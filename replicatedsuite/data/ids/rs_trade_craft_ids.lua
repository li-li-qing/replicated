------------------------------------------------------------------------
-- Replicated Suite - ArcheRage RU Trade Craft IDs
--
-- ID namespace contract:
--   craftId       = Commerce craft/formula identity from ArcheRage DB.
--   productItemId = produced trade-pack item identity (different namespace).
--   compactId     = Replicated Suite legacy material compatibility index.
--
-- One semantic Local Specialty can have more than one craftId (Plaza and
-- Community Center). Therefore ByLegacyName stores a list and callers must not
-- assume "one pack name == one craft formula".
--
-- Source authority: ArcheRage RU database, Commerce craft catalog.
-- Verified: 2026-08-27.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
if S.GameDataRegistry == nil then return end

S.GameIds = S.GameIds or {}
local C = {
    ById = {},
    ByLegacyName = {},
    PrimaryByLegacyName = {},
    VerifiedIngredientSignatures = {},
    stats = {
        registered = 0,
        primary = 0,
        alternate = 0,
        fertilizer = 0,
        verifiedIngredientSignatures = 0,
    },
}
S.GameIds.TradeCraft = C

local Registry = S.GameDataRegistry
local SOURCE = "ArcheRage RU Commerce database"
local VERIFIED_AT = "2026-08-27"

local function BuildTags(kind, entryPoint, primary)
    local tags = { "TRADE_CRAFT", "COMMERCE", tostring(kind or "SPECIALTY") }
    if entryPoint ~= nil and tostring(entryPoint) ~= "" then tags[#tags + 1] = tostring(entryPoint) end
    if primary == true then tags[#tags + 1] = "PRIMARY_RECIPE" else tags[#tags + 1] = "ALTERNATE_RECIPE" end
    return tags
end

local function RegisterCraft(craftId, legacyName, kind, entryPoint, primary, notes)
    craftId = tonumber(craftId)
    if craftId == nil or craftId ~= math.floor(craftId) then return nil end
    legacyName = tostring(legacyName or "")
    if legacyName == "" then return nil end

    local row = {
        craftId = craftId,
        legacyName = legacyName,
        kind = tostring(kind or "SPECIALTY"),
        entryPoint = tostring(entryPoint or "UNKNOWN"),
        primary = primary == true,
        source = SOURCE,
        confidence = "database_verified",
        verified = true,
        verifiedAt = VERIFIED_AT,
        notes = notes,
    }
    C.ById[craftId] = row

    local byName = C.ByLegacyName[legacyName]
    if byName == nil then byName = {}; C.ByLegacyName[legacyName] = byName end
    byName[#byName + 1] = row
    table.sort(byName, function(a, b) return (tonumber(a.craftId) or 0) < (tonumber(b.craftId) or 0) end)
    if row.primary then C.PrimaryByLegacyName[legacyName] = row end

    C.stats.registered = C.stats.registered + 1
    if row.primary then C.stats.primary = C.stats.primary + 1 else C.stats.alternate = C.stats.alternate + 1 end
    if row.kind == "FERTILIZER" then C.stats.fertilizer = C.stats.fertilizer + 1 end

    Registry:Register("trade_craft", "TRADE_CRAFT_" .. tostring(craftId), craftId, {
        name = legacyName,
        family = "TRADE_CRAFT",
        tags = BuildTags(row.kind, row.entryPoint, row.primary),
        source = SOURCE,
        confidence = "database_verified",
        verified = true,
        verifiedAt = VERIFIED_AT,
        notes = "craftId namespace; never use as product ItemID. " .. tostring(notes or ""),
    })
    return row
end

-- 23 original Nuia/Haranya regions. The official Commerce DB keeps the same
-- zone order across Gilda (6202+), Standard (6225+) and Plaza Local (6248+).
local ORIGINAL_REGIONS = {
    { "Gweonid", "Commercial" },
    { "Marianople", "Fine" },
    { "Dewstone", "Fine" },
    { "Solzreed", "Luxury" },
    { "White Arden", "Commercial" },
    { "Lilyut", "Fine" },
    { "Two Crowns", "Luxury" },
    { "Hellswamp", "Preserved" },
    { "Cinderstone", "Luxury" },
    { "Halcyona", "Preserved" },
    { "Sanddeep", "Preserved" },
    { "Solis", "Luxury" },
    { "Arcum Iris", "Commercial" },
    { "Mahadevi", "Fine" },
    { "Falcorth", "Fine" },
    { "Tigerspine", "Fine" },
    { "Silent Forest", "Commercial" },
    { "Villanelle", "Luxury" },
    { "Windscour", "Preserved" },
    { "Perinoor", "Preserved" },
    { "Rookborne", "Preserved" },
    { "Ynystere", "Commercial" },
    { "Hasla", "Preserved" },
}
for index, region in ipairs(ORIGINAL_REGIONS) do
    local prefix = region[1] .. " " .. region[2]
    RegisterCraft(6201 + index, prefix .. " Gilda Specialty", "GILDA", "SPECIALTY_WORKBENCH", true)
    RegisterCraft(6224 + index, prefix .. " Specialty", "STANDARD", "SPECIALTY_WORKBENCH", true)
    RegisterCraft(6247 + index, prefix .. " Local Specialty", "LOCAL", "PLAZA", true)
    RegisterCraft(7770 + index, prefix .. " Fertilizer Specialty", "FERTILIZER", "FERTILIZER", false,
        "Supplemental formula; uses the shared fertilizer recipe template")
end

-- Six later mainland regions use four consecutive formulas per region.
local EXPANSION_REGIONS = {
    { "Airain", "Commercial", 9331 },
    { "Aubre", "Commercial", 9335 },
    { "Ahnimar", "Preserved", 9339 },
    { "Karkasse", "Commercial", 9343 },
    { "Sunbite", "Commercial", 9347 },
    { "Rokhala", "Preserved", 9351 },
}
for _, region in ipairs(EXPANSION_REGIONS) do
    local prefix = region[1] .. " " .. region[2]
    local base = region[3]
    RegisterCraft(base, prefix .. " Gilda Specialty", "GILDA", "SPECIALTY_WORKBENCH", true)
    RegisterCraft(base + 1, prefix .. " Specialty", "STANDARD", "SPECIALTY_WORKBENCH", true)
    RegisterCraft(base + 2, prefix .. " Local Specialty", "LOCAL", "PLAZA", true)
    RegisterCraft(base + 3, prefix .. " Fertilizer Specialty", "FERTILIZER", "FERTILIZER", false,
        "Supplemental formula; uses the shared fertilizer recipe template")
end

-- Community Center is an alternate craft entry for the same semantic Local
-- Specialty. These IDs must be retained instead of overwriting the Plaza ID.
local COMMUNITY_CENTER = {
    { 9593, "Solzreed Luxury Local Specialty" },
    { 9594, "Lilyut Fine Local Specialty" },
    { 9595, "Dewstone Fine Local Specialty" },
    { 9596, "Gweonid Commercial Local Specialty" },
    { 9597, "Karkasse Commercial Local Specialty" },
    { 9598, "Marianople Fine Local Specialty" },
    { 9599, "Hellswamp Preserved Local Specialty" },
    { 9600, "Sanddeep Preserved Local Specialty" },
    { 9601, "Halcyona Preserved Local Specialty" },
    { 9602, "Two Crowns Luxury Local Specialty" },
    { 9603, "White Arden Commercial Local Specialty" },
    { 9604, "Cinderstone Luxury Local Specialty" },
    { 9605, "Aubre Commercial Local Specialty" },
    { 9606, "Airain Commercial Local Specialty" },
    { 9607, "Ahnimar Preserved Local Specialty" },
    { 9608, "Arcum Iris Commercial Local Specialty" },
    { 9609, "Tigerspine Fine Local Specialty" },
    { 9610, "Mahadevi Fine Local Specialty" },
    { 9611, "Solis Luxury Local Specialty" },
    { 9612, "Sunbite Commercial Local Specialty" },
    { 9613, "Villanelle Luxury Local Specialty" },
    { 9614, "Silent Forest Commercial Local Specialty" },
    { 9615, "Hasla Preserved Local Specialty" },
    { 9616, "Perinoor Preserved Local Specialty" },
    { 9617, "Ynystere Commercial Local Specialty" },
    { 9618, "Falcorth Fine Local Specialty" },
    { 9619, "Rookborne Preserved Local Specialty" },
    { 9620, "Windscour Preserved Local Specialty" },
    { 9621, "Rokhala Preserved Local Specialty" },
}
for _, row in ipairs(COMMUNITY_CENTER) do
    RegisterCraft(row[1], row[2], "LOCAL", "COMMUNITY_CENTER", false,
        "Alternate Community Center formula for the same Local Specialty")
end

-- Auroria pack formulas are non-contiguous in the Commerce database.
local AURORIA = {
    { "Aegis Coastal", 11559, 11577, 11566 },
    { "Whalesong Coastal", 11562, 11578, 11567 },
    { "Exeloch Coastal", 11563, 11579, 11568 },
    { "Sungold Coastal", 11564, 11580, 11569 },
    { "Golden Ruins Coastal", 11565, 11581, 11570 },
}
for _, row in ipairs(AURORIA) do
    RegisterCraft(row[2], row[1] .. " Gilda Specialty", "GILDA", "AURORIA_SPECIALTY_WORKBENCH", true)
    RegisterCraft(row[3], row[1] .. " Local Specialty", "LOCAL", "AURORIA_SPECIALTY_WORKBENCH", true)
    RegisterCraft(row[4], row[1] .. " Fertilizer Specialty", "FERTILIZER", "FERTILIZER", false,
        "Supplemental Auroria formula; uses the shared fertilizer recipe template")
end

-- Legacy/custom live pack that still appears in the RU specialty ratio API.
RegisterCraft(5400, "Silent Forest Aged Garlic", "CUSTOM", "LEGACY_SPECIALTY_WORKBENCH", true)

-- Ingredient signatures are a frozen verification manifest from the 2026-08-27
-- ArcheRage Commerce craft-detail audit. DO NOT regenerate this manifest from
-- S.Data.TradeMaterial* at addon runtime: the two sides must remain independent
-- so Foundation diagnostics can detect accidental recipe regressions. Compact
-- material IDs are from rs_trade_materials.lua; pairs are sorted by compact ID.
local VERIFIED_INGREDIENT_SIGNATURES = {
    [5400] = "44:150|67:1|68:1", -- Silent Forest Aged Garlic
    [6202] = "5:300|7:2|10:10", -- Gweonid Commercial Gilda Specialty
    [6203] = "4:300|7:2|17:10", -- Marianople Fine Gilda Specialty
    [6204] = "2:300|7:2|14:10", -- Dewstone Fine Gilda Specialty
    [6205] = "3:300|7:2|8:10", -- Solzreed Luxury Gilda Specialty
    [6206] = "1:300|7:2|12:5", -- White Arden Commercial Gilda Specialty
    [6207] = "6:300|7:2|12:5", -- Lilyut Fine Gilda Specialty
    [6208] = "7:2|12:5|16:300", -- Two Crowns Luxury Gilda Specialty
    [6209] = "3:300|7:2|22:5", -- Hellswamp Preserved Gilda Specialty
    [6210] = "4:300|7:2|11:5", -- Cinderstone Luxury Gilda Specialty
    [6211] = "2:300|7:2|8:10", -- Halcyona Preserved Gilda Specialty
    [6212] = "7:2|16:300|24:5", -- Sanddeep Preserved Gilda Specialty
    [6213] = "7:2|16:300|45:10", -- Solis Luxury Gilda Specialty
    [6214] = "6:300|7:2|8:10", -- Arcum Iris Commercial Gilda Specialty
    [6215] = "1:300|7:2|22:5", -- Mahadevi Fine Gilda Specialty
    [6216] = "7:2|10:10|16:300", -- Falcorth Fine Gilda Specialty
    [6217] = "2:300|7:2|12:5", -- Tigerspine Fine Gilda Specialty
    [6218] = "5:300|7:2|12:5", -- Silent Forest Commercial Gilda Specialty
    [6219] = "4:300|7:2|14:10", -- Villanelle Luxury Gilda Specialty
    [6220] = "3:300|7:2|52:3", -- Windscour Preserved Gilda Specialty
    [6221] = "6:300|7:2|24:5", -- Perinoor Preserved Gilda Specialty
    [6222] = "5:300|7:2|12:5", -- Rookborne Preserved Gilda Specialty
    [6223] = "1:300|7:2|55:5", -- Ynystere Commercial Gilda Specialty
    [6224] = "7:2|16:300|17:10", -- Hasla Preserved Gilda Specialty
    [6225] = "1:180|11:5", -- Gweonid Commercial Specialty
    [6226] = "6:180|18:2", -- Marianople Fine Specialty
    [6227] = "15:15|16:180", -- Dewstone Fine Specialty
    [6228] = "3:180|9:5", -- Solzreed Luxury Specialty
    [6229] = "2:180|9:5", -- White Arden Commercial Specialty
    [6230] = "4:180|13:3", -- Lilyut Fine Specialty
    [6231] = "2:180|19:3", -- Two Crowns Luxury Specialty
    [6232] = "5:200|23:15", -- Hellswamp Preserved Specialty
    [6233] = "6:180|20:3", -- Cinderstone Luxury Specialty
    [6234] = "4:200|21:5", -- Halcyona Preserved Specialty
    [6235] = "3:200|25:5", -- Sanddeep Preserved Specialty
    [6236] = "16:180|47:2", -- Solis Luxury Specialty
    [6237] = "4:180|32:3", -- Arcum Iris Commercial Specialty
    [6238] = "5:180|38:5", -- Mahadevi Fine Specialty
    [6239] = "2:180|11:5", -- Falcorth Fine Specialty
    [6240] = "1:180|9:5", -- Tigerspine Fine Specialty
    [6241] = "6:180|19:3", -- Silent Forest Commercial Specialty
    [6242] = "4:180|18:2", -- Villanelle Luxury Specialty
    [6243] = "16:200|49:6", -- Windscour Preserved Specialty
    [6244] = "5:200|41:15", -- Perinoor Preserved Specialty
    [6245] = "1:200|11:5", -- Rookborne Preserved Specialty
    [6246] = "6:180|13:3", -- Ynystere Commercial Specialty
    [6247] = "6:180|35:5", -- Hasla Preserved Specialty
    [6248] = "16:150|40:15", -- Gweonid Commercial Local Specialty
    [6249] = "1:150|53:15", -- Marianople Fine Local Specialty
    [6250] = "5:150|36:10", -- Dewstone Fine Local Specialty
    [6251] = "6:150|57:5", -- Solzreed Luxury Local Specialty
    [6252] = "3:150|21:5", -- White Arden Commercial Local Specialty
    [6253] = "5:150|27:15", -- Lilyut Fine Local Specialty
    [6254] = "4:150|53:15", -- Two Crowns Luxury Local Specialty
    [6255] = "6:160|39:5", -- Hellswamp Preserved Local Specialty
    [6256] = "16:150|34:15", -- Cinderstone Luxury Local Specialty
    [6257] = "1:160|42:5", -- Halcyona Preserved Local Specialty
    [6258] = "2:160|37:15", -- Sanddeep Preserved Local Specialty
    [6259] = "2:150|46:5", -- Solis Luxury Local Specialty
    [6260] = "2:150|31:5", -- Arcum Iris Commercial Local Specialty
    [6261] = "6:150|37:15", -- Mahadevi Fine Local Specialty
    [6262] = "4:150|33:15", -- Falcorth Fine Local Specialty
    [6263] = "3:150|51:15", -- Tigerspine Fine Local Specialty
    [6264] = "16:150|44:15", -- Silent Forest Commercial Local Specialty
    [6265] = "1:150|27:15", -- Villanelle Luxury Local Specialty
    [6266] = "1:160|54:5", -- Windscour Preserved Local Specialty
    [6267] = "3:160|39:5", -- Perinoor Preserved Local Specialty
    [6268] = "4:160|43:5", -- Rookborne Preserved Local Specialty
    [6269] = "2:150|56:15", -- Ynystere Commercial Local Specialty
    [6270] = "5:160|29:5", -- Hasla Preserved Local Specialty
    [9331] = "4:300|7:2|17:10", -- Airain Commercial Gilda Specialty
    [9332] = "3:180|26:15", -- Airain Commercial Specialty
    [9333] = "1:150|30:5", -- Airain Commercial Local Specialty
    [9335] = "3:300|7:2|27:15", -- Aubre Commercial Gilda Specialty
    [9336] = "16:180|28:15", -- Aubre Commercial Specialty
    [9337] = "6:150|8:10", -- Aubre Commercial Local Specialty
    [9339] = "3:300|7:2|9:5", -- Ahnimar Preserved Gilda Specialty
    [9340] = "1:200|23:15", -- Ahnimar Preserved Specialty
    [9341] = "16:160|29:5", -- Ahnimar Preserved Local Specialty
    [9343] = "4:300|7:2|17:10", -- Karkasse Commercial Gilda Specialty
    [9344] = "3:180|28:15", -- Karkasse Commercial Specialty
    [9345] = "5:150|25:5", -- Karkasse Commercial Local Specialty
    [9347] = "7:2|16:300|48:5", -- Sunbite Commercial Gilda Specialty
    [9348] = "5:180|50:15", -- Sunbite Commercial Specialty
    [9349] = "2:150|49:5", -- Sunbite Commercial Local Specialty
    [9351] = "6:300|7:2|11:5", -- Rokhala Preserved Gilda Specialty
    [9352] = "16:200|34:15", -- Rokhala Preserved Specialty
    [9353] = "4:160|21:5", -- Rokhala Preserved Local Specialty
    [11559] = "1:300|7:5|58:1", -- Aegis Coastal Gilda Specialty
    [11562] = "2:300|7:5|58:1", -- Whalesong Coastal Gilda Specialty
    [11563] = "6:300|7:5|59:1", -- Exeloch Coastal Gilda Specialty
    [11564] = "7:5|16:300|61:3", -- Sungold Coastal Gilda Specialty
    [11565] = "4:300|7:5|60:3", -- Golden Ruins Coastal Gilda Specialty
    [11577] = "1:150|37:15", -- Aegis Coastal Local Specialty
    [11578] = "2:150|40:15", -- Whalesong Coastal Local Specialty
    [11579] = "6:150|51:15", -- Exeloch Coastal Local Specialty
    [11580] = "4:150|33:15", -- Sungold Coastal Local Specialty
    [11581] = "16:150|53:15", -- Golden Ruins Coastal Local Specialty
}
for craftId, signature in pairs(VERIFIED_INGREDIENT_SIGNATURES) do
    C.VerifiedIngredientSignatures[craftId] = signature
end
C.stats.verifiedIngredientSignatures = 98

function C:GetByCraftId(craftId)
    return self.ById[tonumber(craftId)]
end

function C:GetByLegacyName(legacyName)
    return self.ByLegacyName[tostring(legacyName or "")] or {}
end

function C:GetPrimaryByLegacyName(legacyName)
    return self.PrimaryByLegacyName[tostring(legacyName or "")]
end

function C:GetVerifiedIngredientSignature(craftId)
    return self.VerifiedIngredientSignatures[tonumber(craftId)]
end

function C:Describe()
    return {
        registered = tonumber(self.stats.registered) or 0,
        primary = tonumber(self.stats.primary) or 0,
        alternate = tonumber(self.stats.alternate) or 0,
        fertilizer = tonumber(self.stats.fertilizer) or 0,
        verifiedIngredientSignatures = tonumber(self.stats.verifiedIngredientSignatures) or 0,
    }
end
