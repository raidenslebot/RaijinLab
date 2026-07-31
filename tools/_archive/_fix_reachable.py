from pathlib import Path

p = Path(r"C:\Ascension\Workspace\RaijinLab\addon\core\Pathfinder.lua")
s = p.read_text(encoding="utf-8")

OLD = """    -- Provable unreachability: no chain of open blocks connects us, and any fine
    -- path would have to produce one. Costs microseconds and saves a doomed search.
    if H and H.reachable then
        local ok = H.reachable(sid, gid, opts)
        if ok == false then return nil, "no_path" end
    end"""

NEW = """    -- "NOT CONNECTED IN THE MESH" IS NOT "NOT REACHABLE IN THE WORLD".
    --
    -- H.reachable floods coarse blocks built ONLY from cells WorldMesh has
    -- already recorded as open, and coarse_neighbours skips any block absent from
    -- that table - so ground we have simply never walked is byte-identical to a
    -- wall. The comment this replaces called the negative "provable", and it is,
    -- but only within the mesh: promoting a mesh-local verdict to a global one is
    -- the whole bug.
    --
    -- It bites exactly when the mesh has two mapped islands with unexplored (and
    -- perfectly walkable) ground between them - after a graveyard resurrect, a
    -- flight path, or a hearth. Both endpoints snap to known cells, so HLP's own
    -- "endpoint outside the mesh" escape cannot fire, the flood exhausts one
    -- island and answers false. Pathfinder returned no_path, Navigator called
    -- stop() and cleared the goal, which also disables replanning: the bot stands
    -- still forever for somewhere it could have walked to.
    --
    -- The short-circuit also discarded the only tier that could have disagreed.
    -- TIER 2's oracle falls back to NavGrid heights extracted from the client's
    -- own terrain, specifically so routes extend past render range and past
    -- anything we happen to have mapped. Skipping it on mesh evidence throws away
    -- the better witness.
    --
    -- So: a coarse miss now DEMOTES the plan to the slower tiers instead of
    -- terminating it. Refusing to search is only justified when something that
    -- can actually see the world says no.
    if H and H.reachable then
        local ok = H.reachable(sid, gid, opts)
        if ok == false then
            local Tel = RaijinLab and RaijinLab.Telemetry
            if Tel and Tel.every then
                Tel.every("path:coarse_miss", 10, "path", 3, "coarse_disconnected",
                    { note = "unmapped is not unreachable - falling through to full search" })
            end
            return nil, "coarse_miss"
        end
    end"""
assert OLD in s, "reachable short-circuit not found"
s = s.replace(OLD, NEW, 1)

# the caller must treat coarse_miss as "keep going", not as a terminal answer
OLD2 = 'return { path = nil, status = "no_path" }'
if OLD2 in s:
    print("NOTE: find() returns no_path at least once - inspect call site")
p.write_text(s, encoding="utf-8")
print("Pathfinder: coarse flood demotes instead of terminating")
