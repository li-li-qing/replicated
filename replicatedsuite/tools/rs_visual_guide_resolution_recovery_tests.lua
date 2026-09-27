-- Replicated Suite - visual-guide resolution/style recovery regression host.
-- Maintenance intent:
-- This test deliberately uses production rs_theme.lua and rs_v3_combat_visual_guides.lua while
-- providing only the smallest UI/runtime host necessary. It exists because the legacy workspace
-- theme/unit-line hosts are not currently self-contained in the distribution. The contract under
-- test is the user-visible failure mode: a native UI environment reset (resolution/quality/UI-scale)
-- may reset LABEL TextStyle font size without changing feature settings; range-assist and unit-line
-- point glyphs must recover their configured diameter automatically and Theme typography refresh
-- must not clamp them back to ordinary text sizes.

local SCRIPT = debug.getinfo(1, "S").source
local SCRIPT_PATH = SCRIPT:sub(1, 1) == "@" and SCRIPT:sub(2) or SCRIPT
local ROOT = SCRIPT_PATH:match("^(.*)/tools/[^/]+$") or (SCRIPT_PATH:match("^tools/[^/]+$") and ".")
assert(ROOT, "unable to resolve replicatedsuite root")

local passed, failed = 0, 0
local function expect(name, condition, detail)
  if condition then
    passed = passed + 1
    io.write("PASS: " .. name .. "\n")
  else
    failed = failed + 1
    io.write("FAIL: " .. name .. (detail and (" :: " .. tostring(detail)) or "") .. "\n")
  end
end

ALIGN_LEFT = ALIGN_LEFT or "LEFT"
ALIGN_CENTER = ALIGN_CENTER or "CENTER"
ALIGN_RIGHT = ALIGN_RIGHT or "RIGHT"

local uiRevision = 1
local nowMs = 1000
local fontWrites = 0
local invalidations = 0
local controls = {}
local stateCache = setmetatable({}, { __mode = "k" })

ReplicatedSuite = {
  Constants = {
    Color = {
      text = {1, 1, 1, 1},
      textMuted = {0.7, 0.7, 0.7, 1},
      green = {0.2, 1, 0.2, 1},
      yellow = {1, 1, 0.2, 1},
      orange = {1, 0.6, 0.2, 1},
      red = {1, 0.2, 0.2, 1},
      blue = {0.2, 0.6, 1, 1},
      purple = {0.7, 0.4, 1, 1},
      accent = {0.2, 0.8, 1, 1}
    },
    VisualGuide = {
      unitPointHardMax = 24,
      rangePointHardMax = 24
    }
  },
  AppState = { settings = { fontScale = 1 } },
  FrameBudget = { current = { pressure = "Normal" } },
  Services = {},
  Features = {},
  NowMs = function() return nowMs end,
}
local S = ReplicatedSuite

S.Layout = {
  UiEnvironmentRevisionContractVersion = 1,
  GetUiEnvironmentRevision = function(self)
    return uiRevision, "test_revision_" .. tostring(uiRevision)
  end,
  GetContext = function(self)
    return {
      addonScale = 1,
      screenWidth = 1920,
      screenHeight = 1080,
      logicalWidth = 1920,
      logicalHeight = 1080,
      uiScale = 1
    }
  end,
  GetUiParentLocalOrigin = function(self)
    return 0, 0, true
  end
}

S.Services.ScreenProjectionV3 = {
  GetUiParentViewport = function(self)
    return 1920, 1080, "test_viewport"
  end
}

S.UI = {
  controls = controls,
  NativeStateCache = stateCache,
}

function S.UI:PrimeNativeState(widget, patch)
  if not widget or type(patch) ~= "table" then return false end
  local state = stateCache[widget] or {}
  for key, value in pairs(patch) do state[key] = value end
  stateCache[widget] = state
  return true
end

function S.UI:InvalidateNativeState(widget)
  if not widget then return false end
  stateCache[widget] = nil
  invalidations = invalidations + 1
  return true
end

local function makeStyle(widget)
  local style = {}
  function style:SetFontSize(size)
    widget.nativeFontSize = tonumber(size)
    fontWrites = fontWrites + 1
  end
  function style:SetColor(r, g, b, a)
    widget.nativeColor = { r, g, b, a }
  end
  function style:SetAlign(v) widget.nativeAlign = v end
  function style:SetEllipsis(v) widget.nativeEllipsis = v and true or false end
  return style
end

function S.UI:CreateOverlayWindow(id, owner)
  local widget = {
    id = id,
    owner = owner,
    visible = true,
    anchor = {0, 0, 1, 1}
  }
  function widget:SetExtent(w, h)
    self.width, self.height = w, h
  end
  function widget:AddAnchor(...) self.anchor = {...} end
  controls[id] = widget
  return widget
end

function S.UI:CreateLabel(parent, id, text, x, y, w, h, fontSize, tone, align, shadow)
  local widget = {
    id = id,
    owner = parent and parent.owner or nil,
    text = text or "",
    x = x or 0,
    y = y or 0,
    width = w or 0,
    height = h or 0,
    visible = true,
    style = nil,
    rsBaseFontSize = tonumber(fontSize) or 15,
  }
  widget.style = makeStyle(widget)
  function widget:SetText(v) self.text = tostring(v or "") end
  function widget:SetExtent(ww, hh) self.width, self.height = ww, hh end
  function widget:AddAnchor(...) self.anchor = {...} end
  if S.Theme and S.Theme.StyleLabel then
    S.Theme:StyleLabel(widget, widget.rsBaseFontSize, tone or "normal", align or "LEFT", shadow)
  else
    widget.style:SetFontSize(widget.rsBaseFontSize)
    widget.rsAppliedFontSize = widget.rsBaseFontSize
  end
  controls[id] = widget
  self:PrimeNativeState(widget, {
    visible = true,
    fontSize = widget.rsAppliedFontSize or widget.nativeFontSize,
    text = widget.text
  })
  return widget
end

function S.UI:SetVisible(widget, visible)
  if not widget then return false end
  widget.visible = visible and true or false
  self:PrimeNativeState(widget, { visible = widget.visible })
  return true
end
function S.UI:EnsureVisible(widget, visible)
  if not widget then return false end
  local state = stateCache[widget]
  local desired = visible and true or false
  if state and state.visible == desired then return true end
  return self:SetVisible(widget, desired)
end
function S.UI:SetAnchor(widget, parent, x, y, owner)
  if not widget or not parent then return false end
  widget.anchorParent, widget.x, widget.y = parent, x, y
  self:PrimeNativeState(widget, { anchorParent = parent, anchorX = x, anchorY = y })
  return true
end
function S.UI:EnsureAnchor(widget, parent, x, y, owner)
  if not widget or not parent then return false, false, "parent_required" end
  local state = stateCache[widget]
  if state and state.anchorParent == parent and state.anchorX == x and state.anchorY == y then return true, false, nil end
  local changed = self:SetAnchor(widget, parent, x, y, owner)
  return changed == true, changed == true, changed == true and nil or "native_anchor_rejected"
end
function S.UI:SetFontSize(widget, size)
  if not widget or not widget.style or type(widget.style.SetFontSize) ~= "function" then return false end
  widget.style:SetFontSize(size)
  widget.rsAppliedFontSize = tonumber(size)
  self:PrimeNativeState(widget, { fontSize = tonumber(size) })
  return true
end
function S.UI:SetColor(widget, r, g, b, a, owner)
  if not widget or not widget.style or type(widget.style.SetColor) ~= "function" then return false end
  r, g, b, a = tonumber(r) or 0, tonumber(g) or 0, tonumber(b) or 0, tonumber(a) or 1
  widget.style:SetColor(r, g, b, a)
  self:PrimeNativeState(widget, { colorR = r, colorG = g, colorB = b, colorA = a })
  return true
end

S.FeatureRuntime = {
  IsEnabled = function(self, id) return false end
}

local unitProjection = {
  visible = true,
  pointCount = 20,
  pointSize = 10,
  opacity = 0.85,
  refreshMs = 50,
  rows = {
    {
      key = "target",
      x1 = 200, y1 = 200, x2 = 700, y2 = 500,
      visible = true,
      color = {0.2, 1, 0.2, 1},
      pointSize = 10,
      pointCount = 20,
      opacity = 0.85
    }
  }
}
local rangeProjection = {
  visible = true,
  circleCount = 1,
  enabledCircleCount = 1,
  rows = {
    {
      circleKey = "range:1",
      pointSize = 8,
      opacity = 0.75,
      color = {1, 0.8, 0.2, 1},
      points = {
        {x = 600, y = 350}, {x = 650, y = 400}, {x = 600, y = 450}, {x = 550, y = 400}
      }
    }
  }
}

S.Features.combat_unit_lines = {
  UpdateTopic = "combat.unit_lines.updated",
  GetProjection = function(self) return unitProjection end,
  AcquireConsumer = function() return true end,
  ReleaseConsumer = function() return true end,
  HasConsumer = function() return true end
}
S.Features.combat_range_assist = {
  UpdateTopic = "combat.range_assist.updated",
  GetProjection = function(self) return rangeProjection end,
  AcquireConsumer = function() return true end,
  ReleaseConsumer = function() return true end,
  HasConsumer = function() return true end
}

local function loadFile(rel)
  local fn, err = loadfile(ROOT .. "/" .. rel)
  assert(fn, err)
  return fn()
end

loadFile("core/rs_theme.lua")
loadFile("presentation/v3/widgets/rs_v3_combat_visual_guides.lua")

expect("theme manual typography contract exists", S.Theme.ManualTypographyOwnershipContractVersion == 1)
local P = assert(S.UIV3 and S.UIV3.CombatVisualGuidesV3, "visual guide presenter missing")
expect("visual guide presenter version 15+", (P.version or 0) >= 15)
expect("visual guide UI-environment recovery contract exists", P.UiEnvironmentStyleRecoveryContractVersion == 1)
expect("visual guide manual typography contract exists", P.ManualPointTypographyContractVersion == 1)

-- Prove the underlying failure mechanism on an ordinary label: a 40px manual write gets
-- re-resolved from its 15px base and clamped back to normal typography on RefreshTypography.
local ordinaryParent = S.UI:CreateOverlayWindow("ordinary_parent", "test")
local ordinary = S.UI:CreateLabel(ordinaryParent, "ordinary_probe", ".", 0, 0, 20, 20, 15, "strong", "CENTER", false)
S.UI:SetFontSize(ordinary, 40)
local beforeOrdinaryRefresh = ordinary.nativeFontSize
S.Theme:RefreshTypography()
expect("ordinary label demonstrates theme reset mechanism", beforeOrdinaryRefresh == 40 and ordinary.nativeFontSize ~= 40, ordinary.nativeFontSize)

-- Unit line point: configured point size 10 maps to a 40px glyph in production.
P.unitHeld = true
P:EnsureHost("unit")
P:RenderUnit("test_initial")
local unitPool = P.unitPools and P.unitPools.target
local unitDot = unitPool and unitPool[1]
expect("unit dot created", unitDot and unitDot.root ~= nil)
expect("unit dot opts out of ordinary typography", unitDot and unitDot.root.rsManualTypography == true)
expect("unit dot gets configured visual size", unitDot and unitDot.root.nativeFontSize == 40, unitDot and unitDot.root.nativeFontSize)

local unitFontBeforeTheme = unitDot and unitDot.root.nativeFontSize
S.Theme:RefreshTypography()
expect("theme refresh does not shrink unit-line point", unitDot and unitDot.root.nativeFontSize == unitFontBeforeTheme, unitDot and unitDot.root.nativeFontSize)

-- Simulate the game/native UI recreating TextStyle during a resolution/quality change while
-- leaving our Lua-side render diff cache stale. This was the production bug.
unitDot.root.nativeFontSize = 15
S.UI:PrimeNativeState(unitDot.root, { fontSize = 15 })
local invalidBeforeUnitRecovery = invalidations
uiRevision = uiRevision + 1
nowMs = nowMs + 100
P:RenderUnit("test_resolution_change")
expect("unit dot recovers after UI environment revision", unitDot.root.nativeFontSize == 40, unitDot.root.nativeFontSize)
expect("unit recovery invalidates stale render/native cache", invalidations > invalidBeforeUnitRecovery, invalidations)

local invalidStableUnit = invalidations
local fontStableUnit = fontWrites
nowMs = nowMs + 100
P:RenderUnit("test_same_revision")
expect("same UI revision does not repeatedly invalidate unit dots", invalidations == invalidStableUnit, invalidations)
expect("same UI revision preserves diff-render font writes", fontWrites == fontStableUnit, fontWrites - fontStableUnit)

-- Range-assist shares the same style-recovery fence and manual typography ownership.
P.rangeHeld = true
P:EnsureHost("range")
P:RenderRange("test_range_initial")
local rangePool = P.rangePools and P.rangePools["range_1"]
local rangeDot = rangePool and rangePool[1]
local expectedRangeSize = math.max(15, math.floor(10 + 8 * 3))
expect("range dot created", rangeDot and rangeDot.root ~= nil)
expect("range dot opts out of ordinary typography", rangeDot and rangeDot.root.rsManualTypography == true)
expect("range dot gets configured visual size", rangeDot and rangeDot.root.nativeFontSize == expectedRangeSize, rangeDot and rangeDot.root.nativeFontSize)

local rangeFontBeforeTheme = rangeDot.root.nativeFontSize
S.Theme:RefreshTypography()
expect("theme refresh does not shrink range-assist point", rangeDot.root.nativeFontSize == rangeFontBeforeTheme, rangeDot.root.nativeFontSize)

rangeDot.root.nativeFontSize = 15
S.UI:PrimeNativeState(rangeDot.root, { fontSize = 15 })
local invalidBeforeRangeRecovery = invalidations
uiRevision = uiRevision + 1
nowMs = nowMs + 100
P:RenderRange("test_quality_change")
expect("range dot recovers after UI environment revision", rangeDot.root.nativeFontSize == expectedRangeSize, rangeDot.root.nativeFontSize)
expect("range recovery invalidates stale render/native cache", invalidations > invalidBeforeRangeRecovery, invalidations)

local describe = P:Describe()
expect("diagnostics expose style recovery telemetry", type(describe) == "table" and (describe.styleRecoveryCount or 0) >= 2, describe and describe.styleRecoveryCount)
expect("diagnostics expose last UI environment revision", type(describe) == "table" and tonumber(describe.uiEnvironmentRevision) == uiRevision, describe and describe.uiEnvironmentRevision)

io.write(string.format("VISUAL_GUIDE_RESOLUTION_RECOVERY RESULT %d passed / %d failed (Lua %s)\n", passed, failed, _VERSION))
if failed > 0 then os.exit(1) end
