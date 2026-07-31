# Crash lessons (permanent — do not regress)

Hard client crashes after **login + suite ON** and **inject during load** have
been reproduced multiple times. These rules are non-negotiable.

## ERROR #132 @ 0x00857D05 — Register during ADDON_LOADED (2026-07-31)

**Proof:** `runtime.log` line `Register failed` timestamp == crash dump time
`11:38:32.476`. EBX == lua_State from inject log. Stack in FrameScript while
loading `Details\core\level_scaling_data.lua`. `Last FrameScript_SignalEvent:
ADDON_LOADED`.

**Cause:** worker `kHardTimeout` (~6s) called `FrameScript_RegisterFunction`
**without** `g_InWorld==1`. SEH on the worker “caught” an AV but corrupted the
Lua VM; main thread then null-deref’d (`mov edi,[eax]` with eax=0).

**Rule:** NEVER register unless `InWorldFlag()==1` for a sustained streak.
**No hard-timeout bypass.** Failed register → multi-second backoff, not spam.

## Root pattern (OM / suite)

Anything that walks the full object manager (list walk, `EnumVisibleObjects`,
Lua `GetUnitCount` + per-object field fan, Surveyor TraceLine fan) **must not**
run on the same frames as:

1. Character load / PEW / ADDON_LOADED
2. Suite master ON
3. Inject / re-register

## Suite-on force-enable (2026-07-31, CRITICAL)

**Cause:** `Master.start_all` correctly set `om.enable=0` and scheduled arm, then
`start_module("quest")` → `Suite.start()` **immediately** called
`SetSystemVar("om.enable","1")` on the same frame. PEW `ArmRuntimeSystems`
delayed timers could also re-enable mid-warm. Client hard-crashed.

**Rule:** Only `Master.start_all` timers may re-enable OM after suite-on.
- `Suite.start` must NEVER set `om.enable` or `InitObjectManager`
- `Suite.ensure_om` / `tick` fail-closed while `Master.in_suite_warm()`
- PEW `enable_om` timers must check `in_suite_warm` / `_om_gen`
- Runtime rising-edge `om.enable` always restarts list-only warm-up

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
