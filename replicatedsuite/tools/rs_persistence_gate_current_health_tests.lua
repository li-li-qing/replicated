-- 中文维护注释（persistence-current-health-1）：Foundation 的发布阻断必须描述“当前仍失败”状态，
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

print(string.format("PERSISTENCE_GATE_CURRENT_HEALTH_RESULT passed=%d failed=%d", passed, failed))
if failed > 0 then error("persistence gate current-health failures: " .. failed) end
