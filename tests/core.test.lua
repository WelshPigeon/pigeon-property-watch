--[[
    Tests for server/core.lua.

    Run from the repository root with Lua 5.4:
        lua tests/core.test.lua
]]

local json = dofile('tests/json.lua')
local Core = dofile('server/core.lua')
dofile('locales/en.lua')

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        io.write(('  \27[31mFAIL\27[0m  %s%s\n'):format(name, detail ~= nil and ('\n          ' .. tostring(detail)) or ''))
    end
end

local function t(key, values)
    return (Locales.en[key]:gsub('{(%w+)}', function(name) return tostring(values and values[name]) end))
end

io.write('Pigeon Property Watch core tests\n')

---------------------------------------------------------------------------
-- Keyholders

local function same(list, expected) return table.concat(list, ',') == table.concat(expected, ',') end

check('qbx keyholders: JSON array of citizen IDs', same(Core.parseKeyholders('["ABC123","DEF456"]', json.decode), { 'ABC123', 'DEF456' }))
check('nolag keyholders: JSON object keyed by identifier', same(Core.parseKeyholders('{"ZZZ999":{"name":"A"},"ABC123":true}', json.decode), { 'ABC123', 'ZZZ999' }))
check('array of objects with citizenid', same(Core.parseKeyholders('[{"citizenid":"A1"},{"identifier":"B2"},{"cid":"C3"}]', json.decode), { 'A1', 'B2', 'C3' }))
check('comma-separated text', same(Core.parseKeyholders('A1, B2;C3', json.decode), { 'A1', 'B2', 'C3' }))
check('already-decoded table', same(Core.parseKeyholders({ 'A1', 'B2' }, json.decode), { 'A1', 'B2' }))
check('empty JSON array', #Core.parseKeyholders('[]', json.decode) == 0)
check('empty JSON object', #Core.parseKeyholders('{}', json.decode) == 0)
check('nil and blank', #Core.parseKeyholders(nil, json.decode) == 0 and #Core.parseKeyholders('  ', json.decode) == 0)
check('duplicates and "none" removed', same(Core.parseKeyholders('["A1","A1","none",""," B2 "]', json.decode), { 'A1', 'B2' }))

---------------------------------------------------------------------------
-- Classification

local DAY = 86400
local NOW = 1800000000

local props = {
    { system = 'qbx_properties', id = 1, lastActivity = NOW - 10 * DAY },
    { system = 'qbx_properties', id = 2, lastActivity = NOW - 30 * DAY },
    { system = 'qbx_properties', id = 3, lastActivity = NOW - 45 * DAY },
    { system = 'qbx_properties', id = 4, lastActivity = NOW - 22 * DAY - 3600 },
    { system = 'qbx_properties', id = 5, lastActivity = NOW - 29 * DAY - 86399 },
    { system = 'qbx_properties', id = 6, lastActivity = nil },
    { system = 'qbx_properties', id = 7, lastActivity = NOW + 5 * DAY },
    { system = 'qbx_properties', id = 8, lastActivity = NOW - 90 * DAY },
}

local inactive, warning = Core.classify(props, NOW, { inactiveDays = 30, warnDays = 21, ignore = { [8] = true } })
local ids = function(list) local out = {} for i, p in ipairs(list) do out[i] = p.id end return table.concat(out, ',') end
check('inactive: 30+ days, longest first, ignored ones left out', ids(inactive) == '3,2', ids(inactive))
check('warning: 21-29 days', ids(warning) == '5,4', ids(warning))
check('29 days 23:59:59 is still a warning, not inactive', props[5].days == 29)
check('properties with no activity date are skipped', props[6].days == nil)
check('activity in the future counts as 0 days', props[7].days == 0)

local noWarn = select(2, Core.classify(props, NOW, { inactiveDays = 30, warnDays = false }))
check('warnings off: none returned', #noWarn == 0)

local _, _ = Core.classify(props, NOW, { inactiveDays = 30, warnDays = 21, ignore = { ['8'] = true } })
check('ignore list works with string IDs too', props[8].days == 90)

check('notice key changes when the property is used again',
    Core.noticeKey({ system = 's', id = 1, owner = 'A', lastActivity = 100 }, 'inactive') ~= Core.noticeKey({ system = 's', id = 1, owner = 'A', lastActivity = 200 }, 'inactive'))
check('notice key changes when the owner changes',
    Core.noticeKey({ system = 's', id = 1, owner = 'A', lastActivity = 100 }, 'inactive') ~= Core.noticeKey({ system = 's', id = 1, owner = 'B', lastActivity = 100 }, 'inactive'))
check('notice key differs by level',
    Core.noticeKey({ system = 's', id = 1, owner = 'A', lastActivity = 100 }, 'inactive') ~= Core.noticeKey({ system = 's', id = 1, owner = 'A', lastActivity = 100 }, 'warning'))

---------------------------------------------------------------------------
-- Text safety

check('mentions are neutralised', not Core.discordSafe('@everyone hi @here'):find('@everyone', 1, true))
check('markdown is escaped', Core.discordSafe('**bold** `code` [link](x)') == '\\*\\*bold\\*\\* \\`code\\` \\[link\\]\\(x\\)', Core.discordSafe('**bold** `code` [link](x)'))
check('control characters removed', Core.discordSafe('a\nb\tc') == 'a b c')
check('truncate keeps short text', Core.truncate('hello', 10) == 'hello')
check('truncate shortens to exactly the limit with an ellipsis', utf8.len(Core.truncate(string.rep('a', 50), 10)) == 10 and Core.truncate(string.rep('a', 50), 10):sub(-3) == '…')
check('truncate counts characters, not bytes', utf8.len(Core.truncate(string.rep('é', 50), 10)) == 10)
check('truncate survives invalid UTF-8', Core.truncate('abc\255\254def', 100) == 'abcdef')

---------------------------------------------------------------------------
-- Discord messages

local function makeProps(count, long)
    local list = {}
    for i = 1, count do
        list[i] = {
            system = 'nolag_properties', id = i, label = long and string.rep('L', 300) or ('House ' .. i),
            address = long and string.rep('A', 300) or (i .. ' Grove Street'),
            owner = 'CID' .. i, ownerType = 'user',
            keyholders = long and (function() local k = {} for n = 1, 80 do k[n] = 'KEYHOLDER' .. n end return k end)() or { 'CID' .. i, 'KEY' .. i },
            lastActivity = NOW - 40 * DAY, days = 40,
        }
    end
    return list
end

local names = { CID1 = 'Pigeon McPigeon', KEY1 = '@everyone **lol**' }
local options = { names = names, t = t, perMessage = 10, username = 'Test Server · Property Watch', days = 30, system = 'nolag_properties', timestamp = '2026-10-18T00:00:00Z' }

local messages = Core.buildMessages(makeProps(3), 'inactive', options)
local field = messages[1].embeds[1].fields[1]
check('one message for a few properties', #messages == 1 and #messages[1].embeds[1].fields == 3)
check('field heading has ID, label and address', field.name == '#1 House 1 · 1 Grove Street', field.name)
check('owner shown with name and ID', field.value:find('Owner: Pigeon McPigeon (`CID1`)', 1, true) ~= nil, field.value)
check('owner not repeated as a keyholder', not field.value:find('Keyholders: Pigeon', 1, true) and field.value:find('Keyholders: ', 1, true) ~= nil)
check('keyholder names are made safe', not field.value:find('@everyone', 1, true) and field.value:find('\\*\\*lol\\*\\*', 1, true) ~= nil, field.value)
check('last used uses a Discord relative timestamp', field.value:find('<t:' .. (NOW - 40 * DAY) .. ':R>', 1, true) ~= nil)
check('no mentions allowed by default', #messages[1].allowed_mentions.parse == 0 and #messages[1].allowed_mentions.roles == 0)
check('intro text in content', messages[1].content:find('3 properties haven\'t been used for 30 days', 1, true) ~= nil, messages[1].content)

local mention = Core.buildMessages(makeProps(1), 'inactive', setmetatable({ mentionRole = '123456' }, { __index = options }))
check('role mention is pinged and explicitly allowed', mention[1].content:sub(1, 11) == '<@&123456> ' and mention[1].allowed_mentions.roles[1] == '123456')

local many = Core.buildMessages(makeProps(23), 'inactive', options)
check('23 properties at 10 per message make 3 messages', #many == 3 and #many[3].embeds[1].fields == 3)
check('pages are labelled', many[2].embeds[1].title:find('(part 2 of 3)', 1, true) ~= nil, many[2].embeds[1].title)
check('only the first message has the intro', many[1].content ~= nil and many[2].content == nil)

local huge = Core.buildMessages(makeProps(40, true), 'inactive', setmetatable({ perMessage = 25 }, { __index = options }))
local okLimits = true
for _, payload in ipairs(huge) do
    local embed = payload.embeds[1]
    local total = #embed.title + #embed.footer.text
    if #embed.fields > 25 then okLimits = false end
    for _, f in ipairs(embed.fields) do
        if utf8.len(f.name) > 256 or utf8.len(f.value) > 1024 then okLimits = false end
        total = total + #f.name + #f.value
    end
    if total > 6000 then okLimits = false end
end
check('very long names and keyholder lists stay within every Discord limit', okLimits and #huge > 1, #huge .. ' messages')

local warn = Core.buildMessages(makeProps(2), 'warning', setmetatable({ remaining = 9 }, { __index = options }))
check('warning messages use the warning title and colour', warn[1].embeds[1].title:find('becoming inactive', 1, true) ~= nil and warn[1].embeds[1].color == 0xF5A524 and warn[1].content:find('in 9 days', 1, true) ~= nil)

local encoded = json.encode(messages[1])
check('messages encode to JSON', type(encoded) == 'string' and #encoded > 100)

---------------------------------------------------------------------------
-- Schedule

local function clock(h, m, day) return { year = 2026, month = 10, day = day or 18, hour = h, min = m } end

check('parseTime accepts HH:MM', select(1, Core.parseTime('18:30')) == 18 and select(2, Core.parseTime('7:05')) == 5)
check('parseTime rejects bad times', Core.parseTime('25:00') == nil and Core.parseTime('18:60') == nil and Core.parseTime('six') == nil)

local state = {}
check('daily: not due before the time', not Core.isDue({ daily = '18:00' }, clock(17, 59), NOW, state))
check('daily: due at the time', Core.isDue({ daily = '18:00' }, clock(18, 0), NOW, state))
check('daily: only once that day', not Core.isDue({ daily = '18:00' }, clock(18, 1), NOW + 60, state))
check('daily: due again the next day', Core.isDue({ daily = '18:00' }, clock(18, 0, 19), NOW + DAY, state))

local every = {}
check('every N hours: due the first time', Core.isDue({ everyHours = 6 }, clock(1, 0), NOW, every))
check('every N hours: not due after 5 hours', not Core.isDue({ everyHours = 6 }, clock(6, 0), NOW + 5 * 3600, every))
check('every N hours: due after 6 hours', Core.isDue({ everyHours = 6 }, clock(7, 0), NOW + 6 * 3600, every))
check('invalid schedule is never due', not Core.isDue({ daily = 'nope' }, clock(12, 0), NOW, {}))

check('core is exposed as PropertyWatch', PropertyWatch == Core)

io.write(('%d passed, %d failed\n'):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
