------------------------------------------------------------------------
-- Replicated Suite · 藏宝图助手功能入口
-- 作者：Replicated
-- QQ群：1104129461
--
-- 独立源码单元保留Feature ID、Store ID/Schema、UpdateTopic、Demand所有者、Commands、Projection、ApiDependencies、ObservationContractVersion/MapLocationContractVersion及浮窗策略契约。
-- 地图点击唯一写调用为ShowWorldmapLocation，首参只接受核实zoneGroupId；藏宝图枚举走InventorySnapshotV3，禁止固定bagId=0或按名称过滤。
-- 共享装配来自features/life/shared/rs_life_slice_factory.lua，由toc.g保证先加载。
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

-- 藏宝图：共享 InventorySnapshotV3、DMS 坐标与原生世界地图定位。
local Treasure = { Id = "life_treasure", storeId = "v3.life.treasure", enabled = false, storeLoaded = false }
local TREASURE_MAP_REQUEST_TASK = "v3_life_treasure_map_request" -- 仅显式地图请求的一次性冷却等待，不是新的扫描/重试循环。
local SEA_TRACKING_TOKEN = "tracking:treasure_sea" -- 用户开始追踪后持有现有任务；地图关闭不结束导航，停止/切回宝图/停用时释放。
S.Features.Treasure = Treasure
Treasure.UpdateTopic = "v3.life.treasure.updated"
-- 罗盘帧单独通知 Presenter，禁止让 30Hz 镜头更新重建生活列表或写入存档。
Treasure.CompassTopic = "v3.life.treasure.compass"
Treasure.CompassDisplayContractVersion = 2
-- GroundCompass v2.4 的显示语义：米制地面圈、四正方位、金色寻宝箭头、进圈变金并收箭。
-- 属于显示参数而非第二份寻宝状态，不改变选择/历史配置的 canonical。
Treasure.CompassStyle = { radius = 2.5, groundLift = 1.6, maxDistance = 60000,
    ringSegments = 120, maxPoints = 316, labelSize = 12, labelOut = 1.16, reachedDistance = 10 }
Treasure.ObservationContractVersion = 2 -- 藏宝图仍由 InventorySnapshotV3 选择物理背包；2026-10-09 加入 500ms 选中槽核对、3 秒有限补采，罗盘帧不扫描背包。
Treasure.MapLocationContractVersion = 2 -- v2 修复旧版把 ShowWorldmapLocation 首参固定为 2 的错误假设。RU 2025-11 后签名明确要求 zoneGroupId + 全局坐标；优先使用藏宝图原生条目显式区域组，缺失时只退化到玩家当前区域组，绝不再用魔数伪造地图上下文。
Treasure.State = { selectedKey = nil, widgetVisible = false, widgetWindow = nil }
InstallLifeWidgetContract(Treasure, { defaultWidth = 390, defaultHeight = 220, minWidth = 240, minHeight = 120, defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 })
Treasure.Authority = { version = 2, revision = 0, maps = {}, selected = nil, status = "idle", error = nil, lastMapActionError = nil, mapOpenAttempts = 0, lastMapZoneGroup = nil, lastMapZoneSource = nil }
local XA = Treasure.Authority
local Sea = S.TreasureSeaCatalog
Treasure.SeaPointsContractVersion = 2 -- 原包区域组 + 原生地图小箭头；不再创建独立点位地图。
Treasure.SeaRoundPersistenceContractVersion = 1
Treasure.ShipTimerContractVersion = 1 -- 用户显式搜查时间；没有静态点位的服务器刷新队列接口。
XA.viewKind, XA.regions, XA.seaRows, XA.visited, XA.visitUndo = "maps", {}, {}, {}, {}
XA.shipSearches = {}
local function IsSea(point) return type(point)=="table" and (point.kind=="seabugs" or point.kind=="ships") end
-- 一组海域只写一次身份，点号用 s/k 表示搜查/跳过；504点仍是几KiB，不把几百个表键送进Native序列化。
-- 稳定身份来自目录的 kind/region/number，不能用会随距离排序改变的列表下标。
local function EncodeSeaVisits(visited)
    local groups, keys, parts = {}, {}, {}
    for key, mark in pairs(visited) do
        local kind, region, number = key:match("^([^:]+):([^:]+):(%d+)$")
        if (kind=="seabugs" or kind=="ships") and (mark=="searched" or mark=="skipped") then
            local group=kind..":"..region
            if not groups[group] then groups[group]={};keys[#keys+1]=group end
            groups[group][#groups[group]+1]={number=tonumber(number),mark=mark=="searched" and "s" or "k"}
        end
    end
    table.sort(keys)
    for _,group in ipairs(keys) do
        table.sort(groups[group],function(a,b)return a.number<b.number end)
        local tokens={};for _,point in ipairs(groups[group])do tokens[#tokens+1]=point.number..point.mark end
        parts[#parts+1]=group.."="..table.concat(tokens,",")
    end
    return table.concat(parts,";")
end
local function DecodeSeaVisits(text)
    local visited={}
    for group,tokens in tostring(text or ""):gmatch("([^;=]+)=([^;=]+)") do
        for token in tokens:gmatch("[^,]+") do
            local number,mark=token:match("^(%d+)([sk])$")
            local key=number and (group..":"..number) or nil
            if key and Sea and Sea:Get(key) then visited[key]=mark=="s" and "searched" or "skipped" end
        end
    end
    return visited
end
local function NormalizeSeaRound(value)
    if type(value)~="table" then return nil end -- 旧档不补字段，保留原有canonical指纹。
    local regions={};for _,kind in ipairs({"seabugs","ships"}) do
        if type(value.regions)=="table" and type(value.regions[kind])=="string" then regions[kind]=value.regions[kind] end
    end
    return {viewKind=(value.viewKind=="seabugs" or value.viewKind=="ships") and value.viewKind or "maps",
        regions=regions,visits=type(value.visits)=="string" and value.visits or ""}
end
-- 分钟自2000-01-01起算，跨重载/离线保持同一时间轴；不用会重置的NowMs写存档。
local function DateSerial(y,m,d)
    if m<=2 then y,m=y-1,m+12 end
    return 365*y+math.floor(y/4)-math.floor(y/100)+math.floor(y/400)+math.floor((153*(m-3)+2)/5)+d
end
local function ServerMinute()
    local ok,t=pcall(function()return S.Utils.GetServerTime()end)
    if not ok or type(t)~="table" then return nil end
    local y,m,d,h,n=tonumber(t.year),tonumber(t.month),tonumber(t.day),tonumber(t.hour),tonumber(t.minute or t.min)
    local function Valid(v,a,b)return v and v>=a and v<=b and v==math.floor(v)end
    if not Valid(y,2000,2100) or not Valid(m,1,12) or not Valid(d,1,31) or not Valid(h,0,23) or not Valid(n,0,59) then return nil end
    local leap=y%4==0 and (y%100~=0 or y%400==0)
    if d>({31,leap and 29 or 28,31,30,31,30,31,31,30,31,30,31})[m] then return nil end
    return (DateSerial(y,m,d)-DateSerial(2000,1,1))*1440+h*60+n
end
local function EncodeShipSearches(searches)
    local groups,keys,parts={},{},{}
    for key,stamp in pairs(searches)do
        local group,number=key:match("^(ships:[^:]+):(%d+)$")
        if group and Sea and Sea:Get(key) and type(stamp)=="number" and stamp>=0 and stamp<=53123039 and stamp==math.floor(stamp) then
            if not groups[group]then groups[group]={};keys[#keys+1]=group end
            groups[group][#groups[group]+1]={number=tonumber(number),stamp=stamp}
        end
    end
    table.sort(keys)
    for _,group in ipairs(keys)do
        table.sort(groups[group],function(a,b)return a.number<b.number end)
        local tokens={};for _,p in ipairs(groups[group])do tokens[#tokens+1]=p.number.."@"..p.stamp end
        parts[#parts+1]=group.."="..table.concat(tokens,",")
    end
    return table.concat(parts,";")
end
local function DecodeShipSearches(text)
    local searches={}
    for group,tokens in tostring(text or ""):gmatch("([^;=]+)=([^;=]+)")do
        for token in tokens:gmatch("[^,]+")do
            local number,stamp=token:match("^(%d+)@(%d+)$")
            local key=number and (group..":"..number);stamp=tonumber(stamp)
            if key and key:match("^ships:") and Sea and Sea:Get(key) and stamp and stamp<=53123039 then searches[key]=stamp end
        end
    end
    return searches
end
local function NormalizeShipTimers(value)
    if type(value)~="table" then return nil end -- 不改旧存档canonical。
    return {searches=type(value.searches)=="string" and value.searches or "",
        intervalMinutes=math.max(0,math.min(10080,math.floor(tonumber(value.intervalMinutes) or 0)))}
end
local function ShipTimer(point)
    if not point or point.kind~="ships" then return nil end
    local stamp=XA.shipSearches[point.key]
    if not stamp then
        if XA.visited[point.key]=="searched" then return "unknown","搜查时间未知" end
        return nil
    end
    local now=XA.shipNowMinute
    if not now or now<stamp then return "unknown","时间不可用" end
    local elapsed=now-stamp
    local interval=Treasure.State.shipTimers and Treasure.State.shipTimers.intervalMinutes or 0
    local function Duration(minutes)
        if minutes<60 then return minutes.."分" end
        return math.floor(minutes/60).."时"..(minutes%60>0 and (minutes%60).."分" or "")
    end
    if interval<=0 then return "elapsed","已过 "..Duration(elapsed),nil,elapsed end
    if elapsed>=interval then return "due","可复查（预估）",0,elapsed end
    return "estimated","估余 "..Duration(interval-elapsed),interval-elapsed,elapsed
end
local function DecorateSeaRow(row)
    row.visitStatus=XA.visited[row.key]
    row.visitText=row.visitStatus=="searched" and "本轮已搜查" or row.visitStatus=="skipped" and "本轮已跳过" or "未搜查"
    row.timerStatus,row.timerText,row.remainingMinutes,row.elapsedMinutes=ShipTimer(row)
end
function XA:UpdateShipClock(force)
    if self.viewKind~="ships" then return false end
    local ms=S.NowMs and S.NowMs() or 0
    if not force and self.shipClockSampleAt and ms>=self.shipClockSampleAt and ms-self.shipClockSampleAt<5000 then return false end
    self.shipClockSampleAt=ms -- 失败也限频；500ms现有观察任务中采样，33ms罗盘不读取时间。
    local now=ServerMinute()
    if now~=self.shipClockRaw then self.shipClockAdvancedAt=ms;self.shipClockRaw=now end
    if now and self.shipClockAdvancedAt and ms-self.shipClockAdvancedAt>120000 then now=nil end
    local changed=self.shipNowMinute~=now;self.shipNowMinute=now
    if changed or force then
        for _,row in ipairs(self.seaRows)do DecorateSeaRow(row)end
        if IsSea(self.selected)then DecorateSeaRow(self.selected)end
    end
    return changed
end
local function PersistSeaRound(visited,kind,regions,reason,shipSearches)
    if type(P.MutateStore)~="function" then return false,"搜查进度存档事务不可用" end
    local round={viewKind=kind or XA.viewKind,regions=Copy(regions or XA.regions),visits=EncodeSeaVisits(visited)}
    -- 只在用户操作边沿同步保存回读，成功后才切换目标/提交内存标记；重载与退出无需等待debounce。
    return P:MutateStore(Treasure.storeId,function()
        Treasure.State.seaRound=round
        if shipSearches then Treasure.State.shipTimers={searches=EncodeShipSearches(shipSearches),
            intervalMinutes=Treasure.State.shipTimers and Treasure.State.shipTimers.intervalMinutes or 0}end
        return true end,
        {durable=true,reason=reason})
end
XA.compass = { points = {}, status = "idle" } -- 纯会话屏幕快照；当前目标仍唯一归属 selected。
local function ClearCompass(reason)
    -- 没有目标时高频任务不重复分配空帧或写 Native 可见性；状态改变仍同步通知隐藏。
    local status = tostring(reason or "idle")
    if type(XA.compass) == "table" and XA.compass.status == status and #XA.compass.points == 0 then return end
    XA.compass = { points = {}, status = status }
    if S.Events and type(S.Events.Publish) == "function" then S.Events:Publish(Treasure.CompassTopic) end
end
local function Changed(reason)
    XA.revision=XA.revision+1
    PublishFeatureUpdate(Treasure,XA.revision,reason)
end
local function ReadPlayerPosition()
    local ok,x,_,y=Call("X2Unit:GetUnitWorldPositionByTarget",UnitApi,"GetUnitWorldPositionByTarget","player",false)
    x,y=Number(x),Number(y)
    if ok~=true or not x or not y or x~=x or y~=y or math.abs(x)==math.huge or math.abs(y)==math.huge then return nil,nil end
    return x,y
end
local function Distance(point,x,y)
    if x==nil or y==nil then point.distance,point.direction=nil,"--";return end
    local dx,dy=point.worldX-x,point.worldY-y
    point.distance=math.sqrt(dx*dx+dy*dy)
    point.direction=math.abs(dx)>=math.abs(dy) and (dx>=0 and "东" or "西") or (dy>=0 and "北" or "南")
end
function XA:RebuildSeaRows(reorder)
    if not Sea or self.viewKind=="maps" then return end
    self:UpdateShipClock(false)
    self.seaRows=Sea:List(self.viewKind,self.regions[self.viewKind] or "all")
    for _,row in ipairs(self.seaRows) do
        Distance(row,self.playerX,self.playerY)
        DecorateSeaRow(row)
    end
    if reorder then
        table.sort(self.seaRows,function(a,b)
            if a.distance~=b.distance then return (a.distance or math.huge)<(b.distance or math.huge) end
            return a.key<b.key
        end)
    end
end
local function NormalizeTreasureZoneGroup(value)
    -- ShowWorldmapLocation 的首参是 zoneGroupId，不是 WorldId/MapContext。
    -- 这里只接受客户端已经给出的正整数事实；禁止从坐标范围、名称、当前大陆等软线索猜区域，否则地图会打开却把标记投到错误图层。
    local n = Number(value)
    if n == nil then return nil end
    n = math.floor(n)
    if n <= 0 then return nil end
    return n
end
local function Dms(dir, deg, min, sec, offset)
    deg, min, sec = Number(deg), Number(min), Number(sec); if not deg or not min or not sec then return nil end
    -- 仍接受可进位的 DMS 数值；只拒绝不可表示的坐标，不凭字段名新增整数/秒范围假设。
    if deg~=deg or min~=min or sec~=sec or math.abs(deg)==math.huge or math.abs(min)==math.huge or math.abs(sec)==math.huge then return nil end
    local value = deg + min / 60 + sec / 3600; if dir == "W" or dir == "S" then value = -value end
    return value * 1024 + offset
end
local function TreasureText(item, precise)
    local lon, lat = Text(item.longitudeDir), Text(item.latitudeDir)
    local a, b, c = Number(item.longitudeDeg), Number(item.longitudeMin), Number(item.longitudeSec)
    local d, e, f = Number(item.latitudeDeg), Number(item.latitudeMin), Number(item.latitudeSec)
    if (lon ~= "E" and lon ~= "W") or (lat ~= "N" and lat ~= "S") or not a or not b or not c or not d or not e or not f then return nil end
    if precise then return string.format("%s %d°%d' %.12g\" · %s %d°%d' %.12g\"",lon,a,b,c,lat,d,e,f)end
    return string.format("%s %d°%d' %d\" · %s %d°%d' %d\"", lon, a, b, c, lat, d, e, f)
end
local function TreasureMapFromNativeItem(item, row, bagId)
    -- RU 客户端物品名不是中文，旧 string.find(name,"藏宝图") 会把真实藏宝图全部过滤掉。
    -- 藏宝图原生物品事实自身携带完整经纬 DMS 字段，这是本功能真正需要且与语言无关的业务证据；只有八个坐标字段均合法时才接纳，
    -- 不根据名字、Tooltip 文案或未知 category 猜测。InventorySnapshotV3 只负责“哪个物理背包槽真实存在”，业务坐标判断仍由 Treasure Authority 所有。
    if type(item) ~= "table" then return nil end
    local worldX = Dms(item.longitudeDir, item.longitudeDeg, item.longitudeMin, item.longitudeSec, 21504)
    local worldY = Dms(item.latitudeDir, item.latitudeDeg, item.latitudeMin, item.latitudeSec, 28672)
    local text = worldX and worldY and TreasureText(item)
    if text == nil or worldX == nil or worldY == nil then return nil end
    local slot = math.max(1, math.floor(Number(row and row.slot) or 1))
    local name = Text(item.name or item.itemName)
    if name == "" then name = "藏宝图 " .. tostring(slot) end -- 这里只是缺名时的 Presentation fallback，不参与识别，因此不会重新引入本地化依赖。
    return {
        -- selectedKey 在旧版一直使用“坐标文本:槽位”。
        -- 虽然新版 Snapshot 能读到 itemType，也绝不能把它塞进 key，否则用户升级后已保存的当前藏宝图会失配并被静默切回第一张。
        -- itemType 仍作为事实字段保留供诊断/未来迁移使用；只有显式 schema migration 才允许改变持久身份格式。
        key = text .. ":" .. tostring(slot),
        name = name, text = TreasureText(item,true), worldX = worldX, worldY = worldY,
        -- 部分 RU 物品结构会直接附带 zoneGroupId/zoneGroupType。
        -- 若字段不存在则保持 nil，后续显式地图定位时再读取“当前区域组”作为有证据的 fallback；不要在背包扫描阶段调用位置 API。
        zoneGroupId = NormalizeTreasureZoneGroup(item.zoneGroupId) or NormalizeTreasureZoneGroup(item.zoneGroupType) or NormalizeTreasureZoneGroup(item.zoneGroup),
        slot = slot, bagId = Number(bagId), itemType = Number(row and row.itemType), stack = Number(row and row.stack) or 1, direction = "--", distance = nil,
    }
end
-- 库存组件复用同一原生坐标解析，不另起按名称识别或第二份 DMS 换算。
function Treasure:ParseInventoryMap(item,row,bagId) return TreasureMapFromNativeItem(item,row,bagId) end
function XA:Refresh()
    -- 静态目标与背包物品生命周期独立；海上视图中不为固定坐标反复扫描背包。
    if self.viewKind~="maps" and (self.selected==nil or IsSea(self.selected)) then
        self.playerX,self.playerY=ReadPlayerPosition();self:RebuildSeaRows(true);Changed("treasure_sea_refresh");return true
    end
    -- 整包扫描只在首次需求、显式刷新、目标变更或 3 秒补采时运行；失败也记录时间，避免空背包每帧重扫。
    self.lastInventoryScanAt = S.NowMs and S.NowMs() or 0
    -- Treasure 不再直接循环 X2Bag。显式刷新/Consumer 首次进入时只构建一次 bounded Snapshot，
    -- 由 InventorySnapshotV3 统一处理 bagId=1/0 RU 差异；随后只对 Snapshot 已确认占用的槽做一次原生详情读取以取得坐标字段。
    -- 该二阶段读取不在 500ms 位置任务内执行，因此不会把背包扫描带入高频路径，也不会复制第二份 Inventory Authority。
    local snapshotService = S.Services and S.Services.InventorySnapshotV3 or nil
    if type(snapshotService) ~= "table" or type(snapshotService.BuildSnapshot) ~= "function" or type(snapshotService.ReadSlot) ~= "function" then
        if IsSea(self.selected) then self.inventoryError="InventorySnapshotV3 不可用";return false end
        self.status, self.error = "unavailable", "InventorySnapshotV3 不可用"
        ClearCompass("unavailable") -- 读取未知时停止旧方向指引，不把未知伪装成空背包。
        self.revision = self.revision + 1
        PublishFeatureUpdate(Treasure, self.revision, "treasure_inventory_unavailable")
        return false
    end
    -- 首轮共享服务选择可读物理背包，此后本次需求会话锁定同一视图；成功空槽不能触发兼容回退。
    local snapshot, snapshotErr = snapshotService:BuildSnapshot("bag", { maxSlots = 240, bagId = self.inventoryBagId, allowBagFallback = self.inventoryBagId == nil })
    if type(snapshot) ~= "table" or (tonumber(snapshot.readErrors) or 0) > 0 then
        if IsSea(self.selected) then self.inventoryError=tostring(snapshotErr or "背包读取失败");return false end
        self.status, self.error = "unavailable", "背包快照不可用：" .. tostring(snapshotErr or "unknown")
        ClearCompass("unavailable") -- 部分读取失败不能证明最后一张图已消失，保留最后已知列表并显式降级。
        self.revision = self.revision + 1
        PublishFeatureUpdate(Treasure, self.revision, "treasure_inventory_failed")
        return false
    end

    local maps = {}
    for _, row in ipairs(type(snapshot.rows) == "table" and snapshot.rows or {}) do
        -- 详情必须与快照同源；不使用会在空槽切视图的 ReadPhysicalBagSlot，避免扫描后消耗/排序竞态复活旧图。
        local readOk, item = snapshotService:ReadSlot("bag", row.slot, snapshot.bagId)
        if readOk == true and type(item) == "table" and next(item) ~= nil then
            local map = TreasureMapFromNativeItem(item, row, snapshot.bagId)
            if map ~= nil then maps[#maps + 1] = map end
        elseif readOk ~= true then
            if IsSea(self.selected) then self.inventoryError="藏宝图详情读取失败";return false end
            -- 第二阶段详情读取也可能失败；禁止把缺失的坐标详情当作物品已消耗。
            self.status, self.error = "unavailable", "藏宝图详情读取失败"
            ClearCompass("unavailable")
            self.revision = self.revision + 1
            PublishFeatureUpdate(Treasure, self.revision, "treasure_detail_failed")
            return false
        end
    end

    local selected = Treasure.State.selectedKey
    local selectedMap = nil
    local coordinate = Treasure.Inventory and self.selected and self.selected.kind~="catalog" and not IsSea(self.selected)
        and Treasure.Inventory.CoordinateKey(self.selected) or nil
    for _, map in ipairs(maps) do
        if map.key == selected and (not coordinate or Treasure.Inventory.CoordinateKey(map)==coordinate) then selectedMap = map; break end
    end
    if selectedMap==nil and coordinate then
        for _,map in ipairs(maps)do if Treasure.Inventory.CoordinateKey(map)==coordinate then selectedMap=map;selected=map.key;break end end
    end
    if selectedMap == nil then
        selectedMap = maps[1]
        selected = selectedMap and selectedMap.key or nil
    end
    Treasure.State.selectedKey = selected
    if self.stopped then selectedMap=nil end
    self.maps=maps
    if not IsSea(self.selected) and not (self.selected and self.selected.kind=="catalog") then self.selected=selectedMap end
    -- 分组必须先于 Publish；否则静止时的新增/消耗只更新旧行，页面要等玩家移动才看到新数量。
    if Treasure.Inventory then
        Treasure.Inventory:RebuildGroups()
        if self.selected and self.selected.kind=="catalog" and not Treasure.Inventory.byKey[Treasure.Inventory.CoordinateKey(self.selected)] then self.selected=nil end
    end
    if self.pendingMapKey ~= nil and (self.selected == nil or tostring(self.selected.key) ~= self.pendingMapKey) then Treasure:CancelPendingMapAction() end -- 物品消耗/重排改变选择时立即取消旧地图请求。
    self.inventoryBagId = snapshot.bagId
    self.inventoryFallbackUsed = snapshot.fallbackUsed == true
    self.status, self.error, self.inventoryError = ((self.selected or #maps > 0) and "ready" or "empty"), nil, nil
    if self.selected == nil then ClearCompass("empty") end -- 最后一张图消耗后同轮清列表、选择与世界指引。
    self.revision = self.revision + 1
    PublishFeatureUpdate(Treasure, self.revision, "treasure_scan")
    return true
end
function XA:CheckInventory()
    -- 500ms 只核对选中图的真实 bagId/slot；空槽不尝试另一背包视图，防止已消耗图被同槽旧视图复活。
    -- 切槽/排序/消耗时重新取共享快照，3 秒整包补采用于发现新增图和非选中图变化；罗盘热路径永远不扫包。
    local now = S.NowMs and S.NowMs() or 0
    if self.viewKind~="maps" and self.selected==nil then return true end
    if IsSea(self.selected) then
        if self.viewKind=="maps" and now-(self.lastInventoryScanAt or 0)>=3000 then return self:Refresh() end
        return true
    end
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
    if current == nil or current.key ~= map.key or current.worldX~=map.worldX or current.worldY~=map.worldY then
        -- 先停旧箭头；保留完整坐标供本轮同步重扫匹配，避免相同取整文字的槽位交换改变目标。
        ClearCompass("selection_changed")
        return self:Refresh()
    end
    if self.status ~= "ready" then return self:Refresh() end -- 读取恢复后重新核对列表，不能一直挂 unavailable。
    return true
end
local function CompassGeometry(style, previous)
    if previous and previous.radius == style.radius and previous.ringSegments == style.ringSegments then return previous end
    -- 固定圈、刻度和箭头模板只在显示参数变化时计算；每帧仍使用本帧位置/方向作平移旋转。
    -- 私有会话缓存，不保存坐标事实、不改变投影来源、点数或33ms刷新频率。
    local geometry = { radius = style.radius, ringSegments = style.ringSegments, base = {}, arrow = {} }
    local radius = style.radius
    local function Add(rows, x, y, kind, size)
        rows[#rows + 1] = { x = x, y = y, kind = kind, size = size or 3 }
    end
    for i = 1, style.ringSegments do
        local a = (i - 1) * math.pi * 2 / style.ringSegments
        Add(geometry.base, math.cos(a) * radius, math.sin(a) * radius, "ring")
    end
    for degree = 0, 345, 15 do
        local a = degree * math.pi / 180
        local length = degree % 45 == 0 and 0.11 or 0.05
        for step = 1, 2 do
            local r = radius * (1 + length * step / 2)
            Add(geometry.base, math.sin(a) * r, math.cos(a) * r, "tick")
        end
    end
    for i = 1, 40 do Add(geometry.arrow, radius * (0.06 + 0.66 * i / 40), 0, "arrow", 6) end
    for row = 0, 12 do
        local fraction = row / 12
        local halfSteps = math.ceil((1 - fraction) * 6)
        local length = radius * (0.72 + 0.26 * fraction)
        for column = -halfSteps, halfSteps do
            local side = radius * 0.085 * (1 - fraction) * (halfSteps > 0 and column / halfSteps or 0)
            Add(geometry.arrow, length, side, "arrow")
        end
    end
    return geometry
end
function XA:UpdateCompass()
    -- 参考 GroundCompass 的坐标分离规则：藏宝图减 world(false)，相机只投影 local(true)。
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
    local style = Treasure.CompassStyle
    if distance ~= distance or distance == math.huge or distance > style.maxDistance then
        ClearCompass("coordinate_space_mismatch"); return false
    end
    local radius, points = style.radius, self.compassWorldPoints or {}
    self.compassWorldPoints = points -- 有界工作区：120环点＋48刻度＋137箭头＋圆心＋4方位，共310个投影点。
    local pointPool = self.compassWorldPointPool or {}
    self.compassWorldPointPool = pointPool -- 进圈裁掉活动数组的箭头时，保留有界工作表供出圈复用。
    local geometry = CompassGeometry(style, self.compassGeometry)
    self.compassGeometry = geometry
    local near = distance <= radius
    local used = 0
    local function Point(x, y, kind, size, text)
        used = used + 1
        local point = pointPool[used] or {}; pointPool[used] = point; points[used] = point
        -- 此客户端的 playerPos 是头/胸部锚点；参考包已证实下移1.6米。
        -- 相机校准仍对应原 playerPos，不能把地面点反过来校准到头部屏幕锚点。
        point.x, point.y, point.z = px + x, py + y, pz - style.groundLift
        point.kind, point.size, point.text = kind, size or 3, text
    end
    for _, offset in ipairs(geometry.base) do Point(offset.x, offset.y, offset.kind, offset.size) end
    if not near then
        local ux, uy = dx / distance, dy / distance
        -- 三角形在地面平面内填充，同一投影自然随俯角压扁，不能用V形轮廓代替箭头。
        for _, offset in ipairs(geometry.arrow) do Point(ux * offset.x - uy * offset.y, uy * offset.x + ux * offset.y, "arrow", offset.size) end
    end
    Point(0, 0, "center")
    local centerIndex = used
    local dotCount = used
    local labelRadius = radius * style.labelOut
    Point(0, labelRadius, "label", 0, "北")
    Point(labelRadius, 0, "label", 0, "东")
    Point(0, -labelRadius, "label", 0, "南")
    Point(-labelRadius, 0, "label", 0, "西")
    for i = #points, used + 1, -1 do points[i] = nil end
    -- 圆环与箭头使用同一帧刚性投影，深度/镜头/FOV 失败由共享服务否决；不自行猜投影或放大 UI scale。
    local screen, source = projection:ProjectWorldBatch(points, {
        easyPullCompat = true, rigidBatch = true, stabilizeAnchor = true, aspectSafeCamera = true,
        anchorUnit = "player", anchorWorld = { x = px, y = py, z = pz },
    })
    local dots, cardinals = {}, {}
    local bottom = nil
    for i = 1, dotCount do
        local row = type(screen) == "table" and screen[i] or nil
        row = type(row) == "table" and row or { visible = false }
        row.kind, row.size = points[i].kind, points[i].size
        dots[i] = row
        if i <= style.ringSegments and row.visible == true and tonumber(row.y) then bottom = math.max(bottom or row.y, row.y) end
    end
    for i = 1, 4 do
        local row = type(screen) == "table" and screen[dotCount + i] or nil
        row = type(row) == "table" and row or { visible = false }
        row.text = points[dotCount + i].text
        cardinals[i] = row
    end
    local center = dots[centerIndex]
    local distanceLabel = nil
    if center and center.visible == true and tonumber(center.x) and tonumber(center.y) and bottom then
        local text
        if distance <= style.reachedDistance then text = IsSea(map) and "坐标附近" or "已到达"
        elseif distance < 1000 then text = string.format("%.0f m", distance)
        elseif distance < 10000 then text = string.format("%.2f km", distance / 1000)
        else text = string.format("%.1f km", distance / 1000) end
        if IsSea(map) then text=map.regionName.." "..map.name:gsub(" #", "#").." · "..text end
        -- 屏幕上圈的正下方，不挂世界正南；转镜头时距离文字不沿刻度转圈。
        local labelY = center.y + math.max(0, bottom - center.y) * style.labelOut + style.labelSize + 14
        -- 透视下外圈方位的投影不能由内圈屏幕半径线性外推。
        -- 按本帧实际方位文字的20px高度，给24px距离文字保留4px间隔。
        for _, cardinal in ipairs(cardinals) do
            local y = cardinal.visible == true and tonumber(cardinal.y) or nil
            if y and y == y and math.abs(y) < math.huge then labelY = math.max(labelY, y + 10 + 12 + 4) end
        end
        distanceLabel = { x = center.x, y = labelY,
            text = text, visible = true }
    end
    self.compass = { points = dots, cardinals = cardinals, center = center, distanceLabel = distanceLabel,
        status = source or "unavailable", near = near, distance = distance, radius = radius }
    if S.Events and type(S.Events.Publish) == "function" then S.Events:Publish(Treasure.CompassTopic) end
    return true
end
function XA:UpdatePosition()
    local clockChanged=self:UpdateShipClock(false)
    local map = self.selected
    if (not map or self.status~="ready") and self.viewKind=="maps" then return false end
    if S.Api:IsCapabilityAllowed("X2Unit:GetUnitWorldPositionByTarget") ~= true then self.error = "X2Unit:GetUnitWorldPositionByTarget 未在当前 RU 能力面证明"; return false end
    local x,y=ReadPlayerPosition()
    local moved=self.playerX~=x or self.playerY~=y or clockChanged
    self.playerX,self.playerY=x,y
    for _,row in ipairs(self.seaRows) do Distance(row,x,y) end -- 更新数值而非重排，保留行位置和滚动。
    if not x or not y then
        if map then Distance(map,nil,nil) end
        ClearCompass("position_unavailable")
        if moved then Changed("treasure_position_unavailable") end
        return false
    end
    if not map or self.status~="ready" then if moved then Changed("treasure_position") end;return true end
    local dx, dy = map.worldX - x, map.worldY - y
    local distance = math.sqrt(dx * dx + dy * dy)
    local direction = math.abs(dx) >= math.abs(dy) and (dx >= 0 and "东" or "西") or (dy >= 0 and "北" or "南")
    -- 事实读取仍为500ms；相同位置不再让主页面/助手复制全列表并重绑表格。
    -- 同距离的另一张图仍必须发布选择变化，不能只比较数值。
    if not moved and self.lastPositionPublishedKey == map.key and map.distance == distance and map.direction == direction then return true end
    map.distance, map.direction, self.lastPositionPublishedKey = distance, direction, map.key
    self.revision = self.revision + 1
    PublishFeatureUpdate(Treasure, self.revision, "treasure_position")
    return true
end
function XA:GetProjection()
    local visited,searched,skipped,recheck=0,0,0,0
    for _,row in ipairs(self.seaRows) do
        local mark=self.visited[row.key]
        if mark then visited=visited+1 end
        if mark=="searched" then searched=searched+1 elseif mark=="skipped" then skipped=skipped+1 end
        if row.timerStatus=="due" then recheck=recheck+1 end
    end
    return {
        revision = self.revision, maps = Copy(self.maps), selected = Copy(self.selected), status = self.status, error = self.error,
        rows=Copy(self.viewKind=="maps" and self.maps or self.seaRows),viewKind=self.viewKind,
        region=self.regions[self.viewKind] or "all",regionItems=Sea and Sea:Regions(self.viewKind) or {},roundVisited=visited,
        roundSearched=searched,roundSkipped=skipped,roundTotal=#self.seaRows,roundRemaining=#self.seaRows-visited,
        canUndoVisit=#self.visitUndo>0,playerX=self.playerX,playerY=self.playerY,inventoryError=self.inventoryError,
        shipRespawnMinutes=Treasure.State.shipTimers and Treasure.State.shipTimers.intervalMinutes or 0,
        shipClockAvailable=self.shipNowMinute~=nil,recheckCount=recheck,
        refreshMs = Treasure.State.refreshMs or 33, -- 只读绘制偏好，无额外Native采样。
        observationContractVersion = Treasure.ObservationContractVersion, mapLocationContractVersion = Treasure.MapLocationContractVersion,
        inventoryBagId = self.inventoryBagId, inventoryFallbackUsed = self.inventoryFallbackUsed == true,
        lastMapActionError = self.lastMapActionError, mapOpenAttempts = self.mapOpenAttempts,
        mapActionPending = self.pendingMapKey ~= nil, -- 等待由寻宝 Authority 所有，页面和助手只呈现，不另建计时器。
        lastMapZoneGroup = self.lastMapZoneGroup, lastMapZoneSource = self.lastMapZoneSource,
    }
end
local function NormalizeTreasureState(value)
    value = type(value) == "table" and value or {}
    return {
        selectedKey = value.selectedKey ~= nil and tostring(value.selectedKey) or nil,
        -- 旧档缺字段保持 nil，避免改变历史 canonical 指纹；投影和调度回退33ms。
        refreshMs = value.refreshMs ~= nil and math.max(1,math.min(60000,math.floor(Number(value.refreshMs) or 33))) or nil,
        widgetVisible = value.widgetVisible == true,
        widgetWindow = type(value.widgetWindow) == "table" and Copy(value.widgetWindow) or nil,
        seaRound = NormalizeSeaRound(value.seaRound),
        shipTimers = NormalizeShipTimers(value.shipTimers),
    }
end
RegisterStore(Treasure.storeId, "v3.life.treasure", function() return NormalizeTreasureState(nil) end, function() return Copy(Treasure.State) end, function(value)
    value = type(value) == "table" and value or {}
    Treasure.State.selectedKey = value.selectedKey
    Treasure.State.refreshMs = NormalizeTreasureState(value).refreshMs
    Treasure.State.widgetVisible = value.widgetVisible == true
    Treasure.State.widgetWindow = type(value.widgetWindow) == "table" and Copy(value.widgetWindow) or nil
    Treasure.State.seaRound = NormalizeSeaRound(value.seaRound)
    Treasure.State.shipTimers = NormalizeShipTimers(value.shipTimers)
end, NormalizeTreasureState)
Treasure.ApiDependencies = { "X2Bag:GetBagItemInfo", "X2Bag:Capacity", "X2Unit:GetUnitWorldPositionByTarget", "X2Unit:GetUnitScreenPosition", "X2Unit:GetCurrentZoneGroup", "X2Map:ShowWorldmapLocation" } -- UnitScreen 供共享投影锚定；地图写入/区域读取仍仅在显式 Command 执行，不由罗盘自动打开地图。
function Treasure:Initialize()
    local ok,err=LoadStore(self);if ok~=true then return false,err end
    if self.roundRestored~=true then
        local round=self.State.seaRound
        XA.viewKind=round and round.viewKind or "maps"
        XA.regions=round and Copy(round.regions) or {}
        XA.visited=DecodeSeaVisits(round and round.visits)
        XA.shipSearches=DecodeShipSearches(self.State.shipTimers and self.State.shipTimers.searches)
        XA.visitUndo={} -- 撤销栈只属于本次会话；已保存标记仅由“新一轮”显式清除。
        XA:RebuildSeaRows(true)
        self.roundRestored=true
    end
    return true
end
local TREASURE_POSITION_TASK = "v3_life_treasure_position"
local TREASURE_COMPASS_TASK = "v3_life_treasure_compass" -- 30Hz 只更新轻量世界引导；最后一个 Consumer 释放两条任务。
function Treasure:ReconcileDemand(_, before, after)
    local beforeCount = tonumber(before and before.count) or 0
    local afterCount = tonumber(after and after.count) or 0
    if beforeCount <= 0 and afterCount > 0 then
        XA.inventoryBagId = nil -- 新需求会话重新确认可读背包；会话内才锁定，不能把上次客户端上下文带入下一次。
        XA:Refresh(); XA:UpdatePosition()
        if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" or type(S.Scheduler.AddHighFrequencyTask) ~= "function" then return false, "寻宝刷新 Scheduler 不可用" end
        local added = S.Scheduler:AddTask(TREASURE_POSITION_TASK, 500, function()
            if Treasure.enabled == true and (tonumber(Treasure.consumerCount) or 0) > 0 then XA:CheckInventory(); XA:UpdatePosition() end
        end, false, Treasure, "P3", 1)
        if added ~= true then return false, "寻宝位置刷新任务创建失败" end
        if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(TREASURE_POSITION_TASK, Treasure.Id, false) end
        -- Scheduler/Demand 是唯一生命周期入口；Presenter 只订阅帧，不自建常驻轮询或第二份选择。
        local compassAdded = S.Scheduler:AddHighFrequencyTask(TREASURE_COMPASS_TASK, Treasure.State.refreshMs or 33, function()
            if Treasure.enabled == true and (tonumber(Treasure.consumerCount) or 0) > 0 then XA:UpdateCompass() end
        end, false, Treasure, "P2", 1)
        if compassAdded ~= true then S.Scheduler:RemoveTask(TREASURE_POSITION_TASK); return false, "寻宝罗盘任务创建失败" end
        if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(TREASURE_COMPASS_TASK, Treasure.Id, false) end
    elseif beforeCount > 0 and afterCount <= 0 and S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then
        self:CancelPendingMapAction() -- 最后一个可见 Consumer 离开后，不保留会晚开原生地图的请求。
        S.Scheduler:RemoveTask(TREASURE_POSITION_TASK)
        S.Scheduler:RemoveTask(TREASURE_COMPASS_TASK)
        self.Authority.compassWorldPoints, self.Authority.compassWorldPointPool, self.Authority.compassGeometry = nil, nil, nil
        ClearCompass("inactive") -- 关闭后马上隐藏点池并释放几何工作区。
    end
    return true
end
function Treasure:Enable() self.enabled = true; return true end
function Treasure:Disable(reason)
    self:CancelPendingMapAction() -- 停用先撤销延后 Native 写，Demand 清理失败也不能让旧请求执行。
    -- 停用即使 Demand 已为空，也要幂等撤销两条任务及所有世界标记，不能残留指向旧藏宝图的箭头。
    local ok, err = self.Demand:Clear(reason or "treasure_disable"); if ok ~= true then return false, err end
    self.trackingConsumerHeld=false
    if S.Scheduler and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(TREASURE_POSITION_TASK); S.Scheduler:RemoveTask(TREASURE_COMPASS_TASK) end
    self.enabled = false
    XA.compassWorldPoints, XA.compassWorldPointPool, XA.compassGeometry = nil, nil, nil
    ClearCompass("disabled"); return true
end
function Treasure:AcquireConsumer(token) if not self.enabled then return false, "寻宝功能已关闭" end return self.Demand:Acquire(token, {}, "treasure_consumer") end
function Treasure:ReleaseConsumer(token) return self.Demand:Release(token, "treasure_consumer") end
function Treasure:Refresh() if not self.enabled or self.consumerCount <= 0 then return true end; XA:Refresh(); XA:UpdatePosition(); return true end
function Treasure:GetProjection() return XA:GetProjection() end
-- 统一模块诊断的冷快照：只读缓存，不扫背包/位置、不取得租约，也不复制整张点位表。
function Treasure:GetHealth()
    local compass=XA.compass or {}
    local visited=0;for _,row in ipairs(XA.seaRows) do if XA.visited[row.key] then visited=visited+1 end end
    return {diagnosticsContractVersion=2,seaPointsContractVersion=self.SeaPointsContractVersion,
        seaRoundPersistenceContractVersion=self.SeaRoundPersistenceContractVersion,roundSaved=self.State.seaRound~=nil,
        shipTimerContractVersion=self.ShipTimerContractVersion,shipClockAvailable=XA.shipNowMinute~=nil,
        shipRespawnMinutes=self.State.shipTimers and self.State.shipTimers.intervalMinutes or 0,shipTimerSource="manual_search_estimate",
        enabled=self.enabled,consumerCount=self.consumerCount or 0,trackingConsumerHeld=self.trackingConsumerHeld==true,
        revision=XA.revision,status=XA.status,error=XA.error,viewKind=XA.viewKind,region=XA.regions[XA.viewKind] or "all",
        catalogReady=Sea~=nil,catalogCounts=Sea and Sea:Counts() or {available=false},
        filteredPointCount=XA.viewKind~="maps" and #XA.seaRows or nil,bagMapCount=#XA.maps,roundVisited=visited,
        selected=Copy(XA.selected),position={available=XA.playerX~=nil and XA.playerY~=nil,x=XA.playerX,y=XA.playerY},
        compass={status=compass.status,pointCount=#(compass.points or {}),distance=compass.distance,near=compass.near},
        nativeMap={mode="native_arrow",attempts=XA.mapOpenAttempts,lastZoneGroupId=XA.lastMapZoneGroup,zoneSource=XA.lastMapZoneSource,
            lastRequest=Copy(XA.lastMapRequest),lastError=XA.lastMapActionError},
        inventoryError=XA.inventoryError,lastMapActionError=XA.lastMapActionError,mapActionPending=XA.pendingMapKey~=nil}
end
function Treasure:Select(key)
    if not self.enabled then return false,"寻宝功能已关闭" end
    local point=Sea and Sea:Get(key)
    if point then
        if not self.trackingConsumerHeld then
            local acquired,why=self:AcquireConsumer(SEA_TRACKING_TOKEN)
            if acquired~=true then return false,why end
            self.trackingConsumerHeld=true
        end
        XA.stopped=false
        XA.lastMapActionError,XA.lastMapZoneGroup,XA.lastMapZoneSource=nil,nil,nil -- 新目标不继承旧藏宝图的原生地图动作失败。
        self:CancelPendingMapAction();XA.selected=point;DecorateSeaRow(point);XA.status,XA.error="ready",nil
        XA:UpdatePosition();Changed("treasure_sea_select");return true
    end
    for _, map in ipairs(XA.maps or {}) do
        if map.key == key then
            local persisted, persistErr = PersistLifeMutation(self, "treasure_select", function(state) state.selectedKey = key; return true end)
            if persisted ~= true then return false, persistErr end
            if self.trackingConsumerHeld then
                local released,why=self:ReleaseConsumer(SEA_TRACKING_TOKEN)
                if released~=true then return false,why end
                self.trackingConsumerHeld=false
            end
            XA.stopped=false
            if XA.pendingMapKey ~= nil and XA.pendingMapKey ~= tostring(map.key) then self:CancelPendingMapAction() end -- 用户换图取消等待，换回原图也不能复活旧点击。
            XA.selected = map; XA.status,XA.error="ready",nil;XA:UpdatePosition(); return true
        end
    end
    return false, "藏宝图选择无效"
end
function Treasure:SetViewKind(kind)
    if not self.enabled then return false,"寻宝功能已关闭" end
    if kind~="maps" and kind~="seabugs" and kind~="ships" then return false,"未知寻宝分类" end
    if kind~="maps" and not Sea then return false,"海上点位目录未加载" end
    local saved,why=PersistSeaRound(XA.visited,kind,XA.regions,"treasure_sea_view")
    if saved~=true then return false,why end
    XA.viewKind=kind
    XA.playerX,XA.playerY=ReadPlayerPosition()
    if kind=="maps" then XA:Refresh() else XA:RebuildSeaRows(true) end
    Changed("treasure_view");return true
end
function Treasure:SetRegion(region)
    if not self.enabled or not Sea or XA.viewKind=="maps" then return false,"请先选择海虫或沉船" end
    local valid=false;for _,r in ipairs(Sea:Regions(XA.viewKind)) do if r.value==region then valid=true;break end end
    if not valid then return false,"该分类没有此区域" end
    local regions=Copy(XA.regions);regions[XA.viewKind]=region
    local saved,why=PersistSeaRound(XA.visited,XA.viewKind,regions,"treasure_sea_region")
    if saved~=true then return false,why end
    XA.regions=regions;XA.playerX,XA.playerY=ReadPlayerPosition();XA:RebuildSeaRows(true)
    Changed("treasure_region");return true
end
function Treasure:TrackNearest()
    if not self.enabled or not Sea or XA.viewKind=="maps" then return false,"请先选择海虫或沉船" end
    local x,y=ReadPlayerPosition();if not x or not y then return false,"玩家坐标不可用，无法判断最近点" end
    XA.playerX,XA.playerY=x,y
    XA:UpdateShipClock(true)
    local best,distance
    for _,row in ipairs(XA.seaRows) do
        Distance(row,x,y)
        if row.timerStatus~="estimated" and (not XA.visited[row.key] or row.timerStatus=="due" and XA.visited[row.key]=="searched")
            and (not distance or row.distance<distance or row.distance==distance and row.key<best.key) then best,distance=row,row.distance end
    end
    if not best then return false,"当前区域没有待搜查或可复查点；可切换区域或在设置中开始新一轮，计时中的沉船会暂时避开" end
    return self:Select(best.key)
end
function Treasure:VisitAndNext(mark)
    if not self.enabled or not IsSea(XA.selected) then return false,"请先追踪海虫或沉船点" end
    if mark~="searched" and mark~="skipped" then return false,"无效搜查状态" end
    local current=XA.selected
    if current.kind~=XA.viewKind or ((XA.regions[XA.viewKind] or "all")~="all" and current.region~=XA.regions[XA.viewKind]) then
        return false,"当前目标在筛选区域外，请先选择筛选内的目标"
    end
    -- 下一处依赖当前位置；未知时保留当前目标和本轮记录，避免误标或跳到任意点。
    local x,y=ReadPlayerPosition();if not x or not y then return false,"玩家坐标不可用" end
    local visited=Copy(XA.visited);visited[current.key]=mark
    local searches
    if current.kind=="ships" and mark=="searched" then
        XA:UpdateShipClock(true);searches=Copy(XA.shipSearches);searches[current.key]=XA.shipNowMinute
    end
    local saved,why=PersistSeaRound(visited,nil,nil,"treasure_sea_visit",searches)
    if saved~=true then return false,why end
    XA.visitUndo[#XA.visitUndo+1]={key=current.key,previous=XA.visited[current.key],previousSearch=XA.shipSearches[current.key],timerChanged=searches~=nil}
    if #XA.visitUndo>504 then table.remove(XA.visitUndo,1) end
    XA.visited=visited
    if searches then XA.shipSearches=searches end
    for _,row in ipairs(XA.seaRows) do if row.key==current.key then DecorateSeaRow(row) end end
    XA.selected=nil;self:CancelPendingMapAction();ClearCompass("sea_round_next")
    local found=self:TrackNearest()
    if not found then
        XA.status="empty"
        if self.trackingConsumerHeld then
            local released,why=self:ReleaseConsumer(SEA_TRACKING_TOKEN)
            if released~=true then return false,why end
            self.trackingConsumerHeld=false
        end
    end
    Changed("treasure_sea_visit");return true
end
function Treasure:UndoVisit()
    if not self.enabled then return false,"寻宝功能已关闭" end
    local last=XA.visitUndo[#XA.visitUndo];if not last then return false,"本轮没有可撤销的搜查" end
    local visited=Copy(XA.visited);visited[last.key]=last.previous
    local searches
    if last.timerChanged then searches=Copy(XA.shipSearches);searches[last.key]=last.previousSearch end
    local saved,why=PersistSeaRound(visited,nil,nil,"treasure_sea_undo",searches)
    if saved~=true then return false,why end
    table.remove(XA.visitUndo);XA.visited=visited
    if searches then XA.shipSearches=searches end
    for _,row in ipairs(XA.seaRows) do if row.key==last.key then DecorateSeaRow(row) end end
    self:Select(last.key);Changed("treasure_sea_undo");return true
end
function Treasure:ResetRound()
    if not self.enabled then return false,"寻宝功能已关闭" end
    local saved,why=PersistSeaRound({},nil,nil,"treasure_sea_round")
    if saved~=true then return false,why end
    XA.visited,XA.visitUndo={},{}
    XA:RebuildSeaRows(true);Changed("treasure_sea_round");return true
end
function Treasure:StopTracking()
    if not self.enabled then return false,"寻宝功能已关闭" end
    if self.trackingConsumerHeld then
        local released,why=self:ReleaseConsumer(SEA_TRACKING_TOKEN)
        if released~=true then return false,why end
        self.trackingConsumerHeld=false
    end
    XA.selected,XA.stopped=nil,true
    self:CancelPendingMapAction();ClearCompass("tracking_stopped");Changed("treasure_stop");return true
end
local function ResolveTreasureMapZoneGroup(map)
    -- 参考 TreasureMapHunter 的真实调用是 targetZone + global x/y，
    -- 因此先信藏宝图条目自己的 zoneGroup；没有时只允许用玩家当前 zoneGroup。后者只能保证“玩家已进入藏宝图所在区域”时精确定位，
    -- 但至少不会像旧魔数 2 那样打开地图却静默落到错误区域。跨区域一键定位若要完全可靠，后续必须补结构化 Treasure Location DB，不能猜。
    local explicit = type(map) == "table" and NormalizeTreasureZoneGroup(map.zoneGroupId) or nil
    if IsSea(map) then
        if explicit~=nil then return explicit,"sea_catalog" end
        return nil,"海上资料点缺少原包区域组映射"
    end
    if explicit ~= nil then return explicit, "item" end
    if type(map)=="table" and map.kind=="catalog" then return nil,"箱子坐标记录缺少区域组，请先取图核对" end
    local ok, currentZone, err = Call("X2Unit:GetCurrentZoneGroup", UnitApi, "GetCurrentZoneGroup")
    local zone = ok == true and NormalizeTreasureZoneGroup(currentZone) or nil
    if zone ~= nil then return zone, "current_zone" end
    return nil, tostring(err or "藏宝图未提供区域组，且当前区域组不可用")
end
function Treasure:CancelPendingMapAction()
    -- 固定任务身份由 Feature 生命周期拥有；选择过期/停用/后继请求都只取消这一份请求。
    if S.Scheduler and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(TREASURE_MAP_REQUEST_TASK) end
    XA.pendingMapKey = nil
end
function Treasure:ShowSelectedOnMap(deferred)
    -- 地图打开属于显式用户动作，只能从 Command 进入并经 Capability Gate；
    -- UpdatePosition 不发起定位；Scheduler 只执行 Command 已授权的一次冷却等待。失败只记录诊断并保留当前选择/距离追踪，不清 Store、不切换藏宝图，避免 UI 能力故障污染 Domain Authority。
    if self.enabled ~= true then return false, "寻宝功能已关闭" end -- 即时和延后请求都遵守同一个 Feature 生命周期，不靠 UI 可见性判断授权。
    local map = XA.selected
    if type(map) ~= "table" then return false, "请先选择追踪目标" end
    local worldX, worldY = Number(map.worldX), Number(map.worldY)
    if worldX == nil or worldY == nil then return false, "追踪目标坐标不可用" end
    -- 保留 Capability 的250ms间隔；用户重复双击的最后一次请求只等待实际剩余时间。
    -- 回调最多执行一次；目标已改、模块停用或图已失效时取消，不从轮询/恢复路径自动打开地图。
    local cooldown = S.Api and type(S.Api.GetCapabilityCooldownState) == "function"
        and S.Api:GetCapabilityCooldownState("X2Map:ShowWorldmapLocation") or nil
    local remaining = tonumber(cooldown and cooldown.remainingMs) or 0
    self:CancelPendingMapAction()
    if deferred ~= true and remaining > 0 then
        if not self.enabled then return false, "寻宝功能已关闭" end
        local scheduler = S.Scheduler
        if scheduler == nil or type(scheduler.AddHighFrequencyOneShot) ~= "function" then return false, "地图定位等待任务不可用" end
        local key = tostring(map.key)
        -- 短剩余时间使用已有1ms下限的一次性通道，不能被背景 AddOneShot 的50ms下限额外延迟。
        local queued = scheduler:AddHighFrequencyOneShot(TREASURE_MAP_REQUEST_TASK, math.ceil(remaining), function()
            XA.pendingMapKey = nil
            local current = XA.selected
            if self.enabled ~= true or XA.status ~= "ready" or type(current) ~= "table" or tostring(current.key) ~= key then
                XA.revision = XA.revision + 1
                PublishFeatureUpdate(self, XA.revision, "treasure_map_cancelled")
                return true
            end
            return self:ShowSelectedOnMap(true)
        end, self, "P2", 1)
        if queued ~= true then return false, "地图定位等待任务创建失败" end
        XA.pendingMapKey, XA.lastMapActionError = key, nil
        if type(scheduler.SetTaskModule) == "function" then scheduler:SetTaskModule(TREASURE_MAP_REQUEST_TASK, self.Id, true) end
        XA.revision = XA.revision + 1
        PublishFeatureUpdate(self, XA.revision, "treasure_map_pending")
        return true, "pending"
    end
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
    XA.lastMapRequest={key=map.key,kind=map.kind or "maps",zoneGroupId=zoneGroupId,x=worldX,y=worldY,z=0,atMs=S.NowMs and S.NowMs() or 0}
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
    SetShipRespawnMinutes=function(_,value)
        value=tonumber(value)
        if not value or value<0 or value>10080 or value~=math.floor(value)then return false,"预估周期须为0～10080分钟，0仅记录已过时间" end
        local ok,why=P:MutateStore(Treasure.storeId,function()
            Treasure.State.shipTimers={searches=EncodeShipSearches(XA.shipSearches),intervalMinutes=value};return true
        end,{durable=true,reason="treasure_ship_interval"})
        if ok then XA:UpdateShipClock(true);Changed("treasure_ship_interval")end
        return ok,why
    end,
    SetViewKind=function(_,kind)return Treasure:SetViewKind(kind)end,
    SetRegion=function(_,region)return Treasure:SetRegion(region)end,
    TrackNearest=function()return Treasure:TrackNearest()end,
    VisitAndNext=function(_,mark)return Treasure:VisitAndNext(mark)end,
    UndoVisit=function()return Treasure:UndoVisit()end,
    ResetRound=function()return Treasure:ResetRound()end,
    StopTracking=function()return Treasure:StopTracking()end,
    -- 设置成功后更新同一绘制任务；不加快背包扫描、不改变藏宝图选择及原生地图动作。
    SetRefreshMs = function(_, value)
        value=Number(value)
        if not value or value<1 or value>60000 or value~=math.floor(value) then return false,"刷新间隔必须为1～60000毫秒整数" end
        local ok,why=PersistLifeMutation(Treasure,"treasure_refresh_ms",function(state)state.refreshMs=value;return true end)
        if ok then
            if S.Scheduler and type(S.Scheduler.SetTaskInterval)=="function" then S.Scheduler:SetTaskInterval(TREASURE_COMPASS_TASK,value,true) end
            XA.revision=XA.revision+1;PublishFeatureUpdate(Treasure,XA.revision,"treasure_refresh_ms")
        end
        return ok,why
    end,
    Refresh = function(_, reason) return Treasure:Refresh(reason) end,
    Select = function(_, key) return Treasure:Select(key) end,
    ShowSelectedOnMap = function() return Treasure:ShowSelectedOnMap() end, -- Presentation 只调用 Feature Command，不直接触碰 X2Map；主页面与悬浮窗因此共享同一选择和失败诊断。
    GetWidgetVisible = function() return Treasure:GetWidgetVisible() end, SetWidgetVisible = function(_, value, reason) return Treasure:SetWidgetVisible(value, reason) end,
    SetWidgetWindowState = function(_, value, reason) return Treasure:SetWidgetWindowState(value, reason) end, MarkStoreDirty = function(_, delayMs, reason) return Treasure:MarkStoreDirty(delayMs, reason) end,
}
local treasureDemand, treasureErr = Demand:Create({ id = "feature:" .. Treasure.Id, owner = Treasure, projectionOwner = Treasure, projectionConsumersField = "consumers", projectionCountField = "consumerCount", reconcile = function(lease, before, after) return Treasure:ReconcileDemand(lease, before, after) end })
if treasureDemand == nil then error(treasureErr) end
Treasure.Demand = treasureDemand
ok, err = Runtime:RegisterImplementation(Treasure.Id, Treasure); if ok ~= true then error(err) end
