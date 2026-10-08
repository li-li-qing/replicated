-- 维护（2026-09-18，startup-source-recovery）：本文件在故障包中有 9 处未解决的 Git 合并冲突。
-- 已对照用户此前完整 V3 工程恢复有效实现；Authority、调用数据流和存档协议仍由下方原实现负责，
-- 不通过清配置、跳过加载或恢复 Legacy 绕过错误。兼容边界：须与完整 toc.g 及 .18.247 UI 配套；
-- 后续合并必须先检查冲突标记、清单完整性与 Lua 语法，再做运行时验收；注释不增加运行期开销。
-- 维护（2026-09-12）：物理版本按Store注册策略验收；仍比较完整配置，不放宽业务指纹/重载一致性。
-- Development-only: shipped EventBus/Scheduler/Api/Store; optional production
-- Button factory/Click dispatch through a recorded Native handler. Geometry, focus,
-- Native tooltip and disk remain synthetic; not RU-client acceptance.
local passed,failed=0,0
local function Test(name,fn)
    local ok,err=xpcall(fn,function(e)return tostring(e)..'\n'..debug.traceback()end)
    if ok then passed=passed+1;print('PASS library runtime '..name)
    else failed=failed+1;print('FAIL library runtime '..name..': '..err)end
end
local function Copy(v)if type(v)~='table'then return v end;local t={};for k,x in pairs(v)do t[k]=Copy(x)end;return t end
local function Same(a,b)if type(a)~=type(b)then return false end;if type(a)~='table'then return a==b end;for k,v in pairs(a)do if not Same(v,b[k])then return false end end;for k in pairs(b)do if a[k]==nil then return false end end;return true end
local function Find(rows,id)for _,row in ipairs(rows)do if row.id==id then return row end end;error('missing library row '..id)end
local function Boot(options)
    options=options or {};local c={reads=0,writes=0,tooltip=0,logs={},clock=1000,disk=Copy(options.disk or {}),failWrites=false}
    ADDON={LoadData=function(_,k)c.reads=c.reads+1;return Copy(c.disk[k])end,
        SaveData=function(_,k,v)c.writes=c.writes+1;if options.saveFail and c.failWrites then return false end;c.disk[k]=options.nativeLoss and options.nativeLoss(v) or Copy(v);return true end,
        ClearData=function()error('must not clear')end}
    X2Ability={GetBuffTooltip=function(_,id,level)c.tooltip=c.tooltip+1;if options.tooltip then return options.tooltip(id,level)end;return {name='Native '..id,iconPath='ui/icon/test_'..id..'.dds'}end}
    ReplicatedSuite={Features={},Services={},UI={CreateWindowShell=function()end},RSUI={},Generation=1,
        SafeTraceback=function(e)return tostring(e)end,NowMs=function()return c.clock end,
        FeatureRuntime={RegisterImplementation=function()return true end,IsEnabled=function()return false end}}
    local S=ReplicatedSuite
    for _,f in ipairs({'core/rs_utils.lua','core/rs_reuse.lua','core/rs_api.lua','core/rs_api_capabilities.lua','core/rs_events.lua','core/rs_scheduler.lua','core/rs_persistence_transport.lua','core/rs_persistence.lua','core/rs_demand.lua',
        'data/rs_data_registry.lua','data/rs_skill_effects.lua','data/rs_combat_ability_catalog.lua','data/ids/rs_buff_ids.lua','data/ids/rs_plates_ids.lua','services/rs_status_classification_v3.lua',
        'data/rs_status_tracking_catalog.lua','services/rs_buff_metadata_v3.lua','ui/framework/rs_ui_floating_surface.lua','features/combat/buff_display/rs_buff_display_store.lua',
        'features/combat/buff_display/rs_buff_display_projection.lua','features/combat/buff_display/rs_buff_display_feature.lua','features/combat/buff_display/rs_buff_display_management.lua',
        'features/combat/buff_display/rs_buff_display_transfer_v2.lua'})do dofile(f)end
    S.DiagnosticsManager={Emit=function(_,level,source,code,message,context)c.logs[#c.logs+1]={level=level,source=source,code=code,message=message,context=Copy(context)}end}
    local F=S.Features.BuffDisplay;assert(F:EnsureStoreLoaded())
    local h=dofile('tools/rs_status_ui_test_host.lua')(S)
    if options.productionButtons then
        -- Keep actual primitive deferred-onClick resolution; the small adapter supplies
        -- only native handler registration/base component methods, not game hit-testing.
        local factories={}
        S.RSUI.RegisterType=function(_,kind,factory)factories[kind]=factory;return true end
        S.RSUI.ReplaceType=S.RSUI.RegisterType
        S.RSUI._Count=function()end
        S.RSUI.Callback=function(_,_,fn,...)return pcall(fn,...)end
        S.UI.CreateButton=function()return {events={}}end
        S.UI.SetText=function(_,root,text)root.text=text;return true end
        S.UI.SetButtonActive=function()return true end
        S.RSUI.NewComponent=function(_,kind,spec,root)
            local node=h.Node(spec);node.id=spec.id;node.kind=kind;node.state={};node.root=root
            function node:RequireOn(native,event,fn)native.events[event]=fn;return true end
            return node
        end
        dofile('ui/framework/rs_ui_primitives.lua')
        S.RSUI.Button=function(_,spec)return factories.Button(spec)end
    end
    local page=assert(h:Build());page.librarySource='library';assert(page:OnActivated());page:SwitchTab('library')
    local function Pump()
        local n=0
        while S.Scheduler.tasks.v3_buff_management_metadata and n<40 do n=n+1;assert(S.Scheduler:RunTask('v3_buff_management_metadata'),S.LastSchedulerError and S.LastSchedulerError.error)end
        assert(n<40,'unbounded metadata scheduling');return n
    end
    return S,F,page,h,c,Pump
end
Test('real owner-first event refreshes resolved library icons',function()
    local S,F,p,h,c,Pump=Boot();local view=h.widgets.v3_buff_library_table
    local first=view.items[1];assert(not first.iconPath or first.iconPath=='')
    view.spec.bindRow({},first);assert(c.tooltip==0,'native call inside row render')
    Pump();assert(S.Services.BuffMetadataV3:GetCached(first.id).iconPath~='')
    assert(Find(view.items,first.id).iconPath~='','resolved cache never reached library row through owner-first EventBus')
end)
Test('real owner-first event refreshes committed tracking from outside page button',function()
    local S,F,p,h=Boot();local first=h.widgets.v3_buff_library_table.items[1]
    assert(F.Commands:SetTrackedId(first.id,'auto',true))
    assert(h.widgets.v3_buff_library_table.items[1].tracked,'committed tracking stayed untracked until tab reopen')
end)
Test('real API and EventBus import recommended package through one manifest transaction',function()
    local S,F,p,h,c=Boot();local before=c.writes
    local ok,err=F.Commands:ImportBuiltinPack('recommended',true);assert(ok,err)
    assert(c.writes==before+4 and p.activeTab=='library')
    assert(h.widgets.v3_buff_manage_view.spec.set('tracked'));local rows=h.widgets.v3_buff_display_tracking_table.items;assert(#rows==#S.Data.StatusTrackingCatalogV3.Packs.recommended.entries)
    for _,row in ipairs(rows)do assert(row.tracked and F:IsTrackedId(row.id),'uncommitted row '..row.id)end
    local expected=Copy(F.State.settings.tracked)
    local _,fresh=Boot({disk=c.disk});assert(Same(fresh.State.settings.tracked,expected),'durable list changed on reload')
end)
Test('native SaveData rejection is visible and logged with transaction stage',function()
    local S,F,p,h,c=Boot({saveFail=true});local before=Copy(F.State.settings.tracked);c.failWrites=true
    assert(not F.Commands:ImportBuiltinPack('recommended',true));assert(Same(F.State.settings.tracked,before) and p.activeTab=='library')
    local hit;for _,v in ipairs(c.logs)do if v.code=='BUFF_LIBRARY_IMPORT_FAILED'then hit=v end end
    assert(hit and hit.context.pack=='recommended' and hit.context.stage=='commit','silent bulk import failure')
    assert(F.lastLibraryImport.ok==false and F.lastLibraryImport.error)
end)
Test('rejected unknown pack also records attempted import rather than old success',function()
    local _,F=Boot();assert(F:ImportBuiltinPack('recommended',false));assert(not F:ImportBuiltinPack('no-such-pack',false))
    assert(F.lastLibraryImport and F.lastLibraryImport.pack=='no-such-pack' and F.lastLibraryImport.ok==false and F.lastLibraryImport.stage=='validate')
end)
Test('inline tracking command exception stays visible and enters diagnostic history',function()
    local S,F,p,h,c=Boot();F.Commands.SetTrackedPlacement=function()error('injected_tracking_exception')end
    local view=h.widgets.v3_buff_library_table;local col;for _,v in ipairs(view.spec.columns)do if v.id=='player_buff'then col=v end end
    local callOk,result=pcall(col.onClick,view.items[1]);assert(callOk and result==false,'exception escaped without feedback')
    assert(h.widgets.v3_buff_library_status.text:find('injected_tracking_exception',1,true))
    local hit;for _,v in ipairs(c.logs)do if v.code=='BUFF_TRACKING_COMMAND_FAILED'then hit=v end end;assert(hit and hit.context.stage=='command')
end)
Test('name-only native tooltip stays marked unresolved with bounded raw shape evidence',function()
    local S,F,p,h,c,Pump=Boot({tooltip=function()return {name='known name',description='text only'}end})
    for i=1,16 do h.widgets.v3_buff_library_table.spec.bindRow({},h.widgets.v3_buff_library_table.items[i])end
    Pump();local info=F:GetManagementHealth().metadata
    assert(info.resolver and info.resolver.iconMissing>0 and #info.resolver.samples>0 and #info.resolver.samples<=8,'no shape evidence for missing Native icon')
    local calls=c.tooltip;for i=1,16 do h.widgets.v3_buff_library_table.spec.bindRow({},h.widgets.v3_buff_library_table.items[i])end;Pump();assert(c.tooltip==calls,'per-bind retry storm')
end)
Test('temporary missing capability does not permanently poison negative cache',function()
    local S=Boot();local M=S.Services.BuffMetadataV3;X2Ability=nil;M:GetInfo(82,true)
    X2Ability={GetBuffTooltip=function()return {iconPath='ui/icon/available.dds'}end}
    local info=M:GetInfo(82,true);assert(info and info.iconPath=='ui/icon/available.dds','transient unavailable cached forever')
end)
Test('new native icon observed through shared service refreshes visible library',function()
    local S,F,p,h,c,Pump=Boot({tooltip=function()return 'tooltip name'end});local item=h.widgets.v3_buff_library_table.items[1]
    h.widgets.v3_buff_library_table.spec.bindRow({},item);Pump()
    S.Services.BuffMetadataV3:Remember(item.id,'effect','ui/icon/observed.dds')
    S.Events:Publish('v3.buff_display.updated','aura')
    assert(h.widgets.v3_buff_library_table.items[1].iconPath=='ui/icon/observed.dds','observed icon upgrade ignored while library open')
end)
Test('page deactivation cancels job and removes actual internal listeners',function()
    local S,F,p,h,c,Pump=Boot();local first=h.widgets.v3_buff_library_table.items[1]
    h.widgets.v3_buff_library_table.spec.bindRow({},first);assert(p:OnDeactivated());Pump()
    assert(c.tooltip==0 and S.Events.internalListeners['v3.buff_display.updated']==nil)
end)

Test('actual manual CD Button dispatch finds its callback installed after construction',function()
    local S,F,p,h,c=Boot({productionButtons=true});assert(h.widgets.v3_buff_manage_view.spec.set('cooldowns'))
    local button=h.widgets.v3_buff_cooldown_add;h.widgets.v3_buff_cooldown_skill_id:SetValue('99001',false)
    assert(type(button.root.events.OnClick)=='function');local before=c.writes;assert(button.root.events.OnClick(button.root,'LeftButton'))
    assert(c.writes==before+4 and F:IsUnifiedCooldownTracked(99001),'late callback did not commit')
    local prior=c.writes;button:SetEnabled(false);assert(not button.root.events.OnClick(button.root,'LeftButton') and c.writes==prior,'disabled button still wrote')
end)
Test('duplicates preserve custom tracked entries without changing their classification',function()
    local S,F,p,h,c=Boot();assert(F.Commands:SetTrackedId(900000,'debuff',true))
    assert(F:ImportBuiltinPack('recommended',false));local first=Copy(F.State.settings.tracked)
    assert(F:ImportBuiltinPack('recommended',false))
    assert(Same(F.State.settings.tracked,first) and F:IsTrackedId(900000,'debuff'))
    local total=0
    for _,scope in ipairs({'player','target'}) do for _,category in ipairs({'buff','debuff','auto'}) do total=total+#(F.State.settings.tracked[scope][category] or {}) end end
    assert(F.lastLibraryImport.result.existing==total-2 and F.lastLibraryImport.result.total==total)
    assert(F.Commands:SetTrackedId(82,'auto',false));local kept=Copy(F.State.settings.tracked)
    local _,fresh=Boot({disk=c.disk})
    assert(Same(kept,fresh.State.settings.tracked) and not fresh:IsTrackedId(82),'reloading reimported a removed entry')
end)
Test('prepare failure logs failing stage without calling SaveData',function()
    local S,F,p,h,c=Boot();local before=c.writes;F.EnsureStoreLoaded=function()return false,'integrity_failed:test' end
    assert(not F.Commands:ImportBuiltinPack('recommended',true));assert(c.writes==before)
    assert(F.lastLibraryImport.stage=='prepare' and F.lastLibraryImport.error=='integrity_failed:test')
    local log=c.logs[#c.logs];assert(log.code=='BUFF_LIBRARY_IMPORT_FAILED' and log.context.stage=='prepare')
end)
Test('capacity rejection restores configuration and does not perform partial save',function()
    local S,F,p,h,c=Boot();local config=F.State.settings
    for i=1,1024 do config.tracked.player.auto[i]=900000+i end
    local before=Copy(config);local writes=c.writes
    assert(not F:ImportBuiltinPack('recommended',false))
    assert(Same(before,F.State.settings) and writes==c.writes and F.lastLibraryImport.stage=='mutate')
    assert(F.lastLibraryImport.result.rejected==1)
end)
Test('post-commit inline view exception reports durable saved status',function()
    local S,F,p,h,c=Boot();local view=h.widgets.v3_buff_library_table;local row=view.items[1]
    view.SetItems=function()error('injected_view_exception')end
    local col;for _,v in ipairs(view.spec.columns)do if v.id=='player_buff'then col=v end end
    assert(col.onClick(row)==true and F:IsTrackedPlacement(row.id,'player','buff') and c.writes>=4)
    assert(h.widgets.v3_buff_library_status.text:find('追踪已保存',1,true))
    local log=c.logs[#c.logs];assert(log.code=='BUFF_TRACKING_UI_FAILED' and log.context.committed==true)
end)
Test('unchanged owner-first aura events do not rebind table or query Native',function()
    local S,F,p,h,c,Pump=Boot();local view=h.widgets.v3_buff_library_table
    view.spec.bindRow({},view.items[1]);Pump()
    local sets=0;local base=view.SetItems;view.SetItems=function(self,...)sets=sets+1;return base(self,...)end
    local calls=c.tooltip
    for i=1,100 do S.Events:Publish('v3.buff_display.updated','aura')end
    assert(sets==0 and calls==c.tooltip and not S.Scheduler.tasks.v3_buff_management_metadata)
end)
Test('metadata batch and pending bounds still hold with real EventBus',function()
    local S,F,p,h,c,Pump=Boot();local view=h.widgets.v3_buff_library_table
    for i=1,80 do view.spec.bindRow({},view.items[i])end
    assert(F.managementMetadata.queued==64)
    local calls=c.tooltip;assert(S.Scheduler:RunTask('v3_buff_management_metadata'))
    assert(c.tooltip-calls==8 and F.managementMetadata.queued==56)
    Pump();assert(c.tooltip-calls==64 and not S.Scheduler.tasks.v3_buff_management_metadata)
    local before=c.tooltip;for i=1,64 do view.spec.bindRow({},view.items[i])end;Pump();assert(c.tooltip==before)
end)
Test('negative result diagnostics have bounded detached shapes and FIFO cache',function()
    local S,F,p,h,c=Boot({tooltip=function()return {name='x',description='DO_NOT_REPORT_TOOLTIP_BODY'}end})
    local M=S.Services.BuffMetadataV3
    for i=1,540 do M:GetInfo(800000+i,true)end
    local health=M:GetHealth();assert(health.cached==512 and health.iconMissing==540 and #health.samples==8)
    assert(not health.samples[1].first:find('DO_NOT_REPORT',1,true))
    health.samples[1].id=-1;assert(M:GetHealth().samples[1].id~=-1)
    assert(M.cache[tostring(800001)]==nil and M.evictions==28)
end)

Test('failed UI rebind does not mark revision as displayed forever',function()
    local S,F,p,h=Boot();local view=h.widgets.v3_buff_library_table;local first=view.items[1]
    local base=view.SetItems;local once=true
    view.SetItems=function(self,...)if once then once=false;error('injected_setitems_failure')end;return base(self,...)end
    S.Services.BuffMetadataV3:Remember(first.id,'icon','ui/icon/retry.dds')
    assert(not pcall(function()p:RefreshLibrary()end))
    assert(p:RefreshLibrary());assert(Find(view.items,first.id).iconPath=='ui/icon/retry.dds','revision acknowledged before UI accepted it')
end)
Test('manual input reset exception after commit does not claim tracking was unwritten',function()
    local S,F,p,h,c=Boot();assert(h.widgets.v3_buff_manage_view.spec.set('cooldowns'))
    local input=h.widgets.v3_buff_cooldown_skill_id;input:SetValue('99003',false);input.SetValue=function()error('input_reset_failed')end
    local ok,result=pcall(h.widgets.v3_buff_cooldown_add.onClick)
    assert(ok and result==true and c.writes>=4 and F:IsUnifiedCooldownTracked(99003))
    assert(h.widgets.v3_buff_tracking_status.text:find('已保存',1,true) and c.logs[#c.logs].code=='BUFF_TRACKING_UI_FAILED' and c.logs[#c.logs].context.committed)
end)
Test('bulk import preserves numeric window configuration through Transport3 loss model',function()
    local model=dofile('tools/rs_udf_numeric_test_host.lua')
    local S,F,p,h,c=Boot({nativeLoss=model.NativeLoss,productionButtons=true})
    -- State schema owns the window; use actual registered get/apply to avoid assumptions.
    assert(F:MutateStore(function()
        F.State.widgetWindow.userMoved=true;F.State.widgetWindow.coordinateSpace='logical-free-v2';F.State.widgetWindow.x=100;F.State.widgetWindow.y=120;F.State.widgetWindow.normalizedCenterX=0.82991701364517212;F.State.widgetWindow.normalizedCenterY=0.19861100614070892;return true
    end,0,'numeric_window_fixture',true))
    assert(F.Commands:ImportBuiltinPack('recommended',true))
    local before=Copy(F.State);assert(#before.settings.tracked.player.auto>390 and #before.settings.tracked.target.auto>390)
    local _,fresh=Boot({disk=c.disk})
    assert(math.abs(fresh.State.widgetWindow.normalizedCenterX-before.widgetWindow.normalizedCenterX)<0.000001)
    assert(math.abs(fresh.State.widgetWindow.normalizedCenterY-before.widgetWindow.normalizedCenterY)<0.000001)
    assert(Same(fresh.State.settings.tracked,before.settings.tracked))
end)
Test('late Native method installation can repair an unavailable cache entry',function()
    local S=Boot();local M=S.Services.BuffMetadataV3;X2Ability={};M:GetInfo(93,true)
    X2Ability.GetBuffTooltip=function()return {path='ui/icon/late_method.dds'}end
    local row=M:GetInfo(93,true);assert(row and row.iconPath=='ui/icon/late_method.dds')
end)
Test('real paged self-check includes import failure stage and Native shape without new reads',function()
    local S,F,p,h,c,Pump=Boot({saveFail=true,tooltip=function()return {description='BODY_NOT_FOR_REPORT',name='test'}end});c.failWrites=true
    dofile('core/rs_diagnostics.lua')
    S.FoundationGate={Run=function()return {status='READY',blockers=0,warnings=0,checks={}}end}
    S.LogBuffer={};S.RecordLog=function(level,source,message)
        local row={level=level,source=source,message=message,at=c.clock,seq=#S.LogBuffer+1}
        S.LogBuffer[#S.LogBuffer+1]=row
        if S.DiagnosticsManager.CaptureSelfCheckIssue then S.DiagnosticsManager:CaptureSelfCheckIssue(row)end
    end
    dofile('core/rs_report_copy_transport.lua');dofile('core/rs_self_check_report.lua')
    local view=h.widgets.v3_buff_library_table;view.spec.bindRow({},view.items[1]);Pump()
    assert(not F.Commands:ImportBuiltinPack('recommended',true))
    local calls=c.tooltip;local writes=c.writes
    local text,info=S.DiagnosticsManager:BuildPagedSelfCheckReport();assert(text,info)
    assert(text:find('status-library-eventbus-2',1,true) and text:find('stage="commit"',1,true))
    assert(text:find('BUFF_LIBRARY_IMPORT_FAILED',1,true) and text:find('description:string',1,true))
    assert(not text:find('BODY_NOT_FOR_REPORT',1,true) and c.tooltip==calls and c.writes==writes)
end)
print(string.format('LIBRARY RUNTIME RESULT %d passed / %d failed (%s)',passed,failed,_VERSION));if failed>0 then error('library runtime regressions failed')end
