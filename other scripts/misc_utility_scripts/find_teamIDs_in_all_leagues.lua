require 'imports/other/helpers'
require 'imports/career_mode/helpers'

-- This script will build a mapping of leagueID -> list of teamIDs - Made By The Mayo Man (themayonnaiseman)
-- and then print it in a format you can directly copy into another Lua file.

--------------------------------------------------------------------------------
-- 1) Gather data from 'leagueteamlinks'
--------------------------------------------------------------------------------

local leagueteamlinks_table = LE.db:GetTable("leagueteamlinks")
if not leagueteamlinks_table then
    MessageBox("Error", "Could not access 'leagueteamlinks' table.")
    return
end

-- We'll store them in leagueTeams[leagueid] = { team1, team2, ... }
local leagueTeams = {}

local record = leagueteamlinks_table:GetFirstRecord()

while record > 0 do
    local leagueid = leagueteamlinks_table:GetRecordFieldValue(record, "leagueid")
    local teamid   = leagueteamlinks_table:GetRecordFieldValue(record, "teamid")

    if leagueid and teamid then
        if not leagueTeams[leagueid] then
            leagueTeams[leagueid] = {}
        end
        table.insert(leagueTeams[leagueid], teamid)
    end

    record = leagueteamlinks_table:GetNextValidRecord()
end

--------------------------------------------------------------------------------
-- 2) Sort leagueIDs and teamIDs if you want
--------------------------------------------------------------------------------
-- Optional: If you want the output in sorted order:
local leagueIDs = {}
for lgId in pairs(leagueTeams) do
    table.insert(leagueIDs, lgId)
end
table.sort(leagueIDs)  -- sorts league IDs ascending

-- Also sort the team lists:
for lgId, teams in pairs(leagueTeams) do
    table.sort(teams)  -- sorts team IDs ascending
end

--------------------------------------------------------------------------------
-- 3) Print the result in a copy-paste-friendly format
--------------------------------------------------------------------------------
-- We'll build a big multiline string that you can copy/paste into another script.
-- For example:
--
-- leagueTeams = {
--   [39] = { 112026, 112101, 112102, ... },
--   [61] = { 111000, 111555, ... },
-- }

local outputLines = {}
table.insert(outputLines, "leagueTeams = {")

for _, lgId in ipairs(leagueIDs) do
    local teams = leagueTeams[lgId]
    -- Convert the list of teams to a comma-separated string
    local teamListStr = table.concat(teams, ", ")

    local line = string.format("    [%d] = { %s },", lgId, teamListStr)
    table.insert(outputLines, line)
end

table.insert(outputLines, "}")

-- Join all lines
local finalOutput = table.concat(outputLines, "\n")

-- Print to the logger
LOGGER:LogInfo("====================== COPY THIS ======================")
LOGGER:LogInfo(finalOutput)
LOGGER:LogInfo("====================== COPY END ======================")

MessageBox("Done", "League-to-Team mapping printed to logger.\nOpen the Lua Script log and copy the output.")
