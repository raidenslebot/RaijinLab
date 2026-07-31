from pathlib import Path

# ---- 1. the fallback must NOT fire from nearest_giver's priority position ---
p = Path(r"C:\Ascension\Workspace\RaijinLab\addon\modules\questing\QuestOM.lua")
s = p.read_text(encoding="utf-8")

OLD = """    if QuestOM.status_source_alive() == false then
        return QuestOM.candidate_giver(px, py, pz)
    end
    return nil
end"""
NEW = """    -- Deliberately NOT called from here by default. nearest_giver runs in
    -- PRIORITY position - the engine asks it before deciding to do anything
    -- else - so nominating a guess here made the bot walk off to greet a random
    -- npc instead of killing the wolf it had been sent to kill. Three quest-
    -- engine tests caught exactly that, and they were right to.
    --
    -- The fallback belongs at the point where the engine has genuinely run out
    -- of better ideas: the belief-field sweep. Suite asks for it explicitly
    -- there via opts.allow_candidates.
    if opts and opts.allow_candidates and QuestOM.status_source_alive() == false then
        return QuestOM.candidate_giver(px, py, pz)
    end
    return nil
end"""
assert OLD in s, "fallback block not found"
s = s.replace(OLD, NEW, 1)

# give nearest_giver the opts parameter
import re
m = re.search(r"function QuestOM\.nearest_giver\(([^)]*)\)", s)
assert m, "nearest_giver signature not found"
if "opts" not in m.group(1):
    s = s[:m.start()] + "function QuestOM.nearest_giver(%s, opts)" % m.group(1).strip() + s[m.end():]
p.write_text(s, encoding="utf-8")
print("QuestOM: fallback is opt-in via opts.allow_candidates")

# ---- 2. Suite asks for it right where it would otherwise sweep -------------
q = Path(r"C:\Ascension\Workspace\RaijinLab\addon\modules\questing\Suite.lua")
t = q.read_text(encoding="utf-8")
OLD2 = """        -- Not knowing where something is, is not a reason to stand still. It is
        -- the reason to go and look.
        return Suite.search_for(kind, label, q)"""
NEW2 = """        -- Not knowing where something is, is not a reason to stand still. It is
        -- the reason to go and look.
        --
        -- BUT LOOK AT WHAT IS IN FRONT OF US FIRST. The quest-giver status call
        -- is a `return 0` stub in the runtime, so nearest_giver above is nil for
        -- every npc in the world no matter how many are standing right there.
        -- Observed live: a completed quest ("Rude Awakening"), turnin:searching,
        -- belief legs sweeping the zone - while quest givers stood unvisited and
        -- world memory sat at poi=1. Sweeping is the correct response to "I do
        -- not know where it is"; it is the wrong response to "I cannot see".
        --
        -- Only fires when status_source_alive() has measured the sensor DEAD
        -- (400 queries, none non-zero) - not on a hunch, and not while it works.
        if (kind == "giver" or kind == "turnin") and RaijinLab.QuestOM.candidate_giver then
            local want = (kind == "turnin") and "complete" or "available"
            local c = RaijinLab.QuestOM.nearest_giver(want, { allow_candidates = true })
            if c and c.guessed then
                local Tel = RaijinLab and RaijinLab.Telemetry
                if Tel and Tel.every then
                    Tel.every("quest:candidate", 10, "quest", 3, "greet_candidate",
                        { name = tostring(c.name), dist = math.floor(c.dist or 0) })
                end
                local cx, cy, cz = RaijinLab:ObjectPosition(c.guid)
                if cx then
                    local st2 = goto_point(cx, cy, cz, cfg().memory_arrive or 12)
                    if st2 == "arrived" then
                        -- Standing next to it: greet. The dialog is the authority
                        -- the stub cannot be, and QuestFrame records the POI on
                        -- any frame that opens, so a success seeds memory for good.
                        if RaijinLab.Actions and RaijinLab.Actions.Interact then
                            pcall(RaijinLab.Actions.Interact, c.guid)
                        elseif InteractUnit then
                            pcall(InteractUnit, c.guid)
                        end
                        -- If no frame opens this npc is not a giver; do not come
                        -- back to it, or we stand in front of one guard forever.
                        RaijinLab.QuestOM.rule_out(c.guid, "no_frame")
                        return kind .. ":greeting " .. tostring(c.name)
                    end
                    return kind .. ":approaching " .. tostring(c.name)
                end
            end
        end
        return Suite.search_for(kind, label, q)"""
assert OLD2 in t, "search fallthrough not found"
t = t.replace(OLD2, NEW2, 1)
q.write_text(t, encoding="utf-8")
print("Suite: greet the nearest candidate before sweeping")
