------------------------------------------------------------------------
-- Replicated Suite · 列表刷新回归测试
-- 作者：Replicated
-- QQ群：1104129461
--
-- 真实 Healer Store + 页面 RefreshAdvanced + RSUI TableView；真实 Bonds 页面行激活。
-- 治疗页只装配目标方法的局部编辑控件，跳过无关校准/运行时；Native 绘制、债券事实/详情边界由宿主提供。
------------------------------------------------------------------------
local Boot=dofile('tools/rs_gear_page_test_host.lua')
local passed,failed=0,0
local function T(name,fn)local ok,e=xpcall(fn,debug.traceback);if ok then passed=passed+1;print('PASS list-refresh '..name)else failed=failed+1;print('FAIL list-refresh '..name..': '..tostring(e))end end
local function Healer()
 local h=Boot();local S=h.S;assert(h.page:OnDeactivated());dofile('features/combat/healer/rs_healer_store.lua')
 local F=S.Features.Healer;assert(F:EnsureStoreLoaded());assert(F:AddTrackedBuff(21,'初始追踪','old.dds'))
 local parent=h.Native(nil,'healer-refresh-parent',0,0,620,420);local R=S.RSUI
 local ruleTable=assert(R:TableView({id='healer-refresh-rules',parent=parent,items={},rowHeight=25,headerHeight=24,
  columns={{id='name',field='name',title='名称',size='fill'},{id='enabled',field='enabled',title='启用',size='fixed',width=60}},
  getKey=function(row)return row.key end,selectable=true,selectionMode='single'}))
 local trackedTable=assert(R:TableView({id='healer-refresh-tracked',parent=parent,items={},rowHeight=25,headerHeight=24,
  columns={{id='name',field='name',title='名称',size='fill'},{id='enabled',field='enabled',title='启用',size='fixed',width=60}},
  getKey=function(row)return row.key end,selectable=true,selectionMode='single'}))
 local function Node(id)return assert(R:Text({id=id,parent=parent,text=''}))end
 local input=assert(io.open('presentation/v3/pages/rs_v3_healer_page.lua','rb'));local source=input:read('*a');input:close()
 local a=assert(source:find('    function root:RefreshAdvanced()',1,true));local b=assert(source:find('    function root:ShowAdvanced(show)',a,true))
 local helperA=source:find('local function AdvancedRowsRevision(',1,true);local helper=''
 if helperA then local helperB=assert(source:find('local function N(',helperA,true));helper=source:sub(helperA,helperB-1)end
 local root={};local env=setmetatable({root=root,Feature=F,ruleTable=ruleTable,trackedTable=trackedTable,ruleIndex=1,trackedIndex=1,
  ruleRemoveButton=Node('healer-test-remove'),trackedRemoveButton=Node('healer-test-tracked-remove'),
  ruleStatus=Node('healer-test-status'),trackedStatus=Node('healer-test-tracked-status'),ruleEditorFields={},trackedEditorFields={},colorEditorFields={}},{__index=_G})
 local chunk=assert(loadstring(helper..source:sub(a,b-1),'@real_healer_page_refresh'));setfenv(chunk,env);chunk()
 local function Layout()ruleTable:Layout(0,0,620,180);trackedTable:Layout(0,200,620,180)end
 assert(root:RefreshAdvanced());Layout();return h,F,root,ruleTable,trackedTable,Layout
end
T('same-count rule edits refresh displayed pooled values and unchanged refresh reuses rows',function()
 local h,F,root,r,t,Layout=Healer();assert(F:SetRule(1,'name','更新后的规则'));assert(F:SetRule(1,'enabled',false))
 assert(root:RefreshAdvanced());Layout();local slot=assert(r.list.poolByIndex[1])
 assert(slot.row.item.name=='更新后的规则' and slot.row.item.enabled=='否','rule display retained old values at same count')
 local binds=h.S.RSUI.metrics.virtualRowBinds;assert(root:RefreshAdvanced());Layout()
 assert(h.S.RSUI.metrics.virtualRowBinds==binds,'unchanged rules unnecessarily rebind the pool')
end)
T('same-count tracked edits refresh displayed pooled values',function()
 local h,F,root,r,t,Layout=Healer();assert(F:SetTrackedBuff(1,'name','更新后的追踪'));assert(F:SetTrackedBuff(1,'enabled',false))
 assert(root:RefreshAdvanced());Layout();local slot=assert(t.list.poolByIndex[1])
 assert(slot.row.item.name=='更新后的追踪' and slot.row.item.enabled=='否','tracked display retained old values at same count')
end)
T('Bonds real TableView activation passes the row to the detail surface',function()
 local h=Boot();local S=h.S;assert(h.page:OnDeactivated());dofile('ui/framework/rs_ui_forms.lua')
 local row={key='quest:100',name='居民做货任务',text='材料事实',statusText='可查看'};local selected,opened
 local F={Id='life_bonds',UpdateTopic='v3.life.bonds.updated',Commands={Refresh=function()return true end,SelectRow=function(_,key)selected=key;return true end}}
 function F:GetProjection()return {rows={row},revision=1,status='ready',count=1}end
 function F:AcquireConsumer()return true end;function F:ReleaseConsumer()return true end
 function F:GetDisplayOrderKey()return 'continent:west_first'end;function F:GetFilterMask()return 7 end;function F:GetDuplicateMode()return 'all'end
 function F:GetWidgetVisible()return false end;function F:GetSelectedRow()return selected and row end
 for _,key in ipairs({'SetDisplayOrder','SetFilterMask','SetDuplicateMode','SetWidgetVisible'})do F.Commands[key]=function()return true end end
 S.Features.Bonds=F;S.UIV3.WidgetHost={IsVisible=function()return false end,SetVisible=function()return true end}
 S.UIV3.QuestDetailFloatingV3={Open=function(_,kind,key,value)opened={kind,key,value};return true end}
 dofile('presentation/v3/shell/rs_v3_page_host.lua');dofile('presentation/v3/pages/rs_v3_life_m16_pages.lua')
 local page=assert(S.UIV3.PageHost.factories['life.bonds'](h.Native(nil,'bonds-click-parent',0,0,820,680),'life.bonds'));assert(page:Refresh())
 assert(page.tableView:ActivateItem(1),'Bonds activation did not open detail')
 assert(opened and opened[1]=='bonds' and opened[2]==row.key and opened[3]==row,'detail received incorrect row identity')
end)
print(('LIST_REFRESH_RESULT passed=%d failed=%d'):format(passed,failed));if failed>0 then error('list refresh tests failed')end
