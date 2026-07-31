export const meta = {
  name: 'raijin-ac-re',
  description: 'Deepen + adversarially verify Ascension AC reverse-engineering for breakpoint/evasion planning',
  phases: [
    { title: 'Deepen', detail: 'one agent per AC subsystem, using Ghidra/dnSpy/capstone' },
    { title: 'Verify', detail: 'adversarial skeptic per finding; refute the load-bearing claim' },
  ],
}

const PATHS = `
Binaries (offline, hashes match live):
  Extensions.dll : C:\\Ascension\\Workspace\\RaijinLab\\re\\dumps\\Extensions.dll   (x86, image base 0x10000000, .vm_sec VMProtect, .text WRITE+EXEC)
  DivxTac.dll    : C:\\Ascension\\Workspace\\RaijinLab\\re\\dumps\\DivxTac.dll      (x86, C++/CLI mixed, image base 0x10000000)
  MMgr64.exe     : C:\\Ascension\\Workspace\\RaijinLab\\re\\dumps\\MMgr64.exe       (x64, image base 0x140000000)
  Ascension.exe  : C:\\Ascension\\Workspace\\RaijinLab\\re\\dumps\\Ascension.exe    (x86, image base 0x400000, stock 3.3.5.12340 lineage)
  DivxDecoder.dll: C:\\Ascension\\Workspace\\RaijinLab\\re\\dumps\\DivxDecoder.dll  (x86)

Pre-baked Ghidra output (already produced, READ don't regenerate for DivxTac/MMgr64):
  C:\\Ascension\\Workspace\\RaijinLab\\re\\ghidra_out\\DivxTac.dll.decompiled.c  (+.symbols.txt +.imports_xref.txt)
  C:\\Ascension\\Workspace\\RaijinLab\\re\\ghidra_out\\MMgr64.exe.decompiled.c   (+.symbols.txt +.imports_xref.txt)
  Extensions.dll Ghidra MAY still be analyzing (background); check C:\\Ascension\\Workspace\\RaijinLab\\re\\ghidra_out\\Extensions.dll.decompiled.c — if absent/partial, use capstone.

dnSpy managed C# (already produced): C:\\Ascension\\Workspace\\RaijinLab\\re\\dnspy_out\\DivxTac\\*.cs
  dnSpy.Console.exe : C:\\Ascension\\Workspace\\RaijinLab\\tools\\bin\\dnSpy\\dnSpy.Console.exe
    - For IL bodies of C++/CLI methods use:  dnSpy.Console.exe -l IL -t <TypeOrMethodName> <dll>   (or --md <token>)

Tooling: python (has pefile, capstone, lief, yara). Grok's capstone helper scripts in re/scripts/:
  disasm_window.py <pe> <va...> [--before N --after N]   const_xref.py <pe> <const...>
  xref_imports.py <pe> [apis...]                         classify_checks.py <pe> <va...>
  NOTE on Windows the command is 'python' (python3 alias is broken).

VERIFIED GROUND TRUTH (independently confirmed — build on it, don't re-derive):
  - Extensions violation SINK sub_100b5650 @ VA 0x100b5650 / file 0xb4a50; exactly 14 direct E8 callers (the 14 anti-debug vectors). Caller VAs: 0x100b5cba 0x100b5eb8 0x100b6154 0x100b6731 0x100b6954 0x100b6c32 0x100b6ff1 0x100b7189 0x100b72f7 0x100b74bd 0x100b76b8 0x100b7c79 0x100b80b2 0x100b82e4.
  - DivxTac imports NO ReadProcessMemory / Crypt* / RtlComputeCrc32 / VirtualProtect. Only DeviceIoControl+CreateFileA (IOCTL channel), GetProcAddress, IsDebuggerPresent(x3).
  - MMgr64 imports OpenProcess + CreateFileMappingW/MapViewOfFile, NO ReadProcessMemory/hashing. It is the "MemoryBridge" server (protocol v3) that offloads large DBC/content tables from the 32-bit client; session-token + PID-liveness gated.
  - DivxTac managed BannedProccessesManaged normalizes module names lowercased + ".dll" (NAME-based module matching, not hash).
  - Extensions AC strings incl DBG_* enum (BEINGEBUGGEDPEB, NTGLOBALFLAGPEB, NTQUERYINFORMATIONPROCESS, HARDWAREDEBUGREGISTERS, MOVSS, RDTSC, INT3CC, INT2D...), opcodes SMSG_WARDEN_DATA CMSG_WARDEN_DATA CMSG_ANTICHEAT_ALERT CMSG_ANTICHEAT_VERSION, singleton ExtendedAnticheatMgr / TemplatedSingleton<ExtendedAnticheatMgr>.
`

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
      properties: { where: {type:'string'}, purpose: {type:'string'}, safe_bypass: {type:'string'} } } },
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
  },
}

const DIMENSIONS = [
  {
    key: 'divxtac-managed-ac',
    note: 'C:\\Ascension\\Workspace\\RaijinLab\\notes\\11a_divxtac_ac_logic.md',
    prompt: `Reverse the DivxTac.dll anti-cheat DETECTION LOGIC (managed + native).
Read the pre-baked Ghidra native decompile (ghidra_out/DivxTac.dll.*) and dnSpy C# (dnspy_out/DivxTac/*.cs).
The AC functions are C++/CLI (__clrcall) at these native VAs: DetectDebugger 0x10002ec4, SendModuleAntiCheatAlert 0x10002fa8, DetectHackModules 0x10003094, DetectHackProcesses 0x10003234, DetectHackTitles 0x100033f8, AntiCheatThreadLoop 0x100035bc, SendProcessAntiCheatAlert 0x100022fc, AnticheatBannedProcessListHandler 0x10005580, AnticheatInitializeHandler 0x10005908.
Ghidra failed to decompile some (managed) — get their IL/C# via dnSpy: run  dnSpy.Console.exe -l "IL with C#" -t AntiCheatService <DivxTac.dll>  and  -t AnticheatInitializeHandler etc; also try decompiling the <Module> global type and grep tokens. If a method resists, capstone-disassemble the native VA.
ANSWER PRECISELY: (1) AntiCheatThreadLoop cadence — Sleep interval / loop structure. (2) DetectHackModules — does it compare module NAMES against the banned list (confirm the .ToLower()+".dll" name match) or does it hash/byte-compare module memory? (3) DetectDebugger — which techniques (maps to Extensions DBG_* ?). (4) What CreateFileA device + DeviceIoControl IOCTL is used for (kernel driver? MasterHardDiskSerial hardware id? — note MasterHardDiskSerial.cs exists). (5) What SendModuleAntiCheatAlert / SendProcessAntiCheatAlert actually send (which opcode via ClientServices fpSendPacket2). (6) AnticheatInitializeHandler + AnticheatBannedProcessListHandler — what server opcodes drive them, what state they set.
CRITICAL for integrity_relevance: state definitively whether DivxTac hashes/checksums/byte-compares Extensions.dll or client .text anywhere. Write full findings to the note_file. Return the schema.`,
  },
  {
    key: 'divxtac-detourmgr',
    note: 'C:\\Ascension\\Workspace\\RaijinLab\\notes\\11b_divxtac_detourmgr.md',
    prompt: `Reverse DivxTac.dll DetourMgr / ManagedDetourMgr and the GlobalOffsets watch map.
Sources: ghidra_out/DivxTac.dll.decompiled.c + .symbols.txt; dnspy_out/DivxTac/*.cs (DetourMgr.cs, phmap/*, ManagedDetourMgrlockRef.cs). Native init at 0x1000100c (Instance ctor) and FunctionMap initializer.
The map is flat_hash_map<enum GlobalOffsets, unsigned char*>. ANSWER: (1) Enumerate the GlobalOffsets enum members if recoverable (what client functions/addresses are watched). (2) HOW does DetourMgr decide something is detoured — does it store & compare original prologue BYTES (inline-hook detection via memcmp), store expected addresses, or install its own detours? (3) Is DetourMgr checked on the AntiCheatThreadLoop timer or once? (4) Does any of it read or hash Extensions.dll .text?
This determines whether RaijinLab may hook client functions and which are landmined. Write note_file, return schema. integrity_relevance must explicitly cover whether specific client function bytes are watched (and which).`,
  },
  {
    key: 'ext-sink-and-triggers',
    note: 'C:\\Ascension\\Workspace\\RaijinLab\\notes\\11c_extensions_sink_body.md',
    prompt: `Reverse the Extensions.dll violation SINK sub_100b5650 (VA 0x100b5650 / file 0xb4a50) BODY and its trigger cadence.
Use ghidra_out/Extensions.dll.decompiled.c if present (background job) else capstone (re/scripts/disasm_window.py, and follow calls manually).
ANSWER: (1) What does sub_100b5650 DO with the (severity, blob) args — build a packet and send via WS2_32 (Extensions has its own socket path)? set a local/global flag? stage into the MemoryBridge? call into ExtendedAnticheatMgr? Trace the callee chain far enough to classify the report channel. (2) Find the COMMON PARENT/driver of the 14 vector functions: are the 14 anti-debug checks invoked once at init, or on a thread/timer loop? Identify the function that calls the vectors (walk xrefs up from a couple vector entry VAs e.g. 0x100b5b21, 0x100b6a82) and whether it is spawned via CreateThread / scheduled. (3) Note whether the sink or its parent is itself inside .vm_sec (virtualized) range 0xd6e000+.
This decides whether a one-time load-time bypass suffices or a persistent hook is needed. Write note_file, return schema.`,
  },
  {
    key: 'ext-network-ac',
    note: 'C:\\Ascension\\Workspace\\RaijinLab\\notes\\11d_extensions_network_ac.md',
    prompt: `Map the Extensions.dll NETWORK anti-cheat surface: ExtendedAnticheatMgr + the AC opcodes.
Strings present: SMSG_WARDEN_DATA, CMSG_WARDEN_DATA, CMSG_ANTICHEAT_ALERT, CMSG_ANTICHEAT_VERSION, and RTTI .?AVExtendedAnticheatMgr@@ / TemplatedSingleton<ExtendedAnticheatMgr>. Use capstone + const_xref.py + string xrefs on Extensions.dll (and ghidra_out Extensions if ready).
ANSWER: (1) Numeric opcode VALUES for CMSG_ANTICHEAT_ALERT, CMSG_ANTICHEAT_VERSION, SMSG_WARDEN_DATA, CMSG_WARDEN_DATA (find the opcode<->handler registration / enum). (2) The ExtendedAnticheatMgr singleton instance location + its methods; where is the SMSG_WARDEN_DATA handler and what does it do (is legacy Blizzard Warden actually live, or is the opcode repurposed as a shell for the DivxTac/Extensions custom checks?). (3) Relationship between the 14-vector local sink (sub_100b5650) and the network path — does the sink feed CMSG_ANTICHEAT_ALERT? (4) CMSG_ANTICHEAT_VERSION — what version/handshake is sent (patch-detection?). Write note_file, return schema.`,
  },
  {
    key: 'mmgr64-memorybridge',
    note: 'C:\\Ascension\\Workspace\\RaijinLab\\notes\\11e_mmgr64_memorybridge.md',
    prompt: `Confirm and fully document MMgr64.exe as the MemoryBridge server and rule in/out any anti-cheat role.
Source: ghidra_out/MMgr64.exe.decompiled.c + .symbols.txt + .imports_xref.txt (x64, base 0x140000000). Imports: OpenProcess(x3), CreateFileMappingW/MapViewOfFile(x3), IsDebuggerPresent(x2), TerminateProcess. NO ReadProcessMemory/hashing seen.
ANSWER: (1) Confirm the shared-memory handshake: object-token generation/validation, request/response mapping + event names, protocol version 3, PID + session validation (strings in note 03). (2) The command set (Alloc/Free/CreateTable/Read/Write/Projected queries...) — enumerate. (3) WHY OpenProcess on the client — only for session check + liveness wait, or does it also duplicate handles / read memory? Confirm it never ReadProcessMemory nor hashes the client. (4) The 6 table handles (record counts 6801/36548/127121/18561/562792/10667) — what content (DBC mirrors)? (5) IsDebuggerPresent usage — self anti-debug only? (6) Consequence if MMgr64 is killed/spoofed for RaijinLab. integrity_relevance = definitive statement it is NOT a client-memory integrity scanner (or evidence it is). Write note_file, return schema.`,
  },
  {
    key: 'ascension-warden-heritage',
    note: 'C:\\Ascension\\Workspace\\RaijinLab\\notes\\11f_ascension_scan_divxdecoder.md',
    prompt: `Two quick determinations on Ascension.exe (base 0x400000, stock 3.3.5.12340) + DivxDecoder.dll.
(A) Legacy Warden/Scan.dll heritage: strings ScanDLLStart, IsScanDLLFinished, .\\Scan.dll, ScanDLLGlue.cpp, SMSG_ADDON_INFO, &sessionKeyHash=, ?info_hash=, IsLinuxClient. Determine whether the legacy Blizzard Warden/ScanDLL path is LIVE (referenced by real code, wired to a network handler) or DEAD stock code superseded by Extensions/DivxTac. Check xrefs to ScanDLLStart and whether Scan.dll is ever created/loaded. Note the IsLinuxClient string — is it the cxmplexpack-style unlocker hook name or stock?
(B) DivxDecoder.dll side-load hypothesis: it exports DivxDecode/InitializeDivxDecoder/SetOutputFormat/UnInitializeDivxDecoder and is imported by Ascension.exe. Timestamp 2004 (original DivX). Is it a trojaned proxy/side-load pivot for AC (e.g. loads DivxTac, tampered exports) or a legit untouched codec? Check its entrypoint/exports for anomalies (does it LoadLibrary DivxTac / resolve AC?). Use pefile + capstone + string scan.
Write note_file, return schema. integrity_relevance: whether either provides a client-integrity/scan mechanism relevant to RaijinLab.`,
  },
]

phase('Deepen')
const results = await pipeline(
  DIMENSIONS,
  d => agent(d.prompt + "\n\n" + PATHS + "\n\nWrite your full markdown analysis to: " + d.note, {
        label: 'deepen:' + d.key, phase: 'Deepen', schema: FINDING_SCHEMA, effort: 'high' })
        .then(f => f ? { ...f, _key: d.key } : null),
  // Verify stage runs per-finding as soon as its deepen completes
  (finding) => {
    if (!finding) return null
    return agent(
      `You are an adversarial verifier. A prior RE agent produced this finding about the Ascension anti-cheat:\n\n` +
      `SUBSYSTEM: ${finding.subsystem}\nHEADLINE: ${finding.headline}\nINTEGRITY_RELEVANCE: ${finding.integrity_relevance}\n` +
      `EVIDENCE: ${JSON.stringify(finding.evidence)}\n\n` +
      `Independently try to REFUTE the headline and especially the integrity_relevance claim (does this subsystem hash/checksum/byte-compare Extensions.dll or client .text?). ` +
      `Re-open the same binaries/Ghidra/dnSpy outputs and check the specific addresses cited. Default to UNCERTAIN if you cannot reproduce the evidence; REFUTED if you find contrary evidence; CONFIRMED only if the cited addresses/strings check out. ` +
      `Note file to consult/cross-check: ${finding.note_file}\n\n` + PATHS,
      { label: 'verify:' + finding._key, phase: 'Verify', schema: VERDICT_SCHEMA, effort: 'high' })
      .then(v => ({ finding, verdict: v }))
  }
)

return results.filter(Boolean)
