-- 真实死亡回顾 Page/WidgetHost/Widget/Windowing/Shell/Surface/Layout；仅控件叶节点和存档边界采用模型。
local NewHost = dofile('tools/rs_window_viewport_test_host.lua')
local function Copy(t)
    if type(t) ~= 'table' then return t end
    local result = {}; for k,v in pairs(t) do result[k] = Copy(v) end; return result
end
local function Eq(a,b) assert(math.abs(a-b)<0.001, tostring(a)..' ~= '..tostring(b)) end
local function Boot(saved, realPersistence)
    local h = NewHost()
    local s, r = h.S, h.S.RSUI
    local nodes = {}
    for _, name in ipairs({'Overlay','Border','HorizontalBox','VerticalBox','Text','Button'}) do
        local create = r[name]
        r[name] = function(self, spec)
            local c = create(self, spec); nodes[spec.id] = c
            function c:SetVisible(v) return self:SetVisibility(v and 'visible' or 'collapsed') end
            function c:SetEnabled(v) self.enabled = v; return self end
            function c:Render() return true end
            function c:SetItems() end
            function c:SetViewState() end
            function c:ClearSelection() end
            function c:SetSelectedIndex() end
            return c
        end
    end
    r.TableView = r.VerticalBox; r.Toggle = r.Button; r.Dropdown = r.Button
    function r:WithBuildScope(_, fn) return true, fn() end
    s.Utils = { DeepCopy = Copy }
    s.UIV3Design = {
        PageRoot = function(_, p, id) return r:VerticalBox({parent=p,id=id}) end,
        PageHeader = function() end,
        ModuleToggleButton = function(_, spec) return r:Button(spec) end,
        NumericSetting = function(_, p, spec) spec.parent=p; return r:Button(spec) end,
    }
    s.FeatureRuntime = { IsEnabled = function() return h.enabled ~= false end }
    s.Features = { DeathReview = { State = {widgetWindow = Copy(saved or {width=470,height=330,locked=true,minimized=true})}, Commands={} } }
    local f = s.Features.DeathReview
    function f:EnsureStoreLoaded() return true end
    function f:GetWidgetWindowState() return Copy(self.State.widgetWindow) end
    function f:GetSettingsProjection() return {autoShow=true,showDebuffs=false,windowMs=10000,minDamage=0,maxHistory=10} end
    function f:GetProjection() return {enabled=h.enabled~=false,health={},historyRows={},timelineRows={}} end
    function f.Commands:SetWidgetWindowState(state) f.State.widgetWindow=Copy(state);return true end
    function f.Commands:MarkStoreDirty()
        h.writes=h.writes+1; h.saved=Copy(f.State.widgetWindow); return true
    end
    if realPersistence then
        h.disk = {}
        ADDON = { LoadData = function(_, key) return Copy(h.disk[key]) end,
            SaveData = function(_, key, value) h.writes=h.writes+1; h.disk[key]=Copy(value); return true end }
        s.NowMs = function() return 5000 end
        dofile('core/rs_utils.lua'); dofile('core/rs_reuse.lua'); dofile('core/rs_demand.lua')
        dofile('core/rs_api_capabilities.lua'); dofile('core/rs_persistence_transport.lua'); dofile('core/rs_persistence.lua')
        dofile('features/combat/death_review/rs_death_review_store.lua')
        assert(f:EnsureStoreLoaded())
        function f.Commands:MarkStoreDirty(delay, reason) return f:MarkStoreDirty(delay, reason) end
    end
    dofile('core/rs_events.lua')
    s.UIV3 = {PageHost={RegisterFactory=function(_, _, fn) h.build=fn; return true end}}
    dofile('presentation/v3/widgets/rs_v3_widget_host.lua')
    dofile('presentation/v3/widgets/rs_v3_death_review_content.lua')
    dofile('presentation/v3/widgets/rs_v3_death_review_widget.lua')
    dofile('presentation/v3/pages/rs_v3_death_review_page.lua')
    h.page=assert(h.build(UIParent,'combat.death_review')); assert(h.page:OnActivated())
    h.nodes, h.f, h.host = nodes, f, s.UIV3.WidgetHost
    function h:Click(id) return assert(self.nodes[id], 'missing layout entry: '..id).spec.onClick() end
    function h:OpenLayout() return self:Click('v3_death_review_layout_toggle') end
    return h
end

local passed=0
local function Test(name,fn) fn();passed=passed+1;print('PASS death-layout '..name) end
Test('page layout entry opens an empty preview and removes lock and minimization',function()
    local h=Boot();assert(h:OpenLayout())
    local w=assert(h.host:GetInstance('combat.death_review'))
    assert(h.host:IsVisible('combat.death_review') and not w:IsLocked() and not w:IsMinimized())
    assert(h.nodes.v3_death_review_layout_controls.visibility=='visible')
end)
Test('title drag commits location and the next preview restores it',function()
    local h=Boot();assert(h:OpenLayout());local w=h.host:GetInstance('combat.death_review')
    local c=w.windowController;assert(c:BeginInteraction('drag'))
    w.window.x,w.window.y=320,240;c:EndInteraction();assert(c:CommitGeometry('drag'))
    Eq(h.f.State.widgetWindow.x,320);Eq(h.f.State.widgetWindow.y,240)
    local nextHost=Boot(h.saved);assert(nextHost:OpenLayout());local nextWindow=nextHost.host:GetInstance('combat.death_review').window
    Eq(nextWindow.x,320);Eq(nextWindow.y,240)
end)
Test('width and height fields resize the same death window',function()
    local h=Boot();assert(h:OpenLayout())
    assert(h.nodes.v3_death_review_widget_width.spec.set(620))
    assert(h.nodes.v3_death_review_widget_height.spec.set(420))
    local w=h.host:GetInstance('combat.death_review')
    Eq(h.f.State.widgetWindow.width,620);Eq(h.f.State.widgetWindow.height,420)
    Eq(w.window.w,620);Eq(w.window.h,420)
end)
Test('native corner resizing updates the stored preferred size',function()
    local h=Boot();assert(h:OpenLayout());local w=h.host:GetInstance('combat.death_review')
    local c=w.windowController;assert(c:BeginInteraction('resize'))
    w.window.w,w.window.h=640,440;c:EndInteraction();assert(c:CommitGeometry('resize'))
    Eq(h.f.State.widgetWindow.width,640);Eq(h.f.State.widgetWindow.height,440)
end)
Test('locking and restoring layout use the existing death window',function()
    local h=Boot();assert(h:OpenLayout())
    assert(h:Click('v3_death_review_widget_lock'));assert(h.host:GetInstance('combat.death_review'):IsLocked())
    assert(h:Click('v3_death_review_widget_reset'))
    Eq(h.f.State.widgetWindow.width,470);Eq(h.f.State.widgetWindow.height,330)
    assert(h.host.stats.creates==1)
end)
Test('rejected native size leaves prior window state intact',function()
    local h=Boot();assert(h:OpenLayout());local before=Copy(h.f.State.widgetWindow)
    h.rejectExtent=true
    assert(h.nodes.v3_death_review_widget_width.spec.set(620)==false)
    Eq(h.f.State.widgetWindow.width,before.width);Eq(h.f.State.widgetWindow.height,before.height)
end)
Test('real DeathReview Store and Persistence roundtrip keeps custom size and position',function()
    local h=Boot(nil,true);assert(h:OpenLayout())
    assert(h.nodes.v3_death_review_widget_width.spec.set(620))
    assert(h.nodes.v3_death_review_widget_height.spec.set(420))
    local w=h.host:GetInstance('combat.death_review');local c=w.windowController
    assert(c:BeginInteraction('drag'));w.window.x,w.window.y=320,240
    c:EndInteraction();assert(c:CommitGeometry('drag'))
    local p=h.S.Persistence
    assert(p:SaveStore(h.f.StoreId,{durable=true,consumeDirty=true}))
    p:GetStore(h.f.StoreId).loaded=false;h.f.State.widgetWindow=nil
    assert(h.f:EnsureStoreLoaded())
    local state=h.f:GetWidgetWindowState()
    Eq(state.x,320);Eq(state.y,240);Eq(state.width,620);Eq(state.height,420)
    assert(h.writes>0 and next(h.disk)~=nil)
end)
Test('tiny historical sizes render at the usable runtime minimum without changing index canonical',function()
    local h=Boot({width=240,height=180,locked=true,minimized=false});assert(h:OpenLayout())
    local w=assert(h.host:GetInstance('combat.death_review'))
    assert(w.window.w>=420 and w.window.h>=300,'status lists have no row viewport')
    assert(h.nodes.v3_death_review_widget_width.spec.min==420 and h.nodes.v3_death_review_widget_height.spec.min==300)
end)
print('DEATH_REVIEW_LAYOUT PASS: '..passed..' cases (Native and storage boundaries modeled)')
