from pathlib import Path

p = Path(r"C:\Ascension\Workspace\RaijinLab\addon\core\Scheduler.lua")
s = p.read_text(encoding="utf-8")

OLD = """    local target = 1000 / (tonumber(p.target_fps) or 60)
    local maxb = tonumber(p.max_budget) or 8.0
    local minb = tonumber(p.min_budget) or 0.3
    local ema = Scheduler._ema_ms
    local b = Scheduler._adaptive or 1.5
    if ema < target * 0.85 then
        b = b + 0.15                                  -- headroom -> do more
    elseif ema > target then
        b = b * 0.8 - 0.05                            -- over budget -> back off fast
    end
    if b < minb then b = minb elseif b > maxb then b = maxb end
    Scheduler._adaptive = b
end"""

NEW = """    local maxb = tonumber(p.max_budget) or 8.0
    local minb = tonumber(p.min_budget) or 0.3
    local ema = Scheduler._ema_ms
    local b = Scheduler._adaptive or 1.5

    -- THE TARGET MUST BE WHAT THIS MACHINE ACTUALLY DOES, NOT 60 FPS.
    --
    -- This compared the frame time against a hardcoded 1000/60 = 16.7ms. The
    -- client here runs at a stable 30 fps (33.3ms/frame), so `ema > target` was
    -- true on EVERY frame forever, the controller ran `b = b*0.8 - 0.05` every
    -- frame, and the budget collapsed to the 0.3ms floor and stayed pinned there
    -- for the entire session.
    --
    -- What that cost: the pathfinder got 0.3ms per frame - about 9ms per second -
    -- so every A* hit its node cap and returned best-so-far. Live log: 149 of 151
    -- plans came back "partial waypoints=2" for goals ~80yd away, the 2-node stub
    -- ended inside the 18yd arrive radius, the route completed without the
    -- character moving, and the bot spent the session re-planning and drifting.
    -- It looked like a navigation bug. It was a budget bug.
    --
    -- The controller could not tell "this game runs at 30 fps" from "we are making
    -- frames slow", and assumed the latter - absence of headroom against an
    -- invented target read as evidence of our own guilt.
    --
    -- So: learn the baseline. Frames where we did essentially no work show what
    -- the machine costs WITHOUT us; the target is that plus a small allowance.
    -- Now the loop measures our actual impact instead of the machine's speed.
    local spent = Scheduler._last_spent_ms or 0
    if spent <= 0.2 then
        -- our own cost is negligible this frame: this is what the game costs alone
        Scheduler._baseline_ms = Scheduler._baseline_ms
            and (Scheduler._baseline_ms * 0.95 + dt_ms * 0.05) or dt_ms
    end

    local target
    if Scheduler._baseline_ms then
        -- 15% over what the game costs on its own, floored so an already-slow
        -- machine still gets a usable slice rather than being starved further.
        target = math.max(Scheduler._baseline_ms * 1.15, Scheduler._baseline_ms + 2.0)
    else
        -- No baseline yet. Fall back to the configured fps target, but honour a
        -- measured frame time over the assumption if we already have one.
        target = 1000 / (tonumber(p.target_fps) or 60)
        if ema and ema > target then target = ema + 2.0 end
    end
    Scheduler._target_ms = target

    if ema < target * 0.85 then
        b = b + 0.15                                  -- headroom -> do more
    elseif ema > target then
        b = b * 0.8 - 0.05                            -- over budget -> back off fast
    end
    if b < minb then b = minb elseif b > maxb then b = maxb end
    Scheduler._adaptive = b
end"""
assert OLD in s, "adaptive controller not found"
s = s.replace(OLD, NEW, 1)

# record what we actually spent each frame, so the baseline means something
OLD2 = """function Scheduler.over_budget()
    return (clock() - Scheduler._frame_start) >= budget_ms()
end"""
NEW2 = """function Scheduler.over_budget()
    return (clock() - Scheduler._frame_start) >= budget_ms()
end

-- How much of THIS frame we consumed. update_frame() uses it to recognise the
-- frames where we did nothing, which are the only honest measurement of what the
-- game costs without us.
function Scheduler.note_spent()
    Scheduler._last_spent_ms = (clock() - (Scheduler._frame_start or clock())) * 1.0
end"""
assert OLD2 in s
s = s.replace(OLD2, NEW2, 1)
p.write_text(s, encoding="utf-8")
print("Scheduler: budget target is the measured baseline, not an assumed 60fps")
