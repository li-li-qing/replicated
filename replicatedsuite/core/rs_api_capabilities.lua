-- Replicated Suite · API 能力登记与门禁
-- 作者：Replicated
-- QQ群：1104129461
-- 静态覆盖来源：z_api_functions/api_capabilities_ru_20260828.lua；静态、官方和运行证据分开保存。
-- 探测仅限显式触发的无副作用 getter。2026-08-28 已按 RU Allowed 导出清单核实 61 个 Unknown 项。
-- 社区函数 WorldToScreen 不是游戏 API，仍标为 Unknown。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

S.ApiCapabilities = {
    records = {},
    aliases = {},
    updated = "2026-10-07",
    server = "ArcheRage RU",
}
local R = S.ApiCapabilities

local function NormalizeName(value)
    return tostring(value or ""):gsub("%s+", "")
end

local Copy = S.Reuse.Table.DeepCopy

local function ResolveHost(namespace)
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

local CAPABILITIES = {
    ["ADDON:LoadData"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["ADDON:SaveData"] = { OfficialState="OfficialEnabled", Risk="write" },
    ["ADDON:ClearData"] = { OfficialState="OfficialEnabled", Risk="destructive" },
    -- SetClipboardText 在随包参考的 Available/not allowed 区段，不能因符号存在而调用或探测。
    -- 报告使用已验证的输入框，由用户 Ctrl+C 复制。
    ["ADDON:SetClipboardText"] = { OfficialState="OfficialDisabled", Risk="write", SideEffectFree=false,
        Source="z_api_functions/api_functions.lua ADDON Available/not allowed functions",
        Notes="not permitted by bundled manifest; never probe or call for report copy" },
    ["ADDON:AddEscMenuButton"] = { OfficialState="OfficialChanged", Notes="4-arg form remains current project compatibility path" },
    ["ADDON:UpdateEscMenuButton"] = { OfficialState="OfficialEnabled" },
    ["ADDON:GetContent"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["ADDON:ShowContent"] = { OfficialState="OfficialEnabled", Risk="ui", Notes="static Allowed UI entry; hotkey profiles open the native settings only on explicit click" },
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
    -- IsTeamOwner 在 Available/not allowed 区段，且 2026-08-22 实机拒读；保留禁止记录，不能靠探测解除。
    -- 缺少合法权限 getter 时，MoveTeamMember 必须保持不可调用。
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
    ["X2Auction:AskMarketPrice"] = { OfficialState="OfficialEnabled", Since="2025-08-12", Cooldown=500, Risk="server_query", Notes="explicit market-price request paired with paced GetLowestPrice readback; askMarketPriceUi=false for addon quotes; never background-poll" },
    ["X2Quest:IsReadyForCompleteQuest"] = { OfficialState="OfficialEnabled", Since="2026-03-31", SideEffectFree=true },
    -- 副本入口只读接口（RU 2026-05-19）。红龙巢穴、卡杜姆的账号次数来自 GetDetailInstanceInfo，不来自任务。
    -- instanceType 由服务器提供，按本地化名称解析并在会话内缓存。
    ["X2BattleField:GetInstanceUiKindList"] = { OfficialState="OfficialEnabled", Since="2026-05-19", SideEffectFree=true },
    ["X2BattleField:GetInstanceListByKind"] = { OfficialState="OfficialEnabled", Since="2026-05-19", SideEffectFree=true },
    ["X2BattleField:GetDetailInstanceInfo"] = { OfficialState="OfficialEnabled", Since="2026-05-19", SideEffectFree=true },
    ["X2BattleField:GetInstanceName"] = { OfficialState="OfficialEnabled", Since="2026-05-19", SideEffectFree=true },

    ["X2Friend:IsMyFriend"] = { OfficialState="OfficialEnabled", Since="2026-04-28", SideEffectFree=true },
    ["X2Friend:GetFriendList"] = { OfficialState="OfficialEnabled", Since="2026-04-28", SideEffectFree=true },
    -- 本地 Allowed 清单及 RU 2026-04-28 公告已开放此名单 getter。
    -- 消费者仍须校验字段，nil/拒读时按不可用处理；这不代表 Family 写接口开放。
    ["X2Family:GetMemberList"] = { OfficialState="OfficialEnabled", Since="2026-04-28", SideEffectFree=true },
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
    -- 只读 getter 已按 2026-09-03 RU 导出清单核实（api_functions.lua:1855-1878）。
    -- StartReinforceAddExp / StartReinforceLevelup / ChangeLevelEffect / EnableLevelUp 属于 Available/not allowed，不登记写能力。
    ["X2EquipSlotReinforce:GetAttributeTotalLevel"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2EquipSlotReinforce:GetNextSetApplyLevel"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2EquipSlotReinforce:HasNextSetEffect"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2EquipSlotReinforce:SuitableLevelForEquipSlotReinforce"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Notes="equipSlotIndex legal range still RU-unverified; read-only analysis probes a bounded range" },
    ["X2EquipSlotReinforce:GetBundleEffectTopLevel"] = { OfficialState="OfficialEnabled", SideEffectFree=true },

    -- 以下接口已于 2026-08-28 按 api_functions.lua 的 Allowed 清单核实，标为 OfficialEnabled。
    -- 调用时仍检查符号存在；不能自动探测写入或服务器动作。
    ["X2Hotkey:GetOptionBinding"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    -- RU 2025-08-20 开放的宠物按钮读写；能力登记保留官方事实，不会自动调用接口。
    -- 官方按钮 setter 文档漏列 index；原生设置页使用第三参 manager 1/2，所有写入仍须非战斗+读回。
    ["X2Hotkey:GetOptionBindingButton"] = { OfficialState="OfficialEnabled", Since="2025-08-20", SideEffectFree=true },
    ["X2Hotkey:SetOptionBindingButtonWithIndex"] = { OfficialState="OfficialEnabled", Since="2025-08-20", Risk="write", Restrictions={ combat=true }, Notes="RU 2026-08-19 combat restriction; third manager argument follows native UI, requires full readback" },
    -- 只用于用户操作前的白名单预检；事务仍由 Feature 执行。
    -- 不能枚举猜测 action 名，也不能借此绕过战斗写限制。
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
    -- 全局函数（api_functions.lua:5377）从 _G 解析，不挂到 X2Unit 命名空间。
    ["ConvertWorldToScreen"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Method="ConvertWorldToScreen", Source="api_functions.lua:5377 global function", Note="Projection fallback for plate anchoring; runtime verification pending" },
    ["UIParent:GetViewCameraPos"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Source="api_functions.lua:351", Notes="camera projection fallback only; no polling outside active visual consumers" },
    ["UIParent:GetViewCameraDir"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Source="api_functions.lua:352", Notes="camera projection fallback only; no polling outside active visual consumers" },
    ["UIParent:GetViewCameraFov"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Source="api_functions.lua:361", Notes="camera projection fallback only; RangeAssist requires a verified FOV; legacy projection keeps its default fallback" },
    -- WorldToScreen 来自社区 globals/WorldToScreen.lua，不是游戏 API。
    -- Suite 使用 ScreenProjectionV3 内的兼容实现，不依赖这个全局符号。
    ["WorldToScreen"] = { OfficialState="Unknown", SideEffectFree=true, Method="WorldToScreen", Source="community globals/WorldToScreen.lua (NOT a game API)", Notes="custom camera projection; Suite 自有投影逻辑 (旧 rp_api 已删除), does not call this global" },
    ["X2Unit:GetTargetAbilityTemplates"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Unit:GetUnitScreenPosition"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Risk="high_frequency" },
    ["X2Option:GetConsoleVariable"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Option:SetConsoleVariable"] = { OfficialState="OfficialEnabled", Risk="write", Notes="Suite recovery path may use this before the registry loads; normal services must query the registry" },
    -- 传送门选项读写已在 RU 2026-08-23 开放（api_functions.lua:3887/3889）。
    -- 实机传送门旁验证切换前，RuntimeState 保持 Unknown；它是游戏选项，不是控制台变量。
    ["X2Option:GetOptionItemValue"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Notes="personal portal option read; candidate registration P2" },
    ["X2Option:SetItemFloatValue"] = { OfficialState="OfficialEnabled", Risk="write", Notes="personal portal option write; candidate registration P2" },
    ["X2Map:GetZoneStateInfoByZoneId"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    -- ShowWorldmapLocation 自 RU 2025-11 起首参为 zoneGroupId，随后为全局 x/y/z。
    -- TreasureMapHunter 也使用 targetZone,targetX,targetY,0，首参不能填固定 MapContext。
    -- 仅响应用户点击，并保留 250ms 冷却；定位失败不能改动寻宝存档。
    ["X2Map:ShowWorldmapLocation"] = { OfficialState="OfficialEnabled", Cooldown=250, Risk="write", SideEffectFree=false,
        Source="user-supplied TreasureMapHunter RU addon + bundled api_functions.lua Allowed list", Notes="explicit treasure-map world-map location only" },
    ["X2Quest:GetActiveQuestListCount"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Quest:GetActiveQuestType"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Quest:GetQuestContextMainTitle"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    -- 2026-09-09 RU 官方公告开放任务目标只读入口；不等于返回形态已实机验收。
    -- 唯一消费者 QuestProgress 的显式详情读取；不能用奖励文案代替收益记账。
    ["X2Quest:GetQuestJournalObjectiveCount"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Since="2026-09-09", Source="https://ru.archerage.to/forums/threads/obnovlenie-09-09-2026.17558/" },
    ["X2Quest:GetQuestJournalObjectiveText"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Since="2026-09-09", Source="https://ru.archerage.to/forums/threads/obnovlenie-09-09-2026.17558/" },
    ["X2Quest:IsCompleted"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Achievement:GetTodayAssignmentInfo"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Equipment:GetEquippedItemTooltipInfo"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Notes="RU selector semantics are consumer-sensitive in observed builds: HUD self-read remains false; GearV3 loadout reconciliation uses the legacy-proven true path. Target HUD must not use this API as target Authority." },
    ["X2Auction:GetSearchedItemCount"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    -- Allowed 参考及 RU 官方 07.05.2025 更新：查询搜索总覆盖范围，不修改排序。
    ["X2Auction:GetSearchedItemTotalCount"] = { OfficialState="OfficialEnabled", Since="2025-05-07", SideEffectFree=true },
    ["X2Auction:GetSearchedItemInfo"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Resident:GetResidentBoardContent"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Store:GetProductionZoneGroups"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Store:GetSellableZoneGroups"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Ability:GetAllMyActabilityInfos"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Ability:GetBuffTooltip"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Risk="expensive", Notes="buff-id -> icon/name resolution fallback, cached" },
    ["X2Skill:GetCooldown"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Notes="skill cooldown query; reserved for cooldown display features" },
    -- GetMateCooldown 已在 RU 2025-09 开放；mateType：1 骑乘，2 战斗。
    -- CooldownObservationV3 只读用户追踪的本机 ID：self 走 COMBAT_MSG，mate 等由 500ms 轮转补读。
    -- 不扫描未追踪库，不为 CD 订阅全场战斗事件，也不把本机读数或静态 expectedSec 当成远端状态。
    ["X2Skill:GetMateCooldown"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Since="2025-09-16", Notes="mate cooldown query; mateType 1=ride, 2=battle; local cooldown authority only" },
    -- equipSlot 参数使用 ES_* 实际槽号，返回值才是物品 ItemType。
    -- EST_* 表示槽类型，曾因误传 EST_BACKPACK 而持续读空；缺少 ES_* 时只用已验证槽号。
    ["X2Equipment:GetEquippedItemType"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Notes="actual equipment slot index (ES_*) -> equipped itemType; do not pass EST_* slot-type constants" },
    ["X2Mate:IsPlayerPetExists"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Notes="pet/mate existence; reserved for healer summon handling" },
    ["X2Store:GetSpecialtyRatioBetween"] = { OfficialState="OfficialEnabled", Risk="server_query" },
    -- X2House getter（RU 2026-08-19）仅登记候选，不接业务、不自动探测；须在房屋旁手动只读核验后才能认定运行验证。
    ["X2House:GetCurrentHousingTaxInfo"] = { OfficialState="OfficialEnabled", Since="2026-08-19", SideEffectFree=true, Notes="仅登记,尚未接业务,等待住宅旁真机只读验证" },
    ["X2House:GetHouseOwnerName"] = { OfficialState="OfficialEnabled", Since="2026-08-19", SideEffectFree=true, Notes="仅登记,尚未接业务,等待住宅旁真机只读验证" },
    ["X2House:GetHouseName"] = { OfficialState="OfficialEnabled", Since="2026-08-19", SideEffectFree=true, Notes="仅登记,尚未接业务,等待住宅旁真机只读验证" },
    ["X2House:GetHouseType"] = { OfficialState="OfficialEnabled", Since="2026-08-19", SideEffectFree=true, Notes="仅登记,尚未接业务,等待住宅旁真机只读验证" },
    -- RU 2026-08-26 官方新增接口仅登记，不自动探测、轮询或启动功能。
    ["X2Butler:GetChargeInfo"] = { OfficialState="OfficialEnabled", Since="2026-08-26", SideEffectFree=true, Notes="管家能力面仍很窄；等待管家上下文真机核对返回结构" },
    ["X2Store:GetRandomShopStoreRefreshCount"] = { OfficialState="OfficialEnabled", Since="2026-08-26", SideEffectFree=true, Notes="只登记刷新计数 getter，不推断其它随机商店 API 已开放" },
    ["X2Input:GetMousePos"] = { OfficialState="OfficialEnabled", Since="2026-08-26", SideEffectFree=true, Risk="interactive", Notes="未来 RSUI 指针/交互诊断候选；不替换已稳定的 Native drag transaction" },
}
for name, info in pairs(CAPABILITIES) do R:Register(name, info) end

R:Register("UNIT_ENTERED_SIGHT", { OfficialState="Removed", Since="2026-06-09", StaticState="Removed", Risk="removed_event" })
R:Register("UNIT_LEAVED_SIGHT", { OfficialState="Removed", Since="2026-06-09", StaticState="Removed", Risk="removed_event" })
