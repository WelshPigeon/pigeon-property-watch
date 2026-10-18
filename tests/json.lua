--[[ Minimal JSON for the tests (FiveM provides json.encode and json.decode; plain Lua doesn't). ]]

local json = {}

function json.decode(text)
    local pos = 1
    local function skip() pos = text:find('[^ \t\r\n]', pos) or #text + 1 end
    local value
    local function err(message) error(('json: %s at %d'):format(message, pos)) end
    local function str()
        local out, i = {}, pos + 1
        while true do
            local c = text:sub(i, i)
            if c == '' then err('unterminated string') end
            if c == '"' then pos = i + 1; return table.concat(out) end
            if c == '\\' then
                local e = text:sub(i + 1, i + 1)
                local map = { b = '\b', f = '\f', n = '\n', r = '\r', t = '\t', ['"'] = '"', ['\\'] = '\\', ['/'] = '/' }
                if e == 'u' then
                    out[#out + 1] = utf8.char(tonumber(text:sub(i + 2, i + 5), 16)); i = i + 6
                else
                    out[#out + 1] = map[e] or err('bad escape'); i = i + 2
                end
            else
                out[#out + 1] = c; i = i + 1
            end
        end
    end
    function value()
        skip()
        local c = text:sub(pos, pos)
        if c == '{' then
            local t = {}; pos = pos + 1; skip()
            if text:sub(pos, pos) == '}' then pos = pos + 1; return t end
            while true do
                skip(); local k = str(); skip()
                if text:sub(pos, pos) ~= ':' then err('expected :') end
                pos = pos + 1; t[k] = value(); skip()
                local d = text:sub(pos, pos); pos = pos + 1
                if d == '}' then return t elseif d ~= ',' then err('expected , or }') end
            end
        elseif c == '[' then
            local t = {}; pos = pos + 1; skip()
            if text:sub(pos, pos) == ']' then pos = pos + 1; return t end
            while true do
                t[#t + 1] = value(); skip()
                local d = text:sub(pos, pos); pos = pos + 1
                if d == ']' then return t elseif d ~= ',' then err('expected , or ]') end
            end
        elseif c == '"' then return str()
        elseif text:sub(pos, pos + 3) == 'true' then pos = pos + 4; return true
        elseif text:sub(pos, pos + 4) == 'false' then pos = pos + 5; return false
        elseif text:sub(pos, pos + 3) == 'null' then pos = pos + 4; return nil
        else
            local n = text:match('^-?%d+%.?%d*[eE]?[-+]?%d*', pos)
            if not n or n == '' then err('unexpected character') end
            pos = pos + #n; return tonumber(n)
        end
    end
    local result = value(); skip()
    if pos <= #text then err('trailing data') end
    return result
end

function json.encode(value)
    local t = type(value)
    if t == 'nil' then return 'null' end
    if t == 'boolean' or t == 'number' then return tostring(value) end
    if t == 'string' then
        return '"' .. value:gsub('[%c"\\]', function(c)
            local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
            return map[c] or ('\\u%04x'):format(c:byte())
        end) .. '"'
    end
    if next(value) == nil then return '[]' end
    if #value > 0 then
        local parts = {}
        for i = 1, #value do parts[i] = json.encode(value[i]) end
        return '[' .. table.concat(parts, ',') .. ']'
    end
    local keys = {}
    for k in pairs(value) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = json.encode(tostring(k)) .. ':' .. json.encode(value[k]) end
    return '{' .. table.concat(parts, ',') .. '}'
end

return json
