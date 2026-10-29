# 角色战绩基础保护实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 今日/累计战绩无损迁移、基础防改和双电脑去重，测试后提交推送。
**Architecture:** 既有单Character Store和来源账本保留，新增独立保护来源及冷路径认证；沿用TXT/文本通道。
**Tech Stack:** Lua5.1、真实Persistence/EventBus/UI、Python+lupa.lua51。
**Spec:** Docs/superpowers/specs/2026-10-29-combat-history-guard-design.md

## Global Constraints
- 旧历史和 canonical 不丢、不覆盖、不自动变受保护战绩。
- 客户端基础防改不是服务器真实性认证。
- 不新增轮询，不在事件热路径遍历历史；失败不写半次导入。

## Review Focus
- 共用基线100 + 两机新增10/5应为115，反复回传仍115。
- 同来源分叉、版本倒退、同版本异内容和损坏包不得覆盖本地。
- 旧schema、无sync、v1/2/3来源及可选字段零值保持。
- +100增量、改totals/day/source/guard、移除p-凭据需拒绝且不重签。
- unknown日期、跨日、归档、写入失败、角色切换、长历史容量与性能。

### Task 1: 纯Lua认证与独立来源凭据
Files: 新增 core/rs_combat_history_auth.lua、features/combat/analytics/rs_combat_history_guard.lua 与各自tools测试。
- [x] 固定向量/篡改/增量/归档/身份/性能反例先红。
- [x] 实现规格中的认证与Guard接口，重跑绿灯。
- [x] 定向审查接口及热路径成本。

### Task 2: 生产记录、持久化与跨电脑协议
Files: 修改 personal_history、history_transfer、toc.g、传输测试；必要时扩展compact transport保留凭据。
- [x] 真实Store双VM迁移、同步回传和篡改反例先红。
- [x] 保留旧来源canonical，新增p-来源和v4协议，生产事件固定1，失败保护原数据。
- [x] 运行旧传输/存档/击杀回归与长历史/分页故障用例。

### Task 3: 今日查询与状态说明
Files: 修改个人历史页及相关UI测试。
- [x] 增加今日快捷查询与保护/旧记录状态，保留全部日期和导入导出。
- [x] UI宿主验证今日/跨日/未知时间与导入后展示；不宣称RU视觉验收。

### Task 4: 验证与交付
- [x] 最终审查整个差异并修复发现。
- [x] Lua5.1语法、相关回归和有界性能证据；实际未运行的RU验收单列。
- [ ] 核对主目录/远端无并发修改后快进集成，提交推送，确认远端hash和0/0。
