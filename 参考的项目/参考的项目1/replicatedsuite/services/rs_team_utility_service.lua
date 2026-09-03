------------------------------------------------------------------------
-- Replicated Suite - Team Utility Service
-- Auto role assignment + Sacrifice Dance highlight + native marker scale.
--
-- Design notes:
-- * Role writes are event-driven and verified with X2Team:GetRole. A 10s
--   read-only safety watch only reconciles when an event was missed or the
--   server did not commit the requested role; it never spams SetRole.
-- * Shiny-sac candidate discovery is low frequency (10s / roster events).
-- * Buff checks run at 200ms only for members who actually carry Spelldance.
-- * Screen-position follow runs at 50ms only for currently active dancers.
-- * Native raid markers are never cleared or overwritten by the sac overlay.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}
S.Services.TeamUtility = {
    started = false,
    lastAppliedRole = nil,
    lastAppliedClassKey = nil,
    candidates = {},
    activeSac = {},
    overlays = {},
    currentMarkerScale = 1.20,
    pendingRosterReason = nil,
    playerRosterSlot = nil,
    roleVerifyToken = 0,
}
local U = S.Services.TeamUtility

local function DamageReview()
    return S.Services and S.Services.DamageReview or nil
end

local SAC_BUFF_IDS = {
    [30098] = true,
    [30137] = true,
    [30141] = true,
    [30142] = true,
}
local SAC_DURATION_MS = 10000
local MARKER_CVAR = "name_tag_mark_size_ratio"
local MARKER_MIN = 0.50
local MARKER_MAX = 2.00
local MARKER_STEP = 0.10
local MARKER_DEFAULT = 1.20

-- Buff / siege check static ids (raidmanager reference data, P0-4).
local RAID_BUFF_CATEGORIES = {
    drum = { 5700, 32233, 32234, 32235, 32236, 32237, 32238, 32239 },
    statue = { 9002339, 48778, 9002340, 30768, 30765, 30766, 30770, 30760, 30764, 30767 },
    book = { 20552, 21795 },
    ribs = { 685, 693, 597, 689, 21791, 21792, 21793, 21794 },
    goblet = { 7685, 21796, 21801, 21806, 21811, 21819, 21846, 7686, 21797, 21802, 21807, 21812, 21820, 7687, 21798, 21803, 21808, 21813, 21821, 7688, 21799, 21804, 21809, 21814, 21822, 7689, 21800, 21805, 21810, 21815, 21823, 24469, 24470, 24471, 24472, 24473, 24474 },
}
local RAID_SIEGE_BUFFS = {
    catapult = { 31757 },
    clad = { 25088 },
    flamethrower = { 28315 },
}
local RAID_ROLE_LABELS = {
    tank = "T", healer = "奶妈", dealer = "战士", ranged = "远程", none = "未标记",
}

local ROLE_MODES = { "auto", "healer", "tank", "dealer", "ranged" }
local ROLE_MODE_LABELS = {
    auto = "智能",
    healer = "固定治疗",
    tank = "固定坦克",
    dealer = "固定输出",
    ranged = "固定远程",
}
local CLASS_ROLE_LABELS = {
    Mage = "法系",
    Malediction = "法系",
    Tank = "坦克",
    Songer = "辅助",
    Dancer = "舞者",
    Healer = "治疗",
    Gunner = "远程",
    Archer = "输出",
    Melee = "输出",
    Swiftblade = "输出",
    unknown = "未识别",
}

local function RoleValue(mode)
    if mode == "healer" then return tonumber(TMROLE_HEALER) or 2 end
    if mode == "tank" then return tonumber(TMROLE_TANKER) or 1 end
    if mode == "dealer" then return tonumber(TMROLE_DEALER) or 3 end
    if mode == "ranged" then return tonumber(TMROLE_RANGED_DEALER) or 4 end
    return tonumber(TMROLE_NONE) or 0
end

local CLASS_TO_ROLE = {
    Mage = function() return RoleValue("none") end,
    Malediction = function() return RoleValue("none") end,
    Tank = function() return RoleValue("tank") end,
    Songer = function() return RoleValue("tank") end,
    Dancer = function() return RoleValue("tank") end,
    Healer = function() return RoleValue("healer") end,
    Gunner = function() return RoleValue("ranged") end,
    Archer = function() return RoleValue("dealer") end,
    Melee = function() return RoleValue("dealer") end,
    Swiftblade = function() return RoleValue("dealer") end,
    unknown = function() return RoleValue("none") end,
}

local function Clamp(value, low, high)
    value = tonumber(value) or low
    if value < low then return low end
    if value > high then return high end
    return value
end

local function RoundMarker(value)
    value = Clamp(value, MARKER_MIN, MARKER_MAX)
    return math.floor(value * 10 + 0.5) / 10
end

local function SetTeamData(fields)
    local data = S.State.data.teamUtility
    if type(data) ~= "table" then
        data = {}
        S.State.data.teamUtility = data
    end
    local changed = false
    for key, value in pairs(fields or {}) do
        if data[key] ~= value then
            data[key] = value
            changed = true
        end
    end
    if changed then S.State:MarkDirty("teamUtility") end
end

local function GetAbilityIndices(unit)
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return nil end
    local ok, templates = S.Api:CallCapability(
        "X2Unit:GetTargetAbilityTemplates", X2Unit, "GetTargetAbilityTemplates", unit)
    if not ok or type(templates) ~= "table" or templates[1] == nil or templates[2] == nil or templates[3] == nil then return nil end
    local indices = {
        tonumber(templates[1].index),
        tonumber(templates[2].index),
        tonumber(templates[3].index),
    }
    if indices[1] == nil or indices[2] == nil or indices[3] == nil then return nil end
    table.sort(indices)
    return indices
end

local function HasIndex(indices, target)
    if type(indices) ~= "table" then return false end
    for _, value in ipairs(indices) do if tonumber(value) == tonumber(target) then return true end end
    return false
end

local function BuildClassKey(indices)
    if type(indices) ~= "table" or #indices < 3 then return nil end
    return string.format("name_%d_%d_%d", indices[1], indices[2], indices[3])
end


local function ResolveExistingUnitId(candidates)
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return nil end
    for _, unitId in ipairs(candidates) do
        local ok, name = S.Api:CallCapability("X2Unit:UnitName", X2Unit, "UnitName", unitId)
        if ok and name ~= nil and tostring(name) ~= "" then return unitId, tostring(name) end
    end
    return nil, nil
end

local function GetSingleRaidUnit(memberIndex)
    return ResolveExistingUnitId({
        string.format("team%02d", memberIndex),
        string.format("team%d", memberIndex),
    })
end

local function GetCoRaidUnit(teamIndex, memberIndex)
    return ResolveExistingUnitId({
        string.format("team_%02d_%02d", teamIndex, memberIndex),
        string.format("team_%d_%d", teamIndex, memberIndex),
    })
end

local function ReadUnitName(unitId)
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return nil end
    local ok, name = S.Api:CallCapability("X2Unit:UnitName", X2Unit, "UnitName", unitId)
    if ok ~= true or name == nil or tostring(name) == "" then return nil end
    return tostring(name)
end

local function FindPlayerRosterSlot()
    local playerName = ReadUnitName("player")
    if playerName == nil then return nil end

    -- Fast path: roster changes invalidate this cache, so during the 10s safety
    -- watch a stable team costs one UnitName probe instead of a full roster scan.
    local cached = U.playerRosterSlot
    if type(cached) == "table" and cached.unitId ~= nil then
        local cachedName = ReadUnitName(cached.unitId)
        if cachedName == playerName then
            return tonumber(cached.teamIndex), tonumber(cached.memberIndex), cached.unitId
        end
        U.playerRosterSlot = nil
    end

    -- The client exposes different unit-token layouts for a normal raid/party
    -- and a co-raid. Probe the first packed slot to select one layout, then scan
    -- only that layout. This path runs only on roster/reconcile edges.
    local coUnit = GetCoRaidUnit(1, 1)
    if coUnit ~= nil then
        for teamIndex = 1, 2 do
            for memberIndex = 1, 50 do
                local unitId, name = GetCoRaidUnit(teamIndex, memberIndex)
                if unitId ~= nil and name == playerName then
                    U.playerRosterSlot = {
                        teamIndex = teamIndex,
                        memberIndex = memberIndex,
                        unitId = unitId,
                    }
                    return teamIndex, memberIndex, unitId
                end
            end
        end
        return nil
    end

    local singleUnit = GetSingleRaidUnit(1)
    if singleUnit ~= nil then
        for memberIndex = 1, 50 do
            local unitId, name = GetSingleRaidUnit(memberIndex)
            if unitId ~= nil and name == playerName then
                U.playerRosterSlot = {
                    teamIndex = 1,
                    memberIndex = memberIndex,
                    unitId = unitId,
                }
                return 1, memberIndex, unitId
            end
        end
    end
    return nil
end

local function ReadCurrentPlayerRole()
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then
        return nil, "api_unavailable"
    end
    local teamIndex, memberIndex = FindPlayerRosterSlot()
    if teamIndex == nil or memberIndex == nil then return nil, "not_in_team" end
    local ok, currentRole, err = S.Api:CallCapability(
        "X2Team:GetRole", X2Team, "GetRole", teamIndex, memberIndex)
    if ok ~= true then return nil, "role_read_failed:" .. tostring(err or "unknown") end
    currentRole = tonumber(currentRole)
    if currentRole == nil then return nil, "role_read_invalid" end
    return currentRole, nil
end

function U:ResolvePlayerRole()
    local mode = tostring(S.State.settings.teamRoleMode or "auto")
    if mode ~= "auto" then
        return RoleValue(mode), ROLE_MODE_LABELS[mode] or "固定", "fixed:" .. mode, nil
    end

    local indices = GetAbilityIndices("player")
    local key = BuildClassKey(indices)
    if key == nil then return RoleValue("none"), "未识别", "ability_unavailable", nil end
    local classType = type(nameMappings) == "table" and tostring(nameMappings[key] or "unknown") or "unknown"

    -- Strawberry's RU autorole maps every Dancer to the tanker/support color.
    -- That is wrong for Vitalism + Spelldance healing builds.  Keep the class
    -- identity as Dancer for class-trackers, but assign the TEAM role as healer.
    -- This directly fixes Darkness Savior (Shadowplay + Vitalism + Spelldance,
    -- name_8_10_14) and the same support pattern without rewriting global class
    -- identity mappings used by Replicated Plates.
    if key == "name_8_10_14" or (classType == "Dancer" and HasIndex(indices, 10)) then
        return RoleValue("healer"), "治疗", "vitalism_dancer_healer", key
    end

    local resolver = CLASS_TO_ROLE[classType] or CLASS_TO_ROLE.unknown
    local role = resolver()
    return role, CLASS_ROLE_LABELS[classType] or "未识别", classType, key
end

function U:ScheduleRoleVerify(delayMs, desiredRole, label, source, classKey, reason, retriesLeft, token)
    if S.Scheduler == nil then return end
    local taskName = "team_utility_role_verify"
    S.Scheduler:RemoveTask(taskName)
    S.Scheduler:AddTask(taskName, math.max(600, tonumber(delayMs) or 650), function()
        S.Scheduler:RemoveTask(taskName)
        if U.started ~= true or S.State.settings.teamAutoRoleEnabled ~= true then return end
        if token ~= U.roleVerifyToken then return end

        local currentRole, readReason = ReadCurrentPlayerRole()
        if currentRole == tonumber(desiredRole) then
            U.lastAppliedRole = tonumber(desiredRole)
            U.lastAppliedClassKey = classKey
            SetTeamData({
                roleStatus = label,
                roleLabel = label,
                roleValue = tonumber(desiredRole),
                roleSource = source,
                classKey = classKey or "--",
                lastRoleReason = tostring(reason or "verify"),
            })
            return
        end

        local retries = math.max(0, math.floor(tonumber(retriesLeft) or 0))
        if retries > 0 then
            -- X2Team:SetRole has an official 500ms cooldown. Verification waits
            -- at least 600ms before a bounded retry, so no retry can violate it.
            U:ApplyRole(tostring(reason or "verify") .. ":retry", true, retries - 1, token)
            return
        end

        U.lastAppliedRole = nil
        U.lastAppliedClassKey = nil
        SetTeamData({
            roleStatus = readReason == "not_in_team" and "未在团队" or "职责设置未生效",
            roleLabel = label,
            classKey = classKey or "--",
            lastRoleReason = tostring(reason or "verify") .. ":" .. tostring(readReason or "mismatch"),
        })
    end, false, self, "P2")
end

function U:ApplyRole(reason, force, retriesLeft, token)
    if S.State.settings.teamAutoRoleEnabled ~= true then
        SetTeamData({ roleStatus = "关闭" })
        return false
    end
    local roleAllowed = S.Api ~= nil and type(S.Api.IsCapabilityAllowed) == "function"
        and S.Api:IsCapabilityAllowed("X2Team:SetRole") == true
    local readAllowed = S.Api ~= nil and type(S.Api.IsCapabilityAllowed) == "function"
        and S.Api:IsCapabilityAllowed("X2Team:GetRole") == true
    if roleAllowed ~= true or readAllowed ~= true then
        SetTeamData({ roleStatus = "职责 API 不可用" })
        return false
    end

    local role, label, source, classKey = self:ResolvePlayerRole()
    if role == nil then
        SetTeamData({ roleStatus = "无法识别职责" })
        return false
    end

    local currentRole, readReason = ReadCurrentPlayerRole()
    if currentRole == nil then
        self.lastAppliedRole = nil
        self.lastAppliedClassKey = nil
        local retries = math.max(0, math.floor(tonumber(retriesLeft) or 0))
        SetTeamData({
            roleStatus = retries > 0 and "等待团队同步" or "未在团队",
            roleLabel = label,
            classKey = classKey or "--",
            roleSource = source,
            lastRoleReason = tostring(reason or "manual") .. ":" .. tostring(readReason or "team_not_ready"),
        })
        if retries > 0 and S.Scheduler ~= nil then
            self:ScheduleRoleApply(700, reason, true, retries - 1)
        end
        return false
    end

    -- GetRole is the Authority. Never trust the cached lastAppliedRole alone:
    -- SetRole returns nil even on a syntactically successful call, so the old
    -- code could mark a solo/no-op call as "applied" before the player joined.
    if currentRole == tonumber(role) then
        self.lastAppliedRole = tonumber(role)
        self.lastAppliedClassKey = classKey
        SetTeamData({
            roleStatus = label,
            roleLabel = label,
            roleValue = tonumber(role),
            roleSource = source,
            classKey = classKey or "--",
            lastRoleReason = tostring(reason or "already_correct"),
        })
        return true
    end

    local ok, err = S.Api:ActionCapability("X2Team:SetRole", X2Team, "SetRole", role)
    if ok ~= true then
        self.lastAppliedRole = nil
        self.lastAppliedClassKey = nil
        SetTeamData({
            roleStatus = "职责设置失败",
            roleLabel = label,
            classKey = classKey or "--",
            roleSource = source,
            lastRoleReason = tostring(reason or "manual") .. ":" .. tostring(err or "SetRole failed"),
        })
        return false
    end

    -- SetRole is documented as a void/nil-returning write. Do not publish a
    -- false "success" here. Verify after the 500ms official cooldown and retry
    -- at most twice if the roster/server needed more time after joining.
    local verifyToken = tonumber(token)
    if verifyToken == nil then
        self.roleVerifyToken = (tonumber(self.roleVerifyToken) or 0) + 1
        verifyToken = self.roleVerifyToken
    end
    self.lastAppliedRole = nil
    self.lastAppliedClassKey = nil
    SetTeamData({
        roleStatus = "设置中：" .. label,
        roleLabel = label,
        roleValue = tonumber(role),
        roleSource = source,
        classKey = classKey or "--",
        lastRoleReason = tostring(reason or "manual"),
    })
    self:ScheduleRoleVerify(
        650, role, label, source, classKey, reason,
        math.max(0, math.floor(tonumber(retriesLeft) or 0)), verifyToken)
    return true
end

function U:ScheduleRoleApply(delayMs, reason, force, retriesLeft)
    if S.Scheduler == nil then return end
    local taskName = "team_utility_role_debounce"
    self.roleVerifyToken = (tonumber(self.roleVerifyToken) or 0) + 1
    local token = self.roleVerifyToken
    S.Scheduler:RemoveTask(taskName)
    S.Scheduler:RemoveTask("team_utility_role_verify")
    S.Scheduler:AddTask(taskName, math.max(80, tonumber(delayMs) or 150), function()
        S.Scheduler:RemoveTask(taskName)
        U:ApplyRole(reason, force == true, math.max(0, math.floor(tonumber(retriesLeft) or 2)), token)
    end, false, self, "P2")
end

function U:VerifyRoleSafety()
    if self.started ~= true or S.State.settings.teamAutoRoleEnabled ~= true then return end
    local desiredRole = self:ResolvePlayerRole()
    if desiredRole == nil then return end
    local currentRole = ReadCurrentPlayerRole()
    if currentRole == nil then
        self.lastAppliedRole = nil
        self.lastAppliedClassKey = nil
        return
    end
    if tonumber(currentRole) ~= tonumber(desiredRole) then
        self:ScheduleRoleApply(80, "safety_watch", true, 1)
    end
end

function U:SetAutoRoleEnabled(enabled)
    S.State.settings.teamAutoRoleEnabled = enabled == true
    self.lastAppliedRole = nil
    self.lastAppliedClassKey = nil
    S.Storage:RequestSave()
    if S.State.settings.teamAutoRoleEnabled then
        SetTeamData({ roleEnabled = true, roleStatus = "等待识别" })
        if S.Scheduler ~= nil then S.Scheduler:SetEnabled("team_utility_role_watch", true) end
        self:ScheduleRoleApply(80, "toggle", true, 2)
    else
        self.roleVerifyToken = (tonumber(self.roleVerifyToken) or 0) + 1
        if S.Scheduler ~= nil then
            S.Scheduler:RemoveTask("team_utility_role_debounce")
            S.Scheduler:RemoveTask("team_utility_role_verify")
            S.Scheduler:SetEnabled("team_utility_role_watch", false)
        end
        SetTeamData({ roleEnabled = false, roleStatus = "关闭" })
    end
end

function U:CycleRoleMode()
    local current = tostring(S.State.settings.teamRoleMode or "auto")
    local index = 1
    for i, value in ipairs(ROLE_MODES) do if value == current then index = i; break end end
    index = index % #ROLE_MODES + 1
    S.State.settings.teamRoleMode = ROLE_MODES[index]
    self.lastAppliedRole = nil
    self.lastAppliedClassKey = nil
    S.Storage:RequestSave()
    if S.State.settings.teamAutoRoleEnabled then self:ScheduleRoleApply(80, "mode", true, 2) end
    S.State:MarkDirty("teamUtility")
end

function U:GetRoleModeLabel()
    return ROLE_MODE_LABELS[tostring(S.State.settings.teamRoleMode or "auto")] or "智能"
end

function U:HideOverlay(unitId)
    local overlay = self.overlays[unitId]
    if overlay ~= nil then overlay.lastTimerTenths = nil end
    if overlay ~= nil and overlay.window ~= nil and type(overlay.window.Show) == "function" then
        pcall(function() overlay.window:Show(false) end)
    end
end

function U:HideAllSacOverlays()
    for unitId in pairs(self.overlays) do self:HideOverlay(unitId) end
    self.activeSac = {}
    if S.Scheduler ~= nil then S.Scheduler:SetEnabled("team_utility_sac_position", false) end
    SetTeamData({ sacActive = 0 })
end

local function SafeUiId(unitId)
    return tostring(unitId or "unit"):gsub("[^%w_]", "_")
end

function U:CreateOverlay(unitId)
    if self.overlays[unitId] ~= nil then return self.overlays[unitId] end
    local safeId = SafeUiId(unitId)
    local window = CreateEmptyWindow(S.PhysicalId("sac_" .. safeId), "UIParent")
    if window == nil then return nil end
    window:SetExtent(142, 50)
    if window.EnablePick ~= nil then pcall(function() window:EnablePick(false, true) end) end
    if window.Clickable ~= nil then pcall(function() window:Clickable(false) end) end
    if S.UI ~= nil and type(S.UI.TrySetUILayer) == "function" then S.UI:TrySetUILayer(window, "system") end
    if window.SetDrawPriority ~= nil then pcall(function() window:SetDrawPriority(12000) end) end

    local glow = nil
    if type(window.CreateColorDrawable) == "function" then
        glow = window:CreateColorDrawable(1.00, 0.72, 0.05, 0.92, "background")
        glow:AddAnchor("TOPLEFT", window, 0, 0)
        glow:SetExtent(50, 50)
        glow:SetVisible(true)
    end

    local icon = nil
    if type(window.CreateIconDrawable) == "function" then
        icon = window:CreateIconDrawable("artwork")
        icon:SetExtent(44, 44)
        icon:ClearAllTextures()
        icon:AddTexture("ui/icon/icon_skill_pleasure14.dds")
        icon:AddAnchor("TOPLEFT", window, 3, 3)
        icon:SetVisible(true)
    end

    local label = window:CreateChildWidget("label", S.PhysicalId("sac_label_" .. safeId), 0, true)
    label:AddAnchor("TOPLEFT", window, 54, 2)
    label:SetExtent(86, 22)
    if label.SetAutoResize ~= nil then label:SetAutoResize(false) end
    if label.EnablePick ~= nil then label:EnablePick(false) end
    if S.Theme ~= nil and type(S.Theme.StyleLabel) == "function" then S.Theme:StyleLabel(label, 12, "yellow", ALIGN_LEFT) end
    label:SetText("牺牲之舞")
    label:Show(true)

    local timer = window:CreateChildWidget("label", S.PhysicalId("sac_timer_" .. safeId), 0, true)
    timer:AddAnchor("TOPLEFT", window, 54, 24)
    timer:SetExtent(36, 20)
    if timer.SetAutoResize ~= nil then timer:SetAutoResize(false) end
    if timer.EnablePick ~= nil then timer:EnablePick(false) end
    if S.Theme ~= nil and type(S.Theme.StyleLabel) == "function" then S.Theme:StyleLabel(timer, 11, "text", ALIGN_LEFT) end
    timer:SetText("10.0s")
    timer:Show(true)

    local bar = nil
    if UIParent ~= nil and type(UIParent.CreateWidget) == "function" then
        local ok, created = pcall(function() return UIParent:CreateWidget("statusbar", S.PhysicalId("sac_bar_" .. safeId), window) end)
        if ok then bar = created end
    end
    if bar ~= nil then
        bar:AddAnchor("TOPLEFT", window, 92, 28)
        bar:SetExtent(46, 10)
        if bar.SetBarTexture ~= nil then pcall(function() bar:SetBarTexture("ui/common/hud.dds", "background") end) end
        if bar.SetBarTextureByKey ~= nil then pcall(function() bar:SetBarTextureByKey("casting_status_bar") end) end
        if bar.SetOrientation ~= nil then bar:SetOrientation("HORIZONTAL") end
        if bar.SetBarColor ~= nil then bar:SetBarColor(1, 0.78, 0.10, 1) end
        if bar.SetMinMaxValues ~= nil then bar:SetMinMaxValues(0, SAC_DURATION_MS) end
        if bar.SetValue ~= nil then bar:SetValue(SAC_DURATION_MS) end
        bar:Show(true)
    end

    window:Show(false)
    local overlay = { window = window, icon = icon, glow = glow, label = label, timer = timer, bar = bar, lastTimerTenths = nil }
    self.overlays[unitId] = overlay
    return overlay
end

function U:ScanDancerCandidates()
    if X2Unit == nil then return end
    local nextCandidates = {}
    local coUnit = GetCoRaidUnit(1, 1)
    local singleUnit = GetSingleRaidUnit(1)
    local hasCoRaid = coUnit ~= nil
    local raidCount = hasCoRaid and 2 or (singleUnit ~= nil and 1 or 0)

    for teamIndex = 1, raidCount do
        for memberIndex = 1, 50 do
            local unitId, name
            if hasCoRaid then unitId, name = GetCoRaidUnit(teamIndex, memberIndex)
            else unitId, name = GetSingleRaidUnit(memberIndex) end
            if unitId ~= nil then
                local indices = GetAbilityIndices(unitId)
                if HasIndex(indices, 14) then nextCandidates[unitId] = { name = name or unitId } end
            end
        end
    end

    for unitId in pairs(self.activeSac) do
        if nextCandidates[unitId] == nil then
            self.activeSac[unitId] = nil
            self:HideOverlay(unitId)
        end
    end
    self.candidates = nextCandidates

    local count = 0
    for _ in pairs(nextCandidates) do count = count + 1 end
    SetTeamData({ sacCandidates = count })
end

local function TeamCapability(name)
    return U.capabilities ~= nil and U.capabilities[name] == true
end

local function FindSacBuff(unitId)
    if not TeamCapability("X2Unit:UnitBuffCount") or not TeamCapability("X2Unit:UnitBuff") then return nil end
    local okCount, count = pcall(function() return X2Unit:UnitBuffCount(unitId) end)
    count = okCount and math.max(0, tonumber(count) or 0) or 0
    for index = 1, count do
        local okBuff, extra = pcall(function() return X2Unit:UnitBuff(unitId, index) end)
        if okBuff and type(extra) == "table" then
            local buffId = tonumber(extra.buff_id or extra.buffId or extra.id)
            if buffId ~= nil and SAC_BUFF_IDS[buffId] == true then
                local timeLeft = tonumber(extra.timeLeft or extra.time_left)
                if TeamCapability("X2Unit:UnitBuffTooltip") then
                    local okTip, tip = pcall(function() return X2Unit:UnitBuffTooltip(unitId, index) end)
                    if okTip and type(tip) == "table" then timeLeft = tonumber(tip.timeLeft or tip.time_left) or timeLeft end
                end
                return buffId, timeLeft
            end
        end
    end
    return nil, nil
end

function U:ScanSacBuffs()
    if S.State.settings.sacMarkerEnabled ~= true then
        if next(self.activeSac) ~= nil then self:HideAllSacOverlays() end
        return
    end

    local now = S.NowMs()
    local nextActive = {}
    for unitId, candidate in pairs(self.candidates) do
        local buffId, timeLeft = FindSacBuff(unitId)
        if buffId ~= nil then
            local remaining = tonumber(timeLeft)
            if remaining == nil or remaining <= 0 then remaining = SAC_DURATION_MS end
            remaining = math.min(SAC_DURATION_MS, math.max(0, remaining))
            nextActive[unitId] = {
                name = candidate.name,
                buffId = buffId,
                remainingMs = remaining,
                observedAt = now,
            }
            local overlay = self:CreateOverlay(unitId)
            if overlay ~= nil and overlay.window ~= nil then overlay.window:Show(true) end
        end
    end

    for unitId in pairs(self.activeSac) do
        if nextActive[unitId] == nil then self:HideOverlay(unitId) end
    end
    self.activeSac = nextActive

    local count = 0
    for _ in pairs(nextActive) do count = count + 1 end
    if S.Scheduler ~= nil then S.Scheduler:SetEnabled("team_utility_sac_position", count > 0) end
    SetTeamData({ sacActive = count })
end

function U:UpdateSacPositions()
    if S.State.settings.sacMarkerEnabled ~= true or next(self.activeSac) == nil then return end
    if not TeamCapability("X2Unit:GetUnitScreenPosition") then return end
    local now = S.NowMs()
    for unitId, active in pairs(self.activeSac) do
        local overlay = self:CreateOverlay(unitId)
        if overlay ~= nil and overlay.window ~= nil then
            local ok, x, y, z = pcall(function() return X2Unit:GetUnitScreenPosition(unitId) end)
            if not ok or tonumber(x) == nil or tonumber(y) == nil or tonumber(z) == nil then
                overlay.window:Show(false)
            else
                if overlay.window.RemoveAllAnchors ~= nil then overlay.window:RemoveAllAnchors() end
                overlay.window:AddAnchor("TOPLEFT", "UIParent", tonumber(x) - 58, tonumber(y) - 82)
                overlay.window:Show(true)
                local elapsed = math.max(0, now - (tonumber(active.observedAt) or now))
                local remaining = math.max(0, (tonumber(active.remainingMs) or SAC_DURATION_MS) - elapsed)
                -- Position following remains 50ms, but timer text is only rewritten
                -- when the displayed 0.1s value changes. This avoids unnecessary
                -- string formatting / label invalidation in the high-frequency path.
                local tenths = math.max(0, math.ceil(remaining / 100))
                if overlay.timer ~= nil and overlay.lastTimerTenths ~= tenths then
                    overlay.lastTimerTenths = tenths
                    overlay.timer:SetText(string.format("%.1fs", tenths / 10))
                end
                if overlay.bar ~= nil and overlay.bar.SetValue ~= nil then overlay.bar:SetValue(remaining) end
            end
        end
    end
end

function U:SetSacMarkerEnabled(enabled)
    local isEnabled = enabled == true
    S.State.settings.sacMarkerEnabled = isEnabled
    S.Storage:RequestSave()
    SetTeamData({ sacEnabled = isEnabled })

    if S.Scheduler ~= nil then
        S.Scheduler:SetEnabled("team_utility_roster_scan", isEnabled)
        S.Scheduler:SetEnabled("team_utility_sac_scan", isEnabled)
        -- Position following is enabled only while at least one Sacrifice Dance
        -- is actually active.  This keeps the 50ms path dormant otherwise.
        S.Scheduler:SetEnabled("team_utility_sac_position", false)
    end

    if isEnabled then
        -- Even a manual enable may occur while the raid window is being opened.
        -- Reuse the roster settle fence instead of probing team_* immediately.
        self:OnRosterChanged("marker_enabled")
    else
        self.candidates = {}
        self:HideAllSacOverlays()
        SetTeamData({ sacCandidates = 0, sacActive = 0 })
    end
end

function U:ReadMarkerScale()
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return nil end
    local ok, value = S.Api:CallCapability("X2Option:GetConsoleVariable", X2Option, "GetConsoleVariable", MARKER_CVAR)
    if not ok then return nil end
    local numeric = tonumber(value)
    if numeric == nil or numeric ~= numeric or numeric <= 0 then return nil end
    return numeric
end

function U:ApplyMarkerScale(value, persist)
    if S.Api == nil or type(S.Api.ActionCapability) ~= "function" then
        SetTeamData({ markerScaleAvailable = false })
        return false
    end
    local nextValue = RoundMarker(value)
    local ok, result = S.Api:ActionCapability(
        "X2Option:SetConsoleVariable", X2Option, "SetConsoleVariable", MARKER_CVAR, string.format("%.1f", nextValue))
    if ok ~= true then
        SetTeamData({ markerScaleAvailable = false })
        return false
    end
    self.currentMarkerScale = nextValue
    if persist == true then
        S.State.settings.markerScaleOverride = true
        S.State.settings.markerScale = nextValue
        S.Storage:RequestSave()
    end
    SetTeamData({ markerScaleAvailable = true, markerScale = nextValue })
    return true
end

function U:AdjustMarkerScale(delta)
    local current = tonumber(self.currentMarkerScale) or self:ReadMarkerScale() or MARKER_DEFAULT
    local step = tonumber(delta)
    if step == nil or step == 0 then step = MARKER_STEP end
    return self:ApplyMarkerScale(current + step, true)
end

function U:ResetMarkerScale()
    return self:ApplyMarkerScale(MARKER_DEFAULT, true)
end

function U:GetMarkerScaleText()
    local value = tonumber(self.currentMarkerScale) or MARKER_DEFAULT
    return tostring(math.floor(value * 100 + 0.5)) .. "%"
end

function U:ReconcileCharacterSettings(reason)
    if self.started ~= true then return true end
    local review = DamageReview()
    if review ~= nil and type(review.ReconcileCharacterSettings) == "function" then review:ReconcileCharacterSettings() end
    self.lastAppliedRole = nil
    self.lastAppliedClassKey = nil

    local roleEnabled = S.State.settings.teamAutoRoleEnabled == true
    if roleEnabled then
        SetTeamData({ roleEnabled = true, roleStatus = "等待识别" })
        -- Character-scope reconciliation can run during world/raid UI startup.
        -- Keep SetRole out of the native frame construction window as well.
        self:ScheduleRoleApply(1100, tostring(reason or "character_scope"), true, 2)
    else
        self.roleVerifyToken = (tonumber(self.roleVerifyToken) or 0) + 1
        if S.Scheduler ~= nil then
            S.Scheduler:RemoveTask("team_utility_role_debounce")
            S.Scheduler:RemoveTask("team_utility_role_verify")
        end
        SetTeamData({ roleEnabled = false, roleStatus = "关闭" })
    end
    if S.Scheduler ~= nil then S.Scheduler:SetEnabled("team_utility_role_watch", roleEnabled) end

    local sacEnabled = S.State.settings.sacMarkerEnabled == true
    SetTeamData({ sacEnabled = sacEnabled })
    if S.Scheduler ~= nil then
        S.Scheduler:SetEnabled("team_utility_roster_scan", sacEnabled)
        S.Scheduler:SetEnabled("team_utility_sac_scan", sacEnabled)
        S.Scheduler:SetEnabled("team_utility_sac_position", false)
    end
    if sacEnabled then
        -- Use the same settle fence as TEAM_MEMBERS_CHANGED so startup and
        -- character-scope restore never synchronously enumerate team_* slots.
        self:OnRosterChanged("reconcile:" .. tostring(reason or "character_scope"))
    else
        self.candidates = {}
        self:HideAllSacOverlays()
        SetTeamData({ sacCandidates = 0, sacActive = 0 })
    end
    return true
end

function U:ApplyRosterChangedAfterSettle(reason)
    reason = tostring(reason or "")
    if reason == "leaved_by_self" or reason == "kicked_by_self" or reason == "dismissed" then
        self:HideAllSacOverlays()
        self.candidates = {}
        self.lastAppliedRole = nil
        self.lastAppliedClassKey = nil
        if S.Scheduler ~= nil then S.Scheduler:SetEnabled("team_utility_sac_position", false) end
        SetTeamData({ roleStatus = "未在团队", sacCandidates = 0, sacActive = 0 })
        return
    end

    if S.State.settings.sacMarkerEnabled == true then
        self:ScanDancerCandidates()
        self:ScanSacBuffs()
    end
    if S.State.settings.teamAutoRoleEnabled == true then
        -- Do not depend on a specific reason string. TEAM_MEMBERS_CHANGED is
        -- documented as a generic roster edge and different clients/addons may
        -- deliver nil/other reason values. Every settled roster edge is sparse;
        -- GetRole below prevents unnecessary SetRole writes when nothing changed.
        self:ScheduleRoleApply(120, "roster:" .. (reason ~= "" and reason or "changed"), true, 2)
    end
end

------------------------------------------------------------------------
-- P0-4: raid sort + read-only team checks.
-- Everything here is manual/user-click-triggered; nothing auto-starts.
------------------------------------------------------------------------
local RAID_ROLE_KIND_BY_VALUE = { [0] = "none", [1] = "tank", [2] = "healer", [3] = "dealer", [4] = "ranged" }

local function RoleKindFromValue(value)
    value = tonumber(value)
    if value == nil then return nil end
    return RAID_ROLE_KIND_BY_VALUE[value]
end

local function ResolveStableKey(unitId)
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return nil end
    local okW, world = S.Api:CallCapability("X2Unit:UnitNameWithWorld", X2Unit, "UnitNameWithWorld", unitId)
    if okW and world ~= nil and tostring(world) ~= "" then return tostring(world) end
    local okN, name = S.Api:CallCapability("X2Unit:UnitName", X2Unit, "UnitName", unitId)
    if okN and name ~= nil and tostring(name) ~= "" then return tostring(name) end
    return nil
end

local function ReadMemberRole(teamIndex, memberIndex)
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return nil, nil end
    local ok, value = S.Api:CallCapability("X2Team:GetRole", X2Team, "GetRole", teamIndex, memberIndex)
    if not ok then return nil, nil end
    local roleValue = tonumber(value)
    return roleValue, RoleKindFromValue(roleValue)
end


-- Iterate the player's own raid members once; used only by the read-only checks.
local function ForEachOwnRaidMember(callback)
    local teamIndex = FindPlayerRosterSlot()
    if teamIndex == nil then return 0 end
    local useCoLayout = GetCoRaidUnit(1, 1) ~= nil
    local checked = 0
    for memberIndex = 1, 50 do
        local unitId, name
        if useCoLayout then
            unitId, name = GetCoRaidUnit(teamIndex, memberIndex)
        else
            unitId, name = GetSingleRaidUnit(memberIndex)
        end
        if unitId ~= nil then
            checked = checked + 1
            callback(unitId, tostring(name or "?"), memberIndex, teamIndex)
        end
    end
    return checked
end

local function FormatSlot(teamIndex, memberIndex)
    return string.format("T%d-%d", tonumber(teamIndex) or 1, tonumber(memberIndex) or 0)
end

function U:RunBuffCheck()
    if self.started ~= true then return false, "团队辅助模块尚未启用" end
    local canCount = TeamCapability("X2Unit:UnitBuffCount")
    local canBuff = TeamCapability("X2Unit:UnitBuff")
    local missingByCategory = {}
    for category in pairs(RAID_BUFF_CATEGORIES) do missingByCategory[category] = {} end
    local unreadable = {}
    local roleCounts = { tank = 0, healer = 0, dealer = 0, ranged = 0, none = 0 }
    local checked = ForEachOwnRaidMember(function(unitId, name, memberIndex, teamIndex)
        -- Role stats depend only on GetRole and always run (F-9): the button is
        -- "Buff / 职业检查"; an unavailable Buff read must not swallow the
        -- still-available profession statistics.
        local _, roleKind = ReadMemberRole(teamIndex, memberIndex)
        local kind = roleKind or "none"
        roleCounts[kind] = (roleCounts[kind] or 0) + 1
        if canCount and canBuff then
            local okCount, count = pcall(function() return X2Unit:UnitBuffCount(unitId) end)
            local buffCount = okCount and math.max(0, tonumber(count) or 0) or 0
            if buffCount == 0 then
                unreadable[#unreadable + 1] = string.format("%s (%s)", name, FormatSlot(teamIndex, memberIndex))
                return
            end
            local has = {}
            for category in pairs(RAID_BUFF_CATEGORIES) do has[category] = false end
            for index = 1, buffCount do
                local okBuff, extra = pcall(function() return X2Unit:UnitBuff(unitId, index) end)
                if okBuff and type(extra) == "table" then
                    local buffId = tonumber(extra.buff_id or extra.buffId or extra.id)
                    if buffId ~= nil then
                        for category, ids in pairs(RAID_BUFF_CATEGORIES) do
                            for _, id in ipairs(ids) do
                                if tonumber(id) == buffId then has[category] = true end
                            end
                        end
                    end
                end
            end
            for category, present in pairs(has) do
                if present ~= true then
                    missingByCategory[category][#missingByCategory[category] + 1] = string.format("%s (%s)", name, FormatSlot(teamIndex, memberIndex))
                end
            end
        end
    end)
    if checked == 0 then return false, "未读取到团队成员" end
    -- Role statistics are always reported after a successful member scan.
    local roleLine = "职责统计："
    for _, kind in ipairs({ "tank", "healer", "dealer", "ranged", "none" }) do
        roleLine = roleLine .. " " .. tostring(RAID_ROLE_LABELS[kind] or kind) .. " " .. tostring(roleCounts[kind] or 0)
    end
    S.SafeChat(roleLine)
    if not canCount or not canBuff then
        S.SafeChat("Buff 检查：UnitBuff 读取能力不可用，跳过 Buff 扫描（职业统计已输出）。")
        return true, nil
    end
    local anyMissing = false
    for _, category in ipairs({ "drum", "statue", "book", "ribs", "goblet" }) do
        local list = missingByCategory[category] or {}
        if #list > 0 then
            anyMissing = true
            S.SafeChat(string.format("缺少 %s Buff：%s", tostring(category), table.concat(list, "、")))
        end
    end
    if #unreadable > 0 then
        S.SafeChat(string.format("无法读取（可能超出范围）：%s", table.concat(unreadable, "、")))
    end
    if not anyMissing and #unreadable == 0 then
        S.SafeChat("所有可读成员均具备已检查的 Buff。")
    end
    return true, nil
end

function U:RunSiegeCheck()
    if self.started ~= true then return false, "团队辅助模块尚未启用" end
    local canCount = TeamCapability("X2Unit:UnitHiddenBuffCount")
    local canBuff = TeamCapability("X2Unit:UnitHiddenBuff")
    if not canCount or not canBuff then
        S.SafeChat("攻城装备检查：Hidden Buff 读取能力不可用，跳过扫描。")
        return false, "Hidden Buff 能力不可用"
    end
    local detected = { catapult = {}, clad = {}, flamethrower = {} }
    local unreadable = {}
    local checked = ForEachOwnRaidMember(function(unitId, name, memberIndex, teamIndex)
        local okCount, count = pcall(function() return X2Unit:UnitHiddenBuffCount(unitId) end)
        local buffCount = okCount and math.max(0, tonumber(count) or 0) or 0
        if buffCount == 0 then
            unreadable[#unreadable + 1] = string.format("%s (%s)", name, FormatSlot(teamIndex, memberIndex))
            return
        end
        for index = 1, buffCount do
            local okBuff, extra = pcall(function() return X2Unit:UnitHiddenBuff(unitId, index) end)
            if okBuff and type(extra) == "table" then
                local buffId = tonumber(extra.buff_id or extra.buffId or extra.id)
                if buffId ~= nil then
                    for category, ids in pairs(RAID_SIEGE_BUFFS) do
                        for _, id in ipairs(ids) do
                            if tonumber(id) == buffId then
                                detected[category][#detected[category] + 1] = string.format("%s (%s)", name, FormatSlot(teamIndex, memberIndex))
                            end
                        end
                    end
                end
            end
        end
    end)
    -- An empty snapshot is "no data", never "check passed" (F-7).
    if checked == 0 then return false, "未读取到团队成员" end
    local anyDetected = false
    for _, category in ipairs({ "catapult", "clad", "flamethrower" }) do
        local list = detected[category] or {}
        if #list > 0 then
            anyDetected = true
            S.SafeChat(string.format("攻城装备 %s：%s", tostring(category), table.concat(list, "、")))
        end
    end
    if not anyDetected then
        S.SafeChat("当前可读取成员中未检测到攻城装备状态。")
    end
    if #unreadable > 0 then
        S.SafeChat(string.format("无法读取（可能超出范围）：%s", table.concat(unreadable, "、")))
    end
    return true, nil
end

function U:OnRosterChanged(reason)
    -- TEAM_MEMBERS_CHANGED can run from the native raid-frame rebuild stack.
    -- Never hide/show overlays, SetRole, or enumerate team_* unit tokens from
    -- this callback. Coalesce rapid roster events and handle them after the
    -- native widgets have had time to finish OnShow/OnHide.
    self.pendingRosterReason = tostring(reason or "")
    self.playerRosterSlot = nil
    if S.Scheduler == nil then return end
    -- Pause every periodic path that reads team_* handles during the settle
    -- fence. Otherwise the 200ms Sacrifice scan could race the native member
    -- rebuild even though this event callback itself is deferred.
    S.Scheduler:SetEnabled("team_utility_roster_scan", false)
    S.Scheduler:SetEnabled("team_utility_sac_scan", false)
    S.Scheduler:SetEnabled("team_utility_sac_position", false)
    S.Scheduler:RemoveTask("team_utility_roster_settle")
    S.Scheduler:AddTask("team_utility_roster_settle", 1000, function()
        S.Scheduler:RemoveTask("team_utility_roster_settle")
        local pendingReason = U.pendingRosterReason
        U.pendingRosterReason = nil
        local sacEnabled = S.State.settings.sacMarkerEnabled == true
        S.Scheduler:SetEnabled("team_utility_roster_scan", sacEnabled)
        S.Scheduler:SetEnabled("team_utility_sac_scan", sacEnabled)
        U:ApplyRosterChangedAfterSettle(pendingReason)
    end, false, self, "P2")
end

function U:Start()
    if self.started == true then return end
    self.started = true
    local review = DamageReview()
    if review ~= nil and type(review.Start) == "function" then review:Start() end
    self.capabilities = {}
    for _, name in ipairs({
        "X2Unit:UnitBuffCount",
        "X2Unit:UnitBuff",
        "X2Unit:UnitBuffTooltip",
        "X2Unit:GetUnitScreenPosition",
        "X2Unit:UnitHiddenBuffCount",
        "X2Unit:UnitHiddenBuff",
    }) do
        local allowed = S.Api ~= nil and type(S.Api.IsCapabilityAllowed) == "function"
            and S.Api:IsCapabilityAllowed(name) == true
        self.capabilities[name] = allowed == true
    end

    local detectedScale = self:ReadMarkerScale()
    local scale = detectedScale or MARKER_DEFAULT
    self.currentMarkerScale = RoundMarker(scale)
    if S.State.settings.markerScaleOverride == true and tonumber(S.State.settings.markerScale) ~= nil then
        self:ApplyMarkerScale(S.State.settings.markerScale, false)
    else
        SetTeamData({ markerScaleAvailable = detectedScale ~= nil, markerScale = self.currentMarkerScale })
    end

    SetTeamData({
        roleEnabled = S.State.settings.teamAutoRoleEnabled == true,
        roleStatus = S.State.settings.teamAutoRoleEnabled == true and "等待识别" or "关闭",
        sacEnabled = S.State.settings.sacMarkerEnabled == true,
        sacActive = 0,
        sacCandidates = 0,
    })

    S.Events:Subscribe("TEAM_MEMBERS_CHANGED", self, function(_, reason) U:OnRosterChanged(reason) end)
    S.Events:Subscribe("ABILITY_SET_CHANGED", self, function()
        if S.State.settings.teamAutoRoleEnabled == true then U:ScheduleRoleApply(120, "ability_set", true, 2) end
        if S.State.settings.sacMarkerEnabled == true then U:ScanDancerCandidates() end
    end)
    S.Events:Subscribe("ABILITY_CHANGED", self, function()
        if S.State.settings.teamAutoRoleEnabled == true then U:ScheduleRoleApply(120, "ability", true, 2) end
        if S.State.settings.sacMarkerEnabled == true then U:ScanDancerCandidates() end
    end)
    S.Events:Subscribe("ENTERED_WORLD", self, function()
        if S.State.settings.teamAutoRoleEnabled == true then U:ScheduleRoleApply(800, "entered_world", true, 2) end
        if S.Scheduler ~= nil then
            S.Scheduler:RemoveTask("team_utility_world_scan")
            S.Scheduler:AddTask("team_utility_world_scan", 900, function()
                S.Scheduler:RemoveTask("team_utility_world_scan")
                if S.State.settings.sacMarkerEnabled == true then
                    U:ScanDancerCandidates()
                    U:ScanSacBuffs()
                end
            end, false, self, "P2")
        end
    end)

    S.Scheduler:AddTask("team_utility_role_watch", 10000, function() U:VerifyRoleSafety() end, false, self, "P5")
    S.Scheduler:SetEnabled("team_utility_role_watch", S.State.settings.teamAutoRoleEnabled == true)
    S.Scheduler:AddTask("team_utility_roster_scan", 10000, function() U:ScanDancerCandidates() end, true, self, "P2")
    S.Scheduler:AddTask("team_utility_sac_scan", 200, function() U:ScanSacBuffs() end, false, self, "P2")
    S.Scheduler:AddTask("team_utility_sac_position", 50, function() U:UpdateSacPositions() end, false, self, "P4")
    S.Scheduler:AddTask("team_utility_damage_review", 100, function()
        local service = DamageReview()
        if service ~= nil and service.started == true and S.State.settings.damageReviewEnabled == true then
            service:OnUpdate(100, S.NowMs(), false)
        end
    end, false, self, "P4")
    S.Scheduler:SetEnabled("team_utility_damage_review", S.State.settings.damageReviewEnabled == true)

    self:ReconcileCharacterSettings("startup")
end

function U:Stop()
    self.started = false
    self.capabilities = {}
    if S.Scheduler ~= nil then
        for _, taskName in ipairs({
            "team_utility_role_debounce",
            "team_utility_role_verify",
            "team_utility_role_watch",
            "team_utility_world_scan",
            "team_utility_roster_settle",
            "team_utility_roster_scan",
            "team_utility_sac_scan",
            "team_utility_sac_position",
            "team_utility_damage_review",
        }) do S.Scheduler:RemoveTask(taskName) end
    end
    local review = DamageReview()
    if review ~= nil and type(review.Stop) == "function" then review:Stop() end
    self:HideAllSacOverlays()
    for _, overlay in pairs(self.overlays) do
        if overlay.window ~= nil and type(overlay.window.Show) == "function" then pcall(function() overlay.window:Show(false) end) end
    end
    self.candidates = {}
    self.playerRosterSlot = nil
    self.roleVerifyToken = (tonumber(self.roleVerifyToken) or 0) + 1
end
