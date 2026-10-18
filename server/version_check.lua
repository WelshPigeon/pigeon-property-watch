--[[
    Pigeon Studios update checker · v2.0.0
    https://github.com/WelshPigeon/pigeon-versions

    Tells the server owner, once when the resource starts, whether a newer release is available.
    Copy this file into the resource's server/ folder unchanged, and add it to server_scripts.

    Reads from fxmanifest.lua:
        version     '1.2.0'          the installed version (semantic versioning)
        pigeon_slug 'pigeon-dice'    the resource's entry in the version registry

    Server owners can change what it does with a convar in server.cfg:
        set pigeon_update_check "on"      default: one short line per resource
        set pigeon_update_check "quiet"   only print when an update, notice or problem needs attention
        set pigeon_update_check "off"     never check

    Privacy: one GET request to raw.githubusercontent.com per start (plus one retry if GitHub can't be
    reached). Nothing about the server, its players or its configuration is sent.
]]

do
    local CHECKER_VERSION = '2.0.0'
    local REGISTRY_URL = 'https://raw.githubusercontent.com/WelshPigeon/pigeon-versions/main/api/v2/%s.json'
    local SUPPORTED_SCHEMA = 2
    local MAX_HIGHLIGHTS = 3
    local START_DELAY_MS = { 2000, 6000 }  -- spread out so several Pigeon resources don't all print at once
    local RETRY_DELAY_MS = 60000

    local RESOURCE = GetCurrentResourceName()

    -- FiveM console colours: ^1 red, ^2 green, ^3 yellow, ^5 cyan, ^6 purple, ^7 default.
    local BRAND, RESET = '^6', '^7'
    local GREEN, YELLOW, RED, CYAN = '^2', '^3', '^1', '^5'

    local function say(colour, message)
        print(('%s[Pigeon Studios]%s %s%s%s'):format(BRAND, RESET, colour or '', message, RESET))
    end

    local function detail(message)
        print(('                 %s'):format(message))
    end

    --- Strips colour codes and control characters from registry text, and limits its length.
    local function clean(text, limit)
        if type(text) ~= 'string' then return nil end
        text = text:gsub('%^%d', ''):gsub('%c', ' '):gsub('%s+', ' '):match('^%s*(.-)%s*$')
        if text == '' then return nil end
        limit = limit or 160
        if #text > limit then text = text:sub(1, limit - 3) .. '...' end
        return text
    end

    local function metadata(key)
        local value = GetResourceMetadata(RESOURCE, key, 0)
        if type(value) ~= 'string' then return nil end
        value = value:match('^%s*(.-)%s*$')
        return value ~= '' and value or nil
    end

    ---------------------------------------------------------------------------
    -- Semantic versions (https://semver.org), including pre-releases such as 2.0.0-beta.1

    local function parseVersion(version)
        if type(version) ~= 'string' then return nil end
        version = version:match('^%s*[vV]?(.-)%s*$')
        local core, rest = version:match('^([%d%.]+)(.*)$')
        if not core then return nil end

        local major, minor, patch = core:match('^(%d+)%.(%d+)%.(%d+)$')
        if not major then
            major, minor = core:match('^(%d+)%.(%d+)$')
            patch = '0'
        end
        if not major then return nil end

        local pre = {}
        if rest ~= '' then
            local preText = rest:match('^%-([0-9A-Za-z%.%-]+)') or ''
            local after = rest:sub(#preText + (preText ~= '' and 2 or 1))
            if preText == '' and rest:sub(1, 1) ~= '+' then return nil end
            if after ~= '' and not after:match('^%+[0-9A-Za-z%.%-]+$') then return nil end
            for identifier in preText:gmatch('[^%.]+') do
                pre[#pre + 1] = identifier
            end
        end

        return { tonumber(major), tonumber(minor), tonumber(patch), pre = pre }
    end

    --- Returns -1 if a is older than b, 1 if newer, 0 if the same release.
    local function compareVersions(a, b)
        for i = 1, 3 do
            if a[i] ~= b[i] then return a[i] < b[i] and -1 or 1 end
        end
        local x, y = a.pre, b.pre
        if #x == 0 or #y == 0 then
            if #x == #y then return 0 end
            return #x > 0 and -1 or 1  -- a pre-release comes before its release
        end
        for i = 1, math.max(#x, #y) do
            local p, q = x[i], y[i]
            if p == nil then return -1 end
            if q == nil then return 1 end
            local pn, qn = tonumber(p:match('^%d+$')), tonumber(q:match('^%d+$'))
            if pn and qn then
                if pn ~= qn then return pn < qn and -1 or 1 end
            elseif pn or qn then
                return pn and -1 or 1      -- numeric identifiers sort before text
            elseif p ~= q then
                return p < q and -1 or 1
            end
        end
        return 0
    end

    ---------------------------------------------------------------------------

    local mode = GetConvar('pigeon_update_check', 'on'):lower()
    if mode == 'off' or mode == 'false' or mode == '0' then return end
    local quiet = mode == 'quiet'

    local installedText = metadata('version')
    local slug = metadata('pigeon_slug')
    local installed = parseVersion(installedText)

    if not installed then
        say(YELLOW, ('Update check skipped: fxmanifest.lua needs a version such as version \'1.0.0\' (found "%s").'):format(installedText or 'nothing'))
        return
    end
    if not slug or not slug:match('^[a-z0-9][a-z0-9%-]+$') then
        say(YELLOW, 'Update check skipped: fxmanifest.lua needs pigeon_slug \'resource-name\'.')
        return
    end

    local function report(data)
        local name = clean(data.name, 60) or RESOURCE
        local latest = type(data.latest) == 'table' and data.latest or {}
        local latestVersion = parseVersion(latest.version)
        local links = type(data.links) == 'table' and data.links or {}
        local download = clean(links.download, 200) or clean(links.support, 200)

        if not latestVersion then
            if not quiet then say(nil, ('%s v%s: the update information couldn\'t be read.'):format(name, installedText)) end
            return
        end

        local status, notice = data.status, clean(data.notice, 200)
        if status == 'discontinued' then
            say(RED, ('%s is discontinued and no longer supported.'):format(name))
            if notice then detail(notice) end
        elseif status == 'deprecated' then
            say(YELLOW, ('%s is deprecated.'):format(name))
            if notice then detail(notice) end
        elseif notice then
            say(YELLOW, notice)
        end

        local order = compareVersions(installed, latestVersion)

        if order == 0 then
            if not quiet then say(GREEN, ('%s v%s is up to date.'):format(name, installedText)) end
            return
        end

        if order > 0 then
            if not quiet then
                say(CYAN, ('%s v%s is a development build (latest release: v%s).'):format(name, installedText, latest.version))
            end
            return
        end

        -- An update is available. It's a security update if any release newer than the installed one fixed a security problem.
        local security = false
        if type(data.security_releases) == 'table' then
            for _, version in ipairs(data.security_releases) do
                local parsed = parseVersion(version)
                if parsed and compareVersions(parsed, installed) > 0 then
                    security = true
                    break
                end
            end
        end
        local minimum = parseVersion(data.minimum_version)
        local unsupported = minimum and compareVersions(installed, minimum) < 0

        local headline
        if security then
            headline = 'Security update available'
        elseif unsupported then
            headline = 'Important update available'
        else
            headline = 'Update available'
        end

        local released = clean(latest.date, 10)
        say((security or unsupported) and RED or YELLOW, ('%s for %s: v%s -> v%s%s'):format(
            headline, name, installedText, latest.version, released and (' (released %s)'):format(released) or ''
        ))

        if security then
            detail('This update fixes a security problem. Please update as soon as possible.')
        elseif unsupported then
            detail(('v%s is no longer supported. Please update.'):format(installedText))
        end

        local title = clean(latest.title, 100)
        if title then detail(title) end

        if type(latest.highlights) == 'table' then
            local shown = 0
            for _, highlight in ipairs(latest.highlights) do
                local text = clean(highlight)
                if text then
                    detail('- ' .. text)
                    shown = shown + 1
                    if shown == MAX_HIGHLIGHTS then break end
                end
            end
        end

        if download then detail('Get it: ' .. download) end
    end

    local function check(attempt)
        local url = REGISTRY_URL:format(slug)
        PerformHttpRequest(url, function(statusCode, body)
            if statusCode == 200 and type(body) == 'string' then
                local ok, data = pcall(json.decode, body)
                if not ok or type(data) ~= 'table' then
                    if not quiet then say(nil, 'Update check failed: the update information couldn\'t be read.') end
                    return
                end
                if type(data.schema) ~= 'number' or data.schema > SUPPORTED_SCHEMA then
                    if not quiet then say(nil, 'Update check skipped: this version of the update checker is too old to read the registry.') end
                    return
                end
                return report(data)
            end

            if statusCode == 404 then
                if not quiet then say(YELLOW, ('Update check skipped: "%s" isn\'t in the version registry.'):format(slug)) end
                return
            end

            -- GitHub unreachable, rate-limited or erroring: try once more, then give up quietly.
            if attempt == 1 then
                SetTimeout(RETRY_DELAY_MS, function() check(2) end)
            elseif not quiet then
                say(nil, ('Couldn\'t check for updates (%s). The resource works normally.'):format(
                    statusCode and statusCode > 0 and ('HTTP ' .. statusCode) or 'no connection'
                ))
            end
        end, 'GET', '', {
            ['Accept'] = 'application/json',
            ['User-Agent'] = ('PigeonStudios-UpdateChecker/%s'):format(CHECKER_VERSION),
        })
    end

    SetTimeout(math.random(START_DELAY_MS[1], START_DELAY_MS[2]), function() check(1) end)
end
