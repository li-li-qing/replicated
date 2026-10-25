-- Replicated Suite · 原生客户端契约
-- 作者：Replicated
-- QQ群：1104129461
-- 只登记现有 V3 需要且已验证的客户端 API/Object 契约；旧全局仅留作来源证据。
if ReplicatedSuite == nil then return end
local S = ReplicatedSuite

S.NativeContract = {
    version = 2,
    owner = "Replicated Suite",
    server = "ArcheRage RU",
    verifiedAt = "2026-08-31",
    source = "Replicated Suite curated native ABI; legacy globals are migration evidence only",

    Api = {
        -- Foundation 命名空间 ID 是 Suite 精选并保留的 ArcheAge API_TYPE ABI 副本，来源在
        -- legacy_reference/globals_archive；运行代码不读取 API_TYPE 本身。
        ADDON  = { id = 0,  nativeName = "ADDON",    foundation = true, autoImported = true },
        CHAT   = { id = 8,  nativeName = "X2Chat",   foundation = true },
        LOCALE = { id = 24, nativeName = "X2Locale", foundation = true },
        OPTION = { id = 31, nativeName = "X2Option", foundation = true },
        UNIT   = { id = 42, nativeName = "X2Unit",   foundation = true },

        -- Feature 元数据按方法能力描述（如 X2Friend:GetFriendList），原生导入按命名空间进行；NativeImports
        -- 在 ImportAPI 前将方法依赖解析为此处命名空间行。
        ABILITY              = { id = 3,  nativeName = "X2Ability",             feature = true },
        -- （2026-10-04）ACHIEVEMENT=67 来自用户工作版本 Addon1.2.zip
        -- 的 globals/apitypes.lua:114，SHA-256 08d3f23839086e97304383d1a4ebbf9926dba196a105f391c36879031a36d8a6。
        -- 仅给可见提醒的 lazy NativeImports 使用；不是 Foundation 或全部功能的必需依赖。
        ACHIEVEMENT          = { id = 67, nativeName = "X2Achievement",         feature = true },
        BAG                  = { id = 5,  nativeName = "X2Bag",                 feature = true },
        BATTLE_FIELD         = { id = 6,  nativeName = "X2BattleField",         feature = true },
        CRAFT                = { id = 9,  nativeName = "X2Craft",               feature = true },
        EQUIPMENT            = { id = 13, nativeName = "X2Equipment",           feature = true },
        FRIEND               = { id = 15, nativeName = "X2Friend",              feature = true },
        -- （2026-10-13）FAMILY=17取自用户历史Addon1.2.zip!globals/apitypes.lua，
        -- 与FRIEND=15/TEAM=38/UNIT=42同一客户端ABI；仅人员备注选家族时惰性导入，不进入Foundation依赖。
        FAMILY               = { id = 17, nativeName = "X2Family",              feature = true },
        HOTKEY               = { id = 19, nativeName = "X2Hotkey",              feature = true },
        HOUSE                = { id = 20, nativeName = "X2House",               feature = true },
        PLAYER               = { id = 32, nativeName = "X2Player",              feature = true },
        QUEST                = { id = 33, nativeName = "X2Quest",               feature = true },
        -- SKILL=35 来自本机历史 Addon.zip / Addon1.2.zip 的 globals/apitypes.lua:82。
        -- SHA-256 df8475b7cb31… / 08d3f2383908…；该表与项目已核实的 24 个 namespace 一致。
        -- 旧 Plates 也通过 ADDON:ImportAPI(API_TYPE.SKILL.id) 导入，故可确认对应 X2Skill。
        -- 仍仅供 CooldownObservationV3/SkillMetadataV3 惰性导入，不能升为全部消费者的硬依赖。
        SKILL                = { id = 35, nativeName = "X2Skill",               feature = true },
        STORE                = { id = 37, nativeName = "X2Store",               feature = true },
        TEAM                 = { id = 38, nativeName = "X2Team",                feature = true },
        BANK                 = { id = 47, nativeName = "X2Bank",                feature = true },
        COFFER               = { id = 48, nativeName = "X2Coffer",              feature = true },
        AUCTION              = { id = 51, nativeName = "X2Auction",             feature = true },
        MAP                  = { id = 54, nativeName = "X2Map",                 feature = true },
        RESIDENT             = { id = 73, nativeName = "X2Resident",            feature = true },
        EQUIP_SLOT_REINFORCE = { id = 75, nativeName = "X2EquipSlotReinforce",  feature = true },
        BUTLER               = { id = 82, nativeName = "X2Butler",              feature = true },
    },

    Object = {
        WINDOW             = { id = 0,  widgetKind = "window",      required = true },
        LABEL              = { id = 1,  widgetKind = "label",       required = true },
        BUTTON             = { id = 2,  widgetKind = "button",      required = true },
        EDITBOX            = { id = 3,  widgetKind = "editbox",     optional = true },
        EDITBOX_MULTILINE  = { id = 4,  widgetKind = "editbox",     optional = true },
        DRAWABLE           = { id = 6,  required = true },
        COLOR_DRAWABLE     = { id = 7,  required = true },
        ICON_DRAWABLE      = { id = 11, optional = true },
        TEXT_STYLE         = { id = 13, required = true },
        STATUS_BAR         = { id = 17, widgetKind = "statusbar",   optional = true },
        SLIDER             = { id = 24, widgetKind = "slider",      optional = true },
        EMPTY_WIDGET       = { id = 46, widgetKind = "emptywidget", required = true },
        -- Slot=47取自Noviern/x2的docs/reference/examples/Slot.md中的ImportObject(47)。
        -- 仅钓鱼观察惰性使用；导入失败只暂停该能力，不能升为Foundation必需对象。
        SLOT               = { id = 47, widgetKind = "slot",        optional = true },
        X2_EDITBOX         = { id = 53, widgetKind = "editbox",     optional = true },
    },

    Event = {
        ENTERED_WORLD = "ENTERED_WORLD",
        HPW_ZONE_STATE_CHANGE = "HPW_ZONE_STATE_CHANGE",
    },
}

local C = S.NativeContract

function C:GetApi(name)
    return self.Api[tostring(name or ""):upper()]
end

-- Feature 依赖写方法能力 X2Foo:Bar，ImportAPI 导入整个 X2Foo；在此映射到命名空间。
function C:ResolveApiKey(dependency)
    local value = tostring(dependency or ""):gsub("%s+", "")
    if value == "" then return nil end
    local direct = value:upper()
    if self.Api[direct] ~= nil then return direct end
    local namespace = value:match("^([^:]+):") or value
    namespace = tostring(namespace or ""):lower()
    for key, row in pairs(self.Api) do
        if type(row) == "table" and tostring(row.nativeName or ""):lower() == namespace then
            return key
        end
    end
    return nil
end

function C:GetApiForDependency(dependency)
    local key = self:ResolveApiKey(dependency)
    return key and self.Api[key] or nil, key
end

function C:GetObject(name)
    return self.Object[tostring(name or ""):upper()]
end

function C:GetObjectId(name)
    local row = self:GetObject(name)
    return type(row) == "table" and tonumber(row.id) or nil
end

function C:GetEvent(name)
    return self.Event[tostring(name or ""):upper()]
end

function C:Describe()
    local apis, objects, events = 0, 0, 0
    for _ in pairs(self.Api) do apis = apis + 1 end
    for _ in pairs(self.Object) do objects = objects + 1 end
    for _ in pairs(self.Event) do events = events + 1 end
    return {
        version = self.version,
        owner = self.owner,
        server = self.server,
        apis = apis,
        objects = objects,
        events = events,
        externalGlobalsConsumed = 0,
        legacyUiHelpersConsumed = 0,
    }
end
