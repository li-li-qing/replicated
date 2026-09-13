-- Real status model/store, synthetic Floating/Native. No RU pixel assertion.
local pass,fail=0,0
local function Test(n,f)local ok,e=pcall(f);if ok then pass=pass+1;print('PASS compact '..n)else fail=fail+1;print('FAIL compact '..n..': '..tostring(e))end end
local Boot=dofile('tools/rs_report_failure_test_host.lua')
local function Widget()
 local S,F,p,h,c=Boot();p:OnDeactivated();h.widgets={}
 local H=S.UIV3.WidgetHost;H.factories={};H.Register=function(_,id,spec)H.factories[id]=spec;return true end;H.BindFeatureLifecycle=function()return true end
 local surf={shell={root=h.Node({id='shell'})},window={}}
 function surf:GetContentRoot()return self.shell.root end
 function surf:Show(v)self.visible=v;return true end
 function surf:SetStatus(v)self.status=v;return true end
 S.RSUI.FloatingSurface.Create=function()return surf end;S.RSUI.FloatingSurface.CreateStateAdapter=function()return {}end
 F.Commands.Refresh=function()return true end
 F.AcquireConsumer=function()return true end;F.ReleaseConsumer=function()return true end
 S.FeatureRuntime.IsEnabled=function()return true end
 F.projections={player={{id=82,name='A',category='buff',key='player:82',timeText='0.2',stack=1}},target={{id=87,name='B',category='debuff',key='target:87',timeText='1',stack=1}}};F.revision=20
 dofile('presentation/v3/widgets/rs_v3_buff_display_widget.lua');local w=assert(H.factories['combat.buff_display'].create());assert(w:Show({persist=false}))
 return S,F,w,h,c
end
Test('metadata consumers do not cancel each other',function()
 local S,F,p,h=Boot();F:SetManagementPageActive(true,'widget');F:SetManagementPageActive(false)
 assert(F.managementMetadata.active,'closing main page cancelled widget metadata')
 F:SetManagementPageActive(false,'widget');assert(not F.managementMetadata.active)
end)
Test('explicit current view remains live during retention',function()
 local S,F=Boot();F.projections.player={{id=82,name='live',category='buff'}};F.revision=9
 F.managementFreeze.active=true;F.managementFreeze.rows.player={{id=87,name='old',category='debuff'}}
 local r=F:GetManagementProjection({view='live',preserveLive=true,cacheOwner='widget'})
 assert(r[1].id==82,'current view silently changed to retained history')
end)
Test('independent source and type filters intersect',function()
 local S,F=Boot();F.projections={player={{id=82,name='A',category='buff'}},target={{id=87,name='B',category='debuff'}}};F.revision=12
 local r=F:GetManagementProjection({view='live',filter='buff',scope='target'});assert(#r==0)
end)
Test('default widget shows current untracked rows and can add then cancel',function()
 local S,F,w,h=Widget();assert(#w.table.items==2,'widget still shows only saved list');local row=w.table.items[1]
 assert(w.table.spec.onItemActivated(row));assert(F:IsTrackedId(row.id));row=w.table.items[1];assert(row.tracked)
 assert(w.table.spec.onItemActivated(row));assert(not F:IsTrackedId(row.id))
end)
Test('widget keeps independent live and tracked views and queues only visible icons',function()
 local S,F,w,h,c=Widget();assert(w:SetView('tracked'));assert(#w.table.items==0)
 assert(w:SetView('live'));local n=c.tooltip;w.table.spec.bindRow({},w.table.items[1]);assert(c.tooltip==n)
 assert(F.managementMetadata.active);w:Hide({persist=false});assert(not F.managementMetadata.active)
end)
Test('hide uses actual TextInput CancelEditing rather than nonexistent CancelDraft',function()
 local S,F,w,h=Widget();local ended=0
 w.search.CancelEditing=function()ended=ended+1;return true end
 w.search.CancelDraft=nil
 assert(w:Hide({persist=false}));assert(ended==1)
end)
Test('actual RSUI compact widget lays out useful table and releases keyboard input',function()
 local h=dofile('tools/rs_gear_page_test_host.lua')({realTextAuthority=true});local S=h.S
 local held={};local F={Commands={},GetWidgetWindowState=function()return {}end,GetManagementFreezeState=function()return {active=false}end,
   GetManagementProjection=function()return {{id=82,key='player:82',name='测试状态',scopeText='自己',effectTypeText='Buff',timeText='0.2',trackedText='未追踪'}},1 end,
   SetManagementPageActive=function()return true end,EnsureStoreLoaded=function()return true end,GetWidgetVisible=function()return false end}
 F.AcquireConsumer=function(_,k)held[k]=true;return true end;F.ReleaseConsumer=function(_,k)held[k]=nil;return true end
 F.Commands.Refresh=function()return true end;F.Commands.SetWidgetVisible=function()return true end;F.Commands.MarkStoreDirty=function()return true end;F.Commands.SetWidgetWindowState=function()return true end
 S.Features.BuffDisplay=F
 local root=S.RSUI:VerticalBox({id='test_compact_surface',parent=h.Native(nil,'compact_parent',0,0,430,300)})
 local surface={shell={root=root},Show=function()return true end,SetStatus=function()return true end,GetContentRoot=function()return root end}
 S.UIV3.WidgetHost={Register=function(_,id,spec)S.compactCreate=spec.create;return true end,BindFeatureLifecycle=function()return true end}
 S.RSUI.FloatingSurface={Create=function()return surface end,CreateStateAdapter=function()return {}end}
 dofile('presentation/v3/widgets/rs_v3_buff_display_widget.lua');local w=S.compactCreate();assert(w:Show({persist=false}))
 -- Native creation in this host replaces input registration. Adopt the new tree
 -- exactly as V3 host does before testing owned native focus release.
 local function Adopt(c)if c.root then assert(h.UI:AdoptV3Widget(c.root,c.owner,c.id))end;for _,child in ipairs(c.children or {})do Adopt(child)end end
 Adopt(root)
 for _,width in ipairs({330,430,650})do root:Layout(0,0,width,260);assert(w.table.height>70)end
 assert(w.search:BeginEditing('test'));w.search.root.text='查询';assert(w.search:IsEditing())
 assert(w:Hide({persist=false}));assert(not w.search:IsEditing() and not next(held))
end)
print('COMPACT RESULT '..pass..' passed / '..fail..' failed');if fail>0 then error('compact tests failed')end
