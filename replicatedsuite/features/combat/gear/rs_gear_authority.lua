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
    local payload, err = F:LoadPayload(set.storageId); if payload == nil then return nil, err end
    local draft = F.DeepCopy(set)
    draft.items, draft.title, draft.capturedAt = payload.items, payload.title, payload.capturedAt
    draft.configured, draft.payloadRevision = payload.configured == true, math.max(set.payloadRevision or 0, payload.revision or 0)
    return draft
end

function A:CreateSet(name)
    name = Trim(name); if name == "" then return nil, "方案名称不能为空" end
    if #(F.State.sets or {}) >= F.MaxSets then return nil, "换装方案最多 " .. tostring(F.MaxSets) .. " 个" end
    for _, set in ipairs(F.State.sets or {}) do if tostring(set.name) == name then return nil, "已经存在同名方案" end end
    local id = "set_" .. tostring(F.State.nextId or 1)
    local storageId = math.max(1, math.floor(tonumber(F.State.nextStorageId) or 1))
    F.State.nextId, F.State.nextStorageId = (F.State.nextId or 1) + 1, storageId + 1
    F.State.sets[#F.State.sets + 1] = { id = id, name = name, order = #F.State.sets + 1, storageId = storageId, configured = false, quick = true, quickX = nil, quickY = nil, quickPositionCustomized = false, payloadRevision = 0 }
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
    F:ClearPayload(set.storageId)
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
    local previous, err = self:GetDraft(id); if previous == nil then return nil, err end
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

    -- SaveData has no cross-key transaction. Keep the previous shard and index
    -- metadata so a failed index commit cannot leave a newly-written payload
    -- pointing at stale metadata. A best-effort shard rollback is performed
    -- before returning the failure to the UI.
    local previousPayload, previousPayloadErr = F:LoadPayload(set.storageId)
    if previousPayload == nil then return false, previousPayloadErr end
    local previousMeta = F.DeepCopy(set)
    local payload = { configured = draft.configured == true, items = draft.items or {}, title = draft.title, capturedAt = draft.capturedAt, revision = (tonumber(draft.payloadRevision) or 0) + 1 }
    local ok, err = F:SavePayload(set.storageId, payload); if ok ~= true then return false, FriendlyPersistenceError(err) end
    set.name, set.quick, set.configured = name, draft.quick ~= false, payload.configured
    set.payloadRevision = payload.revision
    local indexOk, indexErr = F:SaveIndexNow("gear_save_payload")
    if indexOk ~= true then
        for key in pairs(set) do set[key] = nil end
        for key, value in pairs(previousMeta) do set[key] = value end
        local rollbackOk, rollbackErr = F:SavePayload(set.storageId, previousPayload)
        if rollbackOk ~= true then
            return false, FriendlyPersistenceError(indexErr) .. "；且方案分片回滚失败：" .. FriendlyPersistenceError(rollbackErr)
        end
        return false, FriendlyPersistenceError(indexErr)
    end
    self:Refresh("save")
    return true
end

function A:SetQuick(id, visible)
    local set = self:FindSet(id); if set == nil then return false, "换装方案不存在" end
    local nextValue = visible == true
    if set.quick == nextValue then return true end
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


function A:SetQuickPosition(id, x, y)
    local set = self:FindSet(id); if set == nil then return false, "换装方案不存在" end
    local nx, ny = tonumber(x), tonumber(y)
    if nx == nil or ny == nil then return false, "按钮位置无效" end
    local previousX, previousY, previousCustomized = set.quickX, set.quickY, set.quickPositionCustomized == true
    set.quickX, set.quickY = math.floor(nx + 0.5), math.floor(ny + 0.5)
    set.quickPositionCustomized = true
    local ok, err = F:SaveIndexNow("gear_quick_button_position")
    if ok ~= true then
        set.quickX, set.quickY, set.quickPositionCustomized = previousX, previousY, previousCustomized
        return false, err
    end
    self:Refresh("quick_position")
    return true
end

function A:ResetQuickPositions()
    local before = F.DeepCopy(F.State.sets)
    local changed = false
    for _, set in ipairs(F.State.sets or {}) do
        if set.quickPositionCustomized == true or set.quickX ~= nil or set.quickY ~= nil then
            set.quickPositionCustomized, set.quickX, set.quickY = false, nil, nil
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
            local payload, loadErr = F:LoadPayload(set.storageId)
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
