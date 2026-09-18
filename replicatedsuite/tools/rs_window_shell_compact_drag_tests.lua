-- WindowShell compact-minimize regression: the visible + square must not eat the shared drag surface.
local pass, fail = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then pass = pass + 1; print("PASS compact-window " .. name)
    else fail = fail + 1; print("FAIL compact-window " .. name .. ": " .. tostring(err)) end
end

local function Boot()
    local h = dofile("tools/rs_gear_page_test_host.lua")()
    local S, UI, R = h.S, h.S.UI, h.S.RSUI
    S.Generation = 901
    S.PhysicalId = function(value) return tostring(value) end
    UIParent = h.Native(nil, "UIParent", 0, 0, 1280, 768)
    S.Layout = {
        GetContext = function() return { logicalWidth=1280, logicalHeight=768, safeLeft=0, safeTop=0, safeRight=0, safeBottom=0, addonScale=1 } end,
        GetLogicalRect = function(_, w) return w.x or 0, w.y or 0, w.width or 1, w.height or 1 end,
        ClampRecoverableTopLeft = function(_, x, y) return x, y end,
    }
    S.NativeObjectFactory = { CreateWindow = function(_, id)
        local n = h.Native(UIParent, id, 0, 0, 1, 1)
        function n:SetUILayer() return true end
        function n:SetCloseOnEscape() return true end
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
    -- Windowing itself is already separately tested. Here we preserve the real dragHandle
    -- identity and verify compact chrome hit testing exposes that handle to it.
    R.Windowing = {
        Attach = function(_, spec)
            S.testWindowingSpec = spec
            return {
                id=spec.id, dragHandle=spec.dragHandle.root or spec.dragHandle,
                LayoutHandles=function()return true end, BringToFront=function()return true end, IsResizing=function()return false end,
                SetLocked=function(_,v)return true,v,true end, SetOpacity=function(_,v)return true,v,true end,
            }
        end,
        Detach = function() return true end,
    }
    dofile("ui/framework/rs_ui_window_shell_v3.lua")
    local shell, err = assert(UI.WindowShell:Create({
        id="compact_drag_contract", owner="test:compact", title="测试", width=360, height=260,
        minWidth=200, minHeight=120, compactChrome=true, minimizeMode="compact", minimizedSize=30,
        resizable=false, appearanceControls=false, footer=false,
    }))
    assert(shell, err)
    assert(shell:Show(true))
    return S, shell
end

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

print(string.format("COMPACT WINDOW RESULT: %d passed, %d failed", pass, fail))
if fail > 0 then error("compact window suite failures: " .. fail) end
