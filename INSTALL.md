# auto-ssh-tunnels -- установка и настройка

Менеджер SSH-туннелей. Управляет несколькими туннелями через единый YAML-конфиг,
автоматически мониторит и перезапускает при сбоях.

## Требования

- systemd
- python3, python3-yaml (PyYAML)
- Пакеты: autossh, openssh-client, netcat-openbsd

Поддерживаемые ОС: Ubuntu/Debian, ALT Linux.

## Установка из пакета

```bash
# Ubuntu/Debian
sudo apt install ./auto-ssh-tunnels_1.0.0_all.deb

# ALT Linux
sudo apt-get install ./auto-ssh-tunnels-1.0.0-alt1.noarch.rpm

# Настройка
sudo nano /etc/auto-ssh-tunnels/config.yml
sudo auto-ssh-tunnels full
```

При установке из пакета:
- Зависимости устанавливаются менеджером пакетов
- Конфиг: `/etc/auto-ssh-tunnels/config.yml`
- Команда: `auto-ssh-tunnels`
- Пользователь `tunnel`, SSH-ключ и директория логов создаются при установке (postinst)

## Установка из исходников

```bash
cp config.yml.example config.yml
nano config.yml                       # указать реальные серверы
sudo bash setup.sh                    # установка
sudo bash setup.sh copy-key <name>    # скопировать SSH-ключ на сервер
bash setup.sh status                  # проверка
```

## Конфигурация

Файл `config.yml`:

```yaml
tunnel_user: tunnel               # системный пользователь для autossh
log_dir: /var/log/ssh-tunnel

defaults:
  keepalive_interval: 30          # ServerAliveInterval (сек)
  keepalive_count: 3              # ServerAliveCountMax
  restart_delay: 10               # RestartSec для systemd
  monitor_interval: 120           # интервал watchdog (сек)
  monitor_max_failures: 3         # ошибок до рестарта

connections:
  - name: prod                    # уникальное имя
    server: admin@1.2.3.4:22      # user@host[:port]
    args: "-R 10080:127.0.0.1:80" # аргументы autossh (-R, -L, -A)
    jump: "root@bastion:2200"     # опционально: jump-хост
```

### Поле `args`

Стандартные SSH-флаги проброса портов:

| Флаг | Назначение | Пример |
|------|-----------|--------|
| `-R rport:host:hport` | Обратный туннель (remote forward) | `-R 10022:127.0.0.1:22` |
| `-L lport:host:hport` | Прямой туннель (local forward) | `-L 3129:127.0.0.1:3128` |
| `-A` | Проброс SSH-агента | `-A` |

Несколько флагов через пробел: `"-R 10022:127.0.0.1:22 -R 10080:127.0.0.1:80 -L 3129:127.0.0.1:3128"`.

## Команды

| Команда | Описание |
|---------|----------|
| `sudo auto-ssh-tunnels` | Полная установка: пакеты, пользователь, ключ, systemd-юниты, watchdog |
| `sudo auto-ssh-tunnels full` | То же самое (явно) |
| `auto-ssh-tunnels dry-run` | Предпросмотр генерируемых конфигов без записи на диск |
| `auto-ssh-tunnels status` | Статус сервисов + проверка доступности портов |
| `sudo auto-ssh-tunnels restart [name]` | Перезапуск всех или указанного туннеля |
| `sudo auto-ssh-tunnels copy-key <name>` | Копирование SSH-ключа на целевой сервер |

При установке из исходников вместо `auto-ssh-tunnels` использовать `bash setup.sh`.

## Что делает установка

1. Устанавливает пакеты (autossh, openssh-client, netcat)
2. Создает системного пользователя `tunnel` с домашней директорией
3. Генерирует SSH-ключ Ed25519 (`/home/tunnel/.ssh/id_ed25519`)
4. Создает директорию логов (`/var/log/ssh-tunnel`)
5. Для каждого connection генерирует systemd-сервис `autossh-tunnel-<name>.service`
6. Генерирует watchdog: `tunnel-health.sh` + `tunnel-watchdog.timer` (периодическая проверка портов)
7. Настраивает logrotate для ротации логов
8. Активирует и запускает все сервисы

## Развёртывание по шагам

### 1. Подготовка конфига

```bash
# Из пакета
sudo nano /etc/auto-ssh-tunnels/config.yml

# Из исходников
cp config.yml.example config.yml
nano config.yml
```

### 2. Проверка (dry-run)

```bash
auto-ssh-tunnels dry-run
```

Выведет все генерируемые файлы. Убедиться, что параметры корректны.

### 3. Установка

```bash
sudo auto-ssh-tunnels full
```

### 4. Копирование SSH-ключа на целевые серверы

Для каждого connection:

```bash
sudo auto-ssh-tunnels copy-key prod
```

Потребуется пароль от целевого сервера. После копирования ключ будет в
`~/.ssh/authorized_keys` на стороне сервера.

Альтернативно -- вручную:

```bash
sudo cat /home/tunnel/.ssh/id_ed25519.pub
# скопировать вывод в authorized_keys на целевом сервере
```

### 5. Проверка

```bash
auto-ssh-tunnels status
```

Вывод показывает статус каждого сервиса и доступность пробрасываемых портов.

## Логи

```bash
# systemd-журнал конкретного туннеля
journalctl -u autossh-tunnel-<name> -f

# лог-файлы autossh
ls /var/log/ssh-tunnel/

# статус watchdog
journalctl -u tunnel-watchdog.timer
```

## Управление туннелями

```bash
# перезапуск конкретного
sudo auto-ssh-tunnels restart prod

# перезапуск всех
sudo auto-ssh-tunnels restart

# ручное управление через systemctl
sudo systemctl stop autossh-tunnel-prod
sudo systemctl start autossh-tunnel-prod
sudo systemctl status autossh-tunnel-prod
```

## Watchdog

Автоматический мониторинг: timer запускает `tunnel-health.sh` каждые N секунд
(параметр `monitor_interval`). Скрипт проверяет:

- Активность systemd-сервиса
- Доступность remote-портов (`-R`) через SSH + `nc -z`
- Доступность local-портов (`-L`) через `nc -z`

При `monitor_max_failures` последовательных ошибках -- автоматический рестарт туннеля.

## Обновление конфигурации

При изменении `config.yml` повторно запустить:

```bash
sudo auto-ssh-tunnels full
```

Скрипт идемпотентен: обновит только изменившиеся файлы и перезапустит затронутые сервисы.

## Структура файлов на целевой системе

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
