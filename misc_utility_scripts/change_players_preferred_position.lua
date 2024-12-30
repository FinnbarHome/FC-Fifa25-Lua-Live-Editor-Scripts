--------------------------------------------------------------------------------
-- Lua Script for changing player's preferred positions
--------------------------------------------------------------------------------

require 'imports/career_mode/helpers'
require 'imports/other/helpers'

local players_table_global   = LE.db:GetTable("players")

-- Change the following values to the desired player ID and position ids, make sure to enable which method you want to use below
local player_id_to_change = 73330
local role_id_new_1 = 23 -- eg: 23 lw
local role_id_new_2 = 25 -- eg: 25 st
local role_id_new_3 = 27 -- eg: 27 rw

local function update_player_preferred_position_1(player_id, new_role_id_1)
    local players_table_record = players_table_global:GetFirstRecord()
    
    while players_table_record > 0 do
        local current_player_id = players_table_global:GetRecordFieldValue(players_table_record, "playerid")
        if current_player_id == player_id then
            local old_role_id = players_table_global:GetRecordFieldValue(players_table_record, "preferredposition1")
            local player_preferred_position_2 = players_table_global:GetRecordFieldValue(players_table_record, "preferredposition2")
            local player_preferred_position_3 = players_table_global:GetRecordFieldValue(players_table_record, "preferredposition3")

            players_table_global:SetRecordFieldValue(players_table_record, "preferredposition1", new_role_id_1)
            LOGGER:LogInfo(string.format("Updated player %d's preferred position 1 to %d.", player_id, new_role_id_1))

            -- if a gk set 2nd and 3rd role as nothing and 1st as gk (0)
            if new_role_id_1 == 0 then
                LOGGER:LogInfo(string.format("Player %d is a gk setting preferred positon to gk with 2 and 3 as nothing", player_id))
                players_table_global:SetRecordFieldValue(players_table_record, "preferredposition1", 0)
                players_table_global:SetRecordFieldValue(players_table_record, "preferredposition2", -1)
                players_table_global:SetRecordFieldValue(players_table_record, "preferredposition3", -1)
                return
            end

            -- If the player's preferred position 2 or 3 is the new role, update it to the old role 
            if player_preferred_position_2 == new_role_id_1 then
                players_table_global:SetRecordFieldValue(players_table_record, "preferredposition2", old_role_id)
                LOGGER:LogInfo(string.format("Updated player %d's preferred position 2 to the old role (%d)", player_id, old_role_id))
            end
            if player_preferred_position_3 == new_role_id_1 then
                players_table_global:SetRecordFieldValue(players_table_record, "preferredposition3", old_role_id)
                LOGGER:LogInfo(string.format("Updated player %d's preferred position 3 to the old role (%d)", player_id, old_role_id))
            end

            return
        end
        players_table_record = players_table_global:GetNextValidRecord()
    end
    LOGGER:LogWarning(string.format("Player record for ID %d not found. Could not update preferred position.", player_id))
end

local function update_player_preferred_position_2(player_id, new_role_id_2)
    local players_table_record = players_table_global:GetFirstRecord()
    
    while players_table_record > 0 do
        local current_player_id = players_table_global:GetRecordFieldValue(players_table_record, "playerid")
        if current_player_id == player_id then
            local old_role_id = players_table_global:GetRecordFieldValue(players_table_record, "preferredposition2")
            local player_preferred_position_1 = players_table_global:GetRecordFieldValue(players_table_record, "preferredposition1")
            local player_preferred_position_3 = players_table_global:GetRecordFieldValue(players_table_record, "preferredposition3")

            -- if a gk set 2nd and 3rd role as nothing and 1st as gk (0)
            if player_preferred_position_1 == 0 then
                LOGGER:LogInfo(string.format("Player %d is a gk (0) setting preferred positon to gk with 2 and 3 as nothing (-1)", player_id))
                players_table_global:SetRecordFieldValue(players_table_record, "preferredposition1", 0)
                players_table_global:SetRecordFieldValue(players_table_record, "preferredposition2", -1)
                players_table_global:SetRecordFieldValue(players_table_record, "preferredposition3", -1)
                return
            end

            players_table_global:SetRecordFieldValue(players_table_record, "preferredposition2", new_role_id_2)
            LOGGER:LogInfo(string.format("Updated player %d's preferred position 2 to %d.", player_id, new_role_id_2))

            -- If the player's preferred position 1 or 3 is the new role, update it to the old role 
            if player_preferred_position_1 == new_role_id_2 then
                players_table_global:SetRecordFieldValue(players_table_record, "preferredposition1", old_role_id)
                LOGGER:LogInfo(string.format("Updated player %d's preferred position 1 to the old role (%d)", player_id, old_role_id))
            end
            if player_preferred_position_3 == new_role_id_2 then
                players_table_global:SetRecordFieldValue(players_table_record, "preferredposition3", old_role_id)
                LOGGER:LogInfo(string.format("Updated player %d's preferred position 3 to the old role (%d)", player_id, old_role_id))
            end

            return
        end
        players_table_record = players_table_global:GetNextValidRecord()
    end
    LOGGER:LogWarning(string.format("Player record for ID %d not found. Could not update preferred position.", player_id))
end

local function update_player_preferred_position_3(player_id, new_role_id_3)
    local players_table_record = players_table_global:GetFirstRecord()
    
    while players_table_record > 0 do
        local current_player_id = players_table_global:GetRecordFieldValue(players_table_record, "playerid")
        if current_player_id == player_id then
            local old_role_id = players_table_global:GetRecordFieldValue(players_table_record, "preferredposition3")
            local player_preferred_position_1 = players_table_global:GetRecordFieldValue(players_table_record, "preferredposition1")
            local player_preferred_position_2 = players_table_global:GetRecordFieldValue(players_table_record, "preferredposition2")

            -- if a gk set 2nd and 3rd role as nothing and 1st as gk (0)
            if player_preferred_position_1 == 0 then
                LOGGER:LogInfo(string.format("Player %d is a gk (0) setting preferred positon to gk with 2 and 3 as nothing (-1)", player_id))
                players_table_global:SetRecordFieldValue(players_table_record, "preferredposition1", 0)
                players_table_global:SetRecordFieldValue(players_table_record, "preferredposition2", -1)
                players_table_global:SetRecordFieldValue(players_table_record, "preferredposition3", -1)
                return
            end

            players_table_global:SetRecordFieldValue(players_table_record, "preferredposition3", new_role_id_3)
            LOGGER:LogInfo(string.format("Updated player %d's preferred position 3 to %d.", player_id, new_role_id_3))


            -- If the player's preferred position 1 or 2 is the new role, update it to the old role 
            if player_preferred_position_1 == new_role_id_3 then
                players_table_global:SetRecordFieldValue(players_table_record, "preferredposition1", old_role_id)
                LOGGER:LogInfo(string.format("Updated player %d's preferred position 1 to the old role (%d)", player_id, old_role_id))
            end
            if player_preferred_position_2 == new_role_id_3 then
                players_table_global:SetRecordFieldValue(players_table_record, "preferredposition2", old_role_id)
                LOGGER:LogInfo(string.format("Updated player %d's preferred position 2 to the old role (%d)", player_id, old_role_id))
            end

            return
        end
        players_table_record = players_table_global:GetNextValidRecord()
    end
    LOGGER:LogWarning(string.format("Player record for ID %d not found. Could not update preferred position.", player_id))
end


local function update_all_player_preferred_positions(player_id, new_role_id_1, new_role_id_2, new_role_id_3)
    local players_table_record = players_table_global:GetFirstRecord()
    while players_table_record > 0 do
        local current_player_id = players_table_global:GetRecordFieldValue(players_table_record, "playerid")
        if current_player_id == player_id then
            players_table_global:SetRecordFieldValue(players_table_record, "preferredposition1", new_role_id_1)
            LOGGER:LogInfo(string.format("Updated player %d's preferred position 1 to %d.", player_id, new_role_id_1))

            -- if a gk set 2nd and 3rd role as nothing
            if new_role_id_1 == 0 then
                new_role_id_2 = -1
                new_role_id_3 = -1
            end

            players_table_global:SetRecordFieldValue(players_table_record, "preferredposition2", new_role_id_2)
            LOGGER:LogInfo(string.format("Updated player %d's preferred position 2 to %d.", player_id, new_role_id_2))

            players_table_global:SetRecordFieldValue(players_table_record, "preferredposition3", new_role_id_3)
            LOGGER:LogInfo(string.format("Updated player %d's preferred position 3 to %d.", player_id, new_role_id_3))

            return
        end
        players_table_record = players_table_global:GetNextValidRecord()
    end
    LOGGER:LogWarning(string.format("Player record for ID %d not found. Could not update preferred position.", player_id))
end

-- Uncomment the method you want to use and comment out the ones you don't want to use
update_all_player_preferred_positions(player_id_to_change, role_id_new_1, role_id_new_2, role_id_new_3)
-- update_player_preferred_position_1(player_id_to_change, role_id_new_1)
-- update_player_preferred_position_2(player_id_to_change, role_id_new_2)
-- update_player_preferred_position_3(player_id_to_change, role_id_new_3)
