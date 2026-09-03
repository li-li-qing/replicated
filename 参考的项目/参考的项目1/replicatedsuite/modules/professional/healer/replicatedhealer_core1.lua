ReplicatedSuiteModuleSandbox:Enter('healer', {'ReplicatedHealerBoot', 'ReplicatedHealerConfig', 'ReplicatedHealerModule'})
-----------------------------------------------------------------------
-- Replicated Healer Recommender v3.0.8 Core
-- Author: Replicated
-- Loaded after replicatedhealer.lua bootstrap launcher.
-----------------------------------------------------------------------

if API_TYPE == nil then
	ADDON:ImportAPI(8)
	return
end

-- The bootstrap file creates the visible launcher before this core is loaded.
bootstrapLauncherButton = ReplicatedHealerBoot and ReplicatedHealerBoot.button or nil
bootstrapCreateError = ReplicatedHealerBoot and ReplicatedHealerBoot.createError or nil

pcall(function() ADDON:ImportAPI(API_TYPE.CHAT.id) end)
pcall(function() ADDON:ImportObject(OBJECT_TYPE.TEXT_STYLE) end)
pcall(function() ADDON:ImportObject(OBJECT_TYPE.BUTTON) end)
pcall(function() ADDON:ImportObject(OBJECT_TYPE.DRAWABLE) end)
pcall(function() ADDON:ImportObject(OBJECT_TYPE.COLOR_DRAWABLE) end)
pcall(function() ADDON:ImportObject(OBJECT_TYPE.NINE_PART_DRAWABLE) end)
pcall(function() ADDON:ImportObject(OBJECT_TYPE.WINDOW) end)
pcall(function() ADDON:ImportObject(OBJECT_TYPE.LABEL) end)
pcall(function() ADDON:ImportObject(OBJECT_TYPE.EDITBOX) end)
pcall(function() ADDON:ImportObject(OBJECT_TYPE.X2_EDITBOX) end)
pcall(function() ADDON:ImportObject(OBJECT_TYPE.EMPTY_WIDGET) end)
pcall(function() ADDON:ImportAPI(API_TYPE.UNIT.id) end)
pcall(function() ADDON:ImportAPI(API_TYPE.TEAM.id) end)

ADDON_AUTHOR = "Replicated"
ADDON_TITLE = "Replicated 治疗推荐器"
HEALER_CONFIG = type(ReplicatedHealerConfig) == "table" and ReplicatedHealerConfig or {}
SAVE_KEY_V2 = tostring(HEALER_CONFIG.SaveKey or "replicated_healer_recommender_v2")
SAVE_KEY_V2_BACKUP = SAVE_KEY_V2 .. "_backup"
LEGACY_SAVE_KEY = tostring(HEALER_CONFIG.LegacySaveKey or "replicated_healer_recommender_v1")
SETTINGS_VERSION = tonumber(HEALER_CONFIG.SettingsVersion) or 214
storageWriteFenceReason = nil
storageWriteFenceWarned = false
stateNeedsMigrationSave = false
TOP_LAYER = "system"
CONTENT_ID = 91734

MAX_RULES = 20
MAX_RAID_MEMBERS = 50
MAX_CO_RAID_MEMBERS = 100
MEMBERS_PER_GROUP = 5
GROUPS_PER_SECTION = 5
MEMBERS_PER_SECTION = 25
MAX_HEAD_MARKERS = 50
RECOMMEND_VISIBLE_ROWS = 10
UNAVAILABLE_VISIBLE_ROWS = 2

LAUNCHER_WIDTH = 88
LAUNCHER_HEIGHT = 26
RECOMMEND_FULL_WIDTH = 510
RECOMMEND_FULL_HEIGHT = 342
RECOMMEND_MINI_WIDTH = 430
CONFIG_WIDTH = 560
CONFIG_HEIGHT = 500
RULE_EDITOR_WIDTH = 560
RULE_EDITOR_HEIGHT = 500
PAGE_SWITCHER_WIDTH = 174
PAGE_SWITCHER_HEIGHT = 25

EFFECT_LABELS = { "常驻", "缓慢呼吸", "快速闪烁" }
HEAD_SHAPE_LABELS = { "横条", "方块", "十字", "向下箭头" }
PANEL_MODE_LABELS = { "完整", "迷你", "隐藏" }
SORT_MODE_LABELS = { "统一排序", "分团显示" }
HEALTH_CURVE_LABELS = { "线性", "低血量加速" }
HEALTH_ACCEL_LABELS = { "柔和", "标准", "强烈" }
DISTANCE_CURVE_LABELS = { "线性", "边缘惩罚" }
RANK_CORNER_LABELS = { "左上", "右上", "左下", "右下" }
CALIBRATION_SCOPE_LABELS = { "两团", "仅1团", "仅2团" }
LEVEL_LABELS = { "低优先", "需要关注", "高危", "紧急" }
ROLE_LABELS = { "普通成员", "主坦", "副坦", "治疗", "未识别" }
UNPROTECTED_COLOR = { r = 1.00, g = 0.48, b = 0.08, a = 0.78 }

RULE_PURPOSE_LABELS = {
	"治疗保护",
	"危险状态",
	"控制/解控",
	"不可救援",
	"通用自定义",
}
RULE_SOURCE_LABELS = {
	"普通 Buff",
	"Debuff",
	"隐藏 Buff",
	"Buff + Debuff",
	"全部状态",
}
RULE_MATCH_LABELS = { "命中任意一个", "必须全部命中" }
RULE_EFFECT_LABELS = { "降低评分", "提高评分", "直接排除", "强制紧急" }
RULE_SCORE_MODE_LABELS = { "固定分数", "基础评分百分比" }
RULE_DISTANCE_MODE_LABELS = { "使用全局治疗距离", "自定义作用距离" }
EXCLUDE_DISPLAY_LABELS = { "完全隐藏", "显示暂不可救援" }

SOURCE_BUFF = 1
SOURCE_DEBUFF = 2
SOURCE_HIDDEN = 4

function Clamp(value, minValue, maxValue)
	value = tonumber(value) or minValue
	if value < minValue then
		return minValue
	end
	if value > maxValue then
		return maxValue
	end
	return value
end

function Round(value, decimals)
	local multiplier = 10 ^ (decimals or 0)
	return math.floor((value * multiplier) + 0.5) / multiplier
end

function DeepCopy(value)
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, item in pairs(value) do
		result[key] = DeepCopy(item)
	end
	return result
end

function CopyColor(color, fallback)
	local source = type(color) == "table" and color or fallback or {}
	return {
		r = Clamp(source.r or 1, 0, 1),
		g = Clamp(source.g or 1, 0, 1),
		b = Clamp(source.b or 1, 0, 1),
		a = Clamp(source.a or 1, 0, 1),
	}
end

function CopyAnchor(source, fallback, includeSize)
	local sourceTable = type(source) == "table" and source or {}
	local fallbackTable = type(fallback) == "table" and fallback or {}
	local result = {
		horizontal = sourceTable.horizontal == "RIGHT" and "RIGHT" or (fallbackTable.horizontal or "LEFT"),
		vertical = sourceTable.vertical == "BOTTOM" and "BOTTOM" or (fallbackTable.vertical or "TOP"),
		offsetX = tonumber(sourceTable.offsetX) or tonumber(fallbackTable.offsetX) or 0,
		offsetY = tonumber(sourceTable.offsetY) or tonumber(fallbackTable.offsetY) or 0,
	}
	if includeSize then
		result.width = tonumber(sourceTable.width) or tonumber(fallbackTable.width) or 100
		result.height = tonumber(sourceTable.height) or tonumber(fallbackTable.height) or 100
	end
	return result
end

function GetUiMetrics()
	local uiScale = 1
	if UIParent ~= nil and UIParent.GetUIScale ~= nil then
		local ok, value = pcall(function() return UIParent:GetUIScale() end)
		if ok and tonumber(value) ~= nil and tonumber(value) > 0 then uiScale = tonumber(value) end
	elseif UI ~= nil and UI.GetUIScale ~= nil then
		local ok, value = pcall(function() return UI:GetUIScale() end)
		if ok and tonumber(value) ~= nil and tonumber(value) > 0 then uiScale = tonumber(value) end
	end

	-- UIParent extent is the actual logical canvas.  Some RU clients can report
	-- a larger physical screen size after switching to 1024x768, which makes a
	-- saved 1920x1080 coordinate look valid even though it is off the visible UI.
	local logicalWidth, logicalHeight = nil, nil
	if UIParent ~= nil and UIParent.GetExtent ~= nil then
		local ok, width, height = pcall(function() return UIParent:GetExtent() end)
		if ok then logicalWidth, logicalHeight = tonumber(width), tonumber(height) end
	end
	if (logicalWidth == nil or logicalWidth <= 0) and UIParent ~= nil and UIParent.GetWidth ~= nil then
		local ok, value = pcall(function() return UIParent:GetWidth() end)
		if ok then logicalWidth = tonumber(value) end
	end
	if (logicalHeight == nil or logicalHeight <= 0) and UIParent ~= nil and UIParent.GetHeight ~= nil then
		local ok, value = pcall(function() return UIParent:GetHeight() end)
		if ok then logicalHeight = tonumber(value) end
	end

	local screenWidth = logicalWidth ~= nil and logicalWidth > 0 and logicalWidth * uiScale or 1920
	local screenHeight = logicalHeight ~= nil and logicalHeight > 0 and logicalHeight * uiScale or 1080
	if logicalWidth == nil or logicalWidth <= 0 then
		if UI ~= nil and UI.GetScreenWidth ~= nil then
			local ok, value = pcall(function() return UI:GetScreenWidth() end)
			if ok and tonumber(value) ~= nil then screenWidth = tonumber(value) end
		elseif UIParent ~= nil and UIParent.GetScreenWidth ~= nil then
			local ok, value = pcall(function() return UIParent:GetScreenWidth() end)
			if ok and tonumber(value) ~= nil then screenWidth = tonumber(value) end
		end
		logicalWidth = screenWidth / uiScale
	end
	if logicalHeight == nil or logicalHeight <= 0 then
		if UI ~= nil and UI.GetScreenHeight ~= nil then
			local ok, value = pcall(function() return UI:GetScreenHeight() end)
			if ok and tonumber(value) ~= nil then screenHeight = tonumber(value) end
		elseif UIParent ~= nil and UIParent.GetScreenHeight ~= nil then
			local ok, value = pcall(function() return UIParent:GetScreenHeight() end)
			if ok and tonumber(value) ~= nil then screenHeight = tonumber(value) end
		end
		logicalHeight = screenHeight / uiScale
	end
	return screenWidth, screenHeight, uiScale, logicalWidth, logicalHeight
end

function EffectiveToAnchorOffset(value)
	if F_LAYOUT ~= nil and F_LAYOUT.CalcDontApplyUIScale ~= nil then
		return F_LAYOUT.CalcDontApplyUIScale(tonumber(value) or 0)
	end
	local _, _, uiScale = GetUiMetrics()
	return (tonumber(value) or 0) / uiScale
end

function GetLogicalWidgetRect(widget)
	local _, _, uiScale = GetUiMetrics()
	local x, y = nil, nil
	local width, height = nil, nil
	if widget.GetEffectiveOffset ~= nil then
		x, y = widget:GetEffectiveOffset()
	end
	if widget.GetEffectiveExtent ~= nil then
		width, height = widget:GetEffectiveExtent()
	end
	if x == nil or y == nil then
		x, y = widget:GetOffset()
		return tonumber(x) or 0, tonumber(y) or 0, tonumber(widget:GetWidth()) or 1, tonumber(widget:GetHeight()) or 1
	end
	if width == nil or height == nil then
		width = (tonumber(widget:GetWidth()) or 1) * uiScale
		height = (tonumber(widget:GetHeight()) or 1) * uiScale
	end
	return (tonumber(x) or 0) / uiScale, (tonumber(y) or 0) / uiScale, (tonumber(width) or 1) / uiScale, (tonumber(height) or 1) / uiScale
end

-- Resolution-safe top-level drag bridge. In Suite mode all free-floating
-- Healer windows use the shared logical UIParent proxy so CryEngine cannot
-- normalize a scaled/responsive window on the first drag frame at 1024x768.
-- Standalone mode keeps the historical native path.
function BeginHealerSafeMove(widget, key, clampToScreen)
	if widget == nil then return false end
	widget.rhResolutionDragKey = tostring(key or "healer_window")
	widget.rhResolutionSafeMove = false
	if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
		and type(ReplicatedSuite.Layout.BeginSafeMove) == "function" then
		local ok, moved = pcall(function()
			return ReplicatedSuite.Layout:BeginSafeMove(widget.rhResolutionDragKey, widget, { clamp = clampToScreen ~= false })
		end)
		widget.rhResolutionSafeMove = ok and moved == true
	end
	if widget.rhResolutionSafeMove ~= true and type(widget.StartMoving) == "function" then
		widget:StartMoving()
	end
	return widget.rhResolutionSafeMove == true
end

function EndHealerSafeMove(widget)
	if widget == nil then return false end
	if widget.rhResolutionSafeMove == true and ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
		and type(ReplicatedSuite.Layout.EndSafeMove) == "function" then
		pcall(function() ReplicatedSuite.Layout:EndSafeMove(widget.rhResolutionDragKey, false) end)
	elseif type(widget.StopMovingOrSizing) == "function" then
		widget:StopMovingOrSizing()
	end
	widget.rhResolutionSafeMove = false
	if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
		and type(ReplicatedSuite.Layout.EnsureWidgetVisible) == "function" then
		pcall(function() ReplicatedSuite.Layout:EnsureWidgetVisible(widget, { onlyWhenVisible = true }) end)
	elseif widget.CorrectOffsetByScreen ~= nil then
		pcall(function() widget:CorrectOffsetByScreen() end)
	end
	return true
end

function RegisterHealerFloating(id, widget, options)
	if ReplicatedSuiteEmbedded ~= true or ReplicatedSuite == nil or ReplicatedSuite.Layout == nil
		or type(ReplicatedSuite.Layout.RegisterFloating) ~= "function" or widget == nil then return false end
	options = type(options) == "table" and options or {}
	if options.onlyWhenVisible == nil then options.onlyWhenVisible = true end
	if options.ensureNow == nil then options.ensureNow = false end
	return ReplicatedSuite.Layout:RegisterFloating("healer_" .. tostring(id or "window"), widget, options)
end

function StoreAnchoredRect(target, x, y, width, height)
	local _, _, _, screenWidth, screenHeight = GetUiMetrics()
	width = Clamp(width or 1, 1, screenWidth)
	height = Clamp(height or 1, 1, screenHeight)
	x = Clamp(x or 0, 0, math.max(0, screenWidth - width))
	y = Clamp(y or 0, 0, math.max(0, screenHeight - height))
	if x + width / 2 <= screenWidth / 2 then
		target.horizontal = "LEFT"
		target.offsetX = x
	else
		target.horizontal = "RIGHT"
		target.offsetX = screenWidth - x - width
	end
	if y + height / 2 <= screenHeight / 2 then
		target.vertical = "TOP"
		target.offsetY = y
	else
		target.vertical = "BOTTOM"
		target.offsetY = screenHeight - y - height
	end
	target.offsetX = math.max(0, target.offsetX)
	target.offsetY = math.max(0, target.offsetY)
	if target.width ~= nil then
		target.width = width
		target.height = height
	end
end

function ResolveAnchoredRect(rect, width, height)
	local _, _, _, screenWidth, screenHeight = GetUiMetrics()
	width = Clamp(width or rect.width or 1, 1, screenWidth)
	height = Clamp(height or rect.height or 1, 1, screenHeight)
	local x = rect.horizontal == "RIGHT" and (screenWidth - (rect.offsetX or 0) - width) or (rect.offsetX or 0)
	local y = rect.vertical == "BOTTOM" and (screenHeight - (rect.offsetY or 0) - height) or (rect.offsetY or 0)
	x = Clamp(x, 0, math.max(0, screenWidth - width))
	y = Clamp(y, 0, math.max(0, screenHeight - height))
	return x, y, width, height
end

FLAT_BUTTON_FONT_COLOR = {
	normal = { 0.96, 0.92, 0.82, 1.00 },
	highlight = { 1.00, 0.96, 0.80, 1.00 },
	pushed = { 0.90, 0.86, 0.72, 1.00 },
	disabled = { 0.52, 0.55, 0.58, 1.00 },
}
FLAT_BUTTON_DRAWABLE_COLOR = {
	normal = { 0.14, 0.21, 0.29, 0.97 },
	over = { 0.23, 0.35, 0.47, 0.99 },
	click = { 0.08, 0.13, 0.19, 0.99 },
	disable = { 0.08, 0.09, 0.11, 0.72 },
}

function ApplyExactButtonStyle(button, width, height, fontSize)
	ApplyReplicatedButtonStyle(button, width or 100, height or 24, fontSize or 11)
end

function CreateBackground(parent, red, green, blue, alpha)
	local background = parent:CreateColorDrawable(red, green, blue, alpha, "background")
	background:AddAnchor("TOPLEFT", parent, 0, 0)
	background:AddAnchor("BOTTOMRIGHT", parent, 0, 0)
	return background
end

function CreateLabel(parent, id, text, x, y, width, height, fontSize, align)
	local label = parent:CreateChildWidget("label", id, 0, true)
	label:AddAnchor("TOPLEFT", parent, x, y)
	label:SetExtent(width, height)
	label:EnablePick(false)
	label:Show(true)
	label.style:SetFontSize(fontSize or 12)
	label.style:SetAlign(align or ALIGN_LEFT)
	label.style:SetColor(1, 1, 1, 1)
	label:SetText(text or "")
	return label
end

function CreateTextButton(parent, id, text, x, y, width, height, fontSize)
	local button = parent:CreateChildWidget("button", id, 0, true)
	button:SetText(text or "")
	ApplyExactButtonStyle(button, width or 100, height or 24, fontSize or 11)
	button:AddAnchor("TOPLEFT", parent, x, y)
	return button
end

function CreateEditBox(parent, id, x, y, width, height, maxLength)
	local edit = parent:CreateChildWidgetByType(UOT_X2_EDITBOX, id, 0, true)
	edit:SetExtent(width, height or 24)
	edit:SetInset(5, 5, 5, 5)
	edit:EnableFocus(true)
	edit:UseSelectAllWhenFocused(true)
	edit.style:SetAlign(ALIGN_LEFT)
	edit.style:SetColorByKey("title")
	if maxLength ~= nil and edit.SetMaxTextLength ~= nil then
		edit:SetMaxTextLength(maxLength)
	end
	local bg = edit:CreateDrawable("ui/common/default.dds", "editbox_df", "background")
	bg:AddAnchor("TOPLEFT", edit, 0, 0)
	bg:AddAnchor("BOTTOMRIGHT", edit, 0, 0)
	edit.bg = bg
	edit:AddAnchor("TOPLEFT", parent, x, y)
	return edit
end

function SetMouseThrough(widget, mouseThrough)
	if widget == nil then
		return
	end
	-- RU exposes EnablePick/Clickable as single-argument methods.  Keep the
	-- helper on the documented signature: passing an extra recursive flag
	-- made input ownership unreliable on some widget types.
	if widget.EnablePick ~= nil then
		pcall(function() widget:EnablePick(not mouseThrough) end)
	end
	if widget.Clickable ~= nil then
		pcall(function() widget:Clickable(not mouseThrough) end)
	end
end

function BooleanText(value)
	return value and "开" or "关"
end

function Cycle(value, count, delta)
	local nextValue = (tonumber(value) or 1) + (delta or 1)
	while nextValue < 1 do
		nextValue = nextValue + count
	end
	while nextValue > count do
		nextValue = nextValue - count
	end
	return nextValue
end

function ParseIdList(text)
	local result = {}
	local seen = {}
	for token in string.gmatch(tostring(text or ""), "%d+") do
		local id = tonumber(token)
		if id ~= nil and id > 0 and not seen[id] then
			seen[id] = true
			result[#result + 1] = id
		end
	end
	return result
end

function JoinIdList(ids)
	local parts = {}
	for index = 1, #(ids or {}) do
		parts[#parts + 1] = tostring(ids[index])
	end
	return table.concat(parts, ", ")
end

function NewDefaultHealingRule()
	return {
		name = "持续回血",
		enabled = true,
		purpose = 1,
		sourceMode = 1,
		matchMode = 1,
		ids = { 25875, 220 },
		minStacks = 1,
		minRemainingMs = 0,
		unknownRemainingValid = true,
		healthRangeEnabled = false,
		healthMin = 0,
		healthMax = 100,
		effectType = 1,
		scoreMode = 2,
		scoreValue = 25,
		allowStack = false,
		emergencyRetainPercent = 20,
		countsAsProtection = true,
		displayPriority = 10,
		rescuePriority = 50,
		color = { r = 0.72, g = 0.30, b = 1.00, a = 0.82 },
		distanceMode = 1,
		customDistance = 27,
		healPriorityThreshold = 70,
		excludeDisplayMode = 1,
	}
end

function NewRuleByPurpose(purpose)
	local rule = NewDefaultHealingRule()
	rule.name = "新规则"
	rule.ids = {}
	rule.purpose = purpose or 5
	if rule.purpose == 2 then
		rule.name = "危险状态"
		rule.sourceMode = 2
		rule.effectType = 2
		rule.scoreMode = 1
		rule.scoreValue = 15
		rule.countsAsProtection = false
		rule.displayPriority = 70
		rule.color = { r = 1.00, g = 0.25, b = 0.12, a = 0.82 }
	elseif rule.purpose == 3 then
		rule.name = "控制/解控"
		rule.sourceMode = 2
		rule.effectType = 4
		rule.scoreMode = 1
		rule.scoreValue = 20
		rule.countsAsProtection = false
		rule.displayPriority = 100
		rule.rescuePriority = 100
		rule.distanceMode = 2
		rule.customDistance = 20
		rule.healPriorityThreshold = 70
		rule.color = { r = 0.72, g = 0.28, b = 1.00, a = 0.84 }
	elseif rule.purpose == 4 then
		rule.name = "不可救援"
		rule.sourceMode = 2
		rule.effectType = 3
		rule.scoreMode = 1
		rule.scoreValue = 0
		rule.countsAsProtection = false
		rule.displayPriority = 120
		rule.excludeDisplayMode = 2
		rule.color = { r = 0.55, g = 0.58, b = 0.62, a = 0.72 }
	elseif rule.purpose == 5 then
		rule.name = "通用自定义"
		rule.sourceMode = 5
		rule.effectType = 2
		rule.scoreMode = 1
		rule.scoreValue = 10
		rule.countsAsProtection = false
		rule.displayPriority = 60
		rule.color = { r = 0.20, g = 0.85, b = 1.00, a = 0.78 }
	end
	return rule
end

defaults = DeepCopy(type(HEALER_CONFIG.Defaults) == "table" and HEALER_CONFIG.Defaults or {})
if type(defaults.rules) ~= "table" or #defaults.rules == 0 then defaults.rules = { NewDefaultHealingRule() } end
defaults.settingsVersion = SETTINGS_VERSION

state = {}

function NormalizeWeights()
	local weights = state.weights
	weights.health = tonumber(weights.health) or defaults.weights.health
	weights.distance = tonumber(weights.distance) or defaults.weights.distance
	weights.missing = tonumber(weights.missing) or defaults.weights.missing
	weights.unprotected = tonumber(weights.unprotected) or defaults.weights.unprotected
	local total = math.max(0, weights.health) + math.max(0, weights.distance) + math.max(0, weights.missing) + math.max(0, weights.unprotected)
	if total <= 0 then
		weights.health = 55
		weights.distance = 15
		weights.missing = 10
		weights.unprotected = 20
		return
	end
	weights.health = Round(math.max(0, weights.health) * 100 / total, 1)
	weights.distance = Round(math.max(0, weights.distance) * 100 / total, 1)
	weights.missing = Round(math.max(0, weights.missing) * 100 / total, 1)
	weights.unprotected = Round(100 - weights.health - weights.distance - weights.missing, 1)
	if weights.unprotected < 0 then
		weights.unprotected = 0
		local subtotal = weights.health + weights.distance + weights.missing
		if subtotal > 0 then
			weights.health = Round(weights.health * 100 / subtotal, 1)
			weights.distance = Round(weights.distance * 100 / subtotal, 1)
			weights.missing = Round(100 - weights.health - weights.distance, 1)
		end
	end
end

function NormalizeTrackedBuff(entry, fallbackColor)
	entry = type(entry) == "table" and entry or {}
	entry.id = math.floor(math.max(0, tonumber(entry.id) or 0))
	entry.name = tostring(entry.name or (entry.id > 0 and ("Buff " .. tostring(entry.id)) or "未命名 Buff"))
	entry.iconPath = tostring(entry.iconPath or entry.icon or entry.path or "")
	entry.enabled = entry.enabled ~= false
	entry.color = CopyColor(entry.color, fallbackColor or { r = 0.72, g = 0.30, b = 1.00, a = 0.84 })
	return entry
end

function NormalizeTrackedBuffList(list)
	local normalized = {}
	local seen = {}
	if type(list) == "table" then
		for _, entry in ipairs(list) do
			entry = NormalizeTrackedBuff(entry)
			if entry.id > 0 and not seen[entry.id] and #normalized < MAX_RULES then
				seen[entry.id] = true
				normalized[#normalized + 1] = entry
			end
		end
	end
	return normalized
end

function NormalizeRule(rule)
	rule.name = tostring(rule.name or "未命名规则")
	rule.enabled = rule.enabled ~= false
	rule.purpose = math.floor(Clamp(rule.purpose or 5, 1, #RULE_PURPOSE_LABELS))
	rule.sourceMode = math.floor(Clamp(rule.sourceMode or 5, 1, #RULE_SOURCE_LABELS))
	rule.matchMode = math.floor(Clamp(rule.matchMode or 1, 1, #RULE_MATCH_LABELS))
	rule.ids = ParseIdList(JoinIdList(rule.ids or {}))
	rule.minStacks = math.floor(Clamp(rule.minStacks or 1, 1, 99))
	rule.minRemainingMs = math.floor(Clamp(rule.minRemainingMs or 0, 0, 3600000))
	rule.unknownRemainingValid = rule.unknownRemainingValid ~= false
	rule.healthRangeEnabled = rule.healthRangeEnabled == true
	rule.healthMin = Clamp(rule.healthMin or 0, 0, 100)
	rule.healthMax = Clamp(rule.healthMax or 100, rule.healthMin, 100)
	rule.effectType = math.floor(Clamp(rule.effectType or 2, 1, #RULE_EFFECT_LABELS))
	rule.scoreMode = math.floor(Clamp(rule.scoreMode or 1, 1, #RULE_SCORE_MODE_LABELS))
	rule.scoreValue = Clamp(rule.scoreValue or 0, 0, 500)
	rule.allowStack = rule.allowStack == true
	rule.emergencyRetainPercent = Clamp(rule.emergencyRetainPercent or 20, 0, 100)
	rule.countsAsProtection = rule.countsAsProtection == true
	rule.displayPriority = math.floor(Clamp(rule.displayPriority or 50, 0, 999))
	rule.rescuePriority = math.floor(Clamp(rule.rescuePriority or 50, 0, 999))
	rule.color = CopyColor(rule.color, { r = 1, g = 0.5, b = 0.1, a = 0.8 })
	rule.distanceMode = math.floor(Clamp(rule.distanceMode or 1, 1, #RULE_DISTANCE_MODE_LABELS))
	rule.customDistance = Clamp(rule.customDistance or 20, 1, 100)
	rule.healPriorityThreshold = Clamp(rule.healPriorityThreshold or 70, 0, 100)
	rule.excludeDisplayMode = math.floor(Clamp(rule.excludeDisplayMode or 1, 1, #EXCLUDE_DISPLAY_LABELS))
	rule.simpleDisplayGroup = rule.simpleDisplayGroup == true
end

local function SafeLoadSavedData(key)
	local ok, value = pcall(function() return ADDON:LoadData(key) end)
	if not ok then return nil, tostring(value) end
	return value, nil
end

local function ClearSavedDataVerified(key)
	local ok, value = pcall(function() return ADDON:ClearData(key) end)
	if not ok then return false, tostring(value) end
	if value ~= false then return true, nil end
	-- Some client builds return false when the key was already empty. Verify the
	-- observable state before treating that as a real failure.
	local remaining, loadErr = SafeLoadSavedData(key)
	if loadErr ~= nil then return false, "清除后验证失败：" .. tostring(loadErr) end
	if remaining ~= nil and remaining ~= false then return false, "ClearData 返回 false 且数据仍存在" end
	return true, nil
end

local function ReplaceSavedData(key, payload)
	local cleared, clearErr = ClearSavedDataVerified(key)
	if not cleared then return false, clearErr end
	local ok, result = pcall(function() return ADDON:SaveData(key, payload) end)
	if not ok then return false, tostring(result) end
	if result == false then return false, "SaveData 返回 false" end
	return true, nil
end

function LoadState()
	stateNeedsMigrationSave = false
	state = DeepCopy(defaults)
	local saved, primaryLoadErr = SafeLoadSavedData(SAVE_KEY_V2)
	local recoveredFromBackup = false
	if type(saved) ~= "table" then
		local backup, backupLoadErr = SafeLoadSavedData(SAVE_KEY_V2_BACKUP)
		if type(backup) == "table" then
			saved = backup
			recoveredFromBackup = true
		elseif primaryLoadErr ~= nil or backupLoadErr ~= nil then
			error("配置读取失败：" .. tostring(primaryLoadErr or "primary empty") .. " / " .. tostring(backupLoadErr or "backup empty"))
		end
	end
	local loadedSettingsVersion = type(saved) == "table" and (tonumber(saved.settingsVersion) or 0) or 0
	stateNeedsMigrationSave = recoveredFromBackup == true
		or (type(saved) == "table" and loadedSettingsVersion < SETTINGS_VERSION)
	if loadedSettingsVersion > SETTINGS_VERSION then
		storageWriteFenceReason = "future_settings_schema:" .. tostring(loadedSettingsVersion) .. ">" .. tostring(SETTINGS_VERSION)
	end
	if type(saved) == "table" then
		for key, value in pairs(saved) do
			state[key] = DeepCopy(value)
		end
	else
		-- Only retain layout/calibration from the v1 series. Old business fields
		-- are intentionally discarded by the clean v2 rescue-score refactor.
		local legacy = SafeLoadSavedData(LEGACY_SAVE_KEY)
		if type(legacy) == "table" then
			stateNeedsMigrationSave = true
			state.panelAnchor = CopyAnchor(legacy.panelAnchor, defaults.panelAnchor, false)
			state.launcherAnchor = CopyAnchor(legacy.launcherAnchor, defaults.launcherAnchor, false)
			state.raidOverlayTop = CopyAnchor(legacy.raidOverlayTop, defaults.raidOverlayTop, true)
			state.raidOverlayBottom = CopyAnchor(legacy.raidOverlayBottom, defaults.raidOverlayBottom, true)
			state.raidOverlayTopRaid2 = CopyAnchor(legacy.raidOverlayTopRaid2, defaults.raidOverlayTopRaid2, true)
			state.raidOverlayBottomRaid2 = CopyAnchor(legacy.raidOverlayBottomRaid2, defaults.raidOverlayBottomRaid2, true)
			state.panelMode = math.floor(Clamp(legacy.recommendPanelMode or defaults.panelMode, 1, 3))
		end
	end
	state.settingsVersion = SETTINGS_VERSION
	state.weights = type(state.weights) == "table" and state.weights or DeepCopy(defaults.weights)
	state.levelThresholds = type(state.levelThresholds) == "table" and state.levelThresholds or DeepCopy(defaults.levelThresholds)
	state.levelColors = type(state.levelColors) == "table" and state.levelColors or DeepCopy(defaults.levelColors)
	for index = 1, 4 do
		state.levelColors[index] = CopyColor(state.levelColors[index], defaults.levelColors[index])
	end
	state.headSizes = type(state.headSizes) == "table" and state.headSizes or DeepCopy(defaults.headSizes)
	for index = 1, 4 do
		state.headSizes[index] = math.floor(Clamp(state.headSizes[index] or defaults.headSizes[index], 12, 60))
	end
	state.rules = type(state.rules) == "table" and state.rules or { NewDefaultHealingRule() }
	while #state.rules > MAX_RULES do
		table.remove(state.rules)
	end
	for index = 1, #state.rules do
		NormalizeRule(state.rules[index])
		if loadedSettingsVersion < 210
			and state.rules[index].name == "持续回血"
			and math.abs((tonumber(state.rules[index].minRemainingMs) or 0) - 2000) < 0.01 then
			-- Presence of 25875/220 is enough to show the protected state.
			state.rules[index].minRemainingMs = 0
		end
		if loadedSettingsVersion < 211
			and state.rules[index].name == "持续回血"
			and math.abs((tonumber(state.rules[index].customDistance) or 0) - 20) < 0.01 then
			-- Migrate only the former default; preserve user-customized distances.
			state.rules[index].customDistance = 27
		end
		if loadedSettingsVersion < 213
			and state.rules[index].name == "持续回血"
			and math.abs((tonumber(state.rules[index].color.r) or 0) - 1.00) < 0.01
			and math.abs((tonumber(state.rules[index].color.g) or 0) - 0.48) < 0.01
			and math.abs((tonumber(state.rules[index].color.b) or 0) - 0.08) < 0.01 then
			-- Swap the former default protected orange to the new protected purple.
			state.rules[index].color = { r = 0.72, g = 0.30, b = 1.00, a = 0.82 }
		end
	end

	-- v3.0.1 restores the important status-color workflow as a small, explicit
	-- tracked-Buff list.  When upgrading an existing user, preserve any status
	-- IDs/colors they already configured in the old rule editor instead of
	-- silently discarding that work.
	if loadedSettingsVersion < 217 and type(saved) == "table" and type(saved.trackedBuffs) ~= "table" then
		local migrated = {}
		local seen = {}
		for _, rule in ipairs(state.rules or {}) do
			if rule.enabled ~= false then
				for _, id in ipairs(rule.ids or {}) do
					id = tonumber(id)
					if id ~= nil and id > 0 and not seen[id] and #migrated < MAX_RULES then
						seen[id] = true
						migrated[#migrated + 1] = {
							id = id,
							name = tostring(rule.name or ("Buff " .. tostring(id))),
							enabled = true,
							color = CopyColor(rule.color, defaults.trackedBuffs[1].color),
						}
					end
				end
			end
		end
		state.trackedBuffs = #migrated > 0 and migrated or DeepCopy(defaults.trackedBuffs)
	end
	state.trackedBuffs = NormalizeTrackedBuffList(state.trackedBuffs)
	if #state.trackedBuffs == 0 and loadedSettingsVersion <= 0 then
		state.trackedBuffs = NormalizeTrackedBuffList(DeepCopy(defaults.trackedBuffs))
	end
	state.roleScores = type(state.roleScores) == "table" and state.roleScores or DeepCopy(defaults.roleScores)
	state.roleScores.normal = tonumber(state.roleScores.normal) or 0
	state.roleScores.mainTank = tonumber(state.roleScores.mainTank) or 15
	state.roleScores.offTank = tonumber(state.roleScores.offTank) or 10
	state.roleScores.healer = tonumber(state.roleScores.healer) or 8
	state.roleScores.unknown = tonumber(state.roleScores.unknown) or 0
	state.roleOverrides = type(state.roleOverrides) == "table" and state.roleOverrides or {}
	state.panelAnchor = CopyAnchor(state.panelAnchor, defaults.panelAnchor, false)
	state.recommendWidth = math.floor(Clamp(tonumber(state.recommendWidth) or defaults.recommendWidth, 430, 1000))
	state.recommendHeight = math.floor(Clamp(tonumber(state.recommendHeight) or defaults.recommendHeight, 180, 800))
	state.configAnchor = CopyAnchor(state.configAnchor, defaults.configAnchor, false)
	state.launcherAnchor = CopyAnchor(state.launcherAnchor, defaults.launcherAnchor, false)

	-- v3.0.2 / settings 218: move only the untouched historical launcher
	-- into the shared 2x2 cluster next to Replicated Suite's R entry. Any
	-- launcher the player actually dragged keeps its saved coordinates.
	if loadedSettingsVersion < 218 then
		local oldClusterDefault = state.launcherAnchor.horizontal == "LEFT"
			and state.launcherAnchor.vertical == "TOP"
			and math.abs((tonumber(state.launcherAnchor.offsetX) or 0) - 12) < 0.01
			and math.abs((tonumber(state.launcherAnchor.offsetY) or 0) - 150) < 0.01
		if oldClusterDefault then
			state.launcherAnchor = CopyAnchor(defaults.launcherAnchor, defaults.launcherAnchor, false)
		end
	end

	-- v2.2 changes the untouched launcher default from the right side to a
	-- guaranteed visible left-top safe area. Preserve positions that users
	-- actually dragged, and migrate only known historical default anchors or
	-- incompatible pre-bootstrap implementations.
	local launcherWasOldRightDefault =
		state.launcherAnchor.horizontal == "RIGHT"
		and state.launcherAnchor.vertical == "TOP"
		and math.abs((tonumber(state.launcherAnchor.offsetX) or 0) - 24) < 0.01
		and math.abs((tonumber(state.launcherAnchor.offsetY) or 0) - 148) < 0.01
	local launcherIsCompatibleBootstrap =
		state.launcherImplementation == "bootstrap_v21"
		or state.launcherImplementation == defaults.launcherImplementation
	if launcherWasOldRightDefault or not launcherIsCompatibleBootstrap then
		state.launcherAnchor = CopyAnchor(defaults.launcherAnchor, defaults.launcherAnchor, false)
	end
	state.launcherImplementation = defaults.launcherImplementation

	-- v2.9: the three Replicated launchers share one 104x26 vertical stack.
	-- Migrate only the untouched historical healer position; user-dragged
	-- positions are preserved and merely clamped by LayoutLauncher.
	if loadedSettingsVersion < 215 then
		local oldLauncherDefault = state.launcherAnchor.horizontal == "LEFT"
			and state.launcherAnchor.vertical == "TOP"
			and math.abs((tonumber(state.launcherAnchor.offsetX) or 0) - 12) < 0.01
			and math.abs((tonumber(state.launcherAnchor.offsetY) or 0) - 118) < 0.01
		if oldLauncherDefault then
			state.launcherAnchor = CopyAnchor(defaults.launcherAnchor, defaults.launcherAnchor, false)
		end
		-- Preserve the user's existing runtime choice. Older builds forced
		-- state.enabled=false during this layout migration, which made the healer
		-- appear to stop working immediately after an addon update.
	end
	if loadedSettingsVersion == 218 and state.enabled == false then
		-- v218 may already have persisted the unintended forced-off migration to
		-- both the primary and backup save. Repair that regression exactly once.
		-- After this v219 save, any later user toggle is authoritative again.
		state.enabled = true
	end
	if loadedSettingsVersion < 216 then
		-- Old healer launcher saves are not trustworthy because the previous drag
		-- path mixed effective and logical coordinates. Normalize the primary
		-- launcher once; from v216 onward user dragging is preserved correctly.
		state.launcherAnchor = CopyAnchor(defaults.launcherAnchor, defaults.launcherAnchor, false)
	end

	state.pageSwitcherAnchor = CopyAnchor(state.pageSwitcherAnchor, defaults.pageSwitcherAnchor, false)
	state.raidOverlayTop = CopyAnchor(state.raidOverlayTop, defaults.raidOverlayTop, true)
	state.raidOverlayBottom = CopyAnchor(state.raidOverlayBottom, defaults.raidOverlayBottom, true)
	state.raidOverlayTopRaid2 = CopyAnchor(state.raidOverlayTopRaid2, defaults.raidOverlayTopRaid2, true)
	state.raidOverlayBottomRaid2 = CopyAnchor(state.raidOverlayBottomRaid2, defaults.raidOverlayBottomRaid2, true)
	if loadedSettingsVersion < 209 then
		local function UsesOldOverlayDefault(rect, oldY)
			return rect.horizontal == "LEFT"
				and rect.vertical == "TOP"
				and math.abs((tonumber(rect.offsetX) or 0) - 0) < 0.01
				and math.abs((tonumber(rect.offsetY) or 0) - oldY) < 0.01
				and math.abs((tonumber(rect.width) or 0) - 500) < 0.01
				and math.abs((tonumber(rect.height) or 0) - 176) < 0.01
		end
		if UsesOldOverlayDefault(state.raidOverlayTop, 175) then
			state.raidOverlayTop = DeepCopy(defaults.raidOverlayTop)
		end
		if UsesOldOverlayDefault(state.raidOverlayBottom, 359) then
			state.raidOverlayBottom = DeepCopy(defaults.raidOverlayBottom)
		end
	end
	if loadedSettingsVersion < 210
		and math.abs((tonumber(state.enterThreshold) or 0) - 90) < 0.01
		and math.abs((tonumber(state.exitThreshold) or 0) - 95) < 0.01 then
		-- New default: every damaged teammate in healing range is a candidate.
		-- Preserve thresholds that the user had already customized.
		state.enterThreshold = 100
		state.exitThreshold = 100
	end
	if loadedSettingsVersion < 212
		and math.abs((tonumber(state.emergencyThreshold) or 0) - 20) < 0.01 then
		-- Migrate only the former default; preserve user-customized thresholds.
		state.emergencyThreshold = 50
	end
	state.panelMode = math.floor(Clamp(state.panelMode or 1, 1, 3))
	state.recommendSortMode = math.floor(Clamp(state.recommendSortMode or 1, 1, 2))
	-- settings 221 restores the player-facing team-overlay animation selector.
	-- Compact v3 settings hid that selector while the historical default was
	-- breathing (2), so old untouched saves would otherwise keep breathing
	-- forever. Migrate that former default once; fast blink (3) and all future
	-- explicit choices remain authoritative.
	if loadedSettingsVersion < 221 and tonumber(state.raidEffectMode) == 2 then
		state.raidEffectMode = 1
	end
	state.raidEffectMode = math.floor(Clamp(state.raidEffectMode or 1, 1, 3))
	state.headEffectMode = math.floor(Clamp(state.headEffectMode or 1, 1, 3))
	state.headShapeMode = math.floor(Clamp(state.headShapeMode or 4, 1, 4))
	state.raidRankCount = math.floor(Clamp(state.raidRankCount or 10, 0, 50))
	state.raidRankFontSize = math.floor(Clamp(state.raidRankFontSize or 10, 8, 20))
	state.raidRankAlpha = Clamp(state.raidRankAlpha or 1, 0.1, 1)
	state.raidRankCorner = math.floor(Clamp(state.raidRankCorner or 2, 1, 4))
	state.raidRankOffsetX = Clamp(state.raidRankOffsetX or 1, -20, 20)
	state.raidRankOffsetY = Clamp(state.raidRankOffsetY or 1, -20, 20)
	state.raidCalibrationSection = math.floor(Clamp(state.raidCalibrationSection or 1, 1, 4))
	state.raidCalibrationScope = math.floor(Clamp(state.raidCalibrationScope or 1, 1, 3))
	state.fullRecommendCount = math.floor(Clamp(state.fullRecommendCount or 10, 1, 100))
	state.miniRecommendCount = math.floor(Clamp(state.miniRecommendCount or 3, 1, 3))
	state.headMarkerCount = math.floor(Clamp(state.headMarkerCount or 5, 1, 50))
	state.healthScanMs = math.floor(Clamp(state.healthScanMs or 150, 100, 1000))
	state.buffScanMs = math.floor(Clamp(state.buffScanMs or 300, 200, 2000))
	state.enterThreshold = Clamp(state.enterThreshold or defaults.enterThreshold, 1, 100)
	state.exitThreshold = Clamp(state.exitThreshold or defaults.exitThreshold, state.enterThreshold, 100)
	state.selfThreshold = Clamp(state.selfThreshold or 70, 1, 100)
	state.emergencyThreshold = Clamp(state.emergencyThreshold or defaults.emergencyThreshold or 50, 1, 100)
	state.lowHealthThreshold = Clamp(state.lowHealthThreshold or defaults.lowHealthThreshold or 70, state.emergencyThreshold, 100)
	state.proximityMode = state.proximityMode ~= false
	-- The public UI has one authoritative healing distance.  Keep the legacy
	-- proximity field mirrored only for persistence compatibility.
	state.proximityDistance = Clamp(tonumber(state.maxDistance) or tonumber(state.proximityDistance) or 27, 1, 100)
	state.maxDistance = state.proximityDistance
	state.proximityColor = CopyColor(state.proximityColor, defaults.proximityColor)
	state.lowHealthColor = CopyColor(state.lowHealthColor, defaults.lowHealthColor)
	state.emergencyColor = CopyColor(state.emergencyColor, defaults.emergencyColor)
	if loadedSettingsVersion < 217 then
		-- v3.0.1 promotes only the untouched old pale-blue range tint to pink; a
		-- user-customized color is preserved. New low/emergency colors are added
		-- independently so upgrading never wipes a deliberate RGB choice.
		state.proximityMode = true
		local oldRange = type(saved) == "table" and saved.proximityColor or nil
		local usesOldBlue = type(oldRange) == "table"
			and math.abs((tonumber(oldRange.r) or 0) - 0.40) < 0.01
			and math.abs((tonumber(oldRange.g) or 0) - 0.72) < 0.01
			and math.abs((tonumber(oldRange.b) or 0) - 1.00) < 0.01
		if type(saved) ~= "table" or oldRange == nil or usesOldBlue then
			state.proximityColor = CopyColor(defaults.proximityColor)
		end
		if type(saved) ~= "table" or type(saved.lowHealthColor) ~= "table" then
			state.lowHealthColor = CopyColor(defaults.lowHealthColor)
		end
		if type(saved) ~= "table" or type(saved.emergencyColor) ~= "table" then
			state.emergencyColor = CopyColor(defaults.emergencyColor)
		end
	end
	state.levelThresholds.attention = Clamp(state.levelThresholds.attention or 40, 1, 98)
	state.levelThresholds.high = Clamp(state.levelThresholds.high or 60, state.levelThresholds.attention + 1, 99)
	state.levelThresholds.emergency = Clamp(state.levelThresholds.emergency or 80, state.levelThresholds.high + 1, 100)
	NormalizeWeights()
	if recoveredFromBackup then
		pcall(function()
			X2Chat:DispatchChatMessage(CMF_SYSTEM, "Replicated 治疗推荐器：主配置不可用，已从备份恢复。")
		end)
	end
end

lastSaveError = nil
function SaveState()
	if storageWriteFenceReason ~= nil then
		lastSaveError = "配置写保护：" .. tostring(storageWriteFenceReason)
		if storageWriteFenceWarned ~= true then
			storageWriteFenceWarned = true
			pcall(function()
				X2Chat:DispatchChatMessage(CMF_SYSTEM, "Replicated 治疗推荐器：检测到不可安全覆盖的配置，本次会话保持只读保存保护。")
			end)
		end
		return false
	end
	-- Write the latest complete snapshot to backup first. Never clear the primary
	-- unless a recoverable copy is already committed.
	local backupOk, backupErr = ReplaceSavedData(SAVE_KEY_V2_BACKUP, state)
	if not backupOk then
		lastSaveError = "备份保存失败：" .. tostring(backupErr or "unknown")
		return false
	end
	local primaryOk, primaryErr = ReplaceSavedData(SAVE_KEY_V2, state)
	if not primaryOk then
		lastSaveError = "主配置保存失败（备份已保留）：" .. tostring(primaryErr or "unknown")
		return false
	end
	lastSaveError = nil
	return true
end

loadOk, loadError = pcall(LoadState)
if not loadOk then
	storageWriteFenceReason = "load_failed"
	state = DeepCopy(defaults)
	NormalizeWeights()
	-- A read/normalization error must not clear or overwrite the user's previous
	-- data. Use defaults for this session and leave storage untouched for recovery.
	pcall(function()
		X2Chat:DispatchChatMessage(
			CMF_SYSTEM,
			"Replicated 治疗推荐器：读取配置失败，本次使用默认配置；原保存数据未被覆盖。"
		)
	end)
else
	if storageWriteFenceReason == nil and stateNeedsMigrationSave == true then
		SaveState()
	elseif storageWriteFenceReason ~= nil then
		storageWriteFenceWarned = true
		pcall(function()
			X2Chat:DispatchChatMessage(CMF_SYSTEM, "Replicated 治疗推荐器：检测到更高版本配置，已读取已知字段但不会覆盖原保存。")
		end)
	end
end

-- Suite owns module lifecycle. Preserve every Healer preference, but never let
-- the historical standalone `enabled` flag auto-start business work while the
-- professional module is disabled in Suite. This assignment is intentionally
-- session-only and is not written back here.
if ReplicatedSuiteEmbedded == true then state.enabled = false end

-----------------------------------------------------------------------
-- Runtime state
-----------------------------------------------------------------------

roster = {}
rosterByKey = {}
rosterMode = "none"
healthSnapshot = {}
statusCache = {}
statusScanDiagnostics = {
	scans = 0,
	tooltipOnly = 0,
	skippedNoId = 0,
	lastMember = "",
	lastBuffCount = 0,
	lastDebuffCount = 0,
	lastHiddenCount = 0,
	lastResolved = 0,
	lastScannedAt = 0,
}
candidateMemory = {}
recommendations = {}
unavailable = {}
previousRanks = {}
autoRaidPage = nil
currentVisibleRaidPage = 1
autoRaidDetectionAvailable = false
calibrationMode = false
animationClock = 0
healthElapsed = 10000
buffElapsed = 10000
rosterElapsed = 10000
visualElapsed = 10000
metricsElapsed = 10000
-- TEAM_MEMBERS_CHANGED is emitted while the native raidTeamManager may still
-- be creating/showing member widgets. Never touch team unit tokens or mutate
-- overlay z-order in that callback stack. The update driver waits for this
-- settle window before rebuilding roster/status/health state.
teamRosterSettleRemainingMs = 0
teamRosterZOrderPending = false
recommendScrollOffset = 0
ruleListOffset = 0
selectedRuleIndex = 1
selectedRoleOverrideIndex = 1
roleOverrideOffset = 0

-- These names are intentionally shared with the next toc.g chunk.  They are
-- globals because separate Lua files do not share local scope; no declaration
-- statement is needed (or valid) for globals in Lua.

function GetUnitKey(raidIndex, memberIndex, unitId)
	return tostring(raidIndex or 1) .. ":" .. tostring(memberIndex or 0) .. ":" .. tostring(unitId or "")
end

function FindNormalRaidUnit(memberIndex)
	local ids = { string.format("team%d", memberIndex), string.format("team%02d", memberIndex) }
	for _, unitId in ipairs(ids) do
		local name = SafeUnitCall("UnitName", unitId)
		if name ~= nil then
			return unitId, name
		end
	end
	return nil, nil
end

function FindCoRaidUnit(raidIndex, memberIndex)
	local ids = {
		string.format("team_%d_%d", raidIndex, memberIndex),
		string.format("team_%02d_%02d", raidIndex, memberIndex),
	}
	for _, unitId in ipairs(ids) do
		local name = SafeUnitCall("UnitName", unitId)
		if name ~= nil then
			return unitId, name
		end
	end
	return nil, nil
end

function SafeUnitCall(methodName, unitId, ...)
	if X2Unit == nil then return nil end
	local method = X2Unit[methodName]
	if type(method) ~= "function" then return nil end
	local args = { ... }
	local argCount = select("#", ...)
	local function Fetch()
		local ok, value = pcall(function() return method(X2Unit, unitId, unpack(args, 1, argCount)) end)
		if not ok then return nil end
		return value
	end
	if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.Observation ~= nil
		and (methodName == "UnitName" or methodName == "UnitDistance" or methodName == "UnitHealth" or methodName == "UnitMaxHealth") then
		local ttl = methodName == "UnitName" and 250 or 75
		return ReplicatedSuite.Observation:ReadField("professional:healer", unitId, methodName, Fetch, ttl)
	end
	return Fetch()
end

function SafeUnitScreenPosition(unitId)
	if X2Unit == nil or type(X2Unit.GetUnitScreenPosition) ~= "function" then return nil, nil, nil end
	local ok, x, y, z = pcall(function() return X2Unit:GetUnitScreenPosition(unitId) end)
	if not ok then return nil, nil, nil end
	return tonumber(x), tonumber(y), tonumber(z)
end

function ReadDistance(unitId, isSelf)
	local info = SafeUnitCall("UnitDistance", unitId)
	local distance = nil
	if type(info) == "table" then
		distance = tonumber(info.distance)
	else
		distance = tonumber(info)
	end
	if distance == nil and isSelf then
		return 0
	end
	return distance and math.max(0, distance) or nil
end

function GetOfficialRole(raidIndex, memberIndex)
	if X2Team == nil or X2Team.GetRole == nil then
		return nil
	end
	local ok, value = pcall(function()
		return X2Team:GetRole(raidIndex, memberIndex)
	end)
	if ok then
		return value
	end
	return nil
end

function ClassifyRole(member)
	local override = state.roleOverrides[member.name]
	if override ~= nil then
		return math.floor(Clamp(override, 1, #ROLE_LABELS))
	end
	local raw = member.officialRole
	if raw == nil then
		return 5
	end
	local text = string.lower(tostring(raw))
	if string.find(text, "main") and string.find(text, "tank") then
		return 2
	end
	if string.find(text, "tank") then
		return 3
	end
	if string.find(text, "heal") then
		return 4
	end
	local numeric = tonumber(raw)
	if numeric == 1 then
		return 2
	elseif numeric == 2 then
		return 4
	elseif numeric ~= nil and numeric > 0 then
		return 1
	end
	return 5
end

function RebuildRoster()
	roster = {}
	rosterByKey = {}
	local playerName = SafeUnitCall("UnitName", "player")
	local _, coName = FindCoRaidUnit(1, 1)
	local _, normalName = FindNormalRaidUnit(1)
	if coName ~= nil then
		rosterMode = "coraid"
		for raidIndex = 1, 2 do
			for memberIndex = 1, MAX_RAID_MEMBERS do
				local unitId, name = FindCoRaidUnit(raidIndex, memberIndex)
				if unitId ~= nil and name ~= nil then
					local member = {
						unitId = unitId,
						name = name,
						raidIndex = raidIndex,
						memberIndex = memberIndex,
						isSelf = playerName ~= nil and name == playerName,
						officialRole = GetOfficialRole(raidIndex, memberIndex),
					}
					member.key = GetUnitKey(raidIndex, memberIndex, unitId)
					member.role = ClassifyRole(member)
					roster[#roster + 1] = member
					rosterByKey[member.key] = member
				end
			end
		end
	elseif normalName ~= nil then
		rosterMode = "raid"
		for memberIndex = 1, MAX_RAID_MEMBERS do
			local unitId, name = FindNormalRaidUnit(memberIndex)
			if unitId ~= nil and name ~= nil then
				local member = {
					unitId = unitId,
					name = name,
					raidIndex = 1,
					memberIndex = memberIndex,
					isSelf = playerName ~= nil and name == playerName,
					officialRole = GetOfficialRole(1, memberIndex),
				}
				member.key = GetUnitKey(1, memberIndex, unitId)
				member.role = ClassifyRole(member)
				roster[#roster + 1] = member
				rosterByKey[member.key] = member
			end
		end
	elseif playerName ~= nil then
		rosterMode = "solo"
		local member = {
			unitId = "player",
			name = playerName,
			raidIndex = 1,
			memberIndex = 1,
			isSelf = true,
			role = 1,
		}
		member.key = GetUnitKey(1, 1, "player")
		roster[1] = member
		rosterByKey[member.key] = member
	else
		rosterMode = "none"
	end
end

function DetectVisibleRaidPage()
	if rosterMode ~= "coraid" then
		autoRaidPage = 1
		autoRaidDetectionAvailable = true
		return 1
	end
	local score = { 0, 0 }
	local comparisons = 0
	for memberIndex = 1, 10 do
		local aliasName = SafeUnitCall("UnitName", string.format("team%d", memberIndex))
		if aliasName ~= nil then
			comparisons = comparisons + 1
			local name1 = SafeUnitCall("UnitName", string.format("team_1_%d", memberIndex))
			local name2 = SafeUnitCall("UnitName", string.format("team_2_%d", memberIndex))
			if aliasName == name1 then
				score[1] = score[1] + 1
			end
			if aliasName == name2 then
				score[2] = score[2] + 1
			end
		end
	end
	if comparisons > 0 and score[1] ~= score[2] and math.max(score[1], score[2]) >= 2 then
		autoRaidPage = score[1] > score[2] and 1 or 2
		autoRaidDetectionAvailable = true
	else
		autoRaidPage = nil
		autoRaidDetectionAvailable = false
	end
	return autoRaidPage
end

function ResolveVisibleRaidPage()
	if rosterMode ~= "coraid" then
		currentVisibleRaidPage = 1
	elseif state.manualRaidPageLocked then
		currentVisibleRaidPage = state.manualRaidPage
	else
		local detected = DetectVisibleRaidPage()
		currentVisibleRaidPage = detected or state.manualRaidPage or 1
	end
	return currentVisibleRaidPage
end

function ReadTooltip(unitId, index, sourceBit)
	local tooltip = nil
	if sourceBit == SOURCE_BUFF and X2Unit.UnitBuffTooltip ~= nil then
		tooltip = SafeUnitCall("UnitBuffTooltip", unitId, index)
	elseif sourceBit == SOURCE_DEBUFF and X2Unit.UnitDeBuffTooltip ~= nil then
		tooltip = SafeUnitCall("UnitDeBuffTooltip", unitId, index)
	elseif sourceBit == SOURCE_HIDDEN and X2Unit.UnitHiddenBuffTooltip ~= nil then
		tooltip = SafeUnitCall("UnitHiddenBuffTooltip", unitId, index)
	end
	return type(tooltip) == "table" and tooltip or nil
end

local function StatusId(info)
	if type(info) ~= "table" then return nil end
	return tonumber(
		info.buff_id or info.buffId or info.buffID or info.id
		or info.buffType or info.buff_type or info.type
	)
end

local function StatusTimeLeft(info)
	if type(info) ~= "table" then return nil end
	return tonumber(
		info.timeLeft or info.time_left or info.remainTime
		or info.remainingTime or info.remain_time
	)
end

local function StatusIcon(info)
	if type(info) ~= "table" then return nil end
	for _,key in ipairs({"path","iconPath","icon_path","icon","skillIcon","skill_icon","texture"}) do
		local value=info[key]
		if type(value)=="string" and value~="" then return value end
	end
	return nil
end

function MergeStatus(statuses, extra, tooltip, sourceBit)
	extra = type(extra) == "table" and extra or {}
	tooltip = type(tooltip) == "table" and tooltip or {}
	local extraId = StatusId(extra)
	local tooltipId = StatusId(tooltip)
	local id = extraId or tooltipId
	if id == nil then
		statusScanDiagnostics.skippedNoId = (tonumber(statusScanDiagnostics.skippedNoId) or 0) + 1
		return
	end
	if extraId == nil and tooltipId ~= nil then
		statusScanDiagnostics.tooltipOnly = (tonumber(statusScanDiagnostics.tooltipOnly) or 0) + 1
	end

	local stack = tonumber(tooltip.stack or tooltip.stackCount or tooltip.count)
		or tonumber(extra.stack or extra.stackCount or extra.count) or 1
	local timeLeft = StatusTimeLeft(tooltip) or StatusTimeLeft(extra)
	local name = tostring(tooltip.name or tooltip.buffName or extra.name or extra.buffName or id)
	local iconPath = StatusIcon(tooltip) or StatusIcon(extra) or ""
	local entry = statuses[id]
	if entry == nil then
		entry = {
			id = id,
			stack = stack,
			timeLeft = timeLeft,
			timeKnown = timeLeft ~= nil,
			sourceMask = sourceBit,
			name = name,
			iconPath = iconPath,
		}
		statuses[id] = entry
	else
		entry.stack = math.max(entry.stack or 1, stack)
		entry.sourceMask = (entry.sourceMask or 0) + (entry.sourceMask % (sourceBit * 2) < sourceBit and sourceBit or 0)
		if (entry.name == nil or entry.name == "" or entry.name == tostring(entry.id)) and name ~= "" then entry.name = name end
		if (entry.iconPath == nil or entry.iconPath == "") and iconPath ~= "" then entry.iconPath = iconPath end
		if timeLeft ~= nil then
			if not entry.timeKnown or timeLeft > (entry.timeLeft or 0) then
				entry.timeLeft = timeLeft
			end
			entry.timeKnown = true
		end
	end
end

function ScanUnitStatuses(member)
	local statuses = {}
	-- Extra parentheses force exactly one Lua result. This client returns no
	-- values (rather than nil) for temporarily invalid team units.
	local buffCount = tonumber(SafeUnitCall("UnitBuffCount", member.unitId)) or 0
	for index = 1, buffCount do
		MergeStatus(statuses, SafeUnitCall("UnitBuff", member.unitId, index), ReadTooltip(member.unitId, index, SOURCE_BUFF), SOURCE_BUFF)
	end
	local debuffCount = tonumber(SafeUnitCall("UnitDeBuffCount", member.unitId)) or 0
	for index = 1, debuffCount do
		MergeStatus(statuses, SafeUnitCall("UnitDeBuff", member.unitId, index), ReadTooltip(member.unitId, index, SOURCE_DEBUFF), SOURCE_DEBUFF)
	end
	local hiddenCount = tonumber(SafeUnitCall("UnitHiddenBuffCount", member.unitId)) or 0
	for index = 1, hiddenCount do
		MergeStatus(statuses, SafeUnitCall("UnitHiddenBuff", member.unitId, index), ReadTooltip(member.unitId, index, SOURCE_HIDDEN), SOURCE_HIDDEN)
	end

	local resolved = 0
	for _ in pairs(statuses) do resolved = resolved + 1 end
	statusScanDiagnostics.scans = (tonumber(statusScanDiagnostics.scans) or 0) + 1
	statusScanDiagnostics.lastMember = tostring(member.name or member.unitId or member.key or "")
	statusScanDiagnostics.lastBuffCount = buffCount
	statusScanDiagnostics.lastDebuffCount = debuffCount
	statusScanDiagnostics.lastHiddenCount = hiddenCount
	statusScanDiagnostics.lastResolved = resolved
	statusScanDiagnostics.lastScannedAt = animationClock
	statusCache[member.key] = { statuses = statuses, scannedAt = animationClock }
	return statuses
end

function GetStatuses(member, forceRefresh)
	local cached = statusCache[member.key]
	if forceRefresh or cached == nil then
		return ScanUnitStatuses(member)
	end
	return cached.statuses
end

function ScanAllStatuses()
	for _, member in ipairs(roster) do
		ScanUnitStatuses(member)
	end
end

function SourceModeAccepts(sourceMode, sourceMask)
	if sourceMode == 1 then
		return sourceMask % 2 == 1
	elseif sourceMode == 2 then
		return math.floor(sourceMask / SOURCE_DEBUFF) % 2 == 1
	elseif sourceMode == 3 then
		return math.floor(sourceMask / SOURCE_HIDDEN) % 2 == 1
	elseif sourceMode == 4 then
		return sourceMask % 2 == 1 or math.floor(sourceMask / SOURCE_DEBUFF) % 2 == 1
	end
	return sourceMask > 0
end

function IsStatusValidForRule(status, rule)
	if status == nil or not SourceModeAccepts(rule.sourceMode, status.sourceMask or 0) then
		return false
	end
	if (status.stack or 1) < rule.minStacks then
		return false
	end
	if status.timeKnown then
		if (status.timeLeft or 0) < rule.minRemainingMs then
			return false
		end
	elseif not rule.unknownRemainingValid then
		return false
	end
	return true
end

function RuleMatches(rule, statuses, healthPercent, distance)
	if not rule.enabled or #rule.ids == 0 then
		return false, {}
	end
	if rule.healthRangeEnabled and (healthPercent < rule.healthMin or healthPercent > rule.healthMax) then
		return false, {}
	end
	local ruleDistance = rule.distanceMode == 2 and rule.customDistance or state.maxDistance
	if distance == nil or distance > ruleDistance then
		return false, {}
	end
	local matched = {}
	for _, id in ipairs(rule.ids) do
		if IsStatusValidForRule(statuses[id], rule) then
			matched[#matched + 1] = id
		elseif rule.matchMode == 2 then
			return false, {}
		end
	end
	if rule.matchMode == 1 then
		return #matched > 0, matched
	end
	return #matched == #rule.ids, matched
end

function FindTrackedBuffMatch(statuses)
	if type(statuses) ~= "table" then
		return nil, nil
	end
	for index, tracked in ipairs(state.trackedBuffs or {}) do
		if tracked.enabled ~= false and tracked.id ~= nil then
			local status = statuses[tonumber(tracked.id)]
			if status ~= nil then
				return tracked, status, index
			end
		end
	end
	return nil, nil, nil
end

-- Display priority is deliberately deterministic and separate from rescue
-- scoring: emergency > matched condition group > legacy tracked Buff >
-- low health > in-range base.  Simple condition groups therefore affect only
-- presentation and never silently change rescue scoring.
function ResolveHealingDisplayState(healthPercent, distance, statuses, highestDisplayRule)
	if healthPercent == nil or healthPercent <= 0 or distance == nil or distance > state.maxDistance then
		return nil, nil, 0, nil
	end
	if healthPercent <= state.emergencyThreshold then
		return CopyColor(state.emergencyColor), "紧急生命", 5, nil
	end
	if highestDisplayRule ~= nil and highestDisplayRule.rule ~= nil then
		local rule = highestDisplayRule.rule
		return CopyColor(rule.color), tostring(rule.name or "状态条件"), 4, rule
	end
	if not HasSimpleDisplayGroups() then
		local tracked, status = FindTrackedBuffMatch(statuses)
		if tracked ~= nil then
			local displayName = status ~= nil and status.name or tracked.name
			return CopyColor(tracked.color), tostring(displayName or tracked.name or "追踪 Buff"), 3, tracked
		end
	end
	if healthPercent <= state.lowHealthThreshold then
		return CopyColor(state.lowHealthColor), "低血量", 2, nil
	end
	return CopyColor(state.proximityColor), "治疗范围", 1, nil
end

function HealthDangerScore(healthPercent)
	local danger = Clamp(1 - healthPercent / 100, 0, 1)
	if state.healthCurveMode == 1 then
		return danger
	end
	local exponent = state.healthAccelMode == 1 and 1.35 or (state.healthAccelMode == 3 and 2.25 or 1.75)
	return danger ^ exponent
end

function DistanceScore(distance)
	local normalized = Clamp(distance / math.max(1, state.maxDistance), 0, 1)
	if state.distanceCurveMode == 1 then
		return 1 - normalized
	end
	local edgeStart = Clamp(1 - state.distanceEdgePercent / 100, 0.05, 0.95)
	if normalized <= edgeStart then
		return 1 - (normalized / edgeStart) * 0.25
	end
	local edgeProgress = (normalized - edgeStart) / math.max(0.01, 1 - edgeStart)
	return Clamp(0.75 * (1 - edgeProgress * edgeProgress), 0, 1)
end

function MissingHealthScore(missingHealth)
	local sensitivity = math.max(1, state.missingSensitivity)
	return 1 - math.exp(-math.max(0, missingHealth) / sensitivity)
end

function GetRoleScore(role)
	if not state.roleScoringEnabled then
		return 0
	end
	if role == 2 then
		return state.roleScores.mainTank or 0
	elseif role == 3 then
		return state.roleScores.offTank or 0
	elseif role == 4 then
		return state.roleScores.healer or 0
	elseif role == 5 then
		return state.roleScores.unknown or 0
	end
	return state.roleScores.normal or 0
end

function GetLevelForScore(score, forceEmergency, healthPercent)
	if forceEmergency or healthPercent <= state.emergencyThreshold or score >= state.levelThresholds.emergency then
		return 4
	elseif score >= state.levelThresholds.high then
		return 3
	elseif score >= state.levelThresholds.attention then
		return 2
	end
	return 1
end

function HasSimpleDisplayGroups()
	for _, rule in ipairs(state.rules or {}) do
		if rule ~= nil and rule.simpleDisplayGroup == true then return true end
	end
	return false
end

function HasActiveStatusDisplayTracking()
	local hasSimpleGroups = HasSimpleDisplayGroups()
	if hasSimpleGroups then
		for _, rule in ipairs(state.rules or {}) do
			if rule ~= nil and rule.simpleDisplayGroup == true and rule.enabled ~= false
				and type(rule.ids) == "table" and #rule.ids > 0 then return true end
		end
		return false
	end
	-- Compatibility only: legacy direct Buff colors remain active until the user
	-- creates the first new condition group.  From that point the group model is
	-- the sole display-color Authority, avoiding two hidden systems fighting.
	for _, tracked in ipairs(state.trackedBuffs or {}) do
		if tracked ~= nil and tracked.enabled ~= false then return true end
	end
	return false
end

function FindHighestDisplayRuleMatch(statuses, healthPercent, distance)
	local best = nil
	for ruleIndex, rule in ipairs(state.rules or {}) do
		if rule.simpleDisplayGroup == true then
			local matched, matchedIds = RuleMatches(rule, statuses or {}, healthPercent, distance)
			if matched then
				local candidate = { rule = rule, ruleIndex = ruleIndex, matchedIds = matchedIds }
				if best == nil
					or rule.displayPriority > best.rule.displayPriority
					or (rule.displayPriority == best.rule.displayPriority and ruleIndex < best.ruleIndex) then
					best = candidate
				end
			end
		end
	end
	return best
end

function EvaluateMember(member)
	local snapshot = healthSnapshot[member.key]
	if snapshot == nil or snapshot.currentHealth <= 0 or snapshot.maxHealth <= 0 or snapshot.distance == nil then
		candidateMemory[member.key] = nil
		return nil, nil
	end
	local healthPercent = snapshot.healthPercent
	local distance = snapshot.distance
	if distance > state.maxDistance then
		candidateMemory[member.key] = nil
		return nil, nil
	end

	local cached = statusCache[member.key]
	local shouldRefresh = cached == nil
		or (healthPercent <= state.emergencyThreshold and animationClock - (cached.scannedAt or 0) > 80)
		or (healthPercent <= (member.isSelf and state.selfThreshold or state.enterThreshold)
			and animationClock - (cached and cached.scannedAt or 0) > state.buffScanMs)
		or (HasActiveStatusDisplayTracking()
			and animationClock - (cached and cached.scannedAt or 0) > state.buffScanMs)
	local statuses = GetStatuses(member, shouldRefresh)
	local matchedRules = {}
	local exclusion = nil
	local forceEmergency = false
	local forcePriority = 0
	local hasProtection = false
	local highestProtectionRule = nil
	local highestDisplayRule = nil

	for ruleIndex, rule in ipairs(state.rules) do
		local matched, matchedIds = RuleMatches(rule, statuses, healthPercent, distance)
		if matched then
			local match = { rule = rule, ruleIndex = ruleIndex, matchedIds = matchedIds }
			matchedRules[#matchedRules + 1] = match
			if rule.countsAsProtection then
				hasProtection = true
				if highestProtectionRule == nil
					or rule.displayPriority > highestProtectionRule.rule.displayPriority
					or (rule.displayPriority == highestProtectionRule.rule.displayPriority
						and ruleIndex < highestProtectionRule.ruleIndex) then
					highestProtectionRule = match
				end
			end
			if rule.effectType == 3 then
				if exclusion == nil or rule.displayPriority > exclusion.rule.displayPriority then
					exclusion = match
				end
			elseif rule.effectType == 4 then
				forceEmergency = true
				forcePriority = math.max(forcePriority, rule.rescuePriority)
			end
			if rule.simpleDisplayGroup == true and (highestDisplayRule == nil
				or rule.displayPriority > highestDisplayRule.rule.displayPriority
				or (rule.displayPriority == highestDisplayRule.rule.displayPriority and ruleIndex < highestDisplayRule.ruleIndex)) then
				highestDisplayRule = match
			end
		end
	end

	local memory = candidateMemory[member.key]
	local enterThreshold = member.isSelf and state.selfThreshold or state.enterThreshold
	local meetsEntry = healthPercent < enterThreshold or forceEmergency
	local baseEligible = meetsEntry
	if memory ~= nil and memory.active and healthPercent < state.exitThreshold then
		baseEligible = true
	end
	if exclusion ~= nil then
		candidateMemory[member.key] = nil
		if baseEligible and exclusion.rule.excludeDisplayMode == 2 then
			return nil, {
				key = member.key,
				name = member.name,
				raidIndex = member.raidIndex,
				distance = distance,
				healthPercent = healthPercent,
				reason = exclusion.rule.name,
			}
		end
		return nil, nil
	end
	if not baseEligible then
		if memory ~= nil and memory.active and animationClock - (memory.enteredAt or 0) < state.minHoldMs then
			baseEligible = true
		else
			candidateMemory[member.key] = nil
			return nil, nil
		end
	end
	if memory == nil then
		memory = { active = true, enteredAt = animationClock }
		candidateMemory[member.key] = memory
	else
		memory.active = true
	end

	local weightHealth = state.weights.health / 100
	local weightDistance = state.weights.distance / 100
	local weightMissing = state.weights.missing / 100
	local weightUnprotected = state.weights.unprotected / 100
	local healthFactor = HealthDangerScore(healthPercent)
	local distanceFactor = DistanceScore(distance)
	local missingFactor = MissingHealthScore(snapshot.missingHealth)
	local protectionFactor = hasProtection and 0 or 1
	local baseScore = 100 * (
		healthFactor * weightHealth
		+ distanceFactor * weightDistance
		+ missingFactor * weightMissing
		+ protectionFactor * weightUnprotected
	)
	local roleScore = GetRoleScore(member.role)

	local percentIncrease = 0
	local percentDecrease = 0
	local fixedIncrease = 0
	local fixedDecrease = 0
	local bestNonStackPercentIncrease = 0
	local bestNonStackPercentDecrease = 0
	local bestNonStackFixedIncrease = 0
	local bestNonStackFixedDecrease = 0
	local reasons = {}

	for _, match in ipairs(matchedRules) do
		local rule = match.rule
		if rule.effectType == 1 or rule.effectType == 2 then
			local magnitude = rule.scoreValue
			if rule.effectType == 1 and healthPercent <= state.emergencyThreshold then
				magnitude = magnitude * rule.emergencyRetainPercent / 100
			end
			local isIncrease = rule.effectType == 2
			if rule.scoreMode == 2 then
				if rule.allowStack then
					if isIncrease then percentIncrease = percentIncrease + magnitude else percentDecrease = percentDecrease + magnitude end
				else
					if isIncrease then bestNonStackPercentIncrease = math.max(bestNonStackPercentIncrease, magnitude)
					else bestNonStackPercentDecrease = math.max(bestNonStackPercentDecrease, magnitude) end
				end
			else
				if rule.allowStack then
					if isIncrease then fixedIncrease = fixedIncrease + magnitude else fixedDecrease = fixedDecrease + magnitude end
				else
					if isIncrease then bestNonStackFixedIncrease = math.max(bestNonStackFixedIncrease, magnitude)
					else bestNonStackFixedDecrease = math.max(bestNonStackFixedDecrease, magnitude) end
				end
			end
			reasons[#reasons + 1] = rule.name
		elseif rule.effectType == 4 then
			reasons[#reasons + 1] = rule.name
		end
	end
	percentIncrease = percentIncrease + bestNonStackPercentIncrease
	percentDecrease = percentDecrease + bestNonStackPercentDecrease
	fixedIncrease = fixedIncrease + bestNonStackFixedIncrease
	fixedDecrease = fixedDecrease + bestNonStackFixedDecrease
	local percentNet = Clamp(percentIncrease - percentDecrease, -90, 200)
	local finalScore = baseScore * (1 + percentNet / 100) + fixedIncrease - fixedDecrease + roleScore
	finalScore = Clamp(finalScore, 0, 100)
	local level = GetLevelForScore(finalScore, forceEmergency, healthPercent)

	local color, colorReason, visualPriority = ResolveHealingDisplayState(healthPercent, distance, statuses, highestDisplayRule)
	if color == nil then
		color = CopyColor(state.proximityColor)
		colorReason = "治疗范围"
		visualPriority = 1
	end

	local reasonText = #reasons > 0 and table.concat(reasons, ",") or (hasProtection and "已有保护" or "无保护")
	return {
		key = member.key,
		unitId = member.unitId,
		name = member.name,
		raidIndex = member.raidIndex,
		memberIndex = member.memberIndex,
		isSelf = member.isSelf,
		role = member.role,
		currentHealth = snapshot.currentHealth,
		maxHealth = snapshot.maxHealth,
		healthPercent = healthPercent,
		missingHealth = snapshot.missingHealth,
		distance = distance,
		baseScore = baseScore,
		finalScore = finalScore,
		level = level,
		forceEmergency = forceEmergency,
		forcePriority = forcePriority,
		visualPriority = visualPriority,
		hasProtection = hasProtection,
		color = color,
		colorReason = colorReason,
		reason = reasonText,
		reasons = reasons,
		tieBreaker = (tonumber(member.raidIndex) or 0) * 1000 + (tonumber(member.memberIndex) or 0),
	}, nil
end

function CandidateBefore(left, right)
	if left.visualPriority ~= right.visualPriority then
		return left.visualPriority > right.visualPriority
	end
	if left.forceEmergency ~= right.forceEmergency then
		return left.forceEmergency
	end
	if left.forceEmergency and right.forceEmergency and left.forcePriority ~= right.forcePriority then
		return left.forcePriority > right.forcePriority
	end
	local scoreDifference = left.finalScore - right.finalScore
	local leftPrevious = previousRanks[left.key]
	local rightPrevious = previousRanks[right.key]
	if leftPrevious ~= nil and rightPrevious ~= nil and math.abs(scoreDifference) < state.scoreLead then
		return leftPrevious < rightPrevious
	end
	if left.finalScore ~= right.finalScore then
		return left.finalScore > right.finalScore
	end
	if left.healthPercent ~= right.healthPercent then
		return left.healthPercent < right.healthPercent
	end
	if left.distance ~= right.distance then
		return left.distance < right.distance
	end
	if left.tieBreaker ~= right.tieBreaker then
		return left.tieBreaker < right.tieBreaker
	end
	return tostring(left.key or "") < tostring(right.key or "")
end

function ScanHealthAndBuildRecommendations()
	local nextHealth = {}
	for _, member in ipairs(roster) do
		local current = tonumber(SafeUnitCall("UnitHealth", member.unitId))
		local maximum = tonumber(SafeUnitCall("UnitMaxHealth", member.unitId))
		local distance = ReadDistance(member.unitId, member.isSelf)
		if current ~= nil and maximum ~= nil and maximum > 0 and distance ~= nil then
			nextHealth[member.key] = {
				currentHealth = current,
				maxHealth = maximum,
				missingHealth = math.max(0, maximum - current),
				healthPercent = Clamp(current / maximum * 100, 0, 100),
				distance = distance,
			}
		end
	end
	healthSnapshot = nextHealth
	local nextRecommendations = {}
	local nextUnavailable = {}
	for _, member in ipairs(roster) do
		local candidate, unavailableCandidate = EvaluateMember(member)
		if candidate ~= nil then
			nextRecommendations[#nextRecommendations + 1] = candidate
		end
		if unavailableCandidate ~= nil then
			nextUnavailable[#nextUnavailable + 1] = unavailableCandidate
		end
	end
	table.sort(nextRecommendations, CandidateBefore)
	for index = 1, #nextRecommendations do
		nextRecommendations[index].rank = index
	end
	recommendations = nextRecommendations
	unavailable = nextUnavailable
	previousRanks = {}
	for index = 1, #recommendations do
		previousRanks[recommendations[index].key] = index
	end
	if recommendScrollOffset > math.max(0, #recommendations - RECOMMEND_VISIBLE_ROWS) then
		recommendScrollOffset = math.max(0, #recommendations - RECOMMEND_VISIBLE_ROWS)
	end
end

function GetAnimatedAlpha(color, effectMode)
	local baseAlpha = color.a
	if effectMode == 2 then
		local phase = (math.sin((animationClock / 1200) * math.pi * 2) + 1) / 2
		return baseAlpha * (0.48 + phase * 0.52)
	elseif effectMode == 3 then
		return math.floor(animationClock / 180) % 2 == 0 and baseAlpha or baseAlpha * 0.20
	end
	return baseAlpha
end

-----------------------------------------------------------------------
-- Launcher and co-raid page switcher
-----------------------------------------------------------------------

function StoreEffectiveAnchor(target, widget, defaultWidth, defaultHeight)
	-- Launcher persistence now uses the same logical coordinate authority as the
	-- recommendation/config/raid windows.  Mixing effective pixels for storage
	-- with logical AddAnchor coordinates was the other half of the drag snap-back
	-- bug when UI scale was not 100%.
	local x, y, width, height = GetLogicalWidgetRect(widget)
	StoreAnchoredRect(target, x, y, width or defaultWidth, height or defaultHeight)
end

function LayoutEffectiveAnchoredWindow(widget, anchor, width, height)
	local x, y = ResolveAnchoredRect(anchor, width, height)
	widget:RemoveAllAnchors()
	widget:AddAnchor("TOPLEFT", "UIParent", x, y)
	widget:SetExtent(width, height)
end

launcherHost = bootstrapLauncherButton
launcherButton = bootstrapLauncherButton
if ReplicatedSuiteEmbedded == true then
	launcherHost = nil
	launcherButton = nil
	function LayoutLauncher() end
else
	if launcherButton == nil then error("启动按钮创建失败：" .. tostring(bootstrapCreateError)) end
	launcherButton:SetText("治疗推荐")
	ApplyExactButtonStyle(launcherButton, LAUNCHER_WIDTH, LAUNCHER_HEIGHT, 11)
	launcherButton:SetHeight(LAUNCHER_HEIGHT)
	launcherButton:SetWidth(LAUNCHER_WIDTH)
	if launcherButton.Enable ~= nil then launcherButton:Enable(true) end
	if launcherButton.Clickable ~= nil then launcherButton:Clickable(true) end
	launcherButton:EnableDrag(true)
	launcherButton:Show(ReplicatedHealerBoot.launcherVisible == true)
	function LayoutLauncher()
		if launcherButton.moving == true then return end
		LayoutEffectiveAnchoredWindow(launcherButton, state.launcherAnchor, LAUNCHER_WIDTH, LAUNCHER_HEIGHT)
		launcherButton:SetHeight(LAUNCHER_HEIGHT); launcherButton:SetWidth(LAUNCHER_WIDTH)
		launcherButton:Show(ReplicatedHealerBoot.launcherVisible == true)
	end
	launcherButton:SetHandler("OnDragStart", function(self) BeginHealerSafeMove(self, "healer_launcher", true); self.moving=true; return true end)
	launcherButton:SetHandler("OnDragStop", function(self)
		EndHealerSafeMove(self); self.moving=false; self.dragStoppedAt=animationClock
		StoreEffectiveAnchor(state.launcherAnchor,self,LAUNCHER_WIDTH,LAUNCHER_HEIGHT); SaveState()
	end)
	launcherButton:SetHandler("OnClick", function(self)
		if self.dragStoppedAt ~= nil and animationClock-self.dragStoppedAt <= 150 then return end
		if configWindow ~= nil then configWindow:Show(not configWindow:IsVisible()); if configWindow:IsVisible() then configWindow:SetUILayer(TOP_LAYER); configWindow:Raise(); RefreshSettingsUi() end end
	end)
	LayoutLauncher()
	RegisterHealerFloating("launcher", launcherButton, { onlyWhenVisible = true })
end

function LayoutPageSwitcher()
	-- Page switcher removed in v2.14: both raid panels are now visible simultaneously.
end

function RefreshPageSwitcher()
	-- Page switcher removed in v2.14.
end

-----------------------------------------------------------------------
-- Recommendation window
-----------------------------------------------------------------------

-- Suite v1.1 no longer exposes the independent ranked recommendation HUD.
-- Keep the recommendation Domain/candidate pipeline alive because head markers and
-- raid highlighting still consume it, but do not allocate the obsolete window,
-- rows, resize handles, or input handlers while embedded in Replicated Suite.
recommendPanel = nil
recommendRows = {}
unavailableRows = {}
if ReplicatedSuiteEmbedded ~= true then
	recommendPanel = CreateEmptyWindow("replicatedHealerV2RecommendPanel", "UIParent")
	recommendPanel:SetExtent(RECOMMEND_FULL_WIDTH, RECOMMEND_FULL_HEIGHT)
	recommendPanel:Enable(true)
	recommendPanel:Clickable(true)
	recommendPanel:EnableDrag(true)
	-- Recommendation panel is persistent combat HUD; keep normal z-order.
	recommendBg = CreateBackground(recommendPanel, 0.025, 0.035, 0.055, 0.90)
	recommendHeaderBg = recommendPanel:CreateColorDrawable(0.09, 0.16, 0.25, 0.96, "background")
	recommendHeaderBg:AddAnchor("TOPLEFT", recommendPanel, 0, 0)
	recommendHeaderBg:SetExtent(RECOMMEND_FULL_WIDTH, 28)
	recommendTitle = CreateLabel(
		recommendPanel,
		"replicatedHealerV2RecommendTitle",
		"治疗推荐 · Replicated",
		8,
		4,
		310,
		20,
		14,
		ALIGN_LEFT
	)
	recommendTitle.style:SetOutline(true)
	recommendSortButton = CreateTextButton(recommendPanel, "replicatedHealerV2SortButton", "统一排序", 316, 3, 88, 22, 10)
	recommendModeButton = CreateTextButton(recommendPanel, "replicatedHealerV2ModeButton", "缩小", 406, 3, 66, 22, 10)
	recommendCloseButton = CreateTextButton(recommendPanel, "replicatedHealerV2CloseButton", "X", 478, 3, 26, 22, 11)
	recommendResizeButton = CreateTextButton(
		recommendPanel,
		"replicatedHealerV2ResizeButton",
		"///",
		RECOMMEND_FULL_WIDTH - 34,
		RECOMMEND_FULL_HEIGHT - 26,
		30,
		22,
		10
	)
	recommendPanel:UseResizing(true)
	recommendPanel:SetMinResizingExtent(430, 180)
	recommendPanel:SetMaxResizingExtent(1000, 800)
	recommendColumnHeader = CreateLabel(
		recommendPanel,
		"replicatedHealerV2ColumnHeader",
		"名次  团  玩家                 血量   距离  等级     评分  主要原因",
		8,
		31,
		494,
		18,
		10,
		ALIGN_LEFT
	)
	recommendColumnHeader.style:SetColor(0.72, 0.80, 0.90, 1)
	
	recommendRows = {}
	for rowIndex = 1, RECOMMEND_VISIBLE_ROWS do
		local y = 50 + (rowIndex - 1) * 24
		local bg = recommendPanel:CreateColorDrawable(0.2, 0.2, 0.2, 0.4, "artwork")
		bg:AddAnchor("TOPLEFT", recommendPanel, 6, y)
		bg:SetExtent(498, 22)
		bg:SetVisible(false)
		local label = CreateLabel(
			recommendPanel,
			"replicatedHealerV2RecommendRow" .. tostring(rowIndex),
			"",
			10,
			y + 1,
			490,
			20,
			10,
			ALIGN_LEFT
		)
		label.style:SetOutline(true)
		label:Show(false)
		recommendRows[rowIndex] = { background = bg, label = label }
	end
	
	unavailableTitle = CreateLabel(
		recommendPanel,
		"replicatedHealerV2UnavailableTitle",
		"暂不可救援",
		8,
		292,
		110,
		16,
		10,
		ALIGN_LEFT
	)
	unavailableTitle.style:SetColor(0.72, 0.74, 0.78, 1)
	unavailableRows = {}
	for rowIndex = 1, UNAVAILABLE_VISIBLE_ROWS do
		local label = CreateLabel(
			recommendPanel,
			"replicatedHealerV2UnavailableRow" .. tostring(rowIndex),
			"",
			90,
			288 + rowIndex * 17,
			410,
			16,
			10,
			ALIGN_LEFT
		)
		label.style:SetColor(0.70, 0.72, 0.75, 1)
		unavailableRows[rowIndex] = label
	end
	recommendScrollLabel = CreateLabel(
		recommendPanel,
		"replicatedHealerV2ScrollLabel",
		"鼠标滚轮查看更多",
		8,
		322,
		494,
		16,
		10,
		ALIGN_CENTER
	)
	recommendScrollLabel.style:SetColor(0.60, 0.68, 0.76, 1)
end

function GetRecommendPanelHeight()
	if state.panelMode == 2 then
		return 50 + state.miniRecommendCount * 24 + 4
	end
	return state.recommendHeight
end

function GetFullVisibleRecommendRows(height)
	height = tonumber(height) or state.recommendHeight or RECOMMEND_FULL_HEIGHT
	return math.floor(Clamp(math.floor((height - 70) / 24), 1, RECOMMEND_VISIBLE_ROWS))
end

function LayoutRecommendPanel()
	if ReplicatedSuiteEmbedded == true or recommendPanel == nil then
		return
	end
	local resizing = recommendPanel.resizing == true and state.panelMode == 1
	local moving = recommendPanel.moving == true
	local width = state.panelMode == 2 and RECOMMEND_MINI_WIDTH or state.recommendWidth
	local height = GetRecommendPanelHeight()
	if resizing or moving then
		width = math.floor(Clamp(tonumber(recommendPanel:GetWidth()) or width, 430, 1000))
		height = math.floor(Clamp(tonumber(recommendPanel:GetHeight()) or height, 180, 800))
	else
		local x, y = ResolveAnchoredRect(state.panelAnchor, width, height)
		recommendPanel:RemoveAllAnchors()
		recommendPanel:AddAnchor("TOPLEFT", "UIParent", x, y)
		recommendPanel:SetExtent(width, height)
	end
	recommendHeaderBg:SetExtent(width, 28)
	recommendTitle:SetExtent(width - 200, 20)
	recommendSortButton:RemoveAllAnchors()
	recommendSortButton:AddAnchor("TOPLEFT", recommendPanel, width - 194, 3)
	recommendModeButton:RemoveAllAnchors()
	recommendModeButton:AddAnchor("TOPLEFT", recommendPanel, width - 102, 3)
	recommendCloseButton:RemoveAllAnchors()
	recommendCloseButton:AddAnchor("TOPLEFT", recommendPanel, width - 30, 3)
	for rowIndex = 1, RECOMMEND_VISIBLE_ROWS do
		recommendRows[rowIndex].background:SetExtent(width - 12, 22)
		recommendRows[rowIndex].label:SetExtent(width - 20, 20)
	end
	unavailableRows[1]:SetExtent(width - 100, 16)
	unavailableRows[2]:SetExtent(width - 100, 16)
	recommendScrollLabel:SetExtent(width - 16, 16)
	recommendScrollLabel:RemoveAllAnchors()
	recommendScrollLabel:AddAnchor("BOTTOMLEFT", recommendPanel, 8, -2)
	recommendResizeButton:RemoveAllAnchors()
	recommendResizeButton:AddAnchor("BOTTOMRIGHT", recommendPanel, -4, -4)
	recommendResizeButton:Show(state.panelMode == 1)
	recommendModeButton:SetText(state.panelMode == 2 and "展开" or "缩小")
	recommendPanel:Show(state.enabled and state.panelMode ~= 3)
end

if recommendPanel ~= nil then
	RegisterHealerFloating("recommend", recommendPanel, { onlyWhenVisible = true, fitSize = true })
	recommendPanel:SetHandler("OnDragStart", function(self)
		self.moving = true
		BeginHealerSafeMove(self, "healer_recommend", true)
		return true
	end)
	recommendPanel:SetHandler("OnDragStop", function(self)
		EndHealerSafeMove(self)
		local x, y, width, height = GetLogicalWidgetRect(self)
		StoreAnchoredRect(state.panelAnchor, x, y, width, height)
		self.moving = false
		LayoutRecommendPanel()
		SaveState()
	end)
	recommendResizeButton:EnableDrag(true)
	recommendResizeButton:SetHandler("OnDragStart", function()
		if state.panelMode ~= 1 then
			return false
		end
		recommendPanel.resizing = true
		recommendPanel:StartSizing("BOTTOMRIGHT")
		return true
	end)
	recommendResizeButton:SetHandler("OnDragStop", function()
		recommendPanel:StopMovingOrSizing()
		recommendPanel.resizing = false
		state.recommendWidth = math.floor(Clamp(tonumber(recommendPanel:GetWidth()) or state.recommendWidth, 430, 1000))
		state.recommendHeight = math.floor(Clamp(tonumber(recommendPanel:GetHeight()) or state.recommendHeight, 180, 800))
		local x, y, width, height = GetLogicalWidgetRect(recommendPanel)
		StoreAnchoredRect(state.panelAnchor, x, y, width, height)
		LayoutRecommendPanel()
		SaveState()
	end)
	recommendPanel:SetHandler("OnWheelUp", function()
		recommendScrollOffset = math.max(0, recommendScrollOffset - 1)
	end)
	recommendPanel:SetHandler("OnWheelDown", function()
		local visible = state.panelMode == 2 and state.miniRecommendCount or GetFullVisibleRecommendRows(recommendPanel:GetHeight())
		recommendScrollOffset = math.min(math.max(0, #recommendations - visible), recommendScrollOffset + 1)
	end)
	recommendSortButton:SetHandler("OnClick", function()
		state.recommendSortMode = Cycle(state.recommendSortMode, #SORT_MODE_LABELS, 1)
		SaveState()
	end)
	recommendModeButton:SetHandler("OnClick", function()
		state.panelMode = state.panelMode == 2 and 1 or 2
		recommendScrollOffset = 0
		LayoutRecommendPanel()
		SaveState()
	end)
	recommendCloseButton:SetHandler("OnClick", function()
		state.panelMode = 3
		LayoutRecommendPanel()
		SaveState()
	end)
end

function BuildDisplayRecommendations()
	if state.recommendSortMode == 1 or rosterMode ~= "coraid" then
		return recommendations
	end
	local grouped = {}
	for raidIndex = 1, 2 do
		for _, candidate in ipairs(recommendations) do
			if candidate.raidIndex == raidIndex then
				grouped[#grouped + 1] = candidate
			end
		end
	end
	return grouped
end

function RefreshRecommendationPanel()
	if ReplicatedSuiteEmbedded == true or recommendPanel == nil then
		return
	end
	-- Do not fight the native drag/resize transaction with a 50ms re-layout.
	-- Re-anchoring while StartMoving/StartSizing is active is the source of the
	-- visible flicker and snap-back seen on RU clients.
	if recommendPanel.moving == true or recommendPanel.resizing == true then return end
	LayoutRecommendPanel()
	if not state.enabled or state.panelMode == 3 then
		return
	end
	local displayList = BuildDisplayRecommendations()
	local rowCount = state.panelMode == 2 and state.miniRecommendCount or GetFullVisibleRecommendRows(recommendPanel:GetHeight())
	local maxConfigured = state.panelMode == 2 and state.miniRecommendCount or state.fullRecommendCount
	local maxOffset = math.max(0, math.min(#displayList, maxConfigured) - rowCount)
	recommendScrollOffset = Clamp(recommendScrollOffset, 0, maxOffset)
	recommendSortButton:SetText(SORT_MODE_LABELS[state.recommendSortMode])
	if state.panelMode == 2 then
		recommendTitle:SetText("治疗推荐 · Replicated")
	else
		recommendTitle:SetText(string.format("治疗推荐 · Replicated  候选:%d", #recommendations))
	end
	for rowIndex = 1, RECOMMEND_VISIBLE_ROWS do
		local row = recommendRows[rowIndex]
		local candidateIndex = recommendScrollOffset + rowIndex
		local candidate = candidateIndex <= maxConfigured and displayList[candidateIndex] or nil
		local shouldShow = rowIndex <= rowCount and candidate ~= nil
		row.background:SetVisible(shouldShow)
		row.label:Show(shouldShow)
		if shouldShow then
			local color = candidate.color
			row.background:SetColor(color.r, color.g, color.b, GetAnimatedAlpha(color, state.raidEffectMode) * 0.70)
			local reason = state.recommendDetailed
				and string.format("基础%.1f %s", candidate.baseScore, candidate.reason)
				or candidate.reason
			row.label:SetText(string.format(
				"%3d  [%d团] %-18s %5.1f%% %5.1fm %-8s %5.1f  %s",
				candidate.rank,
				candidate.raidIndex,
				candidate.name,
				candidate.healthPercent,
				candidate.distance,
				LEVEL_LABELS[candidate.level],
				candidate.finalScore,
				reason
			))
		end
	end
	local fullMode = state.panelMode == 1
	local showUnavailable = fullMode and (tonumber(recommendPanel:GetHeight()) or state.recommendHeight) >= RECOMMEND_FULL_HEIGHT
	recommendColumnHeader:Show(fullMode)
	unavailableTitle:Show(showUnavailable)
	recommendScrollLabel:Show(fullMode)
	for rowIndex = 1, UNAVAILABLE_VISIBLE_ROWS do
		local entry = showUnavailable and unavailable[rowIndex] or nil
		unavailableRows[rowIndex]:Show(entry ~= nil)
		if entry ~= nil then
			unavailableRows[rowIndex]:SetText(string.format(
				"[%d团] %s  %.1f%%  %.1fm  %s",
				entry.raidIndex,
				entry.name,
				entry.healthPercent,
				entry.distance,
				entry.reason
			))
		end
	end
end

LayoutRecommendPanel()

-----------------------------------------------------------------------
-- World-view head markers
-----------------------------------------------------------------------

headMarkers = {}
ReplicatedHealerCore1Loaded = true
