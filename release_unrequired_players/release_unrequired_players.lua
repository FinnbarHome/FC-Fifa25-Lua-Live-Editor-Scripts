--------------------------------------------------------------------------------
-- Team Formation Position Management Script with Position-Count-Based Max
--------------------------------------------------------------------------------
require 'imports/career_mode/helpers'
require 'imports/other/helpers'

-- We assume ReleasePlayerFromTeam(player_id) is globally defined elsewhere.

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
    target_leagues = {61,60,14}, -- Eg: 61 = EFL League Two, 60 = EFL League One, 14 = EFL Championship
    excluded_teams = {},         -- e.g. { [1234] = true }

    alternative_positions = {
        RW = {"RM"},
        LW = {"LM"},
        ST = {"RW","LW"},
        CDM= {"CM"},
        CAM= {"RW","LW"}
    },

    positions_to_roles = {
        GK={1,2,0},  CB={11,12,13}, RB={3,4,5},  LB={7,8,9},
        CDM={14,15,16}, RM={23,24,26}, CM={18,19,20}, LM={27,28,30},
        CAM={31,32,33}, ST={41,42,43}, RW={35,36,37}, LW={38,39,40}
    },

    -- Instead of a single max, we multiply each formation position's count by this multiplier
    -- e.g. if formation uses ST 2 times, then max ST = 2 * multiplier
    multiplier = 3
}

--------------------------------------------------------------------------------
-- POSITION MAPPINGS
--------------------------------------------------------------------------------
local position_ids = {
    GK={0}, CB={5,1,4,6}, RB={3,2}, LB={7,8}, CDM={10,9,11},
    RM={12}, CM={14,13,15}, LM={16}, CAM={18,17,19},
    ST={25,20,21,22,24,26}, RW={23}, LW={27}
}

local position_name_by_id = {}
for name, ids in pairs(position_ids) do
    for _, pid in ipairs(ids) do
        position_name_by_id[pid] = name
    end
end

local function get_position_id_from_position_name(pos_name)
    return (position_ids[pos_name] or {})[1]
end

local function get_position_name_from_position_id(pid)
    return position_name_by_id[pid] or ("UnknownPos(".. tostring(pid) ..")")
end

--------------------------------------------------------------------------------
-- METHODS YOU PROVIDED: Update Position + Roles
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
-- GET FORMATION POSITIONS
--------------------------------------------------------------------------------
-- Returns a table of e.g. {"GK","CB","CB","ST","CM",...}
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
-- GET TEAM PLAYERS
--------------------------------------------------------------------------------
-- Returns a list of {id, posName, overall}
local function get_team_players(team_id)
    local players = {}
    local link_rec = team_player_links_global:GetFirstRecord()
    while link_rec>0 do
        local t_id = team_player_links_global:GetRecordFieldValue(link_rec,"teamid")
        local p_id = team_player_links_global:GetRecordFieldValue(link_rec,"playerid")
        if t_id==team_id then
            -- loop players table to find that player_id
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
                        id       = pid,
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
-- ATTEMPT CONVERSION (Step 2)
--------------------------------------------------------------------------------
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
            LOGGER:LogInfo(string.format("Converted player %d from %s to %s", player_id, old_posName, alt_pos))
            return true
        end
    end
    return false
end

--------------------------------------------------------------------------------
-- RELEASE A PLAYER (Step 3)
-- The global ReleasePlayerFromTeam(player_id) is assumed
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

    -- 1) Grab formation positions
    local formation_positions = get_formation_positions(team_id)
    if #formation_positions==0 then
        LOGGER:LogInfo(string.format("No formation found for team %s. Skipping steps.", team_name))
        return
    end

    -- Build a set for quick membership checks, plus a count
    local formation_set = {}
    local formation_count = {}  -- e.g. {ST=2, GK=1, CB=2, ...}
    for _,posName in ipairs(formation_positions) do
        formation_set[posName] = true
        formation_count[posName] = (formation_count[posName] or 0) + 1
    end

    -- 2) Convert any player not in the formation
    local players_list = get_team_players(team_id)
    for _, ply in ipairs(players_list) do
        if not formation_set[ply.posName] then
            -- Attempt conversion
            local success = try_convert_player(ply.id, ply.posName, formation_set)
            -- If not success, will do final check in next step
        end
    end

    -- 3) Release leftover mismatches
    players_list = get_team_players(team_id) -- re-grab
    for _, ply in ipairs(players_list) do
        if not formation_set[ply.posName] then
            release_player(ply.id, team_id)
        end
    end

    -- 4) Limit each position to "formation_count * config.multiplier"
    players_list = get_team_players(team_id)
    local grouped = {}
    for _, ply in ipairs(players_list) do
        grouped[ply.posName] = grouped[ply.posName] or {}
        table.insert(grouped[ply.posName], ply)
    end

    for posName, arr in pairs(grouped) do
        local demand_for_pos = formation_count[posName] or 0
        if demand_for_pos>0 then
            local max_for_pos = demand_for_pos * config.multiplier
            if #arr> max_for_pos then
                -- Sort ascending by overall rating
                table.sort(arr, function(a,b) return a.overall < b.overall end)
                local excess = #arr - max_for_pos
                for i=1,excess do
                    release_player(arr[i].id, team_id)
                end
                LOGGER:LogInfo(string.format(
                    "Position %s had %d players, demanded %d in formation => max %d, released %d lowest overalls.",
                    posName, #arr, demand_for_pos, max_for_pos, excess
                ))
            end
        else
            -- If somehow there's a position we never asked for in formation, decide how to handle:
            -- Possibly release all? The earlier step should have handled it, though.
        end
    end

    LOGGER:LogInfo(string.format("Done processing team %s (%d).", team_name, team_id))
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
