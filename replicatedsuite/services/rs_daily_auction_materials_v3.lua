------------------------------------------------------------------------
-- Replicated Suite V3 - Daily Auction Materials
--
-- Demand-scoped detached read-model for active resident trade-pack quests.
-- QuestProgressV3 owns quest facts; TradeMaterialIdentityV3 owns recipe/material
-- identity.  This service owns only session UI choices (candidate recipe,
-- hidden/material order) and never persists or invents quest requirements.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}
local D = {
    version = 1,
    DailyMaterialContractVersion = 2,
    patch = "daily-auction-title-recovery-1",
    pendingTitles = {}, lastQuestRefreshEpoch = nil,
    titleRetryReads = 0, titleRecoveries = 0,
    nativeQuestLease = false, nativeQuestLeaseState = "idle",
    Id = "v3.daily_auction_materials",
    Topic = "v3.daily_auction_materials.updated",
    presentationBoundary = "service_only",
    consumers = {}, consumerCount = 0,
    revision = 0,
    snapshot = { status = "idle", tasks = {}, revision = 0 },
    selectedRecipes = {}, hiddenMaterials = {}, materialOrder = {},
    questConsumerToken = "service:daily_auction_materials",
    questHeld = false, subscribed = false,
}
S.Services.DailyAuctionMaterialsV3 = D

local function Copy(value, seen)
    if S.Utils ~= nil and type(S.Utils.DeepCopy) == "function" then return S.Utils.DeepCopy(value) end
    if type(value) ~= "table" then return value end
    seen = seen or {}; if seen[value] then return nil end; seen[value] = true
    local out = {}; for key, child in pairs(value) do out[key] = Copy(child, seen) end; return out
end
local function RecipeConfig(questId)
    questId = tonumber(questId)
    for _, entry in ipairs(S.Data and S.Data.DailyTradePackQuestRecipes or {}) do
        if tonumber(entry.questId) == questId then return entry end
    end
    return nil
end
local function HasRecipe(entry, recipe)
    recipe = tostring(recipe or "")
    for _, value in ipairs(type(entry) == "table" and entry.recipes or {}) do if tostring(value) == recipe then return true end end
    return false
end
local function MaterialKey(row, index)
    local itemType = tonumber(row and row.itemType)
    if itemType ~= nil and itemType > 0 then return "item:" .. tostring(math.floor(itemType)) end
    local key = tostring(row and row.materialKey or "")
    if key ~= "" then return "material:" .. key end
    return "row:" .. tostring(index or 0)
end
local function ScopeKey(questId, recipe) return tostring(math.floor(tonumber(questId) or 0)) .. "|" .. tostring(recipe or "") end
local function Publish(self)
    if type(S.Events) == "table" and type(S.Events.Publish) == "function" then S.Events:Publish(self.Topic, self.revision) end
end
local function ApplyOrder(rows, order)
    if type(order) ~= "table" or #order == 0 then return rows end
    local byKey, used, out = {}, {}, {}
    for _, row in ipairs(rows) do byKey[row.key] = row end
    for _, key in ipairs(order) do if byKey[key] ~= nil and not used[key] then out[#out + 1] = byKey[key]; used[key] = true end end
    for _, row in ipairs(rows) do if not used[row.key] then out[#out + 1] = row end end
    return out
end

local function FindZoneIdInText(text)
    text = tostring(text or "")
    local bestId, bestLen = nil, 0
    local byId = S.GameIds and S.GameIds.Zone and S.GameIds.Zone.ById or nil
    local function Consider(zoneId, candidate)
        local name = tostring(candidate or "")
        if name ~= "" and string.find(text, name, 1, true) ~= nil and #name > bestLen then
            bestId, bestLen = tonumber(zoneId), #name
        end
    end
    for zoneId, zone in pairs(type(byId) == "table" and byId or {}) do
        if type(zone) == "table" then
            Consider(zoneId, zone.nameZh)
            -- 中文维护注释（2026-09-25，daily-trade-zone-alias-1）：地区任务标题来自当前 RU 客户端，
            -- 而稳定 ZoneId 数据可能保留旧汉化名。别名属于 Zone 静态身份的一部分；这里只做 bounded
            -- 字符串匹配，不在刷新热路径扫描拍卖数据/价格表，也不根据相似文字猜地区。最长精确命中优先，
            -- 防止“珊瑚海岸”覆盖“珊瑚海岸北部”这类包含关系。
            for _, alias in ipairs(type(zone.nameZhAliases) == "table" and zone.nameZhAliases or {}) do
                Consider(zoneId, alias)
            end
        end
    end
    return bestId and math.floor(bestId) or nil
end

local function BuildMaterialRows(self, identity, questId, recipe, resolved)
    local scope = ScopeKey(questId, recipe)
    local hidden, rows = self.hiddenMaterials[scope] or {}, {}
    for index, raw in ipairs(type(resolved) == "table" and type(resolved.rows) == "table" and resolved.rows or {}) do
        local key = MaterialKey(raw, index)
        local name = type(identity.ResolveMaterialDisplayName) == "function" and identity:ResolveMaterialDisplayName(raw) or tostring(raw.materialKey or "材料")
        rows[#rows + 1] = { key=key, questId=questId, recipe=recipe, itemType=tonumber(raw.itemType), materialKey=raw.materialKey,
            name=tostring(name or "材料"), count=math.max(0, tonumber(raw.count) or 0),
            searchable=raw.includeInCost ~= false and tostring(name or "") ~= "" and tostring(name or "") ~= "材料", hidden=hidden[key] == true }
    end
    return ApplyOrder(rows, self.materialOrder[scope])
end

function D:GetSnapshot() return Copy(self.snapshot) end
function D:GetDiagnosticsSnapshot()
    -- 仅返回已采集证据；打印报告不能触发任务刷新、材料搜索或取得 Consumer。
    local snap, tasks = self.snapshot or {}, {}
    for _, task in ipairs(snap.tasks or {}) do
        local hiddenCount = 0
        for _, row in ipairs(task.materials or {}) do if row.hidden == true then hiddenCount = hiddenCount + 1 end end
        if #tasks < 12 then
            tasks[#tasks + 1] = { questId=task.questId, title=task.title, originZoneId=task.originZoneId,
                discoverySource=task.discoverySource, materialStatus=task.materialStatus, matchReason=task.matchReason,
                selectedRecipe=task.selectedRecipe, requiresSelection=task.requiresSelection == true,
                materialCount=#(task.materials or {}), hiddenMaterialCount=hiddenCount }
        end
    end
    return { version=1, patch=self.patch, status=snap.status, consumerCount=self.consumerCount, activeQuestCount=snap.activeQuestCount or 0,
        knownActiveCount=snap.knownActiveCount or 0, titleMatchedCount=snap.titleMatchedCount or 0, unresolvedTradeLikeCount=snap.unresolvedTradeLikeCount or 0,
        unresolvedTradeLike=Copy(snap.unresolvedTradeLike or {}), unresolvedTaskCount=snap.unresolvedTaskCount or 0,
        pendingTitleCount=snap.pendingTitleCount or 0, pendingTitles=Copy(snap.pendingTitles or {}),
        taskCount=#(snap.tasks or {}), tasks=tasks, tasksOmitted=math.max(0, #(snap.tasks or {}) - #tasks),
        titleRetryReads=self.titleRetryReads, titleRecoveries=self.titleRecoveries,
        nativeQuestLeaseState=self.nativeQuestLeaseState, nativeQuestLeaseError=self.nativeQuestLeaseError,
        lastQuestRefreshEpoch=self.lastQuestRefreshEpoch, reason=snap.reason }
end

function D:Refresh(reason)
    local quest = S.Services and S.Services.QuestProgressV3 or nil
    local identity = S.Services and S.Services.TradeMaterialIdentityV3 or nil
    if type(quest) ~= "table" or type(quest.GetActiveQuestStates) ~= "function" then
        self.revision = self.revision + 1
        self.snapshot = { status = "unavailable", tasks = {}, revision = self.revision, error = "QuestProgressV3 active-state API 不可用" }
        Publish(self); return false, self.snapshot.error
    end
    if type(identity) ~= "table" or type(identity.ResolveStatic) ~= "function" then
        self.revision = self.revision + 1
        self.snapshot = { status = "unavailable", tasks = {}, revision = self.revision, error = "TradeMaterialIdentityV3 不可用" }
        Publish(self); return false, self.snapshot.error
    end
    self.lastQuestRefreshEpoch = tonumber(quest.refreshEpoch)
    local configs = S.Data and S.Data.DailyTradePackQuestRecipes or {}
    local ids = {}; for _, entry in ipairs(configs) do if tonumber(entry.questId) ~= nil then ids[#ids + 1] = math.floor(tonumber(entry.questId)) end end
    local facts = quest:GetActiveQuestStates(ids) or {}
    local tasks = {}
    for _, entry in ipairs(configs) do
        local qid = math.floor(tonumber(entry.questId) or 0)
        local fact = facts[qid]
        if qid > 0 and type(fact) == "table" and fact.active == true then
            local recipes = {}; for _, recipe in ipairs(type(entry.recipes) == "table" and entry.recipes or {}) do recipes[#recipes + 1] = tostring(recipe) end
            -- 中文维护注释（2026-09-14，候选货物显示名）：DailyTradePackQuestRecipes 保存的是内部 legacyName，
            -- 它只能作为静态配方身份，不能直接显示给玩家。这里优先通过已核 recipe.productItemId +
            -- TradeMaterialIdentityV3 的本地化 resolver 得到客户端物品名；无法证明时只显示“候选货物 N”，
            -- 宁可信息少一些，也不把英文内部键泄露到 UI。raw recipe 仍只作为 SelectRecipe 的稳定参数。
            local recipeOptions = {}
            local staticTrade = S.Data and S.Data.TradeStaticV2 or nil
            for recipeIndex, recipe in ipairs(recipes) do
                local record = type(staticTrade) == "table" and type(staticTrade.GetRecipeByLegacyName) == "function" and staticTrade:GetRecipeByLegacyName(recipe) or nil
                local label = type(identity.ResolveProductDisplayName) == "function" and identity:ResolveProductDisplayName(type(record) == "table" and record.productItemId or nil, nil) or nil
                if type(label) ~= "string" or label == "" or label == "贸易品" then label = "候选货物 " .. tostring(recipeIndex) end
                recipeOptions[#recipeOptions + 1] = { recipe = recipe, name = label }
            end
            local selected = self.selectedRecipes[qid]
            if #recipes == 1 then selected = recipes[1]
            elseif not HasRecipe(entry, selected) then selected = nil end
            local task = {
                questId = qid, title = tostring(fact.title or ("居民做货任务 #" .. tostring(qid))), state = tostring(fact.state or "IN_PROGRESS"), active = true,
                recipes = recipes, recipeOptions = recipeOptions, selectedRecipe = selected, requiresSelection = #recipes > 1 and selected == nil,
                materials = {}, materialStatus = "waiting_selection",
            }
            if selected ~= nil then
                local resolved = identity:ResolveStatic(selected, nil)
                if type(resolved) == "table" and type(resolved.rows) == "table" then
                    task.materials = BuildMaterialRows(self, identity, qid, selected, resolved)
                    task.materialStatus = #task.materials > 0 and "ready" or "empty"
                else
                    task.materialStatus = "unavailable"
                end
            end
            tasks[#tasks + 1] = task
        end
    end
    -- 中文维护注释（2026-09-14，RU 区域制作日常发现）：历史 DailyTradePackQuestRecipes 只覆盖一组
    -- 已核交付 QuestId，但实机任务“[特产-西部] 黄金平原的保存特产”属于明确区域+品类的制作日常，
    -- 其 QuestId 不应靠猜补白名单。这里消费 QuestProgressV3 detached 活动任务标题，以共享 Zone.nameZh
    -- 识别地区，再交给 TradeMaterialIdentityV3:ResolveStatic(title, zoneId) 证明真实配方；只有能解析出
    -- 静态材料的任务才显示采购行。2026-09-30：带“特产”证据但无法匹配的任务保留待匹配标题，
    -- 不生成材料；普通任务仍不纳入做货清单，避免把“暂未匹配”伪装成“没有第二项任务”。
    local taskById = {}; for _, task in ipairs(tasks) do taskById[task.questId] = task end
    local activeList = type(quest.GetActiveQuestList) == "function" and (quest:GetActiveQuestList() or {}) or {}
    local titleMatchedCount, unresolvedTradeLike, activeQuestCount = 0, {}, #activeList
    local pendingTitles, pendingSamples, unresolvedCount, unresolvedTaskCount = {}, {}, 0, 0
    for _, fact in ipairs(activeList) do
        local qid = math.floor(tonumber(fact.questId) or 0)
        local title = tostring(fact.title or "")
        if qid > 0 and fact.active ~= false then
            -- 只有 QuestProgress 明确声明的“标题未就绪”才重试；普通未识别任务不猜成做货。
            -- pending 保留全部当前 ID，诊断只采前 6 个样本，不能用样本长度充当总数。
            if fact.titleAvailable == false then
                pendingTitles[#pendingTitles + 1] = qid
                if #pendingSamples < 6 then pendingSamples[#pendingSamples + 1] = { questId=qid, title=title, index=fact.index } end
            end
            local tradeLike = string.find(title, "特产", 1, true) ~= nil
            local zoneId = tradeLike and FindZoneIdInText(title) or nil
            local resolved = zoneId ~= nil and tradeLike and identity:ResolveStatic(title, zoneId) or nil
            local recipe = type(resolved) == "table" and tostring(resolved.label or "") or ""
            if recipe ~= "" and type(resolved.rows) == "table" and #resolved.rows > 0 then
                local rows = BuildMaterialRows(self, identity, qid, recipe, resolved)
                -- 明确标题优先于历史泛化候选，但每个 QuestId 独立保留，不能按货物/材料去重任务。
                for i = #tasks, 1, -1 do if tonumber(tasks[i].questId) == qid then table.remove(tasks, i) end end
                local task = { questId=qid, title=title ~= "" and title or ("做货任务 #"..tostring(qid)), state=tostring(fact.state or "IN_PROGRESS"),
                    active=true, recipes={recipe}, recipeOptions={}, selectedRecipe=recipe, requiresSelection=false, materials=rows,
                    materialStatus=#rows>0 and "ready" or "empty", discoverySource="active_title", originZoneId=zoneId }
                tasks[#tasks + 1] = task; taskById[qid] = task
                titleMatchedCount = titleMatchedCount + 1
            elseif tradeLike then
                local matchReason = zoneId == nil and "zone_unmatched" or "recipe_unmatched"
                unresolvedCount = unresolvedCount + 1
                if #unresolvedTradeLike < 6 then
                    unresolvedTradeLike[#unresolvedTradeLike + 1] = { questId=qid, title=title, zoneId=zoneId,
                        reason=matchReason, knownMappingRetained=taskById[qid] ~= nil }
                end
                -- 中文维护注释（2026-09-30，daily-auction-title-recovery-1）：未匹配的特产任务原先
                -- 被整个丢弃，玩家只能看到另一项。保留无材料的待匹配行，不猜地区/配方，也不覆盖
                -- 已核 QuestId 的候选列表；采购搜索始终只允许已证明的材料行。
                if taskById[qid] == nil then
                    local task = { questId=qid, title=title, state=tostring(fact.state or "IN_PROGRESS"), active=true,
                        recipes={}, recipeOptions={}, requiresSelection=false, materials={}, materialStatus="unresolved",
                        discoverySource="unresolved_title", originZoneId=zoneId, matchReason=matchReason }
                    tasks[#tasks + 1] = task; taskById[qid] = task; unresolvedTaskCount = unresolvedTaskCount + 1
                end
            end
        end
    end
    local knownActiveCount = 0
    for _, task in ipairs(tasks) do
        if task.discoverySource ~= "active_title" and task.discoverySource ~= "unresolved_title" then knownActiveCount = knownActiveCount + 1 end
    end
    self.pendingTitles = pendingTitles
    self.revision = self.revision + 1
    local status = #tasks > 0 and "ready" or "empty"
    if #pendingTitles > 0 or unresolvedTaskCount > 0 then status = #tasks > 0 and "partial" or "waiting_titles" end
    self.snapshot = { status = status, tasks = tasks, revision = self.revision, reason = tostring(reason or "refresh"),
        activeQuestCount=activeQuestCount, knownActiveCount=knownActiveCount, titleMatchedCount=titleMatchedCount,
        unresolvedTradeLikeCount=unresolvedCount, unresolvedTradeLike=unresolvedTradeLike, unresolvedTaskCount=unresolvedTaskCount,
        pendingTitleCount=#pendingTitles, pendingTitles=pendingSamples }
    Publish(self)
    return true
end

-- 中文维护注释（2026-09-14，多候选居民做货）：一个 QuestId 可能允许多个地区货物，recipes 是
-- 候选集合而不是同时需求。只有用户显式选中一个合法候选后才解析材料；绝不把多个 recipe 材料累加。
-- 选择仅属于 Session，不写任务 Authority/Store，任务消失后快照自然不再展示。
function D:SelectRecipe(questId, recipe)
    local entry = RecipeConfig(questId); if entry == nil then return false, "任务不在已核居民做货表" end
    recipe = tostring(recipe or ""); if HasRecipe(entry, recipe) ~= true then return false, "货物候选无效" end
    self.selectedRecipes[math.floor(tonumber(questId))] = recipe
    return self:Refresh("select_recipe")
end

function D:SetMaterialHidden(questId, recipe, materialKey, hidden)
    local scope = ScopeKey(questId, recipe); materialKey = tostring(materialKey or "")
    if materialKey == "" then return false, "材料身份无效" end
    self.hiddenMaterials[scope] = self.hiddenMaterials[scope] or {}
    if hidden == true then self.hiddenMaterials[scope][materialKey] = true else self.hiddenMaterials[scope][materialKey] = nil end
    return self:Refresh("material_hidden")
end

function D:RestoreHidden(questId)
    local prefix = tostring(math.floor(tonumber(questId) or 0)) .. "|"
    for scope in pairs(self.hiddenMaterials) do if scope:sub(1, #prefix) == prefix then self.hiddenMaterials[scope] = nil end end
    return self:Refresh("restore_hidden")
end

function D:MoveMaterial(questId, recipe, materialKey, direction)
    local qid, targetKey = math.floor(tonumber(questId) or 0), tostring(materialKey or "")
    local task = nil; for _, row in ipairs(self.snapshot.tasks or {}) do if row.questId == qid and tostring(row.selectedRecipe or "") == tostring(recipe or "") then task = row; break end end
    if task == nil then return false, "当前任务材料不可用" end
    local index = nil; for i, row in ipairs(task.materials or {}) do if row.key == targetKey then index = i; break end end
    if index == nil then return false, "材料不存在" end
    local delta = tonumber(direction); if delta == nil or delta == 0 then return false, "移动方向无效" end; delta = delta < 0 and -1 or 1
    local target = index + delta; if target < 1 or target > #(task.materials or {}) then return false, "材料已在边界" end
    local order = {}; for _, row in ipairs(task.materials or {}) do order[#order + 1] = row.key end
    order[index], order[target] = order[target], order[index]
    self.materialOrder[ScopeKey(qid, recipe)] = order
    return self:Refresh("move_material")
end

local function IsCurrentConsumer(self)
    return ReplicatedSuite == S and S.Services.DailyAuctionMaterialsV3 == self
        and self.subscribed == true and self.consumerCount > 0
end

function D:RetryPendingTitles(epoch)
    -- 中文维护注释（2026-09-30，daily-auction-title-recovery-1）：Quest ID/完成状态不变时
    -- updated 不发布，但 Native 标题可能已就绪。复用 QuestProgress 的事件/15s safety refreshed
    -- 纪元，只读 pending ID；未变化不重算配方、不发布 UI。无第二轮询、无拍卖查询、无永久任务。
    if not IsCurrentConsumer(self) or #self.pendingTitles == 0 then return true end
    epoch = tonumber(epoch)
    if epoch ~= nil and self.lastQuestRefreshEpoch == epoch then return true end
    self.lastQuestRefreshEpoch = epoch
    local quest = S.Services and S.Services.QuestProgressV3 or nil
    if type(quest) ~= "table" or type(quest.GetActiveQuestState) ~= "function" then return false, "任务标题事实不可用" end
    local changed, recovered = false, 0
    for _, qid in ipairs(self.pendingTitles) do
        self.titleRetryReads = self.titleRetryReads + 1
        local fact = quest:GetActiveQuestState(qid)
        if type(fact) == "table" then
            if fact.active == false then changed = true
            elseif fact.titleAvailable == true then changed = true; recovered = recovered + 1 end
        end
    end
    if changed then
        self.titleRecoveries = self.titleRecoveries + recovered
        return self:Refresh("quest_title_ready")
    end
    return true
end

local function UnsubscribeQuestEvents(self)
    if type(S.Events) == "table" and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self)
    elseif type(S.Events) == "table" and type(S.Events.UnsubscribeInternal) == "function" then
        S.Events:UnsubscribeInternal("v3.quest_progress.updated", self)
        S.Events:UnsubscribeInternal("v3.quest_progress.refreshed", self)
    end
    self.subscribed = false
end

function D:_Subscribe()
    if self.subscribed == true then return true end
    if type(S.Events) ~= "table" or type(S.Events.SubscribeInternal) ~= "function" then return false, "任务更新内部事件不可用" end
    local ok = S.Events:SubscribeInternal("v3.quest_progress.updated", self, function()
        if IsCurrentConsumer(D) then return D:Refresh("quest_progress_updated") end
    end)
    if ok ~= true then return false, "任务更新订阅失败" end
    ok = S.Events:SubscribeInternal("v3.quest_progress.refreshed", self, function(_, epoch)
        return D:RetryPendingTitles(epoch)
    end)
    if ok ~= true then UnsubscribeQuestEvents(self); return false, "任务标题恢复订阅失败" end
    self.subscribed = true; return true
end
function D:_Unsubscribe()
    if self.subscribed == true then UnsubscribeQuestEvents(self) end
    self.pendingTitles = {}; self.lastQuestRefreshEpoch = nil
    return true
end
function D:_AcquireQuest()
    if self.questHeld then return true end
    local quest = S.Services and S.Services.QuestProgressV3 or nil
    if type(quest) ~= "table" or type(quest.AcquireConsumer) ~= "function" then return false, "QuestProgressV3 Consumer 不可用" end
    -- 中文维护注释（2026-09-30，daily-auction-title-recovery-1）：拍卖 Feature 本身只需
    -- X2Auction，不能假定活动/债券已替“今日任务”导入 X2Quest。仅在本服务首个消费者进入时，
    -- 通过唯一 NativeImports Authority 取得已核 X2Quest namespace；不在模块加载/诊断时导入。
    -- Native 注册表无卸载接口，导入身份沿用当前 Generation；任务监听仍随最后 Consumer 释放。
    -- 无 imports 的离线宿主可继续提供 detached QuestProgress 替身，不能由这里直接 ImportAPI。
    local imports = S.ApiImports
    if self.nativeQuestLease ~= true and type(imports) == "table" and type(imports.AcquireApi) == "function" then
        local imported, importErr = imports:AcquireApi(self.Id, "X2Quest")
        self.nativeQuestLeaseState = imported == true and "acquired" or "failed"
        self.nativeQuestLeaseError = imported ~= true and tostring(importErr or "quest_import_failed") or nil
        if imported ~= true then return false, "任务接口导入失败：" .. self.nativeQuestLeaseError end
        self.nativeQuestLease = true
    end
    local ok, err = quest:AcquireConsumer(self.questConsumerToken, { instances = false })
    if ok ~= true then return false, err end
    self.questHeld = true; return true
end
function D:_ReleaseQuest()
    if not self.questHeld then return true end
    local quest = S.Services and S.Services.QuestProgressV3 or nil
    if type(quest) == "table" and type(quest.ReleaseConsumer) == "function" then quest:ReleaseConsumer(self.questConsumerToken) end
    self.questHeld = false; return true
end

if type(S.Demand) ~= "table" or type(S.Demand.Create) ~= "function" then error("Demand unavailable for DailyAuctionMaterialsV3") end
local lease, leaseErr = S.Demand:Create({
    id = D.Id, owner = D, projectionOwner = D, projectionConsumersField = "consumers", projectionCountField = "consumerCount",
    reconcile = function(_, before, after)
        local b, a = tonumber(before.count) or 0, tonumber(after.count) or 0
        if b <= 0 and a > 0 then
            local ok, err = D:_AcquireQuest(); if ok ~= true then return false, err end
            local sub, subErr = D:_Subscribe(); if sub ~= true then D:_ReleaseQuest(); return false, subErr end
            local refreshed, refreshErr = D:Refresh("first_consumer"); if refreshed ~= true then D:_Unsubscribe(); D:_ReleaseQuest(); return false, refreshErr end
        elseif b > 0 and a <= 0 then D:_Unsubscribe(); D:_ReleaseQuest() end
        return true
    end,
    quiesce = function() D:_Unsubscribe(); D:_ReleaseQuest(); return true end,
})
if lease == nil then error(leaseErr) end
D.Demand = lease
function D:AcquireConsumer(token) return self.Demand:Acquire(token, {}, "daily_auction_materials_consumer") end
function D:ReleaseConsumer(token) return self.Demand:Release(token, "daily_auction_materials_consumer") end
