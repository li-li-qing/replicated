------------------------------------------------------------------------
-- 2026-09-30 daily-auction-title-recovery-1 (development only; not in toc.g)
-- Real Demand / QuestProgress / DailyAuctionMaterials / static recipe resolver.
-- Only the RU Native host, event delivery and clock/scheduler edges are simulated.
-- 990011/990012 are synthetic test IDs, NOT proposed additions to game data.
------------------------------------------------------------------------
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; print('PASS daily_title ' .. name)
    else failed = failed + 1; print('FAIL daily_title ' .. name .. ': ' .. tostring(err)) end
end
local function Eq(a, b, why)
    assert(a == b, (why or 'mismatch') .. ': expected=' .. tostring(b) .. ' actual=' .. tostring(a))
end
local function Copy(v)
    if type(v) ~= 'table' then return v end
    local t = {}; for k, c in pairs(v) do t[k] = Copy(c) end; return t
end
local QA, QB = 990011, 990012
local TA = '[特产-西部] 珊瑚海岸的保存特产'
local TB = '[特产-西部] 太初之地的标准特产'
local function Boot()
    local h = { ids = { QA, QB }, titles = { [QA] = TA, [QB] = TB }, titleFailures = {}, titleReads = {}, calls = {}, events = {}, now = 1000 }
    ReplicatedSuite = { Services = {}, Data = {}, Generation = 1, Utils = { DeepCopy = Copy },
        NowMs = function() return h.now end, SafeTraceback = function(e) return tostring(e) end }
    local S = ReplicatedSuite; h.S = S
    S.Events = { internal = {}, native = {} }
    function S.Events:BindOwner() return true end
    function S.Events:Subscribe(name, owner, fn) self.native[name] = self.native[name] or {}; self.native[name][owner] = fn; return true end
    function S.Events:SubscribeInternal(name, owner, fn)
        if h.rejectTopic == name then return false end
        self.internal[name] = self.internal[name] or {}; self.internal[name][owner] = fn; return true
    end
    function S.Events:UnsubscribeOwner(owner) for _, bucket in pairs(self.native) do bucket[owner] = nil end; return true end
    function S.Events:UnsubscribeInternalOwner(owner) for _, bucket in pairs(self.internal) do bucket[owner] = nil end; return true end
    function S.Events:UnsubscribeInternal(name, owner) if self.internal[name] then self.internal[name][owner] = nil end; return true end
    function S.Events:Publish(name, ...)
        h.events[#h.events + 1] = name
        local handlers = {}; for owner, fn in pairs(self.internal[name] or {}) do handlers[#handlers + 1] = { owner, fn } end
        for _, row in ipairs(handlers) do row[2](row[1], ...) end
        return true
    end
    function h:NativeEvent(name)
        self.now = self.now + 250
        for owner, fn in pairs(S.Events.native[name] or {}) do fn(owner) end
    end
    S.Scheduler = { tasks = {} }
    function S.Scheduler:AddTask(name, interval, fn, repeating, owner) self.tasks[name] = { callback = fn, interval = interval, owner = owner }; return true end
    function S.Scheduler:SetTaskModule() return true end
    function S.Scheduler:RemoveTask(name) self.tasks[name] = nil; return true end
    function h:Safety() self.now = self.now + 15000; local t = assert(S.Scheduler.tasks.v3_quest_progress_safety, 'existing safety missing'); t.callback() end
    function h:EventCount(name) local n = 0; for _, item in ipairs(self.events) do if item == name then n = n + 1 end end; return n end
    S.Api = {}
    function S.Api:IsCapabilityAllowed() return true end
    function S.Api:CallCapability(capability, host, method, ...)
        h.calls[capability] = (h.calls[capability] or 0) + 1
        local fn = host and host[method]; if type(fn) ~= 'function' then return false, nil end
        return pcall(fn, host, ...)
    end
    X2Quest = {}
    function X2Quest:GetActiveQuestListCount() return #h.ids end
    function X2Quest:GetActiveQuestType(i) return h.ids[i] end
    function X2Quest:IsCompleted() return false end
    function X2Quest:IsReadyForCompleteQuest() return false end
    function X2Quest:GetQuestContextMainTitle(qid)
        h.titleReads[qid] = (h.titleReads[qid] or 0) + 1
        if h.titleFailures[qid] then error('simulated title not ready') end
        return h.titles[qid]
    end
    -- A passive materials projection must never require X2Auction/X2Craft.
    X2Auction = setmetatable({}, { __index = function() error('daily materials attempted auction IO') end })
    X2Craft = setmetatable({}, { __index = function() error('daily materials attempted craft IO') end })
    dofile('core/rs_demand.lua')
    dofile('data/rs_data_registry.lua')
    dofile('data/ids/rs_item_ids.lua')
    dofile('data/ids/rs_quest_ids.lua')
    dofile('data/ids/rs_instance_ids.lua')
    dofile('core/rs_constants.lua')
    dofile('data/rs_static_data_v2.lua')
    dofile('data/ids/rs_zone_ids.lua')
    dofile('data/ids/rs_trade_craft_ids.lua')
    dofile('data/ids/rs_trade_product_ids.lua')
    dofile('data/rs_trade_materials.lua')
    dofile('data/rs_trade_static_v2.lua')
    dofile('data/rs_quest_data.lua')
    assert(S.BootError == nil, tostring(S.BootError))
    -- Activity/instance definitions remain real, but no instance demand is acquired.
    dofile('services/rs_trade_material_identity_v3.lua')
    dofile('services/rs_quest_progress_v3.lua')
    dofile('services/rs_daily_auction_materials_v3.lua')
    h.P = assert(S.Services.QuestProgressV3); h.D = assert(S.Services.DailyAuctionMaterialsV3)
    function h:Open() assert(self.D:AcquireConsumer('test:sidecar')); return self.D:GetSnapshot() end
    function h:Task(qid) for _, task in ipairs(self.D:GetSnapshot().tasks or {}) do if task.questId == qid then return task end end end
    return h
end

Test('both real historical titles resolve with real recipe data', function()
    local h = Boot(); local snap = h:Open()
    Eq(#snap.tasks, 2); Eq(h:Task(QA).selectedRecipe, 'Sanddeep Preserved Specialty')
    Eq(h:Task(QB).selectedRecipe, 'Aubre Commercial Specialty')
    Eq(#h:Task(QA).materials, 2); Eq(#h:Task(QB).materials, 2)
    Eq(h:Task(QA).originZoneId, 27); Eq(h:Task(QB).originZoneId, 21)
    Eq(h.S.Services.TradeMaterialIdentityV3.liveReads, 0)
end)
Test('late second title recovers on objective event with unchanged quest membership and state', function()
    local h = Boot(); h.titles[QB] = nil; Eq(#h:Open().tasks, 1)
    local rev, before = h.P.revision, h:EventCount('v3.quest_progress.updated')
    h.titles[QB] = TB; h:NativeEvent('QUEST_CONTEXT_OBJECTIVE_EVENT')
    Eq(h.P.revision, rev, 'title-only change must not fake quest progress'); Eq(h:EventCount('v3.quest_progress.updated'), before)
    Eq(#h.D:GetSnapshot().tasks, 2, 'late second title remained dropped')
    Eq(h:Task(QB).selectedRecipe, 'Aubre Commercial Specialty')
end)
Test('unready title capability failure recovers through existing safety refresh', function()
    local h = Boot(); h.titleFailures[QB] = true; Eq(#h:Open().tasks, 1)
    h.titleFailures[QB] = nil; h:Safety(); Eq(#h.D:GetSnapshot().tasks, 2)
end)
Test('both initially unavailable titles recover independently', function()
    local h = Boot(); h.titles = {}; Eq(#h:Open().tasks, 0)
    h.titles[QA] = TA; h:Safety(); Eq(#h.D:GetSnapshot().tasks, 1)
    h.titles[QB] = TB; h:Safety(); Eq(#h.D:GetSnapshot().tasks, 2)
end)
Test('quest getter separates native title from generated fallback', function()
    local h = Boot(); h.titles[QB] = nil; h:Open()
    local facts = h.P:GetActiveQuestStates({ QA, QB })
    Eq(facts[QA].titleAvailable, true); Eq(facts[QB].titleAvailable, false)
    local list = h.P:GetActiveQuestList(); Eq(list[1].titleAvailable, true); Eq(list[2].titleAvailable, false)
    h.titles[QB] = TB; Eq(h.P:GetActiveQuestState(QB).titleAvailable, true)
end)
Test('pre-existing QuestProgress consumer does not hide late title recovery', function()
    local h = Boot(); assert(h.P:AcquireConsumer('test:other', { instances = false }))
    h.titles[QB] = nil; Eq(#h:Open().tasks, 1)
    h.titles[QB] = TB; h:Safety(); Eq(#h.D:GetSnapshot().tasks, 2)
end)
Test('late regular quest title clears pending without inventing a trade task', function()
    local h = Boot(); h.titles[QB] = nil; h:Open(); h.titles[QB] = '普通战斗任务'; h:Safety()
    Eq(#h.D:GetSnapshot().tasks, 1); Eq(h.D:GetDiagnosticsSnapshot().pendingTitleCount, 0)
end)
Test('new quest ID triggers ordinary updated path', function()
    local h = Boot(); h.ids = { QA }; Eq(#h:Open().tasks, 1)
    h.ids = { QA, QB }; h:NativeEvent('ADD_GIVEN_QUEST_INFO'); Eq(#h.D:GetSnapshot().tasks, 2)
end)
Test('removed quest disappears and is not resurrected by late title', function()
    local h = Boot(); h.titles[QB] = nil; h:Open(); h.ids = { QA }; h:NativeEvent('REMOVE_GIVEN_QUEST_INFO')
    h.titles[QB] = TB; h:Safety(); Eq(#h.D:GetSnapshot().tasks, 1); assert(h:Task(QB) == nil)
end)
Test('stable refreshes do not rebuild already complete daily projection', function()
    local h = Boot(); h:Open(); local rev, reads = h.D.revision, (h.titleReads[QA] or 0) + (h.titleReads[QB] or 0)
    for i = 1, 4 do h:Safety() end
    Eq(h.D.revision, rev); Eq((h.titleReads[QA] or 0) + (h.titleReads[QB] or 0), reads)
end)
Test('unready title retries only that title without republishing unchanged materials', function()
    local h = Boot(); h.titles[QB] = nil; h:Open()
    local rev, a, b = h.D.revision, h.titleReads[QA], h.titleReads[QB]
    h:Safety(); h:Safety()
    Eq(h.D.revision, rev, 'unready retry caused UI rebuild'); Eq(h.titleReads[QA], a)
    Eq(h.titleReads[QB], b + 2, 'only one missing-title read per existing refresh is needed')
end)
Test('updated and refreshed in same epoch do not double rebuild', function()
    local h = Boot(); h.titles[QB] = nil; h:Open(); h.titles[QB] = TB; h.ids = { QA, QB, 990013 }; h.titles[990013] = '普通任务'
    local rev = h.D.revision; h:NativeEvent('ADD_GIVEN_QUEST_INFO'); Eq(h.D.revision, rev + 1)
end)
Test('one of two consumers can leave without cancelling title recovery', function()
    local h = Boot(); h.titles[QB] = nil; h:Open(); assert(h.D:AcquireConsumer('test:second')); assert(h.D:ReleaseConsumer('test:sidecar'))
    h.titles[QB] = TB; h:Safety(); Eq(#h.D:GetSnapshot().tasks, 2); Eq(h.D.consumerCount, 1)
end)
Test('last daily consumer release prevents recovery work while other quest consumer remains', function()
    local h = Boot(); h.titles[QB] = nil; h:Open(); assert(h.P:AcquireConsumer('test:other', {})); assert(h.D:ReleaseConsumer('test:sidecar'))
    local rev, reads = h.D.revision, h.titleReads[QB]; h.titles[QB] = TB; h:Safety()
    Eq(h.D.revision, rev); Eq(h.titleReads[QB], reads); Eq(h.D.consumerCount, 0)
    for _, b in pairs(h.S.Events.internal) do assert(b[h.D] == nil, 'daily subscription leaked') end
end)
Test('closing and reopening after title readiness recovers in initial snapshot', function()
    local h = Boot(); h.titles[QB] = nil; h:Open(); assert(h.D:ReleaseConsumer('test:sidecar'))
    assert(next(h.S.Scheduler.tasks) == nil); h.titles[QB] = TB; Eq(#h:Open().tasks, 2)
end)
Test('second subscription failure rolls back demand and first subscription', function()
    local h = Boot(); h.rejectTopic = 'v3.quest_progress.refreshed'
    local ok = h.D:AcquireConsumer('test:sidecar'); Eq(ok, false)
    Eq(h.D.consumerCount, 0); Eq(h.P.consumerCount, 0); Eq(h.P.running, false)
    for _, b in pairs(h.S.Events.internal) do assert(b[h.D] == nil, 'partial subscription leaked') end
end)
Test('stale callback from retired daily service cannot refresh its snapshot', function()
    local h = Boot(); h.titles[QB] = nil; h:Open()
    local handler = assert((h.S.Events.internal['v3.quest_progress.refreshed'] or {})[h.D], 'recovery subscription missing')
    local rev = h.D.revision; h.S.Services.DailyAuctionMaterialsV3 = {}; h.titles[QB] = TB
    handler(h.D, h.P.refreshEpoch + 1, h.P.revision, 'late')
    Eq(h.D.revision, rev)
end)
Test('unmatched trade title stays visible without fabricated materials', function()
    local h = Boot(); h.titles[QB] = '[特产-西部] 未收录测试区域的保存特产'; h:Open()
    local task = assert(h:Task(QB), 'unmatched second trade task silently removed')
    Eq(task.materialStatus, 'unresolved'); Eq(task.matchReason, 'zone_unmatched'); Eq(#task.materials, 0)
    Eq(#h.D:GetSnapshot().tasks, 2); Eq(h.D:GetSnapshot().status, 'partial')
end)
Test('generic inland trade title stays in diagnostics without a shopping task', function()
    local h = Boot(); h.titles[QB] = '内陆特产'; h:Open()
    Eq(#h.D:GetSnapshot().tasks, 1, 'generic trade title polluted daily shopping list')
    assert(h:Task(QB) == nil, 'generic title acquired a recipe or placeholder task')
    local diag = h.D:GetDiagnosticsSnapshot()
    Eq(diag.unresolvedTradeLikeCount, 1); Eq(diag.unresolvedTaskCount, 0)
    Eq(diag.unresolvedTradeLike[1].questId, QB); Eq(diag.unresolvedTradeLike[1].title, '内陆特产')
    Eq(diag.unresolvedTradeLike[1].purchaseTaskEligible, false)
    Eq(diag.unresolvedTradeLike[1].exclusionReason, 'generic_trade_title')
    Eq(h.S.Services.TradeMaterialIdentityV3.liveReads, 0)
end)
Test('only a generic trade quest is an empty shopping list, not missing recipe data', function()
    local h = Boot(); h.ids = { QB }; h.titles[QB] = '内陆特产'; h:Open()
    local snap = h.D:GetSnapshot()
    Eq(#snap.tasks, 0); Eq(snap.status, 'empty'); Eq(snap.unresolvedTaskCount, 0)
    Eq(h.D:GetDiagnosticsSnapshot().unresolvedTradeLike[1].exclusionReason, 'generic_trade_title')
end)
Test('missing static recipe preserves task with recipe reason, not wrong region material', function()
    local h = Boot(); local static = h.S.Data.TradeStaticV2; local original = static.GetRecipeByLegacyName
    static.GetRecipeByLegacyName = function(self, key) if key == 'Aubre Commercial Specialty' then return nil end; return original(self, key) end
    h:Open(); local task = assert(h:Task(QB), 'missing recipe dropped entire task')
    Eq(task.matchReason, 'recipe_unmatched'); Eq(task.originZoneId, 21); Eq(#task.materials, 0)
end)
Test('known multi-candidate task still requires one selection, never sums candidates', function()
    local h = Boot(); local config
    for _, row in ipairs(h.S.Data.DailyTradePackQuestRecipes) do if #row.recipes > 1 then config = row; break end end
    assert(config); h.ids = { config.questId }; h.titles = { [config.questId] = '居民已核交付任务' }; h:Open()
    Eq(h:Task(config.questId).requiresSelection, true); Eq(#h:Task(config.questId).materials, 0)
    assert(h.D:SelectRecipe(config.questId, config.recipes[1])); Eq(h:Task(config.questId).selectedRecipe, config.recipes[1])
end)
Test('two quests sharing one material keep independent hide and ordering scope', function()
    local h = Boot(); h.titles[QB] = TA; h:Open()
    local a, b = h:Task(QA), h:Task(QB); Eq(a.materials[1].key, b.materials[1].key)
    assert(h.D:SetMaterialHidden(QA, a.selectedRecipe, a.materials[1].key, true))
    Eq(h:Task(QA).materials[1].hidden, true); Eq(h:Task(QB).materials[1].hidden, false)
    assert(h.D:MoveMaterial(QA, a.selectedRecipe, a.materials[1].key, 1)); Eq(h:Task(QB).materials[1].key, b.materials[1].key)
end)
Test('diagnostics expose bounded pending and per-task proof without extra native reads', function()
    local h = Boot(); h.titles[QB] = nil; h:Open()
    local before = Copy(h.calls); local diag = h.D:GetDiagnosticsSnapshot()
    Eq(diag.patch, 'daily-auction-title-recovery-1'); Eq(diag.pendingTitleCount, 1)
    Eq(diag.pendingTitles[1].questId, QB); Eq(diag.tasks[1].questId, QA); Eq(diag.tasks[1].materialCount, 2)
    for cap, n in pairs(h.calls) do Eq(n, before[cap], 'diagnostics made Native call') end
    diag.tasks[1].title = 'tampered'; Eq(h:Task(QA).title, TA)
end)
Test('unresolved count is total, not truncated sample length', function()
    local h = Boot(); h.ids = {}; h.titles = {}
    for i = 1, 9 do local qid = 991000 + i; h.ids[i] = qid; h.titles[qid] = '[特产] 未收录测试地区' .. tostring(i) end
    h:Open(); local diag = h.D:GetDiagnosticsSnapshot()
    Eq(diag.unresolvedTradeLikeCount, 9); Eq(#diag.unresolvedTradeLike, 6); Eq(#h.D:GetSnapshot().tasks, 9)
    Eq(diag.knownActiveCount, 0, 'unresolved placeholders must not count as known quest mapping')
end)

-- 中文维护注释（2026-10-02）：地区名称必须按同一个 CraftId 对照 RU 中英文数据库，
-- 不能从待测 Zone.nameZh 反造标题，否则错误别名也会获得绿灯。
-- https://wiki.archerage.to/ru-cn/db/crafts/commerce-vocation
-- https://wiki.archerage.to/ru-en/db/crafts/commerce-vocation
-- 第一列是真实 ZoneId；后面的中文名称/英文配方前缀是独立核对的身份期望。
local REGION_CASES = {
    {1,'格威尔森林','Gweonid Commercial','标准'}, {2,'玛瑞诺普','Marianople Fine','新鲜'},
    {3,'碎石平原','Dewstone Fine','新鲜'}, {4,'黎明半岛','Solis Luxury','特供'},
    {5,'索兹里德半岛','Solzreed Luxury','特供'}, {6,'黎利尔丘陵','Lilyut Fine','新鲜'},
    {7,'彩虹荒野','Arcum Iris Commercial','标准'}, {8,'双冠丘陵','Two Crowns Luxury','特供'},
    {9,'摩哈特比','Mahadevi Fine','新鲜'}, {10,'青铜岩石山','Airain Commercial','标准'},
    {11,'猎鹰高原','Falcorth Fine','新鲜'}, {12,'咏唱之地','Villanelle Luxury','特供'},
    {13,'烈日峡谷','Sunbite Commercial','标准'}, {14,'草原之脉','Windscour Preserved','保存'},
    {15,'哈里洛废墟','Perinoor Preserved','保存'}, {16,'棋盘石林','Rookborne Preserved','保存'},
    {17,'伊尼斯泰尔','Ynystere Commercial','标准'}, {18,'白雪森林','White Arden Commercial','标准'},
    {19,'埋骨之地','Karkasse Commercial','标准'}, {20,'十字星平原','Cinderstone Luxury','特供'},
    {21,'太初之地','Aubre Commercial','标准'}, {22,'黄金平原','Halcyona Preserved','保存'},
    {23,'翡翠谷','Hasla Preserved','保存'}, {24,'虎脊山脉','Tigerspine Fine','新鲜'},
    {25,'古代森林','Silent Forest Commercial','标准'}, {26,'地狱沼泽','Hellswamp Preserved','保存'},
    {27,'珊瑚海岸','Sanddeep Preserved','保存'}, {93,'西风脊','Ahnimar Preserved','保存'},
    {99,'洛卡山脉','Rokhala Preserved','保存'},
}
local function RowSignature(rows)
    local out = {}; for _, row in ipairs(rows or {}) do
        assert(row.itemType and row.itemType > 0 and row.count > 0, 'material identity/count missing')
        out[#out + 1] = tostring(row.itemType) .. ':' .. tostring(row.count)
    end
    table.sort(out); return table.concat(out, '|')
end
for _, region in ipairs(REGION_CASES) do
    Test('independent region and all four families: ' .. region[2], function()
        local h = Boot(); h.ids = {}; h.titles = {}
        local families = {{'特产','Specialty'}, {'特制特产','Gilda Specialty'}, {'传统特产','Local Specialty'}, {'肥料特产','Fertilizer Specialty'}}
        for index, family in ipairs(families) do
            local qid = 992000 + index; h.ids[index] = qid
            h.titles[qid] = '[特产] ' .. region[2] .. '的' .. region[4] .. family[1]
        end
        h:Open(); Eq(#h.D:GetSnapshot().tasks, 4)
        for index, family in ipairs(families) do
            local task = assert(h:Task(992000 + index)); Eq(task.originZoneId, region[1], region[2])
            Eq(task.materialStatus, 'ready', family[1])
            local expected = assert(h.S.Services.TradeMaterialIdentityV3:ResolveStatic(region[3] .. ' ' .. family[2], region[1]))
            Eq(task.selectedRecipe, expected.label, 'family identity'); Eq(RowSignature(task.materials), RowSignature(expected.rows), 'material IDs/counts')
        end
        Eq(h.S.Services.TradeMaterialIdentityV3.liveReads, 0, 'passive daily lookup must stay pure')
    end)
end
Test('user screenshot and independently verified neighboring recipes retain exact material counts', function()
    local h = Boot(); h.ids = {}; h.titles = {}
    -- 中文维护注释：数量直接来自截图与官方 RU Craft 6245/6244/9336/9340/9332/6243，
    -- 不从当前材料表生成期望，才能发现“名字和材料一起串到邻区”的问题。
    local cases = {
        {'棋盘石林','保存','30898:200|773:5'}, {'哈里洛废墟','保存','30899:200|7992:15'},
        {'太初之地','标准','30903:180|8013:15'}, {'西风脊','保存','14630:15|30898:200'},
        {'青铜岩石山','标准','30905:180|8005:15'}, {'草原之脉','保存','14629:6|30903:200'},
    }
    for i, case in ipairs(cases) do h.ids[i] = 993000 + i; h.titles[h.ids[i]] = '[特产] ' .. case[1] .. '的' .. case[2] .. '特产' end
    h:Open()
    for i, case in ipairs(cases) do Eq(RowSignature(assert(h:Task(h.ids[i])).materials), case[3], case[1]) end
end)
Test('two different region names in one title never choose arbitrary longest region', function()
    local h = Boot(); h.titles[QB] = '[特产] 棋盘石林与哈里洛废墟的保存特产'; h:Open()
    local task = assert(h:Task(QB)); Eq(#task.materials, 0); Eq(task.matchReason, 'zone_ambiguous')
end)
Test('unknown named specialty cannot borrow the ordinary recipe solely from 特产', function()
    local h = Boot(); h.titles[QB] = '[特产] 棋盘石林皮毯特产'; h:Open()
    local task = assert(h:Task(QB)); Eq(#task.materials, 0); Eq(task.matchReason, 'recipe_unmatched')
end)
Test('all database signature recipes preserve every ingredient through the real resolver', function()
    local h = Boot(); local count = 0
    for craftId, expected in pairs(h.S.GameIds.TradeCraft.VerifiedIngredientSignatures) do
        local craft = assert(h.S.GameIds.TradeCraft:GetByCraftId(craftId))
        local recipe = assert(h.S.Data.TradeStaticV2:GetRecipeByLegacyName(craft.legacyName))
        Eq(recipe.ingredientSignature, expected, 'database signature craft ' .. craftId)
        Eq(recipe.ingredientVerified, true, craft.legacyName)
        local resolved = assert(h.S.Services.TradeMaterialIdentityV3:ResolveStatic(craft.legacyName, recipe.originZoneId))
        Eq(#resolved.rows, #recipe.ingredients, 'ingredient loss ' .. craft.legacyName)
        RowSignature(resolved.rows)
        count = count + 1
    end
    Eq(count, 98, 'verified recipe coverage'); Eq(h.S.Services.TradeMaterialIdentityV3.liveReads, 0)
end)
Test('missing one ingredient or database mismatch never publishes a partial recipe as complete', function()
    local h = Boot(); local static = h.S.Data.TradeStaticV2; local original = static.GetRecipeByLegacyName
    static.GetRecipeByLegacyName = function(self, name)
        local recipe = original(self, name)
        if recipe and name == 'Rookborne Preserved Specialty' then
            recipe = Copy(recipe); recipe.ingredients[2] = { materialKey='unverified_test_resource', count=5 }
        end
        return recipe
    end
    Eq(h.S.Services.TradeMaterialIdentityV3:ResolveStatic('[棋盘]保存特产', 16), nil, 'partial ingredient result')
    static.GetRecipeByLegacyName = function(self, name)
        local recipe = original(self, name)
        if recipe and name == 'Rookborne Preserved Specialty' then recipe=Copy(recipe); recipe.ingredientStatus='database_mismatch' end
        return recipe
    end
    Eq(h.S.Services.TradeMaterialIdentityV3:ResolveStatic('[棋盘]保存特产', 16), nil, 'contradictory signature')
end)
Test('material words alone never classify an unknown pack as a larder', function()
    local h = Boot(); local identity = h.S.Services.TradeMaterialIdentityV3
    for _, name in ipairs({'棋盘石林蜂蜜特产','棋盘石林奶酪特产','棋盘石林药材特产'}) do
        Eq(identity:ResolveStatic(name, 16), nil, name)
    end
    for _, name in ipairs({'棋盘石林基本发酵蜂蜜','棋盘石林加工发酵奶酪','棋盘石林无添加发酵药材','陈化蜂蜜'}) do
        Eq(assert(identity:ResolveStatic(name, 16)).source, 'static_family', name)
    end
end)
Test('verified product ItemID wins over localized or misleading product text', function()
    local h = Boot(); local identity = h.S.Services.TradeMaterialIdentityV3; local count = 0
    for _, recipe in ipairs(h.S.StaticDataV2:List('trade_recipe')) do
        if recipe.productItemId then
            local resolved = assert(identity:ResolveStatic('本地化名称尚未就绪', recipe.originZoneId, recipe.productItemId), recipe.legacyName)
            Eq(resolved.label, recipe.legacyName); count = count + 1
        end
    end
    assert(count >= 90, 'verified product coverage too small: ' .. count)
    local resolved = assert(identity:ResolveStatic('Perinoor Preserved Specialty', 16, 31874))
    Eq(resolved.label, 'Rookborne Preserved Specialty'); Eq(RowSignature(resolved.rows), '30898:200|773:5')
    Eq(identity:ResolveStatic('[棋盘]保存特产', 15, 31874), nil, 'product/route region conflict')
end)

-- Real import manager: title data must not depend on Bonds/Activities having
-- accidentally imported X2Quest first. Only ADDON:ImportAPI itself is simulated.
local function InstallImports(h, shouldFail)
    local questHost=X2Quest; X2Quest=nil
    dofile('native/rs_native_contract.lua')
    local questApi=assert(h.S.NativeContract:GetApi('QUEST'))
    h.importCalls=0
    ADDON={ImportAPI=function(_, id)
        Eq(id, questApi.id, 'daily must only request the existing QUEST namespace')
        h.importCalls=h.importCalls+1
        if shouldFail then return false end
        X2Quest=questHost; return true
    end}
    dofile('native/rs_native_imports.lua')
end
Test('cold daily-only startup imports its quest dependency without borrowing another feature', function()
    local h=Boot(); InstallImports(h, false); Eq(h.importCalls, 0)
    Eq(#h:Open().tasks, 2, 'cold daily-only startup had no quest namespace')
    Eq(h.importCalls, 1)
    Eq(h.S.ApiImports:GetOwnerApis(h.D.Id)[1], 'QUEST')
end)
Test('native quest import remains lazy and idempotent across daily reopen', function()
    local h=Boot(); InstallImports(h, false)
    h.D:GetDiagnosticsSnapshot(); Eq(h.importCalls, 0, 'diagnostics must not import Native')
    h:Open(); assert(h.D:AcquireConsumer('test:second'))
    assert(h.D:ReleaseConsumer('test:sidecar')); assert(h.D:ReleaseConsumer('test:second'))
    assert(next(h.S.Scheduler.tasks)==nil); h:Open(); Eq(h.importCalls, 1)
end)
Test('native quest import failure is visible and does not start empty quest polling', function()
    local h=Boot(); InstallImports(h, true)
    local ok, err=h.D:AcquireConsumer('test:sidecar')
    Eq(ok, false); assert(type(err)=='string' and #err>0)
    Eq(h.P.consumerCount, 0); Eq(h.P.running, false); assert(next(h.S.Scheduler.tasks)==nil)
    Eq(h.D:GetDiagnosticsSnapshot().nativeQuestLeaseState, 'failed')
end)

print(string.format('DAILY AUCTION TITLE READINESS: %d passed, %d failed', passed, failed))
if failed > 0 then error('daily title readiness failures: ' .. failed) end
