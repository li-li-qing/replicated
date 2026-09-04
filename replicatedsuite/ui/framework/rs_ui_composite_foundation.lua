------------------------------------------------------------------------
-- Replicated Suite - RSUI Reusable Composite Foundation v4
--
-- Foundation-only reusable components shared by multiple feature families.
-- No business facts, no persistence authority and no permanent Tick work.
--
-- Foundation generations:
--   * v1: StatusChip + PickerModel + stable bounded TreeModel/TreeView;
--   * v2: Tree stable identity, transactional mutation and bounded expansion;
--   * v3: SearchablePicker presentation over PickerModel with explicit-submit
--         RU-safe input semantics (Enter/search button; no guessed live keys);
--   * v4: IconPicker presentation over PickerModel + virtual TileView + Image.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI, RSUI = S.UI, S.RSUI
if type(UI) ~= "table" or type(RSUI) ~= "table" then return end
local U = RSUI.LayoutUtil
if type(U) ~= "table" or type(RSUI.ListView) ~= "function" then return end
local N, Pad, Measure, Arrange, Host = U.N, U.Pad, U.Measure, U.Arrange, U.Host
local Tokens = S.UITokens or {}

local function Token(path, fallback)
    if type(Tokens.Number) == "function" then return Tokens:Number(path, fallback) end
    return tonumber(fallback) or 0
end

local function Tone(name, fallback)
    if type(Tokens.Color) == "function" then return Tokens:Color(name, fallback) end
    return fallback
end

local function Copy(source)
    local out = {}
    for key, value in pairs(type(source) == "table" and source or {}) do out[key] = value end
    return out
end

local function Clamp(value, lo, hi)
    value = tonumber(value) or 0
    if lo ~= nil then value = math.max(value, tonumber(lo) or value) end
    if hi ~= nil then value = math.min(value, tonumber(hi) or value) end
    return value
end

------------------------------------------------------------------------
-- StatusChip
------------------------------------------------------------------------
local STATUS = {
    neutral = { tone = "muted", text = "状态" },
    muted = { tone = "muted", text = "状态" },
    info = { tone = "info", text = "信息" },
    pending = { tone = "accent", text = "处理中" },
    success = { tone = "success", text = "正常" },
    warning = { tone = "warning", text = "警告" },
    caution = { tone = "caution", text = "注意" },
    danger = { tone = "danger", text = "异常" },
    error = { tone = "danger", text = "失败" },
    blocked = { tone = "danger", text = "阻断" },
    unavailable = { tone = "muted", text = "不可用" },
}

RSUI.StatusChipContractVersion = 1

RSUI:RegisterTypeValidator("StatusChip", function(spec)
    local status = tostring(spec.status or "neutral"):lower()
    if STATUS[status] == nil and spec.tone == nil then return false, "status_chip_unknown_status:" .. status end
    local minW = tonumber(spec.minWidth)
    local maxW = tonumber(spec.maxWidth)
    if minW ~= nil and maxW ~= nil and minW > maxW then return false, "status_chip_invalid_width_range" end
    return true
end)

RSUI:RegisterType("StatusChip", function(spec)
    local c, err = Host("StatusChip", spec)
    if c == nil then return nil, err end
    c.padding = Pad(spec.padding or { left = 7, top = 2, right = 7, bottom = 2 })
    c.status = tostring(spec.status or "neutral"):lower()
    c.statusText = spec.text ~= nil and tostring(spec.text) or nil
    c.tone = tostring(spec.tone or (STATUS[c.status] and STATUS[c.status].tone) or "muted")
    c.alpha = Clamp(spec.alpha, 0, 1)
    if spec.alpha == nil then c.alpha = 0.26 end

    local background = nil
    if c.root ~= nil and type(c.root.CreateColorDrawable) == "function" then
        local color = Tone(c.tone, { 0.35, 0.40, 0.46, 1 }) or { 0.35, 0.40, 0.46, 1 }
        background = c.root:CreateColorDrawable(color[1] or 0.35, color[2] or 0.40, color[3] or 0.46, c.alpha, "background")
        if background ~= nil and type(background.AddAnchor) == "function" then
            background:AddAnchor("TOPLEFT", c.root, 0, 0)
            background:AddAnchor("BOTTOMRIGHT", c.root, 0, 0)
            background.rsUiOwner = c.owner
        end
    end
    c.background = background

    local label = RSUI:Text({
        id = tostring(spec.id) .. "_label",
        parent = c,
        text = "",
        tone = c.tone,
        fontSize = tonumber(spec.fontSize) or Token("font.caption", 9),
        overflow = "ellipsis",
        vAlign = "center",
        slot = { hAlign = "fill", vAlign = "fill" },
    })
    if label == nil then return nil, "status_chip_label_failed" end
    c.label = label

    local function ResolveText(self)
        if self.statusText ~= nil then return tostring(self.statusText) end
        local row = STATUS[self.status]
        return row and tostring(row.text or self.status) or tostring(self.status)
    end

    function c:SetStatus(status, text, tone)
        status = tostring(status or "neutral"):lower()
        if STATUS[status] == nil and tone == nil then status = "neutral" end
        self.status = status
        self.statusText = text ~= nil and tostring(text) or nil
        self.tone = tostring(tone or (STATUS[status] and STATUS[status].tone) or "muted")
        local color = Tone(self.tone, { 0.35, 0.40, 0.46, 1 }) or { 0.35, 0.40, 0.46, 1 }
        if self.background ~= nil then UI:SetColor(self.background, color[1], color[2], color[3], self.alpha, self.owner) end
        self.label:SetTone(self.tone)
        self.label:SetText(ResolveText(self))
        self:InvalidateMeasure("status_chip")
        RSUI.metrics.statusChipUpdates = (tonumber(RSUI.metrics.statusChipUpdates) or 0) + 1
        return true
    end

    function c:SetText(text)
        return self:SetStatus(self.status, text, self.tone)
    end

    function c:Measure(availableW, availableH)
        local p = self.padding
        local dw, dh = Measure(self.label, nil, availableH)
        local w = dw + p.left + p.right
        local h = math.max(Token("size.compactButtonH", 22), dh + p.top + p.bottom)
        w = Clamp(w, self.spec.minWidth or 42, self.spec.maxWidth)
        h = Clamp(h, self.spec.minHeight or 18, self.spec.maxHeight or 28)
        if availableW ~= nil and self.spec.allowOverflow ~= true then w = math.min(w, math.max(1, N(availableW, w))) end
        if availableH ~= nil and self.spec.allowOverflow ~= true then h = math.min(h, math.max(1, N(availableH, h))) end
        self.desiredWidth, self.desiredHeight, self.measureDirty = math.max(1, w), math.max(1, h), false
        return self.desiredWidth, self.desiredHeight
    end

    function c:Layout(x, y, width, height)
        width = math.max(1, N(width, self.desiredWidth or 42))
        height = math.max(1, N(height, self.desiredHeight or 20))
        self:SetBounds(x, y, width, height)
        local p = self.padding
        Arrange(self.label, p.left, p.top, math.max(1, width - p.left - p.right), math.max(1, height - p.top - p.bottom))
        return height
    end

    c:SetStatus(c.status, c.statusText, c.tone)
    return c
end)

------------------------------------------------------------------------
-- Status semantics authority + combined-state / detail-header composites (v5)
--
-- Resolves the long-standing "StatusChip 语义统一" contract item: Pending /
-- Success / Warning / Blocked and the Empty/Loading/Error/Blocked combined
-- states have ONE semantic authority here. Pages and features resolve their
-- status through RSUI:ResolveStatusSemantic instead of hardcoding tones or
-- building one-off label stacks. StateNotice and DetailHeader are the two
-- standard visual composites named by the RSUI/roadmap contracts; both stay
-- free of business facts, persistence and Tick work.
------------------------------------------------------------------------
RSUI.StatusSemanticsContractVersion = 1

local STATE_SEMANTICS = {
    empty = { tone = "muted", text = "暂无数据" },
    loading = { tone = "accent", text = "读取中" },
    pending = { tone = "accent", text = "处理中" },
    error = { tone = "danger", text = "读取失败" },
    blocked = { tone = "danger", text = "已阻断" },
    unavailable = { tone = "muted", text = "不可用" },
}

-- Single authority for status -> {tone, default text}. Unknown statuses
-- resolve to nil so callers can fail visible instead of guessing a color.
function RSUI:ResolveStatusSemantic(status)
    status = tostring(status or ""):lower()
    local row = STATE_SEMANTICS[status] or STATUS[status]
    if row == nil then return nil end
    return { status = status, tone = tostring(row.tone), text = tostring(row.text) }
end

RSUI.StateNoticeContractVersion = 1

-- StateNotice states are a superset of StatusChip statuses; project the state
-- onto the closest chip-legal status while keeping the notice tone.
local function ChipStatusForState(state)
    if state == "loading" or state == "pending" then return "pending" end
    if state == "error" or state == "blocked" then return "blocked" end
    return "neutral"
end

RSUI:RegisterTypeValidator("StateNotice", function(spec)
    if STATE_SEMANTICS[tostring(spec.state or "empty"):lower()] == nil then
        return false, "state_notice_unknown_state:" .. tostring(spec.state or "")
    end
    return true
end)

RSUI:RegisterType("StateNotice", function(spec)
    local c, err = Host("StateNotice", spec)
    if c == nil then return nil, err end
    c.gap = Token("spacing.sm", 6)
    c.state = tostring(spec.state or "empty"):lower()
    local semantic = STATE_SEMANTICS[c.state]

    c.chip = nil
    if spec.showChip ~= false then
        local chip, chipErr = RSUI:StatusChip({
            id = tostring(spec.id) .. "_chip",
            parent = c,
            status = ChipStatusForState(c.state),
            text = spec.statusText or semantic.text,
            tone = semantic.tone,
            fontSize = tonumber(spec.fontSize) or Token("font.caption", 9),
            slot = { size = "auto" },
        })
        if chip == nil then return nil, "state_notice_chip_failed: " .. tostring(chipErr) end
        c.chip = chip
    end

    local message, messageErr = RSUI:Text({
        id = tostring(spec.id) .. "_message",
        parent = c,
        text = spec.message ~= nil and tostring(spec.message) or semantic.text,
        tone = spec.messageTone or (c.state == "error" or c.state == "blocked") and "danger" or "default",
        fontSize = tonumber(spec.messageFontSize) or Token("font.body", 11),
        overflow = "ellipsis",
        slot = { hAlign = "fill" },
    })
    if message == nil then return nil, "state_notice_message_failed: " .. tostring(messageErr) end
    c.message = message

    c.hint = nil
    if spec.hint ~= nil then
        local hintText, hintErr = RSUI:Text({
            id = tostring(spec.id) .. "_hint",
            parent = c,
            text = tostring(spec.hint),
            tone = "muted",
            fontSize = Token("font.caption", 9),
            overflow = "wrap",
            maxLines = 2,
            slot = { hAlign = "fill" },
        })
        if hintText == nil then return nil, "state_notice_hint_failed: " .. tostring(hintErr) end
        c.hint = hintText
    end

    function c:SetState(state, message, hint)
        state = tostring(state or "empty"):lower()
        local nextSemantic = STATE_SEMANTICS[state]
        if nextSemantic == nil then return false, "state_notice_unknown_state:" .. state end
        self.state = state
        if self.chip ~= nil then
            self.chip:SetStatus(ChipStatusForState(state), nextSemantic.text, nextSemantic.tone)
        end
        self.message:SetText(message ~= nil and tostring(message) or nextSemantic.text)
        if self.hint ~= nil then
            if hint ~= nil then self.hint:SetText(tostring(hint)); self.hint:SetVisible(true)
            else self.hint:SetText(""); self.hint:SetVisible(false) end
        end
        self:InvalidateMeasure("state_notice_state")
        return true
    end

    function c:Measure(availableW, availableH)
        local chipW, chipH = 0, 0
        if self.chip ~= nil then chipW, chipH = Measure(self.chip, availableW, nil) end
        local msgW, msgH = Measure(self.message, availableW, nil)
        local hintW, hintH = 0, 0
        if self.hint ~= nil and self.hint.visible ~= false then hintW, hintH = Measure(self.hint, availableW, nil) end
        local rows = 1 + (self.hint ~= nil and self.hint.visible ~= false and 1 or 0)
        local w = math.max(chipW, msgW, hintW)
        local h = chipH + msgH + hintH + self.gap * (rows - 1) + (self.chip ~= nil and self.gap or 0)
        self.desiredWidth, self.desiredHeight = math.max(1, w), math.max(1, h)
        self.measureDirty = false
        return self.desiredWidth, self.desiredHeight
    end

    function c:Layout(x, y, width, height)
        width, height = math.max(1, N(width, self.desiredWidth or 1)), math.max(1, N(height, self.desiredHeight or 1))
        self:SetBounds(x, y, width, height)
        local cursor = y
        if self.chip ~= nil then
            local chipW, chipH = Measure(self.chip, width, nil)
            Arrange(self.chip, x, cursor, math.max(chipW, 1), math.max(chipH, 1))
            cursor = cursor + chipH + self.gap
        end
        local _, msgH = Measure(self.message, width, nil)
        Arrange(self.message, x, cursor, width, math.max(msgH, 1))
        cursor = cursor + msgH
        if self.hint ~= nil and self.hint.visible ~= false then
            local _, hintH = Measure(self.hint, width, nil)
            Arrange(self.hint, x, cursor + self.gap, width, math.max(hintH, 1))
        end
        return height
    end

    return c
end)

RSUI.DetailHeaderContractVersion = 1

RSUI:RegisterTypeValidator("DetailHeader", function(spec)
    local crumb = spec.crumb
    if crumb ~= nil and type(crumb) ~= "table" then return false, "detail_header_crumb_must_be_table" end
    if spec.title == nil and crumb == nil then return false, "detail_header_requires_title_or_crumb" end
    return true
end)

RSUI:RegisterType("DetailHeader", function(spec)
    local c, err = Host("DetailHeader", spec)
    if c == nil then return nil, err end
    c.gap = Token("spacing.sm", 6)
    local CRUMB_SEPARATOR = " › "
    local function JoinCrumb(crumb)
        local parts = {}
        for _, entry in ipairs(type(crumb) == "table" and crumb or {}) do
            parts[#parts + 1] = tostring(entry)
        end
        return table.concat(parts, CRUMB_SEPARATOR)
    end

    local crumbText, crumbErr = RSUI:Text({
        id = tostring(spec.id) .. "_crumb",
        parent = c,
        text = JoinCrumb(spec.crumb),
        tone = "muted",
        fontSize = Token("font.caption", 9),
        overflow = "ellipsis",
        slot = { hAlign = "fill" },
    })
    if crumbText == nil then return nil, "detail_header_crumb_failed: " .. tostring(crumbErr) end
    c.crumbText = crumbText

    c.titleText = RSUI:Text({
        id = tostring(spec.id) .. "_title",
        parent = c,
        text = tostring(spec.title or ""),
        tone = "strong",
        fontSize = tonumber(spec.titleFontSize) or 13,
        overflow = "ellipsis",
        slot = { hAlign = "fill" },
    })
    if c.titleText == nil then return nil, "detail_header_title_failed" end

    c.chip = nil
    if type(spec.status) == "table" then
        local chip, chipErr = RSUI:StatusChip({
            id = tostring(spec.id) .. "_status",
            parent = c,
            status = spec.status.status or "neutral",
            text = spec.status.text,
            tone = spec.status.tone,
            fontSize = Token("font.caption", 9),
            slot = { size = "auto" },
        })
        if chip == nil then return nil, "detail_header_chip_failed: " .. tostring(chipErr) end
        c.chip = chip
    end

    function c:SetCrumb(crumb)
        self.crumbText:SetText(JoinCrumb(crumb))
        self:InvalidateMeasure("detail_header_crumb")
        return true
    end

    function c:SetTitle(title)
        self.titleText:SetText(tostring(title or ""))
        self:InvalidateMeasure("detail_header_title")
        return true
    end

    function c:SetStatus(status, text, tone)
        if self.chip == nil then return false, "detail_header_no_status_chip" end
        return self.chip:SetStatus(status, text, tone)
    end

    function c:Measure(availableW, availableH)
        local crumbW, crumbH = Measure(self.crumbText, availableW, nil)
        local titleW, titleH = Measure(self.titleText, availableW, nil)
        local chipW, chipH = 0, 0
        if self.chip ~= nil then chipW, chipH = Measure(self.chip, availableW, nil) end
        local w = math.max(crumbW, titleW + (self.chip ~= nil and (chipW + self.gap) or 0))
        local h = crumbH + self.gap + math.max(titleH, chipH)
        self.desiredWidth, self.desiredHeight = math.max(1, w), math.max(1, h)
        self.measureDirty = false
        return self.desiredWidth, self.desiredHeight
    end

    function c:Layout(x, y, width, height)
        width, height = math.max(1, N(width, self.desiredWidth or 1)), math.max(1, N(height, self.desiredHeight or 1))
        self:SetBounds(x, y, width, height)
        local _, crumbH = Measure(self.crumbText, width, nil)
        Arrange(self.crumbText, x, y, width, math.max(crumbH, 1))
        local rowY = y + crumbH + self.gap
        local titleW, titleH = Measure(self.titleText, width, nil)
        local chipW, chipH = 0, 0
        if self.chip ~= nil then
            chipW, chipH = Measure(self.chip, width, nil)
            Arrange(self.chip, x + math.max(0, width - chipW), rowY + math.max(0, titleH - chipH) / 2, chipW, math.max(chipH, 1))
        end
        Arrange(self.titleText, x, rowY, math.max(1, width - (self.chip ~= nil and (chipW + self.gap) or 0)), math.max(titleH, 1))
        return height
    end

    return c
end)

------------------------------------------------------------------------
-- PickerModel: explicit-query, stable-key and bounded option projection.
--
-- SearchablePicker / IconPicker / domain pickers may share this model without
-- inventing per-page filtering state. It is deliberately UI-agnostic and does
-- not assume OnTextChanged, generic keyboard navigation or Tick polling.
------------------------------------------------------------------------
local PickerModel = { version = 1 }
PickerModel.__index = PickerModel
RSUI.PickerModelContractVersion = 1

local function PickerItemKey(model, item, index)
    if type(model.getKey) == "function" then
        local ok, value = pcall(model.getKey, item, index, model)
        if not ok then return nil, "picker_get_key_failed:" .. tostring(index) end
        if value == nil or tostring(value) == "" then return nil, "picker_key_required:" .. tostring(index) end
        return tostring(value), nil
    end
    if type(item) == "table" then
        local value = item.key or item.id or item.value
        if value ~= nil and tostring(value) ~= "" then return tostring(value), nil end
    end
    return nil, "picker_key_required:" .. tostring(index)
end

local function PickerItemText(model, item, key, index)
    if type(model.getText) == "function" then
        local ok, value = pcall(model.getText, item, key, index, model)
        if ok and value ~= nil then return tostring(value) end
    end
    if type(item) == "table" then
        local value = item.text or item.label or item.name or item.title or item.value
        if value ~= nil then return tostring(value) end
    end
    return tostring(key)
end

local function PickerSearchText(model, item, key, text, index)
    local value = nil
    if type(model.getSearchText) == "function" then
        local ok, result = pcall(model.getSearchText, item, key, text, index, model)
        if ok then value = result end
    elseif type(item) == "table" then
        value = item.searchText or item.search or item.keywords
    end
    local parts = { tostring(text or ""), tostring(key or "") }
    if type(value) == "table" then
        for _, part in ipairs(value) do parts[#parts + 1] = tostring(part or "") end
    elseif value ~= nil then
        parts[#parts + 1] = tostring(value)
    end
    return string.lower(table.concat(parts, " "))
end

local function PickerQueryTokens(query, maxTokens)
    query = tostring(query or "")
    query = query:match("^%s*(.-)%s*$") or ""
    local tokens = {}
    for token in string.gmatch(string.lower(query), "%S+") do
        tokens[#tokens + 1] = token
        if #tokens >= maxTokens then break end
    end
    return query, tokens
end

local function PickerMatches(searchText, tokens)
    for _, token in ipairs(tokens) do
        if string.find(searchText, token, 1, true) == nil then return false end
    end
    return true
end

local function BuildPickerProjection(model, items, query)
    if type(items) ~= "table" then return nil, "picker_items_required" end
    query = tostring(query or "")
    if #query > model.maxQueryBytes then return nil, "picker_query_too_long" end
    local normalizedQuery, tokens = PickerQueryTokens(query, model.maxTokens)
    local results, keyToItem = {}, {}
    local seen = {}
    local scanCount = math.min(#items, model.maxScan)
    local matchedCount = 0
    local resultTruncated = false

    for index = 1, scanCount do
        local item = items[index]
        local key, keyErr = PickerItemKey(model, item, index)
        if key == nil then return nil, keyErr end
        if seen[key] == true then return nil, "picker_duplicate_key:" .. key end
        seen[key] = true
        keyToItem[key] = item
        local text = PickerItemText(model, item, key, index)
        local searchText = PickerSearchText(model, item, key, text, index)
        if #tokens == 0 or PickerMatches(searchText, tokens) then
            matchedCount = matchedCount + 1
            if #results < model.maxResults then
                results[#results + 1] = { key = key, item = item, text = text, sourceIndex = index }
            else
                resultTruncated = true
            end
        end
    end

    return {
        query = normalizedQuery,
        results = results,
        keyToItem = keyToItem,
        scanCount = scanCount,
        matchedCount = matchedCount,
        scanTruncated = #items > scanCount,
        resultTruncated = resultTruncated,
    }, nil
end

local function CommitPickerProjection(model, projection, items)
    if items ~= nil then model.items = items end
    model.query = projection.query
    model.results = projection.results
    model.keyToItem = projection.keyToItem
    model.scanCount = projection.scanCount
    model.matchedCount = projection.matchedCount
    model.scanTruncated = projection.scanTruncated == true
    model.resultTruncated = projection.resultTruncated == true
    if model.selectedKey ~= nil and model.keyToItem[model.selectedKey] == nil then model.selectedKey = nil end
    model.revision = (tonumber(model.revision) or 0) + 1
    model.lastError = nil
    RSUI.metrics.pickerModelRebuilds = (tonumber(RSUI.metrics.pickerModelRebuilds) or 0) + 1
    return true
end

function PickerModel:New(spec)
    spec = type(spec) == "table" and spec or {}
    local model = setmetatable({
        items = type(spec.items) == "table" and spec.items or {},
        getKey = spec.getKey,
        getText = spec.getText,
        getSearchText = spec.getSearchText,
        maxScan = math.max(1, math.min(32768, math.floor(tonumber(spec.maxScan) or 8192))),
        maxResults = math.max(1, math.min(512, math.floor(tonumber(spec.maxResults) or 128))),
        maxTokens = math.max(1, math.min(16, math.floor(tonumber(spec.maxTokens) or 8))),
        maxQueryBytes = math.max(16, math.min(1024, math.floor(tonumber(spec.maxQueryBytes) or 256))),
        query = tostring(spec.query or ""),
        selectedKey = spec.selectedKey ~= nil and tostring(spec.selectedKey) or nil,
        results = {},
        keyToItem = {},
        revision = 0,
        selectionRevision = 0,
        lastError = nil,
        scanCount = 0,
        matchedCount = 0,
        scanTruncated = false,
        resultTruncated = false,
    }, self)
    local projection, err = BuildPickerProjection(model, model.items, model.query)
    if projection == nil then model.lastError = err else CommitPickerProjection(model, projection, nil) end
    return model
end

function PickerModel:SetItems(items)
    if type(items) ~= "table" then return false, "picker_items_required" end
    local projection, err = BuildPickerProjection(self, items, self.query)
    if projection == nil then self.lastError = err; return false, err end
    CommitPickerProjection(self, projection, items)
    return true
end

function PickerModel:SetQuery(query)
    query = tostring(query or "")
    if query == self.query then return false, nil end
    local projection, err = BuildPickerProjection(self, self.items, query)
    if projection == nil then self.lastError = err; return false, err end
    CommitPickerProjection(self, projection, nil)
    return true, nil
end

function PickerModel:GetQuery() return self.query end
function PickerModel:GetResults() return self.results end
function PickerModel:GetItem(key) return self.keyToItem[tostring(key or "")] end
function PickerModel:GetSelectedKey() return self.selectedKey end
function PickerModel:GetSelectedItem() return self.selectedKey and self.keyToItem[self.selectedKey] or nil end
function PickerModel:SetSelectedKey(key)
    if key == nil or tostring(key) == "" then
        if self.selectedKey == nil then return false, nil end
        self.selectedKey = nil
        self.selectionRevision = (tonumber(self.selectionRevision) or 0) + 1
        return true, nil
    end
    key = tostring(key)
    if self.keyToItem[key] == nil then return false, "picker_key_not_found_or_unscanned" end
    if self.selectedKey == key then return false, nil end
    self.selectedKey = key
    self.selectionRevision = (tonumber(self.selectionRevision) or 0) + 1
    return true, nil
end
function PickerModel:GetSnapshot()
    return {
        version = self.version,
        revision = self.revision,
        selectionRevision = self.selectionRevision,
        query = self.query,
        resultCount = #self.results,
        matchedCount = tonumber(self.matchedCount) or 0,
        scanCount = tonumber(self.scanCount) or 0,
        maxScan = self.maxScan,
        maxResults = self.maxResults,
        scanTruncated = self.scanTruncated == true,
        resultTruncated = self.resultTruncated == true,
        selectedKey = self.selectedKey,
        lastError = self.lastError,
    }
end

RSUI.PickerModel = PickerModel

------------------------------------------------------------------------
-- SearchablePicker v1
--
-- Explicit-submit Presentation above PickerModel. RU input evidence currently
-- validates Enter/EditEnter/LostFocus but not generic OnTextChanged/OnKeyDown,
-- therefore filtering happens ONLY on Submit() or the visible Search button.
-- The component is an embedded workbench surface, not an implicit popup.
------------------------------------------------------------------------
RSUI.SearchablePickerContractVersion = 1
RSUI:RegisterType("SearchablePicker", function(spec)
    local c, err = Host("SearchablePicker", spec)
    if c == nil then return nil, err end
    c.padding = Pad(spec.padding or 0)
    c.headerHeight = math.max(22, N(spec.headerHeight, Token("size.inputH", 24)))
    c.gap = math.max(0, N(spec.gap, Token("spacing.xs", 4)))
    c.model = type(spec.model) == "table" and spec.model or PickerModel:New({
        items = type(spec.items) == "table" and spec.items or {},
        query = spec.query,
        selectedKey = spec.selectedKey,
        getKey = spec.getKey,
        getText = spec.getText,
        getSearchText = spec.getSearchText,
        maxScan = spec.maxScan,
        maxResults = spec.maxResults,
        maxTokens = spec.maxTokens,
        maxQueryBytes = spec.maxQueryBytes,
    })
    if type(c.model) ~= "table" then return nil, "searchable_picker_model_failed" end
    for _, methodName in ipairs({ "GetQuery", "GetResults", "GetSnapshot", "SetQuery", "SetItems", "GetSelectedKey", "GetSelectedItem", "SetSelectedKey" }) do
        if type(c.model[methodName]) ~= "function" then return nil, "searchable_picker_model_contract:" .. tostring(methodName) end
    end

    local header = RSUI:HorizontalBox({
        id = tostring(spec.id) .. "_header",
        parent = c,
        gap = math.max(2, N(spec.headerGap, Token("spacing.xs", 4))),
        slot = { size = "fixed", height = c.headerHeight, hAlign = "fill" },
    })
    if header == nil then return nil, "searchable_picker_header_failed" end
    c.header = header

    local input = RSUI:TextInput({
        id = tostring(spec.id) .. "_query",
        parent = header,
        value = c.model:GetQuery(),
        maxLength = c.model.maxQueryBytes,
        submitOnLostFocus = false,
        allowEmpty = true,
        slot = { size = "fill", fill = 1, minWidth = 80, hAlign = "fill", vAlign = "fill" },
    })
    if input == nil then return nil, "searchable_picker_input_failed" end
    c.input = input

    local searchButton = RSUI:Button({
        id = tostring(spec.id) .. "_search",
        parent = header,
        text = tostring(spec.searchText or "搜索"),
        compact = true,
        slot = { size = "fixed", width = math.max(46, N(spec.searchButtonWidth, 58)), hAlign = "fill", vAlign = "fill" },
    })
    if searchButton == nil then return nil, "searchable_picker_search_button_failed" end
    c.searchButton = searchButton

    local clearButton = nil
    if spec.clearButton ~= false then
        clearButton = RSUI:Button({
            id = tostring(spec.id) .. "_clear",
            parent = header,
            text = tostring(spec.clearText or "清空"),
            compact = true,
            slot = { size = "fixed", width = math.max(40, N(spec.clearButtonWidth, 48)), hAlign = "fill", vAlign = "fill" },
        })
        if clearButton == nil then return nil, "searchable_picker_clear_button_failed" end
    end
    c.clearButton = clearButton

    local status = RSUI:StatusChip({
        id = tostring(spec.id) .. "_status",
        parent = header,
        status = "info",
        text = "0 项",
        minWidth = math.max(44, N(spec.statusWidth, 64)),
        maxWidth = math.max(64, N(spec.statusMaxWidth, 92)),
        slot = { size = "fixed", width = math.max(56, N(spec.statusWidth, 68)), hAlign = "fill", vAlign = "center" },
    })
    if status == nil then return nil, "searchable_picker_status_failed" end
    c.statusChip = status

    local list = RSUI:ListView({
        id = tostring(spec.id) .. "_results",
        parent = c,
        items = c.model:GetResults(),
        getKey = function(row) return type(row) == "table" and row.key or nil end,
        itemText = function(row) return type(row) == "table" and row.text or "" end,
        selectable = true,
        selectionMode = "single",
        rowHeight = math.max(20, N(spec.rowHeight, Token("size.rowH", 28))),
        desiredRows = math.max(2, math.min(20, math.floor(N(spec.desiredRows, 8)))),
        maxPoolSize = math.max(8, math.min(128, math.floor(N(spec.maxPoolSize, 64)))),
        scrollbar = spec.scrollbar ~= false,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    if list == nil then return nil, "searchable_picker_list_failed" end
    c.list = list

    local function FindResultIndex(self, key)
        key = key ~= nil and tostring(key) or nil
        if key == nil then return nil end
        for index, row in ipairs(self.model:GetResults()) do
            if tostring(row.key or "") == key then return index end
        end
        return nil
    end

    function c:RefreshResults(reason)
        local snap = self.model:GetSnapshot()
        self.list:SetItems(self.model:GetResults(), "picker:" .. tostring(snap.revision or 0))
        local selectedIndex = FindResultIndex(self, self.model:GetSelectedKey())
        if selectedIndex ~= nil then self.list:SetSelectedIndex(selectedIndex) else self.list:ClearSelection() end
        local count = tonumber(snap.resultCount) or 0
        if snap.lastError ~= nil then
            self.statusChip:SetStatus("error", "查询失败")
        elseif snap.resultTruncated == true or snap.scanTruncated == true then
            self.statusChip:SetStatus("warning", tostring(count) .. "+ 项")
        else
            self.statusChip:SetStatus("info", tostring(count) .. " 项")
        end
        if type(spec.onResultsChanged) == "function" then
            RSUI:Callback("rsui:" .. self.id .. ":results", spec.onResultsChanged, self.model:GetResults(), snap, tostring(reason or "refresh"), self)
        end
        return true
    end

    function c:SubmitQuery(query, source)
        if self.enabled == false then return false, "searchable_picker_disabled" end
        if query == nil then query = self.input:GetDraftValue() end
        query = tostring(query or "")
        local changed, queryErr = self.model:SetQuery(query)
        if queryErr ~= nil then
            self.statusChip:SetStatus("error", "查询失败")
            return false, queryErr
        end
        self.input:Render(self.model:GetQuery())
        self:RefreshResults(source or "query")
        RSUI.metrics.searchablePickerQueries = (tonumber(RSUI.metrics.searchablePickerQueries) or 0) + 1
        return changed == true or query == self.model:GetQuery(), nil
    end

    function c:SetItems(items)
        local ok, setErr = self.model:SetItems(items)
        if ok ~= true then self.statusChip:SetStatus("error", "数据错误"); return false, setErr end
        self:RefreshResults("items")
        return true, nil
    end

    function c:GetModel() return self.model end
    function c:GetQuery() return self.model:GetQuery() end
    function c:GetResults() return self.model:GetResults() end
    function c:GetSelectedKey() return self.model:GetSelectedKey() end
    function c:GetSelectedItem() return self.model:GetSelectedItem() end

    function c:SetSelectedKey(key, notify, source)
        local changed, selectErr = self.model:SetSelectedKey(key)
        if selectErr ~= nil then return false, selectErr end
        local index = FindResultIndex(self, self.model:GetSelectedKey())
        if index ~= nil then self.list:SetSelectedIndex(index); self.list:EnsureIndexVisible(index)
        else self.list:ClearSelection() end
        if changed == true then
            RSUI.metrics.searchablePickerSelections = (tonumber(RSUI.metrics.searchablePickerSelections) or 0) + 1
            if notify ~= false and type(spec.onChanged) == "function" then
                RSUI:Callback("rsui:" .. self.id .. ":changed", spec.onChanged, self.model:GetSelectedItem(), self.model:GetSelectedKey(), tostring(source or "api"), self)
            end
        end
        return changed, nil
    end

    function c:FocusSearch()
        if type(RSUI.Focus) ~= "table" or type(RSUI.Focus.Set) ~= "function" then return false, "focus_service_unavailable" end
        return RSUI.Focus:Set(self.input)
    end

    local baseSetEnabled = c.SetEnabled
    function c:SetEnabled(enabled)
        local state, accepted, detail = baseSetEnabled(self, enabled)
        if accepted ~= true then return state, false, detail end
        local children = {
            { self.input, "searchable_input" },
            { self.searchButton, "searchable_search" },
            { self.clearButton, "searchable_clear" },
            { self.list, "searchable_list" },
        }
        for _, entry in ipairs(children) do
            local childOk, childErr = self:EnsureChildEnabled(entry[1], self.enabled, entry[2])
            if childOk ~= true then return state, false, childErr end
        end
        return self.enabled, true, nil
    end

    function c:Measure(availableW, availableH)
        local p = self.padding
        local innerW = availableW and math.max(1, N(availableW, 1) - p.left - p.right) or nil
        local innerH = availableH and math.max(1, N(availableH, 1) - p.top - p.bottom) or nil
        local headerW, headerH = Measure(self.header, innerW, self.headerHeight)
        local listW, listH = Measure(self.list, innerW, innerH and math.max(1, innerH - self.headerHeight - self.gap) or nil)
        local width = math.max(headerW, listW) + p.left + p.right
        local height = math.max(self.headerHeight, headerH) + self.gap + listH + p.top + p.bottom
        if availableW ~= nil and self.spec.allowOverflow ~= true then width = math.min(width, math.max(1, N(availableW, width))) end
        if availableH ~= nil and self.spec.allowOverflow ~= true then height = math.min(height, math.max(1, N(availableH, height))) end
        self.desiredWidth, self.desiredHeight, self.measureDirty = width, height, false
        return width, height
    end

    function c:Layout(x, y, width, height)
        width, height = math.max(1, N(width, self.width or 1)), math.max(1, N(height, self.height or 1))
        self:SetBounds(x, y, width, height)
        local p = self.padding
        local innerW, innerH = math.max(1, width - p.left - p.right), math.max(1, height - p.top - p.bottom)
        Arrange(self.header, p.left, p.top, innerW, self.headerHeight)
        Arrange(self.list, p.left, p.top + self.headerHeight + self.gap, innerW, math.max(1, innerH - self.headerHeight - self.gap))
        return height
    end

    -- TextInput/Button closures read their component spec at event time, so the
    -- composite can install callbacks after all required children have built
    -- without binding duplicate Native handlers.
    input.spec.onSubmit = function(value) return c:SubmitQuery(value, "enter") end
    searchButton.spec.onClick = function() return c:SubmitQuery(c.input:GetDraftValue(), "button") end
    if clearButton ~= nil then
        clearButton.spec.onClick = function()
            UI:SetText(c.input.root, "", c.owner)
            return c:SubmitQuery("", "clear")
        end
    end
    list.onItemActivated = function(row)
        if type(row) ~= "table" then return false end
        local changed = c:SetSelectedKey(row.key, true, "result_click")
        return changed == true
    end

    c:SetEnabled(spec.enabled ~= false)
    c:RefreshResults("init")
    return c
end)

------------------------------------------------------------------------
-- IconPicker v1
--
-- Generic icon-selection Presentation above PickerModel. Icon paths are caller
-- projection data; the component neither resolves Skill/Buff/Item metadata nor
-- owns a second query/selection model. TileView keeps native tile count bounded.
------------------------------------------------------------------------
RSUI.IconPickerContractVersion = 1
RSUI:RegisterType("IconPicker", function(spec)
    if type(RSUI.TileView) ~= "function" or type(RSUI.Image) ~= "function" then return nil, "icon_picker_dependencies_missing" end
    local c, err = Host("IconPicker", spec)
    if c == nil then return nil, err end
    c.padding = Pad(spec.padding or 0)
    c.headerHeight = math.max(22, N(spec.headerHeight, Token("size.inputH", 24)))
    c.previewHeight = spec.showPreview == false and 0 or math.max(32, N(spec.previewHeight, 42))
    c.gap = math.max(0, N(spec.gap, Token("spacing.xs", 4)))
    c.tileWidth = math.max(44, N(spec.tileWidth, 68))
    c.tileHeight = math.max(44, N(spec.tileHeight, spec.showLabels == false and 60 or 76))
    c.iconSize = math.max(20, math.min(c.tileWidth - 8, N(spec.iconSize, 44)))
    c.model = type(spec.model) == "table" and spec.model or PickerModel:New({
        items = type(spec.items) == "table" and spec.items or {},
        query = spec.query,
        selectedKey = spec.selectedKey,
        getKey = spec.getKey,
        getText = spec.getText,
        getSearchText = spec.getSearchText,
        maxScan = spec.maxScan,
        maxResults = spec.maxResults or 256,
        maxTokens = spec.maxTokens,
        maxQueryBytes = spec.maxQueryBytes,
    })
    if type(c.model) ~= "table" then return nil, "icon_picker_model_failed" end
    for _, methodName in ipairs({ "GetQuery", "GetResults", "GetSnapshot", "SetQuery", "SetItems", "GetSelectedKey", "GetSelectedItem", "SetSelectedKey" }) do
        if type(c.model[methodName]) ~= "function" then return nil, "icon_picker_model_contract:" .. tostring(methodName) end
    end

    local function ResolveIcon(item, key, index)
        if type(spec.getIcon) == "function" then
            local ok, value = RSUI:Callback("rsui:" .. c.id .. ":get_icon", spec.getIcon, item, key, index, c)
            if ok and value ~= nil then return tostring(value) end
        end
        if type(item) == "table" then
            local value = item.icon or item.iconPath or item.texture or item.path
            if value ~= nil then return tostring(value) end
        end
        return ""
    end

    local header = RSUI:HorizontalBox({
        id = tostring(spec.id) .. "_header",
        parent = c,
        gap = math.max(2, N(spec.headerGap, Token("spacing.xs", 4))),
        slot = { size = "fixed", height = c.headerHeight, hAlign = "fill" },
    })
    if header == nil then return nil, "icon_picker_header_failed" end
    c.header = header

    local input = RSUI:TextInput({
        id = tostring(spec.id) .. "_query",
        parent = header,
        value = c.model:GetQuery(),
        maxLength = c.model.maxQueryBytes,
        submitOnLostFocus = false,
        allowEmpty = true,
        slot = { size = "fill", fill = 1, minWidth = 80, hAlign = "fill", vAlign = "fill" },
    })
    if input == nil then return nil, "icon_picker_input_failed" end
    c.input = input

    local searchButton = RSUI:Button({
        id = tostring(spec.id) .. "_search",
        parent = header,
        text = tostring(spec.searchText or "搜索"),
        compact = true,
        slot = { size = "fixed", width = math.max(46, N(spec.searchButtonWidth, 58)), hAlign = "fill", vAlign = "fill" },
    })
    if searchButton == nil then return nil, "icon_picker_search_button_failed" end
    c.searchButton = searchButton

    local clearButton = nil
    if spec.clearButton ~= false then
        clearButton = RSUI:Button({
            id = tostring(spec.id) .. "_clear",
            parent = header,
            text = tostring(spec.clearText or "清空"),
            compact = true,
            slot = { size = "fixed", width = math.max(40, N(spec.clearButtonWidth, 48)), hAlign = "fill", vAlign = "fill" },
        })
        if clearButton == nil then return nil, "icon_picker_clear_button_failed" end
    end
    c.clearButton = clearButton

    local status = RSUI:StatusChip({
        id = tostring(spec.id) .. "_status",
        parent = header,
        status = "info",
        text = "0 项",
        slot = { size = "fixed", width = math.max(56, N(spec.statusWidth, 68)), hAlign = "fill", vAlign = "center" },
    })
    if status == nil then return nil, "icon_picker_status_failed" end
    c.statusChip = status

    local tileView = nil
    tileView = RSUI:TileView({
        id = tostring(spec.id) .. "_tiles",
        parent = c,
        items = c.model:GetResults(),
        getKey = function(row) return type(row) == "table" and row.key or nil end,
        selectable = true,
        selectionMode = "single",
        tileWidth = c.tileWidth,
        tileHeight = c.tileHeight,
        minTileWidth = math.max(40, N(spec.minTileWidth, 52)),
        desiredColumns = math.max(2, math.min(10, math.floor(N(spec.desiredColumns, 6)))),
        maxColumns = math.max(2, math.min(16, math.floor(N(spec.maxColumns, 12)))),
        desiredRows = math.max(2, math.min(12, math.floor(N(spec.desiredRows, 4)))),
        overscanRows = math.max(0, math.min(3, math.floor(N(spec.overscanRows, 1)))),
        maxPoolSize = math.max(12, math.min(256, math.floor(N(spec.maxPoolSize, 120)))),
        scrollbar = spec.scrollbar ~= false,
        tileFactory = function(view, poolIndex)
            local tile
            tile = RSUI:Button({
                id = tostring(spec.id) .. "_tile_" .. tostring(poolIndex),
                parent = view,
                text = "",
                width = c.tileWidth,
                height = c.tileHeight,
                compact = true,
                onClick = function()
                    local index = tile and tile.state and tile.state.tileIndex or nil
                    if index ~= nil then return view:HandleTileClick(index) end
                    return false
                end,
            })
            if tile == nil then return nil end
            local image = RSUI:Image({
                id = tile.id .. "_image",
                parent = tile,
                path = "",
                width = c.iconSize,
                height = c.iconSize,
                pickable = false,
            })
            if image == nil then tile:Release(); return nil end
            local label = nil
            if spec.showLabels ~= false then
                label = RSUI:Text({
                    id = tile.id .. "_label",
                    parent = tile,
                    text = "",
                    fontSize = math.max(8, N(spec.labelFontSize, Token("font.caption", 9))),
                    overflow = "ellipsis",
                    hAlign = "center",
                    pickable = false,
                })
                if label == nil then tile:Release(); return nil end
            end
            tile.iconImage, tile.iconLabel = image, label
            local baseMeasure = tile.Measure
            local baseLayout = tile.Layout
            function tile:Measure(availableW, availableH)
                local w = math.max(40, math.min(N(availableW, c.tileWidth), c.tileWidth))
                local h = math.max(40, math.min(N(availableH, c.tileHeight), c.tileHeight))
                self.desiredWidth, self.desiredHeight, self.measureDirty = w, h, false
                return w, h
            end
            function tile:Layout(x, y, width, height)
                if type(baseLayout) == "function" then baseLayout(self, x, y, width, height) else self:SetBounds(x, y, width, height) end
                width, height = math.max(1, N(width, c.tileWidth)), math.max(1, N(height, c.tileHeight))
                local labelH = self.iconLabel ~= nil and math.max(14, N(spec.labelHeight, 18)) or 0
                local iconAvailH = math.max(1, height - labelH - 6)
                local iconSize = math.max(1, math.min(c.iconSize, width - 8, iconAvailH))
                Arrange(self.iconImage, math.max(2, (width - iconSize) * 0.5), 3, iconSize, iconSize)
                if self.iconLabel ~= nil then Arrange(self.iconLabel, 4, math.max(1, height - labelH - 2), math.max(1, width - 8), labelH) end
                return height
            end
            return tile
        end,
        bindTile = function(tile, row, index, key)
            if type(tile) ~= "table" or type(row) ~= "table" then return end
            local item = row.item
            if tile.iconImage ~= nil then tile.iconImage:SetImage(ResolveIcon(item, key, row.sourceIndex or index)) end
            if tile.iconLabel ~= nil then tile.iconLabel:SetText(tostring(row.text or key or "")) end
            RSUI.metrics.iconPickerTileBinds = (tonumber(RSUI.metrics.iconPickerTileBinds) or 0) + 1
        end,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    if tileView == nil then return nil, "icon_picker_tile_view_failed" end
    c.tileView = tileView

    local preview = nil
    if c.previewHeight > 0 then
        preview = RSUI:HorizontalBox({
            id = tostring(spec.id) .. "_preview",
            parent = c,
            gap = math.max(4, N(spec.previewGap, c.gap)),
            padding = spec.previewPadding or { left = 4, top = 3, right = 4, bottom = 3 },
        })
        if preview == nil then return nil, "icon_picker_preview_failed" end
        local previewIconSize = math.max(20, math.min(c.previewHeight - 6, N(spec.previewIconSize, 32)))
        local previewImage = RSUI:Image({
            id = tostring(spec.id) .. "_preview_image",
            parent = preview,
            path = "",
            width = previewIconSize,
            height = previewIconSize,
            pickable = false,
            slot = { size = "fixed", width = previewIconSize, hAlign = "center", vAlign = "center" },
        })
        if previewImage == nil then return nil, "icon_picker_preview_image_failed" end
        local previewText = RSUI:Text({
            id = tostring(spec.id) .. "_preview_text",
            parent = preview,
            text = tostring(spec.emptyPreviewText or "未选择图标"),
            overflow = "ellipsis",
            vAlign = "center",
            slot = { size = "fill", fill = 1, minWidth = 40, hAlign = "fill", vAlign = "center" },
        })
        if previewText == nil then return nil, "icon_picker_preview_text_failed" end
        c.preview, c.previewImage, c.previewText = preview, previewImage, previewText
    end

    local function FindResultIndex(self, key)
        key = key ~= nil and tostring(key) or nil
        if key == nil then return nil end
        for index, row in ipairs(self.model:GetResults()) do
            if tostring(row.key or "") == key then return index end
        end
        return nil
    end

    function c:RefreshPreview()
        if self.preview == nil then return false end
        local key = self.model:GetSelectedKey()
        local item = self.model:GetSelectedItem()
        if key == nil or item == nil then
            self.previewImage:SetImage("")
            self.previewText:SetText(tostring(spec.emptyPreviewText or "未选择图标"))
            return true
        end
        local rowIndex = FindResultIndex(self, key)
        local row = rowIndex and self.model:GetResults()[rowIndex] or nil
        self.previewImage:SetImage(ResolveIcon(item, key, row and row.sourceIndex or nil))
        self.previewText:SetText(row and tostring(row.text or key) or tostring(key))
        return true
    end

    function c:RefreshResults(reason)
        local snap = self.model:GetSnapshot()
        self.syncingSelection = true
        self.tileView:SetItems(self.model:GetResults(), "icon_picker:" .. tostring(snap.revision or 0))
        local selectedIndex = FindResultIndex(self, self.model:GetSelectedKey())
        if selectedIndex ~= nil then self.tileView:SetSelectedIndex(selectedIndex) else self.tileView:ClearSelection() end
        self.syncingSelection = false
        local count = tonumber(snap.resultCount) or 0
        if snap.lastError ~= nil then
            self.statusChip:SetStatus("error", "查询失败")
        elseif snap.resultTruncated == true or snap.scanTruncated == true then
            self.statusChip:SetStatus("warning", tostring(count) .. "+ 项")
        else
            self.statusChip:SetStatus("info", tostring(count) .. " 项")
        end
        self:RefreshPreview()
        if type(spec.onResultsChanged) == "function" then
            RSUI:Callback("rsui:" .. self.id .. ":results", spec.onResultsChanged, self.model:GetResults(), snap, tostring(reason or "refresh"), self)
        end
        return true
    end

    function c:SubmitQuery(query, source)
        if self.enabled == false then return false, "icon_picker_disabled" end
        if query == nil then query = self.input:GetDraftValue() end
        query = tostring(query or "")
        local changed, queryErr = self.model:SetQuery(query)
        if queryErr ~= nil then self.statusChip:SetStatus("error", "查询失败"); return false, queryErr end
        self.input:Render(self.model:GetQuery())
        self:RefreshResults(source or "query")
        RSUI.metrics.iconPickerQueries = (tonumber(RSUI.metrics.iconPickerQueries) or 0) + 1
        return changed == true or query == self.model:GetQuery(), nil
    end

    function c:SetItems(items)
        local ok, setErr = self.model:SetItems(items)
        if ok ~= true then self.statusChip:SetStatus("error", "数据错误"); return false, setErr end
        self:RefreshResults("items")
        return true, nil
    end

    function c:GetModel() return self.model end
    function c:GetQuery() return self.model:GetQuery() end
    function c:GetResults() return self.model:GetResults() end
    function c:GetSelectedKey() return self.model:GetSelectedKey() end
    function c:GetSelectedItem() return self.model:GetSelectedItem() end

    function c:SetSelectedKey(key, notify, source)
        local changed, selectErr = self.model:SetSelectedKey(key)
        if selectErr ~= nil then return false, selectErr end
        self.syncingSelection = true
        local index = FindResultIndex(self, self.model:GetSelectedKey())
        if index ~= nil then self.tileView:SetSelectedIndex(index); self.tileView:EnsureIndexVisible(index)
        else self.tileView:ClearSelection() end
        self.syncingSelection = false
        self:RefreshPreview()
        if changed == true then
            RSUI.metrics.iconPickerSelections = (tonumber(RSUI.metrics.iconPickerSelections) or 0) + 1
            if notify ~= false and type(spec.onChanged) == "function" then
                RSUI:Callback("rsui:" .. self.id .. ":changed", spec.onChanged, self.model:GetSelectedItem(), self.model:GetSelectedKey(), tostring(source or "api"), self)
            end
        end
        return changed, nil
    end

    function c:FocusSearch()
        if type(RSUI.Focus) ~= "table" or type(RSUI.Focus.Set) ~= "function" then return false, "focus_service_unavailable" end
        return RSUI.Focus:Set(self.input)
    end

    local baseSetEnabled = c.SetEnabled
    function c:SetEnabled(enabled)
        local state, accepted, detail = baseSetEnabled(self, enabled)
        if accepted ~= true then return state, false, detail end
        local children = {
            { self.input, "icon_picker_input" },
            { self.searchButton, "icon_picker_search" },
            { self.clearButton, "icon_picker_clear" },
            { self.tileView, "icon_picker_tiles" },
        }
        for _, entry in ipairs(children) do
            local childOk, childErr = self:EnsureChildEnabled(entry[1], self.enabled, entry[2])
            if childOk ~= true then return state, false, childErr end
        end
        return self.enabled, true, nil
    end

    function c:Measure(availableW, availableH)
        local p = self.padding
        local innerW = availableW and math.max(1, N(availableW, 1) - p.left - p.right) or nil
        local innerH = availableH and math.max(1, N(availableH, 1) - p.top - p.bottom) or nil
        local headerW, headerH = Measure(self.header, innerW, self.headerHeight)
        local reserved = self.headerHeight + self.gap + (self.preview ~= nil and (self.previewHeight + self.gap) or 0)
        local tileW, tileH = Measure(self.tileView, innerW, innerH and math.max(1, innerH - reserved) or nil)
        local previewW = 0
        if self.preview ~= nil then previewW = select(1, Measure(self.preview, innerW, self.previewHeight)) end
        local width = math.max(headerW, tileW, previewW) + p.left + p.right
        local height = math.max(self.headerHeight, headerH) + self.gap + tileH + (self.preview ~= nil and (self.gap + self.previewHeight) or 0) + p.top + p.bottom
        if availableW ~= nil and self.spec.allowOverflow ~= true then width = math.min(width, math.max(1, N(availableW, width))) end
        if availableH ~= nil and self.spec.allowOverflow ~= true then height = math.min(height, math.max(1, N(availableH, height))) end
        self.desiredWidth, self.desiredHeight, self.measureDirty = width, height, false
        return width, height
    end

    function c:Layout(x, y, width, height)
        width, height = math.max(1, N(width, self.width or 1)), math.max(1, N(height, self.height or 1))
        self:SetBounds(x, y, width, height)
        local p = self.padding
        local innerW, innerH = math.max(1, width - p.left - p.right), math.max(1, height - p.top - p.bottom)
        Arrange(self.header, p.left, p.top, innerW, self.headerHeight)
        local previewReserve = self.preview ~= nil and (self.previewHeight + self.gap) or 0
        local tileY = p.top + self.headerHeight + self.gap
        local tileH = math.max(1, innerH - self.headerHeight - self.gap - previewReserve)
        Arrange(self.tileView, p.left, tileY, innerW, tileH)
        if self.preview ~= nil then Arrange(self.preview, p.left, tileY + tileH + self.gap, innerW, self.previewHeight) end
        return height
    end

    input.spec.onSubmit = function(value) return c:SubmitQuery(value, "enter") end
    searchButton.spec.onClick = function() return c:SubmitQuery(c.input:GetDraftValue(), "button") end
    if clearButton ~= nil then
        clearButton.spec.onClick = function()
            UI:SetText(c.input.root, "", c.owner)
            return c:SubmitQuery("", "clear")
        end
    end
    tileView.onSelectionChanged = function(_, _, _, _, reason, key, selected)
        if c.syncingSelection == true or selected ~= true or key == nil then return false end
        return c:SetSelectedKey(key, true, reason or "tile_click")
    end

    c:SetEnabled(spec.enabled ~= false)
    c:RefreshResults("init")
    return c
end)

------------------------------------------------------------------------
-- TreeModel: bounded, key-stable and UI-agnostic.
------------------------------------------------------------------------
local TreeModel = { version = 2 }
TreeModel.__index = TreeModel

-- Tree mutations are staged and validated before commit.  Failed SetNodes /
-- expansion operations may update lastError for diagnostics, but must not
-- mutate rows/maps/expansion/revision or leave a half-applied projection.
RSUI.TreeMutationTransactionContractVersion = 2
-- Node identity is a semantic contract, not a visual-row convenience.  A tree
-- must provide node.key / node.id or getKey(); index-path fallback is forbidden
-- because insert/reorder operations would silently move expansion/selection to
-- a different entity.
RSUI.TreeStableIdentityContractVersion = 1
-- Expansion overrides are tri-state (true/false/nil) and hard-bounded so a
-- long-lived tree receiving changing datasets cannot accumulate stale keys
-- without limit.
RSUI.TreeExpansionStateBoundContractVersion = 1

local function TreeNodeKey(model, node, path)
    if type(model.getKey) == "function" then
        local ok, value = pcall(model.getKey, node, path, model)
        if not ok then return nil, "tree_get_key_failed:" .. tostring(path) end
        if value == nil or tostring(value) == "" then return nil, "tree_key_required:" .. tostring(path) end
        return tostring(value), nil
    end
    if type(node) == "table" then
        local value = node.key or node.id
        if value ~= nil and tostring(value) ~= "" then return tostring(value), nil end
    end
    return nil, "tree_key_required:" .. tostring(path)
end

local function TreeNodeChildren(model, node, key)
    if type(model.getChildren) == "function" then
        local ok, value = pcall(model.getChildren, node, model)
        if not ok then return nil, "tree_get_children_failed:" .. tostring(key or "?") end
        if value == nil then return {}, nil end
        if type(value) ~= "table" then return nil, "tree_children_must_be_table:" .. tostring(key or "?") end
        return value, nil
    end
    if type(node) == "table" and node.children ~= nil and type(node.children) ~= "table" then
        return nil, "tree_children_must_be_table:" .. tostring(key or "?")
    end
    return type(node) == "table" and type(node.children) == "table" and node.children or {}, nil
end

local function TreeNodeText(model, node, key)
    if type(model.getText) == "function" then
        local ok, value = pcall(model.getText, node, key, model)
        if ok and value ~= nil then return tostring(value) end
    end
    if type(node) == "table" then
        local value = node.text or node.label or node.name or node.title
        if value ~= nil then return tostring(value) end
    end
    return tostring(key)
end

local function BuildTreeProjection(model, nodes, expanded)
    local rows, keyToNode, keyToRow = {}, {}, {}
    local seen = {}
    local roots = type(nodes) == "table" and nodes or {}
    local nextExpanded = Copy(expanded)

    -- Frame-cursor DFS keeps temporary memory bounded by traversal depth rather
    -- than by sibling count. Every frame stores only an array reference + next
    -- index. Visible output remains hard-bounded by maxNodes.
    local frames = {}
    if #roots > 0 then
        frames[1] = { nodes = roots, index = 1, depth = 0, parentKey = nil, pathPrefix = "" }
    end
    local peakFrames = #frames
    local budgetCut = false

    while #frames > 0 and #rows < model.maxNodes do
        local frame = frames[#frames]
        if frame.index > #frame.nodes then
            frames[#frames] = nil
        else
            local nodeIndex = frame.index
            frame.index = nodeIndex + 1
            local node = frame.nodes[nodeIndex]
            local path = frame.pathPrefix .. tostring(nodeIndex)
            local key, keyErr = TreeNodeKey(model, node, path)
            if key == nil then return nil, keyErr end
            if seen[key] == true then return nil, "tree_duplicate_key:" .. key end
            seen[key] = true

            local children, childErr = TreeNodeChildren(model, node, key)
            if children == nil then return nil, childErr end
            local hasChildren = #children > 0
            if nextExpanded[key] == nil and frame.depth < model.defaultExpandedDepth and hasChildren then
                nextExpanded[key] = true
            end
            local isExpanded = hasChildren and nextExpanded[key] == true
            local row = {
                key = key,
                node = node,
                text = TreeNodeText(model, node, key),
                depth = frame.depth,
                parentKey = frame.parentKey,
                hasChildren = hasChildren,
                expanded = isExpanded,
                childCount = #children,
            }
            rows[#rows + 1] = row
            keyToNode[key], keyToRow[key] = node, #rows

            if isExpanded then
                if #rows < model.maxNodes then
                    frames[#frames + 1] = {
                        nodes = children,
                        index = 1,
                        depth = frame.depth + 1,
                        parentKey = key,
                        pathPrefix = path .. "/",
                    }
                    if #frames > peakFrames then peakFrames = #frames end
                elseif #children > 0 then
                    budgetCut = true
                end
            end
        end
    end

    local truncated = budgetCut
    if #rows >= model.maxNodes and truncated ~= true then
        for index = #frames, 1, -1 do
            local frame = frames[index]
            if type(frame) == "table" and frame.index <= #frame.nodes then truncated = true; break end
        end
    end

    return {
        rows = rows,
        keyToNode = keyToNode,
        keyToRow = keyToRow,
        expanded = nextExpanded,
        truncated = truncated,
        peakTraversalFrames = peakFrames,
    }, nil
end

local function BoundTreeExpansionState(model, expanded, visibleKeys)
    local count = 0
    for _ in pairs(type(expanded) == "table" and expanded or {}) do count = count + 1 end
    if count <= model.maxExpansionState then return expanded, false, count end

    local out, kept = {}, 0
    -- Preserve currently visible overrides first; they are the state the player
    -- can actually observe. Hidden/stale keys are best-effort once the hard cap
    -- is reached.
    for key in pairs(type(visibleKeys) == "table" and visibleKeys or {}) do
        local value = expanded[key]
        if value ~= nil and kept < model.maxExpansionState then
            out[key] = value
            kept = kept + 1
        end
    end
    if kept < model.maxExpansionState then
        for key, value in pairs(expanded) do
            if out[key] == nil and kept < model.maxExpansionState then
                out[key] = value
                kept = kept + 1
            end
        end
    end
    RSUI.metrics.treeExpansionStatePrunes = (tonumber(RSUI.metrics.treeExpansionStatePrunes) or 0) + 1
    return out, true, kept
end

local function CommitTreeProjection(model, projection, nodes, expandAllTruncated)
    if nodes ~= nil then model.nodes = nodes end
    model.rows = projection.rows
    model.keyToNode = projection.keyToNode
    model.keyToRow = projection.keyToRow
    local boundedExpanded, expansionStatePruned, expansionStateCount = BoundTreeExpansionState(model, projection.expanded, projection.keyToNode)
    model.expanded = boundedExpanded
    model.expansionStatePruned = expansionStatePruned == true
    model.expansionStateCount = tonumber(expansionStateCount) or 0
    model.truncated = projection.truncated == true
    model.peakTraversalFrames = tonumber(projection.peakTraversalFrames) or 0
    if expandAllTruncated ~= nil then model.expandAllTruncated = expandAllTruncated == true end
    model.revision = (tonumber(model.revision) or 0) + 1
    model.lastError = nil
    RSUI.metrics.treeModelRebuilds = (tonumber(RSUI.metrics.treeModelRebuilds) or 0) + 1
    return true
end

function TreeModel:New(spec)
    spec = type(spec) == "table" and spec or {}
    local maxNodes = math.max(1, math.min(16384, math.floor(tonumber(spec.maxNodes) or 4096)))
    local maxExpansionState = math.max(1, math.min(32768, math.floor(tonumber(spec.maxExpansionState) or math.min(32768, maxNodes * 2))))
    local model = setmetatable({
        nodes = type(spec.nodes) == "table" and spec.nodes or {},
        getKey = spec.getKey,
        getChildren = spec.getChildren,
        getText = spec.getText,
        maxNodes = maxNodes,
        maxExpansionState = maxExpansionState,
        defaultExpandedDepth = math.max(0, math.min(32, math.floor(tonumber(spec.defaultExpandedDepth) or 0))),
        expanded = {},
        rows = {},
        keyToNode = {},
        keyToRow = {},
        revision = 0,
        lastError = nil,
        truncated = false,
        expandAllTruncated = false,
        expansionStatePruned = false,
        expansionStateCount = 0,
    }, self)
    for key, value in pairs(type(spec.expandedKeys) == "table" and spec.expandedKeys or {}) do
        if value == true or value == false then model.expanded[tostring(key)] = value end
    end
    local ok, err = model:Rebuild()
    if ok ~= true then model.lastError = err end
    return model
end

function TreeModel:Rebuild()
    local projection, err = BuildTreeProjection(self, self.nodes, self.expanded)
    if projection == nil then self.lastError = err; return false, err end
    return CommitTreeProjection(self, projection, nil, nil)
end

function TreeModel:SetNodes(nodes)
    if type(nodes) ~= "table" then return false, "tree_nodes_required" end
    local projection, err = BuildTreeProjection(self, nodes, self.expanded)
    if projection == nil then self.lastError = err; return false, err end
    CommitTreeProjection(self, projection, nodes, nil)
    return true
end

function TreeModel:IsExpanded(key) return self.expanded[tostring(key or "")] == true end
function TreeModel:SetExpanded(key, expanded)
    key = tostring(key or "")
    if key == "" or self.keyToNode[key] == nil then return false, "tree_key_not_found" end
    local rowIndex = self.keyToRow[key]
    local row = rowIndex and self.rows[rowIndex] or nil
    if type(row) ~= "table" or row.hasChildren ~= true then return false, "tree_key_has_no_children" end
    local nextValue = expanded == true
    if self:IsExpanded(key) == nextValue then return false, nil end

    local nextExpanded = Copy(self.expanded)
    if nextValue then nextExpanded[key] = true else nextExpanded[key] = false end
    local projection, err = BuildTreeProjection(self, self.nodes, nextExpanded)
    if projection == nil then self.lastError = err; return false, err end
    CommitTreeProjection(self, projection, nil, nil)
    RSUI.metrics.treeExpansionChanges = (tonumber(RSUI.metrics.treeExpansionChanges) or 0) + 1
    return true
end
function TreeModel:ToggleExpanded(key) return self:SetExpanded(key, not self:IsExpanded(key)) end

function TreeModel:ExpandAll()
    local nextExpanded = Copy(self.expanded)
    local changed = false
    local roots = type(self.nodes) == "table" and self.nodes or {}
    local frames = {}
    if #roots > 0 then frames[1] = { nodes = roots, index = 1, pathPrefix = "" } end
    local visited, budgetCut = 0, false
    local seen = {}

    while #frames > 0 and visited < self.maxNodes do
        local frame = frames[#frames]
        if frame.index > #frame.nodes then
            frames[#frames] = nil
        else
            local nodeIndex = frame.index
            frame.index = nodeIndex + 1
            local node = frame.nodes[nodeIndex]
            local path = frame.pathPrefix .. tostring(nodeIndex)
            visited = visited + 1
            local key, keyErr = TreeNodeKey(self, node, path)
            if key == nil then self.lastError = keyErr; return false, keyErr end
            if seen[key] == true then
                local err = "tree_duplicate_key:" .. key
                self.lastError = err
                return false, err
            end
            seen[key] = true
            local children, childErr = TreeNodeChildren(self, node, key)
            if children == nil then self.lastError = childErr; return false, childErr end
            if #children > 0 then
                if nextExpanded[key] ~= true then nextExpanded[key] = true; changed = true end
                if visited < self.maxNodes then
                    frames[#frames + 1] = { nodes = children, index = 1, pathPrefix = path .. "/" }
                else
                    budgetCut = true
                end
            end
        end
    end

    local expandAllTruncated = budgetCut
    if visited >= self.maxNodes and expandAllTruncated ~= true then
        for index = #frames, 1, -1 do
            local frame = frames[index]
            if type(frame) == "table" and frame.index <= #frame.nodes then expandAllTruncated = true; break end
        end
    end
    if not changed then
        self.expandAllTruncated = expandAllTruncated
        self.lastError = nil
        return false, nil
    end

    local projection, err = BuildTreeProjection(self, self.nodes, nextExpanded)
    if projection == nil then self.lastError = err; return false, err end
    CommitTreeProjection(self, projection, nil, expandAllTruncated)
    RSUI.metrics.treeExpansionChanges = (tonumber(RSUI.metrics.treeExpansionChanges) or 0) + 1
    return true, nil
end

function TreeModel:CollapseAll()
    local nextExpanded = Copy(self.expanded)
    local changed = false
    for key, value in pairs(nextExpanded) do
        if value == true then nextExpanded[key] = false; changed = true end
    end
    if not changed then self.lastError = nil; return false, nil end
    local projection, err = BuildTreeProjection(self, self.nodes, nextExpanded)
    if projection == nil then self.lastError = err; return false, err end
    CommitTreeProjection(self, projection, nil, false)
    RSUI.metrics.treeExpansionChanges = (tonumber(RSUI.metrics.treeExpansionChanges) or 0) + 1
    return true, nil
end
function TreeModel:GetRows() return self.rows end
function TreeModel:GetNode(key) return self.keyToNode[tostring(key or "")] end
function TreeModel:GetRowIndex(key) return self.keyToRow[tostring(key or "")] end
function TreeModel:GetSnapshot()
    local expandedCount, collapsedOverrideCount, expansionStateCount = 0, 0, 0
    for _, value in pairs(self.expanded) do
        expansionStateCount = expansionStateCount + 1
        if value == true then expandedCount = expandedCount + 1 elseif value == false then collapsedOverrideCount = collapsedOverrideCount + 1 end
    end
    return {
        version = self.version, rowCount = #self.rows, expandedCount = expandedCount,
        collapsedOverrideCount = collapsedOverrideCount, expansionStateCount = expansionStateCount,
        maxExpansionState = self.maxExpansionState, expansionStatePruned = self.expansionStatePruned == true,
        revision = self.revision, maxNodes = self.maxNodes, truncated = self.truncated == true,
        peakTraversalFrames = tonumber(self.peakTraversalFrames) or 0,
        expandAllTruncated = self.expandAllTruncated == true,
        stableIdentityContract = tonumber(RSUI.TreeStableIdentityContractVersion) or 0,
        mutationTransactionContract = tonumber(RSUI.TreeMutationTransactionContractVersion) or 0,
        expansionStateBoundContract = tonumber(RSUI.TreeExpansionStateBoundContractVersion) or 0,
        lastError = self.lastError,
    }
end

RSUI.TreeModel = TreeModel
RSUI.TreeViewContractVersion = 1

RSUI:RegisterTypeValidator("TreeView", function(spec)
    if spec.nodes ~= nil and type(spec.nodes) ~= "table" then return false, "tree_nodes_must_be_table" end
    local maxNodes = tonumber(spec.maxNodes)
    if maxNodes ~= nil and (maxNodes < 1 or maxNodes > 16384) then return false, "tree_max_nodes_out_of_range" end
    return true
end)

RSUI:RegisterType("TreeView", function(spec)
    local c, err = Host("TreeView", spec)
    if c == nil then return nil, err end
    c.indentWidth = math.max(8, math.min(40, tonumber(spec.indentWidth) or 16))
    c.chevronWidth = math.max(16, math.min(32, tonumber(spec.chevronWidth) or 20))
    c.model = TreeModel:New(spec)
    if c.model.lastError ~= nil then return nil, c.model.lastError end
    c.onExpansionChanged = spec.onExpansionChanged
    c.onSelectionChanged = spec.onSelectionChanged
    c.onItemActivated = spec.onItemActivated

    local selection = spec.selectionModel
    if selection == nil and type(RSUI.CreateSelectionModel) == "function" then selection = RSUI:CreateSelectionModel({ id = tostring(spec.id) .. "_selection", mode = "single" }) end
    c.selectionModel = selection

    local function RefreshSelectionVisuals(tree)
        if tree.list == nil then return end
        local first, last = tree.list:GetVisibleRange()
        for index = tonumber(first) or 0, tonumber(last) or -1 do
            local row = tree.list:GetRowForIndex(index)
            if type(row) == "table" and type(row.treeLabel) == "table" then
                row.treeLabel:SetSelected(tree.list:IsItemSelected(index))
            end
        end
    end

    local list = RSUI:ListView({
        id = tostring(spec.id) .. "_list",
        parent = c,
        items = c.model:GetRows(),
        dataRevision = "tree:" .. tostring(c.model.revision),
        rowHeight = math.max(20, tonumber(spec.rowHeight) or Token("size.compactRowH", 23)),
        rowGap = math.max(0, tonumber(spec.rowGap) or 1),
        desiredRows = math.max(1, math.min(32, math.floor(tonumber(spec.desiredRows) or 10))),
        maxPoolSize = math.max(4, math.min(256, math.floor(tonumber(spec.maxPoolSize) or 96))),
        overscan = math.max(0, math.min(8, math.floor(tonumber(spec.overscan) or 1))),
        selectable = true,
        selectionModel = selection,
        overlayScrollbar = spec.overlayScrollbar == true,
        getKey = function(item) return item and item.key end,
        rowFactory = function(view, poolIndex)
            local row = RSUI:HorizontalBox({
                id = tostring(spec.id) .. "_row_" .. tostring(poolIndex),
                parent = view,
                gap = 2,
                padding = 0,
            })
            if row == nil then return nil end
            local indent = RSUI:Spacer({
                id = tostring(spec.id) .. "_row_indent_" .. tostring(poolIndex),
                parent = row,
                width = 0,
                height = 1,
                slot = { size = "fixed", width = 0 },
            })
            local chevron = RSUI:Button({
                id = tostring(spec.id) .. "_row_chevron_" .. tostring(poolIndex),
                parent = row,
                text = "·",
                compact = true,
                gradient = false,
                fontSize = tonumber(spec.chevronFontSize) or Token("font.small", 10),
                slot = { size = "fixed", width = c.chevronWidth, minWidth = c.chevronWidth },
                onClick = function(button)
                    local key = button.state and button.state.treeKey
                    if key == nil then return false end
                    return c:ToggleExpanded(key)
                end,
            })
            local label = RSUI:Button({
                id = tostring(spec.id) .. "_row_label_" .. tostring(poolIndex),
                parent = row,
                text = "",
                compact = true,
                gradient = false,
                fontSize = tonumber(spec.fontSize) or Token("font.body", 11),
                slot = { size = "fill", fill = 1, minWidth = 40 },
                onClick = function(button)
                    local index = button.state and button.state.treeIndex
                    if index == nil then return false end
                    view:SetSelectedIndex(index)
                    RefreshSelectionVisuals(c)
                    return true
                end,
            })
            if indent == nil or chevron == nil or label == nil then return nil end
            row.treeIndent, row.treeChevron, row.treeLabel = indent, chevron, label
            return row
        end,
        bindRow = function(row, item, index, key, view)
            if type(row) ~= "table" or type(item) ~= "table" then return end
            local indent = math.max(0, tonumber(item.depth) or 0) * c.indentWidth
            row.treeIndent.spec.width = indent
            row:UpdateChildSlot(row.treeIndent, { size = "fixed", width = indent })
            row.treeChevron.state = row.treeChevron.state or {}
            row.treeChevron.state.treeKey = key
            row.treeChevron:SetText(item.hasChildren and (item.expanded and "−" or "+") or "·")
            local _, chevronAccepted, chevronErr = row.treeChevron:SetEnabled(item.hasChildren == true)
            if chevronAccepted == false then
                c:FailClosedInteraction("tree_chevron_enabled_failed:" .. tostring(chevronErr or "native_enable_rejected"))
                return
            end
            row.treeLabel.state = row.treeLabel.state or {}
            row.treeLabel.state.treeIndex, row.treeLabel.state.treeKey = index, key
            row.treeLabel:SetText(tostring(item.text or key or ""))
            row.treeLabel:SetSelected(view:IsItemSelected(index))
        end,
        onSelectionChanged = function(index, _, view, _, reason, key)
            RefreshSelectionVisuals(c)
            local row = index and c.model.rows[index] or nil
            if type(c.onSelectionChanged) == "function" then
                RSUI:Callback("rsui:" .. tostring(spec.id) .. ":tree_selection", c.onSelectionChanged, key, row and row.node or nil, row, c, reason)
            end
        end,
        onItemActivated = function(item, index, key, view, reason)
            if type(c.onItemActivated) == "function" then
                RSUI:Callback("rsui:" .. tostring(spec.id) .. ":tree_activate", c.onItemActivated, key, item and item.node or nil, item, c, reason)
            end
        end,
    })
    if list == nil then return nil, "tree_list_failed" end
    c.list = list

    function c:_RefreshModel(reason)
        local ok, modelErr = self.model:Rebuild()
        if ok ~= true then return false, modelErr end
        self.list:SetItems(self.model:GetRows(), "tree:" .. tostring(self.model.revision) .. ":" .. tostring(reason or "refresh"))
        RefreshSelectionVisuals(self)
        return true
    end

    function c:SetNodes(nodes)
        local ok, modelErr = self.model:SetNodes(nodes)
        if ok ~= true then return false, modelErr end
        self.list:SetItems(self.model:GetRows(), "tree:" .. tostring(self.model.revision) .. ":nodes")
        RefreshSelectionVisuals(self)
        return true
    end

    function c:SetExpanded(key, expanded)
        local ok, modelErr = self.model:SetExpanded(key, expanded)
        if ok ~= true then return false, modelErr end
        self.list:SetItems(self.model:GetRows(), "tree:" .. tostring(self.model.revision) .. ":expand")
        if type(self.onExpansionChanged) == "function" then
            RSUI:Callback("rsui:" .. self.id .. ":tree_expand", self.onExpansionChanged, tostring(key), expanded == true, self.model:GetNode(key), self)
        end
        RefreshSelectionVisuals(self)
        return true
    end

    function c:ToggleExpanded(key)
        return self:SetExpanded(key, not self.model:IsExpanded(key))
    end

    function c:ExpandAll()
        local changed, modelErr = self.model:ExpandAll()
        if modelErr ~= nil then return false, modelErr end
        if changed then self.list:SetItems(self.model:GetRows(), "tree:" .. tostring(self.model.revision) .. ":expand_all") end
        RefreshSelectionVisuals(self)
        return changed, nil
    end

    function c:CollapseAll()
        local changed, modelErr = self.model:CollapseAll()
        if modelErr ~= nil then return false, modelErr end
        if changed then self.list:SetItems(self.model:GetRows(), "tree:" .. tostring(self.model.revision) .. ":collapse_all") end
        RefreshSelectionVisuals(self)
        return changed, nil
    end

    function c:GetSelectedKey() return self.list:GetSelectedKey() end
    function c:SetSelectedKey(key)
        key = tostring(key or "")
        local index = self.model:GetRowIndex(key)
        if index == nil then return false, "tree_key_not_visible" end
        local changed = self.list:SetSelectedIndex(index)
        self.list:EnsureIndexVisible(index)
        RefreshSelectionVisuals(self)
        return changed
    end
    function c:GetSelectedNode()
        local key = self:GetSelectedKey()
        return key and self.model:GetNode(key) or nil
    end
    function c:EnsureKeyVisible(key)
        local index = self.model:GetRowIndex(key)
        if index == nil then return false end
        return self.list:EnsureIndexVisible(index)
    end
    function c:GetModelSnapshot() return self.model:GetSnapshot() end
    function c:GetVisibleRows() return self.model:GetRows() end

    function c:Measure(availableW, availableH)
        local dw, dh = Measure(self.list, availableW, availableH)
        self.desiredWidth, self.desiredHeight, self.measureDirty = math.max(1, dw), math.max(1, dh), false
        return self.desiredWidth, self.desiredHeight
    end
    function c:Layout(x, y, width, height)
        width, height = math.max(1, N(width, self.width or 1)), math.max(1, N(height, self.height or 1))
        self:SetBounds(x, y, width, height)
        Arrange(self.list, 0, 0, width, height)
        return height
    end

    return c
end)

RSUI.CompositeFoundation = {
    version = 5,
    statusChipContractVersion = RSUI.StatusChipContractVersion,
    statusSemanticsContractVersion = RSUI.StatusSemanticsContractVersion,
    stateNoticeContractVersion = RSUI.StateNoticeContractVersion,
    detailHeaderContractVersion = RSUI.DetailHeaderContractVersion,
    pickerModelContractVersion = RSUI.PickerModelContractVersion,
    searchablePickerContractVersion = RSUI.SearchablePickerContractVersion,
    iconPickerContractVersion = RSUI.IconPickerContractVersion,
    treeViewContractVersion = RSUI.TreeViewContractVersion,
    treeStableIdentityContractVersion = RSUI.TreeStableIdentityContractVersion,
    treeMutationTransactionContractVersion = RSUI.TreeMutationTransactionContractVersion,
    treeExpansionStateBoundContractVersion = RSUI.TreeExpansionStateBoundContractVersion,
    GetSnapshot = function()
        return {
            version = 5,
            statusChip = tonumber(RSUI.StatusChipContractVersion) or 0,
            statusSemantics = tonumber(RSUI.StatusSemanticsContractVersion) or 0,
            stateNotice = tonumber(RSUI.StateNoticeContractVersion) or 0,
            detailHeader = tonumber(RSUI.DetailHeaderContractVersion) or 0,
            pickerModel = tonumber(RSUI.PickerModelContractVersion) or 0,
            searchablePicker = tonumber(RSUI.SearchablePickerContractVersion) or 0,
            iconPicker = tonumber(RSUI.IconPickerContractVersion) or 0,
            treeView = tonumber(RSUI.TreeViewContractVersion) or 0,
            treeStableIdentity = tonumber(RSUI.TreeStableIdentityContractVersion) or 0,
            treeMutationTransaction = tonumber(RSUI.TreeMutationTransactionContractVersion) or 0,
            treeExpansionStateBound = tonumber(RSUI.TreeExpansionStateBoundContractVersion) or 0,
        }
    end,
}
