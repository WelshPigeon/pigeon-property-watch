--[[
    Pigeon Property Watch: core logic.

    Pure Lua with no FiveM or database calls: deciding which properties are inactive, reading keyholder
    lists, building Discord messages within Discord's limits, and working out the schedule. The server
    loads it as the PropertyWatch table; the tests in tests/ run it in plain Lua 5.4.
]]

local Core = {}

local DAY = 86400

-- Discord's limits for webhook messages. https://discord.com/developers/docs/resources/message#embed-object-embed-limits
Core.DISCORD = {
    fieldsPerEmbed = 25,
    fieldName = 256,
    fieldValue = 1024,
    title = 256,
    description = 4096,
    footer = 2048,
    content = 2000,
    totalCharacters = 6000,
}

---------------------------------------------------------------------------
-- Text helpers

--- Trims and shortens text to `limit` characters (counting UTF-8 characters, not bytes).
function Core.truncate(text, limit)
    text = tostring(text or ''):gsub('^%s+', ''):gsub('%s+$', '')
    local length = utf8.len(text)
    if not length then
        -- Invalid UTF-8: drop anything that isn't plain ASCII.
        text = text:gsub('[\128-\255]', '')
        length = #text
    end
    if length <= limit then return text end
    -- Keep limit - 1 characters, then the ellipsis, so the result is exactly `limit` characters at most.
    local cut = utf8.offset(text, limit)
    return (text:sub(1, cut - 1):gsub('[%s,;]+$', '')) .. '…'
end

--- Makes text safe for Discord: no mentions, no markdown that could break formatting, no control characters.
function Core.discordSafe(text)
    text = tostring(text or '')
    text = text:gsub('%c', ' ')
    text = text:gsub('@', '@\u{200B}')            -- stop @everyone, @here and user mentions
    text = text:gsub('([\\`*_~|>#%[%]()])', '\\%1') -- escape markdown
    text = text:gsub('%s+', ' ')
    return (text:gsub('^%s+', ''):gsub('%s+$', ''))
end

---------------------------------------------------------------------------
-- Keyholders

--- Reads a keyholder list stored as JSON in any of the common shapes:
---   ["CID1", "CID2"]                       (qbx_properties)
---   {"CID1": {...}, "CID2": true}          (nolag_properties)
---   [{"citizenid": "CID1"}, ...]           (other housing scripts)
---   "CID1, CID2"                           (plain text)
--- Returns a list of unique identifiers, in a stable order.
---@param raw any the column value: a JSON string, an already-decoded table, or nil
---@param decode function json.decode
function Core.parseKeyholders(raw, decode)
    local list, seen = {}, {}
    local function add(value)
        if value == nil then return end
        value = tostring(value):gsub('^%s+', ''):gsub('%s+$', '')
        if value == '' or value:lower() == 'none' or value:lower() == 'null' or seen[value] then return end
        seen[value] = true
        list[#list + 1] = value
    end

    local data = raw
    if type(raw) == 'string' then
        if raw:match('^%s*$') then return list end
        local ok, decoded = pcall(decode, raw)
        if ok and type(decoded) == 'table' then
            data = decoded
        else
            for token in raw:gmatch('[^,;%s]+') do add(token) end
            return list
        end
    end
    if type(data) ~= 'table' then return list end

    if #data > 0 then
        for _, entry in ipairs(data) do
            if type(entry) == 'table' then
                add(entry.citizenid or entry.identifier or entry.cid or entry.citizen_id or entry.id)
            elseif type(entry) == 'string' or type(entry) == 'number' then
                add(entry)
            end
        end
    else
        local keys = {}
        for key, value in pairs(data) do
            if type(key) == 'string' then
                keys[#keys + 1] = key
            elseif type(value) == 'string' then
                keys[#keys + 1] = value
            end
        end
        table.sort(keys)
        for _, key in ipairs(keys) do add(key) end
    end

    return list
end

---------------------------------------------------------------------------
-- Inactivity

--- Sorts properties into inactive and warning lists.
---@param properties table[] { system, id, label, address, owner, ownerType, keyholders, lastActivity (unix seconds) }
---@param now number unix seconds
---@param options table { inactiveDays, warnDays (number or false), ignore (set of ids) }
---@return table[] inactive, table[] warning   both sorted longest-inactive first, each item gets .days
function Core.classify(properties, now, options)
    local inactive, warning = {}, {}
    local ignore = options.ignore or {}
    local inactiveDays = options.inactiveDays
    local warnDays = options.warnDays

    for _, property in ipairs(properties) do
        local last = tonumber(property.lastActivity)
        if last and not ignore[property.id] and not ignore[tostring(property.id)] then
            local days = math.floor((now - last) / DAY)
            if days < 0 then days = 0 end
            property.days = days
            if days >= inactiveDays then
                inactive[#inactive + 1] = property
            elseif warnDays and days >= warnDays then
                warning[#warning + 1] = property
            end
        end
    end

    local function longestFirst(a, b)
        if a.days ~= b.days then return a.days > b.days end
        return tostring(a.id) < tostring(b.id)
    end
    table.sort(inactive, longestFirst)
    table.sort(warning, longestFirst)
    return inactive, warning
end

--- A key that identifies one stretch of inactivity for one property at one level, so each is reported once.
--- It changes whenever someone uses the property (lastActivity changes) or the owner changes.
function Core.noticeKey(property, level)
    return ('%s:%s:%s:%s:%s'):format(property.system, tostring(property.id), level, tostring(property.owner or ''), tostring(math.floor(tonumber(property.lastActivity) or 0)))
end

---------------------------------------------------------------------------
-- Discord messages

--- Builds the text for one property.
---@param property table
---@param names table<string, string> identifier -> display name
---@param t function locale lookup t(key, values)
function Core.describeProperty(property, names, t)
    local title = property.label and property.label ~= '' and property.label or nil
    local address = property.address and property.address ~= '' and property.address or nil
    local heading
    if title and address and title ~= address then
        heading = ('%s · %s'):format(title, address)
    else
        heading = title or address or t('property_id', { id = property.id })
    end
    heading = ('#%s %s'):format(tostring(property.id), Core.discordSafe(heading))

    local function person(identifier)
        local name = names[identifier]
        if name and name ~= '' then
            return ('%s (`%s`)'):format(Core.discordSafe(name), Core.discordSafe(identifier))
        end
        return ('`%s`'):format(Core.discordSafe(identifier))
    end

    local lines = {}
    if property.owner then
        local key = property.ownerType == 'society' and 'owner_society' or 'owner'
        lines[#lines + 1] = t(key, { owner = person(property.owner) })
    end

    local holders = {}
    for _, identifier in ipairs(property.keyholders or {}) do
        if identifier ~= property.owner then holders[#holders + 1] = person(identifier) end
    end
    if #holders > 0 then
        lines[#lines + 1] = t('keyholders', { keyholders = table.concat(holders, ', ') })
    end

    lines[#lines + 1] = t('last_used', { days = property.days, timestamp = ('<t:%d:R>'):format(math.floor(property.lastActivity)) })

    return Core.truncate(heading, Core.DISCORD.fieldName),
        Core.truncate(table.concat(lines, '\n'), Core.DISCORD.fieldValue)
end

--- Splits properties into Discord webhook payloads that each stay within Discord's limits.
---@param properties table[] already classified (each has .days)
---@param level string 'inactive' or 'warning'
---@param options table { names, t, perMessage, username, avatar, colour, mentionRole, days, total }
---@return table[] payloads ready for json.encode
function Core.buildMessages(properties, level, options)
    local t = options.t
    local perMessage = math.max(1, math.min(options.perMessage or 10, Core.DISCORD.fieldsPerEmbed))
    local payloads = {}

    local function newPayload(page, pages)
        local title = t(level == 'warning' and 'title_warning' or 'title_inactive', { count = #properties, days = options.days })
        if pages > 1 then title = title .. t('page', { page = page, pages = pages }) end
        local payload = {
            username = Core.truncate(options.username or 'Property Watch', 80),
            avatar_url = options.avatar,
            allowed_mentions = { parse = {}, roles = {} },
            embeds = { {
                title = Core.truncate(title, Core.DISCORD.title),
                color = options.colour or (level == 'warning' and 0xF5A524 or 0xE5484D),
                fields = {},
                footer = { text = Core.truncate(t('footer', { system = options.system or '' }), Core.DISCORD.footer) },
                timestamp = options.timestamp,
            } },
        }
        if page == 1 then
            local intro = t(level == 'warning' and 'intro_warning' or 'intro_inactive', { count = #properties, days = options.days, remaining = options.remaining })
            if options.mentionRole then
                payload.content = Core.truncate(('<@&%s> %s'):format(options.mentionRole, intro), Core.DISCORD.content)
                payload.allowed_mentions.roles = { tostring(options.mentionRole) }
            else
                payload.content = Core.truncate(intro, Core.DISCORD.content)
            end
        end
        return payload
    end

    local function size(payload)
        local embed = payload.embeds[1]
        local total = #(embed.title or '') + #(embed.footer.text or '')
        for _, field in ipairs(embed.fields) do total = total + #field.name + #field.value end
        return total
    end

    -- First pass: split by field count and total size.
    local groups, current, currentSize = {}, {}, 0
    local overhead = 600 -- title, footer and timestamp, with room to spare
    for _, property in ipairs(properties) do
        local name, value = Core.describeProperty(property, options.names or {}, t)
        local cost = #name + #value
        if #current >= perMessage or (currentSize + cost + overhead) > Core.DISCORD.totalCharacters then
            groups[#groups + 1] = current
            current, currentSize = {}, 0
        end
        current[#current + 1] = { name = name, value = value, inline = false }
        currentSize = currentSize + cost
    end
    if #current > 0 then groups[#groups + 1] = current end

    for page, fields in ipairs(groups) do
        local payload = newPayload(page, #groups)
        payload.embeds[1].fields = fields
        assert(size(payload) <= Core.DISCORD.totalCharacters, 'message too large')
        payloads[#payloads + 1] = payload
    end
    return payloads
end

---------------------------------------------------------------------------
-- Schedule

--- Parses "HH:MM" (24-hour). Returns hours, minutes or nil.
function Core.parseTime(text)
    local h, m = tostring(text or ''):match('^%s*(%d%d?):(%d%d)%s*$')
    h, m = tonumber(h), tonumber(m)
    if not h or h > 23 or m > 59 then return nil end
    return h, m
end

--- Decides whether a scheduled check is due.
---@param schedule table { daily = 'HH:MM' } or { everyHours = n }
---@param clock table os.date('*t') for now
---@param now number unix seconds
---@param state table { lastRunDay = 'YYYY-MM-DD', lastRun = unix }  (updated when due)
function Core.isDue(schedule, clock, now, state)
    if schedule.daily then
        local h, m = Core.parseTime(schedule.daily)
        if not h then return false end
        local today = ('%04d-%02d-%02d'):format(clock.year, clock.month, clock.day)
        local minutesNow = clock.hour * 60 + clock.min
        if state.lastRunDay ~= today and minutesNow >= h * 60 + m then
            state.lastRunDay = today
            state.lastRun = now
            return true
        end
        return false
    end

    local hours = tonumber(schedule.everyHours)
    if hours and hours > 0 then
        if not state.lastRun or now - state.lastRun >= hours * 3600 then
            state.lastRun = now
            return true
        end
    end
    return false
end

PropertyWatch = Core
return Core
