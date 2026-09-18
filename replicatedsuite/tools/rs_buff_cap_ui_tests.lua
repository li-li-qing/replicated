-- 中文维护：真实RSUI表单/布局/按钮/总线/Store+Feature；Native绘制、焦点和物理存档为替身。
-- 覆盖无需Enter的应用操作、观察刷新不盖输入、保存拒绝回执与窄屏。不是RU实机验收。
local Base = dofile('tools/rs_gear_page_test_host.lua')
local passed, failed = 0, 0
local function Test(name,fn)
    local ok,err=pcall(fn)
    if ok then passed=passed+1;print('PASS buff-cap-ui '..name)
    else failed=failed+1;print('FAIL buff-cap-ui '..name..': '..tostring(err)) end
end
local function Boot(w,ht,disabled,broken)
    local h=Base({width=w or 820,height=ht or 680});assert(h.page:OnDeactivated())
    local S=h.S;dofile('core/rs_demand.lua')
    h.normal,h.hidden,h.countReads,h.shows=4,2,0,{}
    X2Unit.UnitBuffCount=function()h.countReads=h.countReads+1;return h.normal end
    X2Unit.UnitHiddenBuffCount=function()h.countReads=h.countReads+1;return h.hidden end
    dofile('services/rs_alerts_service.lua')
    S.Services.Alerts:SetPresenter({Show=function(_,t)h.shows[#h.shows+1]=t;return true end,Hide=function()return true end})
    assert(S.Services.Alerts:Start())
    dofile('features/rs_feature_registry.lua');dofile('features/rs_business_bridge.lua')
    local F=S.Features.combat_buff_cap;h.F=F;assert(F:Initialize());if not disabled then assert(F:Enable()) end
    S.FeatureRuntime.IsEnabled=function(_,id)return id==F.Id and F.enabled end
    S.FeatureRuntime.SetPreferredEnabled=function(_,id,v)assert(id==F.Id);if v then return F:Enable() else return F:Disable() end end
    if broken then F.Initialize=function()return false,'synthetic protected store' end end
    dofile('ui/framework/rs_ui_forms.lua');dofile('presentation/v3/pages/rs_v3_business_pages.lua')
    local ext=h.Native(nil,'cap_external',0,0,w or 820,ht or 680)
    local root,err=S.UIV3.PageHost.factories['combat.buff_cap'](ext,'combat.buff_cap');assert(root,err);h.page=root;h.widgets={}
    local function Index(n)h.widgets[n.id]=n;for _,ch in ipairs(n.children or {})do Index(ch)end end
    function h:Layout(width,height)ext.width=width or ext.width;ext.height=height or ext.height;root:Layout(0,0,ext.width,ext.height);Index(root)end
    function h:Control(s)return assert(self.widgets['v3_business_combat_buff_cap_'..s],'missing '..s)end
    function h:Action(s)return self:Click('v3_business_combat_buff_cap_'..s)end
    function h:Draft(key,v)return self:Type('v3_business_combat_buff_cap_'..key..'_threshold_input',tostring(v))end
    function h:Apply(key,v)self:Draft(key,v);return self:Action(key..'_threshold_apply')end
    assert(root:OnActivated());h:Layout();h.initialWrites=h.writes
    return h
end
Test('table contains two independent count and peak rows without a cost column',function()
    local h=Boot();local t=h.page.tableView;assert(t:GetItemCount()==2 and #t:GetColumns()==4)
    for _,col in ipairs(t:GetColumns())do assert(col.id~='cost')end
    assert(h.F:GetProjection().rows[1].count==4)
end)
Test('explicit apply commits a typed threshold without Enter',function()
    local h=Boot();h:Apply('normal',8);assert(h.F:GetProjection().normalThreshold==8)
    assert(h.writes==h.initialWrites+1 and h:Control('action_status').text:find('保存',1,true))
end)
Test('observation refresh cannot overwrite an active numeric draft',function()
    local h=Boot();local input=h:Draft('normal',17)
    for i=1,3 do h.normal=10+i;h.F.Commands:Refresh('test') end
    assert(input.root.text=='17' and h.F:GetProjection().normalThreshold==0)
    h:Action('normal_threshold_apply');assert(h.F:GetProjection().normalThreshold==17)
end)
Test('focus loss before apply does not cause a duplicate durable write',function()
    local h=Boot();local c=h:Draft('hidden',6)
    if c.root.events.OnLeave then c.root.events.OnLeave(c.root) end
    assert(c:CommitAndEndEditing('lost_focus_model'));local n=h.writes
    h:Action('hidden_threshold_apply');assert(h.F:GetProjection().hiddenThreshold==6 and h.writes==n)
end)
Test('failed save rolls back value and stays visible through subsequent observations',function()
    local h=Boot();h.failSave=true;h:Apply('normal',18)
    assert(h.F:GetProjection().normalThreshold==0)
    h.F.Commands:Refresh('test');assert(h:Control('action_status').text:find('失败',1,true),'save error overwritten')
end)
Test('toggle acquires explicit background demand and click off removes only that demand',function()
    local h=Boot();h:Apply('normal',10);h:Action('reminder_enabled');assert(h.F.consumerCount==2)
    h:Action('reminder_enabled');assert(h.F.consumerCount==1 and h.F:GetProjection().reminderEnabled==false)
end)
Test('page close preserves reminder and repeated activation never duplicates ownership',function()
    local h=Boot();h:Apply('normal',10);h:Action('reminder_enabled');assert(h.page:OnDeactivated());assert(h.F.consumerCount==1)
    assert(h.page:OnActivated());assert(h.page:OnActivated());assert(h.F.consumerCount==2)
end)
Test('page close with reminders disabled fully stops sampling',function()
    local h=Boot();assert(h.page:OnDeactivated());assert(h.F.consumerCount==0 and h.S.Scheduler.tasks.v3_business_buff_cap_poll==nil)
end)
Test('disabled first-open still permits saving thresholds but refuses test alert',function()
    local h=Boot(820,680,true);h:Apply('normal',20);h:Action('reminder_enabled')
    assert(h.F:GetProjection().normalThreshold==20 and h.F:GetProjection().reminderEnabled==true)
    assert(h.countReads==0 and h.F.consumerCount==0 and h:Control('test_reminder').enabled==false)
end)
Test('manual test does not change readouts or persistent state',function()
    local h=Boot();local n,w=h.countReads,h.writes;h:Action('test_reminder')
    assert(#h.shows==1 and h.countReads==n and h.writes==w and h.F:GetProjection().delivered==0)
end)
Test('reset updates peak display without a save or Native read',function()
    local h=Boot();h.normal=12;h.F.Commands:Refresh('up');h.normal=3;h.F.Commands:Refresh('down')
    local n,w=h.countReads,h.writes;h:Action('reset_peaks');assert(h.F:GetProjection().rows[1].peak==3 and h.countReads==n and h.writes==w)
end)
Test('unavailable count is visible independently while the valid row updates',function()
    local h=Boot();h.hidden=nil;h.normal=9;h.F.Commands:Refresh('unknown');local p=h.F:GetProjection()
    assert(p.rows[1].count==9 and p.rows[2].count==nil and h.page.tableView:GetItemCount()==2)
end)
Test('protected store builds a read-only page without controls or acquisition',function()
    local h=Boot(820,680,true,true)
    assert(h.page.persistenceUnavailable==true and h.widgets.v3_business_combat_buff_cap_normal_threshold==nil)
    assert(h.F.consumerCount==0 and h.countReads==0 and h.writes==h.initialWrites)
end)
Test('controls are usable at narrow and wide page widths',function()
    local h=Boot(820,950)
    for _,w in ipairs({420,480,600,820,1080})do
        h:Layout(w,950)
        for _,suffix in ipairs({'reminder_enabled','test_reminder','reset_peaks','normal_threshold_input','normal_threshold_apply','hidden_threshold_input','hidden_threshold_apply'})do
            local c=h:Control(suffix);local ok,why=h:VisibleRect(c);assert(ok,suffix..': '..tostring(why))
            assert(c.root.width>=34 and c.root.height>=20,suffix..' tiny')
        end
    end
end)
Test('render and layout never read counts or save data',function()
    local h=Boot();local r,w=h.countReads,h.writes
    for i=1,10 do h.page:Refresh();h:Layout(600+i*10,680)end
    assert(h.countReads==r and h.writes==w)
end)

Test('protected page uses existing Shell navigation contract rather than an invented UIV3 method',function()
    local h=Boot(820,680,true,true);local captured=nil
    h.S.UIV3.Shell={Navigate=function(_,route,context)captured={route,context};return true end}
    assert(h.S.UIV3.Navigate==nil);h:Action('diagnostics')
    assert(captured and captured[1]=='system.diagnostics' and captured[2].source=='buff_cap_protected')
    assert(h.countReads==0 and h.F.consumerCount==0)
end)

print('BUFF CAP UI RESULTS: '..passed..' passed / '..failed..' failed (runtime='.._VERSION..')')
assert(failed==0,tostring(failed)..' buff capacity UI regressions')
