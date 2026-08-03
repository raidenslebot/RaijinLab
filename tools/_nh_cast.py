"""Live test of the native-frame cast queue pipeline:
1. install frame hook (force, dev)
2. confirm hook active + draining context
3. stage a real self/ground cast via CastQueued (NO Spell_C from Lua)
4. poll CastQueueStatus + NativeHookDiag to confirm the native hook drained it
5. confirm client still alive (no crash) + runtime log shows DRAIN lines
"""
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


def main():
    print("VERSION:", call("return tostring(RaijinLab:RuntimeCall('GetRuntimeVersion'))"))
    print("INSTALL:", call("return tostring(RaijinLab:RuntimeCall('NativeHookTest'))"))
    time.sleep(0.5)
    print("DIAG   :", call("return tostring(RaijinLab:RuntimeCall('NativeHookDiag'))"))
    # Stage a self/ground cast. 26573 = Consecration (ground, guid=0) - known stable.
    # guid arg 3 = "0" (explicit zero, not intended-guid) -> self/ground path.
    print("STAGE  :", call(
        "return tostring(RaijinLab:RuntimeCall('CastQueued', 26573, '0', 0))"))
    time.sleep(0.3)
    print("QUEUE  :", call("return tostring(RaijinLab:RuntimeCall('CastQueueStatus'))"))
    time.sleep(0.3)
    print("QUEUE2 :", call("return tostring(RaijinLab:RuntimeCall('CastQueueStatus'))"))
    time.sleep(0.3)
    print("DIAG   :", call("return tostring(RaijinLab:RuntimeCall('NativeHookDiag'))"))


if __name__ == "__main__":
    main()
