ReplicatedSuiteModuleSandbox:Enter('healer', {'ReplicatedHealerBoot', 'ReplicatedHealerConfig', 'ReplicatedHealerModule'})
------------------------------------------------------------------------
-- Replicated Healer - Recommendation List Presenter v1
--
-- Native projection for the historical standalone recommendation list. In
-- Suite-embedded mode the independent ranked window remains intentionally
-- unallocated; Recommendation Domain data is still consumed by Marker/Raid
-- presenters. Core1 retains only compatibility helpers used by this presenter.
------------------------------------------------------------------------

if ReplicatedHealerCore1Loaded ~= true then return end

ReplicatedHealerRecommendationListPresenter = ReplicatedHealerRecommendationListPresenter or {}
local Presenter = ReplicatedHealerRecommendationListPresenter
Presenter.Version = "1.0"
Presenter.metrics = Presenter.metrics or { refreshes=0, layouts=0, rowsRendered=0 }

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


-- Stable presenter facade. Historical global function names remain Compatibility
-- Proxies because the compact settings UI still calls LayoutRecommendPanel().
Presenter.Layout = LayoutRecommendPanel
Presenter.Refresh = RefreshRecommendationPanel
Presenter.BuildDisplayList = BuildDisplayRecommendations

local RawLayout = LayoutRecommendPanel
function Presenter:ApplyLayout()
    self.metrics.layouts = (tonumber(self.metrics.layouts) or 0) + 1
    return RawLayout()
end

local RawRefresh = RefreshRecommendationPanel
function Presenter:RefreshNow()
    self.metrics.refreshes = (tonumber(self.metrics.refreshes) or 0) + 1
    local before = 0
    for _ in ipairs(recommendations or {}) do before = before + 1 end
    local result = RawRefresh()
    self.metrics.rowsRendered = (tonumber(self.metrics.rowsRendered) or 0) + before
    return result
end

function Presenter:Describe()
    return {
        version=tostring(self.Version or "?"),
        allocated=recommendPanel ~= nil,
        embedded=ReplicatedSuiteEmbedded == true,
        visible=recommendPanel ~= nil and recommendPanel.IsVisible ~= nil and recommendPanel:IsVisible() or false,
        rows=#(recommendRows or {}),
        refreshes=tonumber(self.metrics.refreshes) or 0,
        layouts=tonumber(self.metrics.layouts) or 0,
        rowsRendered=tonumber(self.metrics.rowsRendered) or 0,
    }
end

-- Compatibility proxies now route through Presenter metrics.
LayoutRecommendPanel = function() return Presenter:ApplyLayout() end
RefreshRecommendationPanel = function() return Presenter:RefreshNow() end
