-- Replicated Suite · 活动日程数据
-- 作者：Replicated
-- QQ群：1104129461
-- 活动名称沿用 Suite/任务现有称谓；响应式控件仅在狭窄宽度使用人工整理的 short/micro 别名。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Data = S.Data or {}

local ALL = {1,2,3,4,5,6,7}
local function Times(days, duration, values)
    local result = {}
    for _, hm in ipairs(values) do
        result[#result + 1] = {
            days = days,
            hour = hm[1],
            minute = hm[2],
            duration = hm[3] or duration,
        }
    end
    return result
end

local E = {}
local O = (S.Data.OfficialNames and S.Data.OfficialNames.Event) or {}
local function Add(fullName, shortName, entries, questKey, options)
    options = type(options) == "table" and options or {}
    for _, item in ipairs(entries) do
        item.name = fullName
        item.fullName = fullName
        -- 窄布局选 full/short/micro 数据别名，避免直接截字挤占倒计时。
        item.shortName = shortName or fullName
        item.microName = options.microName or shortName or fullName
        item.questScope = questKey and "event" or nil
        item.questKey = questKey
        -- EventService 按服务器日期控制季节/自定义活动。日程保留在唯一标准表中；节庆非官方开放期不产生行或提醒。
        item.activeFrom = options.activeFrom
        item.activeUntil = options.activeUntil
        -- 证据等级仅供显示/诊断；不改 fullName/key 或旧关注配置。
        -- 第三方表一致不等于官方核验；计划时长不能证明首领存活。
        item.scheduleConfidence = options.scheduleConfidence
        item.scheduleEvidence = options.scheduleEvidence
        E[#E + 1] = item
    end
end

-- RU静态日程使用服务器墙钟；完整中文名为权威，短别名仅表现。迷雾战争官方游戏时间00:05开始，当前RU阶段对应每四小时服务器xx:20。
-- 必须用服务器墙钟，避免不同场景/副本昼夜时钟影响倒计时；准备阶段是唯一任务开始时刻，禁止再加独立战斗开始行。
Add(O.GR or "迷雾战争", "迷雾", Times(ALL,20,{{2,20},{6,20},{10,20},{14,20},{18,20},{22,20}}), "ghost", { microName="迷雾" })
-- 大陆红龙之渊：Rank 1-3 → Hounds → Shadow Demons → Shadow Fang；Anthalon 不属于本行，任务进度与日程分别处理。
Add(O.CR or "征兆之痕", "征兆", Times(ALL,10,{{0,20},{4,20},{8,20},{12,20},{16,20},{20,20}}), "crimson", { microName="征兆" })
Add(O.HIRAM_T6 or "空虚军团入侵", "空虚军团", Times(ALL,40,{{1,50},{5,50},{9,50},{13,50},{17,50},{21,50}}), "hiram_t6", { microName="空虚" })
-- Sungold/原大陆使用独立活动组，虽然共享早期 Rift 阶段，但 Anthalon 是 Shadow Totem / Shadow Demons / Xarkath 前的原大陆专属世界首领门槛。Shadow Fang 任务 10734 属于大陆分支。
Add(O.SUNGOLD_CRIMSON or "煦日之野征兆", "煦日征兆", Times(ALL,10,{{1,20},{5,20},{9,20},{13,20},{17,20},{21,20}}), "sungold_crimson", { microName="煦日" })
-- JMG 的 RU 日程可能按地区黄金时段调整。这里保存当前插件基线的服务器时刻，禁止统一套用北京时间 ±5h 换算；只在当前 RU 日程来源或实机观察确认确切时刻后修改。
Add(O.JMG or "JMG", "JMG", Times(ALL,15,{{3,20},{7,20},{11,20},{15,20},{19,20},{23,20}}), "jmg", { microName="JMG", scheduleConfidence="reference", scheduleEvidence="当前工程与用户 TimeUntil(1) 时刻一致；当前 RU 具体场次待实机核对；15 分钟为计划显示窗口" })
-- 海妖之乱/Lusca以传送门和主活动开放为日程权威；当前RU实机观察为服务器12:30/22:00。不能为早期怪物波减10分钟，倒计时必须告知玩家实际可进入时刻。
Add(O.LUSCA or "海妖之乱", "海妖", Times(ALL,30,{{12,30},{22,0}}), "lusca", { microName="海妖" })
Add(O.BLACK_DRAGON or "黑龙柯萨纳斯", "黑龙", Times({3,5},60,{{21,30}}), "black_dragon", { microName="黑龙" })
Add(O.BLACK_DRAGON or "黑龙柯萨纳斯", "黑龙", Times({7},60,{{18,30}}), "black_dragon", { microName="黑龙" })
Add("克拉肯", "克拉肯", Times({3,5},60,{{22,30}}), "kraken", { microName="克拉肯" })
Add("克拉肯", "克拉肯", Times({7},60,{{19,30}}), "kraken", { microName="克拉肯" })
Add("利维坦", "利维坦", Times({3,5},60,{{20,5}}), "leviathan", { microName="利维坦" })
Add("利维坦", "利维坦", Times({7},60,{{17,5}}), "leviathan", { microName="利维坦" })
Add(O.CHARYBDIS or "死亡捕食者卡里迪斯", "卡里迪斯", Times({1,5},60,{{21,30}}), "charybdis", { microName="卡里" })
Add("庭院安塔伦", "庭安塔伦", Times({1,2,6},45,{{21,30}}), "garden_anthalon", { microName="庭安" })
-- RU Halcy 时间窗口依据上游 2026-08-05 的校正记录。
Add(O.HALCY or "黄金平原战争", "黄金", Times(ALL,30,{{1,30,30},{11,0,90},{20,30,60}}), "halcy", { microName="黄金" })
-- RuTimers 的三个 Red Dragon 时间窗口均为 30 分钟。
Add("红龙", "红龙", Times({1,2,4,6},30,{{2,0},{10,30},{20,0}}), "red_dragon", { microName="红龙" })
-- 血之使者卡杜姆/Kadum与红龙巢穴同属账号每轮一次进入的团队副本，完成为X2BattleField的1/1进入计数，不能按任务处理。
-- 活动指南列Kadum周日/二/四/六，红龙周日/一/三/五；RU时间窗共用red_dragon行和服务器墙钟。
Add("血之使者卡杜姆", "卡杜姆", Times({1,3,5,7},30,{{2,0},{10,30},{20,0}}), "kadum", { microName="卡杜姆" })
-- Titan Attack 是季节活动；官方 2026 年开放期为 2026-05-27 至 2026-06-23。两个 Titan 行在此区间外必须不可用，不能为不存在的活动显示倒计时。
Add("小泰坦", "小泰坦", Times({3,6},15,{{4,0},{7,0},{10,0},{13,0},{16,0},{19,0},{22,0}}), nil, { activeFrom="2026-05-27", activeUntil="2026-06-23", microName="小泰" })
Add("大泰坦", "大泰坦", Times({4,7},15,{{14,0},{21,0}}), nil, { activeFrom="2026-05-27", activeUntil="2026-06-23", microName="大泰" })
Add(O.ABYSSAL or "深渊之袭", "深渊", Times({3,5,7},30,{{12,0},{22,30}}), "abyssal", { microName="深渊" })
-- 原表把每天的 Hasla 限为周日到周三且提前11分钟，周五会显示“两天后”。
-- RU Wiki 任务9000068文本明确每天21:00；19:00仅用户提供的 TimeUntil(1) 有记录，必须标参考。
-- 两场共用原活动 key/任务；15分钟仍只是计划窗口，不宣称怪物必定存在或精确结束。
-- https://wiki.archerage.to/ru-en/db/quests/9000068 （2026-09-18核对）。不把 NA 日程套给 RU。
Add("翡翠谷征兆", "翡翠征兆", Times(ALL,15,{{19,0}}), "hasla_shadow", { microName="翡翠", scheduleConfidence="reference", scheduleEvidence="用户 TimeUntil(1)；19:00场待 RU 实机确认" })
Add("翡翠谷征兆", "翡翠征兆", Times(ALL,15,{{21,0}}), "hasla_shadow", { microName="翡翠", scheduleConfidence="quest_text", scheduleEvidence="RU Wiki quest 9000068: Every day at 9pm；15分钟为计划窗口" })
-- Akasch Invasion / Ipnya Defense 当前仅周五、周六开放。RU 维护日程的 2025 年校核明确：周六第三场 21:30，周五第三场 22:00。
-- 保留当前 20 分钟活动展示窗口；旧 7.5 补丁提到 40 分钟，但没有足够明确的当前官方静态时长证据可以覆盖实机 RU 数据。
Add("守山", "守山", Times({7},20,{{15,0},{18,30},{21,30}}), "akasch_guard", { microName="守山" })
Add("守山", "守山", Times({6},20,{{15,0},{18,30},{22,0}}), "akasch_guard", { microName="守山" })
-- Great Prairie Guardian Scramble 禁止直接以 2024 年原版 9.0 日程作为最终 RU 权威，该补丁页明确排除 ArcheRage 自定义变更。
-- 2026 年维护的 RU 日程在周五/周六均为 09:00、22:00，展示窗口 20 分钟；只有更新 RU 官方日程明确替代后才能修改。
Add("大草原守护者争夺战", "大草原", Times({6,7},20,{{9,0},{22,0}}), "guardian_scramble", { microName="草原" })

-- Wonderland 首领 Waking Nightmare（RU：Кошмар наяву）与 Captain Moris 每日 11:00、19:00 出现；官方指南明确未击杀首领 30 分钟后离开。
-- 活动窗口因此为 30 分钟，不能使用 Timeuntil 仅用于展示的 5 分钟；任务 9000333 由下方整理的日常组绑定。
Add("梦境", "梦境", Times(ALL,30,{{11,0},{19,0}}), "wonderland_nightmare", { microName="梦境" })

-- Dragon Festival/Imperial Dragon（吸龙）官方2026开放窗口为2026-07-29至2026-08-18；龙之力9000170描述服务器00:00/07:00/14:00/19:00出现。
-- 参考timeUntil的5分钟窗口仅为表现保留，不能作为存活事实。
Add("吸龙", "吸龙", Times(ALL,5,{{0,0},{7,0},{14,0},{19,0}}), "dragon_power", { activeFrom="2026-07-29", activeUntil="2026-08-18", microName="吸龙" })

S.Data.RuEvents = E



-- 实时地区冲突周期。保留既有完整中文地区名；每个监控地区都是独立活动行，展示任务进度。
S.Data.ZoneStateWatch = {
    -- 短名称仅在响应式布局变窄时使用。
    { zoneId = 20,  name = O.CINDERSTONE or "十字星平原", fullName = O.CINDERSTONE or "十字星平原", stripName = "十字星", sourceName = "Cinderstone Moor", questScope = "event", questKey = "cinderstone_purify" },
    { zoneId = 17,  name = O.YNYSTERE or "伊尼斯泰尔", fullName = O.YNYSTERE or "伊尼斯泰尔", stripName = "伊尼斯", sourceName = "Ynystere", questScope = "event", questKey = "ynystere_purify" },
    -- 显式 questScope/questKey 将鲸鱼歌湾、海之烛台实时行接到阶段进度和三阶段详情。
    { zoneId = 103, name = O.WHALESONG or "鲸鱼歌湾", fullName = O.WHALESONG or "鲸鱼歌湾", stripName = "鲸鱼", sourceName = "Whalesong Harbor", questScope = "event", questKey = "whalesong" },
    -- 神盾岛与鲸歌港属于同类实时地区，所有阶段保持可见；只有额外任务倒计时和状态随阶段变化。
    { zoneId = 102, name = O.AEGIS or "海之烛台", fullName = O.AEGIS or "海之烛台", stripName = "烛台", sourceName = "Aegis Island", questScope = "event", questKey = "aegis" },
}
S.Data.ZoneStateWatchById = {}
for _, definition in ipairs(S.Data.ZoneStateWatch) do
    S.Data.ZoneStateWatchById[definition.zoneId] = definition
end

-- RU 客户端允许的 GetZoneStateInfoByZoneId() 返回值提供 remainTime；timeUntil 也直接用它表示 Conflict / War / Peace。
-- 阶段计时必须消费该字段，不能从插件碰巧观察到阶段切换的时刻编造 15 分钟时钟。
S.Data.DynamicEventZones = {
    -- 神之庭院在客户端/数据库为zone133；普通团本首领关联实时War阶段，庭院Anthalon保留上方独立周常固定日程。
-- 同一庭院事实按阶段互斥投影：WAR前timeline提醒四首领，Native确认WAR后仅live section显示战争剩余。Presentation禁止复制判定，不能本地计时1h50m，继续直接消费X2Map.remainTime。
    [133] = {
        name = "庭院Boss", fullName = "庭院Boss", shortName = "庭院", microName = "庭院",
        sourceName = "Garden of the Gods",
        -- 庭院战争/Boss 时间只取 zone133 Native 状态；活动行另外关联精灵的委托 10056，供点击详情和显示任务状态。
        -- 任务状态不能证明战争或 Boss 存活；积分先展示原生 Journal，未核实结构化数值前不猜阈值。
        questScope = "event", questKey = "garden_fairy",
        -- 当前 RU 规则在 War 前保留 10 分钟 Conflict；Peace 期间可用权威 Peace 剩余时间加这段提前量推导下次首领窗口。
        conflictLeadMinutes = 10,
    },
    [102] = {
        name = O.AEGIS or "海之烛台", fullName = O.AEGIS or "海之烛台",
        questScope = "event", questKey = "aegis", sourceName = "Aegis",
        inlineOnly = true,
        -- RU 实机以战争剩余 1h24m 为出怪点；出怪后保留 10 分钟提示，剩余 1h14m 时移除活动行。
        -- 纷争倒计时还须加上开战后的 6 分钟；实时区域行继续展示原生战争状态。
        warTotalMinutes = 90,
        spawnWarRemainMinutes = 84,
        spawnDisplayMinutes = 10,
    },
    [103] = {
        name = O.WHALESONG or "鲸鱼歌湾", fullName = O.WHALESONG or "鲸鱼歌湾",
        questScope = "event", questKey = "whalesong", sourceName = "Whalesong",
        inlineOnly = true,
        -- RU 实机刷新点为战争剩余 1h17m，旧 76m 晚约一分钟；仍直接用 X2Map.remainTime。
        -- 规则变化只改数据与回归，表现层不能另补秒数。
        bossWarRemainMinutes = 77,
        -- 保持原先约 1 分钟的“已到刷新时间”窗口，因此结束阈值同步前移到 1h16m。
        -- 这里表示推导窗口，不声称 Boss 实际存活到该秒。
        bossActiveUntilWarRemainMinutes = 76,
        bossLabel = "Boss",
    },
}
