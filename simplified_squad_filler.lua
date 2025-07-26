--------------------------------------------------------------------------------
-- Simplified Squad Filler Script for FC 25 Live Editor
-- Transfers players to teams with smallest squad sizes
--------------------------------------------------------------------------------
require 'imports/career_mode/helpers'
require 'imports/other/helpers'

local players_table_global   = LE.db:GetTable("players")
local team_player_links_global = LE.db:GetTable("teamplayerlinks")
local league_team_links_global = LE.db:GetTable("leagueteamlinks")

--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------
local config = {
    positions_to_roles = {
        GK = {1, 2, 0}, -- Goalkeeper, Sweeperkeeper, None
        CB = {11, 12, 13}, -- Defender, Stopper, Ball-playing Defender
        RB = {3, 4, 5}, -- Fullback, Falseback, Wingback
        LB = {7, 8, 9}, -- Fullback, Falseback, Wingback
        CDM = {14, 15, 16}, -- Holding, Centre-half, Deep-lying Playmaker
        RM = {23, 24, 26}, -- Winger, Wide Midfielder, Inside Forward
        CM = {18, 19, 20}, -- Box-to-box, Holding, Deep-lying Playmaker
        LM = {27, 28, 30}, -- Winger, Wide Midfielder, Inside Forward
        CAM = {31, 32, 33}, -- Playmaker, Shadow Striker, Half-Winger
        ST = {41, 42, 43}, -- Advanced Forward, Poacher, False Nine 
        RW = {35, 36, 37}, -- Winger, Inside Forward, Wide Playmaker
        LW = {38, 39, 40} -- Winger, Inside Forward, Wide Playmaker
    },
    position_ids = {
        GK = {0}, CB = {5, 1, 4, 6}, RB = {3, 2}, LB = {7, 8},
        CDM = {10, 9, 11}, RM = {12}, CM = {14, 13, 15}, LM = {16},
        CAM = {18, 17, 19}, ST = {25, 20, 21, 22, 24, 26},
        RW = {23}, LW = {27}
    },
    age_constraints = {min = 16, max = 35},
    max_squad_size = 52,  -- Absolute maximum squad size (hard limit)
    target_squad_size = 27, -- Target squad size to fill teams up to
    target_leagues = {61,60,14,13,16,17,19,20,2076,31,32,10,83,53,54,353,351,80,4,2012,1,2149,41,66,308,65,330,350,50,56,189,68,39},
    excluded_teams = { [110] = true },
    transfer = {
        sum = 0,
        wage = 600,
        contract_length = 24,
        release_clause = -1,
        from_team_id = 111592
    },
    lower_bound_minus = 1, -- Range subtracted from team's median rating
    upper_bound_plus = 1,  -- Range added to team's 75th percentile rating
    youth_player = {
        max_age = 23,      -- Maximum age for youth players
        potential_bonus = 5 -- Potential must be >= team median + this value
    }
}

-- Pre-compute position mappings for faster lookups
local position_name_by_id = {}
for name, ids in pairs(config.position_ids) do
    for _, pid in ipairs(ids) do
        position_name_by_id[pid] = name
    end
end

--------------------------------------------------------------------------------
-- CACHING SYSTEM FOR PERFORMANCE
--------------------------------------------------------------------------------
local cache = {
    team_sizes = {},
    team_ratings = {},
    team_names = {},
    player_names = {},
    player_data = {},
    league_teams = {},
    teams_needing_players = {}
}

-- Build comprehensive player data cache
local function build_player_cache()
    if next(cache.player_data) ~= nil then return end
    
    LOGGER:LogInfo("Building player data cache...")
    local player_count = 0
    local rec = players_table_global:GetFirstRecord()
    while rec > 0 do
        local pid = players_table_global:GetRecordFieldValue(rec, "playerid")
        if pid then
            cache.player_data[pid] = {
                overall = players_table_global:GetRecordFieldValue(rec, "overallrating") or 0,
                birthdate = players_table_global:GetRecordFieldValue(rec, "birthdate"),
                preferred_position = players_table_global:GetRecordFieldValue(rec, "preferredposition1"),
                record_id = rec
            }
            player_count = player_count + 1
        end
        rec = players_table_global:GetNextValidRecord()
    end
    LOGGER:LogInfo(string.format("Cached %d players.", player_count))
end

-- Build league-team mapping cache
local function build_league_cache()
    if next(cache.league_teams) ~= nil then return end
    
    LOGGER:LogInfo("Building league-team cache...")
    local record = league_team_links_global:GetFirstRecord()
    while record > 0 do
        local league_id = league_team_links_global:GetRecordFieldValue(record, "leagueid")
        local team_id = league_team_links_global:GetRecordFieldValue(record, "teamid")
        if league_id and team_id and not config.excluded_teams[team_id] then
            cache.league_teams[league_id] = cache.league_teams[league_id] or {}
            table.insert(cache.league_teams[league_id], team_id)
        end
        record = league_team_links_global:GetNextValidRecord()
    end
end

-- Build team size cache
local function build_team_size_cache()
    LOGGER:LogInfo("Building team size cache...")
    cache.team_sizes = {}
    local rec = team_player_links_global:GetFirstRecord()
    while rec > 0 do
        local team_id = team_player_links_global:GetRecordFieldValue(rec, "teamid")
        if team_id then
            cache.team_sizes[team_id] = (cache.team_sizes[team_id] or 0) + 1
        end
        rec = team_player_links_global:GetNextValidRecord()
    end
end

-- Build team rating bounds cache
local function build_team_ratings_cache()
    LOGGER:LogInfo("Building team ratings cache...")
    cache.team_ratings = {}
    
    -- Group players by team
    local team_players = {}
    local rec = team_player_links_global:GetFirstRecord()
    while rec > 0 do
        local team_id = team_player_links_global:GetRecordFieldValue(rec, "teamid")
        local player_id = team_player_links_global:GetRecordFieldValue(rec, "playerid")
        if team_id and player_id then
            team_players[team_id] = team_players[team_id] or {}
            table.insert(team_players[team_id], player_id)
        end
        rec = team_player_links_global:GetNextValidRecord()
    end
    
    -- Calculate ratings for each team
    for team_id, player_ids in pairs(team_players) do
        local ratings = {}
        for _, player_id in ipairs(player_ids) do
            local player_data = cache.player_data[player_id]
            if player_data and player_data.overall then
                table.insert(ratings, player_data.overall)
            end
        end
        
        if #ratings > 0 then
            table.sort(ratings)
            local n = #ratings
            local i50, i75 = math.ceil(0.5 * n), math.ceil(0.75 * n)
            local p50, p75 = math.floor(ratings[i50] + 0.5), math.floor(ratings[i75] + 0.5)
            local lb, ub = p50 - config.lower_bound_minus, p75 + config.upper_bound_plus
            
            cache.team_ratings[team_id] = {lb, ub, p50, p75} -- Store median and 75th percentile for logging
        end
    end
end

-- Initialize all caches
local function initialize_caches()
    build_player_cache()
    build_league_cache()
    build_team_size_cache()
    build_team_ratings_cache()
    LOGGER:LogInfo("All caches initialized.")
end

--------------------------------------------------------------------------------
-- HELPER METHODS
--------------------------------------------------------------------------------
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

-- Cached helper functions for performance
local function get_cached_team_name(team_id)
    if not cache.team_names[team_id] then
        cache.team_names[team_id] = GetTeamName(team_id)
    end
    return cache.team_names[team_id]
end

local function get_cached_player_name(player_id)
    if not cache.player_names[player_id] then
        cache.player_names[player_id] = GetPlayerName(player_id)
    end
    return cache.player_names[player_id]
end

local function get_team_size_cached(team_id)
    return cache.team_sizes[team_id] or 0
end

local function update_team_size_cache(team_id, change)
    cache.team_sizes[team_id] = (cache.team_sizes[team_id] or 0) + change
end

local function update_player_roles_cached(player_id, position_name)
    local roles = config.positions_to_roles[position_name]
    if not roles then 
        LOGGER:LogWarning(string.format("No roles found for position %s", position_name))
        return 
    end
    
    local player_data = cache.player_data[player_id]
    if not player_data then
        LOGGER:LogWarning(string.format("Player %d not found in cache. Could not update roles.", player_id))
        return
    end
    
    local pos = player_data.preferred_position
    local r1, r2, r3 = roles[1], roles[2], roles[3]
    if pos == 0 then r3 = 0 end -- Goalkeeper special case
    
    -- Use cached record ID for direct access
    local rec = player_data.record_id
    if rec and rec > 0 then
        players_table_global:SetRecordFieldValue(rec, "role1", r1)
        players_table_global:SetRecordFieldValue(rec, "role2", r2)
        players_table_global:SetRecordFieldValue(rec, "role3", r3)
    end
end

local function get_team_rating_bounds_cached(team_id)
    local bounds = cache.team_ratings[team_id]
    if bounds then
        return bounds[1], bounds[2], bounds[3], bounds[4] -- min_rating, max_rating, median_rating, p75_rating
    end
    return nil, nil, nil, nil
end

local function get_team_name_with_stats(team_id)
    local team_name = get_cached_team_name(team_id)
    local _, _, median_rating, p75_rating = get_team_rating_bounds_cached(team_id)
    
    if median_rating and p75_rating then
        return string.format("%s (Median: %d 75th: %d)", team_name, median_rating, p75_rating)
    else
        return team_name
    end
end

--------------------------------------------------------------------------------
-- GET ALL ELIGIBLE TEAMS SORTED BY SQUAD SIZE (CACHED)
--------------------------------------------------------------------------------
local function get_teams_by_squad_size_cached()
    local teams = {}
    
    -- Use cached league-team mapping
    for _, league_id in ipairs(config.target_leagues) do
        local teams_in_league = cache.league_teams[league_id] or {}
        for _, team_id in ipairs(teams_in_league) do
            local size = get_team_size_cached(team_id)
            if size < config.target_squad_size and size < config.max_squad_size then
                table.insert(teams, {team_id = team_id, squad_size = size})
            end
        end
    end
    
    -- Sort by squad size (smallest first)
    table.sort(teams, function(a, b) return a.squad_size < b.squad_size end)
    
    return teams
end

--------------------------------------------------------------------------------
-- GET ELIGIBLE FREE AGENTS (CACHED)
--------------------------------------------------------------------------------
local function get_eligible_free_agents_cached()
    local free_agents = {}
    
    -- Find players in the source team using cached data
    local rec = team_player_links_global:GetFirstRecord()
    while rec > 0 do
        local t_id = team_player_links_global:GetRecordFieldValue(rec, "teamid")
        local p_id = team_player_links_global:GetRecordFieldValue(rec, "playerid")
        
        if t_id == config.transfer.from_team_id and p_id then
            local player_data = cache.player_data[p_id]
            if player_data then
                local age = calculate_player_age(player_data.birthdate)
                
                if age >= config.age_constraints.min and age <= config.age_constraints.max then
                    local pos_name = get_position_name_from_position_id(player_data.preferred_position)
                    table.insert(free_agents, {
                        playerid = p_id,
                        overall = player_data.overall,
                        age = age,
                        position_name = pos_name
                    })
                end
            end
        end
        rec = team_player_links_global:GetNextValidRecord()
    end
    
    -- Shuffle the free agents to add randomness
    for i = #free_agents, 2, -1 do
        local j = math.random(i)
        free_agents[i], free_agents[j] = free_agents[j], free_agents[i]
    end
    
    return free_agents
end

--------------------------------------------------------------------------------
-- FIND SUITABLE PLAYER FOR TEAM
--------------------------------------------------------------------------------
local function find_suitable_player(team_id, free_agents, min_rating, max_rating)
    for i, player in ipairs(free_agents) do
        if player.overall >= min_rating and player.overall <= max_rating then
            return i, player
        end
    end
    return nil, nil
end

--------------------------------------------------------------------------------
-- FIND SUITABLE YOUTH PLAYER FOR TEAM
--------------------------------------------------------------------------------
local function find_suitable_youth_player(team_id, free_agents, median_rating)
    local min_potential = median_rating + config.youth_player.potential_bonus
    
    for i, player in ipairs(free_agents) do
        if player.age <= config.youth_player.max_age then
            -- Get player's potential from cache
            local player_data = cache.player_data[player.playerid]
            if player_data then
                local potential = players_table_global:GetRecordFieldValue(player_data.record_id, "potential") or 0
                if potential >= min_potential then
                    return i, player, potential
                end
            end
        end
    end
    return nil, nil, nil
end

--------------------------------------------------------------------------------
-- TRANSFER PLAYER TO TEAM
--------------------------------------------------------------------------------
local function transfer_player_to_team_cached(player, team_id, free_agents, player_index, is_youth_transfer, player_potential, team_median)
    local player_id = player.playerid
    local player_name = get_cached_player_name(player_id)
    local team_name_with_stats = get_team_name_with_stats(team_id)
    local old_squad_size = get_team_size_cached(team_id)
    
    local ok, error_message = pcall(function()
        if IsPlayerPresigned(player_id) then DeletePresignedContract(player_id) end
        if IsPlayerLoanedOut(player_id) then TerminateLoan(player_id) end
        
        TransferPlayer(player_id, team_id, config.transfer.sum, config.transfer.wage, 
                      config.transfer.contract_length, config.transfer.from_team_id, 
                      config.transfer.release_clause)
        
        -- Update player roles based on their position
        if player.position_name then
            update_player_roles_cached(player_id, player.position_name)
        end
        
        -- Update caches after successful transfer
        update_team_size_cache(team_id, 1)
        update_team_size_cache(config.transfer.from_team_id, -1)
    end)
    
    if ok then
        local new_squad_size = old_squad_size + 1
        
        if is_youth_transfer and player_potential and team_median then
            LOGGER:LogInfo(string.format("✓ YOUTH TRANSFER: %s (%d, rating: %d → potential: %d, age: %d) to team %s (%d). Team median: %d. Squad size: %d -> %d.",
                player_name, player_id, player.overall, player_potential, player.age, team_name_with_stats, team_id, team_median, old_squad_size, new_squad_size))
        else
            LOGGER:LogInfo(string.format("Successfully transferred %s (%d, rating: %d, age: %d) to team %s (%d). Squad size: %d -> %d.",
                player_name, player_id, player.overall, player.age, team_name_with_stats, team_id, old_squad_size, new_squad_size))
        end
        
        -- Remove the transferred player from the free agents list
        table.remove(free_agents, player_index)
        return true
    else
        LOGGER:LogWarning(string.format("Failed to transfer player %s (%d) to team %s (%d). Error: %s",
            player_name, player_id, team_name_with_stats, team_id, tostring(error_message)))
        return false
    end
end

--------------------------------------------------------------------------------
-- MAIN TRANSFER PROCESS
--------------------------------------------------------------------------------
local function do_simple_transfers()
    -- Initialize all caches first for performance
    LOGGER:LogInfo("Initializing caches for optimal performance...")
    initialize_caches()
    
    local free_agents = get_eligible_free_agents_cached()
    if #free_agents == 0 then
        MessageBox("No Free Agents", "No eligible free agents found.")
        return
    end
    
    local total_transfers = 0
    local start_time = os.time()
    local round = 1
    local permanently_failed_teams = {} -- Teams that permanently can't find suitable players
    
    LOGGER:LogInfo(string.format("Starting continuous transfers with %d free agents available. Target squad size: %d", 
        #free_agents, config.target_squad_size))
    LOGGER:LogInfo(string.format("Youth player fallback: age ≤%d, potential ≥ team_median+%d", 
        config.youth_player.max_age, config.youth_player.potential_bonus))
    
    local iteration = 1
    
    while true do
        -- Get fresh list of teams that still need players (sorted by smallest squad size)
        local all_teams = get_teams_by_squad_size_cached()
        
        if #all_teams == 0 then
            LOGGER:LogInfo("All teams have reached target squad size!")
            break
        end
        
        if #free_agents == 0 then
            LOGGER:LogInfo("No more free agents available!")
            break
        end
        
        -- Find the smallest squad size that has processable teams
        local smallest_squad_size = nil
        local teams_at_smallest_level = {}
        
        -- Group all non-excluded teams by squad size
        local teams_by_size = {}
        for _, team_info in ipairs(all_teams) do
            if not permanently_failed_teams[team_info.team_id] then
                local size = team_info.squad_size
                teams_by_size[size] = teams_by_size[size] or {}
                table.insert(teams_by_size[size], team_info)
            end
        end
        
        -- Find the smallest squad size that has teams
        local available_sizes = {}
        for size, _ in pairs(teams_by_size) do
            table.insert(available_sizes, size)
        end
        table.sort(available_sizes)
        
        if #available_sizes == 0 then
            LOGGER:LogInfo("No more processable teams at any squad size level.")
            break
        end
        
        smallest_squad_size = available_sizes[1]
        teams_at_smallest_level = teams_by_size[smallest_squad_size]
        
        LOGGER:LogInfo(string.format("Iteration %d: Processing %d teams with smallest squad size %d...", 
            iteration, #teams_at_smallest_level, smallest_squad_size))
        
        local transfers_this_iteration = 0
        local teams_processed = 0
        local teams_successful = 0
        
        for _, team_info in ipairs(teams_at_smallest_level) do
            local team_id = team_info.team_id
            
            -- Double-check team hasn't been permanently excluded
            if permanently_failed_teams[team_id] then
                goto continue_team
            end
            
            -- Get fresh squad size (might have changed due to rating cache invalidation)
            local current_squad_size = get_team_size_cached(team_id)
            
            -- Skip if team has reached target or is at max capacity
            if current_squad_size >= config.target_squad_size or current_squad_size >= config.max_squad_size then
                goto continue_team
            end
            
            -- Skip if team's squad size has changed since we started this iteration
            if current_squad_size ~= smallest_squad_size then
                LOGGER:LogInfo(string.format("Team %s (%d) squad size changed from %d to %d during iteration. Will be processed at correct level.", 
                    get_team_name_with_stats(team_id), team_id, smallest_squad_size, current_squad_size))
                goto continue_team
            end
            
            teams_processed = teams_processed + 1
            
            -- Get team rating bounds from cache
            local min_rating, max_rating, median_rating, p75_rating = get_team_rating_bounds_cached(team_id)
            local team_name_with_stats = get_team_name_with_stats(team_id)
            
            if not min_rating or not max_rating or not median_rating then
                LOGGER:LogInfo(string.format("Team %s (%d) - Could not determine rating bounds. Permanently skipping.", 
                    team_name_with_stats, team_id))
                permanently_failed_teams[team_id] = true
                goto continue_team
            end
            
            LOGGER:LogInfo(string.format("Team %s (%d) - Targeting players with rating %d-%d (squad size: %d)", 
                team_name_with_stats, team_id, min_rating, max_rating, current_squad_size))
            
            -- Find a suitable player
            local player_index, suitable_player = find_suitable_player(team_id, free_agents, min_rating, max_rating)
            local is_youth_transfer = false
            local player_potential = nil
            
            -- If no regular player found, try youth players
            if not player_index then
                local min_potential = median_rating + config.youth_player.potential_bonus
                LOGGER:LogInfo(string.format("Team %s (%d) - No regular player found. Searching for youth players (age ≤%d, potential ≥%d)...", 
                    team_name_with_stats, team_id, config.youth_player.max_age, min_potential))
                
                player_index, suitable_player, player_potential = find_suitable_youth_player(team_id, free_agents, median_rating)
                is_youth_transfer = true
            end
            
            if player_index and suitable_player then
                local success = transfer_player_to_team_cached(suitable_player, team_id, free_agents, player_index, is_youth_transfer, player_potential, median_rating)
                if success then
                    total_transfers = total_transfers + 1
                    transfers_this_iteration = transfers_this_iteration + 1
                    teams_successful = teams_successful + 1
                    -- Remove from failed list if somehow they were there
                    permanently_failed_teams[team_id] = nil
                else
                    LOGGER:LogInfo(string.format("Team %s (%d) - Transfer failed for technical reasons. Will retry in next iteration.", 
                        team_name_with_stats, team_id))
                    -- Don't mark as permanently failed for technical issues
                end
            else
                if is_youth_transfer then
                    LOGGER:LogInfo(string.format("Team %s (%d) - No suitable youth player found either. Permanently skipping.", 
                        team_name_with_stats, team_id))
                else
                    LOGGER:LogInfo(string.format("Team %s (%d) - No suitable player found in rating range %d-%d. Permanently skipping.", 
                        team_name_with_stats, team_id, min_rating, max_rating))
                end
                permanently_failed_teams[team_id] = true
            end
            
            ::continue_team::
        end
        
        -- Log iteration summary
        local elapsed = os.time() - start_time
        local permanently_excluded_count = 0
        for _ in pairs(permanently_failed_teams) do
            permanently_excluded_count = permanently_excluded_count + 1
        end
        
        LOGGER:LogInfo(string.format("Completed squad size %d: %d/%d teams successfully received players.", 
            smallest_squad_size, teams_successful, teams_processed))
        
        LOGGER:LogInfo(string.format("Iteration %d complete: %d transfers made. Total: %d transfers in %d seconds. Free agents left: %d. Teams permanently excluded: %d", 
            iteration, transfers_this_iteration, total_transfers, elapsed, #free_agents, permanently_excluded_count))
        
        -- If no transfers were made this iteration, check if we can continue with next level
        if transfers_this_iteration == 0 then
            LOGGER:LogInfo("No transfers made this iteration. Checking if higher squad size levels are available...")
            
            -- Check if there are any non-excluded teams at higher levels
            local has_higher_level_teams = false
            for _, team_info in ipairs(all_teams) do
                if team_info.squad_size > smallest_squad_size and not permanently_failed_teams[team_info.team_id] then
                    has_higher_level_teams = true
                    break
                end
            end
            
            if not has_higher_level_teams then
                LOGGER:LogInfo("No more teams available at any squad size level.")
                break
            end
        end
        
        iteration = iteration + 1
        
        -- Provide periodic updates for very long runs
        if iteration % 25 == 0 then
            LOGGER:LogInfo(string.format("Extended run: Iteration %d, Total transfers: %d, Time elapsed: %d seconds", 
                iteration, total_transfers, elapsed))
        end
        
        ::continue_iteration::
    end
    
    local final_teams = get_teams_by_squad_size_cached()
    local elapsed = os.time() - start_time
    local permanently_excluded_count = 0
    for _ in pairs(permanently_failed_teams) do
        permanently_excluded_count = permanently_excluded_count + 1
    end
    
    MessageBox("Transfers Complete", string.format(
        "Completed %d iterations in %d seconds.\nTotal successful transfers: %d\nFree agents remaining: %d\nTeams still needing players: %d\nTeams permanently excluded: %d", 
        iteration - 1, elapsed, total_transfers, #free_agents, #final_teams, permanently_excluded_count))
end

--------------------------------------------------------------------------------
-- MAIN SCRIPT EXECUTION
--------------------------------------------------------------------------------
math.randomseed(os.time())
LOGGER:LogInfo("Starting Simplified Squad Filler Script...")

do_simple_transfers() 