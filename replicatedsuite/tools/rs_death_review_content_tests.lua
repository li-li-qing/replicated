-- 真实 RSUI TableView/图标/布局，Native 绘制和命中为模型；不代表 RU 实机截图。
local NewHost=dofile('tools/rs_gear_page_test_host.lua')
local passed=0
local function Test(name,fn)fn();passed=passed+1;print('PASS death-content '..name)end
local function Boot(options)
    options=options or {}
    local h=NewHost({width=1200,height=800})
    dofile('ui/framework/rs_ui_text_layout.lua')
    local createLabel=h.UI.CreateLabel
    h.UI.CreateLabel=function(self,...)
        local label=createLabel(self,...)
        if options.lineHeight then label.style={GetLineHeight=function()return options.lineHeight end} end
        return label
    end
    local create=h.UI.CreateEmptyWidget
    h.UI.CreateEmptyWidget=function(self,...)
        local root=create(self,...)
        function root:CreateIconDrawable()
            return {SetExtent=function(self,w,height)self.width,self.height=w,height end,AddAnchor=function()end}
        end
        return root
    end
    h.UI.SetIconTexture=function(_,drawable,path)drawable.path=path;return true end
    dofile('presentation/v3/widgets/rs_v3_death_review_content.lua')
    local c=h.S.UIV3.DeathReviewContent:Create(h.page,'test_death');return h,c
end
local function Record()
    return {serial=1,time=5000,noticeTime=5000,clock='12:00:00',windowMs=10000,totalDamage=999,
        buffs={{name='护盾',stack=2,timeLeft=8000,path='buff.dds'}},debuffs={{name='流血',stack=1,timeLeft=3000,path='debuff.dds'}},
        statusSnapshot={time=4500,buff='complete',debuff='complete'}}
end
Test('all three independent lists contain an icon column and frozen status text',function()
    local h,c=Boot();c:Render({{timeText='-0.1s',source='Enemy',ability='Skill',amount=999,iconPath='skill.dds'}},Record())
    for _,list in ipairs({c.timeline,c.debuffs,c.buffs})do
        assert(list.spec.scrollbar==true and list.spec.columns[1].cellType=='icon')
        assert(list.list.items[1].iconPath and list.list.items[1].iconPath~='')
    end
    assert(c.buffs.list.items[1].timeText=='8.0s' and c.buffs.list.items[1].name:find('×2',1,true))
    assert(c.statusHint.text:find('0.5',1,true),'capture gap missing')
    c.root:Layout(0,0,740,440)
    for _,list in ipairs({c.timeline,c.debuffs,c.buffs})do
        local row=assert(list.list:GetRowForIndex(1));assert(row.cells[1].icon.path==list.list.items[1].iconPath,'icon not bound to Native drawable')
    end
end)
local function TextLines(component)
    local result={}
    if component.lineLabels then
        for _,label in ipairs(component.lineLabels)do
            if label.shown~=false and label.text~='' then result[#result+1]=label end
        end
    elseif component.root and component.root.shown~=false and component.text~='' then result[1]=component.root end
    return result
end
Test('low native line height never overlaps the two summary lines',function()
    local h,c=Boot({lineHeight=6});local r=Record()
    r.lethal={source='Gattornero',ability='火球术',amount=9020}
    c:Render({},r);c.root:Layout(0,0,408,234)
    local lines=TextLines(c.summary)
    if c.lethalSummary then for _,label in ipairs(TextLines(c.lethalSummary))do lines[#lines+1]=label end end
    assert(#lines==2,'summary lost its lethal line')
    local function AbsoluteY(label)local y=0;while label do y=y+(label.y or 0);label=label.parent end;return y end
    assert(AbsoluteY(lines[2])-AbsoluteY(lines[1])>=13,'summary baselines overlap with GetLineHeight=6')
end)
Test('Chinese skills and sources stay in single line cells with full truncation tooltip',function()
    local h,c=Boot({lineHeight=6});local rows={}
    for i,name in ipairs({'圆月斩','突击','地狱长枪：暴风','女萨兰之锤','裂裂斩：迷梦','火球术'})do
        rows[i]={timeText='-0.1s',source='Teresa @ 长名称服务器',ability=name..' · 长技能名称',amount=9020,iconPath='skill.dds'}
    end
    c:Render(rows,Record())
    for _,size in ipairs({{408,234},{438,230},{740,440},{1100,640}})do
        c.root:Layout(0,0,size[1],size[2])
        local previousBottom
        for i=1,math.min(#rows,c.timeline.list:GetVisibleCapacity())do
            local row=assert(c.timeline.list:GetRowForIndex(i))
            local skill,source
            for _,cell in ipairs(row.cells)do
                if cell.text==rows[i].ability then skill=cell end
                if cell.text==rows[i].source then source=cell end
                local lines=TextLines(cell)
                assert(#lines<=1,'damage cell has overlapping native lines')
            end
            assert(skill and source,'skill and source must have independent readable cells')
            assert(skill.x+skill.width<=source.x+0.1,'skill and source columns overlap')
            assert(skill.root.text:find('\n',1,true)==nil and source.root.text:find('\n',1,true)==nil)
            if previousBottom then assert(row.y>=previousBottom-0.1,'damage rows overlap')end
            previousBottom=row.y+row.height
        end
        local row=assert(c.timeline.list:GetRowForIndex(1))
        if size[1]==408 then
            local tip=row:GetTruncatedTooltipText()
            assert(tip:find(rows[1].ability,1,true) and tip:find(rows[1].source,1,true),'narrow columns lost full text tooltip')
        end
        for _,list in ipairs({c.timeline,c.debuffs,c.buffs})do
            assert(list.list:GetVisibleCapacity()>=1,'low line height/minimum window lost its row viewport')
        end
    end
end)
Test('old records show uncollected buff rather than none',function()
    local h,c=Boot();c:Render({}, {serial=1,time=5000,debuffs={{name='Legacy',stack=1,path='legacy.dds'}}})
    assert(c.buffTitle.text:find('未采集',1,true));assert(c.debuffs.list.items[1].iconPath=='legacy.dds')
    assert(c.debuffTitle.text:find('旧记录',1,true))
end)
Test('partial and failed scans stay visible independently',function()
    local h,c=Boot();local r=Record();r.statusSnapshot.buff='unavailable';r.statusSnapshot.debuff='partial';r.buffs={}
    c:Render({},r);assert(c.buffTitle.text:find('读取失败',1,true));assert(c.debuffTitle.text:find('部分',1,true))
end)
Test('empty complete snapshot says none and unknown time never becomes zero seconds',function()
    local h,c=Boot();local r=Record();r.buffs={};r.debuffs[1].timeLeft=nil;c:Render({},r)
    assert(c.buffTitle.text:find('无',1,true));assert(c.debuffs.list.items[1].timeText=='--')
end)
Test('narrow and wide content keeps two columns and scroll areas inside their parents',function()
    local h,c=Boot();c:Render({},Record())
    for _,size in ipairs({{408,234},{438,230},{740,440},{1100,640}})do
        c.root:Layout(0,0,size[1],size[2])
        assert(c.damagePanel.width>c.statusPanel.width and c.statusPanel.width>0)
        assert(c.statusPanel.x>=c.damagePanel.x+c.damagePanel.width,'columns overlap')
        for _,list in ipairs({c.timeline,c.debuffs,c.buffs})do
            assert(list.height>0 and list.width>0)
            assert(list.list:GetVisibleCapacity()>=1,'list lost its visible rows at minimum size')
            local ok,why=h:VisibleRect(list);assert(ok,why)
        end
    end
end)
Test('real page history picker switches damage and status together and keeps selection',function()
    local h=NewHost({width=1200,height=800});local s=h.S
    dofile('ui/framework/rs_ui_forms.lua')
    s.UI.CreateWindowShell=function()error('Native window not used by page test')end
    dofile('core/rs_demand.lua');dofile('ui/framework/rs_ui_floating_surface.lua')
    s.FeatureRuntime.RegisterImplementation=function()return true end
    s.FeatureRuntime.GetSnapshot=function()return {enabled=true}end
    dofile('features/combat/death_review/rs_death_review_store.lua')
    dofile('features/combat/death_review/rs_death_review_authority.lua')
    dofile('features/combat/death_review/rs_death_review_feature.lua')
    dofile('presentation/v3/widgets/rs_v3_widget_host.lua')
    dofile('presentation/v3/widgets/rs_v3_death_review_content.lua')
    dofile('presentation/v3/pages/rs_v3_death_review_page.lua')
    local f=s.Features.DeathReview
    for i=1,2 do local r=Record();r.schemaVersion=2;r.clock='12:00:0'..i;r.buffs[1].name='Buff '..i
        r.events={{time=5000,source='Enemy',ability='Skill '..i,amount=999,iconPath='skill.dds'}};assert(f:CommitDeathRecord(r)) end
    local page=assert(s.UIV3.PageHost.factories['combat.death_review'](h.page,'combat.death_review'))
    assert(page:OnActivated());page:Layout(0,0,1100,700)
    assert(page.selectedSerial==2 and #page.historyPicker.items==2)
    assert(page.historyPicker:SetSelectedValue(1,false,'test'))
    assert(page.detail.timeline.list.items[1].ability=='Skill 1' and page.detail.buffs.list.items[1].name:find('Buff 1',1,true))
    assert(page:Refresh());assert(page.selectedSerial==1 and page.historyPicker:GetValue()==1)
    assert(f:DeleteRecord(1));page:Refresh();assert(page.selectedSerial==2)
    assert(f:ClearHistory());page:Refresh();assert(page.selectedSerial==nil and #page.detail.buffs.list.items==0)
end)
print('DEATH_REVIEW_CONTENT PASS: '..passed..' cases (Native modeled)')
