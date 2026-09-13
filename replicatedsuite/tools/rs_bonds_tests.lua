------------------------------------------------------------------------
-- Replicated Suite V3 - Bonds / Resident Board Test Suite
--
-- Tests Bonds Authority, board reading 1-7, empty/ready/unavailable state,
-- material counts (bagId 1/0), real quest progress (active index),
-- filtering/sorting, row selection, floating detail integration, and
-- v3_m1_bonds sequence case.
------------------------------------------------------------------------

unpack = unpack or table.unpack
if not math.frexp then math.frexp = function(x) if x == 0 then return 0, 0 end local e = math.floor(math.log(math.abs(x)) / math.log(2)) + 1 return x / (2^e), e end end
if not math.ldexp then math.ldexp = function(m, e) return m * (2^e) end end

local passed, total = 0, 0
local function Test(name, fn)
    total = total + 1
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        passed = passed + 1
        print(string.format("  PASS [%02d] %s", total, name))
    else
        print(string.format("  FAIL [%02d] %s: %s", total, name, tostring(err)))
    end
end

print("=== Replicated Suite: Bonds / Resident Board Tests ===")

local h = dofile("tools/rs_gear_page_test_host.lua")({})
local S = h.S
S.UI = S.UI or {}
S.UI.CreateWindowShell = function()
    return {
        SetTitle = function() end,
        SetFooter = function() end,
        SetMinSize = function() end,
        SetMaxSize = function() end,
        SetResizable = function() end,
        SetCloseHandler = function() end,
        SetMinimizeHandler = function() end,
        SetLockHandler = function() end,
        SetOpacity = function() end,
        SetMinimized = function() end,
        SetLocked = function() end,
        SetExtent = function() end,
        Show = function() end,
        Hide = function() end,
    }
end

dofile("core/rs_demand.lua")
dofile("ui/framework/rs_ui_floating_surface.lua")
dofile("data/rs_data_registry.lua")
dofile("data/ids/rs_item_ids.lua")
dofile("data/ids/rs_quest_ids.lua")
dofile("data/ids/rs_instance_ids.lua")
dofile("data/rs_event_data.lua")
dofile("data/rs_quest_data.lua")
dofile("core/rs_constants.lua")
dofile("core/rs_foundation_gate.lua")
dofile("features/rs_feature_registry.lua")
dofile("services/rs_quest_progress_v3.lua")
dofile("services/rs_inventory_snapshot_v3.lua")

-- Mock RSUI for widgets without wiping existing FloatingSurface
S.RSUI = S.RSUI or {}
S.RSUI.TableView = function(spec)
    local tv = { spec = spec, items = {}, viewState = "ready" }
    function tv:SetItems(items, rev) self.items = items or {}; self.rev = rev end
    function tv:SetViewState(state, info) self.viewState = state; self.viewInfo = info end
    function tv:GetItem(idx) return self.items[idx] end
    function tv:ScrollToTop() end
    return tv
end
S.RSUI.Button = function(spec)
    local btn = { spec = spec, enabled = true, text = spec.text or "" }
    function btn:SetText(t) self.text = t end
    function btn:SetEnabled(e) self.enabled = e end
    return btn
end
S.RSUI.Text = function(spec)
    local txt = { spec = spec, text = spec.text or "" }
    function txt:SetText(t) self.text = t end
    return txt
end
S.RSUI.Dropdown = function(spec)
    local dd = { spec = spec, items = spec.items or {} }
    function dd:SetItems(it) self.items = it or {} end
    return dd
end
S.RSUI.VerticalBox = function() return {} end
S.RSUI.HorizontalBox = function() return {} end
S.RSUI.Border = function() return {} end
S.RSUI.WithBuildScope = function(_, fn) return fn() end

-- Mock UI Hosts
S.UIV3 = S.UIV3 or {}
S.UIV3.PageHost = { factories = { ["life.bonds"] = function() return {} end } }
S.UIV3.WidgetHost = {
    specs = {},
    Register = function(self, id, spec) self.specs[id] = spec; return true end,
    BindFeatureLifecycle = function(self, id, binding) end,
    GetSpec = function(self, id) return self.specs[id] end,
    IsVisible = function() return false end,
    SetVisible = function() return true end,
}
S.UIV3.AuxWindowStoreV3 = {
    EnsureLoaded = function() return true end,
    GetPolicy = function() return {} end,
    GetWindowState = function() return {} end,
    SetWindowState = function() return true end,
    PersistWindow = function() return true end,
}

-- Mock QuestDetailFloatingV3
local openedFloating = nil
S.UIV3.QuestDetailFloatingV3 = {
    Open = function(self, scope, key, sourceRow)
        openedFloating = { scope = scope, key = key, sourceRow = sourceRow }
        return true
    end,
}

-- Ensure FeatureRuntime mock handles implementation checks
S.FeatureRuntime.IsImplemented = function(_, id) return true end
S.FeatureRuntime.IsEnabled = function(_, id) return true end

-- Helper functions to update mock API objects while keeping UnitNameWithWorld intact
local function SetMockUnit(opts)
    _G.X2Unit = _G.X2Unit or {}
    _G.X2Unit.UnitNameWithWorld = function() return "BondsTest@World" end
    for k, v in pairs(opts or {}) do
        _G.X2Unit[k] = v
    end
end
SetMockUnit({ GetCurrentZoneGroup = function(_) return 1 end })

local function SetMockResident(opts)
    _G.X2Resident = _G.X2Resident or {}
    for k, v in pairs(opts or {}) do
        _G.X2Resident[k] = v
    end
end

-- Load bundle & widgets & acceptance
dofile("features/life/rs_life_m16_bundle.lua")
dofile("presentation/v3/widgets/rs_v3_life_economy_widgets.lua")
dofile("features/life/bonds/rs_bonds_acceptance.lua")

local Bonds = S.Features.Bonds
assert(Bonds ~= nil, "Bonds feature failed to initialize")
Bonds:Initialize()
Bonds:Enable()
local BA = Bonds.Authority

Test("B1: Registry contract & metadata", function()
    local reg = S.FeatureRegistry:Get("life_bonds")
    assert(reg ~= nil, "life_bonds not registered")
    assert(reg.route == "life.bonds", "route mismatch")
    assert(reg.authority == "v3.life.bonds", "authority mismatch")
    assert(reg.navigationDevelopmentState == "implemented_pending_ru", "development state must be implemented_pending_ru, got: " .. tostring(reg.navigationDevelopmentState))
    assert(Bonds ~= nil, "Bonds feature missing")
    assert(Bonds.Commands ~= nil, "Bonds commands missing")
end)

Test("B2: Empty vs Unavailable vs Ready status distinction", function()
    -- Case 1: readable == 0 -> unavailable
    SetMockResident({
        GetResidentBoardContent = function(_, index) return nil, "cannot read" end
    })
    Bonds.State.dailySnapshots = {}
    BA:Refresh()
    local proj1 = BA:GetProjection()
    assert(proj1.status == "unavailable", "expected unavailable when readable == 0, got: " .. tostring(proj1.status))

    -- Case 2: readable > 0, but contentCount == 0 -> empty
    SetMockResident({
        GetResidentBoardContent = function(_, index) return { contents = {} } end
    })
    BA:Refresh()
    local proj2 = BA:GetProjection()
    assert(proj2.status == "empty", "expected empty when readable > 0 and contentCount == 0, got: " .. tostring(proj2.status))

    -- Case 3: readable > 0, contentCount > 0 in West -> ready
    SetMockResident({
        GetResidentBoardContent = function(_, index)
            if index == 1 then
                return { contents = { "居民委托：需要布料 20 个" } }
            end
            return { contents = {} }
        end
    })
    SetMockUnit({ GetCurrentZoneGroup = function(_) return 1 end }) -- West zone
    Bonds.State.dailySnapshots = {}
    BA:Refresh()
    local proj3 = BA:GetProjection()
    assert(proj3.status == "ready", "expected ready when contentCount > 0, got: " .. tostring(proj3.status))
    assert(#proj3.rows > 0, "expected rows > 0")
end)

Test("B3: Board 1-7 normalization & continent classification", function()
    -- Set up boards 1 (fabric), 2 (leather), 3 (lumber), 4 (iron) and 5 (auroria)
    SetMockResident({
        GetResidentBoardContent = function(_, index)
            if index == 1 then return { contents = { "布料 20" } }
            elseif index == 2 then return { contents = { "皮革 60" } }
            elseif index == 3 then return { contents = { "木材 100" } }
            elseif index == 4 then return { contents = { "铁锭 20" } }
            elseif index == 5 then return { contents = { "王子的杂货箱 10" } }
            end
            return { contents = {} }
        end
    })
    SetMockUnit({ GetCurrentZoneGroup = function(_) return 1 end })
    Bonds.State.dailySnapshots = {}
    BA:Refresh()
    local proj = BA:GetProjection()
    assert(#proj.rows == 4, "expected 4 mainland rows, got: " .. tostring(#proj.rows))
    assert(proj.rows[1].board == 1 and proj.rows[1].materialKey == "fabric")
    assert(proj.rows[2].board == 2 and proj.rows[2].materialKey == "leather")
    assert(proj.rows[3].board == 3 and proj.rows[3].materialKey == "lumber")
    assert(proj.rows[4].board == 4 and proj.rows[4].materialKey == "iron")
end)

Test("B4: Real Quest State tracking with activeIndex", function()
    local progress = S.Services.QuestProgressV3
    _G.X2Quest = {
        IsCompleted = function(_, qid) return qid == 9044 end, -- Fabric 20 is completed
        GetActiveQuestListCount = function(_) return 1 end,
        GetActiveQuestType = function(_, idx) return 9152 end, -- Leather 60 is active
        IsReadyForCompleteQuest = function(_, qid) return false end,
    }
    progress:Refresh()

    Bonds.State.dailySnapshots = {}
    SetMockResident({
        GetResidentBoardContent = function(_, index)
            if index == 1 then return { contents = { "布料 20" } } -- quest 9044
            elseif index == 2 then return { contents = { "皮革 60" } } -- quest 9152
            elseif index == 3 then return { contents = { "木材 100" } } -- quest 9143
            end
            return { contents = {} }
        end
    })
    SetMockUnit({ GetCurrentZoneGroup = function(_) return 1 end })
    BA:Refresh()
    local proj = BA:GetProjection()
    local r1, r2, r3
    for _, r in ipairs(proj.rows) do
        if r.materialKey == "fabric" then r1 = r
        elseif r.materialKey == "leather" then r2 = r
        elseif r.materialKey == "lumber" then r3 = r end
    end

    assert(r1 ~= nil and r1.statusText == "已完成" and r1.tone == "green", "r1 should be completed")
    assert(r2 ~= nil and r2.statusText == "进行中" and r2.tone == "yellow", "r2 should be in progress")
    assert(r3 ~= nil and r3.statusText == "未接" and r3.tone == "muted", "r3 should be not accepted")
end)

Test("B5: Bag material count & shortage computation", function()
    -- Mock BagApi with bagId = 1 preferred
    _G.X2Bag = {
        Capacity = function(_) return 100 end,
        GetBagItemInfo = function(_, bagId, slot)
            if bagId == 1 and slot == 1 then
                return { itemType = 8256, stackCount = 35 } -- Fabric x35
            elseif bagId == 1 and slot == 2 then
                return { itemType = 16327, stackCount = 5 } -- Leather x5
            end
            return nil
        end
    }
    Bonds.State.dailySnapshots = {}
    SetMockResident({
        GetResidentBoardContent = function(_, index)
            if index == 1 then return { contents = { "布料 20" } }
            elseif index == 2 then return { contents = { "皮革 60" } }
            end
            return { contents = {} }
        end
    })
    SetMockUnit({ GetCurrentZoneGroup = function(_) return 1 end })
    BA:Refresh()
    local proj = BA:GetProjection()
    local fabricRow, leatherRow
    for _, r in ipairs(proj.rows) do
        if r.materialKey == "fabric" then fabricRow = r
        elseif r.materialKey == "leather" then leatherRow = r end
    end
    assert(fabricRow ~= nil, "fabricRow missing")
    assert(fabricRow.haveCount == 35, "expected 35 fabric, got: " .. tostring(fabricRow.haveCount))
    assert(fabricRow.shortage == 0, "expected 0 shortage for fabric")

    assert(leatherRow ~= nil, "leatherRow missing")
    assert(leatherRow.haveCount == 5, "expected 5 leather, got: " .. tostring(leatherRow.haveCount))
    assert(leatherRow.shortage == 55, "expected 55 shortage for leather, got: " .. tostring(leatherRow.shortage))
end)

Test("B6: Sorting & filtering options", function()
    -- Test sorting by quantity
    Bonds.Commands:SetSortMode("quantity")
    local proj = BA:GetProjection()
    assert(Bonds:GetSortMode() == "quantity", "sort mode should be quantity")

    -- Test filter toggle
    Bonds.Commands:SetBondFilterOption("q20", false)
    assert(Bonds:GetBondFilterOption("q20") == false, "q20 should be false")
    Bonds.Commands:SetBondFilterOption("q20", true)
    assert(Bonds:GetBondFilterOption("q20") == true, "q20 should be true")

    -- Test duplicate priority
    Bonds.Commands:SetDuplicatePriority("east")
    assert(Bonds:GetDuplicatePriority() == "east", "priority should be east")
    Bonds.Commands:SetDuplicatePriority("west")
    assert(Bonds:GetDuplicatePriority() == "west", "priority should be west")
end)

Test("B7: Row lookup and selection commands", function()
    local proj = BA:GetProjection()
    assert(#proj.rows > 0, "expected at least one row")
    local first = proj.rows[1]

    Bonds.Commands:SelectRow(first.key)
    local selected = Bonds.Commands:GetSelectedRow()
    assert(selected ~= nil, "selected row missing")
    assert(selected.key == first.key, "selected key mismatch")

    local lookedUp = Bonds.Commands:GetRow(first.key)
    assert(lookedUp ~= nil, "GetRow missing")
    assert(lookedUp.key == first.key, "GetRow key mismatch")
end)

Test("B8: Quest detail floating integration (FindGroup)", function()
    local progress = S.Services.QuestProgressV3
    local proj = BA:GetProjection()
    local first = proj.rows[1]

    local detail = progress:GetGroupDetail("bonds", first.key)
    assert(detail ~= nil, "GetGroupDetail for bonds returned nil")
    assert(type(detail.children) == "table" and #detail.children > 0, "children missing in bond detail")

    -- Test opening floating detail
    openedFloating = nil
    local ok = S.UIV3.QuestDetailFloatingV3:Open("bonds", first.key, first)
    assert(ok == true, "failed to open floating detail")
    assert(openedFloating ~= nil and openedFloating.scope == "bonds" and openedFloating.key == first.key, "floating call mismatched")
end)

Test("B9: Store normalization & daily rollover", function()
    local state = Bonds.State
    assert(state.sortMode ~= nil)
    assert(state.showCompleted ~= nil)

    -- Test DescribeDailyCache
    local desc = Bonds:DescribeDailyCache()
    assert(type(desc) == "table")
    assert(desc.westLoaded ~= nil)
    assert(desc.snapshotCount ~= nil)
end)

Test("B10: FoundationGate sequence case v3_m1_bonds", function()
    Bonds:Enable()
    local fn = S.FoundationGate.sequenceCases and S.FoundationGate.sequenceCases["v3_m1_bonds"]
    assert(fn ~= nil, "v3_m1_bonds sequence case not registered")
    local ok, err = fn()
    assert(ok == true, "v3_m1_bonds sequence failed: " .. tostring(err))
end)

print(string.format("\nBonds Test Results: %d/%d passed", passed, total))
if passed == total then
    print("ALL TESTS PASSED!")
else
    print("SOME TESTS FAILED!")
    os.exit(1)
end
