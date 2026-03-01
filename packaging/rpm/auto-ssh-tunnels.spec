Name:           auto-ssh-tunnels
Version:        @VERSION@
Release:        alt1
Summary:        SSH tunnel manager with YAML config
License:        MIT
Group:          Networking/Remote access
BuildArch:      noarch

Requires:       autossh
Requires:       openssh-clients
Requires:       netcat
Requires:       python3
Requires:       python3-module-pyyaml
Requires:       systemd

Source0:        %{name}-%{version}.tar.gz

%description
Manages multiple persistent SSH tunnels via a single YAML configuration.
Generates systemd services, health-check watchdog, and logrotate configs.

%prep
%setup -q

%install
cp -a usr etc %{buildroot}/

%files
%attr(755,root,root) /usr/sbin/%{name}
/usr/lib/%{name}/lib.sh
/usr/lib/%{name}/generate.sh
%attr(755,root,root) /usr/lib/%{name}/parse-config.py
%config(noreplace) /etc/%{name}/config.yml

%post
# Пользователь autosshtunnels
if ! id autosshtunnels &>/dev/null; then
    useradd -r -m -s /bin/bash autosshtunnels
fi

# SSH-ключ
SSH_DIR="/home/autosshtunnels/.ssh"
KEY_FILE="${SSH_DIR}/id_ed25519"
if [ ! -f "$KEY_FILE" ]; then
    mkdir -p "$SSH_DIR"
    ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "autosshtunnels@$(hostname)"
    chown -R autosshtunnels:autosshtunnels "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    chmod 600 "$KEY_FILE"
fi

# Директория логов
mkdir -p /var/log/ssh-tunnel
chown autosshtunnels:autosshtunnels /var/log/ssh-tunnel

# После обновления: восстановить сервисы, если unit-файлы существуют
if [ "$1" -gt 1 ] 2>/dev/null; then
    systemctl daemon-reload 2>/dev/null || true
    for f in /etc/systemd/system/autossh-tunnel-*.service; do
        [ -f "$f" ] || continue
        svc="$(basename "$f")"
        systemctl enable "$svc" 2>/dev/null || true
        systemctl start "$svc" 2>/dev/null || true
    done
    if [ -f /etc/systemd/system/tunnel-watchdog.timer ]; then
        systemctl enable tunnel-watchdog.timer 2>/dev/null || true
        systemctl start tunnel-watchdog.timer 2>/dev/null || true
    fi
fi

%preun
if [ "$1" = "0" ]; then
    # Полное удаление: остановка и отключение
    for svc in $(systemctl list-units --type=service --no-legend 'autossh-tunnel-*' 2>/dev/null | awk '{print $1}'); do
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
    done

    systemctl stop tunnel-watchdog.timer 2>/dev/null || true
    systemctl disable tunnel-watchdog.timer 2>/dev/null || true
    systemctl stop tunnel-watchdog.service 2>/dev/null || true
    systemctl disable tunnel-watchdog.service 2>/dev/null || true
else
    # Обновление: только остановка, без disable
    for svc in $(systemctl list-units --type=service --no-legend 'autossh-tunnel-*' 2>/dev/null | awk '{print $1}'); do
        systemctl stop "$svc" 2>/dev/null || true
    done

    systemctl stop tunnel-watchdog.timer 2>/dev/null || true
    systemctl stop tunnel-watchdog.service 2>/dev/null || true
fi

%postun
if [ "$1" = "0" ]; then
    # Удаление сгенерированных systemd-юнитов
    rm -f /etc/systemd/system/autossh-tunnel-*.service
    rm -f /etc/systemd/system/tunnel-watchdog.service
    rm -f /etc/systemd/system/tunnel-watchdog.timer
    systemctl daemon-reload 2>/dev/null || true

    # Удаление health-check и logrotate
    rm -f /usr/local/bin/tunnel-health.sh
    rm -f /etc/logrotate.d/ssh-tunnel

    # Удаление логов
    rm -rf /var/log/ssh-tunnel

    # Удаление пользователя autosshtunnels
    if id autosshtunnels &>/dev/null; then
        userdel -r autosshtunnels 2>/dev/null || true
    fi
fi
