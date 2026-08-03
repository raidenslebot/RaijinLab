local ver = "nil"
local okv, v = pcall(function() return RaijinLab:RuntimeCall("GetRuntimeVersion") end)
if okv then ver = tostring(v) end
local pfraw = "nil"
local okp, p = pcall(function() return RaijinLab:RuntimeCall("PlayerFacing") end)
if okp then pfraw = tostring(p) end
return "VER=" .. ver .. " PFRAW=" .. pfraw
