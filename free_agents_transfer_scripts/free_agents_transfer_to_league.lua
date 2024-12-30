--------------------------------------------------------------------------------
-- Lua Script for Multi-League Player Transfers
-- with Position IDs Mapping, Priority Queue, and League-Specific Constraints
--------------------------------------------------------------------------------

require 'imports/career_mode/helpers'
require 'imports/other/helpers'
local logger = require("logger")

local team_player_links_global = LE.db:GetTable("teamplayerlinks")
local players_table_global   = LE.db:GetTable("players")
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
    league_constraints = setmetatable({
        [61] = {min_overall = 58, max_overall = 64, min_potential = 65, max_potential = 99},
        [60] = {min_overall = 65, max_overall = 69, min_potential = 65, max_potential = 99},
        [14] = {min_overall = 70, max_overall = 74, min_potential = 70, max_potential = 99},
        [13] = {min_overall = 74, max_overall = 99, min_potential = 74, max_potential = 99}
    }, { __index = function()
        return {min_overall = 55, max_overall = 90, min_potential = 55, max_potential = 99}
    end }),
    age_constraints = {min = 16, max = 35},
    squad_size = 52,
    target_leagues = {61}, -- Eg: 61 = EFL League Two, 60 = EFL League One, 14 = EFL Championship
    excluded_teams = {}, -- Example: { [12345] = true }
    transfer = {
        sum = 0,
        wage = 600,
        contract_length = 60,
        release_clause = -1,
        from_team_id = 111592
    }
}
-- Call the logger function
-- logger.logConfigSummary(config)

--------------------------------------------------------------------------------
-- HELPER FUNCTIONS
--------------------------------------------------------------------------------
local function get_role_id_from_role_name(role_req)
    return (config.position_ids[role_req] or {})[1]
end

-- Map Position ID to Role Name
local position_name_by_id = {}
for role_name, id_list in pairs(config.position_ids) do
    for _, pos_id in ipairs(id_list) do
        position_name_by_id[pos_id] = role_name
    end
end

local function get_role_name_from_position_id(position_id)
    return position_name_by_id[position_id] or ("UnknownPos(".. tostring(position_id) ..")")
end

-- Compute Age from Birthdate
local function calculate_player_age(birth_date)
    if not birth_date or birth_date <= 0 then return 20 end -- Default age
    local current_date = GetCurrentDate()
    local date = DATE:new()
    date:FromGregorianDays(birth_date)
    local age = current_date.year - date.year
    if (current_date.month < date.month) or (current_date.month == date.month and current_date.day < date.day) then
        age = age - 1
    end
    return age
end


--------------------------------------------------------------------------------
-- FORMATION LOGIC: Retrieve each team's formation positions
--------------------------------------------------------------------------------
local function get_formation_roles(target_team_id)
    if not formations_table_global then
        return {}
    end

    local record = formations_table_global:GetFirstRecord()
    while record > 0 do
        local team_id_current = formations_table_global:GetRecordFieldValue(record, "teamid")
        if team_id_current == target_team_id then
            local roles = {}
            for i = 0, 10 do
                local field_name = ("position%d"):format(i)
                local position_id = formations_table_global:GetRecordFieldValue(record, field_name) or 0
                local role_name = get_role_name_from_position_id(position_id)
                table.insert(roles, role_name)
            end
            return roles
        end
        record = formations_table_global:GetNextValidRecord()
    end
    return {}
end

--------------------------------------------------------------------------------
-- COUNT HOW MANY PLAYERS PER ROLE A TEAM HAS
--------------------------------------------------------------------------------
local function count_roles_in_team(target_team_id)
    if not team_player_links_global or not players_table_global then
        return {}
    end

    -- Cache all player positions
    local player_position_map = {}
    local player_record = players_table_global:GetFirstRecord()
    while player_record > 0 do
        local player_id = players_table_global:GetRecordFieldValue(player_record, "playerid")
        local preferred_position_1 = players_table_global:GetRecordFieldValue(player_record, "preferredposition1")
        if player_id and preferred_position_1 then
            player_position_map[player_id] = preferred_position_1
        end
        player_record = players_table_global:GetNextValidRecord()
    end

    -- Count roles in the team
    local role_count = {}
    local record_team_player_links = team_player_links_global:GetFirstRecord()
    while record_team_player_links > 0 do
        local team_id = team_player_links_global:GetRecordFieldValue(record_team_player_links, "teamid")
        local role_count_player_id = team_player_links_global:GetRecordFieldValue(record_team_player_links, "playerid")
        if team_id == target_team_id and player_position_map[role_count_player_id] then
            local role_name = get_role_name_from_position_id(player_position_map[role_count_player_id])
            role_count[role_name] = (role_count[role_name] or 0) + 1
        end
        record_team_player_links = team_player_links_global:GetNextValidRecord()
    end

    return role_count
end


--------------------------------------------------------------------------------
-- TEAM NEEDS - Attempts to have 2 for every position in team's formation
--------------------------------------------------------------------------------
local function compute_team_needs(team_id)
    local formation_roles = get_formation_roles(team_id)  -- e.g. {"CB","ST","CB",...}
    if #formation_roles == 0 then
        return {}
    end

    -- Tally how many roles the formation demands
    local demand = {}
    for _, role_name in ipairs(formation_roles) do
        demand[role_name] = (demand[role_name] or 0) + 1
    end
    -- Double each
    for role_name in pairs(demand) do
        demand[role_name] = demand[role_name] * 2
    end

    -- Check how many the team currently has
    local current_roles = count_roles_in_team(team_id)

    -- Build array of needed roles
    local needed_slots = {}
    for role_name, required_count in pairs(demand) do
        local existing_count = current_roles[role_name] or 0
        local missing_count = required_count - existing_count
        if missing_count > 0 then
            for _=1, missing_count do
                table.insert(needed_slots, role_name)
            end
        end
    end

    return needed_slots
end

--------------------------------------------------------------------------------
-- GETTEAMSIZE
--------------------------------------------------------------------------------
local function get_team_size(team_id)
    local team_player_links = team_player_links_global
    if not team_player_links then return 0 end

    local count = 0
    local team_player_links_record = team_player_links:GetFirstRecord()
    while team_player_links_record > 0 do
        local team_id_field = team_player_links:GetRecordFieldValue(team_player_links_record, "teamid")
        if team_id_field == team_id then
            count = count + 1
        end
        team_player_links_record = team_player_links:GetNextValidRecord()
    end
    return count
end

--------------------------------------------------------------------------------
-- BUILD A LIST OF TEAMS + NEEDS => PRIORITY QUEUE
--------------------------------------------------------------------------------
local function get_all_teams_and_needs()
    local league_team_links = league_team_links_global
    if not league_team_links then
        return {}
    end

    local all_entries = {}
    local team_needs_cache = {}

    -- Pre-cache league-team mapping
    local league_teams = {}
    local league_team_links_record = league_team_links:GetFirstRecord()
    while league_team_links_record > 0 do
        local league_id_field = league_team_links:GetRecordFieldValue(league_team_links_record, "leagueid")
        local team_id_field = league_team_links:GetRecordFieldValue(league_team_links_record, "teamid")
        if league_id_field and team_id_field and not config.excluded_teams[team_id_field] then
            league_teams[league_id_field] = league_teams[league_id_field] or {}
            table.insert(league_teams[league_id_field], team_id_field)
        end
        league_team_links_record = league_team_links:GetNextValidRecord()
    end

    -- Process each league's teams
    for _, league_id in ipairs(config.target_leagues) do
        local teams = league_teams[league_id] or {}
        for _, team_id in ipairs(teams) do
            if not team_needs_cache[team_id] then
                local team_size = get_team_size(team_id)
                if team_size < config.squad_size then
                    team_needs_cache[team_id] = compute_team_needs(team_id)
                else
                    team_needs_cache[team_id] = {}
                    LOGGER:LogInfo(string.format("Team %d is full. Skipping all future needs.", team_id))
                end
            end

            for _, role_name in ipairs(team_needs_cache[team_id]) do
                table.insert(all_entries, { team_id = team_id, role = role_name, league_id = league_id, weight = 10 })
            end
        end
    end

    table.sort(all_entries, function(a, b) return a.weight > b.weight end)
    return all_entries
end



--------------------------------------------------------------------------------
-- BUILD LIST OF ELIGIBLE FREE AGENTS FOR EACH LEAGUE
--------------------------------------------------------------------------------

local function cache_player_data(players_table)
    local player_data = {}
    local player_record = players_table:GetFirstRecord()

    while player_record > 0 do
        local player_id = players_table:GetRecordFieldValue(player_record, "playerid")
        if player_id then
            local overall = players_table:GetRecordFieldValue(player_record, "overallrating") or
                            players_table:GetRecordFieldValue(player_record, "overall") or 0
            local potential = players_table:GetRecordFieldValue(player_record, "potential") or 0
            local birthdate = players_table:GetRecordFieldValue(player_record, "birthdate")
            local preferred_position_1 = players_table:GetRecordFieldValue(player_record, "preferredposition1")

            local role_name = preferred_position_1 and get_role_name_from_position_id(preferred_position_1) or nil
            if role_name then
                player_data[player_id] = {
                    overall = overall,
                    potential = potential,
                    birthdate = birthdate,
                    roleName = role_name
                }
            end
        end
        player_record = players_table:GetNextValidRecord()
    end

    return player_data
end

local function filter_free_agents(team_player_links, player_data, results)
    local team_player_links_record = team_player_links:GetFirstRecord()

    while team_player_links_record > 0 do
        local team_id = team_player_links:GetRecordFieldValue(team_player_links_record, "teamid")
        local player_id = team_player_links:GetRecordFieldValue(team_player_links_record, "playerid")

        if team_id == config.transfer.from_team_id and player_data[player_id] then
            local data = player_data[player_id]
            local age = calculate_player_age(data.birthdate)

            if age >= config.age_constraints.min and age <= config.age_constraints.max then
                for _, league_id in ipairs(config.target_leagues) do
                    local constraints = config.league_constraints[league_id]
                    local min_overall, max_overall, min_potential, max_potential = constraints.min_overall, constraints.max_overall, constraints.min_potential, constraints.max_potential
                    if data.overall >= min_overall and data.overall <= max_overall and
                       data.potential >= min_potential and data.potential <= max_potential and
                       data.roleName then
                        table.insert(results[league_id], { playerid = player_id, roleName = data.roleName })
                    end
                end
            end
        end

        team_player_links_record = team_player_links:GetNextValidRecord()
    end
end

local function shuffle_free_agents(results)
    for _, league_id in ipairs(config.target_leagues) do
        local free_agents_list = results[league_id]
        for current_index = #free_agents_list, 2, -1 do
            local random_index = math.random(current_index)
            free_agents_list[current_index], free_agents_list[random_index] = free_agents_list[random_index], free_agents_list[current_index]
        end
    end
end

local function build_free_agents_for_leagues()
    local results = {}
    for _, league_id in ipairs(config.target_leagues) do
        results[league_id] = {}
    end

    if not players_table_global or not team_player_links_global then
        return results
    end

    local player_data = cache_player_data(players_table_global)
    filter_free_agents(team_player_links_global, player_data, results)
    shuffle_free_agents(results)

    return results
end

--------------------------------------------------------------------------------
-- ACTUAL TRANSFER MECHANISM
--------------------------------------------------------------------------------
local function find_candidate(free_agents_list, role_required)
    for index, free_agent in ipairs(free_agents_list) do
        if free_agent.roleName == role_required then
            return index
        end
    end
    return nil
end

local function update_player_preferred_position_1(player_id, new_role_id_1)
    local players_table_record = players_table_global:GetFirstRecord()
    
    while players_table_record > 0 do
        local current_player_id = players_table_global:GetRecordFieldValue(players_table_record, "playerid")
        if current_player_id == player_id then
            local old_role_id = players_table_global:GetRecordFieldValue(players_table_record, "preferredposition1")
            local player_preferred_position_2 = players_table_global:GetRecordFieldValue(players_table_record, "preferredposition2")
            local player_preferred_position_3 = players_table_global:GetRecordFieldValue(players_table_record, "preferredposition3")

            players_table_global:SetRecordFieldValue(players_table_record, "preferredposition1", new_role_id_1)
            LOGGER:LogInfo(string.format("Updated player %d's preferred position 1 to %d.", player_id, new_role_id_1))

            -- if a gk set 2nd and 3rd role as nothing and 1st as gk (0)
            if new_role_id_1 == 0 then
                LOGGER:LogInfo(string.format("Player %d is a gk setting preferred positon to gk with 2 and 3 as nothing", player_id))
                players_table_global:SetRecordFieldValue(players_table_record, "preferredposition1", 0)
                players_table_global:SetRecordFieldValue(players_table_record, "preferredposition2", -1)
                players_table_global:SetRecordFieldValue(players_table_record, "preferredposition3", -1)
                return
            end

            -- If the player's preferred position 2 or 3 is the new role, update it to the old role 
            if player_preferred_position_2 == new_role_id_1 then
                players_table_global:SetRecordFieldValue(players_table_record, "preferredposition2", old_role_id)
                LOGGER:LogInfo(string.format("Updated player %d's preferred position 2 to the old role (%d)", player_id, old_role_id))
            end
            if player_preferred_position_3 == new_role_id_1 then
                players_table_global:SetRecordFieldValue(players_table_record, "preferredposition3", old_role_id)
                LOGGER:LogInfo(string.format("Updated player %d's preferred position 3 to the old role (%d)", player_id, old_role_id))
            end

            return
        end
        players_table_record = players_table_global:GetNextValidRecord()
    end
    LOGGER:LogWarning(string.format("Player record for ID %d not found. Could not update preferred position.", player_id))
end

local function update_all_player_roles(player_id, new_role_id_1, new_role_id_2, new_role_id_3)
    local players_table_record = players_table_global:GetFirstRecord()
    while players_table_record > 0 do
        local current_player_id = players_table_global:GetRecordFieldValue(players_table_record, "playerid")
        if current_player_id == player_id then
            local current_players_pos = players_table_global:GetRecordFieldValue(players_table_record, "preferredposition1")
            -- if a gk set 3rd role as nothing
            if current_players_pos == 0 then
                new_role_id_3 = 0
            end

            players_table_global:SetRecordFieldValue(players_table_record, "role1", new_role_id_1)
            players_table_global:SetRecordFieldValue(players_table_record, "role2", new_role_id_2)
            players_table_global:SetRecordFieldValue(players_table_record, "role3", new_role_id_3)
            LOGGER:LogInfo(string.format("Updated player %d's roles to %d,%d and %d.", player_id, new_role_id_1, new_role_id_2, new_role_id_3))
            return
        end
        players_table_record = players_table_global:GetNextValidRecord()
    end
    LOGGER:LogWarning(string.format("Player record for ID %d not found. Could not update preferred position.", player_id))
end

local function handle_player_transfer(player_id, team_id, role_required, league_id, free_agents_list, candidate_index, used_alternative, alternative_role_used)
    local player_name = GetPlayerName(player_id)
    local ok, error_message = pcall(function()
        if IsPlayerPresigned(player_id) then DeletePresignedContract(player_id) end
        if IsPlayerLoanedOut(player_id) then TerminateLoan(player_id) end

        TransferPlayer(player_id, team_id, config.transfer.sum, config.transfer.wage, config.transfer.contract_length, config.transfer.from_team_id, config.transfer.release_clause)
    end)

    if ok then
        LOGGER:LogInfo(string.format(
            "Transferred %s (%d) to team %s (%d) for role %s (league %d).",
            player_name, player_id, GetTeamName(team_id), team_id, role_required, league_id
        ))

        if used_alternative then
            LOGGER:LogInfo(string.format("Used alternative position '%s' instead of '%s'.", alternative_role_used, role_required))
            update_player_preferred_position_1(player_id, get_role_id_from_role_name(role_required))
            update_all_player_roles(player_id, config.positions_to_roles[alternative_role_used][1], config.positions_to_roles[alternative_role_used][2], config.positions_to_roles[alternative_role_used][3])
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

local function find_alternative_candidate(free_agents_list, role_required)
    local alternatives = config.alternative_positions[role_required]
    if not alternatives then return nil, false, nil end

    for _, alternative_role in ipairs(alternatives) do
        local candidate_index = find_candidate(free_agents_list, alternative_role)
        if candidate_index then
            return candidate_index, true, alternative_role
        end
    end
    return nil, false, nil
end


local function process_team_entry(entry, free_agents)
    local team_id, role_required, league_id = entry.team_id, entry.role, entry.league_id

    if get_team_size(team_id) >= config.squad_size then
        LOGGER:LogInfo(string.format("Team %d is full. Skipping.", team_id))
        return false
    end

    local free_agents_list = free_agents[league_id]
    local candidate_index = find_candidate(free_agents_list, role_required)
    local used_alternative, alternative_role_used = false, nil

    if not candidate_index then
        candidate_index, used_alternative, alternative_role_used = find_alternative_candidate(free_agents_list, role_required)
    end

    if candidate_index then
        local player_id = free_agents_list[candidate_index].playerid
        return handle_player_transfer(player_id, team_id, role_required, league_id, free_agents_list, candidate_index, used_alternative, alternative_role_used)
    else
        LOGGER:LogInfo(string.format(
            "No free agent found for role '%s' or alternatives in league %d.",
            role_required, league_id
        ))
        return false
    end
end

local function do_transfers()
    local priority_queue = get_all_teams_and_needs()
    if #priority_queue == 0 then
        MessageBox("No Team Needs", "No teams found with missing roles. Done.")
        return
    end

    local free_agents = build_free_agents_for_leagues()
    if not players_table_global then
        LOGGER:LogError("Players table not initialized. Aborting transfers.")
        return
    end

    local total_transfers = 0

    for _, team_entry in ipairs(priority_queue) do
        local transfer_successful = process_team_entry(team_entry, free_agents)
        if transfer_successful then
            total_transfers = total_transfers + 1
        end
    end

    MessageBox("Transfers Done", string.format(
        "Processed %d needs in priority queue. Total successful transfers: %d",
        #priority_queue, total_transfers
    ))
end

--------------------------------------------------------------------------------
-- MAIN SCRIPT
--------------------------------------------------------------------------------

math.randomseed(os.time())
LOGGER:LogInfo("Starting Multi-League Transfer Script...")

do_transfers()