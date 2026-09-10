#!/usr/bin/env python3  # 中文维护注释：`.18.193` 专项 Harness 只验证 Activities/DeathReview Store canonical schema 边界，不连接游戏 Native API。
"""`.18.193` persistence schema/canonical-generation regression harness."""  # 中文维护注释：本测试防止共享 FloatingSurface 演进再次在同一 Store schema 内静默改变完整性指纹。
from __future__ import annotations  # 中文维护注释：保持项目 Python Harness 统一的类型注解语义，不影响运行时插件代码。

import pathlib  # 中文维护注释：只用标准库解析仓库相对路径，避免测试依赖调用者当前目录。
import subprocess  # 中文维护注释：Real-Lua 段通过独立解释器执行，确保验证的是 Lua 生产逻辑而不是 Python 重写。
import tempfile  # 中文维护注释：Lua 仿真脚本只写临时文件，测试结束立即删除，不污染项目与用户 Store。
from rs_lua_runner import RUNNER  # 中文维护注释：复用项目统一 Lua runner 解析逻辑，保持与其它 persistence Harness 一致。

ROOT = pathlib.Path(__file__).resolve().parents[1]  # 中文维护注释：项目根目录是所有源码断言的唯一 Authority，禁止依赖绝对开发机路径。
PERSISTENCE = ROOT / "core/rs_persistence.lua"  # 中文维护注释：读取真实 Persistence Core，验证 recovery/save 优先级没有被测试替身掩盖。
ACTIVITY_STORE = ROOT / "features/life/activities/rs_activity_store.lua"  # 中文维护注释：Activities Store 是 6271E40B→7E85D975 实机事故的业务 Authority。
DEATH_STORE = ROOT / "features/combat/death_review/rs_death_review_store.lua"  # 中文维护注释：DeathReview Store 同时验证 schema2 边界、Framework2 通用表形 exact-recovery 与旧 014277AB→0CF5BCC1 最终兜底。


def require(name: str, condition: bool) -> None:  # 中文维护注释：所有源码契约通过稳定名称 fail-fast，便于 Agent/CI 精确定位回归项。
    if not condition:  # 中文维护注释：任一 schema/recovery 安全门缺失都必须阻断发布，禁止带已知 Fence 风险交付。
        raise AssertionError(name)  # 中文维护注释：异常只输出契约名称，不输出任何用户存档业务数据。
    print("PASS", name)  # 中文维护注释：成功项保持现有 Harness 的简洁 PASS 输出格式。


def source_checks() -> None:  # 中文维护注释：静态检查钉死生产源码中的 schema/old-new pair/hook 注册，防止后续重构误删冷路径安全门。
    persistence = PERSISTENCE.read_text(encoding="utf-8-sig")  # 中文维护注释：只读 Core 源码验证完整性恢复的保存优先级，不执行写操作。
    activities = ACTIVITY_STORE.read_text(encoding="utf-8-sig")  # 中文维护注释：只读 Activities Store 验证 schema8 与 Store-owned window projection。
    death = DEATH_STORE.read_text(encoding="utf-8-sig")  # 中文维护注释：只读 DeathReview Store 验证 schema2 Framework2 serializer recovery、codec1 与旧 exact pair 的分层边界。
    require("activity_schema8", "local STORE_SCHEMA = 8" in activities and "local LEGACY_SCHEMA = 7" in activities)  # 中文维护注释：Activities 当前/上一代 schema 必须明确分世代，不能继续 schema7 内演进 canonical。
    require("activity_store_owned_projection", "CURRENT_WINDOW_KEYS" in activities and "HISTORICAL_V7_WINDOW_KEYS" in activities and "ProjectWindow" in activities)  # 中文维护注释：共享 Floating 只提供归一语义，Store 必须自己决定持久化字段形状。
    require("activity_exact_pair", 'KNOWN_V7_STAMP = "6271E40B"' in activities and 'KNOWN_V8_CANONICAL = "7E85D975"' in activities)  # 中文维护注释：实机 old/new Hash 必须双重精确匹配，不允许 wildcard mismatch recovery。
    require("activity_recovery_hooks", "rebuildCanonicalForIntegrity = function" in activities and "recoverKnownLegacyCanonical = RecoverKnownV7Canonical" in activities)  # 中文维护注释：exact historical recovery 必须先于 known-pair 最终桥且都由 Store 注册。
    require("death_schema2", "local INDEX_SCHEMA = 2" in death and "PersistenceIndexSchemaContractVersion = INDEX_SCHEMA" in death)  # 中文维护注释：DeathReview Index 已进入 schema2，record 分片 schema1 不应被误改。
    require("death_schema2_framework2_recovery", "PersistenceSchema2Framework2RecoveryContractVersion = 1" in death and "RebuildFramework2Schema2CodecV1Canonical" in death and "schema2fw2_codec1/ipairs=" in death)  # 中文维护注释：`.18.195` 必须以通用结构恢复覆盖 schema2+Framework2 sequence/map 漂移，禁止继续为不同用户内容追加 Hash 白名单。
    require("death_exact_pair", '["014277AB"]' in death and 'currentFingerprint = "0CF5BCC1"' in death)  # 中文维护注释：2026-09-09 schema1 codec1 实机 pair 仍作为更早世代最终 allowlist，不能因新通用路径而放宽成 wildcard。
    require("death_historical_router", "RebuildHistoricalIndexCanonical" in death and "rebuildCanonicalForIntegrity = RebuildHistoricalIndexCanonical" in death)  # 中文维护注释：pre-codec、schema1 codec1、schema2 Framework2 三代候选必须由统一冷路径路由按 metadata 分流。
    require("integrity_restamp_priority", "if deferredSaveReason == nil then -- 中文维护注释：若前面已经发生 integrity/historical/known-stamp recovery" in persistence)  # 中文维护注释：schema migration 不得覆盖 integrity recovery 的 0ms 立即重盖语义。


LUA = r''' -- 中文维护注释：以下 Real-Lua 仿真执行真实 Persistence + Activity Store，证明 schema7→8 exact recovery、重盖与 strict second reload。
local function copy(value, seen) -- 中文维护注释：测试 DeepCopy 仅复制 bounded 仿真表，不访问游戏对象或 Native userdata。
  if type(value) ~= "table" then return value end -- 中文维护注释：标量保持原值，符合 Persistence Domain 深拷贝预期。
  seen = seen or {} -- 中文维护注释：保留循环保护，即使本样本本身不构造环。
  if seen[value] ~= nil then return seen[value] end -- 中文维护注释：重复引用复用已创建目标，避免测试 helper 自己无限递归。
  local out = {}; seen[value] = out -- 中文维护注释：创建独立副本，防止 SaveData/LoadData 共享引用掩盖真实序列化边界。
  for k, v in pairs(value) do out[copy(k, seen)] = copy(v, seen) end -- 中文维护注释：测试数据规模固定且只在冷测试执行，不代表 Runtime Tick 逻辑。
  return out -- 中文维护注释：返回独立仿真表供 Persistence 读写。
end -- 中文维护注释：结束测试 DeepCopy。

local storage = {} -- 中文维护注释：内存表模拟 RU SaveData 物理存储，只用于本进程，测试结束即释放。
local now = 1000 -- 中文维护注释：固定时间源保证 debounce/dirty 结果可重复，不依赖真实系统时钟。
ReplicatedSuite = { BootError=nil, BuildTag="persistence-schema-18-193-harness", Generation=1, SaveKey="rs_18_193_harness", NowMs=function() return now end, Api={}, Utils={}, RSUI={}, Features={} } -- 中文维护注释：构造 Persistence/Store 所需最小 ReplicatedSuite 宿主，不加载任何 Feature Runtime。
function ReplicatedSuite.Utils.DeepCopy(value) return copy(value) end -- 中文维护注释：Store Normalize/Apply 使用真实调用形状但只操作纯 Lua 数据。
function ReplicatedSuite.Utils.Trim(value) return tostring(value or ""):match("^%s*(.-)%s*$") or "" end -- 中文维护注释：提供项目 Store 依赖的纯文本 helper，不涉及用户身份信息。
function ReplicatedSuite.Api:SaveData(key, raw) storage[key]=copy(raw); return true, nil end -- 中文维护注释：保存模拟完整物理 envelope，用于验证 schema8 立即重盖结果。
function ReplicatedSuite.Api:LoadData(key) return copy(storage[key]), nil end -- 中文维护注释：加载每次返回副本，避免内存引用让 fingerprint 校验失真。
function ReplicatedSuite.Api:ClearData(key) storage[key]=nil; return true, nil end -- 中文维护注释：仅实现 Persistence 测试契约，本 Harness 不依赖清档来修复旧数据。

ReplicatedSuite.RSUI.FloatingSurface = {} -- 中文维护注释：Foundation stub 只实现 Store 依赖的纯 NormalizeState 语义，不创建窗口或 Scheduler。
function ReplicatedSuite.RSUI.FloatingSurface:NormalizeState(value, policy) -- 中文维护注释：模拟 v11 窗口归一结果，包括导致 schema generation 演进的四个响应式元数据字段。
  value = type(value)=="table" and value or {}; policy = type(policy)=="table" and policy or {} -- 中文维护注释：输入缺失时使用纯默认表，保持与生产 normalizer 的容错方向一致。
  local function n(v, fallback) return tonumber(v) or tonumber(fallback) end -- 中文维护注释：固定仿真只需要数值回退，不复制生产 UI 的全部 clamp 细节。
  local moved = value.userMoved == true -- 中文维护注释：只有用户移动过的窗口才保存自由坐标与 source viewport 元数据。
  return { width=n(value.width, policy.defaultWidth), height=n(value.height, policy.defaultHeight), minimized=value.minimized==true, locked=value.locked==true, overallOpacity=n(value.overallOpacity or value.opacity, policy.defaultOverallOpacity or 0.94), backgroundOpacity=n(value.backgroundOpacity, policy.defaultBackgroundOpacity or 1), textOpacity=n(value.textOpacity, policy.defaultTextOpacity or 1), fontScale=n(value.fontScale,1), userMoved=moved, x=moved and n(value.x,0) or nil, y=moved and n(value.y,0) or nil, coordinateSpace=moved and tostring(value.coordinateSpace or "logical-free-v2") or nil, savedUiScale=moved and n(value.savedUiScale,1) or nil, savedLogicalWidth=moved and n(value.savedLogicalWidth,nil) or nil, savedLogicalHeight=moved and n(value.savedLogicalHeight,nil) or nil, normalizedCenterX=moved and n(value.normalizedCenterX,nil) or nil, normalizedCenterY=moved and n(value.normalizedCenterY,nil) or nil } -- 中文维护注释：响应式四字段故意存在于 v11 输出，用来证明 Store schema7 historical projection 与 schema8 current projection 分离。
end -- 中文维护注释：结束 FloatingSurface v11 仿真 normalizer。

dofile([[{PERSISTENCE}]]) -- 中文维护注释：执行真实 Persistence Core，所有 envelope/hash/recovery/save 行为均来自生产源码。
dofile([[{ACTIVITY_STORE}]]) -- 中文维护注释：执行真实 Activities Store，测试不复制其 schema/recovery 业务逻辑。
local P = ReplicatedSuite.Persistence -- 中文维护注释：后续只通过正式 Persistence API 操作唯一 Store Authority。
local F = ReplicatedSuite.Features.Activities -- 中文维护注释：读取 Activity Feature 的 Presentation 偏好 State 与公开契约标记。
local store = assert(P:GetStore("v3.activities")) -- 中文维护注释：必须成功注册唯一 v3.activities Store，否则本轮修复不可发布。
assert(store.schemaVersion==8 and store.legacySchemaVersion==7, "activity_schema_boundary") -- 中文维护注释：真实注册结果必须与源码契约完全一致。
assert(type(store.rebuildCanonicalForIntegrity)=="function" and type(store.recoverKnownLegacyCanonical)=="function", "activity_recovery_hooks") -- 中文维护注释：两个冷路径恢复 hook 必须同时存在且由 Core 调用。

local decoded = { widgetVisible=true, widgetRows=9, hiddenEvents={ ["event.alpha"]=true }, widgetWindow={ width=430, height=276, minimized=false, locked=false, overallOpacity=0.94, backgroundOpacity=1, textOpacity=1, fontScale=1, userMoved=true, x=120, y=80, coordinateSpace="logical-free-v2", savedUiScale=0.8, savedLogicalWidth=1600, savedLogicalHeight=900, normalizedCenterX=0.4, normalizedCenterY=0.5 } } -- 中文维护注释：样本包含 schema8 新响应式字段，确保 current/historical canonical 的 Hash 确实不同。
local current = store.migrate(copy(decoded)) -- 中文维护注释：当前 canonical 通过生产 Store migrate 生成，不能在 Harness 手写替代。
local historical = copy(current) -- 中文维护注释：从同一业务 Domain 派生旧 schema7 候选，只去掉 schema8 新增的响应式字段。
historical.widgetWindow.savedLogicalWidth=nil; historical.widgetWindow.savedLogicalHeight=nil; historical.widgetWindow.normalizedCenterX=nil; historical.widgetWindow.normalizedCenterY=nil -- 中文维护注释：这四个字段是本轮 schema generation 边界，其余活动偏好必须保持完全一致。
local oldFp = assert(P:FingerprintCanonicalValue(store, historical)) -- 中文维护注释：用真实 durable canonical Hash 生成 synthetic schema7 旧盖章。
local newFp = assert(P:FingerprintCanonicalValue(store, current)) -- 中文维护注释：用真实 current schema8 canonical Hash 证明新字段会改变指纹。
assert(oldFp ~= newFp, "activity_schema_generations_differ") -- 中文维护注释：若两代 Hash 未分离，本测试无法证明 schema bump 的必要性，应直接失败。
local raw = { payload=copy(decoded), __rsmeta={ framework=2, store="v3.activities", owner="v3.activities", contractVersion=store.contractVersion, lifetime=P.Lifetime.Permanent, scope=P.Scope.Account, schema=7, periodId="permanent", reliabilityContract=P.ReliabilityContractVersion, integrityVersion=P.IntegrityContractVersion, encodedFingerprint=oldFp, envelopeIntegrityVersion=P.EnvelopeIntegrityContractVersion } } -- 中文维护注释：磁盘保留同一业务数据但 stamp 认证 schema7 historical projection，模拟真实 canonicalizer 演进事故。
raw.__rsmeta.envelopeFingerprint = assert(P:FingerprintEnvelopeIntegrity(raw)) -- 中文维护注释：先生成合法独立 Envelope Seal，确保恢复只处理业务 canonical mismatch 而不是元数据损坏。
storage[P.V3KeyPrefix .. "activities"] = copy(raw) -- 中文维护注释：把旧档直接放入模拟物理 Store，不通过 current SaveStore 覆盖其历史 stamp。
local ok, _, err = P:LoadStore("v3.activities") -- 中文维护注释：执行完整生产 Load 路径：seal→decode→current hash→historical exact proof→migrate→Apply。
assert(ok==true, "activity_schema7_exact_recovery:" .. tostring(err)) -- 中文维护注释：可证明的 schema7 canonical 演进必须保留数据并解除 Fence。
assert(store.writeFenced~=true and (store.lastIntegrityStatus=="historical_canonical_recovery" or store.lastIntegrityStatus=="verified_canonical_recovered_representation"), "activity_exact_recovery_status") -- 中文维护注释：exact 旧候选若在剥离未认证新字段后又等于 current canonical，可标记 recovered-representation；两种合法状态都必须解除 Fence。
assert(F.State.widgetVisible==true and F.State.widgetRows==9 and F.State.hiddenEvents["event.alpha"]==true, "activity_business_preferences_preserved") -- 中文维护注释：UI 偏好业务字段必须完整保留，不允许为解 Fence 套默认值或清 Store。
assert(F.State.widgetWindow.savedLogicalWidth==nil and F.State.widgetWindow.normalizedCenterX==nil, "activity_unauthenticated_new_fields_dropped") -- 中文维护注释：exact 旧 stamp 没认证 schema8 新字段时必须保守丢弃，后续窗口移动可重新生成它们。
assert(store.dirty==true and (store.lastDirtyReason=="migration" or store.lastDirtyReason=="integrity_v4_upgrade"), "activity_schema8_rewrite_queued") -- 中文维护注释：exact candidate 若归一后 Hash 未变化只需 schema migration；若 current Hash 仍变化则保留 integrity_v4_upgrade 的 0ms 优先级，两者都必须排队写入 schema8。
assert(P:Flush()==true, "activity_schema8_restamp_flush") -- 中文维护注释：立即持久化当前 schema8 canonical，完成一次性迁移闭环。
assert(storage[P.V3KeyPrefix .. "activities"].__rsmeta.schema==8, "activity_schema8_written") -- 中文维护注释：物理 envelope 必须升级到 schema8，而不是只在内存解除 Fence。
assert(P:LoadStore("v3.activities")==true and store.lastIntegrityStatus=="verified_canonical", "activity_second_reload_strict") -- 中文维护注释：第二次 Fresh Reload 必须走普通严格验证，不能每次重复 known/historical recovery。

local directRaw = { payload=copy(decoded), __rsmeta={ schema=7, store="v3.activities", owner="v3.activities" } } -- 中文维护注释：direct-hook 样本只用于验证真实 6271E40B→7E85D975 allowlist 条件，Core envelope 安全已由上面的集成路径覆盖。
local originalDurable = P.FingerprintDurablePayload -- 中文维护注释：保存真实 durable Hash 函数，known-pair 注入测试结束必须恢复。
P.FingerprintDurablePayload = function() return "7E85D975" end -- 中文维护注释：offline 缺少用户原始 payload，仅注入诊断已观测的 current Hash；生产运行不会替换此函数。
local recovered, reason = store.recoverKnownLegacyCanonical(store.migrate(copy(decoded)), "6271E40B", store.migrate(copy(decoded)), directRaw) -- 中文维护注释：只有 schema7/store/owner + old/new exact pair + strict payload shape 同时满足才应恢复。
assert(type(recovered)=="table" and tostring(reason):find("6271E40B_7E85D975",1,true)~=nil, "activity_known_pair_accept") -- 中文维护注释：实机 pair 命中时必须保留当前 Normalize 后的用户偏好，交给 Core 立即重盖。
assert(store.recoverKnownLegacyCanonical(store.migrate(copy(decoded)), "6271E40C", store.migrate(copy(decoded)), directRaw)==nil, "activity_unknown_old_reject") -- 中文维护注释：未知 old stamp 继续 fail-closed，不能按 Store 名称宽泛接受 mismatch。
P.FingerprintDurablePayload = function() return "7E85D976" end -- 中文维护注释：模拟同一 old stamp 对应不同 current 内容，证明 current Hash 是第二重认证门。
assert(store.recoverKnownLegacyCanonical(store.migrate(copy(decoded)), "6271E40B", store.migrate(copy(decoded)), directRaw)==nil, "activity_wrong_current_reject") -- 中文维护注释：current Hash 不匹配时必须拒绝，避免真实数据改变被误判为 canonical drift。
local badRaw = copy(directRaw); badRaw.payload.futureField = true -- 中文维护注释：注入未知 future 字段验证 strict shape whitelist 不会吞掉未来 schema 或损坏数据。
P.FingerprintDurablePayload = function() return "7E85D975" end -- 中文维护注释：即使 old/new Hash 模拟命中，未知业务字段仍必须优先导致 shape reject。
assert(store.recoverKnownLegacyCanonical(store.migrate(copy(decoded)), "6271E40B", store.migrate(copy(decoded)), badRaw)==nil, "activity_unknown_shape_reject") -- 中文维护注释：known pair 绝不能绕过 Store-owned 业务结构验证。
P.FingerprintDurablePayload = originalDurable -- 中文维护注释：恢复真实 Hash primitive，保证 Harness 不留下跨测试全局副作用。
print("PERSISTENCE_SCHEMA_18_193_LUA PASS") -- 中文维护注释：Real-Lua 全部断言通过后输出唯一成功标记供 Python wrapper 验证。
'''.replace("{PERSISTENCE}", str(PERSISTENCE.as_posix())).replace("{ACTIVITY_STORE}", str(ACTIVITY_STORE.as_posix()))  # 中文维护注释：只替换可信本地源码路径，不拼接任何用户输入或外部命令。


def real_lua_check() -> None:  # 中文维护注释：执行一次独立 Lua 进程验证生产 Persistence/Activity Store 的真实组合行为。
    if RUNNER is None:  # 中文维护注释：正常项目环境应提供 texlua/lua；若工具解析异常则明确失败而不是伪装 PASS。
        raise AssertionError("lua_runner_unavailable")  # 中文维护注释：Persistence 修复属于 Lua Runtime 关键路径，发布门禁不能只靠静态文本断言。
    with tempfile.NamedTemporaryFile("w", suffix=".lua", encoding="utf-8", delete=False) as fh:  # 中文维护注释：临时脚本生命周期局限于本次 Harness，避免向项目添加仿真 Lua Runtime 文件。
        fh.write(LUA)  # 中文维护注释：写入上方固定测试脚本，不包含用户 Store 或真实角色数据。
        tmp = pathlib.Path(fh.name)  # 中文维护注释：保留临时路径用于独立解释器执行与 finally 清理。
    try:  # 中文维护注释：无论解释器成功或失败都必须进入 finally 删除临时脚本。
        proc = subprocess.run([RUNNER, str(tmp)], capture_output=True, text=True, timeout=60)  # 中文维护注释：Real-Lua 冷测试设置 60 秒硬上限，防止 CI/Agent 因解释器异常无限挂起。
    finally:  # 中文维护注释：测试文件清理不依赖断言结果，保持工作树可重复。
        tmp.unlink(missing_ok=True)  # 中文维护注释：只删除本 Harness 自己创建的临时文件，不触碰项目/用户存档。
    if proc.returncode != 0:  # 中文维护注释：Lua 解析或任一断言失败都必须阻断发布。
        raise AssertionError((proc.stdout + proc.stderr).strip())  # 中文维护注释：输出纯测试诊断，便于定位具体 contract token。
    require("activity_real_lua_schema_recovery", "PERSISTENCE_SCHEMA_18_193_LUA PASS" in proc.stdout)  # 中文维护注释：必须看到 Lua 末尾成功标记，不能只依赖退出码 0。


def main() -> int:  # 中文维护注释：专项 Harness 固定执行静态源码门禁后再执行 Real-Lua 行为门禁。
    source_checks()  # 中文维护注释：先检查 schema/pair/hook 是否仍存在，失败时避免启动无意义 Lua 仿真。
    real_lua_check()  # 中文维护注释：再证明真实 Persistence Core 与 Activities Store 能完成 schema7→8 一次性迁移闭环。
    print("PERSISTENCE_SCHEMA_18_193_HARNESS PASS")  # 中文维护注释：统一输出发布门禁成功标记。
    return 0  # 中文维护注释：0 表示全部专项契约通过，可继续执行全工程 Harness/Audit。


if __name__ == "__main__":  # 中文维护注释：只有直接运行本文件时执行门禁，import 不产生测试副作用。
    raise SystemExit(main())  # 中文维护注释：把 main 状态码交给 CI/Agent Shell，失败时保持非零退出码。
