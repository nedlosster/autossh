# Persistent Reverse SSH Tunnel

Постоянный обратный SSH-туннель для доступа к тестовой станции без выделенного IP.

## Принцип работы

```
┌──────────────┐          SSH tunnel          ┌──────────────┐
│   Станция    │ ──────────────────────────▶  │    Сервер    │
│  (нет IP)    │   -R TUNNEL_PORT:localhost:22 │  (есть IP)   │
└──────────────┘                              └──────┬───────┘
                                                     │
                                              localhost:TUNNEL_PORT
                                                     │
                                              ┌──────┴───────┐
                                              │    Агент /    │
                                              │  Оператор    │
                                              └──────────────┘
```

Станция инициирует SSH-соединение к серверу и пробрасывает свой порт 22 на `localhost:<TUNNEL_PORT>` сервера. `autossh` следит за соединением и автоматически переподключается при обрыве. Systemd обеспечивает запуск при загрузке и рестарт при падении процесса.

## Требования

- **Станция**: Ubuntu (systemd), openssh-server установлен
- **Сервер**: SSH-доступ, возможность авторизации по ключу
- **Сеть**: станция может установить исходящее SSH-соединение к серверу

## Структура файлов

```
autossh/
├── README.md                      # Этот файл
├── setup-reverse-tunnel.sh        # Скрипт установки
├── reverse-tunnel.conf.example    # Пример конфигурации
└── reverse-tunnel.service         # Systemd unit
```

## Установка

### 1. Скопируйте файлы на станцию

Любым удобным способом (USB, scp, git clone) перенесите папку `autossh/` на станцию.

### 2. Запустите скрипт установки

```bash
cd autossh/
sudo bash setup-reverse-tunnel.sh
```

Скрипт выполнит:
- Установку `autossh`
- Создание системного пользователя `tunnel`
- Генерацию SSH-ключа `/home/tunnel/.ssh/id_ed25519`
- Копирование конфига в `/etc/reverse-tunnel.conf`
- Установку и активацию systemd-сервиса

### 3. Добавьте публичный ключ на сервер

Скрипт выведет публичный ключ. Добавьте его в `~/.ssh/authorized_keys` того пользователя на сервере, который указан в `SSH_CONNECT`.

### 4. Отредактируйте конфигурацию

```bash
sudo nano /etc/reverse-tunnel.conf
```

### 5. Запустите сервис

```bash
sudo systemctl start reverse-tunnel
```

## Конфигурация

Файл `/etc/reverse-tunnel.conf`:

| Переменная | Описание | Пример |
|---|---|---|
| `SSH_CONNECT` | Строка подключения к серверу | `user@server.example.com` |
| `TUNNEL_PORT` | Порт на сервере для туннеля | `2222` |
| `SSH_EXTRA_OPTS` | Дополнительные SSH-опции | `-o Compression=yes` |

### Примеры SSH_CONNECT

**Прямое подключение:**
```bash
SSH_CONNECT="deploy@192.168.1.100"
```

**Через Jump-хост:**
```bash
SSH_CONNECT="deploy@internal-server -J user@jumphost.example.com"
```

**Нестандартный порт + Jump-хост:**
```bash
SSH_CONNECT="deploy@internal-server -p 2222 -J user@jumphost.example.com:2200"
```

**Несколько Jump-хостов:**
```bash
SSH_CONNECT="deploy@target -J user1@jump1,user2@jump2"
```

## Настройка на стороне сервера

### authorized_keys

На сервере в `~/.ssh/authorized_keys` пользователя из `SSH_CONNECT` добавьте публичный ключ станции. Для ограничения прав можно использовать:

```
no-pty,no-X11-forwarding,command="/bin/false" ssh-ed25519 AAAA... tunnel@station
```

Это запретит интерактивный доступ, оставив только возможность создания туннеля.

### GatewayPorts (опционально)

По умолчанию проброшенный порт доступен только на `localhost` сервера. Если нужен доступ с других машин, в `/etc/ssh/sshd_config` на сервере:

```
GatewayPorts clientspecified
```

И в конфиге станции:

```bash
# Привязка к конкретному интерфейсу или ко всем
SSH_EXTRA_OPTS="-R 0.0.0.0:2222:localhost:22"
```

> **Внимание**: открытие порта наружу требует дополнительных мер безопасности.

## Управление сервисом

```bash
# Запуск
sudo systemctl start reverse-tunnel

# Остановка
sudo systemctl stop reverse-tunnel

# Перезапуск (после изменения конфига)
sudo systemctl restart reverse-tunnel

# Статус
sudo systemctl status reverse-tunnel

# Логи (в реальном времени)
journalctl -u reverse-tunnel -f

# Логи (последние 50 строк)
journalctl -u reverse-tunnel -n 50
```

## Проверка работоспособности

### На станции

```bash
# Статус сервиса
sudo systemctl status reverse-tunnel

# Активные SSH-соединения пользователя tunnel
ps -u tunnel -f
```

### На сервере

```bash
# Проверка что порт слушается
ss -tlnp | grep <TUNNEL_PORT>

# Подключение к станции через туннель
ssh -p <TUNNEL_PORT> user@localhost
```

### Kill-тест

```bash
# На станции — убить процесс, должен перезапуститься через ~10 сек
sudo systemctl kill reverse-tunnel
sleep 15
sudo systemctl status reverse-tunnel
```

## Troubleshooting

### Сервис не запускается

```bash
journalctl -u reverse-tunnel -n 30 --no-pager
```

Частые причины:
- **Конфиг не отредактирован** — в `SSH_CONNECT` стоит `user@server.example.com`
- **autossh не установлен** — `which autossh`
- **Пользователь tunnel не существует** — `id tunnel`

### Connection refused / timeout

- Проверьте сетевой доступ: `sudo -u tunnel ssh -v <SSH_CONNECT>`
- Убедитесь что SSH-сервер на удалённой стороне запущен
- Проверьте firewall на сервере

### Ключ не принят сервером

- Проверьте что публичный ключ добавлен: `cat /home/tunnel/.ssh/id_ed25519.pub`
- На сервере: права на `~/.ssh` (700) и `~/.ssh/authorized_keys` (600)
- На сервере: `tail -f /var/log/auth.log` во время попытки подключения

### Туннель поднимается, но порт на сервере не слушается

- На сервере: `ss -tlnp | grep <TUNNEL_PORT>`
- Порт может быть занят: `ss -tlnp | grep <TUNNEL_PORT>` — если занят другим процессом, смените `TUNNEL_PORT`
- Проверьте `ExitOnForwardFailure=yes` в логах — если порт занят, autossh завершится

### Частые переподключения

- Проверьте стабильность сети
- Увеличьте `ServerAliveInterval` / `ServerAliveCountMax` в service-файле
- Проверьте `StartLimitBurst` — при 5 падениях за 300 сек systemd заблокирует сервис на время. Сброс: `sudo systemctl reset-failed reverse-tunnel`
