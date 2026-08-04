local R = RaijinLab
local out = {}
local function line(s) out[#out + 1] = tostring(s) end

if R and R.RuntimeCall then
    line("AuraProbe(player)=" .. tostring(R:RuntimeCall("AuraProbe", 0)))
    -- Full runtime aura list (sid:stacks:remMs) — much broader than AuraProbe's 5.
    line("UnitAuras(player)=" .. tostring(R:RuntimeCall("UnitAuras", 0)))
    line("ProcFreezeState=" .. tostring(R:RuntimeCall("ProcFreezeState")))
end
-- Full UnitAura enumeration (de)buff, with ids.
if UnitAura then
    local found = {}
    for i = 1, 48 do
        local n, _, _, _, _, _, exp, _, _, _, _, _, id = UnitAura("player", i)
        if not n then break end
        found[#found + 1] = string.format("%d=%d:%s(%.0fs)", i, id or 0, n, (exp or 0))
    end
    line("UnitAuraAll=" .. table.concat(found, " | "))
end
return table.concat(out, "\n")

