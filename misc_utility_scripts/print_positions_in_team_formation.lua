require 'imports/career_mode/helpers'
require 'imports/other/helpers'

----------------------------------------------------------------------------
-- 1) Configuration - Made By The Mayo Man (themayonnaiseman)
----------------------------------------------------------------------------
-- Change this to the team ID you want to inspect
local TARGET_TEAM_ID = 12345

-- In your DB: "formations" table has fields:
--   teamid, position0, position1, ... position10
local FORMATIONS_TABLE_NAME = "formations"

-- Mapping from position IDs to position names.
-- Provided ID sets have multiple IDs mapping to one name.
-- Reverse map that goes ID -> name for easy lookup.
local position_ids = {
    ["GK"]  = {0},
    ["CB"]  = {1,4,5,6},
    ["RB"]  = {2,3},
    ["LB"]  = {7,8},
    ["CDM"] = {9,10,11},
    ["RM"]  = {12},
    ["CM"]  = {13,14,15},
    ["LM"]  = {16},
    ["CAM"] = {17,18,19},
    ["ST"]  = {20,21,22,24,25,26},
    ["RW"]  = {23},
    ["LW"]  = {27}
}

----------------------------------------------------------------------------
-- 2) Build a reverse lookup: positionNameByID[posID] = "ST" (etc.)
----------------------------------------------------------------------------
local positionNameByID = {}

for name, idList in pairs(position_ids) do
    for _, idVal in ipairs(idList) do
        positionNameByID[idVal] = name
    end
end

-- Helper function to map a numeric ID to a position name (or "Unknown")
local function GetPositionName(posID)
    return positionNameByID[posID] or string.format("Unknown(%d)", posID)
end

----------------------------------------------------------------------------
-- 3) Main Script
----------------------------------------------------------------------------
local formations_table = LE.db:GetTable(FORMATIONS_TABLE_NAME)
if not formations_table then
    MessageBox("Error", string.format("'%s' table not found.", FORMATIONS_TABLE_NAME))
    return
end

-- Attempt to find the record in "formations" table for the specified team ID
local record = formations_table:GetFirstRecord()
local foundRecord = 0

while record > 0 do
    local teamid = formations_table:GetRecordFieldValue(record, "teamid")
    if teamid == TARGET_TEAM_ID then
        foundRecord = record
        break
    end
    record = formations_table:GetNextValidRecord()
end

if foundRecord == 0 then
    MessageBox("Not Found", string.format(
        "No formation data found for team ID %d in '%s' table.",
        TARGET_TEAM_ID, FORMATIONS_TABLE_NAME
    ))
    return
end

-- Now read each position0..position10 for that record
local positions = {}
for i = 0, 10 do
    local fieldName = string.format("position%d", i)
    local posID = formations_table:GetRecordFieldValue(foundRecord, fieldName)
    local posName = GetPositionName(posID)

    table.insert(positions, string.format("position%d = %s (ID=%d)", i, posName, posID))
end

-- Print or log them
local lines = {}
table.insert(lines, string.format("Team %d Formation Layout:", TARGET_TEAM_ID))
for _, line in ipairs(positions) do
    table.insert(lines, line)
end

-- Send to logger and a message box
local finalMsg = table.concat(lines, "\n")
LOGGER:LogInfo(finalMsg)
MessageBox("Formation Info", finalMsg)
