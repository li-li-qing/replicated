-- Replicated Suite · 副本浏览身份注册
-- 作者：Replicated
-- QQ群：1104129461
-- ID 命名空间必须分开：databaseZoneId 是 ArcheRage 数据库 Map Zone ID，runtimeInstanceId 是 X2BattleField 的运行时副本类型 ID。
-- 二者不能互换。下列 RU 数据库地区 ID 已核实；runtimeInstanceId 在客户端 API 提供并验证前保持 nil。QuestService 运行时发现仍按需使用本地化 matchNames 别名。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
if S.GameDataRegistry == nil then return end

S.GameIds = S.GameIds or {}
local Registry = S.GameDataRegistry
local SOURCE = "ArcheRage RU map database"
local VERIFIED_AT = "2026-08-27"

local I = {
    ByDatabaseZoneId = {},
    ByKey = {},
    RuntimeObserved = {},
}
S.GameIds.Instance = I

local function RegisterInstanceZone(key, databaseZoneId, nameEn, options)
    options = type(options) == "table" and options or {}
    databaseZoneId = tonumber(databaseZoneId)
    if databaseZoneId == nil then return nil end
    databaseZoneId = math.floor(databaseZoneId)

    local row = {
        key = tostring(key),
        nameEn = tostring(nameEn or key),
        databaseZoneId = databaseZoneId,
        databaseZoneStatus = "database_verified",
        runtimeInstanceId = nil,
        runtimeIdStatus = "pending_client_api_verification",
        maxEntry = tonumber(options.maxEntry),
        matchNames = options.matchNames or { tostring(nameEn or key) },
        source = SOURCE,
        confidence = "database_verified",
        verified = true,
        verifiedAt = VERIFIED_AT,
    }

    I[key] = row
    I.ByKey[key] = row
    I.ByDatabaseZoneId[databaseZoneId] = row

    Registry:Register("instance_zone", "INSTANCE_ZONE_" .. tostring(key):upper(), databaseZoneId, {
        name = row.nameEn,
        family = "INSTANCE_DATABASE_ZONE",
        tags = { "INSTANCE", "DATABASE_ZONE", "RUNTIME_ID_PENDING" },
        source = SOURCE,
        confidence = "database_verified",
        verified = true,
        verifiedAt = VERIFIED_AT,
        notes = "databaseZoneId namespace only; do not use as X2BattleField runtime instance type",
    })
    return row
end

-- QuestService 使用的运行时发现团本；关联独立数据库地区身份时，必须保留原有别名和最大进入次数规则。
RegisterInstanceZone("redDragon", 121, "Red Dragon's Keep", {
    maxEntry = 1,
    matchNames = {
        "红龙巢穴", "红龙",
        "Red Dragon's Keep", "Red Dragon's Lair", "Red Dragon",
        "Логово Красного Дракона", "Логово красного дракона",
    },
})

RegisterInstanceZone("kadum", 132, "Kadum", {
    maxEntry = 1,
    matchNames = {
        "血之使者卡杜姆", "卡杜姆",
        "Kadum",
        "Кадум",
    },
})

-- 额外核实的数据库 Map Zone 身份仅提供静态身份基础；这些记录不会开启运行时完成判定。
RegisterInstanceZone("mistmerrow", 78, "Mistmerrow")
RegisterInstanceZone("mistsong", 89, "Mistsong Summit")
RegisterInstanceZone("ipnysh", 105, "Ipnysh Sanctuary")
RegisterInstanceZone("fallHiramCity", 122, "The Fall of Hiram City")
RegisterInstanceZone("noryette", 125, "Noryette Challenge")
RegisterInstanceZone("hereafter", 130, "Hereafter Rebellion")
RegisterInstanceZone("gardenOfGods", 133, "Garden of the Gods")

-- 经典副本的数据库 Map Zone 身份已按当前 ArcheRage 地图页面核实。这里不设置 runtimeInstanceId；X2BattleField entry.type 命名空间仍需实机验证。
RegisterInstanceZone("burntCastleArmory", 45, "Burnt Castle Armory")
RegisterInstanceZone("greaterBurntCastleArmory", 84, "Greater Burnt Castle Armory")
RegisterInstanceZone("hadirFarm", 46, "Hadir Farm")
RegisterInstanceZone("greaterHadirFarm", 83, "Greater Hadir Farm")
RegisterInstanceZone("palaceCellar", 47, "Palace Cellar")
RegisterInstanceZone("greaterPalaceCellar", 86, "Greater Palace Cellar")
RegisterInstanceZone("kroloalCradle", 52, "Kroloal Cradle")
RegisterInstanceZone("greaterKroloalCradle", 88, "Greater Kroloal Cradle")
RegisterInstanceZone("greaterSharpwindMines", 87, "Greater Sharpwind Mines")
RegisterInstanceZone("greaterHowlingAbyss", 58, "Greater Howling Abyss")

-- entry.type 只作会话观察，不能直接写入静态 runtimeInstanceId；它与数据库地区 ID 属不同命名空间。
function I:ObserveRuntimeCandidate(key, runtimeInstanceId, runtimeName)
    local row = self.ByKey[tostring(key or "")]
    runtimeInstanceId = tonumber(runtimeInstanceId)
    if row == nil or runtimeInstanceId == nil then return false end
    runtimeInstanceId = math.floor(runtimeInstanceId)
    runtimeName = tostring(runtimeName or "")

    local observed = self.RuntimeObserved[row.key]
    if observed == nil then
        observed = {
            key = row.key,
            runtimeInstanceId = nil,
            runtimeName = "",
            candidates = {},
            observationCount = 0,
            distinctCandidateCount = 0,
            source = "X2BattleField live client observation",
            status = "observed_pending_static_verification",
        }
        self.RuntimeObserved[row.key] = observed
    end

    local candidate = observed.candidates[runtimeInstanceId]
    if candidate == nil then
        candidate = { runtimeInstanceId=runtimeInstanceId, count=0, lastRuntimeName="" }
        observed.candidates[runtimeInstanceId] = candidate
        observed.distinctCandidateCount = observed.distinctCandidateCount + 1
    end
    candidate.count = candidate.count + 1
    candidate.lastRuntimeName = runtimeName
    observed.observationCount = observed.observationCount + 1

    if observed.distinctCandidateCount == 1 then
        observed.runtimeInstanceId = runtimeInstanceId
        observed.runtimeName = runtimeName
        observed.status = "observed_pending_static_verification"
    else
        -- 客户端观察存在歧义时，不能把某个候选当成权威结论；所有证据保留在本次会话供诊断使用。
        observed.runtimeInstanceId = nil
        observed.runtimeName = ""
        observed.status = "observed_conflict_pending_static_verification"
    end
    return true
end

function I:GetRuntimeCandidate(key)
    return self.RuntimeObserved[tostring(key or "")]
end

function I:GetByDatabaseZoneId(databaseZoneId)
    return self.ByDatabaseZoneId[tonumber(databaseZoneId)]
end

-- 仅供诊断快照，不用于逐帧副本查询。
function I:Describe()
    local databaseVerified, runtimeVerified, runtimePending, runtimeObserved, runtimeObservedConflicts = 0, 0, 0, 0, 0
    for _, row in pairs(self.ByDatabaseZoneId or {}) do
        if row.databaseZoneStatus == "database_verified" then databaseVerified = databaseVerified + 1 end
        if tonumber(row.runtimeInstanceId) ~= nil then
            runtimeVerified = runtimeVerified + 1
        else
            runtimePending = runtimePending + 1
        end
    end
    for _, observed in pairs(self.RuntimeObserved or {}) do
        runtimeObserved = runtimeObserved + 1
        if observed.status == "observed_conflict_pending_static_verification" then
            runtimeObservedConflicts = runtimeObservedConflicts + 1
        end
    end
    return {
        databaseZones = databaseVerified,
        databaseVerified = databaseVerified,
        runtimeVerified = runtimeVerified,
        runtimePending = runtimePending,
        runtimeObserved = runtimeObserved,
        runtimeObservedConflicts = runtimeObservedConflicts,
        verifiedAt = VERIFIED_AT,
    }
end
