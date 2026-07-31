# Crash lessons (permanent — do not regress)

Hard client crashes after **login + suite ON** have been reproduced multiple times.
These rules are non-negotiable.

## Root pattern

Anything that walks the full object manager (list walk, `EnumVisibleObjects`,
Lua `GetUnitCount` + per-object field fan, Surveyor TraceLine fan) **must not**
run on the same frames as:

1. Character load / PEW
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
