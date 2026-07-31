-- Ipc - run Lua sent from outside the game, on the main thread, and send the
-- result back.
--
-- WHY THIS EXISTS. Development has been a round trip: ask for a slash command,
-- wait for a screenshot, read numbers off an image, guess again. Three wrong
-- guesses about why nothing rendered cost more time than writing this would
-- have. A screenshot cannot be grepped and it cannot be diffed.
--
-- THE THREADING CONTRACT, which is the only part that can hurt you. The DLL runs
-- a named-pipe server on a BACKGROUND thread, but it never touches the client -
-- it moves a string into a queue and waits. This file is the other half: an
-- OnUpdate, so it is already on the game's main thread, where Lua and the object
-- manager may legally be touched. Nothing else in the path crosses a thread.
--
-- ONE JOB PER FRAME, deliberately. A drain loop here would let a caller stall
-- the client for as long as it kept feeding work - and this project has already
-- frozen world entry once with exactly that shape of loop.

local Ipc = {}
RaijinLab.Ipc = Ipc

Ipc.enabled = true
Ipc.jobs = 0
Ipc.last_err = nil

local MAX_REPLY = 60000     -- the pipe accepts 1MB; keep replies readable

-- Render a returned value usefully. `tostring` on a table gives an address,
-- which is exactly the useless answer that made GUID dumps unreadable.
local function dump(v, depth, seen)
    depth = depth or 0
    seen = seen or {}
    local t = type(v)
    if t == "string" then return v end
    if t == "number" or t == "boolean" or t == "nil" then return tostring(v) end
    if t ~= "table" then return "<" .. t .. ">" end
    if seen[v] then return "<cycle>" end
    if depth > 4 then return "<deep>" end
    seen[v] = true
    local parts, n = {}, 0
    -- array part first, so lists read like lists
    for i = 1, table.maxn and table.maxn(v) or #v do
        if v[i] ~= nil then
            n = n + 1
            parts[#parts + 1] = dump(v[i], depth + 1, seen)
            if n > 200 then parts[#parts + 1] = "..." break end
        end
    end
    local arrn = n
    for k, val in pairs(v) do
        if not (type(k) == "number" and k >= 1 and k <= arrn) then
            n = n + 1
            parts[#parts + 1] = tostring(k) .. "=" .. dump(val, depth + 1, seen)
            if n > 200 then parts[#parts + 1] = "..." break end
        end
    end
    seen[v] = nil
    return "{" .. table.concat(parts, ", ") .. "}"
end
Ipc.dump = dump

-- Run one chunk and return its output as text. PURE with respect to the game
-- except for whatever the chunk itself does, so the tests can drive it directly.
--
-- `print` is captured for the duration: a snippet that prints is far more natural
-- to write than one that has to build a return value, and losing that output to
-- the chat frame would defeat the point of running it from outside.
function Ipc.run(code)
    if type(code) ~= "string" or code == "" then return "ERROR: empty chunk" end
    local loader = loadstring or load
    if not loader then return "ERROR: no loadstring in this client" end

    -- Bare expressions are the common case ("RaijinLab.Navigator.state"), so try
    -- them as a return first and fall back to a statement chunk.
    local fn, err = loader("return " .. code)
    if not fn then fn, err = loader(code) end
    if not fn then return "COMPILE ERROR: " .. tostring(err) end

    local lines = {}
    local old_print = print
    print = function(...)
        local n = select("#", ...)
        local bits = {}
        for i = 1, n do bits[i] = dump((select(i, ...))) end
        lines[#lines + 1] = table.concat(bits, "\t")
    end

    local ok, a, b, c, d = pcall(fn)

    print = old_print

    local out = {}
    for i = 1, #lines do out[#out + 1] = lines[i] end
    if not ok then
        out[#out + 1] = "ERROR: " .. dump(a)
    else
        -- Only append a value line when the chunk actually produced one, so a
        -- pure-print snippet is not padded with a bare "nil".
        if a ~= nil or b ~= nil then
            local vals = { dump(a) }
            if b ~= nil then vals[#vals + 1] = dump(b) end
            if c ~= nil then vals[#vals + 1] = dump(c) end
            if d ~= nil then vals[#vals + 1] = dump(d) end
            out[#out + 1] = table.concat(vals, "\t")
        end
    end
    local s = table.concat(out, "\n")
    if string.len(s) > MAX_REPLY then
        s = string.sub(s, 1, MAX_REPLY) .. "\n<truncated>"
    end
    return s
end

-- Poll at most ~6.6 Hz. A RuntimeCall every rendered frame is pure idle FPS
-- cost when the pipe is empty (the common case for players, not harness).
local pump = CreateFrame("Frame")
local ipc_acc = 0
pump:SetScript("OnUpdate", function(_, e)
    if not Ipc.enabled then return end
    ipc_acc = ipc_acc + (e or 0)
    if ipc_acc < 0.15 then return end
    ipc_acc = 0
    if not (RaijinLab.HasRuntime and RaijinLab:HasRuntime()) then return end
    local ok, id, code = pcall(RaijinLab.RuntimeCall, RaijinLab, "IpcPoll")
    if not ok or not id or not code then return end
    Ipc.jobs = Ipc.jobs + 1
    local ran, out = pcall(Ipc.run, code)
    if not ran then
        Ipc.last_err = tostring(out)
        out = "HARNESS ERROR: " .. tostring(out)
    end
    pcall(RaijinLab.RuntimeCall, RaijinLab, "IpcReply", id, out)
end)
Ipc.frame = pump

return Ipc
