-- Replicated Suite window geometry/layer regression.
-- 维护（2026-09-16）：本测试只验证 Foundation 契约，不冒充 RU 实机层级验收。
local pass, fail = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then pass = pass + 1; print("PASS window-layer " .. name)
    else fail = fail + 1; print("FAIL window-layer " .. name .. ": " .. tostring(err)) end
end

local function ShellHost(initialTopmost)
    local h = dofile("tools/rs_gear_page_test_host.lua")()
    local S, UI, R = h.S, h.S.UI, h.S.RSUI
    S.Generation = 916
    S.PhysicalId = function(value) return tostring(value) end
    UIParent = h.Native(nil, "UIParent", 0, 0, 1280, 768)
    local poison = { x = 901, y = 902, w = 903, h = 904 }
    S.Layout = {
        GetContext = function() return { logicalWidth=1280, logicalHeight=768, safeLeft=0, safeTop=0, safeRight=0, safeBottom=0, addonScale=1, uiScale=1, usableWidth=1280, usableHeight=768 } end,
        GetLogicalRect = function() return poison.x, poison.y, poison.w, poison.h end,
        ClampRecoverableTopLeft = function(_, x, y) return x, y end,
    }
    S.NativeObjectFactory = { CreateWindow = function(_, id)
        local n = h.Native(UIParent, id, 0, 0, 1, 1)
        function n:SetUILayer(v) self.layer=v; return true end
        function n:SetCloseOnEscape() return true end
        function n:SetWindowModal() return true end
        function n:SetDrawPriority(v) self.priority=v; return true end
        return n
    end }
    UI.ClaimNativeAuthority = function() return true end
    UI.SetAlpha = function(_,n,v)n.alpha=v;return true end
    UI.EnsureAlpha = function(_,n,v)n.alpha=v;return true,false end
    UI.InvalidateNativeState = function() return true end
    R.ApplyOpacityChannels = function() return true end
    R.ApplyFontScale = function() return true end
    local pref = initialTopmost == true
    R.WindowPreferences = {
        GetTopmost = function(_, id) return pref end,
        SetTopmost = function(_, id, value, persist) pref = value == true; S.prefPersist = persist; S.prefId = id; return true, pref end,
    }
    R.Windowing = {
        Attach = function(_, spec)
            S.testWindowingSpec = spec
            return {
                id=spec.id, dragHandle=spec.dragHandle.root or spec.dragHandle,
                LayoutHandles=function()return true end, BringToFront=function()return true end, IsResizing=function()return false end,
                IsInteracting=function()return false end, SetLocked=function(_,v)return true,v,true end, SetOpacity=function(_,v)return true,v,true end,
            }
        end,
        Detach = function() return true end,
    }
    dofile("ui/framework/rs_ui_window_shell_v3.lua")
    return S, UI, R
end

Test("WindowShell defaults to normal layer and exposes persistent topmost control", function()
    local S, UI = ShellHost(false)
    local shell = assert(UI.WindowShell:Create({ id="layer_contract", owner="test:layer", title="层级", width=360, height=240, footer=false, appearanceControls=false, resizable=false }))
    assert(shell.window.layer == "normal", "default layer must be normal, got " .. tostring(shell.window.layer))
    assert(shell.topmostButton ~= nil, "topmost title button missing")
    assert(shell.topmost == false, "default topmost must be false")
    assert(shell.topmostButton.onClick() ~= false, "topmost click rejected")
    assert(shell.window.layer == "system", "topmost did not move to system layer")
    assert(shell.topmost == true and S.prefPersist == true and S.prefId == "layer_contract", "topmost preference was not persisted per window")
    assert(shell.topmostButton.onClick() ~= false, "unpin click rejected")
    assert(shell.window.layer == "normal" and shell.topmost == false, "unpin did not restore normal layer")
end)

Test("WindowShell geometry callback forwards committed rect instead of rereading native geometry", function()
    local S, UI = ShellHost(false)
    local snapshot
    local shell = assert(UI.WindowShell:Create({ id="geometry_contract", owner="test:geometry", title="位置", width=360, height=240, footer=false, appearanceControls=false, resizable=false,
        onStateChanged=function(_, state) snapshot=state; return true end }))
    local spec = assert(S.testWindowingSpec)
    assert(spec.onGeometryChanged(nil, 111, 222, 333, 244, "drag") ~= false)
    assert(snapshot and snapshot.x == 111 and snapshot.y == 222, "committed x/y were replaced by native reread: " .. tostring(snapshot and snapshot.x) .. "," .. tostring(snapshot and snapshot.y))
    assert(snapshot.width == 333 and snapshot.height == 244, "committed extent was replaced by native reread")
end)

Test("FloatingSurface persists the committed geometry rect and requests immediate dirty edge", function()
    ReplicatedSuite = { BootError=nil, Generation=917, SafeTraceback=function(e)return tostring(e)end, UI={}, RSUI={}, }
    local S, UI, R = ReplicatedSuite, ReplicatedSuite.UI, ReplicatedSuite.RSUI
    local state = { width=320, height=220, userMoved=false }
    S.Layout = {
        GetContext=function() return {logicalWidth=1280,logicalHeight=768,addonScale=1,uiScale=1,safeLeft=0,safeTop=0,safeRight=0,safeBottom=0,usableWidth=1280,usableHeight=768} end,
        ResolvePlacement=function(_,_,_,_,dx,dy)return dx,dy end,
        GetLogicalRect=function() return 900,901,902,903 end,
        StorePlacement=function(_, target) target.x=900;target.y=901;target.coordinateSpace="logical-free-v2";return 900,901,902,903 end,
        StorePlacementRect=function(_, target, x, y, w, h) target.x=x;target.y=y;target.coordinateSpace="logical-free-v2";target.savedUiScale=1;target.savedLogicalWidth=1280;target.savedLogicalHeight=768;target.normalizedCenterX=(x+w*0.5)/1280;target.normalizedCenterY=(y+h*0.5)/768;return x,y,w,h end,
    }
    local shellSpec
    UI.CreateWindowShell=function(_, spec)
        shellSpec=spec
        local shell={window={},normalWidth=spec.width,normalHeight=spec.height,minimized=false,locked=false}
        function shell:GetContentComponent()return {}end;function shell:GetContentRoot()return {}end;function shell:GetWindow()return self.window end
        function shell:SetLocked(v)return true,v,true end;function shell:SetOverallOpacity(v)return true,v,true end;function shell:SetBackgroundOpacity(v)return true,v,true end;function shell:SetTextOpacity(v)return true,v,true end;function shell:SetFontScale(v)return true,v,true end
        function shell:SetMinimized(v)self.minimized=v;return true,v,true end;function shell:Show()return true end;function shell:Close()return true end;function shell:Destroy()return true end
        function shell:IsLocked()return false end;function shell:Layout()return true end
        shell.windowController={IsInteracting=function()return false end}
        return shell
    end
    dofile("ui/framework/rs_ui_floating_surface.lua")
    local delays={}
    local surface=assert(R.FloatingSurface:Create({id="fishing_test",owner="test:fishing",title="钓鱼",state=state,statePolicy={defaultWidth=320,defaultHeight=220,minWidth=100,minHeight=80},
        persist=function(reason,delay) delays[#delays+1]={reason=reason,delay=delay};return true end,footer=false,resizable=false,appearanceControls=false}))
    assert(shellSpec and type(shellSpec.onStateChanged)=="function")
    assert(shellSpec.onStateChanged(surface.shell,{reason="geometry",geometryKind="drag",x=123,y=234,width=320,height=220,normalWidth=320,normalHeight=220,minimized=false,locked=false,overallOpacity=0.94,backgroundOpacity=1,textOpacity=1,fontScale=1}) ~= false)
    assert(state.x == 123 and state.y == 234, "FloatingSurface ignored committed rect and reread native geometry")
    assert(delays[#delays] and delays[#delays].delay == 0, "geometry edge must request immediate persistence")
end)

Test("WindowPreferences default false and persist independently per window", function()
    local defs, values, saves, dirty = {}, {}, 0, 0
    ReplicatedSuite={BootError=nil,RSUI={},Utils={DeepCopy=function(v) if type(v)~='table'then return v end local t={} for k,x in pairs(v)do t[k]=x end return t end},DiagnosticsManager=nil}
    local S=ReplicatedSuite
    S.Persistence={Scope={Account="Account"},Lifetime={Permanent="Permanent"},V3KeyPrefix="rs:v3:"}
    local P=S.Persistence
    function P:GetStore(id)return defs[id]end
    function P:RegisterV3Store(def) defs[def.id]=def; values[def.id]=def.default(); def.loaded=false; return def end
    function P:LoadStore(id) defs[id].loaded=true; defs[id].apply(values[id]); return true end
    function P:IsStoreLoaded(id)return defs[id] and defs[id].loaded==true end
    function P:MarkDirty() dirty=dirty+1; return true end
    function P:SaveStore(id) saves=saves+1; values[id]=defs[id].get(); return true end
    dofile("ui/framework/rs_ui_window_preferences.lua")
    local W=assert(S.RSUI.WindowPreferences)
    assert(W:GetTopmost("main_shell") == false and W:GetTopmost("life.fishing") == false)
    assert(W:SetTopmost("life.fishing",true,true))
    assert(W:GetTopmost("life.fishing") == true and W:GetTopmost("main_shell") == false, "topmost leaked between windows")
    assert(dirty==1 and saves==1, "topmost click was not synchronously persisted")
end)

Test("main shell geometry consumes Windowing committed rect and topmost toggles through adapter", function()
    ReplicatedSuite={BootError=nil,UI={},RSUI={Windowing={}},UIV3={Router={},PageHost={},ModalHost={},ToastHost={},ShellState={width=1040,height=700,userMoved=false}},UIV3NativeAdapter={}}
    local S=ReplicatedSuite
    local V3=S.UIV3
    local explicitRect
    S.Layout={GetContext=function()return{addonScale=1,uiScale=1,logicalWidth=1280,logicalHeight=768,usableWidth=1280,usableHeight=768}end,
        StorePlacement=function() error("main shell must not reread native geometry") end,
        StorePlacementRect=function(_,target,x,y,w,h)explicitRect={x=x,y=y,w=w,h=h};target.x=x;target.y=y;target.coordinateSpace="logical-free-v2";target.userMoved=true;return x,y,w,h end}
    V3.MarkShellStoreDirty=function(_,delay,reason)S.shellDirtyDelay=delay;S.shellDirtyReason=reason;return true end
    S.RSUI.WindowPreferences={GetTopmost=function()return false end,SetTopmost=function(_,_,value,persist)S.mainPref=value;S.mainPrefPersist=persist;return true,value end}
    function S.UIV3NativeAdapter:SetRootLayer(window, topmost) window.layer=topmost and "system" or "normal"; return true end
    dofile("presentation/v3/rs_v3_shell.lua")
    local Shell=assert(S.UIV3.Shell)
    Shell.window={layer="normal"}
    Shell.created=true
    Shell.ApplyLayout=function()return true end
    assert(Shell:CommitWindowGeometry(nil,41,52,630,470,"drag"))
    assert(explicitRect and explicitRect.x==41 and explicitRect.y==52, "main shell discarded committed rect")
    assert(S.shellDirtyDelay==0, "main shell geometry must request immediate persistence")
    assert(type(Shell.SetTopmost)=="function", "main shell topmost API missing")
    assert(Shell:SetTopmost(true,true))
    assert(Shell.window.layer=="system" and S.mainPref==true and S.mainPrefPersist==true)
    assert(Shell:SetTopmost(false,true))
    assert(Shell.window.layer=="normal" and S.mainPref==false)
end)

Test("real Layout stores committed logical rect without UI-scale reread", function()
    ReplicatedSuite={BootError=nil,Constants={},UI={}}
    dofile("core/rs_layout.lua")
    local L=assert(ReplicatedSuite.Layout)
    L.context={logicalWidth=1280,logicalHeight=768,usableWidth=1280,usableHeight=768,safeLeft=0,safeTop=0,safeRight=0,safeBottom=0,uiScale=0.80,addonScale=1}
    L.invalidated=false
    local placement={}
    local x,y,w,h=L:StorePlacementRect(placement,123,234,320,220,{mode="free"})
    assert(x==123 and y==234 and w==320 and h==220, "StorePlacementRect changed committed logical rect")
    assert(placement.x==123 and placement.y==234 and placement.savedUiScale==0.80, "committed placement did not preserve logical/ui-scale metadata")
    assert(math.abs((placement.normalizedCenterX or 0)-((123+160)/1280))<0.000001, "normalized center X mismatch")
    local rx,ry=L:ResolvePlacement(placement,320,220,0,0,{mode="free"})
    assert(rx==123 and ry==234, "same viewport relog must restore exact committed x/y")
end)

print(string.format("WINDOW LAYER RESULT: %d passed, %d failed", pass, fail))
if fail > 0 then error("window layer suite failures: " .. fail) end
