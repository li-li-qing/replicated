-- Real Persistence; controlled Native host. Never loaded by toc.g.
local pass,fail=0,0
local function Test(n,fn)local ok,e=xpcall(fn,debug.traceback);if ok then pass=pass+1;print('PASS workspace '..n)else fail=fail+1;print('FAIL workspace '..n..': '..tostring(e))end end
local function Boot(disk)
 local h=dofile('tools/rs_gear_page_test_host.lua')({disk=disk});local S=h.S
 dofile('features/rs_feature_registry.lua');dofile('presentation/v3/navigation/rs_v3_router.lua')
 S.FeatureRuntime.GetControlState=function(_,id)return {implemented=true,enabled=id=='life_tasks',faulted=false}end
 S.FeatureRuntime.SetPreferredEnabled=function()error('preference changed runtime')end
 dofile('presentation/v3/rs_v3_workspace.lua')
 local W=assert(S.UIV3.Workspace,'workspace model missing');assert(W:EnsureLoaded());return W,S,h
end
Test('home recoverable; hidden registry routes never reappear',function()
 local W=Boot();assert(W:SetNavigation('home','hidden',true)==false)
 assert(W:SetNavigation('combat.target_monitor','favorite',true)==false)
 local rows=W:GetNavigation('all');for _,r in ipairs(rows)do assert(r.id~='combat.target_monitor')end;assert(#rows>10)
end)
Test('favorite first; hidden custom only; reset without business writes',function()
 local W=Boot();assert(W:SetNavigation('life.tasks','favorite',true));assert(W:GetNavigation('custom')[2].id=='life.tasks')
 assert(W:SetNavigation('life.tasks','hidden',true));for _,r in ipairs(W:GetNavigation('custom'))do assert(r.id~='life.tasks')end
 local found=false;for _,r in ipairs(W:GetNavigation('all'))do if r.id=='life.tasks'then found=true end end;assert(found)
 assert(W:Reset('navigation'));assert(W:GetNavPreference('life.tasks').favorite~=true)
end)
Test('enabled filter actual state',function()
 local W=Boot();local found=false;for _,r in ipairs(W:GetNavigation('enabled'))do if r.id~='home'then assert(r.id=='life.tasks');found=true end end;assert(found)
end)
Test('navigation order durable and reload',function()
 local W,S,h=Boot();assert(W:SetNavigation('life.tasks','favorite',true));assert(W:SetNavigation('life.fishing','favorite',true))
 assert(W:MoveNavigation('life.fishing',-1));assert(W:GetNavigation('custom')[2].id=='life.fishing')
 local W2=Boot(h.disk);assert(W2:GetNavigation('custom')[2].id=='life.fishing')
end)
Test('failed write rollback',function()
 local W,S,h=Boot();h.failSave=true;local ok=W:SetNavigation('life.tasks','favorite',true);assert(ok==false);assert(W:GetNavPreference('life.tasks').favorite~=true)
end)
Test('empty cards remain empty and resets isolated',function()
 local W=Boot();assert(W:SetNavigation('life.tasks','favorite',true));for _,c in ipairs(W:GetCards(true))do assert(W:SetCardVisible(c.id,false))end
 assert(#W:GetCards()==0);assert(W:Reset('home'));assert(#W:GetCards()==5);assert(W:GetNavPreference('life.tasks').favorite)
end)
Test('list sorting preserves authority rows',function()
 local W=Boot();local rows={{id='daily:a',rawName='甲',status='未接'},{id='daily:b',rawName='乙',status='已完成'}}
 assert(W:SetListOption('tasks','hideCompleted',true));local out=W:ProjectRows('tasks',rows);assert(#out==1 and #rows==2)
 assert(W:SetListOption('tasks','hideCompleted',false));assert(W:ToggleListPin('tasks','daily:b'));out=W:ProjectRows('tasks',rows);assert(out[1].id=='daily:b' and rows[1].id=='daily:a')
end)
Test('running summary excludes shell and duplicates',function()
 local W,S=Boot();local summary=W:GetRunningSummary();assert(summary.enabled==1 and summary.faulted==0)
 for _,r in ipairs(W:GetFeatureRows('all'))do assert(r.id~='home' and r.id~='system_settings')end
end)
Test('list move respects pin bucket and preserves other scope order',function()
 local W=Boot();local rows={{id='daily:p'},{id='daily:a'},{id='daily:b'}}
 assert(W:ToggleListPin('tasks','daily:p'))
 assert(W:Change('lists',function()W.state.lists.tasks.order={'weekly:x','weekly:y'};return true end))
 assert(W:MoveList('tasks',rows,'daily:p',1)==false,'one pinned row cannot move into unpinned section')
 assert(W:MoveList('tasks',rows,'daily:b',-1));local view=W:ProjectRows('tasks',rows)
 assert(view[1].id=='daily:p' and view[2].id=='daily:b')
 local other=W:ProjectRows('tasks',{{id='weekly:y'},{id='weekly:x'}});assert(other[1].id=='weekly:x')
 assert(rows[2].id=='daily:a','source projection was mutated')
end)
Test('same-parent reorder rejects foreign forged membership and retains native identity',function()
 local W,S,h=Boot();local R=S.RSUI;local parent=R:VerticalBox({id='order_parent',parent=h.Native(nil,'order_native',0,0,400,400)})
 local a=R:Text({id='order_a',parent=parent,text='A'});local b=R:Text({id='order_b',parent=parent,text='B'})
 local native=a.root;assert(parent:ReorderChildren({b,a}));assert(parent.children[1]==b and parent.slots[1].child==b and a.root==native)
 assert(parent:ReorderChildren({b,b})==false);assert(parent.children[1]==b)
 assert(parent:ReorderChildren({{parentComponent=parent}})==false,'forged child was accepted')
 assert(#parent.children==2)
end)
Test('enabled navigation still reveals a deliberately hidden running feature',function()
 local W=Boot();assert(W:SetNavigation('life.tasks','hidden',true))
 local found=false;for _,r in ipairs(W:GetNavigation('enabled'))do if r.id=='life.tasks'then found=true end end
 assert(found,'enabled filter masked an actually running hidden feature')
end)
print('WORKSPACE RESULT '..pass..' passed / '..fail..' failed ('.._VERSION..')');if fail>0 then error('workspace failures '..fail)end
