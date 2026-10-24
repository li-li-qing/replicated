------------------------------------------------------------------------
-- Replicated Suite · 战斗视觉引导
-- 作者：Replicated
-- QQ群：1104129461
--
-- 合并约束：先检查冲突标记、toc.g 加载清单完整性与 Lua 语法，再做运行时验收。
-- 权威归属、调用链和存档协议由实现负责，不能通过清配置、跳过加载或恢复 Legacy 绕过错误。
-- 仅负责当前目标连线与用户范围圆的屏幕表现；Feature 持有采样节拍和分离投影，本文件只对有界点池差异渲染，不持有 Tick/Scheduler。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
if type(S.UI) ~= "table" or type(S.FeatureRuntime) ~= "table" then return end
local UnitFeature = S.Features and S.Features.combat_unit_lines or nil
local RangeFeature = S.Features and S.Features.combat_range_assist or nil
if type(UnitFeature) ~= "table" or type(RangeFeature) ~= "table" then return end

S.UIV3 = S.UIV3 or {}
S.UIV3.CombatVisualGuidesV3 = S.UIV3.CombatVisualGuidesV3 or {}
local P = S.UIV3.CombatVisualGuidesV3
P.version = 16
P.RawViewportSamplingContractVersion = 1
P.UnitAnchorAcceptanceContractVersion = 1
P.ScreenCoordinateAuthorityContractVersion = 1
P.UnitLineRawProjectedAnchorContractVersion = 2
P.ScreenToOverlayHostContractVersion = 1
P.ResolutionIndependentOverlayContractVersion = 1
P.UiEnvironmentStyleRecoveryContractVersion = 1
P.ManualPointTypographyContractVersion = 1
P.owner = "v3:combat_visual_guides"
P.unitToken = "presentation:unit_lines"
P.rangeToken = "presentation:range_assist"
P.unitHeld = P.unitHeld == true
P.rangeHeld = P.rangeHeld == true
P.unitHost = P.unitHost or nil
P.rangeHost = P.rangeHost or nil
P.unitPools = P.unitPools or {}
P.unitPool = P.unitPool or {} -- 旧分配字段仅保留用于诊断兼容。
P.rangePools = P.rangePools or {}
P.rangePool = P.rangePool or {} -- 旧首池别名仅保留用于诊断兼容。
P.eventOwner = P.eventOwner or {}
P.hostMetrics = P.hostMetrics or {}
-- 生命周期看门诊断：presenter 通过订阅 Feature 生命周期事件获取渲染租约，下方须覆盖全部失败模式：
-- 失败不能永久静默停留在零 Consumer、零告警的“已开启但
-- 无消费者”状态并等待用户重新切换：
-- a）订阅/握手时序导致漏收事件；b）运行 stop/start 的 Demand:ClearAll 清空租约却无生命周期事件，后续 F:Enable 因 row.enabled=true 无操作；
-- c）获取事务失败且无告警。
P.watchdogTask = P.watchdogTask or "v3_visual_guides_lifecycle_watchdog"
P.lastLifecycle = P.lastLifecycle or nil
P.acquireAttempts = P.acquireAttempts or { unit = 0, range = 0 }
P.lastAcquireError = P.lastAcquireError or {}
P.reconcileRuns = tonumber(P.reconcileRuns) or 0
P.watchdogTicks = tonumber(P.watchdogTicks) or 0

-- 2026-09-06 实机确认 emptywidget + CreateColorDrawable("overlay") 的 4x4 点不可见，且无成功参考。
-- easypull/plates 均以包含 '.' 的 LABEL 绘点；
-- EnsureUnitPairPool/EnsurePool 同样使用 S.UI:CreateLabel，此处保留一个代际的审计标识与外部调用兼容。
local function NewColorDrawable(parent)
    if parent == nil or type(parent.CreateColorDrawable) ~= "function" then return nil end
    local ok, drawable = pcall(function() return parent:CreateColorDrawable(0.96, 0.78, 0.18, 0.8, "overlay") end)
    return ok and drawable or nil
end

function P:EnsureHost(kind)
    local field = kind == "unit" and "unitHost" or "rangeHost"
    local host = self[field]
    if host == nil then
        -- 按 rp_ui.lua EnsureLinesHost/easypull.lua:257 的已验证模型，覆盖宿主必须是实际顶层 WINDOW；
        -- CreatePanel 文档已记录 RU 的根 emptywidget + "system" UILayer 不可靠，会使宿主和全部子点不可见。
        local created, err = S.UI:CreateOverlayWindow("v3_visual_" .. kind .. "_host", self.owner)
        if created == nil then return nil, err end
        host=created; self[field]=host
    end
    return host
end

local UNIT_COLORS = {
    target = {1.00,0.72,0.12}, targettarget = {0.94,0.42,0.20},
    focus = {0.35,0.82,1.00}, focustarget = {0.67,0.52,1.00},
}
-- 从 Feature 投影解析每对颜色覆盖；无颜色的旧 Store 回退硬编码色板，保持渲染。
local function UnitLineColor(projection, pairKey)
    local colors = type(projection) == "table" and projection.colors or nil
    if type(colors) == "table" then
        local c = colors[tostring(pairKey or "")]
        if type(c) == "table" then return c[1], c[2], c[3] end
    end
    local c = UNIT_COLORS[tostring(pairKey or "target")] or UNIT_COLORS.target
    return c[1], c[2], c[3]
end

-- 单位连线自适应采样与平滑刷新契约。
--
-- pointCount/pairPoints 保留为用户基线密度，兼容 Store，不再视为最终点数。先裁切可见屏幕线段，再随长度增加额外样本，使远近连线具有一致连续性；
-- 总预算随节拍调整，限制高刷新率的 Native 工作。
-- 维护 2026-09-12：客户端报告端点y=-3345，旧实现整段分配点并把屏外点计为可见。
-- 只在UIParent:GetScreenWidth/Height同源raw坐标范围裁剪线段，再分配屏内密度。
-- 禁止用GetUiMetrics的logical尺寸或addonScale裁raw坐标；拿不到同源尺寸就保留原坐标。
-- 裁剪是Presentation的可见采样，不修改Feature端点，也不以裁剪代替Service的behind否决。
local UNIT_LINE_REFERENCE_LENGTH = 240
local VISUAL_GUIDE_LIMITS = (S.Constants and S.Constants.VisualGuide) or {}
local UNIT_LINE_DENSITY_HARD_MIN = math.max(2, math.floor(tonumber(VISUAL_GUIDE_LIMITS.unitLineDensityHardMin) or 2))
local UNIT_LINE_PAIR_HARD_CAP = math.max(UNIT_LINE_DENSITY_HARD_MIN, math.floor(tonumber(VISUAL_GUIDE_LIMITS.unitLineDensityHardMax) or 160))
local RANGE_DENSITY_HARD_MAX = math.max(3, math.floor(tonumber(VISUAL_GUIDE_LIMITS.rangeDensityHardMax) or 192))
local UNIT_LINE_TOTAL_BUDGET_FAST = 256
local UNIT_LINE_TOTAL_BUDGET_MEDIUM = 320
local UNIT_LINE_TOTAL_BUDGET_NORMAL = 384
local UNIT_LINE_TOTAL_BUDGET_SLOW = 480
-- 高频单位连线不能在拥挤/帧压力下整体延迟为 P3 突发；生产端保持帧节拍资格，表现层限制自适应额外密度并逐步扩点池，用户基线密度始终为硬下限。
-- 约束（dynamic-hud-1）：取旧Critical档保守上限固定额外点预算，后台积压恢复不能
-- 自动将连线加密近一倍。用户基础密度仍为硬下限，Native点池增长仍受当帧压力约束。
local UNIT_LINE_EXTRA_BUDGET_FACTOR = 0.55
local UNIT_LINE_POOL_GROWTH = { Normal=48, Busy=32, Heavy=24, Critical=16 }

local function UnitLineTotalBudget(refreshMs)
    refreshMs=math.max(1,math.floor(tonumber(refreshMs) or 100))
    if refreshMs <= 16 then return UNIT_LINE_TOTAL_BUDGET_FAST end
    if refreshMs <= 33 then return UNIT_LINE_TOTAL_BUDGET_MEDIUM end
    if refreshMs <= 50 then return UNIT_LINE_TOTAL_BUDGET_NORMAL end
    return UNIT_LINE_TOTAL_BUDGET_SLOW
end

local function UnitLinePressureBudget(baseBudget, totalBase, pressure)
    local pressured=math.floor(math.max(0,tonumber(baseBudget) or 0)*UNIT_LINE_EXTRA_BUDGET_FACTOR)
    return math.max(math.max(0,math.floor(tonumber(totalBase) or 0)),pressured)
end

local function UnitLinePoolGrowthBudget(pressure)
    return UNIT_LINE_POOL_GROWTH[tostring(pressure or "Normal")] or UNIT_LINE_POOL_GROWTH.Normal
end

local function DesiredUnitLinePointCount(length, baseCount)
    baseCount=math.max(UNIT_LINE_DENSITY_HARD_MIN,math.min(UNIT_LINE_PAIR_HARD_CAP,math.floor(tonumber(baseCount) or 24)))
    length=math.max(0,tonumber(length) or 0)
    -- 保持近距外观，baseCount 为下限；参考将旧 24 点映射为约 10.4 逻辑像素间距。
    local spacing=UNIT_LINE_REFERENCE_LENGTH/math.max(1,baseCount-1)
    local adaptive=math.ceil(length/math.max(1,spacing))+1
    return math.max(baseCount,math.min(UNIT_LINE_PAIR_HARD_CAP,adaptive))
end

local function FinitePointNumber(value)
    local n=tonumber(value)
    if n==nil or n~=n or n==math.huge or n==-math.huge then return nil end
    return n
end

function P:ReadUnitViewport()
    -- 维护：视口事实仍由ScreenProjectionV3提供，Presenter只决定可见段如何分配点数。
    -- 服务缺失/异常时不拿Layout logical大小代替，保留旧版raw坐标回退及unknown诊断。
    local service=S.Services and S.Services.ScreenProjectionV3 or nil
    if type(service)~="table" or type(service.GetUiParentViewport)~="function" then return nil,nil end
    local ok,w,h=pcall(service.GetUiParentViewport,service)
    w,h=FinitePointNumber(w),FinitePointNumber(h)
    if not ok or w==nil or h==nil or w<=1 or h<=1 then return nil,nil end
    return w,h
end

local function ClipUnitSegment(x1,y1,x2,y2,w,h)
    -- Liang-Barsky参数裁剪保留原线斜率；不能分别clamp端点(会改变指向)。固定四边，O(1)。
    local dx,dy=x2-x1,y2-y1
    local enter,leave=0,1
    local function Edge(p,q)
        if p==0 then return q>=0 end
        local t=q/p
        if p<0 then if t>leave then return false end;if t>enter then enter=t end
        else if t<enter then return false end;if t<leave then leave=t end end
        return true
    end
    if not Edge(-dx,x1) or not Edge(dx,w-1-x1) or not Edge(-dy,y1) or not Edge(dy,h-1-y1) then return nil end
    return x1+enter*dx,y1+enter*dy,x1+leave*dx,y1+leave*dy,enter>0 or leave<1
end

function P:BuildUnitLineSamplePlan(rows, projection, viewportW, viewportH, pressure)
    rows=type(rows)=="table" and rows or {}
    projection=type(projection)=="table" and projection or {}
    local pairPoints=type(projection.pairPoints)=="table" and projection.pairPoints or {}
    local plans,totalBase,totalDesired={},0,0
    viewportW,viewportH=FinitePointNumber(viewportW),FinitePointNumber(viewportH)
    local known=viewportW~=nil and viewportH~=nil and viewportW>1 and viewportH>1
    local stats={inputEdges=#rows,clippedEdges=0,outsideEdges=0,invalidEdges=0,shortEdges=0,viewportKnown=known}
    for sourceIndex,row in ipairs(rows) do
        if type(row)=="table" then
            local x1,y1,x2,y2=FinitePointNumber(row.x1),FinitePointNumber(row.y1),FinitePointNumber(row.x2),FinitePointNumber(row.y2)
            if x1~=nil and y1~=nil and x2~=nil and y2~=nil and FinitePointNumber(x2-x1) and FinitePointNumber(y2-y1) then
                local clipped=false
                if known then x1,y1,x2,y2,clipped=ClipUnitSegment(x1,y1,x2,y2,viewportW,viewportH) end
                if x1==nil then stats.outsideEdges=stats.outsideEdges+1
                else
                    if clipped then stats.clippedEdges=stats.clippedEdges+1 end
                    local dx,dy=x2-x1,y2-y1
                    local length=FinitePointNumber(math.sqrt(dx*dx+dy*dy))
                    if length==nil then stats.invalidEdges=stats.invalidEdges+1
                    elseif length<1 then stats.shortEdges=stats.shortEdges+1
                    else
                        local base=math.max(UNIT_LINE_DENSITY_HARD_MIN,math.min(UNIT_LINE_PAIR_HARD_CAP,
                            math.floor(tonumber(pairPoints[row.pairKey]) or tonumber(projection.pointCount) or 24)))
                        local desired=DesiredUnitLinePointCount(length,base)
                        local plan={row=row,sourceIndex=sourceIndex,x1=x1,y1=y1,x2=x2,y2=y2,length=length,base=base,desired=desired,count=base,clipped=clipped==true}
                        plans[#plans+1]=plan;totalBase=totalBase+base;totalDesired=totalDesired+desired
                    end
                end
            else stats.invalidEdges=stats.invalidEdges+1 end
        else stats.invalidEdges=stats.invalidEdges+1 end
    end
    local budget=UnitLinePressureBudget(UnitLineTotalBudget(projection.refreshMs),totalBase,pressure)
    if totalDesired <= budget then
        for _,plan in ipairs(plans) do plan.count=plan.desired end
    else
        local remaining=math.max(0,budget-totalBase)
        local totalExtra=math.max(1,totalDesired-totalBase)
        local used=0
        for _,plan in ipairs(plans) do
            local extra=math.max(0,plan.desired-plan.base)
            local add=math.floor((remaining*extra)/totalExtra)
            plan.count=math.min(plan.desired,plan.base+add); used=used+add
        end
        local leftover=math.max(0,remaining-used)
        local index=1
        while leftover>0 and #plans>0 do
            local plan=plans[index]
            if plan.count < plan.desired then plan.count=plan.count+1; leftover=leftover-1 end
            index=index+1; if index>#plans then index=1 end
            local canGrow=false
            for _,candidate in ipairs(plans) do if candidate.count<candidate.desired then canGrow=true; break end end
            if canGrow~=true then break end
        end
    end
    return plans,budget,stats
end

-- 约束（performance-visual-hotpath-1）：只缓存已读端点的纯几何结果，不跳过Feature采样。
-- 逐项比较端点/顺序/密度/视口/压力/间隔，不用revision（每帧都增加），不拼接长签名。
-- 样式不参与采样，命中后仍绑定本次独立row并执行放置/失败重试/点池渐进增长。
function P:GetUnitRenderPlan(rows, projection, viewportW, viewportH, pressure)
    local cache=self.unitRenderPlanCache
    local pairPoints=type(projection.pairPoints)=="table" and projection.pairPoints or {}
    local hit=cache~=nil and cache.count==#rows and cache.width==viewportW and cache.height==viewportH
        and cache.pressure==pressure and cache.refreshMs==projection.refreshMs and cache.pointCount==projection.pointCount
    if hit then
        for i,row in ipairs(rows) do
            local input=cache.inputs[i]
            local valid=type(row)=="table"
            if input.valid~=valid or (valid and (input.x1~=row.x1 or input.y1~=row.y1 or input.x2~=row.x2
                or input.y2~=row.y2 or input.pairKey~=row.pairKey or input.pairPoints~=pairPoints[row.pairKey])) then hit=false;break end
        end
    end
    if hit then
        for _,plan in ipairs(cache.plans) do plan.row=rows[plan.sourceIndex] end
        self.unitPlanReuses=(self.unitPlanReuses or 0)+1
        return cache.plans,cache.budget,cache.stats
    end
    local plans,budget,stats=self:BuildUnitLineSamplePlan(rows,projection,viewportW,viewportH,pressure)
    local inputs={}
    for i,row in ipairs(rows) do
        if type(row)=="table" then inputs[i]={valid=true,x1=row.x1,y1=row.y1,x2=row.x2,y2=row.y2,
            pairKey=row.pairKey,pairPoints=pairPoints[row.pairKey]}
        else inputs[i]={valid=false} end
    end
    self.unitRenderPlanCache={count=#rows,width=viewportW,height=viewportH,pressure=pressure,
        refreshMs=projection.refreshMs,pointCount=projection.pointCount,inputs=inputs,plans=plans,budget=budget,stats=stats}
    self.unitPlanBuilds=(self.unitPlanBuilds or 0)+1
    return plans,budget,stats
end

P.AdaptiveUnitLineSamplingContractVersion = 2
P.UnitLineVisibleSegmentClippingContractVersion = 2
P.UnitLinePressureBudgetContractVersion = 1
P.UnitLineDiffRenderContractVersion = 1
P.RangeDiffRenderContractVersion = 1
P.RangeViewportVisibilityContractVersion = 1
P.UnitLineProgressivePoolContractVersion = 1

-- 维护（2026-09-24，visual-guide-resolution-style-recovery-1）：范围点/连线点虽然使用 LABEL
-- 作为可靠的 RU Native 绘制载体，但它们的 fontSize 语义是“点直径”，不是普通页面字体。
-- CreateLabel 会登记 rsBaseFontSize=15；若继续交给 Theme:RefreshTypography，切分辨率/画质时
-- Theme 会按普通字体 10..24 上限把已配置的 16..82px 点重置成小号。这里明确把 Typography
-- Authority 交给 VisualGuide Presenter；普通 Label 默认仍由 Theme 管理，不扩大 opt-out 范围。
local function AdoptManualPointTypography(widget)
    if widget == nil then return false end
    widget.rsManualTypography = true
    widget.rsVisualGuidePoint = true
    return true
end

local function NativeFontCacheMatches(widget, size)
    local cache = S.UI and S.UI.NativeStateCache or nil
    if type(cache) ~= "table" then return nil end
    local row = cache[widget]
    if type(row) ~= "table" then return false end
    return tonumber(row.fontSize) == tonumber(size)
end

local function InvalidateVisualDot(dot)
    if type(dot) ~= "table" or dot.root == nil then return 0 end
    -- Presenter 与 RSUI 各有一层 diff cache；只清其中一层会让另一层继续把失真的 Native
    -- 状态当成“已应用”。UI 环境边沿是低频事件，因此这里可以一次性清完整 Native cache，
    -- 下一次正常 Feature projection 刷新会重放 anchor/font/color/visible，无需额外 Tick。
    dot.renderState = {}
    if S.UI ~= nil and type(S.UI.InvalidateNativeState) == "function" then
        S.UI:InvalidateNativeState(dot.root)
    end
    AdoptManualPointTypography(dot.root)
    return 1
end

function P:InvalidateVisualDotPresentation(reason)
    local count = 0
    for _, pool in pairs(type(self.unitPools) == "table" and self.unitPools or {}) do
        for _, dot in ipairs(pool) do count = count + InvalidateVisualDot(dot) end
    end
    for _, pool in pairs(type(self.rangePools) == "table" and self.rangePools or {}) do
        for _, dot in ipairs(pool) do count = count + InvalidateVisualDot(dot) end
    end
    self.styleRecoveryCount = (tonumber(self.styleRecoveryCount) or 0) + 1
    self.lastStyleRecovery = { reason = tostring(reason or "ui_environment_changed"), dots = count, at = S.NowMs and S.NowMs() or 0 }
    return count
end

function P:SyncUiEnvironmentRevision()
    local revision, reason = 0, "unknown"
    if S.Layout ~= nil and type(S.Layout.GetUiEnvironmentRevision) == "function" then
        revision, reason = S.Layout:GetUiEnvironmentRevision()
    elseif S.Layout ~= nil then
        revision = tonumber(S.Layout.metricsRevision) or 0
        reason = "metrics_revision_fallback"
    end
    revision = tonumber(revision) or 0
    if self.lastUiEnvironmentRevision == revision then return false end
    local previous = self.lastUiEnvironmentRevision
    self.lastUiEnvironmentRevision = revision
    self:InvalidateVisualDotPresentation("ui_environment:" .. tostring(reason or "unknown") .. ":" .. tostring(previous or "nil") .. ">" .. tostring(revision))
    return true
end

function P:EnsureUnitPairPool(pairKey, count, growthLimit)
    pairKey=tostring(pairKey or "target")
    count=math.max(0,math.min(UNIT_LINE_PAIR_HARD_CAP,math.floor(tonumber(count) or 0)))
    local pool=self.unitPools[pairKey]
    if type(pool)~="table" then pool={}; self.unitPools[pairKey]=pool end
    local host,err=self:EnsureHost("unit"); if host==nil then return nil,err end
    growthLimit=math.max(0,math.floor(tonumber(growthLimit) or count))
    local target=math.min(count,#pool+growthLimit)
    local created=0
    for index=#pool+1,target do
        -- 2026-09-06 实机参考确认绘点应使用单 '.' 字符 LABEL：easypull.lua:262-280 为 22px/SetOutline，rp_ui.lua:2341-2354 为 15px 点池。
        -- 旧 emptywidget + 4x4 drawable 没有成功参考，在 1080p 以上近乎不可见；使用本项目 S.UI:CreateLabel。
        -- 宿主点 extent 保持 1x1，字形大小由字体决定，较大 extent 只会把字形偏离锚点。
        local dot,dotErr=S.UI:CreateLabel(host,"v3_visual_unit_"..pairKey.."_dot_"..tostring(index),".",0,0,1,1,15,"strong","CENTER",false)
        if dot==nil then return nil,dotErr end
        AdoptManualPointTypography(dot)
        local row={root=dot,drawable=nil,label=true,renderState={visible=false}}; pool[index]=row
        S.UI:SetVisible(dot,false,self.owner)
        created=created+1
    end
    return pool,nil,created,#pool>=count
end

function P:SetDotVisible(dot, visible)
    if type(dot)~="table" or dot.root==nil then return false end
    local state=type(dot.renderState)=="table" and dot.renderState or {}; dot.renderState=state
    local value=visible==true
    if state.visible==value then return false end
    -- 维护（2026-09-18，range-diff-render-1）：UnitLines 与 RangeAssist 共用可见性 diff。
    -- 提升范围圆刷新节奏后，禁止每帧对未变化的几十/上百个点重复 Show/Hide；只有 RSUI
    -- 确认 accepted 后才提交缓存，拒绝时保留旧状态供下一帧重试。
    local accepted,changed
    if type(S.UI.EnsureVisible)=="function" then accepted,changed=S.UI:EnsureVisible(dot.root,value,self.owner)
    else accepted=S.UI:SetVisible(dot.root,value,self.owner);changed=accepted end
    if accepted~=true then return false end
    state.visible=value
    return changed==true
end

function P:SetUnitDotVisible(dot, visible)
    return self:SetDotVisible(dot, visible)
end

function P:HideUnitPools()
    for _,pool in pairs(self.unitPools) do
        for _,dot in ipairs(pool) do self:SetUnitDotVisible(dot,false) end
    end
end

function P:EnsurePool(kind, count)
    -- 旧兼容辅助函数仍遵循活跃连线/范围池的真实安全范围，防止未来调用在 Feature 权威层后重新引入废弃 48 点上限。
    local hardCap = kind == "range" and RANGE_DENSITY_HARD_MAX or UNIT_LINE_PAIR_HARD_CAP
    count=math.max(0,math.min(hardCap,math.floor(tonumber(count) or 0)))
    local pool = kind == "unit" and self.unitPool or self.rangePool
    local host, err = self:EnsureHost(kind); if host == nil then return false, err end
    for index=1,count do
        local row=pool[index]
        if type(row)~="table" or row.root==nil then
            -- 使用参考验证的标签点，与 EnsureUnitPairPool 原因相同；easypull/rp_ui 都用 '.' 标签。
            local dot, dotErr = S.UI:CreateLabel(host, "v3_visual_" .. kind .. "_dot_" .. tostring(index), ".", 0, 0, 1, 1, 15, "strong", "CENTER", false)
            if dot == nil then return false, dotErr end
            AdoptManualPointTypography(dot)
            row={root=dot,drawable=nil,label=true}; pool[index]=row
            S.UI:SetVisible(dot, false, self.owner)
        end
    end
    return true
end

function P:HidePool(pool)
    for _,dot in ipairs(pool) do self:SetDotVisible(dot, false) end
end

function P:EnsureRangePool(circleKey, count)
    count = math.max(0, math.min(RANGE_DENSITY_HARD_MAX, math.floor(tonumber(count) or 0)))
    local host, err = self:EnsureHost("range"); if host == nil then return nil, err end
    local key = tostring(circleKey or "default"):gsub("[^%w_]", "_")
    self.rangePools = self.rangePools or {}
    local pool = self.rangePools[key]
    if type(pool) ~= "table" then pool = {}; self.rangePools[key] = pool end
    if self.rangePool == nil or #self.rangePool == 0 then self.rangePool = pool end
    for index = 1, count do
        local row = pool[index]
        if type(row) ~= "table" or row.root == nil then
            local dot, dotErr = S.UI:CreateLabel(host, "v3_visual_range_" .. key .. "_dot_" .. tostring(index), ".", 0, 0, 1, 1, 15, "strong", "CENTER", false)
            if dot == nil then return nil, dotErr end
            AdoptManualPointTypography(dot)
            row = { root = dot, drawable = nil, label = true }; pool[index] = row
            S.UI:SetVisible(dot, false, self.owner)
        end
    end
    return pool
end

function P:HideRangePools(active)
    self.rangePools = self.rangePools or {}
    for key, pool in pairs(self.rangePools) do
        if active == nil or active[key] ~= true then self:HidePool(pool) end
    end
end

local function RangePoolDotCount(rangePools)
    local total = 0
    for _, pool in pairs(type(rangePools) == "table" and rangePools or {}) do total = total + #pool end
    return total
end

local VISUAL_POINT_SIZE_MIN = tonumber(S.Constants and S.Constants.VisualGuide and S.Constants.VisualGuide.pointSizeMin) or 2
local VISUAL_POINT_SIZE_HARD_MAX = tonumber(S.Constants and S.Constants.VisualGuide and S.Constants.VisualGuide.pointSizeHardMax) or 24
local function ResolveVisualPointFontSize(value)
    local setting = math.max(VISUAL_POINT_SIZE_MIN, math.min(VISUAL_POINT_SIZE_HARD_MAX, math.floor(tonumber(value) or 4)))
    -- 保留已验证 2..10 映射（2->16px、10->40px）并单调扩展，不能把全部 >10 值压成 40px。
    return math.max(15, math.floor(10 + setting * 3))
end

function P:ResolveHostTransform(host)
    local context = S.Layout ~= nil and type(S.Layout.GetContext) == "function" and S.Layout:GetContext() or {}
    local transform = {
        screenWidth = tonumber(context.screenWidth), screenHeight = tonumber(context.screenHeight),
        logicalWidth = tonumber(context.logicalWidth), logicalHeight = tonumber(context.logicalHeight),
        uiScale = tonumber(context.uiScale) or 1, addonScale = tonumber(context.addonScale) or 1,
        originX = 0, originY = 0, known = false, source = "identity",
    }
    if S.Layout ~= nil and type(S.Layout.GetUiParentLocalOrigin) == "function" then
        local ok, ox, oy, known = pcall(function() return S.Layout:GetUiParentLocalOrigin(host) end)
        if ok and known == true and tonumber(ox) ~= nil and tonumber(oy) ~= nil then
            transform.originX, transform.originY = tonumber(ox), tonumber(oy)
            transform.known, transform.source = true, "layout_host_origin"
        end
    end
    return transform
end

local function HostLocalPoint(transform, x, y)
    transform = type(transform) == "table" and transform or {}
    return (tonumber(x) or 0) - (tonumber(transform.originX) or 0),
        (tonumber(y) or 0) - (tonumber(transform.originY) or 0)
end

-- 同帧一行的字形大小/透明度只解析一次；本地 helper 只接收已解析样式，
-- 仍逐点执行锚点、Native 字体缓存和显隐检查。旧公开方法保留原参数与直接调用语义。
local function PlacePreparedUnitDot(self, dot, x, y, size, alpha, pairKey, r, g, b, hostTransform)
    -- LABEL 点的颜色/大小通过标签样式设置，不使用 drawable；原因见 EnsureUnitPairPool。
    if type(dot)~="table" or dot.root==nil then return 0,0,0 end
    -- 点大小设置范围为 2..10，但字形需按 rp_ui 参考保持 >=15px 可读；不能将设置值直接钳制为
    -- 字形可读下限，否则大小滑块会变成无操作（“设置没有用”）。
    -- 应使用单调映射：设置 2→16px、4→22、6→28、8→34、10→40。
    local cr,cg,cb=r,g,b
    if cr==nil then
        local c=UNIT_COLORS[tostring(pairKey or "target")] or UNIT_COLORS.target
        cr,cg,cb=c[1],c[2],c[3]
    end
    local state=type(dot.renderState)=="table" and dot.renderState or {}; dot.renderState=state
    -- 单位线点是 1x1 LABEL 锚点，字形大小由 TextStyle 决定；rp_ui 直接锚在投影单位点。不能减去半字体大小，否则每个点会向左上偏约 8..41px 而错过头顶中心；
    -- 原始投影坐标保持权威，字体只改变墨迹大小。
    local localX, localY = HostLocalPoint(hostTransform, x, y)
    local px=math.floor(localX+0.5)
    local py=math.floor(localY+0.5)
    local anchorWrites,styleWrites,visibilityWrites=0,0,0
    -- RSUI setter 的 false 同时表示拒绝和无变化；
    -- CreateLabel 经 PrimeNativeState 预设 row.fontSize=15，因此 SetFontSize(15) 可合法返回无操作 false。
    -- 不能在显示前据此退出而使所有点永久隐藏在 (0,0)；样式写入按成功参考尽力执行，不妨碍点显现。
    if state.x~=px or state.y~=py then
        -- 维护：旧代码无条件提交anchor缓存，一次拒绝后相同坐标永不重试、点卡在旧位置。
        -- Authority=RSUI EnsureAnchor确认结果；失败隐藏当前点，保留未提交cache供下一帧重试。
        -- 不引入新重试任务、不动用户位置配置；共享range绘制不受此分支影响。
        local accepted,changed
        if type(S.UI.EnsureAnchor)=="function" then accepted,changed=S.UI:EnsureAnchor(dot.root,self.unitHost,px,py,self.owner)
        else accepted=S.UI:SetAnchor(dot.root,self.unitHost,px,py,self.owner);changed=accepted end
        if accepted~=true then self:SetUnitDotVisible(dot,false);return 0,0,0,false end
        state.x,state.y=px,py;anchorWrites=changed==true and 1 or 0
    end
    local nativeFontMatches = NativeFontCacheMatches(dot.root, size)
    if state.size~=size or nativeFontMatches == false then
        -- 本地 renderState 与 RSUI NativeStateCache 必须同时命中才允许跳过。Theme/外部 UI
        -- 环境若改写过 Native fontSize，RSUI cache 会暴露差异；环境 revision 失效则两层都清空。
        S.UI:SetFontSize(dot.root,size,self.owner)
        state.size=size; styleWrites=styleWrites+1
    end
    if state.r~=cr or state.g~=cg or state.b~=cb or state.a~=alpha then
        S.UI:SetColor(dot.root,cr,cg,cb,alpha,self.owner)
        state.r,state.g,state.b,state.a=cr,cg,cb,alpha; styleWrites=styleWrites+1
    end
    if self:SetUnitDotVisible(dot,true) then visibilityWrites=1 end
    return anchorWrites,styleWrites,visibilityWrites,state.visible==true
end

function P:PlaceUnitDot(dot, x, y, size, opacity, pairKey, r, g, b, hostTransform)
    if type(dot)~="table" or dot.root==nil then return 0,0,0 end
    return PlacePreparedUnitDot(self,dot,x,y,ResolveVisualPointFontSize(size),
        math.max(0.1,math.min(1,tonumber(opacity) or 0.78)),pairKey,r,g,b,hostTransform)
end

local function PlacePreparedRangeDot(self, dot, x, y, size, alpha, kind, pairKey, r, g, b, hostTransform)
    if type(dot)~="table" or dot.root==nil then return false end
    local localX, localY = HostLocalPoint(hostTransform, x, y)
    local px,py=math.floor(localX+0.5),math.floor(localY+0.5)
    local cr,cg,cb=r or 0.20,g or 0.82,b or 1.00
    local state=type(dot.renderState)=="table" and dot.renderState or {};dot.renderState=state
    local host=kind=="unit" and self.unitHost or self.rangeHost

    -- 维护（2026-09-18，range-diff-render-1）：RangeAssist 提升镜头跟随节奏后，不能继续每帧对
    -- 每个点无条件 SetAnchor/SetFontSize/SetColor/Show。位置、样式、可见性分别做 diff；Anchor
    -- 只有 RSUI 确认 accepted 后才提交缓存，失败保留旧 cache 以便下一帧重试。用户半径/颜色等
    -- 配置仍由 Feature Authority 提供；这里只减少重复 Native UI 写，不缓存世界或屏幕事实。
    if state.x~=px or state.y~=py then
        local accepted,changed
        if type(S.UI.EnsureAnchor)=="function" then accepted,changed=S.UI:EnsureAnchor(dot.root,host,px,py,self.owner)
        else accepted=S.UI:SetAnchor(dot.root,host,px,py,self.owner);changed=accepted end
        if accepted~=true then self:SetDotVisible(dot,false);return false end
        state.x,state.y=px,py
    end
    local nativeFontMatches = NativeFontCacheMatches(dot.root, size)
    if state.size~=size or nativeFontMatches == false then S.UI:SetFontSize(dot.root,size,self.owner);state.size=size end
    if state.r~=cr or state.g~=cg or state.b~=cb or state.a~=alpha then
        S.UI:SetColor(dot.root,cr,cg,cb,alpha,self.owner)
        state.r,state.g,state.b,state.a=cr,cg,cb,alpha
    end
    self:SetDotVisible(dot,true)
    -- 维护（range-continuity-1）：Show 被拒绝时不能把请求点计为已接受的可见点。
    return state.visible==true
end

function P:PlaceDot(dot, x, y, size, opacity, kind, pairKey, r, g, b, hostTransform)
    if type(dot)~="table" or dot.root==nil then return false end
    return PlacePreparedRangeDot(self,dot,x,y,ResolveVisualPointFontSize(size),
        math.max(0.1,math.min(1,tonumber(opacity) or 0.68)),kind,pairKey,r,g,b,hostTransform)
end

-- ScreenProjectionV3 已返回 OverlayWindow 子锚点使用的左上 UIParent 屏幕坐标；addonScale 是布局大小偏好，不能作世界/屏幕转换。
-- 表现按 1:1 使用 x/y，避免 2560x1440 下随原点距离放大偏移；投影/校准权威均归 ScreenProjectionV3。

function P:RenderUnit()
    self:SyncUiEnvironmentRevision()
    -- 维护：先清本帧telemetry再处理空集/关闭，否则上次“176点”在目标消失后仍被报告为可见。
    -- 无跨帧单位缓存；仅有界Native池复用，禁用时隐藏且Feature释放自己的刷新任务。
    self.lastUnitSampling={inputEdges=0,visibleEdges=0,visibleDots=0,uniquePositions=0,requestedDots=0,clippedEdges=0,outsideEdges=0,invalidEdges=0}
    if self.unitHeld ~= true then self.unitRenderPlanCache=nil;self:HideUnitPools();S.UI:SetVisible(self.unitHost,false,self.owner);return true end
    local projection=(type(UnitFeature.GetRenderProjection)=="function" and UnitFeature:GetRenderProjection()
        or UnitFeature:GetProjection()) or {}; local rows=type(projection.rows)=="table" and projection.rows or {}
    if #rows==0 then
        self.unitRenderPlanCache=nil
        self:HideUnitPools()
        S.UI:SetVisible(self.unitHost,false,self.owner)
        return true
    end
    local pairSizes = type(projection.pairSizes) == "table" and projection.pairSizes or {}
    local pressure="Normal"
    if type(S.FrameBudget)=="table" and type(S.FrameBudget.current)=="table" then pressure=tostring(S.FrameBudget.current.pressure or "Normal") end
    local viewportW,viewportH=self:ReadUnitViewport()
    local plans,budget,sampleStats=self:GetUnitRenderPlan(rows,projection,viewportW,viewportH,pressure)
    local hostTransform=self:ResolveHostTransform(self.unitHost)
    local active={}
    local visibleDots,requestedDots,placementFailures=0,0,0
    local anchorWrites,styleWrites,visibilityWrites,poolGrowth=0,0,0,0
    local uniqueSeen={}
    local uniquePositions=0
    -- px/py 在下方经 floor 得到整数。仅已知小视口的非负有界点用精确数字键；
    -- 32769 进制在 0..32768 两轴内无冲突且远低于 Lua number 的整数精度上限。
    -- 未知视口/超大分辨率/越界点仍保留原字符串语义，不缓存或更改实时坐标。
    local numericUnique=sampleStats.viewportKnown and viewportW<=32768 and viewportH<=32768
    local growthRemaining=UnitLinePoolGrowthBudget(pressure)
    local remainingPlans=#plans
    for planIndex,plan in ipairs(plans) do
        local row=plan.row
        local key=tostring(row.pairKey or row.key or "target"):gsub("[^%w_]","_")
        local requested=math.max(2,math.min(UNIT_LINE_PAIR_HARD_CAP,math.floor(tonumber(plan.count) or 2)))
        requestedDots=requestedDots+requested
        local size=math.max(VISUAL_POINT_SIZE_MIN,math.min(VISUAL_POINT_SIZE_HARD_MAX,math.floor(tonumber(pairSizes[row.pairKey]) or tonumber(projection.pointSize) or 4)))
        local cr,cg,cb=UnitLineColor(projection,row.pairKey)
        -- 逐帧扩池预算在剩余连线对间分配，不能让首池耗尽；四对连线时先到先得会让 2..4 池饥饿多帧，Critical 压力下可达十帧而只见一条线。
        local growthShare=math.max(8,math.floor(growthRemaining/math.max(1,remainingPlans)))
        local pool,err,created=self:EnsureUnitPairPool(key,requested,math.min(growthRemaining,growthShare)); if pool==nil then return false,err end
        created=math.max(0,tonumber(created) or 0); growthRemaining=math.max(0,growthRemaining-created); poolGrowth=poolGrowth+created
        remainingPlans=math.max(0,remainingPlans-1)
        local count=math.min(requested,#pool)
        active[key]=true
        local preparedFontSize=ResolveVisualPointFontSize(size)
        local preparedAlpha=math.max(0.1,math.min(1,tonumber(projection.opacity) or 0.78))
        for i=1,count do
            local t=(i-1)/math.max(1,count-1)
            local px=math.floor((plan.x1+(plan.x2-plan.x1)*t)+0.5)
            local py=math.floor((plan.y1+(plan.y2-plan.y1)*t)+0.5)
            local aw,sw,vw,placed=PlacePreparedUnitDot(self,pool[i],px,py,preparedFontSize,preparedAlpha,key,cr,cg,cb,hostTransform)
            anchorWrites=anchorWrites+(tonumber(aw) or 0); styleWrites=styleWrites+(tonumber(sw) or 0); visibilityWrites=visibilityWrites+(tonumber(vw) or 0)
            -- 计数Native确认的可显示点而不是池容量；失败点不冒充“可见”。
            if placed==true then
                visibleDots=visibleDots+1
                local uk
                if numericUnique and px>=0 and py>=0 and px<=32768 and py<=32768 then uk=py*32769+px
                else uk=tostring(px)..","..tostring(py) end
                if uniqueSeen[uk]~=true then uniqueSeen[uk]=true;uniquePositions=uniquePositions+1 end
            else placementFailures=placementFailures+1 end
        end
        for i=count+1,#pool do if self:SetUnitDotVisible(pool[i],false) then visibilityWrites=visibilityWrites+1 end end
    end
    for key,pool in pairs(self.unitPools) do
        if active[key]~=true then for _,dot in ipairs(pool) do if self:SetUnitDotVisible(dot,false) then visibilityWrites=visibilityWrites+1 end end end
    end
    -- 参考模型：有连线时显示宿主窗口，并在 Suite 表面中抬升（rp_ui.lua UpdateLinesView host Show/Raise）。
    S.UI:SetVisible(self.unitHost,#plans>0,self.owner)
    self.lastUnitSampling={budget=budget,pressure=pressure,visibleEdges=#plans,requestedDots=requestedDots,
        inputEdges=sampleStats.inputEdges,clippedEdges=sampleStats.clippedEdges,outsideEdges=sampleStats.outsideEdges,
        invalidEdges=sampleStats.invalidEdges,shortEdges=sampleStats.shortEdges,viewportKnown=sampleStats.viewportKnown,
        viewportWidth=viewportW,viewportHeight=viewportH,viewportSource=sampleStats.viewportKnown and "ui_parent_screen" or "unknown",
        placementFailures=placementFailures,visibleDots=visibleDots,poolGrowth=poolGrowth,anchorWrites=anchorWrites,styleWrites=styleWrites,visibilityWrites=visibilityWrites,
        uniquePositions=uniquePositions,coordinateSpace="ui_parent_screen_to_host_local",
        hostOriginX=tonumber(hostTransform.originX) or 0,hostOriginY=tonumber(hostTransform.originY) or 0,hostTransformSource=tostring(hostTransform.source or "identity"),
        logicalWidth=tonumber(hostTransform.logicalWidth),logicalHeight=tonumber(hostTransform.logicalHeight),uiScale=tonumber(hostTransform.uiScale) or 1,
        firstRow=(plans[1]~=nil) and (tostring(math.floor(plans[1].x1))..","..tostring(math.floor(plans[1].y1)).."->"..tostring(math.floor(plans[1].x2))..","..tostring(math.floor(plans[1].y2))) or nil}
    return true
end

function P:RenderRange()
    -- 维护（range-continuity-1）：每帧先清证据。空集/异常不能沿用上一帧“可见点”；
    -- 记录的是本次 Native 已接受的放置数，不是屏幕截图验证，更不是池容量。
    local sample = { points=0, circles=0, requestedPoints=0, placementFailures=0, totalCircles=0, enabledCircles=0,
        offscreenPoints=0, invalidPoints=0, visibilityPatch="range-viewport-visibility-1",
        status="rendering", frameAtMs=(S.NowMs and S.NowMs() or 0) }
    self.lastRangeSampling = sample
    self:SyncUiEnvironmentRevision()
    if self.rangeHeld ~= true then
        self:HideRangePools(); S.UI:SetVisible(self.rangeHost,false,self.owner); sample.status="no_consumer"; return true
    end
    -- 约束（performance-hotpath-1）：范围绘制只消费独立坐标/样式快照，完整页面投影
    -- 保留给设置与诊断；不用Authority裸引用，旧宿主兼容仍可回退原GetProjection。
    local projection=(type(RangeFeature.GetRenderProjection)=="function" and RangeFeature:GetRenderProjection()
        or RangeFeature:GetProjection()) or {}; local rows=type(projection.rows)=="table" and projection.rows or {}
    sample.totalCircles, sample.enabledCircles = tonumber(projection.circleCount) or 0, tonumber(projection.enabledCircleCount) or 0
    sample.status = tostring(projection.status or "ready")
    if #rows<1 then self:HideRangePools(); S.UI:SetVisible(self.rangeHost,false,self.owner); return true end
    local viewportW,viewportH=FinitePointNumber(projection.viewportWidth),FinitePointNumber(projection.viewportHeight)
    if viewportW==nil or viewportH==nil or viewportW<=1 or viewportH<=1 then viewportW,viewportH=self:ReadUnitViewport() end
    sample.viewportKnown=viewportW~=nil and viewportH~=nil
    sample.viewportWidth,sample.viewportHeight=viewportW,viewportH
    local active, renderedCircles, totalDots = {}, 0, 0
    local hostTransform=self:ResolveHostTransform(self.rangeHost)
    local firstPoint = "?"
    for _, row in ipairs(rows) do
        local points=type(row)=="table" and type(row.points)=="table" and row.points or {}
        if #points>=3 then
            local circleKey=tostring(row.circleKey or row.key or ("range_" .. tostring(renderedCircles + 1)))
            local count=math.min(RANGE_DENSITY_HARD_MAX,#points)
            sample.requestedPoints = sample.requestedPoints + count
            local pool, err = self:EnsureRangePool(circleKey, count)
            if pool == nil then
                self:HideRangePools(); S.UI:SetVisible(self.rangeHost,false,self.owner)
                sample.status, sample.lastError = "unavailable", tostring(err or "range_pool_unavailable")
                return false, err
            end
            active[circleKey:gsub("[^%w_]", "_")] = true
            local color = type(row.color)=="table" and row.color or nil
            local rr,rg,rb = color and (tonumber(color[1]) or 0.20) or 0.20, color and (tonumber(color[2]) or 0.82) or 0.82, color and (tonumber(color[3]) or 1.00) or 1.00
            local acceptedCount = 0
            local preparedFontSize=ResolveVisualPointFontSize(row.pointSize or projection.pointSize)
            local preparedAlpha=math.max(0.1,math.min(1,tonumber(row.opacity or projection.opacity) or 0.68))
            for i=1,count do
                local px,py=FinitePointNumber(points[i].x),FinitePointNumber(points[i].y)
                -- 维护（2026-10-07，range-viewport-visibility-1）：R22 大圈比近镜头距离更大时，
                -- 部分点会跨过镜头平面，附近点虽在前方却会得到7425等屏外坐标。只显示本帧
                -- 可见范围弧段，不把屏外坐标写入Native、不夹到屏幕边缘、不改世界半径。
                if px==nil or py==nil then
                    self:SetDotVisible(pool[i],false);sample.invalidPoints=sample.invalidPoints+1
                elseif sample.viewportKnown and (px<0 or py<0 or px>viewportW or py>viewportH) then
                    self:SetDotVisible(pool[i],false);sample.offscreenPoints=sample.offscreenPoints+1
                elseif PlacePreparedRangeDot(self,pool[i],px,py,preparedFontSize,preparedAlpha,"range",nil,rr,rg,rb,hostTransform)==true then
                    acceptedCount = acceptedCount + 1
                    if firstPoint == "?" then firstPoint = tostring(math.floor(tonumber(points[i].x) or 0)) .. "," .. tostring(math.floor(tonumber(points[i].y) or 0)) end
                else sample.placementFailures = sample.placementFailures + 1 end
            end
            for i=count+1,#pool do self:SetDotVisible(pool[i],false) end
            if acceptedCount > 0 then renderedCircles = renderedCircles + 1 end
            totalDots = totalDots + acceptedCount
        end
    end
    self:HideRangePools(active)
    local hostAccepted = true
    if type(S.UI.EnsureVisible)=="function" then hostAccepted=S.UI:EnsureVisible(self.rangeHost,renderedCircles>0,self.owner)
    else S.UI:SetVisible(self.rangeHost,renderedCircles>0,self.owner) end
    local hostVisible, hostKnown = nil, false
    if type(S.UI.NativeVisibleReadback) == "function" then hostVisible, hostKnown = S.UI:NativeVisibleReadback(self.rangeHost) end
    if hostAccepted ~= true or (hostKnown == true and hostVisible ~= true) then
        totalDots, renderedCircles = 0, 0
        if sample.requestedPoints > 0 then sample.lastError="range_host_not_visible" end
    end
    sample.points, sample.circles, sample.first = totalDots, renderedCircles, firstPoint
    sample.coordinateSpace = "ui_parent_screen_to_host_local"
    sample.hostOriginX, sample.hostOriginY = tonumber(hostTransform.originX) or 0, tonumber(hostTransform.originY) or 0
    sample.hostTransformSource = tostring(hostTransform.source or "identity")
    sample.logicalWidth, sample.logicalHeight, sample.uiScale = tonumber(hostTransform.logicalWidth), tonumber(hostTransform.logicalHeight), tonumber(hostTransform.uiScale) or 1
    sample.hostVisible = hostKnown == true and tostring(hostVisible == true) or "未知"
    if sample.placementFailures > 0 or sample.invalidPoints > 0 or sample.lastError ~= nil then sample.status = "partial" end
    return true
end

function P:ReconcileOne(feature,id,token,heldField,kind)
    local enabled=S.FeatureRuntime:IsEnabled(id)==true
    if not enabled then
        if kind=="unit" then
            self:HideUnitPools();S.UI:SetVisible(self.unitHost,false,self.owner)
            -- 禁用路径不再报告上一次已显示采样，不创建/销毁range的资源。
            self.lastUnitSampling={inputEdges=0,visibleEdges=0,visibleDots=0,uniquePositions=0,requestedDots=0}
        else self:HideRangePools(); S.UI:SetVisible(self.rangeHost,false,self.owner); self.lastRangeSampling={points=0,circles=0,totalCircles=0,enabledCircles=0} end
        if self[heldField]==true then
            -- 维护：Feature:Disable已先Demand:Clear，旧代码再次Release得到consumer not held，
            -- 使Presenter的held标记无法收敛。租约Authority在Demand；确认已无此token即可清本地影子。
            -- 仍持有时必须真实释放并检查结果；无HasConsumer的旧实现保留原保守路径。
            local alreadyReleased=type(feature.HasConsumer)=="function" and feature:HasConsumer(token)~=true
            if not alreadyReleased then
                local ok,err=feature:ReleaseConsumer(token);if ok~=true then return false,err end
            end
            self[heldField]=false
        end
        return true
    end
    -- 租约失配必须自愈：ClearAll/ForceQuiesce 可无生命周期事件清空租约，后续 F:Enable 因 row.enabled 无操作也不发布；否则 presenter 会误认仍持有
    -- 失效租约，形成“已开启但无消费者 + 零告警”的实机现象。
    if self[heldField]==true and type(feature.HasConsumer)=="function" and feature:HasConsumer(token)~=true then
        self[heldField]=false
    end
    local acquiredNow=false
    if self[heldField]~=true then
        self.acquireAttempts=self.acquireAttempts or {}
        self.acquireAttempts[kind]=(tonumber(self.acquireAttempts[kind]) or 0)+1
        local ok,err=feature:AcquireConsumer(token)
        if ok~=true then
            self.lastAcquireError=self.lastAcquireError or {}
            self.lastAcquireError[kind]={ error=tostring(err or "unknown"), at=(S.NowMs and S.NowMs() or 0) }
            if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.WarnRateLimited) == "function" then
                S.DiagnosticsManager:WarnRateLimited("combat_visual_guides", kind == "unit" and "UNIT_ACQUIRE_FAILED" or "RANGE_ACQUIRE_FAILED",
                    5000, "悬浮组件层获取渲染租约失败", { feature = id, error = tostring(err or "unknown") })
            end
            return false,err
        end
        self.lastAcquireError=self.lastAcquireError or {}
        self.lastAcquireError[kind]=nil
        self[heldField]=true; acquiredNow=true
    end
    local rendered,renderErr
    if kind=="unit" then rendered,renderErr=self:RenderUnit() else rendered,renderErr=self:RenderRange() end
    if rendered~=true and acquiredNow then
        -- 渲染失败时保留 Consumer，不能同 Tick 释放；释放会停用 Demand、移除刷新任务，且 Reconcile 只监听生命周期事件，暂时池/锚点失败将永久隐藏覆盖层。
        -- 保留后 Authority Tick 继续发布 UpdateTopic，渲染可自动重试自愈。
        if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.WarnRateLimited) == "function" then
            S.DiagnosticsManager:WarnRateLimited("combat_visual_guides", kind == "unit" and "UNIT_RENDER_RETRY_KEPT" or "RANGE_RENDER_RETRY_KEPT",
                5000, "渲染失败但保留 Consumer 自动重试", { error = tostring(renderErr or "unknown") })
        end
    end
    return rendered,renderErr
end
function P:Reconcile(reason)
    self.reconcileRuns=(tonumber(self.reconcileRuns) or 0)+1
    local ok1,err1=self:ReconcileOne(UnitFeature,"combat_unit_lines",self.unitToken,"unitHeld","unit")
    local ok2,err2=self:ReconcileOne(RangeFeature,"combat_range_assist",self.rangeToken,"rangeHeld","range")
    return ok1==true and ok2==true, err1 or err2
end

-- 生命周期看门任务为 1 s/P3，正常时每次仅少量表读取；补齐订阅握手漏事件、无事件租约清空、获取失败，并按 1 s 重试。始终注册，但停用且已收敛状态不执行工作。
function P:ConvergeTick()
    self.watchdogTicks=(tonumber(self.watchdogTicks) or 0)+1
    -- 约束（2026-10-09）：正背面显示复用现有一秒租约收敛任务；只查开关/租约，不造第二个
    -- watchdog，不读取目标/相机。新 Presenter 在视觉共享文件之后加载，因此运行时再取得引用。
    local facing=S.UIV3 and S.UIV3.FacingIndicatorV3
    if facing and type(facing.ConvergeTick)=="function" then facing:ConvergeTick() end
    local unitEnabled=S.FeatureRuntime:IsEnabled("combat_unit_lines")==true
    local rangeEnabled=S.FeatureRuntime:IsEnabled("combat_range_assist")==true
    local unitHealthy=self.unitHeld==true and (type(UnitFeature.HasConsumer)~="function" or UnitFeature:HasConsumer(self.unitToken)==true)
    local rangeHealthy=self.rangeHeld==true and (type(RangeFeature.HasConsumer)~="function" or RangeFeature:HasConsumer(self.rangeToken)==true)
    if (unitEnabled==false or unitHealthy==true) and (rangeEnabled==false or rangeHealthy==true) then return end
    self:Reconcile("lifecycle_watchdog")
end

function P:Describe()
    local sample=type(self.lastUnitSampling)=="table" and self.lastUnitSampling or {}
    local rangeSample=type(self.lastRangeSampling)=="table" and self.lastRangeSampling or {}
    return {
        version=self.version,adaptiveUnitLineSampling=tonumber(self.AdaptiveUnitLineSamplingContractVersion) or 0,unitLinePressureBudget=tonumber(self.UnitLinePressureBudgetContractVersion) or 0,unitLineDiffRender=tonumber(self.UnitLineDiffRenderContractVersion) or 0,unitLineProgressivePool=tonumber(self.UnitLineProgressivePoolContractVersion) or 0,
        unitHeld=self.unitHeld==true,rangeHeld=self.rangeHeld==true,
        unitPlanBuilds=tonumber(self.unitPlanBuilds) or 0,unitPlanReuses=tonumber(self.unitPlanReuses) or 0,
        unitDensityPatch="dynamic-hud-1",unitExtraBudgetFactor=UNIT_LINE_EXTRA_BUDGET_FACTOR,
        unitDots=(function() local n=0; for _,pool in pairs(self.unitPools) do n=n+#pool end; return n end)(),
        unitVisibleDots=tonumber(sample.visibleDots) or 0,unitRequestedDots=tonumber(sample.requestedDots) or 0,unitVisibleEdges=tonumber(sample.visibleEdges) or 0,unitClippedEdges=tonumber(sample.clippedEdges) or 0,unitBudget=tonumber(sample.budget) or 0,unitPressure=tostring(sample.pressure or "Normal"),unitPoolGrowth=tonumber(sample.poolGrowth) or 0,unitAnchorWrites=tonumber(sample.anchorWrites) or 0,unitStyleWrites=tonumber(sample.styleWrites) or 0,unitVisibilityWrites=tonumber(sample.visibilityWrites) or 0,
        rangeDots=RangePoolDotCount(self.rangePools),rangeCircles=tonumber(rangeSample.circles) or 0,rangeEnabledCircles=tonumber(rangeSample.enabledCircles) or 0,rangeConfiguredCircles=tonumber(rangeSample.totalCircles) or 0,
        lastLifecycle=self.lastLifecycle,reconcileRuns=tonumber(self.reconcileRuns) or 0,watchdogTicks=tonumber(self.watchdogTicks) or 0,
        uiEnvironmentRevision=tonumber(self.lastUiEnvironmentRevision) or 0,styleRecoveryCount=tonumber(self.styleRecoveryCount) or 0,lastStyleRecovery=self.lastStyleRecovery,
        manualPointTypographyContract=tonumber(self.ManualPointTypographyContractVersion) or 0,uiEnvironmentStyleRecoveryContract=tonumber(self.UiEnvironmentStyleRecoveryContractVersion) or 0,
        acquireAttempts={unit=tonumber(self.acquireAttempts and self.acquireAttempts.unit) or 0,range=tonumber(self.acquireAttempts and self.acquireAttempts.range) or 0},
        lastAcquireError=self.lastAcquireError
    }
end

if S.Events ~= nil and type(S.Events.SubscribeInternal)=="function" then
    S.Events:SubscribeInternal((S.FeatureRuntime and S.FeatureRuntime.LifecycleTopic) or "v3.feature.lifecycle",P.eventOwner,function(_,featureId,state)
        P.lastLifecycle={ id=tostring(featureId or ""), state=tostring(state or ""), at=(S.NowMs and S.NowMs() or 0) }
        if featureId=="combat_unit_lines" or featureId=="combat_range_assist" then P:Reconcile("lifecycle") end
    end)
    S.Events:SubscribeInternal(UnitFeature.UpdateTopic,P.eventOwner,function()
        local ok,err=P:RenderUnit(); if ok~=true and S.DiagnosticsManager and type(S.DiagnosticsManager.WarnRateLimited)=="function" then
            S.DiagnosticsManager:WarnRateLimited("combat_visual_guides","UNIT_RENDER_FAILED",3000,"单位连线渲染失败",{error=tostring(err or "unknown")})
        end
    end)
    S.Events:SubscribeInternal(RangeFeature.UpdateTopic,P.eventOwner,function()
        local ok,err=P:RenderRange(); if ok~=true and S.DiagnosticsManager and type(S.DiagnosticsManager.WarnRateLimited)=="function" then
            S.DiagnosticsManager:WarnRateLimited("combat_visual_guides","RANGE_RENDER_FAILED",3000,"范围辅助渲染失败",{error=tostring(err or "unknown")})
        end
    end)
end
P:Reconcile("bootstrap")
if S.Scheduler ~= nil and type(S.Scheduler.AddTask) == "function" then
    S.Scheduler:AddTask(P.watchdogTask, 1000, function() P:ConvergeTick() end, false, P, "P3", 1)
end

-- 模块诊断只复制本模块现有采样；不调用 Render/GetProjection/NativeVisibleReadback，也不创建控件。
-- 不把共享 Presenter 的 UnitLines 池/投影批次误归属给 RangeAssist。
if S.ModuleDiagnosticsHub ~= nil and type(S.ModuleDiagnosticsHub.RegisterProvider) == "function" then
    S.ModuleDiagnosticsHub:RegisterProvider(RangeFeature.Id, "range_render", function()
        local copy = S.FeatureSliceFactory.Copy
        return { patch="range-continuity-1", held=P.rangeHeld==true,
            poolDots=RangePoolDotCount(P.rangePools), sampling=copy(P.lastRangeSampling or {}),
            acquireAttempts=tonumber(P.acquireAttempts and P.acquireAttempts.range) or 0,
            acquireError=copy(P.lastAcquireError and P.lastAcquireError.range or {}),
            uiEnvironmentRevision=tonumber(P.lastUiEnvironmentRevision) or 0 }
    end)
end
