-- Replicated Suite · 寻宝总开关耐久恢复与取证
-- 真实 Persistence / FeatureRuntime / Treasure，只有 Native 存储为内存盘。
-- 不能据此认定已复现用户 RU 重载问题。
local Host=dofile('tools/rs_udf_numeric_test_host.lua')
local passed,failed=0,0
local function Test(name,fn)
    local ok,err=xpcall(fn,debug.traceback)
    if ok then passed=passed+1;print('PASS treasure-preference '..name)
    else failed=failed+1;print('FAIL treasure-preference '..name..': '..tostring(err))end
end
local function Boot(disk)
    local S,P,native=Host.Boot(disk)
    local meta={id='life_treasure',route='life.treasure',name='寻宝/海虫/沉船',category='life',
        authority='v3.life.treasure',defaultEnabled=false}
    S.FeatureRegistry={order={meta.id},Get=function(_,id)if id==meta.id then return meta end end,
        List=function()return {meta}end,IsAccessible=function(_,id)return id==meta.id end}
    S.ApiImports={Acquire=function()return true end}
    local call=S.Api.CallCapability
    function S.Api:CallCapability(cap,...)
        if cap=='X2Unit:GetUnitWorldPositionByTarget' then return true,21503,nil,28672,0 end
        return call(self,cap,...)
    end
    S.Services.InventorySnapshotV3={BuildSnapshot=function()return {rows={},bagId=1,readErrors=0}end,ReadSlot=function()return true,nil end}
    dofile('features/rs_feature_runtime.lua')
    dofile('features/life/shared/rs_life_slice_factory.lua')
    dofile('data/rs_treasure_sea_points.lua')
    dofile('features/life/treasure/rs_treasure_sea_catalog.lua')
    dofile('features/life/treasure/rs_treasure_feature.lua')
    assert(S.FeatureRuntime:EnableDefaults('runtime_start'))
    return S,S.FeatureRuntime,native
end
Test('enable survives a new runtime without waiting for a debounce',function()
    local S,R,n=Boot();assert(R:SetPreferredEnabled('life_treasure',true,'life_page_toggle'))
    assert(R:IsEnabled('life_treasure') and R:GetPreferredEnabled('life_treasure'))
    local _,fresh=Boot(n.disk);assert(fresh:IsEnabled('life_treasure'),'enabled preference lost on cold reload')
end)
Test('shutdown cleanup does not overwrite enabled preference',function()
    local S,R,n=Boot();assert(R:SetPreferredEnabled('life_treasure',true,'module_toolbar'))
    assert(S.Persistence:Flush());assert(R:DisableAll('shutdown'))
    assert(not R:IsEnabled('life_treasure') and R:GetPreferredEnabled('life_treasure'))
    local _,fresh=Boot(n.disk);assert(fresh:IsEnabled('life_treasure'))
end)
Test('explicit disable survives the same reload path',function()
    local _,R,n=Boot();assert(R:SetPreferredEnabled('life_treasure',true))
    assert(R:SetPreferredEnabled('life_treasure',false,'life_page_toggle'))
    local _,fresh=Boot(n.disk);local wanted,explicit=fresh:GetPreferredEnabled('life_treasure')
    assert(not fresh:IsEnabled('life_treasure') and wanted==false and explicit)
end)
Test('read only evidence distinguishes runtime state from the saved intent',function()
    local S,R,n=Boot();assert(R:SetPreferredEnabled('life_treasure',true,'life_page_toggle'))
    assert(R:Disable('life_treasure','shutdown'))
    local reads,writes=n.reads,n.writes
    local d=R:GetPreferenceDiagnostics('life_treasure')
    assert(d.preferredEnabled and d.explicitPreference and not d.runtimeEnabled)
    assert(d.lastOperation.reason=='life_page_toggle' and d.lastOperation.stage=='committed' and d.lastOperation.targetEnabled)
    assert(d.lifecycleReason=='shutdown' and d.store.lastVerifyOk==true)
    d.lastOperation.reason='edited snapshot'
    assert(R:GetPreferenceDiagnostics('life_treasure').lastOperation.reason=='life_page_toggle')
    assert(reads==n.reads and writes==n.writes,'diagnostic reads or writes Native storage')
end)
Test('a compensating disable records its actual caller',function()
    local _,R=Boot();assert(R:SetPreferredEnabled('life_treasure',true,'life_page_toggle'))
    assert(R:SetPreferredEnabled('life_treasure',false,'life_page_acquire_rollback'))
    local d=R:GetPreferenceDiagnostics('life_treasure')
    assert(d.lastOperation.reason=='life_page_acquire_rollback' and d.lastOperation.stage=='committed')
    assert(d.lastOperation.targetEnabled==false and d.preferredEnabled==false)
end)
Test('failed saving is recorded as rejected and preserves the previous preference',function()
    local _,R,n=Boot();n.failSave=true
    assert(not R:SetPreferredEnabled('life_treasure',true,'life_page_toggle'))
    local d=R:GetPreferenceDiagnostics('life_treasure')
    assert(not d.runtimeEnabled and not d.preferredEnabled)
    assert(d.lastOperation.stage=='persist_rejected' and d.lastOperation.error)
end)
Test('startup evidence records the loaded preference and restoration outcome',function()
    local _,R,n=Boot();assert(R:SetPreferredEnabled('life_treasure',true,'module_toolbar'))
    local _,fresh=Boot(n.disk)
    local d=fresh:GetPreferenceDiagnostics('life_treasure')
    assert(d.startup.preferredEnabled and d.startup.explicitPreference and d.startup.enabledAfter)
    assert(d.lifecycleReason=='runtime_start' and d.lastOperation==nil)
end)
Test('exported module report includes the reason and target without reading storage',function()
    local S,R,n=Boot();assert(R:SetPreferredEnabled('life_treasure',true,'life_page_toggle'))
    dofile('core/rs_diagnostics.lua');dofile('core/rs_diagnostic_detail.lua');dofile('core/rs_module_diagnostics.lua')
    local reads,writes=n.reads,n.writes
    local text,_,exportText=S.ModuleDiagnosticsHub:BuildReport('life_treasure',{detailed=true})
    assert(text:find('controlPreference=preferred:true/explicit:true/runtime:true',1,true))
    assert(text:find('lastStage:committed/lastTarget:true/lastReason:life_page_toggle',1,true))
    assert(exportText:find('feature.preference["lastOperation"]["reason"]',1,true))
    assert(reads==n.reads and writes==n.writes,'module report changed storage')
end)
Test('searched and skipped ship points and the sea filter survive a fresh login',function()
    local S,R,n=Boot();assert(R:SetPreferredEnabled('life_treasure',true))
    local f=S.Features.Treasure
    assert(f.Commands:SetViewKind('ships'));assert(f.Commands:SetRegion('whale-strait'))
    assert(f.Commands:TrackNearest());local first=f.Authority.selected.key
    assert(f.Commands:VisitAndNext('searched'));local second=f.Authority.selected.key
    assert(f.Commands:VisitAndNext('skipped'))
    local fresh=Boot(n.disk);local restored=fresh.Features.Treasure;local p=restored:GetProjection()
    assert(p.viewKind=='ships' and p.region=='whale-strait','sea filter lost on login')
    assert(p.roundSearched==1 and p.roundSkipped==1 and p.roundRemaining==1 and p.roundTotal==3)
    assert(restored.Authority.visited[first]=='searched' and restored.Authority.visited[second]=='skipped')
    assert(restored.Commands:TrackNearest());assert(restored.Authority.selected.key~=first and restored.Authority.selected.key~=second)
end)
Test('a failed round save keeps the current target and search marks unchanged',function()
    local S,R,n=Boot();assert(R:SetPreferredEnabled('life_treasure',true));local f=S.Features.Treasure
    assert(f.Commands:SetViewKind('ships'));assert(f.Commands:SetRegion('whale-strait'));assert(f.Commands:TrackNearest())
    local key=f.Authority.selected.key;n.failSave=true
    assert(not f.Commands:VisitAndNext('searched'),'failed search save was reported as success')
    assert(f.Authority.selected.key==key and f.Authority.visited[key]==nil and #f.Authority.visitUndo==0)
end)
Test('undo and starting a new round persist without clearing other treasure settings',function()
    local S,R,n=Boot();assert(R:SetPreferredEnabled('life_treasure',true));local f=S.Features.Treasure
    assert(f.Commands:SetRefreshMs(50));assert(f.Commands:SetViewKind('seabugs'))
    assert(f.Commands:SetRegion('silent-sea'));assert(f.Commands:TrackNearest())
    local first=f.Authority.selected.key;assert(f.Commands:VisitAndNext('searched'));assert(f.Commands:UndoVisit())
    local fresh,_,freshNative=Boot(n.disk);local restored=fresh.Features.Treasure
    assert(restored.Authority.visited[first]==nil and restored:GetProjection().refreshMs==50)
    assert(restored.Commands:TrackNearest());assert(restored.Commands:VisitAndNext('searched'));assert(restored.Commands:ResetRound())
    local again=Boot(freshNative.disk)
    assert(again.Features.Treasure:GetProjection().roundVisited==0)
    assert(restored:GetProjection().roundSearched==0)
end)
Test('all catalog point marks fit the existing store budget and survive verified reload',function()
    local S,R,n=Boot();assert(R:SetPreferredEnabled('life_treasure',true));local f=S.Features.Treasure
    local counts=S.TreasureSeaCatalog:Counts();local expected=counts.seabugs+counts.ships
    assert(f.Commands:SetViewKind('ships'));assert(f.Commands:SetRegion('all'))
    for _,kind in ipairs({'seabugs','ships'})do
        for _,point in ipairs(S.TreasureSeaCatalog:List(kind,'all'))do f.Authority.visited[point.key]='searched' end
    end
    local key='ships:whale-strait:1';f.Authority.visited[key]=nil
    assert(f.Commands:Select(key));assert(f.Commands:VisitAndNext('searched'))
    local fresh=Boot(n.disk);local count=0;for _ in pairs(fresh.Features.Treasure.Authority.visited)do count=count+1 end
    assert(count==expected,'round marks truncated at save or reload')
    assert(#fresh.Features.Treasure.State.seaRound.visits<4096,'compact progress exceeded its byte budget')
end)
Test('failed undo and new round keep the saved marks and session undo intact',function()
    local S,R,n=Boot();assert(R:SetPreferredEnabled('life_treasure',true));local f=S.Features.Treasure
    assert(f.Commands:SetViewKind('ships'));assert(f.Commands:SetRegion('whale-strait'));assert(f.Commands:TrackNearest())
    local key=f.Authority.selected.key;assert(f.Commands:VisitAndNext('searched'))
    n.failSave=true
    assert(not f.Commands:UndoVisit());assert(not f.Commands:ResetRound())
    assert(f.Authority.visited[key]=='searched' and #f.Authority.visitUndo==1)
    n.failSave=false;assert(f.Commands:UndoVisit());assert(f.Authority.visited[key]==nil)
end)
local function ShipClock(S,day,hour,minute)
    S.Utils.GetServerTime=function()return {year=2026,month=10,day=day,hour=hour,minute=minute}end
end
Test('ship search time survives login and counts offline time without clearing on a new round',function()
    local S,R,n=Boot();assert(R:SetPreferredEnabled('life_treasure',true));local f=S.Features.Treasure
    ShipClock(S,15,23,30)
    assert(f.Commands:SetShipRespawnMinutes(720));assert(f.Commands:SetViewKind('ships'))
    assert(f.Commands:SetRegion('whale-strait'));assert(f.Commands:TrackNearest())
    local key=f.Authority.selected.key;assert(f.Commands:VisitAndNext('searched'));assert(f.Commands:ResetRound())
    local fresh=Boot(n.disk);local g=fresh.Features.Treasure;ShipClock(fresh,16,0,30)
    g.Authority:UpdateShipClock(true);g.Authority:UpdatePosition()
    local row;for _,r in ipairs(g:GetProjection().rows)do if r.key==key then row=r end end
    assert(row and row.timerStatus=='estimated' and row.remainingMinutes==660,'offline elapsed time was lost')
    assert(g:GetProjection().shipRespawnMinutes==720 and g:GetProjection().roundVisited==0)
    assert(g.Commands:TrackNearest());assert(g.Authority.selected.key~=key,'nearest selected a cooling point')
end)
Test('due ship is eligible again but never presented as confirmed spawned',function()
    local S,R=Boot();assert(R:SetPreferredEnabled('life_treasure',true));local f=S.Features.Treasure
    ShipClock(S,15,10,0);assert(f.Commands:SetShipRespawnMinutes(60));assert(f.Commands:SetViewKind('ships'))
    assert(f.Commands:SetRegion('whale-strait'));assert(f.Commands:TrackNearest())
    local key=f.Authority.selected.key;assert(f.Commands:VisitAndNext('searched'))
    for _,p in ipairs(f.Authority.seaRows)do f.Authority.visited[p.key]='searched' end
    ShipClock(S,15,11,1);assert(f.Commands:TrackNearest());assert(f.Authority.selected.key==key)
    local row;for _,r in ipairs(f:GetProjection().rows)do if r.key==key then row=r end end
    assert(row.timerStatus=='due' and row.timerText:find('可复查',1,true))
    assert(not row.timerText:find('已刷新',1,true))
end)
Test('unknown and backward clock cannot fabricate a countdown and undo restores time',function()
    local S,R,n=Boot();assert(R:SetPreferredEnabled('life_treasure',true));local f=S.Features.Treasure
    assert(f.Commands:SetViewKind('ships'));assert(f.Commands:SetRegion('whale-strait'));ShipClock(S,15,10,0)
    assert(f.Commands:TrackNearest());local key=f.Authority.selected.key
    assert(f.Commands:VisitAndNext('searched'));local stamp=f.Authority.shipSearches[key]
    assert(stamp);assert(f.Commands:UndoVisit());assert(f.Authority.shipSearches[key]==nil)
    assert(f.Commands:VisitAndNext('skipped'));assert(f.Authority.shipSearches[key]==nil,'skip started a loot timer')
    assert(f.Commands:Select(key));assert(f.Commands:VisitAndNext('searched'))
    ShipClock(S,15,9,0);f.Authority:UpdateShipClock(true)
    local row;for _,r in ipairs(f:GetProjection().rows)do if r.key==key then row=r end end
    assert(row.timerStatus=='unknown' and row.remainingMinutes==nil)
    S.Utils.GetServerTime=function()return nil end;f.Authority:UpdateShipClock(true)
    assert(f.Authority.shipNowMinute==nil)
    local reads,writes=n.reads,n.writes;f:GetProjection();f:GetHealth()
    assert(reads==n.reads and writes==n.writes,'timer projection touched storage')
end)
Test('timer saves are atomic and all catalog ship timers fit the real transport',function()
    local S,R,n=Boot();assert(R:SetPreferredEnabled('life_treasure',true));local f=S.Features.Treasure
    local expected=S.TreasureSeaCatalog:Counts().ships
    ShipClock(S,15,10,0);assert(f.Commands:SetViewKind('ships'));assert(f.Commands:SetRegion('all'))
    assert(f.Commands:TrackNearest());local key=f.Authority.selected.key;n.failSave=true
    assert(not f.Commands:VisitAndNext('searched'));assert(f.Authority.shipSearches[key]==nil)
    assert(not f.Commands:SetShipRespawnMinutes(720));assert(f:GetProjection().shipRespawnMinutes==0)
    n.failSave=false;f.Authority:UpdateShipClock(true)
    for _,p in ipairs(S.TreasureSeaCatalog:List('ships','all'))do
        f.Authority.shipSearches[p.key]=f.Authority.shipNowMinute;f.Authority.visited[p.key]='searched'
    end
    for _,p in ipairs(S.TreasureSeaCatalog:List('seabugs','all'))do f.Authority.visited[p.key]='searched' end
    assert(f.Commands:VisitAndNext('searched'))
    local fresh=Boot(n.disk);local count=0;for _ in pairs(fresh.Features.Treasure.Authority.shipSearches)do count=count+1 end
    assert(count==expected,'timers were truncated by persistence transport')
end)
Test('ship clock validates calendar and stays out of projections and compass frames',function()
    local S,R=Boot();assert(R:SetPreferredEnabled('life_treasure',true));local f=S.Features.Treasure
    assert(f.Commands:SetViewKind('ships'));local samples=0
    local time={year=2024,month=2,day=29,hour=23,minute=30}
    S.Utils.GetServerTime=function()samples=samples+1;return time end
    f.Authority:UpdateShipClock(true);local start=f.Authority.shipNowMinute;assert(start)
    time={year=2024,month=3,day=1,hour=0,minute=0};f.Authority:UpdateShipClock(true)
    assert(f.Authority.shipNowMinute-start==30,'leap-day boundary incorrect')
    local before=samples
    for i=1,30 do f:GetProjection();f:GetHealth();f.Authority:UpdateCompass()end
    assert(samples==before,'clock sampled by projection or compass')
    time={year=2023,month=2,day=29,hour=0,minute=0};f.Authority:UpdateShipClock(true)
    assert(f.Authority.shipNowMinute==nil,'invalid calendar date accepted')
end)
Test('circle radius and render distance survive immediate login and failed writes roll back',function()
    local S,R,n=Boot();local f=S.Features.Treasure
    assert(f.State.compassRadius==nil and f.State.renderDistance==nil,'new defaults changed old canonical state')
    assert(f:GetProjection().compassRadius==2.5 and f:GetProjection().renderDistance==60000)
    assert(f.Commands:SetCompassRadius(5.5));assert(f.Commands:SetRenderDistance(750))
    local fresh=Boot(n.disk);local projection=fresh.Features.Treasure:GetProjection()
    assert(projection.compassRadius==5.5 and projection.renderDistance==750,'circle settings lost on immediate cold reload')
    n.failSave=true
    assert(f.Commands:SetCompassRadius(8)==false);assert(f.Commands:SetRenderDistance(1000)==false)
    assert(f:GetProjection().compassRadius==5.5 and f:GetProjection().renderDistance==750,'failed save changed circle settings')
    n.failSave=false;local writes=n.writes
    for _,value in ipairs({0,-1,1001,math.huge,0/0,'invalid'})do assert(f.Commands:SetCompassRadius(value)==false)end
    for _,value in ipairs({0,-1,60001,2.5,math.huge,0/0,'invalid'})do assert(f.Commands:SetRenderDistance(value)==false)end
    assert(n.writes==writes,'invalid input wrote preferences')
end)
Test('draw interval is durable before returning and a rejected save rolls it back',function()
    local S,R,n=Boot();local f=S.Features.Treasure
    assert(f.Commands:SetRefreshMs(17))
    local fresh=Boot(n.disk)
    assert(fresh.Features.Treasure:GetProjection().refreshMs==17,'draw interval lost on immediate cold reload')
    n.failSave=true
    assert(f.Commands:SetRefreshMs(50)==false,'failed durable write reported success')
    assert(f:GetProjection().refreshMs==17,'failed save changed committed draw interval')
end)
print(string.format('TREASURE PREFERENCE RESULT %d passed / %d failed (%s)',passed,failed,_VERSION))
assert(failed==0,'treasure preference regression failures: '..failed)
