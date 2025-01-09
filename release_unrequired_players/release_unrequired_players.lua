--------------------------------------------------------------------------------
-- Team Formation Position Management Script
--------------------------------------------------------------------------------
require 'imports/career_mode/helpers'
require 'imports/other/helpers'

-- We'll use the global ReleasePlayerFromTeam(player_id) but not define it here.

--------------------------------------------------------------------------------
-- GLOBAL TABLES
--------------------------------------------------------------------------------
local players_table_global     = LE.db:GetTable("players")
local team_player_links_global = LE.db:GetTable("teamplayerlinks")
local formations_table_global  = LE.db:GetTable("formations")
local league_team_links_global = LE.db:GetTable("leagueteamlinks")

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------
local config = {
    target_leagues = { 61, 60 }, -- E.g. League Two, League One, etc.
    excluded_teams = {[111592] = true},         -- e.g. { [1234] = true }

    -- Step 2: The user-defined alternatives
    alternative_positions = {
        RW = {"RM"},
        LW = {"LM"},
        ST = {"RW","LW"},
        CDM= {"CM"},
        CAM= {"RW","LW"}
    },

    -- Step 2: The user-defined roles
    positions_to_roles = {
        GK={1,2,0},  CB={11,12,13}, RB={3,4,5},  LB={7,8,9},
        CDM={14,15,16}, RM={23,24,26}, CM={18,19,20}, LM={27,28,30},
        CAM={31,32,33}, ST={41,42,43}, RW={35,36,37}, LW={38,39,40}
    },

    max_per_position = 3 -- Step 4: Only allow up to 3 players per position
}

--------------------------------------------------------------------------------
-- POSITION ID MAPPING
--------------------------------------------------------------------------------
local position_ids = {
    GK={0}, CB={5,1,4,6}, RB={3,2}, LB={7,8}, CDM={10,9,11},
    RM={12}, CM={14,13,15}, LM={16}, CAM={18,17,19},
    ST={25,20,21,22,24,26}, RW={23}, LW={27}
}

-- Build a position_id -> name map
local position_name_by_id = {}
for name, ids in pairs(position_ids) do
    for _, pid in ipairs(ids) do
        position_name_by_id[pid] = name
    end
end

-- Convert position name -> (first) ID
local function get_position_id_from_position_name(pos_name)
    return (position_ids[pos_name] or {})[1]
end

-- Convert position ID -> name
local function get_position_name_from_position_id(pid)
    return position_name_by_id[pid] or ("UnknownPos(".. tostring(pid) ..")")
end

--------------------------------------------------------------------------------
-- METHODS YOU PROVIDED
--------------------------------------------------------------------------------
local function update_player_preferred_position_1(player_id, new_pos_id, players_table)
    local rec = players_table:GetFirstRecord()
    while rec>0 do
        local current_pid = players_table:GetRecordFieldValue(rec,"playerid")
        if current_pid==player_id then
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

local function update_all_player_roles(player_id, r1, r2, r3, players_table)
    local rec = players_table:GetFirstRecord()
    while rec>0 do
        local current_pid = players_table:GetRecordFieldValue(rec,"playerid")
        if current_pid==player_id then
            local pos = players_table:GetRecordFieldValue(rec,"preferredposition1")
            if pos==0 then
                r3=0
            end
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

--------------------------------------------------------------------------------
-- GET FORMATION POSITIONS (STEP 2)
--------------------------------------------------------------------------------
local function get_formation_positions(team_id)
    if not formations_table_global then
        return {}
    end
    local rec = formations_table_global:GetFirstRecord()
    while rec>0 do
        local f_team_id = formations_table_global:GetRecordFieldValue(rec,"teamid")
        if f_team_id==team_id then
            local positions={}
            for i=0,10 do
                local field_name = ("position%d"):format(i)
                local pos_id = formations_table_global:GetRecordFieldValue(rec, field_name) or 0
                local pos_name = get_position_name_from_position_id(pos_id)
                positions[#positions+1] = pos_name
            end
            return positions
        end
        rec= formations_table_global:GetNextValidRecord()
    end
    return {}
end

--------------------------------------------------------------------------------
-- GET A TEAM'S PLAYERS (ID, positionName, overall)
--------------------------------------------------------------------------------
local function get_team_players(team_id)
    local players = {}
    local link_rec = team_player_links_global:GetFirstRecord()
    while link_rec>0 do
        local t_id = team_player_links_global:GetRecordFieldValue(link_rec,"teamid")
        local p_id = team_player_links_global:GetRecordFieldValue(link_rec,"playerid")
        if t_id==team_id then
            -- Look up in players_table
            local p_scan = players_table_global:GetFirstRecord()
            while p_scan>0 do
                local pid = players_table_global:GetRecordFieldValue(p_scan,"playerid")
                if pid==p_id then
                    local pref_pos = players_table_global:GetRecordFieldValue(p_scan,"preferredposition1") or 0
                    local pos_name = get_position_name_from_position_id(pref_pos)
                    local overall  = players_table_global:GetRecordFieldValue(p_scan,"overallrating")
                                   or players_table_global:GetRecordFieldValue(p_scan,"overall")
                                   or 0
                    players[#players+1] = {
                        id       = p_id,
                        posName  = pos_name,
                        overall  = overall
                    }
                    break
                end
                p_scan= players_table_global:GetNextValidRecord()
            end
        end
        link_rec= team_player_links_global:GetNextValidRecord()
    end
    return players
end

--------------------------------------------------------------------------------
-- TRY TO CONVERT A PLAYER (STEP 2)
--------------------------------------------------------------------------------
-- Returns true if conversion done, false if no suitable alt
local function try_convert_player(player_id, old_posName, formation_set)
    local alt_list = config.alternative_positions[old_posName]
    if not alt_list then
        return false
    end
    for _, alt_pos in ipairs(alt_list) do
        if formation_set[alt_pos] then
            -- Convert to alt_pos
            local new_pos_id = get_position_id_from_position_name(alt_pos)
            update_player_preferred_position_1(player_id, new_pos_id, players_table_global)

            local roles = config.positions_to_roles[alt_pos]
            if roles then
                update_all_player_roles(player_id, roles[1], roles[2], roles[3], players_table_global)
            end
            local player_name = GetPlayerName(player_id)
            LOGGER:LogInfo(string.format("Converted player %s (ID: %d) from %s to %s", player_name, player_id, old_posName, alt_pos))
            return true
        end
    end
    return false
end

--------------------------------------------------------------------------------
-- RELEASE A PLAYER (STEP 3)
-- The actual function 'ReleasePlayerFromTeam(playerid)' is global & not defined here
--------------------------------------------------------------------------------
local function release_player(player_id, team_id)
    ReleasePlayerFromTeam(player_id)
    local player_name = GetPlayerName(player_id)
    local team_name = GetTeamName(team_id)
    LOGGER:LogInfo(string.format("Released player %s (ID: %d) from %s (ID: %d).", player_name, player_id, team_name, team_id))
end

--------------------------------------------------------------------------------
-- PROCESS ONE TEAM
--------------------------------------------------------------------------------
local function process_team(team_id)
    local team_name = GetTeamName(team_id)
    LOGGER:LogInfo(string.format("Processing team %s (%d)...", team_name, team_id))

    -- Step 2: get formation, convert players if needed
    local formation_positions = get_formation_positions(team_id)
    if #formation_positions==0 then
        LOGGER:LogInfo(string.format("No formation found for %s. Skipping steps.", team_name))
        return
    end

    -- Turn the formation positions into a set
    local formation_set = {}
    for _,posName in ipairs(formation_positions) do
        formation_set[posName] = true
    end

    -- 1) Convert
    local players_list = get_team_players(team_id)
    for _, ply in ipairs(players_list) do
        if not formation_set[ply.posName] then
            -- Attempt conversion
            local success = try_convert_player(ply.id, ply.posName, formation_set)
            -- If not success, we do final release in next step
        end
    end

    -- 2) Release any leftover mismatches
    players_list = get_team_players(team_id) -- re-grab (in case they changed pos)
    for _, ply in ipairs(players_list) do
        if not formation_set[ply.posName] then
            
            release_player(ply.id, team_id)
        end
    end

    -- 3) Limit each position to config.max_per_position (e.g. 3)
    players_list = get_team_players(team_id) -- re-grab after releases
    local grouped = {}
    for _, ply in ipairs(players_list) do
        grouped[ply.posName] = grouped[ply.posName] or {}
        table.insert(grouped[ply.posName], ply)
    end

    for posName, arr in pairs(grouped) do
        if #arr> config.max_per_position then
            -- Sort ascending by overall
            table.sort(arr, function(a,b) return a.overall < b.overall end)
            local excess = #arr - config.max_per_position
            for i=1,excess do
                release_player(arr[i].id, team_id)
            end
        end
    end

    LOGGER:LogInfo(string.format("Done processing team %s (%d).", team_name, team_id))
end

--------------------------------------------------------------------------------
-- STEP 1: Build Team Pool (Collect Teams in target_leagues)
--------------------------------------------------------------------------------
local function build_team_pool()
    local pool = {}
    if not league_team_links_global then
        LOGGER:LogWarning("No league_team_links table found. Pool will be empty.")
        return pool
    end

    local league_map = {}
    local rec = league_team_links_global:GetFirstRecord()
    while rec>0 do
        local league_id = league_team_links_global:GetRecordFieldValue(rec,"leagueid")
        local t_id      = league_team_links_global:GetRecordFieldValue(rec,"teamid")
        if league_id and t_id and not config.excluded_teams[t_id] then
            league_map[league_id] = league_map[league_id] or {}
            league_map[league_id][#league_map[league_id]+1] = t_id
        end
        rec= league_team_links_global:GetNextValidRecord()
    end

    for _, wanted_league_id in ipairs(config.target_leagues) do
        local teams_in_league = league_map[wanted_league_id] or {}
        for _, t_id in ipairs(teams_in_league) do
            pool[#pool+1] = t_id
        end
    end

    return pool
end

--------------------------------------------------------------------------------
-- MAIN
--------------------------------------------------------------------------------
local function do_position_changes()
    local team_pool = build_team_pool()
    if #team_pool==0 then
        LOGGER:LogInfo("No teams found in target leagues. Exiting.")
        return
    end
    LOGGER:LogInfo(string.format(
        "Collected %d teams from leagues: %s",
        #team_pool, table.concat(config.target_leagues,", ")
    ))

    for _, team_id in ipairs(team_pool) do
        process_team(team_id)
    end
    LOGGER:LogInfo("Done processing all target teams.")
end

--------------------------------------------------------------------------------
-- RUN SCRIPT
--------------------------------------------------------------------------------
math.randomseed(os.time())
LOGGER:LogInfo("Starting Team Formation Position Management Script...")

do_position_changes()
