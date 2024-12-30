local function logConfigSummary(config)
    LOGGER:LogInfo("----- Configuration Summary -----")

    -- Position IDs
    LOGGER:LogInfo("Position IDs:")
    for role, ids in pairs(config.position_ids) do
        LOGGER:LogInfo(string.format("  Role: %s -> IDs: %s", role, table.concat(ids, ", ")))
    end

    -- Position Groups
    LOGGER:LogInfo("Position Groups:")
    for role, group in pairs(config.positionToGroup) do
        LOGGER:LogInfo(string.format("  Role: %s -> Group: %s", role, group))
    end

    -- Alternative Positions
    LOGGER:LogInfo("Alternative Positions:")
    for role, alternatives in pairs(config.alternative_positions) do
        LOGGER:LogInfo(string.format("  Role: %s -> Alternatives: %s", role, table.concat(alternatives, ", ")))
    end

    -- League Constraints
    LOGGER:LogInfo("League Constraints:")
    for league_id, constraints in pairs(config.league_constraints) do
        LOGGER:LogInfo(string.format("  League ID: %d", league_id))
        LOGGER:LogInfo(string.format("    Min Overall: %d", constraints.min_overall))
        LOGGER:LogInfo(string.format("    Max Overall: %d", constraints.max_overall))
        LOGGER:LogInfo(string.format("    Min Potential: %d", constraints.min_potential))
        LOGGER:LogInfo(string.format("    Max Potential: %d", constraints.max_potential))
    end

    -- Age Constraints
    LOGGER:LogInfo("Age Constraints:")
    LOGGER:LogInfo(string.format("  Minimum Age: %d", config.age_constraints.min))
    LOGGER:LogInfo(string.format("  Maximum Age: %d", config.age_constraints.max))

    -- Squad Size
    LOGGER:LogInfo("Squad Size:")
    LOGGER:LogInfo(string.format("  Max Squad Size: %d", config.squad_size))

    -- Target Leagues
    LOGGER:LogInfo("Target Leagues:")
    LOGGER:LogInfo(string.format("  Leagues: %s", table.concat(config.target_leagues, ", ")))

    -- Excluded Teams
    LOGGER:LogInfo("Excluded Teams:")
    if next(config.excluded_teams) then
        for team_id, _ in pairs(config.excluded_teams) do
            LOGGER:LogInfo(string.format("  Team ID: %d", team_id))
        end
    else
        LOGGER:LogInfo("  None")
    end

    -- Transfer Parameters
    LOGGER:LogInfo("Transfer Parameters:")
    LOGGER:LogInfo(string.format("  Transfer Sum: %d", config.transfer.sum))
    LOGGER:LogInfo(string.format("  Wage: %d", config.transfer.wage))
    LOGGER:LogInfo(string.format("  Contract Length: %d months", config.transfer.contract_length))
    LOGGER:LogInfo(string.format("  Release Clause: %d", config.transfer.release_clause))
    LOGGER:LogInfo(string.format("  From Team ID: %d", config.transfer.from_team_id))

    LOGGER:LogInfo("---------------------------------")
end

return {
    logConfigSummary = logConfigSummary
}
