------------------------------------------------------------------------
-- Replicated Suite V3 - Random Shop observation authority
-- 维护（2026-09-12）：原页面仅一次读取且将小数四舍五入成次数；现在严格区分合法计数与未知。
-- 唯一事实源仍为已登记的只读 getter；没有商店身份/开启状态/周期证据，不推断日额度、花费、
-- 可刷新余量，也不调用刷新/购买。变化历史只是有限采样，不是每次游戏操作的完整日志。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Features = S.Features or {}
S.Features.RandomShop = S.Features.RandomShop or {}
local F = S.Features.RandomShop
local A = { version = 2, revision = 0, snapshot = nil, history = {}, serial = 0,
    metrics = { refreshes = 0, failures = 0 } }
F.Authority = A
local SOURCE, HISTORY_LIMIT = "X2Store:GetRandomShopStoreRefreshCount", 12

local function Read()
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" or X2Store == nil then
        return nil, "随机商店计数接口不可用", "unavailable"
    end
    local ok, value, err = S.Api:CallCapability(SOURCE, X2Store, "GetRandomShopStoreRefreshCount")
    if ok ~= true then return nil, tostring(err or "计数读取失败"):sub(1, 160), type(value) end
    -- 维护：允许精确整数数字串，拒绝false/nil/表/NaN/无穷/小数；2^53-1是Lua double的安全整数
    -- 边界，不是RU商店限额。不能用round或默认0把异常数据变为可触发提醒的有效次数。
    local count = (type(value) == "number" or type(value) == "string") and tonumber(value) or nil
    if count == nil or count ~= count or count < 0 or count > 9007199254740991 or count ~= math.floor(count) then
        return nil, "计数返回值不是有效非负整数", type(value)
    end
    return count, nil, type(value)
end

function A:Record(count, delta, kind)
    self.serial = self.serial + 1
    table.insert(self.history, 1, { key = "random_shop:" .. tostring(self.serial), count = count,
        delta = delta, kind = kind, observedAtMs = S.NowMs and S.NowMs() or 0 })
    if #self.history > HISTORY_LIMIT then table.remove(self.history) end
end

function A:Clear(reason)
    -- 维护：需求归零/停用时清除所有短期事实，避免重新开页把跨商店、跨暂停的旧读数当作当前值。
    -- 只清本Authority的缓存；永久设置由Feature Store独立拥有，不在这里读写。
    self.history, self.baseline = {}, nil
    self.revision = self.revision + 1
    self.snapshot = { revision = self.revision, available = false, status = "idle", source = SOURCE,
        reason = tostring(reason or "observation_stopped") }
    return true
end

function A:Refresh(reason)
    local count, err, rawType = Read()
    local previous = self.snapshot and self.snapshot.refreshCount or nil
    self.metrics.refreshes = self.metrics.refreshes + 1
    if count == nil then
        self.metrics.failures = self.metrics.failures + 1
        if previous ~= nil then self:Record(nil, nil, "unavailable") end
        self.baseline = nil
    elseif previous == nil then
        self.baseline = count
        self:Record(count, nil, "start")
    elseif count ~= previous then
        if count < previous then self.baseline = count end
        self:Record(count, count - previous, count < previous and "decrease" or "increase")
    end
    -- 维护：下降或读取断档即重新建立观察起点，不累加跨段正差冒充消费次数；同数值的商店切换
    -- 无法由单getter识别，页面必须明确覆盖限制。读数变化不写永久存档。
    self.revision = self.revision + 1
    self.snapshot = { revision = self.revision, available = count ~= nil,
        status = count ~= nil and "ready" or "unavailable", refreshCount = count,
        baseline = self.baseline, sinceBaseline = count and self.baseline and (count - self.baseline) or nil,
        error = err, rawType = rawType, source = SOURCE, reason = tostring(reason or "refresh") }
    return true
end

function A:ResetBaseline()
    local current = self.snapshot
    if current == nil or current.available ~= true then return false, "当前没有有效读数，不能重设观察起点" end
    self.baseline = current.refreshCount
    self.revision = self.revision + 1
    current.baseline, current.sinceBaseline, current.revision = self.baseline, 0, self.revision
    self:Record(current.refreshCount, 0, "manual")
    return true
end

function A:GetProjection()
    -- 维护：脱离所有内部表返回，Presentation不得修改历史/起点，更不能在Render中调用getter。
    local p = self.snapshot or { revision = 0, available = false, status = "idle", source = SOURCE }
    local out = {}; for k, v in pairs(p) do out[k] = v end
    out.history = {}
    for i, row in ipairs(self.history) do
        local copy = {}; for k, v in pairs(row) do copy[k] = v end; out.history[i] = copy
    end
    return out
end
function A:GetHealth()
    return { version = self.version, revision = self.revision, available = self.snapshot ~= nil and self.snapshot.available == true,
        refreshes = self.metrics.refreshes, failures = self.metrics.failures, historySize = #self.history,
        rawType = self.snapshot and self.snapshot.rawType or nil }
end
