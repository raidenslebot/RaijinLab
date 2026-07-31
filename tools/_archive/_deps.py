from pathlib import Path

p = Path(r"C:\Ascension\Workspace\RaijinLab\addon\core\Master.lua")
s = p.read_text(encoding="utf-8")

OLD = "-- Rotation follows the master switch even if it was off when the suite was\n-- stopped: \"the main button turns the rotation on too\"."
NEW = '''-- WHAT EACH MODULE NEEDS TO ACTUALLY WORK.
--
-- Turning on the quester and watching it stand still because the rotation was off
-- is not a configuration choice the user made - it is a trap. A module that
-- cannot function without another is not "compatible" with it, it DEPENDS on it,
-- and the switch should say so by turning it on.
--
-- Deliberately one level deep and explicit rather than a general graph: there are
-- five modules, the relationships are known, and a resolver would be more code
-- than the thing it resolves. Navigation is not listed because it is not a module
-- - it is a shared service that is always available.
M.REQUIRES = {
    quest = { "rotation", "combat" },   -- travel + fight + loot the objective
    grind = { "rotation", "combat" },   -- a grinder that cannot fight is a walker
    gather = {},                        -- opportunistic; needs nothing else
    combat = { "rotation" },            -- a combat brain with no rotation casts nothing
    rotation = {},
}

-- Everything `key` needs, transitively, that is not already on.
function M.missing_deps(key)
    local d = db()
    local out, seen = {}, {}
    local function walk(k)
        for _, dep in ipairs(M.REQUIRES[k] or {}) do
            if not seen[dep] then
                seen[dep] = true
                if not d.modules[dep] then out[#out + 1] = dep end
                walk(dep)
            end
        end
    end
    walk(key)
    return out
end

-- Rotation follows the master switch even if it was off when the suite was
-- stopped: "the main button turns the rotation on too".'''
assert OLD in s
s = s.replace(OLD, NEW, 1)
p.write_text(s, encoding="utf-8")
print("Master: dependency table")

# --- Menu: enabling a module brings up what it needs ------------------------
q = Path(r"C:\Ascension\Workspace\RaijinLab\addon\core\Menu.lua")
t = q.read_text(encoding="utf-8")

OLD2 = """            -- Deliberately does NOT touch the master switch. OFF is a decision,
            -- and a config click must never silently undo it - an off switch you
            -- can cancel by accident is not an off switch. While the suite is off
            -- these toggles just stage what will run when it is turned back on.
            RaijinLabDB.modules[key] = not RaijinLabDB.modules[key]"""
NEW2 = """            -- Deliberately does NOT touch the master switch. OFF is a decision,
            -- and a config click must never silently undo it - an off switch you
            -- can cancel by accident is not an off switch. While the suite is off
            -- these toggles just stage what will run when it is turned back on.
            local turning_on = not RaijinLabDB.modules[key]
            RaijinLabDB.modules[key] = turning_on
            -- Bring up what it DEPENDS on. Enabling questing and watching it stand
            -- there because the rotation was off is not a choice the user made.
            -- Said out loud, because a switch that silently flips other switches
            -- is its own kind of surprise.
            if turning_on and RaijinLab.Master and RaijinLab.Master.missing_deps then
                local need = RaijinLab.Master.missing_deps(key)
                for _, dep in ipairs(need) do
                    RaijinLabDB.modules[dep] = true
                    self:ApplyModuleState(dep)
                end
                if #need > 0 and print then
                    print("|cff7ec8e3RaijinLab|r " .. key .. " also needs " ..
                          table.concat(need, ", ") .. " - enabled")
                end
            end"""
assert OLD2 in t
t = t.replace(OLD2, NEW2, 1)
q.write_text(t, encoding="utf-8")
print("Menu: enabling a module enables its dependencies")

# --- Master.start_all honours dependencies too ------------------------------
s = p.read_text(encoding="utf-8")
OLD3 = """    local started = {}
    for _, k in ipairs(M.MODULES) do
        if d.modules[k] then"""
NEW3 = """    -- Anything armed pulls its dependencies up with it, so a saved selection
    -- that predates this rule still starts in a working state.
    for _, k in ipairs(M.MODULES) do
        if d.modules[k] then
            for _, dep in ipairs(M.missing_deps(k)) do d.modules[dep] = true end
        end
    end

    local started = {}
    for _, k in ipairs(M.MODULES) do
        if d.modules[k] then"""
assert OLD3 in s
s = s.replace(OLD3, NEW3, 1)
p.write_text(s, encoding="utf-8")
print("Master: start_all resolves dependencies")
