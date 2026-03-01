#!/usr/bin/env python3
"""Парсер config.yml → shell-переменные для eval."""
import sys
import yaml


def shell_escape(s):
    return str(s).replace("'", "'\\''")


def main():
    if len(sys.argv) < 2:
        print("Usage: parse-config.py <config.yml>", file=sys.stderr)
        sys.exit(1)

    with open(sys.argv[1]) as f:
        cfg = yaml.safe_load(f)

    remote = cfg.get("remote", {})
    ports = cfg.get("ports", [])

    # Скалярные параметры
    scalars = {
        "REMOTE_HOST": remote.get("host", ""),
        "REMOTE_USER": remote.get("user", "root"),
        "REMOTE_SSH_PORT": remote.get("ssh_port", 22),
        "TUNNEL_USER": cfg.get("tunnel_user", "tunnel"),
        "TUNNEL_PORT_OFFSET": cfg.get("tunnel_port_offset", 10000),
        "TUNNEL_SSH_PORT": cfg.get("tunnel_ssh_port", 22),
        "KEEPALIVE_INTERVAL": cfg.get("keepalive_interval", 30),
        "KEEPALIVE_COUNT": cfg.get("keepalive_count", 3),
        "AUTOSSH_POLL": cfg.get("autossh_poll", 600),
        "AUTOSSH_FIRST_POLL": cfg.get("autossh_first_poll", 30),
        "AUTOSSH_GATE_TIME": cfg.get("autossh_gate_time", 30),
        "MONITOR_CHECK_INTERVAL": cfg.get("monitor_check_interval", 60),
        "MONITOR_MAX_FAILURES": cfg.get("monitor_max_failures", 3),
        "RESTART_DELAY": cfg.get("restart_delay", 10),
        "LOG_DIR": cfg.get("log_dir", "/var/log/ssh-tunnel"),
    }

    for k, v in scalars.items():
        print(f"{k}='{shell_escape(v)}'")

    # Порты — массивы
    print(f"PORT_COUNT={len(ports)}")

    pub = []
    loc = []
    names = []
    target_hosts = []
    target_ports = []
    no_pp = []

    for p in ports:
        pub.append(str(p.get("public", 0)))
        loc.append(str(p.get("local", p.get("public", 0))))
        names.append(shell_escape(p.get("name", "")))

        target = p.get("target", "")
        if target and ":" in target:
            th, tp = target.rsplit(":", 1)
            target_hosts.append(shell_escape(th))
            target_ports.append(tp)
        else:
            target_hosts.append("")
            target_ports.append("0")

        no_pp.append("true" if p.get("no_proxy_protocol", False) else "false")

    print(f"PORT_PUBLIC=({' '.join(pub)})")
    print(f"PORT_LOCAL=({' '.join(loc)})")
    print(f"PORT_NAME=({' '.join(repr(n) for n in names)})")
    print(f"PORT_TARGET_HOST=({' '.join(repr(h) for h in target_hosts)})")
    print(f"PORT_TARGET_PORT=({' '.join(target_ports)})")
    print(f"PORT_NO_PROXY_PROTOCOL=({' '.join(no_pp)})")


if __name__ == "__main__":
    main()
