# Crash lessons (permanent — do not regress)

Hard client crashes after **login + suite ON** and **inject during load** have
been reproduced multiple times. These rules are non-negotiable.

## ERROR #132 @ 0x00857D05 — Register during ADDON_LOADED / world load

**Proof (1):** `Register failed` == crash dump `11:38:32.476` during
`Details\core\level_scaling_data.lua` ADDON_LOADED (hard-timeout path).

**Proof (2):** 2026-07-31 13:28:45 `Register failed rc=1073741819` (0xC0000005)
with `bits=0xE` only (worldFrame|conn|objMgr — **no** localPlayer/guid/flag).
Medium-only WorldReady fired mid load; SEH corrupted VM → crash on world entry.

**Proof (3):** 2026-07-31 13:38 after `/reload` — rebind used **short medium**
settle (`kSettleRebind` ~1.5s) → `Register failed rc=1073741819` at `bits=0xE
settle=96`; later medium OK. Suite-on in that window hard-crashes.

**Cause:** `FrameScript_RegisterFunction` from worker while Lua VM still loading
or world not fully ready. Medium rebind must NOT be faster than medium first.

**Rule:**
- STRONG (flag|local|guid): modest settle; rebind may be faster.
- MEDIUM (0xE only): **same long settle first AND rebind** (~8s+ continuous).
  Never short-circuit medium after `/reload`.
- Failed register → long backoff + extra medium penalty.
- Soft OM list walks use the same **6s** hard settle as Refresh.
- Suite OM arm defers while `HasRuntime()` is false (bridge not rebound).

## Root pattern (OM / suite)

Anything that walks the full object manager (list walk, `EnumVisibleObjects`,
Lua `GetUnitCount` + per-object field fan, Surveyor TraceLine fan) **must not**
run on the same frames as:

1. Character load / PEW / ADDON_LOADED
2. Suite master ON
3. Inject / re-register

## Suite-on / delays are NOT safety (2026-07-31, CRITICAL)

**Wrong approach:** freeze OM → wait 5–8s → re-enable → "warm-up". Every crash
after suite ON landed on those delayed edges (`OM enable edge` +4–6s).

**Proof:** 13:43 / 13:47 sessions — master ON, then hard crash ~5s later when
PEW/Arm timers flipped `om.enable` and restarted list-only warm-up.

**Correct approach:**
- `Master.start_all` **never** touches OM (no enable=0, no Destroy, no timers)
- `ArmRuntimeSystems` is **one-shot**: HW gates + `om.enable=1` + Lua OM if needed
- Rising edge warm-up runs **once per inject**, not on every 0→1
- Gates = player exists + bridge online, not multi-second wall clocks
- `Suite.start` never sets om.enable / InitObjectManager as a thrash

## Ground AoE cast path (Consecration) — freeze → crash

**Proof:** `Consecration=CAST` then `wait no_candidate:Consecration x238`.
Policy optional → empty GUID try_list → infinite no_candidate.

**Rule:** Ground/self optional casts MUST `CastSpell(id)` with no unit when
try_list is empty. Soft-lock failed no_candidate slots so they cannot monopolize.

## Mandatory stagger (current policy)

| When | What is allowed |
|------|-----------------|
| Inject | `om.enable=0`, no walks |
| First 6s after local GUID | Runtime `Refresh` returns empty (no list/enum) |
| PEW soft-arm | HW gates; `om.enable` still 0 for **5s**, Lua OM after **7s** |
| Suite ON | Force `om.enable=0`, destroy Lua OM frame, bump `_om_gen` |
| Suite +6s | `om.enable=1` (native list-only warm-up begins) |
| Suite +8s | Lua `InitObjectManager` |
| Suite +12s | Surveyor |
| After om.enable | **24** list-only frames **and** **6s** wall-clock before enum |

## Never

- `om.enable=1` on the suite-on frame (including Suite.start / ChatHandler)
- `InitObjectManager` on the suite-on frame
- `Refresh(true)` / force enum from suite start
- `Suite.ensure_om()` bypassing `in_suite_warm`
- Auto selftest on the arm frame (delay ≥12s)
- Reading unit descriptor tails on GO/item/container pods
- VirtualQuery in ObjectPtr hot path
- Multi-offset list matrix probe at load

## Fail-closed is correct

Empty `NearbyHostiles` during warm-up is **success**, not a bug. Rotation may
use current target / GUID casts; pack multi-dot waits until `Master.suite_om_safe()`.

## If it crashes again

1. Check `Workspace/logs/runtime.log` for last OM / BRIDGE lines
2. Confirm suite did not call `SetSystemVar om.enable 1` before 4s
3. Confirm no enum log before list-only warm-up finished
4. Lengthen settle / warm-up; never shorten without live proof

## Cast authority (1.10.5-cancast+)

Icy Touch / multi-dot "never casts" is often not a crash — runtime was only a
verb (CastSpell) while Lua guessed face/LoS. Client refused -> spam/stall.

Runtime now owns:
- IsFacingGuid / FaceTowardGuid (TurnByDelta + live facing 0x7AC)
- CanCast / CastSpellEx with FACE_IF_NEEDED | SKIP_IF_NOT_FACING | CHECK_LOS
- Packed result "1|ok" / "0|facing" so Lua never wires a known-fail cast

Auto Face remains an opt-in slot condition (sets FACE_IF_NEEDED). Without it,
SKIP_IF_NOT_FACING still prevents spam — slot waits until you face.

## FrameScript_Execute inside Lua C = hard crash (1.10.19-castsafe)

**Proof:** 2026-07-31 13:51 — rotation `FIRE #1 Auto Attack` then client dies.
Attack/ClearTarget/TargetLastTarget/TargetUnit used `FrameScript_Execute` while
already inside `IsLinuxClient` → RuntimeCall. Nested VM re-entry → ERROR #132.

**Rule (permanent):**
- When `g_currentL` is set (Dispatch is inside a Lua C call): **only nested
  `lua_pcall`** for StartAttack / CastSpellByID / ClearTarget / TargetUnit /
  TargetLastTarget. **Never** FrameScript_Execute.
- Current-target casts: `CastSpellByID` via pcall (not Spell_C(guid) + restore).
- Multi-dot different GUID: native Spell_C(guid), restore via pcall only.
- FSExec allowed only when not already inside Lua (worker/main non-Lua paths).

## Enum mid-load after medium Register (1.10.32-loadsafe) — FATAL

**Proof:** 2026-07-31 15:41 inject during load → medium Register → PEW
`armed one-shot om=1` → client dead ~1s later. No new crash dump (hard kill).

**Cause:** `BuildUnitSnapshotLocked` called `EnumVisibleObjects` on the first
SoftRefresh while the world was still cold (bits=0xE, no localPlayer/guid).

**Rule:** List-only warm first (N successful list walks or ~5s after first
player GUID). Enum only after warm. PEW arm: HW unlock first; om.enable only
after two consecutive player-position ready ticks. Never InitObjectManager on
the arm frame.

## /reload rebind enum warm skipped (1.10.34-reload-aura) — FATAL

**Proof:** 2026-07-31 15:50 `REBIND` → medium `BRIDGE ONLINE bits=0xE` → hard
death. Same class as enum mid-load.

**Cause:** `OnLuaReload` zeroed `g_listWarmWalks` but left `g_firstPlayerMs` at
the pre-reload timestamp. `warmOk = walks>=8 || (now-firstPlayer)>=5s` was
true immediately → SoftRefresh/Refresh called `EnumVisibleObjects` while
FrameXML was still settling after `/reload`.

**Rule:** On every lua_State rebind, reset **both** list-warm counter **and**
`g_firstPlayerMs` (restart the warm epoch). Never let a pre-reload clock
authorize enum. Keep `g_everWalkedOk` so multi-dot list soft-path does not
re-enter the 2s cold settle.

## AuraSearch gen thrash / lag spikes (1.10.35-stable)

**Symptom:** Random hard kills + constant lag spikes while multi-dot runs;
not tied to /reload.

**Cause:** `seed_visible_aura_notes` + `NoteUnitAura` always bumped
`g_auraSearchGen`, which invalidated the 80ms AuraSearch pack cache every
rotation tick → SoftRefresh + full pack rebuild at 40–60Hz. Combined with
NPC `ReadPosOffsets` brute scans (~700 SEH reads/object) this looks like a
memory leak and can AV under load.

**Rule:**
- `NoteUnitAura` bumps gen only on **new** notes or material stacks/exp change
- Seed visible auras only on cache miss, throttled (~0.45s)
- Never brute-scan positions for non-local objects
- SoftRefresh interval ≥100ms; AuraSearch must not double SoftRefresh+Refresh
  on the same call

## WorldReadyStrong OR-bug (1.10.27-strong-fix) — FATAL

**Proof:** 2026-07-31 15:00 inject during load. Register `via=strong` with
`bits=0xF` (flag|wf|conn|mgr — **no** localPlayer/guid). PEW arm + crash ~2s later.

**Cause:** `WorldReadyStrong` used `(bits & mask) != 0` (ANY bit). g_InWorld
flag alone counted as "strong" mid character load.

**Rule:** Strong = localPlayer **and** activeGuid (flag optional on Ascension).
Never Register on flag alone. Medium path remains the long settle fallback.

## Melee multi-dot + readiness (1.10.26-melee-ready)

**Symptom:** Icy Touch (ranged) multi-dot hit aura_search GUIDs correctly;
Plague Strike (melee) hit the *current* client target. Consecration spammed
"spell is not ready yet".

**Root causes:**
1. Spell_C with a non-zero GUID still has melee path resolve against
   `UNIT_FIELD_TARGET` (descriptor+0x48). Ranged honours the GUID arg.
2. Wire returned true while client GCD/CD remaining; provisional hold was
   capped at 150ms → re-wire every frame.

**Rules (permanent):**
- GUID cast: **pin** `UNIT_FIELD_TARGET` to victim for Spell_C, then restore
  (descriptor write — not TargetUnit). Never demote intended GUID → guid=0.
- Runtime refuses Spell_C when nested `GetSpellCooldown` rem > 0.05 (`not_ready`).
- Provisional GCD after wire = full GCD length; refuse events free early.
- Never shrink provisional GCD to 150ms.

## Multi-dot / aura_search — FUNDAMENTAL (do not regress)

**Symptom:** Icy Touch only fired with a client target; acquire-off snapped
selection; rotation froze after failed IT; enemies_in_range went dead.

**Root causes (fixed historically):**
1. Dispatch gated NearbyHostiles on om.enable — soft list never ran
2. Empty hostiles packs cached — enemies_in_range stayed 0
3. Spell_C true without land — long GCD froze the list
4. **False crash "fixes" (1.10.22):** multi-second empty OM warm + rotation
   boot ticks with skip_enemies **killed AuraSearch** while barely helping
   crashes. Never "fix" multi-dot by disabling discovery.

**Rules (permanent):**
- Soft list walk is the multi-dot backbone (works with om.enable 0 or 1)
- AuraSearch always soft-refreshes; never depends on a warm-up that returns empty
- OnLuaReload: brief quiet (~400ms) only — never reset cold settle / everWalked
- SEH walk keeps prior snapshot on bad frames (never wipe units=0 on one AV)
- Failed walk ≠ empty world; keep last good snapshot
- Acquire OFF → Spell_C(guid) + pcall restore; never FSExec inside Lua C
- Never cache empty NearbyHostiles / AuraSearch packs as success
- Cast fail → same-tick fallthrough
