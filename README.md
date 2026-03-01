# Persistent Reverse SSH Tunnel

Набор решений для постоянного обратного SSH-туннеля — доступ к серверам без выделенного IP через публичный хост. Проект содержит три реализации с разным уровнем сложности.

## Оглавление

- [Обзор архитектуры](#обзор-архитектуры)
- [Решение 1 (корень) — Simple Tunnel](#решение-1-корень--simple-tunnel)
- [Решение 2 (type1/) — Minimal Tunnel](#решение-2-type1--minimal-tunnel)
- [Решение 3 (type2/) — Multi-Port Production](#решение-3-type2--multi-port-production)
- [Сравнение решений](#сравнение-решений)
- [Плюсы и минусы](#плюсы-и-минусы)
- [Предложения по улучшению](#предложения-по-улучшению)

---

## Обзор архитектуры

Все решения основаны на одном принципе: приватная станция (без IP) инициирует SSH-соединение к публичному серверу и пробрасывает свои порты через `ssh -R`. `autossh` следит за соединением и переподключается при обрыве. Systemd обеспечивает автозапуск.

### Решение 1 и 2 (Simple / Minimal)

```
┌──────────────┐          SSH tunnel          ┌──────────────┐
│   Станция    │ ──────────────────────────▶  │    Сервер    │
│  (нет IP)    │  -R 127.0.0.1:PORT:          │  (есть IP)   │
│              │     127.0.0.1:22              └──────┬───────┘
└──────────────┘                                     │
                                              localhost:TUNNEL_PORT
                                                     │
                                              ┌──────┴───────┐
                                              │    Агент /    │
                                              │  Оператор    │
                                              └──────────────┘
```

### Решение 3 (Multi-Port Production)

```
                                  ┌─────────────────────────────────────┐
┌──────────┐     публичный        │  Удалённый сервер (публичный IP)    │
│  Клиент  │ ───── порт ────────▶ │  Angie stream proxy (:80, :443...) │
└──────────┘                      │        │                            │
                                  │  127.0.0.1:10080, :10443...        │
                                  │  (tunnel ports)                     │
                                  └──────────────┬──────────────────────┘
                                                 │ SSH reverse tunnel
                                  ┌──────────────┴──────────────────────┐
                                  │  Локальный сервер (приватный)        │
                                  │  autossh -R ... -R ... -R ...       │
                                  │        │                            │
                                  │  127.0.0.1:80 / LAN host:port      │
                                  │  (target services)                  │
                                  └─────────────────────────────────────┘
```

---

## Решение 1 (корень) — Simple Tunnel

Простой обратный туннель с поддержкой jump-хоста и локальных пробросов портов (`ssh -L`).

### Структура

```
├── README.md                      # Документация
├── setup-reverse-tunnel.sh        # Скрипт установки
├── reverse-tunnel-start.sh        # Wrapper-скрипт (/usr/local/bin/)
├── reverse-tunnel.conf.example    # Шаблон конфигурации
└── reverse-tunnel.service         # Systemd unit
```

### Возможности

- Один обратный туннель: `-R 127.0.0.1:<PORT>:127.0.0.1:22`
- Jump-хост через `ProxyCommand` (обход бага OpenSSH 8.x)
- Локальные пробросы портов (`LOCAL_FORWARDS`) — `ssh -L`
- Конфигурация через shell-переменные в `/etc/reverse-tunnel.conf`
- Автоустановка: пользователь, ключ, systemd

### Установка

```bash
cd autossh/
sudo bash setup-reverse-tunnel.sh
# Добавить публичный ключ на сервер
sudo nano /etc/reverse-tunnel.conf
sudo systemctl start reverse-tunnel
```

### Конфигурация

| Переменная | Описание | По умолчанию |
|---|---|---|
| `TUNNEL_USER` | Системный пользователь | `tunnel-c1` |
| `SSH_DESTINATION` | Адрес (`user@host`) | `user@server.example.com` |
| `TUNNEL_PORT` | Порт туннеля на сервере | `2232` |
| `SSH_EXTRA_OPTS` | Доп. опции SSH | _(пусто)_ |
| `SSH_JUMP_HOST` | Jump-хост (`user@host`) | _(пусто)_ |
| `LOCAL_FORWARDS` | Локальные пробросы (формат `порт:адрес:порт`) | _(пусто)_ |

### Примеры

```bash
# Прямое подключение
SSH_DESTINATION="deploy@192.168.1.100"

# Через jump-хост
SSH_DESTINATION="deploy@internal-server"
SSH_JUMP_HOST="user@jumphost.example.com"

# Проброс squid с сервера на станцию
LOCAL_FORWARDS="3129:127.0.0.1:3128"
```

---

## Решение 2 (type1/) — Minimal Tunnel

Упрощённая версия решения 1 **без** поддержки `LOCAL_FORWARDS`. Идентичная структура, те же файлы.

### Отличие от решения 1

Единственное отличие — отсутствие переменной `LOCAL_FORWARDS` и логики построения `-L` флагов в wrapper-скрипте. По факту является предыдущей итерацией решения 1.

---

## Решение 3 (type2/) — Multi-Port Production

Полноценное production-решение для проброса **нескольких портов** с Angie stream proxy, мониторингом и health-check'ами.

### Структура

```
type2/
├── config.yml.example    # YAML-конфигурация
├── setup.sh              # Главный скрипт (оркестратор)
├── lib.sh                # Хелперы (SSH, пакеты, деплой)
├── generate.sh           # Генерация конфигов (heredoc)
├── parse-config.py       # Парсер YAML → shell
└── README.md
```

### Возможности

- Множественный проброс портов (один autossh с несколькими `-R`)
- Angie stream proxy на удалённом сервере (публичные порты → tunnel)
- PROXY protocol (отключаемый per-port)
- Проброс на произвольные хосты в LAN (`target: "192.168.0.28:2222"`)
- Двойной мониторинг: удалённый tunnel-monitor + локальный watchdog
- Автоматическая настройка обоих серверов (local + remote через SSH)
- Полная идемпотентность (безопасный повторный запуск)
- SSH мультиплексирование для эффективных remote-операций
- Поддержка Debian/Ubuntu и ALT Linux
- Конфигурируемые таймауты, keepalive, пороги мониторинга

### Установка

```bash
cd type2/
cp config.yml.example config.yml
nano config.yml
sudo ./setup.sh
```

### Команды

```bash
./setup.sh              # Полная настройка (local + remote)
./setup.sh local        # Только локальная часть
./setup.sh remote       # Только удалённая часть
./setup.sh status       # Статус туннеля и портов
./setup.sh restart      # Перезапуск autossh-tunnel
```

### Конфигурация (config.yml)

```yaml
remote:
  host: 203.0.113.10
  user: admin
  ssh_port: 22

tunnel_user: tunnel

ports:
  - public: 80
    local: 80
    name: HTTP
  - public: 443
    local: 443
    name: HTTPS
  - public: 2222
    local: 2222
    name: GitLab-SSH
    target: "192.168.0.28:2222"
    no_proxy_protocol: true

# tunnel_port_offset: 10000     # 80 → 10080
# keepalive_interval: 30
# monitor_max_failures: 3
```

### Что деплоится

**Локально:**
- `/etc/systemd/system/autossh-tunnel.service`
- `/etc/systemd/system/tunnel-watchdog.service` + `.timer`
- `/usr/local/bin/tunnel-health.sh`

**На удалённом сервере:**
- `/etc/angie/angie.conf` + `/etc/angie/stream.d/tunnel.conf`
- `/etc/systemd/system/tunnel-monitor.service`
- `/usr/local/bin/tunnel-monitor.sh`

---

## Сравнение решений

| Критерий | Решение 1 (корень) | Решение 2 (type1) | Решение 3 (type2) |
|---|---|---|---|
| **Сценарий** | SSH-доступ к 1 станции | SSH-доступ к 1 станции | Проброс N сервисов в продакшн |
| **Формат конфига** | Shell-переменные | Shell-переменные | YAML |
| **Кол-во портов** | 1 reverse + N local | 1 reverse | N reverse |
| **Reverse proxy** | Нет | Нет | Angie stream proxy |
| **PROXY protocol** | Нет | Нет | Да (отключаемый) |
| **Мониторинг** | Нет | Нет | Двусторонний (remote + local) |
| **Автоматический watchdog** | Нет | Нет | Да (systemd timer) |
| **Настройка remote** | Вручную | Вручную | Автоматически (через SSH) |
| **Идемпотентность** | Частичная | Частичная | Полная |
| **Jump-хост** | Да (ProxyCommand) | Да (ProxyCommand) | Нет (прямое подключение) |
| **Local forwards (ssh -L)** | Да | Нет | Нет (другой подход) |
| **Target-хосты в LAN** | Только localhost | Только localhost | Произвольные |
| **Зависимости** | autossh | autossh | autossh, python3-yaml, angie, netcat |
| **Язык** | Bash | Bash | Bash + Python |
| **Совместимость** | Debian/Ubuntu | Debian/Ubuntu | Debian/Ubuntu, ALT Linux |
| **Строк кода** | ~140 | ~100 | ~900+ |
| **Время развёртывания** | 2 мин | 2 мин | 5–10 мин |

---

## Плюсы и минусы

### Решение 1 (корень) — Simple Tunnel

**Плюсы:**
- Минимальные зависимости (только `autossh`)
- Простая и понятная конфигурация (5–6 переменных)
- Быстрое развёртывание (1 команда)
- Обход бага OpenSSH 8.x (ProxyCommand вместо -J)
- Поддержка jump-хоста — работает через цепочки промежуточных серверов
- LOCAL_FORWARDS — двусторонний проброс (и -R, и -L)
- Wrapper-скрипт корректно раскрывает переменные (в отличие от systemd)

**Минусы:**
- Нет мониторинга / health-check'ов — если туннель «зависнет» без разрыва TCP, обнаружить проблему можно только вручную
- Нет автоматической настройки серверной стороны — authorized_keys, sshd_config, firewall настраиваются вручную
- Только один reverse-порт (порт 22 станции)
- Конфиг — shell source → инъекция кода при подмене файла
- Нет ротации логов — журнал только через journald
- `StartLimitBurst=5` при нестабильной сети быстро исчерпывается → сервис блокируется
- `StrictHostKeyChecking=accept-new` — TOFU, при первом подключении принимает любой ключ

### Решение 2 (type1) — Minimal Tunnel

**Плюсы:**
- Все плюсы решения 1 (кроме LOCAL_FORWARDS)
- Максимальная простота — минимум движущихся частей

**Минусы:**
- Все минусы решения 1
- Нет LOCAL_FORWARDS — по функциональности строго подмножество решения 1
- Является устаревшей версией, которую решение 1 полностью замещает

### Решение 3 (type2) — Multi-Port Production

**Плюсы:**
- Полноценный multi-port проброс через один SSH-туннель
- Angie stream proxy — публичные порты проксируются прозрачно для клиентов
- PROXY protocol — сохранение реального IP клиента (для HTTP/HTTPS)
- Двойной мониторинг: remote (tunnel-monitor) + local (watchdog timer)
- Автоматическая настройка обоих серверов за одну команду
- Полная идемпотентность — deploy_file / deploy_file_remote обновляют только при изменении
- YAML-конфигурация — читаемее и безопаснее shell source
- Поддержка target-хостов в LAN (не только localhost)
- SSH мультиплексирование — десятки remote-команд через одно соединение
- Модульная архитектура (lib.sh, generate.sh, parse-config.py, setup.sh)
- Конфигурируемые параметры (keepalive, таймауты, пороги ошибок, log_dir)
- Поддержка ALT Linux (маппинг имён пакетов)

**Минусы:**
- Зависимость от Python 3 + PyYAML для парсинга конфигурации
- Зависимость от Angie (нишевый форк nginx) — не везде доступен, привязка к вендору
- Нет поддержки jump-хоста (в отличие от решения 1)
- Сложность: ~900+ строк, 6 файлов, два языка — труднее отладить и поддерживать
- Генерация конфигов через heredoc + shell-escape — хрупко, сложно тестировать
- tunnel-monitor на remote не перезапускает туннель — только логирует (нет active remediation)
- Health-check через вложенный SSH (ssh → nc на remote) — дорого по ресурсам
- Нет TLS-терминации — Angie stream работает как TCP-прокси, TLS остаётся на бэкенде
- `eval` для загрузки shell-переменных из Python — потенциальная инъекция при ошибках парсера
- sshd_config правится через sed на remote — нет валидации перед `systemctl restart ssh`
- Конфиг logrotate не генерируется — логи в `/var/log/ssh-tunnel/` будут расти бесконечно

---

## Предложения по улучшению

### Решение 1 (корень)

1. **Health-check скрипт + systemd timer** — периодическая проверка доступности tunnel-порта на сервере (по аналогии с type2 watchdog, но проще):
   ```bash
   # tunnel-health.sh
   if ! ssh -o ConnectTimeout=5 ... nc -z 127.0.0.1 $TUNNEL_PORT; then
       systemctl restart reverse-tunnel
   fi
   ```

2. **Валидация конфига** — проверка обязательных переменных при запуске wrapper-скрипта перед вызовом autossh:
   ```bash
   [[ -n "$SSH_DESTINATION" && "$SSH_DESTINATION" != *example* ]] || { echo "Конфиг не настроен"; exit 1; }
   ```

3. **Множественные reverse-порты** — поддержка `REVERSE_FORWARDS="2232:22 8080:80"` аналогично `LOCAL_FORWARDS`.

4. **Увеличение StartLimitBurst** или использование `StartLimitIntervalSec=0` с ограничением через `RestartSec=30` — при нестабильной сети 5 рестартов за 5 минут недостаточно.

5. **Логирование в файл** — добавить `StandardOutput=append:/var/log/reverse-tunnel.log` в systemd unit для удобства диагностики без journalctl.

6. **Uninstall-скрипт** — для чистого удаления (systemctl disable, удаление файлов, опционально пользователя).

7. **Проверка SSH-ключа перед запуском** — wrapper-скрипт должен проверять существование ключа и давать понятную ошибку, а не падать с generic ssh error.

### Решение 2 (type1)

> Рекомендация: **удалить type1/** из проекта — решение 1 (корень) является строгим надмножеством, type1 не несёт самостоятельной ценности. Если нужна история — она есть в git.

Если сохраняется:
1. Все улучшения из решения 1 (кроме LOCAL_FORWARDS, которые здесь намеренно убраны).
2. Добавить пометку "archived/deprecated" в README.

### Решение 3 (type2)

1. **Замена Angie на nginx** (опционально) — nginx доступен из стандартных репозиториев всех дистрибутивов. Stream-модуль идентичен. Можно сделать выбор `proxy_backend: angie|nginx` в конфиге.

2. **Поддержка jump-хоста** — добавить `jump_host` в YAML-конфиг и генерировать `ProxyCommand` в autossh-tunnel.service (как в решении 1).

3. **sshd_config валидация** — перед `systemctl restart ssh` выполнять `sshd -t`:
   ```bash
   remote_sudo sshd -t || { log_error "Невалидный sshd_config!"; return 1; }
   ```

4. **Logrotate** — генерировать конфиг ротации логов:
   ```
   /var/log/ssh-tunnel/*.log {
       daily
       rotate 14
       compress
       missingok
       notifempty
   }
   ```

5. **Замена `eval` на безопасный парсинг** — parse-config.py может записывать переменные в файл, который sourced через `set -a`, либо генерировать JSON и парсить через `jq`.

6. **Active remediation на remote** — tunnel-monitor сейчас только логирует ошибки. Можно добавить автоматический перезапуск autossh через обратную связь (ssh к локальному серверу или webhook).

7. **Тестирование генерации** — heredoc-генераторы в generate.sh сложно верифицировать. Добавить `./setup.sh dry-run` который покажет все генерируемые файлы без деплоя.

8. **Удаление хардкода apt** — `apt_install_remote` не поддерживает ALT Linux (в отличие от локального `apt_install`). Унифицировать через `_pkg_manager()`.

9. **Конфигурируемый authorized_keys** — добавить опции для ограничения ключа (`no-pty,no-X11-forwarding,command="/bin/false"`).

10. **Systemd hardening** — добавить в сервисы `ProtectSystem=strict`, `ProtectHome=read-only`, `NoNewPrivileges=true`, `PrivateTmp=true`.

---

## Какое решение выбрать?

| Задача | Решение |
|---|---|
| Быстрый SSH-доступ к одной станции | **Решение 1** (корень) |
| Проброс нескольких сервисов (web, git, etc.) с мониторингом | **Решение 3** (type2) |
| Минимальная зависимость, максимальная простота | **Решение 1** (корень) |

---

## Общие рекомендации

- **Безопасность authorized_keys**: ограничивайте ключ через `no-pty,no-X11-forwarding,command="/bin/false"`
- **GatewayPorts**: включайте `clientspecified` только при необходимости доступа извне localhost
- **Firewall**: при открытии портов наружу используйте iptables/nftables/ufw
- **Мониторинг**: даже для решения 1 рекомендуется внешний мониторинг (Zabbix, Prometheus node_exporter)

## Управление сервисом

```bash
# Решение 1
sudo systemctl start|stop|restart|status reverse-tunnel
journalctl -u reverse-tunnel -f

# Решение 3
sudo systemctl start|stop|restart|status autossh-tunnel
journalctl -u autossh-tunnel -f
./setup.sh status
```

## Troubleshooting

### Сервис не запускается

```bash
journalctl -u reverse-tunnel -n 30 --no-pager   # решение 1
journalctl -u autossh-tunnel -n 30 --no-pager   # решение 3
```

Частые причины:
- Конфиг не отредактирован (`SSH_DESTINATION` = example)
- Публичный ключ не добавлен на сервер
- Порт на сервере занят другим процессом
- `autossh` не установлен

### `option requires an argument -- R` (OpenSSH 8.x)

Используйте `SSH_JUMP_HOST` вместо `-J` в `SSH_EXTRA_OPTS`. Wrapper-скрипт автоматически конвертирует в `ProxyCommand`.

### Частые переподключения

- Проверьте стабильность сети
- Увеличьте `ServerAliveInterval` / `ServerAliveCountMax`
- Сброс лимита systemd: `sudo systemctl reset-failed reverse-tunnel`
