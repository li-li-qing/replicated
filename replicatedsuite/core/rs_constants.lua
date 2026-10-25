-- Replicated Suite · 共享常量
-- 作者：Replicated
-- QQ群：1104129461
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

local GameIds = S.GameIds or {}
local ItemIds = GameIds.Item or {}
local QuestIds = GameIds.Quest or {}
local ResidentBondQuestIds = QuestIds.ResidentBond or {}
if ItemIds.BLUE_SALT_BOND == nil or type(ItemIds.BOND_MATERIAL) ~= "table"
    or type(ItemIds.AURORIA_BOND_MATERIAL) ~= "table"
    or type(ResidentBondQuestIds.MaterialByQuantity) ~= "table"
    or type(ResidentBondQuestIds.AuroriaByTokenQuantity) ~= "table" then
    S.BootError = "shared item/quest ID catalog unavailable"
    return
end

S.Constants = {
    -- Schema 20->21 首次加载时，将角色档的 modules/settings 合入 Account，保留跨角色开关偏好。
    SaveSchemaVersion = 21,
    -- 游戏 ID 统一放在 data/ids/*.lua，这里引用目录，不另存副本。
    BlueSaltBondItemType = ItemIds.BLUE_SALT_BOND,
    BondMaterialItemTypes = ItemIds.BOND_MATERIAL,
    -- 原大陆债券材料与大陆四种加工材料分开，避免把 six-token Auroria 物品误当 fabric/leather/lumber/iron。
    -- Bonds 读取背包时合并两张只读映射，任务和筛选仍分开处理。
    AuroriaBondMaterialItemTypes = ItemIds.AURORIA_BOND_MATERIAL,
    BondQuestByMaterialQuantity = ResidentBondQuestIds.MaterialByQuantity,
    -- 当前 ArcheRage 原大陆居民日常的官方映射；解析器按居民板物品名与需求数量匹配。
    AuroriaBondQuestByTokenQuantity = ResidentBondQuestIds.AuroriaByTokenQuantity,

    Breakpoint = { COMPACT = 1150, STANDARD = 1700, WIDE = 2300, NARROW_ONE_COLUMN = 760 },
    SafeArea = 12,
    SnapDistance = 16,
    -- CryEngine 改分辨率时从 TOPLEFT 裁剪画布；新浮窗在此区域生成，并按当前逻辑视口夹紧。
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

    -- 视觉引导的硬范围。滑块可显示较窄范围（如 2..10），精确输入经 Domain 校验后再扩展显示范围。
    VisualGuide = {
        pointSizeMin = 2,
        pointSizeDefaultMax = 10,
        pointSizeHardMax = 24,
        -- NumericSlider 的 8/12..48 只是建议范围；Page、Feature、Presenter 统一使用这里的硬范围。
        unitLineDensityHardMin = 2,
        unitLineDensityHardMax = 160,
        rangeDensityHardMin = 3,
        rangeDensityHardMax = 192,
        rangeRadiusHardMin = 0.5,
        rangeRadiusHardMax = 1000,
        refreshMsHardMin = 1,
        refreshMsHardMax = 60000,
    },

    -- 深色主题默认给 card/header/soft 加竖向渐变，header 另带强调条。
    -- 关闭后用纯色；单个面板可传 CreatePanel 的 { gradient = false } 退出渐变。
    Theme = {
        modern = true,
        gradientPanels = true,   -- card/soft 面板使用渐变背景。
        gradientHeaders = true,  -- header 使用渐变及强调条。
        labelShadow = true,      -- fontSize>=13 的标题使用文本阴影。
    },

    Layout = {
        titleHeight = 30, tabHeight = 30, margin = 10, cardGap = 7,
        cardHeaderHeight = 27, rowHeight = 23, compactRowHeight = 20,
        buttonHeight = 26, entryBaseSize = 42, entryMinHitSize = 36,
    },
    MainWindow = {
        -- 默认尺寸需容纳生活仪表盘的五列；已保存宽高优先，最终按屏幕安全范围夹紧。
        threeColumnWidth = 1120, threeColumnHeight = 840,
        twoColumnWidth = 980, twoColumnHeight = 860,
        oneColumnWidth = 640, oneColumnHeight = 860,
        minWidth = 560, minHeight = 600,
        -- 旧 schema 和可读性计算仍使用这些历史上限；V3 外窗不再使用。
        maxWidth = 1180, maxHeight = 900, collapsedHeight = 32, maxReadingWidth = 1180,
    },
    -- HUD 最小尺寸只用于拖动和缩放技术下限；推荐尺寸仍是上方 width/height，内容须适应更小尺寸。
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
        -- 预览一致配色：蓝黑/青绿表面配金色边框；金色承担品牌色，青色/青绿承担交互强调。
        panel = { 0.006, 0.022, 0.030, 0.98 }, panelAlt = { 0.012, 0.038, 0.048, 0.98 },
        card = { 0.010, 0.030, 0.038, 0.97 }, cardHeader = { 0.020, 0.070, 0.082, 0.98 },
        border = { 0.45, 0.33, 0.14, 0.58 }, borderSoft = { 0.070, 0.225, 0.255, 0.54 },
        text = { 0.92, 0.90, 0.84, 1.00 }, textMuted = { 0.61, 0.66, 0.67, 1.00 },
        accent = { 0.91, 0.70, 0.30, 1.00 }, blue = { 0.23, 0.74, 0.82, 1.00 },
        green = { 0.52, 0.88, 0.30, 1.00 }, yellow = { 1.00, 0.78, 0.18, 1.00 },
        orange = { 1.00, 0.42, 0.12, 1.00 }, red = { 0.95, 0.22, 0.16, 1.00 },
        purple = { 0.77, 0.45, 0.98, 1.00 },

        -- 现代深色主题采用上、中、下三段竖向渐变。ChangeColor1/2/3 只接收 (r,g,b)，整体 alpha 单独处理。
        Gradient = {
            panel = {
                { 0.042, 0.112, 0.136 }, -- 顶部。
                { 0.021, 0.067, 0.086 }, -- 中部。
                { 0.009, 0.032, 0.047 }, -- 底部。
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

        -- 现代主题的强调条、分隔线与文本强调色。
        accentSoft = { 0.91, 0.70, 0.30, 0.20 },
        accentLine = { 0.93, 0.72, 0.31, 0.72 },
        divider = { 0.10, 0.29, 0.32, 0.48 },
        dividerSoft = { 0.065, 0.205, 0.225, 0.34 },
        headerText = { 0.98, 0.94, 0.85, 1.00 },
        rowHover = { 0.025, 0.092, 0.108, 0.78 },
        rowSelected = { 0.030, 0.128, 0.148, 0.90 },
    },
}
