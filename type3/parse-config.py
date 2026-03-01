#!/usr/bin/env python3
"""Парсер config.yml -> shell-переменные для eval.

Режимы:
  parse-config.py config.yml --count       # HOST_COUNT=2
  parse-config.py config.yml --globals     # TUNNEL_USER, LOG_DIR, defaults
  parse-config.py config.yml --host N      # Все переменные хоста N
"""
import sys
import yaml


def shell_escape(s):
    return str(s).replace("'", "'\\''")


def validate(cfg):
    """Валидация конфигурации."""
    errors = []

    hosts = cfg.get("hosts")
    if not hosts or not isinstance(hosts, list):
        errors.append("'hosts' должен быть непустым списком")
        return errors

    names = set()
    all_local_ports = {}  # local_port -> (host_name, forward_name)

    for idx, host in enumerate(hosts):
        prefix = f"hosts[{idx}]"

        # Обязательные поля
        name = host.get("name")
        if not name:
            errors.append(f"{prefix}: 'name' обязателен")
        elif name in names:
            errors.append(f"{prefix}: дублирующееся имя хоста '{name}'")
        else:
            names.add(name)

        if not host.get("host"):
            errors.append(f"{prefix} ({name}): 'host' обязателен")

        tunnels = host.get("tunnels", []) or []
        forwards = host.get("forwards", []) or []

        if not tunnels and not forwards:
            errors.append(
                f"{prefix} ({name}): нужен хотя бы один tunnel или forward"
            )

        # Уникальность remote_port внутри хоста
        seen_rports = set()
        for ti, t in enumerate(tunnels):
            rp = t.get("remote_port")
            if rp is None:
                errors.append(
                    f"{prefix}.tunnels[{ti}]: 'remote_port' обязателен"
                )
            elif rp in seen_rports:
                errors.append(
                    f"{prefix}.tunnels[{ti}]: дублирующийся remote_port {rp}"
                )
            else:
                seen_rports.add(rp)

            if not t.get("local"):
                errors.append(
                    f"{prefix}.tunnels[{ti}]: 'local' обязателен"
                )

        # Уникальность local_port глобально
        for fi, f in enumerate(forwards):
            lp = f.get("local_port")
            if lp is None:
                errors.append(
                    f"{prefix}.forwards[{fi}]: 'local_port' обязателен"
                )
            elif lp in all_local_ports:
                prev_host, prev_name = all_local_ports[lp]
                errors.append(
                    f"{prefix}.forwards[{fi}]: дублирующийся local_port "
                    f"{lp} (уже используется в {prev_host}/{prev_name})"
                )
            else:
                all_local_ports[lp] = (name, f.get("name", f"forward-{fi}"))

            if not f.get("remote"):
                errors.append(
                    f"{prefix}.forwards[{fi}]: 'remote' обязателен"
                )

    return errors


def print_globals(cfg):
    """Вывод глобальных переменных."""
    defaults = cfg.get("defaults", {}) or {}

    scalars = {
        "TUNNEL_USER": cfg.get("tunnel_user", "tunnel"),
        "LOG_DIR": cfg.get("log_dir", "/var/log/ssh-tunnel"),
        "KEEPALIVE_INTERVAL": defaults.get("keepalive_interval", 30),
        "KEEPALIVE_COUNT": defaults.get("keepalive_count", 3),
        "RESTART_DELAY": defaults.get("restart_delay", 10),
        "MONITOR_CHECK_INTERVAL": defaults.get("monitor_check_interval", 120),
        "MONITOR_MAX_FAILURES": defaults.get("monitor_max_failures", 3),
    }

    for k, v in scalars.items():
        print(f"{k}='{shell_escape(v)}'")


def print_count(cfg):
    """Вывод количества хостов."""
    hosts = cfg.get("hosts", []) or []
    print(f"HOST_COUNT={len(hosts)}")


def print_host(cfg, index):
    """Вывод переменных конкретного хоста."""
    hosts = cfg.get("hosts", []) or []
    defaults = cfg.get("defaults", {}) or {}

    if index < 0 or index >= len(hosts):
        print(
            f"Ошибка: индекс хоста {index} вне диапазона (0-{len(hosts)-1})",
            file=sys.stderr,
        )
        sys.exit(1)

    host = hosts[index]

    # Скалярные параметры хоста
    scalars = {
        "HOST_NAME": host.get("name", ""),
        "REMOTE_HOST": host.get("host", ""),
        "REMOTE_USER": host.get("user", "root"),
        "REMOTE_SSH_PORT": host.get("ssh_port", 22),
        "JUMP_HOST": host.get("jump_host", ""),
        "KEEPALIVE_INTERVAL": host.get(
            "keepalive_interval", defaults.get("keepalive_interval", 30)
        ),
        "KEEPALIVE_COUNT": host.get(
            "keepalive_count", defaults.get("keepalive_count", 3)
        ),
        "RESTART_DELAY": host.get(
            "restart_delay", defaults.get("restart_delay", 10)
        ),
        "MONITOR_CHECK_INTERVAL": host.get(
            "monitor_check_interval",
            defaults.get("monitor_check_interval", 120),
        ),
        "MONITOR_MAX_FAILURES": host.get(
            "monitor_max_failures", defaults.get("monitor_max_failures", 3)
        ),
    }

    for k, v in scalars.items():
        print(f"{k}='{shell_escape(v)}'")

    # Обратные туннели (-R)
    tunnels = host.get("tunnels", []) or []
    print(f"TUNNEL_COUNT={len(tunnels)}")

    if tunnels:
        rports = []
        locals_ = []
        tnames = []
        for t in tunnels:
            rports.append(str(t.get("remote_port", 0)))
            locals_.append(f"'{shell_escape(t.get('local', ''))}'")
            tnames.append(f"'{shell_escape(t.get('name', ''))}'")

        print(f"TUNNEL_REMOTE_PORT=({' '.join(rports)})")
        print(f"TUNNEL_LOCAL=({' '.join(locals_)})")
        print(f"TUNNEL_NAME=({' '.join(tnames)})")

    # Прямые туннели (-L)
    forwards = host.get("forwards", []) or []
    print(f"FORWARD_COUNT={len(forwards)}")

    if forwards:
        lports = []
        remotes = []
        fnames = []
        for f in forwards:
            lports.append(str(f.get("local_port", 0)))
            remotes.append(f"'{shell_escape(f.get('remote', ''))}'")
            fnames.append(f"'{shell_escape(f.get('name', ''))}'")

        print(f"FORWARD_LOCAL_PORT=({' '.join(lports)})")
        print(f"FORWARD_REMOTE=({' '.join(remotes)})")
        print(f"FORWARD_NAME=({' '.join(fnames)})")


def main():
    if len(sys.argv) < 3:
        print(
            "Usage: parse-config.py <config.yml> "
            "(--count | --globals | --host N)",
            file=sys.stderr,
        )
        sys.exit(1)

    config_path = sys.argv[1]
    mode = sys.argv[2]

    with open(config_path) as f:
        cfg = yaml.safe_load(f)

    # Валидация при любом режиме
    errors = validate(cfg)
    if errors:
        for e in errors:
            print(f"ОШИБКА: {e}", file=sys.stderr)
        sys.exit(1)

    if mode == "--count":
        print_count(cfg)
    elif mode == "--globals":
        print_globals(cfg)
    elif mode == "--host":
        if len(sys.argv) < 4:
            print("--host требует индекс (0, 1, ...)", file=sys.stderr)
            sys.exit(1)
        try:
            index = int(sys.argv[3])
        except ValueError:
            print(f"Неверный индекс: {sys.argv[3]}", file=sys.stderr)
            sys.exit(1)
        print_host(cfg, index)
    else:
        print(f"Неизвестный режим: {mode}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
