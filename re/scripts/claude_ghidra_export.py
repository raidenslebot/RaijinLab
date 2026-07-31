# Ghidra headless post-script (Jython/Ghidra API).
# Exports: full C decompilation of every function + a symbol/xref/string dump.
# Usage (invoked by analyzeHeadless via -postScript claude_ghidra_export.py <outdir>)
import os
from ghidra.app.decompiler import DecompInterface
from ghidra.util.task import ConsoleTaskMonitor

args = getScriptArgs()
outdir = args[0] if args else r"C:\Ascension\Workspace\RaijinLab\re\ghidra_out"
try:
    os.makedirs(outdir)
except Exception:
    pass

prog = currentProgram
name = prog.getName()
base = prog.getImageBase().getOffset()
fm = prog.getFunctionManager()

decomp = DecompInterface()
decomp.openProgram(prog)
monitor = ConsoleTaskMonitor()

# 1) Decompiled C for every function
dc_path = os.path.join(outdir, name + ".decompiled.c")
sym_path = os.path.join(outdir, name + ".symbols.txt")
with open(dc_path, "w") as dc, open(sym_path, "w") as sy:
    sy.write("# image_base=0x%x program=%s\n" % (base, name))
    funcs = list(fm.getFunctions(True))
    sy.write("# function_count=%d\n" % len(funcs))
    for f in funcs:
        ep = f.getEntryPoint().getOffset()
        sy.write("FUNC 0x%x %s\n" % (ep, f.getName()))
        dc.write("\n/* ==== %s @ 0x%x ==== */\n" % (f.getName(), ep))
        try:
            res = decomp.decompileFunction(f, 60, monitor)
            if res and res.decompileCompleted():
                dc.write(res.getDecompiledFunction().getC())
            else:
                dc.write("// <decompile failed: %s>\n" % (res.getErrorMessage() if res else "no result"))
        except Exception as e:
            dc.write("// <exception: %s>\n" % e)

# 2) Imports/symbols/xrefs to interesting APIs
st = prog.getSymbolTable()
imp_path = os.path.join(outdir, name + ".imports_xref.txt")
INTEREST = ["ReadProcessMemory","WriteProcessMemory","OpenProcess","VirtualProtect",
            "CreateToolhelp32Snapshot","Module32","Process32","NtQueryInformationProcess",
            "NtSetInformationThread","IsDebuggerPresent","CheckRemoteDebuggerPresent",
            "GetThreadContext","MapViewOfFile","CreateFileMapping","DeviceIoControl",
            "CryptHashData","CryptCreateHash","RtlComputeCrc32","send","recv","WSASend",
            "CreateFileW","CreateFileA","GetProcAddress","FindWindow","CreateProcess"]
with open(imp_path, "w") as ix:
    for s in st.getExternalSymbols():
        nm = s.getName()
        if any(k in nm for k in INTEREST):
            refs = getReferencesTo(s.getAddress())
            ix.write("IMPORT %s refs=%d\n" % (nm, len(refs)))
            for r in refs[:200]:
                ix.write("   from 0x%x\n" % r.getFromAddress().getOffset())

print("[claude_ghidra_export] wrote:\n  %s\n  %s\n  %s" % (dc_path, sym_path, imp_path))
