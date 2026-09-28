------------------------------------------------------------------------
-- Replicated Suite V3 - life_treasure Feature Authority
--
-- Phase 2 Step 1（2026-09-28，§24.1 固定顺序的第一步）：从 features/life/rs_life_m16_bundle.lua
-- 机械搬迁。只改变源码边界，不改业务行为：Feature ID、Store ID/Schema、UpdateTopic、Demand owner、
-- Commands、Projection shape、ApiDependencies、ObservationContractVersion/MapLocationContractVersion、
-- 悬浮窗窗口策略全部与被搬迁前逐字一致。
--
-- §24.3 红线：地图点击能力不因为文件拆分扩大 Native 权限 —— ShowWorldmapLocation 仍是唯一写类调用，
-- 首参只接受已证实 zoneGroupId；藏宝图枚举继续走 InventorySnapshotV3，不固定 bagId=0、不按名字过滤。
-- 共享装配 helper 来自 features/life/shared/rs_life_slice_factory.lua（toc.g 已保证先加载）。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P, Runtime, Demand = S.Persistence, S.FeatureRuntime, S.Demand
if type(P) ~= "table" or type(Runtime) ~= "table" or type(Demand) ~= "table" then return end
local UnitApi = rawget(_G, "X2Unit")
local LF = S.LifeSliceFactory
if type(LF) ~= "table" then error("LifeSliceFactory unavailable for life_treasure") end
local Copy, Call, Action = LF.Copy, LF.Call, LF.Action
local Number, Text = LF.Number, LF.Text
local InstallLifeWidgetContract, PublishFeatureUpdate = LF.InstallLifeWidgetContract, LF.PublishFeatureUpdate
local RegisterStore, LoadStore, PersistLifeMutation = LF.RegisterStore, LF.LoadStore, LF.PersistLifeMutation

------------------------------------------------------------------------
-- Treasure maps (shared InventorySnapshotV3 + DMS coordinates + native world-map location)
------------------------------------------------------------------------
local Treasure = { Id = "life_treasure", storeId = "v3.life.treasure", enabled = false, storeLoaded = false }
S.Features.Treasure = Treasure
Treasure.UpdateTopic = "v3.life.treasure.updated"
Treasure.ObservationContractVersion = 2 -- 中文维护注释（2026-09-16，背包 Authority 收敛）：v2 表示藏宝图枚举不再固定 bagId=0 直扫，改由 InventorySnapshotV3 选择 RU 当前可读物理背包视图；位置 500ms 刷新仍只读取玩家坐标，不重复扫描背包。
Treasure.MapLocationContractVersion = 2 -- 中文维护注释（2026-09-19，原生地图定位区域 Authority）：v2 修复旧版把 ShowWorldmapLocation 首参固定为 2 的错误假设。RU 2025-11 后签名明确要求 zoneGroupId + 全局坐标；优先使用藏宝图原生条目显式区域组，缺失时只退化到玩家当前区域组，绝不再用魔数伪造地图上下文。
Treasure.State = { selectedKey = nil, widgetVisible = false, widgetWindow = nil }
InstallLifeWidgetContract(Treasure, { defaultWidth = 390, defaultHeight = 220, minWidth = 240, minHeight = 120, defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 })
Treasure.Authority = { version = 2, revision = 0, maps = {}, selected = nil, status = "idle", error = nil, lastMapActionError = nil, mapOpenAttempts = 0, lastMapZoneGroup = nil, lastMapZoneSource = nil }
local XA = Treasure.Authority
local function NormalizeTreasureZoneGroup(value)
    -- 中文维护注释（2026-09-19，区域事实边界）：ShowWorldmapLocation 的首参是 zoneGroupId，不是 WorldId/MapContext。
    -- 这里只接受客户端已经给出的正整数事实；禁止从坐标范围、名称、当前大陆等软线索猜区域，否则地图会打开却把标记投到错误图层。
    local n = Number(value)
    if n == nil then return nil end
    n = math.floor(n)
    if n <= 0 then return nil end
    return n
end
local function Dms(dir, deg, min, sec, offset)
    deg, min, sec = Number(deg), Number(min), Number(sec); if not deg or not min or not sec then return nil end
    local value = deg + min / 60 + sec / 3600; if dir == "W" or dir == "S" then value = -value end
    return value * 1024 + offset
end
local function TreasureText(item)
    local lon, lat = Text(item.longitudeDir), Text(item.latitudeDir)
    local a, b, c = Number(item.longitudeDeg), Number(item.longitudeMin), Number(item.longitudeSec)
    local d, e, f = Number(item.latitudeDeg), Number(item.latitudeMin), Number(item.latitudeSec)
    if (lon ~= "E" and lon ~= "W") or (lat ~= "N" and lat ~= "S") or not a or not b or not c or not d or not e or not f then return nil end
    return string.format("%s %d°%d' %d\" · %s %d°%d' %d\"", lon, a, b, c, lat, d, e, f)
end
local function TreasureMapFromNativeItem(item, row, bagId)
    -- 中文维护注释（2026-09-16，跨语言藏宝图识别）：RU 客户端物品名不是中文，旧 string.find(name,"藏宝图") 会把真实藏宝图全部过滤掉。
    -- 藏宝图原生物品事实自身携带完整经纬 DMS 字段，这是本功能真正需要且与语言无关的业务证据；只有八个坐标字段均合法时才接纳，
    -- 不根据名字、Tooltip 文案或未知 category 猜测。InventorySnapshotV3 只负责“哪个物理背包槽真实存在”，业务坐标判断仍由 Treasure Authority 所有。
    if type(item) ~= "table" then return nil end
    local text = TreasureText(item)
    local worldX = Dms(item.longitudeDir, item.longitudeDeg, item.longitudeMin, item.longitudeSec, 21504)
    local worldY = Dms(item.latitudeDir, item.latitudeDeg, item.latitudeMin, item.latitudeSec, 28672)
    if text == nil or worldX == nil or worldY == nil then return nil end
    local slot = math.max(1, math.floor(Number(row and row.slot) or 1))
    local name = Text(item.name or item.itemName)
    if name == "" then name = "藏宝图 " .. tostring(slot) end -- 中文维护注释：这里只是缺名时的 Presentation fallback，不参与识别，因此不会重新引入本地化依赖。
    return {
        -- 中文维护注释（2026-09-16，旧配置兼容）：selectedKey 在旧版一直使用“坐标文本:槽位”。
        -- 虽然新版 Snapshot 能读到 itemType，也绝不能把它塞进 key，否则用户升级后已保存的当前藏宝图会失配并被静默切回第一张。
        -- itemType 仍作为事实字段保留供诊断/未来迁移使用；只有显式 schema migration 才允许改变持久身份格式。
        key = text .. ":" .. tostring(slot),
        name = name, text = text, worldX = worldX, worldY = worldY,
        -- 中文维护注释（2026-09-19，原生区域优先）：部分 RU 物品结构会直接附带 zoneGroupId/zoneGroupType。
        -- 若字段不存在则保持 nil，后续显式地图定位时再读取“当前区域组”作为有证据的 fallback；不要在背包扫描阶段调用位置 API。
        zoneGroupId = NormalizeTreasureZoneGroup(item.zoneGroupId) or NormalizeTreasureZoneGroup(item.zoneGroupType) or NormalizeTreasureZoneGroup(item.zoneGroup),
        slot = slot, bagId = Number(bagId), itemType = Number(row and row.itemType), direction = "--", distance = nil,
    }
end
function XA:Refresh()
    -- 中文维护注释（2026-09-16，共享背包事实）：Treasure 不再直接循环 X2Bag。显式刷新/Consumer 首次进入时只构建一次 bounded Snapshot，
    -- 由 InventorySnapshotV3 统一处理 bagId=1/0 RU 差异；随后只对 Snapshot 已确认占用的槽做一次原生详情读取以取得坐标字段。
    -- 该二阶段读取不在 500ms 位置任务内执行，因此不会把背包扫描带入高频路径，也不会复制第二份 Inventory Authority。
    local snapshotService = S.Services and S.Services.InventorySnapshotV3 or nil
    if type(snapshotService) ~= "table" or type(snapshotService.BuildSnapshot) ~= "function" or type(snapshotService.ReadPhysicalBagSlot) ~= "function" then
        self.status, self.error = "unavailable", "InventorySnapshotV3 不可用"
        self.revision = self.revision + 1
        PublishFeatureUpdate(Treasure, self.revision, "treasure_inventory_unavailable")
        return false
    end
    local snapshot, snapshotErr = snapshotService:BuildSnapshot("bag", { maxSlots = 240 })
    if type(snapshot) ~= "table" then
        self.status, self.error = "unavailable", "背包快照不可用：" .. tostring(snapshotErr or "unknown")
        self.revision = self.revision + 1
        PublishFeatureUpdate(Treasure, self.revision, "treasure_inventory_failed")
        return false
    end

    local maps = {}
    for _, row in ipairs(type(snapshot.rows) == "table" and snapshot.rows or {}) do
        local readOk, item, _, physicalBagId = snapshotService:ReadPhysicalBagSlot(row.slot, snapshot.bagId)
        if readOk == true and type(item) == "table" and next(item) ~= nil then
            local map = TreasureMapFromNativeItem(item, row, physicalBagId or snapshot.bagId)
            if map ~= nil then maps[#maps + 1] = map end
        end
    end

    local selected = Treasure.State.selectedKey
    local selectedMap = nil
    for _, map in ipairs(maps) do
        if map.key == selected then selectedMap = map; break end
    end
    if selectedMap == nil then
        selectedMap = maps[1]
        selected = selectedMap and selectedMap.key or nil
        Treasure.State.selectedKey = selected
    end
    self.maps, self.selected = maps, selectedMap
    self.inventoryBagId = snapshot.bagId
    self.inventoryFallbackUsed = snapshot.fallbackUsed == true
    self.status, self.error = (#maps > 0 and "ready" or "empty"), nil
    self.revision = self.revision + 1
    PublishFeatureUpdate(Treasure, self.revision, "treasure_scan")
    return true
end
function XA:UpdatePosition()
    local map = self.selected; if not map then return false end
    if S.Api:IsCapabilityAllowed("X2Unit:GetUnitWorldPositionByTarget") ~= true then self.error = "X2Unit:GetUnitWorldPositionByTarget 未在当前 RU 能力面证明"; return false end
    local ok, x, _, y = Call("X2Unit:GetUnitWorldPositionByTarget", UnitApi, "GetUnitWorldPositionByTarget", "player", false)
    x, y = ok and Number(x) or nil, ok and Number(y) or nil; if not x or not y then return false end
    local dx, dy = map.worldX - x, map.worldY - y
    map.distance = math.sqrt(dx * dx + dy * dy)
    map.direction = math.abs(dx) >= math.abs(dy) and (dx >= 0 and "东" or "西") or (dy >= 0 and "北" or "南")
    self.revision = self.revision + 1
    PublishFeatureUpdate(Treasure, self.revision, "treasure_position")
    return true
end
function XA:GetProjection()
    return {
        revision = self.revision, maps = Copy(self.maps), selected = Copy(self.selected), status = self.status, error = self.error,
        observationContractVersion = Treasure.ObservationContractVersion, mapLocationContractVersion = Treasure.MapLocationContractVersion,
        inventoryBagId = self.inventoryBagId, inventoryFallbackUsed = self.inventoryFallbackUsed == true,
        lastMapActionError = self.lastMapActionError, mapOpenAttempts = self.mapOpenAttempts,
        lastMapZoneGroup = self.lastMapZoneGroup, lastMapZoneSource = self.lastMapZoneSource,
    }
end
local function NormalizeTreasureState(value)
    value = type(value) == "table" and value or {}
    return {
        selectedKey = value.selectedKey ~= nil and tostring(value.selectedKey) or nil,
        widgetVisible = value.widgetVisible == true,
        widgetWindow = type(value.widgetWindow) == "table" and Copy(value.widgetWindow) or nil,
    }
end
RegisterStore(Treasure.storeId, "v3.life.treasure", function() return NormalizeTreasureState(nil) end, function() return Copy(Treasure.State) end, function(value)
    value = type(value) == "table" and value or {}
    Treasure.State.selectedKey = value.selectedKey
    Treasure.State.widgetVisible = value.widgetVisible == true
    Treasure.State.widgetWindow = type(value.widgetWindow) == "table" and Copy(value.widgetWindow) or nil
end, NormalizeTreasureState)
Treasure.ApiDependencies = { "X2Bag:GetBagItemInfo", "X2Bag:Capacity", "X2Unit:GetUnitWorldPositionByTarget", "X2Unit:GetCurrentZoneGroup", "X2Map:ShowWorldmapLocation" } -- 中文维护注释：地图 API 与当前区域读取都只在显式 Command 点击时执行；加入依赖仅确保 FeatureRuntime 惰性导入对应 namespace，不启动任何地图观察。
function Treasure:Initialize() return LoadStore(self) end
local TREASURE_POSITION_TASK = "v3_life_treasure_position"
function Treasure:ReconcileDemand(_, before, after)
    local beforeCount = tonumber(before and before.count) or 0
    local afterCount = tonumber(after and after.count) or 0
    if beforeCount <= 0 and afterCount > 0 then
        XA:Refresh(); XA:UpdatePosition()
        if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then return false, "寻宝位置刷新 Scheduler 不可用" end
        local added = S.Scheduler:AddTask(TREASURE_POSITION_TASK, 500, function()
            if Treasure.enabled == true and (tonumber(Treasure.consumerCount) or 0) > 0 then XA:UpdatePosition() end
        end, false, Treasure, "P3", 1)
        if added ~= true then return false, "寻宝位置刷新任务创建失败" end
        if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(TREASURE_POSITION_TASK, Treasure.Id, false) end
    elseif beforeCount > 0 and afterCount <= 0 and S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then
        S.Scheduler:RemoveTask(TREASURE_POSITION_TASK)
    end
    return true
end
function Treasure:Enable() self.enabled = true; return true end
function Treasure:Disable(reason) local ok, err = self.Demand:Clear(reason or "treasure_disable"); if ok ~= true then return false, err end; if S.Scheduler and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(TREASURE_POSITION_TASK) end; self.enabled = false; return true end
function Treasure:AcquireConsumer(token) if not self.enabled then return false, "寻宝功能已关闭" end return self.Demand:Acquire(token, {}, "treasure_consumer") end
function Treasure:ReleaseConsumer(token) return self.Demand:Release(token, "treasure_consumer") end
function Treasure:Refresh() if not self.enabled or self.consumerCount <= 0 then return true end; XA:Refresh(); XA:UpdatePosition(); return true end
function Treasure:GetProjection() return XA:GetProjection() end
function Treasure:Select(key)
    for _, map in ipairs(XA.maps or {}) do
        if map.key == key then
            local persisted, persistErr = PersistLifeMutation(self, "treasure_select", function(state) state.selectedKey = key; return true end)
            if persisted ~= true then return false, persistErr end
            XA.selected = map; XA:UpdatePosition(); return true
        end
    end
    return false, "藏宝图选择无效"
end
local function ResolveTreasureMapZoneGroup(map)
    -- 中文维护注释（2026-09-19，地图定位证据链）：参考 TreasureMapHunter 的真实调用是 targetZone + global x/y，
    -- 因此先信藏宝图条目自己的 zoneGroup；没有时只允许用玩家当前 zoneGroup。后者只能保证“玩家已进入藏宝图所在区域”时精确定位，
    -- 但至少不会像旧魔数 2 那样打开地图却静默落到错误区域。跨区域一键定位若要完全可靠，后续必须补结构化 Treasure Location DB，不能猜。
    local explicit = type(map) == "table" and NormalizeTreasureZoneGroup(map.zoneGroupId) or nil
    if explicit ~= nil then return explicit, "item" end
    local ok, currentZone, err = Call("X2Unit:GetCurrentZoneGroup", UnitApi, "GetCurrentZoneGroup")
    local zone = ok == true and NormalizeTreasureZoneGroup(currentZone) or nil
    if zone ~= nil then return zone, "current_zone" end
    return nil, tostring(err or "藏宝图未提供区域组，且当前区域组不可用")
end
function Treasure:ShowSelectedOnMap()
    -- 中文维护注释（2026-09-16，Native 写边界）：地图打开属于显式用户动作，只能从 Command 进入并经 Capability Gate；
    -- Scheduler/UpdatePosition 永远不能调用它。失败只记录诊断并保留当前选择/距离追踪，不清 Store、不切换藏宝图，避免 UI 能力故障污染 Domain Authority。
    local map = XA.selected
    if type(map) ~= "table" then return false, "请先选择一张藏宝图" end
    local worldX, worldY = Number(map.worldX), Number(map.worldY)
    if worldX == nil or worldY == nil then return false, "藏宝图坐标不可用" end
    local zoneGroupId, zoneSourceOrErr = ResolveTreasureMapZoneGroup(map)
    if zoneGroupId == nil then
        XA.lastMapActionError = "地图定位缺少区域组：" .. tostring(zoneSourceOrErr or "unknown")
        XA.lastMapZoneGroup, XA.lastMapZoneSource = nil, "unresolved"
        XA.revision = XA.revision + 1
        PublishFeatureUpdate(self, XA.revision, "treasure_map_zone_unresolved")
        return false, XA.lastMapActionError
    end
    XA.mapOpenAttempts = (tonumber(XA.mapOpenAttempts) or 0) + 1
    XA.lastMapZoneGroup, XA.lastMapZoneSource = zoneGroupId, tostring(zoneSourceOrErr or "unknown")
    local ok, mapErr = Action("X2Map:ShowWorldmapLocation", nil, "ShowWorldmapLocation", zoneGroupId, worldX, worldY, 0)
    if ok ~= true then
        XA.lastMapActionError = tostring(mapErr or "地图定位失败")
        XA.revision = XA.revision + 1
        PublishFeatureUpdate(self, XA.revision, "treasure_map_failed")
        return false, XA.lastMapActionError
    end
    XA.lastMapActionError = nil
    XA.revision = XA.revision + 1
    PublishFeatureUpdate(self, XA.revision, "treasure_map_opened")
    return true
end
Treasure.Commands = {
    Refresh = function(_, reason) return Treasure:Refresh(reason) end,
    Select = function(_, key) return Treasure:Select(key) end,
    ShowSelectedOnMap = function() return Treasure:ShowSelectedOnMap() end, -- 中文维护注释：Presentation 只调用 Feature Command，不直接触碰 X2Map；主页面与悬浮窗因此共享同一选择和失败诊断。
    GetWidgetVisible = function() return Treasure:GetWidgetVisible() end, SetWidgetVisible = function(_, value, reason) return Treasure:SetWidgetVisible(value, reason) end,
    SetWidgetWindowState = function(_, value, reason) return Treasure:SetWidgetWindowState(value, reason) end, MarkStoreDirty = function(_, delayMs, reason) return Treasure:MarkStoreDirty(delayMs, reason) end,
}
local treasureDemand, treasureErr = Demand:Create({ id = "feature:" .. Treasure.Id, owner = Treasure, projectionOwner = Treasure, projectionConsumersField = "consumers", projectionCountField = "consumerCount", reconcile = function(lease, before, after) return Treasure:ReconcileDemand(lease, before, after) end })
if treasureDemand == nil then error(treasureErr) end
Treasure.Demand = treasureDemand
ok, err = Runtime:RegisterImplementation(Treasure.Id, Treasure); if ok ~= true then error(err) end
