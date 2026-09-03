------------------------------------------------------------------------
-- Replicated Suite - ArcheRage RU event schedule
-- Event names keep the established Suite/quest wording.
-- Responsive widgets use curated short/micro aliases only at narrow widths.
------------------------------------------------------------------------
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
        -- Responsive event widgets choose among full / short / micro names.
        -- Keep these semantic aliases in data instead of truncating rendered text
        -- so narrow layouts remain recognizable and never bleed into the timer.
        item.shortName = shortName or fullName
        item.microName = options.microName or shortName or fullName
        item.questScope = questKey and "event" or nil
        item.questKey = questKey
        -- Seasonal/custom events are date-gated by server date in EventService.
        -- The schedule remains in one canonical table, but inactive festivals
        -- never produce rows or reminders outside their official active window.
        item.activeFrom = options.activeFrom
        item.activeUntil = options.activeUntil
        -- Some activities continue into quest-driven boss/follow-up phases after
        -- the short schedule presentation window. EventService may keep only the
        -- most recent occurrence visible while one of the group's explicitly
        -- marked follow-up objectives is still active/ready.
        item.taskTailMinutes = tonumber(options.taskTailMinutes)
        E[#E + 1] = item
    end
end

-- ArcheRage RU schedule. Static entries use server wall-clock time.
-- Keep full Chinese names as Authority; short aliases are presentation-only.
-- Grimghast Rift / 迷雾战争 officially starts at 00:05 in-game time.
-- On the current RU server phase that maps to xx:20 server time every four hours.
-- Use server wall-clock Authority here so instances/scenes with a different local
-- day/night clock cannot skew the countdown. The preparation phase is treated as
-- the single task-start time; do not add a separate combat-start row.
Add(O.GR or "迷雾战争", "迷雾", Times(ALL,20,{{2,20},{6,20},{10,20},{14,20},{18,20},{22,20}}), "ghost", { microName="迷雾" })
-- Continental Crimson Rift: Rank 1-3 -> Hounds -> Shadow Demons -> Shadow Fang.
-- Anthalon is never part of this row. Keep the row alive after the short wave
-- window while one of the explicitly marked later objectives is active/ready.
Add(O.CR or "征兆之痕", "征兆", Times(ALL,10,{{0,20},{4,20},{8,20},{12,20},{16,20},{20,20}}), "crimson", { microName="征兆", taskTailMinutes=90 })
Add(O.HIRAM_T6 or "空虚军团入侵", "空虚军团", Times(ALL,40,{{1,50},{5,50},{9,50},{13,50},{17,50},{21,50}}), "hiram_t6", { microName="空虚" })
-- Sungold/Auroria uses its own activity group. It shares the early Rift ranks,
-- but Anthalon is the Auroria-only world-boss gate before Shadow Totem / Shadow
-- Demons / Xarkath. Shadow Fang quest 10734 belongs to the continental branch.
Add(O.SUNGOLD_CRIMSON or "煦日之野征兆", "煦日征兆", Times(ALL,10,{{1,20},{5,20},{9,20},{13,20},{17,20},{21,20}}), "sungold_crimson", { microName="煦日", taskTailMinutes=120 })
-- JMG is one of the RU schedules that may be adjusted for regional prime time.
-- These are server-clock slots from the current addon baseline; do NOT apply a
-- blanket Beijing +/-5h conversion. Change them only after a current RU schedule
-- source or live server observation verifies the exact occurrence times.
Add(O.JMG or "JMG", "JMG", Times(ALL,15,{{3,20},{7,20},{11,20},{15,20},{19,20},{23,20}}), "jmg", { microName="JMG" })
-- Lusca / 海妖之乱: use the portal/main-event opening as schedule Authority.
-- Current RU live observation reports the portal at 12:30 / 22:00 server
-- time.  Do not subtract ten minutes for an earlier monster-wave phase: the
-- activity timer is meant to tell players when they can actually enter.
Add(O.LUSCA or "海妖之乱", "海妖", Times(ALL,30,{{12,30},{22,0}}), "lusca", { microName="海妖" })
Add(O.BLACK_DRAGON or "黑龙柯萨纳斯", "黑龙", Times({3,5},60,{{21,30}}), "black_dragon", { microName="黑龙" })
Add(O.BLACK_DRAGON or "黑龙柯萨纳斯", "黑龙", Times({7},60,{{18,30}}), "black_dragon", { microName="黑龙" })
Add("克拉肯", "克拉肯", Times({3,5},60,{{22,30}}), "kraken", { microName="克拉肯" })
Add("克拉肯", "克拉肯", Times({7},60,{{19,30}}), "kraken", { microName="克拉肯" })
Add("利维坦", "利维坦", Times({3,5},60,{{20,5}}), "leviathan", { microName="利维坦" })
Add("利维坦", "利维坦", Times({7},60,{{17,5}}), "leviathan", { microName="利维坦" })
Add(O.CHARYBDIS or "死亡捕食者卡里迪斯", "卡里迪斯", Times({1,5},60,{{21,30}}), "charybdis", { microName="卡里" })
Add("庭院安塔伦", "庭安塔伦", Times({1,2,6},45,{{21,30}}), "garden_anthalon", { microName="庭安" })
-- Upstream corrected these RU Halcy windows on 2026-08-05.
Add(O.HALCY or "黄金平原战争", "黄金", Times(ALL,30,{{1,30,30},{11,0,90},{20,30,60}}), "halcy", { microName="黄金" })
-- RuTimers uses 30 minutes for all three Red Dragon windows.
Add("红龙", "红龙", Times({1,2,4,6},30,{{2,0},{10,30},{20,0}}), "red_dragon", { microName="红龙" })
-- 血之使者卡杜姆 / Kadum is the second one-entry-per-account team raid of the
-- same class as 红龙巢穴 (both are instances, NOT quests; completion is the
-- "1/1" entry counter read from X2BattleField).  ArcheRage's event guide lists
-- Kadum on Sun/Tue/Thu/Sat while 红龙巢穴 runs Sun/Mon/Wed/Fri; the RU windows
-- mirror the red_dragon row (server wall-clock Authority, same as above).
Add("血之使者卡杜姆", "卡杜姆", Times({1,3,5,7},30,{{2,0},{10,30},{20,0}}), "kadum", { microName="卡杜姆" })
-- Titan Attack is a seasonal event, not a permanent weekly schedule.
-- Official 2026 run: 2026-05-27 through 2026-06-23. Keep both Titan rows
-- unavailable outside that window instead of showing a countdown for an event
-- that does not currently exist.
Add("小泰坦", "小泰坦", Times({3,6},15,{{4,0},{7,0},{10,0},{13,0},{16,0},{19,0},{22,0}}), nil, { activeFrom="2026-05-27", activeUntil="2026-06-23", microName="小泰" })
Add("大泰坦", "大泰坦", Times({4,7},15,{{14,0},{21,0}}), nil, { activeFrom="2026-05-27", activeUntil="2026-06-23", microName="大泰" })
Add(O.ABYSSAL or "深渊之袭", "深渊", Times({3,5,7},30,{{12,0},{22,30}}), "abyssal", { microName="深渊" })
Add("翡翠谷征兆", "翡翠征兆", Times({1,2,3,4},15,{{18,49},{20,49}}), "hasla_shadow", { microName="翡翠" })
-- Akasch Invasion / Ipnya Defense. Version 9.0 removed Monday, leaving
-- Friday/Saturday. The maintained RU timer has a dedicated 2025 fix that
-- keeps Saturday's third start at 21:30 and shifts Friday's third start to
-- 22:00. Keep its current 20-minute activity presentation window; the older
-- 7.5 patch described a 40-minute limit, but no current first-party static
-- schedule exposes a newer duration clearly enough to override live RU data.
Add("守山", "守山", Times({7},20,{{15,0},{18,30},{21,30}}), "akasch_guard", { microName="守山" })
Add("守山", "守山", Times({6},20,{{15,0},{18,30},{22,0}}), "akasch_guard", { microName="守山" })
-- Great Prairie Guardian Scramble. Do not use the 2024 original 9.0
-- schedule as the final RU Authority: that patch page explicitly excludes
-- ArcheRage custom changes. The maintained RU schedule split (2026) keeps
-- Friday/Saturday starts at 09:00 and 22:00 with a 20-minute presentation
-- window; preserve both current RU slots unless a newer RU first-party
-- schedule explicitly supersedes them.
Add("大草原守护者争夺战", "大草原", Times({6,7},20,{{9,0},{22,0}}), "guardian_scramble", { microName="草原" })

-- Wonderland boss "Waking Nightmare" / RU "Кошмар наяву". Captain Moris
-- and the boss appear daily at 11:00 and 19:00. If the boss is not killed,
-- the official Wonderland guide states it leaves after 30 minutes, so the
-- activity window is 30 minutes (not Timeuntil's presentation-only 5 min).
-- Quest 9000333 is bound through the curated daily group below.
Add("梦境", "梦境", Times(ALL,30,{{11,0},{19,0}}), "wonderland_nightmare", { microName="梦境" })

-- Dragon Festival / Imperial Dragon ("吸龙").
-- Current official 2026 festival window is 2026-07-29 through 2026-08-18.
-- Quest "龙之力" (9000170) states the Imperial Warrior Dragon appears at
-- 00:00 / 07:00 / 14:00 / 19:00 server time. The supplied working timeUntil
-- keeps a 5-minute active window, which we retain only for presentation.
Add("吸龙", "吸龙", Times(ALL,5,{{0,0},{7,0},{14,0},{19,0}}), "dragon_power", { activeFrom="2026-07-29", activeUntil="2026-08-18", microName="吸龙" })

S.Data.RuEvents = E



-- Live conflict-cycle status. Keep the established full Chinese zone names;
-- every watched zone is rendered as a first-class activity row with task progress.
S.Data.ZoneStateWatch = {
    -- Short names are used only when the responsive layout becomes narrow.
    { zoneId = 20,  name = O.CINDERSTONE or "十字星平原", fullName = O.CINDERSTONE or "十字星平原", stripName = "十字星", sourceName = "Cinderstone Moor", questScope = "event", questKey = "cinderstone_purify" },
    { zoneId = 17,  name = O.YNYSTERE or "伊尼斯泰尔", fullName = O.YNYSTERE or "伊尼斯泰尔", stripName = "伊尼斯", sourceName = "Ynystere", questScope = "event", questKey = "ynystere_purify" },
    { zoneId = 103, name = O.WHALESONG or "鲸鱼歌湾", fullName = O.WHALESONG or "鲸鱼歌湾", stripName = "鲸鱼", sourceName = "Whalesong Harbor" },
    -- Aegis is the same live-region class as Whalesong. Keep it visible in
    -- every phase; only its extra task countdown/status changes with the phase.
    { zoneId = 102, name = O.AEGIS or "海之烛台", fullName = O.AEGIS or "海之烛台", stripName = "烛台", sourceName = "Aegis Island" },
}
S.Data.ZoneStateWatchById = {}
for _, definition in ipairs(S.Data.ZoneStateWatch) do
    S.Data.ZoneStateWatchById[definition.zoneId] = definition
end

-- Live event annotations. The allowed GetZoneStateInfoByZoneId() return value
-- exposes remainTime on this RU client; the user's working timeUntil addon uses
-- that field directly for Conflict / War / Peace.  Therefore the Suite no longer
-- manufactures 15-minute clocks from the moment the addon happens to observe a
-- phase transition.
S.Data.DynamicEventZones = {
    -- Garden of the Gods is zone 133 on the ArcheRage client/database.
    -- Ordinary Garden raid bosses are tied to the live War phase, while
    -- Garden Anthalon keeps its separate fixed weekly schedule above.
    -- Render this as a normal activity row instead of a fifth zone-strip cell.
    [133] = {
        name = "庭院Boss", fullName = "庭院Boss", shortName = "庭院", microName = "庭院",
        sourceName = "Garden of the Gods",
        -- Generic Garden War/boss availability has no single verified quest
        -- mapping.  Do not attach Fairy Request (10056), which is an unrelated
        -- ordinary Garden daily.
        liveRowOnly = true,
        -- Current RU rules retain a 10-minute Conflict immediately before War.
        -- During Peace we can therefore derive the next boss window from the
        -- authoritative remaining Peace time plus this Conflict lead.
        conflictLeadMinutes = 10,
    },
    [102] = {
        name = O.AEGIS or "海之烛台", fullName = O.AEGIS or "海之烛台",
        questScope = "event", questKey = "aegis", sourceName = "Aegis",
        inlineOnly = true,
        -- Aegis tasks are useful only at the opening of War.  The live regional
        -- War clock starts at 90 minutes; keep the explicit "进行中" marker for
        -- the first 20 minutes only (remain > 70m).  After that, the row stays
        -- visible as ordinary War phase information without claiming the event
        -- itself is still running.
        warTotalMinutes = 90,
        activeWarMinutes = 20,
    },
    [103] = {
        name = O.WHALESONG or "鲸鱼歌湾", fullName = O.WHALESONG or "鲸鱼歌湾",
        questScope = "event", questKey = "whalesong", sourceName = "Whalesong",
        inlineOnly = true,
        -- RU-server live rule confirmed by the user: during War, the map's
        -- authoritative remaining-time counter triggers the Whalesong Boss
        -- when it reaches 1h16m.  This is a War-remaining threshold, NOT an
        -- elapsed offset after War begins.
        bossWarRemainMinutes = 76,
        -- The Boss normally dies within roughly one minute after spawning.  The
        -- display therefore uses a short Boss-active band down to 1h15m, then
        -- falls back to the ordinary War remainder without "进行中".
        bossActiveUntilWarRemainMinutes = 75,
        bossLabel = "Boss",
    },
}
