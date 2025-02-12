--------------------------------------------------------------------------------
-- Lua Script for Multi-League Player Transfers
-- with Position IDs Mapping, Priority Queue, and League-Specific Constraints
--------------------------------------------------------------------------------
require 'imports/career_mode/helpers'
require 'imports/other/helpers'
local helper_methods = require("helper_methods")

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
    excluded_teams = { [113926] = true },         -- e.g. { [1234] = true }
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

local player_data = helper_methods.build_player_data(players_table_global)
--------------------------------------------------------------------------------
-- FORMATION LOGIC: Retrieve each team's formation positions
--------------------------------------------------------------------------------
local function get_formation_positions(target_team_id)
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
                local position_name= helper_methods.get_position_name_from_position_id(position_id)
                positions[#positions+1] = position_name
            end
            return positions
        end
        record = formations_table_global:GetNextValidRecord()
    end
    return {}
end

--------------------------------------------------------------------------------
-- TEAM NEEDS - Attempts to have 2 for every position in team's formation
--------------------------------------------------------------------------------
local function compute_team_needs(team_id)
    local formation_positions = get_formation_positions(team_id)
    if #formation_positions==0 then return {} end

    local demand = {}
    for _,pos in ipairs(formation_positions) do
        demand[pos] = (demand[pos] or 0) + 1
    end
    for pos in pairs(demand) do
        demand[pos] = demand[pos]*2
    end

    local current_positions = helper_methods.count_positions_in_team(team_id, team_player_links_global, player_data)
    
    local needed = {}
    for pos, required_count in pairs(demand) do
        local existing = current_positions[pos] or 0
        local missing = required_count - existing
        for _=1, missing>0 and missing or 0 do
            needed[#needed+1] = pos
        end
    end
    return needed
end

--------------------------------------------------------------------------------
-- BUILD A LIST OF TEAMS + NEEDS => PRIORITY QUEUE
--------------------------------------------------------------------------------
local function get_all_teams_and_needs()
    local league_team_links = league_team_links_global
    if not league_team_links then return {} end

    local all_entries, team_needs_cache = {}, {}
    local league_teams = {}
    local record = league_team_links:GetFirstRecord()

    while record>0 do
        local league_id_field = league_team_links:GetRecordFieldValue(record,"leagueid")
        local team_id_field   = league_team_links:GetRecordFieldValue(record,"teamid")
        if league_id_field and team_id_field and not config.excluded_teams[team_id_field] then
            league_teams[league_id_field] = league_teams[league_id_field] or {}
            league_teams[league_id_field][#league_teams[league_id_field]+1] = team_id_field
        end
        record= league_team_links:GetNextValidRecord()
    end

    for _, league_id in ipairs(config.target_leagues) do
        local teams_in_league = league_teams[league_id] or {}
        for _, team_id in ipairs(teams_in_league) do
            local size = helper_methods.get_team_size(team_id, team_player_links_global)
            if size < config.squad_size then
                team_needs_cache[team_id] = compute_team_needs(team_id)
            else
                team_needs_cache[team_id] = {}
                LOGGER:LogInfo(string.format("Team %d is full. Skipping future needs.", team_id))
            end

            for _, pos_name in ipairs(team_needs_cache[team_id]) do
                all_entries[#all_entries+1] = {
                    team_id = team_id,
                    position = pos_name,
                    weight = 10
                }
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
            local age = helper_methods.calculate_player_age(pdata.birthdate)
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
            helper_methods.update_player_preferred_position_1(player_id, helper_methods.get_position_id_from_position_name(position), players_table_global)
            helper_methods.update_all_player_roles(player_id, config.positions_to_roles[position][1], config.positions_to_roles[position][2], config.positions_to_roles[position][3], players_table_global)
        end

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
    if helper_methods.get_team_size(team_id, team_player_links_global) >= config.squad_size then
        LOGGER:LogInfo(string.format("Team %d is full. Skipping.", team_id))
        return false
    end

    local lower_bound, upper_bound = helper_methods.get_team_lower_upper_bounds(team_id, team_player_links_global, player_data, config.lower_bound_minus, config.upper_bound_plus)
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