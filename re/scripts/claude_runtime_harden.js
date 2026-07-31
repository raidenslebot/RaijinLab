export const meta = {
  name: 'raijin-runtime-harden',
  description: 'Comprehensive audit + hardening of the injected RaijinLab runtime DLL. Identifies every worker-thread access to game state, every registered callback, every shared pointer, every hook site — then applies concrete fixes for use-after-free, data races, missing null guards, unbounded loops, and stale-pointer patterns causing random ACCESS_VIOLATION crashes.',
  phases: [
    { title: 'Audit',    detail: 'per-file scan of runtime/src — thread safety, callback lifetime, hook interference, null-deref hazards' },
    { title: 'Fix',      detail: 'apply concrete edits per audit finding across main.cpp, Dispatch.cpp, ObjectManager.cpp, Actions.cpp, TaintPatch.cpp, PebUnlink.cpp' },
    { title: 'Build',    detail: 'rebuild via tools\\build_runtime.bat, verify DLL landed at runtime/dist/, size + timestamp check' },
  ],
}

const CTX = `
============================================================
RAIJINLAB RUNTIME — HARDENING PASS
============================================================
The injected C++ DLL that provides Lua's runtime bridge on WoW 3.3.5 x86.
User reports recurring random ACCESS_VIOLATION crashes (0xC0000005) even
with almost every third-party addon disabled and a tiny 45 MB Lua heap.
Crash pattern:
  - Main tick -> Extensions.dll (AC callback dispatch +0x114255) -> WoW
    frame/render path -> AV writing to [null+8], or executing at heap
    garbage. Different EIPs across crashes.
  - Runtime is present in-process even when the addon is "disabled" in
    the AddOns menu (DLL is injected, worker thread is running, hooks are
    installed) — this is why disabling the addon didn't stop crashes.

User directive: assume the runtime is the culprit. Audit thoroughly, fix
thoroughly, no corner-cutting.

============================================================
SOURCE TREE (read every file)
============================================================
runtime/src/main.cpp                    (158 loc) - DllMain, worker thread, boot sequence
runtime/src/loader/loader.cpp           (205 loc) - LoadLibrary loader exe
runtime/src/core/Log.cpp / Log.h        - logging (thread-safe file writer?)
runtime/src/core/Config.cpp / Config.h  - env-driven config (RL_LOG, RL_PEB_UNLINK, etc.)
runtime/src/core/Patterns.cpp / .h      - IDA-style pattern scanner
runtime/src/core/PebUnlink.cpp / .h     - PEB LDR unlink + PE header wipe (STEALTH)
runtime/src/game/Offsets.cpp / .h       - hardcoded VAs for Ascension.exe
runtime/src/game/AddressDB.cpp / .h     - runtime address resolution
runtime/src/game/ObjectManager.cpp     (1044 loc) - OM enum, guid callbacks, PROBE
runtime/src/game/Actions.cpp           (418 loc)  - Spell_C_CastSpell, PetAttack, Interact, MoveTo, etc.
runtime/src/game/MainThread.cpp        (117 loc)  - main-thread dispatch (deferred exec?)
runtime/src/game/TaintPatch.cpp        (211 loc)  - HW event-gate patcher (unlock hardware-event checks)
runtime/src/game/Types.h               - game struct definitions
runtime/src/game/Mem.h                 - safe memory read helpers
runtime/src/bridge/Dispatch.cpp        (627 loc)  - IsLinuxClient Lua bridge dispatcher
runtime/src/bridge/Dispatch.h
runtime/src/lua/Lua.cpp                (102 loc)  - lua_State access + C API wrappers

Do NOT touch archive/ — legacy, not compiled.

============================================================
GROUND TRUTH (do not re-derive, use these constants)
============================================================
Ascension.exe base 0x400000, x86, no ASLR
FrameScript_RegisterFunction @ 0x817F90
FrameScript_Execute @ 0x819210
g_luaState @ 0xD3F78C
TLS index @ 0xD439BC
Spell_C_CastSpell @ 0x80DA40 (cdecl 3 args)
ClntObjMgrObjectPtr @ 0x4D4DB0 (guidLow, guidHigh, typeMask)
ClntObjMgrEnumVisibleObjects @ 0x4D4B30 (callback receives guidLow, guidHigh, filter as 12-byte cdecl)
Handler-registration magic in DivxTac: 0xDEADBABE (not 0xDEADC0BE)
Live Warden native handler: Ascension.exe 0x7DA20F+ (dormant on most realms)

============================================================
KNOWN LESSONS (do NOT undo, but VERIFY still in place)
============================================================
L1. Worker thread NEVER touches Lua. All Lua interaction must be from
    the main thread via a deferred-dispatch queue (MainThread.cpp).
    Violating this = R03 crash.
L2. 0x84F7A0 is a taint save/zero/restore helper — NOT lua_setfield.
    Do not call it as if it were. R02 lesson.
L3. Handler-registration magic constant is 0xDEADBABE. Any use of
    0xDEADC0BE is Grok's original arithmetic error.
L4. TaintPatch::ApplyHardwareGatesOnly is the ONE HW-DR patch site. Do
    not add more.
L5. IsLinuxClient bridge is stealth — no branded RaijinLab_Runtime global.
L6. Bridge:Register runs from Lua/main-thread; runtime periodically
    calls a MAIN-THREAD idempotent re-registration every 3 s if the
    Lua state pointer changes (1.7.3-reg-self-heal). This must NOT
    run from the worker.

============================================================
AUDIT CATEGORIES (be exhaustive per category)
============================================================
A. Worker-thread safety:
   - Every read/write of a game structure (units, spellbook, cursor,
     GetCursorInfo, ObjMgr, spell cooldowns) from a non-main thread.
   - Every registered callback pointer — where is it stored, when is
     it invalidated, could the caller invoke a stale pointer?
   - Every hook (IAT hook, inline detour, VMT swap) — is the target
     memory guarded during teardown?

B. Callback lifetime:
   - IsLinuxClient handler table — how is entry cleared on Lua reload?
   - Deferred main-thread queue entries — are captured pointers still
     valid at execution time?
   - PetAction / Spell_C_CastSpell target-GUID lookups — is the pointer
     re-resolved each call or cached across ticks?

C. Null-guard hazards:
   - Every pointer deref that could be null: player pointer, target
     pointer, ObjMgr root, lua_State, TLS entries.
   - Every VirtualProtect / write-to-code operation — verify page bounds
     before write.

D. Unbounded loops:
   - Worker loops that iterate ObjMgr — bounded iteration count?
   - Any while(true) that could spin without yielding SwitchToThread?

E. Race hazards:
   - Shared config flags read by both worker and main thread — atomic?
   - Log file writes from multiple threads — mutex?
   - MainThread queue push/pop — lock-free?
     Correctly implemented?

F. Stealth interference:
   - PebUnlink — does it re-hide correctly if run twice?
     Is header wipe safe against DLL unload?
   - Injection race: does the loader hold the DLL long enough for
     PebUnlink to finish before returning?

G. TaintPatch:
   - HW-DR gates: correct addresses? Byte patches idempotent?
   - Restore-on-unload path present?

H. Extensions.dll / AC interaction:
   - Are we registering any handler that AC dispatches? If yes, is our
     callback safe if called after DLL unload / Lua reload?

============================================================
DELIVERABLE
============================================================
Phase 1 (Audit) -> per-file finding list with file:line, category (A..H),
short claim, concrete fix approach. Aim for 20+ real findings.

Phase 2 (Fix) -> apply all Phase-1 fixes via Edit tool. Every change
must be intentional and defended in a code comment (why, not what).
Do not refactor unrelated code. Do not remove instrumentation.

Phase 3 (Build) -> rebuild the DLL, confirm it lands at
runtime/dist/RaijinLabRuntime.dll with a new timestamp and reasonable
size (should be 90-130 KB — the current build is 103,424 bytes).
Report the new hash and any build warnings.

Build command:
  tools\\build_runtime.bat
(This runs cmake configure + build in runtime/build_x86, then copies the
DLL to runtime/dist/.) If the batch script is not present in tools/,
manually invoke:
  cmake --build runtime/build_x86 --config Release
  copy runtime\\build_x86\\RaijinLabRuntime.dll runtime\\dist\\
`

const AUDIT_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['findings','summary'],
  properties: {
    findings: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      required: ['file','line','category','claim','fix'],
      properties: {
        file: { type: 'string' },
        line: { type: 'integer' },
        category: { type: 'string', description: 'A..H per CTX' },
        claim: { type: 'string', description: 'one-sentence defect' },
        failure_scenario: { type: 'string' },
        fix: { type: 'string', description: 'concrete change to make' },
      } } },
    summary: { type: 'string' },
  },
}

const FIX_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['files_changed','summary'],
  properties: {
    files_changed: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      required: ['file','edits_applied','description'],
      properties: {
        file: { type: 'string' },
        edits_applied: { type: 'integer' },
        description: { type: 'string' },
      } } },
    findings_addressed: { type: 'integer' },
    summary: { type: 'string' },
  },
}

const BUILD_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['success','dll_path','summary'],
  properties: {
    success: { type: 'boolean' },
    dll_path: { type: 'string' },
    dll_size_bytes: { type: 'integer' },
    warnings: { type: 'array', items: { type: 'string' } },
    errors: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
  },
}

phase('Audit')

const audit = await agent(
  `You are auditing the RaijinLab runtime DLL (injected into Ascension.exe, WoW 3.3.5 x86) for defects causing random ACCESS_VIOLATION crashes. Read every source file listed in CTX (skip the archive/ directory). For each defect, produce a finding with file, line, category letter (A-H per CTX), one-sentence claim, concrete failure scenario, and a concrete fix. Be thorough — aim for 20+ real findings. Focus on: worker-thread accesses to game state that should be main-thread, callback pointers that could be dereferenced after invalidation, missing null guards on player/target/ObjMgr/lua_State/TLS lookups, unbounded loops, TaintPatch idempotency, PebUnlink safety, and any handler we register that Extensions.dll could dispatch to unsafely. Do NOT touch code yet — only report findings. Return AUDIT_SCHEMA.\n\n` + CTX,
  { label: 'audit:runtime', phase: 'Audit', schema: AUDIT_SCHEMA, effort: 'high' })

log('Audit complete: ' + (audit?.findings?.length ?? 0) + ' findings across the runtime.')

phase('Fix')

const auditBlob = JSON.stringify(audit || {}, null, 1)

const fixed = await agent(
  `Apply the fixes from the audit below. Every finding must be addressed via a real Edit to the named file. Guidance:\n` +
  `  - Prefer minimum-diff correctness. Do NOT refactor unrelated code.\n` +
  `  - Every non-trivial change gets a short comment explaining WHY (not what) — the reason the change is needed.\n` +
  `  - Preserve L1..L6 invariants from CTX. If a finding contradicts one of those invariants, drop the finding and note it in summary.\n` +
  `  - If a finding requires a header change (e.g. adding a std::atomic member), do that too — but keep the change surgical.\n` +
  `  - Do NOT add branded strings or globals — stealth-loader invariant.\n` +
  `  - Any newly introduced synchronization must be documented as "why" in-line.\n` +
  `  - Do NOT touch archive/ files (they don't compile).\n\n` +
  `After each edit, quickly verify the surrounding function still parses. Return FIX_SCHEMA describing per-file edits applied.\n\n` +
  `--- AUDIT FINDINGS ---\n${auditBlob}\n\n` + CTX,
  { label: 'fix:runtime', phase: 'Fix', schema: FIX_SCHEMA, effort: 'high' })

log('Fix pass complete: ' + (fixed?.findings_addressed ?? 0) + ' findings addressed, ' + (fixed?.files_changed?.length ?? 0) + ' files touched.')

phase('Build')

const build = await agent(
  `Rebuild the runtime DLL. Steps:\n` +
  `  1. Run: tools\\\\build_runtime.bat (from repo root C:\\\\Ascension\\\\Workspace\\\\RaijinLab).\n` +
  `  2. If that batch is missing, fall back to: cmake --build runtime/build_x86 --config Release  (then copy build_x86/RaijinLabRuntime.dll to runtime/dist/).\n` +
  `  3. Verify runtime/dist/RaijinLabRuntime.dll exists with a fresh timestamp (post-Fix-phase) and size in 90-130 KB range.\n` +
  `  4. Report every compile warning and every compile error verbatim. If any errors, iterate: identify the offending file/line, fix, re-run build. Repeat up to 3 times.\n` +
  `  5. Do NOT modify source unless it's to fix a compile error.\n` +
  `Return BUILD_SCHEMA. On success, include the final DLL path + size + any non-fatal warnings.\n\n` + CTX,
  { label: 'build:runtime', phase: 'Build', schema: BUILD_SCHEMA, effort: 'high' })

log('Build phase: ' + (build?.success ? 'SUCCESS' : 'FAILED') + '  dll=' + (build?.dll_path ?? 'n/a') + '  size=' + (build?.dll_size_bytes ?? '?') + 'B')

return {
  findings: audit?.findings?.length ?? 0,
  fixes_applied: fixed?.findings_addressed ?? 0,
  files_changed: fixed?.files_changed?.length ?? 0,
  build_success: !!build?.success,
  dll_path: build?.dll_path,
  dll_size: build?.dll_size_bytes,
  warnings: build?.warnings?.length ?? 0,
}
