-- 中文维护：使用真实 Authority、Events、WidgetHost 和死亡窗口；仅替代存档与原生绘制边界。
local passed = 0
local function Test(name, fn)
    fn()
    passed = passed + 1
    print('PASS: ' .. name)
end

local function Boot()
    local h = { enabled = true, autoShow = true, showAccepted = true, warnings = {}, records = {} }
    local settings = { autoShow = true, showDebuffs = false, windowMs = 10000, maxHistory = 10, minDamage = 0 }
    local f = { enabled = true, State = { history = { serial = 0, entries = {} } }, Commands = {} }
    ReplicatedSuite = { Generation = 1, SafeTraceback = debug.traceback, Features = { DeathReview = f },
        Services = {}, RSUI = {}, UIV3 = {}, NowMs = function() return 5000 end }
    local s = ReplicatedSuite
    s.FeatureRuntime = { IsEnabled = function() return h.enabled end }
    s.DiagnosticsManager = {
        WarningRateLimited = function(_, _, code) h.warnings[#h.warnings + 1] = code end,
        Error = function() end,
    }
    function f:GetSettings() settings.autoShow = h.autoShow; return settings end
    function f:GetSettingsProjection() return self:GetSettings() end
    function f:EnsureStoreLoaded() return true end
    function f:GetWidgetWindowState() return {} end
    function f:CommitDeathRecord(record)
        self.State.history.serial = record.serial
        h.records[#h.records + 1] = record
        return true, record
    end
    function f:GetProjection() return { timelineRows = {}, record = h.records[#h.records] } end
    function f.Commands:MarkStoreDirty() return true end
    function f.Commands:SetWidgetWindowState() return true end
    local rsui = s.RSUI
    function rsui:WithBuildScope(_, fn) return true, fn() end
    function rsui:VerticalBox() return {} end
    rsui.HorizontalBox = rsui.VerticalBox
    function rsui:Text(spec)
        return { text = spec.text, SetText = function(self, value) self.text = value end }
    end
    function rsui:TableView()
        return { SetItems = function() end, SetViewState = function() end }
    end
    rsui.FloatingSurface = {
        CreateStateAdapter = function() return {} end,
        Create = function()
            return { shell = { root = {} }, windowController = {}, GetContentRoot = function() return {} end,
                SetStatus = function() end,
                Show = function(self, visible)
                    if visible and not h.showAccepted then return false, 'native show rejected' end
                    self.visible = visible
                    return true
                end }
        end,
    }
    dofile('core/rs_events.lua')
    dofile('features/combat/death_review/rs_death_review_authority.lua')
    dofile('presentation/v3/widgets/rs_v3_widget_host.lua')
    dofile('presentation/v3/widgets/rs_v3_death_review_content.lua')
    dofile('presentation/v3/widgets/rs_v3_death_review_widget.lua')
    function h:Die() return f.Authority:FinalizeDeath(5000, 1) end
    return h, s, f, s.UIV3.WidgetHost
end

Test('death record automatically opens the real widget through owner/revision/reason event arguments', function()
    local h, s, f, host = Boot()
    h:Die()
    assert(host:IsVisible('combat.death_review'), 'death recorded but automatic window never opened')
    local widget = host:GetInstance('combat.death_review')
    assert(widget.visible and widget.surface.visible, 'widget display state did not follow death')
    assert(widget.summary.text:find('总伤害', 1, true), 'window did not render the death record')
    assert(s.LastInternalEventError == nil, 'death callback raised an error')
end)

Test('auto-show preference off still records death without opening a window', function()
    local h, s, f, host = Boot()
    h.autoShow = false
    h:Die()
    assert(f.Authority.deaths == 1 and #h.records == 1, 'preference disabled death recording')
    assert(not host:IsVisible('combat.death_review') and host:GetInstance('combat.death_review') == nil)
end)

Test('disabled feature does not auto-open on a late death update', function()
    local h, s, f, host = Boot()
    h.enabled = false
    s.Events:Publish('v3.death_review.updated', 7, 'death', { serial = 1 })
    assert(not host:IsVisible('combat.death_review'))
end)

Test('non-death record updates do not open the window', function()
    local h, s, f, host = Boot()
    s.Events:Publish('v3.death_review.updated', 7, 'delete', 1)
    s.Events:Publish('v3.death_review.updated', 8, 'clear', nil)
    assert(not host:IsVisible('combat.death_review'))
end)

Test('closing a death window does not prevent the next death from reopening it', function()
    local h, s, f, host = Boot()
    h:Die()
    assert(host:IsVisible('combat.death_review'), 'first death never opened')
    assert(host:SetVisible('combat.death_review', false, { persist = false }))
    h:Die()
    assert(host:IsVisible('combat.death_review'), 'next death did not reopen the closed window')
    assert(host.stats.creates == 1, 'next death rebuilt the existing window')
end)

Test('native show rejection remains hidden and reports auto-show failure', function()
    local h, s, f, host = Boot()
    h.showAccepted = false
    h:Die()
    assert(not host:IsVisible('combat.death_review'))
    assert(h.warnings[1] == 'DEATH_REVIEW_AUTO_SHOW_FAILED', 'auto-show rejection was swallowed')
end)

print('DEATH_REVIEW_AUTO_SHOW PASS: ' .. passed .. ' cases (Native display modeled)')
