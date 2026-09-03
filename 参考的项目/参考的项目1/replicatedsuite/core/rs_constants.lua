------------------------------------------------------------------------
-- Replicated Suite - Constants
-- Author: Replicated
------------------------------------------------------------------------

if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

S.Constants = {
    -- Schema 21: module enabled state and team/damage-review feature toggles
    -- moved from Character Override to the Account base (usage habits persist
    -- across characters and no longer depend on world-qualified identity
    -- matching at load time). Schema 20->21 migration folds previously saved
    -- override modules/settings into the Account base on first load.
    SaveSchemaVersion = 21,
    BlueSaltBondItemType = 41488,
    BondMaterialItemTypes = { fabric = 8256, leather = 16327, lumber = 8337, iron = 8318 },
    BondQuestByMaterialQuantity = {
        fabric = { [20] = 9044, [60] = 9147, [100] = 9148 },
        leather = { [20] = 9046, [60] = 9152, [100] = 9153 },
        iron = { [20] = 9047, [60] = 9137, [100] = 9138 },
        lumber = { [20] = 9049, [60] = 9142, [100] = 9143 },
    },
    -- Official/current ArcheRage Auroria resident daily quest mapping.
    -- Resolver matches the resident-board item name and requested quantity.
    AuroriaBondQuestByTokenQuantity = {
        golden_bag = { [30] = 10504, [90] = 10505 },
        prince_box = { [10] = 10506, [30] = 10507 },
        queen_bag = { [25] = 10508, [75] = 10509 },
        queen_box = { [8] = 10510, [25] = 10511 },
        heir_bag = { [20] = 10512, [60] = 10513 },
        heir_box = { [7] = 10514, [20] = 10515 },
    },

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
        minWidth = 560, minHeight = 600, maxWidth = 1180, maxHeight = 900,
        collapsedHeight = 32, maxReadingWidth = 1180,
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
        panel = { 0.025, 0.035, 0.050, 0.94 }, panelAlt = { 0.040, 0.052, 0.068, 0.94 },
        card = { 0.035, 0.046, 0.060, 0.92 }, cardHeader = { 0.060, 0.072, 0.088, 0.96 },
        border = { 0.34, 0.29, 0.20, 0.90 }, borderSoft = { 0.20, 0.24, 0.28, 0.82 },
        text = { 0.94, 0.91, 0.84, 1.00 }, textMuted = { 0.66, 0.68, 0.70, 1.00 },
        accent = { 0.84, 0.67, 0.33, 1.00 }, blue = { 0.30, 0.75, 1.00, 1.00 },
        green = { 0.52, 0.88, 0.30, 1.00 }, yellow = { 1.00, 0.78, 0.18, 1.00 },
        orange = { 1.00, 0.42, 0.12, 1.00 }, red = { 0.95, 0.22, 0.16, 1.00 },
        purple = { 0.77, 0.45, 0.98, 1.00 },

        -- Modern dark theme: vertical 3-band gradients (top -> mid -> bottom).
        -- ChangeColor1/2/3 take (r,g,b) only, overall alpha handled separately.
        Gradient = {
            panel = {
                { 0.055, 0.085, 0.125 }, -- top
                { 0.032, 0.048, 0.072 }, -- mid
                { 0.016, 0.024, 0.040 }, -- bottom
            },
            card = {
                { 0.060, 0.085, 0.115 },
                { 0.038, 0.054, 0.075 },
                { 0.022, 0.032, 0.048 },
            },
            header = {
                { 0.115, 0.150, 0.195 },
                { 0.075, 0.098, 0.130 },
                { 0.050, 0.066, 0.092 },
            },
            titlebar = {
                { 0.135, 0.170, 0.215 },
                { 0.090, 0.115, 0.150 },
                { 0.060, 0.078, 0.105 },
            },
            button = {
                { 0.120, 0.155, 0.200 },
                { 0.080, 0.105, 0.140 },
                { 0.048, 0.066, 0.092 },
            },
            buttonHover = {
                { 0.175, 0.215, 0.265 },
                { 0.115, 0.148, 0.190 },
                { 0.070, 0.095, 0.128 },
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
        accentSoft = { 0.84, 0.67, 0.33, 0.30 },
        accentLine = { 0.90, 0.75, 0.40, 0.85 },
        divider = { 0.30, 0.36, 0.44, 0.55 },
        dividerSoft = { 0.20, 0.24, 0.30, 0.40 },
        headerText = { 0.98, 0.94, 0.85, 1.00 },
        rowHover = { 0.16, 0.21, 0.27, 0.55 },
        rowSelected = { 0.22, 0.26, 0.18, 0.60 },
    },
}
