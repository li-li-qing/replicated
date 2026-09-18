------------------------------------------------------------------------
-- Replicated Suite - ColorField V2 regression contracts
--
-- 维护说明（2026-09-13）：本组测试固定用户实机暴露出的共享颜色选择器故障：
-- 1) 顶层 transient Window 跨父级相对锚到页面 Button，在 RU 客户端可能落到 (0,0)；
-- 2) 140px popup 强塞 RGB/HEX/按钮导致内容重叠；
-- 3) 0..1 RGB + 拖动即持久化，不符合普通用户交互，也制造高频保存；
-- 4) 所有业务 ColorField 必须复用同一共享修复，不允许页面级补丁。
-- 此测试只验证共享 Foundation 契约和页面默认色声明；Native 实机几何仍需 RU 客户端验证。
------------------------------------------------------------------------
local passed, failed = 0, 0

local function Read(path)
    local f = assert(io.open(path, "rb"), "open failed: " .. path)
    local text = assert(f:read("*a"))
    f:close()
    return text
end

local function Test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("PASS colorfield-v2 " .. name)
    else
        failed = failed + 1
        print("FAIL colorfield-v2 " .. name .. ": " .. tostring(err))
    end
end

local controls = Read("ui/framework/rs_ui_controls.lua")
local positioning = Read("ui/framework/rs_ui_popup_positioning.lua")
local business = Read("presentation/v3/pages/rs_v3_business_pages.lua")
local foundation = Read("core/rs_foundation_gate.lua")
local acceptance = Read("presentation/v3/rs_v3_acceptance.lua")
local startPos = assert(controls:find('RSUI:RegisterType("ColorField"', 1, true), "ColorField block missing")
local colorBlock = controls:sub(startPos)

Test("declares ColorField V2 contract", function()
    assert(controls:find("RSUI.ColorFieldContractVersion = 2", 1, true), "ColorField V2 contract not declared")
end)

Test("uses readable 300x270 popup instead of 140px legacy panel", function()
    assert(controls:find("COLORFIELD_POPUP_WIDTH = 300", 1, true), "popup width contract missing")
    assert(controls:find("COLORFIELD_POPUP_HEIGHT = 270", 1, true), "popup height contract missing")
    assert(not colorBlock:find("trigW, 140", 1, true), "legacy 140px popup still present")
end)

Test("RGB controls are user-facing 0..255 integer sliders", function()
    assert(colorBlock:find('label = "红色"', 1, true), "red label not localized")
    assert(colorBlock:find('label = "绿色"', 1, true), "green label not localized")
    assert(colorBlock:find('label = "蓝色"', 1, true), "blue label not localized")
    assert(colorBlock:find("min = 0, max = 255, step = 1, integer = true", 1, true), "RGB sliders are not 0..255 integers")
end)

Test("draft preview is separate from authoritative persisted color", function()
    assert(colorBlock:find("c.draftColor", 1, true), "draft color missing")
    assert(colorBlock:find("function c:ApplyDraft", 1, true), "explicit ApplyDraft transaction missing")
    assert(colorBlock:find("function c:CancelDraft", 1, true), "explicit CancelDraft transaction missing")
    assert(colorBlock:find("function c:RestoreDefaultDraft", 1, true), "restore-default draft transaction missing")
end)

Test("slider movement does not directly call persistence Commit", function()
    local legacy = 'set = function(v) c.color[ch.idx] = Clamp01(v); c:SyncSwatchAndHex(); return c:Commit() end'
    assert(not colorBlock:find(legacy, 1, true), "legacy immediate persistence slider path still present")
end)

Test("normal user actions expose restore cancel apply", function()
    assert(colorBlock:find('text = "恢复默认"', 1, true), "restore-default button missing")
    assert(colorBlock:find('text = "取消"', 1, true), "cancel button missing")
    assert(colorBlock:find('text = "应用"', 1, true), "apply button missing")
    assert(colorBlock:find('text = "选择颜色"', 1, true), "human-readable popup title missing")
    assert(colorBlock:find('text = "当前颜色"', 1, true), "current-color label missing")
end)

Test("popover includes preset palette and large current preview", function()
    assert(colorBlock:find("COLORFIELD_PRESETS", 1, true), "preset palette missing")
    assert(colorBlock:find("c.previewSwatch", 1, true), "large preview swatch missing")
end)

Test("ColorField commits resolved viewport coordinates to UIParent", function()
    assert(positioning:find("PopupViewportResolvedAnchorContractVersion = 1", 1, true), "viewport-resolved popup contract missing")
    assert(positioning:find("function P:ApplyResolvedViewportPopup", 1, true), "resolved viewport commit helper missing")
    assert(colorBlock:find("ApplyResolvedViewportPopup", 1, true), "ColorField does not use resolved viewport helper")
    assert(not colorBlock:find("ApplyNativeRelativePopup(self.popup, self", 1, true), "ColorField still cross-anchors top-level popup to trigger")
end)

Test("resolved popup diagnostics preserve anchor and final native geometry", function()
    assert(positioning:find('mode = "viewport_resolved"', 1, true), "viewport-resolved diagnostic mode missing")
    assert(positioning:find("popupNativeBeforeCorrection", 1, true), "pre-correction native geometry missing")
    assert(positioning:find("popupNativeAfterCorrection", 1, true), "post-correction native geometry missing")
    assert(positioning:find("finalNativeXY", 1, true), "final native XY diagnostic missing")
end)

Test("business ColorFields declare their own restore defaults", function()
    assert(business:find("defaultColor = { defaultColor[1], defaultColor[2], defaultColor[3] }", 1, true), "unit-line defaultColor not passed to shared ColorField")
    assert(business:find("defaultColor = { 0.20, 0.82, 1.00 }", 1, true), "range-assist defaultColor not passed to shared ColorField")
end)

Test("foundation and acceptance gate the new shared contract", function()
    assert(foundation:find("ColorFieldContractVersion", 1, true), "foundation does not gate ColorField V2")
    assert(foundation:find("PopupViewportResolvedAnchorContractVersion", 1, true), "foundation does not gate viewport-resolved lane")
    assert(acceptance:find("ColorFieldContractVersion", 1, true), "acceptance does not gate ColorField V2")
    assert(acceptance:find("PopupViewportResolvedAnchorContractVersion", 1, true), "acceptance does not gate viewport-resolved lane")
end)

Test("shared consumer contract is bumped beyond native-relative-only v2", function()
    assert(controls:find("RSUI.PopupCoordinateConsumerContractVersion = 3", 1, true), "popup consumer contract not bumped to v3")
end)

print(string.format("ColorField V2 tests: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
