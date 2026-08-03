"""Verify the addon loaded the CastQueued wiring and test a staged cast."""
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


print("RaijinLab.CastQueued      :", call("return tostring(type(RaijinLab.CastQueued))"))
print("Actions.CastQueued        :", call("return tostring(type(RaijinLab.Actions.CastQueued))"))
print("Actions.CastQueueStatus   :", call("return tostring(type(RaijinLab.Actions.CastQueueStatus))"))
print("queue status              :", call("return tostring(RaijinLab.Actions.CastQueueStatus())"))
# stage a self/ground cast through the Lua wrapper (Consecration)
print("CastQueued(26573)         :", call("return tostring(RaijinLab.Actions.CastQueued(26573, nil, 0))"))
time.sleep(0.4)
print("queue status after        :", call("return tostring(RaijinLab.Actions.CastQueueStatus())"))
print("diag                      :", call("return tostring(RaijinLab:RuntimeCall('NativeHookDiag'))"))
