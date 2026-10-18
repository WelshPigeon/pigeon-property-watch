--[[
    Tests for server/main.lua, server/systems.lua and server/names.lua.

    Loads the real resource files in plain Lua 5.4 with a simulated FiveM server and database:
    threads and waits, oxmysql (answering the resource's queries from in-memory tables), Discord
    webhooks, ACE permissions, convars and exports.

    Run from the repository root:
        lua tests/resource.test.lua
]]

local json = dofile('tests/json.lua')

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        io.write(('  \27[31mFAIL\27[0m  %s%s\n'):format(name, detail ~= nil and ('\n          ' .. tostring(detail)) or ''))
    end
end

local DAY = 86400
local NOW = 1800000000

---------------------------------------------------------------------------
-- Simulated server

local function newServer(options)
    options = options or {}
    local s = {
        now = NOW,
        threads = {},
        commands = {},
        handlers = {},
        exports = {},
        printed = {},
        chat = {},
        posts = {},              -- Discord webhook bodies
        httpStatuses = options.httpStatuses or {},
        resources = options.resources or { nolag_properties = 'started', qbx_core = 'started' },
        convars = options.convars or { pigeon_property_watch_webhook = 'https://discord.com/api/webhooks/1/x' },
        aces = options.aces or {},
        -- database
        nolag = options.nolag or {},           -- rows: { id, label, address, keyholders, owner_type, owner, last }
        qbx = options.qbx or {},               -- rows: { id, property_name, keyholders, owner }
        activity = {},                         -- [propertyId] = { owner, last }
        notices = {},                          -- [key] = true
        players = options.players or {},       -- citizenid -> { firstname, lastname }
        queries = {},
    }

    local function db(sql, params)
        s.queries[#s.queries + 1] = { sql = sql, params = params }
        if sql:find('CREATE TABLE') then return {} end

        if sql:find('INNER JOIN `properties_owners`') then
            local includeSociety = params[1] == 1
            local rows = {}
            for _, r in ipairs(s.nolag) do
                if r.owner and (r.owner_type == 'user' or includeSociety) then
                    rows[#rows + 1] = { id = r.id, label = r.label, address = r.address, keyholders = r.keyholders, owner_type = r.owner_type, owner = r.owner, last_activity = r.last, db_now = s.now }
                end
            end
            return rows
        end

        if sql:find('FROM `properties` p') and sql:find('pigeon_property_activity') and sql:find('SELECT') and not sql:find('INSERT') and not sql:find('UPDATE') then
            local rows = {}
            for _, r in ipairs(s.qbx) do
                local a = s.activity[r.id]
                if r.owner and a then
                    rows[#rows + 1] = { id = r.id, label = r.property_name, keyholders = r.keyholders, owner = r.owner, last_activity = a.last, db_now = s.now }
                end
            end
            return rows
        end

        if sql:find('SELECT `notice_key` FROM `pigeon_property_notices`') then
            local rows = {}
            for _, key in ipairs(params) do if s.notices[key] then rows[#rows + 1] = { notice_key = key } end end
            return rows
        end

        if sql:find('FROM `players`') then
            local rows = {}
            for _, cid in ipairs(params) do
                local p = s.players[cid]
                if p then rows[#rows + 1] = { id = cid, charinfo = json.encode({ firstname = p[1], lastname = p[2] }) } end
            end
            return rows
        end

        if sql:find('FROM `users`') then
            local rows = {}
            for _, id in ipairs(params) do
                local p = s.players[id]
                if p then rows[#rows + 1] = { id = id, firstname = p[1], lastname = p[2] } end
            end
            return rows
        end

        error('unexpected query: ' .. sql)
    end

    local function update(sql, params)
        s.queries[#s.queries + 1] = { sql = sql, params = params }
        if sql:find('INSERT IGNORE INTO `pigeon_property_activity`') then
            local added = 0
            for _, r in ipairs(s.qbx) do
                if r.owner and not s.activity[r.id] then
                    s.activity[r.id] = { owner = r.owner, last = s.now }
                    added = added + 1
                end
            end
            return added
        end
        if sql:find('UPDATE `pigeon_property_activity`') then
            local changed = 0
            for _, r in ipairs(s.qbx) do
                local a = s.activity[r.id]
                if r.owner and a and a.owner ~= r.owner then
                    a.owner, a.last = r.owner, s.now
                    changed = changed + 1
                end
            end
            return changed
        end
        if sql:find('ON DUPLICATE KEY UPDATE') then
            s.activity[tonumber(params[1])] = { owner = params[2], last = s.now }
            return 1
        end
        error('unexpected update: ' .. sql)
    end

    local env = setmetatable({}, { __index = _G })
    env.json = json
    env.GetCurrentResourceName = function() return 'pigeon-property-watch' end
    env.GetResourceState = function(name) return s.resources[name] or 'missing' end
    env.GetConvar = function(name, default) return s.convars[name] or default end
    env.IsPlayerAceAllowed = function(source, ace) return s.aces[source] and s.aces[source][ace] or false end
    env.RegisterCommand = function(name, fn) s.commands[name] = fn end
    env.AddEventHandler = function(name, fn) s.handlers[name] = fn end
    env.TriggerClientEvent = function(event, target, payload) s.chat[#s.chat + 1] = { target = target, args = payload.args } end
    env.exports = setmetatable({}, {
        __call = function(_, name, fn) s.exports[name] = fn end,
        __index = function(_, resource)
            if resource == 'qbx_core' then
                return { GetQBPlayers = function() return options.online or {} end }
            end
        end,
    })
    env.print = function(text) s.printed[#s.printed + 1] = (tostring(text):gsub('%^%d', '')) end
    env.os = setmetatable({ time = function() return s.now end, date = function(fmt, time) return os.date(fmt, time or s.now) end }, { __index = os })
    env.CreateThread = function(fn) s.threads[#s.threads + 1] = { co = coroutine.create(fn), wake = 0 } end
    env.Wait = function(ms) coroutine.yield(ms) end
    env.SetTimeout = function(ms, fn) env.CreateThread(function() env.Wait(ms) fn() end) end
    env.promise = { new = function()
        local p = {}
        function p:resolve(v) self.done, self.value = true, v end
        return p
    end }
    env.Citizen = { Await = function(p) while not p.done do coroutine.yield(0) end return p.value end }
    env.PerformHttpRequest = function(url, cb, method, body)
        if url:find('raw.githubusercontent.com') then return cb(404, nil) end -- update checker
        s.posts[#s.posts + 1] = { url = url, method = method, body = json.decode(body) }
        local status = table.remove(s.httpStatuses, 1) or 204
        cb(status)
    end
    env.GetResourceMetadata = function(_, key) if key == 'version' then return '1.0.0' elseif key == 'pigeon_slug' then return 'pigeon-property-watch' end end
    env.MySQL = {
        query = { await = db },
        scalar = { await = function(sql, params)
            s.queries[#s.queries + 1] = { sql = sql, params = params }
            for _, r in ipairs(s.qbx) do if r.id == params[1] then return r.owner end end
            return nil
        end },
        update = { await = update },
        insert = { await = function(sql, params)
            s.queries[#s.queries + 1] = { sql = sql, params = params }
            if sql:find('pigeon_property_notices') then s.notices[params[1]] = true return 1 end
            error('unexpected insert: ' .. sql)
        end },
        ready = function(cb) env.CreateThread(cb) end,
    }
    env.Locales = nil

    s.env = env
    local files = { 'configuration/config.lua', 'locales/en.lua', 'server/core.lua', 'server/queries.lua', 'server/systems.lua', 'server/names.lua' }
    for _, file in ipairs(files) do assert(loadfile(file, 't', env))() end
    if options.configure then options.configure(env.Config) end
    assert(loadfile('server/main.lua', 't', env))()
    assert(loadfile('server/version_check.lua', 't', env))()

    --- Runs threads until they're all waiting, advancing simulated time by `ms`.
    function s.run(ms)
        local target = s.clock + (ms or 0)
        for _ = 1, 10000 do
            local progressed = false
            for i = #s.threads, 1, -1 do
                local th = s.threads[i]
                if th.wake <= target then
                    s.clock = math.max(s.clock, th.wake)
                    local ok, wait = coroutine.resume(th.co)
                    if not ok then error(wait, 0) end
                    if coroutine.status(th.co) == 'dead' then
                        table.remove(s.threads, i)
                    else
                        th.wake = s.clock + (wait or 0)
                    end
                    progressed = true
                end
            end
            if not progressed then break end
        end
        s.clock = target
    end
    s.clock = 0
    s.run(0)
    return s
end

local function command(s, source, ...)
    s.chat, s.printed = {}, {}
    s.commands.propertywatch(source, { ... })
    s.run(120000)
    local out = {}
    for _, p in ipairs(s.printed) do out[#out + 1] = p end
    for _, c in ipairs(s.chat) do out[#out + 1] = table.concat(c.args, ': ') end
    return table.concat(out, '\n')
end

local function fields(post)
    local list = {}
    for _, f in ipairs(post.body.embeds[1].fields) do list[#list + 1] = f.name:match('^#(%d+)') end
    return table.concat(list, ',')
end

io.write('Pigeon Property Watch resource tests\n')

---------------------------------------------------------------------------
-- NoLag Properties

local function nolagRows()
    return {
        { id = 1, label = 'Mirror Park House', address = '5 Mirror Park', keyholders = '{"KEY1":true}', owner_type = 'user', owner = 'CID1', last = NOW - 45 * DAY },
        { id = 2, label = 'Vinewood Flat', address = '9 Vinewood', keyholders = '[]', owner_type = 'user', owner = 'CID2', last = NOW - 25 * DAY },
        { id = 3, label = 'Grove House', address = '1 Grove St', keyholders = '{}', owner_type = 'user', owner = 'CID3', last = NOW - 3 * DAY },
        { id = 4, label = 'Police Garage', address = 'MRPD', keyholders = '[]', owner_type = 'society', owner = 'police', last = NOW - 100 * DAY },
        { id = 5, label = 'Staff House', address = 'Secret', keyholders = '[]', owner_type = 'user', owner = 'CID5', last = NOW - 200 * DAY },
    }
end

do
    local s = newServer({
        nolag = nolagRows(),
        players = { CID1 = { 'Pigeon', 'McPigeon' }, KEY1 = { 'Key', 'Holder' } },
        configure = function(c) c.IgnoreProperties = { 5 } end,
    })
    check('tables are created on start', s.queries[1].sql:find('CREATE TABLE IF NOT EXISTS `pigeon_property_activity`') ~= nil)
    check('detects NoLag Properties on start', table.concat(s.printed, '\n'):find('Watching NoLag Properties. Next check: daily at 18:00') ~= nil, table.concat(s.printed, '\n'))

    local out = command(s, 0, 'status')
    check('status counts owned, inactive and warning properties (players only, ignoring ID 5)',
        out:find('NoLag Properties: 4 owned properties, 1 inactive %(30%+ days%), 1 becoming inactive%.') ~= nil, out)
    check('status sends nothing to Discord', #s.posts == 0)

    out = command(s, 0, 'check')
    check('check sends one inactive and one warning message', #s.posts == 2 and fields(s.posts[1]) == '1' and fields(s.posts[2]) == '2', #s.posts)
    check('summary is printed', out:find('Reported 1 inactive and 1 becoming%-inactive properties to Discord %(2 messages%)') ~= nil, out)
    local value = s.posts[1].body.embeds[1].fields[1].value
    check('owner and keyholder names are looked up', value:find('Pigeon McPigeon (`CID1`)', 1, true) and value:find('Key Holder (`KEY1`)', 1, true), value)
    check('names come from the players table when qbx_core is running', (function()
        for _, q in ipairs(s.queries) do if q.sql:find('FROM `players`') then return true end end
    end)())

    out = command(s, 0)
    check('the same properties aren\'t reported twice', #s.posts == 2 and out:find('nothing new to report') ~= nil, out)

    -- Someone uses property 1, then it goes quiet again for 31 days.
    s.nolag[1].last = NOW - DAY
    s.now = NOW + 31 * DAY
    s.nolag[2].last = NOW - 25 * DAY  -- now 56 days: moves from warning to inactive
    out = command(s, 0, 'check')
    check('a property is reported again after a new stretch of inactivity, and a warning becomes inactive',
        #s.posts == 3 and fields(s.posts[3]) == '2,3,1', fields(s.posts[3] or s.posts[1]))

    out = command(s, 0, 'all')
    check('"all" reports everything again, ignoring what was sent', #s.posts == 4, #s.posts)

    out = command(s, 0, 'nonsense')
    check('unknown action shows help', out:find('Usage: /propertywatch %[check | all | status%]') ~= nil, out)
end

do
    local s = newServer({ nolag = nolagRows(), configure = function(c) c.IncludeSocietyOwned = true end })
    command(s, 0, 'check')
    local found = false
    for _, p in ipairs(s.posts) do if fields(p):find('4') then found = true end end
    check('society-owned properties are included when switched on', found)
    for _, q in ipairs(s.queries) do
        if q.sql:find('properties_owners') then check('society setting is passed to the query as a parameter', q.params[1] == 1) break end
    end
end

do
    local s = newServer({ nolag = nolagRows(), convars = {} })
    local out = command(s, 0, 'check')
    check('no webhook: nothing sent, and says how to fix it', #s.posts == 0 and out:find('pigeon_property_watch_webhook') ~= nil, out)
    s.convars.pigeon_property_watch_webhook = 'https://discord.com/api/webhooks/1/x'
    command(s, 0, 'check')
    check('nothing was marked as sent while there was no webhook', #s.posts == 2)
end

do
    local s = newServer({ nolag = nolagRows(), httpStatuses = { 500 } })
    local out = command(s, 0, 'check')
    check('a failed message is reported in the console', out:find('HTTP 500') ~= nil, out)
    command(s, 0, 'check')
    local resent = false
    for i = 3, #s.posts do if (','..fields(s.posts[i])..','):find(',1,', 1, true) then resent = true end end
    check('properties in a failed message are sent again next time', resent)
end

do
    local s = newServer({ nolag = nolagRows(), httpStatuses = { 429, 204 } })
    command(s, 0, 'check')
    check('rate-limited message is retried once', #s.posts == 3 and fields(s.posts[1]) == '5,1' and fields(s.posts[2]) == '5,1', #s.posts)
end

do
    local s = newServer({ nolag = nolagRows(), configure = function(c) c.Discord.mentionRole = '999'; c.Discord.serverName = 'Los Santos Life' end })
    command(s, 0, 'check')
    local body = s.posts[1].body
    check('role mention is allowed only for the configured role', body.content:sub(1, 7) == '<@&999>' and body.allowed_mentions.roles[1] == '999' and #body.allowed_mentions.parse == 0)
    check('server name is used as the webhook username', body.username == 'Los Santos Life · Property Watch', body.username)
end

do
    local s = newServer({ nolag = nolagRows(), configure = function(c) c.WarnDays = false end })
    command(s, 0, 'check')
    check('warnings off: only inactive properties are sent', #s.posts == 1 and fields(s.posts[1]) == '5,1', fields(s.posts[1]))
end

do
    local s = newServer({ nolag = nolagRows(), configure = function(c) c.WarnDays = 40 end })
    check('a warning threshold above the inactive threshold is turned off with a message', table.concat(s.printed, '\n'):find('Config.WarnDays %(40%) must be lower') ~= nil)
end

do
    local s = newServer({ nolag = nolagRows(), resources = { nolag_properties = 'started', es_extended = 'started' }, players = { CID1 = { 'Esx', 'Person' } } })
    command(s, 0, 'check')
    local usedUsers = false
    for _, q in ipairs(s.queries) do if q.sql:find('FROM `users`') then usedUsers = true end end
    local text = json.encode(s.posts[1].body)
    check('names come from the ESX users table when ESX is running', usedUsers and text:find('Esx Person', 1, true) ~= nil)
end

---------------------------------------------------------------------------
-- Permissions

do
    local s = newServer({ nolag = nolagRows(), aces = { [7] = { ['pigeon-property-watch.admin'] = true } } })
    local out = command(s, 3, 'status')
    check('players without the ACE are refused', out:find('don\'t have permission') ~= nil and #s.posts == 0, out)
    out = command(s, 7, 'status')
    check('players with the ACE get the answer in chat', s.chat[#s.chat].target == 7 and out:find('owned properties') ~= nil, out)
end

---------------------------------------------------------------------------
-- Schedule

do
    local s = newServer({ nolag = nolagRows(), configure = function(c) c.Schedule = { everyHours = 6 } end })
    s.run(60000 + 30000)
    check('every-N-hours: no check straight away on start', #s.posts == 0)
    s.now = NOW + 6 * 3600
    s.run(60000)
    check('every-N-hours: checks after N hours', #s.posts == 2, #s.posts)
end

do
    local s = newServer({ nolag = nolagRows(), configure = function(c) c.Schedule = { everyHours = 6 }; c.CheckOnStart = true end })
    s.run(120000)
    check('CheckOnStart: checks a minute after starting', #s.posts == 2, #s.posts)
end

---------------------------------------------------------------------------
-- Qbox properties

local function qbxServer(extra)
    local opts = {
        resources = { qbx_properties = 'started', qbx_core = 'started' },
        qbx = {
            { id = 10, property_name = 'Apartment 10', keyholders = '["FRIEND"]', owner = 'CIDA' },
            { id = 11, property_name = 'House 11', keyholders = '[]', owner = 'CIDB' },
            { id = 12, property_name = 'Unowned', keyholders = '[]', owner = nil },
        },
        online = { [1] = { PlayerData = { metadata = { currentPropertyId = 11 } } } },
    }
    for k, v in pairs(extra or {}) do opts[k] = v end
    return newServer(opts)
end

do
    local s = qbxServer()
    check('detects Qbox properties', table.concat(s.printed, '\n'):find('Watching Qbox properties') ~= nil)
    local out = command(s, 0, 'status')
    check('first check starts tracking owned properties from now', out:find('Started tracking 2 qbx_properties properties') ~= nil and s.activity[10] and s.activity[12] == nil, out)
    check('nothing is inactive on day one', out:find('2 owned properties, 0 inactive') ~= nil, out)

    s.now = NOW + 31 * DAY
    out = command(s, 0, 'check')
    check('after 31 days with no visits, both are inactive', #s.posts == 1 and (fields(s.posts[1]) == '10,11' or fields(s.posts[1]) == '11,10'), out)

    -- Someone goes into property 10: qbx_properties sets currentPropertyId.
    s.handlers['qbx_core:server:onSetMetaData']('currentPropertyId', nil, 10, 5)
    s.run(0)
    check('entering a property records activity now', s.activity[10].last == s.now)
    s.handlers['qbx_core:server:onSetMetaData']('hunger', 50, 11, 5)
    s.run(0)
    check('other metadata changes are ignored', s.activity[11].last == NOW)

    s.now = s.now + DAY
    s.handlers['qbx_core:server:onSetMetaData']('currentPropertyId', 10, nil, 5)
    s.run(0)
    check('leaving a property records activity too', s.activity[10].last == s.now)

    out = command(s, 0, 'status')
    check('a used property is no longer inactive', out:find('1 inactive') ~= nil, out)

    -- Property 11 is sold to someone else: its clock restarts.
    s.qbx[2].owner = 'CIDC'
    out = command(s, 0, 'status')
    check('a new owner restarts the clock', s.activity[11].owner == 'CIDC' and s.activity[11].last == s.now and out:find('0 inactive') ~= nil, out)
end

do
    local s = qbxServer()
    command(s, 0, 'status')
    s.run(60000)
    check('players already inside a property when the resource starts are recorded', s.activity[11] and s.activity[11].last == NOW)
end

do
    local s = qbxServer()
    command(s, 0, 'status')
    s.now = NOW + 5 * DAY
    check('MarkActive export records activity', s.exports.MarkActive(11) == true and s.activity[11].last == s.now)
    check('MarkActive refuses unowned properties', s.exports.MarkActive(12) == false)
    check('MarkActive refuses nonsense', s.exports.MarkActive('abc') == false)
    s.now = NOW + 40 * DAY
    local inactive = s.exports.GetInactiveProperties()
    check('GetInactiveProperties export returns inactive properties without sending', #inactive == 2 and #s.posts == 0, #inactive)
end

do
    local s = newServer({ resources = {} })
    local out = command(s, 0, 'check')
    check('no housing resource: says what to do, sends nothing', out:find('Start nolag_properties or qbx_properties') ~= nil and #s.posts == 0, out)
end

do
    local s = newServer({ nolag = nolagRows(), resources = { nolag_properties = 'started', qbx_properties = 'started' }, configure = function(c) c.System = 'qbx_properties' end })
    check('Config.System overrides auto-detection', table.concat(s.printed, '\n'):find('Watching Qbox properties') ~= nil)
end

io.write(('%d passed, %d failed\n'):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
