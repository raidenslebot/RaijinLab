local pf = "nil"
local gp = "nil"
if RaijinLab and RaijinLab.Actions and RaijinLab.Actions.PlayerFacing then
    local ok, f = pcall(RaijinLab.Actions.PlayerFacing)
    if ok then pf = tostring(f) end
end
local ok2, g = pcall(function() return GetPlayerFacing() end)
if ok2 then gp = tostring(g) end
local tgt = "nil"
if UnitGUID then
    local ok3, t = pcall(function() return UnitGUID("target") end)
    if ok3 then tgt = tostring(t) end
end
return "PF=" .. pf .. " LUA=" .. gp .. " TGT=" .. tgt
