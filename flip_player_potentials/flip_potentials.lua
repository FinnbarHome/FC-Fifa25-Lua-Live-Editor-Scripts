-- FLIP-BASED POTENTIAL SCRIPT
-- Pairs up players of similar age ranges and fully swaps their potential values, 
-- respecting the condition that potentials remain >= current overall.
-- Improved for FC 25 Live Editor with better pairing algorithm and configurable options.

require 'imports/other/helpers'
require 'imports/career_mode/helpers'

------------------------------------------------------------------------------
-- 1) CONFIG
------------------------------------------------------------------------------

-- User configurable options
local CONFIG = {
    -- Which age ranges to include in the flip (true = include, false = skip)
    includeRanges = {
        ["16-17"] = true,
        ["18-19"] = true,
        ["20-21"] = true,
        ["22-25"] = true,
        ["26-28"] = true,
        ["29-31"] = true,
        ["32+"] = true,
    },
    
    -- Teams to exclude from potential flips (e.g. { [1234] = true })
    excluded_teams = { [110] = true },
    
    -- Smart pairing to maximize successful flips (vs pure random pairing)
    useSmartPairing = true,
    
    -- Maximum attempts to find valid pairs for each player (higher = more success but slower)
    maxPairingAttempts = 10,
    
    -- Enable detailed logging
    detailedLogging = false,
}

-- Age ranges for final stats:
-- { minAge, maxAge, label }
local AGE_RANGES = {
    {16, 17, "16-17"},
    {18, 19, "18-19"},
    {20, 21, "20-21"},
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
local skipCount = {}
local totalPlayersProcessed = 0
local failedPairings = 0

-- Init for each range
for _, r in ipairs(AGE_RANGES) do
    local lbl = r[3]
    upSum[lbl]   = 0
    upCount[lbl] = 0
    downSum[lbl] = 0
    downCount[lbl] = 0
    skipCount[lbl] = 0
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
-- 4) GROUP PLAYERS BY RANGE
------------------------------------------------------------------------------

local players_table = LE.db:GetTable("players")
local team_player_links = LE.db:GetTable("teamplayerlinks")
if not players_table then
    MessageBox("Error", "No 'players' table.")
    return
end

-- Build team index first for faster lookups
LOGGER:LogInfo("Building team index...")
local player_team_map = {}
local rec = team_player_links:GetFirstRecord()
while rec > 0 do
    local pid = team_player_links:GetRecordFieldValue(rec, "playerid")
    local tid = team_player_links:GetRecordFieldValue(rec, "teamid")
    if pid and tid then
        player_team_map[pid] = tid
    end
    rec = team_player_links:GetNextValidRecord()
end
LOGGER:LogInfo("Team index built successfully")

-- rangeGroups[rangeKey] = list of { recordIndex, playerid, overall, potential, age }
local rangeGroups = {}

local function LogDebug(msg)
    if CONFIG.detailedLogging then
        LOGGER:LogInfo(msg)
    end
end

-- Initialize range groups
for _, r in ipairs(AGE_RANGES) do
    rangeGroups[r[3]] = {}
end

-- Process players in batches for better performance
local BATCH_SIZE = 1000
local processed = 0
local skipped = 0

LOGGER:LogInfo("Processing players...")
local rec = players_table:GetFirstRecord()
while rec > 0 do
    local pid = players_table:GetRecordFieldValue(rec, "playerid")
    
    -- Skip players from excluded teams using the index
    local team_id = player_team_map[pid]
    if team_id and CONFIG.excluded_teams[team_id] then
        skipped = skipped + 1
        rec = players_table:GetNextValidRecord()
        goto continue
    end
    
    local ov = players_table:GetRecordFieldValue(rec, "overallrating")
    if not ov or ov == 0 then
        local alt = players_table:GetRecordFieldValue(rec, "overall")
        ov = (alt and alt > 0) and alt or 50
    end
    
    local pot = players_table:GetRecordFieldValue(rec, "potential") or 50
    
    local bd = players_table:GetRecordFieldValue(rec, "birthdate")
    local age = GetAge(bd)
    local rKey = GetRangeKey(age)
    
    -- Only add if we're processing this range
    if CONFIG.includeRanges[rKey] then
        table.insert(rangeGroups[rKey], {
            recordIndex = rec,
            playerid    = pid,
            overall     = ov,
            potential   = pot,
            age         = age,
            rangeKey    = rKey 
        })
        totalPlayersProcessed = totalPlayersProcessed + 1
    end
    
    processed = processed + 1
    if processed % BATCH_SIZE == 0 then
        LOGGER:LogInfo(string.format("Processed %d players (%d skipped)...", processed, skipped))
    end
    
    rec = players_table:GetNextValidRecord()
    ::continue::
end

LOGGER:LogInfo(string.format("Finished processing %d players (%d skipped)", processed, skipped))

------------------------------------------------------------------------------
-- 5) IMPROVED FLIP POTENTIAL ALGORITHM
------------------------------------------------------------------------------

local totalFlips = 0

local function CanSwapPotentials(p1, p2)
    -- Only check that the potential >= overall after swap
    return p2.potential >= p1.overall and p1.potential >= p2.overall
end

local function DoSwapPotentials(p1, p2)
    -- Get current values
    local potA = p1.potential
    local potB = p2.potential
    
    -- Safety check
    if potB < p1.overall or potA < p2.overall then
        LogDebug(string.format("Invalid swap - Player %d pot: %d -> %d (ovr: %d), Player %d pot: %d -> %d (ovr: %d)",
            p1.playerid, potA, potB, p1.overall, p2.playerid, potB, potA, p2.overall))
        return false
    end
    
    -- Flip in DB
    players_table:SetRecordFieldValue(p1.recordIndex, "potential", potB)
    players_table:SetRecordFieldValue(p2.recordIndex, "potential", potA)
    
    -- Calculate deltas
    local dA = potB - potA
    local dB = potA - potB
    
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
    
    -- Update local values for accurate tracking
    p1.potential = potB
    p2.potential = potA
    
    LogDebug(string.format("Swapped - Player %d: %d -> %d, Player %d: %d -> %d", 
        p1.playerid, potA, potB, p2.playerid, potB, potA))
        
    return true
end

-- Process each age range
for _, rangeData in ipairs(AGE_RANGES) do
    local rangeKey = rangeData[3]
    
    -- Skip if range is disabled in config
    if not CONFIG.includeRanges[rangeKey] then
        LogDebug("Skipping range: " .. rangeKey)
        goto continue
    end
    
    local players = rangeGroups[rangeKey]
    
    if #players < 2 then
        LogDebug("Not enough players in range: " .. rangeKey)
        goto continue
    end
    
    LogDebug(string.format("Processing %d players in range %s", #players, rangeKey))
    
    -- Thoroughly shuffle the players for maximum randomization
    for i = 1, 3 do  -- Multiple shuffle passes for better randomization
        for j = #players, 2, -1 do
            local k = math.random(j)
            players[j], players[k] = players[k], players[j]
        end
    end
    
    -- Track which players have been processed
    local processed = {}
    for i = 1, #players do
        processed[i] = false
    end
    
    if CONFIG.useSmartPairing then
        -- Smart pairing algorithm
        for i = 1, #players do
            if not processed[i] then
                local p1 = players[i]
                local candidates = {}
                
                -- Find all valid candidates first
                for j = 1, #players do
                    if not processed[j] and j ~= i then
                        local p2 = players[j]
                        
                        if CanSwapPotentials(p1, p2) then
                            table.insert(candidates, j)
                        end
                    end
                end
                
                -- If we have candidates, pick one randomly
                if #candidates > 0 then
                    local randomIdx = math.random(#candidates)
                    local bestPairIndex = candidates[randomIdx]
                    
                    if DoSwapPotentials(p1, players[bestPairIndex]) then
                        totalFlips = totalFlips + 1
                        processed[i] = true
                        processed[bestPairIndex] = true
                    end
                else
                    -- Could not find a valid pair for this player
                    skipCount[rangeKey] = skipCount[rangeKey] + 1
                    processed[i] = true
                    failedPairings = failedPairings + 1
                end
            end
        end
        
        -- Second pass to catch any unprocessed players
        if failedPairings > 0 then
            local unprocessed = {}
            for i = 1, #players do
                if not processed[i] then
                    table.insert(unprocessed, i)
                end
            end
            
            -- If we have an even number of unprocessed players, try to pair them
            if #unprocessed >= 2 then
                -- Shuffle the unprocessed list
                for i = #unprocessed, 2, -1 do
                    local j = math.random(i)
                    unprocessed[i], unprocessed[j] = unprocessed[j], unprocessed[i]
                end
                
                -- Attempt to pair them
                for i = 1, #unprocessed, 2 do
                    if i + 1 <= #unprocessed then
                        local p1 = players[unprocessed[i]]
                        local p2 = players[unprocessed[i+1]]
                        
                        p1.rangeKey = rangeKey
                        p2.rangeKey = rangeKey
                        
                        if CanSwapPotentials(p1, p2) then
                            if DoSwapPotentials(p1, p2) then
                                totalFlips = totalFlips + 1
                                processed[unprocessed[i]] = true
                                processed[unprocessed[i+1]] = true
                            end
                        end
                    end
                end
            end
        end
    else
        local i = 1
        while i < #players do
            local p1 = players[i]
            local p2 = players[i+1]
            
            -- Ensure rangeKey is set
            p1.rangeKey = rangeKey
            p2.rangeKey = rangeKey
            
            if CanSwapPotentials(p1, p2) then
                if DoSwapPotentials(p1, p2) then
                    totalFlips = totalFlips + 1
                end
            else
                skipCount[rangeKey] = skipCount[rangeKey] + 2
                failedPairings = failedPairings + 1
            end
            
            i = i + 2
        end
        
        -- Handle odd number of players
        if #players % 2 == 1 then
            skipCount[rangeKey] = skipCount[rangeKey] + 1
        end
    end
    
    ::continue::
end

------------------------------------------------------------------------------
-- 6) ENHANCED STATS OUTPUT
------------------------------------------------------------------------------

local lines = {}
table.insert(lines, string.format("FC 25 Potential Flip Script Complete"))
table.insert(lines, string.format("Total players processed: %d", totalPlayersProcessed))
table.insert(lines, string.format("Successful potential flips: %d", totalFlips))
table.insert(lines, string.format("Failed pairings: %d", failedPairings))
table.insert(lines, "")
table.insert(lines, "Stats by age range:")

for _, rr in ipairs(AGE_RANGES) do
    local lbl = rr[3]
    
    -- Skip disabled ranges in output
    if not CONFIG.includeRanges[lbl] then
        table.insert(lines, string.format("  %s -> DISABLED", lbl))
        goto nextRange
    end
    
    local totalInRange = #rangeGroups[lbl]
    local skipped = skipCount[lbl]
    
    local au, cu = 0, upCount[lbl]
    if cu > 0 then
        au = upSum[lbl] / cu
    end
    
    local ad, cd = 0, downCount[lbl]
    if cd > 0 then
        ad = downSum[lbl] / cd
    end
    
    local successRate = 0
    if totalInRange > 0 then
        successRate = ((totalInRange - skipped) / totalInRange) * 100
    end
    
    table.insert(lines, string.format(
        "  %s -> Success: %.1f%% (%d/%d players) | Avg changes: +%.1f (×%d), -%.1f (×%d)",
        lbl, successRate, (totalInRange - skipped), totalInRange, au, cu, ad, cd
    ))
    
    ::nextRange::
end

local finalMsg = table.concat(lines, "\n")
LOGGER:LogInfo(finalMsg)
MessageBox("FC 25 Potential Flip", finalMsg)
