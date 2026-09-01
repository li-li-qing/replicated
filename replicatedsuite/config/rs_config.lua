------------------------------------------------------------------------
-- Replicated Suite - Shareable defaults / persistence namespace
-- Author: Replicated
--
-- IMPORTANT: this file contains only distribution-safe defaults. Personal
-- runtime settings continue to live in ArcheRage ADDON:SaveData storage and
-- are never serialized into this source file.
------------------------------------------------------------------------

ReplicatedSuiteConfig = {
    SaveKey = "replicated_suite_v1",
    MainWindowTitle = "正式版1.2 · 作者：Replicated     qq群：1104129461",
    Defaults = {
        settings = {
            addonScale = 1.00, fontScale = 1.20, opacity = 0.90, contentOpacity = 1.00,
            entryLocked = false, mainLocked = false, showEntry = true, -- canonical R entry is always recoverable
            showCompletedTasks = true, onlyIncompleteTasks = false, eventMaxRows = 20,
            dataRefreshMs = 15000, tradeAutoRefresh = false, tradeAutoRefreshMs = 120000,
            tradeSortMode = "ratio", eventReminderMode = "off", showCombatLaunchers = false, -- legacy migration field; standalone launchers removed
            -- Team utility ships enabled for fresh/default profiles. User-saved
            -- preferences still remain Authority and are never overwritten here.
            teamAutoRoleEnabled = true, teamRoleMode = "auto", sacMarkerEnabled = true,
            -- Damage Review belongs to Team Utility and is independent from the
            -- optional DPS module. Fresh profiles ship with it enabled.
            damageReviewEnabled = true, damageReviewAutoShow = true,
            damageReviewWindowMs = 10000, damageReviewMaxHistory = 10,
            damageReviewMinDamage = 0, damageReviewShowDebuffs = true,
            markerScaleOverride = true, markerScale = 1.20,
            -- Event floating-window content font adjustment. 0 = automatic base,
            -- positive values enlarge text and may intentionally overlap a few
            -- pixels at the minimum window width rather than becoming unreadable.
            eventFontAdjust = 1,
            defaultStartPage = "life", diagnosticsLevel = "warning",
            globalHudFontScale = 1.00, globalHudBackgroundAlpha = 0.90, globalCompactMode = false,
            hudSnapEnabled = true, hudCloseButtonEnabled = true,
            -- Global Target Detection Authority. Runtime target state (current
            -- target/HP/distance/buffs/revision) is never persisted; only user
            -- settings are. Detection is demand-driven and stays dormant when no
            -- consumer subscribes and the global inspector is off.
            targetDetectionEnabled = false,   -- global inspector mode
            targetDetectionQueueRetain = true, -- sticky capture queue
            targetDetectionFastMs = 100,      -- HP / distance lane
            targetDetectionNormalMs = 250,    -- effects / base status lane
            targetDetectionSlowMs = 2000,     -- profession / gear / identity lane
            targetDetectionEffectLimit = 24,  -- max effects per lane per scan
            targetDetectionCacheSize = 32,    -- bounded recent-target cache
            targetDetectionCacheTtlMs = 120000,
            -- Bag organizer: explicit user action only. Matching scans happen on
            -- button click; the move queue is paced by the shared Scheduler.
            bagOrganizerShowBagButtons = true,
            bagOrganizerRequireBankOpen = false,
            bagOrganizerMoveIntervalMs = 250,
            bagOrganizerAllowNameFallback = true,
            bagOrganizerButtonSide = "right", -- right / inside
            bagOrganizerMaxMoves = 0, -- 0 = all matching stacks
            bagOrganizerReportResults = true,
            -- Per-storage blacklist (bank/coffer). Default off; keys inside
            -- categories/items are item category strings / itemType numbers.
            bagOrganizerBlacklist = {
                enabled = false,
                bank = { categories = {}, items = {} },
                coffer = { categories = {}, items = {} },
            },
            -- Craft station material assist (P1-3 / H3). Default ON (user
            -- requirement 2026-08-24: opening the craft station must pop the
            -- panel automatically, no manual enable); autoShow only affects the
            -- automatic popup when a craft station is detected -- the manual
            -- button in the trade card stays available regardless.
            craftAssist = {
                enabled = true,
                autoShow = true,
                -- G2: persisted window size (clamped by rs_state; position goes
                -- through S.Layout floating storage).
                width = 560,
                height = 430,
            },
        },
        -- Suite Authority owns only lifecycle enable/disable state. Domain data
        -- remains inside each module/service and is never cleared by disabling it.
        modules = {
            tasks={enabled=true}, resources={enabled=true}, trade={enabled=true},
            bonds={enabled=true}, activities={enabled=true}, treasure={enabled=true},
            fishing={enabled=true}, bag_organizer={enabled=true}, auction_favorites={enabled=true}, team_utility={enabled=true},
            -- Professional modules are deliberately opt-in on fresh installs.
            -- Their Domain data/config is loaded safely, but business runtime is
            -- started only after Suite ModuleManager grants lifecycle Authority.
            dps={enabled=false}, gear={enabled=false}, healer={enabled=false}, plates={enabled=false},
        },
        ui = {
            entry = { anchorH="LEFT", anchorV="TOP", offsetX=288, offsetY=88 },
            main = { anchorH="LEFT", anchorV="TOP", offsetX=95, offsetY=105, collapsed=false },
            -- Dashboard split preferences are normalized ratios, not pixels.
            -- They are populated only after the player drags a splitter, so
            -- untouched installs continue to use the responsive default solver.
            dashboard = { activityRatio=nil, middleRatio=nil },
            widgets = {
                task={ visible=false, mode="standard", titleVisible=true, collapsed=false, locked=false, clickThrough=false, anchorH="RIGHT", anchorV="TOP", offsetX=16, offsetY=80 },
                trade={ visible=false, mode="standard", titleVisible=true, collapsed=false, locked=false, clickThrough=false, anchorH="RIGHT", anchorV="TOP", offsetX=16, offsetY=120 },
                bond={ visible=false, mode="standard", titleVisible=true, collapsed=false, locked=false, clickThrough=false, anchorH="RIGHT", anchorV="TOP", offsetX=16, offsetY=160 },
                event={ visible=false, mode="standard", titleVisible=true, collapsed=false, locked=false, clickThrough=false, anchorH="RIGHT", anchorV="TOP", offsetX=16, offsetY=200 },
                treasure={ visible=false, mode="standard", titleVisible=true, collapsed=false, locked=false, clickThrough=false, anchorH="RIGHT", anchorV="TOP", offsetX=16, offsetY=240 },
                fishing={ visible=false, mode="standard", titleVisible=true, collapsed=false, locked=false, clickThrough=false, anchorH="RIGHT", anchorV="TOP", offsetX=16, offsetY=280 },
            },
            -- Dialogs use the same logical-edge placement schema as HUDs, but
            -- are not part of HUD edit mode or visibility policy.
            dialogs = {
                trade_detail={ width=580, height=430, fontScale=1.0, backgroundAlpha=0.90, userMoved=false },
            },
        },
        life = {
            trade = { fromZone=nil, toZone=nil, routeConfirmed=false, favorites={} },
            auctionFavorites = { items = {} },
            hiddenEvents = {},
            -- Daily tracking is an explicit user view preference.  Until the
            -- player customizes it, configured=false preserves the historical
            -- behaviour where every curated daily group is visible.  Once
            -- configured, new daily groups are opt-in instead of silently
            -- appearing on an established personal checklist.
            dailyTracking = { configured=false, keys={} },
            -- Per-character activity-task selection.  A group is materialized
            -- only after the player changes one of its task checkboxes. Before
            -- that, QuestService preserves the historical default: canonical
            -- objectives tracked, related/optional objectives not tracked.
            eventTaskTracking = { formatVersion=3, groups={} },
            bondCache = { dateKey = "unknown", west = nil, east = nil, auroria = nil, completedMainlandBondKeys = {} },
            bondSortMode = "continent",
            -- Bond-board display filter. All categories are visible by default;
            -- this preference only affects presentation and never capture/data.
            bondFilter = { q20 = true, q60 = true, q100 = true, auroria = true, excludeSame = false, priority = "west" },
            -- Retained only for compatibility with saved data from older builds.
            -- Current Cinderstone/Ynystere status tracks the actual once-per-day
            -- Industry Dynamo reward quests and no longer depends on this latch.
            eventDailyDone = { dateKey = "unknown", keys = {} },
        },
        profiles = { features = {}, huds = {}, combos = {} },
        product = { lastSeenVersion = "", updateNoticeDismissed = false, lastPage = "life", favorites = {} },
        dailyCounters = { dateKey="unknown", gold=0, honor=0, vocation=0, exp=0 },
    },
}
