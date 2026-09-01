------------------------------------------------------------------------
-- Replicated Suite V3 - Toast Host v1
--
-- One bounded, application-level transient-notification surface. It reuses a
-- fixed three-slot RSUI pool and the single Suite Scheduler; no notification
-- creates a private OnUpdate/Tick and no business Feature owns global chrome.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
if type(RSUI) ~= "table" then return end

S.UIV3 = S.UIV3 or {}
S.UIV3.ToastHost = {
    version = 1,
    owner = "v3:toast_host",
    root = nil,
    stack = nil,
    slots = {},
    entries = {},
    order = {},
    sequence = 0,
    maxVisible = 3,
    maxPending = 12,
    stats = { notifications = 0, dismissals = 0, autoDismissals = 0, dropped = 0 },
}
local T = S.UIV3.ToastHost

local TONES = { default = true, accent = true, muted = true, green = true, red = true, yellow = true, orange = true }
local function NormalizeTone(value)
    value = tostring(value or "default"):lower()
    return TONES[value] and value or "default"
end
local function Clamp(value, minimum, maximum, fallback)
    local n = tonumber(value) or tonumber(fallback) or minimum
    return math.max(minimum, math.min(maximum, n))
end
local function RemoveOrder(id)
    for index = #T.order, 1, -1 do
        if T.order[index] == id then table.remove(T.order, index); return true end
    end
    return false
end

function T:Attach(root)
    if root == nil then return false, "通知宿主缺少根组件" end
    if self.root ~= nil then return self.root == root, self.root == root and nil or "通知宿主已经挂载" end
    self.root = root
    self.stack = RSUI:VerticalBox({
        id = "v3_toast_stack", parent = root, gap = 6,
        slot = { size = "auto", width = 360, hAlign = "right", vAlign = "top", padding = { top = 12, right = 12 } },
    })
    if self.stack == nil then self.root = nil; return false, "通知容器创建失败" end

    for index = 1, self.maxVisible do
        local id = "v3_toast_slot_" .. tostring(index)
        local card = RSUI:Border({ id = id, parent = self.stack, variant = "card", padding = 8,
            slot = { size = "fixed", height = 70, hAlign = "fill" } })
        local body = RSUI:VerticalBox({ id = id .. "_body", parent = card, gap = 3 })
        local header = RSUI:HorizontalBox({ id = id .. "_header", parent = body, gap = 6, slot = { size = "fixed", height = 22, hAlign = "fill" } })
        local title = RSUI:Text({ id = id .. "_title", parent = header, text = "", fontSize = 11, tone = "accent", overflow = "ellipsis", slot = { size = "fill", fill = 1 } })
        local close = RSUI:Button({ id = id .. "_close", parent = header, text = "×", compact = true, slot = { size = "fixed", width = 28 } })
        local detail = RSUI:Text({ id = id .. "_detail", parent = body, text = "", fontSize = 9, tone = "default", overflow = "wrap", maxLines = 2, slot = { size = "auto", hAlign = "fill" } })
        local slot = { index = index, card = card, title = title, detail = detail, close = close, currentId = nil }
        self.slots[index] = slot
        close.onClick = function()
            if slot.currentId == nil then return false end
            return T:Dismiss(slot.currentId, "manual")
        end
        if close.root ~= nil and S.UI ~= nil and type(S.UI.SafeHandler) == "function" then
            S.UI:SafeHandler(close.root, "OnClick", function() return close.onClick() end, "v3_toast:dismiss:" .. tostring(index))
        end
        card:SetVisibility("collapsed")
    end
    return true
end

function T:Render()
    if self.stack == nil then return false end
    for index = 1, self.maxVisible do
        local slot = self.slots[index]
        local orderIndex = #self.order - index + 1
        local id = orderIndex >= 1 and self.order[orderIndex] or nil
        local row = id and self.entries[id] or nil
        if slot ~= nil then
            slot.currentId = row and row.id or nil
            if row ~= nil then
                slot.title:SetText(row.title)
                slot.title:SetTone(row.tone)
                slot.detail:SetText(row.detail)
                slot.detail:SetTone(row.tone == "red" and "red" or "default")
                slot.card:SetVisibility("visible")
            else
                slot.card:SetVisibility("collapsed")
            end
        end
    end
    if type(RSUI.FlushLayoutQueue) == "function" then RSUI:FlushLayoutQueue(12) end
    return true
end

function T:Notify(spec)
    spec = type(spec) == "table" and spec or { detail = tostring(spec or "") }
    local title = tostring(spec.title or "提示")
    local detail = tostring(spec.detail or spec.text or "")
    if detail == "" and title == "" then return nil, "通知内容为空" end
    self.sequence = (tonumber(self.sequence) or 0) + 1
    local id = tostring(spec.id or ("toast_" .. tostring(self.sequence)))
    if self.entries[id] ~= nil then self:Dismiss(id, "replace") end

    while #self.order >= self.maxPending do
        local oldest = self.order[1]
        self:Dismiss(oldest, "capacity")
        self.stats.dropped = (tonumber(self.stats.dropped) or 0) + 1
    end

    local durationMs = math.floor(Clamp(spec.durationMs, 1500, 12000, 3600))
    local taskName = "v3_toast_expire:" .. id
    local row = { id = id, title = title ~= "" and title or "提示", detail = detail, tone = NormalizeTone(spec.tone), taskName = taskName }
    self.entries[id] = row
    self.order[#self.order + 1] = id
    self.stats.notifications = (tonumber(self.stats.notifications) or 0) + 1
    self:Render()

    if S.Scheduler ~= nil and type(S.Scheduler.AddOneShot) == "function" then
        S.Scheduler:AddOneShot(taskName, durationMs, function()
            if T.entries[id] ~= nil then
                T.stats.autoDismissals = (tonumber(T.stats.autoDismissals) or 0) + 1
                T:Dismiss(id, "timeout", true)
            end
        end, self, "P4", 1)
    end
    return id
end

function T:Dismiss(id, reason, taskAlreadyRemoved)
    id = tostring(id or "")
    local row = self.entries[id]
    if row == nil then return false end
    if taskAlreadyRemoved ~= true and S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(row.taskName) end
    self.entries[id] = nil
    RemoveOrder(id)
    self.stats.dismissals = (tonumber(self.stats.dismissals) or 0) + 1
    self.lastDismissReason = tostring(reason or "dismiss")
    self:Render()
    return true
end

function T:Clear(reason)
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveOwner) == "function" then S.Scheduler:RemoveOwner(self) end
    for key in pairs(self.entries) do self.entries[key] = nil end
    for index = #self.order, 1, -1 do self.order[index] = nil end
    self.lastDismissReason = tostring(reason or "clear")
    return self:Render()
end

function T:Describe()
    return {
        version = self.version,
        attached = self.root ~= nil and self.stack ~= nil and #self.slots == self.maxVisible,
        active = #self.order,
        visible = math.min(#self.order, self.maxVisible),
        maxVisible = self.maxVisible,
        maxPending = self.maxPending,
        notifications = tonumber(self.stats.notifications) or 0,
        dismissals = tonumber(self.stats.dismissals) or 0,
        autoDismissals = tonumber(self.stats.autoDismissals) or 0,
        dropped = tonumber(self.stats.dropped) or 0,
    }
end
