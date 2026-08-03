"""Test the no-acquire cast path by staging a cast with flag 16 (CAST_NO_ACQUIRE).
Only the NEW runtime logs 'DRAIN-noacquire' — if we see it, the new build owns
the bridge; if not, the old build still owns it and we need a client restart."""
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


# Get current target
tgt = call("return UnitGUID('target') or 'none'")
print("target:", tgt)
if not tgt or tgt == "none" or tgt == "0x0000000000000000":
    print("NO TARGET - cannot test no-acquire guid cast")
    sys.exit(1)
# Stage a cast with CAST_NO_ACQUIRE (16) at the target
print("stage(flag16):", call("return tostring(RaijinLab:RuntimeCall('CastQueued', 45477, '%s', 16))" % tgt))
time.sleep(0.6)
print("status:", call("return tostring(RaijinLab.Actions.CastQueueStatus())"))
