-- Replicated Suite visual overlay native-layer regression.
-- 维护（2026-09-17）：范围辅助 / 单位连线属于世界 HUD 引导，不是插件窗口。
-- 它们必须位于 game 层，避免遮挡背包、拍卖、地图等 normal/dialog/system 原生窗口；
-- 同时保持 non-pickable，不能截获鼠标。测试只验证 Foundation Native policy，
-- 不冒充 ArcheRage RU 客户端最终渲染顺序的实机验收。

local pass, fail = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        pass = pass + 1
        print("PASS visual-overlay-layer " .. name)
    else
        fail = fail + 1
        print("FAIL visual-overlay-layer " .. name .. ": " .. tostring(err))
    end
end

local function NewNative(id)
    local n = { id = id, shown = nil, layer = nil, pickable = nil, clickable = nil }
    function n:SetUILayer(value) self.layer = value; return true end
    function n:SetCloseOnEscape(value) self.closeOnEscape = value; return true end
    function n:SetWindowModal(value) self.modal = value; return true end
    function n:SetDrawPriority(value) self.priority = value; return true end
    function n:AddAnchor(...) self.anchor = { ... }; return true end
    function n:SetExtent(w, h) self.width, self.height = w, h; return true end
    function n:EnablePick(value) self.pickable = value; return value end
    function n:Clickable(value) self.clickable = value; return value end
    function n:CorrectOffsetByScreen() return true end
    function n:Show(value) self.shown = value; return true end
    return n
end

local function LoadHost()
    UIParent = NewNative("UIParent")
    ReplicatedSuite = {
        BootError = nil,
        Generation = 917,
        PhysicalId = function(value) return tostring(value) end,
        UITokens = { Number = function(_, key, fallback) return fallback end },
        NativeObjectFactory = {
            CreateWindow = function(_, id, parent, template)
                return NewNative(id)
            end,
        },
    }
    dofile("ui/rs_ui_native_primitives.lua")
    return ReplicatedSuite
end

Test("unit-line overlay host stays below native windows", function()
    local S = LoadHost()
    local host = assert(S.UI:CreateOverlayWindow("v3_visual_unit_host", "v3:combat_visual_guides"))
    assert(host.layer == "game", "unit-line overlay must use game layer, got " .. tostring(host.layer))
    assert(host.pickable == false and host.clickable == false, "unit-line overlay must remain non-pickable")
end)

Test("range-assist overlay host stays below native windows", function()
    local S = LoadHost()
    local host = assert(S.UI:CreateOverlayWindow("v3_visual_range_host", "v3:combat_visual_guides"))
    assert(host.layer == "game", "range overlay must use game layer, got " .. tostring(host.layer))
    assert(host.pickable == false and host.clickable == false, "range overlay must remain non-pickable")
end)

print(string.format("VISUAL OVERLAY LAYER RESULT: %d passed, %d failed", pass, fail))
if fail > 0 then error("visual overlay layer suite failures: " .. fail) end
