------------------------------------------------------------------------
-- Replicated Suite - Curated quest groups shown by the dashboard
-- Activity quest IDs are audited against the current ArcheRage database.
-- One canonical ActivityQuestGroups table is shared by the Event HUD/detail
-- path and the Daily page whenever the same activity is exposed there.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Data = S.Data or {}
local O = (S.Data.OfficialNames and S.Data.OfficialNames.QuestGroup) or {}
local Q = S.GameIds and S.GameIds.Quest or nil
local I = S.GameIds and S.GameIds.Instance or nil
if type(Q) ~= "table" or type(I) ~= "table" then
    S.BootError = "shared quest/instance ID catalog unavailable"
    return
end

-- Activity task Authority ----------------------------------------------------
--
-- IMPORTANT:
--   * `objectives` are LOGICAL objectives, not every quest ever associated
--     with an event/category.
--   * Faction variants of the same objective stay inside one `quests` list,
--     therefore they never inflate x/y progress.
--   * Wrapper/prerequisite/boss side quests that belong to the same activity
--     are stored in `relatedObjectives`. They default to display-only, but the
--     player may explicitly track them from the activity detail window; tracked
--     related tasks then participate in that player's x/y denominator.
--   * If the latest database does not provide a verified mapping, EventData
--     must leave questKey unset instead of borrowing an unrelated task set.
local ActivityQuestGroups = {}

local function Activity(key, title, objectives, options)
    options = type(options) == "table" and options or {}
    local group = {
        key = key,
        title = title,
        -- `instanceRaid` groups are NOT quests: completion is the per-account
        -- instance entry counter ("1/1") read from X2BattleField, not quest
        -- state. QuestService skips them in the quest projection and publishes
        -- their progress from the instance snapshot instead.
        kind = options.kind or "activity",
        objectives = objectives or {},
        -- `relatedObjectives` are real quests tied to the activity but default
        -- to untracked. This preserves the compact canonical denominator until
        -- a player explicitly opts an optional/wrapper/Boss task into x/y.
        relatedObjectives = options.relatedObjectives or {},
        -- Optional server-date window for seasonal/limited activities.  Quest
        -- state remains the game API Authority; these fields only control when
        -- the curated dashboard row is exposed to the player.
        activeFrom = options.activeFrom,
        activeUntil = options.activeUntil,
        -- Instance-raid definition (kind == "instanceRaid"): the localized
        -- instance names used to discover the raid in the instance list and the
        -- expected per-account entry limit.  See rs_quest_service.lua.
        instanceRaid = options.instanceRaid,
    }
    ActivityQuestGroups[key] = group
    return group
end

-- Golden Plains: 9320 is the normal player's canonical daily. Hero missions
-- and the guild daily are related records only; they must never turn 1/1 into
-- a fake multi-stage progress counter.
Activity("halcy", O.halcy or "为了势力荣誉的战争", {
    { quests = Q.Activity.halcy.main },
}, {
    relatedObjectives = {
        { role = "英雄支援", quests = Q.Activity.halcy.heroSupport },
        { role = "英雄带队", quests = Q.Activity.halcy.heroLead },
        { role = "英雄奖励", quests = Q.Activity.halcy.heroReward },
        { role = "公会", quests = Q.Activity.halcy.guild },
    },
})

-- Whalesong Siege: three canonical combat stages.  The four IDs in each row
-- are faction variants of the SAME stage.  The current database also exposes
-- the faction wrapper (8637..8640), Jakar boss Path-of-Glory variants
-- (8605..8608), and the current Whalesong guild daily (9000220). Record those
-- in details without inflating the 3-stage counter.
Activity("whalesong", O.whalesong or "鲸鱼歌湾", {
    { quests = Q.Activity.whalesong.stage1 },
    { quests = Q.Activity.whalesong.stage2 },
    { quests = Q.Activity.whalesong.stage3 },
}, {
    relatedObjectives = {
        { role = "总任务", quests = Q.Activity.whalesong.wrapper },
        { role = "Boss", quests = Q.Activity.whalesong.boss },
        { role = "公会", quests = Q.Activity.whalesong.guild },
    },
})

-- Continental Crimson Rift (Cinderstone Moor / Ynystere).
-- Current ArcheRage progression: Rank 1-3 -> Hounds of Kyrios -> Shadow Demon
-- phase -> Shadow Fang. 10734 explicitly requires Shadow Fang, therefore it is
-- continental-only and must never be attached to Sungold/Auroria.
-- 9000448 is a database-side aggregate record with no normal Start/accept stage;
-- do not expose it as a player-facing "总任务". Anthalon is NOT part of this chain.
Activity("crimson", O.crimson or "征兆之痕", {
    { quests = Q.Activity.crimson.stage1 },
    { quests = Q.Activity.crimson.stage2 },
    { quests = Q.Activity.crimson.stage3 },
    { role = "双猎犬 Boss", keepsEventAlive = true, quests = Q.Activity.crimson.hounds },
    { role = "暗影恶魔阶段", keepsEventAlive = true, quests = Q.Activity.crimson.shadowDemon },
    { role = "Shadow Fang Boss", keepsEventAlive = true, quests = Q.Activity.crimson.shadowFang },
}, {
    relatedObjectives = {
        { role = "征兆守护任务", quests = Q.Activity.crimson.guard },
        { role = "荣耀之路：猎犬", quests = Q.Activity.crimson.pathHounds },
        { role = "公会", quests = Q.Activity.crimson.guild },
    },
})

-- Auroria / Sungold Fields Crimson Rift (煦日征兆).
-- It shares the early Rift stages, but after the Hounds the branch differs:
-- Anthalon is the Auroria-only gate; defeating him enables the Shadow Totem,
-- then the Shadow Demon phase can lead to Xarkath. 10734 is deliberately absent
-- here because that quest explicitly requires Shadow Fang (continental final boss).
-- The two Anthalon records below are optional player-facing quests from different
-- systems, so keep them as related tasks rather than pretending they are one
-- mandatory auto-acquired Rift objective.
Activity("sungold_crimson", O.sungold_crimson or "煦日之野征兆", {
    { quests = Q.Activity.sungoldCrimson.stage1 },
    { quests = Q.Activity.sungoldCrimson.stage2 },
    { quests = Q.Activity.sungoldCrimson.stage3 },
    { role = "双猎犬 Boss", keepsEventAlive = true, quests = Q.Activity.sungoldCrimson.hounds },
    { role = "暗影恶魔阶段", keepsEventAlive = true, quests = Q.Activity.sungoldCrimson.shadowDemon },
    { role = "Xarkath Boss", keepsEventAlive = true, quests = Q.Activity.sungoldCrimson.xarkath },
}, {
    relatedObjectives = {
        { role = "征兆守护任务", quests = Q.Activity.sungoldCrimson.guard },
        { role = "荣耀之路：猎犬", quests = Q.Activity.sungoldCrimson.pathHounds },
        { role = "公会", quests = Q.Activity.sungoldCrimson.guild },
        { role = "煦日专属：安塔伦（荣耀之路）", keepsEventAlive = true, quests = Q.Activity.sungoldCrimson.anthalonPath },
        { role = "煦日专属：安塔伦（ArcheMaster）", keepsEventAlive = true, quests = Q.Activity.sungoldCrimson.anthalonArcheMaster },
    },
})

-- Grimghast Rift / 迷雾战争.
-- The bulletin-board material task is ONE random/mutually-exclusive prerequisite,
-- not five simultaneous objectives. Nuia can receive one of 5138/5139/5140/
-- 5150/5151 and Haranya one of 5152/5153/5154/5155/5156. Completing the one
-- that spawned for the character unlocks the faction version of Helping the War
-- Effort (5142/5157), which builds the trebuchet and then opens the combat quests.
-- Store all ten material IDs as variants of ONE logical objective so the details
-- never imply that the player must turn in all five materials on the same day.
Activity("ghost", O.ghost or "迷雾战争", {
    { quests = Q.Activity.ghost.stage1 },
    { quests = Q.Activity.ghost.stage2 },
    { quests = Q.Activity.ghost.stage3 },
    { quests = Q.Activity.ghost.stage4 },
}, {
    relatedObjectives = {
        { role = "随机物资前置（任意一个）", quests = Q.Activity.ghost.randomMaterial },
        { role = "投石车建设", quests = Q.Activity.ghost.trebuchet },
        { role = "Boss", quests = Q.Activity.ghost.boss1 },
        { role = "Boss", quests = Q.Activity.ghost.boss2 },
    },
})

-- Aegis Island / Defend the Seal: three logical stages with faction variants.
-- The faction wrapper (8641..8644), Final Sealbreaker Path-of-Glory variants
-- (8618..8621), and current Aegis guild daily (9000221) are genuine linked
-- tasks; keep them visible while preserving the canonical 3-stage denominator.
Activity("aegis", O.aegis or "海之烛台", {
    { quests = Q.Activity.aegis.stage1 },
    { quests = Q.Activity.aegis.stage2 },
    { quests = Q.Activity.aegis.stage3 },
}, {
    relatedObjectives = {
        { role = "总任务", quests = Q.Activity.aegis.wrapper },
        { role = "Boss", quests = Q.Activity.aegis.boss },
        { role = "公会", quests = Q.Activity.aegis.guild },
    },
})

-- Hiram T6 / Void Army Invasion. 11154 is the wrapper; the four children are
-- the actual logical objectives shown to the user.
Activity("hiram_t6", O.hiram_t6 or "空虚军团入侵", {
    { quests = Q.Activity.hiramT6.stage1 },
    { quests = Q.Activity.hiramT6.stage2 },
    { quests = Q.Activity.hiramT6.stage3 },
    { quests = Q.Activity.hiramT6.stage4 },
}, {
    relatedObjectives = {
        { role = "总任务", quests = Q.Activity.hiramT6.wrapper },
    },
})

-- JMG / Path of Glory bosses: Meina, Glenn, Jola. 5972 is the original
-- three-trophy wrapper. The modern Relentless variants have their own three
-- Path-of-Glory dailies plus 9000467 The Prophecy II; keep every one visible
-- without changing the classic 3/3 denominator.
Activity("jmg", O.jmg or "JMG", {
    { quests = Q.Activity.jmg.boss1 },
    { quests = Q.Activity.jmg.boss2 },
    { quests = Q.Activity.jmg.boss3 },
}, {
    relatedObjectives = {
        { role = "总任务", quests = Q.Activity.jmg.wrapper },
        { role = "强化总任务", quests = Q.Activity.jmg.relentlessWrapper },
        { role = "强化 Boss", quests = Q.Activity.jmg.relentlessBoss1 },
        { role = "强化 Boss", quests = Q.Activity.jmg.relentlessBoss2 },
        { role = "强化 Boss", quests = Q.Activity.jmg.relentlessBoss3 },
    },
})

Activity("lusca", O.lusca or "消灭阿肯怪物", {
    { quests = Q.Activity.lusca.main },
})

-- Hasla Shadow Invasion (翡翠谷征兆). 8909 is the current Daily whose text
-- explicitly says it is completed during the Shadow Invasion in Hasla and
-- describes the three invasion waves. 9494 is the normal introduction/guide;
-- 5884 is Hanure's Path-of-Glory daily, useful as a trigger-related record only.
Activity("hasla_shadow", "翡翠谷征兆", {
    { quests = Q.Activity.haslaShadow.main },
}, {
    relatedObjectives = {
        { role = "引导", quests = Q.Activity.haslaShadow.guide },
        { role = "触发 Boss", quests = Q.Activity.haslaShadow.triggerBoss },
    },
})

-- Live-zone purification reward: one logical daily per zone, with faction
-- variants sharing the same denominator.
Activity("cinderstone_purify", "十字星平原债券奖励", {
    { quests = Q.Activity.cinderstonePurify.main },
})
Activity("ynystere_purify", "伊尼斯泰尔债券奖励", {
    { quests = Q.Activity.ynysterePurify.main },
})

-- Akasch Invasion meta task 9000449 requires exactly these four objectives.
-- The current category also contains additional independent/staged invasion
-- dailies. They are tracked as related tasks so the canonical 4/4 remains true.
Activity("akasch_guard", "守山 / 守护伊弗尼尔山", {
    { quests = Q.Activity.akaschGuard.stage1 },
    { quests = Q.Activity.akaschGuard.stage2 },
    { quests = Q.Activity.akaschGuard.stage3 },
    { quests = Q.Activity.akaschGuard.stage4 },
}, {
    relatedObjectives = {
        { role = "总任务", quests = Q.Activity.akaschGuard.wrapper },
        { role = "入侵日常", quests = Q.Activity.akaschGuard.invasion1 },
        { role = "入侵日常", quests = Q.Activity.akaschGuard.invasion2 },
        { role = "入侵日常", quests = Q.Activity.akaschGuard.invasion3 },
        { role = "入侵日常", quests = Q.Activity.akaschGuard.invasion4 },
        { role = "窥视之眼 2", quests = Q.Activity.akaschGuard.eye2 },
        { role = "窥视之眼 3", quests = Q.Activity.akaschGuard.eye3 },
        { role = "虚空罗盘 2", quests = Q.Activity.akaschGuard.compass2 },
        { role = "虚空罗盘 3", quests = Q.Activity.akaschGuard.compass3 },
        { role = "奥术球体 2", quests = Q.Activity.akaschGuard.orb2 },
        { role = "奥术球体 3", quests = Q.Activity.akaschGuard.orb3 },
        { role = "蛇卵", quests = Q.Activity.akaschGuard.snakeEgg },
        { role = "战斗情报", quests = Q.Activity.akaschGuard.combatIntel },
    },
})

-- Guardian Scramble exposes one base activity daily. 11096/11116/11131 are
-- faction variants of that one objective. 11098 is a separate pirate side
-- quest, 11099 is the normal guide, and 11132/11133 are faction victory rewards.
Activity("guardian_scramble", "大草原守护者争夺战", {
    { title = "神兽争夺战日常任务", quests = Q.Activity.guardianScramble.main },
}, {
    relatedObjectives = {
        { role = "海盗支线", quests = Q.Activity.guardianScramble.pirate },
        { role = "引导", quests = Q.Activity.guardianScramble.guide },
        { role = "胜利奖励", quests = Q.Activity.guardianScramble.victory },
    },
})

Activity("wonderland_nightmare", "梦境 Boss 任务", {
    { quests = Q.Activity.wonderlandNightmare.main },
})
Activity("dragon_power", "龙之力", {
    { quests = Q.Activity.dragonPower.main },
})

-- Rookborne / Rum Runner Rapids festival (洛卡试练庆典).  The current
-- ArcheRage database marks the five objectives below as Festival dailies and
-- the modern event guide exposes exactly these as the core daily set.  6760
-- and 6785 remain valid Festival Daily records in the database but are not in
-- the modern five-daily guide, so keep them as related compatibility/extra
-- objectives instead of inflating the normal 5/5 denominator.  7803/7804 are
-- repeatable festival quests, not Daily quests, and therefore are related only.
-- The 2026 RU event announcement runs from Aug 19 through Sep 1 (inclusive).
Activity("rookborne_festival", "洛卡试练庆典", {
    { title = "洛卡的试验庆典", quests = Q.Activity.rookborneFestival.trialFestival },
    { title = "洛卡的试炼：初学者挑战课程", quests = Q.Activity.rookborneFestival.beginner },
    { title = "洛卡的试炼：高手的挑战", quests = Q.Activity.rookborneFestival.expert },
    { title = "挑战洛卡的试炼：专家", quests = Q.Activity.rookborneFestival.master },
    { title = "酒桶承载着大麦", quests = Q.Activity.rookborneFestival.barley },
}, {
    activeFrom = "2026-08-19",
    activeUntil = "2026-09-01",
    relatedObjectives = {
        { role = "额外/兼容日常", quests = Q.Activity.rookborneFestival.extra1 },
        { role = "额外/兼容日常", quests = Q.Activity.rookborneFestival.extra2 },
        { role = "限时重复任务", quests = Q.Activity.rookborneFestival.repeat1 },
        { role = "限时重复任务", quests = Q.Activity.rookborneFestival.repeat2 },
    },
})

-- Current world-boss/activity dailies. Compatibility IDs that represent the
-- same logical kill stay in one `quests` list. Normal introduction/follow-up
-- quests are related records only so they cannot falsely complete the boss row.
Activity("black_dragon", "黑龙柯萨纳斯", {
    { quests = Q.Activity.blackDragon.main },
}, {
    relatedObjectives = {
        { role = "引导", quests = Q.Activity.blackDragon.guide },
    },
})
Activity("kraken", "克拉肯", {
    { quests = Q.Activity.kraken.main },
})
Activity("leviathan", "利维坦", {
    { quests = Q.Activity.leviathan.main },
})
Activity("charybdis", "死亡捕食者卡里迪斯", {
    { quests = Q.Activity.charybdis.main },
})
Activity("garden_anthalon", "庭院安塔伦", {
    { quests = Q.Activity.gardenAnthalon.main },
}, {
    relatedObjectives = {
        { role = "爪牙", quests = Q.Activity.gardenAnthalon.minion },
    },
})
-- 红龙巢穴 / Red Dragon's Keep: a TEAM RAID, not a quest.  The old mapping
-- (9215/7654/8958/47243) treated the activity as a kill quest, which is wrong:
-- on ArcheRage the raid is time-gated (Mon/Wed/Fri/Sun) and each account has
-- ONE entry per reset.  Completion is the instance entrance counter showing
-- "1/1" after the account entered.  QuestService discovers the instance by
-- matching the localized name in X2BattleField's instance list and reads
-- enterCount/maxEnterCount from GetDetailInstanceInfo.
Activity("red_dragon", "红龙巢穴", {}, {
    kind = "instanceRaid",
    instanceRaid = I.redDragon,
})

-- 血之使者卡杜姆 / Kadum: the second team raid with the same one-entry-per-
-- account mechanic as 红龙巢穴.  ArcheRage's event guide lists Kadum on
-- Sun/Tue/Thu/Sat (红龙巢穴 on Sun/Mon/Wed/Fri); the RU time windows mirror the
-- red_dragon row.  Completion is the same "1/1" instance entry counter.
Activity("kadum", "血之使者卡杜姆", {}, {
    kind = "instanceRaid",
    instanceRaid = I.kadum,
})

-- Abyssal Attack has two current daily activity objectives: the common
-- Stopping Doomsday task plus the faction variant of Becoming a Seaknight.
-- Old 6788/6790 introduction/summon quests are normal one-time quests.
Activity("abyssal", O.abyssal or "深渊之袭", {
    { quests = Q.Activity.abyssal.doomsday },
    { quests = Q.Activity.abyssal.seaknight },
})

S.Data.ActivityQuestGroups = ActivityQuestGroups
-- Compatibility name consumed by Quest/Event services.  It intentionally
-- points at the SAME table: Event progress and task detail cannot drift apart.
S.Data.EventQuestProgress = ActivityQuestGroups

-- Dashboard task groups ------------------------------------------------------
-- Existing Daily presentation is preserved, but every activity row below is a
-- reference to the same canonical Activity table used by the Event HUD.
S.Data.QuestGroups = {
    daily = {
        { key = "guild", title = "公会任务", kind = "guildAchievement", quests = Q.Dashboard.Daily.guild },
        { key = "pack20", title = "20货任务", quests = Q.Dashboard.Daily.pack20 },
        ActivityQuestGroups.halcy,
        { key = "resident", title = "居民任务", quests = Q.Dashboard.Daily.resident },
        ActivityQuestGroups.whalesong,
        ActivityQuestGroups.crimson,
        ActivityQuestGroups.hasla_shadow,
        ActivityQuestGroups.ghost,
        ActivityQuestGroups.aegis,
        ActivityQuestGroups.hiram_t6,
        -- Eastern Hiram daily set. On current ArcheRage, the two similarly
        -- named kill quests are weekly tasks (10334/10335), not Daily rows.
        -- Keep only the three actual Daily objectives here so the dashboard
        -- denominator and task detail do not report a false 5-task daily set.
        { key = "east_hiram_daily", title = "东部悉拉玛山脉日常", objectives = {
            { quests = Q.Dashboard.Daily.eastHiram1 },
            { quests = Q.Dashboard.Daily.eastHiram2 },
            { quests = Q.Dashboard.Daily.eastHiram3 },
        } },
        -- 10558 is already one of the four required objectives of 9000449
        -- `akasch_guard`; exposing it again as a standalone Daily row caused
        -- duplicate dashboard tracking. 10559 is a separate egg-breaking daily.
        { key = "akasch_transfer_phenomenon", title = "打碎蛇卵", quests = Q.Dashboard.Daily.akaschTransfer },
        ActivityQuestGroups.jmg,
        ActivityQuestGroups.lusca,
        -- Garden daily set. Fairy Request is the compact canonical daily here.
        -- Botanical Research has four separate territory versions (not proven
        -- mutually exclusive), plus an explicit normal/pirate faction pair.
        -- Keep them visible as related tasks without inventing a fake 7-stage row.
        { key = "garden_daily", title = "神之庭院日常", objectives = {
            { quests = Q.Dashboard.Daily.garden },
        }, relatedObjectives = {
            { role = "植物研究", quests = Q.Dashboard.Daily.gardenResearch1 },
            { role = "植物研究", quests = Q.Dashboard.Daily.gardenResearch2 },
            { role = "植物研究", quests = Q.Dashboard.Daily.gardenResearch3 },
            { role = "植物研究", quests = Q.Dashboard.Daily.gardenResearch4 },
            { role = "植物研究阵营任务", quests = Q.Dashboard.Daily.gardenResearchFaction },
        } },
        ActivityQuestGroups.akasch_guard,
        ActivityQuestGroups.guardian_scramble,
        ActivityQuestGroups.wonderland_nightmare,
        ActivityQuestGroups.dragon_power,
        ActivityQuestGroups.rookborne_festival,
        { key = "fish20", title = "20鱼任务", quests = Q.Dashboard.Daily.fish20 },
    },
    weekly = {
        { key = "west_hiram", title = "西部悉拉玛山脉周常", objectives = { { quests = Q.Dashboard.Weekly.westHiram1 }, { quests = Q.Dashboard.Weekly.westHiram2 } } },
        -- Current ArcheRage weekly kill quests for Eastern Hiram Mountains.
        -- Do not mirror their legacy/same-name daily IDs into the Daily group.
        { key = "east_hiram", title = "东部悉拉玛山脉周常", objectives = {
            { quests = Q.Dashboard.Weekly.eastHiram1 },
            { quests = Q.Dashboard.Weekly.eastHiram2 },
        } },
        -- Keep the ordinary 2/2 compact progress stable. Other current Auroria
        -- weeklies and pirate-faction variants remain visible as related tasks,
        -- because they are not extra stages every character can complete.
        { key = "auroria_guard", title = "原大陆周常", objectives = {
            { quests = Q.Dashboard.Weekly.auroria1 },
            { quests = Q.Dashboard.Weekly.auroria2 },
        }, relatedObjectives = {
            { role = "区域周常", quests = Q.Dashboard.Weekly.auroriaRelated1 },
            { role = "区域周常", quests = Q.Dashboard.Weekly.auroriaRelated2 },
            { role = "海盗阵营", quests = Q.Dashboard.Weekly.auroriaPirate1 },
            { role = "海盗阵营", quests = Q.Dashboard.Weekly.auroriaPirate2 },
            { role = "海盗阵营", quests = Q.Dashboard.Weekly.auroriaPirate3 },
        } },
        { key = "akasch", title = "伊弗尼尔 / Akasch", quests = Q.Dashboard.Weekly.akasch },
    },
}

-- Resident-specialty Daily tasks that require delivering a trade pack.
--
-- Each quest id may accept one of several regional specialties. Those entries
-- are ALTERNATIVES, not cumulative requirements: consumers must never sum the
-- material quantities across recipes as if the player had to craft every pack.
-- The Auction Favorites integration uses this table only while the matching
-- quest is actively IN_PROGRESS, then derives auctionable ingredients from the
-- canonical TradeMaterial recipe Authority.
--
-- 9000226 (the generic 20-pack Daily) is intentionally absent: it accepts any
-- valid Nuia/Haranya pack and therefore has no truthful pack choice to infer.
S.Data.DailyTradePackQuestRecipes = {
    { questId = Q.Resident.packDelivery[8559], recipes = {
        "Tigerspine Fine Local Specialty",
        "Mahadevi Fine Local Specialty",
        "Solis Luxury Local Specialty",
        "Sunbite Commercial Local Specialty",
        "Arcum Iris Commercial Local Specialty",
    } },
    { questId = Q.Resident.packDelivery[8560], recipes = {
        "Villanelle Luxury Local Specialty",
        "Silent Forest Commercial Local Specialty",
        "Rokhala Preserved Local Specialty",
    } },
    { questId = Q.Resident.packDelivery[8561], recipes = {
        "Falcorth Fine Local Specialty",
        "Rookborne Preserved Local Specialty",
        "Windscour Preserved Local Specialty",
    } },
    { questId = Q.Resident.packDelivery[8562], recipes = {
        "Ynystere Commercial Local Specialty",
    } },
    { questId = Q.Resident.packDelivery[8588], recipes = {
        "Solzreed Luxury Local Specialty",
        "Lilyut Fine Local Specialty",
        "Dewstone Fine Local Specialty",
        "Airain Commercial Local Specialty",
        "Aubre Commercial Local Specialty",
    } },
    { questId = Q.Resident.packDelivery[8589], recipes = {
        "Gweonid Commercial Local Specialty",
        "Karkasse Commercial Local Specialty",
        "Ahnimar Preserved Local Specialty",
    } },
    { questId = Q.Resident.packDelivery[8590], recipes = {
        "Marianople Fine Local Specialty",
        "Hellswamp Preserved Local Specialty",
        "Sanddeep Preserved Local Specialty",
        "Halcyona Preserved Local Specialty",
    } },
    { questId = Q.Resident.packDelivery[8591], recipes = {
        "Cinderstone Luxury Local Specialty",
    } },
    { questId = Q.Resident.packDelivery[8592], recipes = {
        "Hasla Preserved Local Specialty",
        "Perinoor Preserved Local Specialty",
    } },
    { questId = Q.Resident.packDelivery[8593], recipes = {
        "Two Crowns Luxury Local Specialty",
        "White Arden Commercial Local Specialty",
    } },
}

S.Data.ResidentQuestIds = {}
for _, questId in ipairs(Q.Resident.all or {}) do
    S.Data.ResidentQuestIds[questId] = true
end
