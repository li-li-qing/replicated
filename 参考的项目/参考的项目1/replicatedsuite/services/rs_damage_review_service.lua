------------------------------------------------------------------------
-- Replicated Suite - Damage Review Service
-- Team Utility owned incoming-damage/death review. Independent from DPS.
-- Uses a dedicated low-allocation COMBAT_MSG listener and Suite OnUpdate clock.
------------------------------------------------------------------------

if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local U = S.Utils
S.Services = S.Services or {}
S.Services.DamageReview = S.Services.DamageReview or {}
local R = S.Services.DamageReview

R.schemaVersion = 1
R.incoming = type(R.incoming) == "table" and R.incoming or {}
R.debuffSamples = type(R.debuffSamples) == "table" and R.debuffSamples or {}
R.history = {}
R.historyDirty = false
R.historyDirtyAt = 0
R.lastIncomingDamageAt = 0
R.debuffElapsed = 0
R.visibilityElapsed = 0
R.selectedHistoryIndex = 0
R.serial = math.max(0, math.floor(tonumber(R.serial) or 0))
R.autoDismissedSerial = nil
R.windows = R.windows or {}
R.controls = R.controls or {}

local DEBUFF_SAMPLE_INTERVAL_MS = 150
local MAX_INCOMING_EVENTS = 96
local MAX_DEBUFF_SAMPLES = 8
local MAX_DEBUFFS_PER_SAMPLE = 10
local AUTO_ROWS = 8
local HISTORY_ROWS = 12
local AUTO_W = 448
local AUTO_H = 332
local HISTORY_W = 676
local HISTORY_H = 442

local function Config()
    return S.State and S.State.settings or {}
end

local function NowMs()
    return S.NowMs ~= nil and S.NowMs() or 0
end

local function FormatInteger(value)
    local n = tonumber(value) or 0
    local absN = math.abs(n)
    if absN >= 1000000000 then return string.format("%.2fB", n / 1000000000) end
    if absN >= 1000000 then return string.format("%.2fM", n / 1000000) end
    if absN >= 1000 then return string.format("%.1fK", n / 1000) end
    return string.format("%d", math.floor(n + 0.5))
end

local function ReadPlayerName()
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return nil end
    local ok, value = S.Api:CallCapability("X2Unit:UnitName", X2Unit, "UnitName", "player")
    if ok ~= true or value == nil or tostring(value) == "" then return nil end
    return tostring(value)
end

local function ReadPlayerNameWithWorld()
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return nil end
    local ok, value = S.Api:CallCapability("X2Unit:UnitNameWithWorld", X2Unit, "UnitNameWithWorld", "player")
    if ok ~= true or value == nil or tostring(value) == "" then return nil end
    return tostring(value)
end

local function RefreshPlayerIdentity()
    R.playerName = ReadPlayerName() or R.playerName
    R.playerNameWithWorld = ReadPlayerNameWithWorld() or R.playerNameWithWorld
end

local function IsSelfName(name)
    if name == nil then return false end
    return name == R.playerName or name == R.playerNameWithWorld
end

local function IsEnvironmentalEventType(upper)
    return string.find(upper, "ENVIRONMENTAL_DAMAGE", 1, true) ~= nil
        or string.find(upper, "ENVIRONMENTAL_DMANAGE", 1, true) ~= nil
end

local function ParseDamage(eventType, abilityId, damageType, effectType)
    local upper = string.upper(tostring(eventType or ""))
    if string.find(upper, "MELEE_DAMAGE", 1, true) ~= nil then
        return math.abs(tonumber(abilityId) or 0), "DAMAGE", false
    end
    if string.find(upper, "SPELL_DAMAGE", 1, true) ~= nil then
        return math.abs(tonumber(effectType) or 0), "DAMAGE", false
    end
    if IsEnvironmentalEventType(upper) then
        return math.abs(tonumber(damageType) or 0), "DAMAGE", true
    end
    return 0, "OTHER", false
end

local function GetContentMainScriptPosVis(contentId)
    if ADDON == nil or type(ADDON.GetContentMainScriptPosVis) ~= "function" then return false end
    return pcall(ADDON.GetContentMainScriptPosVis, ADDON, contentId)
end

local function GetPlayerDebuffCount()
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return 0 end
    local ok, value = S.Api:CallCapability("X2Unit:UnitDeBuffCount", X2Unit, "UnitDeBuffCount", "player")
    return ok == true and math.max(0, math.floor(tonumber(value) or 0)) or 0
end

local function GetPlayerDebuffTooltip(index)
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return nil end
    local ok, value = S.Api:CallCapability("X2Unit:UnitDeBuffTooltip", X2Unit, "UnitDeBuffTooltip", "player", index)
    return ok == true and value or nil
end

local function GetPlayerDebuffEntry(index)
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return nil end
    local ok, value = S.Api:CallCapability("X2Unit:UnitDeBuff", X2Unit, "UnitDeBuff", "player", index)
    return ok == true and value or nil
end

local function ClampInt(value, minimum, maximum, fallback)
    local n = math.floor(tonumber(value) or fallback or minimum)
    if n < minimum then n = minimum end
    if n > maximum then n = maximum end
    return n
end

local function NormalizeText(value, fallback)
    local text = U.Trim(tostring(value or ""))
    return text ~= "" and text or tostring(fallback or "")
end

local function CurrentClockText()
    if UIParent ~= nil and type(UIParent.GetServerTimeTable) == "function" then
        local ok, value = pcall(function() return UIParent:GetServerTimeTable() end)
        if ok and type(value) == "table" then
            return string.format("%02d:%02d:%02d",
                tonumber(value.hour) or 0,
                tonumber(value.minute) or 0,
                tonumber(value.second) or 0)
        end
    end
    return "--:--:--"
end

local function FormatAmount(value)
    local amount = math.max(0, math.floor((tonumber(value) or 0) + 0.5))
    return FormatInteger(amount)
end

local function CreateBackground(parent, r, g, b, a, layer)
    local bg = parent:CreateColorDrawable(r, g, b, a, layer or "background")
    bg:AddAnchor("TOPLEFT", parent, 0, 0)
    bg:AddAnchor("BOTTOMRIGHT", parent, 0, 0)
    return bg
end

local function CreateSection(parent, id, x, y, width, height, fill)
    local panel = parent:CreateChildWidget("emptywidget", S.PhysicalId(id), 0, true)
    panel:AddAnchor("TOPLEFT", parent, x or 0, y or 0)
    panel:SetExtent(math.max(1, width or 1), math.max(1, height or 1))
    if panel.EnablePick ~= nil then panel:EnablePick(false) end
    if panel.Clickable ~= nil then panel:Clickable(false) end
    local color = type(fill) == "table" and fill or { 0.055, 0.085, 0.125, 0.72 }
    local bg = panel:CreateColorDrawable(color[1], color[2], color[3], color[4], "background")
    if bg ~= nil then
        bg:AddAnchor("TOPLEFT", panel, 0, 0)
        bg:AddAnchor("BOTTOMRIGHT", panel, 0, 0)
    end
    local borderTop = panel:CreateColorDrawable(0.30, 0.47, 0.62, 0.45, "overlay")
    if borderTop ~= nil then
        borderTop:AddAnchor("TOPLEFT", panel, 0, 0)
        borderTop:SetExtent(math.max(1, width or 1), 1)
    end
    panel:Show(true)
    return panel
end

local function CreateDivider(parent, id, x, y, width)
    local divider = parent:CreateChildWidget("emptywidget", S.PhysicalId(id), 0, true)
    divider:AddAnchor("TOPLEFT", parent, x or 0, y or 0)
    divider:SetExtent(math.max(1, width or 1), 1)
    if divider.EnablePick ~= nil then divider:EnablePick(false) end
    if divider.Clickable ~= nil then divider:Clickable(false) end
    local line = divider:CreateColorDrawable(0.26, 0.40, 0.54, 0.55, "background")
    if line ~= nil then
        line:AddAnchor("TOPLEFT", divider, 0, 0)
        line:AddAnchor("BOTTOMRIGHT", divider, 0, 0)
    end
    divider:Show(true)
    return divider
end

local function CreateLabel(parent, id, text, x, y, width, height, fontSize, align)
    local label = parent:CreateChildWidget("label", S.PhysicalId(id), 0, true)
    label:AddAnchor("TOPLEFT", parent, x or 0, y or 0)
    if label.SetAutoResize ~= nil then label:SetAutoResize(false) end
    label:SetExtent(math.max(1, width or 1), math.max(1, height or 1))
    if label.EnablePick ~= nil then label:EnablePick(false) end
    if label.Clickable ~= nil then label:Clickable(false) end
    label.style:SetFontSize(fontSize or 10)
    label.style:SetAlign(align or ALIGN_LEFT)
    label.style:SetColor(1, 1, 1, 1)
    if label.style.SetOutline ~= nil then label.style:SetOutline(true) end
    if label.style.SetEllipsis ~= nil then pcall(function() label.style:SetEllipsis(false) end) end
    label:SetText(tostring(text or ""))
    label:Show(true)
    return label
end

local function CreateButton(parent, id, text, x, y, width, height, fontSize)
    local button = parent:CreateChildWidget("button", S.PhysicalId(id), 0, true)
    button:AddAnchor("TOPLEFT", parent, x or 0, y or 0)
    button:SetExtent(width or 70, height or 24)
    button:SetText(tostring(text or ""))
    if button.SetAutoResize ~= nil then button:SetAutoResize(false) end
    button.rsDamageReviewButtonBgs = button.rsDamageReviewButtonBgs or {}
    if button.rsDamageReviewButtonBgs[1] == nil then
        local colors = {
            { 0.14, 0.21, 0.29, 0.96 },
            { 0.22, 0.34, 0.46, 0.98 },
            { 0.08, 0.13, 0.19, 0.98 },
            { 0.08, 0.09, 0.11, 0.70 },
        }
        for i = 1, 4 do
            local c = colors[i]
            local bg = button:CreateColorDrawable(c[1], c[2], c[3], c[4], "background")
            if bg ~= nil then
                bg:AddAnchor("TOPLEFT", button, 0, 0)
                bg:AddAnchor("BOTTOMRIGHT", button, 0, 0)
            end
            button.rsDamageReviewButtonBgs[i] = bg
        end
        if button.SetNormalBackground ~= nil then
            button:SetNormalBackground(button.rsDamageReviewButtonBgs[1])
            button:SetHighlightBackground(button.rsDamageReviewButtonBgs[2])
            button:SetPushedBackground(button.rsDamageReviewButtonBgs[3])
            button:SetDisabledBackground(button.rsDamageReviewButtonBgs[4])
        elseif button.SetStyle ~= nil then
            pcall(function() button:SetStyle("text_default") end)
        end
    end
    if button.style ~= nil then
        button.style:SetFontSize(fontSize or 10)
        if button.style.SetEllipsis ~= nil then pcall(function() button.style:SetEllipsis(false) end) end
        if button.style.SetColor ~= nil then button.style:SetColor(0.96, 0.92, 0.82, 1) end
        if button.style.SetOutline ~= nil then button.style:SetOutline(true) end
    end
    if button.Enable ~= nil then button:Enable(true) end
    if button.Clickable ~= nil then button:Clickable(true) end
    button:Show(true)
    return button
end

local function CreateRoot(id, width, height)
    local window = CreateEmptyWindow(S.PhysicalId(id), "UIParent")
    window:SetExtent(width, height)
    if window.SetUILayer ~= nil then pcall(function() window:SetUILayer("system") end) end
    if window.SetCloseOnEscape ~= nil then pcall(function() window:SetCloseOnEscape(true) end) end
    if window.Enable ~= nil then window:Enable(true) end
    if window.Clickable ~= nil then window:Clickable(true) end
    CreateBackground(window, 0.025, 0.035, 0.052, 0.94)
    CreateSection(window, id .. "_header", 0, 0, width, 30, { 0.055, 0.095, 0.145, 0.88 })
    CreateDivider(window, id .. "_footer_divider", 0, height - 1, width)
    window:Show(false)
    return window
end

local function SafeSetHandler(widget, eventName, fn)
    if widget == nil or type(widget.SetHandler) ~= "function" then return end
    widget:SetHandler(eventName, function(...)
        local args = { ... }
        local argCount = select("#", ...)
        local ok, result = xpcall(function() return fn(unpack(args, 1, argCount)) end, S.SafeTraceback)
        if not ok and S.RecordLog ~= nil then
            S.RecordLog("error", "damage_review_ui", tostring(result))
        end
        return ok and result or nil
    end)
end

local function CreateDebuffSlots(parent, prefix, y, width)
    local slots = {}
    local size = 26
    local gap = 4
    local maxVisible = math.max(1, math.min(MAX_DEBUFFS_PER_SAMPLE, math.floor((width - 20) / (size + gap))))
    for index = 1, maxVisible do
        local slot = parent:CreateChildWidget("emptywidget", S.PhysicalId(prefix .. "_debuff_" .. tostring(index)), index, true)
        slot:SetExtent(size, size)
        slot:AddAnchor("TOPLEFT", parent, 10 + (index - 1) * (size + gap), y)
        if slot.Enable ~= nil then slot:Enable(true) end
        if slot.EnablePick ~= nil then slot:EnablePick(true, true) end
        if slot.Clickable ~= nil then slot:Clickable(true, true) end
        local icon = nil
        if type(slot.CreateIconDrawable) == "function" then
            local ok, result = pcall(function() return slot:CreateIconDrawable("artwork") end)
            if ok then icon = result end
        end
        if icon ~= nil then
            icon:SetExtent(size, size)
            icon:AddAnchor("TOPLEFT", slot, 0, 0)
            icon:SetVisible(false)
        end
        local stack = CreateLabel(slot, prefix .. "_debuff_stack_" .. tostring(index), "", 13, 12, 12, 12, 8, ALIGN_RIGHT)
        stack.style:SetColor(1.0, 0.9, 0.35, 1)
        slot.icon = icon
        slot.stack = stack
        slot.debuff = nil
        slot:Show(false)
        slots[index] = slot
    end
    return slots
end

local function RenderDebuffs(slots, detailLabel, debuffs)
    debuffs = type(debuffs) == "table" and debuffs or {}
    for index, slot in ipairs(slots or {}) do
        local debuff = debuffs[index]
        slot.debuff = debuff
        if type(debuff) == "table" then
            if slot.icon ~= nil then
                slot.icon:ClearAllTextures()
                if type(debuff.path) == "string" and debuff.path ~= "" then
                    slot.icon:AddTexture(debuff.path)
                    slot.icon:SetVisible(true)
                else
                    slot.icon:SetVisible(false)
                end
            end
            slot.stack:SetText((tonumber(debuff.stack) or 0) > 1 and tostring(debuff.stack) or "")
            slot:Show(true)
        else
            if slot.icon ~= nil then
                slot.icon:ClearAllTextures()
                slot.icon:SetVisible(false)
            end
            slot.stack:SetText("")
            slot:Show(false)
        end
    end
    if detailLabel ~= nil then detailLabel:SetText(#debuffs > 0 and "点击图标查看 Debuff 名称" or "死亡时未记录到 Debuff") end
end

local function BindDebuffClicks(slots, detailLabel)
    for _, slot in ipairs(slots or {}) do
        SafeSetHandler(slot, "OnClick", function(self)
            local debuff = self.debuff
            if detailLabel ~= nil and type(debuff) == "table" then
                local stackText = (tonumber(debuff.stack) or 0) > 1 and (" x" .. tostring(debuff.stack)) or ""
                detailLabel:SetText(NormalizeText(debuff.name, "未知 Debuff") .. stackText)
            end
        end)
    end
end

function R:EnsureAutoPanel()
    if self.windows.auto ~= nil then return self.windows.auto end
    local w = CreateRoot("rs_damage_review_review_auto", AUTO_W, AUTO_H)
    self.windows.auto = w
    self.controls.autoTitle = CreateLabel(w, "rs_damage_review_auto_title", "伤害回顾", 12, 6, 280, 18, 14, ALIGN_LEFT)
    if self.controls.autoTitle.style ~= nil then self.controls.autoTitle.style:SetColor(0.98, 0.93, 0.82, 1) end
    self.controls.autoClock = CreateLabel(w, "rs_damage_review_auto_clock", "", AUTO_W - 128, 8, 78, 16, 10, ALIGN_RIGHT)
    if self.controls.autoClock.style ~= nil then self.controls.autoClock.style:SetColor(0.76, 0.84, 0.96, 1) end
    self.controls.autoClose = CreateButton(w, "rs_damage_review_auto_close", "关闭", AUTO_W - 52, 4, 40, 22, 9)

    CreateSection(w, "rs_damage_review_auto_summary_box", 10, 38, AUTO_W - 20, 48)
    self.controls.autoSummary = CreateLabel(w, "rs_damage_review_auto_summary", "", 18, 46, AUTO_W - 36, 34, 10, ALIGN_LEFT)

    CreateSection(w, "rs_damage_review_auto_timeline_box", 10, 96, AUTO_W - 20, 126)
    self.controls.autoTimelineTitle = CreateLabel(w, "rs_damage_review_auto_timeline_title", "死亡前伤害时间线", 18, 102, 180, 16, 11, ALIGN_LEFT)
    if self.controls.autoTimelineTitle.style ~= nil then self.controls.autoTimelineTitle.style:SetColor(0.95, 0.90, 0.78, 1) end
    self.controls.autoRows = {}
    for index = 1, AUTO_ROWS do
        self.controls.autoRows[index] = CreateLabel(w, "rs_damage_review_auto_row_" .. tostring(index), "",
            18, 122 + (index - 1) * 12, AUTO_W - 36, 12, 9, ALIGN_LEFT)
    end

    CreateSection(w, "rs_damage_review_auto_debuff_box", 10, 232, AUTO_W - 20, 88)
    self.controls.autoDebuffTitle = CreateLabel(w, "rs_damage_review_auto_debuff_title", "死亡时 Debuff", 18, 238, 160, 16, 11, ALIGN_LEFT)
    if self.controls.autoDebuffTitle.style ~= nil then self.controls.autoDebuffTitle.style:SetColor(0.95, 0.90, 0.78, 1) end
    self.controls.autoDebuffDetail = CreateLabel(w, "rs_damage_review_auto_debuff_detail", "", 18, 294, AUTO_W - 36, 16, 9, ALIGN_LEFT)
    if self.controls.autoDebuffDetail.style ~= nil then self.controls.autoDebuffDetail.style:SetColor(0.80, 0.86, 0.95, 1) end
    self.controls.autoDebuffs = CreateDebuffSlots(w, "rs_damage_review_auto", 260, AUTO_W)
    BindDebuffClicks(self.controls.autoDebuffs, self.controls.autoDebuffDetail)
    SafeSetHandler(self.controls.autoClose, "OnClick", function()
        local latest = self.history[#self.history]
        self.autoDismissedSerial = latest and latest.serial or self.serial
        self.autoPendingSerial = nil
        self.autoPendingUntil = nil
        w:Show(false)
    end)
    return w
end

function R:EnsureHistoryWindow()
    if self.windows.history ~= nil then return self.windows.history end
    local w = CreateRoot("rs_damage_review_review_history", HISTORY_W, HISTORY_H)
    self.windows.history = w
    self.controls.historyTitle = CreateLabel(w, "rs_damage_review_history_title", "伤害回顾历史", 12, 6, 300, 18, 14, ALIGN_LEFT)
    if self.controls.historyTitle.style ~= nil then self.controls.historyTitle.style:SetColor(0.98, 0.93, 0.82, 1) end
    self.controls.historyPage = CreateLabel(w, "rs_damage_review_history_page", "0/0", 320, 8, 90, 16, 10, ALIGN_CENTER)
    if self.controls.historyPage.style ~= nil then self.controls.historyPage.style:SetColor(0.76, 0.84, 0.96, 1) end
    self.controls.historyPrev = CreateButton(w, "rs_damage_review_history_prev", "上一条", HISTORY_W - 174, 4, 56, 22, 9)
    self.controls.historyNext = CreateButton(w, "rs_damage_review_history_next", "下一条", HISTORY_W - 114, 4, 56, 22, 9)
    self.controls.historyClose = CreateButton(w, "rs_damage_review_history_close", "关闭", HISTORY_W - 54, 4, 40, 22, 9)

    CreateSection(w, "rs_damage_review_history_summary_box", 12, 38, HISTORY_W - 24, 48)
    self.controls.historySummary = CreateLabel(w, "rs_damage_review_history_summary", "", 20, 46, HISTORY_W - 40, 34, 10, ALIGN_LEFT)

    CreateSection(w, "rs_damage_review_history_timeline_box", 12, 96, HISTORY_W - 24, 222)
    self.controls.historyTimelineTitle = CreateLabel(w, "rs_damage_review_history_timeline_title", "死亡前伤害时间线", 20, 102, 180, 16, 11, ALIGN_LEFT)
    if self.controls.historyTimelineTitle.style ~= nil then self.controls.historyTimelineTitle.style:SetColor(0.95, 0.90, 0.78, 1) end
    self.controls.historyRows = {}
    for index = 1, HISTORY_ROWS do
        self.controls.historyRows[index] = CreateLabel(w, "rs_damage_review_history_row_" .. tostring(index), "",
            20, 122 + (index - 1) * 15, HISTORY_W - 40, 14, 9, ALIGN_LEFT)
    end

    CreateSection(w, "rs_damage_review_history_debuff_box", 12, 328, HISTORY_W - 24, 102)
    self.controls.historyDebuffTitle = CreateLabel(w, "rs_damage_review_history_debuff_title", "死亡时 Debuff", 20, 334, 160, 16, 11, ALIGN_LEFT)
    if self.controls.historyDebuffTitle.style ~= nil then self.controls.historyDebuffTitle.style:SetColor(0.95, 0.90, 0.78, 1) end
    self.controls.historyDebuffDetail = CreateLabel(w, "rs_damage_review_history_debuff_detail", "", 20, 404, HISTORY_W - 40, 16, 9, ALIGN_LEFT)
    if self.controls.historyDebuffDetail.style ~= nil then self.controls.historyDebuffDetail.style:SetColor(0.80, 0.86, 0.95, 1) end
    self.controls.historyDebuffs = CreateDebuffSlots(w, "rs_damage_review_history", 360, HISTORY_W)
    BindDebuffClicks(self.controls.historyDebuffs, self.controls.historyDebuffDetail)
    SafeSetHandler(self.controls.historyClose, "OnClick", function() w:Show(false) end)
    SafeSetHandler(self.controls.historyPrev, "OnClick", function()
        if #self.history == 0 then return end
        self.selectedHistoryIndex = math.max(1, (tonumber(self.selectedHistoryIndex) or #self.history) - 1)
        self:RenderHistory()
    end)
    SafeSetHandler(self.controls.historyNext, "OnClick", function()
        if #self.history == 0 then return end
        self.selectedHistoryIndex = math.min(#self.history, (tonumber(self.selectedHistoryIndex) or #self.history) + 1)
        self:RenderHistory()
    end)
    return w
end

local function FormatDamageLine(record, event, deathAt)
    local ago = math.max(0, (tonumber(deathAt) or 0) - (tonumber(event.time) or 0)) / 1000
    local source = NormalizeText(event.source, "未知来源")
    local ability = NormalizeText(event.ability, "普通攻击")
    return string.format("%4.1f秒前  %s / %s  -%s", ago, source, ability, FormatAmount(event.amount))
end

local function RenderRecord(rows, summary, debuffSlots, debuffDetail, record, rowLimit)
    if type(record) ~= "table" then
        if summary ~= nil then summary:SetText("暂无死亡记录") end
        for _, row in ipairs(rows or {}) do row:SetText("") end
        RenderDebuffs(debuffSlots, debuffDetail, {})
        return
    end
    local events = type(record.events) == "table" and record.events or {}
    local lethal = type(record.lethal) == "table" and record.lethal or nil
    local lethalText = lethal ~= nil
        and (NormalizeText(lethal.source, "未知") .. " / " .. NormalizeText(lethal.ability, "普通攻击") .. " -" .. FormatAmount(lethal.amount))
        or "无可用致死事件"
    if summary ~= nil then
        summary:SetText("时间 " .. tostring(record.clock or "--:--:--")
            .. "  ·  窗口承伤 " .. FormatAmount(record.totalDamage)
            .. "\n最后一击 " .. lethalText)
    end
    local shown = math.min(rowLimit or #rows, #events)
    for rowIndex, row in ipairs(rows or {}) do
        local sourceIndex = #events - rowIndex + 1
        if rowIndex <= shown and sourceIndex >= 1 then
            row:SetText(FormatDamageLine(record, events[sourceIndex], record.time))
        elseif rowIndex == shown + 1 and #events > shown then
            row:SetText("…… 另有 " .. tostring(#events - shown) .. " 条较早伤害")
        else
            row:SetText("")
        end
    end
    RenderDebuffs(debuffSlots, debuffDetail, record.debuffs)
end

function R:RenderAuto()
    local w = self:EnsureAutoPanel()
    local record = self.history[#self.history]
    if record == nil then w:Show(false); return end
    self.controls.autoTitle:SetText("伤害回顾")
    if self.controls.autoClock ~= nil then self.controls.autoClock:SetText(tostring(record.clock or "--:--:--")) end
    RenderRecord(self.controls.autoRows, self.controls.autoSummary,
        self.controls.autoDebuffs, self.controls.autoDebuffDetail, record, AUTO_ROWS)
end

function R:RenderHistory()
    self:EnsureHistoryWindow()
    local count = #self.history
    if count == 0 then
        self.selectedHistoryIndex = 0
        self.controls.historyPage:SetText("0/0")
        self.controls.historyTitle:SetText("伤害回顾历史")
        RenderRecord(self.controls.historyRows, self.controls.historySummary,
            self.controls.historyDebuffs, self.controls.historyDebuffDetail, nil, HISTORY_ROWS)
        return
    end
    self.selectedHistoryIndex = ClampInt(self.selectedHistoryIndex, 1, count, count)
    local record = self.history[self.selectedHistoryIndex]
    self.controls.historyPage:SetText(tostring(self.selectedHistoryIndex) .. "/" .. tostring(count) .. "  ·  " .. tostring(record.clock or "--:--:--"))
    self.controls.historyTitle:SetText("伤害回顾历史")
    RenderRecord(self.controls.historyRows, self.controls.historySummary,
        self.controls.historyDebuffs, self.controls.historyDebuffDetail, record, HISTORY_ROWS)
end

local function CurrentLogicalScreenExtent()
    if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
        and type(ReplicatedSuite.Layout.GetContext) == "function" then
        local ok, context = pcall(function() return ReplicatedSuite.Layout:GetContext() end)
        if ok and type(context) == "table" then
            return math.max(1, tonumber(context.logicalWidth) or 1024), math.max(1, tonumber(context.logicalHeight) or 768)
        end
    end
    if UIParent ~= nil and type(UIParent.GetExtent) == "function" then
        local ok, width, height = pcall(function() return UIParent:GetExtent() end)
        if ok and tonumber(width) and tonumber(height) then return tonumber(width), tonumber(height) end
    end
    return 1024, 768
end

function R:OpenHistory()
    local w = self:EnsureHistoryWindow()
    self.selectedHistoryIndex = #self.history
    self:RenderHistory()
    local screenW, screenH = CurrentLogicalScreenExtent()
    w:RemoveAllAnchors()
    w:AddAnchor("TOPLEFT", "UIParent", math.max(0, math.floor((screenW - HISTORY_W) / 2)), math.max(0, math.floor((screenH - HISTORY_H) / 2)))
    w:Show(true)
    if w.Raise ~= nil then w:Raise() end
end

function R:ToggleHistory()
    local w = self:EnsureHistoryWindow()
    if w:IsVisible() then w:Show(false) else self:OpenHistory() end
end

function R:PositionAutoPanel()
    local w = self:EnsureAutoPanel()
    local positioned = false
    if UIC_DEATH_AND_RESURRECTION_WND ~= nil then
        local ok, x, y, width, _, visible = GetContentMainScriptPosVis(UIC_DEATH_AND_RESURRECTION_WND)
        if ok and visible == true and tonumber(x) ~= nil and tonumber(y) ~= nil and tonumber(width) ~= nil then
            local screenW = CurrentLogicalScreenExtent()
            local px = tonumber(x) + tonumber(width) + 8
            local py = tonumber(y)
            if px + AUTO_W > screenW then px = tonumber(x) - AUTO_W - 8 end
            if px < 0 then px = 0 end
            w:RemoveAllAnchors()
            local _, screenH = CurrentLogicalScreenExtent()
            py = math.max(0, math.min(tonumber(py) or 0, math.max(0, screenH - AUTO_H)))
            w:AddAnchor("TOPLEFT", "UIParent", px, py)
            positioned = true
        end
    end
    if not positioned then
        local screenW, screenH = CurrentLogicalScreenExtent()
        w:RemoveAllAnchors()
        w:AddAnchor("TOPLEFT", "UIParent", math.max(0, math.floor((screenW - AUTO_W) / 2)), math.max(0, math.floor((screenH - AUTO_H) / 2)))
    end
    return positioned
end

function R:PruneIncoming(now)
    local cfg = Config()
    local keepMs = math.max(15000, tonumber(cfg.damageReviewWindowMs) or 10000) + 3000
    local cutoff = now - keepMs
    while #self.incoming > 0 and ((tonumber(self.incoming[1].time) or 0) < cutoff or #self.incoming > MAX_INCOMING_EVENTS) do
        table.remove(self.incoming, 1)
    end
end

function R:OnCombatMessage(eventType, sourceName, targetName, abilityId, abilityName, damageType, effectType, observedAt)
    local cfg = Config()
    if cfg.damageReviewEnabled ~= true or not IsSelfName(targetName) then return end
    local amount, category, environmental = ParseDamage(eventType, abilityId, damageType, effectType)
    amount = math.max(0, tonumber(amount) or 0)
    if category ~= "DAMAGE" or amount <= 0 or amount < math.max(0, tonumber(cfg.damageReviewMinDamage) or 0) then return end
    local now = tonumber(observedAt) or NowMs()
    local source = environmental == true and "环境" or NormalizeText(sourceName, "未知来源")
    local ability = NormalizeText(abilityName, "普通攻击")
    if ability == "HEALTH" then ability = "普通攻击" end
    if environmental == true then
        local envAbility = NormalizeText(abilityId, "环境伤害")
        if envAbility ~= "" and envAbility ~= "0" and envAbility ~= "-1" then ability = envAbility else ability = "环境伤害" end
    end
    self.incoming[#self.incoming + 1] = {
        time = now,
        source = source,
        ability = ability,
        amount = math.floor(amount + 0.5),
        environmental = environmental == true and true or nil,
    }
    self.lastIncomingDamageAt = now
    self:PruneIncoming(now)
end

function R:CaptureDebuffs(now)
    local debuffs = {}
    local count = math.min(MAX_DEBUFFS_PER_SAMPLE, GetPlayerDebuffCount())
    for index = 1, count do
        local tooltip = GetPlayerDebuffTooltip(index)
        local extra = GetPlayerDebuffEntry(index)
        if type(tooltip) == "table" then
            debuffs[#debuffs + 1] = {
                name = NormalizeText(tooltip.name, "未知 Debuff"),
                path = type(extra) == "table" and extra.path or nil,
                stack = tonumber(tooltip.stack) or 0,
            }
        end
    end
    self.debuffSamples[#self.debuffSamples + 1] = { time = now, debuffs = debuffs }
    while #self.debuffSamples > MAX_DEBUFF_SAMPLES do table.remove(self.debuffSamples, 1) end
end

function R:CopyDeathDebuffs(now)
    local selected = nil
    for _, sample in ipairs(self.debuffSamples) do
        if (tonumber(sample.time) or 0) <= now then selected = sample end
    end
    if selected == nil then selected = self.debuffSamples[#self.debuffSamples] end
    local copy = {}
    if type(selected) == "table" and type(selected.debuffs) == "table" then
        for _, debuff in ipairs(selected.debuffs) do
            copy[#copy + 1] = {
                name = debuff.name,
                path = debuff.path,
                stack = debuff.stack,
            }
        end
    end
    return copy
end

function R:TrimHistory()
    local maximum = ClampInt(Config().damageReviewMaxHistory, 1, 30, 10)
    while #self.history > maximum do table.remove(self.history, 1) end
    if self.selectedHistoryIndex > #self.history then self.selectedHistoryIndex = #self.history end
end

function R:OnDeathNotice(info1)
    local cfg = Config()
    if cfg.damageReviewEnabled ~= true or not IsSelfName(info1) then return end

    -- UNIT_DEAD_NOTICE can arrive a few frames after the actual lethal COMBAT_MSG.
    -- Use the Suite monotonic clock as timing Authority, then anchor the visible
    -- "x.x seconds before death" timeline to the latest incoming hit when that
    -- hit is close enough to the notice to be a credible lethal event. This makes
    -- the lethal skill read 0.0s instead of inheriting event-delivery latency.
    local noticeAt = NowMs()
    local anchorAt = noticeAt
    local latest = self.incoming[#self.incoming]
    local latestAt = latest ~= nil and tonumber(latest.time) or nil
    if latestAt ~= nil and latestAt <= noticeAt + 250 and noticeAt - latestAt <= 2000 then
        anchorAt = latestAt
    end

    local windowMs = ClampInt(cfg.damageReviewWindowMs, 3000, 20000, 10000)
    local cutoff = anchorAt - windowMs
    local events = {}
    local total = 0
    for _, event in ipairs(self.incoming) do
        local eventTime = tonumber(event.time) or 0
        if eventTime >= cutoff and eventTime <= anchorAt + 250 then
            events[#events + 1] = {
                time = eventTime,
                source = event.source,
                ability = event.ability,
                amount = event.amount,
                environmental = event.environmental,
            }
            total = total + (tonumber(event.amount) or 0)
        end
    end
    self.serial = self.serial + 1
    local lethal = events[#events]
    local record = {
        schemaVersion = 1,
        serial = self.serial,
        time = anchorAt,
        noticeTime = noticeAt,
        clock = CurrentClockText(),
        windowMs = windowMs,
        totalDamage = math.floor(total + 0.5),
        lethal = lethal ~= nil and {
            time = lethal.time,
            source = lethal.source,
            ability = lethal.ability,
            amount = lethal.amount,
            environmental = lethal.environmental,
        } or nil,
        events = events,
        debuffs = cfg.damageReviewShowDebuffs == true and self:CopyDeathDebuffs(anchorAt) or {},
    }
    self.history[#self.history + 1] = record
    self:TrimHistory()
    self.selectedHistoryIndex = #self.history
    self.historyDirty = true
    self.historyDirtyAt = noticeAt
    self.autoDismissedSerial = nil
    self.autoPendingSerial = record.serial
    self.autoPendingUntil = noticeAt + 2000
    self.incoming = {}
    self.debuffSamples = {}
    self:RenderAuto()
    if cfg.damageReviewAutoShow == true then
        self:PositionAutoPanel()
        self.windows.auto:Show(true)
        if self.windows.auto.Raise ~= nil then self.windows.auto:Raise() end
    end
    if self.windows.history ~= nil and self.windows.history:IsVisible() then self:RenderHistory() end
end

function R:SaveHistoryNow()
    if self.historyDirty ~= true or S.State == nil then return false end
    S.State.life = type(S.State.life) == "table" and S.State.life or {}
    S.State.life.damageReviewHistory = {
        schemaVersion = 1,
        serial = self.serial,
        entries = U.DeepCopy(self.history),
    }
    self.historyDirty = false
    if S.Storage ~= nil and type(S.Storage.RequestSave) == "function" then S.Storage:RequestSave() end
    return true
end

function R:LoadHistory()
    local payload = S.State ~= nil and type(S.State.life) == "table" and S.State.life.damageReviewHistory or nil
    if type(payload) ~= "table" then return end
    local entries = type(payload.entries) == "table" and payload.entries or {}
    self.history = {}
    for _, record in ipairs(entries) do
        if type(record) == "table" and type(record.events) == "table" then
            self.history[#self.history + 1] = U.DeepCopy(record)
        end
    end
    self.serial = math.max(tonumber(payload.serial) or 0, tonumber(self.serial) or 0)
    self:TrimHistory()
    self.selectedHistoryIndex = #self.history
end

function R:OnUpdate(dt, now, combatActive)
    local cfg = Config()
    dt = tonumber(dt) or 0
    now = NowMs()
    if cfg.damageReviewEnabled == true and cfg.damageReviewShowDebuffs == true then
        self.debuffElapsed = self.debuffElapsed + dt
        local recentDamage = now - (tonumber(self.lastIncomingDamageAt) or 0) <= math.max(3000, tonumber(cfg.damageReviewWindowMs) or 10000)
        if self.debuffElapsed >= DEBUFF_SAMPLE_INTERVAL_MS and (combatActive == true or recentDamage) then
            self.debuffElapsed = 0
            self:CaptureDebuffs(now)
        end
    else
        self.debuffElapsed = 0
        self.debuffSamples = {}
    end

    self.visibilityElapsed = self.visibilityElapsed + dt
    if self.visibilityElapsed >= 250 then
        self.visibilityElapsed = 0
        local auto = self.windows.auto
        local latest = self.history[#self.history]
        if auto ~= nil and auto:IsVisible() and latest ~= nil and self.autoDismissedSerial ~= latest.serial then
            -- Follow the native death window while it is visible. During the
            -- first two seconds keep the centered fallback alive because the
            -- native resurrection window may appear slightly after UNIT_DEAD_NOTICE.
            local visible = false
            if UIC_DEATH_AND_RESURRECTION_WND ~= nil then
                local ok, _, _, _, _, isVisible = GetContentMainScriptPosVis(UIC_DEATH_AND_RESURRECTION_WND)
                visible = ok and isVisible == true
            end
            if visible then
                self.autoPendingSerial = nil
                self.autoPendingUntil = nil
                self:PositionAutoPanel()
            elseif self.autoPendingSerial == latest.serial and now <= (tonumber(self.autoPendingUntil) or 0) then
                -- Keep the one-shot fallback visible; do not issue another Show().
            else
                auto:Show(false)
            end
        end
    end

    if self.historyDirty == true and combatActive ~= true and now - (tonumber(self.historyDirtyAt) or 0) >= 1500 then
        self:SaveHistoryNow()
    end
end

function R:GetStatusLine()
    return "伤害回顾：历史 " .. tostring(#self.history)
        .. " / 缓冲伤害 " .. tostring(#self.incoming)
        .. " / Debuff快照 " .. tostring(#self.debuffSamples)
end

function R:ApplyConfigLimits()
    self:TrimHistory()
    if self.windows.history ~= nil and self.windows.history:IsVisible() then self:RenderHistory() end
end

function R:SetEnabled(enabled)
    local value = enabled == true
    S.State.settings.damageReviewEnabled = value
    if S.Storage ~= nil and type(S.Storage.RequestSave) == "function" then S.Storage:RequestSave() end
    if S.Scheduler ~= nil then
        S.Scheduler:SetEnabled("team_utility_damage_review", self.started == true and value)
    end
    if value then
        RefreshPlayerIdentity()
        self:StartListener()
    else
        self:StopListener()
        self.incoming = {}
        self.debuffSamples = {}
        if self.windows.auto ~= nil then self.windows.auto:Show(false) end
        if self.windows.history ~= nil then self.windows.history:Show(false) end
    end
    return value
end

function R:SetSetting(key, value)
    if key == "damageReviewEnabled" then return self:SetEnabled(value == true) end
    if key == "damageReviewAutoShow" or key == "damageReviewShowDebuffs" then
        S.State.settings[key] = value == true
    elseif key == "damageReviewWindowMs" then
        S.State.settings[key] = ClampInt(value, 3000, 20000, 10000)
    elseif key == "damageReviewMaxHistory" then
        S.State.settings[key] = ClampInt(value, 1, 30, 10)
        self:ApplyConfigLimits()
    elseif key == "damageReviewMinDamage" then
        S.State.settings[key] = ClampInt(value, 0, 5000, 0)
    else
        return false
    end
    if S.Storage ~= nil and type(S.Storage.RequestSave) == "function" then S.Storage:RequestSave() end
    return true
end

function R:StartListener()
    if self.started ~= true or Config().damageReviewEnabled ~= true or self.listenerActive == true then return true end
    RefreshPlayerIdentity()

    local host = self.eventHost
    if host == nil then
        host = CreateEmptyWindow(S.PhysicalId("damage_review_event_host"), "UIParent")
        if host == nil or type(host.SetHandler) ~= "function" or type(host.RegisterEvent) ~= "function" then return false end
        local generation = S.Generation
        local handlerOk = pcall(function()
            host:SetHandler("OnEvent", function(_, eventName, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9, arg10, arg11, arg12, arg13, arg14)
                if R.started ~= true or R.listenerActive ~= true or S.Generation ~= generation then return end
                local label = eventName == "COMBAT_MSG" and "event:damage_review_combat" or "event:damage_review"
                local token = S.PerformanceMonitor and S.PerformanceMonitor:Begin(label, "team_utility") or nil
                if eventName == "COMBAT_MSG" then
                    -- COMBAT_MSG = unitId, eventType, sourceName, targetName, abilityId,
                    -- abilityName, damageType, effectType, ... . The review owns only
                    -- the local-player incoming slice and never allocates a relay table.
                    R:OnCombatMessage(arg2, arg3, arg4, arg5, arg6, arg7, arg8, NowMs())
                elseif eventName == "UNIT_DEAD_NOTICE" then
                    R:OnDeathNotice(arg1, arg2, arg3, arg4)
                elseif eventName == "ENTERED_WORLD" then
                    RefreshPlayerIdentity()
                end
                if S.PerformanceMonitor ~= nil then S.PerformanceMonitor:End(token) end
            end)
            host:Show(false)
        end)
        if handlerOk ~= true then
            pcall(function() host:Show(false) end)
            return false
        end
        self.eventHost = host
    end

    local ok = pcall(function()
        host:RegisterEvent("COMBAT_MSG")
        host:RegisterEvent("UNIT_DEAD_NOTICE")
        host:RegisterEvent("ENTERED_WORLD")
    end)
    if ok ~= true then return false end
    self.listenerActive = true
    return true
end

function R:StopListener()
    local host = self.eventHost
    self.listenerActive = false
    if host == nil then return end
    -- Keep the physical host for the lifetime of this Suite generation. Reusing
    -- it avoids duplicate widget IDs when the user toggles the feature/module
    -- off and back on without a full UI reload.
    if type(host.UnregisterEvent) == "function" then
        pcall(function() host:UnregisterEvent("COMBAT_MSG") end)
        pcall(function() host:UnregisterEvent("UNIT_DEAD_NOTICE") end)
        pcall(function() host:UnregisterEvent("ENTERED_WORLD") end)
    end
    pcall(function() host:Show(false) end)
end

function R:ReconcileCharacterSettings()
    if self.started ~= true then return true end
    self:LoadHistory()
    RefreshPlayerIdentity()
    self:ApplyConfigLimits()
    local enabled = Config().damageReviewEnabled == true
    if S.Scheduler ~= nil then S.Scheduler:SetEnabled("team_utility_damage_review", enabled) end
    if enabled then self:StartListener() else self:StopListener() end
    return true
end

function R:Start()
    if self.started == true then return true end
    self.started = true
    self:LoadHistory()
    RefreshPlayerIdentity()
    if Config().damageReviewEnabled == true then self:StartListener() end
    return true
end

function R:Stop()
    self.started = false
    self:StopListener()
    self:SaveHistoryNow()
    self.incoming = {}
    self.debuffSamples = {}
    if self.windows.auto ~= nil then self.windows.auto:Show(false) end
    if self.windows.history ~= nil then self.windows.history:Show(false) end
end
