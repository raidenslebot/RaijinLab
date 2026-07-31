-- Vendor - selling junk, repairing, and restocking consumables.
--
-- This is what closes the loop on unattended play: without it the bag fills with
-- grey drops until nothing can be looted, gear wears to zero, and the food that
-- Rest depends on runs out and never comes back.
--
-- SELLING IS DESTRUCTIVE and cannot be undone, so every rule here is deliberately
-- conservative:
--   * only POOR (grey) quality by default - never white/green/blue and above;
--   * never anything the client marks as a quest item;
--   * never anything on the keep-list, and never an item with no sell value;
--   * a per-run cap, so a mis-set option cannot liquidate an entire bank in one
--     visit before anyone notices.
-- Buying and repairing only ever spend money, which is recoverable, so those are
-- allowed to be more automatic - but repair still refuses when it would leave us
-- unable to afford anything else.

local Vendor = {}

local floor, min, max = math.floor, math.min, math.max

Vendor.DEFAULTS = {
    sell_junk      = true,
    max_quality    = 0,      -- 0 = POOR/grey only. 1 would include commons - opt-in.
    max_sales      = 24,     -- hard cap per merchant visit
    repair         = true,
    repair_reserve = 100000, -- copper to keep back (10g) so we are never stranded
    restock        = true,
    food_target    = 20,     -- how many food/drink to carry
    drink_target   = 20,
    low_durability = 35,     -- % below which a repair trip is worth it
    min_free_slots = 4,      -- below this, a vendor trip is worth it
}

Vendor._sold = 0

local function now() return (GetTime and GetTime()) or 0 end

function Vendor.cfg()
    RaijinLabDB = RaijinLabDB or {}
    RaijinLabDB.vendor = RaijinLabDB.vendor or {}
    local c = RaijinLabDB.vendor
    for k, v in pairs(Vendor.DEFAULTS) do if c[k] == nil then c[k] = v end end
    c.keep_ids = c.keep_ids or {}
    c.junk_ids = c.junk_ids or {}      -- force-sell these even if not grey
    return c
end

-- ---- inventory facts -----------------------------------------------------

function Vendor.free_slots()
    if not (GetContainerNumSlots and GetContainerItemLink) then return 0 end
    local free = 0
    for bag = 0, 4 do
        local n = GetContainerNumSlots(bag) or 0
        for slot = 1, n do
            if not GetContainerItemLink(bag, slot) then free = free + 1 end
        end
    end
    return free
end

-- Worst equipped durability as a percentage (100 when nothing is damaged).
function Vendor.durability_pct()
    if not GetInventoryItemDurability then return 100 end
    local worst = 100
    for slot = 1, 18 do
        local ok, cur, mx = pcall(GetInventoryItemDurability, slot)
        if ok and cur and mx and mx > 0 then
            local p = cur / mx * 100
            if p < worst then worst = p end
        end
    end
    return worst
end

-- Is a bag slot safe to sell? Returns true + reason, or false + why not.
-- Everything here is a refusal by default; an item must positively qualify.
function Vendor.is_junk(bag, slot, c)
    c = c or Vendor.cfg()
    if not GetContainerItemLink then return false, "no_api" end
    local link = GetContainerItemLink(bag, slot)
    if not link then return false, "empty" end
    local id = tonumber(link:match("item:(%d+)"))

    -- Never sell a quest item, whatever its quality says.
    if GetContainerItemQuestInfo then
        local ok, isQuest = pcall(GetContainerItemQuestInfo, bag, slot)
        if ok and isQuest then return false, "quest_item" end
    end
    if id and c.keep_ids[id] then return false, "keep_list" end
    if id and c.junk_ids[id] then return true, "junk_list" end

    local name, _, quality, _, _, itemType, _, _, _, _, sell
    if GetItemInfo then
        local ok, a, b, q, d2, e, f, g, h, i2, j, k = pcall(GetItemInfo, link)
        if ok then name, quality, itemType, sell = a, q, f, k end
    end
    if quality == nil then return false, "unknown_quality" end   -- fail closed
    if quality > (c.max_quality or 0) then return false, "too_good" end
    if itemType == "Quest" then return false, "quest_type" end
    -- No vendor price means it cannot be sold (and may be a token/currency).
    if sell ~= nil and sell <= 0 then return false, "worthless" end
    return true, "grey"
end

-- Every sellable slot, capped.
function Vendor.junk_list()
    local c = Vendor.cfg()
    local out = {}
    if not GetContainerNumSlots then return out end
    for bag = 0, 4 do
        local n = GetContainerNumSlots(bag) or 0
        for slot = 1, n do
            if #out >= (c.max_sales or 24) then return out end
            local ok = Vendor.is_junk(bag, slot, c)
            if ok then
                local link = GetContainerItemLink(bag, slot)
                out[#out + 1] = { bag = bag, slot = slot, link = link }
            end
        end
    end
    return out
end

-- ---- merchant interaction ------------------------------------------------

function Vendor.at_merchant()
    if MerchantFrame and MerchantFrame.IsShown then
        local ok, shown = pcall(MerchantFrame.IsShown, MerchantFrame)
        return ok and shown and true or false
    end
    return false
end

-- Sell the junk. Only ever called with the merchant window open, because
-- UseContainerItem outside a merchant USES the item instead of selling it -
-- which would happily eat our food or fire off a quest item.
function Vendor.sell_junk()
    if not Vendor.at_merchant() then return 0, "no_merchant" end
    local c = Vendor.cfg()
    if not c.sell_junk then return 0, "disabled" end
    local list = Vendor.junk_list()
    local n = 0
    for _, it in ipairs(list) do
        local sold = false
        local A = RaijinLab and RaijinLab.Actions
        if A and A.UseContainerItem then
            sold = pcall(A.UseContainerItem, it.bag, it.slot)
        end
        if not sold and UseContainerItem then
            sold = pcall(UseContainerItem, it.bag, it.slot)
        end
        if sold then n = n + 1 end
    end
    Vendor._sold = (Vendor._sold or 0) + n
    return n
end

-- Repair everything, if this merchant can and we can afford it while keeping a
-- reserve. Returns cost or 0.
function Vendor.repair()
    if not Vendor.at_merchant() then return 0, "no_merchant" end
    local c = Vendor.cfg()
    if not c.repair then return 0, "disabled" end
    if not (CanMerchantRepair and CanMerchantRepair()) then return 0, "cannot_repair" end
    local cost = 0
    if GetRepairAllCost then
        local ok, v = pcall(GetRepairAllCost)
        if ok then cost = tonumber(v) or 0 end
    end
    if cost <= 0 then return 0, "nothing_to_repair" end
    local money = (GetMoney and GetMoney()) or 0
    if money < cost then return 0, "too_poor" end
    -- Repairing into destitution strands us with no way to buy food.
    if (money - cost) < (c.repair_reserve or 0) and cost > money * 0.5 then
        return 0, "would_strand"
    end
    if RepairAllItems then
        local ok = pcall(RepairAllItems)
        if ok then return cost end
    end
    return 0, "no_repair_api"
end

-- How many of an item we already carry.
function Vendor.count_item(name)
    if GetItemCount and name then
        local ok, n = pcall(GetItemCount, name)
        if ok then return tonumber(n) or 0 end
    end
    return 0
end

-- Buy consumables up to target. We only buy things this merchant sells that our
-- own Rest module would actually classify as food or drink, so we never stock up
-- on something unusable.
function Vendor.restock()
    if not Vendor.at_merchant() then return 0, "no_merchant" end
    local c = Vendor.cfg()
    if not c.restock then return 0, "disabled" end
    if not (GetMerchantNumItems and GetMerchantItemInfo and BuyMerchantItem) then
        return 0, "no_merchant_api"
    end
    local R = RaijinLab and RaijinLab.Rest
    local have = R and R.find_consumables() or { food = {}, drink = {} }
    local need = {
        food = max(0, (c.food_target or 0) - #have.food),
        drink = max(0, (c.drink_target or 0) - #have.drink),
    }
    if need.food <= 0 and need.drink <= 0 then return 0, "stocked" end

    local money = (GetMoney and GetMoney()) or 0
    local bought = 0
    local n = GetMerchantNumItems() or 0
    for i = 1, n do
        local ok, name, _, price, quantity, numAvailable, isPurchasable = pcall(GetMerchantItemInfo, i)
        if ok and name and isPurchasable ~= false then
            local kind = nil
            if R and R.classify then
                -- Ask the merchant item's link for its real type where possible.
                local link = GetMerchantItemLink and GetMerchantItemLink(i)
                local itemType, itemSubType
                if link and GetItemInfo then
                    local ok2, _, _, _, _, _, f, g = pcall(GetItemInfo, link)
                    if ok2 then itemType, itemSubType = f, g end
                end
                kind = R.classify({ name = name, itemType = itemType, itemSubType = itemSubType })
            end
            if kind and (need[kind] or 0) > 0 then
                local want = need[kind]
                local cost = (tonumber(price) or 0) * want
                if cost > 0 and cost <= money then
                    local done = pcall(BuyMerchantItem, i, want)
                    if done then
                        money = money - cost
                        need[kind] = 0
                        bought = bought + want
                    end
                end
            end
        end
    end
    return bought
end

-- Everything we do at a merchant, in the order that matters: sell FIRST (it makes
-- room and money), then repair, then spend what is left on food.
function Vendor.do_business()
    if not Vendor.at_merchant() then return nil end
    local sold = Vendor.sell_junk()
    local cost = Vendor.repair()
    local bought = Vendor.restock()
    local Tel = RaijinLab and RaijinLab.Telemetry
    if Tel then Tel.info("vendor", "business", { sold = sold or 0,
        repair_cost = cost or 0, bought = bought or 0,
        free = Vendor.free_slots(), dur = math.floor(Vendor.durability_pct()) }) end
    return string.format("vendor:sold %d, repaired %s, bought %d",
        sold or 0, (cost or 0) > 0 and "yes" or "no", bought or 0)
end

-- ---- do we need a trip? --------------------------------------------------

-- Returns need(bool), reason, urgency(0..1).
-- Three-valued: yes carries { why, urgency }; no means no trip needed.
function Vendor.needs_vendor_k()
    local Kn = RaijinLab and RaijinLab.Know
    local c = Vendor.cfg()
    local free = Vendor.free_slots()
    if free <= (c.min_free_slots or 4) then
        local urg = 1 - (free / max(1, c.min_free_slots or 4))
        if Kn then return Kn.yes({ why = "bags_full", urgency = urg }, "bags_full") end
        return true, "bags_full", urg
    end
    local dur = Vendor.durability_pct()
    if dur <= (c.low_durability or 35) then
        local urg = 1 - (dur / 100)
        if Kn then return Kn.yes({ why = "durability", urgency = urg }, "durability") end
        return true, "durability", urg
    end
    local R = RaijinLab and RaijinLab.Rest
    if R and c.restock then
        local have = R.find_consumables()
        if #have.food == 0 then
            if Kn then return Kn.yes({ why = "out_of_food", urgency = 0.7 }, "out_of_food") end
            return true, "out_of_food", 0.7
        end
        if R.is_mana_user() and #have.drink == 0 then
            if Kn then return Kn.yes({ why = "out_of_drink", urgency = 0.7 }, "out_of_drink") end
            return true, "out_of_drink", 0.7
        end
    end
    if Kn then return Kn.no("stocked") end
    return false, nil, 0
end

function Vendor.needs_vendor()
    local k, why, urg = Vendor.needs_vendor_k()
    if type(k) == "table" and k.state then
        if k.state == "yes" then
            local v = k.value or {}
            return true, v.why or k.why, v.urgency or 0.5
        end
        return false, nil, 0
    end
    -- No Know module: needs_vendor_k already returned bool, why, urg.
    return k, why, urg
end

-- Do we have a PLACE to satisfy a vendor need? (open merchant or remembered POI)
function Vendor.has_plan_k(why)
    local Kn = RaijinLab and RaijinLab.Know
    if Vendor.at_merchant and Vendor.at_merchant() then
        if Kn then return Kn.yes(true, "at_merchant") end
        return true
    end
    local R = RaijinLab
    local P = R and R.POI
    if not (P and P.nearest and R.ObjectPosition) then
        if Kn then return Kn.unknown("no_poi") end
        return nil
    end
    local px, py, pz = R:ObjectPosition("player")
    if not px then
        if Kn then return Kn.unknown("no_pos") end
        return nil
    end
    local kind = (why == "durability") and "repair" or "vendor"
    if P.nearest(kind, px, py, pz) or P.nearest("vendor", px, py, pz) then
        if Kn then return Kn.yes(true, "poi:" .. kind) end
        return true
    end
    if Kn then return Kn.no("no_vendor_known") end
    return false
end

function Vendor.stats()
    local need, why = Vendor.needs_vendor()
    return { free_slots = Vendor.free_slots(), durability = Vendor.durability_pct(),
             junk = #Vendor.junk_list(), at_merchant = Vendor.at_merchant(),
             needs_trip = need, reason = why, sold_total = Vendor._sold or 0 }
end

if RaijinLab then RaijinLab.Vendor = Vendor end
return Vendor
