-- Replicated Suite · 位置锁定存储测试
-- 作者：Replicated
-- QQ群：1104129461
-- 锁偏好的真实 Persistence/Transport 往返；Native 与物理磁盘仍是模型。
local NewHost=dofile('tools/rs_gear_page_test_host.lua')
local passed=0
local function Test(name,fn)fn();passed=passed+1;print('PASS lock-store '..name)end
Test('launcher locked preference reloads through the real store without changing placement',function()
    local h=NewHost();local s=h.S
    s.RecoveryEntry=h.Native(nil,'launcher_lock_store',300,100,30,30)
    function s.RecoveryEntry:EnableDrag(v)self.dragEnabled=v;return true end
    dofile('presentation/v3/rs_v3_launcher_store.lua')
    local v=s.UIV3;assert(v:EnsureLauncherStoreLoaded())
    assert(v:SetLauncherLocked(true));assert(s.Persistence:SaveStore(v.LauncherStoreId,{durable=true,consumeDirty=true}))
    s.Persistence:GetStore(v.LauncherStoreId).loaded=false;v.LauncherStoreLoaded=false;v.LauncherState={}
    assert(v:EnsureLauncherStoreLoaded());assert(v.LauncherState.locked==true and v.LauncherState.userMoved==false)
    assert(v:SetLauncherLocked(false));assert(s.Persistence:SaveStore(v.LauncherStoreId,{durable=true,consumeDirty=true}))
    s.Persistence:GetStore(v.LauncherStoreId).loaded=false;v.LauncherStoreLoaded=false;v.LauncherState={}
    assert(v:EnsureLauncherStoreLoaded());assert(v.LauncherState.locked==nil,'unlock added a false key to old canonical')
end)
Test('feature profile lock uses the real durable store and preserves existing profiles',function()
    local h=NewHost();local s=h.S
    local meta={id='tools_feature_profiles',name='功能方案',category='tools',route='tools.feature_profiles'}
    s.FeatureRegistry={Get=function()return meta end,ListAccessible=function()return {meta}end,IsAccessible=function()return true end}
    dofile('core/rs_demand.lua');dofile('features/tools/rs_feature_profiles_feature.lua')
    local f=s.Features.FeatureProfiles;assert(f:EnsureStoreLoaded());assert(f.Commands:CreateProfile('保留方案'))
    assert(f.Commands:SetQuickButtonsLocked(true))
    s.Persistence:GetStore(f.storeId).loaded=false;f.storeLoaded=false;f.State={}
    assert(f:EnsureStoreLoaded());assert(f:GetProjection().quickButtonsLocked)
    assert(#f.State.profiles==1 and f.State.profiles[1].name=='保留方案')
    assert(f.Commands:SetQuickButtonsLocked(false))
    s.Persistence:GetStore(f.storeId).loaded=false;f.storeLoaded=false;f.State={}
    assert(f:EnsureStoreLoaded());assert(f.State.quickButtonsLocked==nil)
end)
Test('gear main page lock is clickable and saved through the existing quick HUD store',function()
    local h=NewHost();local control=assert(h.widgets.v3_gear_quick_lock,'gear settings lock missing')
    assert(control.root.events.OnClick(control.root,'LeftButton'));assert(h.F:GetQuickHudProjection().locked)
    -- 只带磁盘重建宿主，不额外 Save/Flush 掩盖锁定命令仅排期的问题。
    local cold=NewHost({disk=h.Copy(h.disk)});assert(cold.F:GetQuickHudProjection().locked,'gear lock lost before a persistence heartbeat')
    local unlocked=assert(cold.widgets.v3_gear_quick_lock)
    assert(unlocked.root.events.OnClick(unlocked.root,'LeftButton'))
    local again=NewHost({disk=cold.Copy(cold.disk)});assert(not again.F:GetQuickHudProjection().locked,'gear unlock lost before immediate exit')
end)
Test('gear lock rejects a failed Native write or stale readback without changing its saved intent',function()
    for _,mode in ipairs({'reject','stale'})do
        local h=NewHost();assert(not h.F:GetQuickHudProjection().locked)
        if mode=='reject' then h.failSave=true else ADDON.SaveData=function()return true end end
        local ok=h.F.Commands:SetQuickHudAppearance('locked',true,true,'gear_quick_buttons_locked')
        assert(ok==false,'gear lock accepted '..mode..' disk write')
        assert(not h.F:GetQuickHudProjection().locked,'rejected gear lock left a changed preference')
    end
end)
Test('gear position has durable readback before cold reload and rejects stale geometry',function()
    local h=NewHost();local id=assert(h.F.Authority:CreateSet('退出位置回归'))
    local placement={coordinateSpace='logical-edge-v1',anchorH='LEFT',anchorV='TOP',offsetX=0,offsetY=0}
    assert(h.F.Authority:SetQuickPosition(id,0,0,placement))
    assert(h.S.Persistence:GetStore('v3.gear.index').needsBarrierVerify==false,'gear position returned without readback')
    local cold=NewHost({disk=h.Copy(h.disk)});local set=assert(cold.F.Authority:FindSet(id))
    assert(set.quickX==0 and set.quickY==0 and set.quickPositionCustomized,'zero position lost on immediate reload')
    ADDON.SaveData=function()return true end
    assert(cold.F.Authority:SetQuickPosition(id,70,90,placement)==false,'gear position accepted stale readback')
    local retained=assert(cold.F.Authority:FindSet(id));assert(retained.quickX==0 and retained.quickY==0,'failed position replaced committed coordinates')
end)
Test('session-window chrome locks persist through real transport without adding absent keys to old state',function()
    local h=NewHost();local s=h.S;dofile('ui/framework/rs_ui_window_preferences.lua')
    local prefs=s.RSUI.WindowPreferences;assert(prefs:EnsureLoaded());assert(prefs.state.locked==nil)
    assert(type(prefs.SetLocked)=='function','session-window lock persistence missing')
    assert(prefs:SetLocked('test_session_settings',true,true))
    s.Persistence:GetStore(prefs.storeId).loaded=false;prefs.loaded=false;prefs.state={}
    assert(prefs:GetLocked('test_session_settings'));assert(prefs:SetLocked('test_session_settings',false,true))
    s.Persistence:GetStore(prefs.storeId).loaded=false;prefs.loaded=false;prefs.state={}
    assert(not prefs:GetLocked('test_session_settings'));assert(prefs.state.locked==nil,'empty lock map changed historical canonical')
end)
print('POSITION_LOCK_STORE PASS: '..passed..' cases (Native modeled)')
