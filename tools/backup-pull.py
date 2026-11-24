#!/usr/bin/env python3
"""Mirror the FreeNova hosts into the private `backup-freenova` repository.

Incremental by design: the remote tree is listed first, and only files whose
size differs from the local copy (or that are missing) are downloaded. Files
that disappeared remotely are removed locally, so the checkout stays a mirror
rather than accumulating history.

The hosts this talks to reject `sftp -r` ("not a regular file" for every entry),
so transfers are per-file `get`/`rm` in one sftp session per batch.

Config (default ~/.config/freenova-watch/backup.json, keep it out of git):

    {
      "repo": "/home/ajxs/backups/freenova-backup",
      "askpass": "/home/ajxs/.config/freenova-watch/askpass.sh",
      "sources": [
        {"name": "game-server", "host": "193.70.81.30", "port": 2022,
         "user": "…", "passwordFile": "/home/…/s1.pass", "local": "game-server",
         "excludeDirs": ["steamapps", "Steam", ".steam", "steamcmd", "linux64", "valve"],
         "excludeGlobs": ["core.*", "*.so", "hlds_linux", "hlds_run", "hltv", "*.log.bak"]},
        …
      ]
    }

Exit codes: 0 nothing to do or pushed, 1 error.
"""
import fnmatch
import json
import os
import shlex
import subprocess
import sys
import time

DEFAULT_CONFIG = os.path.expanduser("~/.config/freenova-watch/backup.json")
DEFAULT_ASKPASS = os.path.expanduser("~/.config/freenova-watch/askpass.sh")
STATE = os.path.expanduser("~/.local/state/freenova-watch")


def log(msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def q(path):
    if any(c in path for c in " \t\"'\\"):
        return '"' + path.replace('"', '\\"') + '"'
    return path


def run_sftp(cfg, password, lines, timeout=3600):
    env = dict(os.environ)
    env["SFTP_PASS"] = password
    # askpass lives in the top-level config; a source dict may not carry it.
    env["SSH_ASKPASS"] = cfg.get("askpass") or DEFAULT_ASKPASS
    env["SSH_ASKPASS_REQUIRE"] = "force"
    p = subprocess.run(
        ["sftp", "-P", str(cfg["port"]), "-o", "StrictHostKeyChecking=accept-new",
         f'{cfg["user"]}@{cfg["host"]}'],
        input="\n".join(lines) + "\n", capture_output=True, text=True,
        env=env, timeout=timeout,
    )
    return p.stdout + p.stderr


def parse_blocks(out):
    blocks = []
    cur = None
    for line in out.splitlines():
        if line.startswith("sftp> "):
            cur = [line[len("sftp> "):], []]
            blocks.append(cur)
        elif cur is not None and not line.startswith("Connected to "):
            cur[1].append(line)
    return blocks


def entry_of(line):
    """One `ls -l` line -> (path, size, isdir), or None for anything else.

    These hosts' sftp-server answers `ls -l` with three tab-separated fields and
    no owner/group/date:

        -rw-r--r--\t463328\tcore.so

    The stock OpenSSH form ('-rw-r--r--  1 user group 1234 Nov 22 17:36 path')
    is accepted as well, so the parser does not depend on which server answers.
    """
    if not line or not (line[0] in "-d"):
        return None                                    # links/devices are skipped
    isdir = line[0] == "d"
    if "\t" in line:
        fields = line.split("\t")
        if len(fields) < 3:
            return None
        try:
            return "\t".join(fields[2:]).strip(), int(fields[1]), isdir
        except ValueError:
            return None
    parts = line.strip().split(None, 8)
    if len(parts) < 9:
        return None
    try:
        return parts[8], int(parts[4]), isdir
    except ValueError:
        return None


def walk(cfg, password, excludes_dirs, excludes_globs):
    """Return {remote_path: size} for every regular file under '/', depth first."""
    frontier = ["/"]
    files = {}
    while frontier:
        out = run_sftp(cfg, password, ["ls -l " + q(d) for d in frontier])
        nxt = []
        for cmd, lines in parse_blocks(out):
            if not cmd.startswith("ls -l "):
                continue
            base = cmd[len("ls -l "):].strip('"')
            for line in lines:
                e = entry_of(line)
                if not e:
                    continue
                name, size, isdir = e
                path = (base.rstrip("/") + "/" + name) if base != "/" else "/" + name
                leaf = name.rstrip("/")
                if isdir:
                    if leaf in excludes_dirs:
                        continue
                    if any(fnmatch.fnmatch(leaf, g) for g in excludes_globs):
                        continue
                    nxt.append(path)
                else:
                    if any(fnmatch.fnmatch(leaf, g) for g in excludes_globs):
                        continue
                    files[path] = size
        log(f"  {cfg['name']}: listed {len(frontier)} dir(s) -> {len(files)} files, {len(nxt)} to go")
        frontier = nxt
    return files


def local_path(cfg, remote):
    rel = remote[1:] if remote.startswith("/") else remote
    return os.path.join(cfg["root_local"], cfg["local"], rel)


def mirror(cfg, password, excludes_dirs, excludes_globs, batch=200):
    remote = walk(cfg, password, excludes_dirs, excludes_globs)
    want, keep = {}, set()
    for path, size in remote.items():
        lp = local_path(cfg, path)
        keep.add(lp)
        if not os.path.exists(lp) or os.path.getsize(lp) != size:
            want[path] = (lp, size)

    stale = []
    for dirpath, dirnames, filenames in os.walk(os.path.join(cfg["root_local"], cfg["local"])):
        dirnames[:] = [d for d in dirnames if d != ".git"]
        for f in filenames:
            lp = os.path.join(dirpath, f)
            if lp not in keep:
                stale.append(lp)

    log(f"  {cfg['name']}: {len(remote)} remote files, {len(want)} to fetch, {len(stale)} to remove")

    items = sorted(want.items())
    for i in range(0, len(items), batch):
        chunk = items[i:i + batch]
        cmds = []
        for path, (lp, _size) in chunk:
            os.makedirs(os.path.dirname(lp), exist_ok=True)
            cmds.append(f"get {q(path)} {q(lp)}")
        out = run_sftp(cfg, password, cmds)
        bad = [l for l in out.splitlines() if "not found" in l or "Failure" in l or "denied" in l]
        log(f"  {cfg['name']}: fetched {min(i + batch, len(items))}/{len(items)}"
            + (f" ({len(bad)} errors)" if bad else ""))
        for b in bad[:5]:
            log(f"    ! {b}")

    for lp in stale:
        try:
            os.remove(lp)
        except OSError:
            pass
    for root, dirs, _files in os.walk(os.path.join(cfg["root_local"], cfg["local"]), topdown=False):
        if not os.listdir(root) and root != os.path.join(cfg["root_local"], cfg["local"]):
            os.rmdir(root)
    return len(remote), len(want), len(stale)


def git(repo, *args, check=True):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, check=check)


def main():
    cfg_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_CONFIG
    with open(cfg_path) as fh:
        cfg = json.load(fh)
    os.makedirs(STATE, exist_ok=True)
    repo = cfg["repo"]
    os.makedirs(repo, exist_ok=True)

    total_files = total_fetch = total_stale = 0
    for src in cfg["sources"]:
        src["root_local"] = repo
        with open(src["passwordFile"]) as fh:
            password = fh.read().strip()
        excludes_dirs = set(src.get("excludeDirs", []))
        excludes_globs = src.get("excludeGlobs", [])
        log(f"== {src['name']} ({src['user']}@{src['host']})")
        n, fetched, stale = mirror(src, password, excludes_dirs, excludes_globs)
        total_files += n
        total_fetch += fetched
        total_stale += stale

    counts = {}
    for src in cfg["sources"]:
        base = os.path.join(repo, src["local"])
        c = 0
        for _root, _dirs, files in os.walk(base):
            c += len(files)
        counts[src["local"]] = c

    # SNAPSHOT.md carries the time the snapshot was taken, so rewriting it on a
    # run that changed nothing would make every night a commit of its own. Only
    # write it when the mirror actually moved files (or when it is missing).
    snapshot = os.path.join(repo, "SNAPSHOT.md")
    if total_fetch or total_stale or not os.path.exists(snapshot):
        with open(snapshot, "w") as fh:
            fh.write("# FreeNova backup snapshot\n\n")
            fh.write(f"Taken {time.strftime('%Y-%m-%d %H:%M:%S %Z')} by `tools/backup-pull.py`.\n\n")
            fh.write("| tree | files |\n| --- | --- |\n")
            for k, v in counts.items():
                fh.write(f"| `{k}/` | {v} |\n")
            fh.write("\nExcluded on purpose: engine/steam binaries, `steamapps/`, `Steam/`, "
                     "`valve/`, core dumps, `node_modules/`.\n")
    else:
        log("SNAPSHOT.md left as it is: no file changed")

    if not git(repo, "rev-parse", "--git-dir", check=False).returncode == 0:
        log("no git repository at " + repo)
        return 1

    status = git(repo, "status", "--porcelain").stdout.strip()
    if not status:
        log(f"no changes ({total_files} files mirrored, nothing new)")
        return 0

    git(repo, "add", "-A")
    msg = (f"backup: {time.strftime('%Y-%m-%d %H:%M')} "
           f"({total_fetch} changed, {total_stale} removed)")
    git(repo, "-c", "user.name=ajxs1992", "-c", "user.email=contsecundar099@gmai.com",
        "commit", "-q", "-m", msg)
    r = git(repo, "push", "-q", "origin", "HEAD", check=False)
    if r.returncode != 0:
        log("push failed: " + (r.stderr or r.stdout).strip()[:300])
        return 1
    log(f"pushed: {msg}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
