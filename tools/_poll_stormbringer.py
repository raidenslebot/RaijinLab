# Poll the live client rapidly to catch Stormbringer's transient proc-buff.
# The user just procced; a single probe misses a short-duration buff. This
# samples the full aura list as fast as the pipe allows so we capture the exact
# spell id (and expiry) of whatever the proc applies.
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

# Lua: return the full UnitAuras list + a coarse timestamp.
code = ("R=RaijinLab; local a=R:RuntimeCall('UnitAuras',0); "
        "local b=R:RuntimeCall('AuraProbe',0); "
        "return a..'##'..b")

seen = {}
start = time.time()
for i in range(60):
    r = call(code)
    if "##" in r:
        auras, probe = r.split("##", 1)
        seen[auras] = seen.get(auras, 0) + 1
    sys.stdout.write("[%02d/%2.1fs] %s\n" % (i, time.time()-start, r[:300]))
    time.sleep(0.12)
print("\n--- distinct aura-list states seen ---")
for k, v in seen.items():
    print("%2dx  %s" % (v, k))
