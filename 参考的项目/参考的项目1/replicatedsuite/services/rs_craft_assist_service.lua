-----------------------------------------------------------------------
-- Replicated Suite - Craft Station Material Assist Service (P1-3 / H3)
-- Author: Replicated
--
-- Purpose:
--   While a craft station (pack production table) is open, show a helper
--   panel listing the packs producible in the current zone group, with each
--   pack's material list (required count) and the player's bag counts.
--   Material rows carry 取/放/拍卖 buttons reusing the P1-2 directed move
--   (BagOrganizer:Begin(direction, {itemType=...})) and auction favorites
--   (AddFavorite + Search) chains.
--
-- Detection / data chain (H3, learned from the legacy replicatedsuite):
--   * Events are LATCHES, not direct open commands. TOGGLE_CRAFT /
--     CRAFT_DOODAD_INFO set the craftSignalOpen latch and immediately run the
--     watcher; NPC_CRAFT_UPDATE / CRAFTING_START / CRAFT_STARTED do the same;
--     INTERACTION_START* start a short-lived Probe (80ms, retried 150ms,
--     max 4 attempts) that consults the specialty-workbench coordinates.
--   * A 400ms watcher (WatchCraftGuide) is the authoritative judge: it reads
--     the UIC_CRAFT_BOOK visibility three ways -- content widget parent chain
--     (ADDON:GetContent + GetParent() walk, the same pattern the auction
--     favorites window uses), GetContentMainScriptPosVis, and the event latch
--     as a fallback when both native reads are unknown.
--   * Approval gate: the first time the Craft Book becomes visible the watcher
--     consults the workbench coordinates (radius 10) and only then shows the
--     sidecar. Ordinary Craft Book use (not beside a recognized workbench)
--     never surfaces it. Coordinates are consulted ONLY after an interaction
--     event / visibility transition -- there is no proximity polling loop.
--   * Closing the native Craft Book does NOT destroy the sidecar: it becomes
--     a carried work order the player may walk to a bank/coffer with. The
--     player's own × dismisses it (sessionDismissed) until the next session.
--   * Zone packs come from X2Unit:GetCurrentZoneGroup() -> GetSellableZoneGroups
--     -> GetSpecialtyRatioBetween() and the SPECIALTY_RATIO_BETWEEN_INFO
--     event, exactly like the trade service. That event carries no route
--     identity, so this service only fires a query while the Trade service is
--     idle (inFlight/pending == nil) and only consumes the event while its own
--     ratioQuery marker is set. A stale query is cleared after 5s.
--   * Bag counts are aggregated once per user action (open / pack switch /
--     manual refresh) from a single BagOrganizer:ScanBag(); never polled.
--
-- Performance:
--   * The 400ms watcher only reads native visibility and short-circuits when
--     the feature is disabled or no craft station is visible. Zero API calls
--     while hidden/disabled.
--   * No inventory scanning, no recipe lookups on Tick. Coordinates are read
--     at most once per open transition (and per Probe attempt).
-----------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}
S.Services.CraftAssist = {
    started = false,
    openKind = nil,          -- last detected UIC candidate ("book"|"order"|"make"), informational
    craftSignalOpen = false, -- event latch: an open signal was observed
    craftGuideApproved = false, -- approval gate passed (beside a workbench)
    craftGuideZone = nil,    -- zone that opened the carried sidecar (fixed)
    lastCraftVisible = false, -- last watcher judgement on Craft Book visibility
    lastCraftSignal = nil,   -- last signal name that opened the session
    lastCraftRect = nil,     -- cached craft-station rect (stable-follow path)
    lastZoneRequestAt = nil, -- throttle: zone-pack query cooldown after failures
    stableTick = 0,          -- stable-follow sampling counter (reduce PosVis rate)
    lastUiSignalAt = nil,    -- throttle: UI switch signal (TOGGLE_CRAFT) 1s debounce
    ratioQuery = nil,        -- { from=, to=, at= } while a zone query is in flight
    packs = nil,             -- latest zone pack rows ({name=, itemType=})
    bagCountByType = nil,    -- latest bag count aggregation
    lastZoneGroup = nil,     -- zone group id used for the last pack assembly
    lastError = nil,
    lastMessage = "等待制作台",
    -- Runtime counters for diagnostics (2026-08-24): counts every hot path so
    -- the 检测诊断 output can show EXACTLY what runs while the station is open
    -- (watcher ticks, stable samples, actual window Shows, zone queries, bag
    -- scans, event arrivals). Reset on Start.
    stats = {
        watchTicks = 0,        -- WatchCraftGuide total entries
        stableSamples = 0,     -- stable-follow sampled ticks (PosVis reads)
        fullReads = 0,         -- full ReadCraftBookVisibility calls
        showCalls = 0,         -- ShowCraftGuide entries
        showActual = 0,        -- ShowCraftGuide that really called window:Show
        zoneRequests = 0,      -- RequestZonePacks entries
        zoneRequestsThrottled = 0, -- throttled zone requests
        bagScans = 0,          -- CountBagByType entries (full bag scan)
        openTransitions = 0,   -- Craft Book open transitions (approval ran)
        windowRefresh = 0,     -- window Refresh() calls (window-side)
        officialNameScans = 0, -- ResolveOfficialName calls that scanned storage
        events = {},           -- [eventName] = count of latch signals received
    },
    -- Event ring log (2026-08-24): last N latch-signal arrivals with their
    -- debounce outcome, so "second open does not pop" can be diagnosed (did the
    -- event arrive? was it throttled? did the latch actually flip?).
    eventLog = {},
}
local C = S.Services.CraftAssist

local TASK_VISIBILITY = "craft_assist_craft_visibility"
local TASK_PROBE = "craft_assist_craft_probe"
local QUERY_TIMEOUT_MS = 5000
local MAX_PACKS = 20
-- Refactor (2026-08-24): 400ms polling is enough for "open station -> panel
-- appears beside it" (snappy enough) while halving the per-session native-read
-- rate vs the old 200ms watcher. The watcher is now the ONLY detection path
-- (all craft event subscriptions removed).
local CRAFT_WATCH_MS = 400
local PROBE_FIRST_MS = 80
local PROBE_RETRY_MS = 150
local PROBE_MAX_ATTEMPTS = 4
local APPROVAL_RADIUS = 10
local CONTENT_CHAIN_MAX = 9

-- F2 diagnostic: static UIC candidate fallback. Mirrors the UIC_ globals in
-- api_functions.lua (main window/content categories); used when _G enumeration
-- is blocked by the sandbox. Diagnostic only - never read on the watcher path.
local DIAGNOSTIC_UIC_CANDIDATES = {
    "UIC_CRAFT_BOOK", "UIC_CRAFT_ORDER", "UIC_MAKE_CRAFT_ORDER",
    "UIC_BAG", "UIC_BANK", "UIC_COFFER", "UIC_AUCTION", "UIC_STORE",
    "UIC_CHARACTER_INFO", "UIC_PLAYER_EQUIPMENT", "UIC_SKILL", "UIC_QUEST_LIST",
    "UIC_WORLDMAP", "UIC_ACHIEVEMENT", "UIC_TRADE", "UIC_MAIL", "UIC_WHISPER",
    "UIC_PARTY", "UIC_RAID", "UIC_SQUAD", "UIC_FRIEND", "UIC_NATION",
    "UIC_EXPEDITION", "UIC_FAMILY", "UIC_OPTION_FRAME", "UIC_SYSTEM_CONFIG_FRAME",
    "UIC_GAME_EXIT_FRAME", "UIC_INGAME_SHOP", "UIC_BEAUTY_SHOP", "UIC_PREMIUM",
    "UIC_SPECIALTY_INFO", "UIC_SPECIALTY_BUY", "UIC_SPECIALTY_SELL",
    "UIC_MY_FARM_INFO", "UIC_BUTLER_INFO", "UIC_TRADER", "UIC_MAIN_ACTION_BAR",
    "UIC_DEATH_AND_RESURRECTION_WND", "UIC_GAME_TOOLTIP_WND", "UIC_RECOVER_EXP",
    "UIC_ITEM_REPAIR", "UIC_ENCHANT", "UIC_LOOK_CONVERT", "UIC_ABILITY_CHANGE",
    "UIC_RESIDENT_TOWNHALL", "UIC_EVENT_CENTER", "UIC_CHECK_BOT_WND",
}

-- Craft-station UIC candidates (kept for the F2 diagnostic and the manual
-- refresh path). Priority is a deliberate order: make > order > book.
local CRAFT_CANDIDATES = {
    { key = "make",  label = "制作订单" },
    { key = "order", label = "制作台" },
    { key = "book",  label = "制作手册" },
}

local function Trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function CapabilityAllowed(name)
    if S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function" then return false, "API boundary unavailable" end
    return S.Api:IsCapabilityAllowed(name)
end

-- Same native content position/visibility read BagOrganizer uses. Returns
-- true, {x,y,width,height,visible} or false, nil. No side effects.
local function ReadContentMainScriptPosVis(contentId)
    if contentId == nil or ADDON == nil then return false, nil end
    local allowed = CapabilityAllowed("ADDON:GetContentMainScriptPosVis")
    if allowed ~= true or type(ADDON.GetContentMainScriptPosVis) ~= "function" then return false, nil end
    local ok, x, y, width, height, visible = pcall(function()
        return ADDON:GetContentMainScriptPosVis(contentId)
    end)
    if not ok then return false, nil end
    return true, {
        x = tonumber(x),
        y = tonumber(y),
        width = tonumber(width),
        height = tonumber(height),
        visible = visible == true,
    }
end

local function ContentId(key)
    if key == "book" then return UIC_CRAFT_BOOK end
    if key == "order" then return UIC_CRAFT_ORDER end
    if key == "make" then return UIC_MAKE_CRAFT_ORDER end
    return nil
end

-- Pure decision: given {book=bool, order=bool, make=bool} visibility, return
-- the highest-priority open candidate or nil. Multiple visible candidates pick
-- by CRAFT_CANDIDATES order (make first). nil/false/absent entries are closed.
function C:Decision(visibleMap)
    local map = type(visibleMap) == "table" and visibleMap or {}
    for _, candidate in ipairs(CRAFT_CANDIDATES) do
        if map[candidate.key] == true then return candidate.key end
    end
    return nil
end

-- Read all three candidates and decide. Pure except for the three native
-- reads; used by the manual refresh button and the F2 diagnostic.
function C:CheckOpen()
    local visible = {}
    local readable = false
    for _, candidate in ipairs(CRAFT_CANDIDATES) do
        local id = ContentId(candidate.key)
        if id ~= nil then
            local ok, state = ReadContentMainScriptPosVis(id)
            if ok == true then
                readable = true
                visible[candidate.key] = state.visible == true
            end
        end
    end
    if readable == false then
        -- ADDON/GetContentMainScriptPosVis unavailable: no detection. The
        -- manual button remains the guaranteed fallback channel.
        return nil
    end
    return self:Decision(visible)
end

-- Best open candidate's native rect (for anchoring the panel to the station's
-- left side). Returns {x,y,width,height} or nil. Falls back through the
-- candidates in the same priority order. Used by the manual refresh path and
-- as the window's fallback anchor.
function C:GetOpenRect()
    local kind = self:CheckOpen()
    if kind == nil then return nil end
    local id = ContentId(kind)
    if id == nil then return nil end
    local ok, state = ReadContentMainScriptPosVis(id)
    if ok ~= true or type(state) ~= "table" or state.visible ~= true then return nil end
    return {
        x = tonumber(state.x),
        y = tonumber(state.y),
        width = tonumber(state.width),
        height = tonumber(state.height),
    }
end

-----------------------------------------------------------------------
-- H3 authoritative detection (legacy-replicatedsuite mechanism)
-----------------------------------------------------------------------

-- widget:IsVisible() through a pcall. Returns known, visible.
local function ReadWidgetVisible(widget)
    if widget == nil or type(widget.IsVisible) ~= "function" then return false, nil end
    local ok, value = pcall(function() return widget:IsVisible() end)
    if not ok then return false, nil end
    return true, value == true
end

-- Walk the content widget's parent chain (max CONTENT_CHAIN_MAX hops) and
-- treat the content as visible if ANY node in the chain reports IsVisible().
-- This is the auction-favorites pattern: the Craft Book content is mounted
-- under a parent that carries the actual visibility, so reading only the
-- content window's own PosVis would miss it.
local function ReadContentChainVisible(content)
    local node = content
    local anyKnown = false
    for _ = 0, CONTENT_CHAIN_MAX do
        if node == nil then break end
        local known, visible = ReadWidgetVisible(node)
        if known then
            anyKnown = true
            if visible then return true, true end
        end
        if type(node.GetParent) ~= "function" then break end
        local ok, parent = pcall(function() return node:GetParent() end)
        if not ok or parent == nil or parent == node then break end
        node = parent
    end
    return anyKnown, false
end

-- Current zone group id (X2Unit:GetCurrentZoneGroup), floor-normalized.
function C:GetCurrentZoneId()
    if X2Unit == nil then return nil end
    local ok, zoneId = S.Api:CallCapability("X2Unit:GetCurrentZoneGroup", X2Unit, "GetCurrentZoneGroup")
    zoneId = ok and tonumber(zoneId) or nil
    if zoneId == nil then return nil end
    return math.floor(zoneId)
end

local function DistanceSquared2D(ax, ay, bx, by)
    local dx = (tonumber(ax) or 0) - (tonumber(bx) or 0)
    local dy = (tonumber(ay) or 0) - (tonumber(by) or 0)
    return dx * dx + dy * dy
end

-- Nearest recognized specialty workbench for the current zone within radius
-- (2D world distance). Consults the coordinates ONLY when called -- i.e. after
-- an interaction event or an open transition, never on a poll. Returns
-- location, zoneId, distance or nil, zoneId, nil. No side effects.
function C:GetNearbyTradeCrafter(radius)
    radius = math.max(1, tonumber(radius) or APPROVAL_RADIUS)
    local locationsByZone = S.Data and S.Data.TradeCrafterLocationsByZone or nil
    if type(locationsByZone) ~= "table" or X2Unit == nil then return nil, nil, nil end
    local zoneId = self:GetCurrentZoneId()
    if zoneId == nil then return nil, nil, nil end
    local locations = locationsByZone[zoneId]
    if type(locations) ~= "table" or #locations == 0 then return nil, zoneId, nil end
    local posOk, x, _, y = S.Api:CallCapability("X2Unit:GetUnitWorldPositionByTarget", X2Unit, "GetUnitWorldPositionByTarget", "player", false)
    if posOk ~= true or tonumber(x) == nil or tonumber(y) == nil then return nil, zoneId, nil end
    local maxDistanceSq = radius * radius
    local nearest, nearestSq = nil, nil
    for _, location in ipairs(locations) do
        local distanceSq = DistanceSquared2D(x, y, location.x, location.y)
        if distanceSq <= maxDistanceSq and (nearestSq == nil or distanceSq < nearestSq) then
            nearest, nearestSq = location, distanceSq
        end
    end
    if nearest ~= nil then return nearest, zoneId, math.sqrt(nearestSq or 0) end
    return nil, zoneId, nil
end

-- ADDON:GetContent(UIC_CRAFT_BOOK) -> the Craft Book content widget, or nil.
function C:GetCraftBookContent()
    if UIC_CRAFT_BOOK == nil or ADDON == nil then return nil end
    if CapabilityAllowed("ADDON:GetContent") ~= true then return nil end
    local ok, value = S.Api:CallCapability("ADDON:GetContent", ADDON, "GetContent", UIC_CRAFT_BOOK)
    if ok and value ~= nil then return value end
    return nil
end

-- ADDON:GetContentMainScriptPosVis(UIC_CRAFT_BOOK) -> {x,y,width,height,visible}
-- or false, nil. visible is true when the signal says so, or when the signal
-- is absent but a real rect exists.
function C:ReadCraftBookState()
    if UIC_CRAFT_BOOK == nil or ADDON == nil then return false, nil end
    if CapabilityAllowed("ADDON:GetContentMainScriptPosVis") ~= true
        or type(ADDON.GetContentMainScriptPosVis) ~= "function" then return false, nil end
    local ok, x, y, width, height, visible = pcall(function()
        return ADDON:GetContentMainScriptPosVis(UIC_CRAFT_BOOK)
    end)
    if not ok then return false, nil end
    x, y, width, height = tonumber(x), tonumber(y), tonumber(width), tonumber(height)
    local hasRect = x ~= nil and y ~= nil and width ~= nil and height ~= nil and width > 0 and height > 0
    local hasSignal = visible ~= nil or x ~= nil or y ~= nil or width ~= nil or height ~= nil
    if not hasSignal then return false, nil end
    return true, {
        x = x, y = y, width = width, height = height,
        visible = visible == true or (visible == nil and hasRect),
    }
end

-- A plausible craft-station rect: real size (>=160), not fullscreen, on screen.
local function PlausibleCraftRect(x, y, width, height)
    local context = S.Layout and S.Layout:GetContext() or {}
    local logicalW = tonumber(context.logicalWidth) or 1024
    local logicalH = tonumber(context.logicalHeight) or 768
    x, y, width, height = tonumber(x), tonumber(y), tonumber(width), tonumber(height)
    if x == nil or y == nil or width == nil or height == nil or width < 160 or height < 160 then return false end
    if width > (logicalW * 0.98) or height > (logicalH * 0.98) then return false end
    if x > (logicalW + 64) or y > (logicalH + 64) or x + width < (-64) or y + height < (-64) then return false end
    return true
end

-- Best rect for anchoring: PosVis state first, then the content widget's
-- parent chain via S.Layout:GetLogicalRect.
function C:ResolveCraftBookRect(content, state)
    if type(state) == "table" and PlausibleCraftRect(state.x, state.y, state.width, state.height) then
        return { x = state.x, y = state.y, width = state.width, height = state.height }
    end
    local node = content
    for _ = 0, CONTENT_CHAIN_MAX do
        if node == nil then break end
        if S.Layout ~= nil and type(S.Layout.GetLogicalRect) == "function" then
            local ok, x, y, width, height = pcall(function() return S.Layout:GetLogicalRect(node) end)
            if ok and PlausibleCraftRect(x, y, width, height) then
                return { x = tonumber(x), y = tonumber(y), width = tonumber(width), height = tonumber(height) }
            end
        end
        if type(node.GetParent) ~= "function" then break end
        local ok, parent = pcall(function() return node:GetParent() end)
        if not ok or parent == nil or parent == node then break end
        node = parent
    end
    return nil
end

-- Three-way Craft Book visibility: content parent chain first, then PosVis
-- state, then the event latch as a fallback when both native reads are
-- unknown. Returns known, visible, content, state.
--
-- IMPORTANT (live-client lesson, 2026-08-24): a PosVis "hidden" signal must
-- NOT be treated as an authoritative "Craft Book closed" by itself. On this
-- client the craft station does not map to UIC_CRAFT_BOOK at all (F2
-- diagnostic shows all three UIC candidates hidden), so a hidden PosVis just
-- means "that UIC is not open", not "the station closed". Treating it as
-- known=true made the watcher clear the event latch before the event-only
-- compatibility path could run -- the popup never fired. A hidden PosVis is
-- authoritative ONLY when the content chain is known (the UIC really exists).
function C:ReadCraftBookVisibility()
    local content = self:GetCraftBookContent()
    local contentKnown, contentVisible = ReadContentChainVisible(content)
    if contentVisible == true then
        local _, state = self:ReadCraftBookState()
        return true, true, content, state
    end
    local stateKnown, state = self:ReadCraftBookState()
    if stateKnown then
        if type(state) == "table" and state.visible == true then return true, true, content, state end
        -- hidden PosVis: authoritative close only when the content chain is
        -- known too; otherwise this UIC is not the station and the event
        -- latch must decide.
        if contentKnown then return true, false, content, state end
    end
    if self.craftSignalOpen == true then return false, true, content, state end
    if contentKnown then return true, false, content, state end
    return false, false, content, state
end

-- Settings accessors. Shape: S.State.settings.craftAssist = { enabled=bool,
-- autoShow=bool } (rs_config Defaults + rs_state normalization).
local function CraftSettings()
    local settings = S.State and S.State.settings or {}
    local craft = type(settings.craftAssist) == "table" and settings.craftAssist or {}
    return craft
end

function C:IsEnabled()
    return CraftSettings().enabled == true
end

function C:IsAutoShow()
    local auto = CraftSettings().autoShow
    return auto ~= false
end

local function ExtractStableItemType(itemInfo)
    if type(itemInfo) ~= "table" then return nil end
    local value = tonumber(itemInfo.itemType or itemInfo.itemTypeId or itemInfo.item_type or itemInfo.typeId)
    if value == nil and type(itemInfo.itemInfo) == "table" then
        local nested = itemInfo.itemInfo
        value = tonumber(nested.itemType or nested.itemTypeId or nested.item_type or nested.typeId)
    end
    if value == nil or value <= 0 then return nil end
    return math.floor(value)
end

-- Parse a SPECIALTY_RATIO_BETWEEN_INFO payload into pack rows, mirroring the
-- trade service's OnRatio extraction. Pure: payload -> rows.
local function ParseRatioRows(info)
    local rows = {}
    if type(info) == "table" then
        for _, value in pairs(info) do
            if type(value) == "table" and type(value.itemInfo) == "table" then
                local name = tostring(value.itemInfo.name or "未知特产")
                local itemType = ExtractStableItemType(value.itemInfo) or ExtractStableItemType(value)
                rows[#rows + 1] = { name = name, itemType = itemType }
            end
        end
    end
    return rows
end

-- Pure assembly: pick the pack row matching packName and build material rows
-- from the material service, annotating each with the player's bag count.
-- packs: zone pack rows ({name=, itemType=}). bagCountByType: { [itemType]=n }.
-- Returns { packName=, zoneGroup=, materials={ {name,displayName,itemType,count,includeInCost,bagCount} } }.
function C:AssembleRows(packs, packName, bagCountByType, zoneGroup)
    local chosen
    local wanted = tostring(packName or "")
    for _, pack in ipairs(type(packs) == "table" and packs or {}) do
        if tostring(pack.name or "") == wanted then chosen = pack; break end
    end
    if chosen == nil then
        return { packName = wanted, zoneGroup = zoneGroup, materials = {} }
    end

    local materialService = S.Services and S.Services.TradeMaterials
    local rows = {}
    if materialService ~= nil and type(materialService.GetMaterialsForPack) == "function" then
        local materials, resolved, recipeSource = materialService:GetMaterialsForPack(wanted, zoneGroup, chosen.itemType)
        for _, mat in ipairs(type(materials) == "table" and materials or {}) do
            local itemType = tonumber(mat.itemType)
            rows[#rows + 1] = {
                name = tostring(mat.name or ""),
                displayName = tostring(mat.displayName or mat.name or ""),
                itemType = itemType,
                count = tonumber(mat.count) or 0,
                includeInCost = mat.includeInCost ~= false,
                bagCount = (type(bagCountByType) == "table" and itemType ~= nil and tonumber(bagCountByType[itemType])) or 0,
            }
        end
    end
    return { packName = wanted, zoneGroup = zoneGroup, materials = rows, recipeSource = recipeSource }
end

-- Bug 3: build a flat, all-packs list for the window. Each pack contributes a
-- "pack header" entry followed by its material entries, so the user sees every
-- craftable pack at once instead of cycling < >. Pure, unit-testable.
-- Returns { {type="pack", name=}, {type="material", ...}, ... }.
function C:BuildAllRows(packs, bagCountByType, zoneGroup)
    local result = {}
    for _, pack in ipairs(type(packs) == "table" and packs or {}) do
        if pack ~= nil and tostring(pack.name or "") ~= "" then
            result[#result + 1] = { type = "pack", name = tostring(pack.name) }
            local assembled = self:AssembleRows(packs, pack.name, bagCountByType, zoneGroup)
            for _, mat in ipairs(type(assembled) == "table" and assembled.materials or {}) do
                mat.type = "material"
                result[#result + 1] = mat
            end
        end
    end
    return result
end

-- One-shot bag count aggregation by itemType. Reuses BagOrganizer:ScanBag()
-- (which reads X2Bag through the capability boundary). Returns { [itemType]=n }.
-- 2026-08-24: sums the per-slot STACK quantity (ScanBag entries now carry
-- .stack), so 300 of a material in one slot counts as 300, not 1.
function C:CountBagByType()
    self.stats.bagScans = (self.stats.bagScans or 0) + 1
    local result = {}
    local organizer = S.Services and S.Services.BagOrganizer
    if organizer == nil or type(organizer.ScanBag) ~= "function" then return result end
    local ok, bag = xpcall(function() return organizer:ScanBag() end, S.SafeTraceback)
    if not ok or type(bag) ~= "table" then return result end
    for _, entry in ipairs(bag.items or {}) do
        local itemType = tonumber(entry.itemType)
        if itemType ~= nil then
            result[itemType] = (result[itemType] or 0) + math.max(1, math.floor(tonumber(entry.stack) or 1))
        end
    end
    return result
end

-- Fire one zone-pack query while the Trade service is idle. Sets self.ratioQuery
-- so the event handler can tell the response belongs to us. Returns true when a
-- query was actually started, false when skipped (Trade busy / capability off).
--
-- Performance (2026-08-24 hotfix #3): every failure path used to leave BOTH
-- packs and ratioQuery nil, so the watcher's "packs == nil and ratioQuery ==
-- nil" gate re-fired GetSellableZoneGroups/GetSpecialtyRatioBetween on every
-- tick -- a query storm that froze the client while the craft station was open
-- (compounded by high-frequency craft events calling WatchCraftGuide). Failures
-- now record lastZoneRequestAt and are throttled by QUERY_COOLDOWN_MS.
local QUERY_COOLDOWN_MS = 3000
function C:RequestZonePacks(zoneGroup)
    self.stats.zoneRequests = (self.stats.zoneRequests or 0) + 1
    local zoneId = tonumber(zoneGroup)
    if zoneId == nil then
        self.lastError = "无法确定当前产区"
        return false
    end
    if self.ratioQuery ~= nil then return true end -- already in flight
    local nowMs = S.NowMs and S.NowMs() or 0
    -- Throttle only after a REAL previous attempt: nil means first call, and a
    -- fresh mock clock (or a client whose NowMs is small) must not be mistaken
    -- for "recently failed".
    if self.lastZoneRequestAt ~= nil
        and nowMs - (tonumber(self.lastZoneRequestAt) or 0) < QUERY_COOLDOWN_MS then
        self.stats.zoneRequestsThrottled = (self.stats.zoneRequestsThrottled or 0) + 1
        return false -- throttled after a recent failure
    end
    self.lastZoneRequestAt = nowMs

    local trade = S.Services and S.Services.Trade
    if trade ~= nil and (trade.inFlight ~= nil or trade.pending == true) then
        self.lastError = "跑商货率查询进行中，请稍后重试"
        return false
    end
    if S.Api == nil or S.Api:IsCapabilityAllowed("X2Store:GetSpecialtyRatioBetween") ~= true
        or S.Api:IsCapabilityAllowed("X2Store:GetSellableZoneGroups") ~= true then
        self.lastError = "货率查询 API 不可用"
        return false
    end

    local okZones, zones = S.Api:CallCapability("X2Store:GetSellableZoneGroups", X2Store, "GetSellableZoneGroups", zoneId)
    local dest = nil
    if okZones and type(zones) == "table" then
        for _, zone in ipairs(zones) do
            if type(zone) == "table" and tonumber(zone.id) ~= nil then dest = tonumber(zone.id); break end
        end
    end
    if dest == nil then
        self.lastError = "当前产区无可交货目的地"
        return false
    end

    local ok, err = S.Api:ActionCapability("X2Store:GetSpecialtyRatioBetween", X2Store, "GetSpecialtyRatioBetween", zoneId, dest)
    if ok ~= true then
        self.lastError = "货率查询未接受：" .. tostring(err or "unknown")
        return false
    end
    self.ratioQuery = { from = zoneId, to = dest, at = S.NowMs() }
    self.lastZoneRequestAt = nil -- success resets the throttle window
    self.lastError = nil
    return true
end

-- Event entry: SPECIALTY_RATIO_BETWEEN_INFO. Consume only when we started the
-- query (ratioQuery set) and the Trade service is idle, mirroring trade's own
-- request guarding. Stale queries are dropped after QUERY_TIMEOUT_MS.
function C:OnRatio(info)
    if type(self.ratioQuery) ~= "table" then return end
    local trade = S.Services and S.Services.Trade
    if trade ~= nil and (trade.inFlight ~= nil or trade.pending == true) then
        -- Trade started its own query while ours was in flight: drop ours to
        -- avoid consuming an unidentifiable response.
        self.ratioQuery = nil
        return
    end
    if S.NowMs() - (self.ratioQuery.at or 0) > QUERY_TIMEOUT_MS then
        self.ratioQuery = nil
        return
    end
    local queryFrom = self.ratioQuery and self.ratioQuery.from or nil
    self.ratioQuery = nil
    self.packs = ParseRatioRows(info)
    if queryFrom ~= nil then self.lastZoneGroup = queryFrom end
    if #(self.packs or {}) == 0 then
        self.lastError = "当前产区没有识别到可产特产"
    else
        self.lastError = nil
    end
    self.bagCountByType = self:CountBagByType()
    if S.CraftAssistWindow ~= nil and type(S.CraftAssistWindow.OnDataChanged) == "function" then
        S.CraftAssistWindow:OnDataChanged()
    end
    if S.State ~= nil and type(S.State.MarkDirty) == "function" then S.State:MarkDirty("craftAssist") end
end

function C:GetPacks()
    local packs = self.packs or {}
    if #packs > MAX_PACKS then
        local limited = {}
        for i = 1, MAX_PACKS do limited[i] = packs[i] end
        return limited
    end
    return packs
end

-- Manual refresh: re-read visibility (may change zone), re-scan bag counts and
-- re-request zone packs. The guaranteed fallback when detection fails.
function C:ManualRefresh()
    -- Lightweight refresh (2026-08-24 hotfix #4): the "刷新" button used to run
    -- a FULL bag scan (CountBagByType -> X2Bag 150-slot read) on every click,
    -- which stuttered the client each time. Bag counts are already refreshed on
    -- open and when data arrives (OnRatio); a manual refresh only needs to
    -- re-read the station, re-request zone packs (throttled) and repaint the
    -- window.
    local kind = self:CheckOpen()
    if kind ~= nil then self.openKind = kind end
    local zoneOk, zoneId = S.Api:CallCapability("X2Unit:GetCurrentZoneGroup", X2Unit, "GetCurrentZoneGroup")
    local zone = zoneOk and tonumber(zoneId) or nil
    if zone == nil then
        self.lastError = "无法确定当前产区（GetCurrentZoneGroup 不可用）"
    else
        self.lastZoneGroup = zone
        self:RequestZonePacks(zone)
    end
    if S.CraftAssistWindow ~= nil and type(S.CraftAssistWindow.OnDataChanged) == "function" then
        S.CraftAssistWindow:OnDataChanged()
    end
end

-- F2: craft-station detection diagnostic. Click-triggered ONLY (never polled).
-- Enumerates native content visibility two ways:
--   1. pcall-walk _G for "UIC_" globals (when the sandbox permits);
--   2. static fallback table of UIC constants from api_functions.lua.
-- Outputs to chat: "[制作台诊断] 可见内容:UIC_XXX, ..." plus the three
-- craft candidates' states and the manual-open fallback channel status, so the
-- user can report back which UIC the craft station actually maps to.
function C:DiagnoseCraftDetection()
    local function Chat(line) if S.SafeChat ~= nil then S.SafeChat(line) end end
    local visible = {}
    local checked = {}
    local function ReadOne(name)
        local value = rawget(_G, name)
        if value == nil then return end
        checked[tostring(value)] = true
        local ok, state = ReadContentMainScriptPosVis(value)
        if ok == true and type(state) == "table" and state.visible == true then
            visible[#visible + 1] = name
        end
    end

    -- Path 1: pcall-walk _G for UIC_ globals.
    local walked = false
    local okWalk = pcall(function()
        for key, value in pairs(_G) do
            if type(key) == "string" and key:match("^UIC_") and type(value) == "number" then
                checked[tostring(value)] = true
                local ok2, state = ReadContentMainScriptPosVis(value)
                if ok2 == true and type(state) == "table" and state.visible == true then
                    visible[#visible + 1] = key
                end
            end
        end
        walked = true
    end)
    if not okWalk then walked = false end

    -- Path 2: static fallback table (always runs; cheap, bounded).
    for _, name in ipairs(DIAGNOSTIC_UIC_CANDIDATES) do
        ReadOne(name)
    end

    -- Three craft candidates always reported with explicit state.
    local craftStates = {}
    for _, candidate in ipairs(CRAFT_CANDIDATES) do
        local id = ContentId(candidate.key)
        local state = "未定义"
        if id ~= nil then
            local ok2, st = ReadContentMainScriptPosVis(id)
            state = ok2 == true and (st.visible == true and "可见" or "隐藏") or "不可读"
        end
        craftStates[#craftStates + 1] = candidate.label .. "=" .. state
    end

    -- H3: also report the authoritative Craft Book chain read so the user can
    -- confirm the watcher's view without waiting for a transition.
    local chainState = "不可读"
    local known, vis, content, state = self:ReadCraftBookVisibility()
    if vis == true then
        chainState = "可见"
    elseif known == true then
        chainState = "权威关闭"
    else
        chainState = "仅闩锁" .. (self.craftSignalOpen == true and "（事件闩锁开）" or "（闩锁关）")
    end
    local rect = self:ResolveCraftBookRect(content, state)

    -- H3 full-chain diagnostics: watcher judgement, latches, approval gate,
    -- player position vs. workbench table, and the window dismiss state. Lets
    -- the user report which link of the chain fails on the live client.
    local zoneId = self:GetCurrentZoneId()
    local near, nearZone, nearDist = self:GetNearbyTradeCrafter(APPROVAL_RADIUS)
    local zoneCount = 0
    if zoneId ~= nil and S.Data ~= nil and type(S.Data.TradeCrafterLocationsByZone) == "table" then
        local locations = S.Data.TradeCrafterLocationsByZone[zoneId]
        zoneCount = type(locations) == "table" and #locations or 0
    end
    local playerX, playerZ = nil, nil
    if X2Unit ~= nil and S.Api ~= nil and S.Api:IsCapabilityAllowed("X2Unit:GetUnitWorldPositionByTarget") == true then
        local posOk, px, _, pz = S.Api:CallCapability("X2Unit:GetUnitWorldPositionByTarget", X2Unit, "GetUnitWorldPositionByTarget", "player", false)
        if posOk == true then playerX, playerZ = tonumber(px), tonumber(pz) end
    end
    local dismissed = S.CraftAssistWindow ~= nil and S.CraftAssistWindow.sessionDismissed == true
    local craft = (S.State and S.State.settings and S.State.settings.craftAssist) or {}
    local enabledText = tostring(craft.enabled == true)
    local autoText = tostring(craft.autoShow ~= false)

    local visibleText = #visible > 0 and table.concat(visible, ", ") or "（无可见 UIC）"
    Chat("[制作台诊断] 枚举：" .. (walked and "_G 遍历" or "仅静态表") .. " · 可见内容：" .. visibleText)
    Chat("[制作台诊断] 三候选：" .. table.concat(craftStates, " · "))
    Chat("[制作台诊断] 制作手册内容链：" .. chainState .. (type(rect) == "table" and (" · rect=" .. tostring(rect.width) .. "x" .. tostring(rect.height)) or ""))
    Chat("[制作台诊断] H3链路：known=" .. tostring(known) .. " visible=" .. tostring(vis)
        .. " 闩锁=" .. tostring(self.craftSignalOpen) .. " 批准=" .. tostring(self.craftGuideApproved)
        .. " 最近信号=" .. tostring(self.lastCraftSignal or "无") .. " dismissed=" .. tostring(dismissed))
    Chat("[制作台诊断] 批准门：zone=" .. tostring(zoneId) .. " 表内点=" .. tostring(zoneCount)
        .. " 玩家=(" .. tostring(playerX) .. "," .. tostring(playerZ) .. ")"
        .. " 最近工作台距离=" .. (nearDist ~= nil and string.format("%.1f", nearDist) or "无")
        .. " 命中=" .. tostring(near ~= nil))
    Chat("[制作台诊断] 设置：enabled=" .. enabledText .. " autoShow=" .. autoText)
    if craft.enabled ~= true then
        Chat("[制作台诊断] 提示：功能总开关未开启，自动弹窗被禁用——请到生活页跑商卡片点“助手：开”。（注意：能点此诊断按钮不代表总开关已开，面板可手动打开，但自动弹窗由总开关控制。）")
    end
    if dismissed == true then
        Chat("[制作台诊断] 提示：助手窗被手动关闭过（×），本次制作会话不再自动弹；重新打开制作台后恢复。")
    end
    local manualOk = S.CraftAssistWindow ~= nil and type(S.CraftAssistWindow.Show) == "function"
    Chat("[制作台诊断] 手动开窗通道：" .. (manualOk and "可用（助手窗已就绪）" or "不可用（助手窗未加载）"))
    -- Runtime hot-path counters: shows exactly what ran since Start (or last
    -- reset), so a "window visible + lagging" report can be diagnosed without
    -- guessing (2026-08-24).
    local st = self.stats or {}
    local eventParts = {}
    for name, count in pairs(st.events or {}) do
        eventParts[#eventParts + 1] = tostring(name) .. "=" .. tostring(count)
    end
    local eventText = #eventParts > 0 and table.concat(eventParts, " ") or "无"
    Chat("[制作台诊断] 计数：watch=" .. tostring(st.watchTicks or 0)
        .. " 稳定采样=" .. tostring(st.stableSamples or 0)
        .. " 全量读=" .. tostring(st.fullReads or 0)
        .. " 打开转换=" .. tostring(st.openTransitions or 0))
    Chat("[制作台诊断] 计数：Show调用=" .. tostring(st.showCalls or 0)
        .. " 实际Show=" .. tostring(st.showActual or 0)
        .. " 窗口刷新=" .. tostring(st.windowRefresh or 0)
        .. " 名字扫描=" .. tostring(st.officialNameScans or 0))
    Chat("[制作台诊断] 计数：货率请求=" .. tostring(st.zoneRequests or 0)
        .. " 节流=" .. tostring(st.zoneRequestsThrottled or 0)
        .. " 背包扫描=" .. tostring(st.bagScans or 0)
        .. " 事件：" .. eventText)
    -- Bag-count diagnostics (2026-08-24): "物品在背包但显示 0" — dump how many
    -- itemTypes were aggregated vs how many material rows reference, so the
    -- mismatch (variant itemType / empty scan) is visible. Also list the
    -- LARGEST stacks (>=50) so a high-quantity item like Gilda Stars (513) can
    -- be matched against the material rows even when it is not in the first 8.
    local bagCount = self.bagCountByType or {}
    local bagKeys = 0
    local bagSample = {}
    local bigStacks = {}
    for k, v in pairs(bagCount) do
        bagKeys = bagKeys + 1
        if #bagSample < 8 then bagSample[#bagSample + 1] = tostring(k) .. ":" .. tostring(v) end
        if tonumber(v) >= 50 then bigStacks[#bigStacks + 1] = tostring(k) .. ":" .. tostring(v) end
    end
    local materialKeys = {}
    local packs = self.packs or {}
    for _, pack in ipairs(packs) do
        local assembled = self:AssembleRows(packs, tostring(pack.name or ""), bagCount, self.lastZoneGroup)
        for _, mat in ipairs(type(assembled) == "table" and assembled.materials or {}) do
            if mat.itemType ~= nil and materialKeys[tostring(mat.itemType)] == nil then
                materialKeys[tostring(mat.itemType)] = true
            end
        end
    end
    local matCount = 0
    for _ in pairs(materialKeys) do matCount = matCount + 1 end
    Chat("[制作台诊断] 背包计数：聚合 " .. tostring(bagKeys) .. " 个itemType（样本 " .. table.concat(bagSample, " ") .. "）"
        .. "；材料行引用 " .. tostring(matCount) .. " 个itemType")
    if #bigStacks > 0 then
        Chat("[制作台诊断] 大堆叠：" .. table.concat(bigStacks, " "))
    end
    -- Event ring log: did the latch signal actually arrive / get accepted?
    local el = self.eventLog
    if type(el) == "table" and #el > 0 then
        local parts = {}
        for _, e in ipairs(el) do
            parts[#parts + 1] = tostring(e.name) .. (e.accepted and "" or "[节流]") .. "(" .. tostring(e.latchBefore) .. "→" .. tostring(self.craftSignalOpen) .. ")"
        end
        Chat("[制作台诊断] 事件日志：" .. table.concat(parts, " | "))
    end
    -- Watcher decision log: which branch ran (visible/latch/approved).
    local wl = self.watchLog
    if type(wl) == "table" and #wl > 0 then
        local parts = {}
        for _, w in ipairs(wl) do
            parts[#parts + 1] = "v=" .. tostring(w.visible) .. " k=" .. tostring(w.known) .. " 闩=" .. tostring(w.latch) .. " 批=" .. tostring(w.approved)
        end
        Chat("[制作台诊断] watcher日志：" .. table.concat(parts, " | "))
    end
    return visible
end

-----------------------------------------------------------------------
-- H3 signal layer: events set latches and run the watcher immediately.
-----------------------------------------------------------------------

-- TOGGLE_CRAFT / CRAFT_DOODAD_INFO. Numeric payloads are ambiguous across
-- client generations (0 may be a doodad/context id), so only explicit
-- boolean/text close signals terminate the session latch.
local function IsCraftCloseSignal(value)
    if value == false then return true end
    if type(value) == "string" then
        local text = string.lower(Trim(value))
        return text == "false" or text == "close" or text == "closed"
            or text == "hide" or text == "hidden" or text == "off"
    end
    return false
end

-- Append one latch-signal arrival to the ring log (max 12). Records the event
-- name, whether the 1s debounce accepted it, and the latch before/after.
local function LogCraftEvent(self, eventName, accepted, latchBefore)
    local log = self.eventLog
    if type(log) ~= "table" then log = {}; self.eventLog = log end
    log[#log + 1] = {
        t = S.NowMs and S.NowMs() or 0,
        name = tostring(eventName or "?"),
        accepted = accepted == true,
        latchBefore = latchBefore == true,
    }
    if #log > 12 then
        local kept = {}
        for i = #log - 11, #log do kept[#kept + 1] = log[i] end
        self.eventLog = kept
    end
end

function C:OnCraftUiSignal(eventName, ...)
    local key = tostring(eventName or "?")
    self.stats.events[key] = (self.stats.events[key] or 0) + 1
    -- Minimal latch handler (refactor 2026-08-24): set/clear the open latch and
    -- close flags only. No WatchCraftGuide() call here -- the 400ms watcher
    -- consumes the latch, so a signal burst cannot trigger per-event work.
    local nowMs = S.NowMs and S.NowMs() or 0
    -- Debounce only after a REAL previous signal; nil means first call (fresh
    -- clock / mock must not be mistaken for a recent burst).
    if self.lastUiSignalAt ~= nil
        and nowMs - (tonumber(self.lastUiSignalAt) or 0) < 1000 then
        LogCraftEvent(self, key, false, self.craftSignalOpen)
        return
    end
    self.lastUiSignalAt = nowMs
    local argCount = select("#", ...)
    local args = { ... }
    if tostring(eventName or "") == "TOGGLE_CRAFT" and argCount > 0 and IsCraftCloseSignal(args[1]) then
        LogCraftEvent(self, key .. " close", true, self.craftSignalOpen)
        self.craftSignalOpen = false
        self.craftGuideApproved = false
        self.lastCraftVisible = false
        -- Deliberately keep the already-built sidecar alive: it is a carried
        -- material work order until the player closes it or enters another world.
        return
    end
    LogCraftEvent(self, key, true, self.craftSignalOpen)
    self.craftSignalOpen = true
    self.lastCraftSignal = tostring(eventName or "CRAFT")
end

function C:OnSupplementalCraftSignal(eventName, ...)
    local key = tostring(eventName or "?")
    self.stats.events[key] = (self.stats.events[key] or 0) + 1
    -- Minimal latch handler (refactor v2): same 1s debounce + latch set as the
    -- UI signal; NEVER call WatchCraftGuide() here (the 400ms watcher consumes
    -- the latch). CRAFTING_START etc. can burst while the station is open.
    local nowMs = S.NowMs and S.NowMs() or 0
    if self.lastUiSignalAt ~= nil
        and nowMs - (tonumber(self.lastUiSignalAt) or 0) < 1000 then
        LogCraftEvent(self, key, false, self.craftSignalOpen)
        return
    end
    self.lastUiSignalAt = nowMs
    LogCraftEvent(self, key, true, self.craftSignalOpen)
    self.craftSignalOpen = true
    self.lastCraftSignal = tostring(eventName or "CRAFT")
end

-- INTERACTION_START* fallback: short-lived Probe that consults the workbench
-- coordinates. 80ms first, retried 150ms, at most PROBE_MAX_ATTEMPTS times.
-- Coordinates are read ONLY here (after an interaction event) and in the
-- watcher's open transition -- never on a permanent loop.
--
-- Hotfix #5: INTERACTION_START can fire repeatedly while standing beside the
-- station. Each event used to restart a Probe chain -> an X2Unit position read
-- every 80ms -> the client froze. Once the sidecar is approved+visible, all
-- interaction events short-circuit: the 400ms watcher owns the follow.
function C:OnInteractionCraftFallback(eventName)
    if self.craftGuideApproved == true and self.lastCraftVisible == true then
        self.craftSignalOpen = true
        return
    end
    local attempts = 0
    local function Probe()
        S.Scheduler:RemoveTask(TASK_PROBE)
        attempts = attempts + 1
        local location, zoneId = self:GetNearbyTradeCrafter(APPROVAL_RADIUS)
        if location ~= nil then
            self.craftSignalOpen = true
            self.craftGuideApproved = true
            self.craftGuideZone = zoneId
            self.lastCraftSignal = tostring(eventName or "INTERACTION_START")
            self:WatchCraftGuide()
            return
        end
        if attempts < PROBE_MAX_ATTEMPTS then
            S.Scheduler:AddTask(TASK_PROBE, PROBE_RETRY_MS, Probe, false, self, "P1")
        end
    end
    S.Scheduler:RemoveTask(TASK_PROBE)
    S.Scheduler:AddTask(TASK_PROBE, PROBE_FIRST_MS, Probe, false, self, "P1")
end

-- INTERACTION_END*: clear the session latches, but only when the Craft Book is
-- not authoritatively visible. The sidecar is never hidden here -- the player
-- may be walking to a bank/coffer with the carried work order.
-- Hotfix #5: when the sidecar is already approved+visible the full visibility
-- re-read per INTERACTION_END event was a per-event native read during a
-- possibly high-frequency event stream; skip it (the watcher backstop + the
-- TOGGLE_CRAFT close signal handle closure).
function C:OnCraftInteractionEnd()
    if self.craftGuideApproved == true and self.lastCraftVisible == true then
        return
    end
    local known, visible = self:ReadCraftBookVisibility()
    if known == true and visible == true then return end
    self.craftSignalOpen = false
    self.craftGuideApproved = false
    self.lastCraftVisible = false
end

-----------------------------------------------------------------------
-- H3 watcher + show chain (the authoritative path)
-----------------------------------------------------------------------

-- Show the sidecar. opening=true starts a new session (resets the player's
-- dismiss); a dismissed session is never auto-shown again until the next
-- opening. The production zone is fixed to the zone that opened the sidecar.
--
-- Performance (2026-08-24 hotfix): the 400ms watcher calls this on every tick
-- while the Craft Book stays visible. Two heavy operations were running every
-- tick: the window Show() did a full ApplyLayout+ApplyAnchor+Refresh, and
-- CountBagByType() rescanned the whole bag. Both are now short-circuited when
-- the window is already visible and the anchor rect is unchanged -- the watcher
-- tick then costs only the visibility read + a rect comparison. Bag counts are
-- refreshed on open, on data arrival (OnRatio) and on manual refresh.
function C:ShowCraftGuide(zoneId, rect, opening)
    self.stats.showCalls = (self.stats.showCalls or 0) + 1
    local ui = S.CraftAssistWindow
    if ui == nil or type(ui.Show) ~= "function" then return false end
    if opening == true and type(ui.BeginSession) == "function" then ui:BeginSession() end
    if ui.sessionDismissed == true then return false end
    local zone = tonumber(zoneId) or self:GetCurrentZoneId()
    if zone == nil then return false end
    if tonumber(self.craftGuideZone) ~= zone then self.craftGuideZone = zone end

    -- Already visible + same anchor: nothing to re-layout, nothing to rescan.
    local alreadyVisible = false
    if ui.window ~= nil and type(ui.window.IsVisible) == "function" then
        local visOk, vis = pcall(function() return ui.window:IsVisible() end)
        alreadyVisible = visOk == true and vis == true
    end
    local rectSame = type(rect) == "table" and type(self.lastShownRect) == "table"
        and tonumber(rect.x) == tonumber(self.lastShownRect.x)
        and tonumber(rect.y) == tonumber(self.lastShownRect.y)
    if alreadyVisible and rectSame then return true end
    self.lastShownRect = rect

    -- Data chain: request the zone packs once per session. Bag counts are
    -- scanned on open transitions and when data arrives (OnRatio), never on
    -- every 400ms watcher tick.
    -- Order (2026-08-24): show the window FIRST (empty shell), then do the
    -- heavy work (zone query + bag scan) -- the popup feels instant, data fills
    -- in when OnRatio arrives. Previously the scan+query ran before Show, which
    -- made the FIRST popup stutter.
    self.stats.showActual = (self.stats.showActual or 0) + 1
    if type(ui.Show) == "function" then ui:Show(true, rect) end
    if self.packs == nil and self.ratioQuery == nil then
        self.lastZoneGroup = zone
        self:RequestZonePacks(zone)
    end
    -- Refresh bag counts on EVERY open transition (opening=true), so items
    -- acquired since the last session show up (2026-08-24 fix for "背包有物品
    -- 显示 0"). Stable re-shows (opening=false) skip the scan.
    if opening == true or self.bagCountByType == nil then
        self.bagCountByType = self:CountBagByType()
    end
    if type(ui.OnDataChanged) == "function" then ui:OnDataChanged() end
    return true
end

function C:HideCraftGuide(resetSession)
    local ui = S.CraftAssistWindow
    if ui ~= nil and type(ui.Show) == "function" then ui:Show(false) end
    if resetSession == true then
        self.craftGuideApproved = false
        self.craftGuideZone = nil
        self.lastCraftVisible = false
    end
end

-- The player explicitly closed the sidecar (× / Esc). Reset the service-side
-- session so the NEXT craft-station open re-runs the full approval path and
-- the panel reappears. The window itself is already hidden by the caller.
-- Bug1 (2026-08-24): also clear the open latch -- otherwise the watcher's next
-- full read sees visible=true via the latch fallback (this client reports
-- known=false) and re-approves + re-shows the panel while the player is still
-- beside the station, even though they explicitly dismissed it.
function C:OnSidecarDismissed()
    self.craftSignalOpen = false
    self.craftGuideApproved = false
    self.craftGuideZone = nil
    self.lastCraftVisible = false
    self.lastCraftRect = nil
    self.stableTick = 0
end

-- 400ms authoritative watcher. Reads the Craft Book visibility three ways and
-- drives the approval gate + sidecar show. Zero API calls while disabled.
--
-- Performance (2026-08-24 hotfix #2): while the Craft Book stays open and the
-- sidecar is already approved+visible, the per-tick full read (GetContent +
-- GetContentMainScriptPosVis + parent-chain GetLogicalRect walk) was still
-- running every 400ms -- several native calls per tick during the whole craft
-- session. The craft station rect does not move while open, so once approved
-- we cache the rect and the watcher only does ONE cheap PosVis read per tick
-- (is the station still open?). Full re-read happens on the open transition,
-- on events, and when the PosVis read reports closed.
function C:WatchCraftGuide()
    self.stats.watchTicks = (self.stats.watchTicks or 0) + 1
    if self.started ~= true then return end
    if self:IsEnabled() ~= true then
        if self.craftSignalOpen == true or self.craftGuideApproved == true or self.lastCraftVisible == true then
            self.craftSignalOpen = false
            self.craftGuideApproved = false
            self.lastCraftVisible = false
            self.lastCraftRect = nil
            if S.CraftAssistWindow ~= nil and type(S.CraftAssistWindow.Close) == "function" then S.CraftAssistWindow:Close() end
        end
        return
    end

    -- Stable-follow (FINAL, 2026-08-24): once approved+visible, the watcher
    -- does ABSOLUTELY NOTHING -- zero native reads, zero window calls. Live
    -- diagnostics proved this client reports known=false (PosVis/content chain
    -- unreadable), so every sampled PosVis read failed and fell through to a
    -- full read which (via the latch) said visible=true -> the approved branch
    -- re-showed the window every tick -> full ApplyLayout + per-row storage
    -- scans (128 in one session) -> the freeze. The station data is fixed
    -- (craft amounts don't change), so nothing needs re-reading while open.
    -- Closure is handled by the TOGGLE_CRAFT close signal (subscribed) and
    -- ENTERED_WORLD.
    if self.craftGuideApproved == true and self.lastCraftVisible == true then
        self.stats.stableSamples = (self.stats.stableSamples or 0) + 1
        return
    end

    self.stats.fullReads = (self.stats.fullReads or 0) + 1
    local known, visible, content, state = self:ReadCraftBookVisibility()
    -- Watcher decision log (2026-08-24): record non-stable decisions so the
    -- "second open does not pop" case shows exactly which branch ran.
    local watchLog = self.watchLog
    if type(watchLog) ~= "table" then watchLog = {}; self.watchLog = watchLog end
    watchLog[#watchLog + 1] = {
        t = S.NowMs and S.NowMs() or 0,
        known = known == true, visible = visible == true,
        latch = self.craftSignalOpen == true, approved = self.craftGuideApproved == true,
    }
    if #watchLog > 12 then
        local kept = {}
        for i = #watchLog - 11, #watchLog do kept[#kept + 1] = watchLog[i] end
        self.watchLog = kept
    end
    if visible == true then
        local opening = self.lastCraftVisible ~= true
        self.lastCraftVisible = true
        self.craftSignalOpen = true
        if opening then self.stats.openTransitions = (self.stats.openTransitions or 0) + 1 end
        -- Resolve the rect only on the open transition; afterwards the cached
        -- rect is reused by the stable-follow path above.
        local rect = self.lastCraftRect
        if rect == nil then
            rect = self:ResolveCraftBookRect(content, state)
            self.lastCraftRect = rect
        end
        if opening then
            -- A newly opened native Craft Book is approved only when the player
            -- is beside a recognized specialty workbench. Once approved, the
            -- production zone stays fixed to that workbench.
            local location, zoneId = self:GetNearbyTradeCrafter(APPROVAL_RADIUS)
            if location ~= nil then
                self.craftGuideApproved = true
                self.craftGuideZone = zoneId
                if self:IsAutoShow() then self:ShowCraftGuide(zoneId, rect, true) end
            else
                self.craftGuideApproved = false
            end
        elseif self.craftGuideApproved == true then
            local zoneId = tonumber(self.craftGuideZone) or self:GetCurrentZoneId()
            if zoneId ~= nil and self:IsAutoShow() then self:ShowCraftGuide(zoneId, rect, false) end
        end
        return
    end
    if known == true then
        -- Native Craft Book is authoritatively closed. Keep the sidecar visible
        -- as a carried work order; only stop following/anchoring the Craft Book.
        self.craftSignalOpen = false
        self.lastCraftVisible = false
        self.craftGuideApproved = false
        self.lastCraftRect = nil
        return
    end
    -- Event-only compatibility path. Approval still requires proximity to a
    -- known specialty workbench, so ordinary Craft Book use cannot surface it.
    if self.craftSignalOpen == true then
        if self.craftGuideApproved ~= true then
            local location, zoneId = self:GetNearbyTradeCrafter(APPROVAL_RADIUS)
            if location ~= nil then self.craftGuideApproved = true; self.craftGuideZone = zoneId end
        end
        if self.craftGuideApproved == true then
            local zoneId = tonumber(self.craftGuideZone) or self:GetCurrentZoneId()
            if zoneId ~= nil then
                self:ShowCraftGuide(zoneId, nil, self.lastCraftVisible ~= true)
                self.lastCraftVisible = true
            end
        end
    end
end

function C:Start()
    if self.started == true then return true end
    self.started = true
    self.openKind = nil
    self.craftSignalOpen = false
    self.craftGuideApproved = false
    self.craftGuideZone = nil
    self.lastCraftVisible = false
    self.lastCraftSignal = nil
    self.lastCraftRect = nil
    self.lastZoneRequestAt = nil
    self.stableTick = 0
    self.stats = {
        watchTicks = 0, stableSamples = 0, fullReads = 0, showCalls = 0, showActual = 0,
        zoneRequests = 0, zoneRequestsThrottled = 0, bagScans = 0, openTransitions = 0,
        windowRefresh = 0, officialNameScans = 0, events = {},
    }
    self.eventLog = {}
    self.watchLog = {}
    self.lastUiSignalAt = nil
    self.ratioQuery = nil
    self.packs = nil
    self.bagCountByType = nil
    self.lastError = nil
    self.lastMessage = "等待制作台"
    S.Events:Subscribe("SPECIALTY_RATIO_BETWEEN_INFO", self, function(_, info) C:OnRatio(info) end)

    -- REFACTOR (2026-08-24, user-reported "打开制作台就疯狂卡顿,关掉才好"):
    -- ALL craft/interaction event subscriptions are REMOVED. While the native
    -- craft station UI is open the client pushes TOGGLE_CRAFT / NPC_CRAFT_UPDATE
    -- / INTERACTION_START* / INTERACTION_END* at high frequency; even O(1)
    -- short-circuited callbacks still paid per-event dispatch + callback cost,
    -- which stacked with other modules and froze the client. Detection is now
    -- PURELY the 400ms watcher: it polls visibility and approves/shows the
    -- sidecar, and clears latches on authoritative close (sidecar kept as a
    -- carried work order). Zero event subscriptions means zero per-event cost
    -- while the station is open.
    -- Detection signals (2026-08-24 refactor, final v2): live diagnostics show
    -- the real open trigger is CRAFTING_START (最近信号=CRAFTING_START in the
    -- user's logs), NOT TOGGLE_CRAFT. So the craft-progress events are
    -- subscribed too -- ALL latch sources go through the same 1s-debounced
    -- minimal handler, so even a storm costs ~nothing. INTERACTION_START*/END*
    -- remain unsubscribed (they were the freeze storms / coordinate probes).
    S.Events:Subscribe("TOGGLE_CRAFT", self, function(_, ...) C:OnCraftUiSignal("TOGGLE_CRAFT", ...) end)
    S.Events:Subscribe("CRAFT_DOODAD_INFO", self, function(_, ...) C:OnCraftUiSignal("CRAFT_DOODAD_INFO", ...) end)
    for _, eventName in ipairs({ "NPC_CRAFT_UPDATE", "CRAFTING_START", "CRAFT_STARTED" }) do
        local subscribedEvent = eventName
        S.Events:Subscribe(subscribedEvent, self, function(_, ...) C:OnSupplementalCraftSignal(subscribedEvent, ...) end)
    end
    -- World change resets the whole session (sidecar hidden, zone packs stale).
    S.Events:Subscribe("ENTERED_WORLD", self, function()
        C.craftSignalOpen = false
        C.craftGuideApproved = false
        C.craftGuideZone = nil
        C.lastCraftVisible = false
        C.lastCraftRect = nil
        C:HideCraftGuide(true)
    end)

    -- Create the sidecar once; it stays hidden until the watcher approves.
    if S.CraftAssistWindow ~= nil and type(S.CraftAssistWindow.Create) == "function" then
        S.CraftAssistWindow:Create()
        S.CraftAssistWindow:Show(false)
    end

    S.Scheduler:RemoveTask(TASK_VISIBILITY)
    S.Scheduler:AddTask(TASK_VISIBILITY, CRAFT_WATCH_MS, function() C:WatchCraftGuide() end, false, self, "P2")
    self:WatchCraftGuide()
    return true
end

function C:Stop()
    if self.started ~= true then return true end
    self.started = false
    self.openKind = nil
    self.craftSignalOpen = false
    self.craftGuideApproved = false
    self.craftGuideZone = nil
    self.lastCraftVisible = false
    self.lastCraftRect = nil
    self.ratioQuery = nil
    if S.Events ~= nil and type(S.Events.UnsubscribeOwner) == "function" then S.Events:UnsubscribeOwner(self) end
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveOwner) == "function" then S.Scheduler:RemoveOwner(self) end
    if S.CraftAssistWindow ~= nil and type(S.CraftAssistWindow.Close) == "function" then S.CraftAssistWindow:Close() end
    return true
end
