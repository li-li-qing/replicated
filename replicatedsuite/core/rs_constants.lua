------------------------------------------------------------------------
-- Replicated Suite - Constants
-- Author: Replicated
------------------------------------------------------------------------

if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

local GameIds = S.GameIds or {}
local ItemIds = GameIds.Item or {}
local QuestIds = GameIds.Quest or {}
local ResidentBondQuestIds = QuestIds.ResidentBond or {}
if ItemIds.BLUE_SALT_BOND == nil or type(ItemIds.BOND_MATERIAL) ~= "table"
    or type(ResidentBondQuestIds.MaterialByQuantity) ~= "table"
    or type(ResidentBondQuestIds.AuroriaByTokenQuantity) ~= "table" then
    S.BootError = "shared item/quest ID catalog unavailable"
    return
end

S.Constants = {
    -- Schema 21: module enabled state and team/damage-review feature toggles
    -- moved from Character Override to the Account base (usage habits persist
    -- across characters and no longer depend on world-qualified identity
    -- matching at load time). Schema 20->21 migration folds previously saved
    -- override modules/settings into the Account base on first load.
    SaveSchemaVersion = 21,
    -- Reusable game IDs are owned by data/ids/*.lua. Constants consumes that
    -- shared catalog and does not keep a second copy of the numeric IDs.
    BlueSaltBondItemType = ItemIds.BLUE_SALT_BOND,
    BondMaterialItemTypes = ItemIds.BOND_MATERIAL,
    BondQuestByMaterialQuantity = ResidentBondQuestIds.MaterialByQuantity,
    -- Official/current ArcheRage Auroria resident daily quest mapping.
    -- Resolver matches the resident-board item name and requested quantity.
    AuroriaBondQuestByTokenQuantity = ResidentBondQuestIds.AuroriaByTokenQuantity,

    Breakpoint = { COMPACT = 1150, STANDARD = 1700, WIDE = 2300, NARROW_ONE_COLUMN = 760 },
    SafeArea = 12,
    SnapDistance = 16,
    -- Resolution safety is intentionally expressed in logical UIParent
    -- coordinates. CryEngine resolution changes crop the visible canvas from
    -- TOPLEFT, so new floating controls should be born in this stable discovery
    -- zone and every live floating surface must remain recoverable inside the
    -- current logical viewport.
    ResolutionSafety = {
        spawnX = 300, spawnY = 100, spawnGapX = 8, spawnGapY = 8,
        maxColumns = 4, edge = 12,
    },
    ScaleOptions = { 0.80, 0.90, 1.00, 1.10, 1.20 },
    FontScaleOptions = { 1.00, 1.10, 1.20, 1.30, 1.40, 1.50 },
    DataRefreshOptionsMs = { 5000, 10000, 15000, 30000, 60000 },
    TradeRefreshOptionsMs = { 30000, 60000, 120000, 300000 },
    MinAddonScale = 0.80,
    MaxAddonScale = 1.20,

    -- Modern dark theme master switch. When enabled, card/header/soft panels
    -- created through the UI factory automatically get the vertical gradient
    -- skin (plus accent strip for headers). Set to false to restore the old
    -- flat solid-color look everywhere; individual panels can still opt out
    -- with { gradient = false } in their CreatePanel opts.
    Theme = {
        modern = true,
        gradientPanels = true,   -- card/soft panels get gradient background
        gradientHeaders = true,  -- header bars get gradient + accent strip
        labelShadow = true,      -- titles (fontSize >= 13) get text shadow
    },

    Layout = {
        titleHeight = 30, tabHeight = 30, margin = 10, cardGap = 7,
        cardHeaderHeight = 27, rowHeight = 23, compactRowHeight = 20,
        buttonHeight = 26, entryBaseSize = 42, entryMinHitSize = 36,
    },
    MainWindow = {
        -- Fresh-install / factory-reset recommended extents.  The life dashboard
        -- needs substantially more room than the old 820x735 two-column shell:
        -- that layout owns five vertical tracks, so the former default forced
        -- bond/event/character cards into only a few visible rows on first open.
        -- Persisted user width/height still win in Layout:GetMainSpec(), therefore
        -- this only affects users who have never resized the Suite (or explicitly
        -- restored all defaults). Screen-safe clamping remains authoritative.
        threeColumnWidth = 1120, threeColumnHeight = 840,
        twoColumnWidth = 980, twoColumnHeight = 860,
        oneColumnWidth = 640, oneColumnHeight = 860,
        minWidth = 560, minHeight = 600,
        -- Legacy compatibility metadata only. V3 outer-window authority MUST NOT
        -- consume these historical maxima; keep them for old schema/readability
        -- calculations until the legacy migration layer is retired.
        maxWidth = 1180, maxHeight = 900, collapsedHeight = 32, maxReadingWidth = 1180,
    },
    -- HUD minimums are technical drag/resize floors only. Recommended sizes
    -- remain the width/height values above and content must adapt below them.
    Widget = {
        task = { width = 390, height = 330, minWidth = 120, minHeight = 34, maxWidth = 760, maxHeight = 650, miniWidth = 285, miniHeight = 32 },
        trade = { width = 590, height = 430, minWidth = 120, minHeight = 34, maxWidth = 900, maxHeight = 700, miniWidth = 400, miniHeight = 32 },
        bond = { width = 590, height = 470, minWidth = 120, minHeight = 34, maxWidth = 900, maxHeight = 720, miniWidth = 340, miniHeight = 32 },
        event = { width = 330, height = 350, minWidth = 110, minHeight = 30, maxWidth = 760, maxHeight = 720, miniWidth = 220, miniHeight = 26, collapsedWidth = 145 },
        treasure = { width = 360, height = 245, minWidth = 120, minHeight = 34, maxWidth = 620, maxHeight = 420, miniWidth = 260, miniHeight = 32 },
        fishing = { width = 360, height = 180, minWidth = 120, minHeight = 34, maxWidth = 620, maxHeight = 340, miniWidth = 260, miniHeight = 32 },
    },
    Refresh = {
        layoutMs = 500, storageMs = 200, uiFlushMs = 120,
        eventTimerMs = 1000, questSafetyMs = 15000, resourceSafetyMs = 15000, residentSafetyMs = 30000, residentStageSafetyMs = 60000,
        tradeTimeoutMs = 6500, tradeAutoMs = 120000, auctionStepMs = 200, auctionCooldownMs = 1600, treasurePositionMs = 250, fishingPollMs = 500,
    },
    QuestStatus = {
        NOT_ACCEPTED = "NOT_ACCEPTED", IN_PROGRESS = "IN_PROGRESS",
        READY_TO_TURN_IN = "READY_TO_TURN_IN", COMPLETED = "COMPLETED",
        UNAVAILABLE = "UNAVAILABLE", UNKNOWN = "UNKNOWN",
    },
    Color = {
        -- M6-v2 preview-parity palette: blue-black/teal surfaces with gold
        -- framing. Gold remains branding; cyan/teal is the interaction accent.
        panel = { 0.006, 0.022, 0.030, 0.98 }, panelAlt = { 0.012, 0.038, 0.048, 0.98 },
        card = { 0.010, 0.030, 0.038, 0.97 }, cardHeader = { 0.020, 0.070, 0.082, 0.98 },
        border = { 0.45, 0.33, 0.14, 0.58 }, borderSoft = { 0.070, 0.225, 0.255, 0.54 },
        text = { 0.92, 0.90, 0.84, 1.00 }, textMuted = { 0.61, 0.66, 0.67, 1.00 },
        accent = { 0.91, 0.70, 0.30, 1.00 }, blue = { 0.23, 0.74, 0.82, 1.00 },
        green = { 0.52, 0.88, 0.30, 1.00 }, yellow = { 1.00, 0.78, 0.18, 1.00 },
        orange = { 1.00, 0.42, 0.12, 1.00 }, red = { 0.95, 0.22, 0.16, 1.00 },
        purple = { 0.77, 0.45, 0.98, 1.00 },

        -- Modern dark theme: vertical 3-band gradients (top -> mid -> bottom).
        -- ChangeColor1/2/3 take (r,g,b) only, overall alpha handled separately.
        Gradient = {
            panel = {
                { 0.042, 0.112, 0.136 }, -- top
                { 0.021, 0.067, 0.086 }, -- mid
                { 0.009, 0.032, 0.047 }, -- bottom
            },
            card = {
                { 0.048, 0.124, 0.145 },
                { 0.025, 0.075, 0.093 },
                { 0.010, 0.037, 0.051 },
            },
            header = {
                { 0.066, 0.164, 0.187 },
                { 0.035, 0.105, 0.126 },
                { 0.014, 0.054, 0.070 },
            },
            titlebar = {
                { 0.070, 0.157, 0.184 },
                { 0.038, 0.101, 0.123 },
                { 0.015, 0.052, 0.070 },
            },
            button = {
                { 0.045, 0.105, 0.125 },
                { 0.026, 0.070, 0.086 },
                { 0.014, 0.043, 0.054 },
            },
            buttonHover = {
                { 0.075, 0.185, 0.215 },
                { 0.045, 0.125, 0.150 },
                { 0.022, 0.075, 0.092 },
            },
            buttonPushed = {
                { 0.060, 0.085, 0.118 },
                { 0.090, 0.118, 0.155 },
                { 0.135, 0.170, 0.215 },
            },
            buttonDisabled = {
                { 0.060, 0.066, 0.075 },
                { 0.048, 0.052, 0.060 },
                { 0.036, 0.040, 0.048 },
            },
        },

        -- Accent strip / divider / text emphasis for the modern look.
        accentSoft = { 0.91, 0.70, 0.30, 0.20 },
        accentLine = { 0.93, 0.72, 0.31, 0.72 },
        divider = { 0.10, 0.29, 0.32, 0.48 },
        dividerSoft = { 0.065, 0.205, 0.225, 0.34 },
        headerText = { 0.98, 0.94, 0.85, 1.00 },
        rowHover = { 0.025, 0.092, 0.108, 0.78 },
        rowSelected = { 0.030, 0.128, 0.148, 0.90 },
    },
}
