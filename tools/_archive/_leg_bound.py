from pathlib import Path

# ---- 1. best() may never leave the field's own support ---------------------
p = Path(r"C:\Ascension\Workspace\RaijinLab\addon\core\SearchField.lua")
s = p.read_text(encoding="utf-8")

OLD = """    local best_score, bx, by
    for i = 1, #order do
        local b = order[i]"""
NEW = """    -- A LEG MUST STAY INSIDE THE FIELD'S OWN SUPPORT.
    --
    -- Observed live: the search proposed a target 10698 yards away and walked at
    -- it for fifty seconds. The field is seeded over MAX_RADIUS around an anchor,
    -- so nothing that far can be a legitimate belief cell - it is a stale key, a
    -- coordinate from another map, or arithmetic that escaped. Whatever produced
    -- it, proposing a ten-kilometre walk is wrong, and the cheapest place to be
    -- certain of that is here, where the answer leaves the field.
    --
    -- Bounded against the ANCHOR rather than the player: the player walks away
    -- from the anchor during a sweep, and measuring from a moving origin would
    -- let the bound drift along with the error it is supposed to catch.
    local ax, ay = self.anchor_x or px, self.anchor_y or py
    local limit = (opts.max_leg or SF.MAX_RADIUS) * 1.5

    local best_score, bx, by
    for i = 1, #order do
        local b = order[i]"""
assert OLD in s
s = s.replace(OLD, NEW, 1)

OLD2 = """            local mx = (b.bx + 0.5) * SF.BLOCK * SF.CELL
            local my = (b.by + 0.5) * SF.BLOCK * SF.CELL
            local d = sqrt((mx - px) ^ 2 + (my - py) ^ 2)
            if d > mind then"""
NEW2 = """            local mx = (b.bx + 0.5) * SF.BLOCK * SF.CELL
            local my = (b.by + 0.5) * SF.BLOCK * SF.CELL
            local d = sqrt((mx - px) ^ 2 + (my - py) ^ 2)
            local from_anchor = sqrt((mx - ax) ^ 2 + (my - ay) ^ 2)
            if from_anchor > limit then
                -- outside the support: drop the mass so it cannot be chosen
                -- again, rather than merely skipping it every call
                b.m = 0
            elseif d > mind then"""
assert OLD2 in s
s = s.replace(OLD2, NEW2, 1)

# the refinement pass must respect it too
OLD3 = """                if self.cells[key_of(cx, cy)] then
                    local mx, my = centre_of(cx, cy)
                    local d = sqrt((mx - px) ^ 2 + (my - py) ^ 2)"""
NEW3 = """                if self.cells[key_of(cx, cy)] then
                    local mx, my = centre_of(cx, cy)
                    local d = sqrt((mx - px) ^ 2 + (my - py) ^ 2)
                    if sqrt((mx - ax) ^ 2 + (my - ay) ^ 2) > limit then
                        d = -1                     -- outside support: not a candidate
                    end"""
assert OLD3 in s
s = s.replace(OLD3, NEW3, 1)

# and the fallback-to-block-centre path
OLD4 = """            if sqrt((mx - px) ^ 2 + (my - py) ^ 2) > mind then
                return mx, my, ranked[i].s
            end"""
NEW4 = """            if sqrt((mx - px) ^ 2 + (my - py) ^ 2) > mind
               and sqrt((mx - ax) ^ 2 + (my - ay) ^ 2) <= limit then
                return mx, my, ranked[i].s
            end"""
assert OLD4 in s
s = s.replace(OLD4, NEW4, 1)
p.write_text(s, encoding="utf-8")
print("SearchField: legs bounded to the field support")

# ---- 2. Suite refuses an absurd leg outright -------------------------------
q = Path(r"C:\Ascension\Workspace\RaijinLab\addon\modules\questing\Suite.lua")
t = q.read_text(encoding="utf-8")
OLD5 = """        st.tx, st.ty = bx, by
        st.tz = pz"""
NEW5 = """        -- SECOND LINE OF DEFENCE. The field bounds its own answers, but this is
        -- the layer that actually commits the character to walking somewhere, so
        -- it refuses an impossible leg rather than trusting its supplier. Fifty
        -- seconds were spent walking at a target 10698 yards away because nothing
        -- here asked whether the distance was sane.
        local leg = math.sqrt((bx - px) ^ 2 + (by - py) ^ 2)
        if leg > Suite.SEARCH_MAX_LEG then
            Suite._fields[key] = nil
            Suite._search[key] = nil
            local Tel = RaijinLab and RaijinLab.Telemetry
            if Tel then Tel.warn("quest", "absurd_leg",
                { label = tostring(label), leg = math.floor(leg) }) end
            return kind .. ":none in range, none remembered (" .. tostring(label) .. ")"
        end
        st.tx, st.ty = bx, by
        st.tz = pz"""
assert OLD5 in t
t = t.replace(OLD5, NEW5, 1)
t = t.replace("Suite.SEARCH_SIGHT = 150.0",
              "Suite.SEARCH_SIGHT = 150.0\n"
              "-- yd: no single search leg may be longer than this. A sweep is local; a\n"
              "-- proposal to cross the map is a bug in whatever produced the cell.\n"
              "Suite.SEARCH_MAX_LEG = 1200.0", 1)
q.write_text(t, encoding="utf-8")
print("Suite: refuses an absurd leg")
