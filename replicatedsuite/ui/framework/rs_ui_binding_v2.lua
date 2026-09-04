------------------------------------------------------------------------
-- Replicated Suite - UI Binding v2
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI = S.UI
if type(UI) ~= "table" then return end

local Binding = {
    version = 2.4,
    metrics = { created = 0, reads = 0, writes = 0, skipped = 0, rejected = 0, commits = 0, errors = 0, persistentCreated = 0, persistenceMarks = 0, persistenceFailures = 0, persistenceAutoLoads = 0, persistenceLoadFailures = 0 },
    activeBindings = setmetatable({}, { __mode = "k" }),
}
UI.Binding = Binding

local function Report(code, message, context)
    local D = S.Diagnostics
    if D ~= nil and type(D.Record) == "function" then
        pcall(function() D:Record("warn", "ui", tostring(message or code), tostring(code), context) end)
        return
    end
    if type(S.WarnOnce) == "function" then S.WarnOnce("ui_binding:" .. tostring(code), tostring(message or code)) end
end

local function Notify(binding, callbackName, ...)
    local fn = binding.options and binding.options[callbackName]
    if type(fn) ~= "function" then return end
    local count = select("#", ...)
    local args = { ... }
    args[count + 1] = binding
    local ok, err = xpcall(function() fn(unpack(args, 1, count + 1)) end, S.SafeTraceback)
    if not ok then Report("BIND_CALLBACK_FAILED", err, { id = binding.options and binding.options.id, callback = callbackName }) end
end

function Binding:Create(options)
    options = type(options) == "table" and options or {}
    self.metrics.created = self.metrics.created + 1
    local binding = {
        options = options,
        lastError = nil,
        dirty = false,
        revision = 0,
        lastSource = "init",
    }

    function binding:SetError(reason, source)
        local text = reason ~= nil and tostring(reason) or nil
        if text == "" then text = nil end
        local changed = self.lastError ~= text
        self.lastError = text
        if text ~= nil and changed then Binding.metrics.errors = Binding.metrics.errors + 1 end
        if changed then Notify(self, "onErrorChanged", text, tostring(source or self.lastSource or "program")) end
        return text == nil
    end

    function binding:Get()
        Binding.metrics.reads = Binding.metrics.reads + 1
        if type(options.get) == "function" then
            local ok, value = xpcall(options.get, S.SafeTraceback)
            if ok then return value end
            self:SetError(value, "get")
            Report("BIND_GET_FAILED", value, { id = options.id })
            return options.value
        end
        return options.value
    end

    function binding:Normalize(value, previous, source)
        if type(options.normalize) ~= "function" then return value end
        local ok, normalized = xpcall(function() return options.normalize(value, previous, source, self) end, S.SafeTraceback)
        if ok then return normalized end
        self:SetError(normalized, source)
        Report("BIND_NORMALIZE_FAILED", normalized, { id = options.id })
        return previous
    end

    function binding:Validate(value, previous, source)
        if type(options.validate) ~= "function" then self:SetError(nil, source); return true end
        local ok, accepted, reason = xpcall(function() return options.validate(value, previous, source, self) end, S.SafeTraceback)
        if not ok then
            self:SetError(accepted, source)
            Report("BIND_VALIDATE_FAILED", accepted, { id = options.id })
            return false
        end
        if accepted == false then
            self:SetError(reason or "invalid", source)
            Notify(self, "onRejected", value, previous, source, self.lastError)
            return false
        end
        self:SetError(nil, source)
        return true
    end

    function binding:Equals(a, b)
        if type(options.equals) == "function" then
            local ok, same = pcall(options.equals, a, b)
            if ok then return same == true end
        end
        return a == b
    end

    function binding:Commit(source)
        source = tostring(source or "program")
        if type(options.commit) == "function" then
            local ok, accepted, reason = xpcall(function() return options.commit(source, self) end, S.SafeTraceback)
            if not ok then
                self:SetError(accepted, source)
                Report("BIND_COMMIT_FAILED", accepted, { id = options.id })
                return false
            end
            if accepted == false then
                self:SetError(reason or "commit rejected", source)
                return false
            end
        end
        Binding.metrics.commits = Binding.metrics.commits + 1
        self.dirty = false
        self:SetError(nil, source)
        Notify(self, "onCommitted", source)
        return true
    end

    function binding:Set(value, final, source, previous)
        source = tostring(source or "program")
        self.lastSource = source
        if previous == nil then previous = self:Get() end
        local nextValue = self:Normalize(value, previous, source)
        if not self:Validate(nextValue, previous, source) then
            Binding.metrics.rejected = Binding.metrics.rejected + 1
            return false
        end
        if self:Equals(nextValue, previous) then
            Binding.metrics.skipped = Binding.metrics.skipped + 1
            if final == true and options.commitOnUnchanged == true then return self:Commit(source) end
            return true
        end
        if type(options.set) == "function" then
            local ok, accepted, reason = xpcall(function() return options.set(nextValue, final == true, source, previous, self) end, S.SafeTraceback)
            if not ok then
                self:SetError(accepted, source)
                Report("BIND_SET_FAILED", accepted, { id = options.id })
                return false
            end
            if accepted == false then
                Binding.metrics.rejected = Binding.metrics.rejected + 1
                self:SetError(reason or "setting rejected", source)
                Notify(self, "onRejected", nextValue, previous, source, self.lastError)
                return false
            end
        else
            options.value = nextValue
        end
        Binding.metrics.writes = Binding.metrics.writes + 1
        self.revision = self.revision + 1
        self.dirty = true
        self:SetError(nil, source)
        if type(options.markDirty) == "function" then
            pcall(options.markDirty, nextValue, previous, source, self)
        end
        Notify(self, "onChanged", nextValue, previous, source)
        if final == true and options.autoCommit == true then return self:Commit(source) end
        return true
    end

    function binding:Refresh(source)
        source = tostring(source or "refresh")
        local value = self:Get()
        Notify(self, "onRefreshed", value, source)
        return value
    end

    function binding:GetError() return self.lastError end
    function binding:IsDirty() return self.dirty == true end
    function binding:GetRevision() return tonumber(self.revision) or 0 end
    function binding:ResetDirty() self.dirty = false; return true end
    function binding:Describe()
        return {
            id = tostring(options.id or ""),
            dirty = self.dirty == true,
            error = self.lastError,
            revision = tonumber(self.revision) or 0,
            source = tostring(self.lastSource or ""),
        }
    end
    Binding.activeBindings[binding] = true
    return binding
end



-- Persistence-aware setting binding. The Domain setter still owns the in-memory
-- value; this adapter owns the store dirty/commit contract so NumericField,
-- ToggleField and future settings do not each repeat MarkDirty/SaveStore glue.
-- MarkDirty uses the Persistence delayed/coalesced save lane; no field owns its own scheduler.
function UI:CreatePersistentSettingBinding(options)
    options = type(options) == "table" and options or {}
    local storeId = tostring(options.storeId or options.persistenceStore or "")
    if storeId == "" then return nil, "persistent binding storeId required" end
    local P = S.Persistence
    if type(P) ~= "table" or type(P.GetStore) ~= "function" or P:GetStore(storeId) == nil then
        return nil, "persistent binding store unavailable: " .. storeId
    end
    local baseOptions = {}
    for key, value in pairs(options) do baseOptions[key] = value end
    baseOptions.storeId, baseOptions.persistenceStore = nil, nil
    local domainSet = baseOptions.set
    baseOptions.set = nil
    local binding = Binding:Create(baseOptions)
    if binding == nil then return nil, "binding create failed" end
    Binding.metrics.persistentCreated = (tonumber(Binding.metrics.persistentCreated) or 0) + 1
    binding.storeId = storeId
    binding.persistDelayMs = math.max(0, tonumber(options.persistDelayMs or options.delayMs) or 350)
    binding.persistReason = tostring(options.persistReason or options.id or "setting_changed")
    binding.domainSet = domainSet
    local BaseSet = binding.Set
    local BaseIsDirty = binding.IsDirty
    local BaseCommit = binding.Commit

    function binding:Set(value, final, source, previous)
        source = tostring(source or "persistent_setting")
        local store = P:GetStore(self.storeId)
        if store == nil then
            Binding.metrics.persistenceFailures = (tonumber(Binding.metrics.persistenceFailures) or 0) + 1
            self:SetError("persistent store unavailable", source)
            return false
        end
        -- Load-before-write is a hard persistence invariant. Settings pages can
        -- remain available while their Feature runtime is disabled, so the UI
        -- binding must make sure the permanent Store has been applied BEFORE it
        -- mutates Domain memory. This closes the old "edit defaults, then erase
        -- the user's saved config" failure mode.
        if store.loaded ~= true then
            local prepared, prepareErr = false, "PrepareWrite unavailable"
            if type(P.PrepareWrite) == "function" then prepared, prepareErr = P:PrepareWrite(self.storeId) end
            if prepared ~= true then
                Binding.metrics.persistenceFailures = (tonumber(Binding.metrics.persistenceFailures) or 0) + 1
                Binding.metrics.persistenceLoadFailures = (tonumber(Binding.metrics.persistenceLoadFailures) or 0) + 1
                self:SetError(prepareErr or "store load failed", source)
                return false
            end
            Binding.metrics.persistenceAutoLoads = (tonumber(Binding.metrics.persistenceAutoLoads) or 0) + 1
            store = P:GetStore(self.storeId)
            -- Any previous value captured by a control before the Store load is
            -- stale by definition; re-read the now-authoritative Domain value.
            previous = nil
        end
        -- Persistence is the write authority. Refuse the Domain mutation before
        -- touching in-memory state when the store is fenced.
        if store.writeFenced == true then
            Binding.metrics.persistenceFailures = (tonumber(Binding.metrics.persistenceFailures) or 0) + 1
            self:SetError(store.writeFenceReason or "write fenced", source)
            return false
        end
        if previous == nil then previous = self:Get() end
        local beforeRevision = self:GetRevision()
        local oldSetter = self.options.set
        self.options.set = self.domainSet
        local ok = BaseSet(self, value, false, source, previous)
        self.options.set = oldSetter
        if ok ~= true then return false end
        if self:GetRevision() == beforeRevision then
            if final == true and options.commitOnUnchanged == true then return self:Commit(source) end
            return true
        end
        local marked, markErr = P:MarkDirty(self.storeId, self.persistDelayMs, self.persistReason .. ":" .. source)
        if marked ~= true then
            Binding.metrics.persistenceFailures = (tonumber(Binding.metrics.persistenceFailures) or 0) + 1
            -- Best-effort transactional recovery: put the Domain value back and
            -- restore the binding revision/dirty projection to the effective
            -- value.  The Persistence Store remains the final dirty authority.
            local rollbackOk, rollbackErr = true, nil
            if type(self.domainSet) == "function" then rollbackOk, rollbackErr = pcall(self.domainSet, previous, true, "persistence_rollback", value, self) end
            self.revision = beforeRevision
            self:ResetDirty()
            if rollbackOk ~= true then
                Report("BIND_PERSIST_ROLLBACK_FAILED", rollbackErr, { id = options.id, store = self.storeId })
            end
            self:SetError(markErr or "mark dirty failed", source)
            return false
        end
        Binding.metrics.persistenceMarks = (tonumber(Binding.metrics.persistenceMarks) or 0) + 1
        -- Persistent dirty truth lives in Persistence Store; avoid a second stale
        -- dirty flag that would stay true after the debounce save completes.
        self:ResetDirty()
        if final == true and options.autoCommit == true then return self:Commit(source) end
        return true
    end

    function binding:IsDirty()
        local store = P:GetStore(self.storeId)
        if store ~= nil then return store.dirty == true end
        return BaseIsDirty(self)
    end

    function binding:Commit(source)
        local store = P:GetStore(self.storeId)
        if store == nil then self:SetError("persistent store unavailable", source); return false end
        if store.loaded ~= true then
            local prepared, prepareErr = false, "PrepareWrite unavailable"
            if type(P.PrepareWrite) == "function" then prepared, prepareErr = P:PrepareWrite(self.storeId) end
            if prepared ~= true then
                Binding.metrics.persistenceFailures = (tonumber(Binding.metrics.persistenceFailures) or 0) + 1
                Binding.metrics.persistenceLoadFailures = (tonumber(Binding.metrics.persistenceLoadFailures) or 0) + 1
                self:SetError(prepareErr or "store load failed", source)
                return false
            end
            Binding.metrics.persistenceAutoLoads = (tonumber(Binding.metrics.persistenceAutoLoads) or 0) + 1
            store = P:GetStore(self.storeId)
        end
        if store.dirty == true then
            local ok, err = P:SaveStore(self.storeId, { consumeDirty = true, reason = tostring(source or self.persistReason) })
            if ok ~= true then
                Binding.metrics.persistenceFailures = (tonumber(Binding.metrics.persistenceFailures) or 0) + 1
                self:SetError(err or "save failed", source)
                return false
            end
        end
        return BaseCommit(self, source)
    end

    function binding:GetPersistenceState()
        local store = P:GetStore(self.storeId)
        return {
            storeId = self.storeId, dirty = store ~= nil and store.dirty == true,
            writeFenced = store ~= nil and store.writeFenced == true,
            loaded = store ~= nil and store.loaded == true, loadStatus = store and store.loadStatus or nil,
            lastError = store and store.lastError or nil, dueAt = store and store.dueAt or nil,
        }
    end
    return binding
end

function Binding:GetSnapshot()
    local active, dirty, errored, persistentActive = 0, 0, 0, 0
    for binding in pairs(self.activeBindings or {}) do
        active = active + 1
        if type(binding) == "table" then
            if type(binding.IsDirty) == "function" and binding:IsDirty() == true then dirty = dirty + 1 end
            if type(binding.GetError) == "function" and binding:GetError() ~= nil then errored = errored + 1 end
            if binding.storeId ~= nil then persistentActive = persistentActive + 1 end
        end
    end
    return {
        version = self.version, active = active, dirty = dirty, errored = errored, persistentActive = persistentActive,
        created = self.metrics.created,
        reads = self.metrics.reads,
        writes = self.metrics.writes,
        skipped = self.metrics.skipped,
        rejected = self.metrics.rejected,
        commits = self.metrics.commits,
        errors = self.metrics.errors,
        persistentCreated = tonumber(self.metrics.persistentCreated) or 0,
        persistenceMarks = tonumber(self.metrics.persistenceMarks) or 0,
        persistenceFailures = tonumber(self.metrics.persistenceFailures) or 0,
        persistenceAutoLoads = tonumber(self.metrics.persistenceAutoLoads) or 0,
        persistenceLoadFailures = tonumber(self.metrics.persistenceLoadFailures) or 0,
    }
end

function Binding:ResetMetrics()
    self.metrics.created, self.metrics.reads, self.metrics.writes = 0, 0, 0
    self.metrics.skipped, self.metrics.rejected, self.metrics.commits, self.metrics.errors = 0, 0, 0, 0
    self.metrics.persistentCreated, self.metrics.persistenceMarks, self.metrics.persistenceFailures = 0, 0, 0
    self.metrics.persistenceAutoLoads, self.metrics.persistenceLoadFailures = 0, 0
end

function UI:CreateSettingBinding(options) return Binding:Create(options) end
