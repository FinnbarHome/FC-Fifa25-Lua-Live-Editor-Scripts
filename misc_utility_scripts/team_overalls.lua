require 'imports/career_mode/helpers'
require 'imports/other/helpers'

local team_player_links_global = LE.db:GetTable("teamplayerlinks")
local players_table_global     = LE.db:GetTable("players")
local formations_table_global  = LE.db:GetTable("formations")
local league_team_links_global = LE.db:GetTable("leagueteamlinks")

local team_id = 1

--------------------------------------------------------------------------------
-- Calculate and log various rating statistics: min, 25%, 50% (median), 
-- mean, 75%, and max
--------------------------------------------------------------------------------
local function log_team_rating_stats(team_id)
    -- Collect all overall ratings for players on the given team
    local overall_ratings = {}
    local team_player_links_record = team_player_links_global:GetFirstRecord()

    while team_player_links_record > 0 do
        local current_team_id = team_player_links_global:GetRecordFieldValue(team_player_links_record, "teamid")
        local player_id       = team_player_links_global:GetRecordFieldValue(team_player_links_record, "playerid")

        if current_team_id == team_id then
            -- Look up the player's overall rating from the 'players' table
            local player_record = players_table_global:GetFirstRecord()
            while player_record > 0 do
                local p_id = players_table_global:GetRecordFieldValue(player_record, "playerid")
                if p_id == player_id then
                    -- Try 'overallrating' first, fallback to 'overall'
                    local rating = players_table_global:GetRecordFieldValue(player_record, "overallrating")
                                   or players_table_global:GetRecordFieldValue(player_record, "overall")
                                   or 0
                    table.insert(overall_ratings, rating)
                    break
                end
                player_record = players_table_global:GetNextValidRecord()
            end
        end

        team_player_links_record = team_player_links_global:GetNextValidRecord()
    end

    -- If no players or no ratings found, log a warning and return
    if #overall_ratings == 0 then
        LOGGER:LogWarning(string.format("No ratings found for team %d.", team_id))
        return
    end

    -- Sort the ratings in ascending order
    table.sort(overall_ratings)

    local n = #overall_ratings

    -- Minimum (0% percentile)
    local min_rating = overall_ratings[1]
    local min_rating_rounded = math.floor(min_rating + 0.5)

    -- 25% percentile (Q1)
    local index_25 = math.ceil(0.25 * n)
    local percentile_25 = overall_ratings[index_25]
    local percentile_25_rounded = math.floor(percentile_25 + 0.5)

    -- 50% percentile (median)
    local index_50 = math.ceil(0.5 * n)
    local percentile_50 = overall_ratings[index_50]
    local percentile_50_rounded = math.floor(percentile_50 + 0.5)

    -- 75% percentile (Q3)
    local index_75 = math.ceil(0.75 * n)
    local percentile_75 = overall_ratings[index_75]
    local percentile_75_rounded = math.floor(percentile_75 + 0.5)

    -- 100% percentile (maximum)
    local max_rating = overall_ratings[n]
    local max_rating_rounded = math.floor(max_rating + 0.5)

    -- Mean
    local sum = 0
    for _, value in ipairs(overall_ratings) do
        sum = sum + value
    end
    local mean = sum / n

    -- Log all stats
    LOGGER:LogInfo(string.format("Team %d Ratings Stats:", team_id))
    LOGGER:LogInfo(string.format("   0%% (min): %d", min_rating_rounded))
    LOGGER:LogInfo(string.format("   25%% (Q1): %d", percentile_25_rounded))
    LOGGER:LogInfo(string.format("   50%% (median): %d", percentile_50_rounded))
    LOGGER:LogInfo(string.format("   Mean: %.2f", mean))
    LOGGER:LogInfo(string.format("   75%% (Q3): %d", percentile_75_rounded))
    LOGGER:LogInfo(string.format("   100%% (max): %d", max_rating_rounded))
end

-- Example usage
log_team_rating_stats(team_id)
