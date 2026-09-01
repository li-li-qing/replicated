------------------------------------------------------------------------
-- Replicated Suite - Feature / HUD Profiles / Explicit Combo Shortcuts
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Profiles = {}
local P = S.Profiles

local COMBO_FEATURE_PREFIX = "__combo_feature__:"
local COMBO_HUD_PREFIX = "__combo_hud__:"

local function IsInternalProfileName(name)
    name = tostring(name or "")
    return string.sub(name, 1, #COMBO_FEATURE_PREFIX) == COMBO_FEATURE_PREFIX
        or string.sub(name, 1, #COMBO_HUD_PREFIX) == COMBO_HUD_PREFIX
end

local Copy = S.Reuse.Table.DeepCopy

-- HUD instances are created once and several built-in widgets intentionally
-- keep a direct reference to their placement table. Replacing
-- State.ui.widgets (or an existing placement object) would split Authority:
-- HudManager would read the new table while the live widget still reads the
-- old one. Apply saved profile fields in place so every live reference observes
-- the same state object. Fields absent from an older profile are preserved.
local function OverlayInPlace(target, saved)
    if type(target) ~= "table" or type(saved) ~= "table" then return target end
    for key, value in pairs(saved) do
        if type(value) == "table" then
            if type(target[key]) ~= "table" then target[key] = {} end
            OverlayInPlace(target[key], value)
        else
            target[key] = value
        end
    end
    return target
end

-- Lua tables cannot store an explicit nil value. HUD profiles therefore need
-- separate clear metadata for nullable placement fields. Without this, a
-- profile captured while a HUD inherited the default size/font/background
-- could not later clear a user override back to that inherited/default state.
-- This metadata is UI-only, backward compatible (older profiles simply do not
-- contain it), and does not touch Module Enabled.
local HUD_PROFILE_NULLABLE_FIELDS = {
    "width", "height", "opacity", "fontScale", "backgroundAlpha",
    "compact", "customTitle", "profileExtra",
}

local function CaptureHudClearFields(widgets)
    local clear = {}
    for id, placement in pairs(type(widgets) == "table" and widgets or {}) do
        if type(placement) == "table" then
            local fields = {}
            for _, key in ipairs(HUD_PROFILE_NULLABLE_FIELDS) do
                if placement[key] == nil then fields[#fields + 1] = key end
            end
            if #fields > 0 then clear[tostring(id)] = fields end
        end
    end
    return clear
end

local function ApplyHudClearFields(current, clear)
    if type(current) ~= "table" or type(clear) ~= "table" then return end
    for id, fields in pairs(clear) do
        local placement = current[tostring(id)]
        if type(placement) == "table" and type(fields) == "table" then
            for _, key in ipairs(fields) do
                placement[tostring(key)] = nil
            end
        end
    end
end

local function Store()
    S.State.profiles = type(S.State.profiles) == "table" and S.State.profiles or {}
    local p = S.State.profiles
    p.features = type(p.features) == "table" and p.features or {}
    p.huds = type(p.huds) == "table" and p.huds or {}
    p.combos = type(p.combos) == "table" and p.combos or {}
    return p
end

local function CommitProfilesNow()
    if S.Storage == nil then return true end
    if type(S.Storage.RequestSave) == "function" then S.Storage:RequestSave(0) end
    if type(S.Storage.SaveNow) ~= "function" then return true end
    return S.Storage:SaveNow() == true
end

function P:SaveFeature(name, deferCommit)
    name = tostring(name or "")
    if name == "" then return false end
    local modules = {}
    if S.ModuleManager ~= nil then
        for _, detail in ipairs(S.ModuleManager:List(false)) do
            modules[detail.id] = detail.enabled == true
        end
    end
    Store().features[name] = { modules = modules }
    if deferCommit ~= true and not CommitProfilesNow() then return false, "保存功能方案失败" end
    return true
end

function P:ApplyFeature(name)
    local profile = Store().features[tostring(name or "")]
    if type(profile) ~= "table" or type(profile.modules) ~= "table" then return false, "功能方案不存在" end
    if S.ModuleManager == nil then return false, "ModuleManager unavailable" end
    local failures = {}
    for id, enabled in pairs(profile.modules) do
        if S.ModuleManager:IsRegistered(id) then
            local ok, err = S.ModuleManager:SetEnabled(id, enabled == true, "deferred")
            if not ok then failures[#failures + 1] = tostring(id) .. ":" .. tostring(err) end
        end
    end
    -- Feature profiles may switch many modules at once. Their individual
    -- transitions use deferred persistence, then this single commit publishes the
    -- whole resulting module set atomically from the Suite State snapshot.
    if not CommitProfilesNow() then return false, "应用功能方案后保存失败" end
    if S.State ~= nil then S.State:MarkDirty("modules"); S.State:MarkDirty("combat") end
    if S.HudManager ~= nil then S.HudManager:ApplyAll() end
    if #failures > 0 then return false, table.concat(failures, "; ") end
    return true
end

function P:SaveHud(name, deferCommit)
    name = tostring(name or "")
    if name == "" then return false end
    if S.HudManager ~= nil and type(S.HudManager.CaptureAllProfileStates) == "function" then
        S.HudManager:CaptureAllProfileStates()
    end
    local widgets = S.State.ui and S.State.ui.widgets or {}
    Store().huds[name] = {
        version = 2,
        widgets = Copy(widgets),
        clear = CaptureHudClearFields(widgets),
    }
    if deferCommit ~= true and not CommitProfilesNow() then return false, "保存 HUD 方案失败" end
    return true
end

function P:ApplyHud(name)
    local profile = Store().huds[tostring(name or "")]
    if type(profile) ~= "table" or type(profile.widgets) ~= "table" then return false, "HUD方案不存在" end

    -- Overlay instead of replacing the whole registry. Older profiles may not
    -- contain HUDs/fields added by newer Suite builds; applying such a profile
    -- must never delete those live placements and break HUD management.
    S.State.ui = type(S.State.ui) == "table" and S.State.ui or {}
    S.State.ui.widgets = type(S.State.ui.widgets) == "table" and S.State.ui.widgets or {}
    local current = S.State.ui.widgets
    -- v2 profiles can explicitly restore nil/default/inherited fields. Older
    -- profiles have no clear metadata, so they retain the previous overlay-only
    -- compatibility behavior.
    ApplyHudClearFields(current, profile.clear)
    for id, savedPlacement in pairs(profile.widgets) do
        if type(savedPlacement) == "table" then
            current[id] = type(current[id]) == "table" and current[id] or {}
            OverlayInPlace(current[id], savedPlacement)
        end
    end

    if S.HudManager ~= nil then
        if type(S.HudManager.ApplyAllProfileStates) == "function" then S.HudManager:ApplyAllProfileStates() end
        S.HudManager:ApplyAll()
    end
    if S.UI ~= nil and type(S.UI.ApplyResponsiveLayout) == "function" then S.UI:ApplyResponsiveLayout(false) end
    if not CommitProfilesNow() then return false, "应用 HUD 方案后保存失败" end
    if S.State ~= nil then S.State:MarkDirty("hud") end
    return true
end

function P:SaveCombo(name, featureName, hudName, deferCommit)
    name = tostring(name or "")
    if name == "" then return false end
    Store().combos[name] = { feature = tostring(featureName or ""), hud = tostring(hudName or "") }
    if deferCommit ~= true and not CommitProfilesNow() then return false, "保存组合方案失败" end
    return true
end

-- Explicit combined shortcut.  The feature/HUD snapshots are stored under
-- internal names so normal feature/HUD pickers stay clean and deleting a combo
-- can safely clean up only the snapshots it owns.
function P:SaveCurrentCombo(name)
    name = tostring(name or "")
    if name == "" then return false, "组合名称不能为空" end
    local featureName = COMBO_FEATURE_PREFIX .. name
    local hudName = COMBO_HUD_PREFIX .. name
    local okFeature, errFeature = self:SaveFeature(featureName, true)
    if not okFeature then return false, errFeature end
    local okHud, errHud = self:SaveHud(hudName, true)
    if not okHud then return false, errHud end
    local okCombo, errCombo = self:SaveCombo(name, featureName, hudName, true)
    if not okCombo then return false, errCombo end
    if not CommitProfilesNow() then return false, "保存组合方案失败" end
    return true
end

function P:ApplyCombo(name)
    local combo = Store().combos[tostring(name or "")]
    if type(combo) ~= "table" then return false, "组合快捷方式不存在" end
    if tostring(combo.feature or "") ~= "" then
        local okFeature, errFeature = self:ApplyFeature(combo.feature)
        if not okFeature then return false, errFeature end
    end
    if tostring(combo.hud or "") ~= "" then
        local okHud, errHud = self:ApplyHud(combo.hud)
        if not okHud then return false, errHud end
    end
    return true
end

function P:Delete(kind, name)
    local store = Store()
    local bucket = kind == "feature" and store.features or kind == "hud" and store.huds or kind == "combo" and store.combos or nil
    if bucket == nil then return false, "未知方案类型" end
    name = tostring(name or "")
    if name == "" or bucket[name] == nil then return false, "方案不存在" end
    if kind == "combo" then
        local combo = bucket[name]
        local featureName = type(combo) == "table" and tostring(combo.feature or "") or ""
        local hudName = type(combo) == "table" and tostring(combo.hud or "") or ""
        if string.sub(featureName, 1, #COMBO_FEATURE_PREFIX) == COMBO_FEATURE_PREFIX then store.features[featureName] = nil end
        if string.sub(hudName, 1, #COMBO_HUD_PREFIX) == COMBO_HUD_PREFIX then store.huds[hudName] = nil end
    end
    bucket[name] = nil
    if not CommitProfilesNow() then return false, "删除方案后保存失败" end
    return true
end

function P:List(kind)
    local store = Store()
    local bucket = kind == "feature" and store.features or kind == "hud" and store.huds or kind == "combo" and store.combos or {}
    local names = {}
    for name in pairs(bucket) do
        if kind == "combo" or not IsInternalProfileName(name) then names[#names + 1] = tostring(name) end
    end
    table.sort(names)
    return names
end

function P:NextName(kind, current)
    local names = self:List(kind)
    if #names == 0 then return nil end
    current = tostring(current or "")
    for i, name in ipairs(names) do
        if name == current then return names[(i % #names) + 1] end
    end
    return names[1]
end

