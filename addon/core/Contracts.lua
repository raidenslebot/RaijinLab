-- Contracts - what this bot promises to observably do.
--
-- Each entry here exists because a REAL failure got past every test and every
-- review and was found by a human staring at the game. The comment on each one
-- names the failure it would have caught. If a new class of "it just does
-- nothing" shows up, the fix is not only the bug - it is a contract here, so that
-- class can never be silent again.

local C = {}

local function RL() return RaijinLab end
local function db() return RaijinLabDB or {} end
local function mods() return (db().modules) or {} end
local function master_on()
    local M = RL() and RL().Master
    if not M then return true end
    return M.enabled()
end
local function now() return (GetTime and GetTime()) or 0 end

local function ppos()
    local R = RL()
    if not (R and R.ObjectPosition) then return nil end
    local x, y, z = R:ObjectPosition("player")
    return x, y, z
end

-- Position-change detector shared by the movement contracts.
local moved = { x = nil, y = nil, t = 0 }
local function position_changed()
    local x, y = ppos()
    if not x then return true end                  -- cannot tell -> do not accuse
    if moved.x and ((x - moved.x) ^ 2 + (y - moved.y) ^ 2) > (3 * 3) then
        moved.x, moved.y = x, y
        return true
    end
    if not moved.x then moved.x, moved.y = x, y; return true end
    return false
end

local function in_world()
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then return false end
    local x = ppos()
    return x ~= nil
end

function C.install()
    local Contract = RL() and RL().Contract
    if not Contract then return false end

    -- =====================================================================
    -- LIVENESS. Seven subsystems logged ZERO lines across a 166-minute live
    -- session and nothing noticed, because silence and idleness look identical.
    -- =====================================================================
    Contract.liveness("nav", function()
        return master_on() and (mods().quest or mods().grind or mods().gather)
    end, 120, function()
        return "navigation has emitted nothing while a module that must travel is " ..
               "enabled - the movement stack is probably never being invoked"
    end)

    Contract.liveness("rot", function()
        return master_on() and mods().rotation
    end, 120, function()
        return "the rotation engine is ON but silent - it is not ticking"
    end)

    Contract.liveness("quest", function()
        return master_on() and mods().quest
    end, 120, function()
        return "questing is ON but silent - the quest engine is not ticking"
    end)

    Contract.liveness("director", function()
        return master_on() and (mods().quest or mods().grind)
    end, 120, function()
        return "the goal director is silent - nothing is choosing what to do"
    end)

    -- =====================================================================
    -- BEHAVIOUR
    -- =====================================================================

    -- CAUGHT NOTHING FOR 166 MINUTES: a level-1 character stood in Deathknell
    -- because the quest objective was never in range and nothing was remembered,
    -- so no destination was ever produced. 92% of samples were stationary and the
    -- bot reported itself as working the whole time.
    Contract.invariant("moves_while_working", {
        when = function()
            if not (master_on() and in_world()) then return false end
            if not (mods().quest or mods().grind or mods().gather) then return false end
            if UnitAffectingCombat and UnitAffectingCombat("player") then return false end
            local M = RL() and RL().Mount
            if M and M.is_mounted and M.is_mounted() then return true end
            return true
        end,
        require = position_changed,
        within = 90,
        explain = function()
            local why = "a travelling module is enabled but the character has not " ..
                        "moved for 90s and is not in combat"
            local S = RL() and RL().QuestSuite
            if S and S.state then why = why .. " (quest state: " .. tostring(S.state) .. ")" end
            return why
        end,
    })

    -- CAUGHT 2671 TIMES AND ACTED ON ZERO: the active rotation held no spells
    -- while two populated ones sat beside it. The executor warned every tick and
    -- never switched.
    Contract.invariant("rotation_can_act", {
        when = function() return master_on() and mods().rotation end,
        require = function()
            local E = RL() and RL().RotationExecutor
            if not (E and E.get_active_rotation) then return true end   -- cannot judge
            local ok, rot = pcall(E.get_active_rotation)
            if not ok or type(rot) ~= "table" then return false end
            for _, sl in ipairs(rot.slots or {}) do
                if (tonumber(sl.spell_id) or 0) ~= 0 then return true end
            end
            return false
        end,
        within = 20,
        explain = function()
            return "the rotation engine is ON but the rotation it resolves has no " ..
                   "spells - it cannot cast anything, ever"
        end,
    })

    -- CAUGHT A SESSION OF LOST WORK: rotations live per LOGIN ACCOUNT, so logging
    -- in on another account shows an empty set and reads as deletion. The backup
    -- is account-independent, so if IT is richer than the live DB, work is
    -- sitting on disk unrestored.
    Contract.invariant("no_unrestored_rotations", {
        when = function()
            local CB = RL() and RL().ConfigBackup
            return CB ~= nil and CB.count_rotations ~= nil
        end,
        require = function()
            local CB = RL().ConfigBackup
            local live = CB.count_rotations(db()) or 0
            local snap = CB._contract_best
            if snap == nil then
                local ok, best = pcall(CB.best)
                snap = (ok and best) or false
                CB._contract_best = snap      -- reading 3 files is not a 1Hz job
            end
            if not snap then return true end
            return live >= (CB.count_rotations(snap) or 0)
        end,
        within = 30,
        explain = function()
            local CB = RL().ConfigBackup
            local live = CB.count_rotations(db()) or 0
            local snap = CB._contract_best
            local have = (snap and CB.count_rotations(snap)) or 0
            return string.format(
                "the backup holds %d real rotation(s) but only %d are loaded - your " ..
                "work is on disk and unrestored (rotations are saved PER LOGIN " ..
                "ACCOUNT; /raijin config restore)", have, live)
        end,
    })

    -- CAUGHT 16438 DIRECTOR LINES: the errand goal claimed a band every tick on a
    -- need it could never act on, preempting real work 3x a second.
    Contract.invariant("goals_produce_work", {
        when = function()
            local D = RL() and RL().Director
            return master_on() and D ~= nil and (mods().quest or mods().grind)
        end,
        require = function()
            local D = RL().Director
            local n = D._fallthrough_n or 0
            local prev = C._ft_prev
            C._ft_prev = n
            if prev == nil then return true end
            return (n - prev) < 30          -- >30 fall-throughs in a window = churn
        end,
        within = 30,
        explain = function()
            return "a goal keeps claiming it has work and then doing nothing " ..
                   "(director fall-through churn) - its evaluate() and run() disagree"
        end,
    })

    -- CAUGHT A WHOLE SESSION OF STANDING STILL: a level-1 character owns a mount
    -- but may not ride it, and every attempt stopped movement first.
    Contract.invariant("mount_not_looping", {
        when = function()
            local M = RL() and RL().Mount
            return master_on() and M ~= nil
        end,
        require = function()
            local M = RL().Mount
            return (M._blocks or 0) < 3
        end,
        within = 30,
        severity = "warn",
        explain = function()
            local M = RL().Mount
            local sk = M.has_riding_skill and M.has_riding_skill()
            return "mounting has been given up on " .. tostring(M._blocks) ..
                   " times (riding skill: " .. tostring(sk) .. ") - travelling on foot"
        end,
    })

    -- CAUGHT THE OSCILLATION: the steering loop closed on a dead-reckoned heading
    -- that was 155 degrees stale, so commanded turns never converged.
    Contract.invariant("turning_actually_turns", {
        when = function()
            local N = RL() and RL().Navigator
            return master_on() and N ~= nil and N.state == "moving"
                   and (N._last_turn_cmd or 0) ~= 0
        end,
        require = function()
            local N = RL().Navigator
            local h = N._facing_real
            local prev = C._head_prev
            C._head_prev = h
            if prev == nil or h == nil then return true end
            return math.abs(N.angle_diff(prev, h)) > 0.01
        end,
        within = 20,
        explain = function()
            return "a turn is being commanded every tick but the measured heading " ..
                   "is not changing - the steering loop is open"
        end,
    })

    -- THE READING THE WHOLE BOT STANDS ON. A wrong player position makes every
    -- other subsystem behave correctly for a world the character is not in.
    -- Observed: runtime latched obj+0x48 ~ (0,0,0) while camera sat in-zone.
    -- Use the *streak* of consecutive bad reads, not lifetime _badpos - a fixed
    -- layout must let the suite recover without /reload.
    Contract.invariant("position_is_real", {
        when = function() return master_on() and in_world() end,
        require = function()
            local R = RL()
            if not R then return false end
            -- Probe once so streak reflects the current frame, not stale state.
            if R.ObjectPosition then pcall(function() R:ObjectPosition("player") end) end
            return (R._badpos_streak or 0) < 30
        end,
        within = 20,
        explain = function()
            local R = RL()
            return "player position disagrees with the camera for " ..
                   tostring(R and R._badpos_streak or 0) ..
                   " consecutive reads (lifetime rejects " ..
                   tostring(R and R._badpos or 0) ..
                   ") - navigation is frozen until the runtime pos layout re-pins; re-inject 1.8.14+"
        end,
    })

    -- CAUGHT NOTHING FOR MANY SESSIONS: quest giver detection reads a runtime
    -- command that is a hardcoded `return 0` stub, so no quest could ever be
    -- accepted or handed in. Nothing anywhere counted the zeros, so it looked
    -- exactly like "no quest givers nearby" forever.
    Contract.invariant("quest_giver_detection_alive", {
        when = function()
            local Q = RL() and RL().QuestOM
            -- Only fire when status is proven dead AND we have no candidate
            -- path either - idle wait with a working greet fallback is not a
            -- hard contract kill. The red banner made "quest on" look broken.
            if not (master_on() and mods().quest and Q ~= nil
                    and Q.status_source_alive ~= nil
                    and Q.status_source_alive() == false) then
                return false
            end
            if Q.candidate_giver then
                local ok, c = pcall(Q.candidate_giver)
                if ok and c and c.guid then return false end  -- still have a plan
            end
            return true
        end,
        require = function() return false end,   -- reaching `when` IS the failure
        within = 30,
        explain = function()
            local Q = RL().QuestOM
            return string.format(
                "quest-giver status empty (%d reads, all 0) and no greet " ..
                "candidates. Re-inject 1.8.23-qg (status query was blocked when " ..
                "NPC pos failed). Target a lit !/? : /raijin quest giverprobe",
                Q._status_asked or 0)
        end,
    })

    -- CAUGHT A WHOLE SESSION OF STANDING STILL: the steering loop commanded
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
end

if RaijinLab then RaijinLab.Contracts = C end
return C
