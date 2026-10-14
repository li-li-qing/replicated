------------------------------------------------------------------------
-- Replicated Suite · 人员备注侧栏
-- 作者：Replicated
-- QQ群：1104129461
--
-- 恢复原生打开名单时有效回包带出备注窗；上线等变化只更新名单，不得解除手动关闭。
-- 整个社交窗口可读时跟随显示/关闭，Getter全nil时保留回包兼容路径；本窗口 Escape 隐藏仍走 OnHide 回收需求。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
local R,Host=S.RSUI,S.UIV3 and S.UIV3.WidgetHost
local F=S.Features and S.Features.PlayerNotes
local Observer=S.Services and S.Services.PlayerNotesSurfaceV3
if not R or not Host or not F or not Observer or not R.FloatingSurface then return end
local ID,TOKEN="tools.player_notes_sidecar","widget:player_notes"
local WIDTH,HEIGHT=420,460
local C={openRequested=false,manualRequested=false,dismissed=false,snapshot={},session=0,lastOpenRevision=0}
S.UIV3.PlayerNotesSidecar=C
if S.ModuleDiagnosticsHub and type(S.ModuleDiagnosticsHub.RegisterProvider)=="function"then
    S.ModuleDiagnosticsHub:RegisterProvider("tools_player_notes","social_surface",function()
        local d=Observer:GetDiagnostics();d.dismissed=C.dismissed;d.openRequested=C.openRequested;d.manualRequested=C.manualRequested;d.session=C.session
        -- 只记录本备注窗实际收到的关闭通知，不能把原生 Escape 策略声明为已观察社交 X 关闭。
        d.nativeHideCount=C.nativeHideCount or 0;d.lastCloseReason=C.lastCloseReason
        local instance=Host:GetInstance(ID)
        d.nativeEscapeEnabled=instance~=nil and instance.shell~=nil and instance.shell.spec~=nil and instance.shell.spec.closeOnEscape==true
        if instance then d.popupVisible=instance.visible==true;d.consumerAcquired=instance.acquired==true end
        return d
    end,70,{detailOnly=true})
end
local function Position(snapshot)
    local ctx=S.Layout and S.Layout:GetContext()or {}
    local left,top=tonumber(ctx.safeLeft)or 0,tonumber(ctx.safeTop)or 0
    local right,bottom=(tonumber(ctx.logicalWidth)or 1024)-(tonumber(ctx.safeRight)or 0),(tonumber(ctx.logicalHeight)or 768)-(tonumber(ctx.safeBottom)or 0)
    -- 没有原生社交几何，不虚构贴边位置；首次居中，用户拖动后保持自身窗口位置。
    return math.floor(math.max(left,(left+right-WIDTH)/2)),math.floor(math.max(top,(top+bottom-HEIGHT)/2))
end
local function Create()
    local instance={visible=false,acquired=false,state={width=WIDTH,height=HEIGHT,locked=false,userMoved=false,coordinateSpace="logical-free-v2"}}
    instance.state.x,instance.state.y=Position(C.snapshot)
    local surface,why=R.FloatingSurface:Create({id="v3_player_notes_sidecar",owner="v3:widget:player_notes",title="人员备注",status="打开名单时显示",
        -- 420×460是可读最小尺寸而非固定尺寸；拖动/边缘缩放仍由共享Windowing事务负责，刷新不能重置用户几何。
        width=WIDTH,height=HEIGHT,minWidth=WIDTH,maxWidth=1000,minHeight=HEIGHT,maxHeight=1000,
        -- 对齐用户提供的 expnote/main.lua:119 原生 Escape 关闭策略；关闭后仍走 Host 清理而非只隐藏画面。
        resizable=true,movable=true,closeButton=true,appearanceControls=false,closeOnEscape=true,
        statePolicy={defaultWidth=WIDTH,defaultHeight=HEIGHT,minWidth=WIDTH,maxWidth=1000,minHeight=HEIGHT,maxHeight=1000,defaultLocked=false},
        getState=function()return instance.state end,
        setState=function(value)instance.state=value;return true end,
        persist=function()return true end,
        onClosed=function(_,reason)
            C.dismissed=true;C.manualRequested=false;C.session=C.session+1;C.lastCloseReason=tostring(reason or "close")
            if reason=="native_hide"then C.nativeHideCount=(C.nativeHideCount or 0)+1 end
            return Host:NotifyWindowClosed(ID,{persist=false,source="notes_user_close"})
        end})
    if not surface then return nil,why end
    instance.surface,instance.shell,instance.windowController=surface,surface.shell,surface.windowController
    -- 名单是浮窗主体；局部采用3px间距和24px编辑行，避免共享控件默认尺寸挤走名单，不改变Shell缩放及草稿所有权。
    local root=R:VerticalBox({id="v3_notes_popup_content",parent=surface:GetContentRoot(),gap=3,slot={size="fill",fill=1,hAlign="fill",vAlign="fill"}})
    if not root then return nil,"备注窗口内容构建失败"end
    -- 六类名单共用一排选中态，总宽326px可放进420px最小窗；团号筛选迁入操作排，保留Hidden槽防止刷新期间跳位或遮挡页签。
    local views=R:SegmentedSelector({id="v3_notes_popup_views",parent=root,itemWidth=48,gap=2,height=24,fontSize=10,
        items={{value="friends",text="好友"},{value="block",text="黑名单",width=58},{value="family",text="家族"},{value="expedition",text="远征队",width=58},{value="team",text="团队"},{value="saved",text="已保存",width=56}},
        get=function()return F:GetProjection().view end,set=function(v)return F.Commands:SetView(v)end,slot={size="fixed",height=24,hAlign="fill"}})
    instance.name=R:TextInput({id="v3_notes_popup_name",parent=root,height=24,maxLength=96,commitMode="explicit",placeholder="选择名单或输入完整角色名",slot={size="fixed",height=24,hAlign="fill"}})
    instance.note=R:TextInput({id="v3_notes_popup_note",parent=root,height=24,maxLength=384,allowEmpty=true,commitMode="explicit",placeholder="输入备注；清空后保存可删除",slot={size="fixed",height=24,hAlign="fill"}})
    local actions=R:HorizontalBox({id="v3_notes_popup_actions",parent=root,gap=3,slot={size="fixed",height=24,hAlign="fill"}})
    if not views or not instance.name or not instance.note or not actions then return nil,"备注窗口编辑控件构建失败"end
    -- 按钮按2字/4字文本给宽度，显式小字号与高度；不压缩名字或备注的整行输入，也不改变Commands及删除确认。
    local save=R:Button({id="v3_notes_popup_save",parent=actions,text="保存",compact=true,height=24,fontSize=10,slot={size="fixed",width=44}})
    local remove=R:Button({id="v3_notes_popup_delete",parent=actions,text="删除",compact=true,height=24,fontSize=10,slot={size="fixed",width=44}})
    local target=R:Button({id="v3_notes_popup_target",parent=actions,text="载入目标",compact=true,height=24,fontSize=10,slot={size="fixed",width=68}})
    local refresh=R:Button({id="v3_notes_popup_refresh",parent=actions,text="刷新名单",compact=true,height=24,fontSize=10,slot={size="fixed",width=68}})
    local teamScope=R:Dropdown({id="v3_notes_popup_team_scope",parent=actions,height=24,
        items={{value=0,text="全部团队"},{value=1,text="团队1"},{value=2,text="团队2"}},
        get=function()return F:GetProjection().teamScope end,set=function(v)return F.Commands:SetTeamScope(v)end,
        slot={size="fixed",width=112}})
    -- 普通提示按实际文字测高，长失败原因仍可换两行；名单覆盖说明独立保存，不能用后台刷新冲掉保存/删除反馈。
    instance.feedback=R:Text({id="v3_notes_popup_feedback",parent=root,text="点击名字编辑；关闭按钮收起窗口。",overflow="wrap",fontSize=9,maxLines=2,slot={size="auto",minHeight=14,hAlign="fill"}})
    local coverage=R:Text({id="v3_notes_popup_coverage",parent=root,text="",overflow="wrap",fontSize=9,maxLines=2,slot={size="auto",minHeight=14,hAlign="fill"}})
    -- 表头22px、名单行24px仍保留单选与虚拟滚动；释放的纵向预算全部由fill名单承接，不扩大浮窗本身。
    instance.table=R:TableView({id="v3_notes_popup_table",parent=root,items={},rowHeight=24,headerHeight=22,scrollbar=true,selectable=true,selectionMode="single",
        getKey=function(row)return row.key end,onSortChanged=function(_,direction)return F.Commands:SetNameSort(direction)end,
        columns={{id="index",title="#",field="listIndex",sortable=false,size="fixed",width=26},
            {id="name",title="角色名",field="name",size="fill",fill=1,minWidth=116},{id="note",title="备注",field="note",sortable=false,size="fill",fill=1.6,minWidth=145},
            {id="state",title="状态/队伍",field="statusText",sortable=false,size="fixed",width=76}},
        slot={size="fill",fill=1,hAlign="fill",vAlign="fill"}})
    if not save or not remove or not target or not refresh or not teamScope or not instance.feedback or not coverage or not instance.table then return nil,"备注窗口名单控件构建失败"end
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
        -- 合并后的六页签只刷新同一Selector，不隐藏操作排，保证按下中的Native按钮保持有效。
        local p=F:GetProjection();self.table:SetItems(p.rows,p.revision)
        -- 两处备注表头绑定同一Feature排序，升序/降序/原顺序三态；渲染同步不再次提交命令或覆盖编辑草稿。
        self.table:SetSortState(p.nameSort~="none"and "name"or nil,p.nameSort,false);views:Render()
        -- Hidden保留筛选框布局预算与锚点；不能Collapsed后在点击栈先显示尚在0,0的Native按钮。
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
        if F.enabled~=true or C.dismissed or not (C.openRequested or C.manualRequested)then return false,"没有新的名单响应，或备注功能已关闭"end
        local session=C.session
        local function Current()return F.enabled==true and (C.openRequested or C.manualRequested)and not C.dismissed and C.session==session and F:HasConsumer(TOKEN)end
        if not self.visible then
            local ok,why=F:AcquireConsumer(TOKEN);if not ok then return false,why end;self.acquired=true
            if not Current()then self:Cleanup();return false,"备注窗口状态已变化"end
            local subscribed,subscribeErr=S.Events:SubscribeInternal(F.UpdateTopic,self,function()if instance.visible then instance:Refresh()end end)
            if not subscribed then self:Cleanup();return false,subscribeErr or "备注更新订阅失败"end
            self.visible=true
            -- 自动打开采用响应来源的名单；手动打开保留页面选择，后台家族上线事件不能切换当前视图。
            local chosen,chooseErr=F.Commands:SetView((C.manualRequested or C.snapshot.openSignal=="native_community_visible")and F:GetProjection().view or C.snapshot.openView or "friends")
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
        -- Native布局/控件异常同样回收刚取得的租约，Host记录失败时不能留下不可见的观察者。
        if self.opening then return false,"备注窗口正在显示"end
        self.opening=true
        local ok,result,why=xpcall(function()return Show(self)end,S.SafeTraceback)
        self.opening=false
        if not ok then self:Cleanup();return false,result end
        return result,why
    end
    function instance:Hide()
        -- Native拒绝/抛错仍要回收观察与订阅；保留显隐失败供Host诊断，不把失败窗口当成活跃消费者。
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
    preference=function()return (C.openRequested or C.manualRequested)and not C.dismissed end})
if not bound then error(bindErr)end
-- 明确点击是独立、可撤销的窗口打开意图；不调用Native社交Trigger、不写Store、不增加第二套备注数据。
function C:Open()
    if F.enabled~=true then return false,"请先启用人员备注功能"end
    self.manualRequested,self.dismissed=true,false;self.session=self.session+1
    local ok,why=Host:SetVisible(ID,true,{persist=false,source="notes_manual_open"})
    if ok~=true then self.manualRequested=false end
    return ok,why
end
function C:OnSurface(snapshot)
    if snapshot.source=="native_community_visibility"and snapshot.nativeVisibilityKnown==true and snapshot.nativeVisible~=true
        and snapshot.nativeCloseRevision~=self.lastNativeCloseRevision then
        self.lastNativeCloseRevision=snapshot.nativeCloseRevision
        self.snapshot=snapshot;self.openRequested,self.manualRequested=false,false
        if Host:IsVisible(ID)then return Host:SetVisible(ID,false,{persist=false,source="notes_native_community_closed"})end
        return true
    end
    -- 有效名单响应是用户已实测的启窗入口；上线/成员变化不带新的openRevision，不能冒充该入口。
    local requested=snapshot.status=="ready"and snapshot.popupRequested==true
        and (snapshot.openSignal=="native_list_response"or snapshot.openSignal=="native_team_request"or snapshot.openSignal=="native_community_visible")
    -- 整个社交打开边沿、有效名单回包或团队用户请求可重新打开；背景名单revision不解除dismissed。
    local newOpen=requested and snapshot.openRevision~=self.lastOpenRevision
    if requested~=self.openRequested or newOpen then self.session=self.session+1 end
    if newOpen then self.lastOpenRevision=snapshot.openRevision;self.dismissed=false end
    self.snapshot=snapshot;self.openRequested=requested
    if newOpen and snapshot.openSignal=="native_team_request"and F.enabled==true and not self.manualRequested then
        local chosen,why=F.Commands:SelectLargestTeam();if chosen~=true then return false,why end
    end
    if snapshot.status=="idle"or F.enabled~=true then self.manualRequested=false end
    if not requested and not self.manualRequested then
        if Host:IsVisible(ID)then return Host:SetVisible(ID,false,{persist=false,source="notes_observer_stop"})end
        return true
    end
    if F.enabled~=true or self.dismissed then return true end
    local instance=Host:GetInstance(ID)
    -- Native隐藏拒绝时Host保留可见事实，但实例已经回收需求；下一次打开必须重走Show。
    if not Host:IsVisible(ID)or not instance or not instance.visible or not instance.acquired then
        -- 显示失败后的背景通知不能重试启窗；仅新的有效响应或明确手动意图可触发Show。
        if newOpen or self.manualRequested then return Host:SetVisible(ID,true,{persist=false,source="notes_social_window_open"})end
        return true
    end
    -- 新的原生名单响应可同步名单页，但不Show前置窗口；后台上线通知既不切页也不覆盖名字/备注草稿。
    if newOpen and snapshot.openSignal~="native_community_visible"and not self.manualRequested and F:GetProjection().view~=(snapshot.openView or "friends")then
        return F.Commands:SetView(snapshot.openView or "friends")
    end
    -- Feature自己的名单订阅刷新当前视图；此处不SetVisible(true)，防止上线/分页更新将备注窗抢到前景。
    return true
end
S.Events:SubscribeInternal(Observer.topic,C,function(_,snapshot)return C:OnSurface(snapshot)end)
-- 本人 /bzlist 是明确打开意图；与手动入口共用 Host，不借聊天/成员变动扩大自动弹窗范围。
S.Events:SubscribeInternal("v3.player_notes.user_intent",C,function(_,intent)
    if F.enabled~=true then return false end
    local chosen,why=F.Commands:SetView(intent.view);if chosen~=true then return false,why end
    return C:Open()
end)
S.Events:SubscribeInternal("v3.player_notes.command_feedback",C,function(_,feedback)
    local instance=Host:GetInstance(ID)
    if instance and instance.visible then instance.feedback:SetText(feedback.text)end
    local toast=S.UIV3.ToastHost
    if toast and type(toast.Notify)=="function"then toast:Notify({id="player_notes_command",title="人员备注",detail=feedback.text,tone=feedback.ok and "green"or "red",durationMs=3500})end
end)
C:OnSurface(Observer:GetSnapshot())
