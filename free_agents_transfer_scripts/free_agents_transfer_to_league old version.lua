--------------------------------------------------------------------------------
-- Enhanced Lua Script for Multi-League Player Transfers
-- with Position IDs Mapping, Priority Queue, and League-Specific Constraints
--------------------------------------------------------------------------------

require 'imports/career_mode/helpers'
require 'imports/other/helpers'

local teamplayerlinks_global = LE.db:GetTable("teamplayerlinks")
local players_table_global   = LE.db:GetTable("players")
local formations_table_global = LE.db:GetTable("formations")
local leagueteamlinks_global = LE.db:GetTable("leagueteamlinks")

--------------------------------------------------------------------------------
-- 0) CONFIGURATION
--------------------------------------------------------------------------------

-- 0.1) Position IDs: updated mapping
local position_ids = {
    GK = {0}, 
    CB = {1, 4, 5, 6}, 
    RB = {2, 3}, 
    LB = {7, 8},
    CDM = {9, 10, 11}, 
    RM = {12}, 
    CM = {13, 14, 15}, 
    LM = {16},
    CAM = {17, 18, 19}, 
    ST = {20, 21, 22, 24, 25, 26},
    RW = {23}, 
    LW = {27}
}


local function GetRoleIDFromRoleName(roleReq)
    local roleMapping = {
        ["GK"]  = 0,
        ["CB"]  = 5,
        ["RB"]  = 3,
        ["LB"]  = 7,
        ["CDM"] = 10,
        ["RM"]  = 12,
        ["CM"]  = 14,
        ["LM"]  = 16,
        ["CAM"] = 18,
        ["ST"]  = 25,
        ["RW"]  = 23,
        ["LW"]  = 27
    }
    return roleMapping[roleReq]
end

-- Alternative Positions Mapping
-- If no player is found for a primary position, check these alternatives
local alternative_positions = {
    RW = {"RM"}, 
    LW = {"LM"}, 
    ST = {"RW", "LW"},
    CDM = {"CM"}, 
    CAM = {"RW", "LW"}
    -- Add more mappings as needed
}

   



-- 0.2) League constraints: override or use these map-based rules
-- Format: league_constraints[leagueID] = {
--     min_overall=..., max_overall=..., min_potential=..., max_potential=...
-- }
local league_constraints = {
    [61] = {min_overall = 58, max_overall = 64, min_potential = 65, max_potential = 99}, -- league 2
    [60] = {min_overall = 65, max_overall = 69, min_potential = 65, max_potential = 99}, -- league 1
    [14] = {min_overall = 70, max_overall = 74, min_potential = 70, max_potential = 99}, -- championship
    [13] = {min_overall = 74, max_overall = 99, min_potential = 74, max_potential = 99} -- Premier league
    -- [1234567890] = {min_overall = 65, max_overall = 85, min_potential = 80, max_potential = 95},
    -- Add more leagues as needed
}

-- If a league doesn't appear in league_constraints, fallback to these globals:
local GLOBAL_MIN_OVERALL   = 55
local GLOBAL_MAX_OVERALL   = 90
local GLOBAL_MIN_POTENTIAL = 70
local GLOBAL_MAX_POTENTIAL = 99

-- Age constraints
local MIN_AGE = 16
local MAX_AGE = 35

-- Max squad size
local DESTINATION_MAX_SQUAD_SIZE = 52

-- Multi-league: user can define multiple league IDs in one run
local TARGET_LEAGUE_IDS = {61,60,14}  -- Example usage: {61,60,14,13}

-- Teams to exclude from any process, useful if you don't want to transfer to your own team
local EXCLUDED_TEAM_IDS = {
    -- [12345] = true,
    -- ...
}

--------------------------------------------------------------------------------
-- Transfer function parameters
--------------------------------------------------------------------------------

-- Transfer-related constants
local TRANSFER_SUM     = 0   -- e.g. 500 currency
local WAGE             = 600   -- e.g. wage
local CONTRACT_LENGTH  = 60    -- months
local RELEASE_CLAUSE   = -1    -- -1 => no release clause

-- Source team containing free agents (HIGHLY RECOMMENDED YOU KEEP IT AS FREE AGENTS)
local FROM_TEAM_ID = 111592


--------------------------------------------------------------------------------
-- 1) HELPER: Position ID -> Name
--------------------------------------------------------------------------------
-- Invert position_ids to easily map numeric IDs to role names.

local positionNameByID = {}
for roleName, idList in pairs(position_ids) do
    for _, pid in ipairs(idList) do
        positionNameByID[pid] = roleName
    end
end


local function GetRoleNameFromPositionID(posID)
    return positionNameByID[posID] or ("UnknownPos(".. tostring(posID) ..")")
end

--------------------------------------------------------------------------------
-- 2) FORMATION LOGIC: Retrieve each team's formation positions
--------------------------------------------------------------------------------


-- Returns an array of role names in the team's formation, e.g. {"CB","CB","RB","ST",...}
-- based on position0..position10, mapping each ID to the role name.
local function GetFormationRoles(teamId)
    local formations_table = formations_table_global
    if not formations_table then
        return {}
    end

    local rec = formations_table:GetFirstRecord()
    while rec > 0 do
        local tid = formations_table:GetRecordFieldValue(rec, "teamid")
        if tid == teamId then
            local roles = {}
            for i = 0, 10 do
                local fieldName = ("position%d"):format(i)
                local posID = formations_table:GetRecordFieldValue(rec, fieldName) or 0
                local roleName = GetRoleNameFromPositionID(posID)
                table.insert(roles, roleName)
            end
            return roles
        end
        rec = formations_table:GetNextValidRecord()
    end
    return {}
end


--------------------------------------------------------------------------------
-- 3) COUNT HOW MANY PLAYERS PER ROLE A TEAM HAS
--------------------------------------------------------------------------------
local function CountRolesInTeam(teamId)
    local teamplayerlinks = teamplayerlinks_global
    local players_table = players_table_global
    if not teamplayerlinks or not players_table then
        return {}
    end

    -- Cache all player positions
    local playerPositionMap = {}
    local pRec = players_table:GetFirstRecord()
    while pRec > 0 do
        local playerId = players_table:GetRecordFieldValue(pRec, "playerid")
        local prefpos1 = players_table:GetRecordFieldValue(pRec, "preferredposition1")
        if playerId and prefpos1 then
            playerPositionMap[playerId] = prefpos1
        end
        pRec = players_table:GetNextValidRecord()
    end

    -- Count roles in the team
    local roleCount = {}
    local rec = teamplayerlinks:GetFirstRecord()
    while rec > 0 do
        local tId = teamplayerlinks:GetRecordFieldValue(rec, "teamid")
        local pId = teamplayerlinks:GetRecordFieldValue(rec, "playerid")
        if tId == teamId and playerPositionMap[pId] then
            local rName = GetRoleNameFromPositionID(playerPositionMap[pId])
            roleCount[rName] = (roleCount[rName] or 0) + 1
        end
        rec = teamplayerlinks:GetNextValidRecord()
    end

    return roleCount
end


--------------------------------------------------------------------------------
-- 4) TEAM NEEDS: Double the formation requirement => perfect coverage
-- Returns array of needed roles. E.g., if formation has {"CB","CB","ST"}, we want
-- 2*(2 CB + 1 ST) => 4 CB, 2 ST. Then subtract how many we already have. If any remainder
-- is positive, that many "slots" are needed for that role.
--------------------------------------------------------------------------------
local function ComputeTeamNeeds(teamId)
    local formationRoles = GetFormationRoles(teamId)  -- e.g. {"CB","ST","CB",...}
    if #formationRoles == 0 then
        return {}
    end

    -- Tally how many roles the formation demands
    local demand = {}
    for _, rName in ipairs(formationRoles) do
        demand[rName] = (demand[rName] or 0) + 1
    end
    -- Double each
    for rName in pairs(demand) do
        demand[rName] = demand[rName] * 2
    end
    
    -- Check how many the team currently has
    local have = CountRolesInTeam(teamId)

    -- Build array of needed roles
    local neededSlots = {}
    for rName, required in pairs(demand) do
        local existing = have[rName] or 0
        local missing = required - existing
        if missing > 0 then
            for _=1, missing do
                table.insert(neededSlots, rName)
            end
        end
    end

    return neededSlots
end

--------------------------------------------------------------------------------
-- 5) GETTEAMSIZE
--------------------------------------------------------------------------------
local function GetTeamSize(teamId)
    local tpl = teamplayerlinks_global
    if not tpl then return 0 end

    local count = 0
    local rec = tpl:GetFirstRecord()
    while rec > 0 do
        local tId = tpl:GetRecordFieldValue(rec, "teamid")
        if tId == teamId then
            count = count + 1
        end
        rec = tpl:GetNextValidRecord()
    end
    return count
end

--------------------------------------------------------------------------------
-- 6) LEAGUE CONSTRAINTS: Return the min/max overall/potential for a league
--------------------------------------------------------------------------------
local function GetLeagueConstraints(leagueId)
    local c = league_constraints[leagueId]
    if c then
        return c.min_overall, c.max_overall, c.min_potential, c.max_potential
    end
    -- fallback to global
    return GLOBAL_MIN_OVERALL, GLOBAL_MAX_OVERALL, GLOBAL_MIN_POTENTIAL, GLOBAL_MAX_POTENTIAL
end

--------------------------------------------------------------------------------
-- 7) BUILD A LIST OF TEAMS + NEEDS => PRIORITY QUEUE
-- For each league in TARGET_LEAGUE_IDS, gather all teams, compute needs, build queue.
--------------------------------------------------------------------------------
local function GetAllTeamsAndNeeds()
    local leagueteamlinks = leagueteamlinks_global
    if not leagueteamlinks then
        return {}
    end

    local allEntries = {}
    local teamNeedsCache = {}

    -- Pre-cache league-team mapping
    local leagueTeams = {}
    local rec = leagueteamlinks:GetFirstRecord()
    while rec > 0 do
        local lgId = leagueteamlinks:GetRecordFieldValue(rec, "leagueid")
        local tmId = leagueteamlinks:GetRecordFieldValue(rec, "teamid")
        if lgId and tmId and not EXCLUDED_TEAM_IDS[tmId] then
            leagueTeams[lgId] = leagueTeams[lgId] or {}
            table.insert(leagueTeams[lgId], tmId)
        end
        rec = leagueteamlinks:GetNextValidRecord()
    end

    -- Process each league's teams
    for _, leagueId in ipairs(TARGET_LEAGUE_IDS) do
        local teams = leagueTeams[leagueId] or {}
        for _, tmId in ipairs(teams) do
            if not teamNeedsCache[tmId] then
                local teamSize = GetTeamSize(tmId)
                if teamSize < DESTINATION_MAX_SQUAD_SIZE then
                    teamNeedsCache[tmId] = ComputeTeamNeeds(tmId)
                else
                    teamNeedsCache[tmId] = {}
                    LOGGER:LogInfo(string.format("Team %d is full. Skipping all future needs.", tmId))
                end
            end

            for _, roleName in ipairs(teamNeedsCache[tmId]) do
                table.insert(allEntries, { teamId = tmId, role = roleName, leagueId = leagueId, weight = 10 })
            end
        end
    end

    table.sort(allEntries, function(a, b) return a.weight > b.weight end)
    return allEntries
end



--------------------------------------------------------------------------------
-- 8) BUILD LIST OF ELIGIBLE FREE AGENTS FOR EACH LEAGUE (or handle on the fly)
--    Create a global list of free agents that meet the age + league's constraints.
--    Then, we pick from that list whenever we have a need.
--------------------------------------------------------------------------------
-- Key: e.g. freeAgents[leagueId] = { {playerid=..., roleName=...} ... }
--------------------------------------------------------------------------------
local function initializeResults()
    local results = {}
    for _, lgId in ipairs(TARGET_LEAGUE_IDS) do
        results[lgId] = {}
    end
    return results
end

local function cachePlayerData(players_table)
    local playerData = {}
    local pRec = players_table:GetFirstRecord()

    while pRec > 0 do
        local playerId = players_table:GetRecordFieldValue(pRec, "playerid")
        if playerId then
            local overall = players_table:GetRecordFieldValue(pRec, "overallrating") or 
                            players_table:GetRecordFieldValue(pRec, "overall") or 0
            local potential = players_table:GetRecordFieldValue(pRec, "potential") or 0
            local birthdate = players_table:GetRecordFieldValue(pRec, "birthdate")
            local prefpos1 = players_table:GetRecordFieldValue(pRec, "preferredposition1")

            local roleName = prefpos1 and GetRoleNameFromPositionID(prefpos1) or nil
            if roleName then
                playerData[playerId] = {
                    overall = overall,
                    potential = potential,
                    birthdate = birthdate,
                    roleName = roleName
                }
            end
        end
        pRec = players_table:GetNextValidRecord()
    end

    return playerData
end

local function calculatePlayerAge(birthdate)
    if not birthdate or birthdate <= 0 then return 20 end -- Default age

    local cd = GetCurrentDate()
    local d = DATE:new()
    d:FromGregorianDays(birthdate)
    local age = cd.year - d.year
    if (cd.month < d.month) or (cd.month == d.month and cd.day < d.day) then
        age = age - 1
    end
    return age
end

local function filterFreeAgents(teamplayerlinks, playerData, results)
    local rec = teamplayerlinks:GetFirstRecord()

    while rec > 0 do
        local tid = teamplayerlinks:GetRecordFieldValue(rec, "teamid")
        local pid = teamplayerlinks:GetRecordFieldValue(rec, "playerid")

        if tid == FROM_TEAM_ID and playerData[pid] then
            local data = playerData[pid]
            local age = calculatePlayerAge(data.birthdate)

            if age >= MIN_AGE and age <= MAX_AGE then
                for _, lgId in ipairs(TARGET_LEAGUE_IDS) do
                    local minOvr, maxOvr, minPot, maxPot = GetLeagueConstraints(lgId)
                    if data.overall >= minOvr and data.overall <= maxOvr and
                       data.potential >= minPot and data.potential <= maxPot and
                       data.roleName then
                        table.insert(results[lgId], { playerid = pid, roleName = data.roleName })
                    end
                end
            end
        end

        rec = teamplayerlinks:GetNextValidRecord()
    end
end

local function shuffleFreeAgents(results)
    for _, lgId in ipairs(TARGET_LEAGUE_IDS) do
        local arr = results[lgId]
        for i = #arr, 2, -1 do
            local j = math.random(i)
            arr[i], arr[j] = arr[j], arr[i]
        end
    end
end

local function BuildFreeAgentsForLeagues()
    local results = initializeResults()

    local players_table = players_table_global
    local teamplayerlinks = teamplayerlinks_global

    if not players_table or not teamplayerlinks then
        return results
    end

    local playerData = cachePlayerData(players_table)
    filterFreeAgents(teamplayerlinks, playerData, results)
    shuffleFreeAgents(results)

    return results
end



--------------------------------------------------------------------------------
-- 9) ACTUAL TRANSFER MECHANISM
--------------------------------------------------------------------------------
-- Do a priority queue approach: pop from the big queue of (teamId, role) in random or
-- sorted order. Then find a free agent in that league who matches that role, transfer them.

local function findCandidate(faList, roleReq)
    for index, freeAgent in ipairs(faList) do
        if freeAgent.roleName == roleReq then
            return index
        end
    end
    return nil
end

local function updatePlayerRole(players_table, playerid, newRoleID)
    local record = players_table:GetFirstRecord()
    while record > 0 do
        local currentPlayerID = players_table:GetRecordFieldValue(record, "playerid")
        if currentPlayerID == playerid then
            players_table:SetRecordFieldValue(record, "preferredposition1", newRoleID)
            LOGGER:LogInfo(string.format("Updated player %d's preferred position to %d.", playerid, newRoleID))
            return
        end
        record = players_table:GetNextValidRecord()
    end
    LOGGER:LogWarning(string.format("Player record for ID %d not found. Could not update preferred position.", playerid))
end

local function handlePlayerTransfer(playerid, teamId, roleReq, leagueId, faList, candidateIndex, usedAlternative, altRoleUsed)
    local playerName = GetPlayerName(playerid)
    local ok, errMsg = pcall(function()
        if IsPlayerPresigned(playerid) then DeletePresignedContract(playerid) end
        if IsPlayerLoanedOut(playerid) then TerminateLoan(playerid) end

        TransferPlayer(playerid, teamId, TRANSFER_SUM, WAGE, CONTRACT_LENGTH, FROM_TEAM_ID, RELEASE_CLAUSE)
    end)

    if ok then
        LOGGER:LogInfo(string.format(
            "Transferred %s (%d) to team %s (%d) for role %s (league %d).",
            playerName, playerid, GetTeamName(teamId), teamId, roleReq, leagueId
        ))

        if usedAlternative then
            LOGGER:LogInfo(string.format("Used alternative position '%s' instead of '%s'.", altRoleUsed, roleReq))
            updatePlayerRole(players_table_global, playerid, GetRoleIDFromRoleName(roleReq))
        end

        table.remove(faList, candidateIndex)
        return true
    else
        LOGGER:LogWarning(string.format(
            "Failed to transfer player %s (%d) -> team %s (%d). Error: %s",
            playerName, playerid, GetTeamName(teamId), teamId, tostring(errMsg)
        ))
        return false
    end
end

local function findAlternativeCandidate(faList, roleReq)
    if not alternative_positions[roleReq] then return nil, false, nil end

    for _, altRole in ipairs(alternative_positions[roleReq]) do
        local candidateIndex = findCandidate(faList, altRole)
        if candidateIndex then
            return candidateIndex, true, altRole
        end
    end
    return nil, false, nil
end

local function processTeamEntry(entry, freeAgents)
    local teamId, roleReq, leagueId = entry.teamId, entry.role, entry.leagueId

    if GetTeamSize(teamId) >= DESTINATION_MAX_SQUAD_SIZE then
        LOGGER:LogInfo(string.format("Team %d is full. Skipping.", teamId))
        return false
    end

    local faList = freeAgents[leagueId]
    local candidateIndex = findCandidate(faList, roleReq)
    local usedAlternative, altRoleUsed = false, nil

    if not candidateIndex then
        candidateIndex, usedAlternative, altRoleUsed = findAlternativeCandidate(faList, roleReq)
    end

    if candidateIndex then
        local playerid = faList[candidateIndex].playerid
        return handlePlayerTransfer(playerid, teamId, roleReq, leagueId, faList, candidateIndex, usedAlternative, altRoleUsed)
    else
        LOGGER:LogInfo(string.format(
            "No free agent found for role '%s' or alternatives in league %d.",
            roleReq, leagueId
        ))
        return false
    end
end

local function DoTransfers()
    local bigQueue = GetAllTeamsAndNeeds()
    if #bigQueue == 0 then
        MessageBox("No Team Needs", "No teams found with missing roles. Done.")
        return
    end

    local freeAgents = BuildFreeAgentsForLeagues()
    local players_table = players_table_global
    if not players_table then
        LOGGER:LogError("Players table not initialized. Aborting transfers.")
        return
    end

    local totalTransfers = 0

    for _, entry in ipairs(bigQueue) do
        local success = processTeamEntry(entry, freeAgents)
        if success then
            totalTransfers = totalTransfers + 1
        end
    end

    MessageBox("Transfers Done", string.format(
        "Processed %d needs in priority queue. Total successful transfers: %d",
        #bigQueue, totalTransfers
    ))
end



--------------------------------------------------------------------------------
-- 10) MAIN SCRIPT
--------------------------------------------------------------------------------

math.randomseed(os.time())
LOGGER:LogInfo("Starting Multi-League Transfer Script...")

DoTransfers()
