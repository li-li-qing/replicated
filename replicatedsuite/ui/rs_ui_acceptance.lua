------------------------------------------------------------------------
-- Replicated Suite - UI Acceptance / Responsive Regression (M6)
--
-- On-demand diagnostics only. This module never registers Tick/OnUpdate and
-- never mutates the player's resolution, UI scale, font scale or saved layout.
-- It combines:
--   * a pure synthetic matrix built from the shared Layout Authority; and
--   * a live RSUI inspector pass for the shell and every registered RSUI workspace.
--
-- The purpose is to make 1024x768 -> 2560x1440 and 80% -> 120% scale testing
-- reproducible without introducing resolution-specific branches into business
-- pages. Runtime layout still comes exclusively from S.Layout / RSUI.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI

S.UIAcceptance = S.UIAcceptance or { version = 3, last = nil }
S.UIAcceptance.version = 3
local A = S.UIAcceptance

local TARGETS = {
    { width = 1024, height = 768 },
    { width = 1280, height = 720 },
    { width = 1366, height = 768 },
    { width = 1920, height = 1080 },
    { width = 2560, height = 1440 },
}
local ADDON_SCALES = { 0.80, 1.00, 1.20 }
local FONT_SCALES = { 1.00, 1.20, 1.50 }

local function AddFlag(flags, value)
    flags[#flags + 1] = tostring(value)
end

local function InspectSpec(context, spec)
    local flags, warnings = {}, {}
    local epsilon = 0.05
    if (tonumber(spec.width) or 0) <= 0 or (tonumber(spec.height) or 0) <= 0 then AddFlag(flags, "invalid_window_extent") end
    if (tonumber(spec.contentWidth) or 0) <= 0 or (tonumber(spec.contentHeight) or 0) <= 0 then AddFlag(flags, "invalid_content_extent") end
    if (tonumber(spec.width) or 0) > (tonumber(context.usableWidth) or 0) + epsilon then AddFlag(flags, "window_width_overflow") end
    if (tonumber(spec.height) or 0) > (tonumber(context.usableHeight) or 0) + epsilon then AddFlag(flags, "window_height_overflow") end
    if (tonumber(spec.contentX) or 0) + (tonumber(spec.contentWidth) or 0) > (tonumber(spec.width) or 0) - (tonumber(spec.margin) or 0) + epsilon then
        AddFlag(flags, "content_x_overflow")
    end
    if (tonumber(spec.contentY) or 0) + (tonumber(spec.contentHeight) or 0) > (tonumber(spec.height) or 0) - (tonumber(spec.margin) or 0) + epsilon then
        AddFlag(flags, "content_y_overflow")
    end
    if (tonumber(spec.navWidth) or 0) + (tonumber(spec.navGap) or 0) + (tonumber(spec.margin) or 0) * 2 >= (tonumber(spec.width) or 0) then
        AddFlag(flags, "nav_consumes_window")
    end

    local scale = math.max(0.01, tonumber(context.addonScale) or 1)
    local designContentW = (tonumber(spec.contentWidth) or 0) / scale
    local designContentH = (tonumber(spec.contentHeight) or 0) / scale
    -- Warnings are intentionally informational. Narrow layouts are valid when
    -- the corresponding page owns Scroll/Wrap/ellipsis policies.
    if designContentW < 360 then warnings[#warnings + 1] = "very_narrow_content" end
    if designContentH < 420 then warnings[#warnings + 1] = "short_content" end
    return flags, warnings
end

function A:RunMatrix()
    local rows, failures, warnings = {}, 0, 0
    local worstW, worstH = math.huge, math.huge
    if S.Layout == nil or type(S.Layout.BuildSyntheticContext) ~= "function" or type(S.Layout.BuildMainSpec) ~= "function" then
        return { ok = false, reason = "layout_simulation_unavailable", rows = {}, failures = 1, warnings = 0 }
    end

    for _, target in ipairs(TARGETS) do
        for _, addonScale in ipairs(ADDON_SCALES) do
            for _, fontScale in ipairs(FONT_SCALES) do
                local context = S.Layout:BuildSyntheticContext(target.width, target.height, addonScale)
                for _, mode in ipairs({ "default", "minimum" }) do
                    local placement = nil
                    if mode == "minimum" then
                        placement = {
                            width = S.Constants.MainWindow.minWidth,
                            height = S.Constants.MainWindow.minHeight,
                        }
                    end
                    local spec = S.Layout:BuildMainSpec(context, placement, fontScale)
                    local flags, rowWarnings = InspectSpec(context, spec)
                    failures = failures + (#flags > 0 and 1 or 0)
                    warnings = warnings + (#rowWarnings > 0 and 1 or 0)
                    worstW = math.min(worstW, tonumber(spec.contentWidth) or math.huge)
                    worstH = math.min(worstH, tonumber(spec.contentHeight) or math.huge)
                    rows[#rows + 1] = {
                        width = target.width, height = target.height,
                        addonScale = addonScale, fontScale = fontScale, mode = mode,
                        spec = spec, flags = flags, warnings = rowWarnings,
                    }
                end
            end
        end
    end

    return {
        ok = failures == 0,
        rows = rows,
        failures = failures,
        warnings = warnings,
        cases = #rows,
        worstContentWidth = worstW == math.huge and 0 or worstW,
        worstContentHeight = worstH == math.huge and 0 or worstH,
    }
end

function A:RunTextStress()
    local textLayout = type(RSUI) == "table" and RSUI.TextLayout or nil
    if type(textLayout) ~= "table" or type(textLayout.Wrap) ~= "function" or type(textLayout.Ellipsize) ~= "function" then
        return { ok = false, failures = 1, cases = 0, reason = "text_layout_unavailable" }
    end
    local samples = {
        "这是用于验证超长中文任务名称与活动阶段文字是否能够安全换行并保持UTF8字符边界的压力测试文本",
        "Очень длинное русское название задания и состояния события для проверки безопасного переноса текста интерфейса",
        "Extremely long English activity and trade-pack description used to verify word-boundary wrapping and ellipsis behavior",
        "Replicated_ОченьДлинноеИмя玩家_WithMixedLanguage_1234567890",
    }
    local metrics = textLayout.metrics
    local saved = nil
    if type(metrics) == "table" then
        saved = {}
        for k, v in pairs(metrics) do saved[k] = v end
    end
    local failures, cases = 0, 0
    for _, sample in ipairs(samples) do
        for _, width in ipairs({ 120, 220, 360 }) do
            for _, font in ipairs({ 10, 15 }) do
                cases = cases + 1
                local ok, wrapped, lines = pcall(function() return textLayout:Wrap(nil, sample, width, font, 3) end)
                if not ok or type(wrapped) ~= "string" or wrapped == "" or (tonumber(lines) or 0) < 1 or (tonumber(lines) or 0) > 3 then failures = failures + 1 end
                local okEllipsis, fitted = pcall(function() return textLayout:Ellipsize(nil, sample, width, font) end)
                if not okEllipsis or type(fitted) ~= "string" then failures = failures + 1 end
            end
        end
    end
    if saved ~= nil and type(metrics) == "table" then
        for k in pairs(metrics) do metrics[k] = nil end
        for k, v in pairs(saved) do metrics[k] = v end
    end
    return { ok = failures == 0, failures = failures, cases = cases }
end

local function InspectComponent(component, label, out)
    if type(RSUI) ~= "table" or type(RSUI.IsComponent) ~= "function" or type(RSUI.InspectLayout) ~= "function" then return end
    if not RSUI:IsComponent(component) then return end
    local report = RSUI:InspectLayout(component, { maxNodes = 384, maxDepth = 24 })
    if report == nil or report.ok ~= true then return end
    local hard, soft = 0, 0
    local textTruncated = tonumber(report.textTruncatedCount) or 0
    local samples = {}
    for _, issue in ipairs(report.issues or {}) do
        local isHard = false
        local isSoft = false
        for _, flag in ipairs(issue.flags or {}) do
            if flag == "text_overflow" or flag == "text_truncated" then isSoft = true else isHard = true end
        end
        if isHard then hard = hard + 1 elseif isSoft then soft = soft + 1 end
        if #samples < 8 and (isHard or isSoft) then
            samples[#samples + 1] = tostring(label) .. ":" .. tostring(issue.path or issue.id or "?") .. " [" .. table.concat(issue.flags or {}, ",") .. "]"
        end
    end
    out[#out + 1] = {
        label = tostring(label), nodeCount = tonumber(report.nodeCount) or 0,
        hard = hard, soft = soft, textTruncated = textTruncated, samples = samples,
    }
end

local function InspectPageRoots(pageName, page, sections)
    if type(page) ~= "table" then return 0 end
    local seen, count = {}, 0
    if RSUI:IsComponent(page.component) then
        InspectComponent(page.component, "page/" .. tostring(pageName), sections)
        seen[page.component] = true
        count = count + 1
    end
    local roots = nil
    if type(page.GetInspectionRoots) == "function" then
        local ok, value = pcall(function() return page:GetInspectionRoots() end)
        if ok and type(value) == "table" then roots = value end
    elseif type(page.inspectionRoots) == "table" then
        roots = page.inspectionRoots
    end
    for index, root in ipairs(type(roots) == "table" and roots or {}) do
        if RSUI:IsComponent(root) and seen[root] ~= true then
            seen[root] = true
            InspectComponent(root, "page/" .. tostring(pageName) .. "/root" .. tostring(index), sections)
            count = count + 1
        end
    end
    return count
end

function A:InspectLive()
    local frameworkBefore = S.UI and type(S.UI.GetFrameworkSnapshot) == "function" and S.UI:GetFrameworkSnapshot() or nil
    local cacheRepairsBefore = type(frameworkBefore) == "table" and (tonumber(frameworkBefore.cacheRepairs) or 0) or 0
    local cacheRepairFieldsBefore = type(frameworkBefore) == "table" and type(frameworkBefore.cacheRepairsByField) == "table" and frameworkBefore.cacheRepairsByField or {}
    local cacheRepairOwnersBefore = {}
    for _, row in ipairs(type(frameworkBefore) == "table" and type(frameworkBefore.cacheRepairsByOwner) == "table" and frameworkBefore.cacheRepairsByOwner or {}) do
        cacheRepairOwnersBefore[tostring(row.owner or "")] = tonumber(row.count) or 0
    end
    -- UI acceptance is an explicit diagnostic action. Flush one-shot dirty
    -- roots first, then force a layout-only pass for every registered page.
    -- We deliberately do NOT call ShowPage/Refresh here: acceptance must not
    -- alter the saved page, trigger world scans, or change presentation state.
    if type(RSUI.FlushLayoutQueue) == "function" then RSUI:FlushLayoutQueue(64) end
    local result = {
        ok = true, mainVisible = true, hardIssues = 0, softIssues = 0,
        nodeCount = 0, textTruncated = 0, sections = {}, samples = {}, auditedPages = 0,
        auditedRoots = 0, currentPage = S.UI and tostring(S.UI.currentPage or "") or "",
    }
    local mainWindow = S.MainWindow and S.MainWindow.window or nil
    if mainWindow ~= nil and S.Layout ~= nil and type(S.Layout.GetLogicalRect) == "function" and type(S.Layout.IsRectFullyVisible) == "function" then
        local x, y, w, h = S.Layout:GetLogicalRect(mainWindow)
        result.mainVisible = S.Layout:IsRectFullyVisible(x, y, w, h)
        if result.mainVisible ~= true then result.hardIssues = result.hardIssues + 1 end
        result.mainRect = { x = x, y = y, width = w, height = h }
    end

    local sections = {}
    local shell = S.MainWindow and S.MainWindow.appShell or nil
    if shell ~= nil then
        InspectComponent(shell.navFrame, "shell/nav", sections)
        InspectComponent(shell.contentFrame, "shell/content", sections)
        -- A navigation rail can be technically non-overlapping yet still clip
        -- an entire group. Compare desired document height with the live rail.
        if shell.navStack ~= nil and type(shell.navStack.Measure) == "function" and shell.navFrame ~= nil then
            local ok, _, desiredH = pcall(function() return shell.navStack:Measure(tonumber(shell.navFrame.width) or nil, nil) end)
            if ok and tonumber(desiredH) and tonumber(shell.navFrame.height) and desiredH > shell.navFrame.height + 0.5 then
                result.hardIssues = result.hardIssues + 1
                result.samples[#result.samples + 1] = string.format("shell/nav [desired_height_overflow %.1f > %.1f]", desiredH, shell.navFrame.height)
            end
        end
    end

    local pages = S.UI and S.UI.pages or {}
    local names = {}
    for name, page in pairs(type(pages) == "table" and pages or {}) do
        if type(page) == "table" then names[#names + 1] = tostring(name) end
    end
    table.sort(names)
    local spec = S.Layout and type(S.Layout.GetMainSpec) == "function" and S.Layout:GetMainSpec() or nil
    for _, pageName in ipairs(names) do
        local page = pages[pageName]
        if type(spec) == "table" and S.UI ~= nil and type(S.UI.EnsurePageLayout) == "function" and type(page.ApplyLayout) == "function" then
            local ok = pcall(function() S.UI:EnsurePageLayout(pageName, true, spec) end)
            if not ok then
                result.hardIssues = result.hardIssues + 1
                if #result.samples < 8 then result.samples[#result.samples + 1] = "page/" .. tostring(pageName) .. " [layout_exception]" end
            end
        end
        if type(RSUI.FlushLayoutQueue) == "function" then RSUI:FlushLayoutQueue(64) end
        local roots = InspectPageRoots(pageName, page, sections)
        if roots > 0 then
            result.auditedPages = result.auditedPages + 1
            result.auditedRoots = result.auditedRoots + roots
        end
    end

    local queued = 0
    if type(RSUI.layoutQueue) == "table" then for _ in pairs(RSUI.layoutQueue) do queued = queued + 1 end end
    result.pendingLayoutRoots = queued
    if queued > 0 then result.hardIssues = result.hardIssues + queued end

    for _, section in ipairs(sections) do
        result.nodeCount = result.nodeCount + (tonumber(section.nodeCount) or 0)
        result.hardIssues = result.hardIssues + (tonumber(section.hard) or 0)
        result.softIssues = result.softIssues + (tonumber(section.soft) or 0)
        result.textTruncated = result.textTruncated + (tonumber(section.textTruncated) or 0)
        for _, sample in ipairs(section.samples or {}) do if #result.samples < 8 then result.samples[#result.samples + 1] = sample end end
    end
    result.sections = sections
    result.page = result.currentPage
    local frameworkAfter = S.UI and type(S.UI.GetFrameworkSnapshot) == "function" and S.UI:GetFrameworkSnapshot() or nil
    local cacheRepairsAfter = type(frameworkAfter) == "table" and (tonumber(frameworkAfter.cacheRepairs) or 0) or cacheRepairsBefore
    result.cacheRepairs = math.max(0, cacheRepairsAfter - cacheRepairsBefore)
    result.cacheRepairFields = {}
    local cacheRepairFieldsAfter = type(frameworkAfter) == "table" and type(frameworkAfter.cacheRepairsByField) == "table" and frameworkAfter.cacheRepairsByField or {}
    for _, field in ipairs({ "text", "visible", "extent", "anchor" }) do
        result.cacheRepairFields[field] = math.max(0, (tonumber(cacheRepairFieldsAfter[field]) or 0) - (tonumber(cacheRepairFieldsBefore[field]) or 0))
    end
    if type(frameworkAfter) == "table" and type(frameworkAfter.cacheRepairsByOwner) == "table" then
        local bestOwner, bestCount = nil, 0
        for _, row in ipairs(frameworkAfter.cacheRepairsByOwner) do
            local owner = tostring(row.owner or "")
            local delta = math.max(0, (tonumber(row.count) or 0) - (tonumber(cacheRepairOwnersBefore[owner]) or 0))
            if delta > bestCount then bestOwner, bestCount = owner, delta end
        end
        if bestOwner ~= nil then result.cacheRepairTopOwner = { owner = bestOwner, count = bestCount } end
    end
    result.layoutHostInvalidations = type(RSUI.metrics) == "table" and (tonumber(RSUI.metrics.externalLayoutInvalidations) or 0) or 0
    result.duplicateTypeRegistrations = type(RSUI.metrics) == "table" and (tonumber(RSUI.metrics.duplicateTypeRegistrations) or 0) or 0
    if result.duplicateTypeRegistrations > 0 then result.hardIssues = result.hardIssues + result.duplicateTypeRegistrations end
    if result.cacheRepairs > 0 and #result.samples < 8 then
        local fields = result.cacheRepairFields or {}
        local owner = type(result.cacheRepairTopOwner) == "table" and tostring(result.cacheRepairTopOwner.owner or "") or ""
        result.samples[#result.samples + 1] = string.format("framework [native_cache_repair=%d text=%d visible=%d extent=%d anchor=%d%s]",
            tonumber(result.cacheRepairs) or 0, tonumber(fields.text) or 0, tonumber(fields.visible) or 0,
            tonumber(fields.extent) or 0, tonumber(fields.anchor) or 0, owner ~= "" and (" top=" .. owner) or "")
    end
    result.ok = result.hardIssues == 0 and result.mainVisible == true
    return result
end

local function CompactCopyText(value)
    local text = tostring(value or "")
    text = text:gsub("\r\n", " "):gsub("\r", " "):gsub("\n", " ")
    text = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return text
end

local function TruncateCopyText(value, byteLimit)
    local text = CompactCopyText(value)
    byteLimit = math.max(256, tonumber(byteLimit) or 6000)
    if #text <= byteLimit then return text end
    if S.Utils ~= nil and type(S.Utils.TruncateUtf8) == "function" then
        return S.Utils.TruncateUtf8(text, byteLimit, "…[报告截断]")
    end
    return text:sub(1, byteLimit) .. "…[报告截断]"
end

-- Build one copy-friendly packet.  ArcheAge's chat context menu copies one chat
-- message at a time, therefore acceptance details must never fan out into one
-- message per issue.  The structured result remains in A.last for diagnostics;
-- this function only changes presentation.
function A:GetLastCopyText(includeDetails)
    local last = self.last
    if type(last) ~= "table" then return "未运行（点击 全页验收）" end
    local parts = { self:GetLastSummaryText() }
    if includeDetails == true then
        local live = type(last.live) == "table" and last.live or {}
        local samples = live.samples or {}
        if #samples > 0 then
            local rows = {}
            for index, sample in ipairs(samples) do
                rows[#rows + 1] = "#" .. tostring(index) .. " " .. CompactCopyText(sample)
            end
            parts[#parts + 1] = "布局详情 " .. tostring(#rows) .. "项：" .. table.concat(rows, " ｜ ")
        end

        local matrix = type(last.matrix) == "table" and last.matrix or {}
        local rows, total = {}, 0
        for _, row in ipairs(matrix.rows or {}) do
            if #(row.flags or {}) > 0 then
                total = total + 1
                if #rows < 6 then
                    rows[#rows + 1] = string.format("%dx%d/UI%.0f/字体%.0f/%s=%s",
                        tonumber(row.width) or 0, tonumber(row.height) or 0,
                        (tonumber(row.addonScale) or 0) * 100, (tonumber(row.fontScale) or 0) * 100,
                        tostring(row.mode or "?"), table.concat(row.flags or {}, ","))
                end
            end
        end
        if total > 0 then
            parts[#parts + 1] = "矩阵详情 " .. tostring(total) .. "项：" .. table.concat(rows, " ｜ ")
                .. (total > #rows and (" ｜ 其余" .. tostring(total - #rows) .. "项已聚合") or "")
        end
    end
    return TruncateCopyText(table.concat(parts, " ║ "), 6000)
end

function A:PrintLastReport(includeDetails)
    local payload = "UI验收｜" .. self:GetLastCopyText(includeDetails ~= false)
    if S.SafeChat ~= nil then return S.SafeChat(payload) end
    if type(S.DispatchSystemChat) == "function" then return S.DispatchSystemChat("[Replicated Suite] " .. payload) end
    return false
end

function A:Run(printDetails)
    local matrix = self:RunMatrix()
    local text = self:RunTextStress()
    local live = self:InspectLive()
    local now = S.Utils and type(S.Utils.NowMs) == "function" and S.Utils.NowMs() or 0
    self.last = { matrix = matrix, text = text, live = live, at = now }

    local summary = self:GetLastSummaryText()
    self.last.copyText = self:GetLastCopyText(printDetails == true)
    -- One acceptance action produces exactly one copyable chat message.  Never
    -- emit samples/matrix rows separately: right-click copy in the RU client is
    -- message-scoped and multi-line fan-out makes support reports painful.
    self:PrintLastReport(printDetails == true)
    if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Record) == "function" then
        S.DiagnosticsManager:Record((matrix.ok and text.ok and live.ok) and "info" or "warning", "ui_acceptance", self.last.copyText)
    end
    return self.last
end

function A:GetLastSummaryText()
    local last = self.last
    if type(last) ~= "table" then return "未运行（点击 全页验收）" end
    local matrix = type(last.matrix) == "table" and last.matrix or {}
    local text = type(last.text) == "table" and last.text or {}
    local live = type(last.live) == "table" and last.live or {}
    local repairFields = type(live.cacheRepairFields) == "table" and live.cacheRepairFields or {}
    return string.format("矩阵 %d例 / 硬失败 %d / 提醒 %d · 长文本 %d例 / 失败 %d · 全页 %d页/%d根 · 当前 %s · RSUI硬问题 %d / 文本警告 %d · 安全省略 %d · 节点 %d · 待重排 %d · 缓存修复 %d(文%d/显%d/尺%d/锚%d)",
        tonumber(matrix.cases) or 0, tonumber(matrix.failures) or 0, tonumber(matrix.warnings) or 0,
        tonumber(text.cases) or 0, tonumber(text.failures) or 0,
        tonumber(live.auditedPages) or 0, tonumber(live.auditedRoots) or 0,
        live.mainVisible == false and "主窗越界" or tostring(live.currentPage or live.page or "--"),
        tonumber(live.hardIssues) or 0, tonumber(live.softIssues) or 0, tonumber(live.textTruncated) or 0, tonumber(live.nodeCount) or 0,
        tonumber(live.pendingLayoutRoots) or 0, tonumber(live.cacheRepairs) or 0,
        tonumber(repairFields.text) or 0, tonumber(repairFields.visible) or 0, tonumber(repairFields.extent) or 0, tonumber(repairFields.anchor) or 0)
end
