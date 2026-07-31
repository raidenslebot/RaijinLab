-- Turn-primitive calibration experiment.
--
-- The engine offers several ways to change the character's heading, and only some
-- of them actually rotate the PLAYER (vs just the camera). Rather than guess, this
-- drives each lever for a fixed window and logs the true facing response (read via
-- the OM-independent ObjectFacing). One run tells us which mechanism turns the
-- character, by how much, and how SMOOTHLY (max per-tick step). The control layer
-- is then built on the winner. Results go to the dev log under the [diag] tag.
--
-- Levers tested: keyboard TurnLeft (fixed-rate baseline), camera target-yaw write
-- (no mouselook / with mouselook), and SendInput relative mouse-move under
-- mouselook (the human path). NEVER click-to-move.

local PI2 = math.pi * 2
local function now() return (GetTime and GetTime()) or 0 end
local function A() return RaijinLab and RaijinLab.Actions end
local function dlog(cat, ...) local DL = RaijinLab and RaijinLab.DevLog; if DL then DL.log(cat, ...) end end
local function facing()
    local f = RaijinLab and RaijinLab.ObjectFacing and RaijinLab:ObjectFacing("player")
    return (type(f) == "number") and f or nil
end
local function camyaw()
    local a = A(); return a and a.CameraYaw and a.CameraYaw() or nil
end
local function adiff(a, b)
    if not (a and b) then return 0 end
    local d = (b - a) % PI2; if d > math.pi then d = d - PI2 end; return d
end

-- Each phase: {name, dur, enter, tick, exit}. enter/tick/exit optional.
local function build_phases()
    local a = A()
    return {
        { name = "baseline", dur = 0.35 },
        { name = "kbd_turnleft", dur = 0.45,
          enter = function() a.TurnLeft(true) end,
          exit  = function() a.TurnLeft(false) end },
        { name = "settle", dur = 0.30, enter = function() a.StopMoving() end },
        { name = "camyaw_only", dur = 0.60,
          enter = function(s) s.c0 = camyaw(); if s.c0 and a.SetCameraYaw then a.SetCameraYaw(s.c0 + 1.5) end end },
        { name = "settle", dur = 0.30 },
        { name = "camyaw_mouselook", dur = 0.70,
          enter = function(s) if a.MouselookStart then a.MouselookStart() end
                             s.c0 = camyaw(); if s.c0 and a.SetCameraYaw then a.SetCameraYaw(s.c0 + 1.5) end end,
          exit  = function() if a.MouselookStop then a.MouselookStop() end end },
        { name = "settle", dur = 0.30 },
        { name = "sendinput_mouselook", dur = 0.70,
          enter = function() if a.MouselookStart then a.MouselookStart() end end,
          tick  = function() if a.MouseMove then a.MouseMove(30, 0) end end,
          exit  = function() if a.MouselookStop then a.MouselookStop() end
                             if a.CommitMovement then a.CommitMovement() end end },
        { name = "done", dur = 0.10, enter = function() a.StopMoving(); if a.MouselookStop then a.MouselookStop() end end },
    }
end

function RaijinLab:TurnDiag()
    local a = A()
    if not a then dlog("diag", "no Actions - runtime not ready"); return false end
    if not (CreateFrame and RaijinLab.ObjectFacing) then dlog("diag", "missing CreateFrame/ObjectFacing"); return false end
    if self._turndiag_frame then dlog("diag", "already running"); return false end

    local ml0 = a.IsMouselooking and a.IsMouselooking()
    dlog("diag", "=== TurnDiag start === facing=%s camyaw=%s mouselooking=%s (runtime should be 1.8.6+)",
        tostring(facing()), tostring(camyaw()), tostring(ml0))

    local phases = build_phases()
    local idx = 0
    local st                       -- current phase sample state
    local f = CreateFrame("Frame")
    self._turndiag_frame = f

    local function finish()
        f:SetScript("OnUpdate", nil)
        RaijinLab._turndiag_frame = nil
        -- safety: make sure nothing is left held
        pcall(function() a.StopMoving(); if a.TurnLeft then a.TurnLeft(false) end
            if a.TurnRight then a.TurnRight(false) end; if a.MouselookStop then a.MouselookStop() end end)
        dlog("diag", "=== TurnDiag done ===")
        if print then print("|cff7ec8e3RaijinLab|r turn calibration complete - see raijinlab_dev.log [diag]") end
    end

    local function enter_phase(i)
        local p = phases[i]
        st = { t0 = now(), fstart = facing(), cstart = camyaw(), fprev = facing(),
               maxstep = 0, samples = 0 }
        if p.enter then pcall(p.enter, st) end
        dlog("diag", "phase '%s' begin dur=%.2f facing=%s camyaw=%s mouselooking=%s",
            p.name, p.dur, tostring(st.fstart), tostring(st.cstart),
            tostring(a.IsMouselooking and a.IsMouselooking()))
    end

    local function exit_phase(i)
        local p = phases[i]
        if p.exit then pcall(p.exit, st) end
        local fend, cend = facing(), camyaw()
        local dfac = adiff(st.fstart, fend)
        local dcam = adiff(st.cstart, cend)
        dlog("diag", "phase '%s' END dfacing=%+.4f dcam=%+.4f maxstep=%.4f samples=%d turned=%s smooth=%s",
            p.name, dfac, dcam, st.maxstep, st.samples,
            tostring(math.abs(dfac) > 0.05),
            tostring(st.maxstep > 0 and st.maxstep < 0.35))
    end

    enter_phase(1); idx = 1
    f:SetScript("OnUpdate", function()
        local ok, err = pcall(function()
            local p = phases[idx]
            if p.tick then pcall(p.tick, st) end
            local fnow = facing()
            if fnow and st.fprev then
                local step = math.abs(adiff(st.fprev, fnow))
                if step > st.maxstep then st.maxstep = step end
            end
            st.fprev = fnow; st.samples = st.samples + 1
            if (now() - st.t0) >= p.dur then
                exit_phase(idx)
                idx = idx + 1
                if idx > #phases then finish() else enter_phase(idx) end
            end
        end)
        if not ok then
            dlog("diag", "ERROR: %s", tostring(err))
            finish()
        end
    end)
    return true
end
