ReplicatedSuiteModuleSandbox:Enter('healer', {'ReplicatedHealerBoot', 'ReplicatedHealerConfig', 'ReplicatedHealerModule'})
------------------------------------------------------------------------
-- Replicated Healer - Head Marker Presenter v1
--
-- Presentation Authority for world-space rescue markers. It consumes committed
-- Recommendation projections and performs Diff-based Native UI writes only.
------------------------------------------------------------------------

if ReplicatedHealerCore1Loaded ~= true then return end

ReplicatedHealerMarkerPresenter = ReplicatedHealerMarkerPresenter or {}
local P = ReplicatedHealerMarkerPresenter
P.Version = "1.0"
headMarkers = headMarkers or {}

function CreateMarkerDrawable(marker, index)
	return CreateMovableColorPanel(
		marker,
		"replicatedHealerV2MarkerPart" .. tostring(index),
		1,
		0,
		0,
		0.8,
		"overlay"
	)
end

function EnsureHeadMarker(rank)
	if headMarkers[rank] ~= nil then
		return headMarkers[rank]
	end
	local marker = CreateEmptyWindow("replicatedHealerV2HeadMarker" .. tostring(rank), "UIParent")
	marker:SetExtent(150, 36)
	-- Runtime head markers stay on normal UI z-order so native game windows can cover them.
	marker:Show(false)
	marker.rsUiOwner = HEALER_UI_OWNER_MARKERS
	SetMouseThrough(marker, true)
	if HealerSuiteUI ~= nil and type(HealerSuiteUI.AdoptWidget) == "function" then
		HealerSuiteUI:AdoptWidget(marker, HEALER_UI_OWNER_MARKERS, "head_marker_" .. tostring(rank))
	end
	if HealerSuiteUI ~= nil and type(HealerSuiteUI.PrimeNativeState) == "function" then
		HealerSuiteUI:PrimeNativeState(marker, { width=150, height=36, visible=false })
	end
	local parts = {
		CreateMarkerDrawable(marker, tostring(rank) .. "_1"),
		CreateMarkerDrawable(marker, tostring(rank) .. "_2"),
		CreateMarkerDrawable(marker, tostring(rank) .. "_3"),
		CreateMarkerDrawable(marker, tostring(rank) .. "_4"),
	}
	local infoBg = CreateMovableColorPanel(
		marker,
		"replicatedHealerV2MarkerInfoBg" .. tostring(rank),
		0.02,
		0.025,
		0.035,
		0.72,
		"artwork"
	)
	local rankLabel = CreateLabel(marker, "replicatedHealerV2HeadRank" .. tostring(rank), tostring(rank), 0, 0, 36, 36, 14, ALIGN_CENTER)
	rankLabel.style:SetOutline(true)
	local infoLabel = CreateLabel(marker, "replicatedHealerV2HeadInfo" .. tostring(rank), "", 40, 0, 110, 36, 10, ALIGN_LEFT)
	infoLabel.style:SetOutline(true)
	headMarkers[rank] = {
		window = marker,
		parts = parts,
		infoBg = infoBg,
		rankLabel = rankLabel,
		infoLabel = infoLabel,
	}
	return headMarkers[rank]
end

headMarkerLastActiveCount = tonumber(headMarkerLastActiveCount) or 0

function AnchorMarkerPart(part, parent, x, y, width, height)
	HealerSetAnchor(part, parent, x, y, HEALER_UI_OWNER_MARKERS)
	HealerSetExtent(part, math.max(1, width), math.max(1, height), HEALER_UI_OWNER_MARKERS)
	HealerSetVisible(part, true, HEALER_UI_OWNER_MARKERS)
end

function LayoutHeadMarker(marker, candidate)
	local size = state.headSizes[candidate.level]
	local showName = state.showHeadName == true
	local showDistance = state.showHeadDistance == true
	local showScore = state.showHeadScore == true
	local showExtra = showName or showDistance or showScore
	local infoWidth = showExtra and 130 or 66
	local markerWidth = size + 4 + infoWidth
	local shape = state.headShapeMode

	-- Marker positions may move every 50 ms, but marker geometry normally does
	-- not. Cache the layout inputs so camera movement only updates the outer
	-- anchor instead of re-running extent/font/part layout work for every marker.
	local layout = marker.rsHealerLayout
	if layout ~= nil
		and layout.size == size
		and layout.shape == shape
		and layout.showName == showName
		and layout.showDistance == showDistance
		and layout.showScore == showScore then
		return layout.width, layout.height
	end

	layout = layout or {}
	marker.rsHealerLayout = layout
	layout.size = size
	layout.shape = shape
	layout.showName = showName
	layout.showDistance = showDistance
	layout.showScore = showScore
	layout.width = markerWidth
	layout.height = size

	HealerSetExtent(marker.window, markerWidth, size, HEALER_UI_OWNER_MARKERS)
	HealerSetAnchor(marker.rankLabel, marker.window, 0, 0, HEALER_UI_OWNER_MARKERS)
	HealerSetExtent(marker.rankLabel, size, size, HEALER_UI_OWNER_MARKERS)
	HealerSetFontSize(marker.rankLabel, math.max(9, math.floor(size * 0.38)), HEALER_UI_OWNER_MARKERS)
	HealerSetAnchor(marker.infoLabel, marker.window, size + 4, 0, HEALER_UI_OWNER_MARKERS)
	HealerSetExtent(marker.infoLabel, infoWidth, size, HEALER_UI_OWNER_MARKERS)
	HealerSetFontSize(marker.infoLabel, math.max(8, math.floor(size * 0.28)), HEALER_UI_OWNER_MARKERS)

	local parts = marker.parts
	local showPart1, showPart2, showPart3, showPart4 = false, false, false, false
	local infoVisible = false
	if shape == 1 then
		showPart1 = true
		AnchorMarkerPart(parts[1], marker.window, 0, 0, markerWidth, size)
	elseif shape == 2 then
		local inset = math.max(2, math.floor(size * 0.08))
		showPart1 = true; infoVisible = true
		AnchorMarkerPart(parts[1], marker.window, inset, inset, size - inset * 2, size - inset * 2)
		AnchorMarkerPart(marker.infoBg, marker.window, size + 2, 1, markerWidth - size - 2, size - 2)
	elseif shape == 3 then
		local thickness = math.max(4, math.floor(size * 0.28))
		local inset = math.max(2, math.floor(size * 0.08))
		showPart1 = true; showPart2 = true; infoVisible = true
		AnchorMarkerPart(parts[1], marker.window, math.floor((size - thickness) / 2), inset, thickness, size - inset * 2)
		AnchorMarkerPart(parts[2], marker.window, inset, math.floor((size - thickness) / 2), size - inset * 2, thickness)
		AnchorMarkerPart(marker.infoBg, marker.window, size + 2, 1, markerWidth - size - 2, size - 2)
	else
		local stemWidth = math.max(4, math.floor(size * 0.22))
		local stemHeight = math.max(5, math.floor(size * 0.38))
		local barHeight = math.max(3, math.floor(size * 0.13))
		showPart1, showPart2, showPart3, showPart4 = true, true, true, true
		infoVisible = true
		AnchorMarkerPart(parts[1], marker.window, math.floor((size - stemWidth) / 2), 1, stemWidth, stemHeight)
		AnchorMarkerPart(parts[2], marker.window, math.floor(size * 0.12), stemHeight, math.floor(size * 0.76), barHeight)
		AnchorMarkerPart(parts[3], marker.window, math.floor(size * 0.24), stemHeight + barHeight, math.floor(size * 0.52), barHeight)
		AnchorMarkerPart(parts[4], marker.window, math.floor(size * 0.38), stemHeight + barHeight * 2, math.floor(size * 0.24), barHeight)
		AnchorMarkerPart(marker.infoBg, marker.window, size + 2, 1, markerWidth - size - 2, size - 2)
	end
	HealerSetVisible(parts[1], showPart1, HEALER_UI_OWNER_MARKERS)
	HealerSetVisible(parts[2], showPart2, HEALER_UI_OWNER_MARKERS)
	HealerSetVisible(parts[3], showPart3, HEALER_UI_OWNER_MARKERS)
	HealerSetVisible(parts[4], showPart4, HEALER_UI_OWNER_MARKERS)
	HealerSetVisible(marker.infoBg, infoVisible, HEALER_UI_OWNER_MARKERS)
	return markerWidth, size
end

function RefreshHeadMarkers()
	local count = state.enabled and math.min(state.headMarkerCount, #recommendations) or 0
	local maxTouched = math.max(count, tonumber(headMarkerLastActiveCount) or 0)

	for rank = 1, maxTouched do
		if rank > count then
			local stale = headMarkers[rank]
			if stale ~= nil then HealerSetVisible(stale.window, false, HEALER_UI_OWNER_MARKERS) end
		end
	end
	if count <= 0 then
		headMarkerLastActiveCount = 0
		return
	end

	for rank = 1, count do
		local candidate = recommendations[rank]
		local marker = EnsureHeadMarker(rank)
		local screenX, screenY, screenZ = SafeUnitScreenPosition(candidate.unitId)
		if screenX ~= nil and screenY ~= nil and screenZ ~= nil and screenZ > 0 then
			local width, height = LayoutHeadMarker(marker, candidate)
			local alpha = GetAnimatedAlpha(candidate.color, state.headEffectMode)
			for _, part in ipairs(marker.parts) do
				HealerSetColor(part, candidate.color.r, candidate.color.g, candidate.color.b, alpha, HEALER_UI_OWNER_MARKERS)
			end
			HealerSetColor(marker.infoBg, 0.02, 0.025, 0.035, 0.72, HEALER_UI_OWNER_MARKERS)
			HealerSetText(marker.rankLabel, tostring(candidate.rank), HEALER_UI_OWNER_MARKERS)
			local infoText = string.format("%.0f%%", candidate.healthPercent)
			if state.showHeadName then infoText = infoText .. " " .. tostring(candidate.name or "") end
			if state.showHeadDistance then infoText = infoText .. string.format(" %.0fm", candidate.distance) end
			if state.showHeadScore then infoText = infoText .. string.format(" %.0f分", candidate.finalScore) end
			HealerSetText(marker.infoLabel, infoText, HEALER_UI_OWNER_MARKERS)
			HealerSetAnchor(
				marker.window,
				"UIParent",
				math.floor(screenX - width / 2),
				math.floor(screenY - height - 38),
				HEALER_UI_OWNER_MARKERS
			)
			HealerSetVisible(marker.window, true, HEALER_UI_OWNER_MARKERS)
		else
			HealerSetVisible(marker.window, false, HEALER_UI_OWNER_MARKERS)
		end
	end
	headMarkerLastActiveCount = count
end



P.Ensure = EnsureHeadMarker
P.Layout = LayoutHeadMarker
P.Refresh = RefreshHeadMarkers
function P:HideAll()
    for _, marker in pairs(headMarkers or {}) do
        if marker ~= nil and marker.window ~= nil then HealerSetVisible(marker.window, false, HEALER_UI_OWNER_MARKERS) end
    end
    headMarkerLastActiveCount = 0
end
function P:Describe()
    local allocated=0
    for _ in pairs(headMarkers or {}) do allocated=allocated+1 end
    return { version=tostring(self.Version or "?"), allocated=allocated, active=tonumber(headMarkerLastActiveCount) or 0 }
end
