--[[
    Prints every query from server/queries.lua as JSON, so tests/sql.test.mjs can run the exact same SQL
    against a real MariaDB. Queries built for a number of values are dumped for 1 and 2 values.

        lua tests/dump-queries.lua > queries.json
]]

local json = dofile('tests/json.lua')
local Q = dofile('server/queries.lua')

local out = {}
for name, value in pairs(Q) do
    if type(value) == 'string' and not name:match('_TABLE$') then
        out[name] = value
    elseif type(value) == 'function' then
        out[name .. '_1'] = value(1)
        out[name .. '_2'] = value(2)
    end
end

io.write(json.encode(out))
