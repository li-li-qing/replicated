------------------------------------------------------------------------
-- Replicated Suite · 通用安全工具
-- 作者：Replicated
-- QQ群：1104129461
--
-- 通用工具。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

S.Utils = {}
local U = S.Utils

-- 下方 SafeNumber/FormatMoney 等归 rs_utils；Clamp/Trim/DeepCopy/TableCount 的权威实现由紧接加载的
-- core/rs_reuse.lua 重新导出到 S.Utils.*，本地死副本已物理移除。

function U.SafeNumber(value, fallback)
    local n = tonumber(value)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return fallback or 0 end
    return n
end

-- UnitGearScore(unit,comma) 第二参控制千分位，不是 target 标志；格式化返回如 "12,345" 不能直接 tonumber。此
-- 辅助不读 API、不缓存业务状态，只归一化 X2Unit 返回事实为 number，BuffDisplay/RaidReadiness 共用同一地区格
-- 式规则。支持数字、逗号、ASCII 空白、UTF-8 NBSP/thin-space，未知 table/object 返回 nil，不猜非数字内容，0/
-- 负数不是有效装分。仅短字符串替换，由既有低频装备/就绪路径调用，不新建 Tick 循环。
U.GearScoreParseContractVersion = 1
function U.ParseGearScore(raw)
    local rawType = type(raw)
    local formatted = false
    local candidate = raw
    if rawType == "string" then
        local text = tostring(raw)
        local cleaned = text:gsub(",", ""):gsub("%s", "")
        cleaned = cleaned:gsub("\194\160", ""):gsub("\226\128\137", "")
        formatted = cleaned ~= text
        candidate = cleaned
    elseif rawType ~= "number" then
        return nil, false
    end
    local value = tonumber(candidate)
    if value == nil or value ~= value or value == math.huge or value == -math.huge or value <= 0 then
        return nil, formatted
    end
    return value, formatted
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
    -- 登录或 UI 重载中的服务器时间表可能部分初始化，含零或越界字段。不能制造 0000-00-00、2026-00-00、
    -- 9999-12-31 等不可信日期触发日切，须视为未知；quest IsoDateKey 使用同一范围规则。
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
    -- 沿用 RU TimeUntil 调度的星期约定：周日=1、周一=2、...、周六=7，不能按周一=1 转换而偏移仅工作日事件。
    return (h + 6) % 7 + 1
end

function U.ParseProgress(text)
    if type(text) ~= "string" then return nil, nil end
    local current, total = text:match("(%d+)%s*/%s*(%d+)")
    current, total = tonumber(current), tonumber(total)
    if current ~= nil and total ~= nil and total > 0 then return current, total end
    return nil, nil
end

-- 统一单位名归一化：去首尾空白、转小写、移除世界名后缀及第二个 @ 段（Name@World -> name）。
-- DPS/plates/roster/healer 重建等身份匹配共用唯一实现，不能私建漂移副本。
function U.NormalizeUnitName(name)
    local text = tostring(name or "")
    text = text:gsub("^%s+", ""):gsub("%s+$", ""):lower()
    local at = text:find("@", 1, true)
    if at ~= nil and at > 1 then text = text:sub(1, at - 1) end
    return text
end
