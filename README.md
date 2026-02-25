# Persistent Reverse SSH Tunnel

Постоянный обратный SSH-туннель для доступа к тестовой станции без выделенного IP.

## Принцип работы

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

Станция инициирует SSH-соединение к серверу и пробрасывает свой порт 22 на `127.0.0.1:<TUNNEL_PORT>` сервера. `autossh` следит за соединением и автоматически переподключается при обрыве. Systemd обеспечивает запуск при загрузке и рестарт при падении процесса.

## Требования

- **Станция**: Ubuntu (systemd), openssh-server установлен
- **Сервер**: SSH-доступ, возможность авторизации по ключу
- **Сеть**: станция может установить исходящее SSH-соединение к серверу

## Структура файлов

```
autossh/
├── README.md                      # Этот файл
├── setup-reverse-tunnel.sh        # Скрипт установки
├── reverse-tunnel-start.sh        # Wrapper-скрипт (ставится в /usr/local/bin/)
├── reverse-tunnel.conf.example    # Пример конфигурации
└── reverse-tunnel.service         # Systemd unit (шаблон)
```

## Установка

### 1. Скопируйте файлы на станцию

Любым удобным способом (USB, scp, git clone) перенесите папку `autossh/` на станцию.

### 2. (Опционально) Отредактируйте шаблон конфигурации

Перед установкой можно отредактировать `reverse-tunnel.conf.example` — скрипт скопирует его в `/etc/reverse-tunnel.conf`. Если конфиг уже существует, он не будет перезаписан.

### 3. Запустите скрипт установки

```bash
cd autossh/
sudo bash setup-reverse-tunnel.sh
```

Скрипт выполнит:
- Установку `autossh`
- Создание системного пользователя (имя берётся из `TUNNEL_USER`, по умолчанию `tunnel-c1`)
- Генерацию SSH-ключа `/home/<TUNNEL_USER>/.ssh/id_ed25519`
- Копирование конфига в `/etc/reverse-tunnel.conf` (если не существует)
- Установку wrapper-скрипта в `/usr/local/bin/`
- Установку systemd-сервиса с подстановкой имени пользователя
- Активацию сервиса (`enable`), но **без запуска**

### 4. Добавьте публичный ключ на сервер

Скрипт выведет публичный ключ. Добавьте его в `~/.ssh/authorized_keys` того пользователя на сервере, который указан в `SSH_DESTINATION`.

При использовании jump-хоста ключ нужно добавить и на jump-хост (для пользователя из `SSH_JUMP_HOST`), и на целевой сервер.

### 5. Отредактируйте конфигурацию

```bash
sudo nano /etc/reverse-tunnel.conf
```

### 6. Запустите сервис

```bash
sudo systemctl start reverse-tunnel
```

## Конфигурация

Файл `/etc/reverse-tunnel.conf`:

| Переменная | Описание | По умолчанию |
|---|---|---|
| `TUNNEL_USER` | Системный пользователь для туннеля | `tunnel-c1` |
| `SSH_DESTINATION` | Адрес назначения (`user@host`) | `user@server.example.com` |
| `TUNNEL_PORT` | Порт на сервере для туннеля | `2232` |
| `SSH_EXTRA_OPTS` | Дополнительные SSH-опции (`-4`, `-p` и пр.) | _(пусто)_ |
| `SSH_JUMP_HOST` | Jump-хост (`user@host`) | _(пусто)_ |

> **Важно**: после изменения `TUNNEL_USER` необходимо переустановить сервис (`sudo bash setup-reverse-tunnel.sh`), т.к. `User=` в systemd unit подставляется при установке.

### Почему SSH_JUMP_HOST, а не `-J`?

OpenSSH 8.x содержит баг: при использовании `-J` (ProxyJump) флаг `-R` пробрасывается в ProxyJump-подпроцесс, что вызывает ошибку `option requires an argument -- R`. Wrapper-скрипт конвертирует `SSH_JUMP_HOST` в `-o ProxyCommand=ssh -W %h:%p <jump_host>`, что работает корректно.

### Примеры конфигурации

**Прямое подключение:**
```bash
SSH_DESTINATION="deploy@192.168.1.100"
```

**Через Jump-хост:**
```bash
SSH_DESTINATION="deploy@internal-server"
SSH_JUMP_HOST="user@jumphost.example.com"
```

**Нестандартный порт Jump-хоста:**
```bash
SSH_DESTINATION="deploy@internal-server"
SSH_JUMP_HOST="user@jumphost:2200"
```

**IPv4 + Jump-хост (рабочий пример):**
```bash
TUNNEL_USER="tunnel-c1"
SSH_DESTINATION="nedlosster@38.135.122.149"
TUNNEL_PORT=2232
SSH_EXTRA_OPTS="-4"
SSH_JUMP_HOST="root@nlproxy"
```

## Настройка на стороне сервера

### authorized_keys

На сервере в `~/.ssh/authorized_keys` пользователя из `SSH_DESTINATION` добавьте публичный ключ станции. Для ограничения прав можно использовать:

```
no-pty,no-X11-forwarding,command="/bin/false" ssh-ed25519 AAAA... tunnel-c1@station
```

Это запретит интерактивный доступ, оставив только возможность создания туннеля.

### GatewayPorts (опционально)

По умолчанию проброшенный порт доступен только на `localhost` сервера. Если нужен доступ с других машин, в `/etc/ssh/sshd_config` на сервере:

```
GatewayPorts clientspecified
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

# Активные SSH-соединения пользователя
ps -u tunnel-c1 -f
```

### На сервере

```bash
# Проверка что порт слушается
ss -tlnp | grep 2232

# Подключение к станции через туннель
ssh -p 2232 user@localhost
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
- **Конфиг не отредактирован** — в `SSH_DESTINATION` стоит `user@server.example.com`
- **autossh не установлен** — `which autossh`
- **Пользователь не существует** — `id tunnel-c1`

### Connection refused / timeout

- Проверьте сетевой доступ: `sudo -u tunnel-c1 ssh $SSH_EXTRA_OPTS $SSH_DESTINATION`
- Убедитесь что SSH-сервер на удалённой стороне запущен
- Проверьте firewall на сервере
- При использовании jump-хоста: `sudo -u tunnel-c1 ssh -o "ProxyCommand=ssh -W %h:%p $SSH_JUMP_HOST" $SSH_DESTINATION`

### Ключ не принят сервером

- Проверьте что публичный ключ добавлен: `cat /home/tunnel-c1/.ssh/id_ed25519.pub`
- На сервере: права на `~/.ssh` (700) и `~/.ssh/authorized_keys` (600)
- На сервере: `tail -f /var/log/auth.log` во время попытки подключения
- При jump-хосте: ключ должен быть добавлен и на jump-хост, и на целевой сервер

### Туннель поднимается, но порт на сервере не слушается

- На сервере: `ss -tlnp | grep 2232`
- Порт может быть занят другим процессом — смените `TUNNEL_PORT`
- Проверьте `ExitOnForwardFailure=yes` в логах — если порт занят, autossh завершится

### `option requires an argument -- R`

- Убедитесь что jump-хост указан в `SSH_JUMP_HOST`, а не через `-J` в `SSH_EXTRA_OPTS`
- OpenSSH 8.x пробрасывает `-R` в ProxyJump-подпроцесс при использовании `-J` — это баг

### Частые переподключения

- Проверьте стабильность сети
- Увеличьте `ServerAliveInterval` / `ServerAliveCountMax` в wrapper-скрипте
- Проверьте `StartLimitBurst` — при 5 падениях за 300 сек systemd заблокирует сервис на время. Сброс: `sudo systemctl reset-failed reverse-tunnel`
