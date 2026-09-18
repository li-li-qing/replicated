------------------------------------------------------------------------
-- Replicated Suite V3 - Craft Assist Test Suite
--
-- Tests Craft Assist (tools_craft) after removal of life_craft_planner:
--   * Metadata contract & capability gating
--   * Recipe resolution & user selection (SelectRecipe)
--   * Backpack held counts & shortage calculation
--   * Price quote queue integration (QuotePendingMaterials)
--   * Native craft surface observation (CraftSurfaceV3) fail-closed geometry
--   * FoundationGate contracts: v3_craft_user_selection_contract and v3_craft_sidecar_contract
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

print("=== Replicated Suite: Craft Assist Tests ===")

local h = dofile("tools/rs_gear_page_test_host.lua")({})
local S = h.S

dofile("core/rs_demand.lua")
dofile("data/rs_data_registry.lua")
dofile("data/rs_static_data_v2.lua")
dofile("data/ids/rs_item_ids.lua")
dofile("data/ids/rs_zone_ids.lua")
dofile("data/ids/rs_trade_craft_ids.lua")
dofile("data/ids/rs_trade_product_ids.lua")
dofile("data/ids/rs_quest_ids.lua")
dofile("data/ids/rs_instance_ids.lua")
dofile("data/rs_trade_materials.lua")
dofile("data/rs_trade_static_v2.lua")
dofile("core/rs_constants.lua")
dofile("core/rs_foundation_gate.lua")
dofile("features/rs_feature_registry.lua")

-- Mock RSUI and UIV3 Host components for Sidecar and Page
S.UIV3 = S.UIV3 or {}
S.UIV3.WidgetHost = {
    Register = function(self, id, spec) return true end,
    IsVisible = function(self, id) return false end,
    SetVisible = function(self, id, visible, opts) return true end,
    NotifyWindowClosed = function() return true end,
}
S.UIV3.PageHost = {
    factories = {},
    RegisterFactory = function(self, route, factory)
        self.factories[route] = factory
        return true
    end,
}

S.RSUI = S.RSUI or {}
S.RSUI.FloatingSurface = {
    Create = function(spec)
        local inst = { spec = spec }
        function inst:GetContentRoot() return {} end
        return inst
    end,
}
S.RSUI.VerticalBox = function(spec) return { spec = spec } end
S.RSUI.HorizontalBox = function(spec) return { spec = spec } end
S.RSUI.Button = function(spec)
    local b = { spec = spec, text = spec.text or "", enabled = spec.enabled ~= false }
    function b:SetText(t) self.text = t end
    function b:SetEnabled(e) self.enabled = e end
    return b
end
S.RSUI.Text = function(spec)
    local t = { spec = spec, text = spec.text or "" }
    function t:SetText(txt) self.text = txt end
    return t
end
S.RSUI.Dropdown = function(spec)
    local d = { spec = spec, items = spec.items or {} }
    function d:Render() end
    return d
end
S.RSUI.TableView = function(spec)
    local tbl = { spec = spec, items = spec.items or {} }
    function tbl:SetItems(items) self.items = items end
    function tbl:SetViewState(state, info) self.state = state; self.stateInfo = info end
    return tbl
end
S.RSUI.Toggle = function(spec) return { spec = spec } end
S.RSUI.NumericInput = function(spec)
    local num = { spec = spec, value = spec.value or 1 }
    function num:GetValue() return self.value end
    function num:SetValue(v) self.value = v end
    return num
end

-- Mock FeatureRuntime
S.FeatureRuntime = S.FeatureRuntime or {}
S.FeatureRuntime.IsEnabled = function(_, id) return true end
S.FeatureRuntime.IsImplemented = function(_, id) return true end
S.FeatureRuntime.SetPreferredEnabled = function(_, id, v) return true end

-- Load craft services and features
dofile("services/rs_craft_surface_v3.lua")
dofile("features/rs_business_bridge.lua")
dofile("features/life/craft/rs_craft_assistant_surface_extension_v3.lua")
dofile("presentation/v3/widgets/rs_v3_craft_sidecar.lua")

local Assist = S.Features and S.Features.tools_craft
local Surface = S.Services and S.Services.CraftSurfaceV3
local Sidecar = S.UIV3 and S.UIV3.CraftSidecar

Test("C1: Feature metadata and removed planner contract", function()
    -- 中文维护测试（2026-09-15）：制作规划删除必须是真删除：Registry/Feature 都不存在；
    -- 制作台助手保持独立可用，避免删除 life_craft_planner 时误伤共享 CraftRead/CraftProjection。
    assert(S.Features and S.Features.life_craft_planner == nil, "removed life_craft_planner must not be instantiated")
    assert(S.FeatureRegistry:Get("life_craft_planner") == nil, "removed life_craft_planner must not remain in registry")
    assert(Assist ~= nil, "tools_craft missing")
    assert(Surface ~= nil, "CraftSurfaceV3 missing")
    assert(Sidecar ~= nil, "CraftSidecar missing")

    local regAssist = S.FeatureRegistry:Get("tools_craft")
    assert(regAssist ~= nil, "tools_craft not in registry")
    assert(regAssist.route == "tools.craft_assist", "assist route mismatch")
    assert(regAssist.authority == "v3.craft", "assist authority mismatch")
    assert(regAssist.navigationDevelopmentState == "incomplete", "craft assist development state changed unexpectedly: " .. tostring(regAssist.navigationDevelopmentState))
end)

Test("C2: Capability permissions & read-only gating", function()
    local caps = {
        "X2Craft:GetCraftBaseInfo",
        "X2Craft:GetCraftProductInfo",
        "X2Craft:GetCraftMaterialInfo",
        "X2Craft:GetCraftTypeByItemType",
        "X2Bag:Capacity",
        "X2Bag:GetBagItemInfo",
    }
    for _, capName in ipairs(caps) do
        local desc = S.ApiCapabilities:Describe(capName)
        assert(desc ~= nil, capName .. " must be registered")
        assert(desc.OfficialState == "OfficialEnabled" or desc.OfficialState == "OfficialChanged", capName .. " state must be valid official")
        assert(desc.SideEffectFree == true, capName .. " must be SideEffectFree")
    end

    -- Write mutators must NOT be permitted
    local forbidden = { "X2Craft:Craft", "X2Craft:ExecuteCraft", "X2Craft:StartCraft" }
    for _, capName in ipairs(forbidden) do
        local desc = S.ApiCapabilities:Describe(capName)
        assert(desc == nil or desc.OfficialState ~= "OfficialEnabled", capName .. " must NOT be allowed")
    end
end)

Test("C3: Recipe resolution and user selection", function()
    Assist:Enable()
    local options = Assist:GetProjection().recipeOptions
    assert(type(options) == "table" and #options > 0, "recipeOptions should be populated")

    local firstOption = options[1]
    assert(firstOption.value ~= nil, "option value missing")
    assert(firstOption.craftId ~= nil, "option craftId missing")

    -- Select the first recipe
    local ok, err = Assist.Commands:SelectRecipe(firstOption.value)
    assert(ok == true, "SelectRecipe failed: " .. tostring(err))

    local proj = Assist:GetProjection()
    assert(proj.selectedRecipeKey == firstOption.value, "selectedRecipeKey mismatch")
    assert(Assist.State.craftType == firstOption.craftId, "craftType mismatch")

    -- Invalid recipe key rejected
    local badOk = Assist.Commands:SelectRecipe("non_existent_recipe_key_99999")
    assert(badOk == false, "invalid recipe key should be rejected")
end)

Test("C5: Backpack held counts and shortage calculation", function()
    -- Set mock X2Bag with specific items
    local mockBag = {
        [1] = { itemType = 18888, count = 25 },
        [2] = { itemType = 18889, count = 5 },
    }
    _G.X2Bag = {
        Capacity = function(_) return 50 end,
        GetBagItemInfo = function(_, bagId, slot)
            return mockBag[slot]
        end,
    }

    -- Set mock X2Craft
    _G.X2Craft = {
        GetCraftBaseInfo = function(_, craftType)
            return { name = "测试配方", actability = 10 }
        end,
        GetCraftProductInfo = function(_, craftType)
            return { { itemType = 99999, count = 1 } }
        end,
        GetCraftMaterialInfo = function(_, craftType, doodadId)
            return {
                { itemType = 18888, count = 30 }, -- held 25 -> shortage 5
                { itemType = 18889, count = 5 },  -- held 5 -> shortage 0
                { itemType = 18890, count = 10 }, -- held 0 -> shortage 10
            }
        end,
        GetCraftTypeByItemType = function(_, itemType)
            return 101
        end,
    }

    Assist.State.craftType = 101
    Assist.State.itemType = nil
    Assist.State.selectedRecipeKey = nil
    Assist:AcquireConsumer("test_c5")
    local ok = Assist:Refresh("test_held_counts")
    assert(ok == true, "Assist:Refresh failed")

    local proj = Assist:GetProjection()
    local materials = proj.craft and proj.craft.recipes and proj.craft.recipes[1] and proj.craft.recipes[1].materials and proj.craft.recipes[1].materials.items
    assert(type(materials) == "table" and #materials == 3, "materials items missing")

    local m1, m2, m3
    for _, m in ipairs(materials) do
        if m.itemType == 18888 then m1 = m
        elseif m.itemType == 18889 then m2 = m
        elseif m.itemType == 18890 then m3 = m end
    end

    assert(m1 ~= nil and m1.held == 25 and m1.shortage == 5, "m1 held/shortage mismatch: held=" .. tostring(m1 and m1.held) .. " shortage=" .. tostring(m1 and m1.shortage))
    assert(m2 ~= nil and m2.held == 5 and m2.shortage == 0, "m2 held/shortage mismatch")
    assert(m3 ~= nil and m3.held == 0 and m3.shortage == 10, "m3 held/shortage mismatch")
    Assist:ReleaseConsumer("test_c5")
end)

Test("C8: Explicit material quote queue integration", function()
    local quoteCalls = {}
    S.Services.PriceQuoteQueueV3 = {
        maxQueue = 64,
        GetPriceByItemType = function(_, itemType, itemGrade) return nil end,
        RequestQuote = function(self, tag, itemType, itemGrade, cb)
            quoteCalls[#quoteCalls + 1] = { tag = tag, itemType = itemType, itemGrade = itemGrade }
            if cb then cb() end
            return true
        end,
    }

    Assist:Enable()
    local options = Assist:GetProjection().recipeOptions or {}
    assert(#options > 0, "craft assistant recipe options missing")
    local selected, selectErr = Assist.Commands:SelectRecipe(options[1].value)
    assert(selected == true, "SelectRecipe failed before quote test: " .. tostring(selectErr))
    Assist:AcquireConsumer("test_c8")
    Assist:Refresh("test_quote_refresh")
    assert(#quoteCalls == 0, "ordinary craft Refresh must never fan out auction quotes")

    local projection = Assist:GetProjection() or {}
    if (tonumber(projection.pendingQuoteCount) or 0) > 0 then
        local ok, message = Assist.Commands:QuotePendingMaterials()
        assert(ok == true, "QuotePendingMaterials failed: " .. tostring(message))
        assert(#quoteCalls > 0, "explicit QuotePendingMaterials must submit at least one quote")
    end
    Assist:ReleaseConsumer("test_c8")
end)

Test("C9: CraftSurfaceV3 observation and fail-closed safety", function()
    -- Mock ADDON
    local contentVisible = false
    local mainScriptVisible = nil
    local returnContent = true
    local mockAddon = {
        GetContent = function(_, id)
            if not returnContent then return nil end
            return {
                IsVisible = function() return contentVisible end,
                GetParent = function() return nil end,
            }
        end,
        GetContentMainScriptPosVis = function(_, id)
            return 100, 100, 400, 500, mainScriptVisible
        end,
    }
    _G.ADDON = mockAddon
    _G.UIC_MAKE_CRAFT_ORDER = 8801
    _G.UIC_CRAFT_ORDER = 8802
    _G.UIC_CRAFT_BOOK = 8803

    -- Case A: Geometry returned, but Content widget is nil and visibility is nil -> must fail closed on geometry-only
    returnContent = false
    contentVisible = false
    mainScriptVisible = nil
    local snapA = Surface:_Read()
    assert(snapA.visible == false, "Geometry-only without visibility fact must fail closed")
    assert(snapA.source == "geometry-only" or snapA.status == "unknown", "source should indicate geometry-only, got: " .. tostring(snapA.source))

    -- Case B: Content visible is true -> ready and visible
    returnContent = true
    contentVisible = true
    local snapB = Surface:_Read()
    assert(snapB.visible == true, "Positive content visibility must yield visible = true")
    assert(snapB.status == "ready", "status should be ready")

    -- Case C: MainScript visible is boolean true -> ready and visible
    contentVisible = false
    mainScriptVisible = true
    local snapC = Surface:_Read()
    assert(snapC.visible == true, "Boolean visible = true from mainscript must yield visible = true")

    -- Case D: MainScript visible is false -> visible is false
    mainScriptVisible = false
    local snapD = Surface:_Read()
    assert(snapD.visible == false, "MainScript visible = false must yield visible = false")
end)

Test("C9B: CraftSidecar content status id does not collide with FloatingSurface footer", function()
    local sidecarFile = assert(io.open("presentation/v3/widgets/rs_v3_craft_sidecar.lua", "rb"))
    local sidecarText = sidecarFile:read("*a"); sidecarFile:close()
    assert(sidecarText:find('id = "v3_craft_sidecar_status"', 1, true) == nil,
        "craft content status logical id collides with WindowShell-generated v3_craft_sidecar_status")
    assert(sidecarText:find('id = "v3_craft_sidecar_action_status"', 1, true) ~= nil,
        "craft sidecar must use a dedicated content/action status logical id")
end)

Test("C10: FoundationGate craft-assistant contracts", function()
    local gate = S.FoundationGate
    assert(gate ~= nil, "FoundationGate missing")
    assert(Assist.CraftUserSelectionContractVersion >= 1, "Assist CraftUserSelectionContractVersion missing")
    assert(type(Assist.Commands.SelectRecipe) == "function", "Assist SelectRecipe missing")
    assert(Surface.version >= 1, "Surface version missing")
    assert(Surface.VisibilityContractVersion >= 1, "Surface VisibilityContractVersion missing")
    assert(type(Surface.GetSnapshot) == "function", "Surface GetSnapshot missing")
    assert(type(Surface.Start) == "function", "Surface Start missing")
    assert(type(Surface.Stop) == "function", "Surface Stop missing")
    assert(Sidecar ~= nil, "CraftSidecar missing")
    assert(Assist.CraftSidecarContractVersion >= 1, "CraftSidecarContractVersion missing")
    assert(type(Assist.Commands.SetAutoSidecar) == "function", "SetAutoSidecar missing")
end)

print(string.format("\nCraft Assist Test Results: %d/%d passed", passed, total))
if passed == total then
    print("ALL TESTS PASSED!")
else
    print("SOME TESTS FAILED!")
    os.exit(1)
end
