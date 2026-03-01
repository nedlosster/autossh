#!/bin/bash
# Генерация конфигурационных файлов из переменных (heredoc)

# --- autossh systemd service ---
gen_autossh_service() {
    # Собираем -R флаги
    local r_flags=""
    for i in $(seq 0 $((PORT_COUNT - 1))); do
        local rport=$((PORT_PUBLIC[i] + TUNNEL_PORT_OFFSET))
        local lport=${PORT_LOCAL[i]}
        local lhost="127.0.0.1"

        # Если есть target — проброс на другой хост
        if [ -n "${PORT_TARGET_HOST[i]}" ]; then
            lhost="${PORT_TARGET_HOST[i]}"
            lport="${PORT_TARGET_PORT[i]}"
        fi

        r_flags+="    -R 127.0.0.1:${rport}:${lhost}:${lport} \\"$'\n'
    done

    cat <<EOF
[Unit]
Description=AutoSSH Reverse Tunnel to ${REMOTE_HOST}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${TUNNEL_USER}

Environment="AUTOSSH_GATETIME=${AUTOSSH_GATE_TIME}"
Environment="AUTOSSH_POLL=${AUTOSSH_POLL}"
Environment="AUTOSSH_FIRST_POLL=${AUTOSSH_FIRST_POLL}"
Environment="AUTOSSH_PORT=0"
Environment="AUTOSSH_LOGFILE=${LOG_DIR}/autossh.log"

ExecStart=/usr/bin/autossh -M 0 -N \\
    -o "ServerAliveInterval=${KEEPALIVE_INTERVAL}" \\
    -o "ServerAliveCountMax=${KEEPALIVE_COUNT}" \\
    -o "ExitOnForwardFailure=yes" \\
    -o "TCPKeepAlive=yes" \\
    -o "StrictHostKeyChecking=accept-new" \\
${r_flags}    -i /home/${TUNNEL_USER}/.ssh/id_ed25519 \\
    -p ${TUNNEL_SSH_PORT} \\
    ${TUNNEL_USER}@${REMOTE_HOST}

Restart=always
RestartSec=${RESTART_DELAY}

StandardOutput=append:${LOG_DIR}/autossh-stdout.log
StandardError=append:${LOG_DIR}/autossh-stderr.log

[Install]
WantedBy=multi-user.target
EOF
}

# --- Angie конфиг для удалённого сервера (main) ---
gen_angie_remote_conf() {
    cat <<'EOF'
user www-data;
worker_processes auto;
worker_rlimit_nofile 65536;

error_log /var/log/angie/error.log notice;
pid /run/angie.pid;

events {
    worker_connections 4096;
}

stream {
    log_format proxy '$remote_addr [$time_local] '
                     '$protocol $status $bytes_sent $bytes_received '
                     '$session_time "$upstream_addr"';

    include /etc/angie/stream.d/*.conf;
}

http {
    include /etc/angie/mime.types;
    default_type application/octet-stream;
    access_log off;

    server {
        listen 127.0.0.1:8080;

        location /health {
            return 200 'OK';
            add_header Content-Type text/plain;
        }

        location /status {
            stub_status on;
            allow 127.0.0.1;
            deny all;
        }
    }
}
EOF
}

# --- Stream proxy конфиг для удалённого Angie ---
gen_stream_proxy_conf() {
    echo "# Stream proxy — managed by ssh-tunnel-2local"
    echo ""

    for i in $(seq 0 $((PORT_COUNT - 1))); do
        local pub=${PORT_PUBLIC[i]}
        local tport=$((pub + TUNNEL_PORT_OFFSET))
        local name=${PORT_NAME[i]}
        local no_pp=${PORT_NO_PROXY_PROTOCOL[i]}

        cat <<EOF
# ${name} — port ${pub} -> tunnel ${tport}
upstream tunnel_${pub} {
    server 127.0.0.1:${tport};
}

server {
    listen ${pub};
    listen [::]:${pub};

    proxy_pass tunnel_${pub};
EOF
        if [ "$no_pp" != "true" ]; then
            echo "    proxy_protocol on;"
        fi

        cat <<EOF

    proxy_connect_timeout 10s;
    proxy_timeout 600s;
    proxy_buffer_size 16k;

    access_log ${LOG_DIR}/stream-${pub}.log proxy;
}

EOF
    done
}

# --- Tunnel monitor скрипт (удалённый сервер) ---
gen_tunnel_monitor_sh() {
    local port_checks=""
    for i in $(seq 0 $((PORT_COUNT - 1))); do
        local tport=$((PORT_PUBLIC[i] + TUNNEL_PORT_OFFSET))
        local name=${PORT_NAME[i]}
        port_checks+="    check_port ${tport} \"${name}\" || all_ok=false"$'\n'
    done

    cat <<EOF
#!/bin/bash
# Мониторинг туннельных портов

LOG_FILE="${LOG_DIR}/tunnel-monitor.log"
CHECK_INTERVAL=${MONITOR_CHECK_INTERVAL}
MAX_FAILURES=${MONITOR_MAX_FAILURES}

failures=0

log() { echo "\$(date '+%Y-%m-%d %H:%M:%S') \$*" >> "\$LOG_FILE"; }

check_port() {
    local port=\$1 name=\$2
    if nc -z -w 5 127.0.0.1 "\$port" 2>/dev/null; then
        return 0
    else
        log "FAIL: \$name (port \$port) недоступен"
        return 1
    fi
}

log "Запуск мониторинга"

while true; do
    all_ok=true
${port_checks}
    if \$all_ok; then
        if [ \$failures -gt 0 ]; then
            log "RECOVERED: все порты доступны"
            failures=0
        fi
    else
        failures=\$((failures + 1))
        log "ALERT: failures=\$failures/\$MAX_FAILURES"
    fi

    sleep \$CHECK_INTERVAL
done
EOF
}

# --- Tunnel monitor systemd service ---
gen_tunnel_monitor_service() {
    cat <<EOF
[Unit]
Description=SSH Tunnel Monitor
After=network.target angie.service

[Service]
Type=simple
ExecStart=/usr/local/bin/tunnel-monitor.sh
Restart=always
RestartSec=10

StandardOutput=append:${LOG_DIR}/tunnel-monitor-stdout.log
StandardError=append:${LOG_DIR}/tunnel-monitor-stderr.log

[Install]
WantedBy=multi-user.target
EOF
}

# --- Health check скрипт (локальный сервер) ---
gen_tunnel_health_sh() {
    local port_checks=""
    for i in $(seq 0 $((PORT_COUNT - 1))); do
        local tport=$((PORT_PUBLIC[i] + TUNNEL_PORT_OFFSET))
        local name=${PORT_NAME[i]}
        port_checks+="        if ! ssh -o ControlPath=\"\$SSH_CTL\" -p ${TUNNEL_SSH_PORT} ${TUNNEL_USER}@${REMOTE_HOST} -- nc -z 127.0.0.1 ${tport} 2>/dev/null; then"$'\n'
        port_checks+="            log \"FAIL: ${name} (remote port ${tport})\""$'\n'
        port_checks+="            ok=false"$'\n'
        port_checks+="        fi"$'\n'
    done

    cat <<EOF
#!/bin/bash
# Проверка здоровья туннеля

LOG_FILE="${LOG_DIR}/tunnel-health.log"
FAILURES_FILE="/tmp/tunnel_failures"
MAX_FAILURES=${MONITOR_MAX_FAILURES}

log() { echo "\$(date '+%Y-%m-%d %H:%M:%S') \$*" >> "\$LOG_FILE"; }

# Проверяем что autossh запущен
if ! systemctl is-active --quiet autossh-tunnel; then
    log "FAIL: autossh-tunnel не запущен"
    systemctl restart autossh-tunnel
    log "Перезапущен autossh-tunnel"
    exit 1
fi

# Проверяем SSH-соединение и удалённые порты
SSH_CTL="/tmp/tunnel-health-\$\$"
trap "ssh -o ControlPath=\$SSH_CTL -O exit ${TUNNEL_USER}@${REMOTE_HOST} 2>/dev/null; rm -f \$SSH_CTL" EXIT

if ssh -o ControlMaster=yes -o ControlPath="\$SSH_CTL" -o ControlPersist=30 \
    -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    -i /home/${TUNNEL_USER}/.ssh/id_ed25519 \
    -p ${TUNNEL_SSH_PORT} -fN ${TUNNEL_USER}@${REMOTE_HOST} 2>/dev/null; then

    ok=true
${port_checks}

    if \$ok; then
        # Сброс счётчика
        rm -f "\$FAILURES_FILE"
        exit 0
    fi
else
    log "FAIL: SSH-соединение к ${REMOTE_HOST} не установлено"
fi

# Инкремент счётчика отказов
failures=\$(cat "\$FAILURES_FILE" 2>/dev/null || echo 0)
failures=\$((failures + 1))
echo "\$failures" > "\$FAILURES_FILE"

if [ \$failures -ge \$MAX_FAILURES ]; then
    log "Превышен лимит отказов (\$MAX_FAILURES), перезапуск autossh-tunnel"
    systemctl restart autossh-tunnel
    rm -f "\$FAILURES_FILE"
fi
EOF
}

# --- Watchdog systemd service ---
gen_watchdog_service() {
    cat <<EOF
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
