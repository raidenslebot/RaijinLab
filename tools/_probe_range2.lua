local out = {}
for _, sid in ipairs({45477, 45513, 46501}) do
    local ok, v = pcall(function() return RaijinLab:RuntimeCall("SpellInfoLive", sid) end)
    if ok and type(v) == "string" then
        -- extract the re0..re7 dwords and ri
        local ri = v:match("ri=(%d+)")
        local res = {}
        for i = 0, 7 do
            res[i+1] = v:match("re%d=0x(%x+)"):format() -- not right
        end
        -- simpler: just print the whole tail
        out[#out+1] = sid .. " " .. tostring(ri) .. " " .. (v:match("re0=(%x+).*") or "?")
    else
        out[#out+1] = sid .. " ERR " .. tostring(v)
    end
end
return table.concat(out, "\n")
