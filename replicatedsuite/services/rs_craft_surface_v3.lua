-- Replicated Suite · 制作原生窗口观察
-- 作者：Replicated
-- QQ群：1104129461
-- tools_craft 自动侧栏仅观察 MAKE_CRAFT_ORDER→CRAFT_ORDER→CRAFT_BOOK 可见性；显式点击才读取配方引用，不读取材料或背包。
-- 四返回值版本还须 content/parent 明确可见；旧矩形不能证明窗口打开。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}

local V = {
    version = 2,
    VisibilityContractVersion = 1,
    SelectionContractVersion = 1,
    topic = "v3.craft_surface.updated",
    taskId = "v3_craft_surface_observer",
    intervalMs = 400,
    started = false,
    revision = 0,
    snapshot = { status = "idle", visible = false, revision = 0, source = "none", kind = nil },
    owner = nil,
    candidates = {
        { globalName = "UIC_MAKE_CRAFT_ORDER", kind = "make" },
        { globalName = "UIC_CRAFT_ORDER", kind = "order" },
        { globalName = "UIC_CRAFT_BOOK", kind = "book" },
    },
}
V.owner = V
V.presentationBoundary = "service_only"
S.Services.CraftSurfaceV3 = V

-- 只复制本服务构造的有界标量事实，不保留原生对象；导出不得重新采样 Native。
local function CopyEvidence(value, depth)
    local kind = type(value)
    if kind == "string" or kind == "boolean" then return value end
    if kind == "number" and value == value and value ~= math.huge and value ~= -math.huge then return value end
    if kind ~= "table" or (depth or 0) > 10 then return nil end
    local out = {}
    for key, child in pairs(value) do out[key] = CopyEvidence(child, (depth or 0) + 1) end
    return out
end
local function NativeScalar(value)
    local kind = type(value)
    if kind == "string" then return value:sub(1, 64) end
    if kind == "boolean" then return value end
    if kind == "number" and value == value and value ~= math.huge and value ~= -math.huge then return value end
end

local function Number(value)
    local n = tonumber(value)
    if n == nil or n ~= n then return nil end
    return n
end

local function CopySnapshot(value)
    value = type(value) == "table" and value or {}
    return {
        status = tostring(value.status or "unknown"),
        visible = value.visible == true,
        x = Number(value.x), y = Number(value.y), width = Number(value.width), height = Number(value.height),
        source = tostring(value.source or "unknown"),
        reason = value.reason ~= nil and tostring(value.reason) or nil,
        kind = value.kind ~= nil and tostring(value.kind) or nil,
        contentGlobal = value.contentGlobal ~= nil and tostring(value.contentGlobal) or nil,
        revision = tonumber(value.revision) or 0,
    }
end

local function SameSnapshot(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for _, key in ipairs({ "status", "source", "reason", "kind", "contentGlobal" }) do
        if tostring(a[key] or "") ~= tostring(b[key] or "") then return false end
    end
    if (a.visible == true) ~= (b.visible == true) then return false end
    for _, key in ipairs({ "x", "y", "width", "height" }) do
        local av, bv = Number(a[key]), Number(b[key])
        if av == nil or bv == nil then
            if av ~= bv then return false end
        elseif math.abs(av - bv) >= 1 then
            return false
        end
    end
    return true
end

local function LayoutBounds()
    local context = S.Layout ~= nil and type(S.Layout.GetContext) == "function" and S.Layout:GetContext() or {}
    return math.max(320, Number(context.logicalWidth) or 1024), math.max(240, Number(context.logicalHeight) or 768)
end

local function PlausibleRect(x, y, width, height, logicalWidth, logicalHeight)
    x, y, width, height = Number(x), Number(y), Number(width), Number(height)
    if x == nil or y == nil or width == nil or height == nil then return false end
    if width < 100 or height < 100 then return false end
    if width > logicalWidth * 0.98 or height > logicalHeight * 0.98 then return false end
    if x > logicalWidth + 64 or y > logicalHeight + 64 or x + width < -64 or y + height < -64 then return false end
    return true
end

local function ReadWidgetVisible(widget, probe)
    if widget == nil or type(widget.IsVisible) ~= "function" then return false, false end
    local ok, visible = pcall(function() return widget:IsVisible() end)
    if probe then
        probe.visibilityCallOk = ok == true; probe.visibilityType = type(visible)
        if type(visible) == "boolean" or type(visible) == "number" then probe.visibilityValue = visible end
    end
    if ok ~= true then return false, false end
    return true, visible == true
end

local function ReadContentChainVisible(content, chain)
    local node, anyKnown = content, false
    for _ = 0, 8 do
        if node == nil then break end
        local probe = chain and { objectType = type(node), isUiParent = node == rawget(_G, "UIParent") }
        if chain then chain[#chain + 1] = probe end
        local known, visible = ReadWidgetVisible(node, probe)
        if known == true then
            anyKnown = true
            if visible == true then return true, true end
        end
        if type(node.GetParent) ~= "function" then break end
        local ok, parent = pcall(function() return node:GetParent() end)
        if ok ~= true or parent == nil or parent == node then break end
        node = parent
    end
    return anyKnown, false
end

local function ReadContent(addon, contentId, probe)
    if addon == nil or contentId == nil or S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function" then return nil end
    local allowed = S.Api:IsCapabilityAllowed("ADDON:GetContent") == true
    if probe then probe.contentAllowed = allowed; probe.contentMethodType = type(addon.GetContent) end
    if not allowed or type(addon.GetContent) ~= "function" then return nil end
    local ok, content = S.Api:CallCapability("ADDON:GetContent", addon, "GetContent", contentId)
    if probe then probe.contentCallOk = ok == true; probe.contentType = type(content) end
    if ok == true then return content end
    return nil
end

local function ResolveContentRect(content, logicalWidth, logicalHeight)
    local node = content
    for depth = 0, 8 do
        if node == nil then break end
        if S.Layout ~= nil and (type(S.Layout.ResolveViewportLogicalRect) == "function" or type(S.Layout.GetLogicalRect) == "function") then
            -- 外部几何优先用 Layout 的 viewport-logical-v1，避免旧 GetLogicalRect 重复除缩放；旧引导/测试才用兼容入口。
            local ok, x, y, width, height = pcall(function()
                if type(S.Layout.ResolveViewportLogicalRect) == "function" then return S.Layout:ResolveViewportLogicalRect(node) end
                return S.Layout:GetLogicalRect(node)
            end)
            if ok == true and PlausibleRect(x, y, width, height, logicalWidth, logicalHeight) then
                return Number(x), Number(y), Number(width), Number(height), depth == 0 and "craft-content" or ("craft-parent-" .. tostring(depth))
            end
        end
        if type(node.GetParent) ~= "function" then break end
        local ok, parent = pcall(function() return node:GetParent() end)
        if ok ~= true or parent == nil or parent == node then break end
        node = parent
    end
    return nil
end

function V:_ReadCandidate(addon, candidate, logicalWidth, logicalHeight)
    local contentId = rawget(_G, candidate.globalName)
    local probe = { contentIdType = type(contentId), contentId = type(contentId) == "number" and contentId or nil, contentChain = {} }
    local function Finish(snapshot)
        probe.decision = CopySnapshot(snapshot)
        return snapshot, probe
    end
    if contentId == nil then return Finish({ status = "unavailable", visible = false, kind = candidate.kind, contentGlobal = candidate.globalName, source = "missing-uic" }) end

    local content = ReadContent(addon, contentId, probe)
    local contentKnown, contentVisible = ReadContentChainVisible(content, probe.contentChain)
    local ok, x, y, width, height, visible = pcall(function() return addon:GetContentMainScriptPosVis(contentId) end)
    probe.mainCallOk = ok == true
    probe.mainReturnTypes = table.concat({ type(x), type(y), type(width), type(height), type(visible) }, ",")
    probe.mainValues = { x = NativeScalar(x), y = NativeScalar(y), width = NativeScalar(width), height = NativeScalar(height), visible = NativeScalar(visible) }
    probe.contentVisibilityKnown, probe.contentVisible = contentKnown, contentVisible
    x, y, width, height = Number(x), Number(y), Number(width), Number(height)
    local mainRect = ok == true and PlausibleRect(x, y, width, height, logicalWidth, logicalHeight)
    probe.mainRectValid = mainRect == true

    local visibilityKnown, resolvedVisible = false, false
    if type(visible) == "boolean" then
        visibilityKnown, resolvedVisible = true, visible == true
    elseif contentKnown == true then
        visibilityKnown, resolvedVisible = true, contentVisible == true
    end

    if visibilityKnown == true and resolvedVisible ~= true then
        return Finish({ status = "ready", visible = false, kind = candidate.kind, contentGlobal = candidate.globalName, source = contentKnown and "content-hidden" or "main-script-hidden" })
    end
    if visibilityKnown == true and resolvedVisible == true and mainRect == true then
        return Finish({
            status = "ready", visible = true, kind = candidate.kind, contentGlobal = candidate.globalName,
            x = x, y = y, width = width, height = height,
            source = type(visible) == "boolean" and "main-script" or "main-script+content-vis",
        })
    end
    if visibilityKnown == true and resolvedVisible == true then
        local px, py, pw, ph, source = ResolveContentRect(content, logicalWidth, logicalHeight)
        if px ~= nil then
            return Finish({ status = "ready", visible = true, kind = candidate.kind, contentGlobal = candidate.globalName, x = px, y = py, width = pw, height = ph, source = source })
        end
        return Finish({ status = "unknown", visible = false, kind = candidate.kind, contentGlobal = candidate.globalName, source = "visible-no-geometry", reason = "制作窗口可见但几何无法安全解析" })
    end
    if ok ~= true then
        return Finish({ status = "unknown", visible = false, kind = candidate.kind, contentGlobal = candidate.globalName, source = "main-script-error", reason = "制作窗口几何读取失败" })
    end
    if mainRect == true then
        -- 制作候选不同于 AuctionSurfaceV3，不接受仅几何作为打开证据；多个 UIC 可保留旧矩形，缺 boolean 或
        -- Content 可见事实时失败封闭。
        return Finish({ status = "unknown", visible = false, kind = candidate.kind, contentGlobal = candidate.globalName, source = "geometry-only", reason = "制作窗口仅返回几何，缺少可见性事实" })
    end
    return Finish({ status = "unknown", visible = false, kind = candidate.kind, contentGlobal = candidate.globalName, source = "unknown", reason = "制作窗口返回值未知" })
end

function V:_Read()
    local observation = { contractVersion = 1, sampledAtMs = S.NowMs and S.NowMs() or nil, candidates = {}, generation = S.Generation }
    self.observation = observation
    local addon = rawget(_G, "ADDON")
    observation.addonPresent = addon ~= nil
    if addon == nil then return { status = "unavailable", visible = false, source = "none", reason = "ADDON 不可用" } end
    if S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function"
        or S.Api:IsCapabilityAllowed("ADDON:GetContentMainScriptPosVis") ~= true then
        return { status = "unavailable", visible = false, source = "none", reason = "制作窗口几何 API 未获能力许可" }
    end
    if type(addon.GetContentMainScriptPosVis) ~= "function" then
        return { status = "unavailable", visible = false, source = "none", reason = "制作窗口几何 getter 不可用" }
    end

    local logicalWidth, logicalHeight = LayoutBounds()
    observation.logicalWidth, observation.logicalHeight = logicalWidth, logicalHeight
    local available, unknown, firstReason = 0, 0, nil
    for _, candidate in ipairs(self.candidates) do
        local snapshot, probe = self:_ReadCandidate(addon, candidate, logicalWidth, logicalHeight)
        observation.candidates[candidate.globalName] = probe
        if snapshot.status ~= "unavailable" then available = available + 1 end
        if snapshot.status == "ready" and snapshot.visible == true then return snapshot end
        if snapshot.status == "unknown" then unknown = unknown + 1; firstReason = firstReason or snapshot.reason end
    end
    if available == 0 then return { status = "unavailable", visible = false, source = "none", reason = "制作窗口 UIC 常量不可用" } end
    if unknown > 0 then return { status = "unknown", visible = false, source = "candidate-scan", reason = firstReason or "制作窗口可见性未知" } end
    return { status = "ready", visible = false, source = "candidates-hidden", reason = nil }
end

function V:_Publish(nextSnapshot, force)
    nextSnapshot = type(nextSnapshot) == "table" and nextSnapshot or { status = "unknown", visible = false, source = "none" }
    if force ~= true and SameSnapshot(self.snapshot, nextSnapshot) then return true, false end
    self.revision = (tonumber(self.revision) or 0) + 1
    nextSnapshot.revision = self.revision
    self.snapshot = CopySnapshot(nextSnapshot)
    if S.Events ~= nil and type(S.Events.Publish) == "function" then S.Events:Publish(self.topic, CopySnapshot(self.snapshot)) end
    return true, true
end

function V:Refresh(reason, force)
    if self.started ~= true and force ~= true then return false, "craft surface observer stopped" end
    local nextSnapshot = self:_Read()
    nextSnapshot.reason = nextSnapshot.reason or (reason ~= nil and tostring(reason) or nil)
    return self:_Publish(nextSnapshot, force == true)
end

function V:GetSnapshot() return CopySnapshot(self.snapshot) end
function V:GetDiagnosticsSnapshot()
    return { version = self.version, started = self.started == true, snapshot = self:GetSnapshot(),
        observation = CopyEvidence(self.observation), selection = CopyEvidence(self.lastSelection) }
end

-- 用户点击时读取 O 页的明确选择；可见性观察任务不调用本方法，也不保留 Native 引用。
-- 已观察布局来自 crafting.lua/crafting_view.lua；不枚举 userdata、不接管原生选择回调。
local function SelectionMember(object, key)
    if object == nil then return nil end
    local ok, value = pcall(function() return object[key] end)
    if ok then return value end
end
local function SelectionCall(object, method)
    local fn = SelectionMember(object, method)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, object)
    if ok then return value end
end
local function SelectionId(value)
    if type(value) ~= "number" and type(value) ~= "string" then return nil end
    local n = tonumber(value)
    if n and n == n and n > 0 and n <= 1000000000 and n == math.floor(n) then return n end
end
local function ReadSelectedRecipe()
    local addon, contentId = rawget(_G, "ADDON"), rawget(_G, "UIC_CRAFT_BOOK")
    if addon == nil or contentId == nil or S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function"
        or S.Api:IsCapabilityAllowed("ADDON:GetContent") ~= true or type(S.Api.CallCapability) ~= "function" then
        return nil, "当前无法读取制作页；可使用名称搜索或“更多导入”。"
    end
    local ok, node = S.Api:CallCapability("ADDON:GetContent", addon, "GetContent", contentId)
    if ok ~= true or node == nil then return nil, "未读到 O 页配方对象；请接收配方分享，或查找已收录物品。" end
    local seen = {}
    for _ = 0, 8 do
        if (type(node) ~= "table" and type(node) ~= "userdata") or seen[node] then break end
        seen[node] = true
        local detail = SelectionMember(node, "detailPage")
        if detail ~= nil then
            if SelectionCall(node, "IsVisible") ~= true or SelectionCall(detail, "IsVisible") ~= true then
                return nil, "请先按 O 打开制作页，并选中具体配方。"
            end
            local product = SelectionMember(SelectionMember(SelectionMember(detail, "productInfoFrame"), "item"), "info")
            local itemType = SelectionId(SelectionMember(product, "itemType"))
            if not itemType then return nil, "尚未读到制作页产物，请重新选择一张具体配方。" end
            local list = SelectionMember(detail, "categoryList")
            local craftType = SelectionId(SelectionCall(list, "GetSelectedValue"))
                or SelectionId(SelectionCall(SelectionMember(list, "content"), "GetSelectedValue"))
            local buttons = SelectionMember(SelectionMember(detail, "stepFrame"), "button")
            local stepId, stepCount = nil, 0
            if type(buttons) == "table" then
                -- crafting_view.lua 的 CreateCraftStepFrame 固定创建 10 个阶段按钮。
                for index = 1, 10 do
                    local button = SelectionMember(buttons, index)
                    if SelectionCall(SelectionMember(button, "selected"), "IsVisible") == true then
                        stepCount = stepCount + 1; stepId = SelectionId(SelectionMember(button, "craftType"))
                    end
                end
            end
            if stepCount > 1 or (stepCount == 1 and not stepId) then return nil, "制作阶段选择无法确认，请重新选择配方。" end
            if stepId then craftType = stepId end
            if not craftType then return nil, "请在制作页左侧列表选中一张具体配方，再点加入计划。" end
            local name = SelectionMember(product, "name")
            return { craftType = craftType, itemType = itemType,
                name = type(name) == "string" and #name <= 192 and name or nil, source = "craft_book_selection" }
        end
        node = SelectionCall(node, "GetParent")
    end
    return nil, "当前客户端无法读取制作页选择；可使用名称搜索或“更多导入”。"
end
function V:ReadSelectedRecipe()
    local reference, reason = ReadSelectedRecipe()
    self.lastSelection = { sampledAtMs = S.NowMs and S.NowMs() or nil, success = reference ~= nil,
        reference = CopyEvidence(reference), reason = reason }
    return reference, reason
end

function V:Start()
    if self.started == true then return true end
    if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then
        return false, "craft surface scheduler unavailable"
    end
    self.started = true
    self:_Publish(self:_Read(), true)
    S.Scheduler:RemoveTask(self.taskId)
    local added = S.Scheduler:AddTask(self.taskId, self.intervalMs, function()
        if V.started == true then V:Refresh("observer") end
    end, false, self.owner, "P2")
    if added ~= true then
        self.started = false
        self:_Publish({ status = "unavailable", visible = false, source = "none", reason = "制作窗口观察任务创建失败" }, true)
        return false, "craft surface observer task failed"
    end
    if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(self.taskId, "tools_craft", true) end
    return true
end

function V:Stop(reason)
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(self.taskId) end
    self.started = false
    return self:_Publish({ status = "stopped", visible = false, source = "none", reason = tostring(reason or "feature_disabled") }, true)
end

function V:Describe()
    return {
        version = self.version, visibilityContractVersion = self.VisibilityContractVersion, selectionContractVersion = self.SelectionContractVersion,
        started = self.started == true, intervalMs = self.intervalMs, revision = self.revision,
        topic = self.topic, snapshot = self:GetSnapshot(),
        observation = CopyEvidence(self.observation), selection = CopyEvidence(self.lastSelection),
    }
end
