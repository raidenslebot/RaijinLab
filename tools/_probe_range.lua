local out = {}
for _, sid in ipairs({45477, 45513, 46501, 26573, 6603}) do
    local ok, v = pcall(function() return RaijinLab:RuntimeCall("SpellMeleeInfo", sid) end)
    out[#out+1] = sid .. "=" .. tostring(ok and v or "ERR")
end
return table.concat(out, "  ")
