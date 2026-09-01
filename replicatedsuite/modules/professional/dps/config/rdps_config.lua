ReplicatedSuiteModuleSandbox:Enter('dps', {'ReplicatedDps', 'ReplicatedDpsConfig'})
------------------------------------------------------------------------
-- Replicated DPS - Shareable defaults / persistence namespace
-- Author: Replicated
-- Personal runtime configuration is kept by ADDON:SaveData, not in this file.
------------------------------------------------------------------------

ReplicatedDpsConfig = {
    PersistencePrefix = "repdps",
    Defaults = {
    config = {
        schemaVersion = 3,
        enabled = false,
        -- The RU server disabled broad sight enumeration on 2026-08-19. Team is
        -- therefore the truthful default; legacy range remains a target+team
        -- observation mode for users who already selected it.
        scopeMode = "team",
        showFriendly = true,
        showEnemy = true,
        currentMode = "PVP",
        currentPage = "DAMAGE",
        displayRows = 100,
        alwaysShowSelf = true,
        abbreviateNumbers = true,
        showPercent = true,
        showSuspect = true,
        showPendingSummary = true,
        inferChineseNamesAsNpc = true,
        useSocialFriendlyPriors = true,
        showThirdPartySummary = true,
        showClosure = true,
        friendlyLocked = false,
        enemyLocked = false,
        compactMode = false,
        rankingOpacity = 1.00,
        launcherOpacity = 1.00,
        rankingScale = 1.00,
        personalWindowMs = 5000,
        sideWindowMs = 8000,
        uiRefreshMs = 500,
        rosterScanMs = 1000,
        persistenceMs = 30000,
        diagnosticsEnabled = false,
        rawEventLimit = 1200,
    },
    rules = {
        schemaVersion = 1,
        nextId = 1,
        revision = 0,
        entries = {},
    },
    ui = {
        schemaVersion = 1,
        launcher = { coordinateSpace = "logical", anchorH = "LEFT", anchorV = "TOP", offsetX = 300, offsetY = 100, width = 88, height = 26 },
        config = { coordinateSpace = "logical", anchorH = "LEFT", anchorV = "TOP", offsetX = 230, offsetY = 110, width = 560, height = 470 },
        friendly = { coordinateSpace = "logical", anchorH = "LEFT", anchorV = "TOP", offsetX = 12, offsetY = 160, width = 360, height = 286, visualScale = 1.00 },
        enemy = { coordinateSpace = "logical", anchorH = "LEFT", anchorV = "TOP", offsetX = 380, offsetY = 160, width = 360, height = 286, visualScale = 1.00 },
        detail = { coordinateSpace = "logical", anchorH = "LEFT", anchorV = "TOP", offsetX = 260, offsetY = 120, width = 480, height = 480 },
    },
    },
}
