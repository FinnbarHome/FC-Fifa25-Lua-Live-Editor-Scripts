require 'imports/other/helpers'
require 'imports/career_mode/helpers'

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------

local MIN_AGE = 16
local MAX_AGE = 35

--------------------------------------------------------------------------------
-- HELPER: GetAge(birthdate)
--------------------------------------------------------------------------------

local function GetAge(birthdate)
    if not birthdate or birthdate <= 0 then
        return 20  -- fallback if missing data
    end
    
    local current_date = GetCurrentDate()  -- e.g., { year=2024, month=7, day=20 }
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

--------------------------------------------------------------------------------
-- MAIN SCRIPT
--------------------------------------------------------------------------------

local players_table = LE.db:GetTable("players")
if not players_table then
    MessageBox("Error", "Could not access 'players' table.")
    return
end

-- Create a data structure to track sums & counts per age
-- ageStats[age] = { sumOverall=0, sumPotential=0, count=0 }
local ageStats = {}
for age = MIN_AGE, MAX_AGE do
    ageStats[age] = { sumOverall=0, sumPotential=0, count=0 }
end

-- Iterate over all players
local record = players_table:GetFirstRecord()
while record > 0 do
    local playerid   = players_table:GetRecordFieldValue(record, "playerid")

    -- Attempt to get overall
    local overall    = players_table:GetRecordFieldValue(record, "overallrating")
    if not overall or overall == 0 then
        local alt = players_table:GetRecordFieldValue(record, "overall")
        if alt and alt > 0 then
            overall = alt
        else
            overall = 50 -- fallback
        end
    end

    local potential  = players_table:GetRecordFieldValue(record, "potential") or 50
    local birthdate  = players_table:GetRecordFieldValue(record, "birthdate")
    local age        = GetAge(birthdate)

    -- If age is within 16..35
    if age >= MIN_AGE and age <= MAX_AGE then
        local st = ageStats[age]
        st.sumOverall   = st.sumOverall + overall
        st.sumPotential = st.sumPotential + potential
        st.count        = st.count + 1
    end

    record = players_table:GetNextValidRecord()
end

-- Build an output
local lines = {}
table.insert(lines, "Average Overall & Potential by Age (16..35):")
for age = MIN_AGE, MAX_AGE do
    local st = ageStats[age]
    if st.count > 0 then
        local avgOverall   = st.sumOverall / st.count
        local avgPotential = st.sumPotential / st.count
        table.insert(lines, string.format(
            "Age %d -> AvgOverall=%.2f, AvgPotential=%.2f (count=%d)",
            age, avgOverall, avgPotential, st.count
        ))
    else
        table.insert(lines, string.format("Age %d -> No players found.", age))
    end
end

local finalMsg = table.concat(lines, "\n")
LOGGER:LogInfo(finalMsg)
MessageBox("Done", finalMsg)
