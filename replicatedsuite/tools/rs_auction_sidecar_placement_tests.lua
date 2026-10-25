-- Replicated Suite · 拍卖侧窗位置与缩小状态回读测试（Lua 5.1）
-- 作者：Replicated
-- QQ群：1104129461
-- 真实 Sidecar 创建参数/回调、Floating/Shell/Layout/Persistence；仅隔离业务内容与 Native。
local ViewportBoot=dofile('tools/rs_window_viewport_test_host.lua')
local pass,fail=0,0
local function Copy(v)if type(v)~='table'then return v end;local o={};for k,x in pairs(v)do o[k]=Copy(x)end;return o end
local function Test(name,fn)local ok,err=xpcall(fn,debug.traceback);if ok then pass=pass+1;print('PASS auction placement '..name)
    else fail=fail+1;print('FAIL auction placement '..name..': '..tostring(err))end end
local function Eq(a,b)assert(math.abs(a-b)<.001,tostring(a)..' ~= '..tostring(b))end
local STORE='v3.presentation.auction_sidecar_position'
local function Boot(disk)
    local h=ViewportBoot();local S=h.S;h.disk=disk or {};S.Config={settings={}}
    ADDON={LoadData=function(_,key)return Copy(h.disk[key])end,
        SaveData=function(_,key,value)if h.failSave then return false end;h.disk[key]=Copy(value);h.diskWrites=(h.diskWrites or 0)+1;return true end,
        ClearData=function()error('must not clear position saves')end}
    dofile('core/rs_utils.lua');dofile('core/rs_reuse.lua');dofile('core/rs_demand.lua')
    dofile('core/rs_api_capabilities.lua');dofile('core/rs_persistence_transport.lua');dofile('core/rs_persistence.lua')
    S.Features={tools_auction={IsSidecarEnabled=function()return false end}}
    S.Services={AuctionSurfaceV3={GetSnapshot=function()return {}end}}
    S.UIV3={WidgetHost={Register=function(_,id,spec)h.create=spec.create;return true end,
        BindFeatureLifecycle=function()return true end,IsVisible=function()return false end}}
    function h:CreateSidecar(w,hh)
        if w then self:Viewport(w,hh)end
        local floating=S.RSUI.FloatingSurface
        S.RSUI.FloatingSurface={Create=function(_,spec)h.sidecarSpec=spec;return nil,'capture business boundary'end}
        dofile('presentation/v3/widgets/rs_v3_auction_sidecar.lua')
        assert(h.create()==nil and h.sidecarSpec,'sidecar creation spec missing')
        S.RSUI.FloatingSurface=floating
        self.surface=assert(floating:Create(h.sidecarSpec));assert(self.surface:Show(true))
        self.controller=S.UIV3.AuctionSidecar
        return self.surface
    end
    return h
end
local function Drag(s,x,y)local n=s.shell.titleBar.root;assert(n.handlers.OnDragStart());s.window.x=x;s.window.y=y;n.handlers.OnDragStop()end
local function Corner(h,s,right,bottom)
    local x,y,w,hh=h.S.Layout:GetWindowLogicalRect(s.window);assert(h.S.Layout:IsRectFullyVisible(x,y,w,hh))
    local c=h.S.Layout:GetContext();Eq(right and x+w or x,right and c.logicalWidth-c.safeRight or c.safeLeft)
    Eq(bottom and y+hh or y,bottom and c.logicalHeight-c.safeBottom or c.safeTop)
end
Test('minimized action writes durable position and reloads the same compact rectangle',function()
    local h=Boot();local s=h:CreateSidecar();Drag(s,9999,9999);local before=h.diskWrites
    assert(s:SetMinimized(true));assert(h.diskWrites>before,'minimize was not saved')
    local x,y,w,hh=s.window.x,s.window.y,s.window.w,s.window.h;local disk=Copy(h.disk)
    local cold=Boot(disk);local restored=cold:CreateSidecar();assert(restored.shell.minimized,'compact state lost')
    Eq(restored.window.x,x);Eq(restored.window.y,y);Eq(restored.window.w,w);Eq(restored.window.h,hh)
    assert(cold.S.Persistence:GetStore(STORE).lastIntegrityStatus=='verified_canonical')
end)
Test('all corners retain edge-v1 intent after small-screen fit and durable reload',function()
    local reloads={}
    for _,right in ipairs({false,true})do for _,bottom in ipairs({false,true})do
        local h=Boot();local s=h:CreateSidecar();Drag(s,right and 9999 or -9999,bottom and 9999 or -9999)
        h:Viewport(280,300);h.S.Layout:GetContext(true);assert(s:ApplyLayout(true));Corner(h,s,right,bottom)
        assert(s:SetMinimized(true));Corner(h,s,right,bottom);assert(s:SetMinimized(false));Corner(h,s,right,bottom)
        assert(h.controller.positionState.userMoved,'fitted edge position was erased')
        reloads[#reloads+1]={disk=Copy(h.disk),right=right,bottom=bottom}
    end end
    for _,r in ipairs(reloads)do
        local cold=Boot(r.disk);local s=cold:CreateSidecar(280,300);Corner(cold,s,r.right,r.bottom)
        cold:Viewport(1920,1080);cold.S.Layout:GetContext(true);assert(s:ApplyLayout(true));Corner(cold,s,r.right,r.bottom)
        assert(cold.S.Persistence:GetStore(STORE).writeFenced~=true)
    end
end)
Test('published schema1 free coordinates authenticate and migrate without moving',function()
    local h=Boot();local P=h.S.Persistence
    local state={userMoved=true,coordinateSpace='logical-free-v2',x=440,y=280,savedUiScale=1,
        savedLogicalWidth=1920,savedLogicalHeight=1080,normalizedCenterX=(440+150)/1920,normalizedCenterY=(280+220)/1080}
    assert(P:RegisterV3Store({id=STORE,owner=STORE,scope=P.Scope.Account,lifetime=P.Lifetime.Permanent,
        schemaVersion=1,key=P.V3KeyPrefix..'presentation_auction_sidecar_position',
        budget={maxDepth=3,maxNodes=32,maxStringBytes=256,maxEntriesPerTable=16},
        default=function()return {userMoved=false}end,get=function()return Copy(state)end,apply=function(v)state=Copy(v)end}))
    assert(P:LoadStore(STORE)=='empty');state={userMoved=true,coordinateSpace='logical-free-v2',x=440,y=280,savedUiScale=1,
        savedLogicalWidth=1920,savedLogicalHeight=1080,normalizedCenterX=(440+150)/1920,normalizedCenterY=(280+220)/1080}
    assert(P:SaveStore(STORE,{force=true,durable=true}))
    local cold=Boot(Copy(h.disk));local s=cold:CreateSidecar();Eq(s.window.x,440);Eq(s.window.y,280)
    local store=cold.S.Persistence:GetStore(STORE);assert(store.writeFenced~=true and store.schemaVersion==2)
    assert(cold.S.Persistence:SaveStore(STORE,{force=true,durable=true}))
    local again=Boot(Copy(cold.disk));local s2=again:CreateSidecar();Eq(s2.window.x,440);Eq(s2.window.y,280)
    assert(again.S.Persistence:GetStore(STORE).lastIntegrityStatus=='verified_canonical')
end)
Test('rejected minimize save restores actual and stored expanded rectangle',function()
    local h=Boot();local s=h:CreateSidecar();Drag(s,9999,9999)
    local x,y,w,hh=s.window.x,s.window.y,s.window.w,s.window.h;h.failSave=true
    assert(s:SetMinimized(true)==false,'failed durable write reported success')
    assert(not s.shell.minimized and not h.sidecarSpec.getState().minimized)
    Eq(s.window.x,x);Eq(s.window.y,y);Eq(s.window.w,w);Eq(s.window.h,hh)
end)
-- 小锁只在原 Position Store 中持有 true，解锁缺键必须保留旧 canonical，冷启不依赖 Scheduler/退出 Flush。
Test('lock and unlock survive immediate reload and unlocked canonical omits the new key',function()
    local h=Boot();local s=h:CreateSidecar();assert(s.shell.lockButton.spec.onClick());assert(h.controller.positionState.locked==true)
    local cold=Boot(Copy(h.disk));local restored=cold:CreateSidecar();assert(restored:IsLocked(),'title lock lost on cold creation')
    assert(cold.S.Persistence:GetStore(STORE).lastIntegrityStatus=='verified_canonical')
    assert(restored:SetLocked(false,true));assert(cold.controller.positionState.locked==nil,'unlock added false to old canonical')
    local again=Boot(Copy(cold.disk));assert(again:CreateSidecar():IsLocked()==false,'unlock lost on cold creation')
    assert(again.S.Persistence:GetStore(STORE).lastIntegrityStatus=='verified_canonical')
end)
-- 拒写必须沿 Floating/Shell 的原回滚链恢复位置档与 Native 小锁；显式预览继续不产生存档写入。
Test('lock save rejection restores Native and position state while preview remains memory only',function()
    local h=Boot();local s=h:CreateSidecar();Drag(s,440,280);h.failSave=true
    assert(s:SetLocked(true,true)==false,'failed lock persistence reported success')
    assert(s:IsLocked()==false and h.controller.positionState.locked==nil)
    assert(s.shell.lockButton.spec.onClick()==false,'failed title lock persistence reported success')
    assert(s:IsLocked()==false and h.controller.positionState.locked==nil)
    local before=h.diskWrites;assert(s:SetLocked(true,false));assert(s:IsLocked());assert(h.diskWrites==before)
end)
print(string.format('AUCTION PLACEMENT RESULT %d passed / %d failed (%s)',pass,fail,_VERSION))
assert(fail==0,'auction placement failures: '..fail)
