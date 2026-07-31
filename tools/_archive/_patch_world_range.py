from pathlib import Path

p = Path(r"C:\Ascension\Workspace\RaijinLab\addon\core\World.lua")
text = p.read_text(encoding="utf-8")
start = text.find("        -- Range snapshot")
end = text.find("    -- Protection analysis (immunity / absorb / reflect) for rotation spells.")
if start < 0 or end < 0 or end <= start:
    raise SystemExit(f"markers not found start={start} end={end}")

new = r"""        -- Range snapshot (Executor fill_live overwrites each tick).
        -- Self-AoE (maxR 0 / Whirlwind): never trust IsSpellInRange (returns 0
        -- falsely with a target and used to mark WW as targeted+OOR forever).
        local inr, targeted = true, false
        local minR, maxR = 0, 0
        local sname = nil
        if GetSpellInfo then
            local n, _, _, _, _, _, _, mn, mx = GetSpellInfo(rid)
            sname = n
            minR, maxR = tonumber(mn) or 0, tonumber(mx) or 0
        end
        local self_aoe = (maxR <= 0)
        if sname then
            local nl = string.lower(sname)
            if nl:find("whirlwind", 1, true) or nl:find("thunder clap", 1, true)
                or nl:find("arcane explosion", 1, true) then
                self_aoe = true
            end
        end
        if ctx.target_exists then
            if self_aoe then
                targeted = false
                inr = true -- refined after enemy scan / Executor live check
            else
                local client_r = nil
                if IsSpellInRange then
                    if sname then client_r = IsSpellInRange(sname, "target")
                    else client_r = IsSpellInRange(rid, "target") end
                    if client_r ~= nil then targeted = true end
                    if client_r == 0 then inr = false end
                end
                if client_r ~= 0 and client_r ~= 1 then
                    if maxR > 0 then
                        targeted = true
                        if ctx.target_distance_precise then
                            local d = tonumber(ctx.target_distance)
                            if d and d < 900 then
                                if d > maxR then inr = false end
                                if minR > 0 and d < minR then inr = false end
                            end
                        else
                            local lo = tonumber(ctx.target_distance_lo)
                            local hi = tonumber(ctx.target_distance_hi)
                            if lo and lo > maxR then
                                inr = false
                            elseif hi and hi <= maxR and (minR <= 0 or (lo and lo >= minR)) then
                                inr = true
                            else
                                inr = false
                            end
                        end
                    end
                end
            end
        elseif maxR > 0 and not self_aoe then
            targeted = true
            inr = false
        end
        ctx.spell_in_range[id] = inr
        ctx.spell_in_range[tostring(id)] = inr
        ctx.spell_targeted[id] = targeted
        ctx.spell_targeted[tostring(id)] = targeted
    end

    -- Nearby enemies. CENTER yards for enemies_in_range / WW pack.
    local enemy_list = {}
    local e8, e10, e40, ep = 0, 0, 0, 0
    local nearest_ep, nearest_e, nearest_center = 999, 999, 999
    local nearest_precise = false
    if not opts.skip_enemies then
        local enemies = World.collect_nearby_enemies(40)
        for i = 1, #enemies do
            local e = enemies[i]
            enemy_list[#enemy_list + 1] = e
            local c = tonumber(e.dist_center or e.dist) or 999
            if e.precise and c < nearest_center then
                nearest_center = c
                nearest_e = c
                nearest_precise = true
            end
            if dist_within(e, 8) then e8 = e8 + 1 end
            if dist_within(e, 10) then e10 = e10 + 1 end
            if dist_within(e, 40) then e40 = e40 + 1 end
        end
        for _, u in ipairs(World.collect_units_from_tokens()) do
            if u.is_enemy and not u.is_dead and u.is_player then
                ep = ep + 1
                local d = tonumber(u.dist_edge or u.dist) or 999
                if d < nearest_ep then nearest_ep = d end
            end
        end
    end
    ctx.enemy_list = enemy_list
    ctx.enemy_distances = {}
    for i = 1, #enemy_list do
        ctx.enemy_distances[i] = enemy_list[i].dist_center or enemy_list[i].dist
    end
    ctx.enemies_in_range = e8
    ctx.enemies_in_8 = e8
    ctx.enemies_in_10 = e10
    ctx.enemies_in_40 = e40
    ctx.enemy_players_in_range = ep
    ctx.nearest_enemy_player_dist = nearest_ep
    ctx.nearest_enemy_dist = nearest_e
    ctx.nearest_enemy_center = nearest_center
    ctx.nearest_enemy_precise = nearest_precise
    function ctx.count_enemies_within(range)
        range = tonumber(range) or 8
        local n = 0
        for i = 1, #enemy_list do
            if dist_within(enemy_list[i], range) then n = n + 1 end
        end
        return n
    end
    -- Refine self/AOE: nearest enemy CENTER <= 8 (or target center).
    if not opts.skip_enemies then
        for _, id in ipairs(spell_ids) do
            id = tonumber(id) or 0
            if id > 0 and ctx.spell_targeted[id] == false then
                local maxR = 0
                local nm = nil
                if GetSpellInfo then
                    local n, _, _, _, _, _, _, _, mx = GetSpellInfo(id)
                    nm, maxR = n, tonumber(mx) or 0
                end
                local is_aoe = (maxR <= 0)
                if nm and string.lower(nm):find("whirlwind", 1, true) then
                    is_aoe = true
                end
                if is_aoe then
                    local band = 8
                    local inr = false
                    if nearest_precise and nearest_center <= band then
                        inr = true
                    elseif ctx.target_distance_precise then
                        local tc = tonumber(ctx.target_distance_center)
                        if tc and tc <= band then inr = true end
                    end
                    ctx.spell_in_range[id] = inr
                    ctx.spell_in_range[tostring(id)] = inr
                end
            end
        end
    end

"""

p.write_text(text[:start] + new + text[end:], encoding="utf-8")
print("OK", end - start, "->", len(new))
