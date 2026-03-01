#!/bin/bash
# ssh-tunnel-multihost — главный скрипт настройки
# Управление SSH-туннелями к нескольким хостам.
# Запускается на локальном (приватном) сервере.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.yml"

# --- Подключаем модули ---
source "${SCRIPT_DIR}/lib.sh"
source "${SCRIPT_DIR}/generate.sh"

# --- Загрузка глобальных переменных ---
load_globals() {
    [ -f "$CONFIG_FILE" ] || die "Конфиг не найден: $CONFIG_FILE. Скопируй config.yml.example в config.yml"
    check_python3
    eval "$(python3 "${SCRIPT_DIR}/parse-config.py" "$CONFIG_FILE" --globals)"
    eval "$(python3 "${SCRIPT_DIR}/parse-config.py" "$CONFIG_FILE" --count)"
    [ "$HOST_COUNT" -gt 0 ] || die "Нет хостов в конфиге"
}

# --- Загрузка переменных конкретного хоста ---
load_host() {
    local idx="$1"
    eval "$(python3 "${SCRIPT_DIR}/parse-config.py" "$CONFIG_FILE" --host "$idx")"
}

# --- Общая локальная настройка (один раз) ---
setup_common() {
    log_step "Общая настройка"

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

    # 4. Директория логов
    mkdir -p "$LOG_DIR"
    chown "${TUNNEL_USER}:${TUNNEL_USER}" "$LOG_DIR"
}

# --- Настройка remote-хоста ---
setup_remote() {
    log_step "Настройка удалённого сервера: $HOST_NAME ($REMOTE_HOST)"

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

    stop_ssh_multiplex
    log_info "Настройка $HOST_NAME ($REMOTE_HOST) завершена"
}

# --- Обновление known_hosts для хоста ---
update_known_hosts() {
    local known_hosts="/home/${TUNNEL_USER}/.ssh/known_hosts"
    log_info "Обновляю known_hosts для $HOST_NAME ($REMOTE_HOST)..."

    local scan_args=()
    if [ "$REMOTE_SSH_PORT" != "22" ]; then
        scan_args+=(-p "$REMOTE_SSH_PORT")
    fi
    scan_args+=("$REMOTE_HOST")

    local scanned
    scanned=$(ssh-keyscan "${scan_args[@]}" 2>/dev/null) || true

    if [ -n "$scanned" ]; then
        if [ -f "$known_hosts" ] && echo "$scanned" | while read -r line; do
            grep -qF "$line" "$known_hosts" 2>/dev/null
        done; then
            log_info "  known_hosts для $REMOTE_HOST уже актуален"
        else
            echo "$scanned" >> "$known_hosts"
            log_info "  known_hosts обновлён для $REMOTE_HOST"
        fi
    fi

    chown "${TUNNEL_USER}:${TUNNEL_USER}" "$known_hosts" 2>/dev/null || true
    chmod 644 "$known_hosts" 2>/dev/null || true
}

# --- Сбор данных всех хостов для health-check ---
collect_all_hosts_data() {
    _ALL_HOST_NAMES=()
    _ALL_HOST_ADDRS=()
    _ALL_HOST_SSH_PORTS=()
    _ALL_HOST_JUMP_HOSTS=()
    _ALL_HOST_MAX_FAILURES=()
    _ALL_HOST_TUNNEL_PORTS=()

    for idx in $(seq 0 $((HOST_COUNT - 1))); do
        load_host "$idx"
        _ALL_HOST_NAMES+=("$HOST_NAME")
        _ALL_HOST_ADDRS+=("$REMOTE_HOST")
        _ALL_HOST_SSH_PORTS+=("$REMOTE_SSH_PORT")
        _ALL_HOST_JUMP_HOSTS+=("${JUMP_HOST:-}")
        _ALL_HOST_MAX_FAILURES+=("$MONITOR_MAX_FAILURES")

        # Собираем порты для проверки (только reverse tunnels — они открываются на remote)
        local ports=""
        for i in $(seq 0 $((TUNNEL_COUNT - 1))); do
            ports+="${TUNNEL_REMOTE_PORT[i]} "
        done
        _ALL_HOST_TUNNEL_PORTS+=("$ports")
    done
}

# --- Запуск сервисов ---
start_services() {
    log_step "Запуск сервисов"

    # known_hosts для всех хостов
    for idx in $(seq 0 $((HOST_COUNT - 1))); do
        load_host "$idx"
        update_known_hosts
    done

    # Включаем и запускаем autossh per host
    for idx in $(seq 0 $((HOST_COUNT - 1))); do
        load_host "$idx"
        local svc="autossh-tunnel-${HOST_NAME}"
        systemctl enable "$svc"
        if systemctl is-active --quiet "$svc"; then
            log_info "$svc уже запущен"
        else
            systemctl start "$svc"
            log_info "$svc запущен"
        fi
    done

    # Watchdog timer
    systemctl enable tunnel-watchdog.timer
    systemctl start tunnel-watchdog.timer
    log_info "Watchdog timer запущен"
}

# --- Статус ---
show_status() {
    log_step "Статус туннелей"

    echo ""
    echo "=== Локальные сервисы ==="
    for idx in $(seq 0 $((HOST_COUNT - 1))); do
        load_host "$idx"
        local svc="autossh-tunnel-${HOST_NAME}"
        local status
        status=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
        if [ "$status" = "active" ]; then
            echo "  ✓ $svc: active"
        else
            echo "  ✗ $svc: $status"
        fi
    done

    local timer_status
    timer_status=$(systemctl is-active tunnel-watchdog.timer 2>/dev/null || echo "inactive")
    if [ "$timer_status" = "active" ]; then
        echo "  ✓ tunnel-watchdog.timer: active"
    else
        echo "  ✗ tunnel-watchdog.timer: $timer_status"
    fi

    echo ""
    echo "=== Проверка портов ==="
    for idx in $(seq 0 $((HOST_COUNT - 1))); do
        load_host "$idx"
        echo "  --- $HOST_NAME ($REMOTE_HOST) ---"

        # Обратные туннели (проверяем на remote)
        if [ "$TUNNEL_COUNT" -gt 0 ]; then
            # Пробуем подключиться для проверки
            local ssh_ctl="/tmp/tunnel-status-${HOST_NAME}-$$"
            local ssh_ok=false

            local -a ssh_opts=(-o ControlMaster=yes -o "ControlPath=${ssh_ctl}")
            ssh_opts+=(-o ControlPersist=30 -o ConnectTimeout=5)
            ssh_opts+=(-o StrictHostKeyChecking=accept-new)
            ssh_opts+=(-i "/home/${TUNNEL_USER}/.ssh/id_ed25519")
            if [ -n "$JUMP_HOST" ]; then
                ssh_opts+=(-o "ProxyCommand=ssh -W %h:%p ${JUMP_HOST}")
            fi
            ssh_opts+=(-p "$REMOTE_SSH_PORT" -fN "${TUNNEL_USER}@${REMOTE_HOST}")

            if ssh "${ssh_opts[@]}" 2>/dev/null; then
                ssh_ok=true
            fi

            for i in $(seq 0 $((TUNNEL_COUNT - 1))); do
                local rport=${TUNNEL_REMOTE_PORT[i]}
                local name=${TUNNEL_NAME[i]}
                local mark="✗"
                if $ssh_ok && ssh -o "ControlPath=${ssh_ctl}" -p "$REMOTE_SSH_PORT" \
                    "${TUNNEL_USER}@${REMOTE_HOST}" -- nc -z -w 3 127.0.0.1 "$rport" 2>/dev/null; then
                    mark="✓"
                fi
                echo "    $mark -R ${name} (remote:${rport} ← local:${TUNNEL_LOCAL[i]})"
            done

            if $ssh_ok; then
                ssh -o "ControlPath=${ssh_ctl}" -O exit "${TUNNEL_USER}@${REMOTE_HOST}" 2>/dev/null || true
            fi
        fi

        # Прямые туннели (проверяем локально)
        for i in $(seq 0 $((FORWARD_COUNT - 1))); do
            local lport=${FORWARD_LOCAL_PORT[i]}
            local name=${FORWARD_NAME[i]}
            local mark="✗"
            if nc -z -w 3 127.0.0.1 "$lport" 2>/dev/null; then
                mark="✓"
            fi
            echo "    $mark -L ${name} (local:${lport} → remote:${FORWARD_REMOTE[i]})"
        done
    done
}

# --- Перезапуск ---
restart_tunnel() {
    local target="${1:-}"

    if [ -n "$target" ]; then
        # Перезапуск конкретного хоста
        local svc="autossh-tunnel-${target}"
        log_step "Перезапуск $svc"
        systemctl restart "$svc"

        sleep 3
        if systemctl is-active --quiet "$svc"; then
            log_info "$svc работает"
        else
            log_error "$svc не запустился!"
            systemctl status "$svc" --no-pager -l || true
        fi
    else
        # Перезапуск всех
        log_step "Перезапуск всех туннелей"
        for idx in $(seq 0 $((HOST_COUNT - 1))); do
            load_host "$idx"
            local svc="autossh-tunnel-${HOST_NAME}"
            systemctl restart "$svc"
            log_info "$svc перезапущен"
        done

        sleep 3
        for idx in $(seq 0 $((HOST_COUNT - 1))); do
            load_host "$idx"
            local svc="autossh-tunnel-${HOST_NAME}"
            if systemctl is-active --quiet "$svc"; then
                log_info "$svc работает"
            else
                log_error "$svc не запустился!"
            fi
        done
    fi
}

# --- Dry-run: показать все генерируемые конфиги ---
dry_run() {
    log_step "Dry-run: генерация конфигов (без деплоя)"

    for idx in $(seq 0 $((HOST_COUNT - 1))); do
        load_host "$idx"

        echo ""
        echo "=========================================="
        echo "=== /etc/systemd/system/autossh-tunnel-${HOST_NAME}.service ==="
        echo "=========================================="
        gen_autossh_service
    done

    # Собираем данные всех хостов для health-check
    collect_all_hosts_data

    echo ""
    echo "=========================================="
    echo "=== /usr/local/bin/tunnel-health.sh ==="
    echo "=========================================="
    gen_tunnel_health_sh

    echo ""
    echo "=========================================="
    echo "=== /etc/systemd/system/tunnel-watchdog.service ==="
    echo "=========================================="
    gen_watchdog_service

    echo ""
    echo "=========================================="
    echo "=== /etc/systemd/system/tunnel-watchdog.timer ==="
    echo "=========================================="
    gen_watchdog_timer

    echo ""
    echo "=========================================="
    echo "=== /etc/logrotate.d/ssh-tunnel ==="
    echo "=========================================="
    gen_logrotate_conf
}

# --- Main ---
main() {
    local cmd="${1:-}"
    shift || true

    load_globals

    case "$cmd" in
        ""|full)
            check_root
            setup_common

            for idx in $(seq 0 $((HOST_COUNT - 1))); do
                load_host "$idx"

                # Генерация и деплой autossh-сервиса
                local svc_file="/etc/systemd/system/autossh-tunnel-${HOST_NAME}.service"
                local svc_changed=false
                if gen_autossh_service | deploy_file "$svc_file"; then
                    svc_changed=true
                fi

                # Настройка remote
                setup_remote

                # Перезапуск при изменении конфига
                if $svc_changed && systemctl is-active --quiet "autossh-tunnel-${HOST_NAME}"; then
                    log_info "Конфиг autossh-tunnel-${HOST_NAME} изменился, перезапускаю..."
                    systemctl restart "autossh-tunnel-${HOST_NAME}"
                fi
            done

            # Health-check (один на все хосты)
            collect_all_hosts_data
            gen_tunnel_health_sh | deploy_file /usr/local/bin/tunnel-health.sh 0755 || true

            # Watchdog
            gen_watchdog_service | deploy_file /etc/systemd/system/tunnel-watchdog.service || true
            gen_watchdog_timer | deploy_file /etc/systemd/system/tunnel-watchdog.timer || true

            # Logrotate
            gen_logrotate_conf | deploy_file /etc/logrotate.d/ssh-tunnel || true

            # Reload и запуск
            systemctl daemon-reload
            start_services

            echo ""
            log_step "Готово! Запусти './setup.sh status' для проверки"
            ;;
        local)
            check_root
            setup_common

            for idx in $(seq 0 $((HOST_COUNT - 1))); do
                load_host "$idx"
                local svc_file="/etc/systemd/system/autossh-tunnel-${HOST_NAME}.service"
                gen_autossh_service | deploy_file "$svc_file" || true
            done

            collect_all_hosts_data
            gen_tunnel_health_sh | deploy_file /usr/local/bin/tunnel-health.sh 0755 || true
            gen_watchdog_service | deploy_file /etc/systemd/system/tunnel-watchdog.service || true
            gen_watchdog_timer | deploy_file /etc/systemd/system/tunnel-watchdog.timer || true
            gen_logrotate_conf | deploy_file /etc/logrotate.d/ssh-tunnel || true

            systemctl daemon-reload
            start_services
            ;;
        remote)
            check_root
            local target="${1:-}"
            if [ -n "$target" ]; then
                # Настройка конкретного remote
                local found=false
                for idx in $(seq 0 $((HOST_COUNT - 1))); do
                    load_host "$idx"
                    if [ "$HOST_NAME" = "$target" ]; then
                        setup_remote
                        found=true
                        break
                    fi
                done
                $found || die "Хост '$target' не найден в конфиге"
            else
                # Настройка всех remote
                for idx in $(seq 0 $((HOST_COUNT - 1))); do
                    load_host "$idx"
                    setup_remote
                done
            fi
            ;;
        status)
            show_status
            ;;
        restart)
            check_root
            restart_tunnel "${1:-}"
            ;;
        dry-run)
            dry_run
            ;;
        *)
            echo "Использование: $0 [full|local|remote [name]|status|restart [name]|dry-run]"
            echo ""
            echo "  (без аргументов)  Полная настройка: local + remote + start"
            echo "  local             Только локальная настройка"
            echo "  remote [name]     Только удалённая настройка (все или один хост)"
            echo "  status            Статус всех туннелей и проверка портов"
            echo "  restart [name]    Перезапуск туннелей (все или один)"
            echo "  dry-run           Показать все генерируемые конфиги"
            exit 1
            ;;
    esac
}

main "$@"
