"""Comprehensive static RE dump for RaijinLab notes."""
import re, json, struct, hashlib
from pathlib import Path
from collections import defaultdict

DUMP = Path(r"C:\Ascension\Workspace\RaijinLab\re\dumps")
OUT = Path(r"C:\Ascension\Workspace\RaijinLab\re")
ascii_re = re.compile(rb'[\x20-\x7e]{5,}')

def strings(data, minlen=5):
    return [m.group().decode('ascii') for m in re.finditer(rb'[\x20-\x7e]{%d,}' % minlen, data)]

def wide_strings(data, minlen=5):
    out = []
    for m in re.finditer((rb'(?:[\x20-\x7e]\x00){%d,}' % minlen), data):
        try:
            out.append(m.group().decode('utf-16-le'))
        except: pass
    return out

report = {}

# --- MMgr64 CLI / protocol ---
mm = (DUMP/"MMgr64.exe").read_bytes()
mm_s = strings(mm)
mm_w = wide_strings(mm)
report["MMgr64"] = {
    "interesting": [s for s in mm_s if any(k in s.lower() for k in [
        "memory","bridge","token","protocol","handle","table","pid","client","server",
        "map","alloc","command","reject","session","security","object","error","fail",
        "create","destroy","read","write","free","test","mmgr","ascension"
    ])],
    "wide_interesting": [s for s in mm_w if any(k in s.lower() for k in [
        "memory","bridge","token","mmgr","ascension","global","local"
    ])][:100],
}

# command-like format strings
report["MMgr64"]["formats"] = [s for s in mm_s if "{}" in s or "%s" in s or "%d" in s]

# --- Extensions MemoryBridge + spawn ---
ext = (DUMP/"Extensions.dll").read_bytes()
ext_s = strings(ext)
report["Extensions"] = {
    "mmgr_refs": [s for s in ext_s if "MMgr" in s or "MemoryBridge" in s or "object token" in s.lower() or "CreateProcess" in s],
    "anticheat": [s for s in ext_s if re.search(r"anticheat|Anticheat|DivxTac|Warden|DBG_", s, re.I)],
    "lua_natives": sorted(set(s for s in ext_s if re.match(r"^(Get|Set|Is|Toggle|Load|Save|Unit|Player|Spell|Item|Quest|Guild|Arena|BG|Map|World|Frame|C_)", s) and len(s)<80))[:400],
    "opcodes": sorted(set(s for s in ext_s if re.search(r"(MSG_|SMSG_|CMSG_|OPCODE|Opcode)", s)))[:200],
    "events": sorted(set(s for s in ext_s if re.search(r"ASCENSION_|PLAYER_|UNIT_|CHAT_|COMBAT_|GUILD_|QUEST_", s) and s.isupper() and "_" in s))[:300],
}

# --- DivxTac full managed surface ---
tac = (DUMP/"DivxTac.dll").read_bytes()
tac_s = strings(tac)
report["DivxTac"] = {
    "types": sorted(set(s for s in tac_s if re.search(r"AntiCheat|Banned|Detour|Managed|Process|Module|Detect|Handler|Service|GlobalOffset", s))),
    "all_interesting": [s for s in tac_s if re.search(r"[A-Z][a-z]+[A-Z]", s) and len(s)<120][:300],
}

# --- Ascension.exe IsLinuxClient / ScanDLL ---
asc = (DUMP/"Ascension.exe").read_bytes()
asc_s = strings(asc)
report["Ascension"] = {
    "linux_scan": [s for s in asc_s if re.search(r"IsLinux|ScanDLL|AddonVersion|Warden|Extensions|Divx", s, re.I)],
    "build": [s for s in asc_s if re.search(r"3\.3\.5|12340|build|WoW-code|patch-", s, re.I)][:40],
}

# Heuristic: MemoryBridge command names near "command"
mb_cmds = sorted(set(s for s in mm_s + ext_s if re.search(r"(?i)(alloc|free|read|write|table|create|destroy|map|unmap|handshake|ping|test|open|close|shutdown)", s) and len(s)<100))
report["mb_command_candidates"] = mb_cmds[:200]

# PE section summary
import pefile
for name in ["MMgr64.exe","Extensions.dll","DivxTac.dll","Ascension.exe"]:
    pe = pefile.PE(str(DUMP/name), fast_load=True)
    pe.parse_data_directories(directories=[pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_IMPORT']])
    imps = {}
    if hasattr(pe, 'DIRECTORY_ENTRY_IMPORT'):
        for e in pe.DIRECTORY_ENTRY_IMPORT:
            imps[e.dll.decode()] = [i.name.decode() if i.name else str(i.ordinal) for i in e.imports]
    report.setdefault("imports", {})[name] = imps
    pe.close()

outp = OUT / "deep_re_report.json"
outp.write_text(json.dumps(report, indent=2), encoding="utf-8")
print("Wrote", outp, "bytes", outp.stat().st_size)

# Human summary files
(OUT.parent / "notes" / "03_memorybridge.md").write_text(f"""# MemoryBridge Protocol — Static Map

## Roles
- **Server:** `MMgr64.exe` (x64) — launched by Extensions with client PID + object token
- **Client:** `Extensions.dll` inside Ascension.exe (x86)
- **Protocol version:** 3 (runtime log)

## Launch contract (from strings)
Extensions:
- `MMgr64.exe not found at: {{}}`
- `MMgr64.exe server process.`
- `MMgr64.exe without a valid object token.`
- `CreateProcessW` / `CreateProcess failed with error code: {{}}`

MMgr64:
- Requires **client PID** + **object token**
- Validates session ID match (rejects cross-session PID)
- Exits if client PID not running / terminated
- Security descriptor on mapping object
- Rejects malformed object token

## Operations observed (first run log)
1. Init server+client with protocol=3
2. Alloc 1024 bytes handle 1 → write → read → free (self-test)
3. command 3 → invalid_argument (benign test edge)
4. Create table handles 1..6 with fixed record sizes
5. Shutdown on client exit

## Table sizes (session)
| handle | records | record size | approx bytes |
|--------|---------|-------------|--------------|
| 1 | 6801 | 12 | 80 KB |
| 2 | 36548 | 12 | 428 KB |
| 3 | 127121 | 28 | 3.4 MB |
| 4 | 18561 | 116 | 2.1 MB |
| 5 | 562792 | 64 | 34.4 MB |
| 6 | 10667 | 180 | 1.9 MB |

Record counts resemble DBC/content table cardinalities — treat as **content/integrity mirrors** until proven otherwise.

## Format strings (server)
```
{chr(10).join(report['MMgr64']['formats'][:80])}
```

## Format strings (client MB)
```
{chr(10).join(report['Extensions']['mmgr_refs'][:60])}
```

## Security implications for RaijinLab Runtime
1. MMgr64 is a **trusted co-process** with OpenProcess on the game — AC may assume exclusive external access patterns.
2. Shared memory name/token is **session-bound**; spoofing without matching token fails.
3. Killing MMgr may crash or trip Extensions handshake paths.
4. Protocol mismatch is explicit hard-fail.

## Next dynamic RE
- Capture command line of MMgr64 at spawn
- Enumerate named file mappings while in-world
- Dump table headers for schema
- Frida/x32dbg on Extensions CreateProcessW
""", encoding="utf-8")
print("Wrote notes/03_memorybridge.md")

(OUT.parent / "notes" / "04_anticheat_map.md").write_text(f"""# Anticheat Map — DivxTac + Extensions

## DivxTac types / methods
```
{chr(10).join(report['DivxTac']['types'])}
```

## Extensions AC-related
```
{chr(10).join(report['Extensions']['anticheat'][:80])}
```

## Detection classes
1. **Process names** — BannedProccesses + server list
2. **Window titles** — DetectHackTitles
3. **Modules** — DetectHackModules + managed module normalization
4. **Debugger** — IsDebuggerPresent path + Extensions DBG_* tags
5. **Detours** — DetourMgr watches GlobalOffsets
6. **Server push** — AnticheatInitialize + BannedProcessList opcodes
7. **External** — MMgr64 linkage integrity

## Imports of note (DivxTac)
DeviceIoControl, CreateFileA, IsDebuggerPresent, WaitForSingleObjectEx, threads

## Imports of note (MMgr64)
OpenProcess, CreateFileMappingW, MapViewOfFile, IsDebuggerPresent, TerminateProcess

## RaijinLab Runtime design constraints
- Avoid blacklisted process/window names (maintain local denylist once captured dynamically)
- Prefer **manual map / atypical module** strategies only after dynamic validation — high risk
- Do not leave debugger flags set
- Do not patch DetourMgr-guarded prologue blindly
- Addon-only features need no inject; unlocker features do

## Dynamic capture checklist
- [ ] In-world module list (list DLLs in Ascension.exe)
- [ ] Packet log AC opcodes (if feasible)
- [ ] Title/process scan interval timing
- [ ] Whether Discord SDK / DXVK modules are allowlisted implicitly
""", encoding="utf-8")
print("Wrote notes/04_anticheat_map.md")

# Lua native dump for Ascension
natives_path = OUT.parent / "notes" / "05_ascension_lua_natives.md"
natives = report["Extensions"]["lua_natives"]
events = report["Extensions"]["events"]
natives_path.write_text(f"""# Ascension custom Lua surface (from Extensions.dll strings)

> Heuristic extraction — confirm in-game with `/dump` before relying.

## Likely natives / API names ({len(natives)})
```
{chr(10).join(natives)}
```

## Events ({len(events)})
```
{chr(10).join(events)}
```
""", encoding="utf-8")
print("Wrote", natives_path)
print("DONE")
