-- Replicated Suite · 攻城准备检查功能入口
-- 作者：Replicated
-- QQ群：1104129461
-- 页面和生命周期可用，未验证能力保持 Runtime Blocked。装备/团队事实归 GearServiceV3/TeamRosterV3，不能猜 tooltip 槽位或装分字段。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local FSF = S.FeatureSliceFactory
if type(FSF) ~= "table" then error("FeatureSliceFactory unavailable for combat_siege_readiness") end
local NewFeature = FSF.NewFeature

NewFeature("combat_siege_readiness", { blocker = "GetEquippedItemTooltipInfo 的槽位/装分字段和攻城上下文未在当前 RU 实机确认；不猜测装备状态" })
