# Сборка пакетов auto-ssh-tunnels

## Требования

- **deb**: `dpkg-deb` (пакет `dpkg-dev`)
- **rpm**: `rpmbuild` (пакет `rpm` на Ubuntu/Debian, `rpm-build` на ALT Linux)

## Версия

Версия задаётся в файле `packaging/VERSION`:

```bash
cat packaging/VERSION
```

Обновить через release.sh:

```bash
bash release.sh bump <X.Y.Z>
```

## Сборка

```bash
cd packaging

# Только deb
bash build.sh deb

# Только rpm
bash build.sh rpm

# Оба формата
bash build.sh all

# Очистка
bash build.sh clean
```

Результат -- в `packaging/_out/`:
- `auto-ssh-tunnels_<VERSION>_all.deb`
- `auto-ssh-tunnels-<VERSION>-alt1.noarch.rpm`

## Проверка метаданных

```bash
# deb
dpkg -I packaging/_out/auto-ssh-tunnels_*.deb

# rpm
rpm -qpi packaging/_out/auto-ssh-tunnels-*.rpm
```

## Установка

```bash
# Ubuntu/Debian
sudo apt install ./auto-ssh-tunnels_<VERSION>_all.deb

# ALT Linux
sudo apt-get install ./auto-ssh-tunnels-<VERSION>-alt1.noarch.rpm
```

## Релиз

Скрипт `release.sh` автоматизирует полный цикл: сборка, тегирование, публикация на GitHub.

```bash
# Собрать пакеты (deb обязателен, rpm -- при наличии rpmbuild)
bash release.sh build

# Собрать + создать git tag + push + GitHub release с артефактами
bash release.sh publish

# Обновить версию
bash release.sh bump <X.Y.Z>

# Dry-run (показать действия без выполнения)
bash release.sh -d publish
```

Команда `publish`:
1. Проверяет чистый working tree и отсутствие тега
2. Собирает deb (и rpm при наличии rpmbuild)
3. Создаёт тег `v<VERSION>`
4. Push в remote (master + tags)
5. Создаёт GitHub release с deb/rpm артефактами

## FHS-пути в пакете

```
/usr/sbin/auto-ssh-tunnels                   <- setup.sh
/usr/lib/auto-ssh-tunnels/lib.sh
/usr/lib/auto-ssh-tunnels/generate.sh
/usr/lib/auto-ssh-tunnels/parse-config.py
/etc/auto-ssh-tunnels/config.yml             <- conffile (не перезатирается)
```
