--[[
    Pigeon Property Watch: English.

    To translate, copy this file to a new one named with the language's two-letter code (such as de.lua),
    change `Locales.en` to match (Locales.de), translate the text in quotes, and set Config.Locale.
    Keep words in {curly brackets} exactly as they are; they're filled in automatically.
]]

Locales = Locales or {}

Locales.en = {
    -- Discord messages
    title_inactive = '{count} inactive properties ({days}+ days)',
    title_warning = '{count} properties becoming inactive',
    page = ' (part {page} of {pages})',
    intro_inactive = '{count} properties haven\'t been used for {days} days or more.',
    intro_warning = '{count} properties will count as inactive in {remaining} days or fewer unless someone uses them.',
    property_id = 'Property {id}',
    owner = 'Owner: {owner}',
    owner_society = 'Owned by society: {owner}',
    keyholders = 'Keyholders: {keyholders}',
    last_used = 'Last used {timestamp} ({days} days ago)',
    footer = 'Pigeon Property Watch · {system}',

    -- Console and staff command
    command_help = 'Usage: /{command} [check | all | status]',
    command_started = 'Checking properties now...',
    command_no_permission = 'You don\'t have permission to use this command.',
    status = '{system}: {owned} owned properties, {inactive} inactive ({days}+ days), {warning} becoming inactive.',
    sent = 'Reported {inactive} inactive and {warning} becoming-inactive properties to Discord ({messages} messages).',
    nothing_new = 'Checked {owned} properties: nothing new to report.',
    no_webhook = 'No Discord webhook is set, so nothing was sent. Set pigeon_property_watch_webhook in server.cfg.',
    webhook_failed = 'Discord didn\'t accept a message (HTTP {status}). Check the webhook URL.',
    no_system = 'No supported housing resource is running. Start nolag_properties or qbx_properties, or set Config.System.',
    system_detected = 'Watching {system}. Next check: {next}.',
    baseline = 'Started tracking {count} qbx_properties properties for the first time. They\'ll be checked from today.',
}
