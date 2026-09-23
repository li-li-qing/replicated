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

-- 维护（module-controls-diag-2）：重载会保留Suite全局表，错误池/Provider却只属于一次加载。
-- Generation不同时丢弃旧投影，避免旧故障冒充“本次加载”；旧窗口由Bootstrap统一退役。
-- 同Generation重复执行文件仍可复用；早期错误留在新DiagnosticsManager，Capture再按身份归属。
S.ModuleDiagnosticsHub = type(S.ModuleDiagnosticsHub) == "table"
    and S.ModuleDiagnosticsHub.generation == (tonumber(S.Generation) or 0) and S.ModuleDiagnosticsHub or {
    generation = tonumber(S.Generation) or 0,
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

-- 维护（module-controls-diag-2）：深层快照不得返回原表，避免后续业务修改污染已冻结报告。
-- 复制仅允许有界 primitive 树；没有 Native/UObject 类引用，也不会递归环形或巨大业务对象。
local function Copy(value, depth, seen)
    depth = tonumber(depth) or 0
    if type(value) ~= "table" then return value end
    if depth > 5 then return "<depth_limit>" end
    seen = seen or {}; if seen[value] then return "<cycle>" end; seen[value] = true
    local out, count = {}, 0
    for key, item in pairs(value) do
        count = count + 1; if count > 64 then out.__truncated = true; break end
        if type(key) == "string" or type(key) == "number" then out[key] = Copy(item, depth + 1, seen) end
    end
    seen[value] = nil
    return out
end

local function Clip(value, limit)
    local text = tostring(value or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    limit = tonumber(limit) or REPORT_STRING_MAX
    if #text > limit then
        local finish = limit
        while finish > 0 and (text:byte(finish + 1) or 0) >= 128 and (text:byte(finish + 1) or 0) < 192 do finish = finish - 1 end
        return text:sub(1, finish) .. "[TRUNCATED originalBytes=" .. tostring(#text) .. "]"
    end
    return text
end

local function Keys(value)
    local out = {}
    if type(value) == "table" then
        for key in pairs(value) do out[#out + 1] = key; if #out >= 64 then break end end
    end
    table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
    return out
end

local function ValueText(value, depth, seen, budget)
    depth = tonumber(depth) or 0
    budget = budget or { left = 16384, nodes = 256 }
    budget.nodes = budget.nodes - 1
    if budget.left <= 0 or budget.nodes <= 0 then return "<serialization_budget>" end
    local kind = type(value)
    if kind == "nil" then return "nil" end
    if kind == "boolean" or kind == "number" then return tostring(value) end
    if kind == "string" then
        local text = Clip(value, math.min(REPORT_STRING_MAX, budget.left))
        budget.left = budget.left - #text
        return text
    end
    if kind ~= "table" then return "<" .. kind .. ">" end
    if depth >= REPORT_VALUE_DEPTH then return "<table>" end
    seen = seen or {}
    if seen[value] then return "<cycle>" end
    seen[value] = true
    local parts, count = {}, 0
    for _, key in ipairs(Keys(value)) do
        count = count + 1
        if count > 48 then parts[#parts + 1] = "…"; break end
        parts[#parts + 1] = tostring(key) .. "=" .. ValueText(value[key], depth + 1, seen, budget)
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

-- 维护（module-controls-diag-2）：注册时编译身份索引，错误热路径不再逐模块分词/Tag匹配。
-- 同一个共享 Authority 被多个模块引用时标记为歧义，保留在 system；明确 moduleId/route 优先。
function H:_IdentityIndex()
    local registry = Registry()
    if registry == nil then return nil end
    local revision = tonumber(registry.registrationRevision) or #(registry.order or {})
    local old = self.identityIndex
    if old and old.registry == registry and old.revision == revision then return old end
    local index = { registry = registry, revision = revision, sources = {}, routes = {}, stores = {} }
    local function Put(map, key, id)
        if key == nil or key == "" then return end
        if map[key] == nil then map[key] = id elseif map[key] ~= id then map[key] = false end
    end
    for _, meta in ipairs(type(registry.List) == "function" and registry:List() or {}) do
        Put(index.sources, meta.id, meta.id); Put(index.sources, meta.route, meta.id); Put(index.routes, meta.route, meta.id)
        for _, alias in ipairs(meta.diagnosticSources or {}) do Put(index.sources, alias, meta.id) end
        for _, token in ipairs(AuthorityTokens(meta)) do Put(index.stores, token, meta.id) end
    end
    self.identityIndex = index
    return index
end

function H:_ResolveByStore(storeId, owner)
    local index = self:_IdentityIndex()
    local function Find(value)
        value = tostring(value or "")
        -- 最长前缀逐段回退只与 ID 层数有关；共享歧义前缀不会退到更宽的错误 Owner。
        for _ = 1, 16 do
            if value == "" then break end
            if self.storeOwners[value] ~= nil then return self.storeOwners[value] end
            if index and index.stores[value] ~= nil then return index.stores[value] end
            local shorter = value:match("^(.*)%.[^%.]+$")
            if shorter == nil then break end
            value = shorter
        end
        return nil
    end
    local byStore = Find(storeId)
    if byStore ~= nil then return byStore or nil end
    return Find(owner) or nil
end

function H:ResolveModule(entry)
    entry = type(entry) == "table" and entry or {}
    local context = type(entry.faultEvidence) == "table" and entry.faultEvidence or entry.context or {}
    local explicit = Normalize(context.moduleId or context.featureId or context.feature)
    if explicit ~= "" and Meta(explicit) ~= nil then return explicit end
    local index = self:_IdentityIndex()
    local route = index and index.routes[tostring(context.route or "")]
    if route then return route end
    local owner = self:_ResolveByStore(context.store, context.owner)
    if owner then return owner end
    return index and index.sources[tostring(entry.source or "")] or "system"
end

local function IsFault(row)
    return row.level == "error" or row.level == "warning" or row.level == "warn" or row.level == "fatal"
end
local function SameFault(a, b)
    if not a or a.level ~= b.level or a.source ~= b.source or a.code ~= b.code or a.message ~= b.message then return false end
    local left, right = a.faultEvidence or a.context or {}, b.faultEvidence or b.context or {}
    for key, value in pairs(left) do if right[key] ~= value then return false end end
    for key, value in pairs(right) do if left[key] ~= value then return false end end
    return true
end
function H:_ModuleCounters(id)
    self.moduleCounters = self.moduleCounters or {}
    self.moduleCounters[id] = self.moduleCounters[id] or { ignored = 0, evicted = 0, repeats = 0 }
    return self.moduleCounters[id]
end

function H:Observe(entry)
    -- 新Manager已加载、Hub尚未加载的短暂边界不写旧代投影；全局recent仍保留新证据。
    if self.generation ~= (tonumber(S.Generation) or 0) then return false, "retired_generation" end
    if type(entry) ~= "table" then return false, "entry required" end
    local moduleId = self:ResolveModule(entry)
    if moduleId ~= "system" and Meta(moduleId) == nil then moduleId = "system" end
    local counters = self:_ModuleCounters(moduleId)
    self.stats.observed = (tonumber(self.stats.observed) or 0) + 1
    -- 信息日志留在全局日志；模块故障池只保留 warning/error，防止正常刷新淹没真实故障。
    if not IsFault(entry) then counters.ignored = counters.ignored + 1; return true, moduleId end
    local ring = self.rings[moduleId]
    if type(ring) ~= "table" then ring = {}; self.rings[moduleId] = ring end
    local last = ring[#ring]
    if SameFault(last, entry) then
        last.count = (tonumber(last.count) or 1) + (tonumber(entry.count) or 1)
        last.lastSeq = entry.seq; last.lastAt = entry.lastAt or entry.at
        counters.repeats = counters.repeats + (tonumber(entry.count) or 1)
    else
        ring[#ring + 1] = Copy(entry)
    end
    if moduleId == "system" then self.stats.system = (tonumber(self.stats.system) or 0) + 1
    else self.stats.routed = (tonumber(self.stats.routed) or 0) + 1 end
    while #ring > RING_MAX do
        table.remove(ring, 1); self.stats.evicted = (tonumber(self.stats.evicted) or 0) + 1
        counters.evicted = counters.evicted + 1
    end
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
    if moduleId == "system_diagnostics" then moduleId = "system" end
    local out, seen = {}, {}
    local function Add(row)
        if type(row) ~= "table" or not IsFault(row) then return end
        for _, prior in ipairs(out) do
            if SameFault(prior, row) and (tonumber(row.seq) or 0) >= (tonumber(prior.seq) or 0)
                and (tonumber(row.seq) or 0) <= (tonumber(prior.lastSeq or prior.seq) or 0) then return end
        end
        local key = tostring(row.seq or "")
        if key ~= "" and seen[key] then return end
        if key ~= "" then seen[key] = true end
        out[#out + 1] = Copy(row)
    end
    for _, row in ipairs(self.rings[moduleId] or {}) do
        if self:ResolveModule(row) == moduleId then Add(row) end
    end
    -- Registry 未就绪时落入 system 的故障即便已被全局80条淘汰，也从有界 system 池重新归属。
    if moduleId ~= "system" then
        for _, row in ipairs(self.rings.system or {}) do if self:ResolveModule(row) == moduleId then Add(row) end end
    end
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
    local providerFailures = 0
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
        if not ok or value == nil or value == false then providerFailures = providerFailures + 1 end
        lines[#lines + 1] = ok and ("featureHealth=" .. ValueText(value)) or ("featureHealthError=" .. Clip(value))
    else
        lines[#lines + 1] = "featureHealth=not_sampled(uninitialized_or_unavailable)"
    end

    for _, row in ipairs(self.providers[moduleId] or {}) do
        local ok, value, detail = xpcall(function() return row.fn(moduleId, meta) end, S.SafeTraceback or tostring)
        if ok and value ~= false and value ~= nil then
            lines[#lines + 1] = "provider." .. row.id .. "=" .. ValueText(value)
        else
            providerFailures = providerFailures + 1
            self.stats.providerFailures = (tonumber(self.stats.providerFailures) or 0) + 1
            lines[#lines + 1] = "provider." .. row.id .. "=<failed:" .. Clip(ok and detail or value, 360) .. ">"
        end
    end

    -- 维护（viewport-recovery-1）：只在用户生成报告时采样已存在窗口，按模块隔离。
    -- 不运行 EnsurePreferences/GetState，不加载未启用业务；当前几何与持久 intent 分列。
    -- 系统诊断额外覆盖主窗及未挂 WidgetHost 的辅助窗，避免 errors=0 掩盖离屏。
    lines[#lines+1]="[WINDOW_PLACEMENT]"
    if S.Layout and type(S.Layout.GetContext)=="function" then
        local sampled,detail=pcall(S.Layout.GetContext,S.Layout,true)
        if not sampled then providerFailures=providerFailures+1;lines[#lines+1]="metricsSampleError="..Clip(detail) end
    end
    local widgetHost=S.UIV3 and S.UIV3.WidgetHost
    local windowCount=0
    if widgetHost and type(widgetHost.GetPlacementDiagnostics)=="function" then
        for _,id in ipairs(widgetHost.order or {}) do
            local widgetSpec=widgetHost.specs[id]
            if widgetSpec and (widgetSpec.featureId==moduleId or moduleId=="system_diagnostics") then
                local ok,value=pcall(function()return widgetHost:GetPlacementDiagnostics(id)end)
                lines[#lines+1]="widget."..tostring(id).."="..(ok and ValueText(value) or ("<failed:"..Clip(value)..">"))
                if not ok then providerFailures=providerFailures+1 end
                windowCount=windowCount+1
            end
        end
    end
    if moduleId=="system_diagnostics" then
        local main=S.UIV3 and S.UIV3.Shell
        if main and type(main.GetPlacementDiagnostics)=="function" then
            local ok,value=pcall(function()return main:GetPlacementDiagnostics()end)
            lines[#lines+1]="main="..(ok and ValueText(value) or ("<failed:"..Clip(value)..">"))
            if not ok then providerFailures=providerFailures+1 end
        end
        local registry=S.Layout and S.Layout.floatingRegistry or {}
        -- 维护：按需、有界、稳定排序；provider 不得创建窗或读盘，单窗采集失败不丢其它证据。
        for _,id in ipairs(Keys(registry))do
            local item=registry[id]
            if item and item.options and type(item.options.getPlacementDiagnostics)=="function" then
                local ok,value=pcall(item.options.getPlacementDiagnostics)
                lines[#lines+1]="aux."..tostring(id).."="..(ok and ValueText(value) or ("<failed:"..Clip(value)..">"))
                if not ok then providerFailures=providerFailures+1 end
            end
            if item and item.lastRevalidateError then lines[#lines+1]="revalidate."..tostring(id).."="..Clip(item.lastRevalidateError) end
        end
        if S.Layout then lines[#lines+1]="metricsNotifications="..ValueText(S.Layout.metricsNotifications) end
        local launcher=S.UIV3 and S.UIV3.LauncherPlacementInfo
        if launcher then lines[#lines+1]="launcher.lastPlacement="..ValueText(launcher) end
    end
    if windowCount==0 then lines[#lines+1]="widgets=none_registered_for_module" end

    lines[#lines + 1] = "[MODULE_ERRORS]"
    local recent = self:_CollectReportRecent(moduleId)
    if #recent == 0 then lines[#lines + 1] = "none" end
    for _, row in ipairs(recent) do
        lines[#lines + 1] = string.format("#%s %s/%s %s%s", tostring(row.seq or "?"), tostring(row.level or "?"),
            tostring(row.source or "?"), Clip(row.code or "LEGACY", 96) .. ":" .. Clip(row.message or "", 700),
            type(row.context) == "table" and (" " .. ValueText(row.context)) or "")
        lines[#lines + 1] = " occurrences=" .. tostring(row.count or 1) .. " firstMs=" .. tostring(row.firstAt or row.at or "?")
            .. " lastMs=" .. tostring(row.lastAt or row.at or "?")
        -- 入库时已经有界且只含白名单 primitive；不再套1200字节的短摘要裁剪，保留根因头尾。
        for _, key in ipairs(Keys(row.faultEvidence)) do
            lines[#lines + 1] = " evidence." .. tostring(key) .. "=" .. tostring(row.faultEvidence[key])
        end
    end

    lines[#lines + 1] = "[MODULE_STORES]"
    -- 维护（module-controls-diag-2）：存档/健康/Provider 各自隔离，诊断自身异常必须成为证据而非吞掉报告。
    -- Describe 只读现有状态，不做 Load/Recover/Save；异常不影响其他分区的证据输出。
    local describe
    if type(S.Persistence) == "table" and type(S.Persistence.Describe) == "function" then
        local ok, value = xpcall(function() return S.Persistence:Describe() end, S.SafeTraceback or tostring)
        if ok and type(value) == "table" then describe = value
        else
            providerFailures = providerFailures + 1
            lines[#lines + 1] = "storeCollectorError=" .. Clip(value, 4096)
        end
    else
        lines[#lines + 1] = "storeCollector=unavailable"
        providerFailures = providerFailures + 1
    end
    local storeCount, storeFaults = 0, 0
    for _, row in ipairs(type(describe) == "table" and describe.rows or {}) do
        if self:_StoreBelongs(moduleId, row) then
            storeCount = storeCount + 1
            if row.writeFenced == true or (tonumber(row.consecutiveSaveFailures) or 0) > 0 then storeFaults = storeFaults + 1 end
            lines[#lines + 1] = tostring(row.id or "?") .. " owner=" .. tostring(row.owner or "?")
                .. " load=" .. tostring(row.loadStatus or "?") .. " integrity=" .. tostring(row.lastIntegrityStatus or "?")
                .. " fenced=" .. tostring(row.writeFenced == true) .. " saveFail=" .. tostring(row.consecutiveSaveFailures or 0)
                .. (row.writeFenceReason and (" reason=" .. Clip(row.writeFenceReason, 1200)) or "")
                .. (row.lastIntegrityError and (" integrityError=" .. Clip(row.lastIntegrityError, 4096)) or "")
                .. (row.lastVerifyFingerprint and (" verifyFp=" .. tostring(row.lastVerifyFingerprint)) or "")
                .. (row.lastIntegrityFingerprint and (" integrityFp=" .. tostring(row.lastIntegrityFingerprint)) or "")
        end
    end
    if storeCount == 0 then lines[#lines + 1] = "none" end

    lines[#lines + 1] = "[MODULE_UI]"
    local host = S.UIV3 and S.UIV3.PageHost or nil
    local route = tostring(meta.route or "")
    local pageCreated = type(host) == "table" and type(host.pages) == "table" and host.pages[route] ~= nil or false
    lines[#lines + 1] = "activeRoute=" .. tostring(type(host) == "table" and host.activeRoute or "")
        .. "/pageCreated=" .. tostring(pageCreated)

    -- 中文维护注释（2026-09-20，module-toggle-native-trampoline-1）：模块“启动无反应”过去只能看到
    -- initialized=false，无法区分按钮没收到 Native Click、页面动作未安装、统一 v3.features 写保护，
    -- 还是 Feature 自身初始化失败。这里仅观察现有薄状态，不 Load/Save/Initialize，不改变任何模块生命周期。
    local controlBar = type(host) == "table" and type(host.moduleControls) == "table" and host.moduleControls[route] or nil
    if type(controlBar) == "table" and controlBar.toggle ~= nil then
        local metrics = type(controlBar.actionMetrics) == "table" and controlBar.actionMetrics or {}
        local state = type(controlBar.lastControlState) == "table" and controlBar.lastControlState or {}
        lines[#lines + 1] = "controlToggle=enabled:" .. tostring(controlBar.toggle.enabled ~= false)
            .. "/actionReady:" .. tostring(controlBar.actionReady == true)
            .. "/clicks:" .. tostring(metrics.clicks or 0)
            .. "/completed:" .. tostring(metrics.completed or 0)
            .. "/rejected:" .. tostring(metrics.rejected or 0)
            .. "/implemented:" .. tostring(state.implemented == true)
            .. "/initialized:" .. tostring(state.initialized == true)
            .. "/runtimeEnabled:" .. tostring(state.enabled == true)
            .. (metrics.lastError and ("/lastError:" .. Clip(metrics.lastError, 800)) or "")
    else
        lines[#lines + 1] = "controlToggle=unavailable"
    end
    local runtimeManager = S.FeatureRuntime
    local preferenceStore = type(runtimeManager) == "table" and type(S.Persistence) == "table"
        and type(S.Persistence.GetStore) == "function" and S.Persistence:GetStore(runtimeManager.preferenceStoreId) or nil
    if type(preferenceStore) == "table" then
        lines[#lines + 1] = "controlPreferenceStore=" .. tostring(preferenceStore.id or runtimeManager.preferenceStoreId)
            .. "/load=" .. tostring(preferenceStore.loadStatus or "not_loaded")
            .. "/loaded=" .. tostring(preferenceStore.loaded == true)
            .. "/fenced=" .. tostring(preferenceStore.writeFenced == true)
            .. (preferenceStore.writeFenceReason and ("/reason=" .. Clip(preferenceStore.writeFenceReason, 800)) or "")
    else
        lines[#lines + 1] = "controlPreferenceStore=unavailable"
    end

    local counters = self:_ModuleCounters(moduleId == "system_diagnostics" and "system" or moduleId)
    local errors, warnings = 0, 0
    for _, row in ipairs(recent) do
        if row.level == "error" or row.level == "fatal" then errors = errors + (tonumber(row.count) or 1)
        else warnings = warnings + (tonumber(row.count) or 1) end
    end
    local summary = "已记录错误=" .. errors .. " / 警告=" .. warnings .. " / 存档保护或写入失败=" .. storeFaults
        .. " / 采集失败=" .. providerFailures
    table.insert(lines, 7, "SUMMARY=" .. summary)
    table.insert(lines, 8, "COVERAGE=本次加载已记录且仍保留的模块证据；无记录不代表无故障；不含未捕获的客户端内部错误。")
    table.insert(lines, 9, "PRIVACY=可能含角色名/配置字段/本地错误路径；仅本地生成，分享前请检查。")
    if meta.performanceLabel then lines[#lines + 1] = "performance=" .. meta.performanceLabel .. "(预估，非CPU/FPS实测) " .. tostring(meta.performanceReason or "") end
    lines[#lines + 1] = "[RETENTION] groups=" .. #recent .. "/" .. RING_MAX .. " evictedGroups=" .. counters.evicted
        .. " repeated=" .. counters.repeats .. " informationalNotInFaultRing=" .. counters.ignored
    lines[#lines + 1] = "[RESULT] providerFailures=" .. tostring(providerFailures) .. " errors=" .. tostring(errors)
        .. " warnings=" .. tostring(warnings) .. " stores=" .. tostring(storeCount)
        .. " collection=" .. (providerFailures > 0 and "INCOMPLETE" or "captured_available_sources")
    lines[#lines + 1] = "RS-MODULE-DIAG-END"
    return table.concat(lines, "\n")
end

function H:Capture(moduleId, capacity)
    local report, err = self:BuildReport(moduleId)
    if report == nil then return nil, err end
    local transport = S.ReportCopyTransport
    if type(transport) ~= "table" or type(transport.BuildTextPages) ~= "function" then return nil, "report paging unavailable" end
    self.captureSequence = (tonumber(self.captureSequence) or 0) + 1
    local id = "MD" .. tostring(S.Generation or 0) .. "." .. tostring(self.captureSequence) .. "." .. Normalize(moduleId)
    local session, pageErr = transport:BuildTextPages(report, tonumber(capacity) or 3500, id)
    if session == nil then return nil, pageErr end
    self.stats.captures = (tonumber(self.stats.captures) or 0) + 1
    return { version = 1, id = id, moduleId = Normalize(moduleId), report = report, session = session,
        parts = tonumber(session.parts) or 1, capturedAt = type(S.NowMs) == "function" and S.NowMs() or 0 }
end

-- 维护：仅用户点击“缩短分页”时重切同一份 report，不重新采集或读存档。新分页ID避免混入旧页。
function H:Repage(snapshot, capacity)
    if type(snapshot) ~= "table" or type(snapshot.report) ~= "string" then return nil, "snapshot required" end
    local transport = S.ReportCopyTransport
    if type(transport) ~= "table" or type(transport.BuildTextPages) ~= "function" then return nil, "paging unavailable" end
    local revision = (tonumber(snapshot.pageRevision) or 0) + 1
    local baseId = tostring(snapshot.baseId or snapshot.id or "MD"):sub(1, 40)
    local id = baseId .. "r" .. tostring(revision)
    local session, err = transport:BuildTextPages(snapshot.report, capacity, id)
    if session == nil then return nil, err end
    return { version = snapshot.version, id = id, baseId = baseId, pageRevision = revision, moduleId = snapshot.moduleId,
        report = snapshot.report, capturedAt = snapshot.capturedAt, session = session, parts = session.parts }
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
