#!/bin/bash
# ssh-tunnel-2local — главный скрипт настройки
# Запускается на локальном (приватном) сервере.
# Настраивает локальную машину и через SSH — удалённый (публичный) сервер.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.yml"

# --- Подключаем модули ---
source "${SCRIPT_DIR}/lib.sh"
source "${SCRIPT_DIR}/generate.sh"

# --- Загрузка конфигурации ---
load_config() {
    [ -f "$CONFIG_FILE" ] || die "Конфиг не найден: $CONFIG_FILE. Скопируй config.yml.example в config.yml"
    check_python3
    eval "$(python3 "${SCRIPT_DIR}/parse-config.py" "$CONFIG_FILE")"
    [ -n "$REMOTE_HOST" ] || die "remote.host не указан в конфиге"
    [ "$PORT_COUNT" -gt 0 ] || die "Нет портов в конфиге"
}

# --- Локальная настройка ---
setup_local() {
    log_step "Настройка локального сервера"

    # 1. Пакеты
    log_info "Проверка пакетов..."
    apt_install autossh openssh-client netcat-openbsd

    # 2. Пользователь tunnel
    if ! id "$TUNNEL_USER" &>/dev/null; then
        log_info "Создаю пользователя $TUNNEL_USER..."
        useradd -r -m -s /bin/bash "$TUNNEL_USER"
    else
        log_info "Пользователь $TUNNEL_USER уже существует"
    fi

    # 3. SSH-ключ
    local ssh_dir="/home/${TUNNEL_USER}/.ssh"
    local key_file="${ssh_dir}/id_ed25519"
    if [ ! -f "$key_file" ]; then
        log_info "Генерирую SSH-ключ..."
        mkdir -p "$ssh_dir"
        ssh-keygen -t ed25519 -f "$key_file" -N "" -C "${TUNNEL_USER}@$(hostname)"
        chown -R "${TUNNEL_USER}:${TUNNEL_USER}" "$ssh_dir"
        chmod 700 "$ssh_dir"
        chmod 600 "$key_file"
    else
        log_info "SSH-ключ уже существует: $key_file"
    fi

    # 4. Директория логов (writable для tunnel-пользователя — autossh пишет лог)
    mkdir -p "$LOG_DIR"
    chown "${TUNNEL_USER}:${TUNNEL_USER}" "$LOG_DIR"

    # 5. Systemd-сервис autossh
    local svc_changed=false
    if gen_autossh_service | deploy_file /etc/systemd/system/autossh-tunnel.service; then
        svc_changed=true
    fi

    # 6. Health-check скрипт
    gen_tunnel_health_sh | deploy_file /usr/local/bin/tunnel-health.sh 0755 || true

    # 7. Watchdog service + timer
    gen_watchdog_service | deploy_file /etc/systemd/system/tunnel-watchdog.service || true
    gen_watchdog_timer | deploy_file /etc/systemd/system/tunnel-watchdog.timer || true

    # 8. Reload systemd
    systemctl daemon-reload

    if $svc_changed && systemctl is-active --quiet autossh-tunnel; then
        log_info "Конфиг autossh изменился, перезапускаю..."
        systemctl restart autossh-tunnel
    fi

    log_info "Локальная настройка завершена"
}

# --- Удалённая настройка ---
setup_remote() {
    log_step "Настройка удалённого сервера ($REMOTE_HOST)"

    start_ssh_multiplex

    # 1. Проверка sudo
    remote_sudo true || die "Нет sudo на $REMOTE_HOST"

    # 2. Пакеты
    log_info "Проверка пакетов на $REMOTE_HOST..."
    apt_install_remote openssh-server netcat-openbsd

    # 3. Пользователь tunnel
    if ! remote_exec id "$TUNNEL_USER" &>/dev/null; then
        log_info "Создаю пользователя $TUNNEL_USER на $REMOTE_HOST..."
        remote_sudo useradd -r -m -s /bin/bash "$TUNNEL_USER"
    else
        log_info "Пользователь $TUNNEL_USER уже существует на $REMOTE_HOST"
    fi

    # 4. SSH-ключ → authorized_keys
    local pub_key
    pub_key=$(cat "/home/${TUNNEL_USER}/.ssh/id_ed25519.pub")
    local remote_ssh_dir="/home/${TUNNEL_USER}/.ssh"

    remote_sudo mkdir -p "$remote_ssh_dir"

    if ! remote_exec sudo grep -qF "$pub_key" "${remote_ssh_dir}/authorized_keys" 2>/dev/null; then
        log_info "Добавляю SSH-ключ в authorized_keys на $REMOTE_HOST..."
        echo "$pub_key" | remote_exec sudo tee -a "${remote_ssh_dir}/authorized_keys" >/dev/null
    else
        log_info "SSH-ключ уже в authorized_keys на $REMOTE_HOST"
    fi

    remote_sudo chown -R "${TUNNEL_USER}:${TUNNEL_USER}" "$remote_ssh_dir"
    remote_sudo chmod 700 "$remote_ssh_dir"
    remote_sudo chmod 600 "${remote_ssh_dir}/authorized_keys"

    # 5. Настройка sshd
    log_info "Настройка sshd на $REMOTE_HOST..."
    local sshd_changed=false
    ensure_sshd_option "GatewayPorts" "clientspecified" && sshd_changed=true || true
    ensure_sshd_option "TCPKeepAlive" "yes" && sshd_changed=true || true
    ensure_sshd_option "ClientAliveInterval" "30" && sshd_changed=true || true
    ensure_sshd_allow_user "$TUNNEL_USER" && sshd_changed=true || true

    if $sshd_changed; then
        log_info "Перезапускаю sshd на $REMOTE_HOST..."
        remote_sudo systemctl restart ssh || remote_sudo systemctl restart sshd
    fi

    # 6. Angie
    log_info "Проверка Angie на $REMOTE_HOST..."
    install_angie_repo_remote
    apt_install_remote angie

    # 7. Конфиги Angie
    local angie_changed=false
    if gen_angie_remote_conf | deploy_file_remote /etc/angie/angie.conf; then
        angie_changed=true
    fi

    # Создаём директорию stream.d
    remote_sudo mkdir -p /etc/angie/stream.d

    if gen_stream_proxy_conf | deploy_file_remote /etc/angie/stream.d/tunnel.conf; then
        angie_changed=true
    fi

    # 8. Директория логов на удалённом
    remote_sudo mkdir -p "$LOG_DIR"

    # 9. Tunnel monitor
    gen_tunnel_monitor_sh | deploy_file_remote /usr/local/bin/tunnel-monitor.sh 0755 || true
    gen_tunnel_monitor_service | deploy_file_remote /etc/systemd/system/tunnel-monitor.service || true

    remote_sudo systemctl daemon-reload

    # 10. Проверка и перезагрузка Angie
    if $angie_changed; then
        log_info "Проверяю конфиг Angie..."
        if remote_sudo angie -t; then
            log_info "Перезагружаю Angie..."
            remote_sudo systemctl enable angie
            remote_sudo systemctl reload-or-restart angie
        else
            log_error "Конфиг Angie невалиден! Проверь вручную."
        fi
    else
        remote_sudo systemctl enable angie
        if ! remote_exec systemctl is-active --quiet angie; then
            remote_sudo systemctl start angie
        fi
    fi

    # 11. Включаем tunnel-monitor
    remote_sudo systemctl enable tunnel-monitor
    if ! remote_exec systemctl is-active --quiet tunnel-monitor; then
        remote_sudo systemctl start tunnel-monitor
    fi

    log_info "Настройка удалённого сервера завершена"
}

# --- Запуск сервисов ---
start_services() {
    log_step "Запуск сервисов"

    # ssh-keyscan для known_hosts
    local known_hosts="/home/${TUNNEL_USER}/.ssh/known_hosts"
    log_info "Обновляю known_hosts..."

    local scan_args=()
    if [ "$TUNNEL_SSH_PORT" != "22" ]; then
        scan_args+=(-p "$TUNNEL_SSH_PORT")
    fi
    scan_args+=("$REMOTE_HOST")

    local scanned
    scanned=$(ssh-keyscan "${scan_args[@]}" 2>/dev/null) || true

    if [ -n "$scanned" ]; then
        # Проверяем, есть ли уже ключи
        if [ -f "$known_hosts" ] && echo "$scanned" | while read -r line; do
            grep -qF "$line" "$known_hosts" 2>/dev/null
        done; then
            log_info "known_hosts уже актуален"
        else
            echo "$scanned" >> "$known_hosts"
            chown "${TUNNEL_USER}:${TUNNEL_USER}" "$known_hosts"
            chmod 644 "$known_hosts"
            log_info "known_hosts обновлён"
        fi
    fi

    # Включаем и запускаем autossh-tunnel
    systemctl enable autossh-tunnel
    if systemctl is-active --quiet autossh-tunnel; then
        log_info "autossh-tunnel уже запущен"
    else
        systemctl start autossh-tunnel
        log_info "autossh-tunnel запущен"
    fi

    # Включаем watchdog timer
    systemctl enable tunnel-watchdog.timer
    systemctl start tunnel-watchdog.timer
    log_info "Watchdog timer запущен"
}

# --- Статус ---
show_status() {
    log_step "Статус туннеля"

    echo ""
    echo "=== Локальные сервисы ==="
    for svc in autossh-tunnel tunnel-watchdog.timer; do
        local status
        status=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
        if [ "$status" = "active" ]; then
            echo "  ✓ $svc: active"
        else
            echo "  ✗ $svc: $status"
        fi
    done

    echo ""
    echo "=== Удалённые сервисы ($REMOTE_HOST) ==="
    start_ssh_multiplex
    for svc in angie tunnel-monitor; do
        local status
        status=$(remote_exec systemctl is-active "$svc" 2>/dev/null || echo "inactive")
        if [ "$status" = "active" ]; then
            echo "  ✓ $svc: active"
        else
            echo "  ✗ $svc: $status"
        fi
    done

    echo ""
    echo "=== Проверка портов ==="
    for i in $(seq 0 $((PORT_COUNT - 1))); do
        local pub=${PORT_PUBLIC[i]}
        local tport=$((pub + TUNNEL_PORT_OFFSET))
        local name=${PORT_NAME[i]}

        local remote_ok="✗"
        if remote_exec nc -z -w 3 127.0.0.1 "$tport" 2>/dev/null; then
            remote_ok="✓"
        fi
        echo "  $remote_ok ${name} (port ${pub}, tunnel ${tport})"
    done
}

# --- Перезапуск ---
restart_tunnel() {
    log_step "Перезапуск туннеля"
    systemctl restart autossh-tunnel
    log_info "autossh-tunnel перезапущен"

    sleep 3
    if systemctl is-active --quiet autossh-tunnel; then
        log_info "autossh-tunnel работает"
    else
        log_error "autossh-tunnel не запустился!"
        systemctl status autossh-tunnel --no-pager -l || true
    fi
}

# --- Main ---
main() {
    local cmd="${1:-}"

    load_config

    case "$cmd" in
        ""|full)
            check_root
            setup_local
            setup_remote
            start_services
            echo ""
            log_step "Готово! Запусти './setup.sh status' для проверки"
            ;;
        local)
            check_root
            setup_local
            start_services
            ;;
        remote)
            check_root
            setup_remote
            ;;
        status)
            show_status
            ;;
        restart)
            check_root
            restart_tunnel
            ;;
        *)
            echo "Использование: $0 [local|remote|status|restart]"
            echo ""
            echo "  (без аргументов)  Полная настройка: local + remote"
            echo "  local             Только локальная настройка"
            echo "  remote            Только удалённая настройка"
            echo "  status            Статус туннеля"
            echo "  restart           Перезапуск туннеля"
            exit 1
            ;;
    esac
}

main "$@"
