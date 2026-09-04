------------------------------------------------------------------------
-- Replicated Suite V3 - Gear / Title Authority
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Features = S.Features or {}; S.Features.Gear = S.Features.Gear or {}
local F = S.Features.Gear
local A = { revision = 0, rows = {}, byId = {}, currentSetId = nil, currentState = "unknown", currentCheckedAt = 0 }
F.Authority = A

local Trim = S.Utils.Trim

local function FriendlyPersistenceError(err)
    local text = tostring(err or "保存失败")
    if text:find("encoded_payload_rejected:max_nodes", 1, true) or text:find("payload_rejected:max_nodes", 1, true) then
        return "方案存档超过安全节点预算，已阻止覆盖旧数据。请重新加载新版后再保存；诊断：" .. text
    end
    if text:find("max_string_bytes", 1, true) then
        return "方案文本数据超过安全预算，已阻止覆盖旧数据；诊断：" .. text
    end
    if text:find("readback_verify_failed", 1, true) then
        return "SaveData 返回成功但立即回读校验失败；为保护上一份换装数据，本次新方案没有提交。诊断：" .. text
    end
    if text:find("write fenced", 1, true) then
        return "方案存档当前处于写保护状态，请重新加载插件后再尝试；诊断：" .. text
    end
    return text
end
local function Publish(reason)
    A.revision = A.revision + 1
    if S.Events ~= nil and type(S.Events.Publish) == "function" then S.Events:Publish("v3.gear.updated", A.revision, tostring(reason or "refresh")) end
end

function A:Refresh(reason)
    local rows, byId = {}, {}
    for _, set in ipairs(F.State.sets or {}) do
        local row = {
            id = tostring(set.id), name = tostring(set.name), order = tonumber(set.order) or #rows + 1,
            configured = set.configured == true, quick = set.quick ~= false, storageId = tonumber(set.storageId),
            quickX = tonumber(set.quickX), quickY = tonumber(set.quickY), quickPositionCustomized = set.quickPositionCustomized == true,
            quickCoordinateSpace = set.quickCoordinateSpace,
            quickAnchorH = set.quickAnchorH, quickAnchorV = set.quickAnchorV,
            quickOffsetX = tonumber(set.quickOffsetX), quickOffsetY = tonumber(set.quickOffsetY),
            payloadRevision = tonumber(set.payloadRevision) or 0,
            stateText = set.configured == true and "已配置" or "未配置",
            quickText = set.quick ~= false and "显示" or "隐藏",
        }
        rows[#rows + 1] = row; byId[row.id] = row
    end
    self.rows, self.byId = rows, byId
    Publish(reason)
    if type(F.SyncQuickButtonsHost) == "function" then F:SyncQuickButtonsHost(reason or "authority_refresh") end
    return true
end

function A:GetRows() return self.rows, self.revision end
function A:GetRow(id) return self.byId[tostring(id or "")] end
function A:FindSet(id)
    id = tostring(id or "")
    for _, set in ipairs(F.State.sets or {}) do if tostring(set.id) == id then return set end end
    return nil
end

function A:GetDraft(id)
    local set = self:FindSet(id); if set == nil then return nil, "换装方案不存在" end
    local payload, err, recovery = F:LoadPayloadForSet(set); if payload == nil then return nil, err end
    local draft = F.DeepCopy(set)
    draft.items, draft.title, draft.capturedAt = payload.items, payload.title, payload.capturedAt
    draft.configured, draft.payloadRevision = payload.configured == true, math.max(set.payloadRevision or 0, payload.revision or 0)
    draft.persistenceBank = recovery and recovery.bank or set.payloadBank
    draft.persistenceRecovered = recovery and recovery.recovered == true or false
    return draft
end

function A:CreateSet(name)
    name = Trim(name); if name == "" then return nil, "方案名称不能为空" end
    if #(F.State.sets or {}) >= F.MaxSets then return nil, "换装方案最多 " .. tostring(F.MaxSets) .. " 个" end
    for _, set in ipairs(F.State.sets or {}) do if tostring(set.name) == name then return nil, "已经存在同名方案" end end
    local id = "set_" .. tostring(F.State.nextId or 1)
    local storageId = math.max(1, math.floor(tonumber(F.State.nextStorageId) or 1))
    F.State.nextId, F.State.nextStorageId = (F.State.nextId or 1) + 1, storageId + 1
    F.State.sets[#F.State.sets + 1] = {
        id = id, name = name, order = #F.State.sets + 1, storageId = storageId, configured = false, quick = true,
        quickX = nil, quickY = nil, quickPositionCustomized = false, payloadRevision = 0,
        quickCoordinateSpace = nil, quickAnchorH = nil, quickAnchorV = nil, quickOffsetX = nil, quickOffsetY = nil,
        payloadBank = nil, payloadFingerprint = nil, backupPayloadBank = nil, backupPayloadRevision = 0, backupPayloadFingerprint = nil,
    }
    local ok, err = F:SaveIndexNow("gear_create")
    if ok ~= true then table.remove(F.State.sets); F.State.nextId = F.State.nextId - 1; F.State.nextStorageId = storageId; return nil, err end

    -- Publish the new row before asking WidgetHost to show the screen button.
    -- Otherwise the first Show()/Refresh() can observe the pre-create row cache
    -- and create no button until a later unrelated Gear refresh happens.
    self:Refresh("create")
    local runtimeOk, runtimeErr = true, nil
    if type(F.EnsurePersistentQuickRuntime) == "function" then runtimeOk, runtimeErr = F:EnsurePersistentQuickRuntime("gear_quick_created") end
    local visibleOk, visibleErr = true, nil
    if type(F.SetQuickHudVisible) == "function" then visibleOk, visibleErr = F:SetQuickHudVisible(true, "gear_quick_created") end
    if runtimeOk ~= true then return id, "方案已创建，但屏幕快捷按钮运行态未能持久启用：" .. tostring(runtimeErr or "unknown") end
    if visibleOk ~= true then return id, "方案已创建，但屏幕快捷按钮未能显示：" .. tostring(visibleErr or "unknown") end
    return id, nil
end

function A:DeleteSet(id)
    id = tostring(id or "")
    local index, set
    for i, row in ipairs(F.State.sets or {}) do if tostring(row.id) == id then index, set = i, row; break end end
    if index == nil then return false, "换装方案不存在" end
    local backup = F.DeepCopy(set)
    table.remove(F.State.sets, index); for i, row in ipairs(F.State.sets) do row.order = i end
    local ok, err = F:SaveIndexNow("gear_delete")
    if ok ~= true then table.insert(F.State.sets, index, backup); for i, row in ipairs(F.State.sets) do row.order = i end; return false, err end
    local cleared, clearErr = F:ClearPayload(set.storageId)
    if cleared ~= true and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.WarningRateLimited) == "function" then
        S.DiagnosticsManager:WarningRateLimited("gear_v3", "GEAR_PAYLOAD_CLEANUP_PARTIAL", 3000,
            "换装方案索引已删除，但部分历史分片未能物理清理", { setId = id, storageId = tostring(set.storageId), error = tostring(clearErr or "unknown") })
    end
    self:Refresh("delete")
    return true
end

function A:MoveSet(id, delta)
    id = tostring(id or ""); delta = tonumber(delta) or 0
    local index
    for i, set in ipairs(F.State.sets or {}) do if tostring(set.id) == id then index = i; break end end
    if index == nil then return false, "换装方案不存在" end
    local target = math.max(1, math.min(#F.State.sets, index + delta)); if target == index then return true end
    local before = F.DeepCopy(F.State.sets)
    local row = table.remove(F.State.sets, index); table.insert(F.State.sets, target, row)
    for i, set in ipairs(F.State.sets) do set.order = i end
    local ok, err = F:SaveIndexNow("gear_move")
    if ok ~= true then F.State.sets = before; return false, err end
    self:Refresh("move"); return true
end

function A:Rename(id, name)
    local set = self:FindSet(id); if set == nil then return false, "换装方案不存在" end
    name = Trim(name); if name == "" then return false, "方案名称不能为空" end
    for _, other in ipairs(F.State.sets or {}) do
        if other ~= set and tostring(other.name) == name then return false, "已经存在同名方案" end
    end
    if tostring(set.name) == name then return true end
    local previous = set.name; set.name = name
    local ok, err = F:SaveIndexNow("gear_rename")
    if ok ~= true then set.name = previous; return false, err end
    self:Refresh("rename")
    return true
end

function A:CaptureDraft(id)
    local previous, err = self:GetDraft(id)
    if previous == nil then
        -- A historical single-key payload may already have been truncated while
        -- its lightweight index/name survived. "获取当前" is an explicit user
        -- recovery action, so allow that action to rebuild the payload instead
        -- of trapping the named plan in an unrecoverable state. Ordinary Start/
        -- Validate still fail-closed and never overwrite missing data.
        local set = self:FindSet(id); if set == nil then return nil, err or "换装方案不存在" end
        previous = F.DeepCopy(set)
        previous.items, previous.title, previous.capturedAt = {}, {}, nil
        previous.configured = false
        previous.persistenceReinitialize = true
        previous.persistenceRecoveryReason = tostring(err or "历史方案分片不可用")
    end
    local payload, captureErr = S.Services.GearV3:CapturePayload(previous); if payload == nil then return nil, captureErr end
    previous.items, previous.title, previous.capturedAt, previous.configured = payload.items, payload.title, payload.capturedAt, true
    return previous
end

function A:SaveDraft(draft)
    if type(draft) ~= "table" then return false, "没有可保存的方案" end
    local set = self:FindSet(draft.id); if set == nil then return false, "换装方案不存在" end
    local name = Trim(draft.name); if name == "" then return false, "方案名称不能为空" end
    for _, other in ipairs(F.State.sets) do if other ~= set and tostring(other.name) == name then return false, "已经存在同名方案" end end
    local managed = 0
    for _, item in ipairs(draft.items or {}) do if item.empty ~= true and item.managed ~= false then managed = managed + 1 end end
    local titleManaged = type(draft.title) == "table" and draft.title.apply == true
    if draft.configured == true and managed <= 0 and not titleManaged then return false, "请至少选择一个装备或效果称号配置项" end

    -- Reliability v3 Gear journal:
    --   1) read the currently referenced/last-known-good payload;
    --   2) write the opposite A/B bank;
    --   3) Persistence immediately LoadData-readback verifies that bank;
    --   4) only then commit the lightweight index pointer.
    -- SaveData has no multi-key transaction, so this ordering is what guarantees
    -- an index failure never destroys the previously referenced loadout.
    local previousPayload, previousPayloadErr, previousInfo = F:LoadPayloadForSet(set)
    if previousPayload == nil then
        if draft.persistenceReinitialize ~= true then return false, previousPayloadErr end
        previousPayload = F.NormalizePayload({
            configured = false, revision = tonumber(set.payloadRevision) or 0, storageId = set.storageId, setId = set.id, items = {}, title = {},
        })
        previousInfo = { bank = F.NormalizePayloadBank(set.payloadBank) or "legacy", fingerprint = nil, recovered = false }
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.WarningRateLimited) == "function" then
            S.DiagnosticsManager:WarningRateLimited("gear_v3", "GEAR_PAYLOAD_REINITIALIZED", 3000,
                "历史换装分片不可用，已按用户“获取当前”操作重建该方案", { setId = tostring(set.id), error = tostring(previousPayloadErr or "unknown") })
        end
    end
    local previousMeta = F.DeepCopy(set)
    local previousBank = previousInfo and previousInfo.bank or F.NormalizePayloadBank(set.payloadBank) or "legacy"
    local previousFingerprint = previousInfo and previousInfo.fingerprint or nil
    if previousFingerprint == nil and previousPayload.configured == true then
        previousFingerprint = select(1, F:PayloadFingerprint(previousPayload))
    end

    local nextBank = previousBank == "a" and "b" or "a"
    local payload = {
        configured = draft.configured == true,
        items = draft.items or {},
        title = draft.title,
        capturedAt = draft.capturedAt,
        revision = (tonumber(draft.payloadRevision) or 0) + 1,
        storageId = set.storageId,
        setId = set.id,
    }
    local payloadOk, payloadErr, newFingerprint = F:SavePayload(set.storageId, payload, nextBank)
    if payloadOk ~= true then return false, FriendlyPersistenceError(payloadErr) end

    set.name, set.quick, set.configured = name, draft.quick ~= false, payload.configured
    set.payloadRevision = payload.revision
    set.payloadBank = nextBank
    set.payloadFingerprint = newFingerprint
    if previousPayload.configured == true then
        set.backupPayloadBank = previousBank
        set.backupPayloadRevision = math.max(0, math.floor(tonumber(previousPayload.revision) or 0))
        set.backupPayloadFingerprint = previousFingerprint
    else
        set.backupPayloadBank, set.backupPayloadRevision, set.backupPayloadFingerprint = nil, 0, nil
    end

    local indexOk, indexErr = F:SaveIndexNow("gear_save_payload_bank_commit")
    if indexOk ~= true then
        -- Do NOT overwrite either payload bank here. The old index still points
        -- at the old verified bank; the newly written inactive bank is merely an
        -- orphan and is safe to overwrite on the next successful save.
        for key in pairs(set) do set[key] = nil end
        for key, value in pairs(previousMeta) do set[key] = value end
        return false, FriendlyPersistenceError(indexErr)
    end
    self:Refresh("save")
    return true
end

function A:SetQuick(id, visible)
    local set = self:FindSet(id); if set == nil then return false, "换装方案不存在" end
    local nextValue = visible == true
    if set.quick == nextValue then
        -- A persisted row can already say "显示" while the Presentation widget
        -- has not been recreated yet (reload, native event downgrade, previous
        -- build failure). Treat an explicit "显示" request as a reconciliation
        -- command instead of a no-op so Domain and screen state cannot drift.
        if nextValue then
            local warning = nil
            if type(F.EnsurePersistentQuickRuntime) == "function" then
                local runtimeOk, runtimeErr = F:EnsurePersistentQuickRuntime("gear_quick_reconcile")
                if runtimeOk ~= true then warning = runtimeErr end
            end
            if type(F.SetQuickHudVisible) == "function" then
                local visibleOk, visibleErr = F:SetQuickHudVisible(true, "gear_quick_reconcile")
                if visibleOk ~= true and warning == nil then warning = visibleErr end
            end
            self:Refresh(warning == nil and "quick_reconcile" or "quick_reconcile_warning")
            return true, warning
        end
        return true
    end
    local previous = set.quick ~= false
    set.quick = nextValue
    local ok, err = F:SaveIndexNow("gear_quick_visibility")
    if ok ~= true then set.quick = previous; return false, err end
    local warning = nil
    if nextValue and type(F.EnsurePersistentQuickRuntime) == "function" then
        local runtimeOk, runtimeErr = F:EnsurePersistentQuickRuntime("gear_quick_shown")
        if runtimeOk ~= true then warning = runtimeErr end
    end
    if nextValue and type(F.SetQuickHudVisible) == "function" then
        local visibleOk, visibleErr = F:SetQuickHudVisible(true, "gear_quick_shown")
        if visibleOk ~= true and warning == nil then warning = visibleErr end
    end
    self:Refresh(warning == nil and "quick_visibility" or "quick_visibility_runtime_warning")
    return true, warning
end


local function NormalizeQuickPlacement(placement)
    if type(placement) ~= "table" then return nil end
    if tostring(placement.coordinateSpace or "") ~= "logical-edge-v1" then return nil end
    local anchorH, anchorV = tostring(placement.anchorH or ""), tostring(placement.anchorV or "")
    local offsetX, offsetY = tonumber(placement.offsetX), tonumber(placement.offsetY)
    if (anchorH ~= "LEFT" and anchorH ~= "RIGHT") or (anchorV ~= "TOP" and anchorV ~= "BOTTOM")
        or offsetX == nil or offsetY == nil then return nil end
    return {
        coordinateSpace = "logical-edge-v1",
        anchorH = anchorH,
        anchorV = anchorV,
        offsetX = math.max(0, math.floor(offsetX + 0.5)),
        offsetY = math.max(0, math.floor(offsetY + 0.5)),
    }
end

function A:SetQuickPosition(id, x, y, placement)
    local set = self:FindSet(id); if set == nil then return false, "换装方案不存在" end
    local nx, ny = tonumber(x), tonumber(y)
    if nx == nil or ny == nil then return false, "按钮位置无效" end
    local responsive = NormalizeQuickPlacement(placement)
    local previous = {
        quickX = set.quickX, quickY = set.quickY, quickPositionCustomized = set.quickPositionCustomized == true,
        quickCoordinateSpace = set.quickCoordinateSpace, quickAnchorH = set.quickAnchorH, quickAnchorV = set.quickAnchorV,
        quickOffsetX = set.quickOffsetX, quickOffsetY = set.quickOffsetY,
    }
    set.quickX, set.quickY = math.floor(nx + 0.5), math.floor(ny + 0.5)
    set.quickPositionCustomized = true
    set.quickCoordinateSpace = responsive and responsive.coordinateSpace or nil
    set.quickAnchorH = responsive and responsive.anchorH or nil
    set.quickAnchorV = responsive and responsive.anchorV or nil
    set.quickOffsetX = responsive and responsive.offsetX or nil
    set.quickOffsetY = responsive and responsive.offsetY or nil
    local ok, err = F:SaveIndexNow("gear_quick_button_position")
    if ok ~= true then
        set.quickX, set.quickY, set.quickPositionCustomized = previous.quickX, previous.quickY, previous.quickPositionCustomized
        set.quickCoordinateSpace = previous.quickCoordinateSpace
        set.quickAnchorH, set.quickAnchorV = previous.quickAnchorH, previous.quickAnchorV
        set.quickOffsetX, set.quickOffsetY = previous.quickOffsetX, previous.quickOffsetY
        return false, err
    end
    self:Refresh("quick_position")
    return true
end

function A:ResetQuickPositions()
    local before = F.DeepCopy(F.State.sets)
    local changed = false
    for _, set in ipairs(F.State.sets or {}) do
        if set.quickPositionCustomized == true or set.quickX ~= nil or set.quickY ~= nil or set.quickCoordinateSpace ~= nil then
            set.quickPositionCustomized, set.quickX, set.quickY = false, nil, nil
            set.quickCoordinateSpace, set.quickAnchorH, set.quickAnchorV, set.quickOffsetX, set.quickOffsetY = nil, nil, nil, nil, nil
            changed = true
        end
    end
    if not changed then return true end
    local ok, err = F:SaveIndexNow("gear_quick_button_positions_reset")
    if ok ~= true then F.State.sets = before; return false, err end
    self:Refresh("quick_positions_reset")
    return true
end

function A:GetQuickRows()
    local rows = {}
    for _, row in ipairs(self.rows or {}) do
        if row.quick == true then rows[#rows + 1] = row end
    end
    return rows, self.revision
end

function A:DetectCurrentQuickSet(reason)
    local service = S.Services and S.Services.GearV3 or nil
    if type(service) ~= "table" or type(service.CaptureEquippedSnapshot) ~= "function" then return nil, "gear snapshot unavailable" end

    local candidates, wantedSlots, needTitle, payloadError = {}, {}, false, nil
    for _, set in ipairs(F.State.sets or {}) do
        if set.quick ~= false and set.configured == true then
            local payload, loadErr = F:LoadPayloadForSet(set)
            if type(payload) ~= "table" then payloadError = loadErr or "方案分片不可用"; break end
            candidates[#candidates + 1] = { set = set, payload = payload }
            for _, saved in ipairs(payload.items or {}) do
                if saved.managed ~= false and saved.empty ~= true and tonumber(saved.slot) ~= nil then wantedSlots[tonumber(saved.slot)] = true end
            end
            if type(payload.title) == "table" and payload.title.apply == true then needTitle = true end
        end
    end
    if payloadError ~= nil then
        self.currentSetId, self.currentState, self.currentCheckedAt = nil, "unavailable", S.NowMs and S.NowMs() or 0
        Publish("current_payload_unavailable")
        return nil, payloadError
    end
    if #candidates == 0 then
        self.currentSetId, self.currentState, self.currentCheckedAt = nil, "none", S.NowMs and S.NowMs() or 0
        Publish("current_none")
        return nil, "none"
    end

    local snapshot, snapErr = service:CaptureEquippedSnapshot(wantedSlots, needTitle)
    if snapshot == nil then
        self.currentSetId, self.currentState, self.currentCheckedAt = nil, "unavailable", S.NowMs and S.NowMs() or 0
        Publish("current_unavailable")
        return nil, snapErr
    end
    local bestId, bestScore, tied = nil, -1, false
    for _, candidate in ipairs(candidates) do
        local matched, score = service:PayloadMatchScore(candidate.payload, snapshot)
        if matched then
            if score > bestScore then bestId, bestScore, tied = tostring(candidate.set.id), score, false
            elseif score == bestScore then tied = true end
        end
    end
    if tied then bestId = nil end
    self.currentSetId = bestId
    self.currentState = bestId ~= nil and "matched" or (tied and "ambiguous" or "none")
    self.currentCheckedAt = snapshot.capturedAt or (S.NowMs and S.NowMs() or 0)
    Publish("current_detected:" .. tostring(reason or "manual"))
    return bestId, self.currentState
end

function A:GetCurrentMatch()
    return { id = self.currentSetId, state = self.currentState, checkedAt = self.currentCheckedAt }
end

function A:Validate(id)
    local draft, err = self:GetDraft(id); if draft == nil then return nil, err end
    if draft.configured ~= true then return nil, "当前方案尚未配置" end
    local matched, rows = S.Services.GearV3:ValidatePayload(draft)
    return { matched = matched == true, rows = rows or {}, checkedAt = S.NowMs and S.NowMs() or 0 }
end

function A:Start(id)
    local draft, err = self:GetDraft(id); if draft == nil then return false, err end
    if draft.configured ~= true then return false, "当前方案尚未配置" end
    return S.Services.GearV3:Start(id, draft)
end
