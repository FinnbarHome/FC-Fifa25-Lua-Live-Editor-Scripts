--------------------------------------------------------------------------------
-- Team Ratings Boost Script - Made By The Mayo Man (themayonnaiseman)
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
    -- Target leagues to process (all major leagues)
    target_leagues = {61,60,14,13,16,17,19,20,2076,31,32,10,83,53,54,353,351,80,4,2012,1,2149,41,66,308,65,330,350,50,56,189,68,39},
    excluded_teams = { [111592] = true, [110] = true }, -- Exclude free agents team + team of choice (currently Wolves)
    
    -- Player stat field names
    player_stats = {
        "crossing", "finishing", "headingaccuracy", "shortpassing", "volleys",
        "defensiveawareness", "standingtackle", "slidingtackle", "dribbling",
        "curve", "freekickaccuracy", "longpassing", "ballcontrol", "shotpower",
        "acceleration", "jumping", "stamina", "strength", "longshots",
        "sprintspeed", "agility", "reactions", "balance", "aggression",
        "gkkicking", "interceptions", "positioning", "composure", "penalties",
        "gkdiving", "vision", "gkhandling", "gkpositioning", "gkreflexes"
    },
    
    -- Goalkeeper-specific stats
    gk_stats = {
        "gkdiving", "gkhandling", "gkpositioning", "gkreflexes", "gkkicking"
    },
    
    -- Position mappings
    position_ids = {
        GK={0}, CB={5,1,4,6}, RB={3,2}, LB={7,8}, CDM={10,9,11},
        RM={12}, CM={14,13,15}, LM={16}, CAM={18,17,19},
        ST={25,20,21,22,24,26}, RW={23}, LW={27}
    },
    
    -- Process control
    batch_size = 100,
    fix_potentials = true,
    boost_players = true
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

local function is_goalkeeper(position_id)
    return position_id == 0
end

--------------------------------------------------------------------------------
-- CACHES AND INDEXES
--------------------------------------------------------------------------------
local player_cache = {}
local formation_cache = {}
local team_median_ratings = {}
local loaned_players = {}
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
-- FIX PLAYER POTENTIALS
--------------------------------------------------------------------------------
local function fix_player_potentials()
    if not config.fix_potentials then
        return 0
    end
    
    LOGGER:LogInfo("Fixing player potentials...")
    index_players_by_id()
    
    local fixed_count = 0
    local total_count = 0
    
    local rec = players_table_global:GetFirstRecord()
    while rec > 0 do
        local pid = players_table_global:GetRecordFieldValue(rec, "playerid")
        if pid then
            local overall = players_table_global:GetRecordFieldValue(rec, "overallrating") or 
                           players_table_global:GetRecordFieldValue(rec, "overall") or 0
            local potential = players_table_global:GetRecordFieldValue(rec, "potential") or 0
            
            if potential < overall then
                -- Set potential equal to overall
                players_table_global:SetRecordFieldValue(rec, "potential", overall)
                fixed_count = fixed_count + 1
                
                if fixed_count % 1000 == 0 then
                    LOGGER:LogInfo(string.format("Fixed %d player potentials so far...", fixed_count))
                end
            end
            
            total_count = total_count + 1
        end
        rec = players_table_global:GetNextValidRecord()
    end
    
    LOGGER:LogInfo(string.format("Fixed %d out of %d player potentials", fixed_count, total_count))
    return fixed_count
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
                    positionId = cached_player.preferredposition1,
                    overall = cached_player.overall,
                    potential = cached_player.potential,
                    age = cached_player.age,
                    record = cached_player.record
                }
            end
        end
    end
    
    team_player_cache[team_id] = players
    return players
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
                positions[#positions + 1] = {
                    name = pos_name,
                    id = pos_id
                }
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
-- VALIDATE PLAYER STATS
--------------------------------------------------------------------------------
local function validate_player_stats(player_record)
    -- Test the first player to make sure we can retrieve stats
    for _, stat_name in ipairs(config.player_stats) do
        local value = players_table_global:GetRecordFieldValue(player_record, stat_name)
        if not value or value == 0 then
            LOGGER:LogError(string.format("Cannot retrieve stat '%s' for first player. Ending execution.", stat_name))
            return false
        end
    end
    return true
end

--------------------------------------------------------------------------------
-- BOOST PLAYER STATS
--------------------------------------------------------------------------------
local function boost_player_stats(player_id, player_record, is_gk)
    local stats_boosted = 0
    
    -- Check if player has development plan
    local has_dev_plan = false

    local user_team_playerids = GetUserSeniorTeamPlayerIDs() or {}
    if user_team_playerids[player_id] then
        has_dev_plan = PlayerHasDevelopementPlan(player_id)
    end

    
    for _, stat_name in ipairs(config.player_stats) do
        current_value_stat =players_table_global:GetRecordFieldValue(player_record, stat_name)
        if current_value_stat < 99 then

            -- Skip GK stats for non-goalkeepers
            local is_gk_stat = false
            for _, gk_stat in ipairs(config.gk_stats) do
                if stat_name == gk_stat then
                    is_gk_stat = true
                    break
                end
            end
            
            if not is_gk and is_gk_stat then
                -- Skip goalkeeper stats for non-goalkeepers
                goto continue
            end
            
            local current_value = players_table_global:GetRecordFieldValue(player_record, stat_name)
            if current_value and current_value > 0 then
                local new_value = math.min(99, current_value + 1)
                
                -- Set in players table
                players_table_global:SetRecordFieldValue(player_record, stat_name, new_value)
                --LOGGER:LogInfo(string.format("Set %s in players table for %s", stat_name, GetPlayerName(player_id)))

                -- Also set in development plan if player has one
                if has_dev_plan then
                    PlayerSetValueInDevelopementPlan(player_id, stat_name, new_value)
                    -- LOGGER:LogInfo(string.format("Set %s in development plan for %s", stat_name, GetPlayerName(player_id)))
                end
                


                stats_boosted = stats_boosted + 1
            end
        end

        ::continue::
    end
    
    -- Clear Player modifier to not affect overall
    if stats_boosted > 0 then
        players_table_global:SetRecordFieldValue(player_record, "modifier", 1)
        players_table_global:SetRecordFieldValue(player_record, "modifier", 0)

        current_overall = players_table_global:GetRecordFieldValue(player_record, "overallrating")
        current_potential = players_table_global:GetRecordFieldValue(player_record, "potential")

        if current_potential < current_overall then
            players_table_global:SetRecordFieldValue(player_record, "potential", current_overall)
        end
    end
    
    return stats_boosted
end

--------------------------------------------------------------------------------
-- PROCESS TEAM BOOSTS
--------------------------------------------------------------------------------
local function process_team_boosts(team_id)
    local team_name = GetTeamName(team_id)
    local formation_positions = get_formation_positions(team_id)
    
    LOGGER:LogInfo(string.format("Processing team: %s (ID: %d)", team_name, team_id))
    
    if #formation_positions == 0 then
        LOGGER:LogInfo(string.format("  No formation found for %s, skipping", team_name))
        return 0, 0
    end
    
    local players_list = get_team_players(team_id)
    local team_median = calculate_team_median_rating(team_id)
    
    LOGGER:LogInfo(string.format("  Squad size: %d players, Team median rating: %d", #players_list, team_median))
    
    -- Group formation positions by position name and count duplicates
    local position_counts = {}
    for _, pos in ipairs(formation_positions) do
        position_counts[pos.name] = (position_counts[pos.name] or 0) + 1
    end
    
    -- Log formation structure
    local formation_summary = {}
    for pos_name, count in pairs(position_counts) do
        if count > 1 then
            table.insert(formation_summary, string.format("%dx%s", count, pos_name))
        else
            table.insert(formation_summary, pos_name)
        end
    end
    LOGGER:LogInfo(string.format("  Formation positions: %s", table.concat(formation_summary, ", ")))
    
    -- Find best players for each position slot
    local selected_players = {}
    
    for position_name, count in pairs(position_counts) do
        -- Get all players for this position
        local position_players = {}
        for _, player in ipairs(players_list) do
            if player.posName == position_name then
                table.insert(position_players, player)
            end
        end
        
        -- Sort by overall rating (descending)
        table.sort(position_players, function(a, b) return a.overall > b.overall end)
        
        -- Select the best 'count' players for this position
        for i = 1, math.min(count, #position_players) do
            table.insert(selected_players, position_players[i])
        end
    end
    
    LOGGER:LogInfo(string.format("  Selected %d best players for formation positions", #selected_players))
    
    -- Boost stats for selected players who are below team median
    local players_boosted = 0
    local total_stats_boosted = 0
    local eligible_players = 0
    
    for _, player in ipairs(selected_players) do
        if player.overall < team_median then
            eligible_players = eligible_players + 1
            local is_gk = is_goalkeeper(player.positionId)
            local stats_boosted = boost_player_stats(player.id, player.record, is_gk)
            
            if stats_boosted > 0 then
                players_boosted = players_boosted + 1
                total_stats_boosted = total_stats_boosted + stats_boosted
                
                local player_name = GetPlayerName(player.id)
                LOGGER:LogInfo(string.format(
                    "    - Boosted %s (%s, Age %d) - OVR: %d → +%d stats [Below median: %d]",
                    player_name, player.posName, player.age, player.overall, stats_boosted, team_median
                ))
            end
        end
    end
    
    if eligible_players == 0 then
        LOGGER:LogInfo(string.format("  No players below median (%d) found - no boosts needed", team_median))
    else
        LOGGER:LogInfo(string.format("  Result: %d/%d eligible players boosted (%d total stats increased)", 
            players_boosted, eligible_players, total_stats_boosted))
    end
    
    return players_boosted, total_stats_boosted
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
-- MAIN FUNCTION
--------------------------------------------------------------------------------
local function do_player_boost()
    local start_time = os.time()
    
    -- Pre-index all players
    index_players_by_id()
    build_loan_players_index()
    
    -- Validate that we can read player stats by testing the first player
    local first_rec = players_table_global:GetFirstRecord()
    if first_rec <= 0 then
        LOGGER:LogError("No players found in database. Exiting.")
        return
    end
    
    if not validate_player_stats(first_rec) then
        LOGGER:LogError("Failed to validate player stats. Script execution terminated.")
        return
    end
    
    LOGGER:LogInfo("Player stats validation successful. Proceeding with script execution.")
    
    -- Fix player potentials
    local potentials_fixed = 0
    if config.fix_potentials then
        potentials_fixed = fix_player_potentials()
    end
    
    -- Process team boosts
    local total_players_boosted = 0
    local total_stats_boosted = 0
    local team_pool = {}
    
    if config.boost_players then
        -- Build team pool
        team_pool = build_team_pool()
        if #team_pool == 0 then
            LOGGER:LogInfo("No teams found in target leagues. Skipping team boost.")
        else
            LOGGER:LogInfo(string.format(
                "Processing %d teams from leagues: %s",
                #team_pool, table.concat(config.target_leagues, ", ")
            ))
            LOGGER:LogInfo("=" .. string.rep("=", 70))
            
            for idx, team_id in ipairs(team_pool) do
                -- Show progress every 50 teams
                if idx % 50 == 0 or idx == 1 then
                    local percent_complete = math.floor(idx / #team_pool * 100)
                    LOGGER:LogInfo(string.format(
                        "PROGRESS: %d/%d teams (%d%%) processed - %d players boosted, %d stats increased", 
                        idx, #team_pool, percent_complete, total_players_boosted, total_stats_boosted
                    ))
                    LOGGER:LogInfo("-" .. string.rep("-", 70))
                end
                
                local success, err = pcall(function()
                    local players_boosted, stats_boosted = process_team_boosts(team_id)
                    total_players_boosted = total_players_boosted + players_boosted
                    total_stats_boosted = total_stats_boosted + stats_boosted
                end)
                
                if not success then
                    LOGGER:LogError(string.format("ERROR processing team %d: %s", team_id, tostring(err)))
                end
                
                -- Add separator after each team for readability
                if idx < #team_pool then
                    LOGGER:LogInfo("")
                end
            end
        end
    end
    
    local total_elapsed = os.time() - start_time
    
    LOGGER:LogInfo("=" .. string.rep("=", 70))
    LOGGER:LogInfo("SCRIPT EXECUTION COMPLETED")
    LOGGER:LogInfo("=" .. string.rep("=", 70))
    LOGGER:LogInfo(string.format("Execution time: %d seconds", total_elapsed))
    LOGGER:LogInfo(string.format("Player potentials fixed: %d", potentials_fixed))
    if config.boost_players and #team_pool > 0 then
        LOGGER:LogInfo(string.format("Teams processed: %d", #team_pool))
        LOGGER:LogInfo(string.format("Players boosted: %d", total_players_boosted))
        LOGGER:LogInfo(string.format("Total stats increased: %d", total_stats_boosted))
        if total_players_boosted > 0 then
            local avg_stats_per_player = math.floor(total_stats_boosted / total_players_boosted * 100) / 100
            LOGGER:LogInfo(string.format("Average stats boosted per player: %.1f", avg_stats_per_player))
        end
    end
    LOGGER:LogInfo("=" .. string.rep("=", 70))
    
    -- Show results
    MessageBox("Player Boost Complete", string.format(
        "Potentials fixed: %d\nPlayers boosted: %d\nTotal stats increased: %d\nTime: %d seconds",
        potentials_fixed, total_players_boosted, total_stats_boosted, total_elapsed
    ))
end

--------------------------------------------------------------------------------
-- RUN SCRIPT
--------------------------------------------------------------------------------
math.randomseed(os.time())
LOGGER:LogInfo("Starting Player Potential Fix & Team Boost Script...")
LOGGER:LogInfo(string.format("Config: fix_potentials=%s, boost_players=%s",
    tostring(config.fix_potentials), tostring(config.boost_players)))

do_player_boost() 