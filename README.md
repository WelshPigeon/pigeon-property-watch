<div align="center">
  <h1>Pigeon Property Watch</h1>

  <p><strong>Finds properties nobody has used for weeks and reports them to Discord, for NoLag Properties and Qbox properties.</strong></p>

  <p>
    <a href="https://github.com/pigeon-studios-uk/pigeon-property-watch/releases/latest"><img src="https://img.shields.io/github/v/release/pigeon-studios-uk/pigeon-property-watch?label=release&color=2ea043" alt="Latest release" /></a>
    <a href="LICENSE.md"><img src="https://img.shields.io/badge/licence-Pigeon%20Studios%20Free-6f42c1" alt="Licence: Pigeon Studios Free Licence" /></a>
    <a href="https://discord.gg/2NFVWEUmDF"><img src="https://img.shields.io/badge/support-Discord-5865F2?logo=discord&logoColor=white" alt="Discord support" /></a>
    <img src="https://img.shields.io/badge/FiveM-resource-F40552" alt="FiveM resource" />
  </p>

  <p>
    <a href="https://github.com/pigeon-studios-uk/pigeon-property-watch/releases/latest"><strong>Download</strong></a> ·
    <a href="#installation">Install</a> ·
    <a href="#configuration">Configure</a> ·
    <a href="CHANGELOG.md">Changelog</a> ·
    <a href="https://discord.gg/2NFVWEUmDF">Support</a>
  </p>
</div>

---

## Contents

- [Overview](#overview)
- [Features](#features)
- [What staff see](#what-staff-see)
- [Requirements](#requirements)
- [Installation](#installation)
- [Updating](#updating)
- [How inactivity is measured](#how-inactivity-is-measured)
- [Configuration](#configuration)
- [Schedule and report modes](#schedule-and-report-modes)
- [Discord](#discord)
- [Commands](#commands)
- [Names](#names)
- [Exports](#exports)
- [Database tables](#database-tables)
- [Localisation](#localisation)
- [Update checker](#update-checker)
- [Performance](#performance)
- [Security and privacy](#security-and-privacy)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [Support](#support)
- [Contributing](#contributing)
- [Licence](#licence)
- [Credits](#credits)

## Overview

On busy roleplay servers, houses get bought and forgotten, and they stay locked away from new players. Pigeon Property Watch is a free, server-only resource by [Pigeon Studios](https://pigeonstudios.co.uk) that checks your housing every day, finds properties nobody has entered for a set number of days, and posts a clear list to a staff Discord channel. It shows each property's owner, keyholders, and when it was last used, so staff can decide what to do: message the owner, repossess it or relist it.

It works with **NoLag Properties** and **Qbox properties** out of the box, picks whichever one you run, and never changes your housing data.

## Features

- **Two housing systems, detected automatically.** NoLag Properties (`nolag_properties`) and Qbox properties (`qbx_properties`).
- **Accurate activity.** NoLag Properties' own record of when each property was last entered. For Qbox, Property Watch records every visit itself, server-side, because qbx_properties doesn't.
- **Early warnings.** Optionally flags properties getting close to inactive, so owners can be reminded in time.
- **No repeated spam.** Each property is reported once when it gets close and once when it becomes inactive. Using it resets it.
- **Clear Discord reports.** Owner and keyholder character names, "last used 41 days ago" in each viewer's own time zone, and automatic splitting to stay within Discord's limits.
- **Your schedule.** Daily at a set time, or every few hours.
- **Staff command.** Check, re-send everything or see a summary from the console or in game, with an ACE permission.
- **Ignore list.** Leave out staff, event or job properties by ID. Society-owned NoLag properties are left out unless you turn them on.
- **Read-only on your housing.** It never edits, sells or deletes properties. It only adds two small tables of its own.
- **Server only.** Nothing is sent to players' games.
- **Tested against a real database.** Every query runs against MariaDB in CI.

## What staff see

A Discord message like this, posted by the webhook:

> **Los Santos Life · Property Watch**
> 2 properties haven't been used for 30 days or more.
>
> **2 inactive properties (30+ days)**
> **#1 Mirror Park House · 5 Mirror Park**
> Owner: Pigeon McPigeon (`CID1`)
> Keyholders: Key Holder (`KEY1`)
> Last used 2 months ago (45 days ago)
>
> **#7 Vinewood Flat · 9 Vinewood**
> Owner: Sam Smith (`ABC123`)
> Last used last month (31 days ago)

Warnings arrive as a separate amber message: "3 properties will count as inactive in 9 days or fewer unless someone uses them."

## Requirements

| Requirement | Version | Notes |
|---|---|---|
| FXServer | A [recommended artifact](https://runtime.fivem.net/artifacts/) | |
| [oxmysql](https://github.com/communityox/oxmysql) | 2.0 or newer | |
| MariaDB or MySQL | MariaDB 10.6+ or MySQL 8+ | Tested on MariaDB 10.6 and 11.4 |
| One housing resource | NoLag Properties, or [qbx_properties](https://github.com/Qbox-project/qbx_properties) | |
| A Discord webhook | | For reports. Everything else works without one |

**Frameworks:** works with any. Character names are looked up from the QBCore/Qbox `players` table or the ESX `users` table automatically.

## Installation

1. **Download** `pigeon-property-watch.zip` from the [latest release](https://github.com/pigeon-studios-uk/pigeon-property-watch/releases/latest).
2. **Extract** it into your `resources` folder. The folder must be called `pigeon-property-watch`.
3. **Add your Discord webhook** to `server.cfg` (create it in your staff channel: **Edit Channel → Integrations → Webhooks**):

   ```cfg
   set pigeon_property_watch_webhook "https://discord.com/api/webhooks/..."
   ```

4. **Start it** after oxmysql and your housing resource:

   ```cfg
   ensure oxmysql
   ensure nolag_properties      # or qbx_properties
   ensure pigeon-property-watch
   ```

5. **Let staff use the command** (optional):

   ```cfg
   add_ace group.admin pigeon-property-watch.admin allow
   ```

6. **Restart** your server. The console shows which housing system it's watching:

   ```text
   [pigeon-property-watch] Watching NoLag Properties. Next check: daily at 18:00.
   ```

7. **Try it** from the server console: `propertywatch status`, then `propertywatch check`.

The tables Property Watch needs are created automatically. There's no SQL to import.

## Updating

1. Read the [changelog](CHANGELOG.md), especially any **Upgrade notes**.
2. Back up `configuration/config.lua`.
3. Replace the folder with the new release and copy your settings into the new `config.lua`.
4. Restart the resource.

**Replacing Inactive Property Alert:** Property Watch is its successor. Stop and remove `inactive-property-alert`, install this, and set it up again. The settings are different: there's no table and column mapping any more, because each housing system is supported directly. The webhook moves to the `pigeon_property_watch_webhook` convar.

## How inactivity is measured

A property counts as **used** whenever anyone goes in, whether it's the owner, a keyholder or a guest. It becomes **inactive** after `Config.InactiveDays` days with no visits.

**NoLag Properties** records the last time each property was entered. Property Watch reads that, and for properties nobody has entered since they were bought, uses the purchase date. This matches how NoLag Properties' own inactivity features count.

**Qbox properties** doesn't record visits, so Property Watch does. qbx_properties marks a player as inside a property (after its own checks that they're allowed in), and Property Watch records the time whenever someone goes in or comes out. Because it can only see visits from when it's installed:

- the first time it sees an owned property, it **starts the clock from that moment**. Nothing can be reported as inactive until `Config.InactiveDays` after installing;
- when a property **changes owner**, the clock restarts for the new owner; and
- players who are already inside a property when the resource starts are counted.

Properties without an owner are never reported.

## Configuration

All settings are in `configuration/config.lua`, each explained by a comment.

| Setting | Default | What it does |
|---|---|---|
| `Config.Locale` | `'en'` | Language file from `locales/` |
| `Config.System` | `'auto'` | `'auto'`, `'nolag_properties'` or `'qbx_properties'` |
| `Config.IncludeSocietyOwned` | `false` | NoLag only: also watch society-owned properties |
| `Config.IgnoreProperties` | `{}` | Property IDs never to report, such as `{ 12, 48 }` |
| `Config.InactiveDays` | `30` | Days without a visit before a property is inactive |
| `Config.WarnDays` | `21` | Days before an early warning. `false` to turn off. Must be lower than `InactiveDays` |
| `Config.Schedule` | `{ daily = '18:00' }` | When to check (see below) |
| `Config.CheckOnStart` | `false` | Also check a minute after the server starts |
| `Config.ReportMode` | `'new'` | `'new'` reports each property once per stretch of inactivity; `'all'` reports everything every time |
| `Config.Discord.webhook` | `''` | Webhook URL, if you don't use the convar |
| `Config.Discord.serverName` | `''` | Shown as the webhook's name, such as "Los Santos Life · Property Watch" |
| `Config.Discord.mentionRole` | `nil` | A role ID to ping with each report |
| `Config.Discord.perMessage` | `10` | Properties per message (1 to 25) |
| `Config.Discord.avatar` | `nil` | Image URL for the webhook's avatar |
| `Config.Names` | `'auto'` | `'auto'`, `'qbx'` (players table), `'esx'` (users table) or `'none'` |
| `Config.Command` | `'propertywatch'` | The staff and console command |
| `Config.Permission` | `'pigeon-property-watch.admin'` | ACE players need to use the command |
| `Config.LogToConsole` | `true` | Print a summary of each scheduled check |

## Schedule and report modes

```lua
Config.Schedule = { daily = '18:00' }   -- once a day at 6 pm, server time
Config.Schedule = { everyHours = 12 }   -- every 12 hours
```

A daily check that's already past for today when the server starts waits until tomorrow, so restarts don't trigger extra reports. Set `Config.CheckOnStart = true` to check a minute after every start.

With `Config.ReportMode = 'new'` (the default), each property is reported:

- once when it reaches `WarnDays` (if warnings are on), and
- once when it reaches `InactiveDays`.

If someone uses it, or it changes owner, it starts again. Use `/propertywatch all` whenever you want the full current list. With `'all'`, every check posts the full list.

## Discord

- Messages stay within Discord's limits. Long lists are split into numbered parts, and long names or keyholder lists are shortened.
- Messages are sent a few seconds apart, and retried once if Discord says to slow down.
- Names are cleaned so they can't break formatting or mention anyone. Only the role in `Config.Discord.mentionRole`, if set, can be pinged.
- If Discord rejects a message, those properties are reported again at the next check instead of being lost.
- "Last used" times use Discord's timestamps, so everyone sees them in their own time zone.

## Commands

| Command | What it does |
|---|---|
| `propertywatch` or `propertywatch check` | Runs a check now and reports anything new, as the schedule would |
| `propertywatch all` | Reports every inactive and warning property now, including ones already reported |
| `propertywatch status` | Shows counts in the console or chat without sending anything to Discord |

The server console can always use it. In game, players need the ACE in `Config.Permission`, and answers appear in their chat.

## Names

Owner and keyholder names come from your framework's character table:

- **QBCore and Qbox:** `players.charinfo` (first and last name), by citizen ID.
- **ESX:** `users.firstname` and `users.lastname`, by identifier.

If a name can't be found, the identifier is shown on its own. Set `Config.Names = 'none'` to only show identifiers.

## Exports

For other server-side resources:

```lua
-- Current inactive and warning properties, without reporting them.
-- Each has: system, id, label, address, owner, ownerType, keyholders, lastActivity (unix seconds), days.
local inactive, warning = exports['pigeon-property-watch']:GetInactiveProperties()

-- Qbox only: record that a property was used now, for resources that let players use a property
-- without going inside, such as a garage or a stash at the door. Returns true if recorded.
exports['pigeon-property-watch']:MarkActive(propertyId)

-- Run a check now, as the schedule would. Returns a one-line summary.
local summary = exports['pigeon-property-watch']:Check()
```

## Database tables

Property Watch creates two tables of its own on start, and never changes your housing tables:

| Table | What's in it |
|---|---|
| `pigeon_property_activity` | Qbox only: the last time each owned property was used, and its owner at the time |
| `pigeon_property_notices` | Which reports have been sent, so properties aren't reported twice |

To start again from scratch, stop the resource and empty both tables.

## Localisation

Set `Config.Locale` to a file in `locales/`. To add a language, copy `locales/en.lua`, rename it with the two-letter code (such as `de.lua`), change `Locales.en` to `Locales.de`, and translate the text in quotes. Keep anything in `{curly brackets}` as it is.

## Update checker

When it starts, Property Watch checks our public [version registry](https://github.com/pigeon-studios-uk/pigeon-versions) once and prints one line in the server console. It sends nothing about your server. Control it for every Pigeon Studios resource in `server.cfg`:

```cfg
set pigeon_update_check "on"      # default
set pigeon_update_check "quiet"   # only when there's an update or a problem
set pigeon_update_check "off"     # never check
```

## Performance

Property Watch does nothing between checks except record Qbox property visits, which is one small database write when someone goes in or out. A check is a handful of queries, even with thousands of properties. It runs on the server only; players download nothing.

## Security and privacy

- **Read-only on your housing.** It never changes, sells or deletes properties.
- **No player input.** Nothing players do or send can trigger a check, and the command needs an ACE permission in game.
- **Server-authoritative activity.** Qbox visits are recorded from qbx_core's server-side event, after qbx_properties has checked the player is allowed in, so players can't fake activity.
- **Parameterised queries only.**
- **Personal data.** Reports contain character names and identifiers of owners and keyholders, sent to your Discord channel. Keep it staff-only, and mention it in your server's privacy information. The tables store property IDs, owner identifiers and times only.

Please report security problems privately. Use the **Report a vulnerability** button in this repository's **Security** tab, or follow our [Security Policy](https://github.com/pigeon-studios-uk/.github/blob/main/SECURITY.md).

## Troubleshooting

**"No supported housing resource is running."**
Start `nolag_properties` or `qbx_properties` before `pigeon-property-watch`, or set `Config.System` to the one you use.

**"No Discord webhook is set, so nothing was sent."**
Add `set pigeon_property_watch_webhook "..."` to `server.cfg`, or set `Config.Discord.webhook`.

**"Discord didn't accept a message (HTTP 401/404)."**
The webhook was deleted or the URL is wrong. Create a new one and update the convar.

**Qbox: nothing is ever reported.**
That's expected for the first `Config.InactiveDays` after installing; see [How inactivity is measured](#how-inactivity-is-measured). Run `propertywatch status` to see the counts.

**Names show as IDs only.**
Your framework's character table couldn't be read. Check the console for a warning, or set `Config.Names` to `'qbx'` or `'esx'` to match your framework.

**Reports at the wrong time.**
`Config.Schedule.daily` uses the server machine's local time. Check its time zone.

## FAQ

**Does it take properties off players automatically?**
No. It only reports. What happens next is up to your staff. (NoLag Properties has its own optional inactivity settings if you want automatic handling.)

**Does a keyholder visiting count?**
Yes. Any visit by anyone counts as the property being used.

**Can I use it with another housing script?**
Not yet. If you'd like support for one, open a feature request with a link to the script.

## Support

Read [Troubleshooting](#troubleshooting) first, then ask in the support channels of our [Discord](https://discord.gg/2NFVWEUmDF). Please include your housing resource and version, and the server console output. See [Getting help](https://github.com/pigeon-studios-uk/.github/blob/main/SUPPORT.md).

## Contributing

Fixes, improvements and support for more housing systems are welcome. Please read the [contributing guide](https://github.com/pigeon-studios-uk/.github/blob/main/CONTRIBUTING.md) first.

Tests run in plain Lua 5.4, and the SQL tests against MariaDB:

```bash
lua tests/core.test.lua
lua tests/resource.test.lua
```

See the top of `tests/sql.test.mjs` for running the SQL tests against a throwaway database.

## Licence

Pigeon Property Watch is free to use under the **[Pigeon Studios Free Licence](LICENSE.md)**.

- ✅ Use it on any number of servers, including monetised ones
- ✅ Change it for your own servers
- ❌ Don't reupload, share or mirror the files; link to this repository instead
- ❌ Don't sell it, bundle it in packs, or put it behind escrow
- ❌ Don't remove the credits

This summary isn't the licence; [LICENSE.md](LICENSE.md) is. Third-party notices are in [NOTICE.md](NOTICE.md).

## Credits

Made by [Pigeon Studios](https://pigeonstudios.co.uk).

<sub>Not affiliated with or endorsed by Rockstar Games, Take-Two Interactive, Cfx.re, NoLag Development or the Qbox Project.</sub>
