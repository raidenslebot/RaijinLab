local function FindNpcsAndCastSpells(farm_mobs, farm_spells)
-- Steering, never click-to-move. CTM is a hard project constraint and these two
-- call sites quietly violated it for the whole life of this module; they also
-- gave up obstacle avoidance, which is why a farming route walks into scenery.
local function steer_to(x, y, z, arrive)
    if not x then return false end
    local Nv = RaijinLab.Navigator
    if Nv and Nv.move_to then
        return Nv.move_to({ x = x, y = y, z = z }, { arrive_dist = arrive or 4.0 })
    end
    local Nav = RaijinLab.Nav
    if Nav and Nav.request_move then
        return Nav.request_move({ x = x, y = y, z = z }, { arrive_dist = arrive or 4.0 })
    end
    return false
end

    local found_unit = nil
    for i = 1, RaijinLab:GetNpcCount("player", 30) do
        local unit = RaijinLab:GetNpcWithIndex(i)
        if unit and not RaijinLab:UnitTarget(unit) and not UnitIsDeadOrGhost(unit) and farm_mobs[UnitName(unit)]
        and RaijinLab:InLineOfSight("player", unit) then
            found_unit = unit
            for id, _ in pairs(farm_spells) do
                if select(1, GetSpellCooldown(id)) == 0 then
                    RaijinLab:Face(unit, true)
                    if RaijinLab.Actions and RaijinLab.Actions.StopMoving then RaijinLab.Actions.StopMoving() end
                    if RaijinLab.Actions and RaijinLab.Actions.CastSpell then
                        RaijinLab.Actions.CastSpell(id, unit)
                    end
                    return found_unit
                end
            end
        end
    end
    return found_unit
end

function RaijinLab:MobFarmInit(farm_mobs, farm_spells, farm_spots)
    local function IsMoving(pointer)
        local pointer = pointer or "player"
        if UnitIsVisible(pointer) and GetUnitSpeed(pointer) > 0 then
            return true
        end
    end
    -- create a frame and store it in table
    RaijinLab.mob_farm_frame = CreateFrame("FRAME")
    RaijinLab.mob_farm_frame:SetScript(
        "OnUpdate",
        function(self, ...)
            if UnitIsDeadOrGhost("player") then return end
            if not self.gps_index then
                self.gps_index = 1
            end
            -- limiter
            if not self.last_update_time then
                self.last_update_time = 0
            end
            if not self.last_jump_time then
                self.last_jump_time = 0
            end
            if not self.last_force_move_time then
                self.last_force_move_time = 0
            end
            if GetTime() - self.last_update_time < 0.100 then
                return
            end
            self.last_update_time = GetTime()

            -- iterate mobs
            local found_unit = FindNpcsAndCastSpells(farm_mobs, farm_spells)


            -- (removed EnemiesAroundUnit/HFBurstMacro block: both globals were
            -- undefined here; ran on every OnUpdate as nil calls. Add back once
            -- a real enemy-count source + HFBurst macro are wired.)

            -- move to the next hotspot if we didn't find a mob
            if not self.finished_moving and UnitAffectingCombat("player") and GetTime() - self.last_force_move_time > 3 + math.random() and RaijinLab:ObjectExists("target") and not IsMoving() then
                local x, y, z = RaijinLab:ObjectPosition("target")
                if x then steer_to(x, y, z, 4.0) end
                self.last_force_move_time = GetTime()
            end
            if not found_unit and not RaijinLab.HAS_LOOTABLE_UNIT and not UnitAffectingCombat("player") then
                if RaijinLab:UnitTarget("player") and not RaijinLab:ObjectIsFacing("player", "target") and not IsMoving("player") then
                    if RaijinLab.Actions then RaijinLab.Actions.StopMoving() end
                    RaijinLab:Face("target", true)
                end
                local hotspot = farm_spots[self.gps_index]
                local x, y, z = RaijinLab:ObjectPosition("player")
                local distance = RaijinLab:GetDistanceBetweenPositions(x, y, z, hotspot.x, hotspot.y, hotspot.z)
                if not self.finished_moving then
                    if distance <= 5 then self.finished_moving = true print("finished moving to hotspot index " .. self.gps_index ) else self.finished_moving = false end
                end
                if not self.finished_moving and not IsMoving() then
                    print("moving to hotspot index " .. self.gps_index)
                    steer_to(hotspot.x + math.random() + 1, hotspot.y + math.random() + 1, hotspot.z, 5.0)
                    if GetTime() - self.last_jump_time > 5 + math.random() then
                        C_Timer.After(1 + math.random(), function()
                            if RaijinLab.Actions then RaijinLab.Actions.Jump() end
                        end)
                        self.last_jump_time = GetTime()
                    end
                end
                if self.finished_moving then
                    self.gps_index = self.gps_index + 1
                    if self.gps_index > #farm_spots then
                        self.gps_index = 1
                    end
                    self.finished_moving = false
                end
            end
        end
    )
end


function RaijinLab:MobFarmDestroy()
    RaijinLab.mob_farm_frame:SetScript("OnUpdate", nil)
    RaijinLab.mob_farm_frame = nil
end
