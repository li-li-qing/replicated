ReplicatedSuiteModuleSandbox:Enter('healer', {'ReplicatedHealerBoot', 'ReplicatedHealerConfig', 'ReplicatedHealerModule'})
------------------------------------------------------------------------
-- Replicated Healer - Buff Observer Presenter v1
--
-- Operator/developer-only one-member status observer. This presenter owns the
-- observer window, paging state and bounded refresh cadence. It reads through
-- Status Cache Domain and never publishes into Runtime's atomic raid snapshot.
------------------------------------------------------------------------

if ReplicatedHealerCore1Loaded ~= true then return end

ReplicatedHealerBuffObserver = ReplicatedHealerBuffObserver or {}
local Observer = ReplicatedHealerBuffObserver
Observer.Version = "1.0"
Observer.metrics = Observer.metrics or { refreshes=0, directReads=0, trackedAdds=0, rosterPolls=0 }
HEALER_UI_OWNER_OBSERVER = "healer:buff_observer"

function AddTrackedBuffFromStatus(status)
	if type(status) ~= "table" or tonumber(status.id) == nil then return end
	local id = tonumber(status.id)
	for index, entry in ipairs(state.trackedBuffs) do
		if tonumber(entry.id) == id then
			entry.enabled = true
			if status.name ~= nil and tostring(status.name) ~= tostring(id) then entry.name = tostring(status.name) end
			trackedBuffOffset = math.floor((index - 1) / trackedBuffPageSize) * trackedBuffPageSize
			SaveState() RefreshSettingsUi()
			return
		end
	end
	if #state.trackedBuffs >= MAX_RULES then
		X2Chat:DispatchChatMessage(CMF_SYSTEM, "Replicated：Buff 判断列表最多 20 条。")
		return
	end
	state.trackedBuffs[#state.trackedBuffs + 1] = {
		id = id,
		name = tostring(status.name or ("Buff " .. tostring(id))),
		enabled = true,
		color = { r = 0.72, g = 0.30, b = 1.00, a = 0.84 },
	}
	trackedBuffOffset = math.floor((#state.trackedBuffs - 1) / trackedBuffPageSize) * trackedBuffPageSize
	SaveState()
	RefreshSettingsUi()
end

function StatusSourceText(status)
	local mask = tonumber(status and status.sourceMask) or 0
	local parts = {}
	if mask % 2 == 1 then parts[#parts + 1] = "Buff" end
	if math.floor(mask / SOURCE_DEBUFF) % 2 == 1 then parts[#parts + 1] = "Debuff" end
	if math.floor(mask / SOURCE_HIDDEN) % 2 == 1 then parts[#parts + 1] = "隐藏" end
	return #parts > 0 and table.concat(parts, "/") or "状态"
end

buffObserverWindow = CreateEmptyWindow("replicatedHealerV3BuffObserver", "UIParent")
buffObserverWindow:SetExtent(560, 430)
buffObserverWindow:AddAnchor("CENTER", "UIParent", 0, 0)
buffObserverWindow:SetUILayer(TOP_LAYER)
buffObserverWindow:SetCloseOnEscape(true)
buffObserverWindow:Enable(true)
buffObserverWindow:Clickable(true)
buffObserverWindow:EnableDrag(true)
buffObserverWindow:Show(false)
RegisterHealerFloating("buff_observer", buffObserverWindow, { onlyWhenVisible = true, fitSize = true })
CreateBackground(buffObserverWindow, 0.025, 0.035, 0.05, 0.98)
buffObserverTitle = CreateLabel(buffObserverWindow, "replicatedHealerV3BuffObserverTitle", "Buff 观察器 · Replicated", 12, 7, 420, 22, 15, ALIGN_LEFT)
buffObserverClose = CreateTextButton(buffObserverWindow, "replicatedHealerV3BuffObserverClose", "X", 522, 7, 26, 24, 11)
buffObserverClose:SetHandler("OnClick", function() buffObserverWindow:Show(false) end)
buffObserverWindow:SetHandler("OnDragStart", function(self) BeginHealerSafeMove(self, "healer_buff_observer", true) return true end)
buffObserverWindow:SetHandler("OnDragStop", function(self) EndHealerSafeMove(self) end)
buffObserverPrevMember = CreateTextButton(buffObserverWindow, "replicatedHealerV3BuffPrevMember", "<", 18, 44, 40, 24, 11)
buffObserverMemberLabel = CreateLabel(buffObserverWindow, "replicatedHealerV3BuffMember", "观察对象：--", 64, 46, 404, 20, 11, ALIGN_CENTER)
buffObserverNextMember = CreateTextButton(buffObserverWindow, "replicatedHealerV3BuffNextMember", ">", 474, 44, 40, 24, 11)
CreateLabel(buffObserverWindow, "replicatedHealerV3BuffHint", "只在此窗口打开时额外扫描当前观察成员，不会为了这个功能高频扫描整团。", 18, 74, 524, 20, 10, ALIGN_LEFT)

buffObserverMemberIndex = 1
buffObserverOffset = 0
buffObserverPageSize = 8
buffObserverRows = {}
buffObserverVisibleStatuses = {}
buffObserverScanElapsed = 10000
buffObserverRosterElapsed = 10000
for row = 1, buffObserverPageSize do
	local y = 104 + (row - 1) * 34
	local rowIndex = row
	local item = {}
	item.label = CreateLabel(buffObserverWindow, "replicatedHealerV3BuffObservedLabel" .. tostring(row), "", 18, y + 2, 420, 20, 10, ALIGN_LEFT)
	item.add = CreateTextButton(buffObserverWindow, "replicatedHealerV3BuffObservedAdd" .. tostring(row), "追加", 448, y, 78, 22, 10)
	item.add:SetHandler("OnClick", function()
		local status = buffObserverVisibleStatuses[rowIndex]
		if status ~= nil then Observer.metrics.trackedAdds = (tonumber(Observer.metrics.trackedAdds) or 0) + 1 AddTrackedBuffFromStatus(status) RefreshBuffObserver(false) end
	end)
	buffObserverRows[row] = item
end
buffObserverPrevPage = CreateTextButton(buffObserverWindow, "replicatedHealerV3BuffPrevPage", "上一页", 18, 382, 100, 24, 10)
buffObserverNextPage = CreateTextButton(buffObserverWindow, "replicatedHealerV3BuffNextPage", "下一页", 124, 382, 100, 24, 10)
buffObserverPageLabel = CreateLabel(buffObserverWindow, "replicatedHealerV3BuffPage", "", 236, 384, 290, 20, 10, ALIGN_RIGHT)

function GetBuffObserverMember()
	if #roster == 0 then return nil end
	buffObserverMemberIndex = math.floor(Clamp(buffObserverMemberIndex, 1, #roster))
	return roster[buffObserverMemberIndex]
end

function GetSortedObservedStatuses(member, scanNow)
	if member == nil then return {} end
	local statuses = nil
	if scanNow then
		-- Observer reads are intentionally non-publishing. A developer tool must
		-- not punch a single-member hole into the Runtime's atomic Status
		-- Generation while a raid scan is in progress.
		statuses = ReplicatedHealerStatusCache ~= nil and ReplicatedHealerStatusCache:Read(member) or select(1, ReadUnitStatuses(member))
	else
		local cached = statusCache[member.key]
		statuses = cached and cached.statuses or nil
	end
	if statuses == nil then statuses = ReplicatedHealerStatusCache ~= nil and ReplicatedHealerStatusCache:Read(member) or select(1, ReadUnitStatuses(member)) end
	local rows = {}
	for _, status in pairs(statuses or {}) do rows[#rows + 1] = status end
	table.sort(rows, function(left, right)
		local leftName = tostring(left.name or left.id or "")
		local rightName = tostring(right.name or right.id or "")
		if leftName ~= rightName then return leftName < rightName end
		return (tonumber(left.id) or 0) < (tonumber(right.id) or 0)
	end)
	return rows
end

RefreshBuffObserver = function(scanNow)
	if buffObserverWindow == nil or not buffObserverWindow:IsVisible() then return end
	if #roster == 0 then RebuildRoster() end
	local member = GetBuffObserverMember()
	if member == nil then
		HealerSetText(buffObserverMemberLabel, "观察对象：当前没有可读取成员", HEALER_UI_OWNER_OBSERVER)
		buffObserverVisibleStatuses = {}
		for row = 1, buffObserverPageSize do HealerSetText(buffObserverRows[row].label, "", HEALER_UI_OWNER_OBSERVER) HealerSetVisible(buffObserverRows[row].add, false, HEALER_UI_OWNER_OBSERVER) end
		HealerSetText(buffObserverPageLabel, "0 个状态", HEALER_UI_OWNER_OBSERVER)
		return
	end
	HealerSetText(buffObserverMemberLabel, string.format("观察对象：%s · %d团 #%d", tostring(member.name), tonumber(member.raidIndex) or 1, tonumber(member.memberIndex) or 1), HEALER_UI_OWNER_OBSERVER)
	local statuses = GetSortedObservedStatuses(member, scanNow == true)
	buffObserverOffset = math.min(buffObserverOffset, math.floor(math.max(0, #statuses - 1) / buffObserverPageSize) * buffObserverPageSize)
	buffObserverVisibleStatuses = {}
	for row = 1, buffObserverPageSize do
		local status = statuses[buffObserverOffset + row]
		local item = buffObserverRows[row]
		buffObserverVisibleStatuses[row] = status
		if status ~= nil then
			local tracked = false
			for _, entry in ipairs(state.trackedBuffs) do if tonumber(entry.id) == tonumber(status.id) then tracked = true break end end
			HealerSetText(item.label, string.format("%s  [%s]  ID:%s", tostring(status.name or status.id), StatusSourceText(status), tostring(status.id)), HEALER_UI_OWNER_OBSERVER)
			HealerSetText(item.add, tracked and "已追加" or "追加", HEALER_UI_OWNER_OBSERVER)
			HealerSetVisible(item.add, true, HEALER_UI_OWNER_OBSERVER)
		else
			HealerSetText(item.label, "", HEALER_UI_OWNER_OBSERVER)
			HealerSetVisible(item.add, false, HEALER_UI_OWNER_OBSERVER)
		end
	end
	local page = math.floor(buffObserverOffset / buffObserverPageSize) + 1
	local pages = math.max(1, math.ceil(#statuses / buffObserverPageSize))
	HealerSetText(buffObserverPageLabel, string.format("第 %d/%d 页 · %d 个状态", page, pages, #statuses), HEALER_UI_OWNER_OBSERVER)
end

buffObserverPrevMember:SetHandler("OnClick", function()
	if #roster == 0 then RebuildRoster() end
	buffObserverMemberIndex = math.max(1, buffObserverMemberIndex - 1)
	buffObserverOffset = 0
	RefreshBuffObserver(true)
end)
buffObserverNextMember:SetHandler("OnClick", function()
	if #roster == 0 then RebuildRoster() end
	buffObserverMemberIndex = math.min(math.max(1, #roster), buffObserverMemberIndex + 1)
	buffObserverOffset = 0
	RefreshBuffObserver(true)
end)
buffObserverPrevPage:SetHandler("OnClick", function() buffObserverOffset = math.max(0, buffObserverOffset - buffObserverPageSize) RefreshBuffObserver(false) end)
buffObserverNextPage:SetHandler("OnClick", function()
	local member = GetBuffObserverMember()
	local statuses = GetSortedObservedStatuses(member, false)
	buffObserverOffset = math.min(math.floor(math.max(0, #statuses - 1) / buffObserverPageSize) * buffObserverPageSize, buffObserverOffset + buffObserverPageSize)
	RefreshBuffObserver(false)
end)
simpleOpenBuffObserver:SetHandler("OnClick", function()
	if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.ModuleManager ~= nil and not ReplicatedSuite.ModuleManager:IsEnabled("healer") then
		X2Chat:DispatchChatMessage(CMF_SYSTEM, "Replicated：治疗辅助模块当前未启用；Buff 观察属于 Runtime 扫描，请先启用模块。")
		return
	end
	RebuildRoster()
	-- Prefer the player's own row the first time; then the user can step through
	-- team members with the arrows.
	for index, member in ipairs(roster) do if member.isSelf then buffObserverMemberIndex = index break end end
	buffObserverOffset = 0
	buffObserverScanElapsed = 10000
	buffObserverRosterElapsed = 10000
	buffObserverWindow:Show(true)
	buffObserverWindow:SetUILayer(TOP_LAYER)
	buffObserverWindow:Raise()
	RefreshBuffObserver(true)
end)



local RawRefreshBuffObserver = RefreshBuffObserver
function Observer:Refresh(scanNow)
    self.metrics.refreshes = (tonumber(self.metrics.refreshes) or 0) + 1
    if scanNow == true then self.metrics.directReads = (tonumber(self.metrics.directReads) or 0) + 1 end
    return RawRefreshBuffObserver(scanNow == true)
end

function Observer:IsVisible()
    return buffObserverWindow ~= nil and buffObserverWindow.IsVisible ~= nil and buffObserverWindow:IsVisible()
end

function Observer:ResetCadence(immediate)
    local value = immediate == true and 10000 or 0
    buffObserverScanElapsed = value
    buffObserverRosterElapsed = value
end

function Observer:Tick(deltaMs, runtimeEnabled, rosterStable, rosterPollMs)
    buffObserverScanElapsed = (tonumber(buffObserverScanElapsed) or 0) + math.max(0, tonumber(deltaMs) or 0)
    buffObserverRosterElapsed = (tonumber(buffObserverRosterElapsed) or 0) + math.max(0, tonumber(deltaMs) or 0)
    if rosterStable ~= true or not self:IsVisible() then return false end

    local pollMs = math.max(250, tonumber(rosterPollMs) or 1000)
    if runtimeEnabled ~= true and buffObserverRosterElapsed >= pollMs then
        buffObserverRosterElapsed = 0
        if ReplicatedHealerRoster ~= nil and type(ReplicatedHealerRoster.Request) == "function" then
            ReplicatedHealerRoster:Request("observer_poll", false)
            self.metrics.rosterPolls = (tonumber(self.metrics.rosterPolls) or 0) + 1
        end
    end

    local interval = math.max(300, state and tonumber(state.buffScanMs) or 300)
    if buffObserverScanElapsed >= interval then
        buffObserverScanElapsed = 0
        self:Refresh(runtimeEnabled ~= true)
        return true
    end
    return false
end

function Observer:Describe()
    return {
        version=tostring(self.Version or "?"),
        visible=self:IsVisible(),
        memberIndex=tonumber(buffObserverMemberIndex) or 1,
        offset=tonumber(buffObserverOffset) or 0,
        visibleStatuses=#(buffObserverVisibleStatuses or {}),
        refreshes=tonumber(self.metrics.refreshes) or 0,
        directReads=tonumber(self.metrics.directReads) or 0,
        trackedAdds=tonumber(self.metrics.trackedAdds) or 0,
        rosterPolls=tonumber(self.metrics.rosterPolls) or 0,
    }
end

-- Compatibility proxy for any legacy caller outside Runtime.
RefreshBuffObserver = function(scanNow) return Observer:Refresh(scanNow == true) end
