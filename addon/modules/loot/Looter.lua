-- Pulse only when looter enabled. Empty area: back off (no LoS thrash).
local private = { delay = 0.65, empty_streak = 0 }
RaijinLab.looter = {}

if not RaijinLabDB.looter then
    RaijinLabDB.looter = {
        move_to_loot = false
    }
end

-- Distance-first loot pick. NEVER TraceLine every object — that was the loot
-- lag spike (LoS fan across full interactable + NPC lists every 0.5s).
-- Sort by distance, then LoS only the nearest few candidates.
local function dist_player(object)
    if not object or not RaijinLab.GetDistanceBetweenObjects then return nil end
    local ok, d = pcall(RaijinLab.GetDistanceBetweenObjects, RaijinLab, "player", object)
    if ok and type(d) == "number" then return d end
    return nil
end

-- No TraceLine on loot scan. Interact at feet (≤5yd) is always attempted;
-- longer-range LoS was the walk/loot FPS spike.
local function pick_nearest(cands)
    if not cands or #cands == 0 then return nil end
    table.sort(cands, function(a, b) return (a.distance or 999) < (b.distance or 999) end)
    return cands[1]
end

local function GetLootableUnit()
    local cands = {}

    -- 1) Interactable list (GO / quest) — distance only, no LoS yet.
    local interactable_units = RaijinLab.GetInteractableObjects
        and RaijinLab:GetInteractableObjects() or {}
    for i = 1, #interactable_units do
        local struct = interactable_units[i]
        if struct and struct.Object then
            local is_good_go = true
            if struct.Type and struct.Type.base_type and struct.Type.base_type.name == "GameObject" then
                if not (struct.Info and struct.Info.Quest and struct.Info.Quest.IsTiedToQuest) then
                    is_good_go = false
                end
            end
            if is_good_go then
                local d = dist_player(struct.Object)
                if d and d <= 15 then
                    cands[#cands + 1] = { object = struct.Object, distance = d }
                end
            end
        end
    end

    local best = pick_nearest(cands)
    if best and best.distance and best.distance <= 10 then
        private.lootable_unit = best
        private.empty_streak = 0
        return
    end

    -- 2) Dead lootable NPCs from OM list — distance only (no TraceLine).
    cands = {}
    local npcs = RaijinLab.om and RaijinLab.om.object_list and RaijinLab.om.object_list.npcs
    if npcs then
        local n = #npcs
        -- Cap scan work when OM is huge (walk/loot FPS).
        local lim = math.min(n, 48)
        for i = 1, lim do
            local struct = npcs[i]
            if struct and struct.Object
                and struct.Info and struct.Info.Unit
                and struct.Info.Unit.Dead and struct.Info.Unit.Lootable then
                local d = dist_player(struct.Object)
                if d and d <= 12 then
                    cands[#cands + 1] = { object = struct.Object, distance = d }
                end
            end
        end
    end
    private.lootable_unit = pick_nearest(cands)
    if private.lootable_unit then
        private.empty_streak = 0
    else
        private.empty_streak = (private.empty_streak or 0) + 1
    end
end

local function Gather()
    GetLootableUnit()
    if not private.combat and private.lootable_unit ~= nil and not UnitIsDeadOrGhost("player") then
        local distance = private.lootable_unit.distance
        if not distance then
            private.lootable_unit = nil
            RaijinLab.HAS_LOOTABLE_UNIT = false
            return
        end
        if distance <= 5 then
            RaijinLab.HAS_LOOTABLE_UNIT = true
            if RaijinLab.Actions and RaijinLab.Actions.StopMoving then
                pcall(RaijinLab.Actions.StopMoving)
            elseif RaijinLab.StopMoving then
                pcall(RaijinLab.StopMoving, RaijinLab)
            end
            if RaijinLab.Actions then
                RaijinLab.Actions.Interact(private.lootable_unit.object)
            elseif RaijinLab.ObjectInteract then
                RaijinLab:ObjectInteract(private.lootable_unit.object)
            end
            private.lootable_unit = nil
        elseif distance < 10 and RaijinLabDB.looter.move_to_loot then
            RaijinLab.HAS_LOOTABLE_UNIT = true
            local x, y, z = RaijinLab:ObjectPosition(private.lootable_unit.object)
            local Nav = RaijinLab.Nav
            if x and Nav and Nav.request_move then
                Nav.request_move({ x = x, y = y, z = z }, { arrive_dist = 3.0 })
            end
        else
            RaijinLab.HAS_LOOTABLE_UNIT = false
        end
    else
        RaijinLab.HAS_LOOTABLE_UNIT = false
    end
end

local LooterFrame = CreateFrame("BUTTON", "LooterFrame", UIParent)
local LooterStatus = LooterFrame:CreateFontString("LooterStatusText", "OVERLAY")
LooterFrame:RegisterEvent("PLAYER_LOGIN")
LooterFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
LooterFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
LooterFrame:RegisterEvent("PLAYER_STARTED_MOVING")
LooterFrame:RegisterEvent("PLAYER_STOPPED_MOVING")
LooterFrame:RegisterEvent("LOOT_OPENED")
LooterFrame:RegisterEvent("LOOT_CLOSED")
LooterFrame:RegisterUnitEvent("UNIT_SPELLCAST_START")
LooterFrame:RegisterUnitEvent("UNIT_SPELLCAST_STOP")

LooterFrame:SetScript(
    "OnEvent",
    function(self, event, ...)
        local arg1, arg2, arg3 = ...
        if event == "PLAYER_LOGIN" then
            if RaijinLabDB.looter_enabled == nil then
                RaijinLabDB.looter_enabled = false
            end
            if RaijinLabDB.loot_frame_position == nil then
                RaijinLabDB.loot_frame_position = {}
                RaijinLabDB.loot_frame_position.point = "CENTER"
                RaijinLabDB.loot_frame_position.relativePoint = "TOP"
                RaijinLabDB.loot_frame_position.xOfs = 2
                RaijinLabDB.loot_frame_position.yOfs = -70
            end
            LooterFrame:SetWidth(80)
            LooterFrame:SetHeight(80)
            LooterFrame:SetPoint(
                RaijinLabDB.loot_frame_position.point,
                UIParent,
                RaijinLabDB.loot_frame_position.relativePoint,
                RaijinLabDB.loot_frame_position.xOfs,
                RaijinLabDB.loot_frame_position.yOfs
            )
            LooterFrame:SetMovable(true)
            LooterFrame:EnableMouse(true)
            LooterFrame:RegisterForClicks("RightButtonUp")
            LooterFrame:SetScript(
                "OnClick",
                function(self, button, down)
                    if RaijinLabDB.looter_enabled == false then
                        RaijinLabDB.looter_enabled = true
                    else
                        RaijinLabDB.looter_enabled = false
                    end
                    -- Update label only on toggle (not every OnUpdate frame).
                    if RaijinLabDB.looter_enabled then
                        LooterStatus:SetText("Looter |cFF00FF00Enabled")
                    else
                        LooterStatus:SetText("Looter |cffff0000Disabled")
                    end
                end
            )
            LooterFrame:SetScript(
                "OnMouseDown",
                function(self, button)
                    if button == "LeftButton" and not self.isMoving then
                        self:StartMoving()
                        self.isMoving = true
                    end
                end
            )
            LooterFrame:SetScript(
                "OnMouseUp",
                function(self, button)
                    if button == "LeftButton" and self.isMoving then
                        self:StopMovingOrSizing()
                        self.isMoving = false
                        local point, _, relativePoint, xOfs, yOfs = self:GetPoint(1)
                        RaijinLabDB.loot_frame_position.point = point
                        RaijinLabDB.loot_frame_position.relativePoint = relativePoint
                        RaijinLabDB.loot_frame_position.xOfs = xOfs
                        RaijinLabDB.loot_frame_position.yOfs = yOfs
                    end
                end
            )
            LooterStatus:SetFontObject(GameFontNormalSmall)
            LooterStatus:SetJustifyH("CENTER")
            LooterStatus:SetPoint("CENTER", LooterFrame, "CENTER", 0, 0)
            LooterStatus:SetText("Looter |cffff0000Disabled")
        elseif event == "PLAYER_REGEN_ENABLED" then
            private.combat = false
        elseif event == "PLAYER_REGEN_DISABLED" then
            private.combat = true
        elseif event == "PLAYER_STARTED_MOVING" then
            playerMoving = true
        elseif event == "PLAYER_STOPPED_MOVING" then
            playerMoving = false
        elseif event == "LOOT_OPENED" then
            private.player_looting = true
        elseif event == "LOOT_CLOSED" then
            private.player_looting = false
            private.pulse = GetTime() + 0.35
        elseif event == "UNIT_SPELLCAST_START" then
            if arg1 == "player" then
                private.player_casting = true
            end
        elseif event == "UNIT_SPELLCAST_STOP" then
            if arg1 == "player" then
                private.player_casting = false
                private.pulse = GetTime() + 0.35
            end
        end
    end
)

LooterFrame:SetScript(
    "OnUpdate",
    function(self, elapsed)
        if not RaijinLabDB.looter_enabled then
            private.lootable_unit = nil
            return
        end
        if private.player_looting or private.player_casting then
            return
        end
        if private.pulse == nil then
            private.pulse = GetTime()
        end
        if GetTime() > private.pulse then
            Gather()
            -- Empty area: back off pulse (awareness of nothing to loot).
            local gap = private.delay
            if (private.empty_streak or 0) >= 3 then gap = 1.5 end
            private.pulse = GetTime() + gap
        end
    end
)
