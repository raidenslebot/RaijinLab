addon_name, _ = ...
if not RaijinLab then
    RaijinLab = {}
    RaijinLab.addon_name = addon_name
    -- Single source of truth for the addon-side version string. Kept in sync
    -- with the TOC's `## Version:` and consumed by StatusUI + status prints so
    -- there is exactly one place to bump on release.
    RaijinLab.ADDON_VERSION = "1.8.0"
    RaijinLab.multijump_toggle = false
    RaijinLab.anti_afk = false
    RaijinLab.fly_toggle = false
    RaijinLab.noclip_toggle = false
    RaijinLab.tracker_toggle = false
    RaijinLab.arena_los_toggle = true
    RaijinLab.tooltips = {
        [175422] = "Kill a npc near and then use quest item.",
    }
end

if not RaijinLabDB then
    RaijinLabDB = {}
end
-- Schema version stamp (see core/Persistence.lua). Absence => legacy v1, migrated
-- up at VARIABLES_LOADED. Never downgrade this by hand.
if not RaijinLabDB.schema_version then
    RaijinLabDB.schema_version = 1
end
if not RaijinLabDB.objects_to_track then
    RaijinLabDB.objects_to_track = { default = {} }
end
if not RaijinLabDB.enabled_lists then
    RaijinLabDB.enabled_lists = { default = true }
end
if not RaijinLabDB.modules then
    RaijinLabDB.modules = {
        rotation = false,
        nav = true,
        gather = false,
        combat = false,
        quest = false,
        grind = false,
    }
end
if not RaijinLabDB.rotations then
    RaijinLabDB.rotations = {}
end
if not RaijinLabDB.active_rotation then
    RaijinLabDB.active_rotation = "Default"
end
if not RaijinLabDB.grind then
    RaijinLabDB.grind = { radius = 40, route = {}, enabled = false }
end
if not RaijinLabDB.gather then
    RaijinLabDB.gather = {
        professions = { herbalism = true, mining = true, fishing = true, woodcutting = true },
        enabled = false,
    }
end
if not RaijinLabDB.combat then
    RaijinLabDB.combat = { engage = true, disengage_hp = 25, pvp_mode = "auto", enabled = false }
end
if not RaijinLabDB.quest then
    RaijinLabDB.quest = { enabled = false, auto_accept = true, auto_turnin = true }
end
