-- Real API gate / GearV3 / Demand / Scheduler / Events; only Native values are fixtures.
-- Equipment/assignment shapes come from the user's working 1.2 Character service.
local passed,total=0,0
local function Test(name,fn)
 total=total+1;local ok,err=xpcall(fn,debug.traceback)
 if ok then passed=passed+1;print('PASS reminders '..name)else print('FAIL reminders '..name..': '..tostring(err))end
end
local function Time(day,hour,minute,second)
 return {year=0,month=0,day=day or 0,hour=hour or 0,minute=minute or 0,second=second or 0}
end
local function Boot()
 local h=dofile('tools/rs_gear_page_test_host.lua')();local S=h.S
 dofile('core/rs_demand.lua');dofile('core/rs_refresh_coordinator.lua')
 ADDON.ImportAPI=function()return true end;ADDON.ImportObject=function()return true end
 dofile('native/rs_native_contract.lua');dofile('native/rs_native_imports.lua')
 ES_COSPLAY,ES_UNDERPANTS,EST_COSPLAY,EST_UNDERPANTS='costume','underwear',nil,nil
 TADT_TODAY,TADT_EXPEDITION='daily','guild'
 h.costume={name='测试时装',evolvingInfo={remainTime=Time(2,3)}}
 h.underwear={name='测试内衣',evolvingInfo={remainTime=Time()}}
 h.assignments={daily={},guild={}};h.nativeReads=0
 for _,kind in ipairs({'daily','guild'})do for i=1,7 do h.assignments[kind][i]={status=2}end end
 X2Equipment.GetEquippedItemTooltipInfo=function(_,slot,selector)
  h.nativeReads=h.nativeReads+1;assert(selector==false,'reminder used the loadout selector')
  if h.equipmentError then error('equipment_unavailable')end
  return h.Copy(slot=='costume' and h.costume or h.underwear)
 end
 X2Achievement={GetTodayAssignmentInfo=function(_,kind,index)
  h.nativeReads=h.nativeReads+1
  if h.assignmentError then error('assignment_unavailable')end
  if h.failedIndex==index then error('assignment_partial')end
  return h.Copy(h.assignments[kind][index])
 end}
 local file=io.open('services/rs_home_reminders_v3.lua','r')
 assert(file,'reminder read model is not implemented');file:close()
 dofile('services/rs_home_reminders_v3.lua');h.C=assert(S.Services.HomeRemindersV3)
 function h:Acquire(token)return self.C:AcquireConsumer(token or 'test')end
 function h:Row(key)
  for _,row in ipairs(self.C:GetProjection().rows)do if row.key==key then return row end end
  error('reminder row missing: '..key)
 end
 return h,S,h.C
end
Test('real foundation gate accepts reminder service boundary and rejects a missing declaration',function()
 local h,S,C=Boot();local writes=h.writes
 -- 只替换门禁的无关基础设施；服务实例和 service_presentation_boundary 判定使用生产实现。
 ReplicatedSuite={Features={},Services={HomeRemindersV3=C},SafeTraceback=debug.traceback}
 dofile('core/rs_foundation_gate.lua');local gate=ReplicatedSuite.FoundationGate
 local function Check()
  local report=gate:Run({skipSequences=true})
  for _,row in ipairs(report.checks)do if row.id=='service_presentation_boundary'then return row end end
  error('service boundary gate was not executed')
 end
 local row=Check();assert(row.ok,'reminder blocked the real gate: '..row.detail)
 C.presentationBoundary=nil;row=Check()
 assert(not row.ok and row.severity=='blocker' and row.detail:find('HomeRemindersV3:missing',1,true),'missing declaration bypassed the gate')
 C.presentationBoundary='service_only';assert(Check().ok)
 assert(h.nativeReads==0 and h.writes==writes and not C.running,'read-only boundary check started reminders or wrote a store')
 ReplicatedSuite=S
end)
Test('dormant service neither reads Native nor writes a store',function()
 local h,S,C=Boot();local writes=h.writes
 assert(h.nativeReads==0 and not S.Scheduler.tasks[C.taskName])
 assert(#C:GetProjection().rows==4 and h.writes==writes)
 assert(C:Refresh('manual')==false and h.nativeReads==0,'hidden manual refresh scanned Native')
end)
Test('first visible lease reads only two equipment slots and fourteen assignments',function()
 local h,S,C=Boot();local writes=h.writes;assert(h:Acquire())
 assert(h.nativeReads==16 and S.Scheduler.tasks[C.taskName].intervalMs>=30000)
 assert(h:Row('costume').text=='剩余 2天 3小时' and h:Row('underwear').status=='expired')
 assert(h:Row('daily').status=='accepted' and h:Row('guild').text=='已接 7/7')
 assert(h.writes==writes,'read-only reminders wrote configuration')
end)
Test('identified equipped item without a countdown is permanent while partial time remains unknown',function()
 local h=Boot();h.costume={itemType=90001,name='永久时装'};h.underwear={name='内衣',evolvingInfo={remainTime={day=0}}}
 assert(h:Acquire());assert(h:Row('costume').status=='permanent' and h:Row('underwear').status=='unknown')
 assert(h:Row('costume').text=='永久' and h:Row('costume').available and h:Row('costume').tone=='green')
 assert(h:Row('costume').expirationEvidence.policy=='identified_item_without_countdown')
end)
Test('permanent underwear and costume with modifiers do not require an evolving countdown',function()
 local h=Boot();h.costume={name='时装',evolvingInfo={modifier={{name='strength',value=10}}}};h.underwear={itemType=90002,evolvingInfo={}}
 assert(h:Acquire());assert(h:Row('costume').status=='permanent' and h:Row('underwear').status=='permanent')
 h.costume.evolvingInfo.remainTime=Time(1);assert(h.C:Refresh('equipment_change'))
 assert(h:Row('costume').status=='expiring' and h:Row('costume').text=='剩余 1天','permanent status stuck after changing equipment')
end)
Test('malformed equipment and countdown cannot masquerade as permanent',function()
 for _,info in ipairs({{icon='only_icon'},{name='时装',evolvingInfo='invalid'},{name='时装',evolvingInfo={remainTime=false}},
  {name='时装',evolvingInfo={remainTime={}}},{name='时装',evolvingInfo={remainTime={day=0}}}})do
  local h=Boot();h.costume=info;assert(h:Acquire());assert(h:Row('costume').status=='unknown')
 end
end)
Test('Native read failure cannot masquerade as empty equipment',function()
 local h=Boot();h.equipmentError=true;assert(h:Acquire())
 assert(h:Row('costume').status=='unknown' and h:Row('underwear').status=='unknown')
 h.equipmentError=false;h.costume=nil;h.underwear={};assert(h.C:Refresh('manual'))
 assert(h:Row('costume').status=='empty' and h:Row('underwear').text=='未装备')
end)
Test('invalid expiry fields remain unknown while near expiry is highlighted',function()
 local h=Boot();h.costume.evolvingInfo.remainTime=Time(0,2,5);h.underwear.evolvingInfo.remainTime=Time(-1)
 assert(h:Acquire());assert(h:Row('costume').status=='expiring' and h:Row('costume').tone=='orange')
 assert(h:Row('underwear').status=='unknown')
end)
Test('daily and guild acceptance are counted separately with explicit pending reminders',function()
 local h=Boot();h.assignments.daily[1].status=1;h.assignments.daily[2].status=1
 for i=1,7 do h.assignments.guild[i].status=3 end
 assert(h:Acquire());assert(h:Row('daily').pending==2 and h:Row('daily').text=='还有 2项未接')
 assert(h:Row('guild').status=='completed' and h:Row('guild').text=='已完成 7/7')
end)
Test('one failed assignment never produces a false all-accepted result',function()
 local h=Boot();h.failedIndex=4;assert(h:Acquire())
 assert(h:Row('daily').status=='partial' and h:Row('daily').unknown==1)
 assert(h:Row('daily').text:find('待确认',1,true))
 local evidence=h.C:GetHealth().rows;assert(#evidence==4,'missing diagnostic evidence')
end)
Test('missing assignments and unrecognized status codes remain unknown',function()
 local h=Boot();h.assignments.daily={};h.assignments.guild[2]={status=99}
 assert(h:Acquire());assert(h:Row('daily').status=='unknown' and h:Row('guild').status=='partial')
end)
Test('missing Native constants are not replaced with guessed numbers',function()
 local h=Boot();ES_COSPLAY,ES_UNDERPANTS,TADT_TODAY,TADT_EXPEDITION=nil,nil,nil,nil
 assert(h:Acquire());assert(h.nativeReads==0 and h:Row('costume').status=='unknown')
end)
Test('EST slot types cannot replace missing ES equipment slots',function()
 local h=Boot();ES_COSPLAY,ES_UNDERPANTS=nil,nil;EST_COSPLAY,EST_UNDERPANTS='wrong_type_a','wrong_type_b'
 assert(h:Acquire());assert(h.nativeReads==14 and h:Row('costume').status=='unknown')
end)
Test('projection and diagnostics are detached read-only snapshots',function()
 local h,S,C=Boot();assert(h:Acquire());local reads,writes=h.nativeReads,h.writes
 local p=C:GetProjection();p.rows[1].status='tampered';local d=C:GetHealth();d.rows[1].status='tampered'
 assert(h:Row('costume').status=='valid' and h.nativeReads==reads and h.writes==writes)
end)
Test('two views share one task and releasing one retains the other view',function()
 local h,S,C=Boot();assert(h:Acquire('a'));local reads=h.nativeReads;local task=S.Scheduler.tasks[C.taskName]
 assert(h:Acquire('a'));assert(h:Acquire('b'));assert(h.nativeReads==reads and S.Scheduler.tasks[C.taskName]==task)
 assert(C:ReleaseConsumer('a') and S.Scheduler.tasks[C.taskName])
 assert(C:ReleaseConsumer('b') and not S.Scheduler.tasks[C.taskName])
 assert(h:Row('costume').status=='unknown','hidden service leaked old availability')
end)
Test('event bursts coalesce and release invalidates old refresh callbacks',function()
 local h,S,C=Boot();assert(h:Acquire());local reads=h.nativeReads
 for i=1,20 do S.Events:Dispatch('UNIT_EQUIPMENT_CHANGED','player')end
 assert(h.nativeReads==reads,'event burst scanned synchronously')
 local task=S.Scheduler.tasks[C.taskName]
 assert(C:ReleaseConsumer('test'));assert(h:Acquire('new'))
 reads=h.nativeReads;task.callback();assert(h.nativeReads==reads,'old callback used a new lease')
 assert(C:ReleaseConsumer('new'));assert(C:Refresh('manual')==false and h.nativeReads==reads)
end)
Test('lazy Native imports precede reading equipment slots and assignment constants',function()
 local h,S,C=Boot();local equipment,achievement=X2Equipment,X2Achievement
 X2Equipment,X2Achievement,ES_COSPLAY,ES_UNDERPANTS,TADT_TODAY,TADT_EXPEDITION=nil,nil,nil,nil,nil,nil
 local imported={}
 dofile('native/rs_native_contract.lua');dofile('native/rs_native_imports.lua')
 ADDON.ImportAPI=function(_,id)
  imported[id]=(imported[id] or 0)+1
  if id==13 then X2Equipment=equipment;ES_COSPLAY,ES_UNDERPANTS='costume','underwear'
  elseif id==67 then X2Achievement=achievement;TADT_TODAY,TADT_EXPEDITION='daily','guild'
  else error('unrelated namespace import')end
  return true
 end
 assert(next(imported)==nil);assert(h:Acquire())
 assert(imported[13]==1 and imported[67]==1,'reminders did not own lazy imports')
 assert(h:Row('costume').status=='valid' and h:Row('daily').status=='accepted')
 assert(#S.NativeImports:GetOwnerApis(C.Id)==2)
end)
Test('optional assignment import failure leaves equipment usable and assignments unknown',function()
 local h,S,C=Boot();dofile('native/rs_native_contract.lua');dofile('native/rs_native_imports.lua')
 ADDON.ImportAPI=function(_,id)return id~=67 end
 assert(h:Acquire());assert(h:Row('costume').status=='valid')
 assert(h:Row('daily').status=='unknown' and h.nativeReads==2,'failed import used a foreign or stale global')
end)
Test('changed session generation rejects an already captured callback',function()
 local h,S,C=Boot();assert(h:Acquire());local task=S.Scheduler.tasks[C.taskName];local reads=h.nativeReads
 S.Generation=S.Generation+1;task.callback();assert(h.nativeReads==reads)
end)
print(string.format('HOME_REMINDERS: %d/%d passed (%s)',passed,total,_VERSION))
if passed~=total then error('home reminders regressions')end
