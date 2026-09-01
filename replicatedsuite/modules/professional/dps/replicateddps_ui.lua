ReplicatedSuiteModuleSandbox:Enter('dps', {'ReplicatedDps', 'ReplicatedDpsConfig'})
------------------------------------------------------------------------
-- Replicated DPS - UI shell
-- Author: Replicated
------------------------------------------------------------------------

if ReplicatedDps == nil or ReplicatedDps.Boot == nil then return end
local D = ReplicatedDps
local Boot = D.Boot
local U = D.Util
local C = D.Const
local Api = D.Api
local Actors = D.ActorRegistry
local StatsV3 = D.StatsV3
local StatsRead = D.StatsRead
local IdentityShadow = D.IdentityShadow
local EventFacts = D.EventFacts
local EventBlocks = D.EventBlocks
local EventClassifications = D.EventClassifications
local LocalReplay = D.LocalReplayPlanner
local LocalStatsShadow = D.LocalStatsShadow
local LocalStatsCandidate = D.LocalStatsCandidate
local LocalDerivedShadow = D.LocalDerivedShadow
local LocalCommitEnvelope = D.LocalCommitEnvelope
local PersistenceShards = D.PersistenceShards
local PersistenceLoadGate = D.PersistenceLoadGate
local PersistenceSwitch = D.PersistenceSwitch
local EventShadow = D.EventShadow

if Boot.phase == "FAILED" then return end
if type(Actors) ~= "table" then
    Boot:Fail("ui:actor_registry", "rdps_actor_registry.lua is unavailable")
    return
end
if type(StatsV3) ~= "table" or type(StatsV3.GetStatusLine) ~= "function" then
    Boot:Fail("ui:stats_v3", "rdps_stats_v3.lua is unavailable")
    return
end
if type(StatsRead) ~= "table" or type(StatsRead.GetSharedHealingActor) ~= "function" then
    Boot:Fail("ui:stats_read", "rdps_stats_read.lua is unavailable")
    return
end
if type(EventFacts) ~= "table" or type(EventFacts.GetStatusLine) ~= "function" then
    Boot:Fail("ui:event_facts", "rdps_event_facts.lua is unavailable")
    return
end
if type(EventBlocks) ~= "table" or type(EventBlocks.GetStatusLine) ~= "function" then
    Boot:Fail("ui:event_blocks", "rdps_event_blocks.lua is unavailable")
    return
end
if type(EventClassifications) ~= "table"
    or type(EventClassifications.GetStatusLine) ~= "function" then
    Boot:Fail("ui:event_classification", "rdps_event_classification.lua is unavailable")
    return
end
if type(LocalReplay) ~= "table" or type(LocalReplay.GetStatusLine) ~= "function" then
    Boot:Fail("ui:local_replay", "rdps_local_replay.lua is unavailable")
    return
end
if type(LocalStatsShadow) ~= "table" or type(LocalStatsShadow.GetStatusLine) ~= "function" then
    Boot:Fail("ui:local_stats_shadow", "rdps_local_stats_shadow.lua is unavailable")
    return
end
if type(LocalStatsCandidate) ~= "table" or type(LocalStatsCandidate.GetStatusLine) ~= "function" then
    Boot:Fail("ui:local_stats_candidate", "rdps_local_stats_candidate.lua is unavailable")
    return
end
if type(LocalDerivedShadow) ~= "table" or type(LocalDerivedShadow.GetStatusLine) ~= "function" then
    Boot:Fail("ui:local_derived_shadow", "rdps_local_derived_shadow.lua is unavailable")
    return
end
if type(LocalCommitEnvelope) ~= "table" or type(LocalCommitEnvelope.GetStatusLine) ~= "function" then
    Boot:Fail("ui:local_commit_envelope", "rdps_local_commit_envelope.lua is unavailable")
    return
end
if type(PersistenceShards) ~= "table" or type(PersistenceShards.GetStatusLine) ~= "function" then
    Boot:Fail("ui:persistence_shards", "rdps_persistence_shards.lua is unavailable")
    return
end
if type(PersistenceLoadGate) ~= "table"
    or type(PersistenceLoadGate.GetStatusLine) ~= "function" then
    Boot:Fail("ui:persistence_load_gate", "rdps_persistence_load_gate.lua is unavailable")
    return
end
if type(PersistenceSwitch) ~= "table"
    or type(PersistenceSwitch.GetStatusLine) ~= "function" then
    Boot:Fail("ui:persistence_switch", "rdps_persistence_switch.lua is unavailable")
    return
end
if type(EventShadow) ~= "table" or type(EventShadow.GetStatusLine) ~= "function" then
    Boot:Fail("ui:event_shadow", "rdps_event_shadow.lua is unavailable")
    return
end
Boot:SetPhase("SHELL_CREATING")

D.UI = D.UI or {
    registry = {},
    windows = {},
    pages = {},
    rows = {},
    controls = {},
    shellCommitted = false,
    movingCount = 0,
    resizingCount = 0,
    dragTransaction = nil,
    dragHosts = {},
    quickAutoPlacementResolved = false,
}
local UIX = D.UI

local function IsProtectedSelfEntity(entity)
    if type(entity) ~= "table" or D.Identity == nil then return false end
    if entity.key == D.Identity.entityKey or entity.hardRelation == "SELF" then return true end
    local normalized = U.NormalizeName(entity.name)
    return normalized ~= "" and (normalized == U.NormalizeName(D.Identity.playerName)
        or normalized == U.NormalizeName(D.Identity.playerNameWithWorld))
end

local function EffectiveEntityKind(entity)
    if type(entity) ~= "table" then return nil end
    local override = type(entity.manualOverride) == "table" and entity.manualOverride or nil
    return override ~= nil and override.kind or entity.kind or entity.hardKind
end

local UI_SHELL_SCHEMA = 15
if UIX.shellCommitted == true and tonumber(UIX.shellSchema) ~= UI_SHELL_SCHEMA then
    for _, oldWindow in pairs(UIX.windows or {}) do pcall(function() oldWindow:Show(false) end) end
    for _, oldHost in pairs(UIX.dragHosts or {}) do pcall(function() oldHost:Show(false) end) end
    -- Hide every surviving control/host from the previous shell generation
    -- before rebuilding so hot reload cannot leave an invisible input catcher.
    for _, oldControl in pairs(UIX.controls or {}) do
        if oldControl ~= nil and type(oldControl.Show) == "function" then
            pcall(function() oldControl:Show(false) end)
        end
    end
    UIX.needsRecovery = true
end
if UIX.needsRecovery == true then
    UIX.registry = {}
    UIX.windows = {}
    UIX.pages = {}
    UIX.rows = {}
    UIX.controls = {}
    UIX.detailRows = {}
    UIX.detail = { selected = nil, view = "ABILITY", offset = 0, totalEntries = 0, navigation = {}, candidateSelection = nil }
    UIX.ruleList = { offset = 0, selectedRuleId = nil, totalEntries = 0, visibleRows = 8, clearArmedAt = 0 }
    UIX.ruleRows = {}
    UIX.optionalPrintUnavailable = {}
    UIX.optionalPrintChooserUnavailable = false
    UIX.printContext = nil
    UIX.shellCommitted = false
    UIX.shellSchema = UI_SHELL_SCHEMA
    UIX.movingCount = 0
    UIX.resizingCount = 0
    UIX.dragTransaction = nil
    UIX.dragHosts = {}
    UIX.quickAutoPlacementResolved = false
    UIX.physicalSuffix = "_g" .. tostring(Boot.generation)
    UIX.needsRecovery = false
end
UIX.dragHosts = UIX.dragHosts or {}
UIX.physicalSuffix = UIX.physicalSuffix or ""
UIX.detail = UIX.detail or { selected = nil, view = "ABILITY", offset = 0, totalEntries = 0, navigation = {}, candidateSelection = nil }
UIX.detail.navigation = UIX.detail.navigation or {}
UIX.rankingOffsets = UIX.rankingOffsets or { friendly = 0, enemy = 0 }
UIX.visibleRows = UIX.visibleRows or { friendly = 10, enemy = 10 }
UIX.detailRows = UIX.detailRows or {}
UIX.configRows = UIX.configRows or {}
UIX.ruleList = UIX.ruleList or {
    offset = 0,
    selectedRuleId = nil,
    totalEntries = 0,
    visibleRows = 8,
    clearArmedAt = 0,
}
UIX.ruleRows = UIX.ruleRows or {}
UIX.printContext = type(UIX.printContext) == "table" and UIX.printContext or nil
UIX.optionalPrintChooserUnavailable = UIX.optionalPrintChooserUnavailable == true
UIX.lastRenderedStatsRevision = tonumber(UIX.lastRenderedStatsRevision) or -1

local function PhysicalId(id)
    return tostring(id) .. tostring(UIX.physicalSuffix or "")
end

local function Register(id, widget)
    if UIX.registry[id] ~= nil and UIX.registry[id] ~= widget then
        error("duplicate widget id: " .. tostring(id))
    end
    UIX.registry[id] = widget
    return widget
end

local function SetMouseThrough(widget, mouseThrough)
    if widget == nil then return end
    -- ArcheRage RU's documented Widget API exposes EnablePick/Clickable with
    -- exactly one argument.  Passing a second "recursive" flag is unsupported
    -- and can leave the visual label/window owning the mouse hit, which blocks
    -- the drag surface underneath (or lets the click fall through to the game).
    if widget.EnablePick ~= nil then pcall(function() widget:EnablePick(not mouseThrough) end) end
    if widget.Clickable ~= nil then pcall(function() widget:Clickable(not mouseThrough) end) end
end

-- Widget hit-testing is self-scoped on the RU API.  Disabling the presentation
-- window itself does not disable its child buttons/rows; those children keep
-- their own explicit Pick/Clickable state.
local function SetSelfMouseThrough(widget, mouseThrough)
    SetMouseThrough(widget, mouseThrough)
end

local function CreateBackground(parent, r, g, b, a, layer)
    local bg = parent:CreateColorDrawable(r, g, b, a, layer or "background")
    if bg == nil then error("failed to create color drawable") end
    bg:AddAnchor("TOPLEFT", parent, 0, 0)
    bg:AddAnchor("BOTTOMRIGHT", parent, 0, 0)
    parent.repdpsRefs = parent.repdpsRefs or {}
    parent.repdpsRefs[#parent.repdpsRefs + 1] = bg
    return bg
end

local function SetLabelExtent(label, width, height)
    if label == nil then return end
    width = math.max(1, tonumber(width) or 1)
    height = math.max(1, tonumber(height) or 1)
    label:SetExtent(width, height)
    if label.SetWidth ~= nil then label:SetWidth(width) end
    if label.SetHeight ~= nil then label:SetHeight(height) end
    label.repdpsWidth = width
    label.repdpsHeight = height
end

-- ArcheRage exposes TextStyle:GetTextWidth in the official UI API.  Use the
-- engine's real font metrics first, then fall back to a UTF-8-safe estimate.
-- This avoids the previous double/early truncation of Chinese unit names.
local function Utf8CharLength(text)
    local value = tostring(text or "")
    local count = 0
    local index = 1
    while index <= #value do
        local byte = string.byte(value, index) or 0
        local size = 1
        if byte >= 0xF0 then size = 4
        elseif byte >= 0xE0 then size = 3
        elseif byte >= 0xC0 then size = 2 end
        index = index + size
        count = count + 1
    end
    return count
end

local function Utf8Prefix(text, charCount)
    local value = tostring(text or "")
    local wanted = math.max(0, tonumber(charCount) or 0)
    if wanted <= 0 then return "" end
    local count = 0
    local index = 1
    while index <= #value do
        count = count + 1
        if count > wanted then return string.sub(value, 1, index - 1) end
        local byte = string.byte(value, index) or 0
        if byte >= 0xF0 then index = index + 4
        elseif byte >= 0xE0 then index = index + 3
        elseif byte >= 0xC0 then index = index + 2
        else index = index + 1 end
    end
    return value
end

local function EstimateTextWidth(text, fontSize)
    local value = tostring(text or "")
    local size = math.max(1, tonumber(fontSize) or 10)
    local units = 0
    local index = 1
    while index <= #value do
        local byte = string.byte(value, index) or 0
        if byte < 0x80 then
            units = units + 0.56
            index = index + 1
        elseif byte >= 0xF0 then
            units = units + 1.0
            index = index + 4
        elseif byte >= 0xE0 then
            units = units + 1.0
            index = index + 3
        elseif byte >= 0xC0 then
            units = units + 1.0
            index = index + 2
        else
            units = units + 1.0
            index = index + 1
        end
    end
    return units * size
end

local function MeasureTextWidth(label, text, fontSize)
    local value = tostring(text or "")
    if label ~= nil and label.style ~= nil and label.style.GetTextWidth ~= nil then
        local ok, measured = pcall(function() return label.style:GetTextWidth(value) end)
        if ok and tonumber(measured) ~= nil then return math.max(0, tonumber(measured)) end
    end
    return EstimateTextWidth(value, fontSize)
end

local function SetLabelFontSize(label, fontSize)
    if label == nil then return end
    local size = math.max(1, math.floor(tonumber(fontSize) or 10))
    if label.style ~= nil and label.style.SetFontSize ~= nil then
        pcall(function() label.style:SetFontSize(size) end)
    end
    label.repdpsFontSize = size
end

local function TruncateForWidth(label, value, width, fontSize)
    local text = tostring(value or "")
    local available = math.max(1, (tonumber(width) or 1) - 2)
    local size = math.max(1, tonumber(fontSize) or 10)
    if MeasureTextWidth(label, text, size) <= available then return text end

    local suffix = ""
    local length = Utf8CharLength(text)
    local low, high, best = 0, length, 0
    while low <= high do
        local middle = math.floor((low + high) / 2)
        local candidate = Utf8Prefix(text, middle) .. suffix
        if MeasureTextWidth(label, candidate, size) <= available then
            best = middle
            low = middle + 1
        else
            high = middle - 1
        end
    end
    return Utf8Prefix(text, best) .. suffix
end

local function SetBoundedText(label, value, width, fontSize)
    if label == nil then return end
    local actualWidth = tonumber(width) or tonumber(label.repdpsWidth) or tonumber(label:GetWidth()) or 1
    local actualFont = tonumber(fontSize) or tonumber(label.repdpsFontSize) or 10
    label:SetText(TruncateForWidth(label, value, actualWidth, actualFont))
end

local function SetAdaptiveSingleLineText(label, value, width, preferredFontSize, minimumFontSize)
    if label == nil then return end
    local text = tostring(value or "")
    local actualWidth = math.max(1, tonumber(width) or tonumber(label.repdpsWidth) or 1)
    if actualWidth <= 2 then
        label:SetText("")
        return
    end
    local preferred = math.max(1, math.floor(tonumber(preferredFontSize) or 14))
    local minimum = math.max(1, math.min(preferred, math.floor(tonumber(minimumFontSize) or 10)))
    for size = preferred, minimum, -1 do
        SetLabelFontSize(label, size)
        if MeasureTextWidth(label, text, size) <= actualWidth - 2 then
            label:SetText(text)
            return
        end
    end
    SetBoundedText(label, text, actualWidth, minimum)
end

local function SetFittedControlText(control, value, preferredFontSize, minimumFontSize)
    if control == nil then return end
    local width = tonumber(control.repdpsWidth)
    if width == nil and control.GetWidth ~= nil then width = tonumber(control:GetWidth()) end
    local baseFontSize = tonumber(control.repdpsBaseFontSize) or tonumber(control.repdpsFontSize) or 10
    local preferred = math.min(tonumber(preferredFontSize) or baseFontSize, baseFontSize)
    SetAdaptiveSingleLineText(
        control,
        value,
        math.max(1, width or 1),
        preferred,
        math.min(tonumber(minimumFontSize) or 8, preferred)
    )
end

local function FitMultilineText(label, value, width, fontSize, maxLines)
    local lines = {}
    local source = tostring(value or "") .. "\n"
    for line in string.gmatch(source, "(.-)\n") do
        if maxLines == nil or #lines < maxLines then
            lines[#lines + 1] = TruncateForWidth(label, line, width, fontSize)
        end
    end
    return table.concat(lines, "\n")
end
local function CreateLabel(parent, id, text, x, y, width, height, fontSize, align)
    local label = Register(id, parent:CreateChildWidget("label", PhysicalId(id), 0, true))
    label:AddAnchor("TOPLEFT", parent, x, y)
    if label.SetAutoResize ~= nil then label:SetAutoResize(false) end
    SetLabelExtent(label, width, height)
    label:EnablePick(false)
    if label.Clickable ~= nil then label:Clickable(false) end
    label.repdpsFontSize = fontSize or 11
    label.repdpsBaseFontSize = label.repdpsFontSize
    label.style:SetFontSize(label.repdpsFontSize)
    if label.style.SetEllipsis ~= nil then pcall(function() label.style:SetEllipsis(false) end) end
    label.style:SetAlign(align or ALIGN_LEFT)
    label.style:SetColor(1, 1, 1, 1)
    if label.style.SetOutline ~= nil then label.style:SetOutline(true) end
    label:SetText(text or "")
    label:Show(true)
    return label
end

local function ApplyButtonStyle(button, width, height, fontSize)
    button.repdpsRefs = button.repdpsRefs or {}
    if button.repdpsRefs.buttonBackgrounds == nil then
        local colors = {
            { 0.14, 0.21, 0.29, 0.96 },
            { 0.22, 0.34, 0.46, 0.98 },
            { 0.08, 0.13, 0.19, 0.98 },
            { 0.08, 0.09, 0.11, 0.70 },
        }
        button.repdpsRefs.buttonBackgrounds = {}
        for i = 1, 4 do
            local c = colors[i]
            local bg = button:CreateColorDrawable(c[1], c[2], c[3], c[4], "background")
            if bg ~= nil then
                bg:AddAnchor("TOPLEFT", button, 0, 0)
                bg:AddAnchor("BOTTOMRIGHT", button, 0, 0)
            end
            button.repdpsRefs.buttonBackgrounds[i] = bg
        end
        if button.SetNormalBackground ~= nil then
            button:SetNormalBackground(button.repdpsRefs.buttonBackgrounds[1])
            button:SetHighlightBackground(button.repdpsRefs.buttonBackgrounds[2])
            button:SetPushedBackground(button.repdpsRefs.buttonBackgrounds[3])
            button:SetDisabledBackground(button.repdpsRefs.buttonBackgrounds[4])
        end
    end
    if button.SetAutoResize ~= nil then button:SetAutoResize(false) end
    width = math.max(1, tonumber(width) or 1)
    height = math.max(1, tonumber(height) or 1)
    button:SetExtent(width, height)
    if button.SetWidth ~= nil then button:SetWidth(width) end
    if button.SetHeight ~= nil then button:SetHeight(height) end
    button.repdpsWidth = width
    button.repdpsHeight = height
    button.repdpsFontSize = fontSize or 10
    button.repdpsBaseFontSize = button.repdpsFontSize
    if button.style ~= nil then
        button.style:SetFontSize(button.repdpsFontSize)
        if button.style.SetEllipsis ~= nil then pcall(function() button.style:SetEllipsis(false) end) end
        if button.style.SetColor ~= nil then button.style:SetColor(0.96, 0.92, 0.82, 1) end
    end
end

local function CreateButton(parent, id, text, x, y, width, height, fontSize)
    local button = Register(id, parent:CreateChildWidget("button", PhysicalId(id), 0, true))
    button:SetText(text or "")
    ApplyButtonStyle(button, width, height, fontSize)
    button:AddAnchor("TOPLEFT", parent, x, y)
    if button.Enable ~= nil then button:Enable(true) end
    if button.Clickable ~= nil then button:Clickable(true) end
    button:Show(true)
    return button
end

local function CreatePanel(parent, id, x, y, width, height)
    local panel = Register(id, UIParent:CreateWidget("emptywidget", PhysicalId(id), parent))
    panel:AddAnchor("TOPLEFT", parent, x, y)
    panel:SetExtent(width, height)
    panel:Show(true)
    return panel
end

local function SafeHandler(widget, eventName, handler, label)
    if widget == nil or type(widget.SetHandler) ~= "function" then return false end
    widget:SetHandler(eventName, function(...)
        local args = { ... }
        local argCount = select("#", ...)
        local results = nil
        local ok, err = xpcall(function() results = { handler(unpack(args, 1, argCount)) } end, Boot.SafeTraceback)
        if not ok then
            D.Diagnostics.counters.uiErrors = D.Diagnostics.counters.uiErrors + 1
            D.Diagnostics:AddError("ui:" .. tostring(label or eventName), err)
            return nil
        end
        if results ~= nil then return unpack(results) end
        return nil
    end)
end

local function CreateWindow(id, width, height, useSystemLayer)
    local window = Register(id, CreateEmptyWindow(PhysicalId(id), "UIParent"))
    window:SetExtent(width, height)
    if useSystemLayer ~= false and window.SetUILayer ~= nil then pcall(function() window:SetUILayer("system") end) end
    window:Enable(true)
    window:Clickable(true)
    window:Show(false)
    CreateBackground(window, 0.025, 0.035, 0.052, 0.94)
    return window
end

local function StoreWindowRect(name, window)
    U.StoreRect(D.State.ui[name], window)
    D.MarkUiDirty()
end

local function IsQuickWindowState(stateName)
    return stateName == "friendly" or stateName == "enemy"
end

local function GetRectVisualScale(stateName, window)
    if IsQuickWindowState(stateName) then
        return U.Clamp(tonumber(window and window.repdpsScale)
            or tonumber(D.State.ui[stateName] and D.State.ui[stateName].visualScale)
            or tonumber(D.State.config.rankingScale) or 1, 0.60, 1.20)
    end
    return 1
end

local function GetStableDragRect(stateName, window)
    local rect = D.State.ui[stateName]
    if type(rect) == "table" and type(U.ResolveRect) == "function" then
        local fallbackW = tonumber(window and window.GetWidth and window:GetWidth()) or 1
        local fallbackH = tonumber(window and window.GetHeight and window:GetHeight()) or 1
        return U.ResolveRect(rect, fallbackW, fallbackH)
    end
    return U.GetLogicalRect(window)
end

local function EnsureQuickDragHost(stateName, id)
    UIX.dragHosts = UIX.dragHosts or {}
    local host = UIX.dragHosts[stateName]
    if host ~= nil then return host end
    host = Register(id .. "_host", CreateEmptyWindow(PhysicalId(id .. "_host"), "UIParent"))
    host:SetExtent(1, 1)
    host:AddAnchor("TOPLEFT", "UIParent", 0, 0)
    if host.SetUILayer ~= nil then pcall(function() host:SetUILayer("system") end) end
    if host.Enable ~= nil then host:Enable(true) end
    -- Host is only a movement/anchor container.  Keep its own hit target off,
    -- but do not disable click capability on the parent: RU may use the parent
    -- clickable state as an input gate for child widgets.  The child drag strip
    -- owns the actual Pick target.
    if host.Clickable ~= nil then pcall(function() host:Clickable(true) end) end
    if host.EnablePick ~= nil then pcall(function() host:EnablePick(false) end) end
    host:Show(false)
    UIX.dragHosts[stateName] = host
    return host
end

-- Quick ranking windows use native SetScale(), which makes moving the scaled
-- presentation window itself unreliable on some RU viewport sizes.  Keep the
-- saved geometry on an unscaled real window host instead.  The drag handle is
-- a child of that host and therefore starts movement on its own native parent;
-- there is no proxy hand-off and no second ranking window is ever touched.
local function AttachDragHeader(window, id, stateName, y, height, isLockedFn)
    if IsQuickWindowState(stateName) then
        local host = EnsureQuickDragHost(stateName, id)
        -- Use a real button as the drag hit-owner.  On this RU client a
        -- transparent button is a proven mouse-input widget, while emptywidget
        -- hit ownership can be inconsistent when layered above another window.
        local header = Register(id, host:CreateChildWidget("button", PhysicalId(id), 0, true))
        if header.SetText ~= nil then header:SetText("") end
        if header.EnableFocus ~= nil then pcall(function() header:EnableFocus(false) end) end
        header:SetExtent(math.max(1, window:GetWidth()), math.max(1, height))
        header:AddAnchor("TOPLEFT", host, 0, math.max(0, y or 0))
        if header.Enable ~= nil then header:Enable(true) end
        if header.Clickable ~= nil then header:Clickable(true) end
        if header.EnablePick ~= nil then pcall(function() header:EnablePick(true) end) end
        header:EnableDrag(true)
        if header.SetDragCondition ~= nil and DC_ALWAYS ~= nil then
            pcall(function() header:SetDragCondition(DC_ALWAYS) end)
        end
        header.repdpsMoving = false
        header:Show(false)

        SafeHandler(header, "OnDragStart", function(self)
            if isLockedFn ~= nil and isLockedFn() then return false end
            if self.repdpsMoving == true then return true end
            if type(host.StartMoving) ~= "function" then return false end
            self.repdpsMoving = true
            UIX.movingCount = UIX.movingCount + 1
            -- Crossing the drag boundary makes this HUD independently user-owned
            -- immediately.  Do this before native movement starts so no pending
            -- responsive LayoutAll pass can still treat the friendly/enemy pair
            -- as one untouched default cluster.
            local rect = D.State.ui[stateName]
            if type(rect) == "table" then rect.userMoved = true end
            host:StartMoving()
            return true
        end, id .. ":drag_start")

        SafeHandler(header, "OnDragStop", function(self)
            if type(host.StopMovingOrSizing) == "function" then host:StopMovingOrSizing() end
            local rect = D.State.ui[stateName]
            local x, yPos = U.GetLogicalPosition(host)
            local _, _, width, heightValue = GetStableDragRect(stateName, window)
            rect.visualScale = GetRectVisualScale(stateName, window)
            U.SetRectFromLogical(rect, x, yPos, width, heightValue)
            rect.userMoved = true
            self.repdpsMoving = false
            UIX.movingCount = math.max(0, UIX.movingCount - 1)
            D.MarkUiDirty()
            -- A quick HUD move is strictly side-local.  Do not mark the global
            -- DPS layout dirty here: LayoutAll() also lays out the peer HUD and
            -- historically caused the untouched window to jump on first drag.
            UIX:LayoutQuickWindow(stateName)
            return true
        end, id .. ":drag_stop")
        return header
    end

    -- Config/detail/tool windows are unscaled and use the same proven native
    -- pattern as the other Suite modules: the visible handle moves its window.
    local header = CreatePanel(window, id, 0, y or 0, math.max(1, window:GetWidth()), math.max(1, height))
    header:Enable(true)
    header:Clickable(true)
    if header.EnablePick ~= nil then pcall(function() header:EnablePick(true) end) end
    header:EnableDrag(true)
    SafeHandler(header, "OnDragStart", function(self)
        if isLockedFn ~= nil and isLockedFn() then return false end
        if type(window.StartMoving) ~= "function" then return false end
        self.repdpsMoving = true
        UIX.movingCount = UIX.movingCount + 1
        window:StartMoving()
        return true
    end, id .. ":drag_start")
    SafeHandler(header, "OnDragStop", function(self)
        if type(window.StopMovingOrSizing) == "function" then window:StopMovingOrSizing() end
        if self.repdpsMoving == true then UIX.movingCount = math.max(0, UIX.movingCount - 1) end
        self.repdpsMoving = false
        StoreWindowRect(stateName, window)
        D.MarkLayoutDirty()
        return true
    end, id .. ":drag_stop")
    return header
end

function UIX:StepDragTransaction()
    return false
end

local function PositionQuickDragSurface(surface, windowX, windowY, presentationScale,
    localX, localY, localWidth, localHeight, visible, enabled)
    if surface == nil then return end
    local scale = U.Clamp(tonumber(presentationScale) or 1, 0.60, 1.20)
    local x = (tonumber(localX) or 0) * scale
    local y = (tonumber(localY) or 0) * scale
    local width = math.max(1, (tonumber(localWidth) or 1) * scale)
    local heightValue = math.max(1, (tonumber(localHeight) or 1) * scale)
    if surface.RemoveAllAnchors ~= nil then surface:RemoveAllAnchors() end
    local host = UIX.dragHosts and (surface == UIX.controls.friendlyDrag and UIX.dragHosts.friendly
        or (surface == UIX.controls.enemyDrag and UIX.dragHosts.enemy or nil)) or nil
    if host ~= nil then
        surface:AddAnchor("TOPLEFT", host, x, y)
    else
        surface:AddAnchor("TOPLEFT", "UIParent", (tonumber(windowX) or 0) + x, (tonumber(windowY) or 0) + y)
    end
    surface:SetExtent(width, heightValue)
    if surface.EnableDrag ~= nil then surface:EnableDrag(enabled == true) end
    if surface.Clickable ~= nil then surface:Clickable(enabled == true) end
    surface:Show(visible == true and enabled == true)
    if visible == true and enabled == true and surface.Raise ~= nil then pcall(function() surface:Raise() end) end
end

local function AttachResizeHandle(window, id, stateName, isLockedFn)
    local handle = CreateButton(window, id, "///", window:GetWidth() - 28, window:GetHeight() - 21, 26, 19, 9)
    handle:EnableDrag(true)
    SafeHandler(handle, "OnDragStart", function(self)
        if isLockedFn ~= nil and isLockedFn() then return false end
        self.repdpsResizing = true
        UIX.resizingCount = UIX.resizingCount + 1
        if window.UseResizing ~= nil then pcall(function() window:UseResizing(true) end) end
        window:StartSizing("BOTTOMRIGHT")
        return true
    end, id .. ":resize_start")
    SafeHandler(handle, "OnDragStop", function(self)
        window:StopMovingOrSizing()
        self.repdpsResizing = false
        UIX.resizingCount = math.max(0, UIX.resizingCount - 1)
        StoreWindowRect(stateName, window)
        if IsQuickWindowState(stateName) then
            UIX:LayoutQuickWindow(stateName)
        else
            D.MarkLayoutDirty()
        end
    end, id .. ":resize_stop")
    return handle
end

local function CreateQuickRows(window, sideName)
    local rows = {}
    for i = 1, C.MAX_ROWS do
        local rowId = string.format("repdps_%s_row_%02d", sideName, i)
        local row = CreatePanel(window, rowId, 4, C.HEADER_H + 2 + (i - 1) * C.ROW_H, window:GetWidth() - 8, C.ROW_H - 2)
        row:Enable(true)
        row:Clickable(true)
        if row.EnablePick ~= nil then row:EnablePick(true) end
        row.repdpsBg = CreateBackground(row, 0.08, 0.095, 0.12, 0.86)
        local bar = CreatePanel(row, rowId .. "_bar", 0, 0, 1, C.ROW_H - 2)
        bar.repdpsBg = CreateBackground(
            bar,
            sideName == "friendly" and 0.14 or 0.45,
            sideName == "friendly" and 0.39 or 0.15,
            sideName == "friendly" and 0.63 or 0.16,
            0.80
        )
        SetMouseThrough(bar, true)
        local name = CreateLabel(row, rowId .. "_name", "", 5, 1, 130, C.ROW_H - 3, 10, ALIGN_LEFT)
        local amount = CreateLabel(row, rowId .. "_amount", "", 139, 1, 66, C.ROW_H - 3, 10, ALIGN_RIGHT)
        local rate = CreateLabel(row, rowId .. "_rate", "", 209, 1, 90, C.ROW_H - 3, 10, ALIGN_RIGHT)
        local percent = CreateLabel(row, rowId .. "_percent", "", 303, 1, 38, C.ROW_H - 3, 10, ALIGN_RIGHT)
        row:Show(false)
        rows[i] = {
            panel = row,
            bar = bar,
            name = name,
            amount = amount,
            rate = rate,
            percent = percent,
            nameChars = 14,
            data = nil,
        }
    end
    return rows
end

local function SuiteHudIdForSide(sideName)
    return sideName == "friendly" and "dps_friendly" or "dps_enemy"
end

local function IsQuickHudLocked(sideName)
    if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.HudManager ~= nil then
        return ReplicatedSuite.HudManager:IsLocked(SuiteHudIdForSide(sideName)) == true
    end
    return sideName == "friendly" and D.State.config.friendlyLocked == true or D.State.config.enemyLocked == true
end

local function CreateFriendlyWindow()
    local window = CreateWindow("repdps_friendly_window", C.FRIENDLY_WINDOW_W, C.QUICK_WINDOW_H, false)
    -- The quick window is only the presentation container.  Its own hit target
    -- must be transparent so title text/background cannot block the independent
    -- drag surface.  Real child buttons/rows explicitly keep their own Pick.
    SetSelfMouseThrough(window, true)
    if ReplicatedSuiteEmbedded == true then window.rsHudOwner = "dps_friendly" end
    UIX.windows.friendly = window
    UIX.controls.friendlyHeaderBg = window:CreateColorDrawable(0.07, 0.17, 0.28, 0.97, "background")
    UIX.controls.friendlyHeaderBg:AddAnchor("TOPLEFT", window, 0, 0)
    UIX.controls.friendlyHeaderBg:SetExtent(C.FRIENDLY_WINDOW_W, C.HEADER_H)

    UIX.controls.modeButton = CreateButton(window, "repdps_mode_button", "PVP", 4, 3, 52, 23, 10)
    UIX.controls.damageButton = CreateButton(window, "repdps_page_damage", "伤害", 59, 3, 55, 23, 10)
    UIX.controls.takenButton = CreateButton(window, "repdps_page_taken", "承伤", 117, 3, 55, 23, 10)
    UIX.controls.healButton = CreateButton(window, "repdps_page_heal", "治疗", 175, 3, 55, 23, 10)
    UIX.controls.clearButton = CreateButton(window, "repdps_clear_button", "清空", 233, 3, 55, 23, 10)
    UIX.controls.configButton = ReplicatedSuiteEmbedded ~= true
        and CreateButton(window, "repdps_config_button", "设置", 291, 3, 56, 23, 10) or nil
    UIX.controls.friendlyCompactButton = CreateButton(window, "repdps_friendly_compact", "简", 320, 3, 28, 23, 9)

    UIX.controls.friendlyTitle = CreateLabel(window, "repdps_friendly_title", "友军", 7, 31, 340, 20, 12, ALIGN_LEFT)
    UIX.controls.friendlyDrag = AttachDragHeader(window, "repdps_friendly_drag", "friendly", 29, 27, function()
        return IsQuickHudLocked("friendly")
    end)
    SetMouseThrough(UIX.controls.friendlyTitle, true)
    UIX.rows.friendly = CreateQuickRows(window, "friendly")
    UIX.controls.friendlyFooter = CreateLabel(window, "repdps_friendly_footer", "", 5, C.QUICK_WINDOW_H - C.FOOTER_H, 245, 18, 9, ALIGN_LEFT)
    UIX.controls.friendlyPrev = CreateButton(window, "repdps_friendly_prev", "^", 250, C.QUICK_WINDOW_H - C.FOOTER_H, 28, 18, 9)
    UIX.controls.friendlyPage = CreateLabel(window, "repdps_friendly_page", "", 280, C.QUICK_WINDOW_H - C.FOOTER_H, 48, 18, 9, ALIGN_CENTER)
    UIX.controls.friendlyNext = CreateButton(window, "repdps_friendly_next", "v", 330, C.QUICK_WINDOW_H - C.FOOTER_H, 28, 18, 9)
    UIX.controls.friendlyResize = AttachResizeHandle(window, "repdps_friendly_resize", "friendly", function()
        return IsQuickHudLocked("friendly")
    end)
    return window
end

local function CreateEnemyWindow()
    local window = CreateWindow("repdps_enemy_window", C.ENEMY_WINDOW_W, C.QUICK_WINDOW_H, false)
    SetSelfMouseThrough(window, true)
    if ReplicatedSuiteEmbedded == true then window.rsHudOwner = "dps_enemy" end
    UIX.windows.enemy = window
    UIX.controls.enemyHeaderBg = window:CreateColorDrawable(0.27, 0.08, 0.10, 0.97, "background")
    UIX.controls.enemyHeaderBg:AddAnchor("TOPLEFT", window, 0, 0)
    UIX.controls.enemyHeaderBg:SetExtent(C.ENEMY_WINDOW_W, C.HEADER_H)
    UIX.controls.enemyTitle = CreateLabel(window, "repdps_enemy_title", "敌军", 7, 7, 184, 20, 13, ALIGN_LEFT)
    UIX.controls.enemyMirror = CreateLabel(window, "repdps_enemy_mirror", "PVP / 伤害", 7, 32, 292, 18, 10, ALIGN_LEFT)
    UIX.controls.enemyBossButton = CreateButton(window, "repdps_enemy_boss_target", "目标Boss", 249, 4, 51, 22, 9)
    UIX.controls.enemySettingsButton = ReplicatedSuiteEmbedded ~= true
        and CreateButton(window, "repdps_enemy_settings", "设置", 302, 4, 51, 22, 9) or nil
    UIX.controls.enemyCompactButton = CreateButton(window, "repdps_enemy_compact", "简", 324, 4, 28, 22, 9)
    UIX.controls.enemyDrag = AttachDragHeader(window, "repdps_enemy_drag", "enemy", 29, 27, function()
        return IsQuickHudLocked("enemy")
    end)
    SetMouseThrough(UIX.controls.enemyTitle, true)
    SetMouseThrough(UIX.controls.enemyMirror, true)
    UIX.rows.enemy = CreateQuickRows(window, "enemy")
    UIX.controls.enemyFooter = CreateLabel(window, "repdps_enemy_footer", "", 5, C.QUICK_WINDOW_H - C.FOOTER_H, 245, 18, 9, ALIGN_LEFT)
    UIX.controls.enemyPrev = CreateButton(window, "repdps_enemy_prev", "^", 250, C.QUICK_WINDOW_H - C.FOOTER_H, 28, 18, 9)
    UIX.controls.enemyPage = CreateLabel(window, "repdps_enemy_page", "", 280, C.QUICK_WINDOW_H - C.FOOTER_H, 48, 18, 9, ALIGN_CENTER)
    UIX.controls.enemyNext = CreateButton(window, "repdps_enemy_next", "v", 330, C.QUICK_WINDOW_H - C.FOOTER_H, 28, 18, 9)
    UIX.controls.enemyResize = AttachResizeHandle(window, "repdps_enemy_resize", "enemy", function()
        return IsQuickHudLocked("enemy")
    end)
    return window
end

-- “打印”只是调试辅助功能，绝不能因为控件创建失败而阻断 UI Shell，
-- 更不能让 Runtime 因 uiReady 未完成而停止注册 COMBAT_MSG。
-- 因此打印按钮采用可降级初始化：失败时隐藏可能残留的半成品控件，
-- 记录诊断并继续启动原有统计链路。
local function EnsureOptionalPrintButton(sideName)
    local isFriendly = sideName == "friendly"
    local window = UIX.windows[sideName]
    if window == nil then return false end

    local controlKey = isFriendly and "friendlyPrintButton" or "enemyPrintButton"
    local widgetId = isFriendly and "repdps_friendly_print" or "repdps_enemy_print"
    if UIX.controls[controlKey] ~= nil then return true end

    UIX.optionalPrintUnavailable = UIX.optionalPrintUnavailable or {}
    if UIX.optionalPrintUnavailable[sideName] == true then return false end

    -- CreateButton 会先注册逻辑 ID，再设置样式。若后续步骤抛错，注册表中
    -- 可能留下半成品；同一 Shell 代次不能再次使用相同 ID 创建控件。
    local existing = UIX.registry[widgetId]
    if existing ~= nil then
        pcall(function() existing:Show(false) end)
        UIX.optionalPrintUnavailable[sideName] = true
        if D.Diagnostics ~= nil and D.Diagnostics.AddWarning ~= nil then
            D.Diagnostics:AddWarning("ui_print_button", (isFriendly and "友军" or "敌军") .. "打印按钮存在未完成控件，本次界面已禁用打印功能")
        end
        return false
    end

    local ok, result = xpcall(function()
        if isFriendly then
            return CreateButton(window, widgetId, "打印", 220, 3, 39, 23, 10)
        end
        return CreateButton(window, widgetId, "打印", 196, 4, 51, 22, 9)
    end, Boot.SafeTraceback)

    if ok and result ~= nil then
        UIX.controls[controlKey] = result
        return true
    end

    local partial = UIX.registry[widgetId]
    if partial ~= nil then pcall(function() partial:Show(false) end) end
    UIX.optionalPrintUnavailable[sideName] = true
    if D.Diagnostics ~= nil and D.Diagnostics.AddError ~= nil then
        D.Diagnostics:AddError("ui:optional_print_button:" .. sideName, (isFriendly and "友军" or "敌军") .. "打印按钮创建失败：" .. tostring(result))
    end
    return false
end

local function EnsurePrintButtons()
    EnsureOptionalPrintButton("friendly")
    EnsureOptionalPrintButton("enemy")
end

local PRINT_CHOOSER_DEFAULT_W = 330
local PRINT_CHOOSER_DEFAULT_H = 118

local function DisableOptionalPrintUi()
    local partialWindow = UIX.windows.printChooser or UIX.registry["repdps_print_chooser"]
    if partialWindow ~= nil then pcall(function() partialWindow:Show(false) end) end
    UIX.windows.printChooser = nil
    UIX.printContext = nil
    UIX.optionalPrintChooserUnavailable = true
    for _, key in ipairs({ "printTitle", "printClose", "printHint", "printDamage", "printTaken", "printHeal" }) do
        local control = UIX.controls[key]
        if control ~= nil then pcall(function() control:Show(false) end) end
        UIX.controls[key] = nil
    end
    for _, key in ipairs({ "friendlyPrintButton", "enemyPrintButton" }) do
        local button = UIX.controls[key]
        if button ~= nil then pcall(function() button:Show(false) end) end
        UIX.controls[key] = nil
    end
end

-- The metric chooser is optional for the same reason as the two print buttons:
-- DebugLog tooling must never block UI shell completion or COMBAT_MSG setup.
local function EnsurePrintChooser()
    if UIX.windows.printChooser ~= nil and UIX.controls.printDamage ~= nil
        and UIX.controls.printTaken ~= nil and UIX.controls.printHeal ~= nil then return true end
    if UIX.optionalPrintChooserUnavailable == true then
        -- A normal hot reload calls EnsurePrintButtons before this helper. If a
        -- previous generation already disabled the chooser, hide any newly
        -- recreated orphan print buttons as well instead of leaving dead UI.
        DisableOptionalPrintUi()
        return false
    end

    local windowId = "repdps_print_chooser"
    local existing = UIX.registry[windowId]
    if existing ~= nil and UIX.windows.printChooser == nil then
        DisableOptionalPrintUi()
        return false
    end

    local ok, result = xpcall(function()
        local window = CreateWindow(windowId, PRINT_CHOOSER_DEFAULT_W, PRINT_CHOOSER_DEFAULT_H)
        UIX.windows.printChooser = window
        if window.SetCloseOnEscape ~= nil then window:SetCloseOnEscape(true) end
        UIX.controls.printTitle = CreateLabel(window, "repdps_print_title", "选择打印排行", 10, 8, 270, 22, 13, ALIGN_LEFT)
        UIX.controls.printClose = CreateButton(window, "repdps_print_close", "X", 294, 6, 27, 24, 10)
        UIX.controls.printHint = CreateLabel(window, "repdps_print_hint", "写入 DebugLog，最多前10名", 10, 34, 310, 18, 9, ALIGN_LEFT)
        UIX.controls.printDamage = CreateButton(window, "repdps_print_damage", "伤害", 10, 64, 96, 28, 10)
        UIX.controls.printTaken = CreateButton(window, "repdps_print_taken", "承伤", 117, 64, 96, 28, 10)
        UIX.controls.printHeal = CreateButton(window, "repdps_print_heal", "治疗", 224, 64, 96, 28, 10)
        window:Show(false)
        return true
    end, Boot.SafeTraceback)

    if ok and result == true then return true end
    DisableOptionalPrintUi()
    if D.Diagnostics ~= nil and D.Diagnostics.AddError ~= nil then
        D.Diagnostics:AddError("ui:print_chooser", "打印选择窗口创建失败：" .. tostring(result))
    end
    return false
end

-- The back button is optional for shell safety: a control creation failure must
-- never block COMBAT_MSG registration. Cold starts and reused shells both call
-- this helper, so v0.2.14 UI objects can gain navigation without a schema bump.
local function EnsureDetailBackButton()
    if UIX.windows.detail == nil then return false end
    if UIX.controls.detailBack ~= nil then return true end
    local widgetId = "repdps_detail_back"
    local existing = UIX.registry[widgetId]
    if existing ~= nil then
        pcall(function() existing:Show(false) end)
        return false
    end
    local ok, result = xpcall(function()
        return CreateButton(UIX.windows.detail, widgetId, "<", 8, 4, 38, 23, 11)
    end, Boot.SafeTraceback)
    if ok and result ~= nil then
        UIX.controls.detailBack = result
        result:Show(false)
        return true
    end
    local partial = UIX.registry[widgetId]
    if partial ~= nil then pcall(function() partial:Show(false) end) end
    if D.Diagnostics ~= nil and D.Diagnostics.AddError ~= nil then
        D.Diagnostics:AddError("ui:detail_back", "详情返回按钮创建失败：" .. tostring(result))
    end
    return false
end

-- Target filtering and Boss focus are optional UI additions. The underlying
-- analysis state is independent from these controls, so a failed button creation
-- can never block the combat event pipeline or the original detail editor.
local function EnsureDetailAnalysisButtons()
    if UIX.windows.detail == nil then return false end
    local specs = {
        { key = "detailExcludeTarget", id = "repdps_detail_exclude_target", text = "排除目标数据" },
        { key = "detailBossTarget", id = "repdps_detail_boss_target", text = "设为Boss" },
    }
    local allOk = true
    for _, spec in ipairs(specs) do
        if UIX.controls[spec.key] == nil then
            local existing = UIX.registry[spec.id]
            if existing ~= nil then
                pcall(function() existing:Show(false) end)
                allOk = false
            else
                local ok, result = xpcall(function()
                    return CreateButton(UIX.windows.detail, spec.id, spec.text, 10, 354, 220, 24, 10)
                end, Boot.SafeTraceback)
                if ok and result ~= nil then
                    UIX.controls[spec.key] = result
                    result:Show(false)
                else
                    local partial = UIX.registry[spec.id]
                    if partial ~= nil then pcall(function() partial:Show(false) end) end
                    allOk = false
                    if D.Diagnostics ~= nil and D.Diagnostics.AddError ~= nil then
                        D.Diagnostics:AddError("ui:detail_analysis_button:" .. spec.key, tostring(result))
                    end
                end
            end
        end
    end
    return allOk
end

local function EnsureDetailRowsInteractive()
    for index, row in ipairs(UIX.detailRows or {}) do
        local panel = row and row.panel or nil
        if panel ~= nil then
            local ok, err = pcall(function()
                panel:Enable(true)
                panel:Clickable(true)
                if panel.EnablePick ~= nil then panel:EnablePick(true) end
            end)
            if not ok and D.Diagnostics ~= nil and D.Diagnostics.AddError ~= nil then
                D.Diagnostics:AddError("ui:detail_row_" .. tostring(index), "详情行点击启用失败：" .. tostring(err))
            end
        end
    end
end

local function CreateConfigPage(parent, id)
    local page = CreatePanel(parent, id, 8, 76, C.CONFIG_W - 16, C.CONFIG_H - 112)
    page.repdpsRows = {}
    page:Show(false)
    return page
end

local function CreateConfigWindow()
    local window = CreateWindow("repdps_config_window", C.CONFIG_W, C.CONFIG_H)
    UIX.windows.config = window
    window:SetCloseOnEscape(true)
    local headerBg = window:CreateColorDrawable(0.07, 0.16, 0.26, 0.98, "background")
    headerBg:AddAnchor("TOPLEFT", window, 0, 0)
    headerBg:SetExtent(C.CONFIG_W, 44)
    UIX.controls.configHeaderBg = headerBg
    UIX.controls.configTitle = CreateLabel(window, "repdps_config_title", "Replicated DPS · 作者 Replicated", 10, 7, 470, 24, 15, ALIGN_LEFT)
    UIX.controls.configClose = CreateButton(window, "repdps_config_close", "X", 526, 7, 26, 24, 11)
    UIX.controls.configDrag = AttachDragHeader(window, "repdps_config_drag", "config", 0, 42, function() return false end)
    UIX.controls.configDrag:SetExtent(500, 42)

    local tabNames = { "运行", "显示", "准确率", "名单", "高级", "诊断" }
    UIX.controls.tabs = {}
    for i = 1, 6 do
        local button = CreateButton(window, "repdps_config_tab_" .. tostring(i), tabNames[i], 8 + (i - 1) * 90, 48, 84, 24, 10)
        UIX.controls.tabs[i] = button
    end

    UIX.pages.general = CreateConfigPage(window, "repdps_page_general")
    UIX.pages.display = CreateConfigPage(window, "repdps_page_display")
    UIX.pages.accuracy = CreateConfigPage(window, "repdps_page_accuracy")
    UIX.pages.rules = CreateConfigPage(window, "repdps_page_rules")
    UIX.pages.advanced = CreateConfigPage(window, "repdps_page_advanced")
    UIX.pages.diagnostics = CreateConfigPage(window, "repdps_page_diagnostics")

    local function AddToggle(page, id, labelText, y)
        local label = CreateLabel(page, id .. "_label", labelText, 10, y + 2, 330, 20, 11, ALIGN_LEFT)
        local button = CreateButton(page, id, "", 365, y, 150, 22, 10)
        page.repdpsRows[#page.repdpsRows + 1] = { kind = "toggle", label = label, button = button }
        return button
    end

    local function AddStepper(page, id, labelText, y)
        local label = CreateLabel(page, id .. "_label", labelText, 10, y + 2, 310, 20, 11, ALIGN_LEFT)
        local minus = CreateButton(page, id .. "_minus", "-", 350, y, 36, 22, 10)
        local value = CreateLabel(page, id .. "_value", "", 390, y + 1, 82, 20, 10, ALIGN_CENTER)
        local plus = CreateButton(page, id .. "_plus", "+", 476, y, 36, 22, 10)
        local control = { minus = minus, value = value, plus = plus }
        page.repdpsRows[#page.repdpsRows + 1] = { kind = "stepper", label = label, control = control }
        return control
    end

    UIX.controls.enabled = AddToggle(UIX.pages.general, "repdps_cfg_enabled", "启用战斗统计", 12)
    UIX.controls.showFriendly = AddToggle(UIX.pages.general, "repdps_cfg_show_friendly", "显示友军窗口", 42)
    UIX.controls.showEnemy = AddToggle(UIX.pages.general, "repdps_cfg_show_enemy", "显示敌军窗口", 72)
    UIX.controls.defaultMode = AddToggle(UIX.pages.general, "repdps_cfg_mode", "当前显示模式", 102)
    UIX.controls.defaultPage = AddToggle(UIX.pages.general, "repdps_cfg_page", "当前统计页面", 132)
    UIX.controls.friendlyLocked = AddToggle(UIX.pages.general, "repdps_cfg_friend_lock", "锁定友军窗口", 162)
    UIX.controls.enemyLocked = AddToggle(UIX.pages.general, "repdps_cfg_enemy_lock", "锁定敌军窗口", 192)
    UIX.controls.scopeMode = AddToggle(UIX.pages.general, "repdps_cfg_scope", "数据范围（团队 / 目标+团队）", 222)
    UIX.controls.resetPositions = CreateButton(UIX.pages.general, "repdps_cfg_reset_positions", "恢复全部UI默认位置", 10, 268, 210, 26, 10)
    UIX.controls.restoreClear = CreateButton(UIX.pages.general, "repdps_cfg_restore_clear", "恢复上一次清空", 230, 268, 180, 26, 10)

    UIX.controls.compactMode = AddToggle(UIX.pages.display, "repdps_cfg_compact", "简化模式（只显示伤害排名）", 12)
    UIX.controls.rankingOpacity = AddStepper(UIX.pages.display, "repdps_cfg_opacity", "排行榜透明度", 40)
    UIX.controls.launcherOpacity = AddStepper(UIX.pages.display, "repdps_cfg_launcher_opacity", "顶部入口透明度", 68)
    UIX.controls.rankingScale = AddStepper(UIX.pages.display, "repdps_cfg_scale", "排行榜整体缩放", 96)
    UIX.controls.displayRows = AddStepper(UIX.pages.display, "repdps_cfg_rows", "排行榜显示人数上限", 124)
    UIX.controls.alwaysSelf = AddToggle(UIX.pages.display, "repdps_cfg_always_self", "始终显示自己", 152)
    UIX.controls.abbreviate = AddToggle(UIX.pages.display, "repdps_cfg_abbreviate", "数值缩写（K/M）", 180)
    UIX.controls.showPercent = AddToggle(UIX.pages.display, "repdps_cfg_percent", "显示本方占比", 208)
    UIX.controls.showSuspect = AddToggle(UIX.pages.display, "repdps_cfg_suspect", "显示推断/手动/名单/同名标记", 236)
    UIX.controls.showPending = AddToggle(UIX.pages.display, "repdps_cfg_pending", "显示待确认摘要", 264)
    UIX.controls.showClosure = AddToggle(UIX.pages.display, "repdps_cfg_closure", "显示数据闭合率", 292)

    UIX.controls.fixedAccuracyPolicy = CreateLabel(UIX.pages.accuracy, "repdps_cfg_fixed_policy",
        "固定统计策略：数据优先收录；未确认身份先临时计入，后续可人工纠错。",
        10, 12, 510, 24, 10, ALIGN_LEFT)
    UIX.controls.chineseNpc = AddToggle(UIX.pages.accuracy, "repdps_cfg_chinese_npc", "中文名称视为NPC（RU汉化）", 48)
    UIX.controls.socialPrior = AddToggle(UIX.pages.accuracy, "repdps_cfg_social_prior", "好友/本公会作为友军软先验", 78)
    UIX.controls.thirdParty = AddToggle(UIX.pages.accuracy, "repdps_cfg_third", "显示第三方摘要", 108)
    UIX.controls.capabilityStatus = CreateLabel(UIX.pages.accuracy, "repdps_cfg_capability_status",
        "API能力限制：未公开任意玩家公会ID和宠物/召唤物主人；正式统计不会猜测传播或强行合并。",
        10, 150, 510, 42, 10, ALIGN_LEFT)
    UIX.controls.accuracyHelp = CreateLabel(UIX.pages.accuracy, "repdps_accuracy_help",
        "有效治疗传播同阵营关系；我方造成/受到的有效伤害传播敌军关系，但不猜玩家或NPC。\nPVE事件归属只影响本次统计落点，不永久改变阵营；冲突只提示人工复核，不自动翻转身份。",
        10, 210, 510, 60, 10, ALIGN_LEFT)

    UIX.controls.rulesSummary = CreateLabel(UIX.pages.rules, "repdps_rules_summary", "", 10, 8, 510, 36, 10, ALIGN_LEFT)
    UIX.ruleRows = {}
    for i = 1, 8 do
        local button = CreateButton(UIX.pages.rules, "repdps_rule_row_" .. tostring(i), "", 10, 48 + (i - 1) * 27, 510, 24, 9)
        UIX.ruleRows[i] = { button = button, ruleId = nil }
    end
    UIX.controls.rulesPrev = CreateButton(UIX.pages.rules, "repdps_rules_prev", "上一页", 10, 268, 72, 24, 9)
    UIX.controls.rulesPage = CreateLabel(UIX.pages.rules, "repdps_rules_page", "0/0", 88, 270, 90, 20, 9, ALIGN_CENTER)
    UIX.controls.rulesNext = CreateButton(UIX.pages.rules, "repdps_rules_next", "下一页", 184, 268, 72, 24, 9)
    UIX.controls.rulesToggle = CreateButton(UIX.pages.rules, "repdps_rules_toggle", "禁用规则", 10, 300, 112, 25, 9)
    UIX.controls.rulesDelete = CreateButton(UIX.pages.rules, "repdps_rules_delete", "删除所选", 128, 300, 112, 25, 9)
    UIX.controls.rulesRestoreSession = CreateButton(UIX.pages.rules, "repdps_rules_restore_session", "恢复本次忽略", 246, 300, 128, 25, 9)
    UIX.controls.rulesClear = CreateButton(UIX.pages.rules, "repdps_rules_clear", "清空全部名单", 380, 300, 128, 25, 9)
    UIX.controls.rulesHelp = CreateLabel(UIX.pages.rules, "repdps_rules_help",
        "稳定单位ID优先，缺少ID时按名称匹配；同名冲突会暂停名称规则。误排除可在此禁用或删除。",
        10, 334, 510, 38, 9, ALIGN_LEFT)

    UIX.controls.personalWindow = AddStepper(UIX.pages.advanced, "repdps_cfg_personal_window", "个人有效时间窗口（秒）", 12)
    UIX.controls.sideWindow = AddStepper(UIX.pages.advanced, "repdps_cfg_side_window", "阵营共享时间窗口（秒）", 42)
    UIX.controls.uiRefresh = AddStepper(UIX.pages.advanced, "repdps_cfg_ui_refresh", "UI刷新间隔（毫秒）", 72)
    UIX.controls.rosterRefresh = AddStepper(UIX.pages.advanced, "repdps_cfg_roster_refresh", "团队扫描间隔（毫秒）", 102)
    UIX.controls.rawLimit = AddStepper(UIX.pages.advanced, "repdps_cfg_raw_limit", "原始事件缓存条数", 162)
    UIX.controls.diagEnabled = AddToggle(UIX.pages.advanced, "repdps_cfg_diag_enabled", "诊断模式", 192)

    UIX.controls.diagStatus = CreateLabel(UIX.pages.diagnostics, "repdps_diag_status", "", 10, 10, 515, 230, 10, ALIGN_LEFT)
    UIX.controls.diagRebuild = CreateButton(UIX.pages.diagnostics, "repdps_diag_rebuild", "刷新并修复UI", 10, 250, 150, 26, 10)
    UIX.controls.diagSave = CreateButton(UIX.pages.diagnostics, "repdps_diag_save", "立即保存", 170, 250, 120, 26, 10)
    UIX.controls.diagRescan = CreateButton(UIX.pages.diagnostics, "repdps_diag_rescan", "立即扫描团队/视野", 300, 250, 200, 26, 10)
    UIX.controls.diagShardAudit = CreateButton(UIX.pages.diagnostics, "repdps_diag_shard_audit", "分片安全检查", 10, 282, 220, 26, 10)
    UIX.controls.diagShardClear = CreateButton(UIX.pages.diagnostics, "repdps_diag_shard_clear", "清理分片缓存", 240, 282, 260, 26, 10)

    UIX.controls.configFooter = CreateLabel(window, "repdps_config_footer", "", 9, C.CONFIG_H - 27, 520, 18, 9, ALIGN_LEFT)
    window:Show(false)
    return window
end

local CONFIRM_DEFAULT_W = 420
local CONFIRM_DEFAULT_H = 188

local function CreateConfirmWindow()
    local window = CreateWindow("repdps_confirm_window", CONFIRM_DEFAULT_W, CONFIRM_DEFAULT_H)
    UIX.windows.confirm = window
    window:SetCloseOnEscape(true)
    UIX.controls.confirmTitle = CreateLabel(window, "repdps_confirm_title", "确认清空", 12, 10, CONFIRM_DEFAULT_W - 24, 22, 14, ALIGN_LEFT)
    -- The real client does not reliably clip long label text.  Use one bounded
    -- label per sentence instead of one long multi-line label.
    UIX.controls.confirmLine1 = CreateLabel(window, "repdps_confirm_line_1", "", 12, 42, CONFIRM_DEFAULT_W - 24, 18, 10, ALIGN_LEFT)
    UIX.controls.confirmLine2 = CreateLabel(window, "repdps_confirm_line_2", "", 12, 65, CONFIRM_DEFAULT_W - 24, 18, 10, ALIGN_LEFT)
    UIX.controls.confirmLine3 = CreateLabel(window, "repdps_confirm_line_3", "", 12, 88, CONFIRM_DEFAULT_W - 24, 18, 10, ALIGN_LEFT)
    UIX.controls.confirmYes = CreateButton(window, "repdps_confirm_yes", "确定清空", 88, 137, 105, 27, 10)
    UIX.controls.confirmNo = CreateButton(window, "repdps_confirm_no", "取消", 227, 137, 105, 27, 10)
    window:Show(false)
    return window
end

local DETAIL_ROWS = 9
local DETAIL_DEFAULT_W = 640
local DETAIL_DEFAULT_H = 480
local DETAIL_ROWS_Y = 146

local function CreateDetailWindow()
    local window = CreateWindow("repdps_detail_window", DETAIL_DEFAULT_W, DETAIL_DEFAULT_H)
    UIX.windows.detail = window
    window:SetCloseOnEscape(true)
    local headerBg = window:CreateColorDrawable(0.12, 0.12, 0.22, 0.98, "background")
    headerBg:AddAnchor("TOPLEFT", window, 0, 0)
    headerBg:SetExtent(DETAIL_DEFAULT_W, 32)
    UIX.controls.detailHeaderBg = headerBg
    UIX.controls.detailTitle = CreateLabel(window, "repdps_detail_title", "单位详情", 10, 6, 405, 22, 14, ALIGN_LEFT)
    UIX.controls.detailClose = CreateButton(window, "repdps_detail_close", "X", 428, 4, 26, 23, 11)
    UIX.controls.detailDrag = AttachDragHeader(window, "repdps_detail_drag", "detail", 0, 32, function() return false end)
    UIX.controls.detailDrag:SetExtent(420, 32)

    -- Keep metadata on short, independent lines.  A single long summary label
    -- previously painted beyond the right edge in the real client.
    UIX.controls.detailType = CreateLabel(window, "repdps_detail_type", "", 10, 36, 440, 18, 10, ALIGN_LEFT)
    UIX.controls.detailRelation = CreateLabel(window, "repdps_detail_relation", "", 10, 55, 440, 18, 10, ALIGN_LEFT)
    UIX.controls.detailTotals = CreateLabel(window, "repdps_detail_totals", "", 10, 74, 440, 18, 10, ALIGN_LEFT)

    UIX.controls.detailAbility = CreateButton(window, "repdps_detail_ability", "技能", 10, 98, 100, 23, 10)
    UIX.controls.detailCounterpart = CreateButton(window, "repdps_detail_counterpart", "目标", 116, 98, 100, 23, 10)
    UIX.controls.detailPrev = CreateButton(window, "repdps_detail_prev", "^", 224, 98, 26, 23, 9)
    UIX.controls.detailPage = CreateLabel(window, "repdps_detail_page", "0/0", 254, 100, 160, 20, 9, ALIGN_CENTER)
    UIX.controls.detailNext = CreateButton(window, "repdps_detail_next", "v", 418, 98, 26, 23, 9)
    UIX.controls.detailHint = CreateLabel(window, "repdps_detail_hint", "先手动纠错；确认无误后可保存到名单，下次直接识别。", 10, 124, 460, 18, 9, ALIGN_LEFT)

    UIX.detailRows = {}
    for i = 1, DETAIL_ROWS do
        local id = string.format("repdps_detail_row_%02d", i)
        local row = CreatePanel(window, id, 10, DETAIL_ROWS_Y + (i - 1) * 23, 440, 21)
        row:Enable(true)
        row:Clickable(true)
        if row.EnablePick ~= nil then row:EnablePick(true) end
        row.repdpsBg = CreateBackground(row, 0.075, 0.085, 0.11, 0.88)
        local bar = CreatePanel(row, id .. "_bar", 0, 0, 1, 21)
        bar.repdpsBg = CreateBackground(bar, 0.30, 0.24, 0.55, 0.75)
        SetMouseThrough(bar, true)
        local name = CreateLabel(row, id .. "_name", "", 5, 1, 272, 19, 10, ALIGN_LEFT)
        local value = CreateLabel(row, id .. "_value", "", 282, 1, 152, 19, 10, ALIGN_RIGHT)
        row:Show(false)
        UIX.detailRows[i] = { panel = row, bar = bar, name = name, value = value, data = nil }
    end

    UIX.controls.detailFriendly = CreateButton(window, "repdps_detail_mark_friendly", "设为友军", 10, 382, 86, 24, 9)
    UIX.controls.detailEnemy = CreateButton(window, "repdps_detail_mark_enemy", "设为敌军", 102, 382, 86, 24, 9)
    UIX.controls.detailPlayer = CreateButton(window, "repdps_detail_mark_player", "设为玩家", 194, 382, 86, 24, 9)
    UIX.controls.detailNpc = CreateButton(window, "repdps_detail_mark_npc", "设为NPC", 286, 382, 86, 24, 9)
    UIX.controls.detailOther = CreateButton(window, "repdps_detail_mark_other", "召唤/物件", 378, 382, 92, 24, 9)
    UIX.controls.detailIgnore = CreateButton(window, "repdps_detail_mark_ignore", "忽略实体（本次）", 10, 412, 224, 24, 10)
    UIX.controls.detailAuto = CreateButton(window, "repdps_detail_mark_auto", "恢复自动判断", 240, 412, 230, 24, 10)
    UIX.controls.detailSaveRule = CreateButton(window, "repdps_detail_save_rule", "保存当前到名单", 10, 442, 224, 24, 10)
    UIX.controls.detailRemoveRule = CreateButton(window, "repdps_detail_remove_rule", "从名单移除", 240, 442, 230, 24, 10)
    window:Show(false)
    return window
end

local function PageLabel(page)
    if page == "TAKEN" then return "承伤" end
    if page == "HEAL" then return "治疗" end
    return "伤害"
end

function UIX:SetConfigPage(index)
    self.activeConfigPage = U.Clamp(index, 1, 6)
    if ReplicatedSuiteEmbedded == true and self.windows.config == nil then return true end
    local order = { self.pages.general, self.pages.display, self.pages.accuracy, self.pages.rules, self.pages.advanced, self.pages.diagnostics }
    local names = { "运行", "显示", "准确率", "名单", "高级", "诊断" }
    for i = 1, 6 do
        order[i]:Show(i == self.activeConfigPage)
        SetFittedControlText(self.controls.tabs[i], (i == self.activeConfigPage and "[" or "") .. names[i] .. (i == self.activeConfigPage and "]" or ""), 10, 8)
    end
    self:RefreshConfig()
end

function UIX:SetMode(mode)
    D.State.config.currentMode = mode == "PVE" and "PVE" or "PVP"
    self.rankingOffsets.friendly = 0
    self.rankingOffsets.enemy = 0
    D.MarkConfigDirty()
    D.MarkViewDirty()
    self:RefreshControls()
    self:RefreshQuickWindows()
end

function UIX:SetPage(page)
    local valid = { DAMAGE = true, TAKEN = true, HEAL = true }
    if not valid[page] then page = "DAMAGE" end
    D.State.config.currentPage = page
    self.rankingOffsets.friendly = 0
    self.rankingOffsets.enemy = 0
    D.MarkConfigDirty()
    D.MarkLayoutDirty()
    D.MarkViewDirty()
    self:RefreshControls()
    self:RefreshQuickWindows()
end

function UIX:GetQuickPage()
    if D.State.config.compactMode == true then return "DAMAGE" end
    return D.State.config.currentPage
end

function UIX:RefreshControls()
    if self.controls.modeButton == nil then return end
    SetFittedControlText(self.controls.modeButton, D.State.config.currentMode, 10, 8)
    local selected = self:GetQuickPage()
    SetFittedControlText(self.controls.damageButton, selected == "DAMAGE" and "[伤害]" or "伤害", 10, 8)
    SetFittedControlText(self.controls.takenButton, selected == "TAKEN" and "[承伤]" or "承伤", 10, 8)
    SetFittedControlText(self.controls.healButton, selected == "HEAL" and "[治疗]" or "治疗", 10, 8)
    local compactText = D.State.config.compactMode == true and "全" or "简"
    if self.controls.friendlyCompactButton ~= nil then SetFittedControlText(self.controls.friendlyCompactButton, compactText, 9, 8) end
    if self.controls.enemyCompactButton ~= nil then SetFittedControlText(self.controls.enemyCompactButton, compactText, 9, 8) end
end

local function BoolText(value)
    return value and "开" or "关"
end

local function IsDpsModuleEnabled()
    if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.ModuleManager ~= nil then
        return ReplicatedSuite.ModuleManager:IsEnabled("dps") == true
    end
    return D.State ~= nil and D.State.config ~= nil and D.State.config.enabled == true
end

-- Chat diagnostics (2026-08-24): print the same key lines the diagnostics
-- page shows straight into chat, so the user can copy-paste them back instead
-- of transcribing the UI. Click-triggered only, never polled. Runs BEFORE the
-- roster scan so pending/third-party counters still show the pre-rescan state
-- (the scan replays pending and would hide the evidence). Fully guarded: any
-- failure prints the error to chat instead of silently dropping the output.
local function IsLocalPlayerNameInUi(name)
    local text = U.Trim(tostring(name or ""))
    if text == "" then return false end
    local normalized = U.NormalizeName(text)
    return normalized ~= "" and (normalized == U.NormalizeName(D.Identity.playerName)
        or normalized == U.NormalizeName(D.Identity.playerNameWithWorld))
end

function UIX:PrintDiagnosticsToChat()
    local ok, result = xpcall(function()
        if D.Boot == nil or type(D.Boot.SafeChat) ~= "function" then return false end
        local diag = D.Diagnostics
        local counters = type(diag) == "table" and diag.counters or {}
        local runtime = D.Runtime
        local c = D.State and D.State.config or {}

        local eventTransport = runtime ~= nil and runtime.eventTransport or "未启动"
        local rawEvents = tonumber(counters.rawEvents) or 0
        local rate = runtime ~= nil and runtime.combatEventRate or 0
        local pending = 0
        if D.EventStore ~= nil and type(D.EventStore.pending) == "table" then pending = #D.EventStore.pending end
        local thirdParty = tonumber(counters.thirdPartyEvents) or 0

        local rosterCount = 0
        if type(Actors.GetRosterCount) == "function" then rosterCount = Actors:GetRosterCount() end
        local layoutName = runtime ~= nil and runtime.teamLayoutName or "unknown"
        local aliasCount = tonumber(counters.rosterAliasCount) or 0
        local aliasConflicts = tonumber(counters.rosterAliasConflicts) or 0
        local schemeCount = 0
        if runtime ~= nil and type(runtime.teamSchemeIndexes) == "table" then schemeCount = #runtime.teamSchemeIndexes end

        -- Global (team-row) route counters: registered? how many rows arrived?
        local globalRegistered = runtime ~= nil and runtime.globalCombatHandler ~= nil
        local globalRows = tonumber(counters.globalCombatRows) or 0
        local globalHosts = type(runtime) == "table" and runtime.globalCombatHosts or nil
        local globalHostsText = type(globalHosts) == "table" and #globalHosts > 0
            and table.concat(globalHosts, "+") or (globalRegistered and "?" or "无")
        local globalSample = type(runtime) == "table" and runtime.globalCombatSample or nil
        local globalSampleText = "（空）"
        if type(globalSample) == "table" and #globalSample > 0 then
            local parts = {}
            for _, row in ipairs(globalSample) do
                parts[#parts + 1] = tostring(row.eventType) .. " " .. tostring(row.source) .. "→" .. tostring(row.target)
                    .. " " .. tostring(row.amount)
            end
            globalSampleText = table.concat(parts, " | ")
        end

        -- Recent event sample (single line, pipe-separated).
        local events = D.EventStore and D.EventStore.sessionEvents or nil
        local sampleText = "（空）"
        if type(events) == "table" and #events > 0 then
            local parts = {}
            local startIndex = math.max(1, #events - 7)
            for index = startIndex, #events do
                local row = events[index]
                if type(row) == "table" then
                    local sourceName = tostring(row.sourceName or row[10] or "?")
                    local targetName = tostring(row.targetName or row[11] or "?")
                    local status = tostring(row.classificationStatus or row[18] or "?")
                    local amount = tonumber(row.amount or row[14]) or 0
                    parts[#parts + 1] = tostring(row.eventType or row[6] or "?")
                        .. " " .. sourceName .. "→" .. targetName
                        .. " " .. tostring(amount) .. " " .. status
                end
            end
            if #parts > 0 then sampleText = table.concat(parts, " | ") end
        end

        -- One single line so the user can copy-paste the whole diagnostics in a
        -- single chat message.
        local line = "[DPS诊断] 通道=" .. tostring(eventTransport)
            .. " 原始事件=" .. tostring(rawEvents)
            .. " 负载=" .. string.format("%.0f", tonumber(rate) or 0)
            .. " 待确认=" .. tostring(pending)
            .. " 第三方=" .. tostring(thirdParty)
            .. " 模式=" .. tostring(c.currentMode or "PVP")
            .. " 范围=" .. tostring(c.scopeMode or "team")
            .. " 被拒事件=" .. tostring(tonumber(counters.scopeContextOnlyEvents) or 0)
            .. " 被拒指标=" .. tostring(tonumber(counters.scopeContextOnlyMetrics) or 0)
            .. " 名单=" .. tostring(rosterCount)
            .. " 布局=" .. tostring(layoutName)
            .. " 令牌族=" .. tostring(schemeCount)
            .. " 别名=" .. tostring(aliasCount)
            .. " 冲突=" .. tostring(aliasConflicts)
            .. " 全局路=" .. (globalRegistered and "已注册(" .. globalHostsText .. ")" or "未注册")
            .. " 全局行数=" .. tostring(globalRows)
        D.Boot.SafeChat(line)

        local lastCombat = type(diag) == "table" and diag.lastCombatSample or nil
        if type(lastCombat) == "table" then
            local relSource, relTarget = "?", "?"
            local entities = D.Entities
            if type(entities) == "table" and type(entities.GetRelationAt) == "function" then
                local sourceRef = lastCombat.sourceEntity or (type(entities.GetByKey) == "function"
                    and entities:GetByKey(lastCombat.sourceKey) or nil)
                local targetRef = lastCombat.targetEntity or (type(entities.GetByKey) == "function"
                    and entities:GetByKey(lastCombat.targetKey) or nil)
                if type(sourceRef) == "table" then relSource = tostring(entities:GetRelationAt(sourceRef, lastCombat.timestamp)) end
                if type(targetRef) == "table" then relTarget = tostring(entities:GetRelationAt(targetRef, lastCombat.timestamp)) end
            end
            D.Boot.SafeChat("[DPS诊断] 最近事件：" .. tostring(lastCombat.eventType or "")
                .. " | " .. tostring(lastCombat.sourceName or "") .. " → " .. tostring(lastCombat.targetName or "")
                .. " | " .. tostring(lastCombat.abilityName or "") .. " | " .. tostring(lastCombat.amount or 0)
                .. " | " .. tostring(lastCombat.classificationStatus or "")
                .. " | 关系 " .. tostring(relSource) .. "→" .. tostring(relTarget)
                .. " | 绑定 " .. tostring(lastCombat.sourceBindingQuality or "?")
                .. "/" .. tostring(lastCombat.targetBindingQuality or "?"))
        end
        local lastError = type(diag) == "table" and diag.errors and diag.errors[#diag.errors] or nil
        if lastError ~= nil then
            D.Boot.SafeChat("[DPS诊断] 最近错误：" .. tostring(lastError.message or tostring(lastError)))
        end
        D.Boot.SafeChat("[DPS诊断] 最近事件样本：" .. sampleText)
        D.Boot.SafeChat("[DPS诊断] 全局路样本：" .. globalSampleText)
        -- Live-client lesson 2026-08-24: the client only delivers TEAM damage
        -- rows when the game option "伤害量/治疗量显示目标" is set to 全部.
        -- If the global route is live but no TEAM->NPC damage rows appear in
        -- the sample, point the user at that game setting.
        if globalRegistered and globalRows > 0 and type(globalSample) == "table" and #globalSample > 0 then
            local hasTeamDamage = false
            for _, row in ipairs(globalSample) do
                local et = tostring(row.eventType or "")
                if string.find(et, "DAMAGE", 1, true) ~= nil and not IsLocalPlayerNameInUi(row.source) then
                    hasTeamDamage = true
                    break
                end
            end
            if not hasTeamDamage then
                D.Boot.SafeChat("[DPS诊断] 提示：全局路有事件但未见团员→怪伤害——请检查游戏设置：伤害量/治疗量显示目标 = 全部（否则客户端不下发团队成员伤害事件）。")
            end
        end
        return true
    end, Boot.SafeTraceback)
    if not ok and D.Boot ~= nil and type(D.Boot.SafeChat) == "function" then
        D.Boot.SafeChat("[DPS诊断] 输出失败：" .. tostring(result))
    end
    return ok
end

function UIX:RefreshConfig()
    local c = D.State.config
    if self.controls.enabled == nil then return end
    local moduleEnabled = IsDpsModuleEnabled()
    if self.controls.configTitle ~= nil then
        self.controls.configTitle:SetText(moduleEnabled
            and "Replicated DPS · 作者 Replicated"
            or "Replicated DPS · 当前模块未启用（静态设置可修改）")
    end
    SetFittedControlText(self.controls.enabled, moduleEnabled and "已启用" or "已关闭", 10, 8)
    SetFittedControlText(self.controls.showFriendly, BoolText(c.showFriendly), 10, 8)
    SetFittedControlText(self.controls.showEnemy, BoolText(c.showEnemy), 10, 8)
    SetFittedControlText(self.controls.defaultMode, c.currentMode, 10, 8)
    SetFittedControlText(self.controls.defaultPage, PageLabel(c.currentPage), 10, 8)
    SetFittedControlText(self.controls.friendlyLocked, BoolText(IsQuickHudLocked("friendly")), 10, 8)
    SetFittedControlText(self.controls.enemyLocked, BoolText(IsQuickHudLocked("enemy")), 10, 8)
    if self.controls.scopeMode ~= nil then
        SetFittedControlText(self.controls.scopeMode,
            c.scopeMode == "team" and "团队" or "目标+团队", 10, 8)
    end
    SetFittedControlText(self.controls.compactMode, BoolText(c.compactMode), 10, 8)
    SetFittedControlText(self.controls.rankingOpacity.value, tostring(math.floor((tonumber(c.rankingOpacity) or 1.00) * 100 + 0.5)) .. "%", 10, 8)
    SetFittedControlText(self.controls.launcherOpacity.value, tostring(math.floor((tonumber(c.launcherOpacity) or 1.00) * 100 + 0.5)) .. "%", 10, 8)
    SetFittedControlText(self.controls.rankingScale.value, tostring(math.floor((tonumber(c.rankingScale) or 1.00) * 100 + 0.5)) .. "%", 10, 8)
    SetFittedControlText(self.controls.displayRows.value, tostring(c.displayRows), 10, 8)
    SetFittedControlText(self.controls.alwaysSelf, BoolText(c.alwaysShowSelf), 10, 8)
    SetFittedControlText(self.controls.abbreviate, BoolText(c.abbreviateNumbers), 10, 8)
    SetFittedControlText(self.controls.showPercent, BoolText(c.showPercent), 10, 8)
    SetFittedControlText(self.controls.showSuspect, BoolText(c.showSuspect), 10, 8)
    SetFittedControlText(self.controls.showPending, BoolText(c.showPendingSummary), 10, 8)
    SetFittedControlText(self.controls.showClosure, BoolText(c.showClosure), 10, 8)
    SetFittedControlText(self.controls.chineseNpc, BoolText(c.inferChineseNamesAsNpc), 10, 8)
    SetFittedControlText(self.controls.socialPrior, BoolText(c.useSocialFriendlyPriors), 10, 8)
    SetFittedControlText(self.controls.thirdParty, BoolText(c.showThirdPartySummary), 10, 8)
    SetFittedControlText(self.controls.personalWindow.value, string.format("%.0f", c.personalWindowMs / 1000), 10, 8)
    SetFittedControlText(self.controls.sideWindow.value, string.format("%.0f", c.sideWindowMs / 1000), 10, 8)
    SetFittedControlText(self.controls.uiRefresh.value, tostring(c.uiRefreshMs), 10, 8)
    SetFittedControlText(self.controls.rosterRefresh.value, tostring(c.rosterScanMs), 10, 8)
    SetFittedControlText(self.controls.rawLimit.value, tostring(c.rawEventLimit), 10, 8)
    SetFittedControlText(self.controls.diagEnabled, BoolText(c.diagnosticsEnabled), 10, 8)
    if self.controls.diagRescan ~= nil and self.controls.diagRescan.Enable ~= nil then self.controls.diagRescan:Enable(moduleEnabled) end

    local mode = D.Stats:GetMode(c.currentMode)
    local closureStatus = D.Stats:EnsureClosureCurrent(c.currentMode) or {}
    local diag = D.Diagnostics
    local lastError = diag.errors[#diag.errors]
    -- Diagnostics can stay open during a raid. Counting every historical
    -- entity with pairs() on every UI refresh turns a harmless status label
    -- into an O(all-seen-units) hot path, so refresh those counts at most once
    -- every two seconds.
    local countNow = U.NowMs()
    local countCache = self.diagnosticCountCache
    if type(countCache) ~= "table" or countNow >= (tonumber(countCache.expiresAt) or 0) then
        countCache = {
            roster = Actors:GetRosterCount(),
            entities = Actors:GetEntityCount(),
            expiresAt = countNow + 2000,
        }
        self.diagnosticCountCache = countCache
    end
    local eventShadowStatus = "事件分层：模块不可用"
    if type(EventShadow) == "table" and type(EventShadow.GetStatusLine) == "function" then
        local ok, result = pcall(EventShadow.GetStatusLine, EventShadow)
        if ok then
            eventShadowStatus = tostring(result)
        else
            eventShadowStatus = "事件分层：状态读取失败"
            if type(EventShadow.DisableAfterFailure) == "function" then
                pcall(EventShadow.DisableAfterFailure, EventShadow, result)
            end
        end
    end
    local status = {
        "作者：Replicated",
        "版本：" .. tostring(D.Version),
        type(Api) == "table" and Api:GetStatusLine() or "API：门面不可用",
        type(D.Migrations) == "table" and D.Migrations:DescribeConfigReport() or "配置迁移：模块不可用",
        Actors:GetStatusLine(),
        type(StatsV3) == "table" and StatsV3:GetStatusLine() or "Stats v3：模块不可用",
        type(StatsRead) == "table" and StatsRead:GetStatusLine() or "治疗读路径：模块不可用",
        type(IdentityShadow) == "table" and IdentityShadow:GetStatusLine() or "身份影子：模块不可用",
        type(EventFacts) == "table" and EventFacts:GetStatusLine() or "事实旁路：模块不可用",
        type(EventBlocks) == "table" and EventBlocks:GetStatusLine() or "EventBlock 影子：模块不可用",
        type(LocalReplay) == "table" and LocalReplay:GetStatusLine()
            or "局部重放规划：模块不可用",
        type(LocalStatsShadow) == "table" and LocalStatsShadow:GetStatusLine()
            or "局部 Stats 影子：模块不可用",
        type(LocalStatsCandidate) == "table" and LocalStatsCandidate:GetStatusLine()
            or "局部提交门禁：模块不可用",
        type(LocalDerivedShadow) == "table" and LocalDerivedShadow:GetStatusLine()
            or "局部派生状态：模块不可用",
        type(LocalCommitEnvelope) == "table" and LocalCommitEnvelope:GetStatusLine()
            or "只读提交信封：模块不可用",
        type(PersistenceShards) == "table" and PersistenceShards:GetStatusLine()
            or "16-shard 影子：模块不可用",
        type(PersistenceLoadGate) == "table" and PersistenceLoadGate:GetStatusLine()
            or "分片双读门禁：模块不可用",
        type(PersistenceSwitch) == "table" and PersistenceSwitch:GetStatusLine()
            or "分片正式切换：模块不可用",
        type(EventClassifications) == "table" and EventClassifications:GetStatusLine()
            or "分类旁路：模块不可用",
        eventShadowStatus,
        "启动阶段：" .. tostring(Boot.phase),
        "Runtime：" .. tostring(D.Runtime.started),
        "事件通道：" .. tostring(D.Runtime.eventTransport or "未启动"),
        "原始事件：" .. tostring(diag.counters.rawEvents),
        "解析成功：" .. tostring(diag.counters.parsedEvents),
        "解析失败：" .. tostring(diag.counters.parseFailures),
        "环境伤害已排除：" .. tostring(diag.counters.environmentalEvents or 0)
            .. " / " .. U.FormatNumber(diag.counters.environmentalDamage or 0),
        "纠错日志：" .. tostring(#(D.EventStore.sessionEvents or {}))
            .. "/" .. tostring(C.MAX_CORRECTION_JOURNAL_EVENTS or 4000)
            .. " / 轮换 " .. tostring(diag.counters.correctionJournalRollovers or 0)
            .. " / 完整历史 " .. (D.EventStore.historyCoverageComplete == false and "否" or "是")
            .. " / 当前窗口可重放 "
            .. ((D.Runtime ~= nil and D.Runtime.CanReplayCurrentWindow ~= nil
                and D.Runtime:CanReplayCurrentWindow() == true) and "是" or "否"),
        "实时负载：" .. string.format("%.0f 事件/秒", tonumber(D.Runtime.combatEventRate) or 0)
            .. " / 延迟整表重算 " .. tostring(diag.counters.deferredLiveReclassifies or 0),
        "保存维护：分帧快照 " .. tostring(diag.counters.incrementalStatsSnapshots or 0)
            .. " / 取消 " .. tostring(diag.counters.cancelledStatsSnapshots or 0)
            .. " / 战斗或重放延期 " .. tostring(diag.counters.deferredActiveCombatSaves or 0)
            .. " / 轮换提交 " .. tostring(diag.counters.rotatingStatsSaves or 0),
        "保存字段：" .. tostring(diag.counters.statsSnapshotFields or 0)
            .. " / 避免全量重复写 " .. tostring(diag.counters.avoidedStatsPayloadWrites or 0)
            .. " / 启动命中 " .. tostring(diag.counters.statsHeadHits or 0),
        "启动维护：快速存档 " .. tostring(diag.counters.fastStatsLoads or 0)
            .. " / 修复存档 " .. tostring(diag.counters.repairedStatsLoads or 0)
            .. " / 基线字段 " .. tostring(diag.counters.baselineCopyFields or 0),
        "启动事件：排队 " .. tostring(diag.counters.baselineQueuedEvents or 0)
            .. " / 补处理 " .. tostring(diag.counters.baselineDrainedEvents or 0)
            .. " / 稠密日志 " .. tostring(diag.counters.denseEventStoreLoads or 0),
        "强关系：友 " .. tostring(diag.counters.strongFriendlyRelations or 0)
            .. " / 敌 " .. tostring(diag.counters.strongOpponentRelations or 0)
            .. " / 冲突 " .. tostring(diag.counters.relationConflicts or 0),
        "名单规则：" .. tostring(#(D.State.rules.entries or {})),
        "数据优先收录：" .. tostring(diag.counters.dataFirstAdmissions or 0)
            .. " / 类型猜测已停用 / 最后一击已停用",
        "待确认：" .. tostring(#D.EventStore.pending),
        "第三方事件：" .. tostring(diag.counters.thirdPartyEvents),
        "团队成员缓存：" .. tostring(countCache.roster or 0),
        "团队身份：布局 " .. tostring(D.Runtime.teamLayoutName or "unknown")
            .. " / 别名 " .. tostring(diag.counters.rosterAliasCount or 0)
            .. " / 冲突 " .. tostring(diag.counters.rosterAliasConflicts or 0),
        "实体缓存：" .. tostring(countCache.entities or 0),
        "PVP待确认伤害：" .. U.FormatNumber(D.Stats:GetMode("PVP").pending.damage),
        "PVE待确认伤害：" .. U.FormatNumber(D.Stats:GetMode("PVE").pending.damage),
        "当前对账率：" .. string.format("%.0f%% / %.0f%%",
            tonumber(closureStatus.friendlyDamageVsEnemyTaken) or 0,
            tonumber(closureStatus.enemyDamageVsFriendlyTaken) or 0),
        "待确认丢弃：" .. tostring(diag.counters.droppedPendingEvents or 0),
        "团队令牌族：" .. tostring(D.Runtime.teamSchemeIndexes and #D.Runtime.teamSchemeIndexes or 0),
        -- v0.2.25（性能诊断）：分帧重放/排行榜/视野/身份索引/环形缓冲
        "分帧重放：" .. tostring(diag.counters.replayBatches or 0) .. " 批次 / "
            .. tostring(diag.counters.replayBatchEvents or 0) .. " 事件 / 提交 "
            .. tostring(diag.counters.replayCommits or 0) .. " / 取消 " .. tostring(diag.counters.replayCancels or 0)
            .. (D.State.runtime and D.State.runtime.replaying == true and "（进行中）" or ""),
        "排行榜重建：" .. tostring(diag.counters.rankingRebuilds or 0),
        "身份索引：事件 " .. tostring(diag.counters.identityIndexEvents or 0)
            .. " / 升级重写 " .. tostring(diag.counters.identityUpgradeEventsRewritten or 0),
        "关系二分查询：" .. tostring(diag.counters.relationBinaryLookups or 0)
            .. " / 名称缓存命中 " .. tostring(diag.counters.nameNormalizeCacheHits or 0)
            .. " 未命中 " .. tostring(diag.counters.nameNormalizeCacheMisses or 0),
        "保存整理：actor " .. tostring(diag.counters.saveFinalizeActors or 0)
            .. " / 帧 " .. tostring(diag.counters.saveFinalizeFrames or 0),
    }
    local diagWidth = self.controls.diagStatus.repdpsWidth or 515
    local lastCombat = diag.lastCombatSample
    if type(lastCombat) == "table" then
        status[#status + 1] = "最近事件：" .. TruncateForWidth(
            nil,
            tostring(lastCombat.eventType) .. " | " .. tostring(lastCombat.sourceName) .. " → " .. tostring(lastCombat.targetName)
            .. " | " .. tostring(lastCombat.abilityName) .. " | " .. tostring(lastCombat.amount)
            .. " | " .. tostring(lastCombat.classificationStatus),
            math.max(80, diagWidth - 8),
            10
        )
    end
    if diag.lastUnitInfoSample ~= nil then status[#status + 1] = "单位字段样本：" .. TruncateForWidth(nil, diag.lastUnitInfoSample, math.max(80, diagWidth - 8), 10) end
    if lastError ~= nil then status[#status + 1] = "最近错误：" .. TruncateForWidth(nil, lastError.message, math.max(80, diagWidth - 8), 10) end
    local diagLines = math.max(1, math.floor((tonumber(self.controls.diagStatus.repdpsHeight) or 180) / 13))
    self.controls.diagStatus:SetText(FitMultilineText(
        self.controls.diagStatus,
        table.concat(status, "\n"),
        diagWidth,
        10,
        diagLines
    ))
    self:RefreshRulesPage()
    SetBoundedText(
        self.controls.configFooter,
        moduleEnabled and "统计运行中；只手动清空。" or "统计已暂停；已有数据保留。",
        self.controls.configFooter.repdpsWidth or 520,
        9
    )
end

local function MetricRateLabel(page, analysisView)
    if page == "TAKEN" then return "DTPS" end
    if page == "HEAL" then return "HPS" end
    if type(analysisView) == "table" and analysisView.kind == "BOSS" then return "BossDPS" end
    if type(analysisView) == "table" and analysisView.kind == "EXCLUDED" then return "有效DPS" end
    return "DPS"
end

local function DisplayNumber(value)
    if D.State.config.abbreviateNumbers then return U.FormatNumber(value) end
    return tostring(math.floor((tonumber(value) or 0) + 0.5))
end

local PRINT_METRICS = {
    DAMAGE = { page = "DAMAGE", label = "伤害" },
    TAKEN = { page = "TAKEN", label = "承伤" },
    HEAL = { page = "HEAL", label = "治疗" },
}

local function WriteDebugLog(message)
    if type(Api) ~= "table" or not Api:Has("addon.chat_log") then
        if D.Diagnostics ~= nil and D.Diagnostics.AddWarning ~= nil then
            D.Diagnostics:AddWarning("ui:ranking_print", "ADDON:ChatLog 不可用，排行榜未写入 DebugLog")
        end
        return false
    end
    local ok, result = Api:WriteDebugLog(tostring(message))
    if not ok or result == false then
        if D.Diagnostics ~= nil and D.Diagnostics.AddError ~= nil then
            D.Diagnostics:AddError("ui:ranking_print", "排行榜写入 DebugLog 失败：" .. tostring(result))
        end
        return false
    end
    return true
end

-- DebugLog output always uses a compact, stable format regardless of the UI's
-- “abbreviate numbers” preference. This keeps a top-10 line readable and
-- matches the explicit k/m/b ranking format requested by the user.
local function FormatPrintNumber(value)
    local n = tonumber(value) or 0
    if n ~= n or n == math.huge or n == -math.huge then n = 0 end
    local absN = math.abs(n)
    local scaled, suffix, decimals
    if absN >= 1000000000 then
        scaled, suffix, decimals = n / 1000000000, "b", 2
    elseif absN >= 1000000 then
        scaled, suffix, decimals = n / 1000000, "m", 2
    elseif absN >= 1000 then
        scaled, suffix, decimals = n / 1000, "k", 1
    else
        return string.format("%d", math.floor(n + (n >= 0 and 0.5 or -0.5)))
    end
    local text = string.format("%." .. tostring(decimals) .. "f", scaled)
    text = text:gsub("(%..-)0+$", "%1"):gsub("%.$", "")
    return text .. suffix
end

function UIX:LayoutPrintChooser()
    local window = self.windows.printChooser
    if window == nil then return end
    local _, _, _, logicalWidth, logicalHeight = U.GetUiMetrics()
    local width = math.min(PRINT_CHOOSER_DEFAULT_W, math.max(220, logicalWidth - 16))
    local height = math.min(PRINT_CHOOSER_DEFAULT_H, math.max(104, logicalHeight - 16))
    local x = math.max(0, math.floor((logicalWidth - width) / 2))
    local y = math.max(0, math.floor((logicalHeight - height) / 2))
    window:RemoveAllAnchors()
    window:AddAnchor("TOPLEFT", "UIParent", x, y)
    window:SetExtent(width, height)

    local closeWidth = 27
    self.controls.printClose:RemoveAllAnchors()
    self.controls.printClose:AddAnchor("TOPRIGHT", window, -8, 6)
    ApplyButtonStyle(self.controls.printClose, closeWidth, 24, 10)
    self.controls.printTitle:RemoveAllAnchors()
    self.controls.printTitle:AddAnchor("TOPLEFT", window, 10, 8)
    SetLabelExtent(self.controls.printTitle, math.max(1, width - closeWidth - 28), 22)
    self.controls.printHint:RemoveAllAnchors()
    self.controls.printHint:AddAnchor("TOPLEFT", window, 10, 34)
    SetLabelExtent(self.controls.printHint, math.max(1, width - 20), 18)

    local gap = width < 260 and 3 or 7
    local available = math.max(1, width - 20 - gap * 2)
    local buttonWidth = math.max(1, math.floor(available / 3))
    local buttons = { self.controls.printDamage, self.controls.printTaken, self.controls.printHeal }
    local cursor = 10
    for index, button in ipairs(buttons) do
        local actualWidth = index == 3 and math.max(1, width - 10 - cursor) or buttonWidth
        button:RemoveAllAnchors()
        button:AddAnchor("TOPLEFT", window, cursor, math.max(60, height - 48))
        ApplyButtonStyle(button, actualWidth, 28, width < 260 and 9 or 10)
        cursor = cursor + actualWidth + gap
    end
end

function UIX:ShowPrintChooser(sideName)
    if sideName ~= "friendly" and sideName ~= "enemy" then return false end
    if self.windows.printChooser == nil and not EnsurePrintChooser() then
        D.Boot.SafeChat("打印选择窗口不可用，本次统计不受影响。")
        return false
    end
    local mode = D.State.config.currentMode == "PVE" and "PVE" or "PVP"
    self.printContext = { sideName = sideName, mode = mode }
    local sideLabel = sideName == "friendly" and "友军" or "敌军"
    SetBoundedText(self.controls.printTitle, mode .. sideLabel .. "：选择打印排行", self.controls.printTitle.repdpsWidth or 260, 13)
    self:LayoutPrintChooser()
    self.windows.printChooser:Show(true)
    if self.windows.printChooser.Raise ~= nil then self.windows.printChooser:Raise() end
    return true
end

function UIX:HidePrintChooser()
    if self.windows.printChooser ~= nil then self.windows.printChooser:Show(false) end
    self.printContext = nil
end

local function PrintScopeLabel(mode, sideLabel, metric, analysisView)
    local label = mode .. sideLabel .. metric.label .. "排名"
    if metric.page == "DAMAGE" and type(analysisView) == "table" then
        if analysisView.kind == "BOSS" and analysisView.bossTarget ~= nil then
            return label .. "[Boss:" .. tostring(analysisView.bossTarget.name) .. "]"
        elseif analysisView.kind == "EXCLUDED" then
            return label .. "[已排除" .. tostring(analysisView.excludedCount or 0) .. "个目标]"
        end
    end
    return label
end

-- Print one independently selected metric from the panel that opened the
-- chooser. The context is captured at click time, so changing another window
-- cannot accidentally print the wrong side. Healing reads the independent SharedHealing Authority, while its heading
-- still reflects the panel mode requested by the user.
function UIX:PrintRankingMetric(page, context)
    local metric = PRINT_METRICS[page]
    context = type(context) == "table" and context or self.printContext
    if metric == nil or type(context) ~= "table" then return false end
    local sideName = context.sideName
    if sideName ~= "friendly" and sideName ~= "enemy" then return false end
    local mode = context.mode == "PVE" and "PVE" or "PVP"
    local sideLabel = sideName == "friendly" and "友军" or "敌军"
    local ranking, _, _, _, analysisView = D.Stats:BuildRanking(mode, sideName, metric.page)
    ranking = type(ranking) == "table" and ranking or {}

    local message = PrintScopeLabel(mode, sideLabel, metric, analysisView) .. ":"
    local count = math.min(10, #ranking)
    if count <= 0 then
        message = message .. "暂无有效统计数据"
    else
        local entries = {}
        for rank = 1, count do
            local item = ranking[rank]
            local name = tostring(item and (item.name or item.key) or "未知单位")
            name = name:gsub("[\r\n|]", " ")
            local value = FormatPrintNumber(item and item.value or 0)
            entries[#entries + 1] = tostring(rank) .. "-" .. value .. metric.label .. "-" .. name
        end
        message = message .. table.concat(entries, " | ") .. " |"
    end
    local ok = WriteDebugLog(message)
    if ok then
        self:HidePrintChooser()
    else
        D.Boot.SafeChat("排行榜写入 DebugLog 失败；选择窗口已保留，可再次尝试。")
    end
    return ok
end

-- Compatibility entry point retained for old hot-reloaded handlers. The button
-- now opens the metric chooser instead of immediately printing a mixed summary.
function UIX:PrintRankingSummary(sideName)
    return self:ShowPrintChooser(sideName)
end

local function KindLabel(kind)
    local labels = { PLAYER = "玩家", NPC = "NPC", MATE = "宠物", SLAVE = "召唤物", OTHER = "其他", UNKNOWN = "未知" }
    return labels[kind] or tostring(kind or "未知")
end

local function RelationLabel(relation)
    local labels = { SELF = "自己", TEAM = "团队", FRIENDLY = "友军", OPPONENT = "敌军", SUSPECT_FRIENDLY = "疑似友军", SUSPECT_OPPONENT = "疑似敌军", NEUTRAL = "中立", UNKNOWN = "未知" }
    return labels[relation] or tostring(relation or "未知")
end

local function IsCounterpartPlaceholder(name)
    local normalized = U.NormalizeName(name)
    if normalized == "" then return true end
    local blocked = {
        [U.NormalizeName("其他")] = true,
        [U.NormalizeName("环境")] = true,
        [U.NormalizeName("未知")] = true,
        [U.NormalizeName("未知目标")] = true,
        [U.NormalizeName("未知来源")] = true,
        [U.NormalizeName("未识别目标")] = true,
        [U.NormalizeName("未识别来源")] = true,
    }
    if blocked[normalized] == true then return true end
    return string.find(normalized, U.NormalizeName("未识别目标"), 1, true) == 1
        or string.find(normalized, U.NormalizeName("未识别来源"), 1, true) == 1
end

local function IsPveFriendlyDamageContext(context)
    return type(context) == "table"
        and context.originMode == "PVE"
        and context.originSide == "friendly"
        and context.originPage == "DAMAGE"
        and not IsCounterpartPlaceholder(context.name)
end

function UIX:GetSelectedAnalysisTarget()
    local selected = self.detail and self.detail.selected or nil
    local context = selected and selected.counterpartContext or nil
    if not IsPveFriendlyDamageContext(context) then return nil, context end
    return context.name, context
end

local function CounterpartCandidates(name)
    if type(Actors) == "table" then
        return Actors:GetCandidatesByName(name)
    end
    return {}
end

function UIX:PushDetailNavigation()
    local detail = self.detail
    detail.navigation = detail.navigation or {}
    local selectedCopy = nil
    if type(detail.selected) == "table" then
        -- Do not deep-copy the selected actor: its ability/target maps can be
        -- large after a long battle. The key is sufficient to resolve it again.
        selectedCopy = {
            mode = detail.selected.mode,
            page = detail.selected.page,
            side = detail.selected.side,
            key = detail.selected.key,
            projectionKey = detail.selected.projectionKey,
            name = detail.selected.name,
            stringId = detail.selected.stringId,
            openedFromCounterpart = detail.selected.openedFromCounterpart == true,
            counterpartContext = detail.selected.counterpartContext and U.DeepCopy(detail.selected.counterpartContext) or nil,
        }
    end
    detail.navigation[#detail.navigation + 1] = {
        selected = selectedCopy,
        view = detail.view,
        offset = detail.offset,
        candidateSelection = detail.candidateSelection and U.DeepCopy(detail.candidateSelection) or nil,
    }
    if #detail.navigation > 12 then table.remove(detail.navigation, 1) end
end

function UIX:GoBackDetail()
    local detail = self.detail
    local stack = detail.navigation or {}
    local previous = stack[#stack]
    if previous == nil then return false end
    stack[#stack] = nil
    detail.selected = previous.selected
    detail.view = previous.view or "ABILITY"
    detail.offset = tonumber(previous.offset) or 0
    detail.candidateSelection = previous.candidateSelection
    detail.totalEntries = 0
    self:LayoutDetailWindow()
    self:RefreshDetail()
    return true
end

function UIX:OpenCounterpartEntity(entity, context)
    if entity == nil then return false end
    self:PushDetailNavigation()
    local origin = self.detail.selected or {}
    local relation = entity.relation
    local entitySide = relation == "OPPONENT" and "enemy"
        or ((relation == "SELF" or relation == "TEAM" or relation == "FRIENDLY") and "friendly" or origin.side)
    self.detail.selected = {
        mode = origin.mode or D.State.config.currentMode,
        page = origin.page or D.State.config.currentPage,
        side = entitySide or "friendly",
        key = entity.key,
        projectionKey = entity.key,
        name = entity.name,
        stringId = entity.stringId,
        entityRef = entity,
        actor = nil,
        openedFromCounterpart = true,
        counterpartContext = context,
    }
    self.detail.candidateSelection = nil
    self.detail.view = "ABILITY"
    self.detail.offset = 0
    self.detail.totalEntries = 0
    self:LayoutDetailWindow()
    self:RefreshDetail()
    return true
end

function UIX:OpenCounterpartEntry(entry)
    if type(entry) ~= "table" or entry.kind ~= "COUNTERPART" then return false end
    local lookupName = entry.displayName or entry.name
    if IsCounterpartPlaceholder(lookupName) then
        D.Boot.SafeChat("该行是汇总或占位数据，不能作为具体单位修改。")
        return false
    end
    -- TargetRef(ACTOR) already identifies one exact current entity. Do not
    -- discard that proof and reopen an ambiguous same-name selector.
    if entry.identityKind == "ACTOR" and entry.canonicalKey ~= nil then
        local exact = Actors:GetEntityByKey(entry.canonicalKey)
        if exact == nil and entry.stableId ~= nil then
            exact = D.Entities:GetOrCreate(lookupName, entry.stableId)
        end
        if exact ~= nil then return self:OpenCounterpartEntity(exact, entry) end
    end
    -- Legacy/new name-history rows are intentionally opened as historical
    -- aggregates. They must not be guessed into one of several current IDs.
    if entry.identityKind == "LEGACY_NAME_HISTORY" or entry.identityKind == "NAME_HISTORY" then
        local historical = D.Entities.GetHistoricalNameEntity ~= nil
            and D.Entities:GetHistoricalNameEntity(lookupName)
            or D.Entities:GetOrCreate(lookupName)
        if historical ~= nil then return self:OpenCounterpartEntity(historical, entry) end
    end
    local candidates = CounterpartCandidates(lookupName)

    -- Legacy damage/taken maps are keyed by the visible combat-log name.  When
    -- that name now has both a historical aggregate and one or more concrete
    -- IDs, the aggregate is the only entity that actually owns those name-only
    -- events.  Open it directly so the manual type/relation buttons are usable
    -- immediately and the correction affects future name-only events plus the
    -- retained replay window.  Choosing a concrete ID here would look precise
    -- but would not modify the rows shown in this detail list.
    if entry.identityKind == nil then
        for _, candidateEntity in ipairs(candidates) do
            if type(candidateEntity) == "table" and candidateEntity.flags ~= nil
                and candidateEntity.flags.historicalNameAggregate == true then
                local aggregateContext = U.DeepCopy(entry)
                aggregateContext.identityQuality = "HISTORICAL_NAME_AGGREGATE"
                aggregateContext.sameNameCandidateCount = #candidates
                return self:OpenCounterpartEntity(candidateEntity, aggregateContext)
            end
        end
    end

    if #candidates == 1 then
        return self:OpenCounterpartEntity(candidates[1], entry)
    end
    if #candidates == 0 then
        -- Name-only legacy/current data remains editable for this session. The
        -- details page clearly marks that precision is limited to the name.
        local entity = D.Entities.GetHistoricalNameEntity ~= nil
            and D.Entities:GetHistoricalNameEntity(lookupName)
            or D.Entities:GetOrCreate(lookupName)
        if entity ~= nil then return self:OpenCounterpartEntity(entity, entry) end
        D.Boot.SafeChat("无法定位该目标单位。")
        return false
    end

    self:PushDetailNavigation()
    self.detail.candidateSelection = {
        name = lookupName,
        value = entry.value,
        originMode = entry.originMode,
        originSide = entry.originSide,
        originPage = entry.originPage,
        candidates = {},
    }
    for _, entity in ipairs(candidates) do
        self.detail.candidateSelection.candidates[#self.detail.candidateSelection.candidates + 1] = {
            key = entity.key,
            name = entity.name,
            stableId = entity.stringId,
            kind = entity.kind,
            relation = entity.relation,
            historicalAggregate = entity.flags ~= nil and entity.flags.historicalNameAggregate == true,
        }
    end
    self.detail.offset = 0
    self.detail.totalEntries = #candidates
    self:LayoutDetailWindow()
    self:RefreshDetail()
    return true
end

function UIX:OpenCandidateEntity(candidate)
    if type(candidate) ~= "table" then return false end
    local entity = Actors:GetEntityByKey(candidate.key)
    if entity == nil and candidate.stableId ~= nil then
        entity = D.Entities:GetOrCreate(candidate.name, candidate.stableId)
    end
    if entity == nil then return false end
    local selector = self.detail.candidateSelection
    -- Replace the selector state on the stack with its origin so one Back click
    -- returns to the original actor instead of reopening the selector.
    self.detail.candidateSelection = nil
    self.detail.selected = self.detail.selected
    local origin = self.detail.navigation and self.detail.navigation[#self.detail.navigation]
    if origin ~= nil then
        self.detail.selected = origin.selected
        self.detail.view = origin.view
        self.detail.offset = origin.offset
        self.detail.candidateSelection = origin.candidateSelection
        self.detail.navigation[#self.detail.navigation] = nil
    end
    return self:OpenCounterpartEntity(entity, {
        name = selector and selector.name or candidate.name,
        value = selector and selector.value or 0,
        originMode = selector and selector.originMode or nil,
        originSide = selector and selector.originSide or nil,
        originPage = selector and selector.originPage or nil,
        identityQuality = candidate.historicalAggregate == true and "HISTORICAL_NAME_AGGREGATE" or "AMBIGUOUS_SELECTED",
    })
end

function UIX:GetSelectedDetail()
    local selected = self.detail.selected
    if selected == nil then return nil, nil, nil end
    local entity = Actors:GetEntityByKey(selected.key)
    -- 详情二级导航以前只保存 key。名称实体在身份升级、别名迁移或热重载后，
    -- 旧 key 可能暂时无法从 byKey 找回，RefreshDetail 会提前返回，并保留
    -- “同名候选页”留下的禁用按钮状态，表现为底部按钮全部变黑。
    -- 二级导航现在保留轻量实体引用与稳定 ID；若引用也失效，再按原始名称
    -- 安全重建历史名称实体。该恢复只发生在用户点击详情时，不进入战斗热路径。
    if entity == nil and type(selected.entityRef) == "table" then
        entity = selected.entityRef
    end
    if entity == nil and selected.openedFromCounterpart == true and U.Trim(selected.name) ~= "" then
        if selected.stringId ~= nil and tostring(selected.stringId) ~= "" then
            entity = D.Entities:GetOrCreate(selected.name, selected.stringId)
        elseif D.Entities.GetHistoricalNameEntity ~= nil then
            entity = D.Entities:GetHistoricalNameEntity(selected.name)
        else
            entity = D.Entities:GetOrCreate(selected.name)
        end
    end
    if entity ~= nil then
        selected.key = entity.key
        selected.name = entity.name
        selected.stringId = entity.stringId
        selected.entityRef = entity
    end
    local resolvedKey = entity ~= nil and entity.key or selected.key
    local sides = { selected.side, selected.side == "friendly" and "enemy" or "friendly" }

    local function EnsureHistoricalEntity(actor)
        local canonicalActor = actor
        if entity == nil and type(actor) == "table" then
            local stableId = string.match(tostring(resolvedKey or ""), "^id:(.+)$")
            entity = D.Entities:GetOrCreate(actor.name or selected.name, stableId)
            if entity ~= nil then
                if entity.key ~= resolvedKey and D.Stats.MergeActorKey ~= nil then
                    D.Stats:MergeActorKey(resolvedKey, entity.key, actor.name)
                    resolvedKey = entity.key
                    if selected.page == "HEAL" then
                        canonicalActor = D.Stats:GetSharedHealingActor(selected.side, resolvedKey, U.NowMs()) or actor
                    else
                        local modeStats = D.Stats:GetMode(selected.mode)
                        canonicalActor = modeStats[selected.side] and modeStats[selected.side].actors[resolvedKey] or actor
                    end
                end
                selected.key = entity.key
            end
        end
        return canonicalActor, entity
    end

    if selected.page == "HEAL" then
        for _, sideName in ipairs(sides) do
            local actor = D.Stats:GetSharedHealingActor(sideName, resolvedKey, U.NowMs())
            if actor ~= nil then
                selected.side = sideName
                local canonicalActor, historicalEntity = EnsureHistoricalEntity(actor)
                selected.actor = canonicalActor
                selected.name = canonicalActor.name
                return selected, canonicalActor, historicalEntity
            end
        end
    else
        -- The detail window inherits the exact mode of the clicked ranking row.
        -- Never fall through to the same actor in the opposite mode: otherwise
        -- opening a PVP row can silently display PVE NPC targets (or the reverse)
        -- when the current-mode row moves/disappears during a refresh.
        local actor, resolvedSide = nil, nil
        if type(StatsRead) == "table" and type(StatsRead.GetModeActor) == "function" then
            actor, resolvedSide = StatsRead:GetModeActor(selected.mode, selected.side, resolvedKey)
        else
            local modeStats = D.Stats:GetMode(selected.mode)
            for _, sideName in ipairs(sides) do
                local side = modeStats[sideName]
                actor = side and side.actors[resolvedKey] or nil
                if actor ~= nil then resolvedSide = sideName break end
            end
        end
        if actor ~= nil then
            selected.side = resolvedSide or selected.side
            local canonicalActor, historicalEntity = EnsureHistoricalEntity(actor)
            selected.actor = canonicalActor
            selected.name = canonicalActor.name
            return selected, canonicalActor, historicalEntity
        end
    end
    selected.actor = nil
    if entity ~= nil then selected.name = entity.name end
    return selected, nil, entity
end

function UIX:ShowDetail(sideName, item)
    if item == nil then return end
    self.detail.selected = {
        mode = D.State.config.currentMode,
        page = self:GetQuickPage(),
        side = sideName,
        key = item.key,
        projectionKey = item.key,
        name = item.name,
        actor = item.actor,
    }
    self.detail.view = self.detail.view or "ABILITY"
    self.detail.offset = 0
    self.detail.totalEntries = 0
    self.detail.entryCache = nil
    self.detail.entryJob = nil
    self.detail.navigation = {}
    self.detail.candidateSelection = nil
    self:LayoutDetailWindow()
    self.windows.detail:Show(true)
    if self.windows.detail.Raise ~= nil then self.windows.detail:Raise() end
    self:RefreshDetail()
end

function UIX:CloseDetail()
    self.windows.detail:Show(false)
    self.detail.selected = nil
    self.detail.entryCache = nil
    self.detail.entryJob = nil
    self.detail.navigation = {}
    self.detail.candidateSelection = nil
    for _, row in ipairs(self.detailRows or {}) do row.data = nil end
end


local function DetailEntryWorse(left, right)
    if right == nil then return true end
    if left.value ~= right.value then return left.value < right.value end
    return tostring(left.name) > tostring(right.name)
end

local function SiftDetailWorstDown(entries, root, size)
    while true do
        local child = root * 2
        if child > size then return end
        if child + 1 <= size and DetailEntryWorse(entries[child + 1], entries[child]) then
            child = child + 1
        end
        if not DetailEntryWorse(entries[child], entries[root]) then return end
        entries[root], entries[child] = entries[child], entries[root]
        root = child
    end
end

local function BeginDetailEntryJob(map, cacheKey)
    return {
        key = cacheKey,
        map = type(map) == "table" and map or {},
        entries = {},
        total = 0,
        phase = "COLLECT",
        nextKey = nil,
    }
end

local function StepDetailEntryJob(job, budget)
    if type(job) ~= "table" then return true end
    budget = math.max(1, math.floor(tonumber(budget) or 800))
    local operations = 0
    while operations < budget do
        if job.phase == "COLLECT" then
            local key, rawValue = next(job.map, job.nextKey)
            job.nextKey = key
            if key == nil then
                job.phase = "HEAP"
                job.heapIndex = math.floor(#job.entries / 2)
            else
                local entry
                if type(rawValue) == "table" then
                    entry = {}
                    for field, fieldValue in pairs(rawValue) do entry[field] = fieldValue end
                    entry.name = tostring(entry.name or entry.displayName or key or "未知")
                    entry.value = tonumber(entry.value or entry.amount) or 0
                else
                    entry = { name = tostring(key or "未知"), value = tonumber(rawValue) or 0 }
                end
                if entry.value > 0 then
                    job.entries[#job.entries + 1] = entry
                    job.total = job.total + entry.value
                end
                operations = operations + 1
            end
        elseif job.phase == "HEAP" then
            local index = tonumber(job.heapIndex) or 0
            if index < 1 then
                job.phase = "SORT"
                job.heapSize = #job.entries
            else
                SiftDetailWorstDown(job.entries, index, #job.entries)
                job.heapIndex = index - 1
                operations = operations + 1
            end
        elseif job.phase == "SORT" then
            local size = tonumber(job.heapSize) or 0
            if size <= 1 then
                job.phase = "DONE"
                return true
            end
            job.entries[1], job.entries[size] = job.entries[size], job.entries[1]
            size = size - 1
            job.heapSize = size
            SiftDetailWorstDown(job.entries, 1, size)
            operations = operations + 1
        else
            return true
        end
    end
    return job.phase == "DONE"
end

function UIX:RefreshDetail()
    local window = self.windows.detail
    if window == nil or not window:IsVisible() then return true end
    local summaryWidth = math.max(1, (tonumber(window:GetWidth()) or DETAIL_DEFAULT_W) - 20)
    local selector = self.detail.candidateSelection
    if selector ~= nil then
        SetAdaptiveSingleLineText(self.controls.detailTitle, "选择同名单位：" .. tostring(selector.name), self.controls.detailTitle.repdpsWidth, 14, 10)
        SetBoundedText(self.controls.detailType, "该目标对应多个当前单位，官方战斗事件只提供名称时无法自动拆分历史数值。", summaryWidth, 10)
        SetBoundedText(self.controls.detailRelation, "请先点击下方候选行进入单位详情；进入后按钮才可使用。", summaryWidth, 10)
        SetBoundedText(self.controls.detailTotals, "名称合计：" .. DisplayNumber(selector.value or 0), summaryWidth, 10)
        SetBoundedText(self.controls.detailHint, "当前按钮灰色表示尚未选择候选；点击任意候选行后即可设置类型、关系或名单。", self.controls.detailHint.repdpsWidth, 9)
        SetFittedControlText(self.controls.detailAbility, "候选单位", 10, 8)
        SetFittedControlText(self.controls.detailCounterpart, "同名冲突", 10, 8)
        if self.controls.detailAbility.Enable ~= nil then self.controls.detailAbility:Enable(false) end
        if self.controls.detailCounterpart.Enable ~= nil then self.controls.detailCounterpart:Enable(false) end
        local candidates = selector.candidates or {}
        local visibleRows = U.Clamp(self.visibleDetailRows or DETAIL_ROWS, 0, DETAIL_ROWS)
        local maxOffset = visibleRows > 0 and math.max(0, #candidates - visibleRows) or 0
        local offset = visibleRows > 0 and U.Clamp(tonumber(self.detail.offset) or 0, 0, maxOffset) or 0
        self.detail.offset = offset
        self.detail.totalEntries = #candidates
        local pageStart = visibleRows > 0 and #candidates > 0 and offset + 1 or 0
        local pageEnd = visibleRows > 0 and math.min(#candidates, offset + visibleRows) or 0
        SetFittedControlText(self.controls.detailPage, string.format("%d-%d/%d", pageStart, pageEnd, #candidates), 9, 7)
        if self.controls.detailPrev.Enable ~= nil then self.controls.detailPrev:Enable(offset > 0) end
        if self.controls.detailNext.Enable ~= nil then self.controls.detailNext:Enable(offset < maxOffset) end
        for i = 1, DETAIL_ROWS do
            local row = self.detailRows[i]
            local candidate = candidates[offset + i]
            if i <= visibleRows and candidate ~= nil then
                row.data = { kind = "CANDIDATE", candidate = candidate }
                row.bar:SetExtent(1, math.max(1, tonumber(row.panel:GetHeight()) or 21))
                local idText
                if candidate.historicalAggregate == true then idText = "名称历史汇总"
                elseif candidate.stableId ~= nil then idText = "ID:" .. tostring(candidate.stableId)
                else idText = "仅名称" end
                SetBoundedText(row.name, tostring(offset + i) .. ". " .. tostring(candidate.name), row.name.repdpsWidth, 10)
                SetBoundedText(row.value, KindLabel(candidate.kind) .. "/" .. RelationLabel(candidate.relation) .. " · " .. idText, row.value.repdpsWidth, 9)
                row.panel:Show(true)
            else
                row.data = nil
                row.panel:Show(false)
            end
        end
        for _, button in ipairs({ self.controls.detailFriendly, self.controls.detailEnemy, self.controls.detailPlayer,
            self.controls.detailNpc, self.controls.detailOther, self.controls.detailIgnore, self.controls.detailAuto,
            self.controls.detailSaveRule, self.controls.detailRemoveRule, self.controls.detailExcludeTarget,
            self.controls.detailBossTarget }) do
            if button ~= nil then
                if button.Enable ~= nil then button:Enable(false) end
                if button == self.controls.detailExcludeTarget or button == self.controls.detailBossTarget then button:Show(false) end
            end
        end
        return
    end
    local selected, actor, entity = self:GetSelectedDetail()
    if selected == nil or entity == nil then
        SetAdaptiveSingleLineText(self.controls.detailTitle, "单位详情（数据已变化）", self.controls.detailTitle.repdpsWidth, 14, 10)
        SetBoundedText(self.controls.detailType, "当前单位已不存在，请重新点击排行榜。", summaryWidth, 10)
        self.controls.detailRelation:SetText("")
        self.controls.detailTotals:SetText("")
        self.controls.detailHint:SetText("")
        self.controls.detailPage:SetText("0/0")
        self.detail.offset = 0
        self.detail.totalEntries = 0
        for i = 1, DETAIL_ROWS do self.detailRows[i].panel:Show(false) end
        return
    end

    local sideText = selected.side == "friendly" and "友军" or "敌军"
    local projectionKey = selected.projectionKey or selected.key
    local override = nil
    if D.Entities ~= nil and type(D.Entities.GetManualOverrideByKey) == "function" then
        override = D.Entities:GetManualOverrideByKey(entity.key, projectionKey)
    else
        override = entity.manualOverride
    end
    local savedRule, savedMatchMode = nil, nil
    if D.Entities ~= nil and type(D.Entities.GetPersistentRuleByKey) == "function" then
        savedRule, savedMatchMode = D.Entities:GetPersistentRuleByKey(entity.key, projectionKey)
    elseif D.Rules ~= nil then
        savedRule, savedMatchMode = D.Rules:GetForEntity(entity)
    end
    local manualText = "自动判断"
    if override ~= nil then
        if override.ignored == true then
            manualText = override.source == "rule" and "名单忽略" or "本次忽略（未保存）"
        elseif override.source == "rule" then
            manualText = "名单规则（" .. ((override.matchMode or savedMatchMode) == "ID" and "ID" or "名称") .. "）"
        else
            manualText = "本次手动（未保存）"
        end
    end

    local contextualKind = override ~= nil and override.kind or entity.kind
    local contextualRelation = override ~= nil and override.relation or entity.relation
    local kind = KindLabel(contextualKind)
    local relation = RelationLabel(contextualRelation)
    local friendlyScore = tonumber(entity.relationScores.friendly) or 0
    local opponentScore = tonumber(entity.relationScores.opponent) or 0
    local pageMetric = { DAMAGE = "damage", TAKEN = "taken", HEAL = "heal", KILLS = "kills" }
    local pageLabel = { DAMAGE = "伤害", TAKEN = "承伤", HEAL = "治疗", KILLS = "最后一击" }
    local abilityLabel = { DAMAGE = "造成技能", TAKEN = "承受技能", HEAL = "治疗技能", KILLS = "最后一击技能" }
    local counterpartLabel = selected.page == "TAKEN" and "来源" or "目标"
    local metric = pageMetric[selected.page] or "damage"
    local details = actor ~= nil and actor.details and actor.details[metric] or nil
    local actorName = actor ~= nil and actor.name or entity.name

    -- The clicked unit's complete name is the primary title.  Context is
    -- moved to the metadata line so a long player name is no longer consumed
    -- by the PVP/PVE, side and metric prefixes.
    SetAdaptiveSingleLineText(self.controls.detailTitle, actorName, self.controls.detailTitle.repdpsWidth, 14, 10)
    local detailModeText = selected.page == "HEAL" and "关系共享" or (selected.mode .. "独立明细")
    SetBoundedText(self.controls.detailType, string.format(
        "%s · %s · %s | 类型：%s",
        detailModeText, sideText, pageLabel[selected.page] or selected.page, kind
    ), summaryWidth, 10)
    local conflictText = entity.flags ~= nil and entity.flags.relationConflict == true
        and (" · 冲突：" .. tostring(entity.flags.relationConflictCount or 1)
            .. "次/" .. tostring(entity.flags.lastRelationConflictKind or "关系冲突")) or ""
    SetBoundedText(self.controls.detailRelation, string.format(
        "关系：%s（友 %.0f / 敌 %.0f） · 状态：%s%s",
        relation, friendlyScore, opponentScore, manualText, conflictText
    ), summaryWidth, 10)
    if selected.page == "HEAL" then
        SetBoundedText(self.controls.detailTotals,
            "累计治疗：" .. DisplayNumber(actor and actor.heal or 0) .. "（SharedHealing）",
            summaryWidth, 10)
    else
        local sharedHealActor = D.Stats:GetSharedHealingActor(selected.side, selected.key, U.NowMs())
        local damageText = DisplayNumber(actor and actor.damage or 0)
        if actor ~= nil and D.Analysis:IsPveFriendlyDamageScope(selected.mode, selected.side, selected.page) then
            local modeStats = D.Stats:GetMode(selected.mode)
            local projected, _, damageView = D.Stats:GetDamageAnalysisValue(
                selected.mode, selected.side, actor, modeStats[selected.side], U.NowMs(), selected.key)
            if type(damageView) == "table" and damageView.kind == "BOSS" then
                damageText = DisplayNumber(projected) .. " Boss / 原始 " .. DisplayNumber(actor.damage)
            elseif type(damageView) == "table" and damageView.kind == "EXCLUDED" then
                damageText = DisplayNumber(projected) .. " 有效 / 原始 " .. DisplayNumber(actor.damage)
            end
        end
        SetBoundedText(self.controls.detailTotals, string.format(
            "累计：伤 %s · 承 %s · 治(共享) %s",
            damageText, DisplayNumber(actor and actor.taken or 0),
            DisplayNumber(sharedHealActor and sharedHealActor.heal or 0)
        ), summaryWidth, 10)
    end

    local predictedMatch = D.Rules ~= nil and D.Rules:PredictMatchType(entity, override, nil) or "NAME"
    local conflict = entity.flags ~= nil and (entity.flags.nameConflict == true or entity.flags.ruleAmbiguous == true)
    local hint
    local counterpartContext = selected.counterpartContext
    if counterpartContext ~= nil then
        if counterpartContext.identityQuality == "TARGET_REF_ACTOR" then
            hint = "当前行由稳定 TargetRef 精确定位具体单位；旧同名历史仍保留在独立汇总行，不会自动归并。"
        elseif counterpartContext.identityQuality == "TARGET_REF_NAME_HISTORY" then
            hint = "当前行是迁移后的名称历史增量，没有可靠单位ID；不会猜测归给当前同名单位。"
        elseif counterpartContext.identityQuality == "HISTORICAL_NAME_AGGREGATE" then
            hint = "当前修改名称历史汇总：影响官方战斗事件中只有名称、无法按时间绑定具体ID的可重放数据；不会伪装成某个具体单位。"
        elseif counterpartContext.identityQuality == "AMBIGUOUS_SELECTED" then
            hint = "已从同名候选中选择具体单位；官方战斗事件只有名称时，既有同名数值无法精确拆分。"
        elseif entity.stringId ~= nil and tostring(entity.stringId) ~= "" then
            hint = "当前名称能唯一对应单位ID；纠错将影响可重放历史与后续事件。"
        else
            hint = "当前按名称定位；本次可人工纠错，取得单位ID后才可保存精确玩家规则。"
        end
    elseif override ~= nil and override.ignored == true then
        hint = "该单位当前被忽略，排行数据暂时隐藏；可保存到名单或恢复。"
    elseif conflict and predictedMatch == "NAME" and entity.kind == "PLAYER" then
        hint = "检测到同名冲突：玩家不能按名称保存，需取得单位ID后再保存。"
    elseif override ~= nil and override.source == "session" then
        hint = "本次修改尚未保存；确认组合无误后保存到名单。"
    elseif savedRule ~= nil then
        hint = "已匹配名单（" .. ((savedRule.matchType == "ID") and "单位ID" or "名称") .. "）；可修改后重新保存。"
    elseif actor == nil then
        hint = "该单位当前没有可见排行数据，但仍可修改标记或恢复规则。"
    elseif actor.legacyDetailsDiscarded == true then
        hint = "旧明细已清空；总量保留。先手动纠错，再保存到名单。"
    else
        hint = "先分别选择类型和关系；确认无误后保存到名单。"
    end
    local detailReplaying = (D.State.runtime ~= nil and D.State.runtime.replaying == true)
        or (D.Runtime ~= nil and D.Runtime.replayJob ~= nil)
    local detailReclassifyQueued = D.State.dirty ~= nil
        and D.State.dirty.reclassify == true
        and detailReplaying ~= true
    if detailReplaying then
        hint = "人工规则已写入；正在重新计算统计归属。当前排行仍是上一次已提交快照。 " .. hint
    elseif detailReclassifyQueued then
        hint = "人工规则已写入；统计归属正在等待分帧重算。 " .. hint
    end
    SetBoundedText(self.controls.detailHint, hint, self.controls.detailHint.repdpsWidth, 9)

    local isSelf = IsProtectedSelfEntity(entity)
    local effectiveKind = contextualKind
    local effectiveRelation = contextualRelation
    SetFittedControlText(self.controls.detailFriendly, effectiveRelation == "FRIENDLY" and "[友军]" or "设为友军", 9, 7)
    SetFittedControlText(self.controls.detailEnemy, effectiveRelation == "OPPONENT" and "[敌军]" or "设为敌军", 9, 7)
    SetFittedControlText(self.controls.detailPlayer, effectiveKind == "PLAYER" and "[玩家]" or "设为玩家", 9, 7)
    SetFittedControlText(self.controls.detailNpc, effectiveKind == "NPC" and "[NPC]" or "设为NPC", 9, 7)
    SetFittedControlText(self.controls.detailOther, (effectiveKind == "OTHER" or effectiveKind == "MATE" or effectiveKind == "SLAVE") and "[召唤/物件]" or "召唤/物件", 9, 7)
    local ignoreActive = override ~= nil and override.ignored == true
    local sessionIgnoreRestorable = ignoreActive and override.source == "session"
        and override.editedIgnored ~= false
    local ignoreButtonText = "忽略实体（本次）"
    if ignoreActive then
        if override.source == "rule" then
            ignoreButtonText = "[名单忽略]"
        elseif sessionIgnoreRestorable then
            ignoreButtonText = "[本次忽略] 恢复计入"
        else
            ignoreButtonText = "[继承名单忽略]"
        end
    end
    SetFittedControlText(self.controls.detailIgnore, ignoreButtonText, 10, 8)

    local hasSessionOverride = override ~= nil and override.source == "session"
    if hasSessionOverride and savedRule ~= nil then
        SetFittedControlText(self.controls.detailAuto, "撤销本次修改", 10, 8)
    elseif hasSessionOverride then
        SetFittedControlText(self.controls.detailAuto, "恢复自动判断", 10, 8)
    elseif override ~= nil and override.source == "rule" then
        SetFittedControlText(self.controls.detailAuto, "当前为名单规则", 10, 8)
    else
        SetFittedControlText(self.controls.detailAuto, "当前为自动判断", 10, 8)
    end
    if hasSessionOverride then
        SetFittedControlText(self.controls.detailSaveRule, "保存到名单（" .. (predictedMatch == "ID" and "ID" or "名称") .. "）", 10, 8)
    elseif savedRule ~= nil then
        SetFittedControlText(self.controls.detailSaveRule, "已保存到名单", 10, 8)
    else
        SetFittedControlText(self.controls.detailSaveRule, "请先人工修改", 10, 8)
    end
    SetFittedControlText(self.controls.detailRemoveRule, savedRule ~= nil and "从名单移除" or "未保存到名单", 10, 8)

    local analysisTarget = self:GetSelectedAnalysisTarget()
    local hasAnalysisTarget = analysisTarget ~= nil
    if self.controls.detailExcludeTarget ~= nil then
        local excluded = hasAnalysisTarget and D.Analysis:IsExcluded(analysisTarget)
        SetFittedControlText(self.controls.detailExcludeTarget, excluded and "[已排除] 恢复计入" or "排除目标数据", 10, 8)
        self.controls.detailExcludeTarget:Show(hasAnalysisTarget)
        if self.controls.detailExcludeTarget.Enable ~= nil then self.controls.detailExcludeTarget:Enable(hasAnalysisTarget) end
    end
    if self.controls.detailBossTarget ~= nil then
        local isBoss = hasAnalysisTarget and D.Analysis:IsBoss(analysisTarget)
        local bossAllowed = hasAnalysisTarget and effectiveKind ~= "PLAYER"
        SetFittedControlText(self.controls.detailBossTarget, isBoss and "[Boss统计] 取消" or "设为Boss统计", 10, 8)
        self.controls.detailBossTarget:Show(hasAnalysisTarget)
        if self.controls.detailBossTarget.Enable ~= nil then self.controls.detailBossTarget:Enable(bossAllowed or isBoss) end
    end

    local markEnabled = not isSelf
    for _, button in ipairs({ self.controls.detailFriendly, self.controls.detailEnemy, self.controls.detailPlayer,
        self.controls.detailNpc, self.controls.detailOther }) do
        if button.Enable ~= nil then button:Enable(markEnabled) end
    end
    if self.controls.detailIgnore.Enable ~= nil then
        self.controls.detailIgnore:Enable(markEnabled
            and (ignoreActive ~= true or sessionIgnoreRestorable == true))
    end
    if self.controls.detailAuto.Enable ~= nil then self.controls.detailAuto:Enable(hasSessionOverride) end
    if self.controls.detailSaveRule.Enable ~= nil then
        local hasEditableOverride = hasSessionOverride
            and (override.kind ~= nil or override.relation ~= nil or override.ignored == true)
        local nameOnlyPlayer = predictedMatch == "NAME" and effectiveKind == "PLAYER"
        local historicalAggregate = counterpartContext ~= nil
            and counterpartContext.identityQuality == "HISTORICAL_NAME_AGGREGATE"
        self.controls.detailSaveRule:Enable(markEnabled and hasEditableOverride and not nameOnlyPlayer and not historicalAggregate)
    end
    if self.controls.detailRemoveRule.Enable ~= nil then self.controls.detailRemoveRule:Enable(not isSelf and savedRule ~= nil) end

    local currentAbilityLabel = abilityLabel[selected.page] or "技能"
    SetFittedControlText(self.controls.detailAbility, self.detail.view == "ABILITY" and ("[" .. currentAbilityLabel .. "]") or currentAbilityLabel, 10, 8)
    SetFittedControlText(self.controls.detailCounterpart, self.detail.view == "COUNTERPART" and ("[" .. counterpartLabel .. "]") or counterpartLabel, 10, 8)
    if self.controls.detailAbility.Enable ~= nil then self.controls.detailAbility:Enable(true) end
    if self.controls.detailCounterpart.Enable ~= nil then self.controls.detailCounterpart:Enable(true) end
    local map = {}
    local combinedHealing = nil
    if selected.page == "HEAL" and type(StatsRead) == "table" then
        combinedHealing = StatsRead:GetCombinedHealingBreakdown(selected.side, selected.key)
    end
    if combinedHealing ~= nil then
        if self.detail.view == "COUNTERPART" then
            map = combinedHealing.counterparts or {}
        else
            map = combinedHealing.abilities or {}
        end
    elseif details ~= nil then
        if self.detail.view == "COUNTERPART" then
            map = selected.page == "TAKEN" and details.sources or details.targets
        else map = details.abilities end
    end
    -- Sorting a lossless PVE target map can become expensive after months of
    -- cumulative play. Cache only the stable name/value ordering and decorate
    -- the currently visible rows with live identity/exclusion flags below.
    local cacheKey = table.concat({
        tostring(selected.key or ""),
        tostring(selected.mode or ""),
        tostring(selected.side or ""),
        tostring(selected.page or ""),
        tostring(self.detail.view or ""),
        tostring(actor and actor.repdpsDetailRevision or 0),
        tostring(combinedHealing and combinedHealing.splitTargetRefAmount or 0),
        tostring(combinedHealing and combinedHealing.legacyNameAmount or 0),
    }, "|")
    local cache = self.detail.entryCache
    local entries, total
    local entriesBuilding = false
    if type(cache) == "table" and cache.key == cacheKey then
        entries = cache.entries
        total = cache.total
        self.detail.entryJob = nil
    else
        local job = self.detail.entryJob
        if type(job) ~= "table" or job.key ~= cacheKey or job.map ~= map then
            job = BeginDetailEntryJob(map, cacheKey)
            self.detail.entryJob = job
        end
        local highLoad = D.Runtime ~= nil and D.Runtime.IsHighLoad ~= nil
            and D.Runtime:IsHighLoad(U.NowMs())
        local finished = StepDetailEntryJob(job, highLoad and 240 or 1000)
        if finished then
            entries = job.entries
            total = job.total
            self.detail.entryCache = { key = cacheKey, entries = entries, total = total }
            self.detail.entryJob = nil
        else
            -- Do not expose a partially heap-sorted array. Keep the detail
            -- window responsive and continue the exact full ordering on later
            -- UI refreshes instead of sorting a potentially huge target map in
            -- one frame.
            entries = {}
            total = job.total
            entriesBuilding = true
        end
    end
    local visibleRows = U.Clamp(self.visibleDetailRows or DETAIL_ROWS, 0, DETAIL_ROWS)
    local maxOffset = visibleRows > 0 and math.max(0, #entries - visibleRows) or 0
    local offset = visibleRows > 0 and U.Clamp(tonumber(self.detail.offset) or 0, 0, maxOffset) or 0
    self.detail.offset = offset
    self.detail.totalEntries = #entries
    local maxValue = visibleRows > 0 and entries[offset + 1] and entries[offset + 1].value or 0
    local pageStart = visibleRows > 0 and #entries > 0 and offset + 1 or 0
    local pageEnd = visibleRows > 0 and math.min(#entries, offset + visibleRows) or 0
    if entriesBuilding then
        local job = self.detail.entryJob
        SetFittedControlText(self.controls.detailPage,
            "整理中 " .. tostring(job and #job.entries or 0), 9, 7)
    else
        SetFittedControlText(self.controls.detailPage, string.format("%d-%d/%d", pageStart, pageEnd, #entries), 9, 7)
    end
    if self.controls.detailPrev.Enable ~= nil then self.controls.detailPrev:Enable(visibleRows > 0 and offset > 0) end
    if self.controls.detailNext.Enable ~= nil then self.controls.detailNext:Enable(visibleRows > 0 and offset < maxOffset) end
    for i = 1, DETAIL_ROWS do
        local row = self.detailRows[i]
        local absoluteIndex = offset + i
        local entry = entries[absoluteIndex]
        if i <= visibleRows and entry ~= nil then
            if self.detail.view == "COUNTERPART" then
                entry.kind = "COUNTERPART"
                local lookupName = entry.displayName or entry.name
                if entry.identityQuality == nil then
                    entry.identityQuality = Actors:HasNameConflict(lookupName)
                        and "AMBIGUOUS" or "NAME"
                end
                entry.originMode = selected.mode
                entry.originSide = selected.side
                entry.originPage = selected.page
                if D.Analysis:IsPveFriendlyDamageScope(selected.mode, selected.side, selected.page) then
                    local analysisName = entry.displayName or entry.name
                    entry.analysisExcluded = D.Analysis:IsExcluded(analysisName)
                    entry.analysisBoss = D.Analysis:IsBoss(analysisName)
                else
                    entry.analysisExcluded = nil
                    entry.analysisBoss = nil
                end
            else
                entry.kind = nil
                entry.identityQuality = nil
                entry.analysisExcluded = nil
                entry.analysisBoss = nil
            end
            local pct = total > 0 and entry.value / total * 100 or 0
            local panelWidth = math.max(1, tonumber(row.panel:GetWidth()) or 440)
            row.bar:SetExtent(math.max(1, math.floor(panelWidth * (maxValue > 0 and entry.value / maxValue or 0))), math.max(1, tonumber(row.panel:GetHeight()) or 21))
            local rowName = tostring(absoluteIndex) .. ". " .. tostring(entry.name)
            if entry.kind == "COUNTERPART" and not IsCounterpartPlaceholder(entry.displayName or entry.name) then
                if entry.identityQuality == "AMBIGUOUS" then
                    rowName = rowName .. "  [同名]"
                elseif entry.identityQuality == "TARGET_REF_ACTOR" then
                    rowName = rowName .. "  [精确]"
                elseif entry.readOnlyHistory ~= true then
                    rowName = rowName .. "  [可纠错]"
                end
                if entry.analysisBoss == true then rowName = rowName .. " [Boss]" end
                if entry.analysisExcluded == true then rowName = rowName .. " [已排除]" end
                row.data = entry
            else
                row.data = nil
            end
            SetBoundedText(row.name, rowName, row.name.repdpsWidth, 10)
            SetBoundedText(row.value, DisplayNumber(entry.value) .. string.format("  %.0f%%", pct), row.value.repdpsWidth, 10)
            row.panel:Show(true)
        else
            row.data = nil
            row.panel:Show(false)
        end
    end
end

function UIX:ToggleExcludedTarget(name)
    local ok, changedOrError = D.Analysis:ToggleExcluded(name)
    if not ok then
        D.Boot.SafeChat("排除目标失败：" .. tostring(changedOrError or "未知错误"))
        return false
    end
    local excluded = D.Analysis:IsExcluded(name)
    if excluded then
        D.Boot.SafeChat("已排除 PVE 友军伤害目标：" .. tostring(name) .. "；原始数据继续后台累计。")
    else
        D.Boot.SafeChat("已恢复计入 PVE 友军伤害目标：" .. tostring(name))
    end
    self.rankingOffsets.friendly = 0
    self:RefreshDetail()
    self:RefreshQuickWindows()
    return true
end

function UIX:ToggleSelectedExcludedTarget()
    local name = self:GetSelectedAnalysisTarget()
    if name == nil then
        D.Boot.SafeChat("只有从 PVE 友军伤害详情打开的具体目标才能排除。")
        return false
    end
    return self:ToggleExcludedTarget(name)
end

function UIX:ToggleBossTarget(name, entity)
    name = U.Trim(name)
    if name == "" then
        D.Boot.SafeChat("设置 Boss 失败：目标名称为空。")
        return false
    end
    local resolved = entity
    if type(resolved) ~= "table" then
        resolved = Actors:FindFirstByName(name)
    end
    local resolvedKind = EffectiveEntityKind(resolved)
    if resolvedKind == "PLAYER" then
        D.Boot.SafeChat("设置 Boss 失败：当前目标已确认是玩家。")
        return false
    end
    local ok, enabledOrError = D.Analysis:SetBossTarget(name)
    if not ok then
        D.Boot.SafeChat("设置 Boss 失败：" .. tostring(enabledOrError or "未知错误"))
        return false
    end
    D.State.config.currentMode = "PVE"
    D.State.config.currentPage = "DAMAGE"
    self.rankingOffsets.friendly = 0
    self.rankingOffsets.enemy = 0
    D.MarkConfigDirty()
    D.MarkLayoutDirty()
    D.MarkViewDirty()
    if enabledOrError == true then
        D.Boot.SafeChat("已启用 Boss 专注统计：" .. tostring(name) .. "；已包含此前累计。")
    else
        D.Boot.SafeChat("已取消 Boss 专注统计：" .. tostring(name))
    end
    self:RefreshControls()
    self:RefreshDetail()
    self:RefreshQuickWindows()
    return true
end

function UIX:ToggleCurrentTargetBoss()
    if not IsDpsModuleEnabled() then
        D.Boot.SafeChat("当前模块未启用；读取当前目标前请先启用伤害统计。")
        return false
    end
    if D.Runtime == nil or D.Runtime.GetCurrentTargetSnapshot == nil then
        D.Boot.SafeChat("当前版本无法读取游戏目标。")
        return false
    end
    local snapshot, err = D.Runtime:GetCurrentTargetSnapshot()
    if type(snapshot) ~= "table" then
        D.Boot.SafeChat(tostring(err or "请先在游戏中选中 Boss。"))
        return false
    end
    return self:ToggleBossTarget(snapshot.name, snapshot.entity)
end

function UIX:ToggleSelectedBossTarget()
    local name = self:GetSelectedAnalysisTarget()
    if name == nil then
        D.Boot.SafeChat("只有从 PVE 友军伤害详情打开的具体目标才能设为 Boss。")
        return false
    end
    local selected, _, entity = self:GetSelectedDetail()
    return self:ToggleBossTarget(name, entity or (selected and selected.entityRef) or nil)
end


function UIX:ClearActiveDamageAnalysis()
    if D.State.config.currentMode ~= "PVE" or D.State.config.currentPage ~= "DAMAGE" then return false end
    local boss = D.Analysis:GetBossTarget()
    if boss ~= nil then
        D.Analysis:ClearBossTarget()
        D.Boot.SafeChat("已取消 Boss 专注统计：" .. tostring(boss.name))
    elseif D.Analysis:GetExcludedCount() > 0 then
        local count = D.Analysis:GetExcludedCount()
        D.Analysis:ClearExclusions()
        D.Boot.SafeChat("已恢复全部排除目标，共 " .. tostring(count) .. " 个；原始统计未发生变化。")
    else
        return false
    end
    self.rankingOffsets.friendly = 0
    self:RefreshDetail()
    self:RefreshQuickWindows()
    return true
end

local function ManualReclassifySuffix()
    if D.EventStore ~= nil and D.EventStore.historyCoverageComplete == false then
        local windowSafe = D.Runtime ~= nil and D.Runtime.CanReplayCurrentWindow ~= nil
            and D.Runtime:CanReplayCurrentWindow() == true
        if windowSafe then
            return "；最近纠错窗口将在战斗空档后重新归类，窗口以前的旧累计保持冻结。"
        end
        return "；新规则立即用于后续事件，最近纠错窗口将在安全基线完成后重新归类。"
    end
    return "；相关统计将在战斗空档后重新归类。"
end

function UIX:ApplySelectedManual(kind, relation, ignored)
    local selected, _, entity = self:GetSelectedDetail()
    if selected == nil then return end
    local actionKey = entity ~= nil and entity.key or selected.key
    local projectionKey = selected.projectionKey or selected.key
    local ok, err = D.Entities:ApplyManualByKey(
        actionKey, kind, relation, ignored, projectionKey)
    if ok then
        if err == "NO_CHANGE" then
            D.Boot.SafeChat("当前单位已经是该人工标记，无需重复重新计算：" .. tostring(selected.name or selected.key))
            self:RefreshDetail()
            return
        end
        D.Boot.SafeChat("已更新单位标记：" .. tostring(selected.name or selected.key)
            .. ManualReclassifySuffix())
        self:RefreshDetail()
        self:RefreshQuickWindows()
    else
        D.Boot.SafeChat("更新单位标记失败：" .. tostring(err or "未知错误"))
    end
end

function UIX:ToggleSelectedIgnore()
    local selected, _, entity = self:GetSelectedDetail()
    if selected == nil or entity == nil then return end
    local actionKey = entity.key or selected.key
    local projectionKey = selected.projectionKey or selected.key
    local override = nil
    if D.Entities ~= nil and type(D.Entities.GetManualOverrideByKey) == "function" then
        override = D.Entities:GetManualOverrideByKey(actionKey, projectionKey)
    else
        override = type(entity.manualOverride) == "table" and entity.manualOverride or nil
    end
    if override ~= nil and override.ignored == true then
        local ok, reason = D.Entities:ClearSessionIgnoreByKey(actionKey, projectionKey)
        if ok then
            local text = reason == "RESTORED_RULE_IGNORE"
                and "已撤销本次忽略；该单位仍由名单规则忽略："
                or "已恢复计入，同时保留该单位的类型和敌我设置："
            D.Boot.SafeChat(text .. tostring(selected.name or selected.key)
                .. (reason == "RESTORED_RULE_IGNORE" and "" or ManualReclassifySuffix()))
            self:RefreshDetail()
            self:RefreshQuickWindows()
        else
            D.Boot.SafeChat(tostring(reason or "当前忽略状态不能在这里恢复"))
        end
        return
    end
    self:ApplySelectedManual(nil, nil, true)
end

function UIX:ClearSelectedManual()
    local selected, _, entity = self:GetSelectedDetail()
    if selected == nil then return end
    local actionKey = entity ~= nil and entity.key or selected.key
    local projectionKey = selected.projectionKey or selected.key
    local override = nil
    if entity ~= nil and D.Entities ~= nil and type(D.Entities.GetManualOverrideByKey) == "function" then
        override = D.Entities:GetManualOverrideByKey(actionKey, projectionKey)
    else
        override = entity and entity.manualOverride or nil
    end
    if override ~= nil and override.source == "rule" then
        D.Boot.SafeChat("该单位当前使用持久名单规则；请点击“从名单移除”后恢复自动判断。")
        return
    end
    local hadRule = false
    if entity ~= nil and D.Entities ~= nil and type(D.Entities.GetPersistentRuleByKey) == "function" then
        hadRule = D.Entities:GetPersistentRuleByKey(actionKey, projectionKey) ~= nil
    elseif entity ~= nil and D.Rules ~= nil then
        hadRule = D.Rules:GetForEntity(entity) ~= nil
    end
    if D.Entities:ClearManualByKey(actionKey, projectionKey) then
        D.Boot.SafeChat((hadRule and "已撤销本次修改并恢复名单规则：" or "已恢复自动判断：")
            .. tostring(selected.name or selected.key) .. ManualReclassifySuffix())
        self:RefreshDetail()
        self:RefreshQuickWindows()
    else
        D.Boot.SafeChat("该单位当前没有可撤销的本次手动标记。")
    end
end

function UIX:SaveSelectedRule()
    local selected, _, entity = self:GetSelectedDetail()
    if selected == nil then return end
    local actionKey = entity ~= nil and entity.key or selected.key
    local projectionKey = selected.projectionKey or selected.key
    local rule, matchModeOrError = D.Entities:SaveManualRuleByKey(actionKey, nil, projectionKey)
    if rule == nil then
        D.Boot.SafeChat("保存名单失败：" .. tostring(matchModeOrError or "未知错误"))
        return
    end
    D.Boot.SafeChat(string.format("已保存到名单：%s（按%s匹配）", tostring(rule.displayName),
        matchModeOrError == "ID" and "单位ID" or "名称") .. ManualReclassifySuffix())
    self.ruleList.selectedRuleId = rule.ruleId
    self:RefreshDetail()
    self:RefreshRulesPage()
    self:RefreshQuickWindows()
end

function UIX:RemoveSelectedRule()
    local selected, _, entity = self:GetSelectedDetail()
    if selected == nil then return end
    local actionKey = entity ~= nil and entity.key or selected.key
    local projectionKey = selected.projectionKey or selected.key
    if D.Entities:RemovePersistentRuleByKey(actionKey, projectionKey) then
        D.Boot.SafeChat("已从名单移除：" .. tostring(selected.name or selected.key) .. ManualReclassifySuffix())
        self:RefreshDetail()
        self:RefreshRulesPage()
        self:RefreshQuickWindows()
    else
        D.Boot.SafeChat("该单位没有可移除的名单规则。")
    end
end

local function RuleKindRelationText(rule)
    if rule == nil then return "" end
    local parts = {}
    if rule.kind ~= nil then parts[#parts + 1] = KindLabel(rule.kind) end
    if rule.relation ~= nil then parts[#parts + 1] = RelationLabel(rule.relation) end
    if rule.ignored == true then parts[#parts + 1] = "忽略" end
    return #parts > 0 and table.concat(parts, "/") or "无分类"
end

function UIX:RefreshRulesPage()
    if self.controls.rulesSummary == nil or D.Rules == nil then return end
    local entries = D.Rules:List()
    local visible = U.Clamp(tonumber(self.ruleList.visibleRows) or 8, 1, #self.ruleRows)
    local maxOffset = math.max(0, #entries - visible)
    local offset = U.Clamp(tonumber(self.ruleList.offset) or 0, 0, maxOffset)
    self.ruleList.offset = offset
    self.ruleList.totalEntries = #entries
    if self.ruleList.selectedRuleId ~= nil and D.Rules:GetById(self.ruleList.selectedRuleId) == nil then
        self.ruleList.selectedRuleId = nil
    end
    SetBoundedText(self.controls.rulesSummary,
        string.format("已保存 %d 条规则（上限 %d）。单位ID优先，名称规则遇到同名冲突会暂停。", #entries, D.Const.MAX_PERSISTENT_RULES or 500),
        self.controls.rulesSummary.repdpsWidth, 10)
    for i, row in ipairs(self.ruleRows) do
        local rule = i <= visible and entries[offset + i] or nil
        row.ruleId = rule and rule.ruleId or nil
        if rule ~= nil then
            local selected = tostring(rule.ruleId) == tostring(self.ruleList.selectedRuleId)
            local stateText = rule.enabled == false and "停" or "启"
            local matchText = rule.matchType == "ID" and "ID" or "名"
            local text = string.format("%s[%s][%s] %s · %s", selected and ">" or " ", stateText, matchText, tostring(rule.displayName), RuleKindRelationText(rule))
            SetBoundedText(row.button, text, row.button.repdpsWidth, 9)
            row.button:Show(true)
        else
            row.button:SetText("")
            row.button:Show(false)
        end
    end
    local startIndex = #entries > 0 and offset + 1 or 0
    local endIndex = math.min(#entries, offset + visible)
    SetFittedControlText(self.controls.rulesPage, string.format("%d-%d/%d", startIndex, endIndex, #entries), 9, 7)
    if self.controls.rulesPrev.Enable ~= nil then self.controls.rulesPrev:Enable(offset > 0) end
    if self.controls.rulesNext.Enable ~= nil then self.controls.rulesNext:Enable(offset < maxOffset) end
    local selectedRule = self.ruleList.selectedRuleId and D.Rules:GetById(self.ruleList.selectedRuleId) or nil
    SetFittedControlText(self.controls.rulesToggle, selectedRule ~= nil and (selectedRule.enabled == false and "启用规则" or "禁用规则") or "启用/禁用", 9, 7)
    if self.controls.rulesToggle.Enable ~= nil then self.controls.rulesToggle:Enable(selectedRule ~= nil) end
    if self.controls.rulesDelete.Enable ~= nil then self.controls.rulesDelete:Enable(selectedRule ~= nil) end
    local armed = U.NowMs() - (tonumber(self.ruleList.clearArmedAt) or 0) <= 5000
    SetFittedControlText(self.controls.rulesClear, armed and "再次点击确认清空" or "清空全部名单", 9, 7)
    self.controls.rulesHelp:SetText(FitMultilineText(
        self.controls.rulesHelp,
        "点击规则可选择。个人人工裁决优先；[公会待识别]表示已记录同步意图，但尚未取得可靠公会ID。名称规则同名冲突时暂停。",
        self.controls.rulesHelp.repdpsWidth, 9, 3))
end

function UIX:RefreshQuickWindow(sideName)
    local window = self.windows[sideName]
    if window == nil or not window:IsVisible() then return end
    local mode = D.State.config.currentMode
    local page = self:GetQuickPage()
    local compactMode = D.State.config.compactMode == true
    local ranking, total, metric, side, analysisView = D.Stats:BuildRanking(mode, sideName, page)
    -- Most duplicate display names are repaired at the entity/stat key layer.
    -- If official API limitations still leave two genuinely different scopes
    -- (for example a concrete ID plus an unassignable historical name aggregate),
    -- label those rows instead of presenting two visually identical players.
    local duplicateNameCounts = {}
    if not compactMode then
        for _, duplicateItem in ipairs(type(ranking) == "table" and ranking or {}) do
            local normalized = U.NormalizeName(duplicateItem and duplicateItem.name)
            if normalized ~= "" then
                duplicateNameCounts[normalized] = (duplicateNameCounts[normalized] or 0) + 1
            end
        end
    end
    local rankingLimit = U.Clamp(D.State.config.displayRows, 1, C.MAX_RANKING_ROWS)
    local pinnedSelf = nil
    if sideName == "friendly" and D.State.config.alwaysShowSelf then
        for _, item in ipairs(ranking) do
            local normalized = U.NormalizeName(item.name)
            if item.key == D.Identity.entityKey
                or normalized == U.NormalizeName(D.Identity.playerName)
                or normalized == U.NormalizeName(D.Identity.playerNameWithWorld) then
                pinnedSelf = item
                break
            end
        end
    end
    while #ranking > rankingLimit do table.remove(ranking) end
    if pinnedSelf ~= nil then
        local present = false
        for _, item in ipairs(ranking) do if item == pinnedSelf or item.key == pinnedSelf.key then present = true break end end
        -- The configured ranking limit applies to normal rows.  "Always show
        -- self" is an explicit extra pinned row and must still work when the
        -- player ranks below that limit.
        if not present then ranking[#ranking + 1] = pinnedSelf end
    end

    local visibleRows = U.Clamp(self.visibleRows[sideName] or 10, 1, C.MAX_ROWS)
    local maxOffset = math.max(0, #ranking - visibleRows)
    local offset = U.Clamp(self.rankingOffsets[sideName] or 0, 0, maxOffset)
    self.rankingOffsets[sideName] = offset

    if sideName == "friendly" and D.State.config.alwaysShowSelf and #ranking > 0 then
        local selfIndex = nil
        for i, item in ipairs(ranking) do
            local normalized = U.NormalizeName(item.name)
            if item.key == D.Identity.entityKey
                or normalized == U.NormalizeName(D.Identity.playerName)
                or normalized == U.NormalizeName(D.Identity.playerNameWithWorld) then
                selfIndex = i
                break
            end
        end
        if selfIndex ~= nil and (selfIndex <= offset or selfIndex > offset + visibleRows) and offset == 0 then
            local selfItem = table.remove(ranking, selfIndex)
            local insertAt = math.min(visibleRows, #ranking + 1)
            table.insert(ranking, insertAt, selfItem)
            maxOffset = math.max(0, #ranking - visibleRows)
        end
    end

    local maxValue = #ranking > 0 and ranking[1].value or 0
    local rows = self.rows[sideName]
    for rowIndex = 1, C.MAX_ROWS do
        local row = rows[rowIndex]
        local rankingIndex = offset + rowIndex
        if rowIndex <= visibleRows and ranking[rankingIndex] ~= nil then
            local item = ranking[rankingIndex]
            local pctBar = maxValue > 0 and item.value / maxValue or 0
            local width = math.max(1, math.floor((window:GetWidth() - 8) * pctBar))
            row.bar:SetExtent(width, math.max(14, row.panel:GetHeight()))
            local entity = Actors:GetEntityByKey(item.key)
            local marker = ""
            local normalizedItemName = U.NormalizeName(item.name)
            if not compactMode and duplicateNameCounts[normalizedItemName] ~= nil
                and duplicateNameCounts[normalizedItemName] > 1 then
                local keyText = tostring(item.key or "")
                if string.sub(keyText, 1, 8) == "history:" then marker = marker .. "[历史]"
                elseif string.sub(keyText, 1, 10) == "ambiguous:" then marker = marker .. "[同名汇总]"
                elseif string.sub(keyText, 1, 9) == "teamname:" then marker = marker .. "[团队名]"
                elseif string.sub(keyText, 1, 3) == "id:" then marker = marker .. "[ID]" end
            end
            if not compactMode and D.State.config.showSuspect then
                if item.actor ~= nil and item.actor.provisional == true then marker = marker .. "[推]" end
                if entity ~= nil then
                    if entity.kind == "OTHER" then marker = marker .. "[物]"
                    elseif entity.kind == "SLAVE" then marker = marker .. "[召]"
                    elseif entity.kind == "MATE" then marker = marker .. "[宠]"
                    elseif entity.kind == "NPC" and sideName == "friendly" then marker = marker .. "[NPC]" end
                    if entity.flags ~= nil and entity.flags.nameConflict == true then marker = marker .. "[同名]" end
                    if entity.flags ~= nil and entity.flags.relationConflict == true then marker = marker .. "[冲]" end
                    if entity.manualOverride ~= nil then
                        if entity.manualOverride.source == "rule" then
                            marker = marker .. (entity.manualOverride.ignored and "[名忽]" or "[名]")
                        else
                            marker = marker .. (entity.manualOverride.ignored and "[忽略]" or "[M]")
                        end
                    elseif entity.hardRelation == nil and (entity.relation == "FRIENDLY" or entity.relation == "OPPONENT") then
                        marker = marker .. "[?]"
                    end
                end
            end
            -- Pass the complete name once and let the official font metrics
            -- decide whether truncation is actually required.  The old path
            -- truncated by character count first and then truncated again by
            -- width, which made Chinese names much shorter than necessary.
            SetBoundedText(row.name,
                tostring(item.rank or rankingIndex) .. ". " .. tostring(item.name or "未知") .. marker,
                row.name.repdpsWidth,
                compactMode and 9 or 10
            )
            SetBoundedText(row.amount, DisplayNumber(item.value), row.amount.repdpsWidth, compactMode and 9 or 10)
            if page == "KILLS" or row.showRateColumn ~= true then
                row.rate:SetText("")
            elseif type(analysisView) == "table" and analysisView.rateUnavailable == true then
                row.rate:SetText("-")
            else
                SetBoundedText(row.rate, DisplayNumber(item.rate) .. " " .. MetricRateLabel(page, analysisView), row.rate.repdpsWidth, 10)
            end
            if D.State.config.showPercent and row.showPercentColumn == true then
                SetBoundedText(row.percent, string.format("%.0f%%", item.percent), row.percent.repdpsWidth, 10)
            else
                row.percent:SetText("")
            end
            row.data = item
            row.panel:Show(true)
        else
            row.panel:Show(false)
            row.data = nil
        end
    end

    local totalRate = 0
    if not compactMode and page ~= "KILLS" then
        local activeMs
        if type(analysisView) == "table" and analysisView.enabled == true and analysisView.totalActiveMs ~= nil then
            activeMs = tonumber(analysisView.totalActiveMs) or 0
        else
            activeMs = D.Stats:GetSideMetricActiveMs(side, metric, U.NowMs())
        end
        totalRate = total / math.max(activeMs / 1000, 1)
    end
    local titlePrefix = (sideName == "friendly" and "友军" or "敌军")
    -- 人工规则先更新 Entity Authority，再由分帧重放原子提交新的 Stats
    -- 投影。等待任务启动时旧排行仍是最后一次已提交快照，因此必须和
    -- “重放进行中”一样明确标识，避免用户误以为按钮没有生效。
    local replaying = (D.State.runtime ~= nil and D.State.runtime.replaying == true)
        or (D.Runtime ~= nil and D.Runtime.replayJob ~= nil)
    local reclassifyQueued = D.State.dirty ~= nil
        and D.State.dirty.reclassify == true
        and replaying ~= true
    if replaying then
        titlePrefix = titlePrefix .. " [重新计算中]"
    elseif reclassifyQueued then
        titlePrefix = titlePrefix .. " [等待重新归类]"
    end
    if type(analysisView) == "table" and analysisView.kind == "BOSS" and analysisView.bossTarget ~= nil then
        titlePrefix = titlePrefix .. " Boss[" .. tostring(analysisView.bossTarget.name) .. "]"
    elseif type(analysisView) == "table" and analysisView.kind == "EXCLUDED" then
        titlePrefix = titlePrefix .. " 有效"
    end
    local title
    if compactMode then
        title = (sideName == "friendly" and "友军" or (mode .. " 敌军")) .. "伤害 " .. DisplayNumber(total)
        if replaying or reclassifyQueued then title = title .. " *" end
    else
        title = titlePrefix .. " " .. PageLabel(page) .. "：" .. DisplayNumber(total)
        if page ~= "KILLS" and not (type(analysisView) == "table" and analysisView.rateUnavailable == true) then
            title = title .. "  " .. DisplayNumber(totalRate) .. " " .. MetricRateLabel(page, analysisView)
        end
    end
    if sideName == "friendly" then
        SetBoundedText(self.controls.friendlyTitle, title, self.controls.friendlyTitle.repdpsWidth, compactMode and 10 or 12)
    else
        SetBoundedText(self.controls.enemyTitle, title, self.controls.enemyTitle.repdpsWidth, compactMode and 10 or 13)
        local mirrorMode = page == "HEAL" and "共享" or mode
        if compactMode then
            self.controls.enemyMirror:SetText("")
        else
            SetBoundedText(self.controls.enemyMirror, mirrorMode .. " / " .. PageLabel(page), self.controls.enemyMirror.repdpsWidth, 10)
        end
    end

    local footer = ""
    if not compactMode then
        local modeStats = D.Stats:GetMode(mode)
        if type(analysisView) == "table" and analysisView.kind == "BOSS" and analysisView.bossTarget ~= nil then
            footer = "Boss统计 " .. tostring(analysisView.bossTarget.name) .. "（包含此前累计，点击取消）· 目标级历史时间不足，DPS不显示"
        elseif type(analysisView) == "table" and analysisView.kind == "EXCLUDED" then
            footer = "已排除目标 " .. tostring(analysisView.excludedCount or 0) .. " 个（点击恢复全部）· 目标级历史时间不足，DPS不显示"
        end
        if page == "HEAL" then
            local pvpStats = D.Stats:GetMode("PVP")
            local pveStats = D.Stats:GetMode("PVE")
            if D.State.config.showPendingSummary then
                local pendingHeal = (tonumber(pvpStats.pending and pvpStats.pending.heal) or 0)
                    + (tonumber(pveStats.pending and pveStats.pending.heal) or 0)
                footer = "待确认治疗 " .. U.FormatNumber(pendingHeal)
            end
            if D.State.config.showThirdPartySummary then
                local thirdPartyHeal = (tonumber(pvpStats.thirdParty and pvpStats.thirdParty.heal) or 0)
                    + (tonumber(pveStats.thirdParty and pveStats.thirdParty.heal) or 0)
                footer = footer .. "  第三方治疗 " .. U.FormatNumber(thirdPartyHeal)
            end
        else
            -- Healing now has one shared summary. Do not mix the canonical healing
            -- bucket into PVE damage/taken footers or the PVE view will appear to
            -- have more unresolved combat merely because healing is active.
            if D.State.config.showPendingSummary then
                footer = footer .. (footer ~= "" and "  " or "") .. "待确认伤害 " .. U.FormatNumber(tonumber(modeStats.pending and modeStats.pending.damage) or 0)
            end
            if D.State.config.showThirdPartySummary then
                footer = footer .. (footer ~= "" and "  " or "") .. "第三方伤害 " .. U.FormatNumber(tonumber(modeStats.thirdParty and modeStats.thirdParty.damage) or 0)
            end
            if D.State.config.showClosure and not (type(analysisView) == "table" and analysisView.enabled == true) then
                local closureStats = D.Stats:EnsureClosureCurrent(mode)
                closureStats = type(closureStats) == "table" and closureStats or {}
                local closure = sideName == "friendly"
                    and (tonumber(closureStats.friendlyDamageVsEnemyTaken) or 0)
                    or (tonumber(closureStats.enemyDamageVsFriendlyTaken) or 0)
                footer = footer .. string.format("  对账 %.0f%%", closure)
            end
        end
    end

    local pageLabel = self.controls[sideName .. "Page"]
    local prevButton = self.controls[sideName .. "Prev"]
    local nextButton = self.controls[sideName .. "Next"]
    if pageLabel ~= nil then
        local first = #ranking == 0 and 0 or (offset + 1)
        local last = math.min(#ranking, offset + visibleRows)
        SetBoundedText(pageLabel, tostring(first) .. "-" .. tostring(last) .. "/" .. tostring(#ranking), pageLabel.repdpsWidth or 58, compactMode and 8 or 9)
    end
    if prevButton ~= nil and prevButton.Enable ~= nil then prevButton:Enable(offset > 0) end
    if nextButton ~= nil and nextButton.Enable ~= nil then nextButton:Enable(offset < maxOffset) end

    local reclassifyStatus = ""
    if replaying then
        reclassifyStatus = "统计正在重新归类，当前显示上一次已提交快照"
    elseif reclassifyQueued then
        reclassifyStatus = "人工规则已更新，统计归属等待重新计算"
    end
    if reclassifyStatus ~= "" and not compactMode then
        footer = reclassifyStatus .. (footer ~= "" and (" · " .. footer) or "")
    end

    if sideName == "friendly" then
        SetBoundedText(self.controls.friendlyFooter, footer, self.controls.friendlyFooter.repdpsWidth, 9)
    else
        SetBoundedText(self.controls.enemyFooter, footer, self.controls.enemyFooter.repdpsWidth, 9)
    end
    return D.Stats:IsRankingCacheCurrent(mode, sideName, page)
end

function UIX:NeedsRateRefresh()
    if self.detail ~= nil and self.detail.entryJob ~= nil
        and self.windows ~= nil and self.windows.detail ~= nil
        and self.windows.detail:IsVisible() then
        return true
    end
    if D.State.config.compactMode == true then return false end
    local page = self:GetQuickPage()
    if page == "KILLS" then return false end
    local metric = page == "TAKEN" and "taken" or (page == "HEAL" and "heal" or "damage")
    local now = U.NowMs()
    local grace = D.State.config.uiRefreshMs or 500
    local modes = page == "HEAL" and { "PVP", "PVE" } or { D.State.config.currentMode }
    for _, modeName in ipairs(modes) do
        local modeStats = D.Stats:GetMode(modeName)
        for _, sideName in ipairs({ "friendly", "enemy" }) do
            local active = modeStats[sideName] and modeStats[sideName].active and modeStats[sideName].active[metric]
            if D.Stats:IsActiveClockChanging(active, now, D.State.config.sideWindowMs, grace) then return true end
        end
    end
    return false
end

function UIX:RefreshQuickWindows()
    self:RefreshControls()
    local friendlyCurrent = self:RefreshQuickWindow("friendly") ~= false
    local enemyCurrent = self:RefreshQuickWindow("enemy") ~= false
    self:RefreshDetail()
    if friendlyCurrent and enemyCurrent then
        self.lastRenderedStatsRevision = tonumber(D.Stats.statsMutationRevision) or 0
        D.State.dirty.stats = false
        D.State.dirty.view = false
        return true
    end
    -- 排行榜仍在分帧追赶时保持 dirty；任务提交会再次 MarkViewDirty。
    D.State.dirty.stats = true
    D.State.dirty.view = true
    return false
end

function UIX:ApplyQuickPresentation(sideName)
    local window = self.windows[sideName]
    if window == nil then return end
    local scale = U.Clamp(tonumber(D.State.config.rankingScale) or 1.00, 0.60, 1.20)
    local opacity = U.Clamp(tonumber(D.State.config.rankingOpacity) or 1.00, 0.50, 1.00)
    -- GetEffectiveExtent includes native SetScale on RU builds. Record our
    -- presentation scale so geometry persistence can undo it safely.
    window.repdpsScale = scale
    if window.SetScale ~= nil then pcall(function() window:SetScale(scale) end) end
    if window.SetAlpha ~= nil then pcall(function() window:SetAlpha(opacity) end) end
end

function UIX:LayoutQuickWindow(sideName)
    local window = self.windows[sideName]
    if window == nil then return end
    local compactMode = D.State.config.compactMode == true
    local locked = IsQuickHudLocked(sideName)
    local rect = D.State.ui[sideName]
    local presentationScale = U.Clamp(tonumber(D.State.config.rankingScale) or 1.00, 0.60, 1.20)
    rect.visualScale = presentationScale
    window.repdpsScale = presentationScale
    local x, y, width, height = U.ResolveRect(rect, C.FRIENDLY_WINDOW_W, C.QUICK_WINDOW_H)
    local _, _, _, logicalWidth, logicalHeight = U.GetUiMetrics()
    -- SetScale changes the visible footprint but not our logical SetExtent
    -- Authority. Cap the logical extent so the presented rectangle can still
    -- fit inside the viewport at scales above 100%.
    local maxWindowWidth = math.max(1, math.min(logicalWidth, math.floor(logicalWidth / presentationScale)))
    local maxWindowHeight = math.max(1, math.min(logicalHeight, math.floor(logicalHeight / presentationScale)))

    local headerHeight = compactMode and 30 or C.HEADER_H
    local footerHeight = compactMode and 20 or C.FOOTER_H
    local baseRowHeight = compactMode and 18 or C.ROW_H
    -- Architecture v1.1: user size is Authority.  Keep only a tiny technical
    -- floor so a deliberately narrow ranking HUD remains recoverable.
    local minimumWidthFloor = math.min(96, maxWindowWidth)
    local safeMinWidth = minimumWidthFloor
    local oneRowHeight = headerHeight + footerHeight + baseRowHeight + 4
    local safeMinHeight = math.min(maxWindowHeight, math.max(32, math.min(oneRowHeight, 48)))

    width = U.Clamp(math.max(safeMinWidth, width), minimumWidthFloor, maxWindowWidth)
    height = U.Clamp(math.max(safeMinHeight, height), safeMinHeight, maxWindowHeight)
    rect.width = width
    rect.height = height
    U.SetRectFromLogical(rect, x, y, width, height)
    x, y, width, height = U.ResolveRect(rect, width, height)
    local dragHost = self.dragHosts and self.dragHosts[sideName] or nil
    if dragHost ~= nil then
        dragHost:RemoveAllAnchors()
        dragHost:AddAnchor("TOPLEFT", "UIParent", x, y)
        dragHost:SetExtent(math.max(1, width * presentationScale), math.max(1, height * presentationScale))
        dragHost:Show(window:IsVisible())
        window:RemoveAllAnchors()
        window:AddAnchor("TOPLEFT", dragHost, 0, 0)
        window:SetExtent(width, height)
    else
        U.ApplyRect(window, rect, width, height)
    end
    if window.SetMinResizingExtent ~= nil then
        pcall(function() window:SetMinResizingExtent(minimumWidthFloor, safeMinHeight) end)
    end
    if window.SetMaxResizingExtent ~= nil then
        pcall(function() window:SetMaxResizingExtent(maxWindowWidth, maxWindowHeight) end)
    end

    local headerBg = sideName == "friendly" and self.controls.friendlyHeaderBg or self.controls.enemyHeaderBg
    headerBg:SetExtent(width, headerHeight)
    local drag = sideName == "friendly" and self.controls.friendlyDrag or self.controls.enemyDrag

    if sideName == "friendly" then
        local printButton = self.controls.friendlyPrintButton
        if compactMode then
            self.controls.modeButton:Show(true)
            self.controls.damageButton:Show(false)
            self.controls.takenButton:Show(false)
            self.controls.healButton:Show(false)
            if printButton ~= nil then printButton:Show(false) end
            self.controls.clearButton:Show(false)
            if self.controls.configButton ~= nil then self.controls.configButton:Show(false) end
            self.controls.friendlyCompactButton:Show(true)

            self.controls.modeButton:RemoveAllAnchors()
            self.controls.modeButton:AddAnchor("TOPLEFT", window, 4, 3)
            ApplyButtonStyle(self.controls.modeButton, 46, 23, 9)
            self.controls.friendlyCompactButton:RemoveAllAnchors()
            self.controls.friendlyCompactButton:AddAnchor("TOPRIGHT", window, -4, 3)
            ApplyButtonStyle(self.controls.friendlyCompactButton, 28, 23, 9)
            self.controls.friendlyTitle:RemoveAllAnchors()
            self.controls.friendlyTitle:AddAnchor("TOPLEFT", window, 54, 5)
            SetLabelExtent(self.controls.friendlyTitle, math.max(1, width - 92), 20)
            SetLabelFontSize(self.controls.friendlyTitle, 10)
            PositionQuickDragSurface(drag, x, y, presentationScale,
                52, 1, math.max(1, width - 88), 27,
                window:IsVisible(), not locked)
        else
            self.controls.modeButton:Show(true)
            self.controls.damageButton:Show(true)
            self.controls.takenButton:Show(true)
            self.controls.healButton:Show(true)
            if printButton ~= nil then printButton:Show(true) end
            self.controls.clearButton:Show(true)
            if self.controls.configButton ~= nil then self.controls.configButton:Show(true) end
            self.controls.friendlyCompactButton:Show(true)

            local buttons = { self.controls.modeButton, self.controls.damageButton, self.controls.takenButton, self.controls.healButton }
            local weights = { 0.90, 1.05, 1.05, 1.05 }
            if printButton ~= nil then
                buttons[#buttons + 1] = printButton
                weights[#weights + 1] = 0.92
            end
            buttons[#buttons + 1] = self.controls.clearButton
            weights[#weights + 1] = 0.90
            if self.controls.configButton ~= nil then
                buttons[#buttons + 1] = self.controls.configButton
                weights[#weights + 1] = 0.90
            end
            buttons[#buttons + 1] = self.controls.friendlyCompactButton
            weights[#weights + 1] = 0.55
            local gap = width < 300 and 1 or 2
            local availableHeader = math.max(1, width - 8 - gap * (#buttons - 1))
            local weightTotal = 0
            for _, value in ipairs(weights) do weightTotal = weightTotal + value end
            local cursor, used = 4, 0
            local minimumButtonWidth = math.max(1, math.floor(availableHeader / (#buttons * 2)))
            for index, button in ipairs(buttons) do
                local remainingButtons = #buttons - index
                local remainingWidth = math.max(1, availableHeader - used)
                local maximumWidth = math.max(1, remainingWidth - remainingButtons * minimumButtonWidth)
                local preferredWidth = math.floor(availableHeader * weights[index] / weightTotal)
                local buttonWidth = index == #buttons and remainingWidth or U.Clamp(preferredWidth, minimumButtonWidth, maximumWidth)
                button:RemoveAllAnchors()
                button:AddAnchor("TOPLEFT", window, cursor, 3)
                ApplyButtonStyle(button, buttonWidth, 23, width < 340 and 8 or 10)
                cursor = cursor + buttonWidth + gap
                used = used + buttonWidth
            end
            self.controls.friendlyTitle:RemoveAllAnchors()
            self.controls.friendlyTitle:AddAnchor("TOPLEFT", window, 7, 31)
            SetLabelExtent(self.controls.friendlyTitle, math.max(1, width - 14), 20)
            SetLabelFontSize(self.controls.friendlyTitle, 12)
            PositionQuickDragSurface(drag, x, y, presentationScale,
                0, 29, width, 27,
                window:IsVisible(), not locked)
        end
    else
        local printButton = self.controls.enemyPrintButton
        if compactMode then
            if self.controls.enemySettingsButton ~= nil then self.controls.enemySettingsButton:Show(false) end
            self.controls.enemyBossButton:Show(false)
            if printButton ~= nil then printButton:Show(false) end
            self.controls.enemyCompactButton:Show(true)
            self.controls.enemyMirror:Show(false)
            self.controls.enemyCompactButton:RemoveAllAnchors()
            self.controls.enemyCompactButton:AddAnchor("TOPRIGHT", window, -4, 3)
            ApplyButtonStyle(self.controls.enemyCompactButton, 28, 23, 9)
            self.controls.enemyTitle:RemoveAllAnchors()
            self.controls.enemyTitle:AddAnchor("TOPLEFT", window, 7, 5)
            SetLabelExtent(self.controls.enemyTitle, math.max(1, width - 46), 20)
            SetLabelFontSize(self.controls.enemyTitle, 10)
            PositionQuickDragSurface(drag, x, y, presentationScale,
                2, 1, math.max(1, width - 38), 27,
                window:IsVisible(), not locked)
        else
            if self.controls.enemySettingsButton ~= nil then self.controls.enemySettingsButton:Show(true) end
            self.controls.enemyBossButton:Show(true)
            if printButton ~= nil then printButton:Show(true) end
            self.controls.enemyCompactButton:Show(true)
            self.controls.enemyMirror:Show(true)
            local actions = {}
            if self.controls.enemySettingsButton ~= nil then actions[#actions + 1] = self.controls.enemySettingsButton end
            actions[#actions + 1] = self.controls.enemyBossButton
            if printButton ~= nil then actions[#actions + 1] = printButton end
            actions[#actions + 1] = self.controls.enemyCompactButton
            local enemyActionGap = width < 180 and 1 or 2
            local availableHeader = math.max(1, width - 14 - enemyActionGap * (#actions - 1))
            local actionWidth = math.min(51, math.max(24, math.floor(availableHeader / math.max(#actions + 2, 6))))
            local right = 7
            for _, button in ipairs(actions) do
                local actualWidth = button == self.controls.enemyCompactButton and math.min(30, actionWidth) or actionWidth
                button:RemoveAllAnchors()
                button:AddAnchor("TOPRIGHT", window, -right, 4)
                ApplyButtonStyle(button, actualWidth, 22, 9)
                right = right + actualWidth + enemyActionGap
            end
            local titleWidth = math.max(1, width - right - 7)
            self.controls.enemyTitle:RemoveAllAnchors()
            self.controls.enemyTitle:AddAnchor("TOPLEFT", window, 7, 7)
            SetLabelExtent(self.controls.enemyTitle, titleWidth, 20)
            SetLabelFontSize(self.controls.enemyTitle, 13)
            self.controls.enemyMirror:RemoveAllAnchors()
            self.controls.enemyMirror:AddAnchor("TOPLEFT", window, 7, 32)
            SetLabelExtent(self.controls.enemyMirror, math.max(1, width - 14), 18)
            PositionQuickDragSurface(drag, x, y, presentationScale,
                0, 29, width, 27,
                window:IsVisible(), not locked)
        end
    end

    local rows = self.rows[sideName]
    local rowArea = math.max(1, height - headerHeight - footerHeight - 4)
    local visibleRows = U.Clamp(math.floor(rowArea / baseRowHeight), 1, C.MAX_ROWS)
    self.visibleRows[sideName] = visibleRows
    local rowHeight = math.max(compactMode and 15 or 16, math.floor(rowArea / visibleRows))
    for i = 1, C.MAX_ROWS do
        local row = rows[i]
        row.panel:RemoveAllAnchors()
        row.panel:AddAnchor("TOPLEFT", window, 4, headerHeight + 2 + (i - 1) * rowHeight)
        local panelWidth = math.max(1, width - 8)
        row.panel:SetExtent(panelWidth, math.max(1, rowHeight - 2))
        row.bar:SetExtent(1, math.max(1, rowHeight - 2))
        local gap = panelWidth < 300 and 2 or 4
        local leftPad = compactMode and 4 or 5
        local rightPad = 4
        local currentPage = self:GetQuickPage() or "DAMAGE"
        local showPercentColumn = not compactMode and D.State.config.showPercent == true and panelWidth >= 450
        local showRateColumn = not compactMode and currentPage ~= "KILLS" and panelWidth >= 390
        local percentWidth = showPercentColumn and U.Clamp(math.floor(panelWidth * 0.10), 28, 40) or 1
        local rateWidth = showRateColumn and U.Clamp(math.floor(panelWidth * 0.18), 52, 78) or 1
        local amountWidth = compactMode and U.Clamp(math.floor(panelWidth * 0.28), 54, 82) or U.Clamp(math.floor(panelWidth * 0.15), 46, 62)
        amountWidth = math.min(amountWidth, math.max(1, panelWidth - leftPad - rightPad - gap - 1))
        local rightOffset = rightPad
        row.showPercentColumn = showPercentColumn
        row.showRateColumn = showRateColumn
        row.percent:RemoveAllAnchors()
        row.percent:AddAnchor("TOPRIGHT", row.panel, -rightOffset, 1)
        SetLabelExtent(row.percent, percentWidth, math.max(1, rowHeight - 3))
        if showPercentColumn then rightOffset = rightOffset + percentWidth + gap end
        row.rate:RemoveAllAnchors()
        row.rate:AddAnchor("TOPRIGHT", row.panel, -rightOffset, 1)
        SetLabelExtent(row.rate, rateWidth, math.max(1, rowHeight - 3))
        if showRateColumn then rightOffset = rightOffset + rateWidth + gap end
        row.amount:RemoveAllAnchors()
        row.amount:AddAnchor("TOPRIGHT", row.panel, -rightOffset, 1)
        SetLabelExtent(row.amount, amountWidth, math.max(1, rowHeight - 3))
        rightOffset = rightOffset + amountWidth + gap
        local nameWidth = math.max(1, panelWidth - leftPad - rightOffset)
        row.name:RemoveAllAnchors()
        row.name:AddAnchor("TOPLEFT", row.panel, leftPad, 1)
        SetLabelExtent(row.name, nameWidth, math.max(1, rowHeight - 3))
        SetLabelFontSize(row.name, compactMode and 9 or 10)
        SetLabelFontSize(row.amount, compactMode and 9 or 10)
        if i > visibleRows then row.panel:Show(false) end
    end

    local footer = sideName == "friendly" and self.controls.friendlyFooter or self.controls.enemyFooter
    local prev = self.controls[sideName .. "Prev"]
    local pageLabel = self.controls[sideName .. "Page"]
    local nextButton = self.controls[sideName .. "Next"]
    local resize = sideName == "friendly" and self.controls.friendlyResize or self.controls.enemyResize
    footer:Show(not compactMode)
    local navGap = compactMode and 1 or 2
    local navButtonWidth = compactMode and math.min(24, math.max(16, math.floor(width * 0.10))) or math.min(28, math.max(14, math.floor(width * 0.08)))
    local pageWidth, navStart
    if compactMode then
        pageWidth = math.min(52, math.max(34, math.floor(width * 0.24)))
        local navTotal = navButtonWidth * 2 + pageWidth + navGap * 2
        navStart = math.max(4, math.floor((math.max(1, width - 32) - navTotal) / 2))
    else
        local availablePageWidth = math.max(1, width - 34 - navButtonWidth * 2 - navGap * 2 - 10)
        pageWidth = math.min(58, math.max(18, availablePageWidth))
        local navTotal = navButtonWidth * 2 + pageWidth + navGap * 2
        navStart = math.max(0, width - 34 - navTotal)
        footer:RemoveAllAnchors()
        footer:AddAnchor("BOTTOMLEFT", window, 5, -2)
        SetLabelExtent(footer, math.max(1, navStart - 7), 18)
    end
    if prev ~= nil then
        prev:Show(true)
        prev:RemoveAllAnchors()
        prev:AddAnchor("BOTTOMLEFT", window, navStart, -2)
        ApplyButtonStyle(prev, navButtonWidth, 18, 9)
    end
    if pageLabel ~= nil then
        pageLabel:Show(true)
        pageLabel:RemoveAllAnchors()
        pageLabel:AddAnchor("BOTTOMLEFT", window, navStart + navButtonWidth + navGap, -2)
        SetLabelExtent(pageLabel, pageWidth, 18)
        SetLabelFontSize(pageLabel, compactMode and 8 or 9)
    end
    if nextButton ~= nil then
        nextButton:Show(true)
        nextButton:RemoveAllAnchors()
        nextButton:AddAnchor("BOTTOMLEFT", window, navStart + navButtonWidth + navGap + pageWidth + navGap, -2)
        ApplyButtonStyle(nextButton, navButtonWidth, 18, 9)
    end
    local suiteEditMode = ReplicatedSuiteEmbedded ~= true or self.suiteEditMode == true
    resize:Show(suiteEditMode)
    resize:RemoveAllAnchors()
    resize:AddAnchor("BOTTOMRIGHT", window, -2, -2)
    resize:EnableDrag(suiteEditMode and not locked)
    self:ApplyQuickPresentation(sideName)
end

function UIX:LayoutDetailWindow()
    local window = self.windows.detail
    if window == nil then return end
    local rect = D.State.ui.detail
    local _, _, _, logicalWidth, logicalHeight = U.GetUiMetrics()
    local x, y, width, height = U.ResolveRect(rect, DETAIL_DEFAULT_W, DETAIL_DEFAULT_H)
    local minWidth = math.min(DETAIL_DEFAULT_W, math.max(360, logicalWidth - 12))
    local minHeight = math.min(DETAIL_DEFAULT_H, math.max(330, logicalHeight - 12))
    width = U.Clamp(math.max(minWidth, width), math.min(360, logicalWidth), logicalWidth)
    height = U.Clamp(math.max(minHeight, height), math.min(330, logicalHeight), logicalHeight)
    U.SetRectFromLogical(rect, x, y, width, height)
    U.ApplyRect(window, rect, width, height)

    self.controls.detailHeaderBg:SetExtent(width, 32)
    local hasBack = self.detail ~= nil and (#(self.detail.navigation or {}) > 0 or self.detail.candidateSelection ~= nil)
    local titleX = hasBack and 52 or 10
    self.controls.detailTitle:RemoveAllAnchors()
    self.controls.detailTitle:AddAnchor("TOPLEFT", window, titleX, 6)
    SetLabelExtent(self.controls.detailTitle, math.max(1, width - titleX - 40), 22)
    if self.controls.detailBack ~= nil then
        self.controls.detailBack:RemoveAllAnchors()
        self.controls.detailBack:AddAnchor("TOPLEFT", window, 8, 4)
        ApplyButtonStyle(self.controls.detailBack, 38, 23, 11)
        self.controls.detailBack:Show(hasBack)
    end
    self.controls.detailClose:RemoveAllAnchors()
    self.controls.detailClose:AddAnchor("TOPRIGHT", window, -6, 4)
    ApplyButtonStyle(self.controls.detailClose, 26, 23, 11)
    self.controls.detailDrag:SetExtent(math.max(1, width - 40), 32)

    local contentWidth = math.max(1, width - 20)
    SetLabelExtent(self.controls.detailType, contentWidth, 18)
    SetLabelExtent(self.controls.detailRelation, contentWidth, 18)
    SetLabelExtent(self.controls.detailTotals, contentWidth, 18)

    -- Keep the two detail tabs and the paging cluster inside one exact-width
    -- row. The previous fixed 82/100/26 minima could exceed very narrow
    -- logical viewports after a resolution or UI-scale change.
    local detailGap = contentWidth < 300 and 3 or 6
    local navButtonWidth = U.Clamp(math.floor(contentWidth * 0.07), 18, 26)
    local minimumPageWidth = contentWidth < 260 and 24 or 32
    local detailTabWidth = math.floor((contentWidth - navButtonWidth * 2 - minimumPageWidth - detailGap * 4) / 2)
    detailTabWidth = U.Clamp(detailTabWidth, 1, 100)
    local pageWidth = math.max(1, contentWidth - detailTabWidth * 2 - navButtonWidth * 2 - detailGap * 4)
    local abilityX = 10
    local counterpartX = abilityX + detailTabWidth + detailGap
    local prevX = counterpartX + detailTabWidth + detailGap
    local pageX = prevX + navButtonWidth + detailGap
    local nextX = pageX + pageWidth + detailGap

    self.controls.detailAbility:RemoveAllAnchors()
    self.controls.detailAbility:AddAnchor("TOPLEFT", window, abilityX, 98)
    ApplyButtonStyle(self.controls.detailAbility, detailTabWidth, 23, 10)
    self.controls.detailCounterpart:RemoveAllAnchors()
    self.controls.detailCounterpart:AddAnchor("TOPLEFT", window, counterpartX, 98)
    ApplyButtonStyle(self.controls.detailCounterpart, detailTabWidth, 23, 10)
    self.controls.detailPrev:RemoveAllAnchors()
    self.controls.detailPrev:AddAnchor("TOPLEFT", window, prevX, 98)
    ApplyButtonStyle(self.controls.detailPrev, navButtonWidth, 23, 9)
    self.controls.detailPage:RemoveAllAnchors()
    self.controls.detailPage:AddAnchor("TOPLEFT", window, pageX, 100)
    SetLabelExtent(self.controls.detailPage, pageWidth, 20)
    self.controls.detailNext:RemoveAllAnchors()
    self.controls.detailNext:AddAnchor("TOPLEFT", window, nextX, 98)
    ApplyButtonStyle(self.controls.detailNext, navButtonWidth, 23, 9)
    self.controls.detailHint:RemoveAllAnchors()
    self.controls.detailHint:AddAnchor("TOPLEFT", window, 10, 124)
    SetLabelExtent(self.controls.detailHint, contentWidth, 18)

    local analysisTarget = self:GetSelectedAnalysisTarget()
    local hasAnalysisRow = analysisTarget ~= nil
        and self.controls.detailExcludeTarget ~= nil and self.controls.detailBossTarget ~= nil
    local firstButtonY = height - 98
    local secondButtonY = height - 68
    local thirdButtonY = height - 38
    local analysisButtonY = height - 128
    local rowsBottomY = hasAnalysisRow and analysisButtonY or firstButtonY
    local rowsHeight = rowsBottomY - DETAIL_ROWS_Y - 8
    local visibleRows = rowsHeight >= 18 and U.Clamp(math.floor(rowsHeight / 23), 1, DETAIL_ROWS) or 0
    self.visibleDetailRows = visibleRows
    local rowHeight = visibleRows > 0 and math.max(18, math.floor(rowsHeight / visibleRows)) or 18
    for i = 1, DETAIL_ROWS do
        local row = self.detailRows[i]
        row.panel:RemoveAllAnchors()
        row.panel:AddAnchor("TOPLEFT", window, 10, DETAIL_ROWS_Y + (i - 1) * rowHeight)
        row.panel:SetExtent(contentWidth, math.max(1, rowHeight - 2))
        row.bar:SetExtent(1, math.max(1, rowHeight - 2))
        local valueWidth = U.Clamp(math.floor(contentWidth * 0.34), math.min(60, contentWidth), math.max(1, contentWidth - 18))
        local nameWidth = math.max(1, contentWidth - valueWidth - 12)
        row.name:RemoveAllAnchors()
        row.name:AddAnchor("TOPLEFT", row.panel, 5, 1)
        SetLabelExtent(row.name, nameWidth, rowHeight - 3)
        row.value:RemoveAllAnchors()
        row.value:AddAnchor("TOPRIGHT", row.panel, -5, 1)
        SetLabelExtent(row.value, valueWidth, rowHeight - 3)
        if i > visibleRows then row.panel:Show(false) end
    end

    local gap = contentWidth < 300 and 3 or 6
    if self.controls.detailExcludeTarget ~= nil and self.controls.detailBossTarget ~= nil then
        local analysisWidth = math.max(1, math.floor((contentWidth - gap) / 2))
        self.controls.detailExcludeTarget:RemoveAllAnchors()
        self.controls.detailExcludeTarget:AddAnchor("TOPLEFT", window, 10, analysisButtonY)
        ApplyButtonStyle(self.controls.detailExcludeTarget, analysisWidth, 24, 10)
        self.controls.detailBossTarget:RemoveAllAnchors()
        self.controls.detailBossTarget:AddAnchor("TOPLEFT", window, 10 + analysisWidth + gap, analysisButtonY)
        ApplyButtonStyle(self.controls.detailBossTarget, analysisWidth, 24, 10)
        self.controls.detailExcludeTarget:Show(hasAnalysisRow)
        self.controls.detailBossTarget:Show(hasAnalysisRow)
    end
    local firstWidth = math.max(1, math.floor((contentWidth - gap * 4) / 5))
    local firstButtons = {
        self.controls.detailFriendly,
        self.controls.detailEnemy,
        self.controls.detailPlayer,
        self.controls.detailNpc,
        self.controls.detailOther,
    }
    for index, button in ipairs(firstButtons) do
        button:RemoveAllAnchors()
        button:AddAnchor("TOPLEFT", window, 10 + (index - 1) * (firstWidth + gap), firstButtonY)
        ApplyButtonStyle(button, firstWidth, 24, 9)
    end
    local secondWidth = math.max(1, math.floor((contentWidth - gap) / 2))
    self.controls.detailIgnore:RemoveAllAnchors()
    self.controls.detailIgnore:AddAnchor("TOPLEFT", window, 10, secondButtonY)
    ApplyButtonStyle(self.controls.detailIgnore, secondWidth, 24, 10)
    self.controls.detailAuto:RemoveAllAnchors()
    self.controls.detailAuto:AddAnchor("TOPLEFT", window, 10 + secondWidth + gap, secondButtonY)
    ApplyButtonStyle(self.controls.detailAuto, secondWidth, 24, 10)
    self.controls.detailSaveRule:RemoveAllAnchors()
    self.controls.detailSaveRule:AddAnchor("TOPLEFT", window, 10, thirdButtonY)
    ApplyButtonStyle(self.controls.detailSaveRule, secondWidth, 24, 10)
    self.controls.detailRemoveRule:RemoveAllAnchors()
    self.controls.detailRemoveRule:AddAnchor("TOPLEFT", window, 10 + secondWidth + gap, thirdButtonY)
    ApplyButtonStyle(self.controls.detailRemoveRule, secondWidth, 24, 10)
end

function UIX:LayoutConfigWindow()
    local window = self.windows.config
    if window == nil then return end
    local rect = D.State.ui.config
    local _, _, _, logicalWidth, logicalHeight = U.GetUiMetrics()
    local x, y = U.ResolveRect(rect, C.CONFIG_W, C.CONFIG_H)
    local width = math.min(C.CONFIG_W, math.max(320, logicalWidth - 16))
    local height = math.min(C.CONFIG_H, math.max(320, logicalHeight - 16))
    width = math.min(width, logicalWidth)
    height = math.min(height, logicalHeight)
    U.SetRectFromLogical(rect, x, y, width, height)
    U.ApplyRect(window, rect, width, height)

    self.controls.configHeaderBg:SetExtent(width, 44)
    self.controls.configTitle:RemoveAllAnchors()
    self.controls.configTitle:AddAnchor("TOPLEFT", window, 10, 7)
    SetLabelExtent(self.controls.configTitle, math.max(1, width - 56), 24)
    self.controls.configClose:RemoveAllAnchors()
    self.controls.configClose:AddAnchor("TOPRIGHT", window, -8, 7)
    ApplyButtonStyle(self.controls.configClose, 26, 24, 11)
    self.controls.configDrag:RemoveAllAnchors()
    self.controls.configDrag:AddAnchor("TOPLEFT", window, 0, 0)
    self.controls.configDrag:SetExtent(math.max(1, width - 42), 42)

    local tabGap = width < 280 and 2 or 4
    local tabCount = #self.controls.tabs
    local tabsWidth = math.max(1, width - 16)
    local tabWidth = math.max(1, math.floor((tabsWidth - tabGap * (tabCount - 1)) / tabCount))
    local tabNames = { "运行", "显示", "准确率", "名单", "高级", "诊断" }
    local usedTabWidth = 0
    for index, tab in ipairs(self.controls.tabs) do
        local tabX = 8 + usedTabWidth + (index - 1) * tabGap
        local actualWidth = index == tabCount and math.max(1, width - 8 - tabX) or tabWidth
        tab:RemoveAllAnchors()
        tab:AddAnchor("TOPLEFT", window, tabX, 48)
        ApplyButtonStyle(tab, actualWidth, 24, 10)
        SetFittedControlText(tab, (index == (self.activeConfigPage or 1) and "[" or "")
            .. tabNames[index] .. (index == (self.activeConfigPage or 1) and "]" or ""), 10, 8)
        usedTabWidth = usedTabWidth + actualWidth
    end

    local pageY = 76
    local footerHeight = 22
    local pageWidth = math.max(1, width - 16)
    local pageHeight = math.max(1, height - pageY - footerHeight - 8)
    local pages = { self.pages.general, self.pages.display, self.pages.accuracy, self.pages.rules, self.pages.advanced, self.pages.diagnostics }
    for _, page in ipairs(pages) do
        page:RemoveAllAnchors()
        page:AddAnchor("TOPLEFT", window, 8, pageY)
        page:SetExtent(pageWidth, pageHeight)
    end

    local compactConfig = pageHeight < 170
    local function LayoutRows(page, reserveBottom, options)
        options = type(options) == "table" and options or {}
        local rows = page.repdpsRows or {}
        local count = #rows
        local startY = math.max(0, tonumber(options.startY) or 8)
        if count <= 0 then return startY end
        local usable = math.max(1, pageHeight - (reserveBottom or 0) - startY - 4)
        local minimumStep = math.max(14, tonumber(options.minimumStep)
            or (compactConfig and 16 or 23))
        local maximumStep = math.max(minimumStep, tonumber(options.maximumStep) or 30)
        local naturalStep = math.floor(usable / count)
        local requestedStep = tonumber(options.step)
        local step = U.Clamp(requestedStep or naturalStep, minimumStep, maximumStep)
        if step * count > usable then step = math.max(14, math.floor(usable / count)) end
        local controlHeight = U.Clamp(tonumber(options.controlHeight) or (step - 2),
            tonumber(options.minimumControlHeight) or (compactConfig and 14 or 20),
            tonumber(options.maximumControlHeight) or 22)
        controlHeight = math.min(controlHeight, math.max(14, step - 2))
        local rowFont = math.max(8, tonumber(options.rowFont) or (compactConfig and 8 or 10))
        local maxControlWidth = math.max(1, pageWidth - 20)
        local controlMinimum = math.min(72, maxControlWidth)
        local controlMaximum = math.min(150, maxControlWidth)
        local controlWidth = U.Clamp(math.floor(pageWidth * 0.29), controlMinimum, controlMaximum)
        local labelWidth = math.max(1, pageWidth - controlWidth - 30)
        for index, row in ipairs(rows) do
            local rowY = startY + (index - 1) * step
            row.label:RemoveAllAnchors()
            row.label:AddAnchor("TOPLEFT", page, 10, rowY + (compactConfig and 0 or 1))
            SetLabelExtent(row.label, labelWidth, controlHeight)
            SetLabelFontSize(row.label, rowFont)
            if row.kind == "toggle" then
                row.button:RemoveAllAnchors()
                row.button:AddAnchor("TOPRIGHT", page, -10, rowY)
                ApplyButtonStyle(row.button, controlWidth, controlHeight, rowFont)
            else
                local minusWidth = math.min(34, math.max(18, math.floor(controlWidth * 0.25)))
                local plusWidth = minusWidth
                local valueWidth = math.max(1, controlWidth - minusWidth - plusWidth - 8)
                local startX = pageWidth - 10 - controlWidth
                row.control.minus:RemoveAllAnchors()
                row.control.minus:AddAnchor("TOPLEFT", page, startX, rowY)
                ApplyButtonStyle(row.control.minus, minusWidth, controlHeight, rowFont)
                row.control.value:RemoveAllAnchors()
                row.control.value:AddAnchor("TOPLEFT", page, startX + minusWidth + 4, rowY)
                SetLabelExtent(row.control.value, valueWidth, controlHeight)
                SetLabelFontSize(row.control.value, rowFont)
                row.control.plus:RemoveAllAnchors()
                row.control.plus:AddAnchor("TOPLEFT", page, startX + minusWidth + 4 + valueWidth + 4, rowY)
                ApplyButtonStyle(row.control.plus, plusWidth, controlHeight, rowFont)
            end
        end
        return startY + count * step
    end

    local showGeneralActions = not compactConfig
    LayoutRows(self.pages.general, showGeneralActions and 42 or 0)
    local generalButtonY = math.max(8, pageHeight - 34)
    local actionGap = pageWidth < 260 and 4 or 8
    local actionWidth = math.max(1, math.floor((pageWidth - 20 - actionGap) / 2))
    self.controls.resetPositions:RemoveAllAnchors()
    self.controls.resetPositions:AddAnchor("TOPLEFT", self.pages.general, 10, generalButtonY)
    ApplyButtonStyle(self.controls.resetPositions, actionWidth, 26, 10)
    self.controls.restoreClear:RemoveAllAnchors()
    self.controls.restoreClear:AddAnchor("TOPLEFT", self.pages.general, 10 + actionWidth + actionGap, generalButtonY)
    ApplyButtonStyle(self.controls.restoreClear, actionWidth, 26, 10)
    self.controls.resetPositions:Show(showGeneralActions)
    self.controls.restoreClear:Show(showGeneralActions)

    LayoutRows(self.pages.display, 0)

    -- Accuracy mixes explanatory labels with toggle rows.  It must not use the
    -- generic row origin at y=8, otherwise the first toggle is laid directly on
    -- top of the fixed policy text (the overlap reported by the real client).
    local accuracyPage = self.pages.accuracy
    local accuracyInnerWidth = math.max(1, pageWidth - 20)
    local showAccuracyHelp = pageHeight >= 200
    local policyHeight = showAccuracyHelp and 30 or 20
    local policyLines = showAccuracyHelp and 2 or 1
    local capabilityHeight = showAccuracyHelp and 34 or 24
    local helpReserve = showAccuracyHelp and 50 or 0
    local policyY = 8
    local rowsStartY = policyY + policyHeight + 4
    local accuracyReserve = capabilityHeight + 8 + (showAccuracyHelp and (helpReserve + 8) or 0)

    self.controls.fixedAccuracyPolicy:RemoveAllAnchors()
    self.controls.fixedAccuracyPolicy:AddAnchor("TOPLEFT", accuracyPage, 10, policyY)
    SetLabelExtent(self.controls.fixedAccuracyPolicy, accuracyInnerWidth, policyHeight)
    SetLabelFontSize(self.controls.fixedAccuracyPolicy, showAccuracyHelp and 9 or 8)
    self.controls.fixedAccuracyPolicy:SetText(FitMultilineText(
        self.controls.fixedAccuracyPolicy,
        "固定统计策略：数据优先收录；\n未确认身份先临时计入，后续可人工纠错。",
        accuracyInnerWidth,
        showAccuracyHelp and 9 or 8,
        policyLines
    ))

    local accuracyEnd = LayoutRows(accuracyPage, accuracyReserve, {
        startY = rowsStartY,
        step = showAccuracyHelp and 27 or 22,
        minimumStep = compactConfig and 18 or 22,
        maximumStep = 27,
        controlHeight = showAccuracyHelp and 22 or 18,
        minimumControlHeight = compactConfig and 16 or 18,
        maximumControlHeight = 22,
        rowFont = showAccuracyHelp and 10 or 8,
    })

    local capabilityY = accuracyEnd + 4
    self.controls.capabilityStatus:RemoveAllAnchors()
    self.controls.capabilityStatus:AddAnchor("TOPLEFT", accuracyPage, 10, capabilityY)
    SetLabelExtent(self.controls.capabilityStatus, accuracyInnerWidth, capabilityHeight)
    SetLabelFontSize(self.controls.capabilityStatus, showAccuracyHelp and 9 or 8)
    self.controls.capabilityStatus:SetText(FitMultilineText(
        self.controls.capabilityStatus,
        "API能力限制：未公开任意玩家公会ID、宠物/召唤物主人；\n正式统计不会猜测传播或强行合并。",
        accuracyInnerWidth,
        showAccuracyHelp and 9 or 8,
        showAccuracyHelp and 2 or 1
    ))

    local helpY = capabilityY + capabilityHeight + 6
    self.controls.accuracyHelp:RemoveAllAnchors()
    self.controls.accuracyHelp:AddAnchor("TOPLEFT", accuracyPage, 10, helpY)
    SetLabelExtent(self.controls.accuracyHelp, accuracyInnerWidth, math.max(1, pageHeight - helpY - 4))
    SetLabelFontSize(self.controls.accuracyHelp, 9)
    self.controls.accuracyHelp:SetText(FitMultilineText(
        self.controls.accuracyHelp,
        "治疗=同阵营；我方造成/受到伤害=对方敌军，但单位类型独立确认。\n友军互伤、敌军互伤、跨阵营治疗均标记[冲]，不会自动翻转名单。\n中文名判NPC可关闭；公会同步等待可靠字段，不会猜测。",
        accuracyInnerWidth,
        9,
        3
    ))
    self.controls.accuracyHelp:Show(showAccuracyHelp)
    local showRulesHelp = not compactConfig
    local rulesBottomReserve = showRulesHelp and 104 or 66
    local rulesRowTop = 48
    local rulesRowHeight = 27
    local rulesAvailable = math.max(27, pageHeight - rulesRowTop - rulesBottomReserve)
    local rulesVisible = U.Clamp(math.floor(rulesAvailable / rulesRowHeight), 1, #self.ruleRows)
    self.ruleList.visibleRows = rulesVisible
    self.controls.rulesSummary:RemoveAllAnchors()
    self.controls.rulesSummary:AddAnchor("TOPLEFT", self.pages.rules, 10, 8)
    SetLabelExtent(self.controls.rulesSummary, math.max(1, pageWidth - 20), 36)
    for index, row in ipairs(self.ruleRows) do
        row.button:RemoveAllAnchors()
        row.button:AddAnchor("TOPLEFT", self.pages.rules, 10, rulesRowTop + (index - 1) * rulesRowHeight)
        ApplyButtonStyle(row.button, math.max(1, pageWidth - 20), 24, 9)
        if index > rulesVisible then row.button:Show(false) end
    end
    local rulesNavY = rulesRowTop + rulesVisible * rulesRowHeight + 2
    local rulesInnerWidth = math.max(1, pageWidth - 20)
    local rulesNavGap = pageWidth < 260 and 3 or 6
    local rulesPageWidth = U.Clamp(math.floor(rulesInnerWidth * 0.25), math.min(24, rulesInnerWidth), 88)
    local navButtonWidth = math.max(1, math.floor((rulesInnerWidth - rulesPageWidth - rulesNavGap * 2) / 2))
    self.controls.rulesPrev:RemoveAllAnchors()
    self.controls.rulesPrev:AddAnchor("TOPLEFT", self.pages.rules, 10, rulesNavY)
    ApplyButtonStyle(self.controls.rulesPrev, navButtonWidth, 24, 9)
    self.controls.rulesPage:RemoveAllAnchors()
    self.controls.rulesPage:AddAnchor("TOPLEFT", self.pages.rules, 10 + navButtonWidth + rulesNavGap, rulesNavY + 2)
    SetLabelExtent(self.controls.rulesPage, rulesPageWidth, 20)
    self.controls.rulesNext:RemoveAllAnchors()
    self.controls.rulesNext:AddAnchor("TOPLEFT", self.pages.rules, 10 + navButtonWidth + rulesNavGap + rulesPageWidth + rulesNavGap, rulesNavY)
    ApplyButtonStyle(self.controls.rulesNext, navButtonWidth, 24, 9)
    local rulesActionY = rulesNavY + 30
    local actionGap = pageWidth < 300 and 3 or 5
    local rulesActionWidth = math.max(1, math.floor((rulesInnerWidth - actionGap * 3) / 4))
    local ruleActions = { self.controls.rulesToggle, self.controls.rulesDelete, self.controls.rulesRestoreSession, self.controls.rulesClear }
    local usedActionWidth = 0
    for index, button in ipairs(ruleActions) do
        local actionX = 10 + usedActionWidth + (index - 1) * actionGap
        local actualWidth = index == 4 and math.max(1, pageWidth - 10 - actionX) or rulesActionWidth
        button:RemoveAllAnchors()
        button:AddAnchor("TOPLEFT", self.pages.rules, actionX, rulesActionY)
        ApplyButtonStyle(button, actualWidth, 25, 9)
        usedActionWidth = usedActionWidth + actualWidth
    end
    self.controls.rulesHelp:RemoveAllAnchors()
    self.controls.rulesHelp:AddAnchor("TOPLEFT", self.pages.rules, 10, rulesActionY + 31)
    SetLabelExtent(self.controls.rulesHelp, math.max(1, pageWidth - 20), math.max(1, pageHeight - (rulesActionY + 35)))
    self.controls.rulesHelp:Show(showRulesHelp)

    LayoutRows(self.pages.advanced, 0)

    local diagSecondRowY = math.max(8, pageHeight - 34)
    local diagFirstRowY = math.max(8, diagSecondRowY - 32)
    self.controls.diagStatus:RemoveAllAnchors()
    self.controls.diagStatus:AddAnchor("TOPLEFT", self.pages.diagnostics, 10, 8)
    SetLabelExtent(self.controls.diagStatus, math.max(1, pageWidth - 20), math.max(1, diagFirstRowY - 14))
    local diagGap = pageWidth < 260 and 3 or 6
    local diagInnerWidth = math.max(1, pageWidth - 20)
    local diagButtonWidth = math.max(1, math.floor((diagInnerWidth - diagGap * 2) / 3))
    local diagButtons = { self.controls.diagRebuild, self.controls.diagSave, self.controls.diagRescan }
    local usedDiagWidth = 0
    for index, button in ipairs(diagButtons) do
        local buttonX = 10 + usedDiagWidth + (index - 1) * diagGap
        local actualWidth = index == 3 and math.max(1, pageWidth - 10 - buttonX) or diagButtonWidth
        button:RemoveAllAnchors()
        button:AddAnchor("TOPLEFT", self.pages.diagnostics, buttonX, diagFirstRowY)
        ApplyButtonStyle(button, actualWidth, 26, index == 3 and 9 or 10)
        usedDiagWidth = usedDiagWidth + actualWidth
    end
    local shardButtonWidth = math.max(1, math.floor((diagInnerWidth - diagGap) / 2))
    self.controls.diagShardAudit:RemoveAllAnchors()
    self.controls.diagShardAudit:AddAnchor("TOPLEFT", self.pages.diagnostics, 10, diagSecondRowY)
    ApplyButtonStyle(self.controls.diagShardAudit, shardButtonWidth, 26, 10)
    self.controls.diagShardClear:RemoveAllAnchors()
    self.controls.diagShardClear:AddAnchor("TOPLEFT", self.pages.diagnostics, 10 + shardButtonWidth + diagGap, diagSecondRowY)
    ApplyButtonStyle(self.controls.diagShardClear, math.max(1, diagInnerWidth - shardButtonWidth - diagGap), 26, 10)

    self.controls.configFooter:RemoveAllAnchors()
    self.controls.configFooter:AddAnchor("BOTTOMLEFT", window, 9, -4)
    SetLabelExtent(self.controls.configFooter, math.max(1, width - 18), 18)
end

function UIX:CheckViewportChanged()
    local _, _, uiScale, logicalWidth, logicalHeight = U.GetUiMetrics()
    local previous = self.viewportMetrics
    local changed = previous == nil
        or math.abs((tonumber(previous.logicalWidth) or 0) - logicalWidth) >= 1
        or math.abs((tonumber(previous.logicalHeight) or 0) - logicalHeight) >= 1
        or math.abs((tonumber(previous.uiScale) or 0) - uiScale) >= 0.001
    if changed then
        self.viewportMetrics = {
            logicalWidth = logicalWidth,
            logicalHeight = logicalHeight,
            uiScale = uiScale,
        }
        D.MarkLayoutDirty()
        D.MarkViewDirty()
    end
    return changed
end

function UIX:LayoutAll()
    if self.movingCount > 0 or self.resizingCount > 0 then return end
    local _, _, uiScale, logicalWidth, logicalHeight = U.GetUiMetrics()
    self.viewportMetrics = { logicalWidth = logicalWidth, logicalHeight = logicalHeight, uiScale = uiScale }
    local friendlyRect = D.State.ui.friendly
    local enemyRect = D.State.ui.enemy
    -- Responsive pair placement is bootstrap-only.  It must never run as a
    -- consequence of dragging one HUD, otherwise an untouched peer window can
    -- appear to be linked even though the drag transaction itself is isolated.
    if self.quickAutoPlacementResolved ~= true
        and friendlyRect.userMoved ~= true and enemyRect.userMoved ~= true then
        if logicalWidth >= 748 then
            local quickWidth = math.min(360, math.floor((logicalWidth - 36) / 2))
            local quickHeight = math.min(C.QUICK_WINDOW_H, math.max(220, logicalHeight - 180))
            U.SetRectFromLogical(friendlyRect, 12, 160, quickWidth, quickHeight)
            U.SetRectFromLogical(enemyRect, 24 + quickWidth, 160, quickWidth, quickHeight)
        else
            local top = logicalHeight >= 620 and 70 or 12
            local gap = 8
            local quickWidth = math.max(240, math.min(360, logicalWidth - 24))
            quickWidth = math.min(quickWidth, logicalWidth)
            local availableHeight = math.max(1, logicalHeight - top - 12 - gap)
            local quickHeight = math.floor(availableHeight / 2)
            local oneRowHeight = C.HEADER_H + C.FOOTER_H + C.ROW_H + 4
            local stackedMinimum = math.min(oneRowHeight, math.max(1, quickHeight), logicalHeight)
            quickHeight = U.Clamp(quickHeight, stackedMinimum, math.min(C.QUICK_WINDOW_H, logicalHeight))
            U.SetRectFromLogical(friendlyRect, math.max(0, math.floor((logicalWidth - quickWidth) / 2)), top, quickWidth, quickHeight)
            U.SetRectFromLogical(enemyRect, math.max(0, math.floor((logicalWidth - quickWidth) / 2)), top + quickHeight + gap, quickWidth, quickHeight)
        end
    end
    self.quickAutoPlacementResolved = true
    U.ApplyRect(Boot.launcher, D.State.ui.launcher, 88, 26)
    if Boot.ApplyLauncherOpacity ~= nil then
        Boot:ApplyLauncherOpacity(D.State.config.launcherOpacity)
    end
    self:LayoutConfigWindow()
    self:LayoutQuickWindow("friendly")
    self:LayoutQuickWindow("enemy")
    self:LayoutDetailWindow()
    self:LayoutConfirmWindow()
    self:LayoutPrintChooser()
    self:RefreshControls()
    D.State.dirty.layout = false
end

function UIX:LayoutConfirmWindow()
    local window = self.windows.confirm
    if window == nil then return end
    local _, _, _, logicalWidth, logicalHeight = U.GetUiMetrics()
    local width = math.min(CONFIRM_DEFAULT_W, math.max(240, logicalWidth - 24))
    local height = math.min(CONFIRM_DEFAULT_H, math.max(172, logicalHeight - 16))
    local x = math.max(0, math.floor((logicalWidth - width) / 2))
    local y = math.max(0, math.floor((logicalHeight - height) / 2))

    window:RemoveAllAnchors()
    window:AddAnchor("TOPLEFT", "UIParent", x, y)
    window:SetExtent(width, height)

    local contentWidth = math.max(1, width - 24)
    SetLabelExtent(self.controls.confirmTitle, contentWidth, 22)
    SetLabelExtent(self.controls.confirmLine1, contentWidth, 18)
    SetLabelExtent(self.controls.confirmLine2, contentWidth, 18)
    SetLabelExtent(self.controls.confirmLine3, contentWidth, 18)

    local buttonY = height - 51
    local gap = width < 260 and 6 or 18
    local buttonWidth = math.min(110, math.max(1, math.floor((contentWidth - gap) / 2)))
    local totalButtonsWidth = buttonWidth * 2 + gap
    local firstX = math.max(0, math.floor((width - totalButtonsWidth) / 2))
    self.controls.confirmYes:RemoveAllAnchors()
    self.controls.confirmYes:AddAnchor("TOPLEFT", window, firstX, buttonY)
    ApplyButtonStyle(self.controls.confirmYes, buttonWidth, 27, 10)
    self.controls.confirmNo:RemoveAllAnchors()
    self.controls.confirmNo:AddAnchor("TOPLEFT", window, firstX + buttonWidth + gap, buttonY)
    ApplyButtonStyle(self.controls.confirmNo, buttonWidth, 27, 10)
end

function UIX:SetSuiteHudEffectiveVisible(sideName, effectiveVisible, preferredVisible)
    D.State.runtime.suiteHudVisibility = type(D.State.runtime.suiteHudVisibility) == "table"
        and D.State.runtime.suiteHudVisibility or {}
    D.State.runtime.suiteHudVisibility[sideName] = effectiveVisible == true
    local key = sideName == "friendly" and "showFriendly" or sideName == "enemy" and "showEnemy" or nil
    if key ~= nil and preferredVisible ~= nil and D.State.config[key] ~= (preferredVisible == true) then
        D.State.config[key] = preferredVisible == true
        D.MarkConfigDirty()
    end
    self:ApplyVisibility()
end

function UIX:SetSuiteHudLocked(sideName, effectiveLocked, preferredLocked)
    if sideName ~= "friendly" and sideName ~= "enemy" then return false end
    local key = sideName == "friendly" and "friendlyLocked" or "enemyLocked"
    -- Keep the historical domain field as a compatibility mirror only. Suite
    -- HudManager is the read/write Authority while embedded.
    if D.State.config[key] ~= (preferredLocked == true) then
        D.State.config[key] = preferredLocked == true
        D.MarkConfigDirty()
    end
    self:LayoutQuickWindow(sideName)
    return true
end

function UIX:CaptureSuiteHudProfile(sideName, placement)
    if type(placement) ~= "table" or (sideName ~= "friendly" and sideName ~= "enemy") then return false end
    local rect = D.State and D.State.ui and D.State.ui[sideName] or nil
    if type(rect) ~= "table" then return false end
    for _, key in ipairs({"anchorH","anchorV","offsetX","offsetY","width","height","userMoved"}) do
        if rect[key] ~= nil then placement[key] = rect[key] end
    end
    placement.profileExtra = type(placement.profileExtra) == "table" and placement.profileExtra or {}
    placement.profileExtra.domainGeometryCaptured = true
    placement.profileExtra.visualScale = tonumber(rect.visualScale)
    placement.profileExtra.rankingScale = tonumber(D.State.config.rankingScale)
    placement.profileExtra.rankingOpacity = tonumber(D.State.config.rankingOpacity)
    placement.profileExtra.compactMode = D.State.config.compactMode == true
    return true
end

function UIX:ApplySuiteHudProfile(sideName, placement)
    if type(placement) ~= "table" or (sideName ~= "friendly" and sideName ~= "enemy") then return false end
    local extra = placement.profileExtra
    -- Profiles created before Architecture Audit 2 did not capture DPS domain
    -- geometry. Preserve the user's current DPS layout instead of applying the
    -- old dummy Suite placement defaults.
    if type(extra) ~= "table" or extra.domainGeometryCaptured ~= true then return true end
    local rect = D.State and D.State.ui and D.State.ui[sideName] or nil
    if type(rect) ~= "table" then return false end
    if placement.anchorH == "LEFT" or placement.anchorH == "RIGHT" then rect.anchorH = placement.anchorH end
    if placement.anchorV == "TOP" or placement.anchorV == "BOTTOM" then rect.anchorV = placement.anchorV end
    if tonumber(placement.offsetX) ~= nil then rect.offsetX = math.max(0, tonumber(placement.offsetX)) end
    if tonumber(placement.offsetY) ~= nil then rect.offsetY = math.max(0, tonumber(placement.offsetY)) end
    if tonumber(placement.width) ~= nil and tonumber(placement.width) > 0 then rect.width = tonumber(placement.width) end
    if tonumber(placement.height) ~= nil and tonumber(placement.height) > 0 then rect.height = tonumber(placement.height) end
    if placement.userMoved ~= nil then rect.userMoved = placement.userMoved == true end
    if tonumber(extra.visualScale) ~= nil then rect.visualScale = tonumber(extra.visualScale) end
    if tonumber(extra.rankingScale) ~= nil then D.State.config.rankingScale = U.Clamp(tonumber(extra.rankingScale), 0.60, 1.20) end
    if tonumber(extra.rankingOpacity) ~= nil then D.State.config.rankingOpacity = U.Clamp(tonumber(extra.rankingOpacity), 0.50, 1.00) end
    if extra.compactMode ~= nil then D.State.config.compactMode = extra.compactMode == true end
    D.MarkUiDirty(); D.MarkConfigDirty(); D.MarkLayoutDirty()
    self:LayoutQuickWindow(sideName)
    self:RefreshConfig()
    return true
end

function UIX:ApplySuiteEditMode(enabled)
    self.suiteEditMode = enabled == true
    self:LayoutQuickWindow("friendly")
    self:LayoutQuickWindow("enemy")
end

function UIX:ApplyVisibility()
    -- Module lifecycle and HUD visibility are separate Authorities in Suite.
    local running = IsDpsModuleEnabled()
    if ReplicatedSuiteEmbedded == true then
        local vis = type(D.State.runtime.suiteHudVisibility) == "table" and D.State.runtime.suiteHudVisibility or {}
        self.windows.friendly:Show(running and vis.friendly == true)
        self.windows.enemy:Show(running and vis.enemy == true)
    else
        self.windows.friendly:Show(running and D.State.config.showFriendly == true)
        self.windows.enemy:Show(running and D.State.config.showEnemy == true)
    end

    -- Each ranking HUD owns an independent unscaled movement host.  Visibility
    -- follows only its own ranking window; there is deliberately no paired or
    -- linked movement state between friendly and enemy windows.
    for _, sideName in ipairs({ "friendly", "enemy" }) do
        local surface = self.controls[sideName .. "Drag"]
        local window = self.windows[sideName]
        local host = self.dragHosts and self.dragHosts[sideName] or nil
        if window ~= nil and host ~= nil then host:Show(window:IsVisible()) end
        if surface ~= nil and window ~= nil then
            local enabled = window:IsVisible() and not IsQuickHudLocked(sideName)
            if surface.EnableDrag ~= nil then surface:EnableDrag(enabled) end
            if surface.Clickable ~= nil then surface:Clickable(enabled) end
            surface:Show(enabled)
            if enabled and surface.Raise ~= nil then pcall(function() surface:Raise() end) end
        end
    end
    D.MarkViewDirty()
end

function UIX:ToggleConfig()
    if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.UI ~= nil then
        ReplicatedSuite.UI:ShowPage("dps")
        return true
    end
    local window = self.windows.config
    if window == nil then return false end
    window:Show(not window:IsVisible())
    if window:IsVisible() then
        window:SetUILayer("system")
        if window.Raise ~= nil then window:Raise() end
        self:RefreshConfig()
    end
end

function UIX:ShowClearConfirmation()
    self:LayoutConfirmWindow()
    SetBoundedText(self.controls.confirmLine1, "即将清空 PVP 与 PVE 的全部累计统计。", self.controls.confirmLine1.repdpsWidth, 10)
    SetBoundedText(self.controls.confirmLine2, "包括友军/敌军的伤害、承伤和治疗。", self.controls.confirmLine2.repdpsWidth, 10)
    SetBoundedText(self.controls.confirmLine3, "同时清空待确认与重放缓存；可在设置中恢复一次。", self.controls.confirmLine3.repdpsWidth, 10)
    self.windows.confirm:Show(true)
    if self.windows.confirm.Raise ~= nil then self.windows.confirm:Raise() end
end

function UIX:ResetPositions()
    D.State.ui = U.DeepCopy(D.Defaults.ui)
    D.MarkUiDirty()
    D.MarkLayoutDirty()
    self:LayoutAll()
end

local function ToggleConfigValue(key)
    if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.HudManager ~= nil then
        if key == "showFriendly" or key == "showEnemy" then
            local hudId = key == "showFriendly" and "dps_friendly" or "dps_enemy"
            if ReplicatedSuite.HudManager:ToggleVisible(hudId) ~= false then
                UIX:RefreshConfig()
                return
            end
        end
        if key == "friendlyLocked" or key == "enemyLocked" then
            local hudId = key == "friendlyLocked" and "dps_friendly" or "dps_enemy"
            if ReplicatedSuite.HudManager:ToggleLocked(hudId) ~= false then
                UIX:RefreshConfig()
                return
            end
        end
    end
    D.State.config[key] = not D.State.config[key]
    if key == "diagnosticsEnabled" then
        if type(IdentityShadow) == "table" and type(IdentityShadow.OnDiagnosticsChanged) == "function" then
            IdentityShadow:OnDiagnosticsChanged(D.State.config[key] == true)
        end
        if type(EventBlocks) == "table" and type(EventBlocks.OnDiagnosticsChanged) == "function" then
            local ok, err = pcall(EventBlocks.OnDiagnosticsChanged, EventBlocks,
                D.State.config[key] == true)
            if not ok and type(EventBlocks.DisableAfterFailure) == "function" then
                pcall(EventBlocks.DisableAfterFailure, EventBlocks, err)
            end
        end
        if type(LocalReplay) == "table" and type(LocalReplay.OnDiagnosticsChanged) == "function" then
            local ok, err = pcall(LocalReplay.OnDiagnosticsChanged, LocalReplay,
                D.State.config[key] == true)
            if not ok and type(LocalReplay.DisableAfterFailure) == "function" then
                pcall(LocalReplay.DisableAfterFailure, LocalReplay, err)
            end
        end
        if type(PersistenceShards) == "table"
            and type(PersistenceShards.OnDiagnosticsChanged) == "function" then
            local ok, err = pcall(PersistenceShards.OnDiagnosticsChanged, PersistenceShards,
                D.State.config[key] == true)
            if not ok and type(PersistenceShards.Cancel) == "function" then
                pcall(PersistenceShards.Cancel, PersistenceShards, err)
            end
        end
        if type(PersistenceLoadGate) == "table"
            and type(PersistenceLoadGate.OnDiagnosticsChanged) == "function" then
            local ok, err = pcall(PersistenceLoadGate.OnDiagnosticsChanged,
                PersistenceLoadGate, D.State.config[key] == true)
            if not ok and type(PersistenceLoadGate.Cancel) == "function" then
                pcall(PersistenceLoadGate.Cancel, PersistenceLoadGate, err)
            end
        end
        if type(EventShadow) == "table" and type(EventShadow.OnDiagnosticsChanged) == "function" then
            local ok, err = pcall(EventShadow.OnDiagnosticsChanged, EventShadow,
                D.State.config[key] == true)
            if not ok and type(EventShadow.DisableAfterFailure) == "function" then
                pcall(EventShadow.DisableAfterFailure, EventShadow, err)
            end
        end
    end
    D.MarkConfigDirty()
    if key == "showFriendly" or key == "showEnemy" then
        UIX:ApplyVisibility()
    else
        if key == "showPercent" or key == "compactMode" then D.MarkLayoutDirty() end
        D.MarkViewDirty()
    end
    UIX:RefreshConfig()
end

local function AdjustConfigValue(key, delta, minValue, maxValue, step)
    local current = tonumber(D.State.config[key]) or minValue
    D.State.config[key] = U.Clamp(current + delta * (step or 1), minValue, maxValue)
    D.MarkConfigDirty()
    if key == "rankingScale" or key == "rankingOpacity" then D.MarkLayoutDirty() end
    if key == "launcherOpacity" and Boot.ApplyLauncherOpacity ~= nil then
        Boot:ApplyLauncherOpacity(D.State.config.launcherOpacity)
    end
    UIX:RefreshConfig()
    D.MarkViewDirty()
end

-- Compact mode is a presentation-only projection.  Keep the full-mode window
-- dimensions in memory so one click can shrink to a useful ranking strip and
-- one click can return to the previous full layout without changing statistics.
UIX.compactRestoreSizes = UIX.compactRestoreSizes or {}

local function SetCompactMode(enabled)
    enabled = enabled == true
    if (D.State.config.compactMode == true) == enabled then return end

    for _, sideName in ipairs({ "friendly", "enemy" }) do
        local rect = D.State.ui[sideName]
        if rect ~= nil then
            local x, y, width, height = U.ResolveRect(rect, C.FRIENDLY_WINDOW_W, C.QUICK_WINDOW_H)
            if enabled then
                UIX.compactRestoreSizes[sideName] = { width = width, height = height }
                -- At 100% scale this is already much smaller than the normal
                -- meter. rankingScale can reduce the visual footprint further.
                width = math.min(width, 240)
                height = math.min(height, 190)
            else
                local restore = UIX.compactRestoreSizes[sideName]
                if type(restore) == "table" then
                    width = tonumber(restore.width) or width
                    height = tonumber(restore.height) or height
                end
            end
            U.SetRectFromLogical(rect, x, y, width, height)
            -- The user explicitly selected this layout; prevent the automatic
            -- first-layout policy from immediately expanding it back to 360px.
            rect.userMoved = true
        end
    end

    D.State.config.compactMode = enabled
    UIX.rankingOffsets.friendly = 0
    UIX.rankingOffsets.enemy = 0
    D.MarkConfigDirty()
    D.MarkUiDirty()
    D.MarkLayoutDirty()
    D.MarkViewDirty()
    UIX:LayoutAll()
    UIX:RefreshConfig()
    UIX:RefreshQuickWindows()
end

-- Shared settings facade used by both the historical standalone panel and the
-- consolidated Replicated Suite page.  The Suite page must not mutate mirrored
-- config fields directly when another subsystem owns the effective state (HUD
-- visibility/lock), and settings with domain side effects must follow the same
-- path regardless of which UI surface initiated the change.
function UIX:ToggleSetting(key)
    if key == "compactMode" then
        SetCompactMode(D.State.config.compactMode ~= true)
        return true
    end

    if key == "inferChineseNamesAsNpc" then
        D.State.config.inferChineseNamesAsNpc = not D.State.config.inferChineseNamesAsNpc
        D.MarkConfigDirty()
        if D.Entities ~= nil and type(D.Entities.RefreshChineseNameKinds) == "function" then
            D.Entities:RefreshChineseNameKinds(D.State.config.inferChineseNamesAsNpc)
        elseif type(D.RequestReclassify) == "function" then
            D.RequestReclassify(false)
        end
        D.MarkViewDirty()
        self:RefreshConfig()
        self:RefreshQuickWindows()
        return true
    end

    if key == "useSocialFriendlyPriors" then
        D.State.config.useSocialFriendlyPriors = not D.State.config.useSocialFriendlyPriors
        D.MarkConfigDirty()
        if type(D.RequestReclassify) == "function" then D.RequestReclassify(false) end
        D.MarkViewDirty()
        self:RefreshConfig()
        self:RefreshQuickWindows()
        return true
    end

    ToggleConfigValue(key)
    return true
end

function UIX:SetNumericSetting(key, value, layout)
    local numeric = tonumber(value)
    if numeric == nil then return false, "INVALID_NUMBER" end
    D.State.config[key] = numeric
    D.MarkConfigDirty()

    local needsLayout = layout == true or key == "rankingScale" or key == "rankingOpacity"
    if needsLayout then D.MarkLayoutDirty() end
    D.MarkViewDirty()
    if needsLayout then self:LayoutAll() end
    self:RefreshConfig()
    if needsLayout or key == "displayRows" then self:RefreshQuickWindows() end
    return true
end

function UIX:ToggleScopeMode()
    D.State.config.scopeMode = D.State.config.scopeMode == "team" and "range" or "team"
    D.MarkConfigDirty()
    D.MarkViewDirty()
    if D.State.config.scopeMode == "team" then
        D.Boot.SafeChat("已切换为团队模式。现有统计已保留；如需纯团队统计，请手动清空。非团队单位仍用于目标、承伤来源及 PVP/PVE 判断。")
    else
        D.Boot.SafeChat("已切换为目标+团队模式。现有统计已保留；官方已禁用广域枚举，当前仅按目标与团队观察降级统计。")
    end
    self:RefreshConfig()
    self:RefreshQuickWindows()
    return true
end

function UIX:RestoreLastClearFromSettings()
    if D.EventStore ~= nil and D.EventStore.historyCoverageComplete == false then
        D.Boot.SafeChat("大规模保护模式已轮换纠错日志，当前无法安全恢复上一次清空；正式累计数据未受影响。")
        return false, "HISTORY_INCOMPLETE"
    end
    local restoredMode = D.Stats ~= nil and D.Stats.RestoreLastClear ~= nil and D.Stats:RestoreLastClear() or nil
    if restoredMode == nil then
        D.Boot.SafeChat("没有可恢复的清空快照。")
        return false, "NO_SNAPSHOT"
    end
    if D.Runtime ~= nil and type(D.Runtime.RestoreClearedMode) == "function" then
        D.Runtime:RestoreClearedMode(restoredMode)
    end
    if type(D.QueueStatsSave) == "function" then D.QueueStatsSave() end
    local restoredLabel = restoredMode == "ALL" and "PVP/PVE 全部统计" or tostring(restoredMode)
    D.Boot.SafeChat("已恢复上一次 " .. restoredLabel .. " 清空；统计将在重放完成并脱战后分帧保存。")
    self:RefreshQuickWindows()
    return true
end

function UIX:RepairHudFromSettings()
    if D.Runtime ~= nil and type(D.Runtime.ResetCircuitBreakers) == "function" then
        D.Runtime:ResetCircuitBreakers()
    end
    if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.HudManager ~= nil then
        if ReplicatedSuite.HudManager:Get("dps_friendly") ~= nil then ReplicatedSuite.HudManager:Apply("dps_friendly") end
        if ReplicatedSuite.HudManager:Get("dps_enemy") ~= nil then ReplicatedSuite.HudManager:Apply("dps_enemy") end
    end
    D.MarkLayoutDirty()
    self:LayoutAll()
    self:ApplyVisibility()
    self:RefreshControls()
    self:RefreshQuickWindows()
    return true
end

function UIX:SaveNowFromSettings()
    local failures = {}
    local function SaveOne(label, fn)
        if type(fn) ~= "function" then
            failures[#failures + 1] = label
            return
        end
        local ok, result = xpcall(fn, Boot.SafeTraceback)
        if not ok then
            if D.Diagnostics ~= nil and type(D.Diagnostics.AddError) == "function" then
                D.Diagnostics:AddError("save", label .. ": " .. tostring(result))
            end
            failures[#failures + 1] = label
        elseif result ~= true then
            failures[#failures + 1] = label
        end
    end

    SaveOne("配置", D.SaveConfigNow)
    SaveOne("UI", D.SaveUiNow)
    SaveOne("名单", D.SaveRulesNow)

    local statsQueued = false
    if type(D.QueueStatsSave) == "function" then
        local ok, result = xpcall(D.QueueStatsSave, Boot.SafeTraceback)
        statsQueued = ok and result == true
        if not ok and D.Diagnostics ~= nil and type(D.Diagnostics.AddError) == "function" then
            D.Diagnostics:AddError("save", "统计排队: " .. tostring(result))
        end
    end
    if #failures == 0 then
        D.Boot.SafeChat(statsQueued
            and "DPS 配置、UI 与名单已保存；统计已排队，将在脱战且重放完成后分帧保存。"
            or "DPS 配置、UI 与名单已保存；统计排队失败。")
        return statsQueued
    end

    D.Boot.SafeChat("DPS 保存失败：" .. table.concat(failures, "、")
        .. (statsQueued and "；统计仍已排队。" or "；统计也未能排队。"))
    return false
end

function UIX:RescanNowFromSettings()
    if not IsDpsModuleEnabled() then
        D.Boot.SafeChat("当前模块未启用；立即扫描需要先启用伤害统计。")
        return false, "MODULE_DISABLED"
    end
    if D.Runtime == nil or type(D.Runtime.ScanRoster) ~= "function" then
        D.Boot.SafeChat("DPS 团队扫描未启动：Runtime 不可用。")
        return false, "RUNTIME_UNAVAILABLE"
    end
    local ok, result = D.Runtime:ScanRoster(true, {
        completeNow = true,
        reportResult = true,
        reprocessPending = true,
    })
    self:RefreshConfig()
    self:RefreshQuickWindows()
    return ok, result
end

local function InstallHandlers()
    SafeHandler(UIX.controls.modeButton, "OnClick", function()
        UIX:SetMode(D.State.config.currentMode == "PVP" and "PVE" or "PVP")
    end, "mode")
    SafeHandler(UIX.controls.damageButton, "OnClick", function() UIX:SetPage("DAMAGE") end, "damage")
    SafeHandler(UIX.controls.takenButton, "OnClick", function() UIX:SetPage("TAKEN") end, "taken")
    SafeHandler(UIX.controls.healButton, "OnClick", function() UIX:SetPage("HEAL") end, "heal")
    if UIX.controls.friendlyPrintButton ~= nil then
        SafeHandler(UIX.controls.friendlyPrintButton, "OnClick", function() UIX:ShowPrintChooser("friendly") end, "friendly_print")
    end
    SafeHandler(UIX.controls.clearButton, "OnClick", function() UIX:ShowClearConfirmation() end, "clear")
    SafeHandler(UIX.controls.configButton, "OnClick", function() UIX:ToggleConfig() end, "config")
    local function ToggleCompactMode()
        SetCompactMode(D.State.config.compactMode ~= true)
    end
    SafeHandler(UIX.controls.friendlyCompactButton, "OnClick", ToggleCompactMode, "friendly_compact")
    SafeHandler(UIX.controls.enemyCompactButton, "OnClick", ToggleCompactMode, "enemy_compact")
    if UIX.controls.enemyPrintButton ~= nil then
        SafeHandler(UIX.controls.enemyPrintButton, "OnClick", function() UIX:ShowPrintChooser("enemy") end, "enemy_print")
    end
    if UIX.controls.printClose ~= nil then
        SafeHandler(UIX.controls.printClose, "OnClick", function() UIX:HidePrintChooser() end, "print_close")
    end
    if UIX.controls.printDamage ~= nil then
        SafeHandler(UIX.controls.printDamage, "OnClick", function() UIX:PrintRankingMetric("DAMAGE") end, "print_damage")
    end
    if UIX.controls.printTaken ~= nil then
        SafeHandler(UIX.controls.printTaken, "OnClick", function() UIX:PrintRankingMetric("TAKEN") end, "print_taken")
    end
    if UIX.controls.printHeal ~= nil then
        SafeHandler(UIX.controls.printHeal, "OnClick", function() UIX:PrintRankingMetric("HEAL") end, "print_heal")
    end
    if UIX.controls.enemyBossButton ~= nil then
        SafeHandler(UIX.controls.enemyBossButton, "OnClick", function()
            UIX:ToggleCurrentTargetBoss()
        end, "enemy_current_target_boss")
    end
    SafeHandler(UIX.controls.enemySettingsButton, "OnClick", function()
        UIX:ToggleConfig()
    end, "enemy_settings")
    SafeHandler(UIX.controls.configClose, "OnClick", function() UIX.windows.config:Show(false) end, "config_close")
    SafeHandler(UIX.controls.confirmNo, "OnClick", function() UIX.windows.confirm:Show(false) end, "confirm_no")
    SafeHandler(UIX.controls.detailClose, "OnClick", function() UIX:CloseDetail() end, "detail_close")
    if UIX.controls.detailBack ~= nil then
        SafeHandler(UIX.controls.detailBack, "OnClick", function() UIX:GoBackDetail() end, "detail_back")
    end
    SafeHandler(UIX.controls.detailAbility, "OnClick", function()
        UIX.detail.view = "ABILITY"
        UIX.detail.offset = 0
        UIX.detail.entryCache = nil
        UIX.detail.entryJob = nil
        UIX:RefreshDetail()
    end, "detail_ability")
    SafeHandler(UIX.controls.detailCounterpart, "OnClick", function()
        UIX.detail.view = "COUNTERPART"
        UIX.detail.offset = 0
        UIX.detail.entryCache = nil
        UIX.detail.entryJob = nil
        UIX:RefreshDetail()
    end, "detail_counterpart")
    SafeHandler(UIX.controls.detailPrev, "OnClick", function()
        local step = U.Clamp(UIX.visibleDetailRows or DETAIL_ROWS, 1, DETAIL_ROWS)
        UIX.detail.offset = math.max(0, (tonumber(UIX.detail.offset) or 0) - step)
        UIX:RefreshDetail()
    end, "detail_prev")
    SafeHandler(UIX.controls.detailNext, "OnClick", function()
        local step = U.Clamp(UIX.visibleDetailRows or DETAIL_ROWS, 1, DETAIL_ROWS)
        local maxOffset = math.max(0, (tonumber(UIX.detail.totalEntries) or 0) - step)
        UIX.detail.offset = math.min(maxOffset, (tonumber(UIX.detail.offset) or 0) + step)
        UIX:RefreshDetail()
    end, "detail_next")
    SafeHandler(UIX.controls.detailFriendly, "OnClick", function() UIX:ApplySelectedManual(nil, "FRIENDLY", nil) end, "detail_friend")
    SafeHandler(UIX.controls.detailEnemy, "OnClick", function() UIX:ApplySelectedManual(nil, "OPPONENT", nil) end, "detail_enemy")
    SafeHandler(UIX.controls.detailPlayer, "OnClick", function() UIX:ApplySelectedManual("PLAYER", nil, nil) end, "detail_player")
    SafeHandler(UIX.controls.detailNpc, "OnClick", function() UIX:ApplySelectedManual("NPC", nil, nil) end, "detail_npc")
    SafeHandler(UIX.controls.detailOther, "OnClick", function() UIX:ApplySelectedManual("OTHER", nil, nil) end, "detail_other")
    SafeHandler(UIX.controls.detailIgnore, "OnClick", function() UIX:ToggleSelectedIgnore() end, "detail_ignore")
    SafeHandler(UIX.controls.detailAuto, "OnClick", function() UIX:ClearSelectedManual() end, "detail_auto")
    SafeHandler(UIX.controls.detailSaveRule, "OnClick", function() UIX:SaveSelectedRule() end, "detail_save_rule")
    SafeHandler(UIX.controls.detailRemoveRule, "OnClick", function() UIX:RemoveSelectedRule() end, "detail_remove_rule")
    if UIX.controls.detailExcludeTarget ~= nil then
        SafeHandler(UIX.controls.detailExcludeTarget, "OnClick", function() UIX:ToggleSelectedExcludedTarget() end, "detail_exclude_target")
    end
    if UIX.controls.detailBossTarget ~= nil then
        SafeHandler(UIX.controls.detailBossTarget, "OnClick", function() UIX:ToggleSelectedBossTarget() end, "detail_boss_target")
    end
    if UIX.controls.friendlyFooter ~= nil then
        if UIX.controls.friendlyFooter.EnablePick ~= nil then UIX.controls.friendlyFooter:EnablePick(true) end
        if UIX.controls.friendlyFooter.Clickable ~= nil then UIX.controls.friendlyFooter:Clickable(true) end
        SafeHandler(UIX.controls.friendlyFooter, "OnClick", function()
            UIX:ClearActiveDamageAnalysis()
        end, "friendly_footer_analysis_clear")
    end
    for index, row in ipairs(UIX.detailRows or {}) do
        -- Capture a per-iteration local explicitly. ArcheRage may use Lua 5.1
        -- semantics, where closing over the generic-for variable can make all
        -- row handlers observe the final row after the loop completes.
        local capturedRow = row
        SafeHandler(capturedRow.panel, "OnClick", function()
            local data = capturedRow.data
            if type(data) ~= "table" then return end
            if data.kind == "COUNTERPART" then UIX:OpenCounterpartEntry(data)
            elseif data.kind == "CANDIDATE" then UIX:OpenCandidateEntity(data.candidate) end
        end, "detail_row_click_" .. tostring(index))
        -- ArcheAge UI uses OnRButtonUp for row context actions. This handler is
        -- deliberately limited to PVE friendly damage targets; all other detail
        -- rows keep their original behavior.
        SafeHandler(capturedRow.panel, "OnRButtonUp", function()
            local data = capturedRow.data
            if type(data) ~= "table" or data.kind ~= "COUNTERPART" then return end
            if data.originMode == "PVE" and data.originSide == "friendly" and data.originPage == "DAMAGE" then
                UIX:ToggleExcludedTarget(data.name)
            else
                D.Boot.SafeChat("右键排除只适用于 PVE 友军伤害详情中的目标。")
            end
        end, "detail_row_right_click_" .. tostring(index))
    end
    SafeHandler(UIX.controls.confirmYes, "OnClick", function()
        D.Stats:ClearAll()
        D.Runtime:ClearAllCombatData()
        UIX.rankingOffsets.friendly = 0
        UIX.rankingOffsets.enemy = 0
        UIX.windows.confirm:Show(false)
        UIX:HidePrintChooser()
        UIX:CloseDetail()
        -- rc3：清空发生在战斗主线程，不能立刻同步序列化整棵统计树。
        -- ClearAll 已标记 dirty；Runtime 会在连续空闲后安全保存。
        D.Boot.SafeChat("统计已清空；新数据会立即继续累计，存档将在空闲时自动保存。")
    end, "confirm_yes")

    local function PageRanking(sideName, direction)
        local step = math.max(1, UIX.visibleRows[sideName] or 10)
        UIX.rankingOffsets[sideName] = math.max(0, (UIX.rankingOffsets[sideName] or 0) + direction * step)
        UIX:RefreshQuickWindow(sideName)
    end
    SafeHandler(UIX.controls.friendlyPrev, "OnClick", function() PageRanking("friendly", -1) end, "friendly_prev")
    SafeHandler(UIX.controls.friendlyNext, "OnClick", function() PageRanking("friendly", 1) end, "friendly_next")
    SafeHandler(UIX.controls.enemyPrev, "OnClick", function() PageRanking("enemy", -1) end, "enemy_prev")
    SafeHandler(UIX.controls.enemyNext, "OnClick", function() PageRanking("enemy", 1) end, "enemy_next")

    for _, sideName in ipairs({ "friendly", "enemy" }) do
        local capturedSide = sideName
        for i = 1, C.MAX_ROWS do
            local capturedRow = UIX.rows[capturedSide][i]
            SafeHandler(capturedRow.panel, "OnClick", function()
                if capturedRow.data ~= nil then UIX:ShowDetail(capturedSide, capturedRow.data) end
            end, "row_" .. capturedSide .. "_" .. tostring(i))
            SafeHandler(capturedRow.panel, "OnRButtonUp", function()
                local item = capturedRow.data
                if capturedSide ~= "enemy" or type(item) ~= "table" then return end
                if D.State.config.currentMode ~= "PVE" or UIX:GetQuickPage() ~= "DAMAGE" then
                    D.Boot.SafeChat("右键设置 Boss 只适用于 PVE 伤害页。")
                    return
                end
                local entity = Actors:GetEntityByKey(item.key)
                local kind = EffectiveEntityKind(entity)
                if kind == "PLAYER" then
                    D.Boot.SafeChat("玩家不能设置为 Boss。")
                    return
                end
                UIX:ToggleBossTarget(item.name, entity)
            end, "row_boss_" .. capturedSide .. "_" .. tostring(i))
        end
    end

    -- Suite mode no longer allocates the historical standalone config window.
    -- Every handler below this fence belongs exclusively to that legacy window;
    -- binding them when the window was intentionally omitted caused the embedded
    -- DPS shell to fail at UIX.controls.tabs[1] before Runtime could start.
    if UIX.windows.config ~= nil then
    for i = 1, 6 do
        local index = i
        SafeHandler(UIX.controls.tabs[i], "OnClick", function() UIX:SetConfigPage(index) end, "tab_" .. tostring(i))
    end

    for index, row in ipairs(UIX.ruleRows) do
        SafeHandler(row.button, "OnClick", function()
            if row.ruleId ~= nil then
                UIX.ruleList.selectedRuleId = row.ruleId
                UIX:RefreshRulesPage()
            end
        end, "rule_row_" .. tostring(index))
    end
    SafeHandler(UIX.controls.rulesPrev, "OnClick", function()
        local step = U.Clamp(UIX.ruleList.visibleRows or 8, 1, #UIX.ruleRows)
        UIX.ruleList.offset = math.max(0, (UIX.ruleList.offset or 0) - step)
        UIX:RefreshRulesPage()
    end, "rules_prev")
    SafeHandler(UIX.controls.rulesNext, "OnClick", function()
        local step = U.Clamp(UIX.ruleList.visibleRows or 8, 1, #UIX.ruleRows)
        local maxOffset = math.max(0, (UIX.ruleList.totalEntries or 0) - step)
        UIX.ruleList.offset = math.min(maxOffset, (UIX.ruleList.offset or 0) + step)
        UIX:RefreshRulesPage()
    end, "rules_next")
    SafeHandler(UIX.controls.rulesToggle, "OnClick", function()
        local rule = UIX.ruleList.selectedRuleId and D.Rules:GetById(UIX.ruleList.selectedRuleId) or nil
        if rule ~= nil then
            local enabling = rule.enabled == false
            local changed, reason = D.Rules:SetEnabled(rule.ruleId, enabling)
            if changed then
                if reason == "NO_CHANGE" then
                    D.Boot.SafeChat("名单规则状态未变化：" .. tostring(rule.displayName))
                else
                    D.Boot.SafeChat((enabling and "已启用名单规则：" or "已停用名单规则：")
                        .. tostring(rule.displayName) .. ManualReclassifySuffix())
                end
            end
            UIX:RefreshRulesPage()
            UIX:RefreshQuickWindows()
            UIX:RefreshDetail()
        end
    end, "rules_toggle")
    SafeHandler(UIX.controls.rulesDelete, "OnClick", function()
        local ruleId = UIX.ruleList.selectedRuleId
        if ruleId ~= nil and D.Rules:Remove(ruleId) then
            UIX.ruleList.selectedRuleId = nil
            D.Boot.SafeChat("已删除名单规则。" .. ManualReclassifySuffix())
            UIX:RefreshRulesPage()
            UIX:RefreshQuickWindows()
            UIX:RefreshDetail()
        end
    end, "rules_delete")
    SafeHandler(UIX.controls.rulesRestoreSession, "OnClick", function()
        local count = D.Entities:ClearSessionIgnores()
        if count > 0 then
            D.Boot.SafeChat("已恢复本次运行中误忽略的单位：" .. tostring(count) .. " 个"
                .. ManualReclassifySuffix())
            UIX:RefreshQuickWindows()
            UIX:RefreshDetail()
        else
            D.Boot.SafeChat("当前没有仅本次生效的忽略单位。")
        end
    end, "rules_restore_session")
    SafeHandler(UIX.controls.rulesClear, "OnClick", function()
        local now = U.NowMs()
        if now - (tonumber(UIX.ruleList.clearArmedAt) or 0) > 5000 then
            UIX.ruleList.clearArmedAt = now
            D.Boot.SafeChat("再次点击‘清空全部名单’确认；5秒后自动取消。")
            UIX:RefreshRulesPage()
            return
        end
        UIX.ruleList.clearArmedAt = 0
        if D.Rules:ClearAll() then
            UIX.ruleList.selectedRuleId = nil
            D.Boot.SafeChat("全部持久名单规则已清空。" .. ManualReclassifySuffix())
            UIX:RefreshRulesPage()
            UIX:RefreshQuickWindows()
            UIX:RefreshDetail()
        end
    end, "rules_clear")

    SafeHandler(UIX.controls.enabled, "OnClick", function()
        local desired = not IsDpsModuleEnabled()
        if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.ModuleManager ~= nil then
            ReplicatedSuite.ModuleManager:SetEnabled("dps", desired)
        else
            D.State.config.enabled = desired
            D.State.runtime.paused = not desired
            D.MarkConfigDirty()
            UIX:ApplyVisibility()
            UIX:RefreshConfig()
        end
    end, "enabled")
    SafeHandler(UIX.controls.showFriendly, "OnClick", function() ToggleConfigValue("showFriendly") end, "show_friendly")
    SafeHandler(UIX.controls.showEnemy, "OnClick", function() ToggleConfigValue("showEnemy") end, "show_enemy")
    SafeHandler(UIX.controls.defaultMode, "OnClick", function()
        UIX:SetMode(D.State.config.currentMode == "PVP" and "PVE" or "PVP")
    end, "cfg_mode")
    SafeHandler(UIX.controls.defaultPage, "OnClick", function()
        local order = { "DAMAGE", "TAKEN", "HEAL" }
        local nextPage = order[1]
        for i = 1, #order do
            if order[i] == D.State.config.currentPage then nextPage = order[(i % #order) + 1] break end
        end
        UIX:SetPage(nextPage)
    end, "cfg_page")
    SafeHandler(UIX.controls.friendlyLocked, "OnClick", function() ToggleConfigValue("friendlyLocked") D.MarkLayoutDirty() end, "friend_lock")
    SafeHandler(UIX.controls.enemyLocked, "OnClick", function() ToggleConfigValue("enemyLocked") D.MarkLayoutDirty() end, "enemy_lock")
    SafeHandler(UIX.controls.scopeMode, "OnClick", function() UIX:ToggleScopeMode() end, "scope_mode")
    SafeHandler(UIX.controls.resetPositions, "OnClick", function() UIX:ResetPositions() end, "reset_positions")
    SafeHandler(UIX.controls.restoreClear, "OnClick", function() UIX:RestoreLastClearFromSettings() end, "restore_clear")

    SafeHandler(UIX.controls.compactMode, "OnClick", function() UIX:ToggleSetting("compactMode") end, "compact_mode")
    SafeHandler(UIX.controls.rankingOpacity.minus, "OnClick", function() AdjustConfigValue("rankingOpacity", -1, 0.50, 1.00, 0.10) UIX:LayoutAll() end, "opacity_minus")
    SafeHandler(UIX.controls.rankingOpacity.plus, "OnClick", function() AdjustConfigValue("rankingOpacity", 1, 0.50, 1.00, 0.10) UIX:LayoutAll() end, "opacity_plus")
    SafeHandler(UIX.controls.launcherOpacity.minus, "OnClick", function() AdjustConfigValue("launcherOpacity", -1, 0.20, 1.00, 0.10) end, "launcher_opacity_minus")
    SafeHandler(UIX.controls.launcherOpacity.plus, "OnClick", function() AdjustConfigValue("launcherOpacity", 1, 0.20, 1.00, 0.10) end, "launcher_opacity_plus")
    SafeHandler(UIX.controls.rankingScale.minus, "OnClick", function() AdjustConfigValue("rankingScale", -1, 0.60, 1.20, 0.10) UIX:LayoutAll() end, "scale_minus")
    SafeHandler(UIX.controls.rankingScale.plus, "OnClick", function() AdjustConfigValue("rankingScale", 1, 0.60, 1.20, 0.10) UIX:LayoutAll() end, "scale_plus")
    SafeHandler(UIX.controls.displayRows.minus, "OnClick", function() AdjustConfigValue("displayRows", -1, 10, C.MAX_RANKING_ROWS, 10) end, "rows_minus")
    SafeHandler(UIX.controls.displayRows.plus, "OnClick", function() AdjustConfigValue("displayRows", 1, 10, C.MAX_RANKING_ROWS, 10) end, "rows_plus")
    SafeHandler(UIX.controls.alwaysSelf, "OnClick", function() ToggleConfigValue("alwaysShowSelf") end, "always_self")
    SafeHandler(UIX.controls.abbreviate, "OnClick", function() ToggleConfigValue("abbreviateNumbers") end, "abbreviate")
    SafeHandler(UIX.controls.showPercent, "OnClick", function() ToggleConfigValue("showPercent") end, "percent")
    SafeHandler(UIX.controls.showSuspect, "OnClick", function() ToggleConfigValue("showSuspect") end, "suspect")
    SafeHandler(UIX.controls.showPending, "OnClick", function() ToggleConfigValue("showPendingSummary") end, "pending")
    SafeHandler(UIX.controls.showClosure, "OnClick", function() ToggleConfigValue("showClosure") end, "closure")

    SafeHandler(UIX.controls.chineseNpc, "OnClick", function() UIX:ToggleSetting("inferChineseNamesAsNpc") end, "chinese_npc")
    SafeHandler(UIX.controls.socialPrior, "OnClick", function() UIX:ToggleSetting("useSocialFriendlyPriors") end, "social_prior")
    SafeHandler(UIX.controls.thirdParty, "OnClick", function() ToggleConfigValue("showThirdPartySummary") end, "third")

    SafeHandler(UIX.controls.personalWindow.minus, "OnClick", function() AdjustConfigValue("personalWindowMs", -1, 3000, 10000, 1000) end, "personal_minus")
    SafeHandler(UIX.controls.personalWindow.plus, "OnClick", function() AdjustConfigValue("personalWindowMs", 1, 3000, 10000, 1000) end, "personal_plus")
    SafeHandler(UIX.controls.sideWindow.minus, "OnClick", function() AdjustConfigValue("sideWindowMs", -1, 5000, 15000, 1000) end, "side_minus")
    SafeHandler(UIX.controls.sideWindow.plus, "OnClick", function() AdjustConfigValue("sideWindowMs", 1, 5000, 15000, 1000) end, "side_plus")
    SafeHandler(UIX.controls.uiRefresh.minus, "OnClick", function() AdjustConfigValue("uiRefreshMs", -1, 250, 2000, 250) end, "ui_minus")
    SafeHandler(UIX.controls.uiRefresh.plus, "OnClick", function() AdjustConfigValue("uiRefreshMs", 1, 250, 2000, 250) end, "ui_plus")
    SafeHandler(UIX.controls.rosterRefresh.minus, "OnClick", function() AdjustConfigValue("rosterScanMs", -1, 500, 5000, 500) end, "roster_minus")
    SafeHandler(UIX.controls.rosterRefresh.plus, "OnClick", function() AdjustConfigValue("rosterScanMs", 1, 500, 5000, 500) end, "roster_plus")
    SafeHandler(UIX.controls.rawLimit.minus, "OnClick", function() AdjustConfigValue("rawEventLimit", -1, 100, C.MAX_RAW_EVENTS, 100) end, "raw_minus")
    SafeHandler(UIX.controls.rawLimit.plus, "OnClick", function() AdjustConfigValue("rawEventLimit", 1, 100, C.MAX_RAW_EVENTS, 100) end, "raw_plus")
    SafeHandler(UIX.controls.diagEnabled, "OnClick", function() UIX:ToggleSetting("diagnosticsEnabled") end, "diag_enabled")

    SafeHandler(UIX.controls.diagRebuild, "OnClick", function() UIX:RepairHudFromSettings() end, "diag_rebuild")
    SafeHandler(UIX.controls.diagSave, "OnClick", function() UIX:SaveNowFromSettings() end, "diag_save")
    SafeHandler(UIX.controls.diagRescan, "OnClick", function()
        -- Diagnostics first: the scan replays pending and would mask the very
        -- counters that identify where team data is being dropped.
        UIX:PrintDiagnosticsToChat()
        UIX:RescanNowFromSettings()
    end, "diag_rescan")
    SafeHandler(UIX.controls.diagShardAudit, "OnClick", function()
        local ok, result = PersistenceSwitch:BeginSafetyAudit("UI_MANUAL")
        if ok then
            D.Boot.SafeChat("已启动分片安全检查；结果将在诊断页持续更新。")
        else
            D.Boot.SafeChat("分片安全检查未启动：" .. tostring(result or "当前已有任务"))
        end
        UIX:RefreshConfig()
    end, "diag_shard_audit")
    SafeHandler(UIX.controls.diagShardClear, "OnClick", function()
        local ok, state = PersistenceSwitch:RequestClearShardStorage()
        if ok then
            D.Boot.SafeChat("已开始分帧清理分片缓存；rotating 主/备份不会删除。")
        elseif state == "CONFIRM_AGAIN" then
            D.Boot.SafeChat("危险操作：8 秒内再次点击“清理分片缓存”确认。")
        else
            D.Boot.SafeChat("无法清理分片缓存：" .. tostring(state or "未知原因"))
        end
        UIX:RefreshConfig()
    end, "diag_shard_clear")
    end -- legacy standalone config handlers
end

local function InitializeShell()
    CreateFriendlyWindow()
    CreateEnemyWindow()
    EnsurePrintButtons()
    EnsurePrintChooser()
    -- In Suite mode the right-hand Suite page is the settings surface. The
    -- historical standalone config window is deliberately not allocated.
    if ReplicatedSuiteEmbedded ~= true then CreateConfigWindow() end
    CreateConfirmWindow()
    CreateDetailWindow()
    EnsureDetailBackButton()
    EnsureDetailAnalysisButtons()
    EnsureDetailRowsInteractive()
    InstallHandlers()
    if ReplicatedSuiteEmbedded ~= true then UIX:SetConfigPage(1) end
    UIX:LayoutAll()
    UIX:ApplyVisibility()
    UIX:RefreshControls()
    UIX:RefreshConfig()
    Boot.openSettings = function() return UIX:ToggleConfig() end
    UIX.shellCommitted = true
    UIX.shellSchema = UI_SHELL_SCHEMA
    D.Runtime.uiReady = true
end

local function ReuseShell()
    EnsurePrintButtons()
    EnsurePrintChooser()
    EnsureDetailBackButton()
    EnsureDetailAnalysisButtons()
    EnsureDetailRowsInteractive()
    InstallHandlers()
    Boot.openSettings = function() UIX:ToggleConfig() end
    UIX:SetConfigPage(UIX.activeConfigPage or 1)
    UIX:LayoutAll()
    UIX:ApplyVisibility()
    UIX:RefreshControls()
    UIX:RefreshConfig()
    D.Runtime.uiReady = true
end

local initializer = InitializeShell
if UIX.shellCommitted == true and tonumber(UIX.shellSchema) == UI_SHELL_SCHEMA
    and UIX.windows.friendly ~= nil and UIX.windows.enemy ~= nil and UIX.windows.detail ~= nil
    and (ReplicatedSuiteEmbedded == true or UIX.windows.config ~= nil) then
    initializer = ReuseShell
end

local ok, err = xpcall(initializer, Boot.SafeTraceback)
if not ok then
    for _, window in pairs(UIX.windows) do pcall(function() window:Show(false) end) end
    -- The engine does not expose a reliable destroy-widget API. Mark the
    -- partial shell as abandoned; the next script generation creates a new
    -- physical ID namespace while preserving the single bootstrap launcher.
    UIX.needsRecovery = true
    UIX.shellCommitted = false
    Boot:Fail("ui_shell", err)
    return
end

Boot:CompletePhase("SHELL_READY")
D.Diagnostics.status = "SHELL_READY"
