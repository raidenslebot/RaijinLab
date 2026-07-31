-- Sensors - the list of "what do we know about the world" entry points.
--
-- A SENSOR answers a question about the world and may be unable to answer.
-- Those must return Know values (or a *_k companion that does). ACTIONS and
-- pure math stay boolean.
--
-- This file is both documentation and the load-order anchor for the source
-- guard in tests/run_suite_tests.py: every name listed in Sensors.LIST must
-- resolve to a real function that returns a Know table (or has a sibling
-- with a _k suffix).

local Sensors = {}

-- Registry of qualified sensor names. The source guard reads this list from
-- disk so a missing conversion fails the build.
Sensors.LIST = {
    -- Mount
    "Mount.has_riding_skill_k",
    "Mount.can_ride_k",
    "Mount.is_mounted_k",
    -- Gather
    "Gatherer.profession_enabled_k",
    "Gatherer.has_fishing_pole_k",
    "Gatherer.fishing_pool_near_k",
    -- Rest / Vendor / Trainer / Death
    "Rest.should_rest_k",
    "Vendor.needs_vendor_k",
    "Vendor.has_plan_k",
    "Trainer.at_trainer_k",
    "Trainer.needs_training_k",
    "Death.is_dead_k",
    "Death.is_ghost_k",
    "Death.corpse_known_k",
    -- Quest memory
    "QuestOM.remembered_objective_k",
    "QuestOM.remembered_giver_k",
    -- Terrain
    "NavGrid.walkable",
    -- Caps (already Know-shaped)
    "Caps.probe",
}

function Sensors.ok(k)
    local Kn = RaijinLab and RaijinLab.Know
    if not Kn then return k and true or false end
    return Kn.is_yes(k)
end

function Sensors.no(k)
    local Kn = RaijinLab and RaijinLab.Know
    if not Kn then return not k end
    return Kn.is_no(k)
end

function Sensors.unknown(k)
    local Kn = RaijinLab and RaijinLab.Know
    if not Kn then return k == nil end
    return Kn.is_unknown(k)
end

if RaijinLab then RaijinLab.Sensors = Sensors end
return Sensors
