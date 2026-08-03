"""Probe the live client: version, then NativeHook diagnostics + frame rate."""
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
    time.sleep(0.3)
    print("DIAG1 :", call("return tostring(RaijinLab:RuntimeCall('NativeHookDiag'))"))
    time.sleep(0.5)
    print("DIAG2 :", call("return tostring(RaijinLab:RuntimeCall('NativeHookDiag'))"))
    # install the frame tick hook (force=true, dev only)
    print("INSTALL:", call("return tostring(RaijinLab:RuntimeCall('NativeHookTest'))"))
    time.sleep(0.3)
    print("DIAG3 :", call("return tostring(RaijinLab:RuntimeCall('NativeHookDiag'))"))
    # measure frame rate non-blocking over a few polls
    time.sleep(0.6)
    print("RATE1 :", call("return tostring(RaijinLab:RuntimeCall('FrameTickRate'))"))
    time.sleep(0.6)
    print("RATE2 :", call("return tostring(RaijinLab:RuntimeCall('FrameTickRate'))"))
    time.sleep(0.6)
    print("RATE3 :", call("return tostring(RaijinLab:RuntimeCall('FrameTickRate'))"))
    print("DIAG4 :", call("return tostring(RaijinLab:RuntimeCall('NativeHookDiag'))"))


if __name__ == "__main__":
    main()
