-- 中文维护：真实EventBus/Feature/Store/WidgetHost/RSUI；仅Native绘制与游戏好友名单响应为边界模型。
local Base=dofile('tools/rs_gear_page_test_host.lua')
local passed=0
local function Boot(options)
    options=options or {};local h=Base();assert(h.page:OnDeactivated());local S=h.S
    dofile('core/rs_demand.lua')
    h.friendReads=0;h.friendRequests=0;h.eventReject=options.eventReject
    S.Events.host={RegisterEvent=function(_,name)h.registeredEvent=name;return not h.eventReject end,UnregisterEvent=function()return true end}
    S.Events.running=true
    UIC_COMMUNITY,UIC_FRIEND,UIC_FAMILY,UIC_EXPEDITION=901,902,903,904
    ADDON.GetContent=function()return nil end;ADDON.GetContentMainScriptPosVis=function()return nil end
    X2Friend={GetFriendList=function()h.friendReads=h.friendReads+1;return h.nativeFriendList end,
        RequestFriendList=function()h.friendRequests=h.friendRequests+1;error('observer must not request friends')end}
    X2Unit.UnitName=function()return '目标@甲'end
    S.Layout={GetContext=function()return {logicalWidth=1920,logicalHeight=1080,usableWidth=1920,usableHeight=1080,safeLeft=0,safeTop=0,safeRight=0,safeBottom=0}end}
    S.Layout.ResolvePlacement=function(_,state,w,ht,x,y)return state and state.x or x,state and state.y or y,w,ht,{}end
    S.UI.CreateWindowShell=function(_,spec)
        local n=h.Native(nil,spec.id..'_native',0,0,spec.width,spec.height)
        local body=S.RSUI:VerticalBox({id=spec.id..'_body_model',parent=n,gap=0})
        local shell={root=n,minimizeButton={SetText=function()return true end},windowController={IsInteracting=function()return false end},spec=spec,locked=false}
        function shell:GetContentComponent()return body end;function shell:GetContentRoot()return body end
        function shell:GetNativeContentRoot()return body.root end;function shell:GetWindow()return n end
        function shell:ApplyPlacementRect(x,y,w,ht)n.x,n.y=x,y;n:SetExtent(w,ht);body:Layout(6,24,w-12,ht-46);return true end
        function shell:Show(v)self.shows=(self.shows or 0)+1;n:Show(v);return true end;function shell:IsLocked()return self.locked end
        function shell:SetLocked(v)self.locked=v;return true end;function shell:SetStatus(text)self.status=text;return true end
        function shell:GetPlacementDiagnostics()return {}end
        for _,key in ipairs({'SetOverallOpacity','SetBackgroundOpacity','SetTextOpacity','SetFontScale','SetMinimized'})do shell[key]=function()return true end end
        function shell:Close(reason)self:Show(false);return spec.onClosed(self,reason)end
        return shell
    end
    dofile('ui/framework/rs_ui_floating_surface.lua');dofile('presentation/v3/widgets/rs_v3_widget_host.lua')
    dofile('services/rs_player_notes_surface_v3.lua');dofile('features/shared/rs_feature_slice_factory.lua')
    dofile('features/tools/social/rs_player_notes_feature.lua')
    if options.diagnostics then dofile('features/rs_feature_registry.lua');dofile('core/rs_module_diagnostics.lua')end
    dofile('presentation/v3/widgets/rs_v3_player_notes_sidecar.lua')
    local F=S.Features.PlayerNotes;assert(F:Initialize());assert(F:Enable())
    local V,W=S.Services.PlayerNotesSurfaceV3,S.UIV3.WidgetHost
    function h:Receive(list)S.Events:Dispatch('FRIENDLIST_INFO',true,list or {{'好友@甲'},{name='好友@乙'}});return W:GetInstance('tools.player_notes_sidecar')end
    function h:Close()return assert(W:GetInstance('tools.player_notes_sidecar')).surface:Close('test_user_close')end
    return h,S,F,V,W
end
local function Test(name,fn)fn();passed=passed+1;print('PASS notes-friend-event '..name)end
Test('friend response opens popup despite all native surface getters returning nil',function()
    local h,S,F,V,W=Boot();assert(not W:IsVisible('tools.player_notes_sidecar'))
    local instance=assert(h:Receive());assert(W:IsVisible('tools.player_notes_sidecar')and instance.visible and F.consumerCount==1)
    assert(instance.table:GetItem(1).name=='好友@甲'and instance.table:GetItem(2).name=='好友@乙')
    assert(h.friendRequests==0 and h.friendReads==0,'event path performed extra native friend query')
    assert(h.registeredEvent=='FRIENDLIST_INFO'and S.Scheduler.tasks[V.taskId]==nil,'observer still polls native windows')
end)
Test('manual close stays closed until another friend response and reuses one popup',function()
    local h,S,F,V,W=Boot();local instance=h:Receive();assert(h:Close())
    assert(not W:IsVisible('tools.player_notes_sidecar')and F.consumerCount==0)
    assert(V:Refresh());assert(not W:IsVisible('tools.player_notes_sidecar'),'unchanged snapshot revived dismissed popup')
    assert(h:Receive()==instance and W:IsVisible('tools.player_notes_sidecar')and F.consumerCount==1 and W.stats.creates==1)
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
    assert(instance.table:GetItem(1).name=='新好友@丙'and F.consumerCount==1)
    assert(instance.shell.shows>shows,'new response did not bring existing popup forward')
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
    assert(d.source=='friend_list_event'and d.friendListEvents==1 and d.popupVisible and d.consumerAcquired)
    assert(d.nativeVisibilityKnown==false,'friend response claimed native social window visibility')
end)
Test('real foundation gate accepts service boundary without store writes',function()
    local h,S,F,V,W=Boot();local writes=h.writes;ReplicatedSuite={Features={},Services={PlayerNotesSurfaceV3=V},SafeTraceback=debug.traceback}
    dofile('core/rs_foundation_gate.lua');local report=ReplicatedSuite.FoundationGate:Run({skipSequences=true});ReplicatedSuite=S
    local boundary;for _,check in ipairs(report.checks)do if check.id=='service_presentation_boundary'then boundary=check end end
    assert(boundary and boundary.ok and h.writes==writes)
end)
print('PLAYER_NOTES_FRIEND_EVENT: '..passed..' cases passed (Native modeled)')
