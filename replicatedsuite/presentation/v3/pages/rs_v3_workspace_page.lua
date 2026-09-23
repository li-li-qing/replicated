------------------------------------------------------------------------
-- 个人工作台编辑器（2026-09-18）。仅管理表示偏好；所有业务写入走 Commands。
-- 导航/首页/外观归 Workspace；关注归 Tasks/Activities；启停归 Runtime；窗口归 Host。
-- 控件池固定，操作与可见期事件刷新，无 Tick/Native 采样/GetHealth；重载时无旧订阅。
-- 搜索批量仅作用于当前结果；故障提示保留，不把保存失败伪装成成功。关闭不丢草稿外配置。
------------------------------------------------------------------------
if ReplicatedSuite==nil or ReplicatedSuite.BootError~=nil then return end
local S=ReplicatedSuite
local V=S.UIV3;local R,D=S.RSUI,S.UIV3Design;local W=V and V.Workspace
if not W or not R or not D or not V.PageHost then return end
local Page={requestedTab='navigation',requestedSource='daily'};V.WorkspacePage=Page
local TABS={{value='navigation',text='左侧导航'},{value='home',text='今日总览'},
 {value='lists',text='我的关注'},{value='windows',text='悬浮窗口'},
 {value='features',text='功能状态'},{value='appearance',text='界面外观'}}
local SOURCES={{value='daily',text='日常任务'},{value='weekly',text='周常任务'},{value='activities',text='活动与区域'}}
local FILTERS={{value='all',text='全部条目'},{value='enabled',text='已开启 / 已关注'},
 {value='favorites',text='常用 / 置顶'},{value='hidden',text='隐藏 / 未关注'},{value='faulted',text='运行异常'}}
local function Navigate(route)
 if V.Shell and type(V.Shell.Navigate)=='function'then return V.Shell:Navigate(route,{source='workspace'})end
 return false,'导航不可用'
end
function Page:Open(tab,source)
 self.requestedTab=tab or 'navigation';self.requestedSource=source or self.requestedSource
 return Navigate('system.workspace')
end
local function Text(parent,id,text,height,tone)
 return R:Text({id=id,parent=parent,text=text,fontSize=11,tone=tone or 'muted',overflow='ellipsis',slot={size='fixed',height=height or 24,hAlign='fill'}})
end
function Page:Build(parent,route,initialTab)
 local prefix=route=='system.features' and 'v3_feature_workbench_' or 'v3_workspace_'
 local root,err=D:PageRoot(parent,prefix..'root');if not root then return nil,err end
 root.rows={};root.tab=initialTab or 'navigation';root.source='daily';root.filter=initialTab=='features' and 'enabled' or 'all'
 root.query='';root.revision=0;root.active=false;root.actions={};root.actionButtons={}
 local bar=R:HorizontalBox({id=prefix..'bar',parent=root,gap=6,slot={size='fixed',height=30,hAlign='fill'}})
 R:Text({id=prefix..'title',parent=bar,text='个人工作台',fontSize=15,tone='accent',slot={size='fill',fill=1}})
 local tabs=R:Dropdown({id=prefix..'tabs',parent=bar,items=TABS,maxVisible=6,get=function()return root.tab end,
  set=function(v)return root:SetTab(v)end,slot={size='fixed',width=140}})
 local source=R:Dropdown({id=prefix..'source',parent=bar,items=SOURCES,maxVisible=3,get=function()return root.source end,
  set=function(v)root.source=v;root.selectedId=nil;root.filter='all';return root:Refresh()end,slot={size='fixed',width=130}})
 -- 与页面宿主共用唯一诊断按钮，避免编辑器成为诊断盲区。
 D:ModuleDiagnosticsButton(bar,prefix..'diagnostics',66)
 local summary=Text(root,prefix..'summary','',24)
 local filters=R:HorizontalBox({id=prefix..'filters',parent=root,gap=6,slot={size='fixed',height=30,hAlign='fill'}})
 local query=R:TextInput({id=prefix..'query',parent=filters,placeholder='搜索名称 / 分类',maxLength=96,allowEmpty=true,
  submitOnLostFocus=false,get=function()return root.query end,set=function(v)root.query=tostring(v or '');return true end,
  onSubmit=function()return root:Refresh()end,slot={size='fill',fill=1,minWidth=80}})
 R:Button({id=prefix..'search',parent=filters,text='搜索',compact=true,slot={size='fixed',width=50},
  onClick=function()return query:CommitAndEndEditing('workspace_search')end})
 R:Button({id=prefix..'clear',parent=filters,text='清空',compact=true,slot={size='fixed',width=50},onClick=function()
  query:CancelEditing('workspace_clear');root.query='';query:SetValue('',false);return root:Refresh()end})
 local filter=R:Dropdown({id=prefix..'filter',parent=filters,items=FILTERS,maxVisible=5,get=function()return root.filter end,
  set=function(v)return root:SetFilter(v)end,slot={size='fixed',width=132}})
 local list=R:TableView({id=prefix..'list',parent=root,items={},rowHeight=28,headerHeight=27,desiredRows=12,overscan=1,
  scrollbar=true,selectable=true,selectionMode='single',columnResize=true,headerInteractive=false,
  getKey=function(item)return item and item.id end,
  onSelectionChanged=function(index)
   if root.refreshing then return end
   root.selectedId=root.rows[index or 0] and root.rows[index].id;root:RefreshActions()
  end,
  columns={{id='name',title='名称',field='name',size='fill',fill=2,minWidth=110},
   {id='state',title='状态',field='state',size='fill',fill=1,minWidth=85,getTone=function(row)return row.tone or 'muted'end},
   {id='detail',title='说明',field='detail',size='fill',fill=2,minWidth=100}},
  slot={size='fill',fill=1,hAlign='fill',vAlign='fill'}})
 root.list=list
 local detail=Text(root,prefix..'detail','请选择条目',24)
 for rowIndex=1,2 do
  local row=R:HorizontalBox({id=prefix..'actions_'..rowIndex,parent=root,gap=6,slot={size='fixed',height=30,hAlign='fill'}})
  for column=1,4 do
   local index=(rowIndex-1)*4+column
   root.actionButtons[index]=R:Button({id=prefix..'action_'..index,parent=row,text='',compact=true,enabled=false,
    slot={size='fill',fill=1,minWidth=70},onClick=function()return root:PerformAction(index)end})
  end
 end
 local message=Text(root,prefix..'message','修改即保存；只改变界面或明确选中的功能，不隐式启动其他模块。',26)
 root.message=message
 function root:Selected()for _,row in ipairs(self.rows)do if row.id==self.selectedId then return row end end end
 function root:SelectId(id)
  for index,row in ipairs(self.rows)do if row.id==id then self.selectedId=id;self.list:SetSelectedIndex(index);self:RefreshActions();return true end end
  return false,'条目不在当前结果中'
 end
 function root:SetTab(tab)
  local known=false;for _,item in ipairs(TABS)do if item.value==tab then known=true end end;if not known then return false,'未知页面'end
  query:CancelEditing('workspace_tab');self.tab=tab;self.filter=tab=='features' and 'enabled' or 'all';self.query='';self.selectedId=nil
  query:SetValue('',false);tabs:Render();return self:Refresh()
 end
 function root:SetFilter(value)self.filter=value;self.selectedId=nil;return self:Refresh()end
 local function Matches(row)
  local q=root.query:lower();if q~='' and not (tostring(row.name)..' '..tostring(row.category or '')..' '..tostring(row.id)):lower():find(q,1,true)then return false end
  local f=root.filter
  if f=='all'then return true end
  if f=='enabled'then return row.enabled==true or row.tracked==true or row.visible==true end
  if f=='favorites'then return row.favorite==true or row.pinned==true end
  if f=='hidden'then return row.hidden==true or row.tracked==false or row.visible==false end
  return f=='faulted' and row.faulted==true
 end
 function root:CollectRows()
  local rows={};local tab=self.tab
  if tab=='navigation'then
   for _,r in ipairs(W:GetNavigation('all'))do
    local pref=W:GetNavPreference(r.id);local meta=S.FeatureRegistry:GetByRoute(r.id)
    local state=W:ReadControl(meta and (meta.controlFeatureId~='' and meta.controlFeatureId or meta.id) or r.featureId)
    rows[#rows+1]={id=r.id,name=r.navigationTitle or r.title,category=r.category,route=r.id,
     favorite=pref.favorite,hidden=pref.hidden,enabled=state.enabled,faulted=state.faulted,
     state=state.enabled and '已开启' or '已关闭',tone=state.enabled and 'green' or 'red',
     detail=(pref.favorite and '常用 · ' or '')..(pref.hidden and '导航隐藏' or '导航显示')..(r.id=='home' and ' · 固定入口' or '')}
   end
   -- 所有目录不丢隐藏项；用真实用户顺序排列可见部分，恢复入口始终可达。
   local rank={};for i,r in ipairs(W:GetNavigation('custom'))do rank[r.id]=i end
   table.sort(rows,function(a,b)local x,y=rank[a.id] or 9999,rank[b.id] or 9999;if x==y then return a.id<b.id end;return x<y end)
  elseif tab=='home'then
   for _,r in ipairs(W:GetCards(true))do r.state=r.visible and '已显示' or '已隐藏';r.tone=r.visible and 'green' or 'muted';r.detail='只管理卡片，不改变功能开关';rows[#rows+1]=r end
  elseif tab=='lists'then
   local feature=self.source=='activities' and S.Features.Activities or S.Features.Tasks
   local result,why={},nil
   -- 多返回值不能经 and/or 表达式传递，显式读取错误，防止坏存档被当作空目录。
   if feature and feature.GetAttentionCatalog then result,why=feature:GetAttentionCatalog(self.source)else why='此模块未提供关注目录'end
   if why then return {},why end
   local listId=self.source=='activities' and 'activities' or 'tasks';local opt=W:GetListOption(listId)
   for _,r in ipairs(result)do r.pinned=opt.pinned[W:GetListKey(listId,r)]==true;r.state=r.tracked and '已关注' or '未关注';r.tone=r.tracked and 'green' or 'muted'
    r.detail=(r.pinned and '置顶 · ' or '')..r.category;rows[#rows+1]=r end
   rows=W:ProjectRows(listId,rows,true)
  elseif tab=='features'then
   rows=W:GetFeatureRows('all');for _,r in ipairs(rows)do r.tone=r.faulted and 'red' or r.enabled and 'green' or 'muted';r.detail='性能：'..r.performance..'（预估）';r.favorite=W:GetNavPreference(r.route).favorite end
  elseif tab=='windows'then
   rows=W:GetWindowRows();for _,r in ipairs(rows)do r.tone=r.visible and 'green' or 'muted';r.detail=(r.locked and '已锁定' or '可拖动')..' · '..r.id end
  else
   local settings=W:GetSettings()
   for _,v in ipairs({{'dark','经典深色','保留原有默认风格'},{'gold','暖金深色','深色底与暖金强调'},{'contrast','高对比','提高文字与边界对比'}})do
    rows[#rows+1]={id=v[1],name=v[2],state=settings.appearance==v[1] and '使用中' or '可选择',detail=v[3],tone=settings.appearance==v[1] and 'green' or 'muted'}
   end
  end
  local out={};for _,row in ipairs(rows)do if tab=='appearance' or tab=='home' or Matches(row)then out[#out+1]=row end end
  return out
 end
 function root:RefreshActions()
  local item=self:Selected();local actions={};local tab=self.tab;local has=item~=nil
  local function Add(text,fn,enabled)actions[#actions+1]={text=text,execute=fn,enabled=enabled~=false}end
  local function Route()return item and Navigate(item.route)end
  if tab=='navigation'then
   local editable=has and item.id~='home'
   Add(has and item.favorite and '取消常用' or '加入常用',function()return W:SetNavigation(item.id,'favorite',not item.favorite)end,editable)
   Add(has and item.hidden and '恢复到导航' or '隐藏导航',function()return W:SetNavigation(item.id,'hidden',not item.hidden)end,editable)
   Add('上移',function()return W:MoveNavigation(item.id,-1)end,editable and not item.hidden)
   Add('下移',function()return W:MoveNavigation(item.id,1)end,editable and not item.hidden)
   Add('打开页面',Route,has);Add('恢复默认导航',function()return W:Reset('navigation')end)
  elseif tab=='home'then
   Add(has and item.visible and '隐藏卡片' or '显示卡片',function()return W:SetCardVisible(item.id,not item.visible)end,has)
   Add('上移',function()return W:MoveCard(item.id,-1)end,has);Add('下移',function()return W:MoveCard(item.id,1)end,has)
   Add('恢复默认首页',function()return W:Reset('home')end)
   local show=W:GetSettings().home.stats
   Add(show and '隐藏资源摘要' or '显示资源摘要',function()return W:SetOption('stats',not show)end)
   Add('打开今日总览',function()return Navigate('home')end)
  elseif tab=='lists'then
   local listId=self.source=='activities' and 'activities' or 'tasks';local opt=W:GetListOption(listId)
   local function Batch(selected,enabled)
    local keys={};for _,row in ipairs(selected)do keys[#keys+1]=root.source=='activities' and row.id or row.key end
    local F=root.source=='activities' and S.Features.Activities or S.Features.Tasks
    if root.source=='activities'then return F.Commands:SetAttention(keys,enabled)end
    return F.Commands:SetAttention(root.source,keys,enabled)
   end
   Add(has and item.tracked and '取消关注' or '加入关注',function()return Batch({item},not item.tracked)end,has)
   Add('关注当前结果',function()return Batch(root.rows,true)end,#root.rows>0)
   Add('取消当前结果',function()return Batch(root.rows,false)end,#root.rows>0)
   Add(has and item.pinned and '取消置顶' or '置顶',function()return W:ToggleListPin(listId,W:GetListKey(listId,item))end,has)
   Add('上移',function()return W:MoveList(listId,root.rows,W:GetListKey(listId,item),-1)end,has)
   Add('下移',function()return W:MoveList(listId,root.rows,W:GetListKey(listId,item),1)end,has)
   Add(opt.manual and '改为自动排序' or '改为手动排序',function()return W:SetListOption(listId,'manual',not opt.manual)end)
   if listId=='tasks'then Add(opt.hideCompleted and '显示已完成' or '隐藏已完成',function()return W:SetListOption(listId,'hideCompleted',not opt.hideCompleted)end)end
  elseif tab=='features'then
   Add(has and item.enabled and '关闭功能' or '启用功能',function()return S.FeatureRuntime:SetPreferredEnabled(item.id,not item.enabled,'workspace_manager')end,
    has and (item.enabled or item.implemented and not item.blocked))
   Add('打开模块',Route,has)
   Add('模块诊断',function()return V.ModuleControlsV3:OpenDiagnostics(item.id,item.route)end,has and V.ModuleControlsV3~=nil)
   Add('查看全部',function()return root:SetFilter('all')end)
  elseif tab=='windows'then
   local host=V.WidgetHost;local enabled=has and (item.featureId=='' or W:ReadControl(item.featureId).enabled)
   Add(has and item.visible and '隐藏窗口' or '显示窗口',function()return host:SetVisible(item.id,not item.visible,{source='workspace'})end,has and (item.visible or enabled))
   Add(has and item.minimized and '展开窗口' or '收起窗口',function()return host:SetMinimized(item.id,not item.minimized,true)end,has and item.visible and item.minimizable)
   Add(has and item.locked and '解除锁定' or '锁定窗口',function()return host:SetLocked(item.id,not item.locked,true)end,has and item.created and item.lockable)
   Add('复位位置',function()return host:ResetLayout(item.id)end,has and item.resettable)
   Add('模块设置',Route,has and item.route~=nil)
   Add('精细外观设置',function()return Navigate('system.widgets')end)
  else
   Add('应用选中主题',function()return W:SetOption('appearance',item.id)end,has)
   Add('紧凑密度',function()return W:SetOption('density','compact')end)
   Add('标准密度',function()return W:SetOption('density','standard')end)
   Add('恢复默认外观',function()return W:Reset('appearance')end)
   Add('全局字号 / 缩放',function()return Navigate('system.settings')end)
  end
  self.actions=actions
  for i,button in ipairs(self.actionButtons)do local action=actions[i];button:SetVisible(action~=nil);button:SetText(action and action.text or '');button:SetEnabled(action and action.enabled or false)end
  detail:SetText(has and (item.name..' · '..tostring(item.state)..' · '..tostring(item.detail or '')) or '请选择条目；隐藏项可在“全部条目”中恢复。')
  return true
 end
 function root:PerformAction(index)
  local action=self.actions[index];if not action or not action.enabled or self.busy then return false,'当前操作不可用'end
  self.busy=true
  local ok,value,why=xpcall(action.execute,S.SafeTraceback or tostring)
  self.busy=false
  local success=ok and value~=false
  self:Refresh()
  message:SetText(success and '操作已提交；当前列表显示实际状态。' or ('操作未完成：'..tostring(ok and why or value)))
  message:SetTone(success and 'muted' or 'red')
  return success,why
 end
 function root:Refresh()
  if self.refreshing or self.busy then return true end
  self.refreshing=true;self.revision=self.revision+1
  -- 目录仍由业务模块提供；异常只降级当前工作台，不遗留刷新锁或修改关注。
  local ok,rows,why=pcall(self.CollectRows,self)
  if not ok then why=rows;rows={} end
  self.rows=rows
  if not self:Selected()then self.selectedId=nil end
  source:SetVisible(self.tab=='lists');source:Render();tabs:Render();filter:SetVisible(self.tab~='appearance' and self.tab~='home');filter:Render()
  -- 行密度只改变本页池化 ListView 的度量，不覆盖业务窗口字号/存档。
  if list.list and list.list.SetRowHeight then list.list:SetRowHeight(W:GetSettings().density=='compact' and 24 or 30)end
  list:SetItems(rows,self.revision)
  local index;for i,row in ipairs(rows)do if row.id==self.selectedId then index=i end end;list:SetSelectedIndex(index)
  list:SetViewState(#rows>0 and 'ready' or 'empty',{title='没有匹配条目',detail='清空搜索或切换“全部条目”，不会自动开启功能。'})
  local notices={navigation='常用置顶；隐藏仅改变导航，不关闭功能。首页和系统入口固定保留。',
   home='卡片顺序与显示单独保存。首页只消费已有模块数据。',
   lists='批量仅改变当前搜索/筛选结果；日常与周常独立，置顶和排列与悬浮窗共享。',
   windows='隐藏 / 收起不等于停用。未启用的模块请从“模块设置”明确开启。',
   features='只读取实际启停和故障标记，不执行全量自检。性能等级为预估。',
   appearance='主题只改变配色。密度作用于工作台与首页，不覆盖各窗口字号、位置、透明度。'}
  summary:SetText(tostring(#rows)..' 项 · '..notices[self.tab]);self.refreshing=false;self:RefreshActions()
  if why then message:SetText('读取受保护：'..tostring(why));message:SetTone('red')end
  return true
 end
 function root:OnRoute()
  if route~='system.features' then
   self.source=Page.requestedSource
   if self.active then return self:SetTab(Page.requestedTab)end
  end
  return true
 end
 function root:OnActivated()
  if self.active then return self:Refresh()end
  self.active=true
  if route~='system.features'then self.tab=Page.requestedTab;self.source=Page.requestedSource;self.filter=self.tab=='features' and 'enabled' or 'all'end
  if S.Events then for _,topic in ipairs({'v3.workspace.updated','v3.feature.lifecycle','v3.widgets.changed','v3.tasks.updated','v3.activities.updated'})do
   local watched=topic
   S.Events:SubscribeInternal(watched,self,function(_,_,reason)
    -- 活动秒级投影不改变关注目录；管理器没有必要为倒计时重建整张目录。
    if watched=='v3.tasks.updated' or watched=='v3.activities.updated'then
     if root.tab~='lists' or not ({attention_changed=true,tracking_changed=true,tracking_all_changed=true,hide_event=true,restore_hidden=true})[reason]then return true end
    end
    if root.active then return root:Refresh()end
   end)
  end end
  return self:Refresh()
 end
 function root:OnDeactivated()self.active=false;query:CancelEditing('workspace_hidden');if S.Events then S.Events:UnsubscribeInternalOwner(self)end;return true end
 root.OnDispose=root.OnDeactivated;root.route=route
 return root
end
V.PageHost:RegisterFactory('system.workspace',function(parent,route)return Page:Build(parent,route)end)
