------------------------------------------------------------------------
-- Replicated Suite V3 - Buff Display Feature (Runtime Lanes)
--
-- AuraObservationV3 stays the single Aura Authority. This Feature owns:
--   * scope policy (player/target) and bounded projection for the page table
--   * six independent runtime lanes, each gated by the components it feeds:
--       aura      -> Buff/Debuff facts (page table + head buffs/debuffs)
--       position  -> unit screen projection (all head components)
--       distance  -> UnitDistance (distance component)
--       metadata  -> GetTargetAbilityTemplates class (class component)
--       equipment -> UnitGearScore + equipped slots (gearScore/weapons/wings)
--       cast      -> UnitCastingInfo (castBar component)
--   * UnitGearScore is unit-token keyed and read directly for player/target.
--     It is deliberately NOT gated by target kind: the 2026-09-11 RU API
--     update made kind resolution less reliable while UnitGearScore("target")
--     remains the authoritative read. Equipped icons are still player-scope
--     only: the RU client ignores
--     GetEquippedItemTooltipInfo's targetEquippedItem flag (returns own gear),
--     so a target read can never be trusted (evidence 2026-09-01).
--   * O(1) tracked index rebuilt on demand
--   * management-only session retention: keep old and newly observed rows until explicit clear
--     without altering live HUD lanes (implemented in rs_buff_display_management.lua)
--   * tracked-id import / full export-import with schema migration awareness
--
-- Closing a component stops its lane tasks and clears its cached facts; hiding
-- the window is NOT the same as disabling a component. Demand leases are still
-- reconciled through the shared Feature Runtime.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Runtime = S.FeatureRuntime
S.Features = S.Features or {}
S.Features.BuffDisplay = S.Features.BuffDisplay or {}
local F = S.Features.BuffDisplay
if type(Runtime) ~= "table" then return end

F.Id = "combat_buff_display"
F.EquipmentReadContractVersion = 1 -- player equipped icons read through shared GearV3 authority
F.GearScoreApiContractVersion = 1 -- UnitGearScore(unit, comma=false) + target read independent of kind classification
F.enabled = F.enabled == true
F.consumers, F.consumerCount = {}, 0
F.auraHeld = false
F.castingHeld = false
F.taskName = "v3_buff_display_refresh"          -- aura lane task (contract kept)
F.eventTaskName = "v3_buff_display_event_refresh"
F.eventSubscribed = false
F.eventEdges = tonumber(F.eventEdges) or 0
F.revision = tonumber(F.revision) or 0
F.settingsRevision = tonumber(F.settingsRevision) or 0
F.projections = F.projections or { player = {}, target = {} }
F.coverage = F.coverage or { player = {}, target = {} }
F.laneData = F.laneData or { player = {}, target = {} }
F.trackedIndex = F.trackedIndex or { buff = {}, debuff = {}, auto = {} }
-- 中文维护注释：清理旧 tracked-only 快照引用；唯一会话快照由 Management 文件建立。
F.frozenRows = nil
F.lanes = F.lanes or {
    -- The aura lane intentionally keeps the historical contract task name so
    -- FoundationGate / GetHealth() keep observing the same scheduled task the
    -- Feature has always advertised. P1 (never denied by FrameBudget): tracked
    -- buff latency is the feature's core correctness contract in PvP — as a
    -- P3 lane it was deferred indefinitely during combat frames (real-machine
    -- report 2026-09-01: a self-applied buff took seconds to appear).
    aura      = { active = false, revision = 0, task = "v3_buff_display_refresh",     priority = "P1", cost = 2 },
    position  = { active = false, revision = 0, task = "v3_buff_display_lane_position",  priority = "P1", cost = 1 },
    distance  = { active = false, revision = 0, task = "v3_buff_display_lane_distance",  priority = "P2", cost = 1 },
    metadata  = { active = false, revision = 0, task = "v3_buff_display_lane_metadata",  priority = "P3", cost = 1 },
    equipment = { active = false, revision = 0, task = "v3_buff_display_lane_equipment", priority = "P1", cost = 2 },
    cast      = { active = false, revision = 0, task = "v3_buff_display_lane_cast",      priority = "P2", cost = 1 },
}
-- A file-scoped reload must not leave the aura lane pointing at a stale task
-- name; the contract name is the single source of truth.
F.lanes.aura.task = F.taskName
-- 维护（pvp-hud-1）：运动与换武器是当前两单位的时效性事实，不是全场后台扫描。
-- 只提升这两条有界 lane；职业/装分慢项仍限频，避免把整个模块无差别提升到 P1。
F.lanes.position.priority, F.lanes.equipment.priority = "P1", "P1"
F.PvpPatch = "pvp-hud-1"
F.pendingEdges = {}
F.eventEpoch = (tonumber(F.eventEpoch) or 0) + 1
F.pvpMetrics = { queued=0, merged=0, drained=0, maxQueueAgeMs=0, positionTicks=0,
    equipmentTicks=0, targetInvalidations=0, lastEquipmentAt=0, lastAuraAt=0 }

-- Bounded equipment-lane diagnostics (RU acceptance workflow §BuffGear).
-- Never persisted, never printed per frame; exposed through GetHealth().
F.EquipmentDiagnostics = F.EquipmentDiagnostics or {
    laneTicks = 0, reads = 0, readErrors = 0, emptySlots = 0, validIcons = 0,
    nameOnlyTooltips = 0, unresolvedSlots = 0,
    lastError = nil, lastReadSource = nil, iconField = nil, lastIcon = nil,
    sampleItemKeys = nil, lastTickAt = 0,
    -- 中文维护注释（装备分数 API 诊断，2026-09-11）：
    -- 问题原因：RU 更新后 UnitGearScore(unit, comma) 的 comma 语义开始影响返回格式；旧代码
    -- 对 target 传 true 并直接 tonumber，"12,345" 会变 nil。同时 target-kind gate 可能在 API
    -- 更新后阻断一个本来可读的 UnitGearScore("target")。
    -- Authority/数据流：这里仅保存 equipment lane 最近一次 API 读事实和有界计数，不持久化、
    -- 不写聊天、不参与 HUD Authority。装分仍在 EquipmentTick 内按1秒限频；换武器快项走P1。
    -- 兼容边界：只记录最后 raw type/短 raw 文本/最终数值与错误；不会缓存目标对象或扩大轮询。
    gearScoreReads = 0, gearScoreErrors = 0, gearScoreUnavailable = 0, gearScoreFormatted = 0,
    gearScoreLastScope = nil, gearScoreLastRawType = nil, gearScoreLastRaw = nil,
    gearScoreLastValue = nil, gearScoreLastError = nil, gearScoreLastAt = 0,
}

local function Aura() return S.Services and S.Services.AuraObservationV3 or nil end
local function Casting() return S.Services and S.Services.CastingObservationV3 or nil end
local function Settings() return F.State and F.State.settings or {} end
local function Classification() return S.Services and S.Services.StatusClassificationV3 or nil end
local function Projection() return S.Services and S.Services.ScreenProjectionV3 or nil end
local function Api() return S.Api or nil end
local function Publish(event, arg)
    if S.Events ~= nil and type(S.Events.Publish) == "function" then S.Events:Publish(event, arg) end
end

-- Client globals are resolved through _G on purpose. The bundled RU API surface
-- is not guaranteed to expose these names at load time, and capturing a nil
-- X2*/constant at file scope would permanently disable the call path. Capability
-- hosts are resolved per call by S.Api:ResolveCapabilityHost().
local function Global(name)
    local value = rawget(_G, name)
    if value == nil then return nil end
    return value
end
-- Detached settings snapshot cache. Presentation reads settings through
-- GetSettingsProjection() dozens of times per refresh; without a store-revision
-- gate every read would deep-copy the whole settings table.
local function CopySettings()
    if S.Utils ~= nil and type(S.Utils.DeepCopy) == "function" then return S.Utils.DeepCopy(F.State.settings) end
    local out = {}
    for key, value in pairs(F.State.settings) do out[key] = value end
    return out
end
local settingsCache, settingsCacheRevision = nil, -1
local scopeSettingsCache, scopeSettingsCacheRevision = {}, -1
local function SettingsRevision() return tonumber(F.settingsRevision) or 0 end
function F:InvalidateSettingsCache()
    self.settingsRevision = SettingsRevision() + 1
    settingsCache, settingsCacheRevision = nil, -1
    scopeSettingsCache, scopeSettingsCacheRevision = {}, -1
    return true
end

local HUD_SCOPES = { "player", "target" } -- 帧位置路径复用，不逐帧创建单位列表
local COMPONENT_KEYS = { "buffs", "debuffs", "distance", "class", "gearScore", "mainHand", "offHand", "ranged", "wings", "castBar", "cooldowns" }

local function SplitLines(text)
    local lines = {}
    text = tostring(text or "")
    local start = 1
    while true do
        local _, stop = string.find(text, "\r?\n", start)
        if stop == nil then
            lines[#lines + 1] = string.sub(text, start)
            break
        end
        lines[#lines + 1] = string.sub(text, start, stop - 1)
        start = stop + 1
    end
    return lines
end

-- 中文维护注释（双 HUD scope 读取，2026-09-11）：
-- 问题原因：旧 ComponentEnabled 永远读取 player 的 settings.components，targetLayout 即使
-- 独立保存也无法驱动 lane，导致“目标 HUD 开启组件但后台不采集”。Authority 仍是 Store；
-- Feature 只取得 detached profile。数据流为 Store profile -> scope lane gate -> projection -> Presentation。
-- 兼容边界：无 scope 调用表示“任一 HUD 需要该能力”，用于共享 Scheduler lane；带 scope
-- 调用只控制该单位的数据读取。这样不会为了目标显示强迫无关 player UI 开启，也不增加 Tick。
local function RawScopeLayout(scope)
    if type(F.GetScopeLayoutSettings) == "function" then
        local profile = F:GetScopeLayoutSettings(scope)
        if type(profile) == "table" then return profile end
    end
    local settings = Settings()
    return { plateScale=settings.plateScale, plate=settings.plate, info=settings.info, components=settings.components }
end

local function EnsureScopeSettingsCache()
    local revision = SettingsRevision()
    if scopeSettingsCacheRevision == revision then return end
    local settings = Settings()
    scopeSettingsCache = {}
    for _, name in ipairs({ "player", "target" }) do
        local profile = RawScopeLayout(name)
        scopeSettingsCache[name] = {
            headEnabled = settings.headEnabled ~= false, headShowAll = settings.headShowAll == true,
            headPlayer = settings.headPlayer ~= false, headTarget = settings.headTarget ~= false,
            headShowStacks = settings.headShowStacks ~= false, headShowTime = settings.headShowTime ~= false,
            plateScale = profile.plateScale,
            plate = S.Utils.DeepCopy(profile.plate or {}),
            info = S.Utils.DeepCopy(profile.info or {}),
            components = S.Utils.DeepCopy(profile.components or {}),
        }
    end
    scopeSettingsCacheRevision = revision
end

local function ScopeLayout(scope)
    -- 中文维护注释（lane 热路径缓存）：distance/position 可每 50ms 调用 ComponentEnabled。
    -- 不能在这里每次 Normalize + DeepCopy Store profile；按 settingsRevision 构建一次小型
    -- scope cache，内部 lane 只读该 cache，公共 Presentation 接口再返回 detached copy。
    scope = tostring(scope or "player") == "target" and "target" or "player"
    EnsureScopeSettingsCache()
    return scopeSettingsCache[scope] or RawScopeLayout(scope)
end

local function ComponentEnabled(key, scope)
    if scope ~= nil then
        local layout = ScopeLayout(scope)
        local component = type(layout.components) == "table" and layout.components[key] or nil
        if component == nil or component.enabled == false then return false end
        -- 中文维护注释（Info 生命周期门，2026-09-11）：distance/class/gearScore 都只会
        -- 被绘制到 info 行。旧逻辑即使 info.enabled=false 仍会让 50ms distance、1s
        -- metadata/equipment lane 继续采集，造成“UI 已关闭但后台仍轮询”。Authority 仍由
        -- 当前 scope 的 HUD profile 决定；这里只做运行时需求投影，不改 Store。兼容边界：
        -- Buff/Debuff/装备/施法条不受此门影响，重新开启 info 后 lane 会由 Reconcile 恢复。
        if key == "distance" or key == "class" or key == "gearScore" then
            local info = type(layout.info) == "table" and layout.info or {}
            if info.enabled == false then return false end
            if key == "class" then return info.showClass ~= false end
            if key == "gearScore" then return info.showGear ~= false end
            return info.showDistance ~= false
        end
        return true
    end
    return ComponentEnabled(key, "player") or ComponentEnabled(key, "target")
end

local function AnyHeadComponent(scope)
    for _, key in ipairs(COMPONENT_KEYS) do if ComponentEnabled(key, scope) then return true end end
    return false
end

local function HeadScopeActive()
    local settings = Settings()
    -- headEnabled is the master switch the head renderer already honors
    -- (VisualTick/Start/Reconcile); the lane gates must match it so turning the
    -- head display off also stops the position/distance/metadata/equipment/cast
    -- lanes instead of leaving them polling for a hidden renderer.
    return settings.headEnabled ~= false
        and ((settings.headPlayer ~= false and AnyHeadComponent("player"))
            or (settings.headTarget ~= false and AnyHeadComponent("target")))
end

local function LaneInterval(laneKey)
    local settings = Settings()
    -- 中文维护：留存短状态时复用 aura lane 的50ms兜底；停止留存恢复用户间隔，不写配置。
    if laneKey == "aura" then return F.managementFreeze and F.managementFreeze.active and 50 or settings.refreshMs or 120 end
    -- 维护：位置 lane 仅两次原生屏幕点读取，由既有单 OnUpdate 调度器每渲染帧最多执行一次。
    -- 1ms 是请求每帧，不是保证 1000Hz；这里严禁 Buff/装备/职业读取与布局重建。
    if laneKey == "position" then return 1 end
    if laneKey == "distance" or laneKey == "cast" then return settings.headRefreshMs or 50 end
    if laneKey == "metadata" then return 1000 end
    -- 维护：事件合并上限50ms；丢事件时200ms兜底，仅自己最多四个已启用装备槽。
    -- EquipmentTick 的装分读仍单独限为1秒，不能让兜底提频放大所有 Native 调用。
    if laneKey == "equipment" then return 200 end
    return 400
end

-- Schedule a lane task. Intervals below the background floor (50 ms) go to the
-- high-frequency lane, which allows down to 1 ms and is never clamped upward.
-- Reconcile is deliberately idempotent: an unchanged active lane keeps its
-- existing Scheduler task instead of remove/add churn and runImmediately spikes.
local function SetLaneActive(laneKey, needed, callback, runImmediately)
    local lane = F.lanes[laneKey]
    if lane == nil then return false end
    if needed ~= true then
        if lane.active == true then
            if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(lane.task) end
            lane.active = false
            lane.interval = nil
        end
        return true
    end
    if S.Scheduler == nil then return false end
    local interval = math.max(1, math.floor(tonumber(LaneInterval(laneKey)) or 400))
    local taskExists = S.Scheduler.tasks ~= nil and S.Scheduler.tasks[lane.task] ~= nil
    if lane.active == true and lane.interval == interval and taskExists then return true end
    S.Scheduler:RemoveTask(lane.task)
    local ok
    if interval < 50 then
        if type(S.Scheduler.AddHighFrequencyTask) ~= "function" then lane.active = false; lane.interval = nil; return false end
        ok = S.Scheduler:AddHighFrequencyTask(lane.task, interval, callback, runImmediately, F, lane.priority, lane.cost)
    else
        if type(S.Scheduler.AddTask) ~= "function" then lane.active = false; lane.interval = nil; return false end
        ok = S.Scheduler:AddTask(lane.task, interval, callback, runImmediately, F, lane.priority, lane.cost)
    end
    if ok == true and type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(lane.task, F.Id) end
    lane.active = ok == true
    lane.interval = ok == true and interval or nil
    return ok
end

local function BumpLane(laneKey)
    local lane = F.lanes[laneKey]
    if lane ~= nil then lane.revision = (tonumber(lane.revision) or 0) + 1 end
end

------------------------------------------------------------------------
-- Lane tick handlers
------------------------------------------------------------------------

function F:RefreshScope(scope, forceRefresh)
    scope = tostring(scope or "")
    if scope ~= "player" and scope ~= "target" then return false, "invalid buff display scope" end
    -- 中文维护（enemy-loadout-1）：先撤销旧目标类型，再读取当前实时事实。读取失败/目标消失
    -- 不等于继续沿用上一目标；管理留存仍独立，不因 HUD 失败而删除历史。
    if scope == "target" then
        self.laneData.target = self.laneData.target or {}
        self.laneData.target.targetLoadout = {}
    end
    local aura = Aura()
    if type(aura) ~= "table" or type(aura.GetSnapshot) ~= "function" or type(aura.GetStatusMap) ~= "function" then
        self.projections[scope], self.coverage[scope] = {}, { available = false, complete = false, reliable = false, total = 0, error = "AuraObservationV3 unavailable" }
        -- 维护（pvp-hud-1）：不可读不是当前Buff仍生效；只清live HUD，不删除独立的管理留存。
        local live=self.laneData[scope] or {};live.buffRows,live.debuffRows={},{};self.laneData[scope]=live
        return false, "AuraObservationV3 unavailable"
    end
    local settings = Settings()
    -- Snapshot TTL is HALF the lane interval: the previous form (ttl = full
    -- interval) let the observation cache return facts up to one extra interval
    -- old, doubling worst-case buff latency (lane wait + stale cache). With
    -- ttl < interval every lane tick rescans fresh facts; other consumers
    -- calling between ticks still coalesce onto one scan.
    local retaining=self.managementFreeze and self.managementFreeze.active==true
    local snapshotTtlMs = math.max(1, math.floor((tonumber(LaneInterval("aura")) or 120) / 2))
    local snapshot, snapshotErr = aura:GetSnapshot(scope, {
        buff = true, debuff = true, hidden = true, limit = retaining and 128 or 64, ttlMs = snapshotTtlMs, forceRefresh=forceRefresh==true or (scope=="target" and self.targetInvalidated==true),
    })
    if type(snapshot) ~= "table" then
        self.projections[scope], self.coverage[scope] = {}, { available = false, complete = false, reliable = false, total = 0, error = snapshotErr }
        -- 维护：清除Presentation所用的live行，避免服务暂不可用时仍展示上次Buff图标。
        local live=self.laneData[scope] or {};live.buffRows,live.debuffRows={},{};self.laneData[scope]=live
        -- 不可读不是已消失；留存仍保留旧行，只更新覆盖状态。
        if type(self.ObserveManagementRows)=="function" then self:ObserveManagementRows(scope,nil,self.coverage[scope],nil) end
        return false, snapshotErr or "aura snapshot unavailable"
    end
    if scope == "target" then self.targetInvalidated = false end
    self.pvpMetrics.lastAuraAt = S.NowMs and S.NowMs() or 0
    local statusMap, meta = aura:GetStatusMap(snapshot, { buff = true, debuff = true, hidden = true })
    -- 中文维护：类型识别与 Buff 可视白名单/冻结列表分离，不需要用户额外追踪这些被动效果。
    if scope == "target" and type(self.ProjectTargetLoadout) == "function" then
        self.laneData.target.targetLoadout = self.ProjectTargetLoadout(statusMap)
    end
    -- 中文维护注释：管理列表分页数不能截断 HUD 事实；普通模式三类各64，留存模式各128；投影上限随之为192/384个ID。
    -- 最终显示容量仍由各组件 geometry/虚拟列表控制，而不是先丢掉后面的 Debuff。
    -- 管理事实无条件保留；旧 showBuffs/showDebuffs 仅在下面 HUD lane 生效，避免旧存档隐藏管理行。
    local limit = retaining and 384 or 192
    self.trackedIndex = self:BuildTrackedIndex(settings)
    local rows, coverage = self.ProjectStatusMap(statusMap, {
        available = meta and meta.available, complete = meta and meta.complete, reliable = meta and meta.reliable,
        revision = snapshot.revision,
    }, {showBuffs=true,showDebuffs=true,classification=settings.classification,tracked=settings.tracked}, scope, limit, self.trackedIndex)
    -- 中文维护注释：这里只构建实时 Aura/HUD；管理冻结由独立 Session Snapshot 拥有，
    -- 不得再把过期冻结行写入 laneData，否则头顶状态永远不消失。unknown 也不能误入 Buff lane。
    coverage.scannedAt, coverage.buffCount = tonumber(snapshot.at) or 0, snapshot.buff and tonumber(snapshot.buff.count) or 0
    coverage.debuffCount, coverage.hiddenCount = snapshot.debuff and tonumber(snapshot.debuff.count) or 0, snapshot.hidden and tonumber(snapshot.hidden.count) or 0
    self.projections[scope], self.coverage[scope] = rows, coverage
    -- 中文维护：实时已读事实 -> Feature会话留存。副本去重，永不回写HUD，取消追踪不删除记录。
    if retaining and type(self.ObserveManagementRows)=="function" then self:ObserveManagementRows(scope,rows,coverage,snapshot.at) end
    -- cached category rows for the head plates renderer
    local lane = self.laneData[scope] or {}
    lane.buffRows, lane.debuffRows = {}, {}
    for _, row in ipairs(rows) do
        if row.category == "debuff" and settings.showDebuffs ~= false then lane.debuffRows[#lane.debuffRows + 1] = row
        elseif row.category == "buff" and settings.showBuffs ~= false then lane.buffRows[#lane.buffRows + 1] = row end
    end
    self.laneData[scope] = lane
    return true
end

-- 中文维护注释：追踪索引只在 settings revision 改变时重建；Aura 的 50ms 热路径不能遍历整库。
function F:BuildTrackedIndex(settings)
    settings=type(settings)=="table" and settings or Settings()
    local revision=SettingsRevision()
    if settings==Settings() and self.trackedIndexRevision==revision then return self.trackedIndex end
    local index={buff={},debuff={},auto={}}
    for _,category in ipairs({"buff","debuff","auto"}) do
        for _,id in ipairs(type(settings.tracked)=="table" and settings.tracked[category] or {}) do
            id=math.floor(tonumber(id) or 0);if id>0 then index[category][id]=true end
        end
    end
    if settings==Settings() then self.trackedIndex,self.trackedIndexRevision=index,revision end
    return index
end

-- Tracking is a user-setting mutation, not a Native Aura mutation. Re-stamp the
-- already bounded projection rows immediately so the table's 追踪 column and the
-- head whitelist react in the same click without forcing another Aura scan.
function F:SyncTrackedProjectionFlags()
    local index = self.trackedIndex or self:BuildTrackedIndex(Settings())
    for _, scope in ipairs({ "player", "target" }) do
        for _, row in ipairs(self.projections[scope] or {}) do
            local category = row.category == "debuff" and "debuff" or "buff"
            local id = math.floor(tonumber(row.id) or 0)
            local tracked = id > 0 and ((type(index[category]) == "table" and index[category][id] == true)
                or (type(index.auto)=="table" and index.auto[id]==true))
            row.tracked = tracked == true
            row.trackedText = tracked == true and "已追踪" or ""
        end
    end
    self.revision = (tonumber(self.revision) or 0) + 1
    Publish("v3.buff_display.updated", "tracked_projection")
    Publish("v3.buff_display.plates.updated", "tracked_projection")
    return true
end

-- 中文维护注释：留存的唯一实现位于 rs_buff_display_management.lua；仅管理列表读取历史，HUD不读。
-- 不保留旧 ApplyFreezeRows 旁路；TOC 在完整加载 Feature 后注册管理命令。

function F:Refresh(reason, forceRefresh)
    if self.auraHeld ~= true then return false, "buff display aura lease not held" end
    self:RefreshScope("player",forceRefresh)
    self:RefreshScope("target",forceRefresh)
    BumpLane("aura")
    self.revision = self.revision + 1
    Publish("v3.buff_display.updated", tostring(reason or "refresh"))
    Publish("v3.buff_display.plates.updated", tostring(reason or "refresh"))
    return true
end

local function ScopeHeadEnabled(scope)
    local settings = Settings()
    if scope == "player" then return settings.headPlayer ~= false end
    if scope == "target" then return settings.headTarget ~= false end
    return false
end

local function ProjectScope(scope)
    local projection = Projection()
    if type(projection) ~= "table" or type(projection.ProjectUnit) ~= "function" then
        local lane = F.laneData[scope] or {}
        lane.x, lane.y, lane.depth, lane.source = nil, nil, nil, nil
        lane.projectErr = "projection_service_unavailable"
        F.laneData[scope] = lane
        return false
    end
    -- 维护：原生血条与附着图标必须共用 native_unit 锚点；缺失时隐藏，不在不同帧
    -- 切换到 world+1 米的另一投影（也不覆写 behind_camera 否决），避免跳位和背面残影。
    local x, y, depth, err = projection:ProjectUnit(scope)
    local source = x ~= nil and "native_unit" or nil
    local lane = F.laneData[scope] or {}
    local changed = lane.x ~= x or lane.y ~= y or lane.depth ~= depth
    if x ~= nil and y ~= nil and depth ~= nil then
        lane.x, lane.y, lane.depth, lane.source = x, y, depth, source
        lane.projectErr = nil
    else
        lane.x, lane.y, lane.depth, lane.source = nil, nil, nil, nil
        lane.projectErr = err or "projection_failed"
    end
    F.laneData[scope] = lane
    return changed
end

function F:PositionTick()
    if (tonumber(self.consumerCount) or 0) <= 0 then return true end
    for _, scope in ipairs(HUD_SCOPES) do
        if ScopeHeadEnabled(scope) and AnyHeadComponent(scope) then ProjectScope(scope) end
    end
    -- 维护：raw屏幕视口由同一Service提供，不再用插件logical尺寸裁剪raw投影。
    -- 有限缓存仅减少视口getter；分辨率变更最多等待250ms，位置本身从不缓存/插值。
    local now = S.NowMs and S.NowMs() or 0
    if self.viewportAt == nil or now - self.viewportAt >= 250 then
        local service = Projection()
        if service and type(service.GetUiParentViewport) == "function" then
            self.viewportWidth, self.viewportHeight = service:GetUiParentViewport()
        end
        self.viewportAt = now
    end
    self.pvpMetrics.positionTicks = self.pvpMetrics.positionTicks + 1
    BumpLane("position")
    -- 维护：位置事件只移动父容器；静止帧也允许消费待提交的内容dirty，不再重复ProjectPlates。
    Publish("v3.buff_display.plates.motion", "position")
    return true
end

function F:GetHeadViewport() return self.viewportWidth, self.viewportHeight end

local function NormalizeDistance(value)
    if type(value) == "table" then value = value.distance end
    local n = tonumber(value)
    return n ~= nil and n >= 0 and n or nil
end

function F:DistanceTick()
    if (tonumber(self.consumerCount) or 0) <= 0 then return true end
    local api = Api()
    local changed = false
    -- Distance is meaningful for the target; player self-distance is 0 by definition.
    if ScopeHeadEnabled("target") then
        local lane = self.laneData.target or {}
        local value = nil
        if api ~= nil and type(api.CallCapability) == "function" and X2Unit ~= nil then
            local ok, raw = api:CallCapability("X2Unit:UnitDistance", X2Unit, "UnitDistance", "target")
            value = ok and NormalizeDistance(raw) or nil
        elseif type(Global("UnitDistance")) == "function" then
            local unitDistance = Global("UnitDistance")
            local ok, raw = pcall(unitDistance, "target")
            value = ok and NormalizeDistance(raw) or nil
        end
        if lane.distance ~= value then lane.distance, changed = value, true end
        self.laneData.target = lane
    end
    BumpLane("distance")
    if changed == true then Publish("v3.buff_display.plates.updated", "distance") end
    return true
end

-- UNIT-SCOPE gate for CLASS metadata only: ability templates must never be
-- trusted for a non-player target, so class still fails closed unless target
-- resolves to PLAYER. Gear score no longer uses this gate: UnitGearScore is a
-- unit-token keyed API and is read directly for target after the 2026-09-11 RU
-- update. Equipped icons remain player-scope only (see EquipmentTick).
-- The resolved kind is cached briefly; UnitIdentityV3:GetById additionally keeps
-- its own 60s kind TTL and a 1.5s miss TTL, so this helper adds no hot-path cost.
local targetKindCache = { kind = nil, at = 0 }
local TARGET_KIND_TTL_MS = 1200
local function ResolveTargetKind()
    local now = math.max(0, tonumber(S.NowMs and S.NowMs()) or 0)
    if targetKindCache.kind ~= nil and now - targetKindCache.at <= TARGET_KIND_TTL_MS then return targetKindCache.kind end
    local kind = nil
    local identity = S.Services and S.Services.UnitIdentityV3 or nil
    local api = Api()
    if type(identity) == "table" and type(identity.GetById) == "function"
        and api ~= nil and type(api.CallCapability) == "function" and X2Unit ~= nil then
        local ok, targetId = api:CallCapability("X2Unit:GetTargetUnitId", X2Unit, "GetTargetUnitId")
        if ok ~= true or targetId == nil then
            ok, targetId = api:CallCapability("X2Unit:GetUnitId", X2Unit, "GetUnitId", "target")
        end
        local idText = tostring(targetId or "")
        if idText ~= "" and idText ~= "0" and idText ~= "nil" then
            local info = identity:GetById(idText, { includeKind = true })
            if type(info) == "table" and info.kind ~= nil then kind = info.kind end
        end
    end
    targetKindCache.kind, targetKindCache.at = kind, now
    return kind
end
local function TargetIsPlayer()
    return ResolveTargetKind() == "PLAYER"
end

-- 中文维护注释（UnitGearScore 规范化边界，2026-09-11）：
-- X2Unit 是装分 Authority；格式解析统一收敛到 S.Utils.ParseGearScore，避免状态显示与
-- 团队战备检查各自维护一套地区数字规则。Feature 只负责调用 API 与记录最近诊断。
local function ReadGearScore(scope, api)
    local dia = F.EquipmentDiagnostics
    if dia ~= nil then
        dia.gearScoreReads = (tonumber(dia.gearScoreReads) or 0) + 1
        dia.gearScoreLastScope = tostring(scope or "")
        dia.gearScoreLastAt = math.max(0, tonumber(S.NowMs and S.NowMs()) or 0)
        dia.gearScoreLastError = nil
    end
    if api == nil or type(api.CallCapability) ~= "function" or X2Unit == nil then
        if dia ~= nil then
            dia.gearScoreErrors = (tonumber(dia.gearScoreErrors) or 0) + 1
            dia.gearScoreLastError = "api_unavailable"
            dia.gearScoreLastRawType, dia.gearScoreLastRaw, dia.gearScoreLastValue = nil, nil, nil
        end
        return nil
    end
    -- comma=false is the documented API contract. Target selection is expressed
    -- by the unit token ("target"), never by the second argument.
    local ok, raw, err = api:CallCapability("X2Unit:UnitGearScore", X2Unit, "UnitGearScore", scope, false)
    local value, formatted = nil, false
    if ok == true and S.Utils ~= nil and type(S.Utils.ParseGearScore) == "function" then
        value, formatted = S.Utils.ParseGearScore(raw)
    end
    if dia ~= nil then
        dia.gearScoreLastRawType = type(raw)
        local rawText = raw == nil and "nil" or tostring(raw)
        if #rawText > 48 then rawText = string.sub(rawText, 1, 48) .. "…" end
        dia.gearScoreLastRaw = rawText
        dia.gearScoreLastValue = value
        if formatted == true then dia.gearScoreFormatted = (tonumber(dia.gearScoreFormatted) or 0) + 1 end
        if ok ~= true then
            dia.gearScoreErrors = (tonumber(dia.gearScoreErrors) or 0) + 1
            dia.gearScoreLastError = tostring(err or "read_failed")
        elseif value == nil then
            -- nil/0 is expected for NPCs and some non-inspectable units; keep it
            -- observable without counting it as an API fault every P3 lane tick.
            dia.gearScoreUnavailable = (tonumber(dia.gearScoreUnavailable) or 0) + 1
            dia.gearScoreLastError = "unavailable"
        end
    end
    return value
end

local function ReadClass(scope)
    local api = Api()
    if api == nil or type(api.CallCapability) ~= "function" then return nil end
    local ok, templates = api:CallCapability("X2Unit:GetTargetAbilityTemplates", X2Unit, "GetTargetAbilityTemplates", scope)
    if ok ~= true or type(templates) ~= "table" or templates[1] == nil or templates[2] == nil or templates[3] == nil then return nil end
    local indices = { tonumber(templates[1].index), tonumber(templates[2].index), tonumber(templates[3].index) }
    if indices[1] == nil or indices[2] == nil or indices[3] == nil then return nil end
    table.sort(indices)
    local key = string.format("name_%d_%d_%d", indices[1], indices[2], indices[3])
    if key == "name_30_30_30" then return nil end
    local x2Locale, combinedText = Global("X2Locale"), Global("COMBINED_ABILITY_NAME_TEXT")
    if x2Locale == nil or type(x2Locale.LocalizeUiText) ~= "function" or combinedText == nil then return nil end
    local localizedOk, localized = api:CallCapability("X2Locale:LocalizeUiText", x2Locale, "LocalizeUiText", combinedText, key, "")
    if localizedOk ~= true or localized == nil or tostring(localized) == "" then return nil end
    -- 中文维护（enemy-loadout-1）：沿用中央精确三天赋分类，不以装备/名称猜职业；
    -- 图标是类别提示而非新的团队职责判定，未知组合保留真职业名且不冒用别人的图标。
    local catalog = S.Data and S.Data.TeamAutoRoleCatalog
    local row = catalog and catalog.byClassKey and catalog.byClassKey[key]
    local icon = row and catalog.iconByClassType and catalog.iconByClassType[row.classType]
    return { name = tostring(localized), key = key, icon = icon }
end

function F:MetadataTick()
    if (tonumber(self.consumerCount) or 0) <= 0 then return true end
    local changed = false
    for _, scope in ipairs({ "player", "target" }) do
        if ScopeHeadEnabled(scope) and ComponentEnabled("class", scope) then
            local lane = self.laneData[scope] or {}
            -- UNIT-SCOPE gate: ability templates are player metadata. NPC/UNKNOWN
            -- targets fail closed so the player's own class can never leak onto
            -- a foreign unit's head plate.
            local value = nil
            if scope == "player" or TargetIsPlayer() then value = ReadClass(scope) end
            -- Normalize legacy string lane values to { name } records.
            local normalized = value
            if type(value) == "string" then normalized = { name = value, key = nil } end
            local same = (lane.class == nil and normalized == nil)
                or (type(lane.class) == "table" and type(normalized) == "table"
                    and tostring(lane.class.name) == tostring(normalized.name)
                    and lane.class.key == normalized.key and lane.class.icon == normalized.icon)
            if same ~= true then lane.class, changed = normalized, true end
            self.laneData[scope] = lane
        end
    end
    BumpLane("metadata")
    if changed == true then Publish("v3.buff_display.plates.updated", "metadata") end
    return true
end

-- Equip-slot constants are not guaranteed client globals at load time; resolve
-- them through the safe global reader so a missing constant degrades to the
-- documented slot fallback instead of faulting the lane.
local EQUIPMENT_SLOTS = {
    mainHand = function() local v = Global("ES_MAINHAND"); return type(v) == "number" and v or 16 end,
    offHand = function() local v = Global("ES_OFFHAND"); return type(v) == "number" and v or 17 end,
    ranged = function() local v = Global("ES_RANGED"); return type(v) == "number" and v or 18 end,
    wings = function() local v = Global("ES_BACKPACK"); return type(v) == "number" and v or nil end,
}

-- slotId: numeric equip slot; scope: "player" (own gear) or "target".
-- Real-machine evidence 2026-09-01: the client ignores the second argument
-- (targetEquippedItem) and always returns the player's own equipped item, so
-- only the player scope may call this; the target scope fails closed upstream.
-- Every outcome is recorded into F.EquipmentDiagnostics (bounded, never
-- printed per frame): reads / readErrors / emptySlots / validIcons /
-- iconField / lastError / sampleItemKeys. The 2026-09-01 fix routed the read
-- through GearV3 yet real-machine icons stayed blank -- the remaining unknowns
-- (which icon field the RU tooltip actually carries, whether the lane ticks,
-- whether reads error) must be observable on the client instead of guessed.
local function ReadEquippedIcon(slotId, scope)
    if slotId == nil or scope ~= "player" then
        if slotId == nil then
            local dia = F.EquipmentDiagnostics
            if dia ~= nil then dia.unresolvedSlots = (tonumber(dia.unresolvedSlots) or 0) + 1 end
        end
        return nil
    end

    local dia = F.EquipmentDiagnostics
    local item, readErr = nil, nil
    local gear = S.Services and S.Services.GearV3 or nil
    local readSource = "direct"
    if type(gear) == "table" and type(gear.GetEquipped) == "function" then
        item, readErr = gear:GetEquipped(slotId)
        readSource = "gear_v3"
    else
        -- Fail-soft bootstrap fallback only. Services load before Features in
        -- toc.g, so normal runtime always takes GearV3 above.
        local api = Api()
        local equipment = Global("X2Equipment")
        if api ~= nil and type(api.CallCapability) == "function" and equipment ~= nil then
            local ok, value, err = api:CallCapability("X2Equipment:GetEquippedItemTooltipInfo", equipment, "GetEquippedItemTooltipInfo", slotId, true)
            if ok == true then item = value else readErr = err end
        else
            readErr = "api_unavailable"
        end
    end
    if dia ~= nil then
        dia.reads = (tonumber(dia.reads) or 0) + 1
        dia.lastReadSource = readSource
        if readErr ~= nil then
            dia.readErrors = (tonumber(dia.readErrors) or 0) + 1
            dia.lastError = tostring(readErr)
        elseif type(item) ~= "table" then
            dia.emptySlots = (tonumber(dia.emptySlots) or 0) + 1
        end
    end
    if readErr ~= nil or type(item) ~= "table" then return nil end
    local icon = tostring(item.icon or item.iconPath or item.path or "")
    local rawGradeIcon = item.gradeIcon or item.grade_icon
    local gradeIconPath = type(rawGradeIcon) == "string" and rawGradeIcon or ""
    local name = tostring(item.name or item.itemName or "")
    if dia ~= nil then
        if icon ~= "" then
            dia.validIcons = (tonumber(dia.validIcons) or 0) + 1
            dia.iconField = item.icon ~= nil and "icon" or (item.iconPath ~= nil and "iconPath" or "path")
            dia.lastIcon = icon ~= "" and tostring(icon) or dia.lastIcon
        elseif name ~= "" then
            -- Tooltip without any known icon field: capture the shape ONCE so
            -- the client run reveals the actual field names instead of another
            -- blind fix round.
            dia.nameOnlyTooltips = (tonumber(dia.nameOnlyTooltips) or 0) + 1
            if dia.sampleItemKeys == nil then
                local keys = {}
                for key in pairs(item) do keys[#keys + 1] = tostring(key) end
                table.sort(keys)
                dia.sampleItemKeys = table.concat(keys, ",")
            end
        end
    end
    if icon == "" and name == "" then return nil end
    return { icon = icon, gradeIconPath = gradeIconPath, name = name }
end

local function SameEquipmentItem(left, right)
    if left == nil or right == nil then return left == right end
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    return tostring(left.icon or "") == tostring(right.icon or "")
        and tostring(left.gradeIconPath or "") == tostring(right.gradeIconPath or "")
        and tostring(left.name or "") == tostring(right.name or "")
end

function F:EquipmentTick(onlyFast)
    if (tonumber(self.consumerCount) or 0) <= 0 then return true end
    -- 维护：自己装备与装分分频，不改GetEquipped Authority；显式完整刷新仍可立即读装分。
    -- 无效装备读取仍清旧图，不把旧武器当作当前真相。周期/合并事件只执行有界快项。
    local now = S.NowMs and S.NowMs() or 0
    local scoresDue = onlyFast ~= true or self.lastGearScoreAt == nil or now - self.lastGearScoreAt >= 1000
    if scoresDue then self.lastGearScoreAt = now end
    self.pvpMetrics.equipmentTicks = self.pvpMetrics.equipmentTicks + 1
    self.pvpMetrics.lastEquipmentAt = now
    local dia = F.EquipmentDiagnostics
    if dia ~= nil then
        dia.laneTicks = (tonumber(dia.laneTicks) or 0) + 1
        dia.lastTickAt = S.NowMs and S.NowMs() or 0
    end
    local changed = false
    local api = Api()
    for _, scope in ipairs({ "player", "target" }) do
        if ScopeHeadEnabled(scope) then
            local lane = self.laneData[scope] or {}
            -- EQUIP-SCOPE fail-closed (real-machine evidence 2026-09-01): the
            -- current RU client ignores GetEquippedItemTooltipInfo's
            -- targetEquippedItem flag and always returns the player's OWN gear,
            -- so a target-scope read used to paint the player's weapons onto
            -- the target's plate. The unit-keyed alternates
            -- (GetEquippedItemInfo/GetEquippedItemTooltipText) are not-allowed,
            -- so equipped icons are only ever read for the player scope. Any
            -- cached target values are purged so a stale plate can never
            -- survive a target switch.
            if scope ~= "player" then
                for _, key in ipairs({ "mainHand", "offHand", "ranged", "wings" }) do
                    if lane[key] ~= nil then lane[key], changed = nil, true end
                end
            end
            -- 中文维护注释（目标装分 API 更新修复，2026-09-11）：
            -- 旧逻辑同时犯了两个错误：把 UnitGearScore 的 comma 参数当 target 布尔传 true，
            -- 并用 TargetIsPlayer() 作为调用前置门。前者可能得到 "12,345" 后 tonumber 失败，
            -- 后者在本周 target-kind API 变化时会让一个仍可用的 unit-keyed 读完全不执行。
            -- Authority/数据流：gearScore 直接读取 scope token（player/target）的 X2Unit Authority；
            -- class 仍保留 TargetIsPlayer gate，装备图标仍只读 player，三类能力不互相放宽。
            -- 兼容边界：nil/0/异常值 fail-closed 并清掉旧 lane 值，绝不把自己装分复制到目标。
            if ComponentEnabled("gearScore", scope) and scoresDue then
                local score = ReadGearScore(scope, api)
                if lane.gearScore ~= score then lane.gearScore, changed = score, true end
            elseif not ComponentEnabled("gearScore", scope) and lane.gearScore ~= nil then
                lane.gearScore, changed = nil, true
            end
            -- weapon / glider icons (player scope only). Grade overlay is part
            -- of the same tooltip fact and therefore adds no Native read;
            -- compare it as well so a quality change cannot be hidden behind an
            -- unchanged base icon.
            if scope == "player" then
                for _, key in ipairs({ "mainHand", "offHand", "ranged", "wings" }) do
                    if ComponentEnabled(key, scope) then
                        local slotId = EQUIPMENT_SLOTS[key]()
                        local item = ReadEquippedIcon(slotId, scope)
                        if not SameEquipmentItem(lane[key], item) then lane[key], changed = item, true end
                    end
                end
            end
            self.laneData[scope] = lane
        end
    end
    BumpLane("equipment")
    if changed == true then Publish("v3.buff_display.plates.updated", "equipment") end
    return true
end

function F:CastTick()
    if (tonumber(self.consumerCount) or 0) <= 0 then return true end
    local casting = Casting()
    local changed = false
    for _, scope in ipairs({ "player", "target" }) do
        if ScopeHeadEnabled(scope) and ComponentEnabled("castBar", scope) then
            local lane = self.laneData[scope] or {}
            local cast = type(casting) == "table" and type(casting.Get) == "function" and casting:Get(scope) or nil
            local old = lane.cast
            local same = (old == nil and cast == nil) or (type(old) == "table" and type(cast) == "table"
                and old.spellName == cast.spellName and old.totalMs == cast.totalMs
                and math.abs((old.currMs or 0) - (cast.currMs or 0)) < 50)
            if same ~= true then lane.cast, changed = cast, true end
            self.laneData[scope] = lane
        end
    end
    BumpLane("cast")
    if changed == true then Publish("v3.buff_display.plates.updated", "cast") end
    return true
end

------------------------------------------------------------------------
-- Lane reconciliation (component gating + demand)
------------------------------------------------------------------------

local function LaneNeeds(laneKey, settings)
    local positionActive = HeadScopeActive()
    if laneKey == "aura" then
        -- 管理留存与HUD开关独立，否则隐藏Buff组件会让短状态无机会进入留存列表。
        if F.managementFreeze and F.managementFreeze.active then return true end
        -- 中文维护：目标类型组件消费同一个 Aura 租约；隐藏 Buff 行不能意外停掉类型识别。
        if positionActive and ScopeHeadEnabled("target")
            and (ComponentEnabled("mainHand", "target") or ComponentEnabled("offHand", "target")) then return true end
        return (settings.showBuffs ~= false or settings.showDebuffs ~= false)
            and (ComponentEnabled("buffs") or ComponentEnabled("debuffs") or (tonumber(F.consumerCount) or 0) > 0)
    end
    if laneKey == "position" then return positionActive end
    if laneKey == "distance" then return positionActive and ComponentEnabled("distance") end
    if laneKey == "metadata" then return positionActive and ComponentEnabled("class") end
    if laneKey == "equipment" then
        return positionActive and (ComponentEnabled("gearScore") or ComponentEnabled("mainHand")
            or ComponentEnabled("offHand") or ComponentEnabled("ranged") or ComponentEnabled("wings"))
    end
    if laneKey == "cast" then return positionActive and ComponentEnabled("castBar") end
    return false
end

function F:ReconcileLanes()
    if self.enabled ~= true or (tonumber(self.consumerCount) or 0) <= 0 then
        for laneKey in pairs(self.lanes) do SetLaneActive(laneKey, false, nil) end
        local releaseOk, releaseErr = self:_ReleaseCasting()
        self.laneData = { player = {}, target = {} }
        return releaseOk, releaseErr
    end
    local settings = Settings()
    local castNeeded = LaneNeeds("cast", settings)
    if castNeeded then
        local castOk, castErr = self:_AcquireCasting()
        if castOk ~= true then return false, castErr end
    else
        local castOk, castErr = self:_ReleaseCasting()
        if castOk ~= true then return false, castErr end
    end
    SetLaneActive("aura", LaneNeeds("aura", settings), function() return F:Refresh("aura_lane") end, true)
    SetLaneActive("position", LaneNeeds("position", settings), function() return F:PositionTick() end, true)
    SetLaneActive("distance", LaneNeeds("distance", settings), function() return F:DistanceTick() end, true)
    SetLaneActive("metadata", LaneNeeds("metadata", settings), function() return F:MetadataTick() end, true)
    SetLaneActive("equipment", LaneNeeds("equipment", settings), function() return F:EquipmentTick(true) end, true)
    SetLaneActive("cast", castNeeded, function() return F:CastTick() end, true)
    return true
end

------------------------------------------------------------------------
-- Projection accessors
------------------------------------------------------------------------

function F:GetProjection(scope, limit)
    scope = tostring(scope or "player")
    if scope == "all" then
        local rows = {}
        for _, name in ipairs({ "player", "target" }) do
            for _, row in ipairs(self.projections[name] or {}) do
                local copy = {}
                for key, value in pairs(row) do copy[key] = value end
                copy.scope, copy.scopeText = name, name == "player" and "自己" or "目标"
                rows[#rows + 1] = copy
            end
        end
        limit = math.max(1, math.floor(tonumber(limit) or #rows))
        while #rows > limit do rows[#rows] = nil end
        return rows, self.revision, { player = self.coverage.player, target = self.coverage.target }
    end
    return self.projections[scope] or {}, self.revision, self.coverage[scope] or { available = false, complete = false, reliable = false }
end

function F:GetSettingsProjection()
    local current = SettingsRevision()
    if settingsCache ~= nil and settingsCacheRevision == current then return S.Utils.DeepCopy(settingsCache) end
    local snapshot = CopySettings()
    settingsCache, settingsCacheRevision = snapshot, current
    return S.Utils.DeepCopy(snapshot)
end

function F:GetHeadPolicyProjection()
    local settings = Settings()
    return {
        headEnabled = settings.headEnabled ~= false,
        headShowAll = settings.headShowAll == true,
        headPlayer = settings.headPlayer ~= false,
        headTarget = settings.headTarget ~= false,
        headShowStacks = settings.headShowStacks ~= false,
        headShowTime = settings.headShowTime ~= false,
    }
end

function F:GetScopeSettingsProjection(scope)
    scope = tostring(scope or "player") == "target" and "target" or "player"
    -- 中文维护注释（PVP 50ms 热路径）：cache 只含 6 个运行策略 + 当前视觉 profile，
    -- 不复制 tracked/classification 大表。内部 lane 读同一 generation 的只读 cache；
    -- Presentation 边界仍 DeepCopy，避免 UI 反向修改 Feature/Store Authority。
    EnsureScopeSettingsCache()
    return S.Utils.DeepCopy(scopeSettingsCache[scope] or {})
end

-- Head plates projection for the renderer: enabled components + bounded rows.
function F:GetPlatesProjection(scope)
    scope = tostring(scope or "player")
    local laneData = self.laneData[scope] or {}
    local plates = self.ProjectPlates(laneData, self:GetScopeSettingsProjection(scope), self.trackedIndex)
    local maxRevision = 0
    for _, lane in pairs(self.lanes) do maxRevision = math.max(maxRevision, tonumber(lane.revision) or 0) end
    return plates, maxRevision
end

-- 维护（pvp-hud-1）：原生UIParent屏幕坐标，不除以UI缩放；第五返回为只读失败原因，前四参保持兼容。
function F:GetPlatesAnchor(scope)
    scope = tostring(scope or "player")
    local lane = self.laneData[scope] or {}
    return lane.x, lane.y, lane.depth, lane.source, lane.projectErr
end

-- Legacy accessor kept for old consumers: tracked BUFF rows only.
function F:GetTrackedHeadProjection(scope)
    scope = tostring(scope or "player")
    if scope ~= "player" and scope ~= "target" then return {} end
    local settings = self:GetScopeSettingsProjection(scope)
    local buffs = type(settings.components) == "table" and settings.components.buffs or nil
    buffs = type(buffs) == "table" and buffs or {}
    local perRow = math.max(1, math.min(16, math.floor(tonumber(buffs.maxPerRow) or 8)))
    local maxRows = math.max(1, math.min(4, math.floor(tonumber(buffs.maxRows) or 2)))
    local maxIcons = math.min(64, perRow * maxRows)
    local out = {}
    for _, row in ipairs(self.projections[scope] or {}) do
        if row.tracked == true and row.category ~= "debuff" then
            local copy = {}
            for key, value in pairs(row) do copy[key] = value end
            out[#out + 1] = copy
            if #out >= maxIcons then break end
        end
    end
    return out, self.revision, S.Utils.DeepCopy(self.coverage[scope] or {})
end

-- Full tracked list for the floating widget's tracking manager. Every tracked
-- id (buff + debuff) becomes one row; live projection rows contribute their
-- name/icon/scope, while tracked ids that have vanished (and are not frozen)
-- stay as "已消失" placeholders so the player can still untrack them.
function F:GetTrackedList()
    -- 中文维护注释：包括非实时条目的管理投影由统一目录负责；这里不再每次热刷重建全部 ID。
    if type(self.GetManagementProjection)=="function" then return self:GetManagementProjection({view="tracked",cacheOwner="widget"}) end
    return {}, self.revision
end

------------------------------------------------------------------------
-- Aura consumer lease (unchanged contract)
------------------------------------------------------------------------

function F:_AcquireAura()
    if self.auraHeld == true then return true end
    local aura = Aura()
    if type(aura) ~= "table" or type(aura.AcquireConsumer) ~= "function" then return false, "共享 Aura 服务不可用" end
    local ok, err = aura:AcquireConsumer("buff_display:aura", { purpose = "buff_display" })
    if ok ~= true then return false, err end
    self.auraHeld = true
    return true
end

function F:_ReleaseAura()
    if self.auraHeld ~= true then return true end
    local aura = Aura()
    if type(aura) ~= "table" or type(aura.ReleaseConsumer) ~= "function" then return false, "共享 Aura 服务释放不可用" end
    local ok, err = aura:ReleaseConsumer("buff_display:aura")
    if ok ~= true then return false, err end
    self.auraHeld = false
    return true
end

function F:_AcquireCasting()
    if self.castingHeld == true then return true end
    local casting = Casting()
    if type(casting) ~= "table" or type(casting.AcquireConsumer) ~= "function" then return false, "共享 Casting 服务不可用" end
    local ok, err = casting:AcquireConsumer("buff_display:casting", { player = true, target = true, intervalMs = LaneInterval("cast"), purpose = "buff_display" })
    if ok ~= true then return false, err end
    self.castingHeld = true
    return true
end

function F:_ReleaseCasting()
    if self.castingHeld ~= true then return true end
    local casting = Casting()
    if type(casting) ~= "table" or type(casting.ReleaseConsumer) ~= "function" then return false, "共享 Casting 服务释放不可用" end
    local ok, err = casting:ReleaseConsumer("buff_display:casting")
    if ok ~= true then return false, err end
    self.castingHeld = false
    return true
end

-- Contract-compatible aura task wrappers (the aura lane is the periodic task).
function F:_StartTask()
    return SetLaneActive("aura", true, function() return F:Refresh("scheduled") end, true)
end
function F:_StopTask()
    return SetLaneActive("aura", false, nil)
end

function F:_QueueEventRefresh(reason, delayMs)
    if self.enabled ~= true or (tonumber(self.consumerCount) or 0) <= 0 then return true end
    if S.Scheduler == nil then return false, "状态显示事件调度器不可用" end
    -- 维护（pvp-hud-1）：旧单reason任务每个事件先删后建，BUFF洪流可永久推迟武器事件，
    -- 并用最后一个reason覆盖其它类型。现在保存三个位的并集与最早期限；后来事件只能合并
    -- 或提前目标切换，绝不向后延时。Authority是本Feature的待处理失效，不是第二份装备缓存。
    local now = S.NowMs and S.NowMs() or 0
    local pending = self.pendingEdges
    reason = tostring(reason or "event")
    if reason == "equipment_changed" then pending.equipment, pending.aura = true, true
    elseif reason == "target_changed" then pending.target, pending.aura = true, true
    else pending.aura = true end
    if self.pendingSince == nil then self.pendingSince = now end
    self.pvpMetrics.queued = self.pvpMetrics.queued + 1
    local delay = reason == "target_changed" and 1 or math.max(1, math.min(50, tonumber(delayMs) or 50))
    local due = now + delay
    local exists = S.Scheduler.tasks and S.Scheduler.tasks[self.eventTaskName] ~= nil
    if exists and self.pendingDue ~= nil and self.pendingDue <= due then
        self.pvpMetrics.merged = self.pvpMetrics.merged + 1
        return true
    end
    if exists then S.Scheduler:RemoveTask(self.eventTaskName) end
    self.pendingDue = due
    local epoch, generation = self.eventEpoch, S.Generation
    local add = S.Scheduler.AddHighFrequencyOneShot or S.Scheduler.AddOneShot
    if type(add) ~= "function" then return false, "状态显示事件合并任务不可用" end
    local ok = add(S.Scheduler, self.eventTaskName, delay, function()
        if F.eventEpoch ~= epoch or S.Generation ~= generation then return true end
        local edges, since = F.pendingEdges, F.pendingSince
        F.pendingEdges, F.pendingSince, F.pendingDue = {}, nil, nil
        if F.enabled ~= true or (tonumber(F.consumerCount) or 0) <= 0 then return true end
        local at = S.NowMs and S.NowMs() or 0
        F.pvpMetrics.drained = F.pvpMetrics.drained + 1
        F.pvpMetrics.maxQueueAgeMs = math.max(F.pvpMetrics.maxQueueAgeMs, at - (since or at))
        local settings = Settings()
        -- 强制刷新只越过共享Aura本次TTL；不改别的消费者缓存策略、不扫描静态库。
        if edges.aura then F:Refresh("event_batch", true) end
        if (edges.equipment or edges.target) and LaneNeeds("equipment", settings) then F:EquipmentTick(true) end
        if edges.target then
            targetKindCache.kind, targetKindCache.at = nil, 0
            if LaneNeeds("distance", settings) then F:DistanceTick() end
            if LaneNeeds("metadata", settings) then F:MetadataTick() end
            if LaneNeeds("cast", settings) then F:CastTick() end
        end
        return true
    end, self, "P1", 2)
    if ok == true and type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(self.eventTaskName, self.Id, true) end
    return ok == true, ok == true and nil or "状态显示事件合并任务创建失败"
end

function F:_StartEvents()
    if self.eventSubscribed == true then return true end
    if S.Events == nil or type(S.Events.SubscribeOptional) ~= "function" then return true end
    local any = false
    if S.Events:SubscribeOptional("BUFF_UPDATE", self, function()
        F.eventEdges = (tonumber(F.eventEdges) or 0) + 1
        -- 中文维护：留存期间在事件边立即读已暴露的事实，不能延迟120ms直到短状态消失。
        -- forceRefresh 仅绕过共享Aura本次缓存，不遍历静态库；无消费者/关闭时不读Native。
        if F.managementFreeze and F.managementFreeze.active and F.enabled and (F.consumerCount or 0)>0 then
            return F:Refresh("capture_buff_update",true)
        end
        return F:_QueueEventRefresh("buff_update", 120)
    end) == true then any = true end
    if S.Events:SubscribeOptional("DEBUFF_UPDATE", self, function()
        F.eventEdges = (tonumber(F.eventEdges) or 0) + 1
        -- 中文维护：留存期间在事件边立即读已暴露的事实，不能延迟120ms直到短状态消失。
        -- forceRefresh 仅绕过共享Aura本次缓存，不遍历静态库；无消费者/关闭时不读Native。
        if F.managementFreeze and F.managementFreeze.active and F.enabled and (F.consumerCount or 0)>0 then
            return F:Refresh("capture_debuff_update",true)
        end
        return F:_QueueEventRefresh("debuff_update", 120)
    end) == true then any = true end
    if S.Events:SubscribeOptional("TARGET_CHANGED", self, function()
        -- 中文维护：事件边立即撤掉前一目标类型/职业，延迟采样尚未执行时不能短暂贴到新目标。
        -- 维护：失效必须覆盖整份身份快照；只清职业/类型仍会把旧Buff、装分、读条贴到新目标。
        F.laneData.target, F.projections.target, F.coverage.target = {}, {}, {}
        F.targetInvalidated = true
        F.pvpMetrics.targetInvalidations = F.pvpMetrics.targetInvalidations + 1
        targetKindCache.kind, targetKindCache.at = nil, 0
        Publish("v3.buff_display.plates.updated", "target_identity_invalidated")
        F.eventEdges = (tonumber(F.eventEdges) or 0) + 1
        -- 中文维护：留存期间在事件边立即读已暴露的事实，不能延迟120ms直到短状态消失。
        -- forceRefresh 仅绕过共享Aura本次缓存，不遍历静态库；无消费者/关闭时不读Native。
        if F.managementFreeze and F.managementFreeze.active and F.enabled and (F.consumerCount or 0)>0 then
            F:Refresh("capture_target_changed",true)
        end
        return F:_QueueEventRefresh("target_changed", 80)
    end) == true then any = true end
    -- Weapon/glider swaps must reach the head icons near-instantly (PvP swap
    -- tracking); the 1000ms equipment lane is only a drift backstop.
    if S.Events:SubscribeOptional("UNIT_EQUIPMENT_CHANGED", self, function()
        F.eventEdges = (tonumber(F.eventEdges) or 0) + 1
        return F:_QueueEventRefresh("equipment_changed", 60)
    end) == true then any = true end
    -- internal: re-gate lanes when any display setting changes
    if type(S.Events.SubscribeInternal) == "function" then
        S.Events:UnsubscribeInternalOwner(self)
        S.Events:SubscribeInternal("v3.buff_display.settings", self, function()
            self.trackedIndex = self:BuildTrackedIndex(Settings())
            return self:ReconcileLanes()
        end)
        any = true
    end
    self.eventSubscribed = any
    return true
end

function F:_StopEvents()
    -- 维护：已退订的旧闭包不能写入重开后的Feature；清掉未执行失效，不保留第二个调度器。
    self.eventEpoch = self.eventEpoch + 1
    self.pendingEdges, self.pendingSince, self.pendingDue = {}, nil, nil
    if S.Events ~= nil and type(S.Events.UnsubscribeOwner) == "function" then S.Events:UnsubscribeOwner(self) end
    if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(self.eventTaskName) end
    self.eventSubscribed = false
    return true
end

function F:ReconcileDemand(before, after)
    local beforeCount, afterCount = tonumber(before and before.count) or 0, tonumber(after and after.count) or 0
    if beforeCount <= 0 and afterCount > 0 then
        local ok, err = self:_AcquireAura()
        if ok ~= true then return false, err end
        ok, err = self:_StartTask()
        if ok ~= true then self:_ReleaseAura(); return false, err end
        self:_StartEvents()
        local laneOk, laneErr = self:ReconcileLanes()
        if laneOk ~= true then
            self:_StopEvents()
            for laneKey in pairs(self.lanes) do SetLaneActive(laneKey, false, nil) end
            self:_ReleaseCasting()
            self:_ReleaseAura()
            return false, laneErr
        end
    elseif beforeCount > 0 and afterCount <= 0 then
        self:_StopEvents()
        for laneKey in pairs(self.lanes) do SetLaneActive(laneKey, false, nil) end
        local castOk, castErr = self:_ReleaseCasting()
        local auraOk, auraErr = self:_ReleaseAura()
        if castOk ~= true then return false, castErr end
        if auraOk ~= true then return false, auraErr end
        self.projections = { player = {}, target = {} }
        self.coverage = { player = {}, target = {} }
        self.laneData = { player = {}, target = {} }
        if type(self.ClearFrozenRows)=="function" then self:ClearFrozenRows() end
    end
    return true
end

if S.Demand == nil or type(S.Demand.Create) ~= "function" then error("Demand unavailable for BuffDisplay") end
local demand, demandErr = S.Demand:Create({
    id = "feature:" .. F.Id, owner = F, projectionOwner = F,
    projectionConsumersField = "consumers", projectionCountField = "consumerCount",
    reconcile = function(_, before, after) return F:ReconcileDemand(before, after) end,
    quiesce = function()
        F:_StopEvents()
        for laneKey in pairs(F.lanes) do SetLaneActive(laneKey, false, nil) end
        F:_ReleaseCasting()
        F:_ReleaseAura()
        F.laneData = { player = {}, target = {} }
        if type(F.ClearFrozenRows)=="function" then F:ClearFrozenRows() end
        return true
    end,
})
if demand == nil then error(demandErr) end
F.Demand = demand

function F:Initialize()
    local ok, err = self:EnsureStoreLoaded()
    if ok ~= true then return false, err end
    local aura = Aura()
    if type(aura) ~= "table" or type(aura.GetSnapshot) ~= "function" or type(aura.GetStatusMap) ~= "function" then
        return false, "AuraObservationV3 unavailable"
    end
    local classification = Classification()
    if type(classification) ~= "table" or type(classification.ClassifyEntry) ~= "function" then
        return false, "StatusClassificationV3 unavailable"
    end
    local projection = Projection()
    if type(projection) ~= "table" or type(projection.ProjectUnit) ~= "function" then
        return false, "ScreenProjectionV3 unavailable"
    end
    if type(self.ProjectStatusMap) ~= "function" or type(self.ProjectPlates) ~= "function" then
        return false, "状态显示投影模块未完整加载"
    end
    self.trackedIndex = self:BuildTrackedIndex(Settings())
    return true
end

function F:AcquireConsumer(token)
    if self.enabled ~= true then return false, "状态显示功能未启用" end
    return self.Demand:Acquire(token, {}, "buff_display_consumer")
end
function F:ReleaseConsumer(token) return self.Demand:Release(token, "buff_display_consumer") end
function F:Enable() self.enabled = true; return true end
function F:Disable(reason)
    if self.enabled ~= true then return true end
    local ok, err = self.Demand:Clear(reason or "feature_disable")
    if ok ~= true then return false, err end
    self.enabled = false
    return true
end
function F:GetHealth()
    local aura = Aura()
    local ah = type(aura) == "table" and type(aura.GetHealth) == "function" and aura:GetHealth() or {}
    local activeLanes = {}
    for laneKey, lane in pairs(self.lanes) do if lane.active == true then activeLanes[#activeLanes + 1] = laneKey end end
    table.sort(activeLanes)
    -- 中文维护注释：公开有界诊断，不把目录/冻结行写入 Store；未接入 Native 的 CD 不报告为可用。
    return { schemaVersion=self.SchemaVersion, management=type(self.GetManagementHealth)=="function" and self:GetManagementHealth() or nil,
        ok = self.enabled == true, consumers = self.consumerCount, auraHeld = self.auraHeld == true, castingHeld = self.castingHeld == true,
        revision = self.revision, player = self.coverage.player, target = self.coverage.target,
        eventSubscribed = self.eventSubscribed == true, eventEdges = tonumber(self.eventEdges) or 0,
        eventRefreshPending = S.Scheduler ~= nil and S.Scheduler.tasks and S.Scheduler.tasks[self.eventTaskName] ~= nil,
        observationContractVersion = 2,
        pvp = { patch=self.PvpPatch, queued=self.pvpMetrics.queued, merged=self.pvpMetrics.merged,
            drained=self.pvpMetrics.drained, maxQueueAgeMs=self.pvpMetrics.maxQueueAgeMs,
            pendingAgeMs=self.pendingSince and math.max(0,(S.NowMs and S.NowMs() or 0)-self.pendingSince) or 0,
            positionTicks=self.pvpMetrics.positionTicks, equipmentTicks=self.pvpMetrics.equipmentTicks,
            lastEquipmentAt=self.pvpMetrics.lastEquipmentAt, lastAuraAt=self.pvpMetrics.lastAuraAt,
            targetInvalidations=self.pvpMetrics.targetInvalidations, equipmentBackstopMs=200, eventWindowMs=50 },
        equipmentDiagnostics = S.Utils ~= nil and type(S.Utils.DeepCopy) == "function" and S.Utils.DeepCopy(F.EquipmentDiagnostics) or F.EquipmentDiagnostics,
        activeLanes = activeLanes,
        auraConsumers = tonumber(ah.consumers) or 0, taskActive = S.Scheduler ~= nil and S.Scheduler.tasks and S.Scheduler.tasks[self.taskName] ~= nil }
end

function F:GetWidgetVisible() return self.State and self.State.widgetVisible == true end
function F:GetWidgetWindowState()
    local value = self.State and self.State.widgetWindow or nil
    local floating = S.RSUI and S.RSUI.FloatingSurface or nil
    local policy = { defaultWidth = 430, defaultHeight = 300, minWidth = 180, minHeight = 100,
        defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 }
    if type(floating) == "table" and type(floating.NormalizeState) == "function" then
        return S.Utils.DeepCopy(floating:NormalizeState(value, policy))
    end
    return S.Utils.DeepCopy(value)
end
function F:SetWidgetWindowState(value, reason)
    if type(value) ~= "table" or type(self.State) ~= "table" then return false, "buff display widget window state unavailable" end
    -- FloatingSurface persists in a second callback after setState(). Preflight
    -- here guarantees that callback can never be the first operation against a
    -- cold Store, avoiding mutate-before-load state loss.
    if S.Persistence ~= nil and type(S.Persistence.PrepareWrite) == "function" then
        local prepared, prepareErr = S.Persistence:PrepareWrite(self.StoreId)
        if prepared ~= true then return false, prepareErr or "状态显示悬浮窗配置尚未安全读取" end
    end
    local floating = S.RSUI and S.RSUI.FloatingSurface or nil
    local policy = { defaultWidth = 430, defaultHeight = 300, minWidth = 180, minHeight = 100,
        defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 }
    self.State.widgetWindow = type(floating) == "table" and type(floating.NormalizeState) == "function"
        and floating:NormalizeState(value, policy) or S.Utils.DeepCopy(value)
    return true
end
function F:SetWidgetVisible(value, reason)
    if self.State == nil then return false, "状态显示设置不可用" end
    local ok, err = self:MutateStore(function()
        self.State.widgetVisible = value == true
        return true
    end, 250, "widget_" .. tostring(reason or "visibility"))
    if ok ~= true then return false, err or "状态显示显隐保存失败" end
    return true
end

------------------------------------------------------------------------
-- Import / Export
------------------------------------------------------------------------

-- Parse a plain tracked-id text. Commas, semicolons and whitespace are valid
-- separators. Invalid entries do not invalidate the valid remainder.
function F:ParseTrackedText(text)
    text = tostring(text or "")
    local ids, seen, errors, duplicates = {}, {}, {}, 0
    for _, raw in ipairs(SplitLines(text)) do
        local comment = string.find(raw, "#", 1, true)
        local line = comment ~= nil and string.sub(raw, 1, comment - 1) or raw
        for token in line:gmatch("[^,%s;]+") do
            local id = tonumber(token)
            if id == nil or id ~= math.floor(id) or id <= 0 then
                errors[#errors + 1] = "无效 ID：" .. tostring(token)
            elseif seen[id] == true then
                duplicates = duplicates + 1
            else
                seen[id] = true
                ids[#ids + 1] = id
            end
        end
    end
    table.sort(ids)
    return { ids = ids, errors = errors, duplicates = duplicates }
end

-- Quick tracked-id import. category: "buff" | "debuff" | "auto".
-- mode: "merge" keeps existing tracked ids, "overwrite" replaces the category.
function F:ImportTrackedIds(text, category, mode)
    local parsed = self:ParseTrackedText(text)
    if type(parsed) ~= "table" then return false, "追踪 ID 解析失败" end
    if #parsed.ids == 0 then
        local suffix = #parsed.errors > 0 and ("；非法 " .. tostring(#parsed.errors) .. " 项") or ""
        return false, "没有可导入的 Buff ID" .. suffix
    end
    local marked, markErr = self:MutateStore(function()
        local settings = self.State.settings
        local targetCategories = {}
        if category == "debuff" then targetCategories[1] = "debuff"
        elseif category == "buff" then targetCategories[1] = "buff"
        else targetCategories[1], targetCategories[2] = "buff", "debuff" end
        for _, bucket in ipairs(targetCategories) do
            local existing = mode == "overwrite" and {} or S.Utils.DeepCopy(settings.tracked[bucket] or {})
            local seen = {}
            for _, id in ipairs(existing) do seen[id] = true end
            for _, id in ipairs(parsed.ids) do
                local bucketCategory = bucket
                if category == "auto" or category == nil then
                    local classification = Classification()
                    if classification ~= nil and type(classification.ClassifyId) == "function" then
                        local kind = classification:ClassifyId(id, settings.classification)
                        if kind ~= nil and kind.category == "debuff" then bucketCategory = "debuff" else bucketCategory = "buff" end
                    end
                end
                if bucketCategory == bucket and seen[id] ~= true and #existing < 1024 then
                    seen[id] = true
                    existing[#existing + 1] = id
                end
            end
            table.sort(existing)
            settings.tracked[bucket] = existing
        end
        return true
    end, 250, "import_tracked")
    if marked ~= true then return false, markErr or "追踪 ID 导入保存失败" end
    local settings = self.State.settings
    self.trackedIndex = self:BuildTrackedIndex(settings)
    self:SyncTrackedProjectionFlags()
    Publish("v3.buff_display.settings", "tracked")
    local details = { "有效 " .. tostring(#parsed.ids) }
    if (tonumber(parsed.duplicates) or 0) > 0 then details[#details + 1] = "重复 " .. tostring(parsed.duplicates) end
    if #parsed.errors > 0 then details[#details + 1] = "非法 " .. tostring(#parsed.errors) end
    return true, "导入完成：" .. table.concat(details, " · ")
end

-- Full export: schema version + tracked + components + classification + policy.
function F:ExportAll()
    local settings = Settings()
    return {
        format = "replicatedsuite.buff_display",
        schemaVersion = self.SchemaVersion or 5,
        tracked = S.Utils.DeepCopy(settings.tracked or { buff = {}, debuff = {} }),
        components = S.Utils.DeepCopy(settings.components or {}),
        -- 中文维护注释（完整导出双 HUD）：legacy `components` 继续导出 player 组件，
        -- 供旧文本兼容；`hud` 是新 Authority 快照，补齐 player 的 plate/info/scale 以及
        -- target 全量视觉 profile。导出只读 detached snapshot，不触碰运行时缓存。
        hud = type(self.GetHudCalibrationSnapshot) == "function" and self:GetHudCalibrationSnapshot() or nil,
        classification = S.Utils.DeepCopy(settings.classification or {}),
        settings = {
            showBuffs = settings.showBuffs ~= false, showDebuffs = settings.showDebuffs ~= false,
            showHidden = settings.showHidden == true, freezeEnabled = settings.freezeEnabled == true,
            playerRows = settings.playerRows, targetRows = settings.targetRows,
            refreshMs = settings.refreshMs, headEnabled = settings.headEnabled ~= false,
            headShowAll = settings.headShowAll == true,
            headPlayer = settings.headPlayer ~= false, headTarget = settings.headTarget ~= false,
            headRefreshMs = settings.headRefreshMs,
            headShowStacks = settings.headShowStacks ~= false, headShowTime = settings.headShowTime ~= false,
        },
    }
end

-- Line-based serialization for the multi-line edit box.
function F:SerializeExport(data)
    data = type(data) == "table" and data or {}
    local lines = {
        "# ReplicatedSuite 状态显示导出",
        "VERSION=" .. tostring(data.schemaVersion or self.SchemaVersion or 5),
        "FORMAT=" .. tostring(data.format or "replicatedsuite.buff_display"),
    }
    for _, category in ipairs({ "buff", "debuff" }) do
        local ids = type(data.tracked) == "table" and type(data.tracked[category]) == "table" and data.tracked[category] or {}
        if #ids > 0 then lines[#lines + 1] = string.upper(category) .. "=" .. table.concat(ids, ",") end
    end
    local classification = type(data.classification) == "table" and data.classification or {}
    for id, category in pairs(classification) do lines[#lines + 1] = "CLASSIFICATION=" .. tostring(id) .. ":" .. tostring(category) end
    for _, key in ipairs(COMPONENT_KEYS) do
        local component = type(data.components) == "table" and data.components[key] or nil
        if type(component) == "table" then
            lines[#lines + 1] = "COMPONENT=" .. key .. ":enabled:" .. (component.enabled ~= false and "1" or "0")
            lines[#lines + 1] = "COMPONENT=" .. key .. ":x:" .. tostring(component.x or 0)
            lines[#lines + 1] = "COMPONENT=" .. key .. ":y:" .. tostring(component.y or 0)
            lines[#lines + 1] = "COMPONENT=" .. key .. ":size:" .. tostring(component.size or 0)
            lines[#lines + 1] = "COMPONENT=" .. key .. ":fontSize:" .. tostring(component.fontSize or 0)
            lines[#lines + 1] = "COMPONENT=" .. key .. ":alpha:" .. tostring(component.alpha or 1)
            -- Serialize component-specific geometry too. Without these fields a
            -- full export/import silently lost row capacity/spacing and cast-bar
            -- width/text settings even though the UI exposed them.
            if key == "buffs" or key == "debuffs" or key == "cooldowns" then
                lines[#lines + 1] = "COMPONENT=" .. key .. ":spacing:" .. tostring(component.spacing or 2)
                lines[#lines + 1] = "COMPONENT=" .. key .. ":maxPerRow:" .. tostring(component.maxPerRow or 8)
                lines[#lines + 1] = "COMPONENT=" .. key .. ":maxRows:" .. tostring(component.maxRows or 2)
            elseif key == "castBar" then
                lines[#lines + 1] = "COMPONENT=" .. key .. ":width:" .. tostring(component.width or 120)
                lines[#lines + 1] = "COMPONENT=" .. key .. ":showText:" .. (component.showText ~= false and "1" or "0")
            end
        end
    end
    -- HUD profile extension is additive to the legacy line format. Older builds
    -- ignore these unknown records while still reading COMPONENT/SETTING; new
    -- builds preserve player plate/info/scale and the entire target profile.
    local hud = type(data.hud) == "table" and data.hud or {}
    local function AppendBool(value) return value == true and "1" or "0" end
    local function AppendHudProfile(scope, profile, includeComponents)
        if type(profile) ~= "table" then return end
        lines[#lines + 1] = "HUDSCALE=" .. scope .. ":" .. tostring(profile.plateScale or 1)
        local plate = type(profile.plate) == "table" and profile.plate or {}
        for _, field in ipairs({ "enabled", "width", "height", "x", "y", "opacity", "showName" }) do
            if plate[field] ~= nil then
                local value = (field == "enabled" or field == "showName") and AppendBool(plate[field]) or tostring(plate[field])
                lines[#lines + 1] = "HUDPLATE=" .. scope .. ":" .. field .. ":" .. value
            end
        end
        local info = type(profile.info) == "table" and profile.info or {}
        for _, field in ipairs({ "enabled", "x", "y", "fontSize", "showClass", "showGear", "showDistance" }) do
            if info[field] ~= nil then
                local isBool = field == "enabled" or field == "showClass" or field == "showGear" or field == "showDistance"
                lines[#lines + 1] = "HUDINFO=" .. scope .. ":" .. field .. ":" .. (isBool and AppendBool(info[field]) or tostring(info[field]))
            end
        end
        if includeComponents == true then
            local profileComponents = type(profile.components) == "table" and profile.components or {}
            for _, key in ipairs(COMPONENT_KEYS) do
                local component = profileComponents[key]
                if type(component) == "table" then
                    for _, field in ipairs({ "enabled", "x", "y", "size", "fontSize", "alpha", "spacing", "maxPerRow", "maxRows", "width", "showText" }) do
                        if component[field] ~= nil then
                            local value = (field == "enabled" or field == "showText") and AppendBool(component[field]) or tostring(component[field])
                            lines[#lines + 1] = "HUDCOMPONENT=" .. scope .. ":" .. key .. ":" .. field .. ":" .. value
                        end
                    end
                end
            end
        end
    end
    AppendHudProfile("player", hud.player, false)
    AppendHudProfile("target", hud.target, true)

    local policy = type(data.settings) == "table" and data.settings or {}
    for _, key in ipairs({ "refreshMs", "headRefreshMs", "playerRows", "targetRows", "showBuffs", "showDebuffs", "showHidden", "freezeEnabled", "headEnabled", "headShowAll", "headPlayer", "headTarget", "headShowStacks", "headShowTime" }) do
        if policy[key] ~= nil then lines[#lines + 1] = "SETTING=" .. key .. ":" .. tostring(policy[key]) end
    end
    return table.concat(lines, "\n")
end

-- Parse full-export text. Returns { data = table, errors = {line:n msg}, warnings = {...} }.
function F:ParseImportText(text)
    text = tostring(text or "")
    local data = { tracked = { buff = {}, debuff = {} }, components = {}, hud = {}, classification = {}, settings = {}, schemaVersion = 5 }
    local errors, warnings = {}, {}
    local seenTracked = {}
    for index, raw in ipairs(SplitLines(text)) do
        local line = raw:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local eq = string.find(line, "=", 1, true)
            if eq == nil then errors[#errors + 1] = "第 " .. tostring(index) .. " 行缺少 =： " .. tostring(raw); else
                local key, value = string.sub(line, 1, eq - 1), string.sub(line, eq + 1)
                key = key:gsub("%s+", ""):upper()
                value = value:gsub("%s+", "")
                if key == "VERSION" then
                    local version = tonumber(value)
                    if version ~= nil then data.schemaVersion = math.floor(version) end
                elseif key == "BUFF" or key == "DEBUFF" then
                    local bucket = key == "DEBUFF" and "debuff" or "buff"
                    for token in value:gmatch("[^,;]+") do
                        token = token:gsub("%s+", "")
                        local id = tonumber(token)
                        if id ~= nil and id == math.floor(id) and id > 0 then
                            if seenTracked[id] ~= true then
                                seenTracked[id] = true
                                if #data.tracked[bucket] < 1024 then data.tracked[bucket][#data.tracked[bucket] + 1] = id
                                else warnings[#warnings + 1] = "第 " .. tostring(index) .. " 行：单类最多 1024 个，已截断" end
                            end
                        else
                            errors[#errors + 1] = "第 " .. tostring(index) .. " 行：无效 ID " .. tostring(token)
                        end
                    end
                elseif key == "CLASSIFICATION" then
                    local colon = string.find(value, ":", 1, true)
                    if colon == nil then errors[#errors + 1] = "第 " .. tostring(index) .. " 行：分类格式应为 id:buff|debuff" else
                        local id = tonumber(string.sub(value, 1, colon - 1))
                        local category = string.sub(value, colon + 1):lower()
                        if id ~= nil and id > 0 and (category == "buff" or category == "debuff") then
                            data.classification[id] = category
                        else
                            errors[#errors + 1] = "第 " .. tostring(index) .. " 行：无效分类 " .. tostring(value)
                        end
                    end
                elseif key == "COMPONENT" then
                    local parts = {}
                    for part in value:gmatch("[^:]+") do parts[#parts + 1] = part end
                    if #parts < 3 then errors[#errors + 1] = "第 " .. tostring(index) .. " 行：组件格式应为 key:field:value" else
                        local componentKey, field, rawValue = parts[1], parts[2], parts[3]
                        local known = false
                        for _, ck in ipairs(COMPONENT_KEYS) do if ck == componentKey then known = true break end end
                        if not known then errors[#errors + 1] = "第 " .. tostring(index) .. " 行：未知组件 " .. tostring(componentKey) else
                            local component = data.components[componentKey] or {}
                            if field == "enabled" or field == "showText" then component[field] = rawValue == "1" or rawValue == "true"
                            elseif field == "x" or field == "y" or field == "size" or field == "fontSize"
                                or field == "spacing" or field == "maxPerRow" or field == "maxRows" or field == "width" then
                                local n = tonumber(rawValue)
                                if n == nil then errors[#errors + 1] = "第 " .. tostring(index) .. " 行：无效数值 " .. tostring(rawValue)
                                else component[field] = math.floor(n) end
                            elseif field == "alpha" then
                                local n = tonumber(rawValue)
                                if n == nil then errors[#errors + 1] = "第 " .. tostring(index) .. " 行：无效透明度 " .. tostring(rawValue)
                                else component[field] = n end
                            else errors[#errors + 1] = "第 " .. tostring(index) .. " 行：未知组件字段 " .. tostring(field) end
                            data.components[componentKey] = component
                        end
                    end
                elseif key == "HUDSCALE" then
                    local scope, rawValue = value:match("^([^:]+):(.+)$")
                    if scope ~= "player" and scope ~= "target" then errors[#errors + 1] = "第 " .. tostring(index) .. " 行：HUD scope 必须是 player/target"
                    else
                        local n = tonumber(rawValue)
                        if n == nil then errors[#errors + 1] = "第 " .. tostring(index) .. " 行：HUD 缩放无效"
                        else data.hud[scope] = data.hud[scope] or {}; data.hud[scope].plateScale = n end
                    end
                elseif key == "HUDPLATE" or key == "HUDINFO" then
                    local parts = {}; for part in value:gmatch("[^:]+") do parts[#parts + 1] = part end
                    if #parts < 3 then errors[#errors + 1] = "第 " .. tostring(index) .. " 行：HUD profile 格式无效" else
                        local scope, field, rawValue = parts[1], parts[2], parts[3]
                        if scope ~= "player" and scope ~= "target" then errors[#errors + 1] = "第 " .. tostring(index) .. " 行：HUD scope 必须是 player/target" else
                            local isPlate = key == "HUDPLATE"
                            local boolFields = isPlate and { enabled=true, showName=true } or { enabled=true, showClass=true, showGear=true, showDistance=true }
                            local numberFields = isPlate and { width=true, height=true, x=true, y=true, opacity=true } or { x=true, y=true, fontSize=true }
                            if boolFields[field] ~= true and numberFields[field] ~= true then
                                errors[#errors + 1] = "第 " .. tostring(index) .. " 行：未知 HUD 字段 " .. tostring(field)
                            else
                                local target = isPlate and "plate" or "info"
                                data.hud[scope] = data.hud[scope] or {}; data.hud[scope][target] = data.hud[scope][target] or {}
                                if boolFields[field] == true then data.hud[scope][target][field] = rawValue == "1" or rawValue == "true"
                                else
                                    local n = tonumber(rawValue)
                                    if n == nil then errors[#errors + 1] = "第 " .. tostring(index) .. " 行：HUD 数值无效 " .. tostring(rawValue)
                                    else data.hud[scope][target][field] = n end
                                end
                            end
                        end
                    end
                elseif key == "HUDCOMPONENT" then
                    local parts = {}; for part in value:gmatch("[^:]+") do parts[#parts + 1] = part end
                    if #parts < 4 then errors[#errors + 1] = "第 " .. tostring(index) .. " 行：HUDCOMPONENT 格式应为 scope:key:field:value" else
                        local scope, componentKey, field, rawValue = parts[1], parts[2], parts[3], parts[4]
                        local known = false; for _, ck in ipairs(COMPONENT_KEYS) do if ck == componentKey then known = true break end end
                        if (scope ~= "player" and scope ~= "target") or known ~= true then
                            errors[#errors + 1] = "第 " .. tostring(index) .. " 行：HUDCOMPONENT scope/组件无效"
                        else
                            local boolField = field == "enabled" or field == "showText"
                            local numberField = field == "x" or field == "y" or field == "size" or field == "fontSize" or field == "alpha"
                                or field == "spacing" or field == "maxPerRow" or field == "maxRows" or field == "width"
                            if not boolField and not numberField then errors[#errors + 1] = "第 " .. tostring(index) .. " 行：未知 HUD 组件字段 " .. tostring(field) else
                                data.hud[scope] = data.hud[scope] or {}; data.hud[scope].components = data.hud[scope].components or {}
                                local component = data.hud[scope].components[componentKey] or {}
                                if boolField then component[field] = rawValue == "1" or rawValue == "true" else
                                    local n = tonumber(rawValue)
                                    if n == nil then errors[#errors + 1] = "第 " .. tostring(index) .. " 行：HUD 组件数值无效 " .. tostring(rawValue) else component[field] = n end
                                end
                                data.hud[scope].components[componentKey] = component
                            end
                        end
                    end
                elseif key == "SETTING" then
                    local colon = string.find(value, ":", 1, true)
                    if colon == nil then errors[#errors + 1] = "第 " .. tostring(index) .. " 行：设置格式应为 key:value" else
                        data.settings[string.sub(value, 1, colon - 1)] = string.sub(value, colon + 1)
                    end
                else
                    warnings[#warnings + 1] = "第 " .. tostring(index) .. " 行：忽略未知条目 " .. tostring(key)
                end
            end
        end
    end
    table.sort(data.tracked.buff)
    table.sort(data.tracked.debuff)
    return { data = data, errors = errors, warnings = warnings }
end

-- Apply parsed full-export data. mode "merge" only adds missing tracked ids and
-- applies components/classification that are explicitly present; "overwrite"
-- replaces tracked lists entirely (policy fields always overwrite when present).
function F:ImportAll(data, mode)
    -- 中文维护注释（v2 原子导入）：容量/非法输入/跨桶冲突先整体拒绝，预览绝不调用 Native。
    -- Legacy HUD 字段仍走下方原有 ApplyRaw 链；所有选择与双 HUD 只提交一个 durable 事务。
    local prepared, prepareErr = self:PrepareTrackingImport(data, mode)
    if prepared == nil then return false, prepareErr end
    local nextClassification = nil
    local marked, markErr = self:MutateStore(function()
        local settings = self.State.settings
        settings.tracked = S.Utils.DeepCopy(prepared.tracked)
        settings.trackedCooldowns = S.Utils.DeepCopy(prepared.trackedCooldowns)
        settings.classification = S.Utils.DeepCopy(prepared.classification)
        nextClassification = S.Utils.DeepCopy(prepared.classification)
        if type(data.components) == "table" then
            for _, key in ipairs({ "buffs", "debuffs", "distance", "class", "gearScore", "mainHand", "offHand", "ranged", "wings", "castBar", "cooldowns" }) do
                local component = data.components[key]
                if type(component) == "table" and next(component) ~= nil then
                    for field, value in pairs(component) do
                        -- Import runs inside one persistence transaction. Keep
                        -- component writes Domain-only until the transaction
                        -- commits; publishing per-field events here would expose
                        -- uncommitted preview state to consumers.
                        local ok, err = self:ApplySettingRaw("components." .. key .. "." .. tostring(field), value)
                        if ok ~= true then return false, err end
                    end
                end
            end
        end
        -- Apply the optional dual-HUD profile inside this same persistence transaction.
        -- `COMPONENT=` legacy player fields above have already updated State, so the
        -- baseline snapshot here includes them before profile-specific plate/info data.
        if type(data.hud) == "table" and next(data.hud) ~= nil and type(self.ApplyHudCalibrationSnapshotRaw) == "function" then
            local currentHud = self:GetHudCalibrationSnapshot()
            local function OverlayProfile(base, patch)
                base = S.Utils.DeepCopy(type(base) == "table" and base or {})
                patch = type(patch) == "table" and patch or {}
                if patch.plateScale ~= nil then base.plateScale = patch.plateScale end
                for _, section in ipairs({ "plate", "info" }) do
                    if type(patch[section]) == "table" then
                        base[section] = type(base[section]) == "table" and base[section] or {}
                        for field, item in pairs(patch[section]) do base[section][field] = item end
                    end
                end
                if type(patch.components) == "table" then
                    base.components = type(base.components) == "table" and base.components or {}
                    for componentKey, componentPatch in pairs(patch.components) do
                        base.components[componentKey] = type(base.components[componentKey]) == "table" and base.components[componentKey] or {}
                        for field, item in pairs(type(componentPatch) == "table" and componentPatch or {}) do base.components[componentKey][field] = item end
                    end
                end
                return base
            end
            currentHud.player = OverlayProfile(currentHud.player, data.hud.player)
            currentHud.target = OverlayProfile(currentHud.target, data.hud.target)
            local hudOk, hudErr = self:ApplyHudCalibrationSnapshotRaw(currentHud)
            if hudOk ~= true then return false, hudErr or "HUD profile 导入失败" end
        end
        local policy = type(data.settings) == "table" and data.settings or {}
        for key, value in pairs(policy) do
            if key == "headIconSize" then
                local n = math.max(8, math.min(64, math.floor(tonumber(value) or 24)))
                local okA, errA = self:ApplySettingRaw("components.buffs.size", n); if okA ~= true then return false, errA end
                local okB, errB = self:ApplySettingRaw("components.debuffs.size", n); if okB ~= true then return false, errB end
            elseif key == "headMaxIcons" then
                local n = math.max(1, math.min(16, math.floor(tonumber(value) or 8)))
                local okA, errA = self:ApplySettingRaw("components.buffs.maxPerRow", n); if okA ~= true then return false, errA end
                local okB, errB = self:ApplySettingRaw("components.debuffs.maxPerRow", n); if okB ~= true then return false, errB end
            else
                local normalized = value
                if key == "showBuffs" or key == "showDebuffs" or key == "showHidden"
                    or key == "freezeEnabled" or key == "headEnabled" or key == "headShowAll"
                    or key == "headPlayer" or key == "headTarget" or key == "headShowStacks"
                    or key == "headShowTime" then
                    local raw = tostring(value):lower()
                    normalized = raw == "1" or raw == "true"
                end
                local ok, err = self:ApplySettingRaw(key, normalized)
                if ok ~= true and tostring(err or ""):find("unknown buff display setting", 1, true) == nil then return false, err end
            end
        end
        return true
    end, 0, "import_all", true)
    if marked ~= true then return false, markErr or "完整导入保存失败" end

    local classification = Classification()
    if nextClassification ~= nil and classification ~= nil and type(classification.ApplyOverrides) == "function" then
        classification:ApplyOverrides(nextClassification)
    end
    local settings = self.State.settings
    self.trackedIndex = self:BuildTrackedIndex(settings)
    self:SyncTrackedProjectionFlags()
    self:ReconcileLanes()
    Publish("v3.buff_display.settings", "import")
    return true, "完整导入成功"
end

F.Commands = {
    Refresh = function(_, reason) return F:Refresh(reason or "buff_display_command") end,
    -- Ground-truth field probe: dump the RAW shapes the live client returns for
    -- the player's first buff row (UnitBuff row, UnitBuffTooltip row, trailing
    -- returns, GetBuffTooltip return). Read-only, one-shot, bypasses every
    -- cache — this is how we settle which field actually carries the name on
    -- the current RU client instead of guessing at aliases.
    ProbeAuraFields = function()
        if X2Unit == nil then return false, "X2Unit 不可用" end
        local function ShapeOf(value, limit)
            local t = type(value)
            if t == "table" then
                local keys = {}
                for k, v in pairs(value) do keys[#keys + 1] = tostring(k) .. ":" .. type(v) end
                table.sort(keys)
                return "{" .. table.concat(keys, ",") .. "}"
            end
            local s = tostring(value)
            if #s > (limit or 48) then s = string.sub(s, 1, limit or 48) .. "…" end
            return t .. "(" .. s .. ")"
        end
        local lines = {}
        local function SafeN(fn, ...)
            local rets = { pcall(fn, ...) }
            if rets[1] ~= true then return nil end
            return rets[2], rets[3], rets[4]
        end
        local okCount, count = pcall(function() return X2Unit:UnitBuffCount("player") end)
        lines[#lines + 1] = "BuffCount=" .. (okCount == true and tostring(count) or "ERR")
        if okCount ~= true or tonumber(count) == nil or tonumber(count) < 1 then
            return false, "自己身上没有可探测的 Buff，请先给自己上一个增益再点。"
        end
        local retA, retB, retC = SafeN(function(...) return X2Unit:UnitBuff(...) end, "player", 1)
        lines[#lines + 1] = "UnitBuff[1]=" .. ShapeOf(retA)
        if retB ~= nil or retC ~= nil then
            lines[#lines + 1] = "UnitBuff额外返回=" .. ShapeOf(retB) .. " , " .. ShapeOf(retC)
        end
        if type(X2Unit.UnitBuffTooltip) == "function" then
            local tA, tB = SafeN(function(...) return X2Unit:UnitBuffTooltip(...) end, "player", 1)
            lines[#lines + 1] = "Tooltip[1]=" .. ShapeOf(tA)
            if tB ~= nil then lines[#lines + 1] = "Tooltip额外=" .. ShapeOf(tB) end
        else
            lines[#lines + 1] = "Tooltip=函数不存在"
        end
        local id = nil
        if type(retA) == "table" then
            id = tonumber(retA.effectId or retA.effect_id or retA.buff_id or retA.buffId or retA.buffID or retA.id or retA.buffType)
        end
        if id ~= nil and X2Ability ~= nil and type(X2Ability.GetBuffTooltip) == "function" then
            local gA, gB = SafeN(function(...) return X2Ability:GetBuffTooltip(...) end, id, 0)
            lines[#lines + 1] = "GetBuffTooltip(" .. id .. ",0)=" .. ShapeOf(gA, 80)
            if gB ~= nil then lines[#lines + 1] = "GetBuff额外=" .. ShapeOf(gB) end
        else
            lines[#lines + 1] = "GetBuffTooltip=不可探测(id或函数缺失)"
        end
        for _, line in ipairs(lines) do
            if S.SafeChat ~= nil then S.SafeChat("[状态诊断] " .. line, "info", "buff_display") end
        end
        return true, table.concat(lines, " | ")
    end,
    ResetLayoutSettings = function()
        if type(F.ResetLayoutSettings) ~= "function" then return false, "布局重置入口不可用" end
        local marked, markErr = F:MutateStore(function()
            local ok, err = F:ResetLayoutSettings()
            if ok ~= true then return false, err or "布局重置失败" end
            return true
        end, 250, "reset_layout_settings")
        if marked ~= true then
            F:ReconcileLanes()
            F:RefreshScope("player")
            F:RefreshScope("target")
            return false, markErr or "布局重置保存失败"
        end
        F:ReconcileLanes()
        F:RefreshScope("player")
        F:RefreshScope("target")
        Publish("v3.buff_display.settings", "layout_reset")
        return true
    end,
    -- Backward-compatible command name; semantics are intentionally narrowed to
    -- Layout Reset so old UI/callers can no longer erase tracked/classification.
    ResetAllSettings = function()
        return F.Commands:ResetLayoutSettings()
    end,
    SetSetting = function(_, key, value)
        -- 中文维护注释：兼容旧按钮命令，但不再写 freezeEnabled 到永久 Store。
        if key=="freezeEnabled" then
            if value==true then return F:CaptureManagementFreeze() end
            return F:ClearFrozenRows()
        end
        local ok,err=F:SetSettingValue(key,value)
        if ok==true then F:ReconcileLanes() end
        return ok,err
    end,
    SetTrackedId = function(_, id, category, enabled)
        local ok, err = F:SetTrackedId(id, category, enabled)
        if ok == true then
            -- 取消追踪只更新选择，不删除冻结的事实；用户可在同一快照再次追踪。
            F.trackedIndex = F:BuildTrackedIndex(Settings())
            F:SyncTrackedProjectionFlags()
            -- 重新刷新的是实时事实；冻结行保留，管理装饰层只更新其追踪标记。
            F:RefreshScope("player")
            F:RefreshScope("target")
        end
        return ok, err
    end,
    ClearTrackedIds = function(_, category)
        local ok, err = F:ClearTrackedIds(category)
        if ok == true then
            F.trackedIndex = F:BuildTrackedIndex(Settings())
            F:SyncTrackedProjectionFlags()
            F:RefreshScope("player")
            F:RefreshScope("target")
        end
        return ok, err
    end,
    SetComponentField = function(_, componentKey, field, value)
        return F:SetComponentField(componentKey, field, value)
    end,
    GetLayoutSettingsSnapshot = function()
        return type(F.GetLayoutSettingsSnapshot) == "function" and F:GetLayoutSettingsSnapshot() or {}
    end,
    GetDefaultLayoutSettingsSnapshot = function()
        return type(F.GetDefaultLayoutSettingsSnapshot) == "function" and F:GetDefaultLayoutSettingsSnapshot() or {}
    end,
    GetHudCalibrationSnapshot = function()
        return type(F.GetHudCalibrationSnapshot) == "function" and F:GetHudCalibrationSnapshot() or { player={}, target={} }
    end,
    GetDefaultHudCalibrationSnapshot = function()
        return type(F.GetDefaultHudCalibrationSnapshot) == "function" and F:GetDefaultHudCalibrationSnapshot() or { player={}, target={} }
    end,
    PersistHudCalibrationSnapshot = function(_, snapshot, reason)
        if type(F.PersistHudCalibrationSnapshot) ~= "function" then return false, "HUD 校准持久化入口不可用" end
        return F:PersistHudCalibrationSnapshot(snapshot, reason)
    end,
    CanPersistLayoutSettings = function()
        if type(F.CanPersistLayoutSettings) ~= "function" then return false, "HUD 布局持久化入口不可用" end
        return F:CanPersistLayoutSettings()
    end,
    PersistLayoutSettingsSnapshot = function(_, snapshot, reason)
        if type(F.PersistLayoutSettingsSnapshot) ~= "function" then return false, "HUD 布局持久化入口不可用" end
        return F:PersistLayoutSettingsSnapshot(snapshot, reason)
    end,
    SetClassification = function(_, id, category)
        local ok, err = F:SetClassification(id, category)
        if ok == true then
            local classification = Classification()
            if classification ~= nil and type(classification.SetOverride) == "function" then classification:SetOverride(id, category) end
        end
        return ok, err
    end,
    ClearClassification = function(_, id)
        local ok, err = F:ClearClassification(id)
        if ok == true then
            local classification = Classification()
            if classification ~= nil and type(classification.ClearOverride) == "function" then classification:ClearOverride(id) end
        end
        return ok, err
    end,
    ApplySettingFromBinding = function(_, key, value) return F:ApplySettingFromBinding(key, value) end,
    MarkStoreDirty = function(_, delayMs, reason) return F:MarkStoreDirty(delayMs, reason) end,
    GetSettings = function() return F:GetSettings() end,
    GetWidgetVisible = function() return F:GetWidgetVisible() end,
    SetWidgetVisible = function(_, value, reason) return F:SetWidgetVisible(value, reason) end,
    SetWidgetWindowState = function(_, value, reason) return F:SetWidgetWindowState(value, reason) end,
    ParseTrackedText = function(_, text) return F:ParseTrackedText(text) end,
    ImportTrackedIds = function(_, text, category, mode) return F:ImportTrackedIds(text, category, mode) end,
    ExportAll = function() return F:ExportAll() end,
    SerializeExport = function(_, data) return F:SerializeExport(data) end,
    ParseImportText = function(_, text) return F:ParseImportText(text) end,
    ImportAll = function(_, data, mode) return F:ImportAll(data, mode) end,
}

local ok, err = Runtime:RegisterImplementation(F.Id, F)
if ok ~= true then error(err) end
