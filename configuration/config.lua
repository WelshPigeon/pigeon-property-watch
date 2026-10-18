--[[
    Pigeon Property Watch: settings.

    Pigeon Property Watch only runs on the server; nothing here is ever sent to players.
    Keep the Discord webhook in server.cfg instead of this file if you share your resources folder:
        set pigeon_property_watch_webhook "https://discord.com/api/webhooks/..."
]]

Config = {}

-- Language file from locales/ to use, such as 'en'.
Config.Locale = 'en'

---------------------------------------------------------------------------
-- Housing system

-- Which housing resource to watch:
--   'auto'              use whichever of the two below is running
--   'nolag_properties'  NoLag Properties. Uses its own record of when each property was last entered.
--   'qbx_properties'    Qbox properties. It doesn't record visits, so Property Watch records them itself
--                       from the moment it's installed (see README "How inactivity is measured").
Config.System = 'auto'

-- NoLag Properties only: also watch properties owned by societies (businesses, jobs), not just players.
Config.IncludeSocietyOwned = false

-- Property IDs never to report, such as staff or event properties. For example: { 12, 48 }
Config.IgnoreProperties = {}

---------------------------------------------------------------------------
-- What counts as inactive

-- A property is inactive when nobody has entered it for this many days.
Config.InactiveDays = 30

-- Also report properties that are getting close, after this many days. false to turn off.
-- Must be lower than Config.InactiveDays.
Config.WarnDays = 21

---------------------------------------------------------------------------
-- When to check

-- Check once a day at a set time (24-hour, server time):   { daily = '18:00' }
-- or every few hours:                                       { everyHours = 12 }
Config.Schedule = { daily = '18:00' }

-- Also check a minute after the server starts. Useful while setting up.
Config.CheckOnStart = false

-- 'new' reports each property once per stretch of inactivity: once when it starts to get close (if
--       warnings are on) and once when it becomes inactive. Using the property resets it.
-- 'all' reports every inactive and warning property on every check.
Config.ReportMode = 'new'

---------------------------------------------------------------------------
-- Discord

Config.Discord = {
    -- Webhook URL, or '' to use the pigeon_property_watch_webhook convar from server.cfg (recommended).
    webhook = '',

    -- Name shown on the messages. Your server's name works well, such as 'Los Santos Life'.
    serverName = '',

    -- Discord role ID to ping with each report, as a string, or nil for no ping.
    -- (Server settings → Roles → right-click the role → Copy Role ID, with Developer Mode on.)
    mentionRole = nil,

    -- Properties per message, 1 to 25. Large lists are split across several messages.
    perMessage = 10,

    -- Optional image URL for the webhook's avatar.
    avatar = nil,
}

---------------------------------------------------------------------------
-- Names

-- How owner and keyholder names are looked up from their identifiers:
--   'auto'  QBCore/Qbox players table or ESX users table, whichever framework is running
--   'qbx'   the players table (QBCore and Qbox)
--   'esx'   the users table (ESX)
--   'none'  show identifiers only
Config.Names = 'auto'

---------------------------------------------------------------------------
-- Staff command

-- Console and in-game command: /propertywatch [check | all | status]
Config.Command = 'propertywatch'

-- ACE permission players need to use the command in game. The server console can always use it.
--     add_ace group.admin pigeon-property-watch.admin allow
Config.Permission = 'pigeon-property-watch.admin'

-- Print a summary of each check in the server console.
Config.LogToConsole = true
