------------------------------------------------------------------------
-- Replicated Suite - ArcheRage Trade Product Item IDs
--
-- productItemId is an item namespace and MUST NOT be confused with craftId.
-- Only directly verified ArcheRage DB identities are registered.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
if S.GameDataRegistry == nil then return end

S.GameIds = S.GameIds or {}
local P = { ById = {}, ByLegacyName = {}, stats = { verified = 0, duplicates = 0 } }
S.GameIds.TradeProduct = P

local SOURCE_ACHIEVEMENT = "ArcheRage item database / Trademaster achievement item lists"
local SOURCE_CRAFT_RESULT = "ArcheRage Wiki Crafting Folio product -> item database"
local VERIFIED_AT = "2026-08-27"

local function RegisterProduct(itemId, legacyName, sourceOverride)
    itemId = tonumber(itemId)
    legacyName = tostring(legacyName or "")
    if itemId == nil or itemId ~= math.floor(itemId) or legacyName == "" then return nil end

    local existingById = P.ById[itemId]
    local existingByName = P.ByLegacyName[legacyName]
    if existingById ~= nil or existingByName ~= nil then
        if existingById ~= nil and existingById == existingByName
                and existingById.itemId == itemId and existingById.legacyName == legacyName then
            return existingById
        end
        P.stats.duplicates = P.stats.duplicates + 1
        return nil
    end

    local source = tostring(sourceOverride or SOURCE_ACHIEVEMENT)
    local row = { itemId=itemId, legacyName=legacyName, confidence="database_verified", verified=true, verifiedAt=VERIFIED_AT, source=source }
    P.ById[itemId] = row
    P.ByLegacyName[legacyName] = row
    P.stats.verified = P.stats.verified + 1
    S.GameDataRegistry:Register("trade_product", "TRADE_PRODUCT_" .. tostring(itemId), itemId, {
        name=legacyName, family="TRADE_PRODUCT", tags={"TRADE_PRODUCT","ITEM_ID","DATABASE_VERIFIED"},
        source=source, confidence="database_verified", verified=true, verifiedAt=VERIFIED_AT,
        notes="product ItemID namespace; never use as CraftID",
    })
    return row
end

-- Mainland trade-pack ItemIDs verified one-to-one from current Trademaster achievement item lists.
RegisterProduct(41990, "Ahnimar Preserved Gilda Specialty")
RegisterProduct(41992, "Ahnimar Preserved Local Specialty")
RegisterProduct(41991, "Ahnimar Preserved Specialty")
RegisterProduct(41982, "Airain Commercial Gilda Specialty")
RegisterProduct(41984, "Airain Commercial Local Specialty")
RegisterProduct(41983, "Airain Commercial Specialty")
RegisterProduct(31843, "Arcum Iris Commercial Gilda Specialty")
RegisterProduct(31906, "Arcum Iris Commercial Local Specialty")
RegisterProduct(31866, "Arcum Iris Commercial Specialty")
RegisterProduct(41986, "Aubre Commercial Gilda Specialty")
RegisterProduct(41988, "Aubre Commercial Local Specialty")
RegisterProduct(41987, "Aubre Commercial Specialty")
RegisterProduct(31839, "Cinderstone Luxury Gilda Specialty")
RegisterProduct(31902, "Cinderstone Luxury Local Specialty")
RegisterProduct(31862, "Cinderstone Luxury Specialty")
RegisterProduct(31833, "Dewstone Fine Gilda Specialty")
RegisterProduct(31896, "Dewstone Fine Local Specialty")
RegisterProduct(31856, "Dewstone Fine Specialty")
RegisterProduct(31845, "Falcorth Fine Gilda Specialty")
RegisterProduct(31908, "Falcorth Fine Local Specialty")
RegisterProduct(31868, "Falcorth Fine Specialty")
RegisterProduct(31831, "Gweonid Commercial Gilda Specialty")
RegisterProduct(31894, "Gweonid Commercial Local Specialty")
RegisterProduct(31854, "Gweonid Commercial Specialty")
RegisterProduct(31840, "Halcyona Preserved Gilda Specialty")
RegisterProduct(31903, "Halcyona Preserved Local Specialty")
RegisterProduct(31863, "Halcyona Preserved Specialty")
RegisterProduct(31853, "Hasla Preserved Gilda Specialty")
RegisterProduct(31916, "Hasla Preserved Local Specialty")
RegisterProduct(31876, "Hasla Preserved Specialty")
RegisterProduct(31838, "Hellswamp Preserved Gilda Specialty")
RegisterProduct(31901, "Hellswamp Preserved Local Specialty")
RegisterProduct(31861, "Hellswamp Preserved Specialty")
RegisterProduct(41994, "Karkasse Commercial Gilda Specialty")
RegisterProduct(41996, "Karkasse Commercial Local Specialty")
RegisterProduct(41995, "Karkasse Commercial Specialty")
RegisterProduct(31836, "Lilyut Fine Gilda Specialty")
RegisterProduct(31899, "Lilyut Fine Local Specialty")
RegisterProduct(31859, "Lilyut Fine Specialty")
RegisterProduct(31844, "Mahadevi Fine Gilda Specialty")
RegisterProduct(31907, "Mahadevi Fine Local Specialty")
RegisterProduct(31867, "Mahadevi Fine Specialty")
RegisterProduct(31832, "Marianople Fine Gilda Specialty")
RegisterProduct(31895, "Marianople Fine Local Specialty")
RegisterProduct(31855, "Marianople Fine Specialty")
RegisterProduct(31850, "Perinoor Preserved Gilda Specialty")
RegisterProduct(31913, "Perinoor Preserved Local Specialty")
RegisterProduct(31873, "Perinoor Preserved Specialty")
RegisterProduct(42002, "Rokhala Preserved Gilda Specialty")
RegisterProduct(42004, "Rokhala Preserved Local Specialty")
RegisterProduct(42003, "Rokhala Preserved Specialty")
RegisterProduct(31851, "Rookborne Preserved Gilda Specialty")
RegisterProduct(31914, "Rookborne Preserved Local Specialty")
RegisterProduct(31874, "Rookborne Preserved Specialty")
RegisterProduct(31841, "Sanddeep Preserved Gilda Specialty")
RegisterProduct(31904, "Sanddeep Preserved Local Specialty")
RegisterProduct(31864, "Sanddeep Preserved Specialty")
RegisterProduct(31847, "Silent Forest Commercial Gilda Specialty")
RegisterProduct(31910, "Silent Forest Commercial Local Specialty")
RegisterProduct(31870, "Silent Forest Commercial Specialty")
RegisterProduct(31842, "Solis Luxury Gilda Specialty")
RegisterProduct(31905, "Solis Luxury Local Specialty")
RegisterProduct(31865, "Solis Luxury Specialty")
RegisterProduct(31834, "Solzreed Luxury Gilda Specialty")
RegisterProduct(31897, "Solzreed Luxury Local Specialty")
RegisterProduct(31857, "Solzreed Luxury Specialty")
RegisterProduct(41998, "Sunbite Commercial Gilda Specialty")
RegisterProduct(42000, "Sunbite Commercial Local Specialty")
RegisterProduct(41999, "Sunbite Commercial Specialty")
RegisterProduct(31846, "Tigerspine Fine Gilda Specialty")
RegisterProduct(31909, "Tigerspine Fine Local Specialty")
RegisterProduct(31869, "Tigerspine Fine Specialty")
RegisterProduct(31837, "Two Crowns Luxury Gilda Specialty")
RegisterProduct(31900, "Two Crowns Luxury Local Specialty")
RegisterProduct(31860, "Two Crowns Luxury Specialty")
RegisterProduct(31848, "Villanelle Luxury Gilda Specialty")
RegisterProduct(31911, "Villanelle Luxury Local Specialty")
RegisterProduct(31871, "Villanelle Luxury Specialty")
RegisterProduct(31835, "White Arden Commercial Gilda Specialty")
RegisterProduct(31898, "White Arden Commercial Local Specialty")
RegisterProduct(31858, "White Arden Commercial Specialty")
RegisterProduct(31852, "Ynystere Commercial Gilda Specialty")
RegisterProduct(31915, "Ynystere Commercial Local Specialty")
RegisterProduct(31875, "Ynystere Commercial Specialty")

-- R4: remaining identities verified one-to-one from ArcheRage item pages and
-- Crafting Folio product links. These values were NOT inferred from ID ranges.
RegisterProduct(26485, "Silent Forest Aged Garlic", SOURCE_CRAFT_RESULT)
RegisterProduct(31849, "Windscour Preserved Gilda Specialty", SOURCE_CRAFT_RESULT)
RegisterProduct(31872, "Windscour Preserved Specialty", SOURCE_CRAFT_RESULT)
RegisterProduct(31912, "Windscour Preserved Local Specialty", SOURCE_CRAFT_RESULT)

RegisterProduct(50652, "Aegis Coastal Gilda Specialty", SOURCE_CRAFT_RESULT)
RegisterProduct(50653, "Whalesong Coastal Gilda Specialty", SOURCE_CRAFT_RESULT)
RegisterProduct(50654, "Exeloch Coastal Gilda Specialty", SOURCE_CRAFT_RESULT)
RegisterProduct(50655, "Sungold Coastal Gilda Specialty", SOURCE_CRAFT_RESULT)
RegisterProduct(50656, "Golden Ruins Coastal Gilda Specialty", SOURCE_CRAFT_RESULT)

RegisterProduct(50674, "Aegis Coastal Local Specialty", SOURCE_CRAFT_RESULT)
RegisterProduct(50675, "Whalesong Coastal Local Specialty", SOURCE_CRAFT_RESULT)
RegisterProduct(50676, "Exeloch Coastal Local Specialty", SOURCE_CRAFT_RESULT)
RegisterProduct(50677, "Sungold Coastal Local Specialty", SOURCE_CRAFT_RESULT)
RegisterProduct(50678, "Golden Ruins Coastal Local Specialty", SOURCE_CRAFT_RESULT)

function P:GetByItemId(itemId) return self.ById[tonumber(itemId)] end
function P:GetByLegacyName(legacyName) return self.ByLegacyName[tostring(legacyName or "")] end
function P:Describe(expected)
    local verified = tonumber(self.stats.verified) or 0
    expected = tonumber(expected) or 98
    return { verified=verified, pending=math.max(0, expected-verified), duplicates=tonumber(self.stats.duplicates) or 0, expected=expected, verifiedAt=VERIFIED_AT }
end
