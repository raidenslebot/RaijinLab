from pathlib import Path

p = Path(r"C:\Ascension\Workspace\RaijinLab\addon\core\Navigator.lua")
s = p.read_text(encoding="utf-8")

OLD = """local function set_forward(on)
    if Navigator._moving == on then return end
    Navigator._moving = on
    local a = A(); if a and a.MoveForward then a.MoveForward(on) end
end"""

NEW = """-- COMMANDING FORWARD IS NOT MOVING FORWARD.
--
-- Actions.MoveForward -> runtime MoveForwardStart -> SafeVoid(), which returns 1
-- for "the call did not raise an exception". It never checks that the character
-- moved, so a primitive that does nothing reports success and the steering loop
-- happily believes it is driving.
--
-- Observed live: 273 ticks with fwd=true, heading error converged under 0.5rad
-- on 235 of them, and the position stayed at (1847.93, 1420.04) for sixteen
-- seconds while the client's own flag read moving=false. The loop was perfect
-- and the character never took a step. "It did nothing" was exactly right.
--
-- So verify the command against the world. This does not fix a dead primitive -
-- it makes it impossible for one to be silent, which is the only reason the
-- earlier sessions looked like a navigation bug.
Navigator._fwd_since = nil
Navigator._fwd_from = nil
Navigator.MOVE_PROVE_SECS = 1.5     -- held forward this long with no displacement = dead

local function set_forward(on)
    if Navigator._moving == on then return end
    Navigator._moving = on
    local a = A(); if a and a.MoveForward then a.MoveForward(on) end
    if on then
        local px, py = player_pos()
        Navigator._fwd_since = now()
        Navigator._fwd_from = px and { x = px, y = py } or nil
    else
        Navigator._fwd_since = nil
        Navigator._fwd_from = nil
    end
end

-- Did holding forward actually displace us? Three-valued: nil while we have not
-- held it long enough to judge, true once we have moved, false when the hold has
-- lasted long enough that a working primitive MUST have produced displacement.
function Navigator.forward_effective()
    if not (Navigator._moving and Navigator._fwd_since and Navigator._fwd_from) then
        return nil
    end
    local px, py = player_pos()
    if not px then return nil end
    local d = math.sqrt((px - Navigator._fwd_from.x) ^ 2 + (py - Navigator._fwd_from.y) ^ 2)
    if d > 1.0 then return true end
    if (now() - Navigator._fwd_since) < Navigator.MOVE_PROVE_SECS then return nil end
    return false
end"""
assert OLD in s, "set_forward not found"
s = s.replace(OLD, NEW, 1)
p.write_text(s, encoding="utf-8")
print("Navigator: forward is verified against actual displacement")

# ---- a contract that names it, with the exact remedy ----------------------
c = Path(r"C:\Ascension\Workspace\RaijinLab\addon\core\Contracts.lua")
t = c.read_text(encoding="utf-8")
A = """    C._installed = true
    return true
end"""
N = """    -- CAUGHT A WHOLE SESSION OF STANDING STILL: the steering loop commanded
    -- forward on 273 ticks, aimed correctly, and the character never moved one
    -- yard. The runtime's MoveForwardStart returns "success" for not throwing, so
    -- nothing anywhere could tell the difference between driving and pretending.
    Contract.invariant("forward_actually_moves", {
        when = function()
            local N = RL() and RL().Navigator
            return master_on() and N ~= nil and N.forward_effective ~= nil
                   and N.forward_effective() == false
        end,
        require = function() return false end,   -- reaching `when` IS the failure
        within = 3,
        explain = function()
            return "forward has been held for " ..
                tostring((RL().Navigator.MOVE_PROVE_SECS or 1.5)) ..
                "s with the character correctly aimed and it has not moved a yard. " ..
                "The movement primitive is not taking effect - MoveForwardStart " ..
                "returns success for 'did not crash', so this cannot be seen from " ..
                "its return value. Check the input handler address / hardware " ..
                "unlock in the injected runtime"
        end,
    })

    C._installed = true
    return true
end"""
assert A in t
c.write_text(t.replace(A, N, 1), encoding="utf-8")
print("Contracts: forward_actually_moves")
