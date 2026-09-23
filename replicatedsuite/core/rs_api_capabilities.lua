-- 维护（2026-09-18，startup-source-recovery）：本文件在故障包中有 1 处未解决的 Git 合并冲突。
-- 已对照用户此前完整 V3 工程恢复有效实现；Authority、调用数据流和存档协议仍由下方原实现负责，
-- 不通过清配置、跳过加载或恢复 Legacy 绕过错误。兼容边界：须与完整 toc.g 及 .18.247 UI 配套；
-- 后续合并必须先检查冲突标记、清单完整性与 Lua 语法，再做运行时验收；注释不增加运行期开销。
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
    updated = "2026-09-23", -- 中文维护：hotkey-profile-v2 只补入 RU 2025-08-20 官方已开放的 action 验证 getter；不扩大任何写能力。
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
    -- 维护（2026-09-12）：旧补丁只按函数名搜索，误把 ADDON 的 Available/not allowed
    -- 区段当成 Allowed。SetClipboardText 位于前者，不能因全局函数存在就调用/探测。
    -- 保留显式禁止记录防止后续回归；不是声明新的服务端公告，依据仅为随包参考区段。
    -- 报告复制改走已验证UI输入框的用户 Ctrl+C，不转用未验证 Message/系统接口绕过门禁。
    ["ADDON:SetClipboardText"] = { OfficialState="OfficialDisabled", Risk="write", SideEffectFree=false,
        Source="z_api_functions/api_functions.lua ADDON Available/not allowed functions",
        Notes="not permitted by bundled manifest; never probe or call for report copy" },
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
    ["X2Unit:GetOverHeadMarker"] = { OfficialState="OfficialEnabled", Since="2026-03-24", SideEffectFree=true },
    ["X2Unit:GetOverHeadMarkerUnitId"] = { OfficialState="OfficialEnabled", Since="2026-03-24", SideEffectFree=true },
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
    -- 中文维护（hotkey-profile-v2）：下面两个 getter 只用于显式用户操作前的白名单安全预检；
    -- Authority 仍在 Feature 事务层，绝不能拿它们去循环猜 action 名、建立后台枚举或绕过战斗写限制。
    ["X2Hotkey:IsValidActionName"] = { OfficialState="OfficialEnabled", Since="2025-08-20", SideEffectFree=true, Notes="RU official hotkey action validation; used only for explicit bounded whitelist preflight" },
    ["X2Hotkey:IsOverridableAction"] = { OfficialState="OfficialEnabled", Since="2025-08-20", SideEffectFree=true, Notes="RU official hotkey override validation; used only for explicit bounded whitelist preflight" },
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
    -- API. Suite does NOT depend on the global symbol: ScreenProjectionV3 contains an
    -- EasyPull-compatible private fallback using the same UIParent camera math. Registered only as
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
    -- 中文维护注释（2026-09-19，寻宝原生地图定位）：RU 2025-11 后 ShowWorldmapLocation 的首参明确为 zoneGroupId，后接全局 x/y/z。
    -- 参考 TreasureMapHunter 的实际调用也是 targetZone,targetX,targetY,0；禁止再把首参当成固定 MapContext 魔数。这里仍只登记显式用户点击触发的 UI 定位动作，
    -- 不允许 Scheduler/Tick 自动调用；250ms 冷却防止双击/连点反复打开地图。Treasure Feature 经 ActionCapability fail-closed，地图定位失败不会污染持久化 Authority。
    ["X2Map:ShowWorldmapLocation"] = { OfficialState="OfficialEnabled", Cooldown=250, Risk="write", SideEffectFree=false,
        Source="user-supplied TreasureMapHunter RU addon + bundled api_functions.lua Allowed list", Notes="explicit treasure-map world-map location only" },
    ["X2Quest:GetActiveQuestListCount"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Quest:GetActiveQuestType"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Quest:GetQuestContextMainTitle"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    -- 维护：2026-09-09 RU 官方公告开放任务目标只读入口；不等于返回形态已实机验收。
    -- 唯一消费者 QuestProgress 的显式详情读取；不能用奖励文案代替收益记账。
    ["X2Quest:GetQuestJournalObjectiveCount"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Since="2026-09-09", Source="https://ru.archerage.to/forums/threads/obnovlenie-09-09-2026.17558/" },
    ["X2Quest:GetQuestJournalObjectiveText"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Since="2026-09-09", Source="https://ru.archerage.to/forums/threads/obnovlenie-09-09-2026.17558/" },
    ["X2Quest:IsCompleted"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Achievement:GetTodayAssignmentInfo"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Equipment:GetEquippedItemTooltipInfo"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Notes="RU selector semantics are consumer-sensitive in observed builds: HUD self-read remains false; GearV3 loadout reconciliation uses the legacy-proven true path. Target HUD must not use this API as target Authority." },
    ["X2Auction:GetSearchedItemCount"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Auction:GetSearchedItemInfo"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Resident:GetResidentBoardContent"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Store:GetProductionZoneGroups"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Store:GetSellableZoneGroups"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Ability:GetAllMyActabilityInfos"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Ability:GetBuffTooltip"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Risk="expensive", Notes="buff-id -> icon/name resolution fallback, cached" },
    ["X2Skill:GetCooldown"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Notes="skill cooldown query; reserved for cooldown display features" },
    -- 中文维护注释（2026-09-19，坐骑/战斗宠物 CD）：RU 官方 2025-09 已开放 GetMateCooldown。
    -- Authority/数据流：只允许 CooldownObservationV3 对用户已追踪 ID 读取本机 Native CD；COMBAT_MSG 仅使用 self 快路，
    -- 500ms 有界 round-robin 补 mate/无战斗事件/重载中途覆盖，不扫描未追踪库，也不为 CD 开启全场战斗事件。mateType 1=ride/2=battle。
    -- 它是只读本地事实，不代表远端玩家状态，也禁止静态 expectedSec 伪造。
    ["X2Skill:GetMateCooldown"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Since="2025-09-16", Notes="mate cooldown query; mateType 1=ride, 2=battle; local cooldown authority only" },
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
