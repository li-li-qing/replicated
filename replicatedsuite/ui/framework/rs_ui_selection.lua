------------------------------------------------------------------------
-- Replicated Suite · 稳定身份选择与高亮
-- 作者：Replicated
-- QQ群：1104129461
--
-- ListView/TileView/TableView 共用 key 选择权威，排序/重排不能把选择静默迁到其它条目。
-- 无 Tick 或数据集扫描；多选仅存已选 key，O(selected) 而非 O(data)，View 负责下标映射稳定 key。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
if type(RSUI) ~= "table" then return end

local function NormalizeMode(value)
    local mode = tostring(value or "single"):lower()
    if mode == "none" or mode == "disabled" then return "none" end
    if mode == "multi" or mode == "multiple" then return "multi" end
    return "single"
end

local function NormalizeKey(value)
    if value == nil then return nil end
    local key = tostring(value)
    if key == "" then return nil end
    return key
end


------------------------------------------------------------------------
-- 共享选择表现。
------------------------------------------------------------------------
-- SelectionModel 决定哪些 key 选中，SelectionVisual 统一各 DataView 的呈现；业务页不能自建标记/颜色，未实现 SetSelected() 的自定义列表/图块也受覆盖。
--
-- 每池行/图块一次分配，仅选择变化切换；无 Tick、轮询或数据扫描。
local SelectionVisual = { version = 1 }

local function SelectionColor()
    local tokens = S.UITokens
    local button = type(tokens) == "table" and type(tokens.button) == "table" and tokens.button or nil
    local active = button and button.active or nil
    if type(active) == "table" then
        return tonumber(active[1]) or 0.035, tonumber(active[2]) or 0.145, tonumber(active[3]) or 0.170, math.min(0.88, tonumber(active[4]) or 0.88)
    end
    return 0.035, 0.145, 0.170, 0.88
end

local function AccentColor()
    local tone = S.UITokens and type(S.UITokens.Color) == "function" and S.UITokens:Color("accent") or nil
    if type(tone) == "table" then
        return tonumber(tone[1]) or 0.20, tonumber(tone[2]) or 0.74, tonumber(tone[3]) or 0.84, math.min(1.0, tonumber(tone[4]) or 1.0)
    end
    return 0.20, 0.74, 0.84, 1.0
end

function SelectionVisual:_Ensure(component)
    if type(component) ~= "table" or component.root == nil then return nil end
    if type(component.rsSelectionVisual) == "table" then return component.rsSelectionVisual end
    local root = component.root
    if type(root.CreateColorDrawable) ~= "function" then return nil end

    local r, g, b, a = SelectionColor()
    local fill = root:CreateColorDrawable(r, g, b, a, "background")
    if fill ~= nil and type(fill.AddAnchor) == "function" then
        fill:AddAnchor("TOPLEFT", root, 0, 0)
        fill:AddAnchor("BOTTOMRIGHT", root, 0, 0)
    end

    local ar, ag, ab, aa = AccentColor()
    local accent = root:CreateColorDrawable(ar, ag, ab, aa, "artwork")
    if accent ~= nil and type(accent.AddAnchor) == "function" then
        accent:AddAnchor("TOPLEFT", root, 0, 0)
        accent:AddAnchor("BOTTOMLEFT", root, 0, 0)
        if type(accent.SetWidth) == "function" then accent:SetWidth(3)
        elseif type(accent.SetExtent) == "function" then accent:SetExtent(3, 1) end
    end

    component.rsSelectionVisual = { fill = fill, accent = accent, selected = nil }
    if S.Theme and S.Theme.BindColorDrawable then
        S.Theme:BindColorDrawable(root,fill,'button.active',.88)
        S.Theme:BindColorDrawable(root,accent,'accent')
    end
    if S.UI ~= nil and type(S.UI.SetVisible) == "function" then
        if fill ~= nil then S.UI:SetVisible(fill, false, component.owner) end
        if accent ~= nil then S.UI:SetVisible(accent, false, component.owner) end
    end
    RSUI.metrics.selectionVisualsCreated = (tonumber(RSUI.metrics.selectionVisualsCreated) or 0) + 1
    return component.rsSelectionVisual
end

function SelectionVisual:Apply(component, selected)
    if type(component) ~= "table" then return false end
    selected = selected == true
    component.state = component.state or {}

    -- 保留组件自身 Native 活跃皮肤/TableSkin，共享覆盖层作最终保证；不能预写 state.selected，部分 SetSelected() 用它作 Diff 守卫。
    local specialized = false
    if type(component.SetSelected) == "function" and component.rsSelectionVisualApplying ~= true then
        component.rsSelectionVisualApplying = true
        local ok = pcall(component.SetSelected, component, selected)
        component.rsSelectionVisualApplying = false
        specialized = ok == true
    end
    component.state.selected = selected

    -- 从未选中过的行/图块不分配高亮；首次选择才创建两个共享 drawable，后续绑定/选择均复用。
    local visual = component.rsSelectionVisual
    if selected == true and type(visual) ~= "table" then visual = self:_Ensure(component) end
    if type(visual) == "table" then
        if visual.selected ~= selected then
            visual.selected = selected
            if S.UI ~= nil and type(S.UI.SetVisible) == "function" then
                if visual.fill ~= nil then S.UI:SetVisible(visual.fill, selected, component.owner) end
                if visual.accent ~= nil then S.UI:SetVisible(visual.accent, selected, component.owner) end
            end
            RSUI.metrics.selectionVisualApplications = (tonumber(RSUI.metrics.selectionVisualApplications) or 0) + 1
        end
        return true
    end
    return specialized
end

function SelectionVisual:Clear(component)
    return self:Apply(component, false)
end

RSUI.SelectionVisual = SelectionVisual

local SelectionModel = {}
SelectionModel.__index = SelectionModel

function SelectionModel:GetMode()
    return self.mode
end

function SelectionModel:SetMode(mode)
    local nextMode = NormalizeMode(mode)
    if nextMode == self.mode then return false end
    self.mode = nextMode
    if nextMode == "none" then
        if not self:Clear("mode_none") then self:_Changed("mode_none", nil, nil) end
    elseif nextMode == "single" and self.count > 1 then
        local keep = self.order[1]
        self.selected = {}
        self.order = {}
        self.count = 0
        if keep ~= nil then
            self.selected[keep] = true
            self.order[1] = keep
            self.count = 1
        end
        self:_Changed("mode_single", keep, true)
    else
        self:_Changed("mode", nil, nil)
    end
    return true
end

function SelectionModel:IsSelected(key)
    key = NormalizeKey(key)
    return key ~= nil and self.selected[key] == true
end

function SelectionModel:GetCount()
    return tonumber(self.count) or 0
end

function SelectionModel:GetPrimaryKey()
    return self.order[1]
end

function SelectionModel:GetSelectedKeys()
    local result = {}
    for index, key in ipairs(self.order) do result[index] = key end
    return result
end

function SelectionModel:_Changed(reason, key, selected, context)
    self.revision = (tonumber(self.revision) or 0) + 1
    RSUI.metrics.selectionChanges = (tonumber(RSUI.metrics.selectionChanges) or 0) + 1
    if type(self.onChanged) == "function" then
        RSUI:Callback("rsui:selection:" .. tostring(self.id) .. ":changed", self.onChanged, self, reason, key, selected, context)
    end
    for token, listener in pairs(self.listeners or {}) do
        if type(listener) == "function" then
            RSUI:Callback("rsui:selection:" .. tostring(self.id) .. ":listener:" .. tostring(token), listener, self, reason, key, selected, context)
        end
    end
end

function SelectionModel:Subscribe(token, listener)
    token = tostring(token or "")
    if token == "" or type(listener) ~= "function" then return false end
    self.listeners[token] = listener
    return true
end

function SelectionModel:Unsubscribe(token)
    token = tostring(token or "")
    if self.listeners[token] == nil then return false end
    self.listeners[token] = nil
    return true
end

function SelectionModel:Clear(reason, context)
    if self.count <= 0 then return false end
    self.selected = {}
    self.order = {}
    self.count = 0
    self.anchorKey = nil
    self:_Changed(reason or "clear", nil, false, context)
    return true
end

function SelectionModel:SelectOnly(key, reason, context)
    key = NormalizeKey(key)
    if self.mode == "none" or key == nil then return false end
    if self.count == 1 and self.selected[key] == true then return false end
    self.selected = { [key] = true }
    self.order = { key }
    self.count = 1
    self.anchorKey = key
    self:_Changed(reason or "select_only", key, true, context)
    return true
end

function SelectionModel:SetSelected(key, selected, reason, context)
    key = NormalizeKey(key)
    if self.mode == "none" or key == nil then return false end
    selected = selected == true
    if self.mode == "single" then
        if selected then return self:SelectOnly(key, reason or "select", context) end
        if self.selected[key] ~= true then return false end
        return self:Clear(reason or "deselect", context)
    end

    local exists = self.selected[key] == true
    if exists == selected then return false end
    if selected then
        self.selected[key] = true
        self.order[#self.order + 1] = key
        self.count = self.count + 1
        self.anchorKey = key
    else
        self.selected[key] = nil
        self.count = math.max(0, self.count - 1)
        for index, value in ipairs(self.order) do
            if value == key then table.remove(self.order, index); break end
        end
        if self.anchorKey == key then self.anchorKey = self.order[#self.order] end
    end
    self:_Changed(reason or (selected and "select" or "deselect"), key, selected, context)
    return true
end

function SelectionModel:Toggle(key, reason, context)
    key = NormalizeKey(key)
    if key == nil then return false end
    if self.mode == "single" then
        if self:IsSelected(key) then return self:Clear(reason or "toggle_off", context) end
        return self:SelectOnly(key, reason or "toggle_on", context)
    end
    return self:SetSelected(key, not self:IsSelected(key), reason or "toggle", context)
end

function SelectionModel:GetSnapshot()
    return {
        id = self.id,
        mode = self.mode,
        count = self.count,
        primaryKey = self:GetPrimaryKey(),
        revision = self.revision,
    }
end

function RSUI:CreateSelectionModel(options)
    options = type(options) == "table" and options or {}
    local model = setmetatable({
        id = tostring(options.id or ("selection_" .. tostring((tonumber(self.metrics.selectionModelsCreated) or 0) + 1))),
        mode = NormalizeMode(options.mode),
        selected = {},
        order = {},
        count = 0,
        revision = 0,
        anchorKey = nil,
        onChanged = options.onChanged,
        listeners = {},
    }, SelectionModel)
    self.metrics.selectionModelsCreated = (tonumber(self.metrics.selectionModelsCreated) or 0) + 1
    if type(options.selectedKeys) == "table" and model.mode ~= "none" then
        for _, key in ipairs(options.selectedKeys) do
            key = NormalizeKey(key)
            if key ~= nil and model.selected[key] ~= true then
                if model.mode == "single" and model.count >= 1 then break end
                model.selected[key] = true
                model.order[#model.order + 1] = key
                model.count = model.count + 1
            end
        end
    end
    return model
end

RSUI.SelectionModel = SelectionModel
