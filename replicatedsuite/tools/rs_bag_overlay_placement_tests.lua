-- Replicated Suite · 背包悬浮栏实际尺寸与贴边位置回归（Lua 5.1 离线模型）
-- 作者：Replicated
-- QQ群：1104129461
-- 运行真实 Bag/Persistence/Layout/Windowing/BagQuickOverlay；沿用现有 BagAction
-- 宿主，仅补原生叶节点方法和视口度量。不代表 RU 拖动、绘制或文件系统实机验收。
local pass,fail=0,0
local function Test(name,fn)
    local ok,err=xpcall(fn,debug.traceback)
    if ok then pass=pass+1;print('PASS bag-overlay-placement '..name)
    else fail=fail+1;print('FAIL bag-overlay-placement '..name..': '..tostring(err)) end
end
local function Eq(actual,expected)
    assert(type(actual)=='number' and math.abs(actual-expected)<.001,tostring(actual)..' ~= '..tostring(expected))
end
local function Boot(options)
    options=options or {}
    local h=dofile('tools/rs_bag_action_test_host.lua')({disk=options.disk})
    local S=h.S
    h.viewportWidth,h.viewportHeight=options.width or 1920,options.height or 1080
    S.Constants={SafeArea=12,MinAddonScale=.5,MaxAddonScale=2,
        Breakpoint={COMPACT=1150,STANDARD=1700,WIDE=2300,NARROW_ONE_COLUMN=760}}
    S.Api.GetUiMetrics=function()
        return h.viewportWidth,h.viewportHeight,1,h.viewportWidth,h.viewportHeight,{source='bag_overlay_native_leaf'}
    end
    local function Decorate(n)
        function n:GetOffset()return self.x,self.y end
        function n:GetExtent()return self.width,self.height end
        function n:GetEffectiveOffset()
            local parent=self.parent=='UIParent' and UIParent or self.parent
            local x,y=0,0
            if parent and type(parent.GetEffectiveOffset)=='function' then x,y=parent:GetEffectiveOffset() end
            return x+self.x,y+self.y
        end
        function n:GetEffectiveExtent()return self.width,self.height end
        function n:StartMoving()self.moving=true;return true end
        function n:StopMovingOrSizing()self.moving=false;return true end
        function n:EnableDrag()return true end
        function n:Raise()return true end
        function n:IsVisible()return self.shown end
        return n
    end
    Decorate(UIParent)
    UIParent:SetExtent(h.viewportWidth,h.viewportHeight)
    for _,name in ipairs({'CreatePanel','CreateButton','CreateLabel','CreateEmptyWidget'})do
        local create=S.UI[name]
        S.UI[name]=function(self,...)return Decorate(create(self,...))end
    end
    S.UI.TrySetUILayer=function()return true end
    S.UI.EnsureAlpha=function()return true,false end
    S.RSUI.WindowPreferences={GetTopmost=function()return false end}
    dofile('core/rs_layout.lua')
    dofile('ui/framework/rs_ui_windowing.lua')
    h.overlay={visible=true,status=options.wide and '进行中' or '',statusAt=h.ms,
        running=options.wide==true,moved=1,queued=10,width=508}
    S.Features.tools_bag.GetProjection=function()return {quickOverlay=h.overlay}end
    dofile('presentation/v3/widgets/rs_v3_bag_quick_overlay.lua')
    h.presenter=assert(S.UIV3.BagQuickOverlay)
    assert(h.presenter:Refresh(),h.presenter.lastError)
    function h:SetWide(wide)
        self.overlay.running=wide==true
        self.overlay.status=wide and '进行中' or ''
        self.overlay.statusAt=self.ms
        return self.presenter:Refresh()
    end
    function h:Drag(x,y)
        local p=self.presenter
        assert(p.dragHandle.events.OnDragStart())
        p.root.x,p.root.y=x,y
        assert(p.dragHandle.events.OnDragStop())
    end
    function h:Rect()
        local n=self.presenter.root
        local x,y,w,hh=S.Layout:GetWindowLogicalRect(n)
        assert(S.Layout:IsRectFullyVisible(x,y,w,hh),'actual toolbar outside viewport: '..table.concat({tostring(x),tostring(y),tostring(w),tostring(hh)},','))
        return x,y,w,hh
    end
    function h:AssertEdges(horizontal,vertical)
        local x,y,w,hh=self:Rect();local c=S.Layout:GetContext()
        if horizontal=='LEFT' then Eq(x,c.safeLeft)
        elseif horizontal=='RIGHT' then Eq(x+w,c.logicalWidth-c.safeRight) end
        if vertical=='TOP' then Eq(y,c.safeTop)
        elseif vertical=='BOTTOM' then Eq(y+hh,c.logicalHeight-c.safeBottom) end
    end
    return h
end

Test('drag stores the actual quiet or wide visible rectangle',function()
    for _,wide in ipairs({false,true})do
        local h=Boot({wide=wide});h:Drag(9999,500)
        local x,y,w,hh=h:Rect();local state=h.presenter.positionState
        Eq(state.x,x);Eq(state.y,y)
        Eq(state.normalizedCenterX*h.viewportWidth-state.x,w/2)
        Eq(state.normalizedCenterY*h.viewportHeight-state.y,hh/2)
    end
end)
Test('wide right edge stays pinned when the message clears and returns',function()
    local h=Boot({wide=true});h:Drag(9999,500);h:AssertEdges('RIGHT')
    assert(h:SetWide(false));Eq(h.presenter.root.width,232);h:AssertEdges('RIGHT')
    assert(h:SetWide(true));Eq(h.presenter.root.width,508);h:AssertEdges('RIGHT')
end)
Test('both widths snap and retain all four edges and four corners across width changes',function()
    local cases={{18,300,'LEFT'},{9999,300,'RIGHT'},{500,18,nil,'TOP'},{500,9999,nil,'BOTTOM'},
        {18,18,'LEFT','TOP'},{9999,18,'RIGHT','TOP'},{18,9999,'LEFT','BOTTOM'},{9999,9999,'RIGHT','BOTTOM'}}
    for _,wide in ipairs({false,true})do
        local h=Boot({wide=wide})
        for _,point in ipairs(cases)do
            assert(h:SetWide(wide));h:Drag(point[1],point[2]);h:AssertEdges(point[3],point[4])
            assert(h:SetWide(not wide));h:AssertEdges(point[3],point[4])
            assert(h:SetWide(wide));h:AssertEdges(point[3],point[4])
        end
    end
end)
Test('hide and reopen preserves exact placement and each visible width',function()
    for _,wide in ipairs({false,true})do
        local h=Boot({wide=wide});h:Drag(9999,9999)
        local x,y,w,hh=h:Rect();h.overlay.visible=false;assert(h.presenter:Refresh())
        assert(not h.presenter.shown)
        h.overlay.visible=true;assert(h.presenter:Refresh())
        local nx,ny,nw,nh=h:Rect();Eq(nx,x);Eq(ny,y);Eq(nw,w);Eq(nh,hh)
        h.overlay.visible=false;assert(h.presenter:Refresh());assert(h:SetWide(not wide))
        h.overlay.visible=true;assert(h.presenter:Refresh());h:AssertEdges('RIGHT','BOTTOM')
    end
end)
Test('cold persistence restores both actual sizes and pinned edges on either viewport',function()
    for _,wide in ipairs({false,true})do
        local h=Boot({wide=wide});h:Drag(9999,9999);local disk=h.Copy(h.disk)
        local x,y,w,hh=h:Rect()
        local cold=Boot({disk=h.Copy(disk),wide=wide});local nx,ny,nw,nh=cold:Rect()
        Eq(nx,x);Eq(ny,y);Eq(nw,w);Eq(nh,hh);cold:AssertEdges('RIGHT','BOTTOM')
        for _,dimensions in ipairs({{1920,1080},{1280,720}})do
            local migrated=Boot({disk=h.Copy(disk),wide=not wide,width=dimensions[1],height=dimensions[2]})
            migrated:AssertEdges('RIGHT','BOTTOM')
            assert(migrated:SetWide(wide));migrated:AssertEdges('RIGHT','BOTTOM')
        end
    end
end)

print(string.format('BAG OVERLAY PLACEMENT RESULT %d passed / %d failed (%s)',pass,fail,_VERSION))
assert(fail==0,'bag overlay placement regression failures: '..fail)
