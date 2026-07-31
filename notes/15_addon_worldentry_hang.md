# 15 — RaijinLab addon world-entry hang: root cause & fix set

Status: **CONFIRMED** (static audit, line-verified). Client boot not available; every claim below is grounded in the shipped Lua.

## Symptom

- Load into world → FrameXML loads → client stops processing incoming packets → after 30 s:
  `Packet watchdog timed out after 30 seconds without receiving a packet; forcing disconnect.`
- Addon **disabled** → world entry fine. Addon **enabled** → freeze.
- Injected runtime DLL **not loaded** in these sessions → `RaijinLab:HasRuntime() == false` ("load-only mode").

A 30 s packet-watchdog trip means the **main thread never returned** to the network pump. We are hunting a
main-thread block (infinite loop / runaway ticker / error storm), not a one-shot Lua error (WoW catches those).

## Timeline of a frozen boot (load-only mode)

1. TOC loads. `core/Compat.lua` runs at file scope: base 3.3.5 has **no native `C_Timer`**, so the polyfill
   installs an `OnUpdate` drain over a `waiters` list (Compat.lua:6-40).
2. `VARIABLES_LOADED` → `RaijinLab:CoreOnEvent` → `RaijinLab:Init()` (Events.lua:22-23).
3. `Init()` runs **unconditionally** (no `HasRuntime` gate): banner, hooks, then
   `RaijinLab:InitDrawing()` (Events.lua:74) and `AddDrawingCallback("arena", ArenaTeamAwareness)` (Events.lua:75-77).
4. `InitDrawing()` unconditionally starts a **100 Hz ticker**: `onDrawTicker = Enable(1/100)` =
   `C_Timer.NewTicker(0.01, OnDrawUpdate)` (Drawing.lua:350). Under the polyfill this appends a `waiters` entry.
5. First post-loading-screen frame carries a large `elapsed` (world-load stutter, fps ≤ 100 ⇒ `elapsed ≥ 0.01`).
   The polyfill drain reaches the ticker waiter, fires it, `tick()` re-arms a fresh `{t=0.01}` waiter **into the
   same list mid-drain**, and the drain loop reprocesses it against the **same frozen `elapsed`** → fires again →
   re-arms again → **infinite loop, `OnUpdate` never returns**.
6. Main thread wedged → no packet pump → 30 s watchdog → forced disconnect. Deterministic.

The freeze is the **ticker machinery**, not any callback work: `OnDrawUpdate` outside an arena is a no-op
(`ArenaTeamAwareness` early-returns at Awareness.lua:3, `clearCanvas` walks empty lists), yet the polyfill loops
regardless.

## Confirmed root causes (ordered by certainty)

### RC1 — `core/Compat.lua:10-24` — C_Timer polyfill same-frame re-arm infinite loop (PRIMARY)

The drain loop uses `while i <= #waiters` with a single fixed `elapsed` for the whole pass, and the **fire branch
never advances `i`** (only the `else` branch does). `NewTicker.tick` re-arms via `C_Timer.After(delay, tick)`,
appending a new waiter to the *same* list being drained. A ticker whose `delay` (0.01 s) is ≤ per-frame `elapsed`
re-qualifies (`w.t = 0.01 - elapsed <= 0`) the instant it is re-appended, so `i` and `#waiters` stay pinned and the
loop never terminates. This is a CPU-bound hang, uncatchable by WoW's error handler and by the polyfill's own
`pcall` (pcall catches errors, not non-returning loops). **This is the deterministic cause on a normal (non-arena)
world entry.**

### RC2 — `core/Drawing.lua:350` (+ Events.lua:74) — unconditional 100 Hz sub-frame ticker (TRIGGER)

`InitDrawing` is called from `Init()` with **no `HasRuntime` gate**, and starts `NewTicker(0.01, OnDrawUpdate)`.
The 0.01 s interval is below world-load frame time, which is exactly the condition RC1 needs to detonate. Without
the runtime, drawing is useless anyway (`WorldToScreen` / `ObjectPosition` / `GetCameraPosition` /
`IsPlayerInWorld` are runtime-only globals). This ticker is the sole unconditional `NewTicker(interval ≤ frametime)`
in load-only mode, so it is the trigger that feeds RC1. Removing/raising it stops the freeze even before RC1 is
fixed.

### RC3 — `core/API.lua:33` — `RLCall` infinite tail-recursion (SECONDARY; arena-entry only)

```lua
if type(IsLinuxClient) == "function" then
    return RLCall(...)   -- copy-paste typo: should be IsLinuxClient(...)
end
```

`IsLinuxClient` is a **stock 3.3.5 FrameXML global** (always present, returns nil on Windows), so this branch is
taken whenever the runtime is absent. `return RLCall(...)` is a proper tail call in Lua 5.1 → no stack growth, no
"stack overflow" error → a pure infinite loop pinning one core. Any RLCall-routed API (`ObjectPosition`,
`GetObjectCount`, `WorldToScreen`, …) hard-hangs the instant it is invoked without the runtime.

**Reachability at world entry:** the object manager path is dead in load-only mode — `InitObjectManager` (and its
`PLAYER_ENTERING_WORLD` handler at Manager.lua:238) is created **only inside** `if RaijinLab:HasRuntime()`
(Events.lua:29-30), so S3 is cleared. The **only** unconditional world-entry path to `RLCall` is the arena drawing
callback, and `ArenaTeamAwareness` early-returns unless `IsActiveBattlefieldArena()` is true (Awareness.lua:3).
Net: RC3 hard-freezes **guaranteed when the player enters the world already inside an arena**, but does not trigger
on a generic city/quest/dungeon load. It is a genuine latent hard hang regardless and must be fixed. A second
guaranteed trigger exists for any character who ever toggled the looter on (`RaijinLabDB.looter_enabled` persisted →
Looter.lua:214 `Gather()` → RLCall).

## Cleared suspects (not the freeze)

- **S3 / Manager.lua:238 PEW handler** — runtime-gated; never armed in load-only mode. Handler is a one-shot
  `ResetObjects()` table wipe anyway.
- **S2 / Drawing.lua:341 `CreateFrame("Frame", WorldFrame)`** — table-as-name is tolerated on 3.3.5 (anonymous
  frame); it does NOT abort `InitDrawing` (the freeze proves `InitDrawing` completes). Latent correctness bug only.
- **S1/S5 / ArenaTeamAwareness callback** — early-returns outside arena; no-op at 100 Hz. Harmless on normal entry.
- Tracker, Farming/Farmer/Farms, Travel, Bitops, Variables — no load-time/world-entry loops; runtime-gated or
  slash-command-only.

## Fixes (minimal, surgical; make the addon safe in load-only mode)

### Fix 1 — `core/Compat.lua` (root fix; snapshot the waiter count) — REQUIRED

**Before (lines 10-25):**
```lua
    f:SetScript("OnUpdate", function(_, elapsed)
        local i = 1
        while i <= #waiters do
            local w = waiters[i]
            w.t = w.t - elapsed
            if w.t <= 0 then
                table.remove(waiters, i)
                local ok, err = pcall(w.fn)
                if not ok then
                    geterrorhandler()(err)
                end
            else
                i = i + 1
            end
        end
    end)
```

**After:**
```lua
    f:SetScript("OnUpdate", function(_, elapsed)
        local n = #waiters          -- snapshot: waiters appended during this pass wait for next frame
        local i = 1
        while i <= n do
            local w = waiters[i]
            w.t = w.t - elapsed
            if w.t <= 0 then
                table.remove(waiters, i)
                n = n - 1
                local ok, err = pcall(w.fn)
                if not ok then
                    geterrorhandler()(err)
                end
            else
                i = i + 1
            end
        end
    end)
```

Capturing `n` before the pass and decrementing it on each removal means re-armed waiters land at index `> n` and
are skipped until the next `OnUpdate`, breaking the same-frame re-arm. Each original waiter is still processed
exactly once per frame. This alone stops the freeze for any `NewTicker(interval ≤ frametime)`.

### Fix 2 — `core/Drawing.lua` (gate + de-tune the ticker) — REQUIRED

**Before (line 337-352, `InitDrawing`):**
```lua
function RaijinLab:InitDrawing()
    if not private then
        private = {line = {r = 0, g = 1, b = 0, a = 1, w = 1},
            callbacks = {},
            canvas = CreateFrame("Frame", WorldFrame),
            ...
        textures_used = {}}
        private.canvas:SetAllPoints(WorldFrame)
        onDrawTicker = Enable(1 / 100)
    end
end
```

**After:**
```lua
function RaijinLab:InitDrawing()
    if not RaijinLab:HasRuntime() then return end   -- drawing is useless without the DLL; do not start the ticker
    if not private then
        private = {line = {r = 0, g = 1, b = 0, a = 1, w = 1},
            callbacks = {},
            canvas = CreateFrame("Frame", nil, WorldFrame),  -- fix arg order: name=nil, parent=WorldFrame
            ...
        textures_used = {}}
        private.canvas:SetAllPoints(WorldFrame)
        onDrawTicker = Enable(1 / 30)   -- above per-frame time; a slow frame can never re-fire within one pass
    end
end
```

Also add a defensive guard at the top of `OnDrawUpdate` (line 311) so the pump is inert without the runtime and
never calls the runtime-only `IsPlayerInWorld` bare:

```lua
local function OnDrawUpdate()
    if not RaijinLab:HasRuntime() then return end
    local inWorld = IsPlayerInWorld
    if private and inWorld and inWorld() then
        clearCanvas()
        for _, callback in pairs(private.callbacks) do
            callback()
        end
    end
end
```

### Fix 3 — `core/API.lua:33` (kill the tail-recursion) — REQUIRED

**Before (lines 28-36):**
```lua
local function RLCall(...)
    if type(RaijinLab_Runtime) == "function" then
        return RaijinLab_Runtime(...)
    end
    if type(IsLinuxClient) == "function" then
        return RLCall(...)
    end
    return nil
end
```

**After (make load-only mode a hard no-op):**
```lua
local function RLCall(...)
    if type(RaijinLab_Runtime) == "function" then
        return RaijinLab_Runtime(...)
    end
    return nil   -- no runtime DLL: RLCall is a no-op (was: infinite tail-recursion on the IsLinuxClient typo)
end
```

Matches the already-correct copies in `Runtime.lua:10-11` and `tools/patch_api_bridge.py:11-12`. If the legacy
`IsLinuxClient` dispatcher must be preserved for a real runtime build, use `return IsLinuxClient(...)` instead of
`return RLCall(...)` — but the plain `return nil` is safest for load-only mode.

### Fix 4 — `core/Events.lua:75-77` (gate the arena callback) — RECOMMENDED (defense in depth)

**Before:**
```lua
    if RaijinLab.ArenaTeamAwareness then
        RaijinLab:AddDrawingCallback("arena", RaijinLab.ArenaTeamAwareness)
    end
```

**After:**
```lua
    if RaijinLab:HasRuntime() and RaijinLab.ArenaTeamAwareness then
        RaijinLab:AddDrawingCallback("arena", RaijinLab.ArenaTeamAwareness)
    end
```

With Fix 3 this is no longer strictly required to stop the hang, but it keeps the runtime-only callback off the draw
list entirely in load-only mode (and stops the ~100 Hz nil-error storm on an arena re-log).

### Fix 5 — `modules/arena/Awareness.lua:8` (dead 3.3.5 API) — LOW (correctness)

`GetNumGroupMembers()` does not exist on 3.3.5 (introduced in 4.x). Replace with:
```lua
  for i = 1, (GetNumGroupMembers or GetNumPartyMembers)(), 1 do
```

## Priority

1. **Fix 1 (Compat.lua)** and **Fix 2 (Drawing.lua)** — together eliminate the deterministic generic world-entry
   freeze. Either alone breaks the loop; ship both.
2. **Fix 3 (API.lua)** — eliminates the arena-entry / looter-on hard hang.
3. Fixes 4-5 — hygiene / defense in depth.

## Regression checklist

- [ ] Load-only mode (no runtime), enter world in a **city** → no freeze, no watchdog, banner prints load-only line.
- [ ] Load-only mode, enter world in a **battleground/arena** → no freeze (Fix 3 + Fix 4).
- [ ] Character with `RaijinLabDB.looter_enabled = true` persisted, load-only mode, world entry → no freeze.
- [ ] Confirm no native `C_Timer` on the target client (polyfill is the live path); if a native backport exists,
      verify Fix 1 still applies to it or is harmless.
- [ ] `C_Timer.After(delay, fn)` still fires once after ~delay; `NewTicker(delay, fn)` fires repeatedly at ~delay
      and can be `:Cancel()`ed. Verify a timer scheduled from inside a timer callback runs on the **next** frame,
      not the same one (Fix 1 behavior).
- [ ] With runtime present: draw ticker starts (Fix 2 gate passes), drawing renders; arena awareness draws lines
      in an actual arena.
- [ ] `RLCall`-routed APIs (`GetObjectCount`, `ObjectPosition`, `WorldToScreen`) return `nil` cleanly in load-only
      mode and dispatch correctly with the runtime (Fix 3).
- [ ] Drawing canvas is parented to `WorldFrame` and `SetAllPoints` still anchors correctly (Fix 2 arg-order change).
- [ ] `/reload` in-world (both modes) does not re-trigger the hang.
