--------------------------------------------------------------------------------
-- Lua Script for changing player roles
--------------------------------------------------------------------------------

require 'imports/career_mode/helpers'
require 'imports/other/helpers'

local players_table_global   = LE.db:GetTable("players")

-- Change the following values to the desired player ID and role IDs
local player_id_to_change = 73330
local role_id_new_1 = 38 -- eg: 38 lw winger+
local role_id_new_2 = 39 -- eg: 39 lw inside forward+
local role_id_new_3 = 40 -- eg: 40 lw wide playmaker+

local function update_all_player_roles(player_id, new_role_id_1, new_role_id_2, new_role_id_3)
    local players_table_record = players_table_global:GetFirstRecord()
    while players_table_record > 0 do
        local current_player_id = players_table_global:GetRecordFieldValue(players_table_record, "playerid")
        if current_player_id == player_id then
            local current_players_pos = players_table_global:GetRecordFieldValue(players_table_record, "preferredposition1")
            -- if a gk set 3rd role as nothing
            if current_players_pos == 0 then
                new_role_id_3 = 0
            end

            players_table_global:SetRecordFieldValue(players_table_record, "role1", new_role_id_1)
            players_table_global:SetRecordFieldValue(players_table_record, "role2", new_role_id_2)
            players_table_global:SetRecordFieldValue(players_table_record, "role3", new_role_id_3)
            LOGGER:LogInfo(string.format("Updated player %d's roles to %d,%d and %d.", player_id, new_role_id_1, new_role_id_2, new_role_id_3))
            return
        end
        players_table_record = players_table_global:GetNextValidRecord()
    end
    LOGGER:LogWarning(string.format("Player record for ID %d not found. Could not update preferred position.", player_id))
end

update_all_player_roles(player_id_to_change, role_id_new_1, role_id_new_2, role_id_new_3)