# auto-ssh-tunnels

Менеджер постоянных SSH-туннелей. Управляет несколькими туннелями через единый YAML-конфиг, генерирует systemd-сервисы, health-check watchdog и logrotate.

## Возможности

- Несколько SSH-туннелей через один конфиг
- Обратные (-R) и прямые (-L) туннели
- Jump-хосты (ProxyCommand)
- Автоматический мониторинг и перезапуск (watchdog timer)
- Идемпотентная настройка -- безопасный повторный запуск
- Поддержка Ubuntu/Debian и ALT Linux
- Установка из deb/rpm пакета или из исходников

## Архитектура

```
+--------------+          SSH tunnel          +--------------+
|   Локальный  | --------------------------> |   Удалённый  |
|   сервер     |  -R port:host:hostport      |   сервер     |
|              |  -L port:host:hostport      |  (публ. IP)  |
+--------------+                             +--------------+
```

Локальный сервер инициирует SSH-соединение к удалённому и пробрасывает порты через `ssh -R` / `ssh -L`. `autossh` следит за соединением и переподключается при обрыве. Systemd обеспечивает автозапуск, watchdog timer периодически проверяет доступность портов.

## Установка

### Из пакета

```bash
# Ubuntu/Debian
sudo apt install ./auto-ssh-tunnels_1.0.0_all.deb

# ALT Linux
sudo apt-get install ./auto-ssh-tunnels-1.0.0-alt1.noarch.rpm
```

### Из исходников

```bash
git clone <repo-url>
cd auto-ssh-tunnels
cp config.yml.example config.yml
nano config.yml
sudo bash setup.sh
```

Подробная инструкция -- в [INSTALL.md](INSTALL.md).

## Конфигурация

Файл `config.yml`:

```yaml
tunnel_user: tunnel
log_dir: /var/log/ssh-tunnel

defaults:
  keepalive_interval: 30
  keepalive_count: 3
  restart_delay: 10
  monitor_interval: 120
  monitor_max_failures: 3

connections:
  - name: prod
    server: admin@203.0.113.10:22
    args: "-R 10080:127.0.0.1:80 -R 10443:127.0.0.1:443 -L 3129:127.0.0.1:3128"
    jump: "root@bastion:2200"

  - name: backup
    server: deploy@198.51.100.20
    args: "-R 10022:127.0.0.1:22 -A"
```

### Поле `args`

| Флаг | Назначение | Пример |
|------|-----------|--------|
| `-R rport:host:hport` | Обратный туннель (remote forward) | `-R 10022:127.0.0.1:22` |
| `-L lport:host:hport` | Прямой туннель (local forward) | `-L 3129:127.0.0.1:3128` |
| `-A` | Проброс SSH-агента | `-A` |

## Команды

```bash
sudo auto-ssh-tunnels              # полная установка
sudo auto-ssh-tunnels full         # то же самое (явно)
auto-ssh-tunnels dry-run           # предпросмотр конфигов
auto-ssh-tunnels status            # статус сервисов и портов
sudo auto-ssh-tunnels restart [name]  # перезапуск туннелей
sudo auto-ssh-tunnels copy-key <name> # копирование SSH-ключа на сервер
```

При установке из исходников вместо `auto-ssh-tunnels` использовать `bash setup.sh`.

## Что генерируется при установке

```
/etc/systemd/system/
  autossh-tunnel-<name>.service    # по одному на connection
  tunnel-watchdog.service          # oneshot для health-check
  tunnel-watchdog.timer            # периодический запуск watchdog
/usr/local/bin/
  tunnel-health.sh                 # скрипт проверки туннелей
/var/log/ssh-tunnel/
  autossh-<name>.log               # логи autossh
/home/tunnel/.ssh/
  id_ed25519                       # приватный ключ
  id_ed25519.pub                   # публичный ключ
  known_hosts                      # ключи серверов
/etc/logrotate.d/
  ssh-tunnel                       # ротация логов
```

## Сборка пакетов

См. [BUILD.md](BUILD.md).

## Логи и диагностика

```bash
journalctl -u autossh-tunnel-<name> -f
ls /var/log/ssh-tunnel/
journalctl -u tunnel-watchdog.timer
```

## Требования

- systemd
- python3, python3-yaml (PyYAML)
- autossh, openssh-client, netcat-openbsd

Поддерживаемые ОС: Ubuntu/Debian, ALT Linux.
