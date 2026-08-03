"""Poll the native frame tick hook rate via the live client bridge."""
import sys
import time

sys.path.insert(0, "tools")
import rlctl  # noqa: E402

for i in range(4):
    try:
        r = rlctl.call("return tostring(RaijinLab:RuntimeCall('FrameTickRate'))")
        print("poll%d:" % (i + 1), r)
    except Exception as e:  # noqa: BLE001
        print("poll%d ERR:" % (i + 1), e)
    time.sleep(0.5)
