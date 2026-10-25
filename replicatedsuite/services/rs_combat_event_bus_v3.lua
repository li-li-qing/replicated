-- Replicated Suite · 战斗事件总线
-- 作者：Replicated
-- QQ群：1104129461
-- 私有 COMBAT_MSG 提供 SELF，只有 scope=all 消费者才启用 UI/UIParent 全局桥；全局滤去 SELF，两个切片互斥。
-- 跨宿主按出现次数配对去重，同宿主重复行保留。这里只归一原生事实，不判阵营、PVP/PVE 或排名。
-- raw 单位 ID 须经 UnitIdentityV3 验证名称才能绑定。租约存在才持有处理器，无释放 API 时隐藏停放并以代际隔离。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}

local C = {
    Id = "v3.combat_event_bus",
    version = 9,
    running = false,
    privateHost = nil,
    privateHandlerAttached = false,
    privateEvents = {},
    optionalKillEvents = {},
    killNoticeRows = 0,
    killNoticeRejected = 0,
    killNoticeSources = { private = { received = 0, rejected = 0 }, global = { received = 0, rejected = 0 } },
    killGlobalOwner = { Id = "v3.combat_event_bus.kill_global" },
    killGlobalEpoch = 0,
    killGlobalStarted = false,
    killGlobalActive = false,
    killGlobalEvents = {},
    privateParked = false,
    globalHandlers = {},
    globalActive = false,
    globalParkedHosts = 0,
    subscribers = {},
    subscriberOrder = {},
    subscriberCount = 0,
    subscriberSerial = 0,
    subscriberTombstones = 0,
    dispatchDepth = 0,
    sequence = 0,
    received = 0,
    delivered = 0,
    callbackErrors = 0,
    unknownKinds = 0,
    unknownEvidence = {},
    unknownEvidenceCount = 0,
    unknownTypeDropped = 0,
    privateRows = 0,
    globalRows = 0,
    globalSelfFiltered = 0,
    globalNoIdentitySuppressed = 0, -- 保留历史计数名，现在统计冷路径 journal 行。
    globalCrossHostDuplicates = 0,
    globalCrossHostEvicted = 0,
    factMutationErrors = 0,
    journal = {},
    journalHead = 1,
    journalMax = 256,
    journalTtlMs = 1500,
    journalQueued = 0,
    journalReplayed = 0,
    journalDropped = 0,
    journalDroppedCurrent = 0,
    globalHostCoverage = { UI = false, UIParent = false },
    startFailures = 0,
    stopFailures = 0,
    forcedInert = 0,
    releaseApiMissing = 0,
    releaseCallFailures = 0,
    scopeFiltered = 0,
    lastPlayerRefreshAt = -1,
    pairDedup = {},
    pairOrder = {},
    pairHead = 1,
    pairSerial = 0,
    pairPendingCount = 0,
    pairMax = 256,
    pairTtlMs = 50,
}
C.presentationBoundary = "service_only"
S.Services.CombatEventBusV3 = C

local U = S.Utils
local Identity = S.Services.UnitIdentityV3
local function NowMs() return math.max(0, tonumber(S.NowMs and S.NowMs()) or 0) end
local function Trim(value) return U and U.Trim and U.Trim(value) or (tostring(value or ""):match("^%s*(.-)%s*$") or "") end

local function Emit(level, code, message, context)
    local diag = S.DiagnosticsManager
    if type(diag) == "table" and type(diag.Emit) == "function" then
        diag:Emit(level, "combat_bus", code, message, context)
    end
end

-- 战斗行每秒可数百次，异常消费者不能把热路径变为每秒数百条日志；计数精确保留，日志行限频。
local function EmitRateLimited(level, code, message, context)
    local diag = S.DiagnosticsManager
    if type(diag) == "table" and type(diag.RateLimited) == "function" then
        return diag:RateLimited(level, "combat_bus", code, 3000, message, context)
    end
    return Emit(level, code, message, context)
end

local EVENT_TYPE_CACHE, EVENT_TYPE_CACHE_COUNT, EVENT_TYPE_CACHE_MAX = {}, 0, 128
local UNKNOWN_EVIDENCE_FIELDS={"transport","sourceName","targetName","abilityName","rawEventType","rawUnitId",
    "rawAbilityId","rawDamageType","rawEffectType","rawIsActive","rawMore1","rawMore2","rawMore3","rawMore4","rawMore5"}
local function DiagnosticScalar(value)
    local kind=type(value)
    if kind=="nil" or kind=="number" or kind=="boolean" then return value end
    if kind~="string" then return "<"..kind..">" end
    if #value<=512 then return value end
    local finish=512
    while finish>0 and (value:byte(finish+1) or 0)>=128 and (value:byte(finish+1) or 0)<192 do finish=finish-1 end
    return value:sub(1,finish).."<clipped>"
end
-- 原生死亡/归属入口先留 64 槽标量证据，再交消费者过滤；普通伤害不入环，停用后保留本代现场。
local noticeEvidence={rows={},next=1,count=0,evicted=0}
local function RecordNoticeEvidence(fact,reason)
    local row={at=fact.receivedAt,sequence=fact.sequence,kind=fact.kind,reason=reason,transport=fact.transport,
        rawEventType=fact.rawEventType,killer=DiagnosticScalar(fact.sourceName),
        victim=DiagnosticScalar(fact.targetName or fact.subjectName),rawNotice2=DiagnosticScalar(fact.rawNotice2),
        rawNotice3=DiagnosticScalar(fact.rawNotice3),rawNotice4=DiagnosticScalar(fact.rawNotice4),rawNotice5=DiagnosticScalar(fact.rawNotice5)}
    noticeEvidence.rows[noticeEvidence.next]=row
    noticeEvidence.next=noticeEvidence.next%64+1
    if noticeEvidence.count<64 then noticeEvidence.count=noticeEvidence.count+1 else noticeEvidence.evicted=noticeEvidence.evicted+1 end
end
local function CopyNoticeEvidence()
    -- 只在导出时按先后复制，不暴露现场表、不消费通知，不触发 Native 或结算。
    local rows={};local first=noticeEvidence.count==64 and noticeEvidence.next or 1
    for offset=0,noticeEvidence.count-1 do
        local copy={};for key,value in pairs(noticeEvidence.rows[(first+offset-1)%64+1]) do copy[key]=value end
        rows[#rows+1]=copy
    end
    return rows
end
-- 未知 Native 类型可能含死亡 ABI：每种仅留首份标量样本，最多 32 种，后续只计数。
function C:_RecordUnrecognizedFact(fact)
    local key=tostring(DiagnosticScalar(fact.rawEventType) or "")
    local row=self.unknownEvidence[key]
    if row then row.count=row.count+1;row.lastAt=fact.receivedAt;return end
    if self.unknownEvidenceCount>=32 then self.unknownTypeDropped=self.unknownTypeDropped+1;return end
    row={count=1,firstAt=fact.receivedAt,lastAt=fact.receivedAt}
    for _,field in ipairs(UNKNOWN_EVIDENCE_FIELDS) do row[field]=DiagnosticScalar(fact[field]) end
    self.unknownEvidence[key]=row;self.unknownEvidenceCount=self.unknownEvidenceCount+1
end
local function MatchesQualified(upper, token)
    if upper == token then return true end
    if #upper <= #token then return false end
    local suffix = string.sub(upper, -#token - 1)
    return suffix == "." .. token or suffix == ":" .. token or suffix == "/" .. token or suffix == "_" .. token
end

function C:DescribeEventType(eventType)
    local raw = tostring(eventType or "")
    local cached = EVENT_TYPE_CACHE[raw]
    if cached ~= nil then return cached end
    local upper = string.upper(Trim(raw))
    local row = { kind = "other", category = "other", environmental = false, auraType = nil }
    -- Aura 事实仅归一化显式 apply/remove 事件；未知类似 BUFF/DEBUFF 的字符串仍为 other。
    if string.find(upper, "DEBUFF_APPLIED", 1, true) ~= nil or string.find(upper, "DEBUFF_ADDED", 1, true) ~= nil then
        row.kind, row.category, row.auraType = "aura_apply", "aura", "debuff"
    elseif string.find(upper, "BUFF_APPLIED", 1, true) ~= nil or string.find(upper, "BUFF_ADDED", 1, true) ~= nil then
        row.kind, row.category, row.auraType = "aura_apply", "aura", "buff"
    elseif string.find(upper, "DEBUFF_REMOVED", 1, true) ~= nil or string.find(upper, "DEBUFF_FADED", 1, true) ~= nil then
        row.kind, row.category, row.auraType = "aura_remove", "aura", "debuff"
    elseif string.find(upper, "BUFF_REMOVED", 1, true) ~= nil or string.find(upper, "BUFF_FADED", 1, true) ~= nil then
        row.kind, row.category, row.auraType = "aura_remove", "aura", "buff"
    elseif string.find(upper, "MELEE_DAMAGE", 1, true) ~= nil then
        row.kind, row.category = "melee_damage", "damage"
    elseif string.find(upper, "SPELL_DAMAGE", 1, true) ~= nil or upper == "SPELL_DOT_DAMAGE" then
        row.kind, row.category = "spell_damage", "damage"
    elseif MatchesQualified(upper, "ENVIRONMENTAL_DAMAGE") or MatchesQualified(upper, "ENVIRONMENTAL_DMANAGE") then
        row.kind, row.category, row.environmental = "environmental_damage", "damage", true
    elseif string.find(upper, "SPELL_HEALED", 1, true) ~= nil or string.find(upper, "HEALED", 1, true) ~= nil then
        row.kind, row.category = "heal", "heal"
    elseif string.find(upper, "MISSED", 1, true) ~= nil then
        row.kind, row.category = "miss", "miss"
    elseif string.find(upper, "DEAD", 1, true) ~= nil then
        row.kind, row.category = "death", "death"
    end
    if EVENT_TYPE_CACHE_COUNT < EVENT_TYPE_CACHE_MAX then
        EVENT_TYPE_CACHE[raw] = row
        EVENT_TYPE_CACHE_COUNT = EVENT_TYPE_CACHE_COUNT + 1
    end
    return row
end

function C:ParseAmount(eventType, abilityId, damageType, effectType)
    local descriptor = self:DescribeEventType(eventType)
    if descriptor.kind == "melee_damage" then return math.abs(tonumber(abilityId) or 0) end
    if descriptor.kind == "spell_damage" or descriptor.kind == "heal" then return math.abs(tonumber(effectType) or 0) end
    if descriptor.kind == "environmental_damage" then return math.abs(tonumber(damageType) or 0) end
    return 0
end

local function NormalizeDemandOptions(options)
    options = type(options) == "table" and options or {}
    local scope = tostring(options.scope or "self"):lower()
    if scope ~= "all" then scope = "self" end
    return { scope = scope }
end

local function NeedsAll(snapshot)
    snapshot = type(snapshot) == "table" and snapshot or {}
    local consumers = type(snapshot.consumers) == "table" and snapshot.consumers or snapshot.consumerOptions
    for _, options in pairs(type(consumers) == "table" and consumers or {}) do
        if type(options) == "table" and options.scope == "all" then return true end
    end
    return false
end

function C:_ReleasePrivateHost()
    local host = self.privateHost
    if host == nil then return true end
    local errors, remaining = {}, {}
    local retainedEvents, retainedHandler = false, false
    for eventName in pairs(self.privateEvents) do
        if type(host.UnregisterEvent) == "function" then
            local ok, result = pcall(host.UnregisterEvent, host, eventName)
            if ok ~= true or result == false then
                remaining[eventName] = true
                if self.optionalKillEvents[eventName]~=nil then
                    -- 可选通知的释放缺口只停放，不让新增入口阻断基础采集的关闭。
                    -- 仍保留实际注册和代次/running防护；诊断如实展示 retained。
                    retainedEvents=true;self.optionalKillEvents[eventName]="retained"
                else errors[#errors + 1] = "UnregisterEvent(" .. tostring(eventName) .. ")=" .. tostring(ok and result or "error") end
            end
        else
            -- 客户端缺释放 API 属于能力缺口，不是业务事务失败；租约宿主保持隐藏停放，回调由
            -- runtime/generation guard 惰性隔离。Feature 关闭不能因此报失败或阻断用户动作。
            remaining[eventName] = true
            retainedEvents = true
        end
    end
    self.privateEvents = remaining
    if self.privateHandlerAttached == true then
        if type(host.ReleaseHandler) == "function" then
            local ok, result = pcall(host.ReleaseHandler, host, "OnEvent")
            if ok == true and result ~= false then
                self.privateHandlerAttached = false
            else
                errors[#errors + 1] = "ReleaseHandler=" .. tostring(ok and result or "error")
            end
        else
            retainedHandler = true
        end
    end
    if type(host.Show) == "function" then pcall(function() host:Show(false) end) end
    -- RU 没有项目已验证的 DestroyWidget；代际内宿主保持隐藏，下次 Demand 0->1 时复用，同代际重复创建相同物
    -- 理 ID 会被拒绝。
    self.privateParked = retainedEvents or retainedHandler
    if retainedEvents == true or retainedHandler == true then
        self.releaseApiMissing = self.releaseApiMissing + 1
    end
    if #errors > 0 then
        self.releaseCallFailures = self.releaseCallFailures + #errors
    end
    if self.privateParked == true and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.WarningRateLimited) == "function" then
        S.DiagnosticsManager:WarningRateLimited("combat_event_bus_v3", "COMBAT_EVENT_BUS_PRIVATE_HOST_RETAINED", 3000,
            "战斗事件总线释放时缺少原生反注册接口，已转为隐藏停放兼容模式。", {
                retainedEvents = retainedEvents == true,
                retainedHandler = retainedHandler == true,
            })
    end
    if #errors > 0 then return false, table.concat(errors, ";") end
    return true
end

function C:_StartPrivateHost()
    local factory = S.NativeObjectFactory
    if type(factory) ~= "table" or type(factory.CreateWindow) ~= "function" then return false, "NativeObjectFactory unavailable" end
    local host = self.privateHost
    if host == nil then
        local createErr
        host, createErr = factory:CreateWindow(S.PhysicalId("combat_event_bus"), "UIParent", "")
        if host == nil then return false, createErr or "combat event host create failed" end
        self.privateHost = host
    end
    if type(host.SetHandler) ~= "function" or type(host.RegisterEvent) ~= "function" then
        if type(host.Show) == "function" then pcall(function() host:Show(false) end) end
        return false, "combat event host methods unavailable"
    end
    if type(host.SetExtent) == "function" then pcall(function() host:SetExtent(1, 1) end) end
    if type(host.EnablePick) == "function" then pcall(function() host:EnablePick(false) end) end
    if self.privateHandlerAttached ~= true then
        local generation = S.Generation
        local ok, result = pcall(host.SetHandler, host, "OnEvent", function(_, eventName,...)
            if C:_IsCurrentGeneration(generation) ~= true or C.running ~= true then return end
            local a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12,a13,a14,a15=...
            if eventName == "COMBAT_MSG" then
                C.privateRows = C.privateRows + 1
                C:_OnCombatRaw("private", a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15)
            elseif eventName == "UNIT_DEAD_NOTICE" then
                C:_OnDeathNotice(a1, a2, a3, a4, a5)
            elseif eventName == "INSTANT_GAME_KILL" or eventName == "UNIT_KILL_STREAK" then
                C:_OnKillNotice(eventName, a1)
            end
        end)
        if ok ~= true or result == false then
            if type(host.Show) == "function" then pcall(function() host:Show(false) end) end
            return false, tostring(ok and "OnEvent returned false" or result)
        end
        self.privateHandlerAttached = true
    end
    for _, eventName in ipairs({ "COMBAT_MSG", "UNIT_DEAD_NOTICE" }) do
        if self.privateEvents[eventName] ~= true then
            local registerOk, registerResult = pcall(function() return host:RegisterEvent(eventName) end)
            if registerOk ~= true or registerResult == false then
                return false, eventName .. " registration failed: " .. tostring(registerOk and "returned false" or registerResult)
            end
            self.privateEvents[eventName] = true
        end
    end
    -- 玩家击杀归属通知共用原私有Host；可选注册失败不阻断基础采集。
    -- 来源：Strawberry-devs/ArcheRage-Scriptsbin@945dcab，chat_msg_event/center_message_manager。
    for _, eventName in ipairs({ "INSTANT_GAME_KILL", "UNIT_KILL_STREAK" }) do
        if self.privateEvents[eventName] ~= true and self.optionalKillEvents[eventName] ~= "unavailable" then
            local ok, result = pcall(host.RegisterEvent, host, eventName)
            if ok and result ~= false then self.privateEvents[eventName]=true;self.optionalKillEvents[eventName]="registered"
            else self.optionalKillEvents[eventName]="unavailable" end
        end
    end
    self.privateParked = false
    return true
end

-- 私有 Window 与 UIParent 的原生通知投递面可能不同，尚待 RU 实机对照。
-- 只补同名的低频明确归属入口，不启用全场 COMBAT_MSG；同一击杀仍由既有指标合并。
function C:_StartKillGlobal()
    if self.killGlobalStarted == true then return true end
    self.killGlobalStarted = true
    self.killGlobalEpoch = self.killGlobalEpoch + 1
    local epoch, generation, owner = self.killGlobalEpoch, S.Generation, self.killGlobalOwner
    local events = S.Events
    for _, eventName in ipairs({ "INSTANT_GAME_KILL", "UNIT_KILL_STREAK" }) do
        local nativeEvent = eventName
        local ok, subscribed = false, false
        if events and type(events.SubscribeGlobalOptional) == "function" and type(events.UnsubscribeGlobalOwner) == "function" then
            ok, subscribed = pcall(events.SubscribeGlobalOptional, events, nativeEvent, owner, function(_, payload)
                if C:_IsCurrentGeneration(generation) ~= true or C.running ~= true
                    or C.killGlobalStarted ~= true or C.killGlobalEpoch ~= epoch then return end
                C:_OnKillNotice(nativeEvent, payload, "private:kill_global")
            end)
        end
        self.killGlobalEvents[nativeEvent] = ok and subscribed == true and "registered" or "unavailable"
        if ok and subscribed == true then self.killGlobalActive = true end
    end
    return true
end

function C:_ReleaseKillGlobal()
    -- Epoch 先撤销执行权，防止同代 Stop/Start 复活旧闭包。
    self.killGlobalEpoch = self.killGlobalEpoch + 1
    self.killGlobalStarted, self.killGlobalActive = false, false
    local events = S.Events
    if events and type(events.UnsubscribeGlobalOwner) == "function" then
        pcall(events.UnsubscribeGlobalOwner, events, self.killGlobalOwner)
    end
    for name, state in pairs(self.killGlobalEvents) do
        -- inactive 表示 Owner 已撤权，不把 Core 中可能停放的 Native 回调谎报为已释放。
        if state == "registered" then self.killGlobalEvents[name] = "inactive" end
    end
    return true
end

local function EventCapability(hostLabel, action)
    return tostring(hostLabel) .. ":" .. tostring(action)
end

function C:_ReleaseGlobalBridge()
    local errors, remaining = {}, {}
    local retainedLabels = {}
    for label, row in pairs(self.globalHandlers) do
        local host, handler = row.host, row.handler
        local released, releaseErr, retained = false, nil, false
        if host ~= nil and handler ~= nil and S.Api ~= nil then
            local cap = EventCapability(label, "ReleaseEventHandler")
            if S.Api:IsCapabilityAllowed(cap) == true then
                released, releaseErr = S.Api:Action(host, "ReleaseEventHandler", row.eventConstant, handler)
            elseif type(host.ReleaseEventHandler) == "function" then
                local ok, result = pcall(host.ReleaseEventHandler, host, row.eventConstant, handler)
                released = ok == true and result ~= false
                if released ~= true then releaseErr = ok and "ReleaseEventHandler returned false" or tostring(result) end
            else
                -- 客户端可注册全局 COMBAT_MSG 却不能释放时，停放惰性处理器，不使功能开关失败。
                retained = true
            end
        elseif host ~= nil and handler ~= nil then
            retained = true
        else
            releaseErr = "global handler unavailable"
        end
        if released ~= true and retained ~= true then
            remaining[label] = row
            errors[#errors + 1] = tostring(label) .. "=" .. tostring(releaseErr or "release failed")
        elseif retained == true then
            remaining[label] = row
            retainedLabels[#retainedLabels + 1] = tostring(label)
        end
    end
    self.globalHandlers = remaining
    self.globalActive = false
    self.globalParkedHosts = #retainedLabels
    self.globalHostCoverage = { UI = remaining.UI ~= nil, UIParent = remaining.UIParent ~= nil }
    self.pairDedup, self.pairOrder, self.pairHead, self.pairPendingCount = {}, {}, 1, 0
    self.journal, self.journalHead = {}, 1
    self.journalDroppedCurrent = 0
    self.releaseApiMissing = self.releaseApiMissing + #retainedLabels
    self.releaseCallFailures = self.releaseCallFailures + #errors
    if #retainedLabels > 0 and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.WarningRateLimited) == "function" then
        S.DiagnosticsManager:WarningRateLimited("combat_event_bus_v3", "COMBAT_EVENT_BUS_GLOBAL_BRIDGE_RETAINED", 3000,
            "战斗事件总线全局桥释放时缺少 ReleaseEventHandler，已转为隐藏停放兼容模式。", {
                retained = table.concat(retainedLabels, ","),
            })
    end
    if #errors > 0 then return false, table.concat(errors, ";") end
    return true
end

function C:_RegisterGlobalHost(label, host, eventConstant)
    if host == nil or S.Api == nil then return false, "host unavailable" end
    local capability = EventCapability(label, "SetEventHandler")
    if S.Api:IsCapabilityAllowed(capability) ~= true then return false, "capability unavailable" end
    local generation = S.Generation
    local handler = function(a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15)
        if C:_IsCurrentGeneration(generation) ~= true or C.running ~= true or C.globalActive ~= true then return end
        C:_OnGlobalCombat(label, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15)
    end
    local ok, result, err = S.Api:Call(host, "SetEventHandler", eventConstant, handler)
    if ok ~= true or result == false then return false, err or "SetEventHandler returned false" end
    self.globalHandlers[label] = { host = host, handler = handler, eventConstant = eventConstant }
    return true
end

function C:_StartGlobalBridge()
    if Identity ~= nil and type(Identity.RefreshPlayerIdentity) == "function" then Identity:RefreshPlayerIdentity(true) end
    local eventConstant = UIEVENT_TYPE ~= nil and UIEVENT_TYPE.COMBAT_MSG or "COMBAT_MSG"
    local wasActive = self.globalActive == true
    if wasActive ~= true then
        self.journal, self.journalHead = {}, 1
        self.journalDroppedCurrent = 0
    end
    local successCount, errors = 0, {}
    if self.globalHandlers.UI ~= nil then
        successCount = successCount + 1
    elseif UI ~= nil then
        local ok, err = self:_RegisterGlobalHost("UI", UI, eventConstant)
        if ok then successCount = successCount + 1 else errors[#errors + 1] = "UI=" .. tostring(err) end
    end
    if self.globalHandlers.UIParent ~= nil then
        successCount = successCount + 1
    elseif UIParent ~= nil then
        local ok, err = self:_RegisterGlobalHost("UIParent", UIParent, eventConstant)
        if ok then successCount = successCount + 1 else errors[#errors + 1] = "UIParent=" .. tostring(err) end
    end
    self.globalHostCoverage = { UI = self.globalHandlers.UI ~= nil, UIParent = self.globalHandlers.UIParent ~= nil }
    if successCount <= 0 then
        self:_ReleaseGlobalBridge()
        return false, "global COMBAT_MSG unavailable: " .. table.concat(errors, ";")
    end
    self.globalActive = true
    self.globalParkedHosts = 0
    return true
end

function C:_Start()
    if self.running == true then
        local ok, err = self:_StartPrivateHost()
        if ok ~= true then return false, err end
        return self:_StartKillGlobal()
    end
    local ok, err = self:_StartPrivateHost()
    if ok ~= true then self.startFailures = self.startFailures + 1; return false, err end
    self.running = true
    if S.Events == nil or type(S.Events.Subscribe) ~= "function" then
        self.running = false
        self:_ReleasePrivateHost()
        self.startFailures = self.startFailures + 1
        return false, "core event bus unavailable"
    end
    local subscribed = S.Events:Subscribe("ENTERED_WORLD", self, function()
        if Identity ~= nil and type(Identity.RefreshPlayerIdentity) == "function" then
            Identity:RefreshPlayerIdentity(true)
            if type(Identity.IsPlayerIdentityReady) == "function" and Identity:IsPlayerIdentityReady() == true then C:_FlushPreIdentityJournal(NowMs()) end
        end
    end)
    if subscribed ~= true then
        self.running = false
        self:_ReleasePrivateHost()
        self.startFailures = self.startFailures + 1
        return false, "ENTERED_WORLD subscribe failed"
    end
    self:_StartKillGlobal() -- 可选入口失败时保留现有私有采集，不添加重试任务。
    return true
end

function C:_Stop()
    self:_ReleaseKillGlobal()
    local globalOk, globalErr = self:_ReleaseGlobalBridge()
    if S.Events ~= nil and type(S.Events.UnsubscribeOwner) == "function" then S.Events:UnsubscribeOwner(self) end
    local privateOk, privateErr = self:_ReleasePrivateHost()
    if globalOk ~= true then self.stopFailures = self.stopFailures + 1; return false, globalErr end
    if privateOk ~= true then self.stopFailures = self.stopFailures + 1; return false, privateErr end
    self.running = false
    -- 全局 Clear 也会经此处归还全部租约，必须同步撤销回调执行权；失败路径仍由 Demand 回滚保留原订阅。
    self:_RevokeSubscribers()
    return true
end

-- Clear 失败后 ForceQuiesce 仍须停止业务回调；宿主可能未解绑，原生闭包先查独立 running/globalActive。
function C:_MarkInert()
    self:_ReleaseKillGlobal()
    self.forcedInert = self.forcedInert + 1
    self.running = false
    self.globalActive = false
    -- 原生解绑失败仍须撤销旧 Owner；后来新消费者重启不能唤醒被强制清空租约的回调。
    self:_RevokeSubscribers()
    self.globalHostCoverage = { UI = false, UIParent = false }
    self.pairDedup, self.pairOrder, self.pairHead, self.pairPendingCount = {}, {}, 1, 0
    self.journal, self.journalHead = {}, 1
    self.journalDroppedCurrent = 0
    return true
end

-- 两种传输共用代际 guard；旧代际表明原生处理器仍归上次插件加载，绝不派发。
function C:_IsCurrentGeneration(generation)
    return tonumber(S.Generation) == tonumber(generation)
end

local function TransportIsPrivate(transport)
    transport = tostring(transport or "")
    return transport == "private" or transport:sub(1, 8) == "private:" or transport == "death_notice"
end

-- self 只收私有 SELF，all 收私有加全局切片；全局桥启用后不能让 self 消费者也承担全部行。
function C:AcceptsTransport(options, transport)
    if type(options) ~= "table" then return true end
    if options.scope == "all" then return true end
    if TransportIsPrivate(transport) then return true end
    return false
end
local AcceptsTransport = function(options, transport) return C:AcceptsTransport(options, transport) end

local function BuildSignature(unitId, eventType, sourceName, targetName, abilityId, abilityName, damageType, effectType, isActive, more, more2, more3, more4, more5)
    local sep = "\31"
    return tostring(unitId or "") .. sep .. tostring(eventType or "") .. sep
        .. tostring(sourceName or "") .. sep .. tostring(targetName or "") .. sep
        .. tostring(abilityId or "") .. sep .. tostring(abilityName or "") .. sep
        .. tostring(damageType or "") .. sep .. tostring(effectType or "") .. sep
        .. tostring(isActive or "") .. sep .. tostring(more or "") .. sep
        .. tostring(more2 or "") .. sep .. tostring(more3 or "") .. sep
        .. tostring(more4 or "") .. sep .. tostring(more5 or "")
end

local function CompactPairOrder(bus)
    if bus.pairHead <= 256 or bus.pairHead <= (#bus.pairOrder / 2) then return end
    local compact = {}
    for index = bus.pairHead, #bus.pairOrder do
        local token = bus.pairOrder[index]
        if token ~= nil and token.active == true then compact[#compact + 1] = token end
    end
    bus.pairOrder, bus.pairHead = compact, 1
end

local function AdvancePairHead(bus)
    local head = math.max(1, tonumber(bus.pairHead) or 1)
    while head <= #bus.pairOrder do
        local token = bus.pairOrder[head]
        if token ~= nil and token.active == true then break end
        head = head + 1
    end
    bus.pairHead = head
    if head > #bus.pairOrder then
        bus.pairOrder, bus.pairHead = {}, 1
        return
    end
    CompactPairOrder(bus)
end

local function QueueHasActive(queue)
    if type(queue) ~= "table" then return false end
    local head = math.max(1, tonumber(queue.head) or 1)
    for index = head, #queue do
        local token = queue[index]
        if token ~= nil and token.active == true then return true end
    end
    return false
end

local function EntryHasActive(entry)
    if type(entry) ~= "table" or type(entry.hosts) ~= "table" then return false end
    for _, queue in pairs(entry.hosts) do if QueueHasActive(queue) then return true end end
    return false
end

local function PopMatchingToken(bus, queue, now)
    if type(queue) ~= "table" then return nil end
    local ttl = math.max(1, tonumber(bus.pairTtlMs) or 50)
    local head = math.max(1, tonumber(queue.head) or 1)
    while head <= #queue do
        local token = queue[head]
        head = head + 1
        queue.head = head
        if token ~= nil and token.active == true then
            local age = now - (tonumber(token.at) or 0)
            if age <= ttl and age >= 0 then
                token.active = false
                bus.pairPendingCount = math.max(0, (tonumber(bus.pairPendingCount) or 0) - 1)
                return token
            end
            token.active = false
            bus.pairPendingCount = math.max(0, (tonumber(bus.pairPendingCount) or 0) - 1)
            bus.globalCrossHostEvicted = bus.globalCrossHostEvicted + 1
        end
    end
    return nil
end

local function ExpireOldestPairTokens(bus, now)
    local ttl = math.max(1, tonumber(bus.pairTtlMs) or 50)
    local head = math.max(1, tonumber(bus.pairHead) or 1)
    while head <= #bus.pairOrder do
        local token = bus.pairOrder[head]
        if token == nil or token.active ~= true then
            head = head + 1
        else
            local age = now - (tonumber(token.at) or 0)
            if age <= ttl then break end
            token.active = false
            bus.pairPendingCount = math.max(0, (tonumber(bus.pairPendingCount) or 0) - 1)
            bus.globalCrossHostEvicted = bus.globalCrossHostEvicted + 1
            local entry = bus.pairDedup[token.key]
            if EntryHasActive(entry) ~= true then bus.pairDedup[token.key] = nil end
            head = head + 1
        end
    end
    bus.pairHead = head
    AdvancePairHead(bus)
end

local function EvictOldestPairToken(bus)
    while bus.pairHead <= #bus.pairOrder do
        local token = bus.pairOrder[bus.pairHead]
        bus.pairHead = bus.pairHead + 1
        if token ~= nil and token.active == true then
            token.active = false
            bus.pairPendingCount = math.max(0, (tonumber(bus.pairPendingCount) or 0) - 1)
            bus.globalCrossHostEvicted = bus.globalCrossHostEvicted + 1
            local entry = bus.pairDedup[token.key]
            if EntryHasActive(entry) ~= true then bus.pairDedup[token.key] = nil end
            AdvancePairHead(bus)
            return true
        end
    end
    CompactPairOrder(bus)
    return false
end

function C:_IsCrossHostDuplicate(hostLabel, signature, now)
    hostLabel = tostring(hostLabel or "")
    now = tonumber(now) or NowMs()
    ExpireOldestPairTokens(self, now)
    local entry = self.pairDedup[signature]
    if type(entry) ~= "table" then
        entry = { hosts = {} }
        self.pairDedup[signature] = entry
    end

    -- 跨宿主用 FIFO token 逐次配对；单槽 map 会漏掉 UI,UI,UIParent,UIParent 的第四条镜像。
    for otherHost, queue in pairs(entry.hosts) do
        if otherHost ~= hostLabel then
            local token = PopMatchingToken(self, queue, now)
            if token ~= nil then
                self.globalCrossHostDuplicates = self.globalCrossHostDuplicates + 1
                if EntryHasActive(entry) ~= true then self.pairDedup[signature] = nil end
                AdvancePairHead(self)
                return true
            end
        end
    end

    while (tonumber(self.pairPendingCount) or 0) >= self.pairMax do
        if EvictOldestPairToken(self) ~= true then break end
    end
    self.pairSerial = self.pairSerial + 1
    local token = { key = signature, host = hostLabel, at = now, serial = self.pairSerial, active = true }
    local queue = entry.hosts[hostLabel]
    if type(queue) ~= "table" then queue = { head = 1 }; entry.hosts[hostLabel] = queue end
    queue[#queue + 1] = token
    self.pairOrder[#self.pairOrder + 1] = token
    self.pairPendingCount = (tonumber(self.pairPendingCount) or 0) + 1
    CompactPairOrder(self)
    return false
end

local function JournalActiveCount(bus)
    return math.max(0, #bus.journal - (tonumber(bus.journalHead) or 1) + 1)
end

function C:_DropExpiredJournal(now)
    now = tonumber(now) or NowMs()
    local head = math.max(1, tonumber(self.journalHead) or 1)
    while head <= #self.journal do
        local row = self.journal[head]
        if row ~= nil and now - (tonumber(row.at) or 0) <= self.journalTtlMs then break end
        head = head + 1
        self.journalDropped = self.journalDropped + 1
        self.journalDroppedCurrent = self.journalDroppedCurrent + 1
    end
    self.journalHead = head
end

function C:_JournalGlobal(hostLabel, now, ...)
    self:_DropExpiredJournal(now)
    while JournalActiveCount(self) >= self.journalMax do
        self.journalHead = self.journalHead + 1
        self.journalDropped = self.journalDropped + 1
        self.journalDroppedCurrent = self.journalDroppedCurrent + 1
    end
    self.journal[#self.journal + 1] = { host = hostLabel, at = now, args = { ... } }
    self.journalQueued = self.journalQueued + 1
    self.globalNoIdentitySuppressed = self.globalNoIdentitySuppressed + 1
    if self.journalHead > 256 and self.journalHead > (#self.journal / 2) then
        local compact = {}
        for index = self.journalHead, #self.journal do compact[#compact + 1] = self.journal[index] end
        self.journal, self.journalHead = compact, 1
    end
    return true
end

function C:_ProcessGlobalCombat(hostLabel, receivedAt, unitId, eventType, sourceName, targetName, abilityId, abilityName, damageType, effectType, isActive, more, more2, more3, more4, more5)
    local now = tonumber(receivedAt) or NowMs()
    if Identity:IsPlayerName(sourceName) or Identity:IsPlayerName(targetName) then
        self.globalSelfFiltered = self.globalSelfFiltered + 1
        return false, "self_filtered"
    end
    local signature = BuildSignature(unitId, eventType, sourceName, targetName, abilityId, abilityName, damageType, effectType, isActive, more, more2, more3, more4, more5)
    if self:_IsCrossHostDuplicate(hostLabel, signature, now) then return false, "cross_host_duplicate" end
    self.globalRows = self.globalRows + 1
    self:_OnCombatRaw("global:" .. tostring(hostLabel), unitId, eventType, sourceName, targetName, abilityId, abilityName, damageType, effectType, isActive, more, more2, more3, more4, more5, now)
    return true
end

function C:_FlushPreIdentityJournal(now)
    if Identity == nil or type(Identity.IsPlayerIdentityReady) ~= "function" or Identity:IsPlayerIdentityReady() ~= true then return false, "identity_not_ready" end
    -- 身份就绪后的普通全局行也会经过此处；空 journal 保留已有容器，避免镜像行逐条制造空表垃圾。
    if #self.journal == 0 then self.journalHead = 1; return true, 0 end
    now = tonumber(now) or NowMs()
    self:_DropExpiredJournal(now)
    local head, last = math.max(1, tonumber(self.journalHead) or 1), #self.journal
    if head > last then self.journal, self.journalHead = {}, 1; return true, 0 end
    local replayed = 0
    for index = head, last do
        local row = self.journal[index]
        if row ~= nil then
            if now - (tonumber(row.at) or 0) <= self.journalTtlMs then
                self:_ProcessGlobalCombat(row.host, row.at, unpack(row.args or {}))
                replayed = replayed + 1
            else
                self.journalDropped = self.journalDropped + 1
                self.journalDroppedCurrent = self.journalDroppedCurrent + 1
            end
        end
    end
    self.journal, self.journalHead = {}, 1
    self.journalReplayed = self.journalReplayed + replayed
    return true, replayed
end

function C:GetCoverageState()
    if self.globalActive ~= true then return "INACTIVE" end
    if Identity == nil or type(Identity.IsPlayerIdentityReady) ~= "function" or Identity:IsPlayerIdentityReady() ~= true then return "IDENTITY_COLD" end
    local ui, parent = self.globalHostCoverage.UI == true, self.globalHostCoverage.UIParent == true
    if ui ~= true and parent ~= true then return "UNAVAILABLE" end
    if self.journalDroppedCurrent > 0 or not (ui and parent) then return "DEGRADED" end
    return "FULL"
end

function C:_OnGlobalCombat(hostLabel, unitId, eventType, sourceName, targetName, abilityId, abilityName, damageType, effectType, isActive, more, more2, more3, more4, more5)
    local now = NowMs()
    local playerReady = Identity ~= nil and type(Identity.IsPlayerIdentityReady) == "function" and Identity:IsPlayerIdentityReady() == true
    if playerReady ~= true then
        if now - (tonumber(self.lastPlayerRefreshAt) or -1) >= 1000 and Identity ~= nil and type(Identity.RefreshPlayerIdentity) == "function" then
            self.lastPlayerRefreshAt = now
            Identity:RefreshPlayerIdentity(true)
            playerReady = Identity:IsPlayerIdentityReady() == true
        end
        if playerReady ~= true then
            return self:_JournalGlobal(hostLabel, now, unitId, eventType, sourceName, targetName, abilityId, abilityName, damageType, effectType, isActive, more, more2, more3, more4, more5)
        end
    end
    self:_FlushPreIdentityJournal(now)
    return self:_ProcessGlobalCombat(hostLabel, now, unitId, eventType, sourceName, targetName, abilityId, abilityName, damageType, effectType, isActive, more, more2, more3, more4, more5)
end

function C:_NormalizeCombatFact(transport, unitId, eventType, sourceName, targetName, abilityId, abilityName, damageType, effectType, isActive, more, more2, more3, more4, more5, receivedAt)
    local descriptor = self:DescribeEventType(eventType)
    self.sequence = self.sequence + 1
    local fact = {
        schemaVersion = 1,
        sequence = self.sequence,
        receivedAt = tonumber(receivedAt) or NowMs(),
        transport = tostring(transport or "unknown"),
        kind = descriptor.kind,
        category = descriptor.category,
        environmental = descriptor.environmental == true,
        amount = self:ParseAmount(eventType, abilityId, damageType, effectType),
        sourceName = Trim(sourceName),
        targetName = Trim(targetName),
        abilityName = Trim(abilityName),
        rawUnitId = unitId ~= nil and tostring(unitId) or nil,
        rawEventType = eventType,
        rawAbilityId = abilityId,
        rawDamageType = damageType,
        rawEffectType = effectType,
        rawIsActive = isActive,
        rawMore1 = more,
        rawMore2 = more2,
        rawMore3 = more3,
        rawMore4 = more4,
        rawMore5 = more5,
        auraType = descriptor.auraType,
        auraId = descriptor.category == "aura" and tonumber(abilityId) or nil,
        auraName = descriptor.category == "aura" and Trim(abilityName) or nil,
        auraEvidence = descriptor.category == "aura" and "event_type" or nil,
    }
    if descriptor.kind == "other" then
        self.unknownKinds = self.unknownKinds + 1
        self:_RecordUnrecognizedFact(fact)
    end
    if Identity ~= nil and type(Identity.ResolveCombatEndpoint) == "function" then
        local binding = Identity:ResolveCombatEndpoint(unitId, fact.sourceName, fact.targetName)
        if binding ~= nil then
            fact.boundRole = binding.role
            fact.boundConfidence = binding.confidence
            if binding.role == "source" then fact.sourceId = binding.id else fact.targetId = binding.id end
            -- UnitIdentity 拥有显式 kind 读取并按稳定 ID 缓存；CombatFact 携带已验证事实，避免各消费者重复
            -- GetUnitInfoById 或私建 PLAYER/NPC 逻辑。
            if type(Identity.GetById) == "function" then
                local info = Identity:GetById(binding.id, { includeKind = true })
                if type(info) == "table" and info.kindReliable == true then
                    if binding.role == "source" then fact.sourceKind = info.kind else fact.targetKind = info.kind end
                end
            end
        end
    end
    return fact
end

local function RestorePrimaryFact(fact, schemaVersion, sequence, receivedAt, transport, kind, category, amount, sourceName, targetName, sourceId, targetId, sourceKind, targetKind, abilityName, environmental, boundRole, boundConfidence)
    fact.schemaVersion, fact.sequence, fact.receivedAt = schemaVersion, sequence, receivedAt
    fact.transport, fact.kind, fact.category, fact.amount = transport, kind, category, amount
    fact.sourceName, fact.targetName, fact.sourceId, fact.targetId = sourceName, targetName, sourceId, targetId
    fact.sourceKind, fact.targetKind = sourceKind, targetKind
    fact.abilityName, fact.environmental = abilityName, environmental
    fact.boundRole, fact.boundConfidence = boundRole, boundConfidence
end

local function RestoreRawFact(fact, rawUnitId, rawEventType, rawAbilityId, rawDamageType, rawEffectType, rawIsActive, rawMore1, rawMore2, rawMore3, rawMore4, rawMore5, subjectName, rawNotice2, rawNotice3, rawNotice4, rawNotice5)
    fact.rawUnitId, fact.rawEventType, fact.rawAbilityId = rawUnitId, rawEventType, rawAbilityId
    fact.rawDamageType, fact.rawEffectType, fact.rawIsActive = rawDamageType, rawEffectType, rawIsActive
    fact.rawMore1, fact.rawMore2, fact.rawMore3, fact.rawMore4, fact.rawMore5 = rawMore1, rawMore2, rawMore3, rawMore4, rawMore5
    fact.subjectName = subjectName
    fact.rawNotice2, fact.rawNotice3, fact.rawNotice4, fact.rawNotice5 = rawNotice2, rawNotice3, rawNotice4, rawNotice5
end

function C:_CompactSubscriberOrder()
    if self.dispatchDepth > 0 or self.subscriberTombstones <= 0 then return end
    local compact = {}
    for _, row in ipairs(self.subscriberOrder) do
        if row ~= nil and row.active == true and self.subscribers[row.owner] == row then compact[#compact + 1] = row end
    end
    self.subscriberOrder = compact
    self.subscriberTombstones = 0
end

function C:_RevokeSubscribers()
    -- 派发中只标记旧行无效，保留快照下标；当前回调返回后跳过旧尾部，再统一压缩。
    -- 清空 owner 映射使同一 Owner 重新获取时创建新行，不复用已撤销的执行权。
    for _, row in pairs(self.subscribers) do
        row.active = false
        self.subscriberTombstones = self.subscriberTombstones + 1
    end
    self.subscribers, self.subscriberCount = {}, 0
    self:_CompactSubscriberOrder()
end

-- 每层同步派发独占一个 xpcall 工作帧，保留原有局部事实快照和逐订阅者恢复边界。
-- 常驻最多八层；更深重入使用临时帧，不能无限扩大常驻空间，也不能复用外层执行中的借用事实。
local callbackFrames, CALLBACK_FRAME_LIMIT = {}, 8
local function AcquireCallbackFrame(depth)
    local frame = callbackFrames[depth]
    if frame == nil then
        frame = {}
        frame.invoke = function() frame.callback(frame.owner, frame.fact) end
        if depth <= CALLBACK_FRAME_LIMIT then callbackFrames[depth] = frame end
    end
    return frame
end

function C:_DispatchFact(fact)
    self.received = self.received + 1
    local delivered = 0
    self.dispatchDepth = self.dispatchDepth + 1
    local callbackFrame = AcquireCallbackFrame(self.dispatchDepth)
    local limit = #self.subscriberOrder
    for index = 1, limit do
        local row = self.subscriberOrder[index]
        local owner = row and row.owner or nil
        if row ~= nil and row.active == true and owner ~= nil and self.subscribers[owner] == row and type(row.callback) == "function" then
            if AcceptsTransport(row.options, fact.transport) ~= true then
                self.scopeFiltered = self.scopeFiltered + 1
            else
            -- CombatFact 是借用且不可变；捕获主要语义字段，防止异常消费者污染后续消费者，也避免每条
            -- all-scope 行 DeepCopy。
            local schemaVersion, sequence, receivedAt = fact.schemaVersion, fact.sequence, fact.receivedAt
            local transport, kind, category, amount = fact.transport, fact.kind, fact.category, fact.amount
            local sourceName, targetName, sourceId, targetId = fact.sourceName, fact.targetName, fact.sourceId, fact.targetId
            local sourceKind, targetKind = fact.sourceKind, fact.targetKind
            local abilityName, environmental = fact.abilityName, fact.environmental
            local boundRole, boundConfidence = fact.boundRole, fact.boundConfidence
            local rawUnitId, rawEventType, rawAbilityId = fact.rawUnitId, fact.rawEventType, fact.rawAbilityId
            local rawDamageType, rawEffectType, rawIsActive = fact.rawDamageType, fact.rawEffectType, fact.rawIsActive
            local rawMore1, rawMore2, rawMore3, rawMore4, rawMore5 = fact.rawMore1, fact.rawMore2, fact.rawMore3, fact.rawMore4, fact.rawMore5
            local subjectName = fact.subjectName
            local rawNotice2, rawNotice3, rawNotice4, rawNotice5 = fact.rawNotice2, fact.rawNotice3, fact.rawNotice4, fact.rawNotice5
            local auraType, auraId, auraName, auraEvidence = fact.auraType, fact.auraId, fact.auraName, fact.auraEvidence
            local token = S.PerformanceMonitor and S.PerformanceMonitor:Begin(row.performanceLabel or "combat_fact:consumer", row.label or "combat") or nil
            callbackFrame.callback, callbackFrame.owner, callbackFrame.fact = row.callback, owner, fact
            local ok, err = xpcall(callbackFrame.invoke, S.SafeTraceback)
            -- 借用的 callback/owner/fact 无论成功或抛错都立即归还；Stop/退订不能让工作帧延长旧消费者生命周期。
            callbackFrame.callback, callbackFrame.owner, callbackFrame.fact = nil, nil, nil
            if S.PerformanceMonitor ~= nil then S.PerformanceMonitor:End(token) end
            local mutated = fact.schemaVersion ~= schemaVersion or fact.sequence ~= sequence or fact.receivedAt ~= receivedAt
                or fact.transport ~= transport or fact.kind ~= kind or fact.category ~= category or fact.amount ~= amount
                or fact.sourceName ~= sourceName or fact.targetName ~= targetName or fact.sourceId ~= sourceId or fact.targetId ~= targetId
                or fact.sourceKind ~= sourceKind or fact.targetKind ~= targetKind
                or fact.abilityName ~= abilityName or fact.environmental ~= environmental or fact.boundRole ~= boundRole or fact.boundConfidence ~= boundConfidence
                or fact.rawUnitId ~= rawUnitId or fact.rawEventType ~= rawEventType or fact.rawAbilityId ~= rawAbilityId
                or fact.rawDamageType ~= rawDamageType or fact.rawEffectType ~= rawEffectType or fact.rawIsActive ~= rawIsActive
                or fact.rawMore1 ~= rawMore1 or fact.rawMore2 ~= rawMore2 or fact.rawMore3 ~= rawMore3 or fact.rawMore4 ~= rawMore4 or fact.rawMore5 ~= rawMore5
                or fact.subjectName ~= subjectName or fact.rawNotice2 ~= rawNotice2 or fact.rawNotice3 ~= rawNotice3
                or fact.rawNotice4 ~= rawNotice4 or fact.rawNotice5 ~= rawNotice5
                or fact.auraType ~= auraType or fact.auraId ~= auraId or fact.auraName ~= auraName or fact.auraEvidence ~= auraEvidence
            if mutated then
                self.factMutationErrors = self.factMutationErrors + 1
                RestorePrimaryFact(fact, schemaVersion, sequence, receivedAt, transport, kind, category, amount, sourceName, targetName, sourceId, targetId, sourceKind, targetKind, abilityName, environmental, boundRole, boundConfidence)
                RestoreRawFact(fact, rawUnitId, rawEventType, rawAbilityId, rawDamageType, rawEffectType, rawIsActive, rawMore1, rawMore2, rawMore3, rawMore4, rawMore5, subjectName, rawNotice2, rawNotice3, rawNotice4, rawNotice5)
                fact.auraType, fact.auraId, fact.auraName, fact.auraEvidence = auraType, auraId, auraName, auraEvidence
                EmitRateLimited("error", "COMBAT_FACT_MUTATED", "战斗事实消费者修改了共享 CombatFact，已恢复全部公开事实字段", { consumer = tostring(row.label or "unknown"), sequence = tostring(sequence or "?") })
            end
            if ok then delivered = delivered + 1 else
                self.callbackErrors = self.callbackErrors + 1
                EmitRateLimited("error", "COMBAT_CONSUMER_CALLBACK_FAILED", "战斗事实消费者回调失败", { consumer = tostring(row.label or "unknown"), error = tostring(err) })
            end
            end
        end
    end
    self.dispatchDepth = math.max(0, self.dispatchDepth - 1)
    self:_CompactSubscriberOrder()
    self.delivered = self.delivered + delivered
    return delivered
end

function C:_OnCombatRaw(transport, unitId, eventType, sourceName, targetName, abilityId, abilityName, damageType, effectType, isActive, more, more2, more3, more4, more5, receivedAt)
    -- 此处再查 running，覆盖 journal 回放和停放宿主等内部入口，释放租约后不能继续派发。
    if self.running ~= true then return 0 end
    local fact = self:_NormalizeCombatFact(transport, unitId, eventType, sourceName, targetName, abilityId, abilityName, damageType, effectType, isActive, more, more2, more3, more4, more5, receivedAt)
    return self:_DispatchFact(fact)
end

function C:_OnDeathNotice(info1, info2, info3, info4, info5)
    if self.running ~= true then return 0 end
    self.sequence = self.sequence + 1
    local fact = {
        schemaVersion = 1,
        sequence = self.sequence,
        receivedAt = NowMs(),
        transport = "private",
        kind = "death_notice",
        category = "death",
        subjectName = Trim(info1),
        rawNotice2 = info2,
        rawNotice3 = info3,
        rawNotice4 = info4,
        rawNotice5 = info5,
    }
    RecordNoticeEvidence(fact,"normalized")
    return self:_DispatchFact(fact)
end

-- 原生死亡通知只有姓名；这两个原生战场通知另外给出明确的击杀者。
-- 不解析聊天译文、不猜最后一击、不扩大全场 COMBAT_MSG 订阅，不保留原生 table。
function C:_OnKillNotice(eventName, payload, transport)
    if self.running ~= true then return 0 end
    transport = transport == "private:kill_global" and transport or "private"
    local route = self.killNoticeSources[transport == "private:kill_global" and "global" or "private"]
    route.received = route.received + 1
    self.killNoticeRows=self.killNoticeRows+1
    local killer,victim,streak,mode,param1,param2
    if type(payload)=="table" then
        if eventName=="INSTANT_GAME_KILL" then
            killer,victim,streak,mode=payload.killer,payload.victim,payload.killerKillstreak,payload.ruleMode
        elseif eventName=="UNIT_KILL_STREAK" then
            killer,victim,streak,mode=payload.killerName,payload.victimName,payload.killerKillStreak,payload.gameType
            -- 原生提示也读取这两项；野外模式的数值语义尚未确认，只留标量供漏记核对。
            param1,param2=payload.param1,payload.param2
        end
    end
    if type(killer)~="string" or type(victim)~="string" or #killer>512 or #victim>512
        or Trim(killer)=="" or Trim(victim)=="" or Trim(killer)==Trim(victim) then
        -- 非法字段仅留类型/截断标量，不放宽击杀 ABI；未形成 CombatFact 的行没有 sequence。
        RecordNoticeEvidence({receivedAt=NowMs(),transport=transport,kind="kill_notice",rawEventType=eventName,sourceName=killer,targetName=victim,
            rawNotice2=streak,rawNotice3=mode,rawNotice4=param1,rawNotice5=param2},"invalid_payload")
        route.rejected=route.rejected+1
        self.killNoticeRejected=self.killNoticeRejected+1;return 0
    end
    self.sequence=self.sequence+1
    local fact={schemaVersion=1,sequence=self.sequence,receivedAt=NowMs(),transport=transport,
        kind="kill_notice",category="death",rawEventType=eventName,sourceName=Trim(killer),targetName=Trim(victim),
        -- 这些是原生 BattleField 玩家击杀通知；常规 COMBAT_MSG 的类型仍由单位事实确认。
        sourceKind="PLAYER",targetKind="PLAYER",rawNotice2=DiagnosticScalar(streak),rawNotice3=DiagnosticScalar(mode),
        rawNotice4=DiagnosticScalar(param1),rawNotice5=DiagnosticScalar(param2)}
    RecordNoticeEvidence(fact,"normalized") -- sequence 只关联入口、过滤和计数证据，不能据此补算击杀。
    return self:_DispatchFact(fact)
end

function C:GetDiagnosticDetail()
    local keys,rows={},{}
    for key in pairs(self.unknownEvidence) do keys[#keys+1]=key end
    table.sort(keys)
    for _,key in ipairs(keys) do
        local copy={};for field,value in pairs(self.unknownEvidence[key]) do copy[field]=value end
        rows[#rows+1]=copy
    end
    local events={};for key,value in pairs(self.optionalKillEvents) do events[key]=value end
    local globalEvents={};for key,value in pairs(self.killGlobalEvents) do globalEvents[key]=value end
    local privateSource,globalSource=self.killNoticeSources.private,self.killNoticeSources.global
    -- received/rejected 仍只统计原生归属；events 同时含姓名死亡通知，显式给出覆盖淘汰数。
    return {health=self:GetHealth(),killNotifications={registrations=events,running=self.running,received=self.killNoticeRows,rejected=self.killNoticeRejected,
        sources={private={transport="private",running=self.running and self.privateHandlerAttached==true,registrations=events,
                received=privateSource.received,rejected=privateSource.rejected},
            global={transport="private:kill_global",running=self.killGlobalActive==true,registrations=globalEvents,
                received=globalSource.received,rejected=globalSource.rejected}},
        events=CopyNoticeEvidence(),evicted=noticeEvidence.evicted,limit=64},unknownEvents=rows,unknownTypeDropped=self.unknownTypeDropped,unknownTypeLimit=32,
        coverage="未知类型仅保留本次加载每种类型的首次标量样本；不改变类型解释或击杀归属。"}
end

function C:_ReconcileDemand(_, before, after, context)
    local beforeCount, afterCount = tonumber(before and before.count) or 0, tonumber(after and after.count) or 0
    if beforeCount <= 0 and afterCount > 0 then
        local ok, err = self:_Start()
        if ok ~= true then return false, err end
    end
    local wantAll = NeedsAll(after)
    if wantAll then
        local ok, err = self:_StartGlobalBridge()
        if ok ~= true then return false, err end
    elseif self.globalActive == true then
        local ok, err = self:_ReleaseGlobalBridge()
        if ok ~= true then return false, err end
    end
    if beforeCount > 0 and afterCount <= 0 then
        local ok, err = self:_Stop()
        if ok ~= true then return false, err end
    end
    return true
end

if S.Demand ~= nil and type(S.Demand.Create) == "function" then
    C.demand = S.Demand:Create({
        id = "service.combat_event_bus",
        owner = C,
        normalize = NormalizeDemandOptions,
        reconcile = function(lease, before, after, context) return C:_ReconcileDemand(lease, before, after, context) end,
        -- 尽力原生解绑，无论结果总线都变惰性，强制静止后无业务回调存活；真实释放错误仍报告，不能静默吞掉。
        quiesce = function()
            local released, releaseErr = C:_Stop()
            C:_MarkInert()
            return released, releaseErr
        end,
        projectionOwner = C,
        projectionConsumersField = "consumerOptions",
        projectionCountField = "consumerCount",
    })
end

function C:Subscribe(owner, callback, options)
    if owner == nil or type(callback) ~= "function" then return false, "owner/callback required" end
    if self.demand == nil then return false, "combat demand unavailable" end
    local existing = self.subscribers[owner]
    local token = existing and existing.token or ("combat:" .. tostring(self.subscriberSerial + 1))
    local ok, err = self.demand:Acquire(token, options, "combat_subscribe")
    if ok ~= true then return false, err end
    if existing == nil then
        self.subscriberSerial = self.subscriberSerial + 1
        self.subscriberCount = self.subscriberCount + 1
        existing = { token = token, owner = owner, serial = self.subscriberSerial, active = true }
        self.subscribers[owner] = existing
        self.subscriberOrder[#self.subscriberOrder + 1] = existing
    end
    existing.active = true
    existing.callback = callback
    existing.options = NormalizeDemandOptions(options)
    existing.label = tostring((type(owner) == "table" and (owner.Id or owner.id or owner.Name or owner.name)) or owner or token)
    existing.performanceLabel = "combat_fact:" .. existing.label
    return true
end

function C:Unsubscribe(owner)
    if owner == nil then return false, "owner required" end
    local row = self.subscribers[owner]
    -- 总线全局清理已撤销回调时，上层可幂等确认释放；有记录的失败仍保留并返回真实错误。
    if row == nil then return true end
    local ok, err = self.demand:Release(row.token, "combat_unsubscribe")
    if ok ~= true then return false, err end
    -- 最后消费者成功 Stop 已撤销整组订阅，不能重复扣计数或误删后来替换的行。
    if self.subscribers[owner] == row then
        self.subscribers[owner] = nil
        row.active = false
        self.subscriberTombstones = self.subscriberTombstones + 1
        self.subscriberCount = math.max(0, self.subscriberCount - 1)
        self:_CompactSubscriberOrder()
    end
    return true
end

function C:GetHealth()
    return {
        version = self.version,
        running = self.running == true,
        consumers = tonumber(self.consumerCount) or 0,
        subscribers = self.subscriberCount,
        globalActive = self.globalActive == true,
        coverageState = self:GetCoverageState(),
        globalHosts = (self.globalHandlers.UI and 1 or 0) + (self.globalHandlers.UIParent and 1 or 0),
        globalUI = self.globalHostCoverage.UI == true,
        globalUIParent = self.globalHostCoverage.UIParent == true,
        privateParked = self.privateParked == true,
        globalParkedHosts = tonumber(self.globalParkedHosts) or 0,
        scope = NeedsAll(self) and "all" or (self.subscriberCount > 0 and "self" or "none"),
        scopeFiltered = self.scopeFiltered,
        releaseApiMissing = self.releaseApiMissing,
        releaseCallFailures = self.releaseCallFailures,
        stopFailures = self.stopFailures,
        forcedInert = self.forcedInert,
        journalPending = JournalActiveCount(self),
        journalQueued = self.journalQueued,
        journalReplayed = self.journalReplayed,
        journalDropped = self.journalDropped,
        received = self.received,
        delivered = self.delivered,
        privateRows = self.privateRows,
        globalRows = self.globalRows,
        globalSelfFiltered = self.globalSelfFiltered,
        globalNoIdentitySuppressed = self.globalNoIdentitySuppressed,
        globalCrossHostDuplicates = self.globalCrossHostDuplicates,
        globalCrossHostPending = tonumber(self.pairPendingCount) or 0,
        globalCrossHostEvicted = self.globalCrossHostEvicted,
        callbackErrors = self.callbackErrors,
        factMutationErrors = self.factMutationErrors,
        unknownKinds = self.unknownKinds,
        startFailures = self.startFailures,
    }
end
