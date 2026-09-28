------------------------------------------------------------------------
-- Replicated Suite V3 - tools_portal_profiles Feature Authority
--
-- Phase 1 Batch B（2026-09-28）：从 features/rs_business_bridge.lua 机械搬迁。
-- 只改变源码边界，不改业务行为：Feature ID、Store ID/Schema、UpdateTopic、Demand owner、
-- Commands、Projection shape、ApiDependencies 与被搬迁前逐字一致。
--
-- 本 Feature 仍是诚实的 Runtime Blocked 占位：页面与生命周期真实存在，
-- 但 X2Option 的 optionType/返回值语义与个人传送候选集合未在当前 RU 客户端验证，
-- 因此禁止执行任何猜测写入（也不使用未授权的 X2Warp 写接口）。
-- blocker 文案是用户可见事实（页面“运行时阻塞”行），不得改写。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local FSF = S.FeatureSliceFactory
if type(FSF) ~= "table" then error("FeatureSliceFactory unavailable for tools_portal_profiles") end
local NewFeature = FSF.NewFeature

NewFeature("tools_portal_profiles", { blocker = "X2Option optionType/返回值语义和个人传送候选集合未在当前 RU 客户端验证；禁止执行猜测写入" })
