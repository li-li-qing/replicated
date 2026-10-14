------------------------------------------------------------------------
-- Replicated Suite · 拍卖原生窗口观察
-- 作者：Replicated
-- QQ群：1104129461
--
-- 拍卖原生窗只读观察服务在 tools_auction 启用期间拥有唯一有界观察，并向 Presentation 发布几何/可见事实；不
-- 读收藏、不发搜索、不拥有 UI 对象。部分 RU GetContentMainScriptPosVis(UIC_AUCTION) 只返回 x/y/width/height
-- 而省略 visibility，已有生产证据；因此结合 MainScript 几何与原生 content/parent IsVisible 链，不能无条件要
-- 求第五返回值。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}

local V = {
    version = 3,
    CalibratedOuterGeometryContractVersion = 1,
    VisibilityContractVersion = 2,
    InteractionVisibilityContractVersion = 1, -- 观察器停止不等于原生窗口关闭。
    topic = "v3.auction_surface.updated",
    taskId = "v3_auction_surface_observer",
    started = false,
    revision = 0,
    snapshot = { status = "idle", visible = false, revision = 0, source = "none" },
    owner = nil,
}
V.owner = V
V.presentationBoundary = "service_only"
S.Services.AuctionSurfaceV3 = V

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
        x = Number(value.x), y = Number(value.y),
        width = Number(value.width), height = Number(value.height),
        source = tostring(value.source or "unknown"),
        geometrySource = value.geometrySource, coordinateSpace = value.coordinateSpace,
        effectiveScale = Number(value.effectiveScale),
        reason = value.reason ~= nil and tostring(value.reason) or nil,
        revision = tonumber(value.revision) or 0,
    }
end

local function SameGeometry(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    if tostring(a.status or "") ~= tostring(b.status or "") or (a.visible == true) ~= (b.visible == true) then return false end
    if tostring(a.source or "") ~= tostring(b.source or "") or tostring(a.reason or "") ~= tostring(b.reason or "") then return false end
    if a.geometrySource~=b.geometrySource or a.coordinateSpace~=b.coordinateSpace or a.effectiveScale~=b.effectiveScale then return false end
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
    if width < 120 or height < 120 then return false end
    if width > logicalWidth * 0.98 or height > logicalHeight * 0.98 then return false end
    if x > logicalWidth + 64 or y > logicalHeight + 64 or x + width < -64 or y + height < -64 then return false end
    return true
end

local function ReadWidgetVisible(widget)
    if widget == nil or type(widget.IsVisible) ~= "function" then return false, false end
    local ok, visible = pcall(function() return widget:IsVisible() end)
    -- nil/数字/字符串不构成“已关闭”证据，未知形状保持 unknown。
    if ok ~= true or type(visible) ~= "boolean" then return false, false end
    return true, visible == true
end

-- ADDON content 可为子代理；短父链任一节点可见即视为可见。若至少一节点提供 IsVisible 且全部不可见，则可确定
-- 链隐藏。
local function ReadContentChainVisible(content)
    local node, anyKnown = content, false
    for _ = 0, 8 do
        -- UIParent 永远可见，不能把桌面本身当成拍卖窗口打开的证据。
        if node == nil or node == rawget(_G, "UIParent") then break end
        local known, visible = ReadWidgetVisible(node)
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

local function ReadAuctionContent(addon, contentId)
    -- （2026-10-02，auction-closed-content-1）第二返回值只证明受能力门保护的
    -- Native 调用确实成功，不能把“不允许/缺方法/调用失败”折叠成与“内容不存在”相同的 nil。
    -- 第一返回值保留旧内容对象接口；调用方只有同时持有成功证据才能使用空对象作关闭证据。
    if addon == nil or contentId == nil or S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function"
        or type(S.Api.CallCapability) ~= "function" then return nil, false end
    if S.Api:IsCapabilityAllowed("ADDON:GetContent") ~= true or type(addon.GetContent) ~= "function" then return nil, false end
    local ok, content = S.Api:CallCapability("ADDON:GetContent", addon, "GetContent", contentId)
    if ok == true then return content, true end
    return nil, false
end

local function ContentAbsent(mainOk, x, y, width, height, visible, contentReadOk, content)
    -- RU 实机证据：2026-10-02，MD1.3.life_trade 的拍卖窗关闭或尚未创建时，MainScript 五字段全 nil，
    -- GetContent 成功返回 nil。只有同次采样两 getter 均成功且无内容、几何、可见字段，才证明窗口不存在。不能
    -- 推广为任意 nil/零矩形即关闭，也不缓存旧关闭状态；每次询价边界重新读取。
    return mainOk == true and contentReadOk == true and content == nil
        and x == nil and y == nil and width == nil and height == nil and visible == nil
end

local function ResolveContentRect(content, logicalWidth, logicalHeight)
    local node = content
    local rect
    for depth = 0, 8 do
        if node == nil or node == rawget(_G, "UIParent") then break end
        if S.Layout ~= nil and (type(S.Layout.ResolveViewportLogicalRect) == "function" or type(S.Layout.GetLogicalRect) == "function") then
            -- （2026-09-22，external-surface-geometry-1）外部原生内容坐标最终用于 UIParent 侧栏锚定，
            -- 必须优先走已校准的 viewport-logical-v1；旧 GetLogicalRect 会在部分 RU UI Scale 语义下
            -- 重复除缩放。兼容测试/旧引导环境时才退回 legacy helper，不改变 Native ADDON Authority。
            local ok, x, y, width, height, info = pcall(function()
                if type(S.Layout.ResolveViewportLogicalRect) == "function" then return S.Layout:ResolveViewportLogicalRect(node) end
                return S.Layout:GetLogicalRect(node)
            end)
            if ok == true and PlausibleRect(x, y, width, height, logicalWidth, logicalHeight) then
                -- 内容可能是内部列表；取 UIParent 之前最外层的有效窗口边界，侧窗不能贴到列表内部。
                rect={x=Number(x),y=Number(y),width=Number(width),height=Number(height),
                    source=depth==0 and "auction-content" or ("auction-parent-"..tostring(depth)),
                    effectiveScale=type(info)=="table" and Number(info.effectiveScale) or nil}
            end
        end
        if type(node.GetParent) ~= "function" then break end
        local ok, parent = pcall(function() return node:GetParent() end)
        if ok ~= true or parent == nil or parent == node then break end
        node = parent
    end
    if rect then return rect.x,rect.y,rect.width,rect.height,rect.source,rect.effectiveScale end
    return nil
end

-- （2026-09-30，auction-user-priority-1）后台名称搜索会替换原生拍卖结果，不能把
-- 侧栏关闭后的 idle/stopped 缓存视为玩家没在用拍卖行。此入口只按需读取可见性，不启动观察任务、
-- 不 Publish、不更新几何快照；显式 boolean 优先于几何，兼容四返回值时才读短父链。
-- 可见性不可证实时返回 known=false；两个 getter 成功返回的“内容不存在”形态由共享空内容判定证明关闭。
-- 社交与拍卖共用受能力门保护的可见性读取；服务不持有外部窗口对象、不覆盖原生处理器。
-- content-absent 关闭证明仅有拍卖实机契约，社交全 nil 必须返回 unknown，不能抹掉有效名单回包。
function V:ReadNativeVisibility(contentId, allowAbsent)
    local addon = rawget(_G, "ADDON")
    -- 只在既有按需采样中附带字段形状，不在生成诊断时重读 Native。
    -- 不记录原生对象/全文错误、不持有 UI；unknown 的因果证据有界，权限/可见性决策不放宽。
    local probe = { contractVersion = 1, patch = "auction-closed-content-1", contentId = Number(contentId), contentIdType = type(contentId),
        addonPresent = addon ~= nil, mainMethod = addon ~= nil and type(addon.GetContentMainScriptPosVis) == "function" }
    if addon == nil or contentId == nil or S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function" then
        return false, false, "auction_visibility_api_unavailable", probe
    end
    probe.mainAllowed = S.Api:IsCapabilityAllowed("ADDON:GetContentMainScriptPosVis") == true
    probe.contentAllowed = S.Api:IsCapabilityAllowed("ADDON:GetContent") == true
    local ok, x, y, width, height, visible = pcall(function()
        if probe.mainAllowed ~= true or probe.mainMethod ~= true then error("auction_visibility_not_allowed") end
        return addon:GetContentMainScriptPosVis(contentId)
    end)
    probe.mainCallOk = ok == true
    probe.mainReturnTypes = table.concat({type(x), type(y), type(width), type(height), type(visible)}, ",")
    if ok == true and type(visible) == "boolean" then return true, visible, "main-script", probe end
    local contentOk, content, contentReadOk = pcall(ReadAuctionContent, addon, contentId)
    -- contentCallOk 区分 Lua 包装未抛错，contentReadOk 才代表实际 Native 成功；
    -- 诊断附带 contentAbsent，导出的 txt 能直接辨别正常关闭与 API 失败，不持有原生对象。
    probe.contentCallOk, probe.contentType = contentOk == true, type(content)
    probe.contentReadOk = contentOk == true and contentReadOk == true
    local readOk, known, contentVisible = false, false, false
    if contentOk == true and content ~= nil then
        readOk, known, contentVisible = pcall(ReadContentChainVisible, content)
    end
    probe.chainReadOk, probe.chainKnown = readOk == true, known == true
    if readOk == true and known == true then return true, contentVisible == true, "content-vis", probe end
    local logicalWidth, logicalHeight = LayoutBounds()
    probe.plausibleGeometry = ok == true and PlausibleRect(x, y, width, height, logicalWidth, logicalHeight)
    if probe.plausibleGeometry then return true, true, "main-script-geometry", probe end
    probe.contentAbsent = ContentAbsent(ok, x, y, width, height, visible, probe.contentReadOk, content)
    if probe.contentAbsent and allowAbsent==true then return true, false, "content-absent", probe end
    return false, false, "auction_visibility_unknown", probe
end

function V:ReadVisibility()
    return self:ReadNativeVisibility(rawget(_G, "UIC_AUCTION"), true)
end

function V:_Read()
    local addon = rawget(_G, "ADDON")
    local contentId = rawget(_G, "UIC_AUCTION")
    if addon == nil or contentId == nil then
        return { status = "unavailable", visible = false, source = "none", reason = "ADDON/UIC_AUCTION 不可用" }
    end
    if S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function"
        or S.Api:IsCapabilityAllowed("ADDON:GetContentMainScriptPosVis") ~= true then
        return { status = "unavailable", visible = false, source = "none", reason = "拍卖窗口几何 API 未获能力许可" }
    end
    if type(addon.GetContentMainScriptPosVis) ~= "function" then
        return { status = "unavailable", visible = false, source = "none", reason = "拍卖窗口几何 getter 不可用" }
    end

    local logicalWidth, logicalHeight = LayoutBounds()
    -- （2026-10-02）侧栏几何观察与询价准入共享“正常无内容”的关闭证明；
    -- 保护内容读取/父链异常，不能让一个原生 getter 抛错终止观察任务。
    local contentCallOk, content, contentReadOk = pcall(ReadAuctionContent, addon, contentId)
    local chainOk, contentKnown, contentVisible = pcall(ReadContentChainVisible, content)
    if chainOk ~= true then contentKnown, contentVisible = false, false end

    -- 五返回值原生 getter 在能力门禁后直接调用，因为通用包装返回元组有界，而旧 RU 可省略最后 boolean。
    local ok, x, y, width, height, visible = pcall(function()
        return addon:GetContentMainScriptPosVis(contentId)
    end)
    local contentAbsent = ContentAbsent(ok, x, y, width, height, visible, contentCallOk == true and contentReadOk == true, content)
    x, y, width, height = Number(x), Number(y), Number(width), Number(height)
    local mainRect = ok == true and PlausibleRect(x, y, width, height, logicalWidth, logicalHeight)

    local resolvedVisible
    if type(visible) == "boolean" then
        resolvedVisible = visible == true
    elseif contentKnown == true then
        -- 原生代理提供可见性时，优先采用真实 Widget 可见事实而非陈旧几何。
        resolvedVisible = contentVisible == true
    elseif mainRect == true then
        -- 部分历史 RU 只省略 boolean，但拍卖行关闭时仍清空几何；只有无更强 content 可见性事实时，合理数字几
        -- 何才可作为打开信号。
        resolvedVisible = true
    else
        resolvedVisible = false
    end

    -- MainScript 在不同 RU 构建中可能返回物理像素。优先使用 Layout 已校准的外窗逻辑坐标，
    -- 不直接把 uiScale 当除数；保留原来的可见性证据优先级与询价准入规则。
    local px,py,pw,ph,geometrySource,effectiveScale=ResolveContentRect(content,logicalWidth,logicalHeight)
    if mainRect == true then
        local calibrated=px~=nil and S.Layout~=nil and type(S.Layout.ResolveViewportLogicalRect)=="function"
        return {
            status = "ready", visible = resolvedVisible,
            x = calibrated and px or x, y = calibrated and py or y, width = calibrated and pw or width, height = calibrated and ph or height,
            source = type(visible) == "boolean" and "main-script" or (contentKnown and "main-script+content-vis" or "main-script-geometry"),
            geometrySource=calibrated and geometrySource or "main-script-fallback",effectiveScale=calibrated and effectiveScale or nil,
            coordinateSpace=calibrated and "viewport-logical-v1" or "main-script-unverified",
            reason = nil,
        }
    end

    -- 先在原始返回值上判定全空，再交几何归一；避免非法字符串/NaN 被 Number
    -- 变成 nil 后误获关闭证明。关闭状态无位置可用，侧栏只收起，不生成猜测坐标。
    if contentAbsent then return { status = "ready", visible = false, source = "content-absent", reason = nil } end

    -- MainScript 可是几何不可用的 content 代理；原生树证明可见时寻找最近合理外窗矩形。隐藏且无矩形是明确关
    -- 闭；可见但几何未知须失败封闭，不能把独立面板放到猜测坐标。
    if px ~= nil then
        local geometryVisible=contentKnown==true and contentVisible==true
        if type(visible)=="boolean" then geometryVisible=visible end
        return { status = "ready", visible = geometryVisible,
            x=px,y=py,width=pw,height=ph,source=geometrySource,geometrySource=geometrySource,
            coordinateSpace="viewport-logical-v1",effectiveScale=effectiveScale,reason=nil }
    end
    if contentKnown == true and contentVisible ~= true then
        return { status = "ready", visible = false, source = "content-hidden", reason = nil }
    end
    if ok ~= true then
        return { status = "unknown", visible = false, source = "none", reason = "拍卖窗口几何读取失败" }
    end
    return { status = "unknown", visible = false, source = "none", reason = "拍卖窗口几何/可见性返回值未知" }
end

function V:_Publish(nextSnapshot, force)
    nextSnapshot = type(nextSnapshot) == "table" and nextSnapshot or { status = "unknown", visible = false, source = "none" }
    if force ~= true and SameGeometry(self.snapshot, nextSnapshot) then return true, false end
    self.revision = (tonumber(self.revision) or 0) + 1
    nextSnapshot.revision = self.revision
    self.snapshot = CopySnapshot(nextSnapshot)
    if S.Events ~= nil and type(S.Events.Publish) == "function" then
        S.Events:Publish(self.topic, CopySnapshot(self.snapshot))
    end
    return true, true
end

function V:Refresh(reason, force)
    if self.started ~= true and force ~= true then return false, "auction surface observer stopped" end
    local nextSnapshot = self:_Read()
    nextSnapshot.reason = nextSnapshot.reason or (reason ~= nil and tostring(reason) or nil)
    return self:_Publish(nextSnapshot, force == true)
end

function V:GetSnapshot()
    return CopySnapshot(self.snapshot)
end

function V:Start()
    if self.started == true then return true end
    self.started = true
    self:_Publish(self:_Read(), true)
    if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then
        self.started = false
        self:_Publish({ status = "unavailable", visible = false, source = "none", reason = "Scheduler 不可用" }, true)
        return false, "auction surface scheduler unavailable"
    end
    S.Scheduler:RemoveTask(self.taskId)
    local added = S.Scheduler:AddTask(self.taskId, 250, function()
        if V.started == true then V:Refresh("observer") end
    end, false, self.owner, "P2")
    if added ~= true then
        self.started = false
        self:_Publish({ status = "unavailable", visible = false, source = "none", reason = "拍卖窗口观察任务创建失败" }, true)
        return false, "auction surface observer task failed"
    end
    if type(S.Scheduler.SetTaskModule) == "function" then S.Scheduler:SetTaskModule(self.taskId, "tools_auction", true) end
    return true
end

function V:Stop(reason)
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(self.taskId) end
    self.started = false
    return self:_Publish({ status = "stopped", visible = false, source = "none", reason = tostring(reason or "feature_disabled") }, true)
end

function V:Describe()
    return {
        version = self.version,
        visibilityContractVersion = self.VisibilityContractVersion,
        started = self.started == true,
        revision = tonumber(self.revision) or 0,
        topic = self.topic,
        snapshot = self:GetSnapshot(),
    }
end
