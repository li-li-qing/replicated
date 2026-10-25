-- Replicated Suite · 窗口外壳紧凑拖拽测试
-- 作者：Replicated
-- QQ群：1104129461
-- WindowShell 紧凑最小化回归：可见的 + 方块不能占用共享拖拽区域。
local pass, fail = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then pass = pass + 1; print("PASS compact-window " .. name)
    else fail = fail + 1; print("FAIL compact-window " .. name .. ": " .. tostring(err)) end
end

local function Boot(options)
    options=options or {}
    local h = dofile("tools/rs_gear_page_test_host.lua")()
    local S, UI, R = h.S, h.S.UI, h.S.RSUI
    S.Generation = 901
    S.PhysicalId = function(value) return tostring(value) end
    UIParent = h.Native(nil, "UIParent", 0, 0, 1280, 768)
    -- WindowShell 现已调用真实 placement Authority；旧三方法桩缺
    -- StorePlacementRect/ResolvePlacement。只替换本测试的 Native 视口和几何读取，不反造定位算法。
    dofile("data/rs_data_registry.lua")
    dofile("data/ids/rs_item_ids.lua");dofile("data/ids/rs_quest_ids.lua");dofile("core/rs_constants.lua")
    dofile("core/rs_layout.lua")
    S.Layout.GetContext = function() return { logicalWidth=1280, logicalHeight=768, usableWidth=1280, usableHeight=768,
        safeLeft=0, safeTop=0, safeRight=0, safeBottom=0, addonScale=1, uiScale=1, effectiveScale=1 } end
    S.Layout.GetLogicalRect = function(_, w) return w.x or 0, w.y or 0, w.width or 1, w.height or 1 end
    S.NativeObjectFactory = { CreateWindow = function(_, id)
        local n = h.Native(UIParent, id, 0, 0, 1, 1)
        function n:GetEffectiveOffset()return self.x,self.y end
        function n:GetEffectiveExtent()return self.width,self.height end
        function n:SetUILayer() return true end
        function n:SetCloseOnEscape(value) self.nativeCloseOnEscape=value;return true end
        -- 模拟原生直接隐藏及 OnHide，仍使用真实 Shell 的显隐与关闭通知链。
        local originalShow=n.Show
        function n:Show(value)
            local wasVisible=self.shown==true;local result=originalShow(self,value)
            if wasVisible and value==false and self.events.OnHide then self.events.OnHide(self)end
            return result
        end
        function n:SetWindowModal() return true end
        function n:SetDrawPriority() return true end
        return n
    end }
    UI.ClaimNativeAuthority = function() return true end
    UI.SetAlpha = function(_,n,v)n.alpha=v;return true end
    UI.EnsureAlpha = function(_,n,v)n.alpha=v;return true,false end
    UI.InvalidateNativeState = function() return true end
    R.ApplyOpacityChannels = function() return true end
    R.ApplyFontScale = function() return true end
    -- Windowing 已有独立测试；这里保留真实 dragHandle 身份，验证紧凑窗口外壳命中检测能把该拖拽句柄交给 Windowing。
    dofile("ui/framework/rs_ui_windowing.lua")
    local applyGeometry = R.Windowing.ApplyGeometry
    R.Windowing = {
        ApplyGeometry = applyGeometry,
        Attach = function(_, spec)
            S.testWindowingSpec = spec
            return {
                id=spec.id, dragHandle=spec.dragHandle.root or spec.dragHandle,
                CancelInteraction=function()return true end, -- 外壳隐藏会取消手势；真实捕获释放由视口套件验证。
                LayoutHandles=function()return true end, BringToFront=function()return true end, IsResizing=function()return false end, IsInteracting=function()return false end,
                SetLocked=function(_,v)return true,v,true end, SetOpacity=function(_,v)return true,v,true end,
            }
        end,
        Detach = function() return true end,
    }
    dofile("ui/framework/rs_ui_window_shell_v3.lua")
    local shell, err = assert(UI.WindowShell:Create({
        id="compact_drag_contract", owner="test:compact", title="测试", width=360, height=260,
        minWidth=200, minHeight=120, compactChrome=true, minimizeMode=options.minimizeMode or "compact", minimizedSize=30,
        resizable=false, appearanceControls=false, footer=false,
        closeOnEscape=options.closeOnEscape,onClosed=options.onClosed,
    }))
    assert(shell, err)
    assert(shell:Show(true))
    return S, shell
end

Test("native Escape opt-in synchronizes visibility and notifies close exactly once",function()
    local closes=0
    local S,shell=Boot({closeOnEscape=true,onClosed=function(_,reason)closes=closes+1;assert(reason=='native_hide');return true end})
    assert(shell.window.nativeCloseOnEscape==true,'native Escape close was disabled')
    shell.window:Show(false)
    assert(shell.visible==false and closes==1,'native hide left a visible Shell or skipped cleanup')
    shell.window.events.OnHide(shell.window);assert(closes==1,'duplicate hide repeated cleanup')
    assert(shell:Show(true));assert(shell.window.nativeCloseOnEscape==true,'reopen lost Escape close')
end)
Test("explicit hide and close do not duplicate the native Escape callback",function()
    local closes=0
    local S,shell=Boot({closeOnEscape=true,onClosed=function()closes=closes+1;return true end})
    assert(shell:Show(false));assert(closes==0,'programmatic hide was treated as a user close')
    assert(shell:Show(true));assert(shell:Close('button'));assert(closes==1,'X close notified twice')
end)
Test("ordinary floating windows retain their existing Escape policy",function()
    local S,shell=Boot();assert(shell.window.nativeCloseOnEscape==false,'opt-in changed all floating windows')
end)
Test("native Escape opt-in does not turn minimize hiding into a close",function()
    local closes=0
    local S,shell=Boot({closeOnEscape=true,minimizeMode='hide',onClosed=function()closes=closes+1;return true end})
    assert(shell:SetMinimized(true,false));assert(shell.minimized and not shell.visible and closes==0)
    assert(shell:SetMinimized(false,false));assert(not shell.minimized and shell.visible and closes==0)
end)

Test("normal state keeps minimize button clickable", function()
    local S, shell = Boot()
    assert(shell.minimizeButton.root.pickable == true, "normal minimize button must remain clickable")
    assert(S.testWindowingSpec and (S.testWindowingSpec.dragHandle.root or S.testWindowingSpec.dragHandle) == shell.titleBar.root, "Windowing must keep title bar as shared drag handle")
end)

Test("compact state passes hit testing to title bar and title click restores", function()
    local S, shell = Boot()
    assert(shell:SetMinimized(true, false))
    assert(shell.minimized == true)
    assert(shell.minimizeButton.text == "+")
    assert(shell.minimizeButton.root.pickable == false, "compact + button still intercepts drag surface")
    assert(S.testWindowingSpec and (S.testWindowingSpec.dragHandle.root or S.testWindowingSpec.dragHandle) == shell.titleBar.root)
    local click = shell.titleBar.root.events.OnClick
    assert(type(click) == "function", "compact title bar restore click missing")
    assert(click(shell.titleBar.root, "LeftButton") ~= false)
    assert(shell.minimized == false, "title-bar click did not restore compact window")
    assert(shell.minimizeButton.root.pickable == true, "restored minimize button did not regain click hit testing")
end)

-- 折叠时标识仍可见，但不能继续运行原尺寸业务界面。
Test("compact title remains visible and normal geometry is retained",function()
 local S,shell=Boot();shell:SetTitle("跑商货率")
 local w,h=shell.normalWidth,shell.normalHeight
 assert(shell:SetMinimized(true,false));assert(shell.titleText.visible~=false and shell.titleText.text=="跑商货率")
 assert(shell.window.width>=136 and shell.window.width<240,"compact entry is an unnamed square or full window")
 assert(shell.normalWidth==w and shell.normalHeight==h)
 assert(shell:SetMinimized(false,false));assert(shell.window.width==w and shell.window.height==h)
end)
Test("failed compact persistence rolls back geometry and does not emit committed event",function()
 local S,shell=Boot();local events=0
 S.Events:SubscribeInternal("v3.widgets.changed",{},function()events=events+1 end)
 shell.spec.onStateChanged=function()return false,"write_rejected"end
 local w,h=shell.normalWidth,shell.normalHeight
 assert(shell:SetMinimized(true,true)==false);assert(not shell.minimized and shell.visible)
 assert(shell.window.width==w and shell.window.height==h and events==0)
end)
print(string.format("COMPACT WINDOW RESULT: %d passed, %d failed", pass, fail))
if fail > 0 then error("compact window suite failures: " .. fail) end
