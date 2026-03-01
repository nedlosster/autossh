#!/usr/bin/env bash
# Wrapper для запуска reverse SSH tunnel.
# Вызывается из systemd — корректно раскрывает переменные из конфига.

set -euo pipefail

source /etc/reverse-tunnel.conf

# Построение ProxyCommand из SSH_JUMP_HOST (вместо -J, который в OpenSSH 8.x
# пробрасывает -R в ProxyJump-подпроцесс)
JUMP_OPTS=()
if [[ -n "${SSH_JUMP_HOST:-}" ]]; then
    JUMP_OPTS=(-o "ProxyCommand=ssh -W %h:%p ${SSH_JUMP_HOST}")
fi

exec /usr/bin/autossh -M 0 -N -T \
    -o "ServerAliveInterval=30" \
    -o "ServerAliveCountMax=3" \
    -o "ExitOnForwardFailure=yes" \
    -o "StrictHostKeyChecking=accept-new" \
    -o "TCPKeepAlive=yes" \
    -i "/home/${TUNNEL_USER}/.ssh/id_ed25519" \
    $SSH_EXTRA_OPTS \
    "${JUMP_OPTS[@]}" \
    -R "127.0.0.1:${TUNNEL_PORT}:127.0.0.1:22" \
    $SSH_DESTINATION
