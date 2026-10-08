------------------------------------------------------------------------
-- 整理背包设置：只展示 Feature 的背包快照与持久黑名单，不拥有搬运队列。
-- 窗口布局/筛选是当代 Session 状态；黑名单写入唯一 tools_bag Store。
-- 无定时扫描；打开或显式刷新才取得 InventorySnapshot，隐藏后释放自身 Consumer。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local R = S.RSUI
local F = S.Features and S.Features.tools_bag
if type(R) ~= "table" or type(R.FloatingSurface) ~= "table" or type(F) ~= "table" then return end
S.UIV3 = S.UIV3 or {}
local M = { version=1, generation=S.Generation, visible=false, consumerHeld=false, tab="bag", filter="", windowState={}, renderRevision=0 }
S.UIV3.BagSettingsFloatingV3 = M
local TOKEN = "floating:bag_settings"
local function Text(value) return tostring(value or ""):match("^%s*(.-)%s*$") or "" end

function M:Deactivate()
    self.visible=false
    if self.surface then self.surface:Show(false) end
    if S.Events then S.Events:UnsubscribeInternalOwner(self) end
    if self.consumerHeld then
        local ok,err=F:ReleaseConsumer(TOKEN)
        if ok~=true then return false,err end
        self.consumerHeld=false
    end
    return true
end
function M:Close(reason)
    if self.surface then
        local ok,err=self.surface:Close(reason or "bag_settings_close")
        if ok~=true then return false,err end
    end
    return self:Deactivate()
end
function M:Status(message)
    self.lastMessage=Text(message)
    if self.surface then self.surface:SetStatus(self.lastMessage) end
end
function M:ToggleItem(row)
    if self.visible~=true or F.enabled~=true then return false,"设置窗口已关闭" end
    local id=tonumber(row and row.itemType)
    if id==nil or id<=0 then self:Status("物品尚未提供有效 ID，请刷新背包后再试。");return false,"物品 ID 未知" end
    local ok,err
    if row.blocked==true then ok,err=F.Commands:RemoveGlobalBlacklistItem(id)
    else ok,err=F.Commands:AddGlobalBlacklistItem(id,row.name) end
    if ok~=true then self:Status("保存失败："..tostring(err or "未提交"));return false,err end
    self:Refresh()
    self:Status(row.blocked==true and "已移出黑名单。" or "已加入黑名单，对银行和箱子同时生效。")
    return true
end
function M:Refresh()
    if self.visible~=true then return true end
    local p=F:GetProjection() or {}
    local blocked,rows,seen={}, {}, {}
    for _,entry in ipairs(p.blacklistRows or {}) do blocked[tostring(entry.itemType)]=entry end
    local filter=Text(self.filter):lower()
    local function Add(entry,blacklisted)
        local id=tonumber(entry.itemType)
        local name=Text(entry.itemName or entry.name)
        local key=tostring(id or entry.key or name)
        if seen[key] then return end
        if filter~="" and not name:lower():find(filter,1,true) and not key:find(filter,1,true) then return end
        seen[key]=true
        rows[#rows+1]={key=key,itemType=id,name=name,quantity=tonumber(entry.stack) or 0,
            blocked=blacklisted==true,state=blacklisted==true and "在名单" or "可整理"}
    end
    if self.tab=="blacklist" then
        local quantities={};for _,entry in ipairs(p.bagItemRows or {}) do quantities[tostring(entry.itemType)]=entry.stack end
        for _,entry in ipairs(p.blacklistRows or {}) do
            Add({itemType=entry.itemType,itemName=entry.itemName,stack=quantities[tostring(entry.itemType)]},true)
        end
    else
        for _,entry in ipairs(p.bagItemRows or {}) do Add(entry,blocked[tostring(entry.itemType)]~=nil) end
    end
    self.renderRevision=self.renderRevision+1
    self.table:SetItems(rows,self.renderRevision)
    self.table:SetViewState(#rows>0 and "ready" or "empty",{title=self.tab=="blacklist" and "黑名单为空" or "未找到背包物品",detail="可清除筛选，或点击刷新背包。"})
    self.toggle:SetText((p.blacklist or {}).enabled~=false and "黑名单：开" or "黑名单：关")
    if self.lastMessage==nil then self.surface:SetStatus("共 "..tostring(#rows).." 项；点击行内按钮添加或移除。") end
    return true
end

function M:EnsureCreated()
    if self.surface then return true end
    local surface,err=R.FloatingSurface:Create({
        id="v3_bag_settings_floating",owner="v3:bag_settings:floating",title="整理背包设置",footer=true,
        movable=true,resizable=true,minimizeMode="compact",boundaryMode="free",defaultPlacement="center",
        statePolicy={defaultWidth=530,defaultHeight=430,minWidth=410,minHeight=300},
        getState=function()return self.windowState end,
        setState=function(value)self.windowState=value;return true end,persist=function()return true end,
        onClosed=function()return self:Deactivate() end,
    })
    if surface==nil then return false,err end
    self.surface=surface
    local body=R:VerticalBox({id="v3_bag_settings_body",parent=surface:GetContentRoot(),gap=6,slot={size="fill",fill=1,hAlign="fill",vAlign="fill"}})
    R:Text({id="v3_bag_settings_help",parent=body,text="放只移动仓库已有同类；全放尝试所有非黑名单物品。黑名单对银行和箱子同时生效。物品变化后点刷新背包。",
        fontSize=9,tone="muted",overflow="wrap",slot={size="auto",minHeight=34,hAlign="fill"}})
    local placement=R:HorizontalBox({id="v3_bag_settings_placement",parent=body,gap=5,slot={size="fixed",height=28,hAlign="fill"}})
    R:Text({id="v3_bag_settings_drag_help",parent=placement,text="拖动悬浮栏左侧 ≡，松开自动保存位置。",fontSize=9,tone="muted",slot={size="fill",fill=1,minWidth=120}})
    local reset=R:Button({id="v3_bag_settings_reset_position",parent=placement,text="重置悬浮栏位置",compact=true,slot={size="fixed",width=114}})
    reset.onClick=function()
        local bar=S.UIV3 and S.UIV3.BagQuickOverlay
        if type(bar)~="table" or type(bar.ResetPosition)~="function" then self:Status("悬浮栏尚未加载。");return false,"悬浮栏不可用" end
        local ok,resetErr=bar:ResetPosition()
        self:Status(ok==true and "悬浮栏位置已重置。" or ("位置重置失败："..tostring(resetErr or "未保存")))
        return ok,resetErr
    end
    local controls=R:HorizontalBox({id="v3_bag_settings_controls",parent=body,gap=5,slot={size="fixed",height=28,hAlign="fill"}})
    R:SegmentedSelector({id="v3_bag_settings_tab",parent=controls,items={{value="bag",text="背包物品"},{value="blacklist",text="黑名单"}},itemWidth=76,height=26,gap=3,
        get=function()return self.tab end,set=function(value)self.tab=value;self.lastMessage=nil;return self:Refresh() end,slot={size="fixed",width=155}})
    self.toggle=R:Button({id="v3_bag_settings_toggle",parent=controls,text="黑名单：开",compact=true,slot={size="fixed",width=94}})
    self.toggle.onClick=function()
        local p=F:GetProjection();local ok,err=F.Commands:SetBlacklistEnabled((p.blacklist or {}).enabled~=true)
        if ok~=true then self:Status("保存失败："..tostring(err));return false,err end
        self:Refresh();self:Status((F:GetProjection().blacklist or {}).enabled==true and "黑名单已开启。" or "黑名单已关闭，整理时将不再排除名单物品。")
        return true
    end
    local refresh=R:Button({id="v3_bag_settings_refresh",parent=controls,text="刷新背包",compact=true,slot={size="fixed",width=84}})
    refresh.onClick=function()
        local ok,readErr=F.Commands:Refresh("bag_settings_manual")
        if ok~=true then self:Status("刷新失败："..tostring(readErr));return false,readErr end
        self.lastMessage=nil;return self:Refresh()
    end
    local search=R:HorizontalBox({id="v3_bag_settings_search",parent=body,gap=5,slot={size="fixed",height=28,hAlign="fill"}})
    self.input=R:TextInput({id="v3_bag_settings_filter",parent=search,value="",maxLength=96,placeholder="筛选物品名称或 ID",commitMode="explicit",slot={size="fill",fill=1,minWidth=130}})
    local apply=R:Button({id="v3_bag_settings_apply",parent=search,text="筛选",compact=true,slot={size="fixed",width=48}})
    apply.onClick=function()self.filter=Text(self.input:GetDraftValue());self.lastMessage=nil;return self:Refresh() end
    local clear=R:Button({id="v3_bag_settings_clear_filter",parent=search,text="清除",compact=true,slot={size="fixed",width=48}})
    clear.onClick=function()self.filter="";self.input:SetValue("",false);self.lastMessage=nil;return self:Refresh() end
    local add=R:Button({id="v3_bag_settings_manual_add",parent=search,text="输入添加",compact=true,slot={size="fixed",width=76}})
    add.onClick=function()
        local ok,addErr=F.Commands:ResolveAndAddBlacklistItem(Text(self.input:GetDraftValue()))
        if ok~=true then self:Status("添加失败："..tostring(addErr));return false,addErr end
        self:Refresh();self:Status("已保存到黑名单。可切换黑名单页查看。")
        return true
    end
    self.table=R:TableView({id="v3_bag_settings_items",parent=body,items={},rowHeight=28,headerHeight=26,desiredRows=8,overscan=0,
        scrollbar=true,headerInteractive=false,selectable=false,columns={
            {id="name",title="物品",field="name",size="fill",minWidth=150},
            {id="quantity",title="持有",field="quantity",size="fixed",width=58,minWidth=48},
            {id="state",title="状态",field="state",size="fixed",width=66,minWidth=60},
            {id="action",title="操作",cellType="button",size="fixed",width=64,minWidth=64,absoluteMinWidth=64,sortable=false,resizable=false,
                getText=function(row)return row and row.blocked==true and "移出" or "加入" end,onClick=function(row)return self:ToggleItem(row) end},
        },slot={size="fill",fill=1,hAlign="fill",vAlign="fill"}})
    if body==nil or self.input==nil or self.table==nil or self.toggle==nil then
        -- Open 统一销毁部分创建的 Surface；这里保留引用，避免丢失 Native root。
        return false,"背包设置控件创建失败"
    end
    return true
end
function M:Open()
    if F.enabled~=true then return false,"请先启用整理背包" end
    if self.generation~=S.Generation then return false,"背包设置窗口已失效" end
    local built,ok,err=xpcall(function()return self:EnsureCreated() end,S.SafeTraceback)
    if built~=true or ok~=true then
        self.lastError=tostring(built==true and err or ok)
        if self.surface then self.surface:Destroy() end
        self.surface,self.input,self.table,self.toggle=nil,nil,nil,nil
        return false,self.lastError
    end
    if not self.consumerHeld then
        local acquired,acquireErr=F:AcquireConsumer(TOKEN)
        if acquired~=true then return false,acquireErr end
        self.consumerHeld=true
    end
    self.visible=true;self.lastMessage=nil
    if S.Events then
        S.Events:UnsubscribeInternalOwner(self)
        local subscribed,subscribeErr=S.Events:SubscribeInternal(F.UpdateTopic,self,function(_owner,_revision,reason)
            -- 100ms 几何心跳不重建物品表、不扫描背包。只响应真实快照/黑名单变化。
            if tostring(reason or ""):sub(1,10)=="bag_quick_" then return true end
            return self:Refresh()
        end)
        if subscribed~=true then self:Deactivate();return false,subscribeErr or "背包更新订阅失败" end
        subscribed,subscribeErr=S.Events:SubscribeInternal("v3.feature.lifecycle",self,function(_,id,state)
            if id==F.Id and state=="disabled" then
                self.consumerHeld=false -- Feature 已 Clear Demand，不再释放旧 token。
                return self:Deactivate()
            end
            return true
        end)
        if subscribed~=true then self:Deactivate();return false,subscribeErr or "功能状态订阅失败" end
    else
        self:Deactivate();return false,"事件服务不可用"
    end
    local refreshed,refreshErr=self:Refresh()
    if refreshed~=true then self:Deactivate();return false,refreshErr end
    self.surface:SetMinimized(false,false)
    local shown,showErr=self.surface:Show(true)
    if shown~=true then self:Deactivate();return false,showErr end
    return true
end
function M:GetHealth()
    return {version=self.version,visible=self.visible,consumerHeld=self.consumerHeld,generation=self.generation,
        tab=self.tab,filter=self.filter,renderRevision=self.renderRevision,lastMessage=self.lastMessage,lastError=self.lastError}
end
