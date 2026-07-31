export const meta = {
  name: 'raijin-suite-audit-continue',
  description: 'Comprehensive audit + continuation for Grok\'s 1.6.1 suite: rotation stack, core, modules, runtime, integration, docs. Then fix + refresh + hand off. Comprehensive-to-extremes bar.',
  phases: [
    { title: 'Audit',      detail: '8 parallel deep reviews (rotation / core / modules / runtime / integration / docs / cleanup / P0-P1 gap plan)' },
    { title: 'Verify',     detail: 'adversarial per critical finding' },
    { title: 'Fix',        detail: 'apply high-priority code fixes + archive stale + refresh docs' },
    { title: 'Synthesize', detail: 'STATUS + ARCHITECTURE + README refresh + HANDOFF_grok + commands cheat-sheet' },
    { title: 'Critic',     detail: 'gap audit → optional patch round' },
  ],
}

const CTX = `
============================================================
GROK'S 1.6.1 SUITE — WHAT SHIPPED
============================================================
Root: C:\\Ascension\\Workspace\\RaijinLab\\
STATUS.md and RUNBOOK.md are the operator's front door. Version 1.6.1-crashfix stealth built.

ADDON LOAD ORDER (addon/RaijinLab.toc, TOC 30300):
  libs/bitops -> core/Variables -> Compat -> Runtime -> Actions -> StatusUI ->
  API -> Hooks -> objects/{Functions,Manager,Tracker} -> World -> SpellUtil -> UI ->
  Nav -> rotation/{Protection,Conditions,Engine,Executor,Editor} -> Menu ->
  Drawing -> Events -> Farming -> modules/{arena,travel,loot,farming,questing/Quests,questing/Suite,combat/Brain,gathering/Gatherer,grinding/Grinder} ->
  ChatHandler -> init

ROTATION STACK (Grok's biggest work, all unit-tested via lupa harness, all tests currently pass):
  addon/core/rotation/Engine.lua     (10 KB) — priority list model + Engine.evaluate(rotation, ctx, Conditions)
  addon/core/rotation/Executor.lua   (15 KB) — live tick + Actions.CastSpell + evidence-based cast validation (before/after GetSpellCooldown/UnitCastingInfo snapshots)
  addon/core/rotation/Conditions.lua (35 KB) — 20+ registered conditions: health/power/target buffs/debuffs/aura stacks+remaining/spell_usable/spell_in_range/cooldown/gcd/facing/is_moving/enemies_in_range/pvp_enemy_nearby/combo_points/form_equals/target_protected/target_can_take_damage
  addon/core/rotation/Protection.lua (20 KB) — Divine Shield/Cloak/HoP/Fire Ward/Spell Reflect/CLEU miss tracking, school-aware
  addon/core/rotation/Editor.lua     (41 KB) — drag-drop UI, spellbook cursor accept, per-slot condition editor, spell drop from bars
  addon/core/Actions.lua             (7 KB)  — SINGLE facade routing every taint-sensitive call through the runtime bridge (CastSpell/Target/Attack/Interact/MoveTo/Face/Jump/StopMoving/MoveForward/Strafe/RunMacroText/ExecSecure)

CORE ADDITIONS since prior session:
  addon/core/World.lua      (26 KB) — build_context() for Executor: cooldowns/known_spells/spell_in_range/spell_usable/target_buffs/enemies_in_range/GCD estimate + CLEU aggregation
  addon/core/Nav.lua        (7 KB)  — pure pathfinding + segment_cost + shortest_path + classify_slope + obstacles_from_entities
  addon/core/UI.lua         (7 KB)  — shared color palette + paint/backdrop primitives for the whole suite chrome
  addon/core/Menu.lua       (17 KB) — tabbed control panel: Home / Rotation / Nav / Gather / Combat / Quest / Grind
  addon/core/SpellUtil.lua  (2 KB)  — Hspell link parsing + spellbook cursor resolve + aura mark by name
  addon/core/objects/stale.lua (16 KB) — DEAD (all-commented-out old snippets; obvious archive candidate)

MODULES:
  addon/modules/combat/Brain.lua       (5 KB)
  addon/modules/gathering/Gatherer.lua (6 KB)
  addon/modules/grinding/Grinder.lua   (5 KB)
  addon/modules/questing/Suite.lua     (6 KB)  (new — separate from older Quests.lua)
  Existing: arena/Awareness, travel/Travel, loot/Looter, farming/{Farms,Farmer}, questing/Quests, torghast/TorghastObjects

RUNTIME (v1.6.1, dist/RaijinLabRuntime.dll = 101 KB):
  runtime/src/main.cpp                        (~150 lines) — no worker-thread Lua Execute (crashfix in R03)
  runtime/src/bridge/Dispatch.cpp             — Register + full IsLinuxClient dispatch incl. new native handlers
  runtime/src/game/Actions.cpp / .h            (NEW) — native cast/target/attack/interact/move helpers (Spell_C_CastSpell etc.)
  runtime/src/game/ObjectManager.cpp / .h     — EnumVisibleObjects + descriptor reads, SEH-guarded
  runtime/src/game/Offsets.h                  — verified binary-accurate address set (all confirmed by Claude prior session)
  runtime/src/game/TaintPatch.cpp / .h        — taint bypass (ArmUnlock path)
  runtime/src/game/MainThread.cpp             — thread-safe snapshot
  runtime/src/core/PebUnlink.cpp / .h          (NEW) — stealth: unlinks the DLL from PEB Ldr lists after load
  runtime/src/loader/loader.cpp                — random-stage copy to %TEMP%\\benign_<rand>.dll then LoadLibrary; --quiet
  runtime/src/core/Config, core/Log, core/Patterns — infra
  All offsets binary-verified against re/dumps/Ascension.exe (see [[raijinlab_ac_architecture]] memory).

BINDINGS AND SLASH:
  addon/core/ChatHandler.lua — /raijin, /raijinlab, /rlab, /rl (/rl shadowed by client; /raijin is canonical). Commands:
    status, om, menu (?), mj, aa, fly, nc, tracker, track, farm, travel, gps, help
  Runtime globals visible to addon Lua: IsLinuxClient (stock name), sometimes RaijinLab_Runtime.
  Output goes through print() (SendSystemMessage was chat-gated and silently dropped for low-level chars — fixed).

TESTS:
  tests/run_suite_tests.py — Python + lupa; loads shipped SpellUtil, Protection, Conditions, Engine, Nav; runs 100+ assertions. ALL PASS as of 2026-07-21.

KNOWN OPEN (from STATUS.md):
  P0: Live-prove cast path after 1.6.1 reinject (/raijin rotation status)
  P1: Manual-map (currently LoadLibrary + PEB unlink)
  P1: OM unit enum returns npcs=0 / high ptrMiss (combat still uses tokens; enum not usable yet)
  P2: Wire-level AC packet filter at fpSendPacket2 (Ascension.exe!0x0B0970)
  P2: Behavior humanization (camera jitter, face jitter, AFK nudge)

DOCS FRESHNESS:
  README.md still self-labels "1.4" (updated by Claude prior session — needs 1.6)
  ARCHITECTURE.md still describes pre-suite architecture (no rotation/menu/nav/world)
  notes/STATUS.md is fresh (2026-07-21 suite)
  notes/RUNBOOK.md fresh
  notes/INDEX.md — needs a runtime R03/R04 entry (R04 referenced by STATUS but may not exist yet)
  notes/runtime/R04_stealth_surface.md — check existence
  notes/HANDOFF_claude.md — from AC-RE work; add a HANDOFF_grok.md summarizing this session

TOOLING:
  tools/inject.bat / tools/build_runtime.bat / tools/deploy_addon.ps1
  tools/scripts/*.py (one-shot generators)
  runtime/tools/check_va.py (NEW, Grok — inspect)

REMEMBER (memory-verified):
  - Runtime worker thread must NEVER touch Lua (R03 crash).
  - /rl is shadowed by a client built-in reload; /raijin is primary.
  - SendSystemMessage silently dropped on low-level chars; use print().
  - DivxTac DetourMgr is INERT; module-name scan is the real AC.
  - Warden lives in Ascension.exe 0x7DA20F+ but is server-driven; dormant on most realms.
`

const AUDIT_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['area','findings','recommend'],
  properties: {
    area: { type: 'string' },
    findings: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      required: ['file','what','severity','evidence'],
      properties: {
        file: { type: 'string' },
        line: { type: 'integer' },
        what: { type: 'string', description: 'the issue or observation, concrete' },
        severity: { type: 'string', enum: ['critical','high','medium','low','info'] },
        evidence: { type: 'string' },
        fix: { type: 'string', description: 'concrete minimal fix (code diff-ish)' },
      } } },
    recommend: { type: 'array', items: { type: 'string' }, description: 'ranked next-actions specific to this area' },
    strengths: { type: 'array', items: { type: 'string' }, description: 'what Grok did well here (do not lose)' },
  },
}

const VERIFY_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['finding','verdict','reasoning'],
  properties: {
    finding: { type: 'string' },
    verdict: { type: 'string', enum: ['CONFIRMED','REFUTED','UNCERTAIN','SUPERSEDED'] },
    reasoning: { type: 'string' },
    corrections: { type: 'array', items: { type: 'string' } },
  },
}

const FIX_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['task','output_file','applied'],
  properties: {
    task: { type: 'string' },
    output_file: { type: 'string', description: 'file the fix wrote/edited/created' },
    applied: { type: 'boolean' },
    summary: { type: 'string' },
    followup: { type: 'array', items: { type: 'string' } },
  },
}

const SYNTH_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['doc','output_file'],
  properties: {
    doc: { type: 'string' },
    output_file: { type: 'string' },
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
      } } },
  },
}

// ---------- PHASE A: AUDIT (parallel) ----------

phase('Audit')

const AUDIT_AREAS = [
  {
    key: 'rotation-stack',
    prompt: `Deep audit of the rotation stack. Read every file cover to cover: addon/core/rotation/{Engine,Executor,Editor,Conditions,Protection}.lua and addon/core/Actions.lua and addon/core/SpellUtil.lua.
Focus on:
  (a) Correctness: does Executor.tick handle every ctx branch Engine.evaluate emits? Does Executor's evidence-based validation match how 3.3.5 GetSpellCooldown/UnitCastingInfo actually behave? Are there GCD/casting/queued races? Does the Editor drag-drop maintain slot ids properly across serialize/deserialize?
  (b) Missing conditions or missing wiring: any Conditions.evaluate_one path the World does not populate (checks) — cite specific unpopulated ctx keys.
  (c) Actions.lua taint discipline: is every taint-sensitive call routed via the runtime (no bare CastSpell/UseAction/TargetUnit/RunMacroText/StartAttack/AttackTarget/InteractUnit/etc. anywhere in the addon)? Grep the whole addon for bare calls and cite offenders.
  (d) Editor UX gaps + robustness: does closing the menu mid-drag corrupt state? Do we save on close?
  (e) Any place still calling FrameScript-protected APIs from addon-side (would blow taint / trigger #132) — flag every one.
Return AUDIT_SCHEMA. Cite file:line for each finding. Rank fixes by severity.`,
  },
  {
    key: 'core-layer',
    prompt: `Deep audit of the core addon layer (non-rotation): addon/core/{World,Nav,UI,Menu,Runtime,Actions,Compat,Hooks,Events,Variables,SpellUtil,StatusUI,Drawing,Farming,ChatHandler}.lua + addon/core/objects/{Functions,Manager,Tracker,stale}.lua + addon/libs/bitops.lua.
Focus on:
  (a) World.build_context — does it populate every ctx key Conditions/Engine expects? List keys emitted vs keys consumed.
  (b) Menu tab handlers — do all 7 tabs have live content, or are placeholders shown?
  (c) UI skin usage — is every module using RaijinLab.UI.paint or is there ad-hoc reinvention?
  (d) Runtime.lua bridge detection — HasRuntime()/RuntimeCall()/RuntimeVersion — sound? Any stale legacy path?
  (e) Compat.lua — the C_Timer polyfill drain-loop fix from prior session still present? Any new NewTicker with sub-frame interval elsewhere?
  (f) Events.lua Init() unconditional path — is it now safe (drawing gated behind HasRuntime, etc.)?
  (g) objects/stale.lua — confirm it is dead / all-commented and can be archived.
  (h) Any load-order fragility (global reads before defined, upvalue capture of nil, etc.)
Return AUDIT_SCHEMA with concrete file:line for each finding.`,
  },
  {
    key: 'modules',
    prompt: `Deep audit of the module layer: addon/modules/{arena/Awareness,travel/Travel,loot/Looter,farming/Farms,farming/Farmer,questing/Quests,questing/Suite,combat/Brain,gathering/Gatherer,grinding/Grinder,torghast/TorghastObjects}.lua.
Focus on:
  (a) For every module: is it wired into a Menu tab? Is it callable via /raijin? Or dead-loaded and doing nothing?
  (b) Does each module route actions through RaijinLab.Actions (correct) or reach for bare CastSpell/etc. (wrong — taint)?
  (c) Does each module gate on HasRuntime() before privileged ops?
  (d) TorghastObjects — Torghast is SL retail-only; is this module dead code on 3.3.5? (STATUS said it was removed but the file is 1 KB and still in modules/ — check TOC inclusion).
  (e) Suite.lua vs older Quests.lua — is one obsolete?
  (f) Any references to functions/globals that don't exist (dangling calls).
Return AUDIT_SCHEMA.`,
  },
  {
    key: 'runtime-native',
    prompt: `Deep audit of the C++ runtime added since prior session: runtime/src/{main,bridge/Dispatch,game/Actions,game/ObjectManager,game/TaintPatch,game/MainThread,game/Offsets,game/AddressDB,lua/Lua,loader/loader}.cpp/.h + runtime/src/core/{PebUnlink,Log,Config,Patterns}.cpp/.h.
Focus on:
  (a) Actions.cpp: what native calls does it use (Spell_C_CastSpell VA? Attack? Interact? TargetGuid? ClickToMove?)? Are the offsets binary-plausible for 3.3.5 (Spell_C_CastSpell is around 0x80DA40 on stock; check Actions.lua top-comment for the claim)? Are they in Offsets.h?
  (b) PebUnlink.cpp: is the unlink correctly walking InLoadOrderModuleList/InMemoryOrderModuleList/InInitializationOrderModuleList and rebasing prev/next? Any missing list or off-by-one that would corrupt the loader?
  (c) Dispatch.cpp: any new handler that runs on the worker thread and touches Lua? (Would recrash — R03 lesson.)
  (d) main.cpp: still no worker-thread FrameScript_Execute; Register runs after ~300ms settle?
  (e) TaintPatch.cpp: what does ArmUnlock actually patch? Reversible? Guarded by config flag?
  (f) loader.cpp: random-stage copy to %TEMP% then LoadLibrary — any file-handle leak, temp-file cleanup, or PID targeting bug?
  (g) Offsets.h + AddressDB — any new offset entries that need binary-verification against re/dumps/Ascension.exe (I already verified the base set; only NEW ones need checking)?
  (h) OM enum breakage that STATUS says returns npcs=0: is EnumVisibleObjects being called with the right callback signature (cdecl (uint64 guid, void* userdata) -> int), or does it need the (guid, uint filter) or (guid, void*) 3.3.5 variant?
Return AUDIT_SCHEMA. This audit informs the OM enum fix in the Fix phase.`,
  },
  {
    key: 'integration',
    prompt: `End-to-end integration audit — does the whole suite actually connect?
  (a) TOC load order (RaijinLab.toc): every file loads before its dependent? Editor loads after UI/Conditions/Engine/Protection (yes), Menu after UI (yes), World after Nav+Actions (?) — check.
  (b) Global exports: which files set RaijinLab.<X> = ...? Grep for all "RaijinLab\\.[A-Z]\\w+\\s*=" and confirm each consumer finds it. Missing exports = silent nil deref.
  (c) SavedVariables shape: RaijinLabDB.rotations / active_rotation / rotation_enabled / modules — any place writes a different shape than Executor.get_active_rotation reads?
  (d) ChatHandler commands vs implementations: for each cmd in ChatHandler.lua that isn't 'status/help/om/mj/aa/fly/nc/tracker/track/farm/travel/gps', confirm the target function exists. Does 'menu' exist? Does 'rotation' subcommand exist?
  (e) The Menu tabs (Home/Rotation/Nav/Gather/Combat/Quest/Grind) map to which module code? Any tab whose module isn't implemented?
  (f) Actions -> runtime handler names: for every rt("<Name>", ...) in Actions.lua, is <Name> handled in runtime bridge/Dispatch.cpp? If Dispatch is missing "ArmUnlock" / "CastSpell" / "TargetGuid" / "Interact" / "InteractTarget" / "Attack" / "StopAttack" / "MoveTo" / "FaceDirection" / "Jump" / "StopMoving" / "MoveForwardStart" / "MoveForwardStop" / "StrafeLeftStart" / "StrafeLeftStop" / "StrafeRightStart" / "StrafeRightStop" / "ExecSecure" / "SpellStopCasting" — each missing name is a silent no-op.
Return AUDIT_SCHEMA. The gap list here becomes the top fix priority.`,
  },
  {
    key: 'docs-freshness',
    prompt: `Audit doc freshness against the actual 1.6.1 state (front-door docs the user reads):
  README.md, ARCHITECTURE.md, addon/README.md (if exists), runtime/src/README.md, notes/STATUS.md, notes/RUNBOOK.md, notes/INDEX.md, notes/HANDOFF_claude.md.
For each: (a) claimed version vs actual (1.6.1); (b) missing sections (rotation stack? menu? conditions catalog? Actions facade? PebUnlink? loader stealth mode?); (c) any dead pointer (referenced note that doesn't exist, e.g. notes/runtime/R04_stealth_surface.md — check).
Return AUDIT_SCHEMA. The fixes are documentation rewrites, listed as concrete "rewrite <file>: add section X, remove stale Y".`,
  },
  {
    key: 'cleanup',
    prompt: `Cleanup manifest — find every stale/dead/misplaced artifact in the repo.
Check: addon/core/objects/stale.lua (16 KB, likely all-comment dead code — confirm with head+tail), addon/modules/torghast/ (Torghast is SL retail — is it dead on 3.3.5?), addon/modules/questing/{Quests,Suite} overlap, addon/modules/farming/{Farms,Farmer} vs core/Farming.lua overlap, any *.bak / *.orig / /tmp / .DS_Store, notes/*.md numbering collisions or stale files, tools/scripts leftover generators, runtime/tools/check_va.py (new — is it useful?), runtime/dist/archive/ retention (should we prune?), tests/ directory beyond run_suite_tests.py?
Return AUDIT_SCHEMA. Actions = archive / delete / rename. Prefer archive over delete for Grok's work.`,
  },
  {
    key: 'p0-p1-continuation',
    prompt: `Continuation plan for the open P0/P1 items in STATUS.md, with concrete implementation sketches.
  P0: Live-prove the cast path after 1.6.1 reinject. What EXACT sequence should the user run? What log lines and /raijin outputs are the pass/fail signals? What automated Executor.tick self-diagnostic can be added?
  P1a: OM unit enum returns npcs=0. Diagnose from the code: is the callback signature wrong (see runtime-native audit), or is a descriptor read failing? Propose a static fix if determinable.
  P1b: Manual-map inject. Current is LoadLibrary + PEB unlink. Sketch the incremental delta: manual-map loader design (PE header parse, section copy, relocations, imports resolution, TLS callbacks, PEB never touched) — enough for Grok to implement.
  P2 (light): Behavior humanization design: Executor already has 0.35s throttle and 0.18–0.42s random gap noise per STATUS — check code; suggest additions (camera jitter interval, mouse micro-move, occasional AFK-cancel, reaction time on target change).
Return AUDIT_SCHEMA (findings=the current-state read, recommend=the concrete plan).`,
  },
]

const auditResults = await parallel(AUDIT_AREAS.map(a => () => agent(
  a.prompt + "\n\n" + CTX,
  { label: 'audit:' + a.key, phase: 'Audit', schema: AUDIT_SCHEMA, effort: 'high' })))

const audits = auditResults.filter(Boolean)
const allFindings = audits.flatMap(a => (a.findings || []).map(f => ({ ...f, area: a.area })))
log(`Audit complete: ${audits.length}/${AUDIT_AREAS.length} areas, ${allFindings.length} findings total.`)

// ---------- PHASE B: VERIFY (adversarial per critical/high finding) ----------

phase('Verify')

const toVerify = allFindings
  .filter(f => f.severity === 'critical' || f.severity === 'high')
  .slice(0, 12) // cap to keep the round bounded

const verdicts = await parallel(toVerify.map((f, i) => () => agent(
  `Adversarially verify this finding from the suite audit. Independently re-read the cited file(s) and check the claim.\n\n` +
  `AREA: ${f.area}\nFILE: ${f.file}${f.line ? ':' + f.line : ''}\nSEVERITY: ${f.severity}\nWHAT: ${f.what}\nEVIDENCE: ${f.evidence}\nPROPOSED FIX: ${f.fix || '(none)'}\n\n` +
  `Default UNCERTAIN if you can't reproduce. REFUTED if you find contrary evidence. CONFIRMED only if the cited file:line matches. SUPERSEDED if the code already handles it a different way that works.\n\n` + CTX,
  { label: 'verify:' + i, phase: 'Verify', schema: VERIFY_SCHEMA, effort: 'high' })))

const confirmed = verdicts.filter(Boolean).filter(v => v.verdict === 'CONFIRMED')
log(`Verify: ${confirmed.length}/${toVerify.length} confirmed critical/high findings.`)

// ---------- PHASE C: FIX (parallel — code + cleanup + docs) ----------

phase('Fix')

const findingsSummary = audits.map(a =>
  `## ${a.area}\nSTRENGTHS: ${JSON.stringify(a.strengths || [])}\nFINDINGS: ${JSON.stringify(a.findings)}\nRECOMMEND: ${JSON.stringify(a.recommend)}\n`
).join('\n')
const verifiedSummary = confirmed.map(v => `- ${v.finding}: ${v.reasoning}`).join('\n')

const FIXES = [
  {
    key: 'fix-integration-gaps',
    prompt: `Apply concrete code fixes for the integration audit findings — priority: missing runtime handlers referenced by addon/core/Actions.lua rt("...") calls, missing global exports, ChatHandler command wiring gaps. For each fix:\n  - Read the actual current file first (do not assume).\n  - Make the minimum diff.\n  - Preserve Grok's style.\n  - Do NOT touch runtime C++ unless the fix is a trivial addition to bridge/Dispatch.cpp of a stub handler (log + return nil) to make the addon side survive; genuine native implementations are Grok's lane.\nReturn FIX_SCHEMA with output_file = the primary file edited.`,
  },
  {
    key: 'fix-load-order-and-nils',
    prompt: `Fix any load-order or nil-guard issue found in the core/rotation/modules audits (e.g. Editor references RaijinLab.UI before its export path is established; module code assumes RaijinLab.Actions exists without guarding; SavedVariables shape mismatches). Minimum diffs. Return FIX_SCHEMA.`,
  },
  {
    key: 'archive-stale',
    prompt: `Archive dead/stale files identified in the cleanup audit. Move (do not delete) addon/core/objects/stale.lua to addon/core/objects/archive/stale.lua. Do the same for any other confirmed-dead file. Do NOT modify TOC unless the file was in the TOC and is being retired (Grok's TOC does not list stale.lua so no change needed). Return FIX_SCHEMA listing every move.`,
  },
  {
    key: 'humanization-hardening',
    prompt: `Harden addon/core/rotation/Executor.lua behavior humanization per the P0-P1 continuation plan (only if the plan agent flagged specific gaps). Add: (a) an additional 60–180 ms micro-jitter within each cast attempt, (b) an occasional 700–1300 ms "reaction pause" after target changes, (c) a rolling window that skips a cast every ~40 attempts to break robotic cadence. Keep behavior gated behind a config flag RaijinLab.human = true (default on). Minimum diff. Preserve all existing evidence-based validation. Return FIX_SCHEMA.`,
  },
  {
    key: 'refresh-readmes',
    prompt: `Rewrite the front-door docs to reflect 1.6.1 suite reality: README.md at repo root and runtime/src/README.md. New README.md must have: version badge line, quick-start (build/deploy/inject/reload/menu), full suite feature list (rotation creator with conditions+protection, Menu tabs, Actions facade, Nav, World, unit tests, stealth loader), the /raijin command cheat-sheet, the operator path, AC honesty section, and pointers to STATUS/RUNBOOK/HANDOFFs. runtime/src/README.md should describe the live layout (main/core/game/lua/bridge/loader/tools), the Actions.cpp handlers, PebUnlink, ArmUnlock/TaintPatch flag gates, and the archive/ dead layer. Return FIX_SCHEMA with output_file per doc (return two: one per invocation is fine, or one call editing both — either way).`,
  },
  {
    key: 'refresh-architecture',
    prompt: `Rewrite ARCHITECTURE.md to describe the actual 1.6.1 suite (not the pre-suite 1.0 version currently in the file). Sections: Mission (unchanged), Layer diagram (addon Menu -> rotation stack Engine+Executor+Conditions+Protection+Editor + core World/Nav/UI + Actions facade -> runtime Dispatch -> Ascension.exe funcs), Rotation architecture (data model, condition system, evidence-based casting), Runtime version (1.6.1), Actions facade design (why every taint-sensitive call goes through), Stealth posture (PEB unlink + random-stage loader + quiet logs + AC reality table with the 4 verified AC layers), Test harness. Add a table of external commands. Preserve Grok's tone. Return FIX_SCHEMA.`,
  },
]

const fixResults = await parallel(FIXES.map(f => () => agent(
  f.prompt + `\n\n============================================================\nAUDIT FINDINGS (all areas):\n${findingsSummary}\n\nADVERSARIAL-CONFIRMED HIGH/CRITICAL:\n${verifiedSummary}\n\n` + CTX,
  { label: 'fix:' + f.key, phase: 'Fix', schema: FIX_SCHEMA, effort: 'high' })))

const goodFixes = fixResults.filter(Boolean)
log(`Fix: ${goodFixes.length}/${FIXES.length} tasks applied.`)

// ---------- PHASE D: SYNTHESIZE (three docs) ----------

phase('Synthesize')

const fixesSummary = goodFixes.map(f => `- ${f.task} -> ${f.output_file} (${f.applied ? 'applied' : 'skipped'})\n  ${f.summary || ''}`).join('\n')

const SYNTHESES = [
  {
    key: 'status-refresh',
    out: 'C:\\Ascension\\Workspace\\RaijinLab\\notes\\STATUS.md',
    prompt: `Refresh notes/STATUS.md to reflect the post-audit / post-fix state as of 2026-07-21 (Claude session 2). Structure: Component status table (Addon/Runtime/Loader/Offsets/AC map), What works, Verified this session (from the audit), Corrections/fixes applied this session (from fix summary), Open next by priority, Config, AC honesty. Keep it dense and honest. Return SYNTH_SCHEMA.`,
  },
  {
    key: 'handoff-grok',
    out: 'C:\\Ascension\\Workspace\\RaijinLab\\notes\\HANDOFF_grok.md',
    prompt: `Write notes/HANDOFF_grok.md — Claude's handoff TO Grok for this session. Sections: What Claude did (audit areas covered, files edited, docs refreshed), Correctness verdicts on Grok's core components (rotation stack, Actions facade, runtime, tests), Confirmed strengths (do not lose), Gaps Grok should address (P0 live cast prove, P1 OM enum callback signature if diagnosed, P1 manual-map sketch, humanization additions, doc gaps), Concrete file:line pointers for each item, Quick command cheat-sheet. Be specific and useful. Return SYNTH_SCHEMA.`,
  },
  {
    key: 'commands-cheatsheet',
    out: 'C:\\Ascension\\Workspace\\RaijinLab\\notes\\COMMANDS.md',
    prompt: `Write notes/COMMANDS.md — a single-page cheat-sheet for the operator. Sections: In-game commands (/raijin + aliases with subcommands + one-line what-each-does + example), Runtime bridge probe (/run print(RaijinLab_Runtime('...')) recipes for GetRuntimeVersion / Ping / GetObjectCount / ObjectPosition), Build & deploy (tools\\build_runtime.bat, tools\\deploy_addon.ps1, tools\\inject.bat), Test suite (python tests/run_suite_tests.py), Log paths, Config file. Include a "Troubleshooting quick table": symptom -> likely cause -> fix, covering the four historical bugs (world-entry freeze, worker-thread crash, /rl shadowed, SendSystemMessage gated). Return SYNTH_SCHEMA.`,
  },
]

const synthResults = await parallel(SYNTHESES.map(s => () => agent(
  s.prompt + `\n\nAUDIT FINDINGS:\n${findingsSummary}\n\nFIX SUMMARY:\n${fixesSummary}\n\nOUTPUT_FILE: ${s.out}\n\n` + CTX,
  { label: 'synth:' + s.key, phase: 'Synthesize', schema: SYNTH_SCHEMA, effort: 'high' })))

log(`Synthesize: ${synthResults.filter(Boolean).length}/${SYNTHESES.length} docs written.`)

// ---------- PHASE E: CRITIC ----------

phase('Critic')

const critic = await agent(
  `You are the completeness critic. This session audited Grok's 1.6.1 suite, applied fixes, and refreshed docs. Identify remaining gaps that a future session must address. Sample gap categories:\n` +
  `- an audit area under-covered (e.g. Editor drag-drop tested only statically, no lupa test for it)\n` +
  `- a fix that changed behavior but has no test guard\n` +
  `- a runtime handler that was stubbed but not implemented (would silently no-op)\n` +
  `- a doc claim that isn't backed by verified evidence\n` +
  `- a P0/P1 item from STATUS still open after this session\n` +
  `- integration cases (login->reload->menu open->add spell->save->reload->still there?)\n` +
  `Return CRITIC_SCHEMA. Up to 10 gaps ranked by severity. Each gap: concrete remediation (what a next session should DO, not what's wrong).\n\n` +
  `AUDIT:\n${findingsSummary}\n\nFIX SUMMARY:\n${fixesSummary}\n\n` + CTX,
  { label: 'critic:completeness', phase: 'Critic', schema: CRITIC_SCHEMA, effort: 'high' })

log(`Critic: ${critic?.gaps?.length ?? 0} gaps identified for future work.`)

return {
  audits: audits.length,
  findings: allFindings.length,
  verifiedHigh: confirmed.length,
  fixes: goodFixes.length,
  syntheses: synthResults.filter(Boolean).length,
  criticGaps: critic?.gaps?.length ?? 0,
  files: {
    fixes: goodFixes.map(f => f.output_file),
    docs: synthResults.filter(Boolean).map(s => s.output_file),
  },
}
