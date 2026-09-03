# Strangler Migration（历史迁移方法论 · 已结束）

> **归档说明**：本节原属 `Docs/Rebuild/REBUILD_BLUEPRINT.md` §16.2。旧版（Legacy/Professional）源码已于 2026-09-01/02 全部物理删除，Strangler 渐进迁移阶段已结束，Replicated Suite 当前仅运行 V3 Framework。本文件仅作历史方法论留存，不再作为未来任务。

## 原 §16.2 内容

迁移采用：

```text
Legacy Feature
     ↓
确认真实 Authority
     ↓
定义 Feature Contract
     ↓
建立 V3 Projection
     ↓
建立 V3 Page/Widget
     ↓
Sequence + Acceptance
     ↓
V3 成为默认入口
     ↓
删除 Legacy Presentation
```

不能一次删除所有旧 UI 再重新实现全部功能。
