from pathlib import Path

p = Path(r"C:\Ascension\Workspace\RaijinLab\addon\core\Navigator.lua")
s = p.read_text(encoding="utf-8")

OLD = """    -- predictive terrain: probe where we intend to go and act on it
    terrain_probe(a, px, py, pz, target_h)"""

NEW = """    -- PROBE WHERE THE BODY IS GOING, NOT WHERE WE WISH IT WERE GOING.
    --
    -- This probed target_h - the heading we WANT. But move_cone is 1.6 rad, so
    -- the character runs forward while up to 92 degrees off target: it physically
    -- travels along its FACING and collides along its FACING, while the probe was
    -- sampling a line it was not on. Nothing ever looked at what was actually in
    -- front of the character, which is exactly why it walked into a building "with
    -- no idea it was there" - the ray was pointed somewhere else entirely.
    -- Live evidence: 9684 log lines, one single wall detection.
    --
    -- Probe the travel direction first (that is what we will hit), then the
    -- desired heading (that is what we are turning into). A hit on either is a
    -- blocker: one stops us now, the other stops us a moment from now.
    local travel_h = cf or target_h
    terrain_probe(a, px, py, pz, travel_h)
    if not (a.block or (a.detour or 0) ~= 0 or a.want_jump) then
        local dh = math.abs(Navigator.angle_diff(travel_h, target_h))
        if dh > 0.25 then
            -- Only worth a second cast when the two genuinely differ; probe_hz
            -- throttles the pair together so this does not double the raycasts
            -- in the common aimed-and-running case.
            a.probe_t = nil
            terrain_probe(a, px, py, pz, target_h)
        end
    end"""
assert OLD in s, "probe call site not found"
s = s.replace(OLD, NEW, 1)
p.write_text(s, encoding="utf-8")
print("Navigator: probes the actual travel direction, then the desired one")
