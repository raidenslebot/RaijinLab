"""Consolidate RaijinLab rotations across WoW accounts.

WHY THIS EXISTS
---------------
WoW stores SavedVariables PER ACCOUNT, at
    WTF/Account/<account>/SavedVariables/RaijinLab.lua
Every account folder has its own independent copy of RaijinLabDB. A rotation built
while logged into one account simply does not exist in another - which looks
exactly like "my rotations keep getting deleted", even though nothing was lost.

This tool finds every rotation across every account and (with --apply) copies the
missing ones into the accounts that lack them, so the same set is available
everywhere.

SAFETY
------
  * REFUSES to run while the client is open. WoW holds the whole DB in memory and
    rewrites the file wholesale on logout, so any edit made now would be silently
    discarded - or worse, half-applied.
  * Dry run by default. --apply is required to write anything.
  * Timestamped backup of every file it touches, before touching it.
  * ADDITIVE ONLY. A rotation already present in the target is never overwritten,
    so the local version always wins and nothing can be clobbered by a stale copy.
  * TEXT SPLICE, not parse-and-reserialize. Only the exact byte range of the
    rotations table is modified; every other setting in the file is preserved
    byte-for-byte. A full Lua round-trip would risk mangling data this tool has no
    business touching.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import time

WTF = r"C:\Ascension\Launcher\resources\ascension-live\WTF\Account"
CLIENT_NAMES = ("Ascension", "WoW", "Wow")


def client_running():
    """True if the game is open. Editing SavedVariables underneath it is futile."""
    try:
        out = subprocess.run(
            ["powershell", "-NoProfile", "-Command",
             "Get-Process -Name " + ",".join("'%s'" % n for n in CLIENT_NAMES) +
             " -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name"],
            capture_output=True, text=True, timeout=30)
        return bool(out.stdout.strip())
    except Exception:
        return False        # cannot tell; the --force escape hatch covers this


def accounts(root=WTF):
    if not os.path.isdir(root):
        return []
    found = []
    for name in sorted(os.listdir(root)):
        p = os.path.join(root, name, "SavedVariables", "RaijinLab.lua")
        if os.path.isfile(p):
            found.append((name, p))
    return found


def find_block(text, key, depth=1):
    """Byte range of a `["key"] = { ... }` table at the given indent depth.

    Brace counting is string-aware: a rotation name containing a brace, or a Lua
    escape like \\", would otherwise throw the depth count off and truncate the
    splice mid-table.
    """
    pat = re.compile(r'^' + ('\t' * depth) + re.escape('["%s"]' % key) + r'\s*=\s*\{', re.M)
    m = pat.search(text)
    if not m:
        return None
    i = m.end() - 1                      # sits on the opening brace
    depth_n, in_str, esc = 0, False, False
    while i < len(text):
        c = text[i]
        if in_str:
            if esc:
                esc = False
            elif c == '\\':
                esc = True
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c == '{':
            depth_n += 1
        elif c == '}':
            depth_n -= 1
            if depth_n == 0:
                return m.start(), i + 1, m.end()
        i += 1
    return None


def entries(block_text):
    """Top-level `["name"] = { ... }` entries inside a rotations table body."""
    out = {}
    for m in re.finditer(r'^\t\t\["([^"]+)"\]\s*=\s*\{', block_text, re.M):
        name = m.group(1)
        i = m.end() - 1
        depth, in_str, esc = 0, False, False
        while i < len(block_text):
            c = block_text[i]
            if in_str:
                if esc:
                    esc = False
                elif c == '\\':
                    esc = True
                elif c == '"':
                    in_str = False
            elif c == '"':
                in_str = True
            elif c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    out[name] = block_text[m.start():i + 1]
                    break
            i += 1
    return out


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--apply", action="store_true",
                    help="actually write (default is a dry run)")
    ap.add_argument("--force", action="store_true",
                    help="skip the running-client check (you are on your own)")
    ap.add_argument("--wtf", default=WTF, help="path to WTF/Account")
    args = ap.parse_args()

    accts = accounts(args.wtf)
    if not accts:
        print("No RaijinLab.lua found under " + args.wtf)
        return 1

    # ---- collect every rotation, and note where each one lives ----
    catalog = {}                 # name -> body text
    owners = {}                  # name -> [accounts]
    per_acct = {}                # account -> set(names)
    for acct, path in accts:
        text = read(path)
        span = find_block(text, "rotations")
        names = set()
        if span:
            start, end, body_at = span
            found = entries(text[body_at:end])
            for n, body in found.items():
                names.add(n)
                owners.setdefault(n, []).append(acct)
                catalog.setdefault(n, body)
        per_acct[acct] = names

    print("=" * 68)
    print("ROTATIONS FOUND ACROSS %d ACCOUNT(S)" % len(accts))
    print("=" * 68)
    for name in sorted(catalog):
        print("  %-24s in: %s" % (name, ", ".join(owners[name])))
    print()
    for acct, names in per_acct.items():
        missing = sorted(set(catalog) - names)
        print("  %-32s has %d, missing: %s"
              % (acct, len(names), ", ".join(missing) if missing else "-"))
    print()

    todo = {a: sorted(set(catalog) - n) for a, n in per_acct.items()}
    todo = {a: m for a, m in todo.items() if m}
    if not todo:
        print("Every account already has every rotation. Nothing to do.")
        return 0

    if not args.apply:
        print("DRY RUN - nothing written. Re-run with --apply to merge.")
        return 0

    if client_running() and not args.force:
        print("REFUSING: the game is running. WoW rewrites SavedVariables from")
        print("memory when you log out, so anything written now would be thrown")
        print("away. Fully exit the client, then run this again.")
        return 2

    stamp = time.strftime("%Y%m%d-%H%M%S")
    for acct, path in accts:
        missing = todo.get(acct)
        if not missing:
            continue
        text = read(path)
        span = find_block(text, "rotations")
        if not span:
            print("  SKIP %s - no rotations table to splice into" % acct)
            continue
        start, end, body_at = span

        bak = path + ".premerge-" + stamp
        shutil.copy2(path, bak)

        # Splice just before the table's closing brace. Everything outside this
        # range is untouched.
        close = text.rindex("}", body_at, end)
        # catalog[n] is the entry verbatim, from its leading tabs through its
        # closing brace (no trailing comma - entries() stops at the brace).
        insert = "".join(catalog[n] + ",\n" for n in missing)
        merged = text[:close] + insert + text[close:]
        with open(path, "w", encoding="utf-8") as f:
            f.write(merged)
        print("  %s: added %s  (backup: %s)"
              % (acct, ", ".join(missing), os.path.basename(bak)))

    print()
    print("Done. Log in and check /raijin rotation - your rotations should all be")
    print("present on every account now.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
