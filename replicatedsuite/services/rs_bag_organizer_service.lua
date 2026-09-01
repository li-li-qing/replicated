------------------------------------------------------------------------
-- Replicated Suite - Bag Organizer Service
-- Author: Replicated
--
-- Purpose:
--   * "取": withdraw every stack from the currently open bank/coffer whose
--     item identity already exists in the player's bag.
--   * "放": deposit every matching bag stack into the currently open
--     bank/coffer.
--
-- Performance / safety:
--   * Inventory scans are performed only for explicit user actions/diagnostics.
--   * No StaticLoad/object lookup, item scan, or expensive matching runs on Tick.
--   * Moves are serialized through the shared Suite Scheduler. The default
--     interval is 250 ms, intentionally above the RU 200 ms API cooldown.
--   * A plan captures physical source slots before execution. Only one plan may
--     run at a time, preventing two button presses from racing the same slots.
--   * Blacklist filtering (O:IsBlocked) is a pure plan-time judgment against
--     S.State.settings.bagOrganizerBlacklist; it adds zero API calls and never
--     changes the identity-set matching above it.
--   * Runtime snapshots contain primitives only; native API tables are never
--     retained after planning.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}
S.Services.BagOrganizer = {
    started = false,
    busy = false,
    queue = nil,
    queueIndex = 0,
    direction = nil,
    completed = 0,
    failed = 0,
    skipped = 0,
    blacklistSkipped = 0,
    pendingVerify = nil,
    lastMessage = "等待操作",
    lastPlanCount = 0,
    lastBagCount = 0,
    lastBankCount = 0,
    lastTypedCount = 0,
    lastFallbackCount = 0,
    lastUnknownCount = 0,
    presenter = nil,
    bagContent = nil,
    bankContent = nil,
    cofferContent = nil,
    lastBagVisible = false,
    lastBankVisible = false,
    lastCofferVisible = false,
    bankSessionOpen = false,
    bankOpenSource = "none",
    cofferSessionOpen = false,
    cofferOpenSource = "none",
    -- G4: once any native content-visibility read succeeds this session (the
    -- client exposes a working UIC_* proxy), event latches become redundant
    -- and are skipped by GetOpenStorageKind. Session-local, never persisted.
    nativeDetectionReliable = false,
    activeStorageKind = nil,
    activeStorageSource = "none",
    lastStorageKind = "bank",
    lastBagAnchorSource = "none",
    lastBagAnchorRect = nil,
    floatingPlacement = "hidden",
    floatingVisible = false,
}
local O = S.Services.BagOrganizer
O.presentationBoundary = "service_only"
O.presentationDebt = nil

local TASK_MOVE = "bag_organizer_move_queue"
local TASK_VISIBILITY = "bag_organizer_bank_visibility"
local DEFAULT_SCAN_SLOTS = 150
local MAX_SCAN_SLOTS = 500
local MAX_MOVE_RETRIES = 2

local Trim = S.Reuse.Text.Trim

-- Presentation sink: Legacy/V3 presenters register themselves here.  The
-- service owns storage detection and move state only; it never creates or
-- mutates Native widgets.
function O:SetPresenter(presenter)
    if presenter ~= nil and type(presenter) ~= "table" then return false end
    if self.presenter ~= nil and self.presenter ~= presenter and type(self.presenter.HideFloating) == "function" then
        pcall(self.presenter.HideFloating, self.presenter)
    end
    self.presenter = presenter
    return true
end

function O:_Present(method, ...)
    local presenter = self.presenter
    local fn = presenter ~= nil and presenter[method] or nil
    if type(fn) ~= "function" then return false end
    local ok, value = pcall(fn, presenter, ...)
    if not ok then
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.ErrorRateLimited) == "function" then
            S.DiagnosticsManager:ErrorRateLimited("bag_organizer", "PRESENTER_CALL_FAILED", 3000,
                "Presenter 调用失败：" .. tostring(method), { error = tostring(value), method = tostring(method) })
        end
        return false
    end
    return value ~= false
end

local function Primitive(value)
    local t = type(value)
    if t == "number" or t == "string" or t == "boolean" then return value end
    if t ~= "table" then return nil end
    for _, key in ipairs({ "value", "id", "type", "amount", "count", "number" }) do
        local child = value[key]
        local ct = type(child)
        if ct == "number" or ct == "string" or ct == "boolean" then return child end
    end
    return nil
end

local function MeaningfulNumber(value)
    local n = tonumber(Primitive(value))
    if n == nil or n ~= n or n <= 0 then return nil end
    return math.floor(n)
end

local function ExtractItemType(info)
    if type(info) ~= "table" then return nil end
    for _, key in ipairs({ "itemType", "itemTypeId", "typeId", "item_type" }) do
        local value = MeaningfulNumber(info[key])
        if value ~= nil then return value end
    end
    return nil
end

-- Stack quantity of a bag/bank/coffer slot info (2026-08-24). A slot can hold
-- many of a stackable material; count aggregation must sum stacks, not slots.
-- Same key set omnicraft's ReadStack uses (verified on the live client).
local function ReadStack(info)
    if type(info) ~= "table" then return 1 end
    for _, key in ipairs({ "stackCount", "stack", "count", "itemCount", "amount", "stackSize" }) do
        local value = MeaningfulNumber(info[key])
        if value ~= nil and value > 0 then return value end
    end
    return 1
end

local function ExtractCategory(info)
    if type(info) ~= "table" then return nil end
    for _, key in ipairs({ "category_id", "categoryId", "categoryID", "category" }) do
        local value = Primitive(info[key])
        if value ~= nil and tostring(value) ~= "" then return tostring(value) end
    end
    return nil
end

local function ExtractGrade(info)
    if type(info) ~= "table" then return nil end
    local grade = tonumber(Primitive(info.itemGrade or info.grade))
    if grade == nil or grade ~= grade then return nil end
    return math.floor(grade)
end

local function HasItem(info)
    return type(info) == "table" and next(info) ~= nil
end

local function CapabilityAllowed(name)
    if S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function" then return false, "API boundary unavailable" end
    return S.Api:IsCapabilityAllowed(name)
end

local function SafeGetContent(contentId)
    local allowed = CapabilityAllowed("ADDON:GetContent")
    if allowed ~= true or contentId == nil then return nil end
    local ok, value = S.Api:CallCapability("ADDON:GetContent", ADDON, "GetContent", contentId)
    if ok and value ~= nil then return value end
    return nil
end

local function ReadContentMainScriptPosVis(contentId)
    if contentId == nil or ADDON == nil then return false, nil end
    local allowed = CapabilityAllowed("ADDON:GetContentMainScriptPosVis")
    if allowed ~= true or type(ADDON.GetContentMainScriptPosVis) ~= "function" then return false, nil end

    -- This getter returns five values (x, y, width, height, visible).  Call it
    -- directly behind the capability gate instead of S.Api:CallCapability:
    -- the generic Call helper intentionally carries only four native return
    -- values and would otherwise drop the final visibility flag.
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

local function IsVisible(widget)
    if widget == nil or type(widget.IsVisible) ~= "function" then return false end
    local ok, value = pcall(function() return widget:IsVisible() end)
    return ok and value == true
end

local function ReadCapacity(capability, object)
    local allowed = CapabilityAllowed(capability)
    if allowed ~= true then return DEFAULT_SCAN_SLOTS end
    local ok, value = S.Api:CallCapability(capability, object, "Capacity")
    local n = ok and tonumber(value) or nil
    if n == nil or n ~= n or n <= 0 then return DEFAULT_SCAN_SLOTS end
    return math.max(1, math.min(MAX_SCAN_SLOTS, math.floor(n)))
end

function O:GetBankContent()
    if UIC_BANK == nil then return nil end
    local current = SafeGetContent(UIC_BANK)
    if current ~= nil then self.bankContent = current end
    return self.bankContent
end

function O:GetCofferContent()
    if UIC_COFFER == nil then return nil end
    local current = SafeGetContent(UIC_COFFER)
    if current ~= nil then self.cofferContent = current end
    return self.cofferContent
end

function O:GetBagContent()
    if UIC_BAG == nil then return nil end
    local current = SafeGetContent(UIC_BAG)
    if current ~= nil then self.bagContent = current end
    return self.bagContent
end

function O:GetNativeBankUiState()
    local available, state = ReadContentMainScriptPosVis(UIC_BANK)
    if available == true and type(state) == "table" then return true, state end
    return false, nil
end

function O:GetNativeCofferUiState()
    local available, state = ReadContentMainScriptPosVis(UIC_COFFER)
    if available == true and type(state) == "table" then return true, state end
    return false, nil
end

function O:GetNativeBagUiState()
    local available, state = ReadContentMainScriptPosVis(UIC_BAG)
    if available == true and type(state) == "table" then return true, state end
    return false, nil
end

function O:IsNativeBankVisible()
    local available, state = self:GetNativeBankUiState()
    if available == true then return state.visible == true end
    return IsVisible(self:GetBankContent())
end

function O:IsNativeCofferVisible()
    local available, state = self:GetNativeCofferUiState()
    if available == true then return state.visible == true end
    return IsVisible(self:GetCofferContent())
end

function O:MarkBankOpen(source)
    self.bankSessionOpen = true
    self.bankOpenSource = tostring(source or "event")
end

function O:MarkBankClosed(source)
    self.bankSessionOpen = false
    self.bankOpenSource = tostring(source or "closed")
end

function O:MarkCofferOpen(source)
    self.cofferSessionOpen = true
    self.cofferOpenSource = tostring(source or "event")
end

function O:MarkCofferClosed(source)
    self.cofferSessionOpen = false
    self.cofferOpenSource = tostring(source or "closed")
end

function O:GetOpenStorageKind()
    -- Native content visibility is preferred. Event latches remain a compatibility
    -- path for RU builds whose UIC_* proxy does not expose visibility correctly.
    local bankAvailable, bankState = self:GetNativeBankUiState()
    if bankAvailable == true then self.nativeDetectionReliable = true end
    if bankAvailable == true and type(bankState) == "table" and bankState.visible == true then
        self:MarkBankOpen("main-script-pos-vis")
        self.activeStorageKind = "bank"
        self.activeStorageSource = "main-script-pos-vis"
        self.lastStorageKind = "bank"
        return "bank", self.activeStorageSource
    end

    local cofferAvailable, cofferState = self:GetNativeCofferUiState()
    if cofferAvailable == true then self.nativeDetectionReliable = true end
    if cofferAvailable == true and type(cofferState) == "table" and cofferState.visible == true then
        self:MarkCofferOpen("main-script-pos-vis")
        self.activeStorageKind = "coffer"
        self.activeStorageSource = "main-script-pos-vis"
        self.lastStorageKind = "coffer"
        return "coffer", self.activeStorageSource
    end

    if IsVisible(self:GetBankContent()) then
        self:MarkBankOpen("content-visible")
        self.activeStorageKind = "bank"
        self.activeStorageSource = "content-visible"
        self.lastStorageKind = "bank"
        return "bank", self.activeStorageSource
    end
    if IsVisible(self:GetCofferContent()) then
        self:MarkCofferOpen("content-visible")
        self.activeStorageKind = "coffer"
        self.activeStorageSource = "content-visible"
        self.lastStorageKind = "coffer"
        return "coffer", self.activeStorageSource
    end

    -- G4: once native reads proved reliable this session, the event latches are
    -- redundant and must not resurrect a closed storage when an end event was
    -- lost. Old clients without a working native proxy keep the latch path.
    if self.nativeDetectionReliable ~= true then
        if self.cofferSessionOpen == true then
            self.activeStorageKind = "coffer"
            self.activeStorageSource = tostring(self.cofferOpenSource or "coffer-event")
            self.lastStorageKind = "coffer"
            return "coffer", self.activeStorageSource
        end
        if self.bankSessionOpen == true then
            self.activeStorageKind = "bank"
            self.activeStorageSource = tostring(self.bankOpenSource or "bank-event")
            self.lastStorageKind = "bank"
            return "bank", self.activeStorageSource
        end
    end

    self.activeStorageKind = nil
    self.activeStorageSource = "none"
    return nil, "none"
end

function O:IsBankOpen()
    -- Compatibility name retained for the settings/page layer. In organizer
    -- semantics, either a bank or a coffer is a valid open storage target.
    return self:GetOpenStorageKind() ~= nil
end

function O:IsBagOpen()
    local available, state = self:GetNativeBagUiState()
    if available == true then return state.visible == true end
    return IsVisible(self:GetBagContent())
end

function O:ResolveBagId()
    -- Reuse Resource's already-tested physical bag namespace selection when it
    -- is available. Force a fresh read because organizer plans must reflect the
    -- state at the user's click, not a potentially stale resource-card cache.
    local resource = S.Services and S.Services.Resource or nil
    if resource ~= nil and type(resource.BuildBagSnapshot) == "function" then
        resource.bagDirty = true
        resource.bagSnapshot = nil
        local ok, snapshot = xpcall(function() return resource:BuildBagSnapshot() end, S.SafeTraceback)
        if ok and type(snapshot) == "table" and tonumber(snapshot.bagId) ~= nil then
            return tonumber(snapshot.bagId)
        end
    end
    return 0
end

function O:IdentityFromInfo(info)
    if not HasItem(info) then return nil, nil end
    local itemType = ExtractItemType(info)
    if itemType ~= nil then
        return "type:" .. tostring(itemType), "type"
    end
    if S.State.settings.bagOrganizerAllowNameFallback ~= true then return nil, nil end
    local name = Trim(info.name or info.itemName)
    if name == "" then return nil, nil end
    local grade = ExtractGrade(info)
    local category = ExtractCategory(info)
    -- Name-only fallback is still useful for stackable materials on client
    -- builds that omit itemType/grade/category. The UI exposes an explicit
    -- switch to disable this fallback and require an itemType identity only.
    local key = table.concat({ "fallback", name, tostring(grade or ""), tostring(category or "") }, "|")
    return key, "fallback"
end

function O:IsBlocked(kind, entry)
    -- Pure blacklist judgment. No game API is called: this runs once per
    -- candidate inside BuildPlan and from the management window for display.
    if kind ~= "bank" and kind ~= "coffer" then return false end
    local state = S.State
    local blacklist = state ~= nil and state.settings and state.settings.bagOrganizerBlacklist or nil
    if type(blacklist) ~= "table" or blacklist.enabled ~= true then return false end
    if type(entry) ~= "table" then return false end
    local scope = type(blacklist[kind]) == "table" and blacklist[kind] or nil
    if scope == nil then return false end
    local items = type(scope.items) == "table" and scope.items or nil
    -- Query both numeric and string keys: client-side SaveData serialization may
    -- turn numeric table keys into strings across a relog. One tostring lookup
    -- neutralizes that whole class of silent blacklist loss.
    if items ~= nil and entry.itemType ~= nil
        and (items[entry.itemType] == true or items[tostring(entry.itemType)] == true) then return true end
    local categories = type(scope.categories) == "table" and scope.categories or nil
    if categories ~= nil and entry.category ~= nil and categories[tostring(entry.category)] == true then return true end
    return false
end

function O:ScanBag()
    local bagId = self:ResolveBagId()
    local maxSlot = ReadCapacity("X2Bag:Capacity", X2Bag)
    local result = { bagId = bagId, items = {}, occupied = 0, typed = 0, fallback = 0, unknown = 0, readErrors = 0 }
    for slot = 1, maxSlot do
        local ok, info = S.Api:CallCapability("X2Bag:GetBagItemInfo", X2Bag, "GetBagItemInfo", bagId, slot)
        if not ok then
            result.readErrors = result.readErrors + 1
        elseif HasItem(info) then
            result.occupied = result.occupied + 1
            local key, mode = self:IdentityFromInfo(info)
            if mode == "type" then result.typed = result.typed + 1
            elseif mode == "fallback" then result.fallback = result.fallback + 1
            else result.unknown = result.unknown + 1 end
            result.items[#result.items + 1] = {
                bagId = bagId,
                slot = slot,
                identity = key,
                identityMode = mode,
                name = Trim(info.name or info.itemName),
                itemType = ExtractItemType(info),
                category = ExtractCategory(info),
                -- Stack quantity (2026-08-24): a slot can hold 300 of a
                -- stackable material; count aggregation must sum stacks, not
                -- slots. Reads the same keys omnicraft uses.
                stack = ReadStack(info),
            }
        end
    end
    return result
end

function O:ScanBank()
    local maxSlot = ReadCapacity("X2Bank:Capacity", X2Bank)
    local result = { items = {}, occupied = 0, typed = 0, fallback = 0, unknown = 0, readErrors = 0 }
    for slot = 1, maxSlot do
        local ok, info = S.Api:CallCapability("X2Bank:GetBagItemInfo", X2Bank, "GetBagItemInfo", slot)
        if not ok then
            result.readErrors = result.readErrors + 1
        elseif HasItem(info) then
            result.occupied = result.occupied + 1
            local key, mode = self:IdentityFromInfo(info)
            if mode == "type" then result.typed = result.typed + 1
            elseif mode == "fallback" then result.fallback = result.fallback + 1
            else result.unknown = result.unknown + 1 end
            result.items[#result.items + 1] = {
                slot = slot,
                identity = key,
                identityMode = mode,
                name = Trim(info.name or info.itemName),
                itemType = ExtractItemType(info),
                category = ExtractCategory(info),
            }
        end
    end
    return result
end

function O:ScanCoffer()
    local maxSlot = ReadCapacity("X2Coffer:Capacity", X2Coffer)
    local result = { items = {}, occupied = 0, typed = 0, fallback = 0, unknown = 0, readErrors = 0 }
    for slot = 1, maxSlot do
        local ok, info = S.Api:CallCapability("X2Coffer:GetBagItemInfo", X2Coffer, "GetBagItemInfo", slot)
        if not ok then
            result.readErrors = result.readErrors + 1
        elseif HasItem(info) then
            result.occupied = result.occupied + 1
            local key, mode = self:IdentityFromInfo(info)
            if mode == "type" then result.typed = result.typed + 1
            elseif mode == "fallback" then result.fallback = result.fallback + 1
            else result.unknown = result.unknown + 1 end
            result.items[#result.items + 1] = {
                slot = slot,
                identity = key,
                identityMode = mode,
                name = Trim(info.name or info.itemName),
                itemType = ExtractItemType(info),
                category = ExtractCategory(info),
            }
        end
    end
    return result
end

function O:ScanStorage(kind)
    if kind == "coffer" then return self:ScanCoffer() end
    return self:ScanBank()
end

local function BuildIdentitySet(items)
    local set = {}
    for _, item in ipairs(type(items) == "table" and items or {}) do
        if item.identity ~= nil then set[item.identity] = true end
    end
    return set
end

function O:ValidateAction(direction)
    if self.started ~= true then return false, "整理背包模块尚未启用" end
    if self.busy == true then return false, "上一轮整理还在执行" end
    if direction ~= "withdraw" and direction ~= "deposit" then return false, "未知整理方向" end
    if X2Bag == nil then return false, "X2Bag 尚未就绪" end

    local openKind = self:GetOpenStorageKind()
    if S.State.settings.bagOrganizerRequireBankOpen == true and openKind == nil then
        return false, "当前启用了‘要求仓储打开’，请先打开仓库或箱子"
    end
    local storageKind = openKind or self.lastStorageKind or "bank"
    if storageKind == "coffer" and X2Coffer == nil then return false, "X2Coffer 尚未就绪" end
    if storageKind == "bank" and X2Bank == nil then return false, "X2Bank 尚未就绪" end

    local required
    if storageKind == "coffer" then
        required = direction == "withdraw"
            and { "X2Bag:GetBagItemInfo", "X2Coffer:GetBagItemInfo", "X2Coffer:MoveToEmptyBagSlot" }
            or { "X2Bag:GetBagItemInfo", "X2Coffer:GetBagItemInfo", "X2Bag:MoveToEmptyCofferSlot" }
    else
        required = direction == "withdraw"
            and { "X2Bag:GetBagItemInfo", "X2Bank:GetBagItemInfo", "X2Bank:MoveToEmptyBagSlot" }
            or { "X2Bag:GetBagItemInfo", "X2Bank:GetBagItemInfo", "X2Bag:MoveToEmptyBankSlot" }
    end
    for _, name in ipairs(required) do
        local ok, reason = CapabilityAllowed(name)
        if ok ~= true then return false, tostring(name) .. " 不可用：" .. tostring(reason or "blocked") end
    end
    return true, storageKind
end

function O:BuildPlan(direction, opts)
    local ok, storageKindOrReason = self:ValidateAction(direction)
    if ok ~= true then return nil, storageKindOrReason end
    local storageKind = tostring(storageKindOrReason or "bank")

    local bag = self:ScanBag()
    local storage = self:ScanStorage(storageKind)
    self.lastBagCount = bag.occupied
    self.lastBankCount = storage.occupied -- compatibility field used by the page
    self.lastTypedCount = bag.typed + storage.typed
    self.lastFallbackCount = bag.fallback + storage.fallback
    self.lastUnknownCount = bag.unknown + storage.unknown
    self.lastStorageKind = storageKind

    local references = BuildIdentitySet(direction == "withdraw" and bag.items or storage.items)
    local source = direction == "withdraw" and storage.items or bag.items
    -- Optional directed move (trade detail window P1-2): when opts.itemType is
    -- given, only candidates whose scan entry carries exactly that itemType are
    -- considered. Not passing opts keeps the default path byte-for-byte
    -- identical (frozen; the material_move test asserts the对照).
    --
    -- 2026-08-24 craft-assist fix: for a DIRECTED move (opts.itemType given) the
    -- identity-reference gate is BYPASSED. The craft window's 取/放 buttons mean
    -- "withdraw that itemType from storage / deposit that itemType from bag" --
    -- they must work even when the bag does NOT already contain the material
    -- (the old default path anchors on bag identity, so a material stored only
    -- in the bank could never be withdrawn). Directed matching by itemType is
    -- precise (scan entries carry itemType) and safe (blacklist still applies).
    local directedType = type(opts) == "table" and opts.itemType ~= nil and tonumber(opts.itemType) or nil
    local queue = {}
    local skippedByBlacklist = 0
    local maxMoves = math.max(0, math.floor(tonumber(S.State.settings.bagOrganizerMaxMoves) or 0))
    for _, item in ipairs(source) do
        if item.identity ~= nil and (directedType ~= nil or references[item.identity] == true) then
            -- Directed move (trade detail window P1-2): with opts.itemType the
            -- candidate must carry exactly that itemType; nil/other types skip.
            -- Without opts, directedMatch is always true -> default path frozen.
            local directedMatch = directedType == nil or item.itemType == directedType
            if directedMatch then
                if self:IsBlocked(storageKind, item) then
                    skippedByBlacklist = skippedByBlacklist + 1
                else
                    queue[#queue + 1] = {
                        bagId = item.bagId,
                        slot = item.slot,
                        identity = item.identity,
                        name = item.name,
                        identityMode = item.identityMode,
                    }
                    if maxMoves > 0 and #queue >= maxMoves then break end
                end
            end
        end
    end
    self.blacklistSkipped = skippedByBlacklist
    self.lastPlanCount = #queue
    return {
        direction = direction,
        storageKind = storageKind,
        queue = queue,
        blacklistSkipped = skippedByBlacklist,
        bag = bag,
        storage = storage,
    }
end

function O:RefreshViews()
    self:RefreshFloating()
    self:_Present("RefreshPage", self)
end

function O:Finish(cancelled)
    if S.Scheduler ~= nil then S.Scheduler:RemoveTask(TASK_MOVE) end
    local total = type(self.queue) == "table" and #self.queue or 0
    local actionName = self.direction == "withdraw" and "取" or "放"
    local blacklistSkipped = tonumber(self.blacklistSkipped) or 0
    local blacklistText = blacklistSkipped > 0 and (" · 黑名单跳过 " .. tostring(blacklistSkipped) .. " 件") or ""
    if cancelled == true then
        self.lastMessage = string.format("%s已停止：成功 %d · 失败 %d · 跳过 %d · 计划 %d%s",
            actionName, tonumber(self.completed) or 0, tonumber(self.failed) or 0, tonumber(self.skipped) or 0, total, blacklistText)
    else
        self.lastMessage = string.format("%s完成：成功 %d · 失败 %d · 跳过 %d · 计划 %d%s",
            actionName, tonumber(self.completed) or 0, tonumber(self.failed) or 0, tonumber(self.skipped) or 0, total, blacklistText)
    end
    self.busy = false
    self.queue = nil
    self.queueIndex = 0
    self.pendingVerify = nil
    self.direction = nil
    self.storageKind = nil

    local resource = S.Services and S.Services.Resource or nil
    if resource ~= nil then
        resource.bagDirty = true
        resource.bagSnapshot = nil
    end
    if S.State and type(S.State.MarkDirty) == "function" then S.State:MarkDirty("resources") end
    if S.State.settings.bagOrganizerReportResults == true then S.SafeChat(self.lastMessage) end
    self:RefreshViews()
end

function O:ReadPlannedSource(entry)
    if type(entry) ~= "table" then return false, nil, "invalid entry" end
    local ok, info, err
    if self.direction == "withdraw" then
        if self.storageKind == "coffer" then
            ok, info, err = S.Api:CallCapability("X2Coffer:GetBagItemInfo", X2Coffer, "GetBagItemInfo", entry.slot)
        else
            ok, info, err = S.Api:CallCapability("X2Bank:GetBagItemInfo", X2Bank, "GetBagItemInfo", entry.slot)
        end
    else
        ok, info, err = S.Api:CallCapability("X2Bag:GetBagItemInfo", X2Bag, "GetBagItemInfo", tonumber(entry.bagId) or 0, entry.slot)
    end
    if ok ~= true then return false, nil, tostring(err or "read failed") end
    local identity = self:IdentityFromInfo(info)
    return true, identity, nil
end

function O:IssueMove(entry)
    if self.direction == "withdraw" then
        if self.storageKind == "coffer" then
            return S.Api:ActionCapability("X2Coffer:MoveToEmptyBagSlot", X2Coffer, "MoveToEmptyBagSlot", entry.slot)
        end
        return S.Api:ActionCapability("X2Bank:MoveToEmptyBagSlot", X2Bank, "MoveToEmptyBagSlot", entry.slot)
    end
    if self.storageKind == "coffer" then
        return S.Api:ActionCapability("X2Bag:MoveToEmptyCofferSlot", X2Bag, "MoveToEmptyCofferSlot", entry.slot)
    end
    return S.Api:ActionCapability("X2Bag:MoveToEmptyBankSlot", X2Bag, "MoveToEmptyBankSlot", entry.slot)
end

function O:RecordMoveWarning(message)
    if S.DiagnosticsManager and type(S.DiagnosticsManager.Record) == "function" then
        S.DiagnosticsManager:Record("warning", "bag_organizer", tostring(message or "move warning"))
    end
end

function O:RunNextMove()
    if self.busy ~= true or type(self.queue) ~= "table" then
        if self.busy == true then self:Finish(false) end
        return
    end

    -- Verify the previous action one interval later. The move APIs historically
    -- had intermittent no-op failures on RU; checking the authoritative source
    -- slot prevents us from reporting a silent no-op as success. A retry is
    -- spaced by the same configured >=200 ms scheduler interval.
    local pending = self.pendingVerify
    if type(pending) == "table" then
        local readOk, currentIdentity, readErr = self:ReadPlannedSource(pending.entry)
        if readOk ~= true then
            self.failed = self.failed + 1
            self:RecordMoveWarning("verify slot " .. tostring(pending.entry.slot) .. ": " .. tostring(readErr))
            self.pendingVerify = nil
            self.queueIndex = self.queueIndex + 1
        elseif currentIdentity ~= pending.entry.identity then
            self.completed = self.completed + 1
            self.pendingVerify = nil
            self.queueIndex = self.queueIndex + 1
        elseif (tonumber(pending.retries) or 0) < MAX_MOVE_RETRIES then
            pending.retries = (tonumber(pending.retries) or 0) + 1
            local actionOk, actionErr = self:IssueMove(pending.entry)
            if actionOk ~= true then
                self:RecordMoveWarning("retry slot " .. tostring(pending.entry.slot) .. ": " .. tostring(actionErr or "refused"))
            end
            self:RefreshViews()
            return
        else
            self.failed = self.failed + 1
            self:RecordMoveWarning("move slot " .. tostring(pending.entry.slot) .. " remained unchanged after retries")
            self.pendingVerify = nil
            self.queueIndex = self.queueIndex + 1
        end
    end

    if self.queueIndex >= #self.queue then
        self:Finish(false)
        return
    end

    local entry = self.queue[self.queueIndex + 1]
    if entry == nil then
        self:Finish(false)
        return
    end

    -- Revalidate the exact source slot captured by the click-time plan. If the
    -- player sorts/moves/uses items while the queue is running, a changed slot
    -- is skipped rather than allowing the old slot number to move a new item.
    local readOk, currentIdentity, readErr = self:ReadPlannedSource(entry)
    if readOk ~= true then
        self.failed = self.failed + 1
        self.queueIndex = self.queueIndex + 1
        self:RecordMoveWarning("preflight slot " .. tostring(entry.slot) .. ": " .. tostring(readErr))
        if self.queueIndex >= #self.queue then self:Finish(false) end
        return
    end
    if currentIdentity ~= entry.identity then
        self.skipped = self.skipped + 1
        self.queueIndex = self.queueIndex + 1
        if self.queueIndex >= #self.queue then self:Finish(false) else self:RefreshViews() end
        return
    end

    local actionOk, actionErr = self:IssueMove(entry)
    self.pendingVerify = { entry = entry, retries = 0 }
    if actionOk ~= true then
        self:RecordMoveWarning("move slot " .. tostring(entry.slot) .. ": " .. tostring(actionErr or "refused"))
    end
    self:RefreshViews()
end

function O:Begin(direction, opts)
    local plan, err = self:BuildPlan(direction, opts)
    if plan == nil then
        self.lastMessage = tostring(err or "无法生成整理计划")
        S.SafeChat(self.lastMessage)
        self:RefreshViews()
        return false, self.lastMessage
    end
    local storageName = plan.storageKind == "coffer" and "箱子" or "仓库"
    if #plan.queue == 0 then
        self.lastMessage = direction == "withdraw"
            and ("没有找到" .. storageName .. "中与背包已有物品相同的物品。")
            or ("没有找到背包中与" .. storageName .. "已有物品相同的物品。")
        if plan.bag.unknown + plan.storage.unknown > 0 and S.State.settings.bagOrganizerAllowNameFallback ~= true then
            self.lastMessage = self.lastMessage .. " 有部分物品缺少 itemType；可在整理背包页开启名称回退。"
        end
        local blacklistSkipped = tonumber(plan.blacklistSkipped) or 0
        if blacklistSkipped > 0 then
            self.lastMessage = self.lastMessage .. " · 黑名单跳过 " .. tostring(blacklistSkipped) .. " 件"
        end
        S.SafeChat(self.lastMessage)
        self:RefreshViews()
        return true, 0
    end

    self.busy = true
    self.direction = direction
    self.storageKind = plan.storageKind
    self.queue = plan.queue
    self.queueIndex = 0
    self.completed = 0
    self.failed = 0
    self.skipped = 0
    self.pendingVerify = nil
    local actionName = direction == "withdraw" and "取" or "放"
    self.lastMessage = string.format("%s（%s）：已生成 %d 个移动任务", actionName, storageName, #plan.queue)
    self:RefreshViews()

    local interval = math.max(200, math.min(1000, tonumber(S.State.settings.bagOrganizerMoveIntervalMs) or 250))
    S.Scheduler:RemoveTask(TASK_MOVE)
    S.Scheduler:AddTask(TASK_MOVE, interval, function() O:RunNextMove() end, true, self, "P1")
    return true, #plan.queue
end

function O:Cancel()
    if self.busy ~= true then return false, "当前没有正在执行的整理任务" end
    self:Finish(true)
    return true
end

function O:RunDiagnostics()
    local bagAllowed, bagReason = CapabilityAllowed("X2Bag:GetBagItemInfo")
    local storageKind = self:GetOpenStorageKind() or self.lastStorageKind or "bank"
    local storageName = storageKind == "coffer" and "箱子" or "仓库"
    local readCapability = storageKind == "coffer" and "X2Coffer:GetBagItemInfo" or "X2Bank:GetBagItemInfo"
    local depositCapability = storageKind == "coffer" and "X2Bag:MoveToEmptyCofferSlot" or "X2Bag:MoveToEmptyBankSlot"
    local withdrawCapability = storageKind == "coffer" and "X2Coffer:MoveToEmptyBagSlot" or "X2Bank:MoveToEmptyBagSlot"
    local storageAllowed, storageReason = CapabilityAllowed(readCapability)
    local depositAllowed, depositReason = CapabilityAllowed(depositCapability)
    local withdrawAllowed, withdrawReason = CapabilityAllowed(withdrawCapability)
    if bagAllowed ~= true or storageAllowed ~= true then
        self.lastMessage = "诊断失败：背包/" .. storageName .. "读取 API 不完整"
        S.SafeChat(self.lastMessage .. " · Bag=" .. tostring(bagReason) .. " · Storage=" .. tostring(storageReason))
        self:RefreshViews()
        return false
    end
    if S.State.settings.bagOrganizerRequireBankOpen == true and self:GetOpenStorageKind() == nil then
        self.lastMessage = "诊断：请先打开仓库或箱子"
        S.SafeChat(self.lastMessage)
        self:RefreshViews()
        return false
    end
    local bag = self:ScanBag()
    local storage = self:ScanStorage(storageKind)
    self.lastBagCount, self.lastBankCount = bag.occupied, storage.occupied
    self.lastTypedCount = bag.typed + storage.typed
    self.lastFallbackCount = bag.fallback + storage.fallback
    self.lastUnknownCount = bag.unknown + storage.unknown
    self.lastStorageKind = storageKind
    self.lastMessage = string.format("诊断完成：背包 %d 格 · %s %d 格 · ID %d · 回退 %d · 无身份 %d",
        bag.occupied, storageName, storage.occupied, self.lastTypedCount, self.lastFallbackCount, self.lastUnknownCount)
    S.SafeChat(self.lastMessage .. " · 放API=" .. tostring(depositAllowed) .. " · 取API=" .. tostring(withdrawAllowed)
        .. (depositAllowed and "" or ("(" .. tostring(depositReason) .. ")"))
        .. (withdrawAllowed and "" or ("(" .. tostring(withdrawReason) .. ")")))
    self:RefreshViews()
    return true
end

local function IsPlausibleWindowRect(x, y, width, height, logicalW, logicalH)
    x, y, width, height = tonumber(x), tonumber(y), tonumber(width), tonumber(height)
    if x == nil or y == nil or width == nil or height == nil then return false end
    if width < 80 or height < 80 then return false end
    -- UIC_BAG on this RU client can report a useful extent with a synthetic
    -- (0,0) content origin. That is not the movable inventory window itself.
    if math.abs(x) <= 2 and math.abs(y) <= 2 then return false end
    -- Never mistake UIParent/full-screen wrappers for the bag window.
    if width >= logicalW * 0.92 and height >= logicalH * 0.92 then return false end
    if x < -width or y < -height or x > logicalW + width or y > logicalH + height then return false end
    return true
end

function O:ResolveBagAnchorRect()
    local context = S.Layout:GetContext()
    local logicalW = tonumber(context.logicalWidth) or 1024
    local logicalH = tonumber(context.logicalHeight) or 768

    local available, state = self:GetNativeBagUiState()
    if available == true and type(state) == "table"
        and IsPlausibleWindowRect(state.x, state.y, state.width, state.height, logicalW, logicalH) then
        local rect = { x=tonumber(state.x), y=tonumber(state.y), width=tonumber(state.width), height=tonumber(state.height) }
        self.lastBagAnchorSource = "main-script"
        self.lastBagAnchorRect = rect
        return rect
    end

    -- ADDON:GetContent(UIC_BAG) can be a content proxy whose own effective
    -- origin is (0,0). Walk upward through the allowed GetParent() chain and
    -- select the nearest movable, non-screen-sized ancestor with a real global
    -- rectangle. This keeps the overlay attached to the actual bag window.
    local node = self:GetBagContent()
    for depth = 0, 8 do
        if node == nil then break end
        local ok, x, y, width, height = pcall(function()
            return S.Layout:GetLogicalRect(node)
        end)
        if ok and IsPlausibleWindowRect(x, y, width, height, logicalW, logicalH) then
            local rect = { x=tonumber(x), y=tonumber(y), width=tonumber(width), height=tonumber(height) }
            self.lastBagAnchorSource = depth == 0 and "bag-widget" or ("bag-parent-" .. tostring(depth))
            self.lastBagAnchorRect = rect
            return rect
        end
        if type(node.GetParent) ~= "function" then break end
        local parentOk, parent = pcall(function() return node:GetParent() end)
        if not parentOk or parent == nil or parent == node then break end
        node = parent
    end

    self.lastBagAnchorSource = "unresolved"
    self.lastBagAnchorRect = nil
    return nil
end

function O:RefreshFloating()
    local storageKind = self:GetOpenStorageKind()
    local storageVisible = storageKind ~= nil
    local bagVisible = self:IsBagOpen()
    self.lastBankVisible = storageKind == "bank"
    self.lastCofferVisible = storageKind == "coffer"
    self.lastBagVisible = bagVisible

    local shouldShow = self.started == true
        and S.State.settings.bagOrganizerShowBagButtons == true
        and storageVisible == true
    self.floatingVisible = shouldShow
    self:_Present("RefreshFloating", self, {
        storageKind = storageKind,
        storageVisible = storageVisible,
        bagVisible = bagVisible,
        shouldShow = shouldShow,
        withdrawText = self.busy and self.direction == "withdraw" and "取…" or "取",
        depositText = self.busy and self.direction == "deposit" and "放…" or "放",
        controlsEnabled = self.busy ~= true,
    })
end

function O:WatchFloatingVisibility()
    if self.started ~= true then return end
    -- 150ms watcher reads only native content visibility/geometry. No inventory
    -- slot scan, item identity match, or move API occurs here.
    local storageKind = self:GetOpenStorageKind()
    local bagVisible = self:IsBagOpen()
    local bankVisible = storageKind == "bank"
    local cofferVisible = storageKind == "coffer"
    if bankVisible ~= self.lastBankVisible or cofferVisible ~= self.lastCofferVisible
        or bagVisible ~= self.lastBagVisible or storageKind ~= nil then
        -- While storage is open the lightweight watcher also lets the presenter
        -- follow a moved native bag window. No inventory scan occurs here.
        self:RefreshFloating()
    end
end

-- IMPORTANT: Do not call ADDON:RegisterContentTriggerFunc for UIC_BAG/UIC_BANK/
-- UIC_COFFER. Those native IDs keep full client Authority. We only observe
-- native visibility/events and present our own system-layer overlay.

function O:OnBankOpenSignal(eventName)
    if self.started ~= true then return end
    self:MarkCofferClosed("bank-open")
    self:MarkBankOpen("event:" .. tostring(eventName or "bank"))
    self:RefreshFloating()
end

function O:OnCofferOpenSignal(eventName)
    if self.started ~= true then return end
    self:MarkBankClosed("coffer-open")
    self:MarkCofferOpen("event:" .. tostring(eventName or "coffer"))
    self:RefreshFloating()
end

function O:OnCofferClosed(eventName)
    if self.started ~= true then return end
    self:MarkCofferClosed("event:" .. tostring(eventName or "coffer_end"))
    self:RefreshFloating()
end

function O:OnInteractionEnd(eventName)
    if self.started ~= true then return end
    self:MarkBankClosed("event:" .. tostring(eventName or "interaction_end"))
    self:MarkCofferClosed("event:" .. tostring(eventName or "interaction_end"))
    self:RefreshFloating()
end

function O:Start()
    if self.started == true then return true end
    self.started = true
    self.busy = false
    self.lastMessage = "等待操作"
    self.bagContent = nil
    self.bankContent = nil
    self.cofferContent = nil
    self.lastBagVisible = false
    self.lastBankVisible = false
    self.lastCofferVisible = false
    self.bankSessionOpen = false
    self.bankOpenSource = "none"
    self.cofferSessionOpen = false
    self.cofferOpenSource = "none"
    self.activeStorageKind = nil
    self.activeStorageSource = "none"
    self.lastBagAnchorSource = "none"
    self.lastBagAnchorRect = nil
    self.floatingPlacement = "hidden"
    self.floatingVisible = false
    self:RefreshFloating()

    if S.Events ~= nil then
        if type(S.Events.UnsubscribeOwner) == "function" then S.Events:UnsubscribeOwner(self) end
        for _, eventName in ipairs({
            "BANK_UPDATE", "BANK_EXPANDED", "BANK_TAB_SWITCHED", "BANK_TAB_CREATED",
            "BANK_TAB_REMOVED", "BANK_TAB_SORTED", "BANK_REAL_INDEX_SHOW",
            "PLAYER_BANK_MONEY", "PLAYER_BANK_AA_POINT",
        }) do
            local subscribedEvent = eventName
            S.Events:Subscribe(subscribedEvent, self, function(_, ...)
                O:OnBankOpenSignal(subscribedEvent, ...)
            end)
        end

        -- Coffer/chest has its own API namespace and interaction events. Treat it
        -- as a first-class storage target, not as a bank alias.
        for _, eventName in ipairs({
            "COFFER_INTERACTION_START", "COFFER_UPDATE", "COFFER_TAB_SWITCHED",
            "COFFER_TAB_CREATED", "COFFER_TAB_REMOVED", "COFFER_TAB_SORTED",
            "COFFER_REAL_INDEX_SHOW",
        }) do
            local subscribedEvent = eventName
            S.Events:Subscribe(subscribedEvent, self, function(_, ...)
                O:OnCofferOpenSignal(subscribedEvent, ...)
            end)
        end
        S.Events:Subscribe("COFFER_INTERACTION_END", self, function(_, ...)
            O:OnCofferClosed("COFFER_INTERACTION_END", ...)
        end)

        for _, eventName in ipairs({ "NPC_INTERACTION_END", "INTERACTION_END" }) do
            local subscribedEvent = eventName
            S.Events:Subscribe(subscribedEvent, self, function(_, ...)
                O:OnInteractionEnd(subscribedEvent, ...)
            end)
        end
        for _, eventName in ipairs({ "NPC_INTERACTION_START", "INTERACTION_START", "BAG_UPDATE" }) do
            S.Events:Subscribe(eventName, self, function() O:RefreshFloating() end)
        end
    end

    if S.Scheduler ~= nil then
        S.Scheduler:RemoveTask(TASK_VISIBILITY)
        -- 150ms light geometry/visibility watcher; never scans inventory slots.
        S.Scheduler:AddTask(TASK_VISIBILITY, 150, function() O:WatchFloatingVisibility() end, false, self, "P2")
    end
    self:RefreshViews()
    return true
end

function O:Stop()
    if S.Scheduler ~= nil then
        S.Scheduler:RemoveTask(TASK_MOVE)
        S.Scheduler:RemoveTask(TASK_VISIBILITY)
    end
    if S.Events ~= nil and type(S.Events.UnsubscribeOwner) == "function" then S.Events:UnsubscribeOwner(self) end
    self.busy = false
    self.queue = nil
    self.queueIndex = 0
    self.pendingVerify = nil
    self.direction = nil
    self.storageKind = nil
    self.started = false
    self.lastBagVisible = false
    self.lastBankVisible = false
    self.lastCofferVisible = false
    self.bankSessionOpen = false
    self.bankOpenSource = "stopped"
    self.cofferSessionOpen = false
    self.cofferOpenSource = "stopped"
    self.activeStorageKind = nil
    self.activeStorageSource = "none"
    self.lastBagAnchorSource = "none"
    self.lastBagAnchorRect = nil
    self.floatingPlacement = "hidden"
    self.floatingVisible = false
    self:_Present("HideFloating")
    return true
end
