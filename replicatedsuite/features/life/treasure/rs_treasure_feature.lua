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
-- 中文维护（2026-10-09）：罗盘帧单独通知 Presenter，禁止让 30Hz 镜头更新重建生活列表或写入存档。
Treasure.CompassTopic = "v3.life.treasure.compass"
Treasure.ObservationContractVersion = 2 -- 中文维护：藏宝图仍由 InventorySnapshotV3 选择物理背包；2026-10-09 加入 500ms 选中槽核对、3 秒有限补采，罗盘帧不扫描背包。
Treasure.MapLocationContractVersion = 2 -- 中文维护注释（2026-09-19，原生地图定位区域 Authority）：v2 修复旧版把 ShowWorldmapLocation 首参固定为 2 的错误假设。RU 2025-11 后签名明确要求 zoneGroupId + 全局坐标；优先使用藏宝图原生条目显式区域组，缺失时只退化到玩家当前区域组，绝不再用魔数伪造地图上下文。
Treasure.State = { selectedKey = nil, widgetVisible = false, widgetWindow = nil }
InstallLifeWidgetContract(Treasure, { defaultWidth = 390, defaultHeight = 220, minWidth = 240, minHeight = 120, defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 })
Treasure.Authority = { version = 2, revision = 0, maps = {}, selected = nil, status = "idle", error = nil, lastMapActionError = nil, mapOpenAttempts = 0, lastMapZoneGroup = nil, lastMapZoneSource = nil }
local XA = Treasure.Authority
XA.compass = { points = {}, status = "idle" } -- 中文维护：纯会话屏幕快照；当前目标仍唯一归属 selected。
local function ClearCompass(reason)
    -- 中文维护：没有目标时高频任务不重复分配空帧或写 Native 可见性；状态改变仍同步通知隐藏。
    local status = tostring(reason or "idle")
    if type(XA.compass) == "table" and XA.compass.status == status and #XA.compass.points == 0 then return end
    XA.compass = { points = {}, status = status }
    if S.Events and type(S.Events.Publish) == "function" then S.Events:Publish(Treasure.CompassTopic) end
end
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
    -- 中文维护（2026-10-09）：整包扫描只在首次需求、显式刷新、目标变更或 3 秒补采时运行；失败也记录时间，避免空背包每帧重扫。
    self.lastInventoryScanAt = S.NowMs and S.NowMs() or 0
    -- 中文维护注释（2026-09-16，共享背包事实）：Treasure 不再直接循环 X2Bag。显式刷新/Consumer 首次进入时只构建一次 bounded Snapshot，
    -- 由 InventorySnapshotV3 统一处理 bagId=1/0 RU 差异；随后只对 Snapshot 已确认占用的槽做一次原生详情读取以取得坐标字段。
    -- 该二阶段读取不在 500ms 位置任务内执行，因此不会把背包扫描带入高频路径，也不会复制第二份 Inventory Authority。
    local snapshotService = S.Services and S.Services.InventorySnapshotV3 or nil
    if type(snapshotService) ~= "table" or type(snapshotService.BuildSnapshot) ~= "function" or type(snapshotService.ReadSlot) ~= "function" then
        self.status, self.error = "unavailable", "InventorySnapshotV3 不可用"
        ClearCompass("unavailable") -- 中文维护：读取未知时停止旧方向指引，不把未知伪装成空背包。
        self.revision = self.revision + 1
        PublishFeatureUpdate(Treasure, self.revision, "treasure_inventory_unavailable")
        return false
    end
    -- 中文维护：首轮共享服务选择可读物理背包，此后本次需求会话锁定同一视图；成功空槽不能触发兼容回退。
    local snapshot, snapshotErr = snapshotService:BuildSnapshot("bag", { maxSlots = 240, bagId = self.inventoryBagId, allowBagFallback = self.inventoryBagId == nil })
    if type(snapshot) ~= "table" or (tonumber(snapshot.readErrors) or 0) > 0 then
        self.status, self.error = "unavailable", "背包快照不可用：" .. tostring(snapshotErr or "unknown")
        ClearCompass("unavailable") -- 中文维护：部分读取失败不能证明最后一张图已消失，保留最后已知列表并显式降级。
        self.revision = self.revision + 1
        PublishFeatureUpdate(Treasure, self.revision, "treasure_inventory_failed")
        return false
    end

    local maps = {}
    for _, row in ipairs(type(snapshot.rows) == "table" and snapshot.rows or {}) do
        -- 中文维护：详情必须与快照同源；不使用会在空槽切视图的 ReadPhysicalBagSlot，避免扫描后消耗/排序竞态复活旧图。
        local readOk, item = snapshotService:ReadSlot("bag", row.slot, snapshot.bagId)
        if readOk == true and type(item) == "table" and next(item) ~= nil then
            local map = TreasureMapFromNativeItem(item, row, snapshot.bagId)
            if map ~= nil then maps[#maps + 1] = map end
        elseif readOk ~= true then
            -- 中文维护：第二阶段详情读取也可能失败；禁止把缺失的坐标详情当作物品已消耗。
            self.status, self.error = "unavailable", "藏宝图详情读取失败"
            ClearCompass("unavailable")
            self.revision = self.revision + 1
            PublishFeatureUpdate(Treasure, self.revision, "treasure_detail_failed")
            return false
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
    if selectedMap == nil then ClearCompass("empty") end -- 中文维护：最后一张图消耗后同轮清列表、选择与世界指引。
    self.revision = self.revision + 1
    PublishFeatureUpdate(Treasure, self.revision, "treasure_scan")
    return true
end
function XA:CheckInventory()
    -- 中文维护（2026-10-09）：500ms 只核对选中图的真实 bagId/slot；空槽不尝试另一背包视图，防止已消耗图被同槽旧视图复活。
    -- 切槽/排序/消耗时重新取共享快照，3 秒整包补采用于发现新增图和非选中图变化；罗盘热路径永远不扫包。
    local now = S.NowMs and S.NowMs() or 0
    if now - (self.lastInventoryScanAt or 0) >= 3000 then return self:Refresh() end
    local map = self.selected
    if map == nil then return true end
    local inventory = S.Services and S.Services.InventorySnapshotV3
    if type(inventory) ~= "table" or type(inventory.ReadSlot) ~= "function" then return self:Refresh() end
    local ok, item, err = inventory:ReadSlot("bag", map.slot, map.bagId)
    if ok ~= true then
        self.status, self.error = "unavailable", "藏宝图槽位读取失败：" .. tostring(err or "unknown")
        ClearCompass("unavailable")
        self.revision = self.revision + 1
        PublishFeatureUpdate(Treasure, self.revision, "treasure_slot_failed")
        return false
    end
    local current = TreasureMapFromNativeItem(item, map, map.bagId)
    if current == nil or current.key ~= map.key then
        self.selected = nil -- 中文维护：已证实旧定位槽失效，先停旧箭头；重扫后再选择仍存在的藏宝图。
        ClearCompass("selection_changed")
        return self:Refresh()
    end
    if self.status ~= "ready" then return self:Refresh() end -- 中文维护：读取恢复后重新核对列表，不能一直挂 unavailable。
    return true
end
function XA:UpdateCompass()
    -- 中文维护（2026-10-09）：参考 GroundCompass 的坐标分离规则：藏宝图减 world(false)，相机只投影 local(true)。
    -- 这里只把世界差向量平移到玩家局部基准；不拿全局藏宝坐标直接与局部相机位置相减。
    local map = self.selected
    local projection = S.Services and S.Services.ScreenProjectionV3
    if map == nil or self.status ~= "ready" then ClearCompass(self.status); return false end
    if type(projection) ~= "table" or type(projection.GetUnitWorldPosition) ~= "function" or type(projection.ProjectWorldBatch) ~= "function" then
        ClearCompass("projection_unavailable"); return false
    end
    local wx, wy = projection:GetUnitWorldPosition("player", false)
    local px, py, pz = projection:GetUnitWorldPosition("player", true)
    if wx == nil or wy == nil or px == nil or py == nil or pz == nil then ClearCompass("position_unavailable"); return false end
    local dx, dy = map.worldX - wx, map.worldY - wy
    local distance = math.sqrt(dx * dx + dy * dy)
    local radius, points = 4, self.compassWorldPoints or {}
    self.compassWorldPoints = points -- 中文维护：固定最多 96 点的会话工作区，重复更新复用表，不增长 Native 控件或 Drawable 层。
    local used = 0
    local function Point(x, y)
        used = used + 1
        local point = points[used] or {}; points[used] = point
        point.x, point.y, point.z = px + x, py + y, pz + 0.25
    end
    for i = 1, 64 do
        local a = (i - 1) * math.pi * 2 / 64
        Point(math.cos(a) * radius, math.sin(a) * radius)
    end
    if distance > 0.01 then
        local ux, uy, tip = dx / distance, dy / distance, radius * 0.9
        for i = 1, 16 do Point(ux * tip * i / 16, uy * tip * i / 16) end
        for side = -1, 1, 2 do
            for i = 1, 8 do
                local back = i * radius * 0.22 / 8
                Point(ux * (tip - back) - uy * back * side, uy * (tip - back) + ux * back * side)
            end
        end
    end
    for i = #points, used + 1, -1 do points[i] = nil end
    -- 中文维护：圆环与箭头使用同一帧刚性投影，深度/镜头/FOV 失败由共享服务否决；不自行猜投影或放大 UI scale。
    local screen, source = projection:ProjectWorldBatch(points, {
        easyPullCompat = true, rigidBatch = true, stabilizeAnchor = true, aspectSafeCamera = true,
        anchorUnit = "player", anchorWorld = { x = px, y = py, z = pz + 0.25 },
    })
    self.compass = { points = screen or {}, status = source or "unavailable", near = distance <= radius }
    if S.Events and type(S.Events.Publish) == "function" then S.Events:Publish(Treasure.CompassTopic) end
    return true
end
function XA:UpdatePosition()
    local map = self.selected; if not map or self.status ~= "ready" then return false end -- 中文维护：未知背包不继续更新旧图指引。
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
Treasure.ApiDependencies = { "X2Bag:GetBagItemInfo", "X2Bag:Capacity", "X2Unit:GetUnitWorldPositionByTarget", "X2Unit:GetUnitScreenPosition", "X2Unit:GetCurrentZoneGroup", "X2Map:ShowWorldmapLocation" } -- 中文维护（2026-10-09）：UnitScreen 供共享投影锚定；地图写入/区域读取仍仅在显式 Command 执行，不由罗盘自动打开地图。
function Treasure:Initialize() return LoadStore(self) end
local TREASURE_POSITION_TASK = "v3_life_treasure_position"
local TREASURE_COMPASS_TASK = "v3_life_treasure_compass" -- 中文维护：30Hz 只更新轻量世界引导；最后一个 Consumer 释放两条任务。
function Treasure:ReconcileDemand(_, before, after)
    local beforeCount = tonumber(before and before.count) or 0
    local afterCount = tonumber(after and after.count) or 0
    if beforeCount <= 0 and afterCount > 0 then
        XA.inventoryBagId = nil -- 中文维护：新需求会话重新确认可读背包；会话内才锁定，不能把上次客户端上下文带入下一次。
        XA:Refresh(); XA:UpdatePosition()
        if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" or type(S.Scheduler.AddHighFrequencyTask) ~= "function" then return false, "寻宝刷新 Scheduler 不可用" end
        local added = S.Scheduler:AddTask(TREASURE_POSITION_TASK, 500, function()
            if Treasure.enabled == true and (tonumber(Treasure.consumerCount) or 0) > 0 then XA:CheckInventory(); XA:UpdatePosition() end
        end, false, Treasure, "P3", 1)
        if added ~= true then return false, "寻宝位置刷新任务创建失败" end
        if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(TREASURE_POSITION_TASK, Treasure.Id, false) end
        -- 中文维护：Scheduler/Demand 是唯一生命周期入口；Presenter 只订阅帧，不自建常驻轮询或第二份选择。
        local compassAdded = S.Scheduler:AddHighFrequencyTask(TREASURE_COMPASS_TASK, 33, function()
            if Treasure.enabled == true and (tonumber(Treasure.consumerCount) or 0) > 0 then XA:UpdateCompass() end
        end, false, Treasure, "P2", 1)
        if compassAdded ~= true then S.Scheduler:RemoveTask(TREASURE_POSITION_TASK); return false, "寻宝罗盘任务创建失败" end
        if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(TREASURE_COMPASS_TASK, Treasure.Id, false) end
    elseif beforeCount > 0 and afterCount <= 0 and S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then
        S.Scheduler:RemoveTask(TREASURE_POSITION_TASK)
        S.Scheduler:RemoveTask(TREASURE_COMPASS_TASK)
        self.Authority.compassWorldPoints = nil; ClearCompass("inactive") -- 中文维护：关闭后马上隐藏点池并释放几何工作区。
    end
    return true
end
function Treasure:Enable() self.enabled = true; return true end
function Treasure:Disable(reason)
    -- 中文维护：停用即使 Demand 已为空，也要幂等撤销两条任务及所有世界标记，不能残留指向旧藏宝图的箭头。
    local ok, err = self.Demand:Clear(reason or "treasure_disable"); if ok ~= true then return false, err end
    if S.Scheduler and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(TREASURE_POSITION_TASK); S.Scheduler:RemoveTask(TREASURE_COMPASS_TASK) end
    self.enabled = false; XA.compassWorldPoints = nil; ClearCompass("disabled"); return true
end
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
