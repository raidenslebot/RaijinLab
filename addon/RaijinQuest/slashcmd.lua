-- multi api compat
local compat = RaijinQuestCompat

SLASH_PFDB1, SLASH_PFDB2, SLASH_PFDB3, SLASH_PFDB4 = "/db", "/shagu", "/rqquest", "/rqdb"
SlashCmdList["PFDB"] = function(input, editbox)
  local params = {}
  local meta = { ["addon"] = "PFDB" }

  if (input == "" or input == nil) then
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ffccpf|cffffffffQuest (v" .. RaijinQuestConfig.version .. "):")
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ffcc/db|cffffffff lock |cffcccccc - " .. RaijinQuest_Loc["Lock map tracker"])
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ffcc/db|cffffffff tracker |cffcccccc - " .. RaijinQuest_Loc["Show map tracker"])
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ffcc/db|cffffffff journal |cffcccccc - " .. RaijinQuest_Loc["Show quest journal"])
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ffcc/db|cffffffff arrow |cffcccccc - " .. RaijinQuest_Loc["Show quest arrow"])
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ffcc/db|cffffffff show |cffcccccc - " .. RaijinQuest_Loc["Show database interface"])
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ffcc/db|cffffffff config |cffcccccc - " .. RaijinQuest_Loc["Show configuration interface"])
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ffcc/db|cffffffff locale |cffcccccc - " .. RaijinQuest_Loc["Display addon locales"])
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ffcc/db|cffffffff unit <unit> |cffcccccc - " .. RaijinQuest_Loc["Search unit"])
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ffcc/db|cffffffff object <gameobject> |cffcccccc - " .. RaijinQuest_Loc["Search object"])
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ffcc/db|cffffffff item <item> |cffcccccc - " .. RaijinQuest_Loc["Search loot"])
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ffcc/db|cffffffff vendor <item> |cffcccccc - " .. RaijinQuest_Loc["Search item vendors"])
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ffcc/db|cffffffff quest <questname> |cffcccccc - " .. RaijinQuest_Loc["Show specific quest"])
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ffcc/db|cffffffff quests |cffcccccc - " .. RaijinQuest_Loc["Show all quests on map"])
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ffcc/db|cffffffff clean |cffcccccc - " .. RaijinQuest_Loc["Clean Map"])
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ffcc/db|cffffffff reset |cffcccccc - " .. RaijinQuest_Loc["Reset Map"])
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ffcc/db|cffffffff chests |cffcccccc - " .. RaijinQuest_Loc["Show all chests on map"])
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ffcc/db|cffffffff taxi [faction]|cffcccccc - " .. RaijinQuest_Loc["Show all taxi nodes of [faction]"])
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ffcc/db|cffffffff rares [min, [max]]|cffcccccc - " .. RaijinQuest_Loc["Show all rare mobs of Level [min] to [max]"])
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ffcc/db|cffffffff mines [min, [max]] |cffcccccc - " .. RaijinQuest_Loc["Show mines with skill range of [min] to [max]"])
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ffcc/db|cffffffff mines auto |cffcccccc - " .. RaijinQuest_Loc["Show mines with an appropriate skill level for your character"])
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ffcc/db|cffffffff herbs [min, [max]] |cffcccccc - " .. RaijinQuest_Loc["Show herbs with skill range of [min] to [max]"])
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ffcc/db|cffffffff herbs auto |cffcccccc - " .. RaijinQuest_Loc["Show herbs with an appropriate skill level for your character"])
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ffcc/db|cffffffff scan |cffcccccc - " .. RaijinQuest_Loc["Scan the server for custom items"])
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ffcc/db|cffffffff query |cffcccccc - " .. RaijinQuest_Loc["Query the server for completed quests"])
    return
  end

  local commandlist = { }
  local command

  for command in compat.gfind(input, "[^ ]+") do
    table.insert(commandlist, command)
  end

  local arg1, arg2 = commandlist[1], ""

  -- handle whitespace mob- and item names correctly
  for i in pairs(commandlist) do
    if (i ~= 1) then
      arg2 = arg2 .. commandlist[i]
      if (commandlist[i+1] ~= nil) then
        arg2 = arg2 .. " "
      end
    end
  end

  -- argument: debug
  if (arg1 == "debug") then
    RaijinQuest_config.debug = not RaijinQuest_config.debug
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ffccpf|cffffffffQuest Debug Mode: " .. ( RaijinQuest_config.debug and "|cff33ff33ON" or "|cffff3333OFF" ))
    RaijinQuest:Debug("Debug Mode Changed")
    return
  end

  -- argument: item
  if (arg1 == "item") then
    local maps = RaijinQuestDatabase:SearchItem(arg2, meta, "LOWER")
    RaijinQuestMap:ShowMapID(RaijinQuestDatabase:GetBestMap(maps))
    return
  end

  -- argument: vendor
  if (arg1 == "vendor") then
    local maps = RaijinQuestDatabase:SearchVendor(arg2, meta, "LOWER")
    RaijinQuestMap:ShowMapID(RaijinQuestDatabase:GetBestMap(maps))
    return
  end

  -- argument: unit
  if (arg1 == "unit") then
    local maps = RaijinQuestDatabase:SearchMob(arg2, meta, "LOWER")
    RaijinQuestMap:ShowMapID(RaijinQuestDatabase:GetBestMap(maps))
    return
  end

  -- argument: object
  if (arg1 == "object") then
    local maps = RaijinQuestDatabase:SearchObject(arg2, meta, "LOWER")
    RaijinQuestMap:ShowMapID(RaijinQuestDatabase:GetBestMap(maps))
    return
  end

  -- argument: quest
  if (arg1 == "quest") then
    local maps = RaijinQuestDatabase:SearchQuest(arg2, meta, "LOWER")
    RaijinQuestMap:ShowMapID(RaijinQuestDatabase:GetBestMap(maps))
    return
  end

  -- argument: quests
  if (arg1 == "quests") then
    local maps = RaijinQuestDatabase:SearchQuests(meta)
    RaijinQuestMap:UpdateNodes()
    return
  end

  -- argument: meta
  if (arg1 == "meta") then
    local maps = RaijinQuestDatabase:SearchMetaRelation({ commandlist[2], commandlist[3], commandlist[4] }, meta)
    RaijinQuestMap:ShowMapID(RaijinQuestDatabase:GetBestMap(maps))
    return
  end

  -- argument: chests
  if (arg1 == "chests") then
    local maps = RaijinQuestDatabase:SearchMetaRelation({ commandlist[1] }, meta)
    RaijinQuestMap:ShowMapID(RaijinQuestDatabase:GetBestMap(maps))
    return
  end

  -- argument: taxi
  if (arg1 == "taxi") then
    local maps = RaijinQuestDatabase:SearchMetaRelation({ commandlist[1], commandlist[2] }, meta)
    RaijinQuestMap:ShowMapID(RaijinQuestDatabase:GetBestMap(maps))
    return
  end

  -- argument: rares
  if (arg1 == "rares") then
    local maps = RaijinQuestDatabase:SearchMetaRelation({ commandlist[1], commandlist[2], commandlist[3] }, meta)
    RaijinQuestMap:ShowMapID(RaijinQuestDatabase:GetBestMap(maps))
    return
  end

  -- argument: mines
  if (arg1 == "mines") then
    if (arg2 == "auto") then
      -- id 186 is Mining
      commandlist[3] = RaijinQuestDatabase:GetPlayerSkill(186) or 0
      commandlist[2] = commandlist[3] - 100
    end
    local maps = RaijinQuestDatabase:SearchMetaRelation({ commandlist[1], commandlist[2], commandlist[3] }, meta)
    RaijinQuestMap:ShowMapID(RaijinQuestDatabase:GetBestMap(maps))
    return
  end

  -- argument: herbs
  if (arg1 == "herbs") then
    if (arg2 == "auto") then
      -- id 182 is Herbalism
      commandlist[3] = RaijinQuestDatabase:GetPlayerSkill(182) or 0
      commandlist[2] = commandlist[3] - 100
    end
    local maps = RaijinQuestDatabase:SearchMetaRelation({ commandlist[1], commandlist[2], commandlist[3] }, meta)
    RaijinQuestMap:ShowMapID(RaijinQuestDatabase:GetBestMap(maps))
    return
  end

  -- argument: clean
  if (arg1 == "clean") then
    RaijinQuestMap:DeleteNode("PFDB")
    RaijinQuestMap:UpdateNodes()
    return
  end

  -- argument: reset
  if (arg1 == "reset") then
    RaijinQuest:ResetAll()
    return
  end

  -- argument: show
  if (arg1 == "show") then
    if RaijinQuestBrowser then RaijinQuestBrowser:Show() end
    return
  end

  -- argument: tracker
  if (arg1 == "tracker") then
    if RaijinQuest.tracker then RaijinQuest.tracker:Show() end
    return
  end

  -- argument: lock
  if (arg1 == "lock") then
    RaijinQuest_config.lock = not RaijinQuest_config.lock
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ffccpf|cffffffffQuest Tracker: " .. ( RaijinQuest_config.lock and "Locked" or "Unlocked" ))
    return
  end

  -- argument: journal
  if (arg1 == "journal") then
    if RaijinQuestJournal then RaijinQuestJournal:Show() end
    return
  end

  -- argument: arrow
  if (arg1 == "arrow") then
    if RaijinQuest_config["arrow"] == "1" then
      RaijinQuest_config["arrow"] = "0"
      RaijinQuest.route.arrow:Hide()
    else
      RaijinQuest_config["arrow"] = "1"
    end
    return
  end

  -- argument: show
  if (arg1 == "config") then
    if RaijinQuestConfig then RaijinQuestConfig:Show() end
    return
  end

  -- argument: locale
  if (arg1 == "locale") then
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ffcc" .. RaijinQuest_Loc["Locales"] .. "|r:" .. RaijinQuestDatabase.dbstring)
    return
  end

  -- argument: scan
  if (arg1 == "scan") then
    RaijinQuestDatabase:ScanServer()
    return
  end

    -- argument: query
  if (arg1 == "query") then
    RaijinQuestDatabase:QueryServer()
    return
  end

  -- argument: <text>
  if (type(arg1)=="string") then
    if RaijinQuestBrowser then
      RaijinQuestBrowser:Show()
      RaijinQuestBrowser.input:SetText((string.gsub(string.format("%s %s",arg1,arg2),"^%s*(.-)%s*$", "%1")))
    end
    return
  end
end
