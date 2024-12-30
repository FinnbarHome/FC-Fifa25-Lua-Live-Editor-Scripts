local function logTable(table, indent)
    indent = indent or 0
    local prefix = string.rep("  ", indent)

    if not table or type(table) ~= "table" then
        LOGGER:LogInfo(prefix .. "nil or invalid table")
        return
    end

    for key, value in pairs(table) do
        if value == nil then
            LOGGER:LogInfo(string.format("%sWarning: Key '%s' is nil or missing.", prefix, tostring(key)))
        elseif type(value) == "table" then
            LOGGER:LogInfo(string.format("%s%s:", prefix, tostring(key)))
            logTable(value, indent + 1)
        else
            LOGGER:LogInfo(string.format("%s%s: %s", prefix, tostring(key), tostring(value)))
        end
    end
end



local function logConfigSummary(config)
    LOGGER:LogInfo("----- Configuration Summary -----")
    logTable(config)
    LOGGER:LogInfo("---------------------------------")
end

return {
    logConfigSummary = logConfigSummary
}
