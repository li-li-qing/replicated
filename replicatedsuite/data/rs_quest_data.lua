-- Replicated Suite · 任务分组数据
-- 作者：Replicated
-- QQ群：1104129461
-- 活动任务 ID 按当前 ArcheRage 数据库核验。同一活动在 Event HUD、详情和 Daily 页共用唯一 ActivityQuestGroups 表。
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

-- 活动任务权威：objectives 表示逻辑目标，不能纳入活动/分类关联过的所有任务。
-- 同一目标的阵营变体放进同一个 quests 列表，不能增加 x/y。汇总、前置和支线任务放 relatedObjectives，仅供详情参考，不能进入活动分母。
-- 已核实且含至少两个标准 objectives 的活动默认开启个人进度选择：初始全选，玩家可取消不参与阶段，x/y 仅由所选目标决定；未来必须保持整体性的多目标活动可显式设置 progressSelectionEnabled=false。
-- 单目标和 instanceRaid 保持固定分母，避免取消唯一目标造成无意义的 0/0。最新数据库没有核实映射时，EventData 必须留空 questKey，不能借用无关任务组。
local ActivityQuestGroups = {}

local function Activity(key, title, objectives, options)
    options = type(options) == "table" and options or {}
    objectives = type(objectives) == "table" and objectives or {}
    -- 至少两个已核实主目标时默认允许个人选择；单目标固定 1/1，relatedObjectives 不计分母。
    -- 显式 false 留给必须整体完成的多阶段活动。
    local progressSelectionEnabled = options.progressSelectionEnabled
    if progressSelectionEnabled == nil then
        progressSelectionEnabled = #objectives >= 2
    end
    local group = {
        key = key,
        title = title,
        -- instanceRaid 组不是任务：完成事实来自 X2BattleField 账号进入次数（1/1），不是任务状态。QuestService 在任务投影中跳过它们，改从副本快照发布进度。
        kind = options.kind or "activity",
        objectives = objectives,
        -- relatedObjectives 是真实关联任务，但仅供详情参考，不进入个人 x/y 分母；只有 progressSelectionEnabled=true 时选中的标准 objectives 可以进入分母。
        relatedObjectives = options.relatedObjectives or {},
        -- 个人进度选择属于 Activity 偏好，不能改变 Quest 事实。QuestProgressV3 只发布独立目标快照；Activities 投影玩家 x/y 时应用本表的多阶段策略。
        progressSelectionEnabled = progressSelectionEnabled == true,
        -- 季节/限时活动可配置服务器日期窗口。任务状态仍以游戏 API 为权威；这些字段只控制整理后的面板行何时展示。
        activeFrom = options.activeFrom,
        activeUntil = options.activeUntil,
        -- instanceRaid 定义包含用于副本列表发现的本地化名称，以及账号预计进入上限，详见 rs_quest_service.lua。
        instanceRaid = options.instanceRaid,
    }
    ActivityQuestGroups[key] = group
    return group
end

-- 黄金平原：9320 是普通玩家的标准日常。英雄任务和公会日常仅为关联记录，不能把 1/1 变成虚假的多阶段进度。
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

-- 鲸歌港有三个标准战斗阶段；每行四个 ID 是同一阶段的阵营变体。阵营汇总任务 8637..8640、Jakar Path-of-Glory 8605..8608 与公会日常 9000220 仅展示在详情，不增加三阶段计数。
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

-- 大陆红龙之渊（Cinderstone Moor/Ynystere）顺序为Rank1-3→Hounds of Kyrios→Shadow Demon→Shadow Fang。10734明确要求Shadow Fang，仅属大陆，禁止绑定Sungold/原大陆。
-- 9000448是数据库汇总，无普通接取阶段，禁止显示玩家总任务；Anthalon不属于此链。
Activity("crimson", O.crimson or "征兆之痕", {
    { quests = Q.Activity.crimson.stage1 },
    { quests = Q.Activity.crimson.stage2 },
    { quests = Q.Activity.crimson.stage3 },
    { role = "双猎犬 Boss", keepsEventAlive = true, quests = Q.Activity.crimson.hounds },
    { role = "暗影恶魔阶段", keepsEventAlive = true, quests = Q.Activity.crimson.shadowDemon },
    { role = "Shadow Fang Boss", keepsEventAlive = true, quests = Q.Activity.crimson.shadowFang },
}, {
    -- 默认六阶段显示 0/6；用户取消阶段后才缩小个人分母，例如仅保留后三项为 0/3。关联任务不计入。
    progressSelectionEnabled = true,
    relatedObjectives = {
        { role = "征兆守护任务", quests = Q.Activity.crimson.guard },
        { role = "荣耀之路：猎犬", quests = Q.Activity.crimson.pathHounds },
        { role = "公会", quests = Q.Activity.crimson.guild },
    },
})

-- 原大陆/Sungold煦日征兆共享早期阶段，但Hounds后由Anthalon作为原大陆门槛；击败后启用Shadow Totem，Shadow Demon阶段再到Xarkath。
-- 10734要求大陆终首领Shadow Fang，不能列入此组。下方两个Anthalon记录来自不同系统且为可选玩家任务，作关联任务，不能冒充必需自动接取目标。
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

-- 迷雾战争材料板是一个随机互斥前置目标，不是同时五项：Nuia从5138/5139/5140/5150/5151中取一，Haranya从5152/5153/5154/5155/5156中取一。
-- 完成角色实际获得任务后解锁阵营Helping the War Effort（5142/5157），建投石机再开启战斗任务；十材料ID必须存为一个逻辑目标的变体，禁止暗示同日交齐五种。
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

-- 神盾岛 / Defend the Seal 有三个逻辑阶段，含阵营变体。汇总任务 8641..8644、Final Sealbreaker Path-of-Glory 8618..8621 与公会日常 9000221 是真实关联任务，应保持可见且不增加三阶段分母。
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

-- Hiram T6 / Void Army Invasion：11154 是汇总任务，四个子任务才是展示给玩家的实际逻辑目标。
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

-- JMG / Path of Glory 首领为 Meina、Glenn、Jola；5972 是原有三战利品汇总。现代 Relentless 变体各有 Path-of-Glory 日常及 9000467 The Prophecy II，全部可见但保持经典 3/3 分母。
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

-- 翡翠谷征兆/Hasla Shadow Invasion当前日常8909明确描述在Hasla入侵期间完成及三波入侵；9494为普通介绍引导，5884为Hanure Path-of-Glory日常，仅作触发关联记录。
Activity("hasla_shadow", "翡翠谷征兆", {
    { quests = Q.Activity.haslaShadow.main },
}, {
    relatedObjectives = {
        { role = "引导", quests = Q.Activity.haslaShadow.guide },
        { role = "触发 Boss", quests = Q.Activity.haslaShadow.triggerBoss },
    },
})

-- 实时地区净化奖励：每个地区一个逻辑日常，各阵营变体共享分母。
Activity("cinderstone_purify", "十字星平原债券奖励", {
    { quests = Q.Activity.cinderstonePurify.main },
})
Activity("ynystere_purify", "伊尼斯泰尔债券奖励", {
    { quests = Q.Activity.ynysterePurify.main },
})

-- Akasch 汇总任务 9000449 要求这四个目标；其它独立/阶段任务仅关联展示，不计入 4/4。
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

-- Guardian Scramble 只有一个基础活动日常，11096/11116/11131 是同一目标的阵营变体；11098 为独立海盗支线，11099 为普通引导，11132/11133 为阵营胜利奖励。
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

-- 洛卡试练庆典/Rookborne Rum Runner Rapids下方五目标经当前数据库与指南确认为核心节日日常。6760/6785仍是有效节日日常，但不在现代五日常指南，只作兼容/额外关联，不增加5/5分母。
-- 7803/7804是可重复节庆任务非日常，仅关联展示；2026 RU公告开放2026-08-19至2026-09-01，含结束日。
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

-- 当前世界首领/活动日常：表示同一击杀目标的兼容 ID 必须留在同一个 quests 列表；普通介绍/后续任务只作关联记录，不能误完成首领行。
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

-- 精灵的委托 10056 虽有积分和 Reward Level1..12，活动仍是固定 0/1→1/1。
-- QuestProgressV3 读状态和 Journal，kind=scoreQuest 仅说明详情类型；未核实结构化积分前只显示原生文本。
Activity("garden_fairy", "精灵的委托", {
    { category = "积分任务", quests = Q.Activity.gardenFairyRequest },
}, {
    kind = "scoreQuest",
    progressSelectionEnabled = false,
})
-- 红龙巢穴/Red Dragon's Keep是团队副本，禁止使用9215/7654/8958/47243旧击杀任务映射。开放周一/三/五/日，每账号每重置一次进入，进入后完成计数1/1。
-- QuestService按X2BattleField列表本地化名发现副本，从GetDetailInstanceInfo读enterCount/maxEnterCount。
Activity("red_dragon", "红龙巢穴", {}, {
    kind = "instanceRaid",
    instanceRaid = I.redDragon,
})

-- 卡杜姆/Kadum与红龙巢穴共用账号每轮一次进入规则；指南为周日/二/四/六，红龙为周日/一/三/五，RU时间窗共用red_dragon。完成同样读取1/1副本进入计数。
Activity("kadum", "血之使者卡杜姆", {}, {
    kind = "instanceRaid",
    instanceRaid = I.kadum,
})

-- Abyssal Attack 当前有两个活动日常目标：公共 Stopping Doomsday 与阵营 Becoming a Seaknight。旧 6788/6790 介绍/召唤任务是普通一次性任务。
Activity("abyssal", O.abyssal or "深渊之袭", {
    { quests = Q.Activity.abyssal.doomsday },
    { quests = Q.Activity.abyssal.seaknight },
})

S.Data.ActivityQuestGroups = ActivityQuestGroups
S.Data.EventQuestProgress = ActivityQuestGroups

-- 面板任务分组：保留现有 Daily 展示；下方每个活动行均引用 Event HUD 共用的标准 Activity 表。
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
        -- 东部 Hiram 当前两个同名击杀任务 10334/10335 是周常；这里只保留三个真实日常目标，避免面板分母与详情误报五任务日常组。
        { key = "east_hiram_daily", title = "东部悉拉玛山脉日常", objectives = {
            { quests = Q.Dashboard.Daily.eastHiram1 },
            { quests = Q.Dashboard.Daily.eastHiram2 },
            { quests = Q.Dashboard.Daily.eastHiram3 },
        } },
        -- 10558 已属于 9000449 akasch_guard 的四个必需目标，不能再单独展示成 Daily 行造成重复追踪；10559 是独立击破蛋日常。
        { key = "akasch_transfer_phenomenon", title = "打碎蛇卵", quests = Q.Dashboard.Daily.akaschTransfer },
        ActivityQuestGroups.jmg,
        ActivityQuestGroups.lusca,
        -- 神之庭院日常以 Fairy Request 作为紧凑标准目标。Botanical Research 有四个地区版本，尚未证实互斥，另有明确普通/海盗阵营对；全部仅作关联任务，不能编造七阶段行。
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
        -- 当前 ArcheRage 东部 Hiram Mountains 周常击杀任务；禁止把旧版/同名日常 ID 镜像进 Daily 组。
        { key = "east_hiram", title = "东部悉拉玛山脉周常", objectives = {
            { quests = Q.Dashboard.Weekly.eastHiram1 },
            { quests = Q.Dashboard.Weekly.eastHiram2 },
        } },
        -- 保持普通 2/2 紧凑进度；其他当前原大陆周常和海盗变体作为关联任务展示，它们不是每个角色都能完成的额外阶段。
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

-- 居民特产日常要求交付货包。同一任务 ID 可以接受多个地区特产，它们是可选替代项，禁止跨配方累加材料，假定玩家必须制作全部货包。
-- Auction Favorites 仅在对应任务 IN_PROGRESS 时消费本表，从唯一 TradeMaterial 配方权威派生可拍卖材料。
-- 通用 20 货包日常 9000226 接受任意有效 Nuia/Haranya 货包，没有可信的特定货包选择，因此不列入此表。
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
