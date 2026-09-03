------------------------------------------------------------------------
-- Replicated Suite - API Capability Registry
-- Author: Replicated
-- Static overlay source: z_api_functions/api_capabilities_ru_20260828.lua
--
-- Static/official/runtime evidence are kept separate. Runtime probes are only
-- performed explicitly and only for side-effect-free getters.
-- 2026-08-28 reconciliation: 61 Unknown entries verified present in api_functions.lua
-- (RU client export manifest = official Allowed list) flipped to OfficialEnabled.
-- Only WorldToScreen remains Unknown (community global, NOT a game API).
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

S.ApiCapabilities = {
    records = {},
    aliases = {},
    updated = "2026-08-28",
    server = "ArcheRage RU",
}
local R = S.ApiCapabilities

local function NormalizeName(value)
    return tostring(value or ""):gsub("%s+", "")
end

local Copy = S.Reuse.Table.DeepCopy

local function ResolveHost(namespace)
    -- Global functions register with no namespace; resolve them against _G.
    if namespace == nil then return _G end
    if namespace == "ADDON" then return ADDON end
    if namespace == "UI" then return UI end
    if namespace == "UIParent" then return UIParent end
    return rawget(_G, namespace)
end

function R:Register(name, info)
    name = NormalizeName(name)
    if name == "" then return false end
    info = type(info) == "table" and Copy(info) or {}
    local namespace, method = string.match(name, "^([^:]+):(.+)$")
    info.Name = name
    info.Namespace = info.Namespace or namespace
    info.Method = info.Method or method
    info.StaticState = info.StaticState or "Unknown"
    info.OfficialState = info.OfficialState or "Unknown"
    info.RuntimeState = info.RuntimeState or "Unknown"
    info.LastVerified = info.LastVerified or nil
    info.Source = info.Source or "z_api_functions + RU official overlay"
    info.Risk = info.Risk or "normal"
    self.records[name] = info
    return true
end

function R:Get(name)
    name = NormalizeName(name)
    local alias = self.aliases[name]
    return self.records[alias or name]
end

function R:Describe(name)
    local info = self:Get(name)
    return info and Copy(info) or nil
end

function R:ObserveStaticState(name)
    local info = self:Get(name)
    if info == nil then return false, "unregistered capability" end
    local host = ResolveHost(info.Namespace)
    local available = host ~= nil and type(host[info.Method]) == "function"
    info.StaticState = available and "Available" or "Unavailable"
    return available, info.StaticState
end

function R:IsAllowed(name)
    local info = self:Get(name)
    if info == nil then return false, "unregistered capability" end
    local official = tostring(info.OfficialState or "Unknown")
    if official == "Removed" or official == "OfficialDisabled" then return false, official end
    local available = self:ObserveStaticState(name)
    if available ~= true then return false, "Unavailable" end
    if tostring(info.RuntimeState) == "RuntimeFailed" or tostring(info.RuntimeState) == "CrashRisk" then
        return false, info.RuntimeState
    end
    return true, nil
end

function R:MarkRuntime(name, state, note)
    local info = self:Get(name)
    if info == nil then return false end
    info.RuntimeState = tostring(state or "Unknown")
    info.LastVerified = "runtime"
    if note ~= nil then info.RuntimeNote = tostring(note) end
    return true
end

function R:ProbeGetter(name, ...)
    local info = self:Get(name)
    if info == nil then return false, nil, "unregistered capability" end
    if info.SideEffectFree ~= true then return false, nil, "probe forbidden: capability is not side-effect-free" end
    local allowed, reason = self:IsAllowed(name)
    if not allowed then return false, nil, reason end
    local host = ResolveHost(info.Namespace)
    local method = host and host[info.Method] or nil
    if type(method) ~= "function" then return false, nil, "method unavailable" end
    local args = { ... }
    local argCount = select("#", ...)
    local ok, a, b, c, d = pcall(function() return method(host, unpack(args, 1, argCount)) end)
    if not ok then
        self:MarkRuntime(name, "RuntimeFailed", a)
        return false, nil, tostring(a)
    end
    self:MarkRuntime(name, "RuntimeVerified")
    return true, a, nil, b, c, d
end

-- Current project-critical capabilities. This is deliberately a curated
-- registry, not a dump of every function in z_api_functions.
local CAPABILITIES = {
    ["ADDON:LoadData"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["ADDON:SaveData"] = { OfficialState="OfficialEnabled", Risk="write" },
    ["ADDON:ClearData"] = { OfficialState="OfficialEnabled", Risk="destructive" },
    ["ADDON:AddEscMenuButton"] = { OfficialState="OfficialChanged", Notes="4-arg form remains current project compatibility path" },
    ["ADDON:UpdateEscMenuButton"] = { OfficialState="OfficialEnabled" },
    ["ADDON:GetContent"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["ADDON:GetContentMainScriptPosVis"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Notes="authoritative native content position/visibility; used for bag/bank overlay detection" },
    ["ADDON:RegisterContentTriggerFunc"] = { OfficialState="OfficialEnabled", Risk="callback_registration" },
    ["UI:SetEventHandler"] = { OfficialState="OfficialEnabled", Risk="callback_registration", Notes="static Allowed callback registration; CombatEventBus uses only while an all-scope consumer is active" },
    ["UI:ReleaseEventHandler"] = { OfficialState="OfficialEnabled", Risk="callback_registration" },
    ["UIParent:SetEventHandler"] = { OfficialState="OfficialEnabled", Risk="callback_registration", Notes="compatibility global COMBAT_MSG host; exact handler released on demand stop" },
    ["UIParent:ReleaseEventHandler"] = { OfficialState="OfficialEnabled", Risk="callback_registration" },
    ["X2Locale:GetLocale"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Locale:LocalizeUiText"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Player:PlayerInCombat"] = { OfficialState="OfficialEnabled", Since="2026-06-09", SideEffectFree=true },
    ["X2Player:ChangeAppellation"] = { OfficialState="OfficialEnabled", Since="2026-06-09", Cooldown=2000, Restrictions={ combat=true }, Risk="write" },
    ["X2Bag:EquipBagItem"] = { OfficialState="OfficialEnabled", Since="2026-06-09", Restrictions={ combat=true }, Risk="write", Notes="combat restriction applies to documented general equip path; weapon behavior remains runtime-reconciled in Gear" },
    ["X2Bag:GetBagItemInfo"] = { OfficialState="OfficialChanged", Since="2026-04-07", SideEffectFree=true, Notes="project keeps tested (bagId, slot) signature" },
    ["X2Bag:Capacity"] = { OfficialState="OfficialEnabled", Since="2026-05-12", SideEffectFree=true },
    ["X2Bag:MoveToEmptyBankSlot"] = { OfficialState="OfficialEnabled", Since="2026-05-12", Cooldown=200, Risk="write", Notes="RU fix/cooldown update 2026-05-19; intermittent move fix 2026-06-02" },
    ["X2Bag:MoveToEmptyCofferSlot"] = { OfficialState="OfficialEnabled", Since="2026-05-12", Cooldown=200, Risk="write", Notes="RU fix/cooldown update 2026-05-19; intermittent move fix 2026-06-02" },
    ["X2Bank:GetBagItemInfo"] = { OfficialState="OfficialChanged", Since="2026-04-07", SideEffectFree=true },
    ["X2Bank:Capacity"] = { OfficialState="OfficialEnabled", Since="2026-05-12", SideEffectFree=true },
    ["X2Bank:MoveToEmptyBagSlot"] = { OfficialState="OfficialEnabled", Since="2026-05-12", Cooldown=200, Risk="write", Notes="RU fix/cooldown update 2026-05-19; intermittent move fix 2026-06-02" },
    ["X2Coffer:GetBagItemInfo"] = { OfficialState="OfficialChanged", Since="2026-04-07", SideEffectFree=true, Notes="coffer/chest slot read; category_id added 2026-05-26" },
    ["X2Coffer:Capacity"] = { OfficialState="OfficialEnabled", Since="2026-05-12", SideEffectFree=true },
    ["X2Coffer:MoveToEmptyBagSlot"] = { OfficialState="OfficialEnabled", Since="2026-05-12", Cooldown=200, Risk="write", Notes="RU fix/cooldown update 2026-05-19; intermittent move fix 2026-06-02" },
    ["X2Unit:GetUnitsInSight"] = { OfficialState="OfficialDisabled", Since="2026-06-09", StaticState="Removed", Risk="high_frequency", Notes="Disabled by RU update 2026-08-19; static list still lists it but last-write-wins is Disabled. Tombstone kept to block future re-integration." },
    ["X2Unit:UnitNameWithWorld"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Notes="world-qualified character identity for Character Override storage" },
    ["X2Unit:UnitInfo"] = { OfficialState="OfficialEnabled", Since="2026-06-02", SideEffectFree=true, Risk="expensive" },
    ["X2Unit:UnitModifierInfo"] = { OfficialState="OfficialEnabled", Since="2026-06-02", SideEffectFree=true, Risk="expensive" },
    ["X2Unit:SetOverHeadMarker"] = { OfficialState="OfficialEnabled", Since="2026-03-24", Cooldown=1000, Risk="write" },
    ["X2Unit:RemoveAllOverHeadMarker"] = { OfficialState="OfficialEnabled", Since="2026-03-24", Cooldown=1000, Risk="write" },
    ["X2Team:GetTeamRoleType"] = { OfficialState="OfficialEnabled", Since="2026-02-24", SideEffectFree=true },
    ["X2Team:GetRole"] = { OfficialState="OfficialEnabled", Since="2025-03-04", SideEffectFree=true },
    ["X2Team:SetRole"] = { OfficialState="OfficialEnabled", Since="2025-03-04", Cooldown=500, Risk="write", Notes="RU official: enabled with 500ms cooldown" },
    ["X2Team:MoveTeamMember"] = { OfficialState="OfficialEnabled", Since="2026-02-24", Cooldown=1000, Risk="write" },
    ["X2Team:MoveTeamMemberToParty"] = { OfficialState="OfficialEnabled", Since="2026-02-24", Cooldown=1000, Risk="write" },
    ["X2Team:RaidRecruitAdd"] = { OfficialState="OfficialEnabled", Since="2026-04-07", Cooldown=5000, Risk="write" },
    ["X2Team:RaidRecruitDel"] = { OfficialState="OfficialChanged", Since="2026-04-07", Cooldown=5000, Risk="write", Notes="RU 2026-07-14 removed confirmation requirement" },
    ["X2Team:GetLinkText"] = { OfficialState="OfficialEnabled", Since="2026-07-07", SideEffectFree=true },
    ["X2Team:RaidApplicantList"] = { OfficialState="OfficialEnabled", Since="2026-07-07", Cooldown=1000, Risk="server_query" },
    ["X2Team:RaidApplicantAccept"] = { OfficialState="OfficialEnabled", Since="2026-07-07", Cooldown=1000, Risk="write" },
    ["X2Team:RaidApplicantReject"] = { OfficialState="OfficialEnabled", Since="2026-07-07", Cooldown=1000, Risk="write" },
    ["X2Team:MakeTeamOwner"] = { OfficialState="OfficialEnabled", Since="2026-07-14", Cooldown=5000, Risk="write" },
    ["X2Team:InviteToTeam"] = { OfficialState="OfficialEnabled", Since="2026-07-21", Cooldown=1000, Risk="write" },
    -- IsTeamOwner sits in the static API's "Available/not allowed" section; the
    -- live client rejected it through the capability gate (2026-08-22). It is
    -- permanently fail-closed: probe flips are forbidden, no alternative
    -- permission getter may substitute, and MoveTeamMember has no reachable
    -- production path while no legal permission getter exists. Tombstone kept
    -- to block future re-integration.
    ["X2Team:IsTeamOwner"] = {
        OfficialState = "OfficialDisabled",
        StaticState = "NotAllowed",
        SideEffectFree = true,
        Risk = "permission_guard",
        Notes = "Static not-allowed; live client rejected through capability gate 2026-08-22; substitute permission getters forbidden",
    },
    ["X2Craft:GetCraftBaseInfo"] = { OfficialState="OfficialEnabled", Since="2025-04-29", SideEffectFree=true },
    ["X2Craft:GetCraftMaterialInfo"] = { OfficialState="OfficialEnabled", Since="2025-04-29", SideEffectFree=true, Notes="RU 2026-06-02 fixed the client crash in this getter" },
    ["X2Craft:GetCraftProductInfo"] = { OfficialState="OfficialEnabled", Since="2025-04-29", SideEffectFree=true },
    ["X2Craft:GetCraftTypeByItemType"] = { OfficialState="OfficialEnabled", Since="2026-06-09", SideEffectFree=true },
    ["X2Auction:SearchAuctionArticle"] = { OfficialState="OfficialEnabled", Risk="server_query" },
    ["X2Auction:GetLowestPrice"] = { OfficialState="OfficialEnabled", Since="2025-08-12", Cooldown=500, Risk="server_query", Notes="stable itemType/itemGrade auction lookup; call only from explicit user quote flow" },
    ["X2Auction:AskMarketPrice"] = { OfficialState="OfficialEnabled", Risk="server_query", Notes="explicit market-price UI query only; never background-poll" },
    ["X2Quest:IsReadyForCompleteQuest"] = { OfficialState="OfficialEnabled", Since="2026-03-31", SideEffectFree=true },
    -- Instance-entrance UI reads (RU 2026-05-19). These power the instance-raid
    -- activity rows (红龙巢穴 / 血之使者卡杜姆): the client exposes the per-account
    -- entry counter ("1/1") through GetDetailInstanceInfo, not through quests.
    -- All four are side-effect-free getters; instanceType ids are server data,
    -- so the Suite discovers the raids at runtime by matching the localized
    -- instance name and caches the resolved ids per session.
    ["X2BattleField:GetInstanceUiKindList"] = { OfficialState="OfficialEnabled", Since="2026-05-19", SideEffectFree=true },
    ["X2BattleField:GetInstanceListByKind"] = { OfficialState="OfficialEnabled", Since="2026-05-19", SideEffectFree=true },
    ["X2BattleField:GetDetailInstanceInfo"] = { OfficialState="OfficialEnabled", Since="2026-05-19", SideEffectFree=true },
    ["X2BattleField:GetInstanceName"] = { OfficialState="OfficialEnabled", Since="2026-05-19", SideEffectFree=true },

    -- Future V3 feature reservations: capabilities are registered now so
    -- implementations cannot bypass the central gate later. Registration does
    -- not start polling or enable any planned feature.
    ["X2Friend:IsMyFriend"] = { OfficialState="OfficialEnabled", Since="2026-04-28", SideEffectFree=true },
    ["X2Friend:GetFriendList"] = { OfficialState="OfficialEnabled", Since="2026-04-28", SideEffectFree=true },
    ["X2Friend:GetBlockList"] = { OfficialState="OfficialEnabled", Since="2026-08-05", SideEffectFree=true },
    ["X2Friend:BlockUser"] = { OfficialState="OfficialEnabled", Since="2026-08-05", Cooldown=1000, Risk="write" },
    ["X2Friend:UnblockUser"] = { OfficialState="OfficialEnabled", Since="2026-08-05", Cooldown=1000, Risk="write" },
    ["X2Friend:GetMuteList"] = { OfficialState="OfficialEnabled", Since="2026-08-05", SideEffectFree=true },
    ["X2Friend:MuteUser"] = { OfficialState="OfficialEnabled", Since="2026-08-05", Cooldown=1000, Risk="write" },
    ["X2Friend:UnmuteUser"] = { OfficialState="OfficialEnabled", Since="2026-08-05", Cooldown=1000, Risk="write" },
    ["X2Player:GetAppellations"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Notes="static Allowed getter; ChangeAppellation is the separately announced write" },
    ["X2Player:GetShowingAppellation"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Player:GetEffectAppellation"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2EquipSlotReinforce:GetMaterialInfo"] = { OfficialState="OfficialEnabled", Since="2026-04-28", SideEffectFree=true, Notes="RU 2026-05-12 fixed client crash" },
    ["X2EquipSlotReinforce:GetReinforceInfo"] = { OfficialState="OfficialEnabled", Since="2026-04-28", SideEffectFree=true },
    ["X2EquipSlotReinforce:GetAppliedAllSetEffect"] = { OfficialState="OfficialEnabled", Since="2026-04-28", SideEffectFree=true },
    ["X2EquipSlotReinforce:GetTotalReinforceLevel"] = { OfficialState="OfficialEnabled", Since="2026-04-28", SideEffectFree=true },
    -- Remaining X2EquipSlotReinforce getters consumed by the read-only
    -- reinforcement analysis, reconciled 2026-09-03 against the RU client export
    -- manifest (api_functions.lua lines 1855-1878, "Allowed functions"). All are
    -- SideEffectFree queries; the section's mutators (StartReinforceAddExp /
    -- StartReinforceLevelup / ChangeLevelEffect / EnableLevelUp) sit in
    -- "Available/not allowed" and are deliberately never registered, so the
    -- write path is unreachable at the gate rather than by caller convention.
    ["X2EquipSlotReinforce:GetAttributeTotalLevel"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2EquipSlotReinforce:GetNextSetApplyLevel"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2EquipSlotReinforce:HasNextSetEffect"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2EquipSlotReinforce:SuitableLevelForEquipSlotReinforce"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Notes="equipSlotIndex legal range still RU-unverified; read-only analysis probes a bounded range" },
    ["X2EquipSlotReinforce:GetBundleEffectTopLevel"] = { OfficialState="OfficialEnabled", SideEffectFree=true },

    -- Suite-owned capabilities present in the bundled static API but not
    -- explicitly re-announced by the RU official overlay. Reconciled 2026-08-28
    -- against the RU client export manifest (api_functions.lua): every entry
    -- below that the manifest exports is now OfficialEnabled (the manifest IS
    -- the official Allowed list). Static presence is still checked at the
    -- feature boundary; no write/server action is auto-probed. Only
    -- WorldToScreen stays Unknown (NOT a game API; community global only).
    ["X2Hotkey:GetOptionBinding"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Hotkey:BindingToOption"] = { OfficialState="OfficialEnabled", Since="2025-10-08", Risk="write", Restrictions={ combat=true }, Notes="RU 2026-08-19 combat restriction" },
    ["X2Hotkey:OptionToBinding"] = { OfficialState="OfficialEnabled", Since="2026-08-19", Risk="write", Restrictions={ combat=true }, Notes="RU 2026-08-19 current restricted Allowed state" },
    ["X2Hotkey:SetOptionBindingWithIndex"] = { OfficialState="OfficialEnabled", Since="2025-08-20", Risk="write", Restrictions={ combat=true }, Notes="RU 2026-08-19 combat restriction" },
    ["X2Hotkey:RemoveOptionBinding"] = { OfficialState="OfficialEnabled", Since="2026-05-12", Risk="write", Restrictions={ combat=true }, Notes="RU 2026-08-19 combat restriction" },
    ["X2Hotkey:SaveHotKey"] = { OfficialState="OfficialEnabled", Since="2025-09-17", Risk="write", Restrictions={ combat=true }, Notes="RU 2026-08-19 combat restriction" },
    ["X2Unit:UnitBuffCount"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Risk="high_frequency" },
    ["X2Unit:UnitBuff"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Risk="high_frequency" },
    ["X2Unit:UnitBuffTooltip"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Risk="expensive" },
    ["X2Unit:UnitDeBuffCount"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Risk="high_frequency" },
    ["X2Unit:UnitDeBuff"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Risk="high_frequency" },
    ["X2Unit:UnitDeBuffTooltip"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Risk="expensive" },
    ["X2Unit:UnitHiddenBuffCount"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Risk="high_frequency" },
    ["X2Unit:UnitHiddenBuff"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Risk="high_frequency" },
    ["X2Unit:UnitHiddenBuffTooltip"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Risk="expensive" },
    ["X2Unit:UnitHealth"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Risk="high_frequency" },
    ["X2Unit:UnitMaxHealth"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Risk="high_frequency" },
    ["X2Unit:UnitMana"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Risk="high_frequency" },
    ["X2Unit:UnitMaxMana"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Risk="high_frequency" },
    ["X2Unit:UnitLevel"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Unit:UnitDistance"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Risk="high_frequency" },
    ["X2Unit:UnitGearScore"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Unit:UnitCastingInfo"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Unit:GetTargetUnitId"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Unit:GetUnitId"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Unit:GetUnitNameById"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Notes="static Allowed getter; Combat UnitIdentity binds raw COMBAT_MSG ids only after exact endpoint-name verification" },
    ["X2Unit:GetUnitInfoById"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Risk="expensive", Notes="static Allowed getter; only explicit unit-kind fields are accepted fail-closed" },
    ["X2Unit:GetCurrentZoneGroup"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Unit:UnitName"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Unit:GetUnitWorldPositionByTarget"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    -- Global function (api_functions.lua:5377), registered with an explicit
    -- Method so ResolveHost(nil)->_G resolves it; no X2Unit namespace entry.
    ["ConvertWorldToScreen"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Method="ConvertWorldToScreen", Source="api_functions.lua:5377 global function", Note="Projection fallback for plate anchoring; runtime verification pending" },
    ["UIParent:GetViewCameraPos"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Source="api_functions.lua:351", Notes="camera projection fallback only; no polling outside active visual consumers" },
    ["UIParent:GetViewCameraDir"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Source="api_functions.lua:352", Notes="camera projection fallback only; no polling outside active visual consumers" },
    ["UIParent:GetViewCameraFov"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Source="api_functions.lua:361", Notes="camera projection fallback only; default FOV is used when unavailable" },
    -- NOTE: the community "WorldToScreen" global (globals/WorldToScreen.lua,
    -- easypull dependency) is a CUSTOM camera-projection helper, NOT a game
    -- API. Suite does NOT depend on it: A:ProjectWorldToScreen absorbs the same
    -- UIParent camera math internally (G1b 2026-08-24). Registered only as
    -- documentation to prevent future misuse.
    ["WorldToScreen"] = { OfficialState="Unknown", SideEffectFree=true, Method="WorldToScreen", Source="community globals/WorldToScreen.lua (NOT a game API)", Notes="custom camera projection; Suite 自有投影逻辑 (旧 rp_api 已删除), does not call this global" },
    ["X2Unit:GetTargetAbilityTemplates"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Unit:GetUnitScreenPosition"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Risk="high_frequency" },
    ["X2Option:GetConsoleVariable"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Option:SetConsoleVariable"] = { OfficialState="OfficialEnabled", Risk="write", Notes="Suite recovery path may use this before the registry loads; normal services must query the registry" },
    -- RU 2026-08-23 (P2): personal-portal option read/write. Official Allowed
    -- in api_functions.lua:3887/3889; RuntimeState Unknown until a real client
    -- toggles it next to a portal. Not a console variable -- this is a normal
    -- game option item, so the console-variable red line does not apply.
    ["X2Option:GetOptionItemValue"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Notes="personal portal option read; candidate registration P2" },
    ["X2Option:SetItemFloatValue"] = { OfficialState="OfficialEnabled", Risk="write", Notes="personal portal option write; candidate registration P2" },
    ["X2Map:GetZoneStateInfoByZoneId"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Quest:GetActiveQuestListCount"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Quest:GetActiveQuestType"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Quest:GetQuestContextMainTitle"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Quest:IsCompleted"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Achievement:GetTodayAssignmentInfo"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Equipment:GetEquippedItemTooltipInfo"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Notes="targetEquippedItem flag silently ignored on current RU client: always returns the player's OWN gear (real-machine evidence 2026-09-01); never use for target-scope reads" },
    ["X2Auction:GetSearchedItemCount"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Auction:GetSearchedItemInfo"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Resident:GetResidentBoardContent"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Store:GetProductionZoneGroups"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Store:GetSellableZoneGroups"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Ability:GetAllMyActabilityInfos"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Ability:GetBuffTooltip"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Risk="expensive", Notes="buff-id -> icon/name resolution fallback, cached" },
    ["X2Skill:GetCooldown"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Notes="skill cooldown query; reserved for cooldown display features" },
    ["X2Equipment:GetEquippedItemType"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Notes="equip slot type query; reserved for gear/plates rebuilds" },
    ["X2Mate:IsPlayerPetExists"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Notes="pet/mate existence; reserved for healer summon handling" },
    ["X2Store:GetSpecialtyRatioBetween"] = { OfficialState="OfficialEnabled", Risk="server_query" },
    -- X2House getters (RU 2026-08-19). Candidate registration only: no
    -- business wiring, no auto-probe, no runtime verification until a manual
    -- read-only check beside a house.
    ["X2House:GetCurrentHousingTaxInfo"] = { OfficialState="OfficialEnabled", Since="2026-08-19", SideEffectFree=true, Notes="仅登记,尚未接业务,等待住宅旁真机只读验证" },
    ["X2House:GetHouseOwnerName"] = { OfficialState="OfficialEnabled", Since="2026-08-19", SideEffectFree=true, Notes="仅登记,尚未接业务,等待住宅旁真机只读验证" },
    ["X2House:GetHouseName"] = { OfficialState="OfficialEnabled", Since="2026-08-19", SideEffectFree=true, Notes="仅登记,尚未接业务,等待住宅旁真机只读验证" },
    ["X2House:GetHouseType"] = { OfficialState="OfficialEnabled", Since="2026-08-19", SideEffectFree=true, Notes="仅登记,尚未接业务,等待住宅旁真机只读验证" },
    -- RU 2026-08-26 official additions. They are deliberately only registered:
    -- no automatic probing, polling, or feature startup is introduced here.
    ["X2Butler:GetChargeInfo"] = { OfficialState="OfficialEnabled", Since="2026-08-26", SideEffectFree=true, Notes="管家能力面仍很窄；等待管家上下文真机核对返回结构" },
    ["X2Store:GetRandomShopStoreRefreshCount"] = { OfficialState="OfficialEnabled", Since="2026-08-26", SideEffectFree=true, Notes="只登记刷新计数 getter，不推断其它随机商店 API 已开放" },
    ["X2Input:GetMousePos"] = { OfficialState="OfficialEnabled", Since="2026-08-26", SideEffectFree=true, Risk="interactive", Notes="未来 RSUI 指针/交互诊断候选；不替换已稳定的 Native drag transaction" },
}
for name, info in pairs(CAPABILITIES) do R:Register(name, info) end

R:Register("UNIT_ENTERED_SIGHT", { OfficialState="Removed", Since="2026-06-09", StaticState="Removed", Risk="removed_event" })
R:Register("UNIT_LEAVED_SIGHT", { OfficialState="Removed", Since="2026-06-09", StaticState="Removed", Risk="removed_event" })
