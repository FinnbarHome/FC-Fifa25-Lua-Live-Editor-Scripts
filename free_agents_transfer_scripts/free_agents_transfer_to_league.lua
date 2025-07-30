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
    position_to_group = {
        GK = "goalkeeper",
        RB = "defence", CB = "defence", LB = "defence",
        LM = "midfield", CM = "midfield", CDM = "midfield", RM = "midfield",
        CAM = "attacker", ST = "attacker", RW = "attacker", LW = "attacker"
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
    excluded_teams = { [1952] = true },         -- e.g. { [1234] = true }
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
        max_age = 23,        -- Maximum age for youth players (was hardcoded to 24)
        potential_bonus = 5, -- Potential must be >= team median + this value (when use_median=true)
        use_median = true    -- true: use team median + bonus (like simplified_squad_filler.lua)
                            -- false: use team 75th percentile (original behavior)
    }
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

-- Cache team sizes for performance
local team_size_cache = {}
local function get_team_size(team_id, team_player_links)
    if team_size_cache[team_id] then
        return team_size_cache[team_id]
    end
    
    if not team_player_links then return 0 end
    local count, rec = 0, team_player_links:GetFirstRecord()
    while rec>0 do
        if team_player_links:GetRecordFieldValue(rec,"teamid")==team_id then
            count = count+1
        end
        rec=team_player_links:GetNextValidRecord()
    end
    
    team_size_cache[team_id] = count
    return count
end

local function update_all_player_roles(player_id, r1, r2, r3, players_table)
    local rec = players_table:GetFirstRecord()
    while rec>0 do
        if players_table:GetRecordFieldValue(rec,"playerid")==player_id then
            local pos = players_table:GetRecordFieldValue(rec,"preferredposition1")
            if pos==0 then r3=0 end
            players_table:SetRecordFieldValue(rec,"role1",r1)
            players_table:SetRecordFieldValue(rec,"role2",r2)
            players_table:SetRecordFieldValue(rec,"role3",r3)
            LOGGER:LogInfo(string.format("Updated player %d's roles to %d,%d,%d.", player_id, r1, r2, r3))
            return
        end
        rec = players_table:GetNextValidRecord()
    end
    LOGGER:LogWarning(string.format("Player %d not found. Could not update roles.", player_id))
end

local function update_player_preferred_position_1(player_id, new_pos_id, players_table)
    local rec = players_table:GetFirstRecord()
    while rec>0 do
        if players_table:GetRecordFieldValue(rec,"playerid")==player_id then
            local old = players_table:GetRecordFieldValue(rec,"preferredposition1")
            local pos2= players_table:GetRecordFieldValue(rec,"preferredposition2")
            local pos3= players_table:GetRecordFieldValue(rec,"preferredposition3")
            players_table:SetRecordFieldValue(rec,"preferredposition1", new_pos_id)
            LOGGER:LogInfo(string.format("Updated player %d pos1 to %d.", player_id, new_pos_id))

            if new_pos_id==0 then
                LOGGER:LogInfo(string.format("Player %d is GK -> clearing pos2/pos3.", player_id))
                players_table:SetRecordFieldValue(rec,"preferredposition2",-1)
                players_table:SetRecordFieldValue(rec,"preferredposition3",-1)
                return
            end
            if pos2==new_pos_id then
                players_table:SetRecordFieldValue(rec,"preferredposition2", old)
                LOGGER:LogInfo(string.format("Swapped pos2 with old pos1(%d).", old))
            end
            if pos3==new_pos_id then
                players_table:SetRecordFieldValue(rec,"preferredposition3", old)
                LOGGER:LogInfo(string.format("Swapped pos3 with old pos1(%d).", old))
            end
            return
        end
        rec= players_table:GetNextValidRecord()
    end
    LOGGER:LogWarning(string.format("Player %d not found. Could not update position.", player_id))
end

-- Pre-index players by ID for faster lookups
local function build_player_data(players_table)
    if not players_table then
        LOGGER:LogWarning("Players table not found. Could not build player data.")
        return {}
    end
    local player_data = {}
    local player_by_position = {}
    
    local rec = players_table:GetFirstRecord()
    while rec > 0 do
        local pid = players_table:GetRecordFieldValue(rec, "playerid")
        if pid then
            local rating = players_table:GetRecordFieldValue(rec, "overallrating") or 0
            local potential = players_table:GetRecordFieldValue(rec, "potential") or 0
            local birthdate = players_table:GetRecordFieldValue(rec, "birthdate")
            local pref_pos  = players_table:GetRecordFieldValue(rec, "preferredposition1")
            local pos_name = pref_pos and get_position_name_from_position_id(pref_pos) or nil
            
            -- Store player data by ID
            player_data[pid] = {
                overall = rating,
                potential = potential,
                birthdate = birthdate,
                preferredposition1 = pref_pos,
                positionName = pos_name,
                age = calculate_player_age(birthdate)
            }
            
            -- Also index by position
            if pos_name then
                player_by_position[pos_name] = player_by_position[pos_name] or {}
                table.insert(player_by_position[pos_name], {
                    playerid = pid,
                    overall = rating,
                    potential = potential,
                    age = player_data[pid].age
                })
            end
        end
        rec = players_table:GetNextValidRecord()
    end
    
    return player_data, player_by_position
end

-- Cache position counts for each team
local team_positions_cache = {}
local function count_positions_in_team(team_id, team_player_links, player_data)
    if team_positions_cache[team_id] then
        return team_positions_cache[team_id]
    end
    
    local counts, rec = {}, team_player_links:GetFirstRecord()
    while rec>0 do
        if team_player_links:GetRecordFieldValue(rec,"teamid")==team_id then
            local p_id = team_player_links:GetRecordFieldValue(rec,"playerid")
            local pdata= player_data[p_id]
            if pdata and pdata.preferredposition1 then
                local name = get_position_name_from_position_id(pdata.preferredposition1)
                counts[name] = (counts[name] or 0)+1
            end
        end
        rec=team_player_links:GetNextValidRecord()
    end
    
    team_positions_cache[team_id] = counts
    return counts
end

-- Cache team rating bounds
    local team_bounds_cache = {}
local function get_team_lower_upper_bounds(team_id, team_player_links, player_data, lower_bound_minus, upper_bound_plus)
    if team_bounds_cache[team_id] then
        return team_bounds_cache[team_id][1], team_bounds_cache[team_id][2], team_bounds_cache[team_id][3]
    end

    local ratings, rec = {}, team_player_links:GetFirstRecord()
    while rec>0 do
        local t_id= team_player_links:GetRecordFieldValue(rec,"teamid")
        if t_id==team_id then
            local p_id= team_player_links:GetRecordFieldValue(rec,"playerid")
            local pdata= player_data[p_id]
            if pdata then ratings[#ratings+1]= pdata.overall end
        end
        rec=team_player_links:GetNextValidRecord()
    end
    if #ratings==0 then
        LOGGER:LogWarning(string.format("No ratings found for team %d.", team_id))
        return nil, nil
    end

    table.sort(ratings)
    local n=#ratings
    local i50, i75= math.ceil(0.5*n), math.ceil(0.75*n)
    local p50, p75= math.floor(ratings[i50]+0.5), math.floor(ratings[i75]+0.5)
    local lb, ub= p50 - lower_bound_minus, p75 + upper_bound_plus

    local team_name= GetTeamName(team_id)
    LOGGER:LogInfo(string.format("Team %s(ID %d): 50%%=%d->LB:%d, 75%%=%d->UB:%d", 
        team_name,team_id,p50,lb,p75,ub))
        
    team_bounds_cache[team_id] = {lb, ub, p50}
    return lb, ub, p50
end

-- Initialize player data and position indexed data
local player_data, player_positions_by_id = build_player_data(players_table_global)

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
local function compute_team_needs(team_id)
    if team_needs_cache[team_id] then
        return team_needs_cache[team_id]
    end
    
    local formation_positions = get_formation_positions(team_id)
    if #formation_positions==0 then 
        team_needs_cache[team_id] = {}
        return {} 
    end

    local demand = {}
    for _,pos in ipairs(formation_positions) do
        demand[pos] = (demand[pos] or 0) + 1
    end
    for pos in pairs(demand) do
        demand[pos] = demand[pos]*2
    end

    local current_positions = count_positions_in_team(team_id, team_player_links_global, player_data)
    
    local needed = {}
    for pos, required_count in pairs(demand) do
        local existing = current_positions[pos] or 0
        local missing = required_count - existing
        for _=1, missing>0 and missing or 0 do
            needed[#needed+1] = pos
        end
    end
    
    team_needs_cache[team_id] = needed
    return needed
end

--------------------------------------------------------------------------------
-- BUILD A LIST OF TEAMS + NEEDS => PRIORITY QUEUE
--------------------------------------------------------------------------------
local function get_all_teams_and_needs()
    local league_team_links = league_team_links_global
    if not league_team_links then return {} end

    local all_entries = {}
    local league_teams = build_league_teams_map()

    for _, league_id in ipairs(config.target_leagues) do
        local teams_in_league = league_teams[league_id] or {}
        for _, team_id in ipairs(teams_in_league) do
            local size = get_team_size(team_id, team_player_links_global)
            if size < config.squad_size then
                local team_needs = compute_team_needs(team_id)
                
                for _, pos_name in ipairs(team_needs) do
                    all_entries[#all_entries+1] = {
                        team_id = team_id,
                        position = pos_name,
                        weight = 10
                    }
                end
            else
                LOGGER:LogInfo(string.format("Team %d is full. Skipping future needs.", team_id))
            end
        end
    end

    table.sort(all_entries, function(a,b) return a.weight>b.weight end)
    return all_entries
end

--------------------------------------------------------------------------------
-- BUILD LIST OF ELIGIBLE FREE AGENTS FOR EACH LEAGUE
--------------------------------------------------------------------------------
local function build_free_agents()
    if not player_data or not team_player_links_global then
        return {}, {}
    end

    local results = {}
    local position_index = {} -- To index free agents by position for quick lookup
    local rec = team_player_links_global:GetFirstRecord()
    
    -- First pass: collect all eligible free agents
    while rec > 0 do
        local t_id = team_player_links_global:GetRecordFieldValue(rec, "teamid")
        local p_id = team_player_links_global:GetRecordFieldValue(rec, "playerid")
        local pdata = player_data[p_id]

        if t_id == config.transfer.from_team_id and pdata then
            local age = pdata.age or calculate_player_age(pdata.birthdate)
            if age >= config.age_constraints.min and age <= config.age_constraints.max then
                local pos_name = pdata.positionName
                local new_entry = {
                    playerid = p_id,
                    overall = pdata.overall,
                    potential = pdata.potential,
                    positionName = pos_name,
                    age = age
                }
                
                results[#results + 1] = new_entry
                
                -- Index by position
                if pos_name then
                    position_index[pos_name] = position_index[pos_name] or {}
                    table.insert(position_index[pos_name], #results) -- Store index in results table
                end
            end
        end
        rec = team_player_links_global:GetNextValidRecord()
    end

    -- Shuffle the results to avoid biases
    for i = #results, 2, -1 do
        local j = math.random(i)
        results[i], results[j] = results[j], results[i]
        
        -- We've shuffled the data, so the position index is no longer valid
        -- We'll rebuild it after shuffling
    end
    
    -- Rebuild position index after shuffling
    position_index = {}
    for i, player in ipairs(results) do
        local pos = player.positionName
        if pos then
            position_index[pos] = position_index[pos] or {}
            table.insert(position_index[pos], i)
        end
    end
    
    return results, position_index
end

--------------------------------------------------------------------------------
-- ACTUAL TRANSFER MECHANISM
--------------------------------------------------------------------------------
local function find_candidate(free_agents_list, position_index, position_name, min_rating, max_rating)
    -- If we have an index for this position, use it for faster lookups
    if position_index and position_index[position_name] then
        for _, idx in ipairs(position_index[position_name]) do
            local free_agent = free_agents_list[idx]
            if free_agent.overall >= min_rating and free_agent.overall <= max_rating then
                return idx
            end
        end
        return nil
    end
    
    -- Fallback to linear search if no index is available
    for i, free_agent in ipairs(free_agents_list) do
        if free_agent.positionName == position_name then
            if free_agent.overall >= min_rating and free_agent.overall <= max_rating then
                return i
            end
        end
    end
    return nil
end

local function find_alternative_candidate(free_agents_list, position_index, position_required, min_rating, max_rating)
    local alternatives = config.alternative_positions[position_required]
    if not alternatives then return nil, false, nil end

    for _, alt_position in ipairs(alternatives) do
        local idx = find_candidate(free_agents_list, position_index, alt_position, min_rating, max_rating)
        if idx then
            return idx, true, alt_position
        end
    end
    return nil, false, nil
end

local function find_youth_potential_candidate(free_agents_list, position_index, position_required, min_potential_required)
    -- Look for high potential youth players with configurable age and potential requirements
    -- Age threshold: config.youth_player.max_age (default 23)
    -- Potential requirement: team median + config.youth_player.potential_bonus when use_median=true
    --                       or team 75th percentile when use_median=false (original behavior)
    local max_age = config.youth_player.max_age
    local youth_candidates = {}
    
    -- If we have an index for this position, use it for faster lookups
    if position_index and position_index[position_required] then
        for _, idx in ipairs(position_index[position_required]) do
            local free_agent = free_agents_list[idx]
            if free_agent.age <= max_age and free_agent.potential >= min_potential_required then
                youth_candidates[#youth_candidates + 1] = {
                    index = idx,
                    potential = free_agent.potential
                }
            end
        end
        
        -- Sort by potential (highest first)
        if #youth_candidates > 0 then
            table.sort(youth_candidates, function(a, b) return a.potential > b.potential end)
            return youth_candidates[1].index, true
        end
    else
        -- Fallback to linear search
        for i, free_agent in ipairs(free_agents_list) do
            if free_agent.positionName == position_required then
                local age = free_agent.age or calculate_player_age(player_data[free_agent.playerid].birthdate)
                if age <= max_age and free_agent.potential >= min_potential_required then
                    youth_candidates[#youth_candidates + 1] = {
                        index = i,
                        potential = free_agent.potential
                    }
                end
            end
        end
        
        -- Sort by potential (highest first)
        if #youth_candidates > 0 then
            table.sort(youth_candidates, function(a, b) return a.potential > b.potential end)
            return youth_candidates[1].index, true
        end
    end
    
    -- If no youth with exact position, try alternatives
    local alternatives = config.alternative_positions[position_required]
    if not alternatives then return nil, false end
    
    -- Clear and repopulate candidates using alternatives
    youth_candidates = {}
    
    for _, alt_position in ipairs(alternatives) do
        if position_index and position_index[alt_position] then
            for _, idx in ipairs(position_index[alt_position]) do
                local free_agent = free_agents_list[idx]
                if free_agent.age <= max_age and free_agent.potential >= min_potential_required then
                    youth_candidates[#youth_candidates + 1] = {
                        index = idx,
                        potential = free_agent.potential,
                        position = alt_position
                    }
                end
            end
        else
            -- Fallback for each alternative
            for i, free_agent in ipairs(free_agents_list) do
                if free_agent.positionName == alt_position then
                    local age = free_agent.age or calculate_player_age(player_data[free_agent.playerid].birthdate)
                    if age <= max_age and free_agent.potential >= min_potential_required then
                        youth_candidates[#youth_candidates + 1] = {
                            index = i,
                            potential = free_agent.potential,
                            position = alt_position
                        }
                    end
                end
            end
        end
    end
    
    if #youth_candidates > 0 then
        table.sort(youth_candidates, function(a, b) return a.potential > b.potential end)
        return youth_candidates[1].index, true, youth_candidates[1].position
    end
    
    return nil, false, nil
end

local function handle_player_transfer(player_id, team_id, position, league_id, free_agents_list, candidate_index, used_alternative, alternative_position_used, is_youth_prospect)
    local player_name = GetPlayerName(player_id)
    local ok, error_message = pcall(function()
        if IsPlayerPresigned(player_id) then DeletePresignedContract(player_id) end
        if IsPlayerLoanedOut(player_id) then TerminateLoan(player_id) end

        -- Find the player record once and reuse it
        local player_rec, original_position_id = nil, -1
        if used_alternative then
            LOGGER:LogInfo(string.format("Used alternative position '%s' instead of '%s'.", alternative_position_used, position))
            
            -- Find player record once
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
                -- Convert to the new position
                local new_pos_id = get_position_id_from_position_name(position)
                players_table_global:SetRecordFieldValue(player_rec, "preferredposition1", new_pos_id)
                
                -- Update roles
                local r1, r2, r3 = table.unpack(config.positions_to_roles[position] or {0, 0, 0})
                if players_table_global:GetRecordFieldValue(player_rec, "preferredposition1") == 0 then r3 = 0 end
                players_table_global:SetRecordFieldValue(player_rec, "role1", r1)
                players_table_global:SetRecordFieldValue(player_rec, "role2", r2)
                players_table_global:SetRecordFieldValue(player_rec, "role3", r3)
                
                LOGGER:LogInfo(string.format("Updated player %d pos1 to %d and roles to %d,%d,%d.", 
                    player_id, new_pos_id, r1, r2, r3))
                
                -- Check if player's rating after conversion meets threshold
                local lower_bound, _, _ = get_team_lower_upper_bounds(team_id, team_player_links_global, player_data, config.lower_bound_minus, config.upper_bound_plus)
                local player_rating = players_table_global:GetRecordFieldValue(player_rec, "overallrating") 
                              or players_table_global:GetRecordFieldValue(player_rec, "overall") or 0
                
                -- If player doesn't meet threshold, revert to original position
                if player_rating < lower_bound then
                    LOGGER:LogInfo(string.format("Player %s rating (%d) below threshold (%d) after position change. Reverting position.", 
                        player_name, player_rating, lower_bound))
                    
                    -- Get original position name
                    local original_position_name = get_position_name_from_position_id(original_position_id)
                    
                    -- Revert to original position
                    if original_position_name and original_position_id > 0 then
                        players_table_global:SetRecordFieldValue(player_rec, "preferredposition1", original_position_id)
                        
                        if config.positions_to_roles[original_position_name] then
                            local roles = config.positions_to_roles[original_position_name]
                            players_table_global:SetRecordFieldValue(player_rec, "role1", roles[1])
                            players_table_global:SetRecordFieldValue(player_rec, "role2", roles[2])
                            players_table_global:SetRecordFieldValue(player_rec, "role3", roles[3])
                        end
                    end
                end
            else
                LOGGER:LogWarning(string.format("Player %d record not found. Could not update position.", player_id))
            end
        end

        TransferPlayer(player_id, team_id, config.transfer.sum, config.transfer.wage, config.transfer.contract_length, config.transfer.from_team_id, config.transfer.release_clause)
    end)

    if ok then
        local transfer_type = "normal"
        if used_alternative then
            transfer_type = "alternative position"
        elseif is_youth_prospect then
            transfer_type = "youth prospect"
        end
        
        LOGGER:LogInfo(string.format(
            "Transferred %s (%d) to team %s (%d) for position %s as %s.",
            player_name, player_id, GetTeamName(team_id), team_id, position, transfer_type
        ))

        -- Update caches after transfer
        team_size_cache[team_id] = (team_size_cache[team_id] or 0) + 1
        table.remove(free_agents_list, candidate_index)
        return true
    else
        LOGGER:LogWarning(string.format(
            "Failed to transfer player %s (%d) -> team %s (%d). Error: %s",
            player_name, player_id, GetTeamName(team_id), team_id, tostring(error_message)
        ))
        return false
    end
end

local function process_team_entry(entry, free_agents_list, position_index)
    local team_id = entry.team_id
    local req_pos = entry.position
    
    -- Check if team is already full
    if get_team_size(team_id, team_player_links_global) >= config.squad_size then
        LOGGER:LogInfo(string.format("Team %d is full. Skipping.", team_id))
        return false
    end

    local lower_bound, upper_bound, median_rating = get_team_lower_upper_bounds(team_id, team_player_links_global, player_data, config.lower_bound_minus, config.upper_bound_plus)
    if not lower_bound or not upper_bound then
        LOGGER:LogInfo(string.format("No rating stats for team %d; skipping %s.", team_id, req_pos))
        return false
    end

    -- Calculate youth potential requirement based on config
    local youth_potential_requirement
    if config.youth_player.use_median then
        youth_potential_requirement = median_rating + config.youth_player.potential_bonus
    else
        youth_potential_requirement = upper_bound -- Use 75th percentile (original behavior)
    end

    local candidate_index = find_candidate(free_agents_list, position_index, req_pos, lower_bound, upper_bound)
    local used_alt, alt_position = false, nil
    local is_youth_prospect = false
    
    if not candidate_index then
        candidate_index, used_alt, alt_position =
            find_alternative_candidate(free_agents_list, position_index, req_pos, lower_bound, upper_bound)
            
        -- If still no candidate, try high potential youth
        if not candidate_index then
            candidate_index, is_youth_prospect, alt_position =
                find_youth_potential_candidate(free_agents_list, position_index, req_pos, youth_potential_requirement)
        end
    end

    if candidate_index then
        local player_id = free_agents_list[candidate_index].playerid
        return handle_player_transfer(player_id, team_id, req_pos, nil,
            free_agents_list, candidate_index, used_alt, alt_position, is_youth_prospect)
    else
        LOGGER:LogInfo(string.format(
            "No suitable free agent found for team %d at position '%s' in [%d..%d]. Skipping.",
            team_id, req_pos, lower_bound, upper_bound
        ))
        return false
    end
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

    -- Process all team needs
    local total_transfers = 0
    local start_time = os.time()
    
    for idx, team_entry in ipairs(queue) do
        -- Provide periodic updates for long-running operations
        if idx % 100 == 0 then
            local elapsed = os.time() - start_time
            LOGGER:LogInfo(string.format("Processed %d/%d needs (%d%%) in %d seconds. Transfers so far: %d", 
                idx, #queue, math.floor(idx / #queue * 100), elapsed, total_transfers))
        end
        
        local success = process_team_entry(team_entry, free_agents_list, position_index)
        if success then 
            total_transfers = total_transfers + 1 
            
            -- Update position index after each successful transfer
            -- (removes the transferred player from all indices)
            position_index = {}
            for i, player in ipairs(free_agents_list) do
                local pos = player.positionName
                if pos then
                    position_index[pos] = position_index[pos] or {}
                    table.insert(position_index[pos], i)
                end
            end
        end
    end

    local elapsed = os.time() - start_time
    MessageBox("Transfers Done", string.format(
        "Processed %d needs in %d seconds.\nTotal successful transfers: %d", 
        #queue, elapsed, total_transfers
    ))
end

--------------------------------------------------------------------------------
-- MAIN SCRIPT
--------------------------------------------------------------------------------
math.randomseed(os.time())
LOGGER:LogInfo("Starting Multi-League Transfer Script...")

do_transfers()