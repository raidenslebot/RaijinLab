-- Input hooks. Multijump must NOT call stock JumpOrAscendStart/Strafe*/Move*
-- from addon context when those are taint-gated - route through Actions runtime.

function RaijinLab:CreateJumpHook()
    local oJump = JumpOrAscendStart
    JumpOrAscendStart = function()
        local A = RaijinLab.Actions
        if RaijinLab.multijump_toggle and IsFalling and IsFalling() then
            -- Never SetCVar from addon Lua (taint). Runtime or skip.
            if RaijinLab.RuntimeCall and RaijinLab.HasRuntime and RaijinLab:HasRuntime() then
                pcall(RaijinLab.RuntimeCall, RaijinLab, "SetCVarEx", "AutoInteract", "0")
            end
            if RaijinLab.StopFalling then RaijinLab:StopFalling() end
            if A then A.StopMoving() elseif StopMoving then StopMoving() end
            local getKey = function(vk)
                if RaijinLab.GetKeyState then return RaijinLab:GetKeyState(vk) end
                return false
            end
            if getKey(0x41) then
                if A then A.StrafeLeft(true) end
            elseif getKey(0x44) then
                if A then A.StrafeRight(true) end
            end
            if getKey(0x57) then
                if A then A.MoveForward(true) end
            end
            if A then
                A.Jump()
            elseif oJump then
                -- last resort only if runtime missing
                oJump()
            end
        else
            if A and A.available and A.available() then
                A.Jump()
            elseif oJump then
                oJump()
            end
        end
    end
end

function RaijinLab:CreateChatHook()
    oSendChatMessage = SendChatMessage
    SendChatMessage = function(msg, ...)
        if string.sub(msg, 1, 1) == "." then
            RaijinLab:RunCommand(string.sub(msg, 2))
            return
        end
        oSendChatMessage(msg, ...)
    end
end

function RaijinLab:CreateTrackAchievementHook()
    oAddTrackedAchievement = AddTrackedAchievement
    AddTrackedAchievement = function(...)
        RaijinLab.core_frame:GetScript("OnEvent")(RaijinLab.core_frame, "TRACKED_ACHIEVEMENT_UPDATE")
        oAddTrackedAchievement(...)
    end
end
