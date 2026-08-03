"""Test a guid=0 cast (Consecration) through the g_currentL-fix path.
Verifies SafeNativeCast runs with no crash (doesn't need a target)."""
import sys
import time
import subprocess

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


for i in range(4):
    r = call("return tostring(RaijinLab:RuntimeCall('CastQueued', 26573, nil, 0))")
    print("consecration%d:" % (i + 1), r)
    time.sleep(1.2)
    alive = subprocess.run(["powershell", "-Command",
                            "if (Get-Process Ascension -ErrorAction SilentlyContinue) { 'ALIVE' } else { 'DOWN' }"],
                           capture_output=True, text=True).stdout.strip()
    print("  client:", alive)
    if alive != "ALIVE":
        print("CRASH DETECTED")
        sys.exit(1)
print("done - client survived guid=0 casts")
