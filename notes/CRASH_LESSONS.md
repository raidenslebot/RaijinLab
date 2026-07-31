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

## Multi-dot / aura_search (1.10.11–1.10.12) — FUNDAMENTAL

**Symptom:** Icy Touch only fired with a client target; acquire-off snapped
selection; rotation froze after failed IT; enemies_in_range went dead.

**Root causes (fixed):**
1. **Dispatch gated NearbyHostiles on om.enable** — soft list never ran; only
   mouseover/Unit* worked (instant while hovering).
2. **Empty hostiles packs were cached** — enemies_in_range stayed 0.
3. **Spell_C returns true without land** — long pending/GCD locked ALL lower
   slots (IT priority loop freeze).
4. **Long GUID blacklists / not_ready holds** — multi-dot could not recover.

**Rules (permanent):**
- Rotation discovery / hostility / face / cast-by-GUID = **runtime only**
- Acquire OFF → Spell_C(guid) + restore selection; never Act.Target
- Multi-dot wire without evidence → provisional GCD ≤ **80ms**, FAIL frees now,
  phantom frees next tick (never multi-second list freeze)
- Cast fail → **same-tick priority fallthrough** (clear provisional GCD)
- Never cache empty NearbyHostiles packs
- GUID blacklist cap **0.6s**
