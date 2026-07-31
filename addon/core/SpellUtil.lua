-- Pure helpers for spell id resolution (unit-tested; used by rotation editor).

local SpellUtil = {}

-- Parse a wow spell hyperlink or raw string for the numeric spell id.
-- Examples: "|cff71d5ff|Hspell:133|h[Fireball]|h|r" -> 133
--           "spell:133" -> 133
function SpellUtil.spell_id_from_link(link)
    if type(link) ~= "string" or link == "" then return nil end
    local id = link:match("[Hh]spell:(%d+)") or link:match("spell:(%d+)")
    if id then return tonumber(id) end
    return nil
end

-- Given GetCursorInfo-style returns for a spell drag on 3.3.5:
--   ctype="spell", slot=<spellbook index>, bookType="spell"|"pet"
-- resolve via a provided get_spell_link(slot, bookType) callback.
function SpellUtil.resolve_spellbook_cursor(slot, bookType, get_spell_link, get_spell_name, get_spell_info)
    if type(slot) ~= "number" then return nil end
    local link = get_spell_link and get_spell_link(slot, bookType)
    local spellId = SpellUtil.spell_id_from_link(link)
    local name = get_spell_name and get_spell_name(slot, bookType)
    if not name and spellId and get_spell_info then
        name = get_spell_info(spellId)
    end
    if spellId then
        return spellId, name
    end
    -- Non-stock: some unlockers put real id in `slot`
    if slot > 1000 and get_spell_info and get_spell_info(slot) then
        return slot, get_spell_info(slot)
    end
    return nil
end

-- Mark aura table entries by spell id when the aura is present by name.
function SpellUtil.mark_aura_ids(aura_table, spell_ids, get_spell_info)
    if type(aura_table) ~= "table" or type(spell_ids) ~= "table" then return aura_table end
    for _, id in ipairs(spell_ids) do
        local n = get_spell_info and get_spell_info(id)
        if n and aura_table[n] then
            aura_table[id] = true
            aura_table[tostring(id)] = true
        end
    end
    return aura_table
end

if RaijinLab then
    RaijinLab.SpellUtil = SpellUtil
end

return SpellUtil
