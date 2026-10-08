-- 中文维护（2026-10-07）：完整 Native 替身/真实 Runtime 宿主恢复自 044ffed；
-- 只有 runtimeHud=true 显式使用，防止领域/CD 回归被额外 Renderer 和 Native 生命周期污染。
-- 维护（pvp-hud-1）：开发期宿主。保留真实 Store/Demand/Events/Scheduler/FrameBudget/
-- Feature/Renderer；只替换 Native 图形、游戏事实与内存磁盘。不进入 toc.g，不声称 RU 实测。
local function BootHudRuntime(options)
    options=options or {}
    local h=dofile('tools/rs_gear_page_test_host.lua')({width=1280,height=768})
    h.page:OnDeactivated()
    local S=h.S
    h.scans,h.projectionReads,h.itemReads,h.anchors,h.textures=0,0,0,0,0
    h.facts={player={},target={}};h.points={player={350,350,1},target={850,350,1}}
    h.weapon='old-weapon.dds';h.visibleAnchors=0
    UIParent=h.Native(nil,'UIParent',0,0,1280,768)
    function UIParent:GetScreenWidth()return h.width or 1280 end
    function UIParent:GetScreenHeight()return h.height or 768 end
    local oldCreate=S.UI.CreateEmptyWidget
    S.UI.CreateEmptyWidget=function(_,parent,id,x,y,w,ht,pick,owner)
        local n=oldCreate(S.UI,parent,id,x,y,w,ht,pick,owner)
        function n:CreateIconDrawable()return h.Native(self,self.id..'_icon',0,0,1,1)end
        return n
    end
    S.UI.SetAlpha=function(_,n,v)n.alpha=v;return true end
    S.UI.SetIconTexture=function(_,n,path)
        h.textures=h.textures+1
        if h.rejectTexture==path then return false end
        n.texture=path;return true
    end
    S.UI.EnsureIconTexture=function(_,n,path)
        if n.texture==path then return true,false end
        local ok=S.UI:SetIconTexture(n,path);return ok,ok,not ok and 'rejected' or nil
    end
    local oldAnchor=S.UI.SetAnchor
    S.UI.SetAnchor=function(_,n,p,x,y)
        h.anchors=h.anchors+1
        if h.rejectAnchor==n then return false end
        return oldAnchor(S.UI,n,p,x,y)
    end
    S.UI.EnsureAnchor=function(_,n,p,x,y)
        if n.parent==p and n.x==x and n.y==y then return true,false end
        local ok=S.UI:SetAnchor(n,p,x,y);return ok,ok
    end
    S.Api.GetUiMetrics=function()return h.width or 1280,h.height or 768,h.scale or 1,(h.width or 1280)/(h.scale or 1),(h.height or 768)/(h.scale or 1)end
    S.Layout={GetLogicalRect=function(_,n)return n.x,n.y,n.width,n.height end}
    S.SafeChat=function()return true end;S.PhysicalId=function(s)return s end
    S.AdvanceClock=function(dt)h.ms=h.ms+dt end
    S.NativeObjectFactory={CreateEmptyWidget=function(_,id)return h.Native(nil,id,0,0,1,1)end}
    dofile('core/rs_frame_budget.lua');dofile('core/rs_demand.lua')
    dofile('data/rs_data_registry.lua');dofile('data/ids/rs_plates_ids.lua')
    S.UI.CreateWindowShell=function()error('unexpected shell construction')end
    dofile('ui/framework/rs_ui_floating_surface.lua')
    dofile('features/combat/buff_display/rs_buff_display_store.lua')
    dofile('features/combat/buff_display/rs_buff_display_projection.lua')
    S.Services.AuraObservationV3={AcquireConsumer=function()return true end,ReleaseConsumer=function()return true end,
        GetSnapshot=function(_,scope,opts)h.scans=h.scans+1;h.lastAuraForce=opts.forceRefresh;return {scope=scope,at=h.ms,revision=h.scans}end,
        GetStatusMap=function(_,snap)return h.Copy(h.facts[snap.scope]),{available=true,complete=true,reliable=true}end}
    S.Services.StatusClassificationV3={ClassifyEntry=function(_,entry)return {category='buff',detectionSource='normal'}end}
    S.Services.GearV3={GetEquipped=function(_,slot)h.itemReads=h.itemReads+1;return {name='equipped '..slot,icon=h.weapon}end}
    local function Project(_,scope)
        h.projectionReads=h.projectionReads+1;local p=h.points[scope]
        if not p then return nil,nil,nil,'unit_screen_position_unavailable' end
        return p[1],p[2],p[3],nil,'native_unit'
    end
    S.Services.ScreenProjectionV3={ProjectUnit=Project,ProjectUnitFlexible=Project,
        GetUiParentViewport=function()return h.width or 1280,h.height or 768 end}
    dofile('features/combat/buff_display/rs_buff_display_feature.lua')
    local F=S.Features.BuffDisplay;h.F=F;assert(F:EnsureStoreLoaded());F.enabled=true
    F.State.settings.headEnabled=true;F.State.settings.headPlayer=true;F.State.settings.headTarget=true
    -- No unknown Native cast API is needed for these tests.
    F.State.settings.components.castBar.enabled=false;F.State.settings.targetLayout.components.castBar.enabled=false
    F:InvalidateSettingsCache()
    if options.noRenderer then assert(F:AcquireConsumer('test:observer'))
    else dofile('presentation/v3/widgets/rs_v3_buff_head_markers.lua');h.P=S.UIV3.BuffHeadMarkersV3;assert(h.P.running)end
    assert(S.Scheduler:Start())
    function h:Step(dt)S.Scheduler.driver.events.OnUpdate(S.Scheduler.driver,dt or 16)end
    function h:Event(name)S.Events:Dispatch(name)end
    function h:Fact(id)return {id=id,name='effect'..id,iconPath='buff'..id..'.dds',sources={buff=true}}end
    function h:World(n)local x,y=n.x or 0,n.y or 0;local p=n.parent;while type(p)=='table'do x=x+(p.x or 0);y=y+(p.y or 0);p=p.parent end;return x,y end
    -- 排序后的慢任务可能在首帧位置采样之后发布内容；再推进一帧完成启动快照。
    h:Step(16);h:Step(16)
    return h,S,F,h.P
end

-- Phase 0 recovered lightweight BuffDisplay domain host used by scoped tracking regressions.
-- Test infrastructure only; it deliberately stops before transfer/presentation modules so each owning
-- regression can load the exact production layer it intends to test without double-wrapping APIs.
local function Copy(value,seen)
    if type(value)~='table' then return value end
    seen=seen or {};if seen[value] then return seen[value] end
    local out={};seen[value]=out;for k,v in pairs(value)do out[Copy(k,seen)]=Copy(v,seen)end;return out
end
return function(options)
    options=options or {}
    if options.runtimeHud == true then return BootHudRuntime(options) end
    local io={disk=Copy(options.disk or {}),reads=0,writes=0}
    local S={Generation=41,Features={},Services={},RSUI={},UI={CreateWindowShell=function()return nil,'test_no_window'end},Utils={DeepCopy=Copy},BuildTag='phase0-pvp-domain-host'}
    ReplicatedSuite=S;S.SafeTraceback=debug.traceback;S.PhysicalId=function(v)return tostring(v or '')end
    S.FeatureRuntime={RegisterImplementation=function()return true end,IsEnabled=function()return true end,SetTaskModule=function()return true end}
    S.Scheduler={tasks={}};function S.Scheduler:AddTask(name,ms,fn)self.tasks[name]={callback=fn,fn=fn,ms=ms};return true end
    function S.Scheduler:AddHighFrequencyTask(name,ms,fn)return self:AddTask(name,ms,fn)end
    function S.Scheduler:AddOneShot(name,ms,fn)return self:AddTask(name,ms,fn)end
    function S.Scheduler:RemoveTask(name)self.tasks[name]=nil;return true end;function S.Scheduler:SetTaskModule()return true end
    S.Events={listeners={}}
    function S.Events:SubscribeOptional(topic,owner,fn)self.listeners[#self.listeners+1]={topic=topic,owner=owner,fn=fn};return true end
    function S.Events:SubscribeInternal(topic,owner,fn)return self:SubscribeOptional(topic,owner,fn)end
    function S.Events:UnsubscribeOwner(owner)for i=#self.listeners,1,-1 do if self.listeners[i].owner==owner then table.remove(self.listeners,i)end end;return true end
    S.Events.UnsubscribeInternalOwner=S.Events.UnsubscribeOwner
    function S.Events:Publish(topic,...)for _,r in ipairs(self.listeners)do if r.topic==topic then r.fn(r.owner,...)end end;return true end
    S.Api={allowedCapabilities={}}
    function S.Api:LoadData(key)io.reads=io.reads+1;return Copy(io.disk[key])end
    function S.Api:SaveData(key,value)io.writes=io.writes+1;io.disk[key]=Copy(value);return true end
    function S.Api:ClearData(key)io.disk[key]=nil;return true end
    function S.Api:IsCapabilityAllowed()return true end
    function S.Api:GetCharacterId()return 'phase0-test-character'end
    function S.Api:GetCharacterName()return 'Phase0'end
    for _,f in ipairs({'data/rs_data_registry.lua','data/rs_skill_effects.lua','data/rs_combat_ability_catalog.lua','data/ids/rs_buff_ids.lua','data/ids/rs_plates_ids.lua','services/rs_status_classification_v3.lua','data/rs_status_tracking_catalog.lua','core/rs_persistence_transport.lua','core/rs_persistence.lua','core/rs_demand.lua','ui/framework/rs_ui_floating_surface.lua','features/combat/buff_display/rs_buff_display_store.lua','features/combat/buff_display/rs_buff_display_projection.lua','features/combat/buff_display/rs_buff_display_feature.lua','features/combat/buff_display/rs_buff_display_management.lua'})do dofile(f)end
    local F=assert(S.Features.BuffDisplay,'BuffDisplay feature missing')
    S.Services.AuraObservationV3=S.Services.AuraObservationV3 or {GetSnapshot=function()return nil,'test_no_native_aura'end}
    local h={S=S,P=S.Persistence,io=io,disk=io.disk}
    return h,S,F,nil
end
