------------------------------------------------------------------------
-- Replicated Suite V3 - Craft Planner & Craft Assist Test Suite
--
-- Tests Craft Planner (life_craft_planner) and Craft Assist (tools_craft):
--   * Metadata contract & capability gating
--   * Recipe resolution & user selection (SelectRecipe)
--   * Recipe search & filtering (FindRecipes)
--   * Backpack held counts & shortage calculation
--   * Recursive recipe graph (BuildCraftRecipeGraph), cycles & unresolved safety
--   * Multi-recipe plan lifecycle (Add/Set/Remove/Clear) & material aggregation
--   * Price quote queue integration (QuotePlanMaterials, QuotePendingMaterials)
--   * Native craft surface observation (CraftSurfaceV3) fail-closed geometry
--   * FoundationGate contracts: v3_craft_user_selection_contract,
--     v3_craft_plan_contract, v3_craft_sidecar_contract
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

print("=== Replicated Suite: Craft Planner & Craft Assist Tests ===")

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
dofile("features/life/craft/rs_craft_planner_extension_v3.lua")
dofile("features/life/craft/rs_craft_assistant_surface_extension_v3.lua")
dofile("presentation/v3/widgets/rs_v3_craft_sidecar.lua")

local Planner = S.Features and S.Features.life_craft_planner
local Assist = S.Features and S.Features.tools_craft
local Surface = S.Services and S.Services.CraftSurfaceV3
local Sidecar = S.UIV3 and S.UIV3.CraftSidecar

Test("C1: Feature metadata and registry contract", function()
    assert(Planner ~= nil, "life_craft_planner missing")
    assert(Assist ~= nil, "tools_craft missing")
    assert(Surface ~= nil, "CraftSurfaceV3 missing")
    assert(Sidecar ~= nil, "CraftSidecar missing")

    local regPlanner = S.FeatureRegistry:Get("life_craft_planner")
    assert(regPlanner ~= nil, "life_craft_planner not in registry")
    assert(regPlanner.route == "life.craft_planner", "planner route mismatch")
    assert(regPlanner.authority == "v3.craft_planner", "planner authority mismatch")
    assert(regPlanner.navigationDevelopmentState == "incomplete", "planner must remain incomplete after user RU acceptance found missing coverage: " .. tostring(regPlanner.navigationDevelopmentState))

    local regAssist = S.FeatureRegistry:Get("tools_craft")
    assert(regAssist ~= nil, "tools_craft not in registry")
    assert(regAssist.route == "tools.craft_assist", "assist route mismatch")
    assert(regAssist.authority == "v3.craft", "assist authority mismatch")
    assert(regAssist.navigationDevelopmentState == "incomplete", "craft assist must remain incomplete after user RU acceptance found missing coverage: " .. tostring(regAssist.navigationDevelopmentState))
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
    Planner:Enable()
    local options = Planner:GetProjection().recipeOptions
    assert(type(options) == "table" and #options > 0, "recipeOptions should be populated")

    local firstOption = options[1]
    assert(firstOption.value ~= nil, "option value missing")
    assert(firstOption.craftId ~= nil, "option craftId missing")

    -- Select the first recipe
    local ok, err = Planner.Commands:SelectRecipe(firstOption.value)
    assert(ok == true, "SelectRecipe failed: " .. tostring(err))

    local proj = Planner:GetProjection()
    assert(proj.selectedRecipeKey == firstOption.value, "selectedRecipeKey mismatch")
    assert(Planner.State.craftType == firstOption.craftId, "craftType mismatch")

    -- Invalid recipe key rejected
    local badOk = Planner.Commands:SelectRecipe("non_existent_recipe_key_99999")
    assert(badOk == false, "invalid recipe key should be rejected")
end)

Test("C4: Recipe search via FindRecipes(keyword)", function()
    assert(type(Planner.Commands.FindRecipes) == "function", "FindRecipes command missing")

    -- Search all
    local all = Planner.Commands:FindRecipes("")
    assert(type(all) == "table" and #all > 0, "empty search should return all recipes")

    -- Search by keyword from first item name
    local first = all[1]
    local keyword = first.name:sub(1, 4)
    local filtered = Planner.Commands:FindRecipes(keyword)
    assert(type(filtered) == "table" and #filtered > 0, "search by keyword should find matches")

    -- Search by craftId
    local byId = Planner.Commands:FindRecipes(tostring(first.craftId))
    assert(#byId >= 1, "search by craftId should find record")
    assert(byId[1].craftId == first.craftId, "craftId mismatch in result")

    -- Search by productItemId if available
    if first.productItemId then
        local byItemId = Planner.Commands:FindRecipes(tostring(first.productItemId))
        assert(#byItemId >= 1, "search by productItemId should find record")
    end
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

    Planner.State.craftType = 101
    Planner.State.itemType = nil
    Planner.State.selectedRecipeKey = nil
    Planner:AcquireConsumer("test_c5")
    local ok = Planner:Refresh("test_held_counts")
    assert(ok == true, "Planner:Refresh failed")

    local proj = Planner:GetProjection()
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
    Planner:ReleaseConsumer("test_c5")
end)

Test("C6: Known-record recursive graph and cycle prevention", function()
    assert(type(S.BuildCraftRecipeGraph) == "function", "BuildCraftRecipeGraph missing")

    -- Recipe 1: produces item 1001, requires item 1002 (count 2)
    -- Recipe 2: produces item 1002, requires item 1003 (count 3)
    local records = {
        {
            craftType = 1,
            product = { items = { { itemType = 1001, count = 1 } } },
            materials = { items = { { itemType = 1002, count = 2 } } },
        },
        {
            craftType = 2,
            product = { items = { { itemType = 1002, count = 1 } } },
            materials = { items = { { itemType = 1003, count = 3 } } },
        },
    }

    local graph = S.BuildCraftRecipeGraph(records, { { itemType = 1001, quantity = 1 } })
    assert(graph ~= nil, "graph creation failed")
    assert(graph.diagnostics.nodes >= 3, "graph should contain at least 3 nodes (1001, 1002, 1003)")
    assert(graph.diagnostics.edges >= 2, "graph should contain at least 2 edges")
    assert(graph.diagnostics.cycles == 0, "clean graph should have 0 cycles")

    -- Cyclic recipe: Recipe 1 requires 2002, Recipe 2 requires 2001 (A -> B -> A)
    local cyclicRecords = {
        {
            craftType = 10,
            product = { items = { { itemType = 2001, count = 1 } } },
            materials = { items = { { itemType = 2002, count = 1 } } },
        },
        {
            craftType = 20,
            product = { items = { { itemType = 2002, count = 1 } } },
            materials = { items = { { itemType = 2001, count = 1 } } },
        },
    }
    local cyclicGraph = S.BuildCraftRecipeGraph(cyclicRecords, { { itemType = 2001, quantity = 1 } })
    assert(cyclicGraph ~= nil, "cyclicGraph creation failed")
    assert(cyclicGraph.diagnostics.cycles > 0, "cycle should be detected and logged")
    assert(cyclicGraph.diagnostics.status == "partial", "cyclic graph status must be partial")
end)

Test("C7: Multi-recipe plan lifecycle", function()
    local options = Planner:GetProjection().recipeOptions
    assert(#options >= 2, "need at least 2 recipes for plan testing")
    local r1, r2 = options[1].value, options[2].value

    -- Clear plan first
    Planner.Commands:ClearPlan()
    local proj0 = Planner:GetProjection()
    assert(proj0.planRecipeCount == 0, "plan should be empty initially")

    -- Add recipe 1 with quantity 2
    local ok1, err1 = Planner.Commands:AddPlanRecipe(r1, 2)
    assert(ok1 == true, "AddPlanRecipe 1 failed: " .. tostring(err1))

    -- Add recipe 1 again with quantity 3 (should merge to 5)
    local ok2 = Planner.Commands:AddPlanRecipe(r1, 3)
    assert(ok2 == true, "AddPlanRecipe merge failed")
    local proj1 = Planner:GetProjection()
    assert(proj1.planRecipeCount == 1, "planRecipeCount should be 1 after merge")
    assert(proj1.planRecipeRows[1].quantity == 5, "quantity should be merged to 5, got: " .. tostring(proj1.planRecipeRows[1].quantity))

    -- Add recipe 2 with quantity 1
    local ok3 = Planner.Commands:AddPlanRecipe(r2, 1)
    assert(ok3 == true, "AddPlanRecipe 2 failed")
    local proj2 = Planner:GetProjection()
    assert(proj2.planRecipeCount == 2, "planRecipeCount should be 2")

    -- Set quantity of recipe 1 to 10
    local ok4 = Planner.Commands:SetPlanRecipeQuantity(r1, 10)
    assert(ok4 == true, "SetPlanRecipeQuantity failed")
    local proj3 = Planner:GetProjection()
    assert(proj3.planRecipeRows[1].quantity == 10, "quantity should be updated to 10")

    -- Remove recipe 1
    local ok5 = Planner.Commands:RemovePlanRecipe(r1)
    assert(ok5 == true, "RemovePlanRecipe failed")
    local proj4 = Planner:GetProjection()
    assert(proj4.planRecipeCount == 1, "planRecipeCount should be 1 after remove")
    assert(proj4.planRecipeRows[1].recipeKey == r2, "remaining recipe mismatch")

    -- Clear plan
    local ok6 = Planner.Commands:ClearPlan()
    assert(ok6 == true, "ClearPlan failed")
    local proj5 = Planner:GetProjection()
    assert(proj5.planRecipeCount == 0, "plan should be 0 after clear")
end)

Test("C8: Price quote queue integration", function()
    -- Set mock PriceQuoteQueueV3
    local quoteCalls = {}
    S.Services.PriceQuoteQueueV3 = {
        maxQueue = 64,
        GetPriceByItemType = function(_, itemType, itemGrade)
            if itemType == 18888 then return 100 end
            return nil
        end,
        RequestQuote = function(self, tag, itemType, itemGrade, cb)
            quoteCalls[#quoteCalls + 1] = { tag = tag, itemType = itemType, itemGrade = itemGrade }
            if cb then cb() end
            return true
        end,
    }

    -- Refreshing does NOT call RequestQuote (zero auction spam during refresh)
    Planner:Refresh("test_pricing_refresh")
    assert(#quoteCalls == 0, "ordinary Refresh must not issue RequestQuote")

    -- Add a recipe and check material quoting
    local options = Planner:GetProjection().recipeOptions
    Planner.Commands:AddPlanRecipe(options[1].value, 1)

    local proj = Planner:GetProjection()
    assert(type(proj.planMaterialRows) == "table", "planMaterialRows missing")

    -- Trigger explicit QuotePlanMaterials
    local quoteOk, quoteMsg, reqCount = Planner.Commands:QuotePlanMaterials()
    if proj.planPendingQuoteCount > 0 then
        assert(quoteOk == true, "QuotePlanMaterials failed: " .. tostring(quoteMsg))
        assert(#quoteCalls > 0, "RequestQuote should have been called")
    end

    Planner.Commands:ClearPlan()
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

Test("C10: FoundationGate contracts", function()
    local gate = S.FoundationGate
    assert(gate ~= nil, "FoundationGate missing")

    -- Test v3_craft_user_selection_contract
    assert(Planner.CraftUserSelectionContractVersion >= 1, "Planner CraftUserSelectionContractVersion missing")
    assert(Assist.CraftUserSelectionContractVersion >= 1, "Assist CraftUserSelectionContractVersion missing")
    assert(type(Planner.Commands.SelectRecipe) == "function", "Planner SelectRecipe missing")
    assert(type(Assist.Commands.SelectRecipe) == "function", "Assist SelectRecipe missing")

    -- Test v3_craft_plan_contract
    assert(Planner.CraftPlanContractVersion >= 1, "CraftPlanContractVersion missing")
    assert(type(Planner.Commands.AddPlanRecipe) == "function", "AddPlanRecipe missing")
    assert(type(Planner.Commands.RemovePlanRecipe) == "function", "RemovePlanRecipe missing")
    assert(type(Planner.Commands.ClearPlan) == "function", "ClearPlan missing")
    assert(type(Planner.Commands.QuotePlanMaterials) == "function", "QuotePlanMaterials missing")

    -- Test v3_craft_sidecar_contract
    assert(Surface.version >= 1, "Surface version missing")
    assert(Surface.VisibilityContractVersion >= 1, "Surface VisibilityContractVersion missing")
    assert(type(Surface.GetSnapshot) == "function", "Surface GetSnapshot missing")
    assert(type(Surface.Start) == "function", "Surface Start missing")
    assert(type(Surface.Stop) == "function", "Surface Stop missing")
    assert(Sidecar ~= nil, "CraftSidecar missing")
    assert(Assist.CraftSidecarContractVersion >= 1, "CraftSidecarContractVersion missing")
    assert(type(Assist.Commands.SetAutoSidecar) == "function", "SetAutoSidecar missing")
end)

print(string.format("\nCraft Planner & Assist Test Results: %d/%d passed", passed, total))
if passed == total then
    print("ALL TESTS PASSED!")
else
    print("SOME TESTS FAILED!")
    os.exit(1)
end
