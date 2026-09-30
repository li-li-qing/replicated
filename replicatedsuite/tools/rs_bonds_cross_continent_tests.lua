-- Developer-only regression: actual Bonds/Store/Demand/Event/Scheduler implementations.
-- Native APIs, clock and SaveData medium are controlled inputs, not client acceptance.
unpack = unpack or table.unpack
local total, passed = 0, 0
local function test(name, fn)
    total = total + 1
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; print('PASS '..name)
    else print('FAIL '..name..'\n'..tostring(err)) end
end
local function fresh(options)
    options = options or {}
    local h = dofile('tools/rs_gear_page_test_host.lua')({disk=options.disk})
    local S = h.S
    h.zone, h.day, h.boards, h.boardCalls = options.zone or 1, options.day or '2026-09-30', {}, 0
    UIParent = { GetServerTimeTable = function()
        local y,m,d = tostring(h.day):match('^(%d+)%-(%d+)%-(%d+)$')
        return {year=tonumber(y) or 0,month=tonumber(m) or 0,day=tonumber(d) or 0}
    end }
    X2Unit.GetCurrentZoneGroup = function() return h.zone end
    X2Resident = { GetResidentBoardContent=function(_,i)
        h.boardCalls=h.boardCalls+1; return h.Copy(h.boards[i] or {contents={}})
    end }
    X2Quest = {GetActiveQuestListCount=function()return 0 end,GetActiveQuestType=function()return nil end,
        IsCompleted=function()return false end,IsReadyForCompleteQuest=function()return false end}
    X2Bag = {Capacity=function()return 0 end,GetBagItemInfo=function()return nil end}
    dofile('core/rs_demand.lua')
    dofile('data/rs_data_registry.lua');dofile('data/ids/rs_item_ids.lua');dofile('data/ids/rs_quest_ids.lua')
    dofile('data/ids/rs_instance_ids.lua');dofile('data/rs_event_data.lua');dofile('data/rs_quest_data.lua');dofile('core/rs_constants.lua')
    dofile('services/rs_quest_progress_v3.lua')
    dofile('features/life/shared/rs_life_slice_factory.lua')
    dofile('features/life/bonds/rs_bonds_feature.lua')
    h.B=S.Features.Bonds;h.A=h.B.Authority
    h.initOk,h.initError=h.B:Initialize()
    if options.allowLoadFailure~=true then assert(h.initOk,h.initError) end
    assert(h.B:Enable())
    function h:Mainland(zone, faction)
        self.zone=zone;self.boards={}
        for i=1,4 do self.boards[i]={faction=faction,contents={({'Fabric 20','Leather 60','Lumber 100','Iron 20'})[i]}} end
    end
    function h:RunOne()
        local task=S.Scheduler.tasks.life_bonds_zone_refresh
        if not task then return false end
        self.ms=self.ms+(task.intervalMs or 750)
        task.callback()
        assert(S.LastEventError==nil,tostring(S.LastEventError and S.LastEventError.error))
        return true
    end
    function h:Drain(limit)
        for i=1,(limit or 12) do if not self:RunOne() then return i-1 end end
        assert(S.Scheduler.tasks.life_bonds_zone_refresh==nil,'unbounded location retry')
    end
    function h:Save()
        local ok,err=S.Persistence:SaveStore(self.B.storeId,{force=true,verifyAfterSave=true})
        assert(ok==true,tostring(err))
        return h.Copy(self.disk)
    end
    function h:Coverage(key) return self.B:GetProjection().dailySnapshotStatus[key] end
    return h
end
local function stringifyKeys(value)
    if type(value)~='table' then return value end
    local result={}
    for k,v in pairs(value) do result[type(k)=='number' and tostring(k) or k]=stringifyKeys(v) end
    return result
end

test('normal west + east survives actual SaveStore and fresh LoadStore',function()
    local h=fresh();h:Mainland(1,'Nuia');assert(h.A:Refresh('manual'))
    h:Mainland(4,'Haranya');assert(h.A:Refresh('manual'))
    local disk=h:Save();local r=fresh({disk=disk,zone=4});r.A:Refresh('presentation')
    assert(r:Coverage('west') and r:Coverage('east'),'normal multi-continent round trip lost rows')
end)
test('Native wrapped decimal string keys preserve all mainland boards',function()
    local h=fresh();h:Mainland(1,'Nuia')
    for _,b in pairs(h.boards) do b.contents=stringifyKeys(b.contents) end
    assert(h.A:Refresh('manual'),'string-index native contents were lost')
    assert(#h.B:GetProjection().rows==4,'string-index rows missing')
end)
test('Native bare string-key row map is accepted without metadata rows',function()
    local h=fresh();h.boards={[3]={['1']='Lumber 100',metadata='ignore'},[4]={['1']='Iron 20'}}
    assert(h.A:Refresh('manual'),'bare native string-key rows were lost')
    assert(#h.B:GetProjection().rows==2,'metadata became a row')
end)
test('Native numeric holes retain entries after a nonempty prefix',function()
    local h=fresh();h:Mainland(1,'Nuia')
    h.boards[1].contents={[1]='Fabric 20',[3]='Fabric 60'}
    assert(h.A:Refresh('manual'))
    assert(#h.B.State.dailySnapshots.west.boards[1].lines==2,'ipairs stopped at numeric hole')
end)
test('partial mainland boards 1/2 can be retained with known continent',function()
    local h=fresh();h.boards={[1]={contents={'Fabric 20'}},[2]={contents={'Leather 60'}}}
    assert(h.A:Refresh('manual'),'partial but attributable mainland data discarded')
    assert(h:Coverage('west') and #h.B:GetProjection().rows==2)
end)
test('only board 7 discovers Auroria and coexists with west',function()
    local h=fresh();h:Mainland(1,'Nuia');assert(h.A:Refresh('manual'))
    h.zone=777;h.boards={[7]={faction='Auroria',contents={'Ancestor Coinpurses 20'}}}
    assert(h.A:Refresh('zone_changed'))
    assert(h:Coverage('west') and h:Coverage('auroria'),'board 7 not retained')
end)
test('unknown mainland zone with explicit faction supports partial boards',function()
    local h=fresh({zone=777});h.boards={[1]={faction='Haranya',contents={'Fabric 20'}}}
    assert(h.A:Refresh('manual') and h:Coverage('east'),'explicit mainland side ignored')
end)
test('unattributable mainland data never guessed from last visited continent',function()
    local h=fresh();h:Mainland(1,'Nuia');assert(h.A:Refresh('manual'))
    h.zone=777;h.boards={[1]={contents={'Fabric 100'}},[2]={contents={'Leather 20'}}}
    h.A:Refresh('manual')
    assert(not h:Coverage('east') and h:Coverage('west'))
    assert(h.B:DescribeDailyCache().lastBoardProbe.captureAction=='scope_unresolved')
end)
test('stale faction after teleport is not saved as destination mainland',function()
    local h=fresh();h:Mainland(1,'Nuia');assert(h.A:Refresh('manual'))
    h.zone=4;h.A:Refresh('zone_changed')
    assert(not h:Coverage('east'),'stale west board mislabeled as east')
    assert(h:Coverage('west'))
end)
test('mixed families without location evidence cannot contaminate snapshots',function()
    local h=fresh();h:Mainland(777,nil);h.boards[5]={faction='Auroria',contents={'Prince Coinpurses 30'}}
    h.A:Refresh('manual')
    assert(not h:Coverage('west') and not h:Coverage('east') and not h:Coverage('auroria'),'ambiguous families accepted')
end)
test('unknown server date does not persist undated fresh board into yesterday',function()
    local h=fresh({day='2026-09-29'});h:Mainland(1,'Nuia');assert(h.A:Refresh('manual'));h:Save()
    h.day='unknown';h:Mainland(4,'Haranya');h.A:Refresh('manual')
    assert(h.B.State.dailyDateKey=='2026-09-29' and h:Coverage('west'))
    assert(not h:Coverage('east'),'undated fresh board stamped with restored older date')
    assert(h.S.Persistence:GetStore(h.B.storeId).dirty~=true,'unknown-date observation dirtied old dated snapshot')
end)
test('cold unknown date waits for readiness before collecting and saving',function()
    local h=fresh({day='unknown'});h:Mainland(1,'Nuia');h.A:Refresh('demand_start')
    assert(next(h.B.State.dailySnapshots)==nil and h.B.State.dailyDateKey==nil,'undated snapshot entered persistent domain')
end)
test('presentation and quest refresh never probe missing continent',function()
    local h=fresh();h:Mainland(1,'Nuia');assert(h.A:Refresh('manual'));h:Mainland(4,'Haranya')
    local before=h.boardCalls
    h.A:Refresh('presentation');h.A:Refresh('quest_progress')
    assert(h.boardCalls==before,'projection/progress refresh issued Native board reads')
end)
test('first partial board can merge later settled boards after bounded retry',function()
    local h=fresh();h.boards={[1]={faction='Nuia',contents={'Fabric 20'}}}
    assert(h.B:AcquireConsumer('test'))
    h:Mainland(1,'Nuia');h:Drain()
    assert(h:Coverage('west') and #h.B:GetProjection().rows==4,'late board load never retried')
end)
test('cold empty consumer recovers through LEFT_LOADING event',function()
    local h=fresh();assert(h.B:AcquireConsumer('test'));h:Drain()
    h:Mainland(1,'Nuia');h.S.Events:Dispatch('LEFT_LOADING');h:Drain()
    assert(h:Coverage('west'),'LEFT_LOADING cannot resume empty initial board')
end)
test('first cross-zone read empty then later ready keeps other continent',function()
    local h=fresh();h:Mainland(1,'Nuia');assert(h.B:AcquireConsumer('test'));h:Drain()
    h.zone=4;h.boards={};h.S.Events:Dispatch('ENTER_ANOTHER_ZONEGROUP');assert(h:RunOne())
    h:Mainland(4,'Haranya');h:Drain()
    assert(h:Coverage('west') and h:Coverage('east'),'single 750ms read stranded destination')
end)
test('consumer release cancels delayed native reads',function()
    local h=fresh();assert(h.B:AcquireConsumer('test'));h.S.Events:Dispatch('ENTER_ANOTHER_ZONEGROUP')
    local task=h.S.Scheduler.tasks.life_bonds_zone_refresh;local before=h.boardCalls
    assert(h.B:ReleaseConsumer('test'));if task then task.callback() end
    assert(h.S.Scheduler.tasks.life_bonds_zone_refresh==nil and h.boardCalls==before,'released consumer still reads')
end)
test('all-empty retry has finite budget and no resident polling afterwards',function()
    local h=fresh();assert(h.B:AcquireConsumer('test'));h:Drain()
    local before=h.boardCalls
    for i=1,10 do h.A:Refresh('presentation');h.A:Refresh('quest_progress') end
    assert(h.boardCalls==before,'exhausted failure converted into event polling')
    assert(h.boardCalls<=35,'retry budget exceeds 5 bounded board batches')
end)
test('generation change revokes pending reload callbacks',function()
    local h=fresh();assert(h.B:AcquireConsumer('test'));h.S.Events:Dispatch('ENTER_ANOTHER_ZONEGROUP')
    local task=assert(h.S.Scheduler.tasks.life_bonds_zone_refresh);local before=h.boardCalls
    h.S.Generation=h.S.Generation+1;task.callback()
    assert(h.boardCalls==before,'stale generation read new client state')
end)
test('actual SaveData key representation change keeps valid three-continent stamp',function()
    local h=fresh();h:Mainland(1,'Nuia');assert(h.A:Refresh('manual'))
    h:Mainland(4,'Haranya');assert(h.A:Refresh('manual'))
    h.zone=777;h.boards={[5]={contents={'Prince Coinpurses 30'}}};assert(h.A:Refresh('manual'))
    local save=ADDON.SaveData
    ADDON.SaveData=function(self,key,value)return save(self,key,stringifyKeys(value))end
    local disk=h:Save();local r=fresh({disk=disk});r.A:Refresh('presentation')
    assert(r:Coverage('west') and r:Coverage('east') and r:Coverage('auroria'),'serialized key representation lost snapshots')
end)
test('same-day empty read preserves both caches without re-saving',function()
    local h=fresh();h:Mainland(1,'Nuia');assert(h.A:Refresh('manual'))
    h:Mainland(4,'Haranya');assert(h.A:Refresh('manual'));h:Save();h.boards={};h.A:Refresh('manual')
    assert(h:Coverage('west') and h:Coverage('east'))
    assert(h.S.Persistence:GetStore(h.B.storeId).dirty~=true,'empty probe dirtied valid snapshot')
end)
test('proven date rollover never mixes yesterday with today',function()
    local h=fresh({day='2026-09-29'});h:Mainland(1,'Nuia');assert(h.A:Refresh('manual'))
    h.day='2026-09-30';h:Mainland(4,'Haranya');h.A:Refresh('manual')
    assert(not h:Coverage('west') and h:Coverage('east'),'old date retained as current data')
end)
test('merge filtering changes visible count not stored coverage',function()
    local h=fresh();h:Mainland(1,'Nuia');assert(h.B:AcquireConsumer('test'))
    h:Mainland(4,'Haranya');assert(h.A:Refresh('manual'))
    assert(h.B.Commands:SetDuplicateMode('west'))
    local d=h.B:DescribeDailyCache()
    assert(d.westLoaded and d.eastLoaded)
    assert(type(d.coverage)=='table' and d.coverage.east.lines==4 and d.coverage.east.visibleRows==0,'diagnostic confuses filtered rows with lost cache')
end)
test('diagnostics expose failed persistence without reading or saving',function()
    local h=fresh();h:Mainland(1,'Nuia');assert(h.A:Refresh('manual'))
    h.failSave=true;local ok=h.S.Persistence:SaveStore(h.B.storeId,{force=true,verifyAfterSave=true});assert(ok~=true)
    local beforeReads,beforeWrites,beforeBoards=h.reads,h.writes,h.boardCalls
    local d=h.B:DescribeDailyCache()
    assert(type(d.persistence)=='table' and d.persistence.failure=='save_failed','cached not same as safely saved')
    assert(type(h.B.GetHealth)=='function','module diagnostic missing actual Bonds read-only health')
    h.B:GetHealth()
    assert(h.reads==beforeReads and h.writes==beforeWrites and h.boardCalls==beforeBoards,'diagnostics changed native/persistent state')
end)
test('mixed families with known mainland retain compatible 1..4 projection',function()
    local h=fresh();h:Mainland(4,'Haranya');h.boards[5]={contents={'Prince Coinpurses 30'}}
    assert(h.A:Refresh('manual'),'known mainland wrongly blocked by other cached family')
    assert(h:Coverage('east') and not h:Coverage('auroria') and #h.B:GetProjection().rows==4)
end)
test('mixed families with known Auroria capture only 5..7',function()
    local h=fresh();h:Mainland(54,nil);h.boards[5]={contents={'Prince Coinpurses 30'}}
    assert(h.A:Refresh('manual'),'known Auroria wrongly blocked by other cached family')
    assert(h:Coverage('auroria') and not h:Coverage('west') and not h:Coverage('east'))
    assert(#h.B:GetProjection().rows==1)
end)
test('unknown date becomes ready during finite retry and saves correct date',function()
    local h=fresh({day='unknown'});h:Mainland(1,'Nuia');assert(h.B:AcquireConsumer('test'))
    h.day='2026-09-30';h:Drain()
    assert(h:Coverage('west') and h.B.State.dailyDateKey==h.day)
    local r=fresh({disk=h:Save()});r.A:Refresh('presentation');assert(r:Coverage('west'))
end)
test('native canonical alias collision rejected instead of random pairs winner',function()
    local h=fresh();h.boards[1]={contents={[1]='Fabric 20',['1']='Fabric 60'}}
    h.A:Refresh('manual')
    assert(not h:Coverage('west') and h.B:DescribeDailyCache().lastBoardProbe.shapeError=='native_board_duplicate_index')
end)
test('newer location event supersedes old sequence callback',function()
    local h=fresh();assert(h.B:AcquireConsumer('test'))
    local old=assert(h.S.Scheduler.tasks.life_bonds_zone_refresh)
    h.S.Events:Dispatch('ENTER_ANOTHER_ZONEGROUP');local before=h.boardCalls
    old.callback();assert(h.boardCalls==before,'superseded event performed Native reads')
    h:Mainland(4,'Haranya');h:Drain();assert(h:Coverage('east') and not h:Coverage('west'))
end)
test('disable and reacquire invalidates old callback and preserves cache',function()
    local h=fresh();h:Mainland(1,'Nuia');assert(h.B:AcquireConsumer('test'))
    h.S.Events:Dispatch('LEFT_LOADING');local old=assert(h.S.Scheduler.tasks.life_bonds_zone_refresh)
    assert(h.B:Disable());h:Mainland(4,'Haranya');assert(h.B:Enable());assert(h.B:AcquireConsumer('next'))
    local before=h.boardCalls;old.callback();assert(h.boardCalls==before)
    assert(h:Coverage('west') and h:Coverage('east'))
end)
test('unknown clock never stamps new completion into a restored older day',function()
    local h=fresh({day='2026-09-29'});h:Mainland(1,'Nuia');assert(h.A:Refresh('manual'));h:Save()
    h.day='unknown';X2Quest.IsCompleted=function()return true end
    h.S.Services.QuestProgressV3:Refresh();h.A:Refresh('quest_progress')
    assert(next(h.B.State.completedMainlandKeys)==nil,'current completion stamped under yesterday')
    assert(h.S.Persistence:GetStore(h.B.storeId).dirty~=true,'unknown clock dirtied old completion cache')
end)
local function corruptedReload(mutator)
    local h=fresh();h:Mainland(1,'Nuia');assert(h.A:Refresh('manual'))
    h:Mainland(4,'Haranya');assert(h.A:Refresh('manual'));local disk=h:Save()
    local store=assert(h.S.Persistence:GetStore(h.B.storeId));local key=assert(h.S.Persistence:ResolveStoreKey(store))
    local raw=assert(disk[key]);assert(raw.payload and raw.__rsmeta)
    mutator(raw.payload)
    -- Reseal the envelope to exercise the inner domain stamp, not just outer byte damage.
    -- No changed domain fingerprint: altered content still has to fail Core authentication.
    raw.__rsmeta.envelopeFingerprint=nil
    raw.__rsmeta.envelopeFingerprint=assert(h.S.Persistence:FingerprintEnvelopeIntegrity(raw))
    local r=fresh({disk=disk,allowLoadFailure=true})
    local restored=assert(r.S.Persistence:GetStore(r.B.storeId))
    assert(r.initOk~=true and restored.writeFenced==true,'bad payload admitted by sequence candidate')
    local ok=r.S.Persistence:SaveStore(r.B.storeId,{force=true,verifyAfterSave=true})
    assert(ok~=true and r.clears==0,'bad payload overwritten or cleared')
    return r
end
test('stored mixed string/numeric alias remains integrity fenced',function()
    corruptedReload(function(p)
        local boards=p.dailySnapshots.west.boards;boards['1']=boards[1]
    end)
end)
test('stored string sequence with a missing element remains fenced',function()
    corruptedReload(function(p)
        p.dailySnapshots.west.boards=stringifyKeys(p.dailySnapshots.west.boards)
        p.dailySnapshots.west.boards['2']=nil
    end)
end)
test('stored noncanonical index remains fenced',function()
    corruptedReload(function(p)
        local boards=p.dailySnapshots.west.boards;boards['01']=boards[1];boards[1]=nil
    end)
end)
test('stored changed text cannot pass original stamped fingerprint',function()
    corruptedReload(function(p)
        p.dailySnapshots.west.boards[1].lines[1]='Fabric 100'
    end)
end)
test('stored missing continent cannot pass original stamped fingerprint',function()
    corruptedReload(function(p) p.dailySnapshots.east=nil end)
end)
test('bounded native source rejects oversized map without dropping older cache',function()
    local h=fresh();h:Mainland(1,'Nuia');assert(h.A:Refresh('manual'));h:Save()
    h.boards={};local contents={};for i=1,193 do contents[i]='Fabric 20' end
    h.boards[1]={contents=contents};h.A:Refresh('manual')
    assert(h:Coverage('west') and h.B:DescribeDailyCache().lastBoardProbe.shapeError=='native_board_entry_limit')
    assert(h.S.Persistence:GetStore(h.B.storeId).dirty~=true)
end)
test('unknown mainland zone retains legacy empty-board faction locator fallback',function()
    local h=fresh({zone=777})
    h.boards={[1]={faction='Haranya',contents={}},[3]={contents={'Lumber 100'}},[4]={contents={'Iron 20'}}}
    assert(h.A:Refresh('manual') and h:Coverage('east'),'board1 faction locator discarded when fabric board empty')
end)
test('empty board faction metadata cannot override a known current zone',function()
    local h=fresh({zone=4})
    h.boards={[1]={faction='Nuia',contents={}},[3]={contents={'Lumber 100'}},[4]={contents={'Iron 20'}}}
    assert(h.A:Refresh('manual') and h:Coverage('east') and not h:Coverage('west'))
end)
print(string.format('BONDS_CROSS_CONTINENT: %d/%d passed (runtime=%s)',passed,total,_VERSION))
if passed~=total then error('Bonds cross-continent regression failures') end
