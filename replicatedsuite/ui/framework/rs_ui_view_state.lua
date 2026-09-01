------------------------------------------------------------------------
-- Replicated Suite - RSUI View State v2
--
-- Shared presentation state for data surfaces. Business code owns WHY a view
-- is loading/error/unavailable; this layer owns the consistent visual contract.
-- No Tick/OnUpdate: state changes are explicit and layout piggybacks on the
-- owning DataView's existing layout pass.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
if type(RSUI) ~= "table" then return end

local STATES = {
    loading = true, ready = true, empty = true, error = true, unavailable = true, stale = true,
}
local DEFAULTS = {
    loading = { title = "正在加载…", detail = "请稍候。", tone = "muted", showData = false },
    ready = { title = "", detail = "", tone = "default", showData = true },
    empty = { title = "暂无数据", detail = "当前没有可显示的内容。", tone = "muted", showData = false },
    error = { title = "加载失败", detail = "数据读取失败，可重试。", tone = "red", showData = false },
    unavailable = { title = "当前不可用", detail = "当前客户端或功能状态暂不支持此数据。", tone = "yellow", showData = false },
    stale = { title = "数据可能已过期", detail = "正在等待下一次刷新。", tone = "yellow", showData = true },
}

local function Copy(source)
    local out = {}
    for key, value in pairs(type(source) == "table" and source or {}) do out[key] = value end
    return out
end

local function NormalizeState(value)
    value = tostring(value or "ready"):lower()
    return STATES[value] and value or "ready"
end

local generation = tonumber(S.Generation) or 0
if type(RSUI.ViewState) ~= "table" or tonumber(RSUI.ViewState.generation) ~= generation then
    RSUI.ViewState = {
        version = 2,
        generation = generation,
        metrics = { created = 0, changes = 0, autoEmpty = 0, retries = 0, retryFailures = 0 },
        controllers = setmetatable({}, { __mode = "k" }),
    }
end
local V = RSUI.ViewState
V.version = 2
V.generation = generation
V.metrics = type(V.metrics) == "table" and V.metrics or { created = 0, changes = 0, autoEmpty = 0, retries = 0, retryFailures = 0 }
V.controllers = type(V.controllers) == "table" and V.controllers or setmetatable({}, { __mode = "k" })

function V:Create(view, spec)
    spec = type(spec) == "table" and spec or {}
    if type(view) ~= "table" or view.root == nil then return nil, "view_state_owner_required" end
    self.metrics.created = (tonumber(self.metrics.created) or 0) + 1
    local controller = {
        view = view,
        id = tostring(spec.id or (tostring(view.id or "view") .. "_state")),
        state = NormalizeState(spec.initialState or "ready"),
        autoEmpty = spec.autoEmpty ~= false,
        retry = spec.onRetry,
        title = nil,
        detail = nil,
        tone = nil,
        explicit = false,
        revision = 0,
    }

    controller.message = RSUI:Text({
        id = controller.id .. "_message", parent = view, text = "", fontSize = tonumber(spec.fontSize) or 11,
        tone = "muted", align = ALIGN_CENTER, overflow = "wrap", maxLines = tonumber(spec.maxLines) or 4,
        visibility = "collapsed",
    })
    controller.retryButton = RSUI:Button({
        id = controller.id .. "_retry", parent = view, text = tostring(spec.retryText or "重试"), compact = true,
        width = tonumber(spec.retryWidth) or 72, height = tonumber(spec.retryHeight) or 26, visibility = "collapsed",
        onClick = function()
            if type(controller.retry) ~= "function" then return false end
            V.metrics.retries = (tonumber(V.metrics.retries) or 0) + 1
            controller:Set("loading", { title = "正在重试…", detail = "", explicit = true })
            local ok, a, b = xpcall(function() return controller.retry(controller.view, controller) end, S.SafeTraceback)
            if not ok or a == false then
                V.metrics.retryFailures = (tonumber(V.metrics.retryFailures) or 0) + 1
                controller:Set("error", { detail = tostring((ok and b) or a or "重试失败"), explicit = true })
                return false
            end
            return true
        end,
    })

    function controller:Get()
        return self.state
    end

    function controller:IsDataVisible()
        local defaults = DEFAULTS[self.state] or DEFAULTS.ready
        return defaults.showData == true
    end

    function controller:Set(state, options)
        options = type(options) == "table" and options or {}
        state = NormalizeState(state)
        local defaults = DEFAULTS[state] or DEFAULTS.ready
        local previous = self.state
        self.state = state
        self.title = tostring(options.title ~= nil and options.title or defaults.title or "")
        self.detail = tostring(options.detail ~= nil and options.detail or defaults.detail or "")
        self.tone = tostring(options.tone ~= nil and options.tone or defaults.tone or "default")
        if options.retry ~= nil then self.retry = options.retry end
        if options.explicit ~= nil then self.explicit = options.explicit == true
        else self.explicit = state ~= "ready" and state ~= "empty" end
        self.revision = (tonumber(self.revision) or 0) + 1
        local showOverlay = state ~= "ready"
        if self.message ~= nil then
            local text = self.title
            if self.detail ~= "" then text = text ~= "" and (text .. "\n" .. self.detail) or self.detail end
            self.message:SetText(text)
            self.message:SetTone(self.tone)
            self.message:SetVisibility(showOverlay and "visible" or "collapsed")
        end
        local canRetry = showOverlay and type(self.retry) == "function" and (state == "error" or state == "unavailable")
        if self.retryButton ~= nil then self.retryButton:SetVisibility(canRetry and "visible" or "collapsed") end
        if previous ~= state then V.metrics.changes = (tonumber(V.metrics.changes) or 0) + 1 end
        if type(self.view.InvalidateLayout) == "function" then self.view:InvalidateLayout("view_state:" .. state) end
        return true
    end

    function controller:SetReady()
        self.explicit = false
        return self:Set("ready", { explicit = false })
    end

    function controller:AutoFromCount(count)
        if self.autoEmpty ~= true or self.explicit == true then return false end
        count = math.max(0, math.floor(tonumber(count) or 0))
        if count == 0 then
            if self.state ~= "empty" then V.metrics.autoEmpty = (tonumber(V.metrics.autoEmpty) or 0) + 1 end
            return self:Set("empty", { explicit = false })
        end
        return self:Set("ready", { explicit = false })
    end

    function controller:Layout(x, y, width, height)
        width, height = math.max(1, tonumber(width) or 1), math.max(1, tonumber(height) or 1)
        if self.state == "ready" then return true end
        local messageHeight = math.max(32, math.min(76, math.floor(height * 0.45)))
        local retryVisible = self.retryButton ~= nil and self.retryButton.visible ~= false
        local retryH = retryVisible and 30 or 0
        local totalH = messageHeight + retryH
        local startY = math.max(0, math.floor((height - totalH) * 0.5))
        if self.message ~= nil then
            self.message:Layout(12, startY, math.max(1, width - 24), messageHeight)
            if self.message.root ~= nil and type(self.message.root.Raise) == "function" then pcall(function() self.message.root:Raise() end) end
        end
        if retryVisible then
            local bw = math.min(100, math.max(64, tonumber(self.retryButton.width) or 72))
            self.retryButton:Layout(math.max(0, math.floor((width - bw) * 0.5)), startY + messageHeight + 2, bw, 26)
            if self.retryButton.root ~= nil and type(self.retryButton.root.Raise) == "function" then pcall(function() self.retryButton.root:Raise() end) end
        end
        return true
    end

    function controller:Describe()
        return {
            id = self.id, state = self.state, explicit = self.explicit == true,
            autoEmpty = self.autoEmpty == true, dataVisible = self:IsDataVisible(), revision = tonumber(self.revision) or 0,
            retryable = type(self.retry) == "function",
        }
    end

    controller:Set(controller.state, { explicit = controller.state ~= "ready" and controller.state ~= "empty" })
    V.controllers[controller] = true
    return controller
end

function V:GetSnapshot()
    local active, states = 0, { loading = 0, ready = 0, empty = 0, error = 0, unavailable = 0, stale = 0 }
    for controller in pairs(self.controllers or {}) do
        active = active + 1
        local state = NormalizeState(controller and controller.state or "ready")
        states[state] = (tonumber(states[state]) or 0) + 1
    end
    return {
        version = self.version, generation = self.generation,
        active = active, states = states,
        created = tonumber(self.metrics.created) or 0,
        changes = tonumber(self.metrics.changes) or 0,
        autoEmpty = tonumber(self.metrics.autoEmpty) or 0,
        retries = tonumber(self.metrics.retries) or 0,
        retryFailures = tonumber(self.metrics.retryFailures) or 0,
    }
end

function RSUI:CreateViewState(view, spec)
    return V:Create(view, spec)
end
