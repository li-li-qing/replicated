-- Replicated Suite · 战斗统计事件热路回归
-- 真实 Domain，仅替代关系/设置事实；不访问 Native、玩家存档或运行时 TOC。
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; print('PASS dps-ingest ' .. name)
    else failed = failed + 1; print('FAIL dps-ingest ' .. name .. ': ' .. tostring(err)) end
end
local function Same(a, b, seen)
    assert(type(a) == type(b), 'type differs')
    if type(a) ~= 'table' then assert(a == b, tostring(a) .. ' ~= ' .. tostring(b)); return end
    seen = seen or {}; if seen[a] == b then return end; seen[a] = b
    for k, v in pairs(a) do assert(b[k] ~= nil, 'missing ' .. tostring(k)); Same(v, b[k], seen) end
    for k in pairs(b) do assert(a[k] ~= nil, 'extra ' .. tostring(k)) end
end
local function Boot(path)
    local h = { ms = 10000, sequence = 0, scope = 'all', reads = 0 }
    local S = { Generation = 1, Services = {}, Features = {}, Utils = {}, NowMs = function() return h.ms end }
    ReplicatedSuite = S; dofile('core/rs_reuse.lua')
    h.S = S
    h.F = { enabled = true, IsBossName = function(_, name) return name == 'Boss' end,
        GetSettings = function() return { mode = 'PVP', side = 'friendly', metric = 'damage', displayRows = 150, alwaysShowSelf = true } end }
    S.Features.DPS = h.F
    local R = { relations = { Me = 'SELF', Friend = 'FRIENDLY', Enemy = 'OPPONENT', Boss = 'OPPONENT' }, units = {} }
    function R:GetRelationAt(name) h.reads = h.reads + 1; return self.relations[name] or 'UNKNOWN' end
    function R:GetUnit(name) return self.units[name] end
    function R:ApplyKind(name, kind)
        local old = self.units[name]; local changed = not old or old.kind ~= kind
        self.units[name] = old or {}; self.units[name].kind = kind; return true, nil, changed
    end
    function R:RecordCombatFact(fact)
        return true, { sourceRelation = self:GetRelationAt(fact.sourceName), targetRelation = self:GetRelationAt(fact.targetName) }
    end
    S.Services.CombatRelationV3 = R; h.R = R
    S.Services.CombatAnalyticsV3 = { GetCollectionScope = function() return h.scope end,
        IsSelfActor = function(_, name) return name == 'Me' end }
    dofile(path or 'features/combat/dps/rs_dps_domain.lua'); h.D = h.F.Domain
    function h:Fact(source, target, amount, category, sk, tk, ability)
        self.ms = self.ms + 10; self.sequence = self.sequence + 1
        return self.D:OnCombatFact({ sourceName = source, targetName = target, amount = amount or 100,
            category = category or 'damage', kind = category == 'heal' and 'heal' or 'spell_damage',
            sourceKind = sk, targetKind = tk, abilityName = 'Skill' .. tostring(ability or 7),
            rawAbilityId = ability or 7, receivedAt = self.ms, sequence = self.sequence })
    end
    return h
end
local function Snapshot(h)
    local out = { health = h.D:GetHealth(), boards = {}, details = {} }
    for _, mode in ipairs({ 'PVP', 'PVE' }) do
        for _, metric in ipairs({ 'damage', 'heal', 'taken' }) do
            out.boards[mode .. metric] = h.D:GetProjection({ mode = mode, metric = metric, displayRows = 150, includeZero = true })
            for _, name in ipairs({ 'me', 'friend', 'enemy', 'boss', 'unknown' }) do
                local key = mode .. metric .. name
                out.details[key] = h.D:GetActorDetail({ mode = mode, metric = metric, actorKey = 'name:' .. name, limit = 100 })
            end
        end
    end
    return out
end
local function Allocate(fn)
    collectgarbage('collect'); collectgarbage('stop')
    local before = collectgarbage('count'); local ok, err = pcall(fn)
    local used = collectgarbage('count') - before; collectgarbage('restart')
    assert(ok, err); return used
end

Test('resolved repeated PVP events avoid unused rollback allocation', function()
    local h = Boot(); for _ = 1, 30 do h:Fact('Me', 'Enemy', 100, 'damage', 'PLAYER', 'PLAYER') end
    local used = Allocate(function() for _ = 1, 1000 do assert(h:Fact('Me', 'Enemy', 100, 'damage', 'PLAYER', 'PLAYER')) end end)
    print(string.format('DPS_INGEST_BENCH resolved-1000 allocatedKB=%.2f', used))
    assert(used < 2600, 'resolved event retains unnecessary undo allocations: ' .. tostring(used))
    assert(h.D.pendingCount == 0 and h.D.events == 1030)
    local p = h.D:GetProjection({ mode = 'PVP', metric = 'damage' })
    assert(p.totals.damage == 103000 and p.totals.taken == 0)
end)
Test('resolved shared healing avoids unused rollback allocation', function()
    local h = Boot(); for _ = 1, 30 do h:Fact('Friend', 'Me', 30, 'heal', 'PLAYER', 'PLAYER') end
    local used = Allocate(function() for _ = 1, 1000 do assert(h:Fact('Friend', 'Me', 30, 'heal', 'PLAYER', 'PLAYER')) end end)
    print(string.format('DPS_INGEST_BENCH healing-1000 allocatedKB=%.2f', used))
    assert(used < 2400, 'resolved heal retains unnecessary undo allocations: ' .. tostring(used))
    assert(h.D.pendingCount == 0 and h.D.healing.friendly.heal == 30900)
end)
Test('unknown event retains undo and late classification moves each total once', function()
    local h = Boot(); assert(h:Fact('Unknown', 'Enemy', 77))
    assert(h.D.pendingCount == 1)
    local row = h.D.pendingRows[next(h.D.pendingRows)]
    assert(type(row.appliedContributions) == 'table' and #row.appliedContributions == 2)
    h.R.relations.Unknown = 'FRIENDLY'; h.R.units.Unknown = { kind = 'PLAYER' }; h.R.units.Enemy = { kind = 'PLAYER' }
    assert(h.D:ReplayPending('late')); assert(h.D.pendingCount == 0)
    local p = h.D:GetProjection({ mode = 'PVP' }); assert(p.totals.damage == 77 and p.unresolved.totals.damage == 0)
    assert(h.D:ReplayPending('repeat')); assert(h.D:GetProjection({ mode = 'PVP' }).totals.damage == 77)
end)
Test('provisional kind and unknown side both keep correction references', function()
    local h = Boot(); assert(h:Fact('Me', 'Enemy', 50)); assert(h.D.pendingCount == 1)
    h.R.units.Me = { kind = 'PLAYER' }; h.R.units.Enemy = { kind = 'NPC' }
    h.D:ReplayPending('kind'); assert(h.D.pendingCount == 0)
    assert(h.D:GetProjection({ mode = 'PVE' }).totals.damage == 50)
    assert(h.D:GetProjection({ mode = 'PVP' }).totals.damage == 0)
    h:Fact('Unknown', 'Enemy', 25, 'damage', 'PLAYER', 'NPC'); assert(h.D.pendingCount == 1)
    h.R.relations.Unknown = 'FRIENDLY'; h.D:ReplayPending('side'); assert(h.D.pendingCount == 0)
    assert(h.D:GetProjection({ mode = 'PVE' }).totals.damage == 75)
end)
Test('pending healing transfers source bucket without losing details', function()
    local h = Boot(); h:Fact('Unknown', 'Stranger', 29, 'heal', 'PLAYER', 'PLAYER'); assert(h.D.pendingCount == 1)
    h.R.relations.Unknown = 'FRIENDLY'; h.D:ReplayPending('healer'); assert(h.D.pendingCount == 0)
    assert(h.D.healing.unknown.heal == 0 and h.D.healing.friendly.heal == 29)
    local d = h.D:GetActorDetail({ mode = 'PVP', metric = 'heal', actorKey = 'name:unknown' })
    assert(d.abilities[1].amount == 29 and d.abilities[1].events == 1)
end)
Test('self scope applies only self actor but retains complete accumulation', function()
    local h = Boot(); h.scope = 'self'
    h:Fact('Me', 'Enemy', 31, 'damage', 'PLAYER', 'PLAYER'); h:Fact('Friend', 'Me', 19, 'heal', 'PLAYER', 'PLAYER')
    assert(h.D:GetProjection({ mode = 'PVP', metric = 'damage' }).totals.damage == 31)
    assert(h.D.modes.PVP.enemy.taken == 0 and h.D.healing.friendly.heal == 0)
end)
Test('returned snapshots and borrowed event remain isolated across ingestion', function()
    local h = Boot(); h:Fact('Me', 'Enemy', 10, 'damage', 'PLAYER', 'PLAYER')
    local first = h.D:GetProjection({ mode = 'PVP' }); first.rows[1].damage = 999
    h:Fact('Me', 'Enemy', 20, 'damage', 'PLAYER', 'PLAYER')
    assert(h.D:GetProjection({ mode = 'PVP' }).rows[1].damage == 30 and first.rows[1].damage == 999)
    local fact = { sourceName = 'Me', targetName = 'Enemy', amount = 7, category = 'damage', kind = 'melee_damage', receivedAt = h.ms }
    local original = {}; for k, v in pairs(fact) do original[k] = v end
    assert(h.D:OnCombatFact(fact)); Same(original, fact)
end)
Test('reset and clear keep accumulated session data and release pending bookkeeping', function()
    local h = Boot(); h:Fact('Me', 'Enemy', 31, 'damage', 'PLAYER', 'PLAYER'); h:Fact('Unknown', 'Enemy', 9)
    assert(h.D.pendingCount > 0); h.D:ResetTransient('stop'); assert(h.D.pendingCount == 0)
    assert(h.D:GetProjection({ mode = 'PVP' }).totals.damage == 31)
    h.D:ClearStats('clear'); assert(h.D:GetProjection({ mode = 'PVP' }).totals.damage == 0 and h.D.events == 0)
end)
Test('direct Apply methods still retain undo for a later replacement', function()
    local h = Boot()
    local row = { sourceName = 'Me', targetName = 'Enemy', category = 'damage', amount = 41, at = h.ms,
        sourceRel = 'SELF', targetRel = 'OPPONENT', sourceKind = 'PLAYER', targetKind = 'PLAYER', abilityName = 'Direct', abilityId = 2 }
    assert(h.D:ApplyResolved(row, 'PVP', 'direct', false))
    assert(type(row.appliedContributions) == 'table' and #row.appliedContributions == 2)
    row.targetKind = 'NPC'; assert(h.D:ApplyResolved(row, 'PVE', 'replacement', false))
    assert(h.D.modes.PVP.friendly.damage == 0 and h.D.modes.PVE.friendly.damage == 41)
    row.category = 'heal'; assert(h.D:ApplySharedHeal(row, 'healing'))
    assert(type(row.appliedContributions) == 'table' and #row.appliedContributions == 1)
    assert(h.D.modes.PVE.friendly.damage == 0 and h.D.healing.friendly.heal == 41)
end)
Test('unknown-side pending event eviction remains bounded without lost totals', function()
    local h = Boot()
    for i = 1, 700 do h:Fact('Unknown' .. tostring(i), 'Enemy', 1, 'damage', 'PLAYER', 'PLAYER') end
    assert(h.D.pendingCount == h.D.pendingMax and h.D.pendingEvicted == 188)
    assert(h.D:GetProjection({ mode = 'PVP', side = 'unknown' }).totals.damage == 700)
    h.D:ResetTransient('release'); assert(h.D.pendingCount == 0)
    assert(h.D:GetProjection({ mode = 'PVP', side = 'unknown' }).totals.damage == 700)
end)

if arg[1] then
    Test('pre-change differential 200-player mixed events replay overflow and settings', function()
        local a, b = Boot(arg[1]), Boot()
        local function Feed(h)
            for i = 1, 1400 do
                local name = 'Actor' .. tostring(i % 200)
                h.R.relations[name] = i % 3 == 0 and 'OPPONENT' or 'FRIENDLY'
                h:Fact(i % 5 == 0 and 'Unknown' or (i % 2 == 0 and 'Me' or name), i % 7 == 0 and 'Boss' or 'Enemy',
                    i % 99 + 1, i % 4 == 0 and 'heal' or 'damage', i % 13 == 0 and nil or 'PLAYER',
                    i % 7 == 0 and 'NPC' or 'PLAYER', i % 170 + 1)
            end
        end
        Feed(a); Feed(b); Same(Snapshot(a), Snapshot(b))
        for i = 1, 350 do
            local name = 'Counterpart' .. tostring(i)
            a.R.relations[name] = 'OPPONENT'; b.R.relations[name] = 'OPPONENT'
            a:Fact('Me', name, 1, 'damage', 'PLAYER', 'PLAYER', i)
            b:Fact('Me', name, 1, 'damage', 'PLAYER', 'PLAYER', i)
        end
        Same(Snapshot(a), Snapshot(b))
        a.R.relations.Unknown = 'FRIENDLY'; b.R.relations.Unknown = 'FRIENDLY'
        a.D:ReplayPending('late'); b.D:ReplayPending('late'); Same(Snapshot(a), Snapshot(b))
        a.scope = 'self'; b.scope = 'self'; Feed(a); Feed(b); Same(Snapshot(a), Snapshot(b))
        a.D:ResetTransient('stop'); b.D:ResetTransient('stop'); Same(Snapshot(a), Snapshot(b))
    end)
end
print(string.format('DPS INGEST RESULT %d passed / %d failed', passed, failed))
if failed > 0 then os.exit(1) end
