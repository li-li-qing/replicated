-- Replicated Suite · 制作计划测试
-- 作者：Replicated
-- QQ群：1104129461
-- 检查当前 tools_craft 的配方选择、材料缺口、共享询价和制作窗口观察。
-- 未知窗口几何必须拒绝定位，旧制作规划功能不应重新加载。
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

-- 为伴随浮窗和页面提供 RSUI、UIV3 宿主测试替身。
S.UIV3 = S.UIV3 or {}
S.UIV3.WidgetHost = {
    Register = function(self, id, spec) return true end,
    BindFeatureLifecycle = function(self, id, options) return true end,
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

-- 提供 FeatureRuntime 测试替身。
S.FeatureRuntime = S.FeatureRuntime or {}
S.FeatureRuntime.IsEnabled = function(_, id) return true end
S.FeatureRuntime.IsImplemented = function(_, id) return true end
S.FeatureRuntime.SetPreferredEnabled = function(_, id, v) return true end

-- 按依赖顺序加载制作服务和功能。
dofile("services/rs_craft_surface_v3.lua")
-- 复现 toc.g 顺序，先加载通用装配骨架。
dofile("features/shared/rs_feature_slice_factory.lua")
dofile("features/shared/rs_shared_bounds.lua")
dofile("features/tools/auction/rs_auction_read_model.lua")
-- bridge 已退役；按 toc.g 顺序加载本套件需要的 Feature。
dofile("features/tools/craft/rs_craft_feature.lua")
-- tools_craft 已从 bridge 拆出；按 toc.g 顺序加载它。
dofile("features/life/craft/rs_craft_assistant_surface_extension_v3.lua")
dofile("presentation/v3/widgets/rs_v3_craft_sidecar.lua")

local Assist = S.Features and S.Features.tools_craft
local Surface = S.Services and S.Services.CraftSurfaceV3
local Sidecar = S.UIV3 and S.UIV3.CraftSidecar

Test("C1: Feature metadata and removed planner contract", function()
    -- 制作规划删除必须是真删除：Registry/Feature 都不存在；
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

    -- 修改原生状态的写接口必须被拒绝。
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

    -- 选择第一个制作配方。
    local ok, err = Assist.Commands:SelectRecipe(firstOption.value)
    assert(ok == true, "SelectRecipe failed: " .. tostring(err))

    local proj = Assist:GetProjection()
    assert(proj.selectedRecipeKey == firstOption.value, "selectedRecipeKey mismatch")
    assert(Assist.State.craftType == firstOption.craftId, "craftType mismatch")

    -- 拒绝无效配方键。
    local badOk = Assist.Commands:SelectRecipe("non_existent_recipe_key_99999")
    assert(badOk == false, "invalid recipe key should be rejected")
end)

-- 检查玩家实际选择/显示的文本，防止共享地区表改好后 UI 私有副本仍串区。
Test("C4: Shared region labels and selected recipe display agree", function()
    assert(Assist:AcquireConsumer("test_region_labels"))
    local expected = {[6245]="棋盘石林", [6244]="哈里洛废墟", [6243]="草原之脉", [9332]="青铜岩石山", [9336]="太初之地", [9340]="西风脊"}
    local found = 0
    for _, option in ipairs(Assist:GetProjection().recipeOptions) do
        local zoneName = expected[option.craftId]
        if zoneName then
            assert(option.text == zoneName .. " · 特产", "wrong localized choice for " .. option.craftId .. ": " .. tostring(option.text))
            assert(Assist.Commands:SelectRecipe(option.value))
            local current
            for _, row in ipairs(Assist:GetProjection().rows or {}) do if row.key == "craft:resolution" then current = row end end
            assert(current and current.text == option.text, "selected recipe display must share the same region identity")
            found = found + 1
        end
    end
    assert(found == 6, "all corrected regions must remain selectable")
    Assist:ReleaseConsumer("test_region_labels")
end)

Test("C5: Backpack held counts and shortage calculation", function()
    -- 为 X2Bag 替身配置指定物品。
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

    -- 配置 X2Craft 测试替身。
    _G.X2Craft = {
        GetCraftBaseInfo = function(_, craftType)
            return { name = "测试配方", actability = 10 }
        end,
        GetCraftProductInfo = function(_, craftType)
            return { { itemType = 99999, count = 1 } }
        end,
        GetCraftMaterialInfo = function(_, craftType, doodadId)
            return {
                { itemType = 18888, count = 30 }, -- 持有 25，缺口应为 5。
                { itemType = 18889, count = 5 },  -- 持有 5，缺口应为 0。
                { itemType = 18890, count = 10 }, -- 持有 0，缺口应为 10。
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
    -- 提供 ADDON 测试替身。
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

    -- 情形 A：有几何返回，但 Content 和可见性均为 nil；不能仅凭几何判断窗口打开。
    returnContent = false
    contentVisible = false
    mainScriptVisible = nil
    local snapA = Surface:_Read()
    assert(snapA.visible == false, "Geometry-only without visibility fact must fail closed")
    assert(snapA.source == "geometry-only" or snapA.status == "unknown", "source should indicate geometry-only, got: " .. tostring(snapA.source))

    -- 情形 B：Content 明确可见时，状态为已就绪且可见。
    returnContent = true
    contentVisible = true
    local snapB = Surface:_Read()
    assert(snapB.visible == true, "Positive content visibility must yield visible = true")
    assert(snapB.status == "ready", "status should be ready")

    -- 情形 C：MainScript 可见性为布尔 true 时，状态为已就绪且可见。
    contentVisible = false
    mainScriptVisible = true
    local snapC = Surface:_Read()
    assert(snapC.visible == true, "Boolean visible = true from mainscript must yield visible = true")

    -- 情形 D：MainScript 可见性为 false 时，visible 必须为 false。
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

Test("C11: Craft plan editor survives strict PageHost construction", function()
    -- 普通布局宿主会允许可选组件返回 nil；生产 PageHost 的严格事务必须一起保留。
    local host = dofile("tools/rs_gear_page_test_host.lua")({})
    local suite = host.S
    dofile("ui/framework/rs_ui_forms.lua")
    dofile("features/tools/craft/rs_craft_plan_domain.lua")
    dofile("presentation/v3/widgets/rs_v3_craft_plan_editor.lua")
    local domain = suite.CraftPlanDomain
    local target = { itemType = 8337, name = "合成测试物品", count = 2 }
    local evaluation = domain.Evaluate({ targets = { target } }, { inventoryComplete = false })
    local projection = { plan = {
        revision = 1, sessionRevision = 1, activeId = "p1", name = "测试计划",
        plans = {{ value = "p1", text = "测试计划" }},
        targets = {{ id = "t1", key = domain.Key(target), count = 2 }},
        catalog = {}, recipeCatalog = {}, recipes = {}, choices = {}, allocations = {}, evaluation = evaluation,
    }}
    local feature = { Commands = {}, GetProjection = function() return projection end }
    local external = host.Native(nil, "craft_strict_external", 0, 0, 820, 1800)
    local parent = assert(suite.RSUI:VerticalBox({ id = "craft_strict_parent", parent = external }))
    local built, editor, buildErr = suite.RSUI:WithBuildScope("page:tools.craft_assist", function()
        return suite.UIV3.CreateCraftPlanEditor(parent, feature)
    end)
    assert(built and editor, tostring(buildErr))
    assert(editor:Refresh(projection))
    local seen, selector = {}, nil
    local function Visit(component)
        assert(not seen[component.id], "duplicate logical component id: " .. component.id)
        seen[component.id] = true
        if component.id == "craft_plan_view" then selector = component end
        for _, child in ipairs(component.children or {}) do Visit(child) end
    end
    Visit(editor.root)
    assert(selector and selector.kind == "Dropdown", "view selector must actually be created")
    for _, width in ipairs({820, 680}) do
        external.width = width
        parent:Layout(0, 0, width, 1800)
    end
end)

Test("C12: Generic share and native quantities keep craft and item identities separate", function()
    local host = dofile("tools/rs_gear_page_test_host.lua")({})
    local suite = host.S
    dofile("core/rs_demand.lua")
    dofile("features/shared/rs_shared_bounds.lua")
    dofile("features/shared/rs_feature_slice_factory.lua")
    dofile("features/tools/craft/rs_craft_feature.lua")
    dofile("features/tools/craft/rs_craft_plan_domain.lua")
    local domain, feature = suite.CraftPlanDomain, suite.Features.tools_craft
    assert(domain.ParseRecipeShare("/rsrecipe |if7450;合成家具|r").craftType == 7450)
    assert(not domain.ParseRecipeShare("7450"), "bare item IDs must not be interpreted as craft IDs")
    assert(not domain.ParseRecipeShare("|if7450;家具|r |if7451;装备|r"), "ambiguous shares must be rejected")
    local outputCount, materialAmount = 3, 2
    suite.Api.CallCapability = function(_, capability)
        if capability == "X2Craft:GetCraftProductInfo" then return true, {itemType=90001, itemGrade=0, count=outputCount} end
        if capability == "X2Craft:GetCraftMaterialInfo" then
            return true, {{amount=materialAmount, count=200, item_info={itemType=90002, itemGrade=0, craftType=7452}}}
        end
        error("unexpected capability: " .. tostring(capability))
    end
    local recipe = assert(feature:ReadPlanRecipe(7450))
    assert(recipe.product.itemType == 90001 and recipe.product.count == 3)
    assert(recipe.product.grade == 0 and recipe.materials[1].grade == 0)
    assert(recipe.materials[1].count == 2 and recipe.materials[1].recipeHint == 7452,
        "inventory count must not become recipe amount; craftType is only a recipe hint")
    outputCount = nil
    assert(not feature:ReadPlanRecipe(7450), "unknown output yield must not default to one")
    local manual = assert(feature:ReadPlanRecipe(7450, {outputCount=5}))
    assert(manual.product.count == 5 and manual.outputSource == "manual")
    materialAmount = nil
    assert(not feature:ReadPlanRecipe(7450, {outputCount=5}), "held count cannot fill a missing recipe amount")
end)

Test("C13: Craft tools page exposes advanced settings and popup recovery", function()
    local host = dofile("tools/rs_gear_page_test_host.lua")({width=680, height=680})
    local suite = host.S
    dofile("ui/framework/rs_ui_forms.lua")
    dofile("features/rs_feature_registry.lua")
    dofile("features/tools/craft/rs_craft_plan_domain.lua")
    dofile("presentation/v3/widgets/rs_v3_craft_plan_editor.lua")
    local plan = {revision=1, activeId="p1", plans={{value="p1", text="家具计划"}}, targets={},
        catalog={}, recipes={}, choices={}, allocations={}, evaluation=suite.CraftPlanDomain.Evaluate({}, {})}
    local importedCount,screenVisible,resets,windowResets,laborValue=nil,true,0,0,nil
    suite.Features.tools_craft = {
        Commands={Refresh=function()error("generic page refresh must not read legacy craft context")end,
            PlanReceiveShare=function(_,count)importedCount=count;return true end,
            PlanSetLaborValue=function(_,value)laborValue=value;plan.laborValueCopper=value;return true end,
            SetScreenButtonVisible=function(_,value)screenVisible=value;return true end,
            ResetScreenButtonPosition=function()resets=resets+1;return true end},
        GetScreenButtonState=function()return {visible=screenVisible}end,
        GetProjection=function()return {plan=plan, rows={}, status="partial"}end,
        AcquireConsumer=function()return true end, ReleaseConsumer=function()return true end,
    }
    dofile("presentation/v3/pages/rs_v3_business_pages.lua")
    local external = host.Native(nil, "generic_craft_page_external", 0, 0, 680, 680)
    local built, page, buildErr = suite.RSUI:WithBuildScope("page:tools.craft_assist", function()
        return suite.UIV3.PageHost.factories["tools.craft_assist"](external, "tools.craft_assist")
    end)
    assert(built and page, buildErr)
    page:Refresh(); page:Layout(0, 0, 680, 680)
    local nodes = {}
    local function Visit(node)
        nodes[node.id] = node
        for _, child in ipairs(node.children or {}) do Visit(child) end
    end
    Visit(page)
    assert(nodes.craft_advanced_labor_value and not nodes.craft_plan_table,
        "the tools page must expose advanced settings rather than a second daily planner")
    local labor=nodes.craft_advanced_labor_value
    assert(labor.input:BeginEditing('labor_value'));labor.input.root.text='12'
    assert(labor.apply:Click() and laborValue==12)
    assert(nodes.craft_advanced_clear_labor:Click() and laborValue==nil)
    assert(nodes.v3_business_tools_craft_screen_button:SetValue(false) and screenVisible==false)
    assert(nodes.v3_business_tools_craft_screen_button:SetValue(true) and screenVisible==true)
    assert(nodes.v3_business_tools_craft_reset_button:Click() and resets==1)
    suite.UIV3.CraftSidecar={ResetPosition=function()windowResets=windowResets+1;return true end}
    assert(nodes.v3_business_tools_craft_reset_window:Click() and windowResets==1)
    assert(not nodes.v3_business_tools_craft_auto_sidecar and not nodes.craft_plan_add_selected)
    assert(not nodes.craft_plan_more_imports and not nodes.craft_plan_receive_share)
    assert(not nodes.v3_business_tools_craft_recipe_select)
    assert(page.tableView.visibility == "collapsed")
    assert(nodes.v3_business_tools_craft_hint.text:find("通用配方计划", 1, true))
    assert(nodes.v3_business_tools_craft_hint.text:find("O 自动入口不可用",1,true))
    assert(nodes.v3_business_tools_craft_header_action.onClick())
end)

Test("C14: One-click craft selection is explicit, visible and identity-checked", function()
    local host = dofile("tools/rs_gear_page_test_host.lua")({})
    local suite = host.S
    dofile("core/rs_demand.lua")
    dofile("features/shared/rs_shared_bounds.lua")
    dofile("features/shared/rs_feature_slice_factory.lua")
    dofile("features/tools/craft/rs_craft_feature.lua")
    dofile("features/tools/craft/rs_craft_plan_domain.lua")
    dofile("features/tools/craft/rs_craft_plan_feature.lua")
    dofile("services/rs_craft_surface_v3.lua")
    local feature, surface = suite.Features.tools_craft, suite.Services.CraftSurfaceV3
    local visible, detailVisible, displayed = true, true, 90001
    local content = {IsVisible=function()return visible end, detailPage={
        IsVisible=function()return detailVisible end,
        categoryList={GetSelectedValue=function()return 7450 end},
        productInfoFrame={item={info={itemType=displayed}}},
    }}
    local previousBook = UIC_CRAFT_BOOK
    local previousGetContent = ADDON.GetContent
    ADDON.GetContent=function()return content end
    UIC_CRAFT_BOOK = "synthetic_craft_book"
    local originalCall = suite.Api.CallCapability
    local contentReads = 0
    suite.Api.CallCapability = function(_, capability, object, method, ...)
        if capability == "ADDON:GetContent" then contentReads=contentReads+1;return true,content end
        if capability == "X2Unit:UnitNameWithWorld" then return true,"CraftSelectionTest@World" end
        if capability == "X2Craft:GetCraftProductInfo" then return true,{{itemType=90001,amount=3,item_name="合成家具"}} end
        if capability == "X2Craft:GetCraftMaterialInfo" then return true,{{amount=2,count=200,item_info={itemType=90002}}} end
        if capability == "X2Craft:GetCraftTypeByItemType" then return true,{} end
        return originalCall(suite.Api,capability,object,method,...)
    end
    feature.enabled=true;feature.consumerCount=1
    assert(contentReads==0)
    assert(feature.Commands:PlanImportSelected(7))
    local projection = feature:GetProjection().plan
    assert(projection.targets[1].itemType==90001 and projection.targets[1].count==7)
    assert(projection.recipes["7450"].product.count==3 and projection.recipes["7450"].product.name=="合成家具")
    visible=false;assert(not feature.Commands:PlanImportSelected(1));visible=true
    detailVisible=false;assert(not feature.Commands:PlanImportSelected(1));detailVisible=true
    content.detailPage.productInfoFrame.item.info.itemType=99999
    assert(not feature.Commands:PlanImportSelected(1),"mismatched displayed product must not enter the plan")
    assert(feature:GetProjection().plan.targets[1].count==7)
    feature.consumerCount=0
    local before=contentReads
    assert(not feature.Commands:PlanImportSelected(1) and contentReads==before,"released demand must prevent even UI reads")
    UIC_CRAFT_BOOK=previousBook
    ADDON.GetContent=previousGetContent
end)

Test("C15: Craft module export retains cached window evidence without probing Native", function()
    local host = dofile("tools/rs_gear_page_test_host.lua")({})
    local suite = host.S
    dofile("features/rs_feature_registry.lua")
    dofile("core/rs_diagnostic_detail.lua")
    dofile("core/rs_module_diagnostics.lua")
    dofile("services/rs_craft_surface_v3.lua")
    local nativeReads = 0
    ADDON.GetContent = function()nativeReads=nativeReads+1;return nil end
    ADDON.GetContentMainScriptPosVis = function()nativeReads=nativeReads+1;return nil,nil,nil,nil,nil end
    local oldBook, oldOrder, oldMake = UIC_CRAFT_BOOK, UIC_CRAFT_ORDER, UIC_MAKE_CRAFT_ORDER
    UIC_CRAFT_BOOK, UIC_CRAFT_ORDER, UIC_MAKE_CRAFT_ORDER = "test_book", "test_order", "test_make"
    local surface = suite.Services.CraftSurfaceV3
    assert(surface:Refresh("synthetic_observer", true))
    local feature = { Id="tools_craft", storeId="v3.business.tools_craft", enabled=true, consumerCount=1,
        State={autoSidecar=true}, Commands={}, GetProjection=function()error("diagnostics must not read a projection")end,
        Enable=function()return true end, Disable=function()return true end }
    suite.Features.tools_craft=feature
    suite.FeatureRuntime.implementations={tools_craft=feature}
    suite.FeatureRuntime.state={tools_craft={initialized=true,enabled=true}}
    dofile("features/life/craft/rs_craft_assistant_surface_extension_v3.lua")
    local beforeReads, beforeWrites, beforeStorage = nativeReads, host.writes, host.reads
    local report, err, exported = suite.ModuleDiagnosticsHub:BuildReport("tools_craft", {detailed=true})
    assert(report, err)
    assert(exported and exported:find("craft_surface_runtime",1,true))
    assert(exported:find("nil,nil,nil,nil,nil",1,true),"native shape must survive full TXT serialization")
    assert(exported:find("UIC_CRAFT_BOOK",1,true))
    assert(nativeReads==beforeReads and host.writes==beforeWrites and host.reads==beforeStorage,
        "diagnostic capture must not read Native, read stores or write preferences")
    local cached = surface:GetDiagnosticsSnapshot()
    cached.observation.candidates.UIC_CRAFT_BOOK.mainReturnTypes="changed"
    assert(surface:GetDiagnosticsSnapshot().observation.candidates.UIC_CRAFT_BOOK.mainReturnTypes=="nil,nil,nil,nil,nil")
    UIC_CRAFT_BOOK, UIC_CRAFT_ORDER, UIC_MAKE_CRAFT_ORDER=oldBook,oldOrder,oldMake
end)

Test("C16: One-shot own shares expire and remain owned when another consumer closes", function()
    local host = dofile("tools/rs_gear_page_test_host.lua")({})
    local suite = host.S
    dofile("core/rs_demand.lua")
    dofile("features/shared/rs_shared_bounds.lua")
    dofile("features/shared/rs_feature_slice_factory.lua")
    dofile("features/tools/craft/rs_craft_feature.lua")
    dofile("features/tools/craft/rs_craft_plan_domain.lua")
    dofile("features/tools/craft/rs_craft_plan_feature.lua")
    local feature = suite.Features.tools_craft
    feature.Authority.Refresh=function()return true end -- 本用例只测分享命令，原生材料形态另测。
    feature.ReadPlanRecipe=function(_,id)
        return {id=tostring(id),product={itemType=90001,count=3,name="合成家具"},materials={{itemType=90002,count=2}}}
    end
    feature.ReadPlanRecipeTypes=nil
    feature.enabled=true
    assert(feature:AcquireConsumer("page:tools_craft"))
    assert(feature:AcquireConsumer("widget:craft_sidecar"))
    local command = feature.Commands
    local originalCall = suite.Api.CallCapability
    suite.Api.CallCapability=function(_,capability,object,method,...)
        if capability=="X2Unit:UnitNameWithWorld" then return true,"GearTest@World" end
        if capability=="X2Unit:UnitName" then return true,"GearTest" end
        return originalCall(suite.Api,capability,object,method,...)
    end
    local function Count()return feature:GetProjection().plan.targets[1] and feature:GetProjection().plan.targets[1].count or 0 end
    assert(not command:PlanImportOwnChat("GearTest@World","|if7450;合成家具|r"))
    assert(command:PlanReceiveShare(4,nil,"widget:craft_sidecar"))
    assert(not command:PlanImportOwnChat("Other@World","|if7450;合成家具|r"))
    assert(not command:PlanImportOwnChat("GearTest@World","普通聊天") and Count()==0)
    assert(command:PlanImportOwnChat("GearTest@World","|if7450;合成家具|r") and Count()==4)
    assert(not command:PlanImportOwnChat("GearTest@World","|if7450;合成家具|r") and Count()==4)
    assert(command:PlanReceiveShare(1,nil,"widget:craft_sidecar"))
    assert(command:PlanCancelReceiveShare("page:tools_craft"))
    assert(feature:ReleaseConsumer("page:tools_craft"))
    assert(feature:GetProjection().plan.pendingShare,"closing another consumer must keep the receiver")
    assert(command:PlanCancelReceiveShare("widget:craft_sidecar"))
    assert(not feature:GetProjection().plan.pendingShare,"closing the initiating window must cancel at consumer count 1")
    assert(command:PlanReceiveShare(1,nil,"widget:craft_sidecar"))
    host.ms=host.ms+60001
    assert(not command:PlanImportOwnChat("GearTest@World","|if7450;合成家具|r") and Count()==4)
    assert(command:PlanReceiveShare(1,nil,"widget:craft_sidecar"))
    assert(command:PlanNew("新计划") and not feature:GetProjection().plan.pendingShare)
    assert(feature:ReleaseConsumer("widget:craft_sidecar"))
    assert(not feature:GetProjection().plan.shareCaptureActive)
end)

Test("C17: Manual window survives unknown native visibility and saved recipes can be added repeatedly", function()
    local host = dofile("tools/rs_gear_page_test_host.lua")({})
    dofile('ui/framework/rs_ui_forms.lua')
    local suite, spec, visible = host.S, nil, false
    local data={activeId="p1",contextRecipeOptions={{value="7450",text="合成家具"}},evaluation={rows={}}}
    local adds, cancelled = 0, nil
    suite.Features.tools_craft={Commands={
        PlanAddSavedRecipe=function(_,id,count)assert(id=="7450" and count==1);adds=adds+1;return true end,
        PlanCancelReceiveShare=function(_,owner)cancelled=owner;return true end,
    },GetProjection=function()return {plan=data}end}
    suite.UIV3.WidgetHost={Register=function(_,id,value)spec=value;return true end,
        BindFeatureLifecycle=function()return true end,IsVisible=function()return visible end,
        SetVisible=function(_,id,value)visible=value;return true end}
    suite.Services.CraftSurfaceV3={topic="v3.craft_surface.updated",GetSnapshot=function()return {status="unknown"}end}
    suite.RSUI.FloatingSurface={Create=function()
        local root=suite.RSUI:VerticalBox({id="craft_manual_window_test_root",parent=host.page})
        return {GetContentRoot=function()return root end,SetStatus=function()end,Show=function()return true end}
    end}
    dofile("presentation/v3/widgets/rs_v3_craft_sidecar.lua")
    assert(suite.UIV3.CraftSidecar:OpenManual() and visible)
    suite.Events:Publish("v3.craft_surface.updated",{status="unknown",visible=false})
    assert(visible,"unknown native windows must not revoke manual visibility")
    local ok,window,err=suite.RSUI:WithBuildScope("widget:tools.craft_sidecar",function()return spec.create()end)
    assert(ok and window,err)
    window:Refresh()
    assert(window.recipe:SetSelectedValue("7450",false,"dropdown") and adds==0)
    assert(window.addSaved.onClick() and window.addSaved.onClick())
    data.activeId="p2";window:Refresh();assert(window.addSaved.onClick())
    assert(adds==3,"Binding skipping the same selected value must not suppress explicit add actions")
    assert(window:Hide() and cancelled=="widget:craft_sidecar")
    assert(not suite.UIV3.CraftSidecar:Describe().manualVisible)
end)

Test("C18: Screen entry replaces native auto observation and preserves optional preferences transactionally", function()
    local host=dofile("tools/rs_gear_page_test_host.lua")({})
    local suite,starts=host.S,0
    dofile("core/rs_demand.lua")
    dofile("features/shared/rs_shared_bounds.lua")
    dofile("features/shared/rs_feature_slice_factory.lua")
    dofile("features/tools/craft/rs_craft_feature.lua")
    suite.Services.CraftSurfaceV3={Start=function()starts=starts+1;return true end,
        Stop=function()return true end,GetSnapshot=function()return {status="unknown"}end}
    dofile("features/life/craft/rs_craft_assistant_surface_extension_v3.lua")
    local feature=suite.Features.tools_craft
    assert(feature:Initialize())
    assert(feature:Enable("screen_entry_test"))
    assert(starts==0,"a stored autoSidecar=true must not restart the unusable native observer")
    assert(feature:GetProjection().nativeAutoEntryAvailable==false)
    assert(not feature.Commands:SetAutoSidecar(true))
    assert(type(feature.GetScreenButtonState)=="function" and feature:GetScreenButtonState().visible)
    local store=suite.Persistence:GetStore(feature.storeId)
    assert(store.get().screenButtonVisible==nil,"existing canonical preferences must not gain a default field")
    assert(feature.Commands:SetScreenButtonVisible(false))
    assert(not feature:GetScreenButtonState().visible)
    host.failSave=true
    assert(not feature.Commands:SetScreenButtonVisible(true))
    assert(not feature:GetScreenButtonState().visible,"refused save must keep the old visible preference")
    host.failSave=false
    assert(feature.Commands:SetScreenButtonVisible(true))
    assert(feature:GetScreenButtonState().visible and store.get().screenButtonVisible==nil)
end)

Test("C19: Screen button uses WidgetHost lifecycle and opens the manual window without acquiring demand", function()
    local host=dofile("tools/rs_gear_page_test_host.lua")({})
    local suite,enabled=host.S,true
    local preference={visible=true}
    local opens,saves=0,0
    suite.FeatureRuntime.IsEnabled=function()return enabled end
    suite.Features.tools_craft={Initialize=function()return true end,Commands={
        SetScreenButtonPosition=function(_,x,y,w,h)
            saves=saves+1;preference.placement={userMoved=true,x=x,y=y,coordinateSpace='logical-free-v2'};return true
        end},GetScreenButtonState=function()return host.Copy(preference)end,
        AcquireConsumer=function()error('the idle entry must not acquire crafting demand')end}
    suite.Layout={ResolvePlacement=function(_,p,w,h,x,y)
        return p and p.x or x,p and p.y or y,w,h,{source=p and 'saved' or 'default'}
    end}
    suite.RSUI.Windowing={Attach=function(_,spec)
        return {CancelInteraction=function()return true end,IsInteracting=function()return false end,
            spec=spec}
    end,ApplyGeometry=function(_,native,owner,x,y,w,h)
        native.x,native.y,native.width,native.height=x,y,w,h;return true
    end}
    suite.UIV3.CraftSidecar={OpenManual=function()opens=opens+1;return true end}
    dofile('presentation/v3/widgets/rs_v3_widget_host.lua')
    dofile('presentation/v3/widgets/rs_v3_craft_entry.lua')
    local widgetHost=suite.UIV3.WidgetHost
    assert(widgetHost:IsVisible('tools.craft.entry'),'enabled feature must show its button without opening a page')
    local entry=widgetHost:GetInstance('tools.craft.entry')
    assert(entry and entry.open:Click() and opens==1)
    assert(entry.dragHandle.root:GetParent()==entry.open.root,'drag handle must remain inside the screen button')
    assert(entry.windowController.spec.onGeometryChanged(entry.windowController,400,200,112,28))
    assert(saves==1 and preference.placement.x==400)
    suite.Events:Publish('v3.craft.entry.changed','craft_screen_button_position')
    assert(entry.open.root.x==400 and entry.open.root.y==200)
    enabled=false;suite.Events:Publish('v3.feature.lifecycle','tools_craft','disabled','test')
    assert(not widgetHost:IsVisible('tools.craft.entry'))
    enabled=true;suite.Events:Publish('v3.feature.lifecycle','tools_craft','enabled','test')
    assert(widgetHost:IsVisible('tools.craft.entry') and entry.open:Click() and opens==2)
    preference.visible=false;suite.Events:Publish('v3.craft.entry.changed','craft_screen_button_visible')
    assert(not widgetHost:IsVisible('tools.craft.entry'))
    preference.visible=true;suite.Events:Publish('v3.craft.entry.changed','craft_screen_button_visible')
    assert(widgetHost:IsVisible('tools.craft.entry'))
end)

Test("C20: Real Layout position intent survives durable save, rejection and cold reload", function()
    local viewport=dofile('tools/rs_window_viewport_test_host.lua')({layoutOnly=true})
    local layout=viewport.S.Layout
    local function Load(disk)
        local host=dofile('tools/rs_gear_page_test_host.lua')({disk=disk})
        local suite=host.S;suite.Layout=layout
        dofile('core/rs_demand.lua')
        dofile('features/shared/rs_shared_bounds.lua')
        dofile('features/shared/rs_feature_slice_factory.lua')
        dofile('features/tools/craft/rs_craft_feature.lua')
        suite.Services.CraftSurfaceV3={Stop=function()return true end,GetSnapshot=function()return {}end}
        dofile('features/life/craft/rs_craft_assistant_surface_extension_v3.lua')
        assert(suite.Features.tools_craft:Initialize())
        return host,suite.Features.tools_craft
    end
    local host,feature=Load()
    local ok,why=feature.Commands:SetScreenButtonPosition(400,200,112,28)
    assert(ok,why)
    local position=feature:GetScreenButtonState().placement
    assert(position.userMoved and position.coordinateSpace=='logical-free-v2' and position.x==400 and position.y==200)
    host.failSave=true
    assert(not feature.Commands:SetScreenButtonPosition(600,300,112,28))
    assert(feature:GetScreenButtonState().placement.x==400,'refused position save must roll back the old intent')
    host.failSave=false
    local nextHost,nextFeature=Load(host.disk)
    assert(nextFeature:GetScreenButtonState().placement.x==400,'cold reload must restore the committed position')
    assert(nextFeature.Commands:ResetScreenButtonPosition())
    assert(nextFeature:GetScreenButtonState().placement==nil)
    local resetHost,resetFeature=Load(nextHost.disk)
    assert(resetFeature:GetScreenButtonState().placement==nil,'reset must survive cold reload')
    local window={width=360,height=430,locked=false,userMoved=true}
    layout:StorePlacementRect(window,200,120,360,430,{mode='strict'})
    assert(resetFeature.Commands:SetCraftWindowState(window))
    resetHost.failSave=true;window.locked=true
    assert(not resetFeature.Commands:SetCraftWindowState(window))
    assert(resetFeature:GetCraftWindowState().locked==false,'window state must roll back a refused durable save')
    resetHost.failSave=false
    local windowHost,windowFeature=Load(resetHost.disk)
    local savedWindow=windowFeature:GetCraftWindowState()
    assert(savedWindow.coordinateSpace=='logical-edge-v1' and savedWindow.offsetX==window.offsetX and savedWindow.offsetY==window.offsetY)
    savedWindow.offsetX=9999
    assert(windowFeature:GetCraftWindowState().offsetX==window.offsetX,'window state getter must return a detached value')
    assert(windowFeature.Commands:ResetCraftWindowState())
    local _,windowResetFeature=Load(windowHost.disk)
    assert(windowResetFeature:GetCraftWindowState()==nil,'window reset must survive cold reload')
end)

print(string.format("\nCraft Assist Test Results: %d/%d passed", passed, total))
if passed == total then
    print("ALL TESTS PASSED!")
else
    print("SOME TESTS FAILED!")
    os.exit(1)
end
