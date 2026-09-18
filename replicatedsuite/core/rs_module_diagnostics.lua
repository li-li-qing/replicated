------------------------------------------------------------------------
-- Replicated Suite - Module Diagnostics Hub
--
-- 中文维护注释（2026-09-18，module-diagnostics-1）：
-- 原因：全局 SelfCheck 随 Feature 增长不断膨胀，用户为了一个模块故障必须复制所有模块、
-- Store 与 UI 证据；同时业务页面各自手写诊断会产生第二套身份/分页/错误池。
-- Authority：FeatureRegistry 是 moduleId/route/name 唯一身份 Authority；DiagnosticsManager
-- 是结构化错误唯一 Authority；本 Hub 只做“可证明归属”的有界投影与用户显式点击时的冷快照。
-- 数据流：DiagnosticsManager:_Append -> Observe(detached entry) -> module ring(<=32)；
-- 用户点击生成诊断 -> BuildReport -> ReportCopyTransport 固定分页。翻页只消费 snapshot，
-- 绝不重新调用 Provider、Persistence、Feature 或 Native API。
-- 兼容边界：无法证明归属的共享错误只进入 system；Provider 不得 Enable Feature/Acquire
-- Consumer；本 Hub 本身也永远不调用 Initialize/Enable。未来禁止把它升级成业务 Authority、
-- 后台轮询器或无界日志仓库。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

local RING_MAX = 32
local PROVIDER_MAX = 16
local REPORT_VALUE_DEPTH = 4
local REPORT_STRING_MAX = 1200

S.ModuleDiagnosticsHub = type(S.ModuleDiagnosticsHub) == "table" and S.ModuleDiagnosticsHub or {
    version = 1,
    contractVersion = 1,
    rings = {},
    providers = {},
    storeOwners = {},
    captureSequence = 0,
    stats = { observed = 0, routed = 0, system = 0, evicted = 0, providerFailures = 0, captures = 0 },
}
local H = S.ModuleDiagnosticsHub

local function Normalize(value)
    return tostring(value or ""):lower():gsub("[^%w_%.%-]", "_"):gsub("_+", "_"):gsub("^_+", ""):gsub("_+$", "")
end

local function Copy(value, depth)
    depth = tonumber(depth) or 0
    if depth > 5 or type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do out[key] = Copy(item, depth + 1) end
    return out
end

local function Clip(value, limit)
    local text = tostring(value or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    limit = tonumber(limit) or REPORT_STRING_MAX
    if #text > limit then return text:sub(1, limit) .. "…" end
    return text
end

local function Keys(value)
    local out = {}
    if type(value) == "table" then for key in pairs(value) do out[#out + 1] = key end end
    table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
    return out
end

local function ValueText(value, depth, seen)
    depth = tonumber(depth) or 0
    local kind = type(value)
    if kind == "nil" then return "nil" end
    if kind == "boolean" or kind == "number" then return tostring(value) end
    if kind == "string" then return Clip(value) end
    if kind ~= "table" then return "<" .. kind .. ">" end
    if depth >= REPORT_VALUE_DEPTH then return "<table>" end
    seen = seen or {}
    if seen[value] then return "<cycle>" end
    seen[value] = true
    local parts, count = {}, 0
    for _, key in ipairs(Keys(value)) do
        count = count + 1
        if count > 48 then parts[#parts + 1] = "…"; break end
        parts[#parts + 1] = tostring(key) .. "=" .. ValueText(value[key], depth + 1, seen)
    end
    seen[value] = nil
    return "{" .. table.concat(parts, ",") .. "}"
end

local function Registry()
    return type(S.FeatureRegistry) == "table" and S.FeatureRegistry or nil
end

local function Meta(moduleId)
    local registry = Registry()
    if registry == nil or type(registry.Get) ~= "function" then return nil end
    return registry:Get(moduleId)
end

local function AuthorityTokens(meta)
    local tokens = {}
    local text = tostring(meta and meta.authority or "")
    for token in text:gmatch("v3[%w_%.%-]+") do tokens[#tokens + 1] = token end
    table.sort(tokens, function(a, b) return #a > #b end)
    return tokens
end

function H:RegisterStoreOwner(moduleId, value)
    moduleId = Normalize(moduleId)
    value = tostring(value or "")
    if moduleId == "" or value == "" or Meta(moduleId) == nil then return false, "module/store identity required" end
    self.storeOwners[value] = moduleId
    return true
end

function H:_ResolveByStore(storeId, owner)
    storeId, owner = tostring(storeId or ""), tostring(owner or "")
    if storeId ~= "" and self.storeOwners[storeId] ~= nil then return self.storeOwners[storeId] end
    if owner ~= "" and self.storeOwners[owner] ~= nil then return self.storeOwners[owner] end
    local registry = Registry()
    if registry == nil or type(registry.List) ~= "function" then return nil end
    local best, bestLen = nil, 0
    for _, meta in ipairs(registry:List()) do
        for _, token in ipairs(AuthorityTokens(meta)) do
            local matches = owner == token or storeId == token
                or (storeId ~= "" and storeId:sub(1, #token + 1) == token .. ".")
                or (owner ~= "" and owner:sub(1, #token + 1) == token .. ".")
            if matches and #token > bestLen then best, bestLen = meta.id, #token end
        end
    end
    return best
end

function H:ResolveModule(entry)
    entry = type(entry) == "table" and entry or {}
    local context = type(entry.context) == "table" and entry.context or {}
    local registry = Registry()
    local explicit = Normalize(context.moduleId or context.featureId or context.feature)
    if explicit ~= "" and Meta(explicit) ~= nil then return explicit end
    local route = tostring(context.route or "")
    if route ~= "" and registry ~= nil and type(registry.GetByRoute) == "function" then
        local row = registry:GetByRoute(route); if row ~= nil then return row.id end
    end
    local storeModule = self:_ResolveByStore(context.store, context.owner)
    if storeModule ~= nil then return storeModule end
    local source = tostring(entry.source or "")
    if source ~= "" and registry ~= nil then
        local byId = type(registry.Get) == "function" and registry:Get(source) or nil
        if byId ~= nil then return byId.id end
        local byRoute = type(registry.GetByRoute) == "function" and registry:GetByRoute(source) or nil
        if byRoute ~= nil then return byRoute.id end
        -- 中文维护注释：历史模块长期使用 buff_display_v3 / dps_v3 等 source。它们只能由
        -- FeatureRegistry.diagnosticSources 显式声明后精确归属；禁止在 Hub 里做去后缀、包含词、
        -- 编辑距离等模糊推断，否则 ui_v3/static_data 等共享 source 会被错误塞进业务模块。
        if type(registry.List) == "function" then
            for _, meta in ipairs(registry:List()) do
                for _, alias in ipairs(type(meta.diagnosticSources) == "table" and meta.diagnosticSources or {}) do
                    if source == tostring(alias) then return meta.id end
                end
            end
        end
    end
    return "system"
end

function H:Observe(entry)
    if type(entry) ~= "table" then return false, "entry required" end
    local moduleId = self:ResolveModule(entry)
    if moduleId ~= "system" and Meta(moduleId) == nil then moduleId = "system" end
    local ring = self.rings[moduleId]
    if type(ring) ~= "table" then ring = {}; self.rings[moduleId] = ring end
    ring[#ring + 1] = Copy(entry)
    self.stats.observed = (tonumber(self.stats.observed) or 0) + 1
    if moduleId == "system" then self.stats.system = (tonumber(self.stats.system) or 0) + 1
    else self.stats.routed = (tonumber(self.stats.routed) or 0) + 1 end
    while #ring > RING_MAX do table.remove(ring, 1); self.stats.evicted = (tonumber(self.stats.evicted) or 0) + 1 end
    return true, moduleId
end

function H:GetRecent(moduleId)
    moduleId = Normalize(moduleId)
    if moduleId == "" then moduleId = "system" end
    local out = {}
    for _, row in ipairs(self.rings[moduleId] or {}) do out[#out + 1] = Copy(row) end
    return out
end

function H:_CollectReportRecent(moduleId)
    -- 中文维护注释（2026-09-18）：Hub 的热路径 Observe 可能早于 FeatureRegistry 加载；此时
    -- 可证明为某 Feature 的 Persistence/UI 错误会先安全落入 system ring。用户点击生成诊断时
    -- 才允许在全局 Diagnostics 最近 80 条的有界缓存上重新归属一次。Authority 仍是
    -- DiagnosticsManager.recent；这里只构造临时报表列表，不搬迁/删除历史、不产生新日志。
    -- 这样既补回启动早期业务错误，又不会在每条错误热路径上等待 Registry 或做全表扫描。
    moduleId = Normalize(moduleId)
    local out, seen = {}, {}
    local function Add(row)
        if type(row) ~= "table" then return end
        local key = tostring(row.seq or "")
        if key ~= "" and seen[key] then return end
        if key ~= "" then seen[key] = true end
        out[#out + 1] = Copy(row)
    end
    for _, row in ipairs(self.rings[moduleId] or {}) do Add(row) end
    local diagnostics = S.DiagnosticsManager
    for _, row in ipairs(type(diagnostics) == "table" and diagnostics.recent or {}) do
        if self:ResolveModule(row) == moduleId then Add(row) end
    end
    table.sort(out, function(a, b)
        local as, bs = tonumber(a.seq) or 0, tonumber(b.seq) or 0
        if as ~= bs then return as < bs end
        return tostring(a.code or "") < tostring(b.code or "")
    end)
    while #out > RING_MAX do table.remove(out, 1) end
    return out
end

function H:RegisterProvider(moduleId, id, provider, priority)
    moduleId, id = Normalize(moduleId), Normalize(id)
    if Meta(moduleId) == nil then return false, "unknown module" end
    if id == "" or type(provider) ~= "function" then return false, "provider identity required" end
    local rows = self.providers[moduleId]
    if type(rows) ~= "table" then rows = {}; self.providers[moduleId] = rows end
    for _, row in ipairs(rows) do if row.id == id then return false, "duplicate provider" end end
    if #rows >= PROVIDER_MAX then return false, "provider limit" end
    rows[#rows + 1] = { id = id, fn = provider, priority = tonumber(priority) or 100 }
    table.sort(rows, function(a, b) if a.priority ~= b.priority then return a.priority < b.priority end return a.id < b.id end)
    return true
end

function H:_StoreBelongs(moduleId, row)
    if type(row) ~= "table" then return false end
    local explicit = self:_ResolveByStore(row.id, row.owner)
    return explicit == moduleId
end

local function RuntimeState(moduleId)
    local runtime = S.FeatureRuntime
    local state = type(runtime) == "table" and type(runtime.state) == "table" and runtime.state[moduleId] or nil
    local implemented = type(runtime) == "table" and type(runtime.implementations) == "table" and runtime.implementations[moduleId] ~= nil
    return {
        implemented = implemented,
        initialized = type(state) == "table" and state.initialized == true or false,
        enabled = type(state) == "table" and state.enabled == true or false,
        faulted = type(state) == "table" and state.faulted == true or false,
        lastError = type(state) == "table" and state.lastError or nil,
    }
end

function H:BuildReport(moduleId)
    moduleId = Normalize(moduleId)
    local meta = Meta(moduleId)
    if meta == nil then return nil, "unknown module: " .. tostring(moduleId) end
    local runtime = RuntimeState(moduleId)
    local lines = {
        "RS-MODULE-DIAG-1",
        "BUILD=" .. tostring(S.BuildTag or "?"),
        "MODULE=" .. moduleId,
        "NAME=" .. tostring(meta.name or moduleId),
        "ROUTE=" .. tostring(meta.route or ""),
        "CAPTURED_MS=" .. tostring(type(S.NowMs) == "function" and S.NowMs() or 0),
        "[MODULE_HEADER]",
        "implemented=" .. tostring(runtime.implemented) .. "/initialized=" .. tostring(runtime.initialized)
            .. "/enabled=" .. tostring(runtime.enabled) .. "/faulted=" .. tostring(runtime.faulted),
    }
    if runtime.lastError ~= nil then lines[#lines + 1] = "lastError=" .. Clip(runtime.lastError) end

    lines[#lines + 1] = "[MODULE_STATUS]"
    local impl = type(S.FeatureRuntime) == "table" and type(S.FeatureRuntime.implementations) == "table"
        and S.FeatureRuntime.implementations[moduleId] or nil
    if runtime.initialized and type(impl) == "table" and type(impl.GetHealth) == "function" then
        local ok, value = xpcall(function() return impl:GetHealth() end, S.SafeTraceback or tostring)
        lines[#lines + 1] = ok and ("featureHealth=" .. ValueText(value)) or ("featureHealthError=" .. Clip(value))
    else
        lines[#lines + 1] = "featureHealth=not_sampled(uninitialized_or_unavailable)"
    end

    local providerFailures = 0
    for _, row in ipairs(self.providers[moduleId] or {}) do
        local ok, value, detail = xpcall(function() return row.fn(moduleId, meta) end, S.SafeTraceback or tostring)
        if ok and value ~= false then
            lines[#lines + 1] = "provider." .. row.id .. "=" .. ValueText(value)
        else
            providerFailures = providerFailures + 1
            self.stats.providerFailures = (tonumber(self.stats.providerFailures) or 0) + 1
            lines[#lines + 1] = "provider." .. row.id .. "=<failed:" .. Clip(ok and detail or value, 360) .. ">"
        end
    end

    lines[#lines + 1] = "[MODULE_ERRORS]"
    local recent = self:_CollectReportRecent(moduleId)
    if #recent == 0 then lines[#lines + 1] = "none" end
    for _, row in ipairs(recent) do
        lines[#lines + 1] = string.format("#%s %s/%s %s%s", tostring(row.seq or "?"), tostring(row.level or "?"),
            tostring(row.source or "?"), Clip(row.code or "LEGACY", 96) .. ":" .. Clip(row.message or "", 700),
            type(row.context) == "table" and (" " .. ValueText(row.context)) or "")
    end

    lines[#lines + 1] = "[MODULE_STORES]"
    local describe = type(S.Persistence) == "table" and type(S.Persistence.Describe) == "function" and S.Persistence:Describe() or nil
    local storeCount = 0
    for _, row in ipairs(type(describe) == "table" and describe.rows or {}) do
        if self:_StoreBelongs(moduleId, row) then
            storeCount = storeCount + 1
            lines[#lines + 1] = tostring(row.id or "?") .. " owner=" .. tostring(row.owner or "?")
                .. " load=" .. tostring(row.loadStatus or "?") .. " integrity=" .. tostring(row.lastIntegrityStatus or "?")
                .. " fenced=" .. tostring(row.writeFenced == true) .. " saveFail=" .. tostring(row.consecutiveSaveFailures or 0)
                .. (row.writeFenceReason and (" reason=" .. Clip(row.writeFenceReason, 400)) or "")
        end
    end
    if storeCount == 0 then lines[#lines + 1] = "none" end

    lines[#lines + 1] = "[MODULE_UI]"
    local host = S.UIV3 and S.UIV3.PageHost or nil
    local pageCreated = type(host) == "table" and type(host.pages) == "table" and host.pages[tostring(meta.route or "")] ~= nil or false
    lines[#lines + 1] = "activeRoute=" .. tostring(type(host) == "table" and host.activeRoute or "")
        .. "/pageCreated=" .. tostring(pageCreated)

    lines[#lines + 1] = "[RESULT] providerFailures=" .. tostring(providerFailures) .. " errors=" .. tostring(#recent)
        .. " stores=" .. tostring(storeCount)
    lines[#lines + 1] = "RS-MODULE-DIAG-END"
    return table.concat(lines, "\n")
end

function H:Capture(moduleId, capacity)
    local report, err = self:BuildReport(moduleId)
    if report == nil then return nil, err end
    local transport = S.ReportCopyTransport
    if type(transport) ~= "table" or type(transport.BuildTextPages) ~= "function" then return nil, "report paging unavailable" end
    self.captureSequence = (tonumber(self.captureSequence) or 0) + 1
    local id = "MD" .. tostring(self.captureSequence) .. "." .. Normalize(moduleId)
    local session, pageErr = transport:BuildTextPages(report, tonumber(capacity) or 3500, id)
    if session == nil then return nil, pageErr end
    self.stats.captures = (tonumber(self.stats.captures) or 0) + 1
    return { version = 1, id = id, moduleId = Normalize(moduleId), report = report, session = session,
        parts = tonumber(session.parts) or 1, capturedAt = type(S.NowMs) == "function" and S.NowMs() or 0 }
end

function H:GetPage(snapshot, index)
    if type(snapshot) ~= "table" or type(snapshot.session) ~= "table" then return nil, "module diagnostic snapshot required" end
    local transport = S.ReportCopyTransport
    if type(transport) ~= "table" or type(transport.GetTextPage) ~= "function" then return nil, "report paging unavailable" end
    return transport:GetTextPage(snapshot.session, index)
end

function H:Describe()
    local modules = 0
    for _ in pairs(self.rings) do modules = modules + 1 end
    return { version = self.version, contractVersion = self.contractVersion, modules = modules, ringMax = RING_MAX,
        observed = tonumber(self.stats.observed) or 0, routed = tonumber(self.stats.routed) or 0,
        system = tonumber(self.stats.system) or 0, evicted = tonumber(self.stats.evicted) or 0,
        providerFailures = tonumber(self.stats.providerFailures) or 0, captures = tonumber(self.stats.captures) or 0 }
end
