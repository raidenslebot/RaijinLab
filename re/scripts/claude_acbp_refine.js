export const meta = {
  name: 'raijin-acbp-refine',
  description: 'Refine + polish + expand the AC breakpoint catalog. 3 agents: (1) enrich every BP with hex bytes + safe-patch bytes + Ghidra symbol + runtime-side neutralizer cross-ref, (2) generate multi-tool artifacts (Frida JS, Ghidra bookmark script, IDA py, refreshed x32dbg script), (3) synthesize refined v2 catalog in place.',
  phases: [
    { title: 'Enrich',     detail: 'per-BP: hex prologue, patch bytes, Ghidra symbol, runtime neutralizer, expected observation' },
    { title: 'Artifacts',  detail: 'Frida hook JS + Ghidra .py + IDA .py + refreshed x32dbg script' },
    { title: 'Synthesize', detail: 'refined catalog v2 replaces 12_ac_breakpoint_catalog.md + INDEX/handoff updates' },
  ],
}

const CTX = `
============================================================
YOU ARE REFINING AN EXISTING CATALOG — DO NOT REBUILD
============================================================
File: C:\\Ascension\\Workspace\\RaijinLab\\notes\\12_ac_breakpoint_catalog.md
Size: 62 KB, 11 subsystems (S1..S11), 104 breakpoint rows.

Subsystem map:
  S1  Startup / Boot phase (Extensions self-unpack, hook installer, trampolines)
  S2  AC thread spawn (parent monitor loop FUN_10a3dc20)
  S3  Extensions 14 anti-debug vectors -> sink FUN_100b5650
  S4  DivxTac managed detection loop
  S5  Server-driven bootstrap (opcodes 14/35, magic 0xDEADBABE)
  S6  DetourMgr / GlobalOffsets (VERIFIED INERT — do not spend BP slots here)
  S7  Network AC emit sites (opcodes 1311/1312 + Warden 0x2E7 on the wire)
  S8  MMgr64 IPC (MemoryBridge protocol — not AC, do not tamper)
  S9  Legacy Warden / Scan.dll (dead in this build)
  S10 HWID collection (\\\\.\\PhysicalDrive0 + SMART/STORAGE IOCTLs)
  S11 Ascension.exe native Warden (in-process WardenClient.cpp @ 0x7DA200-0x7DAAE0) — LIVE, server-driven

Supporting files (READ):
  notes/11a_divxtac_ac_logic.md          — DivxTac managed AC ground truth
  notes/11b_divxtac_detourmgr.md         — DetourMgr proof-of-inert
  notes/11c_extensions_sink_body.md      — Extensions violation sink FUN_100b5650 body
  notes/11d_extensions_network_ac.md     — Extensions network AC opcodes + ExtendedAnticheatMgr
  notes/11e_mmgr64_memorybridge.md       — MMgr64 IPC (not AC)
  notes/11f_ascension_scan_divxdecoder.md — Ascension legacy Warden + DivxDecoder side-load hypothesis
  notes/13_ac_evasion_strategy.md        — companion evasion doc (runtime-side patches)
  notes/14_gap{2,4,5,6,7,8}_*.md         — completeness-critic gap patches (Warden discovery + others)
  notes/HANDOFF_claude.md                — Claude's AC-RE handoff
  notes/runtime/R04_stealth_surface.md   — stealth loader posture
  re/ghidra_out/Extensions.dll.decompiled.c (~1.1 MB)  — canonical Extensions decomp
  re/ghidra_out/DivxTac.dll.decompiled.c   (~44 KB)
  re/ghidra_out/MMgr64.exe.decompiled.c    (~34 KB)
  re/dnspy_out/DivxTac/*.cs                — managed DivxTac IL
  re/ext_antidebug_vectors.json            — machine-readable 14 vectors + techniques
  re/ascension_ac_opcodes.json             — machine-readable AC opcode table
  re/ext_virtualprotect_callsites.json     — VirtualProtect call site classification
  re/divxtac_globaloffsets.json            — DetourMgr GlobalOffsets (empty — proof-of-inert)
  re/wowerror_triage.json                  — WowError.exe crash-uploader triage
  re/scripts/set_ac_breakpoints.x32dbg.txt — current x32dbg BP script (needs refresh)

Binaries (offline, sha-verified stable, do NOT reprove):
  re/dumps/Ascension.exe   (x86, base 0x400000)
  re/dumps/Extensions.dll  (x86, base 0x10000000)
  re/dumps/DivxTac.dll     (x86, base 0x10000000)
  re/dumps/MMgr64.exe      (x64, base 0x140000000)
  re/dumps/WowError.exe    (x86, base 0x400000)

Runtime-side handlers (from runtime/src/game/Actions.cpp + bridge/Dispatch.cpp):
  ArmUnlock -> TaintPatch::ApplyHardwareGatesOnly (patches HW-event gates)
  Spell_C_CastSpell / TargetGuid / Interact / MoveTo / Jump / etc.
  1.7.3-reg-self-heal: worker re-registers IsLinuxClient every 3s
  CTM force-off via addon/core/DisableCTM.lua (hooksecurefunc + event driven)

Ground-truth constants (do NOT re-derive):
  Extensions sink FUN_100b5650 @ VA 0x100b5650 / file 0xb4a50
  14 anti-debug vector caller VAs: 0x100b5cba 0x100b5eb8 0x100b6154 0x100b6731 0x100b6954 0x100b6c32 0x100b6ff1 0x100b7189 0x100b72f7 0x100b74bd 0x100b76b8 0x100b7c79 0x100b80b2 0x100b82e4
  AC opcodes: 1311 (CMSG_ANTICHEAT_ALERT), 1312 (CMSG_ANTICHEAT_VERSION), 0x2E6/742 (SMSG_WARDEN_DATA), 0x2E7/743 (CMSG_WARDEN_DATA), server 14 (AnticheatInitialize), 35 (BannedProcessList)
  DivxTac handler context magic: 0xDEADBABE (int32 -559039810). NOT 0xDEADC0BE.
  Live Warden module in Ascension.exe: 0x7DA20F - 0x7DAB6D (Handler 0x7DA850, memcpy primitives 0x7DA500 / 0x7DA550, SendResponse 0x7DAAE9)
  DivxTac AntiCheatThreadLoop cadence: 60s -> DetectHackProcesses -> 60s -> DetectHackModules -> 0s -> DetectHackTitles -> DetectDebugger -> loop
  Extensions VirtualProtect callsites: 4 total; sites at 0x1000106b + 0x100010e4 are load-time self-unpack (no self-hash)

Non-negotiable style rules for the refined catalog:
  - Preserve subsystem numbering (S1..S11); do NOT renumber
  - Every BP row keeps stable ID (S3.02, S11.06 etc.) so external references don't rot
  - Add columns without removing existing ones
  - Cite file + line when referencing addon or runtime source
`

const ENRICH_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['bp_enrichments','gaps_found','summary'],
  properties: {
    bp_enrichments: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      required: ['id','va','hex_prologue','patch_bytes','ghidra_symbol','runtime_neutralizer','expected_observation'],
      properties: {
        id: { type: 'string', description: 'stable BP id from v1, e.g. S3.02, S11.06' },
        va: { type: 'string', description: '0xNNNNNNNN address' },
        hex_prologue: { type: 'string', description: 'first 8-16 bytes at VA (hex, space-separated) for identification' },
        patch_bytes: { type: 'string', description: 'safe-bypass byte sequence (e.g. C3 for ret, 90 90 for nop nop, xor eax,eax + ret)' },
        ghidra_symbol: { type: 'string', description: 'Ghidra FUN_/thunk name if known, else the closest label' },
        runtime_neutralizer: { type: 'string', description: 'if the runtime already handles this (Actions.cpp handler, config flag, ChatHandler cmd), name it; else "none — patch site only"' },
        expected_observation: { type: 'string', description: 'what you SEE when the BP fires (register values, packet content, chat, log line)' },
      } } },
    gaps_found: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      required: ['gap','suggested_bp'],
      properties: {
        gap: { type: 'string', description: 'AC surface not covered by v1 catalog' },
        suggested_bp: { type: 'string', description: 'new BP row spec' },
      } } },
    summary: { type: 'string' },
  },
}

const ART_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['files_written'],
  properties: {
    files_written: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      required: ['path','purpose','line_count'],
      properties: {
        path: { type: 'string' },
        purpose: { type: 'string' },
        line_count: { type: 'integer' },
      } } },
    summary: { type: 'string' },
  },
}

const SYNTH_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['catalog_path','section_count','bp_count','changelog_entries'],
  properties: {
    catalog_path: { type: 'string' },
    section_count: { type: 'integer' },
    bp_count: { type: 'integer' },
    changelog_entries: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
  },
}

phase('Enrich')

const enrich = await agent(
  `You are refining the AC breakpoint catalog. Read notes/12_ac_breakpoint_catalog.md end-to-end + the supporting notes named in CTX + the JSON data files. For EVERY BP row in the catalog (~104 rows across S1..S11), produce enrichment covering:\n` +
  `  1. hex_prologue: read the first 8-16 bytes at the BP's VA from the corresponding binary via python + pefile. Two lines of guidance: (a) for Extensions.dll VAs subtract image base 0x10000000 to get file offset then read bytes; (b) for Ascension.exe VAs subtract 0x400000 to get file offset. This lets a user cross-verify the BP against a specific build.\n` +
  `  2. patch_bytes: the SAFE-BYPASS sequence a user would poke to neutralize this BP. Prefer minimum-diff (e.g. \\"C3\\" for ret, \\"33 C0 C3\\" for xor eax,eax + ret, \\"90 90 90 90 90\\" for NOP a 5-byte call, \\"EB xx\\" for short jmp over a check). Skip if the BP is trace-only (do not invent patches for observation-only BPs).\n` +
  `  3. ghidra_symbol: the FUN_/thunk name Ghidra emits for that VA (grep re/ghidra_out/*.decompiled.c for the VA hex). If not decompiled, say "not-in-ghidra-out".\n` +
  `  4. runtime_neutralizer: cross-reference to what the runtime + addon side ALREADY handles. Names to check: TaintPatch::ApplyHardwareGatesOnly (S3.05 HW-DR), Actions.cpp handlers, DisableCTM.lua (S3.d window scans indirectly), the 3-tier CastSpell fallback (S3.03 IsDebuggerPresent bypass). If none, say "none — patch site only".\n` +
  `  5. expected_observation: what a user SEES when the BP fires. Registers, packet contents, chat message, log line. Concrete, not vague.\n\n` +
  `Also identify GAPS — AC surface not covered by v1. Candidates to check specifically:\n` +
  `  - WowError.exe crash upload path (re/wowerror_triage.json exists — has POST endpoint / payload fields). Not currently in S1-S11.\n` +
  `  - DivxTac MasterHardDiskSerial detailed IOCTL entry points beyond what S10 covers.\n` +
  `  - Extensions.dll VirtualProtect callsites 3 + 4 (build JMP trampolines — potential DetourMgr-adjacent hook detection surface, even though DetourMgr itself is inert).\n` +
  `  - Any string in re/ghidra_out/Extensions.dll.symbols.txt matching AC-suggesting patterns (\"ban\", \"detect\", \"cheat\", \"integrity\", \"warden\", \"anticheat\") that isn't currently referenced by S1-S11.\n\n` +
  `Return ENRICH_SCHEMA. Aim for 100+ enrichments — the whole catalog. Cite Ghidra file:line when helpful.\n\n` + CTX,
  { label: 'enrich:bps', phase: 'Enrich', schema: ENRICH_SCHEMA, effort: 'high' })

log('Enrichment complete: ' + (enrich?.bp_enrichments?.length ?? 0) + ' rows enriched, ' + (enrich?.gaps_found?.length ?? 0) + ' gaps flagged.')

phase('Artifacts')

const enrichBlob = JSON.stringify(enrich || {}, null, 1)

const art = await agent(
  `Produce four operator artifacts. Do NOT summarize — WRITE the files.\n\n` +
  `1. C:\\\\Ascension\\\\Workspace\\\\RaijinLab\\\\re\\\\scripts\\\\ac_frida_hooks.js — runnable Frida agent that Interceptor.attach()es EVERY BP in the enrichment (or a curated top-30 if 100+ is impractical). For each hook: log guid/args, backtrace with symbol resolution via Module.findExportByName + Process.enumerateModules, dump packet bodies for S7/S11 hooks (via CDataStore inspection at ptr+0x00 length + ptr+0x10 opcode). Include an at-a-glance help header + module boot log. Frida runs against Ascension.exe via 'frida -n Ascension.exe -l ac_frida_hooks.js'.\n\n` +
  `2. C:\\\\Ascension\\\\Workspace\\\\RaijinLab\\\\re\\\\scripts\\\\ac_ghidra_bookmarks.py — Ghidra headless script that iterates the enrichment list and: (a) creates a bookmark at each VA with the BP id + expected observation, (b) sets a comment listing safe-patch bytes, (c) creates a named-label for each VA using the BP id + short description. Uses the Ghidra API (currentProgram.getBookmarkManager, currentProgram.getListing().setComment). Runnable via 'analyzeHeadless.bat <proj> -postScript ac_ghidra_bookmarks.py'.\n\n` +
  `3. C:\\\\Ascension\\\\Workspace\\\\RaijinLab\\\\re\\\\scripts\\\\ac_ida.py — IDA Pro Python 3 script that iterates the enrichment and: (a) sets a comment at each address with the BP id + expected observation, (b) sets a label using the BP id + short name, (c) adds an anterior comment with the safe-patch bytes. Use idc.set_cmt / idc.set_name / idc.get_fchunk_attr for control-flow chunks.\n\n` +
  `4. C:\\\\Ascension\\\\Workspace\\\\RaijinLab\\\\re\\\\scripts\\\\set_ac_breakpoints.x32dbg.txt — REFRESH the existing v1 x32dbg script. Add newly-flagged BPs from the gap list, add commentary tying each BP to its runtime neutralizer (if any). Keep the existing sections but promote it from a raw BP dump to a hierarchical script with sections per subsystem and a header explaining the trigger sequence. Works in x32dbg and x64dbg (identical script syntax).\n\n` +
  `Return ART_SCHEMA. Per-file: absolute path, purpose, line count.\n\n` +
  `--- ENRICHMENT DATA (use for BP list; write ALL rows into artifacts, not just a summary) ---\n${enrichBlob}\n\n` + CTX,
  { label: 'artifacts', phase: 'Artifacts', schema: ART_SCHEMA, effort: 'high' })

log('Artifacts complete: ' + (art?.files_written?.length ?? 0) + ' files written.')

phase('Synthesize')

const artBlob = JSON.stringify(art || {}, null, 1)

const synth = await agent(
  `Synthesize the refined AC breakpoint catalog v2. REPLACE C:\\\\Ascension\\\\Workspace\\\\RaijinLab\\\\notes\\\\12_ac_breakpoint_catalog.md in place — new content. Preserve every stable BP id (S1.01 .. S11.09) so external cross-refs don't rot; add NEW rows as SXX.XX with next sequence number in that subsystem, or as SXX.M+ suffix.\n\n` +
  `Structure the refined catalog:\n\n` +
  `  # Header\n` +
  `    - status line (version, date, replaces v1)\n` +
  `    - one-paragraph executive summary of what the catalog is + what changed since v1\n` +
  `    - quick-reference chart: subsystem -> AC risk class -> primary neutralizer (runtime or trace-only)\n` +
  `    - link to companion notes (13 evasion, R04 stealth surface, HANDOFF_claude, ROADMAP_1_7)\n\n` +
  `  # Table of contents (linked, one line per subsystem + Artifacts + Trigger sequence + Cross-reference)\n\n` +
  `  # Per-subsystem (S1..S11 same order, don't renumber):\n` +
  `    - subsystem intro paragraph (unchanged unless new info)\n` +
  `    - BP table WITH NEW COLUMNS: id | location (module+VA) | hex prologue | trigger | expected observation | safe patch bytes | runtime neutralizer | confidence\n` +
  `    - post-table notes (Ghidra symbols, gotchas)\n\n` +
  `  # Newly-added subsystems from the enrich gap list — insert as S12+ with 'Added Round 3' marker\n\n` +
  `  # Artifacts section — enumerate the 4 files the artifacts agent wrote with usage examples\n\n` +
  `  # Trigger sequence — refresh the existing one, add any new BPs\n\n` +
  `  # Cross-reference summary — expand the existing one with the runtime_neutralizer mapping (which BPs are already handled by the shipped runtime/addon vs. patch-site-only)\n\n` +
  `  # Verified inert — extend with anything the enrichment confirmed inert\n\n` +
  `  # Changelog vs v1 — bullet list of every substantive change (new BPs, corrections, new columns, new artifacts)\n\n` +
  `Also update C:\\\\Ascension\\\\Workspace\\\\RaijinLab\\\\notes\\\\INDEX.md to note the v2 catalog + the four new re/scripts/ac_*.js/py/txt artifacts. Also append a short "AC BP catalog refined to v2" section to notes/HANDOFF_claude.md.\n\n` +
  `Return SYNTH_SCHEMA. catalog_path = the 12_ac_breakpoint_catalog.md path. bp_count = total BP rows in v2 (should be >= 104 + gap count).\n\n` +
  `--- ENRICHMENT ---\n${enrichBlob}\n\n--- ARTIFACTS ---\n${artBlob}\n\n` + CTX,
  { label: 'synth:catalog-v2', phase: 'Synthesize', schema: SYNTH_SCHEMA, effort: 'high' })

log('Synthesis complete: ' + (synth?.bp_count ?? 0) + ' BPs, ' + (synth?.section_count ?? 0) + ' sections.')

return {
  enriched: enrich?.bp_enrichments?.length ?? 0,
  gaps: enrich?.gaps_found?.length ?? 0,
  artifacts: art?.files_written?.length ?? 0,
  bp_count_v2: synth?.bp_count ?? 0,
  section_count: synth?.section_count ?? 0,
  files: (art?.files_written || []).map(f => f.path).concat(synth?.catalog_path ? [synth.catalog_path] : []),
}
