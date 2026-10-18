--[[
    Pigeon Property Watch: server.

    Creates its tables, keeps the qbx_properties activity record up to date, runs checks on schedule,
    sends reports to Discord, and provides the staff command and exports.
]]

local Core = PropertyWatch
local Systems = PropertyWatchSystems
local Names = PropertyWatchNames
local Q = PropertyWatchQueries

local RESOURCE = GetCurrentResourceName()
local SEND_GAP_MS = 2500        -- Discord allows about 30 webhook messages a minute; stay well under
local ready = false
local checking = false

---------------------------------------------------------------------------
-- Text and logging

local strings = Locales[Config.Locale] or Locales.en

local function t(key, values)
    local text = strings[key] or Locales.en[key] or key
    return (text:gsub('{(%w+)}', function(name)
        local value = values and values[name]
        if value == nil then return '{' .. name .. '}' end
        return tostring(value)
    end))
end

local function log(message, colour)
    print(('%s[%s]^7 %s'):format(colour or '^5', RESOURCE, message))
end

local function warn(message)
    log(message, '^3')
end

---------------------------------------------------------------------------
-- Settings checks

local warnDays = Config.WarnDays
if warnDays and (type(warnDays) ~= 'number' or warnDays <= 0 or warnDays >= Config.InactiveDays) then
    warn(('Config.WarnDays (%s) must be lower than Config.InactiveDays (%s). Warnings are off.'):format(tostring(warnDays), tostring(Config.InactiveDays)))
    warnDays = false
end

local ignore = {}
for _, id in ipairs(Config.IgnoreProperties or {}) do
    ignore[id] = true
    ignore[tostring(id)] = true
end

local function webhookUrl()
    local fromConvar = GetConvar('pigeon_property_watch_webhook', '')
    if fromConvar ~= '' then return fromConvar end
    return Config.Discord.webhook or ''
end

---------------------------------------------------------------------------
-- Database

local function createTables()
    MySQL.query.await(Q.createActivity)
    MySQL.query.await(Q.createNotices)
end

local function alreadySent(keys)
    local sent = {}
    if #keys == 0 then return sent end
    for start = 1, #keys, 200 do
        local batch = { table.unpack(keys, start, math.min(start + 199, #keys)) }
        local rows = MySQL.query.await(Q.noticesSent(#batch), batch) or {}
        for _, row in ipairs(rows) do sent[row.notice_key] = true end
    end
    return sent
end

local function markSent(properties, level)
    for _, property in ipairs(properties) do
        MySQL.insert.await(Q.noticeInsert, {
            Core.noticeKey(property, level), property.system, tostring(property.id), level,
        })
    end
end

---------------------------------------------------------------------------
-- Discord

--- Sends one webhook message and waits for Discord's answer. Retries once if rate-limited.
local function post(url, payload)
    local body = json.encode(payload)
    for attempt = 1, 2 do
        local result = promise.new()
        PerformHttpRequest(url, function(status) result:resolve(status) end, 'POST', body, { ['Content-Type'] = 'application/json' })
        local status = Citizen.Await(result)
        if status and status >= 200 and status < 300 then return true end
        if status == 429 and attempt == 1 then
            Wait(10000)
        else
            warn(t('webhook_failed', { status = tostring(status) }))
            return false
        end
    end
    return false
end

--- Sends a list of properties for one level. Returns how many messages went, and whether all were accepted.
local function report(url, properties, level, names, systemKey)
    if #properties == 0 then return 0, true end

    local serverName = Config.Discord.serverName ~= '' and Config.Discord.serverName or nil
    local messages = Core.buildMessages(properties, level, {
        names = names,
        t = t,
        perMessage = Config.Discord.perMessage,
        username = serverName and (serverName .. ' · Property Watch') or 'Property Watch',
        avatar = Config.Discord.avatar,
        mentionRole = Config.Discord.mentionRole,
        days = Config.InactiveDays,
        remaining = warnDays and (Config.InactiveDays - warnDays) or nil,
        system = Systems[systemKey].label,
        timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    })

    local allSent = true
    for i, message in ipairs(messages) do
        if i > 1 then Wait(SEND_GAP_MS) end
        if not post(url, message) then
            allSent = false
            break
        end
    end
    return #messages, allSent
end

---------------------------------------------------------------------------
-- Checking

--- Reads every owned property and sorts them into inactive and warning lists.
--- Returns inactive, warning, owned count and system key, or nil if no housing system is available.
local function gather()
    local systemKey = Systems.detect()
    if not systemKey then return nil end
    local system = Systems[systemKey]

    if system.sync then
        local added = system.sync()
        if added > 0 then log(t('baseline', { count = added })) end
    end

    local properties, dbNow = system.fetch()
    local inactive, warning = Core.classify(properties, dbNow or os.time(), {
        inactiveDays = Config.InactiveDays,
        warnDays = warnDays,
        ignore = ignore,
    })
    return inactive, warning, #properties, systemKey
end

--- Runs a check and reports to Discord.
---@param mode 'new'|'all'|'status'
---@return string summary
local function check(mode)
    if not ready then return 'Not ready yet: waiting for the database.' end
    if checking then return 'A check is already running.' end
    checking = true

    local ok, summary = pcall(function()
        local inactive, warning, owned, systemKey = gather()
        if not inactive then return t('no_system') end

        local statusLine = t('status', {
            system = Systems[systemKey].label, owned = owned, inactive = #inactive, warning = #warning, days = Config.InactiveDays,
        })
        if mode == 'status' then return statusLine end

        if mode == 'new' then
            local keys = {}
            for _, p in ipairs(inactive) do keys[#keys + 1] = Core.noticeKey(p, 'inactive') end
            for _, p in ipairs(warning) do keys[#keys + 1] = Core.noticeKey(p, 'warning') end
            local sent = alreadySent(keys)
            local function unsent(list, level)
                local out = {}
                for _, p in ipairs(list) do
                    if not sent[Core.noticeKey(p, level)] then out[#out + 1] = p end
                end
                return out
            end
            inactive, warning = unsent(inactive, 'inactive'), unsent(warning, 'warning')
        end

        if #inactive == 0 and #warning == 0 then
            return t('nothing_new', { owned = owned })
        end

        local url = webhookUrl()
        if url == '' then return statusLine .. ' ' .. t('no_webhook') end

        local identifiers = {}
        for _, list in ipairs({ inactive, warning }) do
            for _, p in ipairs(list) do
                if p.owner then identifiers[#identifiers + 1] = p.owner end
                for _, k in ipairs(p.keyholders or {}) do identifiers[#identifiers + 1] = k end
            end
        end
        local names = Names.lookup(identifiers)

        local messages = 0
        local count, okInactive = report(url, inactive, 'inactive', names, systemKey)
        messages = messages + count
        if okInactive then markSent(inactive, 'inactive') end
        if count > 0 and #warning > 0 then Wait(SEND_GAP_MS) end
        local warnCount, okWarning = report(url, warning, 'warning', names, systemKey)
        messages = messages + warnCount
        if okWarning then markSent(warning, 'warning') end

        return t('sent', { inactive = #inactive, warning = #warning, messages = messages })
    end)

    checking = false
    if not ok then
        warn(('Check failed: %s'):format(tostring(summary)))
        return 'Check failed. See the server console.'
    end
    return summary
end

---------------------------------------------------------------------------
-- qbx_properties activity

-- qbx_properties sets the player's currentPropertyId metadata when they go in, and clears it when they leave.
-- qbx_core reports every metadata change with this server event; record both going in and coming out.
AddEventHandler('qbx_core:server:onSetMetaData', function(key, oldValue, value)
    if key ~= 'currentPropertyId' or not ready then return end
    if Systems.detect() ~= 'qbx_properties' then return end
    local propertyId = value or oldValue
    if propertyId then
        CreateThread(function() Systems.qbx_properties.markActive(propertyId) end)
    end
end)

--- Records properties that online players are inside right now (after a restart, for example).
local function recordPlayersInside()
    if Systems.detect() ~= 'qbx_properties' or GetResourceState('qbx_core') ~= 'started' then return end
    local ok, players = pcall(function() return exports.qbx_core:GetQBPlayers() end)
    if not ok or type(players) ~= 'table' then return end
    for _, player in pairs(players) do
        local propertyId = player.PlayerData and player.PlayerData.metadata and player.PlayerData.metadata.currentPropertyId
        if propertyId then Systems.qbx_properties.markActive(propertyId) end
    end
end

---------------------------------------------------------------------------
-- Schedule

local function describeNext()
    if Config.Schedule.daily then return ('daily at %s'):format(Config.Schedule.daily) end
    if Config.Schedule.everyHours then return ('every %s hours'):format(Config.Schedule.everyHours) end
    return 'never (Config.Schedule is empty)'
end

MySQL.ready(function()
    local ok, problem = pcall(createTables)
    if not ok then
        warn(('Couldn\'t create database tables: %s'):format(tostring(problem)))
        return
    end
    ready = true

    local systemKey = Systems.detect()
    if systemKey then
        log(t('system_detected', { system = Systems[systemKey].label, next = describeNext() }))
    else
        warn(t('no_system'))
    end

    if Config.Schedule.daily and not Core.parseTime(Config.Schedule.daily) then
        warn(('Config.Schedule.daily must be a 24-hour time such as \'18:00\', not "%s". Scheduled checks are off.'):format(tostring(Config.Schedule.daily)))
    end

    CreateThread(function()
        local state = {}
        local now = os.time()
        if not Config.CheckOnStart then
            -- Don't run straight away just because today's time has already passed.
            local clock = os.date('*t', now)
            if Config.Schedule.daily then
                local h, m = Core.parseTime(Config.Schedule.daily)
                if h and clock.hour * 60 + clock.min >= h * 60 + m then
                    state.lastRunDay = ('%04d-%02d-%02d'):format(clock.year, clock.month, clock.day)
                end
            else
                state.lastRun = now
            end
        end

        Wait(60000) -- let the housing resource and framework finish starting
        recordPlayersInside()

        while true do
            local current = os.time()
            if Core.isDue(Config.Schedule, os.date('*t', current), current, state) then
                local summary = check(Config.ReportMode == 'all' and 'all' or 'new')
                if Config.LogToConsole then log(summary) end
            end
            Wait(30000)
        end
    end)
end)

---------------------------------------------------------------------------
-- Command

RegisterCommand(Config.Command, function(source, args)
    if source ~= 0 and not IsPlayerAceAllowed(source, Config.Permission) then
        TriggerClientEvent('chat:addMessage', source, { color = { 240, 110, 110 }, args = { 'Property Watch', t('command_no_permission') } })
        return
    end

    local action = (args[1] or 'check'):lower()
    local mode = ({ check = 'new', all = 'all', status = 'status' })[action]

    local function reply(message)
        if source == 0 then
            log(message)
        else
            TriggerClientEvent('chat:addMessage', source, { color = { 167, 139, 250 }, multiline = true, args = { 'Property Watch', message } })
        end
    end

    if not mode then
        return reply(t('command_help', { command = Config.Command }))
    end

    if mode ~= 'status' then reply(t('command_started')) end
    CreateThread(function()
        reply(check(mode))
    end)
end, false)

---------------------------------------------------------------------------
-- Exports

--- Returns the current inactive and warning properties, without reporting them.
--- exports['pigeon-property-watch']:GetInactiveProperties() -> inactive, warning
exports('GetInactiveProperties', function()
    if not ready then return {}, {} end
    local inactive, warning = gather()
    return inactive or {}, warning or {}
end)

--- Records that a qbx_properties property was used just now, for custom resources that let players
--- use a property without going inside (for example a garage or a stash at the door).
--- exports['pigeon-property-watch']:MarkActive(propertyId) -> true if recorded
exports('MarkActive', function(propertyId)
    if not ready or Systems.detect() ~= 'qbx_properties' then return false end
    return Systems.qbx_properties.markActive(propertyId)
end)

--- Runs a check now, as the scheduled check would. Returns a one-line summary.
--- exports['pigeon-property-watch']:Check()
exports('Check', function()
    return check(Config.ReportMode == 'all' and 'all' or 'new')
end)
