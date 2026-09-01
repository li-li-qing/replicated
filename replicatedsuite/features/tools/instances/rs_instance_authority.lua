------------------------------------------------------------------------
-- Replicated Suite V3 - Instance Browser Authority
--
-- Presentation projection over InstanceCatalogV3. No Native API calls here.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Features = S.Features or {}
S.Features.InstanceBrowser = S.Features.InstanceBrowser or {}
local F = S.Features.InstanceBrowser

local A = {
    revision = 0,
    rows = {},
    byId = {},
    summary = { total = 0, mapped = 0, unmapped = 0, detailReady = 0, available = 0, limited = 0, kinds = 0 },
}
F.Authority = A

local function RowEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    return a.id == b.id
        and a.kindText == b.kindText
        and a.name == b.name
        and a.entryText == b.entryText
        and a.availabilityText == b.availabilityText
        and a.identityText == b.identityText
        and a.runtimeText == b.runtimeText
end

local function RowsEqual(a, b)
    if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then return false end
    for index = 1, #a do if RowEqual(a[index], b[index]) ~= true then return false end end
    return true
end

function A:Refresh(reason)
    local service = S.Services and S.Services.InstanceCatalogV3 or nil
    if type(service) ~= "table" or type(service.GetRows) ~= "function" then return false, "instance catalog unavailable" end
    local rawRows = service:GetRows()
    local nextRows, byId = {}, {}
    local summary = { total = 0, mapped = 0, unmapped = 0, detailReady = 0, available = 0, limited = 0, kinds = 0 }
    local kindSet = {}
    for _, item in ipairs(type(rawRows) == "table" and rawRows or {}) do
        local row = {
            id = tostring(item.id or ("instance:" .. tostring(item.instanceType or "?"))),
            instanceType = item.instanceType,
            kindType = item.kindType,
            kindText = tostring(item.kindName or "未分类"),
            name = tostring(item.name or "未知副本"),
            entryText = tostring(item.entryText or "--"),
            availabilityText = tostring(item.availabilityText or "--"),
            availabilityTone = tostring(item.availabilityTone or "muted"),
            identityText = tostring(item.identityText or "运行时ID待核验"),
            identityTone = tostring(item.identityTone or "muted"),
            runtimeText = "运行时ID #" .. tostring(item.instanceType or "?"),
            databaseZoneId = item.databaseZoneId,
            staticKey = item.staticKey,
            detailAvailable = item.detailAvailable == true,
            available = item.available == true,
            limited = item.limited == true,
            limitUsed = item.limitUsed == true,
            enterCount = tonumber(item.enterCount) or 0,
            maxEnterCount = tonumber(item.maxEnterCount) or 0,
        }
        if row.databaseZoneId ~= nil then row.runtimeText = row.runtimeText .. " · 数据库区域ID " .. tostring(row.databaseZoneId) end
        nextRows[#nextRows + 1] = row
        byId[row.id] = row
        summary.total = summary.total + 1
        if row.staticKey ~= nil then summary.mapped = summary.mapped + 1 else summary.unmapped = summary.unmapped + 1 end
        if row.detailAvailable then summary.detailReady = summary.detailReady + 1 end
        if row.available then summary.available = summary.available + 1 end
        if row.limited then summary.limited = summary.limited + 1 end
        kindSet[row.kindText] = true
    end
    for _ in pairs(kindSet) do summary.kinds = summary.kinds + 1 end

    local changed = RowsEqual(self.rows, nextRows) ~= true
    self.rows, self.byId, self.summary = nextRows, byId, summary
    if changed then
        self.revision = (tonumber(self.revision) or 0) + 1
        if S.Events ~= nil and type(S.Events.Publish) == "function" then
            S.Events:Publish("v3.instance_browser.updated", self.revision, tostring(reason or "refresh"))
        end
    end
    return true
end

function A:GetRows()
    return self.rows, self.revision
end

function A:GetRow(id)
    return self.byId[tostring(id or "")]
end

function A:GetSummary()
    local out = {}
    for key, value in pairs(self.summary or {}) do out[key] = value end
    out.revision = self.revision
    return out
end

function A:ResetTransient()
    self.rows, self.byId = {}, {}
    self.summary = { total = 0, mapped = 0, unmapped = 0, detailReady = 0, available = 0, limited = 0, kinds = 0 }
    self.revision = (tonumber(self.revision) or 0) + 1
    return true
end
