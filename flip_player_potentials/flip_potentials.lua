-- FLIP-BASED POTENTIAL SCRIPT
-- Pairs up players of the same age and flips their potential values, 
-- respecting the condition that flipped potentials remain >= current overall.


require 'imports/other/helpers'
require 'imports/career_mode/helpers'

------------------------------------------------------------------------------
-- 1) CONFIG
------------------------------------------------------------------------------

-- Age ranges for final stats:
-- { minAge, maxAge, label }
local AGE_RANGES = {
    {16, 18, "16-18"},
    {19, 21, "19-21"},
    {22, 25, "22-25"},
    {26, 28, "26-28"},
    {29, 31, "29-31"},
    {32, 99, "32+"}
}

------------------------------------------------------------------------------
-- 2) TRACKING STATS
------------------------------------------------------------------------------

-- upSum[label], upCount[label], downSum[label], downCount[label]
-- Store total up/down changes & counts per age range.
local upSum   = {}
local upCount = {}
local downSum = {}
local downCount = {}

-- Init for each range
for _, r in ipairs(AGE_RANGES) do
    local lbl = r[3]
    upSum[lbl]   = 0
    upCount[lbl] = 0
    downSum[lbl] = 0
    downCount[lbl] = 0
end

-- Maps an age to a range label.
local function GetRangeKey(age)
    for _, rr in ipairs(AGE_RANGES) do
        local minA, maxA, label = rr[1], rr[2], rr[3]
        if age >= minA and age <= maxA then
            return label
        end
    end
    return "32+"
end

------------------------------------------------------------------------------
-- 3) AGE CALC
------------------------------------------------------------------------------

local function GetAge(birthdate)
    if not birthdate or birthdate <= 0 then
        return 20
    end
    local cd = GetCurrentDate() -- e.g., { year=2024, month=7, day=20 }
    local d = DATE:new()
    d:FromGregorianDays(birthdate)

    local age = cd.year - d.year
    if (cd.month < d.month) or (cd.month == d.month and cd.day < d.day) then
        age = age - 1
    end
    if age < 16 then age = 16 end
    if age > 99 then age = 99 end
    return age
end

------------------------------------------------------------------------------
-- 4) GROUP PLAYERS BY AGE
------------------------------------------------------------------------------

local players_table = LE.db:GetTable("players")
if not players_table then
    MessageBox("Error", "No 'players' table.")
    return
end

-- ageGroups[age] = list of { recordIndex, playerid, overall, potential, rangeKey }
local ageGroups = {}

local rec = players_table:GetFirstRecord()
while rec > 0 do
    local pid = players_table:GetRecordFieldValue(rec, "playerid")

    local ov = players_table:GetRecordFieldValue(rec, "overallrating")
    if not ov or ov == 0 then
        local alt = players_table:GetRecordFieldValue(rec, "overall")
        ov = (alt and alt > 0) and alt or 50
    end

    local pot = players_table:GetRecordFieldValue(rec, "potential") or 50

    local bd = players_table:GetRecordFieldValue(rec, "birthdate")
    local age = GetAge(bd)
    local rKey = GetRangeKey(age)

    if not ageGroups[age] then
        ageGroups[age] = {}
    end

    table.insert(ageGroups[age], {
        recordIndex = rec,
        playerid    = pid,
        overall     = ov,
        potential   = pot,
        rangeKey    = rKey
    })

    rec = players_table:GetNextValidRecord()
end

------------------------------------------------------------------------------
-- 5) FLIP POTENTIAL PER AGE GROUP
------------------------------------------------------------------------------

local totalFlips = 0

for age, plist in pairs(ageGroups) do
    -- Shuffle
    for i = #plist, 2, -1 do
        local j = math.random(i)
        plist[i], plist[j] = plist[j], plist[i]
    end

    -- Pair up: (1,2), (3,4), ...
    local i = 1
    while i < #plist do
        local p1 = plist[i]
        local p2 = plist[i+1]
        i = i + 2

        local potA = p1.potential
        local potB = p2.potential
        local ovA  = p1.overall
        local ovB  = p2.overall

        local newPotA = potB
        local newPotB = potA

        -- Check validity
        if newPotA >= ovA and newPotB >= ovB then
            -- Flip in DB
            players_table:SetRecordFieldValue(p1.recordIndex, "potential", newPotA)
            players_table:SetRecordFieldValue(p2.recordIndex, "potential", newPotB)
            totalFlips = totalFlips + 1

            -- Calculate deltas
            local dA = newPotA - potA
            local dB = newPotB - potB

            -- Update up/down stats
            if dA > 0 then
                upSum[p1.rangeKey]   = upSum[p1.rangeKey] + dA
                upCount[p1.rangeKey] = upCount[p1.rangeKey] + 1
            elseif dA < 0 then
                local absD = math.abs(dA)
                downSum[p1.rangeKey]   = downSum[p1.rangeKey] + absD
                downCount[p1.rangeKey] = downCount[p1.rangeKey] + 1
            end

            if dB > 0 then
                upSum[p2.rangeKey]   = upSum[p2.rangeKey] + dB
                upCount[p2.rangeKey] = upCount[p2.rangeKey] + 1
            elseif dB < 0 then
                local absD = math.abs(dB)
                downSum[p2.rangeKey]   = downSum[p2.rangeKey] + absD
                downCount[p2.rangeKey] = downCount[p2.rangeKey] + 1
            end

            -- Update local values
            p1.potential = newPotA
            p2.potential = newPotB
        end
    end
end

------------------------------------------------------------------------------
-- 6) STATS OUTPUT
------------------------------------------------------------------------------

local lines = {}
table.insert(lines, string.format("Flip-based script done. Flips: %d", totalFlips))
table.insert(lines, "")
table.insert(lines, "Avg potential UP & DOWN by age range:")

for _, rr in ipairs(AGE_RANGES) do
    local lbl = rr[3]
    local au, cu = 0, upCount[lbl]
    if cu > 0 then
        au = upSum[lbl] / cu
    end

    local ad, cd = 0, downCount[lbl]
    if cd > 0 then
        ad = downSum[lbl] / cd
    end

    table.insert(lines, string.format(
        "  %s -> flipsUp=%d (avgUp=%.2f), flipsDown=%d (avgDown=%.2f)",
        lbl, cu, au, cd, ad
    ))
end

local finalMsg = table.concat(lines, "\n")
LOGGER:LogInfo(finalMsg)
MessageBox("Done", finalMsg)
