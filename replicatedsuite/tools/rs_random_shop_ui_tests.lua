-- 开发期：真实RSUI/NumericField/TableView/Events/Store；Native几何、点击与磁盘来自既有夹具。
-- 必测慢输入不被轮询覆盖、读写拒绝可见、页面生命周期；不等于RU渲染和聊天焦点验收。
local Base=dofile('tools/rs_gear_page_test_host.lua')
local passed,failed=0,0
local function Test(name,fn)local ok,err=pcall(fn);if ok then passed=passed+1;print('PASS shop-ui '..name)else failed=failed+1;print('FAIL shop-ui '..name..': '..tostring(err))end end
local function Boot(w,ht,disabled,broken)
    local h=Base({width=w or 820,height=ht or 760});assert(h.page:OnDeactivated());local S=h.S
    dofile('core/rs_demand.lua');h.value,h.countReads=4,0
    X2Store={GetRandomShopStoreRefreshCount=function()h.countReads=h.countReads+1;return h.value end}
    dofile('features/tools/random_shop/rs_random_shop_authority.lua');dofile('features/tools/random_shop/rs_random_shop_feature.lua')
    local F=S.Features.RandomShop;h.F=F;assert(F:Initialize());if not disabled then assert(F:Enable())end
    S.FeatureRuntime.IsEnabled=function(_,id)return id==F.Id and F.enabled end
    S.FeatureRuntime.SetPreferredEnabled=function(_,id,v)assert(id==F.Id);local ok,err;if v then ok,err=F:Enable()else ok,err=F:Disable()end
        if ok then S.Events:Publish('v3.feature.lifecycle',id,v and 'enabled' or 'disabled','test')end;return ok,err end
    if broken then F.EnsureStoreLoaded=function()return false,'synthetic protected store'end end
    dofile('ui/framework/rs_ui_forms.lua');dofile('presentation/v3/pages/rs_v3_random_shop_page.lua')
    local ext=h.Native(nil,'shop_external',0,0,w or 820,ht or 760);h.external=ext
    local p,err=S.UIV3.PageHost.factories['tools.random_shop'](ext,'tools.random_shop');assert(p,err);h.page=p;h.widgets={}
    local function Index(n)h.widgets[n.id]=n;for _,child in ipairs(n.children or {})do Index(child)end end
    function h:Layout(width,height)ext.width=width or ext.width;ext.height=height or ext.height;p:Layout(0,0,ext.width,ext.height);Index(p)end
    function h:Control(s)return assert(self.widgets['v3_random_shop_'..s],'missing '..s)end
    function h:Action(s)return self:Click('v3_random_shop_'..s)end
    function h:Draft(n)return self:Type('v3_random_shop_threshold_input',tostring(n))end
    assert(p:OnActivated());h:Layout();h.initialWrites=h.writes;return h
end
Test('page exposes a separate bounded three-column observation history',function()
    local h=Boot();assert(h.page.tableView and #h.page.tableView:GetColumns()==3 and h.page.tableView:GetItemCount()==1)
end)
Test('manual read is explicitly distinguished from refreshing the game shop',function()
    local h=Boot();assert(h:Control('header_action').text=='读取计数');local r=h.countReads;h:Action('header_action');assert(h.countReads==r+1)
end)
Test('apply button durably saves threshold without requiring Enter',function()
    local h=Boot();h:Draft(8);h:Action('threshold_apply');assert(h.F:GetProjection().threshold==8 and h.writes==h.initialWrites+1)
    assert(h:Control('action_status').text:find('保存',1,true))
end)
Test('multiple polls preserve an active draft until Apply',function()
    local h=Boot();h:Action('auto_read');local input=h:Draft(17)
    for i=1,5 do h.value=10+i;h.ms=h.ms+1000;h.S.Scheduler:RunTask('v3_random_shop_observe')end
    assert(input.root.text=='17' and h.F:GetProjection().threshold==0);h:Action('threshold_apply');assert(h.F:GetProjection().threshold==17)
end)
Test('failed save receipt survives later poll and render',function()
    local h=Boot();h:Action('auto_read');h.failSave=true;h:Draft(18);h:Action('threshold_apply');h.value=20;h.F.Commands:Refresh()
    assert(h.F:GetProjection().threshold==0 and h:Control('action_status').text:find('失败',1,true))
end)
Test('disabled page permits editing settings without touching game data',function()
    local h=Boot(820,760,true);h:Draft(12);h:Action('threshold_apply');h:Action('auto_read')
    assert(h.F:GetProjection().threshold==12 and h.countReads==0 and h.F.consumerCount==0 and not h:Control('header_action').enabled)
end)
Test('unknown is displayed rather than a zero count',function()
    local h=Boot();h.value=nil;h.F.Commands:Refresh();assert(h:Control('card_value').text=='未知')
end)
Test('baseline reset does not read or persist',function()
    local h=Boot();h.value=9;h.F.Commands:Refresh();local r,w=h.countReads,h.writes;h:Action('reset_baseline')
    assert(h.F:GetProjection().baseline==9 and h.countReads==r and h.writes==w)
end)
Test('auto toggle creates a single shared observer',function()
    local h=Boot();h:Action('auto_read');assert(h.S.Scheduler.tasks.v3_random_shop_observe and h.F.consumerCount==1)
    h:Action('auto_read');assert(h.S.Scheduler.tasks.v3_random_shop_observe==nil and h.F.consumerCount==1)
end)
Test('repeated activation neither rereads nor duplicates subscriptions',function()
    local h=Boot();local r=h.countReads;assert(h.page:OnActivated());assert(h.page:OnActivated())
    assert(h.countReads==r and h.F.consumerCount==1 and #h.S.Events.internalListeners[h.F.UpdateTopic]==1)
end)
Test('page hide releases task and internal subscriptions',function()
    local h=Boot();h:Action('auto_read');assert(h.page:OnDeactivated());assert(h.F.consumerCount==0 and h.S.Scheduler.tasks.v3_random_shop_observe==nil)
    assert(h.S.Events.internalListeners[h.F.UpdateTopic]==nil and h.F:GetProjection().threshold==0)
end)
Test('release of an active page is also a teardown boundary',function()
    local h=Boot();h:Action('auto_read');h.page:Release();assert(h.F.consumerCount==0 and h.S.Scheduler.tasks.v3_random_shop_observe==nil)
end)
Test('lifecycle updates from another page clear stale consumer flags',function()
    local h=Boot();assert(h.S.FeatureRuntime:SetPreferredEnabled(h.F.Id,false));assert(not h.page.consumerHeld)
    assert(h.S.FeatureRuntime:SetPreferredEnabled(h.F.Id,true));assert(h.page.consumerHeld and h.F.consumerCount==1)
end)
Test('closed page is not resurrected by external reenable',function()
    local h=Boot();assert(h.page:OnDeactivated());h.S.FeatureRuntime:SetPreferredEnabled(h.F.Id,false);h.S.FeatureRuntime:SetPreferredEnabled(h.F.Id,true)
    assert(h.F.consumerCount==0 and h.S.Scheduler.tasks.v3_random_shop_observe==nil)
end)
Test('protected store builds a read-only page without bindings or native reads',function()
    local h=Boot(820,760,true,true);assert(h.page.persistenceUnavailable and h.widgets.v3_random_shop_threshold_input==nil)
    assert(h.countReads==0 and h.writes==h.initialWrites and h.F.consumerCount==0)
end)
Test('projection refresh and relayout never read or save',function()
    local h=Boot();local r,w=h.countReads,h.writes;for i=1,10 do h.page:Refresh();h:Layout(600+i*10,760)end
    assert(h.countReads==r and h.writes==w)
end)
Test('control geometry is usable at narrow and wide widths',function()
    local h=Boot(820,1000);for _,w in ipairs({420,480,600,820,1080})do h:Layout(w,1000)
        for _,s in ipairs({'header_action','toggle','auto_read','reset_baseline','threshold_input','threshold_apply'})do
            local c=h:Control(s);local ok,why=h:VisibleRect(c);assert(ok,s..': '..tostring(why));assert(c.root.width>=34 and c.root.height>=20)
        end
    end
end)
Test('page marks personal threshold reached without posting to chat or HUD',function()
    local h=Boot();h:Draft(4);h:Action('threshold_apply');assert(h:Control('reminder').text:find('达到',1,true))
    assert(h.S.Services.Alerts==nil)
end)
-- 维护：复查页面缓存交叠、窄页滚动、输入提交与订阅失败，避免只验证理想单页路径。
Test('duplicate page construction is fenced without stealing the existing lease',function()
    -- 维护：真实RSUI同Generation禁止复用逻辑ID；不要清空该防护去伪造两个同路由实例。
    -- Demand多Consumer单独在核心组验证；这里检查构建拒绝不能撤销当前页面的需求。
    local h=Boot();h:Action('auto_read')
    local other,err=h.S.UIV3.PageHost.factories['tools.random_shop'](h.external,'tools.random_shop')
    assert(other==nil and tostring(err):find('logical_id_already_consumed',1,true))
    assert(h.F.consumerCount==1 and h.page.consumerHeld and h.S.Scheduler.tasks.v3_random_shop_observe)
    local n=h.countReads;h.value=10;h.F.Commands:Refresh();assert(h.countReads==n+1)
    h.page:Release();assert(h.F.consumerCount==0 and h.S.Scheduler.tasks.v3_random_shop_observe==nil)
end)
Test('failed second internal subscription rolls back first and creates no demand',function()
    local h=Boot();assert(h.page:OnDeactivated());local subscribe=h.S.Events.SubscribeInternal
    h.S.Events.SubscribeInternal=function(self,topic,owner,cb)
        if topic=='v3.feature.lifecycle' then return false,'synthetic subscription failure' end
        return subscribe(self,topic,owner,cb)
    end
    local ok=h.page:OnActivated();assert(ok==false and h.F.consumerCount==0 and not h.page._shopActive)
    assert(h.S.Events.internalListeners[h.F.UpdateTopic]==nil and h.S.Scheduler.tasks.v3_random_shop_observe==nil)
end)
Test('short viewport scrolls to lower content without native reads or saves',function()
    local h=Boot(420,300);assert(h.page:GetMaxOffset()>0);local r,w=h.countReads,h.writes
    h.page:ScrollToBottom();local ok,why=h:VisibleRect(h:Control('limits'));assert(ok,why)
    h.page:EnsureChildVisible(h:Control('actions'));ok,why=h:VisibleRect(h:Control('header_action'));assert(ok,why)
    assert(h.countReads==r and h.writes==w)
end)
Test('loss of focus followed by Apply does not double-save',function()
    local h=Boot();local c=h:Draft(16)
    if c.root.events.OnLeave then c.root.events.OnLeave(c.root) end
    assert(c:CommitAndEndEditing('lost_focus_model'));local n=h.writes
    h:Action('threshold_apply');assert(h.F:GetProjection().threshold==16 and h.writes==n)
end)
Test('history updates do not jump a scrolled page to the top',function()
    local h=Boot(420,300);h.page:ScrollToBottom();local offset=h.page.scrollOffset
    h.value=8;h.F.Commands:Refresh();h:Layout(420,300);assert(h.page.scrollOffset==offset)
end)
print('RANDOM SHOP UI RESULTS: '..passed..' passed / '..failed..' failed (runtime='.._VERSION..')')
assert(failed==0,tostring(failed)..' random shop UI regressions')
