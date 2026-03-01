# Сборка пакетов auto-ssh-tunnels

## Требования

- **deb**: `dpkg-deb` (пакет `dpkg-dev`)
- **rpm**: `rpmbuild` (пакет `rpm-build` / `rpm-utils` на ALT Linux)

## Версия

Версия задаётся в файле `packaging/VERSION`. Обновить перед релизом:

```bash
echo "1.1.0" > packaging/VERSION
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
- `auto-ssh-tunnels_<version>_all.deb`
- `auto-ssh-tunnels-<version>-alt1.noarch.rpm`

## Проверка метаданных

```bash
# deb
dpkg -I packaging/_out/auto-ssh-tunnels_*.deb

# rpm
rpm -qpi packaging/_out/auto-ssh-tunnels-*.rpm
```

## Установка на целевую систему

```bash
# Ubuntu/Debian
sudo apt install ./auto-ssh-tunnels_1.0.0_all.deb

# ALT Linux
sudo apt-get install ./auto-ssh-tunnels-1.0.0-alt1.noarch.rpm
```

## FHS-пути в пакете

```
/usr/sbin/auto-ssh-tunnels                   <- setup.sh
/usr/lib/auto-ssh-tunnels/lib.sh
/usr/lib/auto-ssh-tunnels/generate.sh
/usr/lib/auto-ssh-tunnels/parse-config.py
/etc/auto-ssh-tunnels/config.yml             <- conffile (не перезатирается)
```
