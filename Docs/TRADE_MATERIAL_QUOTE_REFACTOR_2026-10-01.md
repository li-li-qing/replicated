# 跑商材料报价重构：差量覆盖说明

基线：用户提供的 `replicatedsuite(4).zip`。本包仅包含本次修改/新增文件，保留 `replicatedsuite/` 原目录层级；不是完整插件包，不混入其它历史补丁。

## 改动

- 新增 V3 `TradeMaterialQuoteServiceV3`。双击按唯一 `itemType + itemGrade` 处理配方；已有缓存立即参与成本，只有缺价进入前台串行单次查询；重复材料不重复发包，重复点击不扩大请求。
- Fresh `<6h` 直接复用；Warm `6–24h`、Stale `1–7d` 立即复用并在后台更新，Warm 优先于 Stale；`>=7d` 或无法确定年龄的旧记录在跑商侧视为缺价，原记录不删除。保留已确认的新会话报价降级读取。
- 严格路径每个材料最多一次 `SearchAuctionArticle`，按既有结果顺序读取首个身份和品质均匹配、数量与一口价有效的单位价即停止；不调用 Ask/Get 组合，不扩品质、不翻页、不重试，也不为异常价追加第二次搜索。
- 前台任务设置 5 秒截止，结束为成功、部分未知、受阻或失败。截止时尚未查询/未返回的材料仍明确未知；不以 0 补价，不伪造毛利。正常快速回包的 4 项材料测试在 0/1/2/3 秒各发一次请求。
- 前台排在插件后台前；已发出的无令牌原生搜索不能抢占。原生窗口打开/状态未知时前台明确结束，后台停在原有队列，确认关闭后恢复；未知状态最多等待 45 秒。取消或模块关闭释放 owner/watcher/计时器；已发搜索仍保留原生隔离期，防止串回包。
- 移除跑商旧 `force`/品质阶梯重验与“只凭物品身份的全局事件完成任务”路径。当前操作只接受自己的回调；共享事件仅刷新价格投影。其他模块继续使用原队列默认协议。
- 更新页面/详情提示与回归测试，纳入默认测试入口。配方数量、售价、货率、新鲜度售价系数、毛利公式及存档 ID/schema 均未更改；未新增四项材料截断，既有 32 项投影安全上限仍保留且会明确标记不完整。

## 验证

真实 Lua 5.1 引擎运行（Lupa 2.8 的 `lua51` 后端，临时 CLI 包装器）；不是 Lua 5.4 兼容垫片的结果。

- `python tools/rs_lua51_compile_gate.py`：299 个运行时 Lua 文件编译通过
- 默认 `python tools/rs_status_refactor_test_runner.py`：退出码 0
- `--trade-requote`：4 套通过（严格传输 29/29、配方服务 11/11、旧共享队列 24/24、Trade 端到端 17/17）
- `--auction-user-priority`：4 套通过
- `--trade-gear-reliability`：8 套通过
- 材料/利润证据 16/16；包含货率变化重算利润、同材料 2+3 件按 5 件计成本且只查询一次
- `python tools/rs_trade_optimization_tests.py`：通过
- 架构审计：0 问题；Native 依赖审计：0 errors/blockers/warnings；安装清单：299/299，无冲突标记

测试先复现新契约缺失与回调取消缺陷，再修改生产代码；保留旧消费者专门回归，未删除默认测试或缺失夹具门禁。

## 仍需 RU 实机核验

离线测试不能证明真实服务器响应时间，也未进行游戏登录/安装/实机交易。5 秒是调度截止目标，届时允许明确部分未知，绝不宣称全部材料必然成功。

本包未提供 `z_api_functions` / `ui_functions` 参考库；沿用源码中已核验的 9 参数搜索 ABI，不猜新 API 或排序参数。结果是“既有返回顺序的首个有效匹配单位价”，未证明它等于全市场最低价；真实 RU 的排序、挂单数据及可见性返回仍需验收。异常候选保护仍保留，但不会在同次操作自动追加确认查询。

## 文件清单

- `replicatedsuite/features/life/trade/rs_trade_feature.lua`
- `replicatedsuite/features/rs_feature_registry.lua`
- `replicatedsuite/presentation/v3/pages/rs_v3_life_m16_pages.lua`
- `replicatedsuite/presentation/v3/widgets/rs_v3_life_economy_widgets.lua`
- `replicatedsuite/presentation/v3/widgets/rs_v3_trade_detail_floating.lua`
- `replicatedsuite/services/rs_auction_query_v3.lua`
- `replicatedsuite/services/rs_material_price_service_v3.lua`
- `replicatedsuite/services/rs_price_quote_queue_v3.lua`
- `replicatedsuite/services/rs_trade_material_quote_service_v3.lua`
- `replicatedsuite/toc.g`
- `replicatedsuite/tools/rs_auction_full_lane_trade_tests.lua`
- `replicatedsuite/tools/rs_status_refactor_test_runner.py`
- `replicatedsuite/tools/rs_trade_cost_retry_tests.lua`
- `replicatedsuite/tools/rs_trade_economics_evidence_tests.lua`
- `replicatedsuite/tools/rs_trade_material_quote_service_tests.lua`
- `replicatedsuite/tools/rs_trade_optimization_tests.py`
- `replicatedsuite/tools/rs_trade_requote_e2e_tests.lua`
- `replicatedsuite/tools/rs_trade_requote_test_host.lua`
- `replicatedsuite/tools/rs_trade_single_query_transport_tests.lua`
- `replicatedsuite/tools/rs_trade_tests.lua`
- `replicatedsuite/Docs/TRADE_MATERIAL_QUOTE_REFACTOR_2026-10-01.md`（本说明）
