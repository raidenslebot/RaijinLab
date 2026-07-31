local loc = GetLocale()
local dbs = { "items", "quests", "quests-itemreq", "objects", "units", "zones", "professions", "areatrigger", "refloot" }
local noloc = { "items", "quests", "objects", "units" }

-- Patch databases to merge ascension data
local function patchtable(base, diff)
  for k, v in pairs(diff) do
    if base[k] and type(v) == "table" then
      patchtable(base[k], v)
    elseif type(v) == "string" and v == "_" then
      base[k] = nil
    else
      base[k] = v
    end
  end
end
-- fix map-id 1519 spawns [Stormwind]
for _, obj in pairs(RaijinQuestDB["objects"]["data"]) do
  if obj.coords then
    for num, tbl in pairs(obj.coords) do
      if tbl[3] == 1519 then -- map
        tbl[1] = tbl[1] + 6.8 -- x
        tbl[2] = tbl[2] + 10.1 -- y
      end
    end
  end
end
-- fix map-id 1519 spawns [Stormwind]
for _, obj in pairs(RaijinQuestDB["units"]["data"]) do
  if obj.coords then
    for num, tbl in pairs(obj.coords) do
      if tbl[3] == 1519 then -- map
        tbl[1] = tbl[1] + 6.8 -- x
        tbl[2] = tbl[2] + 10.1 -- y
      end
    end
  end
end
-- fix map-id 1519 spawns [Stormwind]
for _, obj in pairs(RaijinQuestDB["areatrigger"]["data"]) do
  if obj.coords then
    for num, tbl in pairs(obj.coords) do
      if tbl[3] == 1519 then -- map
        tbl[1] = tbl[1] + 6.8 -- x
        tbl[2] = tbl[2] + 10.1 -- y
      end
    end
  end
end
-- RaijinQuestDB.locales was defined in database.lua, which we deliberately do
-- not load (we use this database as DATA, not as an addon). The loop below does
-- pairs() over it, and pairs(nil) THROWS - which aborted this file partway,
-- leaving the "loc" name shortcuts unbuilt and every lookup answering nil. Live
-- symptom: `no_known_location` for an objective whose coordinates are on disk.
--
-- Same list database.lua declared, then pruned to what is actually installed -
-- we ship enUS only, so the prune is what keeps the locale merge below honest.
if not RaijinQuestDB.locales then
  RaijinQuestDB.locales = {
    ["enUS"] = "English", ["koKR"] = "Korean", ["frFR"] = "French",
    ["deDE"] = "German", ["zhCN"] = "Chinese", ["zhTW"] = "Taiwanese",
    ["esES"] = "Spanish", ["ruRU"] = "Russian",
  }
  for key in pairs(RaijinQuestDB.locales) do
    if not RaijinQuestDB["quests"][key] then RaijinQuestDB.locales[key] = nil end
  end
end

local loc_core, loc_update
for _, db in pairs(dbs) do
  if RaijinQuestDB[db]["data-ascension"] then
    patchtable(RaijinQuestDB[db]["data"], RaijinQuestDB[db]["data-ascension"])
  end

  for loc, _ in pairs(RaijinQuestDB.locales) do
    if RaijinQuestDB[db][loc] and RaijinQuestDB[db][loc.."-ascension"] then
      loc_update = RaijinQuestDB[db][loc.."-ascension"] or RaijinQuestDB[db]["enUS-ascension"]
      patchtable(RaijinQuestDB[db][loc], loc_update)
    end
  end
end

loc_core = RaijinQuestDB["professions"][loc] or RaijinQuestDB["professions"]["enUS"]
loc_update = RaijinQuestDB["professions"][loc.."-ascension"] or RaijinQuestDB["professions"]["enUS-ascension"]
if loc_update then patchtable(loc_core, loc_update) end

if RaijinQuestDB["minimap-ascension"] then patchtable(RaijinQuestDB["minimap"], RaijinQuestDB["minimap-ascension"]) end
if RaijinQuestDB["meta-ascension"] then patchtable(RaijinQuestDB["meta"], RaijinQuestDB["meta-ascension"]) end

-- Reload all RaijinQuest internal database shortcuts.
-- VENDORED: RaijinQuestDatabase lives in addon.xml, which we deliberately do not
-- load - we use this database as DATA, not as an addon (see RaijinLab.toc). Its
-- Reload() only rebuilt that module's own query shortcuts, and we read the raw
-- tables, so its absence costs nothing. Unguarded this is a hard error on load.
if RaijinQuestDatabase and RaijinQuestDatabase.Reload then
  RaijinQuestDatabase:Reload()
else
  -- ...and when it is absent we must still build the ONE thing Reload made that
  -- anything outside that module uses: the "loc" shortcut. Every locale table is
  -- stored under its locale key ("enUS"), and callers read db[x].loc[id] to get
  -- a name. Without this, units.loc and objects.loc are nil and every id->name
  -- lookup silently returns nothing - which looks exactly like an empty world.
  -- Mirrors database.lua:269, including its noloc rule: items/quests/objects/
  -- units are only ever shipped in enUS.
  local noloc = { items = true, quests = true, objects = true, units = true }
  for _, db in pairs(dbs) do
    if RaijinQuestDB[db] then
      RaijinQuestDB[db]["loc"] = (noloc[db] and RaijinQuestDB[db]["enUS"])
        or RaijinQuestDB[db][loc] or RaijinQuestDB[db]["enUS"] or {}
    end
  end
end