"""Test a GUID-targeted cast through the native-frame queue — the exact case
that caused 0x512B07 VM corruption when Spell_C ran under Lua.

1. read the player's current target guid
2. stage a GUID cast via CastQueued (Icy Touch 45477 / Death Coil or a dot)
3. confirm drain + al=1 + selection NOT stuck on victim + client alive
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
    # current target guid
    tgt = call("return UnitGUID('target') or 'none'")
    print("TARGET :", tgt)
    if not tgt or tgt == "none" or tgt == "0x0000000000000000":
        print("NO TARGET - cannot test GUID cast")
        return 1
    # stage a GUID cast at the target: Death Coil (spell depends on spec) -
    # use Icy Touch 45477 (ranged, no facing required) as a safe probe
    print("STAGE  :", call(
        "return tostring(RaijinLab:RuntimeCall('CastQueued', 45477, '%s', 0))" % tgt))
    time.sleep(0.5)
    print("QUEUE  :", call("return tostring(RaijinLab:RuntimeCall('CastQueueStatus'))"))
    time.sleep(0.5)
    print("DIAG   :", call("return tostring(RaijinLab:RuntimeCall('NativeHookDiag'))"))
    # did the client selection move off the victim? (acquire-off check)
    tgt2 = call("return UnitGUID('target') or 'none'")
    print("TARGET2:", tgt2)
    time.sleep(0.5)
    print("PING   :", call("return tostring(RaijinLab:RuntimeCall('Ping'))"))


if __name__ == "__main__":
    sys.exit(main())
