import dis
import marshal
from pathlib import Path

PYC = Path(r"C:\Ascension\Workspace\RaijinLab\tests\__pycache__\run_suite_tests.cpython-312.pyc")
code = marshal.loads(PYC.read_bytes()[16:])
m = [c for c in code.co_consts if hasattr(c, "co_name") and c.co_name == "main"][0]

# the nested helper, so we know the parameter order
g = [c for c in m.co_consts if hasattr(c, "co_name") and c.co_name == "guard"]
if g:
    print("guard() params:", g[0].co_varnames[: g[0].co_argcount])

ins = list(dis.get_instructions(m))
start = next(i for i, x in enumerate(ins) if x.argval == "=== Source guards (regression checks) ===")
end = next(i for i, x in enumerate(ins) if isinstance(x.argval, str) and x.argval == "SOURCE-GUARD FAILED ")

calls, buf, arming = [], [], False
for x in ins[start:end]:
    if x.opname == "LOAD_FAST" and x.argval == "guard":
        arming, buf = True, []
        continue
    if not arming:
        continue
    if x.opname in ("LOAD_CONST", "LOAD_FAST"):
        buf.append(x.argval)
    elif x.opname == "CALL":
        calls.append(tuple(buf))
        arming, buf = False, []
    elif x.opname.startswith(("STORE", "POP_JUMP", "JUMP")):
        arming, buf = False, []

out = Path(r"C:\Ascension\Workspace\RaijinLab\tools\recovered\source_guards.py")
with out.open("w", encoding="utf-8") as f:
    f.write("# Recovered from the pre-truncation .pyc.\n")
    f.write("# Each entry: (check name, source variable, needle[, needle2...])\n")
    f.write("SOURCE_GUARDS = [\n")
    for c in calls:
        f.write(f"    {c!r},\n")
    f.write("]\n")

print("recovered", len(calls), "source guards ->", out)
for c in calls[:6]:
    print("  ", c)
