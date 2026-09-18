-- 中文维护：真实 RSUI 布局、选择模型、按钮、EventBus、Store 与 Boss Feature；
-- 只替换 Native、磁盘和 HUD Presenter。禁止加入 toc.g；几何模拟不等于 RU 实机验收。
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; print('PASS boss-ui ' .. name)
    else failed = failed + 1; print('FAIL boss-ui ' .. name .. ': ' .. tostring(err)) end
end
local Base = dofile('tools/rs_gear_page_test_host.lua')
local function Boot(width, height, initiallyDisabled)
    local h = Base({width = width or 820, height = height or 680})
    assert(h.page:OnDeactivated())
    local S = h.S
    dofile('core/rs_demand.lua')
    X2Unit.UnitCastingInfo = function() return nil end
    X2Unit.UnitDeBuffCount = function() return 0 end
    dofile('services/rs_casting_observation_v3.lua')
    dofile('services/rs_aura_observation_v3.lua')
    dofile('services/rs_alerts_service.lua')
    local A = S.Services.Alerts
    h.shows = {}
    A:SetPresenter({Show = function(_, text) h.shows[#h.shows + 1] = text; return true end,
        UpdateText = function() return true end, Hide = function() return true end})
    assert(A:Start())
    dofile('data/rs_boss_alerts.lua'); dofile('features/rs_feature_registry.lua')
    dofile('features/rs_business_bridge.lua')
    local F = S.Features.combat_boss_alerts
    assert(F:Initialize()); if not initiallyDisabled then assert(F:Enable()) end; h.F = F
    S.FeatureRuntime.IsEnabled = function(_, id) return id == F.Id and F.enabled end
    S.FeatureRuntime.SetPreferredEnabled = function(_, id, enabled)
        assert(id == F.Id); if enabled then return F:Enable() else return F:Disable() end
    end
    dofile('ui/framework/rs_ui_numeric_range_store.lua'); dofile('ui/framework/rs_ui_forms.lua')
    dofile('presentation/v3/pages/rs_v3_business_pages.lua')
    local external = h.Native(nil, 'boss_external', 0, 0, width or 820, height or 680)
    local root, err = S.UIV3.PageHost.factories['combat.boss_alerts'](external, 'combat.boss_alerts')
    assert(root, err); h.page = root; h.widgets = {}
    local function Index(n)
        h.widgets[n.id] = n
        for _, child in ipairs(n.children or {}) do Index(child) end
    end
    function h:Layout(w, ht)
        external.width = w or external.width; external.height = ht or external.height
        root:Layout(0, 0, external.width, external.height); Index(root)
    end
    function h:Control(suffix) return assert(self.widgets['v3_business_combat_boss_alerts_' .. suffix], 'missing ' .. suffix) end
    function h:Action(suffix) return self:Click('v3_business_combat_boss_alerts_' .. suffix) end
    function h:Row(key)
        for i, row in ipairs(F:GetProjection().rows) do if row.mechanicKey == key then return row, i end end
        error('missing row ' .. key)
    end
    function h:Select(key)
        local _, index = self:Row(key); root.tableView:SetSelectedIndex(index)
    end
    assert(root:OnActivated()); h:Layout(); h.initialWrites = h.writes
    return h
end
Test('rule table is selectable with three meaningful columns', function()
    local h = Boot(); local t = h.page.tableView
    assert(t:GetItemCount() == 5 and #t:GetColumns() == 3, 'wrong rule columns')
    h:Select('ghost_hit'); assert(t:GetSelectedKey() == 'boss:ghost_hit', 'unstable index identity')
    assert(h:Control('rule_toggle').enabled and h:Control('rule_test').enabled)
end)
Test('one native click toggles the selected identity once through durable save', function()
    local h = Boot(); h:Select('ghost_hit'); h:Action('rule_toggle')
    assert(h:Row('ghost_hit').enabled == false and h:Row('smash_earth').enabled == true)
    assert(h.writes == h.initialWrites + 1, 'button did not perform exactly one durable write')
    assert(h:Control('rule_toggle').text == '启用选中规则')
    assert(h:Control('rule_test').enabled == false)
    assert(h:Control('test_status').text:find('保存', 1, true))
end)
Test('selection remains attached to key across a fresh reordered projection', function()
    local h = Boot(); h:Select('ghost_hit')
    local rows = h.F.Authority.rows; rows[1], rows[4] = rows[4], rows[1]
    h.F.Authority.revision = h.F.Authority.revision + 1; h.page:Refresh()
    assert(h.page.tableView:GetSelectedKey() == 'boss:ghost_hit')
    h:Action('rule_toggle'); assert(h:Row('ghost_hit').enabled == false and h:Row('smash_earth').enabled == true)
end)
Test('bulk controls save once and update rule count without re-opening page', function()
    local h = Boot(); h:Action('rules_off')
    assert(h.F:GetProjection().enabledRuleCount == 0 and h.writes == h.initialWrites + 1)
    assert(h:Control('rule_summary').text:find('0/5', 1, true))
    h:Action('rules_on'); assert(h.F:GetProjection().enabledRuleCount == 5 and h.writes == h.initialWrites + 2)
end)
Test('selected-rule test uses actual rule and never writes settings', function()
    local h = Boot(); h:Select('underwater'); h:Action('rule_test')
    assert(h.shows[#h.shows] == '下水！' and h.writes == h.initialWrites)
end)
Test('failed save keeps the previous rule and actionable error visible', function()
    local h = Boot(); h:Select('ghost_hit'); h.failSave = true; h:Action('rule_toggle')
    assert(h:Row('ghost_hit').enabled == true)
    assert(h:Control('test_status').text:find('失败', 1, true), 'failure hidden by refresh')
    assert(h:Control('rule_toggle').text == '关闭选中规则')
end)
Test('closing and reactivating page preserves runtime lease without duplicate writes', function()
    local h = Boot(); assert(h.F.consumerCount == 2)
    assert(h.page:OnDeactivated()); assert(h.F.consumerCount == 1 and h.F:GetProjection().realtime)
    assert(h.page:OnActivated()); assert(h.page:OnActivated()); assert(h.F.consumerCount == 2)
    h:Select('ghost_hit'); h:Action('rule_toggle'); assert(h.writes == h.initialWrites + 1)
end)
Test('feature off keeps static rules manageable and runtime polling stopped', function()
    local h = Boot(); h:Action('toggle'); assert(h.F.enabled == false)
    assert(h.page.tableView:GetViewState() == 'ready', 'disabled feature hides configuration')
    h:Select('underwater'); h:Action('rule_toggle')
    assert(h:Row('underwater').enabled == false and h.F:GetProjection().realtime == false)
    assert(h:Control('rule_test').enabled == false)
end)
Test('first open while disabled still shows all configurable static rules', function()
    local h = Boot(820, 680, true)
    assert(h.page.tableView:GetItemCount() == 5 and h.F.consumerCount == 0, 'disabled initial page lost static catalog')
    h:Select('ghost_hit'); h:Action('rule_toggle')
    assert(h:Row('ghost_hit').enabled == false and h.F:GetProjection().realtime == false)
end)
Test('native HUD toggle stops observation and failed retry preserves saved state', function()
    local h = Boot(); h:Action('hud_enabled')
    assert(h.F:GetProjection().hudEnabled == false and h.F:GetProjection().realtime == false)
    assert(h.writes == h.initialWrites + 1)
    h.failSave = true; h:Action('hud_enabled')
    assert(h.F:GetProjection().hudEnabled == false)
    assert(h:Control('test_status').text:find('失败', 1, true))
end)
Test('clearing selection disables selected actions', function()
    local h = Boot(); h:Select('ghost_hit'); h.page.tableView:ClearSelection()
    assert(h:Control('rule_toggle').enabled == false and h:Control('rule_test').enabled == false)
end)
Test('controls have usable unclipped native geometry at narrow and wide page widths', function()
    local h = Boot(820, 1000)
    for _, w in ipairs({480, 600, 820, 1080}) do
        h:Layout(w, 1000)
        for _, suffix in ipairs({'hud_enabled','hud_anchor','test_big','test_countdown','sim_cast','sim_debuff','hud_edit','hud_reset','observed_casts','rule_toggle','rule_test','rules_on','rules_off'}) do
            local c = h:Control(suffix); local ok, why = h:VisibleRect(c)
            assert(ok, suffix .. ': ' .. tostring(why))
            assert(c.root.width >= 100 and c.root.height >= 22, suffix .. ': tiny button')
        end
    end
end)
Test('refreshing and laying out page never writes persistent settings', function()
    local h = Boot(); local writes = h.writes
    for i = 1, 10 do h.page:Refresh(); h:Layout(600 + i * 10, 680) end
    assert(h.writes == writes)
end)
-- 中文维护（boss-hud-clock-1）：新增控件走真实 RSUI 点击/Commands，避免只测试不存在的虚拟按钮。
Test('observed-cast toggle saves and controls independent observation demand',function()
    local h=Boot();h:Action('observed_casts');assert(h.F:GetProjection().showObservedCasts and h.writes==h.initialWrites+1)
    h:Action('rules_off');assert(h.F:GetProjection().realtime,'generic observations should retain their own demand')
    h:Action('observed_casts');assert(not h.F:GetProjection().realtime)
end)
Test('leaving page ends edit mode without stopping boss observations',function()
    local h=Boot();local edits={};local A=h.S.Services.Alerts
    A.presenter.EditLayout=function(_,on)edits[#edits+1]=on;return true end
    h:Action('hud_edit');assert(h.F:GetProjection().hudEditing)
    h.page:OnDeactivated();assert(not h.F:GetProjection().hudEditing and edits[#edits]==false)
    assert(h.F:GetProjection().realtime and h.writes==h.initialWrites)
end)
Test('signed coordinate controls apply independently and retain rule selection',function()
    local h=Boot();h:Select('ghost_hit')
    assert(h:Control('offset_x'):Apply(-80,'test'));assert(h:Control('offset_y'):Apply(40,'test'));assert(h:Control('width'):Apply(600,'test'))
    local p=h.F:GetProjection();assert(p.hudOffsetX==-80 and p.hudOffsetY==40 and p.hudWidth==600)
    assert(h.page.tableView:GetSelectedKey()=='boss:ghost_hit')
    assert(h:Control('offset_x').apply and h:Control('offset_y').apply and h:Control('width').apply)
end)
print('BOSS UI RESULTS: ' .. passed .. ' passed / ' .. failed .. ' failed (runtime=' .. _VERSION .. ')')
assert(failed == 0, tostring(failed) .. ' boss UI regression(s)')
