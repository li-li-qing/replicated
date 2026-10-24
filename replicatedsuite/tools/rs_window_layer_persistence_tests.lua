------------------------------------------------------------------------
-- Replicated Suite · 窗口层级持久化测试
-- 作者：Replicated
-- QQ群：1104129461
--
-- 维护（2026-09-16）：本测试只验证 Foundation 契约，不冒充 RU 实机层级验收。
------------------------------------------------------------------------
local pass, fail = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then pass = pass + 1; print("PASS window-layer " .. name)
    else fail = fail + 1; print("FAIL window-layer " .. name .. ": " .. tostring(err)) end
end

local function ShellHost(initialTopmost, disk)
    local h = dofile("tools/rs_gear_page_test_host.lua")({disk=disk})
    local S, UI, R = h.S, h.S.UI, h.S.RSUI
    S.Generation = 916
    S.PhysicalId = function(value) return tostring(value) end
    UIParent = h.Native(nil, "UIParent", 0, 0, 1280, 768)
    local poison = { x = 901, y = 902, w = 903, h = 904 }
    -- 2026-10-07：当前 WindowShell 初始化已有 StorePlacementRect/ResolvePlacement 合同。
    -- 原宿主少了这两个方法；使用真实 Layout，仅固定视口并保留“禁止几何回读”的毒值。
    dofile("data/rs_data_registry.lua");dofile("data/rs_static_data_v2.lua")
    dofile("data/ids/rs_item_ids.lua");dofile("data/ids/rs_quest_ids.lua");dofile("core/rs_constants.lua")
    dofile("core/rs_layout.lua")
    S.Layout.GetContext = function() return { logicalWidth=1280, logicalHeight=768, safeLeft=0, safeTop=0, safeRight=0, safeBottom=0, addonScale=1, uiScale=1, usableWidth=1280, usableHeight=768 } end
    S.Layout.GetLogicalRect = function() return poison.x, poison.y, poison.w, poison.h end
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
                CancelInteraction=function()return true end, -- 本套件只替换 Windowing；保留隐藏时的完整控制器契约。
                LayoutHandles=function()return true end, BringToFront=function()return true end, IsResizing=function()return false end,
                IsInteracting=function()return false end, SetLocked=function(_,v)return true,v,true end, SetOpacity=function(_,v)spec.window.alpha=v;return true,v,true end,
            }
        end,
        Detach = function() return true end,
    }
    dofile("ui/framework/rs_ui_window_shell_v3.lua")
    return S, UI, R, h
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

Test("floating show follows a visible pinned menu without changing its own preference", function()
    local S,UI=ShellHost(false)
    local mainVisible=true
    S.UIV3={Shell={window={IsVisible=function()return mainVisible end},GetTopmost=function()return true end}}
    local shell=assert(UI.WindowShell:Create({id="menu_detail",layerRole="floating",width=360,height=240,footer=false,resizable=false,appearanceControls=false}))
    shell.RevalidatePlacement=function()return true end
    assert(shell:Show(true));assert(shell.window.layer=="system","floating remains behind pinned menu")
    assert(shell:GetTopmost()==false and S.prefPersist==nil,"transient layer changed saved pin")
    mainVisible=false;assert(UI.WindowShell:RefreshFloatingLayers())
    assert(shell.window.layer=="normal","closed menu left floating permanently system")
    assert(shell:SetTopmost(true,true));mainVisible=true;assert(UI.WindowShell:RefreshFloatingLayers())
    mainVisible=false;assert(UI.WindowShell:RefreshFloatingLayers());assert(shell.window.layer=="system","user pin lost")
    assert(shell:Destroy());assert(UI.WindowShell.floatingById.menu_detail==nil,"destroy leaked layer observer")
end)

Test("menu unpin updates visible floating and rejected layer prevents showing", function()
    local S,UI=ShellHost(false);local mainTopmost=false
    S.UIV3={Shell={window={IsVisible=function()return true end},GetTopmost=function()return mainTopmost end}}
    local shell=assert(UI.WindowShell:Create({id="menu_layer_rejection",layerRole="floating",width=360,height=240,footer=false,resizable=false,appearanceControls=false}))
    shell.RevalidatePlacement=function()return true end
    assert(shell:Show(true) and shell.window.layer=="normal")
    mainTopmost=true;assert(UI.WindowShell:RefreshFloatingLayers());assert(shell.window.layer=="system")
    assert(shell:SetTopmost(true,false));assert(shell:SetTopmost(false,false));assert(shell.window.layer=="system","unpin went behind still-pinned menu")
    mainTopmost=false;assert(UI.WindowShell:RefreshFloatingLayers());assert(shell.window.layer=="normal")
    assert(shell:Show(false));mainTopmost=true
    shell.window.SetUILayer=function()return false end
    local shown,why=shell:Show(true);assert(shown==false and why and shell.visible==false,"rejected layer still shown")
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

-- 维护：置顶必须由真实 Persistence/Transport 证明耐久；手写 SaveStore=true 会漏掉 Native 静默丢写。
local function PreferenceHost(disk)
    local h=dofile('tools/rs_gear_page_test_host.lua')({disk=disk})
    dofile('ui/framework/rs_ui_window_preferences.lua')
    h.preferences=assert(h.S.RSUI.WindowPreferences)
    assert(h.preferences:EnsureLoaded())
    return h
end

Test("WindowPreferences commit is verified before cold reload and stays independent per window", function()
    local h=PreferenceHost();local W=h.preferences
    assert(not W:GetTopmost('main_shell') and not W:GetTopmost('life.fishing'))
    assert(W:SetTopmost('life.fishing',true,true))
    assert(h.S.Persistence:GetStore(W.storeId).needsBarrierVerify==false,'topmost returned before durable readback')
    local cold=PreferenceHost(h.Copy(h.disk))
    assert(cold.preferences:GetTopmost('life.fishing') and not cold.preferences:GetTopmost('main_shell'),'cold pin lost or leaked')
    assert(cold.preferences:SetTopmost('life.fishing',false,true))
    local again=PreferenceHost(cold.Copy(cold.disk));assert(not again.preferences:GetTopmost('life.fishing'),'cold unpin lost')
end)

Test("WindowPreferences rejects Native refusal and silent loss without pending retries changing intent", function()
    for _,mode in ipairs({'reject','stale'})do
        local h=PreferenceHost();local W=h.preferences
        assert(W:SetTopmost('main_shell',true,true))
        local before=h.Copy(h.disk);local dirty=h.S.Persistence:GetStore(W.storeId).dirty
        if mode=='reject' then h.failSave=true else ADDON.SaveData=function()return true end end
        local ok=W:SetTopmost('main_shell',false,true)
        assert(ok==false,'unpin accepted '..mode..' write')
        assert(W:GetTopmost('main_shell'),'rejected unpin left changed preference')
        assert(h.S.Persistence:GetStore(W.storeId).dirty==dirty,'rejected unpin left a retry that can commit later')
        local cold=PreferenceHost(before);assert(cold.preferences:GetTopmost('main_shell'),'failed unpin changed old disk intent')
    end
end)

Test("WindowPreferences explicit preview does not touch Native storage", function()
    local h=PreferenceHost();local reads,writes=h.reads,h.writes
    assert(h.preferences:SetTopmost('preview_window',true,false))
    assert(h.preferences:GetTopmost('preview_window') and h.reads==reads and h.writes==writes,'preview caused storage IO')
    local cold=PreferenceHost(h.Copy(h.disk));assert(not cold.preferences:GetTopmost('preview_window'),'preview became saved intent')
end)

Test("WindowShell Native pin rolls back when real preference storage rejects or loses the write", function()
    for _,mode in ipairs({'reject','stale'})do
        local S,UI,R,h=ShellHost(false);R.WindowPreferences=nil;dofile('ui/framework/rs_ui_window_preferences.lua')
        local shell=assert(UI.WindowShell:Create({id='real_pin',owner='test',width=360,height=240,appearanceControls=false,footer=false,resizable=false}))
        assert(shell:SetTopmost(true,true));assert(shell.window.layer=='system')
        if mode=='reject' then h.failSave=true else ADDON.SaveData=function()return true end end
        assert(shell:SetTopmost(false,true)==false,'shell accepted '..mode..' unpin')
        assert(shell.window.layer=='system' and shell:GetTopmost() and R.WindowPreferences:GetTopmost('real_pin'),'rejected unpin changed Native or Domain')
    end
end)

Test("actual title NumericField previews have zero IO and final values survive the real auxiliary store", function()
    local S,UI,R,h=ShellHost(false)
    UI.CreateSlider=function(_,p,id,x,y,w,ht,mn,mx,step,value)
        local n=h.Native(p,id,x,y,w,ht);n.value=value
        function n:SetValue(v)self.value=v end;function n:GetValue()return self.value end
        function n:SetRange(a,b,delta)self.min,self.max,self.step=a,b,delta end
        function n:SetValueChangedHandler(fn)self.valueChanged=fn end
        return n
    end
    dofile('ui/framework/rs_ui_forms.lua');dofile('ui/framework/rs_ui_floating_surface.lua');dofile('presentation/v3/rs_v3_aux_window_store.lua')
    local A=S.UIV3.AuxWindowStoreV3;assert(A:EnsureLoaded())
    local s=assert(R.FloatingSurface:Create({id='title_appearance_real',owner='test',statePolicy=A:GetPolicy('bag_settings'),
        getState=function()return A:GetWindowState('bag_settings')end,setState=function(v,reason)return A:SetWindowState('bag_settings',v,reason)end,
        persist=function(reason,delay)return A:PersistWindow('bag_settings',reason,delay)end,footer=false,resizable=false}))
    assert(s.shell:EnsureAppearancePanel())
    local fields={{s.shell.appearanceOverall,'overallOpacity',50},{s.shell.appearanceBackground,'backgroundOpacity',0},
        {s.shell.appearanceText,'textOpacity',50},{s.shell.appearanceFont,'fontScale',110}}
    for _,row in ipairs(fields)do
        local writes,reads=h.writes,h.reads;assert(row[1].slider:Preview(row[3],'test'));assert(h.writes==writes and h.reads==reads,'title preview caused IO')
        assert(row[1].slider:CommitValue(row[3],'slider'),'title final rejected')
        assert(h.writes>writes and h.reads>reads,'title final only queued persistence')
        local expected=row[3]/100;assert(A:GetWindowState('bag_settings')[row[2]]==expected,'title final value lost')
    end
    for _,mode in ipairs({'reject','stale'})do for _,row in ipairs(fields)do
        h.failSave=mode=='reject';if mode=='stale' then ADDON.SaveData=function()return true end end
        local preview=row[2]=='fontScale' and 120 or 60
        assert(row[1].slider:Preview(preview,'test'));assert(row[1].slider:CommitValue(preview,'slider')==false,'title accepted '..mode)
        assert(A:GetWindowState('bag_settings')[row[2]]==row[3]/100,'rejected title changed Domain')
        local nativeField=row[2]=='overallOpacity' and 'opacity' or row[2];assert(s.shell[nativeField]==row[3]/100,'rejected title left applied Native intent')
    end end
    local disk=h.Copy(h.disk);local coldS=ShellHost(false,disk);dofile('ui/framework/rs_ui_floating_surface.lua');dofile('presentation/v3/rs_v3_aux_window_store.lua')
    local restored=coldS.UIV3.AuxWindowStoreV3:GetWindowState('bag_settings')
    assert(restored.overallOpacity==.5 and restored.backgroundOpacity==0 and restored.textOpacity==.5 and restored.fontScale==1.1,'title cold reload mismatch')
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

-- 维护：页面骨架仅用于捕获实际 NumericSetting spec；数值控件/Binding、WidgetHost、Feature、Persistence 全走生产实现。
local function AppearancePageHost(disk)
    local S,UI,R,h=ShellHost(false,disk)
    dofile('ui/framework/rs_ui_floating_surface.lua')
    local function Shallow(value)local out={};for key,item in pairs(value)do out[key]=item end;return out end
    local originalR,originalUI,originalD=Shallow(R),Shallow(UI),Shallow(S.UIV3Design)
    local ui=dofile('tools/rs_status_ui_test_host.lua')(S)
    local makeNode=ui.Node;ui.Node=function(spec)local node=makeNode(spec);function node:SetTone(value)self.tone=value end;return node end
    S.UIV3.Router={Get=function()return nil end}
    S.UIV3.WidgetHost.Describe=function()return {}end;S.UIV3.WidgetHost.GetState=function()return nil end
    S.UIV3Design.NumericSetting=function(_,parent,spec)return ui.Node(spec)end
    dofile('presentation/v3/pages/rs_v3_foundation_pages.lua');assert(S.UIV3.PageHost.factories['system.widgets'](nil,'system.widgets'))
    local specs={};for id,node in pairs(ui.widgets)do specs[id]=node.spec end
    local function Restore(target,value)for key in pairs(target)do target[key]=nil end;for key,item in pairs(value)do target[key]=item end end
    Restore(R,originalR);Restore(UI,originalUI);Restore(S.UIV3Design,originalD)
    UI.CreateSlider=function(_,p,id,x,y,w,ht,mn,mx,step,value)
        local n=h.Native(p,id,x,y,w,ht);n.value=value
        function n:SetValue(v)self.value=v end;function n:GetValue()return self.value end
        function n:SetRange(a,b,delta)self.min,self.max,self.step=a,b,delta end
        function n:SetValueChangedHandler(fn)self.valueChanged=fn end
        return n
    end
    dofile('ui/framework/rs_ui_forms.lua')
    dofile('core/rs_demand.lua');dofile('features/life/activities/rs_activity_store.lua');dofile('features/life/activities/rs_activity_authority.lua');dofile('features/life/activities/rs_activity_feature.lua')
    dofile('presentation/v3/widgets/rs_v3_widget_host.lua');dofile('presentation/v3/widgets/rs_v3_activity_widget.lua');dofile('presentation/v3/widgets/rs_v3_gear_widget.lua')
    h.host=S.UIV3.WidgetHost;assert(h.host:GetState('life.activities'));assert(h.host:GetState('combat.gear.quick'))
    function h:Field(id)local spec=assert(specs[id],id);spec.parent=self.page;return assert(R:NumericField(spec))end
    return h
end
for _,widget in ipairs({{'activity','life.activities'},{'gear','combat.gear.quick'}})do
    for _,channel in ipairs({{'overall','overallOpacity'},{'background','backgroundOpacity'},{'text','textOpacity'}})do
        for _,mode in ipairs({'cold','reject','stale'})do
            Test('Foundation '..widget[1]..' '..channel[1]..' final '..mode,function()
                local h=AppearancePageHost();local id='v3_widgets_'..widget[1]..'_'..channel[1]..'_opacity';local field=h:Field(id)
                local before=h.host:GetState(widget[2])[channel[2]];local writes,reads=h.writes,h.reads
                assert(field.slider:Preview(50,'test'));assert(h.writes==writes and h.reads==reads,'numeric preview caused storage IO')
                assert(h.host:GetState(widget[2])[channel[2]]==before,'numeric preview changed saved intent')
                local save=ADDON.SaveData
                if mode=='reject' then h.failSave=true elseif mode=='stale' then ADDON.SaveData=function()return true end end
                local ok=field.slider:CommitValue(50,'slider')
                if mode~='cold' then
                    assert(ok==false,'page final accepted '..mode);assert(h.host:GetState(widget[2])[channel[2]]==before,'failed page final changed Domain')
                    h.failSave=false;ADDON.SaveData=save;assert(field.slider:CommitValue(50,'slider'),'rejected page final was not retryable')
                else assert(ok==true);assert(h.writes==writes+1,'page final did not make one durable write') end
                local cold=AppearancePageHost(h.Copy(h.disk));assert(cold.host:GetState(widget[2])[channel[2]]==.5,'page final lost before heartbeat')
                if mode=='cold' then
                    assert(cold:Field(id):Apply(60,'input'),'precise input failed')
                    local again=AppearancePageHost(cold.Copy(cold.disk));assert(again.host:GetState(widget[2])[channel[2]]==.6,'precise input lost before heartbeat')
                end
            end)
        end
    end
end
Test('Gear Host explicit preview remains memory only before its durable final',function()
    for _,channel in ipairs({'overall','background','text'})do
        local h=AppearancePageHost();local writes,reads=h.writes,h.reads
        assert(h.host:SetAppearance('combat.gear.quick',channel,.5,false));assert(h.writes==writes and h.reads==reads,'explicit gear preview caused IO')
        assert(h.host:SetAppearance('combat.gear.quick',channel,.5,true));assert(h.writes==writes+1,'same value gear final remained queued')
        local cold=AppearancePageHost(h.Copy(h.disk));local key=channel=='overall' and 'overallOpacity' or channel..'Opacity'
        assert(cold.host:GetState('combat.gear.quick')[key]==.5,'same value gear final lost')
    end
end)

print(string.format("WINDOW LAYER RESULT: %d passed, %d failed", pass, fail))
if fail > 0 then error("window layer suite failures: " .. fail) end
