-- Replicated Suite · 生活经济悬浮组件
-- 作者：Replicated
-- QQ群：1104129461
-- Trade/Bonds/Treasure/Fishing 是独立 FloatingSurface Consumer；页面关闭后 HUD 可继续运行，关闭 HUD 仅释放自身 Demand token；
-- 表现层不持有轮询/Tick。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
local Host = S.UIV3 and S.UIV3.WidgetHost or nil
local Floating = RSUI and RSUI.FloatingSurface or nil
if type(RSUI) ~= "table" or type(Host) ~= "table" or type(Floating) ~= "table" then return end

local function ZoneItems(rows)
    local out = {}
    for _, row in ipairs(type(rows) == "table" and rows or {}) do
        out[#out + 1] = { value = row.id, text = tostring(row.displayName or row.name or ("地区 " .. tostring(row.id or "?"))) }
    end
    return out
end

local function FindZoneName(projection, id)
    id = tonumber(id)
    if id == nil then return "--" end
    for _, list in ipairs({ projection and projection.zones or {}, projection and projection.sellableZones or {} }) do
        for _, row in ipairs(list) do
            if tonumber(row.id) == id then return tostring(row.name or row.displayName or id) end
        end
    end
    return tostring(id)
end

-- 与主页面共用业务值，各实例独立创建 Dropdown，不重设 Native 父级。
local BOND_ORDER_ITEMS = {
    { value = "continent:west_first", text = "按大陆 · 西→东" },
    { value = "continent:east_first", text = "按大陆 · 东→西" },
    { value = "quantity:west_first", text = "按数量 · 少→多" },
    { value = "quantity:east_first", text = "按数量 · 多→少" },
    { value = "material:west_first", text = "按材料 · 正序" },
    { value = "material:east_first", text = "按材料 · 倒序" },
}
local function BondScopeLabel(mask)
    if mask == 15 then return "全部 · 20/60/100/原陆" end
    if mask == 7 then return "主大陆 · 20/60/100" end
    if mask == 8 then return "仅原大陆" end
    if mask == 0 then return "全部关闭" end
    local parts = {}
    if mask % 2 >= 1 then parts[#parts + 1] = "20" end
    if math.floor(mask / 2) % 2 >= 1 then parts[#parts + 1] = "60" end
    if math.floor(mask / 4) % 2 >= 1 then parts[#parts + 1] = "100" end
    if math.floor(mask / 8) % 2 >= 1 then parts[#parts + 1] = "原陆" end
    return "筛选 · " .. table.concat(parts, "+")
end
local BOND_SCOPE_ITEMS = {}
for _, mask in ipairs({ 15, 7, 8, 1, 2, 4, 3, 5, 6, 9, 10, 12, 11, 13, 14, 0 }) do
    BOND_SCOPE_ITEMS[#BOND_SCOPE_ITEMS + 1] = { value = mask, text = BondScopeLabel(mask) }
end
local BOND_DUPLICATE_ITEMS = {
    { value = "all", text = "重复 · 全部" },
    { value = "west", text = "重复 · 留西" },
    { value = "east", text = "重复 · 留东" },
}

-- 独立债券窗在原设置行并排显示范围、排序、重复材料。
-- 短文案适配窄窗；业务 value 与首页设置表单完全一致，选项仅在脚本加载时生成。
local BOND_TOOLBAR_ORDER_ITEMS = {}
for _, item in ipairs(BOND_ORDER_ITEMS) do
    BOND_TOOLBAR_ORDER_ITEMS[#BOND_TOOLBAR_ORDER_ITEMS + 1] = {
        value = item.value, text = item.text:gsub("^按", ""):gsub(" · ", "·"),
    }
end
local BOND_TOOLBAR_SCOPE_ITEMS = {}
local BOND_TOOLBAR_SCOPE_LABELS = { [15] = "范围·全部", [7] = "范围·主陆", [8] = "范围·原陆", [0] = "范围·关闭" }
for _, item in ipairs(BOND_SCOPE_ITEMS) do
    BOND_TOOLBAR_SCOPE_ITEMS[#BOND_TOOLBAR_SCOPE_ITEMS + 1] = {
        value = item.value, text = BOND_TOOLBAR_SCOPE_LABELS[item.value] or item.text:gsub("^筛选 · ", ""):gsub("%+", "/"),
    }
end

-- 页面与悬浮窗共用内容构建器而非Reparent原生窗口。
-- 每个实例独立id/owner/控件，Feature投影/Command唯一，构建和刷新绝不发出材料询价。
local Contents={specs={}}
S.UIV3.LifeEconomyContent=Contents
-- 主页面和助手共用同一双击门控，瞬时点击状态只属于各自UI实例。
local TreasureMapInteraction = { version = 2, hint = "双击目标，在原生地图显示箭头" }
S.UIV3.TreasureMapInteraction = TreasureMapInteraction
function TreasureMapInteraction:Reset(instance)
    instance.treasureLastActivateKey, instance.treasureLastActivateAt = nil, nil
    return true
end
function TreasureMapInteraction:SyncSelection(view, projection)
    local key = type(projection.selected) == "table" and projection.selected.key or nil
    for index = 1, view:GetItemCount() do
        local row = view:GetItem(index)
        if key ~= nil and row and row.key == key then view:SetSelectedIndex(index);return true end
    end
    view:ClearSelection()
    return true
end
function TreasureMapInteraction:Activate(instance, row, Feature)
    if type(row) ~= "table" or row.key == nil then self:Reset(instance);return false, "追踪目标已失效" end
    if S.FeatureRuntime:IsEnabled(Feature.Id) ~= true then self:Reset(instance);return false, "寻宝功能已关闭" end
    local now = type(S.NowMs) == "function" and tonumber(S.NowMs()) or nil
    if now == nil then self:Reset(instance);return false, "双击计时不可用" end
    local previousAt = tonumber(instance.treasureLastActivateAt)
    local isDouble = instance.treasureLastActivateKey == tostring(row.key) and previousAt ~= nil
        and now >= previousAt and now - previousAt <= 450
    -- 每次真实点击都走同一选择命令，不能依赖某个视图的旧高亮状态。
    -- 先确认选择成功，再记录点击；失败恢复后的下一击不能误判为双击。
    local selected, selectErr = Feature.Commands:Select(row.key)
    instance.treasureActionError = selected ~= true and tostring(selectErr or "选择目标失败") or nil
    instance:Refresh()
    if selected ~= true then self:Reset(instance);return false, selectErr end
    instance.treasureLastActivateKey, instance.treasureLastActivateAt = tostring(row.key), now
    if not isDouble then return true end
    self:Reset(instance)
    local opened, openErr = Feature.Commands:ShowSelectedOnMap()
    instance:Refresh()
    return opened, openErr
end
-- 首页标题栏保留单入口；首次点击才创建独立字段表单，复用 FloatingSurface/Dropdown 的原生生命周期。
-- 子 Dropdown 继续由 PopupCoordinator 管理，父表单不注册为 Dropdown，避免打开选项时把表单关掉。
-- 表单只读 Feature 投影并分派原有 Command；不增加消费者、询价任务或业务设置副本。
local function CloseSettingsChoices(instance)
    if instance.treasureCustomControls then instance.treasureCustomControls:ClosePopups()end
    local panel=instance.headerSettings
    for _,control in ipairs(panel and panel.choices or {})do if control.open then control:Close()end end
    for _,key in ipairs({"bondScopeDropdown","bondOrderDropdown","bondDuplicateDropdown","treasureKindDropdown","treasureRegionDropdown","treasureSettingsDropdown"})do
        local control=instance[key];if control and control.open then control:Close()end
    end
    return true
end
local function SettingsRow(panel,key,title)
    local row=RSUI:HorizontalBox({id=panel.prefix..key..'_row',parent=panel.body,gap=6,
        slot={size='fixed',height=28,hAlign='fill'}})
    RSUI:Text({id=panel.prefix..key..'_label',parent=row,text=title,fontSize=10,tone='muted',
        slot={size='fixed',width=64,vAlign='fill'}})
    return row
end
local function SettingsChoice(panel,key,title,items,get,set)
    local control=RSUI:Dropdown({id=panel.prefix..key,parent=SettingsRow(panel,key,title),items=items or {},
        placeholder='请选择',maxVisible=8,popupWidth=300,get=get,set=set,
        slot={size='fill',fill=1,minWidth=100,hAlign='fill'}})
    if control then panel.choices[#panel.choices+1]=control end
    return control
end
local function ApplySettingsCommand(instance,Feature,command,...)
    local fn=Feature.Commands[command]
    local ok,err
    if type(fn)=='function'then ok,err=fn(Feature.Commands,...)else ok,err=false,'设置命令不可用'end
    if ok==true then instance:Refresh()end
    local panel=instance.headerSettings
    if panel then panel.surface:SetStatus(ok==true and '设置已生效' or tostring(err or '设置未保存'),ok==true and 'muted' or 'yellow')end
    return ok,err
end
local function BuildTradeSettings(instance,panel,Feature)
    local controls=panel.controls
    -- 本次设置窗刷新共享一个 detached 投影，
    -- 下拉框 get 不再反复复制全部路线/材料；动作校验仍由 Feature Commands 实时负责。
    local function Projection()return panel.controlProjection or Feature:GetProjection() or {}end
    local function RouteCommand(command,value)
        if Projection().viewMode=='cargo'then return false,'请先切换到全部或关注货物'end
        return ApplySettingsCommand(instance,Feature,command,value)
    end
    controls.fromDropdown=SettingsChoice(panel,'from','起始地',{},function()return Projection().fromZone end,
        function(value)return RouteCommand('SetFrom',value)end)
    controls.toDropdown=SettingsChoice(panel,'to','目的地',{},function()return Projection().toZone end,
        function(value)return RouteCommand('SetTo',value)end)
    controls.favoriteDropdown=SettingsChoice(panel,'favorite','收藏路线',{},function()return Projection().currentFavoriteKey end,
        function(value)return RouteCommand('SelectFavorite',value)end)
    controls.viewSelector=RSUI:SegmentedSelector({id=panel.prefix..'view_mode',parent=SettingsRow(panel,'view','显示货物'),
        items={{value='all',text='全部'},{value='tracked',text='关注'},{value='cargo',text='随身'}},itemWidth=58,height=26,gap=3,
        get=function()return Projection().viewMode or 'all'end,
        set=function(value)return ApplySettingsCommand(instance,Feature,'SetViewMode',value)end,
        slot={size='fill',fill=1,hAlign='fill'}})
    -- 设置窗迁移时漏掉满货率入口；只切换既有 Authority 模式，本地重算售价/毛利，不发起服务器查询。
    controls.ratioSelector=RSUI:SegmentedSelector({id=panel.prefix..'ratio_mode',parent=SettingsRow(panel,'ratio','售价货率'),
        items={{value='current',text='实时货率'},{value='full',text='满货率 130%'}},itemWidth=96,height=26,gap=3,
        get=function()return Projection().ratioMode or 'current'end,
        set=function(value)return ApplySettingsCommand(instance,Feature,'SetRatioMode',value)end,
        slot={size='fill',fill=1,hAlign='fill'}})
    local actions=RSUI:HorizontalBox({id=panel.prefix..'actions',parent=panel.body,gap=5,slot={size='fixed',height=28,hAlign='fill'}})
    controls.refreshButton=RSUI:Button({id=panel.prefix..'refresh',parent=actions,text='刷新货率',compact=true,
        slot={size='fill',fill=1,minWidth=70},onClick=function()
            local p=Projection()
            if p.isRefreshing or p.viewMode~='cargo' and (p.fromZone==nil or p.toZone==nil)then return false,'路线未就绪'end
            return ApplySettingsCommand(instance,Feature,'Refresh','overview_manual')
        end})
    controls.favoriteButton=RSUI:Button({id=panel.prefix..'favorite_toggle',parent=actions,text='添加收藏',compact=true,
        slot={size='fill',fill=1,minWidth=70},onClick=function()return RouteCommand('ToggleCurrentFavorite')end})
    controls.trackButton=RSUI:Button({id=panel.prefix..'track',parent=actions,text='关注货物',compact=true,
        slot={size='fill',fill=1,minWidth=70},onClick=function()
            local row=type(Feature.GetSelectedRow)=='function' and Feature:GetSelectedRow() or nil
            if type(row)~='table' or row.key==nil then return false,'请先在首页选择一个货物'end
            return ApplySettingsCommand(instance,Feature,'ToggleTrackedProduct',row.itemType or row.key)
        end})
    panel.refresh=function(projection)
        panel.controlProjection=projection -- 每轮覆盖旧快照，配置窗口不持有第二份业务状态。
        Contents.specs.Trade.refreshControls(controls,projection,projection.rows or {},Feature)
        controls.refreshButton:SetEnabled(projection.isRefreshing~=true and (projection.viewMode=='cargo' or projection.fromZone~=nil and projection.toZone~=nil))
        controls.refreshButton:SetText(projection.isRefreshing and '刷新中' or '刷新货率')
        controls.ratioSelector:Render()
        return true
    end
    return controls.fromDropdown~=nil and controls.toDropdown~=nil and controls.favoriteDropdown~=nil
        and controls.viewSelector~=nil and controls.ratioSelector~=nil and controls.refreshButton~=nil and controls.favoriteButton~=nil and controls.trackButton~=nil
end
local function BuildBondSettings(instance,panel,Feature)
    local controls=panel.controls
    controls.orderDropdown=SettingsChoice(panel,'order','排序',BOND_ORDER_ITEMS,function()return Feature:GetDisplayOrderKey()end,
        function(value)
            local mode,order=tostring(value or ''):match('^([^:]+):(.+)$')
            if not mode or not order then return false,'债券排序设置无效'end
            return ApplySettingsCommand(instance,Feature,'SetDisplayOrder',mode,order)
        end)
    controls.scopeDropdown=SettingsChoice(panel,'scope','显示范围',BOND_SCOPE_ITEMS,function()return Feature:GetFilterMask()end,
        function(value)return ApplySettingsCommand(instance,Feature,'SetFilterMask',value)end)
    controls.duplicateDropdown=SettingsChoice(panel,'duplicate','重复材料',BOND_DUPLICATE_ITEMS,function()return Feature:GetDuplicateMode()end,
        function(value)return ApplySettingsCommand(instance,Feature,'SetDuplicateMode',value)end)
    panel.refresh=function()
        for _,control in ipairs(panel.choices)do control:Render()end
        return true
    end
    return controls.orderDropdown~=nil and controls.scopeDropdown~=nil and controls.duplicateDropdown~=nil
end
local function BuildSettingsHeader(instance,parent,Feature,name)
    instance.settingsButton=RSUI:Button({id=instance.contentPrefix..'settings',parent=parent,text='设置',compact=true,
        slot={size='fill',fill=1,hAlign='fill'},onClick=function()
            if instance.headerSettings and instance.headerSettings.surface.visible then return instance:CloseHeaderSettings()end
            local panel=instance.headerSettings
            if not panel then
                local prefix=instance.contentPrefix..'settings_'
                local aux=S.UIV3 and S.UIV3.AuxWindowStoreV3
                if not aux then return false,'辅助窗口布局存储不可用' end
                local layoutId=name=='Trade' and 'trade_settings' or 'bonds_settings'
                local state,loadErr=aux:GetWindowState(layoutId,prefix..'window')
                if not state then return false,loadErr end
                local surface,err=Floating:Create({id=prefix..'window',owner='v3:'..prefix,title=name=='Trade' and '贸易设置' or '债券设置',
                    movable=true,resizable=false,appearanceControls=false,footer=true,boundaryMode='free',defaultPlacement='center',
                    statePolicy=aux:GetPolicy(layoutId),
                    -- 首页与独立助手可打开同一种设置窗；每次从同一布局 Authority 读取，不能用旧实例副本恢复位置。
                    getState=function()return aux:GetWindowState(layoutId,prefix..'window') end,
                    setState=function(value,reason)return aux:SetWindowState(layoutId,value,reason) end,
                    persist=function(reason,delay)return aux:PersistWindow(layoutId,reason,delay) end,
                    onStateChanged=function(_,value)if value.minimized then CloseSettingsChoices(instance)end end,
                    onClosed=function()
                        if Contents.openHeaderSettings==instance then Contents.openHeaderSettings=nil end
                        return CloseSettingsChoices(instance)
                    end})
                if not surface then return false,err end
                panel={surface=surface,prefix=prefix,controls={},choices={}}
                instance.headerSettings=panel
                panel.body=RSUI:VerticalBox({id=prefix..'content',parent=surface:GetContentRoot(),gap=6,
                    slot={size='fill',fill=1,hAlign='fill',vAlign='fill'}})
                RSUI:Text({id=prefix..'help',parent=panel.body,fontSize=9,tone='muted',overflow='wrap',
                    text=name=='Trade' and '选择后立即生效；随身模式下不使用路线设置。' or '选择后立即生效，首页与债券页面同步。',
                    slot={size='fixed',height=28,hAlign='fill'}})
                local built=name=='Trade' and BuildTradeSettings(instance,panel,Feature) or name=='Bonds' and BuildBondSettings(instance,panel,Feature)
                if not built then
                    CloseSettingsChoices(instance);surface:Destroy();instance.headerSettings=nil
                    return false,'经济设置控件创建失败'
                end
            end
            if Contents.openHeaderSettings and Contents.openHeaderSettings~=instance then Contents.openHeaderSettings:CloseHeaderSettings()end
            panel.refresh(Feature:GetProjection() or {})
            panel.surface:SetStatus('选择后立即生效','muted')
            local minimized,minimizeErr=panel.surface:SetMinimized(false,false)
            if minimized~=true then return false,minimizeErr end
            local shown,showErr=panel.surface:Show(true)
            if shown==true then Contents.openHeaderSettings=instance else instance:CloseHeaderSettings()end
            return shown,showErr
        end})
    return instance.settingsButton~=nil,'经济标题栏设置创建失败'
end
local function RefreshSettingsHeader(instance,projection)
    local panel=instance.headerSettings
    if panel and panel.surface.visible then return panel.refresh(projection)end
    return true
end
local function BuildBody(instance,parent,spec,Feature)
        local content = RSUI:VerticalBox({ id = instance.contentPrefix .. "content", parent = parent, gap = instance.headerMode and 2 or 4,
            slot = { size="fill", fill=1, hAlign = "fill", vAlign = "fill" } }) -- 填满卡片余量，否则auto只给空表一行高度。
        instance.content=content
        if instance.headerMode and spec.featureName~="Treasure" then
            instance.controls=RSUI:HorizontalBox({id=instance.contentPrefix..'controls',parent=instance.headerParent,gap=0,slot={size='fixed',width=50,vAlign='fill'}})
        else instance.controls=RSUI:VerticalBox({id=instance.contentPrefix.."controls",parent=content,gap=3,slot={size="auto",hAlign="fill"}})end
        if type(spec.buildControls) == "function" then
            local controlsOk, controlsErr = spec.buildControls(instance, instance.controls, Feature)
            if controlsOk == false then return nil, controlsErr or (spec.title .. "悬浮窗控制条创建失败") end
        end
        -- 新增收藏行后，Trade 初始行池从 7 收到 6，抵消额外 Native 分配；滚动仍可访问完整数据。
        -- Bonds 三下拉共用 26px 行，保持 9 行初始池。
        local desiredRows = instance.overview and 6 or (spec.featureName == "Trade" and 6 or 10)
        if instance.overview ~= true and spec.featureName == "Bonds" then desiredRows = 9 end
        local overscanRows = spec.featureName == "Trade" and 0 or 1
        local columns = S.Utils.DeepCopy(spec.columns)
        if spec.featureName == "Trade" then
            for _, column in ipairs(columns) do
                if column.id == "detail" and type(column.onClick) == "function" then
                    local openDetail = column.onClick
                    column.onClick = function(...)
                        instance.tradeLastActivateKey, instance.tradeLastActivateAt = nil, 0
                        return openDetail(...)
                    end
                end
            end
        end
        instance.table = RSUI:TableView({
            id = instance.contentPrefix .. "table", parent = content, items = {}, rowHeight = instance.headerMode and 22 or instance.overview and 26 or 24, headerHeight = instance.headerMode and 20 or instance.overview and 26 or 23, desiredRows = desiredRows,
            rowFitMode = spec.featureName == "Trade" and "adaptive_tail" or "fixed", rowFitMin = instance.headerMode and 20 or instance.overview and 22 or 20, rowFitMax = instance.headerMode and 22 or instance.overview and 30 or 28,
            overscan = overscanRows, scrollbar = true, selectable = spec.selectable == true, selectionMode = "single", columnResize = true, headerInteractive = false,
            columns = columns, slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
        })
        if spec.selectable == true and type(spec.onSelection) == "function" then
            instance.table.onSelectionChanged = function(index)
                local row = instance.table:GetItem(index)
                return spec.onSelection(instance, row, Feature)
            end
        end
        if type(spec.onItemActivated) == "function" then
            -- TableView 回调为 (item,index,key,view,reason)。首参当索引曾在 mock 通过、实机取不到行；
            -- 直接使用 item，仅为旧调用保留 index 回退。
            instance.table.onItemActivated = function(item, index, key, view, reason)
                local row = item
                if type(row) ~= "table" and tonumber(index) ~= nil then row = instance.table:GetItem(index) end
                return spec.onItemActivated(instance, row, Feature, reason)
            end
        end

    return true
end
local function RefreshBody(self,spec,Feature)
            local projection = Feature:GetProjection() or {}
            self.controlProjection = projection -- 主页面、首页卡片与悬浮窗使用同一轮投影契约。
            local rows = type(spec.rows) == "function" and spec.rows(projection) or (projection.rows or {})
            rows = type(rows) == "table" and rows or {}
            self.table:SetItems(rows, projection.revision or 0, spec.featureName == "Trade") -- 仅 Trade 行承诺 revision 完整描述数据。
            -- 顶部控件同步单独隔离；某个 Dropdown 异常不能中断已取到的表格投影。
            -- 控件失败记模块诊断，表格和状态继续显示；投影、TableView 自身错误仍上报。
            local controlRefreshFailed, controlRefreshError = false, nil
            if type(spec.refreshControls) == "function" then
                local controlOk, controlResult, controlErr = xpcall(function()
                    return spec.refreshControls(self, projection, rows, Feature)
                end, S.SafeTraceback)
                if controlOk ~= true or controlResult == false then
                    controlRefreshFailed = true
                    controlRefreshError = controlOk and controlErr or controlResult
                    local diagnostics = S.DiagnosticsManager
                    if type(diagnostics) == "table" and type(diagnostics.WarnRateLimited) == "function" then
                        diagnostics:WarnRateLimited("ui_v3", "LIFE_WIDGET_CONTROL_REFRESH_FAILED", 3000,
                            spec.title .. "悬浮窗顶部控件同步失败；数据表继续显示现有投影", {
                                featureId = tostring(spec.featureId or ""), widgetId = tostring(spec.widgetId or ""),
                                phase = "refresh_controls", error = tostring(controlRefreshError or "unknown"),
                            })
                    end
                end
            end
            if projection.status == "unavailable" or projection.status == "error" then
                self.table:SetViewState("unavailable", { title = spec.title .. "数据不可用", detail = tostring(projection.error or "事实读取失败") })
            elseif spec.featureName == "Trade" and projection.status == "loading" and #rows == 0 then
                -- 货率查询等待异步 Native 事件，loading 不能显示“暂无货率”，否则容易诱发重复点击并撞冷却。
                self.table:SetViewState("empty", { title = "正在查询货率", detail = "等待服务器返回货率；无需连续点击刷新。" })
            elseif spec.featureName == "Trade" and projection.status == "cooldown" and #rows == 0 then
                local remaining = math.max(0, tonumber(projection.cooldownRemainingMs) or 0)
                self.table:SetViewState("empty", { title = "等待服务器查询冷却", detail = "约 " .. tostring(math.ceil(remaining / 1000)) .. " 秒后自动重试。" })
            elseif spec.featureName == "Trade" and projection.viewMode == "cargo" and #rows == 0 then
                local cargo = projection.cargo or {}
                local title = cargo.status == "not_trade" and "背部不是已识别贸易品" or (cargo.status == "empty" and "当前没有背负贸易品" or "随身贸易品暂无目的地货率")
                self.table:SetViewState("empty", { title = title, detail = tostring(cargo.error or "背上贸易包后会自动识别，并串行刷新可售目的地。") })
            elseif spec.featureName == "Trade" and projection.viewMode == "tracked" and #rows == 0 then
                -- 空的“关注货物”不能伪装成“暂无货率”，否则新用户不知道如何产生数据。
                self.table:SetViewState("empty", { title = "还没有关注货物", detail = "切回“当前路线全部货物”，单击选择一行后点“关注货物”。" })
            elseif spec.featureName == "Bonds" and #rows == 0 and projection.filterHint then
                self.table:SetViewState("empty", { title = "已缓存的债券被筛选隐藏", detail = projection.filterHint })
            elseif #rows == 0 then
                self.table:SetViewState("empty", { title = spec.emptyTitle, detail = spec.emptyDetail })
            else
                self.table:SetViewState("ready")
            end
            -- 首页仅压缩重复说明；保留来源错误，报价 Authority 仍在共享 Feature。
            local statusText = spec.status(projection, rows)
            if self.overview and spec.featureName == "Trade" then
                local batch = projection.quoteBatch or {}
                local activeJobs = tonumber((projection.quoteJobs or {}).activeCount) or tonumber(batch.activeJobs) or 0
                statusText = tostring(#rows) .. " 种货物 · 待询价 " .. tostring(projection.pendingQuoteCount or 0)
                    .. (batch.active and (" · " .. tostring(activeJobs) .. " 个货物询价中 · 材料 " .. tostring(batch.completed or 0) .. "/" .. tostring(batch.total or 0))
                        or (" · 可同时加入多个货物"))
                if projection.status == "error" or projection.status == "unavailable" then statusText=tostring(projection.error or "货率读取失败") end
            end
            -- 首页/悬浮窗都通过 Feature 投影呈现暂停，
            -- 不再把“等待玩家关拍卖行”显示成持续询价；保留来源错误的更高显示优先级。
            local activity = projection.quoteActivity
            if spec.featureName == "Trade" and type(activity) == "table" and activity.paused == true
                and projection.status ~= "error" and projection.status ~= "unavailable" then
                statusText = tostring(activity.text or "材料名称查询已暂停")
            end
            local statusTone = projection.status == "ready" and "accent" or (projection.status == "loading" and "yellow" or "muted")
            if controlRefreshFailed then
                statusText = tostring(statusText or "数据已更新") .. " · 顶部控件同步异常"
                statusTone = "yellow"
            end
            self.surface:SetStatus(statusText, statusTone)
            return true
        end

-- overview 仅是显示密度，不持有额外消费者、报价缓存或保存副本。
-- 同一查询按钮在首页批次进行中可取消；高级搜索继续留在完整页面/原悬浮窗。
function Contents:Create(parent,name,prefix,options)
    local spec=self.specs[name];local Feature=S.Features and S.Features[name]
    if not spec or not Feature then return nil,"经济内容不可用："..tostring(name) end
    options=options or {}
    local instance={contentPrefix=prefix,visible=true,overview=options.overview==true,headerParent=options.headerParent,
        headerMode=options.overview==true and options.headerParent~=nil}
    local ok,err=BuildBody(instance,parent,spec,Feature);if not ok then return nil,err end
    local status=RSUI:Text({id=prefix.."status",parent=instance.content,text="--",fontSize=9,tone="muted",overflow="ellipsis",slot={size="fixed",height=instance.headerMode and 16 or 18}})
    instance.statusLabel=status
    instance.surface={SetStatus=function(_,v)status:SetText(v);return true end}
    function instance:Refresh()return RefreshBody(self,spec,Feature)end
    function instance:CloseHeaderSettings()
        CloseSettingsChoices(self)
        if self.headerSettings and self.headerSettings.surface.visible then self.headerSettings.surface:Close('home_exit')end
        if Contents.openHeaderSettings==self then Contents.openHeaderSettings=nil end
        for _,key in ipairs({'tradeSettingsDropdown','treasureKindDropdown','treasureRegionDropdown','treasureSettingsDropdown'})do
            local dropdown=self[key];if dropdown and dropdown.open==true then dropdown:Close()end
        end
        return true
    end
    function instance:DisposeHeaderSettings()
        self:CloseHeaderSettings()
        if self.headerSettings then self.headerSettings.surface:Destroy();self.headerSettings=nil end
        return true
    end
    function instance:SetAvailable(available,reason)
        if not available then self:CloseHeaderSettings();TreasureMapInteraction:Reset(self)end
        self.controls:SetVisible(available)
        if available then return self:Refresh() end
        self.table:SetItems({},"unavailable");self.table:SetViewState("empty",{title=reason or "未启用",detail="点击右上角打开功能页面；首页不会自动启用模块。"})
        status:SetText(reason or "未启用");return true
    end
    return instance
end

local function Register(spec)
    local featureId = tostring(spec.featureId or "")
    if featureId == "" then return false, "生活悬浮窗 featureId 缺失: " .. tostring(spec.widgetId) end
    local Feature = S.Features and S.Features[spec.featureName] or nil
    if type(Feature) ~= "table" then return false, "生活悬浮窗 Feature 缺失: " .. tostring(spec.featureName) end
    if type(Feature.GetProjection) ~= "function" or type(Feature.GetWidgetWindowState) ~= "function"
        or type(Feature.GetWidgetVisible) ~= "function" or type(Feature.AcquireConsumer) ~= "function"
        or type(Feature.ReleaseConsumer) ~= "function" or type(Feature.Commands) ~= "table" then
        return false, "生活悬浮窗 Feature 契约不完整: " .. tostring(spec.widgetId)
    end

    Contents.specs[spec.featureName]=spec

    local function Policy()
        return type(Feature.GetWidgetWindowPolicy) == "function" and Feature:GetWidgetWindowPolicy()
            or { defaultWidth = spec.width or 470, defaultHeight = spec.height or 310, minWidth = 240, minHeight = 140,
                defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 }
    end
    local function Persist(reason)
        return Feature.Commands:MarkStoreDirty(250, "widget_" .. tostring(reason or "state"))
    end

    local function CreateWidget()
        local instance = { id = spec.widgetId, owner = spec.owner, visible = false, subscribed = false }
        local surface, createErr = Floating:Create({
            id = spec.rootId, owner = spec.owner, title = spec.title, status = "--",
            footer = true, resizable = true, movable = true, minimizeMode = "compact", boundaryMode = "free",
            defaultPlacement = "top-right", statePolicy = Policy(),
            getState = function() return Feature:GetWidgetWindowState() end,
            setState = function(value, reason) return Feature.Commands:SetWidgetWindowState(value, reason) end,
            persist = Persist,
            onClosed = function(_, reason)
                return Host:NotifyWindowClosed(spec.widgetId, { source = tostring(reason or "widget_close"), persist = true })
            end,
        })
        if surface == nil then return nil, createErr or (spec.title .. "悬浮窗创建失败") end
        instance.surface, instance.shell, instance.window = surface, surface.shell, surface.window
        instance.root, instance.windowController = surface.shell.root, surface.windowController
        instance.contentPrefix=spec.rootId.."_"
        local bodyOk,bodyErr=BuildBody(instance,surface:GetContentRoot(),spec,Feature)
        if not bodyOk then return nil,bodyErr end
        function instance:Refresh()return RefreshBody(self,spec,Feature)end
        function instance:Subscribe()
            if self.subscribed then return true end
            if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" and type(Feature.UpdateTopic) == "string" then
                S.Events:SubscribeInternal(Feature.UpdateTopic, self, function() if instance.visible then instance:Refresh() end end)
            end
            self.subscribed = true
            return true
        end
        function instance:Unsubscribe()
            if self.subscribed and S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
            self.subscribed = false
            return true
        end
        local function ReleaseConsumer()
            if instance.visible ~= true then return true end
            if not (S.FeatureRuntime and S.FeatureRuntime:IsEnabled(featureId) == true) then return true end
            return Feature:ReleaseConsumer("widget:" .. spec.token)
        end
        local function ReportOpenIssue(level, code, message, phase, detail, acquired)
            local diagnostics = S.DiagnosticsManager
            local fn = type(diagnostics) == "table" and diagnostics[level] or nil
            if type(fn) ~= "function" then return false end
            -- 悬浮窗属于 Presentation，但诊断必须显式带
            -- featureId/widgetId，才能归属到对应模块。该函数只在用户打开/持久化失败边沿执行，不进入刷新热路径。
            fn(diagnostics, "ui_v3", code, message, {
                featureId = featureId, widgetId = tostring(spec.widgetId or ""), route = tostring(spec.widgetId or ""),
                phase = tostring(phase or "unknown"), consumerAcquired = tostring(acquired == true), error = tostring(detail or ""),
            })
            return true
        end
        function instance:Show(context)
            if self.visible then
                local shown, showErr = self.surface:Show(true)
                if shown ~= true then return false, showErr end
                local refreshOk, refreshResult, refreshErr = xpcall(function() return self:Refresh() end, S.SafeTraceback)
                if refreshOk ~= true or refreshResult == false then
                    ReportOpenIssue("Warn", "LIFE_WIDGET_REFRESH_FAILED", spec.title .. "悬浮窗刷新失败，窗口保持打开", "refresh_visible",
                        refreshOk and refreshErr or refreshResult, true)
                    self.surface:SetStatus("数据刷新失败，可稍后重试", "yellow")
                end
                return true
            end

            local acquired = false
            local phase = "feature_gate"
            -- 先完成订阅、Consumer 和 Surface 显示，再独立刷新内容。
            -- 旧顺序让任一刷新异常都撤回窗口和需求，看起来按钮无反应，还覆盖了真实错误。
            local ok, openErr = xpcall(function()
                if not (S.FeatureRuntime and S.FeatureRuntime:IsEnabled(featureId) == true) then error(spec.title .. "功能已关闭") end
                phase = "subscribe"
                local subscribeOk, subscribeErr = self:Subscribe()
                if subscribeOk ~= true then error(subscribeErr or (spec.title .. "事件订阅失败")) end
                phase = "acquire_consumer"
                local acquireOk, acquireErr = Feature:AcquireConsumer("widget:" .. spec.token)
                if acquireOk ~= true then error(acquireErr or (spec.title .. " Consumer 获取失败")) end
                acquired = true
                phase = "surface_show"
                local shown, showErr = self.surface:Show(true)
                if shown ~= true then error(spec.title .. "悬浮窗显示失败：" .. tostring(showErr or "unknown")) end
            end, S.SafeTraceback)
            if ok ~= true then
                local rollbackHideOk, rollbackHideErr = self.surface:Show(false)
                self:Unsubscribe()
                if acquired then Feature:ReleaseConsumer("widget:" .. spec.token) end
                self.visible = false
                ReportOpenIssue("Error", "LIFE_WIDGET_OPEN_FAILED", spec.title .. "悬浮窗打开失败", phase,
                    tostring(openErr or "unknown") .. (rollbackHideOk ~= true and (" | rollbackHide=" .. tostring(rollbackHideErr or "failed")) or ""), acquired)
                return false, openErr
            end

            self.visible = true
            phase = "refresh_after_show"
            local refreshOk, refreshResult, refreshErr = xpcall(function() return self:Refresh() end, S.SafeTraceback)
            if refreshOk ~= true or refreshResult == false then
                -- 内容刷新是 Projection 层失败，不能夺走已经成功建立的窗口/Consumer 生命周期。
                -- 保留窗口让用户仍可关闭/重置布局，并把根因写入模块诊断；后续正常 Feature 更新会再次 Refresh。
                ReportOpenIssue("Warn", "LIFE_WIDGET_REFRESH_FAILED", spec.title .. "悬浮窗已打开，但首次数据刷新失败", phase,
                    refreshOk and refreshErr or refreshResult, acquired)
                self.surface:SetStatus("数据刷新失败，可稍后重试", "yellow")
            end
            if type(context) ~= "table" or context.persist ~= false then
                local persistOk, persistErr = Feature.Commands:SetWidgetVisible(true, "show")
                if persistOk ~= true then
                    -- 可见性已经由 Host/Native 成功提交；存档失败只影响下次自动恢复，不能反向隐藏当前窗口造成双 Authority。
                    ReportOpenIssue("Warn", "LIFE_WIDGET_VISIBILITY_PERSIST_FAILED", spec.title .. "悬浮窗已打开，但可见偏好保存失败",
                        "persist_visibility", persistErr, acquired)
                end
            end
            return true
        end
        function instance:Hide(context)
            CloseSettingsChoices(self)
            local hidden, hideErr = self.surface:Show(false)
            if hidden ~= true then return false, hideErr end
            local released, releaseErr = true, nil
            if self.visible then released, releaseErr = ReleaseConsumer() end
            self.visible = false; self:Unsubscribe();TreasureMapInteraction:Reset(self)
            if type(context) ~= "table" or context.persist ~= false then Feature.Commands:SetWidgetVisible(false, "hide") end
            if released ~= true then return false, releaseErr end
            return true
        end
        function instance:OnWindowClosed(context)
            CloseSettingsChoices(self)
            local released, releaseErr = ReleaseConsumer()
            self.visible = false; self:Unsubscribe();TreasureMapInteraction:Reset(self)
            if type(context) ~= "table" or context.persist ~= false then Feature.Commands:SetWidgetVisible(false, "native_close") end
            if released ~= true then return false, releaseErr end
            return true
        end
        function instance:ApplyProjection() return self:Refresh() end
        function instance:Open(context) return self:Show(context) end
        function instance:Close(context) return self:Hide(context) end
        function instance:ApplyLayout(fromMetricsChange) return self.surface:ApplyLayout(fromMetricsChange == true) end
        function instance:SetSize(w, h, persist) return self.surface:SetSize(w, h, persist) end
        function instance:SetLocked(v, persist) return self.surface:SetLocked(v, persist) end
        function instance:IsLocked() return self.surface:IsLocked() end
        function instance:GetLocked() return self.surface:IsLocked() end
        function instance:SetMinimized(v, persist) return self.surface:SetMinimized(v, persist) end
        function instance:IsMinimized() return self.surface:IsMinimized() end
        function instance:SetOverallOpacity(v, persist) return self.surface:SetOverallOpacity(v, persist) end
        function instance:GetOverallOpacity() return self.surface:GetOverallOpacity() end
        function instance:SetOpacity(v, persist) return self.surface:SetOverallOpacity(v, persist) end
        function instance:GetOpacity() return self.surface:GetOverallOpacity() end
        function instance:SetBackgroundOpacity(v, persist) return self.surface:SetBackgroundOpacity(v, persist) end
        function instance:GetBackgroundOpacity() return self.surface:GetBackgroundOpacity() end
        function instance:SetTextOpacity(v, persist) return self.surface:SetTextOpacity(v, persist) end
        function instance:GetTextOpacity() return self.surface:GetTextOpacity() end
        function instance:ResetLayout(persist) return self.surface:ResetLayout(persist) end
        return instance
    end

    local adapter = Floating:CreateStateAdapter({ statePolicy = Policy(), getState = function() return Feature:GetWidgetWindowState() end,
        setState = function(value, reason) return Feature.Commands:SetWidgetWindowState(value, reason) end, persist = Persist })
    local ok, err = Host:Register(spec.widgetId, {
        featureId = featureId, create = CreateWidget, ensurePreferences = function() return Feature:Initialize() end,
        lockable = true, minimizable = true, resettable = true, opacityAdjustable = true, backgroundOpacityAdjustable = true, textOpacityAdjustable = true,
        getLocked = adapter.getLocked, setLocked = adapter.setLocked, getMinimized = adapter.getMinimized, setMinimized = adapter.setMinimized,
        getOverallOpacity = adapter.getOverallOpacity, setOverallOpacity = adapter.setOverallOpacity, getOpacity = adapter.getOpacity, setOpacity = adapter.setOpacity,
        getBackgroundOpacity = adapter.getBackgroundOpacity, setBackgroundOpacity = adapter.setBackgroundOpacity,
        getTextOpacity = adapter.getTextOpacity, setTextOpacity = adapter.setTextOpacity, resetLayout = adapter.resetLayout,
    })
    if ok ~= true then return false, err end
    if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
        Host:BindFeatureLifecycle(spec.widgetId, {
            featureId = featureId,
            enabled = function() return S.FeatureRuntime:IsEnabled(featureId) == true end,
            preference = function() return Feature:GetWidgetVisible() == true end,
            onShowFailed = function() Feature.Commands:SetWidgetVisible(false, "auto_show_failed") end,
        })
    end
    return true
end

local ok, err = Register({
    featureName = "Trade", featureId = "life_trade", widgetId = "life.trade", token = "life_trade", owner = "v3:widget:life_trade",
    rootId = "v3_life_trade_widget", contentId = "v3_life_trade_widget_content", tableId = "v3_life_trade_widget_table", title = "跑商货率",
    emptyTitle = "暂无货率", emptyDetail = "直接在悬浮窗选择起点和目的地；服务器货率返回后自动更新。",
    buildControls = function(instance, content, Feature)
        if type(Feature.Commands.SetFrom) ~= "function" or type(Feature.Commands.SetTo) ~= "function"
            or type(Feature.Commands.SetViewMode) ~= "function" or type(Feature.Commands.SelectFavorite) ~= "function"
            or type(Feature.Commands.ToggleCurrentFavorite) ~= "function" or type(Feature.Commands.ToggleTrackedProduct) ~= "function"
            or type(Feature.Commands.QuoteRowMaterials) ~= "function" or type(Feature.Commands.SetRatioMode) ~= "function" then
            return false, "跑商悬浮窗 Feature 路线/显示/收藏/关注/单行询价命令缺失"
        end
        if instance.headerMode then return BuildSettingsHeader(instance,content,Feature,'Trade')end

        -- 浮窗保留路线收藏按钮，避免常用操作必须回主页面；首页 overview 仍保持两行。
        -- 收藏直接调用既有 Trade Command，不另存状态。
        local floatingFavoriteManagement = instance.overview ~= true
        local routeControlHeight = floatingFavoriteManagement and 88 or 58
        local routeBox = RSUI:VerticalBox({
            id = (instance.contentPrefix or "v3_life_trade_widget_") .. "route", parent = content, gap = 2,
            slot = { size = "fixed", height = routeControlHeight, hAlign = "fill" },
        })
        instance.routeBox = routeBox
        instance.routeControlHeight = routeControlHeight

        local routeRow = RSUI:HorizontalBox({
            id = (instance.contentPrefix or "v3_life_trade_widget_") .. "route_row", parent = routeBox, gap = 4,
            slot = { size = "fixed", height = 28, hAlign = "fill" },
        })
        instance.fromDropdown = RSUI:Dropdown({
            id = (instance.contentPrefix or "v3_life_trade_widget_") .. "from", parent = routeRow, items = {}, maxVisible = 6,
            popupWidth = 210, placeholder = "起点",
            get = function() return (Feature:GetRouteSettings() or {}).fromZone end,
            set = function(v) return Feature.Commands:SetFrom(v) end,
            slot = { size = "fill", fill = 1, minWidth = 92 },
        })
        RSUI:Text({
            id = (instance.contentPrefix or "v3_life_trade_widget_") .. "route_arrow", parent = routeRow, text = "→", fontSize = 9, tone = "muted",
            slot = { size = "fixed", width = 14 },
        })
        instance.toDropdown = RSUI:Dropdown({
            id = (instance.contentPrefix or "v3_life_trade_widget_") .. "to", parent = routeRow, items = {}, maxVisible = 6,
            popupWidth = 210, placeholder = "目的地",
            get = function() return (Feature:GetRouteSettings() or {}).toZone end,
            set = function(v) return Feature.Commands:SetTo(v) end,
            slot = { size = "fill", fill = 1, minWidth = 92 },
        })
        instance.refreshButton = RSUI:Button({
            id = (instance.contentPrefix or "v3_life_trade_widget_") .. "refresh", parent = routeRow, text = "刷新", compact = true,
            slot = { size = "fixed", width = 48 },
        })
        instance.refreshButton.onClick = function()
            local reason = instance.overview and "overview_manual" or "widget_manual"
            local ok, refreshErr = Feature.Commands:Refresh(reason)
            if ok == true then instance:Refresh() end
            return ok, refreshErr
        end

        local favoriteRow = RSUI:HorizontalBox({
            id = (instance.contentPrefix or "v3_life_trade_widget_") .. "favorite_row", parent = routeBox, gap = 4,
            slot = { size = "fixed", height = 28, hAlign = "fill" },
        })
        instance.favoriteDropdown = RSUI:Dropdown({
            id = (instance.contentPrefix or "v3_life_trade_widget_") .. "favorite", parent = favoriteRow, items = {}, maxVisible = 6,
            popupWidth = 230, placeholder = "收藏路线",
            get = function()
                local projection = instance.controlProjection or Feature:GetProjection() or {} -- 收藏控件复用已提交展示快照。
                return projection.currentRouteFavorite and projection.currentFavoriteKey or nil
            end,
            set = function(value)
                local ok, commandErr = Feature.Commands:SelectFavorite(value)
                if ok == true then instance:Refresh() end
                return ok, commandErr
            end,
            slot = { size = "fill", fill = 1.25, minWidth = 120 },
        })
        if floatingFavoriteManagement then
            instance.favoriteButton = RSUI:Button({
                id = (instance.contentPrefix or "v3_life_trade_widget_") .. "favorite_toggle", parent = favoriteRow,
                text = "添加收藏", compact = true, slot = { size = "fixed", width = 82 },
            })
            instance.favoriteButton.onClick = function()
                local ok, favoriteErr = Feature.Commands:ToggleCurrentFavorite()
                if ok == true then instance:Refresh() end
                return ok, favoriteErr
            end
        end

        local modeRow = favoriteRow
        if floatingFavoriteManagement then
            modeRow = RSUI:HorizontalBox({
                id = (instance.contentPrefix or "v3_life_trade_widget_") .. "mode_row", parent = routeBox, gap = 4,
                slot = { size = "fixed", height = 28, hAlign = "fill" },
            })
        end
        -- 三个显示模式用无弹层 SegmentedSelector，避免增加 Dropdown 的 Native 窗口预算。
        instance.viewSelector = RSUI:SegmentedSelector({
            id = (instance.contentPrefix or "v3_life_trade_widget_") .. "view_mode", parent = modeRow,
            items = {
                { value = "all", text = "全部" },
                { value = "tracked", text = "关注" },
                { value = "cargo", text = "随身" },
            },
            itemWidth = floatingFavoriteManagement and 32 or 40, gap = 2, height = 26, fontSize = 9,
            get = function() return (instance.controlProjection or Feature:GetProjection() or {}).viewMode or "all" end, -- 模式标量不触发全量投影。
            set = function(value)
                local ok, commandErr = Feature.Commands:SetViewMode(value)
                if ok == true then instance:Refresh() end
                return ok, commandErr
            end,
            slot = { size = "fixed", width = floatingFavoriteManagement and 100 or 124, vAlign = "fill" },
        })
        instance.trackButton = RSUI:Button({
            id = (instance.contentPrefix or "v3_life_trade_widget_") .. "track", parent = modeRow, text = "关注货物", compact = true,
            slot = { size = "fixed", width = floatingFavoriteManagement and 64 or 74 },
        })
        instance.trackButton.onClick = function()
            local row = type(Feature.GetSelectedRow) == "function" and Feature:GetSelectedRow() or nil
            if type(row) ~= "table" or row.key == nil then return false, "请先单击选择一个货物" end
            local ok, trackErr = Feature.Commands:ToggleTrackedProduct(row.itemType or row.key)
            if ok == true then instance:Refresh() end
            return ok, trackErr
        end
        if floatingFavoriteManagement then
            -- 悬浮窗直接提供两个货率选项；同一行保留320px客户区预算，单套金额由Feature切换。
            instance.ratioSelector=RSUI:SegmentedSelector({id=(instance.contentPrefix or "v3_life_trade_widget_").."ratio_mode",parent=modeRow,
                items={{value="current",text="实时货率"},{value="full",text="满货率"}},itemWidth=60,gap=2,height=26,fontSize=9,
                get=function()return (instance.controlProjection or Feature:GetProjection()or {}).ratioMode or "current"end,
                set=function(value)local ok,why=Feature.Commands:SetRatioMode(value);if ok then instance:Refresh()end;return ok,why end,
                slot={size="fixed",width=124,vAlign="fill"}})
            if not instance.ratioSelector then return false,"货率选项创建失败"end
        end

        return instance.fromDropdown ~= nil and instance.toDropdown ~= nil and instance.favoriteDropdown ~= nil
            and (instance.overview == true or instance.favoriteButton ~= nil)
            and instance.viewSelector ~= nil and instance.trackButton ~= nil,
            "跑商悬浮窗紧凑控制条创建失败"
    end,
    refreshControls = function(instance, projection, rows, Feature)
        -- RefreshBody 以第四参数传 Feature；旧二参签名曾使此处读取 nil 全局，
        -- 每次发布都报 LIFE_WIDGET_CONTROL_REFRESH_FAILED。rows 只为统一 WidgetSpec 签名保留。
        if instance.headerMode then
            instance.routeTitle=FindZoneName(projection,projection.fromZone)..' → '..FindZoneName(projection,projection.toZone)
            return RefreshSettingsHeader(instance,projection)
        end
        local fromItems, toItems = ZoneItems(projection.zones), ZoneItems(projection.sellableZones)
        local routeControlsEnabled = projection.viewMode ~= "cargo"
        if instance.fromDropdown then
            instance.fromDropdown:SetItems(fromItems)
            instance.fromDropdown:SetEnabled(routeControlsEnabled and #fromItems > 0)
            instance.fromDropdown:Render()
        end
        if instance.toDropdown then
            instance.toDropdown:SetItems(toItems)
            instance.toDropdown:SetEnabled(routeControlsEnabled and #toItems > 0)
            instance.toDropdown:Render()
        end
        if instance.refreshButton then
            instance.refreshButton:SetEnabled(projection.viewMode == "cargo" or (projection.fromZone ~= nil and projection.toZone ~= nil))
            if projection.isRefreshing == true then instance.refreshButton:SetText("刷新中") else instance.refreshButton:SetText("刷新") end
        end
        local favoriteItems = type(projection.favoriteItems) == "table" and projection.favoriteItems or {}
        if instance.favoriteDropdown then
            instance.favoriteDropdown:SetItems(favoriteItems)
            instance.favoriteDropdown:SetEnabled(routeControlsEnabled and #favoriteItems > 0)
            instance.favoriteDropdown:Render()
        end
        if instance.favoriteButton then
            -- 按钮只提交当前 from/to 的收藏切换；
            -- 文案完全由 Projection 的 currentRouteFavorite 回读，Presentation 不缓存第二份收藏状态。
            local canFavorite = routeControlsEnabled and projection.fromZone ~= nil and projection.toZone ~= nil
            instance.favoriteButton:SetEnabled(canFavorite)
            instance.favoriteButton:SetText(projection.currentRouteFavorite == true and "移除收藏" or "添加收藏")
        end
        if instance.viewSelector then
            instance.viewSelector:SetEnabled(true)
            instance.viewSelector:Render()
        end
        if instance.ratioSelector then instance.ratioSelector:Render()end
        if instance.trackButton then
            local row = type(Feature.GetSelectedRow) == "function" and Feature:GetSelectedRow() or nil
            local canTrack = type(row) == "table" and (tonumber(row.itemType) ~= nil or row.key ~= nil)
            instance.trackButton:SetEnabled(canTrack)
            instance.trackButton:SetText(canTrack and (row.tracked == true and "取消关注" or "关注货物") or "关注货物")
        end
    end,
    selectable = true,
    onSelection = function(instance, row, Feature)
        -- 单击只选择，但要立即同步“关注货物”按钮状态；
        -- 不弹详情、不发询价，第二次点击仍能稳定进入同一行的双击识别。
        if type(row) ~= "table" or row.key == nil then return false end
        if type(Feature.Commands.SelectRow) ~= "function" then return true end
        local ok, selectErr = Feature.Commands:SelectRow(row.key)
        if ok == true and instance.trackButton then
            local selected = type(Feature.GetSelectedRow) == "function" and Feature:GetSelectedRow() or row
            instance.trackButton:SetEnabled(type(selected) == "table")
            instance.trackButton:SetText(type(selected) == "table" and selected.tracked == true and "取消关注" or "关注货物")
        end
        if ok == true and instance.headerMode then instance:Refresh()end
        return ok, selectErr
    end,
    onItemActivated = function(instance, row, Feature)
        if type(row) ~= "table" or row.key == nil then return false end
        -- RSUI ListView 的 activated 回调当前按每次 row click 触发；Trade 在 Presentation 层做 opt-in 双击识别，
        -- 不改变其他 TableView 的单击激活契约。状态只保存在这个悬浮窗实例，不进入 Feature/配置存档。
        local now = type(S.NowMs) == "function" and tonumber(S.NowMs()) or 0
        local key = tostring(row.key)
        local previousAt = tonumber(instance.tradeLastActivateAt) or -100000
        local isDouble = instance.tradeLastActivateKey == key and now >= previousAt and (now - previousAt) <= 450
        instance.tradeLastActivateKey, instance.tradeLastActivateAt = key, now
        if not isDouble then return true end
        instance.tradeLastActivateKey, instance.tradeLastActivateAt = nil, 0
        local ok, quoteErr = Feature.Commands:QuoteRowMaterials(row.key)
        if ok == true then
            instance:Refresh()
        elseif instance.surface ~= nil and type(instance.surface.SetStatus) == "function" then
            instance.surface:SetStatus("无法查询毛利：" .. tostring(quoteErr or "材料不可询价"), "yellow")
        end
        return ok, quoteErr
    end,
    columns = {
        { id = "detail", title = "", cellType = "button", getText = function() return "详情" end,
            size = "fixed", width = 44, minWidth = 44, absoluteMinWidth = 44, sortable = false, resizable = false,
            onClick = function(row)
                local detail = S.UIV3 and S.UIV3.TradeDetailFloatingV3
                if type(row) ~= "table" or row.key == nil then return false, "货物已失效" end
                if type(detail) ~= "table" or type(detail.Open) ~= "function" then return false, "货物详情浮窗不可用" end
                return detail:Open(row.key)
            end },
        { id = "name", title = "货物", field = "name", size = "fill", minWidth = 108, fill = 1 }, -- 货物列仍负责吸收剩余宽度，仅略降最小值以支持 320px 紧凑窗口。
        { id = "rate", title = "货率", field = "rate", size = "fixed", width = 54, minWidth = 48, getTone = function(item) return item and item.tone or "muted" end },
        { id = "price", title = "售价", field = "price", size = "fixed", width = 74, minWidth = 60 },
        { id = "profit", title = "毛利", field = "profit", size = "fixed", width = 78, minWidth = 64 },
    },
    status = function(projection, rows)
        -- 悬浮窗底部只显示当前动作/下一步操作，
        -- 不再重复路线、排序、熟练度、计数等已经能从控件或表格看出的信息。
        if projection.status == "error" or projection.status == "unavailable" then
            return tostring(projection.error or "跑商数据不可用")
        end
        local activity = projection.quoteActivity
        if type(activity) == "table" and activity.paused == true then return tostring(activity.text or "材料名称查询已暂停") end
        local batch = projection.quoteBatch or {}
        if batch.active == true then
            local activeJobs = tonumber((projection.quoteJobs or {}).activeCount) or tonumber(batch.activeJobs) or 1
            return "正在查询 " .. tostring(activeJobs) .. " 个货物 · 材料 " .. tostring(batch.completed or 0) .. "/" .. tostring(batch.total or 0)
                .. " · 可继续双击其它货物加入"
        end
        -- 队列停机后的失败原因仍应可见，不能恢复成“已自动更新”的通用提示。
        if (tonumber(batch.failed) or 0) > 0 then
            return tostring(batch.lastJobReason or "部分材料价格未知；双击可重试")
        end
        local remaining = math.max(0, tonumber(projection.cooldownRemainingMs) or 0)
        if projection.routeStatus == "cooldown" and remaining > 0 then
            return "路线已切换 · 服务器冷却约 " .. tostring(math.ceil(remaining / 1000)) .. " 秒后自动读取"
        end
        if projection.isRefreshing == true then return "正在刷新货率 · 当前列表会保留上一份可用数据" end
        if projection.viewMode == "tracked" then return "只看关注货物 · 本地材料价即时计算 · 双击查询缺失材料价" end
        if projection.viewMode == "cargo" then
            local cargo = projection.cargo or {}
            return "随身贸易包：" .. tostring(cargo.name or cargo.legacyName or "未识别") .. " · 自动比较目的地"
        end
        local age = tonumber(projection.ratioAgeMs)
        local ageText = age ~= nil and age >= 10000 and (" · 数据" .. tostring(math.floor(age / 1000)) .. "秒前") or ""
        local autoState = type(projection.autoRefreshState) == "table" and projection.autoRefreshState or {}
        local autoText = projection.autoRefresh == true and (autoState.watchActive == true and " · 货率自动刷新" or " · 自动刷新待机") or ""
        return "本地材料价即时计算毛利 · 后台自动更新 · 双击查询缺失材料" .. autoText .. ageText
    end,
})
if ok ~= true then error(err) end

ok, err = Register({
    featureName = "Bonds", featureId = "life_bonds", widgetId = "life.bonds", token = "life_bonds", owner = "v3:widget:life_bonds",
    rootId = "v3_life_bonds_widget", contentId = "v3_life_bonds_widget_content", tableId = "v3_life_bonds_widget_table", title = "债券 / 居民板",
    emptyTitle = "暂无居民板条目", emptyDetail = "居民板事实不可用或当前筛选没有条目。",
    selectable = true,
    onSelection = function(instance, row, Feature)
        if row == nil or row.key == nil then return false end
        if type(Feature.Commands.SelectRow) == "function" then
            return Feature.Commands:SelectRow(row.key)
        end
        return true
    end,
    onItemActivated = function(instance, row, Feature)
        if row == nil then return false end
        local floating = S.UIV3 and S.UIV3.QuestDetailFloatingV3 or nil
        if type(floating) == "table" and type(floating.Open) == "function" then
            return floating:Open("bonds", row.key, row)
        end
        return false
    end,
    buildControls = function(instance, content, Feature)
        if type(Feature.GetDisplayOrderKey) ~= "function" or type(Feature.GetFilterMask) ~= "function" or type(Feature.GetDuplicateMode) ~= "function"
            or type(Feature.Commands.SetDisplayOrder) ~= "function" or type(Feature.Commands.SetFilterMask) ~= "function"
            or type(Feature.Commands.SetDuplicateMode) ~= "function" then
            return false, "债券悬浮窗下拉设置命令缺失"
        end
        if instance.headerMode then return BuildSettingsHeader(instance,content,Feature,'Bonds')end
        -- 三项等分现有一行，选中值直接读取 Feature；首页标题栏继续使用原有独立设置表单。
        -- compact 允许 Dropdown 随窄窗缩小，弹层独立保持可读宽度，由 RSUI 统一管理互斥/关闭。
        local row = RSUI:HorizontalBox({
            id = (instance.contentPrefix or "v3_life_bonds_widget_") .. "settings_row", parent = content, gap = 4,
            slot = { size = "fixed", height = 26, hAlign = "fill" },
        })
        local prefix = instance.contentPrefix or "v3_life_bonds_widget_"
        instance.bondScopeDropdown = RSUI:Dropdown({
            id = prefix .. "scope", parent = row, items = BOND_TOOLBAR_SCOPE_ITEMS, placeholder = "显示范围",
            compact = true, fontSize = 9, height = 26, maxVisible = 8, popupWidth = 210,
            get = function() return Feature:GetFilterMask() end,
            set = function(value) return Feature.Commands:SetFilterMask(value) end,
            onChanged = function() instance:Refresh() end,
            slot = { size = "fill", fill = 1, minWidth = 44, hAlign = "fill" },
        })
        instance.bondOrderDropdown = RSUI:Dropdown({
            id = prefix .. "order", parent = row, items = BOND_TOOLBAR_ORDER_ITEMS, placeholder = "排序",
            compact = true, fontSize = 9, height = 26, maxVisible = 6, popupWidth = 210,
            get = function() return Feature:GetDisplayOrderKey() end,
            set = function(value)
                local mode, order = string.match(tostring(value or ""), "^([^:]+):(.+)$")
                if mode == nil or order == nil then return false, "债券排序设置无效" end
                return Feature.Commands:SetDisplayOrder(mode, order)
            end,
            onChanged = function() instance:Refresh() end,
            slot = { size = "fill", fill = 1, minWidth = 44, hAlign = "fill" },
        })
        instance.bondDuplicateDropdown = RSUI:Dropdown({
            id = prefix .. "duplicate", parent = row, items = BOND_DUPLICATE_ITEMS, placeholder = "重复材料",
            compact = true, fontSize = 9, height = 26, maxVisible = 3, popupWidth = 180,
            get = function() return Feature:GetDuplicateMode() end,
            set = function(value) return Feature.Commands:SetDuplicateMode(value) end,
            onChanged = function() instance:Refresh() end,
            slot = { size = "fill", fill = 1, minWidth = 44, hAlign = "fill" },
        })
        return instance.bondScopeDropdown ~= nil and instance.bondOrderDropdown ~= nil and instance.bondDuplicateDropdown ~= nil
    end,
    refreshControls = function(instance, projection, rows, Feature)
        if instance.headerMode then return RefreshSettingsHeader(instance,projection)end
        for _, dropdown in ipairs({ instance.bondScopeDropdown, instance.bondOrderDropdown, instance.bondDuplicateDropdown }) do
            dropdown:SetEnabled(true)
            dropdown:Render()
        end
    end,
    columns = {
        -- 大陆列直接显示 Authority row.continent，
        -- 让同日西/东快照合并后仍可辨认来源。悬浮窗不重新根据文本/材料猜大陆。
        { id = "continent", title = "大陆", field = "continent", size = "fixed", width = 54, minWidth = 48 },
        { id = "text", title = "居民板", field = "text", size = "fill", minWidth = 100, fill = 1 },
        { id = "material", title = "材料", field = "name", size = "fixed", width = 60, minWidth = 52 },
        { id = "quantity", title = "需", field = "quantity", size = "fixed", width = 34, minWidth = 30 },
        { id = "resource", title = "有", field = "resourceText", size = "fixed", width = 34, minWidth = 30 },
        { id = "shortage", title = "缺", field = "shortageText", size = "fixed", width = 34, minWidth = 30 },
        { id = "status", title = "状态", field = "statusText", size = "fixed", width = 58, minWidth = 50, getTone = function(item) return item and item.tone or "muted" end },
    },
    status = function(projection, rows)
        local coverage = type(projection.dailySnapshotStatus) == "table" and projection.dailySnapshotStatus or {}
        local current = projection.boardScope == "west" and "西" or (projection.boardScope == "east" and "东" or (projection.boardScope == "auroria" and "原" or "?"))
        local dayText = projection.snapshotDateVerified == false and ("缓存" .. tostring(projection.snapshotDateKey or "--") .. "（待核对日期）") or "今日"
        local saveText = projection.dailySaveStatus == "failed" and " · 本地保存失败" or (projection.dailySaveStatus == "pending" and " · 等待保存" or "")
        return tostring(#rows) .. "条 · 当前" .. current .. " · " .. dayText .. " 西" .. (coverage.west and "✓" or "×")
            .. " 东" .. (coverage.east and "✓" or "×") .. " 原" .. (coverage.auroria and "✓" or "×")
            .. saveText
            .. (projection.filterHint and (" · " .. projection.filterHint) or "")
    end,
})
if ok ~= true then error(err) end

ok, err = Register({
    featureName = "Treasure", featureId = "life_treasure", widgetId = "life.treasure", token = "life_treasure", owner = "v3:widget:life_treasure",
    rootId = "v3_life_treasure_widget", contentId = "v3_life_treasure_widget_content", tableId = "v3_life_treasure_widget_table", title = "寻宝助手",
    emptyTitle = "暂无追踪条目", emptyDetail = "在上方选择分类和海域，或从设置刷新背包藏宝图。", selectable = true,
    buildControls = function(instance, content, Feature)
        -- 地图按钮与双击均为显式动作，Native X2Map 仍由 Feature Command/Capability Gate 所有；
        -- 不在 Presentation 保存坐标、worldId 或第二份选择状态。按钮自身不启动 Scheduler，也不会因为悬浮窗刷新自动打开地图。
        if type(Feature.Commands.ShowSelectedOnMap) ~= "function" then return false, "寻宝地图定位命令缺失" end
        local function Run(command,...)
            TreasureMapInteraction:Reset(instance)
            local ok,why=Feature.Commands[command](Feature.Commands,...)
            instance.treasureActionError=ok~=true and tostring(why or "操作未完成") or nil
            instance:Refresh()
            return ok,why
        end
        local prefix=instance.contentPrefix or "v3_life_treasure_widget_"
        local filters=RSUI:HorizontalBox({id=prefix.."filters",parent=content,gap=3,slot={size="fixed",height=24,hAlign="fill"}})
        instance.treasureFilters=filters
        local function Projection()return instance.treasureControlProjection or Feature:GetProjection()end
        instance.treasureKindDropdown=RSUI:Dropdown({id=prefix.."kind",parent=filters,fontSize=9,height=24,compact=true,
            items={{value="maps",text="寻宝"},{value="seabugs",text="海虫"},{value="ships",text="沉船"}},maxVisible=3,popupWidth=120,
            get=function()return Projection().viewKind end,set=function(value)return Run("SetViewKind",value)end,
            slot={size="fixed",width=60}})
        instance.treasureRegionDropdown=RSUI:Dropdown({id=prefix.."region",parent=filters,fontSize=9,height=24,compact=true,
            items=Projection().regionItems or {},maxVisible=6,popupWidth=190,
            get=function()return Projection().region end,set=function(value)return Run("SetRegion",value)end,
            slot={size="fill",fill=1,minWidth=72}})
        local function SettingsItems(p)
            local interval=p.shipRespawnMinutes or 0
            local items={{value="refresh",text="刷新背包 / 点位"},{value="skip",text="跳过 → 下一处"},
                {value="undo",text="撤销上次搜查"},{value="round",text="新一轮（保留沉船计时）"},{value="stop",text="停止追踪"},
                {value="timer:0",text=(interval==0 and "✓ " or "").."沉船：仅显示已过时间"}}
            if type(Feature.Commands.TrackCustomPoint)=="function" then table.insert(items,1,{value="custom",text="自定义点：输入坐标"})end
            if type(Feature.Commands.ResetCofferRound)=="function" then
                table.insert(items,2,{value="clear_coffers",text=p.inventoryRepairable and "修复损坏记录（保留完整坐标）" or "重新统计保管箱（清空本轮记录）"})
            end
            for _,hours in ipairs({1,2,4,6,12,24,48})do
                items[#items+1]={value="timer:"..(hours*60),text=(interval==hours*60 and "✓ " or "").."沉船预估："..hours.."小时"}
            end
            items[#items+1]={value="draw:33",text="罗盘绘制：33ms"}
            items[#items+1]={value="draw:50",text="罗盘绘制：50ms"}
            items[#items+1]={value="draw:100",text="罗盘绘制：100ms"}
            return items
        end
        instance.treasureSettingsItems=SettingsItems
        instance.treasureSettingsDropdown=RSUI:Dropdown({id=prefix.."settings",parent=filters,fontSize=9,height=24,compact=true,placeholder="设置",
            items=SettingsItems(Projection()),maxVisible=8,popupWidth=242,get=function()return "__settings__" end,
            set=function(value)
                if value=="custom" and instance.treasureCustomControls then
                    return instance.treasureCustomControls:SetExpanded(not instance.treasureCustomControls.expanded)
                end
                local minutes=tostring(value):match("^timer:(%d+)$")
                local draw=tostring(value):match("^draw:(%d+)$")
                if minutes then return Run("SetShipRespawnMinutes",tonumber(minutes))end
                if draw then return Run("SetRefreshMs",tonumber(draw))end
                if value=="refresh" then return Run("Refresh")end
                if value=="clear_coffers" then return Run(Projection().inventoryRepairable and "RepairCofferRecords" or "ResetCofferRound")end
                if value=="skip" then return Run("VisitAndNext","skipped")end
                if value=="undo" then return Run("UndoVisit")end
                if value=="round" then return Run("ResetRound")end
                if value=="stop" then return Run("StopTracking")end
                return false,"未知设置"
            end,onChanged=function(_,_,control)control:Render()end,slot={size="fixed",width=48}})
        if type(Feature.Commands.RepairCofferRecords)=="function" then
            instance.treasureRepairButton=RSUI:Button({id=prefix.."repair_coffers",parent=content,text="修复损坏记录（保留完整坐标）",fontSize=9,compact=true,visible=false,
                slot={size="fixed",height=24,hAlign="fill"},onClick=function()return Run("RepairCofferRecords")end})
        end
        local row=RSUI:HorizontalBox({id=prefix.."actions",parent=content,gap=3,slot={size="fixed",height=24,hAlign="fill"}})
        instance.treasureActionRow=row
        -- 保管箱统计的主操作直接露在浮窗；仅显式点击读取当前箱，按钮/刷新不自动枚举或扫描其它箱。
        if type(Feature.Commands.IdentifyCurrentCoffer)=="function" then
            instance.treasureIdentifyButton=RSUI:Button({id=prefix.."identify_coffer",parent=row,text="识别当前保管箱",fontSize=9,compact=true,
                slot={size="fill",fill=1,minWidth=108},onClick=function()return Run("IdentifyCurrentCoffer")end})
        end
        instance.treasureNextButton=RSUI:Button({id=prefix.."next",parent=row,text="已搜 → 下一处",fontSize=9,compact=true,
            slot={size="fill",fill=1,minWidth=84},onClick=function()return Run("VisitAndNext","searched")end})
        instance.treasureNearestButton=RSUI:Button({id=prefix.."nearest",parent=row,text="最近点",fontSize=9,compact=true,slot={size="fixed",width=54}})
        instance.treasureNearestButton.onClick=function()return Run("TrackNearest")end
        instance.treasureMapButton=RSUI:Button({id=prefix.."map",parent=row,text = "地图定位",fontSize=9,compact=true,
            slot={size="fixed",width=62},onClick=function()return Run("ShowSelectedOnMap")end})
        if type(Feature.Commands.WithdrawCoordinate)=="function" and type(Feature.Commands.CancelWithdrawal)=="function" then
            -- 取图占独立一行以适配240宽小窗；只分派现有串行命令，0表示当前箱该坐标全部，不沿用主页面最多2张的默认值。
            -- 点击时读Feature最新选择/开箱绑定，避免另一个视图换目标后仍使用本浮窗的旧投影。UI不保存坐标或创建取图任务。
            local withdrawRow=RSUI:HorizontalBox({id=prefix.."withdraw_actions",parent=content,gap=3,
                slot={size="fixed",height=24,hAlign="fill"}})
            instance.treasureWithdrawRow=withdrawRow
            instance.treasureWithdrawButton=RSUI:Button({id=prefix.."withdraw_coordinate",parent=withdrawRow,text="取出同坐标",fontSize=9,compact=true,enabled=false,
                slot={size="fill",fill=1,minWidth=132},onClick=function()
                    local p=Feature:GetProjection() or {};local selected=p.selected
                    return Run("WithdrawCoordinate",p.boundCofferId,selected and selected.groupKey,0)
                end})
            instance.treasureCancelWithdrawButton=RSUI:Button({id=prefix.."cancel_withdraw",parent=withdrawRow,text="停止取图",fontSize=9,compact=true,enabled=false,
                slot={size="fixed",width=76},onClick=function()return Run("CancelWithdrawal")end})
        end
        if S.UIV3.TreasureControlsV3 then
            instance.treasureCustomControls=S.UIV3.TreasureControlsV3:BuildCustomPoint(content,Feature,prefix,{hideToggle=true,
                onExpanded=function()instance:Refresh()end,onResult=function(ok,why)
                TreasureMapInteraction:Reset(instance)
                instance.treasureActionError=ok~=true and tostring(why or "操作未完成") or nil
                instance:Refresh()
            end})
        end
        instance.treasureInteractionHint=RSUI:Text({id=prefix.."hint",parent=content,text=TreasureMapInteraction.hint,fontSize=9,
            tone="muted",overflow="ellipsis",slot={size="fixed",height=18,hAlign="fill"}})
        return true
    end,
    refreshControls = function(instance, projection, _, Feature)
        TreasureMapInteraction:SyncSelection(instance.table, projection)
        instance.treasureControlProjection=projection
        if instance.treasureCustomControls then instance.treasureCustomControls:Refresh(projection)end
        local editing=instance.treasureCustomControls and instance.treasureCustomControls.expanded==true or false
        if instance.treasureCustomEditing~=editing then
            instance.treasureCustomEditing=editing
            instance.controls:SetSlot({size=editing and "fill" or "auto",fill=1,hAlign="fill",vAlign="fill"})
        end
        instance.treasureFilters:SetVisible(not editing);instance.treasureActionRow:SetVisible(not editing)
        instance.table:SetVisible(not editing)
        if instance.statusLabel then instance.statusLabel:SetVisible(not editing)end
        if instance.treasureInteractionHint then instance.treasureInteractionHint:SetVisible(not editing)end
        local sea=projection.viewKind=="seabugs" or projection.viewKind=="ships"
        local selected=projection.selected
        local withdraw=projection.withdraw or {}
        local running=withdraw.status=="running"
        if instance.treasureRepairButton then
            instance.treasureRepairButton:SetVisible(projection.inventoryRepairable==true and not editing)
            instance.treasureRepairButton:SetEnabled(Feature.enabled==true and not running)
        end
        local boxId=projection.boundCofferId
        local selectedCount=tonumber(boxId and selected and selected.boxes and selected.boxes[boxId]) or 0
        local same=selected and selected.kind==projection.viewKind and (projection.region=="all" or selected.region==projection.region)
        if instance.treasureMapButton then instance.treasureMapButton:SetEnabled(type(projection.selected)=="table") end
        if instance.treasureNearestButton then instance.treasureNearestButton:SetEnabled(sea) end
        if instance.treasureNextButton then instance.treasureNextButton:SetVisible(sea);instance.treasureNextButton:SetEnabled(same==true) end
        if instance.treasureNearestButton then instance.treasureNearestButton:SetVisible(sea)end
        if instance.treasureIdentifyButton then
            instance.treasureIdentifyButton:SetVisible(not sea)
            instance.treasureIdentifyButton:SetEnabled(Feature.enabled==true and not running)
        end
        if instance.treasureWithdrawRow then
            instance.treasureWithdrawRow:SetVisible(not sea and not editing)
            instance.treasureWithdrawButton:SetEnabled(Feature.enabled==true and not sea and not running and not projection.inventoryUncertain
                and boxId~=nil and selected~=nil and selected.groupKey~=nil and selectedCount>0)
            instance.treasureWithdrawButton:SetText(running and ("正在取图 "..tostring(withdraw.moved or 0).."/"..tostring(withdraw.limit or 0)) or "取出同坐标")
            instance.treasureCancelWithdrawButton:SetEnabled(Feature.enabled==true and running)
        end
        instance.treasureKindDropdown:Render()
        if instance.treasureLastKind~=projection.viewKind then
            instance.treasureRegionDropdown:SetItems(projection.regionItems or {});instance.treasureLastKind=projection.viewKind
        end
        instance.treasureRegionDropdown:SetEnabled(sea or projection.inventoryContractVersion~=nil);instance.treasureRegionDropdown:Render()
        if instance.treasureLastInterval~=projection.shipRespawnMinutes or instance.treasureLastRepairable~=projection.inventoryRepairable then
            instance.treasureSettingsDropdown:SetItems(instance.treasureSettingsItems(projection));instance.treasureLastInterval=projection.shipRespawnMinutes
            instance.treasureLastRepairable=projection.inventoryRepairable
        end
        instance.treasureSettingsDropdown:Render()
        if instance.treasureInteractionHint then
            local errorText = instance.treasureActionError or projection.lastMapActionError
            local hint=TreasureMapInteraction.hint
            if not sea and projection.inventoryContractVersion then
                hint="已识别 "..tostring(projection.scannedCofferCount or 0).." 箱 · 跨箱同坐标 "..tostring(projection.sharedCoordinateCount or 0).." 处 · 同箱重复识别更新记录"
                if projection.inventoryError then hint=projection.inventoryHint end
                -- 进度只显示Feature确认的移动；成功、主动停止和原生拒绝均有反馈，不能把发出移动当作已取出。
                if running then
                    hint="正在取图：已确认 "..tostring(withdraw.moved or 0).."/"..tostring(withdraw.limit or 0).." 张"
                    errorText=instance.treasureActionError -- 历史地图动作错误不能遮住正在进行的取图进度。
                elseif withdraw.error then hint="取图停止："..tostring(withdraw.error).." · 已确认 "..tostring(withdraw.moved or 0).." 张"
                elseif withdraw.status=="done" then hint="本次已取出 "..tostring(withdraw.moved or 0).." 张 · "..hint
                elseif withdraw.status=="cancelled" then hint="已停止取图：已确认 "..tostring(withdraw.moved or 0).." 张 · "..hint
                elseif selectedCount>0 then hint="本箱该坐标 "..tostring(selectedCount).." 张 · 点击取出同坐标将全部取出 · "..hint end
            end
            if sea then
                hint="本轮 已搜 "..tostring(projection.roundSearched or 0).."/"..tostring(projection.roundTotal or 0)
                    .." · 待搜 "..tostring(projection.roundRemaining or 0)
                if (projection.roundSkipped or 0)>0 then hint=hint.." · 跳过 "..tostring(projection.roundSkipped) end
                if (projection.recheckCount or 0)>0 then hint=hint.." · 可复查 "..projection.recheckCount end
            end
            if selected and selected.kind=="custom" then
                hint="自定义点："..tostring(selected.text or "")..(selected.distance and (" · "..math.floor(selected.distance+0.5).."m") or "")
            end
            instance.treasureInteractionHint:SetText(errorText and ("操作未完成：" .. tostring(errorText)) or hint)
            if projection.mapActionPending == true then instance.treasureInteractionHint:SetText("地图定位等待中，冷却结束后自动执行") end -- 助手复用同一待执行请求，不另启计时器。
        end
    end,
    rows = function(projection)
        local rows = projection.rows or projection.maps or {}
        for _, row in ipairs(rows) do
            row.directionText=tostring(row.direction or "--")..(row.distance and (" · "..tostring(math.floor(row.distance+0.5)).."m") or "")
            row.targetText=(row.regionName and (row.regionName.." · ") or "")..tostring(row.groupKey and row.text or row.name or "")
            row.searchText=row.timerText or row.visitText
        end
        return rows
    end,
    onItemActivated = function(instance, row, Feature)
        -- TableView每次行点击都会activated，必须先识别同一张图的第二次点击。
        return TreasureMapInteraction:Activate(instance, row, Feature)
    end,
    columns = {
        { id="name", title="追踪目标", field="targetText", size="fill", minWidth=88, fill=1 },
        { id="direction", title="方向 / 距离", field="directionText", size="fixed", width=86, minWidth=60 },
        { id="visit", title="数量 / 搜查", field="searchText", size="fixed", width=108, minWidth=60 },
    },
    status = function(projection, rows)
        if projection.lastMapActionError ~= nil then return "地图定位失败 · " .. tostring(projection.lastMapActionError) end
        local selected = projection.selected
        return selected and ((selected.regionName and (selected.regionName.." · ") or "")..tostring(selected.name or "").." · "..tostring(selected.direction or "--")..(selected.distance and (" · "..tostring(math.floor(selected.distance+0.5)).."m") or "")..(selected.timerText and (" · "..selected.timerText) or "")) or (tostring(#rows)..(projection.viewKind=="maps" and " 处坐标" or " 个资料点"))
    end,
})
if ok ~= true then error(err) end

ok, err = Register({
    featureName = "Fishing", featureId = "life_fishing", widgetId = "life.fishing", token = "life_fishing", owner = "v3:widget:life_fishing",
    rootId = "v3_life_fishing_widget", contentId = "v3_life_fishing_widget_content", tableId = "v3_life_fishing_widget_table", title = "钓鱼助手",
    emptyTitle = "等待鱼动作", emptyDetail = "选中鱼后会根据已核动作 Buff 给出技能栏建议。",
    buildControls = function(instance, content, Feature)
        -- 主页面与 HUD 必须共享 Fishing.Commands 的可逆 Hotkey 事务；
        -- HUD 不持有 autoArmed 副本、不直接调用 X2Hotkey。ArmAuto 成功后 Auto-R 自有 Demand lease 会继续维持观察，关闭主菜单不影响钓鱼流程。
        if type(Feature.Commands.ArmAuto) ~= "function" or type(Feature.Commands.DisarmAuto) ~= "function" then return false, "钓鱼自动 R 命令缺失" end
        local row = RSUI:HorizontalBox({ id = (instance.contentPrefix or "v3_life_fishing_widget_") .. "auto_row", parent = content, gap = 4, slot = { size = "fixed", height = 28, hAlign = "fill" } })
        instance.fishingAutoButton = RSUI:Button({ id = (instance.contentPrefix or "v3_life_fishing_widget_") .. "auto", parent = row, text = "启用自动 R", compact = true, slot = { size = "fill", fill = 1, minWidth = 100 } })
        instance.fishingAutoButton.onClick = function()
            local projection = Feature:GetProjection() or {}
            local armed = projection.autoArmed == true
            local actionOk, actionErr
            -- 不能写 armed and DisarmAuto() or ArmAuto()：DisarmAuto 合法返回 false 时会继续执行 ArmAuto，
            -- 把关闭变成重新启用。显式分支保证每次点击只提交一个意图。
            if armed then
                actionOk, actionErr = Feature.Commands:DisarmAuto()
            else
                actionOk, actionErr = Feature.Commands:ArmAuto()
            end
            instance:Refresh()
            return actionOk, actionErr
        end
        return true
    end,
    refreshControls = function(instance, projection)
        if instance.fishingAutoButton then
            -- 已 armed 时即使战斗导致 autoAvailable=false 也必须允许点击“关闭自动 R”；Disarm 会按既有事务进入延迟恢复，不能把退出按钮禁掉。
            local armed = projection.autoArmed == true
            local autoAvailable = projection.autoAvailable == true
            instance.fishingAutoButton:SetText(armed and "关闭自动 R" or (autoAvailable and "启用自动 R" or "自动 R 不可用"))
            instance.fishingAutoButton:SetEnabled(armed or autoAvailable)
        end
    end,
    rows = function(projection) return { { key="fishing", message=projection.message or "等待鱼动作", buffText=projection.buffId and tostring(projection.buffId) or "--", slotText=projection.slot and tostring(projection.slot) or "--", statusText=projection.status or "--" } } end,
    columns = {
        { id="message", title="当前动作 / 建议", field="message", size="fill", minWidth=150, fill=1 },
        { id="slot", title="技能栏", field="slotText", size="fixed", width=58, minWidth=50 },
        { id="buff", title="动作ID", field="buffText", size="fixed", width=70, minWidth=60 },
    },
    status = function(projection)
        if projection.autoArmed ~= true and projection.autoAvailable ~= true and projection.autoBlockedReason ~= nil then return tostring(projection.autoBlockedReason) end
        return tostring(projection.message or projection.status or "等待鱼动作")
    end,
})
if ok ~= true then error(err) end

S.UIV3 = S.UIV3 or {}
-- HUD v9 检查债券设置菜单及 Trade 收藏、控件隔离接口，防止新 Gate 混入旧组件。
S.UIV3.LifeEconomyWidgetsV3 = { version = 9, tradeFloatingFavoriteContractVersion = 1, tradeControlRefreshIsolationContractVersion = 1, bondsMaterialColumnContractVersion = 3, bondsMultiContinentContractVersion = 3, bondsDropdownControlsContractVersion = 3, bondsFloatingSettingsMenuContractVersion = 1, bondsResidentBoardFamilyContractVersion = 1, treasureMapLocationContractVersion = 2, fishingFloatingAutoRContractVersion = 1, widgetIds = { "life.trade", "life.bonds", "life.treasure", "life.fishing" } }
