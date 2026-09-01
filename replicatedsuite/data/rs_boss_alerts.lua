------------------------------------------------------------------------
-- Replicated Suite - Boss mechanism alert data (report 七-方案A)
-- Author: Replicated
--
-- S.Data.BossAlerts: data-driven alert table. Each entry:
--   key        stable id used for the per-alert enable switch (items[key])
--   kind       "cast" (match a unit's current cast name) or
--              "debuff" (match an active debuff by numeric id)
--   names      multilingual cast names (string.find plain match on the
--              client-localized spell name; at least EN/RU/ZH)
--   debuffId   numeric debuff id for kind="debuff"
--   alert      the alert text pushed to the screen
--   style      "countdown" (big text + remaining seconds) or "bigtext"
--
-- Source: 参考的项目/wbdebuff (data only, engineering not copied).
--   jumpblackdragon.lua castMessages :30-51 (EN/RU/DE/FR/ZH cast names)
--   buffblackdragon.lua :46 (撞鬼 debuff 23474)
--   buffcharybdis.lua   :46 (下水 debuff 25846)
-- Names are matched with string.find(plain) so partial/UTF-8 names match.
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
