-----------------------------------------------------------------------
-- Replicated Suite - Specialty workbench locations
-- Source: user-provided packratio PackCrafterLocations.txt reference.
--
-- This is trigger metadata only. It is NOT used to infer recipes, prices,
-- inventory identity, or server route validity. Trade/recipe Authority stays
-- with X2Store/X2Craft. Coordinates are consulted only after an interaction
-- event, so there is no permanent proximity polling loop.
-----------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Data = S.Data or {}
S.Data.TradeCrafterLocationsByZone = {
    [1] = {
        { x=10839, y=15533, z=247, community=true },
        { x=10488, y=15561, z=232, community=false },
        { x=9680, y=15189, z=239, community=false },
    },
    [2] = {
        { x=10642, y=11890, z=134, community=true },
        { x=11542, y=12008, z=115, community=false },
    },
    [3] = {
        { x=12291, y=13314, z=155, community=true },
        { x=12357, y=13867, z=120, community=false },
    },
    [4] = {
        { x=16927, y=8082, z=155, community=true },
    },
    [5] = {
        { x=14957, y=14252, z=125, community=true },
        { x=13898, y=14202, z=119, community=false },
        { x=13806, y=14160, z=118, community=false },
    },
    [6] = {
        { x=12629, y=15469, z=163, community=true },
        { x=12603, y=15843, z=209, community=false },
    },
    [7] = {
        { x=20345, y=7193, z=187, community=true },
        { x=21925, y=7378, z=256, community=false },
    },
    [8] = {
        { x=12423, y=11158, z=148, community=true },
        { x=12873, y=11903, z=133, community=false },
    },
    [9] = {
        { x=18670, y=9271, z=175, community=true },
        { x=20049, y=9713, z=193, community=false },
    },
    [10] = {
        { x=6521, y=13406, z=971, community=true },
    },
    [11] = {
        { x=23659, y=9792, z=586, community=true },
        { x=23927, y=9072, z=571, community=false },
    },
    [12] = {
        { x=21837, y=10273, z=154, community=true },
        { x=20914, y=9979, z=200, community=false },
    },
    [13] = {
        { x=21113, y=5775, z=248, community=true },
        { x=21249, y=5036, z=143, community=false },
    },
    [14] = {
        { x=25917, y=6801, z=364, community=true },
        { x=25647, y=7509, z=337, community=false },
    },
    [15] = {
        { x=27770, y=6788, z=576, community=true },
        { x=27120, y=6993, z=460, community=false },
        { x=27445, y=8058, z=656, community=false },
    },
    [16] = {
        { x=24593, y=10461, z=661, community=false },
        { x=25417, y=9795, z=716, community=true },
        { x=25075, y=9162, z=767, community=false },
    },
    [17] = {
        { x=21578, y=12486, z=245, community=true },
        { x=20747, y=12628, z=168, community=false },
        { x=20305, y=13180, z=181, community=false },
    },
    [18] = {
        { x=9730, y=12766, z=164, community=true },
        { x=9387, y=12855, z=246, community=false },
        { x=9709, y=13679, z=230, community=false },
    },
    [19] = {
        { x=10486, y=17373, z=187, community=true },
        { x=10714, y=17835, z=159, community=false },
    },
    [20] = {
        { x=15369, y=11533, z=111, community=true },
        { x=14587, y=11388, z=137, community=false },
        { x=14358, y=12007, z=155, community=false },
    },
    [21] = {
        { x=7626, y=12542, z=683, community=true },
        { x=8003, y=12611, z=694, community=false },
    },
    [22] = {
        { x=9333, y=10338, z=190, community=true },
        { x=9939, y=10287, z=223, community=false },
    },
    [23] = {
        { x=29876, y=8944, z=419, community=true },
        { x=29414, y=8488, z=429, community=false },
        { x=29136, y=8547, z=622, community=false },
    },
    [24] = {
        { x=21765, y=8075, z=406, community=true },
        { x=21815, y=7957, z=388, community=false },
    },
    [25] = {
        { x=22758, y=11974, z=259, community=true },
        { x=23317, y=12520, z=273, community=false },
    },
    [26] = {
        { x=7470, y=9830, z=191, community=true },
        { x=7457, y=9241, z=264, community=false },
    },
    [27] = {
        { x=10107, y=9671, z=204, community=false },
        { x=10832, y=9485, z=107, community=true },
    },
    [93] = {
        { x=6299, y=9474, z=461, community=true },
    },
    [99] = {
        { x=28113, y=9974, z=868, community=true },
        { x=27276, y=11278, z=871, community=false },
    },
}
