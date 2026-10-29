-- Replicated Suite · 个人历史导出与页面诊断回归
-- 作者：Replicated
-- QQ群：1104129461
-- 运行真实历史/持久化/交换协议/页面回调；只替换 Native 文本接收边界，不冒充 RU 实测。
local passed,failed=0,0
local function Test(name,fn)
    local ok,err=xpcall(fn,debug.traceback)
    if ok then passed=passed+1;print('PASS history-transfer '..name)
    else failed=failed+1;print('FAIL history-transfer '..name..': '..tostring(err)) end
end
local function Boot(options)
    options=options or {}
    local h=dofile('tools/rs_gear_page_test_host.lua')();local S=h.S
    S.Features.CombatAnalytics={}
    S.Services.CombatAnalyticsV3={RegisterMetric=function()return true end,GetCollectionScope=function()return 'self'end,
        GetMetric=function()end,GetHealth=function()return {}end,SetStatisticsPolicy=function()return true end}
    S.Services.UnitIdentityV3={player={name='GearTest',nameWithWorld='GearTest@World',id='self-id'}}
    local day=1
    S.Utils.GetServerTime=function()return {year=2026,month=options.days and math.floor((day-1)/28)+1 or 10,
        day=options.days and (day-1)%28+1 or day,hour=8,minute=30}end
    dofile('core/rs_report_copy_transport.lua')
    dofile('core/rs_diagnostic_export.lua')
    dofile('features/combat/analytics/rs_combat_analytics_store.lua')
    dofile('features/combat/analytics/rs_combat_personal_history.lua')
    dofile('features/combat/analytics/rs_combat_history_transfer.lua')
    dofile('features/combat/analytics/rs_combat_analytics_feature.lua')
    -- 交换页面同样读取统计偏好；沿用生产 Store，只替代本用例未加载的 DPS 投影入口。
    dofile('features/combat/dps/rs_dps_store.lua')
    S.Features.DPS.GetSettingsProjection=function(self) return S.Utils.DeepCopy(self:GetSettings()) end
    h.F=S.Features.CombatAnalytics;h.H=h.F.PersonalHistory
    assert(h.H:EnsureLoaded())
    if options.seed~=false then
        for i=1,options.days or 8 do day=i;h.ms=h.ms+1500;assert(h.H:Record({damage=i*123456,kills=i,deaths=1}))end
    end
    if options.protected then
        dofile('core/rs_combat_history_auth.lua');dofile('features/combat/analytics/rs_combat_history_guard.lua')
        dofile('features/combat/analytics/rs_combat_history_transfer.lua')
    end
    local u=dofile('tools/rs_status_ui_test_host.lua')(S);h.u=u
    S.UIV3Design.CombatStatisticsControls=function()return {Render=function()end}end
    S.UIV3Design.CancelCombatStatisticsRefresh=function()end
    local edit=u.edit
    function edit:SetText(value)
        if options.rejectHidden and self.parent.visible==false then return false end
        if options.reject then return false end
        self.text=value:sub(1,options.capacity or 8192);return true
    end
    function edit:GetText()
        if options.readThrows then error('native_read_failure')end
        return self.text
    end
    -- 故意声明8192而实际只收512，复刻“声明长度不等于真实回读容量”的 Native 故障模型。
    function edit:MaxTextLength()return 8192 end
    dofile('presentation/v3/pages/rs_v3_combat_personal_history_page.lua')
    h.page=assert(S.UIV3.PageHost.factories['combat.personal_history'](u.Node({id='history_parent'})))
    for _,id in ipairs({'v3_personal_history_from','v3_personal_history_to'})do
        u.widgets[id].GetValue=function(self)return self.value or ''end -- 补齐测试宿主的只读文本查询边界。
    end
    function h:Click(id)return assert(self.u.widgets[id]).spec.onClick()end
    function h:Report()return self.F:DescribeDiagnosticDetail()end
    return h
end
local function ImportFile(h,packet)
    local text='RSCH-FILE-1|'..packet.packageId..'|'..#packet.payload..'\n'..packet.payload
    local chunks={}
    for index=1,#text,1024 do chunks[#chunks+1]=(text:sub(index,index+1023):gsub('.',function(c)return string.format('%02X',c:byte())end))end
    return {protocol='RS-COMBAT-HISTORY-IMPORT-1',byte_count=tostring(#text),checksum=h.S.ReportCopyTransport:CopyChecksum(text),chunks=chunks}
end
Test('TXT export bypasses the broken editor and saves a separately verified file snapshot',function()
    local h=Boot({reject=true,capacity=262})
    assert(type(h.F.Commands.ExportPersonalHistoryFile)=='function','history TXT export is missing')
    assert(h:Click('v3_history_file_export'),'TXT export still depends on the editor')
    local d=h:Report().history.transfer
    assert(d.stage=='file_snapshot_ready' and d.ready==true and d.action=='export_file')
    local key='replicated_suite_v1_combat_history_export'
    assert(h.disk[key] and h.disk[key..'_page_0001'],'file mailbox was not written')
    assert(h.disk[key].protocol=='RS-COMBAT-HISTORY-FILE-1','history overwrote the diagnostic mailbox')
    assert(h.disk.replicated_suite_v1_diagnostic_export==nil)
    assert(h.H:GetProjection().totals.kills==36 and h.u.edit.text=='','file export touched editor or totals')
end)
Test('prepared TXT imports through the same history authority and deduplicates',function()
    local source=Boot();local packet=assert(source.F.Commands:ExportPersonalHistory())
    local target=Boot({seed=false,reject=true});target.S.CombatHistoryImportFile=ImportFile(source,packet)
    assert(type(target.F.Commands.ImportPersonalHistoryFile)=='function','history TXT import is missing')
    assert(target:Click('v3_history_file_import'))
    assert(target.H:GetProjection().totals.kills==36 and target.H:GetProjection().totals.damage==4444416)
    local writes=target.writes
    assert(target:Click('v3_history_file_import'))
    assert(target.writes==writes and target.H:GetProjection().totals.kills==36,'duplicate TXT was counted twice')
    assert(target:Report().history.transfer.stage=='file_import_ready')
end)
Test('missing prepared TXT requests the file step without reporting a transfer failure',function()
    local h=Boot({seed=false});local warnings=0
    h.S.DiagnosticsManager={Emit=function()warnings=warnings+1 end}
    local writes=h.writes
    local ok,message,code=h.F.Commands:ImportPersonalHistoryFile()
    assert(ok==false and code=='file_not_prepared' and message:find('导入战斗历史.cmd',1,true),'missing file was not distinguished from corrupt input')
    local d=h.H:GetTransferDiagnostics()
    assert(d.stage=='file_waiting' and not d.lastError and d.failures==0 and warnings==0,'normal import preparation became a fault')
    assert(h.writes==writes and h.H:GetProjection().totals.kills==0)
    assert(h:Click('v3_history_file_import')==false)
    local text=h.u.widgets.v3_history_transfer_status.text
    assert(not text:find('失败',1,true) and text:find('导入战斗历史.cmd',1,true),'missing-file instructions still look like a broken import')
    h.S.CombatHistoryImportFile={protocol='unexpected'}
    assert(h.F.Commands:ImportPersonalHistoryFile()==false and warnings==1,'malformed prepared input was silently accepted')
end)
Test('truncated prepared TXT is rejected without saving partial history',function()
    local source=Boot();local packet=assert(source.F.Commands:ExportPersonalHistory())
    local target=Boot({seed=false});target.S.CombatHistoryImportFile=ImportFile(source,packet)
    local chunks=target.S.CombatHistoryImportFile.chunks;chunks[#chunks]=chunks[#chunks]:sub(1,-3)
    assert(type(target.F.Commands.ImportPersonalHistoryFile)=='function','history TXT import validation is missing')
    local writes=target.writes
    local ok,err=target.F.Commands:ImportPersonalHistoryFile()
    assert(ok==false and type(err)=='string' and target.writes==writes and target.H:GetProjection().totals.kills==0)
    assert(target:Report().history.transfer.lastError,'file failure omitted from diagnostics')
end)
Test('TXT import rejects another character without writing the history',function()
    local source=Boot();local packet=assert(source.F.Commands:ExportPersonalHistory())
    local target=Boot({seed=false});target.S.CombatHistoryImportFile=ImportFile(source,packet)
    X2Unit.UnitNameWithWorld=function()return 'Another@World'end;local writes=target.writes
    local ok,err=target.F.Commands:ImportPersonalHistoryFile()
    assert(ok==false and type(err)=='string' and target.writes==writes,tostring(err))
end)
Test('TXT import never clears local totals when the durable save fails',function()
    local source=Boot();local packet=assert(source.F.Commands:ExportPersonalHistory())
    local target=Boot({seed=false});target.S.CombatHistoryImportFile=ImportFile(source,packet)
    target.failSave=true;local ok,err=target.F.Commands:ImportPersonalHistoryFile()
    assert(ok==false and err and target.H:GetProjection().totals.kills==0 and target.H.state.sync==nil)
    assert(target:Report().history.transfer.stage=='file_merge')
end)
Test('overlapping old TXT waits for explicit confirmation before the single merge',function()
    local source=Boot();local packet=assert(source.F.Commands:ExportPersonalHistory())
    local target=Boot();assert(target.H:Record({kills=2}));target.S.CombatHistoryImportFile=ImportFile(source,packet)
    local writes=target.writes;local ok,result=target:Click('v3_history_file_import')
    assert(ok and result.requiresConfirmation and target.writes==writes and target.H:GetProjection().totals.kills==38)
    assert(target.u.widgets.v3_history_file_import.text=='确认合并')
    ok,result=target:Click('v3_history_file_import')
    assert(ok and result.complete and target.H:GetProjection().totals.kills==74)
    writes=target.writes;assert(target:Click('v3_history_file_import'));assert(target.writes==writes)
end)
Test('TXT snapshot readback failure is retained and never reported as a saved file',function()
    local h=Boot();h.S.Api.LoadData=function(_,key)
        if key:match('^replicated_suite_v1_combat_history_export')then return {}end
        return h.Copy(h.disk[key])
    end
    local ok,err=h.F.Commands:ExportPersonalHistoryFile()
    assert(ok==false and err:find('回读',1,true))
    assert(h:Report().history.transfer.stage=='file_save' and h:Report().history.transfer.ready==false)
    assert(h.disk.replicated_suite_v1_combat_history_export==nil,'failed page published a new manifest')
end)
Test('truncated first page repacks the same export without another save',function()
    local h=Boot({capacity=512});local kills=h.H:GetProjection().totals.kills
    assert(h:Click('v3_history_transfer_export'),'Native truncation still blocks export')
    local d=assert(h:Report().history.transfer)
    assert(d.stage=='display_ready' and d.readbackFailures>=1 and d.repages>=1,'recovery evidence omitted')
    assert(d.expectedBytes==d.actualBytes and d.actualBytes<=512 and d.partCount>1,'page was not fully received')
    local writes=h.writes;local first=h.u.edit.text
    assert(h:Click('v3_history_transfer_next'));assert(h:Click('v3_history_transfer_previous'))
    assert(h.u.edit.text==first and h.writes==writes,'paging changed snapshot or saved history again')
    assert(h.H:GetProjection().totals.kills==kills,'export changed existing kills')
end)
Test('editor becomes visible before the first Native write',function()
    local h=Boot({rejectHidden=true})
    assert(h:Click('v3_history_transfer_export'),'export writes while its Native parent is hidden')
end)
Test('Native failure is retained in the module report without rerunning the export',function()
    local h=Boot({reject=true})
    assert(h:Click('v3_history_transfer_export')==false)
    local writes=h.writes;local d=assert(h:Report().history.transfer)
    assert(d.stage=='set_text' and d.lastError and d.failures>=1,'module report omitted the failed UI boundary')
    assert(h.u.widgets.v3_history_transfer_status.text:find(d.lastError,1,true),'visible error has no actionable detail')
    d.lastError='mutated';assert(h:Report().history.transfer.lastError~='mutated','report exposes mutable diagnostics')
    assert(h.writes==writes,'diagnostic report reran export or saved data')
end)
Test('backend save failure is recorded at its own stage and preserves the history',function()
    local h=Boot();local kills=h.H:GetProjection().totals.kills;h.failSave=true
    assert(h:Click('v3_history_transfer_export')==false)
    local d=assert(h:Report().history.transfer)
    assert(d.stage=='save' and d.lastError and d.failures>=1,'backend export failure was only shown in UI')
    assert(h.H:GetProjection().totals.kills==kills and h.H.state.sync==nil,'failed export enrolled half a source')
end)
Test('smaller verified export pieces import exactly once and retain all totals',function()
    local source=Boot();local packet=assert(source.F.Commands:ExportPersonalHistory())
    local writes=source.writes
    local smaller=assert(source.F.Commands:RepagePersonalHistoryExport(packet,256))
    assert(smaller.packageId==packet.packageId and source.writes==writes,'repack changed identity or saved again')
    local target=Boot({seed=false})
    for _,part in ipairs(smaller.parts)do local ok,result=target.F.Commands:ImportPersonalHistory(part);assert(ok,result)end
    assert(target.H:GetProjection().totals.kills==36 and target.H:GetProjection().totals.damage==4444416,'smaller pieces lost data')
    for _,part in ipairs(smaller.parts)do local ok,result=target.F.Commands:ImportPersonalHistory(part);assert(ok,result)end
    assert(target.H:GetProjection().totals.kills==36,'duplicate import counted history twice')
end)
Test('repaging rejects an incomplete packet even when the encoder is unavailable',function()
    local h=Boot();local packet=assert(h.F.Commands:ExportPersonalHistory());local writes=h.writes
    packet.packageId=nil;h.S.ReportCopyTransport=nil
    local value,err=h.F.Commands:RepagePersonalHistoryExport(packet,256)
    assert(value==nil and type(err)=='string','incomplete export packet was accepted')
    assert(h.writes==writes,'invalid repaging wrote to history')
end)
-- 已经交付给用户的段号不能因下一段回读失败而悄悄变化；恢复容量后重试同一段即可。
Test('capacity changes after first delivery never change the frozen segment boundaries',function()
    local options={capacity=512};local h=Boot(options)
    assert(h:Click('v3_history_transfer_export'));local first=h.u.edit.text
    local d=h:Report().history.transfer;local count,repages,writes=d.partCount,d.repages,h.writes
    options.capacity=128;assert(h:Click('v3_history_transfer_next')==false)
    d=h:Report().history.transfer
    assert(d.partCount==count and d.repages==repages and d.stage=='readback','later page silently changed boundaries')
    assert(d.partIndex==2,'failed second page was mislabeled as the previous successful first page')
    options.capacity=512;assert(h:Click('v3_history_transfer_next'));assert(h:Click('v3_history_transfer_previous'))
    assert(h.u.edit.text==first and h.writes==writes)
end)
-- 回读异常或内容被改写不能冒充容量问题重切；诊断必须保留真正失败的Native边界。
Test('read exceptions are actionable diagnostic failures instead of guessed capacities',function()
    local h=Boot({readThrows=true})
    assert(h:Click('v3_history_transfer_export')==false)
    local d=h:Report().history.transfer
    assert(d.stage=='readback' and d.actualBytes==-1 and d.actualType=='read_error' and d.repages==0)
    assert(d.lastError:find('native_read_failure',1,true),'the actual Native read exception was dropped')
end)
-- 可变分段仍受总包预算约束；合法校验的小段也不能累计超过声明长度，更不能改动接收方历史。
Test('variable pieces reject a cumulative size overflow before touching the store',function()
    local source=Boot();local packet=assert(source.F.Commands:ExportPersonalHistory())
    packet=assert(source.F.Commands:RepagePersonalHistoryExport(packet,256))
    local header,body=packet.parts[1]:match('^([^\n]+)\n(.*)$');local fields={}
    for value in header:gmatch('[^|]+')do fields[#fields+1]=value end
    local target=Boot({seed=false});local writes=target.writes;local rejected=false
    for index=1,packet.partCount do
        fields[4]=tostring(index)
        local ok,err=target.F.Commands:ImportPersonalHistory(table.concat(fields,'|')..'\n'..body)
        if not ok then assert(err:find('累计长度',1,true));rejected=true;break end
    end
    assert(rejected and target.writes==writes and target.H:GetProjection().totals.kills==0,'invalid packet wrote partial history')
end)
-- 旧默认7000字节分段继续可读；修复只能放宽合法短段，不能破坏已有跨电脑备份。
Test('legacy fixed size history exports remain importable',function()
    local source=Boot();local packet=assert(source.F.Commands:ExportPersonalHistory());local target=Boot({seed=false})
    for _,part in ipairs(packet.parts)do local ok,result=target.F.Commands:ImportPersonalHistory(part);assert(ok,result)end
    assert(target.H:GetProjection().totals.kills==36 and target.H:GetProjection().totals.deaths==8)
end)
-- 必须验证用户真正交付的合并TXT，而非仅断言UI内部有错误；报告生成本身仍保持只读。
Test('merged module TXT includes the actual failed export stage and Native error',function()
    local h=Boot({reject=true});assert(h:Click('v3_history_transfer_export')==false)
    dofile('features/rs_feature_registry.lua');dofile('core/rs_diagnostic_detail.lua');dofile('core/rs_module_diagnostics.lua')
    h.S.ModuleDiagnosticsHub:RegisterProvider('combat_stats','history_transfer',function()return h.F:DescribeDiagnosticDetail()end,30,{detailOnly=true})
    local writes=h.writes;local summary,err,text=h.S.ModuleDiagnosticsHub:BuildReport('combat_stats',{detailed=true})
    assert(summary,err)
    assert(text:find('set_text',1,true) and text:find('SetText返回false',1,true),'exported TXT still omitted the visible export failure')
    assert(h.writes==writes,'exporting diagnostic TXT modified personal history')
end)
Test('honor counts roundtrip with v2 while old v1 histories remain independently importable',function()
    local source=Boot({seed=false});assert(source.H:Record({kills=5,honorParticipations=14,deaths=2}))
    local packet=assert(source.F.Commands:ExportPersonalHistory())
    assert(packet.payload:match('^RS%-HISTORY%-2|'),'honor history did not use its extended protocol')
    local target=Boot({seed=false});target.S.CombatHistoryImportFile=ImportFile(source,packet)
    assert(target.F.Commands:ImportPersonalHistoryFile())
    local t=target.H:GetProjection().totals
    assert(t.kills==5 and t.honorParticipations==14 and t.deaths==2,'v2 merged distinct counting rules')
    local writes=target.writes;assert(target.F.Commands:ImportPersonalHistoryFile())
    assert(target.writes==writes and target.H:GetProjection().totals.honorParticipations==14,'v2 duplicate added honor twice')
    local saved=assert(target.S.Persistence:GetStore(target.H.StoreId));saved.loaded=false;target.H.loaded=false
    assert(target.H:EnsureLoaded() and target.H:GetProjection().totals.honorParticipations==14,'honor did not survive persistence')
    local legacy=Boot();local old=assert(legacy.F.Commands:ExportPersonalHistory())
    assert(old.payload:match('^RS%-HISTORY%-1|'),'unchanged history lost its v1 encoding')
    local empty=Boot({seed=false});empty.S.CombatHistoryImportFile=ImportFile(legacy,old)
    assert(empty.F.Commands:ImportPersonalHistoryFile())
    assert(empty.H:GetProjection().totals.kills==36 and empty.H:GetProjection().totals.honorParticipations==nil,'v1 import invented historical honor data')
end)
Test('matched honor estimates use v3 and preserve v2 baseline identity across repeated imports',function()
    local source=Boot({seed=false});assert(source.H:Record({kills=5,honorParticipations=14,deaths=2}))
    local v2=assert(source.F.Commands:ExportPersonalHistory())
    local target=Boot({seed=false});target.S.CombatHistoryImportFile=ImportFile(source,v2);assert(target.F.Commands:ImportPersonalHistoryFile())
    assert(source.H:Record({honorParticipations=2,honorKills=2}))
    local v3=assert(source.F.Commands:ExportPersonalHistory());assert(v3.payload:match('^RS%-HISTORY%-3|'))
    target.S.CombatHistoryImportFile=ImportFile(source,v3);assert(target.F.Commands:ImportPersonalHistoryFile())
    local t=target.H:GetProjection().totals
    assert(t.kills==5 and t.honorParticipations==16 and t.honorKills==2 and t.deaths==2,'v3 duplicated the v2 baseline or combined counters')
    local writes=target.writes;assert(target.F.Commands:ImportPersonalHistoryFile());assert(target.writes==writes)
    target.S.CombatHistoryImportFile=ImportFile(source,v2);assert(target.F.Commands:ImportPersonalHistoryFile())
    assert(target.H:GetProjection().totals.honorKills==2 and target.writes==writes,'old v2 replay reset or duplicated v3 estimates')
    local saved=target.S.Persistence:GetStore(target.H.StoreId);saved.loaded=false;target.H.loaded=false
    assert(target.H:EnsureLoaded() and target.H:GetProjection().totals.honorKills==2)
end)
print(string.format('HISTORY TRANSFER RESULT %d passed / %d failed (%s)',passed,failed,_VERSION))
assert(failed==0,'history transfer failures: '..failed)
-- Python/便携exe使用真实Lua写出的文件信箱进行跨语言往返，不把两端独立的假数据当成链路证明。
if arg and arg[1]=='--emit-file' then
    local h=Boot({reject=true,days=336,protected=arg[3]=='guard'})
    if arg[3]=='honor' then assert(h.H:Record({honorParticipations=14,honorKills=14})) end
    if arg[3]=='guard' then assert(h.H:Record({kills=1,deaths=1})) end
    assert(h.F.Commands:ExportPersonalHistoryFile())
    local file=assert(io.open(arg[2],'wb'))
    for key,value in pairs(h.disk)do
        if key:match('^replicated_suite_v1_combat_history_export')then
            local rows={'isTable true\n'}
            for name,child in pairs(value)do assert(type(child)=='string');rows[#rows+1]='str_'..name..' str_'..child..'\n'end
            local raw=table.concat(rows);assert(#raw<9000)
            file:write('account:addon_replicatedsuite_'..key,'\n',#raw,'\n',raw)
        end
    end
    file:close()
elseif arg and arg[1]=='--consume-file' then
    local h=Boot({seed=false,reject=true,protected=arg[3]=='guard'});dofile(arg[2])
    assert(h.F.Commands:ImportPersonalHistoryFile())
    local total=336*337/2
    assert(h.H:GetProjection().totals.kills==total+(arg[3]=='guard' and 1 or 0) and h.H:GetProjection().totals.damage==total*123456)
    if arg[3]=='honor' then assert(h.H:GetProjection().totals.honorParticipations==14 and h.H:GetProjection().totals.honorKills==14) end
    if arg[3]=='guard' then local g=h.H:GetProjection().protection;assert(g.protectedKills==1 and g.protectedDeaths==1 and g.legacyKills==total) end
    local writes=h.writes;assert(h.F.Commands:ImportPersonalHistoryFile());assert(h.writes==writes)
    print('HISTORY TXT ROUNDTRIP PASS')
elseif arg and arg[1]=='--reject-file' then
    local h=Boot({seed=false});local writes=h.writes;dofile(arg[2])
    local ok,err=h.F.Commands:ImportPersonalHistoryFile()
    assert(ok==false and err and h.writes==writes and h.H:GetProjection().totals.kills==0)
    assert(_G.HISTORY_EXECUTED==nil,'input TXT was executed as Lua')
    print('HISTORY TXT REJECTION PASS')
end
