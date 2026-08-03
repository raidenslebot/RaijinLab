"""Confirm sustained stability: client alive + hook diagnostics."""
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


print("DIAG  :", call("return tostring(RaijinLab:RuntimeCall('NativeHookDiag'))"))
print("VERSION:", call("return tostring(RaijinLab:RuntimeCall('GetRuntimeVersion'))"))
