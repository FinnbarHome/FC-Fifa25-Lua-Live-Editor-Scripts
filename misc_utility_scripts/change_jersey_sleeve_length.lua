--------------------------------------------------------------------------------
-- Jersey Sleeve Length & Seasonal Jersey Changer for FC 25 Live Editor - Made By The Mayo Man (themayonnaiseman)
-- Used for "players effected by the rainbow arms bug when using Artisans boots with Fifers mods"
-- Changes jerseysleevelengthcode and hasseasonaljersey for specified players
-- Can target specific players or search for players with certain codes
--------------------------------------------------------------------------------
require 'imports/career_mode/helpers'
require 'imports/other/helpers'

local players_table_global = LE.db:GetTable("players")

--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------
local config = {
    -- MODE SELECTION: Choose between specific player list or search mode
    use_search_mode = true, -- true: search for players with specific sleeve codes, false: use target_players list
    
    -- PLAYER LIST MODE: Specific players to update (only used when use_search_mode = false)
    target_players = {
        192119, -- Courtois
        235073, -- Kobel
        199641, -- Sels
        215223, -- Benitez
        212831, -- Alisson
        238186, -- Bulka
        230670, -- Perri
        193698, -- Baumann
        225116, -- Meret
        210385, -- Silva
        73562,  -- Bento
        205186, -- Gazzaniga
        243952, -- Lunin
        238919, -- Pantemis
        258351  -- Boehmer
    },
    
    -- SEARCH MODE: Find players with these codes (only used when use_search_mode = true)
    search_sleeve_codes = {5, 6, 7}, -- Search for players with these sleeve codes
    search_seasonal_codes = {5, 6, 7}, -- Search for players with these seasonal jersey codes
    
    -- NEW CODES: List of possible new codes (random selection if multiple values)
    new_sleeve_length_codes = {0}, -- 0 = Short sleeves, 1 = Long sleeves, 2 = Long sleeves with turtleneck, 3 = Seasonal undershirt, 4 = Seasonal undershirt with turtleneck, 5 = jerseysleevelengthcode_5, 6 = jerseysleevelengthcode_6, 7 = jerseysleevelengthcode_7
    new_seasonal_jersey_codes = {3,4}, -- 0 = Short, 1 = Long, 2 = Long and Turtleneck, 3 = Seasonal Undershirt, 4 = Seasonal Undershirt and Turtleneck, 5 = hasseasonaljersey_5, 6 = hasseasonaljersey_6, 7 = hasseasonaljersey_7
}

--------------------------------------------------------------------------------
-- HELPER FUNCTIONS
--------------------------------------------------------------------------------

-- Get a random sleeve code from the configured list
local function get_random_sleeve_code()
    if #config.new_sleeve_length_codes == 1 then
        return config.new_sleeve_length_codes[1]
    else
        local random_index = math.random(1, #config.new_sleeve_length_codes)
        return config.new_sleeve_length_codes[random_index]
    end
end

-- Get a random seasonal jersey code from the configured list
local function get_random_seasonal_code()
    if #config.new_seasonal_jersey_codes == 1 then
        return config.new_seasonal_jersey_codes[1]
    else
        local random_index = math.random(1, #config.new_seasonal_jersey_codes)
        return config.new_seasonal_jersey_codes[random_index]
    end
end

-- Check if a sleeve code is in the search list
local function is_target_sleeve_code(sleeve_code)
    for _, target_code in ipairs(config.search_sleeve_codes) do
        if sleeve_code == target_code then
            return true
        end
    end
    return false
end

-- Check if a seasonal jersey code is in the search list
local function is_target_seasonal_code(seasonal_code)
    for _, target_code in ipairs(config.search_seasonal_codes) do
        if seasonal_code == target_code then
            return true
        end
    end
    return false
end

-- Get sleeve code name for display
local function get_sleeve_code_name(code)
    local names = {
        [0] = "Short sleeves",
        [1] = "Long sleeves", 
        [2] = "Long sleeves with turtleneck",
        [3] = "Seasonal undershirt",
        [4] = "Seasonal undershirt with turtleneck",
        [5] = "jerseysleevelengthcode_5",
        [6] = "jerseysleevelengthcode_6",
        [7] = "jerseysleevelengthcode_7"
    }
    return names[code] or string.format("Unknown sleeve code %d", code)
end

-- Get seasonal jersey code name for display
local function get_seasonal_code_name(code)
    local names = {
        [0] = "Short",
        [1] = "Long",
        [2] = "Long and Turtleneck", 
        [3] = "Seasonal Undershirt",
        [4] = "Seasonal Undershirt and Turtleneck",
        [5] = "hasseasonaljersey_5",
        [6] = "hasseasonaljersey_6",
        [7] = "hasseasonaljersey_7"
    }
    return names[code] or string.format("Unknown seasonal code %d", code)
end

--------------------------------------------------------------------------------
-- MAIN FUNCTION
--------------------------------------------------------------------------------
local function change_jersey_sleeve_lengths()
    if not players_table_global then
        LOGGER:LogError("Players table not found. Aborting.")
        MessageBox("Error", "Players table not accessible.")
        return
    end

    -- Initialize random seed
    math.randomseed(os.time())

    local players_updated = 0
    local players_not_found = 0
    local target_player_set = {}
    
    -- Setup based on mode
    if config.use_search_mode then
        LOGGER:LogInfo(string.format("SEARCH MODE: Looking for players with sleeve codes: %s and seasonal codes: %s", 
            table.concat(config.search_sleeve_codes, ", "), table.concat(config.search_seasonal_codes, ", ")))
    else
        -- Convert list to set for faster lookups
        for _, player_id in ipairs(config.target_players) do
            target_player_set[player_id] = true
        end
        LOGGER:LogInfo(string.format("LIST MODE: Processing %d specific players", #config.target_players))
    end
    
    -- Log sleeve code assignment strategy
    if #config.new_sleeve_length_codes == 1 then
        LOGGER:LogInfo(string.format("Sleeve codes: Will set all to %d (%s)", 
            config.new_sleeve_length_codes[1], get_sleeve_code_name(config.new_sleeve_length_codes[1])))
    else
        LOGGER:LogInfo(string.format("Sleeve codes: Will randomly assign from: %s", table.concat(config.new_sleeve_length_codes, ", ")))
    end
    
    -- Log seasonal jersey assignment strategy
    if #config.new_seasonal_jersey_codes == 1 then
        LOGGER:LogInfo(string.format("Seasonal jerseys: Will set all to %d (%s)", 
            config.new_seasonal_jersey_codes[1], get_seasonal_code_name(config.new_seasonal_jersey_codes[1])))
    else
        LOGGER:LogInfo(string.format("Seasonal jerseys: Will randomly assign from: %s", table.concat(config.new_seasonal_jersey_codes, ", ")))
    end

    -- Loop through all players in the database
    local record = players_table_global:GetFirstRecord()
    while record > 0 do
        local player_id = players_table_global:GetRecordFieldValue(record, "playerid")
        local should_update = false
        
        if player_id then
            local update_sleeve = false
            local update_seasonal = false
            
            if config.use_search_mode then
                -- Search mode: check which fields match target codes
                local current_sleeve_code = players_table_global:GetRecordFieldValue(record, "jerseysleevelengthcode") or -1
                local current_seasonal_code = players_table_global:GetRecordFieldValue(record, "hasseasonaljersey") or -1
                
                update_sleeve = is_target_sleeve_code(current_sleeve_code)
                update_seasonal = is_target_seasonal_code(current_seasonal_code)
                should_update = update_sleeve or update_seasonal
            else
                -- List mode: update both fields for target players
                should_update = target_player_set[player_id] ~= nil
                update_sleeve = should_update
                update_seasonal = should_update
            end
            
            if should_update then
                local player_name = GetPlayerName(player_id)
                local current_sleeve_code = players_table_global:GetRecordFieldValue(record, "jerseysleevelengthcode") or -1
                local current_seasonal_code = players_table_global:GetRecordFieldValue(record, "hasseasonaljersey") or -1
                
                LOGGER:LogInfo(string.format("Updated %s (ID: %d):", player_name, player_id))
                
                -- Update sleeve code if it matched
                if update_sleeve then
                    local new_sleeve_code = get_random_sleeve_code()
                    players_table_global:SetRecordFieldValue(record, "jerseysleevelengthcode", new_sleeve_code)
                    LOGGER:LogInfo(string.format("  Sleeve: %d (%s) -> %d (%s)", 
                        current_sleeve_code, get_sleeve_code_name(current_sleeve_code),
                        new_sleeve_code, get_sleeve_code_name(new_sleeve_code)))
                end
                
                -- Update seasonal code if it matched
                if update_seasonal then
                    local new_seasonal_code = get_random_seasonal_code()
                    players_table_global:SetRecordFieldValue(record, "hasseasonaljersey", new_seasonal_code)
                    LOGGER:LogInfo(string.format("  Seasonal: %d (%s) -> %d (%s)", 
                        current_seasonal_code, get_seasonal_code_name(current_seasonal_code),
                        new_seasonal_code, get_seasonal_code_name(new_seasonal_code)))
                end
                
                -- Log what wasn't changed (for clarity)
                if not update_sleeve then
                    LOGGER:LogInfo(string.format("  Sleeve: %d (%s) [no change - didn't match search]", 
                        current_sleeve_code, get_sleeve_code_name(current_sleeve_code)))
                end
                if not update_seasonal then
                    LOGGER:LogInfo(string.format("  Seasonal: %d (%s) [no change - didn't match search]", 
                        current_seasonal_code, get_seasonal_code_name(current_seasonal_code)))
                end
                
                players_updated = players_updated + 1
                
                -- Mark as found for list mode
                if not config.use_search_mode then
                    target_player_set[player_id] = nil
                end
            end
        end
        
        record = players_table_global:GetNextValidRecord()
    end

    -- Check for players that weren't found (only in list mode)
    if not config.use_search_mode then
        for player_id, _ in pairs(target_player_set) do
            LOGGER:LogInfo(string.format("WARNING: Player ID %d not found in database", player_id))
            players_not_found = players_not_found + 1
        end
    end

    -- Summary
    local mode_text = config.use_search_mode and "SEARCH" or "LIST"
    local target_codes_text = config.use_search_mode and 
        string.format("(sleeve: %s, seasonal: %s)", table.concat(config.search_sleeve_codes, ", "), table.concat(config.search_seasonal_codes, ", ")) or
        string.format("(target players: %d)", #config.target_players)
    
    local message = string.format(
        "Jersey sleeve & seasonal update complete!\n\nMode: %s %s\nPlayers updated: %d\nPlayers not found: %d", 
        mode_text, target_codes_text, players_updated, players_not_found
    )
    
    LOGGER:LogInfo(string.format("Update complete: %d updated, %d not found", players_updated, players_not_found))
    MessageBox("Update Complete", message)
end

--------------------------------------------------------------------------------
-- SCRIPT EXECUTION
--------------------------------------------------------------------------------
LOGGER:LogInfo("Starting Jersey Sleeve Length Changer Script...")
change_jersey_sleeve_lengths() 