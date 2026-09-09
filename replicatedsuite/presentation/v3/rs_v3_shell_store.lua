------------------------------------------------------------------------
-- Replicated Suite V3 - Shell Persistence Contract
--
-- Application-window preferences only. Domain/Feature state is never stored
-- here. Schema v7 preserves explicit V3 free-placement plus responsive source
-- viewport metadata. Schema v6 remains a read-only historical canonical for
-- exact integrity recovery; never change a canonical shape without a schema bump.
-- Legacy edge placement is intentionally re-centered once so the rebuilt menu no longer
-- inherits old top-left defaults. Windowing adds no semantic minimum/maximum
-- unless a caller opts in.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P = S.Persistence
if type(P) ~= "table" or type(P.RegisterV3Store) ~= "function" then return end

S.UIV3 = S.UIV3 or {}
local V3 = S.UIV3
V3.ShellSizePolicy = {
    defaultWidth = 1040,
    defaultHeight = 700,
    minWidth = 1,
    minHeight = 1,
}
local SIZE = V3.ShellSizePolicy
V3.ShellState = type(V3.ShellState) == "table" and V3.ShellState or {
    width = SIZE.defaultWidth,
    height = SIZE.defaultHeight,
    lastRoute = "home",
    minimized = false,
    locked = false,
    userMoved = false,
}

local STORE_ID = "v3.shell"
local function AtLeast(value, minimum, fallback)
    local number = tonumber(value) or tonumber(fallback) or minimum
    return math.max(minimum, number)
end
local function NormalizeState(value)
    value = type(value) == "table" and value or {}
    local requestedMoved = value.userMoved == true
    local free = requestedMoved and tostring(value.coordinateSpace or "") == "logical-free-v2"
        and tonumber(value.x) ~= nil and tonumber(value.y) ~= nil
    -- Edge-v1 belonged to the retired shell placement model. Carrying an old
    -- LEFT/TOP offset of zero into V3 makes the rebuilt menu reopen in the
    -- corner forever. Only an explicit V3 free placement is authoritative.
    local moved = free
    return {
        width = AtLeast(value.width, SIZE.minWidth, SIZE.defaultWidth),
        height = AtLeast(value.height, SIZE.minHeight, SIZE.defaultHeight),
        lastRoute = (tostring(value.lastRoute or "home") == "foundation") and "home" or tostring(value.lastRoute or "home"),
        minimized = value.minimized == true,
        locked = value.locked == true,
        userMoved = moved,
        x = moved and tonumber(value.x) or nil,
        y = moved and tonumber(value.y) or nil,
        anchorH = nil,
        anchorV = nil,
        offsetX = nil,
        offsetY = nil,
        coordinateSpace = moved and "logical-free-v2" or nil,
        savedUiScale = moved and tonumber(value.savedUiScale) or nil,
        savedLogicalWidth = moved and tonumber(value.savedLogicalWidth) or nil,
        savedLogicalHeight = moved and tonumber(value.savedLogicalHeight) or nil,
        normalizedCenterX = moved and tonumber(value.normalizedCenterX) or nil,
        normalizedCenterY = moved and tonumber(value.normalizedCenterY) or nil,
    }
end

-- Historical schema-v6 canonical. `.18.157` extended the shell payload with
-- responsive placement metadata but the Store remained schema 6. That did not
-- guarantee a mismatch for every old payload (nil fields are omitted by Lua),
-- but it removed the schema boundary needed to distinguish the two canonical
-- generations. Keep this function immutable and narrow: Persistence may try it
-- only after a current-v4 mismatch, and accepts it only when it reproduces the
-- already-stamped old fingerprint byte-for-byte while the independent envelope
-- seal is valid. Unknown/corrupt payloads therefore remain fail-closed.
local function NormalizeHistoricalV6(value)
    value = type(value) == "table" and value or {}
    local requestedMoved = value.userMoved == true
    local free = requestedMoved and tostring(value.coordinateSpace or "") == "logical-free-v2"
        and tonumber(value.x) ~= nil and tonumber(value.y) ~= nil
    local moved = free
    return {
        width = AtLeast(value.width, SIZE.minWidth, SIZE.defaultWidth),
        height = AtLeast(value.height, SIZE.minHeight, SIZE.defaultHeight),
        lastRoute = (tostring(value.lastRoute or "home") == "foundation") and "home" or tostring(value.lastRoute or "home"),
        minimized = value.minimized == true,
        locked = value.locked == true,
        userMoved = moved,
        x = moved and tonumber(value.x) or nil,
        y = moved and tonumber(value.y) or nil,
        anchorH = nil,
        anchorV = nil,
        offsetX = nil,
        offsetY = nil,
        coordinateSpace = moved and "logical-free-v2" or nil,
        savedUiScale = moved and tonumber(value.savedUiScale) or nil,
    }
end

V3.ShellCanonicalMigrationContractVersion = 1
V3.ShellStoreSchemaContractVersion = 7
V3.ShellKnownLegacyRecoveryContractVersion = 1

-- Real-machine incident identity, observed unchanged on `.18.184` and `.18.187`:
--   stamped v4 = 2EA0A82A, current canonical = 2EC2F5C5
--
-- This is deliberately NOT a generic "accept shell mismatch" escape hatch. The
-- Persistence core reaches this hook only after envelope seal + metadata + decode
-- + budget + exact historical reconstruction have all passed/failed as required.
-- We additionally require the exact old/new fingerprint pair and schema 6. This
-- follows the same one-time Store-owned migration pattern used by Death Review:
-- preserve the validated UI-domain payload, immediately restamp with schema 7,
-- and leave every unknown fingerprint fenced.
local KNOWN_V6_STAMP = "2EA0A82A"
local KNOWN_V7_CANONICAL = "2EC2F5C5"
local SHELL_BUDGET = { maxDepth = 5, maxNodes = 80, maxStringBytes = 2048, maxEntriesPerTable = 40 }

local function RecoverKnownV6Shell(decoded, stampedFingerprint, currentCanonical, raw)
    local meta = type(raw) == "table" and raw.__rsmeta or nil
    if type(meta) ~= "table" or tonumber(meta.schema) ~= 6
        or tostring(meta.store or "") ~= STORE_ID
        or tostring(meta.owner or "") ~= "v3.shell" then
        return nil
    end
    if tostring(stampedFingerprint or "") ~= KNOWN_V6_STAMP then return nil end
    if type(decoded) ~= "table" or type(currentCanonical) ~= "table" then return nil end

    -- Normalize again rather than returning raw decoded data. Unknown/legacy keys
    -- are intentionally dropped by the current schema authority before recovery.
    local normalized = NormalizeState(decoded)
    local currentFingerprint = P:FingerprintDurablePayload(normalized, SHELL_BUDGET)
    if tostring(currentFingerprint or "") ~= KNOWN_V7_CANONICAL then return nil end
    return normalized, "shell_v6_known_stamp_2EA0A82A"
end

local function Apply(value)
    local normalized = NormalizeState(value)
    for key in pairs(V3.ShellState) do V3.ShellState[key] = nil end
    for key, item in pairs(normalized) do V3.ShellState[key] = item end
end

if P:GetStore(STORE_ID) == nil then
    local store, err = P:RegisterV3Store({
        id = STORE_ID,
        owner = "v3.shell",
        scope = P.Scope.Account,
        lifetime = P.Lifetime.Permanent,
        schemaVersion = 7,
        legacySchemaVersion = 6,
        key = P.V3KeyPrefix .. "shell",
        budget = SHELL_BUDGET,
        default = function() return NormalizeState(nil) end,
        get = function() return NormalizeState(V3.ShellState) end,
        apply = Apply,
        migrate = function(value) return NormalizeState(value) end,
        -- Exact v6 -> v7 canonical bridge. The raw metadata check prevents this
        -- historical candidate from being considered for a current/future schema.
        -- Persistence itself hashes the candidate and accepts it only when that
        -- hash equals the already-stamped old fingerprint.
        rebuildCanonicalForIntegrity = function(decoded, _stampedFingerprint, _currentCanonical, raw)
            local meta = type(raw) == "table" and raw.__rsmeta or nil
            if type(meta) ~= "table" or tonumber(meta.schema) ~= 6 then return nil end
            return NormalizeHistoricalV6(decoded)
        end,
        -- Final one-time bridge for the repeated `.18.184/.18.187` RU incident.
        -- Exact historical reconstruction above always gets first chance; this
        -- hook handles only the known stamp pair and otherwise returns nil.
        recoverKnownLegacyCanonical = RecoverKnownV6Shell,
    })
    if store == nil and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Error) == "function" then
        S.DiagnosticsManager:Error("ui_v3", "SHELL_STORE_REGISTER_FAILED", "新版主窗口存档注册失败", { error = tostring(err) })
    end
end

V3.ShellStoreId = STORE_ID
V3.ShellStoreLoaded = V3.ShellStoreLoaded == true
V3.ShellStoreSessionFallback = V3.ShellStoreSessionFallback == true
V3.ShellStoreLoadError = V3.ShellStoreLoadError

function V3:UseShellSessionDefaults(reason)
    Apply(nil)
    self.ShellStoreLoaded = true
    self.ShellStoreSessionFallback = true
    self.ShellStoreLoadError = tostring(reason or "shell store load failed")
    if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Warn) == "function" then
        S.DiagnosticsManager:Warn("ui_v3", "SHELL_STORE_SESSION_FALLBACK",
            "主窗口存档读取失败；本次会话使用默认窗口状态，原存档不会因降级启动被主动覆盖",
            { error = self.ShellStoreLoadError })
    end
    return true
end

function V3:EnsureShellStoreLoaded()
    if self.ShellStoreLoaded == true then return true end
    local store = P:GetStore(STORE_ID)
    if store == nil then return self:UseShellSessionDefaults("新版主窗口存档不可用") end
    local status, _, err = P:LoadStore(STORE_ID)
    if status == true or status == "empty" then
        if status == "empty" then Apply(nil) end
        self.ShellStoreLoaded = true
        self.ShellStoreSessionFallback = false
        self.ShellStoreLoadError = nil
        return true
    end
    return self:UseShellSessionDefaults(err or tostring(status or "读取失败"))
end

function V3:MarkShellStoreDirty(delayMs, reason)
    if P:GetStore(STORE_ID) == nil then return false, "新版主窗口存档不可用" end
    -- Session fallback is intentionally memory-only. Navigation/geometry may
    -- continue to change for usability, but must not turn a protected failed
    -- load into WRITE_BEFORE_LOAD noise or overwrite the last recoverable save.
    if self.ShellStoreSessionFallback == true then return true, "session_fallback_no_persist" end
    return P:MarkDirty(STORE_ID, tonumber(delayMs) or 750, reason or "shell_changed")
end
