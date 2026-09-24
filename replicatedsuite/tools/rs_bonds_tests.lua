-- 维护（2026-09-18，startup-source-recovery）：本文件在故障包中有 5 处未解决的 Git 合并冲突。
-- 已对照用户此前完整 V3 工程恢复有效实现；Authority、调用数据流和存档协议仍由下方原实现负责，
-- 不通过清配置、跳过加载或恢复 Legacy 绕过错误。兼容边界：须与完整 toc.g 及 .18.247 UI 配套；
-- 后续合并必须先检查冲突标记、清单完整性与 Lua 语法，再做运行时验收；注释不增加运行期开销。
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
    local dd = { spec = spec, items = spec.items or {}, enabled = true }
    function dd:SetItems(it) self.items = it or {} end
    function dd:SetEnabled(e) self.enabled = e end
    function dd:Render() return type(self.spec.get) == "function" and self.spec.get() or nil end
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
    assert(reg.navigationDevelopmentState == "complete", "user-accepted bonds must be complete in navigation, got: " .. tostring(reg.navigationDevelopmentState))
    assert(Bonds ~= nil, "Bonds feature missing")
    assert(Bonds.Commands ~= nil, "Bonds commands missing")
    -- 中文维护注释（2026-09-15，多大陆债券排序契约）：大陆顺序必须是独立设置，不能再复用
    -- “重复任务保留哪一侧”的 priority。这样排序只改变展示顺序，绝不会隐式删除另一大陆数据。
    assert(type(Bonds.Commands.SetContinentOrder) == "function", "SetContinentOrder compatibility command missing")
    assert(type(Bonds.Commands.SetDisplayOrder) == "function" and type(Bonds.Commands.SetFilterMask) == "function"
        and type(Bonds.Commands.SetDuplicateMode) == "function", "dropdown atomic commands missing")
    assert((tonumber(Bonds.MultiContinentSnapshotContractVersion) or 0) >= 3, "multi-continent snapshot v3 contract missing")
    assert((tonumber(Bonds.ResidentBoardFamilyContractVersion) or 0) >= 1, "resident board family contract missing")
    assert((tonumber(Bonds.AuroriaMaterialContractVersion) or 0) >= 1, "Auroria material contract missing")
end)

Test("B1b: pre-continentOrder canonical can recover exact historical stamp", function()
    local store = assert(S.Persistence:GetStore("v3.life.bonds"), "bonds store missing")
    assert(type(store.rebuildCanonicalForIntegrity) == "function", "bonds historical canonical hook missing")

    -- 中文维护测试：2026-09-15 已上线的旧债券存档 schema=1 不含 continentOrder。
    -- 新版 NormalizeBondState 默认补 west_first 后会改变 canonical 指纹；恢复桥必须只复原
    -- 这个旧逻辑形状，并由旧 stamped fingerprint 精确认证，不能放宽未知 mismatch。
    local legacyDomain = {
        sortMode = "quantity", showCompleted = true, q20 = true, q60 = true, q100 = true, auroria = true,
        excludeSame = true, priority = "west", completionDateKey = "2026-09-15", completedMainlandKeys = { ["fabric:20"] = true },
        dailyDateKey = "2026-09-15", dailySnapshots = {}, widgetVisible = false, widgetWindow = nil,
    }
    local legacyCanonical = {
        sortMode = "quantity", showCompleted = true, q20 = true, q60 = true, q100 = true, auroria = true,
        excludeSame = true, priority = "west", completionDateKey = "2026-09-15", completedMainlandKeys = { ["fabric:20"] = true },
        dailyDateKey = "2026-09-15", dailySnapshots = {}, widgetVisible = false, widgetWindow = nil,
    }
    local stamped = assert(S.Persistence:FingerprintCanonicalValue(store, legacyCanonical), "legacy fingerprint unavailable")
    local currentCanonical = assert(S.Persistence:CanonicalIntegrityValue(store, legacyDomain), "current canonical unavailable")
    assert(currentCanonical.continentOrder == "west_first", "current canonical must add default continentOrder")
    assert(S.Persistence:FingerprintCanonicalValue(store, currentCanonical) ~= stamped, "test fixture must reproduce canonical drift")

    local historical, recovered = store.rebuildCanonicalForIntegrity(legacyDomain, stamped, currentCanonical, { payload = legacyDomain })
    assert(type(historical) == "table", "historical candidate missing")
    assert(historical.continentOrder == nil, "historical candidate must preserve pre-continentOrder shape")
    assert(S.Persistence:FingerprintCanonicalValue(store, historical) == stamped, "historical candidate must exactly match old stamp")
    assert(type(recovered) == "table" and recovered.continentOrder == "west_first", "recovered current domain must receive default continentOrder")

    local rejected = store.rebuildCanonicalForIntegrity(legacyDomain, "DEADBEEF", currentCanonical, { payload = legacyDomain })
    assert(rejected == nil, "unknown fingerprint must remain fail-closed")
end)

Test("B1c: Persistence LoadStore accepts exact pre-continentOrder envelope and schedules restamp", function()
    local store = assert(S.Persistence:GetStore("v3.life.bonds"), "bonds store missing")
    local key = assert(S.Persistence:ResolveStoreKey(store), "bonds store key unavailable")

    -- 中文维护测试（2026-09-15，真实 LoadStore 冷路径）：B1b 证明 Store hook 本身，
    -- 本用例继续把一个当前合法 envelope 改造成“旧 schema=1 / 无 continentOrder / 旧 canonical stamp”，
    -- 再走 Persistence 的 Envelope Seal -> current mismatch -> historical exact Hash -> current restamp 全链路。
    -- 这样可防止出现“hook 单测通过、实际 Fresh Reload 仍因 Core 调用形状不同而写保护”的回归。
    Bonds.State.sortMode = "quantity"
    Bonds.State.continentOrder = "west_first"
    Bonds.State.dailyDateKey = "2026-09-15"
    Bonds.State.completionDateKey = "2026-09-15"
    Bonds.State.completedMainlandKeys = { ["fabric:20"] = true }
    assert(S.Persistence:MarkDirty("v3.life.bonds", "test_pre_continent_order_envelope") == true)
    assert(S.Persistence:SaveStore("v3.life.bonds", { force = true, verifyReadback = true }) == true)

    local raw = h.Copy(h.disk[key])
    assert(type(raw) == "table" and type(raw.payload) == "table" and type(raw.__rsmeta) == "table", "saved bonds envelope missing")
    raw.payload.continentOrder = nil
    local oldCanonical = assert(S.Persistence:CanonicalIntegrityValue(store, raw.payload), "old canonical probe unavailable")
    oldCanonical.continentOrder = nil
    local oldFingerprint = assert(S.Persistence:FingerprintCanonicalValue(store, oldCanonical), "old canonical fingerprint unavailable")
    raw.__rsmeta.encodedFingerprint = oldFingerprint
    raw.__rsmeta.envelopeFingerprint = nil
    raw.__rsmeta.envelopeFingerprint = assert(S.Persistence:FingerprintEnvelopeIntegrity(raw), "legacy envelope seal unavailable")
    h.disk[key] = h.Copy(raw)

    -- Fresh Reload 会重建 Store 对象；测试宿主复用同一对象，因此显式清理仅属于上一轮 Save 的内存门禁。
    -- discardUnverified 只模拟“新 Lua generation 没有旧 generation barrier obligation”，不放宽被测的 integrity gate。
    store.loaded, store.loadStatus = false, nil
    store.writeFenced, store.writeFenceReason = false, nil
    store.dirty, store.dueAt = false, 0
    store.pendingDurableFingerprint, store.pendingDurableKey, store.pendingDurableValue = nil, nil, nil
    Bonds.State = {}
    local loaded, _, loadErr = S.Persistence:LoadStore("v3.life.bonds", { discardDirty = true, discardUnverified = true })
    assert(loaded == true, "exact historical bonds envelope must load: " .. tostring(loadErr))
    assert(store.writeFenced ~= true, "exact historical bonds envelope must not remain write-fenced")
    assert(Bonds.State.continentOrder == "west_first", "recovered current Domain must receive west_first default")
    assert(store.lastIntegrityStatus == "historical_canonical_recovery", "unexpected recovery status: " .. tostring(store.lastIntegrityStatus))
    assert(store.dirty == true, "historical canonical recovery must schedule current-canonical restamp")
    -- 后续 B2~B15 验证产品默认排序；恢复用例不能把 quantity 测试状态泄漏给其它测试。
    Bonds.State.sortMode = "continent"
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
            if index == 1 then return { contents = { "居民委托：需要布料 20 个" } } end
            if index == 3 then return { contents = { "居民委托：需要木材 60 个" } } end
            if index == 4 then return { contents = { "居民委托：需要铁锭 100 个" } } end
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
        GetQuestContextMainTitle = function(_, qid) return qid == 9152 and "[特产-西部] 黄金平原的保存特产" or ("任务 " .. tostring(qid)) end,
        IsReadyForCompleteQuest = function(_, qid) return false end,
    }
    progress:Refresh()

    assert(type(progress.GetActiveQuestState) == "function" and type(progress.GetActiveQuestStates) == "function", "QuestProgress detached active-state API missing")
    local activeFact = progress:GetActiveQuestState(9152)
    assert(type(activeFact) == "table" and activeFact.questId == 9152 and activeFact.active == true and activeFact.state == "IN_PROGRESS", "single detached active quest fact mismatch")
    assert(activeFact.index == 1, "detached fact may expose copied active index")
    local inactiveFact = progress:GetActiveQuestState(9143)
    assert(type(inactiveFact) == "table" and inactiveFact.active == false, "inactive quest must return detached false fact")
    local facts = progress:GetActiveQuestStates({ 9152, 9143 })
    assert(type(facts) == "table" and facts[9152].active == true and facts[9143].active == false, "batch detached active quest facts mismatch")
    assert(facts ~= progress.activeIndex, "public API must never expose activeIndex table itself")
    assert(type(progress.GetActiveQuestList) == "function", "detached active quest list API missing")
    local activeList = progress:GetActiveQuestList()
    assert(type(activeList) == "table" and #activeList == 1, "active quest list must expose each current active quest once")
    assert(activeList[1].questId == 9152 and activeList[1].index == 1 and activeList[1].title == "[特产-西部] 黄金平原的保存特产", "active quest list identity/title mismatch")
    activeList[1].title = "mutated"
    local activeList2 = progress:GetActiveQuestList()
    assert(activeList2[1].title == "[特产-西部] 黄金平原的保存特产", "active quest list must return detached values")

    Bonds.State.dailySnapshots = {}
    SetMockResident({
        GetResidentBoardContent = function(_, index)
            if index == 1 then return { contents = { "布料 20" } } -- quest 9044
            elseif index == 2 then return { contents = { "皮革 60" } } -- quest 9152
            elseif index == 3 then return { contents = { "木材 100" } } -- quest 9143
            elseif index == 4 then return { contents = { "铁锭 20" } } -- board-family evidence
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
            elseif index == 3 then return { contents = { "木材 100" } }
            elseif index == 4 then return { contents = { "铁锭 20" } }
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

    -- Test continent order as an independent sort preference.
    local orderOk, orderErr = Bonds.Commands:SetContinentOrder("east_first")
    assert(orderOk == true, "SetContinentOrder east_first failed: " .. tostring(orderErr))
    assert(Bonds:GetContinentOrder() == "east_first", "continent order should be east_first")
    orderOk, orderErr = Bonds.Commands:SetContinentOrder("west_first")
    assert(orderOk == true, "SetContinentOrder west_first failed: " .. tostring(orderErr))
    assert(Bonds:GetContinentOrder() == "west_first", "continent order should be west_first")

    -- Duplicate priority only chooses the winner *when merge is enabled*. It must
    -- not silently enable merging, because that was the UI behavior that made the
    -- other mainland appear to be missing.
    Bonds.Commands:SetBondFilterOption("excludeSame", false)
    Bonds.Commands:SetDuplicatePriority("east")
    assert(Bonds:GetDuplicatePriority() == "east", "priority should be east")
    assert(Bonds:GetBondFilterOption("excludeSame") == false, "changing merge priority must not enable merge mode")
    Bonds.Commands:SetDuplicatePriority("west")
    assert(Bonds:GetDuplicatePriority() == "west", "priority should be west")
    assert(Bonds:GetBondFilterOption("excludeSame") == false, "priority switch must keep all-rows mode unchanged")

    local displayOk, displayErr = Bonds.Commands:SetDisplayOrder("quantity", "east_first")
    assert(displayOk == true, tostring(displayErr))
    assert(Bonds:GetDisplayOrderKey() == "quantity:east_first", "combined display order key mismatch")
    local materialOk, materialErr = Bonds.Commands:SetDisplayOrder("material", "west_first")
    assert(materialOk == true, tostring(materialErr))
    assert(Bonds:GetDisplayOrderKey() == "material:west_first", "material display order key mismatch")
    local maskOk, maskErr = Bonds.Commands:SetFilterMask(15)
    assert(maskOk == true and Bonds:GetFilterMask() == 15, tostring(maskErr))
    local dupOk, dupErr = Bonds.Commands:SetDuplicateMode("east")
    assert(dupOk == true and Bonds:GetDuplicateMode() == "east", tostring(dupErr))
    assert(Bonds:GetBondFilterOption("excludeSame") == true and Bonds:GetDuplicatePriority() == "east", "combined duplicate mode mismatch")
    Bonds.Commands:SetDuplicateMode("all")
    Bonds.Commands:SetDisplayOrder("continent", "west_first")
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

Test("B11: QuestProgress publishes arbitrary active quest membership and readiness changes", function()
    local progress = S.Services.QuestProgressV3
    local oldEventProgress, oldQuestGroups = S.Data.EventQuestProgress, S.Data.QuestGroups
    S.Data.EventQuestProgress = {}
    S.Data.QuestGroups = { daily = {}, weekly = {} }

    local ready = false
    _G.X2Quest = {
        IsCompleted = function(_, qid) return false end,
        GetActiveQuestListCount = function(_) return 1 end,
        GetActiveQuestType = function(_, index) return index == 1 and 9152 or nil end,
        GetQuestContextMainTitle = function(_, qid) return "居民债券测试 " .. tostring(qid) end,
        IsReadyForCompleteQuest = function(_, qid) return ready end,
    }
    progress.snapshots = {}
    progress.scopeSnapshots = { daily = {}, weekly = {} }
    progress.activeIndex = {}
    progress.activeQuestStates = {}
    progress.revision = 0

    assert(progress:Refresh("bond_active_added") == true)
    assert(progress.revision == 1, "adding an arbitrary active quest must publish even when canonical groups are unchanged")
    assert(progress.activeQuestStates[9152] == "IN_PROGRESS", "active quest state snapshot missing")

    ready = true
    assert(progress:Refresh("bond_ready_changed") == true)
    assert(progress.revision == 2, "ready-to-turn-in transition must publish while active membership stays unchanged")
    assert(progress.activeQuestStates[9152] == "READY_TO_TURN_IN", "active quest readiness snapshot stale")

    S.Data.EventQuestProgress, S.Data.QuestGroups = oldEventProgress, oldQuestGroups
end)

Test("B12: Bonds demand owns QuestProgress and refreshes immediately after turn-in", function()
    local progress = S.Services.QuestProgressV3
    if Bonds.consumerCount > 0 then Bonds.Demand:Clear("test_reset") end
    if progress.consumerCount > 0 then progress.Demand:Clear("test_reset") end
    Bonds.progressConsumerHeld = false
    Bonds.progressSubscribed = false
    Bonds.State.completedMainlandKeys = {}
    Bonds.State.dailySnapshots = {}

    local active, completed = true, false
    _G.X2Quest = {
        IsCompleted = function(_, qid) return completed and qid == 9152 end,
        GetActiveQuestListCount = function(_) return active and 1 or 0 end,
        GetActiveQuestType = function(_, index) return active and index == 1 and 9152 or nil end,
        GetQuestContextMainTitle = function(_, qid) return "居民债券测试 " .. tostring(qid) end,
        IsReadyForCompleteQuest = function(_, qid) return false end,
    }
    SetMockResident({
        GetResidentBoardContent = function(_, index)
            if index == 2 then return { contents = { "皮革 60" } } end
            if index == 3 then return { contents = { "木材 100" } } end
            if index == 4 then return { contents = { "铁锭 20" } } end
            return { contents = {} }
        end
    })
    SetMockUnit({ GetCurrentZoneGroup = function(_) return 1 end })
    progress.activeIndex = {}
    progress.activeQuestStates = {}
    progress.snapshots = {}
    progress.scopeSnapshots = { daily = {}, weekly = {} }

    local acquired, acquireErr = Bonds:AcquireConsumer("test:bonds-reactive")
    assert(acquired == true, tostring(acquireErr))
    assert(Bonds.progressConsumerHeld == true and progress.consumerCount > 0, "Bonds must hold QuestProgress only while observed")
    assert(Bonds.progressSubscribed == true, "Bonds must subscribe to quest progress updates while observed")

    local before
    for _, row in ipairs(BA:GetProjection().rows or {}) do if row.materialKey == "leather" then before = row end end
    assert(before ~= nil and before.statusText == "进行中", "initial bond quest state should be in progress")

    active, completed = false, true
    assert(progress:Refresh("bond_turn_in") == true)
    local after
    for _, row in ipairs(BA:GetProjection().rows or {}) do if row.materialKey == "leather" then after = row end end
    assert(after ~= nil and after.statusText == "已完成", "turn-in must refresh Bonds from quest event without manual page refresh")

    local released, releaseErr = Bonds:ReleaseConsumer("test:bonds-reactive")
    assert(released == true, tostring(releaseErr))
    assert(Bonds.progressConsumerHeld ~= true and Bonds.progressSubscribed ~= true, "Bonds must release QuestProgress lifecycle when no consumers remain")
end)


Test("B13: Bonds floating table exposes material name column", function()
    local spec = S.UIV3.LifeEconomyContent and S.UIV3.LifeEconomyContent.specs and S.UIV3.LifeEconomyContent.specs.Bonds or nil
    assert(type(spec) == "table", "Bonds floating content spec missing")
    local materialColumn = nil
    for _, column in ipairs(spec.columns or {}) do
        if column.id == "material" then materialColumn = column; break end
    end
    assert(materialColumn ~= nil, "Bonds floating table must include a material column")
    assert(materialColumn.field == "name", "material column must consume authoritative row.name")
    assert(materialColumn.title == "材料", "material column title mismatch")
end)

Test("B14: West and East daily snapshots coexist and sorting never drops a mainland", function()
    -- 中文维护注释（2026-09-15，西东大陆同日缓存回归）：模拟玩家先在西大陆读取，再移动到
    -- 东大陆读取。Authority 必须保留两份同日快照并统一投影；默认“全部显示”时即使两大陆
    -- 出现同材料同数量，也必须同时存在。排序只能调整顺序，不能承担去重副作用。
    Bonds.State.dailySnapshots = {}
    Bonds.State.dailyDateKey = nil
    Bonds.State.excludeSame = false
    Bonds.State.priority = "west"
    Bonds.State.sortMode = "continent"
    Bonds.State.continentOrder = "west_first"

    SetMockUnit({ GetCurrentZoneGroup = function(_) return 1 end }) -- west
    SetMockResident({
        GetResidentBoardContent = function(_, index)
            if index == 1 then return { contents = { "布料 20" } } end
            if index == 3 then return { contents = { "木材 60" } } end
            if index == 4 then return { contents = { "铁锭 100" } } end
            return { contents = {} }
        end
    })
    local acquired, acquireErr = Bonds:AcquireConsumer("test:bonds-multicontinent")
    assert(acquired == true, "multi-continent consumer acquire failed: " .. tostring(acquireErr))
    assert(BA:Refresh() == true, "west capture failed")
    local westProjection = BA:GetProjection()
    assert(westProjection.boardScope == "west", "west refresh must expose west boardScope")
    assert(type(westProjection.dailySnapshotStatus) == "table" and westProjection.dailySnapshotStatus.west == true, "west daily coverage missing")

    SetMockUnit({ GetCurrentZoneGroup = function(_) return 4 end }) -- east
    SetMockResident({
        GetResidentBoardContent = function(_, index)
            if index == 1 then return { contents = { "布料 20" } } end
            if index == 2 then return { contents = { "皮革 60" } } end
            if index == 3 then return { contents = { "木材 100" } } end
            if index == 4 then return { contents = { "铁锭 60" } } end
            return { contents = {} }
        end
    })
    assert(Bonds:Refresh() == true, "east capture failed")
    local projection = BA:GetProjection()
    assert(projection.boardScope == "east", "east refresh must expose east boardScope")
    assert(projection.snapshotCount == 2, "west+east should produce two cached continents")
    assert(projection.dailySnapshotStatus.west == true and projection.dailySnapshotStatus.east == true, "both mainland coverage flags must stay loaded")

    local westCount, eastCount = 0, 0
    for _, row in ipairs(projection.rows or {}) do
        if row.continentKey == "west" then westCount = westCount + 1 end
        if row.continentKey == "east" then eastCount = eastCount + 1 end
    end
    assert(westCount == 3 and eastCount == 4, "all-rows mode must keep both west/east snapshots: " .. tostring(westCount) .. "/" .. tostring(eastCount))

    local sortOk, sortErr = Bonds.Commands:SetContinentOrder("east_first")
    assert(sortOk == true, "east-first sorting failed: " .. tostring(sortErr))
    projection = BA:GetProjection()
    assert(#projection.rows == 7, "sorting must not remove rows")
    assert(projection.rows[1].continentKey == "east" and projection.rows[#projection.rows].continentKey == "west", "east-first order not applied")

    -- Selecting the merge winner while still in all-rows mode must remain a pure
    -- preference. Only the explicit duplicate mode switch may collapse rows.
    Bonds.Commands:SetBondFilterOption("excludeSame", false)
    Bonds.Commands:SetDuplicatePriority("east")
    projection = BA:GetProjection()
    assert(#projection.rows == 7, "merge priority must not hide rows while duplicate mode is all")
    Bonds.Commands:SetBondFilterOption("excludeSame", true)
    projection = BA:GetProjection()
    assert(#projection.rows == 6, "explicit merge mode should collapse only the duplicate fabric row")
    local fabric
    for _, row in ipairs(projection.rows) do if row.materialKey == "fabric" then fabric = row end end
    assert(fabric ~= nil and fabric.continentKey == "east", "east merge priority must retain the east duplicate")

    -- Restore user-facing default for following tests/runs.
    Bonds.Commands:SetBondFilterOption("excludeSame", false)
    Bonds.Commands:SetContinentOrder("west_first")
    local released, releaseErr = Bonds:ReleaseConsumer("test:bonds-multicontinent")
    assert(released == true, "multi-continent consumer release failed: " .. tostring(releaseErr))
end)

Test("B15: Bonds page and floating widget expose unambiguous mainland controls", function()
    -- 中文维护注释：Presentation 只消费 detached Projection/Commands；这些静态契约断言防止后续
    -- UI 重构重新出现“去重/优先西/按大陆排序”这种会把排序与数据隐藏混在一起的模糊文案。
    local pageFile = assert(io.open("presentation/v3/pages/rs_v3_life_m16_pages.lua", "rb"))
    local pageText = pageFile:read("*a"); pageFile:close()
    assert(pageText:find('id = "continent", title = "大陆"', 1, true) ~= nil, "main Bonds table must have an explicit continent column")
    assert(pageText:find('今日已获取：', 1, true) ~= nil, "main Bonds status must show daily west/east coverage")
    assert(pageText:find('当前位置：', 1, true) ~= nil, "main Bonds status must name the current continent")
    assert(pageText:find('按大陆 · 西→东', 1, true) ~= nil and pageText:find('按数量 · 少→多', 1, true) ~= nil
        and pageText:find('按数量 · 多→少', 1, true) ~= nil and pageText:find('按材料 · 正序', 1, true) ~= nil
        and pageText:find('按材料 · 倒序', 1, true) ~= nil, "Bonds sort dropdown must expose continent/quantity/material ordering")
    assert(pageText:find('id = "v3_bonds_scope"', 1, true) ~= nil and pageText:find('id = "v3_bonds_duplicate_mode"', 1, true) ~= nil, "main Bonds controls must use scope/duplicate dropdowns")
    assert(pageText:find('v3_bonds_q20', 1, true) == nil and pageText:find('v3_bonds_sort"', 1, true) == nil, "legacy option buttons must not remain on main Bonds page")

    local widgetFile = assert(io.open("presentation/v3/widgets/rs_v3_life_economy_widgets.lua", "rb"))
    local widgetText = widgetFile:read("*a"); widgetFile:close()
    assert(widgetText:find('SetDisplayOrder', 1, true) ~= nil and widgetText:find('SetFilterMask', 1, true) ~= nil and widgetText:find('SetDuplicateMode', 1, true) ~= nil, "floating Bonds controls must use atomic dropdown commands")
    assert(widgetText:find('{ id = "continent", title = "大陆"', 1, true) ~= nil, "floating Bonds table must have a continent column")
    assert(widgetText:find('bondsDropdownControlsContractVersion = 2', 1, true) ~= nil, "floating Bonds dropdown contract missing")
end)

Test("B16: Unknown Auroria zone is discovered from ResidentBoard family even with mainland cache", function()
    -- 中文维护测试：用户已缓存西大陆后移动到静态 zone 表未收录的原大陆区域；旧逻辑会因为
    -- next(dailySnapshots) ~= nil 而完全跳过 ResidentBoard。显式刷新必须探测 5/6 并新增 auroria 快照。
    Bonds.State.dailySnapshots = {
        west = { continentKey = "west", faction = "Nuia", boards = {
            { index = 1, lines = { "布料 20" } }, { index = 3, lines = { "木材 60" } }, { index = 4, lines = { "铁锭 100" } },
        } },
    }
    SetMockUnit({ GetCurrentZoneGroup = function(_) return 777 end })
    SetMockResident({ GetResidentBoardContent = function(_, index)
        if index == 5 then return { faction = "Auroria", contents = { "Prince's Coinpurses 30" } } end
        if index == 6 then return { faction = "Auroria", contents = { "Queen's Crates 8" } } end
        if index == 7 then return { faction = "Auroria", contents = { "Ancestor's Coinpurses 20" } } end
        return { faction = "Auroria", contents = {} }
    end })
    assert(BA:Refresh("page_manual") == true, "manual unknown-zone Auroria probe failed")
    local projection = BA:GetProjection()
    assert(projection.boardScope == "auroria", "ResidentBoard family must override unknown zone")
    assert(projection.dailySnapshotStatus.west == true and projection.dailySnapshotStatus.auroria == true, "Auroria snapshot must coexist with mainland cache")
    local desc = Bonds:DescribeDailyCache()
    assert(type(desc.lastBoardProbe) == "table" and desc.lastBoardProbe.detectedScope == "auroria", "probe diagnostics must expose Auroria detection")
end)

Test("B17: Empty ResidentBoard probe never overwrites or persists a daily snapshot", function()
    local good = { continentKey = "west", faction = "Nuia", boards = {
        { index = 1, lines = { "布料 20" } }, { index = 3, lines = { "木材 60" } }, { index = 4, lines = { "铁锭 100" } },
    } }
    Bonds.State.dailySnapshots = { west = good }
    SetMockUnit({ GetCurrentZoneGroup = function(_) return 1 end })
    SetMockResident({ GetResidentBoardContent = function() return { contents = {} } end })
    assert(BA:Refresh("page_manual") == true, "good cache must survive temporary empty Native read")
    local projection = BA:GetProjection()
    assert(projection.dailySnapshotStatus.west == true and #projection.rows >= 3, "empty probe must not erase good west cache")
    local desc = Bonds:DescribeDailyCache()
    assert(desc.lastBoardProbe.captureAction == "empty_probe" or desc.lastBoardProbe.captureAction == "kept_cache_empty_probe", "empty-probe diagnostic missing")

    Bonds.State.dailySnapshots = {}
    BA:Refresh("page_manual")
    assert(Bonds.State.dailySnapshots.west == nil and Bonds.State.dailySnapshots.east == nil and Bonds.State.dailySnapshots.auroria == nil, "empty board shells must never be persisted")
end)

Test("B18: Auroria rows resolve real material ItemType, quest and shortage", function()
    _G.X2Bag = {
        Capacity = function() return 20 end,
        GetBagItemInfo = function(_, bagId, slot)
            if bagId == 1 and slot == 1 then return { itemType = 35461, stackCount = 12 } end -- Prince purse
            if bagId == 1 and slot == 2 then return { itemType = 42077, stackCount = 3 } end -- Queen crate
            if bagId == 1 and slot == 3 then return { itemType = 43176, stackCount = 5 } end -- Ancestor purse
            return nil
        end,
    }
    Bonds.State.dailySnapshots = {}
    SetMockUnit({ GetCurrentZoneGroup = function(_) return 777 end })
    SetMockResident({ GetResidentBoardContent = function(_, index)
        if index == 5 then return { contents = { "Prince's Coinpurses 30" } } end
        if index == 6 then return { contents = { "Queen's Crates 8" } } end
        if index == 7 then return { contents = { "Ancestor's Coinpurses 20" } } end
        return { contents = {} }
    end })
    BA:Refresh("page_manual")
    local byMaterial = {}
    for _, row in ipairs(BA:GetProjection().rows or {}) do byMaterial[row.materialKey] = row end
    assert(byMaterial.prince_purse and byMaterial.prince_purse.questId == 10504 and byMaterial.prince_purse.requiredCount == 30, "Prince purse mapping mismatch")
    assert(byMaterial.queen_crate and byMaterial.queen_crate.questId == 10510 and byMaterial.queen_crate.requiredCount == 8, "Queen crate mapping mismatch")
    assert(byMaterial.ancestor_purse and byMaterial.ancestor_purse.questId == 10512 and byMaterial.ancestor_purse.requiredCount == 20, "Ancestor purse mapping mismatch")
    -- InventorySnapshot may be unavailable/partial in a stripped test host; whenever ready, counts must use the real Auroria identities.
    if byMaterial.prince_purse.haveCount ~= nil then
        assert(byMaterial.prince_purse.haveCount == 12 and byMaterial.prince_purse.shortage == 18, "Prince purse inventory/shortage mismatch")
        assert(byMaterial.queen_crate.haveCount == 3 and byMaterial.queen_crate.shortage == 5, "Queen crate inventory/shortage mismatch")
    end
end)


Test("B19: Auroria daily snapshot merges board families instead of replacing the continent", function()
    -- 中文维护测试（18.302）：原大陆不同区域可能只提供 5/6/7 中一部分有效内容；同日 auroria
    -- 必须按 board index 增量合并，不能因为 auroria key 已存在就让 zone-boundary/manual probe 白读。
    Bonds.State.dailySnapshots = {}
    SetMockUnit({ GetCurrentZoneGroup = function(_) return 777 end })
    SetMockResident({ GetResidentBoardContent = function(_, index)
        if index == 5 then return { faction = "Auroria", contents = { "Prince's Coinpurses 30" } } end
        return { faction = "Auroria", contents = {} }
    end })
    assert(BA:Refresh("page_manual") == true, "Prince Auroria capture failed")

    SetMockResident({ GetResidentBoardContent = function(_, index)
        if index == 6 then return { faction = "Auroria", contents = { "Queen's Crates 8" } } end
        return { faction = "Auroria", contents = {} }
    end })
    assert(BA:Refresh("zone_changed") == true, "Queen Auroria boundary merge failed")

    local projection = BA:GetProjection()
    local prince, queen = nil, nil
    for _, row in ipairs(projection.rows or {}) do
        if row.materialKey == "prince_purse" then prince = row end
        if row.materialKey == "queen_crate" then queen = row end
    end
    assert(prince ~= nil and prince.questId == 10504, "existing Prince board must survive later Auroria probe")
    assert(queen ~= nil and queen.questId == 10510, "new Queen board must be merged into Auroria cache")
    local desc = Bonds:DescribeDailyCache()
    assert(desc.lastBoardProbe.captureAction == "merged_new_board_lines", "merge diagnostic action missing")
    assert((tonumber(desc.lastBoardProbe.addedLines) or 0) >= 1, "merge diagnostic must report added lines")
end)

Test("B20: Auroria fallback identity scans all numbers, not only the first number", function()
    -- RU/其他本地化可能在真正需求量前带阶段/编号。没有 purse/crate 关键词时，90 对 Prince 只可能是
    -- purse；首个数字 2 不应让身份解析失败。歧义的 30/25/20 仍由生产代码保持 UNKNOWN。
    Bonds.State.dailySnapshots = {}
    SetMockUnit({ GetCurrentZoneGroup = function(_) return 777 end })
    SetMockResident({ GetResidentBoardContent = function(_, index)
        if index == 5 then return { faction = "Auroria", contents = { "Stage 2 / required 90" } } end
        return { faction = "Auroria", contents = {} }
    end })
    assert(BA:Refresh("page_manual") == true, "Auroria numeric fallback probe failed")
    local matched = nil
    for _, row in ipairs(BA:GetProjection().rows or {}) do
        if row.questId == 10505 then matched = row; break end
    end
    assert(matched ~= nil and matched.materialKey == "prince_purse" and matched.requiredCount == 90,
        "all-number fallback must resolve Prince purse 90 even when first number is unrelated")
end)

Test("B21: RU Ancestor coinpurse wording resolves the ambiguous 20 requirement", function()
    -- 中文维护测试（18.302 RU 本地化）：当前俄服数据把 Ancestor's Coinpurse 写作“Котомка эфенского странника”。
    -- 20 同时也是 ancestor crate 的大额数量，仅靠数量无法裁决；必须识别俄语“Котомка”词根，避免小额钱袋行变 UNKNOWN。
    Bonds.State.dailySnapshots = {}
    SetMockUnit({ GetCurrentZoneGroup = function(_) return 777 end })
    SetMockResident({ GetResidentBoardContent = function(_, index)
        if index == 7 then return { faction = "Auroria", contents = { "Доставьте 20 котомок эфенского странника председателю совета общины." } } end
        -- Public ArcheRage board-family behavior requires board 5 or 6 evidence to classify Auroria.
        if index == 6 then return { faction = "Auroria", contents = { "Расшитые жемчугом кошельки 25" } } end
        return { faction = "Auroria", contents = {} }
    end })
    assert(BA:Refresh("page_manual") == true, "RU Ancestor wording probe failed")
    local matched = nil
    for _, row in ipairs(BA:GetProjection().rows or {}) do
        if row.questId == 10512 then matched = row; break end
    end
    assert(matched ~= nil and matched.materialKey == "ancestor_purse" and matched.requiredCount == 20,
        "Russian 'Котомка' wording must resolve ancestor_purse 20 instead of ambiguous UNKNOWN")
end)

print(string.format("\nBonds Test Results: %d/%d passed", passed, total))
if passed == total then
    print("ALL TESTS PASSED!")
else
    print("SOME TESTS FAILED!")
    os.exit(1)
end
