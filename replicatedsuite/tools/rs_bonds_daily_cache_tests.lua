-- Developer regression: actual Bonds/Persistence/Demand, controlled server clock and Native medium.
-- No game UDF writes; this proves cache/lifecycle contracts, not RU client acceptance.
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed=passed+1; print('PASS bonds-daily '..name)
    else failed=failed+1; print('FAIL bonds-daily '..name..'\n'..tostring(err)) end
end
local function Boot(options)
    options=options or {}
    local h=dofile('tools/rs_gear_page_test_host.lua')({disk=options.disk})
    local S=h.S
    h.day=options.day or '2026-10-07'; h.zone=options.zone or 1; h.boards={}; h.boardCalls=0
    UIParent={GetServerTimeTable=function()
        local y,m,d=h.day:match('^(%d+)%-(%d+)%-(%d+)$')
        return {year=tonumber(y) or 0,month=tonumber(m) or 0,day=tonumber(d) or 0}
    end}
    X2Unit.GetCurrentZoneGroup=function() return h.zone end
    X2Resident={GetResidentBoardContent=function(_,index)
        h.boardCalls=h.boardCalls+1; return h.Copy(h.boards[index] or {contents={}})
    end}
    X2Quest={GetActiveQuestListCount=function()return 0 end,GetActiveQuestType=function()return nil end,
        IsCompleted=function()return false end,IsReadyForCompleteQuest=function()return false end}
    X2Bag={Capacity=function()return 0 end,GetBagItemInfo=function()return nil end}
    dofile('core/rs_demand.lua')
    dofile('data/rs_data_registry.lua'); dofile('data/ids/rs_item_ids.lua'); dofile('data/ids/rs_quest_ids.lua')
    dofile('data/rs_static_data_v2.lua'); dofile('data/ids/rs_zone_ids.lua'); dofile('data/ids/rs_instance_ids.lua')
    dofile('data/rs_event_data.lua'); dofile('data/rs_quest_data.lua'); dofile('core/rs_constants.lua')
    dofile('services/rs_quest_progress_v3.lua')
    dofile('features/life/shared/rs_life_slice_factory.lua'); dofile('features/life/bonds/rs_bonds_feature.lua')
    h.B=S.Features.Bonds; h.A=h.B.Authority
    if not options.skipInitialize then assert(h.B:Initialize()) end
    assert(h.B:Enable())
    function h:Mainland(zone)
        self.zone=zone; self.boards={}
        for i,line in ipairs({'Fabric 20','Leather 60','Lumber 100','Iron 20'}) do
            self.boards[i]={faction=zone==4 and 'Haranya' or 'Nuia',contents={line}}
        end
    end
    function h:Capture(zone) self:Mainland(zone or 1); assert(self.A:Refresh('manual')) end
    function h:Store() return self.S.Persistence:GetStore(self.B.storeId) end
    function h:AssertSaved()
        local store=self:Store()
        assert(not store.dirty and not store.needsBarrierVerify and store.lastVerifyOk==true,'snapshot not durably verified before returning')
    end
    return h
end
Test('first capture survives immediate fresh session without ticking or flushing',function()
    local h=Boot(); h:Capture(); h:AssertSaved()
    assert(h.writes==1,'capture should commit once')
    local r=Boot({disk=h.Copy(h.disk)}); assert(r.B:AcquireConsumer('reload'))
    assert(r.boardCalls==0 and r.writes==0,'same-day complete cache reread Native board or resaved')
    assert(#r.B:GetProjection().rows==4 and r.B.State.dailyDateKey==r.day)
end)
Test('same-day demand and loading events reuse complete cache',function()
    local h=Boot(); h:Capture(); local r=Boot({disk=h.Copy(h.disk)})
    assert(r.B:AcquireConsumer('first')); assert(r.B:ReleaseConsumer('first')); assert(r.B:AcquireConsumer('second'))
    for _,reason in ipairs({'entered_world','left_loading','location_retry','initial','zone_changed'}) do assert(r.A:Refresh(reason)) end
    assert(r.boardCalls==0 and r.writes==0 and #r.B:GetProjection().rows==4,'cached day re-collected')
end)
Test('all three continents restore independently and missing continent is acquired',function()
    local h=Boot(); h:Capture(1); h:Capture(4)
    h.zone=54; h.boards={[5]={contents={'Prince Coinpurses 30'}},[6]={contents={'Queen Crates 8'}},[7]={contents={'Ancestor Coinpurses 20'}}}
    assert(h.A:Refresh('manual')); h:AssertSaved()
    local r=Boot({disk=h.Copy(h.disk),zone=4}); assert(r.B:AcquireConsumer('all'))
    local p=r.B:GetProjection(); assert(p.dailySnapshotStatus.west and p.dailySnapshotStatus.east and p.dailySnapshotStatus.auroria)
    assert(r.boardCalls==0 and r.writes==0 and p.snapshotCount==3)
    local one=Boot(); one:Capture(1)
    local east=Boot({disk=one.Copy(one.disk),zone=4}); east:Mainland(4); assert(east.B:AcquireConsumer('east'))
    assert(east.boardCalls==7 and east.B.State.dailySnapshots.west and east.B.State.dailySnapshots.east); east:AssertSaved()
end)
Test('unknown server date preserves local snapshot until it can be verified',function()
    local h=Boot(); h:Capture()
    local r=Boot({disk=h.Copy(h.disk),day='unknown'}); assert(r.B:AcquireConsumer('unknown'))
    assert(r.B.State.dailyDateKey=='2026-10-07' and #r.B:GetProjection().rows==4)
    assert(r.boardCalls==0 and r.writes==0 and r.B:GetProjection().snapshotDateVerified==false)
    r.day='2026-10-07'; assert(r.A:Refresh('location_retry'))
    assert(r.B:GetProjection().snapshotDateVerified==true and r.boardCalls==0 and r.writes==0)
end)
Test('proven next server day expires cache even if Native board is not ready',function()
    local h=Boot(); h:Capture()
    local r=Boot({disk=h.Copy(h.disk),day='2026-10-08'}); assert(r.B:AcquireConsumer('next_day'))
    assert(next(r.B.State.dailySnapshots)==nil and r.B.State.dailyDateKey=='2026-10-08','yesterday displayed as today')
    r:AssertSaved(); local again=Boot({disk=r.Copy(r.disk),day='2026-10-08'})
    assert(next(again.B.State.dailySnapshots)==nil and again.B.State.dailyDateKey=='2026-10-08')
    r:Mainland(4); assert(r.A:Refresh('location_retry')); r:AssertSaved()
    assert(r.B.State.dailySnapshots.east and not r.B.State.dailySnapshots.west)
end)
Test('server clock moving backwards cannot clear or contaminate newer local day',function()
    local h=Boot(); h:Capture()
    local r=Boot({disk=h.Copy(h.disk),day='2026-10-06',zone=4}); r:Mainland(4); assert(r.B:AcquireConsumer('clock_back'))
    assert(r.B.State.dailyDateKey=='2026-10-07' and r.B.State.dailySnapshots.west and not r.B.State.dailySnapshots.east)
    assert(r.writes==0 and r.boardCalls==0 and r.B:DescribeDailyCache().dateValidation=='server_date_rollback')
end)
Test('partial same-day snapshot is retained and completed after reload',function()
    local h=Boot(); h.boards={[1]={faction='Nuia',contents={'Fabric 20'}}}; assert(h.A:Refresh('manual')); h:AssertSaved()
    local r=Boot({disk=h.Copy(h.disk)}); r:Mainland(1); assert(r.B:AcquireConsumer('partial'))
    assert(r.boardCalls==7 and #r.B:GetProjection().rows==4); r:AssertSaved()
end)
Test('partial unknown-zone Auroria cache continues collecting after reload',function()
    local h=Boot(); h:Capture(1); h.zone=777
    h.boards={[5]={contents={'Prince Coinpurses 30'}}}; assert(h.A:Refresh('manual')); h:AssertSaved()
    local r=Boot({disk=h.Copy(h.disk),zone=777})
    r.boards={[6]={contents={'Queen Crates 8'}},[7]={contents={'Ancestor Coinpurses 20'}}}; assert(r.B:AcquireConsumer('auroria'))
    assert(r.boardCalls==7 and #r.B:GetProjection().rows==7 and r.B.State.dailySnapshots.west); r:AssertSaved()
end)
Test('same-day quest completion is durably retained then cleared at the next day',function()
    local h=Boot(); h:Mainland(1); X2Quest.IsCompleted=function()return true end
    assert(h.A:Refresh('manual')); assert(next(h.B.State.completedMainlandKeys)); h:AssertSaved()
    local r=Boot({disk=h.Copy(h.disk)}); assert(r.B:AcquireConsumer('completion'))
    assert(next(r.B.State.completedMainlandKeys) and r.B:GetProjection().rows[1].completed)
    r.day='2026-10-08'; r.A:Refresh('manual'); assert(next(r.B.State.completedMainlandKeys)==nil); r:AssertSaved()
end)
Test('failed capture save is reported and retains bounded retry obligation',function()
    local h=Boot(); h:Mainland(1); h.failSave=true
    local ok,err=h.A:Refresh('manual'); assert(ok==false and err,'failed save was reported as durable success')
    assert(h.B.State.dailySnapshots.west and h:Store().dirty and h:Store().needsBarrierVerify)
    assert(h.B:DescribeDailyCache().lastSaveIntent.accepted==false)
    assert(h.B:GetProjection().dailySaveStatus=='failed')
    h.failSave=false; assert(h.A:Refresh('manual')); h:AssertSaved()
    local r=Boot({disk=h.Copy(h.disk)}); assert(r.B:AcquireConsumer('recovered')); assert(#r.B:GetProjection().rows==4)
end)
Test('successful SaveData without matching readback cannot claim a saved day',function()
    local h=Boot(); h:Mainland(1); local save=ADDON.SaveData
    ADDON.SaveData=function(self,key,value) local ok=save(self,key,value); h.disk[key]=nil; return ok end
    local ok,err=h.A:Refresh('manual'); assert(ok==false and tostring(err):find('readback_verify_failed',1,true))
    assert(h:Store().dirty and h:Store().needsBarrierVerify)
    ADDON.SaveData=save; assert(h.A:Refresh('manual')); h:AssertSaved()
end)
Test('Life Initialize respects already loaded settings and pending verification',function()
    local h=Boot({skipInitialize=true}); assert(h.S.Persistence:PrepareRead(h.B.storeId))
    h.B.State.sortMode='material'; assert(h.S.Persistence:SaveStore(h.B.storeId,{force=true}))
    assert(h:Store().needsBarrierVerify); local reads,writes=h.reads,h.writes
    local ok,err=h.B:Initialize(); assert(ok,err)
    assert(h.B.State.sortMode=='material' and h:Store().needsBarrierVerify and h.reads==reads and h.writes==writes)
end)
Test('Life Initialize preserves dirty pre-start settings without rereading disk',function()
    local h=Boot({skipInitialize=true}); assert(h.B:SetSortMode('material')); assert(h:Store().dirty)
    local reads,writes=h.reads,h.writes; assert(h.B:Initialize())
    assert(h.B.State.sortMode=='material' and h:Store().dirty and h.reads==reads and h.writes==writes)
end)
Test('fenced local store cannot be replaced by fresh Native data',function()
    local h=Boot({skipInitialize=true}); local store=h:Store()
    store.loaded=true; store.loadStatus='integrity_failed'; store.writeFenced=true
    store.writeFenceReason='integrity_failed'; store.lastError='synthetic integrity failure'
    h:Mainland(1); local reads,writes=h.reads,h.writes
    local ok,err=h.A:Refresh('manual'); assert(ok==false and err)
    assert(not h.B.storeLoaded and store.writeFenced and h.boardCalls==0 and h.reads==reads and h.writes==writes)
end)
Test('active daily date check has no same-day IO and expires only on server date change',function()
    local h=Boot(); h:Mainland(1); assert(h.B:AcquireConsumer('day_check'))
    local task=assert(h.S.Scheduler.tasks.life_bonds_server_date)
    assert(task.intervalMs==60000 and task.owner==h.B and task.priority==3 and task.pending==false and task.elapsedMs==0)
    local reads,writes,boards=h.reads,h.writes,h.boardCalls
    task.callback(); task.callback()
    assert(h.reads==reads and h.writes==writes and h.boardCalls==boards,'same day clock check read board/storage')
    h.day='2026-10-08'; h.zone=4; h:Mainland(4); task.callback()
    assert(h.B.State.dailyDateKey==h.day and h.B.State.dailySnapshots.east and not h.B.State.dailySnapshots.west); h:AssertSaved()
    assert(h.B:ReleaseConsumer('day_check')); assert(h.S.Scheduler.tasks.life_bonds_server_date==nil)
    reads,writes,boards=h.reads,h.writes,h.boardCalls; h.day='2026-10-09'; task.callback()
    assert(h.reads==reads and h.writes==writes and h.boardCalls==boards,'released date task performed IO')
end)
Test('disable and reacquire revokes the previous same-generation date callback',function()
    local h=Boot(); h:Mainland(1); assert(h.B:AcquireConsumer('old'))
    local old=assert(h.S.Scheduler.tasks.life_bonds_server_date)
    assert(h.B:Disable()); assert(h.B:Enable()); assert(h.B:AcquireConsumer('new'))
    local reads,writes,boards=h.reads,h.writes,h.boardCalls; h.day='2026-10-08'; old.callback()
    assert(h.reads==reads and h.writes==writes and h.boardCalls==boards,'superseded date callback still active')
end)
Test('old-generation daily date callback cannot capture or save after reload',function()
    local h=Boot(); h:Mainland(1); assert(h.B:AcquireConsumer('generation'))
    local task=assert(h.S.Scheduler.tasks.life_bonds_server_date); local reads,writes,boards=h.reads,h.writes,h.boardCalls
    h.S.Generation=h.S.Generation+1; h.day='2026-10-08'; task.callback()
    assert(h.reads==reads and h.writes==writes and h.boardCalls==boards)
end)
print(string.format('BONDS_DAILY_CACHE: %d passed / %d failed (runtime=%s)',passed,failed,_VERSION))
if failed>0 then os.exit(1) end
