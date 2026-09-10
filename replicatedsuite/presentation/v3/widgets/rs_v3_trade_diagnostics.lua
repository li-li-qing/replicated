------------------------------------------------------------------------
-- Replicated Suite V3 - Trade Diagnostics Floating Panel
--
-- Dedicated read-only debugging surface for the 跑商 quote pipeline
-- (route -> material identity -> PriceQuoteQueueV3 -> X2Auction). It consumes
-- public Feature/Service describe APIs only: no consumer lease, no Commands,
-- no native auction/craft access, and it never writes business state.
--
-- The copyable report is the debugging contract with the maintainer: it carries
-- per-layer facts (route, identity, live attempts, quote queue with the RAW
-- native return shape) so RU runtime answers come back in one paste.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
local Floating = RSUI and RSUI.FloatingSurface or nil
local AuxStore = S.UIV3 and S.UIV3.AuxWindowStoreV3 or nil
if type(RSUI) ~= "table" or type(Floating) ~= "table" or type(AuxStore) ~= "table" then return end

S.UIV3 = S.UIV3 or {}
S.UIV3.TradeDiagnosticsV3 = S.UIV3.TradeDiagnosticsV3 or {
    version = 1,
    TradeDiagnosticsContractVersion = 1,
    id = "v3_trade_diagnostics",
    created = false,
    visible = false,
    subscribed = false,
    revision = 0,
}
local M = S.UIV3.TradeDiagnosticsV3

local REPORT_MAX_CHARS = 4800
local LINE_MAX_CHARS = 220

local function Feature() return S.Features and S.Features.Trade or nil end
local function Queue() return S.Services and S.Services.PriceQuoteQueueV3 or nil end
local function Identity() return S.Services and S.Services.TradeMaterialIdentityV3 or nil end

local function NowMs()
    if type(S.NowMs) == "function" then return tonumber(S.NowMs()) or 0 end
    return 0
end

local function AgoText(at)
    local delta = math.max(0, math.floor(((NowMs() - (tonumber(at) or 0)) / 1000) + 0.5))
    if delta < 60 then return delta .. "s前" end
    return math.floor(delta / 60 + 0.5) .. "m前"
end

local function Bounded(value, fallback, maxChars)
    local text = tostring(value or fallback or "")
    if #text > (maxChars or LINE_MAX_CHARS) then return string.sub(text, 1, maxChars or LINE_MAX_CHARS) .. "…" end
    return text
end

local function QuoteStatusTone(status)
    if status == "ready" then return "green" end
    if status == "queued" then return "yellow" end
    if status == "unavailable" or status == "failed" then return "red" end
    return "muted"
end

local function DescribeQuoteText(record)
    if record.status == "ready" then
        return tostring(record.price or "?") .. (record.priceSource ~= nil and (" / " .. tostring(record.priceSource)) or "")
    end
    return Bounded(record.error or record.rawShape or "未知", "-", 120)
end

-- Read-only composition over public describe APIs. Safe while the feature is
-- disabled: every source is optional.
local function CollectState()
    local feature = Feature()
    local queue = Queue()
    local identity = Identity()
    local state = {
        featureEnabled = feature ~= nil and S.FeatureRuntime ~= nil and S.FeatureRuntime:IsEnabled(feature.Id) == true,
        projection = feature and type(feature.GetProjection) == "function" and feature:GetProjection() or nil,
        request = feature and type(feature.DescribeRequestState) == "function" and feature:DescribeRequestState() or nil,
        identityState = feature and type(feature.DescribeIdentityState) == "function" and feature:DescribeIdentityState() or nil,
        initTrace = feature and type(feature.DescribeInitTrace) == "function" and feature:DescribeInitTrace() or nil,
        queueHealth = queue and type(queue.GetHealth) == "function" and queue:GetHealth() or nil,
        identity = identity and type(identity.Describe) == "function" and identity:Describe() or nil,
    }
    return state
end

local function SummaryLines(state)
    local lines = {}
    local projection = state.projection or {}
    local request = state.request
    local featureLine = "功能=" .. (state.featureEnabled and "开" or "关")
        .. " · 状态=" .. tostring(projection.status or request and request.status or "--")
        .. " · 线路=" .. tostring(projection.fromZone or "-") .. "->" .. tostring(projection.toZone or "-")
        .. " · 货物=" .. tostring(#(projection.rows or {}))
        .. " · 地区=" .. tostring(#(projection.zones or {})) .. "/" .. tostring(#(projection.sellableZones or {}))
    lines[#lines + 1] = featureLine
    local identityState = state.identityState or {}
    local identityLine = "身份: 配方 " .. tostring((tonumber(identityState.rows) or 0) - (tonumber(identityState.unresolved) or 0))
        .. "/" .. tostring(identityState.rows or 0)
        .. " · 解析中=" .. tostring(identityState.livePending or 0)
        .. (identityState.firstUnresolved ~= nil and (" · 首个未解析=" .. Bounded(identityState.firstUnresolved, "?", 40)) or "")
    local identity = state.identity
    if type(identity) == "table" then
        identityLine = identityLine .. "\nlive: 读=" .. tostring(identity.liveReads or 0)
            .. " 缓存=" .. tostring(identity.cachedReady or 0) .. "/" .. tostring(identity.cachedFailed or 0)
            .. " · 队列=" .. tostring(identity.queueLength or 0)
            .. (identity.lastError ~= nil and (" · lastErr=" .. Bounded(identity.lastError, "", 90)) or "")
    end
    lines[#lines + 1] = identityLine
    local health = state.queueHealth or {}
    local stats = type(health.stats) == "table" and health.stats or {}
    local queueLine = "报价队列: 运行=" .. tostring(health.running == true)
        .. " · 在飞=" .. tostring(health.pending == true)
        .. " · 排队=" .. tostring(health.queueLength or 0) .. "/" .. tostring(health.maxQueue or 0)
        .. " · 尝试=" .. tostring(stats.attempts or 0)
        .. " · 成功=" .. tostring(stats.ready or 0)
        .. " · 失败=" .. tostring(stats.failed or 0)
        .. " · 已报价品类=" .. tostring(health.pricedItemTypes or 0)
    lines[#lines + 1] = queueLine
    if health.lastRawReturn ~= nil then
        lines[#lines + 1] = "最近原生返回: " .. Bounded(health.lastRawReturn, "-", 180)
    end
    local unresolved = tonumber(projection.unresolvedIdentityCount) or 0
    local pendingQuotes = tonumber(projection.pendingQuoteCount) or 0
    local inFlight = tonumber(projection.quoteInFlightCount) or 0
    lines[#lines + 1] = "投影: 待询价=" .. tostring(pendingQuotes)
        .. " · 询价中=" .. tostring(inFlight)
        .. " · 配方待解析=" .. tostring(unresolved)
        .. " · 报价失败行见下表"
    local init = state.initTrace
    if type(init) == "table" then
        local initLine = "初始化: enabled=" .. tostring(init.enabled == true)
            .. " runtime=" .. tostring(init.runtimeEnabled == true)
            .. " store=" .. tostring(init.storeLoaded == true)
            .. " consumers=" .. tostring(init.consumerCount or 0)
        local milestones = type(init.milestones) == "table" and init.milestones or {}
        local tail = {}
        for index = math.max(1, #milestones - 2), #milestones do
            tail[#tail + 1] = tostring(milestones[index].event) .. "(" .. Bounded(milestones[index].detail, "", 46) .. ")"
        end
        if #tail > 0 then initLine = initLine .. "\n最近: " .. table.concat(tail, " · ") end
        lines[#lines + 1] = initLine
    end
    return table.concat(lines, "\n")
end

local function CompletionItems(state)
    local health = state.queueHealth or {}
    local items = {}
    for index, record in ipairs(type(health.recent) == "table" and health.recent or {}) do
        items[#items + 1] = {
            key = tostring(index) .. ":" .. tostring(record.itemType) .. ":" .. tostring(record.at),
            timeText = AgoText(record.at),
            itemText = tostring(record.itemType or "?") .. (record.itemGrade ~= nil and (" (" .. tostring(record.itemGrade) .. "级)") or ""),
            statusText = tostring(record.status or "?"),
            priceText = record.status == "ready" and tostring(record.price or "?") or "--",
            detailText = record.status == "ready"
                and Bounded(record.priceSource or "-", "-", 120)
                or Bounded(record.error or record.rawShape or "-", "-", 150),
        }
    end
    return items
end

local function BuildCopyReport(state)
    local parts = {}
    local function Add(line)
        parts[#parts + 1] = Bounded(line, "", LINE_MAX_CHARS)
    end
    Add("[RS跑商诊断] " .. tostring(S.BuildTag or "?"))
    for line in string.gmatch(SummaryLines(state), "([^\n]+)") do Add(line) end
    local health = state.queueHealth or {}
    local recent = type(health.recent) == "table" and health.recent or {}
    if #recent > 0 then
        Add("最近询价:")
        for index, record in ipairs(recent) do
            if index > 12 then break end
            Add("  #" .. tostring(index) .. " " .. AgoText(record.at) .. " itemType=" .. tostring(record.itemType)
                .. " " .. tostring(record.status)
                .. (record.status == "ready" and (" 价格=" .. tostring(record.price) .. "/" .. tostring(record.priceSource or "-"))
                    or (" 形态=" .. Bounded(record.rawShape or "-", "-", 120) .. " 错误=" .. Bounded(record.error or "-", "-", 120))))
        end
    end
    -- Protocol discrimination evidence: without this the only signal is "all
    -- nil", which cannot separate a wrong call protocol from an empty market.
    local probe = type(health.protocolProbe) == "table" and health.protocolProbe or nil
    if type(probe) == "table" then
        Add("协议探针: done=" .. tostring(probe.done == true) .. " 次=" .. tostring(probe.attempts or 0))
        for index, record in ipairs(type(probe.results) == "table" and probe.results or {}) do
            if index > 6 then break end
            Add("  #" .. tostring(index) .. " itemType=" .. tostring(record.itemType)
                .. " grade=" .. tostring(record.grade)
                .. " ok=" .. tostring(record.ok == true)
                .. (record.error ~= nil and (" err=" .. Bounded(record.error, "-", 60)) or "")
                .. " 形态=" .. Bounded(record.shape or "-", "-", 120)
                .. " 价=" .. tostring(record.money or "-"))
        end
    end
    local identity = state.identity
    if type(identity) == "table" and type(identity.recentFailed) == "table" and #identity.recentFailed > 0 then
        Add("live身份失败:")
        for index, record in ipairs(identity.recentFailed) do
            if index > 8 then break end
            Add("  #" .. tostring(index) .. " itemType=" .. tostring(record.itemType) .. " " .. Bounded(record.error, "-", 140))
        end
    end
    local init = state.initTrace
    if type(init) == "table" then
        Add("初始化: enabled=" .. tostring(init.enabled == true) .. " runtime=" .. tostring(init.runtimeEnabled == true)
            .. " store=" .. tostring(init.storeLoaded == true) .. " consumers=" .. tostring(init.consumerCount or 0))
        local milestones = type(init.milestones) == "table" and init.milestones or {}
        for index, record in ipairs(milestones) do
            Add("  #" .. tostring(index) .. " " .. AgoText(record.at) .. " " .. tostring(record.event)
                .. " " .. Bounded(record.detail, "-", 150))
        end
    end
    local projection = state.projection or {}
    local rows = type(projection.rows) == "table" and projection.rows or {}
    if #rows > 0 then
        Add("行明细:")
        for index, row in ipairs(rows) do
            if index > 12 then break end
            local quoted, failed, pending, inFlightM = 0, 0, 0, 0
            local firstError
            for _, material in ipairs(type(row.materialRows) == "table" and row.materialRows or {}) do
                local status = tostring(material.costStatus or "")
                if status == "quoted" then quoted = quoted + 1 end
                if status == "explicit_quote_required" then pending = pending + 1 end
                if status == "quote_pending" then inFlightM = inFlightM + 1 end
                if status == "quote_failed" then
                    failed = failed + 1
                    if firstError == nil then firstError = material.quoteError end
                end
            end
            -- This panel is the developer surface: internal identifiers belong
            -- here and nowhere else. Pages/HUD rows carry localized Chinese names
            -- only; the English data key and craftType/source trace arrive on the
            -- diagnostics-only fields the projection now separates for us.
            Add("  " .. tostring(index) .. ". " .. Bounded(row.sourceName or row.name or "?", "?", 48)
                .. (row.materialRows ~= nil and #row.materialRows > 0
                    and (" 材料键[" .. Bounded((function()
                        local keys = {}
                        for _, material in ipairs(row.materialRows) do
                            if #keys < 6 then keys[#keys + 1] = tostring(material.internalKey or material.materialKey or "?") end
                        end
                        return table.concat(keys, ", ")
                    end)(), "?", 150) .. "]")
                    or "")
                .. " 身份=" .. Bounded(row.recipeLabel or tostring(row.identityStatus or "?"), "?", 60)
                .. "(" .. tostring(row.identitySource or "-")
                .. (row.identityDetail ~= nil and (";" .. Bounded(row.identityDetail, "-", 60)) or "") .. ")"
                .. " 材料=" .. tostring(row.materialCount or 0)
                .. " 已报=" .. tostring(quoted) .. " 待=" .. tostring(pending)
                .. " 解析中=" .. tostring(inFlightM) .. " 失败=" .. tostring(failed)
                .. (firstError ~= nil and (" 首错=" .. Bounded(firstError, "-", 110)) or ""))
        end
    end
    local report = table.concat(parts, "\n")
    if #report > REPORT_MAX_CHARS then report = string.sub(report, 1, REPORT_MAX_CHARS) .. "\n…(已截断)" end
    return report
end

function M:Unsubscribe()
    if self.subscribed and S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then
        S.Events:UnsubscribeInternalOwner(self)
    end
    self.subscribed = false
    return true
end

function M:Subscribe()
    if self.subscribed then return true end
    if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
        local feature = Feature()
        if type(feature) == "table" and type(feature.UpdateTopic) == "string" then
            S.Events:SubscribeInternal(feature.UpdateTopic, self, function()
                if M.visible then M:Refresh("feature_update") end
            end)
        end
        local queue = Queue()
        if type(queue) == "table" and type(queue.Topic) == "string" then
            S.Events:SubscribeInternal(queue.Topic, self, function()
                if M.visible then M:Refresh("quote_completed") end
            end)
        end
    end
    self.subscribed = true
    return true
end

function M:Deactivate(reason)
    self.visible = false
    return self:Unsubscribe()
end

function M:EnsureCreated()
    if self.created == true and self.surface ~= nil then return true end
    local loaded, loadErr = AuxStore:EnsureLoaded()
    if loaded ~= true then return false, loadErr or "辅助窗口布局读取失败" end
    local surface, err = Floating:Create({
        id = self.id,
        owner = "v3:trade_diagnostics:floating",
        title = "跑商诊断",
        status = "--",
        footer = true,
        movable = true,
        resizable = true,
        minimizeMode = "compact",
        boundaryMode = "free",
        defaultPlacement = "center",
        statePolicy = AuxStore:GetPolicy("trade_diagnostics"),
        getState = function() return AuxStore:GetWindowState("trade_diagnostics") end,
        setState = function(value, reason) return AuxStore:SetWindowState("trade_diagnostics", value, reason) end,
        -- 中文维护注释：跑商诊断只把窗口几何/锁定/透明度写入 Presentation Store；
        -- 业务数据继续由原 Feature/Service Authority 管理，避免第二业务 Authority。
        persist = function(reason, delayMs) return AuxStore:PersistWindow("trade_diagnostics", reason, delayMs) end,
        onClosed = function()
            M:Deactivate("surface_closed")
            return true
        end,
    })
    if surface == nil then return false, err or "跑商诊断面板创建失败" end
    self.surface, self.shell = surface, surface.shell

    local stack = RSUI:VerticalBox({ id = self.id .. "_stack", parent = surface:GetContentRoot(), gap = 6,
        slot = { hAlign = "fill", vAlign = "fill" } })
    self.summary = RSUI:Text({ id = self.id .. "_summary", parent = stack, text = "--", fontSize = 10, tone = "default",
        overflow = "wrap", maxLines = 10, slot = { size = "fixed", height = 128, hAlign = "fill" } })

    local actions = RSUI:HorizontalBox({ id = self.id .. "_actions", parent = stack, gap = 6,
        slot = { size = "fixed", height = 30, hAlign = "fill" } })
    self.copyButton = RSUI:Button({ id = self.id .. "_copy", parent = actions, text = "复制诊断报告", compact = true,
        slot = { size = "fixed", width = 112 } })
    self.refreshButton = RSUI:Button({ id = self.id .. "_refresh", parent = actions, text = "刷新", compact = true,
        slot = { size = "fixed", width = 64 } })

    self.table = RSUI:TableView({
        id = self.id .. "_table", parent = stack, items = {}, rowHeight = 26, headerHeight = 25, desiredRows = 9,
        scrollbar = true, selectable = false, columnResize = true, headerInteractive = false,
        getKey = function(item, index) return item and item.key or tostring(index or 0) end,
        columns = {
            { id = "time", title = "时间", field = "timeText", size = "fixed", width = 62, minWidth = 52 },
            { id = "item", title = "物品(itemType)", field = "itemText", size = "fixed", width = 110, minWidth = 90 },
            { id = "status", title = "状态", field = "statusText", size = "fixed", width = 86, minWidth = 70,
                getTone = function(item) return QuoteStatusTone(item and item.statusText) end },
            { id = "price", title = "价格", field = "priceText", size = "fixed", width = 84, minWidth = 64 },
            { id = "detail", title = "原始返回形态 / 错误", field = "detailText", size = "fill", minWidth = 180, fill = 1.4 },
        },
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    self.hint = RSUI:Text({ id = self.id .. "_hint", parent = stack,
        text = "只读诊断：询价失败的“原始返回形态”是核对 RU 拍卖行最低价接口真实字段的第一手证据；点“复制诊断报告”后把聊天框内容整段发给维护者。",
        fontSize = 9, tone = "muted", overflow = "wrap", maxLines = 2, slot = { size = "fixed", height = 32, hAlign = "fill" } })

    if self.summary == nil or self.copyButton == nil or self.refreshButton == nil or self.table == nil or self.hint == nil then
        surface:Destroy()
        self.surface, self.shell = nil, nil
        return false, "跑商诊断面板内容创建失败"
    end

    self.copyButton.onClick = function()
        local state = CollectState()
        local report = BuildCopyReport(state)
        if type(S.SafeChat) ~= "function" then return false, "聊天输出不可用" end
        S.SafeChat(report, "info", "trade_diagnostics")
        self.surface:SetStatus("诊断报告已输出到聊天框，整段复制发给维护者", "accent")
        return true
    end
    self.refreshButton.onClick = function() return M:Refresh("manual") end

    surface:Show(false)
    self.created = true
    return true
end

function M:Refresh(reason)
    if self.surface == nil then return false, "跑商诊断面板未创建" end
    self.revision = (tonumber(self.revision) or 0) + 1
    local state = CollectState()
    self.summary:SetText(SummaryLines(state))
    local items = CompletionItems(state)
    self.table:SetItems(items, "trade_diag:" .. tostring(self.revision))
    if #items == 0 then
        self.table:SetViewState("empty", { title = "暂无询价记录", detail = "在跑商页选择路线并点击“材料询价”后，这里会逐条显示每次询价的真实结果与原始返回形态。" })
    else
        self.table:SetViewState("ready")
    end
    local health = state.queueHealth or {}
    local stats = type(health.stats) == "table" and health.stats or {}
    local failed = tonumber(stats.failed) or 0
    self.surface:SetStatus("尝试 " .. tostring(stats.attempts or 0)
        .. " · 成功 " .. tostring(stats.ready or 0)
        .. " · 失败 " .. tostring(failed)
        .. (health.lastRawReturn ~= nil and (" · 形态 " .. Bounded(health.lastRawReturn, "-", 60)) or ""),
        failed > 0 and "yellow" or "accent")
    return true
end

function M:Open()
    local ok, err = self:EnsureCreated()
    if ok ~= true then return false, err end
    self:Subscribe()
    self.visible = true
    self:Refresh("open")
    local restored, restoreErr = self.surface:SetMinimized(false, false)
    if restored ~= true then self:Deactivate("restore_failed"); return false, restoreErr end
    local shown, showErr = self.surface:Show(true)
    if shown ~= true then self:Deactivate("show_failed"); return false, showErr end
    return true
end

function M:Close(reason)
    if self.surface == nil then return self:Deactivate(reason or "trade_diag_close") end
    local closed, closeErr = self.surface:Close(reason or "trade_diag_close")
    if closed ~= true then return false, closeErr end
    self:Deactivate(reason or "trade_diag_close")
    return true
end
