------------------------------------------------------------------------
-- Replicated Suite · 窗口立即退出重登回归
-- 作者：Replicated
-- QQ群：1104129461
--
-- 覆盖实际用户提交到 Store 的同步耐久边沿，不执行心跳或退出 Flush。
-- 本文件仅供开发期离线测试，禁止加入运行时 TOC。
------------------------------------------------------------------------
-- 维护：只运行真实 Persistence/Transport/Layout/Windowing/Shell/Floating/Aux；
-- Native 控件和 SaveData 是隔离模型，绝不触碰用户 UDF，不能当作 RU 真机认证。
local NativeBoot=dofile('tools/rs_window_viewport_test_host.lua')
local function Copy(v)local out={};for k,x in pairs(v)do out[k]=type(x)=='table' and Copy(x) or x end;return out end
local function Boot(disk)
    local h=NativeBoot();h.disk=Copy(disk or {});h.diskWrites=0;h.reads=0
    ADDON={LoadData=function(_,key)h.reads=h.reads+1;return h.disk[key] and Copy(h.disk[key]) end,
        SaveData=function(_,key,value)h.diskWrites=h.diskWrites+1;if h.rejectSave then return false end;if h.dropSave then return true end;h.disk[key]=Copy(value);return true end,
        ClearData=function()error('must not clear saves')end}
    h.S.NowMs=function()return 1000 end;h.S.UIV3={};h.S.Features={};h.S.Services={}
    dofile('core/rs_utils.lua');dofile('core/rs_reuse.lua');dofile('core/rs_demand.lua')
    dofile('core/rs_api_capabilities.lua');dofile('core/rs_persistence_transport.lua');dofile('core/rs_persistence.lua')
    dofile('presentation/v3/rs_v3_aux_window_store.lua')
    h.P=h.S.Persistence;h.A=h.S.UIV3.AuxWindowStoreV3;assert(h.A:EnsureLoaded())
    function h:Aux(id)
        local spec={id='aux_'..id,statePolicy=self.A:GetPolicy(id),getState=function()return self.A:GetWindowState(id)end,
            setState=function(v,reason)return self.A:SetWindowState(id,v,reason)end,
            persist=function(reason,delay)return self.A:PersistWindow(id,reason,delay)end}
        local s=self:Surface(assert(self.A:GetWindowState(id)),spec);assert(s:Show(true));return s
    end
    return h
end
local function Eq(a,b)assert(a==b,tostring(a)..' ~= '..tostring(b))end
local function Drag(s,x,y)local n=s.shell.titleBar.root;assert(n.handlers.OnDragStart());s.window.x=x;s.window.y=y;return n.handlers.OnDragStop()end
local pass,fail=0,0
local function Test(name,fn)local ok,e=xpcall(fn,debug.traceback);if ok then pass=pass+1;print('PASS floating relog '..name)else fail=fail+1;print('FAIL floating relog '..name..': '..tostring(e))end end

Test('completed drag is durable without scheduler or shutdown flush',function()
    local h=Boot();local s=h:Aux('bag_settings');assert(Drag(s,0,175));assert(h.diskWrites>0);assert(h.reads>1)
    local x,y=s.window.x,s.window.y;local fresh=Boot(h.disk);local restored=fresh:Aux('bag_settings');Eq(restored.window.x,x);Eq(restored.window.y,y)
end)
Test('API lock and unlock survive immediate cold construction',function()
    local h=Boot();local s=h:Aux('bag_settings');local before=h.diskWrites;assert(s:SetLocked(true,true));assert(h.diskWrites>before,'lock queued without SaveData')
    local fresh=Boot(h.disk);local restored=fresh:Aux('bag_settings');Eq(restored:IsLocked(),true)
    before=fresh.diskWrites;assert(restored:SetLocked(false,true));assert(fresh.diskWrites>before,'unlock queued without SaveData')
    local again=Boot(fresh.disk);Eq(again:Aux('bag_settings'):IsLocked(),false)
end)
Test('title lock and unlock survive immediate cold construction',function()
    local h=Boot();local s=h:Aux('bag_settings');local before=h.diskWrites;assert(s.shell.lockButton.spec.onClick());assert(h.diskWrites>before,'title lock queued without SaveData')
    local fresh=Boot(h.disk);local restored=fresh:Aux('bag_settings');Eq(restored:IsLocked(),true)
    assert(restored.shell.lockButton.spec.onClick());local again=Boot(fresh.disk);Eq(again:Aux('bag_settings'):IsLocked(),false)
end)
Test('API collapse and expand survive immediate cold construction',function()
    local h=Boot();local s=h:Aux('bag_settings');assert(s:SetMinimized(true,true));local fresh=Boot(h.disk);local restored=fresh:Aux('bag_settings');Eq(restored:IsMinimized(),true)
    assert(restored:SetMinimized(false,true));local again=Boot(fresh.disk);Eq(again:Aux('bag_settings'):IsMinimized(),false)
end)
Test('rejected API lock does not fall through to successful Stage',function()
    local h=Boot();local s=h:Aux('bag_settings');assert(Drag(s,300,200));local before=Copy(h.A.state.bag_settings);h.rejectSave=true
    local ok=s:SetLocked(true,true);assert(ok==false,'Save rejection became successful Stage');Eq(s:IsLocked(),false);Eq(h.A.state.bag_settings.locked,before.locked)
    local fresh=Boot(h.disk);Eq(fresh:Aux('bag_settings'):IsLocked(),false)
end)
Test('rejected title lock rolls back Native and Store',function()
    local h=Boot();local s=h:Aux('bag_settings');assert(Drag(s,300,200));h.rejectSave=true
    assert(s.shell.lockButton.spec.onClick()==false,'title lock accepted rejected SaveData');Eq(s:IsLocked(),false);Eq(h.A.state.bag_settings.locked,false)
end)
Test('preview lock neither writes nor reads disk',function()
    local h=Boot();local s=h:Aux('bag_settings');local writes,reads=h.diskWrites,h.reads
    assert(s:SetLocked(true,false));Eq(s:IsLocked(),true);Eq(h.diskWrites,writes);Eq(h.reads,reads)
end)
local appearances={{'SetOverallOpacity','overallOpacity',.5,'overall_opacity'},{'SetBackgroundOpacity','backgroundOpacity',0,'background_opacity'},
    {'SetTextOpacity','textOpacity',.5,'text_opacity'},{'SetFontScale','fontScale',1.1,'font_scale'}}
Test('all completed API appearance values survive immediate cold construction',function()
    for _,row in ipairs(appearances)do
        local h=Boot();local s=h:Aux('bag_settings');assert(s[row[1]](s,row[3],true))
        local cold=Boot(h.disk);local restored=cold:Aux('bag_settings')
        Eq(cold.A:GetWindowState('bag_settings')[row[2]],row[3]);local nativeField=row[2]=='overallOpacity' and 'opacity' or row[2];Eq(restored.shell[nativeField],row[3])
    end
end)
Test('all API appearance saves report Native rejection or silent loss and restore Native and Store',function()
    local methods={{'SetOverallOpacity','overallOpacity',.5},{'SetBackgroundOpacity','backgroundOpacity',.5},{'SetTextOpacity','textOpacity',.5},{'SetFontScale','fontScale',1.1}}
    for _,row in ipairs(methods)do for _,mode in ipairs({'rejectSave','dropSave'})do
        local h=Boot();local s=h:Aux('bag_settings');assert(Drag(s,300,200));local before=Copy(h.A.state.bag_settings)
        -- 维护：真实 SaveData 拒写/静默丢写均须穿过 Core durable 回读，不能用 Persist=false 桩替代实际故障。
        h[mode]=true
        assert(s[row[1]](s,row[3],true)==false,row[1]..' turned rejection into Stage success')
        Eq(h.A.state.bag_settings[row[2]],before[row[2]]);local nativeField=row[2]=='overallOpacity' and 'opacity' or row[2];Eq(s.shell[nativeField],before[row[2]])
        local cold=Boot(h.disk);cold:Aux('bag_settings');Eq(cold.A.state.bag_settings[row[2]],before[row[2]])
    end end
end)
Test('public appearance previews perform zero storage IO',function()
    for _,row in ipairs(appearances)do
        local h=Boot();local s=h:Aux('bag_settings');local writes,reads=h.diskWrites,h.reads
        assert(s[row[1]](s,row[3],false));Eq(h.diskWrites,writes);Eq(h.reads,reads)
    end
end)
Test('same value final after repeated public appearance previews is durable while ordinary same values stay IO free',function()
    for _,row in ipairs(appearances)do
        local h=Boot();local s=h:Aux('bag_settings');assert(Drag(s,300,200));local writes,reads=h.diskWrites,h.reads
        assert(s[row[1]](s,.8,false));assert(s[row[1]](s,row[3],false));Eq(h.diskWrites,writes);Eq(h.reads,reads)
        assert(s[row[1]](s,row[3],true))
        local cold=Boot(h.disk);local restored=cold:Aux('bag_settings');Eq(cold.A:GetWindowState('bag_settings')[row[2]],row[3])
        writes,reads=cold.diskWrites,cold.reads;assert(restored[row[1]](restored,row[3],true));Eq(cold.diskWrites,writes);Eq(cold.reads,reads)
    end
end)
Test('rejected same value public appearance final restores the original committed value and remains retryable',function()
    for _,row in ipairs(appearances)do for _,mode in ipairs({'rejectSave','dropSave'})do
        local h=Boot();local s=h:Aux('bag_settings');assert(Drag(s,300,200));local before=h.A:GetWindowState('bag_settings')
        assert(s[row[1]](s,.8,false));assert(s[row[1]](s,row[3],false));h[mode]=true
        assert(s[row[1]](s,row[3],true)==false,'same value preview final accepted '..mode)
        Eq(h.A:GetWindowState('bag_settings')[row[2]],before[row[2]])
        local nativeField=row[2]=='overallOpacity' and 'opacity' or row[2];Eq(s.shell[nativeField],before[row[2]])
        h[mode]=false;assert(s[row[1]](s,row[3],true))
        local cold=Boot(h.disk);Eq(cold.A:GetWindowState('bag_settings')[row[2]],row[3])
    end end
end)
Test('StateAdapter failure after public previews restores the original committed values',function()
    local methods={'setOverallOpacity','setBackgroundOpacity','setTextOpacity','setFontScale'}
    for index,row in ipairs(appearances)do for _,mode in ipairs({'rejectSave','dropSave'})do
        local h=Boot();local s=h:Aux('bag_settings');assert(Drag(s,300,200));local before=h.A:GetWindowState('bag_settings')
        local adapter=h.S.RSUI.FloatingSurface:CreateStateAdapter(s.spec);local set=adapter[methods[index]]
        assert(set(.8,false));assert(set(row[3],false));h[mode]=true
        assert(set(row[3],true)==false,'adapter accepted '..mode);Eq(h.A:GetWindowState('bag_settings')[row[2]],before[row[2]])
    end end
end)
Test('failed final restores every staged appearance channel and preserves absent original keys',function()
    local h=Boot();local raw={width=620,height=460};local id='v3.test_appearance_stage'
    assert(h.P:RegisterV3Store({id=id,owner=id,scope=h.P.Scope.Account,lifetime=h.P.Lifetime.Permanent,schemaVersion=1,legacySchemaVersion=0,
        key=h.P.V3KeyPrefix..'test_appearance_stage',budget={maxDepth=4,maxNodes=80,maxStringBytes=1024,maxEntriesPerTable=40},
        default=function()return {width=620,height=460}end,get=function()return Copy(raw)end,
        apply=function(v)raw=Copy(v)end}));assert(h.P:LoadStore(id)=='empty');assert(h.P:SaveStore(id,{durable=true}))
    local s=h:Surface(raw,{getState=function()return raw end,setState=function(v)raw=Copy(v);return true end,
        persist=function()return h.P:SaveStore(id,{durable=true,consumeDirty=true})end});assert(s:Show(true))
    assert(s:SetOverallOpacity(.5,false));assert(s:SetFontScale(1.1,false));h.dropSave=true
    assert(s:SetOverallOpacity(.5,true)==false)
    Eq(raw.overallOpacity,nil);Eq(raw.fontScale,nil);Eq(raw.width,620);Eq(raw.height,460)
    Eq(s.shell.opacity,.94);Eq(s.shell.fontScale,1)
    h.dropSave=false;assert(s:SetFontScale(1.1,true));Eq(raw.overallOpacity,.94);Eq(raw.fontScale,1.1)
end)
-- 维护：直接加载真实 Store owner，验证每个发布中的 reason 前缀均提交原 Store；
-- 测试在隔离 Domain 中改窗口标量，不复制生产 Store 归一化/持久化实现。
local owners={
    {'Activities','features/life/activities/rs_activity_store.lua','v3.activities','widget_'},
    {'Tasks','features/life/tasks/rs_task_store.lua','v3.tasks','task_widget_'},
    {'DPS','features/combat/dps/rs_dps_store.lua','v3.dps','widget_'},
    {'DeathReview','features/combat/death_review/rs_death_review_store.lua','v3.death_review','widget_'},
    {'BuffDisplay','features/combat/buff_display/rs_buff_display_store.lua','v3.buff_display.settings','widget_'},
}
local function Owner(h,row)
    dofile(row[2]);local f=assert(h.S.Features[row[1]]);local status,_,err=h.P:LoadStore(row[3]);assert(status==true or status=='empty',err)
    return f
end
for _,row in ipairs(owners)do
    Test(row[1]..' owner locked/lock reasons save durable and cold reload true/false',function()
        local h=Boot();local f=Owner(h,row);f.State.widgetWindow.locked=true
        local writes,reads=h.diskWrites,h.reads;assert(f:MarkStoreDirty(250,row[4]..'locked'));assert(h.diskWrites>writes and h.reads>reads,'owner only queued locked')
        local cold=Boot(h.disk);local fresh=Owner(cold,row);Eq(fresh.State.widgetWindow.locked,true)
        fresh.State.widgetWindow.locked=false;writes,reads=cold.diskWrites,cold.reads
        assert(fresh:MarkStoreDirty(250,row[4]..'lock'));assert(cold.diskWrites>writes and cold.reads>reads,'owner only queued legacy lock')
        local again=Boot(cold.disk);Eq(Owner(again,row).State.widgetWindow.locked,false)
    end)
    Test(row[1]..' owner commits every final appearance reason before cold reload',function()
        for _,appearance in ipairs(appearances)do
            local h=Boot();local f=Owner(h,row);f.State.widgetWindow[appearance[2]]=appearance[3]
            assert(f:MarkStoreDirty(250,row[4]..appearance[4]))
            local cold=Boot(h.disk);Eq(Owner(cold,row).State.widgetWindow[appearance[2]],appearance[3])
        end
    end)
end
Test('life shared owner locked/lock reasons save durable and retain detached false state',function()
    local function Life(h)
        dofile('features/life/shared/rs_life_slice_factory.lua');local f={storeId='v3.test_life_widget',State={widgetWindow={locked=false}}}
        local L=h.S.LifeSliceFactory;L.InstallLifeWidgetContract(f,{defaultWidth=420,defaultHeight=286})
        L.RegisterStore(f.storeId,f.storeId,function()return {widgetWindow={locked=false}}end,function()return Copy(f.State)end,function(v)f.State=Copy(v)end,function(v)return Copy(v)end)
        assert(L.LoadStore(f));return f
    end
    local h=Boot();local f=Life(h);assert(f:SetWidgetWindowState({locked=true}));local writes,reads=h.diskWrites,h.reads
    assert(f:MarkStoreDirty(250,'widget_locked'));assert(h.diskWrites>writes and h.reads>reads)
    local cold=Boot(h.disk);local fresh=Life(cold);Eq(fresh:GetWidgetWindowState().locked,true)
    assert(fresh:SetWidgetWindowState({locked=false}));assert(fresh:MarkStoreDirty(250,'widget_lock'))
    local again=Boot(cold.disk);Eq(Life(again):GetWidgetWindowState().locked,false)
    for _,row in ipairs(appearances)do
        local h=Boot();local f=Life(h);local candidate=f:GetWidgetWindowState();candidate[row[2]]=row[3]
        assert(f:SetWidgetWindowState(candidate));assert(f:MarkStoreDirty(250,'widget_'..row[4]))
        local cold=Boot(h.disk);Eq(Life(cold):GetWidgetWindowState()[row[2]],row[3])
    end
end)
print(string.format('FLOATING RELOG RESULT %d passed / %d failed (%s)',pass,fail,_VERSION))
assert(fail==0,'floating relog failures: '..fail)
