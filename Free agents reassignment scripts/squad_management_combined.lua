--------------------------------------------------------------------------------
-- Combined Squad Management Script - Made By The Mayo Man (themayonnaiseman)
--
-- Runs the three-phase pipeline in one pass:
--   1) RELEASE   - prune excess players, convert off-formation players, protect
--                  high-potential youth, cover empty formation slots.
--   2) TRANSFER  - sign free agents into teams with specific positional shortages
--                  using the configurable search_order (exact -> alt -> widen -> youth).
--   3) FILL      - top up teams toward a target squad size using position-group
--                  balancing, formation matching, and a youth development pathway.
--
-- Any phase can be disabled via CONFIG.phases.{release,transfer,fill}=false.
-- Behavior of each phase matches the standalone scripts; what's new here is a
-- single shared cache layer so the underlying DB tables are scanned once total
-- instead of 3-5 times across scripts.
--------------------------------------------------------------------------------
require 'imports/career_mode/helpers'
require 'imports/other/helpers'

--------------------------------------------------------------------------------
-- DATABASE TABLES
--------------------------------------------------------------------------------
local players_table         = LE.db:GetTable("players")
local team_player_links     = LE.db:GetTable("teamplayerlinks")
local formations_table      = LE.db:GetTable("formations")
local league_team_links     = LE.db:GetTable("leagueteamlinks")
local playerloans_table     = LE.db:GetTable("playerloans")

--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------
local CONFIG = {
    ----------------------------------------------------------------------------
    -- Phase toggles: set any to false to skip that phase entirely.
    ----------------------------------------------------------------------------
    phases = {
        release  = true,
        transfer = true,
        upgrade  = true,
        fill     = true
    },

    ----------------------------------------------------------------------------
    -- Shared settings used by multiple phases.
    ----------------------------------------------------------------------------
    shared = {
        -- Leagues whose teams are processed by every phase.
        target_leagues = {61,60,14,13,16,17,19,20,2076,31,32,10,83,53,54,353,351,80,4,2012,1,2149,41,66,308,65,330,350,50,56,189,68,39},
        -- Teams to permanently exclude (e.g. reserve/placeholder teams).
        excluded_teams = { [1952] = true },
        -- Source team ID that holds the free agent pool (transfer + fill source).
        -- Never treat this as a normal club: it must be excluded from league
        -- team lists or TransferPlayer(…, 111592, …, 111592) will fail.
        source_team_id = 111592,

        -- Position ID -> name mapping (DB stores numeric IDs).
        position_ids = {
            GK = {0}, CB = {5, 1, 4, 6}, RB = {3, 2}, LB = {7, 8},
            CDM = {10, 9, 11}, RM = {12}, CM = {14, 13, 15}, LM = {16},
            CAM = {18, 17, 19}, ST = {25, 20, 21, 22, 24, 26},
            RW = {23}, LW = {27}
        },

        -- Role IDs per position (role1, role2, role3). Set when we convert a
        -- player's preferred position so the game doesn't keep stale roles.
        positions_to_roles = {
            GK  = {1, 2, 0},    CB  = {11, 12, 13}, RB  = {3, 4, 5},    LB  = {7, 8, 9},
            CDM = {14, 15, 16}, RM  = {23, 24, 26}, CM  = {18, 19, 20}, LM  = {27, 28, 30},
            CAM = {31, 32, 33}, ST  = {41, 42, 43}, RW  = {35, 36, 37}, LW  = {38, 39, 40}
        }
    },

    ----------------------------------------------------------------------------
    -- RELEASE phase settings (matches release_unrequired_players.lua).
    ----------------------------------------------------------------------------
    release = {
        -- Position swaps allowed when converting players not in formation.
        alternative_positions = {
            RW = {"RM"}, LW = {"LM"}, ST = {"RW","LW"},
            CDM = {"CM"}, CAM = {"RW","LW"}, CM = {"CDM","CAM"}
        },
        multiplier = 3,                 -- Cap per position = formation_count * multiplier

        -- Youth development
        protect_youth               = true,
        youth_max_age               = 23,
        youth_potential_bonus       = 3,   -- Must have potential >= team_median + this
        youth_potential_cap         = 85,  -- Hard cap on median+bonus threshold
        youth_max_protected_per_pos = 1,

        -- Process control
        convert_non_formation_players = true,
        release_non_formation_players = true,
        prune_excess_players          = true,

        -- Hole-filling safety net: convert a to-be-released player to fill an
        -- empty formation slot instead of releasing, if positions are related.
        min_keep_per_formation_pos = 1,
        cover_bonus_per_pos        = 1,

        -- Save progress every N teams (supports resuming long runs).
        batch_size = 20
    },

    ----------------------------------------------------------------------------
    -- TRANSFER phase settings (matches free_agents_transfer_to_league.lua).
    ----------------------------------------------------------------------------
    transfer = {
        alternative_positions = {
            RW = {"RM"}, LW = {"LM"}, ST = {"RW", "LW"},
            CDM = {"CM"}, CAM = {"RW", "LW"}
        },
        age_constraints = {min = 16, max = 33},
        squad_size = 52,                 -- Hard cap; don't push teams above this
        transfer_terms = {
            sum = 0, wage = 600, contract_length = 24, release_clause = -1
        },
        -- Rating band for "suitable" free agents: [median - minus, p75 + plus].
        lower_bound_minus = 2,
        upper_bound_plus  = 3,
        -- Youth protection threshold for accepting youth prospects out-of-band.
        youth_player = {
            max_age         = 23,
            potential_bonus = 5,
            use_median      = true,
            potential_cap   = 85
        },
        max_widen_steps = 2,
        widen_step_size = 2,
        -- Strategies tried per slot, in order. See find_best_candidate_for_slot
        -- for details on each entry.
        search_order = { "exact", "alt", "widen_one", "youth", "widen_full" },
        critical_position_bonus   = { GK = 50 },
        requeue_every_n_transfers = 50
    },

    ----------------------------------------------------------------------------
    -- UPGRADE phase settings (matches upgrade_team.lua behaviour).
    -- Runs after transfer and before fill. For each formation position whose
    -- best player is far below team median, signs an FA in [median, median+plus]
    -- and optionally releases the worst players at that position.
    ----------------------------------------------------------------------------
    upgrade = {
        -- Positions need upgrading when best_player_ovr <= team_median - this.
        -- 0 means "best player is at or below median" (aggressive); increase
        -- (e.g. 2 or 3) to only upgrade when the gap is significant.
        median_minus_threshold  = 0,
        -- FA rating band: [team_median, team_median + this].
        median_plus_threshold   = 5,
        max_age_for_signing     = 30,
        squad_size              = 52,

        -- Release the worst excess players at the upgraded position right
        -- after signing so squad_size doesn't balloon across upgrades.
        cleanup_after_upgrade   = true,
        cleanup_keep_count      = 3,

        -- Youth protection for cleanup pass (same semantics as release phase).
        protect_youth           = true,
        youth_max_age           = 23,
        youth_potential_bonus   = 2,
        youth_potential_cap     = 85,

        transfer_terms = {
            sum = 0, wage = 600, contract_length = 60, release_clause = -1
        }
    },

    ----------------------------------------------------------------------------
    -- FILL phase settings (matches simplified_squad_filler.lua).
    ----------------------------------------------------------------------------
    fill = {
        age_constraints    = {min = 16, max = 35},
        max_squad_size     = 52,
        target_squad_size  = 27,
        rating_variance    = {lower_bound_minus = 2, upper_bound_plus = 1},
        youth_thresholds   = {max_age = 23, potential_bonus = 5, potential_cap = 85},
        transfer_terms     = {sum = 0, wage = 600, contract_length = 24, release_clause = -1},
        max_widen_steps    = 2,
        widen_step_size    = 2,
        -- Strategic position groups with target ratios (total = 8 parts).
        position_groups = {
            definitions = {
                GK = {"GK"}, DEF = {"CB", "LB", "RB"}, MID = {"CM", "CDM"},
                AM = {"RM", "LM", "RW", "LW", "CAM"}, ST = {"ST"}
            },
            ratios = { GK = 1, DEF = 2, MID = 2, AM = 2, ST = 1 }
        }
    }
}

--==============================================================================
-- SHARED INFRASTRUCTURE
-- Single-pass caches reused across all phases.
--==============================================================================

--------------------------------------------------------------------------------
-- Position name <-> ID mapping (derived from CONFIG.shared.position_ids).
--------------------------------------------------------------------------------
local position_name_by_id = {}
local position_id_by_name = {}
for name, ids in pairs(CONFIG.shared.position_ids) do
    position_id_by_name[name] = ids[1]
    for _, pid in ipairs(ids) do
        position_name_by_id[pid] = name
    end
end

local function pos_name_from_id(pid)
    return position_name_by_id[pid] or ("UnknownPos(".. tostring(pid) ..")")
end

local function pos_id_from_name(name)
    return position_id_by_name[name] or -1
end

--------------------------------------------------------------------------------
-- Age calculation from birthdate (game stores Gregorian days).
--------------------------------------------------------------------------------
local function calculate_age(birth_date, default)
    if not birth_date or birth_date <= 0 then return default or 20 end
    local c = GetCurrentDate()
    local d = DATE:new(); d:FromGregorianDays(birth_date)
    local age = c.year - d.year
    if c.month < d.month or (c.month == d.month and c.day < d.day) then
        age = age - 1
    end
    return age
end

--------------------------------------------------------------------------------
-- Shared player cache: one scan of the players table for all phases.
-- Fields mirror what each individual phase needs, plus the record_id so we can
-- write back to the player row without a second linear scan.
--------------------------------------------------------------------------------
local player_cache = {}

local function build_player_cache()
    if next(player_cache) ~= nil then return end
    if not players_table then
        LOGGER:LogWarning("Players table not found.")
        return
    end

    LOGGER:LogInfo("Building shared player cache...")
    local start_time = os.time()
    local count = 0

    local rec = players_table:GetFirstRecord()
    while rec > 0 do
        local pid = players_table:GetRecordFieldValue(rec, "playerid")
        if pid then
            local birthdate = players_table:GetRecordFieldValue(rec, "birthdate")
            local pref_pos  = players_table:GetRecordFieldValue(rec, "preferredposition1")
            player_cache[pid] = {
                record_id         = rec,
                preferredposition1 = pref_pos,
                positionName      = pref_pos and pos_name_from_id(pref_pos) or nil,
                overall           = players_table:GetRecordFieldValue(rec, "overallrating")
                                    or players_table:GetRecordFieldValue(rec, "overall") or 0,
                potential         = players_table:GetRecordFieldValue(rec, "potential") or 0,
                birthdate         = birthdate,
                age               = calculate_age(birthdate, 30)
            }
            count = count + 1
            if count % 10000 == 0 then
                LOGGER:LogInfo(string.format("Indexed %d players so far...", count))
            end
        end
        rec = players_table:GetNextValidRecord()
    end

    LOGGER:LogInfo(string.format(
        "Player cache: %d players in %ds.", count, os.time() - start_time
    ))
end

--------------------------------------------------------------------------------
-- Shared team->players map: one scan of teamplayerlinks. Kept in sync by the
-- release/transfer phases when they move or remove players.
--------------------------------------------------------------------------------
local team_players_map = nil

local function build_team_players_map()
    if team_players_map then return team_players_map end
    LOGGER:LogInfo("Building team-players map...")
    team_players_map = {}
    if not team_player_links then return team_players_map end

    local start_time = os.time()
    local count = 0
    local rec = team_player_links:GetFirstRecord()
    while rec > 0 do
        local t_id = team_player_links:GetRecordFieldValue(rec, "teamid")
        local p_id = team_player_links:GetRecordFieldValue(rec, "playerid")
        if t_id and p_id then
            local bucket = team_players_map[t_id]
            if not bucket then
                bucket = {}
                team_players_map[t_id] = bucket
            end
            bucket[#bucket + 1] = p_id
            count = count + 1
        end
        rec = team_player_links:GetNextValidRecord()
    end
    LOGGER:LogInfo(string.format(
        "Team-players map: %d links in %ds.", count, os.time() - start_time
    ))
    return team_players_map
end

-- Helpers to keep team_players_map in sync with DB mutations.
local function team_roster_add(team_id, player_id)
    if not team_players_map then return end
    local bucket = team_players_map[team_id]
    if not bucket then
        bucket = {}
        team_players_map[team_id] = bucket
    end
    bucket[#bucket + 1] = player_id
end

local function team_roster_remove(team_id, player_id)
    if not team_players_map then return end
    local bucket = team_players_map[team_id]
    if not bucket then return end
    for i = 1, #bucket do
        if bucket[i] == player_id then
            bucket[i] = bucket[#bucket]
            bucket[#bucket] = nil
            return
        end
    end
end

--------------------------------------------------------------------------------
-- Shared formations map: team_id -> { posName_slot0, posName_slot1, ... }.
-- Includes GK slot; phases filter it out as needed.
--------------------------------------------------------------------------------
local formations_map = nil

local function build_formations_map()
    if formations_map then return formations_map end
    formations_map = {}
    if not formations_table then return formations_map end

    local rec = formations_table:GetFirstRecord()
    while rec > 0 do
        local t_id = formations_table:GetRecordFieldValue(rec, "teamid")
        if t_id then
            local positions = {}
            for i = 0, 10 do
                local pid = formations_table:GetRecordFieldValue(rec, ("position%d"):format(i)) or 0
                positions[#positions + 1] = pos_name_from_id(pid)
            end
            formations_map[t_id] = positions
        end
        rec = formations_table:GetNextValidRecord()
    end
    return formations_map
end

local function get_formation_positions(team_id)
    build_formations_map()
    return formations_map[team_id] or {}
end

--------------------------------------------------------------------------------
-- Shared league->teams map: one scan of leagueteamlinks, honoring excluded_teams.
--------------------------------------------------------------------------------
local league_team_map = nil

-- Free-agent pool (source_team_id) must never be processed as a destination club;
-- it can appear in leagueteamlinks and would cause TransferPlayer(111592->111592).
local function is_team_excluded_from_processing(t_id)
    if not t_id then return true end
    if CONFIG.shared.excluded_teams[t_id] then return true end
    if t_id == CONFIG.shared.source_team_id then return true end
    return false
end

local function build_league_team_map()
    if league_team_map then return league_team_map end
    league_team_map = {}
    if not league_team_links then return league_team_map end

    local rec = league_team_links:GetFirstRecord()
    while rec > 0 do
        local league_id = league_team_links:GetRecordFieldValue(rec, "leagueid")
        local t_id      = league_team_links:GetRecordFieldValue(rec, "teamid")
        if league_id and t_id and not is_team_excluded_from_processing(t_id) then
            league_team_map[league_id] = league_team_map[league_id] or {}
            local bucket = league_team_map[league_id]
            bucket[#bucket + 1] = t_id
        end
        rec = league_team_links:GetNextValidRecord()
    end
    return league_team_map
end

-- Build an ordered list of eligible team IDs from the target leagues.
local function build_target_team_pool()
    local pool = {}
    build_league_team_map()
    for _, league_id in ipairs(CONFIG.shared.target_leagues) do
        for _, t_id in ipairs(league_team_map[league_id] or {}) do
            pool[#pool + 1] = t_id
        end
    end
    return pool
end

--------------------------------------------------------------------------------
-- Loan index (only needed when release phase runs).
--------------------------------------------------------------------------------
local loaned_players = {}
local loan_index_built = false

local function build_loan_index()
    if loan_index_built then return end
    loan_index_built = true
    if not playerloans_table then
        LOGGER:LogWarning("No playerloans table found.")
        return
    end

    local count = 0
    local rec = playerloans_table:GetFirstRecord()
    while rec > 0 do
        local p_id = playerloans_table:GetRecordFieldValue(rec, "playerid")
        local from_team = playerloans_table:GetRecordFieldValue(rec, "teamidloanedfrom")
        if p_id and from_team then
            loaned_players[p_id] = from_team
            count = count + 1
        end
        rec = playerloans_table:GetNextValidRecord()
    end
    LOGGER:LogInfo(string.format("Loan index: %d loaned players.", count))
end

--------------------------------------------------------------------------------
-- Shared name caches so GetTeamName / GetPlayerName only run once per id.
--------------------------------------------------------------------------------
local team_name_cache   = {}
local player_name_cache = {}

local function get_team_name_cached(team_id)
    local name = team_name_cache[team_id]
    if name ~= nil then return name end
    name = GetTeamName(team_id) or tostring(team_id)
    team_name_cache[team_id] = name
    return name
end

local function get_player_name_cached(player_id)
    local name = player_name_cache[player_id]
    if name ~= nil then return name end
    name = GetPlayerName(player_id) or tostring(player_id)
    player_name_cache[player_id] = name
    return name
end

--------------------------------------------------------------------------------
-- Shared record-level writers. Keep the shared player_cache consistent with any
-- DB writes so later phases see correct values.
--------------------------------------------------------------------------------
local function write_player_position_and_roles(player_id, new_pos_name)
    local pdata = player_cache[player_id]
    if not pdata then
        LOGGER:LogWarning(string.format("Player %d not in cache; skip pos/role update.", player_id))
        return false
    end

    local new_pos_id = pos_id_from_name(new_pos_name)
    local rec = pdata.record_id
    local old = players_table:GetRecordFieldValue(rec, "preferredposition1")
    local pos2 = players_table:GetRecordFieldValue(rec, "preferredposition2")
    local pos3 = players_table:GetRecordFieldValue(rec, "preferredposition3")

    players_table:SetRecordFieldValue(rec, "preferredposition1", new_pos_id)
    pdata.preferredposition1 = new_pos_id
    pdata.positionName       = new_pos_name

    if new_pos_id == 0 then
        players_table:SetRecordFieldValue(rec, "preferredposition2", -1)
        players_table:SetRecordFieldValue(rec, "preferredposition3", -1)
    else
        if pos2 == new_pos_id then
            players_table:SetRecordFieldValue(rec, "preferredposition2", old)
        end
        if pos3 == new_pos_id then
            players_table:SetRecordFieldValue(rec, "preferredposition3", old)
        end
    end

    local roles = CONFIG.shared.positions_to_roles[new_pos_name]
    if roles then
        local r1, r2, r3 = roles[1], roles[2], roles[3]
        if new_pos_id == 0 then r3 = 0 end
        players_table:SetRecordFieldValue(rec, "role1", r1)
        players_table:SetRecordFieldValue(rec, "role2", r2)
        players_table:SetRecordFieldValue(rec, "role3", r3)
    end

    return true
end

--==============================================================================
-- RELEASE PHASE
--==============================================================================
local release_phase = {}

-- Bidirectional cover map derived from alternative_positions:
-- cover_map[Y][X] = true means a player with preferred X can cover slot Y.
local release_cover_map = {}
for from_pos, to_list in pairs(CONFIG.release.alternative_positions) do
    for _, to_pos in ipairs(to_list) do
        release_cover_map[to_pos] = release_cover_map[to_pos] or {}
        release_cover_map[to_pos][from_pos] = true
        release_cover_map[from_pos] = release_cover_map[from_pos] or {}
        release_cover_map[from_pos][to_pos] = true
    end
end

-- Per-run state ------------------------------------------------------------
local release_team_player_cache = {}  -- team_id -> players list (invalidated on changes)
local release_team_median_cache = {}
local release_teams_processed   = {}
local release_run_stats = {
    teams_processed   = 0,
    teams_skipped     = 0,
    conversions       = 0,
    cover_conversions = 0,
    releases_step3    = 0,
    releases_step4    = 0,
    youth_protected   = 0,
    youth_released    = 0
}

local function release_invalidate_team_cache(team_id)
    release_team_player_cache[team_id] = nil
    release_team_median_cache[team_id] = nil
end

-- Get this team's roster (excluding players loaned OUT, since they can't be
-- released/converted on the loaning team).
local function release_get_team_players(team_id)
    local cached = release_team_player_cache[team_id]
    if cached then return cached end

    build_team_players_map()
    local players = {}
    local ids = team_players_map[team_id]
    if ids then
        for _, p_id in ipairs(ids) do
            if loaned_players[p_id] ~= team_id then
                local pc = player_cache[p_id]
                if pc then
                    players[#players + 1] = {
                        id        = p_id,
                        posName   = pc.positionName or pos_name_from_id(pc.preferredposition1 or -1),
                        overall   = pc.overall,
                        potential = pc.potential,
                        age       = pc.age
                    }
                end
            end
        end
    end
    release_team_player_cache[team_id] = players
    return players
end

local function release_team_median_rating(team_id)
    local cached = release_team_median_cache[team_id]
    if cached then return cached end

    local players = release_get_team_players(team_id)
    if #players == 0 then return 65 end

    local ratings = {}
    for _, p in ipairs(players) do ratings[#ratings + 1] = p.overall end
    table.sort(ratings)
    local median
    if #ratings % 2 == 0 then
        median = (ratings[#ratings / 2] + ratings[#ratings / 2 + 1]) / 2
    else
        median = ratings[math.ceil(#ratings / 2)]
    end
    median = math.floor(median + 0.5)
    release_team_median_cache[team_id] = median
    return median
end

local function release_is_high_potential_youth(player, median_rating)
    local cfg = CONFIG.release
    if not cfg.protect_youth then return false end
    if player.age > cfg.youth_max_age then return false end

    local threshold = median_rating + cfg.youth_potential_bonus
    local cap = cfg.youth_potential_cap
    if cap and threshold > cap then threshold = cap end
    return player.potential >= threshold
end

-- Step 2: try converting a non-formation player into an alt formation slot.
local function release_try_convert(player_id, old_pos, formation_set, team_id)
    if loaned_players[player_id] then return false end
    local alts = CONFIG.release.alternative_positions[old_pos]
    if not alts then return false end

    for _, alt_pos in ipairs(alts) do
        if formation_set[alt_pos] then
            if write_player_position_and_roles(player_id, alt_pos) then
                LOGGER:LogInfo(string.format(
                    "Converted %d: %s -> %s.", player_id, old_pos, alt_pos
                ))
                release_invalidate_team_cache(team_id)
                return true
            end
        end
    end
    return false
end

-- Step 3 pre-release: if a player about to be released can fill a slot that's
-- below min_keep_per_formation_pos (via the bidirectional cover map), convert
-- them instead of releasing.
local function release_try_cover_slot(player_id, old_pos, formation_set, have, team_id)
    if loaned_players[player_id] then return false end
    local min_keep = CONFIG.release.min_keep_per_formation_pos or 1
    local candidates = release_cover_map[old_pos]
    if not candidates then return false end

    local empties = {}
    for form_pos in pairs(formation_set) do
        if candidates[form_pos] and (have[form_pos] or 0) < min_keep then
            empties[#empties + 1] = form_pos
        end
    end
    if #empties == 0 then return false end

    table.sort(empties, function(a, b) return (have[a] or 0) < (have[b] or 0) end)
    local target = empties[1]
    if not write_player_position_and_roles(player_id, target) then return false end

    LOGGER:LogInfo(string.format(
        "Cover-converted %d: %s -> %s (slot had %d, min %d).",
        player_id, old_pos, target, have[target] or 0, min_keep
    ))
    have[target] = (have[target] or 0) + 1
    release_invalidate_team_cache(team_id)
    return true
end

local function release_release_player(player_id, team_id, reason)
    if loaned_players[player_id] then return false end

    local ok = pcall(function() ReleasePlayerFromTeam(player_id) end)
    if ok then
        local pc = player_cache[player_id]
        local pos_label = (pc and pos_name_from_id(pc.preferredposition1 or -1)) or "?"
        local ovr = (pc and pc.overall) or 0
        LOGGER:LogInfo(string.format(
            "Released %s (%d, %s, OVR %d) from %s (%d). [%s]",
            get_player_name_cached(player_id), player_id, pos_label, ovr,
            get_team_name_cached(team_id), team_id, reason or "unspecified"
        ))
        team_roster_remove(team_id, player_id)
        -- Released players go to the free agent pool; keep shared cache in
        -- sync so the transfer/fill phases can find them.
        team_roster_add(CONFIG.shared.source_team_id, player_id)
        release_invalidate_team_cache(team_id)
        return true
    end
    LOGGER:LogWarning(string.format("Failed to release player %d from team %d", player_id, team_id))
    return false
end

-- Process one team: convert -> cover/release -> prune excess with youth protection.
local function release_process_team(team_id)
    if release_teams_processed[team_id] then return end

    local team_name = get_team_name_cached(team_id)
    LOGGER:LogInfo(string.format("Processing team %s (%d)...", team_name, team_id))
    local start_time = os.time()

    local formation_positions = get_formation_positions(team_id)
    if #formation_positions == 0 then
        LOGGER:LogInfo(string.format("No formation for %s. Skipping.", team_name))
        release_teams_processed[team_id] = true
        release_run_stats.teams_skipped = release_run_stats.teams_skipped + 1
        return
    end

    local formation_set, formation_count = {}, {}
    for _, p in ipairs(formation_positions) do
        formation_set[p] = true
        formation_count[p] = (formation_count[p] or 0) + 1
    end

    -- Diagnostic: dump the formation the script actually sees for this team.
    local fcount_parts = {}
    for pos, c in pairs(formation_count) do
        fcount_parts[#fcount_parts + 1] = string.format("%s x%d", pos, c)
    end
    table.sort(fcount_parts)
    LOGGER:LogInfo(string.format(
        "  Formation(%s): [%s] -> %s",
        team_name, table.concat(formation_positions, ","), table.concat(fcount_parts, ", ")
    ))

    local median_rating = release_team_median_rating(team_id)

    -- Step 2: convert non-formation players.
    local players = release_get_team_players(team_id)
    local conversions = 0
    if CONFIG.release.convert_non_formation_players then
        local to_convert = {}
        for _, p in ipairs(players) do
            if not formation_set[p.posName] then
                to_convert[#to_convert + 1] = p
            end
        end
        for _, p in ipairs(to_convert) do
            if release_try_convert(p.id, p.posName, formation_set, team_id) then
                conversions = conversions + 1
            end
        end
        if conversions > 0 then
            LOGGER:LogInfo(string.format("Step 2: converted %d to formation positions.", conversions))
        end
        release_run_stats.conversions = release_run_stats.conversions + conversions
    else
        LOGGER:LogInfo("Position conversion disabled.")
    end

    -- Step 3: cover-convert or release leftover non-formation players.
    local releases_step3, cover_convs = 0, 0
    if CONFIG.release.release_non_formation_players then
        release_invalidate_team_cache(team_id)
        players = release_get_team_players(team_id)

        local have = {}
        for _, p in ipairs(players) do
            if formation_set[p.posName] then
                have[p.posName] = (have[p.posName] or 0) + 1
            end
        end

        local to_release = {}
        for _, p in ipairs(players) do
            if not formation_set[p.posName] then
                to_release[#to_release + 1] = p
            end
        end
        -- Best-rated non-formation players get the cover-convert priority.
        table.sort(to_release, function(a, b) return a.overall > b.overall end)

        for _, p in ipairs(to_release) do
            if release_try_cover_slot(p.id, p.posName, formation_set, have, team_id) then
                cover_convs = cover_convs + 1
            else
                local reason = string.format("step3 non-formation %s (formation: %s)",
                    p.posName, table.concat(formation_positions, ","))
                if release_release_player(p.id, team_id, reason) then
                    releases_step3 = releases_step3 + 1
                end
            end
        end
        if cover_convs > 0 or releases_step3 > 0 then
            LOGGER:LogInfo(string.format(
                "Step 3: cover-converted %d, released %d (non-formation).",
                cover_convs, releases_step3
            ))
        end
        release_run_stats.cover_conversions = release_run_stats.cover_conversions + cover_convs
        release_run_stats.releases_step3    = release_run_stats.releases_step3 + releases_step3
    else
        LOGGER:LogInfo("Non-formation release disabled.")
    end

    -- Step 4: prune excess players per position with youth protection.
    local releases_step4 = 0
    if CONFIG.release.prune_excess_players then
        release_invalidate_team_cache(team_id)
        players = release_get_team_players(team_id)

        local grouped = {}
        for _, p in ipairs(players) do
            grouped[p.posName] = grouped[p.posName] or {}
            grouped[p.posName][#grouped[p.posName] + 1] = p
        end

        for pos_name, arr in pairs(grouped) do
            local demand = formation_count[pos_name] or 0
            if demand > 0 then
                local min_keep = math.max(
                    demand + (CONFIG.release.cover_bonus_per_pos or 0),
                    CONFIG.release.min_keep_per_formation_pos or 1
                )
                local cap = math.max(demand * CONFIG.release.multiplier, min_keep)

                if #arr > cap then
                    -- Primary: OVR desc. Secondary: potential desc. Tertiary: age asc.
                    -- This makes ties deterministic and prefers the player with
                    -- more upside when OVRs match, instead of insertion order.
                    table.sort(arr, function(a, b)
                        if a.overall ~= b.overall then return a.overall > b.overall end
                        if (a.potential or 0) ~= (b.potential or 0) then
                            return (a.potential or 0) > (b.potential or 0)
                        end
                        return (a.age or 99) < (b.age or 99)
                    end)

                    -- Youth slots: capped by youth_max_protected_per_pos, and
                    -- constrained so youth never displaces a starter (regular
                    -- slots must stay >= demand).
                    local youth_slots = math.min(
                        CONFIG.release.youth_max_protected_per_pos or 1,
                        math.max(0, cap - demand)
                    )
                    local regular_slots = cap - youth_slots

                    local youth_cands = {}
                    for i, p in ipairs(arr) do
                        if release_is_high_potential_youth(p, median_rating) then
                            youth_cands[#youth_cands + 1] = {
                                player = p, index = i, in_top = i <= regular_slots
                            }
                        end
                    end
                    table.sort(youth_cands, function(a, b)
                        return a.player.potential > b.player.potential
                    end)

                    local keep = {}
                    for i = 1, regular_slots do keep[arr[i].id] = true end

                    local youth_added = 0
                    for _, c in ipairs(youth_cands) do
                        if not c.in_top and youth_added < youth_slots then
                            keep[c.player.id] = true
                            youth_added = youth_added + 1
                            release_run_stats.youth_protected = release_run_stats.youth_protected + 1
                            LOGGER:LogInfo(string.format(
                                "Protected youth %d (OVR %d, POT %d, Age %d) at %s.",
                                c.player.id, c.player.overall, c.player.potential,
                                c.player.age, pos_name
                            ))
                        end
                    end

                    local filled = regular_slots + youth_added
                    if filled < cap then
                        for i = regular_slots + 1, #arr do
                            if not keep[arr[i].id] and filled < cap then
                                keep[arr[i].id] = true
                                filled = filled + 1
                            end
                        end
                    end

                    local released = 0
                    for _, p in ipairs(arr) do
                        if not keep[p.id] then
                            local reason = string.format(
                                "step4 prune %s (have %d, demand %d, cap %d)",
                                pos_name, #arr, demand, cap
                            )
                            if release_release_player(p.id, team_id, reason) then
                                released = released + 1
                                releases_step4 = releases_step4 + 1
                                if release_is_high_potential_youth(p, median_rating) then
                                    release_run_stats.youth_released = release_run_stats.youth_released + 1
                                end
                            end
                        end
                    end

                    -- Compact decision dump so we can audit borderline drops.
                    local ovr_parts, kept_parts, rel_parts = {}, {}, {}
                    for _, p in ipairs(arr) do
                        ovr_parts[#ovr_parts + 1] = string.format("%d(%d)", p.overall, p.id)
                        if keep[p.id] then
                            kept_parts[#kept_parts + 1] = string.format("%d(%d)", p.overall, p.id)
                        else
                            rel_parts[#rel_parts + 1] = string.format("%d(%d)", p.overall, p.id)
                        end
                    end
                    LOGGER:LogInfo(string.format(
                        "Step 4 %s: demand=%d cap=%d, %d players [%s]. Kept top %d + youth %d [%s]. Released %d [%s].",
                        pos_name, demand, cap, #arr, table.concat(ovr_parts, ","),
                        regular_slots, youth_added, table.concat(kept_parts, ","),
                        released, table.concat(rel_parts, ",")
                    ))
                end
            end
        end
    else
        LOGGER:LogInfo("Excess pruning disabled.")
    end

    local elapsed = os.time() - start_time
    LOGGER:LogInfo(string.format(
        "Done team %s (%d) in %ds: %d released (step3:%d, step4:%d).",
        team_name, team_id, elapsed,
        releases_step3 + releases_step4, releases_step3, releases_step4
    ))
    release_run_stats.releases_step4 = release_run_stats.releases_step4 + releases_step4
    release_run_stats.teams_processed = release_run_stats.teams_processed + 1
    release_teams_processed[team_id] = true
end

-- Progress save/load so long runs can resume.
local RELEASE_PROGRESS_FILE = "release_players_progress.dat"

local function release_save_progress(current_idx, total, success_count, error_count)
    local ok = pcall(function()
        local file = io.open(RELEASE_PROGRESS_FILE, "w")
        if not file then return end
        file:write(tostring(current_idx) .. "\n")
        file:write(tostring(total) .. "\n")
        file:write(tostring(success_count) .. "\n")
        file:write(tostring(error_count) .. "\n")
        file:write(tostring(os.time()) .. "\n")
        local processed = {}
        for tid in pairs(release_teams_processed) do
            processed[#processed + 1] = tostring(tid)
        end
        file:write(table.concat(processed, ","))
        file:close()
    end)
    if not ok then LOGGER:LogWarning("Failed to save release progress.") end
end

local function release_load_progress()
    local p = {
        current_idx = 1, total_teams = 0, success_count = 0,
        error_count = 0, timestamp = 0, teams_processed = {}
    }
    pcall(function()
        local file = io.open(RELEASE_PROGRESS_FILE, "r")
        if not file then return end
        p.current_idx    = tonumber(file:read("*l")) or 1
        p.total_teams    = tonumber(file:read("*l")) or 0
        p.success_count  = tonumber(file:read("*l")) or 0
        p.error_count    = tonumber(file:read("*l")) or 0
        p.timestamp      = tonumber(file:read("*l")) or 0
        local ids = file:read("*l") or ""
        for id_str in ids:gmatch("([^,]+)") do
            local tid = tonumber(id_str)
            if tid then p.teams_processed[tid] = true end
        end
        file:close()
    end)
    return p
end

function release_phase.run()
    LOGGER:LogInfo("=== RELEASE PHASE ===")
    build_loan_index()

    local team_pool = build_target_team_pool()
    if #team_pool == 0 then
        LOGGER:LogInfo("No teams in target leagues. Release phase exits.")
        return
    end
    LOGGER:LogInfo(string.format(
        "Collected %d teams from leagues: %s",
        #team_pool, table.concat(CONFIG.shared.target_leagues, ", ")
    ))

    local progress = release_load_progress()
    local current_idx = progress.current_idx
    local success_count, error_count = progress.success_count, progress.error_count

    for tid in pairs(progress.teams_processed) do
        release_teams_processed[tid] = true
    end

    if current_idx > 1 then
        local when = os.date("%Y-%m-%d %H:%M:%S", progress.timestamp)
        local resume = MessageBox("Resume Progress?", string.format(
            "Previous release progress found (%d/%d teams) from %s.\nDo you want to resume?",
            current_idx - 1, #team_pool, when
        ), true)
        if not resume then
            current_idx, success_count, error_count = 1, 0, 0
            release_teams_processed = {}
        end
    end

    local total = #team_pool
    local start_time = os.time()

    for idx = current_idx, total do
        local team_id = team_pool[idx]

        if idx % 5 == 0 or idx == current_idx or idx == total then
            local percent = math.floor(idx / total * 100)
            local elapsed = os.time() - start_time
            local est = elapsed > 0 and math.floor((total - idx) * (elapsed / (idx - current_idx + 1))) or "unknown"
            LOGGER:LogInfo(string.format(
                "Release progress: %d/%d (%d%%) - %d ok, %d err. Est. remaining: %s s",
                idx, total, percent, success_count, error_count, tostring(est)
            ))
        end

        local ok, err = pcall(function() release_process_team(team_id) end)
        if ok then success_count = success_count + 1
        else error_count = error_count + 1
             LOGGER:LogError(string.format("Error processing team %d: %s", team_id, tostring(err)))
        end

        if idx % CONFIG.release.batch_size == 0 or idx == total then
            release_save_progress(idx + 1, total, success_count, error_count)
        end
    end

    os.remove(RELEASE_PROGRESS_FILE)

    local total_elapsed = os.time() - start_time
    local total_released  = release_run_stats.releases_step3 + release_run_stats.releases_step4
    local total_converted = release_run_stats.conversions + release_run_stats.cover_conversions

    LOGGER:LogInfo("=== Release run summary ===")
    LOGGER:LogInfo(string.format(
        "Teams processed: %d (errors %d, no-formation skipped %d).",
        success_count, error_count, release_run_stats.teams_skipped
    ))
    LOGGER:LogInfo(string.format(
        "Conversions: %d total (step2 %d, cover %d).",
        total_converted, release_run_stats.conversions, release_run_stats.cover_conversions
    ))
    LOGGER:LogInfo(string.format(
        "Releases: %d total (step3 %d, step4 %d). Youth: protected %d, released %d. Elapsed: %ds.",
        total_released, release_run_stats.releases_step3, release_run_stats.releases_step4,
        release_run_stats.youth_protected, release_run_stats.youth_released, total_elapsed
    ))

    release_phase.summary = {
        teams_success = success_count,
        teams_error   = error_count,
        stats         = release_run_stats,
        elapsed       = total_elapsed
    }
end

--==============================================================================
-- TRANSFER PHASE
--==============================================================================
local transfer_phase = {}

local transfer_size_cache      = {}
local transfer_positions_cache = {}
local transfer_bounds_cache    = {}
local transfer_needs_cache     = {}

local transfer_stats = {
    transfers_total    = 0,
    transfers_normal   = 0,
    transfers_alt      = 0,
    transfers_youth    = 0,
    transfers_widened  = 0,
    slots_abandoned    = 0,
    slots_unfilled     = 0,
    slots_failed       = 0,
    teams_full_skipped = 0,
    teams_no_stats     = 0
}

local function transfer_team_size(team_id)
    local cached = transfer_size_cache[team_id]
    if cached then return cached end
    build_team_players_map()
    local list = team_players_map[team_id]
    local n = list and #list or 0
    transfer_size_cache[team_id] = n
    return n
end

local function transfer_positions_count(team_id)
    local cached = transfer_positions_cache[team_id]
    if cached then return cached end
    build_team_players_map()
    local counts = {}
    for _, p_id in ipairs(team_players_map[team_id] or {}) do
        local pc = player_cache[p_id]
        if pc and pc.preferredposition1 then
            local name = pos_name_from_id(pc.preferredposition1)
            counts[name] = (counts[name] or 0) + 1
        end
    end
    transfer_positions_cache[team_id] = counts
    return counts
end

local function transfer_bounds(team_id, lower_minus, upper_plus)
    local cached = transfer_bounds_cache[team_id]
    if cached then return cached[1], cached[2], cached[3] end

    build_team_players_map()
    local ratings = {}
    for _, p_id in ipairs(team_players_map[team_id] or {}) do
        local pc = player_cache[p_id]
        if pc then ratings[#ratings + 1] = pc.overall end
    end
    if #ratings == 0 then
        LOGGER:LogWarning(string.format("No ratings for team %d.", team_id))
        return nil, nil
    end

    table.sort(ratings)
    local n = #ratings
    local p50 = math.floor(ratings[math.ceil(0.5 * n)] + 0.5)
    local p75 = math.floor(ratings[math.ceil(0.75 * n)] + 0.5)
    local lb, ub = p50 - lower_minus, p75 + upper_plus

    transfer_bounds_cache[team_id] = {lb, ub, p50}
    return lb, ub, p50
end

-- Needs: aim for 2 bodies per formation slot. Returns (needed, shortage_by_pos, total).
local function transfer_compute_needs(team_id)
    local cached = transfer_needs_cache[team_id]
    if cached then return cached.needed, cached.shortage_by_pos, cached.total_shortage end

    local formation_positions = get_formation_positions(team_id)
    if #formation_positions == 0 then
        transfer_needs_cache[team_id] = {needed = {}, shortage_by_pos = {}, total_shortage = 0}
        return {}, {}, 0
    end

    local demand = {}
    for _, pos in ipairs(formation_positions) do
        demand[pos] = (demand[pos] or 0) + 1
    end
    for pos in pairs(demand) do
        demand[pos] = demand[pos] * 2
    end

    local have = transfer_positions_count(team_id)
    local needed, shortage_by_pos, total = {}, {}, 0
    for pos, required in pairs(demand) do
        local short = required - (have[pos] or 0)
        if short > 0 then
            shortage_by_pos[pos] = short
            total = total + short
            for _ = 1, short do needed[#needed + 1] = pos end
        end
    end

    transfer_needs_cache[team_id] = {
        needed = needed, shortage_by_pos = shortage_by_pos, total_shortage = total
    }
    return needed, shortage_by_pos, total
end

local function transfer_entry_weight(shortage_for_pos, total_shortage, pos_name, squad_size)
    local crit = (CONFIG.transfer.critical_position_bonus or {})[pos_name] or 0
    -- Per-position shortage dominates; team-wide shortage secondary; squad_size tiebreak.
    return (shortage_for_pos or 0) * 100
        + (total_shortage or 0)
        + crit
        - (squad_size or 0) * 0.01
end

local function transfer_build_queue()
    local entries = {}
    local teams_considered, teams_with_needs, teams_full = 0, 0, 0

    for _, league_id in ipairs(CONFIG.shared.target_leagues) do
        for _, team_id in ipairs(league_team_map[league_id] or {}) do
            teams_considered = teams_considered + 1
            local size = transfer_team_size(team_id)
            if size < CONFIG.transfer.squad_size then
                local needs, short_by_pos, total = transfer_compute_needs(team_id)
                if #needs > 0 then teams_with_needs = teams_with_needs + 1 end
                for _, pos in ipairs(needs) do
                    entries[#entries + 1] = {
                        team_id  = team_id,
                        position = pos,
                        weight   = transfer_entry_weight(short_by_pos[pos], total, pos, size),
                        shortage = short_by_pos[pos] or 0
                    }
                end
            else
                teams_full = teams_full + 1
            end
        end
    end

    LOGGER:LogInfo(string.format(
        "Need queue built: %d teams considered, %d with needs, %d already full -> %d pending slots.",
        teams_considered, teams_with_needs, teams_full, #entries
    ))
    table.sort(entries, function(a, b) return a.weight > b.weight end)
    return entries
end

local function transfer_build_free_agents()
    build_team_players_map()
    local pool_ids = team_players_map[CONFIG.shared.source_team_id] or {}
    local results = {}

    for _, p_id in ipairs(pool_ids) do
        local pc = player_cache[p_id]
        if pc then
            local age = pc.age
            if age >= CONFIG.transfer.age_constraints.min and age <= CONFIG.transfer.age_constraints.max then
                results[#results + 1] = {
                    playerid     = p_id,
                    overall      = pc.overall,
                    potential    = pc.potential,
                    positionName = pc.positionName,
                    age          = age
                }
            end
        end
    end

    for i = #results, 2, -1 do
        local j = math.random(i)
        results[i], results[j] = results[j], results[i]
    end

    local index = {}
    for i, p in ipairs(results) do
        local pos = p.positionName
        if pos then
            index[pos] = index[pos] or {}
            index[pos][#index[pos] + 1] = i
        end
    end

    return results, index
end

-- Youth prospect finder (ignores rating band; uses capped median+bonus threshold).
local function transfer_find_youth(free_agents, index, req_pos, min_pot)
    local max_age = CONFIG.transfer.youth_player.max_age

    local function best_at(pos)
        local best_idx, best_pot = nil, -1
        local bucket = index[pos]
        if not bucket then return nil end
        for _, i in ipairs(bucket) do
            local fa = free_agents[i]
            if fa and not fa.transferred
                and fa.age <= max_age and fa.potential >= min_pot
                and fa.potential > best_pot then
                best_idx, best_pot = i, fa.potential
            end
        end
        return best_idx
    end

    local idx = best_at(req_pos)
    if idx then return idx, false, nil end

    local alts = CONFIG.transfer.alternative_positions[req_pos]
    if alts then
        for _, alt in ipairs(alts) do
            local i = best_at(alt)
            if i then return i, true, alt end
        end
    end
    return nil, false, nil
end

-- Core alt-conv-safe transfer handler. Converts the player BEFORE calling
-- TransferPlayer; reverts and abandons if the converted rating drops below the
-- widened band (preventing "silent miss" where a slot gets filled out of position).
local function transfer_handle(player_id, team_id, position, free_agents, cand_idx,
                                used_alt, alt_pos_used, is_youth)
    local player_name = get_player_name_cached(player_id)

    local abandoned = false
    if used_alt then
        local pc = player_cache[player_id]
        local rec_id = pc and pc.record_id
        if rec_id then
            -- Snapshot original position/roles so we can revert byte-for-byte if
            -- the rating ends up out of band (preserves un-mapped position IDs).
            local original_pos_id = pc.preferredposition1
            local original_r1 = players_table:GetRecordFieldValue(rec_id, "role1")
            local original_r2 = players_table:GetRecordFieldValue(rec_id, "role2")
            local original_r3 = players_table:GetRecordFieldValue(rec_id, "role3")

            write_player_position_and_roles(player_id, position)

            -- Verify rating still fits the widened band; revert if not.
            local max_widen = (CONFIG.transfer.max_widen_steps or 0)
                             * (CONFIG.transfer.widen_step_size or 0)
            local widened_lb = transfer_bounds(
                team_id,
                CONFIG.transfer.lower_bound_minus + max_widen,
                CONFIG.transfer.upper_bound_plus + max_widen
            )
            local live_rating = players_table:GetRecordFieldValue(rec_id, "overallrating")
                             or players_table:GetRecordFieldValue(rec_id, "overall") or 0

            if widened_lb and live_rating < widened_lb then
                LOGGER:LogInfo(string.format(
                    "Revert alt-conv: %s OVR %d < widened LB %d for %s -> %s. Abandoning.",
                    player_name, live_rating, widened_lb, alt_pos_used, position
                ))
                if original_pos_id and original_pos_id >= 0 then
                    players_table:SetRecordFieldValue(rec_id, "preferredposition1", original_pos_id)
                    pc.preferredposition1 = original_pos_id
                    pc.positionName       = pos_name_from_id(original_pos_id)
                    if original_r1 then players_table:SetRecordFieldValue(rec_id, "role1", original_r1) end
                    if original_r2 then players_table:SetRecordFieldValue(rec_id, "role2", original_r2) end
                    if original_r3 then players_table:SetRecordFieldValue(rec_id, "role3", original_r3) end
                end
                abandoned = true
            end
        else
            LOGGER:LogWarning(string.format("Player %d not in cache; can't alt-convert.", player_id))
        end
    end

    if abandoned then
        transfer_stats.slots_abandoned = transfer_stats.slots_abandoned + 1
        return false, true
    end

    if team_id == CONFIG.shared.source_team_id then
        LOGGER:LogWarning(string.format(
            "Skip transfer: destination is free agent pool (%d). Player %d.",
            team_id, player_id
        ))
        transfer_stats.slots_failed = transfer_stats.slots_failed + 1
        return false, false
    end

    local terms = CONFIG.transfer.transfer_terms
    local ok, err = pcall(function()
        if IsPlayerPresigned(player_id) then DeletePresignedContract(player_id) end
        if IsPlayerLoanedOut(player_id) then TerminateLoan(player_id) end
        TransferPlayer(
            player_id, team_id,
            terms.sum, terms.wage, terms.contract_length,
            CONFIG.shared.source_team_id, terms.release_clause
        )
    end)

    if ok then
        local kind = "normal"
        if used_alt then
            kind = "alt"
            transfer_stats.transfers_alt = transfer_stats.transfers_alt + 1
        elseif is_youth then
            kind = "youth"
            transfer_stats.transfers_youth = transfer_stats.transfers_youth + 1
        else
            transfer_stats.transfers_normal = transfer_stats.transfers_normal + 1
        end
        transfer_stats.transfers_total = transfer_stats.transfers_total + 1

        LOGGER:LogInfo(string.format(
            "Transferred %s (%d) -> %s (%d) as %s for %s.",
            player_name, player_id, get_team_name_cached(team_id), team_id, kind, position
        ))

        -- Sync caches so downstream picks see the new roster.
        transfer_size_cache[team_id] = (transfer_size_cache[team_id] or 0) + 1
        transfer_bounds_cache[team_id]    = nil
        transfer_positions_cache[team_id] = nil
        transfer_needs_cache[team_id]     = nil

        team_roster_add(team_id, player_id)
        team_roster_remove(CONFIG.shared.source_team_id, player_id)

        local fa = free_agents[cand_idx]
        if fa then fa.transferred = true end
        return true, false
    else
        transfer_stats.slots_failed = transfer_stats.slots_failed + 1
        LOGGER:LogWarning(string.format(
            "Failed transfer %s (%d) -> %s (%d). Error: %s",
            player_name, player_id, get_team_name_cached(team_id), team_id, tostring(err)
        ))
        return false, false
    end
end

-- Find candidate for a slot, iterating CONFIG.transfer.search_order.
-- Returns (idx, used_alt, alt_pos, is_youth, used_lb, used_ub) or nils.
local function transfer_find_candidate(free_agents, index, req_pos,
                                       lb, ub, median, youth_min_pot, blocklist)
    local function find_with_block(pos, l, u)
        local best_idx, best_dist = nil, math.huge
        local target = median or ((l + u) * 0.5)
        if index[pos] then
            for _, i in ipairs(index[pos]) do
                if not blocklist[i] then
                    local fa = free_agents[i]
                    if fa and not fa.transferred
                        and fa.overall >= l and fa.overall <= u then
                        local d = math.abs(fa.overall - target)
                        if d < best_dist then best_idx, best_dist = i, d end
                    end
                end
            end
        else
            for i, fa in ipairs(free_agents) do
                if not blocklist[i] and not fa.transferred
                    and fa.positionName == pos
                    and fa.overall >= l and fa.overall <= u then
                    local d = math.abs(fa.overall - target)
                    if d < best_dist then best_idx, best_dist = i, d end
                end
            end
        end
        return best_idx
    end

    local steps = CONFIG.transfer.max_widen_steps or 0
    local step_size = CONFIG.transfer.widen_step_size or 0

    local strategies = {
        exact = function()
            local i = find_with_block(req_pos, lb, ub)
            if i then return i, false, nil, false, lb, ub end
        end,
        alt = function()
            local alts = CONFIG.transfer.alternative_positions[req_pos]
            if not alts then return end
            for _, alt in ipairs(alts) do
                local i = find_with_block(alt, lb, ub)
                if i then return i, true, alt, false, lb, ub end
            end
        end,
        widen_one = function()
            if steps < 1 or step_size <= 0 then return end
            local w_lb, w_ub = lb - step_size, ub + step_size
            local i = find_with_block(req_pos, w_lb, w_ub)
            if i then return i, false, nil, false, w_lb, w_ub end
        end,
        youth = function()
            local i, alt_used, alt_pos = transfer_find_youth(free_agents, index, req_pos, youth_min_pot)
            if i and not blocklist[i] then
                return i, alt_used or false, alt_pos, true, lb, ub
            end
        end,
        widen_full = function()
            if step_size <= 0 then return end
            for s = 2, steps do
                local w_lb, w_ub = lb - s * step_size, ub + s * step_size
                local i = find_with_block(req_pos, w_lb, w_ub)
                if i then return i, false, nil, false, w_lb, w_ub end
            end
        end
    }

    local order = CONFIG.transfer.search_order or { "exact", "alt", "widen_one", "youth", "widen_full" }
    local seen = {}
    for _, name in ipairs(order) do
        local fn = strategies[name]
        if fn and not seen[name] then
            seen[name] = true
            local a, b, c, d, e, f = fn()
            if a then return a, b, c, d, e, f end
        end
    end
    return nil, false, nil, false, lb, ub
end

local function transfer_process_entry(entry, free_agents, index)
    local team_id, req_pos = entry.team_id, entry.position

    if transfer_team_size(team_id) >= CONFIG.transfer.squad_size then
        transfer_stats.teams_full_skipped = transfer_stats.teams_full_skipped + 1
        return false
    end

    local lb, ub, median = transfer_bounds(
        team_id, CONFIG.transfer.lower_bound_minus, CONFIG.transfer.upper_bound_plus
    )
    if not lb or not ub then
        transfer_stats.teams_no_stats = transfer_stats.teams_no_stats + 1
        return false
    end

    local youth_min_pot
    if CONFIG.transfer.youth_player.use_median then
        youth_min_pot = median + CONFIG.transfer.youth_player.potential_bonus
        local cap = CONFIG.transfer.youth_player.potential_cap
        if cap and youth_min_pot > cap then youth_min_pot = cap end
    else
        youth_min_pot = ub
    end

    local blocklist = {}
    for _ = 1, 5 do  -- max 5 abandon-and-retry attempts per slot
        local idx, used_alt, alt_pos, is_youth, used_lb, used_ub =
            transfer_find_candidate(free_agents, index, req_pos, lb, ub, median, youth_min_pot, blocklist)

        if not idx then
            transfer_stats.slots_unfilled = transfer_stats.slots_unfilled + 1
            LOGGER:LogInfo(string.format(
                "No free agent for team %d at '%s' (tried [%d..%d]). Skipping.",
                team_id, req_pos,
                lb - (CONFIG.transfer.max_widen_steps or 0) * (CONFIG.transfer.widen_step_size or 0),
                ub + (CONFIG.transfer.max_widen_steps or 0) * (CONFIG.transfer.widen_step_size or 0)
            ))
            return false
        end

        local widened = (used_lb ~= lb or used_ub ~= ub)
        local player_id = free_agents[idx].playerid
        local success, abandoned = transfer_handle(
            player_id, team_id, req_pos, free_agents, idx, used_alt, alt_pos, is_youth
        )

        if success then
            if widened then
                transfer_stats.transfers_widened = transfer_stats.transfers_widened + 1
            end
            return true
        elseif abandoned then
            blocklist[idx] = true
        else
            return false
        end
    end

    return false
end

function transfer_phase.run()
    LOGGER:LogInfo("=== TRANSFER PHASE ===")
    build_league_team_map()

    local queue = transfer_build_queue()
    if #queue == 0 then
        LOGGER:LogInfo("No team needs. Transfer phase exits.")
        return
    end

    local free_agents, index = transfer_build_free_agents()
    if #free_agents == 0 then
        LOGGER:LogInfo("No eligible free agents. Transfer phase exits.")
        return
    end

    local since_requeue = 0
    local start_time = os.time()

    local idx = 1
    while idx <= #queue do
        if idx % 100 == 0 then
            LOGGER:LogInfo(string.format(
                "Processed %d/%d needs (%d%%) in %ds. Transfers so far: %d",
                idx, #queue, math.floor(idx / #queue * 100),
                os.time() - start_time, transfer_stats.transfers_total
            ))
        end

        if transfer_process_entry(queue[idx], free_agents, index) then
            since_requeue = since_requeue + 1
        end

        if since_requeue >= (CONFIG.transfer.requeue_every_n_transfers or math.huge) then
            since_requeue = 0
            local remaining = {}
            for j = idx + 1, #queue do
                local e = queue[j]
                local size = transfer_team_size(e.team_id)
                if size < CONFIG.transfer.squad_size then
                    local _, short_by_pos, total_short = transfer_compute_needs(e.team_id)
                    if (short_by_pos[e.position] or 0) > 0 then
                        e.weight   = transfer_entry_weight(short_by_pos[e.position], total_short, e.position, size)
                        e.shortage = short_by_pos[e.position]
                        remaining[#remaining + 1] = e
                    end
                end
            end
            table.sort(remaining, function(a, b) return a.weight > b.weight end)

            local new_queue = {}
            for j = 1, idx do new_queue[j] = queue[j] end
            for j, e in ipairs(remaining) do new_queue[idx + j] = e end
            queue = new_queue
            LOGGER:LogInfo(string.format(
                "Re-sorted queue after %d transfers: %d needs still pending.",
                transfer_stats.transfers_total, #remaining
            ))
        end

        idx = idx + 1
    end

    local elapsed = os.time() - start_time
    LOGGER:LogInfo("=== Transfer run summary ===")
    LOGGER:LogInfo(string.format(
        "Transfers: %d total (normal %d, alt-pos %d, youth %d, widened %d). " ..
        "Slots: unfilled %d, abandoned %d, failed %d. " ..
        "Teams skipped: full %d, no-stats %d. Elapsed: %ds.",
        transfer_stats.transfers_total, transfer_stats.transfers_normal,
        transfer_stats.transfers_alt, transfer_stats.transfers_youth,
        transfer_stats.transfers_widened,
        transfer_stats.slots_unfilled, transfer_stats.slots_abandoned, transfer_stats.slots_failed,
        transfer_stats.teams_full_skipped, transfer_stats.teams_no_stats, elapsed
    ))

    transfer_phase.summary = {
        queue_size = #queue,
        stats      = transfer_stats,
        elapsed    = elapsed
    }
end

--==============================================================================
-- UPGRADE PHASE
-- For each team, finds formation positions whose best player is far below the
-- team median and signs a free agent in [median, median + plus] to fix that
-- quality gap. All priorities across all teams are sorted by gap size so the
-- worst shortfalls get first pick of the FA pool. Optionally cleans up the
-- position's deepest layer after signing to avoid squad bloat.
--==============================================================================
local upgrade_phase = {}

local upgrade_median_cache = {}

local upgrade_stats = {
    priorities_found   = 0,
    upgrades_made      = 0,
    upgrades_failed    = 0,
    upgrades_no_fa     = 0,
    teams_full_skipped = 0,
    cleanup_releases   = 0
}

local function upgrade_team_median(team_id)
    local cached = upgrade_median_cache[team_id]
    if cached then return cached end

    build_team_players_map()
    local list = team_players_map[team_id]
    if not list or #list == 0 then return 65 end

    local ratings = {}
    for _, p_id in ipairs(list) do
        local pc = player_cache[p_id]
        if pc then ratings[#ratings + 1] = pc.overall end
    end
    if #ratings == 0 then return 65 end

    table.sort(ratings)
    local median
    if #ratings % 2 == 0 then
        median = (ratings[#ratings / 2] + ratings[#ratings / 2 + 1]) / 2
    else
        median = ratings[math.ceil(#ratings / 2)]
    end
    median = math.floor(median + 0.5)
    upgrade_median_cache[team_id] = median
    return median
end

-- Collect current players at a given position (by preferred position mapping).
local function upgrade_players_at_position(team_id, position)
    local result = {}
    for _, p_id in ipairs(team_players_map[team_id] or {}) do
        local pc = player_cache[p_id]
        if pc and pc.preferredposition1 then
            local name = pos_name_from_id(pc.preferredposition1)
            if name == position then
                result[#result + 1] = {
                    id        = p_id,
                    overall   = pc.overall,
                    potential = pc.potential or 0,
                    age       = pc.age
                }
            end
        end
    end
    return result
end

-- For a team, return a list of priorities (one per formation position that
-- needs upgrading) plus the median used.
local function upgrade_calc_priorities(team_id)
    local formation_positions = get_formation_positions(team_id)
    if #formation_positions == 0 then return {} end

    local median = upgrade_team_median(team_id)
    local threshold = median - CONFIG.upgrade.median_minus_threshold

    local unique = {}
    for _, p in ipairs(formation_positions) do unique[p] = true end

    local priorities = {}
    for pos in pairs(unique) do
        local players = upgrade_players_at_position(team_id, pos)
        if #players > 0 then
            table.sort(players, function(a, b) return a.overall > b.overall end)
            local best = players[1]
            if best.overall <= threshold then
                priorities[#priorities + 1] = {
                    team_id     = team_id,
                    position    = pos,
                    gap         = threshold - best.overall,
                    best_ovr    = best.overall,
                    team_median = median
                }
            end
        else
            -- No player at a formation position at all -> maximum priority.
            priorities[#priorities + 1] = {
                team_id     = team_id,
                position    = pos,
                gap         = threshold + 1,
                best_ovr    = 0,
                team_median = median
            }
        end
    end
    return priorities
end

-- Build free-agent pool indexed by position name. Returns (all, by_pos).
-- FAs are sorted by OVR desc per-position so we always try the best fit first.
local function upgrade_build_free_agents()
    build_team_players_map()
    local list = team_players_map[CONFIG.shared.source_team_id] or {}
    local by_pos = {}

    for _, p_id in ipairs(list) do
        local pc = player_cache[p_id]
        if pc and pc.age <= CONFIG.upgrade.max_age_for_signing and pc.positionName then
            local fa = {
                playerid    = p_id,
                overall     = pc.overall,
                potential   = pc.potential,
                age         = pc.age,
                position    = pc.positionName,
                transferred = false
            }
            by_pos[pc.positionName] = by_pos[pc.positionName] or {}
            local bucket = by_pos[pc.positionName]
            bucket[#bucket + 1] = fa
        end
    end

    for _, bucket in pairs(by_pos) do
        table.sort(bucket, function(a, b) return a.overall > b.overall end)
    end
    return by_pos
end

local function upgrade_find_fa(by_pos, position, min_rating, max_rating)
    local bucket = by_pos[position]
    if not bucket then return nil end
    for _, fa in ipairs(bucket) do
        if not fa.transferred
            and fa.overall >= min_rating
            and fa.overall <= max_rating then
            return fa
        end
    end
    return nil
end

local function upgrade_is_youth_prospect(player, team_median)
    local cfg = CONFIG.upgrade
    if not cfg.protect_youth then return false end
    if player.age > cfg.youth_max_age then return false end
    local threshold = team_median + cfg.youth_potential_bonus
    local cap = cfg.youth_potential_cap
    if cap and threshold > cap then threshold = cap end
    return player.potential >= threshold
end

-- After signing an upgrade, release the worst excess players at that position
-- while preserving top N + 1 youth prospect slot, matching upgrade_team.lua.
local function upgrade_cleanup_position(team_id, position, team_median)
    local cfg = CONFIG.upgrade
    if not cfg.cleanup_after_upgrade then return 0 end
    local keep_count = cfg.cleanup_keep_count or 3

    local players = upgrade_players_at_position(team_id, position)
    if #players <= keep_count then return 0 end

    table.sort(players, function(a, b)
        if a.overall ~= b.overall then return a.overall > b.overall end
        return (a.potential or 0) > (b.potential or 0)
    end)

    local keep = {}
    local top_regular = math.max(0, keep_count - 1)
    for i = 1, top_regular do keep[players[i].id] = true end

    local youth_found = false
    for i = top_regular + 1, #players do
        if upgrade_is_youth_prospect(players[i], team_median) then
            keep[players[i].id] = true
            LOGGER:LogInfo(string.format(
                "Upgrade-protect youth %d (OVR %d, POT %d, age %d) at %s.",
                players[i].id, players[i].overall, players[i].potential,
                players[i].age, position
            ))
            youth_found = true
            break
        end
    end
    if not youth_found and players[keep_count] then
        keep[players[keep_count].id] = true
    end

    local released = 0
    for _, p in ipairs(players) do
        if not keep[p.id] and not loaned_players[p.id] then
            local ok = pcall(function() ReleasePlayerFromTeam(p.id) end)
            if ok then
                LOGGER:LogInfo(string.format(
                    "Upgrade cleanup: released %s (%d, %s, OVR %d) from %s.",
                    get_player_name_cached(p.id), p.id, position, p.overall,
                    get_team_name_cached(team_id)
                ))
                team_roster_remove(team_id, p.id)
                team_roster_add(CONFIG.shared.source_team_id, p.id)
                released = released + 1
            end
        end
    end

    if released > 0 then upgrade_median_cache[team_id] = nil end
    return released
end

local function upgrade_transfer(fa, team_id, position)
    local player_id = fa.playerid
    local terms = CONFIG.upgrade.transfer_terms

    if team_id == CONFIG.shared.source_team_id then
        LOGGER:LogWarning(string.format(
            "Upgrade: skip transfer to free agent pool (%d). Player %d.",
            team_id, player_id
        ))
        return false
    end

    local ok, err = pcall(function()
        if IsPlayerPresigned(player_id) then DeletePresignedContract(player_id) end
        if IsPlayerLoanedOut(player_id) then TerminateLoan(player_id) end
        TransferPlayer(
            player_id, team_id,
            terms.sum, terms.wage, terms.contract_length,
            CONFIG.shared.source_team_id, terms.release_clause
        )
    end)

    if ok then
        LOGGER:LogInfo(string.format(
            "Upgrade: %s (%d, %s, OVR %d) -> %s (%d).",
            get_player_name_cached(player_id), player_id, position, fa.overall,
            get_team_name_cached(team_id), team_id
        ))
        team_roster_add(team_id, player_id)
        team_roster_remove(CONFIG.shared.source_team_id, player_id)
        fa.transferred = true
        upgrade_median_cache[team_id] = nil
        return true
    end

    LOGGER:LogWarning(string.format(
        "Upgrade transfer failed: %s -> %s: %s",
        get_player_name_cached(player_id), get_team_name_cached(team_id), tostring(err)
    ))
    return false
end

function upgrade_phase.run()
    LOGGER:LogInfo("=== UPGRADE PHASE ===")
    build_league_team_map()

    local team_pool = build_target_team_pool()
    if #team_pool == 0 then
        LOGGER:LogInfo("No teams in target leagues. Upgrade phase exits.")
        return
    end

    local by_pos = upgrade_build_free_agents()

    LOGGER:LogInfo("Calculating upgrade priorities across all teams...")
    local all_priorities = {}
    for _, team_id in ipairs(team_pool) do
        local prios = upgrade_calc_priorities(team_id)
        for _, p in ipairs(prios) do
            all_priorities[#all_priorities + 1] = p
        end
    end

    -- Bigger quality gap = higher priority.
    table.sort(all_priorities, function(a, b) return a.gap > b.gap end)
    upgrade_stats.priorities_found = #all_priorities
    LOGGER:LogInfo(string.format(
        "Found %d upgrade priorities across %d teams.",
        #all_priorities, #team_pool
    ))

    local start_time = os.time()
    for idx, pr in ipairs(all_priorities) do
        if idx % 50 == 0 or idx == 1 or idx == #all_priorities then
            LOGGER:LogInfo(string.format(
                "Upgrade progress: %d/%d (%d%%), %d signed so far, %ds elapsed.",
                idx, #all_priorities, math.floor(idx / #all_priorities * 100),
                upgrade_stats.upgrades_made, os.time() - start_time
            ))
        end

        local roster = team_players_map[pr.team_id] or {}
        if #roster >= CONFIG.upgrade.squad_size then
            upgrade_stats.teams_full_skipped = upgrade_stats.teams_full_skipped + 1
        else
            -- Re-evaluate gap with the *current* roster (prior signings may have
            -- already fixed this position via Transfer phase sharing the FA pool).
            local median = upgrade_team_median(pr.team_id)
            local threshold = median - CONFIG.upgrade.median_minus_threshold
            local position_players = upgrade_players_at_position(pr.team_id, pr.position)
            local current_best = 0
            if #position_players > 0 then
                table.sort(position_players, function(a, b) return a.overall > b.overall end)
                current_best = position_players[1].overall
            end

            if current_best <= threshold then
                local min_rating = median
                local max_rating = median + CONFIG.upgrade.median_plus_threshold
                local fa = upgrade_find_fa(by_pos, pr.position, min_rating, max_rating)
                if fa then
                    if upgrade_transfer(fa, pr.team_id, pr.position) then
                        upgrade_stats.upgrades_made = upgrade_stats.upgrades_made + 1
                        upgrade_stats.cleanup_releases =
                            upgrade_stats.cleanup_releases
                            + upgrade_cleanup_position(pr.team_id, pr.position, median)
                    else
                        upgrade_stats.upgrades_failed = upgrade_stats.upgrades_failed + 1
                    end
                else
                    upgrade_stats.upgrades_no_fa = upgrade_stats.upgrades_no_fa + 1
                end
            end
        end
    end

    local elapsed = os.time() - start_time
    LOGGER:LogInfo("=== Upgrade run summary ===")
    LOGGER:LogInfo(string.format(
        "Upgrades: %d signed, %d failed, %d had no FA in band. Teams full skipped: %d. Cleanup releases: %d. Priorities evaluated: %d. Elapsed: %ds.",
        upgrade_stats.upgrades_made, upgrade_stats.upgrades_failed,
        upgrade_stats.upgrades_no_fa, upgrade_stats.teams_full_skipped,
        upgrade_stats.cleanup_releases, upgrade_stats.priorities_found, elapsed
    ))

    upgrade_phase.summary = { stats = upgrade_stats, elapsed = elapsed }
end

--==============================================================================
-- FILL PHASE (simplified squad filler)
--==============================================================================
local fill_phase = {}

local fill_position_to_group = {}
for group_name, pos_list in pairs(CONFIG.fill.position_groups.definitions) do
    for _, p in ipairs(pos_list) do
        fill_position_to_group[p] = group_name
    end
end

local FILL_TOTAL_RATIO_PARTS = 0
for _, ratio in pairs(CONFIG.fill.position_groups.ratios) do
    FILL_TOTAL_RATIO_PARTS = FILL_TOTAL_RATIO_PARTS + ratio
end

local fill_size_cache    = {}
local fill_ratings_cache = {}

local function fill_team_size(team_id)
    local cached = fill_size_cache[team_id]
    if cached then return cached end
    build_team_players_map()
    local list = team_players_map[team_id]
    local n = list and #list or 0
    fill_size_cache[team_id] = n
    return n
end

local function fill_update_size(team_id, delta)
    fill_size_cache[team_id] = (fill_size_cache[team_id] or fill_team_size(team_id)) + delta
end

local function fill_compute_bounds(team_id)
    local list = team_players_map and team_players_map[team_id]
    if not list or #list == 0 then return nil end

    local ratings = {}
    for _, p_id in ipairs(list) do
        local pc = player_cache[p_id]
        if pc and pc.overall then ratings[#ratings + 1] = pc.overall end
    end
    if #ratings == 0 then return nil end

    table.sort(ratings)
    local n = #ratings
    local median = math.floor(ratings[math.ceil(0.5 * n)] + 0.5)
    local p75    = math.floor(ratings[math.ceil(0.75 * n)] + 0.5)
    local min_r  = median - CONFIG.fill.rating_variance.lower_bound_minus
    local max_r  = p75    + CONFIG.fill.rating_variance.upper_bound_plus
    return {min_r, max_r, median, p75}
end

local function fill_bounds(team_id)
    local cached = fill_ratings_cache[team_id]
    if not cached then
        cached = fill_compute_bounds(team_id)
        if cached then fill_ratings_cache[team_id] = cached end
    end
    if cached then return cached[1], cached[2], cached[3], cached[4] end
    return nil, nil, nil, nil
end

local function fill_team_display_name(team_id)
    local name = get_team_name_cached(team_id)
    local _, _, median, p75 = fill_bounds(team_id)
    if median and p75 then
        return string.format("%s (Median: %d 75th: %d)", name, median, p75)
    end
    return name
end

--------------------------------------------------------------------------------
-- Position group / formation analysis
--------------------------------------------------------------------------------
local function fill_count_by_group(team_id)
    local counts = {GK = 0, DEF = 0, MID = 0, AM = 0, ST = 0}
    for _, p_id in ipairs(team_players_map[team_id] or {}) do
        local pc = player_cache[p_id]
        if pc and pc.preferredposition1 then
            local g = fill_position_to_group[pos_name_from_id(pc.preferredposition1)]
            if g then counts[g] = counts[g] + 1 end
        end
    end
    return counts
end

local function fill_count_by_position(team_id)
    local counts = {}
    for _, p_id in ipairs(team_players_map[team_id] or {}) do
        local pc = player_cache[p_id]
        if pc and pc.preferredposition1 then
            local name = pos_name_from_id(pc.preferredposition1)
            counts[name] = (counts[name] or 0) + 1
        end
    end
    return counts
end

local function fill_group_targets(squad_size)
    local per_part = squad_size / FILL_TOTAL_RATIO_PARTS
    local targets = {}
    for g, r in pairs(CONFIG.fill.position_groups.ratios) do
        targets[g] = { ideal = math.floor(r * per_part + 0.5), ratio = r }
    end
    return targets
end

local function fill_underrepresented_groups(team_id, squad_size)
    local have = fill_count_by_group(team_id)
    local targets = fill_group_targets(squad_size)

    local list = {}
    for g, t in pairs(targets) do
        local ideal, actual = t.ideal, have[g] or 0
        local shortfall = ideal > 0 and math.max(0, (ideal - actual) / ideal) or 0
        if shortfall > 0 then
            list[#list + 1] = { group = g, shortfall = shortfall }
        end
    end

    -- Randomize then sort by shortfall so equal groups don't always pick in the same order.
    for i = #list, 2, -1 do
        local j = math.random(i)
        list[i], list[j] = list[j], list[i]
    end
    table.sort(list, function(a, b) return a.shortfall > b.shortfall end)

    local priorities = {}
    for _, e in ipairs(list) do priorities[#priorities + 1] = e.group end
    return priorities
end

local function fill_positions_in_group(group)
    return CONFIG.fill.position_groups.definitions[group] or {}
end

local function fill_compute_position_shortages(team_id)
    local formation = get_formation_positions(team_id)
    if #formation == 0 then return {} end

    -- Note: fill drops GK from formation so position-shortage pass doesn't try
    -- to source goalkeepers via formation (GK is handled via group strategies).
    local demand = {}
    for _, p in ipairs(formation) do
        if p ~= "GK" then demand[p] = (demand[p] or 0) + 1 end
    end

    local have = fill_count_by_position(team_id)
    local shortages = {}
    for p, d in pairs(demand) do
        local s = d - (have[p] or 0)
        if s > 0 then shortages[#shortages + 1] = { position = p, shortage = s } end
    end
    table.sort(shortages, function(a, b) return a.shortage > b.shortage end)
    return shortages
end

-- Outfield formation positions (excludes GK). Used for formation-match strategies.
local function fill_formation_outfield(team_id)
    local formation = get_formation_positions(team_id)
    local result = {}
    for _, p in ipairs(formation) do
        if p ~= "GK" and pos_id_from_name(p) ~= 0 then result[#result + 1] = p end
    end
    return result
end

--------------------------------------------------------------------------------
-- Free agents (from the shared source team bucket).
--------------------------------------------------------------------------------
local function fill_get_free_agents()
    build_team_players_map()
    local list = {}
    for _, p_id in ipairs(team_players_map[CONFIG.shared.source_team_id] or {}) do
        local pc = player_cache[p_id]
        if pc then
            local age = pc.age
            if age >= CONFIG.fill.age_constraints.min and age <= CONFIG.fill.age_constraints.max then
                list[#list + 1] = {
                    playerid      = p_id,
                    overall       = pc.overall,
                    potential     = pc.potential or 0,
                    age           = age,
                    position_name = pc.positionName
                }
            end
        end
    end
    for i = #list, 2, -1 do
        local j = math.random(i)
        list[i], list[j] = list[j], list[i]
    end
    return list
end

--------------------------------------------------------------------------------
-- Candidate selectors (best-fit by overall; youth by highest potential).
--------------------------------------------------------------------------------
local function fill_pick_best_fit(free_agents, target_rating, predicate)
    local best_idx, best_player, best_dist = nil, nil, math.huge
    for i, p in ipairs(free_agents) do
        if predicate(p) then
            local d = math.abs(p.overall - target_rating)
            if d < best_dist then
                best_idx, best_player, best_dist = i, p, d
            end
        end
    end
    return best_idx, best_player
end

local function fill_pick_best_youth(free_agents, min_pot, max_age, predicate)
    local best_idx, best_player, best_pot = nil, nil, -1
    for i, p in ipairs(free_agents) do
        if p.age <= max_age and predicate(p) then
            local pot = p.potential or 0
            if pot >= min_pot and pot > best_pot then
                best_idx, best_player, best_pot = i, p, pot
            end
        end
    end
    if best_pot < 0 then best_pot = nil end
    return best_idx, best_player, best_pot
end

local function fill_youth_threshold(median_rating)
    local t = median_rating + CONFIG.fill.youth_thresholds.potential_bonus
    local cap = CONFIG.fill.youth_thresholds.potential_cap
    if cap and t > cap then t = cap end
    return t
end

local function fill_find_regular_at_position(free_agents, min_r, max_r, target_pos, target_r)
    local target = target_r or ((min_r + max_r) * 0.5)
    local i, p = fill_pick_best_fit(free_agents, target, function(x)
        return x.overall >= min_r and x.overall <= max_r and x.position_name == target_pos
    end)
    if i then return i, p, target_pos end
    return nil, nil, nil
end

local function fill_find_youth_at_position(free_agents, median_rating, target_pos)
    local min_pot = fill_youth_threshold(median_rating)
    local max_age = CONFIG.fill.youth_thresholds.max_age
    local i, p, pot = fill_pick_best_youth(free_agents, min_pot, max_age, function(x)
        return x.position_name == target_pos
    end)
    if i then return i, p, pot, target_pos end
    return nil, nil, nil, nil
end

local function fill_find_regular_in_group(free_agents, min_r, max_r, group, target_r)
    local set = {}
    for _, p in ipairs(fill_positions_in_group(group)) do set[p] = true end
    local target = target_r or ((min_r + max_r) * 0.5)
    local i, p = fill_pick_best_fit(free_agents, target, function(x)
        return x.overall >= min_r and x.overall <= max_r and set[x.position_name]
    end)
    if i then return i, p, group end
    return nil, nil, nil
end

local function fill_find_youth_in_group(free_agents, median_rating, group)
    local min_pot = fill_youth_threshold(median_rating)
    local max_age = CONFIG.fill.youth_thresholds.max_age
    local set = {}
    for _, p in ipairs(fill_positions_in_group(group)) do set[p] = true end
    local i, p, pot = fill_pick_best_youth(free_agents, min_pot, max_age, function(x)
        return set[x.position_name]
    end)
    if i then return i, p, pot, group end
    return nil, nil, nil, nil
end

local function fill_find_regular_in_formation(team_id, free_agents, min_r, max_r, target_r)
    local set = {}
    for _, p in ipairs(fill_formation_outfield(team_id)) do set[p] = true end
    if next(set) == nil then return nil, nil end
    local target = target_r or ((min_r + max_r) * 0.5)
    return fill_pick_best_fit(free_agents, target, function(x)
        return x.overall >= min_r and x.overall <= max_r and set[x.position_name]
    end)
end

local function fill_find_youth_in_formation(team_id, free_agents, median_rating)
    local set = {}
    for _, p in ipairs(fill_formation_outfield(team_id)) do set[p] = true end
    if next(set) == nil then return nil, nil, nil end
    local min_pot = fill_youth_threshold(median_rating)
    local max_age = CONFIG.fill.youth_thresholds.max_age
    return fill_pick_best_youth(free_agents, min_pot, max_age, function(x)
        return set[x.position_name]
    end)
end

local function fill_find_regular_any(free_agents, min_r, max_r, target_r)
    local target = target_r or ((min_r + max_r) * 0.5)
    return fill_pick_best_fit(free_agents, target, function(x)
        return x.overall >= min_r and x.overall <= max_r
    end)
end

local function fill_find_youth_any(free_agents, median_rating)
    local min_pot = fill_youth_threshold(median_rating)
    local max_age = CONFIG.fill.youth_thresholds.max_age
    return fill_pick_best_youth(free_agents, min_pot, max_age, function() return true end)
end

--------------------------------------------------------------------------------
-- Search strategy table. Order mirrors simplified_squad_filler.lua.
--------------------------------------------------------------------------------
local FILL_STRATEGIES = {
    { name = "Specific Position (Regular)", step = 1, requires_positions = true,
      is_youth = false, fn = fill_find_regular_at_position },
    { name = "Specific Position (Youth)",   step = 2, requires_positions = true,
      is_youth = true,  fn = fill_find_youth_at_position },
    { name = "Priority Groups (Regular)",   step = 3, requires_groups    = true,
      is_youth = false, fn = fill_find_regular_in_group },
    { name = "Priority Groups (Youth)",     step = 4, requires_groups    = true,
      is_youth = true,  fn = fill_find_youth_in_group },
    { name = "Formation (Regular)",         step = 5, requires_formation = true,
      is_youth = false, fn = fill_find_regular_in_formation },
    { name = "Formation (Youth)",           step = 6, requires_formation = true,
      is_youth = true,  fn = fill_find_youth_in_formation },
    { name = "Any Regular Player",          step = 7,
      is_youth = false, fn = fill_find_regular_any },
    { name = "Any Youth Player",            step = 8,
      is_youth = true,  fn = fill_find_youth_any }
}

local function fill_widened_bands(min_r, max_r)
    local bands = { {min_r, max_r} }
    local steps = CONFIG.fill.max_widen_steps or 0
    local step_size = CONFIG.fill.widen_step_size or 0
    for s = 1, steps do
        bands[#bands + 1] = { min_r - s * step_size, max_r + s * step_size }
    end
    return bands
end

local function fill_strategy_ok(strategy, ctx)
    if strategy.requires_positions and #ctx.position_shortages == 0 then return false end
    if strategy.requires_groups    and #ctx.underrepresented_groups == 0 then return false end
    if strategy.requires_formation and #ctx.formation_outfield == 0 then return false end
    return true
end

-- Execute a single strategy; returns a search_result or nil.
local function fill_execute_strategy(strategy, ctx)
    if not fill_strategy_ok(strategy, ctx) then return nil end

    local median = ctx.median_rating
    local function build_result(p_idx, player, group, potential, suffix, band)
        local step_str = string.format("Step %d: %s%s", strategy.step, strategy.name, suffix or "")
        if band and (band[1] ~= ctx.min_rating or band[2] ~= ctx.max_rating) then
            step_str = step_str .. string.format(" [widened %d..%d]", band[1], band[2])
        end
        return {
            player_index      = p_idx,
            suitable_player   = player,
            selected_group    = group,
            is_youth_transfer = strategy.is_youth,
            player_potential  = potential,
            search_step       = step_str
        }
    end

    if strategy.requires_positions then
        for _, entry in ipairs(ctx.position_shortages) do
            local target_pos = entry.position
            if strategy.is_youth then
                local i, p, pot, sel_pos = strategy.fn(ctx.free_agents, median, target_pos)
                if i then
                    return build_result(i, p, fill_position_to_group[sel_pos or target_pos], pot, " " .. target_pos)
                end
            else
                for _, band in ipairs(fill_widened_bands(ctx.min_rating, ctx.max_rating)) do
                    local i, p, sel_pos = strategy.fn(ctx.free_agents, band[1], band[2], target_pos, median)
                    if i then
                        return build_result(i, p, fill_position_to_group[sel_pos or target_pos], nil,
                                            " " .. target_pos, band)
                    end
                end
            end
        end
        return nil
    end

    if strategy.requires_groups then
        for _, group in ipairs(ctx.underrepresented_groups) do
            if strategy.is_youth then
                local i, p, pot, sel_group = strategy.fn(ctx.free_agents, median, group)
                if i then return build_result(i, p, sel_group, pot, " " .. group) end
            else
                for _, band in ipairs(fill_widened_bands(ctx.min_rating, ctx.max_rating)) do
                    local i, p, sel_group = strategy.fn(ctx.free_agents, band[1], band[2], group, median)
                    if i then return build_result(i, p, sel_group, nil, " " .. group, band) end
                end
            end
        end
        return nil
    end

    -- Formation / any-player pass.
    if strategy.is_youth then
        local i, p, pot
        if strategy.requires_formation then
            i, p, pot = strategy.fn(ctx.team_id, ctx.free_agents, median)
        else
            i, p, pot = strategy.fn(ctx.free_agents, median)
        end
        if i then return build_result(i, p, fill_position_to_group[p.position_name], pot) end
    else
        for _, band in ipairs(fill_widened_bands(ctx.min_rating, ctx.max_rating)) do
            local i, p
            if strategy.requires_formation then
                i, p = strategy.fn(ctx.team_id, ctx.free_agents, band[1], band[2], median)
            else
                i, p = strategy.fn(ctx.free_agents, band[1], band[2], median)
            end
            if i then return build_result(i, p, fill_position_to_group[p.position_name], nil, nil, band) end
        end
    end
    return nil
end

local function fill_find_for_team(ctx)
    for _, strategy in ipairs(FILL_STRATEGIES) do
        local result = fill_execute_strategy(strategy, ctx)
        if result then return result end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Transfer execution (fill-specific; uses shared rosters + caches).
--------------------------------------------------------------------------------
local function fill_transfer(player, team_id, free_agents, player_idx, search_result)
    local player_id = player.playerid
    local terms = CONFIG.fill.transfer_terms

    if team_id == CONFIG.shared.source_team_id then
        LOGGER:LogWarning(string.format(
            "Fill: skip transfer to free agent pool (%d). Player %d.",
            team_id, player_id
        ))
        return false
    end

    local ok, err = pcall(function()
        if IsPlayerPresigned(player_id) then DeletePresignedContract(player_id) end
        if IsPlayerLoanedOut(player_id) then TerminateLoan(player_id) end
        TransferPlayer(
            player_id, team_id,
            terms.sum, terms.wage, terms.contract_length,
            CONFIG.shared.source_team_id, terms.release_clause
        )
        -- Roles based on player's preferred position (unchanged here).
        if player.position_name then
            local pc = player_cache[player_id]
            if pc and pc.preferredposition1 and pc.preferredposition1 >= 0 then
                local roles = CONFIG.shared.positions_to_roles[player.position_name]
                if roles then
                    local r1, r2, r3 = roles[1], roles[2], roles[3]
                    if pc.preferredposition1 == 0 then r3 = 0 end
                    players_table:SetRecordFieldValue(pc.record_id, "role1", r1)
                    players_table:SetRecordFieldValue(pc.record_id, "role2", r2)
                    players_table:SetRecordFieldValue(pc.record_id, "role3", r3)
                end
            end
        end

        fill_update_size(team_id, 1)
        fill_update_size(CONFIG.shared.source_team_id, -1)
        team_roster_add(team_id, player_id)
        team_roster_remove(CONFIG.shared.source_team_id, player_id)
        fill_ratings_cache[team_id] = nil
    end)

    if ok then
        local old_size = fill_team_size(team_id) - 1
        local new_size = old_size + 1
        local step_str = search_result.search_step and string.format(" (%s)", search_result.search_step) or ""

        if search_result.is_youth_transfer and search_result.player_potential then
            LOGGER:LogInfo(string.format(
                "YOUTH: %s (%s, %d->%d pot, age %d) -> %s [%d->%d]%s",
                get_player_name_cached(player_id), player.position_name,
                player.overall, search_result.player_potential, player.age,
                get_team_name_cached(team_id), old_size, new_size, step_str
            ))
        else
            LOGGER:LogInfo(string.format(
                "%s (%s, %d, age %d) -> %s [%d->%d]%s",
                get_player_name_cached(player_id), player.position_name,
                player.overall, player.age,
                get_team_name_cached(team_id), old_size, new_size, step_str
            ))
        end

        table.remove(free_agents, player_idx)
        return true
    end

    LOGGER:LogWarning(string.format(
        "Fill transfer failed: %s -> %s (%s)",
        get_player_name_cached(player_id), get_team_name_cached(team_id), tostring(err)
    ))
    return false
end

--------------------------------------------------------------------------------
-- Team processing (single pass per iteration).
--------------------------------------------------------------------------------
local function fill_process_team(team_id, free_agents, permanently_failed)
    if permanently_failed[team_id] then return false, "permanently_excluded" end

    local size = fill_team_size(team_id)
    if size >= CONFIG.fill.target_squad_size or size >= CONFIG.fill.max_squad_size then
        return false, "target_reached"
    end

    local min_r, max_r, median = fill_bounds(team_id)
    if not min_r or not max_r or not median then
        LOGGER:LogInfo(string.format(
            "SKIP: %s - no rating data, skipping permanently", get_team_name_cached(team_id)
        ))
        permanently_failed[team_id] = true
        return false, "no_rating_data"
    end

    local groups = fill_underrepresented_groups(team_id, size)
    local display_name = fill_team_display_name(team_id)

    if #groups > 0 then
        LOGGER:LogInfo(string.format(
            "%s (squad: %d) -> targeting %d-%d rating, priority: [%s]",
            display_name, size, min_r, max_r, table.concat(groups, ", ")
        ))
    else
        LOGGER:LogInfo(string.format(
            "%s (squad: %d) -> targeting %d-%d rating, balanced squad",
            display_name, size, min_r, max_r
        ))
    end

    local ctx = {
        team_id                 = team_id,
        free_agents             = free_agents,
        min_rating              = min_r,
        max_rating              = max_r,
        median_rating           = median,
        underrepresented_groups = groups,
        formation_outfield      = fill_formation_outfield(team_id),
        position_shortages      = fill_compute_position_shortages(team_id)
    }

    local result = fill_find_for_team(ctx)
    if result then
        local ok = fill_transfer(result.suitable_player, team_id, free_agents,
                                 result.player_index, result)
        if ok then
            permanently_failed[team_id] = nil
            return true, "transfer_success"
        end
        LOGGER:LogWarning(string.format(
            "Fill transfer failed for %s - will retry", get_team_name_cached(team_id)
        ))
        return false, "transfer_failed"
    end

    LOGGER:LogInfo(string.format(
        "SKIP: %s - no suitable players found (rating %d-%d), skipping permanently",
        get_team_name_cached(team_id), min_r, max_r
    ))
    permanently_failed[team_id] = true
    return false, "no_suitable_players"
end

local function fill_teams_by_squad_size()
    local teams = {}
    build_league_team_map()
    for _, league_id in ipairs(CONFIG.shared.target_leagues) do
        for _, t_id in ipairs(league_team_map[league_id] or {}) do
            local size = fill_team_size(t_id)
            if size < CONFIG.fill.target_squad_size and size < CONFIG.fill.max_squad_size then
                teams[#teams + 1] = { team_id = t_id, squad_size = size }
            end
        end
    end
    table.sort(teams, function(a, b) return a.squad_size < b.squad_size end)
    return teams
end

function fill_phase.run()
    LOGGER:LogInfo("=== FILL PHASE ===")
    build_league_team_map()

    local free_agents = fill_get_free_agents()
    if #free_agents == 0 then
        LOGGER:LogInfo("No eligible free agents. Fill phase exits.")
        return
    end

    local total_transfers = 0
    local start_time = os.time()
    local permanently_failed = {}
    local iteration = 1

    LOGGER:LogInfo(string.format(
        "Starting fill: %d free agents -> target squad size %d",
        #free_agents, CONFIG.fill.target_squad_size
    ))
    LOGGER:LogInfo(string.format(
        "Youth: age <=%d, potential >= median + %d (cap %d).",
        CONFIG.fill.youth_thresholds.max_age,
        CONFIG.fill.youth_thresholds.potential_bonus,
        CONFIG.fill.youth_thresholds.potential_cap or 99
    ))

    while true do
        local all_teams = fill_teams_by_squad_size()
        if #all_teams == 0 then
            LOGGER:LogInfo("All teams have reached target squad size!")
            break
        end
        if #free_agents == 0 then
            LOGGER:LogInfo("No more free agents available!")
            break
        end

        -- Group by squad size and pick the smallest level with non-excluded teams.
        local by_size = {}
        for _, info in ipairs(all_teams) do
            if not permanently_failed[info.team_id] then
                by_size[info.squad_size] = by_size[info.squad_size] or {}
                table.insert(by_size[info.squad_size], info)
            end
        end

        local sizes = {}
        for s in pairs(by_size) do sizes[#sizes + 1] = s end
        table.sort(sizes)
        if #sizes == 0 then
            LOGGER:LogInfo("No processable teams at any squad size level.")
            break
        end

        local smallest_size   = sizes[1]
        local teams_at_level  = by_size[smallest_size]
        LOGGER:LogInfo(string.format(
            "Iteration %d: %d teams at squad size %d",
            iteration, #teams_at_level, smallest_size
        ))

        local this_iteration_transfers = 0
        for _, info in ipairs(teams_at_level) do
            local t_id = info.team_id
            if fill_team_size(t_id) == smallest_size then
                local success = fill_process_team(t_id, free_agents, permanently_failed)
                if success then
                    total_transfers = total_transfers + 1
                    this_iteration_transfers = this_iteration_transfers + 1
                end
            end
        end

        local excluded_count = 0
        for _ in pairs(permanently_failed) do excluded_count = excluded_count + 1 end
        LOGGER:LogInfo(string.format(
            "Iteration %d complete: %d transfers (+%d total). %d agents left, %d teams excluded",
            iteration, this_iteration_transfers, total_transfers, #free_agents, excluded_count
        ))

        -- If we got zero transfers at the current smallest-size level, we need
        -- to know whether to stop or move on to a higher level.
        if this_iteration_transfers == 0 then
            local has_higher = false
            for _, info in ipairs(all_teams) do
                if info.squad_size > smallest_size and not permanently_failed[info.team_id] then
                    has_higher = true; break
                end
            end
            if not has_higher then
                LOGGER:LogInfo("No more teams available at any squad size level.")
                break
            end
        end

        iteration = iteration + 1
        if iteration % 25 == 0 then
            LOGGER:LogInfo(string.format(
                "Extended run: iteration %d, total %d, elapsed %ds",
                iteration, total_transfers, os.time() - start_time
            ))
        end
    end

    local elapsed = os.time() - start_time
    local final_teams = fill_teams_by_squad_size()
    local excluded_count = 0
    for _ in pairs(permanently_failed) do excluded_count = excluded_count + 1 end

    LOGGER:LogInfo("=== Fill run summary ===")
    LOGGER:LogInfo(string.format(
        "Fill transfers: %d in %d iterations (%ds). %d agents left, %d teams still need players, %d permanently excluded.",
        total_transfers, iteration - 1, elapsed, #free_agents, #final_teams, excluded_count
    ))

    fill_phase.summary = {
        transfers       = total_transfers,
        iterations      = iteration - 1,
        elapsed         = elapsed,
        agents_left     = #free_agents,
        teams_remaining = #final_teams,
        teams_excluded  = excluded_count
    }
end

--==============================================================================
-- MAIN
--==============================================================================
local function main()
    math.randomseed(os.time())
    LOGGER:LogInfo("Starting combined squad management script...")
    LOGGER:LogInfo(string.format(
        "Phases: release=%s transfer=%s upgrade=%s fill=%s",
        tostring(CONFIG.phases.release),
        tostring(CONFIG.phases.transfer),
        tostring(CONFIG.phases.upgrade),
        tostring(CONFIG.phases.fill)
    ))

    -- Build shared caches up front so every enabled phase starts instantly.
    build_player_cache()
    build_team_players_map()
    build_formations_map()
    build_league_team_map()

    local overall_start = os.time()

    if CONFIG.phases.release then
        release_phase.run()
    else
        LOGGER:LogInfo("Release phase disabled.")
    end

    if CONFIG.phases.transfer then
        transfer_phase.run()
    else
        LOGGER:LogInfo("Transfer phase disabled.")
    end

    if CONFIG.phases.upgrade then
        upgrade_phase.run()
    else
        LOGGER:LogInfo("Upgrade phase disabled.")
    end

    if CONFIG.phases.fill then
        fill_phase.run()
    else
        LOGGER:LogInfo("Fill phase disabled.")
    end

    local total_elapsed = os.time() - overall_start

    -- Combined summary
    local function get_or_empty(t) return t or {} end
    local r_sum = get_or_empty(release_phase.summary)
    local t_sum = get_or_empty(transfer_phase.summary)
    local u_sum = get_or_empty(upgrade_phase.summary)
    local f_sum = get_or_empty(fill_phase.summary)
    local r_stats = r_sum.stats or {}
    local t_stats = t_sum.stats or {}
    local u_stats = u_sum.stats or {}

    local parts = { string.format("Total elapsed: %ds.", total_elapsed) }

    if CONFIG.phases.release then
        parts[#parts + 1] = string.format(
            "Release: %d teams (err %d). Converted %d (step2 %d / cover %d). Released %d (step3 %d / step4 %d). Youth: prot %d / rel %d.",
            r_sum.teams_success or 0, r_sum.teams_error or 0,
            (r_stats.conversions or 0) + (r_stats.cover_conversions or 0),
            r_stats.conversions or 0, r_stats.cover_conversions or 0,
            (r_stats.releases_step3 or 0) + (r_stats.releases_step4 or 0),
            r_stats.releases_step3 or 0, r_stats.releases_step4 or 0,
            r_stats.youth_protected or 0, r_stats.youth_released or 0
        )
    end

    if CONFIG.phases.transfer then
        parts[#parts + 1] = string.format(
            "Transfer: signed %d (normal %d / alt %d / youth %d, widened %d). Unfilled %d, abandoned %d, failed %d.",
            t_stats.transfers_total or 0, t_stats.transfers_normal or 0,
            t_stats.transfers_alt or 0, t_stats.transfers_youth or 0,
            t_stats.transfers_widened or 0,
            t_stats.slots_unfilled or 0, t_stats.slots_abandoned or 0, t_stats.slots_failed or 0
        )
    end

    if CONFIG.phases.upgrade then
        parts[#parts + 1] = string.format(
            "Upgrade: %d signed, %d failed, %d had no FA in band. Cleanup releases: %d. Priorities: %d. Teams full skipped: %d.",
            u_stats.upgrades_made or 0, u_stats.upgrades_failed or 0,
            u_stats.upgrades_no_fa or 0, u_stats.cleanup_releases or 0,
            u_stats.priorities_found or 0, u_stats.teams_full_skipped or 0
        )
    end

    if CONFIG.phases.fill then
        parts[#parts + 1] = string.format(
            "Fill: %d transfers in %d iterations. %d agents left, %d teams still needing players, %d permanently excluded.",
            f_sum.transfers or 0, f_sum.iterations or 0,
            f_sum.agents_left or 0, f_sum.teams_remaining or 0, f_sum.teams_excluded or 0
        )
    end

    LOGGER:LogInfo("=== Combined run summary ===")
    for _, line in ipairs(parts) do LOGGER:LogInfo(line) end

    MessageBox("Squad Management Complete", table.concat(parts, "\n"))
end

main()
