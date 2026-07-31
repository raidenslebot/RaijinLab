export const meta = {
  name: 'raijin-ac-re-v2',
  description: 'Comprehensive Ascension AC RE for RaijinLab: deepen 6 subsystems → adversarial verify → extract JSON + x32dbg BP script → synthesize breakpoint catalog + evasion + handoff → completeness critic',
  phases: [
    { title: 'Deepen',     detail: '6 per-subsystem RE agents read Ghidra/dnSpy/capstone, write notes 11b-11f' },
    { title: 'Verify',     detail: 'adversarial skeptic per finding — refute integrity_relevance' },
    { title: 'Extract',    detail: 'JSON data + x32dbg BP script + yara + frida probe spec' },
    { title: 'Synthesize', detail: '12_breakpoint_catalog + 13_evasion_strategy + HANDOFF_claude' },
    { title: 'Critique',   detail: 'completeness gaps → patch round' },
  ],
}

const PATHS = `
============================================================
BINARIES (offline, hashes match live)
============================================================
  Extensions.dll : C:\\Ascension\\Workspace\\RaijinLab\\re\\dumps\\Extensions.dll   (x86, image base 0x10000000, .vm_sec VMProtect 33KB, .text 11.6MB normal-native)
  DivxTac.dll    : C:\\Ascension\\Workspace\\RaijinLab\\re\\dumps\\DivxTac.dll      (x86, C++/CLI mixed, image base 0x10000000)
  MMgr64.exe     : C:\\Ascension\\Workspace\\RaijinLab\\re\\dumps\\MMgr64.exe       (x64, image base 0x140000000)
  Ascension.exe  : C:\\Ascension\\Workspace\\RaijinLab\\re\\dumps\\Ascension.exe    (x86, image base 0x400000, stock 3.3.5.12340 lineage + custom)
  DivxDecoder.dll: C:\\Ascension\\Workspace\\RaijinLab\\re\\dumps\\DivxDecoder.dll  (x86, timestamp 2004)

============================================================
PRE-BAKED SOURCE (READ THESE FIRST — don't regen)
============================================================
  Ghidra decomp (COMPLETE for all 3 AC binaries):
    C:\\Ascension\\Workspace\\RaijinLab\\re\\ghidra_out\\DivxTac.dll.decompiled.c   (44KB, note: __clrcall bodies show <decompile failed>; use dnSpy .cs for managed methods)
    C:\\Ascension\\Workspace\\RaijinLab\\re\\ghidra_out\\DivxTac.dll.symbols.txt
    C:\\Ascension\\Workspace\\RaijinLab\\re\\ghidra_out\\DivxTac.dll.imports_xref.txt
    C:\\Ascension\\Workspace\\RaijinLab\\re\\ghidra_out\\MMgr64.exe.decompiled.c    (34KB)
    C:\\Ascension\\Workspace\\RaijinLab\\re\\ghidra_out\\MMgr64.exe.symbols.txt
    C:\\Ascension\\Workspace\\RaijinLab\\re\\ghidra_out\\MMgr64.exe.imports_xref.txt
    C:\\Ascension\\Workspace\\RaijinLab\\re\\ghidra_out\\Extensions.dll.decompiled.c   (1.14 MB, 16037 funcs — includes FUN_100b5650 at line ~3323)
    C:\\Ascension\\Workspace\\RaijinLab\\re\\ghidra_out\\Extensions.dll.symbols.txt   (503 KB)
    C:\\Ascension\\Workspace\\RaijinLab\\re\\ghidra_out\\Extensions.dll.imports_xref.txt

  dnSpy managed C# (authoritative for DivxTac managed methods):
    C:\\Ascension\\Workspace\\RaijinLab\\re\\dnspy_out\\DivxTac\\-Module-.cs         (global functions incl. Anticheat*, Detect*)
    C:\\Ascension\\Workspace\\RaijinLab\\re\\dnspy_out\\DivxTac\\AntiCheatService.cs
    C:\\Ascension\\Workspace\\RaijinLab\\re\\dnspy_out\\DivxTac\\BannedProccesses.cs
    C:\\Ascension\\Workspace\\RaijinLab\\re\\dnspy_out\\DivxTac\\BannedProccessesManaged.cs
    C:\\Ascension\\Workspace\\RaijinLab\\re\\dnspy_out\\DivxTac\\DetourMgr.cs
    C:\\Ascension\\Workspace\\RaijinLab\\re\\dnspy_out\\DivxTac\\Opcodes.cs
    C:\\Ascension\\Workspace\\RaijinLab\\re\\dnspy_out\\DivxTac\\MasterHardDiskSerial.cs
    C:\\Ascension\\Workspace\\RaijinLab\\re\\dnspy_out\\DivxTac\\CDataStore.cs
    C:\\Ascension\\Workspace\\RaijinLab\\re\\dnspy_out\\DivxTac\\CDataStoreManagedHelper.cs
    C:\\Ascension\\Workspace\\RaijinLab\\re\\dnspy_out\\DivxTac\\ProcessDescription.cs
    C:\\Ascension\\Workspace\\RaijinLab\\re\\dnspy_out\\DivxTac\\ManagedDetourMgrlockRef.cs
    (plus phmap/ msclr/ std/ helpers, RTTI, __TypeDescriptor blobs — usually not needed)

============================================================
TOOLING (installed in-workspace)
============================================================
  python (has pefile, capstone, lief, yara-python — 'python' NOT 'python3' on Windows)
  Grok's capstone helpers (re/scripts/):
    disasm_window.py <pe> <va...> [--before N --after N]
    const_xref.py    <pe> <const...>
    xref_imports.py  <pe> [apis...]
    classify_checks.py <pe> <va...>
  dnSpy console: C:\\Ascension\\Workspace\\RaijinLab\\tools\\bin\\dnSpy\\dnSpy.Console.exe
     dnSpy.Console.exe -l "IL with C#" -t <TypeOrMethodName> <dll>
     dnSpy.Console.exe --md <token> <dll>                       (raw metadata token)
  Ghidra headless: C:\\Ascension\\Workspace\\RaijinLab\\tools\\bin\\ghidra_11.3.2_PUBLIC\\support\\analyzeHeadless.bat

============================================================
VERIFIED GROUND TRUTH (build on it, don't re-derive)
============================================================
  - Extensions violation SINK sub_100b5650 @ VA 0x100b5650 / file 0xb4a50; exactly 14 direct E8 callers (the 14 anti-debug vectors). Caller VAs: 0x100b5cba 0x100b5eb8 0x100b6154 0x100b6731 0x100b6954 0x100b6c32 0x100b6ff1 0x100b7189 0x100b72f7 0x100b74bd 0x100b76b8 0x100b7c79 0x100b80b2 0x100b82e4.
  - Ghidra symbol for sink = FUN_100b5650 (search Extensions.dll.decompiled.c for "FUN_100b5650" and for the caller VAs above minus the 0x10000000 base).
  - DivxTac imports NO ReadProcessMemory / Crypt* / RtlComputeCrc32 / VirtualProtect. Only DeviceIoControl+CreateFileA (SMART/STORAGE IOCTLs → HDD serial via MasterHardDiskSerial), GetProcAddress, IsDebuggerPresent(x3), version APIs, Sleep.
  - MMgr64 imports OpenProcess(x3) + CreateFileMappingW/MapViewOfFile(x3), NO ReadProcessMemory/hashing. MemoryBridge server (protocol v3) offloads large DBC/content tables from 32-bit client; session-token + PID-liveness gated. Table record counts observed: 6801, 36548, 127121, 18561, 562792, 10667.
  - DivxTac managed BannedProccessesManaged normalizes module names lowercased + ".dll" (NAME-based module matching, NOT hash).
  - DivxTac AntiCheatThreadLoop cadence (from 11a): DetectHackProcesses → sleep 60s → DetectHackModules → sleep 60s → DetectHackTitles → DetectDebugger → loop. 50 ms per-item throttle on each Detect*.
  - DivxTac SendModuleAntiCheatAlert / SendProcessAntiCheatAlert / DetectDebugger all emit opcode 1311 (CMSG_ANTICHEAT_ALERT) with 3 strings. AnticheatInitializeHandler emits opcode 1312 (CMSG_ANTICHEAT_VERSION) with subtype 4 + HDD serial.
  - DivxTac server-driven handlers: opcode 14 = AnticheatInitializeHandler, opcode 35 = AnticheatBannedProcessListHandler, both with magic context 0xDEADC0BE.
  - Extensions AC strings incl DBG_* enum (BEINGEBUGGEDPEB, NTGLOBALFLAGPEB, NTQUERYINFORMATIONPROCESS, HARDWAREDEBUGREGISTERS, MOVSS, RDTSC, INT3CC, INT2D, CLOSEHANDLEEXCEPTION, SINGLESTEPEXCEPTION, PREFIXHOP, DEBUGACTIVEPROCESS, PROCESSFILENAME, FINDWINDOW, OUTPUTDEBUGSTRING, QUERYPERFORMANCECOUNTER, GETTICKCOUNT), opcodes SMSG_WARDEN_DATA CMSG_WARDEN_DATA CMSG_ANTICHEAT_ALERT CMSG_ANTICHEAT_VERSION, singleton ExtendedAnticheatMgr / TemplatedSingleton<ExtendedAnticheatMgr>.
  - Existing note 11a_divxtac_ac_logic.md at C:\\Ascension\\Workspace\\RaijinLab\\notes\\11a_divxtac_ac_logic.md is Grok's authoritative writeup of DivxTac managed detection logic. TREAT AS TRUE unless you find contrary evidence in the source.
`

// ---------- SCHEMAS ----------

const FINDING_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['subsystem','headline','confidence','evidence','integrity_relevance','breakpoints','note_file'],
  properties: {
    subsystem: { type: 'string' },
    headline: { type: 'string', description: 'one-sentence load-bearing conclusion' },
    confidence: { type: 'string', enum: ['high','medium','low'] },
    evidence: { type: 'array', items: { type: 'string' }, description: 'concrete addresses/strings/decompiled snippets supporting headline' },
    integrity_relevance: { type: 'string', description: 'does this subsystem hash/checksum/byte-compare Extensions or client .text? explicit yes/no + why' },
    breakpoints: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      required: ['where','purpose'],
      properties: {
        where: { type: 'string', description: 'binary + VA or function name' },
        purpose: { type: 'string' },
        safe_bypass: { type: 'string', description: 'how to neutralize this specific check safely' },
        detour_risk: { type: 'string', description: 'is this address DetourMgr-watched?' },
      } } },
    open_questions: { type: 'array', items: { type: 'string' } },
    note_file: { type: 'string', description: 'absolute path of the markdown note the agent wrote' },
  },
}

const VERDICT_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['claim','verdict','reasoning'],
  properties: {
    claim: { type: 'string' },
    verdict: { type: 'string', enum: ['CONFIRMED','REFUTED','UNCERTAIN'] },
    reasoning: { type: 'string' },
    corrections: { type: 'array', items: { type: 'string' } },
    additional_evidence: { type: 'array', items: { type: 'string' } },
  },
}

const EXTRACT_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['task','output_file','summary'],
  properties: {
    task: { type: 'string' },
    output_file: { type: 'string' },
    summary: { type: 'string' },
    record_count: { type: 'integer' },
    sample: { type: 'array', items: { type: 'string' } },
  },
}

const SYNTH_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['doc','output_file','section_count'],
  properties: {
    doc: { type: 'string' },
    output_file: { type: 'string' },
    section_count: { type: 'integer' },
    highlights: { type: 'array', items: { type: 'string' } },
  },
}

const CRITIC_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['gaps'],
  properties: {
    gaps: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      required: ['gap','severity','remediation'],
      properties: {
        gap: { type: 'string' },
        severity: { type: 'string', enum: ['critical','high','medium','low'] },
        remediation: { type: 'string' },
        modality_missing: { type: 'string' },
      } } },
  },
}

// ---------- PHASE A: DEEPEN + VERIFY (pipeline) ----------

const DIMENSIONS = [
  {
    key: 'divxtac-managed-ac',
    note: 'C:\\Ascension\\Workspace\\RaijinLab\\notes\\11a_divxtac_ac_logic.md',
    prompt: `SUBSYSTEM: DivxTac managed anti-cheat detection logic.
STATUS: Note 11a already written by Grok. Your job: VERIFY 11a against source and append a "Claude Verification" section with any deltas, refinements, or errors found. Do NOT overwrite Grok's content.
Read: dnspy_out/DivxTac/AntiCheatService.cs, BannedProccessesManaged.cs, Opcodes.cs, MasterHardDiskSerial.cs, -Module-.cs, and ghidra_out/DivxTac.dll.decompiled.c.
VERIFY these Grok claims (cite line numbers when confirming/refuting):
  (1) AntiCheatThreadLoop cadence 60s→60s→0s (i.e. 120s per full cycle) with 50ms per-item throttle.
  (2) DetectHackModules compares ModuleName.ToLower() against banned list; NAME-only, no image bytes read.
  (3) DetectDebugger = IsDebuggerPresent() only (PEB flag).
  (4) MasterHardDiskSerial uses \\\\.\\PhysicalDrive0 + SMART IOCTLs (0x00074080 SMART_GET_VERSION, 0x0007C088 SMART_RCV_DRIVE_DATA, 0x002D1400 IOCTL_STORAGE_QUERY_PROPERTY) — HWID collection, NOT AC driver.
  (5) All three Send*Alert paths emit opcode 1311 with 3 strings; AnticheatInitializeHandler emits opcode 1312 with subtype 4 + HDD serial.
  (6) Server-driven handlers: opcode 14 = AnticheatInitializeHandler, opcode 35 = AnticheatBannedProcessListHandler, magic context 0xDEADC0BE.
  (7) INTEGRITY CLAIM: DivxTac performs ZERO code integrity checking (no CRC/hash/memcmp against Extensions or client .text).
For EACH claim: state CONFIRMED / REFUTED / PARTIAL + evidence. Append your verification section to 11a. Return schema (breakpoints = per-detection-vector BP recommendations for x32dbg on the native VAs listed in ground truth).`,
  },
  {
    key: 'divxtac-detourmgr',
    note: 'C:\\Ascension\\Workspace\\RaijinLab\\notes\\11b_divxtac_detourmgr.md',
    prompt: `SUBSYSTEM: DivxTac DetourMgr / ManagedDetourMgr / GlobalOffsets watch map.
Read: dnspy_out/DivxTac/DetourMgr.cs, ManagedDetourMgrlockRef.cs, -Module-.cs, phmap/ subdir; and ghidra_out/DivxTac.dll.decompiled.c + .symbols.txt.
The map is flat_hash_map<enum GlobalOffsets, unsigned char*>.
ANSWER PRECISELY:
  (1) Enumerate the GlobalOffsets enum members. Get them from dnSpy IL (dnSpy.Console.exe -l "IL with C#" -t GlobalOffsets DivxTac.dll if available, OR by disassembling FunctionMap$initializer$ at its native VA — find via 'FunctionMap' xrefs in .symbols.txt, then disasm and read the emitted enum-value/pointer pairs). Report each member name (if recoverable) + the client function address it maps to (if the initializer sets a specific pointer or leaves it null and populates at runtime).
  (2) HOW does DetourMgr decide something is detoured? Search DetourMgr.cs for: byte comparison, prologue snapshot, memcmp, ReadProcessMemory (native), address-equality check, or "is JMP present" check. State the mechanism.
  (3) Is DetourMgr checked on the AntiCheatThreadLoop 120s cycle, on a separate timer, or once at init?
  (4) INTEGRITY CLAIM: does DetourMgr read Extensions.dll .text bytes anywhere? Explicit yes/no with evidence.
This determines which client functions RaijinLab must NOT hook. Write note file, return schema. breakpoints = x32dbg BPs on DetourMgr init + any comparison call site + FunctionMap access.`,
  },
  {
    key: 'ext-sink-and-triggers',
    note: 'C:\\Ascension\\Workspace\\RaijinLab\\notes\\11c_extensions_sink_body.md',
    prompt: `SUBSYSTEM: Extensions.dll violation sink FUN_100b5650 body + trigger cadence.
Read Extensions.dll.decompiled.c (grep for "FUN_100b5650" — starts around line 3323). Follow every function it calls (grep for those names) 2 levels deep. Use disasm_window.py for anything Ghidra decomps poorly.
ANSWER PRECISELY:
  (1) What does FUN_100b5650 DO with its args? Trace: does it (a) build a packet + call a socket send fn? (b) set a global flag? (c) call into ExtendedAnticheatMgr singleton (grep symbols for "AVExtendedAnticheatMgr")? (d) write to MemoryBridge? (e) MessageBox / TerminateProcess? Trace the actual data flow — cite Ghidra decompiled snippet.
  (2) COMMON PARENT of the 14 vector callers: search Extensions.dll.decompiled.c for xrefs to any of these VAs 0x100b5cba 0x100b5eb8 0x100b6154 0x100b6731 0x100b6954 0x100b6c32 0x100b6ff1 0x100b7189 0x100b72f7 0x100b74bd 0x100b76b8 0x100b7c79 0x100b80b2 0x100b82e4 (as FUN_100b5cba etc.) — do they share a common caller? Is that caller invoked in a loop / thread / one-time? Identify CreateThread call sites near the cluster.
  (3) Is FUN_100b5650 or the vector cluster inside .vm_sec range (VA 0x10d6e000+)? Print the containing VA range.
  (4) INTEGRITY CLAIM: does the sink or its immediate callees compute a hash / CRC / memcmp of Extensions.dll or client .text? Grep near the sink for "crypt", "crc", "hash", "sha", "memcmp", "VirtualProtect".
This decides one-time bypass vs persistent hook. Write note file, return schema. breakpoints = x32dbg BPs on sink + driver + any spawn thread call.`,
  },
  {
    key: 'ext-network-ac',
    note: 'C:\\Ascension\\Workspace\\RaijinLab\\notes\\11d_extensions_network_ac.md',
    prompt: `SUBSYSTEM: Extensions.dll network anti-cheat surface — ExtendedAnticheatMgr + AC opcodes.
Strings present: SMSG_WARDEN_DATA, CMSG_WARDEN_DATA, CMSG_ANTICHEAT_ALERT, CMSG_ANTICHEAT_VERSION; RTTI .?AVExtendedAnticheatMgr@@ and .?AV?$TemplatedSingleton@VExtendedAnticheatMgr@@@@.
Read Extensions.dll.decompiled.c (grep the strings and RTTI names), string_scan.json, and use const_xref.py / string_scan.py if needed. Also cross-check with DivxTac's Opcodes.cs (dnspy_out/DivxTac/Opcodes.cs) for the numeric mapping — DivxTac uses opcode 14 for AnticheatInitialize and 35 for BannedProcessList inbound, and emits 1311/1312 outbound.
ANSWER PRECISELY:
  (1) Numeric opcode VALUES: from Ghidra / string context, find CMSG_ANTICHEAT_ALERT, CMSG_ANTICHEAT_VERSION, SMSG_WARDEN_DATA, CMSG_WARDEN_DATA opcode integers. Confirm 1311/1312 for CMSG_ANTICHEAT_ALERT / CMSG_ANTICHEAT_VERSION. Locate SMSG_WARDEN_DATA/CMSG_WARDEN_DATA numeric values (typical Blizzard 3.3.5: 0x2E7 / 0x2E6, but Ascension may repurpose).
  (2) ExtendedAnticheatMgr singleton: locate the instance global (TemplatedSingleton<T>::Instance pattern — usually a static ptr in .data), enumerate its member functions (Ghidra symbols starting with the mangled class name). What does the SMSG_WARDEN_DATA handler do — is legacy Warden actually live, or is the opcode reused as a shell for DivxTac/Extensions custom checks?
  (3) Relationship between the 14-vector local sink FUN_100b5650 and the network path: does the sink call into ExtendedAnticheatMgr::Send / a socket path / CMSG_ANTICHEAT_ALERT builder? Trace the sink's callees (see 11c) to confirm.
  (4) CMSG_ANTICHEAT_VERSION payload: what version/handshake integer is sent (from DivxTac this is subtype "4" + HDD serial; does Extensions emit the same or a different subtype/version tag)?
Write note file, return schema.`,
  },
  {
    key: 'mmgr64-memorybridge',
    note: 'C:\\Ascension\\Workspace\\RaijinLab\\notes\\11e_mmgr64_memorybridge.md',
    prompt: `SUBSYSTEM: MMgr64.exe = MemoryBridge server; confirm-and-detail; rule out any AC role.
Read: ghidra_out/MMgr64.exe.decompiled.c + .symbols.txt + .imports_xref.txt, plus notes/03_memorybridge.md (Grok's first-pass) and re/samples/first_run/MemoryBridge.log if it has protocol traces.
Imports (confirmed): OpenProcess(x3), CreateFileMappingW/MapViewOfFile(x3), IsDebuggerPresent(x2), TerminateProcess. NO ReadProcessMemory / hashing / crypto.
ANSWER PRECISELY:
  (1) Shared-memory handshake: object-token generation & validation, request/response mapping name pattern, event names, protocol version 3, PID + session validation. Cite specific decompiled functions (FUN_1400xxxxx) and the string constants they reference.
  (2) Enumerate the full command set (Alloc / Free / CreateTable / Read / Write / Projected queries / whatever the RPC dispatch shows). Give command IDs + arg shapes.
  (3) Why OpenProcess on the client: session check + liveness wait only, OR handle duplication / memory access? If DuplicateHandle appears, confirm the desired access mask.
  (4) The 6 table handles (record counts 6801/36548/127121/18561/562792/10667): map to which DBCs / content tables (compare to Ascension's DBFilesClient\\* string list in Extensions strings — GameObjectDisplayInfoAddon.dbc, ItemAddon.dbc, SpellAddon.dbc appear there; also standard 3.3.5 DBCs like Spell.dbc has ~562k rows if extended).
  (5) IsDebuggerPresent usage: self anti-debug only? Any TerminateProcess call site on positive detect?
  (6) Consequence if MMgr64 is killed / spoofed for RaijinLab (does the client stall / fallback / crash)?
  (7) INTEGRITY CLAIM: definitively NOT a client-memory integrity scanner (support with imports + call graph).
Write note file, return schema. breakpoints = MMgr64 handshake choke points for a runtime mock/spoof.`,
  },
  {
    key: 'ascension-warden-heritage',
    note: 'C:\\Ascension\\Workspace\\RaijinLab\\notes\\11f_ascension_scan_divxdecoder.md',
    prompt: `SUBSYSTEM: Ascension.exe legacy Warden/Scan.dll heritage + DivxDecoder side-load hypothesis.
Read Ascension.exe strings (string_scan.json under "Ascension.exe") and DivxDecoder.dll strings ("DivxDecoder.dll" section).
(A) Legacy Warden/Scan.dll: strings ScanDLLStart, IsScanDLLFinished, .\\Scan.dll, .\\Scan.dll.new, ScanDLLGlue.cpp, SMSG_ADDON_INFO, &sessionKeyHash=, ?info_hash=, IsLinuxClient, ScanThread, AUTH_BANNED_URL, LOGIN_UNABLE_TO_DOWNLOAD_MODULE. Use const_xref.py on Ascension.exe to see whether Scan.dll is ever LoadLibrary'd / whether ScanDLLStart is registered as a Lua fn and never called / whether there is a real network handler for AUTH_BANNED_URL. Determine if the legacy Blizzard Warden/ScanDLL path is LIVE (referenced by real code + wired to a network handler) or DEAD stock code superseded by Extensions/DivxTac. Also — the "IsLinuxClient" string: is this the stock Blizzard export (harmless legacy) or has Ascension repurposed it as the cxmplexpack-style unlocker probe?
(B) DivxDecoder.dll side-load hypothesis: it is imported by Ascension.exe (4 exports: DivxDecode, InitializeDivxDecoder, SetOutputFormat, UnInitializeDivxDecoder), timestamp 2004. Check: (i) does its entrypoint or any export LoadLibrary("DivxTac.dll") or resolve DivxTac symbols? (ii) any anomalies (writable .text, injected TLS callback, unusually large export table for a decoder)? (iii) grep imports for suspicious APIs (VirtualAlloc + WriteProcessMemory + CreateRemoteThread patterns). Use pefile + capstone in a small python snippet if needed.
Write note file, return schema. integrity_relevance: whether either subsystem provides client-integrity/scan mechanism relevant to RaijinLab.`,
  },
]

phase('Deepen')

// Pipeline: each Deepen finding is verified as soon as it lands (verify runs concurrent with other deepens).
const verifiedPairs = await pipeline(
  DIMENSIONS,
  d => agent(d.prompt + "\n\n" + PATHS + "\n\nWrite your full markdown analysis to: " + d.note, {
        label: 'deepen:' + d.key, phase: 'Deepen', schema: FINDING_SCHEMA, effort: 'high' })
        .then(f => f ? { ...f, _key: d.key, _dim: d } : null),
  (finding) => {
    if (!finding) return null
    return agent(
      `You are an ADVERSARIAL VERIFIER. A prior RE agent produced this finding about Ascension AC. Try hard to REFUTE the load-bearing claims — especially the integrity_relevance claim. Independently re-read the SAME source files (Ghidra decomp / dnSpy .cs / capstone disasm) and CHECK the cited addresses.\n\n` +
      `SUBSYSTEM: ${finding.subsystem}\n` +
      `HEADLINE: ${finding.headline}\n` +
      `INTEGRITY_RELEVANCE: ${finding.integrity_relevance}\n` +
      `EVIDENCE (that you must verify): ${JSON.stringify(finding.evidence)}\n` +
      `BREAKPOINTS PROPOSED: ${JSON.stringify(finding.breakpoints)}\n` +
      `NOTE FILE (read the full analysis here): ${finding.note_file}\n\n` +
      `Default to UNCERTAIN if you cannot reproduce the cited evidence. REFUTED if you find contrary evidence. CONFIRMED only if the cited addresses / strings / decompiled snippets check out on your independent read.\n` +
      `Provide 'additional_evidence' with anything you found that strengthens or contradicts the finding.\n\n` + PATHS,
      { label: 'verify:' + finding._key, phase: 'Verify', schema: VERDICT_SCHEMA, effort: 'high' })
      .then(v => ({ finding, verdict: v }))
  }
)

const goodPairs = verifiedPairs.filter(Boolean)
log(`Deepen+Verify complete: ${goodPairs.length}/${DIMENSIONS.length} findings survived.`)

// ---------- PHASE B: EXTRACT (parallel — cross-cutting JSON + scripts) ----------

phase('Extract')

const EXTRACTIONS = [
  {
    key: 'ext-globaloffsets-enum',
    out: 'C:\\Ascension\\Workspace\\RaijinLab\\re\\divxtac_globaloffsets.json',
    prompt: `Extract the DivxTac GlobalOffsets enum members with numeric values and any static pointer initializers.
Sources: dnspy_out/DivxTac/DetourMgr.cs, dnspy_out/DivxTac/-Module-.cs, ghidra_out/DivxTac.dll.symbols.txt.
Approach: (a) grep DetourMgr.cs and -Module-.cs for "GlobalOffsets"; (b) if the enum isn't in .cs, run dnSpy console:  C:\\Ascension\\Workspace\\RaijinLab\\tools\\bin\\dnSpy\\dnSpy.Console.exe -l "IL with C#" -t GlobalOffsets C:\\Ascension\\Workspace\\RaijinLab\\re\\dumps\\DivxTac.dll   > enum.txt   ; (c) if still missing, disassemble the FunctionMap initializer native VA — look up the symbol for "FunctionMap$initializer$" in symbols.txt then disasm_window.py DivxTac.dll <VA> --after 300 and read the emit_pair(enumval, ptr) sequence.
Write JSON: {"enum_name":"GlobalOffsets","members":[{"name":"...","value":N,"initial_ptr":"0x...","meaning":"..."}, ...], "source":"which method extracted", "count":N}. Return schema.`,
  },
  {
    key: 'ext-opcodes-table',
    out: 'C:\\Ascension\\Workspace\\RaijinLab\\re\\ascension_ac_opcodes.json',
    prompt: `Build the definitive Ascension AC opcode table (client↔server).
Sources: dnspy_out/DivxTac/Opcodes.cs (managed enum), Extensions.dll strings (string_scan.json → CMSG_ANTICHEAT_ALERT / CMSG_ANTICHEAT_VERSION / SMSG_WARDEN_DATA / CMSG_WARDEN_DATA plus all CMSG_*_CHEAT / SMSG_CHECK_FOR_BOTS / CMSG_BOT_DETECTED2), and ghidra_out/Extensions.dll.decompiled.c near opcode dispatch (search for "1311","1312","1310" and their hex forms "0x51f","0x520").
Write JSON schema:
{"opcodes":[{"name":"CMSG_ANTICHEAT_ALERT","dir":"C2S","id":1311,"hex":"0x51F","source":"DivxTac Opcodes.cs","payload":"3 strings"}, ...]}
Include every AC-related opcode you find (Warden, Anticheat, Bot detection, Cheat *CHEAT opcodes). At MINIMUM: CMSG_ANTICHEAT_ALERT, CMSG_ANTICHEAT_VERSION, SMSG_WARDEN_DATA, CMSG_WARDEN_DATA, SMSG_CHECK_FOR_BOTS, CMSG_BOT_DETECTED2, opcode 14 (DivxTac AnticheatInit inbound), opcode 35 (DivxTac BannedList inbound), and the *_CHEAT family. Return schema.`,
  },
  {
    key: 'ext-antidebug-vector-table',
    out: 'C:\\Ascension\\Workspace\\RaijinLab\\re\\ext_antidebug_vectors.json',
    prompt: `For each of the 14 Extensions anti-debug vectors, produce a row {caller_va, technique_string, technique_class, api_calls_used, brief_description}.
The 14 caller VAs are: 0x100b5cba 0x100b5eb8 0x100b6154 0x100b6731 0x100b6954 0x100b6c32 0x100b6ff1 0x100b7189 0x100b72f7 0x100b74bd 0x100b76b8 0x100b7c79 0x100b80b2 0x100b82e4. Each calls FUN_100b5650.
For each: (a) look up its containing function in Extensions.dll.decompiled.c — grep "FUN_100b5cba" etc.; (b) identify which DBG_* string it fingerprints (BEINGEBUGGEDPEB, NTGLOBALFLAGPEB, CHECKREMOTEDEBUGGERPRESENT, ISDEBUGGERPRESENT, NTQUERYINFORMATIONPROCESS, NTSETINFORMATIONTHREAD, HARDWAREDEBUGREGISTERS via GetThreadContext, MOVSS, RDTSC, QUERYPERFORMANCECOUNTER, GETTICKCOUNT, INT3CC, INT2D, CLOSEHANDLEEXCEPTION, SINGLESTEPEXCEPTION, PREFIXHOP, DEBUGACTIVEPROCESS, PROCESSFILENAME, FINDWINDOW, OUTPUTDEBUGSTRING); (c) list the imports each function calls (from imports_xref.txt or by grep for "Kernel32" / "Ntdll" / "GetThreadContext" / "FindWindowW" etc.).
Write JSON: {"sink":"FUN_100b5650@0x100b5650","vectors":[...14 rows...], "count":14}. Return schema.`,
  },
  {
    key: 'ext-virtualprotect-callsites',
    out: 'C:\\Ascension\\Workspace\\RaijinLab\\re\\ext_virtualprotect_callsites.json',
    prompt: `Extensions.dll imports VirtualProtect. Determine the purpose of each VirtualProtect call site — is it (a) self-unpack at load (writing to own .text), (b) self-patch / anti-tamper, (c) VMProtect stub, or (d) something else?
Approach: use xref_imports.py Extensions.dll VirtualProtect (from re/scripts/); OR grep Extensions.dll.decompiled.c for "VirtualProtect" (usually named "VirtualProtect" or similar in Ghidra). Get every call site VA + the containing function VA + a 20-line context of the decompilation. Special interest: sites near 0x1000106b and 0x100010e4 (Grok noted these are near entrypoint).
Write JSON: {"sites":[{"va":"0x...","fn":"FUN_...","classification":"self-unpack|self-patch|vmprotect|unknown","context":"..."}], "count":N, "self_hash_evidence":"yes|no + reasoning"}. Return schema.
This is load-bearing: if any site writes-then-VirtualProtects with PAGE_EXECUTE_READ WITHOUT then re-hashing, we know it is self-unpack only and static .text patches survive.`,
  },
  {
    key: 'x32dbg-bp-script',
    out: 'C:\\Ascension\\Workspace\\RaijinLab\\re\\scripts\\set_ac_breakpoints.x32dbg.txt',
    prompt: `Generate an x32dbg command script that sets all recommended AC breakpoints on live Ascension.exe. Include:
  - bpm Extensions.dll+B4A50 (sink FUN_100b5650)
  - bpm each of the 14 vector caller VAs (subtract 0x10000000 to get RVA, then Extensions.dll+RVA form for ASLR safety)
  - bpm DivxTac.dll+2EC4 (DetectDebugger) etc. — the DivxTac native VAs listed in ground truth (2EC4, 2FA8, 3094, 3234, 33F8, 35BC, 22FC, 5580, 5908)
  - bpx on imports: Extensions.dll IsDebuggerPresent, CheckRemoteDebuggerPresent, GetThreadContext, FindWindowW, CloseHandle, VirtualProtect, CreateToolhelp32Snapshot, K32GetProcessMemoryInfo, LoadLibraryW
  - bpx on imports: DivxTac.dll DeviceIoControl (HWID collection), CreateFileA, IsDebuggerPresent
  - bpx on Ascension.exe: LoadLibraryA/W (to catch DivxDecoder side-loads), CreateThread (to catch AC-thread spawn), Extensions.dll spawn if any (from strings "Failed to launch MMgr64.exe")
Format: one command per line; use x32dbg comment lines (starting with ";") to group by subsystem and describe each. At the top: SetLogFile "C:\\Ascension\\Workspace\\RaijinLab\\re\\x32dbg_session.log" and log "AC BP script loaded".
Include a "// SAFETY:" comment noting which BPs are safe (won't crash game on trigger) vs which require conditional actions.
Write the script to output_file. Return schema. record_count = total BPs set.`,
  },
  {
    key: 'yara-additions',
    out: 'C:\\Ascension\\Workspace\\RaijinLab\\re\\yara\\ascension_ac_v2.yar',
    prompt: `Append (or emit a v2 companion of) the existing YARA rules in C:\\Ascension\\Workspace\\RaijinLab\\re\\yara\\ascension_ac.yar with newly-discovered signatures. Rules to add (as separate rule blocks):
  - rule Ascension_Ext_Sink_FUN_100b5650  { strings: prologue bytes at file offset 0xb4a50 (read from Extensions.dll — extract 20 bytes)  condition: any of them }
  - rule Ascension_DivxTac_ManagedAC { strings: managed strings AntiCheatService, BannedProccessesManaged, DetourMgr, AnticheatBannedProcessListHandler condition: 3 of them }
  - rule Ascension_DivxTac_HWID { strings: SMART_GET_VERSION marker, "\\\\.\\PhysicalDrive0", DFP_RECEIVE_DRIVE_DATA structure condition: 2 of them }
  - rule Ascension_MMgr64_Bridge { strings: MemoryBridge protocol string, magic 0xDEADC0BE (little-endian bytes BE C0 AD DE) condition: 2 of them }
  - rule Ascension_ExtendedAnticheatMgr { strings: RTTI ".?AVExtendedAnticheatMgr@@", ".?AV?$TemplatedSingleton@VExtendedAnticheatMgr@@@@" condition: any of them }
Read the existing .yar file first to match its style. Emit rule metadata (author = "Claude", date = "2026-07-20") on each. Write to output_file. Return schema.`,
  },
  {
    key: 'frida-runtime-probe-spec',
    out: 'C:\\Ascension\\Workspace\\RaijinLab\\notes\\FRIDA_probe_plan.md',
    prompt: `Write a Frida runtime probe plan that complements the static analysis. This is a DESIGN document (Grok already has re/scripts/frida_probe.js — read it first if it exists). Cover:
  (1) Attach vs spawn: which is safer against DivxTac IsDebuggerPresent? (Frida agent runs in-process — DivxTac's PEB check may or may not flag; discuss).
  (2) Hooks to install: Extensions.dll FUN_100b5650 (log severity + blob + caller RA); DivxTac DetectDebugger/HackModules/HackTitles (log arg values); ClientServices::fpSendPacket2 (log outgoing opcodes to see 1311/1312 in flight); LoadLibraryW (log all module loads to fingerprint startup).
  (3) Timing safety: must not attach before Extensions self-unpack (VirtualProtect finishes) or hooks land in unwritable memory. Cite Extensions VirtualProtect callsite VAs from ext_virtualprotect_callsites.json (the previous extractor) and recommend a settle delay.
  (4) Log schema per hook (JSON lines).
  (5) Anti-detection: replace IsDebuggerPresent import stub returns to 0 (see DivxTac.dll+2EC4 which reads PEB directly? verify), spoof FindWindowW to not match debugger window classes.
  (6) Sequenced runbook: (a) start Frida injector, (b) attach to Ascension.exe post-Extensions-init, (c) install hooks, (d) run one full AntiCheatThreadLoop cycle (~120s), (e) dump log.
Write to output_file. Return schema.`,
  },
]

const extractResults = await parallel(EXTRACTIONS.map(e => () => agent(
  e.prompt + "\n\n" + PATHS + `\n\nOUTPUT_FILE: ${e.out}`,
  { label: 'extract:' + e.key, phase: 'Extract', schema: EXTRACT_SCHEMA, effort: 'high' })))

const goodExtracts = extractResults.filter(Boolean)
log(`Extract complete: ${goodExtracts.length}/${EXTRACTIONS.length} extractions succeeded.`)

// ---------- PHASE C: SYNTHESIZE (three docs, run in parallel — each reads all upstream) ----------

phase('Synthesize')

const findingsSummary = goodPairs.map(p =>
  `## ${p.finding.subsystem} (verdict: ${p.verdict?.verdict || 'n/a'})\n` +
  `HEADLINE: ${p.finding.headline}\n` +
  `INTEGRITY: ${p.finding.integrity_relevance}\n` +
  `NOTE: ${p.finding.note_file}\n` +
  `BREAKPOINTS: ${JSON.stringify(p.finding.breakpoints)}\n` +
  (p.verdict?.corrections?.length ? `CORRECTIONS: ${JSON.stringify(p.verdict.corrections)}\n` : '')
).join('\n\n')

const extractsSummary = goodExtracts.map(e =>
  `- ${e.task} → ${e.output_file} (${e.record_count ?? '?'} rows) — ${e.summary}`
).join('\n')

const SYNTH_CONTEXT = `
============================================================
UPSTREAM FINDINGS (verified) — READ THE LINKED NOTE FILES FOR FULL DETAIL
============================================================
${findingsSummary}

============================================================
UPSTREAM EXTRACTIONS — READ THE OUTPUT_FILES FOR THE DATA
============================================================
${extractsSummary}
`

const SYNTHESES = [
  {
    key: 'breakpoint-catalog',
    out: 'C:\\Ascension\\Workspace\\RaijinLab\\notes\\12_ac_breakpoint_catalog.md',
    prompt: `Synthesize the CONSOLIDATED anti-cheat breakpoint catalog. This is THE document a reverse engineer opens in x32dbg to set BPs and know what will happen. Organize by subsystem in the exact order an operator would want to hit them:
  1. Startup / boot phase (Extensions self-unpack VirtualProtect + entrypoint)
  2. AC thread spawn (find CreateThread → AC-loop entry)
  3. Extensions 14 anti-debug vectors (grouped by technique class, each with sink VA)
  4. DivxTac managed detection loop (DetectHackModules / Processes / Titles / Debugger + AntiCheatService alerts)
  5. Server-driven bootstrap (opcodes 14/35 handlers, magic 0xDEADC0BE)
  6. DetourMgr / GlobalOffsets watch points (if any specific offsets survived extraction)
  7. Network AC opcodes (1311, 1312, SMSG/CMSG_WARDEN_DATA — where they emit)
  8. MMgr64 IPC (mapping name, event names, protocol handshake — client-side call sites)
  9. Legacy Warden/Scan.dll (if LIVE — from 11f)
  10. HWID collection (DivxTac \\\\.\\PhysicalDrive0 + IOCTLs)
For EACH breakpoint row: {ID, location (module+VA+RVA), what fires it, expected observation, safe-bypass action, dependencies (which BP must fire first), DetourMgr-watched risk, confidence}.
End with a "Suggested trigger sequence" section: what to click / do in-game to guarantee each vector fires (login → in-world → move → cast → alt-tab → close-handle-tricks).
Read all upstream note files (11a-11f) and extractions before writing. Write to output_file. Return schema. section_count = # of subsystems covered.`,
  },
  {
    key: 'evasion-strategy',
    out: 'C:\\Ascension\\Workspace\\RaijinLab\\notes\\13_ac_evasion_strategy.md',
    prompt: `Synthesize the RaijinLab runtime EVASION STRATEGY based on the verified AC map. Structure:
  (1) Ground rules — what integrity checks EXIST vs what DON'T (definitive statement backed by findings).
  (2) Module-load evasion — how to load RaijinLabRuntime.dll so DivxTac's name-based ModuleName.ToLower() scan doesn't match: manual-map (no PEB entry), random name, ntdll direct-syscall LoadLibrary, thread hijack. Rank by detectability vs implementation cost. Reference notes/10_example_code_integration.md warning about LoadLibrary detection.
  (3) DetourMgr-watched functions — which client function prologues must NOT be inline-hooked (from 11b GlobalOffsets extraction). Alternative: use ExecuteInMainThread / trampolines further into the function body.
  (4) 14-vector sink neutralization — options: (a) patch FUN_100b5650 prologue to 'ret' (if 11c confirms no self-hash), (b) hook each of the 14 vector functions to short-circuit, (c) run in a way that no vector triggers (PEB.BeingDebugged=0, no HW BPs on DR0-7, no int3, no FindWindow with debugger names, don't attach a debugger — Frida in-process may already satisfy this). Pick the safest.
  (5) Network AC — DO NOT modify outgoing CMSG_ANTICHEAT_ALERT (1311) / CMSG_ANTICHEAT_VERSION (1312) shape at first; instead, prevent the trigger. Discuss whether to spoof SMSG_WARDEN_DATA if legacy path is live.
  (6) MMgr64 — do NOT tamper; RaijinLab does not need MB. Merely leave it alone. If MB dies the client dies (per 11e finding).
  (7) HWID — DivxTac reads \\\\.\\PhysicalDrive0 SMART data as HWID. Persistent bans key on this. If a spoof is needed, options: user-mode IOCTL hook (fragile), disk serial spoofer driver (nuclear).
  (8) Discovery risks Grok's addon side introduces — enumerated from Example Code integration notes.
  (9) Sequenced implementation plan for Grok: what to ship first (functional-first), what to add for stealth (order).
Write to output_file. Return schema.`,
  },
  {
    key: 'handoff-claude',
    out: 'C:\\Ascension\\Workspace\\RaijinLab\\notes\\HANDOFF_claude.md',
    prompt: `Write the HANDOFF document for Grok — Claude's summary of AC RE findings, delta vs Grok's prior maps, and open items.
Structure:
  - Session date + scope (deep AC RE round 2).
  - Files written this session (list all 11b-11f, 12, 13, JSON extracts, x32dbg script, yara additions, FRIDA plan).
  - Verified vs corrected: for each subsystem, state which of Grok's prior claims are CONFIRMED, which are REFINED (with the refinement), which are REFUTED.
  - New facts (things not in prior Grok notes) — the ExtendedAnticheatMgr network relationship, DetourMgr GlobalOffsets contents (if extracted), Extensions VirtualProtect classification, opcode numeric values.
  - Explicit actionables for Grok's addon/runtime work: which module-loading approaches remain viable, which client function VAs to avoid hooking, what BPs to set when live-debugging.
  - Open questions requiring dynamic (in-game) confirmation — list them.
Read upstream notes + verdicts + extractions before writing. Write to output_file. Return schema.`,
  },
]

const synthResults = await parallel(SYNTHESES.map(s => () => agent(
  s.prompt + "\n\n" + PATHS + "\n\n" + SYNTH_CONTEXT + `\n\nOUTPUT_FILE: ${s.out}`,
  { label: 'synth:' + s.key, phase: 'Synthesize', schema: SYNTH_SCHEMA, effort: 'high' })))

const goodSynths = synthResults.filter(Boolean)
log(`Synthesize complete: ${goodSynths.length}/${SYNTHESES.length} docs written.`)

// ---------- PHASE D: CRITIQUE (single critic, high effort) ----------

phase('Critique')

const critic = await agent(
  `You are the COMPLETENESS CRITIC for a deep RE session on Ascension's custom anti-cheat.\n\n` +
  `Everything produced this session:\n` +
  `--- Verified findings ---\n${findingsSummary}\n\n` +
  `--- Extractions ---\n${extractsSummary}\n\n` +
  `--- Synthesis docs ---\n${goodSynths.map(s=>`- ${s.doc} → ${s.output_file}`).join('\n')}\n\n` +
  `Your job: identify GAPS. What modality wasn't run, what claim wasn't verified, what source wasn't read, what subsystem is under-covered, what breakpoint category is missing, what integrity check was assumed absent without proof, what error state / edge case wasn't considered. Sample gap categories to consider:\n` +
  `  - unverified: dumps_mid_download vs dumps (are hashes identical or did the client update?)\n` +
  `  - missing: has WowError.exe been examined at all (it's in re/dumps but no note references it)?\n` +
  `  - missing: has DivxDecoder side-load been actually verified with pefile (11f asked for it — did the agent do it)?\n` +
  `  - unverified: was the FunctionMap initializer for GlobalOffsets actually decoded from the native VA (extractor may have failed on it)?\n` +
  `  - unverified: has anyone measured actual Extensions VirtualProtect target ranges to prove self-unpack vs self-patch?\n` +
  `  - unverified: has anyone read Extensions.dll.decompiled.c near a DivxTac.dll import xref to confirm Extensions loads DivxTac vs DivxTac being loaded independently?\n` +
  `  - missing: dynamic verification plan for opcode 14/35 arrival timing?\n` +
  `  - missing: what is the FIRST BP that fires (order-of-events at launch)?\n` +
  `Emit up to 10 gaps ranked by severity. For each: gap description, severity (critical/high/medium/low), remediation (concrete next step), modality_missing (static/dynamic/network/etc.). Return schema.`,
  { label: 'critic:completeness', phase: 'Critique', schema: CRITIC_SCHEMA, effort: 'high' })

log(`Critique complete: ${critic?.gaps?.length ?? 0} gaps identified.`)

// ---------- PHASE E: PATCH ROUND (if critic found critical/high gaps and budget allows) ----------

if (critic?.gaps?.length && budget.total && budget.remaining() > 100_000) {
  phase('Patch')
  const criticalGaps = critic.gaps.filter(g => g.severity === 'critical' || g.severity === 'high').slice(0, 5)
  if (criticalGaps.length) {
    log(`Patch round: addressing ${criticalGaps.length} critical/high gaps`)
    const patchResults = await parallel(criticalGaps.map((g, i) => () => agent(
      `Address this GAP identified by the completeness critic:\n\nGAP: ${g.gap}\nREMEDIATION: ${g.remediation}\nMODALITY: ${g.modality_missing || 'unspecified'}\n\n` +
      `Do the remediation work. Read the sources you need. Write your output to a new file under C:\\Ascension\\Workspace\\RaijinLab\\notes\\ named 14_gap_${i+1}_<slug>.md OR append to the most-relevant existing note (state which). Return schema.\n\n` + PATHS,
      { label: 'patch:gap' + (i+1), phase: 'Patch', schema: SYNTH_SCHEMA, effort: 'high' })))
    log(`Patch round complete: ${patchResults.filter(Boolean).length}/${criticalGaps.length} gaps addressed`)
  }
}

return {
  verifiedFindings: goodPairs.length,
  extractions: goodExtracts.length,
  syntheses: goodSynths.length,
  criticGaps: critic?.gaps?.length ?? 0,
  files: {
    notes: goodPairs.map(p => p.finding.note_file).concat(goodSynths.map(s => s.output_file)),
    extractions: goodExtracts.map(e => e.output_file),
  },
}
