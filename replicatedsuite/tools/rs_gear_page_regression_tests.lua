-- 开发期回归：真实布局和命令路径；Native 输入/磁盘是替身，不代表 RU 实机鼠标测试。
local Boot=dofile('tools/rs_gear_page_test_host.lua')
local passed,failed=0,0
local function Test(name,fn)local ok,err=xpcall(fn,function(e)return tostring(e)..'\n'..debug.traceback()end);if ok then passed=passed+1;print('PASS gear page '..name)else failed=failed+1;print('FAIL gear page '..name..': '..err)end end
Test('new and rename rows are arranged and clipped inside visible rail',function()
 local h=Boot()
 for _,id in ipairs({'v3_gear_create_edit','v3_gear_create_button','v3_gear_name_edit','v3_gear_name_button'})do
  local c=h.widgets[id];assert(c.width and c.width>=50,'unarranged '..id);assert(c.height>=22,'collapsed '..id);local ok,err=h:VisibleRect(c);assert(ok,err)
 end
end)
Test('native click create reads live name without Enter then preserves saved name across reload',function()
 local h=Boot();local F=h.F
 h:Type('v3_gear_create_edit','治疗方案');assert(h:Click('v3_gear_create_button'))
 assert(F:GetSetCount()==1 and h.page.draft and h.page.draft.name=='治疗方案')
 h:ReloadStore();assert(F:GetRows()[1].name=='治疗方案')
 assert(h.widgets.v3_gear_create_edit:GetDraftValue()=='')
end)
Test('ambient updates do not erase a new plan name draft',function()
 local h=Boot();h:Type('v3_gear_create_edit','未提交中文草稿')
 for i=1,20 do h.S.Events:Publish('v3.gear.updated',i,'tick');h.page:RefreshData()end
 assert(h.widgets.v3_gear_create_edit:GetDraftValue()=='未提交中文草稿' and h.F:GetSetCount()==0)
end)
Test('leaving page releases both text inputs without creating a plan',function()
 local h=Boot();h:Type('v3_gear_create_edit','不要自动保存');h.page:OnDeactivated()
 assert(h.UI.focused==nil and not h.widgets.v3_gear_create_edit:IsEditing(),'hidden field retained keyboard ownership')
 assert(h.F:GetSetCount()==0)
end)
Test('blank create remains convenient after deleting a different numeric default plan',function()
 local h=Boot();local F=h.F
 assert(F.Commands:CreateSet('换装2'));assert(F.Commands:CreateSet('自定义'));assert(F.Commands:DeleteSet('set_2'))
 assert(h:Click('v3_gear_create_button'),'default name collided with surviving 换装2')
 assert(F:GetSetCount()==2)
end)
Test('RSUI callback preserves explicit false rejection',function()
 local h=Boot();local ok,value=h.S.RSUI:Callback('gear:rejection',function()return false end)
 assert(ok==true and value==false,'rejected command became nil and Button treats it as accepted')
end)
Test('duplicate name remains typed and reports failure next to the visible creation controls',function()
 local h=Boot();assert(h.F.Commands:CreateSet('同名'))
 h:Type('v3_gear_create_edit','同名');local writes=h.writes
 assert(h:Click('v3_gear_create_button')==false,'duplicate command falsely accepted')
 assert(h.F:GetSetCount()==1 and h.writes==writes and h.widgets.v3_gear_create_edit:GetDraftValue()=='同名')
 local feedback=assert(h.widgets.v3_gear_action_feedback,'feedback missing from current viewport')
 assert(feedback.text:find('同名',1,true) or feedback.root.text:find('同名',1,true))
end)
Test('shared ActionRunner receives the domain rejection reason instead of generic action rejected',function()
 local h=Boot();assert(h.F.Commands:CreateSet('同名'))
 h:Type('v3_gear_create_edit','同名');assert(not h:Click('v3_gear_create_button'))
 local found=false
 for _,entry in ipairs(h.logs)do
  if entry[2]=='ACTION_FAILED' and entry[4].action=='gear.create'then
   found=true;assert(entry[3]:find('同名',1,true),'domain reason lost at ActionRunner boundary: '..entry[3])
  end
 end
 assert(found,'missing ActionRunner failure record')
end)
Test('successful creation ends keyboard capture rather than leaving text input active',function()
 local h=Boot();h:Type('v3_gear_create_edit','战斗');assert(h:Click('v3_gear_create_button'))
 assert(h.UI.focused==nil and not h.widgets.v3_gear_create_edit:IsEditing(),'create kept keyboard')
end)

local function Same(a,b)
 if type(a)~=type(b)then return false end
 if type(a)~='table'then return a==b end
 for k,v in pairs(a)do if not Same(v,b[k])then return false end end
 for k in pairs(b)do if a[k]==nil then return false end end
 return true
end
for _,size in ipairs({{600,500},{820,680},{1060,680},{1700,900}})do
 Test('layout remains usable '..size[1]..'x'..size[2],function()
  local h=Boot({width=size[1],height=size[2]})
  for i=1,3 do
   h:Layout(size[1]+(i%2)*80,size[2])
   for _,id in ipairs({'v3_gear_create_edit','v3_gear_create_button','v3_gear_name_edit','v3_gear_name_button'})do
    local c=h.widgets[id];local ok,err=h:VisibleRect(c);assert(ok,err);assert(c.width>=50 and c.height>=22)
   end
   local input,button=h.widgets.v3_gear_create_edit,h.widgets.v3_gear_create_button
   assert(input.x+input.width<=button.x,'create input overlaps button')
  end
 end)
end
Test('rename input remains disabled until a real plan is selected',function()
 local h=Boot();assert(h.widgets.v3_gear_name_edit.enabled==false and h.widgets.v3_gear_name_button.enabled==false)
 assert(h:Click('v3_gear_name_button')==false and h.writes==0)
 assert(h:Click('v3_gear_create_button'));assert(h.widgets.v3_gear_name_edit.enabled and h.widgets.v3_gear_name_button.enabled)
end)
Test('Enter finalizes input draft but does not implicitly create a persistent plan',function()
 local h=Boot();local input=h:Type('v3_gear_create_edit','Enter草稿')
 assert(input.root.events.OnEnterPressed(input.root));assert(h.F:GetSetCount()==0 and h.writes==0)
 assert(h:Click('v3_gear_create_button'));assert(h.F:GetRows()[1].name=='Enter草稿')
end)
Test('empty native input uses a non-empty default even after explicit clear',function()
 local h=Boot();h:Type('v3_gear_create_edit','   ')
 assert(h:Click('v3_gear_create_button'));assert(h.F:GetRows()[1].name=='换装1')
end)
Test('rename reads uncommitted draft and fresh session retains it',function()
 local h=Boot();h:Type('v3_gear_create_edit','原名称');assert(h:Click('v3_gear_create_button'))
 h:Type('v3_gear_name_edit','改名后的治疗装');assert(h:Click('v3_gear_name_button'))
 assert(h.page.draft.name=='改名后的治疗装' and h.UI.focused==nil)
 h.page:OnDeactivated();local n=Boot({disk=h.Copy(h.disk)})
 assert(n.F:GetRows()[1].name=='改名后的治疗装' and n.writes==0)
end)
Test('timer-like refreshes preserve both live rename and create text without writes',function()
 local h=Boot();assert(h:Click('v3_gear_create_button'));h:Type('v3_gear_name_edit','尚未确认的改名');local w=h.writes
 for i=1,50 do h.F.Authority:Refresh('test_event');h:Layout()end
 assert(h.widgets.v3_gear_name_edit:GetDraftValue()=='尚未确认的改名' and h.writes==w)
 assert(h.F:GetRows()[1].name=='换装1')
end)
Test('blur without rename leaves persisted name unchanged',function()
 local h=Boot();assert(h:Click('v3_gear_create_button'));local input=h:Type('v3_gear_name_edit','只编辑没有点击')
 local w=h.writes;input.root.events.OnLostFocus(input.root);h.page:OnDeactivated()
 assert(h.writes==w and h.F:GetRows()[1].name=='换装1')
end)
Test('empty rename rejected with visible error and no save',function()
 local h=Boot();assert(h:Click('v3_gear_create_button'));h:Type('v3_gear_name_edit','');local w=h.writes
 assert(h:Click('v3_gear_name_button')==false and h.writes==w and h.F:GetRows()[1].name=='换装1')
 assert(h.widgets.v3_gear_action_feedback.text:find('不能为空',1,true))
end)
Test('duplicate rename rejected without discarding a useful input draft',function()
 local h=Boot();assert(h.F.Commands:CreateSet('治疗'));assert(h.F.Commands:CreateSet('输出'))
 h.page.selectedId='set_2';assert(h.page:LoadDraft());h.page:Refresh()
 h:Type('v3_gear_name_edit','治疗');local w=h.writes
 assert(not h:Click('v3_gear_name_button') and h.writes==w and h.F:GetRows()[2].name=='输出')
 assert(h.widgets.v3_gear_name_edit:GetDraftValue()=='治疗')
end)
Test('save rejected leaves no ghost plan or consumed persistent identity',function()
 local h=Boot();local state=h.Copy(h.F.State);h.failSave=true;h:Type('v3_gear_create_edit','失败草稿')
 assert(not h:Click('v3_gear_create_button'));assert(Same(state,h.F.State),'partial plan survived rejected save')
 assert(h.page.selectedId==nil and h.widgets.v3_gear_create_edit:GetDraftValue()=='失败草稿')
 assert(h.widgets.v3_gear_create_button.enabled and not h.S.ActionRunner:IsBusy('gear.create'))
 local found=false;for _,entry in ipairs(h.logs)do if entry[2]=='GEAR_PLAN_COMMAND_FAILED'then found=true;assert(entry[4].action=='create')end end;assert(found)
end)
Test('rename save rejection preserves previous persistent and in-memory name',function()
 local h=Boot();assert(h:Click('v3_gear_create_button'));local state=h.Copy(h.F.State);h.failSave=true
 h:Type('v3_gear_name_edit','错误改名');assert(not h:Click('v3_gear_name_button'))
 assert(Same(state,h.F.State) and h.page.draft.name=='换装1')
 assert(h.widgets.v3_gear_name_edit:GetDraftValue()=='错误改名')
end)
Test('create capture save keeps all equipment and title through fresh Store registration',function()
 local h=Boot();h:Type('v3_gear_create_edit','装备与称号');assert(h:Click('v3_gear_create_button'))
 assert(h:Click('v3_gear_capture'));assert(h.equipmentReads==19 and #h.page.draft.items==19)
 assert(h:Click('v3_gear_save'));local draft=h.F:GetDraft(h.page.selectedId);assert(draft.configured and draft.title.effect.id==42)
 local disk=h.Copy(h.disk);h.page:OnDeactivated();local n=Boot({disk=disk})
 local restored=assert(n.F:GetDraft(draft.id));assert(Same(restored.items,draft.items) and Same(restored.title,draft.title))
 assert(restored.name==draft.name and restored.configured and n.writes==0 and n.clears==0)
end)
Test('selection change replaces rename draft but never writes it to wrong set',function()
 local h=Boot();assert(h.F.Commands:CreateSet('方案甲'));assert(h.F.Commands:CreateSet('方案乙'));h.page:Refresh()
 local list=h.widgets.v3_gear_sets;list:SetSelectedIndex(1);h:Type('v3_gear_name_edit','未保存甲');local w=h.writes
 list:SetSelectedIndex(2);assert(h.page.selectedId=='set_2' and h.widgets.v3_gear_name_edit:GetDraftValue()=='方案乙')
 assert(h.UI.focused==nil and h.writes==w and h.F:GetRows()[1].name=='方案甲')
end)
Test('deactivation removes event listener and keyboard then cached page remains usable',function()
 local h=Boot();assert(h:Click('v3_gear_create_button'));h:Type('v3_gear_name_edit','草稿');local w=h.writes
 h.page:OnDeactivated();assert(h.UI.focused==nil and not h.F.transientConsumers['page:gear'])
 for _,entry in ipairs(h.S.Events.internalListeners['v3.gear.updated'] or {})do assert(entry.owner~=h.page)end
 assert(h.page:OnActivated());h:Layout();h:Type('v3_gear_create_edit','第二方案');assert(h:Click('v3_gear_create_button'))
 assert(h.F:GetSetCount()==2 and h.writes==w+1)
end)
Test('scroll to lower groups and back restores hit-testable creation controls',function()
 local h=Boot({height=500});local scroll=h.widgets.v3_gear_left_scroll
 scroll:ScrollToBottom();scroll:ScrollToTop();h:Layout()
 local ok,err=h:VisibleRect(h.widgets.v3_gear_create_button);assert(ok,err)
 assert(h:Click('v3_gear_create_button'))
end)
Test('RSUI callbacks preserve nil true false and zero separately',function()
 local h=Boot();local R=h.S.RSUI
 for _,value in ipairs({true,false,0,''})do local ok,result=R:Callback('value',function()return value end);assert(ok and result==value)end
 local ok,v=R:Callback('void',function()end);assert(ok and v==nil)
 ok,v=R:Callback('throw',function()error('injected_callback_failure')end);assert(not ok and v:find('injected_callback_failure',1,true))
end)
Test('disabled and released create controls never dispatch Store writes',function()
 local h=Boot();h.widgets.v3_gear_create_button:SetEnabled(false);assert(not h:Click('v3_gear_create_button') and h.writes==0)
 h.widgets.v3_gear_create_button:SetEnabled(true);h.page:OnDeactivated();h.page:Release()
 assert(not h:Click('v3_gear_create_button') and h.writes==0)
end)
Test('bounded max plans refusal retains user input and existing plans',function()
 local h=Boot();for i=1,40 do assert(h.F.Commands:CreateSet('测试'..i))end
 local state=h.Copy(h.F.State);local w=h.writes;h:Type('v3_gear_create_edit','第41个')
 assert(not h:Click('v3_gear_create_button') and h.writes==w and Same(h.F.State,state))
 assert(h.widgets.v3_gear_create_edit:GetDraftValue()=='第41个')
end)
print(('GEAR PAGE RESULT %d passed / %d failed (%s)'):format(passed,failed,_VERSION));assert(failed==0,'gear page regressions failed')
