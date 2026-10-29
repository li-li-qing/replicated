-- Replicated Suite · 今日历史与保护说明界面测试
-- 作者：Replicated
-- QQ群：1104129461
-- 使用真实 RSUI 控件、布局和 Native 点击；投影由固定样本隔离，不替代后端守恒/认证测试。
local passed,failed=0,0
local function Test(name,fn)
    local ok,err=pcall(fn)
    if ok then passed=passed+1;print('PASS '..name) else failed=failed+1;print('FAIL '..name..': '..tostring(err)) end
end
local function Boot()
    local h=dofile('tools/rs_gear_page_test_host.lua')({width=620,height=680})
    local S=h.S
    dofile('ui/framework/rs_ui_forms.lua')
    -- 本组只测试历史页面；导航与设置不是被测对象。
    S.Features.DPS={EnsureStoreLoaded=function()return true end,GetSettingsProjection=function()return {trackDamage=h.trackDamage==true,trackHealing=h.trackHealing==true}end}
    h.todayDate='2026-10-29';h.cachedTodayDate='2026-10-29';h.todayReads=0;h.queries={};h.protection=true
    local F={Commands={}}
    function F:EnsureStoreLoaded()return true end
    function F:GetCollectionScope()return 'self' end
    h.fileExports=0;h.fileImports=0
    function F.Commands:ExportPersonalHistoryFile()h.fileExports=h.fileExports+1;return false,'导出测试反馈'end
    function F.Commands:ImportPersonalHistoryFile()h.fileImports=h.fileImports+1;return false,'导入测试反馈'end
    function F.Commands:GetPersonalHistoryToday()
        h.todayReads=h.todayReads+1
        if not h.todayDate then return nil,'服务器日期暂不可用' end
        return h.todayDate
    end
    function F:GetPersonalHistoryProjection(range)
        range=range or {};h.queries[#h.queries+1]={fromDate=range.fromDate,toDate=range.toDate}
        local filtered=range.fromDate~=nil and range.fromDate~=''
        local rows={}
        for i=1,h.rowCount or 1 do rows[i]={date=filtered and range.fromDate or '2026-10-29',kills=3,deaths=2}end
        return {available=true,todayDate=h.cachedTodayDate,revision=1,complete=true,
            dateOptions={'2026-10-30','2026-10-29','2026-10-28'},
            totals={kills=filtered and 3 or 23,deaths=filtered and 2 or 12},
            rows=rows,
            protection=h.protection and {enabled=true,status=h.status or 'basic',protectedKills=filtered and 2 or 20,
                protectedDeaths=filtered and 1 or 10,legacyKills=filtered and 1 or 3,legacyDeaths=filtered and 1 or 2,
                error=h.guardError} or nil}
    end
    S.Features.CombatAnalytics=F
    dofile('presentation/v3/pages/rs_v3_combat_statistics_controls.lua')
    dofile('presentation/v3/pages/rs_v3_combat_personal_history_page.lua')
    local page=assert(S.UIV3.PageHost.factories['combat.personal_history'](h.page.spec.parent))
    assert(page:OnActivated());h.history=page;h.tree={}
    local function Index(node)h.tree[node.id]=node;for _,child in ipairs(node.children or {})do Index(child)end end
    Index(page)
    function h:ClickHistory(id)
        local button=assert(self.tree[id],id..' missing')
        return button.root.events.OnClick(button.root,'LeftButton')
    end
    function h:Arrange(width,height)
        self.page.spec.parent.width=width;self.page.spec.parent.height=height or 680
        self.history:Layout(0,0,width,height or 680);self.S.RSUI:FlushLayoutQueue(32)
    end
    return h
end
Test('history file actions remain visible above the scrollable daily records',function()
    local h=Boot();h.rowCount=40;assert(h.history:RefreshData())
    local body=assert(h.tree.v3_personal_history_page_body)
    for _,size in ipairs({{820,680},{620,580},{480,480}})do
        h:Arrange(size[1],size[2])
        for _,offset in ipairs({0,10000})do
            body:SetScrollOffset(offset,true);h:Arrange(size[1],size[2])
            for _,id in ipairs({'v3_history_file_export','v3_history_file_import','v3_history_text_mode'})do
                local button=assert(h.tree[id])
                assert(button.root.width>40 and button.root.height>=20,id..' has no clickable area')
                local ok,reason=h:VisibleRect(button);assert(ok,id..': '..tostring(reason))
            end
        end
    end
    assert(h:ClickHistory('v3_history_file_export')==false and h.fileExports==1)
    h:Arrange(480,480)
    assert(h:VisibleRect(h.tree.v3_history_transfer_status),'TXT failure feedback is outside the viewport')
    assert(h.tree.v3_history_transfer_status.text:find('导出测试反馈',1,true))
    assert(h:ClickHistory('v3_history_file_import')==false and h.fileImports==1)
    assert(h.tree.v3_history_transfer_status.text:find('导入测试反馈',1,true))
end)
Test('today click selects the current server day and remains reachable at narrow widths',function()
    local h=Boot();local today=assert(h.tree.v3_personal_history_today,'today shortcut missing')
    for _,width in ipairs({820,620,480})do
        h:Arrange(width)
        for _,id in ipairs({'v3_personal_history_today','v3_personal_history_from','v3_personal_history_to','v3_personal_history_all'})do
            local ok,reason=h:VisibleRect(h.tree[id]);assert(ok,tostring(reason))
        end
    end
    assert(h.todayReads==0,'ordinary page rendering must not sample the server clock')
    assert(h:ClickHistory(today.id))
    assert(h.todayReads==1,'today click must explicitly request the current server date')
    assert(h.tree.v3_personal_history_from:GetValue()=='2026-10-29' and h.tree.v3_personal_history_to:GetValue()=='2026-10-29','today did not set both date bounds')
    assert(h.tree.v3_personal_history_totals.text:find('击杀玩家 3',1,true),'today totals did not use the filtered projection')
    assert(h:ClickHistory('v3_personal_history_all'))
    assert(h.todayReads==1,'all dates must not request the server clock')
    assert(h.tree.v3_personal_history_from:GetValue()=='' and h.tree.v3_personal_history_to:GetValue()=='','all dates must clear today selection')
    assert(h.tree.v3_personal_history_totals.text:find('击杀玩家 23',1,true),'all dates lost cumulative totals')
end)
Test('daily history stays visible with long records, transfer feedback and tracking switches',function()
    local h=Boot();h.rowCount=17
    local body=assert(h.tree.v3_personal_history_page_body)
    for _,size in ipairs({{820,680},{620,580},{480,480}})do
        for _,amounts in ipairs({false,true,false})do
            h.trackDamage=amounts;h.trackHealing=amounts;assert(h.history:RefreshData())
            for _,offset in ipairs({0,10000})do
                body:SetScrollOffset(offset,true);h:Arrange(size[1],size[2])
                local active
                for _,view in ipairs(h.tree.v3_personal_history_table_host.children)do if view.visible then active=view end end
                assert(active and active:GetItem(17),'daily data vanished')
                assert(active.root.height>=72,'daily table has no usable viewport')
                local ok,reason=h:VisibleRect(active);assert(ok,'daily table disappeared: '..tostring(reason))
                for _,cell in ipairs(active.header.cells)do assert(h:VisibleRect(cell),'daily column was clipped')end
            end
        end
    end
    assert(h:ClickHistory('v3_history_file_import')==false)
    h:Arrange(480,480)
    local ok,reason=h:VisibleRect(h.tree.v3_personal_history_table_host)
    assert(ok,'import feedback hid the daily table: '..tostring(reason))
end)
Test('each today click rechecks the server day after midnight',function()
    local h=Boot();assert(h:ClickHistory('v3_personal_history_today'))
    h.todayDate='2026-10-30' -- 故意不 RefreshData，点击不能使用上一帧日期。
    assert(h:ClickHistory('v3_personal_history_today'))
    assert(h.todayReads==2,'each today click must request a fresh date')
    assert(h.tree.v3_personal_history_from:GetValue()=='2026-10-30' and h.tree.v3_personal_history_to:GetValue()=='2026-10-30','today reused a stale date')
end)
Test('unknown server day refuses today and preserves the selected dates',function()
    local h=Boot();assert(h.tree.v3_personal_history_from:SetValue('2026-10-28'));assert(h.tree.v3_personal_history_to:SetValue('2026-10-28'))
    h.todayDate=nil
    local ok=h:ClickHistory('v3_personal_history_today')
    assert(ok==false,'unknown day must reject the shortcut')
    assert(h.todayReads==1,'today must use the command even if the projection has an old valid date')
    assert(h.tree.v3_personal_history_from:GetValue()=='2026-10-28' and h.tree.v3_personal_history_to:GetValue()=='2026-10-28','unknown day changed an existing filter')
    assert(h.tree.v3_personal_history_range_hint.text:find('暂不可用',1,true),'unknown day requires visible feedback')
end)
Test('today protection summary uses filtered counts and distinguishes retained legacy records',function()
    local h=Boot();assert(h:ClickHistory('v3_personal_history_today'))
    local note=assert(h.tree.v3_personal_history_protection).text
    assert(note:find('基础保护',1,true) and note:find('击杀 2',1,true) and note:find('死亡 1',1,true),'protected counts did not use selected projection')
    assert(note:find('旧记录',1,true) and note:find('击杀 1',1,true),'retained legacy totals need a separate label')
    assert(not note:find('服务器认证',1,true),'offline checks must not claim server certification')
    h.status='failed';h.guardError='测试存档异常';assert(h.history:RefreshData())
    assert(h.tree.v3_personal_history_protection.text:find('校验失败',1,true),'failed protection was presented as healthy')
end)
Test('old projection hosts remain readable without invented protection claims',function()
    local h=Boot();h.protection=false;h.S.Features.CombatAnalytics.Commands.GetPersonalHistoryToday=nil;assert(h.history:RefreshData())
    assert(h.tree.v3_personal_history_totals.text:find('击杀玩家 23',1,true),'old hosts lost history totals')
    local note=assert(h.tree.v3_personal_history_protection)
    assert(note.visible==false or note.text=='','missing protection must not be presented as enabled')
    assert(h:ClickHistory('v3_personal_history_today'))
    assert(h.tree.v3_personal_history_from:GetValue()=='2026-10-29' and h.tree.v3_personal_history_to:GetValue()=='2026-10-29','old hosts lost the projection date fallback')
    assert(h.todayReads==0,'fallback should be used only when the command is absent')
end)
print('RESULT combat-history-today-ui passed='..passed..' failed='..failed)
if failed>0 then os.exit(1)end
