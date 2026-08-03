"""After /reload: wait for bridge rebind, then verify CastQueued wiring and
run a staged-cast end-to-end test through the native queue."""
import sys
import time

sys.path.insert(0, "tools")
import rlctl  # noqa: E402


def call(cmd, retries=8):
    last = None
    for _ in range(retries):
        try:
            return rlctl.call(cmd)
        except Exception as e:  # noqa: BLE001
            last = e
            time.sleep(0.5)
    raise last


def main():
    # wait for rebind (bridge back online)
    for i in range(10):
        try:
            v = call("return tostring(RaijinLab:RuntimeCall('GetRuntimeVersion'))", retries=2)
            if v:
                print("REBOUND version:", v)
                break
        except Exception:  # noqa: BLE001
            pass
        time.sleep(0.5)
    else:
        print("bridge did not rebind within 5s")
        return 1

    time.sleep(2.0)  # let addon finish loading + re-seal
    print("CastQueued (root)   :", call("return tostring(type(RaijinLab.CastQueued))"))
    print("Actions.CastQueued  :", call("return tostring(type(RaijinLab.Actions.CastQueued))"))
    print("queue status        :", call("return tostring(RaijinLab.Actions.CastQueueStatus())"))
    print("diag                :", call("return tostring(RaijinLab:RuntimeCall('NativeHookDiag'))"))
    # stage a self/ground cast through the Lua wrapper
    print("CastQueued(26573)   :", call("return tostring(RaijinLab.Actions.CastQueued(26573, nil, 0))"))
    time.sleep(0.4)
    print("queue status after  :", call("return tostring(RaijinLab.Actions.CastQueueStatus())"))
    time.sleep(0.3)
    print("diag after          :", call("return tostring(RaijinLab:RuntimeCall('NativeHookDiag'))"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
