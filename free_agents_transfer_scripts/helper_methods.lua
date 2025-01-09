--------------------------------------------------------------------------------
--- Helper methods for free agents transfer script
--------------------------------------------------------------------------------
require 'imports/career_mode/helpers'
require 'imports/other/helpers'

--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------
local position_ids = {
    GK={0}, CB={5,1,4,6}, RB={3,2}, LB={7,8}, CDM={10,9,11},
    RM={12}, CM={14,13,15}, LM={16}, CAM={18,17,19},
    ST={25,20,21,22,24,26}, RW={23}, LW={27}
}

local lower_bound_minus, upper_bound_plus = 2, 2

--------------------------------------------------------------------------------
--- HELPER METHODS
--------------------------------------------------------------------------------
local position_name_by_id = {}
for name, ids in pairs(position_ids) do
    for _, pid in ipairs(ids) do
        position_name_by_id[pid] = name
    end
end

local function get_position_id_from_position_name(req)
    return (position_ids[req] or {})[1]
end

local function get_position_name_from_position_id(pid)
    return position_name_by_id[pid] or ("UnknownPos(".. pid ..")")
end

local function build_player_data(players_table)
    if not players_table then
        LOGGER:LogWarning("Players table not found. Could not build player data.")
        return {}
    end
    local player_data = {}
    local rec = players_table:GetFirstRecord()
    while rec > 0 do
        local pid = players_table:GetRecordFieldValue(rec, "playerid")
        if pid then
            local rating = players_table:GetRecordFieldValue(rec, "overallrating")
                          or players_table:GetRecordFieldValue(rec, "overall") or 0
            local potential = players_table:GetRecordFieldValue(rec, "potential") or 0
            local birthdate = players_table:GetRecordFieldValue(rec, "birthdate")
            local pref_pos  = players_table:GetRecordFieldValue(rec, "preferredposition1")
            player_data[pid] = {
                overall = rating,
                potential = potential,
                birthdate = birthdate,
                preferredposition1 = pref_pos,
                positionName = pref_pos and get_position_name_from_position_id(pref_pos) or nil
            }
        end
        rec = players_table:GetNextValidRecord()
    end
    return player_data
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

local function get_team_size(team_id, team_player_links)
    if not team_player_links then return 0 end
    local count, rec = 0, team_player_links:GetFirstRecord()
    while rec>0 do
        if team_player_links:GetRecordFieldValue(rec,"teamid")==team_id then
            count = count+1
        end
        rec=team_player_links:GetNextValidRecord()
    end
    return count
end

local function update_all_player_roles(player_id, r1, r2, r3, players_table)
    local rec = players_table:GetFirstRecord()
    while rec>0 do
        if players_table:GetRecordFieldValue(rec,"playerid")==player_id then
            local pos = players_table:GetRecordFieldValue(rec,"preferredposition1")
            if pos==0 then r3=0 end
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

local function update_player_preferred_position_1(player_id, new_pos_id, players_table)
    local rec = players_table:GetFirstRecord()
    while rec>0 do
        if players_table:GetRecordFieldValue(rec,"playerid")==player_id then
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

local function count_positions_in_team(team_id, team_player_links, player_data)
    local counts, rec = {}, team_player_links:GetFirstRecord()
    while rec>0 do
        if team_player_links:GetRecordFieldValue(rec,"teamid")==team_id then
            local p_id = team_player_links:GetRecordFieldValue(rec,"playerid")
            local pdata= player_data[p_id]
            if pdata and pdata.preferredposition1 then
                local name = get_position_name_from_position_id(pdata.preferredposition1)
                counts[name] = (counts[name] or 0)+1
            end
        end
        rec=team_player_links:GetNextValidRecord()
    end
    return counts
end

local function get_team_lower_upper_bounds(team_id, team_player_links, player_data)
    local ratings, rec = {}, team_player_links:GetFirstRecord()
    while rec>0 do
        local t_id= team_player_links:GetRecordFieldValue(rec,"teamid")
        if t_id==team_id then
            local p_id= team_player_links:GetRecordFieldValue(rec,"playerid")
            local pdata= player_data[p_id]
            if pdata then ratings[#ratings+1]= pdata.overall end
        end
        rec=team_player_links:GetNextValidRecord()
    end
    if #ratings==0 then
        LOGGER:LogWarning(string.format("No ratings found for team %d.", team_id))
        return nil,nil
    end

    table.sort(ratings)
    local n=#ratings
    local i50, i75= math.ceil(0.5*n), math.ceil(0.75*n)
    local p50, p75= math.floor(ratings[i50]+0.5), math.floor(ratings[i75]+0.5)
    local lb, ub= p50 - lower_bound_minus, p75 + upper_bound_plus

    local team_name= GetTeamName(team_id)
    LOGGER:LogInfo(string.format("Team %s(ID %d): 50%%=%d->LB:%d, 75%%=%d->UB:%d", 
        team_name,team_id,p50,lb,p75,ub))
    return lb, ub
end

return {
    build_player_data = build_player_data, 
    calculate_player_age = calculate_player_age,
    get_team_size = get_team_size,
    update_all_player_roles = update_all_player_roles,
    update_player_preferred_position_1 = update_player_preferred_position_1,
    count_positions_in_team = count_positions_in_team,
    get_position_id_from_position_name = get_position_id_from_position_name,
    get_position_name_from_position_id = get_position_name_from_position_id,
    get_team_lower_upper_bounds = get_team_lower_upper_bounds
}
