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
A.CAST_NO_ACQUIRE        = 16

local function parse_cast_result(res)
    if res == true or res == 1 or res == "true" then
        return true, "ok", 0
    end
    if type(res) == "string" then
        local okb, reason, cdMs = res:match("^(%d+)|([^|]+)|?(%d*)$")
        if okb then
            local cd = tonumber(cdMs) or 0
            return okb == "1", reason or "?", cd
        end
    end
    return false, "cast_fail", 0
end

function A.CastSpell(spellId, unitOrGuid)
    if not A.ensure() then
        print("|cff7ec8e3RaijinLab|r CastSpell: no runtime (inject in-world first)")
        return false
    end
    spellId = tonumber(spellId) or 0
    if spellId <= 0 then return false end
    -- FUNDAMENTAL: if a unit/GUID was requested, NEVER fall through to
    -- CastSpell(id) with no GUID (that hits current target - melee multi-dot bug).
    local had_unit = (unitOrGuid ~= nil and unitOrGuid ~= "" and unitOrGuid ~= 0)
    local g = guid_of(unitOrGuid)
    if had_unit and not g then
        return false
    end
    -- Native Spell_C_CastSpell only (no ExecSecure - re-enters Lua and crashed client).
    -- GUID path: Spell_C(guid) only - runtime does NOT TargetUnit / pin-select
    -- (acquire-off multi-dot). NO_TARGET_CHANGE restores if Spell_C stuck victim.
    local res
    if g then
        -- Acquire-off multi-dot: NO_TARGET_CHANGE only. Do NOT force SKIP/LOS -
        -- that made every unit cast refuse (face/los false-positives) while
        -- Consecration (guid=0) still fired. Lua BasicRules owns soft gates.
        local flags = A.CAST_NO_TARGET_CHANGE or 2
        local ex = rt("CastSpellEx", spellId, g, flags)
        if type(ex) == "string" then
            local okb = ex:match("^(%d+)|")
            return okb == "1"
        end
        res = rt("CastSpell", spellId, g)
    else
        res = rt("CastSpell", spellId)
    end
    if res == true or res == 1 or res == "true" then return true end
    return false
end

-- Authoritative cast: optional native face + skip if not facing + LoS.
-- Returns ok, reason ("ok"|"facing"|"los"|"oor"|"not_ready"|"cast_fail"|...).
-- flags: A.CAST_FACE_IF_NEEDED | A.CAST_SKIP_IF_NOT_FACING | A.CAST_CHECK_LOS
function A.CastSpellEx(spellId, unitOrGuid, flags)
    if not A.ensure() then return false, "no_runtime" end
    spellId = tonumber(spellId) or 0
    if spellId <= 0 then return false, "no_spell" end
    flags = tonumber(flags) or 0
    local had_unit = (unitOrGuid ~= nil and unitOrGuid ~= "" and unitOrGuid ~= 0)
    local g = guid_of(unitOrGuid)
    if had_unit and not g then
        return false, "bad_guid"
    end
    -- Omit guid arg when none (do not pass 0 - lua may tostring to "0" and
    -- older runtimes treated that as bad_guid, blocking Consecration).
    local res
    if g then
        res = rt("CastSpellEx", spellId, g, flags)
    else
        res = rt("CastSpellEx", spellId, nil, flags)
        if type(res) ~= "string" then
            res = rt("CastSpellEx", spellId, 0, flags)
        end
    end
    if type(res) ~= "string" then
        -- Old runtime: fall back to plain CastSpell
        local ok = A.CastSpell(spellId, unitOrGuid)
        return ok, ok and "ok" or "cast_fail", 0
    end
    local ok, reason, cdMs = parse_cast_result(res)
    return ok, reason, cdMs
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

-- Native-frame cast queue (2026-08-02, FINAL - user ABSOLUTE DIRECTIVE):
-- STAGE a cast. Spell_C is NEVER called from the Lua bridge. The native frame
-- hook (NativeHook.cpp TickHookBody, main thread, no Lua on the stack) drains
-- the queue and runs Spell_C from pure native context. This is the structural
-- fix for the 0x512B07 Lua-VM corruption (Spell_C's cast-feedback re-enters
-- FrameScript/Lua, which corrupts the VM when a bridge C-closure is on the
-- stack). The caller (Executor) has already done the Lua-side gates
-- (cooldown / facing / range / LoS); this path only queues.
-- Returns ok, reason ("ok"|"queue_full"|"bad_guid"|"no_spell"|"no_runtime").
function A.CastQueued(spellId, unitOrGuid, flags)
    if not A.ensure() then return false, "no_runtime" end
    spellId = tonumber(spellId) or 0
    if spellId <= 0 then return false, "no_spell" end
    flags = tonumber(flags) or 0
    local had_unit = (unitOrGuid ~= nil and unitOrGuid ~= "" and unitOrGuid ~= 0)
    local g = guid_of(unitOrGuid)
    if had_unit and not g then
        return false, "bad_guid"
    end
    local res
    if g then
        res = rt("CastQueued", spellId, g, flags)
    else
        res = rt("CastQueued", spellId, nil, flags)
        if type(res) ~= "string" then
            res = rt("CastQueued", spellId, 0, flags)
        end
    end
    if type(res) ~= "string" then
        return false, "no_runtime"
    end
    local ok = res:match("^1|") ~= nil
    local reason = res:match("^%d+|(.*)$") or "?"
    return ok, reason
end

-- Number of casts currently staged in the native queue (diagnostics; 0 = idle).
function A.CastQueueStatus()
    if not A.ensure() then return 0 end
    local res = rt("CastQueueStatus")
    return tonumber(res) or 0
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
    -- 2026-08-02 (TAINT + CRASH FIX): prefer resolving the spell NAME to an ID
    -- and casting NATIVELY via Spell_C (no ExecSecure). GetSpellInfo is a
    -- read-only query (never HW-gated / protected) and returns the spell ID as
    -- its 7th value on 3.3.5. The old name path used runtime ExecSecure
    -- (FrameScript_Execute from inside the bridge) - a nested-VM re-entry crash
    -- surface AND the "Tainted call to a secure function" source.
    -- THIS CLIENT'S GetSpellInfo RETURNS NO SPELL ID (verified live 2026-08-03).
    --
    -- The nine returns are: name, rank, icon, powerCost, isFunnel, powerType,
    -- castTime, minRange, maxRange - position 10 is nil. The comment above
    -- claimed the id arrived 7th, and through pcall (which shifts everything by
    -- one) slot 7 is powerType. So a name lookup produced an ID OF THE POWER
    -- TYPE: mana spells gave 0 (harmlessly falling through), but every energy
    -- spell resolved to id 3 and would have cast SPELL 3 instead of the spell
    -- asked for. Fabricating an id from an unrelated column is worse than
    -- having none, so the name is resolved through the runtime's own record
    -- store, and failing that left to the last-resort path below.
    local id = tonumber(name)
    if not id and RaijinLab and RaijinLab.SpellIdByName then
        local n = tonumber(RaijinLab.SpellIdByName(tostring(name)))
        if n and n > 0 then id = n end
    end
    if id then
        return A.CastSpell(id, unitOrGuid)
    end
    -- NO ExecSecure FALLBACK (2026-08-03).
    --
    -- ExecSecure is FrameScript_Execute driven from the bridge, and the comment
    -- 25 lines above already names it: "a nested-VM re-entry crash surface AND
    -- the 'Tainted call to a secure function' source". It was kept as a last
    -- resort, so the ONE path that taints the client was the path taken
    -- whenever a name could not be resolved - producing "RaijinLab tainted the
    -- call of the secure function" and the "blocked from an action only
    -- available to the Blizzard UI" popup, after which protected calls start
    -- answering nil to every addon in that execution path (which is what breaks
    -- GatherMate2 and XPerl, not any error of theirs).
    --
    -- An unresolvable name is a MISSING SPELL ID, and the honest answer to that
    -- is false. Refusing one cast is recoverable; tainting the client is not,
    -- and the directive is explicit that a red notification must be
    -- structurally impossible. Casting is by id, through the runtime, always.
    local DL = RaijinLab and RaijinLab.DevLog
    if DL and DL.log_every then
        DL.log_every("cast_name", 5.0, "cast",
            "cannot resolve %q to a spell id - refusing (native path only)",
            tostring(name))
    end
    return false
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
    -- Native only. The ExecSecure fallback that used to sit here is the
    -- documented taint source (see A.CastByName); a failed retarget is
    -- recoverable, a tainted client is not.
    return not not rt("TargetLastTarget")
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
    -- 2026-08-02 (NO BLOCKED ACTION): the runtime's "Attack" now STAGES the
    -- 6603 engage - the native frame hook runs Spell_C(6603) (no Lua on the
    -- stack). Calling it from the bridge origin was the client's protected
    -- "StartAttack" taint (blocked-action dialog; live "Attack engage nrc=0").
    return not not rt("Attack")
end

-- 2026-08-02: stage an explicit-GUID auto-attack engage (native hook runs it).
function A.AttackEngage(guid)
    if not A.ensure() then return false end
    local g = guid_of(guid)
    if not g then return false end
    return not not rt("AttackEngage", g)
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
    return not not rt("HaltMovement")
end

-- 2026-08-02 (NO BLOCKED ACTION): stage a NATIVE halt. The runtime's frame
-- hook (main thread, no Lua on the stack) releases every held movement key +
-- stops + commits. Calling MoveForward(false)/MouselookStop/StopMoving from
-- this Lua-dispatched RuntimeCall pops the "blocked from an action only
-- available to the Blizzard UI" dialog (client taint on bridge-origin calls to
-- protected APIs). The suite disable path uses this.
function A.HaltMovement()
    if not A.ensure() then return false end
    return not not rt("HaltMovement")
end

-- EVERY STEERING INPUT IS STAGED, NEVER DISPATCHED (2026-08-03).
--
-- USER DIRECTIVE: "literally all protected actions must properly run native
-- through runtime hooks. all modules in the suite."
--
-- The client judges the ORIGIN of a protected call, not its destination, so
-- dispatching MoveForwardStart across the bridge taints exactly as much as
-- calling it in Lua. That is why force_release popped the blocked-action
-- dialog on every suite-OFF while Master.halt_movement, which stages, did not.
--
-- StageInput records intent; the native frame hook diffs wanted against applied
-- and issues only real transitions, so re-asserting a heading every tick is
-- free and a staged halt clears all intent (nothing re-presses after a stop).
-- Fixing it HERE fixed all 30 Navigator sites at once - they route through
-- these wrappers already. Bit order matches Actions.h InputBit.
local function stage(bit, start)
    if not A.ensure() then return false end
    return not not rt("StageInput", bit, start and 1 or 0)
end

function A.MoveForward(start)
    if not A.ensure() then return false end
    return not not stage(0, start)
end

-- Vertical aim while swimming/flying. Hold-style like every other move key;
-- the runtime stops the opposite direction on start so the pair cannot wedge.
-- SetPitch (absolute) is NOT implemented in the runtime - it returns nil now
-- instead of a fake true - so depth control composes these holds instead.
function A.PitchUp(start)
    if not A.ensure() then return false end
    return not not stage(6, start)
end

function A.PitchDown(start)
    if not A.ensure() then return false end
    return not not stage(7, start)
end

function A.StrafeLeft(start)
    if not A.ensure() then return false end
    return not not stage(2, start)
end

function A.StrafeRight(start)
    if not A.ensure() then return false end
    return not not stage(3, start)
end

-- Turn (rotate the character) via the real client turn-key input - the "hold the
-- turn key" model, driven closed-loop by the Navigator. This is how steering
-- actually rotates the character; a raw FaceDirection memory write is ignored by
-- this client. NOT click-to-move.
function A.TurnLeft(start)
    if not A.ensure() then return false end
    return not not stage(4, start)
end

function A.TurnRight(start)
    if not A.ensure() then return false end
    return not not stage(5, start)
end

------------------------------------------------------------
-- Mouselook / camera-yaw steering - the analog, human turn. Hold mouselook and
-- the camera+character yaw follow smoothly; this is the ONLY variable-speed turn
-- in the engine (keyboard TurnLeft/Right is a single fixed rate). NOT click-to-move.
------------------------------------------------------------
function A.MouselookStart()
    if not A.ensure() then return false end
    return not not rt("HaltMovement")
end
function A.MouselookStop()
    if not A.ensure() then return false end
    return not not rt("HaltMovement")
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
    return not not rt("HaltMovement")
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
    -- ExecSecure REMOVED (2026-08-03). RunMacroText is protected, and driving
    -- it through FrameScript_Execute from the bridge is the taint source that
    -- pops "blocked from an action only available to the Blizzard UI" - after
    -- which protected calls answer nil to every addon sharing that execution
    -- path, which is what breaks GatherMate2 and XPerl. A macro slot that
    -- cannot run natively returns false; it never taints the client.
    local res = rt("RunMacroText", text)
    if res == true or res == 1 then return true end
    local DL = RaijinLab and RaijinLab.DevLog
    if DL and DL.log_every then
        DL.log_every("macro", 5.0, "cast",
            "RunMacroText has no native path - refusing (native path only)")
    end
    return false
end

if RaijinLab then
    RaijinLab.Actions = A
    -- Convenience mirrors on RaijinLab root used by older modules
    function RaijinLab:CastSpell(id, unit) return A.CastSpell(id, unit) end
    function RaijinLab:ObjectInteract(obj) return A.Interact(obj) end
    function RaijinLab:MoveTo(x, y, z) return A.MoveTo(x, y, z) end
    function RaijinLab:FaceDirection(a) return A.Face(a) end
    function RaijinLab:CastQueued(id, unit, flags) return A.CastQueued(id, unit, flags) end
end

return A
