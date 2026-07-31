-- RaijinLab.Actions - SINGLE entry point for every taint-sensitive action.
--
-- RULE: Addon Lua must NEVER call FrameScript protected APIs directly:
--   CastSpell*, UseAction, TargetUnit, ClearTarget, AttackTarget, StartAttack,
--   InteractUnit, JumpOrAscendStart, MoveForward*, Strafe*, RunMacroText, etc.
--
-- ALL of those go through the injected runtime (Spell_C_CastSpell, CTM, movement
-- fns, or C-side FrameScript_Execute with origin "*").

local A = {}

local function rt(name, ...)
    if not RaijinLab or type(RaijinLab.RuntimeCall) ~= "function" then return nil end
    if not RaijinLab:HasRuntime() then return nil end
    -- Direct call - avoid nested pcall/vararg bugs that swallowed bool returns
    local ok, a = pcall(RaijinLab.RuntimeCall, RaijinLab, name, ...)
    if not ok then
        if RaijinLab._debug_print then
            print("|cff7ec8e3RaijinLab|r rt error " .. tostring(name) .. ": " .. tostring(a))
        end
        return nil
    end
    return a
end

local function guid_of(unitOrGuid)
    if unitOrGuid == nil then return nil end
    if type(unitOrGuid) == "number" and unitOrGuid > 0 then
        return string.format("0x%X", unitOrGuid)
    end
    local s = tostring(unitOrGuid)
    -- Normalize pure hex / 0x hex for Spell_C_CastSpell GuidArg.
    if s:match("^0[xX]%x+$") then
        return "0x" .. string.upper(s:sub(3))
    end
    if s:match("^%x%x%x%x+$") and not s:match("^nameplate") and not s:match("^party")
        and not s:match("^raid") and not s:match("^boss") then
        return "0x" .. string.upper(s)
    end
    -- Unit token
    if UnitGUID and UnitExists and UnitExists(s) then
        return UnitGUID(s)
    end
    if UnitGUID then
        local g = UnitGUID(s)
        if g then return g end
    end
    return nil
end

function A.ensure()
    if A._armed then return true end
    if not (RaijinLab and RaijinLab.HasRuntime and RaijinLab:HasRuntime()) then
        return false
    end
    rt("ArmUnlock")
    A._armed = true
    return true
end

function A.available()
    return RaijinLab and RaijinLab.HasRuntime and RaijinLab:HasRuntime()
end

------------------------------------------------------------
-- Spells
------------------------------------------------------------
-- Cast flags (match runtime Actions.h)
A.CAST_FACE_IF_NEEDED    = 1
A.CAST_NO_TARGET_CHANGE  = 2
A.CAST_SKIP_IF_NOT_FACING = 4
A.CAST_CHECK_LOS         = 8

local function parse_cast_result(res)
    if res == true or res == 1 or res == "true" then
        return true, "ok"
    end
    if type(res) == "string" then
        local okb, reason = res:match("^(%d+)|(.+)$")
        if okb then
            return okb == "1", reason or "?"
        end
    end
    return false, "cast_fail"
end

function A.CastSpell(spellId, unitOrGuid)
    if not A.ensure() then
        print("|cff7ec8e3RaijinLab|r CastSpell: no runtime (inject in-world first)")
        return false
    end
    spellId = tonumber(spellId) or 0
    if spellId <= 0 then return false end
    local g = guid_of(unitOrGuid)
    -- Native Spell_C_CastSpell only (no ExecSecure - re-enters Lua and crashed client)
    local res
    if g then
        res = rt("CastSpell", spellId, g)
    else
        res = rt("CastSpell", spellId)
    end
    if res == true or res == 1 or res == "true" then return true end
    return false
end

-- Authoritative cast: optional native face + skip if not facing + LoS.
-- Returns ok, reason ("ok"|"facing"|"los"|"oor"|"cast_fail"|...).
-- flags: A.CAST_FACE_IF_NEEDED | A.CAST_SKIP_IF_NOT_FACING | A.CAST_CHECK_LOS
function A.CastSpellEx(spellId, unitOrGuid, flags)
    if not A.ensure() then return false, "no_runtime" end
    spellId = tonumber(spellId) or 0
    if spellId <= 0 then return false, "no_spell" end
    flags = tonumber(flags) or 0
    local g = guid_of(unitOrGuid)
    local res = rt("CastSpellEx", spellId, g or 0, flags)
    if type(res) ~= "string" then
        -- Old runtime: fall back to plain CastSpell
        local ok = A.CastSpell(spellId, unitOrGuid)
        return ok, ok and "ok" or "cast_fail"
    end
    return parse_cast_result(res)
end

function A.CanCast(spellId, unitOrGuid, flags)
    if not A.ensure() then return false, "no_runtime" end
    spellId = tonumber(spellId) or 0
    if spellId <= 0 then return false, "no_spell" end
    flags = tonumber(flags) or 0
    local g = guid_of(unitOrGuid)
    local res = rt("CanCast", spellId, g or 0, flags)
    if type(res) ~= "string" then return true, "ok" end -- unknown API: allow
    return parse_cast_result(res)
end

function A.FaceTowardGuid(unitOrGuid)
    if not A.ensure() then return false end
    local g = guid_of(unitOrGuid)
    if not g then return false end
    local res = rt("FaceTowardGuid", g)
    return res == true or res == 1 or res == "true"
end

function A.IsFacingGuid(unitOrGuid, halfArc)
    if not A.ensure() then return nil end
    local g = guid_of(unitOrGuid)
    if not g then return false end
    local res = rt("IsFacingGuid", g, halfArc or 1.5707963)
    if res == nil then return nil end
    return res == true or res == 1 or res == "true"
end

function A.CastSpellByName(name, unitOrGuid)
    if not name or name == "" then return false end
    local id = nil
    if GetSpellInfo then
        -- reverse lookup not stock; try known book id if provided as number-string
        id = tonumber(name)
    end
    if not id and GetSpellLink then
        -- leave name path to ExecSecure cast by name ONLY via runtime
        if not A.ensure() then return false end
        local g = guid_of(unitOrGuid)
        local code
        if g then
            -- still prefer id if GetSpellInfo from name via link scan fails
            code = string.format("CastSpellByName(%q)", name)
        else
            code = string.format("CastSpellByName(%q)", name)
        end
        -- Prefer resolving spell id from name via GetSpellInfo reverse is hard;
        -- use runtime ExecSecure which is C-origin "*"
        return not not rt("ExecSecure", code)
    end
    if id then return A.CastSpell(id, unitOrGuid) end
    if not A.ensure() then return false end
    return not not rt("ExecSecure", string.format("CastSpellByName(%q)", tostring(name)))
end

function A.StopCasting()
    if not A.ensure() then return false end
    return not not rt("SpellStopCasting")
end

------------------------------------------------------------
-- Targeting / combat
------------------------------------------------------------
function A.Target(unitOrGuid)
    if not A.ensure() then return false end
    if unitOrGuid == nil then return false end
    local s = tostring(unitOrGuid)
    -- 1) Unit token path (nameplate1, target, boss1): most reliable on Ascension.
    if type(unitOrGuid) == "string" and s ~= "" and not s:match("^0[xX]%x+$") then
        if UnitExists and UnitExists(s) then
            if rt("TargetToken", s) then return true end
            -- Fall through to GUID if token TargetUnit failed.
            local g = UnitGUID and UnitGUID(s)
            if g and rt("TargetGuid", g) then return true end
            return false
        end
        -- Not a live token - treat as name.
        return not not rt("TargetByName", s)
    end
    -- 2) Explicit GUID
    local g = guid_of(unitOrGuid)
    if g then return not not rt("TargetGuid", g) end
    return false
end

function A.ClearTarget()
    if not A.ensure() then return false end
    return not not rt("ClearTarget")
end

-- Restore previous client selection after a GUID cast (Spell_C often selects
-- the cast victim). Stock TargetLastTarget is more reliable than TargetUnit(hex).
function A.TargetLastTarget()
    if not A.ensure() then return false end
    if rt("TargetLastTarget") then return true end
    return not not rt("ExecSecure", "TargetLastTarget()")
end

-- Snapshot + cast + restore selection when preserveSelection is true.
-- Used by multi-dot with acquire_target OFF so the client target never sticks
-- on the cast victim.
function A.CastSpellPreserveSelection(spellId, unitOrGuid, flags)
    local had = UnitExists and UnitExists("target")
    local prev = (had and UnitGUID and UnitGUID("target")) or nil
    local ok, reason
    if flags ~= nil and A.CastSpellEx then
        ok, reason = A.CastSpellEx(spellId, unitOrGuid, flags)
    else
        ok = A.CastSpell(spellId, unitOrGuid)
        reason = ok and "ok" or "cast_fail"
    end
    if not ok then return false, reason end
    -- Immediate restore (Spell_C may select mid-call).
    if had and prev then
        local cur = (UnitExists and UnitExists("target") and UnitGUID and UnitGUID("target")) or nil
        if not cur or tostring(cur) ~= tostring(prev) then
            -- Prefer last-target (native stack), then GUID, then clear+retarget.
            if not A.TargetLastTarget() then
                A.Target(prev)
            end
            cur = (UnitExists and UnitExists("target") and UnitGUID and UnitGUID("target")) or nil
            if cur and tostring(cur) ~= tostring(prev) then
                A.ClearTarget()
                A.Target(prev)
            end
        end
    else
        -- Had no target: never leave a sticky selection from the cast.
        if UnitExists and UnitExists("target") then
            A.ClearTarget()
        end
    end
    return true, reason or "ok"
end

function A.Attack()
    if not A.ensure() then return false end
    return not not rt("Attack")
end

function A.StopAttack()
    if not A.ensure() then return false end
    return not not rt("StopAttack")
end

------------------------------------------------------------
-- Interact
------------------------------------------------------------
-- Compare two GUIDs written in different styles ("0x00F1..." vs "F1...", case
-- differing). Returns nil when either side is unreadable, so callers can tell
-- "mismatch" apart from "cannot tell" - those are different answers.
function A.guid_same(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then return nil end
    local function norm(s)
        s = string.lower(s)
        s = string.gsub(s, "^0x", "")
        s = string.gsub(s, "^0+", "")
        return s
    end
    local na, nb = norm(a), norm(b)
    if na == "" or nb == "" then return nil end
    return na == nb
end

-- Does this string already look like a GUID, as opposed to a unit token?
-- "0xF130001A" / "F130001A" -> yes; "target" / "player" / "boss1" -> no.
-- Used to stop a unit token being handed onward as though it were a GUID: the
-- runtime's GuidArg special-cases only "player", so every other token parses
-- as 0 and the call quietly answers about nothing.
function A.looks_like_guid(s)
    if type(s) ~= "string" or s == "" then return false end
    return string.find(s, "^0?[xX]?%x+$") ~= nil
end

-- VERIFY THE OUTCOME, DO NOT TRUST THE RETURN.
--
-- The runtime now answers honestly about whether it DISPATCHED an interact, but
-- dispatching is not succeeding: the bridge's `true` still only means the Lua
-- handler did not throw. That is the same "in range and confident but means no
-- answer" shape that has produced most of this project's live defects, one level
-- up from where it was fixed.
--
-- There is a decisive check available here that the C++ side does not have: if
-- we asked to interact with a specific unit, that unit must be our target
-- afterwards. Targeting goes through TargetUnit, so a failure there makes the
-- interact meaningless no matter what the handler returned. `UnitGUID` is a
-- plain 3.3.5 API and authoritative.
--
-- When the target cannot be read at all we return the dispatch result unchanged
-- rather than inventing a failure - absence of evidence is not evidence of
-- absence, which is the OTHER recurring defect in this codebase.
function A.Interact(unitOrGuid)
    if not A.ensure() then return false end
    local g = guid_of(unitOrGuid)
    if not g then return not not rt("InteractTarget") end
    local dispatched = not not rt("Interact", g)
    if not dispatched then return false end
    if not UnitGUID then return true end
    local tg = UnitGUID("target")
    if not tg then
        -- We asked for a specific unit and ended up with NO target: the
        -- TargetUnit step did not take, so nothing was interacted with.
        return false
    end
    local same = A.guid_same(tg, g)
    if same == false then return false end
    return true
end

------------------------------------------------------------
-- Movement
------------------------------------------------------------
-- CTM FORBIDDEN. Route through keyboard Navigator only.
function A.MoveTo(x, y, z)
    local N = RaijinLab and RaijinLab.Navigator
    if N and N.move_to and x and y then
        return not not N.move_to({ x = x, y = y, z = z or 0 }, { force_forward = true })
    end
    return false
end

function A.Face(radians)
    if not A.ensure() then return false end
    return not not rt("FaceDirection", radians)
end

-- Land hop (one-shot). Do NOT use this for continuous swim-up.
function A.Jump()
    if not A.ensure() then return false end
    return not not rt("Jump")
end

-- Swim vertical is HELD, same model as MoveForward(start):
--   Ascend(true/false)  -> JumpOrAscendStart / AscendStop
--   Descend(true/false) -> SitStandOrDescendStart / DescendStop
-- A one-shot Jump pulse while swimming is not "depth control" - the client only
-- keeps rising while the ascend key is held.
function A.Ascend(start)
    if not A.ensure() then return false end
    return not not rt(start and "AscendStart" or "AscendStop")
end

function A.Descend(start)
    if not A.ensure() then return false end
    return not not rt(start and "DescendStart" or "DescendStop")
end

function A.StopMoving()
    if not A.ensure() then return false end
    return not not rt("StopMoving")
end

function A.MoveForward(start)
    if not A.ensure() then return false end
    return not not rt(start and "MoveForwardStart" or "MoveForwardStop")
end

-- Vertical aim while swimming/flying. Hold-style like every other move key;
-- the runtime stops the opposite direction on start so the pair cannot wedge.
-- SetPitch (absolute) is NOT implemented in the runtime - it returns nil now
-- instead of a fake true - so depth control composes these holds instead.
function A.PitchUp(start)
    if not A.ensure() then return false end
    return not not rt(start and "PitchUpStart" or "PitchUpStop")
end

function A.PitchDown(start)
    if not A.ensure() then return false end
    return not not rt(start and "PitchDownStart" or "PitchDownStop")
end

function A.StrafeLeft(start)
    if not A.ensure() then return false end
    return not not rt(start and "StrafeLeftStart" or "StrafeLeftStop")
end

function A.StrafeRight(start)
    if not A.ensure() then return false end
    return not not rt(start and "StrafeRightStart" or "StrafeRightStop")
end

-- Turn (rotate the character) via the real client turn-key input - the "hold the
-- turn key" model, driven closed-loop by the Navigator. This is how steering
-- actually rotates the character; a raw FaceDirection memory write is ignored by
-- this client. NOT click-to-move.
function A.TurnLeft(start)
    if not A.ensure() then return false end
    return not not rt(start and "TurnLeftStart" or "TurnLeftStop")
end

function A.TurnRight(start)
    if not A.ensure() then return false end
    return not not rt(start and "TurnRightStart" or "TurnRightStop")
end

------------------------------------------------------------
-- Mouselook / camera-yaw steering - the analog, human turn. Hold mouselook and
-- the camera+character yaw follow smoothly; this is the ONLY variable-speed turn
-- in the engine (keyboard TurnLeft/Right is a single fixed rate). NOT click-to-move.
------------------------------------------------------------
function A.MouselookStart()
    if not A.ensure() then return false end
    return not not rt("MouselookStart")
end
function A.MouselookStop()
    if not A.ensure() then return false end
    return not not rt("MouselookStop")
end
function A.IsMouselooking()
    return rt("IsMouselooking") == 1
end
function A.CameraYaw()            -- current smoothed camera yaw (rad), or nil
    local y = rt("CameraYaw")
    if type(y) == "number" and y < 1e8 then return y end
    return nil
end
function A.CameraTargetYaw()
    local y = rt("CameraTargetYaw")
    if type(y) == "number" and y < 1e8 then return y end
    return nil
end
function A.SetCameraYaw(rad)
    if not A.ensure() then return false end
    return not not rt("SetCameraYaw", rad)
end
function A.CommitMovement()
    if not A.ensure() then return false end
    return not not rt("CommitMovement")
end
function A.MouseMove(dx, dy)      -- synthesize a relative OS mouse move (mickeys)
    if not A.ensure() then return false end
    return not not rt("MouseMove", dx or 0, dy or 0)
end

-- In-process yaw turn: rotate the character by a radian delta this frame WITHOUT
-- the OS mouse or cursor capture (so the user's physical mouse stays free), synced
-- to the server. + = left/CCW. This is the primary steering turn primitive.
function A.TurnByDelta(rad)
    if not A.ensure() then return false end
    return not not rt("TurnByDelta", rad or 0)
end
-- Live, CAMERA-INDEPENDENT player facing (rad), or nil if unavailable.
function A.PlayerFacing()
    local f = rt("PlayerFacing")
    if type(f) == "number" and f < 1e8 then return f end
    return nil
end

-- Escape hatch: only for macros the user explicitly configured.
-- Still runtime C-origin - never raw RunMacroText from addon.
function A.RunMacroText(text)
    if not text or text == "" then return false end
    if not A.ensure() then return false end
    return not not rt("ExecSecure", string.format("RunMacroText(%q)", text))
end

if RaijinLab then
    RaijinLab.Actions = A
    -- Convenience mirrors on RaijinLab root used by older modules
    function RaijinLab:CastSpell(id, unit) return A.CastSpell(id, unit) end
    function RaijinLab:ObjectInteract(obj) return A.Interact(obj) end
    function RaijinLab:MoveTo(x, y, z) return A.MoveTo(x, y, z) end
    function RaijinLab:FaceDirection(a) return A.Face(a) end
end

return A
