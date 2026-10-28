-- Replicated Suite · 共享持久化框架
-- 作者：Replicated
-- QQ群：1104129461
-- 本层管理 SaveData 键、schema 隔离、dirty/debounce、周期和诊断；业务数据与重置方式由各 Store 决定。
-- 旧 Suite payload 只用作迁移来源。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

local DeepCopy
if S.Reuse and S.Reuse.Table and type(S.Reuse.Table.DeepCopy) == "function" then
    DeepCopy = S.Reuse.Table.DeepCopy
else
    -- 递归兜底须自包含；Lua 5.1 中在局部变量自身初始化表达式内引用 DeepCopy 会解析为全局。
    DeepCopy = function(value, seen)
        if type(value) ~= "table" then return value end
        seen = seen or {}
        if seen[value] ~= nil then return seen[value] end
        local out = {}; seen[value] = out
        for k, v in pairs(value) do out[DeepCopy(k, seen)] = DeepCopy(v, seen) end
        return out
    end
end

local LIFETIME = {
    Permanent = "Permanent",
    Daily = "Daily",
    Weekly = "Weekly",
    Session = "Session",
    Checkpoint = "Checkpoint",
}

local SCOPE = {
    Account = "Account",
    Character = "Character",
}

S.Persistence = {
    FrameworkVersion = 3,
    -- RU SaveData 可能省略 false、空表、0 和空字符串，也可能损失数字精度。
    -- Transport 仅在保存/加载边界保护这些值；v3 不改业务 schema 或既有六位有效数字指纹，旧版本仍可读。
    TransportContractVersion = 3,
    TransportNumericPrecisionProtectionContractVersion = 1,
    -- 负整数也走既有 n-token；仅标识本次物理保护，不改变 Schema/章算法。
    TransportSignedIntegerProtectionContractVersion = 1,
    FailedSaveEvidenceContractVersion = 1,
    ReadbackDivergenceDiagnosticsContractVersion = 1,
    TransportScalarOmissionProtectionContractVersion = 1,
    ReliabilityContractVersion = 8,
    MinIntegrityReliabilityContractVersion = 4,
    -- Integrity v3 校验解码并归一化后的 canonical，避免 map/sequence、空表或浮点表示变化造成假隔离。
    -- v2 原 envelope 指纹保留兼容。部分生活 Store 的早期 v3 只哈希默认形状、忽略内容，须经下方门禁升级到 v4。
    IntegrityContractVersion = 4,
    ContentBlindCanonicalContractVersion = 3,
    PreCanonicalIntegrityContractVersion = 2,
    LegacyIntegrityContractVersion = 1,
    SerializerNumericFingerprintContractVersion = 1,
    EnvelopeIntegrityContractVersion = 1,
    ScopeBindingContractVersion = 1,
    RuntimeAcceptanceDiagnosticsContractVersion = 1,
    RuntimeAcceptanceSnapshotContractVersion = 2,
    ReadinessContractVersion = 1,
    TerminalLoadMemoizationContractVersion = 1,
    HistoricalCanonicalRecoveryContractVersion = 3,
    KnownLegacyCanonicalRecoveryContractVersion = 1,
    IntegrityRecoveryTraceContractVersion = 1,
    -- Describe 按 GetStoreFailureKind 汇总当前故障；历史失败计数保留为 warning，不据此永久阻断。
    CurrentFailureSummaryContractVersion = 1,
    Lifetime = LIFETIME,
    Scope = SCOPE,
    DefaultBudget = { maxDepth = 12, maxNodes = 4096, maxStringBytes = 65536, maxEntriesPerTable = 1024 },
    -- Domain payload 与框架 envelope 分别预算，不能把 {payload,__rsmeta} 用业务预算整体校验，否则框架新增的
    -- 一层包装会使处于合法 maxDepth 的 payload 被拒绝。
    DefaultEnvelopeOverhead = { maxDepth = 2, maxNodes = 64, maxStringBytes = 4096, maxEntriesPerTable = 16 },
    stores = {},
    order = {},
    keyOwners = {},
    defaultDelayMs = 750,
    maxDebounceMs = 5000,
    periodCheckMs = 15000,
    nextPeriodCheckAt = 0,
    -- 运行时保留失败 Store ID 和原因供 reload/Flush 诊断，不参与写策略。
    lastFlush = { at = 0, ok = nil, saved = 0, verified = 0, failures = {} },
    stats = {
        registered = 0,
        loaded = 0,
        loadFailures = 0,
        saves = 0,
        saveFailures = 0,
        migrations = 0,
        periodResets = 0,
        payloadRejected = 0,
        encodedPayloadRejected = 0,
        metadataMismatches = 0,
        keyCollisions = 0,
        clears = 0,
        clearFailures = 0,
        unloadedWriteRejects = 0,
        dirtyReloadRejects = 0,
        unverifiedReloadRejects = 0,
        flushFailures = 0,
        retryQueued = 0,
        corruptEmptyRejects = 0,
        mutationAttempts = 0,
        mutationPrepareRejects = 0,
        mutationFailures = 0,
        mutationCommitFailures = 0,
        mutationRollbacks = 0,
        mutationRollbackFailures = 0,
        readbackVerifyAttempts = 0,
        readbackVerifySuccesses = 0,
        readbackVerifyFailures = 0,
        integrityStampedSaves = 0,
        integrityLoadChecks = 0,
        integrityLoadFailures = 0,
        integrityLegacyLoads = 0,
        integrityCompatibilityLoads = 0,
        integrityCompatibilityResaves = 0,
        integritySerializerRepairLoads = 0,
        integritySerializerRepairFailures = 0,
        integritySerializerRepairResaves = 0,
        integrityUpgradeRecoveries = 0,
        integrityUpgradeResaves = 0,
        integrityUpgradeValidationFailures = 0,
        encodedLoadRejects = 0,
        verifiedReplacementRecoveries = 0,
        barrierVerifyAttempts = 0,
        barrierVerifySuccesses = 0,
        barrierVerifyFailures = 0,
        barrierVerifyRequeued = 0,
        clearVerifyAttempts = 0,
        clearVerifyFailures = 0,
        envelopeIntegrityStampedSaves = 0,
        envelopeIntegrityLoadChecks = 0,
        envelopeIntegrityLoadFailures = 0,
        decodedLoadRejects = 0,
        durableVerifyAttempts = 0,
        durableVerifyFailures = 0,
        scopeBindingMismatches = 0,
        scopeRebinds = 0,
        deferredLoadResaves = 0,
        readPrepareAttempts = 0,
        readPrepareFailures = 0,
        readPrepareLoads = 0,
        terminalAutoRetrySuppressions = 0,
        terminalLoadShortCircuits = 0,
        knownLegacyCanonicalRecoveries = 0,
        knownLegacyCanonicalRecoveryRejects = 0,
    },
}
local P = S.Persistence
P.V3KeyPrefix = tostring(S.SaveKey or "replicated_suite_v1") .. "_v3_"

local function NowMs()
    return type(S.NowMs) == "function" and math.max(0, tonumber(S.NowMs()) or 0) or 0
end

local function NonEmptyText(value)
    if value == nil then return nil end
    local text = tostring(value):gsub("[\r\n]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return text ~= "" and text or nil
end

-- 恢复 trace 记录 envelope、代际、hook 和候选 Hash 分支，方便辨认拒绝位置。
-- 不保留玩家或设置内容，也不进入 canonical/envelope。
local function AppendIntegrityRecoveryTrace(store, token)
    if type(store) ~= "table" then return end
    token = NonEmptyText(token)
    if token == nil then return end
    local current = NonEmptyText(store.lastIntegrityRecoveryTrace)
    local nextValue = current ~= nil and (current .. ";" .. token) or token
    if #nextValue > 240 then nextValue = nextValue:sub(1, 237) .. "..." end
    store.lastIntegrityRecoveryTrace = nextValue
end

-- 物理编解码在 core/rs_persistence_transport.lua，Store 只声明业务 schema。
-- v1 保护 false/空表，v2 再保护 0/空字符串；加载后先还原，再验 metadata/schema 并 Apply。
-- rs_architecture_audit 也扫描注释，勿在此写具体业务表的点号字段访问。
    local T = S.PersistenceTransport
    if type(T) ~= "table" or type(T.EncodeV3) ~= "function" or type(T.DecodeV3) ~= "function" then
        error("PersistenceTransport unavailable for rs_persistence")
    end
P.SupportedTransportContractVersion=7 -- 默认新写仍为3；压缩格式由 Store 显式选择。

function P:EncodePhysicalEnvelope(raw)
    if type(raw) ~= "table" then return nil, "transport_raw_type:" .. tostring(type(raw)) end
    -- 生产 EncodeValue 按Store注册选择默认3或显式4/5；旧格式仍原样支持，禁止内容与版本标签不一致。
    local version = type(raw.__rsmeta) == "table" and tonumber(raw.__rsmeta.transportVersion) or self.TransportContractVersion
    local encoded, err
    if version == 1 then encoded, err = T.EncodeV1(raw)
    elseif version == 2 then encoded, err = T.EncodeV2(raw)
    elseif version == 3 then encoded, err = T.EncodeV3(raw)
    elseif version == 4 then encoded, err = T.EncodeV4(raw)
    elseif version == 5 then encoded, err = T.EncodeV5(raw)
    elseif version == 6 then encoded, err = T.EncodeV6(raw)
    elseif version == 7 then encoded, err = T.EncodeV7(raw)
    else return nil, "transport_contract:" .. tostring(version) .. ">" .. tostring(self.SupportedTransportContractVersion) end
    if encoded == nil then return nil, err end
    -- DecodePhysicalEnvelope 必须在完整解码前读取这两个路由字段；它们均为非零整数，不属于已知 serializer
    -- omission 类型。
    -- 覆盖回原生数字也避免 v3 标量编码规则扩展后出现“为了知道 codec 版本必须先知道 codec 版本”的自举死循环。
    if type(encoded.__rsmeta) == "table" and type(raw.__rsmeta) == "table" then
        encoded.__rsmeta.framework = raw.__rsmeta.framework
        encoded.__rsmeta.transportVersion = raw.__rsmeta.transportVersion
    end
    return encoded, nil
end

function P:DecodePhysicalEnvelope(raw)
    if type(raw) ~= "table" then return nil, "transport_raw_type:" .. tostring(type(raw)) end
    local meta = type(raw.__rsmeta) == "table" and raw.__rsmeta or nil
    local framework = meta and tonumber(meta.framework) or nil
    local transport = meta and tonumber(meta.transportVersion) or nil
    if framework ~= nil and framework >= 3 then
        if transport == 1 then return T.DecodeV1(raw) end -- 旧 v1 只读兼容，正常业务写入时升级，不在启动批量重写。
        if transport == 2 then return T.DecodeV2(raw) end
        -- 先还原精确 number，再进入原 Envelope/Store 校验；未知代际仍 fail-closed。
        if transport == 3 then return T.DecodeV3(raw) end
        if transport == 4 then return T.DecodeV4(raw) end
        if transport == 5 then return T.DecodeV5(raw) end
        if transport == 6 then return T.DecodeV6(raw) end
        if transport == 7 then return T.DecodeV7(raw) end
        return nil, "transport_contract:" .. tostring(transport) .. ">" .. tostring(self.SupportedTransportContractVersion) -- 未知/future transport 不猜测，防止旧客户端覆盖新格式。
    end
    -- Framework2/无 metadata 的历史存档没有物理哨兵，保持原样进入既有 legacy/schema 迁移。
    -- transportVersion 单独出现而 framework 缺失属于损坏 envelope，不猜测恢复。
    if transport ~= nil then return nil, "transport_without_framework" end
    return raw, nil
end

local PAGE_BYTES,MAX_PAGES=4000,512
local function PageChecksum(text)
    local a,b=1,0
    for i=1,#text do a=(a+text:byte(i))%65521;b=(b+a)%65521 end
    return string.format('%08X',b*65536+a)
end
local function PageKey(key,bank,index)return key..'_rs_page_'..bank..'_'..index end
local function SamePageMetadata(a,b)
    if type(a)~='table' or type(b)~='table' then return false end
    for key,value in pairs(a)do if type(value)=='table' or b[key]~=value then return false end end
    for key,value in pairs(b)do if a[key]~=value then return false end end
    return true
end
-- 大型 Store 可显式选择分页：两个物理 bank 轮换，所有新页回读成功后才切换根指针。
-- 根 key 仍携带原 metadata；读完完整树后继续走原 transport/归属/预算/完整性链，缺页绝不回退为空档。
function P:ReadPhysicalStore(store,key)
    local root,err=S.Api:LoadData(key)
    if err or type(root)~='table' or root.__rsPaged==nil then return root,err end
    if store.nativePaged~=true then return nil,'paged_store_not_supported' end
    local header=root.__rsPaged
    if type(header)~='table' or header.version~=1 or (header.bank~=1 and header.bank~=2)
        or type(header.count)~='number' or header.count~=math.floor(header.count) or header.count<1 or header.count>MAX_PAGES
        or type(header.bytes)~='number' or header.bytes~=math.floor(header.bytes) or header.bytes<1
        or header.bytes>MAX_PAGES*PAGE_BYTES or math.ceil(header.bytes/PAGE_BYTES)~=header.count
        or type(header.checksum)~='string' or not header.checksum:match('^%x%x%x%x%x%x%x%x$') then return nil,'paged_header_invalid' end
    local chunks={}
    for i=1,header.count do
        local page,readErr=S.Api:LoadData(PageKey(key,header.bank,i))
        if readErr then return nil,'paged_read:'..tostring(readErr) end
        local size=math.min(PAGE_BYTES,header.bytes-(i-1)*PAGE_BYTES)
        if type(page)~='table' or page.revision~=header.checksum or page.index~=i or page.count~=header.count
            or type(page.data)~='string' or #page.data~=size*2 or page.data:find('[^0-9A-F]') then return nil,'paged_part_invalid:'..i end
        chunks[i]=(page.data:gsub('..',function(pair)return string.char(tonumber(pair,16))end))
    end
    local wire=table.concat(chunks)
    if #wire~=header.bytes or PageChecksum(wire)~=header.checksum then return nil,'paged_checksum_mismatch' end
    local raw,decodeErr=T.UnpackPhysicalTree(wire)
    if not raw then return nil,decodeErr end
    if not SamePageMetadata(root.__rsmeta,raw.__rsmeta) then return nil,'paged_metadata_mismatch' end
    return raw
end
local function SamePhysical(a,b)
    if a==nil or b==nil then return a==b end
    local left=T.PackPhysicalTree(a);local right=T.PackPhysicalTree(b)
    return left~=nil and left==right
end
local function CommitPhysicalRoot(key,root,previous)
    local saved,saveErr=S.Api:SaveData(key,root)
    local actual,verifyErr=S.Api:LoadData(key)
    if not verifyErr and SamePhysical(actual,root) then return true end
    -- 小快照/清空也会替换分页根，必须共用提交边界。Native false 可能已写，以完整回读为准。
    -- 部分写坏时先恢复旧根，不能让完整旧 bank 失去入口。
    if not verifyErr and SamePhysical(actual,previous) then return false,'paged_root_not_committed:'..tostring(saveErr or saved) end
    if previous~=nil then
        S.Api:SaveData(key,previous)
        local restored,restoreErr=S.Api:LoadData(key)
        if not restoreErr and SamePhysical(restored,previous) then return false,'paged_root_restored' end
        return false,'paged_root_restore_failed:'..tostring(restoreErr or verifyErr or saveErr or 'readback_mismatch')
    end
    return false,'paged_root_unverified:'..tostring(verifyErr or saveErr or 'readback_mismatch')
end
function P:WritePhysicalStore(store,key,raw)
    local limit=store.nativeByteBudget
    if store.nativePaged~=true or not limit then return S.Api:SaveData(key,raw) end
    local previous,readErr=S.Api:LoadData(key)
    if readErr then return false,'paged_previous_read:'..tostring(readErr) end
    local header=type(previous)=='table' and previous.__rsPaged or nil
    if header~=nil and (type(header)~='table' or (header.bank~=1 and header.bank~=2)) then return false,'paged_previous_header' end
    if T.EstimateNativeBytes(raw)<=limit then return CommitPhysicalRoot(key,raw,previous) end
    local wire,err=T.PackPhysicalTree(raw)
    if not wire then return false,err end
    local count=math.ceil(#wire/PAGE_BYTES)
    if count>MAX_PAGES then return false,'paged_capacity_exceeded' end
    local bank=type(header)=='table' and (3-header.bank) or 1
    local checksum=PageChecksum(wire)
    local root={__rsmeta=DeepCopy(raw.__rsmeta),__rsPaged={version=1,bank=bank,count=count,bytes=#wire,checksum=checksum}}
    if T.EstimateNativeBytes(root)>limit then return false,'paged_manifest_budget' end
    for i=1,count do
        local text=wire:sub((i-1)*PAGE_BYTES+1,i*PAGE_BYTES)
        local hex=(text:gsub('.',function(ch)return string.format('%02X',ch:byte())end))
        local page={revision=checksum,index=i,count=count,data=hex}
        if T.EstimateNativeBytes(page)>limit then return false,'paged_part_budget' end
        local pageKey=PageKey(key,bank,i)
        local ok,saveErr=S.Api:SaveData(pageKey,page)
        if ok~=true then return false,'paged_write:'..tostring(saveErr or 'rejected') end
        local actual,verifyErr=S.Api:LoadData(pageKey)
        if verifyErr or type(actual)~='table' or actual.revision~=checksum or actual.index~=i
            or actual.count~=count or actual.data~=hex then return false,'paged_readback:'..i end
    end
    return CommitPhysicalRoot(key,root,previous)
end

-- 数字键被存成字符串后，ipairs 会读成空序列；这里只生成 Store 声明序列的无损形状候选。
-- 仅接受完整 1..N，拒绝稀疏、0 起点、重复或非规范索引；必须命中原指纹，不作通用 map→array 转换。
function P:RebuildDenseSequenceForIntegrity(value, limit)
    if type(value) ~= "table" then return nil, "sequence_type" end
    limit = math.min(2048, math.max(0, math.floor(tonumber(limit) or 0)))
    local indexed, count, maximum, changed = {}, 0, 0, false
    for key, row in pairs(value) do
        local kind, index = type(key), tonumber(key)
        if (kind ~= "number" and kind ~= "string") or index == nil or index ~= index
            or index < 1 or index ~= math.floor(index) then return nil, "invalid_index" end
        if index > limit or count >= limit then return nil, "sequence_limit" end
        if kind == "string" and (not key:match("^[1-9]%d*$") or tostring(index) ~= key) then
            return nil, "invalid_index"
        end
        if indexed[index] ~= nil then return nil, "duplicate_index" end
        indexed[index], count = row, count + 1
        maximum = math.max(maximum, index)
        changed = changed or kind == "string"
    end
    if maximum ~= count then return nil, "sparse_sequence" end
    local out = {}
    for index = 1, count do out[index] = DeepCopy(indexed[index]) end
    return out, nil, changed
end

local function NormalizeId(value)
    local text = tostring(value or ""):lower():gsub("[^%w_%.%-]", "_"):gsub("_+", "_")
    text = text:gsub("^_+", ""):gsub("_+$", "")
    return text
end

local function Emit(level, code, message, context)
    local d = S.DiagnosticsManager
    if type(d) == "table" and type(d.Emit) == "function" then
        return d:Emit(level, "persistence", code, message, context)
    end
    if (level == "error" or level == "warning") and type(S.RecordLog) == "function" then
        S.RecordLog(level, "persistence", "[" .. tostring(code) .. "] " .. tostring(message))
    end
end

local function Count(code, delta)
    local d = S.DiagnosticsManager
    if type(d) == "table" and type(d.Count) == "function" then d:Count("persistence", code, delta or 1) end
end

local function NormalizeBudget(value)
    value = type(value) == "table" and value or {}
    local defaults = P.DefaultBudget or {}
    return {
        maxDepth = math.max(2, math.floor(tonumber(value.maxDepth) or tonumber(defaults.maxDepth) or 12)),
        maxNodes = math.max(16, math.floor(tonumber(value.maxNodes) or tonumber(defaults.maxNodes) or 4096)),
        maxStringBytes = math.max(256, math.floor(tonumber(value.maxStringBytes) or tonumber(defaults.maxStringBytes) or 65536)),
        maxEntriesPerTable = math.max(8, math.floor(tonumber(value.maxEntriesPerTable) or tonumber(defaults.maxEntriesPerTable) or 1024)),
    }
end

local function NormalizeEnvelopeBudget(domainBudget, explicitBudget)
    domainBudget = NormalizeBudget(domainBudget)
    if type(explicitBudget) == "table" then
        local explicit = NormalizeBudget(explicitBudget)
        -- envelope 预算须容纳已批准的 payload，同时限制自定义编码器，不能因多一层元数据拒绝合法业务值。
        return {
            maxDepth = math.max(domainBudget.maxDepth, explicit.maxDepth),
            maxNodes = math.max(domainBudget.maxNodes, explicit.maxNodes),
            maxStringBytes = math.max(domainBudget.maxStringBytes, explicit.maxStringBytes),
            maxEntriesPerTable = math.max(domainBudget.maxEntriesPerTable, explicit.maxEntriesPerTable),
        }
    end
    local overhead = P.DefaultEnvelopeOverhead or {}
    return {
        maxDepth = domainBudget.maxDepth + math.max(1, math.floor(tonumber(overhead.maxDepth) or 2)),
        maxNodes = domainBudget.maxNodes + math.max(8, math.floor(tonumber(overhead.maxNodes) or 64)),
        maxStringBytes = domainBudget.maxStringBytes + math.max(256, math.floor(tonumber(overhead.maxStringBytes) or 4096)),
        maxEntriesPerTable = math.max(domainBudget.maxEntriesPerTable, math.max(8, math.floor(tonumber(overhead.maxEntriesPerTable) or 16))),
    }
end

-- RU 曾截断大型嵌套 payload，保存和加载边界都要检查结构预算；不在 Tick 扫描。
function P:InspectPayload(value, budget)
    budget = NormalizeBudget(budget)
    local seen = {}
    local result = { ok = true, nodes = 0, stringBytes = 0, maxDepth = 0, maxTableEntries = 0, reason = nil }
    local function Fail(reason)
        if result.ok then result.ok = false; result.reason = reason end
        return false
    end
    local function Visit(node, depth)
        if result.ok ~= true then return false end
        if depth > budget.maxDepth then return Fail("max_depth") end
        if depth > result.maxDepth then result.maxDepth = depth end
        local t = type(node)
        result.nodes = result.nodes + 1
        if result.nodes > budget.maxNodes then return Fail("max_nodes") end
        if t == "nil" or t == "boolean" then return true end
        if t == "number" then
            if node ~= node or node == math.huge or node == -math.huge then return Fail("invalid_number") end
            return true
        end
        if t == "string" then
            result.stringBytes = result.stringBytes + #node
            if result.stringBytes > budget.maxStringBytes then return Fail("max_string_bytes") end
            return true
        end
        if t ~= "table" then return Fail("unsupported_type:" .. t) end
        if seen[node] then return Fail("cyclic_table") end
        seen[node] = true
        local entries = 0
        for k, v in pairs(node) do
            entries = entries + 1
            if entries > budget.maxEntriesPerTable then seen[node] = nil; return Fail("max_table_entries") end
            local kt = type(k)
            if kt ~= "string" and kt ~= "number" then seen[node] = nil; return Fail("unsupported_key_type:" .. kt) end
            if not Visit(k, depth + 1) or not Visit(v, depth + 1) then seen[node] = nil; return false end
        end
        if entries > result.maxTableEntries then result.maxTableEntries = entries end
        seen[node] = nil
        return true
    end
    Visit(value, 1)
    result.budget = budget
    return result
end

local function IsLeapYear(year)
    year = tonumber(year) or 0
    return year % 400 == 0 or (year % 4 == 0 and year % 100 ~= 0)
end

local MONTH_DAYS = { 31,28,31,30,31,30,31,31,30,31,30,31 }

local function ValidDate(year, month, day)
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    if year == nil or year < 2000 or year > 2100 or month == nil or month < 1 or month > 12 or day == nil or day < 1 then
        return false
    end
    local maxDay = MONTH_DAYS[month] + ((month == 2 and IsLeapYear(year)) and 1 or 0)
    return day <= maxDay
end

-- 小型有界日历辅助函数只在周期检查中运行（默认每 15 秒），不进入战斗或事件热循环。
local function DateOrdinal(year, month, day)
    if not ValidDate(year, month, day) then return nil end
    local value = 0
    for y = 2000, year - 1 do value = value + (IsLeapYear(y) and 366 or 365) end
    for m = 1, month - 1 do value = value + MONTH_DAYS[m] + ((m == 2 and IsLeapYear(year)) and 1 or 0) end
    return value + day - 1
end

local function DateFromOrdinal(ordinal)
    ordinal = math.floor(tonumber(ordinal) or -1)
    if ordinal < 0 then return nil end
    local year = 2000
    while year <= 2100 do
        local days = IsLeapYear(year) and 366 or 365
        if ordinal < days then break end
        ordinal = ordinal - days
        year = year + 1
    end
    if year > 2100 then return nil end
    local month = 1
    while month <= 12 do
        local days = MONTH_DAYS[month] + ((month == 2 and IsLeapYear(year)) and 1 or 0)
        if ordinal < days then break end
        ordinal = ordinal - days
        month = month + 1
    end
    if month > 12 then return nil end
    return year, month, ordinal + 1
end

local function ShiftDate(year, month, day, deltaDays)
    local ordinal = DateOrdinal(year, month, day)
    if ordinal == nil then return nil end
    return DateFromOrdinal(ordinal + math.floor(tonumber(deltaDays) or 0))
end

local function ServerTimeParts()
    if S.Utils == nil or type(S.Utils.GetServerTime) ~= "function" then return nil end
    local t = S.Utils.GetServerTime()
    if type(t) ~= "table" then return nil end
    local year, month, day = tonumber(t.year), tonumber(t.month), tonumber(t.day)
    if not ValidDate(year, month, day) then return nil end
    local hour = math.max(0, math.min(23, math.floor(tonumber(t.hour) or 0)))
    local minute = math.max(0, math.min(59, math.floor(tonumber(t.minute) or 0)))
    return year, month, day, hour, minute
end

local function DateText(year, month, day)
    if not ValidDate(year, month, day) then return nil end
    return string.format("%04d-%02d-%02d", year, month, day)
end

local function BeforeReset(hour, minute, resetHour, resetMinute)
    local nowMinutes = (tonumber(hour) or 0) * 60 + (tonumber(minute) or 0)
    local resetMinutes = (tonumber(resetHour) or 0) * 60 + (tonumber(resetMinute) or 0)
    return nowMinutes < resetMinutes
end

function P:GetPeriodId(lifetime, policy)
    lifetime = tostring(lifetime or "")
    if lifetime == LIFETIME.Permanent then return "permanent" end
    if lifetime == LIFETIME.Session then return "session:g" .. tostring(tonumber(S.Generation) or 0) end
    if lifetime == LIFETIME.Checkpoint then return "checkpoint" end

    policy = type(policy) == "table" and policy or nil
    if policy == nil then return nil, "reset policy required" end
    local year, month, day, hour, minute = ServerTimeParts()
    if year == nil then return nil, "server time unavailable" end

    local kind = tostring(policy.kind or "")
    if lifetime == LIFETIME.Daily then
        if kind == "server_date" then return DateText(year, month, day) end
        if kind ~= "server_reset" then return nil, "unsupported daily reset policy: " .. kind end
        local resetHour = math.max(0, math.min(23, math.floor(tonumber(policy.hour) or 0)))
        local resetMinute = math.max(0, math.min(59, math.floor(tonumber(policy.minute) or 0)))
        if BeforeReset(hour, minute, resetHour, resetMinute) then
            year, month, day = ShiftDate(year, month, day, -1)
        end
        return DateText(year, month, day)
    end

    if lifetime == LIFETIME.Weekly then
        if kind ~= "server_weekly" then return nil, "unsupported weekly reset policy: " .. kind end
        local resetWeekday = math.floor(tonumber(policy.weekday) or 0)
        if resetWeekday < 1 or resetWeekday > 7 then return nil, "weekly reset weekday must be 1..7" end
        local resetHour = math.max(0, math.min(23, math.floor(tonumber(policy.hour) or 0)))
        local resetMinute = math.max(0, math.min(59, math.floor(tonumber(policy.minute) or 0)))
        local weekday = S.Utils and type(S.Utils.DayOfWeek) == "function" and S.Utils.DayOfWeek(year, month, day) or nil
        if weekday == nil then return nil, "weekday unavailable" end
        local daysSince = (weekday - resetWeekday) % 7
        if daysSince == 0 and BeforeReset(hour, minute, resetHour, resetMinute) then daysSince = 7 end
        year, month, day = ShiftDate(year, month, day, -daysSince)
        local date = DateText(year, month, day)
        return date and ("week:" .. date) or nil
    end
    return nil, "unsupported lifetime: " .. lifetime
end

local SCOPE_HASH_MOD = 2147483647

local function ScopeIdentityFingerprint(value)
    value = NonEmptyText(value)
    if value == nil then return nil end
    -- 两个独立有界字节哈希使身份标记仅含 ASCII，不改变历史物理 SaveData 键格式；这是碰撞检测，不是密码学身份原语。
    local h1, h2 = 104729, 130363
    for i = 1, #value do
        local byte = string.byte(value, i)
        h1 = (h1 * 131 + byte) % SCOPE_HASH_MOD
        h2 = (h2 * 137 + byte + i) % SCOPE_HASH_MOD
    end
    return string.format("%08X%08X", math.floor(h1), math.floor(h2))
end

local function CharacterScopeIdentity()
    -- 角色身份直接取带世界名单元 getter，不依赖旧 Storage 的延迟角色状态。
    local identity = nil
    if X2Unit ~= nil and S.Api ~= nil and type(S.Api.CallCapability) == "function" then
        local ok, value = S.Api:CallCapability("X2Unit:UnitNameWithWorld", X2Unit, "UnitNameWithWorld", "player")
        -- 身份仅接受 Native 文本；false/数字/table 表示未就绪，不能 tostring 后创建永久角色键。
        if ok and type(value) == "string" then identity = NonEmptyText(value) end
    end
    return identity
end

local function CharacterScopeToken(identity)
    identity = NonEmptyText(identity)
    if identity == nil then return nil end
    -- 无损 ASCII 延续旧物理键；只有大小写折叠是原契约，替换字符、合并下划线和截断都不能丢掉角色区别。
    -- 显式检查非 ASCII 字节，使结果不依赖 Lua/C locale 对 %w 的解释；旧 token 只作为只读迁移候选。
    local fullToken = NormalizeId("world:" .. identity)
    local legacyToken = fullToken:sub(1, 80)
    local lossy = identity:find("[\128-\255]") ~= nil or fullToken ~= "world_" .. identity:lower() or #fullToken > 80
    if lossy ~= true then return legacyToken, nil end
    -- 非 ASCII 身份复用稳定双哈希，v2_ 与旧 world 前缀分开，总长仍 <=80。物理键分离后也须校验 scope 指纹。
    return "v2_" .. ScopeIdentityFingerprint(identity) .. "_" .. legacyToken:sub(1, 60), legacyToken
end

function P:ResolveStoreKey(storeOrId)
    local store = type(storeOrId) == "table" and storeOrId or self:GetStore(storeOrId)
    if store == nil then return nil, "unknown store" end
    if store.lifetime == LIFETIME.Session then return nil, nil, nil end
    local baseKey = NonEmptyText(store.key)
    if baseKey == nil then return nil, "store key unavailable", nil end
    if store.scope == SCOPE.Account then return baseKey, nil, nil end
    if store.scope == SCOPE.Character then
        local identity = CharacterScopeIdentity()
        local token, legacyToken = CharacterScopeToken(identity)
        if token == nil then return nil, "character scope unavailable", nil end
        -- 第四返回值只供 Core 的缺键迁移读取；当前绑定、所有保存和耐久验证始终使用第一返回的新权威键。
        return baseKey .. "_char_" .. token, nil, ScopeIdentityFingerprint(identity),
            legacyToken ~= nil and (baseKey .. "_char_" .. legacyToken) or nil
    end
    return nil, "unsupported scope: " .. tostring(store.scope), nil
end

local function CurrentScopeBinding(store)
    if store == nil or store.lifetime == LIFETIME.Session or store.scope ~= SCOPE.Character then
        return true, nil, store and store.resolvedKey or nil, store and store.resolvedScopeFingerprint or nil
    end

    -- 只在就绪或写边界重新解析身份；不能缓存旧身份后把保存导向错误角色。
    local currentKey, scopeErr, currentFingerprint = P:ResolveStoreKey(store)
    if currentKey == nil then return false, scopeErr or "character scope unavailable", nil, nil end
    if store.resolvedKey ~= nil and tostring(store.resolvedKey) ~= tostring(currentKey) then
        return false, "scope_binding_key_changed", currentKey, currentFingerprint
    end
    if store.resolvedScopeFingerprint ~= nil and currentFingerprint ~= nil
        and tostring(store.resolvedScopeFingerprint) ~= tostring(currentFingerprint) then
        return false, "scope_binding_identity_changed", currentKey, currentFingerprint
    end
    return true, nil, currentKey, currentFingerprint
end

local EncodeValue

local function ValidateDefinition(def)
    if type(def) ~= "table" then return nil, "definition must be table" end
    local id = NormalizeId(def.id)
    if id == "" then return nil, "store id required" end
    local lifetime = tostring(def.lifetime or "")
    if LIFETIME[lifetime] == nil then return nil, "invalid lifetime: " .. lifetime end
    local scope = tostring(def.scope or SCOPE.Account)
    if SCOPE[scope] == nil then return nil, "invalid scope: " .. scope end
    -- 只允许注册时明确选择已实现的物理格式；未知版本禁止写入。
    local tv=def.transportVersion
    if def.nativeByteBudget~=nil and (type(def.nativeByteBudget)~='number' or def.nativeByteBudget~=def.nativeByteBudget
        or def.nativeByteBudget<1024 or def.nativeByteBudget>65536 or def.nativeByteBudget~=math.floor(def.nativeByteBudget)) then return nil,'invalid native byte budget' end
    if def.nativePaged~=nil and (type(def.nativePaged)~='boolean' or not def.nativeByteBudget or def.save) then return nil,'invalid native paging policy' end
    if tv~=nil and (type(tv)~="number" or tv~=math.floor(tv) or tv<1 or tv>P.SupportedTransportContractVersion) then return nil,"unsupported store transport" end
    local contractVersion = math.max(1, math.floor(tonumber(def.contractVersion) or 1))
    if contractVersion >= 2 then
        if NonEmptyText(def.owner) == nil then return nil, "V2 store owner required" end
        if def.scope == nil then return nil, "V2 store scope required" end
        if type(def.budget) ~= "table" then return nil, "V2 store requires explicit SaveData budget" end
    end
    if contractVersion >= 3 then
        local owner = NonEmptyText(def.owner)
        if owner == nil or owner:match("^v3%.") == nil then return nil, "V3 store owner must use v3.* namespace" end
    end
    if lifetime ~= LIFETIME.Session and NonEmptyText(def.key) == nil then return nil, "persistent store key required" end
    if contractVersion >= 3 and lifetime ~= LIFETIME.Session then
        local key = NonEmptyText(def.key) or ""
        if key:sub(1, #P.V3KeyPrefix) ~= P.V3KeyPrefix then return nil, "V3 store key must use " .. P.V3KeyPrefix end
    end
    if (lifetime == LIFETIME.Daily or lifetime == LIFETIME.Weekly) and type(def.resetPolicy) ~= "table" then
        return nil, lifetime .. " store requires explicit resetPolicy"
    end
    if type(def.get) ~= "function" and lifetime ~= LIFETIME.Session then return nil, "get() required" end
    if type(def.apply) ~= "function" and lifetime ~= LIFETIME.Session then return nil, "apply() required" end
    return id, nil
end

function P:RegisterStore(def)
    local id, err = ValidateDefinition(def)
    if id == nil then
        Emit("error", "STORE_REGISTER_INVALID", tostring(err), { requestedId = type(def) == "table" and def.id or nil })
        return nil, err
    end
    if self.stores[id] ~= nil then
        Emit("error", "STORE_DUPLICATE", "重复 Persistence Store", { store = id })
        return nil, "duplicate store: " .. id
    end
    local requestedKey = NonEmptyText(def.key)
    if requestedKey ~= nil and tostring(def.lifetime) ~= LIFETIME.Session then
        local existingOwner = self.keyOwners[requestedKey]
        if existingOwner ~= nil then
            self.stats.keyCollisions = (tonumber(self.stats.keyCollisions) or 0) + 1
            Emit("error", "STORE_KEY_COLLISION", "Persistence Store 复用了已注册 SaveData Key", {
                store = id, key = requestedKey, existingStore = existingOwner,
            })
            return nil, "duplicate persistent key: " .. requestedKey
        end
    end

    local state = {
        id = id,
        owner = NonEmptyText(def.owner) or "Suite",
        lifetime = tostring(def.lifetime),
        scope = tostring(def.scope or SCOPE.Account),
        contractVersion = math.max(1, math.floor(tonumber(def.contractVersion) or 1)),
        schemaVersion = math.max(1, math.floor(tonumber(def.schemaVersion) or 1)),
        -- 仅批量ID Store选择v4；其他Store继续原有v3，schema和canonical不变。
        transportVersion = def.transportVersion or P.TransportContractVersion,
        nativeByteBudget = def.nativeByteBudget,
        nativePaged = def.nativePaged == true,
        legacySchemaVersion = math.max(0, math.floor(tonumber(def.legacySchemaVersion) or 0)),
        key = NonEmptyText(def.key),
        resolvedKey = nil,
        resolvedScopeFingerprint = nil,
        lastScopeBindingError = nil,
        get = def.get,
        apply = def.apply,
        default = type(def.default) == "function" and def.default or function() return {} end,
        encode = def.encode,
        decode = def.decode,
        -- 显式启用的表示恢复 hook 只能重建确定形状；envelope seal 有效且候选精确命中旧指纹才接受。
        rebuildEncodedForIntegrity = def.rebuildEncodedForIntegrity,
        -- transport 解码失败后，Store 可提供物理表候选；Core 仍须重验预算、解码、envelope 和业务指纹。
        -- hook 不能 Apply/Save/Clear 或解除写保护。
        repairPhysicalTransport = def.repairPhysicalTransport,
        -- 历史 canonical 候选须通过独立 seal、decode 和当前 canonical 构造，并精确复现旧指纹。
        -- 普通 Store 还要用当前归一化器处理恢复值，防止 false/省略被默认值替换；typed Store 由 decoder 归一化。
        -- 恢复后立即排队重新盖章。
        rebuildCanonicalForIntegrity = def.rebuildCanonicalForIntegrity,
        -- 保存回读的表示恢复默认关闭，只供已测试 Store 显式开启。
        -- 磁盘章、预期值和当前 canonical 必须一致且通过预算；不走 known-pair，也不改内存或补写。
        recoverReadbackRepresentation = def.recoverReadbackRepresentation == true,
        -- 已知 stamp 迁移是最后的白名单桥：当前校验和精确历史重建均失败，且 seal、metadata/schema、预算已通过才调用。
        -- Store 须精确匹配旧指纹并验证旧形状；未知指纹继续隔离。
        recoverKnownLegacyCanonical = def.recoverKnownLegacyCanonical,
        -- RU 曾在跨重载时改变旧 v2 envelope 表示，因此允许满足完整门禁的单代升级，并立即盖 canonical stamp。
        -- verifyAfterSave/recoverableReplacement 等排除条件仍适用；严格 Store 可设 allowIntegrityUpgrade=false。
        allowIntegrityUpgrade = def.allowIntegrityUpgrade ~= false,
        save = def.save,
        migrate = def.migrate,
        resetPolicy = def.resetPolicy,
        autoReset = def.autoReset == true,
        periodIdFromValue = def.periodIdFromValue,
        budget = NormalizeBudget(def.budget),
        encodedBudget = NormalizeEnvelopeBudget(def.budget, def.encodedBudget),
        verifyAfterSave = def.verifyAfterSave == true,
        recoverableReplacement = def.recoverableReplacement == true,
        requireFailureBarrier = def.requireFailureBarrier == true,
        registrationBudgetOk = true,
        dirty = false,
        dueAt = 0,
        firstDirtyAt = 0,
        lastDirtyAt = 0,
        lastDirtyReason = nil,
        dirtyRevision = 0,
        lastSavedRevision = 0,
        consecutiveSaveFailures = 0,
        loaded = false,
        loadStatus = "not_loaded",
        writeFenced = false,
        writeFenceReason = nil,
        replacementOwnershipOk = false,
        replacementOwnershipError = nil,
        lastError = nil,
        lastSaveAt = nil,
        lastLoadAt = nil,
        lastVerifyAt = nil,
        lastVerifyOk = nil,
        lastVerifyFingerprint = nil,
        lastVerifyError = nil,
        lastIntegrityStatus = nil,
        lastIntegrityFingerprint = nil,
        lastIntegrityError = nil,
        lastDecodedInspection = nil,
        needsBarrierVerify = false,
        lastBarrierVerifyAt = nil,
        lastBarrierVerifyOk = nil,
        lastBarrierVerifyError = nil,
        periodId = nil,
        memory = nil,
    }
    self.stores[id] = state
    if state.key ~= nil and state.lifetime ~= LIFETIME.Session then self.keyOwners[state.key] = state.id end
    self.order[#self.order + 1] = id
    table.sort(self.order)
    self.stats.registered = (tonumber(self.stats.registered) or 0) + 1
    Count("STORE_REGISTERED", 1)
    -- 注册时先验默认 payload 的预算；713-ID 跟踪表曾超出 192 项预算，不能等首次保存才发现。
    if state.lifetime ~= LIFETIME.Session then
        local okDefault, defaultPayload = pcall(state.default)
        if okDefault then
            local inspection = self:InspectPayload(defaultPayload, state.budget)
            state.lastPayloadInspection = inspection
            if inspection.ok ~= true then
                state.registrationBudgetOk = false
                state.lastError = "default_payload_rejected:" .. tostring(inspection.reason or "unknown")
                Emit("error", "STORE_DEFAULT_BUDGET_EXCEEDED",
                    "注册即超预算：store 默认 Domain payload 无法通过自身 SaveData 预算检查，所有保存都将被拒绝", {
                        store = id, reason = inspection.reason, nodes = inspection.nodes,
                        stringBytes = inspection.stringBytes, maxTableEntries = inspection.maxTableEntries,
                    })
            elseif type(EncodeValue) == "function" then
                local raw, encodeErr = EncodeValue(state, DeepCopy(defaultPayload), nil)
                if raw == nil then
                    state.registrationBudgetOk = false
                    state.lastError = "default_encode_failed:" .. tostring(encodeErr or "unknown")
                    Emit("error", "STORE_DEFAULT_ENCODE_FAILED", "注册期默认 payload 编码失败", { store = id, error = encodeErr })
                else
                    local encodedInspection = self:InspectPayload(raw, state.encodedBudget)
                    state.lastEncodedInspection = encodedInspection
                    if encodedInspection.ok ~= true then
                        state.registrationBudgetOk = false
                        state.lastError = "default_encoded_payload_rejected:" .. tostring(encodedInspection.reason or "unknown")
                        Emit("error", "STORE_DEFAULT_ENVELOPE_BUDGET_EXCEEDED",
                            "注册即超预算：Persistence 编码外壳无法通过独立 envelope 预算检查", {
                                store = id, reason = encodedInspection.reason, nodes = encodedInspection.nodes,
                                stringBytes = encodedInspection.stringBytes, maxTableEntries = encodedInspection.maxTableEntries,
                            })
                    end
                end
            end
        else
            state.registrationBudgetOk = false
            state.lastError = "default_exception:" .. tostring(defaultPayload)
        end
    end
    return state
end

function P:RegisterV3Store(def)
    if type(def) ~= "table" then return nil, "store definition required" end
    local copy = {}
    for k, v in pairs(def) do copy[k] = v end
    copy.contractVersion = 3
    return self:RegisterStore(copy)
end

function P:GetStore(id)
    return self.stores[NormalizeId(id)]
end

local function DecodeValue(store, raw)
    if type(store.decode) == "function" then
        local ok, value, err = pcall(store.decode, raw)
        if not ok then return nil, "decode exception: " .. tostring(value) end
        if err ~= nil then return nil, tostring(err) end
        return value, nil
    end
    if type(raw) == "table" and raw.payload ~= nil then return raw.payload, nil end
    -- 带 __rsmeta 的普通档是框架 envelope。RU 可能先删 false，再删空 payload；不能把剩余 metadata 当成 Domain。
    -- 这里只还原空外壳，丢失的 default=true→false 仍须后续旧指纹精确证明。
    if type(raw) == "table" and type(raw.__rsmeta) == "table" then return {}, nil end
    return raw, nil
end

EncodeValue = function(store, value, periodId, scopeFingerprint)
    local raw
    if type(store.encode) == "function" then
        local ok, result, err = pcall(store.encode, value)
        if not ok then return nil, "encode exception: " .. tostring(result) end
        if err ~= nil then return nil, tostring(err) end
        raw = result
    else
        raw = { payload = value }
    end
    if type(raw) ~= "table" then return nil, "encoded payload must be table" end
    raw.__rsmeta = {
        framework = P.FrameworkVersion,
        store = store.id,
        owner = store.owner,
        contractVersion = store.contractVersion,
        lifetime = store.lifetime,
        scope = store.scope,
        schema = store.schemaVersion,
        periodId = periodId,
        scopeBindingContract = store.scope == SCOPE.Character and P.ScopeBindingContractVersion or nil,
        scopeIdentityFingerprint = store.scope == SCOPE.Character and NonEmptyText(scopeFingerprint) or nil,
        transportVersion = store.transportVersion or P.TransportContractVersion, -- Store显式物理策略；数值字段不会被 RU false/空表省略，用于
                                                                                 -- LoadData 边界决定是否还原物理哨兵；旧 Framework2 无此字段。
    }
    return raw, nil
end

local function ApplyValue(store, value, reason)
    local ok, err = pcall(store.apply, DeepCopy(value), reason)
    if not ok then return false, tostring(err) end
    return true, nil
end

local function DefaultValue(store)
    local ok, value = pcall(store.default)
    if not ok then return nil, tostring(value) end
    return DeepCopy(value), nil
end

-- Framework2 可能丢 false、空表及空父表。普通 Store 仅按 default 声明重建：false 保持 false，空表保持空，缺 true 叶子尝试 false。
-- 只在 Framework<=2 的指纹失配路径执行；不枚举未知字段，候选经当前 canonicalizer 后须精确命中旧指纹。
function P:RebuildFramework2SerializerOmissions(store, decoded, stampedFingerprint, raw)
    if type(store) ~= "table" or type(raw) ~= "table" or type(raw.__rsmeta) ~= "table" then return nil, nil end
    if type(store.encode) == "function" or type(store.decode) == "function" then return nil, nil end
    local framework = tonumber(raw.__rsmeta.framework) or 0
    if framework < 1 or framework > 2 then return nil, nil end

    local defaults = DefaultValue(store)
    if type(defaults) ~= "table" then return nil, nil end
    local source = type(raw.payload) == "table" and raw.payload or (type(decoded) == "table" and decoded or {})
    local recovered = DeepCopy(source)
    local restored = 0
    local limit = 64 -- 仅为防御未来异常超大 schema；超过上限立即放弃恢复而不是扩大冷启动 CPU。

    local function Restore(defaultNode, sourceNode, outputNode)
        if restored > limit or type(defaultNode) ~= "table" or type(outputNode) ~= "table" then return end
        local sourceTable = type(sourceNode) == "table" and sourceNode or nil
        for key, defaultValue in pairs(defaultNode) do
            if restored > limit then return end
            local sourceValue = sourceTable ~= nil and sourceTable[key] or nil
            if sourceValue == nil and type(defaultValue) == "boolean" then
                -- RU 只会吞 false，不会吞 true。default=false 缺失直接复原 false；
                -- default=true 缺失只“尝试”为 false，最终仍由旧 fingerprint 决定是否真实成立。
                outputNode[key] = false
                restored = restored + 1
            elseif sourceValue == nil and type(defaultValue) == "table" and next(defaultValue) == nil then
                -- 空表是 RU 第二个已实证丢失形态。这里只恢复 Store default 明确声明的空表；
                -- 动态未知表不在 Core 猜测，避免把业务 nil 强制变成 `{}`。
                outputNode[key] = {}
                restored = restored + 1
            elseif type(defaultValue) == "table" then
                local child = type(sourceValue) == "table" and DeepCopy(sourceValue) or {}
                local before = restored
                Restore(defaultValue, sourceValue, child)
                if restored > before then outputNode[key] = child end
            end
        end
    end

    Restore(defaults, source, recovered)
    if restored < 1 or restored > limit then return nil, nil end

    local historicalCanonical = self:CanonicalIntegrityValue(store, recovered)
    if type(historicalCanonical) ~= "table" then return nil, nil end
    local fingerprint = self:FingerprintCanonicalValue(store, historicalCanonical)
    local matched = fingerprint ~= nil and tostring(fingerprint) == tostring(stampedFingerprint)
    store.lastHistoricalRecoveryProbe = "framework2_serializer_omissions=" .. tostring(restored)
        .. "/matched=" .. tostring(matched == true)
    if matched ~= true then return nil, nil end
    return historicalCanonical, recovered
end

-- 完整替换只允许已确认归属的内容错误；读失败、未知格式、owner/scope 不符或未来版本不能丢弃。
-- 错误白名单不能放宽成整个 metadata/envelope/integrity 前缀，否则旧键碰撞时可能覆盖另一角色。
local function IsRecoverableReplacementFence(reason)
    reason = tostring(reason or "")
    return reason == "decode_failed"
        or reason:match("^integrity_failed:fingerprint_") ~= nil
        or reason:match("^integrity_failed:decode_failed:") ~= nil
        or reason:match("^envelope_integrity_failed:envelope_fingerprint_") ~= nil
        or reason:match("^encoded_load_rejected:") ~= nil
        or reason:match("^decoded_load_rejected:") ~= nil
        or reason:match("^transport_decode_failed:") ~= nil
end

local REPLACEMENT_METADATA_BUDGET = { maxDepth = 4, maxNodes = 96, maxStringBytes = 4096, maxEntriesPerTable = 32 }

local function ReplacementMetadataOwnership(store, meta, expectedScopeFingerprint)
    if type(meta) ~= "table" then return false, "replacement_metadata_missing" end
    for _, field in ipairs({ "store", "owner", "lifetime", "scope" }) do
        if NonEmptyText(meta[field]) == nil or tostring(meta[field]) ~= tostring(store[field == "store" and "id" or field]) then
            return false, "replacement_metadata_mismatch:" .. field
        end
    end
    -- schema 等版本即使被更早的 payload/transport 错误遮住，也不能获得完整替换许可。这里仅检查冷加载
    -- 提取的元数据，不修改 stamp、canonical 或物理键；缺失/非整数版本也不足以证明当前构建理解该档。
    local function Supported(value, maximum)
        local version = tonumber(value)
        return version ~= nil and version >= 1 and version == math.floor(version) and version <= maximum
    end
    for _, entry in ipairs({
        { "framework", P.FrameworkVersion }, { "contractVersion", store.contractVersion },
        { "schema", store.schemaVersion }, { "reliabilityContract", P.ReliabilityContractVersion },
        { "integrityVersion", P.IntegrityContractVersion }, { "envelopeIntegrityVersion", P.EnvelopeIntegrityContractVersion },
    }) do
        if not Supported(meta[entry[1]], entry[2]) then return false, "replacement_unsupported_metadata:" .. entry[1] end
    end
    if tonumber(meta.framework) >= 3 and not Supported(meta.transportVersion, P.SupportedTransportContractVersion) then
        return false, "replacement_unsupported_metadata:transportVersion"
    end
    if store.scope == SCOPE.Character then
        if tonumber(meta.scopeBindingContract) ~= tonumber(P.ScopeBindingContractVersion) then
            return false, "replacement_scope_binding_contract"
        end
        -- 迁移只读检查可显式提供候选章的身份以验证其完整元数据；所有原有替换调用不传第三参数，仍严格绑定
        -- 当前 Store 身份，不能借迁移检查放宽 CanReplaceCorrupt 的跨角色写隔离。
        local expectedFingerprint = expectedScopeFingerprint or store.resolvedScopeFingerprint
        if NonEmptyText(meta.scopeIdentityFingerprint) == nil or expectedFingerprint == nil
            or tostring(meta.scopeIdentityFingerprint) ~= tostring(expectedFingerprint) then
            return false, "replacement_scope_identity_fingerprint"
        end
    end
    return true, nil
end

local function PhysicalReplacementOwnership(store, raw)
    local meta = type(raw) == "table" and raw.__rsmeta or nil
    if type(meta) ~= "table" then return false, "replacement_metadata_missing" end
    local inspection = P:InspectPayload(meta, REPLACEMENT_METADATA_BUDGET)
    if inspection.ok ~= true then return false, "replacement_metadata_rejected:" .. tostring(inspection.reason) end
    -- 截断 payload 可使整个 transport 在正常 metadata 门之前失败。只解码有界的 metadata 副本，独立核对
    -- 归属/版本；绝不解码或信任损坏的业务内容。没有完整归属证据的裸表/旧档仍隔离，不能按默认值认领。
    local decoded, err = P:DecodePhysicalEnvelope({ __rsmeta = DeepCopy(meta) })
    if decoded == nil then return false, "replacement_metadata_decode_failed:" .. tostring(err) end
    return ReplacementMetadataOwnership(store, decoded.__rsmeta)
end

-- 有损旧键可能对应多个角色，不能凭有值就认领，损坏候选也不能当新档。
-- 自己的旧候选仍走完整加载链；明确属于外角色且业务章可信时，才允许在当前角色新键创建默认档。
local function InspectLegacyCharacterSource(store, physicalRaw, currentFingerprint)
    if type(physicalRaw) ~= "table" then return nil, "raw_type" end
    local physicalInspection = P:InspectPayload(physicalRaw, store.encodedBudget)
    if physicalInspection.ok ~= true then return nil, "physical_budget" end
    local physicalMeta = physicalRaw.__rsmeta
    if type(physicalMeta) ~= "table" then return nil, "metadata_missing" end
    local metaInspection = P:InspectPayload(physicalMeta, REPLACEMENT_METADATA_BUDGET)
    if metaInspection.ok ~= true then return nil, "metadata_budget" end
    local metadataRaw, metadataError = P:DecodePhysicalEnvelope({ __rsmeta = DeepCopy(physicalMeta) })
    if metadataRaw == nil or metadataError ~= nil then return nil, "metadata_decode:" .. tostring(metadataError) end
    local meta = metadataRaw.__rsmeta
    local stampedIdentity = type(meta) == "table" and meta.scopeIdentityFingerprint or nil
    if type(stampedIdentity) ~= "string" or #stampedIdentity ~= 16 or stampedIdentity:find("[^%x]") ~= nil then
        return nil, "identity_stamp_missing"
    end
    local ownedMetadata, metadataReason = ReplacementMetadataOwnership(store, meta, stampedIdentity)
    if ownedMetadata ~= true then return nil, tostring(metadataReason) end
    if (tonumber(meta.reliabilityContract) or 0) < 6 or NonEmptyText(meta.envelopeFingerprint) == nil
        or NonEmptyText(meta.encodedFingerprint or meta.payloadFingerprint) == nil then return nil, "envelope_stamp_missing" end
    local actualEnvelope = P:FingerprintEnvelopeIntegrity(metadataRaw)
    if actualEnvelope == nil or tostring(actualEnvelope) ~= tostring(meta.envelopeFingerprint) then return nil, "envelope_fingerprint" end
    if stampedIdentity == currentFingerprint then return "owned", nil end

    -- Foreign 只运行已约定为纯函数的 decoder/canonicalizer，绝不应用外角色数据。内容盲 v3 或需要恢复候选
    -- 才能证明的外国档不在此认定健康；保持隔离，比猜测并创建新档更安全。
    local raw, transportError = P:DecodePhysicalEnvelope(physicalRaw)
    if raw == nil or transportError ~= nil then return nil, "foreign_transport:" .. tostring(transportError) end
    local actualFingerprint, fingerprintError
    local integrityVersion = tonumber(meta.integrityVersion)
    if integrityVersion == tonumber(P.IntegrityContractVersion) then
        local value, decodeError = DecodeValue(store, raw)
        if value == nil or decodeError ~= nil then return nil, "foreign_decode:" .. tostring(decodeError) end
        local decodedInspection = P:InspectPayload(value, store.budget)
        if decodedInspection.ok ~= true then return nil, "foreign_decoded_budget" end
        local canonical, canonicalError = P:CanonicalIntegrityValue(store, value)
        if canonical == nil then return nil, "foreign_canonical:" .. tostring(canonicalError) end
        actualFingerprint, fingerprintError = P:FingerprintCanonicalValue(store, canonical)
    elseif integrityVersion == tonumber(P.PreCanonicalIntegrityContractVersion) then
        actualFingerprint, fingerprintError = P:FingerprintEncodedPayload(raw, store.encodedBudget)
    elseif integrityVersion == tonumber(P.LegacyIntegrityContractVersion) then
        actualFingerprint, fingerprintError = P:FingerprintEncodedPayloadV1(raw, store.encodedBudget)
    else return nil, "foreign_integrity_contract" end
    if actualFingerprint == nil then return nil, "foreign_fingerprint:" .. tostring(fingerprintError) end
    if tostring(actualFingerprint) ~= tostring(meta.encodedFingerprint or meta.payloadFingerprint) then return nil, "foreign_payload_fingerprint" end
    return "foreign", nil
end

-- 显式恢复 UI 与 SaveValue 共用这个替换许可检查；许可绑定本次加载和角色，切角色即失效。
function P:CanReplaceCorrupt(id)
    local store = self:GetStore(id)
    if store == nil then return false, "unknown store" end
    if store.recoverableReplacement ~= true then return false, "store_replacement_not_enabled" end
    if store.writeFenced ~= true or not IsRecoverableReplacementFence(store.writeFenceReason) then
        return false, store.writeFenceReason or "store_not_write_fenced"
    end
    if store.replacementOwnershipOk ~= true then
        return false, store.replacementOwnershipError or "replacement_ownership_unverified"
    end
    local bindingOk, bindingErr = CurrentScopeBinding(store)
    if bindingOk ~= true then return false, bindingErr end
    return true, nil
end

-- 字符串索引恢复仅在当前代际/schema 失配时尝试一次，先通过身份、seal 和预算。
-- 预期值、磁盘章、候选和当前 canonical 四者 Hash 须一致；失败保留原拒绝，不 Apply/Save 或借用 known-pair。
local function VerifyReadbackRepresentation(store, raw, actual, canonical, expectedFingerprint)
    local meta = type(raw) == "table" and raw.__rsmeta or nil
    if store.recoverReadbackRepresentation ~= true or type(store.rebuildCanonicalForIntegrity) ~= "function"
        or type(meta) ~= "table" or tonumber(meta.framework) ~= P.FrameworkVersion
        or tonumber(meta.schema) ~= store.schemaVersion or tonumber(meta.transportVersion) ~= (store.transportVersion or P.TransportContractVersion)
        or tonumber(meta.integrityVersion) ~= P.IntegrityContractVersion
        or tostring(meta.encodedFingerprint or meta.payloadFingerprint) ~= tostring(expectedFingerprint) then
        return false
    end
    local loadProbe = store.lastHistoricalRecoveryProbe
    local ok, candidate, recoveredDomain = pcall(store.rebuildCanonicalForIntegrity,
        DeepCopy(actual), expectedFingerprint, DeepCopy(canonical), DeepCopy(raw))
    local probe = store.lastHistoricalRecoveryProbe
    store.lastHistoricalRecoveryProbe = loadProbe -- 只读回读不能污染真实 Load 的失败证据。
    store.lastReadbackRecoveryProbe = tostring(probe or "hook_no_probe"):sub(1, 200)
    if not ok or type(candidate) ~= "table" or type(recoveredDomain) ~= "table" then return false end
    local candidateFingerprint = P:FingerprintCanonicalValue(store, candidate)
    if candidateFingerprint == nil or tostring(candidateFingerprint) ~= tostring(expectedFingerprint) then return false end
    local inspection = P:InspectPayload(recoveredDomain, store.budget)
    if type(inspection) ~= "table" or inspection.ok ~= true then return false end
    local currentCanonical = P:CanonicalIntegrityValue(store, recoveredDomain)
    if type(currentCanonical) ~= "table" then return false end
    local currentFingerprint = P:FingerprintCanonicalValue(store, currentCanonical)
    if currentFingerprint == nil or tostring(currentFingerprint) ~= tostring(expectedFingerprint) then return false end
    store.lastReadbackRepresentationRecovered = true
    return true
end

-- SaveData=true 不代表耐久；关键 Store 可选写后回读，普通去抖设置避免每次加倍 I/O。
-- 回读只 decode，不调用 apply。
function P:TryRepairPhysicalTransport(store, raw, transportErr)
    if type(store) ~= "table" or type(raw) ~= "table" or type(store.repairPhysicalTransport) ~= "function" then
        return nil, transportErr or "transport_decode_failed", nil
    end
    store.lastPhysicalTransportRepairOk = false
    store.lastPhysicalTransportRepairError = nil
    store.lastPhysicalTransportRepairProbe = nil
    local ok, candidate, probe = pcall(store.repairPhysicalTransport, DeepCopy(raw), tostring(transportErr or "unknown"))
    store.lastPhysicalTransportRepairProbe = NonEmptyText(probe)
    if ok ~= true or type(candidate) ~= "table" then
        store.lastPhysicalTransportRepairError = ok and tostring(probe or "no_candidate") or tostring(candidate)
        return nil, transportErr or "transport_decode_failed", nil
    end
    local inspection = self:InspectPayload(candidate, store.encodedBudget)
    if type(inspection) ~= "table" or inspection.ok ~= true then
        store.lastPhysicalTransportRepairError = "candidate_budget:" .. tostring(inspection and inspection.reason or "unknown")
        return nil, transportErr or "transport_decode_failed", nil
    end
    local decoded, decodeErr = self:DecodePhysicalEnvelope(candidate)
    if decoded == nil then
        store.lastPhysicalTransportRepairError = "candidate_decode:" .. tostring(decodeErr or "unknown")
        return nil, transportErr or "transport_decode_failed", nil
    end
    store.lastPhysicalTransportRepairOk = true
    store.lastPhysicalTransportRepairError = nil
    store.lastPhysicalTransportRepairAt = NowMs()
    self.stats.physicalTransportRepairs = (tonumber(self.stats.physicalTransportRepairs) or 0) + 1
    Emit("warning", "STORE_PHYSICAL_TRANSPORT_REPAIRED", "物理传输表依据 Store 的确定性冗余候选完成重建；仍需通过 Envelope/业务指纹后才允许应用", {
        store = store.id, transportError = tostring(transportErr or "unknown"), probe = store.lastPhysicalTransportRepairProbe,
    })
    return decoded, nil, candidate
end

function P:VerifyPersistedValue(storeOrId, expectedValue, resolvedKey)
    local store = type(storeOrId) == "table" and storeOrId or self:GetStore(storeOrId)
    if store == nil then return false, "unknown store" end
    if store.lifetime == LIFETIME.Session then return true end
    if S.Api == nil or type(S.Api.LoadData) ~= "function" then return false, "LoadData unavailable" end

    local key, keyErr = resolvedKey, nil
    if key == nil then key, keyErr = self:ResolveStoreKey(store) end
    if key == nil then return false, keyErr or "store key unavailable" end

    self.stats.readbackVerifyAttempts = (tonumber(self.stats.readbackVerifyAttempts) or 0) + 1
    store.lastVerifyAt = NowMs()
    -- 每次真正回读独立留证，不复用上次成功结果，也不清 Load 探针。
    store.lastReadbackRecoveryProbe = nil
    store.lastReadbackRepresentationRecovered = false
    store.lastPhysicalTransportRepairOk = false
    store.lastPhysicalTransportRepairError = nil
    store.lastPhysicalTransportRepairProbe = nil
    local function Fail(reason)
        reason = tostring(reason or "readback verification failed")
        store.lastVerifyOk = false
        store.lastVerifyFingerprint = nil
        store.lastVerifyError = reason
        self.stats.readbackVerifyFailures = (tonumber(self.stats.readbackVerifyFailures) or 0) + 1
        Emit("error", "STORE_READBACK_VERIFY_FAILED", "SaveData 回读校验失败，不能把本次写入视为已持久化", {
            store = store.id, owner = store.owner, error = reason,
        })
        return false, reason
    end

    local raw, loadErr = self:ReadPhysicalStore(store,key)
    if loadErr ~= nil then return Fail("readback_load_failed:" .. tostring(loadErr)) end
    if raw == nil then return Fail("readback_missing") end
    if type(raw) ~= "table" then return Fail("readback_raw_type:" .. tostring(type(raw))) end

    -- 回读先验物理预算，再解 Transport；完整性和业务 decoder 只能接触还原后的逻辑值。
    local physicalInspection = self:InspectPayload(raw, store.encodedBudget)
    store.lastPhysicalInspection = physicalInspection
    if type(physicalInspection) ~= "table" or physicalInspection.ok ~= true then
        return Fail("readback_physical_payload_rejected:" .. tostring(physicalInspection and physicalInspection.reason or "unknown"))
    end
    local decodedRaw, transportErr = self:DecodePhysicalEnvelope(raw)
    if decodedRaw == nil then
        local repaired, repairErr = self:TryRepairPhysicalTransport(store, raw, transportErr)
        decodedRaw = repaired
        if decodedRaw == nil then return Fail("readback_transport_decode_failed:" .. tostring(repairErr or transportErr or "unknown")) end
    end
    raw = decodedRaw

    local rawInspection = self:InspectPayload(raw, store.encodedBudget)
    if type(rawInspection) ~= "table" or rawInspection.ok ~= true then
        return Fail("readback_encoded_payload_rejected:" .. tostring(rawInspection and rawInspection.reason or "unknown"))
    end

    local meta = type(raw.__rsmeta) == "table" and raw.__rsmeta or nil
    if meta == nil then return Fail("readback_metadata_missing") end
    if tonumber(meta.framework) ~= tonumber(self.FrameworkVersion) then return Fail("readback_metadata_framework") end
    if tostring(meta.store or "") ~= tostring(store.id) then return Fail("readback_metadata_store") end
    if tostring(meta.owner or "") ~= tostring(store.owner) then return Fail("readback_metadata_owner") end
    if tostring(meta.lifetime or "") ~= tostring(store.lifetime) then return Fail("readback_metadata_lifetime") end
    if tostring(meta.scope or "") ~= tostring(store.scope) then return Fail("readback_metadata_scope") end
    if tonumber(meta.schema) ~= tonumber(store.schemaVersion) then return Fail("readback_metadata_schema") end
    if tonumber(meta.contractVersion) ~= tonumber(store.contractVersion) then return Fail("readback_metadata_contract") end

    local readbackIntegrityVersion = tonumber(meta.integrityVersion)
    local canonicalReadback = readbackIntegrityVersion == tonumber(self.IntegrityContractVersion)
    if readbackIntegrityVersion ~= tonumber(self.IntegrityContractVersion)
        and readbackIntegrityVersion ~= tonumber(self.PreCanonicalIntegrityContractVersion) then
        return Fail("readback_metadata_integrity_version:" .. tostring(readbackIntegrityVersion))
    end
    local stampedEncodedFingerprint = NonEmptyText(meta.encodedFingerprint or meta.payloadFingerprint)
    if stampedEncodedFingerprint == nil then return Fail("readback_metadata_fingerprint_missing") end
    if tonumber(meta.reliabilityContract) ~= tonumber(self.ReliabilityContractVersion) then
        return Fail("readback_metadata_reliability_contract")
    end
    if canonicalReadback ~= true then
        -- 旧 v2 原始 envelope 比较只用于仍采用 canonical 前 stamp 的 Store；v3 在下方 decode 后校验
        -- canonical 值，避免 RU 表示变化造成预期外假失败。
        local actualEncodedFingerprint, encodedFingerprintErr = self:FingerprintEncodedPayload(raw, store.encodedBudget)
        if actualEncodedFingerprint == nil then
            return Fail("readback_encoded_fingerprint_failed:" .. tostring(encodedFingerprintErr or "unknown"))
        end
        if tostring(stampedEncodedFingerprint) ~= tostring(actualEncodedFingerprint) then
            return Fail("readback_encoded_fingerprint_mismatch:" .. tostring(stampedEncodedFingerprint) .. ">" .. tostring(actualEncodedFingerprint))
        end
    end

    -- Reliability v6 同时封闭元数据 envelope 和编码业务 payload，检测 v4/v5 纯业务指纹未覆盖的
    -- schema/owner/scope 元数据截断。
    if tonumber(meta.envelopeIntegrityVersion) ~= tonumber(self.EnvelopeIntegrityContractVersion) then
        return Fail("readback_metadata_envelope_integrity_version")
    end
    local stampedEnvelopeFingerprint = NonEmptyText(meta.envelopeFingerprint)
    if stampedEnvelopeFingerprint == nil then return Fail("readback_metadata_envelope_fingerprint_missing") end
    if store.scope == SCOPE.Character then
        if tonumber(meta.scopeBindingContract) ~= tonumber(self.ScopeBindingContractVersion) then
            return Fail("readback_metadata_scope_binding_contract")
        end
        local expectedScopeFingerprint = NonEmptyText(store.resolvedScopeFingerprint)
        local stampedScopeFingerprint = NonEmptyText(meta.scopeIdentityFingerprint)
        if expectedScopeFingerprint == nil or stampedScopeFingerprint == nil
            or tostring(expectedScopeFingerprint) ~= tostring(stampedScopeFingerprint) then
            return Fail("readback_metadata_scope_identity_fingerprint")
        end
    end
    local actualEnvelopeFingerprint, envelopeFingerprintErr = self:FingerprintEnvelopeIntegrity(raw)
    if actualEnvelopeFingerprint == nil then
        return Fail("readback_envelope_fingerprint_failed:" .. tostring(envelopeFingerprintErr or "unknown"))
    end
    if tostring(stampedEnvelopeFingerprint) ~= tostring(actualEnvelopeFingerprint) then
        return Fail("readback_envelope_fingerprint_mismatch:" .. tostring(stampedEnvelopeFingerprint) .. ">" .. tostring(actualEnvelopeFingerprint))
    end

    local actualValue, decodeErr = DecodeValue(store, raw)
    if decodeErr ~= nil then return Fail("readback_decode_failed:" .. tostring(decodeErr)) end
    if actualValue == nil then return Fail("readback_payload_missing") end

    if type(self.FingerprintPayload) ~= "function" then return Fail("fingerprint_unavailable") end
    local expectedFingerprint, expectedErr
    local actualFingerprint, actualErr
    local canonicalExpectedForDiagnostics, canonicalActualForDiagnostics -- 失配时暂留两个有界副本生成首字段差异，函数返回后释放，不写回 Domain。
    if canonicalReadback == true then
        -- v3 在两侧比较 Store canonical 值，使读回证据能容忍加载侧同样吸收的表示变化。
        local canonicalExpected, canonicalExpectedErr = self:CanonicalIntegrityValue(store, expectedValue)
        if canonicalExpected == nil then
            return Fail(tostring(canonicalExpectedErr or "canonical_value_missing"))
        end
        local canonicalActual, canonicalActualErr = self:CanonicalIntegrityValue(store, actualValue)
        if canonicalActual == nil then
            return Fail("readback_canonical_failed:" .. tostring(canonicalActualErr or "unknown"))
        end
        canonicalExpectedForDiagnostics, canonicalActualForDiagnostics = canonicalExpected, canonicalActual
        expectedFingerprint, expectedErr = self:FingerprintCanonicalValue(store, canonicalExpected)
        actualFingerprint, actualErr = self:FingerprintCanonicalValue(store, canonicalActual)
    else
        expectedFingerprint, expectedErr = self:FingerprintDurablePayload(expectedValue, store.budget)
        actualFingerprint, actualErr = self:FingerprintDurablePayload(actualValue, store.budget)
    end
    if expectedFingerprint == nil then return Fail("expected_fingerprint_failed:" .. tostring(expectedErr)) end
    if actualFingerprint == nil then return Fail("readback_fingerprint_failed:" .. tostring(actualErr)) end
    -- 回读须先证明 stamped==expected，再证明 actual==expected；仅比预期与实值会放过旧业务章，导致本次假成功、下次加载失败。
    -- envelope seal 只证明 metadata 自洽，不能替代业务章绑定。不能在验证中重新盖章、写盘或解除写保护。
    -- 旧 integrity-v2 在上方按原 envelope 校验，不能拿其章与 Domain 章比较。
    if canonicalReadback == true and tostring(stampedEncodedFingerprint) ~= tostring(expectedFingerprint) then
        return Fail("readback_stamped_fingerprint_mismatch:" .. tostring(stampedEncodedFingerprint)
            .. ">" .. tostring(expectedFingerprint))
    end
    if canonicalReadback == true and tostring(actualFingerprint) ~= tostring(expectedFingerprint)
        and VerifyReadbackRepresentation(store, raw, actualValue, canonicalActualForDiagnostics, expectedFingerprint) then
        actualFingerprint = expectedFingerprint -- 上述四重等值证明成立，不把候选写回业务 Domain。
    end
    if tostring(actualFingerprint) ~= tostring(expectedFingerprint) then
        local divergence = nil -- 只在失配后按稳定顺序比较，最多 512 节点，指出被序列化器改动的首个字段。
        if canonicalExpectedForDiagnostics ~= nil and canonicalActualForDiagnostics ~= nil
            and type(self.DescribeCanonicalDivergence) == "function" then
            divergence = self:DescribeCanonicalDivergence(canonicalExpectedForDiagnostics, canonicalActualForDiagnostics)
        end
        local detail = divergence ~= nil and ("|divergence=" .. tostring(divergence):gsub("[\r\n]+", " ")) or ""
        return Fail("readback_fingerprint_mismatch:" .. tostring(expectedFingerprint) .. ">" .. tostring(actualFingerprint) .. detail)
    end

    store.lastVerifyOk = true
    store.lastVerifyFingerprint = expectedFingerprint
    store.lastVerifyError = nil
    self.stats.readbackVerifySuccesses = (tonumber(self.stats.readbackVerifySuccesses) or 0) + 1
    return true, nil, expectedFingerprint
end

function P:LoadStore(id, options)
    options = type(options) == "table" and options or {}
    local store = self:GetStore(id)
    if store == nil then return false, nil, "unknown store" end
    -- 不能用磁盘状态覆盖未保存的内存修改；调用者确实要丢弃 dirty 工作数据时须显式说明。此重载隔离归持久化层
    -- ，不能依赖 Feature/页面各自记住。
    if store.lifetime ~= LIFETIME.Session and store.dirty == true and options.discardDirty ~= true then
        self.stats.dirtyReloadRejects = (tonumber(self.stats.dirtyReloadRejects) or 0) + 1
        Count("STORE_DIRTY_RELOAD_REJECTED", 1)
        Emit("warning", "STORE_DIRTY_RELOAD_REJECTED", "存档仍有未落盘修改，已拒绝重新读取以避免覆盖当前配置", {
            store = store.id, owner = store.owner, reason = store.lastDirtyReason, revision = store.dirtyRevision,
        })
        return false, nil, "dirty store reload rejected"
    end
    -- 成功但尚未回读的写入仍有耐久义务；SaveData 可能提前报告成功，不能重载旧值覆盖较新内存。
    -- 只有显式破坏性恢复可丢弃该义务。
    if store.lifetime ~= LIFETIME.Session and store.needsBarrierVerify == true and options.discardUnverified ~= true then
        self.stats.unverifiedReloadRejects = (tonumber(self.stats.unverifiedReloadRejects) or 0) + 1
        Count("STORE_UNVERIFIED_RELOAD_REJECTED", 1)
        Emit("warning", "STORE_UNVERIFIED_RELOAD_REJECTED", "存档写入尚未通过耐久回读，已拒绝重新读取以避免旧磁盘值覆盖当前配置", {
            store = store.id, owner = store.owner, revision = store.dirtyRevision,
            lastVerifyError = store.lastVerifyError,
        })
        return false, nil, "unverified store reload rejected"
    end
    -- 同代际的结构故障不会靠重复 LoadData 修好；缓存终态，避免默认值流程反复读盘和报错。
    -- 新代际、ClearStore 或已验证替换可重新建立状态。
    if store.lifetime ~= LIFETIME.Session and store.loaded == true and store.writeFenced == true
        and options.revalidateTerminal ~= true then
        self.stats.terminalLoadShortCircuits = (tonumber(self.stats.terminalLoadShortCircuits) or 0) + 1
        return false, nil, tostring(store.lastError or store.writeFenceReason or store.loadStatus or "terminal store load failure")
    end
    if store.lifetime == LIFETIME.Session then
        if store.memory == nil then store.memory = select(1, DefaultValue(store)) end
        store.loaded, store.loadStatus, store.lastLoadAt = true, "session", NowMs()
        return true, DeepCopy(store.memory), nil
    end
    if S.Api == nil or type(S.Api.LoadData) ~= "function" then return false, nil, "LoadData unavailable" end
    local resolvedKey, scopeErr, scopeFingerprint, legacyScopeKey = self:ResolveStoreKey(store)
    if resolvedKey == nil then
        store.loaded = false
        store.loadStatus = "scope_pending"
        store.lastError = scopeErr
        return false, nil, scopeErr
    end
    if store.scope == SCOPE.Character and store.resolvedKey ~= nil then
        local keyChanged = tostring(store.resolvedKey) ~= tostring(resolvedKey)
        local identityChanged = store.resolvedScopeFingerprint ~= nil and scopeFingerprint ~= nil
            and tostring(store.resolvedScopeFingerprint) ~= tostring(scopeFingerprint)
        if (keyChanged or identityChanged) and store.needsBarrierVerify == true then
            local reason = "scope_change_barrier_pending"
            store.lastScopeBindingError = reason
            self.stats.scopeBindingMismatches = (tonumber(self.stats.scopeBindingMismatches) or 0) + 1
            return false, nil, reason
        end
        if identityChanged and keyChanged ~= true then
            -- 历史键归一化保持不变以兼容升级；精确带世界名身份折为同一物理 token 时绝不猜所有权。
            local reason = "scope_binding_identity_collision"
            store.loaded = true
            store.loadStatus = "scope_binding_failed"
            store.writeFenced = true
            store.writeFenceReason = reason
            store.lastError = reason
            store.lastScopeBindingError = reason
            self.stats.scopeBindingMismatches = (tonumber(self.stats.scopeBindingMismatches) or 0) + 1
            Emit("error", "STORE_SCOPE_BINDING_COLLISION", "角色级存档身份归一化发生冲突，已拒绝跨角色读取/覆盖", { store = store.id })
            return false, nil, reason
        end
        if keyChanged or identityChanged then
            self.stats.scopeRebinds = (tonumber(self.stats.scopeRebinds) or 0) + 1
        end
    end
    store.resolvedKey = resolvedKey
    store.resolvedScopeFingerprint = scopeFingerprint
    store.lastScopeBindingError = nil

    -- 仅在真正重读前清空上一轮证据，terminal memo 返回则保留故障。
    -- 原实现只重置 trace，回归中会夹带旧 schema 的 probe；诊断不是恢复 Authority。
    store.lastHistoricalRecoveryProbe = nil
    -- 新物理读取清除上一轮数值证据，防止终端失败缓存重验后误用旧样本。
    -- 只存两轴标量/次数，不持有整份raw；普通终端缓存命中不会到达此处。
    store.lastWindowNumericEvidence = nil
    store.lastHistoricalRecoveryHookState = "not_called"
    store.lastIntegrityRecoveryTrace = nil
    store.lastIntegrityMismatchEvidence = nil
    store.lastPhysicalTransportRepairOk = false
    store.lastPhysicalTransportRepairError = nil
    store.lastPhysicalTransportRepairProbe = nil
    -- 归属许可不跨读取复用。失败/空返回也先清证据，防止上一次健康档的所有权替本次未知档背书。
    store.replacementOwnershipOk = false
    store.replacementOwnershipError = "replacement_ownership_unverified"
    local raw, loadErr = self:ReadPhysicalStore(store,resolvedKey)
    local scopeKeyMigration = false
    -- 仅新键明确缺失且读无错时查一次旧键；损坏、未来格式和读失败不能退回旧副本。
    -- 所有排队写入始终绑定新键，旧键不写不删。
    if raw == nil and loadErr == nil and legacyScopeKey ~= nil then
        local legacyRaw, legacyError = self:ReadPhysicalStore(store,legacyScopeKey)
        if legacyError ~= nil then loadErr = legacyError
        elseif legacyRaw ~= nil then
            local ownership, ownershipError = InspectLegacyCharacterSource(store, legacyRaw, scopeFingerprint)
            if ownership == "owned" then
                raw = legacyRaw
                scopeKeyMigration = true
            elseif ownership ~= "foreign" then
                -- 未盖身份章/坏章/不能完整证明的源是终态隔离，不沿用旧 legacy_unstamped 自动认领出口。
                store.loaded, store.loadStatus = true, "scope_migration_failed"
                store.writeFenced = true
                store.writeFenceReason = "legacy_scope_unverified:" .. tostring(ownershipError or "unknown")
                store.lastError = store.writeFenceReason
                self.stats.loadFailures = (tonumber(self.stats.loadFailures) or 0) + 1
                Emit("error", "STORE_SCOPE_MIGRATION_REJECTED", "旧角色键无法证明完整归属，已拒绝迁移和默认值覆盖", { store = store.id })
                return false, nil, store.lastError
            end
            -- 可信 foreign 不 Apply、不 Save，保留旧盘原样；raw 继续为 nil，复用下方新角色空档初始化。
        end
    end
    store.lastLoadAt = NowMs()
    if loadErr ~= nil then
        store.loaded = false
        store.loadStatus = "error"
        store.lastError = tostring(loadErr)
        store.writeFenced = true
        store.writeFenceReason = "load_failed"
        self.stats.loadFailures = (tonumber(self.stats.loadFailures) or 0) + 1
        Emit("error", "STORE_LOAD_FAILED", "读取独立存档失败，已启用写保护", { store = store.id, owner = store.owner, error = loadErr })
        return false, nil, tostring(loadErr)
    end
    if raw == nil then
        local fresh, defaultErr = DefaultValue(store)
        if defaultErr ~= nil then
            store.loaded = true
            store.loadStatus = "default_failed"
            store.writeFenced = true
            store.writeFenceReason = "default_failed"
            store.lastError = tostring(defaultErr)
            return false, nil, tostring(defaultErr)
        end
        if options.apply ~= false then
            local applied, applyErr = ApplyValue(store, fresh, "empty")
            if applied ~= true then
                store.loaded = true
                store.loadStatus = "apply_failed"
                store.writeFenced = true
                store.writeFenceReason = "apply_failed"
                store.lastError = tostring(applyErr)
                Emit("error", "STORE_APPLY_FAILED", "空存档默认值应用失败，已启用写保护", { store = store.id, error = applyErr })
                return false, nil, tostring(applyErr)
            end
        end
        store.loaded = true
        store.loadStatus = "empty"
        store.lastError = nil
        store.writeFenced = false
        store.writeFenceReason = nil
        store.needsBarrierVerify = false
        store.dirty, store.dueAt, store.firstDirtyAt = false, 0, 0
        store.lastDirtyAt, store.lastDirtyReason = 0, nil
        return "empty", DeepCopy(fresh), nil
    end
    if type(raw) ~= "table" then
        store.loaded = true
        store.loadStatus = "decode_failed"
        store.lastError = "unexpected raw type: " .. tostring(type(raw))
        store.writeFenced = true
        store.writeFenceReason = "decode_failed"
        self.stats.corruptEmptyRejects = (tonumber(self.stats.corruptEmptyRejects) or 0) + 1
        self.stats.loadFailures = (tonumber(self.stats.loadFailures) or 0) + 1
        Emit("error", "STORE_DECODE_FAILED", "存档返回了非表且非空的数据，禁止按空存档处理以避免覆盖旧配置", {
            store = store.id, rawType = type(raw),
        })
        return false, nil, store.lastError
    end

    if store.recoverableReplacement == true then
        store.replacementOwnershipOk, store.replacementOwnershipError = PhysicalReplacementOwnership(store, raw)
    end

    -- 先验物理预算并解 Transport，再处理 metadata/canonical/decode/apply。
    -- 未来版本或损坏 Transport 必须隔离，不能当空档用默认值覆盖。
    local physicalTransportRepairNeeded = false
    local physicalLoadInspection = self:InspectPayload(raw, store.encodedBudget)
    store.lastPhysicalInspection = physicalLoadInspection
    if type(physicalLoadInspection) ~= "table" or physicalLoadInspection.ok ~= true then
        store.loaded = true
        store.loadStatus = "encoded_load_rejected"
        store.lastError = "physical_load_rejected:" .. tostring(physicalLoadInspection and physicalLoadInspection.reason or "unknown")
        store.writeFenced = true
        store.writeFenceReason = store.lastError
        self.stats.encodedLoadRejects = (tonumber(self.stats.encodedLoadRejects) or 0) + 1
        self.stats.loadFailures = (tonumber(self.stats.loadFailures) or 0) + 1
        Emit("error", "STORE_PHYSICAL_LOAD_REJECTED", "读取到的物理存档外壳超过安全预算，已在 transport 解码前阻止读取", {
            store = store.id, reason = physicalLoadInspection and physicalLoadInspection.reason or "unknown",
        })
        return false, nil, store.lastError
    end
    local transportRaw, transportErr = self:DecodePhysicalEnvelope(raw)
    if transportRaw == nil then
        local repaired, repairErr = self:TryRepairPhysicalTransport(store, raw, transportErr)
        if repaired ~= nil then
            transportRaw = repaired
            physicalTransportRepairNeeded = true
        else
            store.loaded = true
            store.loadStatus = "transport_decode_failed"
            store.lastError = "transport_decode_failed:" .. tostring(repairErr or transportErr or "unknown")
            store.writeFenced = true
            store.writeFenceReason = store.lastError
            self.stats.loadFailures = (tonumber(self.stats.loadFailures) or 0) + 1
            Emit("error", "STORE_TRANSPORT_DECODE_FAILED", "Framework3 物理存档传输编码无法还原，已启用写保护", { store = store.id, error = tostring(repairErr or transportErr or "unknown") })
            return false, nil, store.lastError
        end
    end
    raw = transportRaw
    -- 有界 physical repair 可能恢复 metadata；只有通过生产 transport 的当前结果才可更新归属证据。
    if store.recoverableReplacement == true then
        store.replacementOwnershipOk, store.replacementOwnershipError = ReplacementMetadataOwnership(store, raw.__rsmeta)
    end

    -- Reliability v4 在读和写两侧验证编码 envelope；不能因截断或畸形值技术上仍是 Lua 表，就允许进入业务
    -- decoder/apply。遍历仅发生在持久化冷边界，不进入 Feature Tick。
    local encodedLoadInspection = self:InspectPayload(raw, store.encodedBudget)
    store.lastEncodedInspection = encodedLoadInspection
    if type(encodedLoadInspection) ~= "table" or encodedLoadInspection.ok ~= true then
        store.loaded = true
        store.loadStatus = "encoded_load_rejected"
        store.lastError = "encoded_load_rejected:" .. tostring(encodedLoadInspection and encodedLoadInspection.reason or "unknown")
        store.writeFenced = true
        store.writeFenceReason = store.lastError
        self.stats.encodedLoadRejects = (tonumber(self.stats.encodedLoadRejects) or 0) + 1
        self.stats.loadFailures = (tonumber(self.stats.loadFailures) or 0) + 1
        Emit("error", "STORE_ENCODED_LOAD_REJECTED", "读取到的存档外壳不满足安全预算，已阻止解码/应用", {
            store = store.id, reason = encodedLoadInspection and encodedLoadInspection.reason or "unknown",
        })
        return false, nil, store.lastError
    end

    local meta = type(raw.__rsmeta) == "table" and raw.__rsmeta or nil
    if meta ~= nil then
        local mismatch = nil
        local metaFramework = tonumber(meta.framework)
        local metaContract = tonumber(meta.contractVersion)
        local metaReliability = tonumber(meta.reliabilityContract)
        if metaFramework ~= nil and metaFramework > (tonumber(self.FrameworkVersion) or 3) then mismatch = "framework"
        elseif metaReliability ~= nil and metaReliability > (tonumber(self.ReliabilityContractVersion) or 0) then mismatch = "reliabilityContract"
        elseif metaContract ~= nil and metaContract > (tonumber(store.contractVersion) or 1) then mismatch = "contractVersion"
        elseif NonEmptyText(meta.store) ~= nil and tostring(meta.store) ~= tostring(store.id) then mismatch = "store"
        elseif NonEmptyText(meta.owner) ~= nil and tostring(meta.owner) ~= tostring(store.owner) then mismatch = "owner"
        elseif NonEmptyText(meta.lifetime) ~= nil and tostring(meta.lifetime) ~= tostring(store.lifetime) then mismatch = "lifetime"
        elseif NonEmptyText(meta.scope) ~= nil and tostring(meta.scope) ~= tostring(store.scope) then mismatch = "scope" end
        if mismatch ~= nil then
            store.loaded = true
            store.loadStatus = "metadata_mismatch"
            store.writeFenced = true
            store.writeFenceReason = "metadata_mismatch:" .. mismatch
            store.lastError = store.writeFenceReason
            self.stats.metadataMismatches = (tonumber(self.stats.metadataMismatches) or 0) + 1
            Emit("error", "STORE_METADATA_MISMATCH", "独立存档元数据与注册契约不一致，已启用写保护", {
                store = store.id, field = mismatch, metaStore = meta.store, metaLifetime = meta.lifetime, metaScope = meta.scope,
            })
            return false, nil, store.writeFenceReason
        end
    end

    -- Reliability v6 为关键元数据添加独立 envelope seal，并保留 v4/v5 编码业务指纹。业务指纹仍不依赖
    -- decoder/schema；seal 在运行 decoder 前发现仅元数据截断或跨 scope 替换。
    local metaReliabilityContract = meta and tonumber(meta.reliabilityContract) or nil
    local stampedEnvelopeVersion = meta and tonumber(meta.envelopeIntegrityVersion) or nil
    local stampedEnvelopeFingerprint = meta and NonEmptyText(meta.envelopeFingerprint) or nil
    -- v2_ 角色新键只由带章写者创建，metadata 缺失时不能按 legacy_unstamped 认领。
    -- 旧键迁移已独立证明归属；ASCII/Account 继续原历史兼容规则。
    local envelopeAdvertised = (legacyScopeKey ~= nil and scopeKeyMigration ~= true)
        or stampedEnvelopeFingerprint ~= nil or stampedEnvelopeVersion ~= nil
        or (metaReliabilityContract ~= nil and metaReliabilityContract >= 6)
    if envelopeAdvertised then
        self.stats.envelopeIntegrityLoadChecks = (tonumber(self.stats.envelopeIntegrityLoadChecks) or 0) + 1
        local envelopeIntegrityErr = nil
        if meta == nil then
            envelopeIntegrityErr = "metadata_missing"
        elseif metaReliabilityContract == nil or metaReliabilityContract < 6
            or metaReliabilityContract > (tonumber(self.ReliabilityContractVersion) or 0) then
            envelopeIntegrityErr = "reliability_contract:" .. tostring(metaReliabilityContract)
        elseif stampedEnvelopeVersion ~= tonumber(self.EnvelopeIntegrityContractVersion) then
            envelopeIntegrityErr = "envelope_version:" .. tostring(stampedEnvelopeVersion)
        elseif stampedEnvelopeFingerprint == nil then
            envelopeIntegrityErr = "envelope_fingerprint_missing"
        elseif meta.framework == nil or NonEmptyText(meta.store) == nil or NonEmptyText(meta.owner) == nil
            or meta.contractVersion == nil or NonEmptyText(meta.lifetime) == nil or NonEmptyText(meta.scope) == nil
            or meta.schema == nil or meta.reliabilityContract == nil or meta.integrityVersion == nil
            or NonEmptyText(meta.encodedFingerprint or meta.payloadFingerprint) == nil then
            envelopeIntegrityErr = "required_metadata_missing"
        elseif store.scope == SCOPE.Character and tonumber(meta.scopeBindingContract) ~= tonumber(self.ScopeBindingContractVersion) then
            envelopeIntegrityErr = "scope_binding_contract:" .. tostring(meta.scopeBindingContract)
        elseif store.scope == SCOPE.Character and (NonEmptyText(meta.scopeIdentityFingerprint) == nil
            or scopeFingerprint == nil or tostring(meta.scopeIdentityFingerprint) ~= tostring(scopeFingerprint)) then
            envelopeIntegrityErr = "scope_identity_fingerprint"
        else
            local actualEnvelopeFingerprint, actualEnvelopeErr = self:FingerprintEnvelopeIntegrity(raw)
            if actualEnvelopeFingerprint == nil then
                envelopeIntegrityErr = "envelope_fingerprint_failed:" .. tostring(actualEnvelopeErr or "unknown")
            elseif tostring(actualEnvelopeFingerprint) ~= tostring(stampedEnvelopeFingerprint) then
                envelopeIntegrityErr = "envelope_fingerprint_mismatch:" .. tostring(stampedEnvelopeFingerprint) .. ">" .. tostring(actualEnvelopeFingerprint)
            end
        end
        if envelopeIntegrityErr ~= nil then
            store.loaded = true
            store.loadStatus = "envelope_integrity_failed"
            store.writeFenced = true
            store.writeFenceReason = "envelope_integrity_failed:" .. tostring(envelopeIntegrityErr)
            store.lastError = store.writeFenceReason
            self.stats.envelopeIntegrityLoadFailures = (tonumber(self.stats.envelopeIntegrityLoadFailures) or 0) + 1
            self.stats.loadFailures = (tonumber(self.stats.loadFailures) or 0) + 1
            Emit("error", "STORE_ENVELOPE_INTEGRITY_FAILED", "存档元数据封印校验失败，已在业务解码前阻止读取/应用", {
                store = store.id, error = envelopeIntegrityErr,
            })
            return false, nil, store.lastError
        end
    end

    local storedSchema = meta and tonumber(meta.schema) or tonumber(store.legacySchemaVersion) or 0
    if storedSchema > store.schemaVersion then
        store.loaded = true
        store.loadStatus = "future_schema"
        store.writeFenced = true
        store.writeFenceReason = "future_schema:" .. tostring(storedSchema) .. ">" .. tostring(store.schemaVersion)
        store.lastError = store.writeFenceReason
        Emit("warning", "STORE_FUTURE_SCHEMA", "独立存档来自更高 Schema，当前版本只读保护", {
            store = store.id, storedSchema = storedSchema, currentSchema = store.schemaVersion,
        })
        return false, nil, store.writeFenceReason
    end

    -- 跨重载业务完整性：Integrity v2 只归一化非整数表示，避免 RU SaveData 浮点变化造成假损坏隔离；v1 仍可读
    -- 取。v1 非关键设置 Store 业务哈希不匹配但 v6+ 元数据 seal 有效时，允许单代兼容加载；decode、预算、迁移
    -- 、apply 全成功后立即排队盖 v2 stamp。关键/journal Store 继续失败封闭，不使用该兼容出口。
    local stampedFingerprint = meta and NonEmptyText(meta.encodedFingerprint or meta.payloadFingerprint) or nil
    local stampedIntegrityVersion = meta and tonumber(meta.integrityVersion) or nil
    local stampedReliabilityContract = meta and tonumber(meta.reliabilityContract) or nil
    local minIntegrityReliability = tonumber(self.MinIntegrityReliabilityContractVersion) or 4
    local currentReliability = tonumber(self.ReliabilityContractVersion) or minIntegrityReliability
    local currentIntegrity = tonumber(self.IntegrityContractVersion) or 4
    local contentBlindIntegrity = tonumber(self.ContentBlindCanonicalContractVersion) or 3
    local preCanonicalIntegrity = tonumber(self.PreCanonicalIntegrityContractVersion) or 2
    local legacyIntegrity = tonumber(self.LegacyIntegrityContractVersion) or 1
    local integrityAdvertised = stampedFingerprint ~= nil or stampedIntegrityVersion ~= nil
        or (stampedReliabilityContract ~= nil and stampedReliabilityContract >= minIntegrityReliability)
    local legacyIntegrityUpgradeNeeded = false
    local integrityUpgradeNeeded = false
    local preDecodedValue = nil
    local serializerRepairNeeded = false
    local serializerRepairedRaw = nil
    -- 记录恢复计数起点，在函数末尾用增量判断本次是否恢复，避免深层分支局部变量超出作用域。
    local recoveriesAtEntry = tonumber(self.stats.integrityUpgradeRecoveries) or 0
    -- 真实读取前已统一清理证据；此处只追加本次契约世代，不复用旧探针。
    AppendIntegrityRecoveryTrace(store, "iv=" .. tostring(stampedIntegrityVersion)
        .. ",rel=" .. tostring(stampedReliabilityContract)
        .. ",fw=" .. tostring(meta and meta.framework or nil)
        .. ",s=" .. tostring(storedSchema)
        .. ",tv=" .. tostring(meta and meta.transportVersion or nil)
        .. ",c=" .. tostring(type(raw) == "table" and raw.codec or nil)
        .. ",env=" .. tostring(envelopeAdvertised == true and 1 or 0))
    if integrityAdvertised then
        self.stats.integrityLoadChecks = (tonumber(self.stats.integrityLoadChecks) or 0) + 1
        local integrityErr = nil
        if stampedReliabilityContract == nil or stampedReliabilityContract < minIntegrityReliability
            or stampedReliabilityContract > currentReliability then
            integrityErr = "reliability_contract:" .. tostring(stampedReliabilityContract)
        elseif stampedIntegrityVersion == contentBlindIntegrity then
            -- 早期 Integrity v3 只描述默认形状，不能证明内容；按缺章走单代门禁，完整业务链通过后盖修复后的 v4 章。
            local decoded, decodeErr = DecodeValue(store, raw)
            local upgradedInspection = nil
            if decoded ~= nil then upgradedInspection = self:InspectPayload(decoded, store.budget) end
            if store.allowIntegrityUpgrade == true
                and (tonumber(stampedReliabilityContract) or 0) >= minIntegrityReliability
                and envelopeAdvertised == true
                and decoded ~= nil
                and type(upgradedInspection) == "table" and upgradedInspection.ok == true then
                integrityUpgradeNeeded = true
                local canonical, canonicalErr = self:CanonicalIntegrityValue(store, decoded)
                if type(canonical) == "table"
                    and not (type(store.encode) == "function" and type(store.decode) == "function") then
                    decoded = canonical
                end
                preDecodedValue = decoded
                store.lastIntegrityStatus = "integrity_contract_upgrade_recovery"
                store.lastIntegrityFingerprint = stampedFingerprint
                store.lastIntegrityError = "content_blind_canonical_stamp"
                self.stats.integrityUpgradeRecoveries = (tonumber(self.stats.integrityUpgradeRecoveries) or 0) + 1
                Emit("info", "STORE_INTEGRITY_CONTRACT_UPGRADE_RECOVERY",
                    "v3 内容盲盖章无法作为完整性证据；元数据封印与业务校验全部通过，按契约升级加载并在保存时重盖 v4 canonical 指纹", {
                        store = store.id, oldFingerprint = stampedFingerprint,
                    })
            else
                integrityErr = "fingerprint_mismatch:" .. tostring(stampedFingerprint)
                    .. "|contract_upgrade_gate=reliability:" .. tostring(stampedReliabilityContract)
                    .. "/optOut:" .. tostring(store.allowIntegrityUpgrade == false)
                    .. "/decode:" .. tostring(decoded ~= nil)
                    .. "/budget:" .. tostring(type(upgradedInspection) == "table" and upgradedInspection.ok == true)
            end
        elseif stampedIntegrityVersion == currentIntegrity then
            -- Integrity v4 校验 canonical 值而非原始编码 envelope。此前元数据 seal 和原始预算已通过，decode
            -- 得到与成功旧检查相同的输入；本仓 decoder 是纯归一化器。保持逻辑的 RU 表示变化由重新 canonical
            -- 化吸收，内容损坏不能被吸收。
            local decoded, decodeErr = DecodeValue(store, raw)
            if decoded == nil then
                integrityErr = "decode_failed:" .. tostring(decodeErr or "decoded payload missing")
            else
                local canonical, canonicalErr = self:CanonicalIntegrityValue(store, decoded)
                if canonical == nil then
                    integrityErr = "fingerprint_failed:" .. tostring(canonicalErr or "canonical_value_missing")
                else
                    local actualFingerprint, actualErr = self:FingerprintCanonicalValue(store, canonical)
                    if actualFingerprint == nil then
                        integrityErr = "fingerprint_failed:" .. tostring(actualErr or "unknown")
                    elseif tostring(actualFingerprint) ~= tostring(stampedFingerprint) then
                        AppendIntegrityRecoveryTrace(store, "v4=mis,new=" .. tostring(actualFingerprint)) -- 只缓存当前 v4 分支的版本/Hash。失配后仅可尝试确定性历史重建，候选必须精确复现旧指纹，且独立 seal 已通过。
                        local rawProof = type(store.encode) == "function" and type(store.decode) == "function"
                            and self:FingerprintEncodedPayload(raw, store.encodedBudget)
                            or self:FingerprintCanonicalValue(store, decoded)
                        store.lastIntegrityMismatchEvidence = {
                            storedSchema = storedSchema, currentSchema = store.schemaVersion,
                            framework = meta and meta.framework, transportVersion = meta and meta.transportVersion,
                            codec = raw.codec, stampedFingerprint = stampedFingerprint,
                            actualFingerprint = actualFingerprint, rawFingerprint = rawProof,
                        }
                        local recoveredHistoricalCanonical = false
                        if envelopeAdvertised == true and store.allowIntegrityUpgrade == true then
                            local decodedInspection = self:InspectPayload(decoded, store.budget)
                            AppendIntegrityRecoveryTrace(store, "db=" .. tostring(type(decodedInspection) == "table" and decodedInspection.ok == true and 1 or 0))
                            if type(decodedInspection) == "table" and decodedInspection.ok == true then
                                -- 先尝试 Core 能证明的 Framework2 false/空表省略，再交给 Store 自定义 hook；两者都须命中同一旧指纹。
                                local rebuiltOk, historicalCanonical, recoveredDomain = pcall(
                                    self.RebuildFramework2SerializerOmissions, self, store, DeepCopy(decoded),
                                    stampedFingerprint, DeepCopy(raw))
                                AppendIntegrityRecoveryTrace(store, "coreF2=" .. tostring(rebuiltOk == true and type(historicalCanonical) == "table" and "cand" or (rebuiltOk == true and "skip" or "err"))) -- typed Store 通常跳过 Core 候选，此记录用于发现意外抢先恢复。
                                if rebuiltOk ~= true or type(historicalCanonical) ~= "table" then
                                    if type(store.rebuildCanonicalForIntegrity) == "function" then
                                        -- 原始 envelope 作为第四参，旧 Lua hook 可忽略。hook 可额外返回恢复后的 Domain，处理 decoder 无法区分的 false 省略。
                                        -- 是否调用独立记录，不能凭 probe 缺失推断未调用。
                                        store.lastHistoricalRecoveryHookState = "called"
                                        rebuiltOk, historicalCanonical, recoveredDomain = pcall(
                                            store.rebuildCanonicalForIntegrity, DeepCopy(decoded), stampedFingerprint,
                                            canonical, DeepCopy(raw))
                                        store.lastHistoricalRecoveryHookState = rebuiltOk ~= true and "exception"
                                            or (type(historicalCanonical) == "table" and "candidate" or "no_candidate")
                                        if NonEmptyText(store.lastHistoricalRecoveryProbe) == nil then
                                            store.lastHistoricalRecoveryProbe = "hook_" .. store.lastHistoricalRecoveryHookState
                                        end
                                        AppendIntegrityRecoveryTrace(store, "hist=" .. tostring(rebuiltOk == true and type(historicalCanonical) == "table" and "cand" or (rebuiltOk == true and "nil" or "err")))
                                    else
                                        store.lastHistoricalRecoveryHookState = "not_registered"
                                        AppendIntegrityRecoveryTrace(store, "hist=nohook")
                                        rebuiltOk, historicalCanonical, recoveredDomain = false, nil, nil
                                    end
                                end
                                if rebuiltOk == true and type(historicalCanonical) == "table" then
                                    local historicalFingerprint = self:FingerprintCanonicalValue(store, historicalCanonical)
                                    AppendIntegrityRecoveryTrace(store, "hfp=" .. tostring(historicalFingerprint or "nil"))
                                    if historicalFingerprint ~= nil and tostring(historicalFingerprint) == tostring(stampedFingerprint) then
                                        -- 历史候选已通过旧 stamp 完整性认证；Apply 必须由恢复的逻辑值推导，
                                        -- 不能盲用 canonical(decoded)，避免默认敏感数据静默变化。
                                        local recoveredApplyValue = decoded
                                        local recoveredApplyOk = true
                                        if type(recoveredDomain) == "table" then
                                            local recoveredDomainInspection = self:InspectPayload(recoveredDomain, store.budget)
                                            if type(recoveredDomainInspection) ~= "table" or recoveredDomainInspection.ok ~= true then
                                                recoveredApplyOk = false
                                            else
                                                recoveredApplyValue = recoveredDomain
                                            end
                                        elseif not (type(store.encode) == "function" and type(store.decode) == "function") then
                                            local recoveredCanonical = self:CanonicalIntegrityValue(store, historicalCanonical)
                                            if recoveredCanonical == nil then
                                                recoveredApplyOk = false
                                            else
                                                local recoveredInspection = self:InspectPayload(recoveredCanonical, store.budget)
                                                if type(recoveredInspection) ~= "table" or recoveredInspection.ok ~= true then
                                                    recoveredApplyOk = false
                                                else
                                                    recoveredApplyValue = recoveredCanonical
                                                end
                                            end
                                        end
                                        local recoveredCurrentCanonical = nil
                                        if recoveredApplyOk == true then
                                            recoveredCurrentCanonical = self:CanonicalIntegrityValue(store, recoveredApplyValue)
                                            local recoveredCanonicalInspection = recoveredCurrentCanonical ~= nil
                                                and self:InspectPayload(recoveredCurrentCanonical, store.encodedBudget) or nil
                                            if type(recoveredCanonicalInspection) ~= "table" or recoveredCanonicalInspection.ok ~= true then
                                                recoveredApplyOk = false
                                            end
                                        end
                                        if recoveredApplyOk == true then
                                            local recoveredCurrentFingerprint = self:FingerprintCanonicalValue(store, recoveredCurrentCanonical)
                                            local needsRestamp = recoveredCurrentFingerprint == nil
                                                or tostring(recoveredCurrentFingerprint) ~= tostring(stampedFingerprint)
                                            recoveredHistoricalCanonical = true
                                            integrityUpgradeNeeded = needsRestamp
                                            preDecodedValue = recoveredApplyValue
                                            store.lastIntegrityStatus = needsRestamp
                                                and "historical_canonical_recovery" or "verified_canonical_recovered_representation"
                                            store.lastIntegrityFingerprint = historicalFingerprint
                                            store.lastIntegrityError = needsRestamp
                                                and "canonicalizer_changed" or "serializer_omission_recovered"
                                            self.stats.integrityUpgradeRecoveries = (tonumber(self.stats.integrityUpgradeRecoveries) or 0) + 1
                                            Emit("info", "STORE_HISTORICAL_CANONICAL_RECOVERY",
                                                needsRestamp
                                                    and "旧版 Store canonical 精确复原已匹配原指纹；按当前 canonical 重新归一该历史逻辑值并排队重盖章"
                                                    or "Store canonical 精确复原已匹配原指纹；已恢复 RU 省略的逻辑值，无需改写现有盖章", {
                                                        store = store.id, oldFingerprint = stampedFingerprint,
                                                        newFingerprint = recoveredCurrentFingerprint or actualFingerprint,
                                                        restamp = needsRestamp,
                                                    })
                                        end
                                    end
                                end
                            end
                        end
                        -- 精确历史候选用尽后，才允许 Store 以精确 stamp 白名单迁移，并校验旧 payload 形状。
                        -- Core 仍验 seal、预算和当前 canonical，恢复后立即盖章；这不是通用失配放行。
                        if recoveredHistoricalCanonical ~= true and envelopeAdvertised == true
                            and store.allowIntegrityUpgrade == true
                            and type(store.recoverKnownLegacyCanonical) == "function" then
                            local knownOk, knownDomain, knownReason = pcall(
                                store.recoverKnownLegacyCanonical, DeepCopy(decoded), stampedFingerprint, canonical, DeepCopy(raw))
                            AppendIntegrityRecoveryTrace(store, "known=" .. tostring(knownOk == true and type(knownDomain) == "table" and "cand" or (knownOk == true and "nil" or "err")))
                            if knownOk == true and type(knownDomain) == "table" then
                                local knownInspection = self:InspectPayload(knownDomain, store.budget)
                                local knownCanonical = nil
                                local knownCanonicalInspection = nil
                                if type(knownInspection) == "table" and knownInspection.ok == true then
                                    knownCanonical = self:CanonicalIntegrityValue(store, knownDomain)
                                    knownCanonicalInspection = knownCanonical ~= nil
                                        and self:InspectPayload(knownCanonical, store.encodedBudget) or nil
                                end
                                if type(knownCanonicalInspection) == "table" and knownCanonicalInspection.ok == true then
                                    local knownCurrentFingerprint = self:FingerprintCanonicalValue(store, knownCanonical)
                                    if knownCurrentFingerprint ~= nil then
                                        recoveredHistoricalCanonical = true
                                        integrityUpgradeNeeded = true
                                        preDecodedValue = knownDomain
                                        store.lastIntegrityStatus = "known_legacy_canonical_recovery"
                                        store.lastIntegrityFingerprint = tostring(stampedFingerprint)
                                        store.lastIntegrityError = tostring(knownReason or "known_legacy_stamp")
                                        self.stats.integrityUpgradeRecoveries = (tonumber(self.stats.integrityUpgradeRecoveries) or 0) + 1
                                        self.stats.knownLegacyCanonicalRecoveries = (tonumber(self.stats.knownLegacyCanonicalRecoveries) or 0) + 1
                                        Emit("warning", "STORE_KNOWN_LEGACY_CANONICAL_RECOVERY",
                                            "已识别并验证 Store 专属历史盖章；保留现存业务数据并立即按当前 canonical 重盖章", {
                                                store = store.id, oldFingerprint = stampedFingerprint,
                                                newFingerprint = knownCurrentFingerprint, reason = knownReason,
                                            })
                                    end
                                else
                                    self.stats.knownLegacyCanonicalRecoveryRejects = (tonumber(self.stats.knownLegacyCanonicalRecoveryRejects) or 0) + 1
                                end
                            elseif knownOk ~= true or knownDomain ~= nil then
                                self.stats.knownLegacyCanonicalRecoveryRejects = (tonumber(self.stats.knownLegacyCanonicalRecoveryRejects) or 0) + 1
                            end
                        end
                        if recoveredHistoricalCanonical ~= true then
                            integrityErr = "fingerprint_mismatch:" .. tostring(stampedFingerprint) .. ">" .. tostring(actualFingerprint)
                            -- 保底诊断使用实际调用状态，不能由 probe 缺失推断未调用；
                            -- 前置 gate 跳过、未注册、无候选、异常必须有不同证据，不能绕过失败。
                            if NonEmptyText(store.lastHistoricalRecoveryProbe) == nil then
                                store.lastHistoricalRecoveryProbe = "hook_" .. tostring(store.lastHistoricalRecoveryHookState or "not_called") .. "/envelopeAdvertised="
                                    .. tostring(envelopeAdvertised) .. "/allowUpgrade=" .. tostring(store.allowIntegrityUpgrade)
                                    .. "/integrityVersion=" .. tostring(stampedIntegrityVersion)
                                    .. "/reliability=" .. tostring(stampedReliabilityContract)
                            end
                            local recoveryTrace = NonEmptyText(store.lastIntegrityRecoveryTrace)
                            if recoveryTrace ~= nil then
                                integrityErr = integrityErr .. "|trace=" .. recoveryTrace -- 短状态机轨迹先于 Store 长 probe，避免 warning 长度上限截掉关键分支。这里只调整诊断顺序。
                            end
                            local historicalProbe = NonEmptyText(store.lastHistoricalRecoveryProbe)
                            if historicalProbe ~= nil then
                                integrityErr = integrityErr .. "|historical_probe=" .. historicalProbe
                            end
                        end
                    else
                        store.lastIntegrityStatus = "verified_canonical"
                        store.lastIntegrityFingerprint = actualFingerprint
                        store.lastIntegrityError = nil
                        -- v4 流水线：Decode -> Normalize -> Verify -> Apply。普通 Store 应用 canonical 归一
                        -- 化值，即使没有 schema 迁移也让 Domain 收到固定形状；typed-codec Store 应用由
                        -- decode() 完成归一化的 Domain。
                        if type(store.encode) == "function" and type(store.decode) == "function" then
                            preDecodedValue = decoded
                        else
                            preDecodedValue = canonical
                        end
                    end
                end
            end
        elseif stampedIntegrityVersion ~= preCanonicalIntegrity and stampedIntegrityVersion ~= legacyIntegrity then
            integrityErr = "integrity_version:" .. tostring(stampedIntegrityVersion)
        elseif stampedFingerprint == nil then
            integrityErr = "fingerprint_missing"
        else
            local actualFingerprint, actualErr
            if stampedIntegrityVersion == legacyIntegrity then
                actualFingerprint, actualErr = self:FingerprintEncodedPayloadV1(raw, store.encodedBudget)
            else
                actualFingerprint, actualErr = self:FingerprintEncodedPayload(raw, store.encodedBudget)
            end
            if actualFingerprint == nil then
                integrityErr = "fingerprint_failed:" .. tostring(actualErr or "unknown")
            elseif tostring(actualFingerprint) ~= tostring(stampedFingerprint) then
                local compatibilityAllowed = stampedIntegrityVersion == legacyIntegrity
                    and (tonumber(stampedReliabilityContract) or 0) >= 6
                    and envelopeAdvertised == true
                    and store.verifyAfterSave ~= true
                    and store.recoverableReplacement ~= true
                if compatibilityAllowed then
                    legacyIntegrityUpgradeNeeded = true
                    store.lastIntegrityStatus = "legacy_v1_compatibility"
                    store.lastIntegrityFingerprint = actualFingerprint
                    store.lastIntegrityError = "fingerprint_mismatch:" .. tostring(stampedFingerprint) .. ">" .. tostring(actualFingerprint)
                    self.stats.integrityCompatibilityLoads = (tonumber(self.stats.integrityCompatibilityLoads) or 0) + 1
                    Emit("info", "STORE_INTEGRITY_V1_COMPATIBILITY_LOAD",
                        "旧版完整性指纹与 RU 序列化后的数值表示不一致；元数据封印有效，完成业务校验后将升级为 v2 指纹", {
                            store = store.id, oldFingerprint = stampedFingerprint, loadedFingerprint = actualFingerprint,
                        })
                else
                    -- Integrity v2 默认继续失败封闭。Store 可主动启用一种有严格证据的序列化形状修复：
                    -- metadata envelope 已通过，Store 非关键且非 journal，钩子重建候选的当前完整性哈希精确
                    -- 等于旧 stamp。丢失或改变的业务值仍失败并保持隔离。
                    local repairAllowed = stampedIntegrityVersion == preCanonicalIntegrity
                        and (tonumber(stampedReliabilityContract) or 0) >= 6
                        and envelopeAdvertised == true
                        and store.verifyAfterSave ~= true
                        and store.recoverableReplacement ~= true
                        and type(store.rebuildEncodedForIntegrity) == "function"
                    local repaired = false
                    if repairAllowed then
                        local okRepair, candidate, repairReason = pcall(store.rebuildEncodedForIntegrity, DeepCopy(raw), {
                            store = store.id, stampedFingerprint = stampedFingerprint, loadedFingerprint = actualFingerprint,
                        })
                        -- 钩子可返回单个候选表，或在多个历史编码形状（如 codec 前 Domain 与中间包装形状）存
                        -- 在时返回 { candidates = { ... } }。Persistence 分别哈希，仅接受精确复现 stamp 的
                        -- 候选。
                        local candidateList = nil
                        if okRepair == true and type(candidate) == "table" and type(candidate.candidates) == "table" then
                            candidateList = candidate.candidates
                        elseif okRepair == true and type(candidate) == "table" then
                            candidateList = { candidate }
                        end
                        if type(candidateList) == "table" then
                            for candidateIndex = 1, #candidateList do
                                local candidateValue = candidateList[candidateIndex]
                                if type(candidateValue) ~= "table" then
                                    self.stats.integritySerializerRepairFailures = (tonumber(self.stats.integritySerializerRepairFailures) or 0) + 1
                                else
                                    local candidateInspection = self:InspectPayload(candidateValue, store.encodedBudget)
                                    local candidateFingerprint, candidateErr = nil, nil
                                    if type(candidateInspection) == "table" and candidateInspection.ok == true then
                                        candidateFingerprint, candidateErr = self:FingerprintEncodedPayload(candidateValue, store.encodedBudget)
                                    else
                                        candidateErr = "candidate_rejected:" .. tostring(candidateInspection and candidateInspection.reason or "unknown")
                                    end
                                    if candidateFingerprint ~= nil and tostring(candidateFingerprint) == tostring(stampedFingerprint) then
                                        repaired = true
                                        serializerRepairNeeded = true
                                        serializerRepairedRaw = candidateValue
                                        store.lastIntegrityStatus = "serializer_repair_verified"
                                        store.lastIntegrityFingerprint = candidateFingerprint
                                        store.lastIntegrityError = "fingerprint_mismatch:" .. tostring(stampedFingerprint) .. ">" .. tostring(actualFingerprint)
                                        self.stats.integritySerializerRepairLoads = (tonumber(self.stats.integritySerializerRepairLoads) or 0) + 1
                                        Emit("info", "STORE_INTEGRITY_SERIALIZER_REPAIR",
                                            "RU 序列化改变了已知 Store 的编码表示；重建候选精确复现原完整性指纹，允许加载并立即改写为稳定编码", {
                                                store = store.id, oldFingerprint = stampedFingerprint, loadedFingerprint = actualFingerprint,
                                                candidate = candidateIndex, reason = tostring(repairReason or "verified_reconstruction"),
                                            })
                                        break
                                    end
                                end
                            end
                            if repaired ~= true then
                                self.stats.integritySerializerRepairFailures = (tonumber(self.stats.integritySerializerRepairFailures) or 0) + 1
                                Emit("warning", "STORE_INTEGRITY_SERIALIZER_REPAIR_REJECTED",
                                    "Store 提供的序列化修复候选无法复现原完整性指纹，继续按真实损坏 Fail Closed", {
                                        store = store.id, oldFingerprint = stampedFingerprint,
                                        error = tostring(repairReason or "fingerprint_not_reproduced"),
                                    })
                            end
                        elseif repairAllowed then
                            self.stats.integritySerializerRepairFailures = (tonumber(self.stats.integritySerializerRepairFailures) or 0) + 1
                        end
                    end
                    if repaired ~= true then
                        -- 旧原始 envelope 章容易受 RU 表示变化影响；独立 seal 和完整 decode/预算通过时可单代升级。
                        -- 门禁兼容完整性时期的 v1/v2 章，延迟盖 canonical 章后恢复严格验证；不能仅凭旧 reliability 版本拒绝可信 seal。
                        local upgradeAllowed = store.allowIntegrityUpgrade == true
                            and stampedIntegrityVersion == preCanonicalIntegrity
                            and (tonumber(stampedReliabilityContract) or 0) >= minIntegrityReliability
                            and envelopeAdvertised == true
                        local upgraded = false
                        if upgradeAllowed then
                            local okDecode, upgradedValue, upgradeDecodeErr = pcall(DecodeValue, store, raw)
                            local upgradedInspection = nil
                            if okDecode == true and upgradedValue ~= nil then
                                upgradedInspection = self:InspectPayload(upgradedValue, store.budget)
                            end
                            if okDecode ~= true or upgradedValue == nil
                                or type(upgradedInspection) ~= "table" or upgradedInspection.ok ~= true then
                                -- 拒绝原因必须可见，避免实机只见 v3Upgrade=0/0 而无法验证原因。
                                self.stats.integrityUpgradeValidationFailures = (tonumber(self.stats.integrityUpgradeValidationFailures) or 0) + 1
                                Emit("warning", "STORE_INTEGRITY_UPGRADE_VALIDATION_FAILED",
                                    "受控升级的解码/预算校验未通过，继续按真实损坏 Fail Closed", {
                                        store = store.id,
                                        decodeOk = okDecode == true,
                                        decodeError = tostring(okDecode == true and (upgradeDecodeErr or "none") or upgradeDecodeErr or "decode exception"),
                                        budgetReason = type(upgradedInspection) == "table" and tostring(upgradedInspection.reason or "unknown") or "inspection_failed",
                                    })
                            end
                            if okDecode == true and upgradedValue ~= nil then
                                if type(upgradedInspection) == "table" and upgradedInspection.ok == true then
                                    upgraded = true
                                    integrityUpgradeNeeded = true
                                    local canonicalValue = self:CanonicalIntegrityValue(store, upgradedValue)
                                    local divergence = nil
                                    local applyValue = upgradedValue
                                    if type(canonicalValue) == "table"
                                        and not (type(store.encode) == "function" and type(store.decode) == "function") then
                                        -- 普通 Store 应用已归一化 canonical 形状，并报告序列化或 normalize
                                        -- 差异改变的精确字段。
                                        applyValue = canonicalValue
                                        divergence = self:DescribeCanonicalDivergence(upgradedValue, canonicalValue)
                                    end
                                    preDecodedValue = applyValue
                                    store.lastIntegrityStatus = "integrity_upgrade_recovery"
                                    store.lastIntegrityFingerprint = actualFingerprint
                                    store.lastIntegrityError = "fingerprint_mismatch:" .. tostring(stampedFingerprint) .. ">" .. tostring(actualFingerprint)
                                    store.lastIntegrityDivergence = divergence
                                    self.stats.integrityUpgradeRecoveries = (tonumber(self.stats.integrityUpgradeRecoveries) or 0) + 1
                                    Emit("info", "STORE_INTEGRITY_UPGRADE_RECOVERY",
                                        "旧版完整性指纹与磁盘表示不一致，但元数据封印与业务校验全部通过；按契约升级加载并将在保存时改盖 canonical 指纹", {
                                            store = store.id, oldFingerprint = stampedFingerprint, loadedFingerprint = actualFingerprint,
                                            divergence = divergence,
                                        })
                                end
                            end
                        end
                        if upgraded ~= true then
                            -- 隔离须报告具体拒绝条件，仅有 v3Upgrade=0/0 无法定位。
                            integrityErr = "fingerprint_mismatch:" .. tostring(stampedFingerprint) .. ">" .. tostring(actualFingerprint)
                                .. "|upgrade_gate=reliability:" .. tostring(stampedReliabilityContract)
                                .. "/version:" .. tostring(stampedIntegrityVersion)
                                .. "/optOut:" .. tostring(store.allowIntegrityUpgrade == false)
                        end
                    end
                end
            else
                store.lastIntegrityStatus = stampedIntegrityVersion == legacyIntegrity and "verified_v1" or "verified_v2"
                store.lastIntegrityFingerprint = actualFingerprint
                store.lastIntegrityError = nil
                if stampedIntegrityVersion == legacyIntegrity and (tonumber(stampedReliabilityContract) or 0) >= 6
                    and store.verifyAfterSave ~= true and store.recoverableReplacement ~= true then
                    -- 精确 v1 加载本身健康，重新盖 v2 stamp 可避免下次原生往返再次进入表示敏感的旧契约。
                    legacyIntegrityUpgradeNeeded = true
                elseif stampedIntegrityVersion == preCanonicalIntegrity
                    and (tonumber(stampedReliabilityContract) or 0) >= 6
                    and store.allowIntegrityUpgrade == true then
                    -- 精确 v2 当前虽健康，仍延迟盖 canonical 章，避免下次原始表示漂移造成假隔离。
                    integrityUpgradeNeeded = true
                end
            end
        end
        if integrityErr ~= nil then
            store.loaded = true
            store.loadStatus = "integrity_failed"
            store.writeFenced = true
            store.writeFenceReason = "integrity_failed:" .. tostring(integrityErr)
            store.lastError = store.writeFenceReason
            store.lastIntegrityStatus = "failed"
            store.lastIntegrityFingerprint = nil
            store.lastIntegrityError = integrityErr
            self.stats.integrityLoadFailures = (tonumber(self.stats.integrityLoadFailures) or 0) + 1
            self.stats.loadFailures = (tonumber(self.stats.loadFailures) or 0) + 1
            Emit("error", "STORE_INTEGRITY_FAILED", "存档跨重载完整性校验失败，已阻止解码/应用并启用写保护", {
                store = store.id, error = integrityErr,
            })
            return false, nil, store.lastError
        end
    else
        store.lastIntegrityStatus = "legacy_unstamped"
        store.lastIntegrityFingerprint = nil
        store.lastIntegrityError = nil
        self.stats.integrityLegacyLoads = (tonumber(self.stats.integrityLegacyLoads) or 0) + 1
    end

    local function RejectDecodedLoad(phase, inspection)
        local reason = tostring(inspection and inspection.reason or "unknown")
        store.loaded = true
        store.loadStatus = "decoded_load_rejected"
        store.lastError = "decoded_load_rejected:" .. tostring(phase or "decode") .. ":" .. reason
        store.writeFenced = true
        store.writeFenceReason = store.lastError
        store.dirty = false
        store.dueAt = 0
        store.firstDirtyAt = 0
        store.lastDirtyAt = 0
        store.lastDirtyReason = nil
        self.stats.decodedLoadRejects = (tonumber(self.stats.decodedLoadRejects) or 0) + 1
        self.stats.loadFailures = (tonumber(self.stats.loadFailures) or 0) + 1
        Emit("error", "STORE_DECODED_LOAD_REJECTED", "解码/迁移后的 Domain payload 超出 Store 安全预算，已阻止应用并启用写保护", {
            store = store.id, phase = tostring(phase or "decode"), reason = reason,
            nodes = inspection and inspection.nodes or nil, depth = inspection and inspection.maxDepth or nil,
        })
        return false, nil, store.lastError
    end

    local decodeRaw = serializerRepairedRaw or raw
    local value, decodeErr
    if preDecodedValue ~= nil then
        -- 复用已通过校验的解码值，不重新解码出另一份 Domain。
        value = preDecodedValue
    else
        value, decodeErr = DecodeValue(store, decodeRaw)
        if decodeErr == nil and value == nil then decodeErr = "decoded payload missing" end
    end
    if decodeErr ~= nil then
        store.loaded = true
        store.loadStatus = "decode_failed"
        store.writeFenced = true
        store.writeFenceReason = "decode_failed"
        store.lastError = decodeErr
        self.stats.loadFailures = (tonumber(self.stats.loadFailures) or 0) + 1
        Emit("error", "STORE_DECODE_FAILED", "独立存档解析失败，已启用写保护", { store = store.id, error = decodeErr })
        return false, nil, decodeErr
    end

    -- 自定义 decoder 可将紧凑编码表大幅扩张；在 migration/apply 前校验 Domain 结果预算，避免小磁盘 envelope
    -- 绕过业务 Store 的有界内存契约。
    local decodedInspection = self:InspectPayload(value, store.budget)
    store.lastDecodedInspection = decodedInspection
    if type(decodedInspection) ~= "table" or decodedInspection.ok ~= true then
        return RejectDecodedLoad("decode", decodedInspection)
    end

    -- 迁移/周期重置后的 Domain 通过最终预算且 apply 成功后才标 dirty，避免失败档被去抖反复保存。
    local deferredSaveReason = nil
    local deferredSaveDelayMs = nil
    if legacyIntegrityUpgradeNeeded == true then
        deferredSaveReason = "integrity_v2_upgrade"
        deferredSaveDelayMs = 0
    elseif serializerRepairNeeded == true then
        deferredSaveReason = "integrity_serializer_repair"
        deferredSaveDelayMs = 0
    elseif integrityUpgradeNeeded == true then
        deferredSaveReason = "integrity_v4_upgrade"
        deferredSaveDelayMs = 0
    end

    if storedSchema < store.schemaVersion then
        if type(store.migrate) ~= "function" then
            if storedSchema ~= store.legacySchemaVersion then
                store.writeFenced = true
                store.writeFenceReason = "migration_missing"
                store.lastError = store.writeFenceReason
                Emit("error", "STORE_MIGRATION_MISSING", "独立存档需要迁移但未提供迁移函数", {
                    store = store.id, from = storedSchema, to = store.schemaVersion,
                })
                return false, nil, store.writeFenceReason
            end
        else
            local ok, migrated, migrateErr = pcall(store.migrate, DeepCopy(value), storedSchema, store.schemaVersion)
            if not ok or migrated == nil then
                local message = ok and tostring(migrateErr or "migration returned nil") or tostring(migrated)
                store.writeFenced = true
                store.writeFenceReason = "migration_failed"
                store.lastError = message
                Emit("error", "STORE_MIGRATION_FAILED", "独立存档迁移失败，已保留原数据并启用写保护", {
                    store = store.id, from = storedSchema, to = store.schemaVersion, error = message,
                })
                return false, nil, message
            end
            value = migrated -- 完整性恢复须立即重盖，普通 schema 迁移不能把 0ms 保存改成去抖。
            self.stats.migrations = (tonumber(self.stats.migrations) or 0) + 1
            if deferredSaveReason == nil then
                deferredSaveReason = "migration"
                deferredSaveDelayMs = self.defaultDelayMs
            end
        end
    end

    local currentPeriod = select(1, self:GetPeriodId(store.lifetime, store.resetPolicy))
    local storedPeriod = meta and NonEmptyText(meta.periodId) or nil
    local payloadPeriod = nil
    if type(store.periodIdFromValue) == "function" then
        local ok, candidate = pcall(store.periodIdFromValue, value)
        if ok then payloadPeriod = NonEmptyText(candidate) end
    end
    store.periodId = storedPeriod or payloadPeriod or currentPeriod

    if store.autoReset == true and (store.lifetime == LIFETIME.Daily or store.lifetime == LIFETIME.Weekly)
        and currentPeriod ~= nil and storedPeriod ~= nil and currentPeriod ~= storedPeriod then
        local fresh, defaultErr = DefaultValue(store)
        if fresh == nil and defaultErr ~= nil then
            store.writeFenced = true
            store.writeFenceReason = "reset_default_failed"
            store.lastError = defaultErr
            return false, nil, defaultErr
        end
        value = fresh
        store.periodId = currentPeriod
        deferredSaveReason = "period_reset_load"
        deferredSaveDelayMs = 0
        self.stats.periodResets = (tonumber(self.stats.periodResets) or 0) + 1
        Emit("info", "STORE_PERIOD_RESET", "独立存档跨周期重置", { store = store.id, oldPeriod = storedPeriod, newPeriod = currentPeriod })
    end

    if deferredSaveReason == nil and physicalTransportRepairNeeded == true then
        -- 只有 transport 候选随后通过现有 Envelope/业务指纹、decode/migrate/budget/apply
        -- 全链路后才来到这里；立即重写为 Store 当前 transport，避免下次重载再次依赖修复。
        deferredSaveReason = "physical_transport_repair"
        deferredSaveDelayMs = 0
    end

    if deferredSaveReason == nil and meta ~= nil
        and (tonumber(meta.framework) or 0) < (tonumber(self.FrameworkVersion) or 3) then
        -- 旧 Framework2 只有在完整性、schema migration、周期 reset 全部
        -- 成功后才排队升级物理 transport；若前面已有更强的 resave 原因则不覆盖，因为
        -- 任一当前 SaveValue 都会自动写 Framework3。这样不会改变历史迁移的事务优先级。
        deferredSaveReason = "framework_transport_upgrade"
        deferredSaveDelayMs = 0
    end

    -- 本次确因旧 Transport 丢值而恢复的 Store 要立即排队升级，防止每次启动重走恢复。
    -- 健康旧档仍在下次正常保存时惰性升级，避免全 Store 同时写盘；版本按 Store 声明，验证/Apply 完成前不写。
    -- 升级原因与 Framework 升级分开，且不能被普通 debounce 延后。
    if deferredSaveReason == nil and meta ~= nil
        and (tonumber(meta.transportVersion) or 0) < (tonumber(store.transportVersion or self.TransportContractVersion) or 0)
        and (tonumber(self.stats.integrityUpgradeRecoveries) or 0) > recoveriesAtEntry then
        deferredSaveReason = "transport_representation_upgrade"
        deferredSaveDelayMs = 0
    end

    -- 旧角色键只有通过上述完整 transport/envelope/业务指纹/schema 链后才获得新键写意图；只排队不提前写。
    -- 保留更强恢复原因，但迁移必须立即可被既有 Scheduler/Flush 收口，不能被普通 schema debounce 延后。
    if scopeKeyMigration == true then
        deferredSaveReason = deferredSaveReason or "scope_key_upgrade"
        deferredSaveDelayMs = 0
    end

    -- 迁移与周期重置也是可扩张 payload 的业务代码；Domain apply 前立即复查最终值。
    local finalDecodedInspection = self:InspectPayload(value, store.budget)
    store.lastDecodedInspection = finalDecodedInspection
    if type(finalDecodedInspection) ~= "table" or finalDecodedInspection.ok ~= true then
        return RejectDecodedLoad("final", finalDecodedInspection)
    end

    if options.apply ~= false then
        local applied, applyErr = ApplyValue(store, value, "load")
        if not applied then
            store.writeFenced = true
            store.writeFenceReason = "apply_failed"
            store.lastError = applyErr
            Emit("error", "STORE_APPLY_FAILED", "独立存档应用失败，已启用写保护", { store = store.id, error = applyErr })
            return false, nil, applyErr
        end
        if deferredSaveReason ~= nil then
            local dirtyNow = NowMs()
            store.dirty = true
            store.firstDirtyAt = dirtyNow
            store.lastDirtyAt = dirtyNow
            store.lastDirtyReason = deferredSaveReason
            store.dirtyRevision = math.max(0, math.floor(tonumber(store.dirtyRevision) or 0)) + 1
            store.dueAt = dirtyNow + math.max(0, tonumber(deferredSaveDelayMs) or 0)
            self.stats.deferredLoadResaves = (tonumber(self.stats.deferredLoadResaves) or 0) + 1
            if deferredSaveReason == "integrity_v2_upgrade" then
                self.stats.integrityCompatibilityResaves = (tonumber(self.stats.integrityCompatibilityResaves) or 0) + 1
            elseif deferredSaveReason == "integrity_serializer_repair" then
                self.stats.integritySerializerRepairResaves = (tonumber(self.stats.integritySerializerRepairResaves) or 0) + 1
            elseif deferredSaveReason == "integrity_v4_upgrade" then
                self.stats.integrityUpgradeResaves = (tonumber(self.stats.integrityUpgradeResaves) or 0) + 1
            end
        end
    end
    store.loaded = true
    store.loadStatus = "loaded"
    store.writeFenced = false
    store.writeFenceReason = nil
    store.lastError = nil
    store.needsBarrierVerify = false
    -- 到此说明磁盘数据已在当前预算/schema/完整性契约下成功 decode/apply，先前会话读隔离已过期并在上方清除。
    -- 保存侧预算隔离未经过成功加载，不能静默清除。
    self.stats.loaded = (tonumber(self.stats.loaded) or 0) + 1
    Count("STORE_LOADED", 1)
    return true, DeepCopy(value), nil
end

function P:SaveValue(id, value, options)
    options = type(options) == "table" and options or {}
    local store = self:GetStore(id)
    if store == nil then return false, "unknown store" end
    if store.lifetime == LIFETIME.Session then
        store.memory = DeepCopy(value)
        store.dirty = false
        return true
    end
    local replacingFencedShard = false
    local originalFenceReason = store.writeFenceReason
    if store.writeFenced == true then
        local verifyRequired = options.verifyAfterSave == true or options.durable == true or store.verifyAfterSave == true
        replacingFencedShard = options.replaceCorrupt == true
            and store.recoverableReplacement == true
            and verifyRequired == true
            and self:CanReplaceCorrupt(store.id) == true
        if replacingFencedShard ~= true then
            Count("STORE_WRITE_FENCED", 1)
            return false, store.writeFenceReason or "write fenced"
        end
    end
    if type(store.save) ~= "function" and (S.Api == nil or type(S.Api.SaveData) ~= "function") then
        return false, "SaveData unavailable"
    end
    local resolvedKey, scopeErr, scopeFingerprint
    if options.useBoundScope == true and store.scope == SCOPE.Character and store.resolvedKey ~= nil then
        -- dirty 状态归加载或修改时的 scope；角色切换后 debounce/Flush 必须完成旧绑定键的写入，不能把旧
        -- Domain 投射到新玩家。
        resolvedKey = store.resolvedKey
        scopeFingerprint = store.resolvedScopeFingerprint
    else
        resolvedKey, scopeErr, scopeFingerprint = self:ResolveStoreKey(store)
        if resolvedKey == nil then
            store.lastError = scopeErr
            return false, scopeErr
        end
        if store.scope == SCOPE.Character and store.resolvedKey ~= nil then
            local keyChanged = tostring(store.resolvedKey) ~= tostring(resolvedKey)
            local identityChanged = store.resolvedScopeFingerprint ~= nil and scopeFingerprint ~= nil
                and tostring(store.resolvedScopeFingerprint) ~= tostring(scopeFingerprint)
            if keyChanged or identityChanged then
                local verifyRequired = options.verifyAfterSave == true or options.durable == true or store.verifyAfterSave == true
                local safeReplacementRebind = keyChanged == true and store.dirty ~= true and store.needsBarrierVerify ~= true
                    and options.allowUnloadedWrite == true and store.recoverableReplacement == true and verifyRequired == true
                if safeReplacementRebind then
                    -- Gear 类非活动 journal 分片采用完整替换写入。干净分片可在同一 Lua 代际中跨角色切换，只
                    -- 在物理键变化时重新绑定；同一个有损键上的身份碰撞仍失败封闭，绝不可覆盖。
                    self.stats.scopeRebinds = (tonumber(self.stats.scopeRebinds) or 0) + 1
                else
                    local bindingErr = keyChanged and "scope_binding_key_changed" or "scope_binding_identity_changed"
                    self.stats.scopeBindingMismatches = (tonumber(self.stats.scopeBindingMismatches) or 0) + 1
                    store.lastScopeBindingError = bindingErr
                    return false, bindingErr
                end
            end
        end
        store.resolvedKey = resolvedKey
        store.resolvedScopeFingerprint = scopeFingerprint
        store.lastScopeBindingError = nil
    end

    local periodId = nil
    if type(store.periodIdFromValue) == "function" then
        local ok, candidate = pcall(store.periodIdFromValue, value)
        if ok then periodId = NonEmptyText(candidate) end
    end
    local periodErr = nil
    if periodId == nil then periodId, periodErr = self:GetPeriodId(store.lifetime, store.resetPolicy) end
    if (store.lifetime == LIFETIME.Daily or store.lifetime == LIFETIME.Weekly) and periodId == nil then
        -- 服务器时间未就绪时不能伪造重置周期；Domain 已通过 periodIdFromValue 携带可信周期时仍可保存，否则
        -- 只隔离本次尝试。
        return false, "period unavailable: " .. tostring(periodErr or "unknown")
    end

    local payloadInspection = self:InspectPayload(value, store.budget)
    store.lastPayloadInspection = payloadInspection
    if payloadInspection.ok ~= true then
        store.lastError = "payload_rejected:" .. tostring(payloadInspection.reason or "unknown")
        store.writeFenced = true
        store.writeFenceReason = store.lastError
        self.stats.payloadRejected = (tonumber(self.stats.payloadRejected) or 0) + 1
        self.stats.saveFailures = (tonumber(self.stats.saveFailures) or 0) + 1
        Count("STORE_PAYLOAD_REJECTED", 1)
        Emit("error", "STORE_PAYLOAD_REJECTED", "独立存档超过 SaveData 安全预算，已阻止写入以保护旧存档", {
            store = store.id, reason = payloadInspection.reason, nodes = payloadInspection.nodes,
            depth = payloadInspection.maxDepth, stringBytes = payloadInspection.stringBytes,
            maxTableEntries = payloadInspection.maxTableEntries,
        })
        -- 写入隔离后须明确告知修改不能保存；713-ID 跟踪表曾超预算而持续静默拒写。
        if S.WarnOnce ~= nil then
            S.WarnOnce("store_payload_rejected_" .. store.id,
                "[" .. store.id .. "] 存档超出安全预算，本次会话的所有修改都无法保存！请在诊断页查看 STORE_PAYLOAD_REJECTED 详情。")
        end
        return false, store.lastError
    end

    -- Reliability v8 对 Store 自身确定性 encode/normalize 的 canonical 值盖 Integrity v4 stamp，不对 raw
    -- envelope 盖章。排除 __rsmeta 避免递归哈希；非整数使用序列化稳定 token，精确 Domain/业务指纹保持不变。
    -- typed-codec 的 canonical 等于编码业务 payload，普通 Store 使用 Domain 的固定形状归一化结果。
    local canonicalValue, canonicalErr = self:CanonicalIntegrityValue(store, value)
    if canonicalValue == nil then
        store.lastError = tostring(canonicalErr or "canonical_value_missing")
        self.stats.saveFailures = (tonumber(self.stats.saveFailures) or 0) + 1
        Emit("error", "STORE_CANONICAL_FAILED", "独立存档 canonical 值计算失败，已阻止写入", {
            store = store.id, error = store.lastError,
        })
        return false, store.lastError
    end
    local encodedFingerprint, fingerprintErr = self:FingerprintCanonicalValue(store, canonicalValue)
    if encodedFingerprint == nil then
        store.lastError = "encoded_fingerprint_failed:" .. tostring(fingerprintErr or "unknown")
        self.stats.saveFailures = (tonumber(self.stats.saveFailures) or 0) + 1
        Emit("error", "STORE_FINGERPRINT_FAILED", "独立存档编码完整性指纹计算失败，已阻止写入", {
            store = store.id, error = tostring(fingerprintErr or "unknown"),
        })
        return false, store.lastError
    end

    local raw, encodeErr = EncodeValue(store, DeepCopy(value), periodId, scopeFingerprint)
    if raw == nil then
        store.lastError = encodeErr
        self.stats.saveFailures = (tonumber(self.stats.saveFailures) or 0) + 1
        Emit("error", "STORE_ENCODE_FAILED", "独立存档编码失败", { store = store.id, error = encodeErr })
        return false, encodeErr
    end
    raw.__rsmeta.reliabilityContract = self.ReliabilityContractVersion
    raw.__rsmeta.integrityVersion = self.IntegrityContractVersion
    raw.__rsmeta.encodedFingerprint = encodedFingerprint
    raw.__rsmeta.envelopeIntegrityVersion = self.EnvelopeIntegrityContractVersion
    local envelopeFingerprint, envelopeErr = self:FingerprintEnvelopeIntegrity(raw)
    if envelopeFingerprint == nil then
        store.lastError = "envelope_fingerprint_failed:" .. tostring(envelopeErr or "unknown")
        self.stats.saveFailures = (tonumber(self.stats.saveFailures) or 0) + 1
        Emit("error", "STORE_ENVELOPE_FINGERPRINT_FAILED", "独立存档元数据封印计算失败，已阻止写入", {
            store = store.id, error = tostring(envelopeErr or "unknown"),
        })
        return false, store.lastError
    end
    raw.__rsmeta.envelopeFingerprint = envelopeFingerprint

    -- 最终序列化表也须检查；encode() 可重塑数据，仅验证 Domain 快照会使编码器突破 RU SaveData 安全 envelope。
    local encodedInspection = self:InspectPayload(raw, store.encodedBudget)
    store.lastEncodedInspection = encodedInspection
    if encodedInspection.ok ~= true then
        store.lastError = "encoded_payload_rejected:" .. tostring(encodedInspection.reason or "unknown")
        store.writeFenced = true
        store.writeFenceReason = store.lastError
        self.stats.encodedPayloadRejected = (tonumber(self.stats.encodedPayloadRejected) or 0) + 1
        self.stats.saveFailures = (tonumber(self.stats.saveFailures) or 0) + 1
        Count("STORE_ENCODED_PAYLOAD_REJECTED", 1)
        Emit("error", "STORE_ENCODED_PAYLOAD_REJECTED", "编码后的独立存档超过 SaveData 安全预算，已阻止写入", {
            store = store.id, reason = encodedInspection.reason, nodes = encodedInspection.nodes,
            depth = encodedInspection.maxDepth, stringBytes = encodedInspection.stringBytes,
            maxTableEntries = encodedInspection.maxTableEntries,
        })
        if S.WarnOnce ~= nil then
            S.WarnOnce("store_encoded_payload_rejected_" .. store.id,
                "[" .. store.id .. "] 存档编码后超出安全预算，本次会话的所有修改都无法保存！请在诊断页查看 STORE_ENCODED_PAYLOAD_REJECTED 详情。")
        end
        return false, store.lastError
    end

    -- 先对逻辑 raw/Domain 盖指纹，真正跨 SaveData 边界时才编码 Transport，避免哨兵进入业务层。
    local physicalRaw, transportErr = self:EncodePhysicalEnvelope(raw)
    if physicalRaw == nil then
        store.lastError = "transport_encode_failed:" .. tostring(transportErr or "unknown")
        self.stats.saveFailures = (tonumber(self.stats.saveFailures) or 0) + 1
        Emit("error", "STORE_TRANSPORT_ENCODE_FAILED", "独立存档物理传输编码失败，已阻止 SaveData", { store = store.id, error = tostring(transportErr or "unknown") })
        return false, store.lastError
    end
    local physicalInspection = self:InspectPayload(physicalRaw, store.encodedBudget)
    store.lastPhysicalInspection = physicalInspection
    if type(physicalInspection) ~= "table" or physicalInspection.ok ~= true then
        store.lastError = "physical_payload_rejected:" .. tostring(physicalInspection and physicalInspection.reason or "unknown")
        self.stats.encodedPayloadRejected = (tonumber(self.stats.encodedPayloadRejected) or 0) + 1
        self.stats.saveFailures = (tonumber(self.stats.saveFailures) or 0) + 1
        Emit("error", "STORE_PHYSICAL_PAYLOAD_REJECTED", "物理传输编码后的存档超过 SaveData 安全预算，已阻止写入", {
            store = store.id, reason = physicalInspection and physicalInspection.reason or "unknown",
        })
        return false, store.lastError
    end

    -- 显式声明的物理预算包括 Native 标签与缩进，
    -- 不是只计算字符串正文；拒绝发生在 Native 写入前，既有物理值不会因此被截坏。
    if store.nativeByteBudget~=nil then
        local bytes=T.EstimateNativeBytes(physicalRaw)
        store.lastNativeByteEstimate=bytes
        if bytes>store.nativeByteBudget and store.nativePaged~=true then
            store.lastError='native_byte_budget_exceeded:'..bytes..'>'..store.nativeByteBudget
            self.stats.saveFailures=(tonumber(self.stats.saveFailures) or 0)+1
            Emit('error','STORE_NATIVE_BYTE_BUDGET_REJECTED','存档超过 Native 物理文本预算，已阻止写入',{store=store.id,error=store.lastError})
            return false,store.lastError
        end
    end
    local ok, saveErr
    if type(store.save) == "function" then
        -- custom save 也属于物理写入边界，因此必须收到 transport 后 envelope；第三参数仍保留原 Domain 快照
        -- 供事务型分片实现使用。
        local callOk, result, customErr = pcall(store.save, resolvedKey, physicalRaw, DeepCopy(value), options)
        if callOk then
            ok = result == true
            saveErr = customErr
        else
            ok = false
            saveErr = result
        end
    else
        ok, saveErr = self:WritePhysicalStore(store,resolvedKey,physicalRaw)
    end
    if ok ~= true then
        -- SaveData 返回失败不能证明物理键未被触碰。journal 分片单独通过指针提交，失败非活动 bank 可安全成为
        -- 孤儿；其他 Store 必须在下一耐久屏障核对或恢复，之后才允许 Reload/Stop。
        if store.recoverableReplacement ~= true or store.requireFailureBarrier == true then store.needsBarrierVerify = true end
        store.lastError = tostring(saveErr or "save failed")
        self.stats.saveFailures = (tonumber(self.stats.saveFailures) or 0) + 1
        Count("STORE_SAVE_FAILED", 1)
        Emit("warning", "STORE_SAVE_FAILED", "独立存档保存失败", { store = store.id, error = saveErr })
        if S.WarnOnce ~= nil then
            S.WarnOnce("store_save_failed_" .. store.id,
                "[" .. store.id .. "] 存档保存失败，本次修改可能无法保留：" .. tostring(saveErr or "unknown"))
        end
        store.consecutiveSaveFailures = (tonumber(store.consecutiveSaveFailures) or 0) + 1
        -- dirty 写入无论是否走显式 Commit 都按有界节奏重试，避免 consumeDirty 失败后每个 Storage tick 重试
        -- ，或调用者进入 reload 时遗忘。从未 dirty 的直接事务写仍归调用者，不自动排队。
        if store.dirty == true then
            store.dueAt = NowMs() + math.min(30000, math.max(2000, tonumber(options.retryMs) or 5000))
            self.stats.retryQueued = (tonumber(self.stats.retryQueued) or 0) + 1
        end
        return false, store.lastError
    end

    local verifyRequired = options.verifyAfterSave == true or options.durable == true or store.verifyAfterSave == true
    if verifyRequired then
        if options.durable == true then
            self.stats.durableVerifyAttempts = (tonumber(self.stats.durableVerifyAttempts) or 0) + 1
        end
        local verified, verifyErr = self:VerifyPersistedValue(store, value, resolvedKey)
        if verified ~= true then
            if options.durable == true then
                self.stats.durableVerifyFailures = (tonumber(self.stats.durableVerifyFailures) or 0) + 1
            end
            -- 即时读回未证明成功时 SaveData 也可能已触碰物理键；保留耐久屏障义务，使调用者回滚 Domain 后
            -- Reload/Stop 不能静默越过不确定键。
            store.needsBarrierVerify = true
            store.lastError = "readback_verify_failed:" .. tostring(verifyErr or "unknown")
            store.consecutiveSaveFailures = (tonumber(store.consecutiveSaveFailures) or 0) + 1
            self.stats.saveFailures = (tonumber(self.stats.saveFailures) or 0) + 1
            Count("STORE_SAVE_VERIFY_FAILED", 1)
            if store.dirty == true then
                store.dueAt = NowMs() + math.min(30000, math.max(2000, tonumber(options.retryMs) or 5000))
                self.stats.retryQueued = (tonumber(self.stats.retryQueued) or 0) + 1
            end
            if S.WarnOnce ~= nil then
                S.WarnOnce("store_readback_verify_failed_" .. store.id,
                    "[" .. store.id .. "] SaveData 返回成功，但立即回读内容不一致；本次写入未被提交为可靠存档。")
            end
            return false, store.lastError
        end
        store.needsBarrierVerify = false
    else
        -- 普通低频设置保留单次写入快路径，只在显式 Reload/Stop 耐久屏障核验物理键一次，不进入 Feature Tick
        -- 或滑块循环。
        store.needsBarrierVerify = true
    end

    self.stats.integrityStampedSaves = (tonumber(self.stats.integrityStampedSaves) or 0) + 1
    self.stats.envelopeIntegrityStampedSaves = (tonumber(self.stats.envelopeIntegrityStampedSaves) or 0) + 1

    store.periodId = periodId
    store.loaded = true
    if store.loadStatus == nil or store.loadStatus == "not_loaded" or store.loadStatus == "scope_pending" then
        store.loadStatus = "saved"
    end
    store.lastSaveAt = NowMs()
    store.lastError = nil
    store.lastIntegrityStatus = "stamped"
    store.lastIntegrityFingerprint = encodedFingerprint
    store.lastIntegrityError = nil
    if replacingFencedShard == true then
        store.writeFenced = false
        store.writeFenceReason = nil
        store.loadStatus = "saved"
        self.stats.verifiedReplacementRecoveries = (tonumber(self.stats.verifiedReplacementRecoveries) or 0) + 1
        Emit("warning", "STORE_VERIFIED_REPLACEMENT_RECOVERED", "已用完整回读验证的新分片替换损坏的非活动存档副本", {
            store = store.id, previousFence = tostring(originalFenceReason or "unknown"),
        })
    end
    store.lastSavedRevision = math.max(tonumber(store.lastSavedRevision) or 0, tonumber(store.dirtyRevision) or 0)
    store.consecutiveSaveFailures = 0
    store.dirty = false
    store.dueAt = 0
    store.firstDirtyAt = 0
    store.lastDirtyAt = 0
    store.lastDirtyReason = nil
    self.stats.saves = (tonumber(self.stats.saves) or 0) + 1
    Count("STORE_SAVED", 1)
    return true
end

local READY_LOAD_STATUS = {
    loaded = true,
    empty = true,
    saved = true,
    session = true,
}

local function IsStoreReady(store)
    return store ~= nil and store.loaded == true and READY_LOAD_STATUS[tostring(store.loadStatus or "")] == true
end

function P:IsStoreLoaded(id)
    local store = self:GetStore(id)
    if store == nil then return false, "unknown store" end
    -- store.loaded 只代表本次尝试已结束；corrupt/future/apply-failed 不能视为可用 Domain。
    if IsStoreReady(store) ~= true then return false, store.loadStatus end
    if store.scope == SCOPE.Character then
        local bindingOk, bindingErr = CurrentScopeBinding(store)
        if bindingOk ~= true then return false, bindingErr or "scope_changed" end
    end
    return true, store.loadStatus
end

-- 设置页可在 Feature 启用前构建；渲染前先加载当前 scope，不能把 Lua 默认值显示成已保存配置。
-- 这里只读，不要求写权限或标 dirty；终态失败继续隔离。
function P:PrepareRead(id)
    self.stats.readPrepareAttempts = (tonumber(self.stats.readPrepareAttempts) or 0) + 1
    local store = self:GetStore(id)
    if store == nil then
        self.stats.readPrepareFailures = (tonumber(self.stats.readPrepareFailures) or 0) + 1
        return false, "unknown store"
    end
    local ready, readyReason = self:IsStoreLoaded(id)
    if ready == true then return true end

    -- 终态失败（corrupt/future/apply-failed 等）已是诊断事实，不能在同一页逐字段反复 LoadData。角色 scope
    -- 变化时 ready-status Store 此处仍可为 false，允许在下方 LoadStore 重新绑定。
    if store.loaded == true and READY_LOAD_STATUS[tostring(store.loadStatus or "")] ~= true then
        self.stats.readPrepareFailures = (tonumber(self.stats.readPrepareFailures) or 0) + 1
        return false, store.lastError or readyReason or store.loadStatus or "store_not_ready"
    end

    local status, _, loadErr = self:LoadStore(id)
    if status ~= true and status ~= "empty" then
        self.stats.readPrepareFailures = (tonumber(self.stats.readPrepareFailures) or 0) + 1
        return false, loadErr or tostring(status or readyReason or "load failed")
    end
    self.stats.readPrepareLoads = (tonumber(self.stats.readPrepareLoads) or 0) + 1
    local loaded, loadedReason = self:IsStoreLoaded(id)
    if loaded ~= true then
        self.stats.readPrepareFailures = (tonumber(self.stats.readPrepareFailures) or 0) + 1
        return false, loadedReason or "store_not_ready_after_load"
    end
    return true
end

function P:CanWrite(id)
    local store = self:GetStore(id)
    if store == nil then return false, "unknown store" end
    if store.lifetime == LIFETIME.Session then return true end
    if IsStoreReady(store) ~= true then return false, "store_not_ready:" .. tostring(store.loadStatus or "not_loaded") end
    if store.scope == SCOPE.Character then
        local bindingOk, bindingErr = CurrentScopeBinding(store)
        if bindingOk ~= true then
            store.lastScopeBindingError = bindingErr
            self.stats.scopeBindingMismatches = (tonumber(self.stats.scopeBindingMismatches) or 0) + 1
            return false, bindingErr or "scope_changed"
        end
    end
    if store.writeFenced == true then return false, store.writeFenceReason or store.lastError or "store write-fenced" end
    return true
end

-- 共享 UI 与通用调用者的修改前辅助必须在 Domain 修改前执行；MarkDirty 不自动加载，否则修改后加载会用磁盘状
-- 态覆盖正要保存的值。
function P:PrepareWrite(id)
    local store = self:GetStore(id)
    if store == nil then return false, "unknown store" end
    if store.lifetime == LIFETIME.Session then return true end

    if IsStoreReady(store) == true and store.scope == SCOPE.Character then
        local bindingOk, bindingErr = CurrentScopeBinding(store)
        if bindingOk ~= true then
            -- 已加载 Domain 属于旧角色，不能写到新角色键；先完成旧 scope 的耐久义务。若无义务且 Store 干净
            -- ，可在修改前加载当前角色来安全重新绑定。
            if store.dirty == true or store.needsBarrierVerify == true then
                store.lastScopeBindingError = "scope_change_pending_persistence:" .. tostring(bindingErr or "changed")
                self.stats.scopeBindingMismatches = (tonumber(self.stats.scopeBindingMismatches) or 0) + 1
                return false, store.lastScopeBindingError
            end
            local status, _, loadErr = self:LoadStore(id)
            if status ~= true and status ~= "empty" then
                return false, loadErr or tostring(status or "scope rebind load failed")
            end
        end
    elseif IsStoreReady(store) ~= true then
        local status, _, loadErr = self:LoadStore(id)
        if status ~= true and status ~= "empty" then return false, loadErr or tostring(status or "load failed") end
    end
    return self:CanWrite(id)
end

function P:SaveStore(id, options)
    options = type(options) == "table" and options or {}
    local store = self:GetStore(id)
    if store == nil then return false, "unknown store" end
    if store.lifetime == LIFETIME.Session then return self:SaveValue(id, store.memory, options) end
    -- SaveStore 也必须遵守先加载后写隔离，避免未启用或加载 Feature 用默认内存覆盖有效旧 Store。完整替换事务
    -- 分片可显式退出此要求；普通设置或索引 Store 始终先加载。
    local replacementWrite = options.replaceCorrupt == true and store.recoverableReplacement == true
    if IsStoreReady(store) ~= true and options.allowUnloadedWrite ~= true and replacementWrite ~= true then
        self.stats.unloadedWriteRejects = (tonumber(self.stats.unloadedWriteRejects) or 0) + 1
        Count("STORE_WRITE_BEFORE_LOAD_REJECTED", 1)
        Emit("error", "STORE_WRITE_BEFORE_LOAD_REJECTED", "配置尚未完成读取，已拒绝直接保存以避免默认值覆盖旧存档", {
            store = store.id, owner = store.owner, loadStatus = store.loadStatus, reason = tostring(options.reason or "direct_save"),
        })
        return false, "store_not_loaded:" .. tostring(store.loadStatus or "not_loaded")
    end
    local ok, value = pcall(store.get)
    if not ok then
        store.lastError = tostring(value)
        Emit("error", "STORE_GET_FAILED", "读取 Domain 持久化快照失败", { store = store.id, error = value })
        return false, tostring(value)
    end
    return self:SaveValue(id, value, options)
end

-- 修改事务先加载，再快照 Domain；修改或提交失败时同时恢复 Domain 和 dirty 元数据。
-- 旧任意 SaveData 键迁移桥已移除。
function P:MutateStore(id, mutate, options)
    options = type(options) == "table" and options or {}
    if type(mutate) ~= "function" then return false, "mutation callback required" end
    local store = self:GetStore(id)
    if store == nil then return false, "unknown store" end
    self.stats.mutationAttempts = (tonumber(self.stats.mutationAttempts) or 0) + 1

    local prepared, prepareErr = self:PrepareWrite(id)
    if prepared ~= true then
        self.stats.mutationPrepareRejects = (tonumber(self.stats.mutationPrepareRejects) or 0) + 1
        return false, prepareErr or "store prepare failed"
    end

    local beforeValue
    if store.lifetime == LIFETIME.Session then
        beforeValue = DeepCopy(store.memory)
    else
        local got, snapshot = pcall(store.get)
        if got ~= true then return false, "pre-mutation snapshot failed: " .. tostring(snapshot) end
        beforeValue = DeepCopy(snapshot)
    end
    local beforeMeta = {
        dirty = store.dirty == true, dueAt = tonumber(store.dueAt) or 0,
        firstDirtyAt = tonumber(store.firstDirtyAt) or 0, lastDirtyAt = tonumber(store.lastDirtyAt) or 0,
        lastDirtyReason = store.lastDirtyReason, dirtyRevision = tonumber(store.dirtyRevision) or 0,
        lastSavedRevision = tonumber(store.lastSavedRevision) or 0,
        consecutiveSaveFailures = tonumber(store.consecutiveSaveFailures) or 0,
    }

    local function Rollback(reason)
        local rollbackOk, rollbackErr
        if store.lifetime == LIFETIME.Session then
            store.memory = DeepCopy(beforeValue)
            rollbackOk = true
        else
            rollbackOk, rollbackErr = ApplyValue(store, beforeValue, "mutation_rollback:" .. tostring(reason or "failed"))
        end
        if rollbackOk == true then
            store.dirty = beforeMeta.dirty
            store.dueAt = beforeMeta.dueAt
            store.firstDirtyAt = beforeMeta.firstDirtyAt
            store.lastDirtyAt = beforeMeta.lastDirtyAt
            store.lastDirtyReason = beforeMeta.lastDirtyReason
            store.dirtyRevision = beforeMeta.dirtyRevision
            store.lastSavedRevision = beforeMeta.lastSavedRevision
            store.consecutiveSaveFailures = beforeMeta.consecutiveSaveFailures
            self.stats.mutationRollbacks = (tonumber(self.stats.mutationRollbacks) or 0) + 1
            return true
        end
        store.writeFenced = true
        store.writeFenceReason = "mutation_rollback_failed"
        store.lastError = tostring(rollbackErr or "mutation rollback failed")
        self.stats.mutationRollbackFailures = (tonumber(self.stats.mutationRollbackFailures) or 0) + 1
        Emit("error", "STORE_MUTATION_ROLLBACK_FAILED", "持久化事务回滚失败，已对 Store 启用写保护", {
            store = store.id, reason = tostring(reason or "failed"), error = store.lastError,
        })
        return false, store.lastError
    end

    local callOk, result, mutationErr, extra = pcall(mutate, store)
    if callOk ~= true or result == false then
        self.stats.mutationFailures = (tonumber(self.stats.mutationFailures) or 0) + 1
        local reason = callOk == true and tostring(mutationErr or "mutation rejected") or tostring(result)
        Rollback(reason)
        return false, reason
    end

    local committed, commitErr
    if options.durable == true then
        committed, commitErr = self:SaveStore(id, {
            consumeDirty = true,
            durable = true,
            verifyAfterSave = true,
            reason = tostring(options.reason or "mutation_durable"),
            retryMs = options.retryMs,
        })
    else
        committed, commitErr = self:MarkDirty(id, tonumber(options.delayMs) or self.defaultDelayMs, tostring(options.reason or "mutation"))
    end
    if committed ~= true then
        self.stats.mutationCommitFailures = (tonumber(self.stats.mutationCommitFailures) or 0) + 1
        Rollback(commitErr or "mutation commit failed")
        return false, commitErr or "mutation commit failed"
    end
    return true, mutationErr, extra
end

function P:ClearStore(id, options)
    options = type(options) == "table" and options or {}
    local store = self:GetStore(id)
    if store == nil then return false, "unknown store" end
    if store.lifetime == LIFETIME.Session then
        local fresh, defaultErr = DefaultValue(store)
        if defaultErr ~= nil then return false, defaultErr end
        store.memory = DeepCopy(fresh)
        store.loaded, store.loadStatus, store.dirty, store.dueAt = true, "session", false, 0
        return true
    end
    local key, keyErr, legacyScopeKey
    if store.scope == SCOPE.Character then
        local prepared, prepareErr = self:PrepareWrite(id)
        if prepared ~= true then return false, prepareErr or "character store not ready for clear" end
        key = store.resolvedKey
        if key == nil then return false, "character store key unavailable" end
        -- 清空前重验完整身份；解析失败也返回 nil，不能误当没有旧候选而删掉已迁移键。
        local currentKey, scopeErr, currentFingerprint, legacyCandidate = self:ResolveStoreKey(store)
        local bindingError = currentKey == nil and (scopeErr or "character scope unavailable") or nil
        if bindingError == nil and tostring(currentKey) ~= tostring(store.resolvedKey) then bindingError = "scope_binding_key_changed" end
        if bindingError == nil and (currentFingerprint == nil or store.resolvedScopeFingerprint == nil
            or tostring(currentFingerprint) ~= tostring(store.resolvedScopeFingerprint)) then bindingError = "scope_binding_identity_changed" end
        if bindingError ~= nil then
            store.lastScopeBindingError = bindingError
            self.stats.scopeBindingMismatches = (tonumber(self.stats.scopeBindingMismatches) or 0) + 1
            return false, bindingError
        end
        legacyScopeKey = legacyCandidate
    else
        key, keyErr = self:ResolveStoreKey(store)
        if key == nil then return false, keyErr end
    end
    if legacyScopeKey ~= nil then
        -- 有旧角色源的键不能物理删除：旧键按迁移契约必须保留，删除新键会让下次冷启动再次认领旧内容。
        -- 默认 payload 的完整 envelope 是新的清空权威，沿用现有耐久 SaveValue 全链；旧键始终不写不删。
        local fresh, defaultErr = DefaultValue(store)
        if defaultErr ~= nil then
            store.writeFenced, store.writeFenceReason, store.lastError = true, "clear_default_failed", tostring(defaultErr)
            return false, defaultErr
        end
        if S.Api == nil or type(S.Api.LoadData) ~= "function" then
            self.stats.clearFailures = (tonumber(self.stats.clearFailures) or 0) + 1
            store.writeFenced, store.writeFenceReason, store.lastError = true, "clear_verify_unavailable", "clear_verify_unavailable"
            return false, store.lastError
        end
        self.stats.clearVerifyAttempts = (tonumber(self.stats.clearVerifyAttempts) or 0) + 1
        local saved, saveErr = self:SaveValue(id, fresh, { durable = true, reason = options.reason or "clear_store" })
        if saved ~= true then
            -- Native 拒绝或假成功 drop 都不得应用默认值。保存可能已触碰新键，隔离陈旧 Domain 和 dirty 重试，
            -- 保留耐久义务；只有重新证明磁盘状态后才能恢复写入，绝不能以旧 getter 自动盖掉清空权威。
            local reason = "clear_default_save_failed:" .. tostring(saveErr or "unknown")
            self.stats.clearFailures = (tonumber(self.stats.clearFailures) or 0) + 1
            self.stats.clearVerifyFailures = (tonumber(self.stats.clearVerifyFailures) or 0) + 1
            store.loadStatus = "clear_verify_failed"
            store.writeFenced, store.writeFenceReason, store.lastError = true, reason, reason
            store.needsBarrierVerify = true
            Emit("error", "STORE_CLEAR_VERIFY_FAILED", "角色清空默认档未通过耐久保存，已保留当前 Domain 并隔离陈旧写入", { store = store.id })
            return false, reason
        end
        if options.applyDefault ~= false then
            local applied, applyErr = ApplyValue(store, fresh, options.reason or "clear_store")
            if applied ~= true then
                -- 磁盘默认章已耐久，但 Domain 仍旧；必须显式 fence，防止后续变更从旧内存复活已清空数据。
                store.loadStatus = "clear_apply_failed"
                store.writeFenced, store.writeFenceReason, store.lastError = true, "clear_apply_failed", tostring(applyErr)
                return false, applyErr
            end
        end
        -- applyDefault=false 保留调用方内存，但标为待重载；下次读写须加载默认章，不能报告物理缺键。
        store.loaded = options.applyDefault ~= false
        store.loadStatus = options.applyDefault == false and "cleared_pending_apply" or "saved"
        store.lastBarrierVerifyAt, store.lastBarrierVerifyOk, store.lastBarrierVerifyError = NowMs(), true, nil
        store.lastLoadAt = NowMs()
        self.stats.clears = (tonumber(self.stats.clears) or 0) + 1
        Count("STORE_CLEARED", 1)
        return true
    end
    if S.Api == nil or type(S.Api.ClearData) ~= "function" then return false, "ClearData unavailable" end
    local cleared, clearErr = S.Api:ClearData(key)
    if cleared ~= true then
        self.stats.clearFailures = (tonumber(self.stats.clearFailures) or 0) + 1
        Emit("warning", "STORE_CLEAR_FAILED", "独立存档物理清理失败", { store = store.id, error = tostring(clearErr or "unknown") })
        return false, clearErr or "clear failed"
    end

    -- ClearData 成功不等于耐久证明；把默认值应用到内存前必须确认精确键已消失，避免假成功清除让设置暂似重置
    -- 、下次 Reload 又复活旧数据。
    if S.Api == nil or type(S.Api.LoadData) ~= "function" then
        self.stats.clearFailures = (tonumber(self.stats.clearFailures) or 0) + 1
        self.stats.clearVerifyFailures = (tonumber(self.stats.clearVerifyFailures) or 0) + 1
        store.writeFenced, store.writeFenceReason = true, "clear_verify_unavailable"
        store.lastError = store.writeFenceReason
        return false, store.lastError
    end
    self.stats.clearVerifyAttempts = (tonumber(self.stats.clearVerifyAttempts) or 0) + 1
    local verifyRaw, verifyErr = S.Api:LoadData(key)
    if verifyErr ~= nil or verifyRaw ~= nil then
        self.stats.clearFailures = (tonumber(self.stats.clearFailures) or 0) + 1
        self.stats.clearVerifyFailures = (tonumber(self.stats.clearVerifyFailures) or 0) + 1
        local reason = verifyErr ~= nil and ("clear_verify_load_failed:" .. tostring(verifyErr)) or "clear_verify_not_empty"
        store.loadStatus = "clear_verify_failed"
        store.writeFenced, store.writeFenceReason, store.lastError = true, reason, reason
        Emit("error", "STORE_CLEAR_VERIFY_FAILED", "ClearData 返回成功但物理存档仍未确认清空，已保留当前 Domain 并启用写保护", {
            store = store.id, owner = store.owner, error = reason,
        })
        return false, reason
    end
    local fresh, defaultErr = DefaultValue(store)
    if defaultErr ~= nil then
        store.writeFenced, store.writeFenceReason, store.lastError = true, "clear_default_failed", tostring(defaultErr)
        return false, defaultErr
    end
    if options.applyDefault ~= false then
        local applied, applyErr = ApplyValue(store, fresh, options.reason or "clear_store")
        if applied ~= true then
            store.writeFenced, store.writeFenceReason, store.lastError = true, "clear_apply_failed", tostring(applyErr)
            return false, applyErr
        end
    end
    store.loaded, store.loadStatus = true, "empty"
    store.dirty, store.dueAt, store.periodId = false, 0, nil
    store.firstDirtyAt, store.lastDirtyAt, store.lastDirtyReason = 0, 0, nil
    store.consecutiveSaveFailures = 0
    store.writeFenced, store.writeFenceReason, store.lastError = false, nil, nil
    store.needsBarrierVerify = false
    store.lastBarrierVerifyAt, store.lastBarrierVerifyOk, store.lastBarrierVerifyError = NowMs(), true, nil
    store.lastLoadAt = NowMs()
    self.stats.clears = (tonumber(self.stats.clears) or 0) + 1
    Count("STORE_CLEARED", 1)
    return true
end

function P:MarkDirty(id, delayMs, reason)
    local store = self:GetStore(id)
    if store == nil then return false, "unknown store" end
    if store.lifetime == LIFETIME.Session then return true end
    if IsStoreReady(store) ~= true then
        self.stats.unloadedWriteRejects = (tonumber(self.stats.unloadedWriteRejects) or 0) + 1
        Count("STORE_WRITE_BEFORE_LOAD_REJECTED", 1)
        Emit("error", "STORE_WRITE_BEFORE_LOAD_REJECTED", "配置尚未完成读取，已拒绝保存意图以避免默认值覆盖旧存档", {
            store = store.id, owner = store.owner, loadStatus = store.loadStatus, reason = tostring(reason or ""),
        })
        return false, "store_not_loaded:" .. tostring(store.loadStatus or "not_loaded")
    end
    if store.scope == SCOPE.Character then
        local bindingOk, bindingErr = CurrentScopeBinding(store)
        if bindingOk ~= true then
            store.lastScopeBindingError = bindingErr
            self.stats.scopeBindingMismatches = (tonumber(self.stats.scopeBindingMismatches) or 0) + 1
            Emit("error", "STORE_SCOPE_DIRTY_REJECTED", "角色级 Store 当前身份已变化，拒绝把旧角色 Domain 标记为待保存", {
                store = store.id, error = tostring(bindingErr or "scope_changed"),
            })
            return false, bindingErr or "scope_changed"
        end
    end
    if store.writeFenced == true then return false, store.writeFenceReason or store.lastError or "store write-fenced" end
    local now = NowMs()
    local delay = math.max(0, tonumber(delayMs) or self.defaultDelayMs)
    if store.dirty ~= true then
        store.firstDirtyAt = now
    end
    store.dirty = true
    store.lastDirtyAt = now
    store.lastDirtyReason = tostring(reason or "changed")
    store.dirtyRevision = math.max(0, math.floor(tonumber(store.dirtyRevision) or 0)) + 1
    if delay <= 0 then
        store.dueAt = now
    else
        -- 真正 debounce 在最后一次修改后保存，同时限制连续输入最长推迟时间，避免长期滑块拖动永久延后持久化。
        local requested = now + delay
        local absoluteCap = (tonumber(store.firstDirtyAt) or now) + math.max(delay, tonumber(self.maxDebounceMs) or 5000)
        store.dueAt = math.min(requested, absoluteCap)
    end
    Count("STORE_DIRTY", 1)
    return true
end

function P:SetSession(id, value)
    local store = self:GetStore(id)
    if store == nil or store.lifetime ~= LIFETIME.Session then return false, "not a Session store" end
    store.memory = DeepCopy(value)
    store.loaded = true
    store.loadStatus = "session"
    return true
end

function P:GetSession(id)
    local store = self:GetStore(id)
    if store == nil or store.lifetime ~= LIFETIME.Session then return nil end
    if store.memory == nil then store.memory = select(1, DefaultValue(store)) end
    return store.memory
end

function P:RevalidateStore(id)
    local store = self:GetStore(id)
    if store == nil then return false, "unknown store" end
    if store.lifetime ~= LIFETIME.Session and IsStoreReady(store) ~= true then
        local status, _, loadErr = self:LoadStore(id)
        if status ~= true and status ~= "empty" then return false, loadErr or tostring(status or "load failed") end
    end
    local fence = tostring(store.writeFenceReason or "")
    if fence:match("^payload_rejected:") == nil and fence:match("^encoded_payload_rejected:") == nil then
        return false, "store is not payload-fenced"
    end
    local ok, value = pcall(store.get)
    if not ok then return false, tostring(value) end
    local inspection = self:InspectPayload(value, store.budget)
    store.lastPayloadInspection = inspection
    if inspection.ok ~= true then return false, inspection.reason end
    local periodId = nil
    if type(store.periodIdFromValue) == "function" then
        local periodOk, candidate = pcall(store.periodIdFromValue, value)
        if periodOk then periodId = NonEmptyText(candidate) end
    end
    if periodId == nil then periodId = select(1, self:GetPeriodId(store.lifetime, store.resetPolicy)) end
    local raw, encodeErr = EncodeValue(store, DeepCopy(value), periodId, store.resolvedScopeFingerprint)
    if raw == nil then return false, encodeErr end
    local encodedInspection = self:InspectPayload(raw, store.encodedBudget)
    store.lastEncodedInspection = encodedInspection
    if encodedInspection.ok ~= true then return false, encodedInspection.reason end
    store.writeFenced = false
    store.writeFenceReason = nil
    store.lastError = nil
    store.dirty = true
    store.firstDirtyAt = NowMs()
    store.lastDirtyAt = store.firstDirtyAt
    store.lastDirtyReason = "revalidate"
    store.dirtyRevision = math.max(0, math.floor(tonumber(store.dirtyRevision) or 0)) + 1
    store.dueAt = store.firstDirtyAt
    return true
end

function P:Flush(owner)
    local allOk, failures = true, {}
    local saved, verified = 0, 0
    owner = NonEmptyText(owner)

    -- 第一阶段：提交当前全部 dirty Domain 快照。
    for _, id in ipairs(self.order) do
        local store = self.stores[id]
        if store ~= nil and store.dirty == true and (owner == nil or store.owner == owner) then
            local ok, err = self:SaveStore(id, { reason = "flush", retryMs = 5000, useBoundScope = true })
            if ok == true then
                saved = saved + 1
            else
                allOk = false
                failures[#failures + 1] = tostring(id) .. ":" .. tostring(err or store.lastError or "save failed")
            end
        end
    end

    -- Reload/Stop 前必须回读上次屏障以来所有写入键并匹配指纹；普通设置不在每次写后立即验证。
    -- 工作量由 Store 数量限制，不进入 Tick/滑块路径。
    for _, id in ipairs(self.order) do
        local store = self.stores[id]
        if store ~= nil and store.lifetime ~= LIFETIME.Session and store.needsBarrierVerify == true
            and (owner == nil or store.owner == owner) then
            self.stats.barrierVerifyAttempts = (tonumber(self.stats.barrierVerifyAttempts) or 0) + 1
            store.lastBarrierVerifyAt = NowMs()

            local ready = IsStoreReady(store)
            local expected, getErr
            if ready == true then
                local got, value = pcall(store.get)
                if got == true then expected = value else getErr = tostring(value) end
            else
                getErr = "store_not_ready:" .. tostring(store.loadStatus or "not_loaded")
            end

            local ok, err
            if getErr == nil then
                ok, err = self:VerifyPersistedValue(store, expected, store.resolvedKey)
            else
                ok, err = false, getErr
            end

            if ok == true then
                verified = verified + 1
                store.needsBarrierVerify = false
                store.lastBarrierVerifyOk = true
                if store.lastError == store.lastBarrierVerifyError then store.lastError = nil end
                store.lastBarrierVerifyError = nil
                self.stats.barrierVerifySuccesses = (tonumber(self.stats.barrierVerifySuccesses) or 0) + 1
            else
                allOk = false
                local reason = "barrier_verify_failed:" .. tostring(err or "unknown")
                store.lastBarrierVerifyOk = false
                store.lastBarrierVerifyError = reason
                store.lastError = reason
                self.stats.barrierVerifyFailures = (tonumber(self.stats.barrierVerifyFailures) or 0) + 1
                failures[#failures + 1] = tostring(id) .. ":" .. reason

                -- 屏障失配可能只是即时读取可见性延迟，不永久隔离写入；重新排队当前已验证 Domain 快照作有界
                -- 重试。下一屏障仍须通过才可 Reload。
                if store.writeFenced ~= true and IsStoreReady(store) == true then
                    local now = NowMs()
                    if store.dirty ~= true then
                        store.firstDirtyAt = now
                        store.dirtyRevision = math.max(0, math.floor(tonumber(store.dirtyRevision) or 0)) + 1
                    end
                    store.dirty = true
                    store.lastDirtyAt = now
                    store.lastDirtyReason = "durability_barrier_verify_failed"
                    store.dueAt = now + 5000
                    self.stats.retryQueued = (tonumber(self.stats.retryQueued) or 0) + 1
                    self.stats.barrierVerifyRequeued = (tonumber(self.stats.barrierVerifyRequeued) or 0) + 1
                end
            end
        end
    end

    self.lastFlush = {
        at = NowMs(),
        ok = allOk == true,
        owner = owner,
        saved = saved,
        verified = verified,
        failures = DeepCopy(failures),
    }

    if allOk ~= true then
        self.stats.flushFailures = (tonumber(self.stats.flushFailures) or 0) + 1
        Emit("error", "STORE_FLUSH_FAILED", "持久化 Flush/耐久屏障未能安全确认全部修改", {
            owner = owner, saved = saved, verified = verified, failures = failures,
        })
    end
    return allOk, failures
end

function P:Tick()
    local now = NowMs()
    for _, id in ipairs(self.order) do
        local store = self.stores[id]
        if store ~= nil and store.dirty == true and now >= (tonumber(store.dueAt) or 0) then
            if IsStoreReady(store) == true and store.writeFenced ~= true then
                self:SaveStore(id, { reason = "debounce", useBoundScope = true })
            else
                -- 终态或隔离 Store 保留 dirty 证据供 Flush/诊断使用，但运行节奏不能反复 SaveStore；恢复须显
                -- 式通过 Load/Revalidate/Clear。
                store.dueAt = now + math.max(5000, tonumber(self.maxDebounceMs) or 5000)
                self.stats.terminalAutoRetrySuppressions = (tonumber(self.stats.terminalAutoRetrySuppressions) or 0) + 1
            end
        end
    end

    if now < (tonumber(self.nextPeriodCheckAt) or 0) then return end
    self.nextPeriodCheckAt = now + math.max(5000, tonumber(self.periodCheckMs) or 15000)
    for _, id in ipairs(self.order) do
        local store = self.stores[id]
        if store ~= nil and IsStoreReady(store) == true and store.autoReset == true
            and (store.lifetime == LIFETIME.Daily or store.lifetime == LIFETIME.Weekly) then
            local current = select(1, self:GetPeriodId(store.lifetime, store.resetPolicy))
            if current ~= nil and store.periodId ~= nil and current ~= store.periodId then
                local fresh, err = DefaultValue(store)
                if fresh ~= nil then
                    local applied, applyErr = ApplyValue(store, fresh, "period_reset")
                    if applied then
                        local old = store.periodId
                        store.periodId = current
                        store.dirty = true
                        store.firstDirtyAt = now
                        store.lastDirtyAt = now
                        store.lastDirtyReason = "period_reset"
                        store.dirtyRevision = math.max(0, math.floor(tonumber(store.dirtyRevision) or 0)) + 1
                        store.dueAt = now
                        self.stats.periodResets = (tonumber(self.stats.periodResets) or 0) + 1
                        Emit("info", "STORE_PERIOD_RESET", "在线跨周期重置", { store = store.id, oldPeriod = old, newPeriod = current })
                    else
                        store.writeFenced = true
                        store.writeFenceReason = "period_apply_failed"
                        store.lastError = applyErr
                    end
                else
                    store.writeFenced = true
                    store.writeFenceReason = "period_default_failed"
                    store.lastError = err
                end
            end
        end
    end
end


-- Fresh Reload 诊断哈希 Domain 快照，排除 envelope 元数据和时间戳；不加载或修改 Store。
local HASH_MOD = 2147483647
local HASH_MULTIPLIER = 131

local function HashText(hash, text)
    hash = math.floor(tonumber(hash) or 1) % HASH_MOD
    text = tostring(text or "")
    for i = 1, #text do
        hash = (hash * HASH_MULTIPLIER + string.byte(text, i)) % HASH_MOD
    end
    return hash
end

local function NumberToken(value)
    value = tonumber(value) or 0
    if value == 0 then return "0" end
    return string.format("%.17g", value)
end

-- 旧 integrity v2/v4 的非整数 token 固定六位有效数字，不能改旧章算法；RU 的固定六位小数舍入仍可能破坏它。
-- Transport v3 在 Native 边界保护完整数字，整数 ID、计数和时间戳保持精确。
local function DurableNumberToken(value)
    value = tonumber(value) or 0
    if value == 0 then return "0" end
    if value == math.floor(value) and math.abs(value) <= 9007199254740991 then
        return string.format("%.0f", value)
    end
    -- 六位有效数字覆盖 UI scale/opacity/color/geometry 的持久化校验，但不能单独防止固定小数舍入。
    -- 历史哈希不变，Transport v3 保护数字；业务 Domain 指纹不使用此 token。
    return string.format("%.6g", value)
end

local function KeyToken(value, numberToken)
    local kind = type(value)
    if kind == "number" then return "n:" .. (numberToken or NumberToken)(value) end
    return "s:" .. tostring(value)
end

local function FingerprintValue(value, hash, seen, numberToken)
    local kind = type(value)
    if kind == "nil" then return HashText(hash, "N;") end
    if kind == "boolean" then return HashText(hash, value and "B1;" or "B0;") end
    if kind == "number" then return HashText(hash, "D" .. (numberToken or NumberToken)(value) .. ";") end
    if kind == "string" then
        hash = HashText(hash, "S" .. tostring(#value) .. ":")
        hash = HashText(hash, value)
        return HashText(hash, ";")
    end
    if kind ~= "table" then return nil, "unsupported_type:" .. kind end
    if seen[value] then return nil, "cyclic_table" end
    seen[value] = true

    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b)
        local at, bt = KeyToken(a, numberToken), KeyToken(b, numberToken)
        if at ~= bt then return at < bt end
        return tostring(type(a)) < tostring(type(b))
    end)

    hash = HashText(hash, "T" .. tostring(#keys) .. "{")
    for _, key in ipairs(keys) do
        hash = HashText(hash, "K")
        local nextHash, keyErr = FingerprintValue(key, hash, seen, numberToken)
        if nextHash == nil then seen[value] = nil; return nil, keyErr end
        hash = nextHash
        hash = HashText(hash, "V")
        local valueHash, valueErr = FingerprintValue(value[key], hash, seen, numberToken)
        if valueHash == nil then seen[value] = nil; return nil, valueErr end
        hash = valueHash
    end
    seen[value] = nil
    return HashText(hash, "};")
end

local function FingerprintPayloadWithNumberToken(self, value, budget, numberToken)
    local inspection = self:InspectPayload(value, budget)
    if inspection.ok ~= true then return nil, tostring(inspection.reason or "payload_rejected"), inspection end
    local hash, err = FingerprintValue(value, 146959810, {}, numberToken)
    if hash == nil then return nil, err, inspection end
    return string.format("%08X", math.floor(hash)), nil, inspection
end

-- 精确 Domain 指纹保持不变，Gear A/B journal 在自身索引契约中保存它；演进持久化哈希时不能静默改变业务契约。
function P:FingerprintPayload(value, budget)
    return FingerprintPayloadWithNumberToken(self, value, budget, NumberToken)
end

-- 读回及耐久证明可归一化非整数，以验证跨原生 SaveData 序列化器的业务等价，而非 Lua 内存二进制表示。
function P:FingerprintDurablePayload(value, budget)
    return FingerprintPayloadWithNumberToken(self, value, budget, DurableNumberToken)
end

-- 仅为编码业务字段计算指纹，排除框架元数据，让 stamp 位于 __rsmeta 而不哈希自身。浅层投影足够：
-- FingerprintPayload 递归遍历引用的嵌套表而不修改，InspectPayload 在哈希前拒绝环和超预算形状。
local function EncodedBusinessProjection(raw)
    if type(raw) ~= "table" then return nil, "encoded payload must be table" end
    local business = {}
    for key, value in pairs(raw) do
        if key ~= "__rsmeta" then business[key] = value end
    end
    return business, nil
end

-- Integrity v2 使用序列化稳定的数字归一化。
function P:FingerprintEncodedPayload(raw, budget)
    local business, err = EncodedBusinessProjection(raw)
    if business == nil then return nil, err end
    return self:FingerprintDurablePayload(business, budget)
end

-- 仅兼容 Integrity v1；新保存绝不能盖此形式的 stamp。
function P:FingerprintEncodedPayloadV1(raw, budget)
    local business, err = EncodedBusinessProjection(raw)
    if business == nil then return nil, err end
    return self:FingerprintPayload(business, budget)
end

-- Integrity v3 的 canonical 值是逻辑 Domain 状态经 Store typed codec（encode）或固定形状归一化器（migrate）
-- 计算的纯函数。RU 可改变顺序敏感 map、空表或浮点磁盘表示，只要 decode 后逻辑等价，两侧重新 canonical 化便
-- 得到相同指纹；内容损坏仍改变 canonical，校验继续失败封闭。
function P:CanonicalIntegrityValue(store, domainValue)
    if type(store.encode) == "function" and type(store.decode) == "function" then
        local ok, encoded = pcall(store.encode, domainValue)
        if ok and type(encoded) == "table" then return encoded, nil end
        return nil, "canonical_encode_failed:" .. tostring(ok and type(encoded) or encoded)
    end
    if type(store.migrate) == "function" then
        local ok, normalized = pcall(store.migrate, domainValue)
        if ok and type(normalized) == "table" then return normalized, nil end
        if ok then return domainValue, nil end
        return nil, "canonical_normalize_failed:" .. tostring(normalized)
    end
    return domainValue, nil
end

-- 按指纹相同的稳定键序返回首个差异路径。单值摘要最多 80 字节并去换行，避免把完整配置写进 Chat.log。
-- 同时输出 Lua type，区分 nil/false/0/空字符串；截断仅用于日志，不影响指纹或恢复判定。
local function SummarizeDivergenceScalar(value)
    local text = tostring(value):gsub("[\r\n]+", " ")
    if #text > 80 then text = text:sub(1, 77) .. "..." end
    return text
end

local function DescribeValueDivergence(expected, actual, path, depth, budget)
    if depth > 8 or budget.used >= budget.max then return nil end -- 最多 8 层/512 节点，避免损坏或恶意嵌套配置在错误处理路径制造
                                                                  -- 长时间扫描。
    local expectedKind, actualKind = type(expected), type(actual)
    if expectedKind ~= actualKind then
        return tostring(path) .. ": type " .. expectedKind .. " vs " .. actualKind
    end
    if expectedKind ~= "table" then
        if expected ~= actual then
            return tostring(path) .. ": " .. expectedKind .. "(" .. SummarizeDivergenceScalar(expected) .. ") vs " .. actualKind .. "(" .. SummarizeDivergenceScalar(actual) .. ")"
        end
        return nil
    end
    local keys = {}
    for key in pairs(expected) do keys[#keys + 1] = key end
    for key in pairs(actual) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local previous = nil
    for _, key in ipairs(keys) do
        if key ~= previous then
            previous = key
            budget.used = budget.used + 1
            local childPath = tostring(path) .. "." .. tostring(key)
            local found = DescribeValueDivergence(expected[key], actual[key], childPath, depth + 1, budget)
            if found ~= nil then return found end
        end
    end
    return nil
end

function P:DescribeCanonicalDivergence(expected, actual)
    if type(expected) ~= "table" or type(actual) ~= "table" then return nil end
    local budget = { used = 0, max = 512 }
    return DescribeValueDivergence(expected, actual, "$", 0, budget)
end

-- 对 canonical v3 值计算指纹；其中没有 __rsmeta，可直接使用耐久的序列化稳定数字 token 哈希。
function P:FingerprintCanonicalValue(store, canonical, budget)
    if canonical == nil then return nil, "canonical_value_missing" end
    return self:FingerprintDurablePayload(canonical, budget or store.encodedBudget)
end

-- 真实 udf 显示数字可能经过 binary32→固定 6 位小数→binary32。此有限投影只用于旧章证明，采用 IEEE ties-to-even。
-- 不覆盖 Lua 算术/format，不把模型当 RU 源码；新 Transport3 不需要此补偿。
local function LegacyBinary32(value)
    if value==0 then return value end
    local sign=value<0 and -1 or 1
    local magnitude=math.abs(value)
    local _,exponent=math.frexp(magnitude)
    local step=2^(exponent-24)
    local scaled=magnitude/step;local whole=math.floor(scaled);local fraction=scaled-whole
    if fraction>0.5 or (fraction==0.5 and whole%2==1) then whole=whole+1 end
    return sign*whole*step
end
local function LegacyFloatFirstProjection(value)
    return LegacyBinary32(tonumber(string.format("%.6f",LegacyBinary32(value))))
end

-- 旧窗口中心比例经固定 6 位小数/binary32 后可能改变旧章。仅尝试已声明 normalizedCenterX/Y，每次一个标量，最多 32 候选。
-- 含已由 udf 证明的 float32 先行分支；整份旧章唯一命中才接受，不改默认值或解除 Fence。
-- 原 raw/decoded/canonical 比例须一致且属于 logical-free-v2；零/小值、跨数量级和双轴损失仍拒绝。
-- 不为凑 Hash 扩枚举；未命中时仅留两轴 17g 值、6g token 和次数。Hash 是一致性检查，不是密码学证明。
P.Fixed6WindowRecoveryContractVersion = 2
function P:RebuildFixed6WindowCanonical(store, decoded, stamp, canonical, raw, schema, codec)
    local meta = type(raw) == "table" and raw.__rsmeta or nil
    if type(store) ~= "table" or type(meta) ~= "table" or meta.store ~= store.id or meta.owner ~= store.owner
        or tonumber(meta.framework) ~= 3 or tonumber(meta.transportVersion) ~= 2
        or tonumber(meta.schema) ~= schema or tonumber(meta.integrityVersion) ~= 4
        or type(stamp) ~= "string" or #stamp ~= 8 or stamp:find("[^%x]")
        or (codec == nil and raw.codec ~= nil) or (codec ~= nil and raw.codec ~= codec) then return nil end
    local proof = {status="shape", attempts=0, matches=0, fields={}}
    store.lastWindowNumericEvidence = proof
    local body = codec ~= nil and type(canonical) == "table" and canonical.payload or canonical
    local cw = type(body) == "table" and body.widgetWindow or nil
    local dw = type(decoded) == "table" and decoded.widgetWindow or nil
    local rw = type(raw.payload) == "table" and raw.payload.widgetWindow or nil
    if type(cw) ~= "table" or type(dw) ~= "table" or type(rw) ~= "table" then return nil end
    local function TextNumber(v)
        if type(v) ~= "number" then return "<" .. type(v) .. ">" end
        if v ~= v or v == math.huge or v == -math.huge then return "<nonfinite>" end
        return string.format("%.17g",v)
    end
    for _,key in ipairs({"normalizedCenterX","normalizedCenterY"}) do
        proof.fields[key]={raw=TextNumber(rw[key]),canonical=TextNumber(cw[key]),
            token=type(cw[key])=="number" and DurableNumberToken(cw[key]) or "-",reason="not_free"}
    end
    if cw.coordinateSpace ~= "logical-free-v2" or cw.userMoved ~= true then return nil end
    if self:InspectPayload(canonical,store.encodedBudget).ok ~= true then proof.status="budget";return nil end
    local matched, matchedKey, matchedValue
    for _,key in ipairs({"normalizedCenterX","normalizedCenterY"}) do
        local value,field=cw[key],proof.fields[key]
        local magnitude=type(value)=="number" and math.abs(value) or 0
        field.reason="range"
        if type(value)=="number" and value==value and magnitude>=0.01 and magnitude<1 then
            field.reason="normalized"
            if dw[key]==value and rw[key]==value then
                local fixed=string.format("%.6f",value)
                local center=tonumber(fixed)
                local exponent=math.floor(math.log(magnitude)/math.log(10))
                local step=10^(exponent-5)
                local low,high=center-0.0000005,center+0.0000005
                field.reason="boundary"
                if low*high>0 and math.floor(math.log(math.abs(low))/math.log(10))==exponent
                    and math.floor(math.log(math.abs(high))/math.log(10))==exponent then
                    local first,last=math.floor(low/step)-1,math.ceil(high/step)+1
                    field.reason="candidate_budget"
                    if last-first+1<=16 then
                        -- 实际计算候选 Hash 时才标 tested；进入枚举不代表存在可区分候选，避免 tries=0 却报告已测试。
                        field.reason="no_alternative"
                        local seen={}
                        for index=first,last do
                            local token=string.format("%.6g",index*step)
                            local number=tonumber(token)
                            if not seen[token] and token~=DurableNumberToken(value) then
                                local witness,restored,model
                                -- 保留已验证跑商旧桥；它还原token值，不偷改老兼容契约。
                                if string.format("%.6f",number)==fixed then
                                    witness,restored,model=number,number,"fixed6"
                                else
                                    -- 已见 0.8299175→float32(.829917490...)→.829917，而旧 6g 章为 .829918。
                                    -- 只检查当前舍入边界；witness 证明历史 token，窗口仍保留已读 value，不能把可行源值当成用户原值。
                                    local points={number,number-step/2,number+step/2,
                                        number-step/2+1e-12,number+step/2-1e-12,
                                        low,high,low+1e-12,high-1e-12}
                                    for _,point in ipairs(points)do
                                        if DurableNumberToken(point)==token and LegacyFloatFirstProjection(point)==value then
                                            witness,restored,model=point,value,"float32_fixed6";break
                                        end
                                    end
                                end
                                if witness~=nil then
                                    field.reason="tested"
                                    seen[token]=true;proof.attempts=proof.attempts+1
                                    if proof.attempts>32 then proof.status="budget";return nil end
                                    local candidate=DeepCopy(canonical)
                                    local window=codec~=nil and candidate.payload.widgetWindow or candidate.widgetWindow
                                    window[key]=witness
                                    local fp=self:FingerprintCanonicalValue(store,candidate)
                                    if fp==stamp then
                                        proof.matches=proof.matches+1;matched=candidate;matchedKey=key;matchedValue=restored
                                        proof.model=model;proof.matchedToken=token
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    proof.status=proof.matches==1 and "unique" or (proof.matches>1 and "ambiguous" or "no_match")
    proof.field=proof.matches==1 and matchedKey or nil
    -- 投影canonical与业务Domain不同（死亡codec / Buff历史schema），只修改声明的
    -- Domain叶子，保留已解码的完整历史/追踪集合；schema升级仍由调用方Core处理。
    if proof.matches==1 then
        local recovered=DeepCopy(decoded);recovered.widgetWindow[matchedKey]=matchedValue
        return matched,recovered
    end
    return nil
end

local ENVELOPE_SEAL_BUDGET = { maxDepth = 4, maxNodes = 96, maxStringBytes = 4096, maxEntriesPerTable = 32 }

function P:FingerprintEnvelopeIntegrity(raw)
    if type(raw) ~= "table" then return nil, "encoded payload must be table" end
    local meta = type(raw.__rsmeta) == "table" and raw.__rsmeta or nil
    if meta == nil then return nil, "metadata_missing" end
    local canonical = {
        framework = tostring(meta.framework or "<nil>"),
        store = tostring(meta.store or "<nil>"),
        owner = tostring(meta.owner or "<nil>"),
        contractVersion = tostring(meta.contractVersion or "<nil>"),
        lifetime = tostring(meta.lifetime or "<nil>"),
        scope = tostring(meta.scope or "<nil>"),
        schema = tostring(meta.schema or "<nil>"),
        periodId = tostring(meta.periodId or "<nil>"),
        reliabilityContract = tostring(meta.reliabilityContract or "<nil>"),
        integrityVersion = tostring(meta.integrityVersion or "<nil>"),
        encodedFingerprint = tostring(meta.encodedFingerprint or meta.payloadFingerprint or "<nil>"),
        envelopeIntegrityVersion = tostring(meta.envelopeIntegrityVersion or "<nil>"),
        scopeBindingContract = tostring(meta.scopeBindingContract or "<nil>"),
        scopeIdentityFingerprint = tostring(meta.scopeIdentityFingerprint or "<nil>"),
    }
    return self:FingerprintPayload(canonical, ENVELOPE_SEAL_BUDGET)
end

-- 事务回滚只还原 Domain/dirty，不能撤销 Native 写入；回读失败可能无 writeFenced，保存失败计数也可能已回滚。
-- 当前故障由 Core 统一判断，成功重试后移出故障集合、保留历史计数。单独 needsBarrierVerify 只是待验证，不能据此导出健康档。
function P:GetStoreFailureKind(storeOrId)
    local store = type(storeOrId) == "table" and storeOrId or self:GetStore(storeOrId)
    if type(store) ~= "table" then return nil end
    if store.writeFenced == true then return "write_fenced" end
    -- 成功Load或普通Save会清lastError，但可能保留历史verify/counter；不可因此导出健康档。
    -- 当前保存/屏障失败的正式调用链都会设置lastError；仅pending本身仍只是待验证。
    if NonEmptyText(store.lastError) == nil then return nil end
    if store.needsBarrierVerify == true then
        if store.lastVerifyOk == false then return "readback_failed" end
        if store.lastBarrierVerifyOk == false then return "barrier_failed" end
        if store.lastError ~= nil then return "save_failed" end
    end
    if (tonumber(store.consecutiveSaveFailures) or 0) > 0 then return "save_failed" end
    return nil
end

-- 用户点击时读取一个当前失败 Store 的 Native 返回表；不调用 LoadStore/default/decode/migrate/apply/Save/Clear。
-- Core 校验已解析键和角色 scope，页面只拿分离文本。快照不是磁盘原始字节，也不是恢复证明。
-- 可能含玩家名、追踪 ID 和布局，不自动发聊天；最多 256KiB ASCII，超限整体拒绝，页面隐藏后释放。
function P:BuildFailedStoreEvidenceText(id, options)
    local store = self:GetStore(id)
    -- 加载写保护与当前保存失败都可只读取证；其余健康 Store 仍拒绝。
    -- 保留旧错误码供旧维护工具兼容；scope/已解析 key/硬预算和 Native 原表序列化门不变。
    if self:GetStoreFailureKind(store) == nil then return nil, "store_not_fenced" end
    if store.lifetime == LIFETIME.Session or NonEmptyText(store.resolvedKey) == nil then
        return nil, "store_key_unresolved"
    end
    local bound, bindingError = CurrentScopeBinding(store)
    if bound ~= true then return nil, "evidence_scope:" .. tostring(bindingError) end
    if type(S.Api) ~= "table" or type(S.Api.LoadData) ~= "function" then return nil, "load_api_unavailable" end
    local ok, raw, readError = pcall(S.Api.LoadData, S.Api, store.resolvedKey)
    if not ok then return nil, "evidence_load_exception:" .. tostring(raw) end
    if readError ~= nil then return nil, "evidence_load_failed:" .. tostring(readError) end
    if type(raw) ~= "table" then return nil, "evidence_raw_type:" .. type(raw) end
    -- 先检查原始 Native 表，再序列化；拒绝环、非有限数、过深/过大表，不修正错误输入。
    local declared = store.encodedBudget or self.DefaultBudget
    -- 取证使用独立硬上限，并不扩大 Store 的预算；与离线解码器预算保持一致。
    local budget = {
        maxDepth = math.min(declared.maxDepth or 12, 15),
        maxNodes = math.min(declared.maxNodes or 4096, 64000),
        maxStringBytes = math.min(declared.maxStringBytes or 65536, 131072),
        maxEntriesPerTable = math.min(declared.maxEntriesPerTable or 1024, 4096),
    }
    local inspection = self:InspectPayload(raw, budget)
    if inspection.ok ~= true then return nil, "evidence_payload:" .. tostring(inspection.reason) end
    local snapshot = {
        store = store.id, key = store.resolvedKey, loadStatus = store.loadStatus,
        failure = tostring(store.lastError or store.writeFenceReason or ""),
        buildTag = tostring(S.BuildTag or "unknown"), luaVersion = tostring(_VERSION),
        capturedAtMs = NowMs(), source = "Native LoadData snapshot; unverified; not disk bytes",
        raw = raw,
    }
    -- 显式 compact 只移除外壳重复的 failure/key/build；完整 Native 表及 metadata 原样保留，scope/预算检查不变。
    -- 无参数仍用旧格式。输出须标明这是未验证的本次读取，不是恢复结果。
    if type(options) == "table" and options.compact == true then
        snapshot = { store = store.id, raw = raw }
    end
    local parts, size, limit = {}, 0, 262144
    local function Add(text)
        size = size + #text
        if size > limit then error("evidence_text_limit") end
        parts[#parts + 1] = text
    end
    local function Hex(text)
        -- HEX 保留任意 UTF-8/控制字节及 transport 哨兵；不会由聊天/文本框解释转义。
        return (text:gsub(".", function(c) return string.format("%02X", string.byte(c)) end))
    end
    local function Serialize(value)
        local kind = type(value)
        if kind == "nil" then Add("N;")
        elseif kind == "boolean" then Add(value and "B1;" or "B0;")
        elseif kind == "number" then Add("D" .. string.format("%.17g", value) .. ";")
        elseif kind == "string" then
            -- 先算编码后长度再分配 HEX，避免超限字符串产生无用的大临时副本。
            local prefix = "S" .. tostring(#value) .. ":"
            if size + #prefix + #value * 2 + 1 > limit then error("evidence_text_limit") end
            Add(prefix .. Hex(value) .. ";")
        elseif kind == "table" then
            local keys = {}
            for key in pairs(value) do keys[#keys + 1] = key end
            table.sort(keys, function(a,b)
                if type(a) ~= type(b) then return type(a) < type(b) end
                return a < b
            end)
            Add("T" .. tostring(#keys) .. "{")
            for _, key in ipairs(keys) do Serialize(key); Serialize(value[key]) end
            Add("}")
        else error("evidence_unsupported_type:" .. kind) end
    end
    local serialized, serializationError = pcall(Serialize, snapshot)
    if not serialized then return nil, tostring(serializationError) end
    local body = table.concat(parts)
    -- 此 checksum 只检测复制缺段/改字，不替代存档 integrity，不提供密码学认证。
    local checksum = string.format("%08X", HashText(146959810, body))
    return "RS-PERSIST-EVIDENCE-1\nBYTES=" .. tostring(#body) .. "\nCHECK=" .. checksum
        .. "\n" .. body .. "\nRS-PERSIST-EVIDENCE-END", nil
end

function P:BuildRuntimeAcceptanceSnapshot(options)
    options = type(options) == "table" and options or {}
    local exact = {}
    for _, id in ipairs(type(options.ids) == "table" and options.ids or {}) do
        id = NormalizeId(id)
        if id ~= "" then exact[id] = true end
    end
    local prefixes = {}
    for _, prefix in ipairs(type(options.prefixes) == "table" and options.prefixes or {}) do
        prefix = NormalizeId(prefix)
        if prefix ~= "" then prefixes[#prefixes + 1] = prefix end
    end

    local selected, missing = {}, {}
    local function Selected(id)
        if exact[id] == true then return true end
        for _, prefix in ipairs(prefixes) do
            if id:sub(1, #prefix) == prefix then return true end
        end
        return options.includeAllV3 == true and id:sub(1, 3) == "v3."
    end
    for id in pairs(exact) do if self.stores[id] == nil then missing[#missing + 1] = id end end
    for _, id in ipairs(self.order) do if Selected(id) then selected[#selected + 1] = id end end
    table.sort(selected)
    table.sort(missing)

    local rows, aggregate = {}, 104729
    local healthy, loaded, dirty, fenced, fingerprinted = 0, 0, 0, 0, 0
    for _, id in ipairs(selected) do
        local store = self.stores[id]
        local row = {
            id = id,
            owner = store.owner,
            scope = store.scope,
            lifetime = store.lifetime,
            schema = store.schemaVersion,
            loaded = select(1, self:IsStoreLoaded(id)) == true,
            terminalLoaded = store.loaded == true,
            loadStatus = store.loadStatus,
            dirty = store.dirty == true,
            writeFenced = store.writeFenced == true,
            writeFenceReason = store.writeFenceReason,
            dirtyRevision = math.max(0, math.floor(tonumber(store.dirtyRevision) or 0)),
            lastSavedRevision = math.max(0, math.floor(tonumber(store.lastSavedRevision) or 0)),
            needsBarrierVerify = store.needsBarrierVerify == true,
            lastBarrierVerifyOk = store.lastBarrierVerifyOk,
            lastBarrierVerifyError = store.lastBarrierVerifyError,
            resolvedKey = store.resolvedKey,
            resolvedScopeFingerprint = store.resolvedScopeFingerprint,
            lastScopeBindingError = store.lastScopeBindingError,
            lastIntegrityStatus = store.lastIntegrityStatus,
            lastIntegrityError = store.lastIntegrityError,
            historicalRecoveryProbe = store.lastHistoricalRecoveryProbe,
            integrityRecoveryTrace = store.lastIntegrityRecoveryTrace,
        }
        if row.loaded then loaded = loaded + 1 end
        if row.dirty then dirty = dirty + 1 end
        if row.writeFenced then fenced = fenced + 1 end

        if row.loaded ~= true then
            row.error = "store_not_loaded:" .. tostring(row.loadStatus or "not_loaded")
        elseif type(store.get) ~= "function" then
            row.error = "store_get_unavailable"
        else
            local ok, payload = pcall(store.get)
            if ok ~= true then
                row.error = "store_get_exception:" .. tostring(payload)
            else
                local fingerprint, fingerprintErr, inspection = self:FingerprintDurablePayload(payload, store.budget)
                row.fingerprint = fingerprint
                row.error = fingerprintErr
                row.nodes = inspection and inspection.nodes or nil
                row.stringBytes = inspection and inspection.stringBytes or nil
                if fingerprint ~= nil then
                    fingerprinted = fingerprinted + 1
                    aggregate = HashText(aggregate, id .. "=" .. fingerprint .. ";")
                end
            end
        end
        if row.loaded == true and row.writeFenced ~= true and row.error == nil then healthy = healthy + 1 end
        rows[#rows + 1] = row
    end

    for _, id in ipairs(missing) do aggregate = HashText(aggregate, "MISSING=" .. id .. ";") end
    return {
        contractVersion = self.RuntimeAcceptanceSnapshotContractVersion,
        fingerprintMode = "serializer_stable_numeric_v2",
        at = NowMs(),
        buildTag = tostring(S.BuildTag or ""),
        generation = tonumber(S.Generation) or 0,
        total = #rows,
        exactMissing = missing,
        healthy = healthy,
        loaded = loaded,
        dirty = dirty,
        fenced = fenced,
        fingerprinted = fingerprinted,
        aggregateFingerprint = string.format("%08X", math.floor(aggregate)),
        rows = rows,
    }
end

function P:GetPersistentKeys()
    local result = {}
    for _, id in ipairs(self.order) do
        local store = self.stores[id]
        if store ~= nil and store.lifetime ~= LIFETIME.Session and store.key ~= nil then
            local key = select(1, self:ResolveStoreKey(store)) or store.key
            result[#result + 1] = key
        end
    end
    table.sort(result)
    return result
end

function P:Describe()
    local rows = {}
    local dirty, fenced, contractV2, contractV3, scopePending, budgetProtected, envelopeBudgetProtected, unloadedDirty, registrationBudgetFailed, barrierPending = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    local currentFailures, currentFailureKinds = 0, {}
    for _, id in ipairs(self.order) do
        local store = self.stores[id]
        if store ~= nil then
            if store.dirty == true then
                dirty = dirty + 1
                if IsStoreReady(store) ~= true then unloadedDirty = unloadedDirty + 1 end
            end
            if store.writeFenced == true then fenced = fenced + 1 end
            if store.needsBarrierVerify == true then barrierPending = barrierPending + 1 end
            -- 历史 incident 成功重试后不清零；当前故障复用 GetStoreFailureKind，避免已恢复 Store 永久阻断。
            -- 这里只遍历内存，Describe 不读盘。
            local failureKind = self:GetStoreFailureKind(store)
            if failureKind ~= nil then
                currentFailures = currentFailures + 1
                currentFailureKinds[failureKind] = (tonumber(currentFailureKinds[failureKind]) or 0) + 1
            end
            if tonumber(store.contractVersion) and tonumber(store.contractVersion) >= 2 then contractV2 = contractV2 + 1 end
            if tonumber(store.contractVersion) and tonumber(store.contractVersion) >= 3 then contractV3 = contractV3 + 1 end
            if type(store.budget) == "table" then budgetProtected = budgetProtected + 1 end
            if type(store.encodedBudget) == "table" then envelopeBudgetProtected = envelopeBudgetProtected + 1 end
            if store.registrationBudgetOk ~= true then registrationBudgetFailed = registrationBudgetFailed + 1 end
            if store.loadStatus == "scope_pending" then scopePending = scopePending + 1 end
            rows[#rows + 1] = {
                id = store.id,
                owner = store.owner,
                lifetime = store.lifetime,
                scope = store.scope,
                contractVersion = store.contractVersion,
                schema = store.schemaVersion,
                loaded = IsStoreReady(store) == true,
                terminalLoaded = store.loaded == true,
                loadStatus = store.loadStatus,
                dirty = store.dirty == true,
                writeFenced = store.writeFenced == true,
                writeFenceReason = store.writeFenceReason,
                currentFailureKind = failureKind,
                periodId = store.periodId,
                baseKey = store.key,
                resolvedKey = store.resolvedKey,
                resolvedScopeFingerprint = store.resolvedScopeFingerprint,
                lastScopeBindingError = store.lastScopeBindingError,
            lastIntegrityStatus = store.lastIntegrityStatus,
            lastIntegrityError = store.lastIntegrityError,
            historicalRecoveryProbe = store.lastHistoricalRecoveryProbe,
            integrityRecoveryTrace = store.lastIntegrityRecoveryTrace,
                lastError = store.lastError,
                lastSaveAt = store.lastSaveAt,
                firstDirtyAt = store.firstDirtyAt,
                lastDirtyAt = store.lastDirtyAt,
                lastDirtyReason = store.lastDirtyReason,
                dirtyRevision = store.dirtyRevision,
                lastSavedRevision = store.lastSavedRevision,
                consecutiveSaveFailures = store.consecutiveSaveFailures,
                budget = DeepCopy(store.budget),
                encodedBudget = DeepCopy(store.encodedBudget),
                verifyAfterSave = store.verifyAfterSave == true,
                recoverableReplacement = store.recoverableReplacement == true,
                lastVerifyAt = store.lastVerifyAt,
                lastVerifyOk = store.lastVerifyOk,
                lastVerifyFingerprint = store.lastVerifyFingerprint,
                lastVerifyError = store.lastVerifyError,
                lastIntegrityStatus = store.lastIntegrityStatus,
                lastIntegrityFingerprint = store.lastIntegrityFingerprint,
                lastIntegrityError = store.lastIntegrityError,
                lastIntegrityDivergence = store.lastIntegrityDivergence,
                needsBarrierVerify = store.needsBarrierVerify == true,
                lastBarrierVerifyAt = store.lastBarrierVerifyAt,
                lastBarrierVerifyOk = store.lastBarrierVerifyOk,
                lastBarrierVerifyError = store.lastBarrierVerifyError,
                registrationBudgetOk = store.registrationBudgetOk == true,
                lastPayloadInspection = DeepCopy(store.lastPayloadInspection),
                lastEncodedInspection = DeepCopy(store.lastEncodedInspection),
                lastDecodedInspection = DeepCopy(store.lastDecodedInspection),
            }
        end
    end
    return {
        total = #rows,
        dirty = dirty,
        fenced = fenced,
        contractV2 = contractV2,
        contractV3 = contractV3,
        legacyContracts = #rows - contractV2,
        scopePending = scopePending,
        budgetProtected = budgetProtected,
        envelopeBudgetProtected = envelopeBudgetProtected,
        registrationBudgetFailed = registrationBudgetFailed,
        unloadedDirty = unloadedDirty,
        barrierPending = barrierPending,
        currentFailures = currentFailures,
        currentFailureKinds = DeepCopy(currentFailureKinds),
        frameworkVersion = self.FrameworkVersion,
        transportContractVersion = self.TransportContractVersion,
        transportScalarOmissionProtectionContractVersion = self.TransportScalarOmissionProtectionContractVersion,
        reliabilityContractVersion = self.ReliabilityContractVersion,
        integrityContractVersion = self.IntegrityContractVersion,
        legacyIntegrityContractVersion = self.LegacyIntegrityContractVersion,
        serializerNumericFingerprintContractVersion = self.SerializerNumericFingerprintContractVersion,
        envelopeIntegrityContractVersion = self.EnvelopeIntegrityContractVersion,
        scopeBindingContractVersion = self.ScopeBindingContractVersion,
        runtimeAcceptanceDiagnosticsContractVersion = self.RuntimeAcceptanceDiagnosticsContractVersion,
        runtimeAcceptanceSnapshotContractVersion = self.RuntimeAcceptanceSnapshotContractVersion,
        readinessContractVersion = self.ReadinessContractVersion,
        terminalLoadMemoizationContractVersion = self.TerminalLoadMemoizationContractVersion,
        historicalCanonicalRecoveryContractVersion = self.HistoricalCanonicalRecoveryContractVersion,
        knownLegacyCanonicalRecoveryContractVersion = self.KnownLegacyCanonicalRecoveryContractVersion,
        integrityRecoveryTraceContractVersion = self.IntegrityRecoveryTraceContractVersion,
        currentFailureSummaryContractVersion = self.CurrentFailureSummaryContractVersion,
        lastFlush = DeepCopy(self.lastFlush),
        rows = rows,
        stats = DeepCopy(self.stats),
    }
end
