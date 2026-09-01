------------------------------------------------------------------------
-- Replicated Suite V3 - Gear / Title Service
--
-- Explicit user-action service. No equipment/bag scan runs in Tick or during
-- passive page refresh. A bounded Scheduler transaction is created only while a
-- user-authorized loadout is being applied, then removed immediately.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}
S.Services.GearV3 = S.Services.GearV3 or {}
local G = S.Services.GearV3

G.version = 2
G.presentationBoundary = "service_only"
G.BagSlots = 150
G.runtime = G.runtime or { busy = false, pendingSetId = nil, session = nil, stage = "IDLE", index = 0, message = "" }
G.taskName = "v3_gear_apply"
G.enabled = false

G.EquipmentSlots = {
    { slot = 1,  key = "head",       name = "头盔" },
    { slot = 3,  key = "chest",      name = "胸甲" },
    { slot = 4,  key = "waist",      name = "腰带" },
    { slot = 8,  key = "wrists",     name = "护腕" },
    { slot = 6,  key = "hands",      name = "手套" },
    { slot = 9,  key = "cloak",      name = "披风" },
    { slot = 5,  key = "legs",       name = "腿甲" },
    { slot = 7,  key = "feet",       name = "鞋子" },
    { slot = 15, key = "underwear",  name = "内衣" },
    { slot = 2,  key = "necklace",   name = "项链" },
    { slot = 10, key = "earring1",   name = "耳环1" },
    { slot = 11, key = "earring2",   name = "耳环2", alternative = true },
    { slot = 12, key = "ring1",      name = "戒指1" },
    { slot = 13, key = "ring2",      name = "戒指2", alternative = true },
    { slot = 16, key = "mainhand",   name = "主手" },
    { slot = 17, key = "offhand",    name = "副手", alternative = true },
    { slot = 18, key = "ranged",     name = "远程" },
    { slot = 19, key = "instrument", name = "乐器" },
    { slot = 28, key = "costume",    name = "时装" },
}
G.WeaponSlots = { [16] = true, [17] = true, [18] = true, [19] = true }
G.WeaponPriority = { [16] = 10, [17] = 20, [18] = 30, [19] = 40 }

local Trim = S.Utils.Trim
local function Lower(value) return string.lower(Trim(value)) end
local function Primitive(value)
    local t = type(value); if t == "string" or t == "number" or t == "boolean" then return value end
    return nil
end
local function MeaningfulId(value)
    if value == nil or value == false or value == 0 then return nil end
    local text = tostring(value); if text == "" or text == "0" or text == "nil" or text == "false" then return nil end
    return value
end
local function DeepCopy(value) return S.Features.Gear and S.Features.Gear.DeepCopy and S.Features.Gear.DeepCopy(value) or value end
local function Publish(reason)
    if S.Events ~= nil and type(S.Events.Publish) == "function" then
        S.Events:Publish("v3.gear.updated", tostring(reason or "refresh"))
    end
end

function G:IsWeaponSlot(slot) return self.WeaponSlots[tonumber(slot)] == true end
function G:GetWeaponPriority(slot) return self.WeaponPriority[tonumber(slot)] or 999 end

function G:NormalizeItemName(name)
    local value = Trim(name)
    value = value:gsub("^[%+%-]?%d+%s+", "")
    value = value:gsub("%s*%([^%)]*%)%s*$", "")
    return Lower(value)
end

function G:ExtractModifiers(item)
    local result = {}
    local modifiers = type(item) == "table" and type(item.evolvingInfo) == "table" and item.evolvingInfo.modifier or nil
    if type(modifiers) == "table" then
        for _, entry in ipairs(modifiers) do
            if type(entry) == "table" and entry.name ~= nil then
                local name, value = Trim(entry.name), Primitive(entry.value)
                if name ~= "" then result[#result + 1] = { name = name, value = value ~= nil and tostring(value) or "" } end
            end
        end
    end
    table.sort(result, function(a, b) return Lower(a.name) .. "=" .. tostring(a.value) < Lower(b.name) .. "=" .. tostring(b.value) end)
    return result
end

function G:ModifierSignature(modifiers)
    local parts = {}
    for _, item in ipairs(type(modifiers) == "table" and modifiers or {}) do parts[#parts + 1] = Lower(item.name) .. "=" .. tostring(item.value or "") end
    return table.concat(parts, ";")
end

function G:ExtractGrade(info)
    return type(info) == "table" and tonumber(info.itemGrade or info.grade) or nil
end

function G:ExtractBagType(info)
    if type(info) ~= "table" then return nil end
    for _, key in ipairs({ "itemType", "itemTypeId", "typeId", "item_type" }) do
        local value = MeaningfulId(Primitive(info[key])); if value ~= nil then return value end
    end
    return nil
end

function G:PackAppellation(data)
    if type(data) ~= "table" then return nil end
    local packed = { values = {} }
    for index = 1, 6 do local value = Primitive(data[index]); if value ~= nil then packed.values[index] = value end end
    packed.id = MeaningfulId(packed.values[1])
    for index = 2, 6 do local value = packed.values[index]; if type(value) == "string" and Trim(value) ~= "" then packed.name = Trim(value); break end end
    return packed
end

function G:TitleText(title)
    if type(title) ~= "table" then return "未读取称号" end
    if Trim(title.displayName) ~= "" then return Trim(title.displayName) end
    local showId = title.showing and title.showing.id or nil
    local effectId = title.effect and title.effect.id or nil
    if showId ~= nil or effectId ~= nil then return "展示ID " .. tostring(showId or "-") .. " / 效果ID " .. tostring(effectId or "-") end
    return "未检测到可保存称号"
end

function G:IsInCombat()
    if X2Player == nil then return false, "X2Player unavailable" end
    local ok, value, err = S.Api:CallCapability("X2Player:PlayerInCombat", X2Player, "PlayerInCombat")
    if ok ~= true then return false, err end
    return value == true, nil
end

function G:GetEquipped(slot)
    if X2Equipment == nil then return nil, "X2Equipment unavailable" end
    local ok, value, err = S.Api:CallCapability("X2Equipment:GetEquippedItemTooltipInfo", X2Equipment, "GetEquippedItemTooltipInfo", slot, true)
    if ok ~= true then return nil, err end
    return value, nil
end

function G:GetBagItem(bagId, slot)
    if X2Bag == nil then return nil, "X2Bag unavailable" end
    local ok, value, err = S.Api:CallCapability("X2Bag:GetBagItemInfo", X2Bag, "GetBagItemInfo", bagId, slot)
    if ok ~= true then return nil, err end
    return value, nil
end

function G:CaptureTitle()
    if X2Player == nil then return nil, "X2Player unavailable" end
    local okShow, showingRaw, showErr = S.Api:CallCapability("X2Player:GetShowingAppellation", X2Player, "GetShowingAppellation")
    if okShow ~= true then return nil, "读取当前展示称号失败：" .. tostring(showErr) end
    local okEffect, effectRaw, effectErr = S.Api:CallCapability("X2Player:GetEffectAppellation", X2Player, "GetEffectAppellation")
    if okEffect ~= true then return nil, "读取当前效果称号失败：" .. tostring(effectErr) end
    local showing, effect = self:PackAppellation(showingRaw), self:PackAppellation(effectRaw)
    local name = effect and effect.name or showing and showing.name or nil
    return { apply = effect ~= nil and effect.id ~= nil, showing = showing, effect = effect, displayName = name }, nil
end

function G:CapturePayload(previous)
    previous = type(previous) == "table" and previous or {}
    local previousManaged = {}
    for _, item in ipairs(previous.items or {}) do previousManaged[tonumber(item.slot)] = item.managed ~= false end
    local hadPrevious = previous.configured == true
    local items = {}
    for _, def in ipairs(self.EquipmentSlots) do
        local tooltip, err = self:GetEquipped(def.slot)
        if err ~= nil then return nil, "读取" .. def.name .. "失败：" .. tostring(err) end
        local hasItem = type(tooltip) == "table"
        local item = {
            slot = def.slot, key = def.key, slotName = def.name, alternative = def.alternative == true,
            empty = not hasItem,
            managed = hasItem and (not hadPrevious or previousManaged[def.slot] ~= false) or false,
        }
        if hasItem then
            item.name = Trim(tooltip.name)
            item.grade = self:ExtractGrade(tooltip)
            item.itemType = self:ExtractBagType(tooltip)
            item.icon = Primitive(tooltip.icon)
            item.modifierSignature = self:ModifierSignature(self:ExtractModifiers(tooltip))
        end
        items[#items + 1] = item
    end
    local title, titleErr = self:CaptureTitle(); if title == nil then return nil, titleErr end
    return { configured = true, items = items, title = title, capturedAt = S.NowMs and S.NowMs() or 0, revision = tonumber(previous.revision) or 0 }, nil
end

function G:SavedItemMatchesTooltip(saved, tooltip)
    if type(saved) ~= "table" or saved.empty == true or type(tooltip) ~= "table" then return false end
    local wantedName, currentName = self:NormalizeItemName(saved.name), self:NormalizeItemName(tooltip.name)
    if wantedName == "" or currentName == "" or wantedName ~= currentName then return false end
    local wantedGrade, currentGrade = tonumber(saved.grade), self:ExtractGrade(tooltip)
    if wantedGrade ~= nil and currentGrade ~= nil and wantedGrade ~= currentGrade then return false end
    local wantedMods = Trim(saved.modifierSignature)
    local currentMods = self:ModifierSignature(self:ExtractModifiers(tooltip))
    if wantedMods ~= "" and currentMods ~= "" and wantedMods ~= currentMods then return false end
    return true
end

function G:CurrentItemMatches(saved)
    if type(saved) ~= "table" or saved.empty == true then return false end
    local tooltip = self:GetEquipped(saved.slot)
    return self:SavedItemMatchesTooltip(saved, tooltip)
end

-- One 19-slot read can evaluate every quick loadout in memory. This avoids the
-- O(setCount * slotCount) native-call pattern that a HUD-side per-set Validate
-- would otherwise create after UNIT_EQUIPMENT_CHANGED.
function G:CaptureEquippedSnapshot(wantedSlots, needTitle)
    local snapshot = { items = {}, titleEffectId = nil, capturedAt = S.NowMs and S.NowMs() or 0 }
    for _, def in ipairs(self.EquipmentSlots) do
        if type(wantedSlots) ~= "table" or wantedSlots[def.slot] == true then
            local tooltip, err = self:GetEquipped(def.slot)
            if err ~= nil then return nil, "读取" .. tostring(def.name) .. "失败：" .. tostring(err) end
            snapshot.items[def.slot] = tooltip
        end
    end
    if needTitle == true then
        if X2Player == nil then return nil, "X2Player unavailable" end
        local ok, raw, err = S.Api:CallCapability("X2Player:GetEffectAppellation", X2Player, "GetEffectAppellation")
        if ok ~= true then return nil, "读取当前效果称号失败：" .. tostring(err) end
        local title = self:PackAppellation(raw)
        snapshot.titleEffectId = title and title.id or nil
    end
    return snapshot, nil
end

function G:PayloadMatchScore(payload, snapshot)
    if type(payload) ~= "table" or payload.configured ~= true or type(snapshot) ~= "table" then return false, 0 end
    local score = 0
    for _, saved in ipairs(payload.items or {}) do
        if saved.managed ~= false and saved.empty ~= true then
            if not self:SavedItemMatchesTooltip(saved, snapshot.items and snapshot.items[tonumber(saved.slot)] or nil) then return false, 0 end
            score = score + 2
        end
    end
    local title = payload.title
    if type(title) == "table" and title.apply == true then
        local wanted = title.effect and MeaningfulId(title.effect.id) or nil
        if wanted == nil or snapshot.titleEffectId == nil or tostring(wanted) ~= tostring(snapshot.titleEffectId) then return false, 0 end
        score = score + 1
    end
    if score <= 0 then return false, 0 end
    return true, score
end

function G:CurrentTitleMatches(payload)
    local title = type(payload) == "table" and payload.title or nil
    if type(title) ~= "table" or title.apply ~= true then return true, "SKIPPED" end
    local wanted = title.effect and MeaningfulId(title.effect.id) or nil
    if wanted == nil then return false, "称号数据不完整" end
    local ok, raw, err = S.Api:CallCapability("X2Player:GetEffectAppellation", X2Player, "GetEffectAppellation")
    if ok ~= true then return false, "读取当前称号失败：" .. tostring(err) end
    local current = self:PackAppellation(raw)
    if current == nil or current.id == nil then return false, "当前称号状态尚未就绪" end
    return tostring(current.id) == tostring(wanted), nil
end

function G:ApplyTitle(payload)
    local title = type(payload) == "table" and payload.title or nil
    if type(title) ~= "table" or title.apply ~= true then return true, "SKIPPED" end
    local matched, reason = self:CurrentTitleMatches(payload); if matched then return true, "ALREADY" end
    if reason ~= nil and reason ~= "SKIPPED" then -- still continue only when current state was readable
        if tostring(reason):find("读取当前称号失败", 1, true) then return false, reason end
    end
    local effect = title.effect and MeaningfulId(title.effect.id) or nil
    if effect == nil then return false, "称号数据不完整" end
    local ok, raw, err = S.Api:CallCapability("X2Player:GetShowingAppellation", X2Player, "GetShowingAppellation")
    if ok ~= true then return false, "读取当前称号展示类型失败：" .. tostring(err) end
    local currentShowing = self:PackAppellation(raw)
    local showing = currentShowing and MeaningfulId(currentShowing.id) or title.showing and MeaningfulId(title.showing.id) or nil
    if showing == nil then return false, "无法取得当前称号展示类型" end
    local callOk, value, callErr = S.Api:CallCapability("X2Player:ChangeAppellation", X2Player, "ChangeAppellation", showing, effect)
    if callOk ~= true then return false, callErr end
    return true, value
end

function G:ValidatePayload(payload)
    local mismatches = {}
    for _, saved in ipairs(type(payload) == "table" and payload.items or {}) do
        if saved.managed ~= false and saved.empty ~= true and not self:CurrentItemMatches(saved) then
            mismatches[#mismatches + 1] = { slot = saved.slot, slotName = saved.slotName, name = saved.name, kind = self:IsWeaponSlot(saved.slot) and "武器" or "装备" }
        end
    end
    local titleMatched, titleReason = self:CurrentTitleMatches(payload)
    if titleMatched ~= true and type(payload) == "table" and type(payload.title) == "table" and payload.title.apply == true then
        mismatches[#mismatches + 1] = { slotName = "称号", name = self:TitleText(payload.title), kind = tostring(titleReason or "未匹配") }
    end
    return #mismatches == 0, mismatches
end

function G:BuildBagCandidate(bagId, slot, info)
    if type(info) ~= "table" then return nil end
    return {
        bagId = bagId, slot = slot, name = Trim(info.name), normalizedName = self:NormalizeItemName(info.name),
        grade = self:ExtractGrade(info), itemType = self:ExtractBagType(info),
        modifierSignature = self:ModifierSignature(self:ExtractModifiers(info)),
    }
end

function G:BuildBagView(bagId)
    local list, errors, firstError = {}, 0, nil
    for slot = 1, self.BagSlots do
        local info, err = self:GetBagItem(bagId, slot)
        if err ~= nil then errors = errors + 1; firstError = firstError or err
        elseif type(info) == "table" then list[#list + 1] = self:BuildBagCandidate(bagId, slot, info) end
    end
    return { bagId = bagId, items = list, errors = errors, firstError = firstError }
end

function G:CandidateFingerprint(candidate)
    return table.concat({
        tostring(candidate and candidate.normalizedName or ""),
        tostring(candidate and candidate.grade or ""),
        tostring(candidate and candidate.modifierSignature or ""),
    }, "|")
end

function G:SamePhysicalBagView(left, right)
    left, right = type(left) == "table" and left or {}, type(right) == "table" and right or {}
    if #(left.items or {}) ~= #(right.items or {}) then return false end
    local bySlot = {}
    for _, candidate in ipairs(left.items or {}) do bySlot[tonumber(candidate.slot)] = self:CandidateFingerprint(candidate) end
    for _, candidate in ipairs(right.items or {}) do
        if bySlot[tonumber(candidate.slot)] ~= self:CandidateFingerprint(candidate) then return false end
    end
    return true
end

-- EquipBagItem accepts only a physical slot, not a bagId. Some RU/community
-- builds expose that physical inventory through bagId 0, bagId 1, or both. If
-- both populated views disagree, fail closed: choosing a candidate from one
-- logical view and passing only its numeric slot could equip an unrelated item.
function G:BuildBagSnapshot()
    local view1, view0 = self:BuildBagView(1), self:BuildBagView(0)
    local count1, count0 = #(view1.items or {}), #(view0.items or {})
    local selected, conflict = view1, false
    if count1 == 0 and count0 > 0 then
        selected = view0
    elseif count1 > 0 and count0 > 0 and not self:SamePhysicalBagView(view1, view0) then
        conflict = true
    elseif count1 == 0 and count0 == 0 and (view1.errors or 0) > (view0.errors or 0) then
        selected = view0
    end
    return {
        bagId = selected.bagId,
        items = selected.items or {},
        errors = selected.errors or 0,
        firstError = selected.firstError,
        viewConflict = conflict,
        counts = { [0] = count0, [1] = count1 },
        errorsByBag = { [0] = view0.errors or 0, [1] = view1.errors or 0 },
    }
end

function G:CandidateMatches(saved, candidate)
    if type(saved) ~= "table" or type(candidate) ~= "table" then return false, 0 end
    local wantedName, gotName = self:NormalizeItemName(saved.name), candidate.normalizedName
    if wantedName == "" or gotName == "" or wantedName ~= gotName then return false, 0 end
    local wantedGrade, gotGrade = tonumber(saved.grade), tonumber(candidate.grade)
    if wantedGrade ~= nil and gotGrade ~= nil and wantedGrade ~= gotGrade then return false, 0 end
    local wantedMods, gotMods = Trim(saved.modifierSignature), Trim(candidate.modifierSignature)
    if wantedMods ~= "" and wantedMods ~= gotMods then return false, 0 end
    local score = 50
    if wantedGrade ~= nil and gotGrade == wantedGrade then score = score + 10 end
    if wantedMods ~= "" then score = score + 25 end
    if saved.itemType ~= nil and candidate.itemType ~= nil and tostring(saved.itemType) == tostring(candidate.itemType) then score = score + 100 end
    return true, score
end

function G:FindCandidate(saved, snapshot, reserved)
    reserved = type(reserved) == "table" and reserved or {}
    local topScore, top = nil, {}
    for _, candidate in ipairs(type(snapshot) == "table" and snapshot.items or {}) do
        if reserved[tonumber(candidate.slot)] ~= true then
            local matched, score = self:CandidateMatches(saved, candidate)
            if matched then
                if topScore == nil or score > topScore then topScore, top = score, { candidate }
                elseif score == topScore then top[#top + 1] = candidate end
            end
        end
    end
    if #top == 0 then
        if type(snapshot) == "table" and (tonumber(snapshot.errors) or 0) > 0 then return nil, "读取背包时发生错误" end
        return nil, "背包中未找到目标装备"
    end
    if #top == 1 then return top[1], nil end
    local fingerprint = self:CandidateFingerprint(top[1])
    for index = 2, #top do
        if self:CandidateFingerprint(top[index]) ~= fingerprint then return nil, "存在多个不同候选，无法安全判断" end
    end
    -- Exact-identical copies are interchangeable for the saved fingerprint.
    -- Pick the lowest physical slot deterministically and reserve it.
    table.sort(top, function(a, b) return tonumber(a.slot) < tonumber(b.slot) end)
    return top[1], nil
end

function G:BuildSession(setId, payload, mismatchRows)
    local wantedSlots = nil
    if type(mismatchRows) == "table" then
        wantedSlots = {}
        for _, row in ipairs(mismatchRows) do
            local slot = tonumber(row and row.slot)
            if slot ~= nil then wantedSlots[slot] = true end
        end
    end

    local pendingSaved = {}
    for _, saved in ipairs(payload.items or {}) do
        if saved.managed ~= false and saved.empty ~= true then
            local mismatch
            if wantedSlots ~= nil then mismatch = wantedSlots[tonumber(saved.slot)] == true
            else mismatch = not self:CurrentItemMatches(saved) end
            if mismatch then pendingSaved[#pendingSaved + 1] = saved end
        end
    end

    -- A title-only loadout, or a loadout whose gear is already correct, must
    -- not scan 300 bag slots just because the title still needs changing.
    if #pendingSaved == 0 then
        return {
            setId = tostring(setId), payload = payload, queue = {}, blocked = {}, reserved = {},
            startedAt = S.NowMs and S.NowMs() or 0,
            titlePending = type(payload.title) == "table" and payload.title.apply == true,
        }
    end

    local snapshot = self:BuildBagSnapshot()
    if snapshot.viewConflict == true then
        return {
            setId = tostring(setId), payload = payload, queue = {}, blocked = {}, reserved = {},
            startedAt = S.NowMs and S.NowMs() or 0, titlePending = type(payload.title) == "table" and payload.title.apply == true,
            preflightError = "客户端返回的两个背包视图不一致；为避免装备错误物品，本次换装已取消",
        }
    end
    local queue, reserved, blocked = {}, {}, {}
    for _, saved in ipairs(pendingSaved) do
        local candidate, reason = self:FindCandidate(saved, snapshot, reserved)
        if candidate == nil then blocked[#blocked + 1] = { slotName = saved.slotName, name = saved.name, reason = reason }
        else
            reserved[tonumber(candidate.slot)] = true
            queue[#queue + 1] = { saved = saved, bagSlot = candidate.slot, bagId = snapshot.bagId, alternative = saved.alternative == true, attempts = 0, verifyPolls = 0 }
        end
    end
    table.sort(queue, function(a, b)
        local aw, bw = self:IsWeaponSlot(a.saved.slot), self:IsWeaponSlot(b.saved.slot)
        if aw ~= bw then return aw end
        if aw then
            local ap, bp = self:GetWeaponPriority(a.saved.slot), self:GetWeaponPriority(b.saved.slot)
            if ap ~= bp then return ap < bp end
        end
        return tonumber(a.saved.slot) < tonumber(b.saved.slot)
    end)
    return {
        setId = tostring(setId), payload = payload, queue = queue, blocked = blocked, reserved = reserved,
        bagId = snapshot.bagId, startedAt = S.NowMs and S.NowMs() or 0,
        titlePending = type(payload.title) == "table" and payload.title.apply == true,
    }
end

function G:RefreshStepCandidate(step, session)
    local snapshot = self:BuildBagSnapshot()
    if snapshot.viewConflict == true then return false, "背包视图发生冲突，已停止重试" end
    local candidate, reason = self:FindCandidate(step.saved, snapshot, {})
    if candidate == nil then return false, reason end
    step.bagSlot, step.bagId = candidate.slot, snapshot.bagId
    return true
end

function G:StopRuntime(reason)
    if S.Scheduler ~= nil then S.Scheduler:RemoveTask(self.taskName) end
    local r = self.runtime
    r.busy, r.session, r.stage, r.index = false, nil, "IDLE", 0
    if reason ~= nil then r.message = tostring(reason) end
    Publish("runtime_stopped")
end

function G:FinishRuntime(ok, message)
    local session = self.runtime.session
    if S.Scheduler ~= nil then S.Scheduler:RemoveTask(self.taskName) end
    self.runtime.busy = false
    self.runtime.stage = ok and "DONE" or "FAILED"
    self.runtime.message = tostring(message or (ok and "换装完成" or "换装失败"))
    self.runtime.lastSetId = session and session.setId or self.runtime.lastSetId
    self.runtime.session = nil
    Publish("runtime_finished")

    -- A page may have transiently enabled Gear solely for this explicit user
    -- action. If the player closed that page mid-transaction, finish the
    -- transaction first and then return the Feature to its previous idle state.
    local feature = S.Features and S.Features.Gear or nil
    if type(feature) == "table" and feature.disableWhenIdle == true then
        feature.disableWhenIdle = false
        if type(feature.MaybeDisableTransient) == "function" then feature:MaybeDisableTransient("gear_transient_idle") end
    end
    return ok
end

function G:RuntimeTick()
    local r, session = self.runtime, self.runtime.session
    if r.busy ~= true or type(session) ~= "table" then self:StopRuntime(); return true end
    local inCombat = self:IsInCombat()
    if inCombat == true then
        r.pendingSetId = session.setId
        return self:FinishRuntime(true, "战斗开始，剩余换装已暂停；脱战后可再次执行")
    end
    if (S.NowMs and S.NowMs() or 0) - (session.startedAt or 0) > 60000 then return self:FinishRuntime(false, "换装总超时，已停止") end

    local step = session.queue[r.index]
    if step == nil then
        local matched = self:ValidatePayload(session.payload)
        if matched == true then return self:FinishRuntime(true, "装备和称号已经达到目标状态") end
        if session.titlePending == true then
            r.stage = "TITLE"
            local titleOk, titleReason = self:ApplyTitle(session.payload)
            if titleOk ~= true then return self:FinishRuntime(false, "装备已处理，但称号切换失败：" .. tostring(titleReason)) end
            session.titlePending = false
            session.titleVerifyPolls = 0
            Publish("title_action")
            return true
        end
        local titleMatched, titleReason = self:CurrentTitleMatches(session.payload)
        if titleMatched ~= true then
            session.titleVerifyPolls = (session.titleVerifyPolls or 0) + 1
            if session.titleVerifyPolls <= 5 then return true end
            return self:FinishRuntime(false, "称号验证失败：" .. tostring(titleReason or "未切换"))
        end
        local gearMatched, mismatches = self:ValidatePayload(session.payload)
        if gearMatched ~= true then return self:FinishRuntime(false, "仍有 " .. tostring(#mismatches) .. " 项未达到目标状态") end
        return self:FinishRuntime(true, "换装 / 称号完成")
    end

    if self:CurrentItemMatches(step.saved) then r.index = r.index + 1; r.stage = "ACTION"; Publish("step_skip"); return true end
    if r.stage == "VERIFY" then
        step.verifyPolls = (step.verifyPolls or 0) + 1
        if step.verifyPolls <= 7 then return true end
        if step.attempts >= 3 then return self:FinishRuntime(false, tostring(step.saved.slotName) .. "连续多次未生效") end
        local found, reason = self:RefreshStepCandidate(step, session)
        if found ~= true then return self:FinishRuntime(false, tostring(step.saved.slotName) .. "重试查找失败：" .. tostring(reason)) end
        r.stage = "ACTION"; step.verifyPolls = 0; return true
    end

    r.stage = "ACTION"
    step.attempts = (step.attempts or 0) + 1
    local ok, _, err = S.Api:CallCapability("X2Bag:EquipBagItem", X2Bag, "EquipBagItem", step.bagSlot, step.alternative == true)
    if ok ~= true then return self:FinishRuntime(false, tostring(step.saved.slotName) .. "换装调用失败：" .. tostring(err)) end
    r.stage = "VERIFY"; step.verifyPolls = 0
    Publish("step_action")
    return true
end

function G:Start(setId, payload)
    if self.enabled ~= true then return false, "换装功能未启用" end
    if self.runtime.busy == true then return false, "已有换装任务正在执行" end
    local inCombat, combatErr = self:IsInCombat()
    if combatErr ~= nil then return false, "无法确认战斗状态：" .. tostring(combatErr) end
    if inCombat == true then
        self.runtime.pendingSetId = tostring(setId)
        self.runtime.message = "战斗中客户端会拒绝自动装备；已记录方案，脱战后请再次执行"
        Publish("combat_blocked")
        return false, self.runtime.message
    end
    local matched, mismatches = self:ValidatePayload(payload)
    if matched == true then self.runtime.message = "当前已经是目标方案"; Publish("already_matched"); return true end
    local session = self:BuildSession(setId, payload, mismatches)
    if session.preflightError ~= nil then return false, tostring(session.preflightError) end
    if #session.blocked > 0 then
        local first = session.blocked[1]
        return false, tostring(first.slotName or "装备") .. "：" .. tostring(first.reason or "无法定位")
    end
    self.runtime.busy, self.runtime.session, self.runtime.stage, self.runtime.index = true, session, "ACTION", 1
    self.runtime.pendingSetId = nil
    self.runtime.message = "正在切换“" .. tostring(setId) .. "”"
    if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then self:StopRuntime("调度器不可用"); return false, self.runtime.message end
    S.Scheduler:SetTaskModule(self.taskName, "gear")
    local added = S.Scheduler:AddTask(self.taskName, 220, function() return G:RuntimeTick() end, true, self, "P1", 2)
    if added ~= true then self:StopRuntime("无法启动换装调度事务"); return false, self.runtime.message end
    Publish("runtime_started")
    return true
end

function G:SetEnabled(enabled)
    self.enabled = enabled == true
    if not self.enabled and self.runtime.busy == true then self:StopRuntime("换装功能已关闭") end
    return true
end

function G:GetRuntimeSnapshot()
    local r = self.runtime
    local session = r.session
    return {
        enabled = self.enabled == true, busy = r.busy == true, stage = tostring(r.stage or "IDLE"),
        index = tonumber(r.index) or 0, total = session and #(session.queue or {}) or 0,
        setId = session and session.setId or r.lastSetId, pendingSetId = r.pendingSetId,
        message = tostring(r.message or ""),
    }
end
