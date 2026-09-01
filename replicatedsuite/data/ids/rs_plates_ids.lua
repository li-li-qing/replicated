------------------------------------------------------------------------
-- Replicated Suite - Plates semantic ID relations
--
-- These relations preserve the existing Plates migration source without
-- promoting compatibility IDs to database-verified facts.  The Registry owns
-- the reusable ID sets; Plates still owns runtime policy and live API reads.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Registry = S.GameDataRegistry
if type(Registry) ~= "table" or type(Registry.RegisterSet) ~= "function" then return end

S.GameIds = S.GameIds or {}
local P = {
    version = 1,
    source = "Replicated Plates migration catalog / RU curated compatibility data",
    confidence = "curated",
    verified = false,
}
S.GameIds.Plates = P

local function RegisterSet(kind, key, ids, name, notes, tags)
    local set = Registry:RegisterSet(kind, key, ids, {
        name = name,
        source = P.source,
        confidence = P.confidence,
        verified = P.verified,
        notes = notes,
        tags = tags,
    })
    if type(set) == "table" and type(set.ids) == "table" then return set.ids end
    return {}
end

-- Static records are discovery seeds only. Runtime displays countdowns from
-- the live X2Skill APIs; these fields are labels/probe hints, not timers.
P.ImportantCooldownEntries = {
    { id=24113, kind="skill", group="glider", priority=20, expectedSec=10, label="Burning Tail Feather / 燃烧尾羽" },
    { id=23040, kind="skill", group="glider", priority=21, expectedSec=30, label="Glider Nitro / 滑翔翼推进" },
    { id=31633, kind="skill", group="glider", priority=22, expectedSec=60, label="Focused Glide / 集中滑翔" },
    { id=32735, kind="skill", group="glider", priority=23, expectedSec=60, label="Instant Acceleration / 瞬间加速" },
    { id=34004, kind="skill", group="glider", priority=24, expectedSec=60, label="Instant Acceleration / 瞬间加速" },
    { id=23270, kind="skill", group="glider", priority=25, expectedSec=60, label="Dragonfire / 龙火" },
    { id=37171, kind="skill", group="glider", priority=26, expectedSec=30, label="Fae Wing Leap / 翼跃" },
    { id=48548, kind="skill", group="glider", priority=27, expectedSec=30, label="Takeoff / 起飞" },
    { id=8000072, kind="skill", group="glider", priority=28, expectedSec=30, label="Sloth Glider / 树懒滑翔" },
    { id=8001355, kind="skill", group="glider", priority=29, expectedSec=60, label="Divebomb / 俯冲撞击" },
    { id=9000060, kind="skill", group="glider", priority=30, expectedSec=10, label="Step Back / 后撤" },
    { id=9000069, kind="skill", group="glider", priority=31, expectedSec=60, label="Stealth / 隐形飞行" },
    { id=9000071, kind="skill", group="glider", priority=32, expectedSec=60, label="Stealth / 隐形飞行" },
    { id=29044, kind="skill", group="glider", priority=33, expectedSec=10, label="Shoot Guided Needle / 制导针" },
    { id=21211, kind="skill", group="glider", priority=34, expectedSec=1, label="Open Star Wings / 星之翼展开" },
    { id=8000577, kind="skill", group="glider", priority=35, expectedSec=10, label="Flaming Pinion / 火焰尾羽" },
    { id=8000578, kind="skill", group="glider", priority=36, expectedSec=10, label="Enhanced Flaming Pinion / 强化火焰尾羽" },
    { id=46050, kind="mate", group="groa", priority=100, expectedSec=90, label="Powerstone Pumpkin - Trick / 南瓜格罗亚" },
    { id=40935, kind="mate", group="groa", priority=101, expectedSec=90, label="Marvelous Mab - Abracadabra / 3秒取消锁定" },
    { id=43706, kind="mate", group="groa", priority=102, expectedSec=90, label="Black Fledgling Phoenix - Mana Shield" },
    { id=49382, kind="mate", group="groa", priority=103, expectedSec=90, label="Rammidri Protection / 5秒首伤免疫" },
    { id=46608, kind="mate", group="groa", priority=104, expectedSec=90, label="Snowflake - Freeze! / 3秒无敌" },
    { id=42006, kind="mate", group="groa", priority=105, expectedSec=90, label="Ellam A / 2.5秒攻击与治疗+20%" },
    { id=42007, kind="mate", group="groa", priority=106, expectedSec=90, label="Ellam B / 2.5秒承伤-50%" },
    { id=42008, kind="mate", group="groa", priority=107, expectedSec=90, label="Ellam C / 2.5秒全Debuff免疫" },
    { id=47796, kind="mate", group="groa", priority=108, expectedSec=90, label="Crowd - Power of Crowd / 5秒穿透+10%" },
    { id=36906, kind="mate", group="groa", priority=109, expectedSec=90, label="Bloomfang - Truly Cathletic / 3秒承伤-30%" },
    { id=8001305, kind="mate", group="groa", priority=110, expectedSec=90, label="Bloomfang - Truly Cathletic / 自定义版本" },
    { id=45328, kind="mate", group="groa", priority=111, expectedSec=90, label="Wisp - Stealth / 5秒隐身" },
    { id=47585, kind="mate", group="groa", priority=112, expectedSec=90, label="Lotty - Get'em! / 5秒攻速施法强化" },
    { id=51027, kind="mate", group="groa", priority=113, expectedSec=90, label="Molang, Help! / 5秒双防+5000" },
}
local cooldownIds = {}
for _, entry in ipairs(P.ImportantCooldownEntries) do cooldownIds[#cooldownIds + 1] = entry.id end
P.ImportantCooldownIds = RegisterSet("skill", "PLATES_IMPORTANT_COOLDOWNS", cooldownIds,
    "Plates 重要冷却探测集合", "Probe hints only; visible countdowns must come from live RU cooldown getters.",
    { "PLATES", "COOLDOWN", "DISCOVERY_ONLY" })

P.MagicCircleBuffIds = RegisterSet("buff", "PLATES_MAGIC_CIRCLE_BUFFS", { 19037, 25850, 25851 },
    "Plates 魔法阵状态集合", "Existing curated candidates; exact RU buff semantics remain a runtime verification item.",
    { "PLATES", "MAGIC_CIRCLE", "RUNTIME_VERIFY_REQUIRED" })

P.TargetArmorPriority = { 16551, 16552, 16553, 714, 716, 740 }
P.TargetArmorByBuff = {
    [16551] = "布甲", [16552] = "皮甲", [16553] = "板甲",
    [714] = "布甲", [716] = "皮甲", [740] = "板甲",
}
P.TargetArmorEffectIds = RegisterSet("buff", "TARGET_ARMOR_SET_EFFECTS", P.TargetArmorPriority,
    "目标护甲状态集合", "Current complete-set IDs plus legacy compatibility IDs; do not infer unknown armor from class or gear score.",
    { "PLATES", "TARGET_LOADOUT", "RUNTIME_COMPATIBILITY" })

P.TargetWeaponPriority = { 16559, 8226, 16558, 16557, 4899, 8227 }
P.TargetWeaponStyleByBuff = {
    [16557] = "双手", [16558] = "双持", [16559] = "盾牌",
    [4899] = "双持", [8226] = "盾牌", [8227] = "双手",
}
P.TargetWeaponEffectIds = RegisterSet("buff", "TARGET_WEAPON_STYLE_EFFECTS", P.TargetWeaponPriority,
    "目标武器状态集合", "Visible equip-state compatibility IDs only; return unknown when no whitelisted state is observed.",
    { "PLATES", "TARGET_LOADOUT", "RUNTIME_COMPATIBILITY" })

P.EffectTimerCorrections = {
    hidden = {
        ["22969"] = { subtractMs = 1440000, note = "Defiance hidden timer correction; source compatibility rule" },
    },
}
P.EffectTimerCorrectionIds = RegisterSet("buff", "EFFECT_TIMER_CORRECTIONS", { 22969 },
    "效果计时修正集合", "Compatibility correction only; the client-returned timer remains the input.",
    { "PLATES", "TIMER_CORRECTION", "RUNTIME_COMPATIBILITY" })

