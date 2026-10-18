--[[
    Pigeon Property Watch: housing systems.

    Each system returns every owned property with its last activity time, using the same shape:
        { system, id, label, address, owner, ownerType, keyholders, lastActivity }
    plus the database's current time, so the comparison doesn't depend on the game server's clock.
    The SQL is in server/queries.lua.
]]

local Core = PropertyWatch
local Q = PropertyWatchQueries
local Systems = {}

local function rowsToProperties(system, rows)
    local properties, now = {}, nil
    for _, row in ipairs(rows) do
        now = now or tonumber(row.db_now)
        properties[#properties + 1] = {
            system = system,
            id = row.id,
            label = row.label,
            address = row.address,
            owner = row.owner,
            ownerType = row.owner_type or 'user',
            keyholders = Core.parseKeyholders(row.keyholders, json.decode),
            lastActivity = tonumber(row.last_activity),
        }
    end
    return properties, now
end

---------------------------------------------------------------------------
-- NoLag Properties: uses its own record of when each property was last entered.

Systems.nolag_properties = {
    label = 'NoLag Properties',
    resource = 'nolag_properties',
}

function Systems.nolag_properties.fetch()
    local rows = MySQL.query.await(Q.nolagFetch, { Config.IncludeSocietyOwned and 1 or 0 }) or {}
    return rowsToProperties('nolag_properties', rows)
end

---------------------------------------------------------------------------
-- Qbox properties
-- qbx_properties doesn't record visits, so Property Watch keeps its own record in pigeon_property_activity,
-- updated whenever qbx_properties marks a player as inside a property. Properties seen for the first time,
-- and properties that change owner, start counting from that moment.

Systems.qbx_properties = {
    label = 'Qbox properties',
    resource = 'qbx_properties',
}

--- Records that someone used a qbx_properties property just now. Returns true if recorded.
function Systems.qbx_properties.markActive(propertyId)
    propertyId = tonumber(propertyId)
    if not propertyId or propertyId ~= math.floor(propertyId) then return false end
    local owner = MySQL.scalar.await(Q.qbxOwner, { propertyId })
    if not owner then return false end
    MySQL.update.await(Q.qbxMarkActive, { tostring(math.tointeger(propertyId)), owner, owner })
    return true
end

--- Starts the clock for owned properties not seen before, and restarts it for properties that have changed
--- owner. Returns how many properties started being tracked for the first time.
function Systems.qbx_properties.sync()
    local added = MySQL.update.await(Q.qbxBaseline) or 0
    MySQL.update.await(Q.qbxOwnerReset)
    return added
end

function Systems.qbx_properties.fetch()
    local rows = MySQL.query.await(Q.qbxFetch) or {}
    return rowsToProperties('qbx_properties', rows)
end

---------------------------------------------------------------------------

--- Works out which system to watch. Returns the system's key, or nil if none is available.
function Systems.detect()
    local chosen = Config.System
    if chosen and chosen ~= 'auto' then
        return Systems[chosen] and chosen or nil
    end
    for _, key in ipairs({ 'nolag_properties', 'qbx_properties' }) do
        local state = GetResourceState(Systems[key].resource)
        if state == 'started' or state == 'starting' then return key end
    end
    return nil
end

PropertyWatchSystems = Systems
