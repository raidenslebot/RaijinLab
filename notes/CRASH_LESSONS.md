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

## Mandatory stagger (current policy)

| When | What is allowed |
|------|-----------------|
| Inject | `om.enable=0`, no walks |
| First 5s after local GUID | Runtime `Refresh` returns empty (no list/enum) |
| PEW | Soft-arm only after **6s** (HW gates, no OM walk) |
| Soft-arm | `om.enable` still 0 for **3s**, Lua OM frame after **5s** |
| Suite ON | Force `om.enable=0`, destroy Lua OM frame |
| Suite +4s | `om.enable=1` (native list-only warm-up begins) |
| Suite +5.5s | Lua `InitObjectManager` |
| Suite +8s | Surveyor |
| After om.enable | **16** list-only frames **and** **4s** wall-clock before enum |

## Never

- `om.enable=1` on the suite-on frame
- `InitObjectManager` on the suite-on frame
- `Refresh(true)` / force enum from suite start
- `Suite.ensure_om()` bypassing the warm window
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
