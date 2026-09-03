------------------------------------------------------------------------
-- Replicated Suite - UI Framework v8
--
-- Incremental upper layer over the limited ArcheAge/RU native UI API.
--
-- Authority rules:
--   * Native widgets remain render objects only; business state never lives here.
--   * DiffRenderer owns cached presentation state for migrated fields.
--   * Lifecycle owns handler release / hide / logical-reference cleanup.  The RU
--     API has no validated generic DestroyWidget operation, so release MUST NOT
--     pretend that a native widget can be safely destroyed.
--   * Hot-path diagnostics are cheap counters only; no log formatting happens
--     on every UI write.
------------------------------------------------------------------------

if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI = S.UI
if type(UI) ~= "table" then return end

local FRAMEWORK_VERSION = 8
local MAX_OWNER_METRICS = 48

local stateCache = setmetatable({}, { __mode = "k" })
local authorityClaims = setmetatable({}, { __mode = "k" })
local geometryLeases = setmetatable({}, { __mode = "k" })
local lifecycle = { owners = {} }

local metrics = {
    attempts = 0,
    writes = 0,
    skips = 0,
    nativeCalls = 0,
    cacheRepairs = 0,
    cacheRepairsByField = {},
    cacheRepairsByOwner = {},
    authority = { claims = 0, conflicts = 0, violations = 0, strictRepairs = 0, byOwner = {}, byField = {} },
    geometryLease = { begins = 0, ends = 0, deferredAnchors = 0, deferredExtents = 0, conflicts = 0 },
    nativeSafety = { staleRejects = 0, registrationRejects = 0, degradedRejects = 0, callFailures = 0, anchorParentRepairs = 0 },
    byOp = {},
    byOwner = {},
    ownerOrder = {},
    lifecycle = {
        adopted = 0,
        handlerBindings = 0,
        releasedOwners = 0,
        releasedHandlers = 0,
        hiddenOnRelease = 0,
    },
}

UI.FrameworkVersion = FRAMEWORK_VERSION
UI.Tokens = S.UITokens
UI.NativeStateCache = stateCache
UI.NativeAuthorityClaims = authorityClaims
UI.NativeGeometryLeases = geometryLeases
UI.Lifecycle = lifecycle
UI.FrameworkMetrics = metrics

local function NormalizeOwner(value)
    local owner = tostring(value or "")
    owner = owner:gsub("[\r\n]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if owner == "" then owner = "suite" end
    if #owner > 64 then owner = owner:sub(1, 64) end
    return owner
end

local function OwnerOf(widget, explicitOwner)
    if explicitOwner ~= nil then return NormalizeOwner(explicitOwner) end
    if widget ~= nil then
        if widget.rsUiOwner ~= nil then return NormalizeOwner(widget.rsUiOwner) end
        if widget.rsHudOwner ~= nil then return NormalizeOwner("hud:" .. tostring(widget.rsHudOwner)) end
    end
    return "suite"
end

local function GetState(widget)
    if widget == nil then return nil end
    local row = stateCache[widget]
    if row == nil then
        row = {}
        stateCache[widget] = row
    end
    return row
end

local function WidgetUsable(widget)
    if widget == nil then return false, "nil_widget" end
    if widget.rsUiRegistrationRejected == true then
        metrics.nativeSafety.registrationRejects = (tonumber(metrics.nativeSafety.registrationRejects) or 0) + 1
        return false, "registration_rejected"
    end
    if widget.rsUiDegraded == true then
        metrics.nativeSafety.degradedRejects = (tonumber(metrics.nativeSafety.degradedRejects) or 0) + 1
        return false, "primitive_degraded"
    end
    local nativeGeneration = tonumber(widget.rsNativeGeneration)
    if nativeGeneration ~= nil and nativeGeneration ~= tonumber(S.Generation) then
        metrics.nativeSafety.staleRejects = (tonumber(metrics.nativeSafety.staleRejects) or 0) + 1
        return false, "stale_generation:" .. tostring(nativeGeneration) .. "!=" .. tostring(S.Generation)
    end
    return true
end

local function ResolveAnchorParent(parent)
    -- UIParent is a special root identity in the ArcheAge native API.  Keep the
    -- logical/cache side as the real UIParent object so effective-offset checks
    -- still work, but never let the literal string drift into cache authority.
    if parent == "UIParent" and UIParent ~= nil then return UIParent end
    local rsui = S.RSUI
    if type(rsui) == "table" and type(rsui.IsComponent) == "function" and rsui:IsComponent(parent) then
        local native = type(rsui.ResolveParent) == "function" and select(1, rsui:ResolveParent(parent)) or nil
        if native ~= nil then
            metrics.nativeSafety.anchorParentRepairs = (tonumber(metrics.nativeSafety.anchorParentRepairs) or 0) + 1
            return native
        end
    end
    return parent
end

local function ResolveNativeAnchorTarget(parent)
    -- RU root widgets (Window / top-level Button) accept "UIParent" as the
    -- root anchor identity. Passing the UIParent userdata can return success but
    -- leave the widget at its native creation origin (0,0), after which the diff
    -- cache incorrectly believes the requested position was applied.
    if parent == UIParent or parent == "UIParent" then return "UIParent" end
    return parent
end

function UI:ResolveNativeAnchorTarget(parent)
    local logicalParent = ResolveAnchorParent(parent)
    return ResolveNativeAnchorTarget(logicalParent), logicalParent
end

local function RecordNativeSafetyFailure(op, widget, detail, owner)
    metrics.nativeSafety.callFailures = (tonumber(metrics.nativeSafety.callFailures) or 0) + 1
    local logical = widget and (widget.rsNativeLogicalId or widget.rsUiLogicalId) or "?"
    local message = tostring(op or "native_call") .. ":" .. tostring(logical) .. ":" .. tostring(detail or "failed")
    if type(S.RecordLog) == "function" then S.RecordLog("error", "ui_native_safety", message) end
    local diagnostics = S.DiagnosticsManager
    if type(diagnostics) == "table" and type(diagnostics.Emit) == "function" then
        diagnostics:Emit("error", "ui_native_safety", "NATIVE_UI_CALL_REJECTED", "原生界面写入已被安全拒绝", {
            op = tostring(op or ""), logicalId = tostring(logical or ""), detail = tostring(detail or ""), owner = OwnerOf(widget, owner),
        })
    end
end

function UI:IsWidgetUsable(widget)
    return WidgetUsable(widget)
end

local function TouchOwnerMetric(owner)
    local row = metrics.byOwner[owner]
    if row ~= nil then return row end

    -- Keep owner cardinality bounded.  "other" is intentionally a hot-path
    -- fallback rather than evicting arbitrary rows while the UI is refreshing.
    if #metrics.ownerOrder >= MAX_OWNER_METRICS then
        owner = "other"
        row = metrics.byOwner[owner]
        if row ~= nil then return row end
    else
        metrics.ownerOrder[#metrics.ownerOrder + 1] = owner
    end

    row = { attempts = 0, writes = 0, skips = 0, nativeCalls = 0 }
    metrics.byOwner[owner] = row
    return row
end

local function RecordAttempt(op, widget, changed, nativeCalls, explicitOwner)
    op = tostring(op or "UNKNOWN")
    nativeCalls = math.max(0, math.floor(tonumber(nativeCalls) or 0))

    metrics.attempts = metrics.attempts + 1
    if changed == true then metrics.writes = metrics.writes + 1 else metrics.skips = metrics.skips + 1 end
    metrics.nativeCalls = metrics.nativeCalls + nativeCalls

    local opRow = metrics.byOp[op]
    if opRow == nil then
        opRow = { attempts = 0, writes = 0, skips = 0, nativeCalls = 0 }
        metrics.byOp[op] = opRow
    end
    opRow.attempts = opRow.attempts + 1
    if changed == true then opRow.writes = opRow.writes + 1 else opRow.skips = opRow.skips + 1 end
    opRow.nativeCalls = opRow.nativeCalls + nativeCalls

    local ownerRow = TouchOwnerMetric(OwnerOf(widget, explicitOwner))
    ownerRow.attempts = ownerRow.attempts + 1
    if changed == true then ownerRow.writes = ownerRow.writes + 1 else ownerRow.skips = ownerRow.skips + 1 end
    ownerRow.nativeCalls = ownerRow.nativeCalls + nativeCalls
end


local function TryNativeText(widget)
    if widget == nil or type(widget.GetText) ~= "function" then return nil, false end
    local ok, value = pcall(function() return widget:GetText() end)
    if not ok then return nil, false end
    return tostring(value or ""), true
end

local function TryNativeExtent(widget)
    if widget == nil or type(widget.GetWidth) ~= "function" or type(widget.GetHeight) ~= "function" then return nil, nil, false end
    local okW, width = pcall(function() return widget:GetWidth() end)
    local okH, height = pcall(function() return widget:GetHeight() end)
    if not okW or not okH then return nil, nil, false end
    width, height = tonumber(width), tonumber(height)
    if width == nil or height == nil then return nil, nil, false end
    return width, height, true
end

local function HasKnownHiddenAncestor(widget)
    local parent = widget and widget.rsUiParent or nil
    local guard = 0
    while parent ~= nil and parent ~= UIParent and guard < 32 do
        guard = guard + 1
        local parentState = stateCache[parent]
        if parentState ~= nil and parentState.visible == false then return true end
        parent = parent.rsUiParent
    end
    return false
end

local function TryNativeVisible(widget)
    if widget == nil or type(widget.IsVisible) ~= "function" then return nil, false end
    local ok, value = pcall(function() return widget:IsVisible() end)
    if not ok then return nil, false end
    -- On RU builds IsVisible() may report EFFECTIVE visibility. A locally shown
    -- child under a hidden V3 shell then returns false even though its own Show
    -- state is correct. Treat that case as unverifiable instead of generating a
    -- false strict-authority violation. Geometry remains fully verifiable.
    if value ~= true and HasKnownHiddenAncestor(widget) then return nil, false end
    return value == true, true
end

local function TryNativeAnchorMatches(widget, parent, x, y)
    if widget == nil or parent == nil then return nil, false end
    local parentState = stateCache[parent]
    if HasKnownHiddenAncestor(widget) or (parentState ~= nil and parentState.visible == false) then
        -- Effective offsets are not a reliable local-anchor probe while an
        -- ancestor is hidden on RU clients; defer verification until visible.
        return nil, false
    end
    if type(widget.GetEffectiveOffset) ~= "function" or type(parent.GetEffectiveOffset) ~= "function" then return nil, false end
    local okWidget, wx, wy = pcall(function() return widget:GetEffectiveOffset() end)
    local okParent, px, py = pcall(function() return parent:GetEffectiveOffset() end)
    wx, wy, px, py = tonumber(wx), tonumber(wy), tonumber(px), tonumber(py)
    if not okWidget or not okParent or wx == nil or wy == nil or px == nil or py == nil then return nil, false end
    local ax, ay = tonumber(x) or 0, tonumber(y) or 0
    local scale = 1
    if S.Layout ~= nil and type(S.Layout.GetContext) == "function" then
        local ok, context = pcall(function() return S.Layout:GetContext() end)
        -- SetAnchor receives logical coordinates that already include the
        -- Suite addonScale chosen by layout. Native getters may additionally
        -- expose the client's UI scale. Multiplying by addonScale a second time
        -- produced thousands of false strict-authority repairs when uiScale != 1.
        if ok and type(context) == "table" then scale = math.max(0.01, tonumber(context.uiScale) or 1) end
    end
    -- RU builds have returned effective offsets in both logical and native
    -- UI-scaled spaces. Accept either coordinate contract here; strict V3
    -- ownership is enforced by the writer fence, not by double-applying the
    -- Suite's addonScale to a value that is already laid out.
    local epsilon = math.max(1.0, scale)
    local rawMatch = math.abs(wx - (px + ax)) <= epsilon and math.abs(wy - (py + ay)) <= epsilon
    local scaledMatch = math.abs(wx - (px + ax * scale)) <= epsilon and math.abs(wy - (py + ay * scale)) <= epsilon
    return rawMatch or scaledMatch, true
end

local function RecordCacheRepair(kind, widget, explicitOwner)
    kind = tostring(kind or "unknown")
    metrics.cacheRepairs = (tonumber(metrics.cacheRepairs) or 0) + 1
    metrics.cacheRepairsByField[kind] = (tonumber(metrics.cacheRepairsByField[kind]) or 0) + 1
    local owner = OwnerOf(widget, explicitOwner)
    if metrics.byOwner[owner] == nil and #metrics.ownerOrder >= MAX_OWNER_METRICS then owner = "other" end
    metrics.cacheRepairsByOwner[owner] = (tonumber(metrics.cacheRepairsByOwner[owner]) or 0) + 1

    local claim = authorityClaims[widget]
    if type(claim) == "table" and claim.mode == "strict" then
        metrics.authority.violations = (tonumber(metrics.authority.violations) or 0) + 1
        metrics.authority.strictRepairs = (tonumber(metrics.authority.strictRepairs) or 0) + 1
        local claimOwner = tostring(claim.owner or owner)
        metrics.authority.byOwner[claimOwner] = (tonumber(metrics.authority.byOwner[claimOwner]) or 0) + 1
        metrics.authority.byField[kind] = (tonumber(metrics.authority.byField[kind]) or 0) + 1
        local d = S.DiagnosticsManager
        if type(d) == "table" and type(d.WarnRateLimited) == "function" then
            d:WarnRateLimited("ui_v3", "AUTHORITY_VIOLATION", 3000, "V3 Native 状态被 Diff Authority 之外的代码修改", {
                owner = claimOwner, field = kind, logicalId = widget and widget.rsUiLogicalId or nil,
            })
        end
    end
end

local function RepairCachedField(row, field, value)
    if row == nil then return end
    row[field] = value
end

local function SameAnchor(row, parent, x, y)
    if row == nil then return false end
    if row.anchorParent ~= nil or row.anchorX ~= nil or row.anchorY ~= nil then
        return row.anchorParent == parent and row.anchorX == x and row.anchorY == y
    end
    -- Compatibility with widgets primed by UI Factory v1.  Once the anchor is
    -- touched through DiffRenderer we migrate to scalar fields so hot HUDs do
    -- not allocate a table every time their screen position changes.
    local legacy = row.anchorTopLeft
    return type(legacy) == "table" and legacy.parent == parent and legacy.x == x and legacy.y == y
end

function UI:PrimeNativeState(widget, values)
    if widget == nil or type(values) ~= "table" then return false end
    local row = GetState(widget)
    for key, value in pairs(values) do row[key] = value end
    return true
end

-- Call this whenever legacy code must write a field directly on a widget that is
-- otherwise managed by DiffRenderer.  During migration it is preferable to
-- invalidate one field rather than clearing every cached presentation value.
function UI:InvalidateNativeState(widget, field)
    if widget == nil then return false end
    if field == nil then
        stateCache[widget] = nil
        return true
    end
    local row = stateCache[widget]
    if row ~= nil then row[tostring(field)] = nil end
    return true
end

-- V3 Native Authority contract. Legacy widgets may coexist during migration,
-- but a strict claim means DiffRenderer is the sole presentation writer. Any
-- later cache repair on that widget is a hard architecture violation.
function UI:ClaimNativeAuthority(widget, owner, mode)
    if widget == nil then return false, "widget required" end
    owner = NormalizeOwner(owner)
    mode = tostring(mode or "strict"):lower()
    if mode ~= "strict" and mode ~= "legacy" then return false, "invalid authority mode" end
    local current = authorityClaims[widget]
    if current ~= nil and tostring(current.owner) ~= owner then
        metrics.authority.conflicts = (tonumber(metrics.authority.conflicts) or 0) + 1
        metrics.authority.violations = (tonumber(metrics.authority.violations) or 0) + 1
        local d = S.DiagnosticsManager
        if type(d) == "table" and type(d.Warn) == "function" then
            d:Warn("ui_v3", "AUTHORITY_CONFLICT", "Native Widget Geometry Authority 冲突", {
                currentOwner = current.owner, requestedOwner = owner, logicalId = widget.rsUiLogicalId,
            })
        end
        return false, "authority conflict"
    end
    if current == nil then metrics.authority.claims = (tonumber(metrics.authority.claims) or 0) + 1 end
    authorityClaims[widget] = { owner = owner, mode = mode }
    widget.rsUiOwner = owner
    widget.rsUiAuthorityMode = mode
    return true
end

function UI:GetNativeAuthority(widget)
    return widget and authorityClaims[widget] or nil
end

function UI:ReleaseNativeAuthority(widget, owner)
    if widget == nil then return false end
    local current = authorityClaims[widget]
    if current == nil then return true end
    if owner ~= nil and NormalizeOwner(owner) ~= tostring(current.owner) then return false, "owner mismatch" end
    authorityClaims[widget] = nil
    widget.rsUiAuthorityMode = nil
    return true
end

function UI:AdoptV3Widget(widget, owner, logicalId)
    owner = NormalizeOwner(owner or "v3")
    local claimed, err = self:ClaimNativeAuthority(widget, owner, "strict")
    if not claimed then return false, err end
    return self:AdoptWidget(widget, owner, logicalId)
end

function UI:GetAuthoritySnapshot()
    local byOwner = {}
    for owner, count in pairs(metrics.authority.byOwner or {}) do byOwner[#byOwner + 1] = { owner=owner, violations=tonumber(count) or 0 } end
    table.sort(byOwner, function(a,b) if a.violations == b.violations then return a.owner < b.owner end return a.violations > b.violations end)
    return {
        claims = tonumber(metrics.authority.claims) or 0,
        conflicts = tonumber(metrics.authority.conflicts) or 0,
        violations = tonumber(metrics.authority.violations) or 0,
        strictRepairs = tonumber(metrics.authority.strictRepairs) or 0,
        liveClaims = (function() local count=0; for _ in pairs(authorityClaims) do count=count+1 end; return count end)(),
        byOwner = byOwner,
        byField = (function()
            local out = {}
            for field, count in pairs(metrics.authority.byField or {}) do out[field] = tonumber(count) or 0 end
            return out
        end)(),
    }
end

function UI:SetText(widget, value, owner)
    local usable = WidgetUsable(widget)
    if usable ~= true or type(widget.SetText) ~= "function" then return false end
    local text = tostring(value or "")
    local row = GetState(widget)
    if row.text == text then
        -- Legacy pages may still mutate native labels directly. Verify only on
        -- the cache-hit path so normal writes stay allocation-free and cheap.
        local nativeText, known = TryNativeText(widget)
        if not known or nativeText == text then
            RecordAttempt("SET_TEXT", widget, false, 0, owner)
            return false
        end
        RepairCachedField(row, "text", nativeText)
        RecordCacheRepair("text", widget, owner)
    end
    local ok, err = pcall(function() widget:SetText(text) end)
    if ok ~= true then RecordNativeSafetyFailure("SET_TEXT", widget, err, owner); return false end
    row.text = text
    RecordAttempt("SET_TEXT", widget, true, 1, owner)
    return true
end

function UI:SetVisible(widget, visible, owner)
    local usable = WidgetUsable(widget)
    if usable ~= true then return false end
    local preferSetVisible = widget.rsUiVisibilityMethod == "SetVisible"
    local hasShow = type(widget.Show) == "function"
    local hasSetVisible = type(widget.SetVisible) == "function"
    if not hasShow and not hasSetVisible then return false end

    local value = visible == true
    local row = GetState(widget)
    if row.visible == value then
        local nativeVisible, known = TryNativeVisible(widget)
        if not known or nativeVisible == value then
            RecordAttempt("SHOW", widget, false, 0, owner)
            return false
        end
        RepairCachedField(row, "visible", nativeVisible)
        RecordCacheRepair("visible", widget, owner)
    end

    local nativeCalls = math.max(1, math.floor(tonumber(widget.rsUiVisibilityNativeCalls) or 1))
    local ok, err = pcall(function()
        if preferSetVisible and hasSetVisible then
            widget:SetVisible(value)
        elseif hasShow then
            widget:Show(value)
        else
            widget:SetVisible(value)
        end
    end)
    if ok ~= true then RecordNativeSafetyFailure("SHOW", widget, err, owner); return false end
    row.visible = value
    RecordAttempt("SHOW", widget, true, nativeCalls, owner)
    return true
end

-- Generic color diff for native drawables, text styles and small composite
-- adapters that expose SetColor(r,g,b,a).  Keeping this in the framework is
-- important for high-frequency HUDs such as Healer markers: color animation
-- may legitimately repaint, while static states should produce zero native
-- writes after the first application.
function UI:SetColor(widget, red, green, blue, alpha, owner)
    local usable = WidgetUsable(widget)
    if usable ~= true or type(widget.SetColor) ~= "function" then return false end
    local r = tonumber(red) or 0
    local g = tonumber(green) or 0
    local b = tonumber(blue) or 0
    local a = tonumber(alpha) or 1
    local row = GetState(widget)
    local sameColor = row.colorR == r and row.colorG == g and row.colorB == b and row.colorA == a
    if not sameColor and row.colorR == nil then
        -- Compatibility with early v1 callers that primed a compact array.
        local legacy = row.color
        sameColor = type(legacy) == "table" and legacy[1] == r and legacy[2] == g and legacy[3] == b and legacy[4] == a
    end
    if sameColor then
        RecordAttempt("SET_COLOR", widget, false, 0, owner)
        return false
    end
    local ok, err = pcall(function() widget:SetColor(r, g, b, a) end)
    if ok ~= true then RecordNativeSafetyFailure("SET_COLOR", widget, err, owner); return false end
    row.colorR, row.colorG, row.colorB, row.colorA = r, g, b, a
    row.color = nil
    RecordAttempt("SET_COLOR", widget, true, math.max(1, math.floor(tonumber(widget.rsUiColorNativeCalls) or 1)), owner)
    return true
end

-- Icon drawables in RU expose ClearAllTextures/AddTexture rather than a
-- universal SetTexture contract. Cache the path here so HUD/list components can
-- refresh the same icon snapshot without repeated native texture writes.
function UI:SetIconTexture(drawable, path, owner)
    if drawable == nil then return false end
    local value = tostring(path or "")
    local row = GetState(drawable)
    if row.iconTexture == value then RecordAttempt("ICON_TEXTURE", drawable, false, 0, owner); return false end
    local calls = 0
    if type(drawable.ClearAllTextures) == "function" then
        local ok = pcall(function() drawable:ClearAllTextures() end)
        if not ok then return false end
        calls = calls + 1
    end
    if value ~= "" then
        if type(drawable.AddTexture) ~= "function" then return false end
        local ok = pcall(function() drawable:AddTexture(value) end)
        if not ok then return false end
        calls = calls + 1
    end
    if calls == 0 then return false end
    row.iconTexture = value
    RecordAttempt("ICON_TEXTURE", drawable, true, calls, owner)
    return true
end


-- Native interaction geometry lease. During StartMoving/StartSizing the client
-- temporarily owns the top-level window geometry so the strict diff renderer
-- must not immediately write the pre-gesture anchor/extent back. The lease is
-- deliberately narrow: only SetAnchor/SetExtent are deferred, all other V3
-- presentation fields remain under normal strict authority.
function UI:BeginNativeGeometryLease(widget, owner, reason)
    if widget == nil then return false, "widget required" end
    local normalizedOwner = NormalizeOwner(owner)
    local claim = authorityClaims[widget]
    if claim ~= nil and tostring(claim.owner) ~= normalizedOwner then
        metrics.geometryLease.conflicts = (tonumber(metrics.geometryLease.conflicts) or 0) + 1
        return false, "authority owner mismatch"
    end
    local current = geometryLeases[widget]
    if current ~= nil and tostring(current.owner) ~= normalizedOwner then
        metrics.geometryLease.conflicts = (tonumber(metrics.geometryLease.conflicts) or 0) + 1
        return false, "geometry lease conflict"
    end
    geometryLeases[widget] = { owner = normalizedOwner, reason = tostring(reason or "native_interaction") }
    metrics.geometryLease.begins = (tonumber(metrics.geometryLease.begins) or 0) + 1
    return true
end

function UI:EndNativeGeometryLease(widget, owner)
    if widget == nil then return false end
    local current = geometryLeases[widget]
    if current == nil then return true end
    if owner ~= nil and NormalizeOwner(owner) ~= tostring(current.owner) then
        metrics.geometryLease.conflicts = (tonumber(metrics.geometryLease.conflicts) or 0) + 1
        return false, "geometry lease owner mismatch"
    end
    geometryLeases[widget] = nil
    -- Native movement has changed the physical state behind the diff cache. The
    -- next committed V3 write must re-prime from the final native rectangle.
    self:InvalidateNativeState(widget)
    metrics.geometryLease.ends = (tonumber(metrics.geometryLease.ends) or 0) + 1
    return true
end

function UI:GetNativeGeometryLease(widget)
    return widget and geometryLeases[widget] or nil
end

local function GeometryWriteDeferred(widget, owner, field)
    local lease = widget and geometryLeases[widget] or nil
    if lease == nil then return false end
    if owner ~= nil and NormalizeOwner(owner) ~= tostring(lease.owner) then
        metrics.geometryLease.conflicts = (tonumber(metrics.geometryLease.conflicts) or 0) + 1
    end
    if field == "anchor" then
        metrics.geometryLease.deferredAnchors = (tonumber(metrics.geometryLease.deferredAnchors) or 0) + 1
    else
        metrics.geometryLease.deferredExtents = (tonumber(metrics.geometryLease.deferredExtents) or 0) + 1
    end
    return true
end

local function RefreshCompositeExtent(widget)
    if widget == nil then return false end
    -- Custom horizontal sliders own child geometry (rail/thumb/drag surface).
    -- A Native root SetExtent therefore is not a complete layout transaction.
    -- Keep this hook centralized so both RSUI Slider and older framework fields
    -- receive identical resize semantics, including after a code hot-reload.
    if widget.rsCustomHorizontal == true and type(UI.UpdateSliderVisual) == "function" then
        local ok, changed = pcall(function() return UI:UpdateSliderVisual(widget, widget.rsValue) end)
        return ok == true and changed == true
    end
    return false
end

function UI:SetExtent(widget, width, height, owner)
    local usable = WidgetUsable(widget)
    if usable ~= true or type(widget.SetExtent) ~= "function" then return false end
    if GeometryWriteDeferred(widget, owner, "extent") then RecordAttempt("SET_EXTENT", widget, false, 0, owner); return false end
    local w = math.max(1, tonumber(width) or 1)
    local h = math.max(1, tonumber(height) or 1)
    local row = GetState(widget)
    if row.width == w and row.height == h then
        local nativeW, nativeH, known = TryNativeExtent(widget)
        local scale = 1
        if S.Layout ~= nil and type(S.Layout.GetContext) == "function" then
            local ok, context = pcall(function() return S.Layout:GetContext() end)
            -- Width/height passed into SetExtent are already Suite logical
            -- coordinates (including addonScale). Native getters may return the
            -- same logical extent or that extent multiplied by the client
            -- UI:GetUIScale value. addonScale must not be applied twice.
            if ok and type(context) == "table" then scale = math.max(0.01, tonumber(context.uiScale) or 1) end
        end
        -- RU clients have exposed GetWidth/GetHeight in both logical space and
        -- client-UI-scaled physical space. Either getter contract is valid.
        -- Comparing against addonScale here used to report an external writer on
        -- almost every layout cache hit whenever UI scale differed from 1.0.
        local epsilon = math.max(0.75, scale)
        local rawMatch = known and math.abs(nativeW - w) <= epsilon and math.abs(nativeH - h) <= epsilon
        local scaledMatch = known and math.abs(nativeW - w * scale) <= epsilon and math.abs(nativeH - h * scale) <= epsilon
        if not known or rawMatch or scaledMatch then
            RefreshCompositeExtent(widget)
            RecordAttempt("SET_EXTENT", widget, false, 0, owner)
            return false
        end
        -- Do not copy an unknown native unit-space back into the logical cache.
        -- The authoritative write below restores the requested logical extent.
        RecordCacheRepair("extent", widget, owner)
    end
    local ok, err = pcall(function() widget:SetExtent(w, h) end)
    if ok ~= true then RecordNativeSafetyFailure("SET_EXTENT", widget, err, owner); return false end
    row.width, row.height = w, h
    RefreshCompositeExtent(widget)
    RecordAttempt("SET_EXTENT", widget, true, 1, owner)
    return true
end

function UI:SetAnchor(widget, parent, x, y, owner)
    local usable = WidgetUsable(widget)
    if usable ~= true or type(widget.AddAnchor) ~= "function" then return false end
    local nativeParent
    nativeParent, parent = self:ResolveNativeAnchorTarget(parent)
    if parent == nil or nativeParent == nil then RecordNativeSafetyFailure("SET_ANCHOR", widget, "parent_required", owner); return false end
    if GeometryWriteDeferred(widget, owner, "anchor") then RecordAttempt("SET_ANCHOR", widget, false, 0, owner); return false end
    local ax, ay = tonumber(x) or 0, tonumber(y) or 0
    local row = GetState(widget)
    if SameAnchor(row, parent, ax, ay) then
        local nativeMatches, known = TryNativeAnchorMatches(widget, parent, ax, ay)
        if not known or nativeMatches == true then
            RecordAttempt("SET_ANCHOR", widget, false, 0, owner)
            return false
        end
        RecordCacheRepair("anchor", widget, owner)
    end
    local nativeCalls = 0
    if type(widget.RemoveAllAnchors) == "function" then
        local removeOk, removeErr = pcall(function() widget:RemoveAllAnchors() end)
        if removeOk ~= true then RecordNativeSafetyFailure("REMOVE_ANCHORS", widget, removeErr, owner); return false end
        nativeCalls = nativeCalls + 1
    end
    local anchorOk, anchorErr = pcall(function() widget:AddAnchor("TOPLEFT", nativeParent, ax, ay) end)
    if anchorOk ~= true then
        RecordNativeSafetyFailure("SET_ANCHOR", widget, anchorErr, owner)
        return false
    end
    nativeCalls = nativeCalls + 1
    row.anchorParent, row.anchorX, row.anchorY = parent, ax, ay
    row.anchorTopLeft = nil
    RecordAttempt("SET_ANCHOR", widget, true, nativeCalls, owner)
    return true
end

-- Screen Snap Adapter -------------------------------------------------------
--
-- Top-level controls should not duplicate sibling discovery or geometry math.
-- Persistence remains owned by the feature/domain; this adapter only registers
-- visible screen controls and commits a snap result through the normal diff
-- renderer so UIParent root-anchor semantics stay centralized.
function UI:RegisterScreenSnap(id, widget, options)
    if S.Layout == nil or type(S.Layout.RegisterScreenSnap) ~= "function" or widget == nil then return false end
    options = type(options) == "table" and options or {}
    local normalized = {}
    for key, value in pairs(options) do normalized[key] = value end
    normalized.snapGroup = tostring(options.snapGroup or "screen_controls")
    normalized.snapKind = tostring(options.snapKind or "button")
    if normalized.ensureNow == nil then normalized.ensureNow = false end
    return S.Layout:RegisterScreenSnap(tostring(id or ""), widget, normalized)
end

function UI:UnregisterScreenSnap(id)
    if S.Layout == nil or type(S.Layout.UnregisterScreenSnap) ~= "function" then return false end
    S.Layout:UnregisterScreenSnap(tostring(id or ""))
    return true
end

function UI:ResolveScreenSnap(id, x, y, width, height, options)
    if S.Layout == nil or type(S.Layout.ResolveScreenSnap) ~= "function" then return x, y, false, nil end
    return S.Layout:ResolveScreenSnap(tostring(id or ""), x, y, width, height, options)
end

function UI:CommitScreenSnap(id, widget, options)
    options = type(options) == "table" and options or {}
    if widget == nil or S.Layout == nil or type(S.Layout.GetLogicalRect) ~= "function" then return false, nil, nil, false, nil end
    local x, y, width, height = S.Layout:GetLogicalRect(widget)
    if tonumber(x) == nil or tonumber(y) == nil then return false, x, y, false, nil end
    local sx, sy, snapped, targetId = self:ResolveScreenSnap(id, x, y, width, height, options)
    if snapped == true then
        self:SetAnchor(widget, UIParent, sx, sy, options.owner or "screen_snap")
        x, y = sx, sy
    end
    return true, x, y, snapped == true, targetId
end

function UI:GetScreenSnapSnapshot()
    if S.Layout ~= nil and type(S.Layout.GetScreenSnapSnapshot) == "function" then return S.Layout:GetScreenSnapSnapshot() end
    return { version = 1, registered = 0, visible = 0, resolves = 0, snaps = 0, candidates = 0 }
end

function UI:SetEnabled(widget, enabled, owner)
    local usable = WidgetUsable(widget)
    if usable ~= true then return false end
    local hasEnable = type(widget.Enable) == "function"
    local hasSetEnabled = type(widget.SetEnabled) == "function"
    if not hasEnable and not hasSetEnabled then return false end
    local value = enabled ~= false
    local row = GetState(widget)
    if row.enabled == value then RecordAttempt("ENABLE", widget, false, 0, owner); return false end
    local ok, err = pcall(function() if hasEnable then widget:Enable(value) else widget:SetEnabled(value) end end)
    if ok ~= true then RecordNativeSafetyFailure("ENABLE", widget, err, owner); return false end
    row.enabled = value
    RecordAttempt("ENABLE", widget, true, 1, owner)
    return true
end

function UI:SetPickable(widget, enabled, owner)
    local usable = WidgetUsable(widget)
    if usable ~= true then return false end
    local value = enabled == true
    local row = GetState(widget)
    if row.pickable == value then RecordAttempt("PICKABLE", widget, false, 0, owner); return false end

    local calls = 0
    if type(widget.EnablePick) == "function" then
        local ok, err = pcall(function() widget:EnablePick(value) end)
        if ok ~= true then RecordNativeSafetyFailure("ENABLE_PICK", widget, err, owner); return false end
        calls = calls + 1
    end
    if type(widget.Clickable) == "function" then
        local ok, err = pcall(function() widget:Clickable(value) end)
        if ok ~= true then RecordNativeSafetyFailure("CLICKABLE", widget, err, owner); return false end
        calls = calls + 1
    end
    row.pickable = value
    RecordAttempt("PICKABLE", widget, true, calls, owner)
    return calls > 0
end

function UI:SetFontSize(widget, size, owner)
    local usable = WidgetUsable(widget)
    if usable ~= true or widget.style == nil or type(widget.style.SetFontSize) ~= "function" then return false end
    local value = tonumber(size)
    if value == nil then return false end
    local row = GetState(widget)
    if row.fontSize == value then RecordAttempt("FONT_SIZE", widget, false, 0, owner); return false end
    local ok, err = pcall(function() widget.style:SetFontSize(value) end)
    if ok ~= true then RecordNativeSafetyFailure("FONT_SIZE", widget, err, owner); return false end
    row.fontSize = value
    widget.rsAppliedFontSize = value
    RecordAttempt("FONT_SIZE", widget, true, 1, owner)
    return true
end

function UI:SetAlpha(widget, alpha, owner)
    local usable = WidgetUsable(widget)
    if usable ~= true or type(widget.SetAlpha) ~= "function" then return false end
    local value = math.max(0, math.min(1, tonumber(alpha) or 1))
    local row = GetState(widget)
    if row.alpha == value then RecordAttempt("SET_ALPHA", widget, false, 0, owner); return false end
    local ok, err = pcall(function() widget:SetAlpha(value) end)
    if ok ~= true then RecordNativeSafetyFailure("SET_ALPHA", widget, err, owner); return false end
    row.alpha = value
    RecordAttempt("SET_ALPHA", widget, true, 1, owner)
    return true
end

-- ScaleBox is event/layout driven; cache native SetScale so repeated layout at
-- the same resolution produces zero writes. SetScale is present in the RU UI
-- allowlist, but callers should still provide a non-scale fallback because
-- individual widget classes may omit the method.
function UI:SetScale(widget, scale, owner)
    local usable = WidgetUsable(widget)
    if usable ~= true or type(widget.SetScale) ~= "function" then return false end
    local value = math.max(0.01, tonumber(scale) or 1)
    local row = GetState(widget)
    if row.scale == value then RecordAttempt("SET_SCALE", widget, false, 0, owner); return false end
    local ok, err = pcall(function() widget:SetScale(value) end)
    if ok ~= true then RecordNativeSafetyFailure("SET_SCALE", widget, err, owner); return false end
    row.scale = value
    RecordAttempt("SET_SCALE", widget, true, 1, owner)
    return true
end

-- Tone/button styling is delegated to Theme so there is still only one color
-- Authority. Theme v1 now returns whether a real native repaint was needed.
function UI:SetLabelTone(widget, tone, owner)
    if WidgetUsable(widget) ~= true then return false end
    if S.Theme == nil or type(S.Theme.SetLabelTone) ~= "function" then return false end
    local changed = S.Theme:SetLabelTone(widget, tone) == true
    RecordAttempt("LABEL_TONE", widget, changed, changed and 1 or 0, owner)
    return changed
end

function UI:SetButtonActive(widget, active, owner)
    if WidgetUsable(widget) ~= true then return false end
    if S.Theme == nil or type(S.Theme.SetButtonActive) ~= "function" then return false end
    local changed = S.Theme:SetButtonActive(widget, active == true) == true
    -- A gradient button repaints two drawables (six band calls) internally, but
    -- expose one logical style write here; Theme remains the detailed native
    -- styling Authority.
    RecordAttempt("BUTTON_ACTIVE", widget, changed, changed and 1 or 0, owner)
    return changed
end

function UI:SetEllipsis(widget, enabled, owner)
    if WidgetUsable(widget) ~= true then return false end
    if S.Theme == nil or type(S.Theme.SetEllipsis) ~= "function" then return false end
    local changed = S.Theme:SetEllipsis(widget, enabled == true) == true
    RecordAttempt("ELLIPSIS", widget, changed, changed and 1 or 0, owner)
    return changed
end

local function EnsureOwner(ownerId)
    ownerId = NormalizeOwner(ownerId)
    local row = lifecycle.owners[ownerId]
    if row == nil then
        row = {
            id = ownerId,
            widgets = {},
            widgetSet = setmetatable({}, { __mode = "k" }),
            handlerKeys = setmetatable({}, { __mode = "k" }),
            released = false,
        }
        lifecycle.owners[ownerId] = row
    end
    return row
end

-- Adopt means "this owner is responsible for the Lua/native references".  It
-- does not transfer business state Authority and it does not destroy widgets.
function UI:AdoptWidget(widget, ownerId, logicalId)
    if widget == nil then return false end
    ownerId = OwnerOf(widget, ownerId)
    widget.rsUiOwner = ownerId
    widget.rsUiReleased = false
    if logicalId ~= nil then widget.rsUiLogicalId = tostring(logicalId) end

    local owner = EnsureOwner(ownerId)
    if owner.widgetSet[widget] == true then return true end
    owner.widgetSet[widget] = true
    owner.widgets[#owner.widgets + 1] = widget
    metrics.lifecycle.adopted = metrics.lifecycle.adopted + 1
    return true
end

function UI:RegisterHandlerBinding(widget, eventName)
    if widget == nil or eventName == nil then return false end
    local ownerId = OwnerOf(widget)
    local owner = EnsureOwner(ownerId)
    local events = owner.handlerKeys[widget]
    if events == nil then events = {}; owner.handlerKeys[widget] = events end
    local key = tostring(eventName)
    if events[key] == true then return true end
    events[key] = true
    metrics.lifecycle.handlerBindings = metrics.lifecycle.handlerBindings + 1
    return true
end

function UI:ReleaseOwner(ownerId)
    ownerId = NormalizeOwner(ownerId)
    local owner = lifecycle.owners[ownerId]
    if owner == nil or owner.released == true then return 0 end
    owner.released = true

    local releasedHandlers, hidden = 0, 0
    for widget, events in pairs(owner.handlerKeys) do
        if widget ~= nil and type(events) == "table" and type(widget.ReleaseHandler) == "function" then
            for eventName in pairs(events) do
                local ok = pcall(function() widget:ReleaseHandler(eventName) end)
                if ok then releasedHandlers = releasedHandlers + 1 end
            end
        end
    end

    for _, widget in ipairs(owner.widgets) do
        if widget ~= nil then
            widget.rsUiReleased = true
            if type(UI.SetVisible) == "function" then
                local ok = pcall(function() UI:SetVisible(widget, false, ownerId) end)
                if ok then hidden = hidden + 1 end
            end
            stateCache[widget] = nil
            local logicalId = widget.rsUiLogicalId
            if logicalId ~= nil and UI.controls ~= nil and UI.controls[logicalId] == widget then UI.controls[logicalId] = nil end
        end
    end

    lifecycle.owners[ownerId] = nil
    metrics.lifecycle.releasedOwners = metrics.lifecycle.releasedOwners + 1
    metrics.lifecycle.releasedHandlers = metrics.lifecycle.releasedHandlers + releasedHandlers
    metrics.lifecycle.hiddenOnRelease = metrics.lifecycle.hiddenOnRelease + hidden

    if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Info) == "function" then
        S.DiagnosticsManager:Info("ui", "UI_OWNER_RELEASED", "UI owner 已释放", {
            owner = ownerId,
            handlers = releasedHandlers,
            hidden = hidden,
        })
    end
    return releasedHandlers + hidden
end

function UI:CreateScope(ownerId)
    ownerId = NormalizeOwner(ownerId)
    EnsureOwner(ownerId)
    local scope = { ownerId = ownerId, released = false }

    function scope:Adopt(widget, logicalId)
        if self.released then return false end
        return UI:AdoptWidget(widget, self.ownerId, logicalId)
    end

    function scope:Bind(widget, eventName, fn, label)
        if self.released or widget == nil then return false end
        UI:AdoptWidget(widget, self.ownerId)
        return UI:SafeHandler(widget, eventName, fn, label)
    end

    function scope:Release()
        if self.released then return 0 end
        self.released = true
        return UI:ReleaseOwner(self.ownerId)
    end

    return scope
end

local function CountWeakKeys(tbl)
    local count = 0
    for _ in pairs(tbl or {}) do count = count + 1 end
    return count
end

function UI:ResetFrameworkMetrics()
    metrics.attempts = 0
    metrics.writes = 0
    metrics.skips = 0
    metrics.nativeCalls = 0
    metrics.cacheRepairs = 0
    metrics.cacheRepairsByField = {}
    metrics.cacheRepairsByOwner = {}
    metrics.authority.claims = 0
    metrics.authority.conflicts = 0
    metrics.authority.violations = 0
    metrics.authority.strictRepairs = 0
    metrics.authority.byOwner = {}
    metrics.authority.byField = {}
    metrics.byOp = {}
    metrics.byOwner = {}
    metrics.ownerOrder = {}
    metrics.lifecycle.adopted = 0
    metrics.lifecycle.handlerBindings = 0
    metrics.lifecycle.releasedOwners = 0
    metrics.lifecycle.releasedHandlers = 0
    metrics.lifecycle.hiddenOnRelease = 0
    metrics.nativeSafety.staleRejects = 0
    metrics.nativeSafety.registrationRejects = 0
    metrics.nativeSafety.degradedRejects = 0
    metrics.nativeSafety.callFailures = 0
    metrics.nativeSafety.anchorParentRepairs = 0
    if UI.LayoutV2 ~= nil and type(UI.LayoutV2.ResetMetrics) == "function" then UI.LayoutV2:ResetMetrics() end
    if UI.Binding ~= nil and type(UI.Binding.ResetMetrics) == "function" then UI.Binding:ResetMetrics() end
    if UI.WindowShell ~= nil and type(UI.WindowShell.ResetMetrics) == "function" then UI.WindowShell:ResetMetrics() end
    if S.RSUI ~= nil and S.RSUI.FloatingSurface ~= nil and type(S.RSUI.FloatingSurface.ResetMetrics) == "function" then S.RSUI.FloatingSurface:ResetMetrics() end
    if S.RSUI ~= nil and type(S.RSUI.ResetMetrics) == "function" then S.RSUI:ResetMetrics() end
    return true
end

function UI:GetFrameworkSnapshot()
    local byOp = {}
    for op, row in pairs(metrics.byOp) do
        byOp[#byOp + 1] = {
            op = op,
            attempts = tonumber(row.attempts) or 0,
            writes = tonumber(row.writes) or 0,
            skips = tonumber(row.skips) or 0,
            nativeCalls = tonumber(row.nativeCalls) or 0,
        }
    end
    table.sort(byOp, function(a, b)
        if a.nativeCalls == b.nativeCalls then return a.op < b.op end
        return a.nativeCalls > b.nativeCalls
    end)

    local byOwner = {}
    for owner, row in pairs(metrics.byOwner) do
        byOwner[#byOwner + 1] = {
            owner = owner,
            attempts = tonumber(row.attempts) or 0,
            writes = tonumber(row.writes) or 0,
            skips = tonumber(row.skips) or 0,
            nativeCalls = tonumber(row.nativeCalls) or 0,
        }
    end
    table.sort(byOwner, function(a, b)
        if a.nativeCalls == b.nativeCalls then return a.owner < b.owner end
        return a.nativeCalls > b.nativeCalls
    end)

    local cacheRepairsByField = {}
    for field, count in pairs(metrics.cacheRepairsByField or {}) do cacheRepairsByField[field] = tonumber(count) or 0 end
    local cacheRepairsByOwner = {}
    for owner, count in pairs(metrics.cacheRepairsByOwner or {}) do
        cacheRepairsByOwner[#cacheRepairsByOwner + 1] = { owner = owner, count = tonumber(count) or 0 }
    end
    table.sort(cacheRepairsByOwner, function(a, b)
        if a.count == b.count then return a.owner < b.owner end
        return a.count > b.count
    end)

    local ownerCount = 0
    for _ in pairs(lifecycle.owners) do ownerCount = ownerCount + 1 end
    local skipRatio = metrics.attempts > 0 and (metrics.skips / metrics.attempts) or 0

    return {
        version = FRAMEWORK_VERSION,
        cachedWidgets = CountWeakKeys(stateCache),
        owners = ownerCount,
        attempts = metrics.attempts,
        writes = metrics.writes,
        skips = metrics.skips,
        nativeCalls = metrics.nativeCalls,
        cacheRepairs = tonumber(metrics.cacheRepairs) or 0,
        cacheRepairsByField = cacheRepairsByField,
        cacheRepairsByOwner = cacheRepairsByOwner,
        authority = self:GetAuthoritySnapshot(),
        skipRatio = skipRatio,
        byOp = byOp,
        byOwner = byOwner,
        lifecycle = {
            adopted = metrics.lifecycle.adopted,
            handlerBindings = metrics.lifecycle.handlerBindings,
            releasedOwners = metrics.lifecycle.releasedOwners,
            releasedHandlers = metrics.lifecycle.releasedHandlers,
            hiddenOnRelease = metrics.lifecycle.hiddenOnRelease,
        },
        nativeSafety = {
            staleRejects = tonumber(metrics.nativeSafety.staleRejects) or 0,
            registrationRejects = tonumber(metrics.nativeSafety.registrationRejects) or 0,
            degradedRejects = tonumber(metrics.nativeSafety.degradedRejects) or 0,
            callFailures = tonumber(metrics.nativeSafety.callFailures) or 0,
            anchorParentRepairs = tonumber(metrics.nativeSafety.anchorParentRepairs) or 0,
        },
        screenSnap = self:GetScreenSnapSnapshot(),
        design = {
            tokens = S.UITokens and tonumber(S.UITokens.version) or 0,
            layout = UI.LayoutV2 and UI.LayoutV2:GetSnapshot() or nil,
            binding = UI.Binding and UI.Binding:GetSnapshot() or nil,
            shell = UI.WindowShell and UI.WindowShell:GetSnapshot() or nil,
            floatingSurface = S.RSUI and S.RSUI.FloatingSurface and S.RSUI.FloatingSurface:GetSnapshot() or nil,
            rsui = S.RSUI and S.RSUI:GetSnapshot() or nil,
        },
    }
end
