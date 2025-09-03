--------------------------------------------------------------------------------
-- Free Agent Analyzer Script for FC 25 Live Editor - Made By The Mayo Man (themayonnaiseman)
-- Analyzes free agents within age parameters and shows distribution by rating
--------------------------------------------------------------------------------
require 'imports/career_mode/helpers'
require 'imports/other/helpers'

local players_table_global = LE.db:GetTable("players")
local team_player_links_global = LE.db:GetTable("teamplayerlinks")

--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------
local config = {
    age_constraints = {min = 16, max = 32},
    transfer = {
        from_team_id = 111592  -- Source team for free agents
    }
}

--------------------------------------------------------------------------------
-- HELPER METHODS
--------------------------------------------------------------------------------
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

--------------------------------------------------------------------------------
-- ANALYZE FREE AGENTS
--------------------------------------------------------------------------------
local function analyze_free_agents()
    LOGGER:LogInfo("Starting Free Agent Analysis...")
    LOGGER:LogInfo(string.format("Age constraints: %d-%d years", config.age_constraints.min, config.age_constraints.max))
    LOGGER:LogInfo(string.format("Source team ID: %d", config.transfer.from_team_id))
    
    local eligible_players = {}
    local rating_distribution = {}
    local total_players_in_team = 0
    local players_within_age = 0
    
    -- Find all players in the source team
    local rec = team_player_links_global:GetFirstRecord()
    while rec > 0 do
        local t_id = team_player_links_global:GetRecordFieldValue(rec, "teamid")
        local p_id = team_player_links_global:GetRecordFieldValue(rec, "playerid")
        
        if t_id == config.transfer.from_team_id and p_id then
            total_players_in_team = total_players_in_team + 1
            
            -- Get player data
            local player_rec = players_table_global:GetFirstRecord()
            while player_rec > 0 do
                if players_table_global:GetRecordFieldValue(player_rec, "playerid") == p_id then
                    local rating = players_table_global:GetRecordFieldValue(player_rec, "overallrating") or 0
                    local birthdate = players_table_global:GetRecordFieldValue(player_rec, "birthdate")
                    local age = calculate_player_age(birthdate)
                    local player_name = GetPlayerName(p_id)
                    
                    -- Check if player meets age criteria
                    if age >= config.age_constraints.min and age <= config.age_constraints.max then
                        players_within_age = players_within_age + 1
                        
                        -- Add to eligible players list
                        table.insert(eligible_players, {
                            playerid = p_id,
                            name = player_name,
                            overall = rating,
                            age = age
                        })
                        
                        -- Count by rating level
                        rating_distribution[rating] = (rating_distribution[rating] or 0) + 1
                    end
                    break
                end
                player_rec = players_table_global:GetNextValidRecord()
            end
        end
        rec = team_player_links_global:GetNextValidRecord()
    end
    
    -- Log summary
    LOGGER:LogInfo("="..string.rep("=", 60))
    LOGGER:LogInfo("FREE AGENT ANALYSIS RESULTS")
    LOGGER:LogInfo("="..string.rep("=", 60))
    LOGGER:LogInfo(string.format("Total players in source team: %d", total_players_in_team))
    LOGGER:LogInfo(string.format("Players within age range (%d-%d): %d", 
        config.age_constraints.min, config.age_constraints.max, players_within_age))
    LOGGER:LogInfo(string.format("Percentage of eligible players: %.1f%%", 
        total_players_in_team > 0 and (players_within_age / total_players_in_team * 100) or 0))
    
    -- Sort eligible players by rating (highest first)
    table.sort(eligible_players, function(a, b) return a.overall > b.overall end)
    
    -- Log top 20 players
    LOGGER:LogInfo("")
    LOGGER:LogInfo("TOP 20 ELIGIBLE FREE AGENTS:")
    LOGGER:LogInfo("-"..string.rep("-", 50))
    for i = 1, math.min(20, #eligible_players) do
        local player = eligible_players[i]
        LOGGER:LogInfo(string.format("%2d. %s (ID: %d) - Rating: %d, Age: %d", 
            i, player.name, player.playerid, player.overall, player.age))
    end
    
    -- Get sorted rating levels
    local rating_levels = {}
    for rating, _ in pairs(rating_distribution) do
        table.insert(rating_levels, rating)
    end
    table.sort(rating_levels, function(a, b) return a > b end) -- Highest first
    
    -- Log rating distribution
    LOGGER:LogInfo("")
    LOGGER:LogInfo("PLAYER DISTRIBUTION BY OVERALL RATING:")
    LOGGER:LogInfo("-"..string.rep("-", 40))
    for _, rating in ipairs(rating_levels) do
        local count = rating_distribution[rating]
        local percentage = players_within_age > 0 and (count / players_within_age * 100) or 0
        LOGGER:LogInfo(string.format("Rating %d: %d players (%.1f%%)", rating, count, percentage))
    end
    
    -- Statistical analysis
    if #eligible_players > 0 then
        -- Calculate rating statistics
        local ratings_list = {}
        for _, player in ipairs(eligible_players) do
            table.insert(ratings_list, player.overall)
        end
        table.sort(ratings_list)
        
        local min_rating = ratings_list[1]
        local max_rating = ratings_list[#ratings_list]
        local total_rating = 0
        for _, rating in ipairs(ratings_list) do
            total_rating = total_rating + rating
        end
        local avg_rating = total_rating / #ratings_list
        
        local median_rating
        local n = #ratings_list
        if n % 2 == 0 then
            median_rating = (ratings_list[n/2] + ratings_list[n/2 + 1]) / 2
        else
            median_rating = ratings_list[math.ceil(n/2)]
        end
        
        LOGGER:LogInfo("")
        LOGGER:LogInfo("RATING STATISTICS:")
        LOGGER:LogInfo("-"..string.rep("-", 25))
        LOGGER:LogInfo(string.format("Minimum Rating: %d", min_rating))
        LOGGER:LogInfo(string.format("Maximum Rating: %d", max_rating))
        LOGGER:LogInfo(string.format("Average Rating: %.1f", avg_rating))
        LOGGER:LogInfo(string.format("Median Rating: %.1f", median_rating))
        LOGGER:LogInfo(string.format("Rating Range: %d", max_rating - min_rating))
    end
    
    -- Age distribution analysis
    local age_distribution = {}
    for _, player in ipairs(eligible_players) do
        local age = player.age
        age_distribution[age] = (age_distribution[age] or 0) + 1
    end
    
    local age_levels = {}
    for age, _ in pairs(age_distribution) do
        table.insert(age_levels, age)
    end
    table.sort(age_levels)
    
    LOGGER:LogInfo("")
    LOGGER:LogInfo("PLAYER DISTRIBUTION BY AGE:")
    LOGGER:LogInfo("-"..string.rep("-", 30))
    for _, age in ipairs(age_levels) do
        local count = age_distribution[age]
        local percentage = players_within_age > 0 and (count / players_within_age * 100) or 0
        LOGGER:LogInfo(string.format("Age %d: %d players (%.1f%%)", age, count, percentage))
    end
    
    LOGGER:LogInfo("")
    LOGGER:LogInfo("="..string.rep("=", 60))
    LOGGER:LogInfo("ANALYSIS COMPLETE")
    LOGGER:LogInfo("="..string.rep("=", 60))
    
    -- Show message box with summary
    local summary_min_rating = 0
    local summary_max_rating = 0
    local summary_avg_rating = 0
    
    if #eligible_players > 0 then
        -- Use the already calculated values
        local ratings_list = {}
        for _, player in ipairs(eligible_players) do
            table.insert(ratings_list, player.overall)
        end
        table.sort(ratings_list)
        
        summary_min_rating = ratings_list[1]
        summary_max_rating = ratings_list[#ratings_list]
        
        local total_rating = 0
        for _, rating in ipairs(ratings_list) do
            total_rating = total_rating + rating
        end
        summary_avg_rating = total_rating / #eligible_players
    end
    
    MessageBox("Free Agent Analysis Complete", string.format(
        "Analysis Results:\n\n" ..
        "Total players in source team: %d\n" ..
        "Eligible players (age %d-%d): %d\n" ..
        "Rating range: %d-%d\n" ..
        "Average rating: %.1f\n\n" ..
        "Check console log for detailed breakdown.",
        total_players_in_team,
        config.age_constraints.min, config.age_constraints.max,
        players_within_age,
        summary_min_rating,
        summary_max_rating,
        summary_avg_rating
    ))
end

--------------------------------------------------------------------------------
-- MAIN SCRIPT EXECUTION
--------------------------------------------------------------------------------
LOGGER:LogInfo("Starting Free Agent Analyzer Script...")
analyze_free_agents() 