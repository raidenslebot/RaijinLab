local R = RaijinLab
local out = {}
local function line(s) out[#out + 1] = tostring(s) end

if R and R.RuntimeCall then
    line("SpellInfoLive(273056)=" .. tostring(R:RuntimeCall("SpellInfoLive", 273056)))
    line("SpellMeleeInfo(273056)=" .. tostring(R:RuntimeCall("SpellMeleeInfo", 273056)))
end

return table.concat(out, "\n")

