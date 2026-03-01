#!/usr/bin/env python3
"""Парсер config.yml -> shell-переменные для eval.

Режимы:
  parse-config.py config.yml --count       # CONN_COUNT=2
  parse-config.py config.yml --globals     # TUNNEL_USER, LOG_DIR, defaults
  parse-config.py config.yml --connection N  # Все переменные connection N
"""
import re
import sys
import yaml


def shell_escape(s):
    return str(s).replace("'", "'\\''")


# Запрещённые символы в args (защита от shell-инъекций)
DANGEROUS_CHARS = re.compile(r'[;$`|><&()\\\']')


def extract_ports(args, flag):
    """Извлечь порты из -R/-L аргументов.

    Форматы:
      -R port:host:hostport          -> port
      -R bind:port:host:hostport     -> port
      -L port:host:hostport          -> port
      -L bind:port:host:hostport     -> port
    """
    ports = []
    for m in re.finditer(rf'{flag}\s+(\S+)', args):
        parts = m.group(1).split(':')
        if len(parts) == 3:      # port:host:hostport
            ports.append(parts[0])
        elif len(parts) == 4:    # bind:port:host:hostport
            ports.append(parts[1])
    return ports


def parse_server(server):
    """Парсинг server: user@host[:port] -> (user, host, port)."""
    if '@' not in server:
        return None, None, None
    user, hostport = server.split('@', 1)
    if ':' in hostport:
        host, port = hostport.rsplit(':', 1)
        return user, host, port
    return user, hostport, '22'


def validate(cfg):
    """Валидация конфигурации."""
    errors = []

    connections = cfg.get("connections")
    if not connections or not isinstance(connections, list):
        errors.append("'connections' должен быть непустым списком")
        return errors

    names = set()
    for idx, conn in enumerate(connections):
        prefix = f"connections[{idx}]"

        # Обязательные поля
        name = conn.get("name")
        if not name:
            errors.append(f"{prefix}: 'name' обязателен")
        elif name in names:
            errors.append(f"{prefix}: дублирующееся имя '{name}'")
        else:
            names.add(name)

        server = conn.get("server")
        if not server:
            errors.append(f"{prefix} ({name}): 'server' обязателен")
        else:
            user, host, port = parse_server(server)
            if not user or not host:
                errors.append(
                    f"{prefix} ({name}): 'server' должен быть в формате "
                    f"user@host или user@host:port"
                )
            if port and not port.isdigit():
                errors.append(
                    f"{prefix} ({name}): порт в 'server' должен быть числом"
                )

        args = conn.get("args")
        if not args:
            errors.append(f"{prefix} ({name}): 'args' обязателен")
        elif DANGEROUS_CHARS.search(args):
            errors.append(
                f"{prefix} ({name}): 'args' содержит запрещённые символы "
                f"(;$`|><&()\\'). Допускаются только SSH-аргументы."
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
        "MONITOR_INTERVAL": defaults.get("monitor_interval", 120),
        "MONITOR_MAX_FAILURES": defaults.get("monitor_max_failures", 3),
    }

    for k, v in scalars.items():
        print(f"{k}='{shell_escape(v)}'")


def print_count(cfg):
    """Вывод количества connections."""
    connections = cfg.get("connections", []) or []
    print(f"CONN_COUNT={len(connections)}")


def print_connection(cfg, index):
    """Вывод переменных конкретного connection."""
    connections = cfg.get("connections", []) or []
    defaults = cfg.get("defaults", {}) or {}

    if index < 0 or index >= len(connections):
        print(
            f"Ошибка: индекс {index} вне диапазона (0-{len(connections)-1})",
            file=sys.stderr,
        )
        sys.exit(1)

    conn = connections[index]
    user, host, port = parse_server(conn.get("server", ""))
    args = conn.get("args", "")

    # Скалярные параметры
    scalars = {
        "CONN_NAME": conn.get("name", ""),
        "CONN_HOST": host or "",
        "CONN_USER": user or "",
        "CONN_PORT": port or "22",
        "CONN_ARGS": args,
        "CONN_JUMP": conn.get("jump", ""),
        "KEEPALIVE_INTERVAL": conn.get(
            "keepalive_interval", defaults.get("keepalive_interval", 30)
        ),
        "KEEPALIVE_COUNT": conn.get(
            "keepalive_count", defaults.get("keepalive_count", 3)
        ),
        "RESTART_DELAY": conn.get(
            "restart_delay", defaults.get("restart_delay", 10)
        ),
        "MONITOR_INTERVAL": conn.get(
            "monitor_interval", defaults.get("monitor_interval", 120)
        ),
        "MONITOR_MAX_FAILURES": conn.get(
            "monitor_max_failures", defaults.get("monitor_max_failures", 3)
        ),
    }

    for k, v in scalars.items():
        print(f"{k}='{shell_escape(v)}'")

    # Извлечённые порты для health-check
    r_ports = extract_ports(args, '-R')
    l_ports = extract_ports(args, '-L')

    if r_ports:
        print(f"CONN_R_PORTS=({' '.join(r_ports)})")
    else:
        print("CONN_R_PORTS=()")

    if l_ports:
        print(f"CONN_L_PORTS=({' '.join(l_ports)})")
    else:
        print("CONN_L_PORTS=()")


def main():
    if len(sys.argv) < 3:
        print(
            "Usage: parse-config.py <config.yml> "
            "(--count | --globals | --connection N)",
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
    elif mode == "--connection":
        if len(sys.argv) < 4:
            print("--connection требует индекс (0, 1, ...)", file=sys.stderr)
            sys.exit(1)
        try:
            index = int(sys.argv[3])
        except ValueError:
            print(f"Неверный индекс: {sys.argv[3]}", file=sys.stderr)
            sys.exit(1)
        print_connection(cfg, index)
    else:
        print(f"Неизвестный режим: {mode}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
