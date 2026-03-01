#!/bin/bash
# Хелперы для setup.sh

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

# --- SSH-ключ вызывающего пользователя ---
_detect_setup_ssh_key() {
    local user="${SUDO_USER:-$(whoami)}"
    local home
    home=$(eval echo "~$user")
    for key in "$home/.ssh/id_ed25519" "$home/.ssh/id_rsa"; do
        if [ -f "$key" ]; then
            echo "$key"
            return
        fi
    done
    echo ""
}

SETUP_SSH_KEY="$(_detect_setup_ssh_key)"

# Маппинг имён пакетов для ALT Linux
_map_pkg() {
    local pkg="$1"
    if [ "$DISTRO" = "altlinux" ]; then
        case "$pkg" in
            openssh-client) echo "openssh-clients" ;;
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
    if [ "$DISTRO" = "altlinux" ]; then
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
        apt-get update -qq
        apt-get install -y -qq "${to_install[@]}"
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

# --- SSH мультиплексирование ---
SSH_CONTROL_PATH=""

_ensure_ssh_key_on_remote() {
    if [ -z "$SETUP_SSH_KEY" ]; then
        die "SSH-ключ не найден у пользователя ${SUDO_USER:-$(whoami)}"
    fi

    # Проверяем, работает ли key-based auth
    if ssh -o BatchMode=yes -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=accept-new \
        -i "$SETUP_SSH_KEY" \
        -p "$REMOTE_SSH_PORT" \
        "$REMOTE_USER@$REMOTE_HOST" true 2>/dev/null; then
        return 0
    fi

    # Ключ не на remote — копируем (спросит пароль один раз)
    log_info "SSH-ключ не найден на $REMOTE_HOST, копирую (потребуется пароль)..."
    ssh-copy-id -i "${SETUP_SSH_KEY}.pub" \
        -p "$REMOTE_SSH_PORT" \
        "$REMOTE_USER@$REMOTE_HOST" \
        || die "Не удалось скопировать SSH-ключ на $REMOTE_HOST"
    log_info "SSH-ключ скопирован на $REMOTE_HOST"
}

start_ssh_multiplex() {
    SSH_CONTROL_PATH="/tmp/ssh-tunnel-setup-$$"

    _ensure_ssh_key_on_remote

    log_info "Открываю SSH-соединение к $REMOTE_HOST..."
    ssh -o ControlMaster=yes \
        -o ControlPath="$SSH_CONTROL_PATH" \
        -o ControlPersist=300 \
        -o StrictHostKeyChecking=accept-new \
        -i "$SETUP_SSH_KEY" \
        -p "$REMOTE_SSH_PORT" \
        -fN "$REMOTE_USER@$REMOTE_HOST" \
        || die "Не удалось подключиться к $REMOTE_HOST"
    trap stop_ssh_multiplex EXIT
}

stop_ssh_multiplex() {
    if [ -n "$SSH_CONTROL_PATH" ]; then
        ssh -o ControlPath="$SSH_CONTROL_PATH" -O exit \
            "$REMOTE_USER@$REMOTE_HOST" 2>/dev/null || true
        SSH_CONTROL_PATH=""
    fi
}

remote_exec() {
    ssh -o ControlPath="$SSH_CONTROL_PATH" \
        -p "$REMOTE_SSH_PORT" \
        "$REMOTE_USER@$REMOTE_HOST" -- "$@"
}

remote_sudo() {
    remote_exec sudo "$@"
}

# Записать stdin в файл на удалённом сервере
# Использование: echo "content" | remote_write /path/to/file 0644
remote_write() {
    local target="$1" mode="${2:-0644}"
    remote_exec sudo tee "$target" >/dev/null
    remote_exec sudo chmod "$mode" "$target"
}

# Идемпотентный деплой на удалённый сервер
# Использование: deploy_file_remote /path content mode
# Возвращает 0 = изменено, 1 = без изменений
deploy_file_remote() {
    local target="$1" mode="${2:-0644}"
    local content
    content=$(cat)

    local existing
    existing=$(remote_exec sudo cat "$target" 2>/dev/null) || true

    if [ "$existing" = "$content" ]; then
        log_info "  без изменений: $REMOTE_HOST:$target"
        return 1
    fi

    remote_exec sudo mkdir -p "$(dirname "$target")"
    printf '%s\n' "$content" | remote_write "$target" "$mode"
    log_info "  обновлено: $REMOTE_HOST:$target"
    return 0
}

# --- Angie ---
install_angie_repo() {
    local codename version_id distro
    codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
    version_id=$(. /etc/os-release && echo "$VERSION_ID")
    distro=$(. /etc/os-release && echo "$ID")
    local expected_url="https://download.angie.software/angie/${distro}/${version_id}/"
    if [ -f /etc/apt/sources.list.d/angie.list ] && grep -q "$expected_url" /etc/apt/sources.list.d/angie.list 2>/dev/null; then
        log_info "Репозиторий Angie уже добавлен"
        return
    fi
    log_info "Добавляю репозиторий Angie..."
    curl -fsSL https://angie.software/keys/angie-signing.gpg \
        | gpg --dearmor -o /usr/share/keyrings/angie-signing.gpg
    echo "deb [signed-by=/usr/share/keyrings/angie-signing.gpg] ${expected_url} ${codename} main" \
        > /etc/apt/sources.list.d/angie.list
    apt-get update -qq
}

install_angie_repo_remote() {
    if remote_exec test -f /etc/apt/sources.list.d/angie.list; then
        # Проверяем, что URL в файле корректный (содержит VERSION_ID, а не VERSION_CODENAME в пути)
        if remote_exec bash -c "'
            version_id=\$(. /etc/os-release && echo \"\$VERSION_ID\")
            grep -q \"/\${version_id}/\" /etc/apt/sources.list.d/angie.list
        '"; then
            log_info "Репозиторий Angie уже добавлен на $REMOTE_HOST"
            return
        fi
        log_info "Репозиторий Angie содержит неверный URL, пересоздаю..."
    fi
    log_info "Добавляю репозиторий Angie на $REMOTE_HOST..."
    remote_exec bash -c "'
        curl -fsSL https://angie.software/keys/angie-signing.gpg \
            | sudo gpg --dearmor -o /usr/share/keyrings/angie-signing.gpg
        codename=\$(. /etc/os-release && echo \"\$VERSION_CODENAME\")
        version_id=\$(. /etc/os-release && echo \"\$VERSION_ID\")
        distro=\$(. /etc/os-release && echo \"\$ID\")
        echo \"deb [signed-by=/usr/share/keyrings/angie-signing.gpg] https://download.angie.software/angie/\${distro}/\${version_id}/ \${codename} main\" \
            | sudo tee /etc/apt/sources.list.d/angie.list >/dev/null
        sudo apt-get update -qq
    '"
}

apt_install_remote() {
    local to_install=()
    for pkg in "$@"; do
        if ! remote_exec dpkg -s "$pkg" &>/dev/null; then
            to_install+=("$pkg")
        fi
    done
    if [ ${#to_install[@]} -gt 0 ]; then
        log_info "Устанавливаю на $REMOTE_HOST: ${to_install[*]}"
        remote_sudo apt-get update -qq
        remote_sudo apt-get install -y -qq "${to_install[@]}"
    else
        log_info "Пакеты уже установлены на $REMOTE_HOST: $*"
    fi
}

# --- sshd_config ---
# Идемпотентная установка опции в sshd_config на удалённом сервере
# Возвращает 0 = изменено, 1 = без изменений
ensure_sshd_option() {
    local key="$1" value="$2"
    local current
    current=$(remote_exec grep -rE "'^${key}[[:space:]]'" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null | head -1 | awk '{print $2}') || true

    if [ "$current" = "$value" ]; then
        log_info "  sshd: $key = $value (уже)"
        return 1
    fi

    # Удаляем закомментированные и существующие строки, добавляем новую
    remote_sudo sed -i "'/^#*${key}[[:space:]]/d'" /etc/ssh/sshd_config
    remote_exec bash -c "'echo \"${key} ${value}\" | sudo tee -a /etc/ssh/sshd_config >/dev/null'"
    log_info "  sshd: $key = $value (обновлено)"
    return 0
}

# Убедиться, что tunnel-пользователь разрешён в AllowUsers (если директива есть)
# Возвращает 0 = изменено, 1 = без изменений
ensure_sshd_allow_user() {
    local user="$1"
    # Ищем AllowUsers во всех sshd конфигах
    local allow_line
    allow_line=$(remote_exec grep -rn "'^AllowUsers[[:space:]]'" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null | head -1) || true

    if [ -z "$allow_line" ]; then
        # AllowUsers не используется — все пользователи разрешены
        log_info "  sshd: AllowUsers не задан, $user разрешён по умолчанию"
        return 1
    fi

    # Проверяем, есть ли уже пользователь в списке
    local file
    file=$(echo "$allow_line" | cut -d: -f1)
    if remote_exec grep -E "'^AllowUsers[[:space:]]'" "$file" 2>/dev/null | grep -qw "$user"; then
        log_info "  sshd: AllowUsers содержит $user (уже)"
        return 1
    fi

    # Добавляем пользователя в AllowUsers
    remote_sudo sed -i "'s/^AllowUsers[[:space:]].*/& ${user}/'" "$file"
    log_info "  sshd: AllowUsers += $user (обновлено)"
    return 0
}
