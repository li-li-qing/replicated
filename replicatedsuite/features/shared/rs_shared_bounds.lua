-- Replicated Suite · 共享数据范围约束
-- 作者：Replicated
-- QQ群：1104129461
-- BagScanLimit 是 bag/craft 共用的扫描上界，集中定义以免各自写 240 后漂移。
-- 这里只放跨 Feature 的有界常量，不放业务判断、私有阈值或读取逻辑。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

S.SharedBounds = {
    ContractVersion = 1,
    -- bag/craft 共用此上界，不各自复制数值。
    BagScanLimit = 240,
}
