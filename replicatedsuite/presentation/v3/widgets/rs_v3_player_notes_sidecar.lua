------------------------------------------------------------------------
-- 中文维护：人员备注收到社交名单或团队窗口事件时弹出；事件不提供社交窗口关闭/位置，因此使用独立浮窗。
-- 手动关闭保持收起，下一次真实名单响应再弹出；仅表示层拥有窗口/草稿，备注仍走同一Feature Store。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
local R,Host=S.RSUI,S.UIV3 and S.UIV3.WidgetHost
local F=S.Features and S.Features.PlayerNotes
local Observer=S.Services and S.Services.PlayerNotesSurfaceV3
if not R or not Host or not F or not Observer or not R.FloatingSurface then return end
local ID,TOKEN="tools.player_notes_sidecar","widget:player_notes"
local WIDTH,HEIGHT=420,460
local C={openRequested=false,dismissed=false,snapshot={},session=0,lastFriendListRevision=0,lastListRevision=0}
S.UIV3.PlayerNotesSidecar=C
if S.ModuleDiagnosticsHub and type(S.ModuleDiagnosticsHub.RegisterProvider)=="function"then
    S.ModuleDiagnosticsHub:RegisterProvider("tools_player_notes","social_surface",function()
        local d=Observer:GetDiagnostics();d.dismissed=C.dismissed;d.openRequested=C.openRequested;d.session=C.session
        local instance=Host:GetInstance(ID)
        if instance then d.popupVisible=instance.visible==true;d.consumerAcquired=instance.acquired==true end
        return d
    end,70,{detailOnly=true})
end
local function Position(snapshot)
    local ctx=S.Layout and S.Layout:GetContext()or {}
    local left,top=tonumber(ctx.safeLeft)or 0,tonumber(ctx.safeTop)or 0
    local right,bottom=(tonumber(ctx.logicalWidth)or 1024)-(tonumber(ctx.safeRight)or 0),(tonumber(ctx.logicalHeight)or 768)-(tonumber(ctx.safeBottom)or 0)
    -- 中文维护：没有原生社交几何，不虚构贴边位置；首次居中，用户拖动后保持自身窗口位置。
    return math.floor(math.max(left,(left+right-WIDTH)/2)),math.floor(math.max(top,(top+bottom-HEIGHT)/2))
end
local function Create()
    local instance={visible=false,acquired=false,state={width=WIDTH,height=HEIGHT,locked=false,userMoved=false,coordinateSpace="logical-free-v2"}}
    instance.state.x,instance.state.y=Position(C.snapshot)
    local surface,why=R.FloatingSurface:Create({id="v3_player_notes_sidecar",owner="v3:widget:player_notes",title="人员备注",status="收到名单时显示",
        -- 中文维护：420×460是可读最小尺寸而非固定尺寸；拖动/边缘缩放仍由共享Windowing事务负责，刷新不能重置用户几何。
        width=WIDTH,height=HEIGHT,minWidth=WIDTH,maxWidth=1000,minHeight=HEIGHT,maxHeight=1000,
        resizable=true,movable=true,closeButton=true,appearanceControls=false,
        statePolicy={defaultWidth=WIDTH,defaultHeight=HEIGHT,minWidth=WIDTH,maxWidth=1000,minHeight=HEIGHT,maxHeight=1000,defaultLocked=false},
        getState=function()return instance.state end,
        setState=function(value)instance.state=value;return true end,
        persist=function()return true end,
        onClosed=function()C.dismissed=true;C.session=C.session+1;return Host:NotifyWindowClosed(ID,{persist=false,source="notes_user_close"})end})
    if not surface then return nil,why end
    instance.surface,instance.shell,instance.windowController=surface,surface.shell,surface.windowController
    local root=R:VerticalBox({id="v3_notes_popup_content",parent=surface:GetContentRoot(),gap=5,slot={size="fill",fill=1,hAlign="fill",vAlign="fill"}})
    if not root then return nil,"备注窗口内容构建失败"end
    -- 中文维护（2026-10-13）：四类社交名单一行，团队/已保存单独一行；420px小窗不能挤六个页签造成裁切。
    local views=R:SegmentedSelector({id="v3_notes_popup_views",parent=root,itemWidth=92,gap=3,height=26,
        items={{value="friends",text="好友"},{value="block",text="黑名单"},{value="family",text="家族"},{value="expedition",text="远征队"}},
        get=function()return F:GetProjection().view end,set=function(v)return F.Commands:SetView(v)end,slot={size="fixed",height=30,hAlign="fill"}})
    local tools=R:HorizontalBox({id="v3_notes_popup_other_views",parent=root,gap=5,slot={size="fixed",height=30,hAlign="fill"}})
    local otherViews=tools and R:SegmentedSelector({id="v3_notes_popup_saved_team",parent=tools,itemWidth=92,gap=3,height=26,
        items={{value="team",text="团队"},{value="saved",text="已保存"}},get=function()return F:GetProjection().view end,
        set=function(v)return F.Commands:SetView(v)end,slot={size="fixed",width=190,height=30}})
    local teamScope=tools and R:Dropdown({id="v3_notes_popup_team_scope",parent=tools,
        items={{value=0,text="全部团队"},{value=1,text="团队1"},{value=2,text="团队2"}},
        get=function()return F:GetProjection().teamScope end,set=function(v)return F.Commands:SetTeamScope(v)end,
        slot={size="fill",fill=1,minWidth=110}})
    instance.name=R:TextInput({id="v3_notes_popup_name",parent=root,maxLength=96,commitMode="explicit",placeholder="选择名单或输入完整角色名",slot={size="fixed",height=30,hAlign="fill"}})
    instance.note=R:TextInput({id="v3_notes_popup_note",parent=root,maxLength=384,allowEmpty=true,commitMode="explicit",placeholder="输入备注；清空后保存可删除",slot={size="fixed",height=30,hAlign="fill"}})
    local actions=R:HorizontalBox({id="v3_notes_popup_actions",parent=root,gap=5,slot={size="fixed",height=30,hAlign="fill"}})
    if not views or not otherViews or not teamScope or not instance.name or not instance.note or not actions then return nil,"备注窗口编辑控件构建失败"end
    local save=R:Button({id="v3_notes_popup_save",parent=actions,text="保存",compact=true,slot={size="fixed",width=64}})
    local remove=R:Button({id="v3_notes_popup_delete",parent=actions,text="删除",compact=true,slot={size="fixed",width=64}})
    local target=R:Button({id="v3_notes_popup_target",parent=actions,text="载入目标",compact=true,slot={size="fixed",width=88}})
    local refresh=R:Button({id="v3_notes_popup_refresh",parent=actions,text="刷新名单",compact=true,slot={size="fixed",width=88}})
    instance.feedback=R:Text({id="v3_notes_popup_feedback",parent=root,text="点击名字编辑备注；用关闭按钮收起。远征队名单随原生成员页翻页更新。",overflow="wrap",fontSize=9,maxLines=2,slot={size="fixed",height=30,hAlign="fill"}})
    -- 中文维护：覆盖提示独立于操作反馈，不把远征当前页误写成全公会，也不冲掉保存/删除结果。
    local coverage=R:Text({id="v3_notes_popup_coverage",parent=root,text="",overflow="wrap",fontSize=9,maxLines=2,slot={size="fixed",height=30,hAlign="fill"}})
    instance.table=R:TableView({id="v3_notes_popup_table",parent=root,items={},rowHeight=28,headerHeight=26,scrollbar=true,selectable=true,selectionMode="single",
        getKey=function(row)return row.key end,columns={{id="name",title="角色名",field="name",size="fill",fill=1,minWidth=116},{id="note",title="备注",field="note",size="fill",fill=1.6,minWidth=145},
            {id="state",title="状态",field="statusText",size="fixed",width=52}},
        slot={size="fill",fill=1,hAlign="fill",vAlign="fill"}})
    if not save or not remove or not target or not refresh or not instance.feedback or not coverage or not instance.table then return nil,"备注窗口名单控件构建失败"end
    local function Report(ok,why,success)instance.feedback:SetText(ok and success or ("失败："..tostring(why or "未执行")));return ok,why end
    local function SelectName(name)
        instance.deleteArm=nil;instance.name:SetValue(name,false,"notes_select");instance.note:SetValue(F:GetNote(name),false,"notes_select")
    end
    instance.table.onSelectionChanged=function(index)local row=instance.table:GetItem(index);if row then SelectName(row.name)end end
    save.onClick=function()instance.deleteArm=nil;local ok,why=F.Commands:SaveNote(instance.name:GetDraftValue(),instance.note:GetDraftValue());return Report(ok,why,"备注已提交保存")end
    remove.onClick=function()
        local name=instance.name:GetDraftValue();if name==""then return Report(false,"先选择角色名")end
        if instance.deleteArm~=name then instance.deleteArm=name;instance.feedback:SetText("再次点击删除以确认："..name);return true end
        instance.deleteArm=nil;local ok,why=F.Commands:DeleteNote(name);if ok then instance.note:SetValue("",false,"notes_deleted")end;return Report(ok,why,"备注已删除")
    end
    target.onClick=function()local ok,name=F.Commands:GetTargetName();if ok then SelectName(name)end;return Report(ok,name,"已载入当前目标")end
    refresh.onClick=function()return F.Commands:Refresh("notes_popup_manual")end
    function instance:Refresh()
        local p=F:GetProjection();self.table:SetItems(p.rows,p.revision);views:Render();otherViews:Render()
        -- 中文维护：Hidden保留筛选框布局预算与锚点；不能Collapsed后在点击栈先显示尚在0,0的Native按钮。
        -- 否则切团队时会盖住团队/已保存页签，等异步Shell重排才能恢复。此处沿用RSUI统一Visibility边界。
        teamScope:SetVisibility(p.view=="team"and R.Visibility.Visible or R.Visibility.Hidden);teamScope:Render()
        coverage:SetText(p.error or (p.view=="team"and "团号与队伍分组来自当前团队名单。"or "名单与已保存备注按完整角色名对应。"))
        self.table:SetViewState(#p.rows>0 and "ready"or (p.status=="unavailable"and "error"or "empty"),{title=p.status=="unavailable"and "名单暂不可读"or "暂无名单",detail=p.error or "可以手动输入角色名，或切换已保存备注。"})
        self.surface:SetStatus(tostring(p.viewLabel or "名单").." · "..tostring(#p.rows).."人",p.error and "orange"or "muted")
        return true
    end
    function instance:ApplyAnchor(snapshot)
        if self.state.userMoved~=true then self.state.x,self.state.y=Position(snapshot or C.snapshot)end
        return self.surface:ApplyLayout(false)
    end
    function instance:Cleanup()
        S.Events:UnsubscribeInternalOwner(self)
        if self.acquired and F:HasConsumer(TOKEN)then local ok,why=F:ReleaseConsumer(TOKEN);if not ok then return false,why end end
        self.acquired,self.visible=false,false;self.deleteArm=nil;return true
    end
    local function Show(self)
        if F.enabled~=true or C.dismissed or not C.openRequested then return false,"没有新好友名单或备注功能已关闭"end
        local session=C.session
        local function Current()return F.enabled==true and C.openRequested and not C.dismissed and C.session==session and F:HasConsumer(TOKEN)end
        if not self.visible then
            local ok,why=F:AcquireConsumer(TOKEN);if not ok then return false,why end;self.acquired=true
            if not Current()then self:Cleanup();return false,"备注窗口状态已变化"end
            local subscribed,subscribeErr=S.Events:SubscribeInternal(F.UpdateTopic,self,function()if instance.visible then instance:Refresh()end end)
            if not subscribed then self:Cleanup();return false,subscribeErr or "备注更新订阅失败"end
            self.visible=true
            local chosen,chooseErr=F.Commands:SetView(C.snapshot.listKind or "friends")
            if not chosen then self:Cleanup();return false,chooseErr end
        end
        if not Current()then self:Cleanup();return false,"备注窗口状态已变化"end
        self:Refresh();local anchored,anchorErr=self:ApplyAnchor(C.snapshot)
        if not anchored then self:Cleanup();return false,anchorErr end
        if not Current()then self:Cleanup();return false,"备注窗口状态已变化"end
        local ok,why=self.surface:Show(true);if not ok then self:Cleanup();return false,why end
        return true
    end
    function instance:Show()
        -- 中文维护：Native布局/控件异常同样回收刚取得的租约，Host记录失败时不能留下不可见的观察者。
        if self.opening then return false,"备注窗口正在显示"end
        self.opening=true
        local ok,result,why=xpcall(function()return Show(self)end,S.SafeTraceback)
        self.opening=false
        if not ok then self:Cleanup();return false,result end
        return result,why
    end
    function instance:Hide()
        -- 中文维护：Native拒绝/抛错仍要回收观察与订阅；保留显隐失败供Host诊断，不把失败窗口当成活跃消费者。
        local called,hidden,why=pcall(self.surface.Show,self.surface,false)
        local cleaned,cleanupErr=self:Cleanup()
        if not called then return false,hidden end
        if hidden~=true then return false,why or "备注窗口隐藏失败"end
        return cleaned,cleanupErr
    end
    function instance:OnWindowClosed()return self:Cleanup()end
    function instance:ApplyLayout(fromMetricsChange)
        if not self.visible then return true end
        return self:ApplyAnchor(C.snapshot)
    end
    instance.content=root
    return instance
end
local registered,why=Host:Register(ID,{featureId=F.Id,create=Create,ensurePreferences=function()return F:Initialize()end})
if not registered then error(why)end
local bound,bindErr=Host:BindFeatureLifecycle(ID,{featureId=F.Id,enabled=function()return F.enabled==true end,
    preference=function()return C.openRequested and not C.dismissed end})
if not bound then error(bindErr)end
function C:OnSurface(snapshot)
    local requested=snapshot.status=="ready"and snapshot.popupRequested==true
    local newList=requested and (snapshot.listRevision or snapshot.friendListRevision)~=self.lastListRevision
    if requested~=self.openRequested or newList then self.session=self.session+1 end
    if newList then self.lastListRevision=snapshot.listRevision or snapshot.friendListRevision;self.lastFriendListRevision=snapshot.friendListRevision;self.dismissed=false end
    self.snapshot=snapshot;self.openRequested=requested
    if not requested then
        if Host:IsVisible(ID)then return Host:SetVisible(ID,false,{persist=false,source="notes_observer_stop"})end
        return true
    end
    if F.enabled~=true or self.dismissed then return true end
    local instance=Host:GetInstance(ID)
    -- Native隐藏拒绝时Host保留可见事实，但实例已经回收需求；下一次打开必须重走Show。
    if not Host:IsVisible(ID)or not instance or not instance.visible or not instance.acquired then
        return Host:SetVisible(ID,true,{persist=false,source="notes_friend_list_received"})
    end
    if newList then
        -- 中文维护：有效回包切换对应名单，与expnote行为一致；只改变读视图，不触碰名字/备注输入草稿。
        local refreshed,why
        if F:GetProjection().view~=(snapshot.listKind or "friends")then refreshed,why=F.Commands:SetView(snapshot.listKind or "friends")
        else refreshed,why=F.Commands:Refresh("notes_social_list")end
        if refreshed~=true then return false,why end
        -- 中文维护：新回包复用Host Show前置窗口，不重建、不覆盖编辑草稿，也不重复Acquire。
        return Host:SetVisible(ID,true,{persist=false,source="notes_friend_list_received"})
    end
    return true
end
S.Events:SubscribeInternal(Observer.topic,C,function(_,snapshot)return C:OnSurface(snapshot)end)
C:OnSurface(Observer:GetSnapshot())
