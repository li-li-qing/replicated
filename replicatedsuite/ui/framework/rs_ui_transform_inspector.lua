------------------------------------------------------------------------
-- Replicated Suite - RSUI Transform Inspector v2
--
-- Reusable editor-side Inspector for HUD/layout surfaces. It binds to the
-- shared AnchorPivotModel and LayoutEditorSnapSettingsModel; it never owns
-- Feature persistence and never creates a second geometry Authority.
--
-- Layout intent (dense editor inspector):
--   Transform  : local top-left X/Y + width/height
--   Anchor     : 9-point preset + normalized anchor/pivot + anchor offsets
--   Snapping   : enable/grid/alignment/canvas/guides + bounded parameters
--
-- Coordinate labels are explicit because ArcheAge/CryEngine uses top-left
-- origin: +X right, +Y down. "Up" therefore means negative Y.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
local UI = S.UI
if type(RSUI) ~= "table" or type(UI) ~= "table" then return end

RSUI.TransformInspectorContractVersion = 2

local function N(value, fallback)
    local result = tonumber(value)
    if result == nil then result = tonumber(fallback) or 0 end
    return result
end

local function Notify(label, fn, ...)
    if type(fn) ~= "function" then return true end
    local count = select("#", ...)
    local args = { ... }
    local ok, err = xpcall(function() fn(unpack(args, 1, count)) end, S.SafeTraceback)
    -- Inspector callbacks are notifications, never mutation Authority. The local
    -- editor model has already committed before this callback fires, so callback
    -- failure must not turn a successful model mutation into a half-transaction.
    if ok ~= true and S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.Warn) == "function" then
        pcall(function() S.DiagnosticsManager:Warn("ui", "TRANSFORM_INSPECTOR_CALLBACK_FAILED",
            "Transform Inspector 回调失败", { callback = tostring(label), error = tostring(err) }) end)
    end
    return true, nil
end

local function PresetItems()
    local result = {}
    local presets = RSUI.AnchorPresets
    for _, key in ipairs(type(presets) == "table" and presets.order or {}) do
        local row = presets.values and presets.values[key] or nil
        result[#result + 1] = { value = key, text = row and row.label or key }
    end
    result[#result + 1] = { value = "custom", text = "自定义" }
    return result
end

local function RectCopy(rect)
    if type(rect) ~= "table" then return nil end
    return { x = N(rect.x, 0), y = N(rect.y, 0), width = math.max(1, N(rect.width, 1)), height = math.max(1, N(rect.height, 1)) }
end

RSUI:RegisterTypeValidator("TransformInspector", function(spec)
    local rectModel = spec.rectModel or spec.anchorModel
    if type(rectModel) ~= "table" or type(rectModel.GetRect) ~= "function"
        or type(rectModel.SetRect) ~= "function" then
        return false, "transform_inspector_rect_model_required"
    end
    local anchorModel = spec.anchorModel
    if anchorModel ~= nil and (type(anchorModel) ~= "table" or type(anchorModel.GetPlacement) ~= "function"
        or type(anchorModel.SetAnchor) ~= "function" or type(anchorModel.SetPivot) ~= "function") then
        return false, "transform_inspector_anchor_model_invalid"
    end
    local snapModel = spec.snapModel
    if snapModel ~= nil and (type(snapModel) ~= "table" or type(snapModel.GetSnapshot) ~= "function"
        or type(snapModel.SetPatch) ~= "function") then
        return false, "transform_inspector_snap_model_invalid"
    end
    return true
end)

RSUI:RegisterType("TransformInspector", function(spec)
    local rectModel = spec.rectModel or spec.anchorModel
    if type(rectModel) ~= "table" or type(rectModel.GetRect) ~= "function" or type(rectModel.SetRect) ~= "function" then
        return nil, "transform_inspector_rect_model_required"
    end
    local anchorModel = spec.anchorModel
    if anchorModel ~= nil and (type(anchorModel.GetPlacement) ~= "function"
        or type(anchorModel.SetAnchor) ~= "function" or type(anchorModel.SetPivot) ~= "function") then
        return nil, "transform_inspector_anchor_model_invalid"
    end
    local snapModel = spec.snapModel
    if snapModel ~= nil and (type(snapModel) ~= "table" or type(snapModel.GetSnapshot) ~= "function"
        or type(snapModel.SetPatch) ~= "function") then
        return nil, "transform_inspector_snap_model_invalid"
    end

    local width = math.max(220, N(spec.width, 286))
    local root = UI:CreateEmptyWidget(spec.parent, spec.id, N(spec.x, 0), N(spec.y, 0), width, math.max(1, N(spec.height, 10)), false)
    if root == nil then return nil, "transform_inspector_create_failed" end
    local c = RSUI:NewComponent("TransformInspector", spec, root)
    c.rectModel = rectModel
    c.anchorModel = anchorModel
    c.snapModel = snapModel
    c.onTransformChanged = spec.onTransformChanged
    c.onAnchorChanged = spec.onAnchorChanged
    c.onSnapChanged = spec.onSnapChanged
    c.enabled = spec.enabled ~= false
    local BaseSetEnabled = c.SetEnabled

    local function InspectorSnapshot()
        return {
            rect = c.rectModel and type(c.rectModel.GetRect) == "function" and RectCopy(c.rectModel:GetRect()) or nil,
            rectModel = c.rectModel and type(c.rectModel.GetSnapshot) == "function" and c.rectModel:GetSnapshot() or nil,
            anchor = c.anchorModel and type(c.anchorModel.GetSnapshot) == "function" and c.anchorModel:GetSnapshot() or nil,
            mode = c.anchorModel ~= nil and "single" or "group",
        }
    end

    local function MutationNotify(label, fn, ...)
        if type(fn) ~= "function" then return true, nil end
        local count = select("#", ...)
        local args = { ... }
        local ok, accepted, detail = xpcall(function() return fn(unpack(args, 1, count)) end, S.SafeTraceback)
        if ok ~= true then return false, tostring(accepted or (label .. "_callback_failed")) end
        if accepted == false then return false, tostring(detail or (label .. "_rejected")) end
        return true, nil
    end

    local function TransformChanged(source)
        RSUI.metrics.transformInspectorEdits = (tonumber(RSUI.metrics.transformInspectorEdits) or 0) + 1
        return Notify("transform", c.onTransformChanged, InspectorSnapshot(), tostring(source or "inspector"), c)
    end

    local function AnchorChanged(source, previousSnapshot)
        local ok, err = MutationNotify("anchor", c.onAnchorChanged,
            c.anchorModel and c.anchorModel:GetSnapshot() or nil, previousSnapshot, tostring(source or "anchor"), c)
        if ok ~= true then return false, err end
        return TransformChanged(source or "anchor")
    end

    local function SnapChanged(source)
        RSUI.metrics.transformInspectorSnapEdits = (tonumber(RSUI.metrics.transformInspectorSnapEdits) or 0) + 1
        if c.snapModel == nil then return true end
        return Notify("snap", c.onSnapChanged, c.snapModel:GetSnapshot(), tostring(source or "inspector"), c)
    end

    local function RectBinding(key, minimum, maximum)
        return RSUI:Binding({
            id = spec.id .. "_bind_rect_" .. key,
            get = function()
                local rect = c.rectModel:GetRect()
                return rect and rect[key] or 0
            end,
            set = function(value, final, source)
                local rect = RectCopy(c.rectModel:GetRect())
                if rect == nil then return false, "transform_rect_unavailable" end
                rect[key] = tonumber(value)
                if (key == "width" or key == "height") and rect[key] <= 0 then return false, "transform_extent_invalid" end
                local ok, err = c.rectModel:SetRect(rect, "inspector:" .. key)
                if ok ~= true then return false, err end
                local notifyOk, notifyErr = TransformChanged(source or key)
                if notifyOk ~= true then return false, notifyErr end
                return true
            end,
            validate = function(value)
                value = tonumber(value)
                if value == nil then return false, "请输入有效数字" end
                if minimum ~= nil and value < minimum then return false, "低于允许范围" end
                if maximum ~= nil and value > maximum then return false, "超过允许范围" end
                return true
            end,
        })
    end

    local function PlacementBinding(key)
        return RSUI:Binding({
            id = spec.id .. "_bind_placement_" .. key,
            get = function()
                local placement = c.anchorModel and c.anchorModel:GetPlacement() or nil
                return placement and placement[key] or 0
            end,
            set = function(value, final, source)
                if c.anchorModel == nil then return false, "transform_anchor_model_unavailable" end
                local previous = c.anchorModel:GetSnapshot()
                local placement = c.anchorModel:GetPlacement()
                if type(placement) ~= "table" then return false, "transform_placement_unavailable" end
                placement[key] = tonumber(value)
                local ok, err = c.anchorModel:SetPlacement(placement.positionX, placement.positionY,
                    placement.width, placement.height, "inspector:" .. key)
                if ok ~= true then return false, err end
                local notifyOk, notifyErr = AnchorChanged(source or key, previous)
                if notifyOk ~= true then return false, notifyErr end
                return true
            end,
        })
    end

    local function AnchorNumberBinding(axis)
        return RSUI:Binding({
            id = spec.id .. "_bind_anchor_" .. axis,
            get = function() local s = c.anchorModel and c.anchorModel:GetSnapshot() or nil; return s and s["anchor" .. axis:upper()] or 0 end,
            set = function(value, final, source)
                if c.anchorModel == nil then return false, "transform_anchor_model_unavailable" end
                local s = c.anchorModel:GetSnapshot()
                local previous = s
                local x, y = s.anchorX, s.anchorY
                if axis == "x" then x = tonumber(value) else y = tonumber(value) end
                local ok, err = c.anchorModel:SetAnchor(x, y, true, "inspector:anchor_" .. axis)
                if ok ~= true then return false, err end
                local notifyOk, notifyErr = AnchorChanged(source or ("anchor_" .. axis), previous)
                if notifyOk ~= true then return false, notifyErr end
                return true
            end,
            validate = function(value) value = tonumber(value); return value ~= nil and value >= 0 and value <= 1, "范围应为 0～1" end,
        })
    end

    local function PivotBinding(axis)
        return RSUI:Binding({
            id = spec.id .. "_bind_pivot_" .. axis,
            get = function() local s = c.anchorModel and c.anchorModel:GetSnapshot() or nil; return s and s["pivot" .. axis:upper()] or 0 end,
            set = function(value, final, source)
                if c.anchorModel == nil then return false, "transform_anchor_model_unavailable" end
                local s = c.anchorModel:GetSnapshot()
                local previous = s
                local x, y = s.pivotX, s.pivotY
                if axis == "x" then x = tonumber(value) else y = tonumber(value) end
                local ok, err = c.anchorModel:SetPivot(x, y, true, "inspector:pivot_" .. axis)
                if ok ~= true then return false, err end
                local notifyOk, notifyErr = AnchorChanged(source or ("pivot_" .. axis), previous)
                if notifyOk ~= true then return false, notifyErr end
                return true
            end,
            validate = function(value) value = tonumber(value); return value ~= nil and value >= 0 and value <= 1, "范围应为 0～1" end,
        })
    end

    local anchorPresetBinding = RSUI:Binding({
        id = spec.id .. "_bind_anchor_preset",
        get = function() return c.anchorModel and c.anchorModel:GetPreset() or "custom" end,
        set = function(value, final, source)
            if c.anchorModel == nil then return false, "transform_anchor_model_unavailable" end
            value = tostring(value or "")
            if value == "custom" then return true end
            local previous = c.anchorModel:GetSnapshot()
            local ok, err = c.anchorModel:SetAnchorPreset(value, true, "inspector:anchor_preset")
            if ok ~= true then return false, err end
            local notifyOk, notifyErr = AnchorChanged(source or "anchor_preset", previous)
            if notifyOk ~= true then return false, notifyErr end
            return true
        end,
    })

    local function SnapBinding(key, kind)
        if c.snapModel == nil then return nil end
        return RSUI:Binding({
            id = spec.id .. "_bind_snap_" .. key,
            get = function() local s = c.snapModel:GetSnapshot(); return s[key] end,
            set = function(value, final, source)
                local patch = {}
                if kind == "bool" then patch[key] = value == true else patch[key] = tonumber(value) end
                local ok, err = c.snapModel:SetPatch(patch, "inspector:" .. key)
                if ok ~= true then return false, err end
                local notifyOk, notifyErr = SnapChanged(source or key)
                if notifyOk ~= true then return false, notifyErr end
                return true
            end,
        })
    end

    c.form = RSUI:Form({ id = spec.id .. "_form", parent = c, width = width, sectionGap = 8 })
    if c.form == nil then c:Release(); return nil, "transform_inspector_form_create_failed" end

    local transform = c.form:AddSection({
        id = spec.id .. "_transform", title = "变换", minColumns = 2, maxColumns = 2,
        minCellWidth = 104, fieldHeight = 46, gapX = 6, gapY = 6,
    })
    local anchor = c.form:AddSection({
        id = spec.id .. "_anchor", title = "锚点与轴心", minColumns = 2, maxColumns = 2,
        minCellWidth = 104, fieldHeight = 46, gapX = 6, gapY = 6,
    })
    local snapping = c.snapModel and c.form:AddSection({
        id = spec.id .. "_snap", title = "吸附与参考线", minColumns = 2, maxColumns = 2,
        minCellWidth = 104, fieldHeight = 46, gapX = 6, gapY = 6,
    }) or nil
    if transform == nil or anchor == nil or (c.snapModel ~= nil and snapping == nil) then
        c:Release(); return nil, "transform_inspector_section_create_failed"
    end

    c.transformSection, c.anchorSection, c.snapSection = transform, anchor, snapping
    anchor:SetVisibility(c.anchorModel ~= nil and RSUI.Visibility.Visible or RSUI.Visibility.Collapsed)

    local numericCommon = {
        type = "NumericField", inline = true, slider = false, stepButtons = false,
        step = 1, inputWidth = 70, labelMinWidth = 54, labelWidth = 88,
    }
    local function AddNumeric(section, id, label, binding, minimum, maximum, step, hint)
        local row = {}
        for key, value in pairs(numericCommon) do row[key] = value end
        row.id, row.label, row.binding = spec.id .. "_" .. id, label, binding
        row.min, row.max, row.step, row.hint = minimum, maximum, step or 1, hint
        return c.form:AddField(section, row)
    end

    AddNumeric(transform, "x", "X（左-/右+）", RectBinding("x", -8192, 8192), -8192, 8192, 1)
    AddNumeric(transform, "y", "Y（上-/下+）", RectBinding("y", -8192, 8192), -8192, 8192, 1)
    AddNumeric(transform, "width", "宽度", RectBinding("width", 1, 8192), 1, 8192, 1)
    AddNumeric(transform, "height", "高度", RectBinding("height", 1, 8192), 1, 8192, 1)

    c.form:AddField(anchor, {
        type = "DropdownField", id = spec.id .. "_anchor_preset", label = "锚点预设",
        binding = anchorPresetBinding, items = PresetItems(), controlWidth = 126,
        hint = "切换预设默认保持当前视觉位置",
    })
    AddNumeric(anchor, "anchor_x", "锚点 X", AnchorNumberBinding("x"), 0, 1, 0.05)
    AddNumeric(anchor, "anchor_y", "锚点 Y", AnchorNumberBinding("y"), 0, 1, 0.05)
    AddNumeric(anchor, "pivot_x", "Pivot X", PivotBinding("x"), 0, 1, 0.05)
    AddNumeric(anchor, "pivot_y", "Pivot Y", PivotBinding("y"), 0, 1, 0.05)
    AddNumeric(anchor, "offset_x", "锚点偏移 X", PlacementBinding("positionX"), -8192, 8192, 1)
    AddNumeric(anchor, "offset_y", "锚点偏移 Y", PlacementBinding("positionY"), -8192, 8192, 1)

    if snapping ~= nil then
        c.form:AddField(snapping, { type = "ToggleField", id = spec.id .. "_snap_enabled", label = "启用吸附", binding = SnapBinding("enabled", "bool") })
        c.form:AddField(snapping, { type = "ToggleField", id = spec.id .. "_snap_grid", label = "网格吸附", binding = SnapBinding("gridEnabled", "bool") })
        c.form:AddField(snapping, { type = "ToggleField", id = spec.id .. "_snap_alignment", label = "对象对齐", binding = SnapBinding("alignmentEnabled", "bool") })
        c.form:AddField(snapping, { type = "ToggleField", id = spec.id .. "_snap_canvas", label = "画布边界/中心", binding = SnapBinding("canvasEnabled", "bool") })
        c.form:AddField(snapping, { type = "ToggleField", id = spec.id .. "_snap_guides", label = "显示参考线", binding = SnapBinding("showGuides", "bool") })
        AddNumeric(snapping, "grid_size", "网格尺寸", SnapBinding("gridSize", "number"), 1, 128, 1)
        AddNumeric(snapping, "snap_threshold", "吸附阈值", SnapBinding("threshold", "number"), 0, 32, 1)
        AddNumeric(snapping, "snap_candidates", "候选上限", SnapBinding("maxCandidates", "number"), 1, 1024, 1)
    end

    function c:SetRectModel(model)
        if type(model) ~= "table" or type(model.GetRect) ~= "function" or type(model.SetRect) ~= "function" then
            return false, "transform_inspector_rect_model_invalid"
        end
        self.rectModel = model
        return true, nil
    end

    function c:SetAnchorModel(model)
        if model ~= nil and (type(model) ~= "table" or type(model.GetPlacement) ~= "function"
            or type(model.SetAnchor) ~= "function" or type(model.SetPivot) ~= "function") then
            return false, "transform_inspector_anchor_model_invalid"
        end
        self.anchorModel = model
        if self.anchorSection ~= nil then
            self.anchorSection:SetVisibility(model ~= nil and RSUI.Visibility.Visible or RSUI.Visibility.Collapsed)
        end
        return true, nil
    end

    function c:SetModels(nextRectModel, nextAnchorModel)
        local ok, err = self:SetRectModel(nextRectModel)
        if ok ~= true then return false, err end
        ok, err = self:SetAnchorModel(nextAnchorModel)
        if ok ~= true then return false, err end
        self:Refresh()
        return true, nil
    end

    function c:Refresh()
        if self.form ~= nil then self.form:Render() end
        RSUI.metrics.transformInspectorRefreshes = (tonumber(RSUI.metrics.transformInspectorRefreshes) or 0) + 1
        return true
    end

    function c:SetEnabled(enabled)
        local nextEnabled = enabled ~= false
        if type(BaseSetEnabled) == "function" then BaseSetEnabled(self, nextEnabled) else self.enabled = nextEnabled end
        if self.form ~= nil then
            for _, field in ipairs(self.form:GetFields() or {}) do if type(field.SetEnabled) == "function" then field:SetEnabled(self.enabled) end end
        end
        return self.enabled
    end

    function c:Layout(x, y, nextWidth, nextHeight)
        local w = math.max(220, N(nextWidth, self.width or width))
        local used = self.form:Layout(0, 0, w, nextHeight)
        UI:SetAnchor(self.root, spec.parent, N(x, 0), N(y, 0), self.owner)
        UI:SetExtent(self.root, w, math.max(1, N(used, 1)), self.owner)
        self:CommitLayoutState(N(x, 0), N(y, 0), w, math.max(1, N(used, 1)))
        RSUI.metrics.transformInspectorLayouts = (tonumber(RSUI.metrics.transformInspectorLayouts) or 0) + 1
        return used
    end

    function c:GetSnapshot()
        return {
            contractVersion = tonumber(RSUI.TransformInspectorContractVersion) or 0,
            enabled = self.enabled == true,
            rect = self.rectModel and type(self.rectModel.GetRect) == "function" and RectCopy(self.rectModel:GetRect()) or nil,
            rectModel = self.rectModel and type(self.rectModel.GetSnapshot) == "function" and self.rectModel:GetSnapshot() or nil,
            anchor = self.anchorModel and self.anchorModel:GetSnapshot() or nil,
            mode = self.anchorModel ~= nil and "single" or "group",
            snap = self.snapModel and self.snapModel:GetSnapshot() or nil,
        }
    end

    c:SetEnabled(c.enabled)
    c:Refresh()
    return c
end)
