#!/usr/bin/env python3
"""RaijinLab Unified Log Catalog — machine-readable index of EVERY diagnostic
source in the workspace. Consolidates all runtime/addon/game logs into a single
JSON catalog under C:\\Ascension\\Workspace\\logs\\catalog\\ so any agent or tool
can load the FULL system state in one read.

Every time a fix is attempted, run this first (or read the latest catalog JSON)
to see the complete picture before touching code.

Usage:
    python tools\\log_catalog.py              # rebuild catalog + print summary
    python tools\\log_catalog.py --json out   # write latest snapshot to file
    python tools\\log_catalog.py --since N     # only include events newer than N sec
"""
import json, os, re, sys, time, glob
from datetime import datetime, timedelta

ROOT = r"C:\Ascension\Workspace"
LOGS = [
    ("runtime",      os.path.join(ROOT, "logs", "runtime.log")),
    ("runtime_prev", os.path.join(ROOT, "logs", "runtime.prev.log")),
    ("runtime_stat", os.path.join(ROOT, "logs", "runtime_status.txt")),
    ("dev",          os.path.join(ROOT, "..", "Launcher", "resources", "ascension-live", "Logs", "raijinlab_dev.log")),
    ("rot_metrics",  os.path.join(ROOT, "..", "Launcher", "resources", "ascension-live", "Logs", "raijinlab_rot_metrics.log")),
    ("validate",     os.path.join(ROOT, "logs", "validate.log")),
    ("validate_rep", os.path.join(ROOT, "logs", "validate_report.txt")),
    ("sig",          os.path.join(ROOT, "logs", "sig_report.txt")),
    ("context",      os.path.join(ROOT, "logs", "context_fidelity.md")),
    ("module_smoke", os.path.join(ROOT, "logs", "module_smoke.md")),
]
GAME_LOGS_DIR = os.path.join(ROOT, "..", "Launcher", "resources", "ascension-live", "Logs")
CATALOG_DIR = os.path.join(ROOT, "logs", "catalog")

# Runtime structured format: HH:MM:SS.mmm|L|cat.sub|src:line|body
RT_RE = re.compile(r"^(\d{2}):(\d{2}):(\d{2})\.(\d{3})\|([TDIWE])\|([^|]+)\|([^|]+)\|(.*)$")
# DevLog format: SSS.SSS [cat] body  (GetTime since login)
DEV_RE = re.compile(r"^(\d+\.\d{3}) \[([^\]]+)\] (.*)$")


def file_mtime(p):
    try:
        return os.path.getmtime(p)
    except OSError:
        return 0.0


def tail_lines(p, n=200000):
    try:
        with open(p, "r", encoding="utf-8", errors="replace") as f:
            return f.readlines()
    except OSError:
        return []


def parse_runtime(line):
    m = RT_RE.match(line)
    if not m:
        return None
    h, mi, s, ms, lvl, cat, src, body = m.groups()
    return {
        "time": f"{h}:{mi}:{s}.{ms}",
        "level": lvl,
        "cat": cat,
        "src": src,
        "body": body.strip(),
    }


def parse_dev(line):
    m = DEV_RE.match(line)
    if not m:
        return None
    return {"time": m.group(1), "cat": m.group(2), "body": m.group(3).strip()}


def build_catalog(since=None):
    cat = {
        "generated_utc": datetime.utcnow().isoformat() + "Z",
        "workspace": ROOT,
        "sources": {},
        "events": [],
        "counts": {},
        "errors": [],
        "warnings": [],
        "facing_events": [],
        "cast_events": [],
        "crash_events": [],
    }
    cutoff = (time.time() - since) if since else 0.0

    for name, path in LOGS:
        mtime = file_mtime(path)
        if not os.path.exists(path):
            continue
        age = time.time() - mtime
        if cutoff and mtime < cutoff:
            continue
        lines = tail_lines(path)
        cat["sources"][name] = {
            "path": path,
            "size": os.path.getsize(path),
            "mtime": datetime.fromtimestamp(mtime).isoformat(),
            "age_sec": round(age, 1),
            "lines": len(lines),
        }
        n_err = n_warn = n_facing = n_cast = n_crash = 0
        for ln in lines:
            ev = parse_runtime(ln) if name.startswith("runtime") else parse_dev(ln)
            if not ev:
                continue
            ev["src_file"] = name
            cat["events"].append(ev)
            lvl = ev.get("level", "")
            body = ev.get("body", "")
            if lvl == "E":
                n_err += 1
                cat["errors"].append(ev)
            elif lvl == "W":
                n_warn += 1
                cat["warnings"].append(ev)
            if re.search(r"facing|in.front|ObjectIsFacing|0x7AC", body, re.I):
                n_facing += 1
                cat["facing_events"].append(ev)
            if re.search(r"cast|CastQueue|DRAIN|STAGE|FIRE|wire", body, re.I):
                n_cast += 1
                cat["cast_events"].append(ev)
            if re.search(r"crash|AV_|0xC0000005|fault|corrupt|garbage-eip", body, re.I):
                n_crash += 1
                cat["crash_events"].append(ev)
        cat["counts"][name] = {
            "events": len([e for e in cat["events"] if e.get("src_file") == name]),
            "errors": n_err, "warnings": n_warn,
            "facing": n_facing, "casts": n_cast, "crashes": n_crash,
        }

    # Game-side blizzard logs (errors/lua/crash)
    game = {}
    for g in glob.glob(os.path.join(GAME_LOGS_DIR, "*.txt")):
        base = os.path.basename(g)
        if not os.path.exists(g):
            continue
        sz = os.path.getsize(g)
        game[base] = {"size": sz, "mtime": datetime.fromtimestamp(os.path.getmtime(g)).isoformat()}
    cat["game_logs"] = game

    # Addon version / config snapshot
    cfg = os.path.join(GAME_LOGS_DIR, "raijinlab_config_1.lua")
    if os.path.exists(cfg):
        cat["addon_config"] = {"path": cfg, "size": os.path.getsize(cfg)}

    # Ordered by time where parseable, newest last
    return cat


def write_catalog(cat, latest=True):
    os.makedirs(CATALOG_DIR, exist_ok=True)
    fname = "latest.json" if latest else time.strftime("catalog_%Y%m%d_%H%M%S.json")
    path = os.path.join(CATALOG_DIR, fname)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(cat, f, indent=1)
    return path


def summarize(cat):
    total = len(cat["events"])
    errs = len(cat["errors"])
    warns = len(cat["warnings"])
    print(f"Catalog: {total} events, {errs} errors, {warns} warnings")
    print("Sources:")
    for name, info in cat["sources"].items():
        c = cat["counts"].get(name, {})
        print(f"  {name:14s} {info['lines']:>7d} lines  E={c.get('errors',0):>3d} W={c.get('warnings',0):>3d} "
              f"face={c.get('facing',0):>4d} cast={c.get('casts',0):>4d} age={info['age_sec']}s")
    if cat["errors"]:
        print("Latest errors:")
        for e in cat["errors"][-8:]:
            print(f"  [{e.get('src_file')}] {e.get('time')} {e.get('cat')}: {e.get('body','')[:120]}")
    if cat["facing_events"]:
        print("Latest facing events:")
        for e in cat["facing_events"][-5:]:
            print(f"  [{e.get('src_file')}] {e.get('time')} {e.get('cat')}: {e.get('body','')[:120]}")


if __name__ == "__main__":
    since = None
    out = None
    for i, a in enumerate(sys.argv[1:]):
        if a == "--json" and i + 2 < len(sys.argv):
            out = sys.argv[i + 2]
        if a == "--since":
            since = float(sys.argv[i + 2])
    c = build_catalog(since)
    if out:
        with open(out, "w", encoding="utf-8") as f:
            json.dump(c, f, indent=1)
        print(f"Wrote snapshot -> {out}")
    else:
        path = write_catalog(c)
        print(f"Wrote catalog -> {path}")
    summarize(c)
