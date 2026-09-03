------------------------------------------------------------------------
-- Replicated Suite - Verified official Chinese names
-- Author: Replicated
--
-- Static names here are only for schedule/group labels that cannot always be
-- obtained from a live quest object. Quest child titles are read from X2Quest.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Data = S.Data or {}

S.Data.OfficialNames = {
    Event = {
        GR = "迷雾战争",
        CR = "征兆之痕",
        HIRAM_T6 = "空虚军团入侵",
        HALCY = "黄金平原战争",
        LUSCA = "海妖之乱",
        WHALESONG = "鲸鱼歌湾",
        AEGIS = "海之烛台",
        CINDERSTONE = "十字星平原",
        YNYSTERE = "伊尼斯泰尔",
        JMG = "JMG",
        SUNGOLD_CRIMSON = "煦日之野征兆",
        BLACK_DRAGON = "黑龙柯萨纳斯",
        CHARYBDIS = "死亡捕食者卡里迪斯",
        ABYSSAL = "深渊之袭",
    },
    QuestGroup = {
        halcy = "为了势力荣誉的战争",
        whalesong = "鲸鱼歌湾",
        crimson = "征兆之痕",
        ghost = "迷雾战争",
        aegis = "海之烛台",
        hiram_t6 = "空虚军团入侵",
        lusca = "消灭阿肯怪物",
        jmg = "JMG",
    }
}
