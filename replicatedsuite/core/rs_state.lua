------------------------------------------------------------------------
-- Replicated Suite - Unified State Authority
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local C = S.Constants

local DeepCopy = S.Reuse.Table.DeepCopy

local defaults = type(S.Config) == "table" and type(S.Config.Defaults) == "table" and S.Config.Defaults or {}
S.State = {
    schemaVersion = C.SaveSchemaVersion,
    settings = DeepCopy(defaults.settings or {}),
    modules = DeepCopy(defaults.modules or {}),
    ui = DeepCopy(defaults.ui or {}),
    life = DeepCopy(defaults.life or {}),
    profiles = DeepCopy(defaults.profiles or {}),
    product = DeepCopy(defaults.product or {}),
    dailyCounters = DeepCopy(defaults.dailyCounters or {}),
    runtime = { activePage="life", layoutRevision=0, dirty={}, dataRevision=0 },
    data = {
        summary={ unfinished=0, turnIn=0, nextEvent="--", bonds=nil },
        daily={}, weekly={}, resources={}, events={}, eventQuestProgress={}, instanceRaidEntries={}, character={},
        trade={ status="idle", fromZone=nil, toZone=nil, route="请选择路线", rows={}, zones={}, sellableZones={}, updatedAt=0, error=nil },
        selectedQuestGroup={ scope=nil, key=nil },
        resident={ status="idle", faction="--", location="unknown", continentKey=nil, rows={}, error=nil },
        bondBoard={ dateKey="unknown", currentContinent=nil, continents={}, materials={}, error=nil },
        residentStages={},
        auction={ status="idle", active=false, query=nil, error=nil },
        treasure={ status="idle", maps={}, selectedKey=nil, direction="--", directionShort="--", arrow="--", bearing=nil, distance=nil, error=nil },
        fishing={ status="idle", buffId=nil, slot=nil, auto=false, message="未启用" },
        combat={ dps=false, healer=false, gear=false, plates=false },
        teamUtility={
            roleEnabled=(defaults.settings or {}).teamAutoRoleEnabled==true,
            roleStatus=(defaults.settings or {}).teamAutoRoleEnabled==true and "等待识别" or "关闭",
            roleLabel="--", classKey="--",
            sacEnabled=(defaults.settings or {}).sacMarkerEnabled==true, sacCandidates=0, sacActive=0,
            damageReviewEnabled=(defaults.settings or {}).damageReviewEnabled==true,
            damageReviewHistory=0, damageReviewBuffered=0,
            markerScaleAvailable=true, markerScale=tonumber((defaults.settings or {}).markerScale) or 1.20,
        },
    },
}

local State = S.State

local function CopyPlacement(target, source)
    if type(target)~="table" or type(source)~="table" then return end
    if source.anchorH=="RIGHT" then target.anchorH="RIGHT" elseif source.anchorH=="LEFT" then target.anchorH="LEFT" end
    if source.anchorV=="BOTTOM" then target.anchorV="BOTTOM" elseif source.anchorV=="TOP" then target.anchorV="TOP" end
    target.offsetX=math.max(0,tonumber(source.offsetX) or tonumber(target.offsetX) or 0)
    target.offsetY=math.max(0,tonumber(source.offsetY) or tonumber(target.offsetY) or 0)
    for _,key in ipairs({"visible","locked","clickThrough","userMoved","collapsed","titleVisible"}) do if source[key]~=nil then target[key]=source[key]==true end end
    if source.mode=="mini" or source.mode=="collapsed" or source.mode=="standard" then target.mode=source.mode end
    if target.mode=="collapsed" or target.mode=="mini" then target.collapsed=true elseif source.collapsed==nil then target.collapsed=false end
    local width=tonumber(source.width); if width and width>0 then target.width=width end
    local height=tonumber(source.height); if height and height>0 then target.height=height end
    local opacity=tonumber(source.opacity); if opacity then target.opacity=math.max(0.0,math.min(1.0,opacity)) end
    local fontScale=tonumber(source.fontScale); if fontScale then target.fontScale=math.max(0.50,math.min(2.00,fontScale)) end
    local backgroundAlpha=tonumber(source.backgroundAlpha); if backgroundAlpha then target.backgroundAlpha=math.max(0.0,math.min(1.0,backgroundAlpha)) end
    for _,key in ipairs({"fontInherited","backgroundInherited","compact","compactInherited","sizeMode"}) do if source[key]~=nil then target[key]=source[key] end end
    if source.customTitle~=nil then target.customTitle=tostring(source.customTitle) end
    -- Professional HUD adapters may attach UI-only profile data (for example
    -- Gear per-loadout quick-button positions). Keep that opaque to Core while
    -- preserving it across Suite save/load and HUD profile copies.
    if type(source.profileExtra)=="table" then target.profileExtra=DeepCopy(source.profileExtra) end
end

function State:MarkDirty(section)
    self.runtime.dirty[section or "all"] = true
    self.runtime.dataRevision = (tonumber(self.runtime.dataRevision) or 0) + 1
end
function State:ConsumeDirty()
    local copy=self.runtime.dirty; self.runtime.dirty={}; return copy
end
function State:HasDirty() for _ in pairs(self.runtime.dirty) do return true end return false end

function State:ApplySaved(saved)
    if type(saved)~="table" then return end
    self.lastLoadedSchema = tonumber(saved.version) or 0
    local settings=type(saved.settings)=="table" and saved.settings or {}
    local scale=tonumber(settings.addonScale); if scale then self.settings.addonScale=math.max(C.MinAddonScale,math.min(C.MaxAddonScale,scale)) end
    local opacity=tonumber(settings.opacity); if opacity then self.settings.opacity=math.max(0.35,math.min(1,opacity)) end
    local contentOpacity=tonumber(settings.contentOpacity); if contentOpacity then self.settings.contentOpacity=math.max(0.0,math.min(1,contentOpacity)) end
    local fontScale=tonumber(settings.fontScale); if fontScale then self.settings.fontScale=math.max(1.00,math.min(1.50,fontScale)) end
    local dataRefreshMs=tonumber(settings.dataRefreshMs); if dataRefreshMs then self.settings.dataRefreshMs=math.max(5000,math.min(60000,dataRefreshMs)) end
    local tradeAutoRefreshMs=tonumber(settings.tradeAutoRefreshMs); if tradeAutoRefreshMs then self.settings.tradeAutoRefreshMs=math.max(30000,math.min(300000,tradeAutoRefreshMs)) end
    local eventFontAdjust=tonumber(settings.eventFontAdjust)
    if eventFontAdjust then self.settings.eventFontAdjust=math.max(-2,math.min(4,math.floor(eventFontAdjust+0.5))) end
    if settings.defaultStartPage~=nil then self.settings.defaultStartPage=tostring(settings.defaultStartPage) end
    if settings.diagnosticsLevel=="off" or settings.diagnosticsLevel=="error" or settings.diagnosticsLevel=="warning" or settings.diagnosticsLevel=="debug" or settings.diagnosticsLevel=="verbose" then self.settings.diagnosticsLevel=settings.diagnosticsLevel end
    local hudFont=tonumber(settings.globalHudFontScale); if hudFont then self.settings.globalHudFontScale=math.max(0.50,math.min(2.00,hudFont)) end
    local hudAlpha=tonumber(settings.globalHudBackgroundAlpha); if hudAlpha then self.settings.globalHudBackgroundAlpha=math.max(0.0,math.min(1.0,hudAlpha)) end
    for _,k in ipairs({"globalCompactMode","hudSnapEnabled","hudCloseButtonEnabled"}) do if settings[k]~=nil then self.settings[k]=settings[k]==true end end
    for _,k in ipairs({"entryLocked","mainLocked","showCompletedTasks","onlyIncompleteTasks","tradeAutoRefresh","showCombatLaunchers","teamAutoRoleEnabled","sacMarkerEnabled","damageReviewEnabled","damageReviewAutoShow","damageReviewShowDebuffs","markerScaleOverride"}) do if settings[k]~=nil then self.settings[k]=settings[k]==true end end
    -- Target Detection Authority settings. Frequencies are clamped so a corrupt
    -- or hand-edited save can never drive an unbounded per-frame API scan.
    if settings.targetDetectionEnabled ~= nil then self.settings.targetDetectionEnabled = settings.targetDetectionEnabled == true end
    if settings.targetDetectionQueueRetain ~= nil then self.settings.targetDetectionQueueRetain = settings.targetDetectionQueueRetain == true end
    local tdFast=tonumber(settings.targetDetectionFastMs); if tdFast then self.settings.targetDetectionFastMs=math.max(60,math.min(1000,tdFast)) end
    local tdNormal=tonumber(settings.targetDetectionNormalMs); if tdNormal then self.settings.targetDetectionNormalMs=math.max(120,math.min(2000,tdNormal)) end
    local tdSlow=tonumber(settings.targetDetectionSlowMs); if tdSlow then self.settings.targetDetectionSlowMs=math.max(500,math.min(30000,tdSlow)) end
    local tdLimit=tonumber(settings.targetDetectionEffectLimit); if tdLimit then self.settings.targetDetectionEffectLimit=math.max(1,math.min(64,tdLimit)) end
    local tdCache=tonumber(settings.targetDetectionCacheSize); if tdCache then self.settings.targetDetectionCacheSize=math.max(1,math.min(128,tdCache)) end
    local tdTtl=tonumber(settings.targetDetectionCacheTtlMs); if tdTtl then self.settings.targetDetectionCacheTtlMs=math.max(5000,math.min(600000,tdTtl)) end
    -- Bag organizer settings are account-scoped presentation/action preferences.
    -- Runtime queue/snapshots are never persisted.
    for _,k in ipairs({"bagOrganizerShowBagButtons","bagOrganizerRequireBankOpen","bagOrganizerAllowNameFallback","bagOrganizerReportResults"}) do
        if settings[k]~=nil then self.settings[k]=settings[k]==true end
    end
    -- Bag organizer blacklist is an account-scoped settings tree. Accept only a
    -- complete shape (enabled + bank/coffer each with categories/items subtables);
    -- anything else is replaced by the default structure. Keys inside the four
    -- subtables are intentionally not deep-cleaned: hand-edited values are the
    -- user's own responsibility and IsBlocked treats them as opaque lookups.
    do
        local bl = settings.bagOrganizerBlacklist
        local bank = type(bl) == "table" and bl.bank or nil
        local coffer = type(bl) == "table" and bl.coffer or nil
        local valid = type(bank) == "table" and type(bank.categories) == "table" and type(bank.items) == "table"
            and type(coffer) == "table" and type(coffer.categories) == "table" and type(coffer.items) == "table"
        if valid then
            local kept = DeepCopy(bl)
            kept.enabled = bl.enabled == true
            self.settings.bagOrganizerBlacklist = kept
        else
            local fallback = type(defaults.settings) == "table" and defaults.settings.bagOrganizerBlacklist or nil
            self.settings.bagOrganizerBlacklist = DeepCopy(fallback or {
                enabled = false,
                bank = { categories = {}, items = {} },
                coffer = { categories = {}, items = {} },
            })
        end
    end
    local damageReviewWindow=tonumber(settings.damageReviewWindowMs); if damageReviewWindow then self.settings.damageReviewWindowMs=math.max(3000,math.min(20000,math.floor(damageReviewWindow+0.5))) end
    local damageReviewHistory=tonumber(settings.damageReviewMaxHistory); if damageReviewHistory then self.settings.damageReviewMaxHistory=math.max(1,math.min(30,math.floor(damageReviewHistory+0.5))) end
    local damageReviewMinDamage=tonumber(settings.damageReviewMinDamage); if damageReviewMinDamage then self.settings.damageReviewMinDamage=math.max(0,math.min(5000,math.floor(damageReviewMinDamage+0.5))) end
    -- Craft station material assist (P1-3). Account-scoped presentation
    -- preferences; accept only the complete two-boolean shape, otherwise fall
    -- back to the default structure (same policy as bagOrganizerBlacklist).
    -- G2: width/height clamped to the resize bounds (420-840 x 320-680).
    do
        local craft = settings.craftAssist
        if type(craft) == "table" then
            local kept = DeepCopy(craft)
            kept.enabled = craft.enabled == true
            kept.autoShow = craft.autoShow ~= false
            local w = tonumber(craft.width)
            local h = tonumber(craft.height)
            kept.width = math.floor((w == nil or w ~= w) and 560 or math.max(420, math.min(840, w)) + 0.5)
            kept.height = math.floor((h == nil or h ~= h) and 430 or math.max(320, math.min(680, h)) + 0.5)
            self.settings.craftAssist = kept
        else
            local fallback = type(defaults.settings) == "table" and defaults.settings.craftAssist or nil
            self.settings.craftAssist = DeepCopy(fallback or { enabled = true, autoShow = true, width = 560, height = 430 })
        end
    end
    local organizerInterval=tonumber(settings.bagOrganizerMoveIntervalMs)
    if organizerInterval then self.settings.bagOrganizerMoveIntervalMs=math.max(200,math.min(1000,math.floor(organizerInterval+0.5))) end
    local organizerMax=tonumber(settings.bagOrganizerMaxMoves)
    if organizerMax then self.settings.bagOrganizerMaxMoves=math.max(0,math.min(500,math.floor(organizerMax+0.5))) end
    if settings.bagOrganizerButtonSide=="right" or settings.bagOrganizerButtonSide=="inside" then
        self.settings.bagOrganizerButtonSide=settings.bagOrganizerButtonSide
    end
    -- One-time migration latches are persisted too. Dropping this field during
    -- load made the old BUFF-HUD visibility repair run again on every login and
    -- could re-open both HUDs after the user intentionally hid them.
    if settings.platesHudVisibilityRepairV1011 ~= nil then
        self.settings.platesHudVisibilityRepairV1011 = settings.platesHudVisibilityRepairV1011 == true
    end
    if settings.teamRoleMode=="auto" or settings.teamRoleMode=="healer" or settings.teamRoleMode=="tank" or settings.teamRoleMode=="dealer" or settings.teamRoleMode=="ranged" then self.settings.teamRoleMode=settings.teamRoleMode end
    local markerScale=tonumber(settings.markerScale); if markerScale then self.settings.markerScale=math.max(0.50,math.min(2.00,markerScale)) end
    -- The floating "R" button is the canonical recovery/entry point for the
    -- Suite. Older builds persisted showEntry=false even though the current UI
    -- has no reachable control that can restore the button once hidden. Do not
    -- import that stale hidden state: the primary entry must always recover on
    -- load.
    self.settings.showEntry = true
    if tonumber(settings.eventMaxRows) then
        if (tonumber(saved.version) or 0) < 4 then
            -- Older builds defaulted to only five events; migrate that sparse
            -- view to the comprehensive first-version target.
            self.settings.eventMaxRows = 20
        else
            self.settings.eventMaxRows=math.max(5,math.min(20,tonumber(settings.eventMaxRows)))
        end
    end
    if settings.tradeSortMode=="ratio" or settings.tradeSortMode=="price" then self.settings.tradeSortMode=settings.tradeSortMode end
    if settings.eventReminderMode=="off" or settings.eventReminderMode=="5" or settings.eventReminderMode=="15_5" then self.settings.eventReminderMode=settings.eventReminderMode end
    local savedModules=type(saved.modules)=="table" and saved.modules or {}
    for id, target in pairs(self.modules or {}) do
        local source=savedModules[id]
        if type(source)=="table" and source.enabled~=nil then target.enabled=source.enabled==true
        elseif type(source)=="boolean" then target.enabled=source==true end
    end
    local ui=type(saved.ui)=="table" and saved.ui or {}; CopyPlacement(self.ui.entry,ui.entry); CopyPlacement(self.ui.main,ui.main)
    -- M6-v7 dashboard splitter preferences are normalized presentation-only
    -- ratios.  Keep them opaque to business modules and clamp corrupt saves so
    -- the responsive solver can always preserve all three dashboard bands.
    self.ui.dashboard = type(self.ui.dashboard)=="table" and self.ui.dashboard or {}
    local dashboard = type(ui.dashboard)=="table" and ui.dashboard or {}
    local activityRatio = tonumber(dashboard.activityRatio)
    local middleRatio = tonumber(dashboard.middleRatio)
    if activityRatio then self.ui.dashboard.activityRatio=math.max(0.18,math.min(0.58,activityRatio)) end
    if middleRatio then self.ui.dashboard.middleRatio=math.max(0.22,math.min(0.62,middleRatio)) end
    local widgets=type(ui.widgets)=="table" and ui.widgets or {}
    -- Preserve placements for HUDs registered after State load (professional
    -- Gear/Plates/DPS adapters).  The old loop only copied IDs present in the
    -- built-in defaults, so professional HUD visibility/lock/profileExtra was
    -- silently lost on every relog before HudManager had a chance to register.
    for name,source in pairs(widgets) do
        name=tostring(name or "")
        if name~="" and type(source)=="table" then
            self.ui.widgets[name]=type(self.ui.widgets[name])=="table" and self.ui.widgets[name] or {}
            CopyPlacement(self.ui.widgets[name],source)
        end
    end
    local dialogs=type(ui.dialogs)=="table" and ui.dialogs or {}
    self.ui.dialogs=type(self.ui.dialogs)=="table" and self.ui.dialogs or {}
    for name,source in pairs(dialogs) do
        name=tostring(name or "")
        if name~="" and type(source)=="table" then
            self.ui.dialogs[name]=type(self.ui.dialogs[name])=="table" and self.ui.dialogs[name] or {}
            CopyPlacement(self.ui.dialogs[name],source)
        end
    end
    local life=type(saved.life)=="table" and saved.life or {}
    if type(life.trade)=="table" then
        self.life.trade.favorites=type(life.trade.favorites)=="table" and life.trade.favorites or {}
        -- v0.2.1 and earlier automatically selected a route on startup.  Do not
        -- restore those implicit values: from v4 onward a route is persisted
        -- only after the user explicitly selects both dropdowns.
        if tonumber(saved.version) ~= nil and tonumber(saved.version) >= 4 and life.trade.routeConfirmed == true then
            self.life.trade.fromZone=tonumber(life.trade.fromZone)
            self.life.trade.toZone=tonumber(life.trade.toZone)
            self.life.trade.routeConfirmed=self.life.trade.fromZone~=nil and self.life.trade.toZone~=nil
        end
    end
    -- Account-scoped Auction Favorites. The saved shape is intentionally simple
    -- (ordered strings only) so adding this feature remains backward-compatible
    -- with Schema 20 while avoiding another cross-domain migration.
    do
        local source = type(life.auctionFavorites)=="table" and life.auctionFavorites or nil
        local rawItems = source and (type(source.items)=="table" and source.items or source) or nil
        local items, seen = {}, {}
        if type(rawItems)=="table" then
            for _, value in ipairs(rawItems) do
                local text=tostring(type(value)=="table" and (value.text or value.name) or value or "")
                text=text:gsub("[\r\n]", " "):match("^%s*(.-)%s*$") or ""
                if text~="" then
                    local key=string.lower(text)
                    if not seen[key] then
                        seen[key]=true
                        items[#items+1]=text
                        if #items>=200 then break end
                    end
                end
            end
        end
        self.life.auctionFavorites={items=items}
    end
    if type(life.damageReviewHistory)=="table" then
        self.life.damageReviewHistory = DeepCopy(life.damageReviewHistory)
    end
    if type(life.hiddenEvents)=="table" then self.life.hiddenEvents=life.hiddenEvents end
    if type(life.dailyTracking)=="table" then
        local savedTracking = life.dailyTracking
        local keys = {}
        if type(savedTracking.keys)=="table" then
            for key, enabled in pairs(savedTracking.keys) do
                if enabled == true then keys[tostring(key)] = true end
            end
        end
        self.life.dailyTracking = { configured = savedTracking.configured == true, keys = keys }
    end
    if type(life.eventTaskTracking)=="table" then
        local groups = {}
        for groupKey, savedGroup in pairs(type(life.eventTaskTracking.groups)=="table" and life.eventTaskTracking.groups or {}) do
            if type(savedGroup)=="table" then
                local keys = {}
                for trackingKey, enabled in pairs(type(savedGroup.keys)=="table" and savedGroup.keys or {}) do
                    if enabled==true or enabled==false then keys[tostring(trackingKey)] = enabled==true end
                end
                groups[tostring(groupKey)] = { configured=savedGroup.configured==true, keys=keys }
            end
        end
        self.life.eventTaskTracking = {
            formatVersion = tonumber(life.eventTaskTracking.formatVersion) or 1,
            groups = groups,
        }
    end
    if type(life.bondCache)=="table" then
        local completedMainlandBondKeys = {}
        if type(life.bondCache.completedMainlandBondKeys) == "table" then
            for key, completed in pairs(life.bondCache.completedMainlandBondKeys) do
                if completed == true then completedMainlandBondKeys[tostring(key)] = true end
            end
        end
        self.life.bondCache = {
            dateKey = tostring(life.bondCache.dateKey or "unknown"),
            west = type(life.bondCache.west)=="table" and life.bondCache.west or nil,
            east = type(life.bondCache.east)=="table" and life.bondCache.east or nil,
            auroria = type(life.bondCache.auroria)=="table" and life.bondCache.auroria or nil,
            -- Daily mainland material+quantity completion is persistent Authority.
            -- Dropping it here made a correctly saved cache forget shared
            -- completion after relog until the live quest API rediscovered it.
            completedMainlandBondKeys = completedMainlandBondKeys,
        }
    end
    do
        local savedSortMode=tostring(life.bondSortMode or "")
        if savedSortMode=="quantity" or savedSortMode=="asc" or savedSortMode=="desc" then
            self.life.bondSortMode="quantity"
        elseif savedSortMode=="continent" or savedSortMode=="none" then
            self.life.bondSortMode="continent"
        end
    end
    if type(life.bondFilter)=="table" then
        local savedFilter=life.bondFilter
        self.life.bondFilter=self.life.bondFilter or {q20=true,q60=true,q100=true,auroria=true,excludeSame=false,priority="west"}
        for _,key in ipairs({"q20","q60","q100","auroria","excludeSame"}) do
            if savedFilter[key]~=nil then self.life.bondFilter[key]=savedFilter[key]==true end
        end
        local savedPriority=tostring(savedFilter.priority or "")
        if savedPriority=="west" or savedPriority=="east" then self.life.bondFilter.priority=savedPriority end
    end
    if type(life.eventDailyDone)=="table" then
        local keys={}
        if type(life.eventDailyDone.keys)=="table" then
            for key,value in pairs(life.eventDailyDone.keys) do if value==true then keys[tostring(key)]=true end end
        end
        self.life.eventDailyDone={dateKey=tostring(life.eventDailyDone.dateKey or "unknown"),keys=keys}
    end
    if type(saved.profiles)=="table" then
        self.profiles = DeepCopy(saved.profiles)
        self.profiles.features = type(self.profiles.features)=="table" and self.profiles.features or {}
        self.profiles.huds = type(self.profiles.huds)=="table" and self.profiles.huds or {}
        self.profiles.combos = type(self.profiles.combos)=="table" and self.profiles.combos or {}
    end
    if type(saved.product)=="table" then
        self.product.lastSeenVersion=tostring(saved.product.lastSeenVersion or "")
        self.product.updateNoticeDismissed=saved.product.updateNoticeDismissed==true
        self.product.lastPage=tostring(saved.product.lastPage or self.product.lastPage or "life")
        self.product.favorites={}
        if type(saved.product.favorites)=="table" then
            for _,id in ipairs(saved.product.favorites) do if tostring(id or "")~="" then self.product.favorites[#self.product.favorites+1]=tostring(id) end end
        end
    end
    if type(saved.dailyCounters)=="table" then
        self.dailyCounters.dateKey=tostring(saved.dailyCounters.dateKey or "unknown")
        for _,k in ipairs({"gold","honor","vocation","exp"}) do self.dailyCounters[k]=tonumber(saved.dailyCounters[k]) or 0 end
    end
end

-- Character Override is intentionally limited to Suite-owned state whose
-- scope is already unambiguous. Professional module Domain persistence keeps
-- Module enabled state and team/damage-review feature toggles are Account-scoped
-- usage habits (Schema 21). Character Override retains only true per-character
-- business data (daily/event task tracking, damage-review history, counters).
local function CopyDailyTracking(source)
    if type(source) ~= "table" then return nil end
    local keys = {}
    if type(source.keys) == "table" then
        for key, enabled in pairs(source.keys) do
            if enabled == true then keys[tostring(key)] = true end
        end
    end
    return { configured = source.configured == true, keys = keys }
end

local function CopyEventTaskTracking(source)
    if type(source) ~= "table" then return nil end
    local groups = {}
    for groupKey, sourceGroup in pairs(type(source.groups)=="table" and source.groups or {}) do
        if type(sourceGroup)=="table" then
            local keys = {}
            for trackingKey, enabled in pairs(type(sourceGroup.keys)=="table" and sourceGroup.keys or {}) do
                if enabled==true or enabled==false then keys[tostring(trackingKey)] = enabled==true end
            end
            groups[tostring(groupKey)] = { configured=sourceGroup.configured==true, keys=keys }
        end
    end
    return { formatVersion = tonumber(source.formatVersion) or 1, groups = groups }
end

local function CopyEventDailyDone(source)
    if type(source) ~= "table" then return nil end
    local keys = {}
    if type(source.keys) == "table" then
        for key, enabled in pairs(source.keys) do
            if enabled == true then keys[tostring(key)] = true end
        end
    end
    return { dateKey = tostring(source.dateKey or "unknown"), keys = keys }
end

function State:ApplyCharacterOverride(saved)
    if type(saved) ~= "table" then return false end

    -- Schema 21: module enabled state and team/damage-review feature toggles are
    -- Account-scoped and restored by ApplySaved from the Account base. Character
    -- Override applies only per-character business data below.

    local life = type(saved.life) == "table" and saved.life or {}
    local tracking = CopyDailyTracking(life.dailyTracking)
    if tracking ~= nil then self.life.dailyTracking = tracking end
    local eventTaskTracking = CopyEventTaskTracking(life.eventTaskTracking)
    if eventTaskTracking ~= nil then self.life.eventTaskTracking = eventTaskTracking end
    local eventDone = CopyEventDailyDone(life.eventDailyDone)
    if eventDone ~= nil then self.life.eventDailyDone = eventDone end
    if type(life.damageReviewHistory) == "table" then self.life.damageReviewHistory = DeepCopy(life.damageReviewHistory) end
    return true
end

function State:BuildCharacterOverride()
    local result = { life = {} }
    result.life.dailyTracking = CopyDailyTracking(self.life and self.life.dailyTracking)
    result.life.eventTaskTracking = CopyEventTaskTracking(self.life and self.life.eventTaskTracking)
    result.life.eventDailyDone = CopyEventDailyDone(self.life and self.life.eventDailyDone)
    if self.life and type(self.life.damageReviewHistory) == "table" then result.life.damageReviewHistory = DeepCopy(self.life.damageReviewHistory) end
    -- dailyCounters (今日收益等) is Account-scoped usage data (Schema 21):
    -- it must survive a relog independent of world-qualified identity, so it
    -- stays in the Account base and is never serialized into Character Override.
    return result
end

function State:BuildSavePayload()
    -- Storage payloads are value snapshots, never aliases into Runtime State.
    -- This keeps migration/serialization helpers from accidentally mutating
    -- live settings while restoring Account-base fields into the payload.
    return DeepCopy({
        version=C.SaveSchemaVersion, settings=self.settings, modules=self.modules,
        ui=self.ui, life=self.life, profiles=self.profiles, product=self.product,
        dailyCounters=self.dailyCounters,
    })
end
