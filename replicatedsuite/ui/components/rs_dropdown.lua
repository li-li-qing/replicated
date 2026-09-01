------------------------------------------------------------------------
-- Replicated Suite - Reusable dropdown
-- Author: Replicated
--
-- The popup is parented to UIParent so it always renders above dashboard
-- cards.  Item refresh preserves the current scroll anchor: periodic Suite
-- data refresh must never drag a user's open dropdown back to the top.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Dropdown = { instances = {} }

local function ClampIndex(index, count)
    if count <= 0 then return 0 end
    index = math.floor(tonumber(index) or 1)
    if index < 1 then return 1 end
    if index > count then return count end
    return index
end

local function FindValue(items, value)
    if value == nil then return nil end
    for i, item in ipairs(items or {}) do
        if item.value == value then return i end
    end
    return nil
end

function S.Dropdown:Create(parent, id, width, height, maxVisible, onSelect)
    local dd = {
        id = id,
        parent = parent,
        items = {},
        selectedValue = nil,
        selectedIndex = 0,
        scrollOffset = 0,
        maxVisible = math.max(3, math.floor(tonumber(maxVisible) or 8)),
        onSelect = onSelect,
        optionButtons = {},
    }

    dd.trigger = S.UI:CreateButton(parent, id .. "_trigger", "请选择  ▼", 0, 0, width or 180, height or 26, 10, false, true)
    dd.trigger.rsDropdownTrigger = true
    if dd.trigger.style and dd.trigger.style.SetAlign then pcall(function() dd.trigger.style:SetAlign(ALIGN_LEFT) end) end

    local popup = CreateEmptyWindow(S.PhysicalId(id .. "_popup"), "UIParent")
    dd.popup = popup
    -- The popup is physically parented to UIParent for z-order safety, but its
    -- logical Lifecycle owner must remain the same as the trigger. Otherwise a
    -- released dialog could leave an orphan popup/handler set behind.
    popup.rsUiOwner = dd.trigger and dd.trigger.rsUiOwner or (parent and parent.rsUiOwner) or "suite"
    if type(S.UI.AdoptWidget) == "function" then S.UI:AdoptWidget(popup, popup.rsUiOwner, id .. "_popup") end
    S.UI:TrySetUILayer(popup, "system")
    if popup.SetDrawPriority ~= nil then pcall(function() popup:SetDrawPriority(10000) end) end
    if popup.Enable ~= nil then popup:Enable(true) end
    if popup.Clickable ~= nil then popup:Clickable(true) end
    S.Theme:AddBorder(popup, true)
    S.Theme:AddGradientBackground(popup, "panel", nil)
    S.Theme:SetOpacity(popup, 1.0)
    popup:Show(false)

    dd.up = S.UI:CreateButton(popup, id .. "_up", "^", 0, 0, 24, 22, 9, false)
    dd.down = S.UI:CreateButton(popup, id .. "_down", "v", 0, 0, 24, 22, 9, false)

    local function Close()
        popup:Show(false)
    end
    dd.Close = Close

    local function RefreshButtons()
        local count = #dd.items
        local visible = math.min(dd.maxVisible, count)
        local needScroll = count > dd.maxVisible
        dd.scrollOffset = math.max(0, math.min(dd.scrollOffset, math.max(0, count - dd.maxVisible)))

        for i = 1, dd.maxVisible do
            local button = dd.optionButtons[i]
            local itemIndex = dd.scrollOffset + i
            local item = dd.items[itemIndex]
            local show = item ~= nil and i <= visible
            button:Show(show)
            if show then
                button:SetText(tostring(item.text or item.value or "--"))
                button.rsItemIndex = itemIndex
                button.rsDropdownSelectable = item.selectable ~= false and item.kind ~= "header"
                if button.Enable ~= nil then pcall(function() button:Enable(button.rsDropdownSelectable) end) end
                if button.style ~= nil and type(button.style.SetColor) == "function" and S.VisualTokens ~= nil then
                    local tone = (item.kind == "header" or item.selectable == false) and "gold" or "textStrong"
                    local c = S.VisualTokens:Color(tone) or S.VisualTokens:Color("textStrong")
                    pcall(function() button.style:SetColor(c[1], c[2], c[3], c[4] or 1) end)
                end
            else
                button.rsItemIndex = nil
                button.rsDropdownSelectable = false
            end
        end
        dd.up:Show(needScroll)
        dd.down:Show(needScroll)
        if dd.up.Enable then dd.up:Enable(needScroll and dd.scrollOffset > 0) end
        if dd.down.Enable then dd.down:Enable(needScroll and dd.scrollOffset < math.max(0, count - dd.maxVisible)) end
    end

    -- Preserve the top visible item whenever the backing list is refreshed.
    -- Services legitimately republish zone data while the popup is open; that
    -- must not reset the user's manual scroll position.
    function dd:SetItems(items)
        local nextItems = type(items) == "table" and items or {}
        local oldTop = self.items[(self.scrollOffset or 0) + 1]
        local oldTopValue = oldTop and oldTop.value or nil
        local oldOffset = tonumber(self.scrollOffset) or 0

        self.items = nextItems

        local anchoredIndex = FindValue(self.items, oldTopValue)
        if anchoredIndex ~= nil then
            self.scrollOffset = anchoredIndex - 1
        else
            self.scrollOffset = math.max(0, math.min(oldOffset, math.max(0, #self.items - self.maxVisible)))
        end

        local selectedIndex = FindValue(self.items, self.selectedValue)
        self.selectedIndex = selectedIndex or 0
        self:RefreshText()
        RefreshButtons()
    end

    function dd:RefreshText()
        local text = "请选择"
        local item = self.items[self.selectedIndex]
        if item ~= nil then text = tostring(item.text or item.value or "请选择") end
        self.trigger:SetText(text .. "  ▼")
    end

    function dd:SetSelectedValue(value, silent)
        self.selectedValue = value
        self.selectedIndex = FindValue(self.items, value) or 0
        self:RefreshText()
        if silent ~= true and self.selectedIndex > 0 and type(self.onSelect) == "function" then
            self.onSelect(self.items[self.selectedIndex])
        end
    end

    function dd:GetSelectedValue()
        return self.selectedValue
    end

    function dd:ApplyLayout(x, y, w, h, popupWidth)
        w = math.max(100, tonumber(w) or width or 180)
        h = math.max(22, tonumber(h) or height or 26)
        self.lastLayout = { x = tonumber(x) or 0, y = tonumber(y) or 0, w = w, h = h, popupWidth = popupWidth }
        S.UI:SetAnchor(self.trigger, parent, x or 0, y or 0)
        self.trigger:SetExtent(w, h)
        if self.popup.RemoveAllAnchors ~= nil then self.popup:RemoveAllAnchors() end
        local optionH = math.max(24, h)
        local count = math.max(1, math.min(self.maxVisible, #self.items))
        local scrollW = (#self.items > self.maxVisible) and 26 or 0
        local context = S.Layout:GetContext()
        local desiredPopupW = math.max(w, tonumber(popupWidth) or tonumber(self.popupWidth) or w)
        local popupW = math.min(desiredPopupW, math.max(w, context.usableWidth - 8 * context.addonScale))
        local popupH = count * optionH
        self.popupWidth = popupW
        self.popup:SetExtent(popupW, popupH)
        local openAbove = false
        if S.Layout ~= nil and type(S.Layout.GetLogicalRect) == "function" then
            local _, triggerY, _, triggerH = S.Layout:GetLogicalRect(self.trigger)
            local bottom = context.logicalHeight - context.safeBottom
            local top = context.safeTop
            openAbove = (triggerY + triggerH + popupH + 4 > bottom) and (triggerY - popupH - 4 >= top)
        end
        if openAbove then
            self.popup:AddAnchor("BOTTOMLEFT", self.trigger, "TOPLEFT", 0, -2)
        else
            self.popup:AddAnchor("TOPLEFT", self.trigger, "BOTTOMLEFT", 0, 2)
        end
        for i = 1, self.maxVisible do
            local b = self.optionButtons[i]
            b:SetExtent(popupW - scrollW, optionH)
            S.UI:SetAnchor(b, self.popup, 0, (i - 1) * optionH)
        end
        self.up:SetExtent(scrollW > 0 and scrollW or 1, optionH)
        self.down:SetExtent(scrollW > 0 and scrollW or 1, optionH)
        S.UI:SetAnchor(self.up, self.popup, popupW - scrollW, 0)
        S.UI:SetAnchor(self.down, self.popup, popupW - scrollW, math.max(0, count * optionH - optionH))
        RefreshButtons()
        -- Popup is parented to UIParent; on compact resolutions a trigger near
        -- the right/bottom edge can otherwise open the list outside CryEngine's
        -- current TOPLEFT crop.  Clamp presentation only; no user setting is
        -- persisted for transient dropdowns.
        if self.popup:IsVisible() then
            if S.Layout ~= nil and type(S.Layout.EnsureWidgetVisible) == "function" then
                S.Layout:EnsureWidgetVisible(self.popup, { onlyWhenVisible = true, edge = S.Constants.SafeArea })
            elseif self.popup.CorrectOffsetByScreen ~= nil then
                pcall(function() self.popup:CorrectOffsetByScreen() end)
            end
            if self.popup.Raise ~= nil then self.popup:Raise() end
        end
    end

    for i = 1, dd.maxVisible do
        local button = S.UI:CreateButton(popup, id .. "_option_" .. i, "", 0, 0, width or 180, height or 26, 10, false, true)
        if button.style and button.style.SetAlign then pcall(function() button.style:SetAlign(ALIGN_LEFT) end) end
        dd.optionButtons[i] = button
        S.UI:SafeHandler(button, "OnClick", function()
            local itemIndex = button.rsItemIndex
            local item = itemIndex and dd.items[itemIndex] or nil
            if item == nil or item.selectable == false or item.kind == "header" or button.rsDropdownSelectable == false then return end
            dd.selectedIndex = itemIndex
            dd.selectedValue = item.value
            dd:RefreshText()
            Close()
            if type(dd.onSelect) == "function" then dd.onSelect(item) end
        end, id .. ":option:" .. i)
    end

    S.UI:SafeHandler(dd.trigger, "OnClick", function()
        local opening = not popup:IsVisible()
        if opening then
            S.Dropdown:CloseAll()
            popup:Show(true)
            if popup.SetDrawPriority ~= nil then pcall(function() popup:SetDrawPriority(10000) end) end
            local last = dd.lastLayout or { x = 0, y = 0, w = width or 180, h = height or 26 }
            dd:ApplyLayout(last.x, last.y, last.w, last.h, last.popupWidth)
            if popup.Raise ~= nil then popup:Raise() end
        else
            popup:Show(false)
        end
        RefreshButtons()
    end, id .. ":trigger")
    S.UI:SafeHandler(dd.up, "OnClick", function()
        dd.scrollOffset = math.max(0, dd.scrollOffset - 1)
        RefreshButtons()
    end, id .. ":up")
    S.UI:SafeHandler(dd.down, "OnClick", function()
        dd.scrollOffset = math.min(math.max(0, #dd.items - dd.maxVisible), dd.scrollOffset + 1)
        RefreshButtons()
    end, id .. ":down")
    if popup.SetHandler ~= nil then
        S.UI:SafeHandler(popup, "OnWheelUp", function() dd.scrollOffset = math.max(0, dd.scrollOffset - 1); RefreshButtons() end, id .. ":wheel_up")
        S.UI:SafeHandler(popup, "OnWheelDown", function() dd.scrollOffset = math.min(math.max(0, #dd.items - dd.maxVisible), dd.scrollOffset + 1); RefreshButtons() end, id .. ":wheel_down")
    end

    if S.Visual ~= nil and S.Visual.Surface ~= nil then
        S.Visual.Surface:Apply(dd.trigger, { surface = "cardRaised", borderTone = "cyanSoft", topAccent = false })
        S.Visual.Surface:Apply(dd.popup, { surface = "sidebar", borderTone = "goldSoft", topAccent = true, accentHeight = 2 })
    end
    dd:ApplyLayout(0, 0, width, height)
    self.instances[#self.instances + 1] = dd
    return dd
end

function S.Dropdown:CloseAll()
    for _, dd in ipairs(self.instances or {}) do
        if type(dd) == "table" and type(dd.Close) == "function" then pcall(dd.Close) end
    end
end
