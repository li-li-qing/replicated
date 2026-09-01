------------------------------------------------------------------------
-- Replicated Suite V3 - Native Contract
--
-- Suite-owned, curated ArcheRage RU client ABI used by the active V3 runtime.
-- This file deliberately contains only contracts required by migrated code.
-- New Feature migrations add their API/Object dependencies here only after the
-- corresponding client contract has been verified. Legacy globals are evidence
-- for migration only and are never a runtime Authority.
------------------------------------------------------------------------
if ReplicatedSuite == nil then return end
local S = ReplicatedSuite

S.NativeContract = {
    version = 2,
    owner = "Replicated Suite",
    server = "ArcheRage RU",
    verifiedAt = "2026-08-31",
    source = "Replicated Suite curated native ABI; legacy globals are migration evidence only",

    Api = {
        -- Foundation namespaces.  IDs are the Suite-owned curated copy of the
        -- ArcheAge API_TYPE ABI retained under legacy_reference/globals_archive;
        -- runtime code never reads API_TYPE itself.
        ADDON  = { id = 0,  nativeName = "ADDON",    foundation = true, autoImported = true },
        CHAT   = { id = 8,  nativeName = "X2Chat",   foundation = true },
        LOCALE = { id = 24, nativeName = "X2Locale", foundation = true },
        OPTION = { id = 31, nativeName = "X2Option", foundation = true },
        UNIT   = { id = 42, nativeName = "X2Unit",   foundation = true },

        -- Feature namespaces.  Native import is namespace-scoped, while
        -- Feature metadata intentionally remains method-capability scoped
        -- (for example X2Friend:GetFriendList). NativeImports resolves the
        -- method dependency to one of these namespace rows before ImportAPI.
        ABILITY              = { id = 3,  nativeName = "X2Ability",             feature = true },
        BAG                  = { id = 5,  nativeName = "X2Bag",                 feature = true },
        BATTLE_FIELD         = { id = 6,  nativeName = "X2BattleField",         feature = true },
        CRAFT                = { id = 9,  nativeName = "X2Craft",               feature = true },
        EQUIPMENT            = { id = 13, nativeName = "X2Equipment",           feature = true },
        FRIEND               = { id = 15, nativeName = "X2Friend",              feature = true },
        HOTKEY               = { id = 19, nativeName = "X2Hotkey",              feature = true },
        HOUSE                = { id = 20, nativeName = "X2House",               feature = true },
        PLAYER               = { id = 32, nativeName = "X2Player",              feature = true },
        QUEST                = { id = 33, nativeName = "X2Quest",               feature = true },
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

-- Feature metadata names user-visible method capabilities (X2Foo:Bar), while
-- ADDON:ImportAPI imports the X2Foo namespace as a whole.  Resolve that split
-- here so FeatureRuntime can stay method-specific without teaching the Native
-- layer about every individual method string.
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
