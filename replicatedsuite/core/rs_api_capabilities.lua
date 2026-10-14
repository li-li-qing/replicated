------------------------------------------------------------------------
-- Replicated Suite · API 能力登记与门禁
-- 作者：Replicated
-- QQ群：1104129461
--
-- API 能力登记表。静态覆盖来源：z_api_functions/api_capabilities_ru_20260828.lua。静态、官方与运行证据分别
-- 保存；运行探测须显式触发且仅限无副作用 getter。2026-08-28 对账确认 api_functions.lua（RU 客户端导出清单，
-- 也是官方 Allowed 清单）中 61 个 Unknown 项存在，已标为 OfficialEnabled；仅社区全局函数 WorldToScreen 保持
-- Unknown，它不是游戏 API。合并必须先检查冲突标记、完整 toc.g 和 Lua 语法，再做运行验收；不得通过清配置、跳
-- 过加载或恢复 Legacy 绕过错误，Authority、数据流及存档协议由各自实现负责。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

S.ApiCapabilities = {
    records = {},
    aliases = {},
    updated = "2026-10-07", -- 用户删除快捷键方案，撤下其独用目录探测登记；共享键位能力保留战斗写限制。
    server = "ArcheRage RU",
}
local R = S.ApiCapabilities

local function NormalizeName(value)
    return tostring(value or ""):gsub("%s+", "")
end

local Copy = S.Reuse.Table.DeepCopy

local function ResolveHost(namespace)
    -- 全局函数不登记命名空间，直接在 _G 中解析。
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

-- 这里只精选项目关键能力，不照搬 z_api_functions 的全部函数。
local CAPABILITIES = {
    ["ADDON:LoadData"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["ADDON:SaveData"] = { OfficialState="OfficialEnabled", Risk="write" },
    ["ADDON:ClearData"] = { OfficialState="OfficialEnabled", Risk="destructive" },
    -- SetClipboardText 位于 ADDON 的 Available/not allowed 区段，不能因全局函数存在就调用或探测。显式禁止记
    -- 录依据随包参考区段，不代表新的服务端公告。报告通过已验证 UI 输入框由用户 Ctrl+C 复制，不用未验证
    -- Message 或系统接口绕过门禁。
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
    -- IsTeamOwner 位于静态 API 的 "Available/not allowed" 区段；实机能力门禁于 2026-08-22 拒绝读取。必须持
    -- 续失败封闭：禁止探测翻转，禁止替代权限 getter；没有合法权限 getter 时 MoveTeamMember 不得有可达生产路
    -- 径，保留禁止记录以防重新接入。
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
    -- 副本入口 UI 只读接口（RU 2026-05-19）用于红龙巢穴、血之使者卡杜姆活动行；账号进入次数 "1/1" 由
    -- GetDetailInstanceInfo 提供，不来自任务。四个 getter 均无副作用；instanceType 是服务器数据，运行时按本
    -- 地化副本名匹配，并在会话内缓存解析 ID。
    ["X2BattleField:GetInstanceUiKindList"] = { OfficialState="OfficialEnabled", Since="2026-05-19", SideEffectFree=true },
    ["X2BattleField:GetInstanceListByKind"] = { OfficialState="OfficialEnabled", Since="2026-05-19", SideEffectFree=true },
    ["X2BattleField:GetDetailInstanceInfo"] = { OfficialState="OfficialEnabled", Since="2026-05-19", SideEffectFree=true },
    ["X2BattleField:GetInstanceName"] = { OfficialState="OfficialEnabled", Since="2026-05-19", SideEffectFree=true },

    -- 预留 V3 功能能力先在中央登记，避免后续实现绕过门禁。登记本身不会启动轮询或启用计划中的功能。
    ["X2Friend:IsMyFriend"] = { OfficialState="OfficialEnabled", Since="2026-04-28", SideEffectFree=true },
    ["X2Friend:GetFriendList"] = { OfficialState="OfficialEnabled", Since="2026-04-28", SideEffectFree=true },
    -- （2026-10-13）本地Allowed清单及RU 2026-04-28公告已开放此getter；只读成员名单，
    -- 返回字段仍由消费者保守校验，nil/拒读必须降级不可用，不能据此开放Family写接口。
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
    -- 强化分析消费的其余 X2EquipSlotReinforce getter，依据 2026-09-03 RU 导出清单对账（
    -- api_functions.lua:1855-1878，"Allowed functions"）；全部为 SideEffectFree 查询。StartReinforceAddExp
    -- / StartReinforceLevelup / ChangeLevelEffect / EnableLevelUp 位于 "Available/not allowed"，不予登记，
    -- 使写路径在门禁处不可达，而非只靠调用者约定。
    ["X2EquipSlotReinforce:GetAttributeTotalLevel"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2EquipSlotReinforce:GetNextSetApplyLevel"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2EquipSlotReinforce:HasNextSetEffect"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2EquipSlotReinforce:SuitableLevelForEquipSlotReinforce"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Notes="equipSlotIndex legal range still RU-unverified; read-only analysis probes a bounded range" },
    ["X2EquipSlotReinforce:GetBundleEffectTopLevel"] = { OfficialState="OfficialEnabled", SideEffectFree=true },

    -- 随包静态 API 中存在、RU 官方覆盖未单独重述的 Suite 能力，已在 2026-08-28 对照 api_functions.lua 导出
    -- 清单核实。清单就是官方 Allowed 列表，其中导出的下列接口标为 OfficialEnabled；功能边界仍检查静态存在性
    -- ，绝不自动探测写入或服务器动作。WorldToScreen 仅为社区全局函数，仍保持 Unknown。
    ["X2Hotkey:GetOptionBinding"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    -- RU 2025-08-20 开放的宠物按钮读写；能力登记保留官方事实，不会自动调用接口。
    -- 官方按钮 setter 文档漏列 index；原生设置页使用第三参 manager 1/2，所有写入仍须非战斗+读回。
    ["X2Hotkey:GetOptionBindingButton"] = { OfficialState="OfficialEnabled", Since="2025-08-20", SideEffectFree=true },
    ["X2Hotkey:SetOptionBindingButtonWithIndex"] = { OfficialState="OfficialEnabled", Since="2025-08-20", Risk="write", Restrictions={ combat=true }, Notes="RU 2026-08-19 combat restriction; third manager argument follows native UI, requires full readback" },
    -- 下面两个 getter 只用于显式用户操作前的白名单安全预检；
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
    -- 全局函数（api_functions.lua:5377）显式登记 Method，使 ResolveHost(nil)->_G 能解析；不登记 X2Unit 命名空间。
    ["ConvertWorldToScreen"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Method="ConvertWorldToScreen", Source="api_functions.lua:5377 global function", Note="Projection fallback for plate anchoring; runtime verification pending" },
    ["UIParent:GetViewCameraPos"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Source="api_functions.lua:351", Notes="camera projection fallback only; no polling outside active visual consumers" },
    ["UIParent:GetViewCameraDir"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Source="api_functions.lua:352", Notes="camera projection fallback only; no polling outside active visual consumers" },
    ["UIParent:GetViewCameraFov"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Source="api_functions.lua:361", Notes="camera projection fallback only; RangeAssist requires a verified FOV; legacy projection keeps its default fallback" },
    -- 社区 WorldToScreen（globals/WorldToScreen.lua，easypull 依赖）是自定义摄像机投影辅助函数，不是游戏
    -- API。Suite 不依赖该全局符号；ScreenProjectionV3 提供使用相同 UIParent 摄像机数学的 EasyPull 兼容私有
    -- 兜底。这里只登记事实以避免误用。
    ["WorldToScreen"] = { OfficialState="Unknown", SideEffectFree=true, Method="WorldToScreen", Source="community globals/WorldToScreen.lua (NOT a game API)", Notes="custom camera projection; Suite 自有投影逻辑 (旧 rp_api 已删除), does not call this global" },
    ["X2Unit:GetTargetAbilityTemplates"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Unit:GetUnitScreenPosition"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Risk="high_frequency" },
    ["X2Option:GetConsoleVariable"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    ["X2Option:SetConsoleVariable"] = { OfficialState="OfficialEnabled", Risk="write", Notes="Suite recovery path may use this before the registry loads; normal services must query the registry" },
    -- 个人传送门选项读写（RU 2026-08-23），官方 Allowed 证据位于 api_functions.lua:3887/3889；在实机传送门
    -- 旁完成切换前 RuntimeState 保持 Unknown。这是普通游戏选项，不是控制台变量，因此不适用控制台变量限制。
    ["X2Option:GetOptionItemValue"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Notes="personal portal option read; candidate registration P2" },
    ["X2Option:SetItemFloatValue"] = { OfficialState="OfficialEnabled", Risk="write", Notes="personal portal option write; candidate registration P2" },
    ["X2Map:GetZoneStateInfoByZoneId"] = { OfficialState="OfficialEnabled", SideEffectFree=true },
    -- （2026-09-19，寻宝原生地图定位）RU 2025-11 后 ShowWorldmapLocation 的首参明确为 zoneGroupId，后接全局
    -- x/y/z。
    -- 参考 TreasureMapHunter 的实际调用也是 targetZone,targetX,targetY,0；禁止再把首参当成固定 MapContext
    -- 魔数。这里仍只登记显式用户点击触发的 UI 定位动作，
    -- 不允许 Scheduler/Tick 自动调用；250ms 冷却防止双击/连点反复打开地图。Treasure Feature 经
    -- ActionCapability fail-closed，地图定位失败不会污染持久化 Authority。
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
    -- （2026-09-19，坐骑/战斗宠物 CD）RU 官方 2025-09 已开放 GetMateCooldown。
    -- Authority/数据流：只允许 CooldownObservationV3 对用户已追踪 ID 读取本机 Native CD；COMBAT_MSG 仅使用
    -- self 快路，
    -- 500ms 有界 round-robin 补 mate/无战斗事件/重载中途覆盖，不扫描未追踪库，也不为 CD 开启全场战斗事件。
    -- mateType：1 表示骑乘，2 表示战斗。
    -- 它是只读本地事实，不代表远端玩家状态，也禁止静态 expectedSec 伪造。
    ["X2Skill:GetMateCooldown"] = { OfficialState="OfficialEnabled", SideEffectFree=true, Since="2025-09-16", Notes="mate cooldown query; mateType 1=ride, 2=battle; local cooldown authority only" },
    -- （2026-09-25，equipment-slot-namespace-1）该 API 的参数名 equipSlot 指实际 ES_* 槽位编号，
    -- 返回值才是装备物品 ItemType。EST_* 是 Equip Slot Type 命名空间，不能直接作为 locator；18.307 跑商
    -- 曾因此把 EST_BACKPACK 当背包槽读取并稳定得到空值。所有新消费者必须优先 ES_*，缺失时只能使用已验证槽号。
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
