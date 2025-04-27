--------------------------------------------------------------------------------
-- Lua Script for Multi-League Player Transfers
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
    age_constraints = {min = 16, max = 35},
    squad_size = 52,
    target_leagues = {61,60,14,13,16,17,19,20,2076,31,32,10,83,53,54,353,351,80,4,2012,1,2149,41,66,308,65,330,350,50,56,189,68,39}, -- Eg: 61 = EFL League Two, 60 = EFL League One, 14 = EFL Championship, premier league, lig 1, lig 2, Bund, bund 2, bund 3, erd, k league, Liga 1, liga 2, argentinan prem, A league, O.Bund, 1A pro l, CSL, 3F Sup L, ISL, Eliteserien, PKO BP Eks, liga port, SSE Airtricity, Superliga, Saudi L, Scot prem, Allsven, CSSL, super lig, MLS
    excluded_teams = { [110] = true },         -- e.g. { [1234] = true }
    transfer = {
        sum = 0,
        wage = 600,
        contract_length = 60,
        release_clause = -1,
        from_team_id = 111592
    },
    lower_bound_minus = 2, -- This is the range that the script subtracts from the lower bounds of the team's ratings.
    upper_bound_plus = 2 -- This is the range that the script adds to the upper bounds of the team's ratings.
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
    local rec = players_table:GetFirstRecord()
    while rec > 0 do
        local pid = players_table:GetRecordFieldValue(rec, "playerid")
        if pid then
            local rating = players_table:GetRecordFieldValue(rec, "overallrating")
                          or players_table:GetRecordFieldValue(rec, "overall") or 0
            local potential = players_table:GetRecordFieldValue(rec, "potential") or 0
            local birthdate = players_table:GetRecordFieldValue(rec, "birthdate")
            local pref_pos  = players_table:GetRecordFieldValue(rec, "preferredposition1")
            player_data[pid] = {
                overall = rating,
                potential = potential,
                birthdate = birthdate,
                preferredposition1 = pref_pos,
                positionName = pref_pos and get_position_name_from_position_id(pref_pos) or nil
            }
        end
        rec = players_table:GetNextValidRecord()
    end
    return player_data
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
        return team_bounds_cache[team_id][1], team_bounds_cache[team_id][2]
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
        
    team_bounds_cache[team_id] = {lb, ub}
    return lb, ub
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
        return {}
    end

    local results = {}
    local rec = team_player_links_global:GetFirstRecord()
    while rec>0 do
        local t_id = team_player_links_global:GetRecordFieldValue(rec,"teamid")
        local p_id = team_player_links_global:GetRecordFieldValue(rec,"playerid")
        local pdata = player_data[p_id]

        if t_id==config.transfer.from_team_id and pdata then
            local age = calculate_player_age(pdata.birthdate)
            if age>=config.age_constraints.min and age<=config.age_constraints.max then
                results[#results+1] = {
                    playerid = p_id,
                    overall = pdata.overall,
                    potential = pdata.potential,
                    positionName = pdata.positionName
                }
            end
        end
        rec = team_player_links_global:GetNextValidRecord()
    end

    -- Shuffle
    for i=#results,2,-1 do
        local j=math.random(i)
        results[i], results[j] = results[j], results[i]
    end
    return results
end

--------------------------------------------------------------------------------
-- ACTUAL TRANSFER MECHANISM
--------------------------------------------------------------------------------
local function find_candidate(free_agents_list, position_name, min_rating, max_rating)
    for i, free_agent in ipairs(free_agents_list) do
        if free_agent.positionName == position_name then
            if free_agent.overall >= min_rating and free_agent.overall <= max_rating then
                return i
            end
        end
    end
    return nil
end

local function find_alternative_candidate(free_agents_list, position_required, min_rating, max_rating)
    local alternatives = config.alternative_positions[position_required]
    if not alternatives then return nil, false, nil end

    for _, alt_position in ipairs(alternatives) do
        local idx = find_candidate(free_agents_list, alt_position, min_rating, max_rating)
        if idx then
            return idx, true, alt_position
        end
    end
    return nil, false, nil
end

local function handle_player_transfer(player_id, team_id, position, league_id, free_agents_list, candidate_index, used_alternative, alternative_position_used)
    local player_name = GetPlayerName(player_id)
    local ok, error_message = pcall(function()
        if IsPlayerPresigned(player_id) then DeletePresignedContract(player_id) end
        if IsPlayerLoanedOut(player_id) then TerminateLoan(player_id) end

        TransferPlayer(player_id, team_id, config.transfer.sum, config.transfer.wage, config.transfer.contract_length, config.transfer.from_team_id, config.transfer.release_clause)
    end)

    if ok then
        LOGGER:LogInfo(string.format(
            "Transferred %s (%d) to team %s (%d) for position %s (league ).",
            player_name, player_id, GetTeamName(team_id), team_id, position
        ))

        if used_alternative then
            LOGGER:LogInfo(string.format("Used alternative position '%s' instead of '%s'.", alternative_position_used, position))
            update_player_preferred_position_1(player_id, get_position_id_from_position_name(position), players_table_global)
            update_all_player_roles(player_id, config.positions_to_roles[position][1], config.positions_to_roles[position][2], config.positions_to_roles[position][3], players_table_global)
        end

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

local function process_team_entry(entry, free_agents_list)
    local team_id= entry.team_id
    local req_pos= entry.position
    if get_team_size(team_id, team_player_links_global) >= config.squad_size then
        LOGGER:LogInfo(string.format("Team %d is full. Skipping.", team_id))
        return false
    end

    local lower_bound, upper_bound = get_team_lower_upper_bounds(team_id, team_player_links_global, player_data, config.lower_bound_minus, config.upper_bound_plus)
    if not lower_bound or not upper_bound then
        LOGGER:LogInfo(string.format("No rating stats for team %d; skipping %s.", team_id, req_pos))
        return false
    end

    local candidate_index = find_candidate(free_agents_list, req_pos, lower_bound, upper_bound)
    local used_alt, alt_position = false, nil
    if not candidate_index then
        candidate_index, used_alt, alt_position =
            find_alternative_candidate(free_agents_list, req_pos, lower_bound, upper_bound)
    end

    if candidate_index then
        local player_id = free_agents_list[candidate_index].playerid
        return handle_player_transfer(player_id, team_id, req_pos, nil,
            free_agents_list, candidate_index, used_alt, alt_position)
    else
        LOGGER:LogInfo(string.format(
            "No suitable free agent found for team %d at position '%s' in [%d..%d]. Skipping.",
            team_id, req_pos, lower_bound, upper_bound
        ))
        return false
    end
end


local function do_transfers()
    local queue = get_all_teams_and_needs()
    if #queue==0 then
        MessageBox("No Team Needs","No teams found with missing positions.")
        return
    end

    local free_agents_list = build_free_agents()
    if not players_table_global then
        LOGGER:LogError("Players table not initialized. Aborting.")
        return
    end

    local total_transfers=0
    for _, team_entry in ipairs(queue) do
        local success= process_team_entry(team_entry, free_agents_list)
        if success then total_transfers= total_transfers+1 end
    end

    MessageBox("Transfers Done", string.format(
        "Processed %d needs. Total successful transfers: %d", #queue, total_transfers
    ))
end


--------------------------------------------------------------------------------
-- MAIN SCRIPT
--------------------------------------------------------------------------------
math.randomseed(os.time())
LOGGER:LogInfo("Starting Multi-League Transfer Script...")

do_transfers()