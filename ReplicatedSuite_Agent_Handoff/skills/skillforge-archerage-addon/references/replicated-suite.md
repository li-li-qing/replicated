# Replicated Suite 项目边界

只在当前工程确为 Replicated Suite 时读取。本页是 2026-09-12 的取材索引，不是永远有效的架构命令；实际任务重新核对目录、加载清单、入口和项目说明。

## 当时的有效代码位置

以下路径相对于项目中的 `replicatedsuite` 目录，复制技能不需要复制项目源码。

| 位置 | 用于回答的问题 |
|---|---|
| `replicatedsuite.lua`、`toc.g` | `ArchitectureMode`、初始化、旧运行时停止、加载顺序 |
| `native/`、`core/rs_api.lua`、`core/rs_api_capabilities.lua` | Native 导入、调用返回、能力门禁与冷却 |
| `core/`、`services/` | 需求、调度、共享事实、持久化与诊断 |
| `features/` | 功能状态、Commands、业务与投影的实际职责 |
| `presentation/v3/`、`ui/framework/` | 当前页面、控件、布局与输入链 |
| `core/rs_persistence.lua`、`core/rs_self_check_report.lua` | 实际存档版本、回读校验、报告预算与原文获取 |
| `tools/` | 当时存在的局部检查和模拟夹具；先读入口与参数 |

当时源码设置 `ArchitectureMode = "v3_rebuild"`。旧技能引用 Professional 页面、`globals/`、已删除的审计工具，会把修复引向错误运行链；同时根说明声称 tools 已删除，但当前 tools 又有新脚本。不能机械地选“文档永远优先”或“文件存在就必须运行”：核对具体脚本、架构及故障覆盖。

## 复用现有职责

- 当前项目通过 Native 边界导入宿主对象和 API；不要在普通功能代码另起一套导入或把社区 `globals` 整套搬进来。
- 服务保存可复用事实，功能层处理业务命令和投影，UI 消费状态。先确认具体实现，再选改动所在层，不让 UI 维护第二份业务真相。
- 需求、任务和订阅沿当前 owner/generation 清理机制管理。隐藏 HUD 与禁用功能不是同一动作；共享服务的其他消费者仍有需求。
- 当时有 `tools/rs_status_refactor_test_runner.py` 等脚本，而旧 `rs_foundation_audit.py` 已不在当前工具中。前者也不自动覆盖本轮故障，须先读用途。
- 执行现有项目工作流，按改动选检查。不要因旧技能要求就恢复旧工具、添加全量审计或生成一批说明文件。

## 当前经验的状态

持久化报告与源码均显示新旧格式并存、回读声明校验和数值表示是不同问题。项目报告中的模拟通过、收到过的用户日志和本次读取源码要分开记录；本技能没有重新运行这些游戏案例。

用户反馈中新出现的 Store、API 或 UI 故障仍须独立定位；不能凭旧案例就套用恢复算法。进一步细节见[存档与诊断](persistence-and-diagnostics.md)及[取材记录](sources.md)。

## 本轮开发经验增补：只作当前工程的索引

本轮来自用户连续反馈及已交付文件，不回写上面的历史取材指纹。已更替的流程以这里链接的主题为准，下一次仍须核对实际文件：

| 场景 | 本轮定位符号/位置（相对Replicated Suite） | 读取主题 |
|---|---|---|
| 完整自检与上一页/下一页 | `core/rs_self_check_report.lua`、`core/rs_report_copy_transport.lua` | [固定报告分页](diagnostic-report-workflow.md) |
| 长追踪ID序列与数值证明 | `core/rs_persistence.lua`、状态显示Store的注册与历史恢复 | [存档格式](persistence-and-diagnostics.md) |
| 新建名称、隐藏搜索框、strict text误报 | `ui/rs_ui_framework.lua`的原生文字草稿及`ui/framework/rs_ui_controls.lua` | [UI交接](ui-and-lifecycle.md) |
| 内置库图标/导入、持续留存 | `rs_buff_display_management.lua`、`rs_buff_metadata_v3.lua`、`rs_aura_observation_v3.lua` | [追踪模型](status-tracking-contracts.md) |
| 询价长队列与晚到结果 | `services/rs_price_quote_queue_v3.lua`、`features/life/rs_life_m16_bundle.lua` | [有限询价](combat-and-price-contracts.md) |
| 总览与日期账本 | `rs_v3_home_overview.lua`、`features/life/rs_daily_ledger.lua` | [日账本](server-day-ledger.md) |

这里的Core/Services/Feature/UI分层及Diff Authority属于Lua客户端插件；不要套入UE的UObject、RepNotify或FFastArraySerializer。用户的UE/LGF习惯只在对应工程生效。

保留最新用户语义：冻结是持续留存；报告是固定正文显式分页；一键导入写入用户选择；首页复用真实模块数据；日统计无验证源不显示假零。各行为的开关、隐藏和跨重载政策要从当前实现核对，不能仅按名称推定。

项目交付仅含本次改变文件并保持相对路径，API开发参考变化才随包；不把UDF、Git、临时夹具或不相关目录打入。每个修改点说明原因、所有权/数据流、兼容边界和维护注意。完整验证与最终五段汇报见[回归与发布](regression-and-release.md)。小改无需复制整份工程或新建一组重复审计文档。

## 2026-09-13增补索引（不取代实际源码核对）

本次实际只读重建了`Addon(20260912-140314).zip`与本对话后续9份增量。对应顺序、包摘要和相关文件片段见[本轮来源](maintenance-evidence-2026-09-13.json)。该重建用于技能取材，不等于用户本机必定已经按此顺序覆盖。

- `rs_buff_display_feature.lua::_QueueEventRefresh`、`rs_v3_buff_head_markers.lua`：最早期限合并、事实/位置分离、原生写确认。
- `services/rs_alerts_service.lua::EnsureTimer/Tick`、`rs_v3_alert_hud.lua`：倒计时截止点、任务存在性、可编辑HUD与来源归属。
- `rs_v3_buff_hud_calibration.lua`、`rs_buff_display_store.lua`：CLASS独立校准、V2报告、旧canonical与新默认分离。
- `core/rs_persistence.lua`、`rs_self_check_report.lua`、`ui/rs_ui_framework.lua`：负值保护、后续耐久失败取证、报告框选择区稳定。

不把旧注释或补丁名当因果证明：当前Feature仍有历史1000ms装备注释而实际lane返回200ms，查执行分支和调用者；变更时同步相关注释，避免文档继续传播过期参数。
