from pathlib import Path

# ---- 1. My own camera guard: 0 is truthy -----------------------------------
p = Path(r"C:\Ascension\Workspace\RaijinLab\addon\core\API.lua")
s = p.read_text(encoding="utf-8")
OLD = """    local c = RaijinLab.GetCameraData and RaijinLab:GetCameraData()
    if not (c and c.px and c.py) then return true end"""
NEW = """    local c = RaijinLab.GetCameraData and RaijinLab:GetCameraData()
    -- 0 IS TRUTHY IN LUA. `c.px and c.py` accepts an all-zero camera read, which
    -- is exactly what a FAILED read looks like - so the witness this guard
    -- depends on could itself be garbage and still be believed. A camera at the
    -- literal world origin would then "disagree" with every real position and
    -- reject all of them, or agree with a garbage (0,y,0) position and pass it.
    -- Same trap as the quest-giver stub returning 0: an in-range value that
    -- means "no answer".
    if not (c and type(c.px) == "number" and type(c.py) == "number") then
        return true
    end
    if c.px == 0 and c.py == 0 and (c.pz == nil or c.pz == 0) then
        return true                      -- all-zero camera = no witness, not a verdict
    end"""
assert OLD in s, "camera guard not found"
p.write_text(s.replace(OLD, NEW, 1), encoding="utf-8")
print("API: camera witness must be a real reading")

# ---- 2. Navigator: no floor found != airborne ------------------------------
n = Path(r"C:\Ascension\Workspace\RaijinLab\addon\core\Navigator.lua")
t = n.read_text(encoding="utf-8")
OLD2 = """    local gz
    if RaijinLab.TraceGround then
        gz = RaijinLab:TraceGround(px, py, pz, 2.5, 6.0)   -- nil = no floor beneath
    else
        gz = pz                                            -- no trace support: can't check
    end
    if gz == nil then"""
NEW2 = """    local gz
    if RaijinLab.TraceGround then
        gz = RaijinLab:TraceGround(px, py, pz, 2.5, 6.0)   -- nil = no floor beneath
    else
        gz = pz                                            -- no trace support: can't check
    end

    -- "THE RAY FOUND NOTHING" IS NOT "THE CHARACTER IS FALLING".
    --
    -- The trace spans 6 yards and its flags (M2 | WMO | terrain | entity) carry
    -- no liquid bit, so it cannot see a water surface at all - Surveyor says as
    -- much, which is why water is learned from IsSwimming instead. Meanwhile the
    -- planner routes through water ON PURPOSE: NavGrid.walkable returns yes for
    -- WATER and Pathfinder merely prices it, because refusing water turns every
    -- river into a wall.
    --
    -- So the bot swims into any lake deeper than ~6yd, the ray hits nothing, and
    -- this gate concluded "airborne" -> cut movement -> abort("fell") -> the chat
    -- says "stopped: left the ground" while the character floats calmly in a
    -- pond. That was reported verbatim.
    --
    -- The damage outlives the swim: abort() calls WorldMesh.mark_stuck on the
    -- last footing, and three marks flip that cell to BLOCKED permanently in the
    -- PERSISTENT mesh - so every crossing burns a false hole into world memory
    -- that never expires.
    --
    -- Swimming is a definite, cheap, stock answer. Ask it before accusing.
    if gz == nil and IsSwimming and IsSwimming() then
        gz = pz              -- in water: floating is not falling
        a.airborne_t = nil
    end
    if gz == nil then"""
assert OLD2 in t, "navigator ground gate not found"
n.write_text(t.replace(OLD2, NEW2, 1), encoding="utf-8")
print("Navigator: swimming is not falling")
