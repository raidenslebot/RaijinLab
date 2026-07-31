"""rlctl - drive the LIVE WoW client from the command line.

    python tools/rlctl.py "RaijinLab.Navigator.state"
    python tools/rlctl.py -f snippet.lua
    python tools/rlctl.py --state
    python tools/rlctl.py --esp

WHY. Every diagnosis here has been a round trip through a human: ask for a slash
command, wait for a screenshot, read numbers off an image. Three wrong guesses
about why the ESP rendered nothing cost more than building this. A screenshot
cannot be grepped, diffed, or asserted on.

HOW IT IS SAFE. The DLL's pipe thread never touches the client - it queues a
string. The addon's OnUpdate (Ipc.lua) pops it, runs it on the GAME'S MAIN
THREAD, and hands the text back. Nothing off-thread ever touches Lua or the
object manager, which is the rule this client punishes hardest.

Requires: client running, DLL injected, addon loaded. Anything else gives a
specific error rather than a hang.
"""

import argparse
import os
import struct
import sys
import time

PIPE = r"\\.\pipe\RaijinLab"


def call(code, timeout=15.0, retries=3):
    """Send one Lua chunk, return its output text. Raises RuntimeError on fail."""
    last = None
    for attempt in range(retries):
        try:
            # Opening the pipe as a file is enough: the server is byte-mode and
            # handles one request per connection.
            f = open(PIPE, "r+b", buffering=0)
        except OSError as exc:
            last = exc
            time.sleep(0.25)
            continue
        try:
            payload = code.encode("utf-8", "replace")
            f.write(struct.pack("<I", len(payload)) + payload)
            f.flush()
            head = f.read(4)
            if len(head) != 4:
                raise RuntimeError("pipe closed before replying")
            (n,) = struct.unpack("<I", head)
            body = b""
            while len(body) < n:
                chunk = f.read(n - len(body))
                if not chunk:
                    break
                body += chunk
            return body.decode("utf-8", "replace")
        finally:
            f.close()
    raise RuntimeError(
        "cannot open %s (%s).\n"
        "  The client must be RUNNING with the DLL INJECTED. If it is, the DLL "
        "predates the IPC build - re-inject." % (PIPE, last))


# Canned dumps. These exist because the same questions get asked every session,
# and retyping a multi-line Lua chunk into a shell is its own source of errors.
PRESETS = {
    # ONE COMMAND THAT ANSWERS THE QUESTION "WHY IS IT DOING THAT".
    #
    # Diagnosing a single live fault repeatedly cost 5-15 round trips of
    # hand-written Lua, several of which failed on syntax before returning
    # anything. Every field below was one I actually had to go and fetch, and the
    # groupings mirror the order the chain fails in: can it sense, can it decide,
    # can it steer, can it move. Add to this rather than writing another one-off.
    "diag": """
local R = RaijinLab
local N = R.Navigator
local S = R.QuestSuite
local Q = R.QuestDB
local o = {}
local function line(s) o[#o+1] = s end
local function f2(v) return type(v) == "number" and string.format("%.2f", v) or tostring(v) end

local px, py, pz = R:ObjectPosition("player")
local face = R:ObjectFacing("player")
line(string.format("POS      %.1f, %.1f, %.1f  facing=%s  zone=%s (%s)",
    px or 0, py or 0, pz or 0, f2(face),
    tostring(Q and Q.current_zone and Q.current_zone()),
    tostring(GetRealZoneText and GetRealZoneText())))

-- SENSE
local L = R.om and R.om.object_list
local zero = 0
if L and L.npcs then
    for i = 1, #L.npcs do
        local r = R:RuntimeCall("ObjectPosition", L.npcs[i].Guid)
        if type(r) == "string" and string.find(r, "^0%.000|0%.000") then zero = zero + 1 end
    end
end
line(string.format("SENSE    npcs=%s (%d at 0,0,0)  gos=%s  players=%s  esp=%s",
    tostring(L and L.npcs and #L.npcs), zero,
    tostring(L and L.gameobjects and #L.gameobjects),
    tostring(L and L.players and #L.players),
    tostring(R.ObjectESP and R.ObjectESP.enabled)))

-- KNOW
local cal = Q and Q._cal or {}
local cz = Q and Q.current_zone and Q.current_zone()
local c = cz and cal[cz]
local croot = nil
if Q and Q.to_root and cz then
    local rz = Q.to_root(cz, 0.5, 0.5)
    croot = cal[rz]
end
line(string.format("KNOW     qdb=%s  cal[%s]=%s solved=%s err=%s samples=%s",
    tostring(Q and Q.available and Q.available()), tostring(cz),
    tostring(c ~= nil), tostring(c and c.t_solved ~= nil),
    f2(c and c.err), tostring(c and #c.samples)))

-- DECIDE
line("DECIDE   " .. tostring(S and S.status and S.status()))

-- STEER
line(string.format("STEER    method=%s err=%s turn=%s lastcmd=%s eff=%s cmd_n=%s",
    tostring(N._method), f2(N._err), tostring(N._turn),
    f2(N._last_turn_cmd), f2(N._eff), tostring(N._eff_cmd)))
local ineff = {}
for k in pairs(N._ineff_method or {}) do ineff[#ineff+1] = k end
line(string.format("         override=%s blacklisted=[%s] suspect=%s held_n=%s last_err=%s",
    tostring(N._turn_method), table.concat(ineff, ","),
    tostring(N._turn_suspect_since ~= nil), tostring(N._held_for_aim_n),
    tostring(N._last_err)))

-- MOVE
local a = N._active
local g = N._pf_final_goal or N._pf_goal
local dz = (g and g.z and pz) and (g.z - pz) or nil
line(string.format("MOVE     state=%s active=%s moving=%s follow=%s block=%s",
    tostring(N.state), tostring(a ~= nil), tostring(N._moving),
    tostring(N._wall_follow), tostring(a and a.block)))
line(string.format("         goal=%s dz=%s  pf=%s replan=%s",
    g and string.format("%.1f,%.1f,%.1f", g.x or 0, g.y or 0, g.z or 0) or "none",
    f2(dz), tostring(N._pf_dbg), tostring(N._replan_n)))

-- WORLD probes straight ahead: the "why did it hit that" evidence
if px and face then
    local ax, ay = px + math.cos(face) * 5, py + math.sin(face) * 5
    local gh = R.TraceGround and R:TraceGround(px, py, pz + 3, 3, 12)
    local ga = R.TraceGround and R:TraceGround(ax, ay, pz + 3, 3, 12)
    local hit = R.TraceLine and R:TraceLine(px, py, pz + 1.4, ax, ay, pz + 1.4)
    line(string.format("AHEAD    wall=%s ground_here=%s ground_5yd=%s step=%s",
        tostring(hit), f2(gh), f2(ga),
        (gh and ga) and f2(ga - gh) or "?"))
end
return table.concat(o, string.char(10))
""",
    "state": """
local R = RaijinLab
local out = {}
local function add(k, v) out[#out+1] = k .. "=" .. tostring(v) end
add("runtime", R.HasRuntime and R:HasRuntime())
add("version", R.RuntimeVersion and R:RuntimeVersion())
add("master", R.Master and R.Master.enabled)
add("quest", R.QuestSuite and R.QuestSuite.running)
add("nav", R.Navigator and R.Navigator.state)
add("nav_active", R.Navigator and (R.Navigator._active ~= nil))
local L = R.om and R.om.object_list
add("npcs", L and L.npcs and #L.npcs)
add("gos", L and L.gameobjects and #L.gameobjects)
local x, y, z = R:ObjectPosition("player")
add("pos", x and string.format("%.1f,%.1f,%.1f", x, y, z))
add("zone", R.QuestDB and R.QuestDB.current_zone and R.QuestDB.current_zone())
add("qdb", R.QuestDB and R.QuestDB.available and R.QuestDB.available())
print(table.concat(out, "  "))
""",
    "esp": """
local R = RaijinLab
local E = R.ObjectESP
if not E then print("ObjectESP MISSING (restart the client - new TOC file)") return end
print("enabled=" .. tostring(E.enabled) .. " mode=" .. tostring(E.mode)
      .. " range=" .. tostring(E.range))
print("drawing object=" .. tostring(R.GetDrawingObject and (R:GetDrawingObject() ~= nil)))
local c = R.GetCameraData and R:GetCameraData()
print("camera=" .. tostring(c ~= nil))
if not c then print("  raw=" .. tostring(R:RuntimeCall("GetCameraData"))) end
local x, y, z = R:ObjectPosition("player")
if x and R.WorldToScreen then
    local on, nx, ny = R.WorldToScreen(x, y, z + 2)
    print("w2s(self)=" .. tostring(on) .. " " .. tostring(nx) .. "," .. tostring(ny))
end
local ok, err = pcall(E.draw)
print("draw=" .. (ok and "ok" or ("ERROR " .. tostring(err))))
""",
    "objects": """
local R = RaijinLab
local L = R.om and R.om.object_list
if not (L and L.gameobjects) then print("no object list") return end
local px, py, pz = R:ObjectPosition("player")
local rows = {}
for i = 1, #L.gameobjects do
    local g = L.gameobjects[i]
    local x, y, z = R:ObjectPosition(g.Guid)
    local d = x and math.sqrt((x-px)^2 + (y-py)^2) or -1
    local dyn = g.DynamicFlags and g.DynamicFlags.value or 0
    local b1 = tonumber(R:RuntimeCall("GameObjectBytes1", g.Guid)) or 0
    rows[#rows+1] = { d = d, s = string.format("e=%-8s d=%-6.1f lo=0x%04X type=%d",
        tostring(g.Id), d, dyn % 65536, math.floor(b1/256) % 256) }
end
table.sort(rows, function(a,b) return a.d < b.d end)
for i = 1, math.min(#rows, 25) do print(rows[i].s) end
print("total=" .. #rows)
""",
}


def main():
    ap = argparse.ArgumentParser(description="drive the live WoW client")
    ap.add_argument("code", nargs="?", help="Lua to run in the client")
    ap.add_argument("-f", "--file", help="run a Lua file's contents")
    ap.add_argument("--timeout", type=float, default=15.0)
    for name in PRESETS:
        ap.add_argument("--" + name, action="store_true",
                        help="canned dump: " + name)
    a = ap.parse_args()

    code = None
    for name in PRESETS:
        if getattr(a, name, False):
            code = PRESETS[name]
            break
    if code is None and a.file:
        code = open(a.file, "r", encoding="utf-8").read()
    if code is None:
        code = a.code
    if not code:
        ap.print_help()
        return 2

    try:
        print(call(code, timeout=a.timeout))
    except (RuntimeError, OSError) as exc:
        print("rlctl: %s" % exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
