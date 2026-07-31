"""Stop everything BEFORE the client tears itself down.

Crash 2026-07-29: ACCESS_VIOLATION writing 0x00000000 at 0x007CECFF, during
PLAYER_LOGOUT. The faulting instruction is `mov [eax], esi` with EAX=0 - a null
write in a linked-list unlink - inside a recursive teardown traversal, and ECX
held 0x4D56455E (ASCII-looking) rather than a plausible pointer: a freed or
corrupted node.

That is the shape of something walking the client's object/frame lists while the
client is destroying them. Our logout handler did real WORK (WorldMesh.evict,
Traversability.prune, ConfigBackup.save, DB sanitize) but never STOPPED anything
first, so through the whole teardown we still had:

  * Scheduler's OnUpdate frame running jobs every frame
  * the Navigator ticker steering, raycasting and holding movement keys
  * the 1Hz Instrument heartbeat doing a TraceGround and a full OM snapshot
  * the injected runtime enumerating the object manager
  * the draw ticker touching textures parented to WorldFrame

We cannot prove from the dump that this caused it (the client blames no addon,
and none of the faulting frames are ours). But an injected agent that keeps
reading the object manager while the client frees it is a genuine hazard whether
or not it fired this time, and "stop, then flush" is the correct order anyway -
the current code flushes while still running.
"""
from pathlib import Path

R = Path(r"C:\Ascension\Workspace\RaijinLab")

# ---- the halt itself, next to the other lifecycle code --------------------
ev = R / "addon/core/Events.lua"
s = ev.read_text(encoding="utf-8")

ANCH = "local variables_loaded = false"
HALT = '''-- EVERYTHING OFF, IN THE RIGHT ORDER, BEFORE THE CLIENT TEARS DOWN.
--
-- Order matters and is deliberate:
--   1. release held INPUT first - a held MoveForward/turn/pitch key surviving
--      into logout is the one thing that can still move the character while its
--      own systems are being freed.
--   2. stop the tickers that touch the world (navigator, instrument, drawing,
--      scheduler) so nothing walks the object manager mid-teardown.
--   3. tell the runtime to stop enumerating the OM.
--   4. only THEN flush to disk.
--
-- Every step is pcall'd individually: a halt that aborts halfway is worse than
-- no halt, because it leaves exactly the subsystem that errored still running.
function RaijinLab.HaltAll(why)
    local function try(f, ...) if f then pcall(f, ...) end end

    -- 1. inputs
    local N = RaijinLab.Navigator
    if N then
        try(N.stop)
        try(N.release_all)          -- may not exist on older builds; try() is safe
        try(N._stop_ticker)
    end
    local A = RaijinLab.Actions
    if A then
        try(A.MoveForward, false); try(A.MoveBackward, false)
        try(A.StrafeLeft, false);  try(A.StrafeRight, false)
        try(A.TurnLeft, false);    try(A.TurnRight, false)
        try(A.Ascend, false);      try(A.Descend, false)
        try(A.PitchUp, false);     try(A.PitchDown, false)
        try(A.StopMoving)
    end

    -- 2. tickers and background work
    local M = RaijinLab.Master
    if M and M.stop_all then try(M.stop_all, "logout") end
    if RaijinLab._instr_t and RaijinLab._instr_t.Cancel then
        try(function() RaijinLab._instr_t:Cancel() end)
        RaijinLab._instr_t = nil
    end
    try(RaijinLab.DestroyDrawing, RaijinLab)
    local S = RaijinLab.Scheduler
    if S then try(S.clear); try(S.stop) end

    -- 3. the runtime must stop reading the object manager
    if RaijinLab.RuntimeCall then
        try(RaijinLab.RuntimeCall, RaijinLab, "SetSystemVar", "om.enable", "0")
    end

    local DL = RaijinLab.DevLog
    if DL and DL.log then try(DL.log, "boot", "halted (" .. tostring(why or "?") .. ")") end
end

local variables_loaded = false'''
assert ANCH in s, "anchor not found"
assert "function RaijinLab.HaltAll" not in s
s = s.replace(ANCH, HALT, 1)

# ---- call it FIRST on both teardown paths ---------------------------------
OLD = """    if event == "PLAYER_LOGOUT" then
        -- Last chance before WoW writes SavedVariables to disk. Flush the active
        -- rotation and sanitize the DB so the write can't be poisoned."""
NEW = """    if event == "PLAYER_LOGOUT" then
        -- STOP FIRST, THEN FLUSH. This used to flush while every ticker was
        -- still running and the runtime was still enumerating the object
        -- manager, straight through the client's own teardown.
        RaijinLab.HaltAll("logout")
        -- Last chance before WoW writes SavedVariables to disk. Flush the active
        -- rotation and sanitize the DB so the write can't be poisoned."""
assert OLD in s
s = s.replace(OLD, NEW, 1)

OLD2 = """    if event == "PLAYER_LEAVING_WORLD" then"""
NEW2 = """    if event == "PLAYER_LEAVING_WORLD" then
        -- Also a teardown: /reload and character-select free the object manager
        -- the same way. Cheap to repeat, and the modules re-arm on world entry.
        RaijinLab.HaltAll("leaving_world")"""
assert OLD2 in s
s = s.replace(OLD2, NEW2, 1)
ev.write_text(s, encoding="utf-8")
print("Events: HaltAll runs before any teardown flush")

# ---- make sure the drawing teardown cannot leave live textures ------------
dr = R / "addon/core/Drawing.lua"
t = dr.read_text(encoding="utf-8")
OLD3 = """function RaijinLab:DestroyDrawing()"""
NEW3 = """-- Hide and drop every pooled texture before releasing `private`. The pool is
-- parented to a WorldFrame child, so leaving live textures attached while the
-- client frees its frame tree is exactly the kind of dangling reference that
-- turns a teardown into a null-pointer unlink.
function RaijinLab:DestroyDrawing()
    if private then
        for _, T in ipairs(private.lines_used or {}) do pcall(function() T:Hide() end) end
        for _, T in ipairs(private.lines or {}) do pcall(function() T:Hide() end) end
        private.lines, private.lines_used = {}, {}
        private.callbacks = {}
    end"""
assert OLD3 in t, "DestroyDrawing not found"
t = t.replace(OLD3, NEW3, 1)
dr.write_text(t, encoding="utf-8")
print("Drawing: teardown hides and drops the texture pool first")
