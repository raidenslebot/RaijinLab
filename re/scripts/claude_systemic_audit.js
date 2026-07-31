export const meta = {
  name: 'raijin-systemic-audit',
  description: 'Not a bug hunt — a structural read. 3 orthogonal lenses (cast-path stress, AC/capability ceiling, coupling & lifecycle) + 1 synthesizer that names THE weakest link and the minimum sequence to unblock the whole system.',
  phases: [
    { title: 'Lenses',     detail: '3 parallel systemic reviews (cast-pipeline stress, AC-capability tradeoff, coupling/lifecycle)' },
    { title: 'Synthesize', detail: 'name the weakest link + prioritized 1.7 roadmap' },
  ],
}

const CTX = `
============================================================
YOU ARE NOT LOOKING FOR BUGS
============================================================
Bugs and stale docs have been audited exhaustively (94 findings, 12 confirmed HIGH/CRITICAL, all
addressed in the last two Claude sessions). The remaining 4 critic gaps are known and either
require live client (P0 cast-prove, P0 OM enum probe) or Grok C++ work (main-thread Register hook,
Editor UI mock testing). Do NOT re-audit those.

You are looking for STRUCTURAL WEAKNESS: the single decision or missing capability that determines
the ceiling of the whole system. What will break under real load. What must be built first to
unblock everything else. Which coupling is load-bearing and one bad-day away from failing. Answer
the question "if I could only fix ONE thing to fundamentally improve this system, what is it, and why."

============================================================
COMPLETE SYSTEM MAP (READ THIS ONCE, DON'T RE-DERIVE)
============================================================
Root: C:\\Ascension\\Workspace\\RaijinLab\\
Version: addon 1.6.1-suite, runtime 1.6.1-crashfix.

## The two worlds and the bridge

  [ WoW client Lua VM (main thread) ]
    ← addon: 12k lines Lua in addon/ (TOC-loaded at world entry)
    ← Menu (tabbed control panel) ← rotation Editor → RaijinLabDB (SavedVariables)
    ← rotation Executor (100Hz-ish OnUpdate ticker)
    ← RaijinLab.Actions FACADE — the single entry point for all taint-sensitive verbs
    ↓
    IsLinuxClient("<name>", args...)   [stock global, bound by the runtime]
    ↓
  [ RaijinLabRuntime.dll (injected x86, main thread callback context) ]
    ← bridge/Dispatch.cpp — matches name → native handler
    ← game/Actions.cpp — Spell_C_CastSpell / Target / Interact / Move / ExecSecure / etc.
    ← game/ObjectManager.cpp — EnumVisibleObjects with SEH guards, CIRCUIT-BREAKER on AV
    ← game/TaintPatch.cpp — ApplyHardwareGatesOnly (arms cast-during-taint acceptance)
    ← core/PebUnlink.cpp — post-load PEB triple-unlink + PE header wipe

## The 4-layer AC (verified static, honest)

  1. Extensions.dll: 14 anti-debug vectors → sink FUN_100b5650 (behavioral only, no image hash)
  2. DivxTac.dll: name-based module/process/title scan every 60s (DetourMgr INERT, no bytes read)
  3. MMgr64.exe: MemoryBridge server (NOT AC — do NOT kill it)
  4. Legacy Blizzard Warden in Ascension.exe (0x7DA20F+, opcode 0x2E6 handler, in-process memcpy of any range)
     — DORMANT unless the SERVER issues challenges. Most realms don't. IF the realm does, static .text
     patches (including our TaintPatch) are observable. Runtime-hook that reverts before/during the
     0x2E6 dispatch is the real answer.

## What actually happens on a cast (the pipeline you must reason about)

  1. Executor OnUpdate tick (10-33 Hz)
  2. 0.35s min-gap throttle (wire-safety)
  3. Soft-GCD gate (World.gcd_remaining() > 0.10 → skip)
  4. World.build_context() — builds ~40 ctx keys: cooldowns, buffs, target aura, spell_in_range, spell_usable, is_moving, in_combat, health/power pcts, TTD, protection map
  5. Engine.evaluate(rotation, ctx, Conditions) — walks priority list, first slot whose conditions pass AND spell_ready → returns action
  6. attempt_action — Grok's evidence-based validator:
     - pre-flight IsUsableSpell + IsSpellInRange
     - cast_snapshot(sid) BEFORE
     - Act.CastSpell(sid, guid) via runtime
     - cast_snapshot(sid) AFTER — check casting/channel/current/CD delta as EVIDENCE the cast landed
     - retry snapshot once (GetSpellCooldown lags one call)
     - if no evidence → "no_effect:<name>#<id>"
  7. On success: gated Attack() only for physical school (via Protection.guess_school)

## The runtime handlers (Actions.cpp)

  ArmUnlock, CastSpell (3-tier: lua_pcall CastSpellByID → native Spell_C_CastSpell → FrameScript_Execute),
  TargetGuid, TargetByName, ClearTarget, Attack, StopAttack, Interact, InteractTarget,
  MoveTo, FaceDirection, Jump, StopMoving, MoveForwardStart/Stop, MoveBackwardStart/Stop,
  StrafeLeft/RightStart/Stop, TurnLeft/RightStart/Stop, SpellStopCasting, ExecSecure, RunMacroText

## Known invariants (violate these and things crash)

  - Runtime worker thread must NEVER touch Lua (R03 crashfix rule)
  - Register() currently runs on worker after 300ms settle; it works empirically but is the SAME
    class of race as R03 (single quick call). Real fix = main-thread hook.
  - /rl is shadowed by client built-in reload; /raijin is canonical
  - SendSystemMessage is chat-gated for < level 10 chars → use print()
  - Any FrameScript-protected API (CastSpell, TargetUnit, UseAction, InteractUnit, RunMacroText)
    from addon Lua is instant taint → must route through Actions facade → runtime

## Modules

  Rotation stack (5 files, 121KB): Engine/Executor/Conditions/Protection/Editor — the flagship
  Menu (7 tabs, one per module): Home / Rotation / Nav / Gather / Combat / Quest / Grind
  Combat/Brain, Gathering/Gatherer, Grinding/Grinder, Questing/Suite — module drivers
  Nav — pure-Lua pathfinding (no game deps except MoveTo via Actions)
  World — the single ctx-builder feeding conditions

## Dev/deploy loop

  edit source under addon/ or runtime/src/
  tools\\build_runtime.bat            (only if runtime changed)
  copy addon/... → Interface/AddOns/RaijinLab/... (deploy_addon.ps1 or manual)
  in-game: /reload
  if runtime changed: quit game, tools\\inject.bat (in-world, once)
  tests: python tests/run_suite_tests.py (Lua + source guards, ~130 assertions)

## Data model

  RaijinLabDB.rotations[name] = serialized Engine.new_rotation() table
    { name, enabled, slots = [ { id, action_type, spell_id, name, icon, conditions=[{id,args}], enabled } ] }
  RaijinLabDB.active_rotation = string
  RaijinLabDB.rotation_enabled = bool
  RaijinLabDB.modules = { rotation, nav, gather, combat, quest, grind : bool }
  Per-module: RaijinLabDB.{grind,gather,combat,quest} = state tables
  Rotations are PER-ACCOUNT (SavedVariables at account scope, not per-character)

## What is empirically PROVEN working right now (2026-07-21)

  - Injection + PEB unlink + PE header wipe → BRIDGE ONLINE, no crash across sessions
  - IsLinuxClient bridge callable from main thread (/run print(IsLinuxClient('GetRuntimeVersion')) → 1.6.1)
  - Addon loads, menu opens, /raijin cheat-sheet all respond
  - Rotation editor drag/drop/edit condition, save+reload roundtrips (5 unit tests confirm)
  - 100+ Lua tests + 15 source-guard regression tests all green

## What is NOT yet proven live

  - A rotation actually driving a cast on a target dummy end-to-end (P0)
  - OM enum returning non-zero unit count (currently npcs=0 with ptrMiss — likely callback ABI mismatch)
  - Warden challenges arriving on this realm (opcode 0x2E6 flow) — dormant so far

## Deferred / known-fragile

  - Register() worker-thread race (works, but is a latent R03)
  - Rotation SavedVariables format has no version field → future schema changes will silently corrupt old profiles
  - Executor 0.35s throttle is a magic constant; no per-class tuning
  - No condition depends on incoming damage (CLEU is armed but no "recently hit for > X% HP" condition)
  - No interruption / kick / dispel scheduling (would need target-cast context)
  - No multi-target awareness beyond enemies_in_range count (no soft-target queue)
  - Loader accumulates %TEMP%\\<benign>_<hex>.dll copies forever (no cleanup)
  - No telemetry on Executor internals except last_err (hard to diagnose live)

Read the code. Read the notes/STATUS + notes/HANDOFF_grok + notes/HANDOFF_claude + notes/12/13
for AC context. Then answer YOUR lens question below. Cite files with paths + line numbers.
Focus on structural — one great insight beats ten shallow observations.
`

const LENS_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['lens','weakest_link','why','ceiling','remediation'],
  properties: {
    lens: { type: 'string' },
    weakest_link: { type: 'string', description: 'the ONE structural weakness in this lens, named specifically' },
    why: { type: 'string', description: 'the causal chain — why this specific weakness caps the whole system, not just this feature' },
    ceiling: { type: 'string', description: 'concretely: what functionality is impossible / unreliable / dangerous while this remains' },
    remediation: {
      type: 'object', additionalProperties: false,
      required: ['action','effort','unlock'],
      properties: {
        action: { type: 'string', description: 'the concrete build to do' },
        effort: { type: 'string', enum: ['hours','day','days','week'] },
        unlock: { type: 'string', description: 'what this unlocks — must be broader than the weakness itself' },
      },
    },
    other_findings: { type: 'array', items: { type: 'string' }, description: 'secondary structural observations within this lens (max 4)' },
    non_findings: { type: 'array', items: { type: 'string' }, description: 'things that LOOK like problems but are actually load-bearing / intentional (avoid future re-audits)' },
  },
}

const SYNTH_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['the_weakest_link','why_this_beats_the_others','roadmap','output_file'],
  properties: {
    the_weakest_link: { type: 'string', description: 'ONE weakness across all lenses — the fundamental structural ceiling' },
    why_this_beats_the_others: { type: 'string', description: 'why this specific one is the priority over the others named per lens' },
    roadmap: {
      type: 'array', minItems: 3, maxItems: 7, items: {
        type: 'object', additionalProperties: false,
        required: ['step','why','effort','unlocks'],
        properties: {
          step: { type: 'string', description: 'concrete build step' },
          why: { type: 'string' },
          effort: { type: 'string', enum: ['hours','day','days','week','weeks'] },
          unlocks: { type: 'string', description: 'the follow-on functionality this step unlocks' },
        },
      },
    },
    output_file: { type: 'string' },
    do_not_do: { type: 'array', items: { type: 'string' }, description: 'things a future session might be tempted to do that would waste effort or actively harm' },
  },
}

phase('Lenses')

const LENSES = [
  {
    key: 'cast-pipeline-stress',
    prompt: `LENS 1: Stress-test the rotation cast pipeline (Executor → Actions → runtime → validate).
Adversarially imagine real load: 5 FPS during raid transition, GCDs stacking, IsUsableSpell lying about mana on a custom-resource class, a mob dying between attempt_action's IsSpellInRange check and Act.CastSpell, /reload mid-tick, runtime unload (END pressed) during a queued cast, the client's GetSpellCooldown returning stale data one call out of ten.
Read: addon/core/rotation/Executor.lua (full), addon/core/rotation/Engine.lua (evaluate + spell_ready), addon/core/Actions.lua, addon/core/World.lua (build_context + gcd_remaining + spell_cooldown_remaining), runtime/src/game/Actions.cpp if accessible via ghidra decompile or the surface described above.
Where in this chain is the SINGLE point that determines correctness under load? Is it the evidence-based validator (does it false-negative when the client is under load)? Is it the ArmUnlock one-shot state (what if it never got called / got called twice)? Is it the ctx staleness (World.build_context is called every tick — is there race between when we read GetSpellCooldown and when we call the cast)? Is it something about the 3-tier CastSpell escalation in the runtime?
Answer the LENS_SCHEMA. Weakest link = ONE specific thing.`,
  },
  {
    key: 'ac-capability-ceiling',
    prompt: `LENS 2: The AC-vs-capability tradeoff. Given the verified 4-layer AC map (Extensions 14-vector sink behavioral only, DivxTac 60s NAME-based scan, MMgr64 not-AC, Warden dormant/server-driven), what functionality are we currently NOT enabling that we safely COULD, and what specific functionality would push us over the line into detection?
Read: notes/12_ac_breakpoint_catalog.md, notes/13_ac_evasion_strategy.md, notes/HANDOFF_claude.md, notes/runtime/R04_stealth_surface.md, runtime/src/game/TaintPatch.cpp (what does ApplyHardwareGatesOnly actually change?), runtime/src/game/Actions.cpp (what verbs are wired but under-used?), addon/core/Actions.lua (what does the facade EXPOSE vs what does the runtime actually implement?).
Concretely: which of ObjectManager.enum / native TargetGuid / native ClickToMove / Interact / RunMacroText / ExecSecure are dispatched but not exposed to addon code (or exposed but unused by real modules)? What features (auto-loot, combat-target-cycling, real navmesh, spell interruption, tab-target replacement) are gated only on our own caution, not on AC risk?
Answer LENS_SCHEMA. Weakest link = the one MISSED capability whose absence caps every module downstream.`,
  },
  {
    key: 'coupling-lifecycle',
    prompt: `LENS 3: Coupling and lifecycle. This is a TWO-process system (client + injected runtime) with fragile boundaries. Trace what happens in each scenario and identify the load-bearing invariant most likely to break:
  (a) User /reloads UI while rotation is active — what state is lost? What state should persist but doesn't (rotation SavedVariables have no schema version)?
  (b) User presses END mid-cast — runtime unloads via FreeLibraryAndExitThread. Does addon Lua notice? Does Actions.available() flip correctly, or does the next cast attempt call into a freed handler?
  (c) User switches character — SavedVariables are per-account; per-character preferences (which class Menu tab, keybinds) have nowhere to live.
  (d) Client crashes/logs out with rotation enabled — RaijinLabDB.rotation_enabled = true persists → next login auto-starts a rotation with no target, spamming skip logs.
  (e) Rotation schema change (new condition arg, renamed slot field) — SavedVariables have no version field. What breaks silently?
  (f) Runtime version mismatch (addon expects 1.7 handler, injected 1.6.1) — how does the addon fail? Does Actions.available() gate on version too, or just presence?
Read: addon/core/Runtime.lua, addon/core/Actions.lua (available/ensure), addon/core/rotation/Executor.lua (start/stop), addon/core/Variables.lua (SavedVariables schema), runtime/src/main.cpp DllMain + FreeLibraryAndExitThread path.
Weakest link = the one lifecycle transition most likely to corrupt state, crash, or silently mislead. Answer LENS_SCHEMA.`,
  },
]

const lensResults = await parallel(LENSES.map(l => () => agent(
  l.prompt + "\n\n" + CTX,
  { label: 'lens:' + l.key, phase: 'Lenses', schema: LENS_SCHEMA, effort: 'xhigh' })))

const lenses = lensResults.filter(Boolean)
log(`Lenses: ${lenses.length}/${LENSES.length} completed.`)

phase('Synthesize')

const lensSummary = lenses.map(l =>
  `## LENS: ${l.lens}\n` +
  `WEAKEST_LINK: ${l.weakest_link}\n` +
  `WHY: ${l.why}\n` +
  `CEILING: ${l.ceiling}\n` +
  `REMEDIATION: ${JSON.stringify(l.remediation)}\n` +
  `OTHER: ${JSON.stringify(l.other_findings || [])}\n` +
  `NON-FINDINGS (do not re-audit): ${JSON.stringify(l.non_findings || [])}`
).join('\n\n')

const synth = await agent(
  `Synthesize the three lens outputs into ONE prioritized systemic roadmap. Do not just concatenate — CHOOSE among them. Which of the three weakest links is actually the ceiling? Which two are downstream symptoms of the first? What is the smallest set of things that must ship to change the trajectory of the whole system?\n\n` +
  `Constraints:\n` +
  `  - Preserve every proven-working part of Grok's suite. Do NOT propose rewrites.\n` +
  `  - Roadmap steps must be sequenced: step N unlocks step N+1.\n` +
  `  - Include 'do_not_do' items — traps a future session might fall into (over-eager stealth, humanization return, retail-API porting, etc.).\n` +
  `Write the synthesis to notes/ROADMAP_1_7.md (create it). Use headings + tables. Return SYNTH_SCHEMA.\n\n` +
  `--- LENS RESULTS ---\n${lensSummary}\n\n` + CTX,
  { label: 'synth:roadmap', phase: 'Synthesize', schema: SYNTH_SCHEMA, effort: 'xhigh' })

return {
  lenses: lenses.length,
  weakest_links_per_lens: lenses.map(l => ({ lens: l.lens, wl: l.weakest_link })),
  the_weakest_link: synth?.the_weakest_link,
  roadmap_steps: synth?.roadmap?.length ?? 0,
  output_file: synth?.output_file,
}
