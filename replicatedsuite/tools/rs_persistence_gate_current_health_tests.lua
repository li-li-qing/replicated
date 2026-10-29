-- Replicated Suite · 持久化门禁当前健康测试
-- 作者：Replicated
-- QQ群：1104129461
-- Foundation 的发布阻断必须描述“当前仍失败”状态，
-- 不能把已经恢复的 durable/readback 历史 incident 永久当 blocker。历史计数仍由 incidents warning
-- 保留，绝不在这里清零。此测试不触发 SaveData，只验证 Gate 对 Persistence 只读摘要的解释。
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; print("PASS persistence-gate " .. name)
    else failed = failed + 1; print("FAIL persistence-gate " .. name .. ": " .. tostring(err)) end
end

ReplicatedSuite = {
    BootError = nil,
    SafeTraceback = function(e) return tostring(e) end,
    Persistence = { FingerprintEnvelopeIntegrity = function() return "fixture" end },
}
dofile("core/rs_foundation_gate.lua")
local G = assert(ReplicatedSuite.FoundationGate)

local function Snapshot(overrides)
    local out = {
        reliabilityContractVersion = 8,
        integrityContractVersion = 4,
        historicalCanonicalRecoveryContractVersion = 3,
        knownLegacyCanonicalRecoveryContractVersion = 1,
        envelopeIntegrityContractVersion = 1,
        scopeBindingContractVersion = 1,
        currentFailures = 0,
        currentFailureSummaryContractVersion = 1,
        stats = {
            envelopeIntegrityStampedSaves = 40,
            envelopeIntegrityLoadChecks = 23,
            envelopeIntegrityLoadFailures = 0,
            decodedLoadRejects = 0,
            durableVerifyAttempts = 5,
            durableVerifyFailures = 4,
            scopeBindingMismatches = 0,
            scopeRebinds = 0,
            integrityLoadFailures = 2,
            encodedLoadRejects = 0,
        },
    }
    for k, v in pairs(overrides or {}) do out[k] = v end
    return out
end

Test("recovered durable incidents do not remain a blocker", function()
    assert(type(G.EvaluatePersistenceReliabilityV6) == "function", "current-health evaluator missing")
    local ok, detail = G:EvaluatePersistenceReliabilityV6(Snapshot())
    assert(ok == true, detail)
    assert(detail:find("currentFail=0", 1, true), detail)
    assert(detail:find("durableFail=4", 1, true), "historical evidence disappeared")
end)

Test("an active failed store still blocks v6", function()
    local snap = Snapshot({ currentFailures = 1 })
    local ok, detail = G:EvaluatePersistenceReliabilityV6(snap)
    assert(ok == false, "active failure was ignored")
    assert(detail:find("currentFail=1", 1, true), detail)
end)

Test("envelope and scope failures still block independently of current store count", function()
    local snap = Snapshot()
    snap.stats.envelopeIntegrityLoadFailures = 1
    local ok = G:EvaluatePersistenceReliabilityV6(snap)
    assert(ok == false, "envelope failure was weakened")
    snap = Snapshot(); snap.stats.scopeBindingMismatches = 1
    ok = G:EvaluatePersistenceReliabilityV6(snap)
    assert(ok == false, "scope mismatch was weakened")
end)

local function RunCheck(snapshot,id)
    ReplicatedSuite.Persistence.Describe=function()return snapshot end
    local report=G:Run({skipSequences=true})
    for _,row in ipairs(report.checks)do if row.id==id then return row end end
    error('missing check: '..id)
end
Test("recovered integrity incidents are warnings instead of current blockers",function()
    local snap=Snapshot()
    local row=RunCheck(snap,'persistence_reliability_v4')
    assert(row.ok,row.detail)
    assert(row.detail:find('integrityFail=2',1,true),'historical integrity evidence disappeared')
    local incident=RunCheck(snap,'persistence_reliability_incidents')
    assert(not incident.ok and incident.severity=='warning','recovered incidents were erased')
    assert(snap.stats.integrityLoadFailures==2,'gate cleared historical failures')
end)
Test("active and unknown integrity health still block v4",function()
    assert(not RunCheck(Snapshot({currentFailures=1}),'persistence_reliability_v4').ok)
    local snap=Snapshot();snap.currentFailures=nil
    assert(not RunCheck(snap,'persistence_reliability_v4').ok,'unknown current health was accepted')
    snap=Snapshot();snap.currentFailureSummaryContractVersion=nil
    assert(not RunCheck(snap,'persistence_reliability_v4').ok,'missing health contract was accepted')
end)

print(string.format("PERSISTENCE_GATE_CURRENT_HEALTH_RESULT passed=%d failed=%d", passed, failed))
if failed > 0 then error("persistence gate current-health failures: " .. failed) end
