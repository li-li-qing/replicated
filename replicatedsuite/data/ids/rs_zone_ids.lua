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
local Z = { ById = {}, ByKey = {} }
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

for _, def in ipairs(DEFINITIONS) do
    local zoneId, semanticKey, nameEn, tradeQuality = def[1], def[2], def[3], def[4]
    local key = "zone." .. tostring(semanticKey):lower()
    local row = {
        zoneId = zoneId,
        semanticKey = semanticKey,
        nameEn = nameEn,
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
