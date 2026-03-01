#!/bin/bash
# Генерация конфигурационных файлов для type3 (multi-host)

# --- autossh systemd service (per host) ---
# Использует переменные: HOST_NAME, REMOTE_HOST, REMOTE_SSH_PORT, TUNNEL_USER,
#   JUMP_HOST, KEEPALIVE_INTERVAL, KEEPALIVE_COUNT, RESTART_DELAY, LOG_DIR,
#   TUNNEL_COUNT, TUNNEL_REMOTE_PORT[], TUNNEL_LOCAL[],
#   FORWARD_COUNT, FORWARD_LOCAL_PORT[], FORWARD_REMOTE[]
gen_autossh_service() {
    # Собираем -R флаги (обратные туннели)
    local r_flags=""
    local i
    for i in $(seq 0 $((TUNNEL_COUNT - 1))); do
        r_flags+="    -R 127.0.0.1:${TUNNEL_REMOTE_PORT[i]}:${TUNNEL_LOCAL[i]} \\"$'\n'
    done

    # Собираем -L флаги (прямые туннели)
    local l_flags=""
    for i in $(seq 0 $((FORWARD_COUNT - 1))); do
        l_flags+="    -L 127.0.0.1:${FORWARD_LOCAL_PORT[i]}:${FORWARD_REMOTE[i]} \\"$'\n'
    done

    # ProxyCommand для jump-хоста (%%h/%%p — экранирование для systemd)
    local proxy_line=""
    if [ -n "$JUMP_HOST" ]; then
        proxy_line="    -o \"ProxyCommand=ssh -W %%h:%%p ${JUMP_HOST}\" \\"$'\n'
    fi

    cat <<EOF
[Unit]
Description=AutoSSH Tunnel to ${HOST_NAME} (${REMOTE_HOST})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${TUNNEL_USER}

Environment="AUTOSSH_GATETIME=30"
Environment="AUTOSSH_POLL=600"
Environment="AUTOSSH_PORT=0"
Environment="AUTOSSH_LOGFILE=${LOG_DIR}/autossh-${HOST_NAME}.log"

ExecStart=/usr/bin/autossh -M 0 -N \\
    -o "ServerAliveInterval=${KEEPALIVE_INTERVAL}" \\
    -o "ServerAliveCountMax=${KEEPALIVE_COUNT}" \\
    -o "ExitOnForwardFailure=yes" \\
    -o "TCPKeepAlive=yes" \\
    -o "StrictHostKeyChecking=accept-new" \\
${proxy_line}${r_flags}${l_flags}    -i /home/${TUNNEL_USER}/.ssh/id_ed25519 \\
    -p ${REMOTE_SSH_PORT} \\
    ${TUNNEL_USER}@${REMOTE_HOST}

Restart=always
RestartSec=${RESTART_DELAY}
StartLimitIntervalSec=0

StandardOutput=append:${LOG_DIR}/autossh-${HOST_NAME}.log
StandardError=append:${LOG_DIR}/autossh-${HOST_NAME}.log

[Install]
WantedBy=multi-user.target
EOF
}

# --- Health check скрипт (один на все хосты) ---
# Вызывается из setup.sh после заполнения массивов:
#   _ALL_HOST_NAMES[], _ALL_HOST_ADDRS[], _ALL_HOST_SSH_PORTS[],
#   _ALL_HOST_JUMP_HOSTS[], _ALL_HOST_MAX_FAILURES[], _ALL_HOST_TUNNEL_PORTS[]
gen_tunnel_health_sh() {
    # Шапка скрипта (без подстановки переменных)
    cat <<HEADER
#!/bin/bash
# Проверка здоровья всех SSH-туннелей
# Автоматически сгенерировано setup.sh

LOG_FILE="${LOG_DIR}/tunnel-health.log"

log() { echo "\$(date '+%Y-%m-%d %H:%M:%S') \$*" >> "\$LOG_FILE"; }

check_host() {
    local name="\$1" host="\$2" port="\$3" tunnel_user="\$4" jump_host="\$5"
    local max_failures="\$6"
    shift 6
    local tunnel_ports=("\$@")

    local svc="autossh-tunnel-\${name}"
    local failures_file="/tmp/tunnel_failures_\${name}"

    # Проверяем что autossh запущен
    if ! systemctl is-active --quiet "\$svc"; then
        log "FAIL: \${svc} не запущен, перезапускаю"
        systemctl restart "\$svc"
        return 1
    fi

    # SSH-соединение для проверки портов
    local ssh_ctl="/tmp/tunnel-health-\${name}-\$\$"
    local -a ssh_opts=(-o ControlMaster=yes -o "ControlPath=\${ssh_ctl}")
    ssh_opts+=(-o ControlPersist=30 -o ConnectTimeout=10)
    ssh_opts+=(-o StrictHostKeyChecking=accept-new)
    ssh_opts+=(-i /home/${TUNNEL_USER}/.ssh/id_ed25519)

    if [ -n "\$jump_host" ]; then
        ssh_opts+=(-o "ProxyCommand=ssh -W %h:%p \${jump_host}")
    fi

    ssh_opts+=(-p "\$port" -fN "\${tunnel_user}@\${host}")

    if ssh "\${ssh_opts[@]}" 2>/dev/null; then
        local ok=true

        for tport in "\${tunnel_ports[@]}"; do
            if ! ssh -o "ControlPath=\${ssh_ctl}" -p "\$port" \\
                "\${tunnel_user}@\${host}" -- nc -z 127.0.0.1 "\$tport" 2>/dev/null; then
                log "FAIL: \${name} — порт \${tport} недоступен на \${host}"
                ok=false
            fi
        done

        ssh -o "ControlPath=\${ssh_ctl}" -O exit "\${tunnel_user}@\${host}" 2>/dev/null || true

        if \$ok; then
            rm -f "\$failures_file"
            return 0
        fi
    else
        log "FAIL: SSH-соединение к \${host} (\${name}) не установлено"
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

# --- Проверка хостов ---
HEADER

    # Генерируем вызовы check_host для каждого хоста
    local i
    for i in $(seq 0 $((${#_ALL_HOST_NAMES[@]} - 1))); do
        echo "check_host '${_ALL_HOST_NAMES[i]}' '${_ALL_HOST_ADDRS[i]}' '${_ALL_HOST_SSH_PORTS[i]}' '${TUNNEL_USER}' '${_ALL_HOST_JUMP_HOSTS[i]}' '${_ALL_HOST_MAX_FAILURES[i]}' ${_ALL_HOST_TUNNEL_PORTS[i]}"
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
OnUnitActiveSec=${MONITOR_CHECK_INTERVAL}
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
