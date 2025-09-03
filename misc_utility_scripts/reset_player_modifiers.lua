--------------------------------------------------------------------------------
-- Player Modifier Reset for FC 25 Live Editor - Made By The Mayo Man (themayonnaiseman)
-- Resets the "modifier" field to 0 for all players in the database
--------------------------------------------------------------------------------
require 'imports/career_mode/helpers'
require 'imports/other/helpers'

local players_table_global = LE.db:GetTable("players")

--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------
local config = {
    new_modifier_value = 0, -- Value to set for all players' modifier field
}

--------------------------------------------------------------------------------
-- MAIN FUNCTION
--------------------------------------------------------------------------------
local function reset_player_modifiers()
    if not players_table_global then
        LOGGER:LogError("Players table not found. Aborting.")
        MessageBox("Error", "Players table not accessible.")
        return
    end

    local players_updated = 0
    local players_already_zero = 0
    
    LOGGER:LogInfo(string.format("Starting modifier reset: Setting all player modifiers to %d", config.new_modifier_value))

    -- Loop through all players in the database
    local record = players_table_global:GetFirstRecord()
    while record > 0 do
        local player_id = players_table_global:GetRecordFieldValue(record, "playerid")
        
        if player_id then
            local current_modifier = players_table_global:GetRecordFieldValue(record, "modifier") or 0
            
            if current_modifier ~= config.new_modifier_value then
                -- Update the modifier field
                players_table_global:SetRecordFieldValue(record, "modifier", config.new_modifier_value)
                players_updated = players_updated + 1
                
                -- Log every 1000 updates to show progress
                if players_updated % 1000 == 0 then
                    LOGGER:LogInfo(string.format("Progress: %d players updated...", players_updated))
                end
            else
                players_already_zero = players_already_zero + 1
            end
        end
        
        record = players_table_global:GetNextValidRecord()
    end

    -- Summary
    local total_players = players_updated + players_already_zero
    local message = string.format(
        "Player modifier reset complete!\n\nTotal players processed: %d\nPlayers updated: %d\nPlayers already at target value: %d", 
        total_players, players_updated, players_already_zero
    )
    
    LOGGER:LogInfo(string.format("Reset complete: %d total players, %d updated, %d already correct", 
        total_players, players_updated, players_already_zero))
    MessageBox("Reset Complete", message)
end

--------------------------------------------------------------------------------
-- SCRIPT EXECUTION
--------------------------------------------------------------------------------
LOGGER:LogInfo("Starting Player Modifier Reset Script...")
reset_player_modifiers() 