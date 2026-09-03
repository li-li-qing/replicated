------------------------------------------------------------------------
-- Replicated Suite - Storage
-- Author: Replicated
--
-- Schema 20: Account base + Character Override with explicit false booleans.
-- Suite owns only Suite state here. Historical DPS/Healer/Gear/Plates Domain
-- persistence keys are deliberately NOT migrated by this layer.
------------------------------------------------------------------------

if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

S.Storage = {
    dirty = false,
    dueAt = 0,
    lastError = nil,
    failureCount = 0,
    loadedSchema = 0,
    characterKey = nil,
    characterOverrides = {},
    accountCharacterBase = nil,
    characterScopeDeferred = false,
    deferredCharacterSnapshot = nil,
    lastCharacterKey = nil,
    loadFailed = false,
    futureSchema = false,
    writeFenceReason = nil,
    factoryResetPending = false,
}
local Storage = S.Storage

-- 2026-08-24: daily counters are persisted under their OWN tiny save key.
-- The main Suite payload (settings/modules/ui/life/profiles/...) is large and
-- the RU client's SaveData serializer drops trailing fields -- dailyCounters
-- (last in BuildSavePayload) was silently lost, so every reload re-initialized
-- today's earnings to 0. A dedicated tiny key cannot be truncated and survives
-- any payload growth. The main payload keeps a copy as a backward-compatible
-- fallback and is migrated once to the dedicated key on first load.
local function DailyCountersKey()
    return tostring(S.SaveKey or "replicated_suite_v1") .. "_daily"
end

local function DeepCopy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[DeepCopy(key)] = DeepCopy(child) end
    return result
end

local function NonEmptyText(value)
    if value == nil then return nil end
    local text = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil end
    return text
end

local function DeepEqual(left, right, seen)
    if left == right then return true end
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return false end
    seen = seen or {}
    if seen[left] == right then return true end
    seen[left] = right
    for key, value in pairs(left) do
        if not DeepEqual(value, right[key], seen) then return false end
    end
    for key in pairs(right) do
        if left[key] == nil then return false end
    end
    return true
end

-- Merge only values that changed while character identity was cold.  The
-- deferred base is the exact effective character snapshot loaded before the
-- world-qualified identity became available.  This preserves an already-saved
-- Schema-20+ override while still honoring user edits made during that short
-- cold-start window.
-- Schema 21: module enabled state, team/damage-review feature toggles and
-- dailyCounters (今日收益) are Account-scoped; cold-start edits to them are
-- saved through the Account base, so only per-character business data (life)
-- needs merging here.
local function MergeColdEdits(base, current, persisted)
    base = type(base) == "table" and base or {}
    current = type(current) == "table" and current or {}
    local merged = type(persisted) == "table" and DeepCopy(persisted) or DeepCopy(current)

    merged.life = type(merged.life) == "table" and merged.life or {}
    local baseLife = type(base.life) == "table" and base.life or {}
    local currentLife = type(current.life) == "table" and current.life or {}
    for _, key in ipairs({"dailyTracking", "eventTaskTracking", "eventDailyDone", "damageReviewHistory"}) do
        if not DeepEqual(currentLife[key], baseLife[key]) then
            merged.life[key] = DeepCopy(currentLife[key])
        end
    end
    return merged
end

function Storage:ResolveCharacterKey()
    -- Persist only a world-qualified identity. Falling back to UnitName would
    -- create a second key when UnitNameWithWorld becomes available later and
    -- can also collide across worlds. If identity is cold during bootstrap we
    -- simply defer Character Override materialization until a later SaveNow().
    if X2Unit ~= nil and S.Api ~= nil and type(S.Api.CallCapability) == "function" then
        local ok, value = S.Api:CallCapability("X2Unit:UnitNameWithWorld", X2Unit, "UnitNameWithWorld", "player")
        value = ok and NonEmptyText(value) or nil
        if value ~= nil then return "world:" .. value end
    end
    return nil
end

function Storage:GetCharacterScopedModuleSet()
    local result = {}
    local manager = S.ModuleManager
    if manager == nil or type(manager.registry) ~= "table" then return result end
    for id, def in pairs(manager.registry) do
        if type(def) == "table" and def.Internal ~= true and tostring(def.DataScope or "account") == "character" then
            result[tostring(id)] = true
        end
    end
    return result
end

function Storage:ReconcileCharacterScopedModules(moduleSet)
    local manager = S.ModuleManager
    local runtime = S.Runtime
    if manager == nil or runtime == nil or runtime.started ~= true then return true end
    for id in pairs(moduleSet or {}) do
        local desired = S.State ~= nil and S.State.modules ~= nil and S.State.modules[id] ~= nil
            and S.State.modules[id].enabled == true
        local actual = type(manager.IsEnabled) == "function" and manager:IsEnabled(id) or false
        if desired ~= actual then
            local ok, err
            if desired then ok, err = manager:Enable(id, false)
            else ok, err = manager:Disable(id, false, "character_scope_resolved") end
            if ok ~= true and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Record) == "function" then
                S.DiagnosticsManager:Record("warning", "storage",
                    "character scope reconcile " .. tostring(id) .. ": " .. tostring(err or "failed"))
            end
        end
    end
    return true
end

local function PublishCharacterScope(StorageSelf, moduleSet)
    StorageSelf:ReconcileCharacterScopedModules(moduleSet)
    if S.Runtime ~= nil and S.Runtime.started == true and type(S.Runtime.OnCharacterScopeResolved) == "function" then
        S.Runtime:OnCharacterScopeResolved()
    end
    if S.State ~= nil then S.State:MarkDirty("all") end
end

function Storage:RefreshCharacterScope(reason)
    local key = self:ResolveCharacterKey()
    if key == nil then
        if self.characterKey == nil then self.characterScopeDeferred = true end
        return false, "identity unavailable"
    end

    local moduleSet = self:GetCharacterScopedModuleSet()
    if self.characterKey == key and self.characterScopeDeferred ~= true then
        return true, "unchanged"
    end

    -- First authoritative identity after a cold bootstrap. Preserve an existing
    -- Schema-20 override and overlay only edits made while the Account base was
    -- temporarily visible.
    if self.characterKey == nil then
        local current = S.State:BuildCharacterOverride(moduleSet)
        local coldBase = type(self.deferredCharacterSnapshot) == "table"
            and self.deferredCharacterSnapshot or DeepCopy(current)
        local persisted = self.characterOverrides and self.characterOverrides[key] or nil
        local hadColdEdits = not DeepEqual(current, coldBase)
        local merged = MergeColdEdits(coldBase, current, persisted, moduleSet)

        self.characterKey = key
        self.lastCharacterKey = key
        self.characterScopeDeferred = false
        self.deferredCharacterSnapshot = nil
        S.State:ApplyCharacterOverride(merged, moduleSet)
        PublishCharacterScope(self, moduleSet)

        if type(persisted) ~= "table" or hadColdEdits or self.loadedSchema < (tonumber(S.Constants and S.Constants.SaveSchemaVersion) or 20) then
            self:RequestSave(0)
        end
        return true, type(persisted) == "table" and "resolved_existing" or "resolved_new"
    end

    -- Same addon generation, different world-qualified player identity. Never
    -- let Character A's effective state become Character B's implicit base:
    -- snapshot A first, restore the stable Account base, then apply B.
    local previousKey = self.characterKey
    self.characterOverrides = type(self.characterOverrides) == "table" and self.characterOverrides or {}
    self.characterOverrides[previousKey] = S.State:BuildCharacterOverride(moduleSet)

    if type(self.accountCharacterBase) == "table" then
        S.State:ApplyCharacterOverride(self.accountCharacterBase, moduleSet)
    end
    local nextOverride = self.characterOverrides[key]
    if type(nextOverride) == "table" then
        S.State:ApplyCharacterOverride(nextOverride, moduleSet)
    end

    self.characterKey = key
    self.lastCharacterKey = key
    self.characterScopeDeferred = false
    self.deferredCharacterSnapshot = nil
    PublishCharacterScope(self, moduleSet)
    self:RequestSave(0)
    return true, "switched:" .. tostring(previousKey) .. "->" .. tostring(key) .. ":" .. tostring(reason or "watch")
end

function Storage:TryResolveDeferredCharacterScope()
    if self.characterKey ~= nil and self.characterScopeDeferred ~= true then return true end
    return self:RefreshCharacterScope("deferred")
end

local function RestoreAccountCharacterBase(payload, base)
    if type(payload) ~= "table" or type(base) ~= "table" then return end
    -- Schema 21: module enabled state, team/damage-review feature toggles and
    -- dailyCounters (今日收益) are Account-scoped usage data and stay in the
    -- Account base (payload.dailyCounters keeps the live value from
    -- BuildSavePayload; it is never overwritten by the load-time snapshot).
    -- Character Override carries only per-character business data (life).
    -- FIX: trade.favorites and auctionFavorites are Account-scoped but were
    -- missing from this whitelist, causing them to be overwritten by the empty
    -- Account Base snapshot captured at login. They must be preserved here.

    payload.life = type(payload.life) == "table" and payload.life or {}
    local baseLife = type(base.life) == "table" and base.life or {}
    payload.life.dailyTracking = DeepCopy(baseLife.dailyTracking)
    payload.life.eventTaskTracking = DeepCopy(baseLife.eventTaskTracking)
    payload.life.eventDailyDone = DeepCopy(baseLife.eventDailyDone)
    payload.life.damageReviewHistory = DeepCopy(baseLife.damageReviewHistory)
    -- NOTE: trade.favorites and auctionFavorites are Account-scoped favorites.
    -- They are persisted directly in the main payload via BuildSavePayload and
    -- restored by ApplySaved. They must NOT be overwritten here with the
    -- per-character accountCharacterBase snapshot, which is only captured once
    -- at Load and goes stale after in-session additions -- that stale clobber
    -- is what cleared the favorites on a character switch.
end

local function RepairSchema19FalseBooleans(value, schema)
    if tonumber(schema) ~= 19 or type(value) ~= "table" then return value, false end
    local changed = false
    value.settings = type(value.settings) == "table" and value.settings or {}
    for _, key in ipairs({"teamAutoRoleEnabled", "sacMarkerEnabled"}) do
        -- Audit4 Schema19's BuildCharacterOverride used `value or nil`, so true
        -- was always serialized and false was the only boolean that vanished.
        -- This makes the missing value unambiguous for that one writer version.
        if value.settings[key] == nil then value.settings[key] = false; changed = true end
    end
    if type(value.characterOverrides) == "table" then
        for _, override in pairs(value.characterOverrides) do
            if type(override) == "table" then
                override.settings = type(override.settings) == "table" and override.settings or {}
                for _, key in ipairs({"teamAutoRoleEnabled", "sacMarkerEnabled"}) do
                    if override.settings[key] == nil then override.settings[key] = false; changed = true end
                end
            end
        end
    end
    return value, changed
end

function Storage:Load()
    local value, err = S.Api:LoadData(S.SaveKey)
    if err ~= nil then
        -- A read error is different from a missing key. Continue with in-memory
        -- defaults so the UI remains recoverable, but fence SaveData for this
        -- generation: writing defaults over an unreadable existing save would
        -- be irreversible data loss.
        self.lastError = err
        self.loadFailed = true
        self.futureSchema = false
        self.writeFenceReason = "load_failed"
        self.loadedSchema = 0
        local moduleSet = self:GetCharacterScopedModuleSet()
        self.accountCharacterBase = S.State:BuildCharacterOverride(moduleSet)
        self.characterOverrides = {}
        self.characterKey = self:ResolveCharacterKey()
        self.characterScopeDeferred = self.characterKey == nil
        self.deferredCharacterSnapshot = self.characterScopeDeferred
            and S.State:BuildCharacterOverride(moduleSet) or nil
        S.SafeChat("读取配置失败，本次会话将禁止覆盖存档：" .. tostring(err))
        return false
    end

    self.loadFailed = false
    self.futureSchema = false
    self.writeFenceReason = nil
    value = type(value) == "table" and value or nil
    self.loadedSchema = value and (tonumber(value.version) or 0) or 0
    local currentSchema = tonumber(S.Constants and S.Constants.SaveSchemaVersion) or 20
    if self.loadedSchema > currentSchema then
        -- Forward-compatibility fence: an older Suite may safely project known
        -- fields from a newer payload, but it must never rewrite that payload
        -- with an older schema and silently discard fields it does not know.
        self.futureSchema = true
        self.writeFenceReason = "future_schema:" .. tostring(self.loadedSchema) .. ">" .. tostring(currentSchema)
        self.lastError = self.writeFenceReason
        S.SafeChat("检测到更高版本配置 Schema " .. tostring(self.loadedSchema)
            .. "，本次会话进入只读保护，避免旧版本覆盖新字段。")
    else
        self.lastError = nil
    end
    local repairedSchema19 = false
    if value ~= nil then value, repairedSchema19 = RepairSchema19FalseBooleans(value, self.loadedSchema) end

    -- Schema 20 -> 21 migration: module enabled state, team/damage-review
    -- feature toggles and dailyCounters (今日收益) move from Character Override
    -- to the Account base. Fold saved overrides into the Account baseline so a
    -- previously enabled professional module and the current day's counters
    -- survive the first login after upgrade even when world-qualified identity
    -- is cold or drifted.
    local migratedSchema20 = false
    if value ~= nil and type(value.characterOverrides) == "table" and self.loadedSchema < 21 then
        local migratedModules = type(value.modules) == "table" and value.modules or {}
        local migratedSettings = type(value.settings) == "table" and value.settings or {}
        local settingKeys = {
            "teamAutoRoleEnabled", "teamRoleMode", "sacMarkerEnabled",
            "damageReviewEnabled", "damageReviewAutoShow", "damageReviewWindowMs",
            "damageReviewMaxHistory", "damageReviewMinDamage", "damageReviewShowDebuffs",
        }
        local migratedCounters = type(value.dailyCounters) == "table" and value.dailyCounters or nil
        for _, override in pairs(value.characterOverrides) do
            if type(override) == "table" then
                local ovModules = type(override.modules) == "table" and override.modules or {}
                for id, moduleState in pairs(ovModules) do
                    if type(moduleState) == "table" and moduleState.enabled == true then
                        local target = migratedModules[tostring(id)]
                        if type(target) ~= "table" then target = {}; migratedModules[tostring(id)] = target end
                        if target.enabled ~= true then target.enabled = true; migratedSchema20 = true end
                    end
                end
                local ovSettings = type(override.settings) == "table" and override.settings or {}
                for _, key in ipairs(settingKeys) do
                    if ovSettings[key] ~= nil then
                        migratedSettings[key] = DeepCopy(ovSettings[key])
                        migratedSchema20 = true
                    end
                end
                -- Fold the most recent day's counters into the Account base.
                -- Cross-day data is meaningless (the resource service resets on
                -- dateKey mismatch), so only a same-day payload is preserved.
                local ovCounters = type(override.dailyCounters) == "table" and override.dailyCounters or nil
                if type(ovCounters) == "table" and type(ovCounters.dateKey) == "string" then
                    if migratedCounters == nil or ovCounters.dateKey > tostring(migratedCounters.dateKey or "") then
                        migratedCounters = DeepCopy(ovCounters)
                        migratedSchema20 = true
                    end
                end
            end
        end
        if migratedSchema20 then
            value.modules = migratedModules
            value.settings = migratedSettings
            if type(migratedCounters) == "table" then value.dailyCounters = migratedCounters end
        end
    end
    -- Restore daily counters from the dedicated tiny save key FIRST: the RU
    -- client serializer can drop dailyCounters from the large main payload
    -- (trailing field), which made every reload look like a fresh install.
    -- The main-payload copy remains a backward-compatible fallback for
    -- pre-2026-08-24 saves and is migrated to the dedicated key below.
    local dailyLoaded = false
    if S.Api ~= nil and type(S.Api.LoadData) == "function" and type(S.Api.SaveData) == "function" then
        local dailyValue, dailyErr = S.Api:LoadData(DailyCountersKey())
        if dailyErr == nil and type(dailyValue) == "table" and type(dailyValue.dailyCounters) == "table" then
            if type(value) ~= "table" then value = {} end
            value.dailyCounters = dailyValue.dailyCounters
            dailyLoaded = true
        end
    end
    S.State:ApplySaved(value)

    -- One-time migration: a pre-dedicated-key save that still carries
    -- dailyCounters in the main payload gets copied to the dedicated key so it
    -- can no longer be lost by a later serializer truncation.
    if dailyLoaded ~= true and type(value) == "table" and type(value.dailyCounters) == "table"
        and S.Api ~= nil and type(S.Api.SaveData) == "function" then
        local migratedOk = pcall(function()
            S.Api:SaveData(DailyCountersKey(), { dailyCounters = value.dailyCounters })
        end)
        if migratedOk == true then dailyLoaded = true end
    end
    -- Persist the dedicated key on this generation's first save if it still
    -- has no dedicated copy (for example the migration write was fenced).
    self._dailyNeedsSeed = dailyLoaded ~= true

    local moduleSet = self:GetCharacterScopedModuleSet()
    -- Capture the validated Account base BEFORE applying the current character.
    -- This prevents a character-specific edit from leaking back into the base
    -- on the next SaveNow().
    self.accountCharacterBase = S.State:BuildCharacterOverride(moduleSet)
    self.characterOverrides = value and type(value.characterOverrides) == "table"
        and DeepCopy(value.characterOverrides) or {}
    self.lastCharacterKey = value and NonEmptyText(value.lastCharacterKey) or nil
    self.characterKey = self:ResolveCharacterKey()

    if self.characterKey ~= nil then
        local override = self.characterOverrides[self.characterKey]
        if type(override) == "table" then
            S.State:ApplyCharacterOverride(override, moduleSet)
        end
        self.lastCharacterKey = self.characterKey
        self.characterScopeDeferred = false
        self.deferredCharacterSnapshot = nil
        -- Schema <20 requires normalization into the current Account/base + explicit-boolean format. Preserve that behavior
        -- as the base and materialize the current character on the next bounded
        -- storage tick. No old professional Domain key is touched.
        -- Schema 20 -> 21 migration (migratedSchema20) also rewrites immediately
        -- so the folded Account baseline is persisted in the new format.
        if migratedSchema20 or self.loadedSchema < (tonumber(S.Constants and S.Constants.SaveSchemaVersion) or 20) then
            self.dirty = true
            self.dueAt = S.NowMs() + 750
        end
    else
        -- World-qualified identity is still cold (RU clients can keep
        -- UnitNameWithWorld frozen for a while, sometimes for the whole addon
        -- generation).  Booting purely from the Account base made every
        -- character-scoped module (gear/dps/healer toggle, per-character daily
        -- data) appear reset at login until identity resolved -- and when it
        -- never resolved, the override that held the real intent was unreachable
        -- for the whole session.  Tentatively apply the LAST used character's
        -- override so the module lifecycle starts from the user's actual state.
        -- When real identity arrives, RefreshCharacterScope/MergeColdEdits and
        -- ReconcileCharacterScopedModules still correct any difference.
        local tentativeKey = NonEmptyText(self.lastCharacterKey)
        local tentative = tentativeKey ~= nil and self.characterOverrides[tentativeKey] or nil
        if type(tentative) == "table" then
            S.State:ApplyCharacterOverride(tentative, moduleSet)
        end
        -- Keep the exact cold-start view so a later world-qualified identity can
        -- distinguish existing persisted override data from user edits made while
        -- identity was unavailable. Without this fence a Schema-20 override could
        -- be overwritten by the Account base on the first later save.
        self.characterScopeDeferred = true
        self.deferredCharacterSnapshot = S.State:BuildCharacterOverride(moduleSet)
        if migratedSchema20 or self.loadedSchema < (tonumber(S.Constants and S.Constants.SaveSchemaVersion) or 20) or repairedSchema19 then
            self.dirty = true
            self.dueAt = S.NowMs() + 750
        end
    end
    return true
end

-- Lightweight daily-counter recovery (2026-08-24 reload fix).  A UI reload
-- rebuilds State from defaults, and if Storage:Load() ran before the counters
-- were restored (or the load failed transiently), dailyCounters can sit at
-- {dateKey="unknown"} while the disk still holds the real day's earnings.
-- EnsureDate must never zero that state; this method re-reads ONLY the
-- dailyCounters block from the persisted payload (no State-wide side effects)
-- so the day's counters can be recovered in place.
--
-- Returns a tri-state verdict so the caller can tell "recovered" from
-- "definitively no saved counters" from "could not read the disk":
--   true   -- counters restored into State from a payload that had them
--   "empty" -- a payload WAS read but carries no counters anywhere
--             (first run / pre-Schema-21 save with nothing to fold)
--   false  -- could not read the payload (error, nil/false return, or the
--             addon storage is still re-mounting right after a UI reload).
--             The caller MUST NOT reset and MUST NOT write zeros.
function Storage:RestoreDailyCounters()
    -- loadFailed must NOT gate this reader: it only records that the FIRST
    -- Load() call failed (e.g. transient API unavailability during a UI
    -- refresh). A later read can succeed and recover the saved counters.
    if self.factoryResetPending == true then return false end
    if S.Api == nil or type(S.Api.LoadData) ~= "function" then return false end
    local saved = nil
    local fromDailyKey = false
    -- Prefer the dedicated daily save key (2026-08-24): the main payload's
    -- trailing dailyCounters can be dropped by the RU serializer, so a reload
    -- must never trust "no counters" until BOTH locations were checked.
    local daily, dailyErr = S.Api:LoadData(DailyCountersKey())
    if dailyErr == nil and type(daily) == "table" and type(daily.dailyCounters) == "table" then
        saved = daily.dailyCounters
        fromDailyKey = true
    else
        local value, err = S.Api:LoadData(S.SaveKey)
        if err ~= nil then return false end
        -- A nil/false payload means the storage returned "nothing". During a UI
        -- reload the addon storage may not be re-mounted yet, so this is NOT
        -- proof of a fresh install -- only a successfully read table can be
        -- judged.
        if type(value) ~= "table" then return false end
        saved = type(value.dailyCounters) == "table" and value.dailyCounters or nil
        if saved == nil and type(value.characterOverrides) == "table" then
            -- Schema 20-era payload: dailyCounters lived in the Character
            -- Override and the Storage:Load() migration may not have run yet
            -- (this reader must not depend on it). Fold the most recent day the
            -- same way.
            for _, override in pairs(value.characterOverrides) do
                local ov = type(override) == "table" and override.dailyCounters or nil
                if type(ov) == "table" and type(ov.dateKey) == "string" then
                    if saved == nil or tostring(ov.dateKey) > tostring(saved.dateKey or "") then
                        saved = ov
                    end
                end
            end
        end
    end
    if saved == nil then return "empty" end
    -- Recovered from the main payload (pre-dedicated-key save): migrate the
    -- counters to the dedicated key so a later serializer truncation of the
    -- main payload can never lose them again.
    if fromDailyKey ~= true and S.Api ~= nil and type(S.Api.SaveData) == "function" then
        pcall(function() S.Api:SaveData(DailyCountersKey(), { dailyCounters = saved }) end)
    end
    local counters = S.State and S.State.dailyCounters
    if type(counters) ~= "table" then return false end
    counters.dateKey = tostring(saved.dateKey or "unknown")
    for _, k in ipairs({ "gold", "honor", "vocation", "exp" }) do
        counters[k] = tonumber(saved[k]) or 0
    end
    return true
end

function Storage:RequestSave(delayMs)
    -- After a destructive factory reset succeeds, the old in-memory generation
    -- must never be allowed to repopulate the just-cleared storage while UI
    -- reload is in progress (or if that reload fails). The fresh generation
    -- recreates Storage with this fence cleared.
    if self.factoryResetPending == true then return end
    self.dirty = true
    self.dueAt = S.NowMs() + math.max(0, tonumber(delayMs) or 250)
end

-- Immediate write of the dedicated daily-counter save key (2026-08-24). Used
-- by the first-run/empty path so the very first initialization is on disk at
-- once instead of waiting for the next storage tick -- otherwise a reload
-- right after the first init would look like a fresh install again. This key
-- is Suite-owned and never written when a factory reset is pending.
function Storage:PersistDailyCounters(counters)
    if self.factoryResetPending == true then return false end
    if S.Api == nil or type(S.Api.SaveData) ~= "function" or type(counters) ~= "table" then return false end
    local ok = pcall(function() S.Api:SaveData(DailyCountersKey(), { dailyCounters = counters }) end)
    return ok == true
end

function Storage:BuildScopedPayload()
    if self.characterKey == nil then self:TryResolveDeferredCharacterScope() end
    local moduleSet = self:GetCharacterScopedModuleSet()
    -- State returns a detached save snapshot. Keep the effective Character view
    -- separate because Account-base restoration is applied only to the payload.
    local effectiveCharacter = S.State:BuildCharacterOverride(moduleSet)
    local payload = S.State:BuildSavePayload()
    payload.version = S.Constants.SaveSchemaVersion
    -- Remember which character's override was last materialized so a cold next
    -- boot can tentatively restore it (see Storage:Load).  Never let an
    -- unresolved identity erase the previous pointer.
    payload.lastCharacterKey = NonEmptyText(self.characterKey) or NonEmptyText(self.lastCharacterKey) or nil

    local overrides = DeepCopy(self.characterOverrides or {})
    if self.characterKey ~= nil then
        -- Identity is authoritative: keep the persisted Account base clean and
        -- write the current effective character view into its world-qualified
        -- override.
        RestoreAccountCharacterBase(payload, self.accountCharacterBase or {}, moduleSet)
        overrides[self.characterKey] = effectiveCharacter
        self.characterScopeDeferred = false
    else
        -- Character identity can be temporarily cold during login/reload. Never
        -- discard a user's just-edited character-scoped values merely to keep
        -- the base pure. Preserve the legacy effective snapshot for this save;
        -- a later save with UnitNameWithWorld available will normalize it back
        -- into Account base + Character Override.
        self.characterScopeDeferred = true
    end
    payload.characterOverrides = overrides
    return payload
end

function Storage:SaveNow()
    if self.factoryResetPending == true then
        self.dirty = false
        self.dueAt = 0
        return false
    end
    if self.loadFailed == true or self.futureSchema == true then
        if self.loadFailed == true then
            self.lastError = self.lastError or "storage load failed; write fenced"
            S.WarnOnce("storage_write_fenced", "配置读取失败，本次会话已阻止 SaveData 以保护原存档。")
        else
            self.lastError = self.writeFenceReason or self.lastError or "future schema; write fenced"
            S.WarnOnce("storage_future_schema_fenced", "配置来自更高版本，本次会话不会覆盖该存档。")
        end
        -- A write fence cannot heal by retrying SaveData. Consume the current
        -- dirty request instead of waking the storage task every 30 seconds; a
        -- later user edit may request another save and will be rejected once
        -- again without touching disk. Runtime edits remain usable this session.
        self.dirty = false
        self.dueAt = 0
        return false
    end
    local payload = self:BuildScopedPayload()
    local ok, err = S.Api:SaveData(S.SaveKey, payload)
    if not ok then
        self.lastError = err
        self.failureCount = (tonumber(self.failureCount) or 0) + 1
        -- Do not retry every storage tick. A temporary SaveData failure should
        -- not turn into chat spam or a hot loop.
        local backoff = math.min(30000, 2000 * self.failureCount)
        self.dueAt = S.NowMs() + backoff
        S.WarnOnce("storage_save_" .. tostring(err), "保存配置失败，将自动重试：" .. tostring(err))
        return false
    end
    -- Dedicated daily-counter save (2026-08-24): a tiny payload that the main
    -- serializer cannot truncate. Failure here is non-fatal -- the main payload
    -- copy still carries the values this session and the next save retries.
    if type(payload.dailyCounters) == "table" and S.Api ~= nil and type(S.Api.SaveData) == "function" then
        local dailyOk = pcall(function()
            S.Api:SaveData(DailyCountersKey(), { dailyCounters = payload.dailyCounters })
        end)
        if dailyOk == true then self._dailyNeedsSeed = false end
    end
    self.characterOverrides = DeepCopy(payload.characterOverrides or {})
    self.loadedSchema = tonumber(payload.version) or self.loadedSchema
    self.dirty = false
    self.lastError = nil
    self.failureCount = 0
    return true
end

------------------------------------------------------------------------
-- Destructive factory reset
--
-- This is intentionally broader than the normal "restore layout" action. The
-- user uses it to reproduce a true first-install/new-user state, so every
-- persistence Authority owned by Replicated Suite and the embedded professional
-- modules for the current player identity must be cleared before code reload.
-- Orphan shard/payload keys are cleared as well where their key space is fixed
-- or can be bounded from the saved root metadata.
------------------------------------------------------------------------
local function AddResetKey(list, seen, key)
    key = NonEmptyText(key)
    if key == nil or seen[key] == true then return end
    seen[key] = true
    list[#list + 1] = key
end

local function ConsiderGearRootForReset(root, state)
    if type(root) ~= "table" then return end
    local nextId = math.max(1, math.floor(tonumber(root.nextStorageId) or 1))
    state.maxStorageId = math.max(state.maxStorageId or 0, nextId - 1)
    for _, character in pairs(type(root.characters) == "table" and root.characters or {}) do
        for _, set in ipairs(type(character) == "table" and type(character.sets) == "table" and character.sets or {}) do
            local storageId = math.floor(tonumber(type(set) == "table" and set.storageId or nil) or 0)
            if storageId > 0 then state.maxStorageId = math.max(state.maxStorageId or 0, storageId) end
        end
    end
end

function Storage:BuildFactoryResetKeys()
    local keys, seen = {}, {}

    -- Suite account/character state, the dedicated daily-counter save and the
    -- fishing hotkey recovery lane.
    AddResetKey(keys, seen, S.SaveKey)
    AddResetKey(keys, seen, DailyCountersKey())
    AddResetKey(keys, seen, tostring(S.SaveKey or "replicated_suite_v1") .. "_fishing_hotkey_recovery")

    -- Replicated Healer keeps primary + backup plus one legacy migration key.
    local healerConfig = rawget(_G, "ReplicatedHealerConfig")
    local healerKey = type(healerConfig) == "table" and healerConfig.SaveKey or "replicated_healer_recommender_v2"
    local healerLegacy = type(healerConfig) == "table" and healerConfig.LegacySaveKey or "replicated_healer_recommender_v1"
    AddResetKey(keys, seen, healerKey)
    AddResetKey(keys, seen, tostring(healerKey) .. "_backup")
    AddResetKey(keys, seen, healerLegacy)

    -- Gear root + backup and every allocated per-set payload. nextStorageId is
    -- monotonic, so clearing 1..nextStorageId-1 also removes payloads belonging
    -- to sets that the user deleted earlier and that no longer appear in root.
    local gearConfig = rawget(_G, "ReplicatedGearConfig")
    local gearKey = type(gearConfig) == "table" and gearConfig.SaveKey or "replicated_gear_v1"
    local gearState = { maxStorageId = 0 }
    local gear = rawget(_G, "ReplicatedGear")
    if type(gear) == "table" and type(gear.Core) == "table" then
        ConsiderGearRootForReset(gear.Core.root, gearState)
    end
    for _, rootKey in ipairs({gearKey, tostring(gearKey) .. "_backup"}) do
        local saved, loadErr = S.Api:LoadData(rootKey)
        if loadErr ~= nil then
            return nil, "读取换装存档失败，无法确认全部 payload：" .. tostring(loadErr)
        end
        ConsiderGearRootForReset(saved, gearState)
    end
    if gearState.maxStorageId > 4096 then
        return nil, "换装存档 payload 编号异常（>4096），为避免一次性执行过多 ClearData 已停止出厂重置。"
    end
    AddResetKey(keys, seen, gearKey)
    AddResetKey(keys, seen, tostring(gearKey) .. "_backup")
    for storageId = 1, gearState.maxStorageId do
        local payload = tostring(gearKey) .. "_payload_" .. tostring(storageId)
        AddResetKey(keys, seen, payload)
        AddResetKey(keys, seen, payload .. "_backup")
    end

    -- Plates uses a fixed sharded tracking space. Clear current and legacy
    -- non-partitioned shard names across every bank so a later migration cannot
    -- resurrect old tracked Buff/Debuff/Hidden rows after the reset.
    local plates = rawget(_G, "ReplicatedPlates")
    local platesKey = type(plates) == "table" and plates.SaveKey or "replicated_plates_v1"
    local platesBackup = type(plates) == "table" and plates.BackupSaveKey or (tostring(platesKey) .. "_backup")
    AddResetKey(keys, seen, platesKey)
    AddResetKey(keys, seen, platesBackup)
    AddResetKey(keys, seen, tostring(platesKey) .. "_tracking_manifest")
    for _, bank in ipairs({"a", "b", "c"}) do
        for _, scope in ipairs({"target", "player"}) do
            for _, effectType in ipairs({"buff", "debuff", "hidden"}) do
                local prefix = tostring(platesKey) .. "_tracking_" .. bank .. "_" .. scope .. "_" .. effectType
                AddResetKey(keys, seen, prefix) -- V1 legacy shard.
                for part = 1, 16 do AddResetKey(keys, seen, prefix .. "_p" .. tostring(part)) end
            end
        end
    end

    -- DPS persistence is identity-scoped. Use its own Key() Authority so the
    -- hash/suffix stays exactly aligned with the running module. Clearing the
    -- rotating stats, transactional config/rules/ui, legacy DPS death-review, clear
    -- snapshots and all 16x3 shard banks reproduces a genuinely empty install.
    local dps = rawget(_G, "ReplicatedDps")
    local persistence = type(dps) == "table" and dps.Persistence or nil
    if type(persistence) == "table" and type(persistence.Key) == "function" then
        for _, name in ipairs({"config", "ui", "rules", "death_review_history", "snapshot", "stats", "stats_head"}) do
            for _, slot in ipairs({"primary", "pending", "backup"}) do
                AddResetKey(keys, seen, persistence.Key(name, slot))
            end
        end
        AddResetKey(keys, seen, persistence.Key("stats_shard_switch", "primary"))
        for _, bank in ipairs({"a", "b", "c"}) do
            AddResetKey(keys, seen, persistence.Key("stats_shard_manifest", bank))
            for shardId = 0, 15 do
                AddResetKey(keys, seen, persistence.Key(string.format("stats_shard_%02d", shardId), bank))
            end
        end
    else
        return nil, "DPS 持久化身份 Authority 不可用；已取消出厂重置，避免只清一半配置。"
    end

    return keys, nil
end

function Storage:ResetAllPersistedData()
    if S.Api == nil or type(S.Api.ClearData) ~= "function" or type(S.Api.LoadData) ~= "function" then
        return false, { error = "ClearData/LoadData 不可用" }
    end
    if type(S.Api.IsCapabilityAllowed) == "function" then
        local allowed, reason = S.Api:IsCapabilityAllowed("ADDON:ClearData")
        if allowed ~= true then
            return false, { error = "ADDON:ClearData 当前不可用：" .. tostring(reason or "blocked") }
        end
    end
    local keys, buildErr = self:BuildFactoryResetKeys()
    if type(keys) ~= "table" then return false, { error = tostring(buildErr or "无法建立重置键列表") } end

    -- Fishing temporarily rewrites the user's R binding and keeps an emergency
    -- recovery snapshot outside the Suite root. Restore the real keyboard state
    -- before deleting that snapshot; otherwise a factory reset performed while
    -- auto-fishing is armed could erase the only recovery Authority first.
    local fishing = S.Services and S.Services.Fishing or nil
    if fishing ~= nil and type(fishing.DisarmAuto) == "function" then
        local restored, restoreErr = fishing:DisarmAuto(true)
        if restored == false then
            return false, { error = "钓鱼快捷键恢复失败，已取消全部重置：" .. tostring(restoreErr or "unknown") }
        end
    end

    local failures = {}
    local cleared = 0
    for _, key in ipairs(keys) do
        local ok, clearErr = S.Api:ClearData(key)
        if ok ~= true then
            -- RU builds may report false for an already-empty key. Verify the
            -- observable storage state before classifying it as a real failure.
            local remaining, loadErr = S.Api:LoadData(key)
            if loadErr == nil and (remaining == nil or remaining == false) then
                ok = true
            else
                failures[#failures + 1] = tostring(key) .. ": " .. tostring(clearErr or loadErr or "ClearData failed")
            end
        end
        if ok == true then cleared = cleared + 1 end
    end

    if #failures > 0 then
        -- Do not pretend the user is on a clean baseline when any Authority key
        -- could still restore old data. Keep the current generation alive so the
        -- failure can be inspected/retried instead of immediately reloading.
        return false, { total = #keys, cleared = cleared, failures = failures, error = failures[1] }
    end

    -- Prevent ReloadCodeFromDisk() and the Suite shutdown path from writing the
    -- old in-memory Suite snapshot back over the just-cleared root key.
    self.dirty = false
    self.dueAt = 0
    self.failureCount = 0
    self.lastError = nil
    self.characterOverrides = {}
    self.accountCharacterBase = nil
    self.deferredCharacterSnapshot = nil
    self.factoryResetPending = true

    -- UI reload keeps Lua globals alive on some RU clients. This one-shot marker
    -- tells professional modules with memory-backed fallbacks (notably DPS) to
    -- discard their previous generation before loading defaults from empty disk.
    rawset(_G, "ReplicatedSuiteFactoryResetPending", true)

    -- Professional runtimes are about to be replaced by UI reload. Suppress only
    -- their pending in-memory dirty markers; their fresh generation will rebuild
    -- defaults from the now-empty storage Authorities.
    local plates = rawget(_G, "ReplicatedPlates")
    if type(plates) == "table" and type(plates.Storage) == "table" then
        plates.Storage.dirty = false
        plates.Storage.trackingDirty = false
    end
    local dps = rawget(_G, "ReplicatedDps")
    if type(dps) == "table" and type(dps.Persistence) == "table" then
        dps.Persistence.lastBackupAt = {}
    end

    -- Clearing and UI reload are separate native operations on RU. Quiesce the
    -- old generation immediately after the last successful ClearData so no
    -- scheduler/event/professional OnUpdate gets a frame in which it can write
    -- the just-cleared in-memory settings back to disk. Keep the current UI
    -- alive only long enough for the button callback to invoke code reload.
    if S.ModuleManager ~= nil and type(S.ModuleManager.Shutdown) == "function" then
        pcall(function() S.ModuleManager:Shutdown() end)
    end
    if S.Events ~= nil and type(S.Events.Stop) == "function" then pcall(function() S.Events:Stop() end) end
    if S.Scheduler ~= nil and type(S.Scheduler.Stop) == "function" then pcall(function() S.Scheduler:Stop() end) end

    return true, { total = #keys, cleared = cleared }
end

function Storage:Tick()
    if self.dirty ~= true then return end
    if S.NowMs() < (tonumber(self.dueAt) or 0) then return end
    self:SaveNow()
end
