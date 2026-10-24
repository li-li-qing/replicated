------------------------------------------------------------------------
-- Replicated Suite · 寻宝坐标库存与逐箱登记
-- 作者：Replicated
-- QQ群：1104129461
--
-- 同一 Treasure Feature 的库存组件：只用现有 Snapshot/Persistence/Scheduler。
-- 按开箱交互生成本轮记录号；同次打开重复识别更新记录，不以内容相同冒充物理箱身份。
-- 旧寻宝 Store 不增字段；角色级快照分块保存，移动意图先耐久落盘，确认后替换。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local F = S.Features and S.Features.Treasure
local LF, P = S.LifeSliceFactory, S.Persistence
if not F or not LF or not P then error("Treasure inventory dependencies unavailable") end
local Copy, Call, Action = LF.Copy, LF.Call, LF.Action
local A = F.Authority
local I = { storeId="v3.life.treasure.inventory", State={filter="all",sort="count",boxes={},overrides={}},
    rows={}, byKey={}, withdraw={status="idle",moved=0}, maxBoxes=8192, maxSlots=240 } -- 记录按需增长；上界对应Store表预算，不再预置3箱或限制32箱。
F.Inventory, F.InventoryContractVersion = I, 1
local TASK = "v3_life_treasure_withdraw"
local LABEL = {all="全部大陆",west="西大陆",east="东大陆",auroria="原大陆",sea="海上",unknown="未分类"}
local function Finite(v) v=tonumber(v);if v and v==v and math.abs(v)<math.huge then return v end end
local function Integer(v,lo,hi) v=Finite(v);if v and v==math.floor(v) and v>=lo and v<=hi then return v end end
local function Key(map)
    local x,y=map and Finite(map.worldX),map and Finite(map.worldY)
    if not x or not y then return nil end
    if x==0 then x=0 end;if y==0 then y=0 end -- 统一 -0，不按显示文字/取整坐标合并。
    return string.format("coord:%.17g:%.17g",x,y)
end
I.CoordinateKey=Key
local function BoxId(v) local n=Integer(v,1,I.maxBoxes);return n and tostring(n) end
local function Publish(reason)
    A.revision=A.revision+1;LF.PublishFeatureUpdate(F,A.revision,reason)
end
local function Now() return S.NowMs and S.NowMs() or 0 end
local function Stamp()
    local ok,t=pcall(function()return S.Utils.GetServerTime()end)
    if ok and type(t)=="table" and tonumber(t.year) and tonumber(t.month) and tonumber(t.day) then
        return string.format("%04d-%02d-%02d %02d:%02d",t.year,t.month,t.day,tonumber(t.hour) or 0,tonumber(t.minute or t.min) or 0)
    end
    return "扫描时间不可用"
end
local function Decode(box)
    local maps={}
    assert(type(box)=="table" and type(box.chunks)=="table" and Integer(box.records,0,I.maxSlots),"箱子快照结构无效")
    for _,chunk in ipairs(box.chunks) do
        assert(type(chunk)=="string" and #chunk<=1024 and chunk:sub(-1)=="\n","箱子快照分块无效")
        local consumed=0
        for line in chunk:gmatch("([^\n]+)\n") do
            local x,y,z,count,text=line:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
            x,y,z,count=Finite(x),Finite(y),Integer(z,0,1000000),Integer(count,1,2147483647)
            assert(x and y and z and count and text and #text<=180 and not text:find("[%c]"),"箱子坐标记录无效")
            maps[#maps+1]={worldX=x,worldY=y,zoneGroupId=z>0 and z or nil,count=count,text=text,name="藏宝图"}
            consumed=consumed+#line+1
        end
        assert(consumed==#chunk,"箱子快照存在残缺记录")
    end
    assert(#maps==box.records,"箱子快照记录数量不符")
    return maps
end
local function Normalize(value)
    value=type(value)=="table" and value or {}
    local out={filter=LABEL[value.filter] and value.filter or "all",sort=value.sort=="coordinate" and "coordinate" or "count",boxes={},overrides={}}
    -- 可选字段缺失时保持旧Schema1表形，避免读取旧档时凭默认字段改变完整性指纹；首次识别/显式重新统计才写入。
    if value.scanRound==true then out.scanRound=true end
    local seen=0
    for id,box in pairs(value.boxes or {}) do
        assert(BoxId(id)==id,"箱号无效");Decode(box);seen=seen+1;assert(seen<=I.maxBoxes,"登记箱数超出上限")
        out.boxes[id]=Copy(box)
    end
    seen=0
    for key,continent in pairs(value.overrides or {}) do
        assert(type(key)=="string" and #key<=100 and key:match("^coord:") and LABEL[continent] and continent~="all","手动分类无效")
        seen=seen+1;assert(seen<=8192,"手动分类数量超出上限");out.overrides[key]=continent
    end
    if value.pendingCoffer~=nil then out.pendingCoffer=assert(BoxId(value.pendingCoffer),"待核对箱号无效") end
    return out
end
local store,storeErr=P:RegisterV3Store({id=I.storeId,owner="v3.life.treasure",scope=P.Scope.Character,lifetime=P.Lifetime.Permanent,
    schemaVersion=1,legacySchemaVersion=0,key=P.V3KeyPrefix.."v3_life_treasure_inventory",
    nativeByteBudget=14336, -- 真实UDF本轮截在16383字节；复用Core物理预算，在写入前拒绝超限，不能只限制单个chunk。
    recoverableReplacement=true, -- 仅显式“重新统计”可替换损坏的可再生箱记录；普通登记仍须PrepareWrite和完整校验。
    budget={maxDepth=6,maxNodes=12000,maxEntriesPerTable=8192,maxStringBytes=1048576},
    default=function()return Normalize(nil)end,get=function()return Copy(I.State)end,
    apply=function(v)I.State=Normalize(v)end,migrate=Normalize})
if not store then error(storeErr or "Treasure inventory store registration failed") end

function I:Initialize()
    -- 同代切角时 Core 绑定才是就绪权威；取消上一角色箱交互/取图任务，但不清 Domain，避免破坏待刷新旧角色存档。
    if self.loaded and P:IsStoreLoaded(self.storeId)==true then return true end
    if self.loaded then
        -- 背包地图是本 Feature 的会话缓存，也属于上一角色；库存重绑前作废，不改任何角色存档，等待原扫描链补齐新背包。
        A.maps={};A.selected=nil;A.lastInventoryScanAt=nil;A.inventoryBagId=nil
        A.inventoryError="角色已变化，等待重新读取背包";A.status="unavailable"
        if type(F.CancelPendingMapAction)=="function" then F:CancelPendingMapAction() end
    end
    self.loaded=false;self.bound=nil;self.openRecord=nil
    if self.job then self:Stop("cancelled","角色库存绑定已变化，请重新识别保管箱") end
    if A.selected and A.selected.kind=="catalog" then A.selected=nil end
    local ok,err=P:PrepareRead(self.storeId)
    if ok~=true then self.lastError=tostring(err or "箱子记录读取失败");self:RebuildGroups();return false,err end
    self.lastError=nil
    self.loaded=true;self.bound=nil;self.openRecord=nil;self.job=nil;self.withdraw={status="idle",moved=0}
    self:RebuildGroups();return true
end
function I:EndCofferInteraction(reason)
    -- 原生 START/END 无可靠箱ID，只划分交互边界。开箱记录与取图绑定分开，取消取图不能让再次识别追加同箱。
    self.cofferSession=(self.cofferSession or 0)+1;self.openRecord=nil;self.bound=nil
    self.lastCofferBoundary=reason
    if self.job then self:Stop("cancelled","保管箱已关闭或切换，请重新识别")
    else Publish("treasure_coffer_interaction")end
end
function I:WatchCofferInteraction(active)
    local events=S.Events;if not events then return end
    if not active then
        if not self.cofferEventChannels and not self.openRecord and not self.bound and not self.job then return end
        if events.UnsubscribeGlobalOwner then events:UnsubscribeGlobalOwner(self)end
        events:UnsubscribeOwner(self);self.cofferEventChannels=nil
        self:EndCofferInteraction("inactive");return
    end
    if self.cofferEventChannels then return end
    events:BindOwner(self,F.Id);self.cofferEventChannels={}
    for _,name in ipairs({"COFFER_INTERACTION_START","COFFER_INTERACTION_END"})do
        local callback=function(owner)
            owner.cofferEventCount=(owner.cofferEventCount or 0)+1;owner:EndCofferInteraction(name)
        end
        -- 客户端原生箱界面使用 UIParent 全局分发；只经现有可释放桥订阅。能力缺失时回退私有事件宿主。
        local subscribed=events.SubscribeGlobalOptional and events:SubscribeGlobalOptional(name,self,callback)
        if subscribed then self.cofferEventChannels[name]="global"
        elseif events:SubscribeOptional(name,self,callback) then self.cofferEventChannels[name]="host"
        else self.cofferEventChannels[name]="unavailable" end
    end
end
function I:Commit(reason,fn)
    local ok,err=self:Initialize();if ok~=true then return false,err end
    ok,err=P:MutateStore(self.storeId,function()fn(self.State);return true end,{durable=true,reason=reason})
    self:RebuildGroups()
    if ok~=true then
        -- recoverableReplacement 也用于无活动读者的journal；本组件仍有活动记录，原生写失败不能略过Reload屏障。
        local current=P:GetStore(self.storeId)
        if current and (tonumber(current.consecutiveSaveFailures) or 0)>0 then current.needsBarrierVerify=true end
        self.lastError=tostring(err or "库存记录保存失败")
        if self.lastError:find("native_byte_budget_exceeded:",1,true)then
            self.lastError="本轮箱子记录已达存档容量，本次未保存，原记录已保留；请分批重新统计";err=self.lastError
        end
    end
    return ok,err
end
function I:Continent(map)
    local zones=S.GameIds and S.GameIds.Zone and S.GameIds.Zone.ById or {}
    local zone=zones[tonumber(map.zoneGroupId)]
    if zone and LABEL[zone.continentKey] then return zone.continentKey end
    local data=S.Data and S.Data.TreasureSeaPoints
    for _,region in ipairs(data and data.regions or {})do if region.zoneGroupId==map.zoneGroupId then return "sea" end end
    return "unknown"
end
function I:RebuildGroups()
    local groups={}
    local function Add(map,boxId,uncertain)
        local key=Key(map);if not key then return end
        local row=groups[key]
        if not row then row={key=key,groupKey=key,kind="inventory",name="藏宝图",text=map.text,
            worldX=map.worldX,worldY=map.worldY,zoneGroupId=map.zoneGroupId,count=0,bagCount=0,cofferCount=0,
            uncertainCount=0,boxes={},continent=self:Continent(map)};groups[key]=row
        else
            local continent=self:Continent(map)
            if continent~="unknown" then
                if row.continent=="unknown" and not row.continentConflict then row.continent=continent
                elseif continent~=row.continent then row.continent="unknown";row.continentConflict=true end
            end
        end
        if map.zoneGroupId and not row.zoneConflict then
            if not row.zoneGroupId then row.zoneGroupId=map.zoneGroupId
            elseif row.zoneGroupId~=map.zoneGroupId then row.zoneGroupId=nil;row.zoneConflict=true end
        end
        local n=math.max(1,tonumber(map.count or map.stack) or 1)
        if uncertain then row.uncertainCount=row.uncertainCount+n
        else row.count=row.count+n;if boxId then row.cofferCount=row.cofferCount+n else row.bagCount=row.bagCount+n end end
        if boxId then row.boxes[boxId]=(row.boxes[boxId] or 0)+n end
    end
    for _,map in ipairs(A.maps or {})do Add(map)end
    self.cofferSummaries,self.boxIds={},{}
    for id,box in pairs(self.loaded and self.State.boxes or {})do
        local count=0;for _,map in ipairs(Decode(box))do Add(map,id,self.State.pendingCoffer==id);count=count+map.count end
        self.cofferSummaries[id]={stamp=box.stamp,coordinateCount=box.records,count=count,uncertain=self.State.pendingCoffer==id}
        self.boxIds[#self.boxIds+1]=id
    end
    table.sort(self.boxIds,function(a,b)return tonumber(a)<tonumber(b)end)
    self.sharedCoordinateCount=0
    self.rows,self.byKey={},groups
    for key,row in pairs(groups)do
        row.continent=self.State.overrides[key] or row.continent;row.regionName=LABEL[row.continent]
        local parts={};if row.bagCount>0 then parts[#parts+1]="背包 "..row.bagCount end
        row.cofferSourceCount=0
        -- 箱数按需增长后，只遍历该坐标实际命中的来源；避免每条坐标再扫描全部已识别箱。
        local sources={};for id in pairs(row.boxes)do sources[#sources+1]=id end
        table.sort(sources,function(a,b)return tonumber(a)<tonumber(b)end)
        for _,id in ipairs(sources)do
            parts[#parts+1]="记录"..id.." "..row.boxes[id]..(self.State.pendingCoffer==id and "（待核对）" or "")
            if self.State.pendingCoffer~=id then row.cofferSourceCount=row.cofferSourceCount+1 end
        end
        row.sourceText=table.concat(parts," / ");row.visitText="共 "..row.count.." 张 · 包"..row.bagCount.."/箱"..row.cofferCount
        -- 背包重复、单箱多张与跨箱重复分开；只有至少两条已确认箱记录同时命中才算跨箱同坐标。
        if row.cofferSourceCount>1 then
            self.sharedCoordinateCount=self.sharedCoordinateCount+1
            row.visitText=row.visitText.." · 跨"..row.cofferSourceCount.."箱同坐标"
        end
        if row.uncertainCount>0 then row.visitText=row.visitText.." + 待核对"..row.uncertainCount end
        self.rows[#self.rows+1]=row
    end
    table.sort(self.rows,function(a,b)
        if self.State.sort=="count" and a.count~=b.count then return a.count>b.count end
        if a.worldX~=b.worldX then return a.worldX<b.worldX end
        return a.worldY<b.worldY
    end)
    if A.selected and A.selected.kind=="catalog" then
        local current=groups[Key(A.selected)]
        if current then
            local distance,direction=A.selected.distance,A.selected.direction
            A.selected=Copy(current);A.selected.kind="catalog";A.selected.distance=distance;A.selected.direction=direction
        end
    end
end
function I:Window()
    local contentId=rawget(_G,"UIC_COFFER");if contentId==nil then return false,"保管箱窗口标识不可用" end
    -- 此 Native 有五个数据返回值，现有 Api:Call 只保留四个；沿用背包工具的已门控几何读取，不能丢掉最后的 visible。
    local addon=rawget(_G,"ADDON")
    if not S.Api or S.Api:IsCapabilityAllowed("ADDON:GetContentMainScriptPosVis")~=true
        or not addon or type(addon.GetContentMainScriptPosVis)~="function" then return false,"保管箱窗口能力不可用" end
    local _,content=Call("ADDON:GetContent",nil,"GetContent",contentId)
    local function Flag(value)
        if type(value)=="boolean" then return true,value end
        if value==0 or value==1 then return true,value==1 end
        if type(value)=="string" then
            value=value:lower():gsub("^%s+", ""):gsub("%s+$", "")
            if value=="1" or value=="true" or value=="on" or value=="show" or value=="visible" then return true,true end
            if value=="0" or value=="false" or value=="off" or value=="hide" or value=="hidden" then return true,false end
        end
        return false,false
    end
    local contentVisible,node=false,content
    for _=0,8 do
        if type(node)~="table" and type(node)~="userdata" then break end
        if type(node.IsVisible)=="function" then
            local ok,value=pcall(function()return node:IsVisible()end)
            local known,shown=Flag(value);if ok and known and shown then contentVisible=true;break end
        end
        if type(node.GetParent)~="function" then break end
        local ok,parent=pcall(function()return node:GetParent()end)
        if not ok or parent==node then break end;node=parent
    end
    local ok,x,y,w,h,visible=pcall(function()return addon:GetContentMainScriptPosVis(contentId)end)
    x,y,w,h=Finite(x),Finite(y),Finite(w),Finite(h)
    local layout=S.Layout and type(S.Layout.GetContext)=="function" and S.Layout:GetContext() or {}
    local lw,lh=math.max(320,tonumber(layout.logicalWidth) or 1024),math.max(240,tonumber(layout.logicalHeight) or 768)
    local rect=ok and x and y and w and h and w>0 and h>0 and w<=lw*2 and h<=lh*2
        and x>=-w and y>=-h and x<=lw+w and y<=lh+h
    local known,shown=Flag(visible)
    -- 与已有仓储适配一致：明确隐藏优先；缺少第五值时，合法 MainScript 矩形也是开窗证据。
    if (known and not shown) or not (rect or contentVisible) then return false,"请先打开保管箱，再点击识别当前保管箱" end
    return true,content
end
function I:Scan(scope)
    local service=S.Services and S.Services.InventorySnapshotV3
    if not service then return nil,"库存快照服务不可用" end
    if scope=="coffer" then local ok,err=self:Window();if not ok then return nil,err end end
    local prefix=scope=="coffer" and "X2Coffer" or "X2Bag"
    local capOk,capacity=Call(prefix..":Capacity",nil,"Capacity")
    capacity=Integer(capacity,0,self.maxSlots)
    if not capOk or not capacity then return nil,"容器容量未知或超过240槽，本次未覆盖旧记录" end
    local bagId=scope=="bag" and A.inventoryBagId or nil
    if scope=="bag" and bagId==nil then
        local snapshot,err=service:BuildSnapshot(scope,{maxSlots=self.maxSlots})
        if not snapshot or (snapshot.readErrors or 0)>0 then return nil,err or "容器读取不完整，保留旧记录" end
        bagId=snapshot.bagId
    end
    local result={maps={},entries={},tokens={},counts={},occupied=0,capacity=capacity,bagId=bagId}
    local sig={}
    -- 由共享服务读槽和归一化，原生详情在同一次读取中解析，不再对每个占用槽二次读取。
    for slot=1,capacity do
        local ok,item=service:ReadSlot(scope,slot,bagId)
        if not ok or (item~=nil and type(item)~="table") then return nil,"容器读取不完整，保留旧记录" end
        local live=service:NormalizeRow(slot,item,bagId)
        if live then
            local map=F:ParseInventoryMap(item,live,bagId)
            local key=Key(map)
            if not key and tostring(live.category)=="9000022" then return nil,"有藏宝图尚无完整坐标，保留旧记录" end
            if map then map.count=live.stack;map.groupKey=key;result.maps[#result.maps+1]=map;result.counts[key]=(result.counts[key] or 0)+live.stack end
            local token=table.concat({tostring(live.identity),tostring(live.grade),tostring(live.stack),key or ""},"/")
            result.entries[slot]={token=token,map=map};result.tokens[#result.tokens+1]=token
            sig[#sig+1]=slot..":"..token;result.occupied=result.occupied+1
        end
    end
    table.sort(result.tokens);table.sort(sig)
    result.signature=table.concat(sig,"\n");result.contents=table.concat(result.tokens,"\n")
    return result
end
function I:Pack(scan)
    local grouped={}
    for _,map in ipairs(scan.maps)do
        local key=Key(map);local row=grouped[key]
        if not row then row=Copy(map);row.count=0;grouped[key]=row end
        row.count=row.count+map.count
        if map.zoneGroupId and not row.zoneConflict then
            if not row.zoneGroupId then row.zoneGroupId=map.zoneGroupId
            elseif row.zoneGroupId~=map.zoneGroupId then row.zoneGroupId=nil;row.zoneConflict=true end
        end
    end
    local keys={};for key in pairs(grouped)do keys[#keys+1]=key end;table.sort(keys)
    local box={records=#keys,chunks={},stamp=Stamp()};local chunk=""
    for _,key in ipairs(keys)do
        local m=grouped[key]
        local line=string.format("%.17g|%.17g|%d|%d|%s\n",m.worldX,m.worldY,m.zoneGroupId or 0,m.count,m.text)
        if #chunk+#line>1024 then box.chunks[#box.chunks+1]=chunk;chunk="" end
        chunk=chunk..line
    end
    if chunk~="" then box.chunks[#box.chunks+1]=chunk end
    return box
end
function I:RegisterCoffer(id,startRound)
    id=BoxId(id);if not id then return false,"本轮识别记录编号无效或已达存档容量，请重新统计" end
    if not F.enabled then return false,"寻宝功能已关闭" end
    if self.job then return false,"请先停止取图，再登记箱子" end
    local session=self.cofferSession
    local scan,err=self:Scan("coffer");if not scan then self.lastError=err;return false,err end
    local ok,content=self:Window();if not ok then return false,content end
    if session~=self.cofferSession then return false,"识别期间保管箱已关闭或切换，请重新识别" end
    local saved,why=self:Commit("treasure_coffer_register",function(state)
        -- 首次识别将旧箱号记录清空与新快照同一次耐久保存；扫描/保存失败仍保留原记录。
        if startRound==true then state.boxes={};state.pendingCoffer=nil;state.scanRound=true end
        state.boxes[id]=self:Pack(scan);if state.pendingCoffer==id then state.pendingCoffer=nil end
    end)
    if not saved then return false,why end
    -- 保存可同步触发原生事件；快照仍属于刚才的箱，不能把其取图权/记录号绑定给之后打开的箱。
    if session==self.cofferSession then
        self.bound={id=id,signature=scan.signature,content=content};self.openRecord={id=id,content=content}
    end
    self.lastError=nil
    if startRound==true and A.selected and A.selected.kind=="catalog" and not self.byKey[Key(A.selected)] then F:StopTracking()end
    Publish("treasure_coffer_registered");return true
end
function I:IdentifyCurrentCoffer()
    if not F.enabled then return false,"寻宝功能已关闭" end
    if self.job then return false,"请先停止取图，再识别当前保管箱" end
    local ok=self:Initialize();if not ok then return false,"箱子记录读取失败，请在设置中重新统计保管箱" end
    local startRound=self.State.scanRound~=true
    local nextId=1
    if not startRound then
        local open,content=self:Window();if not open then self:EndCofferInteraction("window_closed");return false,content end
        if self.openRecord and self.openRecord.content~=nil and self.openRecord.content~=content then self:EndCofferInteraction("window_changed")end
        if self.openRecord and self.State.boxes[self.openRecord.id] then nextId=tonumber(self.openRecord.id)
        else for id in pairs(self.State.boxes)do nextId=math.max(nextId,tonumber(id)+1)end end
    end
    -- 只复用尚未结束的开箱交互；不同交互即使内容完全相同也分别计数，不按签名合并物理箱。
    return self:RegisterCoffer(nextId,startRound)
end
function I:ResetCofferRound()
    if not F.enabled then return false,"寻宝功能已关闭" end
    if self.job then return false,"请先停止取图，再重新统计" end
    local ready=self:Initialize()
    local ok,err
    if ready then
        ok,err=self:Commit("treasure_coffer_round_reset",function(state)
            state.boxes={};state.pendingCoffer=nil;state.scanRound=true
        end)
    else
        -- 重载后被隔离的截断快照不能按“已读”使用，也不能自动清空。仅用户点击清空时完整替换此组件自己的Store；
        -- 归属/版本/故障类型只由 Core 授权，禁止 UI 用宽泛 envelope 前缀把身份不符误认作可丢弃损坏。
        -- 同一角色有完整 metadata 证据的内容损坏可重建；另一角色、未知归属、未来格式和暂时读失败继续拒绝。
        -- 查询不读盘不清隔离；实际 SaveValue 仍重新检查当前 scope、预算和授权，并立即回读，成功才应用新轮。
        local replaceable,replaceErr=P:CanReplaceCorrupt(self.storeId)
        if replaceable~=true then return false,replaceErr or self.lastError or "箱子记录尚不可安全重置" end
        local fresh=Normalize(nil);fresh.scanRound=true
        ok,err=P:SaveValue(self.storeId,fresh,{replaceCorrupt=true,allowUnloadedWrite=true,durable=true,reason="treasure_coffer_round_reset_corrupt"})
        if ok then self.State=fresh;self.loaded=true;self:RebuildGroups()else self.lastError=tostring(err or "箱子记录重置失败")end
    end
    if not ok then return false,err end
    self.bound=nil;self.openRecord=nil;self.lastError=nil;self.withdraw={status="idle",moved=0}
    if A.selected and A.selected.kind=="catalog" then F:StopTracking()end
    Publish("treasure_coffer_round_reset");return true
end
function I:SetFilter(value)
    if not F.enabled or not LABEL[value] then return false,"大陆分类无效" end
    local ok,err=self:Commit("treasure_continent_filter",function(state)state.filter=value end)
    if ok then Publish("treasure_continent_filter")end;return ok,err
end
function I:SetContinent(key,value)
    if not F.enabled or not self.byKey[key] or (value~="auto" and (not LABEL[value] or value=="all")) then return false,"请先选择坐标和有效分类" end
    local ok,err=self:Commit("treasure_continent_assign",function(state)state.overrides[key]=value~="auto" and value or nil end)
    if ok then Publish("treasure_continent_assign")end;return ok,err
end
function I:Stop(status,err)
    local job=self.job
    if S.Scheduler then S.Scheduler:RemoveTask(TASK)end
    if job then self.withdraw={status=status or "cancelled",moved=job.moved,limit=job.limit,error=err,boxId=job.boxId}end
    self.job=nil
    if status~="done" then self.bound=nil end
    if err then self.lastError=tostring(err)end
    self:RebuildGroups();Publish("treasure_withdraw_"..tostring(status));return true
end
function I:Withdraw(id,key,limit)
    id=BoxId(id);limit=Integer(limit,0,self.maxSlots)
    if not F.enabled then return false,"寻宝功能已关闭" end
    if self.job then return false,"取图正在进行" end
    if not id or not limit or not self.byKey[key] then return false,"请选择有效坐标和取图数量" end
    if not self.bound or self.bound.id~=id or self.State.pendingCoffer then return false,"请先识别本次打开的保管箱；有未确认移动时请重新统计" end
    local binding=self.bound
    local scan,err=self:Scan("coffer");if not scan then return false,err end
    if self.bound~=binding then return false,"取图检查期间保管箱已关闭或切换，请重新识别" end
    if scan.signature~=self.bound.signature then self.bound=nil;return false,"箱内物品已变化，请重新统计后逐箱识别" end
    local n=scan.counts[key] or 0;if n==0 then return false,"当前箱子没有该坐标的藏宝图" end
    if not S.Scheduler or type(S.Scheduler.AddTask)~="function" then return false,"取图调度不可用" end
    local job={boxId=id,key=key,limit=limit==0 and n or math.min(limit,n),moved=0,started=Now(),generation=S.Generation}
    self.job=job;self.withdraw={status="running",moved=0,limit=job.limit,boxId=id};self.lastError=nil
    local ok,why=S.Scheduler:AddTask(TASK,250,function()return self:Step(job)end,false,F,"P2",1)
    if ok~=true then self.job=nil;self.withdraw.status="failed";return false,why or "取图任务创建失败" end
    if type(S.Scheduler.SetTaskModule)=="function" then S.Scheduler:SetTaskModule(TASK,F.Id,true)end
    Publish("treasure_withdraw_started");return true
end
function I:Step(job)
    if self.job~=job then return true end
    if not F.enabled or S.Generation~=job.generation or (F.consumerCount or 0)<=0 then return self:Stop("cancelled","寻宝已关闭或界面已退出")end
    local open,content=self:Window()
    if not open or not self.bound or (self.bound.content~=nil and content~=self.bound.content) then return self:Stop("failed","箱子已关闭或切换，请重新登记")end
    local coffer,err=self:Scan("coffer");if not coffer then return self:Stop("failed",err)end
    if self.job~=job or not self.bound then return true end
    local bag;bag,err=self:Scan("bag");if not bag then return self:Stop("failed",err)end
    if self.job~=job or not self.bound then return true end
    local pending=job.pending
    if pending then
        local sourceDelta=pending.sourceCount-(coffer.counts[job.key] or 0)
        local bagDelta=(bag.counts[job.key] or 0)-pending.bagCount
        if sourceDelta==pending.count and bagDelta==pending.count and coffer.contents==pending.expectedContents then
            job.moved=job.moved+pending.count;job.pending=nil
            job.started=Now() -- 只限制无进展等待；大箱子批量取图不被整批30秒截断。
            local saved,why=self:Commit("treasure_coffer_withdraw_confirm",function(state)state.boxes[job.boxId]=self:Pack(coffer);state.pendingCoffer=nil end)
            A:Refresh()
            if not saved then return self:Stop("failed","物品已取出，但箱子记录保存失败："..tostring(why))end
            if self.job~=job or not self.bound then return true end -- 确认保存/背包刷新也可能同步结束原开箱交互。
            self.bound.signature=coffer.signature;self.withdraw.moved=job.moved
            if job.moved>=job.limit then return self:Stop("done")end
            Publish("treasure_withdraw_confirmed");return true
        end
        if coffer.signature~=pending.beforeSignature and coffer.contents~=pending.expectedContents then return self:Stop("failed","箱内内容发生额外变化，已停止取图")end
        if Now()-pending.at>=3000 then return self:Stop("failed","取图反馈超时；本箱待重新登记核对")end
        return true -- 已发出的移动只观察，不重发。
    end
    if Now()-job.started>=30000 then return self:Stop("failed","取图等待超过30秒，已停止")end
    if coffer.signature~=self.bound.signature then return self:Stop("failed","箱内物品已变化，请重新统计后逐箱识别")end
    if bag.occupied>=bag.capacity then return self:Stop("failed","背包已满")end
    local map
    for _,candidate in ipairs(coffer.maps)do if candidate.groupKey==job.key and candidate.count<=job.limit-job.moved then map=candidate;break end end
    if not map then return self:Stop("failed","没有符合数量的整槽藏宝图；无法拆分该槽")end
    local cooldown=S.Api.GetCapabilityCooldownState and S.Api:GetCapabilityCooldownState("X2Coffer:MoveToEmptyBagSlot")
    if cooldown and (tonumber(cooldown.remainingMs) or 0)>0 then return true end
    local saved,why=self:Commit("treasure_coffer_withdraw_intent",function(state)state.pendingCoffer=job.boxId end)
    if not saved then return self:Stop("failed",why)end
    if self.job~=job or not F.enabled then return true end
    -- 耐久保存可能触发同步回调；写入前再次核对，不能让保存前的槽号跨过这条边界。
    local recheck,recheckErr=self:Scan("coffer")
    if self.job~=job or not self.bound then return true end -- 扫描期间收到切箱事件，旧槽位不再有写入权。
    if not recheck or recheck.signature~=coffer.signature then
        self:Commit("treasure_coffer_withdraw_not_sent",function(state)state.pendingCoffer=nil end)
        return self:Stop("failed",recheckErr or "保存期间箱内物品发生变化，未发送取图")
    end
    local tokens,removed={},false
    for _,token in ipairs(coffer.tokens)do if not removed and token==coffer.entries[map.slot].token then removed=true else tokens[#tokens+1]=token end end
    job.pending={count=map.count,sourceCount=coffer.counts[job.key] or 0,bagCount=bag.counts[job.key] or 0,
        expectedContents=table.concat(tokens,"\n"),beforeSignature=coffer.signature,at=Now()}
    local ok,moveErr=Action("X2Coffer:MoveToEmptyBagSlot",nil,"MoveToEmptyBagSlot",map.slot)
    if ok~=true then
        self:Commit("treasure_coffer_withdraw_rejected",function(state)state.pendingCoffer=nil end)
        return self:Stop("failed",tostring(moveErr or "游戏拒绝取图"))
    end
    return true
end
function I:Decorate(p)
    p.inventoryContractVersion=1;p.withdraw=Copy(self.withdraw);p.boundCofferId=self.bound and self.bound.id
    p.inventoryUncertain=self.State.pendingCoffer~=nil;p.inventoryError=self.lastError
    p.scannedCofferCount=#(self.boxIds or {});p.sharedCoordinateCount=self.sharedCoordinateCount or 0
    p.cofferRoundStarted=self.State.scanRound==true
    p.coffers=Copy(self.cofferSummaries or {});p.sortMode=self.State.sort
    p.inventoryHint="本轮已识别 "..p.scannedCofferCount.." 箱 · 跨箱同坐标 "..p.sharedCoordinateCount.." 处 · 同箱重复识别更新记录"
    if not p.cofferRoundStarted then p.inventoryHint="打开保管箱后点击识别，自动清空旧登记并开始本轮统计。" end
    if p.inventoryUncertain then p.inventoryHint="记录"..self.State.pendingCoffer.."有未确认移动，未计入总量；请重新统计后逐箱识别。" end
    if not self.loaded then p.inventoryHint="保管箱记录读取失败，未计入箱内数量；请在设置中点击重新统计。" end
    if A.status=="unavailable" or A.inventoryError then p.inventoryHint="背包读取不可用，展示最后记录；"..p.inventoryHint end
    if p.viewKind~="maps" then return p end
    p.region=self.State.filter;p.regionItems={}
    for _,key in ipairs({"all","auroria","west","east","sea","unknown"})do p.regionItems[#p.regionItems+1]={value=key,text=LABEL[key]}end
    p.rows={};p.totalMapCount=0;p.coordinateCount=#self.rows
    for _,row in ipairs(self.rows)do
        p.totalMapCount=p.totalMapCount+row.count
        if self.State.filter=="all" or row.continent==self.State.filter then
            local r=Copy(row)
            if p.playerX and p.playerY then local dx,dy=r.worldX-p.playerX,r.worldY-p.playerY
                r.distance=math.sqrt(dx*dx+dy*dy);r.direction=math.abs(dx)>=math.abs(dy) and (dx>=0 and "东" or "西") or (dy>=0 and "北" or "南")end
            p.rows[#p.rows+1]=r
        end
    end
    if #p.rows>0 and p.status=="empty" then p.status="ready" end
    if p.selected and p.selected.kind~="ships" and p.selected.kind~="seabugs" then
        local key=Key(p.selected);p.selected.key=key;p.selected.groupKey=key
        local group=self.byKey[key];if group then p.selected.count=group.count;p.selected.continent=group.continent;p.selected.boxes=Copy(group.boxes)end
    end
    return p
end

-- 组件只装配到同一个 Feature；旧 Store/物理图选择身份与海上逻辑继续由原实现拥有。
local initialize,projection,select,region,disable,reconcile,check,health,viewKind=
    F.Initialize,A.GetProjection,F.Select,F.SetRegion,F.Disable,F.ReconcileDemand,A.CheckInventory,F.GetHealth,F.SetViewKind
function F:Initialize()
    local ok,err=initialize(self);if ok~=true then return false,err end
    -- 可再生的箱子记录损坏只隔离本组件；保留寻宝界面和显式重新统计入口，不能把整个Feature锁死在初始化失败。
    if I:Initialize()~=true then I:RebuildGroups()end
    return true
end
function A:GetProjection()
    -- 先按当前角色准备库存，再让原投影复制 selection；否则上一角色目录选择和数量会进入新角色页面。
    I:Initialize()
    return I:Decorate(projection(self))
end
function F:Select(key)
    local group=I.byKey[key];if not group then return select(self,key)end
    if not self.enabled then return false,"寻宝功能已关闭" end
    for _,map in ipairs(A.maps)do if Key(map)==key then return select(self,map.key)end end
    self:CancelPendingMapAction();A.selected=Copy(group);A.selected.kind="catalog";A.stopped=false;A.status="ready"
    A:UpdatePosition();Publish("treasure_catalog_select");return true
end
function F:SetRegion(value)if A.viewKind=="maps" then return I:SetFilter(value)end;return region(self,value)end
function F:SetViewKind(value)if value~="maps" and I.job then I:Stop("cancelled","已切换寻宝分类")end;return viewKind(self,value)end
function F:Disable(reason)I:WatchCofferInteraction(false);return disable(self,reason)end
function F:ReconcileDemand(lease,before,after)
    local active=(tonumber(after and after.count) or 0)>0
    if not active then I:WatchCofferInteraction(false)end
    local ok,err=reconcile(self,lease,before,after)
    if ok==true and active then I:WatchCofferInteraction(true)end
    return ok,err
end
function A:CheckInventory()
    if I.openRecord or I.bound then local ok,content=I:Window()
        if not ok or (I.openRecord and I.openRecord.content~=nil and content~=I.openRecord.content)then I:EndCofferInteraction("window_closed_or_changed")end
    end
    if self.selected and self.selected.kind=="catalog" then if Now()-(self.lastInventoryScanAt or 0)>=3000 then return self:Refresh()end;return true end
    return check(self)
end
function F:GetHealth()local p=health(self);p.inventory={storeId=I.storeId,loaded=I.loaded==true,coordinateCount=#I.rows,
    scannedCofferCount=#(I.boxIds or {}),sharedCoordinateCount=I.sharedCoordinateCount or 0,scanRound=I.State.scanRound==true,
    cofferEventChannels=Copy(I.cofferEventChannels),cofferEventCount=I.cofferEventCount or 0,cofferSession=I.cofferSession or 0,
    openRecordId=I.openRecord and I.openRecord.id,lastCofferBoundary=I.lastCofferBoundary,
    boundCofferId=I.bound and I.bound.id,pendingCoffer=I.State.pendingCoffer,withdraw=Copy(I.withdraw),lastError=I.lastError};return p end
F.Commands.RegisterCoffer=function(_,id)return I:RegisterCoffer(id)end
F.Commands.IdentifyCurrentCoffer=function()return I:IdentifyCurrentCoffer()end
F.Commands.ResetCofferRound=function()return I:ResetCofferRound()end
F.Commands.WithdrawCoordinate=function(_,id,key,limit)return I:Withdraw(id,key,limit)end
F.Commands.CancelWithdrawal=function()return I:Stop("cancelled")end
F.Commands.SetCoordinateContinent=function(_,key,value)return I:SetContinent(key,value)end
F.Commands.SetInventorySort=function(_,value)
    if not F.enabled or (value~="count" and value~="coordinate")then return false,"排序方式无效" end
    local ok,err=I:Commit("treasure_inventory_sort",function(state)state.sort=value end)
    if ok then Publish("treasure_inventory_sort")end;return ok,err
end
for _,cap in ipairs({"X2Coffer:GetBagItemInfo","X2Coffer:Capacity","X2Coffer:MoveToEmptyBagSlot","ADDON:GetContent","ADDON:GetContentMainScriptPosVis"})do
    F.ApiDependencies[#F.ApiDependencies+1]=cap
end
