# ssh-tunnel-2local

Упрощённый проброс портов через SSH reverse tunnel. Скрипт запускается **на локальном (приватном) сервере** и настраивает:
- себя — autossh, watchdog, health-check
- удалённый (публичный) сервер — Angie stream proxy, tunnel monitor

## Архитектура

```
Клиент → Удалённый Angie (:порт) → SSH reverse tunnel → Локальный autossh → target
```

- autossh пробрасывает порты напрямую на target (или localhost)
- PROXY protocol добавляется на удалённом Angie (отключается через `no_proxy_protocol: true`)
- Локальный Angie не нужен — autossh работает как чистый TCP-прокси

## Быстрый старт

```bash
# 1. Скопировать проект на локальный сервер
git clone <repo-url> /opt/ssh-tunnel-2local
cd /opt/ssh-tunnel-2local

# 2. Создать конфиг
cp config.yml.example config.yml
nano config.yml

# 3. Запустить (от root)
sudo ./setup.sh
```

## Требования

- **Локальный сервер**: Ubuntu/Debian, root, python3-yaml
- **Удалённый сервер**: Ubuntu/Debian, SSH-доступ с sudo
- Пакеты устанавливаются автоматически: `autossh`, `angie`, `netcat-openbsd`

## Команды

```bash
./setup.sh              # Полная настройка: local + remote
./setup.sh local        # Только локальная настройка
./setup.sh remote       # Только удалённая настройка
./setup.sh status       # Статус туннеля и проверка портов
./setup.sh restart      # Перезапуск autossh-tunnel
```

## Конфигурация (config.yml)

```yaml
remote:
  host: 203.0.113.10          # Внешний IP публичного сервера
  user: admin                 # SSH-юзер для настройки (с sudo)
  ssh_port: 22                # SSH-порт для управления

tunnel_user: tunnel           # Пользователь для туннеля (создаётся на обоих серверах)

ports:
  - public: 80
    local: 80
    name: HTTP

  - public: 443
    local: 443
    name: HTTPS

  # Проброс на другой хост в LAN
  - public: 2222
    local: 2222
    name: GitLab-SSH
    target: "192.168.0.28:2222"
    no_proxy_protocol: true
```

### Параметры портов

| Параметр | Описание |
|----------|----------|
| `public` | Порт на удалённом сервере (слушает Angie) |
| `local` | Локальный порт (по умолчанию = public) |
| `name` | Имя для логов и мониторинга |
| `target` | `host:port` — проброс на другой хост в LAN |
| `no_proxy_protocol` | `true` — отключить PROXY protocol (для SSH, RDP и т.д.) |

### Необязательные параметры

| Параметр | По умолчанию | Описание |
|----------|-------------|----------|
| `tunnel_port_offset` | 10000 | Смещение портов (80 → 10080) |
| `tunnel_ssh_port` | 22 | SSH-порт для туннеля |
| `keepalive_interval` | 30 | SSH ServerAliveInterval (сек) |
| `keepalive_count` | 3 | SSH ServerAliveCountMax |
| `autossh_poll` | 600 | Интервал проверки autossh (сек) |
| `autossh_gate_time` | 30 | Мин. время работы до рестарта (сек) |
| `monitor_check_interval` | 60 | Интервал мониторинга (сек) |
| `monitor_max_failures` | 3 | Отказов до перезапуска |
| `restart_delay` | 10 | Задержка перезапуска (сек) |
| `log_dir` | /var/log/ssh-tunnel | Директория логов |

## Структура файлов

```
├── config.yml.example    # Пример конфига
├── config.yml            # Конфиг (gitignored)
├── setup.sh              # Главный скрипт
├── lib.sh                # Хелперы
├── generate.sh           # Генерация конфигов
├── parse-config.py       # Парсер YAML → shell
└── README.md
```

## Что деплоится

### Локальный сервер
- `/etc/systemd/system/autossh-tunnel.service` — сервис autossh
- `/etc/systemd/system/tunnel-watchdog.service` — health-check (oneshot)
- `/etc/systemd/system/tunnel-watchdog.timer` — таймер watchdog
- `/usr/local/bin/tunnel-health.sh` — скрипт проверки здоровья

### Удалённый сервер
- `/etc/angie/angie.conf` — основной конфиг Angie
- `/etc/angie/stream.d/tunnel.conf` — stream proxy для портов
- `/etc/systemd/system/tunnel-monitor.service` — мониторинг портов
- `/usr/local/bin/tunnel-monitor.sh` — скрипт мониторинга

## Идемпотентность

Повторный запуск `./setup.sh` безопасен — обновляет только изменённые файлы, перезапускает сервисы только при необходимости.
