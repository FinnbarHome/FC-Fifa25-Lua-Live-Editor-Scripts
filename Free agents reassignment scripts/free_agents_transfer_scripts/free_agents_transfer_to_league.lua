--------------------------------------------------------------------------------
-- Lua Script for Multi-League Player Transfers - Made By The Mayo Man (themayonnaiseman)
-- with Position IDs Mapping, Priority Queue, and League-Specific Constraints
--------------------------------------------------------------------------------
require 'imports/career_mode/helpers'
require 'imports/other/helpers'

local players_table_global   = LE.db:GetTable("players")
local team_player_links_global = LE.db:GetTable("teamplayerlinks")
local formations_table_global = LE.db:GetTable("formations")
local league_team_links_global = LE.db:GetTable("leagueteamlinks")

--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------
local config = {
    position_ids = {
        GK = {0}, CB = {5, 1, 4, 6}, RB = {3, 2}, LB = {7, 8},
        CDM = {10, 9, 11}, RM = {12}, CM = {14, 13, 15}, LM = {16},
        CAM = {18, 17, 19}, ST = {25, 20, 21, 22, 24, 26},
        RW = {23}, LW = {27}
    },
    alternative_positions = {
        RW = {"RM"}, 
        LW = {"LM"}, 
        ST = {"RW", "LW"},
        CDM = {"CM"}, 
        CAM = {"RW", "LW"}
    },
    positions_to_roles = {
        GK = {1, 2, 0}, -- Eg: 1,2,0 Goalkeeper, Sweeperkeeper, None
        CB = {11, 12, 13}, -- Eg: 11,12,13 Defender, Stopper, Ball-playing Defender
        RB = {3, 4, 5}, -- Eg: 3,4,5 Fullback, Falseback, Wingback
        LB = {7, 8, 9}, -- Eg; 7,8,9 Fullback, Falseback, Wingback
        CDM = {14, 15, 16}, -- Eg: 14,15,16 Holding, Centre-half, Deep-lying Playmaker
        RM = {23, 24, 26}, -- Eg: 23,24,26 Winger, Wide Midfielder, Inside Forward
        CM = {18, 19, 20}, -- Eg: 18,19,20 Box-to-box, Holding, Deep-lying Playmaker
        LM = {27, 28, 30}, -- Eg: 27,28,30 Winger, Wide Midfielder, Inside Forward
        CAM = {31, 32, 33}, -- Eg: 31,32,33 Playmaker, Shadow Striker, Half-Winger
        ST = {41, 42, 43}, -- Eg: 41,42,43 Advanced Forward, Poacher, False Nine 
        RW = {35, 36, 37}, -- Eg: 35,36,37 Winger, Inside Forward, Wide Playmaker
        LW = {38, 39, 40} -- Eg: 38,39,40 Winger, Inside Forward, Wide Playmaker
    },
    age_constraints = {min = 16, max = 32},
    squad_size = 52,
    target_leagues = {61,60,14,13,16,17,19,20,2076,31,32,10,83,53,54,353,351,80,4,2012,1,2149,41,66,308,65,330,350,50,56,189,68,39}, -- Eg: 61 = EFL League Two, 60 = EFL League One, 14 = EFL Championship, premier league, lig 1, lig 2, Bund, bund 2, bund 3, erd, k league, Liga 1, liga 2, argentinan prem, A league, O.Bund, 1A pro l, CSL, 3F Sup L, ISL, Eliteserien, PKO BP Eks, liga port, SSE Airtricity, Superliga, Saudi L, Scot prem, Allsven, CSSL, super lig, MLS
    excluded_teams = { [1947] = true },         -- e.g. { [1234] = true }
    transfer = {
        sum = 0,
        wage = 600,
        contract_length = 24,
        release_clause = -1,
        from_team_id = 111592
    },
    lower_bound_minus = 2, -- This is the range that the script subtracts from the lower bounds of the team's ratings.
    upper_bound_plus = 3, -- This is the range that the script adds to the upper bounds of the team's ratings.
    youth_player = {
        max_age = 23,        -- Maximum age for youth players
        potential_bonus = 5, -- Potential must be >= team median + this value (when use_median=true)
        use_median = true,   -- true: use team median + bonus; false: use team 75th percentile
        -- Hard cap on the median+bonus threshold: if a team's (median + bonus) exceeds this,
        -- the requirement is clamped to this value so high-potential youth (>= cap) are
        -- always considered, even for stacked elite squads.
        potential_cap = 85
    },

    -- Progressive rating-band widening: if no candidate fits the initial band, widen by
    -- widen_step_size on each side up to max_widen_steps times before giving up on a position.
    max_widen_steps = 2,
    widen_step_size = 2,

    -- Order of strategies tried when filling a slot. Each entry names one step:
    --   "exact"      - exact position in the initial rating band
    --   "alt"        - alternative positions (see alternative_positions) in the initial band
    --   "widen_one"  - exact position, widened by one widen_step_size on each side
    --   "youth"      - high-potential youth prospect (ignores rating band, uses capped median+bonus)
    --   "widen_full" - exact position, progressively widened steps 2..max_widen_steps
    -- Unknown/duplicate entries are skipped; omitted strategies are simply not tried.
    search_order = { "exact", "alt", "widen_one", "youth", "widen_full" },

    -- Extra priority weight for holes at critical positions (GK in particular).
    critical_position_bonus = { GK = 50 },

    -- Re-sort the need queue every N successful transfers so recently-filled teams
    -- lose priority and teams that haven't been touched get a fresh look.
    requeue_every_n_transfers = 50
}

-- Pre-compute position mappings for faster lookups
local position_name_by_id = {}
local position_id_by_name = {}
for name, ids in pairs(config.position_ids) do
    position_id_by_name[name] = ids[1]
    for _, pid in ipairs(ids) do
        position_name_by_id[pid] = name
    end
end

--------------------------------------------------------------------------------
-- HELPER METHODS
--------------------------------------------------------------------------------
local function get_position_id_from_position_name(req)
    return position_id_by_name[req] or -1
end

local function get_position_name_from_position_id(pid)
    return position_name_by_id[pid] or ("UnknownPos(".. pid ..")")
end

local function calculate_player_age(birth_date)
    if not birth_date or birth_date <= 0 then return 20 end
    local c = GetCurrentDate()
    local d = DATE:new(); d:FromGregorianDays(birth_date)
    local age = c.year - d.year
    if c.month < d.month or (c.month==d.month and c.day<d.day) then
        age = age - 1
    end
    return age
end

-- One-shot scan of teamplayerlinks: team_id -> { player_id, ... }
-- All per-team lookups (size, bounds, position counts, free-agent pool) reuse this map
-- instead of re-scanning the whole table per team.
local team_players_map = nil
local function build_team_players_map()
    if team_players_map then return team_players_map end
    team_players_map = {}
    if not team_player_links_global then return team_players_map end
    local rec = team_player_links_global:GetFirstRecord()
    while rec > 0 do
        local t_id = team_player_links_global:GetRecordFieldValue(rec, "teamid")
        local p_id = team_player_links_global:GetRecordFieldValue(rec, "playerid")
        if t_id and p_id then
            local bucket = team_players_map[t_id]
            if not bucket then
                bucket = {}
                team_players_map[t_id] = bucket
            end
            bucket[#bucket + 1] = p_id
        end
        rec = team_player_links_global:GetNextValidRecord()
    end
    return team_players_map
end

local team_size_cache = {}
local function get_team_size(team_id)
    if team_size_cache[team_id] then return team_size_cache[team_id] end
    build_team_players_map()
    local list = team_players_map[team_id]
    local count = list and #list or 0
    team_size_cache[team_id] = count
    return count
end

-- Pre-index players by ID for faster lookups
local function build_player_data(players_table)
    if not players_table then
        LOGGER:LogWarning("Players table not found. Could not build player data.")
        return {}
    end
    local player_data = {}

    local rec = players_table:GetFirstRecord()
    while rec > 0 do
        local pid = players_table:GetRecordFieldValue(rec, "playerid")
        if pid then
            local birthdate = players_table:GetRecordFieldValue(rec, "birthdate")
            local pref_pos  = players_table:GetRecordFieldValue(rec, "preferredposition1")
            player_data[pid] = {
                overall = players_table:GetRecordFieldValue(rec, "overallrating") or 0,
                potential = players_table:GetRecordFieldValue(rec, "potential") or 0,
                birthdate = birthdate,
                preferredposition1 = pref_pos,
                positionName = pref_pos and get_position_name_from_position_id(pref_pos) or nil,
                age = calculate_player_age(birthdate)
            }
        end
        rec = players_table:GetNextValidRecord()
    end

    return player_data
end

local team_positions_cache = {}
local function count_positions_in_team(team_id, pdata_by_id)
    if team_positions_cache[team_id] then return team_positions_cache[team_id] end
    build_team_players_map()
    local counts = {}
    local list = team_players_map[team_id]
    if list then
        for _, p_id in ipairs(list) do
            local pdata = pdata_by_id[p_id]
            if pdata and pdata.preferredposition1 then
                local name = get_position_name_from_position_id(pdata.preferredposition1)
                counts[name] = (counts[name] or 0) + 1
            end
        end
    end
    team_positions_cache[team_id] = counts
    return counts
end

local team_bounds_cache = {}
local function get_team_lower_upper_bounds(team_id, pdata_by_id, lower_bound_minus, upper_bound_plus)
    if team_bounds_cache[team_id] then
        return team_bounds_cache[team_id][1], team_bounds_cache[team_id][2], team_bounds_cache[team_id][3]
    end

    build_team_players_map()
    local ratings = {}
    local list = team_players_map[team_id]
    if list then
        for _, p_id in ipairs(list) do
            local pdata = pdata_by_id[p_id]
            if pdata then ratings[#ratings + 1] = pdata.overall end
        end
    end
    if #ratings == 0 then
        LOGGER:LogWarning(string.format("No ratings found for team %d.", team_id))
        return nil, nil
    end

    table.sort(ratings)
    local n = #ratings
    local i50, i75 = math.ceil(0.5 * n), math.ceil(0.75 * n)
    local p50, p75 = math.floor(ratings[i50] + 0.5), math.floor(ratings[i75] + 0.5)
    local lb, ub = p50 - lower_bound_minus, p75 + upper_bound_plus

    team_bounds_cache[team_id] = {lb, ub, p50}
    return lb, ub, p50
end

local player_data = build_player_data(players_table_global)

-- Map teams to leagues for faster lookups
local league_teams_map = {}
local function build_league_teams_map()
    if next(league_teams_map) ~= nil then
        return league_teams_map
    end
    
    local record = league_team_links_global:GetFirstRecord()
    while record>0 do
        local league_id_field = league_team_links_global:GetRecordFieldValue(record,"leagueid")
        local team_id_field   = league_team_links_global:GetRecordFieldValue(record,"teamid")
        if league_id_field and team_id_field and not config.excluded_teams[team_id_field] then
            league_teams_map[league_id_field] = league_teams_map[league_id_field] or {}
            league_teams_map[league_id_field][#league_teams_map[league_id_field]+1] = team_id_field
        end
        record= league_team_links_global:GetNextValidRecord()
    end
    
    return league_teams_map
end

--------------------------------------------------------------------------------
-- FORMATION LOGIC: Retrieve each team's formation positions
--------------------------------------------------------------------------------
local formation_cache = {}
local function get_formation_positions(target_team_id)
    if formation_cache[target_team_id] then
        return formation_cache[target_team_id]
    end
    
    if not formations_table_global then
        return {}
    end

    local record = formations_table_global:GetFirstRecord()
    while record > 0 do
        local team_id_current = formations_table_global:GetRecordFieldValue(record, "teamid")
        if team_id_current == target_team_id then
            local positions = {}
            for i=0,10 do
                local field_name = ("position%d"):format(i)
                local position_id= formations_table_global:GetRecordFieldValue(record, field_name) or 0
                local position_name= get_position_name_from_position_id(position_id)
                positions[#positions+1] = position_name
            end
            formation_cache[target_team_id] = positions
            return positions
        end
        record = formations_table_global:GetNextValidRecord()
    end
    
    formation_cache[target_team_id] = {}
    return {}
end

--------------------------------------------------------------------------------
-- TEAM NEEDS - Attempts to have 2 for every position in team's formation
--------------------------------------------------------------------------------
local team_needs_cache = {}
-- Returns: needed (array of pos names, one entry per missing slot),
--          shortage_by_pos (map of pos -> current shortage),
--          total_shortage (number)
local function compute_team_needs(team_id)
    if team_needs_cache[team_id] then
        local cached = team_needs_cache[team_id]
        return cached.needed, cached.shortage_by_pos, cached.total_shortage
    end

    local formation_positions = get_formation_positions(team_id)
    if #formation_positions == 0 then
        team_needs_cache[team_id] = {needed = {}, shortage_by_pos = {}, total_shortage = 0}
        return {}, {}, 0
    end

    local demand = {}
    for _, pos in ipairs(formation_positions) do
        demand[pos] = (demand[pos] or 0) + 1
    end
    for pos in pairs(demand) do
        demand[pos] = demand[pos] * 2
    end

    local current_positions = count_positions_in_team(team_id, player_data)

    local needed = {}
    local shortage_by_pos = {}
    local total_shortage = 0
    for pos, required_count in pairs(demand) do
        local existing = current_positions[pos] or 0
        local missing = required_count - existing
        if missing > 0 then
            shortage_by_pos[pos] = missing
            total_shortage = total_shortage + missing
            for _ = 1, missing do
                needed[#needed + 1] = pos
            end
        end
    end

    team_needs_cache[team_id] = {
        needed = needed,
        shortage_by_pos = shortage_by_pos,
        total_shortage = total_shortage
    }
    return needed, shortage_by_pos, total_shortage
end

--------------------------------------------------------------------------------
-- BUILD A LIST OF TEAMS + NEEDS => PRIORITY QUEUE
--------------------------------------------------------------------------------
local function compute_entry_weight(shortage_for_pos, total_shortage, pos_name, squad_size)
    local crit_bonus = (config.critical_position_bonus and config.critical_position_bonus[pos_name]) or 0
    -- Per-position shortage dominates (biggest hole goes first), team-wide shortage
    -- is a secondary factor (smaller/emptier teams float up), and squad_size breaks
    -- remaining ties. Negating squad_size keeps smaller teams with higher weight.
    return (shortage_for_pos or 0) * 100
        + (total_shortage or 0)
        + crit_bonus
        - (squad_size or 0) * 0.01
end

local function get_all_teams_and_needs()
    if not league_team_links_global then return {} end

    local all_entries = {}
    local league_teams = build_league_teams_map()
    local teams_considered, teams_with_needs, teams_full = 0, 0, 0

    for _, league_id in ipairs(config.target_leagues) do
        local teams_in_league = league_teams[league_id] or {}
        for _, team_id in ipairs(teams_in_league) do
            teams_considered = teams_considered + 1
            local size = get_team_size(team_id)
            if size < config.squad_size then
                local team_needs, shortage_by_pos, total_shortage = compute_team_needs(team_id)
                if #team_needs > 0 then teams_with_needs = teams_with_needs + 1 end
                for _, pos_name in ipairs(team_needs) do
                    local weight = compute_entry_weight(
                        shortage_by_pos[pos_name], total_shortage, pos_name, size
                    )
                    all_entries[#all_entries + 1] = {
                        team_id = team_id,
                        position = pos_name,
                        weight = weight,
                        shortage = shortage_by_pos[pos_name] or 0
                    }
                end
            else
                teams_full = teams_full + 1
            end
        end
    end

    LOGGER:LogInfo(string.format(
        "Need queue built: %d teams considered, %d with needs, %d already full -> %d pending slots.",
        teams_considered, teams_with_needs, teams_full, #all_entries
    ))

    table.sort(all_entries, function(a, b) return a.weight > b.weight end)
    return all_entries
end

--------------------------------------------------------------------------------
-- BUILD LIST OF ELIGIBLE FREE AGENTS FOR EACH LEAGUE
--------------------------------------------------------------------------------
local function build_free_agents()
    if not player_data then return {}, {} end

    build_team_players_map()
    local pool_ids = team_players_map[config.transfer.from_team_id] or {}

    local results = {}
    for _, p_id in ipairs(pool_ids) do
        local pdata = player_data[p_id]
        if pdata then
            local age = pdata.age or calculate_player_age(pdata.birthdate)
            if age >= config.age_constraints.min and age <= config.age_constraints.max then
                results[#results + 1] = {
                    playerid = p_id,
                    overall = pdata.overall,
                    potential = pdata.potential,
                    positionName = pdata.positionName,
                    age = age
                }
            end
        end
    end

    -- Shuffle to avoid ordering bias; rebuild position index after the shuffle
    for i = #results, 2, -1 do
        local j = math.random(i)
        results[i], results[j] = results[j], results[i]
    end

    local position_index = {}
    for i, player in ipairs(results) do
        local pos = player.positionName
        if pos then
            position_index[pos] = position_index[pos] or {}
            position_index[pos][#position_index[pos] + 1] = i
        end
    end

    return results, position_index
end

--------------------------------------------------------------------------------
-- RUN STATS (for end-of-run summary)
--------------------------------------------------------------------------------
local stats = {
    transfers_total    = 0,
    transfers_normal   = 0,
    transfers_alt      = 0,
    transfers_youth    = 0,
    transfers_widened  = 0,
    slots_abandoned    = 0,
    slots_unfilled     = 0,
    slots_failed       = 0,
    teams_full_skipped = 0,
    teams_no_stats     = 0
}

--------------------------------------------------------------------------------
-- ACTUAL TRANSFER MECHANISM
--------------------------------------------------------------------------------
-- Find the highest-potential youth free agent at `position_required` (or any
-- alternative position) who meets the min_potential_required threshold.
-- Returns (index, used_alternative, alt_position_name_or_nil).
local function find_youth_potential_candidate(free_agents_list, position_index, position_required, min_potential_required)
    local max_age = config.youth_player.max_age

    local function best_at(pos)
        local best_idx, best_pot = nil, -1
        local bucket = position_index[pos]
        if not bucket then return nil end
        for _, idx in ipairs(bucket) do
            local fa = free_agents_list[idx]
            if fa and not fa.transferred
                and fa.age <= max_age and fa.potential >= min_potential_required
                and fa.potential > best_pot then
                best_idx, best_pot = idx, fa.potential
            end
        end
        return best_idx
    end

    local idx = best_at(position_required)
    if idx then return idx, false, nil end

    local alternatives = config.alternative_positions[position_required]
    if alternatives then
        for _, alt_position in ipairs(alternatives) do
            local alt_idx = best_at(alt_position)
            if alt_idx then return alt_idx, true, alt_position end
        end
    end

    return nil, false, nil
end

local function handle_player_transfer(player_id, team_id, position, free_agents_list, candidate_index, used_alternative, alternative_position_used, is_youth_prospect)
    local player_name = GetPlayerName(player_id)

    -- Alt-position conversion: do it before the transfer and verify rating still fits
    -- the (widened) band. If it doesn't, revert and abandon this candidate so the slot
    -- stays open for a real fit rather than silently filling it out-of-position.
    local abandoned_due_to_revert = false
    if used_alternative then
        local player_rec, original_position_id = nil, -1
        local rec = players_table_global:GetFirstRecord()
        while rec > 0 do
            if players_table_global:GetRecordFieldValue(rec, "playerid") == player_id then
                player_rec = rec
                original_position_id = players_table_global:GetRecordFieldValue(rec, "preferredposition1")
                break
            end
            rec = players_table_global:GetNextValidRecord()
        end

        if player_rec then
            local new_pos_id = get_position_id_from_position_name(position)
            players_table_global:SetRecordFieldValue(player_rec, "preferredposition1", new_pos_id)

            local r1, r2, r3 = table.unpack(config.positions_to_roles[position] or {0, 0, 0})
            if new_pos_id == 0 then r3 = 0 end
            players_table_global:SetRecordFieldValue(player_rec, "role1", r1)
            players_table_global:SetRecordFieldValue(player_rec, "role2", r2)
            players_table_global:SetRecordFieldValue(player_rec, "role3", r3)

            -- Verify rating still fits the team's widened band; if not, revert and abort
            -- so the caller can try the next strategy/candidate for this slot.
            local max_widen = (config.max_widen_steps or 0) * (config.widen_step_size or 0)
            local lower_bound = get_team_lower_upper_bounds(
                team_id, player_data,
                config.lower_bound_minus + max_widen,
                config.upper_bound_plus + max_widen
            )
            local player_rating = players_table_global:GetRecordFieldValue(player_rec, "overallrating")
                          or players_table_global:GetRecordFieldValue(player_rec, "overall") or 0

            if lower_bound and player_rating < lower_bound then
                LOGGER:LogInfo(string.format(
                    "Revert alt-conv: %s OVR %d < widened LB %d for %s -> %s. Abandoning.",
                    player_name, player_rating, lower_bound, alternative_position_used, position
                ))

                local original_position_name = get_position_name_from_position_id(original_position_id)
                if original_position_name and original_position_id and original_position_id >= 0 then
                    players_table_global:SetRecordFieldValue(player_rec, "preferredposition1", original_position_id)
                    local roles = config.positions_to_roles[original_position_name]
                    if roles then
                        players_table_global:SetRecordFieldValue(player_rec, "role1", roles[1])
                        players_table_global:SetRecordFieldValue(player_rec, "role2", roles[2])
                        players_table_global:SetRecordFieldValue(player_rec, "role3", roles[3])
                    end
                end
                abandoned_due_to_revert = true
            end
        else
            LOGGER:LogWarning(string.format("Player %d record not found. Could not update position.", player_id))
        end
    end

    if abandoned_due_to_revert then
        stats.slots_abandoned = stats.slots_abandoned + 1
        return false, true -- not-transferred, flagged so caller can skip this candidate
    end

    local ok, error_message = pcall(function()
        if IsPlayerPresigned(player_id) then DeletePresignedContract(player_id) end
        if IsPlayerLoanedOut(player_id) then TerminateLoan(player_id) end
        TransferPlayer(player_id, team_id, config.transfer.sum, config.transfer.wage,
            config.transfer.contract_length, config.transfer.from_team_id, config.transfer.release_clause)
    end)

    if ok then
        local kind = "normal"
        if used_alternative then
            kind = "alt"
            stats.transfers_alt = stats.transfers_alt + 1
        elseif is_youth_prospect then
            kind = "youth"
            stats.transfers_youth = stats.transfers_youth + 1
        else
            stats.transfers_normal = stats.transfers_normal + 1
        end
        stats.transfers_total = stats.transfers_total + 1

        LOGGER:LogInfo(string.format(
            "Transferred %s (%d) -> %s (%d) as %s for %s.",
            player_name, player_id, GetTeamName(team_id), team_id, kind, position
        ))

        team_size_cache[team_id] = (team_size_cache[team_id] or 0) + 1
        -- Invalidate per-team caches so subsequent picks see the updated roster
        -- (rating bounds drift as weaker teams fill up; needs/positions change too).
        team_bounds_cache[team_id] = nil
        team_positions_cache[team_id] = nil
        team_needs_cache[team_id] = nil

        -- Keep the team_players_map in sync with the DB so downstream lazy
        -- rebuilds (e.g. position counts / bounds after invalidation) are correct.
        if team_players_map then
            local bucket = team_players_map[team_id]
            if not bucket then
                bucket = {}
                team_players_map[team_id] = bucket
            end
            bucket[#bucket + 1] = player_id
            local src = team_players_map[config.transfer.from_team_id]
            if src then
                for i = 1, #src do
                    if src[i] == player_id then
                        src[i] = src[#src]
                        src[#src] = nil
                        break
                    end
                end
            end
        end

        -- Mark as transferred rather than removing: keeps position_index indices
        -- valid and avoids an O(n) rebuild after every transfer.
        local fa = free_agents_list[candidate_index]
        if fa then fa.transferred = true end
        return true, false
    else
        stats.slots_failed = stats.slots_failed + 1
        LOGGER:LogWarning(string.format(
            "Failed transfer %s (%d) -> %s (%d). Error: %s",
            player_name, player_id, GetTeamName(team_id), team_id, tostring(error_message)
        ))
        return false, false
    end
end

-- Try strategies in the order configured by config.search_order, honoring a
-- per-slot blocklist of candidate indices that were abandoned mid-transfer (e.g.
-- the alt-position conversion dropped the rating below the widened band).
--
-- Each strategy returns (idx, used_alt, alt_pos, is_youth, used_lb, used_ub) on
-- success or nil to let the next strategy run.
local function find_best_candidate_for_slot(free_agents_list, position_index, req_pos,
    lower_bound, upper_bound, median_rating, youth_potential_requirement, blocklist)

    -- Wrap candidate search so it respects both the per-slot blocklist and the
    -- global `transferred` flag on free agents.
    local function find_with_block(pos, lb, ub)
        local best_idx, best_dist = nil, math.huge
        local target = median_rating or ((lb + ub) * 0.5)
        if position_index and position_index[pos] then
            for _, i in ipairs(position_index[pos]) do
                if not blocklist[i] then
                    local fa = free_agents_list[i]
                    if fa and not fa.transferred
                        and fa.overall >= lb and fa.overall <= ub then
                        local d = math.abs(fa.overall - target)
                        if d < best_dist then best_idx, best_dist = i, d end
                    end
                end
            end
        else
            for i, fa in ipairs(free_agents_list) do
                if not blocklist[i] and not fa.transferred
                    and fa.positionName == pos
                    and fa.overall >= lb and fa.overall <= ub then
                    local d = math.abs(fa.overall - target)
                    if d < best_dist then best_idx, best_dist = i, d end
                end
            end
        end
        return best_idx
    end

    local steps = config.max_widen_steps or 0
    local step_size = config.widen_step_size or 0

    local strategies = {
        exact = function()
            local idx = find_with_block(req_pos, lower_bound, upper_bound)
            if idx then return idx, false, nil, false, lower_bound, upper_bound end
        end,
        alt = function()
            local alts = config.alternative_positions[req_pos]
            if not alts then return end
            for _, alt_pos in ipairs(alts) do
                local a_idx = find_with_block(alt_pos, lower_bound, upper_bound)
                if a_idx then return a_idx, true, alt_pos, false, lower_bound, upper_bound end
            end
        end,
        widen_one = function()
            if steps < 1 or step_size <= 0 then return end
            local w_lb = lower_bound - step_size
            local w_ub = upper_bound + step_size
            local idx = find_with_block(req_pos, w_lb, w_ub)
            if idx then return idx, false, nil, false, w_lb, w_ub end
        end,
        youth = function()
            local y_idx, y_alt_used, y_alt_pos = find_youth_potential_candidate(
                free_agents_list, position_index, req_pos, youth_potential_requirement
            )
            if y_idx and not blocklist[y_idx] then
                return y_idx, y_alt_used or false, y_alt_pos, true, lower_bound, upper_bound
            end
        end,
        widen_full = function()
            if step_size <= 0 then return end
            for s = 2, steps do
                local w_lb = lower_bound - s * step_size
                local w_ub = upper_bound + s * step_size
                local idx = find_with_block(req_pos, w_lb, w_ub)
                if idx then return idx, false, nil, false, w_lb, w_ub end
            end
        end
    }

    local order = config.search_order or { "exact", "alt", "widen_one", "youth", "widen_full" }
    local seen = {}
    for _, step_name in ipairs(order) do
        local fn = strategies[step_name]
        if fn and not seen[step_name] then
            seen[step_name] = true
            local idx, used_alt, alt_pos, is_youth, used_lb, used_ub = fn()
            if idx then
                return idx, used_alt, alt_pos, is_youth, used_lb, used_ub
            end
        end
    end

    return nil, false, nil, false, lower_bound, upper_bound
end

local function process_team_entry(entry, free_agents_list, position_index)
    local team_id = entry.team_id
    local req_pos = entry.position

    if get_team_size(team_id) >= config.squad_size then
        stats.teams_full_skipped = stats.teams_full_skipped + 1
        return false
    end

    local lower_bound, upper_bound, median_rating = get_team_lower_upper_bounds(
        team_id, player_data,
        config.lower_bound_minus, config.upper_bound_plus
    )
    if not lower_bound or not upper_bound then
        stats.teams_no_stats = stats.teams_no_stats + 1
        return false
    end

    local youth_potential_requirement
    if config.youth_player.use_median then
        youth_potential_requirement = median_rating + config.youth_player.potential_bonus
        -- Cap the requirement so high-potential youth (>= cap) are always considered
        -- even for stacked elite squads where median+bonus would exclude them.
        local cap = config.youth_player.potential_cap
        if cap and youth_potential_requirement > cap then
            youth_potential_requirement = cap
        end
    else
        youth_potential_requirement = upper_bound
    end

    -- Try candidates, retrying after any alt-position conversion that had to be
    -- reverted (abandoned) so we don't silently leave the slot miss-filled.
    local blocklist = {}
    local max_attempts = 5
    for _ = 1, max_attempts do
        local candidate_index, used_alt, alt_position, is_youth_prospect, used_lb, used_ub =
            find_best_candidate_for_slot(
                free_agents_list, position_index, req_pos,
                lower_bound, upper_bound, median_rating,
                youth_potential_requirement, blocklist
            )

        if not candidate_index then
            stats.slots_unfilled = stats.slots_unfilled + 1
            LOGGER:LogInfo(string.format(
                "No free agent for team %d at '%s' (tried [%d..%d]). Skipping.",
                team_id, req_pos,
                lower_bound - (config.max_widen_steps or 0) * (config.widen_step_size or 0),
                upper_bound + (config.max_widen_steps or 0) * (config.widen_step_size or 0)
            ))
            return false
        end

        local widened = (used_lb ~= lower_bound or used_ub ~= upper_bound)

        local player_id = free_agents_list[candidate_index].playerid
        local success, abandoned = handle_player_transfer(
            player_id, team_id, req_pos,
            free_agents_list, candidate_index,
            used_alt, alt_position, is_youth_prospect
        )

        if success then
            if widened then stats.transfers_widened = stats.transfers_widened + 1 end
            return true
        elseif abandoned then
            blocklist[candidate_index] = true
            -- loop and try the next candidate
        else
            -- hard failure (pcall error); don't retry this slot
            return false
        end
    end

    return false
end

local function do_transfers()
    -- Get all team needs
    local queue = get_all_teams_and_needs()
    if #queue == 0 then
        MessageBox("No Team Needs", "No teams found with missing positions.")
        return
    end

    -- Build free agents list with position indexing
    local free_agents_list, position_index = build_free_agents()
    if #free_agents_list == 0 then
        MessageBox("No Free Agents", "No eligible free agents found to transfer.")
        return
    end
    
    if not players_table_global then
        LOGGER:LogError("Players table not initialized. Aborting.")
        return
    end

    -- Process all team needs. Queue is periodically re-weighted: after each successful
    -- transfer the touched team's needs/bounds caches are invalidated; every
    -- requeue_every_n_transfers transfers we recompute weights for the still-pending
    -- entries and re-sort.
    local since_requeue = 0
    local start_time = os.time()

    local idx = 1
    while idx <= #queue do
        if idx % 100 == 0 then
            LOGGER:LogInfo(string.format(
                "Processed %d/%d needs (%d%%) in %ds. Transfers so far: %d",
                idx, #queue, math.floor(idx / #queue * 100),
                os.time() - start_time, stats.transfers_total
            ))
        end

        if process_team_entry(queue[idx], free_agents_list, position_index) then
            since_requeue = since_requeue + 1
        end

        if since_requeue >= (config.requeue_every_n_transfers or math.huge) then
            since_requeue = 0
            local remaining = {}
            for j = idx + 1, #queue do
                local e = queue[j]
                local size = get_team_size(e.team_id)
                if size < config.squad_size then
                    local _, shortage_by_pos, total_short = compute_team_needs(e.team_id)
                    if (shortage_by_pos[e.position] or 0) > 0 then
                        e.weight = compute_entry_weight(
                            shortage_by_pos[e.position], total_short, e.position, size
                        )
                        e.shortage = shortage_by_pos[e.position]
                        remaining[#remaining + 1] = e
                    end
                end
            end
            table.sort(remaining, function(a, b) return a.weight > b.weight end)

            local new_queue = {}
            for j = 1, idx do new_queue[j] = queue[j] end
            for j, e in ipairs(remaining) do new_queue[idx + j] = e end
            queue = new_queue
            LOGGER:LogInfo(string.format(
                "Re-sorted queue after %d transfers: %d needs still pending.",
                stats.transfers_total, #remaining
            ))
        end

        idx = idx + 1
    end

    local elapsed = os.time() - start_time

    local summary = string.format(
        "Transfers: %d total (normal %d, alt-pos %d, youth %d, widened %d). " ..
        "Slots: unfilled %d, abandoned %d, failed %d. " ..
        "Teams skipped: full %d, no-stats %d. Elapsed: %ds.",
        stats.transfers_total, stats.transfers_normal, stats.transfers_alt,
        stats.transfers_youth, stats.transfers_widened,
        stats.slots_unfilled, stats.slots_abandoned, stats.slots_failed,
        stats.teams_full_skipped, stats.teams_no_stats, elapsed
    )
    LOGGER:LogInfo("=== Transfer run summary ===")
    LOGGER:LogInfo(summary)

    MessageBox("Transfers Done", string.format(
        "Processed %d needs in %ds.\nSigned %d (normal %d / alt %d / youth %d, widened %d).\nUnfilled %d, abandoned %d, failed %d.",
        #queue, elapsed,
        stats.transfers_total, stats.transfers_normal, stats.transfers_alt,
        stats.transfers_youth, stats.transfers_widened,
        stats.slots_unfilled, stats.slots_abandoned, stats.slots_failed
    ))
end

--------------------------------------------------------------------------------
-- MAIN SCRIPT
--------------------------------------------------------------------------------
math.randomseed(os.time())
LOGGER:LogInfo("Starting Multi-League Transfer Script...")

do_transfers()