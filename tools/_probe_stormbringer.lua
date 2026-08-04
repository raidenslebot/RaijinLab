local R = RaijinLab
local out = {}
local function line(s) out[#out + 1] = tostring(s) end

-- Dump the raw player aura walk (runtime AuraProbe -> entry: sid(xN,f0xX,dur/exp ms)).
if R and R.RuntimeCall then
    local p = R:RuntimeCall("AuraProbe", 0)
    line("player AuraProbe=" .. tostring(p))
end

-- Also enumerate player buffs via the standard API for a readable cross-check.
if UnitBuff then
    local found = {}
    local i = 1
    while i < 48 do
        local n = UnitBuff("player", i)
        if not n then break end
        found[#found + 1] = string.format("%d:%s", i, n)
        i = i + 1
    end
    line("UnitBuff list=" .. table.concat(found, " | "))
end

return table.concat(out, "\n")

