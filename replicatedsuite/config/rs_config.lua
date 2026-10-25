-- Replicated Suite · 默认配置与存档命名空间
-- 作者：Replicated
-- QQ群：1104129461
-- 这里只放随插件发布的默认值；个人配置保存到 ADDON:SaveData。
ReplicatedSuiteConfig = {
    SaveKey = "replicated_suite_v1",
    MainWindowTitle = "正式版1.2 · 作者：Replicated     qq群：1104129461",
    Defaults = {
        settings = {
            addonScale = 1.00, fontScale = 1.20, opacity = 0.90, contentOpacity = 1.00,
            entryLocked = false, mainLocked = false, showEntry = true, -- 主入口 R 始终可恢复访问。
            showCompletedTasks = true, onlyIncompleteTasks = false, eventMaxRows = 20,
            dataRefreshMs = 15000, tradeAutoRefresh = false, tradeAutoRefreshMs = 120000,
            tradeSortMode = "ratio", eventReminderMode = "off", showCombatLaunchers = false, -- 旧存档迁移字段；独立启动器已移除。
            -- 新档案默认启用团队工具；加载时保留用户已有选择。
            teamAutoRoleEnabled = true, teamRoleMode = "auto", sacMarkerEnabled = true,
            -- 伤害复盘属于团队工具，与可选 DPS 模块独立；新档案默认启用。
            damageReviewEnabled = true, damageReviewAutoShow = true,
            damageReviewWindowMs = 10000, damageReviewMaxHistory = 10,
            damageReviewMinDamage = 0, damageReviewShowDebuffs = true,
            markerScaleOverride = true, markerScale = 1.20,
            -- 字号偏移：0 用自动基准，正值放大；最小宽度下允许少量重叠。
            eventFontAdjust = 1,
            defaultStartPage = "life", diagnosticsLevel = "warning",
            globalHudFontScale = 1.00, globalHudBackgroundAlpha = 0.90, globalCompactMode = false,
            hudSnapEnabled = true, hudCloseButtonEnabled = true,
            -- 这里只保存目标探测设置，不保存目标、HP、Buff 等运行状态。
            -- 没有订阅者且全局检查器关闭时停止探测。
            targetDetectionEnabled = false,   -- 全局检查器模式。
            targetDetectionQueueRetain = true,
            targetDetectionFastMs = 100,      -- HP/距离通道。
            targetDetectionNormalMs = 250,    -- 效果/基础状态通道。
            targetDetectionSlowMs = 2000,     -- 职业/装备/身份通道。
            targetDetectionEffectLimit = 24,  -- 每次扫描各通道的最大效果数。
            targetDetectionCacheSize = 32,
            targetDetectionCacheTtlMs = 120000,
            -- 点击后才扫描背包；移动队列由 Scheduler 限速。
            bagOrganizerShowBagButtons = true,
            bagOrganizerRequireBankOpen = false,
            bagOrganizerMoveIntervalMs = 250,
            bagOrganizerAllowNameFallback = true,
            bagOrganizerButtonSide = "right",
            bagOrganizerMaxMoves = 0, -- 0 表示全部匹配堆叠。
            bagOrganizerReportResults = true,
            -- bank/coffer 分别保存黑名单；categories 用类别字符串，items 用 itemType 数字作键。
            bagOrganizerBlacklist = {
                enabled = false,
                bank = { categories = {}, items = {} },
                coffer = { categories = {}, items = {} },
            },
            -- autoShow 只控制打开制作台时自动弹出；贸易卡片的手动按钮始终可用。
            craftAssist = {
                enabled = true,
                autoShow = true,
                -- 持久化窗口尺寸由布局 metrics 夹紧，位置通过 S.Layout 浮窗存储。
                width = 560,
                height = 430,
            },
        },
        -- 这里只保存模块启停；禁用模块时保留其数据。
        modules = {
            tasks={enabled=true}, resources={enabled=true}, trade={enabled=true},
            bonds={enabled=true}, activities={enabled=true}, treasure={enabled=true},
            fishing={enabled=true}, bag_organizer={enabled=true}, auction_favorites={enabled=true}, team_utility={enabled=true},
            -- 新安装需手动开启专业模块；可先加载数据，运行仍须经 ModuleManager 启用。
            dps={enabled=false}, gear={enabled=false}, healer={enabled=false}, plates={enabled=false},
        },
        ui = {
            entry = { anchorH="LEFT", anchorV="TOP", offsetX=288, offsetY=88 },
            main = { anchorH="LEFT", anchorV="TOP", offsetX=95, offsetY=105, collapsed=false },
            -- 分栏保存比例，不保存像素；用户拖过分隔条才写入，否则使用自动布局。
            dashboard = { activityRatio=nil, middleRatio=nil },
            widgets = {
                task={ visible=false, mode="standard", titleVisible=true, collapsed=false, locked=false, clickThrough=false, anchorH="RIGHT", anchorV="TOP", offsetX=16, offsetY=80 },
                trade={ visible=false, mode="standard", titleVisible=true, collapsed=false, locked=false, clickThrough=false, anchorH="RIGHT", anchorV="TOP", offsetX=16, offsetY=120 },
                bond={ visible=false, mode="standard", titleVisible=true, collapsed=false, locked=false, clickThrough=false, anchorH="RIGHT", anchorV="TOP", offsetX=16, offsetY=160 },
                event={ visible=false, mode="standard", titleVisible=true, collapsed=false, locked=false, clickThrough=false, anchorH="RIGHT", anchorV="TOP", offsetX=16, offsetY=200 },
                treasure={ visible=false, mode="standard", titleVisible=true, collapsed=false, locked=false, clickThrough=false, anchorH="RIGHT", anchorV="TOP", offsetX=16, offsetY=240 },
                fishing={ visible=false, mode="standard", titleVisible=true, collapsed=false, locked=false, clickThrough=false, anchorH="RIGHT", anchorV="TOP", offsetX=16, offsetY=280 },
            },
            -- 对话框沿用 HUD 的逻辑边缘定位协议，但不参与 HUD 编辑模式或可见性策略。
            dialogs = {
                trade_detail={ width=580, height=430, fontScale=1.0, backgroundAlpha=0.90, userMoved=false },
            },
        },
        life = {
            trade = { fromZone=nil, toZone=nil, routeConfirmed=false, favorites={} },
            auctionFavorites = { items = {} },
            hiddenEvents = {},
            -- configured=false 时显示全部精选日常组；定制后新增组需手动选入。
            dailyTracking = { configured=false, keys={} },
            -- 按角色保存活动任务选择，修改勾选后才保存该组；默认只跟踪标准目标。
            eventTaskTracking = { formatVersion=3, groups={} },
            bondCache = { dateKey = "unknown", west = nil, east = nil, auroria = nil, completedMainlandBondKeys = {} },
            bondSortMode = "continent",
            -- 只过滤债券板显示，不影响采集。
            bondFilter = { q20 = true, q60 = true, q100 = true, auroria = true, excludeSame = false, priority = "west" },
            -- 保留字段以兼容旧档；Cinderstone/Ynystere 现按每日 Industry Dynamo 奖励任务判断。
            eventDailyDone = { dateKey = "unknown", keys = {} },
        },
        profiles = { features = {}, huds = {}, combos = {} },
        product = { lastSeenVersion = "", updateNoticeDismissed = false, lastPage = "life", favorites = {} },
        dailyCounters = { dateKey="unknown", gold=0, honor=0, vocation=0, exp=0 },
    },
}
