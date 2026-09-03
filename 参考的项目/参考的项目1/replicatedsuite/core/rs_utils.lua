------------------------------------------------------------------------
-- Replicated Suite - Utilities
-- Author: Replicated
------------------------------------------------------------------------

if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

S.Utils = {}
local U = S.Utils

function U.Clamp(value, minimum, maximum)
    local n = tonumber(value) or 0
    if minimum ~= nil and n < minimum then n = minimum end
    if maximum ~= nil and n > maximum then n = maximum end
    return n
end

function U.SafeNumber(value, fallback)
    local n = tonumber(value)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return fallback or 0 end
    return n
end

function U.Trim(text)
    if text == nil then return "" end
    return tostring(text):match("^%s*(.-)%s*$") or ""
end

function U.DeepCopy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] ~= nil then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[U.DeepCopy(key, seen)] = U.DeepCopy(item, seen) end
    return result
end

function U.FormatMoney(copper, signed)
    local value = math.floor(U.SafeNumber(copper, 0))
    local sign = ""
    if value < 0 then sign = "-"; value = -value elseif signed == true and value > 0 then sign = "+" end
    local gold = math.floor(value / 10000)
    local silver = math.floor((value % 10000) / 100)
    local coin = value % 100
    if gold > 0 then return string.format("%s%d金%02d银", sign, gold, silver) end
    if silver > 0 then return string.format("%s%d银%02d铜", sign, silver, coin) end
    return string.format("%s%d铜", sign, coin)
end

function U.FormatCompactMoney(copper, signed)
    local value = math.floor(U.SafeNumber(copper, 0))
    local sign = ""
    if value < 0 then sign = "-"; value = -value elseif signed == true and value > 0 then sign = "+" end
    local gold = math.floor(value / 10000)
    local silver = math.floor((value % 10000) / 100)
    if gold > 0 then return string.format("%s%d金%02d银", sign, gold, silver) end
    return string.format("%s%d银", sign, silver)
end

function U.FormatCountdown(seconds)
    local value = math.max(0, math.floor(U.SafeNumber(seconds, 0)))
    if value < 60 then return tostring(value) .. "s" end
    local minutes = math.floor(value / 60)
    if minutes < 60 then return tostring(minutes) .. "m" end
    local hours = math.floor(minutes / 60)
    minutes = minutes % 60
    if hours < 24 then return string.format("%dh%02dm", hours, minutes) end
    local days = math.floor(hours / 24)
    hours = hours % 24
    return string.format("%dd%dh", days, hours)
end

function U.ServerDateKey()
    if UIParent == nil or type(UIParent.GetServerTimeTable) ~= "function" then return "unknown" end
    local ok, t = pcall(function() return UIParent:GetServerTimeTable() end)
    if not ok or type(t) ~= "table" then return "unknown" end
    local year = U.SafeNumber(t.year, 0)
    local month = U.SafeNumber(t.month, 0)
    local day = U.SafeNumber(t.day, 0)
    -- A partially-initialized server-time table (visible right after login or
    -- during a UI reload) can carry zeroed/out-of-range fields. Fabricating a
    -- date from them ("0000-00-00", "2026-00-00", "9999-12-31") would let a
    -- daily-rollover decision fire on a key it cannot trust. Treat them as
    -- "unknown" instead; the same range rule is used by quest IsoDateKey.
    if year < 2000 or year > 2100 or month < 1 or month > 12 or day < 1 or day > 31 then
        return "unknown"
    end
    return string.format("%04d-%02d-%02d", year, month, day)
end

function U.GetServerTime()
    if UIParent == nil or type(UIParent.GetServerTimeTable) ~= "function" then return nil end
    local ok, t = pcall(function() return UIParent:GetServerTimeTable() end)
    if not ok or type(t) ~= "table" then return nil end
    return t
end

function U.DayOfWeek(year, month, day)
    year, month, day = U.SafeNumber(year, 2000), U.SafeNumber(month, 1), U.SafeNumber(day, 1)
    if month < 3 then month = month + 12; year = year - 1 end
    local k = year % 100
    local j = math.floor(year / 100)
    local h = (day + math.floor((13 * (month + 1)) / 5) + k + math.floor(k / 4) + math.floor(j / 4) + 5 * j) % 7
    -- Keep the exact weekday convention used by the supplied RU TimeUntil
    -- schedule: Sunday=1, Monday=2, ... Saturday=7.  The previous Suite
    -- conversion used Monday=1 and shifted every weekday-only event.
    return (h + 6) % 7 + 1
end

function U.ParseProgress(text)
    if type(text) ~= "string" then return nil, nil end
    local current, total = text:match("(%d+)%s*/%s*(%d+)")
    current, total = tonumber(current), tonumber(total)
    if current ~= nil and total ~= nil and total > 0 then return current, total end
    return nil, nil
end

function U.TableCount(t)
    local n = 0
    if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end
    return n
end
