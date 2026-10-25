-- Replicated Suite · 任务身份注册
-- 作者：Replicated
-- QQ群：1104129461
-- 共享任务 ID 集中在本表。这里只拥有身份；完成和进度策略归 Quest/Event 服务，关系数据仍保存在 rs_quest_data.lua。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
if S.GameDataRegistry == nil then return end

S.GameIds = S.GameIds or {}
local Q = {
    ResidentBond = {},
    Activity = {},
    Dashboard = { Daily = {}, Weekly = {} },
    Resident = {},
}
S.GameIds.Quest = Q

local Registry = S.GameDataRegistry
local CURATED_SOURCE = "Replicated Suite curated ArcheRage RU quest mapping"
local DATABASE_SOURCE = "ArcheRage RU quest database"
local VERIFIED_AT = "2026-08-27"

-- 只有在当前 ArcheRage RU 数据库中独立定位的 ID 才能标记 database_verified；其余保持 curated_pending，不能静默成为关键完成逻辑的权威。
local DATABASE_VERIFIED_IDS = {}
local function MarkVerified(ids)
    for _, id in ipairs(ids) do DATABASE_VERIFIED_IDS[tonumber(id)] = true end
end

MarkVerified({
    -- 蓝盐债券材料委托板。
    9044, 9147, 9148, 9046, 9152, 9153, 9047, 9137, 9138, 9049, 9142, 9143,
    -- 原大陆居民债券委托板。
    10504, 10505, 10506, 10507, 10508, 10509, 10510, 10511, 10512, 10513, 10514, 10515,
    -- RU 数据库列出的 Community Center / 居民日常身份。
    8345, 8347, 8348, 8349, 8350, 8559, 8560, 8561, 8562, 8588, 8589, 8590, 8591, 8592, 8593,
    -- 黄金平原 / Halcyona。
    9320, 9130, 9223, 9227,
    -- 鲸歌港战斗阶段、Possessed Jakar 分支、汇总任务和公会日常。
    8602, 8603, 8604, 8605, 8606, 8607, 8608, 8609, 8610, 8611, 8612, 8613, 8614, 8615, 8616, 8617,
    8637, 8638, 8639, 8640, 9000220,
    -- 神盾岛防御阶段、Final Sealbreaker 分支、汇总任务和公会日常。
    8618, 8619, 8620, 8621, 8623, 8624, 8625, 8626, 8627, 8628, 8629, 8630,
    8631, 8632, 8633, 8634, 8641, 8642, 8643, 8644, 9000221,
    -- Void Corps 入侵 / Hiram T6 汇总任务及四个子任务。
    11154, 11155, 11156, 11157, 11158,
    -- 现有公会/贸易面板映射使用的当前 RU 数据库日常记录。
    9000223, 9000225, 9000226,
    -- Cinderstone / Ynystere Industry Dynamo 净化日常。
    9960, 9962, 9963, 9964, 9965, 9966,
    -- 深渊袭击：Lusca 日常及四个阵营的 Seaknight 变体。
    5765, 6973, 6974, 6975, 6976,
    -- 原大陆 / 神之庭院植物研究日常。
    10145, 10146, 10147, 10148, 10188, 10189,
    -- 东部 Hiram 当前日常记录与 Hiram 周常目标身份。
    9317, 9318, 9326, 9077, 11196, 10334, 10335,
    -- 当前成就确认的长期原大陆/Hiram 守护者任务身份。
    9131, 9017, 9019, 9020,
    -- Akasch 入侵任务链、汇总任务和 Ipnya 周常。
    9000449, 10699, 10700, 10701, 10702, 10703, 10704, 10705, 10708, 11200,
    -- Great Prairie Guardian Scramble 任务身份。
    11096, 11098, 11099, 11116, 11131, 11132, 11133,
    -- JMG / Prophecy 任务链及 Hasla / Anthalon / Path of Glory 相关身份。
    5969, 5970, 5971, 5972, 9000467, 5884, 5885, 5886, 7396, 7648, 7649, 8909, 9494,
    -- 当前数据库保留的 Rookborne 节庆任务身份。
    6758, 6759, 6760, 6761, 6784, 6785, 7802, 7803, 7804,
    -- 在当前数据库独立定位的其余面板/活动任务身份。
    6791, 7736, 7737, 9021, 9052, 9053, 9000170, 9000333, 9000531,
    -- 红龙之渊数据库分类。9000448 是数据库汇总元数据，不是玩家参与的阶段，需在下方独立注册。
    2941, 2942, 2943, 8998, 10729, 10730, 10734, 10735, 9000448,
    -- Grimghast Rift / 迷雾战争.
    5138, 5139, 5140, 5142, 5143, 5144, 5150, 5151, 5152, 5153, 5154, 5155, 5156, 5157, 10739, 11192,
    -- 按任务页面明确核实的世界首领 / 神之庭院身份。
    9221, 9222, 5883, 7655, 9969, 10186, 10187,
    -- 现有模块使用的当前数据库日常记录。
    10328, 10329, 10330, 10558, 10559, 10561, 10562, 10563, 10564, 10565, 10569, 10571, 10056,
})

Q.Verification = {
    ById = DATABASE_VERIFIED_IDS,
    verifiedAt = VERIFIED_AT,
    databaseSource = DATABASE_SOURCE,
    pendingSource = CURATED_SOURCE,
}

local function IsDatabaseVerified(id)
    return DATABASE_VERIFIED_IDS[tonumber(id)] == true
end

local function AreAllDatabaseVerified(ids)
    if type(ids) ~= "table" or #ids == 0 then return false end
    for _, id in ipairs(ids) do
        if not IsDatabaseVerified(id) then return false end
    end
    return true
end

local function RegistrationMeta(verified)
    if verified then
        return DATABASE_SOURCE, "database_verified", true, VERIFIED_AT
    end
    return CURATED_SOURCE, "curated_pending", false, nil
end

local function RegisterSet(key, ids, name, tags, notes)
    local verified = AreAllDatabaseVerified(ids)
    local source, confidence, verifiedFlag, verifiedAt = RegistrationMeta(verified)
    local set = Registry:RegisterSet("quest", key, ids, {
        name = name,
        tags = tags,
        source = source,
        confidence = confidence,
        verified = verifiedFlag,
        verifiedAt = verifiedAt,
        notes = notes,
    })
    return set and set.ids or ids
end

local function RegisterId(key, id, name, tags, notes)
    local source, confidence, verifiedFlag, verifiedAt = RegistrationMeta(IsDatabaseVerified(id))
    local record = Registry:Register("quest", key, id, {
        name = name,
        tags = tags,
        source = source,
        confidence = confidence,
        verified = verifiedFlag,
        verifiedAt = verifiedAt,
        notes = notes,
    })
    return record and record.id or id
end

-- 居民委托板 / 债券任务。
Q.ResidentBond.MaterialByQuantity = {
    fabric = {
        [20] = RegisterId("RESIDENT_BOND_FABRIC_20", 9044, "居民债券：布料20", { "DAILY", "RESIDENT_BOND" }),
        [60] = RegisterId("RESIDENT_BOND_FABRIC_60", 9147, "居民债券：布料60", { "DAILY", "RESIDENT_BOND" }),
        [100] = RegisterId("RESIDENT_BOND_FABRIC_100", 9148, "居民债券：布料100", { "DAILY", "RESIDENT_BOND" }),
    },
    leather = {
        [20] = RegisterId("RESIDENT_BOND_LEATHER_20", 9046, "居民债券：皮革20", { "DAILY", "RESIDENT_BOND" }),
        [60] = RegisterId("RESIDENT_BOND_LEATHER_60", 9152, "居民债券：皮革60", { "DAILY", "RESIDENT_BOND" }),
        [100] = RegisterId("RESIDENT_BOND_LEATHER_100", 9153, "居民债券：皮革100", { "DAILY", "RESIDENT_BOND" }),
    },
    iron = {
        [20] = RegisterId("RESIDENT_BOND_IRON_20", 9047, "居民债券：铁锭20", { "DAILY", "RESIDENT_BOND" }),
        [60] = RegisterId("RESIDENT_BOND_IRON_60", 9137, "居民债券：铁锭60", { "DAILY", "RESIDENT_BOND" }),
        [100] = RegisterId("RESIDENT_BOND_IRON_100", 9138, "居民债券：铁锭100", { "DAILY", "RESIDENT_BOND" }),
    },
    lumber = {
        [20] = RegisterId("RESIDENT_BOND_LUMBER_20", 9049, "居民债券：木材20", { "DAILY", "RESIDENT_BOND" }),
        [60] = RegisterId("RESIDENT_BOND_LUMBER_60", 9142, "居民债券：木材60", { "DAILY", "RESIDENT_BOND" }),
        [100] = RegisterId("RESIDENT_BOND_LUMBER_100", 9143, "居民债券：木材100", { "DAILY", "RESIDENT_BOND" }),
    },
}

-- 10504/10505 为 Prince's Coinpurses，10512..10515 为 Ancestor/Ancestral；旧 golden_bag/heir 命名有误。
-- Quest ID 不变，旧 key 保留 alias，供居民板、背包和任务进度共用身份。
Q.ResidentBond.AuroriaByTokenQuantity = {
    prince_purse = {
        [30] = RegisterId("AURORIA_BOND_PRINCE_PURSE_30", 10504, "原大陆债券：王子的钱袋30", { "DAILY", "AURORIA_RESIDENT_BOND" }),
        [90] = RegisterId("AURORIA_BOND_PRINCE_PURSE_90", 10505, "原大陆债券：王子的钱袋90", { "DAILY", "AURORIA_RESIDENT_BOND" }),
    },
    prince_crate = {
        [10] = RegisterId("AURORIA_BOND_PRINCE_CRATE_10", 10506, "原大陆债券：王子的箱子10", { "DAILY", "AURORIA_RESIDENT_BOND" }),
        [30] = RegisterId("AURORIA_BOND_PRINCE_CRATE_30", 10507, "原大陆债券：王子的箱子30", { "DAILY", "AURORIA_RESIDENT_BOND" }),
    },
    queen_purse = {
        [25] = RegisterId("AURORIA_BOND_QUEEN_PURSE_25", 10508, "原大陆债券：女王的钱袋25", { "DAILY", "AURORIA_RESIDENT_BOND" }),
        [75] = RegisterId("AURORIA_BOND_QUEEN_PURSE_75", 10509, "原大陆债券：女王的钱袋75", { "DAILY", "AURORIA_RESIDENT_BOND" }),
    },
    queen_crate = {
        [8] = RegisterId("AURORIA_BOND_QUEEN_CRATE_8", 10510, "原大陆债券：女王的箱子8", { "DAILY", "AURORIA_RESIDENT_BOND" }),
        [25] = RegisterId("AURORIA_BOND_QUEEN_CRATE_25", 10511, "原大陆债券：女王的箱子25", { "DAILY", "AURORIA_RESIDENT_BOND" }),
    },
    ancestor_purse = {
        [20] = RegisterId("AURORIA_BOND_ANCESTOR_PURSE_20", 10512, "原大陆债券：祖先的钱袋20", { "DAILY", "AURORIA_RESIDENT_BOND" }),
        [60] = RegisterId("AURORIA_BOND_ANCESTOR_PURSE_60", 10513, "原大陆债券：祖先的钱袋60", { "DAILY", "AURORIA_RESIDENT_BOND" }),
    },
    ancestor_crate = {
        [7] = RegisterId("AURORIA_BOND_ANCESTOR_CRATE_7", 10514, "原大陆债券：祖先的箱子7", { "DAILY", "AURORIA_RESIDENT_BOND" }),
        [20] = RegisterId("AURORIA_BOND_ANCESTOR_CRATE_20", 10515, "原大陆债券：祖先的箱子20", { "DAILY", "AURORIA_RESIDENT_BOND" }),
    },
}
Q.ResidentBond.AuroriaByTokenQuantity.golden_bag = Q.ResidentBond.AuroriaByTokenQuantity.prince_purse
Q.ResidentBond.AuroriaByTokenQuantity.prince_box = Q.ResidentBond.AuroriaByTokenQuantity.prince_crate
Q.ResidentBond.AuroriaByTokenQuantity.queen_bag = Q.ResidentBond.AuroriaByTokenQuantity.queen_purse
Q.ResidentBond.AuroriaByTokenQuantity.queen_box = Q.ResidentBond.AuroriaByTokenQuantity.queen_crate
Q.ResidentBond.AuroriaByTokenQuantity.heir_bag = Q.ResidentBond.AuroriaByTokenQuantity.ancestor_purse
Q.ResidentBond.AuroriaByTokenQuantity.heir_box = Q.ResidentBond.AuroriaByTokenQuantity.ancestor_crate

-- 表别名只兼容直接访问；旧 Registry semantic key 还须显式 RegisterAlias。
-- 保留 18.300 前的 12 个旧 key，指向同一记录，不重复注册 ID。
for _, alias in ipairs({
    { "AURORIA_BOND_GOLDEN_BAG_30", 10504 }, { "AURORIA_BOND_GOLDEN_BAG_90", 10505 },
    { "AURORIA_BOND_PRINCE_BOX_10", 10506 }, { "AURORIA_BOND_PRINCE_BOX_30", 10507 },
    { "AURORIA_BOND_QUEEN_BAG_25", 10508 }, { "AURORIA_BOND_QUEEN_BAG_75", 10509 },
    { "AURORIA_BOND_QUEEN_BOX_8", 10510 }, { "AURORIA_BOND_QUEEN_BOX_25", 10511 },
    { "AURORIA_BOND_HEIR_BAG_20", 10512 }, { "AURORIA_BOND_HEIR_BAG_60", 10513 },
    { "AURORIA_BOND_HEIR_BOX_7", 10514 }, { "AURORIA_BOND_HEIR_BOX_20", 10515 },
}) do
    Registry:RegisterAlias("quest", alias[1], alias[2])
end

-- 活动任务集合。
Q.Activity.halcy = {
    main = RegisterSet("ACTIVITY_HALCY_MAIN", { 9320 }, "黄金平原普通日常", { "DAILY", "ACTIVITY", "HALCY" }),
    heroSupport = RegisterSet("ACTIVITY_HALCY_HERO_SUPPORT", { 9130 }, nil, { "DAILY", "RELATED", "HALCY" }),
    heroLead = RegisterSet("ACTIVITY_HALCY_HERO_LEAD", { 9223 }, nil, { "DAILY", "RELATED", "HALCY" }),
    heroReward = RegisterSet("ACTIVITY_HALCY_HERO_REWARD", { 9227 }, nil, { "DAILY", "RELATED", "HALCY" }),
    guild = RegisterSet("ACTIVITY_HALCY_GUILD", { 9000225 }, nil, { "DAILY", "GUILD", "RELATED", "HALCY" }),
}

Q.Activity.whalesong = {
    stage1 = RegisterSet("ACTIVITY_WHALESONG_STAGE_1", { 8602, 8609, 8610, 8611 }, nil, { "DAILY", "ACTIVITY", "WHALESONG" }),
    stage2 = RegisterSet("ACTIVITY_WHALESONG_STAGE_2", { 8603, 8612, 8613, 8614 }, nil, { "DAILY", "ACTIVITY", "WHALESONG" }),
    stage3 = RegisterSet("ACTIVITY_WHALESONG_STAGE_3", { 8604, 8615, 8616, 8617 }, nil, { "DAILY", "ACTIVITY", "WHALESONG" }),
    wrapper = RegisterSet("ACTIVITY_WHALESONG_WRAPPER", { 8637, 8638, 8639, 8640 }, nil, { "DAILY", "RELATED", "WHALESONG" }),
    boss = RegisterSet("ACTIVITY_WHALESONG_BOSS", { 8605, 8606, 8607, 8608 }, nil, { "DAILY", "BOSS", "RELATED", "WHALESONG" }),
    guild = RegisterSet("ACTIVITY_WHALESONG_GUILD", { 9000220 }, nil, { "DAILY", "GUILD", "RELATED", "WHALESONG" }),
}

local crimsonCommon = {
    stage1 = RegisterSet("ACTIVITY_CRIMSON_STAGE_1", { 2941 }, nil, { "DAILY", "ACTIVITY", "CRIMSON_RIFT" }),
    stage2 = RegisterSet("ACTIVITY_CRIMSON_STAGE_2", { 2942 }, nil, { "DAILY", "ACTIVITY", "CRIMSON_RIFT" }),
    stage3 = RegisterSet("ACTIVITY_CRIMSON_STAGE_3", { 2943 }, nil, { "DAILY", "ACTIVITY", "CRIMSON_RIFT" }),
    hounds = RegisterSet("ACTIVITY_CRIMSON_HOUNDS", { 10729 }, nil, { "DAILY", "BOSS", "ACTIVITY", "CRIMSON_RIFT" }),
    shadowDemon = RegisterSet("ACTIVITY_CRIMSON_SHADOW_DEMON", { 10730 }, nil, { "DAILY", "ACTIVITY", "CRIMSON_RIFT" }),
    guard = RegisterSet("ACTIVITY_CRIMSON_GUARD", { 8998 }, nil, { "DAILY", "RELATED", "CRIMSON_RIFT" }),
    pathHounds = RegisterSet("ACTIVITY_CRIMSON_PATH_HOUNDS", { 5886 }, nil, { "DAILY", "RELATED", "CRIMSON_RIFT" }),
    guild = RegisterSet("ACTIVITY_CRIMSON_GUILD", { 9000223 }, nil, { "DAILY", "GUILD", "RELATED", "CRIMSON_RIFT" }),
}
Q.Activity.crimson = {
    stage1 = crimsonCommon.stage1,
    stage2 = crimsonCommon.stage2,
    stage3 = crimsonCommon.stage3,
    hounds = crimsonCommon.hounds,
    shadowDemon = crimsonCommon.shadowDemon,
    shadowFang = RegisterSet("ACTIVITY_CRIMSON_SHADOW_FANG", { 10734 }, nil, { "DAILY", "BOSS", "ACTIVITY", "CRIMSON_RIFT" }),
    databaseWrapper = RegisterSet("ACTIVITY_CRIMSON_DATABASE_WRAPPER", { 9000448 }, "Crimson Omens DB aggregate", { "DATABASE_ONLY", "RELATED", "CRIMSON_RIFT" },
        "Database aggregate identity only; do not use as a player-facing stage completion Authority"),
    guard = crimsonCommon.guard,
    pathHounds = crimsonCommon.pathHounds,
    guild = crimsonCommon.guild,
}
Q.Activity.sungoldCrimson = {
    stage1 = crimsonCommon.stage1,
    stage2 = crimsonCommon.stage2,
    stage3 = crimsonCommon.stage3,
    hounds = crimsonCommon.hounds,
    shadowDemon = crimsonCommon.shadowDemon,
    xarkath = RegisterSet("ACTIVITY_SUNGOLD_CRIMSON_XARKATH", { 10735 }, nil, { "DAILY", "BOSS", "ACTIVITY", "SUNGOLD_CRIMSON" }),
    guard = crimsonCommon.guard,
    pathHounds = crimsonCommon.pathHounds,
    guild = crimsonCommon.guild,
    anthalonPath = RegisterSet("ACTIVITY_SUNGOLD_CRIMSON_ANTHALON_PATH", { 5885 }, nil, { "DAILY", "BOSS", "RELATED", "SUNGOLD_CRIMSON" }),
    anthalonArcheMaster = RegisterSet("ACTIVITY_SUNGOLD_CRIMSON_ANTHALON_ARCHEMASTER", { 7396 }, nil, { "DAILY", "BOSS", "RELATED", "SUNGOLD_CRIMSON" }),
}

Q.Activity.ghost = {
    stage1 = RegisterSet("ACTIVITY_GHOST_STAGE_1", { 5143 }, nil, { "DAILY", "ACTIVITY", "GRIMGHAST" }),
    stage2 = RegisterSet("ACTIVITY_GHOST_STAGE_2", { 5144 }, nil, { "DAILY", "ACTIVITY", "GRIMGHAST" }),
    stage3 = RegisterSet("ACTIVITY_GHOST_STAGE_3", { 11192 }, nil, { "DAILY", "ACTIVITY", "GRIMGHAST" }),
    stage4 = RegisterSet("ACTIVITY_GHOST_STAGE_4", { 10739 }, nil, { "DAILY", "ACTIVITY", "GRIMGHAST" }),
    randomMaterial = RegisterSet("ACTIVITY_GHOST_RANDOM_MATERIAL", { 5138, 5139, 5140, 5150, 5151, 5152, 5153, 5154, 5155, 5156 }, nil, { "DAILY", "RELATED", "GRIMGHAST" }),
    trebuchet = RegisterSet("ACTIVITY_GHOST_TREBUCHET", { 5142, 5157 }, nil, { "DAILY", "RELATED", "GRIMGHAST" }),
    boss1 = RegisterSet("ACTIVITY_GHOST_BOSS_1", { 7648 }, nil, { "DAILY", "BOSS", "RELATED", "GRIMGHAST" }),
    boss2 = RegisterSet("ACTIVITY_GHOST_BOSS_2", { 7649 }, nil, { "DAILY", "BOSS", "RELATED", "GRIMGHAST" }),
}

Q.Activity.aegis = {
    stage1 = RegisterSet("ACTIVITY_AEGIS_STAGE_1", { 8623, 8624, 8625, 8626 }, nil, { "DAILY", "ACTIVITY", "AEGIS" }),
    stage2 = RegisterSet("ACTIVITY_AEGIS_STAGE_2", { 8627, 8628, 8629, 8630 }, nil, { "DAILY", "ACTIVITY", "AEGIS" }),
    stage3 = RegisterSet("ACTIVITY_AEGIS_STAGE_3", { 8631, 8632, 8633, 8634 }, nil, { "DAILY", "ACTIVITY", "AEGIS" }),
    wrapper = RegisterSet("ACTIVITY_AEGIS_WRAPPER", { 8641, 8642, 8643, 8644 }, nil, { "DAILY", "RELATED", "AEGIS" }),
    boss = RegisterSet("ACTIVITY_AEGIS_BOSS", { 8618, 8619, 8620, 8621 }, nil, { "DAILY", "BOSS", "RELATED", "AEGIS" }),
    guild = RegisterSet("ACTIVITY_AEGIS_GUILD", { 9000221 }, nil, { "DAILY", "GUILD", "RELATED", "AEGIS" }),
}

Q.Activity.hiramT6 = {
    stage1 = RegisterSet("ACTIVITY_HIRAM_T6_STAGE_1", { 11155 }, nil, { "DAILY", "ACTIVITY", "HIRAM_T6" }),
    stage2 = RegisterSet("ACTIVITY_HIRAM_T6_STAGE_2", { 11156 }, nil, { "DAILY", "ACTIVITY", "HIRAM_T6" }),
    stage3 = RegisterSet("ACTIVITY_HIRAM_T6_STAGE_3", { 11157 }, nil, { "DAILY", "ACTIVITY", "HIRAM_T6" }),
    stage4 = RegisterSet("ACTIVITY_HIRAM_T6_STAGE_4", { 11158 }, nil, { "DAILY", "ACTIVITY", "HIRAM_T6" }),
    wrapper = RegisterSet("ACTIVITY_HIRAM_T6_WRAPPER", { 11154 }, nil, { "DAILY", "RELATED", "HIRAM_T6" }),
}

Q.Activity.jmg = {
    boss1 = RegisterSet("ACTIVITY_JMG_BOSS_1", { 5969 }, nil, { "DAILY", "BOSS", "ACTIVITY", "JMG" }),
    boss2 = RegisterSet("ACTIVITY_JMG_BOSS_2", { 5970 }, nil, { "DAILY", "BOSS", "ACTIVITY", "JMG" }),
    boss3 = RegisterSet("ACTIVITY_JMG_BOSS_3", { 5971 }, nil, { "DAILY", "BOSS", "ACTIVITY", "JMG" }),
    wrapper = RegisterSet("ACTIVITY_JMG_WRAPPER", { 5972 }, nil, { "DAILY", "RELATED", "JMG" }),
    relentlessWrapper = RegisterSet("ACTIVITY_JMG_RELENTLESS_WRAPPER", { 9000467 }, nil, { "DAILY", "RELATED", "JMG" }),
    relentlessBoss1 = RegisterSet("ACTIVITY_JMG_RELENTLESS_BOSS_1", { 10328 }, nil, { "DAILY", "BOSS", "RELATED", "JMG" }),
    relentlessBoss2 = RegisterSet("ACTIVITY_JMG_RELENTLESS_BOSS_2", { 10329 }, nil, { "DAILY", "BOSS", "RELATED", "JMG" }),
    relentlessBoss3 = RegisterSet("ACTIVITY_JMG_RELENTLESS_BOSS_3", { 10330 }, nil, { "DAILY", "BOSS", "RELATED", "JMG" }),
}

Q.Activity.lusca = { main = RegisterSet("ACTIVITY_LUSCA_MAIN", { 5765 }, nil, { "DAILY", "ACTIVITY", "LUSCA" }) }
Q.Activity.haslaShadow = {
    main = RegisterSet("ACTIVITY_HASLA_SHADOW_MAIN", { 8909 }, nil, { "DAILY", "ACTIVITY", "HASLA_SHADOW" }),
    guide = RegisterSet("ACTIVITY_HASLA_SHADOW_GUIDE", { 9494 }, nil, { "RELATED", "HASLA_SHADOW" }),
    triggerBoss = RegisterSet("ACTIVITY_HASLA_SHADOW_TRIGGER_BOSS", { 5884 }, nil, { "DAILY", "BOSS", "RELATED", "HASLA_SHADOW" }),
}
Q.Activity.cinderstonePurify = { main = RegisterSet("ACTIVITY_CINDERSTONE_PURIFY", { 9960, 9962, 9963 }, nil, { "DAILY", "ACTIVITY", "PURIFICATION" }) }
Q.Activity.ynysterePurify = { main = RegisterSet("ACTIVITY_YNYSTERE_PURIFY", { 9964, 9965, 9966 }, nil, { "DAILY", "ACTIVITY", "PURIFICATION" }) }

Q.Activity.akaschGuard = {
    stage1 = RegisterSet("ACTIVITY_AKASCH_GUARD_STAGE_1", { 10561 }, nil, { "DAILY", "ACTIVITY", "AKASCH" }),
    stage2 = RegisterSet("ACTIVITY_AKASCH_GUARD_STAGE_2", { 10562 }, nil, { "DAILY", "ACTIVITY", "AKASCH" }),
    stage3 = RegisterSet("ACTIVITY_AKASCH_GUARD_STAGE_3", { 10563 }, nil, { "DAILY", "ACTIVITY", "AKASCH" }),
    stage4 = RegisterSet("ACTIVITY_AKASCH_GUARD_STAGE_4", { 10558 }, nil, { "DAILY", "ACTIVITY", "AKASCH" }),
    wrapper = RegisterSet("ACTIVITY_AKASCH_GUARD_WRAPPER", { 9000449 }, nil, { "DAILY", "RELATED", "AKASCH" }),
    invasion1 = RegisterSet("ACTIVITY_AKASCH_GUARD_INVASION_1", { 10564 }, nil, { "DAILY", "RELATED", "AKASCH" }),
    invasion2 = RegisterSet("ACTIVITY_AKASCH_GUARD_INVASION_2", { 10565 }, nil, { "DAILY", "RELATED", "AKASCH" }),
    invasion3 = RegisterSet("ACTIVITY_AKASCH_GUARD_INVASION_3", { 10569 }, nil, { "DAILY", "RELATED", "AKASCH" }),
    invasion4 = RegisterSet("ACTIVITY_AKASCH_GUARD_INVASION_4", { 10571 }, nil, { "DAILY", "RELATED", "AKASCH" }),
    eye2 = RegisterSet("ACTIVITY_AKASCH_GUARD_EYE_2", { 10699 }, nil, { "DAILY", "RELATED", "AKASCH" }),
    eye3 = RegisterSet("ACTIVITY_AKASCH_GUARD_EYE_3", { 10700 }, nil, { "DAILY", "RELATED", "AKASCH" }),
    compass2 = RegisterSet("ACTIVITY_AKASCH_GUARD_COMPASS_2", { 10701 }, nil, { "DAILY", "RELATED", "AKASCH" }),
    compass3 = RegisterSet("ACTIVITY_AKASCH_GUARD_COMPASS_3", { 10702 }, nil, { "DAILY", "RELATED", "AKASCH" }),
    orb2 = RegisterSet("ACTIVITY_AKASCH_GUARD_ORB_2", { 10703 }, nil, { "DAILY", "RELATED", "AKASCH" }),
    orb3 = RegisterSet("ACTIVITY_AKASCH_GUARD_ORB_3", { 10704 }, nil, { "DAILY", "RELATED", "AKASCH" }),
    snakeEgg = RegisterSet("ACTIVITY_AKASCH_GUARD_SNAKE_EGG", { 10705 }, nil, { "DAILY", "RELATED", "AKASCH" }),
    combatIntel = RegisterSet("ACTIVITY_AKASCH_GUARD_COMBAT_INTEL", { 10708 }, nil, { "DAILY", "RELATED", "AKASCH" }),
}

Q.Activity.guardianScramble = {
    main = RegisterSet("ACTIVITY_GUARDIAN_SCRAMBLE_MAIN", { 11096, 11116, 11131 }, nil, { "DAILY", "ACTIVITY", "GUARDIAN_SCRAMBLE" }),
    pirate = RegisterSet("ACTIVITY_GUARDIAN_SCRAMBLE_PIRATE", { 11098 }, nil, { "DAILY", "RELATED", "GUARDIAN_SCRAMBLE" }),
    guide = RegisterSet("ACTIVITY_GUARDIAN_SCRAMBLE_GUIDE", { 11099 }, nil, { "RELATED", "GUARDIAN_SCRAMBLE" }),
    victory = RegisterSet("ACTIVITY_GUARDIAN_SCRAMBLE_VICTORY", { 11132, 11133 }, nil, { "DAILY", "RELATED", "GUARDIAN_SCRAMBLE" }),
}

Q.Activity.wonderlandNightmare = { main = RegisterSet("ACTIVITY_WONDERLAND_NIGHTMARE", { 9000333 }, nil, { "DAILY", "BOSS", "ACTIVITY" }) }
Q.Activity.dragonPower = { main = RegisterSet("ACTIVITY_DRAGON_POWER", { 9000170 }, nil, { "DAILY", "ACTIVITY" }) }
Q.Activity.rookborneFestival = {
    trialFestival = RegisterSet("ACTIVITY_ROOKBORNE_FESTIVAL_TRIAL", { 6761 }, nil, { "DAILY", "FESTIVAL" }),
    beginner = RegisterSet("ACTIVITY_ROOKBORNE_FESTIVAL_BEGINNER", { 6758 }, nil, { "DAILY", "FESTIVAL" }),
    expert = RegisterSet("ACTIVITY_ROOKBORNE_FESTIVAL_EXPERT", { 6759 }, nil, { "DAILY", "FESTIVAL" }),
    master = RegisterSet("ACTIVITY_ROOKBORNE_FESTIVAL_MASTER", { 7802 }, nil, { "DAILY", "FESTIVAL" }),
    barley = RegisterSet("ACTIVITY_ROOKBORNE_FESTIVAL_BARLEY", { 6784 }, nil, { "DAILY", "FESTIVAL" }),
    extra1 = RegisterSet("ACTIVITY_ROOKBORNE_FESTIVAL_EXTRA_1", { 6760 }, nil, { "DAILY", "RELATED", "FESTIVAL" }),
    extra2 = RegisterSet("ACTIVITY_ROOKBORNE_FESTIVAL_EXTRA_2", { 6785 }, nil, { "DAILY", "RELATED", "FESTIVAL" }),
    repeat1 = RegisterSet("ACTIVITY_ROOKBORNE_FESTIVAL_REPEAT_1", { 7803 }, nil, { "REPEATABLE", "RELATED", "FESTIVAL" }),
    repeat2 = RegisterSet("ACTIVITY_ROOKBORNE_FESTIVAL_REPEAT_2", { 7804 }, nil, { "REPEATABLE", "RELATED", "FESTIVAL" }),
}
Q.Activity.blackDragon = {
    main = RegisterSet("ACTIVITY_BLACK_DRAGON", { 9221 }, nil, { "DAILY", "BOSS", "ACTIVITY" }),
    guide = RegisterSet("ACTIVITY_BLACK_DRAGON_GUIDE", { 9222 }, nil, { "RELATED", "BOSS" }),
}
Q.Activity.kraken = { main = RegisterSet("ACTIVITY_KRAKEN", { 5883 }, nil, { "DAILY", "BOSS", "ACTIVITY" }) }
Q.Activity.leviathan = { main = RegisterSet("ACTIVITY_LEVIATHAN", { 7655 }, nil, { "DAILY", "BOSS", "ACTIVITY" }) }
Q.Activity.charybdis = { main = RegisterSet("ACTIVITY_CHARYBDIS", { 9969 }, nil, { "DAILY", "BOSS", "ACTIVITY" }) }
Q.Activity.gardenAnthalon = {
    main = RegisterSet("ACTIVITY_GARDEN_ANTHALON", { 10186 }, nil, { "DAILY", "BOSS", "ACTIVITY" }),
    minion = RegisterSet("ACTIVITY_GARDEN_ANTHALON_MINION", { 10187 }, nil, { "DAILY", "RELATED", "BOSS" }),
}
-- 10056 是庭院每日累计积分任务，与固定周常安塔伦 10186/10187 分开。
-- 单独注册 Activity set；同一 Quest ID 可属于多个集合。
Q.Activity.gardenFairyRequest = RegisterSet(
    "ACTIVITY_GARDEN_FAIRY_REQUEST", { 10056 }, "精灵的委托",
    { "DAILY", "ACTIVITY", "GARDEN", "SCORE" },
    "Garden of the Gods score/reward-level daily; display native journal detail instead of inventing a local score parser."
)
Q.Activity.abyssal = {
    doomsday = RegisterSet("ACTIVITY_ABYSSAL_DOOMSDAY", { 6791 }, nil, { "DAILY", "ACTIVITY", "ABYSSAL" }),
    seaknight = RegisterSet("ACTIVITY_ABYSSAL_SEAKNIGHT", { 6973, 6974, 6975, 6976 }, nil, { "DAILY", "ACTIVITY", "ABYSSAL" }),
}

-- 仅供面板使用的日常 / 周常集合。
local residentDaily = RegisterSet("DAILY_RESIDENT_ALL", { 8345, 8347, 8348, 8349, 8350, 8559, 8560, 8561, 8562, 8588, 8589, 8590, 8591, 8592, 8593 }, nil, { "DAILY", "RESIDENT" })
Q.Dashboard.Daily.guild = RegisterSet("DAILY_GUILD", { 7736, 7737 }, nil, { "DAILY", "GUILD" })
Q.Dashboard.Daily.pack20 = RegisterSet("DAILY_PACK_20", { 9000226 }, nil, { "DAILY", "TRADE_PACK" })
Q.Dashboard.Daily.resident = residentDaily
Q.Dashboard.Daily.eastHiram1 = RegisterSet("DAILY_EAST_HIRAM_1", { 9317 }, nil, { "DAILY", "EAST_HIRAM" })
Q.Dashboard.Daily.eastHiram2 = RegisterSet("DAILY_EAST_HIRAM_2", { 9318 }, nil, { "DAILY", "EAST_HIRAM" })
Q.Dashboard.Daily.eastHiram3 = RegisterSet("DAILY_EAST_HIRAM_3", { 9326 }, nil, { "DAILY", "EAST_HIRAM" })
Q.Dashboard.Daily.akaschTransfer = RegisterSet("DAILY_AKASCH_TRANSFER", { 10559 }, nil, { "DAILY", "AKASCH" })
Q.Dashboard.Daily.garden = RegisterSet("DAILY_GARDEN_FAIRY_REQUEST", { 10056 }, nil, { "DAILY", "GARDEN" })
Q.Dashboard.Daily.gardenResearch1 = RegisterSet("DAILY_GARDEN_RESEARCH_1", { 10145 }, nil, { "DAILY", "RELATED", "GARDEN" })
Q.Dashboard.Daily.gardenResearch2 = RegisterSet("DAILY_GARDEN_RESEARCH_2", { 10146 }, nil, { "DAILY", "RELATED", "GARDEN" })
Q.Dashboard.Daily.gardenResearch3 = RegisterSet("DAILY_GARDEN_RESEARCH_3", { 10147 }, nil, { "DAILY", "RELATED", "GARDEN" })
Q.Dashboard.Daily.gardenResearch4 = RegisterSet("DAILY_GARDEN_RESEARCH_4", { 10148 }, nil, { "DAILY", "RELATED", "GARDEN" })
Q.Dashboard.Daily.gardenResearchFaction = RegisterSet("DAILY_GARDEN_RESEARCH_FACTION", { 10188, 10189 }, nil, { "DAILY", "RELATED", "GARDEN" })
Q.Dashboard.Daily.fish20 = RegisterSet("DAILY_FISH_20", { 9000531 }, nil, { "DAILY", "FISHING" })

Q.Dashboard.Weekly.westHiram1 = RegisterSet("WEEKLY_WEST_HIRAM_1", { 9077 }, nil, { "WEEKLY", "WEST_HIRAM" })
Q.Dashboard.Weekly.westHiram2 = RegisterSet("WEEKLY_WEST_HIRAM_2", { 11196 }, nil, { "WEEKLY", "WEST_HIRAM" })
Q.Dashboard.Weekly.eastHiram1 = RegisterSet("WEEKLY_EAST_HIRAM_1", { 10334 }, nil, { "WEEKLY", "EAST_HIRAM" })
Q.Dashboard.Weekly.eastHiram2 = RegisterSet("WEEKLY_EAST_HIRAM_2", { 10335 }, nil, { "WEEKLY", "EAST_HIRAM" })
Q.Dashboard.Weekly.auroria1 = RegisterSet("WEEKLY_AURORIA_1", { 9131 }, nil, { "WEEKLY", "AURORIA" })
Q.Dashboard.Weekly.auroria2 = RegisterSet("WEEKLY_AURORIA_2", { 9017 }, nil, { "WEEKLY", "AURORIA" })
Q.Dashboard.Weekly.auroriaRelated1 = RegisterSet("WEEKLY_AURORIA_RELATED_1", { 9019 }, nil, { "WEEKLY", "RELATED", "AURORIA" })
Q.Dashboard.Weekly.auroriaRelated2 = RegisterSet("WEEKLY_AURORIA_RELATED_2", { 9020 }, nil, { "WEEKLY", "RELATED", "AURORIA" })
Q.Dashboard.Weekly.auroriaPirate1 = RegisterSet("WEEKLY_AURORIA_PIRATE_1", { 9021 }, nil, { "WEEKLY", "RELATED", "PIRATE", "AURORIA" })
Q.Dashboard.Weekly.auroriaPirate2 = RegisterSet("WEEKLY_AURORIA_PIRATE_2", { 9052 }, nil, { "WEEKLY", "RELATED", "PIRATE", "AURORIA" })
Q.Dashboard.Weekly.auroriaPirate3 = RegisterSet("WEEKLY_AURORIA_PIRATE_3", { 9053 }, nil, { "WEEKLY", "RELATED", "PIRATE", "AURORIA" })
Q.Dashboard.Weekly.akasch = RegisterSet("WEEKLY_AKASCH", { 11200 }, nil, { "WEEKLY", "AKASCH" })

Q.Resident.all = residentDaily
Q.Resident.packDelivery = {
    [8559] = RegisterId("RESIDENT_PACK_DELIVERY_8559", 8559, nil, { "DAILY", "RESIDENT", "TRADE_PACK" }),
    [8560] = RegisterId("RESIDENT_PACK_DELIVERY_8560", 8560, nil, { "DAILY", "RESIDENT", "TRADE_PACK" }),
    [8561] = RegisterId("RESIDENT_PACK_DELIVERY_8561", 8561, nil, { "DAILY", "RESIDENT", "TRADE_PACK" }),
    [8562] = RegisterId("RESIDENT_PACK_DELIVERY_8562", 8562, nil, { "DAILY", "RESIDENT", "TRADE_PACK" }),
    [8588] = RegisterId("RESIDENT_PACK_DELIVERY_8588", 8588, nil, { "DAILY", "RESIDENT", "TRADE_PACK" }),
    [8589] = RegisterId("RESIDENT_PACK_DELIVERY_8589", 8589, nil, { "DAILY", "RESIDENT", "TRADE_PACK" }),
    [8590] = RegisterId("RESIDENT_PACK_DELIVERY_8590", 8590, nil, { "DAILY", "RESIDENT", "TRADE_PACK" }),
    [8591] = RegisterId("RESIDENT_PACK_DELIVERY_8591", 8591, nil, { "DAILY", "RESIDENT", "TRADE_PACK" }),
    [8592] = RegisterId("RESIDENT_PACK_DELIVERY_8592", 8592, nil, { "DAILY", "RESIDENT", "TRADE_PACK" }),
    [8593] = RegisterId("RESIDENT_PACK_DELIVERY_8593", 8593, nil, { "DAILY", "RESIDENT", "TRADE_PACK" }),
}

-- 仅供诊断的快照，禁止从逐帧任务轮询调用。
function Q:Describe()
    local total, verified, pending = 0, 0, 0
    for _, record in ipairs(Registry:List("quest") or {}) do
        total = total + 1
        if record.verified == true and record.confidence == "database_verified" then
            verified = verified + 1
        else
            pending = pending + 1
        end
    end
    return {
        total = total,
        verified = verified,
        pending = pending,
        verifiedAt = VERIFIED_AT,
    }
end

