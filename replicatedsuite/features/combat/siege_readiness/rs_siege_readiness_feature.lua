------------------------------------------------------------------------
-- Replicated Suite V3 - combat_siege_readiness Feature Authority
--
-- Phase 1 Batch B（2026-09-28）：从 features/rs_business_bridge.lua 机械搬迁。
-- 只改变源码边界，不改业务行为：Feature ID、Store ID/Schema、UpdateTopic、Demand owner、
-- Commands、Projection shape、ApiDependencies 与被搬迁前逐字一致。
--
-- 本 Feature 仍是诚实的 Runtime Blocked 占位：页面与生命周期真实存在，只有最后一个
-- 未验证子能力被围栏。blocker 文案是用户可见事实（页面“运行时阻塞”行），不得改写。
-- 中文维护注释：它不拥有装备/团队事实（事实归 GearServiceV3 / TeamRosterV3），
-- 也不得为了“做点什么”去猜 GetEquippedItemTooltipInfo 的槽位/装分字段。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local FSF = S.FeatureSliceFactory
if type(FSF) ~= "table" then error("FeatureSliceFactory unavailable for combat_siege_readiness") end
local NewFeature = FSF.NewFeature

NewFeature("combat_siege_readiness", { blocker = "GetEquippedItemTooltipInfo 的槽位/装分字段和攻城上下文未在当前 RU 实机确认；不猜测装备状态" })
