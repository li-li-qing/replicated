------------------------------------------------------------------------
-- Replicated Suite V3 - Auction Workspace Services Tests
------------------------------------------------------------------------
unpack = unpack or table.unpack
local passed, total = 0, 0
local function Test(name, fn)
    total = total + 1
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; print(string.format("  PASS [%02d] %s", total, name))
    else print(string.format("  FAIL [%02d] %s: %s", total, name, tostring(err))) end
end

print("=== Replicated Suite: Auction Workspace Services Tests ===")
local h = dofile("tools/rs_gear_page_test_host.lua")({})
local S = h.S
_G.ReplicatedSuite = S
S.Services = S.Services or {}
dofile("core/rs_demand.lua")
dofile("data/rs_data_registry.lua")
dofile("data/ids/rs_item_ids.lua")
dofile("data/ids/rs_quest_ids.lua")
dofile("data/ids/rs_instance_ids.lua")
dofile("data/rs_quest_data.lua")

local activeQuestIds = {}
local activeQuestList = {}
local questConsumers = 0
S.Services.QuestProgressV3 = {
    AcquireConsumer = function(self) questConsumers = questConsumers + 1; return true end,
    ReleaseConsumer = function(self) questConsumers = math.max(0, questConsumers - 1); return true end,
    GetActiveQuestStates = function(self, ids)
        local out = {}
        for _, id in ipairs(ids or {}) do
            if activeQuestIds[id] then out[id] = { questId = id, active = true, state = "IN_PROGRESS", index = 1 } end
        end
        return out
    end,
    GetActiveQuestList = function(self)
        local out = {}
        for index, row in ipairs(activeQuestList or {}) do
            local copy = {}; for key, value in pairs(row) do copy[key] = value end
            copy.index = copy.index or index
            out[#out + 1] = copy
        end
        return out
    end,
}

local recipeMaterials = {}
S.GameIds = S.GameIds or {}
S.GameIds.Zone = S.GameIds.Zone or { ById = {} }
S.GameIds.Zone.ById[22] = { zoneId = 22, nameZh = "黄金平原", nameEn = "Halcyona", tradeQuality = "Preserved" }

S.Services.TradeMaterialIdentityV3 = {
    ResolveStatic = function(self, recipeName, originZoneId)
        local rows = recipeMaterials[recipeName]
        local label = recipeName
        if not rows and tonumber(originZoneId) == 22 and tostring(recipeName or ""):find("黄金平原", 1, true) then
            rows = recipeMaterials["Halcyona Preserved Specialty"]
            label = "Halcyona Preserved Specialty"
        end
        if not rows then return nil end
        local copy = {}; for i, row in ipairs(rows) do local r = {}; for k, v in pairs(row) do r[k] = v end; copy[i] = r end
        return { rows = copy, label = label, source = "test" }
    end,
    ResolveMaterialDisplayName = function(self, row) return tostring(row.displayName or row.materialKey or "材料") end,
}

-- Build representative fixture from real authoritative daily quest table.
local single, multi
for _, entry in ipairs(S.Data.DailyTradePackQuestRecipes or {}) do
    if #entry.recipes == 1 and not single then single = entry end
    if #entry.recipes > 1 and not multi then multi = entry end
end
assert(single and multi, "daily trade quest fixtures unavailable")
recipeMaterials[single.recipes[1]] = {
    { itemType = 1001, materialKey = "Lumber", displayName = "木材", count = 20, includeInCost = true },
    { itemType = 23633, materialKey = "Gilda Star", displayName = "德翡纳之星", count = 1, includeInCost = false },
}
recipeMaterials[multi.recipes[1]] = { { itemType = 1002, materialKey = "Iron", displayName = "铁锭", count = 10, includeInCost = true } }
recipeMaterials[multi.recipes[2]] = { { itemType = 1003, materialKey = "Fabric", displayName = "布料", count = 15, includeInCost = true } }
recipeMaterials["Halcyona Preserved Specialty"] = {
    { itemType = 1004, materialKey = "GroundGrain", displayName = "研磨谷物", count = 200, includeInCost = true },
    { itemType = 1005, materialKey = "HayBale", displayName = "干草捆", count = 5, includeInCost = true },
}

local dailyLoaded, dailyErr = pcall(dofile, "services/rs_daily_auction_materials_v3.lua")
local sessionLoaded, sessionErr = pcall(dofile, "services/rs_auction_session_list_v3.lua")

Test("daily service resolves single recipe and does not aggregate multi candidates", function()
    assert(dailyLoaded == true, "daily service failed to load: " .. tostring(dailyErr))
    local D = S.Services.DailyAuctionMaterialsV3
    assert(type(D) == "table" and type(D.AcquireConsumer) == "function")
    activeQuestIds = { [single.questId] = true, [multi.questId] = true }
    assert(D:AcquireConsumer("test:daily") == true)
    assert(questConsumers == 1, "daily demand must acquire exactly one QuestProgress consumer")
    assert(D:Refresh("test") == true)
    local snap = D:GetSnapshot()
    local byId = {}; for _, task in ipairs(snap.tasks or {}) do byId[task.questId] = task end
    assert(byId[single.questId] ~= nil and byId[single.questId].requiresSelection ~= true, "single recipe task must resolve immediately")
    assert(#(byId[single.questId].materials or {}) == 2, "single recipe materials missing")
    assert(byId[single.questId].materials[1].name == "木材" and byId[single.questId].materials[1].count == 20, "single material normalization mismatch")
    assert(byId[single.questId].materials[2].searchable == false, "non-auction recipe currency must not be searchable")
    assert(byId[multi.questId] ~= nil and byId[multi.questId].requiresSelection == true, "multi recipe task must require explicit selection")
    assert(#(byId[multi.questId].materials or {}) == 0, "multi recipe candidates must never be aggregated")
    assert(#(byId[multi.questId].recipes or {}) == #multi.recipes, "all candidates must remain selectable")
    assert(type(byId[multi.questId].recipeOptions) == "table" and #byId[multi.questId].recipeOptions == #multi.recipes, "daily candidate display options missing")
    assert(tostring(byId[multi.questId].recipeOptions[1].name or "") ~= tostring(multi.recipes[1]), "player-facing candidate label must not leak raw legacy recipe name")

    assert(D:SelectRecipe(multi.questId, multi.recipes[2]) == true)
    local selected = D:GetSnapshot(); local selectedTask
    for _, task in ipairs(selected.tasks or {}) do if task.questId == multi.questId then selectedTask = task end end
    assert(selectedTask and selectedTask.selectedRecipe == multi.recipes[2], "selected recipe must be session-authoritative")
    assert(#selectedTask.materials == 1 and selectedTask.materials[1].name == "布料", "only selected recipe materials may be exposed")

    local key = selectedTask.materials[1].key
    assert(D:SetMaterialHidden(multi.questId, multi.recipes[2], key, true) == true)
    local hidden = D:GetSnapshot(); for _, task in ipairs(hidden.tasks) do if task.questId == multi.questId then selectedTask = task end end
    assert(selectedTask.materials[1].hidden == true, "daily delete semantics must be session hide, not fact mutation")
    assert(D:RestoreHidden(multi.questId) == true)
    D:ReleaseConsumer("test:daily")
    assert(questConsumers == 0, "daily demand release must release QuestProgress consumer")
end)


Test("daily service discovers live localized trade-pack craft quest outside legacy quest-id table", function()
    local D = S.Services.DailyAuctionMaterialsV3
    activeQuestIds = {}
    activeQuestList = {
        { questId = 990001, active = true, state = "IN_PROGRESS", title = "[特产-西部] 黄金平原的保存特产", index = 1 },
    }
    assert(D:AcquireConsumer("test:title_discovery") == true)
    assert(D:Refresh("title_discovery") == true)
    local snap = D:GetSnapshot()
    local task
    for _, row in ipairs(snap.tasks or {}) do if row.questId == 990001 then task = row; break end end
    assert(task ~= nil, "localized active trade-pack quest must be discovered even when quest id is absent from legacy mapping")
    assert(task.discoverySource == "active_title", "discovered task must report title-based evidence source")
    assert(task.selectedRecipe == "Halcyona Preserved Specialty", "localized Halcyona title must resolve canonical trade recipe")
    assert(task.requiresSelection ~= true, "specific localized craft quest must not require unrelated candidate selection")
    assert(#(task.materials or {}) == 2 and task.materials[1].name == "研磨谷物", "discovered trade-pack materials missing")
    local diag = type(D.GetDiagnosticsSnapshot) == "function" and D:GetDiagnosticsSnapshot() or nil
    assert(type(diag) == "table" and tonumber(diag.titleMatchedCount) == 1, "daily diagnostics must expose title-discovery evidence")
    D:ReleaseConsumer("test:title_discovery")
    activeQuestList = {}
end)

Test("specific live trade-pack title overrides generic legacy quest-id candidate mapping", function()
    local D = S.Services.DailyAuctionMaterialsV3
    activeQuestIds = { [multi.questId] = true }
    activeQuestList = {
        { questId = multi.questId, active = true, state = "IN_PROGRESS", title = "[特产-西部] 黄金平原的保存特产", index = 1 },
    }
    assert(D:AcquireConsumer("test:title_override") == true)
    assert(D:Refresh("title_override") == true)
    local snap = D:GetSnapshot(); local task
    for _, row in ipairs(snap.tasks or {}) do if row.questId == multi.questId then task = row; break end end
    assert(task ~= nil and task.discoverySource == "active_title", "specific live title must override generic quest-id candidate table")
    assert(task.selectedRecipe == "Halcyona Preserved Specialty" and task.requiresSelection ~= true, "specific live title must resolve exactly one recipe")
    D:ReleaseConsumer("test:title_override")
    activeQuestIds, activeQuestList = {}, {}
end)

Test("session list provides non-persistent grouped CRUD and in-group itemType merge", function()
    assert(sessionLoaded == true, "session service failed to load: " .. tostring(sessionErr))
    local T = S.Services.AuctionSessionListV3
    assert(type(T) == "table" and type(T.AddTradeGroup) == "function")
    T:Clear("test")
    local ok, groupId = T:AddTradeGroup({
        source = "trade", sourceKey = "route:1", productName = "双冠丘陵货物",
        materials = {
            { itemType = 2001, name = "木材", count = 10 },
            { itemType = 2001, name = "木材", count = 15 },
            { itemType = 2002, name = "蜂蜜", count = 5 },
        },
    })
    assert(ok == true and tonumber(groupId), "AddTradeGroup failed")
    local snap = T:GetSnapshot()
    assert(#snap.groups == 1 and #snap.groups[1].materials == 2, "same itemType must merge only within one group")
    assert(snap.groups[1].materials[1].count == 25, "merged count mismatch")

    assert(T:RenameGroup(groupId, "临时货物 A") == true)
    assert(T:AddMaterial(groupId, { itemType = 2003, name = "铁锭", count = 3 }) == true)
    snap = T:GetSnapshot(); assert(snap.groups[1].productName == "临时货物 A" and #snap.groups[1].materials == 3)
    local ironKey = snap.groups[1].materials[3].key
    assert(T:UpdateMaterial(groupId, ironKey, { count = 8, name = "铁锭" }) == true)
    assert(T:MoveMaterial(groupId, ironKey, -1) == true)
    assert(T:RemoveMaterial(groupId, ironKey) == true)
    assert(T:RemoveGroup(groupId) == true)
    assert(#T:GetSnapshot().groups == 0, "RemoveGroup must remove only selected group")
    assert(T.PersistenceStoreId == nil, "session service must never register persistence")
end)


Test("session material rename refreshes name identity and still merges by renamed key", function()
    local T = S.Services.AuctionSessionListV3
    T:Clear("test_rename_identity")
    local ok, groupId = T:AddTradeGroup({ source = "manual", sourceKey = "manual", productName = "手工临时清单", materials = {} })
    assert(ok == true and tonumber(groupId), "manual group create failed")
    local addOk, oldKey = T:AddMaterial(groupId, { name = "蜂蜜", count = 2 })
    assert(addOk == true and oldKey == "name:蜂蜜", "name-only material key mismatch")
    assert(T:UpdateMaterial(groupId, oldKey, { name = "木材" }) == true, "name-only rename failed")
    local snap = T:GetSnapshot()
    local renamed = snap.groups[1].materials[1]
    assert(renamed.name == "木材", "renamed display name mismatch")
    assert(renamed.key == "name:木材", "name-only rename must refresh identity key")
    local mergeOk, mergedKey = T:AddMaterial(groupId, { name = "木材", count = 3 })
    assert(mergeOk == true and mergedKey == "name:木材", "renamed identity must remain mergeable")
    snap = T:GetSnapshot()
    assert(#snap.groups[1].materials == 1 and snap.groups[1].materials[1].count == 5, "renamed material must merge instead of duplicating")
end)


Test("session name-only rename into existing identity merges without duplicate keys", function()
    local T = S.Services.AuctionSessionListV3
    T:Clear("test_rename_collision")
    local ok, groupId = T:AddTradeGroup({ source = "manual", sourceKey = "manual", productName = "手工临时清单", materials = {} })
    assert(ok == true)
    local okA, honeyKey = T:AddMaterial(groupId, { name = "蜂蜜", count = 2 })
    local okB = T:AddMaterial(groupId, { name = "木材", count = 3 })
    assert(okA == true and okB == true)
    assert(T:UpdateMaterial(groupId, honeyKey, { name = "木材" }) == true)
    local snap = T:GetSnapshot()
    assert(#snap.groups[1].materials == 1, "rename collision must merge two name identities")
    assert(snap.groups[1].materials[1].key == "name:木材" and snap.groups[1].materials[1].count == 5, "rename collision merge mismatch")
end)

Test("session service reload replaces runtime state instead of persisting temporary groups", function()
    local T = S.Services.AuctionSessionListV3
    T:Clear("test_reload")
    assert(T:AddTradeGroup({ source = "manual", sourceKey = "reload", productName = "本次运行", materials = { { name = "木材", count = 1 } } }) == true)
    assert(#T:GetSnapshot().groups == 1, "precondition: session group missing")
    assert(dofile("services/rs_auction_session_list_v3.lua") == nil, "service module reload should not return business state")
    local reloaded = S.Services.AuctionSessionListV3
    assert(reloaded ~= T, "module reload must replace the old session service table")
    assert(#reloaded:GetSnapshot().groups == 0, "ReloadAddon semantics require temporary groups to reset")
    assert(reloaded.PersistenceStoreId == nil, "reloaded session service must still have no persistence")
end)

print(string.format("\nAuction Workspace Service Test Results: %d/%d passed", passed, total))
if passed ~= total then os.exit(1) end
print("ALL TESTS PASSED!")
