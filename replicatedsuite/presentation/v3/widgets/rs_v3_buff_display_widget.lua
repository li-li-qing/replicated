------------------------------------------------------------------------
-- Replicated Suite V3 - Buff Display Floating Widget
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
local Host = S.UIV3 and S.UIV3.WidgetHost or nil
local Feature = S.Features and S.Features.BuffDisplay or nil
local Floating = RSUI and RSUI.FloatingSurface or nil
if type(RSUI) ~= "table" or type(Host) ~= "table" or type(Feature) ~= "table" or type(Floating) ~= "table" then return end

local ID, OWNER = "combat.buff_display", "v3:widget:buff_display"
-- 维护：新增筛选/操作行需要可操作最小尺寸；旧位置/透明度原样保留，过小旧尺寸仅按政策钳制。
local function Policy() return { defaultWidth = 430, defaultHeight = 300, minWidth = 330, minHeight = 220, defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1, defaultTextOpacity = 1 } end
local function Persist(reason) return Feature.Commands:MarkStoreDirty(250, "widget_" .. tostring(reason or "state")) end

local function CreateWidget()
    local instance = { id = ID, owner = OWNER, visible = false, subscribed = false, rows = {}, selectedRow = nil, channelButtons = {} }
    local surface, err = Floating:Create({ id = "v3_buff_display_widget", owner = OWNER, title = "状态追踪", status = "--", footer = true, resizable = true, movable = true, minimizeMode = "compact", boundaryMode = "free", defaultPlacement = "top-right", statePolicy = Policy(), getState = function() return Feature:GetWidgetWindowState() end, setState = function(value, reason) return Feature.Commands:SetWidgetWindowState(value, reason) end, persist = Persist, onClosed = function(_, reason) return Host:NotifyWindowClosed(ID, { source = tostring(reason or "widget_close"), persist = true }) end })
    if surface == nil then return nil, err or "状态显示悬浮窗创建失败" end
    instance.surface, instance.shell, instance.window, instance.root, instance.windowController = surface, surface.shell, surface.window, surface.shell.root, surface.windowController
    local content = RSUI:VerticalBox({ id = "v3_buff_display_widget_content", parent = surface:GetContentRoot(), gap = 4, slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    -- 维护（compact-tracker-1）：复用Feature管理投影/持久化命令，不创建第二套Aura监听或追踪Store。
    -- 窗口视图是会话状态；已有位置/透明度不重置。实时与留存视图明确分开，不停正式HUD。
    instance.view,instance.scope,instance.filter,instance.query="live","all","all",""
    local views=RSUI:HorizontalBox({id="v3_buff_widget_views",parent=content,gap=4,slot={size="fixed",height=26}})
    instance.viewSelector=RSUI:SegmentedSelector({id="v3_buff_widget_view",parent=views,itemWidth=80,height=26,
        items={{value="live",text="当前状态"},{value="frozen",text="留存记录"},{value="tracked",text="已追踪"}},
        get=function()return instance.view end,set=function(v)return instance:SetView(v)end,
        slot={size="fill",fill=1}})
    local filters=RSUI:HorizontalBox({id="v3_buff_widget_filters",parent=content,gap=4,slot={size="fixed",height=28}})
    instance.scopeInput=RSUI:Dropdown({id="v3_buff_widget_scope",parent=filters,
        items={{value="all",text="全部来源"},{value="player",text="自己"},{value="target",text="目标"}},
        get=function()return instance.scope end,set=function(v)instance.scope=v;return instance:Refresh()end,
        slot={size="fixed",width=88}})
    RSUI:Dropdown({id="v3_buff_widget_filter",parent=filters,
        items={{value="all",text="全部类型"},{value="buff",text="Buff"},{value="debuff",text="Debuff"},{value="auto",text="待分类"}},
        get=function()return instance.filter end,set=function(v)instance.filter=v;return instance:Refresh()end,
        slot={size="fixed",width=88}})
    instance.search=RSUI:TextInput({id="v3_buff_widget_search",parent=filters,placeholder="名称 / ID",commitOnEnter=true,
        get=function()return instance.query end,set=function(v)instance.query=tostring(v or "");return instance:Refresh()end,
        slot={size="fill",fill=1,minWidth=68}})
    local actions=RSUI:HorizontalBox({id="v3_buff_display_widget_actions",parent=content,gap=4,slot={size="fixed",height=26}})
    instance.captureButton=RSUI:Button({id="v3_buff_widget_capture",parent=actions,text="持续留存",compact=true,slot={size="fixed",width=108}})
    local clear=RSUI:Button({id="v3_buff_widget_clear",parent=actions,text="清空留存",compact=true,slot={size="fixed",width=76}})
    local settings=RSUI:Button({id="v3_buff_display_widget_settings",parent=actions,text="设置",compact=true,slot={size="fixed",width=48}})
    settings.onClick=function()
        local shell=S.UIV3 and S.UIV3.shell
        if shell and type(shell.Navigate)=="function" then return shell:Navigate("combat.buff_display",{source="buff_display_widget"}) end
        return false,"主页面不可用"
    end
    instance.captureButton.onClick=function()
        local active=Feature:GetManagementFreezeState().active
        local ok,err
        if active then ok,err=Feature.Commands:ClearManagementFreeze() else ok,err=Feature.Commands:CaptureManagementFreeze() end
        if ok then instance:Refresh() else instance.surface:SetStatus(tostring(err),"warn") end
        return ok,err
    end
    clear.onClick=function()local ok,err=Feature.Commands:ResetManagementCapture();if ok then instance:Refresh()end;return ok,err end
    instance.table=RSUI:TableView({id="v3_buff_display_widget_table",parent=content,items={},rowHeight=24,headerHeight=23,
        desiredRows=9,overscan=1,scrollbar=true,selectable=false,headerInteractive=false,
        -- 可见行仅入队；Native查询由共享有界Metadata任务执行，render中不直接读API。
        bindRow=function(_,item)if item and item.id then Feature:QueueManagementMetadata(item.id)end end,
        onItemActivated=function(item)
            if type(item)~="table" or not item.id then return false,"状态行无效" end
            instance.selectedRow=item
            if type(instance.RefreshSelectedControls)=="function" then instance:RefreshSelectedControls() end
            return true
        end,
        columns={
            {id="icon",title="",field="iconPath",cellType="icon",iconSize=16,fallbackIcon="ui/icon/icon_unknown_item.dds",size="fixed",width=22,minWidth=20},
            {id="name",title="状态 / 点击选择",field="name",size="fill",minWidth=68,fill=1},
            {id="source",title="来源",field="scopeText",size="fixed",width=36,minWidth=30},
            {id="type",title="类型",field="effectTypeText",size="fixed",width=50,minWidth=44},
            {id="stack",title="层",field="stack",size="fixed",width=26,minWidth=22},
            {id="time",title="剩余",field="timeText",size="fixed",width=50,minWidth=42},
            {id="tracked",title="追踪位置",field="trackedText",size="fixed",width=112,minWidth=90}},
        slot={size="fill",fill=1,hAlign="fill",vAlign="fill"}})
    -- 中文维护（tracking-scope-v1）：小窗复用同一四通道命令，不创建第二套追踪状态。
    -- 行激活仅选择；通道按钮才跨 Persistence boundary。关闭小窗不会影响正式 HUD Consumer。
    local scopeActions=RSUI:HorizontalBox({id="v3_buff_widget_scope_actions",parent=content,gap=4,slot={size="fixed",height=27,hAlign="fill"}})
    local defs={
        {id="v3_buff_widget_player_buff",scope="player",category="buff",label="自身 Buff",status="自身·Buff"},
        {id="v3_buff_widget_player_debuff",scope="player",category="debuff",label="自身 Debuff",status="自身·Debuff"},
        {id="v3_buff_widget_target_buff",scope="target",category="buff",label="目标 Buff",status="目标·Buff"},
        {id="v3_buff_widget_target_debuff",scope="target",category="debuff",label="目标 Debuff",status="目标·Debuff"},
    }
    local function ValidSelected() local r=instance.selectedRow;return type(r)=="table" and r.id~=nil and r.kind~="skill" and r.kind~="mate" end
    function instance:RefreshSelectedControls()
        local row=self.selectedRow;local valid=ValidSelected();local labels={}
        for _,def in ipairs(defs) do
            local b=self.channelButtons[def.id];local active=valid and Feature:IsTrackedChannel(row.id,def.scope,def.category)==true
            if b then b:SetEnabled(valid);b:SetText((active and "✓ " or "")..def.label) end
            if active then labels[#labels+1]=def.status end
        end
        if valid and Feature:IsTrackedChannel(row.id,"player","auto") then labels[#labels+1]="自身·自动" end
        if valid and Feature:IsTrackedChannel(row.id,"target","auto") then labels[#labels+1]="目标·自动" end
        self.selectedTrackingText=valid and (#labels>0 and table.concat(labels," / ") or "未追踪") or nil
        return true
    end
    local function Toggle(scope,category)
        if not ValidSelected() then instance:RefreshSelectedControls();return false,"请先点击一个 Buff / Debuff 状态行" end
        local row=instance.selectedRow;local enabled=not Feature:IsTrackedChannel(row.id,scope,category)
        local ok,err=Feature.Commands:SetTrackedChannel(row.id,scope,category,enabled)
        if ok then instance:Refresh() else instance.surface:SetStatus("追踪失败："..tostring(err),"warn") end
        instance:RefreshSelectedControls();return ok,err
    end
    for _,def in ipairs(defs) do local d=def;local b=RSUI:Button({id=d.id,parent=scopeActions,text=d.label,compact=true,
        onClick=function() return Toggle(d.scope,d.category) end,slot={size="fill",fill=1,minWidth=88}});b:SetEnabled(false);instance.channelButtons[d.id]=b end
    function instance:SetView(view)
        if view~="live" and view~="frozen" and view~="tracked" then return false,"invalid_view" end
        self.view=view
        if view=="tracked" then self.scope="all" end -- 收藏没有当前单位身份，不能沿用目标筛选造成空列表。
        self.scopeInput:SetEnabled(view~="tracked");self.scopeInput:Render();self.viewSelector:Render()
        return self:Refresh()
    end
    function instance:Refresh()
        local rows,revision=Feature:GetManagementProjection({view=self.view,scope=self.scope,filter=self.filter,
            query=self.query,cacheOwner="widget",preserveLive=true})
        if self.managementRevision~=revision or self.rows~=rows then
            self.managementRevision=revision;self.rows=rows;self.table:SetItems(rows,revision)
            self.table:SetViewState(#rows>0 and "ready" or "empty",{title="此视图暂无状态",detail="当前：观察状态；留存：保留短状态；已追踪：管理收藏。"})
        end
        local capture=Feature:GetManagementFreezeState()
        self.captureButton:SetText(capture.active and "停止并清空" or "持续留存")
        self:RefreshSelectedControls()
        local selected=self.selectedRow and (" · 所选 "..tostring(self.selectedRow.name or self.selectedRow.id).."："..tostring(self.selectedTrackingText or "不可设置")) or ""
        self.surface:SetStatus((self.view=="tracked" and "已追踪 " or self.view=="frozen" and "留存 " or "当前 ")..#rows
            ..selected..(capture.active and " · 持续留存中" or "")..(capture.overflow and " · 留存已达上限" or ""),capture.overflow and "warn" or "accent")
        return true
    end
    function instance:Subscribe()
        if self.subscribed == true then return true end
        if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
            S.Events:SubscribeInternal("v3.buff_display.updated", self, function() if instance.visible then instance:Refresh() end end)
            -- Tracked-id mutations (row click, quick import) also publish the
            -- settings topic; refresh on it too so the tracking manager always
            -- mirrors the authoritative list.
            S.Events:SubscribeInternal("v3.buff_display.settings", self, function() if instance.visible then instance:Refresh() end end)
        end
        self.subscribed = true
        return true
    end
    function instance:Unsubscribe()
        if self.subscribed ~= true then return true end
        if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        self.subscribed = false
        return true
    end
    function instance:Show(context)
        if self.visible == true then self:Refresh(); return self.surface:Show(true) end
        local acquired = false
        local ok, showErr = xpcall(function()
            self:Subscribe()
            local acquireOk, acquireErr = Feature:AcquireConsumer("widget:buff_display")
            if acquireOk ~= true then error(acquireErr or "状态显示悬浮窗订阅失败") end
            acquired = true
            Feature:SetManagementPageActive(true,"widget")
            -- Fill the projection synchronously (the aura lane only runs on the
            -- next Scheduler frame) so live rows carry their name/icon and the
            -- tracking list is not all-"已消失" placeholders on first open.
            if type(Feature.Commands) == "table" and type(Feature.Commands.Refresh) == "function" then
                Feature.Commands:Refresh("widget_show")
            end
            self:Refresh()
            if self.surface:Show(true) ~= true then error("状态显示悬浮窗显示失败") end
        end, S.SafeTraceback)
        if ok ~= true then
            self.surface:Show(false); Feature:SetManagementPageActive(false,"widget"); self:Unsubscribe(); if acquired then Feature:ReleaseConsumer("widget:buff_display") end; self.visible = false
            return false, showErr
        end
        self.visible = true
        if type(context) ~= "table" or context.persist ~= false then Feature.Commands:SetWidgetVisible(true, "show") end
        return true
    end
    function instance:Hide(context)
        if self.search and type(self.search.CancelEditing)=="function" then self.search:CancelEditing("widget_hide") end
        local hidden, hideErr = self.surface:Show(false)
        if hidden ~= true then return false, hideErr end
        local released, releaseErr = true, nil
        if self.visible == true and S.FeatureRuntime:IsEnabled("combat_buff_display") == true then
            released, releaseErr = Feature:ReleaseConsumer("widget:buff_display")
        end
        Feature:SetManagementPageActive(false,"widget"); self.visible = false; self:Unsubscribe()
        if type(context) ~= "table" or context.persist ~= false then Feature.Commands:SetWidgetVisible(false, "hide") end
        if released ~= true then return false, releaseErr end
        return true
    end
    function instance:OnWindowClosed(context)
        if self.search and type(self.search.CancelEditing)=="function" then self.search:CancelEditing("widget_close") end
        local released, releaseErr = true, nil
        if self.visible == true and S.FeatureRuntime:IsEnabled("combat_buff_display") == true then released, releaseErr = Feature:ReleaseConsumer("widget:buff_display") end
        Feature:SetManagementPageActive(false,"widget"); self.visible = false; self:Unsubscribe()
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
local ok, err = Host:Register(ID, { featureId = "combat_buff_display", create = CreateWidget, ensurePreferences = function() return Feature:EnsureStoreLoaded() end, lockable = true, minimizable = true, resettable = true, opacityAdjustable = true, backgroundOpacityAdjustable = true, textOpacityAdjustable = true, getLocked = adapter.getLocked, setLocked = adapter.setLocked, getMinimized = adapter.getMinimized, setMinimized = adapter.setMinimized, getOverallOpacity = adapter.getOverallOpacity, setOverallOpacity = adapter.setOverallOpacity, getOpacity = adapter.getOpacity, setOpacity = adapter.setOpacity, getBackgroundOpacity = adapter.getBackgroundOpacity, setBackgroundOpacity = adapter.setBackgroundOpacity, getTextOpacity = adapter.getTextOpacity, setTextOpacity = adapter.setTextOpacity, resetLayout = adapter.resetLayout })
if ok ~= true then error(err) end
if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
    Host:BindFeatureLifecycle(ID, { featureId = "combat_buff_display", enabled = function() return S.FeatureRuntime:IsEnabled("combat_buff_display") == true end, preference = function() return Feature:GetWidgetVisible() == true end, onShowFailed = function() Feature.Commands:SetWidgetVisible(false, "auto_show_failed") end })
end
