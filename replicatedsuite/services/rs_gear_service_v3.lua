-- Replicated Suite · 装备与称号操作
-- 作者：Replicated
-- QQ群：1104129461
-- 只响应显式换装动作，应用时才建立有限 Scheduler 事务，结束即移除；被动刷新不扫装备或背包。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}
S.Services.GearV3 = S.Services.GearV3 or {}
local G = S.Services.GearV3

G.version = 5
G.PartialApplyContractVersion = 1
G.ContinuationContractVersion = 1
G.continuationPatch = "gear-partial-continuation-1"
G.TitleEffectAuthorityContractVersion = 1
G.presentationBoundary = "service_only"
G.BagSlots = 150
G.MaxBagSlots = 240
G.PreferredBagId = 1
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
local function DeepCopy(value)
    if S.Utils ~= nil and type(S.Utils.DeepCopy) == "function" then return S.Utils.DeepCopy(value) end
    return value
end
local function Publish(reason)
    if S.Events ~= nil and type(S.Events.Publish) == "function" then
        S.Events:Publish("v3.gear.updated", tostring(reason or "refresh"))
    end
end

function G:IsWeaponSlot(slot) return self.WeaponSlots[tonumber(slot)] == true end
function G:GetWeaponPriority(slot) return self.WeaponPriority[tonumber(slot)] or 999 end
function G:IsRingSlot(slot) return tonumber(slot) == 12 or tonumber(slot) == 13 end
-- RU 官方数据库：wiki.archerage.to/ru-cn/db/items/48559（关联 48628），充盈的拉玛哈的戒指。
-- 用户实机契约：可持有两枚但只佩戴一枚；不按“大象”昵称猜物品，不增加装备/卸装能力。
function G:IsSingleWearRing(itemType) return tonumber(itemType) == 48559 or tonumber(itemType) == 48628 end
function G:RequiresRingIdentity(saved)
    return type(saved)=='table' and self:IsRingSlot(saved.slot)
        and (MeaningfulId(saved.itemType)==nil or self:IsSingleWearRing(saved.itemType)
            or type(saved.ringIdentity)=='table' or Trim(saved.modifierSignature)~='')
end
function G:HasSingleWearRingConflict(payload)
    local count=0
    for _,saved in ipairs(type(payload)=='table' and payload.items or {})do
        if self:IsRingSlot(saved.slot) and saved.managed~=false and saved.empty~=true and self:IsSingleWearRing(saved.itemType) then count=count+1 end
    end
    return count>1
end

function G:ExtractRingIdentity(item)
    -- 只由戒指捕获/同名候选/回读使用。完整读取与未知分离；不把 ipairs 截断、空值或畸形词条当作无属性。
    local function Unknown(reason) return { version=1, status='unknown', reason=reason, summary='词条不可读：'..reason } end
    local list=type(item)=='table' and type(item.evolvingInfo)=='table' and item.evolvingInfo.modifier or nil
    if type(list)~='table' then return Unknown('未提供 evolvingInfo.modifier') end
    if self:ExtractBagType(item)==nil or self:ExtractGrade(item)==nil then return Unknown('物品类型或品质缺失') end
    local count,ordered=0,{}
    for key,entry in pairs(list)do
        local index=tonumber(key)
        if index==nil or index<1 or index~=math.floor(index) or index>16 or ordered[index]~=nil then return Unknown('词条列表不完整或超过16项') end
        ordered[index]=entry;count=count+1
    end
    local rows={}
    for index=1,count do
        local entry=ordered[index]
        if type(entry)~='table' or type(entry.name)~='string' then return Unknown('词条名称缺失或列表稀疏') end
        local name,value=Trim(entry.name),entry.value
        if name=='' or #name>128 or (type(value)~='string' and type(value)~='number') then return Unknown('词条名称或数值无效') end
        -- 数字原值直接规范化，先 tostring/Trim 会丢失 Lua 5.1 的有效精度。
        if type(value)=='string' then
            value=Trim(value);if value=='' or #value>128 then return Unknown('词条数值缺失或过长') end
        end
        local number=tonumber(value)
        if number~=nil then
            if number~=number or number==math.huge or number==-math.huge then return Unknown('词条数值不是有限数') end
            value=string.format('%.17g',number==0 and 0 or number)
        elseif type(entry.value)=='number' then return Unknown('词条数值不是有限数') end
        -- 长度编码避免名称中的 =/; 与不同词条形成同一签名；文字值保留单位，不猜百分比。
        local key=Lower(name)
        rows[#rows+1]={ key=tostring(#key)..':'..key..tostring(#value)..':'..value, text=name..' '..value }
    end
    table.sort(rows,function(a,b)return a.key<b.key end)
    local signature,summary={'ring1'},{}
    for _,row in ipairs(rows)do signature[#signature+1]=row.key;summary[#summary+1]=row.text end
    return {version=1,status='known',signature=table.concat(signature,'|'),summary=#summary>0 and table.concat(summary,'；') or '无成长词条（已读取）'}
end

function G:SavedRingIdentityError(saved)
    local identity=type(saved)=='table' and saved.ringIdentity or nil
    if type(identity)~='table' or identity.version~=1 then return '戒指词条未记录，请重新获取当前并保存方案','ring_recapture_required' end
    if identity.status~='known' or Trim(identity.signature)=='' then return '戒指词条不可读：'..tostring(identity.reason or '请重新获取当前并保存方案'),'ring_identity_unknown' end
end

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
    -- 方案只切换效果称号，显示优先取 effect 名称。历史 showing 仅作兼容/诊断，不能让用户误以为会恢复展示称号。
    local effectName = type(title.effect) == "table" and Trim(title.effect.name) or ""
    if effectName ~= "" then return effectName end
    if Trim(title.displayName) ~= "" then return Trim(title.displayName) end
    local effectId = title.effect and title.effect.id or nil
    if effectId ~= nil then return "效果ID " .. tostring(effectId) end
    return "未检测到可保存效果称号"
end

function G:IsInCombat()
    if X2Player == nil then return false, "X2Player unavailable" end
    local ok, value, err = S.Api:CallCapability("X2Player:PlayerInCombat", X2Player, "PlayerInCombat")
    if ok ~= true then return false, err end
    return value == true, nil
end

function G:GetEquipped(slot)
    if X2Equipment == nil then return nil, "X2Equipment unavailable" end
    -- 自身 HUD 的 GetEquipped 使用 false 选择器；RU 各版本布尔语义有差异，目标 HUD 不能用它读目标装备。
    local ok, value, err = S.Api:CallCapability("X2Equipment:GetEquippedItemTooltipInfo", X2Equipment, "GetEquippedItemTooltipInfo", slot, false)
    if ok ~= true then return nil, err end
    return value, nil
end

function G:GetLoadoutEquipped(slot)
    if X2Equipment == nil then return nil, "X2Equipment unavailable" end
    -- 换装 Capture/Validate/Verify 使用 true，HUD 仍用 false；受影响 RU 的 false 会把已穿装备误判 mismatch，阻住槽28和称号。
    -- 统一参数前须同时实测换装与 HUD，不能凭远程 HUD 的 ranged.enabled=false 改事务选择器。
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

function G:GetBagScanLimit()
    local fallback = tonumber(self.BagSlots) or 150
    if X2Bag == nil or S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function"
        or S.Api:IsCapabilityAllowed("X2Bag:Capacity") ~= true then
        return fallback
    end
    local ok, value = S.Api:CallCapability("X2Bag:Capacity", X2Bag, "Capacity")
    local capacity = ok == true and tonumber(value) or nil
    if capacity == nil or capacity <= 0 then return fallback end
    return math.max(1, math.min(tonumber(self.MaxBagSlots) or 240, math.floor(capacity)))
end

function G:CaptureTitle()
    if X2Player == nil then return nil, "X2Player unavailable" end
    -- 展示 nameType 与效果 effectType 可不同；方案只保存并执行 effect，showing 留作兼容快照。
    -- nameType=0 合法；展示读失败但 effect 可读时仍可捕获。
    local okEffect, effectRaw, effectErr = S.Api:CallCapability("X2Player:GetEffectAppellation", X2Player, "GetEffectAppellation")
    if okEffect ~= true then return nil, "读取当前效果称号失败：" .. tostring(effectErr) end
    local effect = self:PackAppellation(effectRaw)

    local showing = nil
    local okShow, showingRaw = S.Api:CallCapability("X2Player:GetShowingAppellation", X2Player, "GetShowingAppellation")
    if okShow == true then showing = self:PackAppellation(showingRaw) end

    local name = effect and effect.name or nil
    return { apply = effect ~= nil and effect.id ~= nil, showing = showing, effect = effect, displayName = name }, nil
end

function G:CapturePayload(previous)
    previous = type(previous) == "table" and previous or {}
    local previousUnchecked = {}
    -- 旧空槽的 managed=false 不等于用户取消勾选；重新获取已有装备时，只继承“原来有装备且主动取消”的选择。
    if previous.configured == true then
        for _, item in ipairs(previous.items or {}) do
            previousUnchecked[tonumber(item.slot)] = item.empty ~= true and item.managed == false
        end
    end
    local items = {}
    for _, def in ipairs(self.EquipmentSlots) do
        local tooltip, err = self:GetLoadoutEquipped(def.slot)
        if err ~= nil then return nil, "读取" .. def.name .. "失败：" .. tostring(err) end
        local hasItem = type(tooltip) == "table"
        local item = {
            slot = def.slot, key = def.key, slotName = def.name, alternative = def.alternative == true,
            empty = not hasItem,
            managed = hasItem and previousUnchecked[def.slot] ~= true or false,
        }
        if hasItem then
            item.name = Trim(tooltip.name)
            item.grade = self:ExtractGrade(tooltip)
            item.itemType = self:ExtractBagType(tooltip)
            item.icon = Primitive(tooltip.icon)
            item.modifierSignature = self:ModifierSignature(self:ExtractModifiers(tooltip))
            if self:IsRingSlot(def.slot) and (self:RequiresRingIdentity(item) or type(tooltip.evolvingInfo)=='table') then
                item.ringIdentity=self:ExtractRingIdentity(tooltip)
            end
        end
        items[#items + 1] = item
    end
    local title, titleErr = self:CaptureTitle(); if title == nil then return nil, titleErr end
    return { configured = true, items = items, title = title, capturedAt = S.NowMs and S.NowMs() or 0, revision = tonumber(previous.revision) or 0 }, nil
end

function G:SavedItemMatchesTooltip(saved, tooltip)
    if type(saved) ~= "table" or saved.empty == true or type(tooltip) ~= "table" then return false end
    if self:RequiresRingIdentity(saved) and self:SavedRingIdentityError(saved)~=nil then return false end
    local wantedName, currentName = self:NormalizeItemName(saved.name), self:NormalizeItemName(tooltip.name)
    if wantedName == "" or currentName == "" or wantedName ~= currentName then return false end
    -- 双方稳定 ID 都存在且冲突时必须拒绝；旧方案缺 ID 才用原名称/品质/属性指纹兼容。
    local currentType = self:ExtractBagType(tooltip)
    if saved.itemType ~= nil and currentType ~= nil and tostring(saved.itemType) ~= tostring(currentType) then return false end
    local wantedGrade, currentGrade = tonumber(saved.grade), self:ExtractGrade(tooltip)
    if wantedGrade ~= nil and currentGrade ~= nil and wantedGrade ~= currentGrade then return false end
    if self:RequiresRingIdentity(saved) then
        local current=self:ExtractRingIdentity(tooltip)
        return saved.itemType~=nil and currentType~=nil and tostring(saved.itemType)==tostring(currentType)
            and wantedGrade~=nil and wantedGrade==currentGrade and current.status=='known' and saved.ringIdentity.signature==current.signature
    end
    local wantedMods = Trim(saved.modifierSignature)
    local currentMods = self:ModifierSignature(self:ExtractModifiers(tooltip))
    if wantedMods ~= "" and currentMods ~= "" and wantedMods ~= currentMods then return false end
    return true
end

function G:CurrentItemMatches(saved)
    if type(saved) ~= "table" or saved.empty == true then return false end
    -- 第二返回值保留读取失败；不可验证的槽跳过，不能把未知当普通 mismatch 后授权动作。
    local tooltip, err = self:GetLoadoutEquipped(saved.slot)
    if err ~= nil then return false, err end
    if self:RequiresRingIdentity(saved) then
        local reason,code=self:SavedRingIdentityError(saved);if reason then return false,reason,code end
        if type(tooltip)=='table' and self:NormalizeItemName(saved.name)==self:NormalizeItemName(tooltip.name)
            and (self:ExtractBagType(tooltip)==nil or tostring(saved.itemType)==tostring(self:ExtractBagType(tooltip))) then
            local identity=self:ExtractRingIdentity(tooltip)
            if identity.status~='known' then return false,'当前戒指词条不可读：'..identity.reason,'ring_identity_unknown' end
        end
    end
    return self:SavedItemMatchesTooltip(saved, tooltip), nil
end

-- 一次 19 槽读取可在内存评估全部快捷套装，避免 UNIT_EQUIPMENT_CHANGED 后 HUD 为每个套装 Validate 形成 O(
-- setCount*slotCount) 原生调用。
function G:CaptureEquippedSnapshot(wantedSlots, needTitle)
    local snapshot = { items = {}, titleEffectId = nil, capturedAt = S.NowMs and S.NowMs() or 0 }
    for _, def in ipairs(self.EquipmentSlots) do
        if type(wantedSlots) ~= "table" or wantedSlots[def.slot] == true then
            local tooltip, err = self:GetLoadoutEquipped(def.slot)
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
    if self:HasSingleWearRingConflict(payload) then return false,0 end
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

function G:GetCurrentShowingAppellationType()
    if X2Player == nil then return nil, "X2Player unavailable" end
    local ok, raw, err = S.Api:CallCapability("X2Player:GetShowingAppellation", X2Player, "GetShowingAppellation")
    if ok ~= true then return nil, "读取当前称号展示类型失败：" .. tostring(err) end

    -- titleswap 执行前读取当前 GetShowingAppellation()[1]；无展示称号或 nil 时传 0，不能用会滤掉 0 的 MeaningfulId。
    -- 只读执行此刻的展示状态，绝不能回退保存时的 showing，避免切效果时恢复旧名称称号。
    if raw == nil then return 0, nil end
    if type(raw) ~= "table" then return nil, "当前称号展示数据格式异常" end
    local value = Primitive(raw[1])
    if value == nil then return 0, nil end
    local numeric = tonumber(value)
    if numeric == nil then return nil, "当前称号展示类型不是数字：" .. tostring(value) end
    return numeric, nil
end

function G:ApplyTitle(payload)
    local title = type(payload) == "table" and payload.title or nil
    if type(title) ~= "table" or title.apply ~= true then return true, "SKIPPED" end
    local matched, reason = self:CurrentTitleMatches(payload); if matched then return true, "ALREADY" end
    if reason ~= nil and reason ~= "SKIPPED" then -- 只有当前效果状态可读时才继续。
        if tostring(reason):find("读取当前称号失败", 1, true) then return false, reason end
    end
    local effect = title.effect and MeaningfulId(title.effect.id) or nil
    if effect == nil then return false, "称号效果数据不完整" end

    -- 方案只决定 effectType，nameType 保留执行时当前值；保存时 showing 不参与动作参数。
    local showing, showingErr = self:GetCurrentShowingAppellationType()
    if showing == nil then return false, showingErr or "无法取得当前称号展示类型" end
    local effectType = tonumber(effect) or effect
    local callOk, value, callErr = S.Api:CallCapability("X2Player:ChangeAppellation", X2Player, "ChangeAppellation", showing, effectType)
    if callOk ~= true then return false, callErr end
    if value == false then return false, "ChangeAppellation rejected" end
    return true, value
end

function G:ValidatePayload(payload)
    local mismatches = {}
    local conflict=self:HasSingleWearRingConflict(payload)
    for _, saved in ipairs(type(payload) == "table" and payload.items or {}) do
        if saved.managed ~= false and saved.empty ~= true and ((conflict and self:IsRingSlot(saved.slot) and self:IsSingleWearRing(saved.itemType)) or not self:CurrentItemMatches(saved)) then
            mismatches[#mismatches + 1] = { slot = saved.slot, slotName = saved.slotName, name = saved.name, kind = self:IsWeaponSlot(saved.slot) and "武器" or "装备" }
        end
    end
    local titleMatched, titleReason = self:CurrentTitleMatches(payload)
    if titleMatched ~= true and type(payload) == "table" and type(payload.title) == "table" and payload.title.apply == true then
        mismatches[#mismatches + 1] = { slotName = "称号", name = self:TitleText(payload.title), kind = tostring(titleReason or "未匹配") }
    end
    return #mismatches == 0, mismatches
end

function G:ValidateWeaponPayload(payload)
    local mismatches = {}
    for _, saved in ipairs(type(payload) == "table" and payload.items or {}) do
        if saved.managed ~= false and saved.empty ~= true and self:IsWeaponSlot(saved.slot)
            and not self:CurrentItemMatches(saved) then
            mismatches[#mismatches + 1] = { slot = saved.slot, slotName = saved.slotName, name = saved.name, kind = "武器" }
        end
    end
    return #mismatches == 0, mismatches
end

function G:BuildBagCandidate(bagId, slot, info)
    if type(info) ~= "table" then return nil end
    return {
        bagId = bagId, slot = slot, name = Trim(info.name), normalizedName = self:NormalizeItemName(info.name),
        grade = self:ExtractGrade(info), itemType = self:ExtractBagType(info),
        modifierSignature = self:ModifierSignature(self:ExtractModifiers(info)),
        -- 保留本次读取的有限词条来源，详细解析只在戒指候选匹配时执行，不增加每帧/额外背包读取。
        ringSource = { itemType=self:ExtractBagType(info), itemGrade=self:ExtractGrade(info), evolvingInfo=info.evolvingInfo },
    }
end

function G:BuildBagView(bagId)
    local list, errors, firstError = {}, 0, nil
    local scanLimit = self:GetBagScanLimit()
    for slot = 1, scanLimit do
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
        tostring(candidate and candidate.ringIdentity and candidate.ringIdentity.signature or ''),
    }, "|")
end

-- EquipBagItem 只消费物理槽；RU gearswap/fast-swap 真实装备实现使用 bagId=1 的 inventory 视图，GearV3 以其
-- 为事务权威。仅视图 1 全不可读或为空时有界兜底 bagId=0；两逻辑视图可合法不同，不能比较后因任何分歧硬阻断。
function G:BuildBagSnapshot()
    local preferredId = tonumber(self.PreferredBagId) or 1
    local preferred = self:BuildBagView(preferredId)
    if #(preferred.items or {}) > 0 then
        preferred.fallbackUsed = false
        return preferred
    end

    local fallbackId = preferredId == 1 and 0 or 1
    local fallback = self:BuildBagView(fallbackId)
    if #(fallback.items or {}) > 0 then
        fallback.fallbackUsed = true
        fallback.preferredErrors = preferred.errors or 0
        fallback.preferredFirstError = preferred.firstError
        return fallback
    end

    if (tonumber(fallback.errors) or 0) < (tonumber(preferred.errors) or 0) then
        fallback.fallbackUsed = true
        return fallback
    end
    preferred.fallbackUsed = false
    return preferred
end

function G:CandidateMatches(saved, candidate)
    if type(saved) ~= "table" or type(candidate) ~= "table" then return false, 0 end
    local wantedName, gotName = self:NormalizeItemName(saved.name), candidate.normalizedName
    if wantedName == "" or gotName == "" or wantedName ~= gotName then return false, 0 end
    -- 同名不同ID不能用“低分候选”降级选中；该项跳过，不影响其它已确认项目。
    if saved.itemType ~= nil and candidate.itemType ~= nil and tostring(saved.itemType) ~= tostring(candidate.itemType) then return false, 0 end
    local wantedGrade, gotGrade = tonumber(saved.grade), tonumber(candidate.grade)
    if wantedGrade ~= nil and gotGrade ~= nil and wantedGrade ~= gotGrade then return false, 0 end
    if self:RequiresRingIdentity(saved) then
        if self:SavedRingIdentityError(saved)~=nil then return false,0 end
        candidate.ringIdentity=candidate.ringIdentity or self:ExtractRingIdentity(candidate.ringSource)
        if candidate.ringIdentity.status~='known' then return false,0,'ring_identity_unknown' end
        return saved.itemType~=nil and candidate.itemType~=nil and tostring(saved.itemType)==tostring(candidate.itemType)
            and wantedGrade~=nil and wantedGrade==gotGrade and candidate.ringIdentity.status=='known'
            and candidate.ringIdentity.signature==saved.ringIdentity.signature,185
    end
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
    if self:RequiresRingIdentity(saved) then
        local reason,code=self:SavedRingIdentityError(saved);if reason then return nil,reason,code end
    end
    local topScore, top, unknownRing = nil, {}, false
    for _, candidate in ipairs(type(snapshot) == "table" and snapshot.items or {}) do
        if reserved[tonumber(candidate.slot)] ~= true then
            local matched, score, identityError = self:CandidateMatches(saved, candidate)
            -- 只记录本次目标的同名候选错误，不能让另一个戒指留下的缓存污染共享快照。
            if identityError=='ring_identity_unknown' then unknownRing=true end
            if matched then
                if topScore == nil or score > topScore then topScore, top = score, { candidate }
                elseif score == topScore then top[#top + 1] = candidate end
            end
        end
    end
    if unknownRing then return nil,'同名戒指候选词条不可读，无法安全区分','ring_identity_unknown' end
    if #top == 0 then
        if type(snapshot) == "table" and (tonumber(snapshot.errors) or 0) > 0 then return nil, "读取背包时发生错误", "read_error" end
        return nil, "背包中未找到目标装备", "not_found"
    end
    if #top == 1 then return top[1], nil, nil end
    if self:RequiresRingIdentity(saved) then return nil,'存在多枚词条完全相同的戒指，无法唯一判断','ring_ambiguous' end
    local fingerprint = self:CandidateFingerprint(top[1])
    for index = 2, #top do
        if self:CandidateFingerprint(top[index]) ~= fingerprint then return nil, "存在多个不同候选，无法安全判断", "ambiguous" end
    end
    -- 已保存指纹完全一致的副本可互换；确定性选择并预留最小物理槽。
    table.sort(top, function(a, b) return tonumber(a.slot) < tonumber(b.slot) end)
    return top[1], nil, nil
end

function G:BuildSession(setId, payload, mismatchRows, options)
    options = type(options) == "table" and options or {}
    local uniqueConflict=self:HasSingleWearRingConflict(payload)
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
            if uniqueConflict and self:IsRingSlot(saved.slot) and self:IsSingleWearRing(saved.itemType) then mismatch=true end
            if mismatch and (options.weaponOnly ~= true or self:IsWeaponSlot(saved.slot)) then
                pendingSaved[#pendingSaved + 1] = saved
            end
        end
    end

    -- 仅称号套装或装备已正确的套装，不能因称号仍需改变就扫描 300 背包槽。
    if #pendingSaved == 0 then
        return {
            setId = tostring(setId), payload = payload, queue = {}, blocked = {}, reserved = {},
            startedAt = S.NowMs and S.NowMs() or 0,
            titlePending = options.weaponOnly ~= true and type(payload.title) == "table" and payload.title.apply == true,
            weaponOnly = options.weaponOnly == true,
        }
    end

    local snapshot = self:BuildBagSnapshot()
    local queue, reserved, blocked = {}, {}, {}
    for _, saved in ipairs(pendingSaved) do
        local candidate, reason, reasonCode
        if uniqueConflict and self:IsRingSlot(saved.slot) and self:IsSingleWearRing(saved.itemType) then
            reason,reasonCode='充盈的拉玛哈的戒指只能佩戴一枚，请重新获取当前并保存方案','ring_unique_conflict'
        else candidate,reason,reasonCode=self:FindCandidate(saved,snapshot,reserved) end
        -- 目标副手可能正装在主手；只有主手已有可执行替换步骤，且当前主手身份可验证时，
        -- 才延后解析副手。它仍只能从动作前真实背包快照装备，不能直接操作装备槽，也不能把普通缺失/歧义放宽为重试。
        local deferred = false
        if candidate == nil and reasonCode == "not_found" and tonumber(saved.slot) == 17 then
            local mainStep
            for _, planned in ipairs(queue) do if tonumber(planned.saved.slot) == 16 then mainStep = planned; break end end
            local currentMain, readErr = self:GetLoadoutEquipped(16)
            deferred = mainStep ~= nil and readErr == nil and self:SavedItemMatchesTooltip(saved, currentMain)
        end
        if deferred then
            queue[#queue + 1] = { saved=saved, alternative=true, deferredCandidate=true, attempts=0, verifyPolls=0 }
        elseif candidate == nil then blocked[#blocked + 1] = { slot = saved.slot, slotName = saved.slotName, name = saved.name, reason = reason, code = reasonCode }
        else
            reserved[tonumber(candidate.slot)] = true
            queue[#queue + 1] = { saved = saved, bagSlot = candidate.slot, bagId = snapshot.bagId,
                candidateFingerprint = self:CandidateFingerprint(candidate), candidateItemType = candidate.itemType,
                alternative = saved.alternative == true, attempts = 0, verifyPolls = 0 }
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
        titlePending = options.weaponOnly ~= true and type(payload.title) == "table" and payload.title.apply == true,
        weaponOnly = options.weaponOnly == true,
        bagFallbackUsed = snapshot.fallbackUsed == true,
    }
end

function G:RefreshStepCandidate(step, session)
    if type(session.performance) == "table" then session.performance.rescans = session.performance.rescans + 1 end
    local snapshot = self:BuildBagSnapshot()
    local candidate, reason, reasonCode = self:FindCandidate(step.saved, snapshot, {})
    if candidate == nil then return false, reason, reasonCode end
    step.bagSlot, step.bagId = candidate.slot, snapshot.bagId
    step.candidateFingerprint, step.candidateItemType = self:CandidateFingerprint(candidate), candidate.itemType
    return true
end

function G:ValidateStepCandidate(step, session)
    -- 前项真实回读成功后再解析延后副手；重新扫描失败仍走原跳过反馈，不向 nil/旧物理槽发起写入。
    if step.deferredCandidate == true then
        local ok, reason, code = self:RefreshStepCandidate(step, session)
        if ok == true then step.deferredCandidate = nil end
        return ok, reason, code
    end
    -- 前项可能改变背包物理槽；动作前先读候选单槽，指纹变动才重新有限扫描。
    -- 缺失、歧义或读错仍留证后跳过，不能对旧槽盲目 Equip。
    local info = self:GetBagItem(step.bagId, step.bagSlot)
    local candidate = self:BuildBagCandidate(step.bagId, step.bagSlot, info)
    if candidate ~= nil and self:CandidateMatches(step.saved, candidate)
        and self:CandidateFingerprint(candidate) == step.candidateFingerprint
        and tostring(candidate.itemType or "") == tostring(step.candidateItemType or "") then return true end
    return self:RefreshStepCandidate(step, session)
end

function G:AddSkippedStep(session, saved, reason, reasonCode)
    if type(session) ~= "table" or type(saved) ~= "table" then return false end
    session.blocked = type(session.blocked) == "table" and session.blocked or {}
    local slot = tonumber(saved.slot)
    for _, row in ipairs(session.blocked) do
        if tonumber(row and row.slot) == slot then return true end
    end
    session.blocked[#session.blocked + 1] = {
        slot = slot, slotName = saved.slotName, name = saved.name,
        reason = tostring(reason or "背包中未找到目标装备"), code = tostring(reasonCode or "not_found"),
    }
    return true
end

function G:BlockedSlotSet(session)
    local result = {}
    for _, row in ipairs(type(session) == "table" and session.blocked or {}) do
        local slot = tonumber(row and row.slot)
        if slot ~= nil then result[slot] = true end
    end
    return result
end

function G:ValidateReachableSession(session)
    if type(session) ~= "table" or type(session.payload) ~= "table" then return false, { { slotName = "方案", kind = "invalid_session" } } end
    local blocked, mismatches = self:BlockedSlotSet(session), {}
    for _, saved in ipairs(session.payload.items or {}) do
        local slot = tonumber(saved and saved.slot)
        if saved.managed ~= false and saved.empty ~= true and blocked[slot] ~= true
            and (session.weaponOnly ~= true or self:IsWeaponSlot(slot)) and not self:CurrentItemMatches(saved) then
            mismatches[#mismatches + 1] = { slot = slot, slotName = saved.slotName, name = saved.name, kind = "装备" }
        end
    end
    if session.weaponOnly ~= true and type(session.payload.title) == "table" and session.payload.title.apply == true then
        local titleMatched, titleReason = self:CurrentTitleMatches(session.payload)
        if titleMatched ~= true then mismatches[#mismatches + 1] = { slotName = "称号", name = self:TitleText(session.payload.title), kind = tostring(titleReason or "未匹配") } end
    end
    return #mismatches == 0, mismatches
end

function G:PartialSummary(session, prefix)
    local blocked = type(session) == "table" and session.blocked or {}
    if #blocked <= 0 then return tostring(prefix or "换装完成") end
    local first = blocked[1]
    return tostring(prefix or "换装部分完成") .. "；跳过 " .. tostring(#blocked) .. " 项无法完成的装备"
        .. (first and ("（首项：" .. tostring(first.slotName or first.name or "装备") .. "：" .. tostring(first.reason or first.code or "无法识别") .. "）") or "")
end

function G:SkipRuntimeStep(session, step, reason, reasonCode)
    -- 仅隔离当前项目；不重启队列、不取消其它装备/称号，不把错误伪装成成功。
    self:AddSkippedStep(session, step.saved, reason, reasonCode)
    self.runtime.index = self.runtime.index + 1
    self.runtime.stage = "ACTION"
    self.runtime.message = self:PartialSummary(session, "继续换装")
    Publish("step_failed_skipped")
    return true
end

function G:StopRuntime(reason)
    if S.Scheduler ~= nil then S.Scheduler:RemoveTask(self.taskName) end
    local r = self.runtime
    if r.session and type(r.session.performance) == "table" then
        r.session.performance.elapsedMs = math.max(0, (S.NowMs and S.NowMs() or 0) - r.session.performance.startedAt)
        r.lastPerformance = DeepCopy(r.session.performance)
    end
    r.skipped = DeepCopy(r.session and r.session.blocked or r.skipped or {})
    r.outcome = "stopped"
    r.busy, r.session, r.stage, r.index = false, nil, "IDLE", 0
    if reason ~= nil then r.message = tostring(reason) end
    Publish("runtime_stopped")
end

function G:FinishRuntime(ok, message)
    local session = self.runtime.session
    if session and type(session.performance) == "table" then
        session.performance.elapsedMs = math.max(0, (S.NowMs and S.NowMs() or 0) - session.performance.startedAt)
        self.runtime.lastPerformance = DeepCopy(session.performance)
    end
    if S.Scheduler ~= nil then S.Scheduler:RemoveTask(self.taskName) end
    self.runtime.busy = false
    self.runtime.skipped = DeepCopy(session and session.blocked or {})
    self.runtime.outcome = not ok and "failed"
        or ((#self.runtime.skipped > 0 or self.runtime.pendingSetId ~= nil) and "partial" or "complete")
    self.runtime.stage = ok and "DONE" or "FAILED"
    self.runtime.message = tostring(message or (ok and "换装完成" or "换装失败"))
    self.runtime.lastSetId = session and session.setId or self.runtime.lastSetId
    self.runtime.session = nil
    Publish("runtime_finished")

    -- 只发布完成事件，由 Feature 响应；Service 不向上调用具体 Feature。
    return ok
end

function G:RuntimeTick()
    local r, session = self.runtime, self.runtime.session
    if r.busy ~= true or type(session) ~= "table" then self:StopRuntime(); return true end
    if type(session.performance) == "table" then session.performance.ticks = session.performance.ticks + 1 end
    local inCombat, combatErr = self:IsInCombat()
    -- 全局安全门保持强制停止，不能把“无法确认战斗状态”当成某一件识别失败而继续写装备。
    if combatErr ~= nil then return self:FinishRuntime(false, "无法确认战斗状态，换装已停止：" .. tostring(combatErr)) end
    if inCombat == true and session.weaponOnly ~= true then
        r.pendingSetId = session.setId
        return self:FinishRuntime(true, "战斗开始，剩余防具/饰品/称号已暂停；脱战后可再次执行")
    end
    if (S.NowMs and S.NowMs() or 0) - (session.startedAt or 0) > 60000 then return self:FinishRuntime(false, "换装总超时，已停止") end

    local step = session.queue[r.index]
    -- 回读确认后可同拍检查下一项；循环只消费已匹配项，动作分支立即返回，每拍仍最多一次 Native 写。
    while step ~= nil do
        local itemMatched, equippedErr, ringErrorCode = self:CurrentItemMatches(step.saved)
        -- Native 回读可能同步触发取消/停用；旧会话不能继续下一项。
        if r.busy ~= true or r.session ~= session then return true end
        if equippedErr ~= nil then return self:SkipRuntimeStep(session, step, equippedErr, ringErrorCode or "equipped_read_error") end
        if itemMatched ~= true then break end
        r.index = r.index + 1
        r.stage = "ACTION"
        step = session.queue[r.index]
    end
    if step == nil then
        if session.weaponOnly == true then
            local reachableMatched, reachableMismatches = self:ValidateReachableSession(session)
            if reachableMatched ~= true then
                return self:FinishRuntime(false, "战斗换装失败：可执行武器中仍有 " .. tostring(#reachableMismatches) .. " 件未达到目标状态")
            end
            local allMatched = self:ValidatePayload(session.payload)
            if allMatched == true then
                return self:FinishRuntime(true, "战斗中武器切换完成，当前方案已完全匹配")
            end
            r.pendingSetId = session.setId
            if #(session.blocked or {}) > 0 then
                return self:FinishRuntime(true, self:PartialSummary(session, "战斗中可用武器已切换") .. "；其余防具/饰品/称号仍按战斗规则延后")
            end
            return self:FinishRuntime(true, "战斗中武器切换完成；防具/饰品/称号未处理，脱战后再次执行可补齐")
        end
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
        local reachableMatched, reachableMismatches = self:ValidateReachableSession(session)
        if reachableMatched ~= true then return self:FinishRuntime(false, "可执行项目中仍有 " .. tostring(#reachableMismatches) .. " 项未达到目标状态") end
        if #(session.blocked or {}) > 0 then return self:FinishRuntime(true, self:PartialSummary(session, "换装部分完成")) end
        return self:FinishRuntime(true, "换装 / 称号完成")
    end

    if r.stage == "VERIFY" then
        if type(session.performance) == "table" then session.performance.verificationWaits = session.performance.verificationWaits + 1 end
        step.verifyPolls = (step.verifyPolls or 0) + 1
        if step.verifyPolls <= 7 then return true end
        if step.attempts >= 3 then
            return self:SkipRuntimeStep(session, step, "连续多次未生效（已达到3次动作上限）", "verify_failed")
        end
        local found, reason, reasonCode = self:RefreshStepCandidate(step, session)
        if found ~= true then return self:SkipRuntimeStep(session, step, reason, reasonCode) end
        r.stage = "ACTION"; step.verifyPolls = 0; return true
    end

    r.stage = "ACTION"
    local candidateOk, candidateErr, candidateCode = self:ValidateStepCandidate(step, session)
    if r.busy ~= true or r.session ~= session then return true end
    if candidateOk ~= true then return self:SkipRuntimeStep(session, step, candidateErr, candidateCode) end
    step.attempts = (step.attempts or 0) + 1
    if type(session.performance) == "table" then session.performance.actionAttempts = session.performance.actionAttempts + 1 end
    local ok, value, err = S.Api:CallCapability("X2Bag:EquipBagItem", X2Bag, "EquipBagItem", step.bagSlot, step.alternative == true)
    if ok ~= true then return self:SkipRuntimeStep(session, step, tostring(err or "换装调用失败"), "action_error") end
    if value == false then return self:SkipRuntimeStep(session, step, "EquipBagItem rejected", "action_rejected") end
    r.stage = "VERIFY"; step.verifyPolls = 0
    Publish("step_action")
    return true
end

function G:Start(setId, payload)
    if self.enabled ~= true then return false, "换装功能未启用" end
    if self.runtime.busy == true then return false, "已有换装任务正在执行" end
    local inCombat, combatErr = self:IsInCombat()
    if combatErr ~= nil then return false, "无法确认战斗状态：" .. tostring(combatErr) end
    self.runtime.skipped, self.runtime.outcome = {}, "not_applied"
    self.runtime.lastPerformance = nil
    self.runtime.pendingSetId = nil
    local matched, mismatches = self:ValidatePayload(payload)
    if matched == true then self.runtime.outcome = "complete"; self.runtime.message = "当前已经是目标方案"; Publish("already_matched"); return true end

    -- RU实机历史已经确认：战斗中防具/饰品通常会被客户端拒绝，
    -- 但主手/副手/远程/乐器仍允许换装。不要用一个全局战斗门把
    -- 可用的武器路径一起阻断；战斗模式只构建武器 mismatch 队列。
    local weaponOnly = inCombat == true
    local session = self:BuildSession(setId, payload, mismatches, { weaponOnly = weaponOnly })
    session.performance = { startedAt = session.startedAt, intervalMs = 220,
        ticks = 0, actionAttempts = 0, rescans = 0, verificationWaits = 0 }
    if session.preflightError ~= nil then return false, tostring(session.preflightError) end
    if weaponOnly == true and #session.queue == 0 and #session.blocked == 0 then
        self.runtime.pendingSetId = tostring(setId)
        self.runtime.message = "当前方案只有防具/饰品/称号需要切换；战斗中已安全跳过，脱战后再次执行"
        Publish("combat_non_weapon_deferred")
        return true
    end
    -- 预检只生成明确定位的动作；not_found/read_error/ambiguous 留证后跳过，不阻断其它项目。
    self.runtime.skipped = DeepCopy(session.blocked or {})
    if #session.queue == 0 and session.titlePending ~= true then
        local first = session.blocked[1]
        self.runtime.message = first and ("有 " .. tostring(#session.blocked) .. " 件目标装备无法安全定位；无其它可执行项目") or "没有需要执行的换装项目"
        Publish("nothing_reachable")
        return false, self.runtime.message
    end
    self.runtime.busy, self.runtime.session, self.runtime.stage, self.runtime.index = true, session, "ACTION", 1
    self.runtime.outcome = "running"
    self.runtime.pendingSetId = nil
    self.runtime.message = weaponOnly and ("战斗中正在优先切换“" .. tostring(setId) .. "”的武器") or ("正在切换“" .. tostring(setId) .. "”")
    if #session.blocked > 0 then self.runtime.message = self.runtime.message .. "；" .. tostring(#session.blocked) .. " 件无法识别将跳过" end
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
        patch = self.continuationPatch, outcome = tostring(r.outcome or "idle"),
        skippedCount = #(session and session.blocked or r.skipped or {}),
        skipped = DeepCopy(session and session.blocked or r.skipped or {}),
        performance = DeepCopy(session and session.performance or r.lastPerformance),
    }
end

-- 完整自检自动采集公共 Service 健康快照；这里只复制会话证据，不读取
-- 背包/装备、不创建任务，避免诊断自身扰动性能测量。
function G:GetHealth() return self:GetRuntimeSnapshot() end
