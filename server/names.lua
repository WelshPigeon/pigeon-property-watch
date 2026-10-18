--[[
    Pigeon Property Watch: names.

    Turns owner and keyholder identifiers into character names, from the framework's own tables.
]]

local Q = PropertyWatchQueries
local Names = {}
local BATCH = 200

local function frameworkFor(setting)
    if setting and setting ~= 'auto' then return setting end
    if GetResourceState('es_extended') == 'started' then return 'esx' end
    if GetResourceState('qbx_core') == 'started' or GetResourceState('qb-core') == 'started' then return 'qbx' end
    return 'none'
end

local queries = { qbx = Q.namesQbx, esx = Q.namesEsx }

local function nameFromRow(framework, row)
    local first, last
    if framework == 'qbx' then
        local ok, info = pcall(json.decode, row.charinfo or '')
        if ok and type(info) == 'table' then first, last = info.firstname, info.lastname end
    else
        first, last = row.firstname, row.lastname
    end
    local name = ('%s %s'):format(first or '', last or ''):gsub('%s+', ' '):match('^%s*(.-)%s*$')
    return name ~= '' and name or nil
end

--- Looks up names for a list of identifiers. Returns a table of identifier -> name for the ones found.
function Names.lookup(identifiers)
    local framework = frameworkFor(Config.Names)
    local query = queries[framework]
    local names = {}
    if not query or #identifiers == 0 then return names end

    local unique, seen = {}, {}
    for _, id in ipairs(identifiers) do
        if id and not seen[id] then
            seen[id] = true
            unique[#unique + 1] = id
        end
    end

    for start = 1, #unique, BATCH do
        local batch = { table.unpack(unique, start, math.min(start + BATCH - 1, #unique)) }
        local ok, rows = pcall(MySQL.query.await, query(#batch), batch)
        if ok then
            for _, row in ipairs(rows or {}) do
                names[row.id] = nameFromRow(framework, row)
            end
        else
            print(('^3[pigeon-property-watch] Couldn\'t look up names from the %s table: %s^7'):format(framework == 'esx' and 'users' or 'players', tostring(rows)))
            break
        end
    end

    return names
end

PropertyWatchNames = Names
