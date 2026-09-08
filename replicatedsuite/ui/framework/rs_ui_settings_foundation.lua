------------------------------------------------------------------------
-- Replicated Suite - RSUI Settings Page Foundation v3
--
-- Standard composition layer for dense feature settings pages.  It owns no
-- business state and introduces no second layout authority: every surface is
-- built from existing RSUI Vertical/Horizontal/UniformGrid/FormRow/GroupBox/
-- CollapsibleGroup primitives and therefore inherits Measure/Arrange,
-- invalidation, build transactions and Native ownership fences.
--
-- Goals:
--   * consistent feature header / section / style-card / diagnostics hierarchy;
--   * width-driven 1/2-column grids without resolution-specific literals;
--   * responsive setting rows and numeric rows that stack instead of crushing;
--   * diagnostics hidden by default, but still available without a second page;
--   * zero Tick / OnUpdate / polling.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
if type(RSUI) ~= "table" or type(RSUI.LayoutUtil) ~= "table" then return end
local Tokens = S.UITokens or {}

local F = RSUI.SettingsFoundation or {}
F.version = 3
F.contractVersion = 3
F.responsiveContractVersion = 2
F.diagnosticsDisclosureContractVersion = 1
F.styleCardContractVersion = 3
F.compactToggleContractVersion = 1
F.scrollSafeCardContractVersion = 2
F.sectionHierarchyContractVersion = 1
F.numericSliderContractVersion = 1

local function Token(path, fallback)
    if type(Tokens.Number) == "function" then return Tokens:Number(path, fallback) end
    return tonumber(fallback) or 0
end

local function Copy(value)
    local out = {}
    for key, item in pairs(type(value) == "table" and value or {}) do out[key] = item end
    return out
end

local function Id(spec, suffix)
    return tostring(spec.id or "settings") .. tostring(suffix or "")
end

function F:ResolveColumns(width, minCellWidth, gap, maxColumns)
    width = math.max(0, tonumber(width) or 0)
    minCellWidth = math.max(1, tonumber(minCellWidth) or Token("settings.styleCardMinWidth", 280))
    gap = math.max(0, tonumber(gap) or Token("settings.gridGap", Token("spacing.sm", 8)))
    maxColumns = math.max(1, math.floor(tonumber(maxColumns) or 2))
    local columns = math.floor((width + gap) / (minCellWidth + gap))
    return math.max(1, math.min(maxColumns, columns))
end

function F:ResolveDensity(width)
    width = math.max(0, tonumber(width) or 0)
    local compact = Token("breakpoint.compact", 720)
    local regular = Token("breakpoint.regular", 980)
    if width < compact then return "compact" end
    if width < regular then return "regular" end
    return "wide"
end

function F:CreatePageRoot(spec)
    spec = type(spec) == "table" and spec or {}
    return RSUI:VerticalBox({
        id = Id(spec, "_settings_root"), parent = spec.parent,
        gap = tonumber(spec.gap) or Token("settings.sectionGap", Token("spacing.md", 12)),
        padding = spec.padding ~= nil and spec.padding or Token("settings.pagePadding", 0),
        slot = spec.slot or { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
end

function F:CreateHeader(spec)
    spec = type(spec) == "table" and spec or {}
    local root = RSUI:VerticalBox({
        id = Id(spec, "_header"), parent = spec.parent,
        gap = tonumber(spec.gap) or Token("settings.headerGap", Token("spacing.xs", 4)),
        slot = spec.slot or { size = "auto", hAlign = "fill" },
    })
    if root == nil then return nil, "settings_header_root_failed" end
    local top = RSUI:HorizontalBox({
        id = Id(spec, "_header_top"), parent = root,
        gap = tonumber(spec.actionGap) or Token("spacing.sm", 8),
        slot = { size = "auto", minHeight = tonumber(spec.minHeight) or Token("settings.headerMinHeight", 28), hAlign = "fill" },
    })
    if top == nil then return nil, "settings_header_top_failed" end
    local title = RSUI:Text({
        id = Id(spec, "_header_title"), parent = top,
        text = tostring(spec.title or ""), tone = spec.titleTone or "strong",
        fontSize = tonumber(spec.titleFontSize) or Token("font.title", 15),
        overflow = "ellipsis", slot = { size = "fill", fill = 1, hAlign = "fill" },
    })
    if title == nil then return nil, "settings_header_title_failed" end
    local status = nil
    if type(spec.status) == "table" then
        local statusSpec = Copy(spec.status)
        statusSpec.id = statusSpec.id or Id(spec, "_header_status")
        statusSpec.parent = top
        statusSpec.slot = statusSpec.slot or { size = "auto" }
        status = RSUI:StatusChip(statusSpec)
        if status == nil then return nil, "settings_header_status_failed" end
    end
    local actions = RSUI:HorizontalBox({
        id = Id(spec, "_header_actions"), parent = top,
        gap = tonumber(spec.actionGap) or Token("spacing.xs", 4),
        slot = { size = "auto" },
    })
    if actions == nil then return nil, "settings_header_actions_failed" end
    local description = nil
    if spec.description ~= nil and tostring(spec.description) ~= "" then
        description = RSUI:Text({
            id = Id(spec, "_header_description"), parent = root,
            text = tostring(spec.description), tone = spec.descriptionTone or "muted",
            fontSize = tonumber(spec.descriptionFontSize) or Token("font.caption", 9),
            overflow = "wrap", maxLines = tonumber(spec.descriptionMaxLines) or 2,
            slot = { size = "auto", hAlign = "fill" },
        })
        if description == nil then return nil, "settings_header_description_failed" end
    end
    local result = { kind = "SettingsFeatureHeader", root = root, top = top, title = title, description = description, status = status, actions = actions }
    function result:SetTitle(text) return self.title:SetText(tostring(text or "")) end
    function result:SetDescription(text)
        if self.description == nil then return false, "description_not_created" end
        return self.description:SetText(tostring(text or ""))
    end
    function result:SetStatus(state, text, tone)
        if self.status == nil or type(self.status.SetStatus) ~= "function" then return false, "status_not_created" end
        return self.status:SetStatus(state, text, tone)
    end
    return result
end

function F:CreateToggleGrid(spec)
    spec = type(spec) == "table" and spec or {}
    local grid = RSUI:UniformGrid({
        id = Id(spec, "_toggle_grid"), parent = spec.parent,
        minCellWidth = tonumber(spec.minCellWidth) or Token("settings.toggleMinWidth", 150),
        minCellHeight = tonumber(spec.minCellHeight) or Token("settings.toggleMinHeight", 26),
        maxColumns = math.max(1, math.floor(tonumber(spec.maxColumns) or 4)),
        gap = tonumber(spec.gap) or Token("settings.gridGap", Token("spacing.sm", 8)),
        slot = spec.slot or { size = "auto", hAlign = "fill" },
    })
    if grid == nil then return nil, "settings_toggle_grid_failed" end
    grid.settingsToggleCount = 0
    grid.settingsCompactToggles = spec.compact ~= false
    grid.settingsToggleWidth = math.max(72, tonumber(spec.toggleWidth) or Token("settings.toggleCompactWidth", 142))
    function grid:AddToggle(toggleSpec)
        toggleSpec = Copy(toggleSpec)
        self.settingsToggleCount = self.settingsToggleCount + 1
        toggleSpec.id = toggleSpec.id or (tostring(self.id) .. "_toggle_" .. tostring(self.settingsToggleCount))
        toggleSpec.parent = self
        if self.settingsCompactToggles == true then
            toggleSpec.width = tonumber(toggleSpec.width) or self.settingsToggleWidth
            -- UniformGrid owns row/column placement, but the Toggle itself must
            -- keep its compact desired width. `fill` here recreates the giant
            -- full-cell bars that SettingsFoundation was introduced to remove.
            toggleSpec.slot = toggleSpec.slot or { size = "auto", hAlign = "left", vAlign = "center" }
        else
            toggleSpec.slot = toggleSpec.slot or { size = "fill", fill = 1, hAlign = "fill" }
        end
        return RSUI:Toggle(toggleSpec)
    end
    return grid
end

function F:CreateSection(spec)
    spec = type(spec) == "table" and spec or {}
    -- Settings sections are hierarchy/layout containers, not nested cards.  The
    -- old card-inside-card composition produced bright double borders and spent
    -- scarce 768p height on decoration.  A flat title + optional divider keeps
    -- the visual hierarchy while StyleCards remain the actual grouped surfaces.
    local root = RSUI:VerticalBox({
        id = Id(spec, "_section"), parent = spec.parent,
        gap = tonumber(spec.gap) or Token("settings.sectionInnerGap", Token("spacing.xs", 4)),
        padding = spec.padding ~= nil and spec.padding or Token("settings.sectionFlatPadding", 0),
        slot = spec.slot or { size = "auto", hAlign = "fill" },
    })
    if root == nil then return nil, "settings_section_root_failed" end
    local title = nil
    if spec.title ~= nil and tostring(spec.title) ~= "" then
        title = RSUI:Text({
            id = Id(spec, "_section_title"), parent = root,
            text = tostring(spec.title), tone = spec.titleTone or "strong",
            fontSize = tonumber(spec.titleFontSize) or Token("font.section", 12),
            overflow = "ellipsis",
            slot = { size = "fixed", height = tonumber(spec.headerHeight) or Token("settings.sectionHeaderHeight", 22), hAlign = "fill", vAlign = "center" },
        })
        if title == nil then return nil, "settings_section_title_failed" end
    end
    local divider = nil
    if spec.divider ~= false then
        divider = RSUI:Divider({
            id = Id(spec, "_section_divider"), parent = root, soft = true,
            slot = { size = "fixed", height = 1, hAlign = "fill" },
        })
        if divider == nil then return nil, "settings_section_divider_failed" end
    end
    local content = RSUI:VerticalBox({
        id = Id(spec, "_section_content"), parent = root,
        gap = tonumber(spec.itemGap) or Token("settings.itemGap", Token("spacing.sm", 6)),
        slot = { size = "auto", hAlign = "fill" },
    })
    if content == nil then return nil, "settings_section_content_failed" end
    return { kind = "SettingsSection", root = root, title = title, divider = divider, content = content }
end

function F:CreateStyleCardGrid(spec)
    spec = type(spec) == "table" and spec or {}
    return RSUI:UniformGrid({
        id = Id(spec, "_style_grid"), parent = spec.parent,
        minCellWidth = tonumber(spec.minCellWidth) or Token("settings.styleCardMinWidth", 280),
        minCellHeight = tonumber(spec.minCellHeight) or Token("settings.styleCardMinHeight", 96),
        maxColumns = math.max(1, math.floor(tonumber(spec.maxColumns) or 2)),
        gap = tonumber(spec.gap) or Token("settings.gridGap", Token("spacing.sm", 8)),
        slot = spec.slot or { size = "auto", hAlign = "fill" },
    })
end

function F:CreateStyleCard(spec)
    spec = type(spec) == "table" and spec or {}
    local group = RSUI:GroupBox({
        id = Id(spec, "_style_card"), parent = spec.parent,
        title = tostring(spec.title or ""), tone = spec.tone or "strong",
        headerHeight = tonumber(spec.headerHeight) or Token("settings.styleCardHeaderHeight", 24),
        variant = spec.variant or "soft", gradient = spec.gradient == true,
        accentStrip = spec.accentStrip == true,
        padding = spec.padding ~= nil and spec.padding or Token("settings.styleCardPadding", Token("component.card.padding", 10)),
        gap = tonumber(spec.gap) or Token("settings.itemGap", Token("spacing.sm", 8)),
        slot = spec.slot or { size = "auto", minHeight = tonumber(spec.minHeight) or Token("settings.styleCardMinHeight", 96), hAlign = "fill" },
    })
    if group == nil then return nil, "settings_style_card_group_failed" end
    local content = RSUI:VerticalBox({
        id = Id(spec, "_style_card_content"), parent = group,
        gap = tonumber(spec.itemGap) or Token("settings.cardItemGap", Token("spacing.xs", 5)),
        slot = { size = "auto", hAlign = "fill" },
    })
    if content == nil then return nil, "settings_style_card_content_failed" end
    local result = { kind = "SettingsStyleCard", root = group, content = content }
    if spec.description ~= nil and tostring(spec.description) ~= "" then
        result.description = RSUI:Text({
            id = Id(spec, "_style_card_description"), parent = content,
            text = tostring(spec.description), tone = "muted", fontSize = Token("font.caption", 9),
            overflow = "wrap", maxLines = 2, slot = { size = "auto", hAlign = "fill" },
        })
    end
    return result
end

function F:CreateDiagnosticsDisclosure(spec)
    spec = type(spec) == "table" and spec or {}
    local group = RSUI:CollapsibleGroup({
        id = Id(spec, "_diagnostics"), parent = spec.parent,
        title = tostring(spec.title or "高级 / 诊断"), expanded = spec.expanded == true,
        variant = spec.variant or "soft", tone = spec.tone or "muted",
        accentStrip = spec.accentStrip == true,
        padding = spec.padding ~= nil and spec.padding or Token("settings.diagnosticsPadding", Token("component.card.padding", 10)),
        gap = tonumber(spec.gap) or Token("settings.itemGap", Token("spacing.sm", 8)),
        slot = spec.slot or { size = "auto", hAlign = "fill" },
        onExpandedChanged = spec.onExpandedChanged,
    })
    if group == nil then return nil, "settings_diagnostics_group_failed" end
    local content = RSUI:VerticalBox({
        id = Id(spec, "_diagnostics_content"), parent = group,
        gap = tonumber(spec.itemGap) or Token("settings.diagnosticsItemGap", Token("spacing.xs", 5)),
        slot = { size = "auto", hAlign = "fill" },
    })
    if content == nil then return nil, "settings_diagnostics_content_failed" end
    RSUI.metrics.settingsDiagnosticsDisclosuresCreated = (tonumber(RSUI.metrics.settingsDiagnosticsDisclosuresCreated) or 0) + 1
    local result = { kind = "SettingsDiagnosticsDisclosure", root = group, content = content }
    function result:SetExpanded(expanded) return self.root:SetExpanded(expanded == true, true) end
    function result:IsExpanded() return self.root.expanded == true end
    return result
end

function F:CreateSettingRow(spec)
    spec = type(spec) == "table" and spec or {}
    local row = RSUI:FormRow({
        id = Id(spec, "_setting_row"), parent = spec.parent,
        layout = spec.layout or "auto",
        collapseWidth = tonumber(spec.collapseWidth) or Token("settings.settingRowCollapseWidth", 360),
        labelShare = tonumber(spec.labelShare) or Token("settings.labelShare", 0.30),
        labelMinWidth = tonumber(spec.labelMinWidth) or Token("settings.labelMinWidth", 92),
        controlMinWidth = tonumber(spec.controlMinWidth) or Token("settings.controlMinWidth", 140),
        hintWidth = tonumber(spec.hintWidth) or 0,
        gap = tonumber(spec.gap) or Token("settings.settingRowGap", Token("spacing.sm", 8)),
        slot = spec.slot or { size = "auto", hAlign = "fill" },
    })
    if row == nil then return nil, "settings_row_failed" end
    local label = RSUI:Text({
        id = Id(spec, "_setting_label"), parent = row,
        text = tostring(spec.label or ""), tone = spec.labelTone or "default",
        fontSize = tonumber(spec.labelFontSize) or Token("font.body", 11),
        overflow = "ellipsis", slot = { size = "auto", hAlign = "left", vAlign = "center" },
    })
    if label == nil then return nil, "settings_row_label_failed" end
    local control = nil
    if type(spec.createControl) == "function" then
        local ok, value, err = xpcall(function() return spec.createControl(row) end, S.SafeTraceback)
        if ok ~= true then return nil, "settings_row_control_exception:" .. tostring(value) end
        control = value
        if control == nil then return nil, "settings_row_control_failed:" .. tostring(err or "unknown") end
    elseif spec.controlType ~= nil then
        local controlSpec = Copy(spec.controlSpec)
        controlSpec.id = controlSpec.id or Id(spec, "_setting_control")
        controlSpec.parent = row
        controlSpec.slot = controlSpec.slot or { size = "fill", fill = 1, hAlign = "fill", vAlign = "center" }
        control = RSUI:Create(tostring(spec.controlType), controlSpec)
        if control == nil then return nil, "settings_row_control_failed" end
    else
        return nil, "settings_row_control_required"
    end
    local hint = nil
    if spec.hint ~= nil and tostring(spec.hint) ~= "" then
        hint = RSUI:Text({
            id = Id(spec, "_setting_hint"), parent = row,
            text = tostring(spec.hint), tone = spec.hintTone or "muted",
            fontSize = tonumber(spec.hintFontSize) or Token("font.caption", 9),
            overflow = "wrap", maxLines = tonumber(spec.hintMaxLines) or 2,
            slot = { size = "auto", hAlign = "fill", vAlign = "center" },
        })
        if hint == nil then return nil, "settings_row_hint_failed" end
    end
    return { kind = "SettingsRow", root = row, label = label, control = control, hint = hint }
end

function F:CreateNumericSetting(spec)
    spec = type(spec) == "table" and spec or {}
    local fieldSpec = Copy(spec)
    fieldSpec.parent = spec.parent
    fieldSpec.id = tostring(spec.id or "settings_numeric")
    fieldSpec.inline = true
    fieldSpec.responsiveStack = spec.responsiveStack ~= false
    fieldSpec.stackBelow = tonumber(spec.stackBelow) or Token("settings.numericStackBelow", 250)
    fieldSpec.slider = spec.slider ~= false
    fieldSpec.stepButtons = spec.stepButtons == true
    fieldSpec.applyButton = spec.applyButton ~= false
    fieldSpec.applyText = tostring(spec.applyText or "应用")
    fieldSpec.applyButtonWidth = tonumber(spec.applyButtonWidth) or Token("settings.applyButtonWidth", 42)
    fieldSpec.padding = tonumber(spec.padding) or Token("settings.numericPadding", 4)
    fieldSpec.labelFontSize = tonumber(spec.labelFontSize) or Token("font.body", 10)
    fieldSpec.labelWidth = tonumber(spec.labelWidth) or Token("settings.numericLabelWidth", 92)
    fieldSpec.inputWidth = tonumber(spec.inputWidth) or Token("settings.numericInputWidth", 72)
    fieldSpec.controlHeight = tonumber(spec.controlHeight) or Token("size.inputH", 24)
    fieldSpec.minHeight = tonumber(spec.minHeight) or Token("settings.numericMinHeight", 32)
    return RSUI:NumericField(fieldSpec)
end

-- Explicit standard setting used by feature pages whenever the user should get
-- the full slider + exact edit box + Apply affordance.  This is intentionally a
-- thin policy wrapper over NumericField: Binding, adaptive range, draft fences
-- and persistence remain single-authority in NumericField/NumericRangeStore.
function F:CreateNumericSliderSetting(spec)
    spec = Copy(type(spec) == "table" and spec or {})
    spec.slider = true
    spec.applyButton = spec.applyButton ~= false
    if spec.responsiveStack == nil then spec.responsiveStack = true end
    if spec.adaptiveRange == nil and spec.fixedRange ~= true then spec.adaptiveRange = true end
    return self:CreateNumericSetting(spec)
end

function F:GetSnapshot()
    return {
        version = self.version,
        contractVersion = self.contractVersion,
        responsiveContractVersion = self.responsiveContractVersion,
        diagnosticsDisclosureContractVersion = self.diagnosticsDisclosureContractVersion,
        styleCardContractVersion = self.styleCardContractVersion,
        compactToggleContractVersion = self.compactToggleContractVersion,
        scrollSafeCardContractVersion = self.scrollSafeCardContractVersion,
        sectionHierarchyContractVersion = self.sectionHierarchyContractVersion,
        numericSliderContractVersion = self.numericSliderContractVersion,
        factories = {
            "CreatePageRoot", "CreateHeader", "CreateToggleGrid", "CreateSection",
            "CreateStyleCardGrid", "CreateStyleCard", "CreateDiagnosticsDisclosure",
            "CreateSettingRow", "CreateNumericSetting", "CreateNumericSliderSetting",
        },
    }
end

RSUI.SettingsFoundation = F
RSUI.SettingsFoundationContractVersion = F.contractVersion
RSUI.SettingsResponsiveContractVersion = F.responsiveContractVersion
RSUI.SettingsDiagnosticsDisclosureContractVersion = F.diagnosticsDisclosureContractVersion
RSUI.SettingsStyleCardContractVersion = F.styleCardContractVersion
RSUI.SettingsCompactToggleContractVersion = F.compactToggleContractVersion
RSUI.SettingsScrollSafeCardContractVersion = F.scrollSafeCardContractVersion
RSUI.SettingsSectionHierarchyContractVersion = F.sectionHierarchyContractVersion
RSUI.SettingsNumericSliderContractVersion = F.numericSliderContractVersion

function RSUI:CreateFeatureSettingsHeader(spec) return F:CreateHeader(spec) end
function RSUI:CreateSettingsToggleGrid(spec) return F:CreateToggleGrid(spec) end
function RSUI:CreateSettingsSection(spec) return F:CreateSection(spec) end
function RSUI:CreateSettingsStyleCardGrid(spec) return F:CreateStyleCardGrid(spec) end
function RSUI:CreateSettingsStyleCard(spec) return F:CreateStyleCard(spec) end
function RSUI:CreateSettingsDiagnosticsDisclosure(spec) return F:CreateDiagnosticsDisclosure(spec) end
function RSUI:CreateResponsiveSettingRow(spec) return F:CreateSettingRow(spec) end
function RSUI:CreateResponsiveNumericSetting(spec) return F:CreateNumericSetting(spec) end
function RSUI:CreateSettingsNumericSlider(spec) return F:CreateNumericSliderSetting(spec) end
