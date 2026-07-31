export const meta = {
  name: 'raijin-addon-hang-audit',
  description: 'Find why the RaijinLab addon hard-freezes world entry (30s packet-watchdog timeout) even in load-only mode. Audit all addon files for load-time / world-entry main-thread hazards, verify each can actually cause a 30s freeze, synthesize minimal fixes.',
  phases: [
    { title: 'Audit',     detail: 'file-group auditors + world-entry timeline reconstruction' },
    { title: 'Verify',    detail: 'per-candidate: can it REALLY block the main thread 30s at world entry?' },
    { title: 'Synthesize', detail: 'ranked hang-causes + concrete minimal fixes' },
  ],
}

const CONTEXT = `
============================================================
PROBLEM
============================================================
The RaijinLab WoW 3.3.5 addon (Ascension private server) HARD-FREEZES the client on
"load into world": FrameXML loads, then the client stops processing incoming packets for
30s → "Packet watchdog timed out after 30 seconds without receiving a packet; forcing disconnect."
EMPIRICAL: addon DISABLED → world entry works fine. addon ENABLED → freeze. So the addon
is the cause. The injected runtime DLL is NOT loaded in these sessions (RaijinLab:HasRuntime()
returns false) — so the addon runs in "load-only mode".

A 30s PACKET-WATCHDOG timeout means the MAIN THREAD is blocked (WoW pumps the network on the
main thread between frames; if a Lua/C frame never returns, no packets are processed). So we are
hunting for MAIN-THREAD-BLOCKING behavior: infinite/very-long loops, runaway timer/ticker
recursion, re-entrant hooks, huge per-frame work, or an unguarded error-storm at world entry.
A plain one-shot Lua error does NOT cause this (WoW catches it) — so filter for BLOCKING, not erroring.

============================================================
ADDON LAYOUT
============================================================
Root: C:\\Ascension\\Workspace\\RaijinLab\\addon\\
TOC load order (RaijinLab.toc):
  libs\\bitops.lua
  core\\Variables.lua
  core\\Compat.lua           [READ — see below]
  core\\Runtime.lua          [READ — HasRuntime()=false path]
  core\\StatusUI.lua         [READ — already fixed a syntax bug; not the freeze]
  core\\API.lua
  core\\Hooks.lua            [READ — see below]
  core\\objects\\Functions.lua
  core\\objects\\Manager.lua   <-- registers its OWN PLAYER_ENTERING_WORLD at line ~238
  core\\objects\\Tracker.lua
  core\\Drawing.lua          [READ — see below]
  core\\Events.lua           [READ — see below]
  core\\Farming.lua
  modules\\arena\\Awareness.lua
  modules\\travel\\Travel.lua
  modules\\loot\\Looter.lua
  modules\\farming\\Farms.lua
  modules\\farming\\Farmer.lua
  modules\\questing\\Quests.lua
  core\\ChatHandler.lua      [READ]
  init.lua                   [READ — registers PLAYER_ENTERING_WORLD, VARIABLES_LOADED etc; sets OnUpdate=CoreOnUpdate]

============================================================
WHAT RUNS UNCONDITIONALLY (already established by Claude — build on this)
============================================================
init.lua: creates core_frame, registers PLAYER_ENTERING_WORLD/VARIABLES_LOADED/PLAYER_TARGET_CHANGED/
  TRACKED_ACHIEVEMENT_UPDATE/QUEST_ACCEPTED/QUEST_FINISHED/QUEST_LOG_UPDATE, sets OnEvent=CoreOnEvent,
  OnUpdate=CoreOnUpdate.
Events.lua CoreOnEvent: on VARIABLES_LOADED → RaijinLab:Init(). Runtime-gated block SKIPPED (no runtime).
Events.lua CoreOnUpdate: increments timer; returns early because HasRuntime()=false (the anti_afk/autointeract
  code below the early-return never runs without runtime). => CoreOnUpdate is benign without runtime.
Events.lua Init(): runs UNCONDITIONALLY (NOT gated by HasRuntime):
   PrintBanner(); CreateJumpHook(); CreateChatHook(); CreateTrackAchievementHook(); InitDrawing();
   and if ArenaTeamAwareness exists → AddDrawingCallback("arena", ArenaTeamAwareness).
Hooks.lua: CreateJumpHook (wraps global JumpOrAscendStart), CreateChatHook (wraps global SendChatMessage —
   intercepts msgs starting with "."), CreateTrackAchievementHook (wraps global AddTrackedAchievement to
   fire a synthetic TRACKED_ACHIEVEMENT_UPDATE then call original). These are plain global-function wraps
   (not hooksecurefunc); guards on multijump_toggle (false w/o runtime).
Drawing.lua InitDrawing(): creates private table; canvas = CreateFrame("Frame", WorldFrame)  <-- NOTE:
   2nd CreateFrame arg is NAME (string) but a FRAME TABLE (WorldFrame) is passed there — API misuse on 3.3.5;
   then private.canvas:SetAllPoints(WorldFrame); then onDrawTicker = Enable(1/100) = C_Timer.NewTicker(0.01, OnDrawUpdate)
   — a 100 Hz ticker. OnDrawUpdate: if private and IsPlayerInWorld() then clearCanvas(); for _,cb in pairs(callbacks) do cb() end end.
   Without runtime, callbacks is empty except possibly "arena" (ArenaTeamAwareness) added in Init().
Compat.lua: if native C_Timer is ABSENT, installs a polyfill: a single OnUpdate frame draining a 'waiters' list;
   NewTicker(delay,fn) recursively re-schedules via After. A 0.01s ticker under the polyfill re-arms every frame.
   IMPORTANT: determine if Ascension 3.3.5 HAS a native C_Timer. If yes, polyfill is skipped. If no, the polyfill
   drives the 100Hz drawing ticker.

============================================================
PRIME SUSPECTS TO CONFIRM OR CLEAR
============================================================
S1. Drawing 100Hz ticker (OnDrawUpdate) + "arena" ArenaTeamAwareness callback: if ArenaTeamAwareness runs every
    10ms at world entry and does heavy work or calls a runtime-only fn (RaijinLab:GetCameraPosition / WorldToScreen /
    ObjectPosition) that is NIL without the runtime → error-storm 100×/sec, OR blocks. Read modules\\arena\\Awareness.lua.
S2. CreateFrame("Frame", WorldFrame) name-arg misuse (Drawing.lua:341) — does it error/abort InitDrawing, or create a
    bad frame? On 3.3.5 CreateFrame(type, name, parent, template): passing a table as the name arg.
S3. objects\\Manager.lua PLAYER_ENTERING_WORLD handler (line ~238) — does it enumerate objects / loop / call runtime
    fns at world entry unconditionally? This is a top hang candidate. READ IT FULLY.
S4. Any file-scope (load-time) code in the 13 unread files that loops or does blocking work at parse time.
S5. The ArenaTeamAwareness drawing callback specifically (added unconditionally in Init if the function exists).

============================================================
TOOLING
============================================================
Read the files directly. This is a Lua static audit. No build/run available (can't launch the game).
`

const AUDIT_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['scope','findings'],
  properties: {
    scope: { type: 'string', description: 'which files/lens this agent covered' },
    findings: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      required: ['file','line','what','runs_when','blocks_main_thread','severity','evidence'],
      properties: {
        file: { type: 'string' },
        line: { type: 'integer' },
        what: { type: 'string', description: 'the hazardous code' },
        runs_when: { type: 'string', enum: ['load-time','VARIABLES_LOADED','PLAYER_ENTERING_WORLD','every-frame/ticker','on-hook','slash-command','never-without-runtime'] },
        blocks_main_thread: { type: 'string', enum: ['yes-hard-loop','yes-error-storm','yes-runaway-timer','maybe','no-just-errors','no'] },
        severity: { type: 'string', enum: ['critical','high','medium','low','info'] },
        evidence: { type: 'string' },
        fix: { type: 'string', description: 'concrete minimal fix' },
      } } },
    notes: { type: 'string' },
  },
}

const VERIFY_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['candidate','verdict','reasoning'],
  properties: {
    candidate: { type: 'string' },
    verdict: { type: 'string', enum: ['CONFIRMED-HANG','LIKELY-HANG','ERROR-ONLY','FALSE-ALARM','UNCERTAIN'] },
    reasoning: { type: 'string' },
    fix: { type: 'string' },
  },
}

const SYNTH_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['root_causes','fixes','output_file'],
  properties: {
    root_causes: { type: 'array', items: { type: 'string' } },
    fixes: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      required: ['file','change','why'],
      properties: { file: {type:'string'}, change: {type:'string'}, why: {type:'string'} } } },
    output_file: { type: 'string' },
    confidence: { type: 'string', enum: ['high','medium','low'] },
  },
}

phase('Audit')

const A = 'C:\\Ascension\\Workspace\\RaijinLab\\addon\\'
const GROUPS = [
  { key: 'objects', files: `${A}core\\objects\\Manager.lua, ${A}core\\objects\\Functions.lua, ${A}core\\objects\\Tracker.lua`,
    lens: 'Object manager + tracker. CRITICAL: Manager.lua registers its own PLAYER_ENTERING_WORLD (~line 238). Trace EXACTLY what fires at world entry without the runtime — does it enumerate objects, loop, or call runtime-only globals (EnumVisibleObjects / ObjectCount / IsLinuxClient / RaijinLab:RuntimeCall)? Does any load-time file-scope code run a loop? This is the #1 hang suspect.' },
  { key: 'drawing-arena', files: `${A}modules\\arena\\Awareness.lua, ${A}core\\Farming.lua, ${A}modules\\farming\\Farms.lua, ${A}modules\\farming\\Farmer.lua`,
    lens: 'The "arena" ArenaTeamAwareness drawing callback runs UNCONDITIONALLY at 100Hz (added in Init, driven by the Drawing ticker). Read Awareness.lua: what does ArenaTeamAwareness do each tick? Does it call runtime-only fns (WorldToScreen/GetCameraPosition/ObjectPosition) that are nil w/o runtime → error 100×/s? Does it loop over objects? Also audit Farming/Farms/Farmer for load-time or ticker loops.' },
  { key: 'compat-timer', files: `${A}core\\Compat.lua, ${A}core\\Drawing.lua, ${A}libs\\bitops.lua, ${A}core\\Variables.lua`,
    lens: 'Determine definitively: does Ascension 3.3.5 provide a native C_Timer? (Check GlueXML/FrameXML extracts if referenced, else reason from the client build 3.3.5/30300 — retail C_Timer did NOT exist until MoP, so 3.3.5 almost certainly uses the polyfill.) If polyfill is used, analyze the 100Hz drawing ticker interaction with the waiters-list OnUpdate: is there unbounded growth, re-entrancy, or per-frame O(n^2)? Also check bitops.lua + Variables.lua for load-time loops. Confirm/deny the CreateFrame("Frame", WorldFrame) name-arg misuse impact on 3.3.5.' },
  { key: 'modules-api', files: `${A}core\\API.lua, ${A}modules\\travel\\Travel.lua, ${A}modules\\loot\\Looter.lua, ${A}modules\\questing\\Quests.lua`,
    lens: 'Audit for load-time file-scope code that loops/blocks, and any hooksecurefunc / event registration that fires at world entry. API.lua especially: does it wrap/replace any global at load time, or define the runtime bridge in a way that recurses? Looter/Quests may register events that fire during world-entry data streaming.' },
]

const auditResults = await parallel(GROUPS.map(g => () => agent(
  `Audit these RaijinLab addon files for MAIN-THREAD-BLOCKING hazards that fire at load-time or world-entry (WITHOUT the runtime DLL, i.e. HasRuntime()=false):\n${g.files}\n\nLENS: ${g.lens}\n\n` +
  `Read each file fully. For each hazard return a finding. Focus on what can cause a 30s freeze (hard loop / error-storm / runaway timer / re-entrant hook), NOT plain one-shot errors. Rank by severity. Propose a concrete minimal fix per finding.\n\n` + CONTEXT,
  { label: 'audit:' + g.key, phase: 'Audit', schema: AUDIT_SCHEMA, effort: 'high' })))

// Timeline reconstruction — one agent walks the exact runtime-less boot sequence
const timeline = await agent(
  `Reconstruct the EXACT sequence of RaijinLab addon activity from ADDON_LOADED → VARIABLES_LOADED → PLAYER_ENTERING_WORLD, assuming HasRuntime()=false (runtime DLL not injected). Read init.lua, Events.lua, and any file the sequence touches (Manager.lua for its own PLAYER_ENTERING_WORLD frame, Drawing.lua for the ticker, Awareness.lua for the arena callback). Produce a step-by-step timeline and PINPOINT the single step most likely to block the main thread for 30s at world entry. Return the AUDIT_SCHEMA with findings = the blocking step(s).\n\n` + CONTEXT,
  { label: 'audit:timeline', phase: 'Audit', schema: AUDIT_SCHEMA, effort: 'high' })

const allFindings = auditResults.filter(Boolean).flatMap(r => r.findings || [])
  .concat((timeline?.findings) || [])
// keep only plausible hang candidates for verification
const candidates = allFindings.filter(f =>
  f.blocks_main_thread && f.blocks_main_thread.startsWith('yes') || f.blocks_main_thread === 'maybe' || f.severity === 'critical')
log(`Audit complete: ${allFindings.length} findings, ${candidates.length} hang-candidates to verify.`)

phase('Verify')

const verdicts = await parallel(candidates.map((c, i) => () => agent(
  `Adversarially verify whether this RaijinLab addon finding can REALLY cause a 30-second main-thread freeze at world entry (the observed symptom: packet-watchdog timeout). Re-read the cited file. A plain one-shot Lua error is NOT a freeze (WoW catches it) → verdict ERROR-ONLY. A hard loop, a runaway/re-entrant timer, an error thrown 100×/sec from a ticker (which can still stall + spam), or huge per-frame work → CONFIRMED/LIKELY-HANG. Be skeptical.\n\n` +
  `FINDING: ${JSON.stringify(c)}\n\n` + CONTEXT,
  { label: 'verify:' + (c.file||'f') + ':' + (c.line||i), phase: 'Verify', schema: VERIFY_SCHEMA, effort: 'high' })))

const confirmed = verdicts.filter(Boolean).filter(v => v.verdict === 'CONFIRMED-HANG' || v.verdict === 'LIKELY-HANG')
log(`Verify complete: ${confirmed.length} confirmed/likely hang-causes.`)

phase('Synthesize')

const synth = await agent(
  `Synthesize the ROOT CAUSE(S) of the RaijinLab addon world-entry freeze and the minimal fix set. You have:\n\n` +
  `ALL AUDIT FINDINGS:\n${JSON.stringify(allFindings, null, 1)}\n\n` +
  `VERIFIED HANG-CAUSES:\n${JSON.stringify(confirmed, null, 1)}\n\n` +
  `Produce: (1) root_causes — the specific code that blocks the main thread at world entry, ordered by certainty. ` +
  `(2) fixes — concrete minimal per-file changes (exact enough that an engineer applies them directly). Prefer surgical fixes that make the addon SAFE in load-only mode (no runtime): e.g. don't start the 100Hz drawing ticker unless runtime present / callbacks non-empty; guard ArenaTeamAwareness registration behind HasRuntime; fix CreateFrame arg order; guard the object-manager world-entry handler. ` +
  `(3) Write a full write-up to output_file C:\\Ascension\\Workspace\\RaijinLab\\notes\\15_addon_worldentry_hang.md including the timeline, the confirmed cause(s), each fix with before/after, and a regression checklist. Return SYNTH_SCHEMA.\n\n` + CONTEXT,
  { label: 'synth:fixes', phase: 'Synthesize', schema: SYNTH_SCHEMA, effort: 'high' })

return {
  findings: allFindings.length,
  candidates: candidates.length,
  confirmed: confirmed.length,
  root_causes: synth?.root_causes || [],
  fixes: synth?.fixes || [],
  writeup: synth?.output_file,
}
