-- Phase 0 regression fixture restoration helper. Offline only; never loaded by toc.g.
local H = {}
function H.Read(path)
    local f = assert(io.open(path, 'rb'), 'missing source: '..tostring(path))
    local s = f:read('*a'); f:close(); return s
end
function H.Contains(path, needles)
    local s = H.Read(path)
    for _, needle in ipairs(needles) do
        assert(s:find(needle, 1, true), path..' missing contract marker: '..needle)
    end
end
function H.NotContains(path, needles)
    local s = H.Read(path)
    for _, needle in ipairs(needles) do
        assert(not s:find(needle, 1, true), path..' contains forbidden marker: '..needle)
    end
end
function H.Pass(name) print('PASS restored fixture '..name) end
return H
