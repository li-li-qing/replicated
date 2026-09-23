------------------------------------------------------------------------
-- Replicated Suite V3 - Quest / Activity Floating Detail
--
-- Presentation surface used when an Activity/Task row is activated. Geometry
-- is durable through the Presentation-only AuxWindow Store; gameplay facts stay
-- owned by QuestProgressV3.
--
-- Lifecycle contract (2026-09-21):
--   * The floating detail owns its own QuestProgressV3 Consumer while a mapped
--     task detail is open, so closing the main page/widget cannot freeze it.
--   * The detail listens only to QuestProgress's successful refresh epoch for
--     live Journal Objective text. It does not add Tick/OnUpdate or Native reads
--     outside QuestProgressV3.
--   * Closing the window releases the Consumer and internal event subscription.
--   * Rows without a verified questKey still open a consistent activity detail
--     surface, but do not wake QuestProgress/InstanceCatalog.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
local Floating = RSUI and RSUI.FloatingSurface or nil
local AuxStore = S.UIV3 and S.UIV3.AuxWindowStoreV3 or nil
if type(RSUI) ~= "table" or type(Floating) ~= "table" or type(AuxStore) ~= "table" then return end

S.UIV3 = S.UIV3 or {}
-- 中文维护注释（2026-09-21，activity-detail-generation-1）：文件重载会保留 ReplicatedSuite
-- Lua 全局，但 Bootstrap 会退役上一 Generation 的 Native Window/RSUI 子树。旧实现无 Generation
-- 边界，created=true 会让 EnsureCreated 继续复用已经退役的 surface，活动点击因此只得到一个被
-- TableView 吞掉的 false，用户看到的就是“点击没反应”。详情业务状态不跨加载代继承；窗口几何仍
-- 由 AuxWindowStore 永久保存。Authority：Generation 只决定 Presentation 实例寿命，QuestProgress
-- 继续独占任务事实。兼容：同 Generation 的重复执行仍复用实例，避免重复 Native ID。
local generation = tonumber(S.Generation) or 0
local previous = S.UIV3.QuestDetailFloatingV3
S.UIV3.QuestDetailFloatingV3 = type(previous) == "table"
    and tonumber(previous.generation) == generation and previous or {
        generation = generation,
        id = "v3_quest_detail_floating",
        created = false,
        visible = false,
        revision = 0,
    }
local M = S.UIV3.QuestDetailFloatingV3
M.generation = generation
M.ConsumerLifecycleContractVersion = 2
M.ProgressSelectionInteractionContractVersion = 2 -- 2026-09-22: selection-event transport + visible text state; prevents .281 activation regression.
M.consumerToken = tostring(M.consumerToken or "presentation:v3.quest_detail")
M.consumerHeld = M.consumerHeld == true
M.subscribed = M.subscribed == true
M.current = nil
M.layoutDurable = M.layoutDurable == true
M.layoutLoadError = nil
-- 中文维护注释（2026-09-21，activity-progress-selection-1）：活动“追踪”现改为个人进度选择。
-- Presentation 不再维护“全部/仅追踪”筛选或收藏状态；勾选的 main objective 直接决定 Activities
-- Feature 投影的 x/y。未配置时默认全部主任务计入，related/journal 永远不是独立可选项。
M.selectedRowKey = nil
M.selectionChangeInFlight = false
M.progressToggleAttempts = tonumber(M.progressToggleAttempts) or 0
M.progressToggleSuccesses = tonumber(M.progressToggleSuccesses) or 0
M.progressToggleFailures = tonumber(M.progressToggleFailures) or 0
M.lastProgressToggleKey = nil
M.lastProgressToggleError = nil
M.trackingAvailable = false -- 兼容诊断字段：现在表示个人进度选择 Store 是否可写。
M.trackingLoadError = nil
M.lastDetail = nil
M.lastRawDetail = nil
M.lastSource = nil
M.projectedByKey = {}

local function NotifyUnavailable(detail)
    local host = S.UIV3 and S.UIV3.ToastHost or nil
    if type(host) == "table" and type(host.Notify) == "function" then
        host:Notify({ id = "v3_quest_detail_floating_unavailable", title = "任务详情", detail = tostring(detail or "任务详情暂不可用。"),
            tone = "yellow", durationMs = 2800 })
        return true
    end
    -- 失败聊天提示统一由 FailOpen 输出，避免 ToastHost 缺席时重复打印两次。
    return false
end

-- 中文维护注释（2026-09-21，Presentation 边界）：Activity Authority 的 row 会在下一次投影时整体替换；
-- 详情窗不能长期持有该业务表引用，也不能反向修改它。这里只复制标题/状态等 primitive 显示事实，
-- 任务完成度仍每次从 QuestProgressV3 读取。兼容无 questKey 的活动也依赖这份 detached snapshot。
local function SnapshotSourceRow(row)
    if type(row) ~= "table" then return nil end
    return {
        key = tostring(row.key or ""),
        name = tostring(row.rawName or row.name or row.shortName or ""),
        shortName = tostring(row.shortName or row.name or row.rawName or ""),
        status = tostring(row.status or ""),
        scheduleText = tostring(row.scheduleText or ""),
        progressText = tostring(row.progressText or ""),
        tone = tostring(row.tone or "muted"),
        progressTone = tostring(row.progressTone or "muted"),
        zoneState = row.zoneState == true,
    }
end

local function SourceTitle(source, fallback)
    source = type(source) == "table" and source or nil
    local title = source and tostring(source.name or "") or ""
    if title == "" then title = tostring(fallback or "任务详情") end
    return title
end

local function JoinSummary(source, detailText)
    local parts = {}
    source = type(source) == "table" and source or nil
    if source ~= nil and tostring(source.status or "") ~= "" then
        parts[#parts + 1] = tostring(source.status)
    end
    if tostring(detailText or "") ~= "" then parts[#parts + 1] = tostring(detailText) end
    if #parts == 0 then return "--" end
    return table.concat(parts, " · ")
end

local function BuildUnmappedDetail(scope, key, source)
    local rows = {}
    source = type(source) == "table" and source or nil
    if source ~= nil and tostring(source.status or "") ~= "" then
        rows[#rows + 1] = {
            key = "activity_status", category = "状态", name = tostring(source.status), status = "",
            tone = tostring(source.tone or "muted"), related = false, counted = false,
        }
    end
    if source ~= nil and tostring(source.scheduleText or "") ~= "" then
        rows[#rows + 1] = {
            key = "activity_schedule", category = "时间", name = tostring(source.scheduleText), status = "",
            tone = "muted", related = false, counted = false,
        }
    end
    rows[#rows + 1] = {
        key = "activity_no_verified_tasks", category = "任务", name = "当前没有已核验的关联任务", status = "未映射",
        tone = "muted", related = false, counted = false,
    }
    local summary = "当前没有已核验的关联任务"
    if source ~= nil and tostring(source.progressText or "") ~= "" and tostring(source.progressText) ~= "--" then
        summary = "当前进度 " .. tostring(source.progressText) .. " · " .. summary
    end
    return {
        scope = tostring(scope or "event"), key = tostring(key or ""), title = SourceTitle(source, "活动详情"),
        kind = "unmapped", completed = 0, total = 0, activeCount = 0, readyCount = 0, relatedCount = 0,
        summaryText = summary, children = rows,
    }
end

local function ActivityFeature()
    return S.Features and S.Features.Activities or nil
end

local function CopyRow(row)
    if type(row) ~= "table" then return {} end
    local out = {}
    for key, value in pairs(row) do out[key] = value end
    return out
end

-- 中文维护注释（2026-09-21，activity-progress-selection-1）：详情行的 selected/selectable 已由
-- Activities Feature 基于 Store + QuestProgress 事实统一投影。Presentation 只把它画成“追踪”勾选列；
-- 不自行计算 x/y，也不允许 related/journal 行混入分母。整行点击即切换该 main objective，避免上一版
-- “先选行再点加入追踪”的双操作和“仅追踪”筛选把未勾任务藏起来。
function M:ProjectDetailRows(detail)
    local rows, byKey = {}, {}
    local eligibleCount = math.max(0, math.floor(tonumber(detail and detail.progressSelectionEligible) or 0))
    local selectedCount = math.max(0, math.floor(tonumber(detail and detail.progressSelectionSelected) or 0))
    for _, sourceRow in ipairs(type(detail and detail.children) == "table" and detail.children or {}) do
        local row = CopyRow(sourceRow)
        row.trackable = row.progressSelectable == true
        row.tracked = row.progressSelected == true
        if row.trackable then
            -- 中文维护注释（2026-09-22，activity-detail-ui-2）：RU 字体并不保证 ✓/□ glyph 可见；
            -- 业务状态已经正确切换时，空白 glyph 会让用户误判为“没有勾选”。追踪状态因此使用
            -- 明确中文文本作为主语义，颜色只作辅助。Authority 仍是 Activity Store，不由 Presentation 猜测。
            row.trackingText = row.tracked and "已选" or "未选"
        elseif row.journal == true then
            row.trackingText = ""
        else
            row.trackingText = "—"
        end
        rows[#rows + 1] = row
        byKey[tostring(row.key or #rows)] = row
    end
    self.projectedByKey = byKey
    return rows, selectedCount, eligibleCount
end

function M:SelectedProjectedRow()
    local key = self.table ~= nil and type(self.table.GetSelectedKey) == "function" and self.table:GetSelectedKey() or self.selectedRowKey
    if key == nil then return nil end
    return self.projectedByKey and self.projectedByKey[tostring(key)] or nil
end

function M:UpdateTrackingControls(selectedCount, eligibleCount, detail)
    selectedCount = tonumber(selectedCount) or 0
    eligibleCount = tonumber(eligibleCount) or 0
    -- 中文维护注释（2026-09-22，activity-detail-ui-2）：个人分母属于 Activities(event) 偏好；
    -- Daily/Weekly 可能复用同一 QuestGroup，但绝不能露出可写的活动追踪控件。
    local enabled = type(detail) == "table" and tostring(detail.scope or "") == "event" and detail.progressSelectionEnabled == true
    if self.trackingChip ~= nil then
        self.trackingChip:SetVisible(enabled)
        if enabled then
            local allSelected = eligibleCount > 0 and selectedCount >= eligibleCount
            local status = allSelected and "success" or (selectedCount > 0 and "pending" or "warning")
            local tone = allSelected and "green" or (selectedCount > 0 and "yellow" or "red")
            self.trackingChip:SetStatus(status, "追踪 " .. tostring(selectedCount) .. "/" .. tostring(eligibleCount), tone)
        end
    end
    return true
end

function M:ToggleProgressSelection(row)
    local session = self.current
    if type(session) ~= "table" or session.scope ~= "event" or session.mapped ~= true then return true end
    if type(row) ~= "table" or row.progressSelectable ~= true or tostring(row.trackingKey or "") == "" then return true end

    -- 中文维护注释（2026-09-22，activity-detail-toggle-observability-2）：这里只记录有界 primitive
    -- 交互证据，帮助区分“Native 行点击未到达 / Store 写入失败 / Presentation 重绘失败”。不持久化、
    -- 不拥有选择业务状态、不进入 Tick。
    self.progressToggleAttempts = (tonumber(self.progressToggleAttempts) or 0) + 1
    self.lastProgressToggleKey = tostring(row.trackingKey or row.key or "")
    self.lastProgressToggleError = nil

    if self.trackingAvailable ~= true then
        local detail = self.trackingLoadError or "活动个人进度选择不可用"
        self.progressToggleFailures = (tonumber(self.progressToggleFailures) or 0) + 1
        self.lastProgressToggleError = tostring(detail)
        NotifyUnavailable("个人进度选择暂不可保存：" .. tostring(self.trackingLoadError or "存档未就绪"))
        return false, detail
    end
    local feature = ActivityFeature()
    local commands = type(feature) == "table" and feature.Commands or nil
    if type(commands) ~= "table" or type(commands.SetProgressTaskSelected) ~= "function" then
        self.progressToggleFailures = (tonumber(self.progressToggleFailures) or 0) + 1
        self.lastProgressToggleError = "活动个人进度命令不可用"
        return false, self.lastProgressToggleError
    end
    local ok, err = commands:SetProgressTaskSelected(session.key, row.trackingKey, row.progressSelected ~= true, "quest_detail")
    if ok ~= true then
        self.progressToggleFailures = (tonumber(self.progressToggleFailures) or 0) + 1
        self.lastProgressToggleError = tostring(err or "活动个人进度选择失败")
        NotifyUnavailable(err or "活动个人进度选择失败")
        return false, err or "活动个人进度选择失败"
    end

    -- 不重新读取 Native Quest/Journal：上一轮 raw detail 已经包含任务事实，Feature 只按新 Store
    -- 重投影 selected 集合。这样每次勾选不会增加 Native API 调用。
    local rendered, renderErr
    if type(self.lastRawDetail) == "table" and type(feature.ProjectActivityDetail) == "function" then
        local projected = feature:ProjectActivityDetail(self.lastRawDetail)
        rendered, renderErr = self:RenderDetail(projected, self.lastSource, "progress_selection_changed")
    else
        rendered, renderErr = self:RefreshCurrent("progress_selection_changed")
    end
    if rendered ~= true then
        -- Store 命令已经成功时不能伪装成“未保存”。保留证据并提示；下一次任务刷新会从 Authority 收敛。
        self.progressToggleFailures = (tonumber(self.progressToggleFailures) or 0) + 1
        self.lastProgressToggleError = "saved_but_render_failed:" .. tostring(renderErr or "unknown")
        NotifyUnavailable("追踪设置已保存，但界面刷新失败；请重新打开详情。")
        return true, self.lastProgressToggleError
    end
    self.progressToggleSuccesses = (tonumber(self.progressToggleSuccesses) or 0) + 1
    self.lastProgressToggleError = nil
    return true
end

-- 中文维护注释（2026-09-22，activity-detail-selection-transport-2）：RU 实机稳定链路是
-- Native Row -> SelectionModel -> onSelectionChanged。`.281` 在推广多活动选择时把已修好的 Selection
-- transport 覆盖回 onItemActivated，导致“点一下只有蓝色行高亮、追踪不变”。这里恢复 SelectionChanged
-- 为唯一 checkbox-like transport，并立即清空临时 Selection；长期状态只来自 Activity Store。
function M:HandleProgressSelectionChanged(index, view, reason, key, selected)
    if self.selectionChangeInFlight == true then return true end
    if selected ~= true or key == nil then
        if selected ~= true then self.selectedRowKey = nil end
        return true
    end

    local row = self.projectedByKey and self.projectedByKey[tostring(key)] or nil
    if row == nil and view ~= nil and type(view.GetItem) == "function" then row = view:GetItem(index) end
    self.selectionChangeInFlight = true
    self.selectedRowKey = tostring(key)

    local callOk, result, detail = xpcall(function()
        return self:ToggleProgressSelection(row)
    end, S.SafeTraceback or tostring)

    -- Selection 只是点击 transport，不是追踪状态。无论主任务/关联任务、成功/失败都必须清掉，
    -- 保证同一行连续点击每次都会产生 selected=true，也避免截图中的蓝底/黄色边线被误认为“已追踪”。
    self.selectedRowKey = nil
    if view ~= nil and type(view.SetSelectedIndex) == "function" then
        view:SetSelectedIndex(nil)
    elseif view ~= nil and type(view.ClearSelection) == "function" then
        view:ClearSelection()
    end
    self.selectionChangeInFlight = false

    if callOk ~= true then
        self.progressToggleFailures = (tonumber(self.progressToggleFailures) or 0) + 1
        self.lastProgressToggleError = tostring(result or "progress_selection_callback_error")
        if type(S.SafeChat) == "function" then
            S.SafeChat("[Replicated Suite] 活动任务追踪点击失败：" .. self.lastProgressToggleError)
        end
        return false, self.lastProgressToggleError
    end
    return result ~= false, detail
end

function M:EnsureCreated()
    -- 同 Generation 也可能经历显式 Destroy/Bootstrap teardown；不能只看 created flag。
    if self.created == true and self.surface ~= nil and self.shell ~= nil and self.shell.destroyed ~= true then return true end
    self.created, self.visible = false, false
    self.surface, self.shell = nil, nil
    self.summaryRow, self.progressChip, self.relatedChip, self.trackingChip = nil, nil, nil, nil
    self.summary, self.table, self.hint = nil, nil, nil

    local policy = AuxStore:GetPolicy("quest_detail")
    if type(policy) ~= "table" then return false, "任务详情窗口策略不可用" end
    local loaded, loadErr = AuxStore:EnsureLoaded()
    local getState, setState, persistState
    if loaded == true then
        self.layoutDurable, self.layoutLoadError = true, nil
        getState = function() return AuxStore:GetWindowState("quest_detail") end
        setState = function(value, reason) return AuxStore:SetWindowState("quest_detail", value, reason) end
        persistState = function(reason, delayMs) return AuxStore:PersistWindow("quest_detail", reason, delayMs) end
    else
        -- 中文维护注释（2026-09-21，aux-layout-degrade-1）：quest_detail 是纯 Presentation 几何。
        -- 即使其 Store 因完整性保护/旧坏数据暂时不可读，也不能让“查看任务详情”这个业务入口一起失效。
        -- 降级只在内存保存几何，绝不写回被保护 Store；下一次完整重载仍优先尝试 Durable Store。
        -- 任务事实/Consumer 不受影响，也不会绕过任何业务 Persistence fence。
        self.layoutDurable = false
        self.layoutLoadError = tostring(loadErr or "辅助窗口布局读取失败")
        self.ephemeralState = Floating:NormalizeState(nil, policy)
        getState = function() return Floating:NormalizeState(M.ephemeralState, policy) end
        setState = function(value) M.ephemeralState = Floating:NormalizeState(value, policy); return true end
        persistState = function() return true end
    end

    local surface, err = Floating:Create({
        id = self.id,
        owner = "v3:quest_detail:floating",
        title = "任务详情",
        status = "--",
        -- 中文维护注释（2026-09-22，activity-detail-ui-2）：状态已由顶部 Chip 统一表达；旧 Footer
        -- 再显示“个人进度 x/y”会与顶部重复并浪费 22px。关闭 Footer 不影响 Windowing 的拖动/缩放。
        footer = false,
        movable = true,
        resizable = true,
        minimizeMode = "compact",
        boundaryMode = "free",
        defaultPlacement = "center",
        statePolicy = policy,
        getState = getState,
        setState = setState,
        -- 中文维护注释：任务详情只把窗口几何/锁定/透明度写入 Presentation Store；
        -- 业务数据继续由原 Feature/Service Authority 管理，避免第二业务 Authority。
        persist = persistState,
        onClosed = function(_, reason)
            M.visible = false
            -- 中文维护注释（2026-09-21，独立生命周期）：X 按钮和程序 Close 必须走同一释放链。
            -- 关闭仅释放本详情窗自己的 Consumer/内部事件，不关闭 Activities/Tasks Feature，也不清用户配置。
            local cleaned, cleanupErr = M:DeactivateSession(tostring(reason or "window_closed"))
            if cleaned ~= true and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Record) == "function" then
                S.DiagnosticsManager:Record("warning", "v3.quest_detail", "任务详情关闭清理失败: " .. tostring(cleanupErr or "unknown"))
            end
            return true
        end,
    })
    if surface == nil then return false, err or "任务详情悬浮窗创建失败" end
    self.surface, self.shell = surface, surface.shell

    local stack = RSUI:VerticalBox({ id = self.id .. "_stack", parent = surface:GetContentRoot(), gap = 5,
        slot = { hAlign = "fill", vAlign = "fill" } })

    -- 中文维护注释（2026-09-21，activity-progress-selection-ui-1）：个人进度选择不再需要第二排
    -- “加入追踪/仅追踪”按钮。顶部只保留紧凑状态条，表格第一列直接显示追踪勾选；点击 main row 即切换。
    -- 这样详情窗口更接近游戏任务面板，也避免用户误把“收藏/筛选”理解成和 0/N 无关的第二套状态。
    self.summaryRow = RSUI:HorizontalBox({ id = self.id .. "_summary_row", parent = stack, gap = 6,
        slot = { size = "fixed", height = 24, hAlign = "fill" } })
    self.progressChip = RSUI:StatusChip({ id = self.id .. "_progress_chip", parent = self.summaryRow,
        status = "neutral", text = "个人进度 --", minWidth = 102, maxWidth = 142, slot = { size = "auto" } })
    self.trackingChip = RSUI:StatusChip({ id = self.id .. "_tracking_chip", parent = self.summaryRow,
        status = "neutral", text = "追踪 0/0", minWidth = 82, maxWidth = 118, slot = { size = "auto" } })
    self.relatedChip = RSUI:StatusChip({ id = self.id .. "_related_chip", parent = self.summaryRow,
        status = "neutral", text = "关联 0", minWidth = 68, maxWidth = 104, slot = { size = "auto" } })
    self.summary = RSUI:Text({ id = self.id .. "_summary", parent = self.summaryRow, text = "--", fontSize = 9, tone = "muted",
        overflow = "ellipsis", slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "center" } })

    self.table = RSUI:TableView({
        id = self.id .. "_table", parent = stack, items = {}, rowHeight = 28, headerHeight = 27, desiredRows = 10,
        scrollbar = true, selectable = true, selectionMode = "single", columnResize = true, headerInteractive = false,
        getKey = function(item, index) return item and item.key or tostring(index or 0) end,
        -- TableRow 是 RU 已验证的点击 surface；业务动作绑定 SelectionChanged 并立即清掉临时选择。
        -- 不创建每行 Button/Checkbox，因此不会增加 Native 对象或 Tick。
        onSelectionChanged = function(index, _, view, _, reason, key, selected)
            return M:HandleProgressSelectionChanged(index, view, reason, key, selected)
        end,
        columns = {
            { id = "tracking", title = "追踪", field = "trackingText", size = "fixed", width = 62, minWidth = 58, absoluteMinWidth = 52,
                getTone = function(item) return item and item.progressSelectable == true and (item.progressSelected == true and "green" or "muted") or "muted" end },
            { id = "category", title = "类型", field = "category", size = "fixed", width = 86, minWidth = 66, absoluteMinWidth = 52,
                getTone = function(item) return item and item.related and "accent" or "muted" end },
            { id = "name", title = "任务 / 阶段", field = "name", size = "fill", minWidth = 200, absoluteMinWidth = 96, fill = 1.7,
                getTone = function(item) return item and item.tone or "default" end },
            { id = "status", title = "状态", field = "status", size = "fixed", width = 76, minWidth = 68, absoluteMinWidth = 54,
                getTone = function(item) return item and item.tone or "muted" end },
        },
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    self.hint = RSUI:Text({ id = self.id .. "_hint", parent = stack, text = "--", fontSize = 9, tone = "muted",
        overflow = "ellipsis", slot = { size = "fixed", height = 20, hAlign = "fill" } })
    if self.summaryRow == nil or self.progressChip == nil or self.relatedChip == nil or self.trackingChip == nil
        or self.summary == nil or self.table == nil or self.hint == nil then
        surface:Destroy()
        self.surface, self.shell = nil, nil
        return false, "任务详情悬浮窗内容创建失败"
    end
    surface:Show(false)
    self.created = true
    return true
end

function M:SubscribeProgress()
    if self.subscribed == true then return true end
    if S.Events == nil or type(S.Events.SubscribeInternal) ~= "function" then return false, "内部事件总线不可用" end
    local subscribed = S.Events:SubscribeInternal("v3.quest_progress.refreshed", self, function()
        -- 中文维护注释（2026-09-21，Journal 实时目标）：只在详情可见且有任务映射时重读当前组。
        -- QuestProgress 已完成事件合并/15s safety，并在发布前清掉 Journal cache，所以这里不再增加调度器或 Tick。
        if M.visible == true and M.switching ~= true and M.consumerHeld == true
            and type(M.current) == "table" and M.current.mapped == true then
            M:RefreshCurrent("quest_progress_refreshed")
        end
    end)
    if subscribed ~= true then return false, "任务详情进度订阅失败" end
    self.subscribed = true
    return true
end

function M:UnsubscribeProgress()
    if self.subscribed ~= true then return true end
    if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then
        S.Events:UnsubscribeInternalOwner(self)
    end
    self.subscribed = false
    return true
end

function M:ReleaseProgressConsumer(reason)
    if self.consumerHeld ~= true then return true end
    local service = S.Services and S.Services.QuestProgressV3 or nil
    -- Runtime shutdown may have transactionally cleared all Demand leases before the native window closes.
    -- Treat an already-cleared token as released; never resurrect or fail a close because ownership ended upstream.
    local demand = type(service) == "table" and service.Demand or nil
    if type(demand) == "table" and type(demand.Has) == "function" and demand:Has(self.consumerToken) ~= true then
        self.consumerHeld = false
        return true
    end
    if type(service) ~= "table" or type(service.ReleaseConsumer) ~= "function" then
        self.consumerHeld = false
        return false, "新版任务进度服务不可用"
    end
    local released, releaseErr = service:ReleaseConsumer(self.consumerToken)
    if released ~= true then return false, releaseErr or ("任务详情 Consumer 释放失败: " .. tostring(reason or "close")) end
    self.consumerHeld = false
    return true
end

function M:DeactivateSession(reason)
    local unsubscribed, unsubscribeErr = self:UnsubscribeProgress()
    local released, releaseErr = self:ReleaseProgressConsumer(reason)
    self.current = nil
    self.selectedRowKey = nil
    self.selectionChangeInFlight = false
    self.lastDetail, self.lastRawDetail, self.lastSource = nil, nil, nil
    self.projectedByKey = {}
    self.lastTrackedCount, self.lastTrackableCount = 0, 0
    self.trackingAvailable, self.trackingLoadError = false, nil
    if released ~= true then return false, releaseErr end
    if unsubscribed ~= true then return false, unsubscribeErr end
    return true
end

function M:RenderDetail(detail, source, reason)
    if type(detail) ~= "table" then return false, "任务详情数据为空" end
    if self.summary == nil or self.progressChip == nil or self.relatedChip == nil or self.trackingChip == nil
        or self.table == nil or self.hint == nil then return false, "任务详情控件未创建" end
    self.revision = (tonumber(self.revision) or 0) + 1
    self.lastDetail, self.lastSource = detail, source
    local title = SourceTitle(source, detail.title or "任务详情")
    if self.shell ~= nil and type(self.shell.SetTitle) == "function" then self.shell:SetTitle(title) end

    local scope = tostring(detail.scope or (self.current and self.current.scope) or "event")
    local completed = math.max(0, math.floor(tonumber(detail.completed) or 0))
    local total = math.max(0, math.floor(tonumber(detail.total) or 0))
    local relatedCount = math.max(0, math.floor(tonumber(detail.relatedCount) or 0))
    local selectionEnabled = scope == "event" and detail.progressSelectionEnabled == true
    if selectionEnabled then
        self.trackingAvailable = detail.progressSelectionAvailable == true
        self.trackingLoadError = detail.progressSelectionError
    end
    if detail.kind == "unmapped" then
        self.progressChip:SetStatus("unavailable", "暂无任务映射", "muted")
    elseif detail.kind == "scoreQuest" then
        -- 中文维护注释（2026-09-22，Garden score UI）：Activity 层必须和其他单任务活动保持统一的 0/1 -> 1/1。
        -- 积分/Reward Level 是这一个任务内部的详细目标，不替代完成度；若 Native Journal 提供，则继续在下方原样展示。
        local done = total > 0 and completed >= total
        local status, tone = done and "success" or "pending", done and "green" or "yellow"
        if (tonumber(detail.readyCount) or 0) > 0 then status, tone = "pending", "orange" end
        if total <= 0 then status, tone = "neutral", "muted" end
        self.progressChip:SetStatus(status, "主进度 " .. tostring(math.min(completed, 1)) .. "/1", tone)
    elseif total > 0 then
        local done = completed >= total
        self.progressChip:SetStatus(done and "success" or "pending",
            (selectionEnabled and "个人进度 " or "主进度 ") .. tostring(completed) .. "/" .. tostring(total), done and "green" or "yellow")
    else
        self.progressChip:SetStatus("neutral", "暂无主任务", "muted")
    end
    self.relatedChip:SetStatus(relatedCount > 0 and "info" or "neutral", "关联 " .. tostring(relatedCount), relatedCount > 0 and "accent" or "muted")

    -- mapped 详情不长期显示 Activity row 的倒计时/区域状态，因为本窗口只持有 QuestProgress Consumer；
    -- 主页面关闭后 Activity Authority 可以按设计静默。个人 x/y 由 Activities Feature 同一 read-model 投影，
    -- 因此详情和主列表不会各自维护一份分母算法。
    local summaryText = detail.kind == "unmapped" and JoinSummary(source, detail.summaryText or "--") or tostring(detail.summaryText or "--")
    -- 中文维护注释（2026-09-22，activity-detail-ui-2）：mapped Event 的 x/y、追踪数、关联数已经由
    -- 三个 Chip 完整表达；再在右侧显示“个人进度 6/6 · 3 项关联任务”属于重复信息，并在 560px 宽度
    -- 下挤压布局。Daily/Weekly/未映射详情仍保留摘要文本。
    local showSummaryText = detail.kind == "unmapped" or scope ~= "event"
    self.summary:SetVisible(showSummaryText)
    self.summary:SetText(showSummaryText and summaryText or "")

    local children, selectedCount, eligibleCount = self:ProjectDetailRows(detail)
    self.lastTrackedCount, self.lastTrackableCount = selectedCount, eligibleCount -- 兼容旧诊断字段名。
    self.table:SetItems(children, "floating_detail:" .. tostring(self.revision))
    if self.selectedRowKey ~= nil and self.projectedByKey[tostring(self.selectedRowKey)] == nil then
        self.selectedRowKey = nil
        if type(self.table.ClearSelection) == "function" then self.table:ClearSelection() end
    end
    if #children == 0 then
        self.table:SetViewState("empty", { title = "暂无子任务详情", detail = "当前条目没有已核验的任务明细。" })
    else
        self.table:SetViewState("ready")
    end

    -- 切换活动/显式重新打开时清空旧选择；Quest 实时刷新和个人进度勾选只重绑同一 key，不跳顶。
    if tostring(reason or "") == "open" then
        self.selectedRowKey = nil
        if type(self.table.ClearSelection) == "function" then self.table:ClearSelection() end
        if type(self.table.ScrollToTop) == "function" then self.table:ScrollToTop() end
    end
    self:UpdateTrackingControls(selectedCount, eligibleCount, detail)

    if detail.kind == "unmapped" then
        self.hint:SetText("当前活动暂无已核验任务映射；后续补充 Quest ID 后会自动进入同一详情界面。")
    elseif detail.kind == "scoreQuest" then
        self.hint:SetText("活动完成度按精灵的委托记 0/1→1/1；实时积分和奖励阶段以游戏任务日志目标为准。")
    elseif scope == "event" and selectionEnabled then
        if self.trackingAvailable == true then
            self.hint:SetText("点击主任务行切换追踪；只有已追踪主任务计入个人进度，关联任务不计入。")
        else
            self.hint:SetText("当前按默认全部任务计算；个人进度追踪暂不可保存：" .. tostring(self.trackingLoadError or "存档未就绪"))
        end
    elseif scope == "event" then
        self.hint:SetText("当前活动暂未开放自定义进度追踪；主任务按默认集合计算，关联任务仅作参考。")
    else
        self.hint:SetText("主任务计入该" .. (scope == "weekly" and "周常" or "日常") .. "进度；关联任务只作详情参考。")
    end
    -- footer=false：顶部 Chip 已是唯一状态语义 Authority，避免底部再次重复“个人进度 x/y”。
    return true
end

function M:RefreshCurrent(reason)
    local session = self.current
    if type(session) ~= "table" then return false, "任务详情 Session 不存在" end
    if session.mapped ~= true then
        self.lastRawDetail = nil
        return self:RenderDetail(BuildUnmappedDetail(session.scope, session.key, session.source), session.source, reason)
    end
    local service = S.Services and S.Services.QuestProgressV3 or nil
    if type(service) ~= "table" or type(service.GetGroupDetail) ~= "function" then return false, "新版任务进度服务不可用" end
    -- Journal Native 读取仍全部封装在 QuestProgressV3；Presentation 只请求当前显式详情。
    local rawDetail = service:GetGroupDetail(session.scope, session.key, { journal = true })
    if type(rawDetail) ~= "table" then
        self.lastRawDetail = nil
        return self:RenderDetail(BuildUnmappedDetail(session.scope, session.key, session.source), session.source, reason)
    end
    self.lastRawDetail = rawDetail
    local detail = rawDetail
    if session.scope == "event" then
        local activity = ActivityFeature()
        if type(activity) == "table" and type(activity.ProjectActivityDetail) == "function" then
            detail = activity:ProjectActivityDetail(rawDetail)
        end
    end
    return self:RenderDetail(detail, session.source, reason)
end

local function FailOpen(message)
    message = tostring(message or "任务详情打开失败")
    NotifyUnavailable(message)
    -- ToastHost 在主菜单关闭时可能不可见；技术失败同步给聊天，避免再次出现“完全没反应”。
    if type(S.SafeChat) == "function" then S.SafeChat("[Replicated Suite] 任务详情打开失败：" .. message) end
    return false, message
end

function M:GetInteractionDiagnostics()
    return {
        generation = tonumber(self.generation) or 0,
        created = self.created == true,
        visible = self.visible == true,
        shellDestroyed = self.shell ~= nil and self.shell.destroyed == true or false,
        consumerHeld = self.consumerHeld == true,
        subscribed = self.subscribed == true,
        layoutDurable = self.layoutDurable == true,
        layoutLoadError = self.layoutLoadError,
        trackingAvailable = self.trackingAvailable == true, -- compatibility label: personal progress selection writable
        trackingLoadError = self.trackingLoadError,
        progressSelectionSelected = tonumber(self.lastTrackedCount) or 0,
        progressSelectionEligible = tonumber(self.lastTrackableCount) or 0,
        selectedRowKey = self.selectedRowKey,
        progressToggleAttempts = tonumber(self.progressToggleAttempts) or 0,
        progressToggleSuccesses = tonumber(self.progressToggleSuccesses) or 0,
        progressToggleFailures = tonumber(self.progressToggleFailures) or 0,
        lastProgressToggleKey = self.lastProgressToggleKey,
        lastProgressToggleError = self.lastProgressToggleError,
        currentKey = type(self.current) == "table" and self.current.key or nil,
        currentScope = type(self.current) == "table" and self.current.scope or nil,
    }
end

function M:Open(scope, key, sourceRow)
    scope, key = tostring(scope or "event"), tostring(key or "")
    local ok, err = self:EnsureCreated()
    if ok ~= true then return FailOpen(err or "任务详情悬浮窗创建失败") end

    local source = SnapshotSourceRow(sourceRow)
    local service = S.Services and S.Services.QuestProgressV3 or nil
    local kind = nil
    if key ~= "" and type(service) == "table" and type(service.GetGroupKind) == "function" then
        kind = service:GetGroupKind(scope, key)
    end
    local mapped = key ~= "" and kind ~= nil
    -- 维护：切换条目时 Demand reconcile/显式 Refresh 会同步发布 refreshed；在 current 尚未提交前屏蔽回调，
    -- 避免先把旧活动 Journal 重绘一次再立即切到新活动，减少 Native 目标读取和视觉闪烁。
    self.switching = true

    if mapped == true then
        if type(service) ~= "table" or type(service.AcquireConsumer) ~= "function" then
            self.switching = false
            return FailOpen("新版任务进度服务不可用。")
        end
        local needsInstances = kind == "instanceRaid"
        -- 中文维护注释（2026-09-21，详情独立 Consumer）：普通活动只请求 QuestProgress；只有静态分组明确为
        -- instanceRaid 才把 instances=true 传给 Demand，避免查看征兆/鲸鱼时无意义唤醒 InstanceCatalog。
        local acquired, transitioned = service:AcquireConsumer(self.consumerToken, { instances = needsInstances })
        if acquired ~= true then self.switching = false; return FailOpen(transitioned or "任务详情 Consumer 启动失败") end
        self.consumerHeld = true
        local subscribed, subscribeErr = self:SubscribeProgress()
        if subscribed ~= true then
            self:ReleaseProgressConsumer("subscribe_rollback")
            self.switching = false
            return FailOpen(subscribeErr or "任务详情进度订阅失败")
        end
        -- Demand token 的 options 与上一条相同（例如从征兆切到鲸鱼）时不会触发 reconcile；显式点击
        -- 本身是合理的即时刷新边界，因此仅在没有 Demand transition 时补一次同步 Refresh。首次 Acquire/切副本
        -- 已由 Demand reconcile 刷新，避免重复 Native 读取。
        if transitioned ~= true and type(service.Refresh) == "function" then
            local refreshed, refreshErr = service:Refresh("quest_detail_open", needsInstances)
            if refreshed ~= true then
                self.switching = false
                self:DeactivateSession("refresh_failed")
                return FailOpen(refreshErr or "任务详情刷新失败")
            end
        end
    else
        -- 无任务映射的活动仍然可以打开详情，但不应为了一个静态“暂无任务”窗口保持 Quest/Instance 后台服务。
        self:UnsubscribeProgress()
        self:ReleaseProgressConsumer("unmapped_detail")
    end

    self.current = {
        scope = scope,
        key = key,
        source = source,
        mapped = mapped == true,
        kind = kind,
    }
    -- 中文维护注释（2026-09-21，activity-progress-selection-1）：个人进度 Store 与 Quest Consumer 是
    -- 两条独立生命周期。偏好读取失败不能阻断任务详情/Journal；此时按默认全部主任务计算并禁用编辑。
    -- Daily/Weekly 继续使用自己的任务规则，这里只服务 event scope 的 opt-in 活动。
    self.trackingAvailable, self.trackingLoadError = false, nil
    if scope == "event" and mapped == true then
        local activity = ActivityFeature()
        if type(activity) == "table" and type(activity.EnsureDetailTrackingLoaded) == "function" then
            local trackingOk, trackingErr = activity:EnsureDetailTrackingLoaded()
            self.trackingAvailable = trackingOk == true
            self.trackingLoadError = trackingOk == true and nil or tostring(trackingErr or "活动个人进度选择读取失败")
        else
            self.trackingLoadError = "活动个人进度选择服务不可用"
        end
    end
    local rendered, renderErr = self:RefreshCurrent("open")
    self.switching = false
    if rendered ~= true then
        if mapped == true then self:DeactivateSession("render_failed") end
        return FailOpen(renderErr or "任务详情绘制失败")
    end

    -- Activating a new row is an explicit request to read the detail; restore
    -- a previously compact-minimized session window instead of leaving only
    -- the tiny square visible.
    local restored, restoreErr = self.surface:SetMinimized(false, false)
    if restored ~= true then
        if mapped == true then self:DeactivateSession("restore_failed") end
        return FailOpen(restoreErr or "任务详情窗口恢复失败")
    end
    local shown, showErr = self.surface:Show(true)
    if shown ~= true and type(self.surface.ResetLayout) == "function" then
        -- 旧分辨率/坏几何只允许一次内存恢复；业务数据和任务 Consumer 不参与该几何事务。
        local resetOk = self.surface:ResetLayout(false)
        if resetOk == true then shown, showErr = self.surface:Show(true) end
    end
    if shown ~= true then
        if mapped == true then self:DeactivateSession("show_failed") end
        return FailOpen(showErr or "任务详情窗口显示失败")
    end
    self.visible = true
    return true
end

function M:Close(reason)
    if self.surface == nil then
        self.visible = false
        return self:DeactivateSession(reason or "quest_detail_close")
    end
    local closed, closeErr = self.surface:Close(reason or "quest_detail_close")
    if closed ~= true then return false, closeErr end
    self.visible = false
    return true
end
