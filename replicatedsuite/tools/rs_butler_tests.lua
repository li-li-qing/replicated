------------------------------------------------------------------------
-- Replicated Suite V3 - Butler Read-only Test Suite
--
-- Tests Butler Authority, X2Butler read-only getters, capability gating,
-- out-of-context graceful fallback, in-context ready projection, bounded depth,
-- demand scoping, manual refresh, presentation formatting, event notification,
-- and v3_butler_read_only_contract acceptance sequence.
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

print("=== Replicated Suite: Butler Read-only Tests ===")

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

-- Load Butler domain files
dofile("features/life/butler/rs_butler_authority.lua")
dofile("features/life/butler/rs_butler_feature.lua")
dofile("features/life/butler/rs_butler_acceptance.lua")
dofile("presentation/v3/pages/rs_v3_butler_page.lua")

local Butler = S.Features.Butler
local BA = Butler.Authority

-- Helper to set mock X2Butler safely
local function SetMockButler(opts)
    _G.X2Butler = {}
    for k, v in pairs(opts or {}) do
        _G.X2Butler[k] = v
    end
end

Test("B1: Registry contract & metadata", function()
    local reg = S.FeatureRegistry:Get("life_butler")
    assert(reg ~= nil, "life_butler not registered in FeatureRegistry")
    assert(reg.route == "life.butler", "route mismatch: " .. tostring(reg.route))
    assert(reg.authority == "v3.butler", "authority mismatch: " .. tostring(reg.authority))
    assert(reg.navigationDevelopmentState == "incomplete", "development state must follow user RU acceptance and remain incomplete, got: " .. tostring(reg.navigationDevelopmentState))
    assert(reg.status == "migrated_v3_read_only", "status mismatch: " .. tostring(reg.status))
    assert(reg.apiPolicy == "read_only", "apiPolicy must be read_only")
    assert(type(reg.apiDependencies) == "table" and #reg.apiDependencies == 1, "apiDependencies must contain 1 getter")
    assert(reg.apiDependencies[1] == "X2Butler:GetChargeInfo", "apiDependencies[1] mismatch")
    assert(Butler ~= nil, "Butler feature missing")
    assert(Butler.Authority ~= nil, "Butler Authority missing")
    assert(Butler.Commands ~= nil, "Butler Commands missing")
end)

Test("B2: Official API capability gate verification", function()
    local capName = "X2Butler:GetChargeInfo"
    local desc = S.ApiCapabilities:Describe(capName)
    assert(desc ~= nil, capName .. " must be registered in ApiCapabilities")
    assert(desc.OfficialState == "OfficialEnabled", capName .. " must be OfficialEnabled")
    assert(desc.SideEffectFree == true, capName .. " must be SideEffectFree")

    -- Assert mutators are NOT registered / not allowed
    local writeCaps = { "X2Butler:Equip", "X2Butler:Interact", "X2Butler:SetOrder" }
    for _, mutator in ipairs(writeCaps) do
        local d = S.ApiCapabilities:Describe(mutator)
        assert(d == nil or d.OfficialState ~= "OfficialEnabled", mutator .. " write mutator must NOT be allowed")
    end
end)

Test("B3: Out-of-context / Unavailable graceful fallback", function()
    SetMockButler({
        GetChargeInfo = function(_) return nil end,
    })

    local ok = BA:Refresh("test_out_of_context")
    assert(ok == true, "Refresh must succeed even when out of context")
    local proj = BA:GetProjection()
    assert(proj.available == false, "available must be false when out of context")
    assert(proj.status == "unavailable", "status must be unavailable, got: " .. tostring(proj.status))
    assert(proj.charge == nil, "charge should be nil")

    local health = BA:GetHealth()
    assert(health.failures > 0, "failures metric should track out-of-context refresh")
end)

Test("B4: In-context Ready state with structured charge info", function()
    SetMockButler({
        GetChargeInfo = function(_)
            return {
                charge = 120,
                maxCharge = 200,
                remainTime = 86400,
                chargeType = 1,
            }
        end,
    })

    local ok = BA:Refresh("test_in_context")
    assert(ok == true, "Refresh should succeed")
    local proj = BA:GetProjection()
    assert(proj.available == true, "available must be true in context")
    assert(proj.status == "ready", "status must be ready, got: " .. tostring(proj.status))
    assert(type(proj.charge) == "table", "charge should be table")
    assert(proj.charge.charge == 120, "charge mismatch")
    assert(proj.charge.maxCharge == 200, "maxCharge mismatch")
    assert(proj.charge.remainTime == 86400, "remainTime mismatch")
end)

Test("B5: Bounded table depth & cyclic protection", function()
    local cyclicTbl = { charge = 50 }
    cyclicTbl.selfRef = cyclicTbl

    SetMockButler({
        GetChargeInfo = function(_) return cyclicTbl end,
    })

    BA:Refresh("test_cyclic")
    local proj = BA:GetProjection()
    assert(proj.available == true, "cyclic structure should not crash Refresh")
    assert(proj.charge.selfRef == "[循环字段]" or type(proj.charge.selfRef) == "string", "cyclic reference must be handled gracefully")
end)

Test("B6: Demand lifecycle & consumer scoping", function()
    Butler:Enable()
    assert(Butler.enabled == true, "Butler must be enabled")

    -- Initially 0 consumers
    assert(Butler.consumerCount == 0, "initial consumer count must be 0")

    -- Acquire consumer
    local acqOk, acqErr = Butler:AcquireConsumer("test_page_consumer")
    assert(acqOk == true, "AcquireConsumer failed: " .. tostring(acqErr))
    assert(Butler.consumerCount == 1, "consumerCount should be 1")

    -- Release consumer
    local relOk = Butler:ReleaseConsumer("test_page_consumer")
    assert(relOk == true, "ReleaseConsumer failed")
    assert(Butler.consumerCount == 0, "consumerCount should be 0 after release")

    -- Refresh when consumerCount == 0 should not query X2Butler
    local reads = 0
    SetMockButler({
        GetChargeInfo = function(_) reads = reads + 1; return { charge = 10 } end,
    })
    Butler:Refresh("zero_consumer_refresh")
    assert(reads == 0, "should not query X2Butler when consumerCount is 0")
end)

Test("B7: Manual refresh command", function()
    Butler:Enable()
    Butler:AcquireConsumer("test_cmd_consumer")
    local revBefore = BA.revision
    local ok, err = Butler.Commands:Refresh("manual_test")
    assert(ok == true, "Commands:Refresh failed: " .. tostring(err))
    assert(BA.revision > revBefore, "revision should advance after manual refresh")
    Butler:ReleaseConsumer("test_cmd_consumer")
end)

Test("B8: PageHost factory and UI formatting", function()
    local factory = S.UIV3.PageHost.factories["life.butler"]
    assert(type(factory) == "function", "Page factory for life.butler must be registered")

    local page = factory({}, "life.butler")
    assert(page ~= nil, "page creation failed")
    assert(page.route == "life.butler", "page route mismatch")

    -- Test OnActivated and OnDeactivated
    S.FeatureRuntime.IsEnabled = function(_, id) return true end
    local actOk = page:OnActivated()
    assert(actOk == true, "OnActivated should succeed")
    assert(page.consumerHeld == true, "consumerHeld should be true after OnActivated")

    local deactOk = page:OnDeactivated()
    assert(deactOk == true, "OnDeactivated should succeed")
    assert(page.consumerHeld == false, "consumerHeld should be false after OnDeactivated")
end)

Test("B9: Event publish on refresh", function()
    local receivedTopic = nil
    S.Events:SubscribeInternal("v3.butler.updated", "test_owner", function(owner, payload)
        receivedTopic = payload
    end)

    BA:Refresh("event_publish_test")
    assert(receivedTopic ~= nil, "v3.butler.updated event was not published")
    assert(receivedTopic.revision == BA.revision, "event revision mismatch")
    S.Events:UnsubscribeInternal("v3.butler.updated", "test_owner")
end)

Test("B10: FoundationGate sequence case v3_butler_read_only_contract", function()
    local seqCase = S.FoundationGate.sequenceCases and S.FoundationGate.sequenceCases["v3_butler_read_only_contract"]
    assert(type(seqCase) == "function", "v3_butler_read_only_contract sequence case missing")
    local ok, err = seqCase()
    assert(ok == true, "v3_butler_read_only_contract sequence failed: " .. tostring(err))
end)

print(string.format("\nButler Test Results: %d/%d passed", passed, total))
if passed == total then
    print("ALL TESTS PASSED!")
else
    print("SOME TESTS FAILED!")
    os.exit(1)
end
