# Changelog

All notable changes to Pigeon Property Watch are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **Major** versions can need changes to your configuration or other resources. Read the **Upgrade notes**.
- **Minor** versions add features without breaking existing setups.
- **Patch** versions fix bugs only.

## [Unreleased]

## [1.0.0] - 2026-10-18

First release. Pigeon Property Watch replaces Inactive Property Alert.

### Upgrade notes

- Coming from Inactive Property Alert: remove `inactive-property-alert`, install this and set it up again. Table and column mapping is gone; NoLag Properties and Qbox properties are supported directly. Set the webhook with the `pigeon_property_watch_webhook` convar.

### Added

- Support for NoLag Properties, using its record of when each property was last entered, or its purchase date.
- Support for Qbox properties, recording every visit server-side, with a first-seen baseline and a fresh clock for new owners.
- Automatic detection of the housing system.
- Early warnings before a property becomes inactive.
- Reporting each property once per stretch of inactivity, or the full list every time.
- Discord reports with owner and keyholder character names, relative "last used" times, an optional role ping, and automatic splitting within Discord's limits.
- Retrying when Discord rate-limits, and re-sending properties from messages Discord rejected.
- Daily or every-N-hours schedules.
- `propertywatch` command (`check`, `all`, `status`) for the console and staff with an ACE permission.
- Ignore list, and optional society-owned NoLag properties.
- Character names from the QBCore/Qbox `players` table or the ESX `users` table.
- `GetInactiveProperties`, `MarkActive` and `Check` exports.
- Every message in `locales/`.
- Update checker from the Pigeon Studios version registry.
- Tests for the core logic and the resource in plain Lua 5.4, and for every query against MariaDB 10.6 and 11.4.

[Unreleased]: https://github.com/WelshPigeon/pigeon-property-watch/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/WelshPigeon/pigeon-property-watch/releases/tag/v1.0.0
