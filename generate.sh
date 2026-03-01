#!/bin/bash
# Генерация конфигурационных файлов для auto-ssh-tunnels

# --- autossh systemd service (per connection) ---
# Использует переменные: CONN_NAME, CONN_HOST, CONN_USER, CONN_PORT, CONN_ARGS,
#   CONN_JUMP, TUNNEL_USER, KEEPALIVE_INTERVAL, KEEPALIVE_COUNT, RESTART_DELAY, LOG_DIR
gen_autossh_service() {
    # ProxyCommand для jump-хоста (%%h/%%p — экранирование для systemd)
    local proxy_line=""
    if [ -n "$CONN_JUMP" ]; then
        proxy_line="    -o \"ProxyCommand=ssh -W %%h:%%p ${CONN_JUMP}\" \\"$'\n'
    fi

    cat <<EOF
[Unit]
Description=AutoSSH Tunnel to ${CONN_NAME} (${CONN_HOST})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${TUNNEL_USER}

Environment="AUTOSSH_GATETIME=30"
Environment="AUTOSSH_POLL=600"
Environment="AUTOSSH_PORT=0"
Environment="AUTOSSH_LOGFILE=${LOG_DIR}/autossh-${CONN_NAME}.log"

ExecStart=/usr/bin/autossh -M 0 -N \\
    -o "ServerAliveInterval=${KEEPALIVE_INTERVAL}" \\
    -o "ServerAliveCountMax=${KEEPALIVE_COUNT}" \\
    -o "ExitOnForwardFailure=yes" \\
    -o "TCPKeepAlive=yes" \\
    -o "StrictHostKeyChecking=accept-new" \\
${proxy_line}    -i /home/${TUNNEL_USER}/.ssh/id_ed25519 \\
    -p ${CONN_PORT} \\
    ${CONN_ARGS} \\
    ${CONN_USER}@${CONN_HOST}

Restart=always
RestartSec=${RESTART_DELAY}
StartLimitIntervalSec=0

StandardOutput=append:${LOG_DIR}/autossh-${CONN_NAME}.log
StandardError=append:${LOG_DIR}/autossh-${CONN_NAME}.log

[Install]
WantedBy=multi-user.target
EOF
}

# --- Health check скрипт (один на все connections) ---
# Вызывается из setup.sh после заполнения массивов:
#   _ALL_CONN_NAMES[], _ALL_CONN_HOSTS[], _ALL_CONN_PORTS[],
#   _ALL_CONN_USERS[], _ALL_CONN_JUMPS[], _ALL_CONN_MAX_FAILURES[],
#   _ALL_CONN_R_PORTS[], _ALL_CONN_L_PORTS[]
gen_tunnel_health_sh() {
    # Шапка скрипта (без подстановки переменных)
    cat <<HEADER
#!/bin/bash
# Проверка здоровья всех SSH-туннелей
# Автоматически сгенерировано setup.sh

LOG_FILE="${LOG_DIR}/tunnel-health.log"

log() { echo "\$(date '+%Y-%m-%d %H:%M:%S') \$*" >> "\$LOG_FILE"; }

# Проверка -R портов на remote через SSH + nc
check_remote_ports() {
    local name="\$1" host="\$2" port="\$3" user="\$4" jump="\$5"
    shift 5
    local r_ports=("\$@")

    [ \${#r_ports[@]} -eq 0 ] && return 0

    local ssh_ctl="/tmp/tunnel-health-\${name}-\$\$"
    local -a ssh_opts=(-o ControlMaster=yes -o "ControlPath=\${ssh_ctl}")
    ssh_opts+=(-o ControlPersist=30 -o ConnectTimeout=10)
    ssh_opts+=(-o StrictHostKeyChecking=accept-new)
    ssh_opts+=(-i /home/${TUNNEL_USER}/.ssh/id_ed25519)

    if [ -n "\$jump" ]; then
        ssh_opts+=(-o "ProxyCommand=ssh -W %h:%p \${jump}")
    fi

    ssh_opts+=(-p "\$port" -fN "\${user}@\${host}")

    if ssh "\${ssh_opts[@]}" 2>/dev/null; then
        local ok=true
        for tport in "\${r_ports[@]}"; do
            if ! ssh -o "ControlPath=\${ssh_ctl}" -p "\$port" \\
                "\${user}@\${host}" -- nc -z 127.0.0.1 "\$tport" 2>/dev/null; then
                log "FAIL: \${name} — -R порт \${tport} недоступен на \${host}"
                ok=false
            fi
        done
        ssh -o "ControlPath=\${ssh_ctl}" -O exit "\${user}@\${host}" 2>/dev/null || true
        \$ok && return 0
    else
        log "FAIL: SSH-соединение к \${host} (\${name}) не установлено"
    fi
    return 1
}

# Проверка -L портов локально
check_local_ports() {
    local name="\$1"
    shift
    local l_ports=("\$@")
    local ok=true

    for lport in "\${l_ports[@]}"; do
        if ! nc -z -w 3 127.0.0.1 "\$lport" 2>/dev/null; then
            log "FAIL: \${name} — -L порт \${lport} недоступен локально"
            ok=false
        fi
    done
    \$ok
}

# Полная проверка одного connection
check_conn() {
    local name="\$1" host="\$2" port="\$3" user="\$4" jump="\$5"
    local max_failures="\$6"
    shift 6
    # Остаток — r_ports...|l_ports...
    # Парсим через разделитель --
    local r_ports=() l_ports=()
    local in_l=false
    for arg in "\$@"; do
        if [ "\$arg" = "--" ]; then
            in_l=true
            continue
        fi
        if \$in_l; then
            l_ports+=("\$arg")
        else
            r_ports+=("\$arg")
        fi
    done

    local svc="autossh-tunnel-\${name}"
    local failures_file="/tmp/tunnel_failures_\${name}"

    # Проверяем что autossh запущен
    if ! systemctl is-active --quiet "\$svc"; then
        log "FAIL: \${svc} не запущен, перезапускаю"
        systemctl restart "\$svc"
        return 1
    fi

    local ok=true
    check_remote_ports "\$name" "\$host" "\$port" "\$user" "\$jump" "\${r_ports[@]}" || ok=false
    check_local_ports "\$name" "\${l_ports[@]}" || ok=false

    if \$ok; then
        rm -f "\$failures_file"
        return 0
    fi

    # Инкремент счётчика отказов
    local failures
    failures=\$(cat "\$failures_file" 2>/dev/null || echo 0)
    failures=\$((failures + 1))
    echo "\$failures" > "\$failures_file"

    if [ "\$failures" -ge "\$max_failures" ]; then
        log "Превышен лимит отказов (\${max_failures}) для \${name}, перезапуск \${svc}"
        systemctl restart "\$svc"
        rm -f "\$failures_file"
    fi

    return 1
}

# --- Проверка connections ---
HEADER

    # Генерируем вызовы check_conn для каждого connection
    local i
    for i in $(seq 0 $((${#_ALL_CONN_NAMES[@]} - 1))); do
        echo "check_conn '${_ALL_CONN_NAMES[i]}' '${_ALL_CONN_HOSTS[i]}' '${_ALL_CONN_PORTS[i]}' '${_ALL_CONN_USERS[i]}' '${_ALL_CONN_JUMPS[i]}' '${_ALL_CONN_MAX_FAILURES[i]}' ${_ALL_CONN_R_PORTS[i]} -- ${_ALL_CONN_L_PORTS[i]}"
    done
}

# --- Watchdog systemd service (oneshot) ---
gen_watchdog_service() {
    cat <<'EOF'
[Unit]
Description=SSH Tunnel Watchdog

[Service]
Type=oneshot
ExecStart=/usr/local/bin/tunnel-health.sh
EOF
}

# --- Watchdog timer ---
gen_watchdog_timer() {
    cat <<EOF
[Unit]
Description=SSH Tunnel Watchdog Timer

[Timer]
OnBootSec=60
OnUnitActiveSec=${MONITOR_INTERVAL}
AccuracySec=10

[Install]
WantedBy=timers.target
EOF
}

# --- Logrotate ---
gen_logrotate_conf() {
    cat <<EOF
${LOG_DIR}/*.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
}
