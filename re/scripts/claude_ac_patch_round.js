export const meta = {
  name: 'raijin-ac-patch-r1',
  description: 'Patch round: address 6 static gaps identified by completeness critic — re-verify 0xDEADC0BE, raw-disasm FunctionMap initializer, hash-diff dumps vs mid_download, WowError.exe triage, native SMSG_WARDEN_DATA handler, Extensions→DivxTac load edge.',
  phases: [
    { title: 'Patch', detail: '6 gap-remediation agents in parallel + 1 handoff-updater' },
  ],
}

const PATHS = `
BINARIES:
  Extensions.dll : C:\\Ascension\\Workspace\\RaijinLab\\re\\dumps\\Extensions.dll   (x86, image base 0x10000000, .vm_sec VMProtect 33KB, .text 11.6MB normal-native)
  DivxTac.dll    : C:\\Ascension\\Workspace\\RaijinLab\\re\\dumps\\DivxTac.dll      (x86, C++/CLI mixed, image base 0x10000000)
  MMgr64.exe     : C:\\Ascension\\Workspace\\RaijinLab\\re\\dumps\\MMgr64.exe       (x64, image base 0x140000000)
  Ascension.exe  : C:\\Ascension\\Workspace\\RaijinLab\\re\\dumps\\Ascension.exe    (x86, image base 0x400000)
  DivxDecoder.dll: C:\\Ascension\\Workspace\\RaijinLab\\re\\dumps\\DivxDecoder.dll  (x86)
  WowError.exe   : C:\\Ascension\\Workspace\\RaijinLab\\re\\dumps\\WowError.exe     (x86; NEVER TRIAGED in v1)
  ALTERNATE (mid-download): C:\\Ascension\\Workspace\\RaijinLab\\re\\dumps_mid_download\\   — contains Ascension.exe / Extensions.dll / DivxTac.dll / MMgr64.exe / DivxDecoder.dll captured DURING download; may or may not match final dumps.

PRE-BAKED SOURCE:
  Ghidra: C:\\Ascension\\Workspace\\RaijinLab\\re\\ghidra_out\\{DivxTac,MMgr64,Extensions}.dll.decompiled.c + .symbols.txt + .imports_xref.txt
  dnSpy DivxTac managed: C:\\Ascension\\Workspace\\RaijinLab\\re\\dnspy_out\\DivxTac\\*.cs (AntiCheatService.cs, BannedProccessesManaged.cs, Opcodes.cs, DetourMgr.cs (stub), -Module-.cs, MasterHardDiskSerial.cs, ...)
  DivxTac managed .cs files are the AUTHORITATIVE source for managed methods; Ghidra shows <decompile failed> for __clrcall bodies.
  Existing notes: C:\\Ascension\\Workspace\\RaijinLab\\notes\\{11a..11f, 12, 13, HANDOFF_claude, FRIDA_probe_plan}.md
  Existing extractions: C:\\Ascension\\Workspace\\RaijinLab\\re\\{divxtac_globaloffsets, ascension_ac_opcodes, ext_antidebug_vectors, ext_virtualprotect_callsites}.json
  Existing YARA: C:\\Ascension\\Workspace\\RaijinLab\\re\\yara\\{ascension_ac.yar, ascension_ac_v2.yar}
  Existing x32dbg script: C:\\Ascension\\Workspace\\RaijinLab\\re\\scripts\\set_ac_breakpoints.x32dbg.txt

TOOLING:
  python (pefile, capstone, lief, yara-python) — Windows: use 'python' not 'python3'
  dnSpy: C:\\Ascension\\Workspace\\RaijinLab\\tools\\bin\\dnSpy\\dnSpy.Console.exe -l "IL with C#" -t <TypeOrMethod> <dll>
  Grok's capstone helpers in re/scripts/: disasm_window.py, const_xref.py, xref_imports.py, classify_checks.py

GROUND-TRUTH FROM V1 ROUND:
  - Extensions violation sink FUN_100b5650 @ 0x100b5650; 14 direct E8 callers.
  - Sink integrity_relevance = CONFIRMED no self-hash (V1 verdict).
  - DivxTac imports NO ReadProcessMemory / Crypt* / VirtualProtect. DivxTac managed BannedProccessesManaged.ToLower()+.dll name-match confirmed.
  - MMgr64 = MemoryBridge server; no ReadProcessMemory; not AC.
  - Opcode 1311 = CMSG_ANTICHEAT_ALERT; 1312 = CMSG_ANTICHEAT_VERSION; DivxTac inbound opcodes 14 (init) + 35 (banned list) allegedly registered with magic context 0xDEADC0BE.
`

const PATCH_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['gap','verdict','output_file','summary'],
  properties: {
    gap: { type: 'string' },
    verdict: { type: 'string', enum: ['CONFIRMED','REFUTED','PARTIAL','INDETERMINATE'] },
    output_file: { type: 'string' },
    summary: { type: 'string' },
    corrections: { type: 'array', items: { type: 'string' } },
    new_facts: { type: 'array', items: { type: 'string' } },
    followup: { type: 'array', items: { type: 'string' } },
  },
}

phase('Patch')

const GAPS = [
  {
    key: 'gap2-deadc0be-reverify',
    out: 'C:\\Ascension\\Workspace\\RaijinLab\\notes\\14_gap2_deadc0be_reverify.md',
    prompt: `GAP 2 (CRITICAL): Re-derive the 0xDEADC0BE context magic from primary source.
Prior V1 notes (11a §6 and 11d) claim ClientServices::fpSetMessageHandler((Opcodes)14, AnticheatInitializeHandler, /*context=*/(void*)-559039810, ...) and same for opcode 35 → 0xDEADC0BE. Critic notes literal bytes {BE C0 AD DE} were never grepped in dumps.
DO:
  (1) Open dnspy_out/DivxTac/-Module-.cs and search for the SetMessageHandlers method (VA 0x100058c8 per 11a) and the AnticheatInitializeHandler / AnticheatBannedProcessListHandler registrations. Report the actual literal integer argument passed as the context (may be -559039810 / 0xDEADC0BE / something else). If .cs shows the numeric literal, cite the line.
  (2) If not visible in .cs, run:  C:\\Ascension\\Workspace\\RaijinLab\\tools\\bin\\dnSpy\\dnSpy.Console.exe -l "IL with C#" -t SetMessageHandlers C:\\Ascension\\Workspace\\RaijinLab\\re\\dumps\\DivxTac.dll   and read the IL to confirm.
  (3) Additionally: python-scan the raw DivxTac.dll bytes for literal 0xDEADC0BE little-endian (BE C0 AD DE) — write and run a small script (report offsets). Do the same in Extensions.dll to see if the magic is a cross-module handshake.
  (4) State the verdict: CONFIRMED (magic is 0xDEADC0BE) / REFUTED (magic is X instead) / PARTIAL.
Write findings to output_file. Update HANDOFF_claude.md with a footnote patch if verdict differs from V1. Return schema.`,
  },
  {
    key: 'gap4-functionmap-rawdisasm',
    out: 'C:\\Ascension\\Workspace\\RaijinLab\\notes\\14_gap4_functionmap_rawdisasm.md',
    prompt: `GAP 4 (HIGH): Raw-disassemble the DivxTac FunctionMap initializer to definitively confirm empty-map claim.
The V1 extraction concluded 0-member GlobalOffsets enum + no inserts, but the initializer might do runtime SetProcAddress-based insertion the extractor missed.
DO:
  (1) In DivxTac.dll.symbols.txt find any symbol containing "FunctionMap" or "$initializer$". Note the native VA (per 11a it's around 0x10001028 for phmap empty-init but the initializer itself may differ).
  (2) Use capstone: python re/scripts/disasm_window.py C:/Ascension/Workspace/RaijinLab/re/dumps/DivxTac.dll <VA> --after 400  and read the sequence.
  (3) Trace for these patterns: (a) any 'mov [reg+N], <ptr>' writing pointers into the phmap struct; (b) GetProcAddress-return values being stored; (c) any calls to phmap insert / emplace functions. Report each.
  (4) Verdict: CONFIRMED empty at init (map populated at runtime by external code) / CONFIRMED empty forever / REFUTED (initializer inserts N entries — list them with client-fn addresses).
  (5) If REFUTED, patch divxtac_globaloffsets.json with the discovered entries.
Write findings to output_file. Return schema. new_facts = list of any specific client function VAs discovered as monitored.`,
  },
  {
    key: 'gap5-hash-diff-dumps',
    out: 'C:\\Ascension\\Workspace\\RaijinLab\\notes\\14_gap5_hash_diff_dumps.md',
    prompt: `GAP 5 (HIGH): SHA-256 hash-diff dumps vs dumps_mid_download to confirm we analyzed the final binaries.
DO:
  (1) Write and run a python script that SHA-256s all files in re/dumps and re/dumps_mid_download and prints a table + diff report.
  (2) For any changed binary: run pefile timestamp check (TimeDateStamp) on both to see if a version bump happened.
  (3) If Extensions.dll / DivxTac.dll / MMgr64.exe / Ascension.exe differ, note that ALL prior VAs are potentially stale.
  (4) Verdict: CONFIRMED analyzed=final / REFUTED (list which binaries differ) / PARTIAL.
Also write the manifest to C:\\Ascension\\Workspace\\RaijinLab\\re\\dumps_manifest.json — schema { "final": {name:{sha256,size,timestamp}}, "mid_download": {...}, "diff": [{name, action}]  }.
Write findings to output_file. Return schema.`,
  },
  {
    key: 'gap6-wowerror-triage',
    out: 'C:\\Ascension\\Workspace\\RaijinLab\\notes\\14_gap6_wowerror_triage.md',
    prompt: `GAP 6 (HIGH): First-pass triage of WowError.exe — never analyzed in V1.
DO:
  (1) pefile triage: machine, timestamp, imports, exports, sections, sizes, entropy per section. Report as a table.
  (2) String scan: use re/scripts/string_scan.py or a small script to dump strings; look for AC-shaped tokens: 'anticheat', 'ban', 'warden', 'PhysicalDrive', 'HWID', 'CMSG_', 'SMSG_', 'HTTP', 'https://', 'crash-report', 'symbol', 'PDB', 'sha', 'crypt', 'DivxTac', 'MMgr'.
  (3) xref check: does Ascension.exe reference "WowError" / spawn it? Grep Ascension.exe strings + imports for WowError.
  (4) Assess AC role: crash-report + upload channel is a legitimate ban vector (client PDB + crash context posted to server).
  (5) Verdict: is WowError.exe (a) benign crash reporter, (b) has an AC role (uploads context that can identify RaijinLab), (c) other.
Write to output_file. Return schema. If (b) — followup should list what fields it uploads.`,
  },
  {
    key: 'gap7-warden-native-handler',
    out: 'C:\\Ascension\\Workspace\\RaijinLab\\notes\\14_gap7_warden_native_handler.md',
    prompt: `GAP 7 (HIGH): Locate the native SMSG_WARDEN_DATA (0x2E6, dec 742) / CMSG_WARDEN_DATA (0x2E7, dec 743) handler in Extensions.dll.
V1 opcode-table JSON said the native Warden handler is registered in Extensions.dll but was never actually decompiled.
DO:
  (1) Grep Extensions.dll.decompiled.c for immediate values 0x2E6, 0x2E7, 742, 743, and for the string "WARDEN". Note every callsite.
  (2) In Extensions.dll, find ClientServices::SetMessageHandler-style registration for opcode 742 (search near immediate 0x2E6). Alternatively grep the .decompiled.c for pattern of registering a handler with a small integer opcode + function pointer.
  (3) Once handler VA found: read the FUN_100xxxxx body (should be around 200-2000 bytes) and CLASSIFY: (a) legacy Blizzard Warden challenge/response (module_seed + XOR data + CRC memory reads), (b) stub/no-op, (c) repurposed as shell for the DivxTac/Extensions custom checks.
  (4) If (a): report whether the challenge actually reads client .text bytes (memory-integrity check that survives DivxTac lacking it).
  (5) If Warden IS live: this contradicts V1's "DivxTac + Extensions FUN_100b5650 are the only detection paths" — flag prominently.
Write to output_file. Update 11d and 12 (breakpoint catalog) with new handler VA if found. Return schema.`,
  },
  {
    key: 'gap8-ext-divxtac-load-edge',
    out: 'C:\\Ascension\\Workspace\\RaijinLab\\notes\\14_gap8_ext_divxtac_load_edge.md',
    prompt: `GAP 8 (HIGH): Confirm WHICH binary loads DivxTac.dll — Extensions.dll, Ascension.exe, or something else.
DO:
  (1) Grep Ascension.exe strings for 'DivxTac' (string_scan.json → "Ascension.exe" section) and Extensions.dll strings.
  (2) In Ascension.exe imports_xref (from pe_triage.json), see if DivxTac.dll appears as a static import — Ascension.exe imports DivxDecoder.dll, NOT DivxTac.dll per V1.
  (3) In Extensions.dll.decompiled.c grep for 'DivxTac' string + xrefs. Look for LoadLibraryW / LoadLibraryExW / CorBindToRuntime calls near a DivxTac reference.
  (4) Same for Ascension.exe.decompiled.c IF a Ghidra output exists for it (may not — Ascension.exe is 7MB, likely too big). If not, use capstone const_xref.py to find 'DivxTac.dll' string xrefs.
  (5) Also check WowError.exe (see gap 6) for DivxTac references.
  (6) Verdict: which binary loads DivxTac.dll, at what call site, on what trigger (module init / user login / server opcode). This determines when DivxTac becomes active and thus when RaijinLab must be evasive.
Write to output_file. Return schema. new_facts = the specific loader VA + module name.`,
  },
]

const patchResults = await parallel(GAPS.map(g => () => agent(
  g.prompt + "\n\n" + PATHS + `\n\nOUTPUT_FILE: ${g.out}`,
  { label: g.key, phase: 'Patch', schema: PATCH_SCHEMA, effort: 'high' })))

const good = patchResults.filter(Boolean)
log(`Patch round complete: ${good.length}/${GAPS.length} gaps addressed`)

// Update HANDOFF with patch results — one final consolidator
const patchSummary = good.map(p =>
  `## ${p.gap}\nVERDICT: ${p.verdict}\nFILE: ${p.output_file}\nSUMMARY: ${p.summary}\n` +
  (p.corrections?.length ? `CORRECTIONS: ${JSON.stringify(p.corrections)}\n` : '') +
  (p.new_facts?.length ? `NEW FACTS: ${JSON.stringify(p.new_facts)}\n` : '')
).join('\n\n')

await agent(
  `Append a "Patch Round 1 (Static Gap Remediation)" section to C:\\Ascension\\Workspace\\RaijinLab\\notes\\HANDOFF_claude.md summarizing these 6 patch-round results and their impact on the prior HANDOFF conclusions. Also update notes/12_ac_breakpoint_catalog.md ONLY if any patch discovered a new breakpoint location or refuted an existing one (native Warden handler in gap 7, new GlobalOffsets entries in gap 4, WowError-triggered ban vector in gap 6, or a DivxTac load-edge BP in gap 8).\n\nPatch results:\n${patchSummary}\n\n` + PATHS,
  { label: 'consolidate-handoff', phase: 'Patch', effort: 'high' })

return { patched: good.length, gaps_addressed: good.map(g => g.gap), verdicts: good.map(g => ({ gap: g.gap, verdict: g.verdict })) }
