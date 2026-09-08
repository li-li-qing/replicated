#!/usr/bin/env python3
"""Real-Lua regression for TradeMaterialIdentityV3 ResolveStatic.

The .18.165 bug class: the service resolved recipes through S.StaticDataV2 (the
REGISTRY) instead of the S.Data.TradeStaticV2 ACCESSOR FACADE, so every lookup
silently returned nil and all route rows stuck at 配方解析中. This harness loads
the real service file plus the real recipe/material data and pins the layered
resolution semantics against facade accessors named exactly like the runtime.
"""
from pathlib import Path
import subprocess
import tempfile
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from rs_lua_runner import RUNNER

lua = f'''ReplicatedSuite = {{ Data = {{}}, Services = {{}}, GameIds = {{}} }}
local S = ReplicatedSuite
dofile([[{(ROOT / "data/rs_trade_materials.lua").as_posix()}]])

-- Real curated auction meta (subset is enough for row identity).
S.Data.TradeMaterialAuctionMeta = {{
    ["Lumber"] = {{ itemType = 8337, itemGrade = 0 }},
    ["Honey"] = {{ itemType = 28481, itemGrade = 0 }},
    ["Milk"] = {{ itemType = 8055, itemGrade = 1 }},
    ["Medicinal Powder"] = {{ itemType = 30903, itemGrade = 1 }},
    ["Hay Bale"] = {{ itemType = 3712, itemGrade = 0 }},
    ["Royal Seed"] = {{ itemType = 42343, itemGrade = 3 }},
    ["Cultivated Ginseng"] = {{ itemType = 3680, itemGrade = 0 }},
    ["Lemon"] = {{ itemType = 8036, itemGrade = 0 }},
}}

-- Zone Authority subset copied from data/ids/rs_zone_ids.lua definitions.
S.GameIds.Zone = {{ ById = {{
    [8] = {{ zoneId = 8, nameEn = "Two Crowns", tradeQuality = "Luxury" }},
    [22] = {{ zoneId = 22, nameEn = "Halcyona", tradeQuality = "Preserved" }},
}} }}

-- Registry mock: only what the service may consume (template catalog).
local catalogs = {{}}
S.StaticDataV2 = {{
    DefineCatalog = function(self, name) catalogs[name] = catalogs[name] or {{ records = {{}} }} end,
    Register = function(self, cat, key, row) catalogs[cat] = catalogs[cat] or {{ records = {{}} }}; catalogs[cat].records[key] = row; return row end,
    GetCatalog = function(self, name) return catalogs[name] end,
    Get = function(self, cat, key) return catalogs[cat] and catalogs[cat].records[key] or nil end,
}}
S.StaticDataV2:DefineCatalog("trade_recipe_template")
local function TemplateRow(key, raw)
    local counts, ids = raw[1], raw[2]
    local ingredients = {{}}
    for i = 1, math.min(#counts, #ids) do
        ingredients[i] = {{ materialKey = nil, compactId = ids[i], count = counts[i] }}
    end
    S.StaticDataV2:Register("trade_recipe_template", key, {{ family = key, ingredients = ingredients }})
end
TemplateRow("template.fertilizer", S.Data.TradeMaterialFertilizer)
TemplateRow("template.fragment", S.Data.TradeMaterialFragment)
TemplateRow("template.transport", S.Data.TradeMaterialTransport)

-- Accessor FACADE under the exact runtime name S.Data.TradeStaticV2, built from
-- the real legacy recipe tables. Records mirror the registered shape: enriched
-- ingredient keys ("material.xxx") + compactId, like StaticDataV2 registration.
local compactByName = {{}}
for name, row in pairs(S.Data.TradeMaterialResources or {{}}) do
    if type(row) == "table" and tonumber(row[1]) ~= nil then compactByName[name] = math.floor(row[1]) end
end
local nameByCompact, keyByCompact = {{}}, {{}}
for name, compactId in pairs(compactByName) do
    nameByCompact[compactId] = name
    keyByCompact[compactId] = "material." .. name:lower():gsub("[^%w_%%%.%-]", "_"):gsub("_+", "_")
end
local function FacadeTable(t)
    local out = {{}}
    for legacyName, raw in pairs(t) do
        local counts, ids = raw[1], raw[2]
        local ingredients = {{}}
        for i = 1, math.min(#counts, #ids) do
            ingredients[i] = {{ materialKey = keyByCompact[ids[i]], compactId = ids[i], count = counts[i] }}
        end
        out[legacyName] = {{ legacyName = legacyName, ingredients = ingredients }}
    end
    return out
end
local recipeTables = {{}}
for _, t in ipairs({{ S.Data.TradeMaterialNuia, S.Data.TradeMaterialHaranya, S.Data.TradeMaterialAuroria, S.Data.TradeMaterialCustom }}) do
    for name, record in pairs(FacadeTable(t)) do recipeTables[name] = record end
end
S.Data.TradeStaticV2 = {{
    GetRecipeByLegacyName = function(self, name) return recipeTables[tostring(name or "")] or nil end,
    GetMaterialByLegacyName = function(self, name)
        local compactId = compactByName[tostring(name or "")]
        if compactId == nil then return nil end
        return {{ nameEn = name, itemId = nil, compactId = compactId, includeInCost = true }}
    end,
    GetMaterialByCompactId = function(self, compactId)
        local name = nameByCompact[tonumber(compactId)]
        if name == nil then return nil end
        return {{ nameEn = name, compactId = compactId, includeInCost = true }}
    end,
}}

dofile([[{(ROOT / "services/rs_trade_material_identity_v3.lua").as_posix()}]])
local M = ReplicatedSuite.Services.TradeMaterialIdentityV3
assert(type(M) == "table", "service not registered")
assert(type(M.ResolveStatic) == "function")
local function eq(actual, expected, label)
  if actual ~= expected then error(label .. ": expected=" .. tostring(expected) .. " actual=" .. tostring(actual)) end
end
local function rowOf(result, index) return result.rows[index] end

-- Zone Authority + localized tail: [黄金](Halcyona/Preserved) 特制特产 → Gilda recipe.
local gilda = M:ResolveStatic("[黄金]保存特制特产", 22)
assert(gilda ~= nil, "gilda pack unresolved")
eq(gilda.label, "Halcyona Preserved Gilda Specialty", "gilda label")
eq(gilda.source, "static_recipe", "gilda source")
eq(#gilda.rows, 3, "gilda ingredient count")
eq(rowOf(gilda, 1).count, 300, "gilda first count")

-- 传统特产 must map to Local Specialty (the historical mis-mapping hazard).
local localSpec = M:ResolveStatic("[黄金]保存传统特产", 22)
assert(localSpec ~= nil, "traditional pack unresolved")
eq(localSpec.label, "Halcyona Preserved Local Specialty", "traditional->local label")
eq(rowOf(localSpec, 1).count, 160, "local first count")

-- Plain 特产 tail.
local plain = M:ResolveStatic("黄金平原特产", 22)
assert(plain ~= nil, "plain pack unresolved")
eq(plain.label, "Halcyona Preserved Specialty", "plain label")

-- Shared larder family: 奶酪 keyword wins regardless of zone.
local cheese = M:ResolveStatic("黄金平原加工发酵奶酪", 22)
assert(cheese ~= nil, "cheese family unresolved")
eq(cheese.source, "static_family", "cheese family source")
eq(cheese.label, "陈化奶酪", "cheese label")
eq(#cheese.rows, 4, "cheese ingredient count")
eq(rowOf(cheese, 1).materialKey, "Lumber", "cheese first material key")
eq(rowOf(cheese, 2).materialKey, "Milk", "cheese second material key")

-- Fertilizer template family.
local fertilizer = M:ResolveStatic("[黄金]保存肥料特产", 22)
assert(fertilizer ~= nil, "fertilizer family unresolved")
eq(fertilizer.source, "static_family", "fertilizer source")
eq(#fertilizer.rows, 4, "fertilizer ingredient count")

-- Localized text must NEVER choose the region: no originZone -> no identity.
eq(M:ResolveStatic("黄金平原特产", nil), nil, "missing originZone must stay unresolved")
-- Unknown pack stays honestly unresolved.
eq(M:ResolveStatic("完全未知的货物名", 22), nil, "unknown pack must stay unresolved")

-- Live cache state helpers exist for the projection state machine.
assert(type(M.GetCachedLive) == "function" and type(M.HasLiveAttempt) == "function")

print("TRADE_MATERIAL_IDENTITY_LUA_HARNESS_PASS 8/8")
'''
with tempfile.NamedTemporaryFile("w", suffix=".lua", encoding="utf-8", delete=False) as f:
    f.write(lua)
    script = f.name
try:
    proc = subprocess.run([RUNNER, script], capture_output=True, text=True, encoding="utf-8")
finally:
    Path(script).unlink(missing_ok=True)
if proc.returncode != 0:
    print("TRADE_MATERIAL_IDENTITY_LUA_HARNESS FAIL")
    print(proc.stdout)
    print(proc.stderr)
    sys.exit(proc.returncode or 1)
print(proc.stdout.strip())
