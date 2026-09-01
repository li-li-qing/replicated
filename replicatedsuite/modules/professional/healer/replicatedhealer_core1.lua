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

local HealerReuse = ReplicatedSuite and ReplicatedSuite.Reuse or nil
if HealerReuse ~= nil and HealerReuse.Value ~= nil and type(HealerReuse.Value.Clamp) == "function" then
	Clamp = HealerReuse.Value.Clamp
else
	function Clamp(value, minValue, maxValue)
		value = tonumber(value) or minValue
		if value < minValue then return minValue end
		if value > maxValue then return maxValue end
		return value
	end
end

function Round(value, decimals)
	local multiplier = 10 ^ (decimals or 0)
	return math.floor((value * multiplier) + 0.5) / multiplier
end

if HealerReuse ~= nil and HealerReuse.Table ~= nil and type(HealerReuse.Table.DeepCopy) == "function" then
	DeepCopy = HealerReuse.Table.DeepCopy
else
	function DeepCopy(value)
		if type(value) ~= "table" then return value end
		local result = {}
		for key, item in pairs(value) do result[key] = DeepCopy(item) end
		return result
	end
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

-- Settings defaults/normalization/migration now live in dedicated Domain files.
-- These compatibility functions keep Core2 and the legacy standalone editor
-- source-compatible while the actual Authority is ReplicatedHealerSettingsModel.
HealerSettingsModel = ReplicatedHealerSettingsModel
HealerSettingsBootstrap = ReplicatedHealerSettingsBootstrap
if type(HealerSettingsModel) ~= "table" or type(HealerSettingsBootstrap) ~= "table" then
	error("Healer Settings Model/Bootstrap 未加载")
end

defaults = HealerSettingsModel:BuildDefaults(HEALER_CONFIG)
state = {}
HealerSettingsBootMeta = nil

function NewDefaultHealingRule()
	return HealerSettingsModel:NewDefaultHealingRule()
end

function NewRuleByPurpose(purpose)
	return HealerSettingsModel:NewRuleByPurpose(purpose)
end

function NormalizeWeights()
	return HealerSettingsModel:NormalizeWeights(state, defaults)
end

function NormalizeTrackedBuff(entry, fallbackColor)
	return HealerSettingsModel:NormalizeTrackedBuff(entry, fallbackColor)
end

function NormalizeTrackedBuffList(list)
	return HealerSettingsModel:NormalizeTrackedBuffList(list)
end

function NormalizeRule(rule)
	return HealerSettingsModel:NormalizeRule(rule)
end

-- Legacy Core1 save helpers are retained only as the fallback writer used by
-- rh_settings_store.lua when Suite Persistence is unavailable. Boot loading is
-- read-only and is performed by rh_settings_bootstrap.lua.
local function SafeLoadSavedData(key)
	local ok, value = pcall(function() return ADDON:LoadData(key) end)
	if not ok then return nil, tostring(value) end
	return value, nil
end

local function ClearSavedDataVerified(key)
	local ok, value = pcall(function() return ADDON:ClearData(key) end)
	if not ok then return false, tostring(value) end
	if value ~= false then return true, nil end
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
	local loaded, meta = HealerSettingsBootstrap:Load(HEALER_CONFIG)
	if type(loaded) ~= "table" or type(meta) ~= "table" or meta.ok ~= true then
		error(type(meta) == "table" and tostring(meta.error or "settings bootstrap failed") or "settings bootstrap failed")
	end
	state = loaded
	defaults = type(meta.defaults) == "table" and meta.defaults or defaults
	stateNeedsMigrationSave = meta.needsMigrationSave == true
	storageWriteFenceReason = meta.writeFenceReason
	HealerSettingsBootMeta = meta
	return true
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
	if HealerSettingsBootMeta ~= nil and HealerSettingsBootMeta.recoveredFromBackup == true then
		pcall(function()
			X2Chat:DispatchChatMessage(CMF_SYSTEM, "Replicated 治疗推荐器：主配置不可用，已从备份恢复。")
		end)
	end
	-- Migration persistence is intentionally deferred until rh_settings_store
	-- registers the Permanent Store. This prevents Core1 from writing during
	-- the middle of boot before the full persistence safety layer exists.
	if storageWriteFenceReason ~= nil then
		storageWriteFenceWarned = true
		pcall(function()
			X2Chat:DispatchChatMessage(CMF_SYSTEM, "Replicated 治疗推荐器：检测到更高版本配置，已读取已知字段但不会覆盖原保存。")
		end)
	end
end

-- Suite session-only enabled suppression is applied by rh_settings_store.lua
-- after any pending boot migration snapshot has been durably committed. Keeping
-- the persisted value intact until then avoids saving a false runtime override.

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
	sharedScans = 0,
	directScans = 0,
	tooltipOnly = 0,
	skippedNoId = 0,
	lastSource = "none",
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

-- Native Unit/Team calls and roster token discovery are provided by
-- api/rh_api.lua and domain/rh_roster.lua. Core1 is now compatibility/runtime
-- glue; Roster, Status and Recommendation Authority live in dedicated Domain
-- modules loaded later in toc.g.

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

-- Roster generations are owned by domain/rh_roster.lua.

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

------------------------------------------------------------------------
-- Status Cache and Recommendation Domain implementations moved to:
--   domain/rh_status_cache.lua
--   domain/rh_recommendation.lua
-- Keep Core1 focused on configuration, persistence, common UI helpers and
-- recommendation-panel presentation.
------------------------------------------------------------------------

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
-- Recommendation list projection moved to presentation/
-- rh_recommendation_list_presenter.lua. Core1 no longer allocates or refreshes
-- that Native HUD directly.
-----------------------------------------------------------------------

-- Status/Recommendation/Marker/Raid implementations continue in the
-- dedicated Domain / Presentation files loaded immediately after Core1.
-----------------------------------------------------------------------

ReplicatedHealerCore1Loaded = true
