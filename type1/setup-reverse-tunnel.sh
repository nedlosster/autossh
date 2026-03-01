#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_SRC="$SCRIPT_DIR/reverse-tunnel.conf.example"
SERVICE_SRC="$SCRIPT_DIR/reverse-tunnel.service"
START_SRC="$SCRIPT_DIR/reverse-tunnel-start.sh"
CONF_DST="/etc/reverse-tunnel.conf"
SERVICE_DST="/etc/systemd/system/reverse-tunnel.service"
START_DST="/usr/local/bin/reverse-tunnel-start.sh"

# Читаем TUNNEL_USER из конфига (если конфиг уже установлен — из него, иначе из шаблона)
if [[ -f "$CONF_DST" ]]; then
    source "$CONF_DST"
else
    source "$CONF_SRC"
fi
TUNNEL_USER="${TUNNEL_USER:-tunnel-c1}"
SSH_KEY="/home/$TUNNEL_USER/.ssh/id_ed25519"

# ─── 1. Проверка root ────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "Ошибка: запустите скрипт от root (sudo $0)" >&2
    exit 1
fi

# ─── 2. Установка autossh ────────────────────────────────────────────
echo ">>> Установка autossh..."
apt-get update -qq
apt-get install -y -qq autossh
echo "    autossh установлен."

# ─── 3. Создание системного пользователя tunnel ──────────────────────
if id "$TUNNEL_USER" &>/dev/null; then
    echo ">>> Пользователь '$TUNNEL_USER' уже существует, пропускаю."
else
    echo ">>> Создание системного пользователя '$TUNNEL_USER'..."
    useradd --system --create-home --shell /usr/sbin/nologin "$TUNNEL_USER"
    echo "    Пользователь '$TUNNEL_USER' создан."
fi

# ─── 4. Генерация SSH-ключа ──────────────────────────────────────────
if [[ -f "$SSH_KEY" ]]; then
    echo ">>> SSH-ключ уже существует: $SSH_KEY, пропускаю генерацию."
else
    echo ">>> Генерация SSH-ключа (ed25519)..."
    mkdir -p "$(dirname "$SSH_KEY")"
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "$TUNNEL_USER@$(hostname)"
    chown -R "$TUNNEL_USER":"$TUNNEL_USER" "/home/$TUNNEL_USER/.ssh"
    chmod 700 "/home/$TUNNEL_USER/.ssh"
    chmod 600 "$SSH_KEY"
    chmod 644 "${SSH_KEY}.pub"
    echo "    Ключ создан."
fi

# ─── 5. Вывод публичного ключа ───────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Добавьте этот публичный ключ в ~/.ssh/authorized_keys"
echo "  на СЕРВЕРЕ (для пользователя, указанного в SSH_DESTINATION):"
echo "════════════════════════════════════════════════════════════════"
echo ""
cat "${SSH_KEY}.pub"
echo ""
echo "════════════════════════════════════════════════════════════════"
echo ""

# ─── 6. Копирование конфига ──────────────────────────────────────────
if [[ -f "$CONF_DST" ]]; then
    echo ">>> Конфиг $CONF_DST уже существует, не перезаписываю."
else
    echo ">>> Копирование конфига → $CONF_DST"
    cp "$CONF_SRC" "$CONF_DST"
    chmod 644 "$CONF_DST"
    echo "    Конфиг скопирован."
fi

# ─── 7. Копирование wrapper-скрипта ──────────────────────────────────
echo ">>> Копирование wrapper-скрипта → $START_DST"
cp "$START_SRC" "$START_DST"
chmod 755 "$START_DST"

# ─── 8. Копирование systemd unit (подстановка имени пользователя) ────
echo ">>> Копирование systemd unit → $SERVICE_DST"
sed "s/__TUNNEL_USER__/$TUNNEL_USER/g" "$SERVICE_SRC" > "$SERVICE_DST"
chmod 644 "$SERVICE_DST"

# ─── 9. Reload и enable ──────────────────────────────────────────────
echo ">>> systemctl daemon-reload && enable reverse-tunnel..."
systemctl daemon-reload
systemctl enable reverse-tunnel
echo "    Сервис включён (enable), но НЕ запущен."

# ─── 10. Финальные инструкции ────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Установка завершена. Дальнейшие шаги:                     ║"
echo "║                                                            ║"
echo "║  1. Добавьте публичный ключ (выше) на сервер               ║"
echo "║  2. Отредактируйте конфиг:                                 ║"
echo "║       sudo nano /etc/reverse-tunnel.conf                   ║"
echo "║  3. Запустите сервис:                                      ║"
echo "║       sudo systemctl start reverse-tunnel                  ║"
echo "║  4. Проверьте статус:                                      ║"
echo "║       sudo systemctl status reverse-tunnel                 ║"
echo "║       journalctl -u reverse-tunnel -f                      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
