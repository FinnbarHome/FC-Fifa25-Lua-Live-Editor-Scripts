require 'imports/other/helpers'
require 'imports/career_mode/helpers'

------------------------------------------------------------------------------
-- 1) CONFIG
------------------------------------------------------------------------------

-- How many players to modify (under 20, overall ≤ threshold, potential ≤ threshold)
local NUMBER_OF_TARGET_PLAYERS = 20

-- Potential range to assign
local MIN_POT = 85
local MAX_POT = 90

-- Only affect players with current overall ≤ this rating
local MAX_CURRENT_OVERALL = 65

-- Only affect players whose current potential ≤ this rating
local MAX_CURRENT_POTENTIAL = 70  -- e.g., ignore players who already have 81+ potential

------------------------------------------------------------------------------
-- 2) HELPER: GetAge(birthdate)
------------------------------------------------------------------------------

local function GetAge(birthdate)
    if not birthdate or birthdate <= 0 then
        return 20  -- fallback
    end
    local current_date = GetCurrentDate()
    local date_obj = DATE:new()
    date_obj:FromGregorianDays(birthdate)

    local age = current_date.year - date_obj.year
    if (current_date.month < date_obj.month)
       or (current_date.month == date_obj.month and current_date.day < date_obj.day) then
        age = age - 1
    end
    if age < 0 then age = 0 end
    return age
end

------------------------------------------------------------------------------
-- 3) MAIN SCRIPT
------------------------------------------------------------------------------

local players_table = LE.db:GetTable("players")
if not players_table then
    MessageBox("Error", "Could not access 'players' table.")
    return
end

local eligiblePlayers = {}

local current_record = players_table:GetFirstRecord()

while current_record > 0 do
    local playerid = players_table:GetRecordFieldValue(current_record, "playerid")

    -- Attempt to get current overall from 'overallrating', fallback to 'overall'
    local overall = players_table:GetRecordFieldValue(current_record, "overallrating")
    if not overall or overall == 0 then
        local altOverall = players_table:GetRecordFieldValue(current_record, "overall")
        if altOverall and altOverall > 0 then
            overall = altOverall
        else
            overall = 50
        end
    end

    local potential = players_table:GetRecordFieldValue(current_record, "potential") or 50

    local birthdate = players_table:GetRecordFieldValue(current_record, "birthdate")
    local age       = GetAge(birthdate)

    -- Criteria:
    -- 1) Age ≤ 19
    -- 2) Overall ≤ MAX_CURRENT_OVERALL
    -- 3) Potential ≤ MAX_CURRENT_POTENTIAL
    if age <= 19 and overall <= MAX_CURRENT_OVERALL and potential <= MAX_CURRENT_POTENTIAL then
        table.insert(eligiblePlayers, {
            recordIndex = current_record,
            playerid    = playerid
        })
    end

    current_record = players_table:GetNextValidRecord()
end

-- If fewer eligible players than requested, clamp
if #eligiblePlayers < NUMBER_OF_TARGET_PLAYERS then
    NUMBER_OF_TARGET_PLAYERS = #eligiblePlayers
end

-- Shuffle the eligible players (so selection is random)
for i = #eligiblePlayers, 2, -1 do
    local j = math.random(i)
    eligiblePlayers[i], eligiblePlayers[j] = eligiblePlayers[j], eligiblePlayers[i]
end

local changedCount = 0
for i = 1, NUMBER_OF_TARGET_PLAYERS do
    local pInfo = eligiblePlayers[i]

    -- Assign random potential in [MIN_POT..MAX_POT]
    local newPotential = math.random(MIN_POT, MAX_POT)

    -- Update the DB
    players_table:SetRecordFieldValue(pInfo.recordIndex, "potential", newPotential)
    changedCount = changedCount + 1

    -- Optional logging:
    -- LOGGER:LogInfo(string.format(
    --     "Updated player %d potential to %d (was <= %d).",
    --     pInfo.playerid, newPotential, MAX_CURRENT_POTENTIAL
    -- ))
end

MessageBox("Done", string.format(
    "Set potential [%d..%d] for %d players (19 or under, overall ≤ %d, pot ≤ %d).",
    MIN_POT, MAX_POT, changedCount, MAX_CURRENT_OVERALL, MAX_CURRENT_POTENTIAL
))
