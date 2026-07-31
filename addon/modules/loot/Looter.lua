local private = { delay = 0.5 }
RaijinLab.looter = {}

if not RaijinLabDB.looter then
    RaijinLabDB.looter = {
        move_to_loot = false
    }
end
-- local struct = {
--     Object = "nil",
--     Name = "nil",
--     Guid = "nil",
--     Id = 0,
--     Type = {
--         base_type = { -- RaijinLab:ObjectTypeFlags() GameObject
--             name = "nil"
--         },
--         sub_type = { -- RaijinLab:GameObjectType() Door
--             id = 0,
--             name = "nil"
--         }
--     },
--     Flags = { value = 0, list = {} }, -- Depends on sub_type
--     DynamicFlags = { value = 0, list = {} }, -- Depends on sub_tpe
--     Info = {
--         Quest = {
--             IsTiedToQuest = false
--         },
--         Unit = {
--             Dead = false,
--             Hidden = false,
--             Rare = false,
--             Lootable = false,
--             Skinnable = false
--         },
--         Filter = {
--             List = "nil"
--         },
--         GameObject = {
--             Interactable = true
--         }
--     }
-- }
local function GetLootableUnit()
    local interactable_units = RaijinLab:GetInteractableObjects()
    local obj_loot_candidates = {}
    for i = 1, #interactable_units do
        local struct = interactable_units[i]
        local object = struct.Object
        local is_good_go = true
        if struct.Type.base_type.name == "GameObject" and not struct.Info.Quest.IsTiedToQuest then
            is_good_go = false
        else
            is_good_go = true
        end
        local distance = RaijinLab:GetDistanceBetweenObjects("player", object)
        if RaijinLab:InLineOfSight("player", object) and is_good_go then
            table.insert(obj_loot_candidates, {object = object, distance = distance})
        end
    end
    table.sort(obj_loot_candidates, function(a, b) return a.distance < b.distance end)
    private.lootable_unit = obj_loot_candidates[1]
    local npc_loot_candidates = {}
    if not private.lootable_unit or private.lootable_unit.distance > 10 then
        for i = 1, #RaijinLab.om.object_list.npcs do
            local struct = RaijinLab.om.object_list.npcs[i]
            local object = struct.Object
            if struct.Info.Unit.Dead and struct.Info.Unit.Lootable then
                local distance = RaijinLab:GetDistanceBetweenObjects("player", object)
                if RaijinLab:InLineOfSight("player", object) then
                    table.insert(npc_loot_candidates, {object = object, distance = distance})
                end
            end
        end
    end
    table.sort(npc_loot_candidates, function(a, b) return a.distance < b.distance end)
    private.lootable_unit = npc_loot_candidates[1]
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
            RaijinLab:StopMoving()
            if RaijinLab.Actions then
                RaijinLab.Actions.Interact(private.lootable_unit.object)
            elseif RaijinLab.ObjectInteract then
                RaijinLab:ObjectInteract(private.lootable_unit.object)
            end
            private.lootable_unit = nil
        elseif distance < 10 and RaijinLabDB.looter.move_to_loot then
            RaijinLab.HAS_LOOTABLE_UNIT = true
            local x, y, z = RaijinLab:ObjectPosition(private.lootable_unit.object)
            -- Steering, not click-to-move (forbidden project-wide). Walking to a
            -- corpse is ordinary travel and must obey the same obstacle handling
            -- as everything else, or the looter drags the character through
            -- scenery the navigator would have gone around.
            local Nav = RaijinLab.Nav
            if x and Nav and Nav.request_move then
                Nav.request_move({ x = x, y = y, z = z }, { arrive_dist = 3.0 })
            end
        else
            RaijinLab.HAS_LOOTABLE_UNIT = false
        end
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
            private.pulse = GetTime() + 1
        elseif event == "UNIT_SPELLCAST_START" then
            if arg1 == "player" then
                private.player_casting = true
            end
        elseif event == "UNIT_SPELLCAST_STOP" then
            if arg1 == "player" then
                private.player_casting = false
                private.pulse = GetTime() + 1
            end
        end
    end
)

LooterFrame:SetScript(
    "OnUpdate",
    function(self, elapsed)
        if RaijinLabDB.looter_enabled and not private.player_looting and not private.player_casting then
            if private.pulse == nil then
                private.pulse = GetTime()
            end
            if GetTime() > private.pulse then
                Gather()
                private.pulse = GetTime() + private.delay
            end
        end
        if RaijinLabDB.looter_enabled then
            LooterStatus:SetText("Looter |cFF00FF00Enabled")
        end
        if not RaijinLabDB.looter_enabled then
            LooterStatus:SetText("Looter |cffff0000Disabled")
            private.lootable_unit = nil
        end
    end
)
