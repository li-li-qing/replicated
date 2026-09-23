------------------------------------------------------------------------
-- Replicated Suite V3 - Native nameplate visual CVar authority
--
-- 维护（2026-09-20，nameplate-mark-ratio-3）：
-- 原因：18.272 RU 实机已确认 name_tag_hp_* 能实时改变血条，但 over_head_marker_width /
-- over_head_marker_height / over_head_marker_offset 即使 SetConsoleVariable 成功也没有视觉效果。
-- console_vars.lua 同时提供 name_tag_mark_size_ratio（help: name tag mark scale），它与
-- X2Unit:SetOverHeadMarker 所产生的头顶队伍标记处于 NameTag 标记层，因此改为用该“比例”变量作为
-- 头顶标记大小的唯一 Native Authority；旧 over_head_marker_* 不再写入，避免继续制造无效设置。
--
-- Authority / 数据流：Presentation -> Feature.Commands -> 本 Authority -> Capability Registry -> X2Option。
-- 页面和 Feature 不直接访问 X2Option。无 Tick/轮询；仅 Enable、显式设置、ENTERED_WORLD、Disable 写入。
--
-- 兼容边界：v3.nameplate_visuals Store 不升 schema；历史 markerWidth/markerHeight/markerOffset
-- 字段继续原样保存，只把 markerWidth/46 解释为新的 marker scale（预设仍会同步写 width/height）。
-- 这样 18.270-18.272 用户不会因为 canonical shape 改动触发 Persistence 指纹保护。Native 基线仍按
-- “可读值 -> system.cfg -> 已知默认”解析，关闭恢复启用前值；失败事务继续回滚。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Features = S.Features or {}
S.Features.NameplateVisuals = S.Features.NameplateVisuals or {}
local F = S.Features.NameplateVisuals

local A = {
    version = 3,
    baseline = nil,
    baselineSources = nil,
    lastObserved = nil,
    lastEffective = nil,
    lastApplied = nil,
    lastApplyReason = nil,
    lastError = nil,
    revision = 0,
    readbackMode = "unknown",
    unreadableCvars = {},
    systemCfgPath = nil,
    metrics = {
        reads = 0, readMisses = 0, writes = 0, applies = 0, restores = 0,
        failures = 0, rollbacks = 0, verifiedWrites = 0, unverifiedWrites = 0,
        baselineNative = 0, baselineSystemCfg = 0, baselineDefault = 0,
    },
}
F.Authority = A

-- default 来自本项目 z_api_functions/console_vars.lua 的当前参考 dump。
-- 注意：dump 只证明客户端存在这些变量，不证明 Lua GetConsoleVariable 一定可读。

local function Emit(level, code, message, context)
    local d = S.DiagnosticsManager
    if type(d) == "table" and type(d.Emit) == "function" then
        context = type(context) == "table" and context or {}
        context.moduleId, context.featureId = F.Id or "combat_nameplate_visuals", F.Id or "combat_nameplate_visuals"
        d:Emit(level, "nameplate_visuals_v3", code, message, context)
    end
end

local function Clone(value)
    local out = {}
    for key, item in pairs(type(value) == "table" and value or {}) do out[key] = item end
    return out
end

local function ArrayClone(value)
    local out = {}
    for i, item in ipairs(type(value) == "table" and value or {}) do out[i] = item end
    return out
end

local function NativeNumber(value)
    local n = tonumber(value)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return nil end
    return n
end

local MARKER_BASE_WIDTH = 46
local SPECS = {
    -- 中文维护注释（nameplate-mark-ratio-3）：18.272 实机已证明 over_head_marker_width/height/offset
    -- 不是当前 RU 构建可实时控制的头顶队伍标记尺寸入口。name_tag_mark_size_ratio 的客户端 help
    -- 明确为 "name tag mark scale"，且 SetOverHeadMarker 属于 NameTag/OverHeadMark 渲染链，因此这里只
    -- 使用 ratio。resolve 同时兼容 Authority 自己的 markerScale 快照与 schema1 持久设置的 markerWidth。
    { key = "markerScale", cvar = "name_tag_mark_size_ratio", default = 1, resolve = function(settings)
        local direct = type(settings) == "table" and NativeNumber(settings.markerScale) or nil
        if direct ~= nil then return direct end
        local width = type(settings) == "table" and NativeNumber(settings.markerWidth) or nil
        if width == nil then width = MARKER_BASE_WIDTH end
        return width / MARKER_BASE_WIDTH
    end },
    { key = "markerFixedSize", cvar = "overhead_marker_fixed_size",          default = 1, boolean = true },
    { key = "hpWidth",         cvar = "name_tag_hp_width",                   default = 70 },
    { key = "hpHeight",        cvar = "name_tag_hp_height",                  default = 7 },
    { key = "bgHpWidth",       cvar = "name_tag_hp_width_on_bgmode",         default = 158 },
    { key = "bgHpHeight",      cvar = "name_tag_hp_height_on_bgmode",        default = 38 },
}
A.Specs = SPECS

local function SpecValue(spec, raw)
    local n = NativeNumber(raw)
    if n == nil then return nil end
    if spec.boolean then return n ~= 0 end
    return n
end

local function ExpectedValue(spec, settings)
    if type(spec.resolve) == "function" then return NativeNumber(spec.resolve(settings)) end
    local value = settings[spec.key]
    if spec.boolean then return value == true and 1 or 0 end
    return NativeNumber(value)
end

local function Equivalent(left, right)
    left, right = NativeNumber(left), NativeNumber(right)
    if left == nil or right == nil then return false end
    return math.abs(left - right) <= 0.01
end

local function JoinSources(sources)
    local counts = { native = 0, system_cfg = 0, default = 0 }
    for _, source in pairs(type(sources) == "table" and sources or {}) do
        if counts[source] ~= nil then counts[source] = counts[source] + 1 end
    end
    return "native=" .. tostring(counts.native)
        .. "/system_cfg=" .. tostring(counts.system_cfg)
        .. "/default=" .. tostring(counts.default)
end

function A:TryReadCVar(name)
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return nil, "API Boundary 不可用" end
    local ok, value, err = S.Api:CallCapability("X2Option:GetConsoleVariable", rawget(_G, "X2Option"), "GetConsoleVariable", name)
    self.metrics.reads = (tonumber(self.metrics.reads) or 0) + 1
    if ok ~= true then
        self.metrics.readMisses = (tonumber(self.metrics.readMisses) or 0) + 1
        return nil, tostring(err or "读取失败")
    end
    local n = NativeNumber(value)
    if n == nil then
        self.metrics.readMisses = (tonumber(self.metrics.readMisses) or 0) + 1
        return nil, tostring(name) .. " 返回非数值：" .. tostring(type(value))
    end
    return n, nil
end

-- 仅用于基线恢复，不修改文件。路径与公开 RU reloadcfg 使用的 ../Documents/system.cfg 一致，
-- 额外两个候选只是兼容不同工作目录；读取失败属于可接受降级，不会阻断 Feature。
function A:ReadSystemCfgSnapshot()
    if type(io) ~= "table" or type(io.open) ~= "function" then return {}, nil end
    local candidates = { "../Documents/system.cfg", "Documents/system.cfg", "system.cfg" }
    local wanted = {}
    for _, spec in ipairs(SPECS) do wanted[spec.cvar] = true end
    for _, path in ipairs(candidates) do
        local file = io.open(path, "r")
        if file ~= nil then
            local values = {}
            for line in file:lines() do
                if not tostring(line):match("^%s*%-%-") then
                    local name, raw = tostring(line):match("^%s*([%w_]+)%s*=%s*([^%s;#]+)")
                    if name ~= nil and wanted[name] == true then
                        local n = NativeNumber(raw)
                        if n ~= nil then values[name] = n end
                    end
                end
            end
            file:close()
            return values, path
        end
    end
    return {}, nil
end

function A:WriteCVar(name, value)
    if S.Api == nil or type(S.Api.ActionCapability) ~= "function" then return false, "API Boundary 不可用" end
    local n = NativeNumber(value)
    if n == nil then return false, tostring(name) .. " 写入值无效" end
    -- RU 社区 reloadcfg/highlight 均使用 SetConsoleVariable(name, tostring(value))。
    -- 对不可回读 CVar，Set 成功只能证明 Lua 调用未报错，不能伪称客户端已 readback 验证。
    local ok, err = S.Api:ActionCapability("X2Option:SetConsoleVariable", rawget(_G, "X2Option"), "SetConsoleVariable", name, tostring(n))
    self.metrics.writes = (tonumber(self.metrics.writes) or 0) + 1
    if ok ~= true then return false, tostring(err or "写入失败") end
    return true
end

local function UpdateReadbackState(self, unreadable)
    self.unreadableCvars = ArrayClone(unreadable)
    local count = #self.unreadableCvars
    if count == 0 then self.readbackMode = "strict"
    elseif count >= #SPECS then self.readbackMode = "write_only"
    else self.readbackMode = "partial" end
end

function A:CaptureBaseline()
    if self.baseline ~= nil then return true end
    local cfgValues, cfgPath = self:ReadSystemCfgSnapshot()
    local baseline, sources, unreadable = {}, {}, {}
    self.systemCfgPath = cfgPath

    for _, spec in ipairs(SPECS) do
        local native = self:TryReadCVar(spec.cvar)
        if native ~= nil then
            baseline[spec.key] = SpecValue(spec, native)
            sources[spec.key] = "native"
            self.metrics.baselineNative = (tonumber(self.metrics.baselineNative) or 0) + 1
        else
            unreadable[#unreadable + 1] = spec.cvar
            local cfg = type(cfgValues) == "table" and NativeNumber(cfgValues[spec.cvar]) or nil
            if cfg ~= nil then
                baseline[spec.key] = SpecValue(spec, cfg)
                sources[spec.key] = "system_cfg"
                self.metrics.baselineSystemCfg = (tonumber(self.metrics.baselineSystemCfg) or 0) + 1
            else
                baseline[spec.key] = SpecValue(spec, spec.default)
                sources[spec.key] = "default"
                self.metrics.baselineDefault = (tonumber(self.metrics.baselineDefault) or 0) + 1
            end
        end
    end

    self.baseline, self.baselineSources = Clone(baseline), Clone(sources)
    self.lastEffective = Clone(baseline)
    UpdateReadbackState(self, unreadable)

    if #unreadable > 0 then
        -- 这是能力差异而不是启动错误：SetConsoleVariable 仍可工作。只留信息证据，不污染模块故障环。
        Emit("info", "CVAR_READBACK_PARTIAL", "部分头顶显示 CVar 无法由 Lua 回读，已切换受控 write-only 模式", {
            readbackMode = self.readbackMode,
            unreadable = table.concat(unreadable, ","),
            baselineSources = JoinSources(sources),
            systemCfg = tostring(cfgPath or "not_found"),
        })
    end
    return true
end

local function SnapshotForRollback(self)
    local snapshot, observed, unreadable = {}, {}, {}
    for _, spec in ipairs(SPECS) do
        local native = self:TryReadCVar(spec.cvar)
        if native ~= nil then
            local value = SpecValue(spec, native)
            snapshot[spec.key], observed[spec.key] = value, value
        else
            unreadable[#unreadable + 1] = spec.cvar
            local fallback = type(self.lastApplied) == "table" and self.lastApplied[spec.key] or nil
            if fallback == nil and type(self.lastEffective) == "table" then fallback = self.lastEffective[spec.key] end
            if fallback == nil and type(self.baseline) == "table" then fallback = self.baseline[spec.key] end
            if fallback == nil then fallback = SpecValue(spec, spec.default) end
            snapshot[spec.key] = fallback
        end
    end
    self.lastObserved = Clone(observed)
    UpdateReadbackState(self, unreadable)
    return snapshot
end

local function RollbackSnapshot(self, snapshot, reason)
    self.metrics.rollbacks = (tonumber(self.metrics.rollbacks) or 0) + 1
    local failures = {}
    for _, spec in ipairs(SPECS) do
        local expected = ExpectedValue(spec, snapshot)
        local ok, err = self:WriteCVar(spec.cvar, expected)
        if ok ~= true then failures[#failures + 1] = spec.cvar .. "=" .. tostring(err) end
    end
    if #failures > 0 then
        local text = "回滚失败(" .. tostring(reason or "transaction") .. "): " .. table.concat(failures, "; ")
        Emit("error", "ROLLBACK_FAILED", "头顶显示增强 Native 事务回滚不完整", { error = text, reason = reason })
        return false, text
    end
    self.lastEffective = Clone(snapshot)
    return true
end

local function ValidateSettings(settings)
    local desired = {}
    for _, spec in ipairs(SPECS) do
        local expected = ExpectedValue(spec, settings)
        if expected == nil then return nil, "设置值无效：" .. tostring(spec.key) end
        desired[spec.key] = spec.boolean and (expected ~= 0) or expected
    end
    return desired
end

local function VerifyReadable(self, desired, rollback, reason)
    local observed, unreadable = {}, {}
    for _, spec in ipairs(SPECS) do
        local actual = self:TryReadCVar(spec.cvar)
        if actual == nil then
            unreadable[#unreadable + 1] = spec.cvar
            self.metrics.unverifiedWrites = (tonumber(self.metrics.unverifiedWrites) or 0) + 1
        else
            observed[spec.key] = SpecValue(spec, actual)
            self.metrics.verifiedWrites = (tonumber(self.metrics.verifiedWrites) or 0) + 1
            local expected = ExpectedValue(spec, desired)
            if not Equivalent(actual, expected) then
                self.metrics.failures = (tonumber(self.metrics.failures) or 0) + 1
                self.lastError = tostring(spec.cvar) .. " 回读不一致 expected=" .. tostring(expected) .. " actual=" .. tostring(actual)
                RollbackSnapshot(self, rollback, reason or "readback_mismatch")
                Emit("error", "READBACK_MISMATCH", "头顶显示增强 CVar 可读项回读不一致并已尝试回滚", {
                    error = self.lastError, cvar = spec.cvar, reason = reason,
                })
                return false, self.lastError
            end
        end
    end
    self.lastObserved = observed
    UpdateReadbackState(self, unreadable)
    return true
end

function A:ApplySettings(settings, reason)
    settings = type(settings) == "table" and settings or (type(F.GetSettings) == "function" and F:GetSettings() or nil)
    if type(settings) ~= "table" then return false, "设置不可用" end
    local desired, validateErr = ValidateSettings(settings)
    if desired == nil then return false, validateErr end

    -- 可读项使用真实 Native 值快照；不可读项使用 lastApplied / baseline。这样连续修改时，后一次
    -- Set 失败仍能回到前一次已经成功声明的值，而不是把整个 Feature 突然复位。
    local before = SnapshotForRollback(self)
    for _, spec in ipairs(SPECS) do
        local expected = ExpectedValue(spec, desired)
        local ok, err = self:WriteCVar(spec.cvar, expected)
        if ok ~= true then
            self.metrics.failures = (tonumber(self.metrics.failures) or 0) + 1
            self.lastError = tostring(spec.cvar) .. " 写入失败：" .. tostring(err)
            RollbackSnapshot(self, before, "write_failed")
            Emit("error", "CVAR_WRITE_FAILED", "头顶显示增强 CVar 写入失败并已尝试回滚", {
                error = self.lastError, reason = reason, cvar = spec.cvar,
            })
            return false, self.lastError
        end
    end

    -- 只对真正可读的变量做提交屏障。nil 不再等同于失败；它只会把该项记为 unverified/write-only。
    local verified, verifyErr = VerifyReadable(self, desired, before, "readback_mismatch")
    if verified ~= true then return false, verifyErr end

    self.lastApplied, self.lastEffective = Clone(desired), Clone(desired)
    self.metrics.applies = (tonumber(self.metrics.applies) or 0) + 1
    self.revision = (tonumber(self.revision) or 0) + 1
    self.lastApplyReason, self.lastError = tostring(reason or "apply"), nil
    return true
end

function A:RestoreBaseline(reason)
    if self.baseline == nil then return true end
    local before = SnapshotForRollback(self)
    for _, spec in ipairs(SPECS) do
        local expected = ExpectedValue(spec, self.baseline)
        local ok, err = self:WriteCVar(spec.cvar, expected)
        if ok ~= true then
            self.metrics.failures = (tonumber(self.metrics.failures) or 0) + 1
            self.lastError = tostring(spec.cvar) .. " 恢复失败：" .. tostring(err)
            RollbackSnapshot(self, before, "restore_failed")
            Emit("error", "RESTORE_FAILED", "头顶显示增强关闭恢复失败，已尝试回滚到关闭前状态", {
                error = self.lastError, reason = reason,
            })
            return false, self.lastError
        end
    end

    local verified, verifyErr = VerifyReadable(self, self.baseline, before, "restore_readback_mismatch")
    if verified ~= true then return false, verifyErr end

    self.lastApplied = nil
    self.lastEffective = Clone(self.baseline)
    self.metrics.restores = (tonumber(self.metrics.restores) or 0) + 1
    self.revision = (tonumber(self.revision) or 0) + 1
    self.lastApplyReason, self.lastError = tostring(reason or "restore"), nil
    return true
end

function A:ReleaseBaseline()
    self.baseline = nil
    self.baselineSources = nil
    self.lastApplied = nil
    self.systemCfgPath = nil
    return true
end

function A:GetBaselineSourceSummary()
    return JoinSources(self.baselineSources)
end

function A:GetProjection()
    return {
        baseline = self.baseline and Clone(self.baseline) or nil,
        baselineSources = self.baselineSources and Clone(self.baselineSources) or nil,
        baselineSourceSummary = self:GetBaselineSourceSummary(),
        observed = self.lastObserved and Clone(self.lastObserved) or nil,
        effective = self.lastEffective and Clone(self.lastEffective) or nil,
        revision = tonumber(self.revision) or 0,
        lastApplyReason = self.lastApplyReason,
        lastError = self.lastError,
        readbackMode = tostring(self.readbackMode or "unknown"),
        unreadableCvars = ArrayClone(self.unreadableCvars),
        systemCfgPath = self.systemCfgPath,
        metrics = Clone(self.metrics),
        markerCvar = "name_tag_mark_size_ratio",
        legacyMarkerCvarsIgnored = true,
    }
end
