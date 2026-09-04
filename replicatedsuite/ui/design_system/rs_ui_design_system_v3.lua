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

S.UIV3Design = { version = 6 }
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

function D:PageHeader(parent, id, title, subtitle, actionText, onAction)
    local block = RSUI:VerticalBox({ id = id, parent = parent, gap = 3, slot = { size = "auto", hAlign = "fill" } })
    local row = RSUI:HorizontalBox({ id = id .. "_row", parent = block, gap = 8, slot = { size = "fixed", height = 30, hAlign = "fill" } })
    Text(row, id .. "_title", title, 17, "accent", { size = "fill", fill = 1 }, "ellipsis")
    if actionText ~= nil and tostring(actionText) ~= "" then
        RSUI:Button({ id = id .. "_action", parent = row, text = actionText, compact = true, onClick = onAction, slot = { size = "fixed", width = 110 } })
    end
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
