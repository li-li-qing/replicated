------------------------------------------------------------------------
-- Replicated Suite V3 - Combat Mechanic Catalog
-- Exact O(1) indexes compiled from BossAlerts. No fuzzy scan in combat hot path.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Data = S.Data or {}
local Source = S.Data.BossAlerts
local C = { version = 1, ByCastName = {}, ByDebuffId = {}, count = 0 }
S.Data.CombatMechanicCatalog = C

local function Normalize(value)
    return string.lower((tostring(value or ""):match("^%s*(.-)%s*$") or ""))
end
for _, spec in ipairs(type(Source) == "table" and Source or {}) do
    local row = {
        key = tostring(spec.key or ""), kind = tostring(spec.kind or ""), alert = tostring(spec.alert or ""),
        style = tostring(spec.style or ""), debuffId = tonumber(spec.debuffId), source = "BossAlerts",
    }
    if row.key ~= "" then
        C.count = C.count + 1
        if row.kind == "debuff" and row.debuffId ~= nil then C.ByDebuffId[row.debuffId] = row end
        if row.kind == "cast" then
            for _, name in ipairs(type(spec.names) == "table" and spec.names or {}) do
                local key = Normalize(name)
                if key ~= "" and C.ByCastName[key] == nil then C.ByCastName[key] = row end
            end
        end
    end
end
function C:FindCast(name) return self.ByCastName[Normalize(name)] end
function C:FindDebuff(id) return self.ByDebuffId[tonumber(id)] end
function C:GetHealth() return { version = self.version, mechanics = self.count } end
