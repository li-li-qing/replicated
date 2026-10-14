------------------------------------------------------------------------
-- Replicated Suite · 共享帧预算
-- 作者：Replicated
-- QQ群：1104129461
--
-- 帧预算协调器集中管理 Suite 周期工作软预算，不替代 Domain 运行体，也不持有 OnUpdate。当前 Suite Scheduler
-- 是预算执行权威；接口可供专业运行体复用，独立原生 OnUpdate 宿主逐步迁移，不能在此强行接线。P0/P1 关键或用
-- 户动作工作绝不丢弃；低优先级可延后，但有界饥饿保护确保后台维护不会永久停滞。热路径仅使用有界计数：每次
-- Request() 不写诊断日志、不逐帧全表扫描、不依赖墙上时钟，以原生帧 delta 表示压力；这里不执行任务回调。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

local PRIORITY = { P0=0, P1=1, P2=2, P3=3, P4=4, P5=5 }
local PRESSURE_RANK = { Normal=0, Busy=1, Heavy=2, Critical=3 }
local BACKLOG_PRESSURE = {
    Normal="Normal", Delayed="Busy", ["Heavy Backlog"]="Heavy", Critical="Critical",
}

-- 额度采用保守的抽象工作单位而非毫秒，保证缺少可靠 Lua 执行计时器的 RU 客户端上策略仍确定。任务可通过
-- Scheduler:SetCost 声明更高成本，不改变业务行为。
local PROFILE = {
    Normal   = { credits=10, maxExecutions=10 },
    Busy     = { credits=8,  maxExecutions=8  },
    Heavy    = { credits=5,  maxExecutions=6  },
    Critical = { credits=3,  maxExecutions=4  },
}

local MAX_DEFER_FRAMES = { [0]=0, [1]=0, [2]=3, [3]=5, [4]=8, [5]=12 }
local STARVATION_LATE_RATIO = { [0]=0, [1]=0, [2]=1.5, [3]=2.0, [4]=3.0, [5]=4.0 }
local MAX_OWNER_STATS = 96

local function Finite(value, fallback)
    value = tonumber(value)
    if value == nil or value ~= value or value == math.huge or value == -math.huge then return fallback end
    return value
end

local function NormalizePriority(value)
    if type(value) == "string" then value = PRIORITY[string.upper(value)] end
    value = math.floor(Finite(value, 3))
    if value < 0 then return 0 end
    if value > 5 then return 5 end
    return value
end

local function NormalizeCost(value)
    value = math.floor(Finite(value, 1))
    if value < 1 then return 1 end
    if value > 8 then return 8 end
    return value
end

local function DtPressure(dtMs)
    local dt = math.max(0, Finite(dtMs, 0))
    if dt >= 70 then return "Critical" end
    if dt >= 40 then return "Heavy" end
    if dt >= 24 then return "Busy" end
    return "Normal"
end

local function MaxPressure(a, b)
    a, b = tostring(a or "Normal"), tostring(b or "Normal")
    if (PRESSURE_RANK[b] or 0) > (PRESSURE_RANK[a] or 0) then return b end
    return a
end

S.FrameBudget = {
    Version = "1.0",
    frameSerial = 0,
    current = {
        pressure="Normal", frameDtMs=0, pendingBefore=0,
        creditsTotal=10, creditsRemaining=10, maxExecutions=10,
        granted=0, deferred=0, criticalGranted=0, starvationRuns=0,
        budgetedGranted=0, budgetedCostUnits=0, visualGranted=0, visualCostUnits=0, backgroundReserveRuns=0,
    },
    previous = nil,
    totals = { frames=0, requests=0, granted=0, deferred=0, criticalGranted=0, starvationRuns=0 },
    ownerStats = {}, ownerCount = 0,
}
local B = S.FrameBudget

function B:BeginFrame(frameDtMs, backlogHealth, pendingBefore)
    local dt = math.max(0, Finite(frameDtMs, 0))
    local pressure = MaxPressure(DtPressure(dt), BACKLOG_PRESSURE[tostring(backlogHealth or "Normal")] or "Normal")
    local profile = PROFILE[pressure] or PROFILE.Normal

    local old = self.current
    self.previous = {
        serial = self.frameSerial,
        pressure = old.pressure,
        frameDtMs = old.frameDtMs,
        pendingBefore = old.pendingBefore,
        pendingAfter = old.pendingAfter,
        creditsTotal = old.creditsTotal,
        creditsRemaining = old.creditsRemaining,
        maxExecutions = old.maxExecutions,
        granted = old.granted,
        deferred = old.deferred,
        criticalGranted = old.criticalGranted,
        budgetedGranted = old.budgetedGranted,
        budgetedCostUnits = old.budgetedCostUnits,
        visualGranted = old.visualGranted,
        visualCostUnits = old.visualCostUnits,
        backgroundReserveRuns = old.backgroundReserveRuns,
        starvationRuns = old.starvationRuns,
    }

    self.frameSerial = self.frameSerial + 1
    self.current = {
        serial = self.frameSerial,
        pressure = pressure,
        frameDtMs = dt,
        pendingBefore = math.max(0, math.floor(Finite(pendingBefore, 0))),
        pendingAfter = 0,
        creditsTotal = profile.credits,
        creditsRemaining = profile.credits,
        maxExecutions = profile.maxExecutions,
        granted = 0,
        deferred = 0,
        criticalGranted = 0,
        budgetedGranted = 0,
        budgetedCostUnits = 0,
        visualGranted = 0,
        visualCostUnits = 0,
        backgroundReserveRuns = 0,
        starvationRuns = 0,
    }
    self.totals.frames = (tonumber(self.totals.frames) or 0) + 1
    return pressure
end

function B:_OwnerStats(owner)
    owner = tostring(owner or "unknown")
    if owner == "" then owner = "unknown" end
    local stats = self.ownerStats[owner]
    if stats ~= nil then return stats, owner end
    if self.ownerCount >= MAX_OWNER_STATS then
        owner = "other"
        stats = self.ownerStats[owner]
        if stats ~= nil then return stats, owner end
    end
    stats = { requests=0, granted=0, deferred=0, starvationRuns=0, criticalGranted=0, maxConsecutiveDefers=0 }
    self.ownerStats[owner] = stats
    self.ownerCount = self.ownerCount + 1
    return stats, owner
end

-- （2026-10-03，scheduler-starvation-fairness）饥饿阈值只归预算 Broker；Scheduler 排序和 Request
-- 必须用同一判定，否则 P2 长期抢走唯一 starvation escape，P3 候选/P4 高亮永远等待。纯函数不记统计/不分配表。
function B:IsStarving(priority, deferCount, lateRatio)
    local p=NormalizePriority(priority)
    if p<=1 then return false end
    return math.max(0,Finite(deferCount,0)) >= (MAX_DEFER_FRAMES[p] or 8)
        or math.max(0,Finite(lateRatio,0)) >= (STARVATION_LATE_RATIO[p] or 3.0)
end

function B:Request(owner, priority, costUnits, deferCount, lateRatio, lane)
    local p = NormalizePriority(priority)
    local cost = NormalizeCost(costUnits)
    local current = self.current
    local stats = self:_OwnerStats(owner)
    -- 保留早期表参数形式的兼容性；Scheduler 使用直接标量参数，逐帧热路径不分配选项表。
    if type(deferCount) == "table" then
        local options = deferCount
        deferCount = options.deferCount
        lateRatio = options.lateRatio
    end

    self.totals.requests = (tonumber(self.totals.requests) or 0) + 1
    stats.requests = (tonumber(stats.requests) or 0) + 1

    -- P0/P1 属于正确性或用户动作通道，计入预算但绝不被软预算拒绝。超出剩余额度时在诊断中显示亏欠，不改变游戏行为。
    if p <= 1 then
        current.granted = current.granted + 1
        current.criticalGranted = current.criticalGranted + 1
        -- P1连续视觉由HF车道保证每帧最多一次。
        -- 旧账本把4个HF的执行量扣进Critical的3credits/4slots，后台只剩1个饥饿逃生，
        -- 单次停顿即可让lateRatio长期Critical。视觉与普通工作分账，用于下方有限预留；
        -- 所有工作仍扣原总credits。普通P0/P1动作也占后台账，缺lane的旧调用不改变行为。
        if lane == "highfrequency" and p == 1 then
            current.visualGranted = current.visualGranted + 1
            current.visualCostUnits = current.visualCostUnits + cost
        else
            current.budgetedGranted = current.budgetedGranted + 1
            current.budgetedCostUnits = current.budgetedCostUnits + cost
        end
        current.creditsRemaining = math.max(0, current.creditsRemaining - cost)
        self.totals.granted = self.totals.granted + 1
        self.totals.criticalGranted = self.totals.criticalGranted + 1
        stats.granted = stats.granted + 1
        stats.criticalGranted = stats.criticalGranted + 1
        return true, "critical"
    end

    deferCount = math.max(0, math.floor(Finite(deferCount, 0)))
    lateRatio = math.max(0, Finite(lateRatio, 0))
    if deferCount > (tonumber(stats.maxConsecutiveDefers) or 0) then stats.maxConsecutiveDefers = deferCount end

    local executionRoom = current.granted < current.maxExecutions
    local creditRoom = current.creditsRemaining >= cost
    -- 仅原生帧已恢复（<40ms）但后台lateRatio仍高时，确保最多2个普通
    -- slots/credits可运行。已执行的普通工作（包括P0/P1）抵扣预留，不能额外叠加2次。
    -- 原生长帧保持旧总预算/饥饿保护，不把全部后台配额叠在视觉之后，不新增追赶循环。
    local reserveRoom = current.visualGranted > 0 and current.frameDtMs < 40
        and current.budgetedGranted < 2 and current.budgetedCostUnits + cost <= 2
    if (executionRoom and creditRoom) or reserveRoom then
        current.granted = current.granted + 1
        current.budgetedGranted = current.budgetedGranted + 1
        current.budgetedCostUnits = current.budgetedCostUnits + cost
        current.creditsRemaining = current.creditsRemaining - cost
        if current.creditsRemaining < 0 then current.creditsRemaining = 0 end
        self.totals.granted = self.totals.granted + 1
        stats.granted = stats.granted + 1
        if not (executionRoom and creditRoom) then
            current.backgroundReserveRuns = current.backgroundReserveRuns + 1
            return true, "background_reserve"
        end
        return true, "budget"
    end

    -- 每个渲染帧仅允许一次饥饿逃逸；若所有旧任务同时逃逸，会重新造成预算协调器要避免的卡顿。
    local starving = self:IsStarving(p,deferCount,lateRatio) -- 只轮转“已达旧阈值”的任务；仍严格每帧最多一个 escape，不放宽
                                                             -- credits/maxExecutions。
    if starving and current.starvationRuns < 1 then
        current.granted = current.granted + 1
        current.budgetedGranted = current.budgetedGranted + 1
        current.budgetedCostUnits = current.budgetedCostUnits + cost
        current.starvationRuns = current.starvationRuns + 1
        current.creditsRemaining = math.max(0, current.creditsRemaining - cost)
        self.totals.granted = self.totals.granted + 1
        self.totals.starvationRuns = self.totals.starvationRuns + 1
        stats.granted = stats.granted + 1
        stats.starvationRuns = stats.starvationRuns + 1
        return true, "starvation"
    end

    current.deferred = current.deferred + 1
    self.totals.deferred = self.totals.deferred + 1
    stats.deferred = stats.deferred + 1
    return false, executionRoom and "credits" or "execution_cap"
end

function B:EndFrame(pendingAfter)
    self.current.pendingAfter = math.max(0, math.floor(Finite(pendingAfter, 0)))
end

function B:Describe()
    local c = self.current or {}
    local rows = {}
    for owner, stats in pairs(self.ownerStats or {}) do
        if (tonumber(stats.deferred) or 0) > 0 or (tonumber(stats.starvationRuns) or 0) > 0 then
            rows[#rows + 1] = {
                owner=owner, requests=tonumber(stats.requests) or 0, granted=tonumber(stats.granted) or 0,
                deferred=tonumber(stats.deferred) or 0, starvationRuns=tonumber(stats.starvationRuns) or 0,
                maxConsecutiveDefers=tonumber(stats.maxConsecutiveDefers) or 0,
            }
        end
    end
    table.sort(rows, function(a, b)
        if a.deferred ~= b.deferred then return a.deferred > b.deferred end
        if a.starvationRuns ~= b.starvationRuns then return a.starvationRuns > b.starvationRuns end
        return tostring(a.owner) < tostring(b.owner)
    end)
    while #rows > 8 do table.remove(rows) end

    return {
        version = tostring(self.Version or "?"), serial = tonumber(c.serial) or 0,
        pressure = tostring(c.pressure or "Normal"), frameDtMs = tonumber(c.frameDtMs) or 0,
        pendingBefore = tonumber(c.pendingBefore) or 0, pendingAfter = tonumber(c.pendingAfter) or 0,
        creditsTotal = tonumber(c.creditsTotal) or 0, creditsRemaining = tonumber(c.creditsRemaining) or 0,
        maxExecutions = tonumber(c.maxExecutions) or 0, granted = tonumber(c.granted) or 0,
        deferred = tonumber(c.deferred) or 0, criticalGranted = tonumber(c.criticalGranted) or 0,
        budgetedGranted = tonumber(c.budgetedGranted) or 0, visualGranted = tonumber(c.visualGranted) or 0,
        visualCostUnits = tonumber(c.visualCostUnits) or 0,
        budgetedCostUnits = tonumber(c.budgetedCostUnits) or 0,
        backgroundReserveRuns = tonumber(c.backgroundReserveRuns) or 0,
        accountingPatch = "visual-background-budget-1",
        starvationRuns = tonumber(c.starvationRuns) or 0,
        totals = {
            frames=tonumber(self.totals.frames) or 0, requests=tonumber(self.totals.requests) or 0,
            granted=tonumber(self.totals.granted) or 0, deferred=tonumber(self.totals.deferred) or 0,
            criticalGranted=tonumber(self.totals.criticalGranted) or 0, starvationRuns=tonumber(self.totals.starvationRuns) or 0,
        },
        topDeferred = rows,
    }
end
