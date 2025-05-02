--------------------------------------------------------------------------------
-- Optimal Formation Finder Script for FC 25 Live Editor
-- Determines the best formation for a given team based on player ratings
--------------------------------------------------------------------------------
require 'imports/career_mode/helpers'
require 'imports/other/helpers'

-- Get global database tables
local players_table_global      = LE.db:GetTable("players")
local team_player_links_global  = LE.db:GetTable("teamplayerlinks")
local formations_table_global   = LE.db:GetTable("formations")

--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------
-- Configuration table
local config = {
    -- Target team ID 
    target_team_id = 10,
    
    -- Show top N formations in results
    top_formations_to_show = 5,
    
    -- Clear cache before running (set to true to force recalculation)
    clear_cache = false
}

-- Position mappings
local position_config = {
    position_ids = {
        GK = {0}, CB = {5, 1, 4, 6}, RB = {3, 2}, LB = {7, 8},
        CDM = {10, 9, 11}, RM = {12}, CM = {14, 13, 15}, LM = {16},
        CAM = {18, 17, 19}, ST = {25, 20, 21, 22, 24, 26},
        RW = {23}, LW = {27}
    },
    -- Positions that can be used as alternatives (prefer higher rating)
    alternative_positions = {
        RB = {"LB"}, 
        LB = {"RB"},
        RM = {"LM", "RW", "LW"}, 
        LM = {"RM", "LW", "RW"},
        RW = {"LW", "RM", "LM"}, 
        LW = {"RW", "RM", "LM"}
    }
}

-- Create reverse position mapping for easy lookup
local position_name_by_id = {}
local position_id_by_name = {}
for name, ids in pairs(position_config.position_ids) do
    position_id_by_name[name] = ids[1] -- Use first ID as primary
    for _, pid in ipairs(ids) do
        position_name_by_id[pid] = name
    end
end

-- Cache for all formations
local all_formations = {}
-- Cache for team players
local team_players_cache = {}
-- Cache for player data
local player_data_cache = {}
-- Cache for formation evaluations
local formation_evaluations_cache = {}

--------------------------------------------------------------------------------
-- HELPER FUNCTIONS
--------------------------------------------------------------------------------
local function get_position_name_from_id(position_id)
    return position_name_by_id[position_id] or ("Unknown(" .. position_id .. ")")
end

local function get_position_id_from_name(position_name)
    return position_id_by_name[position_name] or -1
end

-- Get player data from the players table
local function get_player_data(player_id)
    -- Check cache first
    if player_data_cache[player_id] then
        return player_data_cache[player_id]
    end

    local rec = players_table_global:GetFirstRecord()
    while rec > 0 do
        local pid = players_table_global:GetRecordFieldValue(rec, "playerid")
        if pid == player_id then
            local rating = players_table_global:GetRecordFieldValue(rec, "overallrating") or 0
            local position_id = players_table_global:GetRecordFieldValue(rec, "preferredposition1")
            local position_name = get_position_name_from_id(position_id)
            
            local player_data = {
                id = player_id,
                overall = rating,
                position_id = position_id,
                position_name = position_name,
                name = GetPlayerName(player_id) or "Unknown Player"
            }
            
            -- Cache the result
            player_data_cache[player_id] = player_data
            return player_data
        end
        rec = players_table_global:GetNextValidRecord()
    end
    return nil
end

-- Get all players from a specific team with their ratings and positions
local function get_team_players(team_id)
    -- Check cache first
    if team_players_cache[team_id] then
        LOGGER:LogInfo("Using cached team players data")
        return team_players_cache[team_id].players, team_players_cache[team_id].players_by_position
    end

    local players = {}
    local players_by_position = {}
    
    -- First, find all players linked to this team
    local rec = team_player_links_global:GetFirstRecord()
    while rec > 0 do
        local tid = team_player_links_global:GetRecordFieldValue(rec, "teamid")
        if tid == team_id then
            local player_id = team_player_links_global:GetRecordFieldValue(rec, "playerid")
            local player_data = get_player_data(player_id)
            if player_data then
                table.insert(players, player_data)
                
                -- Index players by position for faster lookups
                local pos_name = player_data.position_name
                if pos_name then
                    players_by_position[pos_name] = players_by_position[pos_name] or {}
                    table.insert(players_by_position[pos_name], player_data)
                end
            end
        end
        rec = team_player_links_global:GetNextValidRecord()
    end
    
    -- Sort players in each position by overall rating (highest first)
    for pos, players_list in pairs(players_by_position) do
        table.sort(players_list, function(a, b) return a.overall > b.overall end)
    end
    
    -- Cache the result
    team_players_cache[team_id] = {
        players = players,
        players_by_position = players_by_position
    }
    
    LOGGER:LogInfo(string.format("Found %d players for team %d", #players, team_id))
    return players, players_by_position
end

-- Get all available formations from the formations table
local function get_all_formations()
    if #all_formations > 0 then
        return all_formations
    end
    
    local formations = {}
    local seen_formations = {}
    
    -- Get the database records in a more efficient manner
    local positions_cache = {}
    
    local rec = formations_table_global:GetFirstRecord()
    while rec > 0 do
        local positions = {}
        local formation_id = formations_table_global:GetRecordFieldValue(rec, "formationid")
        
        -- Build positions array
        for i = 0, 10 do
            local field_name = ("position%d"):format(i)
            local position_id = formations_table_global:GetRecordFieldValue(rec, field_name) or 0
            
            -- Cache position name lookup
            if not positions_cache[position_id] then
                positions_cache[position_id] = get_position_name_from_id(position_id)
            end
            
            table.insert(positions, {
                id = position_id, 
                name = positions_cache[position_id]
            })
        end
        
        -- Create a unique key for this formation based on positions
        local formation_key = ""
        for _, pos in ipairs(positions) do
            formation_key = formation_key .. pos.name .. ","
        end
        
        -- Only add unique formations
        if not seen_formations[formation_key] then
            table.insert(formations, {
                positions = positions,
                formation_id = formation_id,
                key = formation_key
            })
            seen_formations[formation_key] = true
        end
        
        rec = formations_table_global:GetNextValidRecord()
    end
    
    all_formations = formations
    LOGGER:LogInfo(string.format("Found %d unique formations", #formations))
    return formations
end

-- Find best player for a position, considering alternatives if needed
local function find_best_player_for_position(position_name, players_by_position, used_players)
    local best_player = nil
    local best_rating = -1
    local from_alternative = false
    local alternative_used = nil
    local candidates = {}
    
    -- Check primary position first (direct lookup)
    if players_by_position[position_name] then
        for _, player in ipairs(players_by_position[position_name]) do
            if not used_players[player.id] then
                table.insert(candidates, {
                    player = player,
                    rating = player.overall,
                    from_alternative = false
                })
            end
        end
    end
    
    -- Check alternative positions if configured
    local alternatives = position_config.alternative_positions[position_name]
    if alternatives then
        for _, alt_position in ipairs(alternatives) do
            if players_by_position[alt_position] then
                for _, player in ipairs(players_by_position[alt_position]) do
                    if not used_players[player.id] then
                        table.insert(candidates, {
                            player = player,
                            rating = player.overall,
                            from_alternative = true,
                            alternative_used = alt_position
                        })
                    end
                end
            end
        end
    end
    
    -- Find player with highest rating among all candidates
    table.sort(candidates, function(a, b) return a.rating > b.rating end)
    
    if #candidates > 0 then
        best_player = candidates[1].player
        best_rating = candidates[1].rating
        from_alternative = candidates[1].from_alternative
        alternative_used = candidates[1].alternative_used
    end
    
    return best_player, from_alternative, alternative_used
end

-- Evaluate a formation with the current team roster
local function evaluate_formation(formation, players_by_position)
    local total_rating = 0
    local used_players = {}
    local selected_players = {}
    
    for i, position in ipairs(formation.positions) do
        local player, from_alternative, alternative_used = find_best_player_for_position(
            position.name, players_by_position, used_players)
        
        if player then
            total_rating = total_rating + player.overall
            used_players[player.id] = true
            
            table.insert(selected_players, {
                player = player,
                position = position.name,
                from_alternative = from_alternative,
                alternative_used = alternative_used
            })
        else
            -- Missing a player for this position - major penalty
            total_rating = total_rating - 50
            table.insert(selected_players, {
                player = nil,
                position = position.name
            })
        end
    end
    
    local avg_rating = #selected_players > 0 and (total_rating / #selected_players) or 0
    
    return {
        formation = formation,
        average_rating = avg_rating,
        total_rating = total_rating,
        lineup = selected_players
    }
end

-- Find the optimal formation for a team
local function find_optimal_formation(team_id)
    -- Check cache first
    if formation_evaluations_cache[team_id] then
        LOGGER:LogInfo("Using cached formation evaluations")
        local cached = formation_evaluations_cache[team_id]
        return cached[1], cached
    end

    local start_time = os.time()
    
    -- Get team players and all available formations
    local players, players_by_position = get_team_players(team_id)
    local formations = get_all_formations()
    
    if #players == 0 then
        LOGGER:LogWarning(string.format("No players found for team %d", team_id))
        return nil
    end
    
    -- Evaluate each formation
    local evaluations = {}
    for i, formation in ipairs(formations) do
        local result = evaluate_formation(formation, players_by_position)
        table.insert(evaluations, result)
        
        -- Log progress for large operations
        if i % 10 == 0 then
            LOGGER:LogInfo(string.format("Evaluated %d/%d formations", i, #formations))
        end
    end
    
    -- Sort by average rating (highest first)
    table.sort(evaluations, function(a, b) return a.average_rating > b.average_rating end)
    
    -- Cache the results
    formation_evaluations_cache[team_id] = evaluations
    
    local elapsed = os.time() - start_time
    LOGGER:LogInfo(string.format("Evaluated %d formations in %d seconds", #formations, elapsed))
    
    return evaluations[1], evaluations
end

-- Generate a human-readable formation display (e.g., "4-3-3")
local function get_formation_display(positions)
    local positions_counts = {}
    
    for _, position in ipairs(positions) do
        positions_counts[position.name] = (positions_counts[position.name] or 0) + 1
    end
    
    local defense_count = (positions_counts["CB"] or 0) + (positions_counts["RB"] or 0) + (positions_counts["LB"] or 0)
    local midfield_count = (positions_counts["CDM"] or 0) + (positions_counts["CM"] or 0) + 
                           (positions_counts["RM"] or 0) + (positions_counts["LM"] or 0) + 
                           (positions_counts["CAM"] or 0)
    local attack_count = (positions_counts["ST"] or 0) + (positions_counts["RW"] or 0) + (positions_counts["LW"] or 0)
    
    return string.format("%d-%d-%d", defense_count, midfield_count, attack_count)
end

-- Display the optimal formation results
local function display_results(team_id, best_result, all_results)
    local team_name = GetTeamName(team_id)
    
    -- Create a friendly display of the formation
    local formation_display = get_formation_display(best_result.formation.positions)
    
    -- Build detailed lineup message
    local lineup_msg = string.format("Optimal Formation for %s: %s (Avg Rating: %.2f)\n\n", 
        team_name, formation_display, best_result.average_rating)
    
    lineup_msg = lineup_msg .. "Starting XI:\n"
    
    for i, selection in ipairs(best_result.lineup) do
        if selection.player then
            local position_info = selection.position
            if selection.from_alternative then
                position_info = string.format("%s (natural: %s)", selection.position, selection.alternative_used)
            end
            
            lineup_msg = lineup_msg .. string.format("%d. %s - %s (%d OVR)\n", 
                i, position_info, selection.player.name, selection.player.overall)
        else
            lineup_msg = lineup_msg .. string.format("%d. %s - NO PLAYER AVAILABLE\n", i, selection.position)
        end
    end
    
    -- Show top formations
    lineup_msg = lineup_msg .. string.format("\nTop %d Formations:\n", config.top_formations_to_show)
    for i = 1, math.min(config.top_formations_to_show, #all_results) do
        local result = all_results[i]
        local form_display = get_formation_display(result.formation.positions)
        
        lineup_msg = lineup_msg .. string.format("%d. %s - %.2f avg rating\n", 
            i, form_display, result.average_rating)
    end
    
    -- Show the results
    MessageBox("Optimal Formation Results", lineup_msg)
end

-- Function to clear all caches if needed
local function clear_all_caches()
    LOGGER:LogInfo("Clearing all caches")
    player_data_cache = {}
    team_players_cache = {}
    formation_evaluations_cache = {}
end

--------------------------------------------------------------------------------
-- MAIN SCRIPT EXECUTION
--------------------------------------------------------------------------------
local function main()
    LOGGER:LogInfo("Starting Optimal Formation Finder...")
    
    -- Clear caches if configured to do so
    if config.clear_cache then
        clear_all_caches()
    end
    
    -- Validate team exists before proceeding
    local team_name = GetTeamName(config.target_team_id)
    if not team_name or team_name == "" then
        MessageBox("Error", string.format("Invalid team ID: %d. Please set a valid team ID in the config.", config.target_team_id))
        return
    end
    
    -- Get the optimal formation for the target team
    local best_result, all_results = find_optimal_formation(config.target_team_id)
    
    if best_result then
        -- Display the results
        display_results(config.target_team_id, best_result, all_results)
    else
        MessageBox("Error", string.format("Failed to find optimal formation for team %d", config.target_team_id))
    end
end

-- Execute the main function
main()
