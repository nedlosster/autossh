#!/bin/bash
# Генерация конфигурационных файлов для auto-ssh-tunnels

# --- autossh systemd service (per connection) ---
# Использует переменные: CONN_NAME, CONN_HOST, CONN_USER, CONN_PORT, CONN_ARGS,
#   CONN_JUMP, TUNNEL_USER, KEEPALIVE_INTERVAL, KEEPALIVE_COUNT, RESTART_DELAY, LOG_DIR,
#   CONN_R_PORTS[]
gen_autossh_service() {
    # ProxyCommand для jump-хоста (%%h/%%p — экранирование для systemd)
    local proxy_line=""
    if [ -n "$CONN_JUMP" ]; then
        proxy_line="    -o \"ProxyCommand=$(build_proxy_command "$CONN_JUMP" systemd)\" \\"$'\n'
    fi

    # ExecStartPre: cleanup зависших сессий на remote (только если есть -R порты)
    local cleanup_line=""
    if [ ${#CONN_R_PORTS[@]} -gt 0 ] && [ -n "${CONN_R_PORTS[0]:-}" ]; then
        local cleanup_args="${CONN_USER} ${CONN_HOST} ${CONN_PORT} ${TUNNEL_USER}"
        if [ -n "$CONN_JUMP" ]; then
            cleanup_args+=" ${CONN_JUMP}"
        fi
        cleanup_args+=" -- ${CONN_R_PORTS[*]}"
        cleanup_line="ExecStartPre=-/usr/local/bin/tunnel-cleanup.sh ${cleanup_args}"$'\n'
    fi

    cat <<EOF
[Unit]
Description=AutoSSH Tunnel to ${CONN_NAME} (${CONN_HOST})
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=${TUNNEL_USER}

${cleanup_line}ExecStart=/usr/bin/autossh -M 0 -N \\
    -o "ServerAliveInterval=${KEEPALIVE_INTERVAL}" \\
    -o "ServerAliveCountMax=${KEEPALIVE_COUNT}" \\
    -o "ExitOnForwardFailure=yes" \\
    -o "TCPKeepAlive=yes" \\
    -o "StrictHostKeyChecking=no" \\
${proxy_line}    -i /home/${TUNNEL_USER}/.ssh/id_ed25519 \\
    -p ${CONN_PORT} \\
    ${CONN_ARGS} \\
    ${CONN_USER}@${CONN_HOST}

Restart=always
RestartSec=${RESTART_DELAY}

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

# Парсинг jump user@host[:port] -> ProxyCommand с -p
_build_proxy_cmd() {
    local j="\$1" key="\$2"
    local jhost="\$j" jport=""
    if [[ "\$j" == *@*:* ]]; then
        jhost="\${j%:*}"; jport="\${j##*:}"
        [[ "\$jport" =~ ^[0-9]+\$ ]] || jport=""
    fi
    local popts=""
    [ -n "\$jport" ] && popts="-p \${jport} "
    echo "ssh \${popts}-i \${key} -o StrictHostKeyChecking=no -W %h:%p \${jhost}"
}

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
        ssh_opts+=(-o "ProxyCommand=\$(_build_proxy_cmd "\$jump" /home/${TUNNEL_USER}/.ssh/id_ed25519)")
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

# --- Cleanup скрипт: убивает зависшие sshd на remote перед запуском autossh ---
gen_tunnel_cleanup_sh() {
    cat <<CLEANUP
#!/bin/bash
# Очистка зависших SSH-сессий на remote перед запуском autossh.
# Вызывается через ExecStartPre в autossh-tunnel-*.service.
# Использование: tunnel-cleanup.sh <user> <host> <port> <tunnel_user> [jump] -- <r_port1> ...

LOG_FILE="${LOG_DIR}/tunnel-cleanup.log"
log() { echo "\$(date '+%Y-%m-%d %H:%M:%S') \$*" >> "\$LOG_FILE"; }

# Парсинг jump user@host[:port] -> ProxyCommand с -p
_build_proxy_cmd() {
    local j="\$1" key="\$2"
    local jhost="\$j" jport=""
    if [[ "\$j" == *@*:* ]]; then
        jhost="\${j%:*}"; jport="\${j##*:}"
        [[ "\$jport" =~ ^[0-9]+\$ ]] || jport=""
    fi
    local popts=""
    [ -n "\$jport" ] && popts="-p \${jport} "
    echo "ssh \${popts}-i \${key} -o StrictHostKeyChecking=no -W %h:%p \${jhost}"
}

conn_user="\$1"; host="\$2"; port="\$3"; tunnel_user="\$4"; shift 4

# Jump-хост (опционально)
jump=""
if [ "\$1" != "--" ]; then
    jump="\$1"; shift
fi
shift  # пропускаем --

r_ports=("\$@")
[ \${#r_ports[@]} -eq 0 ] && exit 0

# SSH-опции
ssh_opts=(-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes)
ssh_opts+=(-i "/home/\${tunnel_user}/.ssh/id_ed25519")
if [ -n "\$jump" ]; then
    ssh_opts+=(-o "ProxyCommand=\$(_build_proxy_cmd "\$jump" /home/\${tunnel_user}/.ssh/id_ed25519)")
fi
ssh_opts+=(-p "\$port" "\${conn_user}@\${host}")

killed=0
for rport in "\${r_ports[@]}"; do
    # Ищем sshd, который слушает на порту
    pid=\$(ssh "\${ssh_opts[@]}" "sudo ss -tlnp sport = :\${rport} 2>/dev/null" 2>/dev/null \
        | grep -oP 'pid=\K[0-9]+' | head -1)

    if [ -n "\$pid" ]; then
        log "Порт \${rport} на \${host} занят sshd pid=\${pid}, убиваю"
        ssh "\${ssh_opts[@]}" "sudo kill \${pid}" 2>/dev/null || true
        killed=\$((killed + 1))
    fi
done

if [ \$killed -gt 0 ]; then
    log "Убито \${killed} зависших процессов на \${host}, жду освобождения портов"
    sleep 1
fi

exit 0
CLEANUP
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
