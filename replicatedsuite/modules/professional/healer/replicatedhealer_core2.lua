ReplicatedSuiteModuleSandbox:Enter('healer', {'ReplicatedHealerBoot', 'ReplicatedHealerConfig', 'ReplicatedHealerModule'})
-- Do not register update handlers when the preceding core chunk failed.  This
-- prevents a single startup error from producing repeated OnUpdate log spam.
if ReplicatedHealerCore1Loaded ~= true then
	return
end

local healerRuntimeGeneration = ReplicatedHealerBoot and tonumber(ReplicatedHealerBoot.generation) or 0
-- `_G` is the isolated module environment; the normal global lookup reaches
-- the Suite root through its fallback metatable.
local SuitePerformance = ReplicatedSuite and ReplicatedSuite.PerformanceMonitor or nil
-- Marker/Raid and Suite Settings projection moved to presentation/* modules.
-- Core2 now keeps standalone legacy settings/editor construction plus module
-- lifecycle glue; Suite-facing Settings Authority/commands live in the dedicated
-- Settings Model + Presenter layers.

-----------------------------------------------------------------------
-- Compact settings UI (real extents; designed for 1024x768 / UI 80%)
-----------------------------------------------------------------------

function InitializeSettingsUi()
configPages = { {}, {}, {}, {}, {} }
configTabs = {}
selectedLevelColor = 4
selectedHeadSizeLevel = 4

function RegisterPageWidget(pageIndex, widget)
	configPages[pageIndex][#configPages[pageIndex] + 1] = widget
	return widget
end

function CreatePageLabel(pageIndex, id, text, x, y, width, height, fontSize, align)
	return RegisterPageWidget(pageIndex, CreateLabel(configWindow, id, text, x, y, width, height, fontSize, align))
end

function CreatePageButton(pageIndex, id, text, x, y, width, height, fontSize)
	return RegisterPageWidget(pageIndex, CreateTextButton(configWindow, id, text, x, y, width, height, fontSize))
end

function SetSettingsPage(pageIndex)
	pageIndex = math.floor(Clamp(tonumber(pageIndex) or 1, 1, #configPages))
	-- v3.0.1 exposes three player-facing workflows: healing display, tracked
	-- Buff colors, and drag-first raid calibration. Legacy scoring/rule/role
	-- widgets remain instantiated only for persistence compatibility.
	if pageIndex ~= 1 and pageIndex ~= 2 and pageIndex ~= 5 then pageIndex = 1 end
	state.settingsPage = pageIndex
	for index = 1, #configPages do
		for _, widget in ipairs(configPages[index]) do
			widget:Show(index == state.settingsPage and widget.rhSettingsHidden ~= true)
		end
		if configTabs[index] ~= nil then
			local label = index == 1 and "治疗显示" or (index == 2 and "Buff追踪" or (index == 5 and "团队校准" or ""))
			configTabs[index]:SetText((index == state.settingsPage and "[" or "") .. label .. (index == state.settingsPage and "]" or ""))
		end
	end
end

configWindow = CreateEmptyWindow("replicatedHealerV2ConfigWindow", "UIParent")
configWindow:SetExtent(CONFIG_WIDTH, CONFIG_HEIGHT)
initialConfigX, initialConfigY = ResolveAnchoredRect(state.configAnchor, CONFIG_WIDTH, CONFIG_HEIGHT)
configWindow:AddAnchor("TOPLEFT", "UIParent", initialConfigX, initialConfigY)
configWindow:SetUILayer(TOP_LAYER)
configWindow:SetCloseOnEscape(true)
configWindow:Enable(true)
configWindow:Clickable(true)
configWindow:EnableDrag(true)
configWindow:Show(false)
RegisterHealerFloating("config", configWindow, { onlyWhenVisible = true, fitSize = true })
CreateBackground(configWindow, 0.03, 0.04, 0.06, 0.97)
configHeader = configWindow:CreateColorDrawable(0.09, 0.17, 0.27, 0.96, "background")
configHeader:AddAnchor("TOPLEFT", configWindow, 0, 0)
configHeader:SetExtent(CONFIG_WIDTH, 48)
configTitle = CreateLabel(configWindow, "replicatedHealerV2ConfigTitle", ADDON_TITLE, 12, 5, 420, 22, 17, ALIGN_LEFT)
configTitle.style:SetOutline(true)
configAuthor = CreateLabel(configWindow, "replicatedHealerV2ConfigAuthor", "作者：Replicated · v3.0.9 治疗显示 / Buff追踪 / 团队校准", 13, 27, 420, 16, 10, ALIGN_LEFT)
configAuthor.style:SetColor(0.70, 0.80, 0.92, 1)
configClose = CreateTextButton(configWindow, "replicatedHealerV2ConfigClose", "X", 526, 7, 26, 24, 11)
configClose:SetHandler("OnClick", function() configWindow:Show(false) end)
configWindow:SetHandler("OnDragStart", function(self) BeginHealerSafeMove(self, "healer_config", true) return true end)
configWindow:SetHandler("OnDragStop", function(self)
	EndHealerSafeMove(self)
	local x, y, width, height = GetLogicalWidgetRect(self)
	StoreAnchoredRect(state.configAnchor, x, y, width, height)
	SaveState()
end)

for index = 1, 5 do
	configTabs[index] = CreateTextButton(
		configWindow,
		"replicatedHealerV2ConfigTab" .. tostring(index),
		({ "治疗显示", "Buff追踪", "", "", "团队校准" })[index],
		8 + (index - 1) * 108,
		54,
		102,
		24,
		11
	)
	configTabs[index]:SetHandler("OnClick", function() SetSettingsPage(index) SaveState() RefreshSettingsUi() end)
end
for index = 3, 4 do configTabs[index]:Show(false) end
configTabs[1]:RemoveAllAnchors()
configTabs[1]:AddAnchor("TOPLEFT", configWindow, 8, 54)
configTabs[1]:SetExtent(172, 24)
configTabs[2]:RemoveAllAnchors()
configTabs[2]:AddAnchor("TOPLEFT", configWindow, 188, 54)
configTabs[2]:SetExtent(172, 24)
configTabs[5]:RemoveAllAnchors()
configTabs[5]:AddAnchor("TOPLEFT", configWindow, 368, 54)
configTabs[5]:SetExtent(168, 24)

function CreateValueControl(pageIndex, id, labelText, y, minusText, plusText, onMinus, onPlus)
	local label = CreatePageLabel(pageIndex, id .. "Label", labelText, 18, y + 2, 270, 20, 11, ALIGN_LEFT)
	local minus = CreatePageButton(pageIndex, id .. "Minus", minusText or "-", 342, y, 36, 22, 10)
	local value = CreatePageLabel(pageIndex, id .. "Value", "", 382, y + 1, 102, 20, 11, ALIGN_CENTER)
	local plus = CreatePageButton(pageIndex, id .. "Plus", plusText or "+", 488, y, 36, 22, 10)
	minus:SetHandler("OnClick", function() onMinus() SaveState() RefreshSettingsUi() end)
	plus:SetHandler("OnClick", function() onPlus() SaveState() RefreshSettingsUi() end)
	return { label = label, minus = minus, value = value, plus = plus }
end

function CreateCycleControl(pageIndex, id, labelText, y, onClick)
	CreatePageLabel(pageIndex, id .. "Label", labelText, 18, y + 2, 280, 20, 11, ALIGN_LEFT)
	local button = CreatePageButton(pageIndex, id .. "Button", "", 342, y, 182, 22, 10)
	button:SetHandler("OnClick", function() onClick() SaveState() RefreshSettingsUi() end)
	return button
end

function ApplyHealerRuntimeEnabled(enabled)
	state.enabled = enabled == true
	if state.enabled then
		-- Enabling can happen while the native raid frame is entering the world or
		-- rebuilding. Defer the first team-token scan instead of forcing it in the
		-- same UI lifecycle stack.
		teamRosterSettleRemainingMs = math.max(tonumber(teamRosterSettleRemainingMs) or 0, 900)
		teamRosterZOrderPending = true
		rosterElapsed = 0
		healthElapsed = 0
		buffElapsed = 0
		if ReplicatedHealerBoot ~= nil then ReplicatedHealerBoot.runtimeError = nil end
	else
		recommendations = {}
		unavailable = {}
		healthSnapshot = {}
	end
end

function SetHealerRuntimeEnabled(enabled)
	if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.ModuleManager ~= nil then
		return ReplicatedSuite.ModuleManager:SetEnabled("healer", enabled == true)
	end
	ApplyHealerRuntimeEnabled(enabled)
	return true
end

-- Page 1: Rescue score. In Suite this is a lifecycle proxy, not a second Authority.
enabledButton = CreateCycleControl(1, "replicatedHealerV2Enabled", "治疗辅助模块", 90, function() SetHealerRuntimeEnabled(not state.enabled) end)
maxDistanceControl = CreateValueControl(1, "replicatedHealerV2MaxDistance", "最大治疗距离（超距直接排除）", 118, nil, nil,
	function() state.maxDistance = Clamp(state.maxDistance - 1, 1, 100) state.proximityDistance = state.maxDistance end,
	function() state.maxDistance = Clamp(state.maxDistance + 1, 1, 100) state.proximityDistance = state.maxDistance end)
enterControl = CreateValueControl(1, "replicatedHealerV2EnterThreshold", "队友进入候选阈值", 146, nil, nil,
	function() state.enterThreshold = Clamp(state.enterThreshold - 1, 1, state.exitThreshold) end,
	function() state.enterThreshold = Clamp(state.enterThreshold + 1, 1, state.exitThreshold) end)
exitControl = CreateValueControl(1, "replicatedHealerV2ExitThreshold", "队友退出候选阈值", 174, nil, nil,
	function() state.exitThreshold = Clamp(state.exitThreshold - 1, state.enterThreshold, 100) end,
	function() state.exitThreshold = Clamp(state.exitThreshold + 1, state.enterThreshold, 100) end)
selfControl = CreateValueControl(1, "replicatedHealerV2SelfThreshold", "自己进入候选阈值", 202, nil, nil,
	function() state.selfThreshold = Clamp(state.selfThreshold - 1, 1, 100) end,
	function() state.selfThreshold = Clamp(state.selfThreshold + 1, 1, 100) end)
emergencyControl = CreateValueControl(1, "replicatedHealerV2EmergencyThreshold", "紧急生命阈值（至少紧急）", 230, nil, nil,
	function() state.emergencyThreshold = Clamp(state.emergencyThreshold - 1, 1, 100) end,
	function() state.emergencyThreshold = Clamp(state.emergencyThreshold + 1, 1, 100) end)
healthCurveButton = CreateCycleControl(1, "replicatedHealerV2HealthCurve", "生命危险曲线", 258,
	function() state.healthCurveMode = Cycle(state.healthCurveMode, #HEALTH_CURVE_LABELS, 1) end)
healthAccelButton = CreateCycleControl(1, "replicatedHealerV2HealthAccel", "低血量加速强度", 286,
	function() state.healthAccelMode = Cycle(state.healthAccelMode, #HEALTH_ACCEL_LABELS, 1) end)
distanceCurveButton = CreateCycleControl(1, "replicatedHealerV2DistanceCurve", "距离评分曲线", 314,
	function() state.distanceCurveMode = Cycle(state.distanceCurveMode, #DISTANCE_CURVE_LABELS, 1) end)
edgeControl = CreateValueControl(1, "replicatedHealerV2DistanceEdge", "距离边缘惩罚区", 342, nil, nil,
	function() state.distanceEdgePercent = Clamp(state.distanceEdgePercent - 5, 5, 80) end,
	function() state.distanceEdgePercent = Clamp(state.distanceEdgePercent + 5, 5, 80) end)
weightHealthControl = CreateValueControl(1, "replicatedHealerV2WeightHealth", "权重：生命危险", 370, nil, nil,
	function() state.weights.health = math.max(0, state.weights.health - 5) NormalizeWeights() end,
	function() state.weights.health = state.weights.health + 5 NormalizeWeights() end)
weightDistanceControl = CreateValueControl(1, "replicatedHealerV2WeightDistance", "权重：距离", 398, nil, nil,
	function() state.weights.distance = math.max(0, state.weights.distance - 5) NormalizeWeights() end,
	function() state.weights.distance = state.weights.distance + 5 NormalizeWeights() end)
weightMissingControl = CreateValueControl(1, "replicatedHealerV2WeightMissing", "权重：缺失生命（平滑曲线）", 426, nil, nil,
	function() state.weights.missing = math.max(0, state.weights.missing - 5) NormalizeWeights() end,
	function() state.weights.missing = state.weights.missing + 5 NormalizeWeights() end)
weightProtectionControl = CreateValueControl(1, "replicatedHealerV2WeightProtection", "权重：无治疗保护", 454, nil, nil,
	function() state.weights.unprotected = math.max(0, state.weights.unprotected - 5) NormalizeWeights() end,
	function() state.weights.unprotected = state.weights.unprotected + 5 NormalizeWeights() end)

-- Page 2: Display
panelModeButton = CreateCycleControl(2, "replicatedHealerV2PanelMode", "推荐窗口模式", 90,
	function() state.panelMode = Cycle(state.panelMode, #PANEL_MODE_LABELS, 1) LayoutRecommendPanel() end)
sortModeButton = CreateCycleControl(2, "replicatedHealerV2SortMode", "推荐窗口排序", 118,
	function() state.recommendSortMode = Cycle(state.recommendSortMode, #SORT_MODE_LABELS, 1) end)
detailedButton = CreateCycleControl(2, "replicatedHealerV2Detailed", "推荐窗口原因", 146,
	function() state.recommendDetailed = not state.recommendDetailed end)
fullCountControl = CreateValueControl(2, "replicatedHealerV2FullCount", "完整窗口显示人数（可滚动）", 174, nil, nil,
	function() state.fullRecommendCount = Clamp(state.fullRecommendCount - 1, 1, 100) end,
	function() state.fullRecommendCount = Clamp(state.fullRecommendCount + 1, 1, 100) end)
miniCountControl = CreateValueControl(2, "replicatedHealerV2MiniCount", "迷你窗口显示人数", 202, nil, nil,
	function() state.miniRecommendCount = Clamp(state.miniRecommendCount - 1, 1, 3) LayoutRecommendPanel() end,
	function() state.miniRecommendCount = Clamp(state.miniRecommendCount + 1, 1, 3) LayoutRecommendPanel() end)
headCountControl = CreateValueControl(2, "replicatedHealerV2HeadCount", "人物头顶标记人数", 230, nil, nil,
	function() state.headMarkerCount = Clamp(state.headMarkerCount - 1, 1, 50) end,
	function() state.headMarkerCount = Clamp(state.headMarkerCount + 1, 1, 50) end)
raidEffectButton = CreateCycleControl(2, "replicatedHealerV2RaidEffect", "团队列表高亮动画", 258,
	function() state.raidEffectMode = Cycle(state.raidEffectMode, #EFFECT_LABELS, 1) end)
headEffectButton = CreateCycleControl(2, "replicatedHealerV2HeadEffect", "人物头顶标记动画", 286,
	function() state.headEffectMode = Cycle(state.headEffectMode, #EFFECT_LABELS, 1) end)
headShapeButton = CreateCycleControl(2, "replicatedHealerV2HeadShape", "人物头顶标记形状", 314,
	function() state.headShapeMode = Cycle(state.headShapeMode, #HEAD_SHAPE_LABELS, 1) end)
headLevelButton = CreateCycleControl(2, "replicatedHealerV2HeadLevel", "正在调整的头顶等级", 342,
	function() selectedHeadSizeLevel = Cycle(selectedHeadSizeLevel, 4, 1) end)
headSizeControl = CreateValueControl(2, "replicatedHealerV2HeadSize", "当前等级头顶标记大小", 370, nil, nil,
	function() state.headSizes[selectedHeadSizeLevel] = Clamp(state.headSizes[selectedHeadSizeLevel] - 2, 12, 60) end,
	function() state.headSizes[selectedHeadSizeLevel] = Clamp(state.headSizes[selectedHeadSizeLevel] + 2, 12, 60) end)
raidRankCountControl = CreateValueControl(2, "replicatedHealerV2RaidRankCount", "团队格显示名次前 N 人", 398, nil, nil,
	function() state.raidRankCount = Clamp(state.raidRankCount - 1, 0, 50) end,
	function() state.raidRankCount = Clamp(state.raidRankCount + 1, 0, 50) end)
raidRankCornerButton = CreateCycleControl(2, "replicatedHealerV2RaidRankCorner", "团队格名次位置", 426,
	function() state.raidRankCorner = Cycle(state.raidRankCorner, #RANK_CORNER_LABELS, 1) LayoutRaidOverlays() end)
showRaidRanksButton = CreateCycleControl(2, "replicatedHealerV2ShowRaidRanks", "团队列表显示名次数字", 454,
	function() state.showRaidRanks = not state.showRaidRanks end)
displayColorPreview = CreatePageLabel(2, "replicatedHealerV2ColorPreview", "", 18, 478, 506, 16, 10, ALIGN_CENTER)

-- Page 3: Rules
CreatePageLabel(3, "replicatedHealerV2RuleHelp", "最多20条；颜色由救援等级为基础，高显示优先级规则可覆盖。", 18, 88, 506, 18, 10, ALIGN_LEFT)
ruleRows = {}
for row = 1, 10 do
	local y = 112 + (row - 1) * 25
	local button = CreatePageButton(3, "replicatedHealerV2RuleRow" .. tostring(row), "", 18, y, 506, 22, 10)
	button:SetHandler("OnClick", function()
		local index = ruleListOffset + row
		if state.rules[index] ~= nil then
			selectedRuleIndex = index
			RefreshSettingsUi()
		end
	end)
	ruleRows[row] = button
end
rulePrevButton = CreatePageButton(3, "replicatedHealerV2RulePrev", "上一页", 18, 370, 80, 22, 10)
ruleNextButton = CreatePageButton(3, "replicatedHealerV2RuleNext", "下一页", 102, 370, 80, 22, 10)
ruleAddButton = CreatePageButton(3, "replicatedHealerV2RuleAdd", "新增", 186, 370, 70, 22, 10)
ruleEditButton = CreatePageButton(3, "replicatedHealerV2RuleEdit", "编辑", 260, 370, 70, 22, 10)
ruleCopyButton = CreatePageButton(3, "replicatedHealerV2RuleCopy", "复制", 334, 370, 70, 22, 10)
ruleDeleteButton = CreatePageButton(3, "replicatedHealerV2RuleDelete", "删除", 408, 370, 70, 22, 10)
ruleUpButton = CreatePageButton(3, "replicatedHealerV2RuleUp", "上", 482, 370, 42, 22, 10)
ruleDownButton = CreatePageButton(3, "replicatedHealerV2RuleDown", "下", 482, 396, 42, 22, 10)
ruleDefaultButton = CreatePageButton(3, "replicatedHealerV2RuleDefault", "重新添加默认持续回血规则", 18, 402, 250, 24, 10)
ruleSummaryLabel = CreatePageLabel(3, "replicatedHealerV2RuleSummary", "", 18, 434, 460, 44, 10, ALIGN_LEFT)

rulePrevButton:SetHandler("OnClick", function() ruleListOffset = math.max(0, ruleListOffset - 10) RefreshSettingsUi() end)
ruleNextButton:SetHandler("OnClick", function() ruleListOffset = math.min(math.max(0, #state.rules - 10), ruleListOffset + 10) RefreshSettingsUi() end)
ruleAddButton:SetHandler("OnClick", function()
	if #state.rules < MAX_RULES then
		state.rules[#state.rules + 1] = NewRuleByPurpose(5)
		selectedRuleIndex = #state.rules
		SaveState()
		if ruleEditorWindow ~= nil then ruleEditorWindow:Show(true) RefreshRuleEditorUi(true) end
	end
end)
ruleEditButton:SetHandler("OnClick", function()
	if state.rules[selectedRuleIndex] ~= nil and ruleEditorWindow ~= nil then
		ruleEditorWindow:Show(true)
		RefreshRuleEditorUi(true)
	end
end)
ruleCopyButton:SetHandler("OnClick", function()
	if #state.rules < MAX_RULES and state.rules[selectedRuleIndex] ~= nil then
		local copy = DeepCopy(state.rules[selectedRuleIndex])
		copy.name = copy.name .. " 副本"
		table.insert(state.rules, selectedRuleIndex + 1, copy)
		selectedRuleIndex = selectedRuleIndex + 1
		SaveState()
		RefreshSettingsUi()
	end
end)
ruleDeleteButton:SetHandler("OnClick", function()
	if state.rules[selectedRuleIndex] ~= nil then
		table.remove(state.rules, selectedRuleIndex)
		selectedRuleIndex = Clamp(selectedRuleIndex, 1, math.max(1, #state.rules))
		SaveState()
		RefreshSettingsUi()
	end
end)
ruleUpButton:SetHandler("OnClick", function()
	if selectedRuleIndex > 1 then
		state.rules[selectedRuleIndex], state.rules[selectedRuleIndex - 1] = state.rules[selectedRuleIndex - 1], state.rules[selectedRuleIndex]
		selectedRuleIndex = selectedRuleIndex - 1
		SaveState()
		RefreshSettingsUi()
	end
end)
ruleDownButton:SetHandler("OnClick", function()
	if selectedRuleIndex < #state.rules then
		state.rules[selectedRuleIndex], state.rules[selectedRuleIndex + 1] = state.rules[selectedRuleIndex + 1], state.rules[selectedRuleIndex]
		selectedRuleIndex = selectedRuleIndex + 1
		SaveState()
		RefreshSettingsUi()
	end
end)
ruleDefaultButton:SetHandler("OnClick", function()
	if #state.rules < MAX_RULES then
		state.rules[#state.rules + 1] = NewDefaultHealingRule()
		selectedRuleIndex = #state.rules
		SaveState()
		RefreshSettingsUi()
	end
end)

-- Page 4: Roles
roleEnabledButton = CreateCycleControl(4, "replicatedHealerV2RoleEnabled", "职责评分", 90,
	function()
		state.roleScoringEnabled = not state.roleScoringEnabled
		if ReplicatedHealerRoster ~= nil then
			if state.roleScoringEnabled == true and type(ReplicatedHealerRoster.Invalidate) == "function" then
				-- Do not score against unknown/stale native roles. Keep the last
				-- committed roster visible but close the Domain gate until a full
				-- sliced Role Generation commits.
				ReplicatedHealerRoster:Invalidate(false, "role_scoring_enabled")
			elseif type(ReplicatedHealerRoster.Request) == "function" then
				ReplicatedHealerRoster:Request("role_scoring_disabled", false)
			end
		end
		if ReplicatedHealerRuntime ~= nil and type(ReplicatedHealerRuntime.OnScoringPolicyChanged) == "function" then
			ReplicatedHealerRuntime:OnScoringPolicyChanged("role_scoring_toggle")
		end
	end)
roleMainTankControl = CreateValueControl(4, "replicatedHealerV2RoleMainTank", "主坦固定加分", 118, nil, nil,
	function() state.roleScores.mainTank = Clamp(state.roleScores.mainTank - 1, -100, 100) end,
	function() state.roleScores.mainTank = Clamp(state.roleScores.mainTank + 1, -100, 100) end)
roleOffTankControl = CreateValueControl(4, "replicatedHealerV2RoleOffTank", "副坦固定加分", 146, nil, nil,
	function() state.roleScores.offTank = Clamp(state.roleScores.offTank - 1, -100, 100) end,
	function() state.roleScores.offTank = Clamp(state.roleScores.offTank + 1, -100, 100) end)
roleHealerControl = CreateValueControl(4, "replicatedHealerV2RoleHealer", "治疗固定加分", 174, nil, nil,
	function() state.roleScores.healer = Clamp(state.roleScores.healer - 1, -100, 100) end,
	function() state.roleScores.healer = Clamp(state.roleScores.healer + 1, -100, 100) end)
roleNormalControl = CreateValueControl(4, "replicatedHealerV2RoleNormal", "普通成员固定加分", 202, nil, nil,
	function() state.roleScores.normal = Clamp(state.roleScores.normal - 1, -100, 100) end,
	function() state.roleScores.normal = Clamp(state.roleScores.normal + 1, -100, 100) end)
roleUnknownControl = CreateValueControl(4, "replicatedHealerV2RoleUnknown", "未识别职责固定加分", 230, nil, nil,
	function() state.roleScores.unknown = Clamp(state.roleScores.unknown - 1, -100, 100) end,
	function() state.roleScores.unknown = Clamp(state.roleScores.unknown + 1, -100, 100) end)
CreatePageLabel(4, "replicatedHealerV2RoleOverrideTitle", "全局手动职责覆盖（玩家名）", 18, 268, 300, 18, 11, ALIGN_LEFT)
roleNameEdit = RegisterPageWidget(4, CreateEditBox(configWindow, "replicatedHealerV2RoleNameEdit", 18, 292, 240, 24, 32))
roleOverrideMode = 1
roleOverrideButton = CreatePageButton(4, "replicatedHealerV2RoleOverrideMode", ROLE_LABELS[roleOverrideMode], 266, 292, 126, 24, 10)
roleOverrideAdd = CreatePageButton(4, "replicatedHealerV2RoleOverrideAdd", "添加/更新", 398, 292, 126, 24, 10)
roleOverrideRows = {}
for row = 1, 6 do
	roleOverrideRows[row] = CreatePageButton(4, "replicatedHealerV2RoleOverrideRow" .. tostring(row), "", 18, 324 + (row - 1) * 24, 430, 21, 10)
	roleOverrideRows[row]:SetHandler("OnClick", function()
		selectedRoleOverrideIndex = roleOverrideOffset + row
		RefreshSettingsUi()
	end)
end
roleOverrideDelete = CreatePageButton(4, "replicatedHealerV2RoleOverrideDelete", "删除选中", 454, 324, 70, 22, 10)
roleOverridePrev = CreatePageButton(4, "replicatedHealerV2RoleOverridePrev", "上一页", 18, 468, 90, 22, 10)
roleOverrideNext = CreatePageButton(4, "replicatedHealerV2RoleOverrideNext", "下一页", 114, 468, 90, 22, 10)
roleOverrideButton:SetHandler("OnClick", function() roleOverrideMode = Cycle(roleOverrideMode, #ROLE_LABELS, 1) roleOverrideButton:SetText(ROLE_LABELS[roleOverrideMode]) end)
roleOverrideAdd:SetHandler("OnClick", function()
	local name = tostring(roleNameEdit:GetText() or "")
	if name ~= "" then
		state.roleOverrides[name] = roleOverrideMode
		SaveState()
		if ReplicatedHealerRoster ~= nil and type(ReplicatedHealerRoster.Reclassify) == "function" then
			ReplicatedHealerRoster:Reclassify()
		else
			RebuildRoster()
		end
		RefreshSettingsUi()
	end
end)

-- Page 5: Calibration
calibrationButton = CreateCycleControl(5, "replicatedHealerV2Calibration", "团队列表校准模式", 90,
	function() calibrationMode = not calibrationMode ApplyCalibrationMode() end)
calibrationSectionButton = CreateCycleControl(5, "replicatedHealerV2CalibrationSection", "正在调整的覆盖区域", 118,
	function()
		CycleCalibrationSectionInScope()
		ApplyCalibrationMode()
		if RefreshCalibrationCoordinateEdits ~= nil then RefreshCalibrationCoordinateEdits() end
	end)
proximityButton = CreateCycleControl(5, "replicatedHealerV2Proximity", "近距离成员显示淡蓝", 146,
	function() state.proximityMode = not state.proximityMode SaveState() end)
CreatePageLabel(5, "replicatedHealerV2ProximityDistanceLabel", "范围 (m)", 18, 178, 56, 18, 11, ALIGN_LEFT)
proximityDistanceLabel = CreatePageLabel(5, "replicatedHealerV2ProximityDistanceVal", "27", 78, 178, 28, 18, 11, ALIGN_CENTER)
proximityDistMinus = CreatePageButton(5, "replicatedHealerV2ProximityDistMinus", "-", 110, 174, 20, 20, 10)
proximityDistPlus = CreatePageButton(5, "replicatedHealerV2ProximityDistPlus", "+", 134, 174, 20, 20, 10)
CreatePageLabel(5, "replicatedHealerV2ProximityColorLabel", "颜色", 18, 202, 32, 18, 11, ALIGN_LEFT)
CreatePageLabel(5, "replicatedHealerV2ProximityRLabel", "R", 52, 202, 12, 18, 11, ALIGN_CENTER)
proximityRLabel = CreatePageLabel(5, "replicatedHealerV2ProximityRVal", "0.40", 66, 202, 32, 18, 11, ALIGN_CENTER)
proximityRMinus = CreatePageButton(5, "replicatedHealerV2ProximityRMinus", "-", 100, 198, 16, 20, 10)
proximityRPlus = CreatePageButton(5, "replicatedHealerV2ProximityRPlus", "+", 118, 198, 16, 20, 10)
CreatePageLabel(5, "replicatedHealerV2ProximityGLabel", "G", 138, 202, 12, 18, 11, ALIGN_CENTER)
proximityGLabel = CreatePageLabel(5, "replicatedHealerV2ProximityGVal", "0.72", 152, 202, 32, 18, 11, ALIGN_CENTER)
proximityGMinus = CreatePageButton(5, "replicatedHealerV2ProximityGMinus", "-", 186, 198, 16, 20, 10)
proximityGPlus = CreatePageButton(5, "replicatedHealerV2ProximityGPlus", "+", 204, 198, 16, 20, 10)
CreatePageLabel(5, "replicatedHealerV2ProximityBLabel", "B", 224, 202, 12, 18, 11, ALIGN_CENTER)
proximityBLabel = CreatePageLabel(5, "replicatedHealerV2ProximityBVal", "1.00", 238, 202, 32, 18, 11, ALIGN_CENTER)
proximityBMinus = CreatePageButton(5, "replicatedHealerV2ProximityBMinus", "-", 272, 198, 16, 20, 10)
proximityBPlus = CreatePageButton(5, "replicatedHealerV2ProximityBPlus", "+", 290, 198, 16, 20, 10)
CreatePageLabel(5, "replicatedHealerV2ProximityALabel", "A", 310, 202, 12, 18, 11, ALIGN_CENTER)
proximityALabel = CreatePageLabel(5, "replicatedHealerV2ProximityAVal", "0.45", 324, 202, 32, 18, 11, ALIGN_CENTER)
proximityAMinus = CreatePageButton(5, "replicatedHealerV2ProximityAMinus", "-", 358, 198, 16, 20, 10)
proximityAPlus = CreatePageButton(5, "replicatedHealerV2ProximityAPlus", "+", 376, 198, 16, 20, 10)
CreatePageLabel(5, "replicatedHealerV2CoordinateTitle", "直接输入坐标", 18, 238, 110, 18, 11, ALIGN_LEFT)
CreatePageLabel(5, "replicatedHealerV2CoordinateXLabel", "X", 132, 238, 18, 18, 11, ALIGN_CENTER)
calibrationXEdit = RegisterPageWidget(5, CreateEditBox(configWindow, "replicatedHealerV2CoordinateX", 152, 234, 92, 24, 8))
CreatePageLabel(5, "replicatedHealerV2CoordinateYLabel", "Y", 252, 238, 18, 18, 11, ALIGN_CENTER)
calibrationYEdit = RegisterPageWidget(5, CreateEditBox(configWindow, "replicatedHealerV2CoordinateY", 272, 234, 92, 24, 8))
applyCoordinateButton = CreatePageButton(5, "replicatedHealerV2ApplyCoordinate", "应用坐标", 372, 234, 112, 24, 10)
CreatePageLabel(5, "replicatedHealerV2PositionTitle", "位置微调（当前区域）", 18, 274, 240, 18, 11, ALIGN_LEFT)
moveLeft = CreatePageButton(5, "replicatedHealerV2MoveLeft", "左移", 18, 296, 112, 24, 10)
moveUp = CreatePageButton(5, "replicatedHealerV2MoveUp", "上移", 136, 296, 112, 24, 10)
moveDown = CreatePageButton(5, "replicatedHealerV2MoveDown", "下移", 254, 296, 112, 24, 10)
moveRight = CreatePageButton(5, "replicatedHealerV2MoveRight", "右移", 372, 296, 112, 24, 10)
CreatePageLabel(5, "replicatedHealerV2SizeTitle", "尺寸微调（当前区域）", 18, 332, 240, 18, 11, ALIGN_LEFT)
widthMinus = CreatePageButton(5, "replicatedHealerV2WidthMinus", "宽 -", 18, 354, 112, 24, 10)
widthPlus = CreatePageButton(5, "replicatedHealerV2WidthPlus", "宽 +", 136, 354, 112, 24, 10)
heightMinus = CreatePageButton(5, "replicatedHealerV2HeightMinus", "高 -", 254, 354, 112, 24, 10)
heightPlus = CreatePageButton(5, "replicatedHealerV2HeightPlus", "高 +", 372, 354, 112, 24, 10)
resetOverlay = CreatePageButton(5, "replicatedHealerV2ResetOverlay", "恢复当前默认位置", 18, 390, 230, 24, 10)
resetLauncher = CreatePageButton(5, "replicatedHealerV2ResetLauncher", "恢复启动按钮左上角", 254, 390, 230, 24, 10)
calibrationInfo = CreatePageLabel(5, "replicatedHealerV2CalibrationInfo", "", 18, 420, 506, 70, 10, ALIGN_LEFT)

RefreshCalibrationCoordinateEdits = function()
	local config = GetOverlayConfig(state.raidCalibrationSection)
	local x, y = ResolveAnchoredRect(config, config.width, config.height)
	calibrationXEdit:SetText(tostring(math.floor(x + 0.5)))
	calibrationYEdit:SetText(tostring(math.floor(y + 0.5)))
end

applyCoordinateButton:SetHandler("OnClick", function()
	local x = tonumber(tostring(calibrationXEdit:GetText() or ""))
	local y = tonumber(tostring(calibrationYEdit:GetText() or ""))
	if x == nil or y == nil then
		X2Chat:DispatchChatMessage(CMF_SYSTEM, "Replicated：请输入有效的 X、Y 数字。")
		return
	end
	local config = GetOverlayConfig(state.raidCalibrationSection)
	local _, _, width, height = ResolveAnchoredRect(config, config.width, config.height)
	StoreAnchoredRect(config, x, y, width, height)
	LayoutRaidOverlays()
	SaveState()
	RefreshCalibrationCoordinateEdits()
	RefreshSettingsUi()
end)

function ModifyOverlay(dx, dy, dw, dh)
	local config = GetOverlayConfig(state.raidCalibrationSection)
	local x, y, width, height = ResolveAnchoredRect(config, config.width, config.height)
	StoreAnchoredRect(config, x + (dx or 0), y + (dy or 0), Clamp(width + (dw or 0), 180, 1200), Clamp(height + (dh or 0), 80, 600))
	LayoutRaidOverlays()
	SaveState()
	RefreshCalibrationCoordinateEdits()
	RefreshSettingsUi()
end
moveLeft:SetHandler("OnClick", function() ModifyOverlay(-5, 0, 0, 0) end)
moveRight:SetHandler("OnClick", function() ModifyOverlay(5, 0, 0, 0) end)
moveUp:SetHandler("OnClick", function() ModifyOverlay(0, -5, 0, 0) end)
moveDown:SetHandler("OnClick", function() ModifyOverlay(0, 5, 0, 0) end)
widthMinus:SetHandler("OnClick", function() ModifyOverlay(0, 0, -5, 0) end)
widthPlus:SetHandler("OnClick", function() ModifyOverlay(0, 0, 5, 0) end)
heightMinus:SetHandler("OnClick", function() ModifyOverlay(0, 0, 0, -5) end)
heightPlus:SetHandler("OnClick", function() ModifyOverlay(0, 0, 0, 5) end)
resetOverlay:SetHandler("OnClick", function()
	if state.raidCalibrationSection == 1 then state.raidOverlayTop = DeepCopy(defaults.raidOverlayTop)
	elseif state.raidCalibrationSection == 2 then state.raidOverlayBottom = DeepCopy(defaults.raidOverlayBottom)
	elseif state.raidCalibrationSection == 3 then state.raidOverlayTopRaid2 = DeepCopy(defaults.raidOverlayTopRaid2)
	else state.raidOverlayBottomRaid2 = DeepCopy(defaults.raidOverlayBottomRaid2) end
	LayoutRaidOverlays()
	SaveState()
	RefreshCalibrationCoordinateEdits()
	RefreshSettingsUi()
end)
resetLauncher:SetHandler("OnClick", function()
	state.launcherAnchor = DeepCopy(defaults.launcherAnchor)
	LayoutLauncher()
	SaveState()
end)

-- Proximity distance and color +/- handlers
proximityDistMinus:SetHandler("OnClick", function()
	state.proximityDistance = Clamp(state.proximityDistance - 1, 1, 100)
	SaveState() RefreshSettingsUi()
end)
proximityDistPlus:SetHandler("OnClick", function()
	state.proximityDistance = Clamp(state.proximityDistance + 1, 1, 100)
	SaveState() RefreshSettingsUi()
end)
proximityRMinus:SetHandler("OnClick", function()
	state.proximityColor.r = Clamp(state.proximityColor.r - 0.05, 0, 1)
	SaveState() RefreshSettingsUi()
end)
proximityRPlus:SetHandler("OnClick", function()
	state.proximityColor.r = Clamp(state.proximityColor.r + 0.05, 0, 1)
	SaveState() RefreshSettingsUi()
end)
proximityGMinus:SetHandler("OnClick", function()
	state.proximityColor.g = Clamp(state.proximityColor.g - 0.05, 0, 1)
	SaveState() RefreshSettingsUi()
end)
proximityGPlus:SetHandler("OnClick", function()
	state.proximityColor.g = Clamp(state.proximityColor.g + 0.05, 0, 1)
	SaveState() RefreshSettingsUi()
end)
proximityBMinus:SetHandler("OnClick", function()
	state.proximityColor.b = Clamp(state.proximityColor.b - 0.05, 0, 1)
	SaveState() RefreshSettingsUi()
end)
proximityBPlus:SetHandler("OnClick", function()
	state.proximityColor.b = Clamp(state.proximityColor.b + 0.05, 0, 1)
	SaveState() RefreshSettingsUi()
end)
proximityAMinus:SetHandler("OnClick", function()
	state.proximityColor.a = Clamp(state.proximityColor.a - 0.05, 0.05, 1)
	SaveState() RefreshSettingsUi()
end)
proximityAPlus:SetHandler("OnClick", function()
	state.proximityColor.a = Clamp(state.proximityColor.a + 0.05, 0.05, 1)
	SaveState() RefreshSettingsUi()
end)

-- v3.0.1 compact public settings ------------------------------------------------
-- Legacy score/rule/role widgets stay instantiated only so old saves continue
-- to normalize correctly.  The visible UI is now centered on the actual
-- healer workflow: distance/HP thresholds + RGBA colors, tracked Buff colors,
-- and direct-mouse raid calibration.
for _, pageIndex in ipairs({ 1, 2, 5 }) do
	for _, widget in ipairs(configPages[pageIndex]) do
		widget.rhSettingsHidden = true
	end
end

function ColorToDisplayText(color)
	color = color or {}
	return string.format(
		"R%03d G%03d B%03d A%03d%%",
		math.floor(Clamp(color.r or 0, 0, 1) * 255 + 0.5),
		math.floor(Clamp(color.g or 0, 0, 1) * 255 + 0.5),
		math.floor(Clamp(color.b or 0, 0, 1) * 255 + 0.5),
		math.floor(Clamp(color.a or 0, 0, 1) * 100 + 0.5)
	)
end

------------------------------------------------------------------------
-- Shared RGBA editor (RGB 0..255, Alpha 0..100%)
------------------------------------------------------------------------
colorEditorTarget = nil
colorEditorTargetName = "颜色"
colorEditorWindow = CreateEmptyWindow("replicatedHealerV3ColorEditor", "UIParent")
colorEditorWindow:SetExtent(430, 286)
colorEditorWindow:AddAnchor("CENTER", "UIParent", 0, 0)
colorEditorWindow:SetUILayer(TOP_LAYER)
colorEditorWindow:SetCloseOnEscape(true)
colorEditorWindow:Enable(true)
colorEditorWindow:Clickable(true)
colorEditorWindow:EnableDrag(true)
colorEditorWindow:Show(false)
RegisterHealerFloating("color_editor", colorEditorWindow, { onlyWhenVisible = true, fitSize = true })
CreateBackground(colorEditorWindow, 0.025, 0.035, 0.05, 0.98)
colorEditorTitle = CreateLabel(colorEditorWindow, "replicatedHealerV3ColorEditorTitle", "RGBA 颜色", 12, 8, 350, 22, 15, ALIGN_LEFT)
colorEditorClose = CreateTextButton(colorEditorWindow, "replicatedHealerV3ColorEditorClose", "X", 392, 7, 26, 24, 11)
colorEditorClose:SetHandler("OnClick", function() colorEditorWindow:Show(false) end)
colorEditorWindow:SetHandler("OnDragStart", function(self) BeginHealerSafeMove(self, "healer_color_editor", true) return true end)
colorEditorWindow:SetHandler("OnDragStop", function(self) EndHealerSafeMove(self) end)

colorEditorRows = {}
local colorEditorChannelNames = { "R 红色", "G 绿色", "B 蓝色", "A 透明度" }
for channel = 1, 4 do
	local y = 48 + (channel - 1) * 42
	local row = {}
	row.label = CreateLabel(colorEditorWindow, "replicatedHealerV3ColorLabel" .. tostring(channel), colorEditorChannelNames[channel], 18, y + 3, 112, 20, 11, ALIGN_LEFT)
	row.minus = CreateTextButton(colorEditorWindow, "replicatedHealerV3ColorMinus" .. tostring(channel), "-", 146, y, 42, 24, 11)
	row.value = CreateEditBox(colorEditorWindow, "replicatedHealerV3ColorValue" .. tostring(channel), 194, y, 96, 24, 4)
	row.plus = CreateTextButton(colorEditorWindow, "replicatedHealerV3ColorPlus" .. tostring(channel), "+", 296, y, 42, 24, 11)
	local channelIndex = channel
	local function AdjustColorChannel(direction)
		if colorEditorTarget == nil then return end
		local key = ({ "r", "g", "b", "a" })[channelIndex]
		local step = channelIndex == 4 and 0.05 or (5 / 255)
		colorEditorTarget[key] = Clamp((tonumber(colorEditorTarget[key]) or 0) + step * direction, 0, 1)
		SaveState()
		if RefreshColorEditor ~= nil then RefreshColorEditor() end
		if RefreshSettingsUi ~= nil then RefreshSettingsUi() end
		if RefreshRaidHighlights ~= nil then RefreshRaidHighlights() end
	end
	row.minus:SetHandler("OnClick", function() AdjustColorChannel(-1) end)
	row.plus:SetHandler("OnClick", function() AdjustColorChannel(1) end)
	colorEditorRows[channel] = row
end
colorEditorPreview = CreateMovableColorPanel(colorEditorWindow, "replicatedHealerV3ColorPreview", 1, 1, 1, 1, "overlay")
colorEditorPreview:RemoveAllAnchors()
colorEditorPreview:AddAnchor("TOPLEFT", colorEditorWindow, 18, 224)
colorEditorPreview:SetExtent(250, 28)
colorEditorPreview:SetVisible(true)
colorEditorDone = CreateTextButton(colorEditorWindow, "replicatedHealerV3ColorDone", "应用并关闭", 282, 224, 136, 28, 11)
colorEditorDone:SetHandler("OnClick", function()
	if colorEditorTarget == nil then colorEditorWindow:Show(false) return end
	local values = {}
	for channel = 1, 4 do
		values[channel] = tonumber(tostring(colorEditorRows[channel].value:GetText() or ""))
		if values[channel] == nil then
			X2Chat:DispatchChatMessage(CMF_SYSTEM, "Replicated：RGBA 请输入数字。RGB 范围 0-255，A 范围 0-100。")
			return
		end
	end
	colorEditorTarget.r = Clamp(values[1], 0, 255) / 255
	colorEditorTarget.g = Clamp(values[2], 0, 255) / 255
	colorEditorTarget.b = Clamp(values[3], 0, 255) / 255
	colorEditorTarget.a = Clamp(values[4], 0, 100) / 100
	SaveState()
	if RefreshSettingsUi ~= nil then RefreshSettingsUi() end
	if RefreshRaidHighlights ~= nil then RefreshRaidHighlights() end
	colorEditorWindow:Show(false)
end)

RefreshColorEditor = function()
	if colorEditorTarget == nil then return end
	colorEditorTitle:SetText("RGBA · " .. tostring(colorEditorTargetName or "颜色"))
	for channel = 1, 4 do
		local key = ({ "r", "g", "b", "a" })[channel]
		local value = Clamp(colorEditorTarget[key] or 0, 0, 1)
		if channel == 4 then
			colorEditorRows[channel].value:SetText(tostring(math.floor(value * 100 + 0.5)))
		else
			colorEditorRows[channel].value:SetText(tostring(math.floor(value * 255 + 0.5)))
		end
	end
	colorEditorPreview:SetColor(colorEditorTarget.r, colorEditorTarget.g, colorEditorTarget.b, colorEditorTarget.a)
end

function OpenColorEditor(target, name)
	if type(target) ~= "table" then return end
	colorEditorTarget = target
	colorEditorTargetName = tostring(name or "颜色")
	RefreshColorEditor()
	colorEditorWindow:Show(true)
	colorEditorWindow:SetUILayer(TOP_LAYER)
	colorEditorWindow:Raise()
end

------------------------------------------------------------------------
-- Page 1: healing display
------------------------------------------------------------------------
simpleEnabledButton = CreateCycleControl(1, "replicatedHealerSimpleEnabled", "治疗辅助模块", 94, function()
	SetHealerRuntimeEnabled(not state.enabled)
end)
simpleDistanceControl = CreateValueControl(1, "replicatedHealerSimpleDistance", "治疗距离", 126, nil, nil,
	function() state.maxDistance = Clamp(state.maxDistance - 1, 1, 100) state.proximityDistance = state.maxDistance end,
	function() state.maxDistance = Clamp(state.maxDistance + 1, 1, 100) state.proximityDistance = state.maxDistance end)
simpleLowHealthControl = CreateValueControl(1, "replicatedHealerSimpleLowHealth", "低血量阈值", 158, nil, nil,
	function() state.lowHealthThreshold = Clamp(state.lowHealthThreshold - 1, state.emergencyThreshold, 100) end,
	function() state.lowHealthThreshold = Clamp(state.lowHealthThreshold + 1, state.emergencyThreshold, 100) end)
simpleEmergencyControl = CreateValueControl(1, "replicatedHealerSimpleEmergency", "紧急血量阈值", 190, nil, nil,
	function() state.emergencyThreshold = Clamp(state.emergencyThreshold - 1, 1, state.lowHealthThreshold) end,
	function() state.emergencyThreshold = Clamp(state.emergencyThreshold + 1, 1, state.lowHealthThreshold) end)
simpleRangeTintButton = CreateCycleControl(1, "replicatedHealerSimpleRangeTint", "显示治疗范围成员", 222, function()
	state.proximityMode = not state.proximityMode
end)

function CreateSimpleColorRow(id, labelText, y, targetGetter)
	local label = CreatePageLabel(1, id .. "Label", labelText, 18, y + 2, 210, 20, 11, ALIGN_LEFT)
	local value = CreatePageLabel(1, id .. "Value", "", 224, y + 2, 188, 20, 10, ALIGN_CENTER)
	local button = CreatePageButton(1, id .. "Button", "编辑 RGBA", 420, y, 104, 22, 10)
	button:SetHandler("OnClick", function()
		local target = targetGetter()
		OpenColorEditor(target, labelText)
	end)
	return { label = label, value = value, button = button, getter = targetGetter }
end

simpleRangeColorRow = CreateSimpleColorRow("replicatedHealerSimpleRangeColor", "治疗范围颜色", 258, function() return state.proximityColor end)
simpleLowColorRow = CreateSimpleColorRow("replicatedHealerSimpleLowColor", "低血量颜色", 290, function() return state.lowHealthColor end)
simpleEmergencyColorRow = CreateSimpleColorRow("replicatedHealerSimpleEmergencyColor", "紧急颜色", 322, function() return state.emergencyColor end)
simpleBasicHelp = CreatePageLabel(1, "replicatedHealerSimpleHelp",
	"颜色优先级：紧急 > 追踪 Buff > 低血量 > 治疗范围。RGB 按 0-255 调整，A 按透明度百分比调整；治疗距离是唯一距离 Authority。",
	18, 364, 506, 54, 10, ALIGN_LEFT)

------------------------------------------------------------------------
-- Page 2: tracked Buff list + live observer
------------------------------------------------------------------------
trackedBuffOffset = 0
trackedBuffPageSize = 6
trackedBuffRows = {}

simpleOpenBuffObserver = CreatePageButton(2, "replicatedHealerSimpleOpenBuffObserver", "打开 Buff 观察器", 18, 94, 180, 26, 10)
CreatePageLabel(2, "replicatedHealerTrackedHelp",
	"观察器会读取当前选择成员身上的 Buff / Debuff / 隐藏 Buff。点击右侧“追加”进入判断列表。多人同时命中时，列表越靠上的 Buff 颜色优先。",
	210, 94, 314, 48, 10, ALIGN_LEFT)
CreatePageLabel(2, "replicatedHealerTrackedTitle", "判断列表", 18, 140, 260, 18, 11, ALIGN_LEFT)

for row = 1, trackedBuffPageSize do
	local y = 164 + (row - 1) * 40
	local rowIndex = row
	local item = {}
	item.label = CreatePageLabel(2, "replicatedHealerTrackedLabel" .. tostring(row), "", 18, y + 2, 250, 20, 10, ALIGN_LEFT)
	item.enabled = CreatePageButton(2, "replicatedHealerTrackedEnabled" .. tostring(row), "开", 274, y, 46, 22, 10)
	item.color = CreatePageButton(2, "replicatedHealerTrackedColor" .. tostring(row), "RGBA", 324, y, 78, 22, 9)
	item.up = CreatePageButton(2, "replicatedHealerTrackedUp" .. tostring(row), "上", 406, y, 34, 22, 10)
	item.down = CreatePageButton(2, "replicatedHealerTrackedDown" .. tostring(row), "下", 444, y, 34, 22, 10)
	item.remove = CreatePageButton(2, "replicatedHealerTrackedRemove" .. tostring(row), "删", 482, y, 42, 22, 10)
	local function AbsoluteIndex() return trackedBuffOffset + rowIndex end
	item.enabled:SetHandler("OnClick", function()
		local entry = state.trackedBuffs[AbsoluteIndex()]
		if entry ~= nil then entry.enabled = not entry.enabled SaveState() RefreshSettingsUi() end
	end)
	item.color:SetHandler("OnClick", function()
		local entry = state.trackedBuffs[AbsoluteIndex()]
		if entry ~= nil then OpenColorEditor(entry.color, entry.name .. " [" .. tostring(entry.id) .. "]") end
	end)
	item.up:SetHandler("OnClick", function()
		local index = AbsoluteIndex()
		if index > 1 and state.trackedBuffs[index] ~= nil then
			state.trackedBuffs[index], state.trackedBuffs[index - 1] = state.trackedBuffs[index - 1], state.trackedBuffs[index]
			SaveState() RefreshSettingsUi()
		end
	end)
	item.down:SetHandler("OnClick", function()
		local index = AbsoluteIndex()
		if index < #state.trackedBuffs and state.trackedBuffs[index] ~= nil then
			state.trackedBuffs[index], state.trackedBuffs[index + 1] = state.trackedBuffs[index + 1], state.trackedBuffs[index]
			SaveState() RefreshSettingsUi()
		end
	end)
	item.remove:SetHandler("OnClick", function()
		local index = AbsoluteIndex()
		if state.trackedBuffs[index] ~= nil then
			table.remove(state.trackedBuffs, index)
			trackedBuffOffset = math.min(trackedBuffOffset, math.floor(math.max(0, #state.trackedBuffs - 1) / trackedBuffPageSize) * trackedBuffPageSize)
			SaveState() RefreshSettingsUi()
		end
	end)
	trackedBuffRows[row] = item
end
trackedBuffPrev = CreatePageButton(2, "replicatedHealerTrackedPrev", "上一页", 18, 414, 100, 24, 10)
trackedBuffNext = CreatePageButton(2, "replicatedHealerTrackedNext", "下一页", 124, 414, 100, 24, 10)
trackedBuffPageLabel = CreatePageLabel(2, "replicatedHealerTrackedPage", "", 236, 416, 288, 20, 10, ALIGN_RIGHT)
trackedBuffPrev:SetHandler("OnClick", function() trackedBuffOffset = math.max(0, trackedBuffOffset - trackedBuffPageSize) RefreshSettingsUi() end)
trackedBuffNext:SetHandler("OnClick", function() local maxOffset = math.floor(math.max(0, #state.trackedBuffs - 1) / trackedBuffPageSize) * trackedBuffPageSize trackedBuffOffset = math.min(maxOffset, trackedBuffOffset + trackedBuffPageSize) RefreshSettingsUi() end)

------------------------------------------------------------------------
-- Buff Observer UI / paging / scan cadence moved to
-- presentation/rh_buff_observer.lua. Core2 only owns the settings control that
-- launches the presenter.
------------------------------------------------------------------------

------------------------------------------------------------------------
-- Page 5: team calibration
------------------------------------------------------------------------
simpleCalibrationButton = CreateCycleControl(5, "replicatedHealerSimpleCalibration", "团队列表校准模式", 94, function()
	if not state.enabled then
		X2Chat:DispatchChatMessage(CMF_SYSTEM, "Replicated：当前治疗辅助模块未启用，校准模式不会启动。")
		return
	end
	calibrationMode = not calibrationMode
	ApplyCalibrationMode()
end)
simpleCalibrationSectionButton = CreateCycleControl(5, "replicatedHealerSimpleCalibrationSection", "当前尺寸调整区域", 126, function()
	CycleCalibrationSectionInScope()
	ApplyCalibrationMode()
end)
simpleCalibrationScopeButton = CreateCycleControl(5, "replicatedHealerSimpleCalibrationScope", "校准显示范围", 158, function()
	state.raidCalibrationScope = Cycle(state.raidCalibrationScope, #CALIBRATION_SCOPE_LABELS, 1)
	NormalizeCalibrationSectionForScope()
	ApplyCalibrationMode()
end)
simpleRaidEffectButton = CreateCycleControl(5, "replicatedHealerSimpleRaidEffect", "团队覆盖显示效果", 190, function()
	state.raidEffectMode = Cycle(state.raidEffectMode, #EFFECT_LABELS, 1)
	RefreshRaidHighlights()
end)
simpleCalibrationHelp = CreatePageLabel(5, "replicatedHealerSimpleCalibrationHelp",
	"两团会显示 4 个框；仅1团/仅2团只显示对应团的 2 个框。每个框标题都会标明团号和成员范围，当前调整区域只会在可见团内切换。",
	18, 222, 506, 48, 10, ALIGN_LEFT)
simpleWidthMinus = CreatePageButton(5, "replicatedHealerSimpleWidthMinus", "宽 -", 18, 278, 120, 26, 10)
simpleWidthPlus = CreatePageButton(5, "replicatedHealerSimpleWidthPlus", "宽 +", 146, 278, 120, 26, 10)
simpleHeightMinus = CreatePageButton(5, "replicatedHealerSimpleHeightMinus", "高 -", 276, 278, 120, 26, 10)
simpleHeightPlus = CreatePageButton(5, "replicatedHealerSimpleHeightPlus", "高 +", 404, 278, 120, 26, 10)
simpleResetOverlay = CreatePageButton(5, "replicatedHealerSimpleResetOverlay", "恢复当前区域默认", 18, 314, 246, 26, 10)
simpleResetAllOverlays = CreatePageButton(5, "replicatedHealerSimpleResetAll", "恢复四个区域默认", 278, 314, 246, 26, 10)
simpleCalibrationInfo = CreatePageLabel(5, "replicatedHealerSimpleCalibrationInfo", "", 18, 352, 506, 76, 10, ALIGN_LEFT)

local function ResizeSelectedOverlay(dw, dh)
	local config = GetOverlayConfig(state.raidCalibrationSection)
	local x, y, width, height = ResolveAnchoredRect(config, config.width, config.height)
	StoreAnchoredRect(config, x, y, Clamp(width + (dw or 0), 180, 1200), Clamp(height + (dh or 0), 80, 600))
	LayoutRaidOverlays()
	SaveState()
	RefreshSettingsUi()
end
simpleWidthMinus:SetHandler("OnClick", function() ResizeSelectedOverlay(-5, 0) end)
simpleWidthPlus:SetHandler("OnClick", function() ResizeSelectedOverlay(5, 0) end)
simpleHeightMinus:SetHandler("OnClick", function() ResizeSelectedOverlay(0, -5) end)
simpleHeightPlus:SetHandler("OnClick", function() ResizeSelectedOverlay(0, 5) end)
simpleResetOverlay:SetHandler("OnClick", function()
	if state.raidCalibrationSection == 1 then state.raidOverlayTop = DeepCopy(defaults.raidOverlayTop)
	elseif state.raidCalibrationSection == 2 then state.raidOverlayBottom = DeepCopy(defaults.raidOverlayBottom)
	elseif state.raidCalibrationSection == 3 then state.raidOverlayTopRaid2 = DeepCopy(defaults.raidOverlayTopRaid2)
	else state.raidOverlayBottomRaid2 = DeepCopy(defaults.raidOverlayBottomRaid2) end
	LayoutRaidOverlays() SaveState() RefreshSettingsUi()
end)
simpleResetAllOverlays:SetHandler("OnClick", function()
	state.raidOverlayTop = DeepCopy(defaults.raidOverlayTop)
	state.raidOverlayBottom = DeepCopy(defaults.raidOverlayBottom)
	state.raidOverlayTopRaid2 = DeepCopy(defaults.raidOverlayTopRaid2)
	state.raidOverlayBottomRaid2 = DeepCopy(defaults.raidOverlayBottomRaid2)
	LayoutRaidOverlays() SaveState() RefreshSettingsUi()
end)

RefreshCalibrationCoordinateEdits()


-- Color editing buttons shared by display page.
colorChannel = 1
colorChannelLabels = { "R", "G", "B", "A" }
colorChannelButton = CreatePageButton(2, "replicatedHealerV2ColorChannel", "通道 R", 18, 454, 94, 22, 10)
colorMinusButton = CreatePageButton(2, "replicatedHealerV2ColorMinus", "-0.05", 118, 454, 70, 22, 10)
colorPlusButton = CreatePageButton(2, "replicatedHealerV2ColorPlus", "+0.05", 194, 454, 70, 22, 10)
colorChannelButton:SetHandler("OnClick", function() colorChannel = Cycle(colorChannel, 4, 1) RefreshSettingsUi() end)
function AdjustLevelColor(delta)
	local color = state.levelColors[selectedLevelColor]
	local key = ({ "r", "g", "b", "a" })[colorChannel]
	color[key] = Clamp(color[key] + delta, colorChannel == 4 and 0.05 or 0, 1)
	SaveState()
	RefreshSettingsUi()
end
colorMinusButton:SetHandler("OnClick", function() AdjustLevelColor(-0.05) end)
colorPlusButton:SetHandler("OnClick", function() AdjustLevelColor(0.05) end)

function GetSortedRoleOverrides()
	local rows = {}
	for name, role in pairs(state.roleOverrides) do
		rows[#rows + 1] = { name = name, role = role }
	end
	table.sort(rows, function(a, b) return a.name < b.name end)
	return rows
end
roleOverridePrev:SetHandler("OnClick", function() roleOverrideOffset = math.max(0, roleOverrideOffset - 6) RefreshSettingsUi() end)
roleOverrideNext:SetHandler("OnClick", function()
	local rows = GetSortedRoleOverrides()
	roleOverrideOffset = math.min(math.max(0, #rows - 6), roleOverrideOffset + 6)
	RefreshSettingsUi()
end)
roleOverrideDelete:SetHandler("OnClick", function()
	local rows = GetSortedRoleOverrides()
	local entry = rows[selectedRoleOverrideIndex]
	if entry ~= nil then
		state.roleOverrides[entry.name] = nil
		SaveState()
		if ReplicatedHealerRoster ~= nil and type(ReplicatedHealerRoster.Reclassify) == "function" then
			ReplicatedHealerRoster:Reclassify()
		else
			RebuildRoster()
		end
		RefreshSettingsUi()
	end
end)
for row = 1, 6 do
	roleOverrideRows[row]:SetHandler("OnClick", function()
		selectedRoleOverrideIndex = roleOverrideOffset + row
		local rows = GetSortedRoleOverrides()
		local entry = rows[selectedRoleOverrideIndex]
		if entry ~= nil then
			roleNameEdit:SetText(entry.name)
			roleOverrideMode = entry.role
			roleOverrideButton:SetText(ROLE_LABELS[roleOverrideMode])
		end
		RefreshSettingsUi()
	end)
end

RefreshSettingsUi = function()
	local suiteEnabled = state.enabled == true
	if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.ModuleManager ~= nil then
		suiteEnabled = ReplicatedSuite.ModuleManager:IsEnabled("healer")
	end
	if configAuthor ~= nil then
		configAuthor:SetText(suiteEnabled
			and "作者：Replicated · v3.0.9 治疗显示 / Buff追踪 / 团队校准"
			or "当前模块未启用 · 静态设置可修改 · Runtime 动作不可用")
	end
	if simpleOpenBuffObserver ~= nil and simpleOpenBuffObserver.Enable ~= nil then simpleOpenBuffObserver:Enable(suiteEnabled) end
	enabledButton:SetText(BooleanText(state.enabled))
	maxDistanceControl.value:SetText(string.format("%.0f 米", state.maxDistance))
	enterControl.value:SetText(string.format("%.0f%%", state.enterThreshold))
	exitControl.value:SetText(string.format("%.0f%%", state.exitThreshold))
	selfControl.value:SetText(string.format("%.0f%%", state.selfThreshold))
	emergencyControl.value:SetText(string.format("%.0f%%", state.emergencyThreshold))
	healthCurveButton:SetText(HEALTH_CURVE_LABELS[state.healthCurveMode])
	healthAccelButton:SetText(HEALTH_ACCEL_LABELS[state.healthAccelMode])
	distanceCurveButton:SetText(DISTANCE_CURVE_LABELS[state.distanceCurveMode])
	edgeControl.value:SetText(string.format("%.0f%%", state.distanceEdgePercent))
	weightHealthControl.value:SetText(string.format("%.1f%%", state.weights.health))
	weightDistanceControl.value:SetText(string.format("%.1f%%", state.weights.distance))
	weightMissingControl.value:SetText(string.format("%.1f%%", state.weights.missing))
	weightProtectionControl.value:SetText(string.format("%.1f%%", state.weights.unprotected))

	panelModeButton:SetText(PANEL_MODE_LABELS[state.panelMode])
	sortModeButton:SetText(SORT_MODE_LABELS[state.recommendSortMode])
	detailedButton:SetText(state.recommendDetailed and "详细" or "简洁")
	fullCountControl.value:SetText(tostring(state.fullRecommendCount))
	miniCountControl.value:SetText(tostring(state.miniRecommendCount))
	headCountControl.value:SetText(tostring(state.headMarkerCount))
	raidEffectButton:SetText(EFFECT_LABELS[state.raidEffectMode])
	headEffectButton:SetText(EFFECT_LABELS[state.headEffectMode])
	headShapeButton:SetText(HEAD_SHAPE_LABELS[state.headShapeMode])
	headLevelButton:SetText(LEVEL_LABELS[selectedHeadSizeLevel])
	headSizeControl.value:SetText(tostring(state.headSizes[selectedHeadSizeLevel]))
	raidRankCountControl.value:SetText(tostring(state.raidRankCount))
	raidRankCornerButton:SetText(RANK_CORNER_LABELS[state.raidRankCorner])
	showRaidRanksButton:SetText(BooleanText(state.showRaidRanks))
	colorChannelButton:SetText("通道 " .. colorChannelLabels[colorChannel])
	local color = state.levelColors[selectedLevelColor]
	displayColorPreview:SetText(string.format(
		"%s RGBA = %.2f, %.2f, %.2f, %.2f",
		LEVEL_LABELS[selectedLevelColor], color.r, color.g, color.b, color.a
	))
	displayColorPreview.style:SetColor(color.r, color.g, color.b, 1)

	for row = 1, 10 do
		local index = ruleListOffset + row
		local rule = state.rules[index]
		if rule ~= nil then
			ruleRows[row]:Show(true)
			ruleRows[row]:SetText(string.format(
				"%s%02d  %-18s  %-10s  %s",
				index == selectedRuleIndex and ">" or " ",
				index,
				rule.name,
				RULE_PURPOSE_LABELS[rule.purpose],
				rule.enabled and "启用" or "停用"
			))
		else
			ruleRows[row]:SetText("")
			ruleRows[row]:Show(false)
		end
	end
	local selectedRule = state.rules[selectedRuleIndex]
	if selectedRule ~= nil then
		ruleSummaryLabel:SetText(string.format(
			"选中：%s\nID：%s · %s · %s",
			selectedRule.name,
			JoinIdList(selectedRule.ids),
			RULE_EFFECT_LABELS[selectedRule.effectType],
			RULE_SOURCE_LABELS[selectedRule.sourceMode]
		))
	else
		ruleSummaryLabel:SetText("当前没有规则，可新增或重新添加默认规则。")
	end

	roleEnabledButton:SetText(BooleanText(state.roleScoringEnabled))
	roleMainTankControl.value:SetText(tostring(state.roleScores.mainTank))
	roleOffTankControl.value:SetText(tostring(state.roleScores.offTank))
	roleHealerControl.value:SetText(tostring(state.roleScores.healer))
	roleNormalControl.value:SetText(tostring(state.roleScores.normal))
	roleUnknownControl.value:SetText(tostring(state.roleScores.unknown))
	local overrideRows = GetSortedRoleOverrides()
	for row = 1, 6 do
		local entry = overrideRows[roleOverrideOffset + row]
		roleOverrideRows[row]:SetText(entry and string.format("%s  >  %s", entry.name, ROLE_LABELS[entry.role]) or "")
		roleOverrideRows[row]:Show(entry ~= nil)
	end
	roleOverrideButton:SetText(ROLE_LABELS[roleOverrideMode])

	calibrationButton:SetText(calibrationMode and "开" or "关")
	calibrationSectionButton:SetText(({ "1团上半区 1-25", "1团下半区 26-50", "2团上半区 1-25", "2团下半区 26-50" })[state.raidCalibrationSection])
	proximityButton:SetText(state.proximityMode and "开" or "关")
	proximityDistanceLabel:SetText(tostring(state.proximityDistance))
	proximityRLabel:SetText(string.format("%.2f", state.proximityColor.r))
	proximityGLabel:SetText(string.format("%.2f", state.proximityColor.g))
	proximityBLabel:SetText(string.format("%.2f", state.proximityColor.b))
	proximityALabel:SetText(string.format("%.2f", state.proximityColor.a))
	local config = GetOverlayConfig(state.raidCalibrationSection)
	local x, y, width, height = ResolveAnchoredRect(config, config.width, config.height)
	local screenWidth, screenHeight, uiScale = GetUiMetrics()
	calibrationInfo:SetText(string.format(
		"当前区域：%s · X %.0f  Y %.0f  宽 %.0f  高 %.0f\n屏幕：%dx%d · UI：%.0f%%\n淡蓝格仅用于对齐；实时候选颜色会覆盖对应成员格。",
		({ "1团上半区", "1团下半区", "2团上半区", "2团下半区" })[state.raidCalibrationSection],
		x, y, width, height,
		screenWidth, screenHeight, uiScale * 100
	))

	if simpleEnabledButton ~= nil then
		simpleEnabledButton:SetText(BooleanText(state.enabled))
		simpleDistanceControl.value:SetText(string.format("%.0f 米", state.maxDistance))
		simpleLowHealthControl.value:SetText(string.format("%.0f%%", state.lowHealthThreshold))
		simpleEmergencyControl.value:SetText(string.format("%.0f%%", state.emergencyThreshold))
		simpleRangeTintButton:SetText(BooleanText(state.proximityMode))
		simpleRangeColorRow.value:SetText(ColorToDisplayText(state.proximityColor))
		simpleLowColorRow.value:SetText(ColorToDisplayText(state.lowHealthColor))
		simpleEmergencyColorRow.value:SetText(ColorToDisplayText(state.emergencyColor))

		trackedBuffOffset = math.min(trackedBuffOffset, math.floor(math.max(0, #state.trackedBuffs - 1) / trackedBuffPageSize) * trackedBuffPageSize)
		for row = 1, trackedBuffPageSize do
			local entry = state.trackedBuffs[trackedBuffOffset + row]
			local item = trackedBuffRows[row]
			local hidden = entry == nil
			item.label.rhSettingsHidden = hidden
			item.enabled.rhSettingsHidden = hidden
			item.color.rhSettingsHidden = hidden
			item.up.rhSettingsHidden = hidden
			item.down.rhSettingsHidden = hidden
			item.remove.rhSettingsHidden = hidden
			if entry ~= nil then
				item.label:SetText(string.format("%s  [ID:%s]", tostring(entry.name), tostring(entry.id)))
				item.enabled:SetText(entry.enabled ~= false and "开" or "关")
				local c = entry.color or {}
				item.color:SetText(string.format("%d/%d/%d/%d",
					math.floor(Clamp(c.r or 0, 0, 1) * 255 + 0.5),
					math.floor(Clamp(c.g or 0, 0, 1) * 255 + 0.5),
					math.floor(Clamp(c.b or 0, 0, 1) * 255 + 0.5),
					math.floor(Clamp(c.a or 0, 0, 1) * 100 + 0.5)))
			else
				item.label:SetText("")
			end
		end
		local trackedPage = math.floor(trackedBuffOffset / trackedBuffPageSize) + 1
		local trackedPages = math.max(1, math.ceil(#state.trackedBuffs / trackedBuffPageSize))
		trackedBuffPageLabel:SetText(string.format("第 %d/%d 页 · %d 条 · 上方优先", trackedPage, trackedPages, #state.trackedBuffs))

		simpleCalibrationButton:SetText(calibrationMode and "开" or "关")
		if simpleCalibrationButton.Enable ~= nil then simpleCalibrationButton:Enable(state.enabled == true) end
		simpleRaidEffectButton:SetText(EFFECT_LABELS[state.raidEffectMode])
		NormalizeCalibrationSectionForScope()
		simpleCalibrationScopeButton:SetText(CALIBRATION_SCOPE_LABELS[state.raidCalibrationScope])
		simpleCalibrationSectionButton:SetText(({ "1团上半区 1-25", "1团下半区 26-50", "2团上半区 1-25", "2团下半区 26-50" })[state.raidCalibrationSection])
		simpleCalibrationInfo:SetText(string.format(
			"显示范围：%s · 当前选择：%s\n宽 %.0f · 高 %.0f\n只显示单团时，团号由范围选项和框标题双重确认。",
			CALIBRATION_SCOPE_LABELS[state.raidCalibrationScope],
			({ "1团上半区", "1团下半区", "2团上半区", "2团下半区" })[state.raidCalibrationSection],
			width, height
		))
	end
	SetSettingsPage(state.settingsPage)
	colorChannelButton:Show(false)
	colorMinusButton:Show(false)
	colorPlusButton:Show(false)
	displayColorPreview:Show(false)
end

SetSettingsPage(state.settingsPage)

end

-- Suite mode owns all settings UI inside the main window.  The historical
-- standalone settings window is not even constructed while embedded; keeping
-- it alive was both a second UI Authority and a boot-failure surface on RU
-- clients where one of the old widget types/layers is unavailable.
if ReplicatedSuiteEmbedded == true then
	function ApplyHealerRuntimeEnabled(enabled)
		state.enabled = enabled == true
		if state.enabled then
			teamRosterSettleRemainingMs = math.max(tonumber(teamRosterSettleRemainingMs) or 0, 900)
			teamRosterZOrderPending = true
			rosterElapsed = 0
			healthElapsed = 0
			buffElapsed = 0
			if ReplicatedHealerBoot ~= nil then ReplicatedHealerBoot.runtimeError = nil end
		else
			recommendations = {}
			unavailable = {}
			healthSnapshot = {}
		end
	end
	function SetHealerRuntimeEnabled(enabled)
		if ReplicatedSuite ~= nil and ReplicatedSuite.ModuleManager ~= nil then
			return ReplicatedSuite.ModuleManager:SetEnabled("healer", enabled == true)
		end
		ApplyHealerRuntimeEnabled(enabled)
		return true
	end
	function SetSettingsPage(pageIndex) state.settingsPage = tonumber(pageIndex) or 1 end
	RefreshSettingsUi = function() end
else
	InitializeSettingsUi()
end

-----------------------------------------------------------------------
-- Rule editor (three compact tabs)
-----------------------------------------------------------------------

function InitializeRuleEditor()
ruleDraft = nil
ruleEditorPage = 1
ruleEditorPages = { {}, {}, {} }
ruleEditorTabs = {}

function RegisterRuleEditorWidget(pageIndex, widget)
	ruleEditorPages[pageIndex][#ruleEditorPages[pageIndex] + 1] = widget
	return widget
end

function SetRuleEditorPage(pageIndex)
	ruleEditorPage = math.floor(Clamp(pageIndex, 1, 3))
	for index = 1, 3 do
		for _, widget in ipairs(ruleEditorPages[index]) do
			widget:Show(index == ruleEditorPage)
		end
		ruleEditorTabs[index]:SetText((index == ruleEditorPage and "[" or "") .. ({ "基础", "评分", "显示/距离" })[index] .. (index == ruleEditorPage and "]" or ""))
	end
end

ruleEditorWindow = CreateEmptyWindow("replicatedHealerV2RuleEditor", "UIParent")
ruleEditorWindow:SetExtent(RULE_EDITOR_WIDTH, RULE_EDITOR_HEIGHT)
ruleEditorWindow:AddAnchor("CENTER", "UIParent", 0, 0)
ruleEditorWindow:SetUILayer(TOP_LAYER)
ruleEditorWindow:SetCloseOnEscape(true)
ruleEditorWindow:Enable(true)
ruleEditorWindow:Clickable(true)
ruleEditorWindow:EnableDrag(true)
ruleEditorWindow:Show(false)
RegisterHealerFloating("rule_editor", ruleEditorWindow, { onlyWhenVisible = true, fitSize = true })
CreateBackground(ruleEditorWindow, 0.03, 0.04, 0.06, 0.98)
editorHeader = ruleEditorWindow:CreateColorDrawable(0.11, 0.18, 0.28, 0.97, "background")
editorHeader:AddAnchor("TOPLEFT", ruleEditorWindow, 0, 0)
editorHeader:SetExtent(RULE_EDITOR_WIDTH, 48)
editorTitle = CreateLabel(ruleEditorWindow, "replicatedHealerV2RuleEditorTitle", "状态规则编辑 · Replicated", 12, 7, 430, 22, 16, ALIGN_LEFT)
editorTitle.style:SetOutline(true)
editorClose = CreateTextButton(ruleEditorWindow, "replicatedHealerV2RuleEditorClose", "X", 526, 7, 26, 24, 11)
editorClose:SetHandler("OnClick", function() ruleEditorWindow:Show(false) end)
ruleEditorWindow:SetHandler("OnDragStart", function(self) BeginHealerSafeMove(self, "healer_rule_editor", true) return true end)
ruleEditorWindow:SetHandler("OnDragStop", function(self) EndHealerSafeMove(self) end)

for index = 1, 3 do
	ruleEditorTabs[index] = CreateTextButton(
		ruleEditorWindow,
		"replicatedHealerV2RuleEditorTab" .. tostring(index),
		({ "基础", "评分", "显示/距离" })[index],
		12 + (index - 1) * 178,
		54,
		170,
		24,
		11
	)
	ruleEditorTabs[index]:SetHandler("OnClick", function() SetRuleEditorPage(index) RefreshRuleEditorUi(false) end)
end

function CreateEditorLabel(pageIndex, id, text, x, y, width, height, fontSize)
	return RegisterRuleEditorWidget(pageIndex, CreateLabel(ruleEditorWindow, id, text, x, y, width, height, fontSize or 11, ALIGN_LEFT))
end
function CreateEditorButton(pageIndex, id, text, x, y, width, height)
	return RegisterRuleEditorWidget(pageIndex, CreateTextButton(ruleEditorWindow, id, text, x, y, width, height, 10))
end
function CreateEditorCycle(pageIndex, id, labelText, y, onClick)
	CreateEditorLabel(pageIndex, id .. "Label", labelText, 18, y + 2, 255, 20, 11)
	local button = CreateEditorButton(pageIndex, id .. "Button", "", 318, y, 206, 22)
	button:SetHandler("OnClick", function() onClick() RefreshRuleEditorUi(false) end)
	return button
end
function CreateEditorValue(pageIndex, id, labelText, y, onMinus, onPlus)
	CreateEditorLabel(pageIndex, id .. "Label", labelText, 18, y + 2, 255, 20, 11)
	local minus = CreateEditorButton(pageIndex, id .. "Minus", "-", 318, y, 34, 22)
	local value = CreateEditorLabel(pageIndex, id .. "Value", "", 356, y + 1, 126, 20, 11)
	value.style:SetAlign(ALIGN_CENTER)
	local plus = CreateEditorButton(pageIndex, id .. "Plus", "+", 486, y, 38, 22)
	minus:SetHandler("OnClick", function() onMinus() RefreshRuleEditorUi(false) end)
	plus:SetHandler("OnClick", function() onPlus() RefreshRuleEditorUi(false) end)
	return { value = value }
end

-- Basic page
CreateEditorLabel(1, "replicatedHealerV2RuleNameLabel", "规则名称", 18, 90, 120, 20, 11)
ruleNameEdit = RegisterRuleEditorWidget(1, CreateEditBox(ruleEditorWindow, "replicatedHealerV2RuleNameEdit", 150, 88, 374, 24, 32))
CreateEditorLabel(1, "replicatedHealerV2RuleIdsLabel", "状态 ID（逗号分隔）", 18, 120, 130, 20, 11)
ruleIdsEdit = RegisterRuleEditorWidget(1, CreateEditBox(ruleEditorWindow, "replicatedHealerV2RuleIdsEdit", 150, 118, 374, 24, 256))
ruleEnabledButton = CreateEditorCycle(1, "replicatedHealerV2RuleEnabled", "启用规则", 150,
	function() ruleDraft.enabled = not ruleDraft.enabled end)
rulePurposeButton = CreateEditorCycle(1, "replicatedHealerV2RulePurpose", "规则用途（切换不自动覆盖）", 178,
	function() ruleDraft.purpose = Cycle(ruleDraft.purpose, #RULE_PURPOSE_LABELS, 1) end)
applyPurposeTemplateButton = CreateEditorButton(1, "replicatedHealerV2ApplyPurpose", "套用当前用途模板（会重置相关参数）", 318, 206, 206, 22)
applyPurposeTemplateButton:SetHandler("OnClick", function()
	local name = tostring(ruleNameEdit:GetText() or ruleDraft.name)
	local ids = ParseIdList(ruleIdsEdit:GetText())
	ruleDraft = NewRuleByPurpose(ruleDraft.purpose)
	ruleDraft.name = name
	ruleDraft.ids = ids
	RefreshRuleEditorUi(false)
end)
ruleSourceButton = CreateEditorCycle(1, "replicatedHealerV2RuleSource", "检测范围", 238,
	function() ruleDraft.sourceMode = Cycle(ruleDraft.sourceMode, #RULE_SOURCE_LABELS, 1) end)
ruleMatchButton = CreateEditorCycle(1, "replicatedHealerV2RuleMatch", "多个 ID 的匹配方式", 266,
	function() ruleDraft.matchMode = Cycle(ruleDraft.matchMode, #RULE_MATCH_LABELS, 1) end)
ruleStackControl = CreateEditorValue(1, "replicatedHealerV2RuleMinStack", "最小有效层数", 294,
	function() ruleDraft.minStacks = Clamp(ruleDraft.minStacks - 1, 1, 99) end,
	function() ruleDraft.minStacks = Clamp(ruleDraft.minStacks + 1, 1, 99) end)
ruleRemainingControl = CreateEditorValue(1, "replicatedHealerV2RuleRemaining", "最小有效剩余时间", 322,
	function() ruleDraft.minRemainingMs = Clamp(ruleDraft.minRemainingMs - 500, 0, 3600000) end,
	function() ruleDraft.minRemainingMs = Clamp(ruleDraft.minRemainingMs + 500, 0, 3600000) end)
ruleUnknownButton = CreateEditorCycle(1, "replicatedHealerV2RuleUnknown", "剩余时间未知时视为有效", 350,
	function() ruleDraft.unknownRemainingValid = not ruleDraft.unknownRemainingValid end)
ruleHealthRangeButton = CreateEditorCycle(1, "replicatedHealerV2RuleHealthRange", "生命百分比生效范围", 378,
	function() ruleDraft.healthRangeEnabled = not ruleDraft.healthRangeEnabled end)
ruleHealthMinControl = CreateEditorValue(1, "replicatedHealerV2RuleHealthMin", "最低生命百分比", 406,
	function() ruleDraft.healthMin = Clamp(ruleDraft.healthMin - 5, 0, ruleDraft.healthMax) end,
	function() ruleDraft.healthMin = Clamp(ruleDraft.healthMin + 5, 0, ruleDraft.healthMax) end)
ruleHealthMaxControl = CreateEditorValue(1, "replicatedHealerV2RuleHealthMax", "最高生命百分比", 434,
	function() ruleDraft.healthMax = Clamp(ruleDraft.healthMax - 5, ruleDraft.healthMin, 100) end,
	function() ruleDraft.healthMax = Clamp(ruleDraft.healthMax + 5, ruleDraft.healthMin, 100) end)

-- Score page
ruleEffectButton = CreateEditorCycle(2, "replicatedHealerV2RuleEffect", "规则作用类型", 90,
	function() ruleDraft.effectType = Cycle(ruleDraft.effectType, #RULE_EFFECT_LABELS, 1) end)
ruleScoreModeButton = CreateEditorCycle(2, "replicatedHealerV2RuleScoreMode", "评分计算方式", 118,
	function() ruleDraft.scoreMode = Cycle(ruleDraft.scoreMode, #RULE_SCORE_MODE_LABELS, 1) end)
ruleScoreValueControl = CreateEditorValue(2, "replicatedHealerV2RuleScoreValue", "提高/降低数值", 146,
	function() ruleDraft.scoreValue = Clamp(ruleDraft.scoreValue - 1, 0, 500) end,
	function() ruleDraft.scoreValue = Clamp(ruleDraft.scoreValue + 1, 0, 500) end)
ruleAllowStackButton = CreateEditorCycle(2, "replicatedHealerV2RuleAllowStack", "允许与其他规则叠加", 174,
	function() ruleDraft.allowStack = not ruleDraft.allowStack end)
ruleEmergencyRetainControl = CreateEditorValue(2, "replicatedHealerV2RuleEmergencyRetain", "紧急状态扣分保留比例", 202,
	function() ruleDraft.emergencyRetainPercent = Clamp(ruleDraft.emergencyRetainPercent - 5, 0, 100) end,
	function() ruleDraft.emergencyRetainPercent = Clamp(ruleDraft.emergencyRetainPercent + 5, 0, 100) end)
ruleProtectionButton = CreateEditorCycle(2, "replicatedHealerV2RuleProtection", "计入已有治疗保护", 230,
	function() ruleDraft.countsAsProtection = not ruleDraft.countsAsProtection end)
ruleRescuePriorityControl = CreateEditorValue(2, "replicatedHealerV2RuleRescuePriority", "强制紧急救援优先级", 258,
	function() ruleDraft.rescuePriority = Clamp(ruleDraft.rescuePriority - 5, 0, 999) end,
	function() ruleDraft.rescuePriority = Clamp(ruleDraft.rescuePriority + 5, 0, 999) end)
CreateEditorLabel(2, "replicatedHealerV2RuleScoreHelp",
	"执行顺序：直接排除 > 强制紧急 > 百分比合并 > 固定分数。\n不允许叠加的同方向规则只取影响最大者。",
	18, 310, 506, 54, 11)

-- Display/distance page
ruleDisplayPriorityControl = CreateEditorValue(3, "replicatedHealerV2RuleDisplayPriority", "颜色显示优先级", 90,
	function() ruleDraft.displayPriority = Clamp(ruleDraft.displayPriority - 5, 0, 999) end,
	function() ruleDraft.displayPriority = Clamp(ruleDraft.displayPriority + 5, 0, 999) end)
ruleDistanceModeButton = CreateEditorCycle(3, "replicatedHealerV2RuleDistanceMode", "规则作用距离", 118,
	function() ruleDraft.distanceMode = Cycle(ruleDraft.distanceMode, #RULE_DISTANCE_MODE_LABELS, 1) end)
ruleDistanceControl = CreateEditorValue(3, "replicatedHealerV2RuleDistance", "自定义作用距离", 146,
	function() ruleDraft.customDistance = Clamp(ruleDraft.customDistance - 1, 1, 100) end,
	function() ruleDraft.customDistance = Clamp(ruleDraft.customDistance + 1, 1, 100) end)
ruleHealPriorityControl = CreateEditorValue(3, "replicatedHealerV2RuleHealPriority", "控制规则治疗优先分界线", 174,
	function() ruleDraft.healPriorityThreshold = Clamp(ruleDraft.healPriorityThreshold - 5, 0, 100) end,
	function() ruleDraft.healPriorityThreshold = Clamp(ruleDraft.healPriorityThreshold + 5, 0, 100) end)
ruleExcludeDisplayButton = CreateEditorCycle(3, "replicatedHealerV2RuleExcludeDisplay", "直接排除后的显示方式", 202,
	function() ruleDraft.excludeDisplayMode = Cycle(ruleDraft.excludeDisplayMode, #EXCLUDE_DISPLAY_LABELS, 1) end)
editorColorChannel = 1
editorColorChannelButton = CreateEditorButton(3, "replicatedHealerV2RuleColorChannel", "颜色通道 R", 18, 246, 130, 22)
editorColorMinus = CreateEditorButton(3, "replicatedHealerV2RuleColorMinus", "-0.05", 154, 246, 78, 22)
editorColorPlus = CreateEditorButton(3, "replicatedHealerV2RuleColorPlus", "+0.05", 238, 246, 78, 22)
editorColorPreview = CreateEditorLabel(3, "replicatedHealerV2RuleColorPreview", "", 18, 278, 506, 24, 11)
editorColorPreview.style:SetAlign(ALIGN_CENTER)
editorColorChannelButton:SetHandler("OnClick", function() editorColorChannel = Cycle(editorColorChannel, 4, 1) RefreshRuleEditorUi(false) end)
function AdjustRuleColor(delta)
	local key = ({ "r", "g", "b", "a" })[editorColorChannel]
	ruleDraft.color[key] = Clamp(ruleDraft.color[key] + delta, editorColorChannel == 4 and 0.05 or 0, 1)
	RefreshRuleEditorUi(false)
end
editorColorMinus:SetHandler("OnClick", function() AdjustRuleColor(-0.05) end)
editorColorPlus:SetHandler("OnClick", function() AdjustRuleColor(0.05) end)
CreateEditorLabel(3, "replicatedHealerV2RuleDisplayHelp",
	"治疗等级颜色优先级为50。默认持续回血规则为10，不覆盖红/橙；\n控制规则默认100，但血量低于治疗优先分界线时仍使用治疗颜色。",
	18, 322, 506, 54, 11)

editorSave = CreateTextButton(ruleEditorWindow, "replicatedHealerV2RuleEditorSave", "保存规则", 318, 462, 100, 26, 11)
editorCancel = CreateTextButton(ruleEditorWindow, "replicatedHealerV2RuleEditorCancel", "取消", 424, 462, 100, 26, 11)
editorCancel:SetHandler("OnClick", function() ruleEditorWindow:Show(false) end)
editorSave:SetHandler("OnClick", function()
	if ruleDraft ~= nil and state.rules[selectedRuleIndex] ~= nil then
		ruleDraft.name = tostring(ruleNameEdit:GetText() or ruleDraft.name)
		ruleDraft.ids = ParseIdList(ruleIdsEdit:GetText())
		NormalizeRule(ruleDraft)
		state.rules[selectedRuleIndex] = DeepCopy(ruleDraft)
		SaveState()
		ruleEditorWindow:Show(false)
		RefreshSettingsUi()
	end
end)

RefreshRuleEditorUi = function(reloadDraft)
	if reloadDraft or ruleDraft == nil then
		local source = state.rules[selectedRuleIndex]
		if source == nil then return end
		ruleDraft = DeepCopy(source)
		ruleNameEdit:SetText(ruleDraft.name)
		ruleIdsEdit:SetText(JoinIdList(ruleDraft.ids))
	end
	ruleEnabledButton:SetText(BooleanText(ruleDraft.enabled))
	rulePurposeButton:SetText(RULE_PURPOSE_LABELS[ruleDraft.purpose])
	ruleSourceButton:SetText(RULE_SOURCE_LABELS[ruleDraft.sourceMode])
	ruleMatchButton:SetText(RULE_MATCH_LABELS[ruleDraft.matchMode])
	ruleStackControl.value:SetText(tostring(ruleDraft.minStacks))
	ruleRemainingControl.value:SetText(string.format("%.1f 秒", ruleDraft.minRemainingMs / 1000))
	ruleUnknownButton:SetText(BooleanText(ruleDraft.unknownRemainingValid))
	ruleHealthRangeButton:SetText(ruleDraft.healthRangeEnabled and "自定义范围" or "不限")
	ruleHealthMinControl.value:SetText(string.format("%.0f%%", ruleDraft.healthMin))
	ruleHealthMaxControl.value:SetText(string.format("%.0f%%", ruleDraft.healthMax))
	ruleEffectButton:SetText(RULE_EFFECT_LABELS[ruleDraft.effectType])
	ruleScoreModeButton:SetText(RULE_SCORE_MODE_LABELS[ruleDraft.scoreMode])
	ruleScoreValueControl.value:SetText(tostring(ruleDraft.scoreValue))
	ruleAllowStackButton:SetText(BooleanText(ruleDraft.allowStack))
	ruleEmergencyRetainControl.value:SetText(string.format("%.0f%%", ruleDraft.emergencyRetainPercent))
	ruleProtectionButton:SetText(BooleanText(ruleDraft.countsAsProtection))
	ruleRescuePriorityControl.value:SetText(tostring(ruleDraft.rescuePriority))
	ruleDisplayPriorityControl.value:SetText(tostring(ruleDraft.displayPriority))
	ruleDistanceModeButton:SetText(RULE_DISTANCE_MODE_LABELS[ruleDraft.distanceMode])
	ruleDistanceControl.value:SetText(string.format("%.0f 米", ruleDraft.customDistance))
	ruleHealPriorityControl.value:SetText(string.format("%.0f%%", ruleDraft.healPriorityThreshold))
	ruleExcludeDisplayButton:SetText(EXCLUDE_DISPLAY_LABELS[ruleDraft.excludeDisplayMode])
	editorColorChannelButton:SetText("颜色通道 " .. ({ "R", "G", "B", "A" })[editorColorChannel])
	editorColorPreview:SetText(string.format("RGBA = %.2f, %.2f, %.2f, %.2f", ruleDraft.color.r, ruleDraft.color.g, ruleDraft.color.b, ruleDraft.color.a))
	editorColorPreview.style:SetColor(ruleDraft.color.r, ruleDraft.color.g, ruleDraft.color.b, 1)
	SetRuleEditorPage(ruleEditorPage)
	ruleEditorWindow:SetUILayer(TOP_LAYER)
	ruleEditorWindow:Raise()
end

SetRuleEditorPage(1)

end
if ReplicatedSuiteEmbedded ~= true then InitializeRuleEditor() end

-----------------------------------------------------------------------
-- Advanced score/display settings
-----------------------------------------------------------------------

function InitializeAdvancedSettings()
advancedWindow = CreateEmptyWindow("replicatedHealerV2AdvancedWindow", "UIParent")
advancedWindow:SetExtent(520, 440)
advancedWindow:AddAnchor("CENTER", "UIParent", 0, 0)
advancedWindow:SetUILayer(TOP_LAYER)
advancedWindow:SetCloseOnEscape(true)
advancedWindow:Enable(true)
advancedWindow:Clickable(true)
advancedWindow:EnableDrag(true)
advancedWindow:Show(false)
RegisterHealerFloating("advanced", advancedWindow, { onlyWhenVisible = true, fitSize = true })
CreateBackground(advancedWindow, 0.03, 0.04, 0.06, 0.98)
advancedHeader = advancedWindow:CreateColorDrawable(0.10, 0.17, 0.27, 0.96, "background")
advancedHeader:AddAnchor("TOPLEFT", advancedWindow, 0, 0)
advancedHeader:SetExtent(520, 45)
advancedTitle = CreateLabel(advancedWindow, "replicatedHealerV2AdvancedTitle", "高级参数 · Replicated", 12, 7, 390, 22, 16, ALIGN_LEFT)
advancedClose = CreateTextButton(advancedWindow, "replicatedHealerV2AdvancedClose", "X", 486, 7, 26, 24, 11)
advancedClose:SetHandler("OnClick", function() advancedWindow:Show(false) end)
advancedWindow:SetHandler("OnDragStart", function(self) BeginHealerSafeMove(self, "healer_advanced", true) return true end)
advancedWindow:SetHandler("OnDragStop", function(self) EndHealerSafeMove(self) end)
advancedPage = 1
advancedPages = { {}, {} }
advancedTabs = {}
function RegisterAdvanced(pageIndex, widget)
	advancedPages[pageIndex][#advancedPages[pageIndex] + 1] = widget
	return widget
end
function SetAdvancedPage(pageIndex)
	advancedPage = pageIndex
	for index = 1, 2 do
		for _, widget in ipairs(advancedPages[index]) do widget:Show(index == advancedPage) end
		advancedTabs[index]:SetText((index == advancedPage and "[" or "") .. ({ "评分高级", "显示高级" })[index] .. (index == advancedPage and "]" or ""))
	end
end
for index = 1, 2 do
	advancedTabs[index] = CreateTextButton(advancedWindow, "replicatedHealerV2AdvancedTab" .. index, ({ "评分高级", "显示高级" })[index], 12 + (index - 1) * 250, 52, 244, 24, 11)
	advancedTabs[index]:SetHandler("OnClick", function() SetAdvancedPage(index) end)
end
function CreateAdvancedLabel(pageIndex, id, text, y)
	return RegisterAdvanced(pageIndex, CreateLabel(advancedWindow, id, text, 18, y + 2, 260, 20, 11, ALIGN_LEFT))
end
function CreateAdvancedValue(pageIndex, id, text, y, onMinus, onPlus)
	CreateAdvancedLabel(pageIndex, id .. "Label", text, y)
	local minus = RegisterAdvanced(pageIndex, CreateTextButton(advancedWindow, id .. "Minus", "-", 300, y, 34, 22, 10))
	local value = RegisterAdvanced(pageIndex, CreateLabel(advancedWindow, id .. "Value", "", 340, y + 1, 110, 20, 11, ALIGN_CENTER))
	local plus = RegisterAdvanced(pageIndex, CreateTextButton(advancedWindow, id .. "Plus", "+", 456, y, 38, 22, 10))
	minus:SetHandler("OnClick", function() onMinus() SaveState() RefreshSettingsUi() end)
	plus:SetHandler("OnClick", function() onPlus() SaveState() RefreshSettingsUi() end)
	return value
end
function CreateAdvancedToggle(pageIndex, id, text, y, onClick)
	CreateAdvancedLabel(pageIndex, id .. "Label", text, y)
	local button = RegisterAdvanced(pageIndex, CreateTextButton(advancedWindow, id .. "Button", "", 300, y, 194, 22, 10))
	button:SetHandler("OnClick", function() onClick() SaveState() RefreshSettingsUi() end)
	return button
end

advancedHealthScan = CreateAdvancedValue(1, "replicatedHealerV2AdvancedHealthScan", "血量/距离扫描间隔", 88,
	function() state.healthScanMs = Clamp(state.healthScanMs - 50, 100, 1000) end,
	function() state.healthScanMs = Clamp(state.healthScanMs + 50, 100, 1000) end)
advancedBuffScan = CreateAdvancedValue(1, "replicatedHealerV2AdvancedBuffScan", "状态全量扫描间隔", 116,
	function() state.buffScanMs = Clamp(state.buffScanMs - 50, 200, 2000) end,
	function() state.buffScanMs = Clamp(state.buffScanMs + 50, 200, 2000) end)
advancedSensitivity = CreateAdvancedValue(1, "replicatedHealerV2AdvancedSensitivity", "缺失生命平滑敏感度", 144,
	function() state.missingSensitivity = Clamp(state.missingSensitivity - 5000, 5000, 200000) end,
	function() state.missingSensitivity = Clamp(state.missingSensitivity + 5000, 5000, 200000) end)
advancedHold = CreateAdvancedValue(1, "replicatedHealerV2AdvancedHold", "候选最短保持时间", 172,
	function() state.minHoldMs = Clamp(state.minHoldMs - 100, 0, 5000) end,
	function() state.minHoldMs = Clamp(state.minHoldMs + 100, 0, 5000) end)
advancedLead = CreateAdvancedValue(1, "replicatedHealerV2AdvancedLead", "名次立即顶替分差", 200,
	function() state.scoreLead = Clamp(state.scoreLead - 1, 0, 50) end,
	function() state.scoreLead = Clamp(state.scoreLead + 1, 0, 50) end)
advancedAttention = CreateAdvancedValue(1, "replicatedHealerV2AdvancedAttention", "需要关注等级阈值", 228,
	function() state.levelThresholds.attention = Clamp(state.levelThresholds.attention - 1, 1, state.levelThresholds.high - 1) end,
	function() state.levelThresholds.attention = Clamp(state.levelThresholds.attention + 1, 1, state.levelThresholds.high - 1) end)
advancedHigh = CreateAdvancedValue(1, "replicatedHealerV2AdvancedHigh", "高危等级阈值", 256,
	function() state.levelThresholds.high = Clamp(state.levelThresholds.high - 1, state.levelThresholds.attention + 1, state.levelThresholds.emergency - 1) end,
	function() state.levelThresholds.high = Clamp(state.levelThresholds.high + 1, state.levelThresholds.attention + 1, state.levelThresholds.emergency - 1) end)
advancedEmergency = CreateAdvancedValue(1, "replicatedHealerV2AdvancedEmergency", "紧急等级阈值", 284,
	function() state.levelThresholds.emergency = Clamp(state.levelThresholds.emergency - 1, state.levelThresholds.high + 1, 100) end,
	function() state.levelThresholds.emergency = Clamp(state.levelThresholds.emergency + 1, state.levelThresholds.high + 1, 100) end)

advancedHeadName = CreateAdvancedToggle(2, "replicatedHealerV2AdvancedHeadName", "头顶显示玩家名字", 88, function() state.showHeadName = not state.showHeadName end)
advancedHeadDistance = CreateAdvancedToggle(2, "replicatedHealerV2AdvancedHeadDistance", "头顶显示距离", 116, function() state.showHeadDistance = not state.showHeadDistance end)
advancedHeadScore = CreateAdvancedToggle(2, "replicatedHealerV2AdvancedHeadScore", "头顶显示评分", 144, function() state.showHeadScore = not state.showHeadScore end)
advancedRankFont = CreateAdvancedValue(2, "replicatedHealerV2AdvancedRankFont", "团队格名次字号", 172,
	function() state.raidRankFontSize = Clamp(state.raidRankFontSize - 1, 8, 20) LayoutRaidOverlays() end,
	function() state.raidRankFontSize = Clamp(state.raidRankFontSize + 1, 8, 20) LayoutRaidOverlays() end)
advancedRankAlpha = CreateAdvancedValue(2, "replicatedHealerV2AdvancedRankAlpha", "团队格名次透明度", 200,
	function() state.raidRankAlpha = Clamp(state.raidRankAlpha - 0.1, 0.1, 1) end,
	function() state.raidRankAlpha = Clamp(state.raidRankAlpha + 0.1, 0.1, 1) end)
advancedRankX = CreateAdvancedValue(2, "replicatedHealerV2AdvancedRankX", "团队格名次水平偏移", 228,
	function() state.raidRankOffsetX = Clamp(state.raidRankOffsetX - 1, -20, 20) LayoutRaidOverlays() end,
	function() state.raidRankOffsetX = Clamp(state.raidRankOffsetX + 1, -20, 20) LayoutRaidOverlays() end)
advancedRankY = CreateAdvancedValue(2, "replicatedHealerV2AdvancedRankY", "团队格名次垂直偏移", 256,
	function() state.raidRankOffsetY = Clamp(state.raidRankOffsetY - 1, -20, 20) LayoutRaidOverlays() end,
	function() state.raidRankOffsetY = Clamp(state.raidRankOffsetY + 1, -20, 20) LayoutRaidOverlays() end)
advancedSelectedLevel = 4
advancedColorChannel = 1
advancedLevelButton = CreateAdvancedToggle(2, "replicatedHealerV2AdvancedLevel", "正在编辑的救援等级颜色", 294,
	function() advancedSelectedLevel = Cycle(advancedSelectedLevel, 4, 1) end)
advancedChannelButton = CreateAdvancedToggle(2, "replicatedHealerV2AdvancedChannel", "颜色通道", 322,
	function() advancedColorChannel = Cycle(advancedColorChannel, 4, 1) end)
advancedColorValue = CreateAdvancedValue(2, "replicatedHealerV2AdvancedColorValue", "当前颜色通道数值", 350,
	function()
		local key = ({ "r", "g", "b", "a" })[advancedColorChannel]
		state.levelColors[advancedSelectedLevel][key] = Clamp(state.levelColors[advancedSelectedLevel][key] - 0.05, advancedColorChannel == 4 and 0.05 or 0, 1)
	end,
	function()
		local key = ({ "r", "g", "b", "a" })[advancedColorChannel]
		state.levelColors[advancedSelectedLevel][key] = Clamp(state.levelColors[advancedSelectedLevel][key] + 0.05, advancedColorChannel == 4 and 0.05 or 0, 1)
	end)
advancedPreview = RegisterAdvanced(2, CreateLabel(advancedWindow, "replicatedHealerV2AdvancedPreview", "", 18, 386, 476, 20, 11, ALIGN_CENTER))

advancedOpen = CreateTextButton(configWindow, "replicatedHealerV2AdvancedOpen", "高级参数", 446, 25, 70, 19, 9)
advancedOpen:SetHandler("OnClick", function()
	advancedWindow:Show(true)
	advancedWindow:SetUILayer(TOP_LAYER)
	advancedWindow:Raise()
	RefreshSettingsUi()
end)
advancedOpen:Show(false)

BaseRefreshSettingsUi = RefreshSettingsUi
RefreshSettingsUi = function()
	BaseRefreshSettingsUi()
	advancedHealthScan:SetText(string.format("%d ms", state.healthScanMs))
	advancedBuffScan:SetText(string.format("%d ms", state.buffScanMs))
	advancedSensitivity:SetText(tostring(state.missingSensitivity))
	advancedHold:SetText(string.format("%d ms", state.minHoldMs))
	advancedLead:SetText(string.format("%.0f 分", state.scoreLead))
	advancedAttention:SetText(string.format("%.0f 分", state.levelThresholds.attention))
	advancedHigh:SetText(string.format("%.0f 分", state.levelThresholds.high))
	advancedEmergency:SetText(string.format("%.0f 分", state.levelThresholds.emergency))
	advancedHeadName:SetText(BooleanText(state.showHeadName))
	advancedHeadDistance:SetText(BooleanText(state.showHeadDistance))
	advancedHeadScore:SetText(BooleanText(state.showHeadScore))
	advancedRankFont:SetText(tostring(state.raidRankFontSize))
	advancedRankAlpha:SetText(string.format("%.1f", state.raidRankAlpha))
	advancedRankX:SetText(tostring(state.raidRankOffsetX))
	advancedRankY:SetText(tostring(state.raidRankOffsetY))
	advancedLevelButton:SetText(LEVEL_LABELS[advancedSelectedLevel])
	advancedChannelButton:SetText(({ "R", "G", "B", "A" })[advancedColorChannel])
	local advancedColor = state.levelColors[advancedSelectedLevel]
	local key = ({ "r", "g", "b", "a" })[advancedColorChannel]
	advancedColorValue:SetText(string.format("%.2f", advancedColor[key]))
	advancedPreview:SetText(string.format("%s RGBA %.2f, %.2f, %.2f, %.2f", LEVEL_LABELS[advancedSelectedLevel], advancedColor.r, advancedColor.g, advancedColor.b, advancedColor.a))
	advancedPreview.style:SetColor(advancedColor.r, advancedColor.g, advancedColor.b, 1)
	-- Color editing is provided by the advanced window; hide the obsolete
	-- overlapping in-page channel controls to keep 1024x768 layout clean.
end
SetAdvancedPage(1)

end
if ReplicatedSuiteEmbedded ~= true then InitializeAdvancedSettings() end

-----------------------------------------------------------------------
-- Layout, update driver and addon entry
-----------------------------------------------------------------------

function OnTeamMembersChanged(reason)
	-- IMPORTANT: this event can be dispatched from inside the native
	-- raidTeamManager member OnShow/rebuild stack. Keep the callback strictly
	-- data-only. Calling SetUILayer/Raise or probing team_* unit tokens here can
	-- re-enter native UI code while member widgets are only partially built.
	teamRosterSettleRemainingMs = math.max(tonumber(teamRosterSettleRemainingMs) or 0, 900)
	teamRosterZOrderPending = true
	rosterElapsed = 10000
	healthElapsed = 0
	buffElapsed = 0
	if ReplicatedHealerBuffObserver ~= nil and type(ReplicatedHealerBuffObserver.ResetCadence) == "function" then
		ReplicatedHealerBuffObserver:ResetCadence()
	else
		buffObserverRosterElapsed = 0
		buffObserverScanElapsed = 0
	end
	-- Drop stale recommendations immediately without touching any widgets. The
	-- normal visual pass will hide stale marks, and a fresh roster is rebuilt
	-- only after the native raid frame has settled.
	recommendations = {}
	unavailable = {}
	if ReplicatedHealerRuntime ~= nil and type(ReplicatedHealerRuntime.InvalidateRoster) == "function" then
		-- Any membership generation can change the meaning of team unit tokens.
		-- Clear key-indexed caches now, but keep all native UI work behind the
		-- existing settle fence.
		ReplicatedHealerRuntime:InvalidateRoster(true)
	end
	if reason == "leaved_by_self" or reason == "kicked_by_self" or reason == "dismissed" then
		roster = {}
		rosterByKey = {}
		rosterMode = "none"
		healthSnapshot = {}
		statusCache = {}
	end
end
-- Do not attach TEAM_MEMBERS_CHANGED directly to UIParent:SetEventHandler.
-- That API slot is shared and can replace another addon's handler (notably DPS
-- roster refresh).  A private event host isolates Healer; the normal 1s roster
-- poll remains a fallback if this optional event cannot be registered.
local teamEventHost = nil
local teamEventRegistered = false
local HealerTeamEventHandler = function(_, eventName, ...)
	if ReplicatedHealerBoot == nil or tonumber(ReplicatedHealerBoot.generation) ~= healerRuntimeGeneration then return end
	if state == nil or state.enabled ~= true then return end
	if eventName ~= "TEAM_MEMBERS_CHANGED" then return end
	local token = SuitePerformance and SuitePerformance:Begin("event:healer_team", "healer") or nil
	local args = { ... }
	local argCount = select("#", ...)
	local ok = xpcall(function() OnTeamMembersChanged(unpack(args, 1, argCount)) end, function(runtimeErr)
		return tostring(runtimeErr)
	end)
	if not ok then
		-- Keep the event host usable; the periodic roster scan will recover.
		rosterElapsed = 10000
	end
	if SuitePerformance ~= nil then SuitePerformance:End(token) end
end

local function ReleaseHealerTeamEventHandler()
	local shared = rawget(_G, "ReplicatedSuiteShared")
	local native = shared and shared.NativeSafe or nil
	if native ~= nil and type(native.ReleaseHandler) == "function" then
		native.ReleaseHandler(teamEventHost, "OnEvent")
		return
	end
	if teamEventHost == nil or type(teamEventHost.ReleaseHandler) ~= "function" then return end
	if type(teamEventHost.HasHandler) == "function" and not teamEventHost:HasHandler("OnEvent") then return end
	pcall(function() teamEventHost:ReleaseHandler("OnEvent") end)
end

local function InstallHealerTeamEventHandler()
	if teamEventHost == nil or teamEventRegistered ~= true or type(teamEventHost.SetHandler) ~= "function" then return true end
	ReleaseHealerTeamEventHandler()
	local shared = rawget(_G, "ReplicatedSuiteShared")
	local native = shared and shared.NativeSafe or nil
	if native ~= nil and type(native.BindHandler) == "function" then return native.BindHandler(teamEventHost, "OnEvent", HealerTeamEventHandler) end
	local ok, result = pcall(teamEventHost.SetHandler, teamEventHost, "OnEvent", HealerTeamEventHandler)
	return ok == true and result ~= false
end

teamEventHost = CreateEmptyWindow("replicatedHealerV2TeamEventHost", "UIParent")
if teamEventHost ~= nil then
	teamEventHost:SetExtent(1, 1)
	teamEventHost:Show(false)
	if type(teamEventHost.RegisterEvent) == "function" then
		local ok, result = pcall(function() return teamEventHost:RegisterEvent("TEAM_MEMBERS_CHANGED") end)
		teamEventRegistered = ok and result ~= false
	end
	-- Standalone owns its lifecycle. Suite embedded mode binds the handler only
	-- from ModuleManager:EnableRuntime and releases it on DisableRuntime.
	if ReplicatedSuiteEmbedded ~= true then InstallHealerTeamEventHandler() end
end

layoutViewport = layoutViewport or nil

function HasViewportChanged()
	local _, _, uiScale, logicalWidth, logicalHeight = GetUiMetrics()
	local previous = layoutViewport
	return previous == nil
		or math.abs((tonumber(previous.logicalWidth) or 0) - logicalWidth) >= 1
		or math.abs((tonumber(previous.logicalHeight) or 0) - logicalHeight) >= 1
		or math.abs((tonumber(previous.uiScale) or 0) - uiScale) >= 0.001
end

LayoutAll = function()
	local _, _, uiScale, logicalWidth, logicalHeight = GetUiMetrics()
	layoutViewport = { logicalWidth = logicalWidth, logicalHeight = logicalHeight, uiScale = uiScale }
	LayoutLauncher()
	LayoutRecommendPanel()
	LayoutRaidOverlays()
	if configWindow ~= nil then
		local _, _, _, logicalWidth, logicalHeight = GetUiMetrics()
		local width = math.min(CONFIG_WIDTH, math.max(480, logicalWidth - 24))
		local height = math.min(CONFIG_HEIGHT, math.max(430, logicalHeight - 24))
		local x, y = ResolveAnchoredRect(state.configAnchor, width, height)
		configWindow:RemoveAllAnchors()
		configWindow:AddAnchor("TOPLEFT", "UIParent", x, y)
		configWindow:SetExtent(width, height)
	end
end

updateDriver = CreateEmptyWindow("replicatedHealerV2UpdateDriver", "UIParent")
updateDriver:SetExtent(1, 1)
updateDriver:Show(ReplicatedSuiteEmbedded ~= true)
SetMouseThrough(updateDriver, true)

-- The native update host remains in Core2 for lifecycle compatibility, but all
-- periodic policy now belongs to runtime/rh_runtime.lua. This keeps one Healer
-- OnUpdate while removing the old monolithic 100-player scan body from the UI
-- chunk.
local function RunHealerRuntimeTick(dt)
	if ReplicatedHealerRuntime == nil or type(ReplicatedHealerRuntime.Tick) ~= "function" then
		error("Healer Runtime v1 unavailable")
	end
	return ReplicatedHealerRuntime:Tick(dt)
end

local healerRuntimeLastError = nil
local healerRuntimeFailureCount = 0
local function HealerUpdateHandler(_, dt)
	if ReplicatedHealerBoot == nil or tonumber(ReplicatedHealerBoot.generation) ~= healerRuntimeGeneration then
		updateDriver:Show(false)
		return
	end
	-- pcall accepts arguments directly, avoiding two short-lived closures on
	-- every rendered frame while still keeping the single update driver alive.
	local token = SuitePerformance and SuitePerformance:Begin("onupdate:healer_runtime", "healer") or nil
	local ok, err = pcall(RunHealerRuntimeTick, dt)
	if SuitePerformance ~= nil then SuitePerformance:End(token) end
	if ok then
		healerRuntimeLastError = nil
		healerRuntimeFailureCount = 0
		if ReplicatedHealerBoot ~= nil then ReplicatedHealerBoot.runtimeError = nil end
		return
	end
	local text = tostring(err or "unknown")
	healerRuntimeFailureCount = healerRuntimeFailureCount + 1
	if ReplicatedHealerBoot ~= nil then ReplicatedHealerBoot.runtimeError = text end
	if ReplicatedSuiteEmbedded == true and healerRuntimeFailureCount >= 3
		and ReplicatedSuite ~= nil and ReplicatedSuite.ModuleManager ~= nil
		and type(ReplicatedSuite.ModuleManager.ReportRuntimeFault) == "function" then
		-- Persistent OnUpdate faults must fail closed instead of retrying every
		-- rendered frame.  ModuleManager keeps the persisted ON intent so the
		-- normal module Retry action can explicitly restart it after diagnosis.
		ReplicatedSuite.ModuleManager:ReportRuntimeFault("healer", "OnUpdate", text)
		return
	end
	if text ~= healerRuntimeLastError then
		healerRuntimeLastError = text
		-- Standalone compatibility keeps the historical one-per-distinct-error
		-- notice. Embedded Suite faults are surfaced centrally after the bounded
		-- transient retry budget above, avoiding a chat/retry storm.
		if ReplicatedSuiteEmbedded ~= true then
			pcall(function()
				X2Chat:DispatchChatMessage(CMF_SYSTEM, "Replicated 治疗推荐器运行异常，正在自动重试：" .. string.sub(text, 1, 180))
			end)
		end
	end
end
if ReplicatedSuiteEmbedded ~= true then
	local ok, result = pcall(updateDriver.SetHandler, updateDriver, "OnUpdate", HealerUpdateHandler)
	if not ok or result == false then
		pcall(function() updateDriver:Show(false) end)
		if ReplicatedHealerBoot ~= nil then ReplicatedHealerBoot.runtimeError = ok and "OnUpdate SetHandler returned false" or tostring(result) end
	end
end

-- Register the actual window, not only a trigger callback. This makes the
-- content discoverable/openable from Replicated Suite through GetContent/ShowContent.
if ReplicatedSuiteEmbedded ~= true and ADDON ~= nil and type(ADDON.RegisterContentWidget) == "function" then
	pcall(function() ADDON:RegisterContentWidget(CONTENT_ID, configWindow) end)
end

if ReplicatedSuiteEmbedded ~= true and ADDON ~= nil and type(ADDON.RegisterContentTriggerFunc) == "function" then
	pcall(function()
		ADDON:RegisterContentTriggerFunc(CONTENT_ID, function(show)
			local currentVisible = configWindow:IsVisible() == true
			local desiredVisible = ReplicatedEscMenuPolicy ~= nil
				and ReplicatedEscMenuPolicy:ResolveVisibility(show, currentVisible)
				or (show == true or (type(show) == "number" and show ~= 0))
			configWindow:Show(desiredVisible)
			if desiredVisible then
				configWindow:SetUILayer(TOP_LAYER)
				configWindow:Raise()
				RefreshSettingsUi()
			end
		end)
	end)
end
if ReplicatedSuiteEmbedded ~= true and ReplicatedEscMenuPolicy ~= nil and type(ReplicatedEscMenuPolicy.RegisterButton) == "function" then
	ReplicatedEscMenuPolicy:RegisterButton(3, CONTENT_ID, "info", "治疗推荐 · Replicated")
elseif ReplicatedSuiteEmbedded ~= true and ADDON ~= nil and type(ADDON.AddEscMenuButton) == "function" then
	pcall(function() ADDON:AddEscMenuButton(3, CONTENT_ID, "info", "治疗推荐 · Replicated") end)
end

-- In Suite-embedded mode ModuleManager is the only lifecycle Authority.
-- A historical Healer saved-state may still contain enabled=true, but loading
-- the Lua file itself must never perform roster/Buff/health scans before the
-- Suite explicitly enables the module.
if state.enabled and ReplicatedSuiteEmbedded ~= true then
	teamRosterSettleRemainingMs = math.max(tonumber(teamRosterSettleRemainingMs) or 0, 900)
	teamRosterZOrderPending = true
	rosterElapsed = 0
	healthElapsed = 0
	buffElapsed = 0
end
LayoutAll()
RefreshSettingsUi()
RefreshRecommendationPanel()
RefreshHeadMarkers()
RefreshRaidHighlights()


if ReplicatedHealerBoot ~= nil then
	ReplicatedHealerBoot.loaded = true
	ReplicatedHealerBoot.error = nil
end

-- Suite lifecycle adapter exported from the isolated Healer environment.
ReplicatedHealerModule = ReplicatedHealerModule or {}
local HM = ReplicatedHealerModule

local function GetHealerAuraBridge()
    local suite = ReplicatedSuite
    return type(suite) == "table" and suite.Features and suite.Features.HealerAuraBridge or nil
end

local function StartHealerAuraBridge(reason)
    local bridge = GetHealerAuraBridge()
    if type(bridge) ~= "table" or type(bridge.Start) ~= "function" then return true end
    local ok, err = bridge:Start(reason or "healer_enable")
    HM.auraBridgeLastError = ok == true and nil or tostring(err or "acquire failed")
    return ok == true, err
end

local function StopHealerAuraBridge(reason)
    local bridge = GetHealerAuraBridge()
    if type(bridge) ~= "table" or type(bridge.Stop) ~= "function" then return true end
    local ok, err = bridge:Stop(reason or "healer_disable")
    HM.auraBridgeLastError = ok == true and nil or tostring(err or "release failed")
    return ok == true, err
end

function HM:EnableRuntime()
    healerRuntimeFailureCount = 0
    healerRuntimeLastError = nil
    local auraOk, auraErr = StartHealerAuraBridge("enable")
    if auraOk ~= true then
        if ReplicatedHealerBoot ~= nil then ReplicatedHealerBoot.runtimeError = tostring(auraErr or "Aura bridge acquire failed") end
        return false
    end
    ApplyHealerRuntimeEnabled(true)
    if InstallHealerTeamEventHandler() ~= true then
        ApplyHealerRuntimeEnabled(false)
        ReleaseHealerTeamEventHandler()
        StopHealerAuraBridge("enable_event_failure")
        if ReplicatedHealerBoot ~= nil then ReplicatedHealerBoot.runtimeError = "OnEvent SetHandler failed" end
        return false
    end
    if updateDriver ~= nil then
        local shared = rawget(_G, "ReplicatedSuiteShared")
        local native = shared and shared.NativeSafe or nil
        local bindOk, bindResult
        if native ~= nil and type(native.BindHandler) == "function" then
            bindOk, bindResult = native.BindHandler(updateDriver, "OnUpdate", HealerUpdateHandler)
        else
            if updateDriver.HasHandler ~= nil and updateDriver:HasHandler("OnUpdate") and updateDriver.ReleaseHandler ~= nil then
                pcall(function() updateDriver:ReleaseHandler("OnUpdate") end)
            end
            bindOk, bindResult = pcall(updateDriver.SetHandler, updateDriver, "OnUpdate", HealerUpdateHandler)
        end
        if not bindOk or bindResult == false then
            ApplyHealerRuntimeEnabled(false)
            ReleaseHealerTeamEventHandler()
            StopHealerAuraBridge("enable_update_handler_failure")
            pcall(function() updateDriver:Show(false) end)
            if ReplicatedHealerBoot ~= nil then
                ReplicatedHealerBoot.runtimeError = bindOk and "OnUpdate SetHandler returned false" or tostring(bindResult)
            end
            return false
        end
        updateDriver:Show(true)
    else
        ApplyHealerRuntimeEnabled(false)
        ReleaseHealerTeamEventHandler()
        StopHealerAuraBridge("enable_driver_missing")
        return false
    end
    -- Do not synchronously probe team_* tokens from the module-enable call.
    -- The native raid frame may still be constructing. Run the first complete
    -- scan through the normal update driver after the settle fence expires.
    if ReplicatedHealerRuntime ~= nil and type(ReplicatedHealerRuntime.Reset) == "function" then
        ReplicatedHealerRuntime:Reset("enable", true)
    end
    teamRosterSettleRemainingMs = math.max(tonumber(teamRosterSettleRemainingMs) or 0, 900)
    teamRosterZOrderPending = true
    rosterElapsed = 10000
    healthElapsed = 0
    buffElapsed = 0
    recommendations = {}
    unavailable = {}
    RefreshHeadMarkers()
    RefreshRaidHighlights()
    return true
end

function HM:DisableRuntime()
    healerRuntimeFailureCount = 0
    healerRuntimeLastError = nil
    local auraOk, auraErr = StopHealerAuraBridge("disable")
    if auraOk ~= true then
        if ReplicatedHealerBoot ~= nil then ReplicatedHealerBoot.runtimeError = tostring(auraErr or "Aura bridge release failed") end
        return false
    end
    ApplyHealerRuntimeEnabled(false)
    if ReplicatedHealerRuntime ~= nil and type(ReplicatedHealerRuntime.Reset) == "function" then
        ReplicatedHealerRuntime:Reset("disable", true)
    end
    ReleaseHealerTeamEventHandler()
    -- Calibration is a runtime HUD mode.  Never let it survive a ModuleManager
    -- disable and reappear on the next enable as a second visibility Authority.
    calibrationMode = false
    ApplyCalibrationMode()
    if updateDriver ~= nil then
        updateDriver:Show(false)
        local shared = rawget(_G, "ReplicatedSuiteShared")
        local native = shared and shared.NativeSafe or nil
        if native ~= nil and type(native.ReleaseHandler) == "function" then native.ReleaseHandler(updateDriver, "OnUpdate")
        elseif updateDriver.HasHandler ~= nil and updateDriver:HasHandler("OnUpdate") and updateDriver.ReleaseHandler ~= nil then pcall(function() updateDriver:ReleaseHandler("OnUpdate") end) end
    end
    recommendations = {}
    unavailable = {}
    if recommendPanel ~= nil then recommendPanel:Show(false) end
    for _, marker in pairs(headMarkers or {}) do
        if marker.window ~= nil then HealerSetVisible(marker.window, false, HEALER_UI_OWNER_MARKERS) end
    end
    for _, overlay in pairs(raidOverlays or {}) do
        if overlay.window ~= nil then HealerSetVisible(overlay.window, false, HEALER_UI_OWNER_RAID) end
    end
    return true
end

function HM:GetRuntimeDiagnostics()
    local result
    if ReplicatedHealerRuntime ~= nil and type(ReplicatedHealerRuntime.Describe) == "function" then
        result = ReplicatedHealerRuntime:Describe()
    else
        result = { version="unavailable", rosterMode=tostring(rosterMode or "none"), rosterCount=#(roster or {}) }
    end
    if type(result) ~= "table" then result = {} end
    if ReplicatedHealerSettingsModel ~= nil and type(ReplicatedHealerSettingsModel.Describe) == "function" then result.settingsModel = ReplicatedHealerSettingsModel:Describe() end
    if ReplicatedHealerSettingsMigrations ~= nil and type(ReplicatedHealerSettingsMigrations.Describe) == "function" then result.settingsMigrations = ReplicatedHealerSettingsMigrations:Describe() end
    if ReplicatedHealerSettingsBootstrap ~= nil and type(ReplicatedHealerSettingsBootstrap.Describe) == "function" then result.settingsBootstrap = ReplicatedHealerSettingsBootstrap:Describe() end
    if ReplicatedHealerSettingsStore ~= nil and type(ReplicatedHealerSettingsStore.Describe) == "function" then result.settingsStore = ReplicatedHealerSettingsStore:Describe() end
    if ReplicatedHealerSettingsPresenter ~= nil and type(ReplicatedHealerSettingsPresenter.Describe) == "function" then result.settingsPresenter = ReplicatedHealerSettingsPresenter:Describe() end
    local auraBridge = GetHealerAuraBridge()
    if type(auraBridge) == "table" and type(auraBridge.GetHealth) == "function" then result.auraBridge = auraBridge:GetHealth() end
    result.auraBridgeLastError = HM.auraBridgeLastError
    return result
end

function HM:DescribeRuntime()
    return {
        loaded = ReplicatedHealerBoot ~= nil and ReplicatedHealerBoot.loaded == true,
        enabled = state ~= nil and state.enabled == true,
        runtimeError = ReplicatedHealerBoot and ReplicatedHealerBoot.runtimeError or nil,
        rankedHudRemoved = ReplicatedSuiteEmbedded == true,
    }
end

if ReplicatedSuiteEmbedded == true then HM:DisableRuntime() end
