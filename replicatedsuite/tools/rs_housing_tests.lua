------------------------------------------------------------------------
-- Replicated Suite V3 - Housing / Tax Read-only Test Suite
--
-- Tests Housing Authority, X2House read-only getters, capability gating,
-- out-of-context graceful fallback, in-context ready projection, partial state,
-- demand scoping, manual refresh, presentation formatting, event notification,
-- and v3_housing_read_only_contract acceptance sequence.
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

print("=== Replicated Suite: Housing / Tax Read-only Tests ===")

local h = dofile("tools/rs_gear_page_test_host.lua")({})
local S = h.S

dofile("core/rs_demand.lua")
dofile("data/rs_data_registry.lua")
dofile("data/ids/rs_item_ids.lua")
dofile("data/ids/rs_quest_ids.lua")
dofile("data/ids/rs_instance_ids.lua")
dofile("core/rs_constants.lua")
dofile("core/rs_foundation_gate.lua")
dofile("features/rs_feature_registry.lua")

-- Mock RSUI and UIV3Design for PageHost
S.RSUI = S.RSUI or {}
S.RSUI.HorizontalBox = function() return {} end
S.RSUI.VerticalBox = function() return {} end
S.RSUI.Button = function(spec)
    local btn = { spec = spec, text = spec.text or "" }
    function btn:SetText(t) self.text = t end
    return btn
end
S.RSUI.Text = function(spec)
    local txt = { spec = spec, text = spec.text or "" }
    function txt:SetText(t) self.text = t end
    return txt
end

S.UIV3Design = {
    PageRoot = function(_, parent, id)
        local root = { id = id, parent = parent }
        return root
    end,
    PageHeader = function(_, parent, id, title, desc, btnText, btnFn)
        return { id = id, title = title, desc = desc, btnText = btnText, btnFn = btnFn }
    end,
    InfoCard = function(_, parent, spec)
        local card = { spec = spec, value = spec.value, detail = spec.detail }
        function card:SetData(data)
            if data.value ~= nil then self.value = data.value end
            if data.detail ~= nil then self.detail = data.detail end
        end
        return card
    end,
}

S.UIV3 = S.UIV3 or {}
S.UIV3.PageHost = {
    factories = {},
    RegisterFactory = function(self, route, factory)
        self.factories[route] = factory
        return true
    end,
}

-- Ensure FeatureRuntime mock handles implementation checks
S.FeatureRuntime = S.FeatureRuntime or {}
S.FeatureRuntime.IsImplemented = function(_, id) return true end
S.FeatureRuntime.IsEnabled = function(_, id) return true end
S.FeatureRuntime.SetPreferredEnabled = function(_, id, v) return true end

-- Load Housing domain files
dofile("features/life/housing/rs_housing_authority.lua")
dofile("features/life/housing/rs_housing_feature.lua")
dofile("features/life/housing/rs_housing_acceptance.lua")
dofile("presentation/v3/pages/rs_v3_housing_page.lua")

local Housing = S.Features.Housing
local HA = Housing.Authority

-- Helper to set mock X2House safely
local function SetMockHouse(opts)
    _G.X2House = {}
    for k, v in pairs(opts or {}) do
        _G.X2House[k] = v
    end
end

Test("H1: Registry contract & metadata", function()
    local reg = S.FeatureRegistry:Get("life_housing")
    assert(reg ~= nil, "life_housing not registered in FeatureRegistry")
    assert(reg.route == "life.housing", "route mismatch: " .. tostring(reg.route))
    assert(reg.authority == "v3.housing", "authority mismatch: " .. tostring(reg.authority))
    assert(reg.navigationDevelopmentState == "incomplete", "development state must follow user RU acceptance and remain incomplete, got: " .. tostring(reg.navigationDevelopmentState))
    assert(reg.status == "migrated_v3_read_only", "status mismatch: " .. tostring(reg.status))
    assert(reg.apiPolicy == "read_only", "apiPolicy must be read_only")
    assert(type(reg.apiDependencies) == "table" and #reg.apiDependencies == 4, "apiDependencies must contain 4 getters")
    assert(Housing ~= nil, "Housing feature missing")
    assert(Housing.Authority ~= nil, "Housing Authority missing")
    assert(Housing.Commands ~= nil, "Housing Commands missing")
end)

Test("H2: Official API capability gate verification", function()
    local caps = {
        "X2House:GetCurrentHousingTaxInfo",
        "X2House:GetHouseOwnerName",
        "X2House:GetHouseName",
        "X2House:GetHouseType",
    }
    for _, capName in ipairs(caps) do
        local desc = S.ApiCapabilities:Describe(capName)
        assert(desc ~= nil, capName .. " must be registered in ApiCapabilities")
        assert(desc.OfficialState == "OfficialEnabled", capName .. " must be OfficialEnabled")
        assert(desc.SideEffectFree == true, capName .. " must be SideEffectFree")
    end

    -- Assert mutators are NOT registered / not allowed
    local writeCaps = { "X2House:SetHouseName", "X2House:Demolish", "X2House:BuyHouse", "X2House:SetHouseForSale" }
    for _, capName in ipairs(writeCaps) do
        local desc = S.ApiCapabilities:Describe(capName)
        assert(desc == nil or desc.OfficialState ~= "OfficialEnabled", capName .. " write mutator must NOT be allowed")
    end
end)

Test("H3: Out-of-context / Unavailable graceful fallback", function()
    -- When player is away from house, getters return nil
    SetMockHouse({
        GetCurrentHousingTaxInfo = function(_) return nil end,
        GetHouseOwnerName = function(_) return nil end,
        GetHouseName = function(_) return nil end,
        GetHouseType = function(_) return nil end,
    })

    local ok = HA:Refresh("test_out_of_context")
    assert(ok == true, "Refresh must succeed even when out of context")
    local proj = HA:GetProjection()
    assert(proj.available == false, "available must be false when out of context")
    assert(proj.status == "unavailable", "status must be unavailable, got: " .. tostring(proj.status))
    assert(proj.values.name == nil, "name should be nil")
    assert(proj.values.owner == nil, "owner should be nil")
    assert(proj.values.tax == nil, "tax should be nil")
    assert(proj.values.type == nil, "type should be nil")

    local health = HA:GetHealth()
    assert(health.failures > 0, "failures metric should track out-of-context refresh")
end)

Test("H4: In-context Ready state with full fields", function()
    SetMockHouse({
        GetCurrentHousingTaxInfo = function(_)
            return { totalTax = 25, prepayment = 0, deposit = 50, dueDate = "2026-09-20" }
        end,
        GetHouseOwnerName = function(_) return "OwnerTester" end,
        GetHouseName = function(_) return "南瓜头稻草人菜园" end,
        GetHouseType = function(_) return 204 end,
    })

    local ok = HA:Refresh("test_in_context")
    assert(ok == true, "Refresh should succeed")
    local proj = HA:GetProjection()
    assert(proj.available == true, "available must be true in context")
    assert(proj.status == "ready", "status must be ready, got: " .. tostring(proj.status))
    assert(proj.values.name == "南瓜头稻草人菜园", "name mismatch")
    assert(proj.values.owner == "OwnerTester", "owner mismatch")
    assert(proj.values.type == "204", "type mismatch")
    assert(type(proj.values.tax) == "table", "tax should be bounded table")
    assert(proj.values.tax.totalTax == 25, "tax totalTax mismatch")
    assert(proj.values.tax.deposit == 50, "tax deposit mismatch")
end)

Test("H5: Partial state handling", function()
    -- Only name and owner available, tax and type fail
    SetMockHouse({
        GetCurrentHousingTaxInfo = function(_) error("tax info unavailable") end,
        GetHouseOwnerName = function(_) return "PartialOwner" end,
        GetHouseName = function(_) return "荒野简易棚" end,
        GetHouseType = function(_) return nil, "unknown type" end,
    })

    HA:Refresh("test_partial")
    local proj = HA:GetProjection()
    assert(proj.available == true, "available should be true when partial fields present")
    assert(proj.status == "partial", "status must be partial, got: " .. tostring(proj.status))
    assert(proj.values.name == "荒野简易棚", "name should be populated")
    assert(proj.values.owner == "PartialOwner", "owner should be populated")
    assert(proj.values.tax == nil, "tax should be nil")
    assert(proj.values.type == nil, "type should be nil")
    assert(proj.errors.tax ~= nil, "error for tax should be recorded")
end)

Test("H6: Demand lifecycle & consumer scoping", function()
    Housing:Enable()
    assert(Housing.enabled == true, "Housing must be enabled")

    -- Initially 0 consumers
    assert(Housing.consumerCount == 0, "initial consumer count must be 0")

    -- Acquire consumer
    local acqOk, acqErr = Housing:AcquireConsumer("test_page_consumer")
    assert(acqOk == true, "AcquireConsumer failed: " .. tostring(acqErr))
    assert(Housing.consumerCount == 1, "consumerCount should be 1")

    -- Release consumer
    local relOk = Housing:ReleaseConsumer("test_page_consumer")
    assert(relOk == true, "ReleaseConsumer failed")
    assert(Housing.consumerCount == 0, "consumerCount should be 0 after release")

    -- Refresh when consumerCount == 0 should not query X2House
    local reads = 0
    SetMockHouse({
        GetHouseName = function(_) reads = reads + 1; return "House" end,
    })
    Housing:Refresh("zero_consumer_refresh")
    assert(reads == 0, "should not query X2House when consumerCount is 0")
end)

Test("H7: Manual refresh command", function()
    Housing:Enable()
    Housing:AcquireConsumer("test_cmd_consumer")
    local revBefore = HA.revision
    local ok, err = Housing.Commands:Refresh("manual_test")
    assert(ok == true, "Commands:Refresh failed: " .. tostring(err))
    assert(HA.revision > revBefore, "revision should advance after manual refresh")
    Housing:ReleaseConsumer("test_cmd_consumer")
end)

Test("H8: PageHost factory and UI formatting", function()
    local factory = S.UIV3.PageHost.factories["life.housing"]
    assert(type(factory) == "function", "Page factory for life.housing must be registered")

    local page = factory({}, "life.housing")
    assert(page ~= nil, "page creation failed")
    assert(page.route == "life.housing", "page route mismatch")

    -- Test OnActivated and OnDeactivated
    S.FeatureRuntime.IsEnabled = function(_, id) return true end
    local actOk = page:OnActivated()
    assert(actOk == true, "OnActivated should succeed")
    assert(page.consumerHeld == true, "consumerHeld should be true after OnActivated")

    local deactOk = page:OnDeactivated()
    assert(deactOk == true, "OnDeactivated should succeed")
    assert(page.consumerHeld == false, "consumerHeld should be false after OnDeactivated")
end)

Test("H9: Event publish on refresh", function()
    local receivedTopic = nil
    S.Events:SubscribeInternal("v3.housing.updated", "test_owner", function(owner, payload)
        receivedTopic = payload
    end)

    HA:Refresh("event_publish_test")
    assert(receivedTopic ~= nil, "v3.housing.updated event was not published")
    assert(receivedTopic.revision == HA.revision, "event revision mismatch")
    S.Events:UnsubscribeInternal("v3.housing.updated", "test_owner")
end)

Test("H10: FoundationGate sequence case v3_housing_read_only_contract", function()
    local seqCase = S.FoundationGate.sequenceCases and S.FoundationGate.sequenceCases["v3_housing_read_only_contract"]
    assert(type(seqCase) == "function", "v3_housing_read_only_contract sequence case missing")
    local ok, err = seqCase()
    assert(ok == true, "v3_housing_read_only_contract sequence failed: " .. tostring(err))
end)

print(string.format("\nHousing Test Results: %d/%d passed", passed, total))
if passed == total then
    print("ALL TESTS PASSED!")
else
    print("SOME TESTS FAILED!")
    os.exit(1)
end
