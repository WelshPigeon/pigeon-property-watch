--[[
    Pigeon Property Watch: every database query, in one place.

    Kept separate so the same SQL the server runs is also run against a real MariaDB in CI
    (tests/sql.test.mjs), with every parameter passed separately, never joined into the SQL.
]]

local Q = {}

local ACTIVITY = 'pigeon_property_activity'
local NOTICES = 'pigeon_property_notices'

Q.ACTIVITY_TABLE = ACTIVITY
Q.NOTICES_TABLE = NOTICES

---------------------------------------------------------------------------
-- Property Watch's own tables

Q.createActivity = ([[
CREATE TABLE IF NOT EXISTS `%s` (
    `system` VARCHAR(32) NOT NULL,
    `property_id` VARCHAR(64) NOT NULL,
    `owner` VARCHAR(64) NULL DEFAULT NULL,
    `last_activity` DATETIME NOT NULL,
    PRIMARY KEY (`system`, `property_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]]):format(ACTIVITY)

Q.createNotices = ([[
CREATE TABLE IF NOT EXISTS `%s` (
    `notice_key` VARCHAR(191) NOT NULL,
    `system` VARCHAR(32) NOT NULL,
    `property_id` VARCHAR(64) NOT NULL,
    `level` VARCHAR(16) NOT NULL,
    `sent_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`notice_key`),
    KEY `property` (`system`, `property_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]]):format(NOTICES)

--- Which of these notice keys have already been reported. One ? per key.
function Q.noticesSent(count)
    return ('SELECT `notice_key` FROM `%s` WHERE `notice_key` IN (%s)'):format(NOTICES, ('?,'):rep(count):sub(1, -2))
end

-- params: notice_key, system, property_id, level
Q.noticeInsert = ('INSERT IGNORE INTO `%s` (`notice_key`, `system`, `property_id`, `level`) VALUES (?, ?, ?, ?)'):format(NOTICES)

---------------------------------------------------------------------------
-- NoLag Properties
-- Last activity is when the property was last entered, or when it was bought if nobody has entered it
-- since, matching how NoLag Properties itself decides a property is inactive.
-- params: include society-owned (1 or 0)

Q.nolagFetch = [[
SELECT
    p.id,
    p.label,
    p.address,
    p.keyholders,
    o.type AS owner_type,
    o.identifier AS owner,
    UNIX_TIMESTAMP(COALESCE(p.last_entered, TIMESTAMP(o.purchase_date))) AS last_activity,
    UNIX_TIMESTAMP() AS db_now
FROM `properties` p
INNER JOIN `properties_owners` o ON p.ownerid = o.id
WHERE o.identifier IS NOT NULL
    AND (o.type = 'user' OR ? = 1)]]

---------------------------------------------------------------------------
-- Qbox properties

-- params: property id
Q.qbxOwner = 'SELECT `owner` FROM `properties` WHERE `id` = ?'

-- params: property id (as text), owner, owner
Q.qbxMarkActive = ([[
INSERT INTO `%s` (`system`, `property_id`, `owner`, `last_activity`)
VALUES ('qbx_properties', ?, ?, NOW())
ON DUPLICATE KEY UPDATE `owner` = ?, `last_activity` = NOW()]]):format(ACTIVITY)

-- Start the clock for owned properties not seen before.
Q.qbxBaseline = ([[
INSERT IGNORE INTO `%s` (`system`, `property_id`, `owner`, `last_activity`)
SELECT 'qbx_properties', CAST(p.id AS CHAR), p.owner, NOW()
FROM `properties` p
WHERE p.owner IS NOT NULL]]):format(ACTIVITY)

-- Restart the clock for properties that have changed owner.
Q.qbxOwnerReset = ([[
UPDATE `%s` a
INNER JOIN `properties` p ON a.system = 'qbx_properties' AND a.property_id = CAST(p.id AS CHAR)
SET a.owner = p.owner, a.last_activity = NOW()
WHERE p.owner IS NOT NULL AND (a.owner IS NULL OR a.owner <> p.owner)]]):format(ACTIVITY)

Q.qbxFetch = ([[
SELECT
    p.id,
    p.property_name AS label,
    p.keyholders,
    p.owner,
    UNIX_TIMESTAMP(a.last_activity) AS last_activity,
    UNIX_TIMESTAMP() AS db_now
FROM `properties` p
INNER JOIN `%s` a ON a.system = 'qbx_properties' AND a.property_id = CAST(p.id AS CHAR)
WHERE p.owner IS NOT NULL]]):format(ACTIVITY)

---------------------------------------------------------------------------
-- Names. One ? per identifier.

function Q.namesQbx(count)
    return ('SELECT `citizenid` AS id, `charinfo` FROM `players` WHERE `citizenid` IN (%s)'):format(('?,'):rep(count):sub(1, -2))
end

function Q.namesEsx(count)
    return ('SELECT `identifier` AS id, `firstname`, `lastname` FROM `users` WHERE `identifier` IN (%s)'):format(('?,'):rep(count):sub(1, -2))
end

PropertyWatchQueries = Q
return Q
