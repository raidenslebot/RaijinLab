"""Send /reload (ReloadUI) through the IPC pipe to load newly deployed Lua."""
import sys
import time

sys.path.insert(0, "tools")
import rlctl  # noqa: E402

print("sending ReloadUI via pipe...")
try:
    # ReloadUI tears down the VM; the reply may not come back, which is fine.
    out = rlctl.call("ReloadUI()", timeout=5.0, retries=1)
    print("reply:", out)
except Exception as e:  # noqa: BLE001
    print("no reply (expected during reload):", e)
print("reload sent - waiting for rebind...")
