# Metadata 服务公共缓存基类评估

**评估日期**：2026-09-02  
**评估对象**：`services/rs_buff_metadata_v3.lua`（193 行）与 `services/rs_skill_metadata_v3.lua`（183 行）  
**评估范围**：是否抽公共 LRU cache 基类。**只出评估结论，不实现。**

---

## 1. 同构分析

两个服务的 cache 框架代码**完全同构**，重复约 50 行：

| 维度 | buff_metadata | skill_metadata | 同构？ |
|---|---|---|---|
| cache 字段 | `cache/order/orderHead/serial/cacheCount/cacheMax(512)/hits/misses/nativeLookups/nativeFailures/evictions` | 完全相同 | ✅ |
| `_EvictIfNeeded` | 行 58-82：while 循环 + orderHead 前进 + serial 校验 + compact | 行 71-96：完全相同 | ✅ 逐行同构 |
| `_Store` | 行 84-93：serial 自增 + `__cacheSerial` 标记 + cache/order 写入 | 行 97-106：完全相同 | ✅ 逐行同构 |
| `GetHealth` 基础字段 | `cached/cacheMax/hits/misses/nativeLookups/nativeFailures/evictions` | 完全相同 + 额外 `version/x2Info/x2Tooltip` | ✅ 基础部分同构 |
| LRU 策略 | order 数组 + orderHead 游标 + 256 阈值 compact | 完全相同 | ✅ |
| cacheMax | 512 | 512 | ✅ |
| miss 缓存 | `cache[key] = false` + cacheCount++ | `cache[key] = false` + cacheCount++（行 175） | ✅ |

**重复量**：`_EvictIfNeeded`(25行) + `_Store`(10行) + cache 字段声明(12行) + `GetHealth` 基础(10行) ≈ **57 行重复**。

---

## 2. 差异分析

| 维度 | buff_metadata | skill_metadata | 能否统一？ |
|---|---|---|---|
| Native 源 | `X2Ability:GetBuffTooltip(buffType, itemLevel)` | `X2Skill:Info(id)` + `X2Skill:GetSkillTooltip(id)` | ❌ 完全不同的 API |
| 解析逻辑 | tooltip 文本首行解析（string -> firstLine -> name）+ table 解析 | SafeInvoke + StaticSkill catalog fallback + name/icon 组合解析 | ❌ 逻辑结构不同 |
| cache 行结构 | `{name, iconPath, __cacheSerial}` | `{skillId, name, iconPath, resolved, source, __cacheSerial}` | ❌ 字段集不同 |
| 公开 API | `GetCached`(peek) + `Remember`(外部注入) + `GetInfo`(完整解析) | `GetSkillInfo`(完整解析 + fallbackName) | ❌ 签名和语义不同 |
| capability gate | `IsCapabilityAllowed("X2Ability:GetBuffTooltip")` | 无 gate（直接 SafeInvoke） | ❌ 安全策略不同 |
| 探测策略 | itemLevel {0,1,55} 循环探测 | 不探测，直接调 Info 再调 GetSkillTooltip | ❌ |
| fallback | 无（miss 返回 nil） | UNKNOWN_ICON + fallbackName + "技能 N" | ❌ |

**差异量**：Native 源、解析逻辑、cache 行结构、公开 API 签名、安全策略、探测策略、fallback 全部不同。

---

## 3. 抽基类方案（假设性设计，不实现）

如果抽公共基类，设计如下：

```
RsLruCache（基类，放入 core/ 或 services/）
├─ 字段：cache/order/orderHead/serial/cacheCount/cacheMax/hits/misses/evictions
├─ _EvictIfNeeded()        ← 完全复用
├─ _Store(key, row)        ← 完全复用
├─ GetCached(key)          ← 完全复用（peek）
├─ _CacheMiss(key)         ← 完全复用（cache[key]=false + cacheCount++）
└─ GetHealthBase()         ← 返回基础字段，子类追加自身字段

BuffMetadataV3（子类）
├─ 继承 RsLruCache
├─ nativeLookups/nativeFailures（自身字段）
├─ GetInfo(id)             ← Native 源 + 解析逻辑（buff 专属）
├─ Remember(id, name, icon) ← 外部注入（buff 专属）
└─ GetHealth()             ← 基类 + nativeLookups/nativeFailures

SkillMetadataV3（子类）
├─ 继承 RsLruCache
├─ nativeLookups/nativeFailures（自身字段）
├─ GetSkillInfo(id, fallback) ← Native 源 + 解析逻辑（skill 专属）
└─ GetHealth()             ← 基类 + version/x2Info/x2Tooltip
```

**去重量**：约 57 行（基类约 60 行，两个子类各省 57 行，净去重 57×2 - 60 = 54 行）。

---

## 4. 风险评估

| 风险 | 等级 | 说明 |
|---|---|---|
| 行为冻结原则 | **高** | 两个服务在生产环境运行，LRU eviction 顺序、miss 缓存、serial 校验逻辑必须**逐字节不变**。任何 compact 阈值或 eviction 条件的偏移都会改变 cache 命中率 |
| Harness 覆盖 | **中** | 当前 Harness 主要测 StatusDisplay/Healer 等消费方，没有专门测 metadata cache 的 eviction/compact 行为。抽基类前需要先补 cache 行为 Harness |
| Lua 5.1 继承 | **低** | Lua 5.1 无 class 关键字，用 metatable `__index` 模拟。项目已有 `S.Services.XxxV3` 模式，基类放入 `S.Services.RsLruCache` 即可 |
| 回归范围 | **中** | buff_metadata 被 AuraObservationV3/BuffDisplay 消费；skill_metadata 被 CombatAnalytics/DamageReview 消费。回归需要跑 4 套 Harness（status_display/combat_analytics/death_review/foundation_gate） |

---

## 5. 收益评估

| 指标 | 值 |
|---|---|
| 净去重 | ~54 行 |
| 新增基类 | ~60 行 |
| 新增复杂度 | metatable 继承 + 子类 override 约定 |
| 当前消费者 | 2 个（buff + skill） |
| 未来潜在消费者 | item_metadata / auction_metadata / quest_metadata（均未确认） |

---

## 6. 结论

**当前不建议抽公共基类。**

理由：

1. **收益不足**。54 行净去重对于一个 197 文件的工程是噪音级收益，而引入 metatable 继承 + 子类 override 约定增加了阅读复杂度。
2. **差异远大于共性**。两个服务的 Native 源、解析逻辑、cache 行结构、公开 API、安全策略、探测策略、fallback **全部不同**。基类只能抽 cache 框架（57 行），其余逻辑仍在子类。
3. **行为冻结风险**。LRU eviction/compact 逻辑在生产环境运行，抽基类要求逐字节不变，但当前没有专门测 cache 行为的 Harness。先补 Harness 再抽基类的成本 > 直接保留两份同构代码的成本。
4. **YAGNI**。当前只有 2 个消费者。"如果未来出现第 3 个 metadata 服务再抽"是更安全的策略——届时会有第三个数据点帮助确认基类边界。

**触发条件**（满足任一即可重新评估）：
- 出现第 3 个 metadata 服务（item/auction/quest），且其 cache 框架与现有两个同构
- buff 或 skill metadata 的 cache 框架出现 bug，需要统一修复
- cacheMax/eviction 策略需要统一调优（当前两个都是 512，但调优时机未到）

---

## 7. 如果用户批准抽基类的实施清单

以下清单仅在用户明确批准后执行，当前不实施：

1. 新建 `services/rs_lru_cache_base.lua`，放入 `RsLruCache` 基类（cache 字段 + `_EvictIfNeeded` + `_Store` + `GetCached` + `_CacheMiss` + `GetHealthBase`）
2. 在 `toc.g` 中按加载顺序插入基类（在 buff_metadata 和 skill_metadata 之前）
3. `rs_buff_metadata_v3.lua` 改为继承 `RsLruCache`，删除同构代码，保留 Native 源和解析逻辑
4. `rs_skill_metadata_v3.lua` 同上
5. 新建 `.workbuddy/tmp/lru_cache_harness.lua`，专门测 eviction 顺序 / compact 阈值 / miss 缓存 / serial 校验
6. 跑 4 套回归 Harness + 新 cache Harness + Foundation Audit + toc.g 对账
7. 同步 `Docs/Architecture/SERVICE_ARCHITECTURE.md`
