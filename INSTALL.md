# auto-ssh-tunnels -- установка и настройка

## Требования

- systemd
- python3, python3-yaml (PyYAML)
- autossh, openssh-client, netcat-openbsd

Поддерживаемые ОС: Ubuntu/Debian, ALT Linux.

## Установка из пакета

Пакеты доступны на странице [Releases](https://github.com/nedlosster/auto-ssh-tunnels/releases).

```bash
# Ubuntu/Debian
sudo apt install ./auto-ssh-tunnels_<VERSION>_all.deb

# ALT Linux
sudo apt-get install ./auto-ssh-tunnels-<VERSION>-alt1.noarch.rpm
```

При установке из пакета:
- Зависимости устанавливаются менеджером пакетов
- Конфиг: `/etc/auto-ssh-tunnels/config.yml`
- Команда: `auto-ssh-tunnels` (на ALT Linux: `/usr/sbin/auto-ssh-tunnels`)
- Системный пользователь `autosshtunnels`, SSH-ключ и директория логов создаются автоматически

## Установка из исходников

```bash
cp config.yml.example config.yml
nano config.yml
sudo bash setup.sh
```

## Конфигурация

Формат `config.yml` описан в [README.md](README.md#конфигурация).

Ключевые моменты:
- `tunnel_user` -- системный пользователь для autossh-процессов (по умолчанию `autosshtunnels`)
- `connections[].server` -- формат `user@host[:port]`
- `connections[].args` -- SSH-аргументы: `-R`, `-L`, `-A`
- `connections[].jump` -- jump-хост (опционально): `user@host[:port]`

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

Выведет все генерируемые systemd-юниты, health-check скрипт и logrotate конфиг.

### 3. Установка

```bash
sudo auto-ssh-tunnels full
```

Создаёт пользователя, SSH-ключ, systemd-сервисы, watchdog timer, logrotate. Сканирует и добавляет в known_hosts ключи jump-хостов и целевых серверов.

### 4. Копирование SSH-ключа

SSH-ключ пользователя `autosshtunnels` нужно добавить в `authorized_keys` на целевом сервере. Если задан jump-хост -- на jump-хосте тоже.

Через встроенную команду (копирует на целевой сервер через jump):

```bash
sudo auto-ssh-tunnels copy-key <name>
```

Вручную:

```bash
# Получить публичный ключ
sudo cat /home/autosshtunnels/.ssh/id_ed25519.pub

# Добавить в authorized_keys на целевом сервере и jump-хосте
```

### 5. Проверка

```bash
auto-ssh-tunnels status
```

Показывает статус каждого сервиса, проверяет доступность `-R` портов на remote и `-L` портов локально.

## Команды

| Команда | Описание |
|---------|----------|
| `sudo auto-ssh-tunnels` | Полная установка |
| `sudo auto-ssh-tunnels full` | То же самое (явно) |
| `auto-ssh-tunnels dry-run` | Предпросмотр генерируемых конфигов |
| `auto-ssh-tunnels status` | Статус сервисов и проверка портов |
| `sudo auto-ssh-tunnels restart [name]` | Перезапуск всех или указанного туннеля |
| `sudo auto-ssh-tunnels copy-key <name>` | Копирование SSH-ключа на целевой сервер |

При установке из исходников вместо `auto-ssh-tunnels` использовать `bash setup.sh`.

## Что делает установка

1. Устанавливает пакеты (autossh, openssh-client, netcat)
2. Создаёт системного пользователя `autosshtunnels` с домашней директорией
3. Генерирует SSH-ключ Ed25519 (`/home/autosshtunnels/.ssh/id_ed25519`)
4. Создаёт директорию логов (`/var/log/ssh-tunnel`)
5. Сканирует ключи jump-хостов и целевых серверов в known_hosts
6. Генерирует systemd-сервис `autossh-tunnel-<name>.service` для каждого connection
7. Генерирует watchdog: `tunnel-health.sh` + `tunnel-watchdog.timer`
8. Настраивает logrotate для ротации логов
9. Включает (enable) и запускает все сервисы

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
/home/autosshtunnels/.ssh/
  id_ed25519                       # приватный ключ
  id_ed25519.pub                   # публичный ключ
  known_hosts                      # ключи серверов (jump + target)
/etc/logrotate.d/
  ssh-tunnel                       # ротация логов
```

## Логи

```bash
# systemd-журнал конкретного туннеля
journalctl -u autossh-tunnel-<name> -f

# лог-файлы autossh
ls /var/log/ssh-tunnel/

# статус watchdog
journalctl -u tunnel-watchdog.timer
```

## Обновление конфигурации

При изменении `config.yml` повторно запустить:

```bash
sudo auto-ssh-tunnels full
```

Скрипт идемпотентен: сравнивает генерируемые файлы с существующими. Если systemd-юнит изменился (порты, серверы, параметры) -- выполняет `daemon-reload` и перезапускает затронутый сервис. Неизменённые сервисы не трогаются.

## Обновление пакета

При обновлении пакета (deb/rpm) сервисы останавливаются, обновляются файлы, затем сервисы автоматически включаются и запускаются. Конфиг `/etc/auto-ssh-tunnels/config.yml` не перезатирается.
