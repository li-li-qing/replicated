------------------------------------------------------------------------
-- Replicated Suite · 债券每日缓存测试
-- 作者：Replicated
-- QQ群：1104129461
--
-- 开发期回归使用实际 Bonds、Persistence 和 Demand，服务器时间与原生存储介质为受控输入。
-- 不写游戏 UDF，仅验证缓存和生命周期契约，不能替代 RU 实机验收。
------------------------------------------------------------------------
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
    local h=Boot(); h:Mainland(1); local active,done=true,false
    X2Quest.GetActiveQuestListCount=function()return active and 1 or 0 end
    X2Quest.GetActiveQuestType=function(_,i)return active and i==1 and 9044 or nil end
    X2Quest.IsCompleted=function(_,qid)return done and qid==9044 end
    assert(h.B:AcquireConsumer('daily_turn_in'));active,done=false,true
    assert(h.S.Services.QuestProgressV3:Refresh('turn_in')); assert(next(h.B.State.completedMainlandKeys)); h:AssertSaved()
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
-- 跨日时进度/筛选可能先刷新 serverDateKey，但它们不读取居民板，不能消费日期探测的责任。
Test('quest progress at midnight cannot consume the next daily collection',function()
    local h=Boot();h:Mainland(1);assert(h.B:AcquireConsumer('progress_midnight'))
    local task=assert(h.S.Scheduler.tasks.life_bonds_server_date);local before=h.boardCalls
    h.day='2026-10-08';h.boards[1].contents={'Fabric 60'}
    h.S.Events:Publish('v3.quest_progress.refreshed',1,'quest_event')
    assert(h.boardCalls==before,'quest progress must remain projection only')
    task.callback()
    assert(h.boardCalls==before+7 and h.B.State.dailySnapshots.west,'date observation suppressed actual next-day collection')
    assert(h.B:GetProjection().rows[1].quantity==60,'yesterday task survived the new day')
    h:AssertSaved();before=h.boardCalls;task.callback()
    assert(h.boardCalls==before,'same day check became permanent resident polling')
end)
Test('filter projection at midnight cannot consume the next daily collection',function()
    local h=Boot();h:Mainland(1);assert(h.B:AcquireConsumer('filter_midnight'))
    local task=assert(h.S.Scheduler.tasks.life_bonds_server_date);local before=h.boardCalls
    h.day='2026-10-08';h.boards[1].contents={'Fabric 100'}
    h.B.Commands:SetFilterMask(15);assert(h.boardCalls==before)
    task.callback()
    assert(h.boardCalls==before+7 and h.B:GetProjection().rows[1].quantity==100,'filter update swallowed the daily collection')
    h:AssertSaved()
end)
-- 2026-10-15：没有日期的 Native 完成标记不能证明今日已完成。
Test('eight undated completion flags never become eight completed daily rows',function()
    local h=Boot();h:Mainland(1)
    for i,material in ipairs({'Fabric','Leather','Lumber','Iron'}) do h.boards[i].contents={material..' 20',material..' 60'} end
    X2Quest.IsCompleted=function()return true end
    assert(h.B:AcquireConsumer('undated_all'))
    local p=h.B:GetProjection();assert(#p.rows==8)
    for _,row in ipairs(p.rows) do assert(row.completed~=true and row.statusText=='待确认','undated flag painted today as completed') end
    assert(next(h.B.State.completedMainlandKeys)==nil,'historical completion contaminated today latch')
    local evidence=h.B:DescribeDailyCache().completionEvidence
    assert(evidence and evidence.unverifiedCount==8,'completion scope is not diagnosable')
end)
Test('active daily quest outranks an undated completion flag',function()
    local h=Boot();h:Mainland(1);local ready=false
    X2Quest.IsCompleted=function()return true end
    X2Quest.GetActiveQuestListCount=function()return 1 end
    X2Quest.GetActiveQuestType=function(_,i)return i==1 and 9044 or nil end
    X2Quest.IsReadyForCompleteQuest=function()return ready end
    assert(h.B:AcquireConsumer('active_history'))
    assert(h.B:GetProjection().rows[1].statusText=='进行中','history hid an active daily quest')
    ready=true;assert(h.S.Services.QuestProgressV3:Refresh('ready'))
    assert(h.B:GetProjection().rows[1].statusText=='可交付','history hid ready-to-turn-in daily quest')
end)
Test('same-day observed incomplete to complete survives reload but never relatches tomorrow',function()
    local h=Boot();h:Mainland(1);local active,completed=true,false
    X2Quest.GetActiveQuestListCount=function()return active and 1 or 0 end
    X2Quest.GetActiveQuestType=function(_,i)return active and i==1 and 9044 or nil end
    X2Quest.IsCompleted=function(_,qid)return completed and qid==9044 end
    assert(h.B:AcquireConsumer('observed_completion'));active,completed=false,true
    assert(h.S.Services.QuestProgressV3:Refresh('turn_in'))
    assert(h.B:GetProjection().rows[1].completed and h.B.State.completedMainlandKeys['today:v1:fabric:20'])
    h:AssertSaved()
    local r=Boot({disk=h.Copy(h.disk)});r:Mainland(1)
    X2Quest.IsCompleted=function(_,qid)return qid==9044 end
    assert(r.B:AcquireConsumer('same_day_reload'));assert(r.B:GetProjection().rows[1].completed)
    r.day='2026-10-08';assert(r.A:Refresh('manual'))
    assert(not r.B:GetProjection().rows[1].completed,'constant true relatches yesterday completion on every new day')
    assert(next(r.B.State.completedMainlandKeys)==nil,'yesterday proof migrated into today')
end)
Test('legacy same-day unscoped completion keys cannot prove today after upgrade',function()
    local h=Boot();h:Capture()
    h.B.State.completedMainlandKeys={['fabric:20']=true}
    assert(h.S.Persistence:SaveStore(h.B.storeId,{force=true,verifyAfterSave=true}))
    local r=Boot({disk=h.Copy(h.disk)});r:Mainland(1);X2Quest.IsCompleted=function()return true end
    assert(r.B:AcquireConsumer('legacy_completion'))
    assert(r.B:GetProjection().rows[1].statusText=='待确认','legacy unscoped latch still paints completed')
    assert(r.B:DescribeDailyCache().completionEvidence.legacyIgnoredCount==1)
    assert(not r:Store().writeFenced,'valid legacy envelope was rejected')
end)
Test('Bonds detail never reinterprets unverified history as a completed daily quest',function()
    local h=Boot();h:Mainland(1);X2Quest.IsCompleted=function()return true end
    assert(h.B:AcquireConsumer('detail_history'));local row=h.B:GetProjection().rows[1]
    local detail=h.S.Services.QuestProgressV3:GetGroupDetail('bonds',row.key)
    assert(detail and detail.children[1].state=='UNKNOWN' and detail.completed==0,'detail bypassed daily evidence authority')
    assert(detail.summaryText:find('待确认',1,true),'detail summary claims definite daily progress')
end)
Test('reaccepting a verified daily quest revokes its previous observed completion',function()
    local h=Boot();h:Mainland(1);local active,done=true,false
    X2Quest.IsCompleted=function(_,qid)return done and qid==9044 end
    X2Quest.GetActiveQuestListCount=function()return active and 1 or 0 end
    X2Quest.GetActiveQuestType=function(_,i)return active and i==1 and 9044 or nil end
    assert(h.B:AcquireConsumer('reaccept'));active,done=false,true;assert(h.S.Services.QuestProgressV3:Refresh('turn_in'))
    assert(h.B:GetProjection().rows[1].completed)
    active=true;assert(h.S.Services.QuestProgressV3:Refresh('reaccepted'))
    assert(h.B:GetProjection().rows[1].statusText=='进行中' and h.B.State.completedMainlandKeys['today:v1:fabric:20']==nil)
    active=false;assert(h.S.Services.QuestProgressV3:Refresh('abandoned'))
    assert(h.B:GetProjection().rows[1].statusText=='待确认','abandoning a reaccepted quest was treated as turn-in')
end)
Test('missing native completion evidence remains unknown and public facts stay detached',function()
    local h=Boot();h:Mainland(1);local P=h.S.Services.QuestProgressV3
    X2Quest.IsCompleted=function()error('native not ready')end
    assert(h.B:AcquireConsumer('missing_completion'))
    assert(h.B:GetProjection().rows[1].statusText=='待确认' and next(h.B.State.completedMainlandKeys)==nil)
    X2Quest.IsCompleted=function()return true end
    local fact=P:GetQuestCompletionFact(9044);assert(fact.completed==true);fact.completed=false
    assert(P:GetQuestCompletionFact(9044).completed==true,'consumer mutated shared completion facts')
    assert(P:GetQuestCompletionFact(0)==nil and P:QuestState(0)=='UNKNOWN','invalid quest query did not fail gracefully')
end)
Test('successful quest refresh propagates inactive completion flag changes without manual refresh',function()
    local h=Boot();h:Mainland(1);local done=false
    X2Quest.IsCompleted=function(_,qid)return done and qid==9044 end
    assert(h.B:AcquireConsumer('completion_event'));done=true
    assert(h.S.Services.QuestProgressV3:Refresh('completion_changed'))
    assert(h.B:GetProjection().rows[1].statusText=='待确认' and next(h.B.State.completedMainlandKeys)==nil,
        'history loading was not propagated as unverified completion')
end)
Test('active true history cannot borrow incomplete evidence from before acceptance',function()
    local h=Boot();h:Mainland(1);local active,done=false,false
    X2Quest.IsCompleted=function(_,qid)return done and qid==9044 end
    X2Quest.GetActiveQuestListCount=function()return active and 1 or 0 end
    X2Quest.GetActiveQuestType=function(_,i)return active and i==1 and 9044 or nil end
    assert(h.B:AcquireConsumer('accept_history'))
    active,done=true,true;assert(h.S.Services.QuestProgressV3:Refresh('accepted_with_history'))
    active=false;assert(h.S.Services.QuestProgressV3:Refresh('abandoned_with_history'))
    assert(h.B:GetProjection().rows[1].statusText=='待确认' and next(h.B.State.completedMainlandKeys)==nil,
        'pre-acceptance false was reused as proof of turn-in')
end)
Test('unknown date discards uncommitted active completion evidence before same-day recovery',function()
    local h=Boot();h:Mainland(1);local active,done=true,false
    X2Quest.GetActiveQuestListCount=function()return active and 1 or 0 end
    X2Quest.GetActiveQuestType=function(_,i)return active and i==1 and 9044 or nil end
    X2Quest.IsCompleted=function(_,qid)return done and qid==9044 end
    assert(h.B:AcquireConsumer('unknown_completion_date'))
    h.day='unknown';done=true;assert(h.S.Services.QuestProgressV3:Refresh('unknown_day_active_true'))
    active=false;h.day='2026-10-07';assert(h.S.Services.QuestProgressV3:Refresh('known_day_after_abandon'))
    assert(h.B:GetProjection().rows[1].statusText=='待确认' and next(h.B.State.completedMainlandKeys)==nil,
        'unknown-day observation failed to revoke earlier completion candidate')
end)
Test('abandoned incomplete quest cannot reuse its candidate when history loads later',function()
    local h=Boot();h:Mainland(1);local active,done=true,false
    X2Quest.GetActiveQuestListCount=function()return active and 1 or 0 end
    X2Quest.GetActiveQuestType=function(_,i)return active and i==1 and 9044 or nil end
    X2Quest.IsCompleted=function(_,qid)return done and qid==9044 end
    assert(h.B:AcquireConsumer('abandon_before_history'))
    active=false;assert(h.S.Services.QuestProgressV3:Refresh('abandoned_incomplete'))
    assert(h.B:GetProjection().rows[1].statusText=='未接')
    done=true;assert(h.S.Services.QuestProgressV3:Refresh('history_loaded_after_abandon'))
    assert(h.B:GetProjection().rows[1].statusText=='待确认' and next(h.B.State.completedMainlandKeys)==nil)
end)
Test('unavailable completion or active index breaks uncommitted transition evidence',function()
    for _,kind in ipairs({'completed','active_index'}) do
        local h=Boot();h:Mainland(1);local active,done,fail=true,false,false
        X2Quest.GetActiveQuestListCount=function()if fail and kind=='active_index' then error('index not ready')end;return active and 1 or 0 end
        X2Quest.GetActiveQuestType=function(_,i)return active and i==1 and 9044 or nil end
        X2Quest.IsCompleted=function(_,qid)if fail and kind=='completed' then error('completion not ready')end;return done and qid==9044 end
        assert(h.B:AcquireConsumer('broken_evidence_'..kind))
        active,done,fail=false,true,true;assert(h.S.Services.QuestProgressV3:Refresh('unavailable_evidence'))
        fail=false;assert(h.S.Services.QuestProgressV3:Refresh('restored_history'))
        assert(h.B:GetProjection().rows[1].statusText=='待确认' and next(h.B.State.completedMainlandKeys)==nil,
            'unavailable '..kind..' did not revoke the completion candidate')
    end
end)
-- 交付成功事件必须独立于页面需求；无日期的历史 true 仍不能补算成今日完成。
local function CompletionHost(options)
    local h=Boot(options); h.quest={id=9152,active=false,done=true,reads=0}
    X2Quest.GetActiveQuestListCount=function()
        h.quest.reads=h.quest.reads+1
        if h.quest.failIndex then error('index unavailable') end
        return h.quest.active and 1 or 0
    end
    X2Quest.GetActiveQuestType=function(_,i)
        if h.quest.failType then error('quest type unavailable') end
        return h.quest.active and i==1 and h.quest.id or nil
    end
    X2Quest.IsCompleted=function(_,qid)
        h.quest.reads=h.quest.reads+1
        if h.quest.failDone then error('completion unavailable') end
        return qid==h.quest.id and h.quest.done
    end
    function h:QuestEvent(status,qid) self.S.Events:Dispatch('QUEST_CONTEXT_UPDATED',qid or self.quest.id,status) end
    function h:CompletionTask()
        for name,task in pairs(self.S.Scheduler.tasks) do
            if name:find('life_bonds_completion:',1,true)==1 then return task end
        end
    end
    return h
end
Test('closed page records an explicit Taichu turn-in durably and restores it after reload',function()
    local h=CompletionHost({day='2026-10-23',zone=21}); h:QuestEvent('completed')
    assert(h.B.State.completedMainlandKeys['today:v1:leather:60'],'explicit turn-in was lost while UI was closed')
    assert(h.B.State.completionDateKey==h.day); h:AssertSaved()
    assert(h.boardCalls==0 and (h.A.resourceReads or 0)==0,'background observer read board or bag')
    assert((h.S.Services.QuestProgressV3.consumerCount or 0)==0 and not h:CompletionTask(),'observer acquired polling demand')
    local r=Boot({disk=h.Copy(h.disk),day=h.day,zone=21}); r:Mainland(21)
    X2Quest.IsCompleted=function(_,qid)return qid==9152 end
    assert(r.B:AcquireConsumer('restore_turn_in'))
    assert(r.B:GetProjection().rows[2].statusText=='已完成','confirmed turn-in did not survive reload')
end)
Test('completion event resolves active quests whose historical completion was already true',function()
    local h=CompletionHost(); h:Mainland(21); h.quest.active=true
    assert(h.B:AcquireConsumer('active_true')); assert(h.B:GetProjection().rows[2].statusText=='进行中')
    h.quest.active=false; h:QuestEvent('completed')
    assert(h.B:GetProjection().rows[2].statusText=='已完成'); h:AssertSaved()
    assert(h.B:ReleaseConsumer('active_true')); local writes=h.writes
    h.quest.id=9044; h:QuestEvent('completed')
    assert(h.B.State.completedMainlandKeys['today:v1:fabric:20'] and h.writes==writes+1,'closing page removed completion observer')
end)
Test('unrelated malformed abandoned and dialog events never prove completion',function()
    local h=CompletionHost(); local reads,writes=h.quest.reads,h.writes
    h:QuestEvent('updated'); h:QuestEvent('dropped'); h:QuestEvent('completed',999999)
    h.S.Events:Dispatch('QUEST_CONTEXT_UPDATED','completed',9152)
    h.S.Events:Dispatch('QUEST_CONTEXT_UPDATED',9152.5,'completed')
    h.S.Events:Dispatch('COMPLETE_QUEST_CONTEXT_NPC',9152)
    h.S.Events:Dispatch('COMPLETE_QUEST_CONTEXT_DOODAD',9152)
    assert(next(h.B.State.completedMainlandKeys)==nil and not h:CompletionTask())
    assert(h.quest.reads==reads and h.writes==writes,'irrelevant event caused Native reads or writes')
end)
Test('completion observer requires a known non-rollback server day',function()
    local h=CompletionHost({day='unknown'}); h:QuestEvent('completed')
    assert(next(h.B.State.completedMainlandKeys)==nil and h.writes==0 and not h:CompletionTask())
    h.day='2026-10-07'; h:Capture(); local disk=h.Copy(h.disk)
    for _,field in ipairs({'dailyDateKey','completionDateKey'}) do
        local r=CompletionHost({disk=h.Copy(disk),day='2026-10-06'})
        r.B.State[field]='2026-10-08'; r:QuestEvent('completed')
        assert(next(r.B.State.completedMainlandKeys)==nil and r.writes==0 and not r:CompletionTask(),'clock rollback accepted')
    end
end)
Test('completed event retries only its target until native facts catch up',function()
    for _,kind in ipairs({'active','failIndex','failDone','done'}) do
        local h=CompletionHost(); h.quest[kind]=kind~='done'; h:QuestEvent('completed')
        local task=assert(h:CompletionTask(),'missing bounded retry for '..kind)
        assert(next(h.B.State.completedMainlandKeys)==nil and h.boardCalls==0)
        h.quest[kind]=kind=='done'; task.callback()
        assert(h.B.State.completedMainlandKeys['today:v1:leather:60'] and not h:CompletionTask()); h:AssertSaved()
    end
end)
Test('partially unreadable active index cannot confirm an apparently inactive quest',function()
    local h=CompletionHost(); h.quest.active,h.quest.failType=true,true; h:QuestEvent('completed')
    assert(next(h.B.State.completedMainlandKeys)==nil,'partial active index was mistaken for no active quest')
    assert(h:CompletionTask()); h.quest.active,h.quest.failType=false,false; h:CompletionTask().callback()
    assert(h.B.State.completedMainlandKeys['today:v1:leather:60'])
end)
Test('duplicate completion events do not resave or extend a bounded retry',function()
    local h=CompletionHost(); h:QuestEvent('completed'); local writes=h.writes
    h:QuestEvent('completed'); assert(h.writes==writes and h.B.State.completedMainlandKeys['today:v1:leather:60'])
    local r=CompletionHost(); r.quest.active=true; r:QuestEvent('completed'); local task=assert(r:CompletionTask())
    r:QuestEvent('completed'); assert(r:CompletionTask()==task,'duplicate reset the attempt budget')
    local count=0
    while r:CompletionTask() do count=count+1; assert(count<=3,'unbounded completion polling'); r:CompletionTask().callback() end
    assert(count==3 and next(r.B.State.completedMainlandKeys)==nil and r.boardCalls==0)
end)
Test('started and dropped cancel pending proof and started revokes a prior same-day completion',function()
    for _,status in ipairs({'started','dropped'}) do
        local h=CompletionHost(); h.quest.active=true; h:QuestEvent('completed'); local task=assert(h:CompletionTask())
        h:QuestEvent(status); h.quest.active=false; task.callback()
        assert(not h:CompletionTask() and next(h.B.State.completedMainlandKeys)==nil,'cancelled candidate wrote proof')
    end
    local h=CompletionHost(); h:QuestEvent('completed'); assert(h.B.State.completedMainlandKeys['today:v1:leather:60'])
    h:QuestEvent('started'); h:QuestEvent('dropped')
    assert(not h.B.State.completedMainlandKeys['today:v1:leather:60'],'reaccepted then abandoned quest retained an old proof')
    h:AssertSaved()
end)
Test('late retry cannot move yesterday turn-in into today or survive observer shutdown',function()
    for _,kind in ipairs({'midnight','unknown','disable','generation','reload'}) do
        local h=CompletionHost(); h.quest.active=true; h:QuestEvent('completed'); local task=assert(h:CompletionTask())
        if kind=='midnight' then h.day='2026-10-08'
        elseif kind=='unknown' then h.day='unknown'
        elseif kind=='disable' then assert(h.B:Disable()); assert(h.B:Enable())
        elseif kind=='generation' then h.S.Generation=h.S.Generation+1
        else ReplicatedSuite={} end
        h.quest.active=false; task.callback()
        assert(next(h.B.State.completedMainlandKeys)==nil and h.writes==0,'late '..kind..' callback saved a completion')
    end
end)
Test('failed completion commit rolls back proof and can recover within its retry budget',function()
    local h=CompletionHost(); h.failSave=true; h:QuestEvent('completed')
    assert(next(h.B.State.completedMainlandKeys)==nil,'failed disk write left a completed in-memory proof')
    local task=assert(h:CompletionTask()); h.failSave=false; task.callback()
    assert(h.B.State.completedMainlandKeys['today:v1:leather:60'] and not h:CompletionTask()); h:AssertSaved()
    local r=CompletionHost(); local store=r:Store(); store.writeFenced=true; store.writeFenceReason='integrity_failed'
    r:QuestEvent('completed'); assert(store.writeFenced and r.writes==0 and next(r.B.State.completedMainlandKeys)==nil)
end)
Test('cancellation during a native read cannot commit or reschedule the old candidate',function()
    for _,kind in ipairs({'dropped','disable','generation'}) do
        local h=CompletionHost(); X2Quest.IsCompleted=function()
            if kind=='dropped' then h:QuestEvent('dropped')
            elseif kind=='disable' then assert(h.B:Disable())
            else h.S.Generation=h.S.Generation+1 end
            return true
        end
        h:QuestEvent('completed')
        assert(next(h.B.State.completedMainlandKeys)==nil and h.writes==0 and not h:CompletionTask(),
            'candidate cancelled during Native read still wrote proof: '..kind)
    end
end)
Test('unverified completion readback cannot publish a confirmed proof',function()
    local h=CompletionHost(); local save=ADDON.SaveData
    ADDON.SaveData=function(self,key,value) local ok=save(self,key,value); h.disk[key]=nil; return ok end
    h:QuestEvent('completed'); ADDON.SaveData=save
    assert(next(h.B.State.completedMainlandKeys)==nil and h.B:DescribeDailyCache().completionEvents.confirmed==0,
        'unverified completion save was published as confirmed')
end)
Test('failed reaccept revocation stays pending and cannot display or restore the old proof',function()
    for _,uiOpen in ipairs({false,true}) do
        local h=CompletionHost(); h:QuestEvent('completed')
        if uiOpen then h:Mainland(21); assert(h.B:AcquireConsumer('revoke_failed')) end
        h.failSave=true; h:QuestEvent('started'); local task=assert(h:CompletionTask(),'failed revocation has no retry')
        if uiOpen then assert(h.B:GetProjection().rows[2].statusText=='待确认','failed revocation still displays completed') end
        h:QuestEvent('started'); assert(h:CompletionTask()==task,'duplicate start reset revoke retry budget')
        h.failSave=false; h:QuestEvent('dropped')
        assert(h.B.State.completedMainlandKeys['today:v1:leather:60']==nil and not h:CompletionTask()); h:AssertSaved()
        local r=Boot({disk=h.Copy(h.disk)}); r:Mainland(21); X2Quest.IsCompleted=function()return true end
        assert(r.B:AcquireConsumer('revoked_reload')); assert(r.B:GetProjection().rows[2].statusText=='待确认')
    end
end)
Test('explicit abandonment also clears the older active-incomplete observation',function()
    local h=CompletionHost(); h:Mainland(21); h.quest.active,h.quest.done=true,false
    assert(h.B:AcquireConsumer('drop_old_observation')); h.quest.active,h.quest.done=false,true
    h:QuestEvent('dropped'); assert(h.S.Services.QuestProgressV3:Refresh('history_after_drop'))
    assert(h.B:GetProjection().rows[2].statusText=='待确认' and next(h.B.State.completedMainlandKeys)==nil,
        'old transition path ignored an explicit drop event')
end)
Test('server day is revalidated after native reads before mutating completion state',function()
    local h=CompletionHost(); X2Quest.IsCompleted=function()
        h.day='2026-10-08'; h.B.State.completionDateKey=h.day
        h.B.State.completedMainlandKeys={['today:v1:fabric:20']=true}
        return true
    end
    h:QuestEvent('completed')
    assert(h.writes==0 and h.B.State.completionDateKey==h.day and h.B.State.completedMainlandKeys['today:v1:fabric:20'],
        'yesterday candidate overwrote new-day completion state')
    assert(not h.B.State.completedMainlandKeys['today:v1:leather:60'] and not h:CompletionTask())
end)
Test('Auroria event uses canonical token keys and observer diagnostics are detached',function()
    local h=CompletionHost(); h.quest.id=h.S.Constants.AuroriaBondQuestByTokenQuantity.prince_purse[30]
    h:QuestEvent('completed')
    assert(h.B.State.completedMainlandKeys['today:v1:auroria:prince_purse:30'],'alias replaced canonical token')
    assert(not h.B.State.completedMainlandKeys['today:v1:auroria:golden_bag:30'])
    local d=assert(h.B:DescribeDailyCache().completionEvents); assert(d.subscribed and d.confirmed==1 and d.pendingCount==0)
    d.last.reason='mutated'; assert(h.B:DescribeDailyCache().completionEvents.last.reason~='mutated')
end)
-- 覆盖当前地区目录与全部规范债券变体；地区不参与 QuestId，但必须验证板文本、完成 key 和冷载投影一致。
local matrixHost=Boot()
local matrixZones=matrixHost.Copy(matrixHost.S.GameIds.Zone.ById)
local matrixVariants={mainland={},auroria={}}
local function AddMatrixVariants(family,material,board,label,map)
    local quantities={}; for quantity in pairs(map) do quantities[#quantities+1]=quantity end; table.sort(quantities)
    for _,quantity in ipairs(quantities) do
        matrixVariants[family][#matrixVariants[family]+1]={material=material,quantity=quantity,questId=map[quantity],board=board,label=label,
            key='today:v1:'..(family=='auroria' and 'auroria:' or '')..material..':'..tostring(quantity)}
    end
end
for board,material in ipairs({'fabric','leather','lumber','iron'}) do
    AddMatrixVariants('mainland',material,board,nil,matrixHost.S.Constants.BondQuestByMaterialQuantity[material])
end
for _,entry in ipairs({
    {'prince_purse',5,'Prince Coinpurses'},{'prince_crate',5,'Prince Crates'},
    {'queen_purse',6,'Queen Coinpurses'},{'queen_crate',6,'Queen Crates'},
    {'ancestor_purse',7,'Ancestor Coinpurses'},{'ancestor_crate',7,'Ancestor Crates'},
}) do AddMatrixVariants('auroria',entry[1],entry[2],entry[3],matrixHost.S.Constants.AuroriaBondQuestByTokenQuantity[entry[1]]) end
Test('region matrix covers every canonical quest once without alias collisions',function()
    local ids={}
    assert(#matrixVariants.mainland==12 and #matrixVariants.auroria==12,'canonical bond variant coverage changed')
    for _,variants in pairs(matrixVariants) do for _,v in ipairs(variants) do
        assert(not ids[v.questId],'different completion keys share a quest id'); ids[v.questId]=v.key
    end end
end)
local matrixZoneIds={}; for zoneId,zone in pairs(matrixZones) do
    assert(zone.continentKey=='west' or zone.continentKey=='east' or zone.continentKey=='auroria','unclassified bond location')
    matrixZoneIds[#matrixZoneIds+1]=zoneId
end
table.sort(matrixZoneIds)
local matrixCombinations=0
for _,zoneId in ipairs(matrixZoneIds) do
    local zone=matrixZones[zoneId]
    Test('all bond variants persist and expire in '..zone.nameZh..' ('..tostring(zoneId)..')',function()
        local family=zone.continentKey=='auroria' and 'auroria' or 'mainland'
        local variants=matrixVariants[family]
        local h=CompletionHost({day='2026-10-23',zone=zoneId}); local expected,boards={},{}
        for _,v in ipairs(variants) do
            expected[v.questId]=v
            boards[v.board]=boards[v.board] or {faction=zone.continentKey=='east' and 'Haranya' or 'Nuia',contents={}}
            local contents=boards[v.board].contents
            contents[#contents+1]=zone.nameZh..': '..(v.label and v.label..' ' or '')..tostring(v.quantity)
        end
        -- 模拟历史 IsCompleted 全程为 true，不借用 active && false 跃迁。
        X2Quest.IsCompleted=function(_,qid)return expected[qid]~=nil end
        for _,v in ipairs(variants) do
            h:QuestEvent('completed',v.questId)
            assert(h.B.State.completedMainlandKeys[v.key],'missing completion '..v.key)
        end
        assert(h.writes==#variants and h.boardCalls==0 and (h.A.resourceReads or 0)==0,'background confirmation did unrelated work')
        assert(h.S.Services.QuestProgressV3.consumerCount==0 and not h:CompletionTask()); h:AssertSaved()
        local r=Boot({disk=h.Copy(h.disk),day=h.day,zone=zoneId}); r.boards=h.Copy(boards)
        X2Quest.IsCompleted=function(_,qid)return expected[qid]~=nil end
        assert(r.B:AcquireConsumer('region_matrix'))
        local rows=r.B:GetProjection().rows; assert(#rows==#variants,'reload lost region board rows')
        for _,row in ipairs(rows) do
            local v=assert(expected[row.questId],'wrong regional quest id')
            assert(row.completed and row.statusText=='已完成' and row.materialKey==v.material and row.quantity==v.quantity,
                'regional completion does not match canonical quest')
            assert(row.continentKey==zone.continentKey and (family=='auroria' or row.regionZoneId==zoneId),'wrong region classification')
        end
        r:AssertSaved()
        r.day='2026-10-24'; assert(r.A:Refresh('manual'))
        assert(next(r.B.State.completedMainlandKeys)==nil,'yesterday proof survived a new server day')
        rows=r.B:GetProjection().rows; assert(#rows==#variants)
        for _,row in ipairs(rows) do assert(not row.completed and row.statusText=='待确认','history alone relatched the next day') end
        matrixCombinations=matrixCombinations+#variants
    end)
end
print(string.format('BONDS_REGION_MATRIX: %d regions / %d quest-region combinations',#matrixZoneIds,matrixCombinations))
print(string.format('BONDS_DAILY_CACHE: %d passed / %d failed (runtime=%s)',passed,failed,_VERSION))
if failed>0 then os.exit(1) end
