--------------------------------------------------------------------------------
-- Lua Script for Multi-League Player Transfers
-- with Position IDs Mapping, Priority Queue, and League-Specific Constraints
--------------------------------------------------------------------------------

require 'imports/career_mode/helpers'
require 'imports/other/helpers'
local logger = require("logger")

local teamplayerlinks_global = LE.db:GetTable("teamplayerlinks")
local players_table_global   = LE.db:GetTable("players")
local formations_table_global = LE.db:GetTable("formations")
local leagueteamlinks_global = LE.db:GetTable("leagueteamlinks")

--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------

-- Position IDs: updated mapping
local position_ids = {
    GK = {0},                          -- Primary: 0
    CB = {5, 1, 4, 6},                 -- Primary: 5
    RB = {3, 2},                       -- Primary: 3
    LB = {7, 8},                       -- Primary: 7
    CDM = {10, 9, 11},                 -- Primary: 10
    RM = {12},                         -- Primary: 12
    CM = {14, 13, 15},                 -- Primary: 14
    LM = {16},                         -- Primary: 16
    CAM = {18, 17, 19},                -- Primary: 18
    ST = {25, 20, 21, 22, 24, 26},     -- Primary: 25
    RW = {23},                         -- Primary: 23
    LW = {27}                          -- Primary: 27
}

--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------

local config = {
    position_ids = {
        GK = {0}, CB = {5, 1, 4, 6}, RB = {3, 2}, LB = {7, 8},
        CDM = {10, 9, 11}, RM = {12}, CM = {14, 13, 15}, LM = {16},
        CAM = {18, 17, 19}, ST = {25, 20, 21, 22, 24, 26},
        RW = {23}, LW = {27}
    },
    positionToGroup = {
        GK = "goalkeeper",
        RB = "defence", CB = "defence", LB = "defence",
        LM = "midfield", CM = "midfield", CDM = "midfield", RM = "midfield",
        CAM = "attacker", ST = "attacker", RW = "attacker", LW = "attacker"
    },
    alternative_positions = {
        RW = {"RM"}, LW = {"LM"}, ST = {"RW", "LW"},
        CDM = {"CM"}, CAM = {"RW", "LW"}
    },
    league_constraints = setmetatable({
        [61] = {min_overall = 58, max_overall = 64, min_potential = 65, max_potential = 99},
        [60] = {min_overall = 65, max_overall = 69, min_potential = 65, max_potential = 99},
        [14] = {min_overall = 70, max_overall = 74, min_potential = 70, max_potential = 99},
        [13] = {min_overall = 74, max_overall = 99, min_potential = 74, max_potential = 99}
    }, { __index = function()
        return {min_overall = 55, max_overall = 90, min_potential = 55, max_potential = 99}
    end }),
    age_constraints = {min = 16, max = 35},
    squad_size = 52,
    target_leagues = {61, 60, 14},
    excluded_teams = {}, -- Example: { [12345] = true }
    transfer = {
        sum = 0,
        wage = 600,
        contract_length = 60,
        release_clause = -1,
        from_team_id = 111592
    }
}
-- Call the logger function
logger.logConfigSummary(config)

--------------------------------------------------------------------------------
-- HELPER FUNCTIONS
--------------------------------------------------------------------------------
local function GetRoleIDFromRoleName(roleReq)
    return (position_ids[roleReq] or {})[1]
end

-- Map Position ID to Role Name
local positionNameByID = {}
for roleName, idList in pairs(position_ids) do
    for _, pid in ipairs(idList) do
        positionNameByID[pid] = roleName
    end
end

local function GetRoleNameFromPositionID(posID)
    return positionNameByID[posID] or ("UnknownPos(".. tostring(posID) ..")")
end

-- Compute Age from Birthdate
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


--------------------------------------------------------------------------------
-- FORMATION LOGIC: Retrieve each team's formation positions
--------------------------------------------------------------------------------
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
-- COUNT HOW MANY PLAYERS PER ROLE A TEAM HAS
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
-- TEAM NEEDS - Attempts to have 2 for every position in team's formation
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
-- GETTEAMSIZE
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
-- BUILD A LIST OF TEAMS + NEEDS => PRIORITY QUEUE
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
        if lgId and tmId and not config.excluded_teams[tmId] then
            leagueTeams[lgId] = leagueTeams[lgId] or {}
            table.insert(leagueTeams[lgId], tmId)
        end
        rec = leagueteamlinks:GetNextValidRecord()
    end

    -- Process each league's teams
    for _, leagueId in ipairs(config.target_leagues) do
        local teams = leagueTeams[leagueId] or {}
        for _, tmId in ipairs(teams) do
            if not teamNeedsCache[tmId] then
                local teamSize = GetTeamSize(tmId)
                if teamSize < config.squad_size then
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
-- BUILD LIST OF ELIGIBLE FREE AGENTS FOR EACH LEAGUE
--------------------------------------------------------------------------------

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

local function filterFreeAgents(teamplayerlinks, playerData, results)
    local rec = teamplayerlinks:GetFirstRecord()

    while rec > 0 do
        local tid = teamplayerlinks:GetRecordFieldValue(rec, "teamid")
        local pid = teamplayerlinks:GetRecordFieldValue(rec, "playerid")

        if tid == config.transfer.from_team_id and playerData[pid] then
            local data = playerData[pid]
            local age = calculatePlayerAge(data.birthdate)

            if age >= config.age_constraints.min and age <= config.age_constraints.max then
                for _, lgId in ipairs(config.target_leagues) do
                    local constraints = config.league_constraints[lgId]
                    local minOvr, maxOvr, minPot, maxPot = constraints.min_overall, constraints.max_overall, constraints.min_potential, constraints.max_potential
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
    for _, lgId in ipairs(config.target_leagues) do
        local arr = results[lgId]
        for i = #arr, 2, -1 do
            local j = math.random(i)
            arr[i], arr[j] = arr[j], arr[i]
        end
    end
end

local function BuildFreeAgentsForLeagues()
    local results = {}
    for _, lgId in ipairs(config.target_leagues) do
        results[lgId] = {}
    end

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
-- ACTUAL TRANSFER MECHANISM
--------------------------------------------------------------------------------
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

        TransferPlayer(playerid, teamId, config.transfer.sum, config.transfer.wage, config.transfer.contract_length, config.transfer.from_team_id, config.transfer.release_clause)
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
    local alternatives = config.alternative_positions[roleReq]
    if not alternatives then return nil, false, nil end

    for _, altRole in ipairs(alternatives) do
        local candidateIndex = findCandidate(faList, altRole)
        if candidateIndex then
            return candidateIndex, true, altRole
        end
    end
    return nil, false, nil
end


local function processTeamEntry(entry, freeAgents)
    local teamId, roleReq, leagueId = entry.teamId, entry.role, entry.leagueId

    if GetTeamSize(teamId) >= config.squad_size then
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
-- MAIN SCRIPT
--------------------------------------------------------------------------------

math.randomseed(os.time())
LOGGER:LogInfo("Starting Multi-League Transfer Script...")

DoTransfers()