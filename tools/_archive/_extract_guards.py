import dis
import marshal
from pathlib import Path

PYC = Path(r"C:\Ascension\Workspace\RaijinLab\tests\__pycache__\run_suite_tests.cpython-312.pyc")
code = marshal.loads(PYC.read_bytes()[16:])
m = [c for c in code.co_consts if hasattr(c, "co_name") and c.co_name == "main"][0]

tuples = [c for c in m.co_consts if isinstance(c, tuple)]
print("tuple constants in main():", len(tuples))
for t in tuples:
    if all(isinstance(x, str) for x in t) and len(t) > 2:
        print("  ", t[:4], "..." if len(t) > 4 else "")

# Fall back to reading BUILD_TUPLE groupings from the instruction stream.
ins = list(dis.get_instructions(m))
groups, buf = [], []
for x in ins:
    if x.opname == "LOAD_CONST" and isinstance(x.argval, str):
        buf.append(x.argval)
    elif x.opname == "BUILD_TUPLE" and x.arg == 3 and len(buf) >= 3:
        groups.append(tuple(buf[-3:]))
        buf = []
    elif x.opname not in ("LOAD_CONST",):
        if x.opname.startswith(("STORE", "CALL", "BUILD_LIST")):
            buf = []

print("\n3-tuples built in main() (candidate source guards):", len(groups))
out = Path(r"C:\Ascension\Workspace\RaijinLab\tools\recovered\source_guards.py")
with out.open("w", encoding="utf-8") as f:
    f.write("# Recovered source-guard triples: (relative path, check name, needle)\n")
    f.write("SOURCE_GUARDS = [\n")
    for g in groups:
        f.write(f"    {g!r},\n")
    f.write("]\n")
for g in groups[:40]:
    print("  ", g)
print("\nwritten to", out)
