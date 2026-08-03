"""Test the g_currentL-fix: GUID cast through the direct path, repeated, and
confirm the client does NOT crash (the exact 0x512B07 trigger)."""
import sys
import time

sys.path.insert(0, "tools")
import rlctl  # noqa: E402


def call(cmd, retries=5):
    last = None
    for _ in range(retries):
        try:
            return rlctl.call(cmd)
        except Exception as e:  # noqa: BLE001
            last = e
            time.sleep(0.3)
    raise last


tgt = call("return UnitGUID('target') or 'none'")
print("target:", tgt)
if not tgt or tgt == "none" or tgt == "0x0000000000000000":
    print("NO TARGET - cannot test guid cast")
    sys.exit(1)

import subprocess
for i in range(5):
    r = call("return tostring(RaijinLab:RuntimeCall('CastQueued', 45477, '%s', 2))" % tgt)
    print("cast%d 45477:" % (i + 1), r)
    time.sleep(1.2)
    # check client alive
    alive = subprocess.run(["powershell", "-Command",
                            "if (Get-Process Ascension -ErrorAction SilentlyContinue) { 'ALIVE' } else { 'DOWN' }"],
                           capture_output=True, text=True).stdout.strip()
    print("  client:", alive)
    if alive != "ALIVE":
        print("CRASH DETECTED")
        sys.exit(1)
print("5 GUID casts, client survived -> g_currentL fix holds")
