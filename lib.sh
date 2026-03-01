#!/bin/bash
# Хелперы для setup.sh (auto-ssh-tunnels)
# Только локальные функции, без remote-управления.

# --- Логирование ---
log_info()  { echo -e "\033[32m[INFO]\033[0m  $*"; }
log_warn()  { echo -e "\033[33m[WARN]\033[0m  $*"; }
log_error() { echo -e "\033[31m[ERROR]\033[0m $*"; }
log_step()  { echo -e "\n\033[1;36m==> $*\033[0m"; }

die() { log_error "$@"; exit 1; }

# --- Определение дистрибутива ---
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    else
        echo "unknown"
    fi
}

DISTRO="$(detect_distro)"

# Маппинг имён пакетов для ALT Linux
_map_pkg() {
    local pkg="$1"
    local distro="${2:-$DISTRO}"
    if [ "$distro" = "altlinux" ]; then
        case "$pkg" in
            openssh-client) echo "openssh-clients" ;;
            openssh-server) echo "openssh-server" ;;
            netcat-openbsd) echo "netcat" ;;
            *) echo "$pkg" ;;
        esac
    else
        echo "$pkg"
    fi
}

# Проверка установлен ли пакет
_pkg_installed() {
    local pkg="$1"
    local distro="${2:-$DISTRO}"
    if [ "$distro" = "altlinux" ]; then
        rpm -q "$pkg" &>/dev/null
    else
        dpkg -s "$pkg" &>/dev/null
    fi
}

# --- Проверки ---
check_root() {
    [ "$(id -u)" -eq 0 ] || die "Запусти от root: sudo $0 $*"
}

check_python3() {
    command -v python3 >/dev/null || die "python3 не найден. Установи: apt install python3-yaml"
    python3 -c "import yaml" 2>/dev/null || die "python3-yaml не найден. Установи: apt install python3-yaml"
}

# --- Управление пакетами ---
apt_install() {
    local to_install=()
    for pkg in "$@"; do
        local mapped
        mapped=$(_map_pkg "$pkg")
        if ! _pkg_installed "$mapped"; then
            to_install+=("$mapped")
        fi
    done
    if [ ${#to_install[@]} -gt 0 ]; then
        log_info "Устанавливаю: ${to_install[*]}"
        if [ "$DISTRO" = "altlinux" ]; then
            apt-get update -qq 2>/dev/null || true
            apt-get install -y "${to_install[@]}"
        else
            apt-get update -qq
            apt-get install -y -qq "${to_install[@]}"
        fi
    else
        log_info "Пакеты уже установлены: $*"
    fi
}

# --- Деплой файлов (идемпотентный) ---
# Возвращает 0 = изменено, 1 = без изменений
deploy_file() {
    local target="$1" mode="${2:-0644}" owner="${3:-root:root}"
    local content
    content=$(cat)

    if [ -f "$target" ]; then
        local existing
        existing=$(cat "$target")
        if [ "$existing" = "$content" ]; then
            log_info "  без изменений: $target"
            return 1
        fi
    fi

    mkdir -p "$(dirname "$target")"
    printf '%s\n' "$content" > "$target"
    chmod "$mode" "$target"
    chown "$owner" "$target"
    log_info "  обновлено: $target"
    return 0
}
