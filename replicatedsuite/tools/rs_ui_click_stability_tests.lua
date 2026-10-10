-- 真实 RSUI 容器、虚拟数据视图和 Native OnClick；Native 隐藏取消按下采用显式故障模型。
-- 开发期门禁，不进入 toc.g，不代表 RU 客户端实测。
local passed,failed=0,0
local function Test(name,fn)
    local ok,err=xpcall(fn,debug.traceback)
    if ok then passed=passed+1;print('PASS click-stability '..name)
    else failed=failed+1;print('FAIL click-stability '..name..': '..tostring(err))end
end
local function Boot()
    local h=dofile('tools/rs_gear_page_test_host.lua')()
    h.parent=h.Native(nil,'click_test_parent',0,0,600,600)
    h.R=h.S.RSUI;h.clicks=0
    return h
end
local function Button(h,parent,id)
    return assert(h.R:Button({id=id,parent=parent,text=id,onClick=function()h.clicks=h.clicks+1;return true end,
        slot={size='fixed',width=90,height=26,hAlign='fill',vAlign='fill'}}))
end
local function Gesture(h,button,refresh)
    local ancestors={};local n=button.root
    while n do assert(n.shown~=false,'pressed target is hidden');ancestors[n]=true;n=n.parent end
    local cancelled=false;local ensure=h.UI.EnsureVisible
    h.UI.EnsureVisible=function(ui,n,visible,...)
        if ancestors[n] and n.shown~=false and visible==false then cancelled=true end
        return ensure(ui,n,visible,...)
    end
    refresh();h.R:FlushLayoutQueue(32)
    h.UI.EnsureVisible=ensure
    assert(not cancelled,'refresh hid the pressed button or its ancestor')
    local clicks=h.clicks
    assert(button.root.events.OnClick(button.root,'LeftButton'),'native click rejected')
    assert(h.clicks==clicks+1,'one click did not execute exactly once')
end
for _,orientation in ipairs({'horizontal','vertical'})do
    Test('SplitView '..orientation..' retains both pane buttons',function()
        local h=Boot();local c=assert(h.R:SplitView({id='click_split',parent=h.parent,orientation=orientation,
            mode='ratio',ratio=0.5,minPrimary=20,minSecondary=20}))
        local buttons={}
        for i=1,3 do buttons[i]=Button(h,c,'split_button_'..i)end
        c:Layout(0,0,400,180);h.R:FlushLayoutQueue(32)
        assert(buttons[3].root.shown==false,'third pane should be excluded')
        for i=1,2 do Gesture(h,buttons[i],function()c:Layout(0,0,400,180)end)end
        assert(buttons[3].root.shown==false,'refresh revived the excluded pane')
        assert(c:SetSplitRatio(0.7));assert(buttons[1].root.shown and buttons[2].root.shown)
        buttons[1]:SetVisible(false);c:Layout(0,0,400,180)
        assert(not buttons[1].root.shown and buttons[2].root.shown and buttons[3].root.shown,'pane replacement visibility is wrong')
    end)
    Test('ScrollBox '..orientation..' retains visible buttons and hides exited ones',function()
        local h=Boot();local c=assert(h.R:ScrollBox({id='click_scroll',parent=h.parent,orientation=orientation,gap=2,scrollbar=false}))
        local buttons={};for i=1,12 do buttons[i]=Button(h,c,'scroll_button_'..i)end
        local w,ht=orientation=='horizontal' and 200 or 140,orientation=='horizontal' and 36 or 86
        c:Layout(0,0,w,ht);h.R:FlushLayoutQueue(32)
        Gesture(h,buttons[1],function()c:Layout(0,0,w,ht)end)
        assert(c:SetScrollOffset(1));assert(not buttons[1].root.shown,'exited button stayed visible')
        Gesture(h,buttons[2],function()c:Layout(0,0,w,ht)end)
        assert(c:ScrollToBottom());assert(not buttons[2].root.shown,'top button remained at the bottom')
        assert(c:ScrollToTop());assert(buttons[1].root.shown,'scroll back did not restore target')
    end)
end
for _,kind in ipairs({'HorizontalBox','VerticalBox','UniformGrid','WrapBox','WidgetSwitcher'})do
    Test(kind..' keeps the active button visible during layout',function()
        local h=Boot();local c=assert(h.R[kind](h.R,{id='click_'..kind,parent=h.parent,gap=2,
            minCellWidth=90,minCellHeight=26,maxColumns=3,preferredColumns=3}))
        local first=Button(h,c,'click_first');local second=Button(h,c,'click_second')
        c:Layout(0,0,400,180);h.R:FlushLayoutQueue(32)
        Gesture(h,first,function()c:Layout(0,0,400,180)end)
        if kind=='WidgetSwitcher' then
            assert(c:SetActiveWidget(second));assert(not first.root.shown and second.root.shown)
            Gesture(h,second,function()assert(c:SetActiveWidget(second));c:Layout(0,0,400,180)end)
        end
    end)
end
for _,kind in ipairs({'ListView','TableView','TileView'})do
    Test(kind..' data refresh retains a live row click',function()
        local h=Boot();local items={};for i=1,20 do items[i]={id='item_'..i,name='name_'..i}end
        local c=assert(h.R[kind](h.R,{id='click_data_'..kind,parent=h.parent,items=items,selectable=true,
            rowHeight=24,desiredRows=4,scrollbar=false,tileWidth=100,tileHeight=26,fixedColumns=2,
            onItemActivated=function()h.clicks=h.clicks+1;return true end,
            onSelectionChanged=kind=='TileView' and function()h.clicks=h.clicks+1 end or nil,
            columns=kind=='TableView' and {{id='name',field='name',title='Name',size='fill',fill=1}} or nil}))
        c:Layout(0,0,360,150);h.R:FlushLayoutQueue(32)
        local host=c.list or c;local slot
        for _,candidate in ipairs(host.pool)do if (candidate.row or candidate.tile).root.shown then slot=candidate;break end end
        assert(slot,'no visible pooled row');local row=assert(slot.row or slot.tile)
        local root=row.root
        Gesture(h,row,function()
            local nextItems={};for i=1,20 do nextItems[i]={id='item_'..i,name='updated_'..i}end
            assert(c:SetItems(nextItems,'revision_2'))
        end)
        assert((slot.row or slot.tile).root==root,'refresh rebuilt the pressed row')
    end)
end
Test('SegmentedSelector refresh neither cancels nor duplicates a click',function()
    local h=Boot();local value='a'
    local c=assert(h.R:SegmentedSelector({id='click_segments',parent=h.parent,
        items={{value='a',text='A'},{value='b',text='B'}},get=function()return value end,
        set=function(v)value=v;h.clicks=h.clicks+1;return true end}))
    c:Layout(0,0,200,30);h.R:FlushLayoutQueue(32)
    Gesture(h,c.buttons[2],function()for i=1,10 do c:Render()end end)
    assert(value=='b' and c.buttons[2].state.selected,'selected state did not follow the command')
end)
Test('Toggle refresh retains one native click',function()
    local h=Boot();local value=false
    local c=assert(h.R:Toggle({id='click_toggle',parent=h.parent,
        get=function()return value end,set=function(v)value=v;h.clicks=h.clicks+1;return true end}))
    c:Layout(0,0,160,30);h.R:FlushLayoutQueue(32)
    Gesture(h,c,function()for i=1,10 do c:Render()end end)
    assert(value==true,'toggle did not apply the requested state')
end)
Test('Dropdown refresh retains an open option click and closes hit testing',function()
    local h=Boot();local value='a'
    -- 只替换 RU 屏幕定位边界；下拉选项池、刷新、绑定和 Native OnClick 使用生产实现。
    h.R.PopupPositioning={
        ResolveDropdown=function(_,control,opts)return {width=opts.popupWidth,height=opts.rowHeight*math.min(#control.items,opts.maxVisible)},nil,{visibleRows=opts.maxVisible}end,
        ApplyNativeRelativePopup=function(_,popup,control,owner,opts)popup:SetExtent(opts.width,opts.height);return true end,
        CorrectNativePopupToScreen=function()return true end,
    }
    local items={{value='a',text='A'},{value='b',text='B'},{value='c',text='C'}}
    local c=assert(h.R:Dropdown({id='click_dropdown',parent=h.parent,items=items,
        get=function()return value end,set=function(v)value=v;h.clicks=h.clicks+1;return true end}))
    c:Layout(0,0,200,30);h.R:FlushLayoutQueue(32)
    assert(c:Open());assert(c.open and c.popup.pickable)
    local option=assert(c.optionButtons[2])
    Gesture(h,{root=option},function()assert(c:SetItems(items));c:Layout(0,0,200,30)end)
    assert(value=='b' and not c.open,'option selection did not complete')
    assert(not c.popup.shown and not c.popup.pickable,'hidden popup can still intercept clicks')
    assert(c:Open());assert(c.popup.shown and c.popup.pickable,'reopening did not restore hit testing')
end)
print('RESULT click-stability passed='..passed..' failed='..failed..' ('.._VERSION..')')
if failed>0 then error('click stability regression')end
