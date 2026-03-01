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
Source1:        postinst.sh
Source2:        prerm.sh
Source3:        postrm.sh

%description
Manages multiple persistent SSH tunnels via a single YAML configuration.
Generates systemd services, health-check watchdog, and logrotate configs.

%prep
%setup -c

%install
cp -a usr etc %{buildroot}/

%files
%attr(755,root,root) /usr/sbin/%{name}
/usr/lib/%{name}/lib.sh
/usr/lib/%{name}/generate.sh
%attr(755,root,root) /usr/lib/%{name}/parse-config.py
%config(noreplace) /etc/%{name}/config.yml

%post
bash %{SOURCE1} configure

%preun
if [ "$1" = "0" ]; then
    bash %{SOURCE2} remove
fi

%postun
if [ "$1" = "0" ]; then
    bash %{SOURCE3} purge
fi
