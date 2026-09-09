------------------------------------------------------------------------
-- Replicated Suite - RSUI Popup Positioning Authority v2 -- 中文维护注释：v2 使用 Suite-owned Diff cache 完整父链作为首选锚点，外部 Native 才进入 Effective Geometry 校准。
--
-- Detached UIParent popups (Dropdown / ColorField / Tooltip fallback /
-- ContextMenu) MUST NOT derive their screen position by hand from a child
-- widget's local x/y or by blindly dividing GetEffectiveOffset() by uiScale.
--
-- RU clients have exposed WidgetBase effective geometry in both already-logical
-- and UI-scaled units depending on client/UI-size combinations.  The old popup
-- path divided by uiScale unconditionally, so a trigger that was already in
-- logical space was transformed a second time.  The visible symptom is exactly
-- what users reported: the farther the trigger is from the top-left, the larger
-- the popup offset becomes.
--
-- This file is the single Presentation Authority for detached popup placement:
--   Anchor native geometry -> Layout viewport-logical normalization ->
--   one bounded placement solve -> UIParent anchor.
--
-- It is event-driven only.  No Tick, polling, inventory scan or feature-domain
-- state belongs here.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI, RSUI, Layout = S.UI, S.RSUI, S.Layout
if type(UI) ~= "table" or type(RSUI) ~= "table" or type(Layout) ~= "table" then return end

RSUI.PopupPositioningContractVersion = 3 -- 中文维护注释：.18.191 将 Suite-owned detached Popup 的最终定位 Authority 升级为“Native Window 直接相对 Trigger 锚定”，不再依赖插件反推屏幕绝对坐标。
RSUI.PopupNativeRelativeAnchorContractVersion = 1 -- 中文维护注释：该契约要求 Dropdown/ColorField/目标型 Tooltip/ContextMenu 使用 Native AddAnchor 相对触发控件定位，并由 CorrectOffsetByScreen 只处理屏幕边缘。
RSUI.PopupCoordinateSpaceContractVersion = 1 -- 中文维护注释：最终输出仍保持 viewport-logical-v1，因此坐标空间名称不变，仅更换更可靠的锚点来源。
RSUI.PopupSuiteAnchorAuthorityContractVersion = 1 -- 中文维护注释：用于 Foundation/Acceptance 强制要求 Suite-owned Popup 优先走 NativeStateCache 完整父链。

local P = RSUI.PopupPositioning or {
    version = 3, -- 中文维护注释：运行时快照版本升级到 3，用于区分 .18.191 的 Native-relative Popup 定位与旧的绝对坐标求解。
    coordinateSpace = "viewport-logical-v1",
    metrics = {
        resolves = 0,
        flips = 0,
        horizontalClamps = 0,
        verticalClamps = 0,
        shrinks = 0,
        anchorFallbacks = 0,
        nativeRelativeApplies = 0, -- 中文维护注释：统计 Suite-owned Popup 直接相对 Trigger 建立 Native Anchor 的次数，仅在显式打开/重排时增加，不建立后台轮询。
        nativeScreenCorrections = 0, -- 中文维护注释：统计调用 RU CorrectOffsetByScreen 的次数，用于确认屏幕边缘修正是否真正进入 Native 路径。
        nativeScreenCorrectionFailures = 0, -- 中文维护注释：统计 CorrectOffsetByScreen 抛出异常的次数；Native 返回 false 不视为 transport 失败，遵循项目 Boolean Setter/Native 调用语义。
    },
    recent = {},
    recentOrder = {},
    recentLimit = 12,
}
RSUI.PopupPositioning = P -- 中文维护注释：将唯一 Popup Positioning Authority 挂回 RSUI 命名空间，所有 detached Popup Consumer 只能通过这里解析位置。
P.version = 3 -- 中文维护注释：热重载可能复用上一代 PopupPositioning table，因此显式提升到 v3，确保实机诊断能证明当前已加载 .18.191 Native-relative Authority。
P.metrics.nativeRelativeApplies = tonumber(P.metrics.nativeRelativeApplies) or 0 -- 中文维护注释：热重载沿用旧 metrics table 时补齐相对锚定计数器，避免 Snapshot 读取 nil。
P.metrics.nativeScreenCorrections = tonumber(P.metrics.nativeScreenCorrections) or 0 -- 中文维护注释：热重载沿用旧 metrics table 时补齐屏幕修正计数器，保持诊断连续。
P.metrics.nativeScreenCorrectionFailures = tonumber(P.metrics.nativeScreenCorrectionFailures) or 0 -- 中文维护注释：热重载沿用旧 metrics table 时补齐屏幕修正失败计数器，失败证据不会因升级丢失。

local function N(value, fallback)
    value = tonumber(value)
    if value == nil then return tonumber(fallback) or 0 end
    return value
end

local function Clamp(value, minimum, maximum)
    value, minimum, maximum = N(value, minimum), N(minimum, 0), N(maximum, minimum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function CopyRect(rect)
    if type(rect) ~= "table" then return nil end
    local x, y = tonumber(rect.x), tonumber(rect.y)
    local w, h = tonumber(rect.width), tonumber(rect.height)
    if x == nil or y == nil or w == nil or h == nil then return nil end
    return {
        x = x, y = y,
        width = math.max(1, w), height = math.max(1, h),
        right = x + math.max(1, w), bottom = y + math.max(1, h),
        coordinateSpace = tostring(rect.coordinateSpace or "viewport-logical-v1"),
        source = rect.source,
    }
end

local function ResolveNative(target)
    if RSUI:IsComponent(target) then return target:GetRoot(), target end
    if type(target) == "table" then return target, nil end
    return nil, nil
end

local function ReadNativePopupGeometry(widget) -- 中文维护注释：只在用户显式打开 Popup 的低频路径读取 Native 几何，用于诊断 .18.191 的真实相对锚定结果，禁止放入 Tick/Observer。
    local row = {} -- 中文维护注释：每次采样只构造一个有界小表，最多随 PopupPositioning recentLimit 保留 12 条，不形成长期增长。
    if widget == nil then return row end -- 中文维护注释：目标为空时返回空诊断事实，不尝试猜测坐标或访问 Native 方法。
    if type(widget.GetOffset) == "function" then pcall(function() row.offsetX, row.offsetY = widget:GetOffset() end) end -- 中文维护注释：记录 RU UIBounds:GetOffset 原始返回值，不做 uiScale 变换，作为实机原始证据。
    if type(widget.GetExtent) == "function" then pcall(function() row.extentW, row.extentH = widget:GetExtent() end) end -- 中文维护注释：记录 GetExtent 原始尺寸，用于判断顶层 Window 与普通子控件是否采用不同单位。
    if type(widget.GetEffectiveOffset) == "function" then pcall(function() row.effectiveX, row.effectiveY = widget:GetEffectiveOffset() end) end -- 中文维护注释：记录 EffectiveOffset 原始值，仅用于诊断对比，绝不再作为 Suite-owned Popup 定位 Authority。
    if type(widget.GetEffectiveExtent) == "function" then pcall(function() row.effectiveW, row.effectiveH = widget:GetEffectiveExtent() end) end -- 中文维护注释：记录 EffectiveExtent 原始值，便于确认 RU 客户端是否对不同 Widget 类型应用额外缩放。
    row.logicalId = tostring(widget.rsNativeLogicalId or widget.rsUiLogicalId or widget.rsUiOwner or "?") -- 中文维护注释：附带 Suite 逻辑身份，实机报告可直接知道采样的是哪个 Trigger/Popup，而不是只看到四个数字。
    return row -- 中文维护注释：返回原始 Native 几何事实；调用方只负责格式化，不对这些值做业务判断。
end -- 中文维护注释：结束低频 Native Popup 几何采样 helper。

function P:_TouchRecentId(id) -- 中文维护注释：统一维护 Popup 诊断 recent 的有界 LRU 顺序，Native-relative 与绝对坐标两条车道共享同一 12 条上限。
    id = tostring(id or "popup") -- 中文维护注释：所有无显式 ID 的 Popup 统一归入 popup，避免 nil key 破坏有界表。
    if self.recent[id] == nil then self.recentOrder[#self.recentOrder + 1] = id end -- 中文维护注释：只有第一次出现该 ID 才加入顺序表，重复打开只覆盖最新事实。
    while #self.recentOrder > math.max(1, tonumber(self.recentLimit) or 12) do local oldest = table.remove(self.recentOrder, 1); self.recent[oldest] = nil end -- 中文维护注释：超过上限立即淘汰最旧 Popup，诊断不允许随玩家长期使用无限增长。
    return id -- 中文维护注释：返回归一后的 ID，供记录函数写入同一个 recent 槽位。
end -- 中文维护注释：结束有界 recent ID 维护 helper。

function P:ApplyNativeRelativePopup(popup, target, owner, options) -- 中文维护注释：这是 .18.191 Suite-owned detached Popup 的最终定位入口，Native Window 直接相对 Trigger 锚定，彻底绕开绝对屏幕坐标反推。
    options = type(options) == "table" and options or {} -- 中文维护注释：缺省参数归一为空表，保持所有调用点 fail-safe 且不依赖外部可变表。
    local targetNative = select(1, ResolveNative(target)) -- 中文维护注释：只取得触发器真实 Native 根；Component 仅作为逻辑包装，不参与后续坐标计算。
    if popup == nil or targetNative == nil then return false, "popup_native_relative_target_unavailable" end -- 中文维护注释：Popup 或 Trigger 缺失时无法建立原生 Anchor，必须 fail-closed，禁止回退魔法偏移。
    local width = math.max(1, N(options.width, 1)) -- 中文维护注释：Popup 宽度使用 Consumer 已经 Measure/Resolve 的逻辑尺寸，不从 RU Getter 反推。
    local height = math.max(1, N(options.height, 1)) -- 中文维护注释：Popup 高度使用 Consumer 已经 Measure/Resolve 的逻辑尺寸，保证列表行高与组件布局一致。
    local triggerWidth = math.max(1, N(options.triggerWidth, 1)) -- 中文维护注释：Trigger 宽度由调用组件自身 lastLayout 提供，因此不受 GetEffectiveExtent 单位差异影响。
    local triggerHeight = math.max(1, N(options.triggerHeight, 1)) -- 中文维护注释：Trigger 高度同样由组件布局事实提供，是 bottom/right 相对偏移的唯一尺寸 Authority。
    local gap = math.max(0, N(options.gap, 2)) -- 中文维护注释：相对间距属于纯 Presentation token，默认 2 逻辑像素，不与分辨率比例相乘。
    local placement = tostring(options.placement or "bottom-start") -- 中文维护注释：placement 只决定 Trigger-local 偏移方向，不再产生 UIParent 绝对坐标。
    local relativeX, relativeY = N(options.offsetX, 0), triggerHeight + gap -- 中文维护注释：默认把 Popup 左边缘与 Trigger 左边缘对齐，并紧贴 Trigger 下方。
    if placement == "top-start" then relativeY = -(height + gap) elseif placement == "right-start" then relativeX, relativeY = triggerWidth + gap, 0 end -- 中文维护注释：顶部/右侧 Popup 仍只使用 Trigger-local 偏移，Native Anchor 系统负责父链、Shell、Scroll 与 UI Scale。
    local extentOk, _, extentErr = UI:EnsureExtent(popup, width, height, owner) -- 中文维护注释：先事务式提交 Popup 尺寸；Native 拒绝时不允许继续发布错误锚点。
    if extentOk ~= true then return false, "popup_native_relative_extent_failed:" .. tostring(extentErr or "unknown") end -- 中文维护注释：尺寸事务失败立即返回真实原因，不显示尺寸未知的顶层 Window。
    if type(UI.InvalidateNativeState) == "function" then UI:InvalidateNativeState(popup, "anchorParent") end -- 中文维护注释：CorrectOffsetByScreen 可能在 Native 内部改写顶层 Window 的最终偏移；每次显式打开前只失效 Anchor 父字段，强制重新建立相对 Trigger Anchor，避免 Diff cache 把合法 Native 边缘修正误判为外部写入。
    local anchorOk, _, anchorErr = UI:EnsureAnchor(popup, targetNative, relativeX, relativeY, owner) -- 中文维护注释：关键修复：顶层 transient Window 的 Anchor reference 直接使用 Trigger Native，而不是 UIParent + 反推绝对 X/Y。
    if anchorOk ~= true then return false, "popup_native_relative_anchor_failed:" .. tostring(anchorErr or "unknown") end -- 中文维护注释：原生相对锚定失败时必须 fail-closed，禁止自动退回 .18.189/.18.190 的猜测坐标路径。
    popup.rsUiCoordinateLane = "popup-native-relative-v1" -- 中文维护注释：显式标记新坐标 lane，诊断与 Foundation 可区分 Native-relative 与旧 popup-anchor-v1。
    popup.rsUiCoordinateSpace = "native-trigger-relative-v1" -- 中文维护注释：相对 Anchor 不是 viewport absolute 坐标，因此使用独立空间名称，禁止 Consumer 二次做 uiScale/HostOrigin 变换。
    self.metrics.nativeRelativeApplies = N(self.metrics.nativeRelativeApplies) + 1 -- 中文维护注释：记录一次用户触发的相对锚定事务，仅用于诊断覆盖率。
    local id = self:_TouchRecentId(options.id) -- 中文维护注释：取得有界 recent 槽位，重复打开同一 Dropdown 只更新最后一次事实。
    self.recent[id] = { id = id, mode = "native_relative", coordinateSpace = "native-trigger-relative-v1", anchorSource = "native_relative_trigger", placement = placement, relative = { x = relativeX, y = relativeY, width = width, height = height, triggerWidth = triggerWidth, triggerHeight = triggerHeight }, targetNative = ReadNativePopupGeometry(targetNative), popupNativeBeforeCorrection = ReadNativePopupGeometry(popup) } -- 中文维护注释：记录相对偏移与修正前两端 Native 原始值，为下一次 RU 报告提供可直接比对的第一手证据。
    return true, nil, { placement = placement, relativeX = relativeX, relativeY = relativeY, width = width, height = height } -- 中文维护注释：返回已提交的 Trigger-local 几何，调用方只管理行布局/显示生命周期，不再决定屏幕坐标。
end -- 中文维护注释：结束 Native-relative Popup Anchor Authority。

function P:CorrectNativePopupToScreen(popup, id) -- 中文维护注释：Popup 已经相对 Trigger 正确锚定后，仅调用 RU 官方允许的 UIBounds:CorrectOffsetByScreen 处理屏幕边缘，不能拿它替代 Anchor Authority。
    id = tostring(id or "popup") -- 中文维护注释：归一诊断 ID，确保修正后的 Native 结果能写回同一条 Popup 记录。
    if popup == nil then return false, "popup_screen_correction_target_unavailable" end -- 中文维护注释：没有 Popup Native 时无法做边缘修正，直接返回明确错误。
    local corrected = false -- 中文维护注释：默认记录本次没有执行 Native 修正，便于区分客户端缺方法与调用异常。
    if type(popup.CorrectOffsetByScreen) == "function" then local ok = pcall(function() popup:CorrectOffsetByScreen() end); corrected = ok == true; self.metrics.nativeScreenCorrections = N(self.metrics.nativeScreenCorrections) + 1; if ok ~= true then self.metrics.nativeScreenCorrectionFailures = N(self.metrics.nativeScreenCorrectionFailures) + 1 end end -- 中文维护注释：调用 RU 已允许的屏幕修正；只把 Lua/Native 异常视为失败，不把未知 Native 返回值误判为事务拒绝。
    local row = self.recent[id] -- 中文维护注释：读取相同 Popup 的上一阶段记录，把修正后原始 Native 坐标追加进去而不是另建无限日志。
    if type(row) == "table" then row.nativeCorrectionAvailable = type(popup.CorrectOffsetByScreen) == "function"; row.nativeCorrectionOk = corrected; row.popupNativeAfterCorrection = ReadNativePopupGeometry(popup) end -- 中文维护注释：记录修正能力、执行结果和最终 Native Geometry，用户点击诊断按钮即可复制。
    return corrected or type(popup.CorrectOffsetByScreen) ~= "function", corrected and nil or (type(popup.CorrectOffsetByScreen) == "function" and "popup_screen_correction_failed" or nil) -- 中文维护注释：客户端没有该方法时不阻断普通 Popup；方法存在却异常才向调用方报告失败。
end -- 中文维护注释：结束 Native 屏幕边缘修正 helper。

function P:GetViewport(context)
    context = type(context) == "table" and context or (type(Layout.GetContext) == "function" and Layout:GetContext() or nil)
    local width = math.max(1, N(context and context.logicalWidth, 1024))
    local height = math.max(1, N(context and context.logicalHeight, 768))
    local left = math.max(0, N(context and context.safeLeft, 4))
    local top = math.max(0, N(context and context.safeTop, 4))
    local rightMargin = math.max(0, N(context and context.safeRight, 4))
    local bottomMargin = math.max(0, N(context and context.safeBottom, 4))
    return {
        x = left,
        y = top,
        width = math.max(1, width - left - rightMargin),
        height = math.max(1, height - top - bottomMargin),
        right = math.max(left + 1, width - rightMargin),
        bottom = math.max(top + 1, height - bottomMargin),
        viewportWidth = width,
        viewportHeight = height,
        coordinateSpace = "viewport-logical-v1",
    }
end

function P:_Record(id, anchor, result, meta)
    id = tostring(id or "popup")
    if self.recent[id] == nil then
        self.recentOrder[#self.recentOrder + 1] = id
        while #self.recentOrder > math.max(1, tonumber(self.recentLimit) or 12) do
            local oldest = table.remove(self.recentOrder, 1)
            self.recent[oldest] = nil
        end
    end
    self.recent[id] = {
        id = id,
        anchor = CopyRect(anchor),
        result = CopyRect(result),
        placement = meta and meta.placement or nil,
        flipped = meta and meta.flipped == true or false,
        clampedX = meta and meta.clampedX == true or false,
        clampedY = meta and meta.clampedY == true or false,
        visibleRows = meta and tonumber(meta.visibleRows) or nil,
        coordinateSpace = "viewport-logical-v1",
        anchorSource = anchor and anchor.source or nil,
        normalization = meta and meta.normalization or nil,
    }
end

function P:GetSnapshot()
    local rows = {}
    for _, id in ipairs(self.recentOrder) do
        local row = self.recent[id]
        if row ~= nil then rows[#rows + 1] = row end
    end
    return {
        version = tonumber(self.version) or 0,
        contractVersion = tonumber(RSUI.PopupPositioningContractVersion) or 0,
        coordinateSpaceContractVersion = tonumber(RSUI.PopupCoordinateSpaceContractVersion) or 0,
        coordinateSpace = self.coordinateSpace,
        metrics = {
            resolves = N(self.metrics.resolves),
            flips = N(self.metrics.flips),
            horizontalClamps = N(self.metrics.horizontalClamps),
            verticalClamps = N(self.metrics.verticalClamps),
            shrinks = N(self.metrics.shrinks),
            anchorFallbacks = N(self.metrics.anchorFallbacks),
            nativeRelativeApplies = N(self.metrics.nativeRelativeApplies), -- 中文维护注释：输出相对 Trigger 锚定次数，验证实机是否真正进入 .18.191 新路径。
            nativeScreenCorrections = N(self.metrics.nativeScreenCorrections), -- 中文维护注释：输出 Native 屏幕修正调用次数，确认边缘适配是否执行。
            nativeScreenCorrectionFailures = N(self.metrics.nativeScreenCorrectionFailures), -- 中文维护注释：输出 Native 屏幕修正异常次数，异常必须可复制而不能静默。
        },
        recent = rows,
    }
end

-- 中文维护说明：.18.189 已证明“统一调用一个 Effective Geometry 校准函数”仍不足以解决 RU 实机偏移，因为 GetEffectiveOffset 的问题不仅可能是单位不同，还可能包含控件类型/父级语义差异。 -- 中文维护注释：记录真实实机证据，禁止未来再次把 Effective API 当成 Suite-owned Trigger 的首选 Authority。
-- 中文维护说明：Suite-owned Trigger 的位置本来就是由 UI:SetAnchor / UI:SetExtent 写入，NativeStateCache 保存了每一级真实逻辑父链；只要父链完整抵达 UIParent，它比任何反向读取 Native Effective Geometry 都更确定。 -- 中文维护注释：说明为什么 .18.190 改成 cache-first。
function P:ResolveAnchorRect(target) -- 中文维护注释：把 Trigger 解析为 UIParent viewport-logical-v1 锚点；此函数是所有 Dropdown/ColorField/Tooltip/ContextMenu 的统一入口。
    local native, component = ResolveNative(target) -- 中文维护注释：同时保留 Native 根和 RSUI Component 身份，用于区分 Suite-owned 与外部原生控件。
    if native == nil then return nil, "popup_anchor_rect_unavailable" end -- 中文维护注释：没有 Native 根无法建立任何屏幕几何证据，直接 fail-closed。
    local cache = UI and UI.NativeStateCache or nil -- 中文维护注释：读取 Diff Authority 的弱引用状态缓存；这里只读，不新增 Tick，也不修改组件状态。
    local suiteOwned = component ~= nil or (type(cache) == "table" and type(cache[native]) == "table") -- 中文维护注释：RSUI Component 或已被 Diff Authority 管理的 Native 控件都属于 Suite-owned 车道。
    if suiteOwned == true and type(Layout.ResolveSuiteOwnedViewportLogicalRect) == "function" then -- 中文维护注释：Suite-owned Trigger 必须优先使用完整缓存父链，禁止先尝试 Effective Geometry。
        local ok, x, y, w, h, meta = pcall(function() return Layout:ResolveSuiteOwnedViewportLogicalRect(native) end) -- 中文维护注释：有界调用缓存父链 Authority；异常不会逃逸到 Popup Open 事件。
        if ok == true and tonumber(x) ~= nil and tonumber(y) ~= nil and tonumber(w) ~= nil and tonumber(h) ~= nil then -- 中文维护注释：只有完整可证明的逻辑矩形才允许继续显示 Popup。
            return { -- 中文维护注释：构造统一的 viewport-logical-v1 Anchor Rect，后续 Placement 只能做 flip/clamp，不能再次缩放。
                x = tonumber(x), y = tonumber(y), width = math.max(1, tonumber(w)), height = math.max(1, tonumber(h)), -- 中文维护注释：直接使用 Diff Authority 的逻辑位置和尺寸。
                right = tonumber(x) + math.max(1, tonumber(w)), bottom = tonumber(y) + math.max(1, tonumber(h)), -- 中文维护注释：预计算右/下边界供 Dropdown 空间预算与 Clamp 使用。
                coordinateSpace = "viewport-logical-v1", -- 中文维护注释：明确最终锚点已处于 UIParent 逻辑视口坐标，Consumer 不得二次变换。
                source = "suite_native_state_anchor_chain", -- 中文维护注释：实机诊断明确标记本次采用 cache-first Authority。
                normalization = meta, -- 中文维护注释：保留父链深度等只读诊断证据，不参与业务逻辑。
            }, nil -- 中文维护注释：Suite-owned 成功后立即返回，绝不再混入 Effective Geometry 的第二套坐标。
        end -- 中文维护注释：结束完整缓存父链成功分支。
        self.metrics.anchorFallbacks = N(self.metrics.anchorFallbacks) + 1 -- 中文维护注释：缓存父链断裂属于需要关注的异常路径，累计到有界诊断指标。
        return nil, "popup_suite_anchor_chain_unavailable" -- 中文维护注释：Suite-owned 控件父链不完整时直接 fail-closed；禁止退回 Effective API 猜位置，否则会重演 .18.189 实机偏移。
    end -- 中文维护注释：结束 Suite-owned Trigger 车道。
    if type(Layout.ResolveViewportLogicalRect) == "function" then -- 中文维护注释：只有外部原生 Trigger 才允许使用 RU Effective Geometry 校准车道。
        local ok, x, y, w, h, meta = pcall(function() return Layout:ResolveViewportLogicalRect(native) end) -- 中文维护注释：对外部原生控件保留 .18.189 的 bounded effective-unit calibration。
        if ok == true and tonumber(x) ~= nil and tonumber(y) ~= nil and tonumber(w) ~= nil and tonumber(h) ~= nil then -- 中文维护注释：只有有效完整矩形才允许外部原生 Popup 锚定。
            local source = type(meta) == "table" and tostring(meta.source or "") or "external_native_effective" -- 中文维护注释：记录外部原生几何来源，便于与 Suite cache 车道区分。
            self.metrics.anchorFallbacks = N(self.metrics.anchorFallbacks) + 1 -- 中文维护注释：外部原生车道不是默认路径，计入 fallback 方便诊断覆盖率。
            return { -- 中文维护注释：把外部原生解析结果规范成同一 Anchor Rect 结构。
                x = tonumber(x), y = tonumber(y), width = math.max(1, tonumber(w)), height = math.max(1, tonumber(h)), -- 中文维护注释：使用校准后的外部原生逻辑矩形。
                right = tonumber(x) + math.max(1, tonumber(w)), bottom = tonumber(y) + math.max(1, tonumber(h)), -- 中文维护注释：计算边界供 Placement 使用。
                coordinateSpace = "viewport-logical-v1", -- 中文维护注释：外部原生结果也必须统一成 viewport-logical-v1。
                source = source ~= "" and source or "external_native_effective", -- 中文维护注释：保证诊断来源永远非空。
                normalization = meta, -- 中文维护注释：保留 Effective scale、scaleSource、score 等校准证据。
            }, nil -- 中文维护注释：返回外部原生 Anchor Rect。
        end -- 中文维护注释：结束外部原生 Effective Geometry 成功分支。
    end -- 中文维护注释：结束外部原生 Geometry Authority 检查。
    return nil, "popup_anchor_rect_unavailable" -- 中文维护注释：所有可证明坐标来源都失败时拒绝显示 Popup，绝不使用固定偏移或局部坐标猜测。
end -- 中文维护注释：结束统一 Popup Anchor Rect 解析函数。

-- Generic anchor placement.  `preferred` is bottom-start by default.  The
-- solver flips vertically when the preferred side cannot contain the desired
-- popup and the opposite side can (or simply has more room), then clamps the
-- final rect into the safe viewport.  No consumer may apply another scale or
-- host-origin transform after this returns.
function P:ResolveAnchored(anchor, popupWidth, popupHeight, options)
    options = type(options) == "table" and options or {}
    anchor = CopyRect(anchor)
    if anchor == nil then return nil, "popup_anchor_invalid" end
    local viewport = self:GetViewport(options.context)
    local gap = math.max(0, N(options.gap, 2))
    local width = math.max(1, math.min(N(popupWidth, anchor.width), viewport.width))
    local height = math.max(1, math.min(N(popupHeight, 1), viewport.height))
    local preferred = tostring(options.preferred or "bottom-start")
    local alignEnd = preferred:find("end", 1, true) ~= nil or options.align == "end"
    local preferAbove = preferred:find("top", 1, true) ~= nil or options.preferAbove == true

    local belowSpace = math.max(0, viewport.bottom - (anchor.bottom + gap))
    local aboveSpace = math.max(0, (anchor.y - gap) - viewport.y)
    local useAbove = preferAbove
    if preferAbove then
        if height > aboveSpace and belowSpace >= height then useAbove = false
        elseif height > aboveSpace and belowSpace > aboveSpace then useAbove = false end
    else
        if height > belowSpace and aboveSpace >= height then useAbove = true
        elseif height > belowSpace and aboveSpace > belowSpace then useAbove = true end
    end

    local rawX = alignEnd and (anchor.right - width) or anchor.x
    local rawY = useAbove and (anchor.y - gap - height) or (anchor.bottom + gap)
    local x = Clamp(rawX, viewport.x, math.max(viewport.x, viewport.right - width))
    local y = Clamp(rawY, viewport.y, math.max(viewport.y, viewport.bottom - height))
    local clampedX, clampedY = math.abs(x - rawX) > 0.01, math.abs(y - rawY) > 0.01

    self.metrics.resolves = N(self.metrics.resolves) + 1
    if useAbove ~= preferAbove then self.metrics.flips = N(self.metrics.flips) + 1 end
    if clampedX then self.metrics.horizontalClamps = N(self.metrics.horizontalClamps) + 1 end
    if clampedY then self.metrics.verticalClamps = N(self.metrics.verticalClamps) + 1 end

    local result = {
        x = x, y = y, width = width, height = height,
        right = x + width, bottom = y + height,
        coordinateSpace = "viewport-logical-v1",
    }
    local meta = {
        placement = useAbove and "top" or "bottom",
        flipped = useAbove ~= preferAbove,
        clampedX = clampedX,
        clampedY = clampedY,
        belowSpace = belowSpace,
        aboveSpace = aboveSpace,
        normalization = anchor.normalization,
    }
    if options.record ~= false then self:_Record(options.id, anchor, result, meta) end
    return result, nil, meta
end

-- Dropdown specialization: visible row count is derived from the selected side
-- and a viewport-height budget.  This keeps long region lists usable on 768p
-- without creating a screen-sized popup; the existing Dropdown pool/scroll
-- authority remains responsible for row reuse and scrolling.
function P:ResolveDropdown(target, options)
    options = type(options) == "table" and options or {}
    local anchor, anchorErr = self:ResolveAnchorRect(target)
    if anchor == nil then return nil, anchorErr end
    local viewport = self:GetViewport(options.context)
    local rowHeight = math.max(1, N(options.rowHeight, anchor.height))
    local itemCount = math.max(0, math.floor(N(options.itemCount, 0)))
    local maxVisible = math.max(1, math.floor(N(options.maxVisible, 8)))
    local wantedRows = math.max(1, math.min(maxVisible, math.max(1, itemCount)))
    local gap = math.max(0, N(options.gap, 2))
    local below = math.max(0, viewport.bottom - (anchor.bottom + gap))
    local above = math.max(0, (anchor.y - gap) - viewport.y)
    local ratio = Clamp(N(options.maxViewportHeightRatio, 0.60), 0.20, 0.95)
    local viewportBudget = math.max(rowHeight, math.floor(viewport.height * ratio))
    local desiredHeight = wantedRows * rowHeight

    local useAbove = false
    local sideSpace = below
    if desiredHeight > below then
        if desiredHeight <= above or above > below then useAbove, sideSpace = true, above end
    end
    local heightBudget = math.max(rowHeight, math.min(viewportBudget, sideSpace > 0 and sideSpace or viewportBudget))
    local visibleRows = math.max(1, math.min(wantedRows, math.floor(heightBudget / rowHeight)))
    local popupHeight = visibleRows * rowHeight
    if visibleRows < wantedRows then self.metrics.shrinks = N(self.metrics.shrinks) + 1 end

    local desiredWidth = math.max(anchor.width, N(options.popupWidth, anchor.width))
    local result, resolveErr, meta = self:ResolveAnchored(anchor, desiredWidth, popupHeight, {
        id = options.id,
        context = options.context,
        gap = gap,
        preferred = useAbove and "top-start" or "bottom-start",
        record = false, -- Dropdown records once after attaching row/flip evidence.
    })
    if result == nil then return nil, resolveErr end
    -- Dropdown's product preference is always below the trigger.  ResolveAnchored
    -- receives the already-selected side so it can clamp without re-flipping;
    -- restore the user-meaningful flip bit here for diagnostics/acceptance.
    if useAbove == true and meta.flipped ~= true then
        self.metrics.flips = N(self.metrics.flips) + 1
    end
    meta.flipped = useAbove == true
    meta.placement = useAbove and "top" or "bottom"
    meta.visibleRows = visibleRows
    meta.wantedRows = wantedRows
    meta.maxVisible = maxVisible
    meta.itemCount = itemCount
    meta.rowHeight = rowHeight
    meta.normalization = anchor.normalization
    self:_Record(options.id, anchor, result, meta)
    return result, nil, meta
end

function P:ResolvePoint(x, y, popupWidth, popupHeight, options)
    options = type(options) == "table" and options or {}
    x, y = tonumber(x), tonumber(y)
    if x == nil or y == nil then return nil, "popup_point_invalid" end
    local gap = math.max(0, N(options.gap, 8))
    local anchor = {
        x = x, y = y, width = 1, height = 1,
        right = x + 1, bottom = y + 1,
        coordinateSpace = "viewport-logical-v1", source = "logical_point",
    }
    local viewport = self:GetViewport(options.context)
    local width = math.max(1, math.min(N(popupWidth, 1), viewport.width))
    local height = math.max(1, math.min(N(popupHeight, 1), viewport.height))
    local rawX, rawY = x + gap, y + gap
    if rawX + width > viewport.right then rawX = x - width - gap end
    if rawY + height > viewport.bottom then rawY = y - height - gap end
    local px = Clamp(rawX, viewport.x, math.max(viewport.x, viewport.right - width))
    local py = Clamp(rawY, viewport.y, math.max(viewport.y, viewport.bottom - height))
    local result = { x = px, y = py, width = width, height = height, right = px + width, bottom = py + height, coordinateSpace = "viewport-logical-v1" }
    local meta = {
        placement = "point",
        flipped = rawX < x or rawY < y,
        clampedX = math.abs(px - rawX) > 0.01,
        clampedY = math.abs(py - rawY) > 0.01,
    }
    self.metrics.resolves = N(self.metrics.resolves) + 1
    if meta.clampedX then self.metrics.horizontalClamps = N(self.metrics.horizontalClamps) + 1 end
    if meta.clampedY then self.metrics.verticalClamps = N(self.metrics.verticalClamps) + 1 end
    self:_Record(options.id, anchor, result, meta)
    return result, nil, meta
end
