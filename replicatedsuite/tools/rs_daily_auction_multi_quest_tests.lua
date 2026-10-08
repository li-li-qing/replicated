------------------------------------------------------------------------
-- Replicated Suite - Daily Auction multi-quest localized zone regression
--
-- Self-contained: validates the real Zone static file plus
-- DailyAuctionMaterialsV3 without the heavyweight workspace UI test host.
------------------------------------------------------------------------
local ROOT = "./"

local function Copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local out = {}; seen[value] = out
    for key, child in pairs(value) do out[Copy(key, seen)] = Copy(child, seen) end
    return out
end
local function Assert(value, message)
    if value ~= true then error(tostring(message or "assertion failed"), 2) end
end
local function Eq(actual, expected, message)
    if actual ~= expected then
        error(tostring(message or "equality assertion failed") .. ": expected=" .. tostring(expected) .. " actual=" .. tostring(actual), 2)
    end
end

ReplicatedSuite = {
    Utils = { DeepCopy = Copy },
    Services = {},
    Data = { DailyTradePackQuestRecipes = {} },
    Events = {
        Publish = function() return true end,
        SubscribeInternal = function() return true end,
        UnsubscribeInternalOwner = function() return true end,
    },
    GameDataRegistry = { Register = function() return true end },
    StaticDataV2 = { catalogs = {} },
}
local S = ReplicatedSuite

function S.StaticDataV2:GetCatalog(id) return self.catalogs[id] end
function S.StaticDataV2:DefineCatalog(id, spec)
    self.catalogs[id] = { spec = spec, records = {} }
    return self.catalogs[id]
end
function S.StaticDataV2:Register(catalogId, key, row)
    local catalog = self.catalogs[catalogId]
    if catalog == nil then return nil end
    local stored = Copy(row)
    catalog.records[key] = stored
    return stored
end

-- 中文维护注释（2026-10-02）：太初对应 RU 制作 9336/Aubre，西风对应 9340/Ahnimar。
-- 测试曾要求保留错误“太初→93”别名；以同 CraftId 的官方中英文记录修正期望。
dofile(ROOT .. "data/ids/rs_zone_ids.lua")
Assert(type(S.GameIds) == "table" and type(S.GameIds.Zone) == "table", "zone authority did not load")
Eq(S.GameIds.Zone.ById[27].nameZh, "珊瑚海岸", "Coral Coast primary localized name")
Eq(S.GameIds.Zone.ById[21].nameZh, "太初之地", "Aubre current RU localized name")
Eq(S.GameIds.Zone.ById[93].nameZh, "西风脊", "Ahnimar current RU localized name")

S.Demand = {}
function S.Demand:Create(spec)
    local lease = { count = 0, tokens = {}, spec = spec }
    function lease:Acquire(token)
        if self.tokens[token] then return true end
        local before, after = { count = self.count }, { count = self.count + 1 }
        if type(self.spec.reconcile) == "function" then
            local ok, err = self.spec.reconcile(self, before, after)
            if ok == false then return false, err end
        end
        self.count, self.tokens[token] = after.count, true
        if type(self.spec.projectionOwner) == "table" then
            self.spec.projectionOwner[self.spec.projectionCountField] = self.count
        end
        return true
    end
    function lease:Release(token)
        if not self.tokens[token] then return true end
        self.tokens[token] = nil
        local before, after = { count = self.count }, { count = math.max(0, self.count - 1) }
        if type(self.spec.reconcile) == "function" then
            local ok, err = self.spec.reconcile(self, before, after)
            if ok == false then return false, err end
        end
        self.count = after.count
        if type(self.spec.projectionOwner) == "table" then
            self.spec.projectionOwner[self.spec.projectionCountField] = self.count
        end
        return true
    end
    return lease
end

local activeList = {
    { questId = 990011, active = true, state = "IN_PROGRESS", title = "[特产-西部] 珊瑚海岸的保存特产", index = 1 },
    { questId = 990012, active = true, state = "IN_PROGRESS", title = "[特产-西部] 太初之地的标准特产", index = 2 },
}
S.Services.QuestProgressV3 = {
    GetActiveQuestStates = function() return {} end,
    GetActiveQuestList = function() return activeList end,
    AcquireConsumer = function() return true end,
    ReleaseConsumer = function() return true end,
}

local resolvedByZone = {
    [27] = { label = "Sanddeep Preserved Specialty", rows = { { itemType = 1001, count = 5 }, { itemType = 1002, count = 25 } } },
    [21] = { label = "Aubre Commercial Specialty", rows = { { itemType = 2001, count = 15 }, { itemType = 2002, count = 23 } } },
}
S.Services.TradeMaterialIdentityV3 = {
    ResolveStatic = function(_, title, zoneId)
        if zoneId == 27 and tostring(title):find("珊瑚海岸", 1, true) then return Copy(resolvedByZone[27]) end
        if zoneId == 21 and tostring(title):find("太初之地", 1, true) then return Copy(resolvedByZone[21]) end
        return nil
    end,
    ResolveMaterialDisplayName = function(_, row) return "材料#" .. tostring(row.itemType) end,
    ResolveProductDisplayName = function() return "贸易品" end,
}

dofile(ROOT .. "services/rs_daily_auction_materials_v3.lua")
local D = S.Services.DailyAuctionMaterialsV3
Assert(type(D) == "table", "DailyAuctionMaterialsV3 did not load")
Assert(D:Refresh("localized_multi_quest_regression") == true, "daily auction refresh failed")
local snapshot = D:GetSnapshot()
Eq(#(snapshot.tasks or {}), 2, "both simultaneous trade-pack quests must be preserved")
Eq(snapshot.titleMatchedCount, 2, "both localized trade-pack titles must be matched")
local byId = {}
for _, task in ipairs(snapshot.tasks or {}) do byId[task.questId] = task end
Assert(byId[990011] ~= nil, "珊瑚海岸 quest missing")
Assert(byId[990012] ~= nil, "太初之地 quest missing")
Eq(byId[990011].originZoneId, 27, "珊瑚海岸 stable zone id")
Eq(byId[990012].originZoneId, 21, "太初之地 stable Aubre zone id")
Eq(#(byId[990011].materials or {}), 2, "珊瑚海岸 materials missing")
Eq(#(byId[990012].materials or {}), 2, "太初之地 materials missing")

print("DAILY_AUCTION_MULTI_QUEST_TEST PASS")
