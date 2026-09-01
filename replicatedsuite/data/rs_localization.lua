------------------------------------------------------------------------
-- Replicated Suite - Verified static Chinese localization authority
-- Runtime code never fetches the Wiki.  Additions must be reviewed against
-- the RU-CN Knowledge Database before being committed.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Data = S.Data or {}
local SharedItemIds = (S.GameIds and S.GameIds.Item) or {}
local SharedBondMaterials = SharedItemIds.BOND_MATERIAL or {}

S.Data.Localization = {
    version = 2,
    sources = {
        items = "https://wiki.archerage.to/ru-cn/db/items",
        crafts = "https://wiki.archerage.to/ru-cn/db/crafts",
    },
    verifiedAt = "2026-08-24",
    items = {
        [6312] = "造纸机",
        [6872] = "高级印刷机",
        [10469] = "高级印刷机",
        [11780] = "多功能制作台",
        -- Trade materials: reviewed static subset currently referenced by the
        -- trade/craft assistant. IDs are server item identities, never recipe
        -- resource ids or a machine translation cache.
        [30898] = "切碎的蔬菜", [30902] = "谷物细粉", [30905] = "干净的肉脯",
        [30900] = "晒干的花草", [30899] = "浓缩的果汁", [30901] = "捣碎的香料",
        [3603] = "鸡蛋", [8065] = "葡萄", [19947] = "鹅毛", [773] = "苹果",
        [8055] = "牛奶", [8054] = "橄榄", [8053] = "绵羊毛", [3667] = "水仙花",
        [30903] = "熏蒸的药粉", [19946] = "鸭毛", [14627] = "樱花果", [3588] = "石榴",
        [3675] = "月桂叶", [7994] = "红薯", [14620] = "香蕉", [14630] = "蘑菇",
        [3592] = "鳄梨", [3628] = "迷迭香", [8005] = "大麦", [784] = "大米",
        [8013] = "玉米", [2178] = "矢车菊", [14971] = "黑麦", [3622] = "向日葵",
        [16268] = "姜黄", [7998] = "胡萝卜", [3684] = "映山红", [3564] = "百合",
        [15767] = "银杏叶", [8012] = "黄瓜", [8038] = "无花果", [8000] = "花生",
        [8010] = "洋葱", [7992] = "土豆", [3545] = "燕麦", [3546] = "黄米",
        [8001] = "大蒜", [26674] = "兔驼毛", [16273] = "番红花", [8034] = "椰枣",
        [8036] = "柠檬", [14629] = "薄荷", [3627] = "薰衣草", [8016] = "番茄",
        [15770] = "辣木树果实", [3713] = "菖蒲", [16290] = "芦荟", [14621] = "橘子",
        [3711] = "玫瑰", [8006] = "草莓", [18749] = "烈火原木", [18442] = "源晶木",
        [49243] = "银百合", [49244] = "烈火花瓣", [SharedBondMaterials.lumber] = "木材", [28481] = "蜂蜜",
        [3712] = "稻草捆", [42343] = "有光泽的种子", [3680] = "长脑参",
        [4747] = "特产品质认证书", [3426] = "坚硬的原木", [45045] = "时空裂缝碎片",
        [SharedBondMaterials.iron] = "铁锭", [SharedItemIds.BLUE_SALT_BOND] = "蓝盐商会债券证书", [19448] = "细须柔顺剂",
        [19449] = "胚芽皮革油", [19450] = "双花翻新剂", [23633] = "德翡纳之星",
    },
    crafts = {
        [2841] = "纸",
    },
    doodads = {},
}

S.Localization = S.Localization or {}
local L = S.Localization
L.session = L.session or {}

local aliases = { item = "items", items = "items", craft = "crafts", crafts = "crafts", doodad = "doodads", doodads = "doodads" }
function L:GetName(kind, id, fallback)
    local bucket = aliases[string.lower(tostring(kind or ""))]
    local numericId = tonumber(id)
    local data = S.Data and S.Data.Localization
    local text = bucket and numericId and data and data[bucket] and data[bucket][numericId] or nil
    if type(text) == "string" and text ~= "" then return text, true end
    local cacheKey = bucket and numericId and (bucket .. ":" .. tostring(numericId)) or nil
    local cached = cacheKey and self.session[cacheKey] or nil
    if type(cached) == "string" and cached ~= "" then return cached, false end
    local present = tostring(fallback or "")
    if present ~= "" then
        if cacheKey ~= nil then self.session[cacheKey] = present end
        return present, false
    end
    return numericId and ("ID " .. tostring(numericId)) or "未知", false
end

function L:RememberSessionName(kind, id, name)
    local bucket = aliases[string.lower(tostring(kind or ""))]
    local numericId, text = tonumber(id), tostring(name or "")
    if bucket == nil or numericId == nil or text == "" then return false end
    local static = S.Data and S.Data.Localization and S.Data.Localization[bucket] and S.Data.Localization[bucket][numericId]
    if type(static) == "string" and static ~= "" then return false end
    self.session[bucket .. ":" .. tostring(numericId)] = text
    return true
end
