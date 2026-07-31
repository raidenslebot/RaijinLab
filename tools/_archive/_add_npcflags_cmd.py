from pathlib import Path

p = Path(r"C:\Ascension\Workspace\RaijinLab\addon\core\ChatHandler.lua")
s = p.read_text(encoding="utf-8")

# find an existing quest subcommand to sit beside
ANCH = '    elseif cmd == "show" or cmd == "vision" or cmd == "draw" then'
assert ANCH in s, "anchor command not found"

CMD = '''    elseif cmd == "npcflags" then
        -- MEASURE THE OFFSET, DO NOT GUESS IT.
        --
        -- Quest-giver detection is dead because ObjectQuestGiverStatus is a
        -- `return 0` stub in the runtime. The natural replacement is
        -- UNIT_NPC_FLAGS bit 0x2 (QUESTGIVER), but that offset is not in the
        -- runtime's DescriptorTable, and every other offset in that table was
        -- verified rather than assumed. So this finds it empirically instead.
        --
        -- Usage: target a KNOWN quest giver (one with a "!" or "?" over it) and
        -- run /raijin npcflags. Then target something that is definitely NOT a
        -- quest giver (a critter, a guard with no marker) and run it again. Any
        -- offset that appears in the first list and not the second is a
        -- candidate for UNIT_NPC_FLAGS; a single survivor is the answer.
        --
        -- Safe: ObjectField is bounded and the runtime's Mem::Read is
        -- range-checked and SEH-wrapped, so a wrong offset reads 0, not a crash.
        local g = UnitGUID and UnitGUID("target")
        if not g then
            SendSystemMessage("|cff7ec8e3RaijinLab|r npcflags: select a target first")
            return true
        end
        if not RaijinLab.ObjectField then
            SendSystemMessage("|cff7ec8e3RaijinLab|r npcflags: runtime has no ObjectField")
            return true
        end
        local hits, n = {}, 0
        for off = 0, 0x400, 4 do
            local ok, v = pcall(RaijinLab.ObjectField, RaijinLab, g, off)
            v = ok and tonumber(v) or nil
            -- Ignore all-ones / absurd values: those are unmapped reads, not fields.
            if v and v ~= 0 and v < 0x7FFFFFFF and bit and bit.band(v, 0x2) ~= 0 then
                n = n + 1
                hits[#hits + 1] = string.format("0x%X(=%d)", off, v)
            end
        end
        local nm = (UnitName and UnitName("target")) or "target"
        RaijinLabDB.quest = RaijinLabDB.quest or {}
        local prev = RaijinLabDB.quest._npcflag_probe
        RaijinLabDB.quest._npcflag_probe = hits
        SendSystemMessage(string.format(
            "|cff7ec8e3RaijinLab|r npcflags [%s]: %d offset(s) with bit 0x2 set", nm, n))
        SendSystemMessage("  " .. (table.concat(hits, " ", 1, math.min(#hits, 20))))
        if prev then
            -- Difference against the previous target: that is the actual signal.
            local seen = {}
            for _, o in ipairs(hits) do seen[o] = true end
            local only_prev = {}
            for _, o in ipairs(prev) do if not seen[o] then only_prev[#only_prev + 1] = o end end
            SendSystemMessage("  in the PREVIOUS target but not this one: " ..
                ((#only_prev > 0) and table.concat(only_prev, " ") or "(none)"))
            SendSystemMessage("  -> an offset listed there, on a questgiver-then-" ..
                "nonquestgiver pair, is your UNIT_NPC_FLAGS candidate")
        else
            SendSystemMessage("  now target a NON quest giver and run it again to difference")
        end
        return true
''' + ANCH

s = s.replace(ANCH, CMD, 1)
p.write_text(s, encoding="utf-8")
print("ChatHandler: /raijin npcflags calibration added")
