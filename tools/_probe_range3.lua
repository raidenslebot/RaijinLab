local out = {}
for _, sid in ipairs({45477, 45513, 46501, 26573}) do
    local ok, v = pcall(function() return RaijinLab:RuntimeCall("SpellInfoLive", sid) end)
    out[#out+1] = tostring(ok and v or ("ERR " .. tostring(v)))
end
return table.concat(out, "  ||  ")
