"""Check which runtime owns the bridge and whether zero-frame-acquire commands live."""
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


print("version     :", call("return tostring(RaijinLab:RuntimeCall('GetRuntimeVersion'))"))
print("has CastQueued:", call("return tostring(type(RaijinLab.Actions.CastQueued))"))
print("status      :", call("return tostring(RaijinLab.Actions.CastQueueStatus())"))
print("diag        :", call("return tostring(RaijinLab:RuntimeCall('NativeHookDiag'))"))
