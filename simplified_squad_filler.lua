--------------------------------------------------------------------------------
-- Simplified Squad Filler Script for FC 25 Live Editor
-- 
-- Modular system for transferring players to teams with smallest squad sizes
-- Features:
--   • Strategic position group balancing (GK:DEF:MID:AM:ST ratios)
--   • Formation-aware player selection
--   • Youth player development pathway
--   • Comprehensive caching for performance
--   • Extensible search strategy system
--------------------------------------------------------------------------------
require 'imports/career_mode/helpers'
require 'imports/other/helpers'

local players_table_global   = LE.db:GetTable("players")
local team_player_links_global = LE.db:GetTable("teamplayerlinks")
local league_team_links_global = LE.db:GetTable("leagueteamlinks")
local formations_table_global = LE.db:GetTable("formations")

--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------

-- Core transfer settings
local TRANSFER_CONFIG = {
    age_constraints = {min = 16, max = 35},
    max_squad_size = 52,     -- Hard limit per team
    target_squad_size = 27,  -- Fill teams up to this size
    rating_variance = {lower_bound_minus = 1, upper_bound_plus = 1},
    youth_thresholds = {max_age = 23, potential_bonus = 5},
    source_team_id = 111592  -- Free agents pool
}

-- Player position system
local POSITION_SYSTEM = {
    -- Position ID mappings for database queries
    position_ids = {
        GK = {0}, CB = {5, 1, 4, 6}, RB = {3, 2}, LB = {7, 8},
        CDM = {10, 9, 11}, RM = {12}, CM = {14, 13, 15}, LM = {16},
        CAM = {18, 17, 19}, ST = {25, 20, 21, 22, 24, 26},
        RW = {23}, LW = {27}
    },
    -- Role assignments for each position
    roles = {
        GK = {1, 2, 0}, CB = {11, 12, 13}, RB = {3, 4, 5}, LB = {7, 8, 9},
        CDM = {14, 15, 16}, RM = {23, 24, 26}, CM = {18, 19, 20}, LM = {27, 28, 30},
        CAM = {31, 32, 33}, ST = {41, 42, 43}, RW = {35, 36, 37}, LW = {38, 39, 40}
    },
    -- Strategic position groupings with target ratios
    groups = {
        definitions = {
            GK = {"GK"}, DEF = {"CB", "LB", "RB"}, MID = {"CM", "CDM"},
            AM = {"RM", "LM", "RW", "LW", "CAM"}, ST = {"ST"}
        },
        ratios = {GK = 1, DEF = 2, MID = 2, AM = 2, ST = 1} -- Total: 8 parts
    }
}

-- League and team filtering
local TEAM_FILTER = {
    target_leagues = {61,60,14,13,16,17,19,20,2076,31,32,10,83,53,54,353,351,80,4,2012,1,2149,41,66,308,65,330,350,50,56,189,68,39},
    excluded_teams = {[110] = true},
    transfer_terms = {sum = 0, wage = 600, contract_length = 24, release_clause = -1}
}

-- Constants for readability
local SEARCH_STEPS = {
    PRIORITY_REGULAR = 1, PRIORITY_YOUTH = 2,
    FORMATION_REGULAR = 3, FORMATION_YOUTH = 4,
    ANY_REGULAR = 5, ANY_YOUTH = 6
}

local TOTAL_RATIO_PARTS = 8

--------------------------------------------------------------------------------
-- POSITION MAPPING INITIALIZATION
-- Pre-compute lookups for performance
--------------------------------------------------------------------------------
local position_name_by_id = {}
local position_to_group = {}

-- Build position ID to name mapping
for position_name, id_list in pairs(POSITION_SYSTEM.position_ids) do
    for _, position_id in ipairs(id_list) do
        position_name_by_id[position_id] = position_name
    end
end

-- Build position to strategic group mapping
for group_name, position_list in pairs(POSITION_SYSTEM.groups.definitions) do
    for _, position_name in ipairs(position_list) do
        position_to_group[position_name] = group_name
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
end

-- Build league-team mapping cache
local function build_league_cache()
    if next(cache.league_teams) ~= nil then return end
    
    local record = league_team_links_global:GetFirstRecord()
    while record > 0 do
        local league_id = league_team_links_global:GetRecordFieldValue(record, "leagueid")
        local team_id = league_team_links_global:GetRecordFieldValue(record, "teamid")
        if league_id and team_id and not TEAM_FILTER.excluded_teams[team_id] then
            cache.league_teams[league_id] = cache.league_teams[league_id] or {}
            table.insert(cache.league_teams[league_id], team_id)
        end
        record = league_team_links_global:GetNextValidRecord()
    end
end

-- Build team size cache
local function build_team_size_cache()
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
            local count = #ratings
            local median_index = math.ceil(0.5 * count)
            local p75_index = math.ceil(0.75 * count)
            local median = math.floor(ratings[median_index] + 0.5)
            local p75 = math.floor(ratings[p75_index] + 0.5)
            
            -- Apply rating variance for transfer targeting
            local min_rating = median - TRANSFER_CONFIG.rating_variance.lower_bound_minus
            local max_rating = p75 + TRANSFER_CONFIG.rating_variance.upper_bound_plus
            
            cache.team_ratings[team_id] = {min_rating, max_rating, median, p75}
        end
    end
end

-- Initialize all caches
local function initialize_caches()
    LOGGER:LogInfo("Initializing caches...")
    build_player_cache()
    build_league_cache()
    build_team_size_cache()
    build_team_ratings_cache()
    -- Formation cache is built on-demand to avoid unnecessary database reads
    LOGGER:LogInfo("Caches ready.")
end

--------------------------------------------------------------------------------
-- UTILITY FUNCTIONS
-- Core helper functions for data processing
--------------------------------------------------------------------------------

-- Convert position ID to readable name
local function get_position_name_from_id(position_id)
    return position_name_by_id[position_id] or ("UnknownPos(".. position_id ..")")
end

-- Calculate current age from birth date
local function calculate_player_age(birth_date)
    if not birth_date or birth_date <= 0 then return 20 end
    
    local current_date = GetCurrentDate()
    local birth_date_obj = DATE:new()
    birth_date_obj:FromGregorianDays(birth_date)
    
    local age = current_date.year - birth_date_obj.year
    
    -- Adjust if birthday hasn't occurred this year
    if current_date.month < birth_date_obj.month or 
       (current_date.month == birth_date_obj.month and current_date.day < birth_date_obj.day) then
        age = age - 1
    end
    
    return age
end

-- Check if player meets age requirements
local function is_valid_age(age)
    return age >= TRANSFER_CONFIG.age_constraints.min and age <= TRANSFER_CONFIG.age_constraints.max
end

--------------------------------------------------------------------------------
-- CACHED DATA ACCESS
-- Performance-optimized data retrieval functions
--------------------------------------------------------------------------------

-- Get team name with caching
local function get_cached_team_name(team_id)
    if not cache.team_names[team_id] then
        cache.team_names[team_id] = GetTeamName(team_id)
    end
    return cache.team_names[team_id]
end

-- Get player name with caching
local function get_cached_player_name(player_id)
    if not cache.player_names[player_id] then
        cache.player_names[player_id] = GetPlayerName(player_id)
    end
    return cache.player_names[player_id]
end

-- Get current team size from cache
local function get_team_size_cached(team_id)
    return cache.team_sizes[team_id] or 0
end

-- Update team size cache after transfers
local function update_team_size_cache(team_id, size_change)
    cache.team_sizes[team_id] = (cache.team_sizes[team_id] or 0) + size_change
end

-- Get team rating bounds with all statistics
local function get_team_rating_bounds_cached(team_id)
    local bounds = cache.team_ratings[team_id]
    if bounds then
        return bounds[1], bounds[2], bounds[3], bounds[4] -- min, max, median, p75
    end
    return nil, nil, nil, nil
end

-- Format team name with rating statistics for display
local function get_team_display_name(team_id)
    local team_name = get_cached_team_name(team_id)
    local _, _, median_rating, p75_rating = get_team_rating_bounds_cached(team_id)
    
    if median_rating and p75_rating then
        return string.format("%s (Median: %d 75th: %d)", team_name, median_rating, p75_rating)
    else
        return team_name
    end
end

-- Update player roles based on position
local function update_player_roles(player_id, position_name)
    local role_config = POSITION_SYSTEM.roles[position_name]
    if not role_config then 
        LOGGER:LogWarning(string.format("No roles found for position %s", position_name))
        return 
    end
    
    local player_data = cache.player_data[player_id]
    if not player_data then
        LOGGER:LogWarning(string.format("Player %d not found in cache", player_id))
        return
    end
    
    local role1, role2, role3 = role_config[1], role_config[2], role_config[3]
    
    -- Goalkeeper special case: no third role
    if player_data.preferred_position == 0 then 
        role3 = 0 
    end
    
    -- Update roles using cached record reference
    local record_id = player_data.record_id
    if record_id and record_id > 0 then
        players_table_global:SetRecordFieldValue(record_id, "role1", role1)
        players_table_global:SetRecordFieldValue(record_id, "role2", role2)
        players_table_global:SetRecordFieldValue(record_id, "role3", role3)
    end
end

--------------------------------------------------------------------------------
-- POSITION GROUP ANALYSIS
-- Strategic position balancing based on formation ratios
--------------------------------------------------------------------------------

-- Count current players by strategic group
local function count_players_by_group(team_id)
    local group_counts = {GK = 0, DEF = 0, MID = 0, AM = 0, ST = 0}
    
    local record = team_player_links_global:GetFirstRecord()
    while record > 0 do
        if team_player_links_global:GetRecordFieldValue(record, "teamid") == team_id then
            local player_id = team_player_links_global:GetRecordFieldValue(record, "playerid")
            local player_data = cache.player_data[player_id]
            
            if player_data and player_data.preferred_position then
                local position_name = get_position_name_from_id(player_data.preferred_position)
                local group_name = position_to_group[position_name]
                if group_name then
                    group_counts[group_name] = group_counts[group_name] + 1
                end
            end
        end
        record = team_player_links_global:GetNextValidRecord()
    end
    
    return group_counts
end

-- Calculate ideal group distribution based on squad size
local function calculate_group_targets(squad_size)
    local players_per_ratio_part = squad_size / TOTAL_RATIO_PARTS
    local group_targets = {}
    
    for group_name, ratio in pairs(POSITION_SYSTEM.groups.ratios) do
        local ideal_count = ratio * players_per_ratio_part
        group_targets[group_name] = {
            ideal = math.floor(ideal_count + 0.5), -- Round to nearest integer
            ratio = ratio
        }
    end
    
    return group_targets
end

-- Analyze position group needs and prioritize underrepresented groups
local function get_underrepresented_groups(team_id, squad_size)
    local current_counts = count_players_by_group(team_id)
    local target_counts = calculate_group_targets(squad_size)
    
    local group_analysis = {}
    local underrepresented_list = {}
    
    -- Analyze each position group
    for group_name, targets in pairs(target_counts) do
        local actual_count = current_counts[group_name] or 0
        local ideal_count = targets.ideal
        local shortfall_percentage = 0
        
        -- Calculate proportional shortfall (how underrepresented relative to ideal)
        if ideal_count > 0 then
            shortfall_percentage = math.max(0, (ideal_count - actual_count) / ideal_count)
        end
        
        group_analysis[group_name] = {
            actual = actual_count,
            ideal = ideal_count,
            shortfall = shortfall_percentage
        }
        
        -- Track groups that need more players
        if shortfall_percentage > 0 then
            table.insert(underrepresented_list, {
                group = group_name,
                shortfall = shortfall_percentage
            })
        end
    end
    
    -- Randomize order for equal shortfalls, then sort by priority
    for i = #underrepresented_list, 2, -1 do
        local j = math.random(i)
        underrepresented_list[i], underrepresented_list[j] = underrepresented_list[j], underrepresented_list[i]
    end
    
    table.sort(underrepresented_list, function(a, b)
        return a.shortfall > b.shortfall
    end)
    
    -- Extract prioritized group names
    local priority_groups = {}
    for _, entry in ipairs(underrepresented_list) do
        table.insert(priority_groups, entry.group)
    end
    
    return priority_groups, group_analysis
end

-- Get all positions within a strategic group
local function get_positions_in_group(group_name)
    return POSITION_SYSTEM.groups.definitions[group_name] or {}
end

--------------------------------------------------------------------------------
-- FORMATION ANALYSIS
-- Team formation-based position requirements
--------------------------------------------------------------------------------
local formation_cache = {}

-- Get outfield positions from team's formation (excludes GK)
local function get_formation_positions(team_id)
    -- Return cached result if available
    if formation_cache[team_id] then
        return formation_cache[team_id]
    end
    
    if not formations_table_global then
        formation_cache[team_id] = {}
        return {}
    end

    local record = formations_table_global:GetFirstRecord()
    while record > 0 do
        local current_team_id = formations_table_global:GetRecordFieldValue(record, "teamid")
        if current_team_id == team_id then
            local formation_positions = {}
            
            -- Extract all formation positions (0-10 slots)
            for slot_index = 0, 10 do
                local field_name = string.format("position%d", slot_index)
                local position_id = formations_table_global:GetRecordFieldValue(record, field_name) or 0
                local position_name = get_position_name_from_id(position_id)
                
                -- Include all outfield positions (exclude GK)
                if position_id ~= 0 and position_name ~= "GK" then
                    table.insert(formation_positions, position_name)
                end
            end
            
            formation_cache[team_id] = formation_positions
            return formation_positions
        end
        record = formations_table_global:GetNextValidRecord()
    end
    
    -- Cache empty result if team formation not found
    formation_cache[team_id] = {}
    return {}
end

--------------------------------------------------------------------------------
-- GET ALL ELIGIBLE TEAMS SORTED BY SQUAD SIZE (CACHED)
--------------------------------------------------------------------------------
local function get_teams_by_squad_size_cached()
    local teams = {}
    
    -- Use cached league-team mapping
    for _, league_id in ipairs(TEAM_FILTER.target_leagues) do
        local teams_in_league = cache.league_teams[league_id] or {}
        for _, team_id in ipairs(teams_in_league) do
            local current_size = get_team_size_cached(team_id)
            if current_size < TRANSFER_CONFIG.target_squad_size and current_size < TRANSFER_CONFIG.max_squad_size then
                table.insert(teams, {team_id = team_id, squad_size = current_size})
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
    local record = team_player_links_global:GetFirstRecord()
    while record > 0 do
        local team_id = team_player_links_global:GetRecordFieldValue(record, "teamid")
        local player_id = team_player_links_global:GetRecordFieldValue(record, "playerid")
        
        if team_id == TRANSFER_CONFIG.source_team_id and player_id then
            local player_data = cache.player_data[player_id]
            if player_data then
                local age = calculate_player_age(player_data.birthdate)
                
                if is_valid_age(age) then
                    local position_name = get_position_name_from_id(player_data.preferred_position)
                    table.insert(free_agents, {
                        playerid = player_id,
                        overall = player_data.overall,
                        age = age,
                        position_name = position_name
                    })
                end
            end
        end
        record = team_player_links_global:GetNextValidRecord()
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

-- Find suitable player prioritizing specific position group (NO FALLBACK)
local function find_suitable_player_by_group_only(team_id, free_agents, min_rating, max_rating, target_group)
    local target_positions = get_positions_in_group(target_group)
    
    -- Only try to find a player in the target group, no fallback
    for i, player in ipairs(free_agents) do
        if player.overall >= min_rating and player.overall <= max_rating then
            for _, target_position in ipairs(target_positions) do
                if player.position_name == target_position then
                    return i, player, target_group
                end
            end
        end
    end
    
    return nil, nil, nil
end

--------------------------------------------------------------------------------
-- FIND SUITABLE YOUTH PLAYER FOR TEAM
--------------------------------------------------------------------------------
local function find_suitable_youth_player(team_id, free_agents, median_rating)
    local min_potential = median_rating + TRANSFER_CONFIG.youth_thresholds.potential_bonus
    
    for i, player in ipairs(free_agents) do
        if player.age <= TRANSFER_CONFIG.youth_thresholds.max_age then
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

-- Find suitable youth player prioritizing specific position group (NO FALLBACK)
local function find_suitable_youth_player_by_group_only(team_id, free_agents, median_rating, target_group)
    local min_potential = median_rating + TRANSFER_CONFIG.youth_thresholds.potential_bonus
    local target_positions = get_positions_in_group(target_group)
    
    -- Only try to find a youth player in the target group, no fallback
    for i, player in ipairs(free_agents) do
        if player.age <= TRANSFER_CONFIG.youth_thresholds.max_age then
            local player_data = cache.player_data[player.playerid]
            if player_data then
                local potential = players_table_global:GetRecordFieldValue(player_data.record_id, "potential") or 0
                if potential >= min_potential then
                    for _, target_position in ipairs(target_positions) do
                        if player.position_name == target_position then
                            return i, player, potential, target_group
                        end
                    end
                end
            end
        end
    end
    
    return nil, nil, nil, nil
end

-- Find suitable regular player matching team formation (excluding GK)
local function find_suitable_player_by_formation(team_id, free_agents, min_rating, max_rating)
    local formation_positions = get_formation_positions(team_id)
    if #formation_positions == 0 then
        return nil, nil
    end
    
    -- Shuffle formation positions to add randomness
    local shuffled_positions = {}
    for _, pos in ipairs(formation_positions) do
        table.insert(shuffled_positions, pos)
    end
    
    for i = #shuffled_positions, 2, -1 do
        local j = math.random(i)
        shuffled_positions[i], shuffled_positions[j] = shuffled_positions[j], shuffled_positions[i]
    end
    
    -- Try each formation position randomly
    for _, formation_position in ipairs(shuffled_positions) do
        for i, player in ipairs(free_agents) do
            if player.overall >= min_rating and player.overall <= max_rating and player.position_name == formation_position then
                return i, player
            end
        end
    end
    
    return nil, nil
end

-- Find suitable youth player matching team formation (excluding GK)
local function find_suitable_youth_player_by_formation(team_id, free_agents, median_rating)
    local formation_positions = get_formation_positions(team_id)
    if #formation_positions == 0 then
        return nil, nil, nil
    end
    
    local min_potential = median_rating + TRANSFER_CONFIG.youth_thresholds.potential_bonus
    
    -- Shuffle formation positions to add randomness
    local shuffled_positions = {}
    for _, position in ipairs(formation_positions) do
        table.insert(shuffled_positions, position)
    end
    
    for i = #shuffled_positions, 2, -1 do
        local j = math.random(i)
        shuffled_positions[i], shuffled_positions[j] = shuffled_positions[j], shuffled_positions[i]
    end
    
    -- Try each formation position randomly
    for _, formation_position in ipairs(shuffled_positions) do
        for i, player in ipairs(free_agents) do
            if player.age <= TRANSFER_CONFIG.youth_thresholds.max_age and player.position_name == formation_position then
                local player_data = cache.player_data[player.playerid]
                if player_data then
                    local potential = players_table_global:GetRecordFieldValue(player_data.record_id, "potential") or 0
                    if potential >= min_potential then
                        return i, player, potential
                    end
                end
            end
        end
    end
    
    return nil, nil, nil
end

-- Search strategy definitions for modular player searching
-- To add new search methods: 
--   1. Add strategy definition here with requires_* flags and search_func
--   2. Implement the search function following existing signature patterns
--   3. System will automatically incorporate it into the search sequence
local SEARCH_STRATEGIES = {
    {
        name = "Priority Groups (Regular)",
        step_number = 1,
        requires_groups = true,
        is_youth = false,
        search_func = find_suitable_player_by_group_only
    },
    {
        name = "Priority Groups (Youth)",
        step_number = 2,
        requires_groups = true,
        is_youth = true,
        search_func = find_suitable_youth_player_by_group_only
    },
    {
        name = "Formation (Regular)",
        step_number = 3,
        requires_formation = true,
        is_youth = false,
        search_func = find_suitable_player_by_formation
    },
    {
        name = "Formation (Youth)",
        step_number = 4,
        requires_formation = true,
        is_youth = true,
        search_func = find_suitable_youth_player_by_formation
    },
    {
        name = "Any Regular Player",
        step_number = 5,
        is_youth = false,
        search_func = find_suitable_player
    },
    {
        name = "Any Youth Player",
        step_number = 6,
        is_youth = true,
        search_func = find_suitable_youth_player
    }
}

--------------------------------------------------------------------------------
-- PLAYER SEARCH SYSTEM
-- Modular and extensible player search strategies
--------------------------------------------------------------------------------

-- Create search context for team player needs
local function create_search_context(team_id, free_agents, min_rating, max_rating, median_rating)
    local underrepresented_groups = get_underrepresented_groups(team_id, get_team_size_cached(team_id))
    local formation_positions = get_formation_positions(team_id)
    
    return {
        team_id = team_id,
        free_agents = free_agents,
        min_rating = min_rating,
        max_rating = max_rating,
        median_rating = median_rating,
        underrepresented_groups = underrepresented_groups,
        formation_positions = formation_positions
    }
end

-- Check if search strategy requirements are met
local function can_execute_strategy(strategy, context)
    if strategy.requires_groups and #context.underrepresented_groups == 0 then
        return false
    end
    if strategy.requires_formation and #context.formation_positions == 0 then
        return false
    end
    return true
end

-- Execute a single search strategy
local function execute_search_strategy(strategy, context)
    if not can_execute_strategy(strategy, context) then
        return nil
    end
    
    local search_func = strategy.search_func
    local player_index, suitable_player, player_potential, selected_group = nil, nil, nil, nil
    
    -- Handle different search function signatures based on strategy type
    if strategy.requires_groups then
        -- Search through all underrepresented groups
        for _, target_group in ipairs(context.underrepresented_groups) do
            if strategy.is_youth then
                player_index, suitable_player, player_potential, selected_group = 
                    search_func(context.team_id, context.free_agents, context.median_rating, target_group)
            else
                player_index, suitable_player, selected_group = 
                    search_func(context.team_id, context.free_agents, context.min_rating, context.max_rating, target_group)
            end
            
            if player_index then
                local search_step = string.format("Step %d: %s %s", 
                    strategy.step_number, strategy.name, target_group)
                return {
                    player_index = player_index,
                    suitable_player = suitable_player,
                    selected_group = selected_group,
                    is_youth_transfer = strategy.is_youth,
                    player_potential = player_potential,
                    search_step = search_step
                }
            end
        end
    else
        -- Single search attempt
        if strategy.is_youth then
            player_index, suitable_player, player_potential = 
                search_func(context.team_id, context.free_agents, context.median_rating)
        else
            player_index, suitable_player = 
                search_func(context.team_id, context.free_agents, context.min_rating, context.max_rating)
        end
        
        if player_index then
            selected_group = position_to_group[suitable_player.position_name]
            local search_step = string.format("Step %d: %s", strategy.step_number, strategy.name)
            return {
                player_index = player_index,
                suitable_player = suitable_player,
                selected_group = selected_group,
                is_youth_transfer = strategy.is_youth,
                player_potential = player_potential,
                search_step = search_step
            }
        end
    end
    
    return nil
end

-- Execute all search strategies until a player is found
local function find_suitable_player_for_team(search_context)
    for _, strategy in ipairs(SEARCH_STRATEGIES) do
        local result = execute_search_strategy(strategy, search_context)
        if result then
            return result
        end
    end
    return nil -- All strategies failed
end

--------------------------------------------------------------------------------
-- PLAYER TRANSFER SYSTEM
-- Modular transfer handling with clear data structures
--------------------------------------------------------------------------------

-- Transfer context data structure for cleaner function signatures
local function create_transfer_context(player, team_id, free_agents, player_index, search_result)
    return {
        player = player,
        team_id = team_id,
        free_agents = free_agents,
        player_index = player_index,
        search_result = search_result
    }
end

-- Execute the actual transfer operation
local function execute_transfer(transfer_context)
    local player = transfer_context.player
    local team_id = transfer_context.team_id
    local player_id = player.playerid
    
    local ok, error_message = pcall(function()
        -- Clear existing contracts
        if IsPlayerPresigned(player_id) then DeletePresignedContract(player_id) end
        if IsPlayerLoanedOut(player_id) then TerminateLoan(player_id) end
        
        -- Execute transfer with configured terms
        TransferPlayer(player_id, team_id, 
            TEAM_FILTER.transfer_terms.sum, 
            TEAM_FILTER.transfer_terms.wage, 
            TEAM_FILTER.transfer_terms.contract_length, 
            TRANSFER_CONFIG.source_team_id, 
            TEAM_FILTER.transfer_terms.release_clause)
        
        -- Update player roles for new position
        if player.position_name then
            update_player_roles(player_id, player.position_name)
        end
        
        -- Update squad size caches
        update_team_size_cache(team_id, 1)
        update_team_size_cache(TRANSFER_CONFIG.source_team_id, -1)
    end)
    
    return ok, error_message
end

-- Generate transfer success log message
local function log_successful_transfer(transfer_context)
    local player = transfer_context.player
    local team_id = transfer_context.team_id
    local search_result = transfer_context.search_result
    
    local player_name = get_cached_player_name(player.playerid)
    local team_name = get_cached_team_name(team_id)
    local old_squad_size = get_team_size_cached(team_id) - 1 -- Already updated, so subtract 1
    local new_squad_size = old_squad_size + 1
    
    local step_info = search_result.search_step and string.format(" (%s)", search_result.search_step) or ""
    
    if search_result.is_youth_transfer and search_result.player_potential then
        LOGGER:LogInfo(string.format("YOUTH: %s (%s, %d->%d pot, age %d) -> %s [%d->%d] %s",
            player_name, player.position_name, player.overall, search_result.player_potential, 
            player.age, team_name, old_squad_size, new_squad_size, step_info))
    else
        LOGGER:LogInfo(string.format("%s (%s, %d, age %d) -> %s [%d->%d] %s",
            player_name, player.position_name, player.overall, player.age, 
            team_name, old_squad_size, new_squad_size, step_info))
    end
end

-- Main transfer function with simplified interface
local function transfer_player_to_team(transfer_context)
    local ok, error_message = execute_transfer(transfer_context)
    
    if ok then
        log_successful_transfer(transfer_context)
        -- Remove transferred player from free agents pool
        table.remove(transfer_context.free_agents, transfer_context.player_index)
        return true
    else
        local player_name = get_cached_player_name(transfer_context.player.playerid)
        local team_name = get_cached_team_name(transfer_context.team_id)
        LOGGER:LogWarning(string.format("Transfer failed: %s -> %s (%s)",
            player_name, team_name, tostring(error_message)))
        return false
    end
end

--------------------------------------------------------------------------------
-- TEAM PROCESSING
-- Core logic for processing individual teams
--------------------------------------------------------------------------------

-- Process a single team for potential player transfers
local function process_team_for_transfers(team_id, free_agents, permanently_failed_teams)
    -- Skip if team is permanently excluded
    if permanently_failed_teams[team_id] then
        return false, "permanently_excluded"
    end
    
    local current_squad_size = get_team_size_cached(team_id)
    
    -- Skip if team has reached target or maximum capacity
    if current_squad_size >= TRANSFER_CONFIG.target_squad_size or 
       current_squad_size >= TRANSFER_CONFIG.max_squad_size then
        return false, "target_reached"
    end
    
    -- Get team rating requirements
    local min_rating, max_rating, median_rating = get_team_rating_bounds_cached(team_id)
    if not min_rating or not max_rating or not median_rating then
        LOGGER:LogInfo(string.format("SKIP: %s - no rating data, skipping permanently", get_cached_team_name(team_id)))
        permanently_failed_teams[team_id] = true
        return false, "no_rating_data"
    end
    
    -- Log team targeting strategy
    local team_display_name = get_team_display_name(team_id)
    local underrepresented_groups = get_underrepresented_groups(team_id, current_squad_size)
    
    if #underrepresented_groups > 0 then
        LOGGER:LogInfo(string.format("%s (squad: %d) -> targeting %d-%d rating, priority: [%s]", 
            team_display_name, current_squad_size, min_rating, max_rating, table.concat(underrepresented_groups, ", ")))
    else
        LOGGER:LogInfo(string.format("%s (squad: %d) -> targeting %d-%d rating, balanced squad", 
            team_display_name, current_squad_size, min_rating, max_rating))
    end
    
    -- Execute modular search system
    local search_context = create_search_context(team_id, free_agents, min_rating, max_rating, median_rating)
    local search_result = find_suitable_player_for_team(search_context)
    
    if search_result then
        -- Create transfer context and execute transfer
        local transfer_context = create_transfer_context(
            search_result.suitable_player, 
            team_id, 
            free_agents, 
            search_result.player_index, 
            search_result
        )
        
        local success = transfer_player_to_team(transfer_context)
        if success then
            permanently_failed_teams[team_id] = nil -- Remove from failed list if present
            return true, "transfer_success"
        else
            LOGGER:LogWarning(string.format("Transfer failed for %s - will retry", get_cached_team_name(team_id)))
            return false, "transfer_failed"
        end
    else
        -- All search strategies failed
        LOGGER:LogInfo(string.format("SKIP: %s - no suitable players found (rating %d-%d), skipping permanently", 
            get_cached_team_name(team_id), min_rating, max_rating))
        permanently_failed_teams[team_id] = true
        return false, "no_suitable_players"
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
    
    LOGGER:LogInfo(string.format("Starting transfers: %d free agents -> target squad size %d", #free_agents, TRANSFER_CONFIG.target_squad_size))
    LOGGER:LogInfo(string.format("Search strategy: Priority groups -> Formation positions -> Any player (Youth: age <=%d, potential >= median+%d)", 
        TRANSFER_CONFIG.youth_thresholds.max_age, TRANSFER_CONFIG.youth_thresholds.potential_bonus))
    
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
        
        LOGGER:LogInfo(string.format("Iteration %d: %d teams at squad size %d", 
            iteration, #teams_at_smallest_level, smallest_squad_size))
        
        local transfers_this_iteration = 0
        local teams_processed = 0
        local teams_successful = 0
        
        for _, team_info in ipairs(teams_at_smallest_level) do
            local team_id = team_info.team_id
            local current_squad_size = get_team_size_cached(team_id)
            
            -- Skip if team's squad size has changed since we started this iteration
            if current_squad_size ~= smallest_squad_size then
                goto continue_team
            end
            
            teams_processed = teams_processed + 1
            
            -- Process team using modular system
            local success, reason = process_team_for_transfers(team_id, free_agents, permanently_failed_teams)
            
            if success then
                total_transfers = total_transfers + 1
                transfers_this_iteration = transfers_this_iteration + 1
                teams_successful = teams_successful + 1
            end
            -- Note: Failure reasons are already logged within process_team_for_transfers
            
            ::continue_team::
        end
        
        -- Log iteration summary
        local elapsed = os.time() - start_time
        local permanently_excluded_count = 0
        for _ in pairs(permanently_failed_teams) do
            permanently_excluded_count = permanently_excluded_count + 1
        end
        
        LOGGER:LogInfo(string.format("Iteration %d complete: %d transfers (+%d total). %d agents left, %d teams excluded", 
            iteration, transfers_this_iteration, total_transfers, #free_agents, permanently_excluded_count))
        
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
        "%d transfers completed in %d iterations (%d seconds)\n- %d free agents remaining\n- %d teams still need players\n- %d teams permanently excluded", 
        total_transfers, iteration - 1, elapsed, #free_agents, #final_teams, permanently_excluded_count))
end

--------------------------------------------------------------------------------
-- MAIN SCRIPT EXECUTION
-- Entry point for the squad filler system
--------------------------------------------------------------------------------

-- Initialize random seed for player selection fairness
math.randomseed(os.time())

LOGGER:LogInfo("Starting Simplified Squad Filler Script...")

-- Execute the main transfer process
-- This will continue until all teams reach target size or no more suitable players exist
do_simple_transfers()