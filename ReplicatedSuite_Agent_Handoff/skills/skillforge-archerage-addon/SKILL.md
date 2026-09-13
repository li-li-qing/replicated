---
name: skillforge-archerage-addon
description: "Use when developing or debugging ArcheRage RU Lua addons or Replicated Suite: PVP图标延迟/抖动、首领倒计时、HUD校准/默认模板、存档回读、RS-ERROR-PAGE复制、Buff追踪、询价及生命周期，或更新本技能。泛用Lua、UE5/UE Lua、AAEmu服务端和仅AAClassic不触发；服务器不明时先确认。"
compatibility: "阅读无需依赖；随包离线工具需Python 3.10+。Lua语法门禁另需可信的Lua 5.1可执行文件；不安装依赖、不联网、不操作客户端。"
metadata:
  revision: "2026.09.13-r2"
---

# ArcheRage RU 插件开发与排障

把用户可见行为对应到实际调用链，再修改首次失效的边界。当前代码、用户明确语义与现场证据决定方案；历史补丁、参考插件、技能中的参数只是带范围的线索。

## 开始与交付：六道门

1. **基线**：读取真实入口、TOC、当前说明与有关文件；确认原包、覆盖顺序、源码摘要、已加载标记和配置版本。已有材料可解决的问题自行读取。缺失的旧包不能靠对话总结重建。技能修改不等于修改游戏运行代码。
2. **契约**：写清操作后的可见结果、数据所有者、单位/时间/坐标空间、失败与未知、停用条件。Lua组件的Authority不是UE网络Authority；不植入UObject、OnRep或FastArray。
3. **证据**：分别标记用户观察、已读源码、本轮执行、历史测试和假设。API先查本地参考/当前门禁；新能力或可能变更的权限再核对有日期的一手来源。方法存在与pcall成功都不等于业务成功。
4. **复现**：先保留能暴露原断点的反例；原Native不可运行就用明确故障模型，但保留真实调度、EventBus、Diff、布局或codec中与故障有关的层。不把模型通过称为用户实机复现。
5. **修正**：使用现有Core/Services/Feature/UI与owner/generation；只扩大到证实同因的调用点。每个修改点写原因、所有权/数据流、兼容边界与维护风险。持续完成一轮，不逐小步索要确认；破坏性写入和无法推断的产品语义仍须确认。
6. **验证与发布**：重跑失败用例及相邻正常路径；用最终ZIP在确定基线上重建并复测。Lua5.4+shim不能代替Lua5.1；Lua5.1语法也不证明RU运行。缺工具/文件、跳过、历史通过分别报告。最终列完成内容、文件、性能、兼容风险和测试建议。

## 按症状取材

| 症状/任务 | 必读参考 |
|---|---|
| 加载、API、事件、新能力、Lua版本 | [运行时与API](references/runtime-and-api.md) |
| 保存回读、负坐标变零、旧配置/默认值 | [存档与诊断](references/persistence-and-diagnostics.md) |
| HUD移动抖动、人多换装图标不变、切人串图 | [PVP时效与渲染](references/pvp-hud-and-freshness.md) |
| 自己装备/敌人武器类型、职业图标、短状态/内置库 | [状态追踪契约](references/status-tracking-contracts.md) |
| 倒计时卡住、重复读条、首领漏技能、HUD不能调整 | [首领计时与布局](references/boss-alert-clock-and-layout.md) |
| 新组件不能校准、导出位置、设置发行默认 | [HUD模板与默认值](references/hud-template-and-defaults.md) |
| 点击、草稿、焦点、布局、隐藏与重载 | [UI与生命周期](references/ui-and-lifecycle.md) |
| 回调重入、取消复活、请求乱序、复用串数据 | [回调与请求契约](references/callback-and-request-contracts.md) |
| 完整报告、分页、等待后Ctrl+C失败 | [固定报告与复制](references/diagnostic-report-workflow.md) |
| DPS/HPS、报价、历史利润 | [战斗与价格](references/combat-and-price-contracts.md) |
| 每日净收益、原始计数含义不明 | [服务器日期账本](references/server-day-ledger.md) |
| 增量交付、模拟全绿、验收口径 | [回归与发布](references/regression-and-release.md) |
| 当前确为Replicated Suite | [项目边界](references/replicated-suite.md) |
| 增补Skills与经验分级 | [反馈](references/feedback.md)、[案例](references/maintenance-lessons-2026-09.md)、[来源](references/sources.md) |
| 需要机器检查 | [工具说明](references/verification-tools.md)、[行为评测办法](evals/README.md) |

只读取当前问题需要的主题，不把整个参考库压进每次任务。

## 必须保留的判断

**时效不靠堆频率。** 移动只更新位置；事实按事件与有界补采刷新，静态元数据缓存。连续事件合并待处理类别，保留最早期限；不能持续取消重排，把武器更新饿死。检查观测→调度→投影→原生写入的每段时间，不承诺50ms就是端到端延迟。

**未知不伪装成事实。** API未知不显示零；敌方类型不等于具体物品；未观测状态不等于不存在。旧目标/旧generation结果不能写当前HUD。原生拒写时不能推进“已显示”缓存。

**保存、默认、导出是不同动作。** 负数与旧指纹按真实codec验证；不排除差异字段、不清档。发行默认仅用于新建或用户明确恢复，旧canonical先验证再迁移。校准草稿导出不代表已保存；传输校验成功不代表默认值已应用。

**报告是固定快照。** 编辑框按实际回读容量分页，显式前后页；翻页不采样/读档/改ID。等待复制期间不空闲重写正文或重复改锚点；不无证据指认“2秒刷新”，不全局抢聊天焦点。

## 可执行检查

从本技能目录运行，先看`--help`，不要猜脚本参数：

```text
python scripts/verify_skill.py .
python -m unittest discover -s tests -v
python scripts/verify_report.py pages.txt --hud --output verified-layout.txt
python scripts/check_lua51.py --lua /path/to/lua5.1 /path/to/changed.lua
python scripts/audit_patch.py --base /path/to/baseline --current /path/to/current --zip /path/to/patch.zip
```

工具不提供无限安全保证。包结构通过≠Agent行为通过；复制一致≠源数据真实；ZIP一致≠运行测试通过。缺Lua5.1时门禁返回blocked，不用其他版本绿灯替代。文件名隐私筛查不能替代内容审阅。

同一故障多轮没有新证据时，停止再发同类猜测补丁，继续查首次失效层与取证缺口。用户已确认的无关功能不因旧日志重新扩张改动。新功能只有离线证据时保持“待实机验收”，不自动移除“未完成”。
