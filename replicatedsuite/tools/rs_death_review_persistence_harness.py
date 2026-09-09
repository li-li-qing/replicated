#!/usr/bin/env python3
"""Real-Lua harness for DeathReview historical index persistence (.18.151).

Locks the RU regression reported on 2026-09-07:
- .18.143-.18.145 partial opaque widgetWindow v4 stamps recover only by exact historical hash match;
- missing default-TRUE business booleans are reconstructed only when the old stamp proves false;
- historical history.entries survive RU sequence/map key-shape drift only when the old stamp proves the recovered rows;
- recovered logical data is re-canonicalized by the current Store before Apply;
- native persistence may omit false/default fields and empty tables;
- canonical verification must rebuild the same logical window state and must
  not raise fingerprint_mismatch;
- repeated EnsureStoreLoaded attempts after a terminal failure are memoized at
  the persistence boundary (one physical incident per Lua generation).
"""
from __future__ import annotations

import pathlib
import subprocess
import tempfile
from rs_lua_runner import RUNNER

ROOT = pathlib.Path(__file__).resolve().parents[1]
PERSISTENCE = ROOT / "core/rs_persistence.lua"
DEATH_STORE = ROOT / "features/combat/death_review/rs_death_review_store.lua"

LUA = r'''
local function copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] ~= nil then return seen[value] end
  local out = {}; seen[value] = out
  for k, v in pairs(value) do out[copy(k, seen)] = copy(v, seen) end
  return out
end

local function dropFalseAndEmpty(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] ~= nil then return seen[value] end
  local out = {}; seen[value] = out
  for k, v in pairs(value) do
    if v ~= false then
      local nextValue = dropFalseAndEmpty(v, seen)
      if type(nextValue) ~= "table" or next(nextValue) ~= nil then
        out[k] = nextValue
      end
    end
  end
  return out
end

local storage = {}
local now = 12000
ReplicatedSuite = {
  BootError = nil,
  BuildTag = "death-review-persistence-harness",
  Generation = 1,
  SaveKey = "rs_death_review_harness",
  NowMs = function() return now end,
  Api = {},
  Utils = {},
  RSUI = {},
  Features = {},
}

function ReplicatedSuite.Utils.DeepCopy(value) return copy(value) end
function ReplicatedSuite.Utils.Trim(value)
  return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

-- Pure subset of the real FloatingSurface NormalizeState contract. The Store
-- intentionally depends on this Foundation normalizer so save/load canonical
-- state is identical to the Feature's HUD mutation boundary.
ReplicatedSuite.RSUI.FloatingSurface = {}
function ReplicatedSuite.RSUI.FloatingSurface:NormalizeState(value, policy)
  value = type(value) == "table" and value or {}
  policy = type(policy) == "table" and policy or {}
  local function clamp(v, lo, hi, fallback)
    local n = tonumber(v) or tonumber(fallback) or lo
    if n < lo then n = lo end
    if hi ~= nil and n > hi then n = hi end
    return n
  end
  local moved = value.userMoved == true
  local free = moved and tostring(value.coordinateSpace or "") == "logical-free-v2"
    and tonumber(value.x) ~= nil and tonumber(value.y) ~= nil
  local overall = tonumber(value.overallOpacity)
  if overall == nil then overall = tonumber(value.opacity) end
  return {
    width = clamp(value.width, math.max(1, tonumber(policy.minWidth) or 1), tonumber(policy.maxWidth), tonumber(policy.defaultWidth) or 420),
    height = clamp(value.height, math.max(1, tonumber(policy.minHeight) or 1), tonumber(policy.maxHeight), tonumber(policy.defaultHeight) or 286),
    minimized = value.minimized == true or (value.minimized == nil and policy.defaultMinimized == true),
    locked = value.locked == true or (value.locked == nil and policy.defaultLocked == true),
    overallOpacity = clamp(overall, 0, 1, tonumber(policy.defaultOverallOpacity) or 0.94),
    backgroundOpacity = clamp(value.backgroundOpacity, 0, 1, tonumber(policy.defaultBackgroundOpacity) or 1),
    textOpacity = clamp(value.textOpacity, 0, 1, tonumber(policy.defaultTextOpacity) or 1),
    fontScale = clamp(value.fontScale, 0.75, 1.50, 1),
    userMoved = moved,
    x = free and tonumber(value.x) or nil,
    y = free and tonumber(value.y) or nil,
    anchorH = moved and not free and (tostring(value.anchorH or "") == "RIGHT" and "RIGHT" or "LEFT") or nil,
    anchorV = moved and not free and (tostring(value.anchorV or "") == "BOTTOM" and "BOTTOM" or "TOP") or nil,
    offsetX = moved and not free and math.max(0, tonumber(value.offsetX) or 0) or nil,
    offsetY = moved and not free and math.max(0, tonumber(value.offsetY) or 0) or nil,
    coordinateSpace = moved and (free and "logical-free-v2" or "logical-edge-v1") or nil,
    savedUiScale = moved and tonumber(value.savedUiScale) or nil,
  }
end

function ReplicatedSuite.Api:SaveData(key, raw)
  -- Model RU representation drift across the BUSINESS payload, not just window
  -- presentation members. Metadata stays intact, so the independent envelope
  -- seal remains valid while false/default logical values may disappear.
  local disk = copy(raw)
  if type(disk.payload) == "table" then disk.payload = dropFalseAndEmpty(disk.payload) end
  storage[key] = disk
  return true, nil
end
function ReplicatedSuite.Api:LoadData(key) return copy(storage[key]), nil end
function ReplicatedSuite.Api:ClearData(key) storage[key] = nil; return true, nil end

dofile([[{PERSISTENCE}]])
dofile([[{DEATH_STORE}]])
local P = ReplicatedSuite.Persistence
local F = ReplicatedSuite.Features.DeathReview
local id = "v3.death_review"
local key = P.V3KeyPrefix .. "death_review_index"

assert(type(F.WidgetWindowSizePolicy) == "table", "window_policy_owned_by_store")
assert(F.PersistenceCanonicalWindowContractVersion == 7, "historical_index_canonical_v7") -- 中文维护注释：.18.193 要求 DeathReview 窗口 canonical 进入 Store-owned 投影 v7。
assert(P.TerminalLoadMemoizationContractVersion == 1, "terminal_memo_contract")
assert(P.HistoricalCanonicalRecoveryContractVersion == 3, "historical_canonical_contract")
assert(P.KnownLegacyCanonicalRecoveryContractVersion == 1, "known_legacy_canonical_contract") -- 中文维护注释：Core known-stamp 框架版本不变，本轮只扩展 Store 自己的精确事故 allowlist。
local deathStore = assert(P:GetStore(id)) -- 中文维护注释：测试读取唯一注册的 DeathReview Index Store，不构造第二 Persistence Authority。
assert(deathStore.schemaVersion == 2, "death_review_index_schema2") -- 中文维护注释：schema2 是 `.18.193` 当前 Index canonical generation，旧 schema1 仅用于迁移样本。
assert(F.PersistenceIndexSchemaContractVersion == 2, "death_review_index_schema_contract") -- 中文维护注释：Feature 契约必须与实际 Store schema 同步。
assert(F.PersistenceKnownLegacyRecoveryContractVersion == 2, "death_review_known_pair_contract_v2") -- 中文维护注释：Store recovery v2 必须包含 014277AB→0CF5BCC1 codec1 实机事故边界。
assert(type(deathStore.rebuildCanonicalForIntegrity) == "function", "historical_canonical_hook_registered")
assert(type(deathStore.recoverKnownLegacyCanonical) == "function", "known_legacy_hook_registered")

-- Exact .18.143-.18.145 compatibility probe.  Old Store canonicalization
-- passed widgetWindow through opaquely.  A real historical in-memory state can
-- therefore be PARTIAL (for example geometry + a few false/default appearance
-- fields), while RU disk representation omits false members.  Neither the raw
-- disk shape nor the current full FloatingSurface shape reproduces that stamp;
-- the bounded subset recovery must add back only the exact missing members.
local legacyCanonical = {
  settings = copy(F.State.settings),
  history = {
    serial = 17,
    entries = {
      {
        serial = 17, storageId = 4, time = 123456, clock = "12:34:56", windowMs = 10000,
        totalDamage = 54321, lethalSource = "HarnessSource", lethalAbility = "HarnessAbility",
        lethalAmount = 12000, eventCount = 3, debuffCount = 1,
      },
    },
  },
  widgetWindow = {
    width = 470,
    height = 330,
    minimized = false,
    locked = false,
    overallOpacity = 0.96,
  },
}
-- These are default-TRUE settings. If RU omits false, the disk payload cannot
-- distinguish "explicitly disabled" from "missing => default true" without the
-- already-stamped integrity fingerprint.
legacyCanonical.settings.autoShow = false
legacyCanonical.settings.showDebuffs = false
local legacyFingerprint = assert(P:FingerprintCanonicalValue(deathStore, legacyCanonical))
local currentCanonical = assert(P:CanonicalIntegrityValue(deathStore, legacyCanonical))
local currentFingerprint = assert(P:FingerprintCanonicalValue(deathStore, currentCanonical))
assert(legacyFingerprint ~= currentFingerprint, "historical_and_current_canonical_must_differ")
local legacyDiskPayload = dropFalseAndEmpty(legacyCanonical)
assert(legacyDiskPayload.widgetWindow.minimized == nil and legacyDiskPayload.widgetWindow.locked == nil, "ru_false_window_members_omitted")
assert(legacyDiskPayload.settings.autoShow == nil and legacyDiskPayload.settings.showDebuffs == nil, "ru_false_business_members_omitted")
-- Model the remaining RU table-shape drift class: the old canonical stamped a
-- sequence, while native storage returns the same bounded summary under a
-- string key. ipairs() now sees zero rows, pairs() still sees the row.
local legacySummary = assert(legacyDiskPayload.history.entries[1])
legacyDiskPayload.history.entries = { ["1"] = legacySummary }
assert(#legacyDiskPayload.history.entries == 0, "ru_history_sequence_shape_drifted")
local pairRows = 0; for _ in pairs(legacyDiskPayload.history.entries) do pairRows = pairRows + 1 end
assert(pairRows == 1, "ru_history_map_row_present")
local rawDiskFingerprint = assert(P:FingerprintCanonicalValue(deathStore, legacyDiskPayload))
assert(rawDiskFingerprint ~= legacyFingerprint, "raw_disk_shape_must_not_match_old_stamp")
local legacyRaw = {
  payload = copy(legacyDiskPayload),
  __rsmeta = {
    framework = P.FrameworkVersion, store = id, owner = "v3.death_review", contractVersion = deathStore.contractVersion,
    lifetime = P.Lifetime.Permanent, scope = P.Scope.Account, schema = 1, periodId = "permanent",
    reliabilityContract = P.ReliabilityContractVersion, integrityVersion = P.IntegrityContractVersion,
  },
}
legacyRaw.__rsmeta.encodedFingerprint = legacyFingerprint
legacyRaw.__rsmeta.envelopeIntegrityVersion = P.EnvelopeIntegrityContractVersion
legacyRaw.__rsmeta.envelopeFingerprint = assert(P:FingerprintEnvelopeIntegrity(legacyRaw))
storage[key] = legacyRaw
local recoveriesBefore = P.stats.integrityUpgradeRecoveries
local legacyOk, _, legacyErr = P:LoadStore(id)
assert(legacyOk == true, "legacy_partial_opaque_v4_recovers:" .. tostring(legacyErr))
assert(P.stats.integrityLoadFailures == 0, "legacy_recovery_not_counted_as_failure")
assert(P.stats.integrityUpgradeRecoveries == recoveriesBefore + 1, "legacy_recovery_counted_once")
assert(deathStore.lastIntegrityStatus == "historical_canonical_recovery", "historical_status")
assert(F.State.widgetWindow.width == 470 and F.State.widgetWindow.height == 330, "legacy_window_normalized_current_domain")
assert(F.State.widgetWindow.minimized == false and F.State.widgetWindow.userMoved == false, "legacy_defaults_restored")
assert(F.State.settings.autoShow == false and F.State.settings.showDebuffs == false, "legacy_false_business_settings_restored")
assert(F.State.history.serial == 17 and #F.State.history.entries == 1, "legacy_history_rows_restored")
assert(F.State.history.entries[1].serial == 17 and F.State.history.entries[1].storageId == 4, "legacy_history_identity_restored")
assert(type(deathStore.lastHistoricalRecoveryProbe) == "string" and deathStore.lastHistoricalRecoveryProbe:find("histIpairs=0/histPairs=1", 1, true) ~= nil, "history_shape_probe_records_drift")
assert(deathStore.lastHistoricalRecoveryProbe:find("matchBase=2", 1, true) ~= nil, "recovered_history_base_proved_by_old_hash")
assert(deathStore.dirty == true and deathStore.lastDirtyReason == "integrity_v4_upgrade", "legacy_restamp_queued")
assert(P:Flush() == true, "legacy_restamp_flush")
local stampedAfterRecovery = storage[key].__rsmeta.encodedFingerprint
assert(stampedAfterRecovery ~= legacyFingerprint, "legacy_stamp_replaced_with_current_canonical")
local reloadAfterRecovery, _, reloadAfterRecoveryErr = P:LoadStore(id)
assert(reloadAfterRecovery == true, "restamped_reload_verifies:" .. tostring(reloadAfterRecoveryErr))
assert(P:GetStore(id).lastIntegrityStatus == "verified_canonical", "restamped_codec_verifies")
assert(F.State.settings.autoShow == false and F.State.settings.showDebuffs == false, "false_business_settings_survive_restamped_reload")
assert(storage[key].codec == 1, "serializer_stable_codec_written")
assert(storage[key].payload.settings.autoShowDisabled == 1 and storage[key].payload.settings.showDebuffsDisabled == 1, "false_business_settings_use_numeric_sentinels")
assert(P:GetStore(id).dirty ~= true, "current_codec_does_not_loop_restamp")

-- Real-machine known-stamp migration bridge. 770CB0B8 is intentionally NOT the
-- hash of this synthetic payload: exact historical reconstruction must fail,
-- then the Store-owned exact stamp allowlist + strict legacy shape validator may
-- recover the still-present Domain and immediately restamp it. Any other stamp
-- remains fenced by the generic integrity path.
local knownLegacyPayload = {
  settings = { windowMs = 11100, maxHistory = 10, minDamage = 25 },
  history = { serial = 4, entries = {
    ["1"] = { serial = 4, storageId = 7, time = 4444, clock = "04:44:44", windowMs = 11100,
      totalDamage = 8888, lethalSource = "KnownSource", lethalAbility = "KnownAbility",
      lethalAmount = 2222, eventCount = 2, debuffCount = 0 },
  } },
  widgetWindow = { width = 470, height = 330, overallOpacity = 0.96 },
}
local knownRaw = {
  payload = copy(knownLegacyPayload),
  __rsmeta = {
    framework = P.FrameworkVersion, store = id, owner = "v3.death_review", contractVersion = deathStore.contractVersion,
    lifetime = P.Lifetime.Permanent, scope = P.Scope.Account, schema = 1, periodId = "permanent",
    reliabilityContract = P.ReliabilityContractVersion, integrityVersion = P.IntegrityContractVersion,
  },
}
knownRaw.__rsmeta.encodedFingerprint = "770CB0B8"
knownRaw.__rsmeta.envelopeIntegrityVersion = P.EnvelopeIntegrityContractVersion
knownRaw.__rsmeta.envelopeFingerprint = assert(P:FingerprintEnvelopeIntegrity(knownRaw))
storage[key] = knownRaw
local knownBefore = P.stats.knownLegacyCanonicalRecoveries
local knownOk, _, knownErr = P:LoadStore(id)
assert(knownOk == true, "known_legacy_stamp_recovers:" .. tostring(knownErr))
assert(P:GetStore(id).lastIntegrityStatus == "known_legacy_canonical_recovery", "known_legacy_status")
assert(P.stats.knownLegacyCanonicalRecoveries == knownBefore + 1, "known_legacy_counted")
assert(F.State.history.serial == 4 and #F.State.history.entries == 1 and F.State.history.entries[1].storageId == 7, "known_legacy_history_preserved")
assert(F.State.settings.windowMs == 11100 and F.State.settings.minDamage == 25, "known_legacy_settings_preserved")
assert(P:GetStore(id).dirty == true and P:GetStore(id).lastDirtyReason == "integrity_v4_upgrade", "known_legacy_restamp_queued")
assert(P:Flush() == true, "known_legacy_restamp_flush")
assert(storage[key].codec == 1 and storage[key].__rsmeta.encodedFingerprint ~= "770CB0B8", "known_legacy_rewritten_codec")
assert(P:LoadStore(id) == true and P:GetStore(id).lastIntegrityStatus == "verified_canonical", "known_legacy_second_reload_strict")

-- 中文维护注释：`.18.193` 还必须钉死 2026-09-09 RU 实机 schema1+codec1 old/new pair；这里直接执行 Store hook，避免用 synthetic payload 猜真实 014277AB 的原始业务内容。
local codecPairRaw = { -- 中文维护注释：构造严格 codec1 物理形状，只包含 DeathReview Index v1 编码允许的 settings/history/widgetWindow。
  codec = 1, -- 中文维护注释：实机事故已经进入 codec1 世代，因此不能误走 pre-codec 770CB0B8 兼容分支。
  payload = { -- 中文维护注释：payload 结构必须通过 Store-owned codec1 shape validator，未知字段应继续拒绝。
    settings = { windowMs = 10000, maxHistory = 10, minDamage = 0 }, -- 中文维护注释：默认 true 布尔在 codec1 中通过“缺少 Disabled sentinel”表达，不重新写 Lua false。
    history = { serial = 0, entries = {} }, -- 中文维护注释：空历史是合法 bounded Index 状态，不需要构造玩家/伤害业务数据。
    widgetWindow = { width = 470, height = 330, overallOpacity = 0.96 }, -- 中文维护注释：只使用已知 schema1 codec1 窗口字段，响应式新字段可缺失。
  }, -- 中文维护注释：结束 codec1 payload。
  __rsmeta = { schema = 1, store = id, owner = "v3.death_review" }, -- 中文维护注释：known-pair hook 必须再次绑定旧 schema/store/owner，不能只凭 fingerprint。
} -- 中文维护注释：结束 2026-09-09 codec1 known-pair 样本。
local codecPairDecoded, codecPairDecodeErr = deathStore.decode(codecPairRaw) -- 中文维护注释：复用生产 codec decoder 得到当前 Domain，测试不绕过 settings/history/window Normalize。
assert(type(codecPairDecoded) == "table" and codecPairDecodeErr == nil, "codec_pair_decodes") -- 中文维护注释：若 codec 本身不能正式解码，known-pair 迁移绝不能接受。
local codecPairCanonical = assert(P:CanonicalIntegrityValue(deathStore, codecPairDecoded)) -- 中文维护注释：current canonical 仍由生产 Store encode 生成，只有 Hash primitive 在下一步替换为实机观测值。
local originalCanonicalFingerprint = P.FingerprintCanonicalValue -- 中文维护注释：保存生产 Hash 函数，direct-hook 测试结束必须恢复，避免污染后续 persistence 测试。
P.FingerprintCanonicalValue = function() return "0CF5BCC1" end -- 中文维护注释：offline 无用户原始 payload，只注入诊断中已观测 current Hash；生产运行仍使用真实 durable fingerprint。
local codecPairRecovered, codecPairReason = deathStore.recoverKnownLegacyCanonical(codecPairDecoded, "014277AB", codecPairCanonical, codecPairRaw) -- 中文维护注释：old=014277AB 与 current=0CF5BCC1 同时命中才应返回当前 Normalize Domain。
assert(type(codecPairRecovered) == "table" and tostring(codecPairReason):find("schema1_codec1", 1, true) ~= nil, "codec_pair_exact_accept") -- 中文维护注释：精确 pair 应可保留现存 Index 数据并交给 Core 立即 schema2 重盖。
assert(deathStore.recoverKnownLegacyCanonical(codecPairDecoded, "014277AC", codecPairCanonical, codecPairRaw) == nil, "codec_pair_unknown_old_reject") -- 中文维护注释：只差一位的未知 old stamp 必须继续 fail-closed，禁止宽松 prefix/范围匹配。
P.FingerprintCanonicalValue = function() return "0CF5BCC2" end -- 中文维护注释：模拟同一 old stamp 对应不同当前内容，证明 old stamp 单独不能授权恢复。
assert(deathStore.recoverKnownLegacyCanonical(codecPairDecoded, "014277AB", codecPairCanonical, codecPairRaw) == nil, "codec_pair_wrong_current_reject") -- 中文维护注释：current Hash 不等于 0CF5BCC1 时必须维持 Fence，避免真实内容损坏被当成 canonical drift。
P.FingerprintCanonicalValue = originalCanonicalFingerprint -- 中文维护注释：恢复真实 Hash primitive，后续 unknown-stamp/普通 Save/Load 测试继续覆盖生产 Persistence 行为。

-- Unknown v4 stamp MUST NOT use the migration bridge.
local unknownRaw = copy(knownRaw)
unknownRaw.__rsmeta.encodedFingerprint = "770CB0B9"
unknownRaw.__rsmeta.envelopeFingerprint = assert(P:FingerprintEnvelopeIntegrity(unknownRaw))
storage[key] = unknownRaw
P:GetStore(id).loaded = false
P:GetStore(id).loadStatus = "not_loaded"
P:GetStore(id).writeFenced = false
P:GetStore(id).writeFenceReason = nil
P:GetStore(id).lastError = nil
local unknownOk = P:LoadStore(id)
assert(unknownOk == false, "unknown_legacy_stamp_stays_fenced")
assert(P:GetStore(id).writeFenced == true, "unknown_legacy_stamp_write_fence")

-- Restore a healthy current codec for the remaining ordinary canonical-window
-- path. The failed unknown probe is intentionally revalidated destructively only
-- inside this harness; production code never performs this reset.
storage[key] = copy(knownRaw)
storage[key].__rsmeta.encodedFingerprint = "770CB0B8"
storage[key].__rsmeta.envelopeFingerprint = assert(P:FingerprintEnvelopeIntegrity(storage[key]))
P:GetStore(id).loaded = false
P:GetStore(id).loadStatus = "not_loaded"
P:GetStore(id).writeFenced = false
P:GetStore(id).writeFenceReason = nil
P:GetStore(id).lastError = nil
assert(P:LoadStore(id) == true, "known_legacy_recover_again_for_test_reset")
assert(P:Flush() == true, "known_legacy_test_reset_flush")
local integrityFailuresAfterKnownStampTests = P.stats.integrityLoadFailures

-- Return to default-true business settings so the ordinary canonical-window
-- path below can still prove that representation-only false window omissions
-- verify directly without historical recovery.
F.State.settings.autoShow = true
F.State.settings.showDebuffs = true
F.State.settings.windowMs = 13500
F.State.widgetWindow = ReplicatedSuite.RSUI.FloatingSurface:NormalizeState({
  width = 503,
  height = 347,
  minimized = false,
  locked = false,
  overallOpacity = 0.96,
  backgroundOpacity = 1,
  textOpacity = 1,
  fontScale = 1,
  userMoved = false,
}, F.WidgetWindowSizePolicy)

assert(P:SaveStore(id) == true, "save")
assert(type(storage[key]) == "table", "disk_exists")
assert(storage[key].payload.widgetWindow.minimized == nil, "serializer_dropped_false_minimized")
assert(storage[key].payload.widgetWindow.locked == nil, "serializer_dropped_false_locked")
assert(storage[key].payload.widgetWindow.userMoved == nil, "serializer_dropped_false_userMoved")

-- Barrier readback must canonicalize the drifted disk representation back to
-- the same logical window state instead of declaring corruption.
assert(P:Flush() == true, "barrier_verifies_drift")
assert(P.stats.integrityLoadFailures == integrityFailuresAfterKnownStampTests, "no_integrity_failure_at_barrier")

now = now + 10
local ok, _, err = P:LoadStore(id)
assert(ok == true, "reload_accepts_canonical_window:" .. tostring(err))
assert(F.State.widgetWindow.width == 503 and F.State.widgetWindow.height == 347, "geometry_preserved")
assert(F.State.widgetWindow.minimized == false and F.State.widgetWindow.locked == false, "false_defaults_restored")
assert(F.State.widgetWindow.userMoved == false, "userMoved_restored")
assert(F.State.settings.windowMs == 13500, "business_setting_preserved")
assert(P:GetStore(id).lastIntegrityStatus == "verified_canonical", "canonical_verified")

-- Separate terminal memoization probe: one malformed store is physically read
-- once; subsequent LoadStore calls in the same generation return the memoized
-- terminal error without increasing integrity failures or touching LoadData.
local reads = 0
local originalLoadData = ReplicatedSuite.Api.LoadData
function ReplicatedSuite.Api:LoadData(k)
  if k == P.V3KeyPrefix .. "memo" then reads = reads + 1 end
  return originalLoadData(self, k)
end
local memoState = { value = 1 }
assert(P:RegisterV3Store({
  id = "v3.memo", owner = "v3.memo", scope = P.Scope.Account,
  lifetime = P.Lifetime.Permanent, schemaVersion = 1, legacySchemaVersion = 0,
  key = P.V3KeyPrefix .. "memo",
  budget = { maxDepth = 4, maxNodes = 64, maxStringBytes = 1024, maxEntriesPerTable = 32 },
  default = function() return { value = 0 } end,
  get = function() return copy(memoState) end,
  apply = function(v) memoState = copy(v) end,
  migrate = function(v) return { value = tonumber(type(v) == "table" and v.value) or 0 } end,
}))
local memoStore = P:GetStore("v3.memo")
local raw = {
  payload = { value = 5 },
  __rsmeta = {
    framework = P.FrameworkVersion, store = "v3.memo", owner = "v3.memo", contractVersion = memoStore.contractVersion,
    lifetime = P.Lifetime.Permanent, scope = P.Scope.Account, schema = 1, periodId = "permanent",
    reliabilityContract = P.ReliabilityContractVersion, integrityVersion = P.IntegrityContractVersion,
  },
}
raw.__rsmeta.encodedFingerprint = "DEADBEEF"
raw.__rsmeta.envelopeIntegrityVersion = P.EnvelopeIntegrityContractVersion
raw.__rsmeta.envelopeFingerprint = assert(P:FingerprintEnvelopeIntegrity(raw))
storage[P.V3KeyPrefix .. "memo"] = raw
local beforeFail = P.stats.integrityLoadFailures
local firstOk = P:LoadStore("v3.memo")
assert(firstOk == false, "memo_first_fails")
assert(P.stats.integrityLoadFailures == beforeFail + 1, "one_integrity_incident")
assert(reads == 1, "one_physical_read")
local secondOk = P:LoadStore("v3.memo")
assert(secondOk == false, "memo_second_still_fails")
assert(P.stats.integrityLoadFailures == beforeFail + 1, "no_duplicate_integrity_incident")
assert(reads == 1, "no_duplicate_physical_read")
assert(P.stats.terminalLoadShortCircuits >= 1, "memo_short_circuit_counted")

print("DEATH_REVIEW_PERSISTENCE_HARNESS PASS")
'''.replace("{PERSISTENCE}", str(PERSISTENCE.as_posix())).replace("{DEATH_STORE}", str(DEATH_STORE.as_posix()))


def main() -> int:
    store_src = DEATH_STORE.read_text(encoding="utf-8-sig")
    persistence_src = PERSISTENCE.read_text(encoding="utf-8-sig")
    for token in (
        "F.WidgetWindowSizePolicy = {",
        "local function NormalizeWidgetWindow(value)",
        "local function EncodeIndex(value)",
        "local function DecodeIndex(raw)",
        "local function RebuildV18_145Canonical(value, stampedFingerprint, currentCanonical, rawEnvelope)",
        "LEGACY_WINDOW_RECOVERABLE_KEYS = {",
        "LEGACY_DEFAULT_TRUE_SETTING_KEYS = {",
        "MAX_HISTORICAL_RECOVERY_MUTATIONS = 12",
        "KNOWN_LEGACY_V4_INDEX_FINGERPRINTS",  # 中文维护注释：必须继续保留 Store-owned exact fingerprint allowlist，而不是把事故 pair 放进 Persistence Core。
        '["014277AB"]',  # 中文维护注释：钉死 2026-09-09 RU schema1 codec1 的真实旧 stamp，防止维护时误删迁移桥。
        'currentFingerprint = "0CF5BCC1"',  # 中文维护注释：old/new pair 必须双向精确约束，不能只凭旧 stamp 接受任意当前内容。
        "recoverKnownLegacyCanonical = RecoverKnownLegacyV4Index",  # 中文维护注释：known-pair hook 必须注册到 Index Store，且只位于冷 Load 边界。
        "NormalizeHistoricalIndexWithRecoveredEntries",  # 中文维护注释：旧 RU sequence/map shape 恢复仍保留，避免 schema2 修复回退既有兼容。
        "lastHistoricalRecoveryProbe",  # 中文维护注释：失败必须保留无敏感业务内容的 runtime-only 诊断证据。
        "rebuildCanonicalForIntegrity = RebuildHistoricalIndexCanonical",  # 中文维护注释：`.18.193` 统一路由 pre-codec 与 schema1 codec1 两个历史 canonical 世代。
    ):
        if token not in store_src:
            raise AssertionError("DeathReview canonical window implementation missing: " + token)
    for token in (
        "TerminalLoadMemoizationContractVersion = 1",
        "HistoricalCanonicalRecoveryContractVersion = 3",
        "KnownLegacyCanonicalRecoveryContractVersion = 1",
        "rebuildCanonicalForIntegrity = def.rebuildCanonicalForIntegrity",
        "STORE_HISTORICAL_CANONICAL_RECOVERY",
        "historical_probe=",
        "recoverKnownLegacyCanonical = def.recoverKnownLegacyCanonical",
        "STORE_KNOWN_LEGACY_CANONICAL_RECOVERY",
        "terminalLoadShortCircuits = 0",
        "options.revalidateTerminal ~= true",
    ):
        if token not in persistence_src:
            raise AssertionError("Persistence terminal memoization missing: " + token)
    if RUNNER is None:
        print("DEATH_REVIEW_PERSISTENCE_HARNESS SKIP | lua runner unavailable")
        return 2
    with tempfile.NamedTemporaryFile("w", suffix=".lua", encoding="utf-8", delete=False) as fh:
        fh.write(LUA)
        tmp = pathlib.Path(fh.name)
    try:
        proc = subprocess.run([RUNNER, str(tmp)], capture_output=True, text=True)
    finally:
        tmp.unlink(missing_ok=True)
    if proc.returncode != 0:
        raise AssertionError((proc.stdout + proc.stderr).strip())
    if "DEATH_REVIEW_PERSISTENCE_HARNESS PASS" not in proc.stdout:
        raise AssertionError(proc.stdout.strip())
    print("DEATH_REVIEW_PERSISTENCE_HARNESS PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
