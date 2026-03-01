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
+--------------+         SSH tunnel          +--------------+
|   Локальный  | --------------------------> |   Удалённый  |
|   сервер     |  -R port:host:hostport      |   сервер     |
|              |  -L port:host:hostport      |  (публ. IP)  |
+--------------+                             +--------------+
```

Локальный сервер инициирует SSH-соединение к удалённому и пробрасывает порты через `ssh -R` / `ssh -L`. `autossh` следит за соединением и переподключается при обрыве. Systemd обеспечивает автозапуск, watchdog timer периодически проверяет доступность портов.

## Установка

### Из пакета

Готовые пакеты доступны на странице [Releases](https://github.com/nedlosster/auto-ssh-tunnels/releases).

```bash
# Ubuntu/Debian
sudo apt install ./auto-ssh-tunnels_<VERSION>_all.deb

# ALT Linux
sudo apt-get install ./auto-ssh-tunnels-<VERSION>-alt1.noarch.rpm
```

### Из исходников

```bash
git clone https://github.com/nedlosster/auto-ssh-tunnels.git
cd autossh
cp config.yml.example config.yml
nano config.yml
sudo bash setup.sh
```

Подробная инструкция -- в [INSTALL.md](INSTALL.md).

## Конфигурация

Файл конфига:
- из пакета: `/etc/auto-ssh-tunnels/config.yml`
- из исходников: `config.yml` в директории проекта

```yaml
tunnel_user: autosshtunnels
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
    args: "-R 10022:127.0.0.1:22"
```

### Параметры connection

| Поле | Обязательно | Описание |
|------|:-----------:|----------|
| `name` | да | Уникальное имя (используется в имени systemd-сервиса) |
| `server` | да | `user@host[:port]` -- целевой SSH-сервер |
| `args` | да | Аргументы SSH: `-R`, `-L`, `-A` и др. |
| `jump` | нет | Jump-хост: `user@host[:port]` (ProxyCommand) |

### Флаги в `args`

| Флаг | Назначение | Пример |
|------|-----------|--------|
| `-R rport:host:hport` | Обратный туннель (remote forward) | `-R 10022:127.0.0.1:22` |
| `-L lport:host:hport` | Прямой туннель (local forward) | `-L 3129:127.0.0.1:3128` |
| `-A` | Проброс SSH-агента | `-A` |

Несколько флагов через пробел: `"-R 10022:127.0.0.1:22 -L 3129:127.0.0.1:3128"`.

## Команды

```bash
sudo auto-ssh-tunnels              # полная установка
sudo auto-ssh-tunnels full         # то же самое (явно)
auto-ssh-tunnels dry-run           # предпросмотр генерируемых конфигов
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
/home/autosshtunnels/.ssh/
  id_ed25519                       # SSH-ключ (создаётся при установке)
  known_hosts                      # ключи серверов (jump + target)
/etc/logrotate.d/
  ssh-tunnel                       # ротация логов
```

## Сборка пакетов

Сборка и публикация релизов -- через `release.sh`. Подробности в [BUILD.md](BUILD.md).

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
