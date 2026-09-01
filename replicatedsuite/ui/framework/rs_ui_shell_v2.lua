------------------------------------------------------------------------
-- Replicated Suite - Managed Window Shell v2
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI = S.UI
if type(UI) ~= "table" then return end

local Tokens = S.UITokens or {}
local Shell = { version = 2, metrics = { created = 0, shown = 0, closed = 0, destroyed = 0, layoutPasses = 0 } }
UI.WindowShell = Shell

local function Token(path, fallback)
    if type(Tokens.Number) == "function" then return Tokens:Number(path, fallback) end
    return tonumber(fallback) or 0
end

local function WindowExtent(window, managed)
    local w, h
    if window ~= nil and type(window.GetWidth) == "function" then pcall(function() w = window:GetWidth() end) end
    if window ~= nil and type(window.GetHeight) == "function" then pcall(function() h = window:GetHeight() end) end
    if (tonumber(w) or 0) <= 0 or (tonumber(h) or 0) <= 0 then
        if managed ~= nil and type(managed.GetSize) == "function" then w, h = managed:GetSize() end
    end
    return math.max(1, tonumber(w) or 420), math.max(1, tonumber(h) or 280)
end

function Shell:Create(spec)
    spec = type(spec) == "table" and spec or {}
    if type(UI.WindowManager) ~= "table" or type(UI.WindowManager.Create) ~= "function" then return nil end
    local id = tostring(spec.id or "")
    if id == "" then return nil end
    local managed = UI.WindowManager:Create(spec)
    if managed == nil or managed.window == nil then return nil end
    local window = managed.window
    local owner = window.rsUiOwner or ("dialog:" .. id)
    local titleH = tonumber(spec.titleHeight) or Token("component.window.titleBarH", 32)
    local footerH = spec.footer == false and 0 or (tonumber(spec.footerHeight) or Token("component.window.footerH", 30))
    local padding = tonumber(spec.padding) or Token("component.window.padding", 12)
    local gap = tonumber(spec.gap) or Token("component.window.gap", 8)

    local shell = { id = id, managed = managed, window = window, owner = owner, destroyed = false, footerVisible = footerH > 0 }
    Shell.metrics.created = Shell.metrics.created + 1

    shell.titleBar = UI:CreatePanel(window, id .. "_shell_title", 0, 0, 10, titleH, "header", { gradientKind = "titlebar", accentStrip = true })
    shell.title = UI:CreateLabel(shell.titleBar, id .. "_shell_title_text", tostring(spec.title or id), padding, 3, 220, titleH - 6, tonumber(spec.titleFontSize) or Token("font.title", 15), "default", ALIGN_LEFT, true)
    if spec.closeButton ~= false then shell.close = UI:CreateButton(shell.titleBar, id .. "_shell_close", "×", 0, 3, 28, math.max(20, titleH - 6), 12, false, true) end
    shell.body = UI:CreatePanel(window, id .. "_shell_body", 0, titleH + gap, 10, 10, "card", { gradient = spec.bodyGradient ~= false })
    if footerH > 0 then
        shell.footer = UI:CreatePanel(window, id .. "_shell_footer", 0, 0, 10, footerH, "soft", { gradient = true })
        shell.status = UI:CreateLabel(shell.footer, id .. "_shell_status", tostring(spec.status or ""), padding, 2, 200, footerH - 4, Token("font.small", 10), "muted", ALIGN_LEFT)
    end

    function shell:Layout()
        if self.destroyed then return false end
        local width, height = WindowExtent(window, managed)
        local footerUsed = self.footerVisible and footerH or 0
        local bodyY = titleH + gap
        local bodyH = math.max(1, height - bodyY - padding - (footerUsed > 0 and (footerUsed + gap) or 0))
        UI:SetAnchor(self.titleBar, window, 0, 0, owner); UI:SetExtent(self.titleBar, width, titleH, owner)
        UI:SetExtent(self.title, math.max(1, width - padding * 2 - (self.close and 34 or 0)), titleH - 6, owner)
        if self.close ~= nil then UI:SetAnchor(self.close, self.titleBar, math.max(0, width - 34), 3, owner) end
        UI:SetAnchor(self.body, window, padding, bodyY, owner); UI:SetExtent(self.body, math.max(1, width - padding * 2), bodyH, owner)
        if self.footer ~= nil then
            UI:SetVisible(self.footer, self.footerVisible, owner)
            if self.footerVisible then
                UI:SetAnchor(self.footer, window, padding, height - padding - footerH, owner)
                UI:SetExtent(self.footer, math.max(1, width - padding * 2), footerH, owner)
                if self.status ~= nil then UI:SetExtent(self.status, math.max(1, width - padding * 2), footerH - 4, owner) end
            end
        end
        Shell.metrics.layoutPasses = Shell.metrics.layoutPasses + 1
        return true
    end

    function shell:SetTitle(text) UI:SetText(self.title, tostring(text or ""), owner) end
    function shell:SetStatus(text, tone)
        if self.status == nil then return false end
        UI:SetText(self.status, tostring(text or ""), owner)
        if tone ~= nil then UI:SetLabelTone(self.status, tone, owner) end
        return true
    end
    function shell:SetFooterVisible(visible) self.footerVisible = visible == true; self:Layout(); return self.footerVisible end
    function shell:GetContentRoot() return self.body end
    function shell:Show(visible)
        if self.destroyed then return false end
        self:Layout(); managed:Show(visible == true)
        if visible == true then Shell.metrics.shown = Shell.metrics.shown + 1 end
        return true
    end
    function shell:Close(reason)
        if self.destroyed then return false end
        if type(spec.onClose) == "function" then
            local ok, accepted = xpcall(function() return spec.onClose(reason or "close", self) end, S.SafeTraceback)
            if not ok or accepted == false then return false end
        end
        managed:Show(false); Shell.metrics.closed = Shell.metrics.closed + 1; return true
    end
    function shell:Destroy()
        if self.destroyed then return 0 end
        self.destroyed = true; Shell.metrics.destroyed = Shell.metrics.destroyed + 1
        return managed:Destroy()
    end

    if shell.close ~= nil then UI:SafeHandler(shell.close, "OnClick", function() return shell:Close("button") end, "shell:" .. id .. ":close") end
    managed:BindTitleBar(shell.titleBar)
    shell:Layout()
    return shell
end

function Shell:GetSnapshot()
    return { version = self.version, created = self.metrics.created, shown = self.metrics.shown, closed = self.metrics.closed, destroyed = self.metrics.destroyed, layoutPasses = self.metrics.layoutPasses }
end

function Shell:ResetMetrics()
    self.metrics.created, self.metrics.shown, self.metrics.closed, self.metrics.destroyed, self.metrics.layoutPasses = 0, 0, 0, 0, 0
end

function UI:CreateWindowShell(spec) return Shell:Create(spec) end
