-- Steering-based navigation executor.
--
-- Moves the character the HUMAN way - turn toward a heading, run forward, jump
-- obstacles - NEVER click-to-move (CTM is 100% forbidden). Turning uses the client's
-- own TurnLeft/TurnRight (keyboard-flag turn): fully IN-PROCESS, no OS mouse, no
-- cursor capture, so the user's physical mouse stays free while the bot steers.
-- Closed loop on the REAL heading read from the camera (camera-forward == facing).
--   TurnLeft/TurnRight, MoveForwardStart/Stop, StrafeLeft/Right, Jump, StopMoving,
--   Ascend/Descend and PitchUp/PitchDown holds (swim depth, runtime 1.8.17-pitch).
--
-- Three layers:
--   * OBJECT detection - the object manager gives nearby units/objects with
--     positions; the steerer repels away from those that are ahead (potential
--     field), so it flows around mobs/props instead of bumping them.
--   * TERRAIN handling - the client's own physics does the colliding (you cannot
--     walk through a wall or off-mesh); the steerer DETECTS terrain by watching
--     whether it is actually advancing and runs an escalating unstuck routine
--     (jump -> jitter facing -> strafe -> back up). NOTE: predictive terrain
--     raycasting (runtime TraceLine) and navmesh pathing (runtime FindPath) are
--     currently STUBS in the bridge, so this is reactive, not look-ahead; when
--     those land, avoid_heading/goto can consult them for look-ahead.
--   * PATHING - follows a supplied waypoint list node by node; between nodes it
--     steers directly with avoidance. Long cross-terrain routes therefore need
--     waypoints (recorded/route) until the navmesh is implemented.
--
-- Runs its OWN high-frequency OnUpdate ticker (~33 Hz) so turning is smooth and
-- stuck detection is fine-grained, decoupled from the slow decision loops that
-- only call Navigator.move_to(goal) and poll Navigator.state.

local Navigator = {}
Navigator.state = "idle"          -- idle | moving | waypoint | arrived | stuck
Navigator._active = nil
Navigator._moving = false
Navigator._strafe = nil           -- "left" | "right" | nil (edge-tracked)
Navigator._turn = nil             -- "left" | "right" | nil (edge-tracked keyboard turn)
Navigator._pitch = nil            -- "up" | "down" | nil (edge-tracked swim pitch hold)
Navigator._wet = false            -- swimming on the previous step (water->land edge detect)
Navigator._last_heading = nil     -- previous live heading (fallback when a read misses)

local PI2 = math.pi * 2
-- WoW's Lua 5.1 has atan2(y,x); newer Lua (test harness) folded it into a
-- 2-arg math.atan. Bind whichever exists so the geometry is portable + correct.
local atan2 = math.atan2 or math.atan
local function now() return (GetTime and GetTime()) or 0 end
local function dlog(cat, ...) local DL = RaijinLab and RaijinLab.DevLog; if DL then DL.log(cat, ...) end end

local DEFAULTS = {
    -- Keyboard-flag turn (mouse-free): the client turns at a fixed rate while the
    -- TurnLeft/TurnRight flag is held. Closed loop on the real (camera) heading with
    -- hysteresis - engage past turn_start, release within turn_stop.
    -- "turnby" = variable-rate in-process yaw (sharp for big errors, gentle for
    -- small); "keyboard" = the client's fixed single turn rate, which is what
    -- makes the bot feel stiff and unable to turn. turnby was opt-in only because
    -- its self-check needs a REAL heading to confirm the character is rotating,
    -- and the heading read was broken. It is not any more, and turn_toward still
    -- auto-falls back to keyboard if the rotation does not actually happen.
    -- Keyboard turn is the client's real fixed-rate yaw - human-like and proven.
    -- TurnByDelta often failed effectiveness checks (live: head jumped while travel
    -- stayed flat), then flapped method mid-walk. Prefer keyboard; turnby stays
    -- available if Caps forces it later.
    turn_method = "keyboard",
    turn_rate = 7.0,          -- rad/s cap for TurnByDelta if used
    turn_start = 0.18,        -- rad (~10 deg): re-engage (less fidget)
    turn_stop = 0.10,         -- rad (~6 deg): aligned; stop turning
    target_smooth = 0.22,     -- slower aim settle (was 0.35) - less left/right hunt
    arrive_dist = 2.5,        -- yd to count the goal reached
    look_ahead = 5.0,         -- shorter look-ahead (was 7): less corner-cut / overshoot
    -- (strafe_deadband / strafe_off / strafe_cone removed: strafe is no longer a
    -- steering controller. Course is pure-pursuit's job; strafe belongs to the
    -- obstacle layer and is requested explicitly via force_strafe.)
                              -- with turning to close the gap faster), else just turn.
    -- Human locomotion: walk while turning only within a modest cone.
    -- Was 2.4 (~137deg): live logs show err=+1.5-2.0 with fwd=true -> circles.
    -- 0.85 rad (~50deg) is enough to arc gently; larger errors = turn in place.
    move_cone = 0.85,
    kbd_turn_rate = 3.1,      -- rad/s the client turns at (for dead-reckon while turning
                              -- in place); measured from /raijin turntest (~180 deg/s)
    stuck_dist = 0.8,         -- yd of progress required per window
    stuck_secs = 2.2,         -- was 1.1 - too aggressive: no-fwd due to false wall
                              -- probes hit stuck in ~1s and Jump-spammed
    avoid_clearance = 1.6,    -- yd padding around obstacles
    avoid_range = 6.0,        -- yd ahead to consider obstacles
    avoid_max_bend = 0.6,     -- rad: hard cap on how far avoidance may bend the goal
                              -- bearing. Uncapped, one mob near the goal line swung
                              -- the heading most of a half-turn and the bot left for
                              -- somewhere else entirely.
    jump_gap = 2.5,           -- was 0.7 - recovery Jump every 0.7s looked like
                              -- "random hopping"; one hop per 2.5s max
    -- Safety (prevents the "ran me under the map" failure):
    abort_fall = 20,          -- yd below the move's start Z while airborne => fell, hard stop
    max_airborne = 2.5,       -- secs off the ground before giving up the move (fell)
    move_deadline = 60,       -- secs before giving up on a goal (never run forever)
    max_recover = 8,          -- consecutive stuck recoveries before giving up
    detour_step = 0.6,        -- rad added to the goal heading per recovery to steer AROUND (not into) blockers
    -- Predictive terrain (real TraceLine raycasts):
    -- Higher Hz is fine: probe uses GroundCache + early-out centre ray first.
    probe_hz = 8,
    cliff_look = 2.5,         -- yd ahead to check for a floor before stepping
    max_step_down = 6,        -- yd of drop tolerated ahead; more => treat as a cliff, don't walk off
    wall_probe = 2.2,         -- yd ahead to raycast for walls
    jump_stall = 0.35,        -- secs without forward progress before a foot-lip hop is even considered
    wall_bend0 = 0.9,         -- rad: first bend on wall contact
    wall_bend_step = 0.25,    -- rad added per probe while contact persists (wall-following)
    wall_bend_max = 1.9,      -- rad: just past perpendicular, so a corner clears without reversing
    wall_relax = 0.4,         -- secs of clear probes before easing the bend back toward the goal
    -- A LONG WALL NEEDS A LONG COMMITMENT. 1.5s released the chosen side while
    -- still pressed against the same surface, so the next contact could pick the
    -- other way: the character walked north, reversed south, reversed north
    -- again, and covered 563yd of a wall it never got round. Rounding a building
    -- takes tens of seconds; the commitment has to outlive the obstacle, not the
    -- probe. Re-deciding is what wastes the distance already travelled.
    wall_commit = 12.0,        -- secs to hold a chosen way-around before re-deciding (anti-oscillation)
    body_radius = 0.45,       -- yd: half the character's width; probes sweep this, because a single centre ray threads trunks and posts
    wall_height = 1.4,        -- chest ray height: a hit here is a REAL wall (detour)
    wall_standoff = 0.15,     -- rad past the tangent while wall-following: biases
                              -- the heading slightly AWAY from the surface so the
                              -- body keeps clearance instead of scraping along it
    foot_height = 0.4,        -- foot ray height: a hit here alone is a hoppable lip (jump)
    max_replans = 5,          -- times to auto re-pathfind after getting stuck before giving up
    replan_cooldown = 2.0,    -- secs: min gap between replans (anti-flap; no recompute storms)
}
-- Bump when a tuning DEFAULT below changes so it overrides the value saved in
-- RaijinLabDB.nav from an older version (cfg() otherwise only fills MISSING keys,
-- so stale saved tuning - e.g. move_cone=0.9 - would silently shadow the new default).
local CFG_VERSION = 16
local FORCED_KEYS = { "move_cone", "turn_rate", "turn_start", "turn_stop",
                      "target_smooth", "kbd_turn_rate", "arrive_dist",
                      "look_ahead",
                      "replan_cooldown", "probe_hz", "stuck_secs", "jump_gap" }
local function cfg()
    RaijinLabDB = RaijinLabDB or {}
    local n = RaijinLabDB.nav or {}
    RaijinLabDB.nav = n
    if n._cfgver ~= CFG_VERSION then
        for _, k in ipairs(FORCED_KEYS) do n[k] = DEFAULTS[k] end   -- re-apply new tuning
        n._cfgver = CFG_VERSION
    end
    for k, v in pairs(DEFAULTS) do if n[k] == nil then n[k] = v end end
    return n
end

-- ================= pure geometry (unit-tested) =================

-- Normalize an angle to [0, 2pi).
function Navigator.norm(a)
    a = a % PI2
    if a < 0 then a = a + PI2 end
    return a
end

-- Shortest signed difference b-a in (-pi, pi].
function Navigator.angle_diff(a, b)
    local d = (b - a) % PI2
    if d > math.pi then d = d - PI2 end
    return d
end

-- WoW facing/orientation from (px,py) toward (gx,gy). atan2 convention matches
-- the client's orientation field, so FaceDirection(heading_to(...)) looks at the
-- point. (Runtime GetAnglesBetweenObjects is stubbed, so we compute it here.)
function Navigator.heading_to(px, py, gx, gy)
    return Navigator.norm(atan2(gy - py, gx - px))
end

-- Turn `cur` toward `target` by at most `max_step` radians (rate limiting =
-- smooth RMB-style turn instead of an instant snap).
function Navigator.step_facing(cur, target, max_step)
    local d = Navigator.angle_diff(cur, target)
    if math.abs(d) <= max_step then return Navigator.norm(target) end
    return Navigator.norm(cur + (d > 0 and max_step or -max_step))
end

-- Bend the goal heading AROUND obstacles that are AHEAD, so the path bows past
-- them. obstacles = { {x,y,r}, ... } in world coords; px,py the player. Pure.
-- Returns an adjusted heading.
--
-- THE REPULSION USED TO BE RADIAL AND UNBOUNDED, WHICH IS WHY THE BOT "RAN OFF IN
-- A RANDOM DIRECTION". Each obstacle pushed straight away from itself with weight
-- up to 1.6 against a UNIT goal vector, so one unit or prop sitting near the goal
-- bearing at a few yards out-voted the goal outright: a mob standing between us
-- and the destination produced a push almost exactly opposite the goal, and the
-- resulting heading flipped by 90-180 degrees. Worse, a head-on obstacle pushes
-- back along the goal line, which cancels the goal instead of choosing a side -
-- the character faces away from where it wants to go and the pursuit loop then
-- fights it. Three properties fix that:
--   * TANGENTIAL, not radial. Steer along the obstacle's tangent, on the side the
--     goal already favours (sign of the obstacle-normal x goal cross product), so
--     avoidance SLIDES PAST instead of reversing. Because that tangent is picked
--     to have a non-negative dot with the goal direction, the blended vector can
--     never oppose the goal - no obstacle arrangement can turn the bot around.
--   * CLAMPED. Total deflection is capped, so no obstacle (or pile-up of them)
--     can dominate the goal bearing; the worst case is a lean, not a U-turn.
--   * SMOOTH. Weight follows a smoothstep that reaches exactly zero at the
--     influence radius, and the in-front test fades instead of switching, so an
--     obstacle drifting in or out of range cannot step-change the heading. The
--     old hard `ahead > 0.15` cut made the target heading jump every time a
--     wandering mob crossed the cone edge.
function Navigator.avoid_heading(px, py, goal_h, obstacles, opts)
    opts = opts or {}
    local clearance = opts.avoid_clearance or DEFAULTS.avoid_clearance
    local range = opts.avoid_range or DEFAULTS.avoid_range
    local max_bend = opts.avoid_max_bend or DEFAULTS.avoid_max_bend or 0.6
    local gx, gy = math.cos(goal_h), math.sin(goal_h)
    local vx, vy = gx, gy
    for _, o in ipairs(obstacles or {}) do
        local ox, oy = o.x - px, o.y - py
        local d = math.sqrt(ox * ox + oy * oy)
        local reach = (o.r or 2.0) + clearance + range   -- influence radius
        if d > 0.01 and d < reach then
            local nx, ny = ox / d, oy / d
            -- only avoid things roughly in front, ramped over the cone edge
            local ahead = ((nx * gx + ny * gy) - 0.15) / 0.85
            if ahead > 0 then
                if ahead > 1 then ahead = 1 end
                local t = (reach - d) / reach
                local w = t * t * (3 - 2 * t) * ahead    -- smoothstep: 0 at reach
                -- Left tangent of the obstacle normal is (-ny, nx); its dot with
                -- the goal direction is exactly this cross product, so the sign
                -- picks whichever way round already heads toward the goal.
                local side = ((nx * gy - ny * gx) >= 0) and 1 or -1
                vx = vx - ny * side * w
                vy = vy + nx * side * w
            end
        end
    end
    if vx * vx + vy * vy < 1e-6 then return goal_h end
    local h = Navigator.norm(atan2(vy, vx))
    local bend = Navigator.angle_diff(goal_h, h)
    if bend > max_bend then return Navigator.norm(goal_h + max_bend) end
    if bend < -max_bend then return Navigator.norm(goal_h - max_bend) end
    return h
end

-- PURE PURSUIT over a route polyline (list of {x,y}). Instead of chasing the exact
-- next waypoint (which makes the character wobble and overshoot), we steer toward a
-- LOOK-AHEAD point that slides `look` yd ahead ALONG the line - the path is tracked
-- smoothly and corners are cut like a human. Returns:
--   aimx, aimy = the look-ahead point to face
--   cross      = signed cross-track offset (+ = character is LEFT of the path dir)
--   idx        = advanced current-segment index (monotone progress)
--   remain     = remaining path length from the projection to the goal (path end)
-- Pure + unit-tested. No side effects.
function Navigator.pursuit(path, idx, px, py, look)
    local n = #path
    if n == 0 then return px, py, 0, 1, 0 end
    if n == 1 then
        local dx, dy = path[1].x - px, path[1].y - py
        return path[1].x, path[1].y, 0, 1, math.sqrt(dx * dx + dy * dy)
    end
    idx = idx or 1
    if idx < 1 then idx = 1 elseif idx > n - 1 then idx = n - 1 end
    -- closest projection over segments idx..idx+4 (advance, never regress the index)
    local bi, bd2, bcx, bcy
    for i = idx, math.min(idx + 4, n - 1) do
        local ax, ay = path[i].x, path[i].y
        local ex, ey = path[i + 1].x - ax, path[i + 1].y - ay
        local L2 = ex * ex + ey * ey
        local t = 0
        if L2 > 1e-6 then t = ((px - ax) * ex + (py - ay) * ey) / L2 end
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        local cx, cy = ax + ex * t, ay + ey * t
        local d2 = (px - cx) * (px - cx) + (py - cy) * (py - cy)
        if not bd2 or d2 < bd2 then bd2, bi, bcx, bcy = d2, i, cx, cy end
    end
    idx = bi
    -- signed cross-track vs the current segment's direction (left-normal)
    local ex, ey = path[idx + 1].x - path[idx].x, path[idx + 1].y - path[idx].y
    local elen = math.sqrt(ex * ex + ey * ey)
    local cross = 0
    if elen > 1e-6 then cross = (px - bcx) * (-ey / elen) + (py - bcy) * (ex / elen) end
    -- walk `look` yd forward along the polyline from the projection -> aim point
    local rem, lx, ly = look, bcx, bcy
    local sx, sy = bcx, bcy
    for i = idx, n - 1 do
        local tx, ty = path[i + 1].x, path[i + 1].y
        local seg = math.sqrt((tx - sx) * (tx - sx) + (ty - sy) * (ty - sy))
        if seg >= rem then
            local f = (seg > 1e-6) and (rem / seg) or 0
            lx, ly = sx + (tx - sx) * f, sy + (ty - sy) * f
            rem = 0; break
        end
        rem = rem - seg; lx, ly = tx, ty; sx, sy = tx, ty
    end
    -- remaining length from projection to the goal
    local remain, rx, ry = 0, bcx, bcy
    for j = idx, n - 1 do
        local tx, ty = path[j + 1].x, path[j + 1].y
        remain = remain + math.sqrt((tx - rx) * (tx - rx) + (ty - ry) * (ty - ry))
        rx, ry = tx, ty
    end
    return lx, ly, cross, idx, remain
end

-- ================= live steering =================

local function player_pos()
    if RaijinLab and RaijinLab.ObjectPosition then return RaijinLab:ObjectPosition("player") end
end
-- CHARACTER HEADING from the CAMERA. The local player's live heading is NOT kept
-- at object+0x7A4 (that field reads ~0 for the controlled player - the client keeps
-- heading in the movement/camera system); ObjectFacing is therefore useless here.
-- But the camera matrix read is live, and because we steer in MOUSELOOK (camera
-- locked directly behind the character), camera-forward heading == character
-- facing. Proven by /raijin turntest: the camera swung 0.37->3.69 rad with the
-- character while ObjectFacing stayed pinned at ~0. atan2(fwd.y,fwd.x) ignores the
-- camera pitch and yields the yaw = the direction the character faces / travels.
-- The character's REAL heading - CAMERA-INDEPENDENT (immune to free-look). While
-- the character is moving, its TRAVEL bearing IS its facing (MoveForward moves along
-- the facing); we sample that from the position delta. While turning in place (not
-- moving) we dead-reckon by the known turn rate. The camera heading is only the
-- cold-start fallback (before the character has moved). This is what fixes both the
-- wandering AND free-look: neither the camera nor the dead 0x7A4/stale PlayerFacing
-- is trusted for control.
-- A TRUST FLAG MUST NOT LATCH. These verdicts compare a heading source against the
-- TRAVEL bearing, so they can only be refreshed while the character is MOVING. A
-- single disagreement recorded just before stopping used to condemn that source
-- indefinitely - the live log showed cam=(ok=false) on every sample of a
-- 166-minute session, which is how control fell through to dead-reckoning and
-- drifted 155 degrees out of date. Verdicts expire.
Navigator.TRUST_TTL = 3.0

-- yd: how far a TraceLine miss is actually meaningful. Collision is streamed in
-- around the player, so beyond roughly this range "nothing was hit" only means
-- "nothing is loaded there". Deliberately conservative: planning a route we did
-- not need costs a few ms, whereas trusting a phantom clear line costs a wall.
-- The BINDING guard on the instant-direct shortcut. LOS_TRUST_RANGE (200) never
-- binds because this is far smaller, so `d <= 12 and d <= 200` is just `d <= 12`
-- - a mutation deleting the 200 guard is inert, which is why the harness could
-- not defend it. 12 is the number that keeps the character out of the church:
-- a LoS-clear ray at 22-36yd steered direct into the same building repeatedly.
Navigator.LOS_SHORTCUT_MAX = 12
Navigator.LOS_TRUST_RANGE = 200

-- secs a measured travel bearing stays usable as the probe direction. One steer
-- tick is ~30ms, so anything older than this means the body has not displaced and
-- the sample describes a motion that has already ended.
local TRAVEL_FRESH = 0.25

function Navigator.verdict(key, agree)
    Navigator[key] = agree
    Navigator[key .. "_t"] = now()
end

function Navigator.trusted(key)
    local v = Navigator[key]
    if v == nil then return nil end
    if (now() - (Navigator[key .. "_t"] or 0)) > Navigator.TRUST_TTL then return nil end
    return v
end

local function measure_facing(px, py, dt)
    -- TRAVEL bearing = ground truth WHILE MOVING; used to VALIDATE the camera
    -- (detect free-look). Ignore teleports (>1.5yd/tick).
    local travel
    if px and Navigator._fh_px then
        local dx, dy = px - Navigator._fh_px, py - Navigator._fh_py
        local d2 = dx * dx + dy * dy
        if d2 > (0.04 * 0.04) and d2 < (1.5 * 1.5) then travel = Navigator.norm(atan2(dy, dx)) end
    end
    Navigator._fh_px, Navigator._fh_py = px, py
    Navigator._travel_now = travel
    -- Stamped, because consumers outside this function (the terrain probe) steer a
    -- raycast down this bearing: aiming a sweep along a direction the body stopped
    -- travelling seconds ago samples ground the character is nowhere near.
    if travel then Navigator._travel_t = now() end

    -- CAMERA heading = the PRIMARY read: the follow-camera swings with the character
    -- whether it's moving OR turning in place, so this tracks rotation continuously -
    -- which is exactly what lets it do a clean 180/360. atan2(fwd.y,fwd.x).
    local cam
    local c = RaijinLab and RaijinLab.GetCameraData and RaijinLab:GetCameraData()
    if c and c.fx and (c.fx * c.fx + c.fy * c.fy) > 1e-6 then cam = Navigator.norm(atan2(c.fy, c.fx)) end
    Navigator._cam_now = cam
    -- LIVE FACING (player+0x7AC) - the value the CLIENT ITSELF steers by, exposed
    -- by the runtime since 1.8.8-livefacing. This is strictly better than every
    -- source below it: camera-independent (immune to free-look), valid whether the
    -- character is moving or standing still, and never accumulates drift.
    --
    -- The block below used to read it only to PRINT it, because it was written
    -- when the field returned garbage (4.5e20). It is fixed now, and continuing to
    -- steer by dead-reckoning instead cost real accuracy: the live log showed the
    -- reckoned heading 155 degrees out of date, snapping the instant a travel
    -- bearing arrived, which is what made the bot oscillate left-right-left and
    -- never converge.
    local live
    local a = RaijinLab and RaijinLab.Actions
    if a and a.PlayerFacing then
        local f = a.PlayerFacing()
        if RaijinLab.ValidFacing then f = RaijinLab.ValidFacing(f) end
        if type(f) == "number" then live = Navigator.norm(f) end
    end
    Navigator._pf_now = live

    -- Trust but verify: while moving, facing and travel bearing must agree, since
    -- MoveForward travels along the facing. Keeps a bad build from steering blind.
    if live and travel then
        local agree = math.abs(Navigator.angle_diff(live, travel)) < 0.7
        Navigator.verdict("_pf_ok", agree)
        -- While moving, travel is ground truth. A disagreeing "live" read made
        -- the steerer flip headings (live log: head 1.4->0.58->1.8 while travel
        -- stayed 1.4) which is the robotic left-right dance.
        if not agree then live = nil end
    end
    if cam and travel then Navigator.verdict("_cam_ok", math.abs(Navigator.angle_diff(cam, travel)) < 0.6) end

    -- A FROZEN READ IS NOT A HEADING. The live field can come back stuck - the
    -- observed failure was exactly 0.000 forever - and a constant value passes
    -- every check that only asks "is this a number in range". The loop then aims
    -- at a heading that never moves, commands a turn, sees no change, and turns
    -- again: the character spins on the spot while every individual reading looks
    -- fine.
    --
    -- The distinguishing evidence is not the value, it is the RESPONSE: while we
    -- are actively commanding a turn, a live heading MUST change. If it does not
    -- across a sustained command, the source is dead - fall through to travel,
    -- camera, then dead-reckoning, all of which do move.
    --
    -- This guard existed before (documented as "never trust a frozen read") and
    -- was lost when live facing became primary. Re-added, and now with a test.
    if live then
        local commanding = (Navigator._turn ~= nil)
            or ((Navigator._last_turn_cmd or 0) ~= 0)
        if commanding then
            if Navigator._pf_prev and math.abs(Navigator.angle_diff(Navigator._pf_prev, live)) < 0.0005 then
                Navigator._pf_still = (Navigator._pf_still or 0) + 1
            else
                Navigator._pf_still = 0
                Navigator._turn_suspect_since = nil   -- it moved: not suspect
            end
            if (Navigator._pf_still or 0) >= 20 then
                Navigator.verdict("_pf_ok", false)     -- expires like any verdict
                -- A FROZEN HEADING UNDER COMMAND HAS TWO CAUSES, NOT ONE.
                --
                -- This concluded "the sensor is dead" and fell through to
                -- dead-reckoning - which INTEGRATES THE COMMANDS WE SENT. If the
                -- real fault is the actuator (this client: keyboard turning does
                -- nothing), the estimate then believes every turn that never
                -- happened, the heading error looks small, and the bot drives at
                -- full speed in the direction it is actually facing. That is the
                -- "spazzing into a wall" the user watched, and no layer below can
                -- detect it because the navigator has stopped measuring.
                --
                -- We cannot tell sensor from actuator here, so we do not guess:
                -- record the suspicion and let the run-blind interlock refuse
                -- forward until something starts responding. Standing still with
                -- a broken heading is always better than running with one.
                Navigator._turn_suspect_since = Navigator._turn_suspect_since or now()
            end
        end
        Navigator._pf_prev = live
    end

    if live and Navigator.trusted("_pf_ok") ~= false then
        Navigator._facing_real = live
        return live
    end
    -- Fallbacks, in descending order of reliability.
    if travel then
        Navigator._facing_real = travel
        return travel
    end
    if cam and Navigator.trusted("_cam_ok") ~= false then
        Navigator._facing_real = cam
        return cam
    end
    if Navigator._turn and Navigator._facing_real then
        local sgn = (Navigator._turn == "left") and 1 or -1
        Navigator._facing_real = Navigator.norm(Navigator._facing_real + sgn * (cfg().kbd_turn_rate or 3.1) * (dt or 0.033))
        return Navigator._facing_real
    end
    return Navigator._facing_real or cam
end
local function A() return RaijinLab and RaijinLab.Actions end

-- Edge-triggered movement so we don't spam key-down every frame.
-- WHAT A MISSING FLOOR ACTUALLY MEANS.
--
-- The downward trace spans 6yd and its flags carry no liquid bit, so it cannot
-- see a water surface at all. The planner routes through water on purpose, so
-- "the ray found nothing" is the NORMAL reading while swimming - and treating it
-- as falling aborted with "stopped: left the ground" in the middle of a lake,
-- then burned a false BLOCKED cell into the persistent mesh on the way out.
--
-- Three-valued on purpose. "unknown" is not "airborne": only a definite no-floor
-- with a definite not-swimming is grounds for the fall abort.
function Navigator.floor_verdict(gz, swimming)
    if gz ~= nil then return "grounded" end
    if swimming then return "swimming" end
    return "airborne"
end

-- Breath remaining in [0,1], or nil when the timer is not running (full lungs /
-- no API). Pure enough for tests: only reads GetMirrorTimerInfo.
function Navigator.breath_frac()
    if type(GetMirrorTimerInfo) ~= "function" then return nil end
    local ok, name, value, maxvalue = pcall(GetMirrorTimerInfo, "BREATH")
    if not ok then return nil end
    if name ~= "BREATH" then return nil end
    maxvalue = tonumber(maxvalue) or 0
    value = tonumber(value) or 0
    if maxvalue <= 0 then return nil end
    local f = value / maxvalue
    if f < 0 then f = 0 elseif f > 1 then f = 1 end
    return f
end

-- Vertical-only helper (kept for tests / callers). Prefer swim_control for the
-- full held-key + breath-latch policy.
function Navigator.swim_vertical_need(pz, goal_z, breath, opts)
    local r = Navigator.swim_control(true, pz, goal_z, breath, nil, false, opts)
    return r and r.vert or nil
end

-- Shore transition policy. Pure: no API calls.
-- "climb_out" / "enter" / "open_water" / nil
function Navigator.shore_intent(swimming, floor_ahead, water_ahead, goal_dry)
    if swimming then
        if goal_dry then return "climb_out" end
        if floor_ahead and not water_ahead then return "climb_out" end
        return "open_water"
    end
    if water_ahead then return "enter" end
    return nil
end

-- FULL swim decision. Pure. Returns a table so tests assert the whole contract,
-- not a single field that can be right while the rest is wrong:
--   vert            "up" | "down" | nil   -- which vertical key to HOLD
--   force_forward   bool                  -- keep driving (climb-out / enter)
--   clear_cliff     bool                  -- do not cliff-block forward
--   surface_latch   bool                  -- breath emergency still active
--   note            "breath_panic" | "surfaced" | nil
--
-- Breath uses hysteresis: panic enters at breath_panic, stays latched until
-- breath recovers to breath_recover (or timer clears). A single tick of "up"
-- then diving again is how you drown with a green status light.
function Navigator.swim_control(swimming, pz, goal_z, breath, shore, surface_latch, opts)
    opts = opts or {}
    local panic = opts.breath_panic or 0.25
    local recover = opts.breath_recover or 0.55
    local dead = opts.z_deadband or 1.5
    local out = {
        vert = nil, force_forward = false, clear_cliff = false,
        surface_latch = false, note = nil,
    }
    if not swimming then
        if surface_latch then out.note = "surfaced" end
        -- Enter is a dry-feet decision: clear the cliff block so we step in.
        if shore == "enter" then
            out.force_forward = true
            out.clear_cliff = true
        end
        return out
    end
    local latch = not not surface_latch
    if breath ~= nil and breath < panic then
        latch = true
        out.note = "breath_panic"
    end
    if latch and (breath == nil or breath >= recover) then
        latch = false
    end
    out.surface_latch = latch

    if latch or shore == "climb_out" then
        out.vert = "up"
    elseif goal_z ~= nil and pz ~= nil then
        if (goal_z - pz) > dead then out.vert = "up"
        elseif (pz - goal_z) > dead then out.vert = "down" end
    end

    if shore == "climb_out" or shore == "enter" then
        out.force_forward = true
        out.clear_cliff = true
    end
    return out
end

-- Depth-hold plan while swimming. Pure - step() applies it edge-triggered.
-- PITCH + FORWARD is the primary depth mechanism: the client swims along the
-- nose, so pitch down + forward IS diving and pitch up + forward IS surfacing
-- at full swim speed. The ascend/descend holds (slow, thrustless bobbing) are
-- kept ONLY as the vertical fallback when forward is not actually driving.
--   vert   from swim_control - already deadbanded by z_deadband, so inside the
--          depth band this yields level pitch (nil): no porpoising around the
--          target z.
--   latch  breath emergency overrides everything: pitch up + forward + ascend
--          TOGETHER, and pitch down is unreachable until the latch clears - a
--          single tick of nose-down with empty lungs is the drowning-with-a-
--          green-status-light bug all over again.
--   fwd    forward is ENGAGED AND EFFECTIVE (measured, not commanded).
--   shore  "climb_out" keeps the proven ascend+forward lip-pop even while
--          forward drives; pitch alone noses into the bank below the lip.
function Navigator.swim_hold_plan(swimming, vert, latch, fwd, shore)
    local plan = { pitch = nil, ascend = false, descend = false }
    if not swimming then return plan end
    if latch then
        plan.pitch = "up"
        plan.ascend = true
        return plan
    end
    if vert == "up" then
        if fwd then plan.pitch = "up" end
        if (not fwd) or shore == "climb_out" then plan.ascend = true end
    elseif vert == "down" then
        if fwd then plan.pitch = "down" else plan.descend = true end
    end
    return plan
end

-- COMMANDING FORWARD IS NOT MOVING FORWARD.
--
-- Actions.MoveForward -> runtime MoveForwardStart -> SafeVoid(), which returns 1
-- for "the call did not raise an exception". It never checks that the character
-- moved, so a primitive that does nothing reports success and the steering loop
-- happily believes it is driving.
--
-- Observed live: 273 ticks with fwd=true, heading error converged under 0.5rad
-- on 235 of them, and the position stayed at (1847.93, 1420.04) for sixteen
-- seconds while the client's own flag read moving=false. The loop was perfect
-- and the character never took a step. "It did nothing" was exactly right.
--
-- So verify the command against the world. This does not fix a dead primitive -
-- it makes it impossible for one to be silent, which is the only reason the
-- earlier sessions looked like a navigation bug.
Navigator._fwd_since = nil
Navigator._fwd_from = nil
Navigator.MOVE_PROVE_SECS = 1.5     -- held forward this long with no displacement = dead

-- A BOT THAT CANNOT AIM MUST NOT RUN.
--
-- Every "spazzing into a wall" report has the same shape: a large heading error
-- that never shrinks, while forward is held down. The character then drives at
-- full speed in whatever direction it happens to face, scrubbing along geometry.
-- Steering is a PRECONDITION for moving, so forward is refused while the heading
-- is badly wrong and the last turn command demonstrably did not rotate us.
-- This cannot deadlock: turning happens with forward released, and as soon as
-- the error closes (or the heading starts responding) movement resumes.
-- Pure, and deliberately NOT based on the per-method effectiveness counters:
-- switch_turn_method resets those every time it flips, so with both methods dead
-- the evidence was wiped on each flip and this never fired - which is exactly the
-- live behaviour (alternating methods, forward held, character grinding a wall).
-- Duration of a bad heading is the honest signal: if we have been pointed the
-- wrong way for AIM_GRACE seconds, we are not steering, whatever the cause.
function Navigator.aim_unusable(susp_since, tnow)
    if susp_since == nil then susp_since = Navigator._turn_suspect_since end
    if tnow == nil then tnow = now() end
    -- Sustained suspicion that the heading is not responding is enough on its
    -- own: once dead-reckoning takes over, `err` is computed against a believed
    -- heading and stops being evidence of anything.
    -- THE SIGNAL IS "NOT RESPONDING", NOT "ERROR IS LARGE".
    --
    -- A large heading error while actively turning is NORMAL - it is what a turn
    -- looks like from the inside. Refusing to move on error alone stopped the bot
    -- mid-turn on a legitimate correction and broke wall-following, where the
    -- commanded heading is deliberately far off the goal. What is never normal is
    -- a heading that does not move while we are commanding it to: that is
    -- `_turn_suspect_since`, set by the frozen-read guard, and it is the only
    -- evidence used here.
    if type(susp_since) ~= "number" or type(tnow) ~= "number" then return false end
    return (tnow - susp_since) >= (Navigator.AIM_GRACE or 1.5)
end

Navigator.AIM_GRACE = 1.5      -- s: how long a bad heading may persist before we stop
Navigator.AIM_ABORT_TICKS = 3  -- refusals before the move is abandoned outright

local function set_forward(on)
    -- ONE CHOKE POINT FOR "NEVER WALK INTO NOTHING".
    --
    -- Four separate places re-enabled forward with no floor ahead: the wall
    -- follow override, the >50-step anti-stall nudge, stuck recovery's direct
    -- set_forward(true), and the recovery jump. Each was found and fixed one at a
    -- time, and each fix left the others walking off the same cliff - which is
    -- why the symptom never visibly improved. Patching call sites is what let
    -- four of them accumulate in the first place, and it cannot cover the fifth.
    --
    -- So the rule lives where the key is actually written. Every caller, present
    -- and future, is now subject to it: if the probe says there is no floor on
    -- this heading, forward does not go on. This mirrors the aim_unusable guard
    -- immediately below - the same shape of invariant, enforced the same way.
    local act = Navigator._active
    if on and act and act.block_void then
        on = false
        Navigator._held_for_void = true
        Navigator._held_for_void_n = (Navigator._held_for_void_n or 0) + 1
        local DL = RaijinLab and RaijinLab.DevLog
        if DL and DL.log_every then
            DL.log_every("nav_void", 1.0, "nav",
                "forward refused: no floor ahead (%d)", Navigator._held_for_void_n)
        end
    else
        Navigator._held_for_void = false
    end
    if on and Navigator.aim_unusable() then
        on = false
        Navigator._held_for_aim = true
        Navigator._held_for_aim_n = (Navigator._held_for_aim_n or 0) + 1
    else
        Navigator._held_for_aim = false
    end
    if Navigator._moving == on then return end
    Navigator._moving = on
    local a = A(); if a and a.MoveForward then a.MoveForward(on) end
    if on then
        local px, py = player_pos()
        Navigator._fwd_since = now()
        Navigator._fwd_from = px and { x = px, y = py } or nil
    else
        Navigator._fwd_since = nil
        Navigator._fwd_from = nil
    end
end

-- Did holding forward actually displace us? Three-valued: nil while we have not
-- held it long enough to judge, true once we have moved, false when the hold has
-- lasted long enough that a working primitive MUST have produced displacement.
function Navigator.forward_effective()
    if not (Navigator._moving and Navigator._fwd_since and Navigator._fwd_from) then
        return nil
    end
    local px, py = player_pos()
    if not px then return nil end
    local d = math.sqrt((px - Navigator._fwd_from.x) ^ 2 + (py - Navigator._fwd_from.y) ^ 2)
    if d > 1.0 then return true end
    if (now() - Navigator._fwd_since) < Navigator.MOVE_PROVE_SECS then return nil end
    return false
end
local function set_strafe(dir)     -- dir: "left"|"right"|nil
    if Navigator._strafe == dir then return end
    local a = A()
    if a then
        if Navigator._strafe == "left" and a.StrafeLeft then a.StrafeLeft(false) end
        if Navigator._strafe == "right" and a.StrafeRight then a.StrafeRight(false) end
        if dir == "left" and a.StrafeLeft then a.StrafeLeft(true) end
        if dir == "right" and a.StrafeRight then a.StrafeRight(true) end
    end
    Navigator._strafe = dir
end
-- Swim vertical holds. Mutual exclusion: never hold ascend and descend together.
local function set_ascend(on)
    if Navigator._ascend == on then return end
    local a = A()
    if a and a.Ascend then a.Ascend(on) end
    Navigator._ascend = on
end
local function set_descend(on)
    if Navigator._descend == on then return end
    local a = A()
    if a and a.Descend then a.Descend(on) end
    Navigator._descend = on
end
local function release_vertical()
    set_ascend(false)
    set_descend(false)
end
-- Swim pitch holds (runtime 1.8.17-pitch). Edge-tracked like every other move
-- key so a hold is only (re)issued on state CHANGE; the runtime stops the
-- opposite direction on start, so the pair cannot wedge each other.
local function set_pitch(dir)      -- "up" | "down" | nil, edge-triggered
    if Navigator._pitch == dir then return end
    local a = A()
    if a then
        if Navigator._pitch == "up" and a.PitchUp then a.PitchUp(false) end
        if Navigator._pitch == "down" and a.PitchDown then a.PitchDown(false) end
        if dir == "up" and a.PitchUp then a.PitchUp(true) end
        if dir == "down" and a.PitchDown then a.PitchDown(true) end
    end
    Navigator._pitch = dir
end
-- Edge/stop release: send BOTH stops even when the book-keeping says level.
-- A pitch hold that survives onto land corrupts the next movement (same class
-- as the held-key kill-switch bug), and the tracked state can desync from the
-- client across a /reload or runtime reinject - so leave-water/stop/abort
-- never trust it. NOT for per-tick use: inside the tick the edge-triggered
-- set_pitch keeps holds change-only.
local function release_pitch()
    local a = A()
    if a then
        if a.PitchUp then a.PitchUp(false) end
        if a.PitchDown then a.PitchDown(false) end
    end
    Navigator._pitch = nil
end
-- Pitch control shipped in runtime 1.8.17-pitch. An older bridge answers the
-- Pitch*Start command with a hardcoded success (SafeVoid: "did not throw"),
-- so Actions.PitchUp EXISTING proves nothing about capability - presence is
-- not capability, the trap that has already produced five defects here. Gate
-- on the runtime version the same way turning gates on Caps live_facing, so
-- an old bridge keeps the proven ascend/descend depth control instead of
-- silently losing depth-seeking to a no-op primitive.
local function pitch_capable()
    local Caps = RaijinLab and RaijinLab.Caps
    if not (Caps and Caps.know) then return false end
    local r = Caps.know("runtime")
    if not (r and r.state == "yes") then return false end
    local ver = tostring(r.value or "")
    if ver:find("pitch", 1, true) then return true end
    local M, m, p = ver:match("(%d+)%.(%d+)%.(%d+)")
    M, m, p = tonumber(M), tonumber(m), tonumber(p)
    if not (M and m and p) then return false end
    if M ~= 1 then return M > 1 end
    if m ~= 8 then return m > 8 end
    return p >= 17
end
-- ===== KEYBOARD-FLAG TURN (mouse-free, confirmed to rotate the character) =====
-- TurnLeft/TurnRight hold the client's own turn (fixed rate, ~180 deg/s) fully
-- IN-PROCESS - no OS mouse, no cursor capture, so the physical mouse stays free.
-- We close the loop on the REAL (camera) heading: turn the shortest way toward the
-- target, stop when aligned. + heading = CCW = TurnLeft (verified via /raijin turntest).
local function set_turn(dir)     -- "left"|"right"|nil, edge-triggered
    if Navigator._turn == dir then return end
    local a = A()
    if a then
        if Navigator._turn == "left"  and a.TurnLeft  then a.TurnLeft(false)  end
        if Navigator._turn == "right" and a.TurnRight then a.TurnRight(false) end
        if dir == "left"  and a.TurnLeft  then a.TurnLeft(true)  end
        if dir == "right" and a.TurnRight then a.TurnRight(true) end
    end
    Navigator._turn = dir
end
local function turn_stop() set_turn(nil) end

-- One tick of the closed-loop turn toward `target`. `cur` is the real heading.
-- PRIMARY method "turnby": a fast, VARIABLE in-process yaw delta each frame (sharp
-- flick for big errors, gentle for small) via the client's own TurnByDelta - no OS
-- mouse, no cursor capture. If it proves not to actually rotate the character (the
-- real heading isn't moving while we command), it auto-falls-back to the fixed-rate
-- keyboard turn (known to rotate). Returns (aerr, errs, cmd, method).
local function turn_toward(cur, target, dt)
    local c = cfg()
    local errs = Navigator.angle_diff(cur, target)   -- signed (+ = target CCW)
    local aerr = math.abs(errs)
    local a = A()
    -- Prefer TurnBy when Caps.live_facing is yes (runtime 1.8.8-livefacing+).
    -- Otherwise keyboard (proven). Never hardcode a dead "ObjectFacing is useless"
    -- workaround after the capability has shipped - Caps lifts it automatically.
    -- CAPABILITY BEATS THE SAVED DEFAULT.
    --
    -- This read used to be `_turn_method or c.turn_method`, and c.turn_method
    -- defaults to "keyboard" - so the capability check below was DEAD CODE and
    -- every client turned by keyboard. On this client keyboard turning does not
    -- rotate the character at all: live, the navigator commanded -1.73 rad every
    -- tick for 50 ticks while `_facing_real` sat unchanged at 1.577 and the goal
    -- distance stayed at 46.8yd. FaceDirection moves it instantly (verified: 1.577
    -- -> -0.612), which is why the bot appeared to "run off in a random direction"
    -- - it was walking whatever way it happened to already face.
    --
    -- Only an EXPLICIT override (_turn_method, set by the ineffective-turn
    -- fallback below) outranks the capability now.
    local method = Navigator._turn_method
    if not method then
        -- ASK THE PRIMITIVE, NOT A PROBE.
        --
        -- This went through Caps.has("live_facing"), which answered differently
        -- across DLL rebuilds and parked the navigator on keyboard turning -
        -- which on this client does not rotate the character AT ALL. If the
        -- runtime exposes an analog turn, use it; keyboard is the fallback for
        -- a runtime that has neither, not a default.
        if a and (a.TurnByDelta or a.Face) then
            method = "turnby"
        else
            method = c.turn_method or "keyboard"
        end
    end

    -- Large error: snap with FaceDirection when available (one shot), then hold
    -- keyboard for fine settle. Avoids multi-second circle-walks while turning.
    if aerr > 1.0 and a and a.Face and (not Navigator._face_snap_t
        or (now() - Navigator._face_snap_t) > 0.8) then
        pcall(a.Face, target)
        Navigator._face_snap_t = now()
        set_turn(nil)
        Navigator._last_heading = cur
        Navigator._last_turn_cmd = errs
        return aerr, errs, errs, "face"
    end
    if method == "turnby" then
        if Navigator._turn then set_turn(nil) end     -- release any held keyboard keys
        local delta = 0
        if aerr > (c.turn_stop or 0.03) then
            local maxStep = (c.turn_rate or 7.0) * dt -- rad this frame (turn_rate = fast)
            delta = errs
            if delta >  maxStep then delta =  maxStep end
            if delta < -maxStep then delta = -maxStep end
            if a and a.TurnByDelta then a.TurnByDelta(delta) end
            -- effectiveness: is the REAL heading actually rotating while we command?
            if cur and Navigator._eff_prev then
                Navigator._eff = (Navigator._eff or 0.05) * 0.85
                    + math.abs(Navigator.angle_diff(Navigator._eff_prev, cur)) * 0.15
            end
            Navigator._eff_cmd = (Navigator._eff_cmd or 0) + 1
            if Navigator.turn_ineffective(Navigator._eff_cmd, Navigator._eff) then
                Navigator.switch_turn_method("turnby ineffective")
            end
        else
            Navigator._eff_cmd = 0
        end
        Navigator._eff_prev = cur
        Navigator._last_heading = cur
        Navigator._last_turn_cmd = delta      -- watched by the steering contract
        return aerr, errs, delta, method
    else
        -- KEYBOARD: fixed-rate hysteresis bang-bang (human-like continuous turn).
        if Navigator._turn ~= nil then
            if aerr <= (c.turn_stop or 0.03) then set_turn(nil)
            else set_turn(errs > 0 and "left" or "right") end
        elseif aerr >= (c.turn_start or 0.10) then
            set_turn(errs > 0 and "left" or "right")
        end
        Navigator._last_heading = cur
        -- THE CONTRACT'S INPUT HAS TO BE WRITTEN BY THE MODE THAT IS RUNNING.
        --
        -- This branch never assigned _last_turn_cmd, so it kept whatever the
        -- "face" or "turnby" branch last left there - permanently non-zero. The
        -- turning_actually_turns contract gates on `_last_turn_cmd ~= 0`, so once
        -- keyboard mode took over (and live it ALWAYS does: every turn line in
        -- the session log reads m=keyboard) the gate was stuck open, and any 20
        -- ticks of steady heading tripped it. Steady heading while following a
        -- straight path segment is CORRECT behaviour, not an open loop.
        --
        -- It stayed hidden while search legs beelined, because a beeline is a
        -- constant heading correction; it surfaced the moment real waypoints
        -- produced long aligned stretches. Write the actual command: 0 when we
        -- are not turning, so the contract watches this mode truthfully.
        Navigator._last_turn_cmd = Navigator._turn and errs or 0
        -- KEYBOARD MUST EARN ITS KEEP TOO.
        --
        -- Only turnby was ever checked for effectiveness, and its fallback went
        -- ONE WAY into this branch - so on a client where keyboard turning does
        -- nothing (this one: 50 ticks of commanded turn with the real heading
        -- frozen) the navigator switched into a dead method and could never get
        -- out. It sat at 10 yards from a quest giver with a 0.97rad error,
        -- commanding a turn forever.
        if Navigator._turn ~= nil then
            if cur and Navigator._eff_prev then
                Navigator._eff = (Navigator._eff or 0.05) * 0.85
                    + math.abs(Navigator.angle_diff(Navigator._eff_prev, cur)) * 0.15
            end
            Navigator._eff_cmd = (Navigator._eff_cmd or 0) + 1
            if Navigator.turn_ineffective(Navigator._eff_cmd, Navigator._eff) then
                Navigator.switch_turn_method("keyboard ineffective")
            end
        else
            Navigator._eff_cmd = 0
        end
        Navigator._eff_prev = cur
        return aerr, errs, (Navigator._turn and 1 or 0), method
    end
end

-- Collect nearby OM objects as circular obstacles (units + game objects), minus
-- the current move target so we don't repel away from where we want to go.
local function gather_obstacles(px, py, skip_guid)
    -- Prefer the Obstacles layer: it carries each entity's REAL collision size
    -- (combat reach / bounding radius plus our own half-width) instead of one
    -- guessed radius for everything, it includes other players, and it is a
    -- throttled snapshot rather than a fresh OM walk every single frame.
    local OB = RaijinLab and RaijinLab.Obstacles
    if OB and OB.refresh then
        OB.refresh()
        local out = {}
        local list = OB._list or {}
        for i = 1, #list do
            local o = list[i]
            if o.guid ~= skip_guid then
                local dx, dy = o.x - px, o.y - py
                if dx * dx + dy * dy < 400 then       -- 20yd: see them sooner
                    out[#out + 1] = { x = o.x, y = o.y, r = o.r }
                end
            end
        end
        return out
    end

    local om = RaijinLab and RaijinLab.om and RaijinLab.om.object_list
    if not om then return {} end
    local out = {}
    local function add(list)
        for i = 1, #(list or {}) do
            local s = list[i]
            if s and s.Guid ~= skip_guid and not (s.Info and s.Info.Unit and s.Info.Unit.Dead) then
                local x, y = RaijinLab:ObjectPosition(s.Guid)
                if x then
                    local dx, dy = x - px, y - py
                    if dx * dx + dy * dy < 100 then   -- within 10yd
                        out[#out + 1] = { x = x, y = y, r = 2.0 }
                    end
                end
            end
        end
    end
    add(om.npcs); add(om.gameobjects)
    return out
end

local function reset_progress(a)
    local px, py = player_pos()
    a.anchor = px and { x = px, y = py } or nil
    a.progress_t = now()
    a.stuck_n = 0
end

-- Gentle recovery: STOP pushing the blocker, jump once, and steer AROUND it by
-- adding an escalating, side-alternating detour angle to the goal heading. NO
-- repeated wall-thrashing or strafing (that is what clipped the player through
-- terrain). Returns false when we've given up (caller should stop).
local function recover(a)
    local t = now()
    a.recover_n = (a.recover_n or 0) + 1
    -- LEARN once.
    if a.recover_n == 1 then
        local WM = RaijinLab and RaijinLab.WorldMesh
        if WM and WM.mark_stuck then
            local sx, sy, sz = player_pos()
            WM.mark_stuck(sx, sy, sz)
            dlog("nav", "STUCK at (%.1f,%.1f,%.1f) -> recover n=1", sx or 0, sy or 0, sz or 0)
        end
    end
    if a.recover_n > cfg().max_recover then
        local F = RaijinLab and RaijinLab.Fail
        if F and F.record then
            local g = a.goal or {}
            local key = string.format("nav:stuck:%.0f:%.0f", g.x or 0, g.y or 0)
            F.record(key, F.TRANSIENT or "transient", {
                why = "max_recover", backoff = 15,
            })
        end
        return false
    end
    -- NO JUMP ON FIRST RECOVERIES unless a lip probe set want_jump. Live logs:
    -- fwd=false (false wall block) -> stuck -> Jump spam with no progress.
    -- Prefer: clear false block, force forward + detour. Jump only if lip or n>=3.
    --
    -- A VOID IS NOT A FALSE BLOCK. Stuck recovery exists for phantom walls, and
    -- clearing the flag then forcing forward is the right answer to those. At a
    -- ledge the flag is correct and the recovery would run off it - with a jump
    -- on the third attempt. Keep the detour and the turn; refuse the clearance.
    if not a.block_void then a.block = false end
    local mag = math.min(cfg().detour_step * a.recover_n, math.rad(120))
    a.detour = (a.recover_n % 2 == 1) and mag or -mag
    a.progress_t = t
    local a_ = A()
    local may_jump = a.want_jump or (a.recover_n >= 3)
    a.want_jump = false
    -- STUCK RECOVERY IS FOR SNAGS, AND A LEDGE IS NOT A SNAG.
    --
    -- Both branches below assume the thing stopping us is something to push
    -- through: jump over it, or drive at it harder. At a rim there is nothing to
    -- push through, and both are a way over the edge - the jump literally clears
    -- the gap the sensor refused, and set_forward(true) here bypasses every block
    -- check in the steering path by writing the key directly. Measured: the stop
    -- held the character at the rim for 23 seconds, then recovery drove it off.
    --
    -- Being stopped at a ledge is the sensor SUCCEEDING. Keep the turn (the
    -- detour above is already set) and let steering find a heading with ground
    -- on it; never add thrust along a heading that has none.
    if a.block_void then
        set_forward(false)
        dlog("nav", "recover: ledge ahead, turning only (n=%d detour=%.2f)",
             a.recover_n, a.detour or 0)
        return true
    end
    if may_jump and a_ and a_.Jump and t - (a.jump_t or 0) >= cfg().jump_gap then
        a_.Jump()
        a.jump_t = t
        dlog("nav", "recover jump n=%d", a.recover_n)
    else
        -- Drive out of the snag instead of airtime thrash.
        set_forward(true)
        dlog("nav", "recover drive n=%d detour=%.2f (no jump)", a.recover_n, a.detour or 0)
    end
    return true
end

-- Public: set a destination (optionally with waypoints). Starts the ticker.
function Navigator.move_to(goal, opts)
    if not goal or not goal.x then return false end
    opts = opts or {}
    -- Default: force forward while turning (keyboard locomotion must not wait
    -- for perfect alignment - that produced live freezes with fwd=false).
    if opts.force_forward == nil then opts.force_forward = true end
    -- Honor Fail backoff for a goal we just gave up on as stuck.
    local F = RaijinLab and RaijinLab.Fail
    if F and F.may_retry then
        local key = string.format("nav:stuck:%.0f:%.0f", goal.x or 0, goal.y or 0)
        local ok = F.may_retry(key)
        if not ok then
            dlog("nav", "move_to blocked by Fail backoff at (%.0f,%.0f)", goal.x, goal.y)
            return false, "fail_backoff"
        end
    end
    local px, py, pz = player_pos()
    -- THE WAY ROUND AN OBSTACLE OUTLIVES THE PLAN THAT MET IT.
    --
    -- The wall commitment used to live only on _active, and every re-plan builds
    -- a fresh _active - so each re-arm forgot which way it had chosen and picked
    -- again from whichever shoulder happened to hit. Observed: the character
    -- worked 70 yards north along a wall, re-planned, chose south, and gave the
    -- distance straight back. The obstacle did not change; only our memory of it
    -- did.
    --
    -- Carried across while the commitment is still warm, so a route around a
    -- building survives the several re-plans it inevitably takes.
    local _ws, _wb, _wht = Navigator._wall_side, Navigator._wall_bend, Navigator._wall_hold_t
    local _warm = _wht and (now() - _wht) < ((cfg().wall_commit or 12.0) * 2)
    Navigator._active = {
        goal = goal, path = opts and opts.waypoints, idx = 1, opts = opts or {},
        jump_t = 0, detour = 0, recover_n = 0,
        start_t = now(), start_z = pz, prev_z = pz,
        wall_side = _warm and _ws or nil,
        wall_bend = _warm and _wb or nil,
        wall_hold_t = _warm and _wht or nil,
    }
    reset_progress(Navigator._active)
    Navigator.state = "moving"
    local Ou = RaijinLab and RaijinLab.Outcomes
    if Ou and Ou.begin then
        if Navigator._outcome then
            if Ou.settle_progress then
                Ou.settle_progress(Navigator._outcome, "superseded")
            else
                Ou.settle(Navigator._outcome, 0.0, "superseded")
            end
        end
        Navigator._outcome = Ou.begin("nav", {
            x = goal.x, y = goal.y, z = goal.z,
            waypoints = opts and opts.waypoints and #opts.waypoints or 0,
        })
    end
    Navigator._start_ticker()
    -- keep the environment mapped ahead so we route around walls, not into them
    local Sv = RaijinLab and RaijinLab.Surveyor
    if Sv and Sv.start then Sv.start() end
    dlog("nav", "move_to goal=(%.1f,%.1f,%.1f) waypoints=%d arrive=%.1f",
        goal.x, goal.y, goal.z or 0, opts and opts.waypoints and #opts.waypoints or 0,
        (opts and opts.arrive_dist) or DEFAULTS.arrive_dist)
    return true
end

-- RELEASE WITHOUT TRUSTING OUR OWN BOOKKEEPING.
--
-- set_forward/set_strafe are edge-triggered: `if Navigator._moving == on then
-- return end`. That is right for the steady state and WRONG for a stop, because
-- the one situation a stop must handle is the tracked flag disagreeing with the
-- key that is actually held. When they diverge the release is skipped and the
-- character runs in a straight line forever with nothing steering it.
--
-- Observed exactly: dead, _active nil, _facing_real nil, Navigator not steering
-- at all - and the ghost travelling 607yd due east away from a corpse 40yd west.
-- This project has already shipped one kill switch that released nothing; a stop
-- must command the release regardless of what we believe.
local function force_release()
    Navigator._moving = nil          -- forget the belief, so the edge always fires
    Navigator._strafe = nil
    set_forward(false)
    set_strafe(nil)
    -- STAGE A NATIVE HALT; NEVER CALL THE MOVEMENT APIS DIRECTLY (2026-08-03).
    --
    -- The four calls that used to be here - MoveForward(false),
    -- MoveBackward(false), StrafeLeft/Right(false) - are the PROTECTED movement
    -- APIs. Master.halt_movement documents exactly this and was fixed to stage
    -- a native halt instead; force_release kept calling them, and Navigator.stop
    -- runs BEFORE halt_movement, so suite-OFF popped "RaijinLab has been blocked
    -- from an action only available to the Blizzard UI" every single time -
    -- which is precisely when the user sees it.
    --
    -- HaltMovement is drained by the runtime's frame hook (main thread, no Lua
    -- on the stack), which releases every held key, stops, and commits. That is
    -- the native-carrier rule, and it is strictly more thorough than the four
    -- calls it replaces.
    local a = A()
    if a and a.HaltMovement then
        pcall(a.HaltMovement)
    end
end
Navigator.force_release = force_release

function Navigator.stop()
    -- stop() must release like abort(): same edge-trigger trap, same consequence
    -- of a key held with nothing steering.
    force_release(); turn_stop()
    -- Pitch releases UNCONDITIONALLY on stop - before, and regardless of, the
    -- breath latch below. The latch legitimately keeps the ascend hold, but a
    -- kept pitch hold has no such excuse (survival never drives forward, so
    -- pitch adds nothing) and on land it corrupts the next movement.
    release_pitch()
    -- Breath emergency outlives the path. Stopping a move mid-lake with empty
    -- lungs must NOT release ascend - that is how "arrived" drowned the bot.
    if Navigator._active and Navigator._active.breath_surface then
        Navigator._breath_surface = true
    end
    local Ou = RaijinLab and RaijinLab.Outcomes
    if Ou and Navigator._outcome then
        Ou.settle(Navigator._outcome, 0.0, "stopped")
        Navigator._outcome = nil
    end
    Navigator._active = nil
    Navigator.state = "idle"
    if not Navigator._breath_surface then
        release_vertical()
        local a = A(); if a and a.StopMoving then a.StopMoving() end
        Navigator._stop_ticker()
    end
end

function Navigator.arrived() return Navigator.state == "arrived" end
function Navigator.status() return Navigator.state end

-- Predictive terrain sensing via real TraceLine raycasts (throttled). Looks
-- along the intended `heading` and sets, on the active move:
--   a.block     = true  -> a cliff/gap with no safe floor ahead: DON'T run forward
--   a.want_jump = true  -> a low wall/step just ahead: hop it
--   a.detour           -> a side angle that has a floor, to steer around a ledge
-- Degrades to a no-op when TraceLine is unavailable (old runtime / tests).
-- PURE: has the variable-rate turn primitive proved it does not rotate us?
--
-- `eff` is an EMA of how much the REAL facing moved per commanded turn. If we
-- have commanded a good number of turns and the character has barely rotated,
-- the primitive is not working and we must fall back to the keyboard turn -
-- otherwise we command turns forever and never face anything.
--
-- This is not hypothetical: live, TurnByDelta never called CommitMovement, so
-- the rotation was set in-process and never pushed. This check is what noticed
-- ("TurnByDelta ineffective (real facing not moving) -> keyboard turn") and kept
-- the bot steering at all. Requires a MINIMUM SAMPLE so a couple of tiny
-- corrections near the target heading cannot condemn a working primitive.
-- A FALLBACK THAT ONLY GOES ONE WAY IS A TRAP.
--
-- Whichever turn method is running, if it proves it cannot rotate the character
-- we move to the OTHER one and give it a clean slate. Both dead is possible in
-- principle, so we never mark both permanently - we alternate, which means the
-- worst case is oscillation between two methods rather than a permanent freeze
-- with the character commanding a turn it can never execute.
Navigator._ineff_method = {}

-- VERIFY BEFORE CONDEMNING.
--
-- `_eff` is measured against `_facing_real`, which is a FUSION - live read, else
-- travel direction, else dead reckoning. When the frozen-read guard demotes the
-- live source that estimate stops reflecting the character, `_eff` reads ~0, and
-- a turn method that WORKS gets blacklisted forever.
--
-- Measured live, and this is the whole bug: `TurnByDelta(0.7)` moved the real
-- facing from -0.489 to 0.211 - exactly the 0.7 commanded - while the navigator
-- had `blacklisted=[turnby]`, was using `keyboard` (which rotates nothing on
-- this client), and was reporting `cannot_steer: heading will not respond`.
--
-- So ask the SENSOR, not the estimate, before throwing a method away. One direct
-- reading cannot be fooled by whatever the fusion is currently believing.
function Navigator.switch_turn_method(why)

    local from = Navigator._turn_method or Navigator._method or "turnby"
    local to = (from == "turnby") and "keyboard" or "turnby"
    -- NEVER SETTLE ON A METHOD ALREADY PROVEN DEAD.
    --
    -- Plain alternation oscillates, and on this client one of the two does not
    -- work at all: keyboard turning left the real heading frozen for 50 ticks
    -- while commanding -1.73rad. Half the flips therefore parked the navigator
    -- in a method that cannot rotate, and it sat 14 yards from a quest giver
    -- with a 0.67rad error going nowhere.
    --
    -- Remember which ones failed. If the alternative has already failed too,
    -- forget both verdicts and fall back to the CAPABILITY-preferred method -
    -- the one the runtime actually advertises - rather than trusting a stale
    -- measurement that may have been taken while something else was wrong.
    Navigator._ineff_method[from] = true
    if Navigator._ineff_method[to] then
        Navigator._ineff_method = {}
        local Caps = RaijinLab and RaijinLab.Caps
        to = (Caps and Caps.has and Caps.has("live_facing")) and "turnby" or "keyboard"
    end
    Navigator._turn_method = to
    -- fresh evidence for the new method; the old verdict must not condemn it
    Navigator._eff, Navigator._eff_cmd, Navigator._eff_prev = nil, 0, nil
    if Navigator._turn then set_turn(nil) end
    dlog("nav", "turn method %s -> %s (%s)", from, to, tostring(why or "?"))
    return to
end

function Navigator.turn_ineffective(cmd_n, eff)
    if type(cmd_n) ~= "number" or cmd_n < 18 then return false end
    -- an unmeasured effectiveness is not evidence of failure
    if eff == nil then return false end
    return eff < 0.008
end

-- PURE: the next wall-following bend, given the current one.
--
-- Extracted so it is testable headless. The mutation harness proved this fix was
-- UNDEFENDED: replacing the escalation with a constant 0.9 rad passed the entire
-- suite. That constant is precisely the bug the escalation exists to fix - at
-- 0.9 rad, cos(0.9)=0.62, so 62% of forward speed still points INTO the surface
-- and the character leans on a long wall forever instead of travelling along it.
--
-- Monotonic while contact persists, capped just past perpendicular so a corner
-- clears without ever reversing back toward the goal.
-- PURE: may a clear ray to this goal be taken as proof of an open route?
--
-- A CLEAR TRACE IS ONLY EVIDENCE WITHIN LOADED COLLISION. The client streams
-- terrain and WMO collision around the player, so a ray cast at something far
-- away spends most of its length in space with nothing loaded to hit and comes
-- back "clear". Taking that as an open route is how the bot walked straight into
-- walls with dist=2203 in the live log while never planning a path.
--
-- Extracted as a predicate because the mutation harness proved the range guard
-- was UNDEFENDED: deleting `goal_dist <= LOS_TRUST_RANGE` passed the whole suite.
-- A CLEAR RAY TO A POINT ON ANOTHER FLOOR IS NOT A WALKABLE ROUTE.
--
-- `dz` is the difference in ELEVATION to the goal. Live, the bot was sent to a
-- quest giver standing 16.5 yards above it on the upper floor of a building:
-- horizontally it was close, the ground ahead was flat and the forward ray was
-- clear, so every 2D check said "go" and it walked into the wall underneath the
-- target. Nothing in the sensing could object, because nothing was asking about
-- height.
--
-- Walking cannot change your floor. Beyond a step's worth of rise the direct
-- approach is meaningless and the route has to be planned (stairs, a ramp), so
-- the shortcut is refused and the planner has to earn it.
Navigator.LEVEL_DZ = 3.0        -- yd: more than a step up is a different level

function Navigator.los_shortcut_ok(goal_dist, opts, trust_range, dz)
    opts = opts or {}
    if opts._no_los_shortcut then return false end
    if opts._from_replan then return false end
    if type(goal_dist) ~= "number" then return false end
    if type(dz) == "number" and math.abs(dz) > (Navigator.LEVEL_DZ or 3.0) then
        return false
    end
    trust_range = trust_range or Navigator.LOS_TRUST_RANGE or 12
    return goal_dist <= (Navigator.LOS_SHORTCUT_MAX or 12)
        and goal_dist <= trust_range
end

function Navigator.next_wall_bend(cur, step, cap, bend0)
    step = step or 0.25
    cap = cap or 1.9
    bend0 = bend0 or 0.9
    return math.min((cur or bend0) + step, cap)
end

-- PURE: what the MESH says about walking on from here, given a heading.
--
-- Extracted so it is testable without a client. Returns:
--   blocked  - the way ahead is definitely not walkable ON THIS FLOOR
--   side     - +0.9 go left, -0.9 go right, nil when the mesh cannot tell
--
-- Only a definite NO counts. Unknown, no tile, an unexported zone - all fall
-- through as "not blocked", because the mesh must never veto by silence; the
-- ray probes remain the fallback exactly as before.
function Navigator.mesh_ahead(NG, Know, px, py, pz, heading, ahead, swing)
    if not (NG and NG.walkable_z and Know and Know.is_no) then return false, nil end
    if type(px) ~= "number" or type(heading) ~= "number" then return false, nil end
    ahead = ahead or 3.0
    swing = swing or 1.05
    local function solid(x, y)
        local ok, k = pcall(NG.walkable_z, x, y, pz)
        return (ok and Know.is_no(k)) and true or false
    end
    local function clear(ang)
        local d = 1.0
        while d <= ahead do
            if solid(px + math.cos(ang) * d, py + math.sin(ang) * d) then return false end
            d = d + 1.0
        end
        return true
    end
    if clear(heading) then return false, nil end
    local lc, rc = clear(heading + swing), clear(heading - swing)
    if lc == rc then return true, nil end          -- mesh cannot distinguish
    return true, (lc and 0.9 or -0.9)
end

local function terrain_probe(a, px, py, pz, heading)
    if not (RaijinLab and RaijinLab.TraceLine and RaijinLab.TraceGround) then return end
    local c = cfg()
    local t = now()
    local period = 1 / (c.probe_hz or 10)
    if a.probe_t and (t - a.probe_t) < period then return end
    a.probe_t = t
    a.block = false
    -- TWO OPPOSITE HAZARDS USED TO SHARE ONE BOOLEAN.
    --
    -- a.block meant both "solid thing in front of you" and "NO FLOOR in front of
    -- you". Those want opposite responses: you may hold forward and slide along a
    -- wall, and you must never hold forward at a ledge. Sharing the flag means
    -- any rule written for one silently rewrites the other - which is exactly how
    -- the wall-following fix (forward stays on while a side is committed) also
    -- switched off the cliff stop, and the character started running off edges.
    --
    -- block_void is the negative-obstacle half. Nothing may override it.
    a.block_void = false
    -- a fresh probe owns the verdict: last tick's wall is not evidence
    a.sensor_detour = false
    -- ...but the SIDE we committed to is not a per-probe verdict. Release it
    -- only after the way has stayed clear for a moment, otherwise the first
    -- clear probe mid-detour drops the commitment and the oscillation returns.
    -- RELAX BEFORE RELEASING. A clear probe means the bend is working, not that
    -- it is unnecessary: dropping straight back to the goal heading swings the
    -- body into the surface we were just clearing. Ease the bend down first, and
    -- only drop the side commitment once we are actually straightened out.
    if a.wall_hold_t and (now() - a.wall_hold_t) > (c.wall_relax or 0.4) then
        local b = (a.wall_bend or 0) - (c.wall_bend_step or 0.25)
        if b <= (c.wall_bend0 or 0.9) * 0.5 then b = 0 end
        a.wall_bend = b
        if b > 0 and (a.wall_side or 0) ~= 0 then
            a.detour = a.wall_side >= 0 and b or -b
            a.sensor_detour = true                 -- still perception's, not stale
        end
    end
    if a.wall_hold_t and (now() - a.wall_hold_t) > (c.wall_commit or 1.5)
        and (a.wall_bend or 0) <= 0 then
        a.wall_side = 0
        a.wall_bend = 0
        a.wall_hold_t = nil
    end

    -- WALL-FOLLOWING THAT GOES NOWHERE IS NOT WALL-FOLLOWING.
    --
    -- The release above is time-based and only fires once the bend has already
    -- eased to zero, so a commitment that is being continually refreshed never
    -- expires. Measured live: `wall_follow` latched on for all 242 frames of an
    -- 8-second window while the character moved ZERO yards - it was steering
    -- along a surface it was not travelling past, forever.
    --
    -- Following a wall means MOVING along it. If we have not covered any ground
    -- since the commitment began, the side we picked is not working; drop it and
    -- let the next probe choose afresh, from the mesh this time.
    if (a.wall_side or 0) ~= 0 then
        if not a.wf_from then
            a.wf_from = { x = px, y = py, t = t }
        elseif (t - a.wf_from.t) > (c.wall_progress_secs or 3.0) then
            -- The threshold has to clear genuine slow going, not just a freeze:
            -- skirting a long wall measures ~0.9yd/s in the scenario suite, so
            -- demanding 1.5yd/2s condemned real progress and the bot stopped
            -- routing around an 800yd wall. Only a near-total stall counts.
            local moved = math.sqrt((px - a.wf_from.x) ^ 2 + (py - a.wf_from.y) ^ 2)
            if moved < (c.wall_progress_min or 0.75) then
                a.wall_side, a.wall_bend, a.wall_hold_t = 0, 0, nil
                a.detour, a.sensor_detour = 0, false
                Navigator._wall_follow = false
                dlog("nav", "wall-follow released: %.1fyd in %.1fs is not progress",
                     moved, t - a.wf_from.t)
            end
            a.wf_from = { x = px, y = py, t = t }
        end
    else
        a.wf_from = nil
    end

    -- ---- THE MESH IS ASKED FIRST -------------------------------------------
    --
    -- Everything below this block senses the world by firing TraceLine rays each
    -- frame. That was the only source available before the premapped mesh could
    -- be read at all, and it is why fixing the map changed nothing the character
    -- did: the steering loop never consulted it. Measured live, "the cell 3yd
    -- ahead is solid" fired on 0 of 242 frames while the bot ground into a
    -- building - the mesh was silent because nothing asked it.
    --
    -- The mesh is strictly better evidence than a ray where it has data: it is
    -- 0.5yd, it knows which FLOOR the character is on, and it already excludes
    -- the band a body cannot fit through. So it answers first, and a definite NO
    -- is acted on immediately. Anything else (unknown, no tile, an unexported
    -- zone) falls through to the rays exactly as before - the mesh may not veto
    -- by silence.
    -- ---- THE MESH IS ASKED FIRST -------------------------------------------
    --
    -- Everything below senses the world by firing TraceLine rays each frame.
    -- That was the only source before the premapped mesh could be read at all,
    -- and it is why fixing the map changed nothing the character DID: the
    -- steering loop never consulted it. Measured live, "the cell 3yd ahead is
    -- solid" fired on 0 of 242 frames while the bot ground into a building.
    --
    -- Where the mesh has data it is strictly better evidence than a ray: 0.5yd,
    -- floor-aware, and already excluding the band a body cannot fit through.
    local mblock, mside = Navigator.mesh_ahead(
        RaijinLab and RaijinLab.NavGrid, RaijinLab and RaijinLab.Know,
        px, py, pz, heading, c.mesh_look or 3.0, c.mesh_swing or 1.05)
    a.mesh_block = mblock
    if mblock then
        a.block = true
        if mside and (a.wall_side or 0) == 0 then
            a.wall_side = mside
            a.wall_bend = c.wall_bend0 or 0.9
            a.wall_block_h = heading
        end
        if mside then a.wall_hold_t = now() end
    end

    local look = c.cliff_look or 2.5
    local span = (c.max_step_down or 6) + 2
    local swimming = IsSwimming and IsSwimming()
    local function sample_ahead(h)
        local ax = px + math.cos(h) * look
        local ay = py + math.sin(h) * look
        -- learned snag spots read as no-floor: steer around them proactively
        local WM = RaijinLab.WorldMesh
        if WM and WM.is_blacklisted and WM.is_blacklisted(ax, ay, pz) then
            return nil, false
        end
        local GC = RaijinLab.GroundCache
        local hit
        -- through the shared cache (terrain is static; keeps probes near-free).
        -- MUST pass `span` - GroundCache defaults match walkable step, and a
        -- longer hardcoded span once green-lit deep water the step gate rejects.
        if GC and GC.ground then
            hit = GC.ground(ax, ay, pz, nil, 3.0, span)
        else
            hit = RaijinLab:TraceGround(ax, ay, pz, 3.0, span)
        end
        -- Geographic water only. While swimming with no solid and no map, treat
        -- the look-ahead as open water so route_z does not call it a dry cliff.
        local mapped = GC and GC.is_water and GC.is_water(ax, ay)
        local water = (mapped == true)
            or (swimming and hit == nil and mapped ~= false)
        local rz, kind
        if GC and GC.route_z then
            rz, kind = GC.route_z(pz, hit, water)
        else
            rz, kind = hit, (hit and "walk" or "void")
        end
        -- floor_ahead means walk/wade surface, not "any route_z including swim".
        local floor = (kind == "walk" or kind == "wade") and rz or nil
        return floor, water, kind, rz
    end

    local floor_h, water_h, kind_h, route_h = sample_ahead(heading)
    a.water_ahead = water_h and true or false
    a.floor_ahead = floor_h ~= nil
    a.ahead_kind = kind_h
    -- Goal dry: map says not water. Unknown map does not invent a dry goal.
    local g = a.goal
    local goal_dry = false
    if g and g.x then
        local GC = RaijinLab.GroundCache
        if GC and GC.is_water then
            local gw = GC.is_water(g.x, g.y)
            goal_dry = (gw == false)
        end
    end
    a.shore = Navigator.shore_intent(swimming, a.floor_ahead, a.water_ahead, goal_dry)

    -- Cliff / gap: dry land with no ROUTE surface ahead. Water enter is NOT a
    -- cliff. Already swimming: never cliff-block. route_h is the classified
    -- height (walk/wade/swim band); floor_h is walk/wade only.
    if not swimming and route_h == nil and a.shore ~= "enter" then
        local found = nil
        for _, off in ipairs({ 0.5, -0.5, 0.9, -0.9, 1.4, -1.4 }) do
            local _f, _w, _k, rz = sample_ahead(Navigator.norm(heading + off))
            if rz ~= nil then found = off; break end
        end
        -- NO FLOOR ON THIS HEADING MEANS DO NOT WALK ON THIS HEADING.
        --
        -- This used to treat "some other angle has floor" as permission to keep
        -- running, and only blocked when every lateral sample was empty too. At a
        -- straight cliff edge that condition is nearly unreachable: the offsets
        -- are +/-0.5, 0.9 and 1.4 rad over a 2.5yd look, so they land a fraction
        -- SHORT of the rim and dutifully report floor. So `found` was set, the
        -- detour branch was taken, forward stayed on - and the character nudged
        -- over the edge at a slight angle. Traced: 250 yards across a 40-yard
        -- drop with block=false on every single frame. The cliff detector was
        -- defeated by its own escape check.
        --
        -- A lateral sample is a direction to TURN TOWARDS, never a reason to
        -- keep walking on a heading with nothing under it. Block forward, steer,
        -- and let the next probe clear the block once the new heading has ground
        -- on it - which is what happens the moment the turn takes.
        a.block = true
        a.block_void = true
        if found and not a.mesh_block then
            a.detour = found
        end
        local DL = RaijinLab and RaijinLab.DevLog
        if DL then DL.log_every("nav_terrain", 0.5, "nav", "terrain CLIFF ahead heading=%.2f -> %s",
            heading, found and ("detour " .. string.format("%.2f", found)) or "BLOCK forward") end
    end

    -- Wall / step sensing at TWO heights. A chest-height hit is a real wall:
    -- jumping into it just grinds - detour around it. A foot-height hit with a
    -- CLEAR chest is the tiny rock / root / lip that snags a character: hop it
    -- and keep running. This distinction is what turns "pebble = stuck" into
    -- "pebble = one jump, never noticed".
    local reach = c.wall_probe or 2.2
    local ex = px + math.cos(heading) * reach
    local ey = py + math.sin(heading) * reach
    local zc = pz + (c.wall_height or 1.4)
    local zf = pz + (c.foot_height or 0.4)
    -- A CHARACTER IS NOT A LINE. This cast one ray straight ahead, so anything
    -- narrower than the body and offset from dead centre - a tree trunk, a post,
    -- a lamp - was missed at chest height while the collision capsule still hit
    -- it. The foot ray then caught the roots, the lip rule said "hoppable", and
    -- the bot stood there trying to JUMP OVER A TREE. Reported verbatim.
    --
    -- Sweep the body's width instead: centre plus both shoulders, offset
    -- perpendicular to the heading. Three rays is the cheapest shape that cannot
    -- thread a trunk between them, and the probe is already throttled to
    -- probe_hz so the extra casts cost nothing measurable.
    local half = c.body_radius or 0.45
    local nx, ny = -math.sin(heading), math.cos(heading)   -- perpendicular
    -- Centre ray first: on a flat wall (the common case) one TraceLine is enough.
    -- Shoulder ray only if centre is clear - still catches trunks/posts, half
    -- the ray budget when pressed against buildings. Alternating shoulder side
    -- keeps full coverage over two probe ticks at 8Hz.
    a.sweep_side = -(a.sweep_side or 1)
    local chest_hit, hx, hy, chest_off
    do
        local hit, ihx, ihy = RaijinLab:TraceLine(px, py, zc, ex, ey, zc, 0x100111)
        if hit and ihx then
            local ddx, ddy = ihx - px, ihy - py
            if math.sqrt(ddx * ddx + ddy * ddy) < reach then
                chest_hit, hx, hy, chest_off = hit, ihx, ihy, 0
            end
        end
        if not chest_hit then
            local o = half * a.sweep_side
            local sx, sy = px + nx * o, py + ny * o
            local tx, ty = ex + nx * o, ey + ny * o
            hit, ihx, ihy = RaijinLab:TraceLine(sx, sy, zc, tx, ty, zc, 0x100111)
            if hit and ihx then
                local ddx, ddy = ihx - sx, ihy - sy
                if math.sqrt(ddx * ddx + ddy * ddy) < reach then
                    chest_hit, hx, hy, chest_off = hit, ihx, ihy, o
                end
            end
        end
    end
    if chest_hit and hx then
        do
            -- real wall: never jump into it; steer around
            --
            -- TWO FIXES HERE.
            --
            -- (a) The side was chosen from recover_n parity, which is 0 during
            -- normal running - so it ALWAYS bent the same way (+0.7) regardless
            -- of where the wall actually was, and the 3-ray sweep's knowledge of
            -- WHICH shoulder hit was thrown away. Half the time that steers
            -- straight into the wall it just detected. Now: hit on the left
            -- shoulder means go right, and vice versa.
            --
            -- (b) A wall closer than about half the probe reach used to leave
            -- a.block false, so set_forward kept commanding FULL SPEED FORWARD
            -- into geometry the sensor had positively identified. Bending 0.7rad
            -- while running at a wall 1yd away just grinds along it. Close wall
            -- now blocks forward so the turn happens in place.
            -- COMMIT TO A SIDE. Choosing purely from which shoulder hit made
            -- the bot oscillate: the left ray hits so we turn right, which swings
            -- the RIGHT shoulder into the wall, so we turn left, forever. The
            -- live log shows it as consecutive `detour 0.90` / `detour -0.90`.
            --
            -- A wall is a surface, not a point. The way past it is to pick one
            -- direction and HOLD it until the way is actually clear - the same
            -- hysteresis the strafe controller already uses. Re-deciding every
            -- probe is what produces the random-looking dance.
            local side = chest_off or 0
            local want
            if side > 0 then want = -0.9          -- hit on the left -> go right
            elseif side < 0 then want = 0.9       -- hit on the right -> go left
            else
                -- centre hit carries no side information. Keep whatever we were
                -- already committed to; only invent a direction if we have none.
                want = (a.wall_side ~= 0 and a.wall_side)
                    or ((a.recover_n % 2 == 0) and 0.9 or -0.9)
            end
            if (a.wall_side or 0) == 0 then
                a.wall_side = want                 -- first contact: choose
                a.wall_bend = c.wall_bend0 or 0.9  -- and start at the gentle bend
                -- REMEMBER THE DIRECTION THAT WAS BLOCKED. The surface is
                -- roughly perpendicular to it, so this is what lets us steer
                -- ALONG the wall instead of bending an arbitrary amount off a
                -- goal heading that may itself point straight into it.
                a.wall_block_h = heading
            end
            a.wall_hold_t = now()                  -- keep the commitment alive
            -- mirror onto the Navigator so it survives the next _active rebuild
            Navigator._wall_side = a.wall_side
            Navigator._wall_hold_t = a.wall_hold_t

            -- ESCALATE WHILE THE WALL IS STILL THERE.
            --
            -- A constant 0.9 rad keeps 62% of forward speed pointed INTO the
            -- surface, so against a long wall the character leans on the face
            -- forever - exactly the live "runs into the building and stays
            -- there", and 72% stationary at x=296.5 in the simulator.
            --
            -- Each probe that still sees the wall bends further, toward
            -- perpendicular: at pi/2 the motion is purely along the surface,
            -- which is what actually gets round it. Capped just past
            -- perpendicular so we can clear a corner without ever reversing into
            -- the goal.
            local step = c.wall_bend_step or 0.25
            local capb = c.wall_bend_max or 1.9        -- ~109 deg
            a.wall_bend = Navigator.next_wall_bend(a.wall_bend, step, capb, c.wall_bend0)
            Navigator._wall_bend = a.wall_bend
            a.detour = a.wall_side >= 0 and a.wall_bend or -a.wall_bend
            a.sensor_detour = true    -- owned by perception until the way is clear
            local dx0, dy0 = hx - px, (hy or py) - py
            local hitd = math.sqrt(dx0 * dx0 + dy0 * dy0)
            -- HARD BLOCK on any in-range chest hit. Live Deathknell: wall at
            -- d=1.8 with block=false + force_forward drove straight into the
            -- same building every run. Mid-range "detour while walking" only
            -- works for open soft clutter; a solid chest ray IS a wall.
            a.block = true
            a.wall_hit_t = now()
            a.wall_hit_d = hitd
            -- Close wall: back off once so the turn can open, then replan the
            -- route. Live: pressing into a church face with only a heading bend
            -- never cleared the ray; character froze against the wall.
            if hitd < 2.5 and (not a.wall_backoff_t or (now() - a.wall_backoff_t) > 2.0) then
                a.wall_backoff_t = now()
                a.want_backoff = true
                if Navigator._pf_final_goal and (not a.wall_replan_t or (now() - a.wall_replan_t) > 3.0) then
                    a.wall_replan_t = now()
                    a.want_replan = true
                end
            end
            local DL = RaijinLab and RaijinLab.DevLog
            if DL then DL.log_every("nav_wall", 0.5, "nav",
                "terrain WALL(chest) d=%.1f detour=%.2f block=%s",
                hitd, a.detour or 0, tostring(a.block)) end
            return
        end
    end
    -- JUMPING IS A REMEDY FOR BEING SNAGGED, NOT A GREETING FOR TERRAIN.
    --
    -- Walking uphill, the ground 2.2yd ahead is HIGHER than your feet, so the
    -- horizontal foot ray hits the slope itself; the chest ray clears, the lip
    -- rule said "hoppable", and the character jumped continuously while climbing
    -- - thrown off course by its own airtime, for terrain it walks up anyway.
    -- The client climbs every walkable slope without help; a hop only ever earns
    -- its cost when the character is physically STUCK on something.
    --
    -- So the foot sweep runs only when forward progress has actually stalled
    -- (no 0.8yd progress step for jump_stall secs). While we are advancing there
    -- is nothing to fix - and no foot rays to pay for, which is most of the
    -- probe's former per-tick burst. A committed wall detour also skips it:
    -- a foot hit there is the wall's base, and airtime cannot be steered.
    local stalled = (now() - (a.progress_t or now())) > (c.jump_stall or 0.35)
    local foot_hit, fx2, fy2
    if not stalled or (a.wall_side or 0) ~= 0 then
        -- advancing, or rounding a wall: no hop, no rays
    else
    for _, o in ipairs({ 0, half * a.sweep_side }) do
        local sx, sy = px + nx * o, py + ny * o
        local tx, ty = ex + nx * o, ey + ny * o
        local hit, ihx, ihy = RaijinLab:TraceLine(sx, sy, zf, tx, ty, zf, 0x100111)
        if hit and ihx then
            local ddx, ddy = ihx - sx, ihy - sy
            if math.sqrt(ddx * ddx + ddy * ddy) < reach then
                foot_hit, fx2, fy2 = hit, ihx, ihy
                break
            end
        end
    end
    end
    if foot_hit and fx2 then
        do
            a.want_jump = true                       -- hoppable lip: jump it
            local DL = RaijinLab and RaijinLab.DevLog
            if DL then DL.log_every("nav_hop", 0.5, "nav", "terrain LIP(foot) ahead -> hop") end
        end
    end
end

-- Closed-loop re-planning: when steering to a PATHFOUND goal gives up (stuck /
-- fell / deadline), don't just fail - compute a FRESH route from where we are
-- now and try again. That turns a dead end into a solved problem, up to
-- max_replans attempts, after which we truly give up.
local function maybe_replan()
    local g = Navigator._pf_final_goal
    if not g then return end

    -- DO NOT RE-PLAN WHILE ROUNDING A WALL AND MAKING PROGRESS.
    --
    -- The planner cannot see round a long surface - that is precisely why the
    -- reactive layer is driving - so every plan it produces is the straight line
    -- to the goal. Accepting one mid-detour steers us back INTO the wall we were
    -- escaping and gives up the lateral distance already won. Observed: worked
    -- 50 yards north along the face, took a fresh plan back to y=4, and ended
    -- further from a way round than when it started.
    --
    -- While the wall commitment is warm AND we are still displacing, the reactive
    -- layer owns the heading. If it stops making progress the commitment goes
    -- cold and planning resumes - so this can delay a re-plan, never prevent one.
    --
    -- WARM MEANS STILL GETTING SOMEWHERE, NOT STILL WITHIN A DEADLINE.
    --
    -- This used to expire after wall_commit (12) seconds. Rounding is measured at
    -- roughly 2.4 yd/s, so twelve seconds buys about 29 yards - and the walls
    -- worth rounding are hundreds of yards long. The deadline therefore always
    -- expired mid-detour, on a bot that was travelling perfectly well, and handed
    -- the heading back to a planner that cannot see round the surface. Traced:
    -- worked north from y=17 to y=201, the clock ran out, the fresh plan went
    -- back south to y=-7, and it jammed against the same face it had started at.
    -- Every replan reversed the previous one; the 184 yards were spent twice and
    -- kept neither time.
    --
    -- There is no need to guess a duration. Whether following is paying off is
    -- MEASURED, once, by the progress rule above: hold a side, and it is dropped
    -- the moment 3 seconds pass without covering 0.75 yards. So the commitment is
    -- warm exactly while that rule still holds a side. A long wall is now rounded
    -- to its end, and a useless one is released just as fast as before.
    local a = Navigator._active
    local warm = ((a and (a.wall_side or 0) ~= 0) or Navigator._wall_follow) and true or false
    local moving_ok = a and a.progress_t and (now() - a.progress_t) < 2.0
    if warm and moving_ok then
        local DL = RaijinLab and RaijinLab.DevLog
        if DL and DL.log_every then
            DL.log_every("nav_wallhold", 3.0, "nav",
                "re-plan deferred: rounding a wall and still advancing")
        end
        return
    end
    -- COOLDOWN (anti-flap): never replan more than once per replan_cooldown. A genuine
    -- stuck persists and replans after it; transient drift/arcing never triggers one.
    -- With the Surveyor mapping walls and the planner routing around them, a real stuck
    -- is now rare - this keeps a rare event from becoming a recompute storm.
    local t = now()
    if Navigator._last_replan_t and (t - Navigator._last_replan_t) < (cfg().replan_cooldown or 2.0) then
        return
    end
    Navigator._last_replan_t = t
    Navigator._replan_n = (Navigator._replan_n or 0) + 1
    if Navigator._replan_n > (cfg().max_replans or 5) then
        -- PLANNING GAVE UP. THE GOAL DID NOT.
        --
        -- Clearing _pf_final_goal here abandoned the destination outright, and
        -- with it every further attempt: the character stood at the obstacle
        -- doing nothing, which is exactly the reported "it just stops". In the
        -- simulator: replan_n=6, pf_goal=none, parked against a wall with a
        -- one-yard stub path.
        --
        -- Failing to PLAN a route is not proof no route exists - it usually means
        -- the search could not reach around a long surface inside its budget.
        -- The reactive layer can still make progress there: wall-following slides
        -- along the face until the way opens, and every yard travelled changes
        -- the problem the next plan has to solve.
        --
        -- So: stop planning, keep GOING. Steer directly at the goal bearing with
        -- the sensor in charge of the last two yards, and re-arm planning once we
        -- have actually moved somewhere new.
        Navigator._replan_n = 0
        Navigator._plan_exhausted_at = { x = Navigator._px_last, y = Navigator._py_last }
        local a = Navigator._active
        if a then
            a.path = { { x = g.x, y = g.y, z = g.z } }
            a.idx = 1
            a.goal = { x = g.x, y = g.y, z = g.z }
            reset_progress(a)
        else
            Navigator.move_to({ x = g.x, y = g.y, z = g.z },
                              Navigator._pf_opts or { arrive_dist = 5 })
        end
        local DL = RaijinLab and RaijinLab.DevLog
        if DL then DL.log("nav", "plan exhausted -> reactive steer to goal (%.0f,%.0f)",
            g.x, g.y) end
        return
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(0.4, function()
            -- still the same goal (not superseded)? re-solve from here.
            if Navigator._pf_final_goal == g and Navigator.pathfind_to then
                Navigator.pathfind_to(g, Navigator._pf_opts or {})
            end
        end)
    elseif Navigator.pathfind_to then
        Navigator.pathfind_to(g, Navigator._pf_opts or {})
    end
end

-- Stop the character and end the run with a terminal state (safety aborts).
local function abort(reason)
    force_release(); turn_stop()
    release_pitch()   -- unconditional: the latch may keep ascend below, never pitch
    if Navigator._active and Navigator._active.breath_surface then
        Navigator._breath_surface = true
    end
    Navigator.state = reason
    local Ou = RaijinLab and RaijinLab.Outcomes
    if Ou and Navigator._outcome then
        local score = (reason == "arrived") and 1.0
            or ((reason == "stuck" or reason == "fell" or reason == "deadline") and -1.0 or 0.0)
        Ou.settle(Navigator._outcome, score, reason)
        Navigator._outcome = nil
    end
    Navigator._active = nil

    -- SCHEDULE A RE-ARM RATHER THAN GOING QUIET.
    --
    -- abort() stops the ticker, so any recovery living inside step() is
    -- unreachable by construction - the first version of this fix sat in step()
    -- and never once ran. With the ticker stopped and _active nil, NOTHING is
    -- left executing to notice that the goal is still wanted, so the character
    -- stands where it failed for the rest of the session.
    --
    -- A terminal state describes the last ATTEMPT, not the destination. If the
    -- goal is still wanted, try again after a cooldown: collision streams in, the
    -- world moves, and we are a few yards from where we failed - the next attempt
    -- is solving a different problem.
    if reason ~= "arrived" then
        local g = Navigator._pf_final_goal or Navigator._want_goal
        if g and g.x and C_Timer and C_Timer.After then
            local gap = (cfg().rearm_cooldown or 3.0)
            if (now() - (Navigator._rearm_t or 0)) > gap then
                Navigator._rearm_t = now()
                C_Timer.After(gap, function()
                    -- only if nothing else took over in the meantime
                    if Navigator._active then return end
                    local want = Navigator._pf_final_goal or Navigator._want_goal
                    if not (want and want.x) then return end
                    Navigator._replan_n = 0
                    local DL = RaijinLab and RaijinLab.DevLog
                    if DL then DL.log("nav", "re-arm after %s -> (%.0f,%.0f)",
                        tostring(reason), want.x, want.y) end
                    if Navigator.pathfind_to then
                        Navigator.pathfind_to({ x = want.x, y = want.y, z = want.z },
                                              Navigator._pf_opts or { arrive_dist = 5 })
                    end
                end)
            end
        end
    end

    -- Keep the ticker + ascend hold while breath latch is set; step() runs a
    -- survival-only path until lungs recover or feet leave the water.
    if not Navigator._breath_surface then
        release_vertical()
        local ax = A(); if ax and ax.StopMoving then ax.StopMoving() end
        Navigator._stop_ticker()
    end
    dlog("nav", "abort reason=%s replan_n=%s pf_goal=%s breath_latch=%s",
        reason, tostring(Navigator._replan_n or 0),
        Navigator._pf_final_goal and "set" or "none",
        tostring(Navigator._breath_surface))
    if reason == "arrived" then
        local g = Navigator._pf_final_goal
        local px, py = player_pos()
        -- Reached the end of the route. If it was only a PARTIAL route toward a
        -- far pathfind goal (goal beyond loaded terrain / node cap), we're now at
        -- the edge of what was reachable - which has loaded MORE terrain - so
        -- continue with a fresh search from here. This chains local searches to
        -- reach ANY distance. Only treat it as continuation while we're still
        -- meaningfully advancing; a stall folds into the failure re-plan (which
        -- eventually gives up), so an unreachable goal can't loop forever.
        if g and px then
            local far = math.sqrt((px - g.x) ^ 2 + (py - g.y) ^ 2) > (Navigator._pf_arrive or 3) + 2.0
            if far then
                local advanced = true
                local la = Navigator._pf_last_arrive
                if la then
                    if math.sqrt((px - la.x) ^ 2 + (py - la.y) ^ 2) < 3.0 then advanced = false end
                end
                Navigator._pf_last_arrive = { x = px, y = py }
                if advanced then
                    Navigator._replan_n = 0     -- real progress: this isn't a failure
                    if C_Timer and C_Timer.After then
                        -- Was 0.1s: partial stubs replan-arrived in a tight loop
                        -- and the character spun in place. 1.2s lets a real leg run.
                        C_Timer.After(1.2, function()
                            if Navigator._pf_final_goal == g and Navigator.pathfind_to then
                                Navigator.pathfind_to(g, Navigator._pf_opts or {})
                            end
                        end)
                    end
                    return
                end
                maybe_replan()                  -- stalled at the same spot: count it
                return
            end
        end
        Navigator._pf_final_goal = nil          -- truly at the goal: stop
        Navigator._replan_n = 0
        Navigator._pf_last_arrive = nil
    elseif reason == "failed" then
        maybe_replan()                          -- stuck -> re-route from here
    elseif reason == "fell" then
        -- Left the ground / under the map. Steering CANNOT recover from mid-air,
        -- and re-planning would just shove the falling character deeper (this is
        -- the exact bug that walked it to z=-152). Hard stop; the player recovers
        -- via .unstuck / hearth, then a new command re-plans cleanly.
        Navigator._pf_final_goal = nil
        Navigator._replan_n = 0
        if print then print("|cffff5555RaijinLab nav|r stopped: left the ground (recover with .unstuck / hearth)") end
    end
end

-- Survival-only: hold ascend while breath-latched even with no active path.
-- Returns true if the ticker must keep running.
function Navigator.swim_survival_tick()
    local swimming = IsSwimming and IsSwimming()
    if not swimming then
        if Navigator._breath_surface then
            local W = RaijinLab and RaijinLab.Watchdog
            if W and W.note then W.note("surfaced") end
            dlog("nav", "swim survival: surfaced latch clear")
        end
        Navigator._breath_surface = false
        release_vertical()
        release_pitch()   -- left the water: a surviving pitch hold corrupts land moves
        return false
    end
    local px, py, pz = player_pos()
    local breath = Navigator.breath_frac()
    local ctrl = Navigator.swim_control(
        true, pz, nil, breath, nil, Navigator._breath_surface, nil)
    Navigator._breath_surface = ctrl.surface_latch
    if ctrl.vert == "up" then
        set_descend(false); set_ascend(true)
    else
        -- No path: never invent a dive. Release only when latch has cleared.
        if not ctrl.surface_latch then release_vertical() end
    end
    if ctrl.note then
        local W = RaijinLab and RaijinLab.Watchdog
        if W and W.note and (now() - (Navigator._breath_note_t or 0)) > 2 then
            W.note(ctrl.note); Navigator._breath_note_t = now()
        end
    end
    if (now() - (Navigator._survlog_t or 0)) >= 1.0 then
        Navigator._survlog_t = now()
        dlog("nav",
            "swim survival z=%.1f vert=%s breath=%s latch=%s asc=%s desc=%s",
            pz or 0, tostring(ctrl.vert),
            breath ~= nil and string.format("%.2f", breath) or "nil",
            tostring(Navigator._breath_surface),
            tostring(Navigator._ascend), tostring(Navigator._descend))
    end
    return not not Navigator._breath_surface
end

-- One steering step (called by the ticker).
function Navigator.step()
    local a = Navigator._active
    if not a then
        -- NEVER REST IN A TERMINAL STATE WHILE A GOAL IS STILL WANTED.
        --
        -- Live and in the simulator: the Navigator hit "failed" against a wall,
        -- dropped _active, and then sat there for the rest of the session. The
        -- ticker stops, nothing re-arms, and the character stands still forever -
        -- the exact "it just stops and does nothing" report.
        --
        -- A terminal state is a statement about the LAST ATTEMPT, not about the
        -- goal. If the destination is still wanted, the only correct behaviour is
        -- to try again after a cooldown: the world changes (collision streams in,
        -- a mob moves, we drifted a few yards) and the next attempt solves a
        -- different problem.
        local g = Navigator._pf_final_goal or Navigator._want_goal
        if g and (Navigator.state == "failed" or Navigator.state == "stuck"
                  or Navigator.state == "fell") then
            local c0 = cfg()
            local gap = (c0.rearm_cooldown or 3.0)
            if (now() - (Navigator._rearm_t or 0)) > gap then
                Navigator._rearm_t = now()
                Navigator._replan_n = 0
                local DL = RaijinLab and RaijinLab.DevLog
                if DL then DL.log("nav", "re-arm from %s -> goal (%.0f,%.0f)",
                    tostring(Navigator.state), g.x, g.y) end
                if Navigator.pathfind_to then
                    Navigator.pathfind_to({ x = g.x, y = g.y, z = g.z },
                                          Navigator._pf_opts or { arrive_dist = 5 })
                end
            end
        end
        if Navigator.swim_survival_tick() then return end
        Navigator._stop_ticker()
        return
    end
    local c = cfg()
    local px, py, pz = player_pos()
    -- SAFETY 1: require a FULL position. ObjectPosition can intermittently return
    -- only X (y/z nil); driving on that, or doing nil math, is how the character
    -- ends up in the void. No usable position => stop and wait.
    if not (px and py and pz) then set_forward(false); set_strafe(nil); turn_stop(); release_vertical(); set_pitch(nil); return end

    -- SAFETY 2 (THE hard guarantee): am I standing on a floor? Trace straight
    -- down from my feet - if there's no ground within a few yards, I'm airborne /
    -- clipped / under the map, and DRIVING would only send me deeper. So the
    -- instant ground contact is lost, forward movement stops. This makes it
    -- physically impossible for steering to walk the character off a ledge or push
    -- it through the world: the moment it's not grounded, it holds.
    -- NB: keep these branches separate. `X and probe() or pz` would collapse a
    -- genuine nil (no ground) back to pz and defeat the whole gate.
    local gz
    local walk_down = (RaijinLab.GroundCache and RaijinLab.GroundCache.WALK_DOWN) or 6.0
    if RaijinLab.TraceGround then
        gz = RaijinLab:TraceGround(px, py, pz, 2.5, walk_down)   -- nil = no floor beneath
    else
        gz = pz                                            -- no trace support: can't check
    end

    -- "THE RAY FOUND NOTHING" IS NOT "THE CHARACTER IS FALLING".
    --
    -- The trace spans WALK_DOWN yards and its flags (M2 | WMO | terrain | entity)
    -- carry no liquid bit, so it cannot see a water surface at all - Surveyor
    -- says as much, which is why water is learned from IsSwimming instead.
    -- Meanwhile the planner routes through water ON PURPOSE: NavGrid.walkable
    -- returns yes for WATER and Pathfinder merely prices it, because refusing
    -- water turns every river into a wall.
    --
    -- Swimming is a definite, cheap, stock answer. Ask it before accusing.
    -- Kept as a named pure function so it can be tested without a tick: the
    -- version inlined here first shipped with no test that could reach it, and
    -- the mutation harness reported it DECORATIVE - a fix nothing defends.
    local swimming_now = IsSwimming and IsSwimming()
    if Navigator.floor_verdict(gz, swimming_now) == "swimming" then
        gz = pz              -- in water: floating is not falling
        a.airborne_t = nil
    end
    if gz == nil then
        set_forward(false); set_strafe(nil); turn_stop(); release_vertical(); set_pitch(nil)
        local a2 = A(); if a2 and a2.StopMoving then a2.StopMoving() end
        a.airborne_t = a.airborne_t or now()
        local fell = a.start_z and (a.start_z - pz) > (c.abort_fall or 20)
        if fell or (now() - a.airborne_t) > (c.max_airborne or 2.5) then
            -- Blacklist the spot we launched from so we never route through it again.
            local lg = a.last_ground
            if lg then local WM = RaijinLab.WorldMesh; if WM and WM.mark_stuck then WM.mark_stuck(lg.x, lg.y, lg.z) end end
            dlog("nav", "FELL: no ground under (z=%.1f start=%.1f) launch=%s -> hard stop, NO replan",
                pz, a.start_z or 0, lg and string.format("(%.1f,%.1f,%.1f)", lg.x, lg.y, lg.z) or "?")
            return abort("fell")
        end
        return
    end
    a.airborne_t = nil
    a.last_ground = { x = px, y = py, z = gz }   -- remember last solid footing
    -- MAP: record traversal into the persistent navmesh/heatmap (arithmetic-only,
    -- safe every tick). Confirmed-walkable + visit count where the body actually goes.
    local WM = RaijinLab and RaijinLab.WorldMesh
    if WM and WM.observe then WM.observe(px, py, gz, Navigator._moving) end
    a.prev_z = pz

    -- Detailed frame-by-frame log for the FIRST steps of a move, so a fall/clip
    -- right after starting is fully visible in the log (pos, ground, mode flags).
    a.step_n = (a.step_n or 0) + 1
    if a.step_n <= 12 then
        dlog("nav", "step#%d pos=(%.2f,%.2f,%.2f) gz=%.2f moving=%s noclip=%s",
            a.step_n, px, py, pz, gz, tostring(Navigator._moving),
            tostring(RaijinLabDB and RaijinLabDB.noclip_toggle or false))
    end

    -- SAFETY 3: never run forever.
    if a.start_t and (now() - a.start_t) > (c.move_deadline or 60) then
        return abort("failed")
    end

    -- ===== PURE-PURSUIT PATH FOLLOWING =====
    -- Steer toward a LOOK-AHEAD point that slides along the route polyline, not the
    -- exact next waypoint - the character tracks the line smoothly (no wobble) and
    -- cuts corners like a human. Cross-track drift is held by STRAFING (below), not
    -- by turning. We NEVER replan just because the actual path drifts from the plan.
    local poly = a.poly
    if not poly then
        poly = {}
        if a.path and #a.path > 0 then
            for i = 1, #a.path do poly[i] = a.path[i] end
            -- Always end at the real goal. Live partial paths of 1 WP near the
            -- player made remain~0 -> abort(arrived) -> replan every 0.3s = spin.
            local last = a.path[#a.path]
            local g = a.goal
            if g and g.x and last and last.x then
                local dx, dy = g.x - last.x, g.y - last.y
                if (dx * dx + dy * dy) > 9 then
                    poly[#poly + 1] = g
                end
            elseif g and g.x then
                poly[#poly + 1] = g
            end
        else
            poly[1] = a.goal
        end
        a.poly = poly
    end
    local aimx, aimy, cross, remain
    local look = c.look_ahead or 5.0
    -- Near a wall: shorten look-ahead so pure-pursuit cannot cut the corner
    -- through the building (live: 7yd look aimed through church while path
    -- went around the doorway).
    if a.sensor_detour or ((a.wall_side or 0) ~= 0) then
        look = math.min(look, 2.0)
    end
    aimx, aimy, cross, a.idx, remain = Navigator.pursuit(poly, a.idx or 1, px, py, look)
    a.cross = cross
    local dist = remain
    local arrive = a.opts.arrive_dist or c.arrive_dist
    if remain <= arrive then return abort("arrived") end
    -- If the look-ahead aim is behind a solid wall, aim at the next path node
    -- instead of cutting the chord through geometry.
    if aimx and RaijinLab.TraceLine then
        local aim_blocked = RaijinLab:TraceLine(
            px, py, (pz or 0) + 1.2, aimx, aimy, (pz or 0) + 1.2, 0x100111)
        if aim_blocked then
            local ni = math.min((a.idx or 1) + 1, #poly)
            local node = poly[ni] or poly[a.idx or 1]
            if node and node.x then
                aimx, aimy = node.x, node.y
            end
        end
    end

    -- desired heading = toward the look-ahead point + active detour, bent around mobs.
    --
    -- WHILE TOUCHING A WALL, STEER ALONG IT - NOT "GOAL PLUS A BEND".
    --
    -- `goal_h + detour` is only sane while the goal heading is roughly clear.
    -- In sustained contact it is not: the sim reproduced a bot pinned at exactly
    -- x=300.0 on a wall spanning x=300..320, because its route's last waypoint
    -- was INSIDE that wall (partial routes end at the frontier), so the goal
    -- heading pointed into the surface and a +1.9rad bend still left an inward
    -- component. It ground along at 0.4yd/s for 200 seconds.
    --
    -- A surface is followed by steering perpendicular to the direction that was
    -- blocked, with a small outward bias so the body keeps clearance instead of
    -- scraping. The side is the one already committed, so this does not
    -- reintroduce the left/right oscillation the commitment exists to stop.
    local base_h = Navigator.heading_to(px, py, aimx, aimy)
    local gh
    if (a.wall_side or 0) ~= 0 and a.wall_block_h and (a.wall_bend or 0) > 0 then
        local sgn = (a.wall_side >= 0) and 1 or -1
        gh = Navigator.norm(a.wall_block_h
            + sgn * (math.pi * 0.5 + (c.wall_standoff or 0.15)))
        Navigator._wall_follow = true
    else
        gh = Navigator.norm(base_h + (a.detour or 0))
        Navigator._wall_follow = false
    end
    local target_h = gh
    if not a.opts.no_avoid then
        target_h = Navigator.avoid_heading(px, py, gh, gather_obstacles(px, py, a.opts.goal_guid),
            { avoid_clearance = c.avoid_clearance, avoid_range = c.avoid_range,
              avoid_max_bend = c.avoid_max_bend })
    end
    -- SMOOTH the target heading (low-pass) so obstacle avoidance / node changes can't
    -- make it jump frame-to-frame - that jitter made the turn hunt back and forth.
    if a.smooth_th then
        target_h = Navigator.norm(a.smooth_th + Navigator.angle_diff(a.smooth_th, target_h) * (c.target_smooth or 0.35))
    end
    a.smooth_th = target_h

    -- ===== IN-PROCESS TURN (fast TurnByDelta, keyboard fallback) =====
    -- Turn toward target_h mouse-free (no cursor capture), closed loop on the real,
    -- camera-independent heading (player+0x7AC, validated by travel). NEVER CTM.
    local dt = a.last_t and (now() - a.last_t) or 0.033
    if dt <= 0 or dt > 0.5 then dt = 0.033 end
    a.last_t = now()
    local heading = measure_facing(px, py, dt)        -- real, camera-independent heading
    local cf = heading or Navigator._last_heading or target_h
    local errs, cmd, method = 0, 0, "turnby"
    local err
    if heading then
        -- published so the controller can be watched, not only inferred
        Navigator._target_h = target_h
        Navigator._err = nil
        err, errs, cmd, method = turn_toward(cf, target_h, dt)
        Navigator._err, Navigator._method = err, method
        -- RAW proof of life, sampled passively. `_facing_real` is a fusion and
        -- lies once the live source is demoted; this is the sensor itself, and
        -- it is what acquits a turn method that actually works.
        if not Navigator._err_then_t or (now() - Navigator._err_then_t) > 1.0 then
            Navigator._err_then, Navigator._err_then_t = err, now()
        end
        if RaijinLab and RaijinLab.ObjectFacing then
            local okf, rf = pcall(RaijinLab.ObjectFacing, RaijinLab, "player")
            if okf and type(rf) == "number" then
                if Navigator._raw_last
                    and math.abs(Navigator.angle_diff(Navigator._raw_last, rf)) > 0.01 then
                    Navigator._raw_moved_t = now()
                end
                Navigator._raw_last = rf
            end
        end
        -- ENFORCE IT EVERY TICK, NOT JUST ON THE TRANSITION.
        --
        -- set_forward early-returns when the requested state already matches, so
        -- a check inside it only runs when forward is being turned ON. Forward
        -- was already held when the aim went bad, so the interlock was never
        -- re-evaluated and the character kept running blind - which is exactly
        -- what the sim reproduced (err=1.57, heading frozen, still moving).
        if Navigator.aim_unusable() then
            Navigator._held_for_aim_n = (Navigator._held_for_aim_n or 0) + 1
            if Navigator._moving then set_forward(false) end
            -- AND STOP COMMANDING A TURN THAT DOES NOT TURN.
            --
            -- Merely releasing forward leaves the loop grinding: still "moving",
            -- still ordering rotations nothing obeys, forever - which is what the
            -- turning_actually_turns invariant reports. A steering failure is not
            -- a transient to ride out, it is a dead end, so ABORT the move and
            -- say why. The suite can then pick another goal, and the fault is a
            -- named error instead of a character vibrating against a building.
            if (Navigator._held_for_aim_n or 0) >= (Navigator.AIM_ABORT_TICKS or 12) then
                -- SWITCH METHODS BEFORE GIVING UP.
                --
                -- Aborting calls set_turn(nil), which removes the very evidence
                -- the effectiveness measurement needs - so the method that just
                -- failed to steer us was never condemned and got chosen again on
                -- the next move. Live, the navigator sat on `keyboard` (which
                -- rotates nothing on this client) with only `turnby` blacklisted,
                -- 115 degrees off target, indefinitely. If we could not steer,
                -- the method we were using is the prime suspect: mark it and take
                -- the other one into the next attempt.
                -- START THE NEXT ATTEMPT FROM A CLEAN SLATE.
                --
                -- Aborting used to leave `_ineff_method` intact, so the next
                -- move re-selected the same condemned method and aborted again -
                -- permanently. Measured live: `blacklisted=[turnby]`, running on
                -- `keyboard` which rotates nothing on this client, reporting
                -- "cannot_steer: heading will not respond" forever, while a
                -- direct TurnByDelta(0.7) moved the facing by exactly 0.7.
                --
                -- If we could not steer at all, every verdict that led here is
                -- suspect. Forget them and re-derive the choice from the
                -- primitive that exists; a genuinely dead method will simply be
                -- condemned again on fresh evidence.
                Navigator._ineff_method = {}
                Navigator._turn_method = nil
                Navigator._eff, Navigator._eff_cmd, Navigator._eff_prev = nil, 0, nil
                set_turn(nil)
                Navigator._last_err = "cannot_steer: heading will not respond"
                Navigator._held_for_aim_n = 0
                Navigator._turn_suspect_since = nil
                Navigator._aim_bad_since = nil
                Navigator.stop()
                -- stop() releases the keys but leaves the STATE reading "moving"
                -- with the last turn command still on the record, so every
                -- watcher (the turning_actually_turns invariant above all) still
                -- sees an open steering loop after we have given up. Say plainly
                -- that we are neither moving nor steering.
                Navigator.state = "idle"
                Navigator._last_turn_cmd = 0
                Navigator._pf_still = 0
                dlog("nav", "aborting move: %s", Navigator._last_err)
            end
        end
    else
        err = math.abs(Navigator.angle_diff(cf, target_h))   -- no read: hold
    end

    -- PROBE WHERE THE BODY IS GOING, NOT WHERE WE WISH IT WERE GOING.
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
    --
    -- AND FACING IS NOT THE TRAVEL BEARING EITHER, WHENEVER STRAFE IS HELD. Strafe
    -- adds a sideways component, so the body runs the diagonal at about facing +/-
    -- 45 degrees while this pointed the 3-ray sweep dead ahead - the same defect
    -- one layer down: the sweep walks a line the character is not on, so the wall
    -- the character actually clips is never sampled. Cross-track corrections are
    -- exactly when we are cutting toward something off the current facing, which
    -- is the worst time to be blind.
    --
    -- MEASURED beats COMMANDED. The travel bearing sampled from the position delta
    -- already contains the strafe, plus slide along collision, knockback and swim
    -- drift - none of which the key state knows about. Only when there is no fresh
    -- displacement to measure (standing still, first tick of a move) do we fall
    -- back to reconstructing it from the keys we are holding.
    -- Account for our own burst. The 1Hz heartbeat reads an EMA, so a multi-ms
    -- probe spike every 100ms hid inside a clean 33ms median while the player
    -- reported extreme stutter. Track the worst probe cost each second and put
    -- it in the heartbeat: a cost that cannot be seen cannot be argued about.
    local __t0 = debugprofilestop and debugprofilestop()
    local travel_h = cf or target_h
    if Navigator._travel_now and (now() - (Navigator._travel_t or 0)) <= TRAVEL_FRESH then
        travel_h = Navigator._travel_now
    elseif Navigator._strafe then
        -- Strafe only engages inside strafe_cone (1.0 rad), which is inside
        -- move_cone (1.6), so forward is held whenever a strafe is: the body is on
        -- the diagonal, not the pure sideways line. + heading = CCW = left.
        local side = (Navigator._strafe == "left") and 1 or -1
        travel_h = Navigator.norm(travel_h + side * (math.pi / 4))
    end
    terrain_probe(a, px, py, pz, travel_h)
    -- Second probe (desired heading) only when turning hard AND travel is clear.
    -- Was: dual flip every other tick even when nearly aligned -> double TraceLine
    -- cost for no gain. Wall/block detection still runs on travel heading every
    -- probe_hz period (full functionality).
    if not (a.block or (a.detour or 0) ~= 0 or a.want_jump) then
        local dh = math.abs(Navigator.angle_diff(travel_h, target_h))
        a.dual_flip = not a.dual_flip
        if dh > 0.55 and a.dual_flip then
            local saved = a.probe_t
            a.probe_t = a.probe_t2
            terrain_probe(a, px, py, pz, target_h)
            a.probe_t2 = a.probe_t
            a.probe_t = saved
        end
    end
    if __t0 and debugprofilestop then
        local __ms = debugprofilestop() - __t0
        if __ms > (Navigator._probe_peak or 0) then Navigator._probe_peak = __ms end
    end

    -- SWIM: one pure decision, then HOLD the matching keys. Pulsing Jump while
    -- swimming is not depth control - the client only rises while ascend is held.
    -- Depth-seeking itself is PITCH + FORWARD (runtime 1.8.17-pitch): the body
    -- swims along the nose, so pitch down + forward IS the dive; the bare
    -- ascend/descend holds stay as the thrustless fallback (see swim_hold_plan).
    local wp = a.path and a.idx and a.path[a.idx]
    local tz = (wp and wp.z) or (a.goal and a.goal.z) or nil
    local breath = swimming_now and Navigator.breath_frac() or nil
    local ctrl = Navigator.swim_control(
        swimming_now, pz, tz, breath, a.shore,
        a.breath_surface or Navigator._breath_surface, nil)
    a.breath_surface = ctrl.surface_latch
    Navigator._breath_surface = ctrl.surface_latch
    a.swim_vert = ctrl.vert
    a.swim_ctrl = ctrl

    -- Forward intent is decided HERE (applied below, after the jump block)
    -- because the depth mechanism depends on it: with no forward there is no
    -- thrust for the pitch to aim, so the plan must know which world it is in.
    local block = a.block
    if ctrl.clear_cliff or ctrl.force_forward then block = false end
    -- Real chest-wall contacts must NEVER be force-forwarded through.
    -- Live: force_forward + 1s no_progress cleared block while standing on a
    -- building face -> ram forever. Only soft/false blocks may be overridden.
    local real_wall = a.sensor_detour
        or ((a.wall_side or 0) ~= 0)
        or (a.wall_hit_t and (now() - a.wall_hit_t) < 1.5)
    local no_progress = a.progress_t and (now() - a.progress_t) > 1.0
    if no_progress and (a.opts and a.opts.force_forward) and not real_wall
       and not a.block_void then
        -- Soft false-positive (slope/door lip): allow drive-through. A missing
        -- floor is never a false positive - "no progress" at a ledge is the
        -- sensor working, so drive-through must not reach it.
        block = false
        a.block = false
    end
    -- TURN IN PLACE when facing is wrong. force_forward used to force walk at
    -- any error -> perfect circles (live: err=1.5-2.0 rad, fwd=true, dist flat).
    local cone = c.move_cone or 0.85
    -- WHEN YOU ARE FOLLOWING A WALL, THE WALL IS AHEAD. THAT IS WHAT CONTACT IS.
    --
    -- `not block` used to kill forward outright, so the only motion left while in
    -- contact was the sideways force_strafe. That made every improvement to the
    -- mesh make the bot WORSE: a coarse mesh rarely reported a solid cell ahead,
    -- so forward stayed on and the face was skirted at ~2.4 yd/s; a mesh fine
    -- enough to actually resolve the wall reported it constantly, forward died,
    -- and skirting collapsed to a crawl. That crawl then fell under the "0.75yd
    -- in 3s is not progress" release, which dropped the committed side, which let
    -- the planner replan straight back into the face. Traced end to end on the
    -- 800-yard wall: north to y=201, released, reversed, jammed at y=-17.
    --
    -- The heading here is already the BENT one - the obstacle layer rotates it
    -- along the face before this point - so `err < cone` means "pointing along
    -- the wall", not "pointing into it". Driving forward on that heading is
    -- exactly what a player does: hold forward and run along the surface. Forward
    -- is still cut when there is no committed side, which is the genuinely
    -- head-on case with no chosen way out.
    --
    -- ...AND IT APPLIES TO WALLS ONLY. A ledge is not a surface to skirt.
    -- Rounding a wall means the solid thing is BESIDE you; at a drop there is
    -- nothing beside you to follow, and holding forward walks off it. The first
    -- version of this clause tested `block` alone, so a committed wall side
    -- released forward at cliff edges too - reported live as driving straight
    -- into a cliff. block_void is never overridden, by this or anything else.
    local following = (a.wall_side or 0) ~= 0 and (a.wall_bend or 0) > 0
        and not a.block_void
    -- RUN WHILE YOU TURN, LIKE A PERSON (2026-08-03).
    --
    -- A fixed cone makes the bot stand PERFECTLY STILL and pivot before taking
    -- a step - live: twelve consecutive frames at the identical position while
    -- the heading swung 1.78 -> 2.52. Nobody plays that way; a human starts
    -- running immediately and ARCS onto the line.
    --
    -- Widening the cone is not the answer either: it was 2.4 rad once and
    -- produced circles. The difference between arcing and orbiting is not the
    -- angle, it is whether the aim is CLOSING. So this is closed-loop: keep
    -- running while the heading error is actually shrinking, and fall back to
    -- pivot-in-place the moment it stops shrinking. Orbiting IS "error not
    -- closing", so the failure mode switches forward off by construction
    -- rather than being excluded by a magic constant.
    --
    -- The hard cap stays: past ~90 degrees the target is genuinely behind us
    -- and turning first is what a person does too.
    -- REVERTED PENDING PROPER WORK (2026-08-03). The closed-loop version of
    -- this - keep running while the heading error is CLOSING, capped at 90
    -- degrees - is the right idea for "move like a person instead of pivoting
    -- in place for twelve frames". But it failed plans_around_walls_at_range
    -- and breath_panic_surfaces: running while turning changes wall-rounding
    -- and swim-surfacing behaviour, and I had not reasoned about either.
    --
    -- The scenarios are correct to reject it. Shipping a behaviour change that
    -- breaks two proven scenarios to satisfy a feel complaint would trade a
    -- known-good for an unknown, which is exactly the two-steps-forward-one-back
    -- pattern this project keeps paying for. The arc work needs those two
    -- scenarios understood first, not the assertion loosened.
    local fwd_on = (err < cone) and (not block or following)
    -- Soft force: only walk while turning if still within ~70deg. Never at 90deg+.
    if a.opts and a.opts.force_forward and not block and err < 1.2 then
        fwd_on = true
    end
    local steps = a.step_n or 0
    -- Standing still with small error: nudge forward. Large error: keep turning.
    if steps > 25 and not Navigator._travel_now and not block and err < cone then
        fwd_on = true
    end
    -- THE ANTI-STALL NUDGE MUST NOT NUDGE ANYONE OFF A CLIFF.
    --
    -- This guarded on `real_wall` and not on `block`, and real_wall is false at a
    -- ledge: there is no wall side, no sensor detour, no recent wall hit - only
    -- missing floor. So after 50 steps it re-enabled forward unconditionally and
    -- overrode the cliff stop that had correctly fired one line above. Measured:
    -- floor_ahead=false and block_void=true at x=58.4, 59.1 and 59.6, and the
    -- character still crossed the rim at 59.6 -> 64.2 at full run speed. Every
    -- other clause here already tests `not block`; this one was the hole.
    if steps > 50 and not Navigator._travel_now and not real_wall
       and not block and err < 0.9 then
        fwd_on = true
    end
    local can_pitch = swimming_now and pitch_capable()
    if swimming_now and ctrl.surface_latch and can_pitch then
        -- Breath overrides aim: pitch up + forward + ascend together surfaces
        -- at full swim speed instead of waiting for the turn to converge with
        -- empty lungs. Only forced when pitch is real - on an old bridge,
        -- forward without pitch is a horizontal push into whatever is ahead.
        fwd_on = true
    end
    -- MEASURED beats COMMANDED (forward_effective's own lesson): a commanded-
    -- but-dead forward would leave pitch as the "primary" depth mechanism with
    -- zero thrust behind it while the fallback holds sat released. Unknown
    -- (nil, just started) still counts as driving; only proven-dead demotes.
    local fwd_drives = fwd_on and can_pitch
        and Navigator.forward_effective() ~= false
    local plan = Navigator.swim_hold_plan(
        swimming_now, ctrl.vert, ctrl.surface_latch, fwd_drives, a.shore)
    -- can_pitch gate: never book-keep a hold on a bridge that stubs the
    -- command - a phantom "held" pitch is state that only exists on our side.
    set_pitch(can_pitch and plan.pitch or nil)
    if plan.ascend then
        set_descend(false); set_ascend(true)
    elseif plan.descend then
        set_ascend(false); set_descend(true)
    else
        release_vertical()
    end
    if ctrl.note then
        local W = RaijinLab and RaijinLab.Watchdog
        if W and W.note and (now() - (a.breath_note_t or 0)) > 2 then
            W.note(ctrl.note); a.breath_note_t = now()
        end
    end
    if swimming_now then
        Navigator._wet = true
    else
        release_vertical()
        if Navigator._wet then
            -- WATER -> LAND EDGE: both pitch stops UNCONDITIONALLY, not the
            -- edge-tracked release - the tracked state is exactly what cannot
            -- be trusted at the moment a held pitch would corrupt land moves.
            Navigator._wet = false
            release_pitch()
        end
    end

    -- Land hop only (pebble/lip). Never a substitute for swim ascend hold.
    --
    -- NEVER HOP AT A LEDGE. A hop is the right answer to a lip with floor behind
    -- it and the worst possible answer at a rim: it converts a stop into a
    -- launch, clearing exactly the gap the sensor is trying to refuse. Stuck
    -- recovery also jumps on its third attempt, so an edge that pins the bot
    -- would eventually be jumped off by the recovery itself.
    if a.want_jump and a.block_void then
        a.want_jump = false
        local DL = RaijinLab and RaijinLab.DevLog
        if DL then DL.log_every("nav_hop", 1.0, "nav", "hop refused: no floor ahead") end
    end
    if a.want_jump and not swimming_now then
        a.want_jump = false
        local aj = A()
        if aj and aj.Jump and (now() - (a.jump_t or 0)) >= c.jump_gap then
            aj.Jump(); a.jump_t = now()
        end
    elseif a.want_jump and swimming_now then
        a.want_jump = false   -- swim uses set_ascend, not Jump pulse
    end

    -- Wall backoff: stop forward and strafe along the committed side so the
    -- body slides off the face instead of grinding. No MoveBackward on this
    -- client - strafe + replan is the escape.
    if a.want_backoff and not swimming_now then
        a.want_backoff = false
        fwd_on = false
        local side = a.wall_side or a.detour or 0.9
        a.force_strafe = (side > 0) and "left" or "right"
        a.force_strafe_t = now()
        dlog("nav", "wall backoff strafe=%s detour=%.2f", tostring(a.force_strafe), side)
    end
    if a.want_replan and not swimming_now then
        a.want_replan = false
        dlog("nav", "wall replan from pathfind goal")
        maybe_replan()
    end
    -- SUSTAINED CONTACT STRAFES TOO, NOT JUST THE BACKOFF INSTANT.
    --
    -- force_strafe used to live 0.6s after a backoff and nothing else, so a long
    -- wall was travelled by the bent heading alone - and the sideways component
    -- that actually got the body along the face came from the cross-track
    -- controller. That controller is gone (it was steering the whole route and
    -- fighting the turn), so the obstacle layer must ask for its own strafe:
    -- while we are IN CONTACT and committed to a side, slide along it. This is
    -- strafe used for the one thing it is for.
    if a.block and (a.wall_side or 0) ~= 0 and not swimming_now then
        a.force_strafe = (a.wall_side > 0) and "left" or "right"
        a.force_strafe_t = now()
    end
    if a.force_strafe and a.force_strafe_t and (now() - a.force_strafe_t) < 0.6 then
        -- hold the escape strafe; applied below after want_strafe calc
    elseif a.force_strafe then
        a.force_strafe = nil
    end

    -- run forward once roughly aimed AND not blocked by a cliff ahead.
    -- (fwd_on was decided next to the swim plan above, which needs it.)
    set_forward(fwd_on)

    -- STRAFE IS FOR OBSTACLES. IT IS NOT FOR STEERING.
    --
    -- This used to sidestep whenever cross-track error passed 1.8yd, which any
    -- real route exceeds constantly - every waypoint corner, every turn settle.
    -- The result was the character shuffling sideways the whole way to its
    -- destination: "randomly pressing strafe arbitrarily when it could just be
    -- walking in a straight line".
    --
    -- It was also redundant. Pure-pursuit ALREADY angles back onto the line, so
    -- the strafe was a second controller fighting the first over the same error,
    -- with a 1.8yd deadband against a turn that corrects continuously. Two
    -- controllers on one error is how you get oscillation.
    --
    -- A person walking to a point turns and walks. They sidestep to get around
    -- something. So: only the obstacle layer (wall-follower / body-width probe)
    -- may strafe, via force_strafe. Course is the turn's job, exclusively.
    local want_strafe = a.force_strafe or nil
    set_strafe(want_strafe)

    -- Turn/steer diagnostic - the primary window into the loop. Logs the camera
    -- heading (used for control) next to PlayerFacing and the ACTUAL travel
    -- direction, so we can confirm the turn is really rotating the character:
    -- `travel` should track `head`. If travel stays fixed while head/tgt move, the
    -- turn primitive is not rotating the character.
    -- First 12 steps + 2Hz after: full turn diagnostics without 33Hz log spam.
    if a.step_n and (a.step_n <= 12 or (now() - (a.turnlog_t or 0)) >= 0.5) then
        a.turnlog_t = now()
        dlog("nav", "turn#%d head=%s cam=%s(ok=%s) travel=%s tgt=%.3f err=%+.3f m=%s turn=%s fwd=%s dist=%.1f",
            a.step_n, heading and string.format("%.3f", heading) or "nil",
            Navigator._cam_now and string.format("%.3f", Navigator._cam_now) or "nil",
            tostring(Navigator._cam_ok),
            Navigator._travel_now and string.format("%.3f", Navigator._travel_now) or "nil",
            target_h, errs or 0, tostring(method), tostring(Navigator._turn),
            tostring(Navigator._moving), dist)
    end
    -- Swim/shore line: what live testing needs to prove hold-keys and latch.
    if swimming_now or a.shore or Navigator._breath_surface then
        if (now() - (a.swimlog_t or 0)) >= 1.0 then
            a.swimlog_t = now()
            dlog("nav",
                "swim z=%.1f vert=%s pitch=%s shore=%s breath=%s latch=%s asc=%s desc=%s water_ahead=%s floor_ahead=%s fwd=%s",
                pz, tostring(ctrl.vert), tostring(Navigator._pitch), tostring(a.shore),
                breath ~= nil and string.format("%.2f", breath) or "nil",
                tostring(Navigator._breath_surface),
                tostring(Navigator._ascend), tostring(Navigator._descend),
                tostring(a.water_ahead), tostring(a.floor_ahead),
                tostring(Navigator._moving))
        end
    end

    -- stuck detection: did we advance stuck_dist since the anchor within window?
    if a.anchor then
        if a.breath_surface then
            -- Forced surfacing (breath latch) holds forward with the nose
            -- pitched hard up: ~zero XY displacement is the CORRECT reading,
            -- not a stuck. Refresh the clock rather than merely skipping the
            -- check - a clock that AGES through the emergency would declare
            -- stuck on the FIRST tick after the latch clears, and turn-hunting
            -- recovery or a "failed" abort mid-climb interrupts the surfacing.
            a.progress_t = now()
        end
        local mdx, mdy = px - a.anchor.x, py - a.anchor.y
        if math.sqrt(mdx * mdx + mdy * mdy) >= c.stuck_dist then
            -- LEARN: escaping a stuck via recovery proves THIS spot is a working
            -- seam (the one place you CAN get up/through) - remember it.
            if (a.recover_n or 0) > 0 then
                local WM = RaijinLab.WorldMesh
                if WM and WM.mark_ramp then WM.mark_ramp(px, py, pz) end
            end
            -- PROGRESS CLEARS RECOVERY, NOT PERCEPTION.
            --
            -- a.detour is the ONLY channel by which the wall/cliff sensor
            -- influences the heading, and this zeroed it on every 0.8yd of
            -- movement. Running along a building means making progress every
            -- tick, so the sensor's steering output was erased as fast as it was
            -- produced - the bot "saw" the wall continuously and never acted on
            -- it. Recovery state (the escalating side-alternating angle) SHOULD
            -- clear on progress; a live sensor reading should not.
            reset_progress(a); a.recover_n = 0
            if not a.sensor_detour then a.detour = 0 end
            Navigator.state = "moving"
        elseif (Navigator._moving or a.block) and (now() - (a.progress_t or now())) > c.stuck_secs then
            -- No progress while trying to move OR while blocked by a wall ahead ->
            -- recover: turn to hunt a clear direction (now that big turns actually
            -- work). This is how it escapes a wall / gets out of a building.
            Navigator.state = "stuck"
            if not recover(a) then return abort("failed") end   -- gave up gracefully
        else
            if Navigator.state ~= "stuck" then Navigator.state = "moving" end
        end
    end
end

-- ---- ticker (own high-frequency frame) ----
function Navigator._start_ticker()
    if Navigator._frame then return end
    if not CreateFrame then return end
    local f = CreateFrame("Frame")
    local acc = 0
    f:SetScript("OnUpdate", function(_, e)
        acc = acc + (e or 0)
        if acc >= 0.03 then acc = 0
            local ok, err = pcall(Navigator.step)
            if not ok then
                -- A bug must NEVER leave the character careening. Hard-stop.
                Navigator._last_err = tostring(err)
                -- ...BUT A SILENT HARD-STOP IS A SILENT DEATH. This recorded the
                -- error into a field nothing ever read or printed, then called
                -- stop() -> _stop_ticker(), ending navigation permanently. Live:
                -- steps ceased at step#12 while the quest engine went on
                -- reporting "accept:to ? st=8 d=20 (moving)" for FOURTEEN
                -- MINUTES, 20 yards from the npc. Say what happened, once per
                -- distinct error, so the next freeze names its own cause.
                Navigator._err_n = (Navigator._err_n or 0) + 1
                if Navigator._err_last_shown ~= Navigator._last_err then
                    Navigator._err_last_shown = Navigator._last_err
                    dlog("nav", "STEP ERROR (#%d) - navigation stopped: %s",
                        Navigator._err_n, Navigator._last_err)
                end
                pcall(function()
                    local a = RaijinLab and RaijinLab.Actions
                    -- FULL RELEASE = STAGE A NATIVE HALT (2026-08-03). This
                    -- released all seven inputs by calling the PROTECTED
                    -- movement APIs one at a time, which is what pops "blocked
                    -- from an action only available to the Blizzard UI" (see
                    -- Master.halt_movement). HaltMovement is drained by the
                    -- runtime frame hook with no Lua on the stack and releases
                    -- every held key, stops and commits - the same intent,
                    -- without touching a protected API from addon context.
                    if a and a.HaltMovement then pcall(a.HaltMovement) end
                    if a and a.StopMoving then a.StopMoving() end
                end)
                Navigator._moving = false
                Navigator._strafe = nil
                Navigator._turn = nil
                Navigator._pitch = nil
                Navigator.stop()
            end
        end
    end)
    Navigator._frame = f
end
function Navigator._stop_ticker()
    if Navigator._frame then
        Navigator._frame:SetScript("OnUpdate", nil)
        Navigator._frame = nil
    end
    -- release the turn keys if the ticker stops without going through stop()/abort()
    local a = RaijinLab and RaijinLab.Actions
    if a then if a.TurnLeft then a.TurnLeft(false) end; if a.TurnRight then a.TurnRight(false) end end
    Navigator._turn = nil
    -- same for the pitch pair: a hold outliving the ticker is a wedged key
    if a then if a.PitchUp then a.PitchUp(false) end; if a.PitchDown then a.PitchDown(false) end end
    Navigator._pitch = nil
end

-- ---- live path visualization (drawing callback) ----
-- Draws the active route (player -> remaining waypoints -> goal) plus a goal
-- marker, projected via the real camera WorldToScreen. Registered/unregistered
-- through the shared 30Hz drawing loop by set_draw().
function Navigator.draw()
    local a = Navigator._active
    local d = RaijinLab and RaijinLab.drawing
    if not a or not d then return end
    local px, py, pz = player_pos()
    if not px then return end
    -- route
    if d.SetColorRaw then d:SetColorRaw(0.2, 1.0, 0.45, 0.9) end
    if d.SetWidth then d:SetWidth(3) end
    local prevx, prevy, prevz = px, py, pz
    local nodes = {}
    if a.path then for i = a.idx, #a.path do nodes[#nodes + 1] = a.path[i] end end
    nodes[#nodes + 1] = a.goal
    for _, n in ipairs(nodes) do
        if d.Line then d:Line(prevx, prevy, prevz, n.x, n.y, n.z) end
        prevx, prevy, prevz = n.x, n.y, n.z
    end
    -- goal marker
    if d.SetColorRaw then d:SetColorRaw(1.0, 0.82, 0.1, 0.9) end
    if d.Circle then d:Circle(a.goal.x, a.goal.y, a.goal.z, 1.2) end
end

-- ---- high-level: real pathfinding to a goal, then steer the route ----
-- Runs an async A* (Pathfinder, on the Scheduler) that finds a walkable route
-- around real terrain, then hands the resulting waypoints to move_to so the
-- steerer follows them. Falls back to direct steering when no pathfinder /
-- position is available or no route is found. The search never hitches the
-- frame; while it runs, state is "pathfinding" and movement holds.
-- Remembered separately from _pf_final_goal, which the give-up paths clear.
-- Without a surviving record of what was WANTED there is nothing to re-arm from,
-- and the terminal state becomes permanent.
Navigator._want_goal = nil

function Navigator.pathfind_to(goal, opts)
    opts = opts or {}
    -- record what was WANTED, before any give-up path can clear _pf_final_goal
    if goal and goal.x then
        Navigator._want_goal = { x = goal.x, y = goal.y, z = goal.z }
    end
    local PF = RaijinLab and RaijinLab.Pathfinder
    local px, py, pz = player_pos()
    -- start mapping the surroundings immediately so the search + follow have terrain
    local Sv = RaijinLab and RaijinLab.Surveyor
    if Sv and Sv.start then Sv.start() end
    -- Scheduler must be alive for async PF.find. Without it, state stays
    -- "pathfinding" and the character never takes a step.
    local S0 = RaijinLab and RaijinLab.Scheduler
    if S0 and S0.start then pcall(S0.start) end
    if not PF or not PF.find or not px then
        return Navigator.move_to(goal, opts)
    end
    -- Already working this goal: do not cancel the in-flight A* / active route.
    -- Suite idle re-arm used to call pathfind_to every 0.3s, which cancelled the
    -- job before it could finish and left nav idle forever.
    local eps = 1.5
    local function same_goal(g)
        return g and goal and goal.x
            and math.abs((g.x or 0) - goal.x) < eps
            and math.abs((g.y or 0) - goal.y) < eps
            and math.abs((g.z or 0) - (goal.z or 0)) < 4
    end
    -- A SEARCH THAT NEVER ANSWERS MUST NOT WEDGE THE STATE MACHINE.
    --
    -- "pathfinding" is only meaningful while a job is actually running. If the
    -- job is gone and no route arrived - the search was cancelled, the scheduler
    -- never ran it, or a callback returned early - the state is a lie, and the
    -- guard below then refuses every future search because we are "already
    -- searching". Nothing recovers, because nothing is running to recover.
    --
    -- Observed: _pf_job nil, _pf_goal set, state "pathfinding", the ghost parked
    -- 40 yards from its corpse for the entire window. A stale state must expire.
    if Navigator.state == "pathfinding" and not Navigator._pf_job
        and not Navigator._active then
        local age = Navigator._pf_t0 and (now() - Navigator._pf_t0) or math.huge
        if age > (cfg().pf_stale_secs or 3.0) then
            dlog("nav", "pathfinding state stale (no job, no route) -> idle")
            Navigator.state = "idle"
            -- do NOT clear _pf_goal here: a result may still be in flight, and
            -- the callback decides staleness by comparing against this value.
            -- Clearing it makes the arriving answer judge ITSELF stale and throw
            -- away a perfectly good route - the same defect this expiry exists to
            -- break, reintroduced one layer up.
        end
    end
    if Navigator.state == "pathfinding" and same_goal(Navigator._pf_goal) then
        -- A SEARCH IN FLIGHT IS NOT A LICENCE TO KEEP RUNNING BLIND.
        --
        -- This early return is correct - do not restart a search already solving
        -- the same goal - but it is also the path every repeat call takes, so any
        -- release placed after it never executes. With no active route the held
        -- keys are just the last direction we happened to face; the ghost ran 607
        -- yards east of a corpse 40 yards west, at full speed, for the whole
        -- window, because nothing on this path ever let go.
        if not Navigator._active then force_release() end
        return true
    end
    if Navigator._active and Navigator.state == "moving" and same_goal(Navigator._active.goal) then
        return true
    end
    -- INSTANT PATH: if the straight line to the goal is clear (torso-height ray),
    -- there is nothing to route around - steer DIRECT immediately instead of
    -- spinning up the async collision-graph A*. This is the common case (visible
    -- target) and makes it zero-latency; look-ahead avoidance handles anything that
    -- appears en route. Only a genuinely occluded goal pays for a (bounded) search.
    -- A CLEAR TRACE IS ONLY EVIDENCE WITHIN LOADED COLLISION. The client streams
    -- terrain and WMO collision around the player; a ray cast at something 2km away
    -- spends almost all of its length in space that has nothing loaded to hit, and
    -- comes back "clear". Taking that as proof of an open route is exactly how the
    -- bot ended up walking straight into walls with dist=2203 in the live log and
    -- never planning a single path all session.
    --
    -- So the shortcut only applies at ranges where a miss actually means something.
    -- Past that, plan - which is the case that needs planning most.
    local goal_dist = math.sqrt((px - goal.x) ^ 2 + (py - goal.y) ^ 2)
    -- FUNDAMENTAL: a single torso ray "clear" is NOT proof of a walkable route
    -- through town. WMO collision streams incompletely; rays skim roofs and
    -- miss walls; then move_to rams the character into the building. Live:
    -- pathfind_to LoS-clear at ~22-36yd -> direct into the same church every time.
    -- Only allow the instant direct shortcut for very short hops with multi-
    -- height clear rays AND no NavGrid STRUCTURE on the segment.
    -- Pass the ELEVATION difference too: the church this comment describes has an
    -- upper floor, and a quest giver standing on it is horizontally close with a
    -- clear ray - the exact case that walked the character into the wall below.
    local _gz = goal and (goal.z or goal[3])
    local _px, _py, _pz = player_pos()
    local allow_los_shortcut = Navigator.los_shortcut_ok(
        goal_dist, opts, Navigator.LOS_TRUST_RANGE,
        (_gz and _pz) and (_gz - _pz) or nil)
    if allow_los_shortcut and RaijinLab.TraceLine then
        local structure = false
        local NG = RaijinLab.NavGrid
        if NG and NG.at and NG.STRUCTURE then
            local steps = math.max(3, math.floor(goal_dist / 3))
            for i = 0, steps do
                local t = i / steps
                local sx = px + (goal.x - px) * t
                local sy = py + (goal.y - py) * t
                local okc, code = pcall(NG.at, sx, sy)
                if okc and code == NG.STRUCTURE then structure = true; break end
            end
        end
        if not structure then
            local clear = true
            for _, h in ipairs({ 0.5, 1.2, 1.8 }) do
                local blocked = RaijinLab:TraceLine(
                    px, py, (pz or 0) + h,
                    goal.x, goal.y, (goal.z or pz or 0) + h, 0x100111)
                if blocked then clear = false; break end
            end
            if clear then
                dlog("nav", "pathfind_to: short multi-height LoS clear at %.0fyd -> direct", goal_dist)
                return Navigator.move_to(goal, opts)
            end
        end
    elseif not opts._from_replan and goal_dist > Navigator.LOS_TRUST_RANGE then
        dlog("nav", "pathfind_to: goal %.0fyd beyond LoS trust range -> planning", goal_dist)
    end
    local S = RaijinLab.Scheduler
    if Navigator._pf_job and S and S.cancel then S.cancel(Navigator._pf_job) end
    -- Reset the re-plan counter only when this is a genuinely NEW goal (a re-plan
    -- keeps counting toward max_replans; a fresh user goal starts over).
    local pg = Navigator._pf_final_goal
    if not pg or pg.x ~= goal.x or pg.y ~= goal.y or pg.z ~= goal.z then
        Navigator._replan_n = 0
        Navigator._pf_last_arrive = nil
    end
    Navigator._pf_final_goal = goal
    Navigator._pf_opts = opts
    Navigator._pf_arrive = opts.arrive_dist or cfg().arrive_dist
    -- HOLDING MOVEMENT ONLY MAKES SENSE IF WE HAVE A ROUTE TO HOLD.
    --
    -- Movement deliberately persists across a search so a long plan does not
    -- stutter the character mid-route. That is right when there IS a route being
    -- refined, and dangerous when there is not: with no active path the held keys
    -- are simply the last direction we happened to face, and nothing is steering.
    --
    -- Observed: a ghost released facing east, pathfind_to was called, no route
    -- ever came back, and it ran 607 yards due east away from a corpse 40 yards
    -- west - travelling fast and confidently in a direction nothing had chosen.
    -- That is the "runs off in a random direction" report, exactly.
    if not Navigator._active then force_release() end
    Navigator.state = "pathfinding"
    Navigator._pf_goal = goal
    Navigator._pf_t0 = now()
    dlog("nav", "pathfind_to goal=(%.1f,%.1f,%.1f) from=(%.1f,%.1f,%.1f) dist=%.1f replan_n=%d",
        goal.x, goal.y, goal.z or 0, px, py, pz or 0,
        math.sqrt((px - goal.x) ^ 2 + (py - goal.y) ^ 2), Navigator._replan_n or 0)
    Navigator._pf_job = PF.find({ x = px, y = py, z = pz }, goal, function(path, status)
        Navigator._pf_job = nil
        Navigator._pf_t0 = nil
        -- WHICH BRANCH DID THE ANSWER TAKE? Every corpse-run / stuck-goal
        -- investigation has cost hours because the callback is invisible: the
        -- only observable is the state AFTER it, and four different branches
        -- leave the same state behind. These two fields cost nothing and make
        -- the search outcome directly readable by tools/rl.py.
        Navigator._pf_cb_n = (Navigator._pf_cb_n or 0) + 1
        Navigator._pf_last = "enter:" .. tostring(status) .. "/" .. tostring(path and #path or 0)
        dlog("nav", "pathfind result status=%s waypoints=%s", tostring(status), path and tostring(#path) or "nil")
        -- A STALE RESULT MUST NOT LEAVE US IN A SEARCHING STATE.
        --
        -- Discarding a result whose goal changed is right. Returning without
        -- touching the state is not: state stays "pathfinding" with no job and no
        -- route, and the guard at the top of pathfind_to then early-returns on
        -- every subsequent call because we are "already searching" - so nothing
        -- ever searches again. A permanent deadlock.
        --
        -- It is easy to reach: any caller that rebuilds its goal table each tick
        -- (Death.tick hands goto_fn a fresh {x,y,z} every time) invalidates the
        -- in-flight result by identity, every time. The corpse run stood still
        -- 40 yards from the body for the whole window because of this.
        -- STALENESS IS ABOUT THE DESTINATION, NOT THE TABLE IDENTITY.
        --
        -- This compared `_pf_goal ~= goal` by reference while the guard at the
        -- top of pathfind_to compares COORDINATES. Any caller that rebuilds its
        -- goal each tick - Death.tick hands goto_fn a fresh {x,y,z} every time -
        -- therefore invalidated its own in-flight result on every tick: the
        -- search finished, its answer was thrown away as "stale" for a goal that
        -- had not moved an inch, and the cycle repeated forever. The corpse run
        -- stood 40 yards from the body for the entire window.
        --
        -- Two checks on the same question must use the same definition.
        local cur = Navigator._pf_goal
        local same = cur and goal and cur.x and goal.x
            and math.abs(cur.x - goal.x) < 0.5
            and math.abs((cur.y or 0) - (goal.y or 0)) < 0.5
        Navigator._pf_last = "same=" .. tostring(same)
        if not same then
            Navigator._pf_last = "stale"
            if Navigator.state == "pathfinding" and not Navigator._active then
                Navigator.state = "idle"     -- never strand the state machine
            end
            return
        end
        if path and #path >= 2 then
            local wp = {}
            for i = 2, #path do wp[#wp + 1] = path[i] end   -- skip our own start node
            -- Reject useless partial stubs: last node still at the player's feet
            -- while the real goal is far. Live: partial waypoints=2 -> move_to 1 WP
            -- -> arrived instantly -> replan forever = spin in place.
            local pnowx, pnowy = player_pos()
            local last = wp[#wp]
            local stub = false
            if pnowx and last and last.x and goal and goal.x then
                local d_last = math.sqrt((pnowx - last.x) ^ 2 + (pnowy - last.y) ^ 2)
                local d_goal = math.sqrt((pnowx - goal.x) ^ 2 + (pnowy - goal.y) ^ 2)
                local arrive = opts.arrive_dist or 3
                Navigator._pf_dbg = string.format(
                    "dlast=%.1f dgoal=%.1f arrive=%.1f nwp=%d st=%s lastxy=(%.0f,%.0f) me=(%.0f,%.0f)",
                    d_last, d_goal, arrive, #wp, tostring(status),
                    last.x or -1, last.y or -1, pnowx or -1, pnowy or -1)
                -- A STUB IS A ROUTE THAT GOES NOWHERE - NOT A SHORT ONE.
                --
                -- This asked "is the last node still at my feet?" as
                -- `d_last < arrive + 3`, scaling the foot-radius by the ARRIVAL
                -- TOLERANCE. Those measure different things: arrive_dist says
                -- when to stop, not what counts as progress. The corpse run uses
                -- arrive=20, so "at my feet" quietly became "within 23 yards" -
                -- more than half of a 40-yard trip.
                --
                -- What that cost: A* returned status=found with one waypoint at
                -- (118,100) for a corpse at (100,100) - a correct, complete route
                -- that ends inside the 20yd tolerance it was given. d_last=22.2 <
                -- 23, d_goal=40 > 28, #wp<=1: all three true, so the right answer
                -- was discarded as a stub on every one of ten searches, and the
                -- ghost never moved off (140,100).
                --
                -- Measure the thing we actually care about: does following this
                -- route get us CLOSER TO THE GOAL? A stub is a route that does
                -- not. That is scale-free, needs no tuning, and cannot be fooled
                -- by a generous arrival tolerance.
                local d_last_goal = math.sqrt((last.x - goal.x) ^ 2 + (last.y - goal.y) ^ 2)
                local progress = d_goal - d_last_goal
                if progress < 2.0 and d_goal > arrive and (status == "partial" or #wp <= 1) then
                    stub = true
                    dlog("nav", "pathfind: reject stub (no progress %.1fyd) d_goal=%.1f", progress, d_goal)
                end
            end
            Navigator._pf_last = "stub=" .. tostring(stub)
            if not stub then
                local F = RaijinLab and RaijinLab.Fail
                if F and F.clear then
                    pcall(F.clear, string.format("nav:stuck:%.0f:%.0f", goal.x or 0, goal.y or 0))
                end
                local ok = Navigator.move_to(goal, {
                    waypoints = wp,
                    arrive_dist = opts.arrive_dist,
                    goal_guid = opts.goal_guid,
                    force_forward = opts.force_forward,
                })
                Navigator._pf_last = (ok == false) and "move_reject" or "move_ok"
                if ok == false then
                    dlog("nav", "pathfind: move_to rejected after route -> idle re-arm allowed")
                    Navigator.state = "idle"
                end
            else
                -- Side-step then replan instead of thrashing the same stub.
                path = nil
                status = "stub"
            end
        end
        if not (path and #path >= 2) or status == "stub" then
            -- No full route: still do NOT ram the final goal in a straight line
            -- through a building. Detour laterally, then replan.
            dlog("nav", "pathfind: no route (status=%s) -> side step + replan", tostring(status))
            local ang = math.atan2(goal.y - py, goal.x - px)
            local side = ((Navigator._replan_n or 0) % 2 == 0) and 1 or -1
            local det = {
                x = px + math.cos(ang + side * 1.2) * 12,
                y = py + math.sin(ang + side * 1.2) * 12,
                z = pz,
            }
            Navigator._replan_n = (Navigator._replan_n or 0) + 1
            Navigator.move_to(det, {
                arrive_dist = 3, force_forward = true,
            })
            if C_Timer and C_Timer.After and Navigator._replan_n < 6 then
                C_Timer.After(2.0, function()
                    if Navigator._pf_final_goal == goal then
                        Navigator.pathfind_to(goal, opts)
                    end
                end)
            end
        end
    end, {
        step = opts.step or 3.0, arrive = opts.arrive_dist or 3.0,
        max_nodes = opts.max_nodes or 4000, dirs = opts.dirs or 16, max_ms = 0.8,
    })
    -- Watchdog: if pathfind hangs, side-step then replan - never naked direct
    -- into the obstacle that caused the hang.
    if C_Timer and C_Timer.After then
        local gref = goal
        C_Timer.After(1.2, function()
            if Navigator.state == "pathfinding" and Navigator._pf_goal == gref then
                dlog("nav", "pathfind watchdog: 1.2s no result -> side step")
                if Navigator._pf_job and S0 and S0.cancel then pcall(S0.cancel, Navigator._pf_job) end
                Navigator._pf_job = nil
                Navigator._pf_t0 = nil
                local p2x, p2y, p2z = player_pos()
                if p2x then
                    local ang = math.atan2(gref.y - p2y, gref.x - p2x)
                    Navigator.move_to({
                        x = p2x + math.cos(ang + 1.4) * 10,
                        y = p2y + math.sin(ang + 1.4) * 10,
                        z = p2z,
                    }, { arrive_dist = 3, force_forward = true })
                    C_Timer.After(1.5, function()
                        if Navigator._pf_final_goal == gref then
                            local o2 = {}
                            for k, v in pairs(opts) do o2[k] = v end
                            o2._no_los_shortcut = true
                            o2._from_replan = true
                            Navigator.pathfind_to(gref, o2)
                        end
                    end)
                end
            end
        end)
    end
    return true
end

function Navigator.set_draw(on)
    if not RaijinLab or not RaijinLab.AddDrawingCallback then return false end
    if on then
        RaijinLab:AddDrawingCallback("navPath", Navigator.draw)
    else
        RaijinLab:RemoveDrawingCallback("navPath")
    end
    Navigator._drawing = on and true or false
    return true
end

if RaijinLab then RaijinLab.Navigator = Navigator end
return Navigator
