# Replicated Suite Trade Native Dependency Fix — 2026-09-28

Build: `v3-m1.16.0.18.327-trade-native-dependency-ownership`

## 现象

实机 `life_trade` 模块诊断中：

- 货率路线正常，`lastRatioParsedRows=8`；
- `X2Craft:GetCraftTypeByItemType` 显示 `Unavailable ... host_global_missing`；
- `PriceQuoteQueueV3` 的 `marketPriceAsks=207 / marketPriceAskFailures=207`；
- `MaterialPriceServiceV3 entries=0 / writes=0 / misses=11501`；
- RowJob 因材料报价不可用全部 failed。

## 根因

`FeatureRuntime:Initialize()` 以实现层 `impl.ApiDependencies` 为 Native Import Authority。

Trade 的真实调用链已经依赖：

- `TradeMaterialIdentityV3 -> X2Craft:*`；
- `PriceQuoteQueueV3 / AuctionQueryV3 -> X2Auction:*`。

但 `Trade.ApiDependencies` 只声明 Store / Ability / Equipment；Registry 也没有完整声明 Craft/Auction 依赖。因此单独启用跑商时不会导入 `X2Craft`/`X2Auction` namespace。若制作/拍卖 Feature 恰好先启用，问题可能被偶然掩盖，形成 Feature 间隐性强耦合。

## 修复

Trade 现在独立声明并导入完整的 14 项 Native dependency：

- X2Store x3
- X2Ability x1
- X2Equipment x2
- X2Craft x3
- X2Auction x5

实现层与 FeatureRegistry 保持一致；没有新增轮询、事件或第二个报价 Authority。拍卖查询仍全部经过 `PriceQuoteQueueV3` 单 lane 节流。

## 验证

- `texlua tools/rs_trade_tests.lua` -> 22/22 PASS
- `python tools/rs_trade_optimization_tests.py` -> PASS
- `python tools/rs_status_refactor_test_runner.py --syntax` -> 378 Lua PASS (Lua 5.4 compatibility runtime)
- Architecture Audit -> 49 个既有债务，无新增类别
- Full Regression 仍只因 2 个历史证据 fixture 缺失而 BLOCKED；未删除/伪造门禁。

## 用户实机复测重点

Fresh Reload 后只开启跑商也必须：

1. `provider.describeidentitystate.live.lastError` 不再出现 `host_global_missing`；
2. QuoteQueue `marketPriceAskFailures` 不应再因 capability unavailable 与 asks 1:1 增长；
3. MaterialPrice cache 应逐步出现 entries/writes；
4. [黄金]保存特产/保存特制特产 RowJob 应从 failed 转为 ready/partial（如果拍卖确实无对应材料，则允许诚实 unavailable）；
5. 不要求开启“拍卖助手”或“制作助手”才能让跑商材料报价工作。
