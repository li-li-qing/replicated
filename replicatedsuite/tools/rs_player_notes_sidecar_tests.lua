------------------------------------------------------------------------
-- Replicated Suite · 人员备注伴随浮窗测试
-- 作者：Replicated
-- QQ群：1104129461
--
-- 真实EventBus/Feature/Store/WidgetHost/RSUI；仅Native绘制与游戏好友名单响应为边界模型。
------------------------------------------------------------------------
local Base=dofile('tools/rs_gear_page_test_host.lua')
local passed=0
local function Boot(options)
    options=options or {};local h=Base({disk=options.disk});assert(h.page:OnDeactivated());local S=h.S
    dofile('core/rs_demand.lua')
    h.friendReads=0;h.friendRequests=0;h.eventReject=options.eventReject
    S.Events.host={RegisterEvent=function(_,name)h.registeredEvent=name;return not h.eventReject end,UnregisterEvent=function()return true end}
    S.Events.running=true
    -- 全局 UI 事件与窗口 RegisterEvent 是独立传输，参考插件团队开关使用前者；只模拟 Native 注册/释放。
    UIParent=nil;h.globalHandlers={};h.globalRegistrations=0;h.globalReleases=0
    if options.globalEvents then
        UIParent={SetEventHandler=function(_,name,fn)h.globalRegistrations=h.globalRegistrations+1;h.globalHandlers[name]=h.globalHandlers[name]or {};table.insert(h.globalHandlers[name],fn);return true end,
            ReleaseEventHandler=function(_,name,fn)h.globalReleases=h.globalReleases+1;local list={};for _,v in ipairs(h.globalHandlers[name]or {})do if v~=fn then list[#list+1]=v end end;h.globalHandlers[name]=list;return true end}
    end
    UIC_COMMUNITY,UIC_FRIEND,UIC_FAMILY,UIC_EXPEDITION=901,902,903,904
    ADDON.GetContent=function()return nil end;ADDON.GetContentMainScriptPosVis=function()return nil end
    if options.nativeSurface then
        h.surfaceReads=0;h.contentReads=0
        ADDON.GetContentMainScriptPosVis=function(_,id)assert(id==UIC_COMMUNITY);h.surfaceReads=h.surfaceReads+1;return nil,nil,nil,nil,h.socialVisible end
        ADDON.GetContent=function(_,id)assert(id==UIC_COMMUNITY);h.contentReads=h.contentReads+1;return h.socialContent end
        dofile('services/rs_auction_surface_v3.lua')
    end
    X2Friend={GetFriendList=function()h.friendReads=h.friendReads+1;return h.nativeFriendList end,
        RequestFriendList=function()h.friendRequests=h.friendRequests+1;error('observer must not request friends')end}
    h.identityReads=0;X2Unit.UnitName=function(_,token)if token=='player'then h.identityReads=h.identityReads+1;return '本人@甲'end;return '目标@甲'end
    if options.roster then S.Services.TeamRosterV3={AcquireConsumer=function()return true end,ReleaseConsumer=function()return true end,GetSnapshot=function()return {members=options.roster}end}end
    S.Layout={GetContext=function()return {logicalWidth=1920,logicalHeight=1080,usableWidth=1920,usableHeight=1080,safeLeft=0,safeTop=0,safeRight=0,safeBottom=0}end}
    S.Layout.ResolvePlacement=function(_,state,w,ht,x,y)return state and state.x or x,state and state.y or y,w,ht,{}end
    S.UI.CreateWindowShell=function(_,spec)
        local n=h.Native(nil,spec.id..'_native',0,0,spec.width,spec.height)
        local body=S.RSUI:VerticalBox({id=spec.id..'_body_model',parent=n,gap=0})
        local shell={root=n,minimizeButton={SetText=function()return true end},windowController={IsInteracting=function()return false end},spec=spec,locked=false}
        shell.closeOnEscape=spec.closeOnEscape==true
        function shell:GetContentComponent()return body end;function shell:GetContentRoot()return body end
        function shell:GetNativeContentRoot()return body.root end;function shell:GetWindow()return n end
        function shell:ApplyPlacementRect(x,y,w,ht)n.x,n.y=x,y;n:SetExtent(w,ht);body:Layout(6,24,w-12,ht-46);return true end
        function shell:Show(v)self.shows=(self.shows or 0)+1;n:Show(v);return true end;function shell:IsLocked()return self.locked end
        function shell:SetLocked(v)self.locked=v;return true end;function shell:SetStatus(text)self.status=text;return true end
        function shell:GetPlacementDiagnostics()return {}end
        for _,key in ipairs({'SetOverallOpacity','SetBackgroundOpacity','SetTextOpacity','SetFontScale','SetMinimized'})do shell[key]=function()return true end end
        function shell:Close(reason)self:Show(false);return spec.onClosed(self,reason)end
        -- 这里只替代原生 Escape/OnHide 边界；真实 Shell 的单次通知和重复显隐由独立 Shell 回归覆盖。
        function shell:NativeEscapeClose()
            assert(self.closeOnEscape,'notes did not opt into the native Escape policy')
            self:Show(false);return spec.onClosed(self,'native_hide')
        end
        return shell
    end
    dofile('ui/framework/rs_ui_floating_surface.lua');dofile('presentation/v3/widgets/rs_v3_widget_host.lua')
    dofile('presentation/v3/rs_v3_aux_window_store.lua')
    dofile('services/rs_player_notes_surface_v3.lua');dofile('features/shared/rs_feature_slice_factory.lua')
    dofile('features/tools/social/rs_player_notes_feature.lua')
    if options.diagnostics then dofile('features/rs_feature_registry.lua');dofile('core/rs_module_diagnostics.lua')end
    dofile('presentation/v3/widgets/rs_v3_player_notes_sidecar.lua')
    -- 常规窗口回归关闭临时调用审计，独立用例验证原始 Native 调用参数与审计预算。
    S.Services.PlayerNotesSurfaceV3.nativeCallAuditEnabled=options.nativeCallAudit==true
    local F=S.Features.PlayerNotes;assert(F:Initialize());assert(F:Enable())
    local V,W=S.Services.PlayerNotesSurfaceV3,S.UIV3.WidgetHost
    function h:Receive(list)S.Events:Dispatch('FRIENDLIST_INFO',true,list or {{'好友@甲'},{name='好友@乙'}});return W:GetInstance('tools.player_notes_sidecar')end
    function h:Close()return assert(W:GetInstance('tools.player_notes_sidecar')).surface:Close('test_user_close')end
    function h:Global(name,...)local list={};for _,fn in ipairs(self.globalHandlers[name]or {})do list[#list+1]=fn end;for _,fn in ipairs(list)do fn(...)end end
    return h,S,F,V,W
end
local function Test(name,fn)fn();passed=passed+1;print('PASS notes-friend-event '..name)end
Test('whole native community visibility opens without a list event and closes by either native route',function()
    local h,S,F,V,W=Boot({nativeSurface=true});local task=assert(S.Scheduler.tasks[V.taskId],'community visibility observation missing')
    assert(task.intervalMs==250 and task.owner==V and S.Scheduler.taskModules[V.taskId]=='tools_player_notes')
    h.socialVisible=true;assert(V:RefreshNativeVisibility());assert(W:IsVisible('tools.player_notes_sidecar'))
    local instance=W:GetInstance('tools.player_notes_sidecar');assert(F.Commands:SetView('family'))
    assert(instance.note:BeginEditing('test'));instance.note.root.text='关闭社交保留草稿'
    local revision=V.openRevision;assert(V:RefreshNativeVisibility());assert(V.openRevision==revision)
    h.socialVisible=false;assert(V:RefreshNativeVisibility());assert(not W:IsVisible('tools.player_notes_sidecar')and F.consumerCount==0)
    h:Receive();assert(not W:IsVisible('tools.player_notes_sidecar'),'list response reopened while native community is hidden')
    h.socialVisible=true;assert(V:RefreshNativeVisibility());assert(W:IsVisible('tools.player_notes_sidecar'))
    assert(F:GetProjection().view=='family'and instance.note.root.text=='关闭社交保留草稿','whole-window reopen changed view or draft')
    assert(h:Close());assert(V:RefreshNativeVisibility());h:Receive();assert(not W:IsVisible('tools.player_notes_sidecar'),'unchanged visible native window undid explicit dismissal')
    h.socialVisible=false;assert(V:RefreshNativeVisibility());h.socialVisible=true;assert(V:RefreshNativeVisibility());assert(W:IsVisible('tools.player_notes_sidecar'))
    h.socialVisible=false;assert(V:RefreshNativeVisibility());assert(not W:IsVisible('tools.player_notes_sidecar'))
    assert(h.contentReads==1,'explicit boolean visibility performed unnecessary content reads')
    assert(S.UIV3.PlayerNotesSidecar:Open());h:Receive();assert(W:IsVisible('tools.player_notes_sidecar'),'repeated closed fact cancelled explicit manual opening')
    local d=V:GetDiagnostics();local reads=h.surfaceReads;assert(d.nativeVisibilityKnown and not d.nativeVisible and d.polling)
    V:GetDiagnostics();assert(h.surfaceReads==reads,'diagnostic export resampled the game')
    local callback=S.Scheduler.tasks[V.taskId].callback;assert(F:Disable());assert(S.Scheduler.tasks[V.taskId]==nil)
    h.socialVisible=true;callback();assert(not W:IsVisible('tools.player_notes_sidecar'),'late observer revived disabled notes')
end)
Test('temporary unknown visibility cannot reset dismissal or create a second open edge',function()
    local h,S,F,V,W=Boot({nativeSurface=true});h.socialVisible=true;assert(V:RefreshNativeVisibility());assert(h:Close())
    local revision=V.openRevision;h.socialVisible=nil;assert(V:RefreshNativeVisibility())
    h.socialVisible=true;assert(V:RefreshNativeVisibility());assert(V.openRevision==revision and not W:IsVisible('tools.player_notes_sidecar'))
end)
Test('all-nil community is unknown; auction absence rule must not suppress working friend response',function()
    local h,S,F,V,W=Boot({nativeSurface=true});local d=V:GetDiagnostics()
    assert(d.nativeVisibilityKnown==false and d.visibilityProbe.mainReturnTypes=='nil,nil,nil,nil,nil')
    h:Receive();assert(W:IsVisible('tools.player_notes_sidecar'));assert(V:RefreshNativeVisibility());assert(W:IsVisible('tools.player_notes_sidecar'))
    h.socialContent={IsVisible=function()return true end,GetParent=function()return UIParent end}
    assert(V:RefreshNativeVisibility());assert(V:GetDiagnostics().nativeVisibilityKnown)
    h.socialContent.IsVisible=function()return false end;assert(V:RefreshNativeVisibility());assert(not W:IsVisible('tools.player_notes_sidecar'))
    h.socialContent=nil;assert(V:RefreshNativeVisibility());assert(V:GetDiagnostics().nativeVisibilityKnown==false)
    h:Receive();assert(W:IsVisible('tools.player_notes_sidecar'),'unknown observation blocked existing fallback')
end)
Test('friend response opens popup despite all native surface getters returning nil',function()
    local h,S,F,V,W=Boot();assert(not W:IsVisible('tools.player_notes_sidecar'))
    local instance=assert(h:Receive());assert(W:IsVisible('tools.player_notes_sidecar')and instance.visible and F.consumerCount==1)
    assert(instance.table:GetItem(1).name=='好友@乙'and instance.table:GetItem(2).name=='好友@甲')
    assert(h.friendRequests==0 and h.friendReads==0,'event path performed extra native friend query')
    assert(h.registeredEvent=='FRIENDLIST_INFO'and S.Scheduler.tasks[V.taskId]==nil,'observer still polls native windows')
end)
Test('manual close stays closed until another friend response and reuses one popup',function()
    local h,S,F,V,W=Boot();local instance=h:Receive();assert(h:Close())
    assert(not W:IsVisible('tools.player_notes_sidecar')and F.consumerCount==0)
    assert(V:Refresh());assert(not W:IsVisible('tools.player_notes_sidecar'),'unchanged snapshot revived dismissed popup')
    assert(h:Receive()==instance and W:IsVisible('tools.player_notes_sidecar')and F.consumerCount==1 and W.stats.creates==1)
end)
Test('native Escape closes notes and releases its consumer until a fresh social response',function()
    local h,S,F,V,W=Boot();local instance=h:Receive();assert(instance.shell.closeOnEscape)
    assert(instance.note:BeginEditing('test'));instance.note.root.text='未保存备注'
    assert(instance.shell:NativeEscapeClose())
    assert(not W:IsVisible('tools.player_notes_sidecar')and not instance.visible and F.consumerCount==0)
    local C=S.UIV3.PlayerNotesSidecar;assert(C.dismissed and C.nativeHideCount==1 and C.lastCloseReason=='native_hide')
    assert(V:Refresh());assert(not W:IsVisible('tools.player_notes_sidecar'),'unchanged response reopened Escape-dismissed notes')
    assert(h:Receive()==instance and instance.visible and F.consumerCount==1)
    assert(instance.note.root.text=='未保存备注','Escape close discarded the unsaved note')
end)
Test('feature disable unsubscribes event and delayed responses cannot revive popup',function()
    local h,S,F,V,W=Boot();h:Receive();assert(F:Disable())
    assert(not W:IsVisible('tools.player_notes_sidecar')and F.consumerCount==0 and not V.started)
    h:Receive();assert(not W:IsVisible('tools.player_notes_sidecar'))
    assert(F:Enable());assert(not W:IsVisible('tools.player_notes_sidecar'),'enable reused previous session response')
    h:Receive();assert(W:IsVisible('tools.player_notes_sidecar')and F.consumerCount==1)
end)
Test('empty response opens truthful empty list; malformed response does not open',function()
    local h,S,F,V,W=Boot();S.Events:Dispatch('FRIENDLIST_INFO',true,'bad');assert(not W:IsVisible('tools.player_notes_sidecar'))
    h:Receive({});local instance=W:GetInstance('tools.player_notes_sidecar');assert(instance.visible and instance.table:GetItemCount()==0)
end)
Test('event snapshot is bounded detached and never captures unsupported fields',function()
    local h,S,F,V,W=Boot();local rows={};for i=1,205 do rows[i]={name='好友'..i,secret={password='unused'}}end
    h:Receive(rows);rows[1].name='changed'
    local d=V:GetFriendListSnapshot();assert(#d==200 and d[1].name=='好友1'and d[1].secret==nil)
    d[1].name='also changed';assert(V:GetFriendListSnapshot()[1].name=='好友1')
    local info=V:GetDiagnostics();assert(info.friendListCount==205 and info.friendListTruncated and info.friendListEvents==1)
    assert(F:GetProjection().error=='仅显示前200名好友','bounded cache lost truncation feedback')
end)
Test('updating list preserves editor draft and existing window geometry',function()
    local h,S,F,V,W=Boot();local instance=h:Receive();assert(instance.table:SetSelectedIndex(1));assert(instance.note:BeginEditing('test'))
    instance.note.root.text='未提交备注';instance.state.userMoved=true;instance.state.x,instance.state.y=75,95
    local shows=instance.shell.shows
    h:Receive({{'新好友@丙'},{'好友@甲'}})
    assert(instance.note:GetDraftValue()=='未提交备注'and instance.state.x==75 and instance.state.y==95)
    assert(instance.table:GetItem(2).name=='新好友@丙'and F.consumerCount==1)
    assert(instance.shell.shows==shows,'list data refresh brought existing popup forward')
end)
Test('native show failure releases demand and another response retries',function()
    local h,S,F,V,W=Boot();local instance=h:Receive();h:Close();local show=instance.shell.Show
    instance.shell.Show=function()return false,'injected show rejection'end;h:Receive()
    assert(F.consumerCount==0 and not instance.visible and not instance.acquired)
    instance.shell.Show=show;h:Receive();assert(instance.visible and F.consumerCount==1)
end)
Test('temporary hide rejection releases demand and next friend response restores it',function()
    local h,S,F,V,W=Boot();local instance=h:Receive();local show=instance.shell.Show
    instance.shell.Show=function(self,v)if v==false then return false,'temporary hide rejection'end;return show(self,v)end
    assert(F:Disable());assert(not instance.visible and F.consumerCount==0)
    instance.shell.Show=show;assert(F:Enable());h:Receive();assert(instance.visible and instance.acquired and F.consumerCount==1)
end)
Test('synchronous disable during acquisition cannot revive popup',function()
    local h,S,F,V,W=Boot();S.Events:SubscribeInternal(F.UpdateTopic,'test_disable',function(_,_,reason)if reason=='consumer_acquire'then assert(F:Disable())end end)
    h:Receive();local instance=W:GetInstance('tools.player_notes_sidecar')
    assert(not F.enabled and F.consumerCount==0 and not W:IsVisible('tools.player_notes_sidecar')and not instance.visible)
end)
Test('optional event registration rejection leaves manual notes usable without polling',function()
    local h,S,F,V,W=Boot({eventReject=true});assert(F.enabled and not V.eventSubscribed)
    assert(F.Commands:SaveNote('手动@甲','备注'));assert(F:GetNote('手动@甲')=='备注')
    assert(V:GetDiagnostics().status=='unavailable'and S.Scheduler.tasks[V.taskId]==nil)
end)
Test('diagnostic provider is cache only and reflects event and popup state',function()
    local h,S,F,V,W=Boot({diagnostics=true});h:Receive()
    local provider=assert(S.ModuleDiagnosticsHub.providers.tools_player_notes[1]);local d=provider.fn()
    assert(d.source=='social_list_response'and d.friendListEvents==1 and d.popupVisible and d.consumerAcquired)
    assert(d.nativeVisibilityKnown==false,'friend response claimed native social window visibility')
end)
Test('real foundation gate accepts service boundary without store writes',function()
    local h,S,F,V,W=Boot();local writes=h.writes;ReplicatedSuite={Features={},Services={PlayerNotesSurfaceV3=V},SafeTraceback=debug.traceback}
    dofile('core/rs_foundation_gate.lua');local report=ReplicatedSuite.FoundationGate:Run({skipSequences=true});ReplicatedSuite=S
    local boundary;for _,check in ipairs(report.checks)do if check.id=='service_presentation_boundary'then boundary=check end end
    assert(boundary and boundary.ok and h.writes==writes)
end)
-- 用户已实测原生好友页有效回包启窗；上线/成员变化与有效响应分开，保持原生Getter全nil的真实故障边界。
Test('background online membership block and raid notifications never open notes',function()
    local h,S,F,V,W=Boot()
    for _,event in ipairs({'FAMILY_MEMBER_ONLINE','FAMILY_REFRESH','FAMILY_INFO_REFRESH','FAMILY_MEMBER_ADDED','FAMILY_MEMBER_LEFT','FAMILY_MEMBER_KICKED','FAMILY_OWNER_CHANGED','FAMILY_REMOVED','FAMILY_NAME_CHANGED','BLOCKED_USERS_INFO','BLOCKED_USER_LIST','BLOCKED_USER_UPDATE','FRIENDLIST_UPDATE','TOGGLE_RAID_FRAME2','TOGGLE_RAID_FRAME_PARTY'})do
        S.Events:Dispatch(event,'update','member');assert(V:Refresh())
        assert(not W:IsVisible('tools.player_notes_sidecar'),event..' opened notes')
    end
    assert(F.consumerCount==0 and W:GetInstance('tools.player_notes_sidecar')==nil)
    assert(V.openRevision==0 and S.Scheduler.tasks[V.taskId]==nil,'background notification created opening or polling')
    local instance=assert(h:Receive());assert(instance.visible,'valid response failed to restore the real native-open path')
end)
Test('background notifications preserve manual dismissal until another valid native response',function()
    local h,S,F,V,W=Boot();local instance=h:Receive();assert(h:Close());local opening=V.openRevision
    for _,event in ipairs({'FAMILY_MEMBER_ONLINE','FAMILY_REFRESH','BLOCKED_USERS_INFO','TOGGLE_RAID_FRAME2'})do S.Events:Dispatch(event,'member')end
    assert(V:Refresh());assert(V.openRevision==opening and not W:IsVisible('tools.player_notes_sidecar'))
    assert(h:Receive()==instance and instance.visible and V.openRevision==opening+1 and F.consumerCount==1)
end)
Test('background notifications retain active view draft and native z-order',function()
    local h,S,F,V,W=Boot();local instance=h:Receive();assert(F.Commands:SetView('saved'));assert(instance.note:BeginEditing('test'))
    instance.note.root.text='未保存草稿';local shows=instance.shell.shows
    S.Events:Dispatch('FAMILY_MEMBER_ONLINE','member');S.Events:Dispatch('BLOCKED_USER_UPDATE','member');assert(V:Refresh())
    assert(F:GetProjection().view=='saved'and instance.note:GetDraftValue()=='未保存草稿'and instance.shell.shows==shows)
end)
Test('only valid expedition response opens and selects its list; malformed response stays quiet',function()
    local h,S,F,V,W=Boot();S.Events:Dispatch('EXPEDITION_MANAGEMENT_MEMBERS_INFO',1,1,'bad')
    assert(not W:IsVisible('tools.player_notes_sidecar'))
    S.Events:Dispatch('EXPEDITION_MANAGEMENT_MEMBERS_INFO',1,1,{{'远征成员'}})
    local instance=assert(W:GetInstance('tools.player_notes_sidecar'))
    assert(instance.visible and F:GetProjection().view=='expedition'and instance.table:GetItem(1).name=='远征成员')
end)
Test('manual popup remains usable without polling and feature disable removes observation',function()
    local h,S,F,V,W=Boot();assert(S.UIV3.PlayerNotesSidecar:Open());local instance=W:GetInstance('tools.player_notes_sidecar')
    assert(instance.visible and S.Scheduler.tasks[V.taskId]==nil)
    assert(F:Disable());assert(not instance.visible and F.consumerCount==0 and not V.started)
    h:Receive();assert(not W:IsVisible('tools.player_notes_sidecar'))
end)
print('PLAYER_NOTES_NATIVE_RESPONSES: '..passed..' cases passed (Native modeled)')
Test('friends use the native default name order instead of response order',function()
    local h,S,F,V,W=Boot();local instance=h:Receive({{'Zed@一'},{'Amy@二'},{'Amy@一'}})
    assert(instance.table:GetItem(1).name=='Amy@一'and instance.table:GetItem(3).name=='Zed@一')
    assert(V:GetFriendListSnapshot()[1][1]=='Zed@一','projection sorting mutated the detached source')
end)
Test('explicit refresh reads live friends and preserves response opening and draft',function()
    local h,S,F,V,W=Boot();local instance=h:Receive({{'Zed'},{'Amy'}})
    assert(instance.table:SetSelectedIndex(1));assert(instance.note:BeginEditing('test'));instance.note.root.text='待保存'
    local revision=V.openRevision;local writes=h.writes;local shows=instance.shell.shows
    h.nativeFriendList={{'Bea'},{'Amy'}};assert(F.Commands:Refresh('notes_popup_manual'))
    assert(h.friendReads==1 and h.friendRequests==0 and V.openRevision==revision and V.friendListEvents==1)
    assert(instance.table:GetItem(1).name=='Amy'and instance.table:GetItem(2).name=='Bea')
    assert(instance.note:GetDraftValue()=='待保存'and instance.shell.shows==shows and h.writes==writes)
    h.nativeFriendList=nil;assert(F.Commands:Refresh('notes_popup_manual'))
    assert(F:GetProjection().status=='unavailable','failed refresh silently displayed stale names')
    h.nativeFriendList={};assert(F.Commands:Refresh('notes_manual'));assert(instance.table:GetItemCount()==0)
end)
Test('name header cycles ascending descending and source order across views',function()
    local h,S,F,V,W=Boot();local instance=h:Receive({{'Zed'},{'Amy'}})
    assert(instance.table:GetSortState().direction=='asc')
    assert(instance.table:ToggleSort('name'));assert(instance.table:GetItem(1).name=='Zed')
    assert(instance.table:ToggleSort('name'));assert(instance.table:GetItem(1).name=='Zed'and instance.table:GetSortState().direction=='none')
    S.Events:Dispatch('EXPEDITION_MANAGEMENT_MEMBERS_INFO',2,1,{{'Zed'},{'Amy'}})
    assert(instance.table:GetItem(1).name=='Zed'and instance.table:GetSortState().direction=='none')
    assert(instance.table:ToggleSort('name'));assert(instance.table:GetItem(1).name=='Amy')
    assert(F.Commands:SetView('friends'));assert(instance.table:GetItem(1).name=='Zed'and instance.table:GetSortState().direction=='none')
    assert(h.friendReads==0 and h.friendRequests==0,'sorting fetched native data')
end)
Test('family and community event diagnostics do not guess an opening intent',function()
    local h,S,F,V,W=Boot()
    S.Events:Dispatch('FAMILY_MEMBER',true,{name='private'});S.Events:Dispatch('TOGGLE_COMMUNITY',true,{uic=UIC_FAMILY,name='private'})
    local d=V:GetDiagnostics();assert(d.socialEventFacts.FAMILY_MEMBER.count==1 and d.socialEventFacts.TOGGLE_COMMUNITY.count==1)
    assert(d.socialEventFacts.TOGGLE_COMMUNITY.uic==UIC_FAMILY and d.socialEventFacts.TOGGLE_COMMUNITY.firstBoolean==true)
    assert(d.socialEventFacts.FAMILY_MEMBER.argumentTypes=='boolean,table')
    assert(not W:IsVisible('tools.player_notes_sidecar')and V.openRevision==0 and S.Scheduler.tasks[V.taskId]==nil)
    d.socialEventFacts.FAMILY_MEMBER.count=99;assert(V:GetDiagnostics().socialEventFacts.FAMILY_MEMBER.count==1)
    assert(F:Disable());assert(F:Enable());assert(next(V:GetDiagnostics().socialEventFacts)==nil)
end)
Test('family getter order refresh and exact note identities remain independent of opening',function()
    local h,S,F,V,W=Boot();local reads,imports=0,0
    local native={{name='Zed',online=false},{name='Amy',online=true}}
    X2Family={GetMemberList=function(_,all)assert(all==true);reads=reads+1;return native end}
    S.ApiImports={AcquireApi=function(_,owner,cap)assert(owner=='service:PlayerNotesSurfaceV3:family'and cap=='X2Family:GetMemberList');imports=imports+1;return true end}
    assert(F.Commands:SaveNote('Amy','家人'));assert(S.UIV3.PlayerNotesSidecar:Open());assert(F.Commands:SetView('family'))
    local instance=W:GetInstance('tools.player_notes_sidecar');assert(instance.table:GetItem(1).name=='Zed'and instance.table:GetItem(2).note=='家人')
    assert(instance.table:GetSortState().direction=='none');local writes=h.writes
    assert(instance.table:ToggleSort('name'));assert(instance.table:GetItem(1).name=='Amy'and instance.table:GetItem(1).note=='家人')
    native={{name='Bea',online=true},{name='Amy',online=true}};assert(F.Commands:Refresh('notes_popup_manual'))
    assert(instance.table:GetItem(1).name=='Amy'and instance.table:GetItem(2).name=='Bea'and h.writes==writes)
    assert(reads>=2 and imports==reads and V.openRevision==0,'manual family view fabricated an automatic opening')
    local ok,list,count=V:ReadFamilyList();assert(ok and count==2);list[1].name='changed';assert(native[1].name=='Bea')
end)
print('PLAYER_NOTES_ORDER_REFRESH: regression cases passed (Native modeled)')
Test('global community probe is separate and releases exact callbacks on disable',function()
    local h,S,F,V,W=Boot({globalEvents=true});assert(V:GetDiagnostics().globalSubscriptions.TOGGLE_COMMUNITY)
    local native=0;local existing=function()native=native+1 end;UIParent:SetEventHandler('TOGGLE_COMMUNITY',existing)
    local old=h.globalHandlers.TOGGLE_COMMUNITY[1];h:Global('TOGGLE_COMMUNITY',true,{uic=UIC_FAMILY})
    assert(native==1 and V:GetDiagnostics().globalEventFacts.TOGGLE_COMMUNITY.firstBoolean==true)
    assert(V:GetDiagnostics().socialEventFacts.TOGGLE_COMMUNITY==nil and not W:IsVisible('tools.player_notes_sidecar'),'unknown global community contract guessed an opening')
    assert(F:Disable());assert(#h.globalHandlers.TOGGLE_COMMUNITY==1 and h.globalHandlers.TOGGLE_COMMUNITY[1]==existing)
    assert(F:Enable());old(false);assert(next(V:GetDiagnostics().globalEventFacts)==nil,'old global callback survived disable/re-enable')
    h:Global('TOGGLE_COMMUNITY',false);assert(native==2 and V:GetDiagnostics().globalEventFacts.TOGGLE_COMMUNITY.firstBoolean==false)
end)
print('PLAYER_NOTES_GLOBAL_TRANSPORT: cases passed (Native modeled)')
Test('explicit team information request opens grouped notes and selects the larger joint team',function()
    local roster={{name='甲',teamIndex=1,memberIndex=1},{name='乙',teamIndex=2,memberIndex=1},{name='丙',teamIndex=2,memberIndex=6}}
    local h,S,F,V,W=Boot({globalEvents=true,roster=roster});h:Global('TOGGLE_RAID_FRAME2')
    local instance=assert(W:GetInstance('tools.player_notes_sidecar'));local p=F:GetProjection()
    assert(instance.visible and p.view=='team'and p.teamScope==2 and #p.rows==2)
    assert(p.rows[2].partyIndex==2 and p.rows[2].statusText=='团2 · 2队')
    assert(F.Commands:SetTeamScope(0));assert(#F:GetProjection().rows==3)
    assert(h:Close());S.Events:Publish('v3.team_roster.updated',2);assert(not instance.visible,'roster update revived closed notes')
    h:Global('TOGGLE_RAID_FRAME2');assert(instance.visible and F:GetProjection().teamScope==2)
    assert(h.friendRequests==0 and S.Scheduler.tasks[V.taskId]==nil)
end)
Test('own chat commands use the unique note store and ignore other senders and ordinary chat',function()
    local h,S,F,V,W=Boot();local writes=h.writes
    S.Events:Dispatch('CHAT_MESSAGE',1,nil,'别人@甲','/bz Bob 敌对');assert(h.writes==writes and F:GetNote('Bob')==''and not W:IsVisible('tools.player_notes_sidecar'))
    local reads=h.identityReads;S.Events:Dispatch('CHAT_MESSAGE',1,nil,'本人@甲','普通消息');assert(h.identityReads==reads)
    S.Events:Dispatch('CHAT_MESSAGE',1,nil,'本人@甲','/bz Bob 敌对');assert(F:GetNote('Bob')=='敌对')
    S.Events:Dispatch('CHAT_MESSAGE',1,nil,'本人@甲','/bz 目标备注');assert(F:GetNote('目标@甲')=='目标备注')
    S.Events:Dispatch('CHAT_MESSAGE',1,nil,'本人@甲','/bzlist');local instance=assert(W:GetInstance('tools.player_notes_sidecar'))
    assert(instance.visible and F:GetProjection().view=='saved'and #F:GetProjection().rows==2)
    S.Events:Dispatch('CHAT_MESSAGE',1,nil,'本人@甲','/bzdel 1');assert(F:GetNote('Bob')=='')
    S.Events:Dispatch('CHAT_MESSAGE',1,nil,'本人@甲','/bzdel');assert(F:GetNote('目标@甲')=='')
    writes=h.writes;S.Events:Dispatch('CHAT_MESSAGE',1,nil,'本人@甲','/bzdel 999');assert(h.writes==writes)
    S.Events:Dispatch('CHAT_MESSAGE',1,nil,'本人@甲','/bz Bob '..string.rep('x',385));assert(h.writes==writes)
    assert(F:Disable());S.Events:Dispatch('CHAT_MESSAGE',1,nil,'本人@甲','/bz Bob 备注');assert(F:GetNote('Bob')=='')
end)
print('PLAYER_NOTES_REFERENCE_PARITY: cases passed (Native modeled)')
Test('non-team views release shared roster and native member slots define grouped order',function()
    local roster={{name='本人',teamIndex=1,memberIndex=43},{name='甲',teamIndex=1,memberIndex=1},{name='乙',teamIndex=1,memberIndex=6}}
    local h,S,F,V,W=Boot({roster=roster});local acquired,released=0,0
    S.Services.TeamRosterV3.AcquireConsumer=function()acquired=acquired+1;return true end
    S.Services.TeamRosterV3.ReleaseConsumer=function()released=released+1;return true end
    local instance=h:Receive();assert(acquired==0,'friend popup scanned the entire team')
    assert(F.Commands:SetView('team'));assert(acquired==1 and instance.table:GetItem(1).name=='甲'and instance.table:GetItem(3).partyIndex==9)
    assert(roster[1].name=='本人','group sorting mutated the shared source')
    assert(F.Commands:SetView('saved'));assert(released==1 and not F.rosterHeld)
    assert(F.Commands:SetView('team'));S.Services.TeamRosterV3.ReleaseConsumer=function()return false,'injected roster release rejection'end
    local ok,why=F.Commands:SetView('friends');assert(ok==false and why=='injected roster release rejection'and F.view=='team'and F.rosterHeld)
end)
Test('repeated unknown community readings back off without claiming hidden and known visibility restores cadence',function()
    local h,S,F,V,W=Boot({nativeSurface=true});local task=assert(S.Scheduler.tasks[V.taskId])
    for i=1,7 do assert(V:RefreshNativeVisibility())end
    assert(task.intervalMs==2000,'unreadable community was still queried four times per second')
    local d=V:GetDiagnostics();assert(d.visibilityUnknownStreak==8 and d.visibilityIntervalMs==2000 and d.visibilityKnownSamples==0)
    h:Receive();assert(W:IsVisible('tools.player_notes_sidecar'),'probe backoff suppressed valid friend response')
    h.socialVisible=true;assert(V:RefreshNativeVisibility());assert(task.intervalMs==250)
    d=V:GetDiagnostics();assert(d.visibilityKnownSamples==1 and d.visibilityUnknownStreak==0 and d.nativeVisibilityKnown)
    h.socialVisible=false;assert(V:RefreshNativeVisibility());assert(not W:IsVisible('tools.player_notes_sidecar'))
    assert(F:Disable());assert(S.Scheduler.tasks[V.taskId]==nil)
    h.socialVisible=nil;assert(F:Enable());assert(S.Scheduler.tasks[V.taskId].intervalMs==250 and V:GetDiagnostics().visibilityUnknownStreak==1)
end)
Test('raw native call audit compares targets forms and preserves nil arity without exporting native objects',function()
    local h,S,F,V,W=Boot({nativeSurface=true,nativeCallAudit=true})
    UIC_AUCTION=905;local calls=0;local widget={secret={name='不要导出'},IsVisible=function()return true end}
    ADDON.GetContentMainScriptPosVis=function(self,id)
        calls=calls+1
        if self~=ADDON then assert(type(self)=='number'and id==nil);return nil,nil,nil,nil,false,nil,33 end
        assert(type(id)=='number')
        if id==UIC_AUCTION then return 30,40,600,500,true end
        return nil,nil,nil,nil,nil
    end
    ADDON.GetContent=function(self,id)calls=calls+1;if self~=ADDON then return nil end;assert(type(id)=='number');return widget end
    assert(V:CaptureNativeCallAudit('controlled_test'))
    local d=V:GetDiagnostics();local frame=d.nativeCallAudit[#d.nativeCallAudit]
    assert(frame.reason=='controlled_test'and frame.targets.UIC_COMMUNITY.id==UIC_COMMUNITY)
    assert(frame.targets.UIC_COMMUNITY.mainWithSelf.returnCount==5 and frame.targets.UIC_COMMUNITY.mainWithSelf.returnTypes=='nil,nil,nil,nil,nil')
    assert(frame.targets.UIC_COMMUNITY.mainWithoutSelf.returnCount==7 and frame.targets.UIC_COMMUNITY.mainWithoutSelf.values[5]==false and frame.targets.UIC_COMMUNITY.mainWithoutSelf.values[7]==33)
    assert(frame.targets.UIC_AUCTION.mainWithSelf.values[5]==true and frame.targets.UIC_AUCTION.contentWithSelf.firstType=='table')
    assert(frame.targets.UIC_AUCTION.contentWithSelf.values[1]==nil,'audit retained a native object')
    frame.targets.UIC_COMMUNITY.mainWithoutSelf.values[5]='changed';assert(V:GetDiagnostics().nativeCallAudit[#d.nativeCallAudit].targets.UIC_COMMUNITY.mainWithoutSelf.values[5]==false)
    assert(V:GetSnapshot().openSignal~='native_community_visible','audit adopted an unverified alternate form as an opening signal')
    while V.nativeCallAuditCount<12 do assert(V:CaptureNativeCallAudit('budget'))end
    local before=calls;assert(V:CaptureNativeCallAudit('overflow')==false and calls==before)
    V:GetDiagnostics();assert(calls==before,'diagnostics retried raw native calls')
    assert(F:Disable());assert(V:CaptureNativeCallAudit('disabled')==false and calls==before)
end)
Test('call audit obeys API permissions and fences native reentry before later reads or history writes',function()
    local h,S,F,V,W=Boot({nativeSurface=true,nativeCallAudit=true});local calls=0
    ADDON.GetContentMainScriptPosVis=function()calls=calls+1;return nil end;ADDON.GetContent=ADDON.GetContentMainScriptPosVis
    local allowed=S.Api.IsCapabilityAllowed;S.Api.IsCapabilityAllowed=function()return false end
    assert(V:CaptureNativeCallAudit('blocked'));assert(calls==0,'raw audit bypassed API permissions')
    S.Api.IsCapabilityAllowed=allowed
    local count=V.nativeCallAuditCount
    ADDON.GetContentMainScriptPosVis=function()calls=calls+1;S.Generation=S.Generation+1;return nil end
    assert(V:CaptureNativeCallAudit('reentry')==false and calls==1 and V.nativeCallAuditCount==count,'old generation continued auditing')
end)
Test('response and subsequent scheduled observation record distinct raw-call phases',function()
    local h,S,F,V,W=Boot({nativeSurface=true,nativeCallAudit=true});local count=V.nativeCallAuditCount
    h:Receive();assert(V.nativeCallAuditCount==count+1 and V.nativeCallAudit[V.nativeCallAuditCount].reason=='friend_response')
    assert(V:RefreshNativeVisibility());assert(V.nativeCallAuditCount==count+2 and V.nativeCallAudit[V.nativeCallAuditCount].reason=='after_list_response')
end)
Test('dragged note layout survives close reopen and cold reload through the real auxiliary Store',function()
    local h,S,F,V,W=Boot();local instance=assert(h:Receive());local spec=instance.surface.spec
    local state=spec.getState();state.x,state.y,state.userMoved=345,234,true;state.coordinateSpace='logical-free-v2'
    assert(spec.setState(state,'geometry'));assert(spec.persist('geometry'));local disk=h.Copy(h.disk)
    h:Close();assert(S.UIV3.PlayerNotesSidecar:Open());assert(instance.state.x==345 and instance.state.y==234)
    local fresh,FS,FF,FV,FW=Boot({disk=disk});local restored=assert(fresh:Receive())
    assert(restored.state.x==345 and restored.state.y==234 and restored.state.userMoved)
end)
print('PLAYER_NOTES_SIDECAR_TOTAL: '..passed..' cases passed (Native modeled)')
