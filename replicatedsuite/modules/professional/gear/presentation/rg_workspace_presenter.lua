ReplicatedSuiteModuleSandbox:Enter('gear', {'ReplicatedGear', 'ReplicatedGearConfig'})
------------------------------------------------------------------------
-- Replicated Gear - Suite Workspace Presenter (M5 v4)
--
-- Boundary:
--   * UI-facing read/write facade only; Core remains loadout/persistence Authority.
--   * Runtime remains swap execution Authority.
--   * Native equipment/title reads happen only in explicit Capture/Validate actions,
--     never from the periodic workspace refresh path.
--   * The presenter never keeps a second persistent copy of a loadout payload.
------------------------------------------------------------------------
if ReplicatedGear == nil or ReplicatedGear.BootError ~= nil or ReplicatedGear.Core == nil or ReplicatedGear.Runtime == nil then return end

local G = ReplicatedGear
local C = G.Core
local R = G.Runtime
local A = G.Api
local U = G.UI

G.WorkspacePresenter = {}
local W = G.WorkspacePresenter
W.generation = G.Generation

local function RefreshQuick()
    if U ~= nil and type(U.RefreshQuick) == "function" then pcall(function() U:RefreshQuick() end) end
end

local function RuntimeBusy()
    return R ~= nil and ((type(R.IsBusy) == "function" and R:IsBusy()) or R.busy == true) or false
end

local function RejectBusy(action)
    if RuntimeBusy() then return false, "换装正在执行，暂不能" .. tostring(action or "修改方案") end
    return true
end

function W:GetRevision()
    return math.max(0, math.floor(tonumber(C.root and C.root.revision) or 0))
end

function W:IsBusy()
    return RuntimeBusy()
end

function W:GetSetRows()
    local rows = {}
    for index, set in ipairs(C:GetSets(true)) do
        local managed = set.configured == true and C:CountManagedItems(set) or 0
        local titleManaged = type(set.title) == "table" and set.title.apply == true
        rows[index] = {
            id = tostring(set.id or index),
            order = tonumber(set.order) or index,
            name = tostring(set.name or ("换装" .. tostring(index))),
            configured = set.configured == true,
            quick = set.quick ~= false,
            managedCount = managed,
            titleManaged = titleManaged,
            payloadRevision = math.max(0, math.floor(tonumber(set.payloadRevision) or 0)),
        }
    end
    return rows, self:GetRevision()
end

function W:GetDraft(id)
    return C:GetSetCopy(id)
end

function W:GetSlotDefinitions()
    local result = {}
    for index, slot in ipairs(C.EquipmentSlots or {}) do
        result[index] = {
            slot = tonumber(slot.slot),
            key = tostring(slot.key or index),
            name = tostring(slot.name or ("槽位" .. tostring(index))),
            weapon = C:IsWeaponSlot(slot.slot) == true,
        }
    end
    return result
end

function W:IsWeaponSlot(slot)
    return C:IsWeaponSlot(slot) == true
end

function W:CreateSet(name)
    local ok, err = RejectBusy("新建方案")
    if not ok then return nil, err end
    local set, createErr = C:CreateSet(name)
    if set == nil then return nil, createErr end
    RefreshQuick()
    return tostring(set.id)
end

function W:DeleteSet(id)
    local ok, err = RejectBusy("删除方案")
    if not ok then return false, err end
    local deleted, deleteErr = C:DeleteSet(id)
    if deleted == true then RefreshQuick() end
    return deleted == true, deleteErr
end

function W:MoveSet(id, delta)
    local ok, err = RejectBusy("调整方案顺序")
    if not ok then return false, err end
    local moved, moveErr = C:MoveSet(id, delta)
    if moved == true then RefreshQuick() end
    return moved == true, moveErr
end

function W:CaptureDraft(id)
    local ok, err = RejectBusy("读取当前配置")
    if not ok then return nil, err end
    -- Explicit user action. Core owns all equipment/title native reads and fails
    -- closed if any slot is incomplete; periodic UI refresh never calls this.
    return C:CaptureDraft(id)
end

function W:CommitMetadata(draft)
    local ok, err = RejectBusy("保存方案")
    if not ok then return false, err end
    local saved, saveErr = C:CommitMetadata(draft, "suite_workspace_metadata")
    if saved == true then RefreshQuick() end
    return saved == true, saveErr
end

function W:CommitPayload(draft)
    local ok, err = RejectBusy("保存装备配置")
    if not ok then return false, err end
    -- This is an explicit user-facing save and therefore crosses Core's payload
    -- write fence using the already-whitelisted Suite reason.
    local saved, saveErr = C:CommitPayloadDraft(draft, "suite_save_current_edit")
    if saved == true then RefreshQuick() end
    return saved == true, saveErr
end

function W:SetQuickEnabled(id, enabled)
    local draft = C:GetSetCopy(id)
    if draft == nil then return false, "换装不存在" end
    draft.quick = enabled == true
    return self:CommitMetadata(draft)
end

function W:SetQuickSnapEnabled(enabled)
    local ok, err = RejectBusy("调整快捷按钮吸附")
    if not ok then return false, err end
    local saved, saveErr = C:SetQuickButtonSnapEnabled(enabled == true)
    if saved == true then RefreshQuick() end
    return saved == true, saveErr
end

function W:IsQuickSnapEnabled()
    return C:IsQuickButtonSnapEnabled() == true
end

function W:ApplyPreset(draft, mode)
    if type(draft) ~= "table" then return false, false end
    return C:ApplyManagedPreset(draft, tostring(mode or "NONE"))
end

function W:ToggleManagedSlot(draft, slot)
    if type(draft) ~= "table" then return false, "没有可编辑方案" end
    for _, item in ipairs(draft.items or {}) do
        if tonumber(item.slot) == tonumber(slot) then
            if item.empty == true then return false, tostring(item.slotName or "该部位") .. "为空，不能参与自动换装" end
            item.managed = item.managed == false
            return true, item.managed == true
        end
    end
    return false, "该部位尚未读取；请先获取当前配置"
end

function W:ToggleTitle(draft)
    if type(draft) ~= "table" then return false, "没有可编辑方案" end
    local title = type(draft.title) == "table" and draft.title or nil
    if title == nil or type(title.effect) ~= "table" or title.effect.id == nil then
        return false, "当前方案没有可切换的称号信息"
    end
    title.apply = title.apply ~= true
    return true, title.apply == true
end

function W:GetTitleText(draft)
    return C:TitleText(type(draft) == "table" and draft.title or nil)
end

function W:GetManagedCount(draft)
    return C:CountManagedItems(draft)
end

function W:Start(id)
    if id == nil then return false, "请先选择换装方案" end
    return R:Start(id)
end

function W:GetRuntimeSnapshot()
    local session = R and R.session or nil
    local inCombat = nil
    -- Cheap state query only; no equipment/bag scan. Keeping this inside the Gear
    -- presenter preserves the UI -> Presenter -> API boundary.
    if A ~= nil and type(A.IsPlayerInCombat) == "function" then
        local ok, value = pcall(function() return A:IsPlayerInCombat() end)
        if ok then inCombat = value == true end
    end
    return {
        busy = RuntimeBusy(),
        stage = tostring(R and R.stage or "IDLE"),
        index = math.max(0, math.floor(tonumber(R and R.index) or 0)),
        total = type(session) == "table" and #(session.queue or {}) or 0,
        setId = type(session) == "table" and tostring(session.setId or "") or nil,
        setName = type(session) == "table" and tostring(session.setName or "") or nil,
        partial = type(session) == "table" and session.partial == true or false,
        pending = type(session) == "table" and #(session.pendingFailures or {}) or 0,
        managed = type(session) == "table" and math.max(0, tonumber(session.managedCount) or 0) or 0,
        inCombat = inCombat,
        activeSetId = U ~= nil and U.activeSetId or nil,
        switchingSetId = U ~= nil and U.switchingSetId or nil,
        persistenceDegraded = C.persistenceDegraded == true,
        writeFence = C.writeFenceReason,
    }
end

function W:ValidateSet(id)
    local ok, err = RejectBusy("检查当前装备")
    if not ok then return nil, err end
    local set = C:GetSetCopy(id)
    if type(set) ~= "table" or set.configured ~= true then return nil, "当前方案尚未配置" end
    -- Explicit user action; unlike Refresh(), this may read all managed equipped
    -- slots and current title to produce an authoritative readiness report.
    local gearMatched, mismatches = C:ValidateSetEquipped(set)
    local titleMatched, titleReason = C:CurrentTitleMatches(set)
    local rows = {}
    for _, item in ipairs(mismatches or {}) do
        rows[#rows + 1] = {
            slot = tostring(item.slotName or item.slot or "装备"),
            expected = tostring(item.name or "未知装备"),
            kind = C:IsWeaponSlot(item.slot) and "武器" or "装备",
        }
    end
    if titleMatched ~= true and type(set.title) == "table" and set.title.apply == true then
        rows[#rows + 1] = {
            slot = "称号",
            expected = C:TitleText(set.title),
            kind = tostring(titleReason or "未匹配"),
        }
    end
    return {
        matched = gearMatched == true and titleMatched == true,
        gearMatched = gearMatched == true,
        titleMatched = titleMatched == true,
        rows = rows,
        checkedAt = G.NowMs(),
    }
end
