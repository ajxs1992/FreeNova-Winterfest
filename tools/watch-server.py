#!/usr/bin/env python3
"""Watch the FreeNova game servers and shout when one dies.

A Host_Error or a segfault just restarts the container; nothing tells anyone.
This daemon probes each server over A2S every minute, keeps a small state file,
and posts to a Discord webhook when a server goes down (two consecutive misses),
when it comes back, and once a day with a digest.

Config (default ~/.config/freenova-watch/watch.json, outside the repo):

    {
      "interval": 60,
      "fail_threshold": 2,
      "digest_hour": 9,
      "webhook": "https://discord.com/api/webhooks/…",
      "servers": [
        {"name": "CS 1.6 Classic", "host": "193.70.81.30", "port": 27015}
      ]
    }

State and the log live in ~/.local/state/freenova-watch/.
"""
import json
import os
import socket
import struct
import sys
import time
import urllib.request

DEFAULT_CONFIG = os.path.expanduser("~/.config/freenova-watch/watch.json")
STATE_DIR = os.path.expanduser("~/.local/state/freenova-watch")
STATE_FILE = os.path.join(STATE_DIR, "state.json")
LOG_FILE = os.path.join(STATE_DIR, "watch.log")


def log(msg, file=True):
    """Print to the journal, and append to watch.log unless this is a heartbeat.

    Every probe is printed so `journalctl -u freenova-watch` shows the server is
    actually being read; only state changes (down, recovered, digest) go into
    watch.log, which is meant to stay short enough to read.
    """
    os.makedirs(STATE_DIR, exist_ok=True)
    line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
    print(line, flush=True)
    if file:
        # 0600, not the umask: watch.log records probe results and webhook errors.
        fd = os.open(LOG_FILE, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, "a") as fh:
            fh.write(line + "\n")


def a2s_info(host, port, timeout=4.0):
    """Return dict(name, map, players, max) or None when unreachable."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.sendto(b"\xff\xff\xff\xffTSource Engine Query\x00", (host, port))
        data, _ = s.recvfrom(4096)
    except OSError:
        return None
    finally:
        s.close()

    def cstr(b, off):
        end = b.index(b"\x00", off)
        return b[off:end].decode("latin1"), end + 1

    try:
        i = 4
        kind = data[i:i + 1]
        i += 1
        if kind == b"m":            # GoldSrc
            _addr, i = cstr(data, i)
            name, i = cstr(data, i)
            mapname, i = cstr(data, i)
            _folder, i = cstr(data, i)
            _game, i = cstr(data, i)
            players, maxp = data[i], data[i + 1]
        elif kind == b"I":          # Source
            i += 1
            name, i = cstr(data, i)
            mapname, i = cstr(data, i)
            _folder, i = cstr(data, i)
            _game, i = cstr(data, i)
            i += 2
            players, maxp = data[i], data[i + 1]
        else:
            return None
    except (IndexError, ValueError):
        return None
    return {"name": name, "map": mapname, "players": players, "max": maxp}


def notify(webhook, content):
    if not webhook:
        log("(no webhook configured) " + content.replace("\n", " | ")[:200])
        return
    body = json.dumps({"content": content[:1900]}).encode()
    req = urllib.request.Request(webhook, data=body,
                                 headers={"Content-Type": "application/json",
                                          "User-Agent": "freenova-watch/1.0"})
    try:
        urllib.request.urlopen(req, timeout=10).read()
    except Exception as exc:                      # noqa: BLE001 - never die on a webhook
        log(f"webhook failed: {exc}")


def load_state():
    try:
        with open(STATE_FILE) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def save_state(state):
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        json.dump(state, fh, indent=1)
    os.replace(tmp, STATE_FILE)


def main():
    cfg_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_CONFIG
    with open(cfg_path) as fh:
        cfg = json.load(fh)
    interval = int(cfg.get("interval", 60))
    threshold = int(cfg.get("fail_threshold", 2))
    webhook = cfg.get("webhook", "")
    digest_hour = int(cfg.get("digest_hour", 9))

    log(f"watching {len(cfg['servers'])} server(s) every {interval}s")
    state = load_state()
    last_digest_day = state.get("last_digest_day")

    while True:
        now = time.time()
        for srv in cfg["servers"]:
            key = f"{srv['host']}:{srv['port']}"
            st = state.setdefault(key, {"fails": 0, "down": False, "down_since": None,
                                        "since": None, "probes": 0, "downs": 0,
                                        "last": None, "name": srv["name"]})
            info = a2s_info(srv["host"], int(srv["port"]))
            st["probes"] += 1
            if info:
                if st["down"]:
                    mins = int((now - (st["down_since"] or now)) / 60)
                    notify(webhook, f"🟢 **{srv['name']} is back** after ~{mins} min "
                                    f"(`{info['map']}`, {info['players']}/{info['max']}).")
                    log(f"{srv['name']}: recovered after {mins} min")
                    st["down"] = False
                    st["down_since"] = None
                if st["since"] is None:
                    st["since"] = now
                st["fails"] = 0
                st["last"] = info
                log(f"{srv['name']}: up — {info['map']} {info['players']}/{info['max']} "
                    f"(A2S {key}, probe {st['probes']})", file=False)
            else:
                st["fails"] += 1
                if not st["down"] and st["fails"] < threshold:
                    log(f"{srv['name']}: no A2S answer ({st['fails']} in a row) on {key}",
                        file=False)
                if not st["down"] and st["fails"] >= threshold:
                    st["down"] = True
                    st["down_since"] = now
                    st["downs"] += 1
                    last = st.get("last") or {}
                    notify(webhook, f"🔴 **{srv['name']} is not answering** "
                                    f"({st['fails']} failed A2S probes on `{key}`). "
                                    f"Last seen: `{last.get('map', '?')}` "
                                    f"{last.get('players', '?')}/{last.get('max', '?')}.")
                    log(f"{srv['name']}: DOWN after {st['fails']} failed probes")

        today = time.strftime("%Y-%m-%d")
        if time.localtime().tm_hour >= digest_hour and last_digest_day != today:
            lines = [f"**FreeNova daily digest — {today}**"]
            for srv in cfg["servers"]:
                key = f"{srv['host']}:{srv['port']}"
                st = state.get(key, {})
                last = st.get("last") or {}
                lines.append(
                    f"• {srv['name']}: {st.get('probes', 0)} probes, "
                    f"{st.get('downs', 0)} down event(s), "
                    f"now {'DOWN' if st.get('down') else (last.get('map', 'up'))} "
                    f"{last.get('players', '?')}/{last.get('max', '?')}")
            notify(webhook, "\n".join(lines))
            last_digest_day = today
            state["last_digest_day"] = today
            for srv in cfg["servers"]:
                key = f"{srv['host']}:{srv['port']}"
                if key in state:
                    state[key]["probes"] = 0
                    state[key]["downs"] = 0
            log("digest sent")

        save_state(state)
        time.sleep(interval)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        pass
