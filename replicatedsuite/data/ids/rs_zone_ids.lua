------------------------------------------------------------------------
-- Replicated Suite - Shared Zone IDs / Static Zone Metadata
--
-- Zone identity belongs to the shared GameDataRegistry. Stable trade-specific
-- metadata (for example the legacy pack quality family) is mirrored into
-- StaticDataV2 so Services never carry their own magic zone-id tables.
--
-- These IDs are migrated from the existing ArcheRage RU curated trade data.
-- They are not marked database_verified until separately re-verified.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Registry = S.GameDataRegistry
local Static = S.StaticDataV2
if type(Registry) ~= "table" or type(Static) ~= "table" then return end

S.GameIds = S.GameIds or {}
local Z = { ById = {}, ByKey = {}, ContinentContractVersion = 1 }
S.GameIds.Zone = Z

if Static:GetCatalog("zone") == nil then
    Static:DefineCatalog("zone", { idField = "zoneId", requireId = true })
end

local SOURCE = "Replicated Suite legacy ArcheRage RU curated zone mapping"
local DEFINITIONS = {
    { 1,   "GWEONID",       "Gweonid",       "Commercial" },
    { 2,   "MARIANOPLE",    "Marianople",    "Fine" },
    { 3,   "DEWSTONE",      "Dewstone",      "Fine" },
    { 4,   "SOLIS",         "Solis",         "Luxury" },
    { 5,   "SOLZREED",      "Solzreed",      "Luxury" },
    { 6,   "LILYUT",        "Lilyut",        "Fine" },
    { 7,   "ARCUM_IRIS",    "Arcum Iris",    "Commercial" },
    { 8,   "TWO_CROWNS",    "Two Crowns",    "Luxury" },
    { 9,   "MAHADEVI",      "Mahadevi",      "Fine" },
    { 10,  "AIRAIN",        "Airain",        "Commercial" },
    { 11,  "FALCORTH",      "Falcorth",      "Fine" },
    { 12,  "VILLANELLE",    "Villanelle",    "Luxury" },
    { 13,  "SUNBITE",       "Sunbite",       "Commercial" },
    { 14,  "WINDSCOUR",     "Windscour",     "Preserved" },
    { 15,  "PERINOOR",      "Perinoor",      "Preserved" },
    { 16,  "ROOKBORNE",     "Rookborne",     "Preserved" },
    { 17,  "YNYSTERE",      "Ynystere",      "Commercial" },
    { 18,  "WHITE_ARDEN",   "White Arden",   "Commercial" },
    { 19,  "KARKASSE",      "Karkasse",      "Commercial" },
    { 20,  "CINDERSTONE",   "Cinderstone",   "Luxury" },
    { 21,  "AUBRE",         "Aubre",         "Commercial" },
    { 22,  "HALCYONA",      "Halcyona",      "Preserved" },
    { 23,  "HASLA",         "Hasla",         "Preserved" },
    { 24,  "TIGERSPINE",    "Tigerspine",    "Fine" },
    { 25,  "SILENT_FOREST", "Silent Forest", "Commercial" },
    { 26,  "HELLSWAMP",     "Hellswamp",     "Preserved" },
    { 27,  "SANDDEEP",      "Sanddeep",      "Preserved" },
    { 54,  "EXELOCH",       "Exeloch",       "Coastal" },
    { 56,  "SUNGOLD",       "Sungold",       "Coastal" },
    { 57,  "GOLDEN_RUINS",  "Golden Ruins",  "Coastal" },
    { 93,  "AHNIMAR",       "Ahnimar",       "Preserved" },
    { 99,  "ROKHALA",       "Rokhala",       "Preserved" },
    { 102, "AEGIS",         "Aegis",         "Coastal" },
    { 103, "WHALESONG",     "Whalesong",     "Coastal" },
}

-- 中文维护注释（2026-10-04）：大陆是地区的静态事实，不是采集居民板时的所在地。
-- RU 官方数据库的 Nuia/Haranya/Auroria 地区目录逐项核对；Airain（10）与 Aubre（21）
-- 都属于西大陆。债券与所在地判断共同消费本表，禁止在 Feature 再维护另一份地区分边。
-- https://wiki.archerage.to/ru-en/db/achievements/655
local CONTINENT_BY_ZONE = {
    [1]="west", [2]="west", [3]="west", [5]="west", [6]="west", [8]="west",
    [10]="west", [18]="west", [19]="west", [20]="west", [21]="west", [22]="west",
    [26]="west", [27]="west", [93]="west",
    [4]="east", [7]="east", [9]="east", [11]="east", [12]="east", [13]="east",
    [14]="east", [15]="east", [16]="east", [17]="east", [23]="east", [24]="east",
    [25]="east", [99]="east",
    [54]="auroria", [56]="auroria", [57]="auroria", [102]="auroria", [103]="auroria",
}

-- 中文维护注释（2026-10-02）：地区中文名参与任务→ZoneId→配方解析，不能只当显示文案。
-- 对照 RU 中英文 Commerce 数据库的相同 CraftId：6243=草原/Windscour，6244=哈里洛/Perinoor，
-- 6245=棋盘/Rookborne，9332=青铜/Airain，9336=太初/Aubre，9340=西风/Ahnimar。
-- https://wiki.archerage.to/ru-cn/db/crafts/commerce-vocation
-- https://wiki.archerage.to/ru-en/db/crafts/commerce-vocation
-- 旧“太初→93”是串区错误，不能保留为别名；这里只保留不冲突的旧汉化名，稳定数值 ID 不变。
local DISPLAY_NAME_ALIASES_ZH = {
    [16] = { "洛卡棋盘" }, -- Rookborne 的旧汉化；当前制作日常与制作台使用“棋盘石林”。
}

local DISPLAY_NAME_ZH = {
    [1] = "格威尔森林",
    [2] = "玛瑞诺普",
    [3] = "碎石平原",
    [4] = "黎明半岛",
    [5] = "索兹里德半岛",
    [6] = "黎利尔丘陵",
    [7] = "彩虹荒野",
    [8] = "双冠丘陵",
    [9] = "摩哈特比",
    [10] = "青铜岩石山",
    [11] = "猎鹰高原",
    [12] = "咏唱之地",
    [13] = "烈日峡谷",
    [14] = "草原之脉",
    [15] = "哈里洛废墟",
    [16] = "棋盘石林",
    [17] = "伊尼斯泰尔",
    [18] = "白雪森林",
    [19] = "埋骨之地",
    [20] = "十字星平原",
    [21] = "太初之地",
    [22] = "黄金平原",
    [23] = "翡翠谷",
    [24] = "虎脊山脉",
    [25] = "古代森林",
    [26] = "地狱沼泽",
    [27] = "珊瑚海岸",
    [54] = "墟境之口",
    [56] = "煦日之野",
    [57] = "黄金废墟",
    [93] = "西风脊",
    [99] = "洛卡山脉",
    [102] = "海之烛台",
    [103] = "鲸鱼歌湾",
}

for _, def in ipairs(DEFINITIONS) do
    local zoneId, semanticKey, nameEn, tradeQuality = def[1], def[2], def[3], def[4]
    local key = "zone." .. tostring(semanticKey):lower()
    local row = {
        zoneId = zoneId,
        semanticKey = semanticKey,
        nameEn = nameEn,
        nameZh = DISPLAY_NAME_ZH[zoneId],
        nameZhAliases = DISPLAY_NAME_ALIASES_ZH[zoneId],
        continentKey = CONTINENT_BY_ZONE[zoneId],
        tradeQuality = tradeQuality,
        source = SOURCE,
        confidence = "curated",
        verified = false,
    }
    local stored = Static:Register("zone", key, row)
    if stored ~= nil then
        Z.ById[zoneId] = stored
        Z.ByKey[semanticKey] = stored
        Z[semanticKey] = zoneId
    end
    Registry:Register("zone", semanticKey, zoneId, {
        name = nameEn,
        family = "TRADE_PRODUCTION_ZONE",
        tags = { "ZONE", "TRADE_ZONE", "TRADE_QUALITY_" .. tostring(tradeQuality):upper() },
        source = SOURCE,
        confidence = "curated",
        verified = false,
    })
end
