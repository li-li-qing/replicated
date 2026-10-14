------------------------------------------------------------------------
-- Replicated Suite · 默认配置与存档命名空间
-- 作者：Replicated
-- QQ群：1104129461
--
-- 可分发默认配置与持久化命名空间。这里只保存可随插件发布的默认值；个人运行配置始终保存在 ArcheRage
-- ADDON:SaveData 中，绝不序列化到此源码。
------------------------------------------------------------------------
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
            -- 团队工具在新建或默认档案中启用；用户已保存的偏好仍是权威，不能在这里覆盖。
            teamAutoRoleEnabled = true, teamRoleMode = "auto", sacMarkerEnabled = true,
            -- 伤害复盘属于团队工具，与可选 DPS 模块独立；新档案默认启用。
            damageReviewEnabled = true, damageReviewAutoShow = true,
            damageReviewWindowMs = 10000, damageReviewMaxHistory = 10,
            damageReviewMinDamage = 0, damageReviewShowDebuffs = true,
            markerScaleOverride = true, markerScale = 1.20,
            -- 事件浮窗内容字号偏移：0 使用自动基准，正值放大文本；在最小窗口宽度下允许少量像素重叠，以保持可读性。
            eventFontAdjust = 1,
            defaultStartPage = "life", diagnosticsLevel = "warning",
            globalHudFontScale = 1.00, globalHudBackgroundAlpha = 0.90, globalCompactMode = false,
            hudSnapEnabled = true, hudCloseButtonEnabled = true,
            -- 全局目标探测权威。当前目标、HP、距离、Buff、revision 等运行状态不持久化，只保存用户设置。探测
            -- 按需启动；没有消费者订阅且全局检查器关闭时保持休眠。
            targetDetectionEnabled = false,   -- 全局检查器模式。
            targetDetectionQueueRetain = true, -- 持续捕获队列。
            targetDetectionFastMs = 100,      -- HP/距离通道。
            targetDetectionNormalMs = 250,    -- 效果/基础状态通道。
            targetDetectionSlowMs = 2000,     -- 职业/装备/身份通道。
            targetDetectionEffectLimit = 24,  -- 每次扫描各通道的最大效果数。
            targetDetectionCacheSize = 32,    -- 有界近期目标缓存。
            targetDetectionCacheTtlMs = 120000,
            -- 背包整理仅响应用户显式操作。点击按钮才扫描匹配项，移动队列由共享 Scheduler 控制节奏。
            bagOrganizerShowBagButtons = true,
            bagOrganizerRequireBankOpen = false,
            bagOrganizerMoveIntervalMs = 250,
            bagOrganizerAllowNameFallback = true,
            bagOrganizerButtonSide = "right", -- 右侧/内部。
            bagOrganizerMaxMoves = 0, -- 0 表示全部匹配堆叠。
            bagOrganizerReportResults = true,
            -- 每种存储（bank/coffer）独立的黑名单，默认关闭；categories/items 中的键分别为物品类别字符串和
            -- itemType 数字。
            bagOrganizerBlacklist = {
                enabled = false,
                bank = { categories = {}, items = {} },
                coffer = { categories = {}, items = {} },
            },
            -- 制作台材料辅助默认开启（用户需求证据：2026-08-24）。打开制作台须自动弹出面板；autoShow 仅控制
            -- 检测到制作台时的自动弹出，贸易卡片的手动按钮始终可用。
            craftAssist = {
                enabled = true,
                autoShow = true,
                -- 持久化窗口尺寸由布局 metrics 夹紧，位置通过 S.Layout 浮窗存储。
                width = 560,
                height = 430,
            },
        },
        -- Suite 只拥有生命周期启停状态的权威；领域数据仍属于各模块或服务，禁用模块不能清除数据。
        modules = {
            tasks={enabled=true}, resources={enabled=true}, trade={enabled=true},
            bonds={enabled=true}, activities={enabled=true}, treasure={enabled=true},
            fishing={enabled=true}, bag_organizer={enabled=true}, auction_favorites={enabled=true}, team_utility={enabled=true},
            -- 专业模块在新安装时由用户主动开启。领域数据与配置仍安全加载，业务运行须等待 Suite
            -- ModuleManager 授予生命周期权限。
            dps={enabled=false}, gear={enabled=false}, healer={enabled=false}, plates={enabled=false},
        },
        ui = {
            entry = { anchorH="LEFT", anchorV="TOP", offsetX=288, offsetY=88 },
            main = { anchorH="LEFT", anchorV="TOP", offsetX=95, offsetY=105, collapsed=false },
            -- 仪表盘分栏偏好保存归一化比例而非像素；用户拖动分隔条后才写入，未调整的安装继续使用响应式默认
            -- 布局解算。
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
            -- 日常跟踪是用户显式选择的视图偏好。定制前 configured=false 保留全部精选日常组可见的默认行为；
            -- 定制后新增组须主动选入，不能悄悄加入已有个人清单。
            dailyTracking = { configured=false, keys={} },
            -- 活动任务按角色选择；玩家修改组内任务勾选后才实体化该组。此前 QuestService 保持默认：跟踪标准
            -- 目标，不跟踪关联或可选目标。
            eventTaskTracking = { formatVersion=3, groups={} },
            bondCache = { dateKey = "unknown", west = nil, east = nil, auroria = nil, completedMainlandBondKeys = {} },
            bondSortMode = "continent",
            -- 债券板显示过滤默认包含全部类别；只影响表现，不能影响采集或数据。
            bondFilter = { q20 = true, q60 = true, q100 = true, auroria = true, excludeSame = false, priority = "west" },
            -- 该字段只为兼容旧存档保留。当前 Cinderstone/Ynystere 状态依据每日一次的 Industry Dynamo 奖励任
            -- 务，不再依赖此锁存位。
            eventDailyDone = { dateKey = "unknown", keys = {} },
        },
        profiles = { features = {}, huds = {}, combos = {} },
        product = { lastSeenVersion = "", updateNoticeDismissed = false, lastPage = "life", favorites = {} },
        dailyCounters = { dateKey="unknown", gold=0, honor=0, vocation=0, exp=0 },
    },
}
