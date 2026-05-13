--------------------------------------------------------------------------------
-- Team Formation Position Management Script with Position-Count-Based Max - Made By The Mayo Man (themayonnaiseman)
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
    target_leagues = {61,60,14,13,16,17,19,20,2076,31,32,10,83,53,54,353,351,80,4,2012,1,2149,41,66,308,65,330,350,50,56,189,68,39}, -- Eg: 61 = EFL League Two, 60 = EFL League One, 14 = EFL Championship, premier league, lig 1, lig 2, Bund, bund 2, bund 3, erd, k league, Liga 1, liga 2, argentinan prem, A league, O.Bund, 1A pro l, CSL, 3F Sup L, ISL, Eliteserien, PKO BP Eks, liga port, SSE Airtricity, Superliga, Saudi L, Scot prem, Allsven, CSSL, super lig, MLS
    excluded_teams = { [1947] = true },         -- e.g. { [1234] = true }

    alternative_positions = {
        RW = {"RM"},
        LW = {"LM"},
        ST = {"RW","LW"},
        CDM= {"CM"},
        CAM= {"RW","LW"},
        CM = {"CDM","CAM"}
    },

    positions_to_roles = {
        GK={1,2,0},  CB={11,12,13}, RB={3,4,5},  LB={7,8,9},
        CDM={14,15,16}, RM={23,24,26}, CM={18,19,20}, LM={27,28,30},
        CAM={31,32,33}, ST={41,42,43}, RW={35,36,37}, LW={38,39,40}
    },

    multiplier = 3,  -- Number of players per position to keep
    
    -- Youth development settings
    protect_youth = true,             -- Set to false to disable youth protection
    youth_max_age = 23,               -- Maximum age to be considered a youth player
    youth_potential_bonus = 3,        -- How many points above median team rating the potential must be
    youth_potential_cap = 85,         -- Hard cap on (median + bonus): if team's median+bonus exceeds this,
                                      -- youth with potential >= cap are always protected regardless.
    youth_max_protected_per_pos = 1,  -- Maximum number of youth players to protect per position
    
    -- Performance settings
    batch_size = 20,                  -- Number of teams to process before saving progress
    
    -- Process control
    convert_non_formation_players = true,  -- Try to convert players not in formation to alternative positions
    release_non_formation_players = true,  -- Release players that don't fit formation (even after conversion attempts)
    prune_excess_players = true,           -- Release excess players beyond the multiplier limit

    -- Hole-filling safety net
    -- When a player would be released because their position isn't in formation, they'll instead
    -- be converted to a formation slot that currently has fewer than min_keep_per_formation_pos
    -- players, as long as the positions are related (via alternative_positions, bidirectional).
    min_keep_per_formation_pos = 1,   -- Minimum bodies per formation position before we stop cover-converting
    cover_bonus_per_pos = 1           -- Ensure at least (formation_count + this) are kept per position in pruning
}

--------------------------------------------------------------------------------
-- POSITION MAPPINGS
--------------------------------------------------------------------------------
local position_ids = {
    GK={0}, CB={5,1,4,6}, RB={3,2}, LB={7,8}, CDM={10,9,11},
    RM={12}, CM={14,13,15}, LM={16}, CAM={18,17,19},
    ST={25,20,21,22,24,26}, RW={23}, LW={27}
}

-- Pre-compute position mappings for faster lookups
local position_name_by_id = {}
local position_id_by_name = {}
for name, ids in pairs(position_ids) do
    position_id_by_name[name] = ids[1]
    for _, pid in ipairs(ids) do
        position_name_by_id[pid] = name
    end
end

local function get_position_id_from_position_name(pos_name)
    return position_id_by_name[pos_name] or -1
end

local function get_position_name_from_position_id(pid)
    return position_name_by_id[pid] or ("UnknownPos(".. tostring(pid) ..")")
end

-- Bidirectional cover map derived from config.alternative_positions.
-- cover_map[Y][X] = true means a player with preferred position X can plausibly cover formation slot Y.
-- We include both directions (X -> Y from alternative_positions[X], and the reverse) so we can
-- fill empty formation holes from a wider pool of similar positions.
local cover_map = {}
for from_pos, to_list in pairs(config.alternative_positions) do
    for _, to_pos in ipairs(to_list) do
        cover_map[to_pos] = cover_map[to_pos] or {}
        cover_map[to_pos][from_pos] = true
        cover_map[from_pos] = cover_map[from_pos] or {}
        cover_map[from_pos][to_pos] = true
    end
end

--------------------------------------------------------------------------------
-- CACHES AND INDEXES
--------------------------------------------------------------------------------
local player_cache = {}
local teams_processed = {}
local formation_cache = {}
local team_median_ratings = {}
local loaned_players = {}

-- Built once from a single scan of teamplayerlinks: team_id -> { player_id, ... }
-- All per-team roster lookups use this instead of re-scanning the full linking table.
local team_players_map = nil

-- Built once from a single scan of formations: team_id -> { "GK","CB",... }
local formations_map = nil

-- Run-wide counters populated during processing; surfaced in the end-of-run summary.
local run_stats = {
    teams_processed      = 0,
    teams_skipped        = 0,
    conversions          = 0,  -- step 2: non-formation -> alt position in formation
    cover_conversions    = 0,  -- step 3: convert instead of releasing to fill empty slot
    releases_step3       = 0,  -- step 3: released because position not in formation
    releases_step4       = 0,  -- step 4: released as excess beyond multiplier cap
    youth_protected      = 0,
    youth_released       = 0
}

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
    if next(player_cache) ~= nil then return end

    LOGGER:LogInfo("Building player index...")
    local start_time = os.time()
    local count = 0

    local rec = players_table_global:GetFirstRecord()
    while rec > 0 do
        local pid = players_table_global:GetRecordFieldValue(rec, "playerid")
        if pid then
            local birthdate = players_table_global:GetRecordFieldValue(rec, "birthdate")
            local pref_pos1 = players_table_global:GetRecordFieldValue(rec, "preferredposition1")

            player_cache[pid] = {
                record = rec,
                preferredposition1 = pref_pos1,
                overall = players_table_global:GetRecordFieldValue(rec, "overallrating") or
                          players_table_global:GetRecordFieldValue(rec, "overall") or 0,
                potential = players_table_global:GetRecordFieldValue(rec, "potential") or 0,
                age = calculate_player_age(birthdate),
                birthdate = birthdate,
                positionName = get_position_name_from_position_id(pref_pos1)
            }

            count = count + 1
            if count % 10000 == 0 then
                LOGGER:LogInfo(string.format("Indexed %d players so far...", count))
            end
        end
        rec = players_table_global:GetNextValidRecord()
    end

    LOGGER:LogInfo(string.format("Indexed %d players in %d seconds", count, os.time() - start_time))
end

--------------------------------------------------------------------------------
-- LOAN PLAYERS TRACKING
--------------------------------------------------------------------------------
local function build_loan_players_index()
    if next(loaned_players) ~= nil then
        return -- Already built
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
-- TEAM -> PLAYERS MAP (single scan)
--------------------------------------------------------------------------------
local function build_team_players_map()
    if team_players_map then return team_players_map end
    LOGGER:LogInfo("Building team-players map...")
    local start_time = os.time()
    team_players_map = {}
    if not team_player_links_global then return team_players_map end

    local count = 0
    local rec = team_player_links_global:GetFirstRecord()
    while rec > 0 do
        local t_id = team_player_links_global:GetRecordFieldValue(rec, "teamid")
        local p_id = team_player_links_global:GetRecordFieldValue(rec, "playerid")
        if t_id and p_id then
            local bucket = team_players_map[t_id]
            if not bucket then
                bucket = {}
                team_players_map[t_id] = bucket
            end
            bucket[#bucket + 1] = p_id
            count = count + 1
        end
        rec = team_player_links_global:GetNextValidRecord()
    end
    LOGGER:LogInfo(string.format("Team-players map: %d links in %ds.", count, os.time() - start_time))
    return team_players_map
end

--------------------------------------------------------------------------------
-- GET TEAM PLAYERS
--------------------------------------------------------------------------------
local team_player_cache = {} -- Cache team players to avoid redundant lookups

local function get_team_players(team_id)
    if team_player_cache[team_id] then
        return team_player_cache[team_id]
    end

    index_players_by_id()
    build_loan_players_index()
    build_team_players_map()

    local players = {}
    local ids = team_players_map[team_id]
    if ids then
        for _, p_id in ipairs(ids) do
            if not is_player_on_loan_from(p_id, team_id) then
                local cached_player = player_cache[p_id]
                if cached_player then
                    local pref_pos = cached_player.preferredposition1 or 0
                    players[#players + 1] = {
                        id = p_id,
                        posName = get_position_name_from_position_id(pref_pos),
                        overall = cached_player.overall,
                        potential = cached_player.potential,
                        age = cached_player.age
                    }
                end
            end
        end
    end

    team_player_cache[team_id] = players
    return players
end

-- Function to invalidate team player cache when players are updated/released.
-- Also invalidates the cached median rating so downstream youth-potential checks
-- stay accurate as the roster changes during processing.
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
-- Calculate Team Median Rating 
--------------------------------------------------------------------------------
local function calculate_team_median_rating(team_id)
    if team_median_ratings[team_id] then
        return team_median_ratings[team_id]
    end
    
    local players_list = get_team_players(team_id)
    if #players_list == 0 then
        return 65 -- Default value if no players found
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
    
    -- Ensure median is stored as integer for proper string formatting
    median = math.floor(median + 0.5)
    team_median_ratings[team_id] = median
    return median
end

--------------------------------------------------------------------------------
-- GET FORMATION POSITIONS
--------------------------------------------------------------------------------
-- Build formations map once: team_id -> {"GK","CB","CB",...}
local function build_formations_map()
    if formations_map then return formations_map end
    formations_map = {}
    if not formations_table_global then return formations_map end

    local rec = formations_table_global:GetFirstRecord()
    while rec > 0 do
        local t_id = formations_table_global:GetRecordFieldValue(rec, "teamid")
        if t_id then
            local positions = {}
            for i = 0, 10 do
                local pos_id = formations_table_global:GetRecordFieldValue(rec, ("position%d"):format(i)) or 0
                positions[#positions + 1] = get_position_name_from_position_id(pos_id)
            end
            formations_map[t_id] = positions
        end
        rec = formations_table_global:GetNextValidRecord()
    end
    return formations_map
end

-- Returns a table of e.g. {"GK","CB","CB","ST","CM",...}
local function get_formation_positions(team_id)
    if formation_cache[team_id] then return formation_cache[team_id] end
    build_formations_map()
    local positions = formations_map[team_id] or {}
    formation_cache[team_id] = positions
    return positions
end

--------------------------------------------------------------------------------
-- Update Position + Roles
--------------------------------------------------------------------------------
-- Note: these helpers are intentionally quiet now; the conversion callers log a
-- single consolidated line per player so we don't get 3+ lines per conversion.
local function update_player_preferred_position_1(player_id, new_pos_id, players_table)
    local player = player_cache[player_id]
    if not player then
        LOGGER:LogWarning(string.format("Player %d not found in cache. Could not update position.", player_id))
        return
    end

    local rec = player.record
    local old = players_table:GetRecordFieldValue(rec, "preferredposition1")
    local pos2 = players_table:GetRecordFieldValue(rec, "preferredposition2")
    local pos3 = players_table:GetRecordFieldValue(rec, "preferredposition3")

    players_table:SetRecordFieldValue(rec, "preferredposition1", new_pos_id)
    player.preferredposition1 = new_pos_id

    if new_pos_id == 0 then
        players_table:SetRecordFieldValue(rec, "preferredposition2", -1)
        players_table:SetRecordFieldValue(rec, "preferredposition3", -1)
        return
    end
    if pos2 == new_pos_id then
        players_table:SetRecordFieldValue(rec, "preferredposition2", old)
    end
    if pos3 == new_pos_id then
        players_table:SetRecordFieldValue(rec, "preferredposition3", old)
    end
end

local function update_all_player_roles(player_id, r1, r2, r3, players_table)
    local player = player_cache[player_id]
    if not player then
        LOGGER:LogWarning(string.format("Player %d not found in cache. Could not update roles.", player_id))
        return
    end

    local rec = player.record
    local pos = players_table:GetRecordFieldValue(rec, "preferredposition1")
    if pos == 0 then r3 = 0 end
    players_table:SetRecordFieldValue(rec, "role1", r1)
    players_table:SetRecordFieldValue(rec, "role2", r2)
    players_table:SetRecordFieldValue(rec, "role3", r3)
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

    -- median + bonus, capped: elite squads still have to accept youth with potential >= cap
    local potential_threshold = team_median_rating + config.youth_potential_bonus
    local cap = config.youth_potential_cap
    if cap and potential_threshold > cap then
        potential_threshold = cap
    end
    return player.potential >= potential_threshold
end

--------------------------------------------------------------------------------
-- ATTEMPT CONVERSION (Step 2)
--------------------------------------------------------------------------------
local function try_convert_player(player_id, old_posName, formation_set, team_id)
    -- Don't try to convert loaned players
    if loaned_players[player_id] then
        return false
    end
    
    local alt_list = config.alternative_positions[old_posName]
    if not alt_list then
        return false
    end
    
    for _, alt_pos in ipairs(alt_list) do
        if formation_set[alt_pos] then
            local new_pos_id = get_position_id_from_position_name(alt_pos)
            update_player_preferred_position_1(player_id, new_pos_id, players_table_global)

            local roles = config.positions_to_roles[alt_pos]
            if roles then
                update_all_player_roles(player_id, roles[1], roles[2], roles[3], players_table_global)
            end
            LOGGER:LogInfo(string.format("Converted %d: %s -> %s.", player_id, old_posName, alt_pos))

            invalidate_team_player_cache(team_id)
            return true
        end
    end
    return false
end

--------------------------------------------------------------------------------
-- COVER EMPTY FORMATION SLOT (before step 3 release)
--------------------------------------------------------------------------------
-- If a non-formation player is about to be released and the team has a formation
-- slot below the min_keep_per_formation_pos threshold that this player can
-- plausibly cover (via the bidirectional cover_map), convert them to fill it
-- instead of releasing. Mutates `have` in place on success.
local function try_cover_empty_formation_slot(player_id, old_posName, formation_set, have, team_id)
    if loaned_players[player_id] then
        return false
    end

    local min_keep = config.min_keep_per_formation_pos or 1
    local candidates = cover_map[old_posName]
    if not candidates then
        return false
    end

    -- Deterministic iteration order so logs are easier to follow
    local empty_positions = {}
    for form_pos in pairs(formation_set) do
        if candidates[form_pos] and (have[form_pos] or 0) < min_keep then
            empty_positions[#empty_positions + 1] = form_pos
        end
    end
    if #empty_positions == 0 then
        return false
    end
    table.sort(empty_positions, function(a, b)
        return (have[a] or 0) < (have[b] or 0)
    end)

    local target_pos = empty_positions[1]
    local new_pos_id = get_position_id_from_position_name(target_pos)
    update_player_preferred_position_1(player_id, new_pos_id, players_table_global)

    local roles = config.positions_to_roles[target_pos]
    if roles then
        update_all_player_roles(player_id, roles[1], roles[2], roles[3], players_table_global)
    end

    LOGGER:LogInfo(string.format(
        "Cover-converted %d: %s -> %s (slot had %d, min %d).",
        player_id, old_posName, target_pos, have[target_pos] or 0, min_keep
    ))

    have[target_pos] = (have[target_pos] or 0) + 1
    invalidate_team_player_cache(team_id)
    return true
end

--------------------------------------------------------------------------------
-- RELEASE A PLAYER (Step 3)
--------------------------------------------------------------------------------
local function release_player(player_id, team_id)
    if loaned_players[player_id] then
        -- silently skip loaned players; this was noisy in logs
        return false
    end

    local success = pcall(function()
        ReleasePlayerFromTeam(player_id)
    end)

    if success then
        LOGGER:LogInfo(string.format(
            "Released %s (%d) from %s (%d).",
            GetPlayerName(player_id), player_id, GetTeamName(team_id), team_id
        ))

        -- Keep the team->players map in sync so subsequent rebuilds are correct.
        if team_players_map then
            local bucket = team_players_map[team_id]
            if bucket then
                for i = 1, #bucket do
                    if bucket[i] == player_id then
                        bucket[i] = bucket[#bucket]
                        bucket[#bucket] = nil
                        break
                    end
                end
            end
        end
        invalidate_team_player_cache(team_id)
        return true
    else
        LOGGER:LogWarning(string.format("Failed to release player %d from team %d", player_id, team_id))
        return false
    end
end

--------------------------------------------------------------------------------
-- PROCESS ONE TEAM
--------------------------------------------------------------------------------
local function process_team(team_id)
    if teams_processed[team_id] then
        return -- Skip already processed teams
    end
    
    local team_name = GetTeamName(team_id)
    LOGGER:LogInfo(string.format("Processing team %s (%d)...", team_name, team_id))
    local start_time = os.time()

    -- 1) Grab formation positions
    local formation_positions = get_formation_positions(team_id)
    if #formation_positions == 0 then
        LOGGER:LogInfo(string.format("No formation found for team %s. Skipping steps.", team_name))
        teams_processed[team_id] = true
        run_stats.teams_skipped = run_stats.teams_skipped + 1
        return
    end

    -- Build a set for quick membership checks, plus a count
    local formation_set = {}
    local formation_count = {}  -- e.g. {ST=2, GK=1, CB=2, ...}
    for _, posName in ipairs(formation_positions) do
        formation_set[posName] = true
        formation_count[posName] = (formation_count[posName] or 0) + 1
    end

    -- Calculate team median rating for high potential youth detection
    local team_median = calculate_team_median_rating(team_id)

    -- 2) Convert any player not in the formation
    local players_list = get_team_players(team_id)
    
    local conversions = 0
    if config.convert_non_formation_players then
        -- First batch: identify all non-formation players that need conversion
        local players_to_convert = {}
        for _, ply in ipairs(players_list) do
            if not formation_set[ply.posName] then
                table.insert(players_to_convert, ply)
            end
        end
        
        for _, ply in ipairs(players_to_convert) do
            local success = try_convert_player(ply.id, ply.posName, formation_set, team_id)
            if success then conversions = conversions + 1 end
        end
        if conversions > 0 then
            LOGGER:LogInfo(string.format("Step 2: converted %d to formation positions.", conversions))
        end
        run_stats.conversions = run_stats.conversions + conversions
    else
        LOGGER:LogInfo("Player position conversion is disabled in config")
    end

    -- 3) Release leftover mismatches (including high potential youth that couldn't be converted)
    local releases = 0
    local cover_conversions = 0
    if config.release_non_formation_players then
        -- We need to refresh the player list as positions may have changed
        invalidate_team_player_cache(team_id)
        players_list = get_team_players(team_id)

        -- Count current bodies per formation position so cover-before-release can
        -- target the slots that are actually below min_keep_per_formation_pos.
        local have = {}
        for _, ply in ipairs(players_list) do
            if formation_set[ply.posName] then
                have[ply.posName] = (have[ply.posName] or 0) + 1
            end
        end

        local players_to_release = {}
        for _, ply in ipairs(players_list) do
            if not formation_set[ply.posName] then
                table.insert(players_to_release, ply)
            end
        end

        -- Try to convert the best-rated non-formation players into empty slots first,
        -- so if we only have one body to spare, the better player covers the hole.
        table.sort(players_to_release, function(a, b) return a.overall > b.overall end)

        for _, ply in ipairs(players_to_release) do
            if try_cover_empty_formation_slot(ply.id, ply.posName, formation_set, have, team_id) then
                cover_conversions = cover_conversions + 1
            else
                local success = release_player(ply.id, team_id)
                if success then releases = releases + 1 end
            end
        end
        if cover_conversions > 0 or releases > 0 then
            LOGGER:LogInfo(string.format(
                "Step 3: cover-converted %d, released %d (non-formation).",
                cover_conversions, releases
            ))
        end
        run_stats.cover_conversions = run_stats.cover_conversions + cover_conversions
        run_stats.releases_step3 = run_stats.releases_step3 + releases
    else
        LOGGER:LogInfo("Non-formation player release is disabled in config")
    end

    -- 4) Limit each position to "formation_count * config.multiplier"
    local position_releases = 0
    if config.prune_excess_players then
        -- Refresh player list again after releases
        invalidate_team_player_cache(team_id)
        players_list = get_team_players(team_id)
        
        local grouped = {}
        for _, ply in ipairs(players_list) do
            grouped[ply.posName] = grouped[ply.posName] or {}
            table.insert(grouped[ply.posName], ply)
        end
    
        for posName, arr in pairs(grouped) do
            local demand_for_pos = formation_count[posName] or 0
            if demand_for_pos > 0 then
                -- Ensure we always keep at least (formation_count + cover_bonus_per_pos) bodies
                -- in addition to respecting the multiplier-based cap.
                local min_keep_for_pos = math.max(
                    demand_for_pos + (config.cover_bonus_per_pos or 0),
                    config.min_keep_per_formation_pos or 1
                )
                local max_for_pos = math.max(demand_for_pos * config.multiplier, min_keep_for_pos)

                if #arr > max_for_pos then
                    -- Sort all players by overall first (descending)
                    table.sort(arr, function(a, b)
                        return a.overall > b.overall
                    end)

                    -- Youth cap: up to config.youth_max_protected_per_pos slots, but never
                    -- enough to push out a starter-quality player (i.e. regulars >= demand).
                    local youth_eligible_slots = math.min(
                        config.youth_max_protected_per_pos or 1,
                        math.max(0, max_for_pos - demand_for_pos)
                    )
                    local regular_slots = max_for_pos - youth_eligible_slots
                    
                    -- First identify ALL high potential youth players
                    local all_youth_candidates = {}
                    for i = 1, #arr do
                        if is_high_potential_youth(arr[i], team_median) then
                            table.insert(all_youth_candidates, {
                                player = arr[i],
                                index = i,
                                is_in_top_overall = i <= regular_slots
                            })
                        end
                    end
                    
                    -- Sort ALL youth candidates by potential (descending)
                    table.sort(all_youth_candidates, function(a, b)
                        return a.player.potential > b.player.potential
                    end)
                    
                    -- Track which players to keep
                    local players_to_keep = {}
                    
                    -- First add all top overall players
                    for i = 1, regular_slots do
                        players_to_keep[arr[i].id] = true
                    end
                    
                    -- Then add highest potential youth players up to the limit
                    -- but only if they're not already in the top overall slots
                    local youth_added = 0
                    for _, candidate in ipairs(all_youth_candidates) do
                        if not candidate.is_in_top_overall and youth_added < youth_eligible_slots then
                            players_to_keep[candidate.player.id] = true
                            youth_added = youth_added + 1
                            run_stats.youth_protected = run_stats.youth_protected + 1

                            LOGGER:LogInfo(string.format(
                                "Protected youth %d (OVR %d, POT %d, Age %d) at %s.",
                                candidate.player.id, candidate.player.overall,
                                candidate.player.potential, candidate.player.age, posName
                            ))
                        end
                    end
                    
                    -- Fill remaining slots with next highest overall players
                    local filled_count = regular_slots + youth_added
                    if filled_count < max_for_pos then
                        for i = regular_slots + 1, #arr do
                            if not players_to_keep[arr[i].id] and filled_count < max_for_pos then
                                players_to_keep[arr[i].id] = true
                                filled_count = filled_count + 1
                            end
                        end
                    end
                    
                    -- Release players not in the keep list
                    local released = 0
                    for _, player in ipairs(arr) do
                        if not players_to_keep[player.id] then
                            if release_player(player.id, team_id) then
                                released = released + 1
                                position_releases = position_releases + 1
                                if is_high_potential_youth(player, team_median) then
                                    run_stats.youth_released = run_stats.youth_released + 1
                                end
                            end
                        end
                    end

                    LOGGER:LogInfo(string.format(
                        "Step 4 %s: %d -> kept %d top + %d youth, released %d.",
                        posName, #arr, regular_slots, youth_added, released
                    ))
                end
            end
        end
    else
        LOGGER:LogInfo("Excess player pruning is disabled in config")
    end

    local elapsed = os.time() - start_time
    LOGGER:LogInfo(string.format(
        "Done team %s (%d) in %ds: %d released (step3:%d, step4:%d).",
        team_name, team_id, elapsed, releases + position_releases, releases, position_releases
    ))
    run_stats.releases_step4 = run_stats.releases_step4 + position_releases
    run_stats.teams_processed = run_stats.teams_processed + 1
    teams_processed[team_id] = true
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

    -- Single pass: index league -> {team_id,...}, then flatten for the target leagues.
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
        for _, t_id in ipairs(league_team_map[league_id] or {}) do
            if not config.excluded_teams[t_id] then
                pool[#pool + 1] = t_id
            end
        end
    end

    return pool
end

--------------------------------------------------------------------------------
-- SAVE/RESUME PROGRESS
--------------------------------------------------------------------------------
local function save_progress(current_idx, team_pool, success_count, error_count)
    local progress_data = {
        current_idx = current_idx,
        total_teams = #team_pool,
        success_count = success_count,
        error_count = error_count,
        teams_processed = teams_processed,
        timestamp = os.time()
    }
    
    local success = pcall(function()
        local file = io.open("release_players_progress.dat", "w")
        if file then
            file:write(tostring(progress_data.current_idx) .. "\n")
            file:write(tostring(progress_data.total_teams) .. "\n")
            file:write(tostring(progress_data.success_count) .. "\n")
            file:write(tostring(progress_data.error_count) .. "\n")
            file:write(tostring(progress_data.timestamp) .. "\n")
            
            -- Write processed teams as comma-separated list
            local processed_teams = {}
            for team_id, _ in pairs(teams_processed) do
                table.insert(processed_teams, tostring(team_id))
            end
            file:write(table.concat(processed_teams, ","))
            
            file:close()
            LOGGER:LogInfo("Progress saved successfully")
        else
            LOGGER:LogWarning("Failed to save progress - couldn't open file")
        end
    end)
    
    if not success then
        LOGGER:LogWarning("Failed to save progress due to error")
    end
end

local function load_progress()
    local progress_data = {
        current_idx = 1,
        total_teams = 0,
        success_count = 0,
        error_count = 0,
        teams_processed = {},
        timestamp = 0
    }
    
    local success = pcall(function()
        local file = io.open("release_players_progress.dat", "r")
        if file then
            progress_data.current_idx = tonumber(file:read("*l")) or 1
            progress_data.total_teams = tonumber(file:read("*l")) or 0
            progress_data.success_count = tonumber(file:read("*l")) or 0
            progress_data.error_count = tonumber(file:read("*l")) or 0
            progress_data.timestamp = tonumber(file:read("*l")) or 0
            
            -- Read processed teams
            local processed_teams_str = file:read("*l") or ""
            if processed_teams_str ~= "" then
                for team_id_str in processed_teams_str:gmatch("([^,]+)") do
                    local team_id = tonumber(team_id_str)
                    if team_id then
                        progress_data.teams_processed[team_id] = true
                    end
                end
            end
            
            file:close()
            LOGGER:LogInfo(string.format("Loaded progress: %d/%d teams processed", 
                progress_data.current_idx - 1, progress_data.total_teams))
        else
            LOGGER:LogInfo("No progress file found, starting fresh")
        end
    end)
    
    if not success then
        LOGGER:LogWarning("Failed to load progress due to error")
    end
    
    return progress_data
end

--------------------------------------------------------------------------------
-- MAIN
--------------------------------------------------------------------------------
local function do_position_changes()
    local start_time = os.time()
    
    -- Pre-index all players for faster lookups
    index_players_by_id()
    
    -- Build loan players index
    build_loan_players_index()
    
    local team_pool = build_team_pool()
    if #team_pool == 0 then
        LOGGER:LogInfo("No teams found in target leagues. Exiting.")
        return
    end
    LOGGER:LogInfo(string.format(
        "Collected %d teams from leagues: %s",
        #team_pool, table.concat(config.target_leagues, ", ")
    ))

    -- Load previous progress if available
    local progress = load_progress()
    local current_idx = progress.current_idx
    local success_count = progress.success_count
    local error_count = progress.error_count
    
    -- Restore previously processed teams
    for team_id, _ in pairs(progress.teams_processed) do
        teams_processed[team_id] = true
    end
    
    -- Ask user if they want to resume or start fresh
    if current_idx > 1 then
        local last_run_time = os.date("%Y-%m-%d %H:%M:%S", progress.timestamp)
        local resume = MessageBox("Resume Progress?", string.format(
            "Previous progress found (%d/%d teams) from %s.\nDo you want to resume?",
            current_idx - 1, #team_pool, last_run_time
        ), true) -- true for OK/Cancel dialog
        
        if not resume then
            -- User chose to start fresh
            current_idx = 1
            success_count = 0
            error_count = 0
            teams_processed = {}
        end
    end
    
    local total_teams = #team_pool

    for idx = current_idx, total_teams do
        local team_id = team_pool[idx]
        
        -- Provide periodic status updates
        if idx % 5 == 0 or idx == current_idx or idx == total_teams then
            local percent_complete = math.floor(idx / total_teams * 100)
            local elapsed = os.time() - start_time
            local remaining_estimate = elapsed > 0 and math.floor((total_teams - idx) * (elapsed / (idx - current_idx + 1))) or "unknown"
            
            LOGGER:LogInfo(string.format(
                "Progress: %d/%d teams (%d%%) - %d successful, %d errors. Est. time remaining: %s seconds", 
                idx, total_teams, percent_complete, success_count, error_count, tostring(remaining_estimate)
            ))
        end
        
        -- Add error handling around individual team processing
        local success, err = pcall(function()
            process_team(team_id)
        end)
        
        if success then
            success_count = success_count + 1
        else
            error_count = error_count + 1
            LOGGER:LogError(string.format("Error processing team %d: %s", team_id, tostring(err)))
        end
        
        if idx % config.batch_size == 0 or idx == total_teams then
            save_progress(idx + 1, team_pool, success_count, error_count)
        end
    end
    
    local total_elapsed = os.time() - start_time
    local total_released = run_stats.releases_step3 + run_stats.releases_step4
    local total_converted = run_stats.conversions + run_stats.cover_conversions

    LOGGER:LogInfo("=== Release run summary ===")
    LOGGER:LogInfo(string.format(
        "Teams processed: %d (errors %d, no-formation skipped %d).",
        success_count, error_count, run_stats.teams_skipped
    ))
    LOGGER:LogInfo(string.format(
        "Conversions: %d total (step2 %d, cover %d).",
        total_converted, run_stats.conversions, run_stats.cover_conversions
    ))
    LOGGER:LogInfo(string.format(
        "Releases: %d total (step3 non-formation %d, step4 excess %d).",
        total_released, run_stats.releases_step3, run_stats.releases_step4
    ))
    LOGGER:LogInfo(string.format(
        "Youth: protected %d, released %d. Elapsed: %ds.",
        run_stats.youth_protected, run_stats.youth_released, total_elapsed
    ))

    MessageBox("Processing Complete", string.format(
        "Teams: %d (errors %d).\nConverted: %d (step2 %d / cover %d).\nReleased: %d (step3 %d / step4 %d).\nYouth: protected %d, released %d.\nTime: %ds.",
        success_count, error_count,
        total_converted, run_stats.conversions, run_stats.cover_conversions,
        total_released, run_stats.releases_step3, run_stats.releases_step4,
        run_stats.youth_protected, run_stats.youth_released, total_elapsed
    ))
    
    os.remove("release_players_progress.dat")
end

--------------------------------------------------------------------------------
-- RUN SCRIPT
--------------------------------------------------------------------------------
math.randomseed(os.time())
LOGGER:LogInfo("Starting Team Formation Position Management Script...")

do_position_changes()
