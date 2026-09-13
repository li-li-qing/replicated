# RU 2026-09-09 任务目标只读接口增量

复核日期：2026-09-12。

原始来源：RU服务器官方管理员发布的更新公告：
<https://ru.archerage.to/forums/threads/obnovlenie-09-09-2026.17558/>

公告“Аддоны / Включены следующие функции”明确列出：

```
X2Quest:GetQuestJournalObjectiveCount(idx)
X2Quest:GetQuestJournalObjectiveText(idx, objIdx)
```

本次在 `api_functions.lua` 中只将以上两项从 Available/not allowed 移到 Allowed，其他历史参考保持原状态。运行时能力注册区分官方允许与客户端验证；OfficialEnabled的依据是公告，不是已经测试成功。

公告也列出了 `X2Faction:GetExpeditionMemberCount()`，但本轮没有消费者，不在本次运行时任务改造中调用或扩展此能力。

接口签名没有完整说明返回类型/索引约定。当前适配复用工程的活动任务索引，先后验证索引对应的QuestID，仅接受整数数量和字符串目标；遇到返回形态不符时停止并记录，不猜字段。务必在RU客户端核对实际返回。

本公告未证明金币、经验、荣誉和生活点采集接口开放；禁止据此放开 `GetMyMoneyString`、`GetExpInfo`、`GetHeirExpInfo` 或 `GetGamePoints`。需要其他明确来源才能实现相应适配器。

此目录仅开发期参考，不进入运行时TOC。
