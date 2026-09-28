------------------------------------------------------------------------
-- Replicated Suite V3 - Shared cross-Feature bounds（Phase 1 Batch D，2026-09-28）
--
-- 为什么存在：`BagScanLimit` 不是某一个 Feature 的偏好，而是整个 Suite 对“一次最多扫描多少个背包槽位”
-- 的平台级上界。拆分前它是 rs_business_bridge.lua 里的一个 chunk 级 local，被 tools_bag（多处）
-- 与 tools_craft 的持有量/缺口读取共同使用。把 craft 拆成独立文件后，如果让两个文件各写一份
-- `240`，就会产生一份**会静默漂移的策略副本**；放回 Feature 工厂又会违反工厂“不认识 Bag”的边界。
-- 因此给它一个显式的共享归属：这里是该上界的唯一 Authority。
--
-- 边界：本文件只放“被多个 Feature 共享、且不属于任何单个 Feature”的有界常量；
-- 不得把业务判断、Feature 私有阈值或任何读取逻辑搬进来。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

S.SharedBounds = {
    ContractVersion = 1,
    -- 中文维护注释：与拆分前的 bridge 常量逐字一致（240）。tools_bag 与 tools_craft 的持有量读取
    -- 都必须使用这一个值；任何一侧想改上界都必须改这里，不允许在各自的 Feature 里另写数字。
    BagScanLimit = 240,
}
