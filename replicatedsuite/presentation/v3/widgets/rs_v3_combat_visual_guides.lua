------------------------------------------------------------------------
-- Replicated Suite V3 - Combat Visual Guides Presenter
--
-- Screen-only Presentation for current-target line and user-defined range
-- circle. Features own sampling cadence and detached projections; this file
-- only diff-renders bounded dot pools and owns no Tick/Scheduler.
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
P.version = 8
P.owner = "v3:combat_visual_guides"
P.unitToken = "presentation:unit_lines"
P.rangeToken = "presentation:range_assist"
P.unitHeld = P.unitHeld == true
P.rangeHeld = P.rangeHeld == true
P.unitHost = P.unitHost or nil
P.rangeHost = P.rangeHost or nil
P.unitPools = P.unitPools or {}
P.unitPool = P.unitPool or {} -- legacy allocation field retained only for diagnostics compatibility
P.rangePool = P.rangePool or {}
P.eventOwner = P.eventOwner or {}
P.hostMetrics = P.hostMetrics or {}
-- Lifecycle watchdog telemetry (v6): the presenter acquires its render lease by
-- SUBSCRIBING to feature lifecycle events, so every failure mode below was
-- permanently fatal AND silent before v6 — 0 consumers, 0 warnings, "已开启但
-- 无消费者" until the user re-toggled:
--   a) lifecycle event missed (subscription/handshake timing),
--   b) lease cleared underneath the presenter (Demand:ClearAll on runtime
--      stop/start publishes no lifecycle event, and a later F:Enable is a
--      no-op because row.enabled is already true),
--   c) acquire transaction failure (never warned).
P.watchdogTask = P.watchdogTask or "v3_visual_guides_lifecycle_watchdog"
P.lastLifecycle = P.lastLifecycle or nil
P.acquireAttempts = P.acquireAttempts or { unit = 0, range = 0 }
P.lastAcquireError = P.lastAcquireError or {}
P.reconcileRuns = tonumber(P.reconcileRuns) or 0
P.watchdogTicks = tonumber(P.watchdogTicks) or 0

-- RETIRED 2026-09-06: emptywidget + CreateColorDrawable("overlay") 4x4 dots
-- had no working-reference precedent and were invisible on the real client.
-- Both reference implementations (easypull, plates) draw overlay dots as
-- LABEL widgets containing a '.' glyph; EnsureUnitPairPool/EnsurePool now do
-- the same via S.UI:CreateLabel. Kept here so the audit token trail and any
-- external caller survive one generation.
local function NewColorDrawable(parent)
    if parent == nil or type(parent.CreateColorDrawable) ~= "function" then return nil end
    local ok, drawable = pcall(function() return parent:CreateColorDrawable(0.96, 0.78, 0.18, 0.8, "overlay") end)
    return ok and drawable or nil
end

function P:EnsureHost(kind)
    local field = kind == "unit" and "unitHost" or "rangeHost"
    local host = self[field]
    if host == nil then
        -- v7 reference alignment (rp_ui.lua EnsureLinesHost / easypull.lua:257):
        -- the overlay host MUST be a real top-level WINDOW. The previous root
        -- emptywidget + "system" UILayer is recorded in our own CreatePanel
        -- documentation as unreliable on RU clients — the host rendered nothing
        -- and every dot (its child) was invisible with it.
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
-- Resolve a per-pair color override from the Feature projection; falls back to
-- the hardcoded palette so older stores without colors keep rendering.
local function UnitLineColor(projection, pairKey)
    local colors = type(projection) == "table" and projection.colors or nil
    if type(colors) == "table" then
        local c = colors[tostring(pairKey or "")]
        if type(c) == "table" then return c[1], c[2], c[3] end
    end
    local c = UNIT_COLORS[tostring(pairKey or "target")] or UNIT_COLORS.target
    return c[1], c[2], c[3]
end

-- Unit Line Adaptive Sampling + Smooth Refresh Contract v2
--
-- `pointCount/pairPoints` are preserved as the user's BASE density for store
-- compatibility.  They are no longer treated as the final number of dots.
-- The visible screen-space segment is clipped first, then extra samples are
-- added as the segment grows so long-distance relations keep the same visual
-- continuity as short-distance relations.  A cadence-aware TOTAL budget caps
-- Native work when the user selects very high refresh rates.
-- v7 reference alignment: NO segment clipping. The reference renderers anchor
-- sampled dots at RAW projected coordinates (rp_ui.lua UpdateLinesView
-- AddAnchor(host, x, y)) — off-screen dots are simply off-screen and cost
-- nothing but bounded pool slots. The previous Liang-Barsky clip compared
-- raw/native coordinates against the logical viewport from GetUiMetrics; when
-- those spaces disagreed the clip rejected EVERY plan and the renderer placed
-- 0 dots while the feature still reported a projected row ("投影有 1 行但渲染
-- 层 0 个可见点", .18.130b field report). Dots are still bounded per pair and
-- per refresh cadence.
local UNIT_LINE_REFERENCE_LENGTH = 240
local UNIT_LINE_PAIR_HARD_CAP = 160
local UNIT_LINE_TOTAL_BUDGET_FAST = 256
local UNIT_LINE_TOTAL_BUDGET_MEDIUM = 320
local UNIT_LINE_TOTAL_BUDGET_NORMAL = 384
local UNIT_LINE_TOTAL_BUDGET_SLOW = 480
-- Smooth Refresh Contract v1: high-frequency unit lines must not be deferred as
-- one monolithic P3 burst under crowd/frame pressure.  Instead the producer
-- stays frame-cadence eligible while Presentation sheds only adaptive EXTRA
-- density and grows Native dot pools progressively.  The user's configured
-- base density remains the hard floor.
local UNIT_LINE_PRESSURE_FACTOR = { Normal=1.00, Busy=0.82, Heavy=0.68, Critical=0.55 }
local UNIT_LINE_POOL_GROWTH = { Normal=48, Busy=32, Heavy=24, Critical=16 }

local function UnitLineTotalBudget(refreshMs)
    refreshMs=math.max(1,math.min(1000,math.floor(tonumber(refreshMs) or 100)))
    if refreshMs <= 16 then return UNIT_LINE_TOTAL_BUDGET_FAST end
    if refreshMs <= 33 then return UNIT_LINE_TOTAL_BUDGET_MEDIUM end
    if refreshMs <= 50 then return UNIT_LINE_TOTAL_BUDGET_NORMAL end
    return UNIT_LINE_TOTAL_BUDGET_SLOW
end

local function UnitLinePressureBudget(baseBudget, totalBase, pressure)
    local factor=UNIT_LINE_PRESSURE_FACTOR[tostring(pressure or "Normal")] or 1
    local pressured=math.floor(math.max(0,tonumber(baseBudget) or 0)*factor)
    return math.max(math.max(0,math.floor(tonumber(totalBase) or 0)),pressured)
end

local function UnitLinePoolGrowthBudget(pressure)
    return UNIT_LINE_POOL_GROWTH[tostring(pressure or "Normal")] or UNIT_LINE_POOL_GROWTH.Normal
end

local function DesiredUnitLinePointCount(length, baseCount)
    baseCount=math.max(8,math.min(48,math.floor(tonumber(baseCount) or 24)))
    length=math.max(0,tonumber(length) or 0)
    -- Preserve the old near-distance look: baseCount remains a floor.  The
    -- reference maps 24 legacy points to roughly 10.4 logical px spacing.
    local spacing=UNIT_LINE_REFERENCE_LENGTH/math.max(1,baseCount-1)
    local adaptive=math.ceil(length/math.max(1,spacing))+1
    return math.max(baseCount,math.min(UNIT_LINE_PAIR_HARD_CAP,adaptive))
end

function P:BuildUnitLineSamplePlan(rows, projection, logicalW, logicalH, pressure)
    rows=type(rows)=="table" and rows or {}
    projection=type(projection)=="table" and projection or {}
    local pairPoints=type(projection.pairPoints)=="table" and projection.pairPoints or {}
    local plans,totalBase,totalDesired={},0,0
    for _,row in ipairs(rows) do
        if type(row)=="table" then
            local x1,y1,x2,y2=tonumber(row.x1),tonumber(row.y1),tonumber(row.x2),tonumber(row.y2)
            if x1~=nil and y1~=nil and x2~=nil and y2~=nil then
                local base=math.max(8,math.min(48,math.floor(tonumber(pairPoints[row.pairKey]) or tonumber(projection.pointCount) or 24)))
                local dx,dy=x2-x1,y2-y1
                local length=math.sqrt(dx*dx+dy*dy)
                local desired=DesiredUnitLinePointCount(length,base)
                local plan={ row=row,x1=x1,y1=y1,x2=x2,y2=y2,length=length,base=base,desired=desired,count=base }
                plans[#plans+1]=plan
                totalBase=totalBase+base; totalDesired=totalDesired+desired
            end
        end
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
    return plans,budget
end

P.AdaptiveUnitLineSamplingContractVersion = 2
P.UnitLineVisibleSegmentClippingContractVersion = 1
P.UnitLinePressureBudgetContractVersion = 1
P.UnitLineDiffRenderContractVersion = 1
P.UnitLineProgressivePoolContractVersion = 1
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
        -- DOT MODEL (2026-09-06, reference-aligned): the previous emptywidget +
        -- 4x4 CreateColorDrawable("overlay") dot has NO working-reference
        -- precedent and 4px is near-invisible at 1080p+. Every reference that
        -- actually works on live RU draws dots as a LABEL containing a single
        -- '.' character (easypull.lua:262-280 label '.' SetFontSize(22)
        -- SetOutline; plates rp_ui.lua:2341-2354 label '.' 15px pools). Use the
        -- same model through the project's own S.UI:CreateLabel primitive.
        -- Reference dot model (rp_ui.lua EnsureLinesHost): extent 1x1 — the
        -- '.' glyph size IS carried by the font size, a larger extent only
        -- offsets the glyph from the anchor point.
        local dot,dotErr=S.UI:CreateLabel(host,"v3_visual_unit_"..pairKey.."_dot_"..tostring(index),".",0,0,1,1,15,"strong","CENTER",false)
        if dot==nil then return nil,dotErr end
        local row={root=dot,drawable=nil,label=true,renderState={visible=false}}; pool[index]=row
        S.UI:SetVisible(dot,false,self.owner)
        created=created+1
    end
    return pool,nil,created,#pool>=count
end

function P:SetUnitDotVisible(dot, visible)
    if type(dot)~="table" or dot.root==nil then return false end
    local state=type(dot.renderState)=="table" and dot.renderState or {}; dot.renderState=state
    local value=visible==true
    if state.visible==value then return false end
    -- Commit the presenter cache ONLY after RSUI accepted the native write.
    -- Committing unconditionally turned one rejected Show() into a permanent
    -- desync: every later frame believed the dot was already hidden/shown and
    -- never retried, leaving pool widgets stuck visible at (0,0) -- the
    -- reported "screen shows a single dot" failure shape.
    if S.UI:SetVisible(dot.root,value,self.owner)~=true then return false end
    state.visible=value
    return true
end

function P:HideUnitPools()
    for _,pool in pairs(self.unitPools) do
        for _,dot in ipairs(pool) do self:SetUnitDotVisible(dot,false) end
    end
end

function P:EnsurePool(kind, count)
    count=math.max(0,math.min(48,math.floor(tonumber(count) or 0)))
    local pool = kind == "unit" and self.unitPool or self.rangePool
    local host, err = self:EnsureHost(kind); if host == nil then return false, err end
    for index=1,count do
        local row=pool[index]
        if type(row)~="table" or row.root==nil then
            -- Reference-aligned label dot (same rationale as
            -- EnsureUnitPairPool; easypull/rp_ui both draw '.' labels).
            local dot, dotErr = S.UI:CreateLabel(host, "v3_visual_" .. kind .. "_dot_" .. tostring(index), ".", 0, 0, 1, 1, 15, "strong", "CENTER", false)
            if dot == nil then return false, dotErr end
            row={root=dot,drawable=nil,label=true}; pool[index]=row
            S.UI:SetVisible(dot, false, self.owner)
        end
    end
    return true
end

function P:HidePool(pool)
    for _,dot in ipairs(pool) do S.UI:SetVisible(dot.root, false, self.owner) end
end

local VISUAL_POINT_SIZE_MIN = tonumber(S.Constants and S.Constants.VisualGuide and S.Constants.VisualGuide.pointSizeMin) or 2
local VISUAL_POINT_SIZE_HARD_MAX = tonumber(S.Constants and S.Constants.VisualGuide and S.Constants.VisualGuide.pointSizeHardMax) or 24
local function ResolveVisualPointFontSize(value)
    local setting = math.max(VISUAL_POINT_SIZE_MIN, math.min(VISUAL_POINT_SIZE_HARD_MAX, math.floor(tonumber(value) or 4)))
    -- Preserve the proven 2..10 mapping (2->16px, 10->40px) and extend it
    -- monotonically instead of flattening all values >10 back to 40px.
    return math.max(15, math.floor(10 + setting * 3))
end

function P:PlaceUnitDot(dot, x, y, size, opacity, pairKey, r, g, b)
    -- LABEL dots: color/size ride the label style, not a drawable (see
    -- EnsureUnitPairPool for why the drawable model was replaced).
    if type(dot)~="table" or dot.root==nil then return 0,0,0 end
    -- v11 (.18.135): the point-size SETTING range is 2..10 while the glyph
    -- must stay readable (>=15px, rp_ui reference). Clamping the setting into
    -- the band made the size slider a no-op ("设置没有用"). Map it
    -- monotonically instead: setting 2→16px, 4→22, 6→28, 8→34, 10→40.
    size=ResolveVisualPointFontSize(size)
    local alpha=math.max(0.1,math.min(1,tonumber(opacity) or 0.78))
    local cr,cg,cb=r,g,b
    if cr==nil then
        local c=UNIT_COLORS[tostring(pairKey or "target")] or UNIT_COLORS.target
        cr,cg,cb=c[1],c[2],c[3]
    end
    local state=type(dot.renderState)=="table" and dot.renderState or {}; dot.renderState=state
    local px=math.floor((tonumber(x) or 0)-size/2)
    local py=math.floor((tonumber(y) or 0)-size/2)
    local anchorWrites,styleWrites,visibilityWrites=0,0,0
    -- v10 ROOT-CAUSE FIX (the "S visible but no dots" report): RSUI setters
    -- return false BOTH for "rejected" AND for "no change needed". CreateLabel
    -- primes row.fontSize=15 via PrimeNativeState, so with the 15px floor the
    -- first SetFontSize(15) returned false (no-op), the old commit-on-accept
    -- check treated it as failure, bailed out BEFORE SetUnitDotVisible, and
    -- the dot stayed hidden at (0,0) on EVERY tick. Style writes are now
    -- best-effort exactly like the working reference (rp_ui pcall style/font
    -- and never bails): a visible dot with imperfect styling beats a
    -- perfectly-styled dot that never shows.
    if state.x~=px or state.y~=py then
        S.UI:SetAnchor(dot.root,self.unitHost,px,py,self.owner)
        state.x,state.y=px,py; anchorWrites=1
    end
    if state.size~=size then
        S.UI:SetFontSize(dot.root,size,self.owner)
        state.size=size; styleWrites=styleWrites+1
    end
    if state.r~=cr or state.g~=cg or state.b~=cb or state.a~=alpha then
        S.UI:SetColor(dot.root,cr,cg,cb,alpha,self.owner)
        state.r,state.g,state.b,state.a=cr,cg,cb,alpha; styleWrites=styleWrites+1
    end
    if self:SetUnitDotVisible(dot,true) then visibilityWrites=1 end
    return anchorWrites,styleWrites,visibilityWrites
end

function P:PlaceDot(dot, x, y, size, opacity, kind, pairKey, r, g, b)
    -- Label-dot placement (reference model). Color rides the label style;
    -- Base 2..10 retains the proven 16..40px mapping; exact values accepted
    -- above 10 continue monotonically instead of being visually flattened.
    size=ResolveVisualPointFontSize(size)
    S.UI:SetAnchor(dot.root, kind == "unit" and self.unitHost or self.rangeHost, math.floor((tonumber(x) or 0)-size/2), math.floor((tonumber(y) or 0)-size/2), self.owner)
    S.UI:SetFontSize(dot.root, size, self.owner)
    if kind == "range" then
        -- r,g,b are passed by RenderRange from the persisted projection color;
        -- fall back to the original (0.20, 0.82, 1.00) when none is set.
        S.UI:SetColor(dot.root, r or 0.20, g or 0.82, b or 1.00, math.max(0.1,math.min(1,tonumber(opacity) or 0.68)), self.owner)
    else
        local cr, cg, cb = r, g, b
        if cr == nil then
            local c = UNIT_COLORS[tostring(pairKey or "target")] or UNIT_COLORS.target
            cr, cg, cb = c[1], c[2], c[3]
        end
        S.UI:SetColor(dot.root, cr, cg, cb, math.max(0.1,math.min(1,tonumber(opacity) or 0.78)),self.owner)
    end
    S.UI:SetVisible(dot.root, true, self.owner)
end

-- Reference-aligned screen scale (rp_ui.lua UpdateLinesView: pt.x * scale,
-- addonScale defaults to 1). Presentation never derives a second coordinate
-- space; it multiplies raw projected coords by the layout scale only.
function P:AddonScale()
    local context = S.Layout ~= nil and type(S.Layout.GetContext) == "function" and S.Layout:GetContext() or nil
    local scale = tonumber(context and context.addonScale) or 1
    if scale <= 0 then return 1 end
    return scale
end

function P:RenderUnit()
    if self.unitHeld ~= true then self:HideUnitPools(); return true end
    local projection=UnitFeature:GetProjection() or {}; local rows=type(projection.rows)=="table" and projection.rows or {}
    if #rows==0 then
        self:HideUnitPools()
        S.UI:SetVisible(self.unitHost,false,self.owner)
        return true
    end
    local pairSizes = type(projection.pairSizes) == "table" and projection.pairSizes or {}
    local pressure="Normal"
    if type(S.FrameBudget)=="table" and type(S.FrameBudget.current)=="table" then pressure=tostring(S.FrameBudget.current.pressure or "Normal") end
    local plans,budget=self:BuildUnitLineSamplePlan(rows,projection,nil,nil,pressure)
    local addonScale=self:AddonScale()
    local active={}
    local visibleDots,requestedDots=0,0
    local anchorWrites,styleWrites,visibilityWrites,poolGrowth=0,0,0,0
    local uniqueSeen={}
    local uniquePositions=0
    local growthRemaining=UnitLinePoolGrowthBudget(pressure)
    local remainingPlans=#plans
    for planIndex,plan in ipairs(plans) do
        local row=plan.row
        local key=tostring(row.pairKey or row.key or "target"):gsub("[^%w_]","_")
        local requested=math.max(2,math.min(UNIT_LINE_PAIR_HARD_CAP,math.floor(tonumber(plan.count) or 2)))
        requestedDots=requestedDots+requested
        local size=math.max(VISUAL_POINT_SIZE_MIN,math.min(VISUAL_POINT_SIZE_HARD_MAX,math.floor(tonumber(pairSizes[row.pairKey]) or tonumber(projection.pointSize) or 4)))
        local cr,cg,cb=UnitLineColor(projection,row.pairKey)
        -- Split the frame growth budget across the remaining pairs instead of
        -- letting the first pool consume it all: with four pairs enabled the
        -- old first-come loop starved pools 2..4 for many frames (up to ten
        -- under Critical pressure), rendering as "only one line has dots".
        local growthShare=math.max(8,math.floor(growthRemaining/math.max(1,remainingPlans)))
        local pool,err,created=self:EnsureUnitPairPool(key,requested,math.min(growthRemaining,growthShare)); if pool==nil then return false,err end
        created=math.max(0,tonumber(created) or 0); growthRemaining=math.max(0,growthRemaining-created); poolGrowth=poolGrowth+created
        remainingPlans=math.max(0,remainingPlans-1)
        local count=math.min(requested,#pool)
        active[key]=true; visibleDots=visibleDots+count
        for i=1,count do
            local t=(i-1)/math.max(1,count-1)
            local px=math.floor((plan.x1+(plan.x2-plan.x1)*t)*addonScale+0.5)
            local py=math.floor((plan.y1+(plan.y2-plan.y1)*t)*addonScale+0.5)
            local aw,sw,vw=self:PlaceUnitDot(pool[i],px,py,size,projection.opacity,key,cr,cg,cb)
            anchorWrites=anchorWrites+(tonumber(aw) or 0); styleWrites=styleWrites+(tonumber(sw) or 0); visibilityWrites=visibilityWrites+(tonumber(vw) or 0)
            local uk=tostring(px)..","..tostring(py)
            if uniqueSeen[uk]~=true then uniqueSeen[uk]=true; uniquePositions=uniquePositions+1 end
        end
        for i=count+1,#pool do if self:SetUnitDotVisible(pool[i],false) then visibilityWrites=visibilityWrites+1 end end
    end
    for key,pool in pairs(self.unitPools) do
        if active[key]~=true then for _,dot in ipairs(pool) do if self:SetUnitDotVisible(dot,false) then visibilityWrites=visibilityWrites+1 end end end
    end
    -- Reference model: the host window is shown while lines exist and raised
    -- above other Suite surfaces (rp_ui.lua UpdateLinesView host Show/Raise).
    S.UI:SetVisible(self.unitHost,#plans>0,self.owner)
    self.lastUnitSampling={budget=budget,pressure=pressure,visibleEdges=#plans,requestedDots=requestedDots,
        visibleDots=visibleDots,poolGrowth=poolGrowth,anchorWrites=anchorWrites,styleWrites=styleWrites,visibilityWrites=visibilityWrites,
        uniquePositions=uniquePositions,addonScale=addonScale,
        firstRow=(plans[1]~=nil) and (tostring(math.floor(plans[1].x1))..","..tostring(math.floor(plans[1].y1)).."->"..tostring(math.floor(plans[1].x2))..","..tostring(math.floor(plans[1].y2))) or nil}
    return true
end

function P:RenderRange()
    if self.rangeHeld ~= true then self:HidePool(self.rangePool); S.UI:SetVisible(self.rangeHost,false,self.owner); return true end
    local projection=RangeFeature:GetProjection() or {}; local row=projection.rows and projection.rows[1] or nil
    local points=type(row)=="table" and type(row.points)=="table" and row.points or {}
    if #points<3 then self:HidePool(self.rangePool); S.UI:SetVisible(self.rangeHost,false,self.owner); return true end
    -- Range line color is now configurable via the page ColorField; fall back to
    -- the legacy default when no color has been persisted.
    local rc=type(projection.color)=="table" and projection.color or nil
    local rr,rg,rb=rc and (tonumber(rc[1]) or 0.20) or 0.20, rc and (tonumber(rc[2]) or 0.82) or 0.82, rc and (tonumber(rc[3]) or 1.00) or 1.00
    local count=math.min(48,#points); local ok,err=self:EnsurePool("range",count); if ok~=true then return false,err end
    local addonScale=self:AddonScale()
    for i=1,count do
        self:PlaceDot(self.rangePool[i],points[i].x*addonScale,points[i].y*addonScale,projection.pointSize,projection.opacity,"range",nil,rr,rg,rb)
    end
    for i=count+1,#self.rangePool do S.UI:SetVisible(self.rangePool[i].root,false,self.owner) end
    S.UI:SetVisible(self.rangeHost,true,self.owner)
    local hostVisible, hostKnown = nil, false
    if type(S.UI.NativeVisibleReadback) == "function" then hostVisible, hostKnown = S.UI:NativeVisibleReadback(self.rangeHost) end
    self.lastRangeSampling = { points = count, addonScale = addonScale,
        first = (count > 0 and points[1] ~= nil) and (tostring(math.floor((tonumber(points[1].x) or 0) * addonScale)) .. "," .. tostring(math.floor((tonumber(points[1].y) or 0) * addonScale))) or "?",
        hostVisible = hostKnown == true and tostring(hostVisible == true) or "未知" }
    return true
end

function P:ReconcileOne(feature,id,token,heldField,kind)
    local enabled=S.FeatureRuntime:IsEnabled(id)==true
    if not enabled then
        if kind=="unit" then self:HideUnitPools() else self:HidePool(self.rangePool) end
        if self[heldField]==true then
            local ok,err=feature:ReleaseConsumer(token); if ok~=true then return false,err end
            self[heldField]=false
        end
        return true
    end
    -- Lease-desync heal (v6): runtime ClearAll/ForceQuiesce can empty the lease
    -- WITHOUT any lifecycle event, and a later F:Enable is a row.enabled no-op
    -- that publishes nothing. Without this heal the presenter believes it holds
    -- a dead lease forever — the "已开启但无消费者 + 零告警" field report.
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
        -- Historical behavior released the consumer on the SAME tick the
        -- render failed. That quiesced the demand, removed the refresh task
        -- and left the presenter with no retry path (Reconcile only listens to
        -- lifecycle events), so one transient pool/anchor failure permanently
        -- hid the overlay until the user toggled the feature. Keep the
        -- consumer instead: Authority ticks keep publishing UpdateTopic, so
        -- the render retries automatically and self-heals.
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

-- Lifecycle watchdog (v6, 1 s, P3, a few table reads per tick when healthy).
-- It closes every silent-failure mode of the subscribe-based lease handshake:
-- missed lifecycle events, lease cleared without lifecycle, and failed
-- acquires (retried here at 1 s instead of dying on the first attempt).
-- Registered unconditionally; a disabled-but-converged state costs nothing.
function P:ConvergeTick()
    self.watchdogTicks=(tonumber(self.watchdogTicks) or 0)+1
    local unitEnabled=S.FeatureRuntime:IsEnabled("combat_unit_lines")==true
    local rangeEnabled=S.FeatureRuntime:IsEnabled("combat_range_assist")==true
    local unitHealthy=self.unitHeld==true and (type(UnitFeature.HasConsumer)~="function" or UnitFeature:HasConsumer(self.unitToken)==true)
    local rangeHealthy=self.rangeHeld==true and (type(RangeFeature.HasConsumer)~="function" or RangeFeature:HasConsumer(self.rangeToken)==true)
    if (unitEnabled==false or unitHealthy==true) and (rangeEnabled==false or rangeHealthy==true) then return end
    self:Reconcile("lifecycle_watchdog")
end

function P:Describe() local sample=type(self.lastUnitSampling)=="table" and self.lastUnitSampling or {}; return {version=self.version,adaptiveUnitLineSampling=tonumber(self.AdaptiveUnitLineSamplingContractVersion) or 0,unitLinePressureBudget=tonumber(self.UnitLinePressureBudgetContractVersion) or 0,unitLineDiffRender=tonumber(self.UnitLineDiffRenderContractVersion) or 0,unitLineProgressivePool=tonumber(self.UnitLineProgressivePoolContractVersion) or 0,unitHeld=self.unitHeld==true,rangeHeld=self.rangeHeld==true,unitDots=(function() local n=0; for _,pool in pairs(self.unitPools) do n=n+#pool end; return n end)(),unitVisibleDots=tonumber(sample.visibleDots) or 0,unitRequestedDots=tonumber(sample.requestedDots) or 0,unitVisibleEdges=tonumber(sample.visibleEdges) or 0,unitClippedEdges=tonumber(sample.clippedEdges) or 0,unitBudget=tonumber(sample.budget) or 0,unitPressure=tostring(sample.pressure or "Normal"),unitPoolGrowth=tonumber(sample.poolGrowth) or 0,unitAnchorWrites=tonumber(sample.anchorWrites) or 0,unitStyleWrites=tonumber(sample.styleWrites) or 0,unitVisibilityWrites=tonumber(sample.visibilityWrites) or 0,rangeDots=#self.rangePool,
    lastLifecycle=self.lastLifecycle,reconcileRuns=tonumber(self.reconcileRuns) or 0,watchdogTicks=tonumber(self.watchdogTicks) or 0,
    acquireAttempts={unit=tonumber(self.acquireAttempts and self.acquireAttempts.unit) or 0,range=tonumber(self.acquireAttempts and self.acquireAttempts.range) or 0},
    lastAcquireError=self.lastAcquireError} end

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
