#!/bin/bash
# auto-ssh-tunnels — менеджер SSH-туннелей
# Управление SSH-туннелями через единый YAML-конфиг.
# Запускается на локальном сервере. Remote не настраивается.

set -euo pipefail

PKG_NAME="auto-ssh-tunnels"
if [ -d "/usr/lib/${PKG_NAME}" ] && [ -f "/usr/lib/${PKG_NAME}/lib.sh" ]; then
    LIB_DIR="/usr/lib/${PKG_NAME}"
    CONFIG_FILE="/etc/${PKG_NAME}/config.yml"
    PKG_MODE=true
else
    LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
    CONFIG_FILE="${LIB_DIR}/config.yml"
    PKG_MODE=false
fi

# --- Подключаем модули ---
source "${LIB_DIR}/lib.sh"
source "${LIB_DIR}/generate.sh"

# --- Загрузка глобальных переменных ---
load_globals() {
    [ -f "$CONFIG_FILE" ] || die "Конфиг не найден: $CONFIG_FILE. Скопируй config.yml.example в config.yml"
    check_python3
    eval "$(python3 "${LIB_DIR}/parse-config.py" "$CONFIG_FILE" --globals)"
    eval "$(python3 "${LIB_DIR}/parse-config.py" "$CONFIG_FILE" --count)"
    [ "$CONN_COUNT" -gt 0 ] || die "Нет connections в конфиге"
}

# --- Загрузка переменных конкретного connection ---
load_connection() {
    local idx="$1"
    eval "$(python3 "${LIB_DIR}/parse-config.py" "$CONFIG_FILE" --connection "$idx")"
}

# --- Общая локальная настройка (один раз) ---
setup_common() {
    log_step "Общая настройка"

    # 1. Пакеты (в пакетном режиме зависимости решены менеджером пакетов)
    if ! $PKG_MODE; then
        log_info "Проверка пакетов..."
        apt_install autossh openssh-client netcat-openbsd
    fi

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

# --- Обновление known_hosts для connection ---
update_known_hosts() {
    local known_hosts="/home/${TUNNEL_USER}/.ssh/known_hosts"
    log_info "Обновляю known_hosts для $CONN_NAME ($CONN_HOST)..."

    local scan_args=()
    if [ "$CONN_PORT" != "22" ]; then
        scan_args+=(-p "$CONN_PORT")
    fi
    scan_args+=("$CONN_HOST")

    local scanned
    scanned=$(ssh-keyscan "${scan_args[@]}" 2>/dev/null) || true

    if [ -n "$scanned" ]; then
        if [ -f "$known_hosts" ] && echo "$scanned" | while read -r line; do
            grep -qF "$line" "$known_hosts" 2>/dev/null
        done; then
            log_info "  known_hosts для $CONN_HOST уже актуален"
        else
            echo "$scanned" >> "$known_hosts"
            log_info "  known_hosts обновлён для $CONN_HOST"
        fi
    fi

    chown "${TUNNEL_USER}:${TUNNEL_USER}" "$known_hosts" 2>/dev/null || true
    chmod 644 "$known_hosts" 2>/dev/null || true
}

# --- Сбор данных всех connections для health-check ---
collect_all_conn_data() {
    _ALL_CONN_NAMES=()
    _ALL_CONN_HOSTS=()
    _ALL_CONN_PORTS=()
    _ALL_CONN_USERS=()
    _ALL_CONN_JUMPS=()
    _ALL_CONN_MAX_FAILURES=()
    _ALL_CONN_R_PORTS=()
    _ALL_CONN_L_PORTS=()

    for idx in $(seq 0 $((CONN_COUNT - 1))); do
        load_connection "$idx"
        _ALL_CONN_NAMES+=("$CONN_NAME")
        _ALL_CONN_HOSTS+=("$CONN_HOST")
        _ALL_CONN_PORTS+=("$CONN_PORT")
        _ALL_CONN_USERS+=("$CONN_USER")
        _ALL_CONN_JUMPS+=("${CONN_JUMP:-}")
        _ALL_CONN_MAX_FAILURES+=("$MONITOR_MAX_FAILURES")

        # R-порты и L-порты (пробелами — для подстановки в скрипт)
        _ALL_CONN_R_PORTS+=("${CONN_R_PORTS[*]:-}")
        _ALL_CONN_L_PORTS+=("${CONN_L_PORTS[*]:-}")
    done
}

# --- Запуск сервисов ---
start_services() {
    log_step "Запуск сервисов"

    # known_hosts для всех connections
    for idx in $(seq 0 $((CONN_COUNT - 1))); do
        load_connection "$idx"
        update_known_hosts
    done

    # Включаем и запускаем autossh per connection
    for idx in $(seq 0 $((CONN_COUNT - 1))); do
        load_connection "$idx"
        local svc="autossh-tunnel-${CONN_NAME}"
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
    for idx in $(seq 0 $((CONN_COUNT - 1))); do
        load_connection "$idx"
        local svc="autossh-tunnel-${CONN_NAME}"
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
    for idx in $(seq 0 $((CONN_COUNT - 1))); do
        load_connection "$idx"
        echo "  --- $CONN_NAME ($CONN_HOST) ---"

        # Обратные туннели (-R) — проверяем на remote
        if [ ${#CONN_R_PORTS[@]} -gt 0 ] && [ -n "${CONN_R_PORTS[0]:-}" ]; then
            local ssh_ctl="/tmp/tunnel-status-${CONN_NAME}-$$"
            local ssh_ok=false

            local -a ssh_opts=(-o ControlMaster=yes -o "ControlPath=${ssh_ctl}")
            ssh_opts+=(-o ControlPersist=30 -o ConnectTimeout=5)
            ssh_opts+=(-o StrictHostKeyChecking=accept-new)
            ssh_opts+=(-i "/home/${TUNNEL_USER}/.ssh/id_ed25519")
            if [ -n "${CONN_JUMP:-}" ]; then
                ssh_opts+=(-o "ProxyCommand=ssh -W %h:%p ${CONN_JUMP}")
            fi
            ssh_opts+=(-p "$CONN_PORT" -fN "${CONN_USER}@${CONN_HOST}")

            if ssh "${ssh_opts[@]}" 2>/dev/null; then
                ssh_ok=true
            fi

            for rport in "${CONN_R_PORTS[@]}"; do
                local mark="✗"
                if $ssh_ok && ssh -o "ControlPath=${ssh_ctl}" -p "$CONN_PORT" \
                    "${CONN_USER}@${CONN_HOST}" -- nc -z -w 3 127.0.0.1 "$rport" 2>/dev/null; then
                    mark="✓"
                fi
                echo "    $mark -R :${rport} (remote)"
            done

            if $ssh_ok; then
                ssh -o "ControlPath=${ssh_ctl}" -O exit "${CONN_USER}@${CONN_HOST}" 2>/dev/null || true
            fi
        fi

        # Прямые туннели (-L) — проверяем локально
        if [ ${#CONN_L_PORTS[@]} -gt 0 ] && [ -n "${CONN_L_PORTS[0]:-}" ]; then
            for lport in "${CONN_L_PORTS[@]}"; do
                local mark="✗"
                if nc -z -w 3 127.0.0.1 "$lport" 2>/dev/null; then
                    mark="✓"
                fi
                echo "    $mark -L :${lport} (local)"
            done
        fi
    done
}

# --- Перезапуск ---
restart_tunnel() {
    local target="${1:-}"

    if [ -n "$target" ]; then
        # Перезапуск конкретного connection
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
        for idx in $(seq 0 $((CONN_COUNT - 1))); do
            load_connection "$idx"
            local svc="autossh-tunnel-${CONN_NAME}"
            systemctl restart "$svc"
            log_info "$svc перезапущен"
        done

        sleep 3
        for idx in $(seq 0 $((CONN_COUNT - 1))); do
            load_connection "$idx"
            local svc="autossh-tunnel-${CONN_NAME}"
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

    for idx in $(seq 0 $((CONN_COUNT - 1))); do
        load_connection "$idx"

        echo ""
        echo "=========================================="
        echo "=== /etc/systemd/system/autossh-tunnel-${CONN_NAME}.service ==="
        echo "=========================================="
        gen_autossh_service
    done

    # Собираем данные всех connections для health-check
    collect_all_conn_data

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

# --- copy-key: копирование SSH-ключа на сервер ---
copy_key() {
    local target="${1:-}"
    [ -n "$target" ] || die "Укажи имя connection: $0 copy-key <name>"

    local found=false
    for idx in $(seq 0 $((CONN_COUNT - 1))); do
        load_connection "$idx"
        if [ "$CONN_NAME" = "$target" ]; then
            found=true
            break
        fi
    done
    $found || die "Connection '$target' не найден в конфиге"

    local key_file="/home/${TUNNEL_USER}/.ssh/id_ed25519.pub"
    [ -f "$key_file" ] || die "SSH-ключ не найден: $key_file. Сначала запусти sudo $0"

    log_step "Копирование SSH-ключа на $CONN_NAME ($CONN_USER@$CONN_HOST:$CONN_PORT)"

    local -a ssh_copy_args=()
    ssh_copy_args+=(-i "$key_file")
    ssh_copy_args+=(-p "$CONN_PORT")
    if [ -n "${CONN_JUMP:-}" ]; then
        ssh_copy_args+=(-o "ProxyCommand=ssh -W %h:%p ${CONN_JUMP}")
    fi
    ssh_copy_args+=("${CONN_USER}@${CONN_HOST}")

    # ssh-copy-id запускаем от имени tunnel-пользователя
    sudo -u "$TUNNEL_USER" ssh-copy-id "${ssh_copy_args[@]}" \
        || die "Не удалось скопировать SSH-ключ на $CONN_HOST"

    log_info "SSH-ключ скопирован на $CONN_HOST"
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

            for idx in $(seq 0 $((CONN_COUNT - 1))); do
                load_connection "$idx"

                # Генерация и деплой autossh-сервиса
                local svc_file="/etc/systemd/system/autossh-tunnel-${CONN_NAME}.service"
                local svc_changed=false
                if gen_autossh_service | deploy_file "$svc_file"; then
                    svc_changed=true
                fi

                # Перезапуск при изменении конфига
                if $svc_changed && systemctl is-active --quiet "autossh-tunnel-${CONN_NAME}"; then
                    log_info "Конфиг autossh-tunnel-${CONN_NAME} изменился, перезапускаю..."
                    systemctl restart "autossh-tunnel-${CONN_NAME}"
                fi
            done

            # Health-check (один на все connections)
            collect_all_conn_data
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
        copy-key)
            copy_key "${1:-}"
            ;;
        *)
            echo "Использование: $0 [full|status|restart [name]|dry-run|copy-key <name>]"
            echo ""
            echo "  (без аргументов)  Полная установка"
            echo "  status            Статус всех туннелей и проверка портов"
            echo "  restart [name]    Перезапуск туннелей (все или один)"
            echo "  dry-run           Показать все генерируемые конфиги"
            echo "  copy-key <name>   Скопировать SSH-ключ на сервер"
            exit 1
            ;;
    esac
}

main "$@"
