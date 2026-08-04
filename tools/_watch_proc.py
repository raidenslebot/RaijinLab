# Live observer: capture the moment Stormbringer's proc fires 273057 client-side.
# Goals:
#  1. Confirm the proc is CLIENT-ROLLED: watch the client's CURRENT-CAST + current-spell
#     for a 273057 cast appearing while the user lands a direct damaging spell.
#  2. If the client locally begins a 273057 cast (appears in CastState/CurrentSpell)
#     with no server round-trip, Option 1 (hook the roll) is viable.
# Watch for: spell id 273057 (the proc bolt) being cast by the local player.
import struct, time, sys

PIPE = r"\\.\pipe\RaijinLab"

def call(code, timeout=8.0, retries=2):
    for _ in range(retries):
        try:
            f = open(PIPE, "r+b", buffering=0)
        except OSError as e:
            time.sleep(0.1); continue
        try:
            p = code.encode("utf-8", "replace")
            f.write(struct.pack("<I", len(p)) + p); f.flush()
            head = f.read(4)
            if len(head) != 4: return "(closed)"
            n = struct.unpack("<I", head)[0]
            body = b""
            while len(body) < n:
                c = f.read(n - len(body))
                if not c: break
                body += c
            return body.decode("utf-8", "replace")
        finally:
            f.close()
    return "(cannot open pipe)"

# Poll cast state + current spell + full aura list each ~40ms.
code = ("R=RaijinLab; "
        "local cs=R:RuntimeCall('CastState') or ''; "
        "local cur=R:RuntimeCall('CurrentSpell') or 0; "
        "local au=R:RuntimeCall('UnitAuras',0) or ''; "
        "return cs..'||'..tostring(cur)..'||'..au")

procs_seen = 0
start = time.time()
prev_cur = None
print("Watching for client-side 273057 proc cast... cast your direct damaging spells.")
print("-" * 70)
for i in range(2000):
    r = call(code)
    if "||" not in r:
        continue
    state, cur, au = r.split("||", 2)
    # CastState has no spell id, only attrs. CurrentSpell is the authoritative
    # 'last spell used/cast'. Watch it change to 273057/273058.
    if cur != prev_cur:
        if str(cur).strip() not in ("0", "nil", ""):
            print("[%6.1fs] CurrentSpell -> %s   %s" % (time.time()-start, cur, state))
        prev_cur = cur
    # Look for 273057/273058 anywhere in the cast state or auras.
    if "273057" in (state + au) or "273058" in (state + au):
        procs_seen += 1
        print("[%6.1fs] *** PROC SIGNAL *** cur=%s state=%s  (n=%d)" % (time.time()-start, cur, state, procs_seen))
        time.sleep(0.05)
    time.sleep(0.04)
print("-" * 70)
print("done: proc signals seen = %d" % procs_seen)
