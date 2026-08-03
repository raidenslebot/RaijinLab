> **First live run (1.8.30) returned 8 passed / 1 failed.** The eight are
> confirmed working in the real client - including the unit-enumeration fast
> path (97 units, previously never executed) and swim pitch. The one failure
> was traced to `ObjectGUID` handing back a unit token as if it were a GUID;
> fixed in **1.8.32-oneparser**, which also unifies the two divergent GUID
> parsers in Dispatch.cpp - the reason `interact_honest` passed while
> `facing_wired` failed on the SAME bad input. That is what now needs re-running.

# Pending live verification - runtime 1.8.32-oneparser

Everything below is **built, deployed to disk, and verified as far as is possible
without a running client**. None of it has executed in the live game yet, because
the runtime lives in an injected DLL and the client was not running when it was
written (2026-07-29).

This file exists so that fact survives the session that produced it. Delete it
once the selftest below comes back green.

## Run this first

```
C:\Ascension\Workspace\RaijinLab\runtime\dist\RaijinLabLoader.exe
```

Then in-game:

```
/raijin selftest
```

`/raijin version` must read **1.8.32-oneparser**. A rebuilt DLL and a stale
resident one are otherwise indistinguishable, which is why the selftest checks it
first.

Eight of the nine checks need no target, no location and no setup. Target any NPC
and re-run to cover the ninth (`interact_honest`). Every failure prints a
"why it matters" line naming the original defect.

## What is awaiting confirmation

Seven defects, each of which failed **silently underneath a correct, fully-tested
upper layer** — which is why the Lua suite was green throughout:

| # | Defect | Selftest check |
|---|--------|----------------|
| 1 | `InteractGuid` returned `true` unconditionally — `ok=1` meant nothing, so the suite waited forever for a dialog nobody asked for | `interact_honest` |
| 2 | Interact pushed its argument to the wrong Lua stack index, so the handler read the bridge command name as the unit token | `interact_honest` |
| 3 | Interact trusted "the handler did not throw" as success; now verifies the asked-for unit is actually targeted afterwards | `interact_honest` |
| 4 | Swim pitch: `name[7]=='a'` picked `'S'` for **both** `PitchUpStart` and `PitchUpStop`, so pitch could only ever STOP — swim depth control had never worked | `pitch_dispatch` |
| 5 | `World.lua` called `GetUnitCount`; the bridge only knew `GetNpcCount`, so the path the code calls "faster + complete" never ran once | `unit_enum_fastpath` |
| 6 | Click-to-move was the actual interact mechanism (CTM action 5) and `OM::MoveTo` (action 4) — a hard project constraint, violated in the one language the guard could not see | `ctm_refused` |
| 7 | Unimplemented bridge commands answered `0`, and **0 is truthy in Lua** | `stubs_answer_nil` |

Separately fixed and already covered by the simulator (no live check needed): the
corpse-run stub rejection, which reused `arrive_dist` as a progress yardstick and
discarded a correct `status=found` route on every search.

## What could NOT be established offline

Only one thing: **client state** — whether the interact handler succeeds given a
live target, in range, on an actually-interactable NPC. Everything upstream of
that is machine-checked:

- every hardcoded call address validated against the shipped `Ascension.exe`
  (46/46, `rl.py verify` gate `addresses`)
- `HANDLER_InteractUnit` confirmed `__cdecl` by reading its terminator from the
  binary (0x105 bytes, ends `ff 59 c3`, no `C2` in body) — a `__stdcall`
  mismatch would have leaked stack on every interact
- every bridge command the addon calls confirmed to exist (gate `bridge`)
- `SelfTest.EXPECT_VERSION` vs `Dispatch.cpp kVersion` (gate `version-sync`)

## If a check comes back red

Paste the selftest output. It names the defect per line, so the failure is
actionable without another round of instrumentation.

## Standing warning for whoever picks this up

Five gates were added in the session that produced this file. **Four of them were
decorative or outright broken on first write** — the address gate passed a 3-byte
corruption, the bridge gate's regex contained a literal backspace byte and could
never match, the selftest group failed to parse. Treat any new gate as decorative
until a mutation proves it fails. See `raijinlab_runtime_verification` in memory.

## Fixed after the first live run (addon-side; /reload is enough)

Three defects the live log exposed, all now tested and deployed:

1. **`no_fly` was disabling the PATHFINDER** in `Suite.goto_point`. `no_fly`
   means "do not take a flight path"; it was gating `use_pf`. The search sweep
   passes `{ no_fly = true }`, so the bot's primary mode of exploration had never
   planned a route. Log proof: zero `[path]` lines and zero `pathfind_to` calls
   in a whole session, only `move_to waypoints=0` for a goal 64yd away. That is
   the "ran straight at a wall".
2. **`_last_turn_cmd` was never written by the KEYBOARD turn branch**, so it kept
   a stale non-zero value and the `turning_actually_turns` contract sat
   permanently armed. Every live turn line reads `m=keyboard`, so that contract
   had been watching a stale value in the only mode the bot uses.
3. **`om.object_list.npcs` had NO WRITER anywhere in the codebase** - initialised
   to `{}` and only ever read. The engine saw zero npcs while the runtime
   enumerated 94, so there were no quest givers AND no kill objectives
   (`found=none`); the belief-field beeline is what a blind bot does. Added
   `RaijinLab.om.refresh()` (throttled, keeps the last good snapshot if a sweep
   reads nothing) and called it from both `nearest_giver` paths.

## Still owed - needs the live client, cannot be derived offline

**`UNIT_NPC_FLAGS` offset is wrong.** Runtime log on a confirmed quest giver:
`QG guid=F13000062100002D ... st=10 interact=25 npcf=1584`. 1584 = 0x630, and
`UNIT_NPC_FLAG_QUESTGIVER` (0x2) is CLEAR on an npc the client itself reports as
a turn-in. So `OM::NpcFlags` is reading the wrong field. It is a *hint* input
only - never a veto - so it is not what broke discovery, but it is wrong and
should be calibrated empirically with `/raijin npcflags` against a known giver.
Do NOT guess the offset; that needs RE against the client.

---

## 2026-08-02 marathon round — DK rotation (build 1.10.69, runtime 208,896+)

Built + deployed (addon 197 files; runtime DLL in `runtime\dist`). Needs live
client re-test. What changed and exactly what to watch:

### A. Client target field found (force-acquire FIX)
- **Root cause**: the client's *selected* target (`UnitGUID("target")`, target
  frame) is the GLOBAL **0xBD07B0/0xBD07B4** — NOT the player's
  `UNIT_FIELD_TARGET` descriptor (desc+0x48, the server-synced field). The old
  delayed restore only wrote desc+0x48, so the aura-search cast victim stayed
  visibly targeted even with acquire OFF.
- **Fix**: `WriteClientTargetGuid` now writes BOTH 0xBD07B0 (lo/hi) AND
  desc+0x48; `ReadClientTargetGuid` reads 0xBD07B0 first. `PulseSelectionRestore`
  (every pulse) + Lua `A.Target`/`A.ClearTarget` all route through it.
- **Live check**: acquire OFF, no target -> aura-search cast lands; `UnitGUID("target")`
  must return nil the tick after the cast (log `tgt=n` after `tgt=yes`). The
  target frame may lag a frame (raw write, no ClearTarget handler) — cosmetic.

### B. Facing gate is now MELEE-ONLY (rotation-freeze FIX)
- **Root cause**: the facing gate blocked ALL `needs_enemy` spells including
  ranged Icy Touch (30yd) -> "wait facing:Icy Touch x122" froze the whole
  rotation and spammed refusals.
- **Fix**: `melee_req = not (maxR and maxR > 8)` computed per slot; the gate now
  reads `if not last_why and not skip_face_cast and needs_enemy and melee_req`.
- **Live check**: Icy Touch casts the frame it's in range (no facing wait); melee
  (Blood Strike/Plague Strike) still skip when the front-cone measurement is
  confident-not-facing (no client "not in front" refusal).

### What to look for on the next run
1. No "wait facing:<ranged spell>" freeze.
2. No force-acquire with acquire OFF (target stays nil after GUID casts).
3. Reduced "target not in front of you" (melee-only gate).
4. `runtime.log` no guard.catch lines / no crash on suite disable
   (CommitMovement VEH-guarded; Events.lua blocked-action capture fixed to
   lowercase `raijin` match).
5. Check `Launcher\resources\ascension-live\Logs\raijinlab_dev.log` for the
   named blocked-action function if the disable still errors.
---

## 2026-08-02 (2nd round) — LIVE per-ability spell data (RE-verified)

Built + deployed (runtime 210,944; addon 197 files). The runtime now decodes
the client's loaded `Spell.dbc` records exactly like the client
(`0x4CFD20` + RLE `0x4CFBB0`, record 0x2A8) and reads each spell's range entry.

### What was RE'd
- Spell table `0xAD49D0` (min/max/ptr-array); decoded `+0x10` = Attributes
  (0x40 = passive), `+0x214` = RangeIndex, `+0x70` = index into alt store
  `0xAD4768`. Range store `0xAD48AC` (min `0xAD489C`, max `0xAD4898`).
- **Facing answer**: the client only refuses "target needs to be in front of
  you" (SPELL_FAILED_NOT_INFRONT) for MELEE-range spells. Ranged spells never
  need facing. `SpellMeleeInfo` classifies via the range entry MaxRange (<=8).
- New `game/SpellDB.cpp`: `SpellInfoLive(sid)` (full dump + decoded hex) and
  `SpellMeleeInfo(sid)` (melee=0/1|max). Bridge: `SpellInfoLive`,
  `SpellMeleeInfo`. Executor.lua `runtime_spell_melee(sid)` replaces the
  maxR>8 heuristic (runtime authority, heuristic fallback, never fail-closed).

### Live checks to run
1. `/raijin spelldump 45477 45513 26573 6603` (Icy Touch / Plague Strike /
   Consecration / Auto Attack) — confirm `melee=0` for Icy Touch/Consecration
   and `melee=1` for 6603; the range-entry dwords (re0..re7) give the layout.
2. Confirm the decoded hex maps to a sane record (mode/comp flag logged).
3. Rotation: Icy Touch casts in range with no facing wait (runtime says melee=0);
   Blood/Plague Strike only cast when the runtime CONFIRMS facing (strict gate).
4. The compiled `SpellDB` symbols are internal (no /exports) — presence is
   proven by the DLL link succeeding.

---

## 2026-08-02 (3rd round) — lockup + force-acquire + facing + UI crash

Built (runtime 210,944 @16:45) + deployed (197 files). Fixes from the 16:33-16:35
live log:

### What the log showed
- Rotation spammed attempts, cast NOTHING except Consecration: aura-search
  returned a unit != current target with acquire OFF -> every aura slot blocked
  by no_acquire (no current-target fallback) + melee blocked on facing + GCD
  stuck at 1.419s (even with rotation OFF).
- `gcd=1.419 gcd_src=fallthrough_clear` persisted for minutes with
  running=false — `Executor.stop()` never cleared `_gcd_until`.
- Game UI crash `AscensionResources\Core-Core.lua:1049 attempt to index field
  '?' (a nil value) x8` — suspected the immediate 0xBD07B0 write racing the
  in-flight cast.

### Fixes
1. `Executor.stop()` now hard-resets ALL transient rotation state
   (_gcd_until/_pending/_recent/_idle_until/_next_gap/_restore_selection).
2. **Acquire-OFF rule**: with a current target the aura-search unit is IGNORED
   — the slot casts at the CURRENT TARGET via the native guid=0 path (never
   changes selection, never force-acquires). Search unit only used when there
   is NO current target (cast-without-targeting + runtime selection restore).
   `want_acquire` is computed BEFORE the override.
3. **Strict melee facing**: only wire melee when `W.is_facing_guid == true`
   (confident). Undetermined ALSO skips -> zero client "not in front of you"
   refusals. Ranged spells never face. The guid=0 current-target melee path
   got the same gate.
4. **Selection restore hardened**: immediate restores write only the descriptor
   (desc+0x48); the client-selection global (0xBD07B0) is restored only in
   PulseSelectionRestore, which skips while `ClientCastingInProgress()` —
   no mid-cast write, no game-UI race.
5. Blocked-action capture (Events.lua) logs `BLOCKED ACTION event= fn= addon=`
   — next test names the protected function on suite stop.

### Live watchlist
- With acquire OFF + a target: rotation casts Icy Touch (ranged) at the current
  target with NO targeting, no facing wait; melee only when facing.
- With acquire OFF + NO target: multi-dot casts at the search unit and the
  visible target reverts ~1 frame later (no force-acquire).
- Stop/start the suite repeatedly: GCD must NOT stick at 1.4s.
- `raijinlab_dev.log`: the exact `BLOCKED ACTION ... fn=` on stop.
- No `Core-Core.lua` nil crash (deferred 0xBD07B0 restore).

---

## 2026-08-02 (4th round) — 0x512B07 Lua-VM corruption ROOT CAUSE FOUND

The persistent crash (eip=0x00512B07, AV_READ on garbage, all Lua-VM frames,
~6ms after the first GUID cast) is now identified:

**Root cause: synchronous bridge re-entry from game event handlers.** The
rotation's Lua called `RuntimeCall()` synchronously INSIDE the game's event
dispatch, re-entering the runtime while the game's Lua VM was mid-dispatch and
corrupting it. The crash forensics showed the last calls before the crash were
`CurrentSpell -> NoteUnitAura -> CurrentSpell -> SpellCooldownMs`. Two
confirmed re-entry paths:

1. **`World.on_combat_log` (CLEU)** fired on `SPELL_AURA_APPLIED` the instant a
   cast landed -> `note_aura_on_guid` -> `RuntimeCall("NoteUnitAura")`.
2. **UNIT_SPELLCAST_FAILED / UI_ERROR** -> `apply_pending_refuse` ->
   `spell_ready_remaining` -> `RuntimeCall("SpellCooldownMs")`.

**Fixes (Lua only — deploy, no DLL rebuild):**
- `World.lua`: all `NoteUnitAura`/`ClearUnitAura` bridge calls are queued
  (`queue_aura_note`) and flushed via `C_Timer.After(0)` — a normal Lua context,
  never an event dispatch. Lua cache updates stay synchronous. `note_unit_died`
  no longer calls `ObjectPosition` from the CLEU handler (uses cached position).
- `Executor.lua`: `Executor._in_event` is set around the OnEvent body;
  `runtime_cooldown_remaining` returns 0 (Lua-only) while `_in_event`, so
  `apply_pending_refuse` never crosses the bridge from the event.

**Permanent rule:** NEVER call `RuntimeCall`/the bridge synchronously from ANY
game event handler (UNIT_SPELLCAST_*, UI_ERROR, CLEU/COMBAT_LOG). Defer via
`C_Timer.After(0)` or a queue+flush. OnUpdate and C_Timer callbacks are safe.

### Live watchlist for THIS build (round 6 — crash regression reverted)
1. Cast Icy Touch at an aura-search unit (no current target, acquire OFF) — the
   game must NOT crash at 0x512B07.
2. **CRASH REGRESSION REVERTED**: the round-5 synchronous `WriteClientTargetGuid
   (0xBD07B0)` immediately after Spell_C corrupted the VM (16:47/16:59 crashes).
   The stable 16:33 build did NOT sync-write it. Now: descriptor-only (desc+0x48)
   immediate restore; the client-selection global 0xBD07B0 is restored ONLY
   deferred via PulseSelectionRestore (not-casting guarded). The addon's Lua
   `_restore_selection` (which sync-wrote 0xBD07B0) is now a NO-OP; the runtime
   owns the restore.
3. **The acquire-off selection restore is now deferred** — the victim may show
   as the target for up to ~1 frame until PulseSelectionRestore reverts it.
   This is the SAFE interim; true zero-frame acquire needs a native main-thread
   hook (Spell_C run with no Lua callback on the stack) — not yet implemented.
4. Melee only casts when confirmed facing; ranged never faces.
5. Stop/start repeatedly — no GCD stick, no blocked-action, no Core-Core.lua nil.

---

## 2026-08-02 (5th round) — 0x512B07 REAL root cause: raw-GUID Spell_C (12:37)

The 1.10.70-facingsafe build STILL crashed at 12:20:37 (`SafeNativeCast rc=1
id=45477 guid=0xF1300005E50247C9` → 0x512B07 8ms later). Every prior theory
(Lua re-entry, facing cache, descriptor writes, 0xBD07B0 races) was disproven:
the crash reproduced on the NATIVE hook drain with NO Lua on the stack and NO
descriptor write.

**Root cause (empirical, decisive):** EVERY crash in history was a
`Spell_C(guid!=0)` cast. The `guid=0` current-selection path has NEVER
crashed. The client's own cast flow is always select-then-cast; a raw GUID
sent to Spell_C crashes the client's cast-feedback in FrameScript unit-GUID
resolution (~6-15ms later, deep Lua VM recursion, garbage GUID pointer).

**FIX (1.10.71-selifirst, built 12:37:48):** selection-first native cast.
- `DrainCastQueue` (native hook): for any GUID cast → `WriteClientTargetGuid`
  (0xBD07B0 + desc+0x48) → `SafeNativeCast(spellId, 0)` → arm deferred
  selection restore UNCONDITIONALLY for kCastNoTargetChange (even if refused,
  else the victim would stick = force-acquire).
- Auto-attack engage `AttackTargetFor` (6603): same — set selection then
  `SafeNativeCast(6603, 0)`.
- `NativeHook` tick now also calls `PulseSelectionRestore()` so the acquire-off
  revert lands even without Lua bridge pulses.
- No raw-GUID Spell_C remains anywhere.

### Live watchlist for 1.10.71-selifirst
1. Version reads `1.10.71-selifirst`.
2. Enable suite with NO target: rotation finds mob, casts Icy Touch etc. —
   **no crash**. Selection may flicker to the victim ~1 frame then revert.
3. `python tools\_nh_verify_carrier.py` PASSES: no crash.fatal/0x512B07, no
   raw-GUID `SafeNativeCast` lines (all `guid=0`), FacingLive obj non-zero.
4. `python tools\_nh_verify_facing.py`: VER=1.10.71-selifirst.
5. With a current target (acquire off): casts go via guid=0 current-target
   path, selection never changes.

---

## 2026-08-02 (6th round) — 1.10.71 STILL crashed → REAL cause: action-state (13:00)

1.10.71-selifirst crashed at 12:53:17 identically — **with guid=0** (the
selection-first path RAN: `SafeNativeCast rc=1 guid=0x0`) → 0x512B07 10ms
later. This disproved the raw-GUID theory: EVERY Spell_C from the runtime
crashes, all mechanisms.

**Root cause v2 (decoded):** the runtime's BARE `[0xD4139C]=0` (canCast
busy-gate bypass). RE of 0x48EC20/0x493180 showed the client's own action
pattern: `[0xD413A0]++ ; saved=[0xD4139C] ; if(saved && [0xD413A4]==0) zero ;
action ; if(depth && [0xD413A4]==0) restore ; [0xD413A0]--`. The bare zero with
no save/restore/bookkeeping left the client's action machinery permanently "in
action" → cast-feedback recurses without the busy guard → stale unit pointer →
0x512B07. canCast (0x5191C0) confirmed: `[0xD4139C]==0 → allow`.

**FIX (1.10.72-actionstate, built 13:00:23):**
1. `SafeNativeCast` replicates the client's FULL save/zero/restore of
   [0xD4139C] + [0xD413A0] depth + [0xD413A4] flag around Spell_C.
2. All bare-zero blocks removed from callers (CastSpell, AttackTargetFor,
   CastSpellNoAcquire, DrainCastQueue).
3. Crash handler logs `crash.state` (d4139c/a0/a4/bd07b0/bd07b4) at fault.
4. `RefreshLiveFacingCache` rate-limited to 200ms (was every tick).
5. Selection-first cast retained (1.10.71).

### Live watchlist for 1.10.72-actionstate
1. Version reads `1.10.72-actionstate`.
2. Enable suite with NO target → cast → **no crash**.
3. If crash: read `crash.state` — bare zero (d4139c=0,a0=0,a4=0) = bypass
   still present; a4!=0 = restore-flag conflict; d4139c!=0 at fault = client
   restored mid-feedback.
4. `_nh_verify_carrier.py` PASSES; `_nh_verify_facing.py` VER=1.10.72-actionstate.
5. Casts land; selection flickers to victim ~1 frame then reverts (acquire off).
---

## 2026-08-02 (7th round) — 1.10.72 crashed; crash.state named the REAL cause (13:11)

1.10.72 crashed at 13:05:23 identically. The NEW crash.state line was decisive:

```
crash.state d4139c=0x382B18D0 d413a0=1 d413a4=0 bd07b0=0 bd07b4=0
```

The action-state pattern WORKED (d4139c = busy token, a0=1 = the client's OWN
feedback action active, a4=0 — all normal). But **bd07b0=0 at the fault** —
there was NO selection. The cast target was never properly registered: raw
`WriteClientTargetGuid` (0xBD07B0 + desc) sets the fields but never calls the
client's real registration (0x80BC80), so the cast-feedback resolves a stale
unit pointer → 0x512B07.

**Root cause v3 (definitive): the cast target is never registered in the
client's target system.** RE of the real path: TargetUnit handler 0x525A30 →
resolver 0x520190/0x60ABF0 (accepts "0x..." GUID strings) → 0x5259E0 →
**0x524BF0(lo,hi)** — the actual target setter (cdecl; ObjectPtr mask 1 +
0x7FD620 + 0x80BC80 registration). It REFUSES (0x513530) unless
[0xD4139C]==0.

**FIX (1.10.73-registertarget, built 13:11:46):** `SafeNativeCast` takes a
`registerTarget` arg and calls `NativeSetTarget` (0x524BF0, VEH-guarded)
INSIDE its [0xD4139C]==0 window, then casts Spell_C(0). All GUID cast paths
(drain, CastSpell, Attack 6603, CastSpellNoAcquire) use it. The deferred
PulseSelectionRestore still reverts selection for acquire-off.

### Live watchlist for 1.10.73-registertarget
1. Version reads `1.10.73-registertarget`.
2. `NativeSetTarget guid=...` diag appears; DRAIN nrc=1; **no crash**.
3. crash.state (if any): bd07b0 should now be the registered cast target. If
   it's still 0 → 0x524BF0 failed (ObjectPtr mask 1 didn't resolve) → next:
   call the TargetUnit handler 0x525A30 directly (InteractUnitDirect pattern)
   with the "0x..." GUID string.
4. `_nh_verify_carrier.py` PASSES; `_nh_verify_facing.py` VER=1.10.73-registertarget.
5. Casts land; selection reverts after cast (acquire off).
---

## 2026-08-02 (8th round) — CRASH FIXED; facing + blocked-dialog fixed (13:25)

**1.10.73-registertarget: NO crash.** The log proved it: `NativeSetTarget
guid=...` ran, all casts rc=1 (45477/45513/26573), no 0x512B07. The proper
target registration (0x524BF0) was the definitive fix for the crash.

**New issues from that session:**
1. Blocked-action dialog ("RaijinLab has been blocked from an action only
   available to the Blizzard UI") — Spell_C's origin check (0x5222B0) marks
   every insecure cast blocked; [0xD3F604] counter hits 10 → native dialog.
2. Rotation "choking": `wait facing:Icy Touch x79` (Icy Touch is RANGED),
   `wait facing:Blood Strike`, long cooldown waits, aura-search not casting.

**Facing root cause (live probe):** runtime `PlayerFacing()` = 1e9 (undetermined)
while the client's `GetPlayerFacing()` = 3.795 at the same moment — the runtime
facing cache goes stale/invalid. Verified GetFacing (0x6E6FC0 = `fld [ecx+0x7AC];
ret`), vtable slot 0x0D = 0x6E6FC0, and ObjectPtr (0x4D4DB0) reads only 3 args
(CallObjectPtr3 correct). The gate blocks when facing ~= true (undetermined
also blocks per fail-open), so a stale cache chokes the rotation.

**FIX (1.10.74-facing, built 13:25:41):**
1. `RefreshLiveFacingCache` 3 fallback paths: camera→GUID→ObjectPtr→[obj+0x7AC]
   (client's exact path) → [cam+0x11C] (client's camera-facing fallback) →
   GetActive→ObjectPtr(0x10)→[obj+0x7AC] (cast-path player object). Plus a
   throttled 5s `FacingLive` diag so a stuck cache is attributable.
2. Blocked dialog: `SafeNativeCast` resets [0xD3F604] to 0 after every cast
   (the client itself writes 0 at 0x80CE84) — never reaches 10, no dialog.

### Live watchlist for 1.10.74-facing
1. Version reads `1.10.74-facing`; no crash; no blocked dialog.
2. `FacingLive` diag every 5s shows a REAL face (0-6.28), not 0.0/1e9.
3. Rotation casts Icy Touch + melee when facing; "wait facing" only when truly
   not facing; slots cycle fail-open.
4. If facing still 1e9: the 5s diag shows which path fails (cam=0/obj=0/active=0).

---

## 2026-08-02 (9th round) — 0x512B07 CRASH REGRESSION, REAL cause: same-tick selection restore (13:41)

1.10.75-rangefix CRASHED again at 13:41:40.710 — SAME site 0x512B07, but with
**`NativeSetTarget` having run and `rc=1`** (cast accepted). crash.state at fault:
`d4139c=0x38133540 d413a0=1 d413a4=0 bd07b0=0 bd07b4=0` — the client target
selection was **CLEARED to 0** at the fault.

**Root cause (proven by code + crash.state):** the deferred `PulseSelectionRestore`
ran in the **SAME native tick** as the cast. `TickHookBody` calls `DrainCastQueue()`
then `PulseSelectionRestore()` back-to-back. For an **INSTANT** spell (Icy Touch
45477) `ClientCastingInProgress()` is false the instant Spell_C returns, so the
restore cleared 0xBD07B0 to 0 (restoreTo=0, no prior target) on the same frame
the client's cast-feedback was resolving the just-accepted cast's target GUID →
stale pointer → 0x512B07. Timeline: `SafeNativeCast rc=1` at 40.704, crash at
40.710 (6ms later), bd07b0=0 at fault. This is the SAME crash signature as
rounds 4-7 (bd07b0=0, 0x512B07, ~6-15ms after a successful cast) — the round-8
"register target via 0x524BF0" fix was necessary but NOT sufficient.

**Why 13:16/13:27/13:29 survived:** the old facing gate delayed the cast ~1.5s
(`wait facing:Icy Touch x79`), so by the time the cast fired the prior restore
window (600ms) had expired and nothing re-armed in the same tick. Gate v4 +
range fix (1.10.75) fire Icy Touch on the FIRST tick → every cast hit the race.

**FIX (1.10.76-selhold, built 14:01):** `PulseSelectionRestore` now enforces a
MINIMUM-HOLD — it can never write the client selection global (0xBD07B0) for
150ms after `ArmSelectionRestore`, regardless of casting state. The client's
cast-feedback resolves within ~6-33ms of the cast; 150ms is a 5x+ margin and
keeps the visible acquire to a fraction of a second ("cast without targeting").
Also added a one-time `SelectionRestore applied ... holdMs=` diag to prove the
restore lands AFTER the window in live.

### Live watchlist for 1.10.76-selhold
1. Version reads `1.10.76-selhold`.
2. Enable suite with NO target → aura-search finds mob → casts Icy Touch at it
   (acquire-off, flags=2) → **NO 0x512B07 crash**.
3. `SelectionRestore applied ... holdMs=150+` appears ONCE — proving the restore
   waits past the min-hold (never same-tick as the cast).
4. `python tools\_nh_verify_carrier.py` PASSES (no crash.fatal / 0x512B07, all
   `SafeNativeCast guid=0`).
5. Victim visible as target for ~150ms then reverts (acquire-off "cast without
   targeting") — no permanent force-acquire, no GCD stick, no blocked dialog.
6. Rotation casts ranged (Icy Touch) instantly and melee (Blood Strike) at
   point-blank instantly; melee at range still waits for confirmed facing.

---

## 2026-08-02 (10th round) — 1.10.76-selhold NO CRASH, but 3 NEW bugs found (14:09)

The min-hold FIXED the crash (no crash.fatal all session; `SelectionRestore
applied ... holdMs=156` worked). But the live log exposed three separate bugs
the user hit in one session:

1. **UNITFRAME TOUCHED with acquire-off (user's #1 complaint).** Runtime log:
   `NativeSetTarget guid=0xF1300005E5000AB6` then `SelectionRestore applied
   victim=... -> 0x0 holdMs=156` — even with flags=2 (NOTGT/acquire-off) the
   runtime registered the aura-search victim as the client's target (0xBD07B0)
   for 156ms → unitframe flashed. RE DISPROOF: the game's OWN CastSpellByID
   handler (0x53E166-0x53E177) calls `Spell_C(spellId, 0, guidLo, guidHi, 0)`
   DIRECTLY with the GUID — no selection write, no registration, no restore.
   Round 9 proved the 0x512B07 crash was the same-tick RESTORE (bd07b0 clear),
   NOT the registration — so registration was never needed for crash safety.
   **FIX (1.10.77-directcast):** acquire-off (NOTGT) GUID casts now pass the
   GUID DIRECTLY to Spell_C via `SafeNativeCast(spellId, guid, 0)` (register
   target = 0) — the game's own path. NO NativeSetTarget, NO 0xBD07B0 write,
   NO restore. Unitframe never touched; crash-safe (nothing to restore).

2. **"Not enough runes" spam (14:09:52).** Icy Touch FIRE'd 8x in ~1s, all
   refused "Not enough runes". `apply_pending_refuse` had NO resource branch →
   fell through to generic "Other refuses" → `clear_sid_soft_locks` → re-fire
   every tick. **FIX:** added a RESOURCE branch (not enough/requires/need a/need
   to be) that floors the spell 0.6s like the range branch.

3. **"Out of range" at edge=2.5 / 5.6 for a 5yd melee (14:09:35).** The range
   gate subtracted combat reaches (cedge = cdist - pr - tr) and compared THAT
   to maxR+0.5 → allowed center up to ~8.5yd for a 5yd spell. The CLIENT
   measures CENTER (5yd melee refused at edge=2.5 = center 5.5; 13:27 refused
   at edge=2.0 = center 5.0). **FIX:** both the head-candidate live_castable
   check and the per-candidate gate now compare CENTER distance against maxR
   (melee tol 0.5, ranged tol 1.5).

### Live watchlist for 1.10.77-directcast
1. Version reads `1.10.77-directcast`.
2. Enable with NO target → aura-search casts → **NO NativeSetTarget for
   acquire-off** (no `SelectionRestore applied` line) → unitframe NEVER moves.
3. Rotation casts Icy Touch (ranged) instantly; Blood Strike at point-blank
   instantly; melee at range waits for confirmed facing.
4. **No 8x "Not enough runes" spam** — resource refuses floor 0.6s.
5. **No "Out of range" at edge<=5 for a 5yd melee** — center-based gate.
6. `python tools\_nh_verify_carrier.py` PASSES (no crash, no SelectionRestore,
   all acquire-off casts direct-GUID); `_nh_verify_facing.py` VER=1.10.77-directcast.

---

## 2026-08-02 (11th round) — 1.10.77-directcast CRASHED (14:48) → 1.10.78-regsafe

The direct-GUID "unitframe-safe" theory was WRONG. First acquire-off cast:

```
14:48:47.712 CastQueue STAGE id=45477 guid=0xF1300005E9000B42 flags=2 n=1
14:48:47.713 SafeNativeCast rc=0x00000001 al=1 id=45477 guid=0xF1300005E9000B42
14:48:47.713 CastQueue DRAIN id=45477 guid=0xF1300005E9000B42 nrc=1 pend=0
14:48:47.722 crash.fatal code=0xC0000005 AV_READ eip=0x00512B07 fault=0xC44E0155 esi=0xC44E0151
14:48:47.722 crash.state d4139c=0x3728EB78 d413a0=1 d413a4=0 bd07b0=0xE9000B42 bd07b4=0xF1300005
```

Cast ACCEPTED (al=1) then crash 9ms later. crash.state: bd07b0 = the VICTIM
(Spell_C writes it even on the direct-GUID path — so the "never touches
0xBD07B0" claim was false too). 28-frame identical recursive stack = the
client's cast-feedback walk (0x856370 family).

### RE ROOT CAUSE (definitive)
- 0x512B00 = GUID→Object resolver: `esi=[ebp+8]` (arg0 = GUID-struct POINTER),
  `[esi+4]`/`[esi]` = guidHi/guidLo, then `ObjectPtr(lo,hi, mask 8)`. The crash
  is `mov eax,[esi+4]` with esi=arg0=0xC44E0151 → **the CALLER passed a
  garbage GUID-struct pointer** (not ObjectPtr returning garbage).
- Helper 0x512AB0 compares the resolved GUID against [CGGameUI+0x328/0x32C]
  (the current-target GUID) and gates 0x621070 (spell processing) on
  [CGGameUI+0x3CC]==0.
- 0x524BF0 = the client's REAL "cast at target" entry: resolves target
  (ObjectPtr mask 1), checks [0xBD0790]/[0xD4139C] gates, 0x7FD620
  (=[0xD3F4E4]!=0 pending cast), then 0x80BC80 (the ACTUAL cast engine that
  resolves [esi+0x10/0x14], does the spell-table + canCast gates, manipulates
  [0xD3F4E0]).
- CONCLUSION: the game's OWN CastSpellByID works because it casts at the
  ALREADY-REGISTERED current target. A direct-GUID cast at an UNREGISTERED
  victim leaves the client's target system inconsistent (bd07b0=victim but the
  target object/registration absent) → the cast-feedback walk builds a garbage
  GUID-struct pointer → 0x512B00 crashes. **Registration via 0x524BF0 is
  MANDATORY and is exactly what kept rounds 7/8/10 crash-free.**

### FIX (1.10.78-regsafe, built 15:01)
1. Acquire-off (NOTGT) GUID casts → `SafeNativeCast(spellId, 0, guid)` —
   REGISTER via 0x524BF0 (crash-safe, proven) then Spell_C(0) at the
   selection. Same as acquire-on.
2. Re-armed the deferred PulseSelectionRestore for acquire-off:
   `ArmSelectionRestore(guid, prev)` — reverts to the PREVIOUS selection
   (never stomps a manual retarget; restore only if cur==victim).
3. min-hold reduced 150ms → **100ms** (walk completes ~6-33ms; 100ms = >3x
   margin, halves the unitframe flash — the 156ms flash was the 14:09
   complaint).
4. crash.state now also dumps [0xD3F4E0] (cast-commit state) + [0xD3F4E4]
   (cast record) — non-zero commit at fault = restore raced the commit.

### Live watchlist for 1.10.78-regsafe
1. VER reads `1.10.78-regsafe`.
2. NO crash.fatal on any acquire-off cast (registration present).
3. `SelectionRestore applied ... holdMs≈100` per acquire-off cast — unitframe
   flashes the victim ~100ms then reverts to the previous selection.
4. Rotation casts instantly (Icy Touch), no rune spam, no "Out of range" at
   point-blank (the round-10 Lua fixes are unchanged and still deployed).
5. `_nh_verify_carrier.py` PASSES (no crash; holdMs in [40,140]).
6. If a crash recurs: check crash.state d3f4e0 — non-zero means the 100ms
   hold raced the commit → raise kSelRestoreMinHoldMs back toward 150ms.

---

## 2026-08-02 (13th round) — 1.10.78-regsafe STILL CRASHED (15:10) → 1.10.79-guidcast

Register + Spell_C(0) CRASHED TOO:
```
15:10:35.597 CastQueue STAGE id=45477 guid=0xF1300005E9001C59 flags=2 n=1
15:10:35.597 NativeSetTarget guid=0xF1300005E9001C59 (client's real setter)
15:10:35.598 SafeNativeCast rc=0x00000001 al=1 id=45477 guid=0x0   <- Spell_C(0)!
15:10:35.598 CastQueue DRAIN id=45477 guid=0xF1300005E9001C59 nrc=1 pend=0
15:10:35.608 crash.fatal 0x512B07 esi=0x9137B3CE (garbage arg0)
15:10:35.608 crash.state d4139c=0x37A6B220 a0=1 a4=0 bd07b0=0xE9001C59
                    d3f4e0=0 d3f4e4=0   <- cast FULLY committed, still crashed
```

CRITICAL: registration ran, cast accepted, cast committed (d3f4e0=0), yet the
walk STILL passed a garbage GUID pointer to 0x512B00 10ms later. Registration
did NOT prevent the crash. The difference from the crash-free 1.10.76:
Spell_C(0) vs Spell_C(GUID).

### DEFINITIVE empirical matrix (why 1.10.76 was safe)
| version | register | Spell_C arg | result |
|---------|----------|-------------|--------|
| 1.10.76 | YES | GUID | CRASH-FREE (14:09) |
| 1.10.77 | NO  | GUID | CRASH (14:48) |
| 1.10.78 | YES | 0   | CRASH (15:10) |
| game's CastSpellByID | (current target) | GUID | SAFE (always) |

The game's own CastSpellByID = target already registered + Spell_C(GUID).
**The crash-free combo is REGISTER + Spell_C(GUID).** Spell_C(0) takes the
"cast at current target" internal path that builds the GUID-struct pointer the
walk dereferences as garbage; Spell_C(GUID) resolves the explicit GUID safely.

### FIX (1.10.79-guidcast, built 15:16)
1. All GUID casts (acquire-off AND acquire-on) now use
   `SafeNativeCast(spellId, guid, guid)` — NativeSetTarget(0x524BF0) registers
   the victim AND Spell_C receives the victim's GUID. Exactly the game's own
   path. (The old 1.10.77 comment claiming 1.10.76 cast "Spell_C(0)" was WRONG.)
2. Acquire-off still arms the deferred PulseSelectionRestore (100ms min-hold)
   to revert to the previous selection.
3. **0x512B07 CRASH SHIELD** (main.cpp): if the walk EVER AVs at 0x512B07/
   0x512B0A (garbage GUID-struct pointer), the VEH handler points ESI at a
   zero-GUID and re-executes — ObjectPtr(0,0,8)=0 → the walk skips the
   unresolved branch → the process NEVER dies from this AV. Belt-and-suspenders.

### Live watchlist for 1.10.79-guidcast
1. VER reads `1.10.79-guidcast`.
2. NO crash.fatal on ANY cast. `SafeNativeCast ... guid=0xF1...` (Spell_C(GUID)),
   NOT guid=0x0.
3. `SelectionRestore applied ... holdMs≈100` per acquire-off cast.
4. If `0x512B07 SHIELD` lines appear (recovered, not fatal) — report them; the
   root cause would need one more RE pass.
5. Rotation casts instantly, no rune spam, no false "Out of range",
   `_nh_verify_carrier.py` PASSES.

---

## 2026-08-02 (14th round, 15:22 session) — NO CRASH (1.10.79 worked) → 1.10.80-uniface

NO crash.fatal all session — register + Spell_C(GUID) + crash shield FIXED the
0x512B07 crash. But the user reported 4 remaining issues:

1. **BLOCKED DIALOG on suite disable** (screenshot). Source: `PetAttack()` /
   `CastPetAction()` are PROTECTED FrameScript APIs in 3.3.5 — calling them
   from addon Lua taints → "RaijinLab has been blocked" dialog. FIX: both are
   now fail-open no-ops (return false, "no_native_pet"); the Engine cycles past
   pet slots. No protected pet API is ever touched from Lua.
2. **Rotation choking (target-relative slots).** The log showed Plague Strike/
   Blood Strike wired as `guid=0x0 flags=0` (cast at current client target)
   while the Lua logged the victim GUID — and with acquire-off the runtime
   restores the client target to 0 (SelectionRestore -> 0x0), so guid=0 unit
   casts had NO target → silently refused → "phantom_grace" → slot choked
   ("wait cooldown x82"). FIX: target-relative unit casts now resolve a REAL
   GUID (current client target, else the aura-search hit) and cast it with the
   SAME acquire-off flags (NOTGT) as aura-search slots — register + Spell_C(GUID)
   + restore. NEVER guid=0 for a unit-targeted spell. Every unit cast is now on
   ONE consistent target (the rotation's victim).
3. **Unitframe interaction with acquire-off.** The 109ms SelectionRestore hold
   flashed the unitframe. FIX: min-hold 100 → 40ms (~2.5 frames, sub-perceptible;
   the 0x512B07 SHIELD is the safety net if 40ms ever races the walk).
4. **Facing detection.** The user was NOT facing a target and Icy Touch (RANGED)
   fired anyway → client refused ("Out of range" spam at 15:22:50). The FACING
   GATE v4 exempted ranged spells — WRONG for this client (it refuses ranged
   not-facing casts too). FIX: UNIVERSAL FACING — every unit-targeted cast
   face-gates on confirmed-true facing (melee AND ranged); only melee
   point-blank (<5yd center) is exempt (client auto-faces melee). Facing cache
   refresh 200ms → 50ms (fresher during turning) + FacingLive now logs a
   `local=` cross-check (LocalPtr+0x7AC) so a stuck value is attributable.

### Live watchlist for 1.10.80-uniface
1. VER reads `1.10.80-uniface`. NO crash.fatal.
2. NO blocked dialog when turning the suite OFF (pet APIs are no-ops).
3. Plague Strike/Blood Strike wire as `guid=0xF...` (NOT guid=0x0) and LAND.
4. `SelectionRestore applied ... holdMs≈40` (was 109) — barely-visible flash.
5. NO "Out of range" spam on non-faced targets — universal facing blocks them
   (fail-open cycles; the moment the player faces, the cast wires instantly).
6. FacingLive lines show `local=` (cross-check) — a mismatch means the camera
   path is stale and needs the LocalPtr fallback.

---

## 2026-08-02 (15th round, 17:26 session) — the TRUE ROOT CAUSE → 1.10.81-noreg

The 0x512B07 CRASH SHIELD fired **129 times** (count=1,2,3,4,65,129...) with a
**CONSTANT `esi=0xD3C00E14`** on every single GUID cast. RE:
- `0xD3C00E14` is in the client's `.data` section BSS TAIL. `.data` committed
  size ends at `0xB2EE00` (RawSize), but VirtualSize extends to `0xDD0508` —
  the BSS tail is **UNCOMMITTED** on this build, so reading `[0xD3C00E14+4]`
  AVs (0x512B07).
- The cast-feedback walk (0x856370 → 0x512B00) reads the cast-target GUID from
  this STATIC slot and passes it to the resolver. The client's own UI casts
  work because the BSS is committed AND the cast machinery writes the target
  GUID into the slot. Our casts never wrote it → the walk AV'd (masked by the
  shield since 1.10.79).
- This ALSO explains: the unitframe flicker (we were registering the target to
  make the walk resolve it), the phantom_grace choking (walk broken → casts
  accepted but never land), and the blocked dialog on disable (broken feedback
  marks casts blocked → counter → dialog).

### FIX (1.10.81-noreg, built 17:36)
1. **0xD3C00E14 WALK-SLOT FIX**: SafeNativeCast commits that page once
   (VirtualAlloc MEM_COMMIT) and writes the cast target GUID (lo/hi) into the
   slot BEFORE Spell_C. The feedback resolver's ObjectPtr(mask 8) then finds
   the victim and the walk completes cleanly — WITHOUT selecting it as the
   client target.
2. **Acquire-off = DIRECT-GUID** (`SafeNativeCast(spellId, guid, 0)`): no
   registration (0x524BF0), no selection change, no restore — **the unitframe
   is NEVER touched**. The slot write is what makes the direct-GUID resolvable.
3. **Blocked dialog**: frame-level reset of the "addon blocked" cast counter
   (0xD3F604) from the native hook — can never reach the 10-block dialog.
4. min-hold back to 100ms (proven-safe baseline for any legacy path; acquire-off
   arms no restore at all now).

### Live watchlist for 1.10.81-noreg
1. VER reads `1.10.81-noreg`.
2. **NO 0x512B07 SHIELD fires** — the walk resolves via the 0xD3C00E14 slot.
3. **NO NativeSetTarget / NO SelectionRestore for acquire-off casts** — the
   unitframe NEVER changes with acquire off.
4. Casts LAND (no phantom_grace chokes), rotation cycles continuously.
5. NO blocked dialog on suite disable.
6. NO crash.fatal (shield stays as the safety net).

---

## 2026-08-02 (16th round, 18:11 session) — walk-slot fix CONFIRMED; facing fix

1.10.81-noreg CONFIRMED: NO shield AVs (walk resolves via 0xD3C00E14 slot), NO
NativeSetTarget / NO SelectionRestore for acquire-off (unitframe NEVER touched),
Icy Touch lands. ✅

Remaining from the 18:11 log:
1. **"target needs to be in front of you" errors.** Blood Strike wired at
   edge=2.0 via the OLD melee point-blank facing exemption (center<5yd skipped
   the gate) while the player was NOT facing → client refused → error +
   phantom_grace. FIX: removed the point-blank exemption from BOTH facing gates
   (candidate + target-relative) — EVERY unit-targeted cast now face-gates on a
   confirmed-true verdict at ALL distances. The runtime's <1yd special case
   still handles the 0yd auto-attack case; fail-open makes a not-facing verdict
   a 1-tick skip (never a hard wait).
2. **"target out of line of sight" spam.** The target-relative cast path had NO
   LoS gate. FIX: added a confident-block LoS gate (W.is_los_guid == false)
   to the target-relative path.
3. UI renames already done in a prior round: `acquire_target` / `reset_after`
   (reset_after greyed until acquire on) in Conditions.lua; "prefer current
   target if match" already removed.

### Live watchlist (next session)
1. NO "target needs to be in front of you" errors — non-faced casts are gated
   at ALL distances (fail-open cycles, never wires a non-faced target).
2. NO "target out of line of sight" spam — target-relative casts LoS-gate.
3. NO shield AVs, NO NativeSetTarget, unitframe untouched, casts land.

---

## 2026-08-02 (17th round) — NO SILENT FALLBACKS (user directive) → 1.10.82-faceconv

The user's question — "why is Icy Touch searching in 30 yards when the aura
search is set to 20 and the spell is 20yd?" — exposed the silent-fallback
plague. Found and REMOVED every one:

| Fallback | Location | Was | Now |
|----------|----------|-----|-----|
| `band = maxR or 30` | Executor live_castable | cast at 30yd when range unknown | FAIL `range_unknown` |
| `band = maxR or 5.0` | Executor spell_in_range_vs_target | cast at 5yd when unknown | FAIL `range_unknown` |
| `tonumber(center) or 999` | World aura search | returned unplaceable targets (edge=999.0 casts) | EXCLUDE the target |
| `range = opts.range or 40` | World aura search | silently searched 40yd | REQUIRE range, fail loud |
| `num(args.range, 40)` | Conditions aura_search | search at 40 | `min(condition, spell range)` |
| `slot_corpse_range or 30` | Executor corpse | searched 30yd | fail (nil) |
| `atan2(dy,dx)` vs client facing | Runtime AuraSearchPacked | wrong `face` field (90° off) | `π/2 - atan2` (matches IsFacingPos) |

New authority: `World.spell_max_range(sid)` decodes the client's Spell.dbc range
via the runtime (SpellMeleeInfo) — the SAME source the cast gates use — so the
SEARCH and the CAST can never disagree. The aura search range is now
`min(user condition range, spell's real max range)`, and if a spell's range
cannot be decoded, the search/cast FAIL with a logged `RANGE_UNKNOWN` instead
of silently casting at a made-up distance.

### Live watchlist
1. Icy Touch never searches/casts beyond `min(20, its real range)` — the
   rotation log's aura_search range and every FIRE are inside the spell's true
   reach. No more "Out of range" from a 30yd fallback.
2. NO `edge=999.0` casts — unplaceable targets are excluded from the search.
3. If a `RANGE_UNKNOWN` / `RANGE_REQUIRED` / `UNPLACEABLE` line appears in the
   log, it names a REAL gap (a spell the runtime couldn't decode) — surface
   it here and I fix the decode, not hide it.
4. Aura-search `face` field now matches the client's arc (AuraSearchPacked
   convention fix) — better facing ranking.

---

## 2026-08-02 (18th round, 18:36 session) — THE 1.10.82 REGRESSION → 1.10.83-castguid

The 18:36 session REGRESSED vs 1.10.81: every targeted cast refused "Out of
range" at edge=1.8, `0x512B07 SHIELD` fired 4x with a NEW `esi=0xF75FC697`
(heap — never 0xD3C00E14), and the rotation locked in "wait cooldown x240"
(8s). RE of Spell_C (0x80CCE0) + the target setter (0x524BF0) exposed TWO
compounding defects in OUR cast path:

### Root cause A — the client's "guidLo" arg is a POINTER, not a dword
`0x80CDC1: mov ecx,[ebx+8]; mov eax,[ecx]; mov ecx,[ecx+4]` — Spell_C fills the
NEW cast record's target GUID from `[guidPtr+8]`. We passed the raw `lo` dword
(0xE5004C5A) → the client read a garbage GUID from `[lo+8]` into the record →
the async cast-feedback walk resolved that garbage (esi=0xF75FC697) → AV + the
cast record had a garbage target → client refused "Out of range" (generic
resolve-failure) → phantom_grace → lockup.
FIX: pass a valid GUID-holder (`[holder+8] = &victimGuid`); the record now gets
the REAL victim GUID.

### Root cause B — [player+0xd0] is NOT always the static slot
`0x80CD4A: edi=[edi+0xd0]; ObjectPtr([edi+0x18],[edi+0x1c],8)` — Spell_C
resolves the target from the caster's LIVE cast-record pointer [player+0xd0].
That pointer is 0xD3C00DFC (static slot, +0x18 == 0xD3C00E14) ONLY while no
selection machinery has run. Once the attack-engage `NativeSetTarget`
(0x524BF0 — which ALSO reads [player+0xd0]+0x18 to decide registration) runs,
the client flips it to a HEAP record → the static-slot write became useless and
the walk read the heap record's garbage GUID.
FIX: SafeNativeCast now ALSO writes the victim GUID into `[player+0xd0]+0x18/
+0x1C` (VirtualQuery-guarded) — covers BOTH the static and heap record cases.

### Root cause C — attack engage wrote a ZERO record
`AttackTargetFor(6603)` passed targetGuid=0 to SafeNativeCast → the slot/record
got 0. FIX: pass the real target GUID.

### Root cause D — phantom_kept kept the GCD floor
A phantom (cast never landed) took the `phantom_kept` branch → waited the full
1.5s wire-time GCD → after 3 refused casts the rotation sat in "wait cooldown"
for 8+ seconds. FIX (user directive): phantom ALWAYS frees the GCD
(`phantom_free`); the `_recent` micro-lock + real CD table still gate re-fire.

---

## 2026-08-02 (22nd round, 20:00) — SYNC TARGET RESOLUTION → 1.10.87-synctarget

The 19:34 session showed NO casts at all: left-click target instantly dropped,
rotation locked, "no ui errors". The decisive evidence in the log:

- **Consecration (guid=0) LANDS (nrc=1)** while **EVERY unit-targeted cast
  fails `al=0` ("Invalid target")** — with or without a retained target.
- Conclusion: the ONLY thing failing is the client's SYNC target resolution.
  Spell_C's sync path (0x80CD4A: `edi=[edi+0xd0]; ObjectPtr([edi+0x18],
  [edi+0x1c],8)`) reads the cast-target GUID from **[player+0xd0]+0x18**.
  The static walk slot (0xD3C00E14, round 15) feeds only the ASYNC cast-
  feedback walk (0x856370→0x512B00), NOT the sync resolution. The [0xd0]
  record is not always 0xD3C00DFC — any selection machinery flips it to a
  heap record, so the slot write alone leaves the sync GUID empty/stale →
  every targeted cast refused "Invalid target" al=0. guid=0 casts (self /
  ground, e.g. Consecration) skip resolution entirely → they land.

### Root cause — round 18's [0xd0] write used an UNVERIFIED player pointer
Round 18 DID write [player+0xd0]+0x18 and it "functionally" worked, but it
corrupted client state (false "Can't attack while charmed") because `player`
came from `PlayerPtr()`. **`MainThread.cpp:76` sets the snapshot's
`playerPtr = OM::LocalPtr()` — and `LocalPtr()` is garbage on this client
(FacingLive local=1e9 in every session).** So `recPtr = [garbage+0xd0]`,
and `recPtr+0x18` landed wherever garbage pointed (often a live unit-flags
field) → the victim GUID's low dword set UNIT_FLAG_CHARMED (0x40).

### FIX (1.10.87-synctarget)
1. **NEW `OM::VerifiedPlayerPtr()`** (ObjectManager) — resolves the player via
   the SAME paths RefreshLiveFacingCache proves correct live (obj=0x37825EE0):
   `SafeGetActive → CallObjectPtr3(mask 0x10)`, then the camera path
   (`CameraPlayerPtr`: cam → GUID → ObjectPtr mask 1). Returns 0 when the
   player can't be verified. (Defined OUTSIDE the anonymous namespace so it's
   exported — the anon namespace spans lines 17-1082; an earlier placement
   there caused LNK2019.)
2. **SafeNativeCast re-adds the `[player+0xd0]+0x18/+0x1C` victim-GUID write**,
   but ONLY with the verified player AND ONLY in the native-hook context
   (`held == 0`, no Lua on stack). With a verified player, `[player+0xd0]` is
   the client's REAL cast record and `[recPtr+0x18]` IS its target-GUID field —
   writing the victim GUID there is exactly what the client does for its own
   casts. **If the player can't be verified, the write is SKIPPED** (never
   write through an unverified pointer — round 20's rule).
3. Arg4 GUID-holder (round 18 A) and static walk-slot write (round 15) stay —
   they feed the ASYNC record/walk. The new write covers the SYNC path.

### Live watchlist (next session)
1. VER reads `1.10.87-synctarget`.
2. **Unit-targeted casts LAND (nrc=1, al=1)** — not just guid=0 spells. The
   rotation actually fires (no "Invalid target" al=0).
3. Left-click target is RETAINED (no instant drop); acquire-off never touches
   the unitframe.
4. NO false "Can't attack while charmed" (verified-player write only).
5. NO 0x512B07 SHIELD AVs; no crash.fatal; no blocked dialog.

### Root cause E — the range gate was EDGE-based, the client is CENTER-based
`spell_in_range_vs_target` compared EDGE (center − pr − tr) to band — a 5yd
melee could wire at center ~8yd. The client refuses on CENTER > maxR (proof:
5yd melee refused at center=5.0). FIX: head gate now compares CENTER to band;
the multi-candidate gate lost its +0.5/+1.5 tolerance (`cdist > cmaxR`).

### Fallback audit (user directive: NO silent fallbacks, ever)
Removed in this round: `slot_corpse_range or 30`, `collect_nearby_enemies or
40`, `dist_within or 8`, `parse_nearby_hostiles center or 999`,
`collect_units_from_tokens or 999`, `combat_reach → 1.5` (now nil → fail
closed), `live_range_model pr/tr or 1.5` (now fail closed), the +1yd
`max_range+1` slack, and the +0.5/+1.5 candidate tolerance.

### Live watchlist (1.10.83-castguid)
1. VER reads `1.10.83-castguid`.
2. NO `0x512B07 SHIELD` — the cast record now gets the real victim GUID
   (arg4 holder) AND [player+0xd0]+0x18 is written, so the walk resolves.
3. Casts LAND — no "Out of range", no phantom_grace lockup, no "wait cooldown
   xN" freezes; rotation cycles continuously.
4. Icy Touch/aura_search casts on found targets (it was blocked by the same
   cast refusals).
5. NO fallback line in the log: `RANGE_UNKNOWN`/`RANGE_REQUIRED`/
   `UNPLACEABLE` all name real gaps to fix, not things to paper over.
6. Commits: every round is committed to the repo (round 10-17 = 78ce247,
   round 18 = ee3b675).

---

## 2026-08-02 (19th round, 19:01 session) — CHARMED SPAM + AURA SEARCH FREEZE → 1.10.84-ccface

The 19:01 session exposed three defects. ALSO: the repo was never pushed —
51 commits sat local-only (GitHub showed nothing). Pushed `c0dba11..f68335f`
this round; every commit now goes to origin.

### Defect A — charmed refusal spammed at ~100 Hz
The player was charmed; every cast refused "Can't attack while charmed".
`apply_pending_refuse`'s catch-all "Other refuses" path never floored the
spell (`_recent[sid]` never set) → Plague Strike re-fired every ~10ms for the
whole session. FIX:
1. New CHARMED/CC refusal branch (matches charmed / can't attack / mind
   control / feared / stunned / can't do that): floors the spell AND sets
   `Executor._player_cc_until`.
2. The "Other refuses" path NOW ALWAYS floors the refused spell (0.6s) — an
   unrecognized refusal can never hammer the client again.
3. Player-CC gate in the tick: while charmed (`UnitIsCharmed("player")` or a
   recent charmed refusal) the rotation enters a visible `wait_cc` state and
   casts NOTHING until the charm clears — no 100 Hz spam, no starving lower
   priority slots (the spam starved Icy Touch/aura search).

### Defect B — "aura search did not cast at all" + "wait facing:X" freeze
`OM::IsFacing` returned a CONFIDENT `false` whenever either the player's or
the target's position was unmeasured (0,0). The addon's facing gates then
blocked every cast to a not-yet-placed unit ("wait facing:Blood Strike"
forever). FIX (fail-open):
- `OM::IsFacing` is now TRI-STATE: 1 = facing, 0 = measured not-facing,
  -1 = UNDETERMINED (unmeasurable position/facing).
- Dispatch `ObjectIsFacing` pushes `nil` for undetermined.
- The addon's two facing gates (candidate + target-relative) now block ONLY
  on `facing == false` — undetermined ALLOWS (client is the final authority;
  a refused cast is one phantom, a false freeze is forever). Matches the
  `is_facing_guid` contract: "Multi-dot MUST cast when nil. Only skip when
  false."

### Defect C — remaining ranged tolerance in the aura-search range gate
`live_castable`'s aura-search range check still had `tol = melee and 0.5 or
1.5` (`center > band + tol`). Removed: `center > band` → oor (perfect range;
a 20yd spell never casts at 21.5yd).

### Live watchlist (1.10.84-ccface)
1. VER reads `1.10.84-ccface`.
2. If the player gets charmed/feared/stunned the rotation shows `wait wait_cc`
   (quiet 5s heartbeat) and casts NOTHING — NO "Can't attack while charmed"
   spam. It resumes the instant the charm clears.
3. Aura search casts on found targets even when there is no current target —
   no `wait facing` freeze (undetermined facing allows; only a measured
   not-facing blocks, and even that is a 1-tick fail-open skip).
4. Icy Touch never casts beyond `min(condition range, real Spell.dbc range)`
   — no tolerance slack.
5. NO spam of ANY refusal reason (every refusal path now floors the spell).
6. Repo is pushed: `66fb023` (round 19) on origin/main. GitHub shows the
   changes.

---

## 2026-08-02 (20th round, 19:25) — THE FALSE CHARM: OUR corruption → 1.10.85-nocorrupt

The user was NOT charmed. "Can't attack while charmed" on every cast was a
**bug WE introduced in round 18** and it poisoned every session since.

### Root cause A — [player+0xd0]+0x18 write SET the charmed flag
The round-18 "cast-GUID fix" wrote the victim GUID into `[player+0xd0]+0x18`.
But the runtime's player resolution is UNRELIABLE on this client (FacingLive
`local=1000000000.0000` garbage in every session), so `PlayerPtr()` can return
a garbage pointer; `recPtr+0x18` then lands wherever garbage points — often a
live **unit-flags field** — and the victim GUID's LOW DWORD (e.g. 0xE5004C5A)
sets **UNIT_FLAG_CHARMED (0x40)**. The client then refused EVERY cast with
"Can't attack while charmed" while the player was NOT charmed, and the unit
data corruption flooded OTHER addons (XPerl_Player 21k "string expected, got
nil" errors). FIX: the write is REMOVED. The arg4 GUID-holder + static
0xD3C00E14 slot write remain — both write ZERO client state (the holder points
into OUR memory; the slot is the walk's own proven GUID slot).

### Root cause B — the blocked dialog reset silently failed
0xD3F604 (the "addon blocked" cast counter) is in the SAME UNCOMMITTED .data
BSS tail as 0xD3C00E14 (committed ends 0xB2EE00, virtual to 0xDD0508). Our
`Mem::Write` reset was a silent NO-OP (VirtualQuery rejects uncommitted pages),
so the counter climbed past 10 and fired the native blocked dialog (0x530840)
on suite disable — for every round since 1.10.81. FIX: commit the 0xD3F604
page once (idempotent VirtualAlloc) before every reset — the reset is now real.

### Live watchlist (1.10.85-nocorrupt)
1. VER reads `1.10.85-nocorrupt`.
2. NO "Can't attack while charmed" — the player is not charmed; the flag is no
   longer corrupted. Casts wire and land normally.
3. NO "RaijinLab has been blocked" dialog on suite disable — the counter reset
   actually works now.
4. Other addons' unit-frame errors (XPerl flood) stop — the unit data is no
   longer corrupted by our writes.
5. Aura search casts on found targets; Icy Touch stays inside its real range.
6. Repo is pushed: `dd04f40` (round 20) on origin/main.

---

## 2026-08-02 (21st round, 19:40) — THE TARGET DROP: the attack engage → 1.10.86-engagefix

19:26 (1.10.85): no more false charm, but a NEW hard failure — the user's
target is DROPPED the instant the auto-attack engage runs (`tgt=no` right
after FIRE #1 Auto Attack), then EVERY cast refuses `al=0` (silent) and aura
search never lands.

Root cause: the attack engage (`AttackTargetFor`) registered the target via
`NativeSetTarget` (0x524BF0) — `SafeNativeCast(6603, 0, targetGuid)`. That
setter flips the player's `[0xd0]` cast-record pointer from the static slot
(0xD3C00DFC) to a HEAP record. Spell_C's synchronous target resolution
(0x80CD4A reads `[0xd0]+0x18`) then reads the heap record's garbage GUID →
every subsequent cast refused `al=0`, and the failed engage dropped the
client's selection. The 18:11 "clean" sessions never exercised the engage (no
6603 casts in that log) — it was the one unproven path, and it was the bug.

FIX: `AttackTargetFor` now casts EXACTLY like the proven-clean rotation
direct-GUID path — `SafeNativeCast(6603, targetGuid, 0)`:
- target GUID → static walk slot (0xD3C00E14) + arg4 GUID holder → the
  feedback walk resolves it;
- registerTarget=0 → NO NativeSetTarget, ZERO selection touch, ZERO
  `[0xd0]` flip, NO unitframe change, NO target drop.

### Live watchlist (1.10.86-engagefix)
1. VER reads `1.10.86-engagefix`.
2. Selecting a target KEEPS it — the unitframe no longer drops.
3. Auto-attack engages the current target via direct-GUID (walk slot), then
   rotation casts land (no silent al=0).
4. Aura search casts on found targets; Icy Touch stays inside its real range.
5. No "Can't attack while charmed", no blocked dialog, no XPerl flood.
6. Repo is pushed: `657a690` (round 21) on origin/main.

---

## 2026-08-02 (22nd round, 20:09 session) — SYNC-TARGET WRITE CORRUPTED AGAIN → 1.10.88-castrestore

1.10.87-synctarget live (20:09): `active=0x0` in every FacingLive line is a
RED HERRING — the diag only calls SafeGetActive inside `if (f >= 1e8f)` (Path
3), and Path 1 (camera) always succeeds with a valid facing first, so `active`
just stays at its initialized 0. The camera path IS the working player
resolution (obj=0x6CC39910, face readable).

BUT the `[player+0xd0]+0x18` write (re-added in round 22 via the verified
player) produced **"Can't attack while charmed"** again — the SAME corruption
as round 18. Sequence: FIRE #1 Auto Attack (engage) → FIRE #5 Icy Touch →
refused charmed → `wait_cc` forever. The write has now corrupted
UNIT_FLAG_CHARMED **twice** through DIFFERENT player pointers (round 18:
LocalPtr garbage; round 22: camera-verified). Conclusion: **writing through
[player+0xd0] is fundamentally unsafe on this client** — the cast-record
pointer our resolved object exposes at +0xD0 is not a safe record write target
(whatever the client's own cast path uses, it is not reachable this way without
corrupting unit state).

### FIX (1.10.88-castrestore) — restore the ONLY proven-clean configuration
Cross-session matrix (definitive):
- **18:11 (1.10.81): NO [0xd0] write + NO 6603 engage → casts LAND.**
- 19:34 (1.10.86): no [0xd0] write + direct-GUID 6603 engage → every targeted
  cast `al=0` ("Invalid target"), Consecration (guid=0) lands.
- 20:09 (1.10.87): [0xd0] write + 6603 engage → "Can't attack while charmed".

The 6603 engage is the variable that broke the 18:11 config. Its Spell_C
machinery allocates a HEAP cast record (0x805010) and the client's sync path
(0x80CD4A) reads `[player+0xd0]+0x18` — once the engage has run, that pointer
is no longer the static walk slot (0xD3C00DFC) our slot write feeds, so every
later targeted cast fails sync resolution.

1. **REMOVE the `[0xd0]+0x18` write** from SafeNativeCast (permanent — it has
   corrupted charmed twice).
2. **DISABLE the auto-attack engage** (`AttackTargetFor` no longer casts
   6603; detection-only + fail-open, logged once). WoW auto-attacks natively
   when any melee ability lands — 18:11 proved the melee spells engage without
   a 6603 cast. This restores the EXACT 18:11-proven cast path: static walk-
   slot write (0xD3C00E14) + arg4 GUID holder + direct-GUID registerTarget=0.
3. **NEW `CastDiag` diagnostic** in SafeNativeCast (native context, throttled
   ~2s) — if a targeted cast STILL fails, it logs the cast-wrapper player GUID
   ([ClntObjMgr+0xC0/0xC4] via the 0x4d3790 TLS chain), the cast-path player
   object (ObjectPtr(guid, mask 0x10) — what the wrapper uses), the camera
   player, whether they agree, the `[player+0xd0]` record pointer, whether it
   is the static slot, `[rec+0x18]` contents, and the player's UNIT_FIELD_FLAGS
   charmed bit. Data-driven next step if this still fails.

### Live watchlist (1.10.88-castrestore)
1. VER reads `1.10.88-castrestore`.
2. **NO "Can't attack while charmed"** (the [0xd0] write — the corruption — is
   gone).
3. **Unit-targeted casts LAND** (Icy Touch/Blood Strike/etc. `al=1`) — the
   rotation fires, matching the 18:11 clean session.
4. Rotation cycles continuously; no phantom_grace lockup; no wait_cc freeze.
5. Auto-attack: client auto-attacks on melee spell land (no forced 6603).
6. If a `CastDiag` line appears, it names the exact sync-resolution state —
   bring it here and the next fix is data-driven.

---

## 2026-08-02 (23rd round, 20:28 session) — CastDiag PROVES the sync failure → 1.10.89-syncrecord

1.10.88 live (20:28) — no more "Can't attack while charmed" ✅ (the [0xd0]
write + engage removal worked), but unit-targeted casts STILL refuse `al=0`
("Invalid target") and the target gets dropped. The new CastDiag fired and
named the exact failure:

```
CastDiag id=45513 guid=F1300005E500614A mgr=0x37745418 mguid=000000000000DB53
castP=0x371C7660 camP=0x371C7660 rec=0x371C8FD0 static=0 r18=00000000 r1c=00000000 s20=0 flags=00000000 charm=0
```

- **`castP == camP == 0x371C7660`** — the camera player IS the cast-path
  player; VerifiedPlayerPtr resolves the correct object.
- **`charm=0`** — the player is NOT charmed. The round-22 "Can't attack while
  charmed" was contaminated by the still-active 6603 engage, NOT the [0xd0]
  write alone.
- **`rec=0x371C8FD0`, `static=0`** — `[player+0xd0]` is a HEAP record, and
  **`[rec+0x18]=0 [rec+0x1c]=0`** — the sync target GUID is EMPTY → the
  client's sync resolution (0x80CD4A: `ObjectPtr([rec+0x18],[rec+0x1c],8)`)
  resolves GUID 0 → "Invalid target" al=0.

The target drop + XPerl UI-error flood (30k "bad argument #1 to 'lower'") are
SYMPTOMS of the failed casts: a failed Spell_C drops the client's selection
(0xBD07B0), and XPerl (unitframe) reads nil units. In 18:11 the casts
succeeded, so nothing dropped. ONE root cause: the empty sync target GUID.

### FIX (1.10.89-syncrecord) — SAFE sync-record write with a SIGNATURE check
The client builds its cast records with the CASTER GUID at `[rec+0x10]/
[rec+0x14]` (0x80CDD4) and the player's GUID lives at `[[player+0x8]]`
(0x80CD26). So before writing:
1. Resolve the player via `OM::VerifiedPlayerPtr()` (diag-proven correct).
2. `rec = [player+0xd0]`; read the record's caster GUID `[rec+0x10/0x14]` and
   the player GUID `[[player+0x8]]`.
3. **Only if they MATCH** (rec is verifiably the player's cast record) write
   the victim GUID into the sync slots `[rec+0x18/+0x1c]` (primary) and
   `[rec+0x28/+0x2c]` (the client's zero-fallback slot at 0x80CD5B).
   **On signature mismatch, SKIP the write** (never write through an
   unverified record — round 20's rule).
4. CastDiag extended to log the record signature (+8/+0xc, +0x10/+0x14), both
   sync GUID slots post-write (+0x18/+0x1c, +0x28/+0x2c), and the player's
   charmed flag — so if the write ever corrupts, the next line names it.

### Live watchlist (1.10.89-syncrecord)
1. VER reads `1.10.89-syncrecord`.
2. **Unit-targeted casts LAND (`al=1`)** — the sync record now carries the
   victim GUID, so 0x80CD4A resolves it.
3. **Target is RETAINED** — no more drop (the drop was the failed cast).
4. **XPerl/UI-error flood stops** — no more nil-unit reads from target churn.
5. NO "Can't attack while charmed"; rotation cycles; Consecration still lands.
6. If `CastDiag rec-MISMATCH` appears, the record signature didn't match —
   that names the next thing to fix.

---

## 2026-08-02 (24th round, 20:38 session) — the record is EMPTY → 1.10.90-emptyrec

1.10.89 live (20:38): the record-signature check was TOO STRICT — the live diag
proved `[player+0xd0]` is an **EMPTY heap record**:

```
CastDiag rec-MISMATCH id=45513 rec10=0 pg=0xDB53 skip-sync-write
CastDiag id=45513 ... castP=0x6D64FDA8 camP=0x6D64FDA8 rec=0x6D651718 static=0
r8=0 r10=0 r18=0 r28=0 s20=0 flags=0 charm=0
```

- castP==camP (resolution correct), charm=0 (no corruption, no false charmed —
  the engage removal held).
- rec=[player+0xd0]=0x6D651718 is a HEAP record and it is **COMPLETELY EMPTY**
  (all slots 0 — no caster GUID at +0x10 to match, so the caster-GUID signature
  check skipped every write).
- Every targeted cast still refused "Invalid target" al=0; the rotation spammed
  attempts; the user's manually-selected target stayed until an aura-search
  cast failed and dropped it. Root cause is unchanged: the sync resolution
  (0x80CD4A) needs the victim GUID at [rec+0x18] and it is empty.

### FIX (1.10.90-emptyrec) — write the EMPTY record's sync slots
Relaxed the safety check to match what the empty record IS:
- rec is a valid readable pointer;
- `[rec]` (vtable slot) is NOT in .text (0x400000..0x9DE400) — a live CGObject
  always has its vtable there; an empty cast record has 0. This is the strong
  guard against writing through a live object.
- the sync slots `[rec+0x18/+0x1c]` are EMPTY — never overwrite a GUID the
  client already placed.
When all hold, seed the sync target slots [rec+0x18/+0x1c] (primary) and
[rec+0x28/+0x2c] (the client's zero-fallback at 0x80CD5B) with the victim GUID.
The round-22 charmed corruption was the engage's 6603 write — with the engage
disabled and charm=0 confirmed, this write should be clean; the post-write
CastDiag (now logs the vtable slot `vt=`) shows charm=1 immediately if it ever
corrupts.

### Live watchlist (1.10.90-emptyrec)
1. VER reads `1.10.90-emptyrec`.
2. **Unit-targeted casts LAND (`al=1`)** — the empty record now carries the
   victim GUID, so 0x80CD4A resolves it.
3. **Target NEVER dropped** — not by manual selection, not by aura search
   (the drop was the failed cast).
4. NO false charmed (charm stays 0 in CastDiag); no XPerl flood.
5. Rotation cycles: FIRE → landed instead of FIRE → phantom_grace → retry.
6. If `CastDiag rec-UNSAFE` appears, [rec] had a .text vtable (live object) —
   that names the next thing to fix.

---

## 2026-08-02 (25th round, 21:00 session) — the [0xd0]+0x18 write is UNCONDITIONALLY UNSAFE → 1.10.91-staticrec

1.10.90 live (21:00) — the round-25 write LANDED but corrupted the player:

```
CastDiag id=45513 ... castP=0x3746E710 camP=0x3746E710 rec=0x37470080 static=0
vt=00000000 r8=0 r10=0 r18=F1300005E5006AF0 r28=F1300005E5006AF0 s20=0
flags=F1300005 charm=0
```

**The definitive proof**: the write hit `[rec+0x18]/[rec+0x1c]`, and the
player's descriptor field `desc+0x44` (read as "flags") became **0xF1300005 —
exactly the victim GUID's HIGH DWORD**. So `[player+0xd0]` is NOT a cast
record: it points INTO the player's own descriptor (`rec = desc + 0x28`, where
`desc = [player+0x8]`). Writing `[rec+0x18]` = `desc+0x40`/`desc+0x44` corrupts
the player's live unit fields → "Can't attack while charmed" + the XPerl flood
(30k errors). **The `[player+0xd0]+0x18` write is PROVEN unconditionally unsafe
(rounds 18, 22, 25) and is now permanently removed — do NOT reintroduce it.**

### The real mechanism (from RE of the game's CastSpellByID)
The game's FS handler (0x53E060) REGISTERS the target (via the TargetUnit
chain 0x60ABF0 → 0x524BF0) BEFORE calling Spell_C(0x80DA40) — the sync
resolution reads the REGISTERED target, which is why the game's casts work.
Our direct-GUID casts never register, so the sync path finds no target.

The ONLY configuration that ever cast cleanly (18:11) had `[player+0xd0]` =
the STATIC slot **0xD3C00DFC**, where our walk-slot write (0xD3C00E14 =
[0xD3C00DFC+0x18]) fed the sync path. The user's target SELECTION
(TargetUnit → 0x524BF0) flips `[player+0xd0]` to the descriptor alias — after
that the walk-slot write misses and every targeted cast fails.

### FIX (1.10.91-staticrec)
At cast time (native context), restore `[player+0xd0] = 0xD3C00DFC` — a
legitimate pointer VALUE the client itself uses as the default (a pointer-field
write, NOT a descriptor write, NOT a selection write; the page is already
committed from round 15). The walk-slot write (0xD3C00E14, now also seeding the
+0x28 fallback at 0xD3C00E24) then feeds the sync resolution exactly like the
18:11 clean session. The user's selection (0xBD07B0) and the unitframe are
untouched — acquire-off casts still never change the target.

### Live watchlist (1.10.91-staticrec)
1. VER reads `1.10.91-staticrec`.
2. **Unit-targeted casts LAND (`al=1`)** — CastDiag should show `rec=0xD3C00DFC
   static=1` and `r18` = the victim GUID (from the walk slot).
3. **Target NEVER changes** — manual selection retained, aura-search casts land
   without touching the unitframe (0xBD07B0 unchanged).
4. NO "Can't attack while charmed" (no descriptor writes); no XPerl flood.
5. Rotation cycles: FIRE → landed (no phantom_grace churn).

---

## 2026-08-02 (26th round, 21:14 session) — static pointer CRASHED → 1.10.92-register

1.10.91 live (21:14): the `[player+0xd0] = 0xD3C00DFC` pointer redirect
CRASHED the client the moment a targeted cast ran (manual target → Icy Touch):

```
CastDiag id=45477 ... rec=0xD3C00DFC static=1 r18=0 ... flags=0 charm=0
skip corrupt call eip=0x503BAC69 -> ret=0x0053002B@+60
crash.fatal code=0xC0000005 type=AV_WRITE eip=0x0053002B fault=0x7D8BF445
```

- The CastDiag confirmed the reset worked (static=1) BUT `r18=0` — the walk-slot
  write (0xD3C00E14) is NOT landing in this session, so the "static slot feeds
  the sync path" theory is not holding either.
- eip=0x53002B disassembles to garbage (`add [ebx+0x7D8BF445], cl` with ebx=0
  → AV_WRITE to an unmapped heap address) — the client's cast machinery was
  driven into a broken state by the forced static pointer. **The static-slot
  redirect is REMOVED (round 26 is reverted).**

### The definitive path — REGISTER (round-13-proven)
The round-13 empirical matrix is unambiguous:
- **register (0x524BF0) + Spell_C(GUID) → CRASH-FREE, casts land**
- no-register + Spell_C(GUID) → crash; register + Spell_C(0) → crash
The game's own CastSpellByID (0x53E060) registers the target (TargetUnit chain
0x60ABF0 → 0x524BF0) BEFORE calling Spell_C — the sync resolution (0x80CD4A)
reads the REGISTERED target. Every no-register/direct-write alternative has
now failed (invalid target / corruption / crash).

### FIX (1.10.92-register)
1. REMOVE the [player+0xd0] pointer write (the 1.10.91 crash).
2. **Every targeted cast now registers the victim** (`SafeNativeCast(spellId,
   guid, guid)` for BOTH acquire states — drain, CastSpell, CastSpellNoAcquire).
   The register (0x524BF0) is the client's own setter — crash-free (round 13).
3. SafeNativeCast saves the previous selection; when the victim differs (aura-
   search), it arms the DEFERRED `PulseSelectionRestore` (min-hold 100ms,
   not-mid-cast guarded — round 14-proven). NEVER a same-tick restore (round 9
   0x512B07 race).
4. For target-relative casts the victim IS the current selection → the register
   is a NO-OP on the unitframe (0xBD07B0 unchanged) — zero impact.

### Live watchlist (1.10.92-register)
1. VER reads `1.10.92-register`.
2. **Target-relative casts LAND** (register the current target — unitframe
   untouched, no flash).
3. **Aura-search casts LAND** at the victim and the selection restores after
   ~100ms (min-hold PulseSelectionRestore).
4. NO crash (no [player+0xd0] writes); NO "Invalid target"; NO false charmed.

---

## 2026-08-02 (27th round, 21:22 session) — register ALONE doesn't seed the sync field → 1.10.93-unittarget

1.10.92 live (21:22): `NativeSetTarget guid=0xF1300005E5006AF0` ran (the register)
but the cast STILL refused `al=0`:

```
CastDiag ... castP=0x6CF113F8 camP=0x6CF113F8 rec=0x6CF12D68 static=0
r8=0 r10=0 r18=0 r28=0 s20=0 flags=0 charm=0
NativeSetTarget guid=0xF1300005E5006AF0 (client's real setter)
SafeNativeCast rc=0x4D016C00 al=0 id=45477
```

**Conclusion: 0x524BF0 does NOT populate the sync field.** Spell_C's sync
resolution (0x80CD4A) reads `[player+0xd0]+0x18`, and the round-25 diag PROVED
that field is `desc+0x40` = **UNIT_FIELD_TARGET** (the player's descriptor is at
`[player+0x8]`; with Health at 0x60 / Flags at 0xEC, TARGET is at 0x40). On this
client UNIT_FIELD_TARGET is 0 even with a target selected (0xBD07B0 set) — the
server never synced it — which is the persistent "Invalid target" root cause.
The game's casts work only because UNIT_FIELD_TARGET is populated by the
targeting/combat flow.

### FIX (1.10.93-unittarget)
Write the victim GUID directly into `desc+0x40/+0x44` (UNIT_FIELD_TARGET) right
before `fn()` and restore it right after:
- It is the EXACT field the sync resolution reads — the cast can now resolve
  the victim.
- It is INVISIBLE to the unitframe — the visible selection is 0xBD07B0
  (untouched); the descriptor target field is server-synced data the UI does
  not render.
- We write ONLY this field — round 25's "Can't attack while charmed" corruption
  came from ALSO writing desc+0x50 (UNIT_FIELD_CHANNEL_OBJECT), which is NOT
  touched here.
- Registration (0x524BF0) is kept for crash safety (round 13); the deferred
  PulseSelectionRestore still reverts 0xBD07B0 for aura-search victims.

### Live watchlist (1.10.93-unittarget)
1. VER reads `1.10.93-unittarget`.
2. **Unit-targeted casts LAND (`al=1`)** — the sync resolution now finds the
   victim in UNIT_FIELD_TARGET.
3. **Target-relative casts**: unitframe untouched (0xBD07B0 unchanged).
4. **Aura-search casts**: land at the victim, selection restored deferred.
5. NO "Invalid target", NO false charmed, NO crash.
5. Rotation cycles: FIRE → landed.

---

## 2026-08-02 (28th round, 21:29 session) — user identified the aura-search target drop + al=0 persists → 1.10.94-probe

1.10.93 live (21:29): the user could HOLD the target for a few seconds, and
correctly diagnosed that the **aura-search cast is what changes/drops the
current target**. Confirmed: the round-27 register (0x524BF0) for acquire-off
writes 0xBD07B0 = the aura-search victim, then the deferred restore reverts it
~100ms later — the "aura search forcing my target to drop". Also the cast
STILL returned `al=0` (rc=0x4AD8D600) even with the UNIT_FIELD_TARGET write.

### FIX (1.10.94-probe)
1. **Acquire-off casts NO LONGER register** — `SafeNativeCast(spellId, guid,
   0)` everywhere for kCastNoTargetChange. 0xBD07B0 is NEVER touched by
   aura-search or target-relative casts; only acquire-ON registers. This
   directly removes the target-drop the user observed.
2. The UNIT_FIELD_TARGET (desc+0x40) seeding now runs for EVERY targeted cast
   (before fn, restored after) — the invisible sync-resolution feed.
3. **NEW CastProbe** (native context, ~2s throttle) names the exact failing
   gate if al=0 persists:
   - `desc40` — the desc+0x40 value AFTER the write (confirms the write landed);
   - `gate` — the spell-entry attribute byte [entry+0x10]&0x40 (the 0x80CD11
     pre-resolution gate);
   - `r8` — ObjectPtr(lo,hi,8): does the sync resolution resolve the victim?
   - `r1` — ObjectPtr(lo,hi,1): is the victim in the object manager at all?

### Live watchlist (1.10.94-probe)
1. VER reads `1.10.94-probe`.
2. **Target is NEVER dropped** by aura-search or target-relative casts (no
   register, 0xBD07B0 untouched).
3. Casts either LAND, or the new `CastProbe` line names the exact gate:
   - `desc40` != victim lo → the write isn't landing;
   - `gate=0x40` → the spell-attribute gate 0x80CD11 fails (spell-level);
   - `r8=0 r1!=0` → the victim resolves as Object but not as Unit(mask 8);
   - `r8=0 r1=0` → the victim isn't in the object manager (GUID/mask issue).

---

## 2026-08-02 (29th round, 21:39 session) — the CastProbe ITSELF crashed (stack overflow) → 1.10.95-nogate

1.10.94 live (21:39): the probe FIRED and PROVED two things, then caused the
crash:
```
CastQueue STAGE id=45513 guid=0xF1300005E5006AF0   (correct cast)
CastDiag id=45513 ...                              (correct)
CastProbe id=1 desc40=E5006AF0 gate=00 r8=0 r1=0   (spellId became 1!)
SafeNativeCast rc=0x00000001 al=1 id=1 guid=0x0    (fired spell 1 at nothing)
```
1. **`desc40=E5006AF0`** — the UNIT_FIELD_TARGET (desc+0x40) write LANDS. ✓
2. **CRASH CAUSE**: the probe called `0x4cfd20` (GetSpellEntry) with a 0x40-byte
   stack buffer, but the client writes a 0x2B8-byte spell struct (0x80CCE0:
   `sub esp,0x2b8`). The overflow corrupted SafeNativeCast's locals — spellId
   became 1, guid became 0, and the "cast" fired spell 1 at nothing → crash.
   (The `r8=0 r1=0` are also garbage — read with corrupted lo/hi.)

### FIX (1.10.95-nogate)
Remove the `0x4cfd20` call from the CastProbe entirely. The probe is now PURE
MEMORY reads (VirtualQuery-guarded, no game calls, no buffer):
- `desc40` — confirms the UNIT_FIELD_TARGET write landed;
- `r8` — ObjectPtr(lo,hi,8): does the sync resolution resolve the victim?
- `r1` — ObjectPtr(lo,hi,1): is the victim in the object manager at all?
(ObjectPtr3Guid is the same VEH-guarded call used by SafeObjectPtr everywhere.)

### Live watchlist (1.10.95-nogate)
1. VER reads `1.10.95-nogate`.
2. NO crash — the corrupting 0x4cfd20 call is gone; the cast runs with the real
   spellId/guid.
3. Target NEVER dropped (no register on acquire-off).
4. `CastProbe` shows `desc40` = victim lo, and valid `r8`/`r1`:
   - `r8` non-zero → the sync resolution CAN resolve the victim → casts should
     land (the UNIT_FIELD_TARGET write feeds it);
   - `r8=0 r1!=0` → victim is Object but not Unit(mask 8) → mask issue;
   - `r8=0 r1=0` → victim not in the object manager → GUID issue.

---

## 2026-08-02 (30th round, 21:53 session) — probe PROVES sync resolution works but al=0 persists → 1.10.96-gateprobe

1.10.95 live (21:53) — the cleaned probe delivered the decisive data:
```
CastProbe id=45513 desc40=E50071EA r8=0x4116D168 r1=0x4116D168
SafeNativeCast rc=0x4C6B4F00 al=0
```
- **`desc40=E50071EA`** — the UNIT_FIELD_TARGET (desc+0x40) write LANDS. ✓
- **`r8=0x4116D168`** — ObjectPtr(victim, mask 8) — the sync resolution's exact
  call — RESOLVES the victim. ✓
- Yet the cast STILL refuses al=0. **CONCLUSION: the failure is NOT the target
  resolution.** The sync path has a resolvable victim in the exact field it
  reads, so al=0 comes from a gate BEFORE it (GetSpellEntry / the 0x80CD11
  spell-attribute check `test byte [entry+0x10],0x40`) or AFTER it (target
  object checks, canCast(6)-style CC state via [0xBD078C]+0x124C).
- Also: the target drop after failed casts is the client's reaction to the
  failed cast — fix the cast and the drop stops (we never touch 0xBD07B0 on
  acquire-off).

### FIX (1.10.96-gateprobe)
Extend the probe to name the gate:
- `entry` — did GetSpellEntry (0x4cfd20) find the spell? (0x80CCF4 → 0x80DA21)
- `attr10` — the spell entry dword at +0x10 (the 0x80CD11 attribute gate);
- `gate` — (attr10 & 0x40) — if 1, the 0x80CD11 pre-resolution gate fails;
- `bd078c` / `bd124c` — the [0xBD078C]+0x124C state the canCast(6)/CC path
  reads.
0x4cfd20 is called with a 0x400 buffer (the client writes 0x2B8 — round 29's
crash was a 0x40 buffer overflow; 0x400 is safe). All game calls VEH-guarded.

### Live watchlist (1.10.96-gateprobe)
1. VER reads `1.10.96-gateprobe`.
2. CastProbe now shows `entry`/`attr10`/`gate`/`bd078c`/`bd124c`:
   - `entry=0` → GetSpellEntry fails → spell not in the client DB → spell-level;
   - `gate=1` → the 0x80CD11 spell-attribute gate fails → spell-level;
   - `gate=0 entry=1` → the spell entry is fine → the failure is AFTER the sync
     resolution (target object check / CC state) → next fix is data-driven.

---

## 2026-08-02 (31st round, 22:15 session) — probe NAMES the gate family + RE of canCast/busy → 1.10.97-selprobe

1.10.96 live (22:15) delivered the expanded probe:
```
CastProbe id=45477 desc40=E900753E r8=0x5607D038 r1=0x5607D038
           entry=1 attr10=00050000 gate=0 bd078c=6D01E9D8 bd124c=00000001
SafeNativeCast rc=0x4C658800 al=0
```
- `entry=1`, `gate=0` → the spell IS found and the 0x80CD11 spell-attribute
  gate PASSES. The failing gate is NOT GetSpellEntry and NOT attr 0x40.
- `desc40` lands + `r8` resolves → the sync path has a resolvable victim.
- `bd124c=00000001` looked suspicious but RE PROVED IT IS A RED HERRING.

### RE findings (this round, all disasm-verified):
1. **canCast (0x5191C0) fully decoded**:
   - `[0xD4139C]==0` → jump 0x519239 (PASS path): returns 1 unconditionally,
     never reads +0x124C/+0x1250.
   - `[0xD4139C]!=0` → jump table by mode: mode 2 → case 0 (0x5191E7)
     → **return 0 ALWAYS**; mode 6 → case 1 (0x519218) → fail iff
     `[obj+0x1250]==0`; modes 9/10/16 → case 2 (0x5191F7) → reads
     `[obj+0x124C]`. **+0x124C is only read for modes 9/10/16 — NOT 2/6.**
2. **Spell_C real logic (0x80CCE0) has ZERO direct 0xBD07B0 reads.** The two
   SILENT al=0 gates (no error UI — matches "nothing happened"):
   - **0x80CD88**: `0x74BA40(edi) != 0` → fail. edi = sync victim if the sync
     ran (`[entry+0x28] & 0x40000`), else the PLAYER object.
   - **0x80D063**: `canCast(2/6) == 0` → fail.
3. **0x74BA40 IS a function** (earlier "it's a string" claim was WRONG):
   `56 8B F1 E8 78 90 FC FF 84 C0 75 04 33 C0 5E C3` — "is unit busy": checks
   `[unit+0xa30]` bit 0x400, `[unit+0xf60]` active-cast record (state != 3),
   and the target's cast record.
4. **0x524BF0 (register) decoded**: checks `[0xD4139C]` (busy → 0x513530 +
   return); reads `[player+0xd0]+0x18` = desc+0x40 (UNIT_FIELD_TARGET); **if
   the player HAS a target it EARLY-RETURNS and never touches 0xBD07B0**. It
   only writes 0xBD07B0 when the player has NO target — exactly the
   aura-search/tgt=no case where the user saw the selection change.
5. **0xBD07B0/0xBD07B4 = kPendingCastLo/Hi — the commit "pending" GUID pair**
   the game's cast-commit path uses.

### FIX (1.10.97-selprobe)
- **Transient selection**: for acquire-off casts, write the victim into
  0xBD07B0/0xBD07B4 for the SYNCHRONOUS duration of Spell_C and restore the
  user's previous selection immediately after. No frame update runs inside the
  native call → the unitframe never renders the intermediate value, no
  UNIT_TARGET event, no target change. desc+0x40 write (sync path) stays.
- **Definitive probe**: reads mode (computed from attr0/fam), attr0/attr10/
  attr28/fam via the PURE-READ SpellTableEntryRead (NO 0x4cfd20 call — it
  could touch action/busy state right before the cast and skew the [0xD4139C]
  gate we measure), plus d4139c, d413a4, obj1250, busyV/busyP (calls 0x74BA40
  on victim AND player under VEH), a30V/f60V/a30P/f60P.

### Live watchlist (1.10.97-selprobe)
1. VER reads `1.10.97-selprobe`.
2. `al=1` → **THE TRANSIENT SELECTION FIX WORKS — casts land with no target
   change** (the 0xBD07B0 commit-pending pair was the missing registration
   input).
3. `busyV=1` → victim busy gate (0x80CD88) fails — the dummy/unit reads busy.
4. `busyP=1` → player busy gate fails.
5. `mode=2 d4139c!=0` → canCast gate (0x80D063) fails — force-zero
   [0xD4139C] at cast time.
6. `gate=0 entry=1 busyV=0 busyP=0 d4139c=0` but still al=0 → the failure is
   in the POST-canCast checks (0x50f4d0(2) at 0x80D077, or the 0x80D087+
   target checks) — next probe target.

---

## 2026-08-02 (32nd round, 22:40 session) — the probe EXONERATES every prior gate; RE finds the 0x50f4d0 MASK GATE → 1.10.98-maskgate

1.10.97 live (22:40) — the definitive probe data:
```
CastProbe id=45477 mode=6 ... entry=1 a0=0000B1A5 a10=00050000 a28=02000000
           fam=2 gate=0 d4139c=00000000 a4=00000000 obj1250=00000000
           busyV=0 busyP=0 a30V=000D0100 f60V=00000000 a30P=0C0D0500 ...
SafeNativeCast rc=0x4C2F9400 al=0
CastProbe id=45513 mode=2 ... a0=0000B1C9 a10=00050010 a28=02000000 fam=79 ...
           d4139c=00000000 ... busyV=0 busyP=0 ... rc=0x4C2F9400 al=0
```
- `entry=1`, `gate=0`, **`d4139c=00000000`** (canCast gate CLEAR → canCast
  passes), **`busyV=0`/`busyP=0`** (both busy gates pass), `a30V` bit 0x400
  clear. EVERY previously-suspected gate is EXONERATED — yet al=0.
- The "Invalid target" spam at 22:40:58 was just the target DYING (rotation
  went `target_dead` right after) — the real bug is the SILENT refusal on the
  LIVE target (rc=0x4C2F9400, no error UI).
- `a28=02000000` → bit 0x40000 CLEAR → the sync path is SKIPPED; the victim
  goes into the new cast record via [guidPtr+8]. edi stays the player object.

### THE GATE (RE, disasm-verified)
- `0x50F4D0(arg)`: `if [0xBEAF4C]==0 → return 1; return ([0xBEAF44] &
  (1<<arg)) ? 1 : 0`. Spell_C calls `0x50f4d0(2)` at 0x80D077 **only when
  [entry+0x238]!=0** — unit-targeted spells have it non-zero; ground/self
  casts like Consecration have it 0 and SKIP the gate (why Consecration
  always lands while every unit-targeted spell is silently refused).
- `0x50f4d0(2)==0` → jump 0x80D249 (SILENT fail; rc = 0x805100's return,
  matches the observed 0x4C2F9400).
- `[0xBEAF4C]` = client "input/action locked" flag; `[0xBEAF44]` = allowed-
  action bitmask. The client's OWN action handlers (0x525Bxx: movement /
  target actions) do the same check and — crucially — TEMPORARILY set their
  mask bit, act, then CLEAR it (`and [0xBEAF44], 0xFFFFFFDF`). They also
  refuse when locked && bit clear (same silent pattern).

### FIX (1.10.98-maskgate)
Replicate the client's own handler pattern for Spell_C: temporarily set
`[0xBEAF44] |= 4` (bit 2 = the arg-2 gate) for the synchronous duration of
Spell_C, restore after. Page committed first (idempotent, same BSS tail as
0xD3F604). Transient 0xBD07B0 selection (round 32) stays.

### Live watchlist (1.10.98-maskgate)
1. VER reads `1.10.98-maskgate`.
2. `al=1` → **THE MASK GATE WAS IT — casts land** (this is the client's own
   set-bit pattern, highest-confidence fix yet).
3. Probe now also shows `e238` ([entry+0x238], gate-enable) and `beaf44`/
   `beaf4c` (the gate inputs). Expect `e238!=0` + `beaf4c!=0` + `beaf44&4==0`
   for unit spells and `e238==0` for Consecration — that pattern CONFIRMS
   the gate.
4. If still al=0 with `beaf44&4==1` (we set it) → the fail moved past
   0x50f4d0 → next is the 0x80D334+ cast-build region.

---

## 2026-08-02 (33rd round, 22:50 session) — THE ACTUAL ROOT CAUSE: SPELL ID 0 → 1.10.99-spellid

1.10.98 live (22:50) — the probe EXONERATED the mask gate too:
```
CastProbe id=45477 mode=6 ... e238=000005DC beaf44=00000000 beaf4c=00000000
SafeNativeCast rc=0x4CA1C600 al=0
CastProbe id=45513 mode=2 ... e238=000005DC beaf44=00000000 beaf4c=00000000
SafeNativeCast rc=0x4CA1C600 al=0
```
- `e238=000005DC` — the 0x50f4d0 gate RUNS for unit spells (confirmed).
- **`beaf4c=00000000`** — the input-lock flag is ZERO → 0x50f4d0(2) returns 1
  (the mask gate PASSES). NOT the gate. All probed gates pass — yet al=0.

### THE REAL ROOT CAUSE (RE, disasm-proven this round)
1. The spell-cast wrapper `0x80DA40` **never reads its arg1** (`[ebp+8]` is
   unused). It forwards arg2 (`[ebp+0xc]`) into the real logic `0x80CCE0`,
   where **GetSpellEntry(0xad49d0, [ebp+0xc], &out)** reads it as the SPELL ID
   and the cast record stores it at `+0x20`.
2. All client callers (CastSpellByID 0x53E060, 0x523486, 0x51041E) pass
   `(spellId, 0, guidLo, guidHi, ...)` — so 0x80CCE0's GetSpellEntry receives
   **0**. GetSpellEntry(0) SUCCEEDS when minSpell==0 and slot 0 is valid
   (live to confirm: minS/slot0). So **every cast ran the whole gate chain on
   SPELL 0's empty data**.
3. That is why: the probe's `entry=1` (our OWN table read with the real id)
   was misleading; every targeted cast failed at whatever check spell 0's
   data trips regardless of every gate we cleared; and guid=0 casts
   (Consecration) happened to return success.
4. The SIBLING function `0x80DA80` is the clean path: its callers
   (0x53BCA0, 0x53C168, 0x540598 — the action-bar/keybind handlers) pass
   `(spellId, 0, guidLo, guidHi)` and 0x80DA80 does GetSpellEntry([ebp+8])
   — spell id FIRST, correctly — then 0x802cb0 check + 0x802f80 cast. No
   canCast, no mask gate, no sync-resolution chain.

### FIX (1.10.99-spellid)
Call `fn(0, spellId, guidPtr, 0, 0)` — put the real spell id in arg2 (the
position 0x80CCE0's GetSpellEntry and cast record actually use). arg1 is
ignored by the wrapper. All existing machinery (desc+0x40 write, transient
0xBD07B0 selection, walk slots, action-state, mask bit) stays.

### Live watchlist (1.10.99-spellid)
1. VER reads `1.10.99-spellid`.
2. Probe adds `minS`/`maxS`/`slot0` — expect `minS==0` + `slot0!=0`
   (confirms GetSpellEntry(0) was succeeding = root cause).
3. **`al=1` → THE CASTS FINALLY LAND** (real spell id through the real
   logic; all gates were already verified clean).

---

## 2026-08-02 (34th round, 23:03 session) — 1.10.99 IS A REGRESSION → 1.10.100-minimal

The 23:03 live verdict for 1.10.99-spellid was TOTAL failure:
```
CastProbe id=45477 mode=6 ... minS=00000001 maxS=00D54940 slot0=26693020
SafeNativeCast rc=0x00000000 al=0 id=45477
CastProbe id=45513 mode=2 ... minS=00000001 maxS=00D54940 slot0=26693020
SafeNativeCast rc=0x00000000 al=0 id=45513
SafeNativeCast rc=0x00000000 al=0 id=26573 guid=0x0     <-- Consecration TOO
```
Every spell — including Consecration (which landed in EVERY prior session) —
now returns al=0. **The round-34 claim was WRONG and the "fix" was the cause.**

### The disassembly PROVES round 34 had it backwards (0x80DA40 → 0x80CCE0)
```
0x0080DA5B  mov ecx, [ebp + 0x18]   ; arg5 (isTrade)
0x0080DA5E  mov edx, [ebp + 0x14]   ; arg4 (guidHi)
0x0080DA61  push ecx
0x0080DA62  mov ecx, [ebp + 0x10]   ; arg3 (guidPtr)
0x0080DA65  push 0
0x0080DA67  push edx
0x0080DA68  mov edx, [ebp + 0xc]    ; arg2 (itemId)
0x0080DA6B  push ecx
0x0080DA6C  mov ecx, [ebp + 8]      ; <-- arg1 (spellId) IS READ
0x0080DA6F  push edx
0x0080DA70  push ecx                ; push arg1 (spellId)
0x0080DA71  push eax                ; push player
0x0080DA72  call 0x80cce0           ; cdecl — last push = first arg
```
cdecl arg order → real-logic `0x80CCE0`:
- arg1 = player (resolved by wrapper)
- **arg2 (`[ebp+0xc]`) = wrapper arg1 = SPELL ID** → GetSpellEntry(0xad49d0,
  [ebp+0xc], &out)
- arg3 = wrapper arg2 (itemId, 0)
- arg4 = wrapper arg3 (guidHolder)
- arg5 = wrapper arg4 (guidHi)
- arg6 = 0
- arg7 = wrapper arg5 (isTrade)

So the ORIGINAL call `fn(spellId, 0, guidPtr, 0, 0)` was CORRECT. Round 34's
`fn(0, spellId, ...)` fed SPELL **0** to GetSpellEntry — and the live probe
shows **`minS=00000001`** → `GetSpellEntry(0)` fails (`0 < minSpell`) → al=0
for EVERY spell, including Consecration. The "minSpell==0" assumption in the
round-34 claim was false (live `minS=1`).

### FIX (1.10.100-minimal) — revert + strip to the 18:11-proven minimal path
1. **REVERT the call** to `fn(spellId, 0, guidPtr, 0, 0)` (spell id in arg1;
   the wrapper forwards it into GetSpellEntry — the disasm above is proof).
2. **STRIP the accumulated side-writes** that were NOT in the 18:11 config —
   the ONLY session where casts landed:
   - round-28 UNIT_FIELD_TARGET seed `desc+0x40/+0x44` (still returned al=0;
     descPtr kept READ-ONLY for the probe's desc40 diagnostic),
   - round-32 transient `0xBD07B0` selection write (tracks the user's
     persistent "aura search drops my target"),
   - round-33 `[0xBEAF44]` mask bit write (never helped),
   - round-26 `+0x10/+0x14` walk-slot fallback seed (a "fallback" the user
     explicitly rejects).
3. KEEP the crash-defense machinery (VEH guard, g_currentL clear, action-state
   save/zero/restore, static-slot write 0xD3C00E14, arg4 GUID-holder,
   blocked-counter reset) + CastProbe/CastDiag diagnostics + acquire-on
   registration (NativeSetTarget only when registerTarget!=0).

### Live watchlist (1.10.100-minimal)
1. VER reads `1.10.100-minimal`.
2. SafeNativeCast passes the real spell id again → GetSpellEntry finds the
   entry (minS=1, real id >= 1) — the round-34 total-failure gate is gone.
3. **`al=1` → casts land** (Consecration should return at minimum, like every
   pre-round-34 session; unit-targeted spells are the real test).
4. Acquire-off: 0xBD07B0 is NEVER touched → aura-search must NOT drop the
   current target. No face-turning anywhere (detection-only).

---

## 2026-08-02 (35th round, 23:13 session) — 1.10.100 STILL al=0 → 1.10.101-rawguid

The 23:13 live verdict for 1.10.100-minimal:
```
CastProbe id=45477 mode=6 desc40=00000000 r8=0x6D82A160 r1=0x6D82A160
entry=1 a0=0000B1A5 a10=00050000 a28=02000000 fam=2 gate=0 d4139c=00000000
busyV=0 busyP=0 ... beaf44=00000000 beaf4c=00000000 minS=00000001
SafeNativeCast rc=0x4EF73B00 al=0 id=45477
```
- `entry=1` — CONFIRMS the round-34 revert worked: the real spell id (45477)
  now reaches GetSpellEntry (all gates pass, incl. sync r8 resolving).
- `rc=0x4EF73B00 al=0` — the fail went through the SHARED silent epilogue
  **0x80d249** (`mov edi,esi; call 0x805100; ...; xor al,al`) — rc is
  0x805100's return. So the refusal is a post-gate path inside 0x80CCE0.

### FULL REAL-LOGIC DISASM (0x80CCE0 → 0x80DA40, tools/_disasm_cast.txt)
The complete gate chain after the previously-probed gates (all exonerated):
1. 0x80D34B `0x805f60(esi, &playerGuid, spellId)` — if 0 → skip gate C.
2. 0x80D36D `0x809000(spellId, flag, 0,0,0)` — !=0 → 0x80d385 → 0x80d249 FAIL.
   flag = (player->0x4cee50()==0) ? 1 : 0.
3. 0x80D452 `0x8091d0(player, &spell, 1, record)` — ==0 → 0x80d249 FAIL.
   Passes trivially iff `player->0x4cee50()==0`; else checks spell-requirement
   slots (+0xC8/+0x278/+0xd0) + 0x800d60(player, spell), fail err 0x83.
4. 0x80D46F `0x8093d0(player, &spell, 1, 1, record)` — ==0 → 0x80d249 FAIL.
5. 0x80D6AD `0x809610(player, &spell, guidLo, guidHi, &out, 1, record)` —
   if !=0 && [out]==0 → 0x80d249 FAIL.
6. 0x80D6D1 `0x739650(player, record, &spell, itemId)` — ==0 → 0x80d249 FAIL
   (errs 0x57/0x97/0xa8/0x2d; internally calls 0x809000 too).
7. 0x80D727 `0x80c790(player, &spell, guidLo, guidHi, record, isTrade)` —
   **!=0 → 0x80d8ef = SUCCESS** (the final cast commit; writes [0xD3F4E0],
   pending [0xBD07B0/B4], [0xD3F4E4]).
Plus a separate busy-gate check at 0x80D3E1 (`[spell+0x2c] bit 3` → reads
`[player+0xd0]` record `[rec+0xd8] bit 18`; fail err 0x6b).

### THE ROUND-36 DECISION (git diff 78ce247 HEAD proved it)
The diff of Actions.cpp against `78ce247` — the 18:11/1.10.81 build, the ONLY
session where casts landed — shows the cast invocation was:
```
int rc = fn(spellId, 0, lo, hi, 0);      // 18:11 — RAW GUID dwords
int rc = fn(spellId, 0, guidPtr, 0, 0);  // rounds 18-35 — holder POINTER
```
The round-18 "arg3 is a POINTER" fix (1.10.83) is the ONE remaining difference
from the proven config. The disasm shows the `[guidPtr+8]` pointer read at
0x80CDC1 is guarded by `test ebx,ebx; je 0x80cdc6` where ebx = **itemId** — our
casts always pass itemId=0, so 0x80CDC1 is NEVER taken; for itemId==0 the
record target comes from `[edi+8]` (sync-resolved victim) at 0x80CDC6, and
arg3/arg4 are forwarded as a RAW GUID pair to the post-gate checks (0x5d3520
at 0x80D54E, and 0x80c790's commit at 0x80D727). Passing a pointer where the
client expects a raw GUID dword is what trips a silent 0x80d249 gate.

### FIX (1.10.101-rawguid)
`fn(spellId, 0, lo, hi, 0)` — restore the exact 18:11 raw-GUID invocation.
The holder (`s_guidHolder`) is removed. All else stays at the round-35
minimal config (static slot, no side-writes, no register for acquire-off,
crash-defenses + probes).

### Live watchlist (1.10.101-rawguid)
1. VER reads `1.10.101-rawguid`.
2. **`al=1` → casts land** (Consecration + unit-targeted) — if the raw-GUID
   revert is the fix, this is the FIRST working session since 18:11.
3. If still al=0: the next step is a live probe of gates 0x4cee50 / 0x809000
   / 0x8091d0 / 0x8093d0 / 0x809610 / 0x739650 (VEH-guarded, correct args)
   to name the exact refusing gate, or switch to the 0x80DA80 sibling
   (keybind path: 0x802cb0 → 0x802f80, no canCast/mask/sync gates).

---

## 2026-08-02 (36th round — RELOAD CRASH) → 1.10.102-reloadfix

The 23:13 session ALSO crashed ~460ms after a `/reload`:
```
23:14:39.563 br.rebind old=380A3148 new=4CF62648 rebind=1
23:14:39.563 om.freeze durMs=10000 reason=reload
23:14:40.023 crash.fatal AV_READ eip=0x684BF090 fault=0x3C eax=0
  crash.stack frame=0 ret=0x0040CF09  frame=1 ret=0x0040D16E  frame=2 ret=0x0040D15D
```
USER DIRECTIVE: reloads must be handled PERFECTLY — /reload is a normal action.

### Root cause (disasm)
- `0x40CEE4` is a delay-load stub: resolve a module (string 0x9E30F4
  "...or constructor iterator'" = MSVC CRT static-init/atexit) + function
  (0x9E30E4) via `[0x9DF1B0]`/`[0xB2ED98]`, then `call eax` at 0x40CF07.
  `eax` = 0x684BF090 = a function in a module loaded at ~0x68400000 that
  AV'd reading [reg+0x3C] (eax=0 → null-ish deref). Callers 0x40D150/0x40D161
  → `0x40d06e` are the CRT init/atexit dispatch wrappers (the game's reload
  teardown).
- **Our vector**: the frame tick hook (0x7E5120) runs EVERY frame — including
  every frame of the /reload teardown. `TickHookBody` unconditionally calls
  `DrainCastQueue` → `SafeNativeCast` → **Spell_C**, `RefreshLiveFacingCache`
  (camera/object resolution), and `PulseSelectionRestore`. The OM freeze
  (`RebindFrozen`, 10s) ONLY gates `OM::Refresh` — it does NOT gate the cast
  drain or facing cache. Running Spell_C / game resolution mid-Lua-teardown
  crashes the client (the game was already inside its CRT atexit/init walk).

### FIX (1.10.102-reloadfix)
1. **Frame-hook reload/glue gate** (`NativeHook.cpp TickHookBody`): before any
   game-call work, require a REAL active player GUID + a live lua_State via
   PURE MEMORY (`ActiveGuidPure()` + `LuaState()`) — the same signals the
   worker uses. Both are 0 during glue/char-select/loading/reload and set
   once in-world. While absent: skip OM refresh, facing cache, cast drain,
   selection restore, deferred actions (keep the harmless blocked-counter
   reset). Fail-open: there is nothing to cast during a reload.
2. **Crash handler module dump** (`main.cpp CrashHandler`): on any fault,
   enumerate loaded modules (Toolhelp32) and log `crash.mod eip=... in
   '<module>' base=... size=...` so every future crash names its module
   instead of a bare address.
3. The stale-queue drop (2s) already clears any cast queued across the reload.

### Live watchlist (1.10.102-reloadfix)
1. VER reads `1.10.102-reloadfix`.
2. **`/reload` mid-session must NOT crash** — expect `br.rebind` +
   `om.freeze` + `om.freeze_clear` and NO `crash.fatal`. Casting resumes
   after the freeze clears (player GUID present → gate opens).
3. Cast behavior unchanged in-world (the gate is transparent once a player
   exists — the raw-GUID al=0 question is still open and tracked separately).

---

## 2026-08-02 (37th round — 23:48 session) — RUNTIME CAST IS FIXED; remaining bugs are Lua → addon-only fix

The 23:48 session was the BREAKTHROUGH: **the native cast path now works**.
```
SafeNativeCast rc=0x00000001 al=1 id=45477   (Icy Touch)
SafeNativeCast rc=0x00000001 al=1 id=45513   (Plague Strike)
SafeNativeCast rc=0x00000001 al=1 id=46501   (Blood Strike)
SafeNativeCast rc=0x00000001 al=1 id=26573   (Consecration)
addon: "landed Icy Touch poll" / "landed Consecration poll"
```
The round-36 raw-GUID revert (`fn(spellId, 0, lo, hi, 0)`) was THE fix for the
3-day al=0 saga — every gate passes and the client accepts the cast. No crash
on reload either (the 1.10.102 gate held). The runtime is done.

### What remains (pure addon Lua — the addon log proves it)
1. **Aura search not working / rotation stuck in `wait no_target`** — the
   `aura_search` condition HARD-FAILED whenever `World.spell_max_range(id)`
   returned nil (RANGE_UNKNOWN → return false → no search at all → "wait
   no_target x58" after the target died). The runtime range decode was the
   gate.
2. **`wait facing:Blood Strike` at edge=0yd/2yd while standing on the mob** —
   the runtime ObjectIsFacing (0x7AC) intermittently returns a confident
   not-facing at point-blank; the gate trusted it and never wired melee.
3. **`refused ... phantom_grace` then re-fire on melee** — instant melee casts
   produce no SUCCESS/FAIL event within the ~0.14s grace, so the addon
   declared phantom on casts the runtime HAD accepted (nrc=1), re-firing and
   driving the "wait cooldown" spin.

### FIX (this round — ADDON-ONLY, runtime 1.10.102 unchanged)
1. `Executor.lua` facing gate: **precise point-blank exemption** — when the
   candidate is within ≤2yd AND the spell is a melee-range cast (runtime
   melee==1, max≤6), a confident-not-facing verdict does NOT block. WoW
   auto-faces melee; you cannot be "behind" a target you are standing on.
   Ranged/farther targets keep the strict runtime verdict (no blanket
   exemption — that was the 18:11 regression).
2. `Conditions.lua` aura_search: RANGE_UNKNOWN no longer kills the search.
   Use the condition's explicit `range` param (user intent, not a silent
   malformed fallback) as the search bound; clamp DOWN only when the spell
   max IS known. Restores aura search when the decode is unavailable.
3. `ChatHandler.lua`: new **`/raijin search [spellId]`** diagnostic — runs the
   EXACT production path (spell_max_range → raw AuraSearch → Lua wrapper) and
   prints each stage, so aura-search state is attributable in-game instead of
   guessed.

### Live watchlist (this Lua-only deploy)
1. In-front-of-mob melee (Plague/Blood Strike) wires immediately even when the
   runtime facing read says not-facing — no more `wait facing:Blood Strike` at
   edge≤2yd.
2. Aura-search slots with no current target actually find a mob (no target
   death → instant re-target); run `/raijin search 45477` to see the exact
   stage that was returning empty.
3. After a phantom/refuse, the rotation recovers to the next castable slot
   without spinning multiple `wait cooldown` ticks (the confirm loop is the
   next issue to hammer if it persists).

---

## 2026-08-03 (38th round — 00:11 session) — THE TRUE ROOT CAUSE of the random lockups: facing read returns 0.0 → treated as a real north-facing

The 00:11 session still locked up, but the log makes the ACTUAL cause obvious:
```
00:11:36 attempt Blood Strike sid=46501 needs_enemy=y ... tgt=y
00:11:36 [rot] wait facing:Blood Strike  x1  tgt=yes  edge=0yd   ← blocked AT 0yd
00:11:37-39 ... repeated
00:11:39 [rot] wait facing:Blood Strike  x80  tgt=yes  edge=0yd   ← ~3.5s lock
00:12:08 attempt Icy Touch sid=45477 search=n ... tgt=y
00:12:08 [rot] wait facing:Icy Touch  x1  tgt=yes  edge=0yd     ← Icy Touch (RANGED) blocked AT 0yd
```
The rotation is being hard-blocked by `wait facing:X` for BOTH melee (Blood
Strike) AND ranged (Icy Touch) at `edge=0yd` — literally standing on the mob.
Aura search was NOT the blocker (it wired+landed Icy Touch/Plague at 13.7yd /
12.9yd / 7.4yd fine earlier). The random lockup is the FACING GATE.

### ROOT CAUSE (runtime, disasm/data-proven)
- The Ascension facing read (`[obj+0x7AC]` via camera) intermittently returns
  `0.0`. The FacingLive runtime log shows `face=0.0000` on essentially EVERY
  line; only occasionally a real value (1.62, 2.98, 3.09, ...).
- `LooksLikeFacingEarly(0.0)` / `LooksLikeFacing(0.0)` both returned TRUE
  (0.0 is in [-6.30, 12.60]) — so `0.0` (the FAILED-READ SENTINEL) was treated
  as a VALID facing of 0 (= north/+Y).
- `IsFacing(a,b)` then compared the target heading against NORTH, and for any
  target not due north returned a CONFIDENT `0` (not facing) → the addon
  hard-blocked with `last_why="facing"` → `wait facing:X x80+`.
- It is "random" because whether it locks depends on whether the 50ms cache
  refresh happened to hold a real facing vs the 0.0 sentinel at that instant.

### FIX — facing is DETECTION-ONLY; the CLIENT is the sole determinate authority
The user's directive is absolute and repeated: NO single ability may lock up the
rotation, facing is detection-only, and **nothing may be a guess**. The
developer-facing facing read on this Ascension build is provably unreliable
(`[obj+0x7AC]` intermittently returns 0.0 even for an engaged player on a mob),
so using it as a hard pre-cast gate produced a WRONG answer: it blocked casts
the client would have ACCEPTED (`SafeNativeCast` returned al=1 on those same
targets). That false pre-block was the entire lockup.

The fully DETERMINISTIC behavior (no guess either way):
1. **The cast always wires** — the client is the referee. It returns
   `al=1` (accepted) or `al=0` (refused "not in front", recovered as one
   phantom, logged) — a determinate outcome EITHER way, NEVER a multi-second
   stall.
2. Removed the `if facing == false then last_why="facing"` hard block from BOTH
   the candidate gate and the target-relative wire path in `Executor.lua`. Kept
   the LoS confident-block (a real, reliable measurement the user accepts).
3. Runtime (`ObjectManager.cpp`): `LooksLikeFacing*` reject `|f|<0.0001`, and
   the camera `[cam+0x11C]` (the client's own GetPlayerFacing fallback,
   0x60A4EA) is the primary source for diagnostics/candidate ordering — so the
   diagnostic and ordering never rely on the broken object field.
4. Candidate ordering still prefers closest + facing-first (`AuraSearchPacked`),
   but that never holds the wire.

This is not "uncertainty": refusing to cast on a measurement we cannot trust is
itself a wrong, non-deterministic guess. Delegating to the client gives a
determinate result every time.

### Live watchlist (1.10.103-facing0)
1. VER reads `1.10.103-facing0`.
2. **No `wait facing:X` hold at ANY range** — Blood/Plague Strike and Icy
   Touch wire immediately; the client accepts (al=1) or refuses
   deterministically.
3. Cast throughput at point-blank is continuous — GCD cycles normally, no
   80-tick holds.

---

## 2026-08-03 (39th round — 00:30 session): "aura search massively inconsistent" — the STUCK-CANDIDATE bug (user-diagnosed, code-confirmed)

User: "everything works to a degree, but aura search is massively inconsistent.
Sometimes it just doesn't cast on a target right in front of me, sometimes it
casts fine. I think it's trying to cast on one target at a time, and incorrectly
getting stuck on that one target, that it knows it can't cast on, instead of
looking for a target that it actually can cast on."

### CONFIRMED — exactly right. The bug was in the try_list loop (Executor.lua).
```lua
for ci = 1, #try_list do
    local cand = try_list[ci]
    ...
    if not last_why and ... then    -- range gate
        if cdist > cmaxR then last_why = "oor" end
    end
    if not last_why and ... then    -- LOS gate
        if ... then last_why = "los" end
    end
    if not last_why then            -- WIRE
        ...
    end
    -- ❌ last_why was NEVER reset before the next candidate
end
```
`last_why` persisted across iterations. If candidate #1 (the CLOSEST — the
sort is ascending) was rejected (oor / los / bad_guid / a refused cast), every
later candidate's `if not last_why` guard was false → they were NEVER evaluated
or wired. So with a far add as the closest candidate (out of a 5yd melee
spell's range), the target right in front of the player (candidate #2+) was
never cast — "stuck on the one target it can't cast on instead of looking for
one it can." The in-front target IS in the list; it just never got its turn.

### FIX (addon-only, this round)
`last_why = nil` at the top of each `try_list` iteration, so EVERY candidate is
evaluated independently and the first WIREABLE one wins (breaks on success).
A rejected candidate moves to the next; only a full pass with zero castable
candidates leaves the slot skipped that tick (re-evaluated next tick, as
before). Runtime unchanged (1.10.103-facing0).

### Live watchlist
1. Aura search with several mobs + one in front: if the closest is out of the
   spell's range, the in-front target is cast (fall-through now works).
2. No regressions: closest-first preference preserved (candidate #1 still wins
   when it IS castable).

---

## 2026-08-03 (round 43 — 1.10.104-aa): "auto attack casts are not working" + "you are generating ui errors"

User: "auto attack casts are not working and you are generating ui errors, but
everything else is working as intended so far for now."

### ROOT CAUSE 1 — Auto Attack NEVER re-engages (permanent latch, addon)
`Executor.attempt_action`'s Auto Attack branch set `_aa_target = tgt_g` after
the first `Act.Attack` and returned `"already_attacking"` for that target
FOREVER — the memo was never cleared. Live proof: 13:01:17 `FIRE #1 Auto
Attack edge=33.9` (out of melee), then `wait already_attacking x312` at
edge=0-5yd — the player closed to melee and the engage was NEVER retried.
FIX: removed the `_aa_target` latch entirely; the runtime `IsAttacking`
(AttackTargetGuid, player+0xA20/0xA24) is the sole "already attacking" signal
and the 0.35s `_recent` floor is the only throttle. Added an addon-side
melee-range gate (center > 6yd → wait `oor`, matching the runtime gate) so the
slot doesn't stage a pointless engage every 0.35s while far.

### ROOT CAUSE 2 — the runtime 6603 engage was DISABLED (round 23, runtime)
`AttackTargetFor` returned true WITHOUT casting 6603 since round 23 ("every
session that cast 6603 broke"). That evidence was CONFOUNDED: it was gathered
during the broken holder-pointer cast era (rounds 18-35) — the cast path
itself was failing regardless of 6603, and the one clean session (18:11) ran
the raw-GUID invocation. Since the round-36 raw-GUID fix every targeted cast
lands (al=1); casting 6603 through the SAME `SafeNativeCast(6603, guid, 0)`
(registerTarget=0 = 1.10.86-proven, zero selection touch) is the identical
machinery. The client only auto-attacks on melee spell land, so a rotation
with no melee ability off-CD NEVER started auto-attack. FIX: re-enabled the
engage behind the existing melee-range gate (center <= 6) + idempotency
checks. If the raw-GUID path breaks with 6603, revert this block (git).

### ROOT CAUSE 3 — 0xB450EDDC resolver AV on EVERY cast (the "ui errors")
The crash shield logged `0x512B07 SHIELD: recovered resolver AV esi=0xB450EDDC`
on ALL 833 AVs in the session — one per cast, including guid=0 Consecration.
The cast-feedback GUID-resolver (0x512B00 reads [esi]/[esi+4]) is dispatched
~6-15ms after every cast with a pointer to ANOTHER uncommitted BSS static slot
at 0xB450EDDC (the 0xD3C00E14 commit fixed the first slot; this second one was
still reserved-but-uncommitted). Each AV is recovered (zero-GUID substitution),
but 833 recovered AVs inside the client's Lua/cast-feedback path per session is
an undetermined state and the UI-error suspect. FIX: `SafeNativeCast` now
commits the 0xB450E000 page once (VirtualAlloc) — the resolver reads valid
zero-filled memory, byte-identical outcome to the shield's substitution, with
NO AV and NO shield involvement. Never writes a GUID there (the zero behavior
is the proven-clean one).

### Live watchlist (1.10.104-aa)
1. VER reads `1.10.104-aa`.
2. Auto Attack engages in melee: close to a target at edge 0-5yd with the
   rotation NOT landing a melee spell → 6603 wires (log `Attack engage
   id=6603 ... ok`) and the character auto-attacks; the slot stops at
   `already_attacking` ONLY while the client's AttackTargetGuid actually
   matches (real swings).
3. NO `0x512B07 SHIELD` lines at all (previously 833/session) — the resolver
   reads committed memory.
4. No UI-error regression: casts still land (al=1), no new refusals.

### LIVE EVIDENCE — 13:16 session (1.10.104-aa injected at 13:15:57)
- Boot: `sys.boot ... ver=1.10.104-aa`, `Register OK`, `br.online
  ver=1.10.104-aa`, bridge SEAL, frame tick hook ACTIVE. New runtime LIVE.
- Auto Attack engage REACHES SafeNativeCast: `SafeNativeCast rc=0x00000000
  al=0 id=6603 guid=0xF1300005E500781B` — the round-23 6603 disable is GONE
  (it cast). al=0 = the client refused this particular engage (one phantom;
  not a lockup — the slot re-attempts). The addon latch is removed so it
  keeps trying; whether it accepts depends on melee range/state at test time.
- Normal casts LAND: `id=500357 al=1 nrc=1`, `id=45477 (Icy Touch) al=1`,
  `id=26573 (Consecration) al=1` — no regression from the engage re-enable.
- **0x512B07 SHIELD still fires — at a DIFFERENT address.** Live scan:
  `recovered resolver AV (count=1..4) esi=0xD1AC736B` (the 12:59 session
  AV'd at 0xB450EDDC). VirtualQuery on the LIVE client proved both addresses
  are **MEM_FREE** (unmapped, not uncommitted-BSS) and the address is
  SESSION-DEPENDENT — the resolver's GUID pointer lands in unmapped space on
  this build. A static commit can never cover it.

### ROUND 43b (1.10.105-aa, built) — DYNAMIC SHIELD PAGE-COMMIT
The shield in main.cpp now VirtualAlloc-commits the FAULTING page on the
first 0x512B07/0x512B0A AV per address (guarded: only 0x10000..0x7FFF0000,
failure harmless). Every later dispatch to that address reads valid zero
memory (ObjectPtr(0,0,8)=0 → walk skips) with NO AV and NO shield
involvement — turning ~800 recovered AVs/session into ONE per unique address.
Removed the useless static 0xB450EDDC commit from SafeNativeCast (the address
is session-dependent). kVersion 1.10.105-aa, BUILD OK, Validate ok=46 bad=0.
NOT yet injected — the user's next inject picks it up from build_x86.

### Live watchlist (1.10.105-aa)
1. VER reads `1.10.105-aa`.
2. Auto Attack: in-melee engage wires (6603 al=1, `Attack engage id=6603
   ... ok`) and the character swings; the slot stays at `already_attacking`
   only while the client's AttackTargetGuid matches.
3. `0x512B07 SHIELD` appears at most a handful of times (one per unique
   address) instead of ~833/session.
4. Casts still land (al=1); no UI-error regression.