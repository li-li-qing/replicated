ReplicatedSuiteModuleSandbox:Enter('healer', {'ReplicatedHealerBoot', 'ReplicatedHealerConfig', 'ReplicatedHealerModule'})
------------------------------------------------------------------------
-- Replicated Healer - Raid Overlay Presenter v1
--
-- Presentation Authority for native raid-list overlays and calibration frames.
-- Calibration state remains persisted Healer configuration; this presenter owns
-- widget lifecycle/layout/visibility only.
------------------------------------------------------------------------

if ReplicatedHealerCore1Loaded ~= true then return end

ReplicatedHealerRaidPresenter = ReplicatedHealerRaidPresenter or {}
local P = ReplicatedHealerRaidPresenter
P.Version = "1.0"

-----------------------------------------------------------------------
-- Current-tab raid list overlay (two independently calibrated 25 slots)
-----------------------------------------------------------------------

raidOverlays = {}

function GetOverlayConfig(sectionIndex)
	if sectionIndex == 2 then return state.raidOverlayBottom
	elseif sectionIndex == 3 then return state.raidOverlayTopRaid2
	elseif sectionIndex == 4 then return state.raidOverlayBottomRaid2
	else return state.raidOverlayTop end
end

-- Compatibility bridge for pre-Suite calibration callers.  Some historical
-- Healer UI code used GetRaidOverlayState() for the same four persisted
-- rectangles.  Keep one tiny alias at the domain boundary so an old caller can
-- never take the whole calibration page down with a nil-global runtime error.
function GetRaidOverlayState(sectionIndex)
	return GetOverlayConfig(sectionIndex)
end

function GetSectionFirstMember(sectionIndex)
	return (sectionIndex == 2 or sectionIndex == 4) and 26 or 1
end

function GetSectionRaidIndex(sectionIndex)
	return sectionIndex <= 2 and 1 or 2
end

function IsCalibrationSectionInScope(sectionIndex)
	local scope = math.floor(Clamp(state.raidCalibrationScope or 1, 1, 3))
	local raidIndex = GetSectionRaidIndex(sectionIndex)
	return scope == 1 or (scope == 2 and raidIndex == 1) or (scope == 3 and raidIndex == 2)
end

function NormalizeCalibrationSectionForScope()
	state.raidCalibrationSection = math.floor(Clamp(state.raidCalibrationSection or 1, 1, 4))
	if IsCalibrationSectionInScope(state.raidCalibrationSection) then return end
	state.raidCalibrationSection = state.raidCalibrationScope == 3 and 3 or 1
end

-- Calibration is a direct four-frame editor.  Entering calibration always
-- exposes all four persisted raid rectangles at once so the user can drag the
-- exact frame they want without a separate "current area" selector.
-- raidCalibrationSection is retained only as a compatibility/last-selected
-- value for older callers; it is no longer a visibility Authority.
function IsActiveCalibrationSection(sectionIndex)
	if calibrationMode ~= true then return false end
	return sectionIndex >= 1 and sectionIndex <= 4
end

function CycleCalibrationSectionInScope()
	NormalizeCalibrationSectionForScope()
	local visible = {}
	for sectionIndex = 1, 4 do
		if IsCalibrationSectionInScope(sectionIndex) then
			visible[#visible + 1] = sectionIndex
		end
	end
	if #visible == 0 then
		state.raidCalibrationSection = 1
		return
	end
	local currentPos = 1
	for index, sectionIndex in ipairs(visible) do
		if sectionIndex == state.raidCalibrationSection then currentPos = index break end
	end
	state.raidCalibrationSection = visible[(currentPos % #visible) + 1]
end

function CreateRaidOverlaySection(sectionIndex)
	local firstMember = GetSectionFirstMember(sectionIndex)
	local overlay = CreateEmptyWindow("replicatedHealerV2RaidOverlay" .. tostring(sectionIndex), "UIParent")
	overlay.rsUiOwner = HEALER_UI_OWNER_RAID
	if HealerSuiteUI ~= nil and type(HealerSuiteUI.AdoptWidget) == "function" then
		HealerSuiteUI:AdoptWidget(overlay, HEALER_UI_OWNER_RAID, "raid_overlay_" .. tostring(sectionIndex))
	end
	-- The raid frame can raise itself when a member row is clicked.  Keeping the
	-- highlight on the ordinary layer therefore lets the native raid frame cover
	-- our colors immediately after the click.  Put only this small overlay on the
	-- system layer instead.  Mouse ownership is still controlled independently by
	-- SetMouseThrough(), so normal mode remains click-through to the native rows.
	if overlay.SetUILayer ~= nil then
		pcall(function() overlay:SetUILayer(TOP_LAYER) end)
	end
	overlay:Enable(true)
	overlay:Clickable(false)
	overlay:EnableDrag(false)
	SetMouseThrough(overlay, true)
	local calibrationBg = overlay:CreateColorDrawable(0.04, 0.30, 0.58, 0.52, "artwork")
	calibrationBg:AddAnchor("TOPLEFT", overlay, 0, 0)
	calibrationBg:AddAnchor("BOTTOMRIGHT", overlay, 0, 0)
	calibrationBg:SetVisible(false)
	local selectedBorders = {
		overlay:CreateColorDrawable(0.18, 0.72, 1.00, 0.92, "overlay"),
		overlay:CreateColorDrawable(0.18, 0.72, 1.00, 0.92, "overlay"),
		overlay:CreateColorDrawable(0.18, 0.72, 1.00, 0.92, "overlay"),
		overlay:CreateColorDrawable(0.18, 0.72, 1.00, 0.92, "overlay"),
	}
	selectedBorders[1]:AddAnchor("TOPLEFT", overlay, 0, 0)
	selectedBorders[2]:AddAnchor("BOTTOMLEFT", overlay, 0, 0)
	selectedBorders[3]:AddAnchor("TOPLEFT", overlay, 0, 0)
	selectedBorders[4]:AddAnchor("TOPRIGHT", overlay, 0, 0)
	for _, border in ipairs(selectedBorders) do border:SetVisible(false) end
	local title = CreateLabel(
		overlay,
		"replicatedHealerV2OverlayTitle" .. tostring(sectionIndex),
		string.format("拖动校准 · %d团 %d-%d", GetSectionRaidIndex(sectionIndex), firstMember, firstMember + 24),
		6,
		2,
		300,
		18,
		11,
		ALIGN_LEFT
	)
	title.style:SetOutline(true)
	SetMouseThrough(title, true)
	title:Show(false)
	local slots = {}
	local rankLabels = {}
	local calibrationLabels = {}
	for localIndex = 1, MEMBERS_PER_SECTION do
		local memberIndex = firstMember + localIndex - 1
		local slot = CreateMovableColorPanel(
			overlay,
			"replicatedHealerV2RaidSlot" .. tostring(sectionIndex) .. "_" .. tostring(memberIndex),
			0.16,
			0.52,
			1.00,
			0.2,
			"artwork"
		)
		slots[localIndex] = slot
		local rankLabel = CreateLabel(
			overlay,
			"replicatedHealerV2RaidRank" .. tostring(sectionIndex) .. "_" .. tostring(memberIndex),
			"",
			0,
			0,
			24,
			14,
			state.raidRankFontSize,
			ALIGN_CENTER
		)
		rankLabel.style:SetOutline(true)
		rankLabel:Show(false)
		rankLabels[localIndex] = rankLabel
		local calibrationLabel = CreateLabel(
			overlay,
			"replicatedHealerV2CalibrationLabel" .. tostring(sectionIndex) .. "_" .. tostring(memberIndex),
			tostring(memberIndex),
			0,
			0,
			30,
			14,
			9,
			ALIGN_CENTER
		)
		calibrationLabel.style:SetOutline(true)
		SetMouseThrough(calibrationLabel, true)
		calibrationLabel:Show(false)
		calibrationLabels[localIndex] = calibrationLabel
	end
	-- Calibration uses a dedicated transparent button as the mouse owner.
	-- The combat overlay itself is normally mouse-through and contains many
	-- non-pickable visual children.  Relying on the parent window's drag state
	-- was not reliable on RU: the drag event could be swallowed before it ever
	-- reached OnDragStart.  A button is a proven input widget on this client,
	-- and mirrors the game's title-bar pattern by moving the parent window.
	local dragSurface = overlay:CreateChildWidget("button",
		"replicatedHealerV2CalibrationDragSurface" .. tostring(sectionIndex), 0, true)
	dragSurface:SetText("")
	dragSurface:AddAnchor("TOPLEFT", overlay, 0, 0)
	dragSurface:SetExtent(1, 1)
	dragSurface:Show(false)
	SetMouseThrough(dragSurface, true)
	if dragSurface.EnableDrag ~= nil then dragSurface:EnableDrag(false) end
	if dragSurface.SetDragCondition ~= nil and DC_ALWAYS ~= nil then
		dragSurface:SetDragCondition(DC_ALWAYS)
	end

	local function SelectCalibrationSection()
		-- Keep every calibration frame visible.  Selecting a frame only updates
		-- the compatibility "last selected" record and its accent color; it must
		-- never hide the other three frames.
		state.raidCalibrationSection = sectionIndex
		for candidateSection = 1, 4 do
			local candidate = raidOverlays[candidateSection]
			if candidate ~= nil then
				local selected = candidateSection == sectionIndex
				for _, border in ipairs(candidate.selectedBorders) do
					border:SetVisible(calibrationMode == true)
					if border.SetColor ~= nil then
						if selected then border:SetColor(0.18, 0.82, 1.00, 1.00) else border:SetColor(0.12, 0.48, 0.72, 0.72) end
					end
				end
			end
		end
	end

	-- RU calibration input: move the visible overlay window itself.  The old
	-- transparent child-button approach could swallow input without ever moving
	-- the parent, leaving a calibration frame that looked inert.  Direct window
	-- dragging mirrors the proven config/color-editor windows in this module.
	overlay:SetHandler("OnDragStart", function(self)
		if not calibrationMode then return false end
		SelectCalibrationSection()
		self.moving = true
		BeginHealerSafeMove(self, "healer_raid_calibration_" .. tostring(sectionIndex), true)
		return true
	end)
	overlay:SetHandler("OnDragStop", function(self)
		EndHealerSafeMove(self)
		if calibrationMode then
			local x, y, width, height = GetLogicalWidgetRect(self)
			StoreAnchoredRect(GetOverlayConfig(sectionIndex), x, y, width, height)
			SaveState()
			LayoutRaidOverlaySection(sectionIndex)
			if RefreshCalibrationCoordinateEdits ~= nil then RefreshCalibrationCoordinateEdits() end
		end
		self.moving = false
	end)
	overlay:SetHandler("OnClick", function(self, arg)
		if calibrationMode and arg ~= "RightButton" then
			SelectCalibrationSection()
		end
	end)
	-- Keep the legacy child surface inert.  It remains allocated only so older
	-- references are harmless; it no longer owns mouse/drag gestures.
	dragSurface:Show(false)
	SetMouseThrough(dragSurface, true)
	if dragSurface.EnableDrag ~= nil then dragSurface:EnableDrag(false) end
	RegisterHealerFloating("raid_overlay_" .. tostring(sectionIndex), overlay, {
		onMetricsChanged = function(changed)
			if changed == true and type(LayoutRaidOverlaySection) == "function" then
				LayoutRaidOverlaySection(sectionIndex)
			elseif ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil then
				ReplicatedSuite.Layout:EnsureWidgetVisible(overlay, { onlyWhenVisible = true })
			end
		end,
	})
	return {
		sectionIndex = sectionIndex,
		firstMember = firstMember,
		window = overlay,
		calibrationBg = calibrationBg,
		selectedBorders = selectedBorders,
		title = title,
		slots = slots,
		rankLabels = rankLabels,
		calibrationLabels = calibrationLabels,
		dragSurface = dragSurface,
	}
end

raidOverlays[1] = CreateRaidOverlaySection(1)
raidOverlays[2] = CreateRaidOverlaySection(2)
raidOverlays[3] = CreateRaidOverlaySection(3)
raidOverlays[4] = CreateRaidOverlaySection(4)

function LayoutRaidOverlaySection(sectionIndex)
	local overlay = raidOverlays[sectionIndex]
	local config = GetOverlayConfig(sectionIndex)
	local x, y, width, height = ResolveAnchoredRect(config, config.width, config.height)
	if overlay.window.moving == true then
		width = tonumber(overlay.window:GetWidth()) or width
		height = tonumber(overlay.window:GetHeight()) or height
	else
		overlay.window:RemoveAllAnchors()
		overlay.window:AddAnchor("TOPLEFT", "UIParent", x, y)
		overlay.window:SetExtent(width, height)
	end
	if overlay.dragSurface ~= nil then
		overlay.dragSurface:SetExtent(width, height)
	end
	overlay.selectedBorders[1]:SetExtent(width, 2)
	overlay.selectedBorders[2]:SetExtent(width, 2)
	overlay.selectedBorders[3]:SetExtent(2, height)
	overlay.selectedBorders[4]:SetExtent(2, height)
	local outerPad = 4
	local topPad = 22
	local groupGap = 4
	local rowGap = 1
	local groupWidth = math.floor((width - outerPad * 2 - groupGap * (GROUPS_PER_SECTION - 1)) / GROUPS_PER_SECTION)
	local slotHeight = math.floor((height - topPad - outerPad - rowGap * (MEMBERS_PER_GROUP - 1)) / MEMBERS_PER_GROUP)
	groupWidth = math.max(24, groupWidth)
	slotHeight = math.max(8, slotHeight)
	for localIndex = 1, MEMBERS_PER_SECTION do
		local groupIndex = math.floor((localIndex - 1) / MEMBERS_PER_GROUP)
		local rowIndex = (localIndex - 1) % MEMBERS_PER_GROUP
		local slotX = outerPad + groupIndex * (groupWidth + groupGap)
		local slotY = topPad + rowIndex * (slotHeight + rowGap)
		local slot = overlay.slots[localIndex]
		slot:RemoveAllAnchors()
		slot:AddAnchor("TOPLEFT", overlay.window, slotX, slotY)
		slot:SetExtent(groupWidth, slotHeight)
		local calibrationLabel = overlay.calibrationLabels[localIndex]
		calibrationLabel:RemoveAllAnchors()
		calibrationLabel:AddAnchor("TOPLEFT", overlay.window, slotX, slotY)
		calibrationLabel:SetExtent(groupWidth, slotHeight)
		local rankLabel = overlay.rankLabels[localIndex]
		local rankWidth = math.max(18, state.raidRankFontSize * 2)
		local rankHeight = math.max(12, state.raidRankFontSize + 4)
		local cornerX = (state.raidRankCorner == 2 or state.raidRankCorner == 4)
			and (slotX + groupWidth - rankWidth - state.raidRankOffsetX)
			or (slotX + state.raidRankOffsetX)
		local cornerY = (state.raidRankCorner == 3 or state.raidRankCorner == 4)
			and (slotY + slotHeight - rankHeight - state.raidRankOffsetY)
			or (slotY + state.raidRankOffsetY)
		rankLabel:RemoveAllAnchors()
		rankLabel:AddAnchor("TOPLEFT", overlay.window, cornerX, cornerY)
		rankLabel:SetExtent(rankWidth, rankHeight)
		rankLabel.style:SetFontSize(state.raidRankFontSize)
	end
end

function LayoutRaidOverlays()
	LayoutRaidOverlaySection(1)
	LayoutRaidOverlaySection(2)
	LayoutRaidOverlaySection(3)
	LayoutRaidOverlaySection(4)
end

function EnsureRaidOverlayZOrder(overlay, raiseNow)
	if overlay == nil or overlay.window == nil then return end
	-- Do not maintain z-order from OnUpdate.  Reassert the layer only at lifecycle
	-- boundaries (show/calibration/roster rebuild), avoiding four Raise calls every
	-- visual tick while still keeping the overlay above the native raid list.
	if overlay.window.SetUILayer ~= nil then
		pcall(function() overlay.window:SetUILayer(TOP_LAYER) end)
	end
	if raiseNow and overlay.window.Raise ~= nil then
		pcall(function() overlay.window:Raise() end)
	end
end

function ApplyCalibrationMode()
	-- Apply layout before showing the frames so stale/off-screen persisted values
	-- are clamped by ResolveAnchoredRect every time calibration is entered.
	LayoutRaidOverlays()
	for sectionIndex = 1, 4 do
		local overlay = raidOverlays[sectionIndex]
		local calibrationVisible = IsActiveCalibrationSection(sectionIndex)
		-- Explicit visibility here is intentional.  Waiting for the normal combat
		-- highlight refresh made calibration depend on roster/runtime state and on
		-- some clients resulted in an enabled mode with no visible frame.
		HealerSetVisible(overlay.window, calibrationVisible or (not calibrationMode and state.enabled and (rosterMode == "raid" or rosterMode == "coraid")), HEALER_UI_OWNER_RAID)
		EnsureRaidOverlayZOrder(overlay, calibrationVisible)
		SetMouseThrough(overlay.window, not calibrationVisible)
		if overlay.window.Clickable ~= nil then overlay.window:Clickable(calibrationVisible) end
		if overlay.window.EnableDrag ~= nil then overlay.window:EnableDrag(calibrationVisible) end
		if overlay.window.SetDragCondition ~= nil and DC_ALWAYS ~= nil then overlay.window:SetDragCondition(DC_ALWAYS) end
		-- Legacy transparent drag surface must stay inert; the visible window owns
		-- all calibration input now.
		if overlay.dragSurface ~= nil then
			overlay.dragSurface:Show(false)
			SetMouseThrough(overlay.dragSurface, true)
			if overlay.dragSurface.EnableDrag ~= nil then overlay.dragSurface:EnableDrag(false) end
		end
		overlay.calibrationBg:SetVisible(calibrationVisible)
		overlay.title:Show(calibrationVisible)
		local selected = calibrationVisible and state.raidCalibrationSection == sectionIndex
		for _, border in ipairs(overlay.selectedBorders) do
			border:SetVisible(calibrationVisible)
			if border.SetColor ~= nil then
				if selected then border:SetColor(0.18, 0.82, 1.00, 1.00) else border:SetColor(0.12, 0.48, 0.72, 0.72) end
			end
		end
		for localIndex = 1, MEMBERS_PER_SECTION do
			overlay.calibrationLabels[localIndex]:Show(calibrationVisible)
		end
	end
	if RefreshRaidHighlights ~= nil then RefreshRaidHighlights() end
	-- RefreshRaidHighlights can re-show the native overlay at a lifecycle edge;
	-- reassert the calibration frames last so they are unquestionably visible and
	-- above the raid UI when the user is expected to drag them.
	if calibrationMode then
		for sectionIndex = 1, 4 do
			if IsActiveCalibrationSection(sectionIndex) then
				local overlay = raidOverlays[sectionIndex]
				HealerSetVisible(overlay.window, true, HEALER_UI_OWNER_RAID)
				EnsureRaidOverlayZOrder(overlay, true)
			end
		end
	end
end

function GetOverlaySlot(raidIndex, memberIndex)
	if memberIndex == nil or memberIndex < 1 or memberIndex > 50 then
		return nil, nil
	end
	local sectionIndex = (raidIndex - 1) * 2 + (memberIndex > 25 and 2 or 1)
	local localIndex = memberIndex - GetSectionFirstMember(sectionIndex) + 1
	return raidOverlays[sectionIndex], localIndex
end

function RefreshRaidHighlights()
	local runtimeShowOverlay = state.enabled and (rosterMode == "raid" or rosterMode == "coraid")
	for sectionIndex = 1, 4 do
		local overlay = raidOverlays[sectionIndex]
		local calibrationVisible = IsActiveCalibrationSection(sectionIndex)
		local showOverlay = calibrationMode and calibrationVisible or (not calibrationMode and runtimeShowOverlay)
		local changedVisibility = HealerSetVisible(overlay.window, showOverlay, HEALER_UI_OWNER_RAID)
		if changedVisibility and showOverlay then EnsureRaidOverlayZOrder(overlay, true) end
		for localIndex = 1, MEMBERS_PER_SECTION do
			HealerSetVisible(overlay.slots[localIndex], calibrationVisible, HEALER_UI_OWNER_RAID)
			HealerSetVisible(overlay.rankLabels[localIndex], false, HEALER_UI_OWNER_RAID)
			if calibrationVisible then
				-- Alignment grid only. Live rescue candidates overwrite this faint
				-- neutral color below, so calibration never replaces real feedback.
				HealerSetColor(overlay.slots[localIndex], 0.16, 0.52, 1.00, 0.08, HEALER_UI_OWNER_RAID)
			end
		end
	end
	if not state.enabled then
		return
	end
	for _, candidate in ipairs(recommendations) do
		local overlay, localIndex = GetOverlaySlot(candidate.raidIndex, candidate.memberIndex)
		local canRender = overlay ~= nil and (not calibrationMode or IsActiveCalibrationSection(overlay.sectionIndex))
		if canRender then
			local alpha = GetAnimatedAlpha(candidate.color, state.raidEffectMode)
			HealerSetColor(overlay.slots[localIndex], candidate.color.r, candidate.color.g, candidate.color.b, alpha, HEALER_UI_OWNER_RAID)
			HealerSetVisible(overlay.slots[localIndex], true, HEALER_UI_OWNER_RAID)
			if not calibrationMode and state.showRaidRanks and candidate.rank <= state.raidRankCount then
				HealerSetText(overlay.rankLabels[localIndex], tostring(candidate.rank), HEALER_UI_OWNER_RAID)
				HealerSetColor(overlay.rankLabels[localIndex].style, 1, 1, 1, state.raidRankAlpha, HEALER_UI_OWNER_RAID)
				HealerSetVisible(overlay.rankLabels[localIndex], true, HEALER_UI_OWNER_RAID)
			end
		end
	end
	if not calibrationMode then
		for _, member in ipairs(roster) do
			local snapshot = healthSnapshot[member.key]
			if snapshot ~= nil and snapshot.distance ~= nil and snapshot.distance <= state.maxDistance
				and snapshot.healthPercent > 0 then
				local overlay, localIndex = GetOverlaySlot(member.raidIndex, member.memberIndex)
				if overlay ~= nil and not overlay.slots[localIndex]:IsVisible() then
					local cached = statusCache[member.key]
					local statuses = cached and cached.statuses or {}
					local displayRule = FindHighestDisplayRuleMatch and FindHighestDisplayRuleMatch(statuses, snapshot.healthPercent, snapshot.distance) or nil
					local color, _, visualPriority = ResolveHealingDisplayState(snapshot.healthPercent, snapshot.distance, statuses, displayRule)
					-- Turning off the base range tint hides only the ordinary
					-- in-range pink state. Low/emergency/Buff signals remain visible.
					if color ~= nil and (state.proximityMode or visualPriority > 1) then
						HealerSetColor(overlay.slots[localIndex], color.r, color.g, color.b, color.a, HEALER_UI_OWNER_RAID)
						HealerSetVisible(overlay.slots[localIndex], true, HEALER_UI_OWNER_RAID)
					end
				end
			end
		end
	end
end

LayoutRaidOverlays()
ApplyCalibrationMode()


P.GetOverlayConfig = GetOverlayConfig
P.LayoutSection = LayoutRaidOverlaySection
P.LayoutAll = LayoutRaidOverlays
P.Refresh = RefreshRaidHighlights
P.ApplyCalibrationMode = ApplyCalibrationMode
P.EnsureZOrder = EnsureRaidOverlayZOrder
P.GetOverlaySlot = GetOverlaySlot
function P:HideAll()
    for _, overlay in pairs(raidOverlays or {}) do
        if overlay ~= nil and overlay.window ~= nil then HealerSetVisible(overlay.window, false, HEALER_UI_OWNER_RAID) end
    end
end
function P:Describe()
    local visible=0
    for _, overlay in pairs(raidOverlays or {}) do
        if overlay ~= nil and overlay.window ~= nil and type(overlay.window.IsVisible)=="function" and overlay.window:IsVisible() then visible=visible+1 end
    end
    return { version=tostring(self.Version or "?"), overlays=#(raidOverlays or {}), visible=visible, calibration=calibrationMode==true }
end
