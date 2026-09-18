------------------------------------------------------------------------
-- Replicated Suite - ColorField V2 popup positioning behavioral tests
-- Offline only: validates viewport-logical solver + final UIParent anchor lane.
------------------------------------------------------------------------
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; print("PASS colorfield-popup " .. name)
    else failed = failed + 1; print("FAIL colorfield-popup " .. name .. ": " .. tostring(err)) end
end

UIParent = { id = "UIParent" }
local context = { logicalWidth = 1024, logicalHeight = 768, safeLeft = 4, safeTop = 4, safeRight = 4, safeBottom = 4, uiScale = 1 }
local writes = {}
local UI = {
    NativeStateCache = setmetatable({}, { __mode = "k" }),
    EnsureExtent = function(_, widget, w, h, owner) writes.extent = { widget=widget,w=w,h=h,owner=owner }; return true, true, nil end,
    EnsureAnchor = function(_, widget, parent, x, y, owner) writes.anchor = { widget=widget,parent=parent,x=x,y=y,owner=owner }; return true, true, nil end,
    InvalidateNativeState = function(_, widget, key) writes.invalidated = { widget=widget,key=key }; return true end,
}
local RSUI = {
    IsComponent = function(_, value) return type(value) == "table" and value.__component == true end,
}
local Layout = {
    GetContext = function() return context end,
}
ReplicatedSuite = { BootError = nil, UI = UI, RSUI = RSUI, Layout = Layout }
dofile("ui/framework/rs_ui_popup_positioning.lua")
local P = assert(ReplicatedSuite.RSUI.PopupPositioning)

local function Popup()
    return {
        rsNativeLogicalId = "color_popup",
        GetOffset = function() return 0,0 end,
        GetExtent = function() return 300,270 end,
        GetEffectiveOffset = function() return 0,0 end,
        GetEffectiveExtent = function() return 300,270 end,
    }
end

Test("center trigger resolves below without clamp", function()
    context.logicalWidth, context.logicalHeight = 1024, 768
    local anchor = { x=200,y=120,width=140,height=26,right=340,bottom=146,coordinateSpace="viewport-logical-v1",source="suite_native_state_anchor_chain" }
    local result, err, meta = P:ResolveAnchored(anchor, 300, 270, { id="cf_center", gap=4, preferred="bottom-start" })
    assert(result and not err)
    assert(result.x == 200 and result.y == 150, tostring(result.x)..","..tostring(result.y))
    assert(meta.placement == "bottom")
end)

Test("bottom trigger flips above", function()
    context.logicalWidth, context.logicalHeight = 1280, 768
    local anchor = { x=400,y=700,width=140,height=26,right=540,bottom=726,coordinateSpace="viewport-logical-v1",source="suite_native_state_anchor_chain" }
    local result, err, meta = P:ResolveAnchored(anchor, 300, 270, { id="cf_bottom", gap=4, preferred="bottom-start" })
    assert(result and not err)
    assert(meta.placement == "top" and result.y == 426, tostring(result.y))
end)

Test("right trigger clamps within viewport", function()
    context.logicalWidth, context.logicalHeight = 1920, 1080
    local anchor = { x=1820,y=100,width=90,height=26,right=1910,bottom=126,coordinateSpace="viewport-logical-v1",source="suite_native_state_anchor_chain" }
    local result = assert(P:ResolveAnchored(anchor, 300, 270, { id="cf_right", gap=4, preferred="bottom-start" }))
    assert(result.x == 1616, tostring(result.x)) -- 1920 - safeRight(4) - 300
end)

Test("2560x1440 bottom-right trigger stays fully on screen", function()
    context.logicalWidth, context.logicalHeight = 2560, 1440
    local anchor = { x=2480,y=1370,width=70,height=26,right=2550,bottom=1396,coordinateSpace="viewport-logical-v1",source="suite_native_state_anchor_chain" }
    local result, err, meta = P:ResolveAnchored(anchor, 300, 270, { id="cf_2560", gap=4, preferred="bottom-start" })
    assert(result and not err)
    assert(result.x == 2256, tostring(result.x))
    assert(meta.placement == "top" and result.y == 1096, tostring(result.y))
end)

Test("final commit anchors top-level popup only to UIParent", function()
    writes = {}
    local popup = Popup()
    local anchor = { x=320,y=200,width=132,height=26,right=452,bottom=226,coordinateSpace="viewport-logical-v1",source="suite_native_state_anchor_chain" }
    local resolved = { x=320,y=230,width=300,height=270,right=620,bottom=500,coordinateSpace="viewport-logical-v1" }
    local ok, err = P:ApplyResolvedViewportPopup(popup, anchor, resolved, "test_owner", { id="cf_commit" })
    assert(ok == true and err == nil, tostring(err))
    assert(writes.anchor and writes.anchor.parent == UIParent, "not anchored to UIParent")
    assert(writes.anchor.x == 320 and writes.anchor.y == 230)
    assert(writes.extent.w == 300 and writes.extent.h == 270)
    local snap = P:GetSnapshot()
    local row = snap.recent[#snap.recent]
    assert(row.mode == "viewport_resolved")
    assert(row.anchorSource == "suite_native_state_anchor_chain")
    assert(row.resolvedXY.x == 320 and row.resolvedXY.y == 230)
    assert((snap.metrics.viewportResolvedApplies or 0) >= 1)
end)

Test("rejects non viewport-logical coordinate space", function()
    writes = {}
    local ok, err = P:ApplyResolvedViewportPopup(Popup(), nil,
        { x=1,y=2,width=300,height=270,coordinateSpace="native-trigger-relative-v1" }, "owner", { id="bad" })
    assert(ok == false and err == "popup_viewport_resolved_space_invalid", tostring(err))
    assert(writes.anchor == nil)
end)

print(string.format("ColorField popup positioning tests: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
