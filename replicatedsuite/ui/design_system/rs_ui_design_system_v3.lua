------------------------------------------------------------------------
-- Replicated Suite V3 - Design System Helpers
--
-- Composition helpers only. They create RSUI components and never own domain
-- state. Visual consistency lives here; page information architecture does not.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
if type(RSUI) ~= "table" then return end

S.UIV3Design = { version = 11, diagnosticHeaderContractVersion = 1 }
local D = S.UIV3Design

local function Text(parent, id, text, size, tone, slot, overflow)
    return RSUI:Text({
        id = id, parent = parent, text = text or "", fontSize = size or 11,
        tone = tone or "default", overflow = overflow or "ellipsis", slot = slot,
    })
end

local function RootSpec(parent, idOrSpec, defaults)
    local spec = {}
    if type(idOrSpec) == "table" then
        for key, value in pairs(idOrSpec) do spec[key] = value end
    else
        spec.id = idOrSpec
    end
    for key, value in pairs(defaults or {}) do
        if spec[key] == nil then spec[key] = value end
    end
    spec.parent = parent
    return spec
end

function D:PageRoot(parent, idOrSpec)
    local spec = RootSpec(parent, idOrSpec, {
        gap = 12, padding = 2, slot = { hAlign = "fill", vAlign = "fill" },
    })
    spec.strictBuild = true
    return RSUI:VerticalBox(spec)
end

-- Long settings/forms must remain operable at the minimum window size and at
-- enlarged font/UI scales. Use this root only for sequential content; pages
-- whose primary body is a ListView/TableView keep their own virtual scrolling.
-- `idOrSpec` is intentionally backward-compatible: simple pages may pass an id
-- string, while richer pages may override gap/padding without bypassing the
-- shared Design helper.
function D:ScrollablePageRoot(parent, idOrSpec)
    local spec = RootSpec(parent, idOrSpec, {
        orientation = "vertical", gap = 12, padding = 2, scrollStep = 2,
        scrollbar = true, reserveScrollbar = true, scrollbarWidth = 14, scrollbarGap = 4,
        slot = { hAlign = "fill", vAlign = "fill" },
    })
    spec.strictBuild = true
    return RSUI:ScrollBox(spec)
end

-- 维护（module-controls-diag-2）：页面通过此入口领取宿主已创建的总开关。
-- 原回调、ActionRunner引用、失败回滚继续使用同一实例；只迁移位置，不另造状态/Consumer。
-- 非PageHost直接构建（独立页面宿主）仍按spec创建，兼容现有隔离页面使用方式。
function D:ModuleToggleButton(spec)
    local host = S.UIV3 and S.UIV3.PageHost
    local context = host and type(host.GetBuildContext) == "function" and host:GetBuildContext() or nil
    local bar = context and context.controlBar
    if bar and bar.toggle then
        if type(spec.onClick) == "function" then bar.toggle.onClick, bar.toggle.spec.onClick = spec.onClick, spec.onClick end
        return bar.toggle
    end
    return RSUI:Button(spec)
end

function D:ModuleDiagnosticsButton(parent, id, width)
    -- 中文维护注释（2026-09-18，module-diagnostics-header-2）：所有业务页的诊断入口都必须
    -- 经过这个共享 helper。标准 PageHeader 自动调用；少数拥有自定义抬头（首页/战斗分析）的页面
    -- 只负责放置按钮，不得复制 Window:Open、Feature 归属或错误处理逻辑。这样未来诊断入口协议
    -- 变化只改 DesignSystem，不会在几十个页面里产生分叉。
    local pageHost = S.UIV3 and S.UIV3.PageHost or nil
    local buildContext = type(pageHost) == "table" and type(pageHost.GetBuildContext) == "function" and pageHost:GetBuildContext() or nil
    if buildContext and buildContext.controlBar then return buildContext.controlBar.diagnostics end
    local moduleId = type(buildContext) == "table" and tostring(buildContext.moduleId or "") or ""
    local route = type(buildContext) == "table" and tostring(buildContext.route or "") or ""
    if moduleId == "" or moduleId == "system_diagnostics" or route == "system.diagnostics" then return nil end
    return RSUI:Button({
        id = tostring(id or "module_diagnostics"), parent = parent, text = "诊断", compact = true,
        slot = { size = "fixed", width = tonumber(width) or 76 },
        onClick = function()
            -- Authority/生命周期：诊断只能观察。禁止通过按钮 InitializeFeature、SetEnabled、Acquire
            -- Consumer 或调用业务刷新；关闭/故障模块必须同样可以打开诊断窗口。窗口按点击时解析，
            -- 因 DesignSystem 的 TOC 顺序早于 Presentation widget，加载期不能缓存 nil。
            local window = S.UIV3 and S.UIV3.ModuleDiagnosticsWindowV3 or nil
            if type(window) ~= "table" or type(window.Open) ~= "function" then
                local diagnostics = S.DiagnosticsManager
                if type(diagnostics) == "table" and type(diagnostics.Error) == "function" then
                    diagnostics:Error("ui_v3", "MODULE_DIAGNOSTICS_WINDOW_UNAVAILABLE", "模块诊断窗口不可用", {
                        feature = moduleId, route = route, owner = "module_diagnostics_header",
                    })
                end
                return false, "模块诊断窗口不可用"
            end
            return window:Open(moduleId)
        end,
    })
end

function D:PageHeader(parent, id, title, subtitle, actionText, onAction)
    local block = RSUI:VerticalBox({ id = id, parent = parent, gap = 3, slot = { size = "auto", hAlign = "fill" } })
    local row = RSUI:HorizontalBox({ id = id .. "_row", parent = block, gap = 8, slot = { size = "fixed", height = 30, hAlign = "fill" } })
    Text(row, id .. "_title", title, 17, "accent", { size = "fill", fill = 1 }, "ellipsis")
    if actionText ~= nil and tostring(actionText) ~= "" then
        RSUI:Button({ id = id .. "_action", parent = row, text = actionText, compact = true, onClick = onAction, slot = { size = "fixed", width = 110 } })
    end
    self:ModuleDiagnosticsButton(row, id .. "_diagnostics", 76)
    if subtitle ~= nil and tostring(subtitle) ~= "" then
        Text(block, id .. "_subtitle", subtitle, 10, "muted", { size = "auto", hAlign = "fill" }, "wrap")
    end
    return block
end

function D:InfoCard(parent, spec)
    spec = type(spec) == "table" and spec or {}
    local id = tostring(spec.id or "v3_info_card")
    local card = RSUI:Border({
        id = id, parent = parent, variant = spec.variant or "card", padding = spec.padding or 10,
        slot = spec.slot or { size = "auto", hAlign = "fill" },
    })
    local stack = RSUI:VerticalBox({ id = id .. "_stack", parent = card, gap = 4 })
    local header = RSUI:HorizontalBox({ id = id .. "_header", parent = stack, gap = 8, slot = { size = "fixed", height = 24 } })
    local title = Text(header, id .. "_title", spec.title or "", spec.titleSize or 12, spec.titleTone or "default", { size = "fill", fill = 1 }, "ellipsis")
    local value = Text(header, id .. "_value", spec.value or "", spec.valueSize or 11, spec.valueTone or "accent", { size = "auto" }, "ellipsis")
    local detail = RSUI:Text({
        id = id .. "_detail", parent = stack, text = spec.detail or "", fontSize = spec.detailSize or 10,
        tone = spec.detailTone or "muted", overflow = "wrap", maxLines = math.max(1, tonumber(spec.detailMaxLines) or 4),
        slot = { size = "auto", hAlign = "fill" },
    })
    card.titleText, card.valueText, card.detailText = title, value, detail
    function card:SetData(data)
        data = type(data) == "table" and data or {}
        if data.title ~= nil then self.titleText:SetText(data.title) end
        if data.value ~= nil then self.valueText:SetText(data.value) end
        if data.detail ~= nil then self.detailText:SetText(data.detail) end
        return true
    end
    return card
end

function D:StatusRow(parent, id, label, value, tone)
    local row = RSUI:HorizontalBox({ id = id, parent = parent, gap = 8, slot = { size = "fixed", height = 25, hAlign = "fill" } })
    Text(row, id .. "_label", label or "", 10, "muted", { size = "fill", fill = 1 }, "ellipsis")
    local valueText = Text(row, id .. "_value", value or "", 10, tone or "default", { size = "auto" }, "ellipsis")
    row.valueText = valueText
    return row
end

-- Static "not migrated yet" placeholder only. Stateful empty/loading/error/
-- blocked notices belong to RSUI StateNotice (composite foundation), which owns
-- the shared status semantics; do not grow this placeholder into a second one.
function D:EmptyState(parent, id, title, detail)
    local card = RSUI:Border({ id = id, parent = parent, variant = "soft", padding = 14, slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    local stack = RSUI:VerticalBox({ id = id .. "_stack", parent = card, gap = 6, slot = { hAlign = "fill", vAlign = "fill" } })
    RSUI:Spacer({ id = id .. "_top", parent = stack, slot = { size = "fill", fill = 1 } })
    Text(stack, id .. "_title", title or "尚未迁移", 15, "accent", { size = "fixed", height = 26, hAlign = "fill" }, "ellipsis")
    Text(stack, id .. "_detail", detail or "", 10, "muted", { size = "auto", hAlign = "fill" }, "wrap")
    RSUI:Spacer({ id = id .. "_bottom", parent = stack, slot = { size = "fill", fill = 1 } })
    return card
end

-- Standard settings-page composition. These are thin Design-System entrypoints
-- over RSUI.SettingsFoundation; geometry remains owned by the existing RSUI
-- panels/templates and business state remains in Feature bindings.
function D:FeatureSettingsHeader(parent, spec)
    spec = RootSpec(parent, spec, {})
    return RSUI:CreateFeatureSettingsHeader(spec)
end

function D:SettingsToggleGrid(parent, spec)
    spec = RootSpec(parent, spec, {})
    return RSUI:CreateSettingsToggleGrid(spec)
end

function D:SettingsSection(parent, spec)
    spec = RootSpec(parent, spec, {})
    return RSUI:CreateSettingsSection(spec)
end

function D:SettingsStyleCardGrid(parent, spec)
    spec = RootSpec(parent, spec, {})
    return RSUI:CreateSettingsStyleCardGrid(spec)
end

function D:SettingsStyleCard(parent, spec)
    spec = RootSpec(parent, spec, {})
    return RSUI:CreateSettingsStyleCard(spec)
end

function D:SettingsDiagnostics(parent, spec)
    spec = RootSpec(parent, spec, {})
    return RSUI:CreateSettingsDiagnosticsDisclosure(spec)
end

function D:ResponsiveSettingRow(parent, spec)
    spec = RootSpec(parent, spec, {})
    return RSUI:CreateResponsiveSettingRow(spec)
end

function D:ResponsiveNumericSetting(parent, spec)
    spec = RootSpec(parent, spec, {})
    return RSUI:CreateResponsiveNumericSetting(spec)
end

function D:SettingsNumericSlider(parent, spec)
    spec = RootSpec(parent, spec, {})
    return RSUI:CreateSettingsNumericSlider(spec)
end

-- Exact numeric-setting contract. V3 numeric preferences always expose a real
-- NumericInput; sliders are optional accelerators and +/- step buttons are
-- disabled by default. Pages must not encode numeric choices as cycling buttons.
function D:NumericSetting(parent, spec)
    spec = type(spec) == "table" and spec or {}
    local nextSpec = {}
    for key, value in pairs(spec) do nextSpec[key] = value end
    nextSpec.parent = parent
    nextSpec.stepButtons = spec.stepButtons == true
    if spec.slider == nil then nextSpec.slider = true end

    -- NumericField owns its typography-aware desired height. Historical V3 pages
    -- used fixed 62px slots, which clipped the hint line as soon as UI/font scale
    -- increased. Preserve an explicit legacy height only as a minimum; Auto sizing
    -- lets Measure -> Arrange allocate the real label/control/hint requirement.
    local slot = {}
    for key, value in pairs(type(spec.slot) == "table" and spec.slot or {}) do slot[key] = value end
    if next(slot) == nil then slot = { size = "auto", hAlign = "fill" } end
    if spec.allowFixedHeight ~= true and tostring(slot.size or "auto"):lower() == "fixed" then
        local legacyHeight = tonumber(slot.height) or tonumber(spec.height)
        if legacyHeight ~= nil then slot.minHeight = math.max(tonumber(slot.minHeight) or 0, legacyHeight) end
        slot.height = nil
        slot.size = "auto"
    end
    if slot.hAlign == nil then slot.hAlign = "fill" end
    nextSpec.slot = slot
    return RSUI:NumericField(nextSpec)
end

-- Dense V3 settings row: label + slider + exact edit box on one line.  The
-- NumericField/Binding implementation is reused unchanged, so preview/commit,
-- validation and persistence retain the same single Authority.
function D:CompactNumericSetting(parent, spec)
    spec = type(spec) == "table" and spec or {}
    local nextSpec = {}
    for key, value in pairs(spec) do nextSpec[key] = value end
    nextSpec.parent = parent
    nextSpec.inline = true
    nextSpec.slider = spec.slider ~= false
    nextSpec.stepButtons = spec.stepButtons == true
    -- RU EditBox Enter delivery is not a verified capability.  Compact numeric
    -- settings therefore expose a visible Apply action by default; Enter/blur
    -- remain compatibility conveniences, not the only commit path.
    nextSpec.applyButton = spec.applyButton ~= false
    nextSpec.applyText = tostring(spec.applyText or "应用")
    nextSpec.applyButtonWidth = tonumber(spec.applyButtonWidth) or 40
    nextSpec.hint = spec.inlineHint == true and spec.hint or nil
    nextSpec.padding = tonumber(spec.padding) or 4
    nextSpec.labelFontSize = tonumber(spec.labelFontSize) or 9
    nextSpec.labelWidth = tonumber(spec.labelWidth) or 78
    nextSpec.inputWidth = tonumber(spec.inputWidth) or 74
    nextSpec.controlHeight = tonumber(spec.controlHeight) or 22
    nextSpec.minHeight = math.max(28, tonumber(spec.minHeight) or 30)
    local slot = {}
    for key, value in pairs(type(spec.slot) == "table" and spec.slot or {}) do slot[key] = value end
    if next(slot) == nil then slot = { size = "auto", minHeight = nextSpec.minHeight, hAlign = "fill" } end
    if slot.hAlign == nil then slot.hAlign = "fill" end
    nextSpec.slot = slot
    return RSUI:NumericField(nextSpec)
end
