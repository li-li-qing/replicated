-- 战斗健康投影性能回归：真实名单/关系服务，仅替换宿主，不读取玩家存档。
-- 离线套件，不进入 TOC；人数诊断不能为了计数复制整份团队成员。
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; print('PASS combat-health ' .. name)
    else failed = failed + 1; print('FAIL combat-health ' .. name .. ': ' .. tostring(err)) end
end
local function Boot()
    local h = { copies = 0, snapshots = 0, reads = 0 }
    local S = { Services = {}, Utils = {}, NowMs = function() return 1000 end }
    ReplicatedSuite = S
    local function Copy(value)
        if type(value) ~= 'table' then return value end
        h.copies = h.copies + 1
        local out = {}; for key, item in pairs(value) do out[key] = Copy(item) end
        return out
    end
    S.Utils.DeepCopy = Copy
    dofile('services/rs_team_roster_v3.lua')
    dofile(arg[1] or 'services/rs_combat_relation_v3.lua')
    h.S, h.T, h.R = S, S.Services.TeamRosterV3, S.Services.CombatRelationV3
    local original = h.T.GetSnapshot
    function h.T:GetSnapshot()
        h.snapshots = h.snapshots + 1
        return original(self)
    end
    function h:Seed(count)
        self.T.ordered = {}
        for index = 1, count do
            self.T.ordered[index] = {name = 'Member' .. index, unitToken = 'team' .. index,
                teamIndex = 1, memberIndex = index, roles = { healer = index % 2 == 0 }}
        end
    end
    return h
end

Test('populated roster health never copies member rows', function()
    local h = Boot(); h:Seed(200)
    for _ = 1, 20 do assert(h.R:GetHealth().rosterMembers == 200) end
    assert(h.snapshots == 0 and h.copies == 0, 'count-only read copied roster: ' .. h.copies)
end)
Test('roster changes and empty zero are read immediately', function()
    local h = Boot(); h:Seed(100); assert(h.R:GetHealth().rosterMembers == 100)
    h:Seed(2); assert(h.R:GetHealth().rosterMembers == 2)
    h:Seed(0); assert(h.R:GetHealth().rosterMembers == 0)
    assert(h.snapshots == 0, 'valid zero fell through to snapshot')
end)
Test('health result is detached and relation counters stay current', function()
    local h = Boot(); h:Seed(3)
    h.R.units = {a = {manual = true, relation = 'UNKNOWN'}, b = {relation = 'OPPONENT'}}
    h.R.evidenceApplied = 8
    local first = h.R:GetHealth(); first.rosterMembers = 999; first.units = 999
    local next = h.R:GetHealth()
    assert(next.rosterMembers == 3 and next.units == 2 and next.manual == 1 and next.unknown == 1)
    assert(next.evidenceApplied == 8 and h.R.rosterHeld == false)
    h.R.units.b = nil; h.R.evidenceApplied = 9
    next = h.R:GetHealth(); assert(next.units == 1 and next.evidenceApplied == 9)
end)
Test('old snapshot-only providers remain supported', function()
    local h = Boot()
    h.S.Services.TeamRosterV3 = {GetSnapshot = function() h.snapshots = h.snapshots + 1; return {count = '7'} end}
    assert(h.R:GetHealth().rosterMembers == 7 and h.snapshots == 1)
end)
Test('missing lightweight count falls back once', function()
    local h = Boot()
    h.S.Services.TeamRosterV3 = {
        GetHealth = function() h.reads = h.reads + 1; return {members = 'unavailable'} end,
        GetSnapshot = function() h.snapshots = h.snapshots + 1; return {count = 4} end,
    }
    assert(h.R:GetHealth().rosterMembers == 4 and h.reads == 1 and h.snapshots == 1)
    h.S.Services.TeamRosterV3.GetHealth = function() return nil end
    assert(h.R:GetHealth().rosterMembers == 4 and h.snapshots == 2)
end)
Test('missing roster and unavailable legacy count stay zero', function()
    local h = Boot(); h.S.Services.TeamRosterV3 = nil
    assert(h.R:GetHealth().rosterMembers == 0)
    h.S.Services.TeamRosterV3 = {GetSnapshot = function() return nil end}
    assert(h.R:GetHealth().rosterMembers == 0)
    h.S.Services.TeamRosterV3 = {GetHealth = function() return {members = '0'} end}
    assert(h.R:GetHealth().rosterMembers == 0)
end)
Test('health reads do not start roster or touch Native', function()
    local h = Boot()
    h.S.Services.TeamRosterV3 = {
        GetHealth = function() h.reads = h.reads + 1; return {members = 9} end,
        AcquireConsumer = function() error('unexpected acquire') end,
        Refresh = function() error('unexpected refresh') end,
        GetSnapshot = function() error('unexpected full snapshot') end,
    }
    assert(h.R:GetHealth().rosterMembers == 9 and h.reads == 1)
end)
print('COMBAT_HEALTH_PERFORMANCE_RESULT passed=' .. passed .. ' failed=' .. failed)
if failed > 0 then os.exit(1) end
