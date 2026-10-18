fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'pigeon-property-watch'
author 'Pigeon Studios'
description 'Finds properties nobody has used for weeks and reports them to Discord, for NoLag Properties and Qbox properties.'
version '1.0.0'
repository 'https://github.com/WelshPigeon/pigeon-property-watch'

-- Pigeon Studios version registry entry, read by server/version_check.lua.
pigeon_slug 'pigeon-property-watch'

server_only 'yes'

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'configuration/config.lua',
    'locales/*.lua',
    'server/core.lua',
    'server/queries.lua',
    'server/systems.lua',
    'server/names.lua',
    'server/main.lua',
    'server/version_check.lua',
}

dependencies {
    'oxmysql',
}
