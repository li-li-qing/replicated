------------------------------------------------------------------------
-- Replicated Suite - reusable settings, list and layout components
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI = S.UI
local Value = S.Reuse and S.Reuse.Value or S.Utils

function UI:CreateSettingBinding(options)
    if UI.Binding ~= nil and type(UI.Binding.Create) == "function" then return UI.Binding:Create(options) end
    options = type(options) == "table" and options or {}
    local binding = { options = options }
    function binding:Get() return type(options.get) == "function" and options.get() or options.value end
    function binding:Set(value, final, source, previous)
        if type(options.set) ~= "function" then return true end
        local ok, accepted = xpcall(function() return options.set(value, final == true, tostring(source or "program"), previous) end, S.SafeTraceback)
        if not ok then S.SafeChat("设置写入失败：" .. tostring(accepted), "error"); return false end
        return accepted ~= false
    end
    function binding:Commit()
        if type(options.commit) ~= "function" then return true end
        local ok, accepted = xpcall(options.commit, S.SafeTraceback)
        if not ok then S.SafeChat("设置保存失败：" .. tostring(accepted), "error"); return false end
        return accepted ~= false
    end
    return binding
end

function UI:CreatePager(options)
    options = type(options) == "table" and options or {}
    local pager = { pageSize = math.max(1, math.floor(tonumber(options.pageSize) or 1)), page = 1, total = 0 }
    function pager:SetTotal(total)
        self.total = math.max(0, math.floor(tonumber(total) or 0))
        self.page = math.min(self.page, self:GetPageCount())
        return self.page
    end
    function pager:GetPageCount() return math.max(1, math.ceil(self.total / self.pageSize)) end
    function pager:SetPage(page) self.page = math.max(1, math.min(self:GetPageCount(), math.floor(tonumber(page) or 1))); return self.page end
    function pager:Move(delta) return self:SetPage(self.page + (tonumber(delta) or 0)) end
    function pager:GetRange()
        local first = self.total > 0 and ((self.page - 1) * self.pageSize + 1) or 0
        return first, math.min(self.total, first + self.pageSize - 1)
    end
    function pager:Bind(previous, nextButton, label, onChanged)
        local function refresh()
            if label ~= nil and type(label.SetText) == "function" then label:SetText(tostring(pager.page) .. "/" .. tostring(pager:GetPageCount())) end
            local multiple = pager:GetPageCount() > 1
            if previous ~= nil then previous:Show(multiple); if previous.Enable then previous:Enable(multiple and pager.page > 1) end end
            if nextButton ~= nil then nextButton:Show(multiple); if nextButton.Enable then nextButton:Enable(multiple and pager.page < pager:GetPageCount()) end end
        end
        if previous ~= nil then UI:SafeHandler(previous, "OnClick", function() pager:Move(-1); refresh(); if onChanged then onChanged(pager) end end, tostring(options.id or "pager") .. ":previous") end
        if nextButton ~= nil then UI:SafeHandler(nextButton, "OnClick", function() pager:Move(1); refresh(); if onChanged then onChanged(pager) end end, tostring(options.id or "pager") .. ":next") end
        pager.RefreshControls = refresh
        refresh()
        return pager
    end
    return pager
end

function UI:CreateNumericSettingControl(parent, id, options)
    options = type(options) == "table" and options or {}
    local prefix = tostring(id or "numeric")
    local row = { options = options, value = nil, destroyed = false }
    local x, y = tonumber(options.x) or 0, tonumber(options.y) or 0
    local labelWidth, sliderWidth = tonumber(options.labelWidth) or 104, tonumber(options.sliderWidth) or 112
    local height = tonumber(options.height) or 24
    row.label = UI:CreateLabel(parent, prefix .. "_label", tostring(options.label or "数值") .. "：", x, y + 2, labelWidth, height, tonumber(options.fontSize) or 9, nil, ALIGN_LEFT)
    row.minus = UI:CreateButton(parent, prefix .. "_minus", "-", x + labelWidth + sliderWidth + 4, y, 25, height, 10, false)
    row.slider = UI:CreateSlider(parent, prefix .. "_slider", x + labelWidth, y + 2, sliderWidth, math.max(16, height - 4), options.min, options.max, options.step, options.value)
    row.edit = UI:CreateEditBox(parent, prefix .. "_edit", x + labelWidth + sliderWidth + 33, y, tonumber(options.editWidth) or 54, height, tonumber(options.maxLength) or 14)
    row.plus = UI:CreateButton(parent, prefix .. "_plus", "+", x + labelWidth + sliderWidth + (tonumber(options.editWidth) or 54) + 41, y, 25, height, 10, false)

    function row:Normalize(value) return Value.Normalize(value, options) end
    function row:Format(value) return Value.Format(value, options) end
    function row:Render(value)
        self.value = self:Normalize(value)
        if self.edit ~= nil and self.edit.SetText then self.edit:SetText(self:Format(self.value)) end
        if self.slider ~= nil and type(self.slider.SetValue) == "function" then self.slider:SetValue(self.value, false)
        elseif self.slider ~= nil and UI.UpdateSliderVisual then UI:UpdateSliderVisual(self.slider, self.value) end
        return self.value
    end
    function row:SetValue(value, emit, final, source)
        local nextValue = self:Normalize(value)
        local previous = self.value
        if emit == true then
            local ok, accepted
            if type(options.onChanged) == "function" then
                ok, accepted = xpcall(function() return options.onChanged(nextValue, final == true, tostring(source or "program"), previous) end, S.SafeTraceback)
            elseif options.binding ~= nil and type(options.binding.Set) == "function" then
                ok, accepted = xpcall(function() return options.binding:Set(nextValue, final == true, tostring(source or "program"), previous) end, S.SafeTraceback)
            else
                ok, accepted = true, true
            end
            if not ok or accepted == false then self:Render(previous); return false end
        end
        self:Render(nextValue)
        return true
    end
    function row:Refresh()
        local getter = options.getValue or (options.binding and options.binding.Get)
        return self:SetValue(type(getter) == "function" and getter() or self.value or options.value or options.min, false)
    end
    function row:SetEnabled(enabled)
        for _, widget in ipairs({ self.minus, self.slider, self.edit, self.plus }) do
            if widget ~= nil and type(widget.SetEnabled) == "function" then widget:SetEnabled(enabled == true)
            elseif widget ~= nil and widget.Enable then widget:Enable(enabled == true) end
        end
    end
    function row:Destroy()
        self.destroyed = true
        for _, widget in ipairs({ self.label, self.minus, self.slider, self.edit, self.plus }) do if widget ~= nil and widget.Show then widget:Show(false) end end
    end
    local step = tonumber(options.step) or 1
    UI:SafeHandler(row.minus, "OnClick", function() return row:SetValue((row.value or options.min or 0) - step, true, true, "minus") end, prefix .. ":minus")
    UI:SafeHandler(row.plus, "OnClick", function() return row:SetValue((row.value or options.min or 0) + step, true, true, "plus") end, prefix .. ":plus")
    local function submitEdit()
        if row.edit == nil or type(row.edit.GetText) ~= "function" then return false end
        local text = tostring(row.edit:GetText() or "")
        local unit = tostring(options.unit or "")
        if unit ~= "" then text = text:gsub(unit, "") end
        if not Value.IsFinite(text) then row:Render(row.value); return false end
        return row:SetValue(tonumber(text), true, true, "edit")
    end
    for _, eventName in ipairs({ "OnEnterPressed", "OnEditEnter", "OnLostFocus" }) do UI:SafeHandler(row.edit, eventName, submitEdit, prefix .. ":edit:" .. eventName) end
    if row.slider ~= nil and type(row.slider.SetValueChangedHandler) == "function" then
        row.slider:SetValueChangedHandler(function(value, final) row:SetValue(value, true, final == true, "slider") end)
    else
        local function changed()
            if row.slider ~= nil and type(row.slider.GetValue) == "function" then return row:SetValue(row.slider:GetValue(), true, true, "slider") end
            return false
        end
        UI:SafeHandler(row.slider, "OnValueChanged", changed, prefix .. ":slider")
        UI:SafeHandler(row.slider, "OnSliderChanged", changed, prefix .. ":slider_legacy")
    end
    row:Refresh()
    return row
end

function UI:CreateToggleSettingControl(parent, id, options)
    options = type(options) == "table" and options or {}
    local binding = options.binding or UI:CreateSettingBinding({ get=options.getValue, set=options.onChanged, commit=options.commit })
    local button = UI:CreateButton(parent, tostring(id) .. "_toggle", "", tonumber(options.x) or 0, tonumber(options.y) or 0,
        tonumber(options.width) or 112, tonumber(options.height) or 24, tonumber(options.fontSize) or 9, false)
    local control = { button=button, binding=binding }
    function control:Refresh()
        local enabled = binding:Get() == true
        button:SetText(tostring(options.label or "开关") .. "：" .. (enabled and tostring(options.onText or "开") or tostring(options.offText or "关")))
        if S.Theme and S.Theme.SetButtonActive then S.Theme:SetButtonActive(button, enabled) end
        return enabled
    end
    S.UI:SafeHandler(button, "OnClick", function()
        local nextValue = not (binding:Get() == true)
        if binding:Set(nextValue, true, "toggle") then binding:Commit(); control:Refresh() end
    end, tostring(id) .. ":toggle")
    control:Refresh()
    return control
end

function UI:CreateChoiceSettingControl(parent, id, options)
    options = type(options) == "table" and options or {}
    local values = type(options.values) == "table" and options.values or {}
    local binding = options.binding or UI:CreateSettingBinding({ get=options.getValue, set=options.onChanged, commit=options.commit })
    local x, y = tonumber(options.x) or 0, tonumber(options.y) or 0
    local height, width = tonumber(options.height) or 24, tonumber(options.width) or 112
    local previous = UI:CreateButton(parent, tostring(id) .. "_previous", "<", x, y, 24, height, 9, false)
    local label = UI:CreateButton(parent, tostring(id) .. "_label", "", x + 28, y, width, height, tonumber(options.fontSize) or 9, false)
    local nextButton = UI:CreateButton(parent, tostring(id) .. "_next", ">", x + 32 + width, y, 24, height, 9, false)
    local control = { previous=previous, label=label, next=nextButton, binding=binding }
    local function indexOf(value)
        for i, item in ipairs(values) do if (type(item) == "table" and item.value or item) == value then return i end end
        return 1
    end
    function control:Refresh()
        local item = values[indexOf(binding:Get())] or {}
        local text = type(item) == "table" and (item.label or item.value) or item
        label:SetText(tostring(options.label or "选项") .. "：" .. tostring(text or "--"))
    end
    local function move(delta)
        if #values == 0 then return end
        local index = ((indexOf(binding:Get()) - 1 + delta) % #values) + 1
        local item = values[index]; local value = type(item) == "table" and item.value or item
        if binding:Set(value, true, "choice") then binding:Commit(); control:Refresh() end
    end
    S.UI:SafeHandler(previous, "OnClick", function() move(-1) end, tostring(id) .. ":previous")
    S.UI:SafeHandler(nextButton, "OnClick", function() move(1) end, tostring(id) .. ":next")
    S.UI:SafeHandler(label, "OnClick", function() move(1) end, tostring(id) .. ":label")
    control:Refresh()
    return control
end

function UI:CreateWidgetRegistry()
    local registry = { items = {}, sections = {} }
    function registry:Register(section, widget)
        section = tostring(section or "default"); self.sections[section] = self.sections[section] or {}
        self.sections[section][#self.sections[section] + 1] = widget; self.items[#self.items + 1] = widget; return widget
    end
    function registry:SetSectionVisible(section, visible)
        for _, widget in ipairs(self.sections[tostring(section or "default")] or {}) do if widget ~= nil and widget.Show then widget:Show(visible == true) end end
    end
    function registry:Destroy()
        for _, widget in ipairs(self.items) do if widget ~= nil and widget.Show then widget:Show(false) end end
        self.items, self.sections = {}, {}
    end
    return registry
end

function UI:CreateFormLayout(options)
    options = type(options) == "table" and options or {}
    -- Compatibility adapter: old callers only need Next(); new callers should
    -- use UI.LayoutV2:VStack/HStack/Grid/Form directly.
    local layout = { x = tonumber(options.x) or 0, y = tonumber(options.y) or 0, rowHeight = tonumber(options.rowHeight) or 28, gap = tonumber(options.gap) or 4, index = 0 }
    function layout:Next(columns, column)
        self.index = self.index + 1
        columns = math.max(1, math.floor(tonumber(columns) or 1)); column = math.max(1, math.min(columns, math.floor(tonumber(column) or 1)))
        return self.x + (column - 1) * (tonumber(options.columnWidth) or 260), self.y + (self.index - 1) * (self.rowHeight + self.gap)
    end
    function layout:AsV2(parent)
        if UI.LayoutV2 == nil then return nil end
        return UI.LayoutV2:VStack(parent, { x=self.x, y=self.y, height=self.rowHeight, gap=self.gap, owner=options.owner })
    end
    return layout
end
