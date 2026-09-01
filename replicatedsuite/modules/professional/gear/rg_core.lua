ReplicatedSuiteModuleSandbox:Enter('gear', {'ReplicatedGear', 'ReplicatedGearConfig'})
------------------------------------------------------------------------
-- Replicated Gear - Loadout data / capture / matching core
------------------------------------------------------------------------

if ReplicatedGear == nil or ReplicatedGear.BootError ~= nil or ReplicatedGear.Api == nil then return end
local G = ReplicatedGear
local A = G.Api

G.Core = {}
local C = G.Core

C.Schema = 9
C.SetPayloadSchema = 2
C.writeFenceReason = nil
C.writeFenceWarned = false
C.BackupKey = G.SaveKey .. "_backup"
C.SetPayloadPrefix = G.SaveKey .. "_payload_"
C.MaxSets = 40
C.BagSlots = 150

-- Equipment payload writes are deliberately stronger than ordinary Gear metadata
-- persistence.  A logout/UI reload may legitimately flush positions, names or
-- module settings, but it must never reinterpret the character's currently worn
-- gear as the selected loadout.  Only explicit user-facing save actions may cross
-- this fence.
C.PayloadCommitReasons = {
    suite_save_current_edit = true,
    suite_save_slots = true,
    suite_save_quick_title = true,
    standalone_save = true,
}

C.EquipmentSlots = {
    { slot = 1,  key = "head",       name = "头盔",   alternative = false },
    { slot = 3,  key = "chest",      name = "胸甲",   alternative = false },
    { slot = 4,  key = "waist",      name = "腰带",   alternative = false },
    { slot = 8,  key = "wrists",     name = "护腕",   alternative = false },
    { slot = 6,  key = "hands",      name = "手套",   alternative = false },
    { slot = 9,  key = "cloak",      name = "披风",   alternative = false },
    { slot = 5,  key = "legs",       name = "腿甲",   alternative = false },
    { slot = 7,  key = "feet",       name = "鞋子",   alternative = false },
    { slot = 15, key = "underwear",  name = "内衣",   alternative = false },
    { slot = 2,  key = "necklace",   name = "项链",   alternative = false },
    { slot = 10, key = "earring1",   name = "耳环1",  alternative = false },
    { slot = 11, key = "earring2",   name = "耳环2",  alternative = true  },
    { slot = 12, key = "ring1",      name = "戒指1",  alternative = false },
    { slot = 13, key = "ring2",      name = "戒指2",  alternative = true  },
    { slot = 16, key = "mainhand",   name = "主手",   alternative = false },
    { slot = 17, key = "offhand",    name = "副手",   alternative = true  },
    { slot = 18, key = "ranged",     name = "远程",   alternative = false },
    { slot = 19, key = "instrument", name = "乐器",   alternative = false },
    { slot = 28, key = "costume",    name = "时装",   alternative = false },
}

-- Weapon-slot classification is used for ordering and reconciliation. Current RU
-- Addon EquipBagItem calls are blocked in combat, so Runtime defers every mismatch
-- until combat ends; manual backpack/shortcut weapon switching is a separate path.
C.WeaponSlots = {
    [16] = true, -- main hand
    [17] = true, -- off hand / shield
    [18] = true, -- ranged
    [19] = true, -- instrument
}

-- Weapon phase order: main hand -> off hand/shield -> ranged -> instrument.
-- Keep the weapon order aligned with the current public GearSwap loadout order:
-- main hand -> off hand -> ranged -> instrument.  This is important when moving
-- from a two-handed weapon to a main-hand/off-hand pair: equipping the main hand
-- first releases the off-hand constraint before the shield/off-hand action runs.
C.WeaponPriority = {
    [16] = 10, -- main hand first
    [17] = 20, -- off hand / shield second
    [18] = 30,
    [19] = 40,
}

function C:IsWeaponSlot(slot)
    return self.WeaponSlots[tonumber(slot)] == true
end

function C:GetWeaponPriority(slot)
    return self.WeaponPriority[tonumber(slot)] or 999
end

function C:IsManagedItem(item)
    return type(item) == "table" and item.managed ~= false and item.empty ~= true
end

function C:NormalizeManagedItem(item)
    if type(item) ~= "table" then return item end
    -- rc1-rc12 had no per-slot participation flag: every non-empty captured slot
    -- was part of the loadout. Preserve that behavior during migration. Empty
    -- slots remain unmanaged because the public API cannot reliably unequip them.
    if item.empty == true then
        item.managed = false
    elseif item.managed == nil then
        item.managed = true
    else
        item.managed = item.managed == true
    end
    return item
end

function C:CountManagedItems(set)
    local count = 0
    for _, item in ipairs(type(set) == "table" and set.items or {}) do
        if self:IsManagedItem(item) then count = count + 1 end
    end
    return count
end

-- Pure preset application over a draft. Modes: ALL / WEAPON / ARMOR / NONE / TITLE.
-- ALL/WEAPON/NONE semantics are byte-identical to the legacy UI loop; ARMOR
-- selects every non-weapon non-empty item; TITLE deselects all items and enables
-- title participation only when a captured title exists (draft.title.effect.id).
-- Except for TITLE's explicit title.apply write, no mode touches draft.title.
-- Returns changed, titleMissing (titleMissing is true only for TITLE without a
-- usable captured title; the UI shows a status hint, never an error box).
function C:ApplyManagedPreset(draft, mode)
    if type(draft) ~= "table" then return false, false end
    local changed = false
    local titleMissing = false
    if type(draft.items) == "table" then
        for _, item in ipairs(draft.items) do
            if type(item) == "table" then
                local desired = false
                if item.empty ~= true then
                    if mode == "ALL" then
                        desired = true
                    elseif mode == "WEAPON" then
                        desired = self:IsWeaponSlot(item.slot)
                    elseif mode == "ARMOR" then
                        desired = not self:IsWeaponSlot(item.slot)
                    elseif mode == "NONE" then
                        desired = false
                    end
                    -- TITLE: every item stays deselected (desired == false).
                end
                if item.managed ~= desired then
                    item.managed = desired
                    changed = true
                end
            end
        end
    end
    if mode == "TITLE" then
        local title = type(draft.title) == "table" and draft.title or nil
        local hasEffect = title ~= nil and type(title.effect) == "table" and title.effect.id ~= nil
        if hasEffect then
            if title.apply ~= true then
                title.apply = true
                changed = true
            end
        else
            titleMissing = true
        end
    end
    return changed, titleMissing
end

function C:GetDefaultQuickButtonPosition(index)
    local base = self:GetUiState("quick") or { x = 12, y = 150 }
    local n = math.max(1, math.floor(tonumber(index) or 1)) - 1
    return (tonumber(base.x) or 12) + (n % 4) * 108,
        (tonumber(base.y) or 150) + math.floor(n / 4) * 30
end

function C:IsQuickButtonSnapEnabled()
    local quick = self:GetUiState("quick")
    return type(quick) ~= "table" or quick.snapEnabled ~= false
end

function C:SetQuickButtonSnapEnabled(enabled)
    local quick = self:GetUiState("quick")
    if type(quick) ~= "table" then return false, "quick ui state unavailable" end
    local old = quick.snapEnabled
    quick.snapEnabled = enabled == true
    local ok, err = self:Persist()
    if not ok then quick.snapEnabled = old; return false, err end
    return true
end

function C:GetQuickButtonPosition(set, index)
    if type(set) == "table" and set.quickPositionCustomized == true and
        tonumber(set.quickX) ~= nil and tonumber(set.quickY) ~= nil then
        return tonumber(set.quickX), tonumber(set.quickY), true
    end
    -- Untouched buttons intentionally have no persisted position.  rg_ui.lua
    -- chooses a screen-aware visible default, so the configuration window can
    -- never cover the button on first creation.
    return nil, nil, false
end

local function Trim(value)
    local s = tostring(value or "")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

local function Lower(value)
    return string.lower(Trim(value))
end

local function Primitive(value)
    local kind = type(value)
    if kind == "string" or kind == "number" or kind == "boolean" then return value end
    return nil
end

local function MeaningfulId(value)
    if value == nil or value == false then return nil end
    if type(value) == "number" and value == 0 then return nil end
    local text = tostring(value)
    if text == "" or text == "0" or text == "nil" or text == "false" then return nil end
    return value
end

local function RootRevision(root)
    if type(root) ~= "table" then return -1 end
    return math.max(0, math.floor(tonumber(root.revision) or 0))
end

local function RootQuality(root)
    if type(root) ~= "table" then return -1 end
    local score = 0
    if type(root.ui) == "table" then score = score + 1 end
    if type(root.characters) == "table" then
        score = score + 1
        for _, char in pairs(root.characters) do
            if type(char) == "table" and type(char.sets) == "table" then
                score = score + #char.sets
            end
        end
    end
    return score
end

function C:DeepCopy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] ~= nil then return seen[value] end
    local copy = {}
    seen[value] = copy
    for k, v in pairs(value) do
        if type(k) ~= "userdata" and type(v) ~= "userdata" and type(v) ~= "function" and type(v) ~= "thread" then
            copy[self:DeepCopy(k, seen)] = self:DeepCopy(v, seen)
        end
    end
    return copy
end

function C:NormalizeItemName(name)
    local value = Trim(name)
    value = value:gsub("^[%+%-]?%d+%s+", "")
    value = value:gsub("%s*%([^%)]*%)%s*$", "")
    return Lower(value)
end

function C:ExtractModifiers(item)
    local result = {}
    local modifiers = type(item) == "table"
        and type(item.evolvingInfo) == "table"
        and item.evolvingInfo.modifier or nil
    if type(modifiers) == "table" then
        for _, entry in ipairs(modifiers) do
            if type(entry) == "table" and entry.name ~= nil then
                local name = Trim(entry.name)
                local value = Primitive(entry.value)
                if name ~= "" then
                    result[#result + 1] = {
                        name = name,
                        value = value ~= nil and tostring(value) or "",
                    }
                end
            end
        end
    end
    table.sort(result, function(a, b)
        local ak = Lower(a.name) .. "=" .. tostring(a.value or "")
        local bk = Lower(b.name) .. "=" .. tostring(b.value or "")
        return ak < bk
    end)
    return result
end

function C:ModifierSignature(modifiers)
    local parts = {}
    for _, item in ipairs(type(modifiers) == "table" and modifiers or {}) do
        parts[#parts + 1] = Lower(item.name) .. "=" .. tostring(item.value or "")
    end
    return table.concat(parts, ";")
end

function C:ExtractBagType(info)
    if type(info) ~= "table" then return nil end
    local keys = { "itemType", "itemTypeId", "typeId", "item_type" }
    for _, key in ipairs(keys) do
        local value = MeaningfulId(Primitive(info[key]))
        if value ~= nil then return value end
    end
    return nil
end

function C:ExtractGrade(info)
    if type(info) ~= "table" then return nil end
    return tonumber(info.itemGrade or info.grade)
end

function C:PackAppellation(data)
    if type(data) ~= "table" then return nil end
    local packed = { values = {} }
    for index = 1, 6 do
        local value = Primitive(data[index])
        if value ~= nil then packed.values[index] = value end
    end
    packed.id = MeaningfulId(packed.values[1])
    for index = 2, 6 do
        local value = packed.values[index]
        if type(value) == "string" and Trim(value) ~= "" then
            packed.name = Trim(value)
            break
        end
    end
    return packed
end

function C:CaptureTitle()
    local showingRaw, showingErr = A:GetShowingAppellation()
    if showingErr ~= nil then
        return nil, "读取当前展示称号失败：" .. tostring(showingErr)
    end
    local effectRaw, effectErr = A:GetEffectAppellation()
    if effectErr ~= nil then
        return nil, "读取当前效果称号失败：" .. tostring(effectErr)
    end
    local showing = self:PackAppellation(showingRaw)
    local effect = self:PackAppellation(effectRaw)
    -- Combat Closet and the official ChangeAppellation contract treat the first
    -- argument as the *current* displayed name type, while the saved loadout
    -- contributes the desired effect/appellation type.  Therefore a saved
    -- effect id is sufficient to remember the loadout title; the showing id is
    -- retained only as a fallback/debug snapshot.
    local canApply = effect ~= nil and effect.id ~= nil
    local name = nil
    if effect and effect.name then name = effect.name end
    if (name == nil or name == "") and showing and showing.name then name = showing.name end
    return {
        apply = canApply,
        showing = showing,
        effect = effect,
        displayName = name,
    }, nil
end

function C:TitleText(title)
    if type(title) ~= "table" then return "未读取称号" end
    if title.displayName ~= nil and Trim(title.displayName) ~= "" then
        return tostring(title.displayName)
    end
    local showId = title.showing and title.showing.id or nil
    local effectId = title.effect and title.effect.id or nil
    if showId ~= nil or effectId ~= nil then
        return "展示ID " .. tostring(showId or "-") .. " / 效果ID " .. tostring(effectId or "-")
    end
    return "未检测到可保存称号"
end

function C:GetCharacterIdentity()
    local fullName = A:GetPlayerNameWithWorld()
    if type(fullName) == "string" and Trim(fullName) ~= "" then
        return Lower(fullName), false, Trim(fullName)
    end
    -- UnitName can become available a little earlier than UnitNameWithWorld.
    -- Do not bind/save per-character data under that short name: two worlds can
    -- legally contain the same short character name.  Keep it only for a clear
    -- "identity still loading" diagnostic until the full-name API is ready.
    local shortName = A:GetPlayerName()
    if type(shortName) == "string" and Trim(shortName) ~= "" then
        return nil, true, Trim(shortName)
    end
    return nil, true, nil
end

function C:GetCharacterKey()
    local key = self:GetCharacterIdentity()
    return key
end

function C:DefaultRoot()
    return {
        schema = self.Schema,
        revision = 0,
        nextStorageId = 1,
        ui = {
            launcher = { x = 300, y = 100 },
            quick = { x = 12, y = 150, visible = true, page = 1, snapEnabled = true },
            config = { x = 190, y = 105 },
        },
        characters = {},
    }
end

function C:NormalizeRoot(root)
    if type(root) ~= "table" then root = self:DefaultRoot() end
    local sourceSchema = math.max(0, math.floor(tonumber(root.schema) or 0))
    root.schema = self.Schema
    root.revision = math.max(0, math.floor(tonumber(root.revision) or 0))
    root.nextStorageId = math.max(1, math.floor(tonumber(root.nextStorageId) or 1))
    root.ui = type(root.ui) == "table" and root.ui or {}
    root.ui.launcher = type(root.ui.launcher) == "table" and root.ui.launcher or { x = 300, y = 100 }
    -- schema 9: all untouched Gear launchers now start from the same CryEngine-
    -- safe top-left discovery zone used by newly-created loadout buttons.  Keep
    -- arbitrary/player-dragged positions intact; only exact historical defaults
    -- are migrated.  This matters when a player switches from 1K/2K to 1024x768,
    -- where coordinates near the old large-resolution edge can be cropped away.
    if sourceSchema < 9 then
        local lx = tonumber(root.ui.launcher.x)
        local ly = tonumber(root.ui.launcher.y)
        local knownDefault = lx ~= nil and ly ~= nil and (
            (math.abs(lx - 72) < 0.01 and math.abs(ly - 200) < 0.01) or
            (math.abs(lx - 12) < 0.01 and (math.abs(ly - 118) < 0.01 or math.abs(ly - 182) < 0.01))
        )
        if knownDefault then
            root.ui.launcher.x = 300
            root.ui.launcher.y = 100
        end
    end
    root.ui.quick = type(root.ui.quick) == "table" and root.ui.quick or { x = 12, y = 150, visible = true, page = 1, snapEnabled = true }
    if root.ui.quick.snapEnabled == nil then root.ui.quick.snapEnabled = true else root.ui.quick.snapEnabled = root.ui.quick.snapEnabled == true end
    root.ui.config = type(root.ui.config) == "table" and root.ui.config or { x = 190, y = 105 }
    root.characters = type(root.characters) == "table" and root.characters or {}
    return root
end

function C:NormalizeCharacter(char)
    char = type(char) == "table" and char or { nextId = 1, sets = {} }
    char.nextId = math.max(1, math.floor(tonumber(char.nextId) or 1))
    char.sets = type(char.sets) == "table" and char.sets or {}
    for index, set in ipairs(char.sets) do
        set.id = tostring(set.id or ("set_" .. tostring(index)))
        set.name = Trim(set.name ~= nil and set.name or ("换装" .. tostring(index)))
        set.order = index
        set.storageId = tonumber(set.storageId) and math.max(1, math.floor(tonumber(set.storageId))) or nil
        set.payloadRevision = math.max(0, math.floor(tonumber(set.payloadRevision) or 0))
        if set.quick == nil then set.quick = true end
        set.quickX = tonumber(set.quickX)
        set.quickY = tonumber(set.quickY)
        -- rc9/rc10 assigned every new floating button the legacy shared-panel
        -- coordinates even before the user moved it.  Those coordinates are often
        -- directly underneath the configuration window.  Infer whether an old
        -- position was actually user-customized, then let UI choose a safe default
        -- for all untouched buttons.
        if set.quickPositionCustomized == nil then
            local oldX, oldY = self:GetDefaultQuickButtonPosition(set.storageId or index)
            local hasPosition = set.quickX ~= nil and set.quickY ~= nil
            set.quickPositionCustomized = hasPosition and
                (math.abs(set.quickX - oldX) > 2 or math.abs(set.quickY - oldY) > 2) or false
        else
            set.quickPositionCustomized = set.quickPositionCustomized == true
        end
        if set.quickPositionCustomized ~= true then
            set.quickX = nil
            set.quickY = nil
        end
        set.configured = set.configured == true
        set.items = type(set.items) == "table" and set.items or {}
        for _, item in ipairs(set.items) do
            if type(item) == "table" then
                if (item.modifierSignature == nil or item.modifierSignature == "") and type(item.modifiers) == "table" then
                    item.modifierSignature = self:ModifierSignature(item.modifiers)
                end
                -- rc1-rc3 persisted both the parsed modifier array and its
                -- canonical signature, plus a derived normalized name.  Only
                -- the signature/raw name are needed at runtime.  Drop the
                -- redundant fields on load so dozens of sets stay compact.
                item.modifiers = nil
                item.normalizedName = nil
                self:NormalizeManagedItem(item)
            end
        end
    end
    return char
end


function C:EnsureSetStorageId(set)
    if type(set) ~= "table" then return nil end
    local existing = tonumber(set.storageId)
    if existing ~= nil and existing >= 1 then
        set.storageId = math.floor(existing)
        return set.storageId
    end
    self.root.nextStorageId = math.max(1, math.floor(tonumber(self.root.nextStorageId) or 1))
    set.storageId = self.root.nextStorageId
    self.root.nextStorageId = self.root.nextStorageId + 1
    return set.storageId
end

function C:SetPayloadKey(set, backup)
    local storageId = self:EnsureSetStorageId(set)
    if storageId == nil then return nil end
    local key = self.SetPayloadPrefix .. tostring(storageId)
    if backup == true then key = key .. "_backup" end
    return key
end

function C:CompactRoot()
    local payload = self:DeepCopy(self.root)
    for _, char in pairs(type(payload.characters) == "table" and payload.characters or {}) do
        if type(char) == "table" and type(char.sets) == "table" then
            for _, set in ipairs(char.sets) do
                if type(set) == "table" then
                    -- Keep only lightweight index metadata in the root key.
                    -- Full 19-slot equipment/title payloads live in one SaveData
                    -- key per set, avoiding the undocumented aggregate table-size
                    -- ceiling seen by the RU client after only a few full sets.
                    set.items = nil
                    set.title = nil
                    set._payloadLoaded = nil
                    set._payloadError = nil
                    set._payloadWriteFence = nil
                end
            end
        end
    end
    return payload
end

function C:CheckWriteFence()
    if self.writeFenceReason == nil then return true end
    if self.writeFenceWarned ~= true then
        self.writeFenceWarned = true
        G.SafeChat("换装配置处于写保护，本次会话不会覆盖原保存：" .. tostring(self.writeFenceReason))
    end
    return false, "storage write protected: " .. tostring(self.writeFenceReason)
end

function C:SaveSetPayload(set)
    local writable, fenceErr = self:CheckWriteFence()
    if not writable then return false, fenceErr end
    if type(set) ~= "table" then return false, "set unavailable" end
    if set._payloadWriteFence ~= nil then
        return false, "payload write protected: " .. tostring(set._payloadWriteFence)
    end
    local primaryKey = self:SetPayloadKey(set, false)
    local backupKey = self:SetPayloadKey(set, true)
    if primaryKey == nil or backupKey == nil then return false, "storage key unavailable" end
    local previousRevision = math.max(0, math.floor(tonumber(set.payloadRevision) or 0))
    local revision = previousRevision + 1
    local payload = {
        schema = self.SetPayloadSchema,
        revision = revision,
        configured = set.configured == true,
        items = self:DeepCopy(set.items or {}),
        title = self:DeepCopy(set.title),
        capturedAt = set.capturedAt,
    }
    local backupOk, backupErr = self:ReplaceSavedTable(backupKey, payload)
    if not backupOk then return false, backupErr end
    local primaryOk, primaryErr = self:ReplaceSavedTable(primaryKey, payload)
    set.payloadRevision = revision
    set._payloadLoaded = true
    if not primaryOk then
        return true, "BACKUP_ONLY"
    end
    return true
end

function C:LoadSetPayload(set)
    if type(set) ~= "table" then return false, "set unavailable" end
    if set._payloadLoaded == true then return true end
    local primaryKey = self:SetPayloadKey(set, false)
    local backupKey = self:SetPayloadKey(set, true)
    local primary, primaryErr = A:LoadData(primaryKey)
    local backup, backupErr = A:LoadData(backupKey)
    local primarySchema = type(primary) == "table" and math.max(0, math.floor(tonumber(primary.schema) or 0)) or 0
    local backupSchema = type(backup) == "table" and math.max(0, math.floor(tonumber(backup.schema) or 0)) or 0
    local futurePayloadSchema = math.max(primarySchema, backupSchema)
    local loaded = nil
    if type(primary) == "table" and type(backup) == "table" then
        local pr, br = RootRevision(primary), RootRevision(backup)
        loaded = br > pr and backup or primary
    elseif type(primary) == "table" then
        loaded = primary
    elseif type(backup) == "table" then
        loaded = backup
    end
    if type(loaded) == "table" then
        if futurePayloadSchema > self.SetPayloadSchema then
            set._payloadWriteFence = "future_payload_schema:" .. tostring(futurePayloadSchema) .. ">" .. tostring(self.SetPayloadSchema)
        else
            set._payloadWriteFence = nil
        end
        -- LoadData may return a table whose lifetime is owned by the client.
        -- Never retain that table directly: all runtime/editor mutations must stay
        -- detached from the persistence object until an explicit commit occurs.
        set.items = type(loaded.items) == "table" and self:DeepCopy(loaded.items) or {}
        for _, item in ipairs(set.items) do self:NormalizeManagedItem(item) end
        set.title = self:DeepCopy(loaded.title)
        set.capturedAt = loaded.capturedAt
        set.configured = loaded.configured == true
        set.payloadRevision = RootRevision(loaded)
        set._payloadLoaded = true
        set._payloadError = nil
        return true
    end
    -- Legacy rc1-rc7 roots embedded the full payload directly. Preserve and
    -- migrate that data instead of treating it as missing.
    if (type(set.items) == "table" and #set.items > 0) or set.title ~= nil then
        local ok, err = self:SaveSetPayload(set)
        if ok then
            set._payloadLoaded = true
            return true
        end
        set._payloadError = err
        return false, err
    end
    if set.configured == true then
        local err = primaryErr or backupErr or "已保存方案的装备明细不可用"
        set._payloadError = err
        return false, err
    end
    set.items = type(set.items) == "table" and set.items or {}
    set._payloadLoaded = true
    return true
end

function C:EnsureSetPayloadLoaded(set)
    if type(set) ~= "table" then return false, "换装不存在" end
    return self:LoadSetPayload(set)
end

function C:EnsureCharacter()
    local key, provisional, shortName = self:GetCharacterIdentity()
    if key == nil then
        self.characterKey = nil
        self.character = nil
        self.characterIdentityPending = provisional == true
        self.characterShortName = shortName
        if shortName ~= nil then
            return false, "角色世界信息尚未就绪（" .. tostring(shortName) .. "）"
        end
        return false, "角色信息尚未就绪"
    end
    self.characterIdentityPending = false
    self.characterShortName = nil
    if self.characterKey == key and type(self.character) == "table" then return true end

    local char = self.root.characters[key]
    if type(char) ~= "table" then
        -- rc1 could save under __default__ when the addon loaded before player
        -- identity was ready. Migrate that one legacy bucket only when the real
        -- character has no existing data, avoiding silent cross-character merges.
        local legacy = self.root.characters["__default__"]
        if type(legacy) == "table" and type(legacy.sets) == "table" and #legacy.sets > 0 then
            char = legacy
            self.root.characters["__default__"] = nil
            self.root.characters[key] = char
        else
            char = { nextId = 1, sets = {} }
            self.root.characters[key] = char
        end
    end
    self.characterKey = key
    self.character = self:NormalizeCharacter(char)

    local metadataDirty = false
    for _, set in ipairs(self.character.sets or {}) do
        if set.storageId == nil then
            self:EnsureSetStorageId(set)
            metadataDirty = true
        end
        local hadEmbeddedPayload = (type(set.items) == "table" and #set.items > 0) or set.title ~= nil
        if set.configured == true then
            if hadEmbeddedPayload and (tonumber(set.payloadRevision) or 0) <= 0 then
                local payloadOk, payloadErr = self:SaveSetPayload(set)
                if not payloadOk then
                    set._payloadError = payloadErr
                    G.SafeChat("迁移换装“" .. tostring(set.name or set.id) .. "”明细失败：" .. tostring(payloadErr or "unknown"))
                else
                    metadataDirty = true
                end
            else
                local payloadOk, payloadErr = self:LoadSetPayload(set)
                if not payloadOk then set._payloadError = payloadErr end
            end
        else
            set.items = type(set.items) == "table" and set.items or {}
            set._payloadLoaded = true
        end
    end
    if metadataDirty == true then
        local persistOk, persistErr = self:Persist()
        if not persistOk then
            G.SafeChat("换装索引迁移保存失败：" .. tostring(persistErr or "unknown"))
        end
    end
    return true
end

function C:RequireCharacter()
    local ok, err = self:EnsureCharacter()
    if not ok then return false, err end
    return true
end

function C:Initialize()
    self.writeFenceReason = nil
    self.writeFenceWarned = false
    local primary, primaryErr = A:LoadData(G.SaveKey)
    local backup, backupErr = A:LoadData(self.BackupKey)
    local loaded = nil
    if type(primary) == "table" and type(backup) == "table" then
        local primaryRevision, backupRevision = RootRevision(primary), RootRevision(backup)
        if backupRevision > primaryRevision then
            loaded = backup
        elseif primaryRevision > backupRevision then
            loaded = primary
        else
            -- Normal successful saves produce identical same-revision copies.
            -- If one copy was partially damaged, prefer the structurally richer
            -- one rather than blindly taking primary.
            loaded = RootQuality(backup) > RootQuality(primary) and backup or primary
        end
    elseif type(primary) == "table" then
        loaded = primary
    elseif type(backup) == "table" then
        loaded = backup
        G.SafeChat("主配置不可用，已从备份配置恢复。")
    end
    local primarySchema = type(primary) == "table" and math.max(0, math.floor(tonumber(primary.schema) or 0)) or 0
    local backupSchema = type(backup) == "table" and math.max(0, math.floor(tonumber(backup.schema) or 0)) or 0
    local futureSchema = math.max(primarySchema, backupSchema)
    if futureSchema > self.Schema then
        self.writeFenceReason = "future_root_schema:" .. tostring(futureSchema) .. ">" .. tostring(self.Schema)
        G.SafeChat("检测到更高版本换装配置，已读取已知字段但不会覆盖原保存。")
        self.writeFenceWarned = true
    elseif loaded == nil and (primaryErr ~= nil or backupErr ~= nil) then
        self.writeFenceReason = "load_failed"
        G.SafeChat("读取保存配置时发生错误，将使用当前内存默认配置；原保存已进入写保护。")
        self.writeFenceWarned = true
    end
    -- Treat persisted data as an immutable snapshot.  This prevents any client
    -- implementation that keeps LoadData tables live until logout from observing
    -- later in-memory normalization/editor changes as implicit persistence.
    self.root = self:NormalizeRoot(self:DeepCopy(loaded))
    self:EnsureCharacter()
    return true
end

function C:ReplaceSavedTable(key, payload)
    local writable, fenceErr = self:CheckWriteFence()
    if not writable then return false, fenceErr end
    local cleared, clearErr = A:ClearData(key)
    if not cleared then
        -- Some ArcheRage builds report false when the key was already empty.
        -- Verify observable state before treating that as a real failure.
        local remaining, loadErr = A:LoadData(key)
        if loadErr ~= nil or (remaining ~= nil and remaining ~= false) then
            return false, clearErr or loadErr or "ClearData failed"
        end
    end
    local saved, saveErr = A:SaveData(key, payload)
    if not saved then return false, saveErr end
    return true
end

function C:Persist()
    local writable, fenceErr = self:CheckWriteFence()
    if not writable then return false, fenceErr end
    if type(self.root) ~= "table" then return false, "root unavailable" end
    self.root.schema = self.Schema
    local previousRevision = math.max(0, math.floor(tonumber(self.root.revision) or 0))
    self.root.revision = previousRevision + 1
    local payload = self:CompactRoot()

    -- Public ArcheRage examples clear a key before replacing its table. Keep a
    -- same-revision backup first so a client interruption between clear/save
    -- cannot permanently erase all user loadouts.
    local backupOk, backupErr = self:ReplaceSavedTable(self.BackupKey, payload)
    if not backupOk then
        self.root.revision = previousRevision
        G.SafeChat("保存备份配置失败：" .. tostring(backupErr or "unknown"))
        return false, backupErr
    end
    local primaryOk, primaryErr = self:ReplaceSavedTable(G.SaveKey, payload)
    if not primaryOk then
        self.persistenceDegraded = true
        G.SafeChat("主配置槽写入失败；最新配置已安全保留在备份槽，下次启动会自动恢复：" .. tostring(primaryErr or "unknown"))
        return true, "BACKUP_ONLY"
    end
    self.persistenceDegraded = false
    return true
end

function C:GetUiState(name)
    return self.root and self.root.ui and self.root.ui[name] or nil
end

function C:GetSets(includeUnconfigured)
    if not self:EnsureCharacter() then return {} end
    local list = {}
    for _, set in ipairs(self.character and self.character.sets or {}) do
        if includeUnconfigured == true or set.configured == true then
            list[#list + 1] = set
        end
    end
    table.sort(list, function(a, b)
        local ao, bo = tonumber(a.order) or 0, tonumber(b.order) or 0
        if ao ~= bo then return ao < bo end
        return tostring(a.id) < tostring(b.id)
    end)
    return list
end

function C:GetQuickSets()
    local result = {}
    for _, set in ipairs(self:GetSets(false)) do
        if set.quick ~= false then result[#result + 1] = set end
    end
    return result
end

function C:FindSet(id)
    if not self:EnsureCharacter() then return nil end
    local wanted = tostring(id or "")
    for _, set in ipairs(self.character and self.character.sets or {}) do
        if tostring(set.id) == wanted then return set end
    end
    return nil
end

function C:GetSetCopy(id)
    local set = self:FindSet(id)
    if set == nil then return nil end
    local ok = self:EnsureSetPayloadLoaded(set)
    if not ok and set.configured == true then return nil end
    return self:DeepCopy(set)
end

function C:IsNameUsed(name, exceptId)
    if not self:EnsureCharacter() then return false end
    local wanted = Lower(name)
    if wanted == "" then return false end
    for _, set in ipairs(self.character.sets) do
        if tostring(set.id) ~= tostring(exceptId or "") and Lower(set.name) == wanted then
            return true
        end
    end
    return false
end

function C:CreateSet(name)
    local ready, readyErr = self:RequireCharacter()
    if not ready then return nil, readyErr end
    name = Trim(name)
    if name == "" then return nil, "请输入换装名称" end
    if #self.character.sets >= self.MaxSets then return nil, "最多支持 " .. tostring(self.MaxSets) .. " 套换装" end
    if self:IsNameUsed(name) then return nil, "已经存在同名换装" end
    local id = "set_" .. tostring(self.character.nextId)
    self.character.nextId = self.character.nextId + 1
    local oldNextStorageId = math.max(1, math.floor(tonumber(self.root.nextStorageId) or 1))
    local set = {
        id = id,
        name = name,
        order = #self.character.sets + 1,
        quick = true,
        quickX = nil,
        quickY = nil,
        quickPositionCustomized = false,
        configured = false,
        items = {},
        title = nil,
        payloadRevision = 0,
    }
    self:EnsureSetStorageId(set)
    set._payloadLoaded = true
    local oldNextId = self.character.nextId - 1
    self.character.sets[#self.character.sets + 1] = set
    local ok, err = self:Persist()
    if not ok then
        table.remove(self.character.sets, #self.character.sets)
        self.character.nextId = oldNextId
        self.root.nextStorageId = oldNextStorageId
        return nil, "保存新换装失败：" .. tostring(err or "unknown")
    end
    return set
end

function C:SetQuickButtonPosition(id, x, y)
    local set = self:FindSet(id)
    if set == nil then return false, "换装不存在" end
    local nx, ny = tonumber(x), tonumber(y)
    if nx == nil or ny == nil then return false, "按钮位置无效" end
    local oldX, oldY = set.quickX, set.quickY
    local oldCustomized = set.quickPositionCustomized == true
    set.quickX = math.floor(nx + 0.5)
    set.quickY = math.floor(ny + 0.5)
    set.quickPositionCustomized = true
    local ok, err = self:Persist()
    if not ok then
        set.quickX, set.quickY = oldX, oldY
        set.quickPositionCustomized = oldCustomized
        return false, err
    end
    return true
end

function C:DeleteSet(id)
    local ready, readyErr = self:RequireCharacter()
    if not ready then return false, readyErr end
    for index, set in ipairs(self.character.sets) do
        if tostring(set.id) == tostring(id) then
            local removed = table.remove(self.character.sets, index)
            for order, item in ipairs(self.character.sets) do item.order = order end
            local ok, err = self:Persist()
            if not ok then
                table.insert(self.character.sets, index, removed)
                for order, item in ipairs(self.character.sets) do item.order = order end
                return false, err
            end
            -- Index deletion is authoritative. Payload cleanup is best effort;
            -- stale orphan keys are harmless and storage ids are never reused.
            local payloadKey = self:SetPayloadKey(removed, false)
            local payloadBackupKey = self:SetPayloadKey(removed, true)
            if removed._payloadWriteFence == nil then
                if payloadKey then pcall(function() A:ClearData(payloadKey) end) end
                if payloadBackupKey then pcall(function() A:ClearData(payloadBackupKey) end) end
            end
            return true
        end
    end
    return false, "换装不存在"
end

function C:MoveSet(id, delta)
    local ready, readyErr = self:RequireCharacter()
    if not ready then return false, readyErr end
    local index = nil
    for i, set in ipairs(self.character.sets) do
        if tostring(set.id) == tostring(id) then index = i break end
    end
    if index == nil then return false end
    local target = math.max(1, math.min(#self.character.sets, index + (tonumber(delta) or 0)))
    if target == index then return true end
    local item = table.remove(self.character.sets, index)
    table.insert(self.character.sets, target, item)
    for order, set in ipairs(self.character.sets) do set.order = order end
    local ok, err = self:Persist()
    if not ok then
        table.remove(self.character.sets, target)
        table.insert(self.character.sets, index, item)
        for order, set in ipairs(self.character.sets) do set.order = order end
        return false, err
    end
    return true
end

function C:CaptureDraft(id)
    local draft = self:GetSetCopy(id)
    if draft == nil then return nil, "换装不存在" end
    local previousManaged = {}
    local hadPreviousConfiguration = draft.configured == true
    for _, oldItem in ipairs(draft.items or {}) do
        previousManaged[tonumber(oldItem.slot)] = self:IsManagedItem(oldItem)
    end
    draft.items = {}
    for _, slotDef in ipairs(self.EquipmentSlots) do
        local tooltip, tooltipErr = A:GetEquippedItemTooltipInfo(slotDef.slot)
        local rawType, typeErr = A:GetEquippedItemType(slotDef.slot)
        local equippedType = MeaningfulId(rawType)
        -- Capturing a loadout is an Authority write.  Any API read failure must
        -- abort the whole capture rather than silently persisting a half-read
        -- slot as empty.
        if tooltipErr ~= nil then
            return nil, "读取" .. tostring(slotDef.name) .. "详情失败：" .. tostring(tooltipErr)
        end
        if typeErr ~= nil then
            return nil, "读取" .. tostring(slotDef.name) .. "类型失败：" .. tostring(typeErr)
        end
        local hasItem = type(tooltip) == "table" or equippedType ~= nil
        if equippedType ~= nil and type(tooltip) ~= "table" then
            return nil, tostring(slotDef.name) .. "检测到装备类型，但装备详情尚未就绪，请稍后重新获取当前配置"
        end
        local item = {
            slot = slotDef.slot,
            key = slotDef.key,
            slotName = slotDef.name,
            alternative = slotDef.alternative == true,
            empty = not hasItem,
            -- Updating an existing partial loadout keeps the user's slot mask.
            -- A brand-new capture starts as a full loadout; the UI provides
            -- one-click 全选/仅武器/清空 so partial sets take only a few clicks.
            managed = hasItem and (not hadPreviousConfiguration or previousManaged[tonumber(slotDef.slot)] ~= false) or false,
        }
        if hasItem then
            item.name = type(tooltip) == "table" and Trim(tooltip.name) or "未知装备"
            item.grade = self:ExtractGrade(tooltip)
            item.itemType = equippedType
            item.icon = type(tooltip) == "table" and Primitive(tooltip.icon) or nil
            local modifiers = self:ExtractModifiers(tooltip)
            item.modifierSignature = self:ModifierSignature(modifiers)
        end
        draft.items[#draft.items + 1] = item
    end
    local title, titleErr = self:CaptureTitle()
    if titleErr ~= nil then
        return nil, titleErr
    end
    draft.title = title
    draft.configured = true
    draft.capturedAt = G.NowMs()
    return draft
end

function C:CommitDraft(draft, options)
    if type(draft) ~= "table" then return false, "没有可保存的配置" end
    local current = self:FindSet(draft.id)
    if current == nil then return false, "换装已经不存在" end
    local name = Trim(draft.name)
    if name == "" then return false, "换装名称不能为空" end
    if self:IsNameUsed(name, draft.id) then return false, "已经存在同名换装" end

    options = type(options) == "table" and options or {}
    local writePayload = options.writePayload == true
    local commitReason = tostring(options.reason or "")
    if writePayload and self.PayloadCommitReasons[commitReason] ~= true then
        return false, "装备明细写入被拒绝：缺少明确的用户保存授权"
    end

    local before = self:DeepCopy(current)
    local candidate = self:DeepCopy(current)

    -- Metadata is safe to persist during ordinary settings/lifecycle flushes.
    -- Crucially, without writePayload we preserve the already-saved equipment
    -- payload byte-for-byte in memory and never call SaveSetPayload().
    candidate.name = name
    candidate.quick = draft.quick ~= false
    candidate.storageId = current.storageId
    self:EnsureSetStorageId(candidate)

    if writePayload then
        candidate.configured = draft.configured == true
        candidate.items = self:DeepCopy(draft.items or {})
        for _, item in ipairs(candidate.items) do self:NormalizeManagedItem(item) end
        candidate.title = self:DeepCopy(draft.title)
        candidate.capturedAt = draft.capturedAt

        if candidate.configured == true then
            local titleManaged = type(candidate.title) == "table" and candidate.title.apply == true
            if self:CountManagedItems(candidate) <= 0 and not titleManaged then
                return false, "请至少勾选一个参与换装的装备部位或称号"
            end
            local payloadOk, payloadErr = self:SaveSetPayload(candidate)
            if not payloadOk then return false, "保存装备明细失败：" .. tostring(payloadErr or "unknown") end
        end
    end

    for k in pairs(current) do current[k] = nil end
    for k, v in pairs(candidate) do current[k] = self:DeepCopy(v) end
    current._payloadLoaded = true

    local ok, err = self:Persist()
    if not ok then
        for k in pairs(current) do current[k] = nil end
        for k, v in pairs(before) do current[k] = self:DeepCopy(v) end
        current._payloadLoaded = true
        -- Payload rollback is required only when this transaction was explicitly
        -- authorized to touch the equipment snapshot.  Metadata-only commits must
        -- never rewrite loadout payloads, even on an error path.
        if writePayload and before.configured == true then
            pcall(function() self:SaveSetPayload(before) end)
        end
        return false, err
    end
    return true
end

function C:CommitMetadata(draft, reason)
    return self:CommitDraft(draft, { writePayload = false, reason = reason or "metadata" })
end

function C:CommitPayloadDraft(draft, reason)
    return self:CommitDraft(draft, { writePayload = true, reason = reason })
end

function C:FindSavedItemBySlot(set, slot)
    for _, item in ipairs(type(set) == "table" and set.items or {}) do
        if tonumber(item.slot) == tonumber(slot) then return item end
    end
    return nil
end

function C:CurrentItemMatches(saved)
    if type(saved) ~= "table" or saved.empty == true then return false end
    local currentType = MeaningfulId(A:GetEquippedItemType(saved.slot))
    local typeComparable = saved.itemType ~= nil and currentType ~= nil
    if typeComparable and tostring(saved.itemType) ~= tostring(currentType) then return false end

    local tooltip = A:GetEquippedItemTooltipInfo(saved.slot)
    if type(tooltip) ~= "table" then
        -- Type alone is acceptable only when capture had no richer fingerprint.
        return typeComparable
            and tonumber(saved.grade) == nil
            and tostring(saved.modifierSignature or "") == ""
            and (saved.name == nil or saved.name == "" or saved.name == "未知装备")
    end

    local savedName = tostring(saved.normalizedName or self:NormalizeItemName(saved.name))
    local currentName = self:NormalizeItemName(tooltip.name)
    local nameComparable = savedName ~= "" and currentName ~= ""
    if nameComparable and savedName ~= currentName then return false end
    if not typeComparable and not nameComparable then return false end

    local savedGrade = tonumber(saved.grade)
    local currentGrade = self:ExtractGrade(tooltip)
    if savedGrade ~= nil and currentGrade ~= nil and savedGrade ~= currentGrade then return false end
    local required = tostring(saved.modifierSignature or "")
    if required ~= "" and self:ModifierSignature(self:ExtractModifiers(tooltip)) ~= required then return false end
    return true
end

function C:BuildBagCandidate(bagId, slot, info)
    if type(info) ~= "table" then return nil end
    local modifiers = self:ExtractModifiers(info)
    return {
        bagId = bagId,
        slot = slot,
        info = info,
        name = Trim(info.name),
        normalizedName = self:NormalizeItemName(info.name),
        grade = self:ExtractGrade(info),
        itemType = MeaningfulId(self:ExtractBagType(info)),
        modifierSignature = self:ModifierSignature(modifiers),
    }
end

function C:BuildBagSnapshot()
    local candidatesByBag = {}
    local counts, readErrors, firstErrors = {}, {}, {}
    for _, bagId in ipairs({ 1, 0 }) do
        local list, count, errors = {}, 0, 0
        for slot = 1, self.BagSlots do
            local info, readErr = A:GetBagItemInfo(bagId, slot)
            if readErr ~= nil then
                errors = errors + 1
                if firstErrors[bagId] == nil then firstErrors[bagId] = readErr end
            else
                local candidate = self:BuildBagCandidate(bagId, slot, info)
                if candidate ~= nil then
                    count = count + 1
                    list[#list + 1] = candidate
                end
            end
        end
        candidatesByBag[bagId] = list
        counts[bagId] = count
        readErrors[bagId] = errors
    end
    local count1, count0 = counts[1] or 0, counts[0] or 0
    local function ViewKey(candidate)
        -- Exclude guessed bag-side itemType fields here.  They are not part of
        -- the documented GetBagItemInfo return contract and may differ between
        -- client builds even when both bag ids expose the same physical slot.
        return table.concat({
            tostring(candidate.normalizedName or ""),
            tostring(candidate.grade or ""),
            tostring(candidate.modifierSignature or ""),
        }, "|")
    end
    local function SameView(left, right)
        if #left ~= #right then return false end
        local bySlot = {}
        for _, candidate in ipairs(left) do bySlot[tonumber(candidate.slot)] = ViewKey(candidate) end
        for _, candidate in ipairs(right) do
            if bySlot[tonumber(candidate.slot)] ~= ViewKey(candidate) then return false end
        end
        return true
    end

    -- The newest public GearSwap implementation uses bagId=1.  Prefer that
    -- physical-slot view, fall back to 0 only when 1 exposes no items.  If both
    -- expose populated but different views, EquipBagItem(slot) gives us no bagId
    -- with which to disambiguate, so fail closed rather than risk equipping the
    -- unrelated item that happens to occupy the same numeric slot.
    local bagId = 1
    local viewConflict = false
    if count1 == 0 and count0 > 0 then
        bagId = 0
    elseif count1 > 0 and count0 > 0 and not SameView(candidatesByBag[1], candidatesByBag[0]) then
        bagId = 1
        viewConflict = true
    elseif count1 == 0 and count0 == 0 and (readErrors[1] or 0) > (readErrors[0] or 0) then
        bagId = 0
    end

    return {
        bagId = bagId,
        items = candidatesByBag[bagId] or {},
        counts = counts,
        readErrors = readErrors[bagId] or 0,
        firstReadError = firstErrors[bagId],
        readErrorsByBag = readErrors,
        viewConflict = viewConflict,
    }
end


-- Weapon execution uses the physical bag position convention proven by the
-- CombatCloset shipped in the user's ArcheRage addon set: scan bagId=0 and pass
-- that position directly to X2Bag:EquipBagItem(pos, alternative).  Some newer
-- community GearSwap builds expose the same inventory through bagId=1, so view 1
-- remains a bounded fallback.  Armor/accessories keep their stricter dual-view
-- reconciliation and never block the weapon phase.
function C:BuildWeaponBagSnapshot(bagId)
    bagId = tonumber(bagId) or 0
    local items, errors, firstError = {}, 0, nil
    for slot = 1, self.BagSlots do
        local info, readErr = A:GetBagItemInfo(bagId, slot)
        if readErr ~= nil then
            errors = errors + 1
            if firstError == nil then firstError = readErr end
        else
            local candidate = self:BuildBagCandidate(bagId, slot, info)
            if candidate ~= nil then items[#items + 1] = candidate end
        end
    end
    return { bagId = bagId, items = items, readErrors = errors, firstReadError = firstError }
end

-- Community-compatible weapon lookup used by the out-of-combat weapon pass.
-- It scans bagId=1, matches by saved item name and passes the physical bag slot
-- directly to EquipBagItem. Runtime still blocks Addon equipment actions in combat.
function C:FindCommunityWeaponCandidate(saved, reserved)
    if type(saved) ~= "table" or not self:IsWeaponSlot(saved.slot) then return nil, "NOT_WEAPON" end
    local wantedName = tostring(saved.name or "")
    if wantedName == "" then return nil, "NO_NAME" end
    reserved = type(reserved) == "table" and reserved or {}
    local firstReadError = nil
    for posInBag = 1, self.BagSlots do
        if not reserved[posInBag] then
            local info, readErr = A:GetBagItemInfo(1, posInBag)
            if readErr ~= nil then
                if firstReadError == nil then firstReadError = readErr end
            elseif type(info) == "table" and tostring(info.name or "") == wantedName then
                return {
                    bagId = 1,
                    weaponBagView = 1,
                    slot = posInBag,
                    name = info.name,
                    grade = info.grade or info.itemGrade,
                    raw = info,
                    compatibilityMatch = true,
                }, nil
            end
        end
    end
    return nil, firstReadError ~= nil and "READ_ERROR" or "MISSING"
end

function C:FindWeaponFastCandidate(saved, reserved, bagCache, preferredBagId)
    if type(saved) ~= "table" or not self:IsWeaponSlot(saved.slot) then return nil, "NOT_WEAPON" end
    -- The bundled CombatCloset uses bagId=0 on this client family. Keep one shared
    -- snapshot per preflight so a two/four-weapon loadout does not rescan all 150
    -- slots for every step. bagId=1 is a compatibility fallback only.
    bagCache = type(bagCache) == "table" and bagCache or {}
    local reasons = {}
    local order = tonumber(preferredBagId) == 1 and { 1, 0 } or { 0, 1 }
    for _, bagId in ipairs(order) do
        local bag = bagCache[bagId]
        if type(bag) ~= "table" then
            bag = self:BuildWeaponBagSnapshot(bagId)
            bagCache[bagId] = bag
        end
        local candidate, reason = self:FindBagCandidate(saved, bag, reserved)
        local compatibilityMatch = false
        if candidate == nil and reason ~= "AMBIGUOUS" then
            local compat, compatReason = self:FindWeaponCompatibilityCandidate(saved, bag, reserved)
            if compat ~= nil then
                candidate, reason, compatibilityMatch = compat, nil, true
            elseif compatReason == "AMBIGUOUS" then
                reason = "AMBIGUOUS"
            else
                local unique, uniqueReason = self:FindUniqueWeaponNameCandidate(saved, bag, reserved)
                if unique ~= nil then
                    candidate, reason, compatibilityMatch = unique, nil, true
                elseif uniqueReason == "AMBIGUOUS" then
                    reason = "AMBIGUOUS"
                end
            end
        end
        if candidate ~= nil then
            candidate.weaponBagView = bagId
            candidate.compatibilityMatch = compatibilityMatch == true
            return candidate, nil
        end
        reasons[#reasons + 1] = tostring(bagId) .. ":" .. tostring(reason or "MISSING")
        if reason == "AMBIGUOUS" then return nil, "AMBIGUOUS" end
    end
    return nil, table.concat(reasons, ",")
end

function C:BagSlotMatches(saved, bagId, slot)
    local info, err = A:GetBagItemInfo(bagId, slot)
    if err ~= nil then return false, "READ_ERROR" end
    local candidate = self:BuildBagCandidate(bagId, slot, info)
    if candidate == nil then return false, "EMPTY" end
    local matched = self:CandidateMatches(saved, candidate)
    return matched == true, matched == true and nil or "CHANGED"
end

function C:WeaponBagSlotMatches(saved, bagId, slot)
    local info, err = A:GetBagItemInfo(bagId, slot)
    if err ~= nil then return false, "READ_ERROR" end
    local candidate = self:BuildBagCandidate(bagId, slot, info)
    if candidate == nil then return false, "EMPTY" end

    -- Weapon Fast Path intentionally mirrors the community addons: the physical
    -- bag position is the action input.  Do not reject that position merely because
    -- the bag tooltip omits modifier/type fields which existed on the equipped
    -- tooltip at save time.  Name is mandatory; grade/modifiers only veto when both
    -- sides actually expose conflicting values.
    local wantedName = tostring(saved and (saved.normalizedName or self:NormalizeItemName(saved.name)) or "")
    local candidateName = tostring(candidate.normalizedName or "")
    if wantedName == "" or candidateName == "" or wantedName ~= candidateName then return false, "CHANGED" end
    local wantedGrade, gotGrade = tonumber(saved and saved.grade), tonumber(candidate.grade)
    if wantedGrade ~= nil and gotGrade ~= nil and wantedGrade ~= gotGrade then return false, "CHANGED" end
    local wantedMods = tostring(saved and saved.modifierSignature or "")
    local gotMods = tostring(candidate.modifierSignature or "")
    if wantedMods ~= "" and gotMods ~= "" and wantedMods ~= gotMods then return false, "CHANGED" end
    return true, nil
end

function C:CandidateFingerprint(candidate)
    return table.concat({
        tostring(candidate.itemType or ""),
        tostring(candidate.normalizedName or ""),
        tostring(candidate.grade or ""),
        tostring(candidate.modifierSignature or ""),
    }, "|")
end

function C:CandidateMatches(saved, candidate)
    if type(saved) ~= "table" or type(candidate) ~= "table" then return false, 0 end
    -- GetEquippedItemType is documented, but GetBagItemInfo's returned table
    -- fields are not. Treat a bag-side type field only as a positive hint; a
    -- mismatching guessed field must never veto an otherwise exact fingerprint.
    local typeComparable = saved.itemType ~= nil and candidate.itemType ~= nil
    local exactType = typeComparable and tostring(saved.itemType) == tostring(candidate.itemType)

    local savedName = tostring(saved.normalizedName or self:NormalizeItemName(saved.name))
    local candidateName = tostring(candidate.normalizedName or "")
    local nameComparable = savedName ~= "" and candidateName ~= ""
    local exactName = nameComparable and savedName == candidateName
    if nameComparable and not exactName then return false, 0 end
    if not exactType and not exactName then return false, 0 end

    local savedGrade = tonumber(saved.grade)
    if savedGrade ~= nil and candidate.grade ~= nil and savedGrade ~= candidate.grade then return false, 0 end
    local requiredMods = tostring(saved.modifierSignature or "")
    if requiredMods ~= "" and requiredMods ~= tostring(candidate.modifierSignature or "") then return false, 0 end
    local score = 0
    if exactType then score = score + 100 end
    if exactName then score = score + 50 end
    if savedGrade ~= nil and candidate.grade == savedGrade then score = score + 10 end
    if requiredMods ~= "" then score = score + 25 end
    return true, score
end

function C:FindBagCandidate(saved, bagSnapshot, reserved)
    local topScore, top = nil, {}
    for _, candidate in ipairs(bagSnapshot and bagSnapshot.items or {}) do
        if not (reserved and reserved[candidate.slot]) then
            local match, score = self:CandidateMatches(saved, candidate)
            if match then
                if topScore == nil or score > topScore then
                    topScore, top = score, { candidate }
                elseif score == topScore then
                    top[#top + 1] = candidate
                end
            end
        end
    end
    if #top == 0 then
        if bagSnapshot and (tonumber(bagSnapshot.readErrors) or 0) > 0 then return nil, "READ_ERROR" end
        return nil, "MISSING"
    end
    if #top == 1 then return top[1], nil end
    local fingerprint = self:CandidateFingerprint(top[1])
    for index = 2, #top do
        if self:CandidateFingerprint(top[index]) ~= fingerprint then
            return nil, "AMBIGUOUS"
        end
    end
    table.sort(top, function(a, b) return tonumber(a.slot) < tonumber(b.slot) end)
    return top[1], nil
end

-- Weapon-only compatibility fallback based on the behavior used by the current
-- community GearSwap: the public bag tooltip can omit fields that exist on the
-- equipped tooltip. Keep our full fingerprint as the primary match, but when a
-- weapon has exactly one same-name/same-grade candidate and the bag simply lacks
-- modifier data, allow that unique candidate rather than treating it as missing.
-- Never use this fallback when multiple candidates remain or when the bag exposes
-- a conflicting modifier signature; avoiding a wrong same-name weapon remains
-- more important than forcing a swap.
function C:FindWeaponCompatibilityCandidate(saved, bagSnapshot, reserved)
    if type(saved) ~= "table" or not self:IsWeaponSlot(saved.slot) then return nil, "NOT_WEAPON" end
    local savedName = tostring(saved.normalizedName or self:NormalizeItemName(saved.name))
    if savedName == "" then return nil, "MISSING" end
    local savedGrade = tonumber(saved.grade)
    local savedMods = tostring(saved.modifierSignature or "")
    local matches = {}
    for _, candidate in ipairs(bagSnapshot and bagSnapshot.items or {}) do
        if not (reserved and reserved[candidate.slot])
            and tostring(candidate.normalizedName or "") == savedName then
            local grade = tonumber(candidate.grade)
            local gradeOk = savedGrade == nil or grade == nil or savedGrade == grade
            local candidateMods = tostring(candidate.modifierSignature or "")
            local modsOk = savedMods == "" or candidateMods == "" or savedMods == candidateMods
            if gradeOk and modsOk then matches[#matches + 1] = candidate end
        end
    end
    if #matches == 1 then return matches[1], "WEAPON_COMPAT" end
    if #matches > 1 then return nil, "AMBIGUOUS" end
    if bagSnapshot and (tonumber(bagSnapshot.readErrors) or 0) > 0 then return nil, "READ_ERROR" end
    return nil, "MISSING"
end

-- CombatCloset itself matches by normalized item name from bagId=0. Keep
-- fingerprint matching first, but if the physical bag view contains exactly one
-- weapon with the saved normalized name, that unique position is safe enough to
-- use as the final compatibility fallback. Multiple same-name weapons stay
-- ambiguous so we never guess between different rolls.
function C:FindUniqueWeaponNameCandidate(saved, bagSnapshot, reserved)
    if type(saved) ~= "table" or not self:IsWeaponSlot(saved.slot) then return nil, "NOT_WEAPON" end
    local wanted = tostring(saved.normalizedName or self:NormalizeItemName(saved.name))
    if wanted == "" then return nil, "MISSING" end
    local matches = {}
    for _, candidate in ipairs(bagSnapshot and bagSnapshot.items or {}) do
        if not (reserved and reserved[candidate.slot])
            and tostring(candidate.normalizedName or "") == wanted then
            matches[#matches + 1] = candidate
        end
    end
    if #matches == 1 then return matches[1], "WEAPON_NAME_UNIQUE" end
    if #matches > 1 then return nil, "AMBIGUOUS" end
    return nil, "MISSING"
end

function C:IsDesiredEquippedElsewhere(saved)
    if type(saved) ~= "table" then return false end
    for _, slotDef in ipairs(self.EquipmentSlots) do
        if tonumber(slotDef.slot) ~= tonumber(saved.slot) then
            local probe = self:DeepCopy(saved)
            probe.slot = slotDef.slot
            if self:CurrentItemMatches(probe) then return true end
        end
    end
    return false
end

function C:SavedItemMatchesSlot(saved, targetSlot)
    if type(saved) ~= "table" or saved.empty == true then return false end
    local probe = self:DeepCopy(saved)
    probe.slot = targetSlot
    return self:CurrentItemMatches(probe)
end

function C:SymmetricPairEquivalent(set, slotA, slotB)
    local a = self:FindSavedItemBySlot(set, slotA)
    local b = self:FindSavedItemBySlot(set, slotB)
    if not self:IsManagedItem(a) or not self:IsManagedItem(b) then return false end
    local direct = self:SavedItemMatchesSlot(a, slotA) and self:SavedItemMatchesSlot(b, slotB)
    if direct then return true end
    return self:SavedItemMatchesSlot(a, slotB) and self:SavedItemMatchesSlot(b, slotA)
end

function C:BuildSwapSession(setId)
    local set = self:FindSet(setId)
    if set == nil then return nil, "换装不存在" end
    if set.configured ~= true then return nil, "这个换装还没有获取并保存当前配置" end
    local payloadOk, payloadErr = self:EnsureSetPayloadLoaded(set)
    if not payloadOk then return nil, "读取换装装备明细失败：" .. tostring(payloadErr or "unknown") end

    -- The saved loadout describes desired state only. Runtime success/failure is
    -- never authoritative by itself; the final equipped state is reconciled again
    -- after every attempted transaction.
    local session = {
        setId = set.id,
        setName = set.name,
        set = self:DeepCopy(set),
        bag = nil,
        weaponBags = {},
        reserved = {},
        queue = {},
        skipped = 0,
        emptySlots = {},
        missing = {},
        ambiguous = {},
        readErrors = {},
        reposition = {},
        pendingFailures = {},
        success = 0,
        failed = 0,
        preflightChecked = 0,
        preflightSame = 0,
        preflightNeedChange = 0,
        runtimeSkipped = 0,
        weaponManaged = 0,
        weaponQueued = 0,
        nonWeaponQueued = 0,
        managedCount = 0,
        partial = false,
    }

    local pairEquivalent = {}
    if self:SymmetricPairEquivalent(set, 10, 11) then pairEquivalent[10], pairEquivalent[11] = true, true end
    if self:SymmetricPairEquivalent(set, 12, 13) then pairEquivalent[12], pairEquivalent[13] = true, true end

    -- Phase 1: preflight only the managed equipped slots. Already-correct slots
    -- are excluded from bag scanning, which also gives repeat clicks natural
    -- checkpoint/resume behavior.
    local needsChange = {}
    for _, saved in ipairs(set.items or {}) do
        self:NormalizeManagedItem(saved)
        if saved.managed == false or saved.empty == true then
            -- Unmanaged/empty slots are outside this loadout's Authority.
        else
            session.preflightChecked = session.preflightChecked + 1
            local slot = tonumber(saved.slot)
            if self:IsWeaponSlot(slot) then
                session.weaponManaged = session.weaponManaged + 1
            end
            if pairEquivalent[slot] or self:CurrentItemMatches(saved) then
                session.skipped = session.skipped + 1
                session.preflightSame = session.preflightSame + 1
            else
                session.preflightNeedChange = session.preflightNeedChange + 1
                needsChange[#needsChange + 1] = saved
            end
        end
    end
    session.managedCount = session.preflightChecked

    -- If every managed gear slot is already correct, do not touch the bag. The
    -- runtime still performs final reconciliation/title handling.
    if #needsChange == 0 then
        return session
    end

    -- Phase 2: discover candidates only for mismatched slots.  A pure weapon
    -- loadout deliberately skips the expensive 0/1 dual-view armor snapshot.
    -- Weapon lookup mirrors the current public ArcheRage GearSwap exactly:
    -- bagId=1, name match, physical bag position -> EquipBagItem.
    local hasNonWeaponChange = false
    for _, saved in ipairs(needsChange) do
        if not self:IsWeaponSlot(saved.slot) then hasNonWeaponChange = true; break end
    end
    local bag = hasNonWeaponChange and self:BuildBagSnapshot() or { bagId = 1, items = {}, viewConflict = false }
    session.bag = bag
    -- A bagId 0/1 view mismatch must never abort the transaction before weapon
    -- work. Non-weapon slots still fail closed per-slot below.
    local nonWeaponViewConflict = hasNonWeaponChange and bag.viewConflict == true

    local directWeapons, directOthers = {}, {}
    local deferredWeapons, deferredOthers = {}, {}

    local function AddPending(saved, reason, preflight)
        session.pendingFailures[#session.pendingFailures + 1] = {
            slot = saved and saved.slot or nil,
            slotName = saved and saved.slotName or nil,
            name = saved and saved.name or "未知装备",
            reason = tostring(reason or "未完成"),
            preflight = preflight == true,
        }
        session.partial = true
    end

    for _, saved in ipairs(needsChange) do
        local candidate, reason
        local compatibilityMatch = false
        if self:IsWeaponSlot(saved.slot) then
            candidate, reason = self:FindCommunityWeaponCandidate(saved, session.reserved)
            compatibilityMatch = candidate ~= nil
        elseif nonWeaponViewConflict then
            candidate, reason = nil, "VIEW_CONFLICT"
        else
            candidate, reason = self:FindBagCandidate(saved, bag, session.reserved)
        end
        local step = {
            saved = self:DeepCopy(saved),
            slot = saved.slot,
            alternative = saved.alternative == true,
            retries = 0,
            verifyPolls = 0,
            weapon = self:IsWeaponSlot(saved.slot),
            compatibilityMatch = compatibilityMatch == true,
        }
        if candidate ~= nil then
            step.bagSlot = candidate.slot
            step.bagId = candidate.bagId
            step.weaponBagView = candidate.weaponBagView
            session.reserved[candidate.slot] = true
            if step.weapon then
                directWeapons[#directWeapons + 1] = step
            else
                directOthers[#directOthers + 1] = step
            end
        elseif step.weapon then
            -- Community GearSwap retries the whole missing weapon set after a pass.
            -- Keep every mismatched weapon in the queue even when it is not in the
            -- bag at preflight (for example, it may still occupy another hand).
            step.deferred = true
            deferredWeapons[#deferredWeapons + 1] = step
        elseif self:IsDesiredEquippedElsewhere(saved) then
            step.deferred = true
            deferredOthers[#deferredOthers + 1] = step
        elseif reason == "AMBIGUOUS" then
            session.ambiguous[#session.ambiguous + 1] = saved
            AddPending(saved, "找到多个无法唯一确认的候选", true)
        elseif reason == "READ_ERROR" then
            session.readErrors[#session.readErrors + 1] = saved
            AddPending(saved, "背包读取不完整", true)
        elseif reason == "VIEW_CONFLICT" then
            AddPending(saved, "bagId 0/1 背包视图冲突；该非武器槽位为避免穿错已延后", true)
        else
            session.missing[#session.missing + 1] = saved
            AddPending(saved, "背包中找不到目标装备", true)
        end
    end

    -- Weapon work is deliberately first.  Within that phase, match the current
    -- public GearSwap order: main hand, off-hand/shield, ranged, instrument.
    -- This avoids deliberately issuing an off-hand action while an old two-handed
    -- main weapon is still occupying the dependency.
    local function SortWeaponSteps(a, b)
        local ap = self:GetWeaponPriority(a and a.slot)
        local bp = self:GetWeaponPriority(b and b.slot)
        if ap ~= bp then return ap < bp end
        return tonumber(a and a.slot) < tonumber(b and b.slot)
    end
    local weaponSteps = {}
    for _, step in ipairs(directWeapons) do weaponSteps[#weaponSteps + 1] = step end
    for _, step in ipairs(deferredWeapons) do weaponSteps[#weaponSteps + 1] = step end
    table.sort(weaponSteps, SortWeaponSteps)

    -- For weapons, slot order is stronger than direct/deferred convenience.
    -- Runtime has a bounded dependency deferral for the rare case where a desired
    -- weapon is currently equipped in another hand and must first be released.
    for _, step in ipairs(weaponSteps) do session.queue[#session.queue + 1] = step end
    for _, step in ipairs(directOthers) do session.queue[#session.queue + 1] = step end
    for _, step in ipairs(deferredOthers) do session.queue[#session.queue + 1] = step end

    session.weaponQueued = #weaponSteps
    session.nonWeaponQueued = #directOthers + #deferredOthers

    return session
end

function C:RefreshStepCandidate(session, step)
    if type(session) ~= "table" or type(step) ~= "table" then return false, "INVALID" end
    local isWeapon = self:IsWeaponSlot(step.saved and step.saved.slot)
    local candidate, reason
    local compatibilityMatch = false

    if isWeapon then
        -- Do not build/reconcile the armor bag views for weapons.  Re-scan the
        -- same bagId=1/name path used by community GearSwap and dispatch directly.
        candidate, reason = self:FindCommunityWeaponCandidate(step.saved, session.reserved)
        compatibilityMatch = candidate ~= nil
    else
        local bag = self:BuildBagSnapshot()
        session.bag = bag
        if bag.viewConflict == true then return false, "VIEW_CONFLICT" end
        candidate, reason = self:FindBagCandidate(step.saved, bag, session.reserved)
    end

    if candidate == nil then return false, reason end
    step.bagSlot = candidate.slot
    step.bagId = candidate.bagId
    step.weaponBagView = candidate.weaponBagView
    step.compatibilityMatch = compatibilityMatch == true
    step.deferred = false
    session.reserved[candidate.slot] = true
    return true
end

function C:GetWeaponMismatches(set)
    local result = {}
    if type(set) ~= "table" then return result end
    for _, saved in ipairs(set.items or {}) do
        self:NormalizeManagedItem(saved)
        if self:IsManagedItem(saved) and self:IsWeaponSlot(saved.slot) and not self:CurrentItemMatches(saved) then
            result[#result + 1] = saved
        end
    end
    table.sort(result, function(a, b)
        local ap = self:GetWeaponPriority(a and a.slot)
        local bp = self:GetWeaponPriority(b and b.slot)
        if ap ~= bp then return ap < bp end
        return (tonumber(a and a.slot) or 999) < (tonumber(b and b.slot) or 999)
    end)
    return result
end

function C:BuildCommunityWeaponRetrySteps(savedItems)
    local steps, used = {}, {}
    for _, saved in ipairs(savedItems or {}) do
        local candidate = self:FindCommunityWeaponCandidate(saved, used)
        local step = {
            saved = self:DeepCopy(saved),
            slot = saved.slot,
            alternative = saved.alternative == true,
            retries = 0,
            verifyPolls = 0,
            weapon = true,
            compatibilityMatch = candidate ~= nil,
            communityDirect = true,
        }
        if candidate ~= nil then
            step.bagSlot = candidate.slot
            step.bagId = 1
            step.weaponBagView = 1
            used[candidate.slot] = true
        else
            step.deferred = true
        end
        steps[#steps + 1] = step
    end
    return steps
end

function C:ValidateSetEquipped(set)
    if type(set) ~= "table" then return false, { { slotName = "套装", name = "数据无效" } } end
    local mismatches = {}
    local pairEquivalent = {}
    if self:SymmetricPairEquivalent(set, 10, 11) then pairEquivalent[10], pairEquivalent[11] = true, true end
    if self:SymmetricPairEquivalent(set, 12, 13) then pairEquivalent[12], pairEquivalent[13] = true, true end
    for _, saved in ipairs(set.items or {}) do
        self:NormalizeManagedItem(saved)
        local slot = tonumber(saved.slot)
        if self:IsManagedItem(saved) and not pairEquivalent[slot] and not self:CurrentItemMatches(saved) then
            mismatches[#mismatches + 1] = saved
        end
    end
    return #mismatches == 0, mismatches
end

function C:CurrentTitleMatches(set)
    local title = type(set) == "table" and set.title or nil
    if type(title) ~= "table" or title.apply ~= true then return true, "SKIPPED" end
    local wantedEffect = title.effect and MeaningfulId(title.effect.id) or nil
    if wantedEffect == nil then return false, "称号数据不完整" end
    local currentRaw, currentErr = A:GetEffectAppellation()
    if currentErr ~= nil then return false, "读取当前称号失败：" .. tostring(currentErr) end
    local current = self:PackAppellation(currentRaw)
    if current == nil or current.id == nil then return false, "当前称号状态尚未就绪" end
    return tostring(current.id) == tostring(wantedEffect), nil
end

function C:ApplySavedTitle(set)
    local title = type(set) == "table" and set.title or nil
    if type(title) ~= "table" or title.apply ~= true then return true, "SKIPPED" end
    local effect = title.effect and MeaningfulId(title.effect.id) or nil
    if effect == nil then return false, "称号数据不完整" end

    local already, currentReason = self:CurrentTitleMatches(set)
    if already == true then return true, "ALREADY" end
    if currentReason ~= nil then return false, currentReason end

    -- The first ChangeAppellation argument is taken from the *current* showing
    -- appellation, matching the working Combat Closet implementation.  Falling
    -- back to the captured showing id keeps old saves usable if the client
    -- briefly cannot report the current showing state.
    local currentShowingRaw, currentShowingErr = A:GetShowingAppellation()
    if currentShowingErr ~= nil then
        return false, "读取当前称号展示类型失败：" .. tostring(currentShowingErr)
    end
    local currentShowing = self:PackAppellation(currentShowingRaw)
    local showing = currentShowing and MeaningfulId(currentShowing.id)
        or (title.showing and MeaningfulId(title.showing.id) or nil)
    if showing == nil then return false, "无法取得当前称号展示类型" end
    return A:ChangeAppellation(showing, effect)
end

local initOk, initErr = xpcall(function() C:Initialize() end, G.SafeTraceback)
if not initOk then
    G.BootError = "core: " .. tostring(initErr)
    G.SafeChat("核心初始化失败：" .. tostring(initErr))
    return
end
