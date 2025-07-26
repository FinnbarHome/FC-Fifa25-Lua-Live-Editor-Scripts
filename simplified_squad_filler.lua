--------------------------------------------------------------------------------
-- Simplified Squad Filler Script for FC 25 Live Editor
-- Transfers players to teams with smallest squad sizes
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
    },
    position_groups = {
        GK = {"GK"},
        DEF = {"CB", "LB", "RB"},
        MID = {"CM", "CDM"},
        AM = {"RM", "LM", "RW", "LW", "CAM"},
        ST = {"ST"}
    },
    group_ratios = {
        GK = 1,   -- 1 part
        DEF = 2,  -- 2 parts  
        MID = 2,  -- 2 parts
        AM = 2,   -- 2 parts
        ST = 1    -- 1 part
    }  -- Total: 8 parts
}

-- Pre-compute position mappings for faster lookups
local position_name_by_id = {}
for name, ids in pairs(config.position_ids) do
    for _, pid in ipairs(ids) do
        position_name_by_id[pid] = name
    end
end

-- Pre-compute position to group mapping
local position_to_group = {}
for group_name, positions in pairs(config.position_groups) do
    for _, position in ipairs(positions) do
        position_to_group[position] = group_name
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
        if league_id and team_id and not config.excluded_teams[team_id] then
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
    LOGGER:LogInfo("Initializing caches...")
    build_player_cache()
    build_league_cache()
    build_team_size_cache()
    build_team_ratings_cache()
    -- Formation cache is built on-demand to avoid unnecessary database reads
    LOGGER:LogInfo("Caches ready.")
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
-- POSITIONAL GROUPING AND RATIO LOGIC
--------------------------------------------------------------------------------

-- Count players by position group for a team
local function count_players_by_group(team_id)
    local group_counts = {GK = 0, DEF = 0, MID = 0, AM = 0, ST = 0}
    
    local rec = team_player_links_global:GetFirstRecord()
    while rec > 0 do
        if team_player_links_global:GetRecordFieldValue(rec, "teamid") == team_id then
            local player_id = team_player_links_global:GetRecordFieldValue(rec, "playerid")
            local player_data = cache.player_data[player_id]
            
            if player_data and player_data.preferred_position then
                local position_name = get_position_name_from_position_id(player_data.preferred_position)
                local group = position_to_group[position_name]
                if group then
                    group_counts[group] = group_counts[group] + 1
                end
            end
        end
        rec = team_player_links_global:GetNextValidRecord()
    end
    
    return group_counts
end

-- Calculate underrepresented position groups in order of priority
local function get_underrepresented_position_groups(team_id, squad_size)
    local group_counts = count_players_by_group(team_id)
    local total_ratio_parts = 8 -- GK(1) + DEF(2) + MID(2) + AM(2) + ST(1) = 8
    local players_per_part = squad_size / total_ratio_parts
    
    local group_analysis = {}
    local underrepresented_groups = {}
    
    for group_name, ratio in pairs(config.group_ratios) do
        local ideal_count = ratio * players_per_part
        local actual_count = group_counts[group_name]
        local shortfall = 0
        
        if ideal_count > 0 then
            shortfall = math.max(0, (ideal_count - actual_count) / ideal_count)
        end
        
        group_analysis[group_name] = {
            ideal = math.floor(ideal_count + 0.5), -- Round to nearest integer
            actual = actual_count,
            shortfall = shortfall
        }
        
        -- Only include groups with shortfall
        if shortfall > 0 then
            table.insert(underrepresented_groups, {
                group = group_name,
                shortfall = shortfall
            })
        end
    end
    
    -- Pre-shuffle to randomize ties, then sort by shortfall (highest first)
    for i = #underrepresented_groups, 2, -1 do
        local j = math.random(i)
        underrepresented_groups[i], underrepresented_groups[j] = underrepresented_groups[j], underrepresented_groups[i]
    end
    
    table.sort(underrepresented_groups, function(a, b)
        return a.shortfall > b.shortfall
    end)
    
    -- Extract just the group names in priority order
    local priority_groups = {}
    for _, entry in ipairs(underrepresented_groups) do
        table.insert(priority_groups, entry.group)
    end
    
    return priority_groups, group_analysis
end

-- Get all positions in a position group
local function get_positions_in_group(group_name)
    return config.position_groups[group_name] or {}
end

-- Get formation positions for a team (excluding GK)
local formation_cache = {}
local function get_formation_positions(target_team_id)
    if formation_cache[target_team_id] then
        return formation_cache[target_team_id]
    end
    
    if not formations_table_global then
        formation_cache[target_team_id] = {}
        return {}
    end

    local record = formations_table_global:GetFirstRecord()
    while record > 0 do
        local team_id_current = formations_table_global:GetRecordFieldValue(record, "teamid")
        if team_id_current == target_team_id then
            local positions = {}
            for i=0,10 do
                local field_name = ("position%d"):format(i)
                local position_id = formations_table_global:GetRecordFieldValue(record, field_name) or 0
                local position_name = get_position_name_from_position_id(position_id)
                -- Exclude GK (position 0) from formation positions
                if position_id ~= 0 and position_name ~= "GK" then
                    positions[#positions+1] = position_name
                end
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

-- Find suitable youth player prioritizing specific position group (NO FALLBACK)
local function find_suitable_youth_player_by_group_only(team_id, free_agents, median_rating, target_group)
    local min_potential = median_rating + config.youth_player.potential_bonus
    local target_positions = get_positions_in_group(target_group)
    
    -- Only try to find a youth player in the target group, no fallback
    for i, player in ipairs(free_agents) do
        if player.age <= config.youth_player.max_age then
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
    
    local min_potential = median_rating + config.youth_player.potential_bonus
    
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
            if player.age <= config.youth_player.max_age and player.position_name == formation_position then
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

--------------------------------------------------------------------------------
-- TRANSFER PLAYER TO TEAM
--------------------------------------------------------------------------------
local function transfer_player_to_team_cached(player, team_id, free_agents, player_index, is_youth_transfer, player_potential, team_median, selected_group, target_group, search_step)
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
        
        -- Build position group status for logging
        local group_status = ""
        if selected_group then
            if target_group and selected_group == target_group then
                group_status = string.format(" [%s: ✓ Priority]", selected_group)
            elseif target_group then
                group_status = string.format(" [%s: Fallback, wanted %s]", selected_group, target_group)
            else
                group_status = string.format(" [%s: Balanced]", selected_group)
            end
        end
        
        -- Add search step to logging
        local step_info = search_step and string.format(" (%s)", search_step) or ""
        
        if is_youth_transfer and player_potential then
            LOGGER:LogInfo(string.format("YOUTH: %s (%s, %d->%d pot, age %d) -> %s [%d->%d] %s",
                player_name, player.position_name, player.overall, player_potential, player.age, 
                get_cached_team_name(team_id), old_squad_size, new_squad_size, step_info))
        else
            LOGGER:LogInfo(string.format("%s (%s, %d, age %d) -> %s [%d->%d] %s",
                player_name, player.position_name, player.overall, player.age, 
                get_cached_team_name(team_id), old_squad_size, new_squad_size, step_info))
        end
        
        -- Remove the transferred player from the free agents list
        table.remove(free_agents, player_index)
        return true
    else
        LOGGER:LogWarning(string.format("Transfer failed: %s → %s (%s)",
            player_name, get_cached_team_name(team_id), tostring(error_message)))
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
    
    LOGGER:LogInfo(string.format("Starting transfers: %d free agents -> target squad size %d", #free_agents, config.target_squad_size))
    LOGGER:LogInfo(string.format("Search strategy: Priority groups -> Formation positions -> Any player (Youth: age <=%d, potential >= median+%d)", 
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
        
        LOGGER:LogInfo(string.format("Iteration %d: %d teams at squad size %d", 
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
                goto continue_team
            end
            
            teams_processed = teams_processed + 1
            
            -- Get team rating bounds from cache
            local min_rating, max_rating, median_rating, p75_rating = get_team_rating_bounds_cached(team_id)
            local team_name_with_stats = get_team_name_with_stats(team_id)
            
            if not min_rating or not max_rating or not median_rating then
                LOGGER:LogInfo(string.format("SKIP: %s - no rating data, skipping permanently", get_cached_team_name(team_id)))
                permanently_failed_teams[team_id] = true
                goto continue_team
            end
            
            -- Analyze position group needs
            local underrepresented_groups, group_analysis = get_underrepresented_position_groups(team_id, current_squad_size)
            
            -- Log team analysis concisely
            if #underrepresented_groups > 0 then
                LOGGER:LogInfo(string.format("%s (squad: %d) -> targeting %d-%d rating, priority: [%s]", 
                    team_name_with_stats, current_squad_size, min_rating, max_rating, table.concat(underrepresented_groups, ", ")))
            else
                LOGGER:LogInfo(string.format("%s (squad: %d) -> targeting %d-%d rating, balanced squad", 
                    team_name_with_stats, current_squad_size, min_rating, max_rating))
            end
            
            -- Explicit 6-step search process with group prioritization and formation logic
            local player_index, suitable_player, selected_group = nil, nil, nil
            local is_youth_transfer = false
            local player_potential = nil
            local search_step = ""
            
            -- Get team formation positions for steps 3 and 4
            local formation_positions = get_formation_positions(team_id)
            
            -- STEP 1: Loop through all underrepresented groups trying to find regular players
            if #underrepresented_groups > 0 then
                for _, target_group in ipairs(underrepresented_groups) do
                    player_index, suitable_player, selected_group = find_suitable_player_by_group_only(team_id, free_agents, min_rating, max_rating, target_group)
                    if player_index then
                        search_step = string.format("Step 1: Regular player in priority group %s", target_group)
                        break
                    end
                end
            end
            
            -- STEP 2: Loop through all underrepresented groups trying to find youth players
            if not player_index and #underrepresented_groups > 0 then
                for _, target_group in ipairs(underrepresented_groups) do
                    player_index, suitable_player, player_potential, selected_group = find_suitable_youth_player_by_group_only(team_id, free_agents, median_rating, target_group)
                    if player_index then
                        is_youth_transfer = true
                        search_step = string.format("Step 2: Youth player in priority group %s", target_group)
                        break
                    end
                end
            end
            
            -- STEP 3: Try find regular player matching team formation (excluding GK)
            if not player_index and #formation_positions > 0 then
                player_index, suitable_player = find_suitable_player_by_formation(team_id, free_agents, min_rating, max_rating)
                if player_index then
                    selected_group = position_to_group[suitable_player.position_name]
                    search_step = "Step 3: Regular player in formation"
                end
            end
            
            -- STEP 4: Try find youth player matching team formation (excluding GK)
            if not player_index and #formation_positions > 0 then
                player_index, suitable_player, player_potential = find_suitable_youth_player_by_formation(team_id, free_agents, median_rating)
                if player_index then
                    selected_group = position_to_group[suitable_player.position_name]
                    is_youth_transfer = true
                    search_step = "Step 4: Youth player in formation"
                end
            end
            
            -- STEP 5: Try find any regular player
            if not player_index then
                player_index, suitable_player = find_suitable_player(team_id, free_agents, min_rating, max_rating)
                if player_index then
                    selected_group = position_to_group[suitable_player.position_name]
                    search_step = "Step 5: Any regular player"
                end
            end
            
            -- STEP 6: Try find any youth player
            if not player_index then
                player_index, suitable_player, player_potential = find_suitable_youth_player(team_id, free_agents, median_rating)
                if player_index then
                    selected_group = position_to_group[suitable_player.position_name]
                    is_youth_transfer = true
                    search_step = "Step 6: Any youth player"
                end
            end
            
            if player_index and suitable_player then
                local target_group = #underrepresented_groups > 0 and underrepresented_groups[1] or nil
                local success = transfer_player_to_team_cached(suitable_player, team_id, free_agents, player_index, is_youth_transfer, player_potential, median_rating, selected_group, target_group, search_step)
                if success then
                    total_transfers = total_transfers + 1
                    transfers_this_iteration = transfers_this_iteration + 1
                    teams_successful = teams_successful + 1
                    -- Remove from failed list if somehow they were there
                    permanently_failed_teams[team_id] = nil
                else
                    LOGGER:LogWarning(string.format("Transfer failed for %s - will retry", get_cached_team_name(team_id)))
                    -- Don't mark as permanently failed for technical issues
                end
            else
                -- All 6 steps failed
                LOGGER:LogInfo(string.format("SKIP: %s - no suitable players found (rating %d-%d), skipping permanently", 
                    get_cached_team_name(team_id), min_rating, max_rating))
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
--------------------------------------------------------------------------------
math.randomseed(os.time())
LOGGER:LogInfo("Starting Simplified Squad Filler Script...")

do_simple_transfers() 