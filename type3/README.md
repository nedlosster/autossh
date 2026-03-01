# ssh-tunnel-multihost (type3)

Multi-host SSH tunnel manager. Один YAML-конфиг, systemd-сервисы, автоподключение, восстановление.

## Возможности

- Несколько удалённых хостов — по одному autossh-сервису на хост
- Обратные туннели (`-R`) и прямые туннели (`-L`) в одном сервисе
- Jump-хосты через `ProxyCommand` (обход бага OpenSSH 8.x)
- Watchdog (timer + health-check) — один на все хосты
- Поддержка Ubuntu и ALT Linux (на local и remote)
- Идемпотентный деплой — безопасно запускать повторно

## Быстрый старт

```bash
cd type3/
cp config.yml.example config.yml
vim config.yml                    # настрой хосты и туннели

sudo ./setup.sh                   # полная настройка (local + remote)
sudo ./setup.sh status            # проверка статуса
```

## Команды

```
sudo ./setup.sh                   # Полная настройка
sudo ./setup.sh local             # Только локальная настройка (без remote)
sudo ./setup.sh remote            # Настройка всех remote-хостов
sudo ./setup.sh remote prod       # Настройка конкретного remote
sudo ./setup.sh status            # Статус всех туннелей + проверка портов
sudo ./setup.sh restart           # Перезапуск всех туннелей
sudo ./setup.sh restart prod      # Перезапуск конкретного туннеля
./setup.sh dry-run                # Показать генерируемые конфиги (без деплоя)
```

## Конфигурация

См. `config.yml.example` — пример с двумя хостами (prod + backup).

Ключевые секции:
- `tunnel_user` — системный пользователь для туннелей
- `defaults` — глобальные параметры (keepalive, watchdog)
- `hosts[].tunnels` — обратные туннели (`ssh -R`)
- `hosts[].forwards` — прямые туннели (`ssh -L`)
- `hosts[].jump_host` — jump-хост (опционально)

## Архитектура

```
Локальный сервер
├── autossh-tunnel-prod.service     ← 1 сервис на хост
├── autossh-tunnel-backup.service
├── tunnel-watchdog.timer           ← один watchdog
│   └── tunnel-health.sh
└── /var/log/ssh-tunnel/

Remote: prod (203.0.113.10)         ← через jump@bastion
Remote: backup (198.51.100.20)      ← напрямую
```

## Файлы (деплоятся setup.sh)

**Локально:**
- `/etc/systemd/system/autossh-tunnel-<name>.service` — per host
- `/etc/systemd/system/tunnel-watchdog.service` + `.timer`
- `/usr/local/bin/tunnel-health.sh`
- `/etc/logrotate.d/ssh-tunnel`

**На remote (per host):**
- Пользователь `tunnel` + `authorized_keys`
- `sshd_config`: GatewayPorts, TCPKeepAlive, ClientAliveInterval

## Требования

- `autossh`, `openssh-client`, `netcat-openbsd`, `python3-yaml`
- SSH-ключ у пользователя, запускающего `setup.sh`
- sudo на remote-хостах (для `user` из конфига)
