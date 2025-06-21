--------------------------------------------------------------------------------
-- Team Upgrade Script - Sign Better Free Agents and Clean Up Roster
--------------------------------------------------------------------------------
require 'imports/career_mode/helpers'
require 'imports/other/helpers'

--------------------------------------------------------------------------------
-- GLOBAL TABLES
--------------------------------------------------------------------------------
local players_table_global     = LE.db:GetTable("players")
local team_player_links_global = LE.db:GetTable("teamplayerlinks")
local formations_table_global  = LE.db:GetTable("formations")
local league_team_links_global = LE.db:GetTable("leagueteamlinks")
local playerloans_table_global = LE.db:GetTable("playerloans")

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------
local config = {
    -- Target leagues to process
    target_leagues = {61,60,14,13,16,17,19,20,2076,31,32,10,83,53,54,353,351,80,4,2012,1,2149,41,66,308,65,330,350,50,56,189,68,39},
    excluded_teams = { [110] = true },
    
    -- Upgrade thresholds
    median_minus_threshold = 0,  -- If best player in position is median-3 or lower, try to upgrade
    median_plus_threshold = 5,   -- Look for free agents between median and median+5
    max_age_for_signing = 29,    -- Maximum age for free agents to sign
    
    -- Transfer settings
    transfer = {
        sum = 0,
        wage = 600,
        contract_length = 60,
        release_clause = -1,
        from_team_id = 111592  -- Free agents team ID
    },
    
    -- Youth protection settings (from release script)
    protect_youth = true,
    youth_max_age = 23,
    youth_potential_bonus = 2,
    youth_max_protected_per_pos = 1,
    
    -- Position mappings
    position_ids = {
        GK={0}, CB={5,1,4,6}, RB={3,2}, LB={7,8}, CDM={10,9,11},
        RM={12}, CM={14,13,15}, LM={16}, CAM={18,17,19},
        ST={25,20,21,22,24,26}, RW={23}, LW={27}
    },
    
    -- Process control
    batch_size = 10,
    process_upgrades = true,
    process_cleanup = true
}

--------------------------------------------------------------------------------
-- POSITION MAPPINGS
--------------------------------------------------------------------------------
local position_name_by_id = {}
local position_id_by_name = {}
for name, ids in pairs(config.position_ids) do
    position_id_by_name[name] = ids[1]
    for _, pid in ipairs(ids) do
        position_name_by_id[pid] = name
    end
end

local function get_position_name_from_position_id(pid)
    return position_name_by_id[pid] or ("UnknownPos(".. tostring(pid) ..")")
end

--------------------------------------------------------------------------------
-- CACHES AND INDEXES
--------------------------------------------------------------------------------
local player_cache = {}
local teams_processed = {}
local formation_cache = {}
local team_median_ratings = {}
local loaned_players = {}
local free_agents_cache = {}
local team_player_cache = {}

--------------------------------------------------------------------------------
-- HELPER FUNCTIONS
--------------------------------------------------------------------------------
local function calculate_player_age(birth_date)
    if not birth_date or birth_date <= 0 then return 30 end
    local c = GetCurrentDate()
    local d = DATE:new(); d:FromGregorianDays(birth_date)
    local age = c.year - d.year
    if c.month < d.month or (c.month==d.month and c.day<d.day) then
        age = age - 1
    end
    return age
end

--------------------------------------------------------------------------------
-- PLAYER INDEXING
--------------------------------------------------------------------------------
local function index_players_by_id()
    if next(player_cache) ~= nil then 
        return
    end
    
    LOGGER:LogInfo("Building player index...")
    local start_time = os.time()
    local count = 0
    
    local rec = players_table_global:GetFirstRecord()
    while rec > 0 do
        local pid = players_table_global:GetRecordFieldValue(rec, "playerid")
        if pid then
            local birthdate = players_table_global:GetRecordFieldValue(rec, "birthdate")
            local pref_pos1 = players_table_global:GetRecordFieldValue(rec, "preferredposition1")
            local pos_name = get_position_name_from_position_id(pref_pos1)
            
            player_cache[pid] = {
                record = rec,
                preferredposition1 = pref_pos1,
                overall = players_table_global:GetRecordFieldValue(rec, "overallrating") or 
                          players_table_global:GetRecordFieldValue(rec, "overall") or 0,
                potential = players_table_global:GetRecordFieldValue(rec, "potential") or 0,
                age = calculate_player_age(birthdate),
                birthdate = birthdate,
                positionName = pos_name
            }
            
            count = count + 1
            
            if count % 10000 == 0 then
                LOGGER:LogInfo(string.format("Indexed %d players so far...", count))
            end
        end
        rec = players_table_global:GetNextValidRecord()
    end
    
    local elapsed = os.time() - start_time
    LOGGER:LogInfo(string.format("Indexed %d players in %d seconds", count, elapsed))
end

--------------------------------------------------------------------------------
-- LOAN PLAYERS TRACKING
--------------------------------------------------------------------------------
local function build_loan_players_index()
    if next(loaned_players) ~= nil then
        return
    end
    
    LOGGER:LogInfo("Building loan players index...")
    local count = 0
    
    if not playerloans_table_global then
        LOGGER:LogWarning("No playerloans table found.")
        return
    end
    
    local rec = playerloans_table_global:GetFirstRecord()
    while rec > 0 do
        local player_id = playerloans_table_global:GetRecordFieldValue(rec, "playerid")
        local loaned_from_team = playerloans_table_global:GetRecordFieldValue(rec, "teamidloanedfrom")
        
        if player_id and loaned_from_team then
            loaned_players[player_id] = loaned_from_team
            count = count + 1
        end
        
        rec = playerloans_table_global:GetNextValidRecord()
    end
    
    LOGGER:LogInfo(string.format("Found %d players currently on loan", count))
end

local function is_player_on_loan_from(player_id, team_id)
    return loaned_players[player_id] == team_id
end

--------------------------------------------------------------------------------
-- GET TEAM PLAYERS
--------------------------------------------------------------------------------
local function get_team_players(team_id)
    if team_player_cache[team_id] then
        return team_player_cache[team_id]
    end
    
    index_players_by_id()
    build_loan_players_index()
    
    local players = {}
    local team_players = {}
    
    local link_rec = team_player_links_global:GetFirstRecord()
    while link_rec > 0 do
        local t_id = team_player_links_global:GetRecordFieldValue(link_rec, "teamid")
        local p_id = team_player_links_global:GetRecordFieldValue(link_rec, "playerid")
        
        if t_id == team_id and p_id then
            team_players[p_id] = true
        end
        link_rec = team_player_links_global:GetNextValidRecord()
    end
    
    for p_id in pairs(team_players) do
        if not is_player_on_loan_from(p_id, team_id) then
            local cached_player = player_cache[p_id]
            if cached_player then
                players[#players + 1] = {
                    id = p_id,
                    posName = cached_player.positionName,
                    overall = cached_player.overall,
                    potential = cached_player.potential,
                    age = cached_player.age
                }
            end
        end
    end
    
    team_player_cache[team_id] = players
    return players
end

local function invalidate_team_player_cache(team_id)
    if team_id then
        team_player_cache[team_id] = nil
        team_median_ratings[team_id] = nil
    else
        team_player_cache = {}
        team_median_ratings = {}
    end
end

--------------------------------------------------------------------------------
-- CALCULATE TEAM MEDIAN RATING
--------------------------------------------------------------------------------
local function calculate_team_median_rating(team_id)
    if team_median_ratings[team_id] then
        return team_median_ratings[team_id]
    end
    
    local players_list = get_team_players(team_id)
    if #players_list == 0 then
        return 65
    end
    
    local ratings = {}
    for _, player in ipairs(players_list) do
        table.insert(ratings, player.overall)
    end
    
    table.sort(ratings)
    local median
    if #ratings % 2 == 0 then
        median = (ratings[#ratings/2] + ratings[#ratings/2 + 1]) / 2
    else
        median = ratings[math.ceil(#ratings/2)]
    end
    
    median = math.floor(median + 0.5)
    team_median_ratings[team_id] = median
    
    -- LOGGER:LogInfo(string.format("Team %d median rating calculated: %d", team_id, median))
    return median
end

--------------------------------------------------------------------------------
-- GET FORMATION POSITIONS
--------------------------------------------------------------------------------
local function get_formation_positions(team_id)
    if formation_cache[team_id] then
        return formation_cache[team_id]
    end
    
    if not formations_table_global then
        formation_cache[team_id] = {}
        return {}
    end
    
    local rec = formations_table_global:GetFirstRecord()
    while rec > 0 do
        local f_team_id = formations_table_global:GetRecordFieldValue(rec, "teamid")
        if f_team_id == team_id then
            local positions = {}
            for i = 0, 10 do
                local field_name = ("position%d"):format(i)
                local pos_id = formations_table_global:GetRecordFieldValue(rec, field_name) or 0
                local pos_name = get_position_name_from_position_id(pos_id)
                positions[#positions + 1] = pos_name
            end
            formation_cache[team_id] = positions
            return positions
        end
        rec = formations_table_global:GetNextValidRecord()
    end
    
    formation_cache[team_id] = {}
    return {}
end

--------------------------------------------------------------------------------
-- BUILD FREE AGENTS LIST
--------------------------------------------------------------------------------
local function build_free_agents_by_position()
    if next(free_agents_cache) ~= nil then
        return free_agents_cache
    end
    
    LOGGER:LogInfo("Building free agents index...")
    index_players_by_id()
    
    local rec = team_player_links_global:GetFirstRecord()
    while rec > 0 do
        local t_id = team_player_links_global:GetRecordFieldValue(rec, "teamid")
        local p_id = team_player_links_global:GetRecordFieldValue(rec, "playerid")
        
        if t_id == config.transfer.from_team_id then
            local cached_player = player_cache[p_id]
            if cached_player and cached_player.age <= config.max_age_for_signing then
                local pos_name = cached_player.positionName
                if pos_name then
                    free_agents_cache[pos_name] = free_agents_cache[pos_name] or {}
                    table.insert(free_agents_cache[pos_name], {
                        id = p_id,
                        overall = cached_player.overall,
                        potential = cached_player.potential,
                        age = cached_player.age
                    })
                end
            end
        end
        
        rec = team_player_links_global:GetNextValidRecord()
    end
    
    -- Sort free agents by overall rating (descending)
    for pos_name, agents in pairs(free_agents_cache) do
        table.sort(agents, function(a, b) return a.overall > b.overall end)
    end
    
    LOGGER:LogInfo("Free agents index built.")
    return free_agents_cache
end

--------------------------------------------------------------------------------
-- FIND SUITABLE FREE AGENT
--------------------------------------------------------------------------------
local function find_suitable_free_agent(position, min_rating, max_rating)
    local free_agents = build_free_agents_by_position()
    local position_agents = free_agents[position] or {}
    
    for _, agent in ipairs(position_agents) do
        if agent.overall >= min_rating and agent.overall <= max_rating then
            return agent
        end
    end
    
    return nil
end

--------------------------------------------------------------------------------
-- TRANSFER PLAYER
--------------------------------------------------------------------------------
local function transfer_player_to_team(player_id, team_id, position)
    local player_name = GetPlayerName(player_id)
    local team_name = GetTeamName(team_id)
    
    local ok, error_message = pcall(function()
        if IsPlayerPresigned(player_id) then DeletePresignedContract(player_id) end
        if IsPlayerLoanedOut(player_id) then TerminateLoan(player_id) end
        
        TransferPlayer(
            player_id, 
            team_id, 
            config.transfer.sum, 
            config.transfer.wage, 
            config.transfer.contract_length, 
            config.transfer.from_team_id, 
            config.transfer.release_clause
        )
    end)
    
    if ok then
        LOGGER:LogInfo(string.format(
            "Transferred %s (ID: %d) to %s (ID: %d) for position %s.",
            player_name, player_id, team_name, team_id, position
        ))
        
        -- Remove from free agents cache
        local position_agents = free_agents_cache[position] or {}
        for i, agent in ipairs(position_agents) do
            if agent.id == player_id then
                table.remove(position_agents, i)
                break
            end
        end
        
        -- Invalidate team cache
        invalidate_team_player_cache(team_id)
        return true
    else
        LOGGER:LogWarning(string.format(
            "Failed to transfer player %s (ID: %d) to team %s (ID: %d). Error: %s",
            player_name, player_id, team_name, team_id, tostring(error_message)
        ))
        return false
    end
end

--------------------------------------------------------------------------------
-- RELEASE PLAYER
--------------------------------------------------------------------------------
local function release_player(player_id, team_id)
    if loaned_players[player_id] then
        LOGGER:LogInfo(string.format("Skipping release of player %d who is on loan from team %d", player_id, team_id))
        return false
    end
    
    local success = pcall(function()
        ReleasePlayerFromTeam(player_id)
    end)
    
    if success then
        local player_name = GetPlayerName(player_id)
        local team_name = GetTeamName(team_id)
        LOGGER:LogInfo(string.format("Released player %s (ID: %d) from %s (ID: %d).", player_name, player_id, team_name, team_id))
        
        invalidate_team_player_cache(team_id)
        return true
    else
        LOGGER:LogWarning(string.format("Failed to release player %d from team %d", player_id, team_id))
        return false
    end
end

--------------------------------------------------------------------------------
-- YOUTH PLAYER PROTECTION
--------------------------------------------------------------------------------
local function is_high_potential_youth(player, team_median_rating)
    if not config.protect_youth then
        return false
    end
    
    if player.age > config.youth_max_age then
        return false
    end
    
    local potential_threshold = team_median_rating + config.youth_potential_bonus
    return player.potential >= potential_threshold
end

--------------------------------------------------------------------------------
-- ROSTER CLEANUP LOGIC
--------------------------------------------------------------------------------
local function cleanup_position_roster(team_id, position, team_median)
    -- Get all players in this position
    local players_list = get_team_players(team_id)
    local position_players = {}
    
    for _, player in ipairs(players_list) do
        if player.posName == position then
            table.insert(position_players, player)
        end
    end
    
    if #position_players <= 3 then
        -- No cleanup needed
        return 0
    end
    
    -- Sort by overall rating (descending)
    table.sort(position_players, function(a, b) return a.overall > b.overall end)
    
    -- Identify players to keep
    local players_to_keep = {}
    
    -- Keep the two best players
    if position_players[1] then players_to_keep[position_players[1].id] = true end
    if position_players[2] then players_to_keep[position_players[2].id] = true end
    
    -- Look for high potential youth
    local youth_kept = false
    for i = 3, #position_players do
        if is_high_potential_youth(position_players[i], team_median) then
            players_to_keep[position_players[i].id] = true
            youth_kept = true
            LOGGER:LogInfo(string.format(
                "Keeping youth player %d (OVR: %d, POT: %d, Age: %d) in position %s",
                position_players[i].id, position_players[i].overall, 
                position_players[i].potential, position_players[i].age, position
            ))
            break
        end
    end
    
    -- If no youth kept, keep the third best player
    if not youth_kept and position_players[3] then
        players_to_keep[position_players[3].id] = true
    end
    
    -- Release the rest
    local released = 0
    for _, player in ipairs(position_players) do
        if not players_to_keep[player.id] then
            if release_player(player.id, team_id) then
                released = released + 1
            end
        end
    end
    
    return released
end

--------------------------------------------------------------------------------
-- PROCESS TEAM UPGRADES
--------------------------------------------------------------------------------
local function process_team_upgrades(team_id)
    local team_name = GetTeamName(team_id)
    LOGGER:LogInfo(string.format("Processing upgrades for team %s (%d)...", team_name, team_id))
    
    -- Get formation positions
    local formation_positions = get_formation_positions(team_id)
    if #formation_positions == 0 then
        LOGGER:LogInfo(string.format("No formation found for team %s. Skipping.", team_name))
        return 0, 0
    end
    
    -- Get unique positions from formation
    local unique_positions = {}
    for _, pos in ipairs(formation_positions) do
        unique_positions[pos] = true
    end
    
    -- Calculate team median rating
    local team_median = calculate_team_median_rating(team_id)
    
    local upgrades_made = 0
    local players_released = 0
    
    -- Process each position
    for position in pairs(unique_positions) do
        -- Get all players in this position
        local players_list = get_team_players(team_id)
        local position_players = {}
        
        for _, player in ipairs(players_list) do
            if player.posName == position then
                table.insert(position_players, player)
            end
        end
        
        if #position_players > 0 then
            -- Find best player in position
            table.sort(position_players, function(a, b) return a.overall > b.overall end)
            local best_player = position_players[1]
            
            -- Check if upgrade is needed
            local upgrade_threshold = team_median - config.median_minus_threshold
            
            if best_player.overall <= upgrade_threshold then
                LOGGER:LogInfo(string.format(
                    "Position %s needs upgrade. Best player rating: %d, threshold: %d",
                    position, best_player.overall, upgrade_threshold
                ))
                
                -- Look for suitable free agent
                local min_rating = team_median
                local max_rating = team_median + config.median_plus_threshold
                
                local free_agent = find_suitable_free_agent(position, min_rating, max_rating)
                
                if free_agent then
                    -- Transfer the player
                    if config.process_upgrades then
                        local success = transfer_player_to_team(free_agent.id, team_id, position)
                        if success then
                            upgrades_made = upgrades_made + 1
                            
                            -- Cleanup roster after signing
                            if config.process_cleanup then
                                local released = cleanup_position_roster(team_id, position, team_median)
                                players_released = players_released + released
                            end
                        end
                    else
                        LOGGER:LogInfo(string.format(
                            "Would sign player %d (OVR: %d) for position %s (upgrades disabled)",
                            free_agent.id, free_agent.overall, position
                        ))
                    end
                else
                    LOGGER:LogInfo(string.format(
                        "No suitable free agent found for position %s in rating range [%d-%d]",
                        position, min_rating, max_rating
                    ))
                end
            end
        end
    end
    
    return upgrades_made, players_released
end

--------------------------------------------------------------------------------
-- BUILD TEAM POOL
--------------------------------------------------------------------------------
local function build_team_pool()
    local pool = {}
    if not league_team_links_global then
        LOGGER:LogWarning("No league_team_links table found. Pool will be empty.")
        return pool
    end
    
    local league_team_map = {}
    local rec = league_team_links_global:GetFirstRecord()
    while rec > 0 do
        local league_id = league_team_links_global:GetRecordFieldValue(rec, "leagueid")
        local t_id = league_team_links_global:GetRecordFieldValue(rec, "teamid")
        if league_id and t_id then
            league_team_map[league_id] = league_team_map[league_id] or {}
            league_team_map[league_id][#league_team_map[league_id] + 1] = t_id
        end
        rec = league_team_links_global:GetNextValidRecord()
    end
    
    for _, league_id in ipairs(config.target_leagues) do
        local teams_in_league = league_team_map[league_id] or {}
        for _, t_id in ipairs(teams_in_league) do
            if not config.excluded_teams[t_id] then
                pool[#pool + 1] = t_id
            end
        end
    end
    
    return pool
end

--------------------------------------------------------------------------------
-- UPGRADE PRIORITY CALCULATION
--------------------------------------------------------------------------------
local function calculate_team_upgrade_priorities(team_id)
    local priorities = {}
    local team_median = calculate_team_median_rating(team_id)
    local formation_positions = get_formation_positions(team_id)
    
    -- Get unique positions from formation
    local unique_positions = {}
    for _, pos in ipairs(formation_positions) do
        unique_positions[pos] = true
    end
    
    -- Calculate priority for each position
    for position in pairs(unique_positions) do
        local players_list = get_team_players(team_id)
        local position_players = {}
        
        for _, player in ipairs(players_list) do
            if player.posName == position then
                table.insert(position_players, player)
            end
        end
        
        if #position_players > 0 then
            -- Find best player in position
            table.sort(position_players, function(a, b) return a.overall > b.overall end)
            local best_player = position_players[1]
            local upgrade_threshold = team_median - config.median_minus_threshold
            
            if best_player.overall <= upgrade_threshold then
                -- Calculate priority based on how far below threshold the best player is
                local priority = upgrade_threshold - best_player.overall
                table.insert(priorities, {
                    team_id = team_id,
                    position = position,
                    priority = priority,
                    best_player_rating = best_player.overall,
                    team_median = team_median
                })
            end
        end
    end
    
    return priorities
end

--------------------------------------------------------------------------------
-- MAIN FUNCTION
--------------------------------------------------------------------------------
local function do_team_upgrades()
    local start_time = os.time()
    
    -- Pre-index all players
    index_players_by_id()
    build_loan_players_index()
    
    -- Build team pool
    local team_pool = build_team_pool()
    if #team_pool == 0 then
        LOGGER:LogInfo("No teams found in target leagues. Exiting.")
        return
    end
    
    LOGGER:LogInfo(string.format(
        "Collected %d teams from leagues: %s",
        #team_pool, table.concat(config.target_leagues, ", ")
    ))
    
    -- Calculate all upgrade priorities
    LOGGER:LogInfo("Calculating upgrade priorities for all teams...")
    local all_priorities = {}
    for _, team_id in ipairs(team_pool) do
        local team_priorities = calculate_team_upgrade_priorities(team_id)
        for _, priority in ipairs(team_priorities) do
            table.insert(all_priorities, priority)
        end
    end
    
    -- Sort priorities by highest priority (biggest gap) first
    table.sort(all_priorities, function(a, b) return a.priority > b.priority end)
    
    LOGGER:LogInfo(string.format("Found %d positions needing upgrades across all teams", #all_priorities))
    
    local total_upgrades = 0
    local total_releases = 0
    local success_count = 0
    local error_count = 0
    local processed_teams = {}
    
    -- Process each priority
    for idx, priority in ipairs(all_priorities) do
        if idx % 5 == 0 or idx == 1 or idx == #all_priorities then
            local percent_complete = math.floor(idx / #all_priorities * 100)
            LOGGER:LogInfo(string.format(
                "Progress: %d/%d priorities (%d%%) - %d upgrades, %d releases so far", 
                idx, #all_priorities, percent_complete, total_upgrades, total_releases
            ))
        end
        
        -- Skip if we've already processed this team
        if processed_teams[priority.team_id] then
            goto continue
        end
        
        LOGGER:LogInfo(string.format(
            "Processing team %d (ID: %d) - Position %s needs upgrade (Best: %d, Median: %d, Priority: %d)",
            idx, priority.team_id, priority.position, priority.best_player_rating, 
            priority.team_median, priority.priority
        ))
        
        local success, err = pcall(function()
            local upgrades, releases = process_team_upgrades(priority.team_id)
            total_upgrades = total_upgrades + upgrades
            total_releases = total_releases + releases
            success_count = success_count + 1
            processed_teams[priority.team_id] = true
        end)
        
        if not success then
            error_count = error_count + 1
            LOGGER:LogError(string.format("Error processing team %d: %s", priority.team_id, tostring(err)))
        end
        
        -- Save progress periodically
        if idx % config.batch_size == 0 then
            LOGGER:LogInfo("Batch complete. Saving progress...")
        end
        
        ::continue::
    end
    
    local total_elapsed = os.time() - start_time
    LOGGER:LogInfo(string.format(
        "Done processing all teams in %d seconds. Upgrades: %d, Releases: %d, Success: %d, Errors: %d", 
        total_elapsed, total_upgrades, total_releases, success_count, error_count
    ))
    
    -- Show results
    MessageBox("Team Upgrades Complete", string.format(
        "Processed %d teams\nUpgrades made: %d\nPlayers released: %d\nSuccess: %d\nErrors: %d\nTotal time: %d seconds",
        #team_pool, total_upgrades, total_releases, success_count, error_count, total_elapsed
    ))
end

--------------------------------------------------------------------------------
-- RUN SCRIPT
--------------------------------------------------------------------------------
math.randomseed(os.time())
LOGGER:LogInfo("Starting Team Upgrade Script...")
LOGGER:LogInfo(string.format("Config: median_minus_threshold=%d, median_plus_threshold=%d, max_age=%d",
    config.median_minus_threshold, config.median_plus_threshold, config.max_age_for_signing))

do_team_upgrades()
