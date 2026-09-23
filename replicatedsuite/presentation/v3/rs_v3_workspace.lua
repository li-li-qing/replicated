------------------------------------------------------------------------
-- 个人工作台：仅拥有 Presentation 偏好与只读投影（2026-09-18）。
-- 原因：导航、首页及列表选择过去分散且无法恢复隐藏。Authority：启停仍属
-- FeatureRuntime，窗口仍属 WidgetHost，关注仍属业务 Store。本 Store 不保存
-- Enabled/进度/几何，不调用游戏 API；失败保留原存档写保护，不猜指纹、不重置业务。
-- 所有投影有界，只有显式操作耐久写入；不新增 Tick/扫描/全量诊断。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.UIV3 = S.UIV3 or {}
local W = { version=1, revision=0, loaded=false, storeId='v3.workspace' }
S.UIV3.Workspace = W
local P = S.Persistence
local CARDS = {
 {id='daily',name='日常任务',feature='Tasks',featureId='life_tasks',route='life.tasks',widget='life.tasks',scope='daily'},
 {id='weekly',name='周常任务',feature='Tasks',featureId='life_tasks',route='life.tasks',widget='life.tasks',scope='weekly'},
 {id='activities',name='活动 / 世界状态',feature='Activities',featureId='life_activities',route='life.activities',widget='life.activities'},
 {id='bonds',name='债券 / 居民板',feature='Bonds',featureId='life_bonds',route='life.bonds',widget='life.bonds'},
 {id='trade',name='当前跑商路线',feature='Trade',featureId='life_trade',route='life.trade',widget='life.trade'},
}
local CATEGORIES={home=1,combat=2,life=3,tools=4,system=5}
local function Copy(v)
 if type(v)~='table' then return v end
 local out={};for k,x in pairs(v)do out[k]=Copy(x)end;return out
end
local function Key(v) return type(v)=='string' and #v>0 and #v<=192 and not v:find('[\r\n%z]') end
local function Map(v)
 local out,n={},0
 for k,x in pairs(type(v)=='table' and v or {})do
  if Key(k) and x==true and n<512 then out[k]=true;n=n+1 end
 end
 return out
end
local function Order(v)
 local out,seen={},{}
 for _,k in ipairs(type(v)=='table' and v or {})do
  if Key(k) and not seen[k] and #out<512 then seen[k]=true;out[#out+1]=k end
 end
 return out
end
local function Normalize(v)
 v=type(v)=='table' and v or {};local nav=type(v.navigation)=='table' and v.navigation or {}
 local home=type(v.home)=='table' and v.home or {};local lists=type(v.lists)=='table' and v.lists or {}
 local out={navigation={favorite=Map(nav.favorite),hidden=Map(nav.hidden),order=Order(nav.order)},
  home={hidden=Map(home.hidden),order=Order(home.order),stats=home.stats~=false},lists={},
  appearance=({dark=true,gold=true,contrast=true})[v.appearance] and v.appearance or 'dark',
  density=v.density=='compact' and 'compact' or 'standard'}
 out.navigation.hidden.home=nil
 for _,id in ipairs({'tasks','activities'})do
  local l=type(lists[id])=='table' and lists[id] or {}
  out.lists[id]={pinned=Map(l.pinned),order=Order(l.order),manual=l.manual==true,hideCompleted=l.hideCompleted==true}
 end
 return out
end
W.state=Normalize(nil)
W.Normalize=Normalize -- 纯 canonical；测试/后续 schema 必须保留此版本形状。
local function Apply(v)W.state=Normalize(v)end
if P and type(P.RegisterV3Store)=='function' and not P:GetStore(W.storeId) then
 local store,err=P:RegisterV3Store({id=W.storeId,owner='v3.workspace',scope=P.Scope.Account,lifetime=P.Lifetime.Permanent,
  schemaVersion=1,legacySchemaVersion=0,key=P.V3KeyPrefix..'workspace',
  budget={maxDepth=7,maxNodes=6500,maxStringBytes=131072,maxEntriesPerTable=512},
  default=function()return Normalize(nil)end,get=function()return Normalize(W.state)end,apply=Apply})
 if not store then W.error=tostring(err or 'workspace store unavailable')end
end
function W:EnsureLoaded()
 if self.loaded then return not self.error,self.error end
 self.loaded=true
 if not P or not P:GetStore(self.storeId)then self.error=self.error or '个性化存档不可用';return false,self.error end
 local ok,_,err=P:LoadStore(self.storeId)
 if ok~=true and ok~='empty'then self.error=tostring(err or ok or '个性化配置读取失败');return false,self.error end
 return true
end
function W:Change(kind,fn)
 local ready,err=self:EnsureLoaded();if not ready then return false,err end
 local ok,why=P:MutateStore(self.storeId,fn,{durable=true,reason='workspace:'..tostring(kind)})
 if not ok then return false,why end
 self.revision=self.revision+1
 if S.Events and type(S.Events.Publish)=='function'then S.Events:Publish('v3.workspace.updated',kind,self.revision)end
 return true
end
function W:GetSettings()self:EnsureLoaded();return Copy(self.state)end
function W:GetNavPreference(id)self:EnsureLoaded();local n=self.state.navigation;return {favorite=n.favorite[id]==true,hidden=n.hidden[id]==true}end
function W:SetNavigation(id,option,value)
 local router=S.UIV3.Router;local row=router and router:Get(id)
 if not row or not row.visible or row.category=='system' or id=='home'then return false,'该入口不可隐藏或重排' end
 if option~='favorite' and option~='hidden'then return false,'未知导航选项'end
 return self:Change('navigation',function()
  self.state.navigation[option][id]=value==true or nil
  -- 首次收藏按用户点击顺序追加，之后显式上/下移决定位置；不猜原分组的优先级。
  if option=='favorite' and value==true then
   local found=false;for _,key in ipairs(self.state.navigation.order)do if key==id then found=true end end
   if not found then self.state.navigation.order[#self.state.navigation.order+1]=id end
  end
  return true
 end)
end
local function Ranked(rows,order,key)
 local rank={};for i,id in ipairs(order)do rank[id]=i end
 local out={};for i,row in ipairs(rows)do out[#out+1]={row=row,rank=rank[key(row)] or 100000+i,index=i}end
 table.sort(out,function(a,b)return a.rank<b.rank end)
 local result={};for _,v in ipairs(out)do result[#result+1]=v.row end;return result
end
function W:ReadControl(id)
 local runtime=S.FeatureRuntime
 if runtime and type(runtime.GetControlState)=='function'then return runtime:GetControlState(id)end
 return {implemented=runtime and type(runtime.IsImplemented)=='function' and runtime:IsImplemented(id)==true,
  enabled=runtime and type(runtime.IsEnabled)=='function' and runtime:IsEnabled(id)==true,faulted=false}
end
function W:GetNavigation(mode,query)
 self:EnsureLoaded();mode=tostring(mode or 'custom');query=tostring(query or ''):lower()
 local router=S.UIV3.Router;local rows=router and router:List() or {};local nav=self.state.navigation;local out={}
 table.sort(rows,function(a,b)
  if a.category~=b.category then return (CATEGORIES[a.category] or 9)<(CATEGORIES[b.category] or 9)end
  if a.navigationIncomplete~=b.navigationIncomplete then return a.navigationIncomplete~=true end
  if a.groupOrder~=b.groupOrder then return a.groupOrder<b.groupOrder end
  if a.groupItemOrder~=b.groupItemOrder then return a.groupItemOrder<b.groupItemOrder end
  return a.id<b.id
 end)
 for _,r in ipairs(rows)do
  if r.category~='system' then
   local meta=S.FeatureRegistry:GetByRoute(r.id);local control=meta and meta.controlFeatureId
   -- “已开启”是全局真实运行视图，不受个人隐藏影响；否则顶栏数量与左栏会相互矛盾。
   -- 收藏/我的导航才消费 hidden，仍仅遍历 Router 允许的可见目录，不恢复已移除页面。
   local include=r.id=='home' or mode=='all' or mode=='enabled' and self:ReadControl(control or r.featureId).enabled
    or not nav.hidden[r.id] and (mode=='custom' or mode=='favorites' and nav.favorite[r.id])
   if include and (r.id=='home' or query=='' or tostring(r.title):lower():find(query,1,true) or r.id:find(query,1,true))then out[#out+1]=r end
  end
 end
 if mode~='all'then out=Ranked(out,nav.order,function(r)return r.id end)end
 local buckets={{},{},{}}
 for _,r in ipairs(out)do local i=r.id=='home' and 1 or mode~='all' and nav.favorite[r.id] and 2 or 3;buckets[i][#buckets[i]+1]=r end
 out={};for _,bucket in ipairs(buckets)do for _,r in ipairs(bucket)do out[#out+1]=r end end
 return out
end
local function Moved(rows,id,delta,key)
 local at;for i,r in ipairs(rows)do if key(r)==id then at=i;break end end
 if not at then return nil,'未找到条目'end
 local target=at+(delta<0 and -1 or 1);if target<1 or target>#rows then return nil,'已到边界'end
 rows[at],rows[target]=rows[target],rows[at];local order={};for _,r in ipairs(rows)do order[#order+1]=key(r)end;return order
end
function W:MoveNavigation(id,delta)
 local rows={};local preference=self:GetNavPreference(id)
 for _,r in ipairs(self:GetNavigation('custom'))do if r.id~='home' and self:GetNavPreference(r.id).favorite==preference.favorite then rows[#rows+1]=r end end
 local order,err=Moved(rows,id,delta,function(r)return r.id end);if not order then return false,err end
 return self:Change('navigation',function()
  -- 保留另一收藏分组及未来版本的未知 ID；不以一次移动抹掉其他用户顺序。
  local seen={};for _,k in ipairs(order)do seen[k]=true end
  for _,k in ipairs(self.state.navigation.order)do if not seen[k]then order[#order+1]=k end end
  self.state.navigation.order=order;return true
 end)
end
function W:GetCards(includeHidden)
 self:EnsureLoaded();local rows=Ranked(Copy(CARDS),self.state.home.order,function(r)return r.id end);local out={}
 for _,r in ipairs(rows)do r.visible=not self.state.home.hidden[r.id];if includeHidden or r.visible then out[#out+1]=r end end
 return out
end
function W:SetCardVisible(id,value)
 local known=false;for _,r in ipairs(CARDS)do if r.id==id then known=true end end;if not known then return false,'未知卡片'end
 return self:Change('home',function()self.state.home.hidden[id]=value~=true or nil;return true end)
end
function W:MoveCard(id,delta)
 local order,err=Moved(self:GetCards(true),id,delta,function(r)return r.id end);if not order then return false,err end
 return self:Change('home',function()self.state.home.order=order;return true end)
end
function W:SetOption(key,value)
 if key=='appearance' and not ({dark=true,gold=true,contrast=true})[value]then return false,'未知主题'end
 if key=='density' and value~='compact' and value~='standard'then return false,'未知密度'end
 if key~='appearance' and key~='density' and key~='stats'then return false,'未知选项'end
 return self:Change(key=='stats' and 'home' or key,function()
  if key=='stats'then self.state.home.stats=value==true else self.state[key]=value end;return true
 end)
end
function W:GetListKey(id,row)
 if id=='activities'then return row.zoneState and tostring(row.key) or tostring(row.fullName or row.name or row.id or row.key or '')end
 return tostring(row.id or (tostring(row.scope)..':'..tostring(row.groupKey or row.key)))
end
function W:GetListOption(id)self:EnsureLoaded();return Copy(self.state.lists[id] or {})end
function W:SetListOption(id,key,value)
 if not self.state.lists[id] or (key~='manual' and key~='hideCompleted')then return false,'未知列表选项'end
 return self:Change('lists',function()self.state.lists[id][key]=value==true;return true end)
end
function W:ToggleListPin(id,key)
 if not self.state.lists[id] or not Key(key)then return false,'未知列表条目'end
 return self:Change('lists',function()local p=self.state.lists[id].pinned;p[key]=not p[key] or nil;return true end)
end
-- 维护（活动分区）：分区由 Authority/目录的显式字段决定，不从活动名称猜测。
-- Workspace 只管理分区内部个人顺序；旧 order/pinned 键完整保留，不迁移业务数据。
local function ListSection(id,row)
 if id~='activities'then return 'list'end
 return (row.presentationSection=='live' or row.zoneState==true or row.category=='区域状态') and 'live' or 'timeline'
end
function W:MoveList(id,rows,key,delta)
 if not self.state.lists[id]then return false,'未知列表'end
 -- 置顶和实时区域都是稳定分区；跨分区移动不会产生可见变化，必须拒绝假成功。
 local pins=self.state.lists[id].pinned;local pinned=pins[key]==true
 local section
 for _,row in ipairs(rows)do if self:GetListKey(id,row)==key then section=ListSection(id,row);break end end
 if not section then return false,'未找到条目'end
 local subset={};for _,row in ipairs(rows)do
  if (pins[self:GetListKey(id,row)]==true)==pinned and ListSection(id,row)==section then subset[#subset+1]=row end
 end
 local order,err=Moved(subset,key,delta,function(r)return self:GetListKey(id,r)end);if not order then return false,err end
 return self:Change('lists',function()
  -- 过滤日常/搜索结果中的一次移动不能清空周常或暂未出现条目的个人顺序。
  local seen={};for _,k in ipairs(order)do seen[k]=true end
  for _,k in ipairs(self.state.lists[id].order)do if not seen[k]then order[#order+1]=k end end
  self.state.lists[id].manual=true;self.state.lists[id].order=order;return true
 end)
end
function W:ProjectRows(id,rows,all)
 self:EnsureLoaded();local opt=self.state.lists[id];if not opt then return rows end
 local out={};for _,r in ipairs(type(rows)=='table' and rows or {})do
  if all or not opt.hideCompleted or r.status~='已完成'then out[#out+1]=r end
 end
 if opt.manual then out=Ranked(out,opt.order,function(r)return self:GetListKey(id,r)end)end
 local first,last={},{};for _,r in ipairs(out)do local dest=opt.pinned[self:GetListKey(id,r)] and first or last;dest[#dest+1]=r end
 for _,r in ipairs(last)do first[#first+1]=r end
 -- 先执行原个人顺序/置顶，再稳定分区；首页、悬浮和自定义目录看到相同边界。
 if id=='activities'then
  local timeline,live={},{};for _,r in ipairs(first)do local dest=ListSection(id,r)=='live' and live or timeline;dest[#dest+1]=r end
  for _,r in ipairs(live)do timeline[#timeline+1]=r end;return timeline
 end
 return first
end
function W:Reset(section)
 if section~='navigation' and section~='home' and section~='lists' and section~='appearance'then return false,'未知恢复范围'end
 return self:Change(section,function()local defaults=Normalize(nil)
  if section=='appearance'then self.state.appearance=defaults.appearance;self.state.density=defaults.density
  else self.state[section]=defaults[section]end;return true
 end)
end
function W:GetFeatureRows(mode,query)
 local rows={};query=tostring(query or ''):lower()
 for _,meta in ipairs(S.FeatureRegistry and S.FeatureRegistry:List() or {})do
  if meta.lifecycle~='shell' then
   local state=self:ReadControl(meta.id);local pref=self:GetNavPreference(meta.route)
   local include=mode=='all' or mode==nil or mode=='enabled' and state.enabled or mode=='faulted' and state.faulted or mode=='favorites' and pref.favorite
   if include and (query=='' or meta.name:lower():find(query,1,true) or meta.id:find(query,1,true))then
    rows[#rows+1]={id=meta.id,name=meta.name,route=meta.route,enabled=state.enabled==true,faulted=state.faulted==true,
     implemented=state.implemented==true,blocked=meta.runtimeBlocked==true,performance=meta.performanceLabel or '—',
     reason=meta.performanceReason or '',state=state.faulted and '异常' or state.enabled and '已开启' or '已关闭'}
   end
  end
 end
 return rows
end
function W:GetRunningSummary()
 local out={enabled=0,faulted=0,names={}};for _,r in ipairs(self:GetFeatureRows('all'))do
  if r.enabled then out.enabled=out.enabled+1;out.names[#out.names+1]=r.name end
  if r.faulted then out.faulted=out.faulted+1 end
 end;return out
end
function W:GetWindowRows()
 local host=S.UIV3.WidgetHost;local rows={};if not host then return rows end
 for _,id in ipairs(host.order or {})do
  local r=type(host.GetPresentationState)=='function' and host:GetPresentationState(id) or nil
  if r then rows[#rows+1]=r end
 end;return rows
end
function W:DescribeModule(id)
 local state=self:ReadControl(id);local labels={state.enabled and '功能已开启' or '功能未开启'}
 if state.faulted then labels[#labels+1]='运行时已记录故障'end
 local shown,mini,hidden=0,0,0
 for _,r in ipairs(self:GetWindowRows())do if r.featureId==id then
  if not r.visible then hidden=hidden+1 elseif r.minimized then mini=mini+1 else shown=shown+1 end
 end end
 if shown+mini+hidden>0 then labels[#labels+1]='窗口展开 '..shown..' / 收起 '..mini..' / 隐藏 '..hidden end
 return table.concat(labels,' · ')
end
