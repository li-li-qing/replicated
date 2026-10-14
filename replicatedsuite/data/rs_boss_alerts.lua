------------------------------------------------------------------------
-- Replicated Suite · 首领机制提示
-- 作者：Replicated
-- QQ群：1104129461
--
-- S.Data.BossAlerts 为数据驱动提示表，每项字段：
-- key：稳定ID，用于items[key]逐提示开关；kind：cast按当前施法名称匹配，debuff按数字ID匹配活动减益。
-- names：多语言精确施法名，运行时一次构建查询表，观察循环禁止模糊匹配；debuffId：kind=debuff的数字ID。
-- alert：屏幕提示文本；style：countdown显示大字和剩余秒数，bigtext仅大字。
-- 来源：参考的项目/wbdebuff，仅使用数据、不复制工程实现；jumpblackdragon.lua castMessages:30-51为EN/RU/DE/FR/ZH名称，buffblackdragon.lua:46为撞鬼debuff23474，buffcharybdis.lua:46为下水debuff25846。
-- 运行时按本地化名称精确查询，新增RU别名必须经观察核实。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Data = S.Data or {}
S.Data.BossAlerts = {
    {
        key = "smash_earth",
        kind = "cast",
        names = {
            "Smash Earth",
            "Сотрясение",
            "Erdschmettern",
            "Coup tellurique",
            "大地强击",
        },
        alert = "离开地面！",
        style = "countdown",
    },
    {
        key = "sea_of_death",
        kind = "cast",
        names = {
            "Sea of Death",
            "Электрические разряды",
            "Meer des Todes",
            "Mer funeste",
            "死亡之海",
        },
        alert = "离开水面！",
        style = "countdown",
    },
    {
        key = "scale_explosion",
        kind = "cast",
        names = {
            "Black Dragon Scale",
            "Сбрасывание чешуи",
            "Schwarze Drachenschuppe",
            "Écaille du Dragon noir",
            "黑龙鳞片",
        },
        alert = "大地爆炸！",
        style = "countdown",
    },
    {
        key = "ghost_hit",
        kind = "debuff",
        debuffId = 23474,
        names = {},
        alert = "撞鬼了！",
        style = "bigtext",
    },
    {
        key = "underwater",
        kind = "debuff",
        debuffId = 25846,
        names = {},
        alert = "下水！",
        style = "bigtext",
    },
}
