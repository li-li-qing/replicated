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
P.version = 5
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

local function NewColorDrawable(parent)
    if parent == nil or type(parent.CreateColorDrawable) ~= "function" then return nil end
    local ok, drawable = pcall(function() return parent:CreateColorDrawable(0.96, 0.78, 0.18, 0.8, "overlay") end)
    return ok and drawable or nil
end

function P:EnsureHost(kind)
    local field = kind == "unit" and "unitHost" or "rangeHost"
    local _,_,_,w,h = S.Api:GetUiMetrics(); w,h=tonumber(w) or 1024,tonumber(h) or 768
    local host = self[field]
    if host == nil then
        local created, err = S.UI:CreateEmptyWidget(UIParent, "v3_visual_" .. kind .. "_host", 0, 0, w, h, false, self.owner)
        if created == nil then return nil, err end
        host=created; self[field]=host
        S.UI:SetVisible(host, true, self.owner); S.UI:TrySetUILayer(host, "system")
    end
    local metrics=self.hostMetrics[kind]
    if type(metrics)~="table" or metrics.w~=w or metrics.h~=h then
        S.UI:SetAnchor(host, UIParent, 0, 0, self.owner); S.UI:SetExtent(host, w, h, self.owner)
        self.hostMetrics[kind]={w=w,h=h}
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

local function ClipTest(p, q, t0, t1)
    if math.abs(p) < 0.000001 then
        if q < 0 then return nil, nil end
        return t0, t1
    end
    local r = q / p
    if p < 0 then
        if r > t1 then return nil, nil end
        if r > t0 then t0 = r end
    else
        if r < t0 then return nil, nil end
        if r < t1 then t1 = r end
    end
    return t0, t1
end

-- Liang-Barsky clipping in logical UI space.  Clipping BEFORE sampling is
-- important: an endpoint can be thousands of pixels off-screen at an oblique
-- camera angle. Sampling that unbounded segment with a fixed/capped count can
-- leave zero or only one visible dot even though the line crosses the screen.
local function ClipSegmentToRect(x1, y1, x2, y2, left, top, right, bottom)
    x1,y1,x2,y2=tonumber(x1),tonumber(y1),tonumber(x2),tonumber(y2)
    if x1==nil or y1==nil or x2==nil or y2==nil then return nil end
    local dx,dy=x2-x1,y2-y1
    local t0,t1=0,1
    t0,t1=ClipTest(-dx,x1-left,t0,t1); if t0==nil then return nil end
    t0,t1=ClipTest(dx,right-x1,t0,t1); if t0==nil then return nil end
    t0,t1=ClipTest(-dy,y1-top,t0,t1); if t0==nil then return nil end
    t0,t1=ClipTest(dy,bottom-y1,t0,t1); if t0==nil then return nil end
    return x1+t0*dx,y1+t0*dy,x1+t1*dx,y1+t1*dy,(t0>0.000001 or t1<0.999999)
end

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
    logicalW=math.max(1,tonumber(logicalW) or 1024)
    logicalH=math.max(1,tonumber(logicalH) or 768)
    local pairPoints=type(projection.pairPoints)=="table" and projection.pairPoints or {}
    local plans,totalBase,totalDesired={},0,0
    for _,row in ipairs(rows) do
        if type(row)=="table" then
            local cx1,cy1,cx2,cy2,clipped=ClipSegmentToRect(row.x1,row.y1,row.x2,row.y2,0,0,logicalW,logicalH)
            if cx1~=nil then
                local base=math.max(8,math.min(48,math.floor(tonumber(pairPoints[row.pairKey]) or tonumber(projection.pointCount) or 24)))
                local dx,dy=cx2-cx1,cy2-cy1
                local length=math.sqrt(dx*dx+dy*dy)
                local desired=DesiredUnitLinePointCount(length,base)
                local plan={ row=row,x1=cx1,y1=cy1,x2=cx2,y2=cy2,length=length,base=base,desired=desired,count=base,clipped=clipped==true }
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
        local dot,dotErr=S.UI:CreateEmptyWidget(host,"v3_visual_unit_"..pairKey.."_dot_"..tostring(index),0,0,4,4,false,self.owner)
        if dot==nil then return nil,dotErr end
        local row={root=dot,drawable=NewColorDrawable(dot),renderState={visible=false}}; pool[index]=row
        if row.drawable==nil then return nil,"visual_unit_dot_drawable_failed" end
        S.UI:SetAnchor(row.drawable,dot,0,0,self.owner); S.UI:SetExtent(row.drawable,4,4,self.owner); S.UI:SetVisible(dot,false,self.owner)
        created=created+1
    end
    return pool,nil,created,#pool>=count
end

function P:SetUnitDotVisible(dot, visible)
    if type(dot)~="table" or dot.root==nil then return false end
    local state=type(dot.renderState)=="table" and dot.renderState or {}; dot.renderState=state
    local value=visible==true
    if state.visible==value then return false end
    S.UI:SetVisible(dot.root,value,self.owner); state.visible=value
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
            local dot, dotErr = S.UI:CreateEmptyWidget(host, "v3_visual_" .. kind .. "_dot_" .. tostring(index), 0, 0, 4, 4, false, self.owner)
            if dot == nil then return false, dotErr end
            row={root=dot,drawable=nil}; pool[index]=row
            S.UI:SetVisible(dot, false, self.owner)
        end
        if row.drawable==nil then
            row.drawable=NewColorDrawable(row.root)
            if row.drawable==nil then S.UI:SetVisible(row.root,false,self.owner); return false,"visual_dot_drawable_failed" end
            S.UI:SetAnchor(row.drawable,row.root,0,0,self.owner); S.UI:SetExtent(row.drawable,4,4,self.owner)
        end
    end
    return true
end

function P:HidePool(pool)
    for _,dot in ipairs(pool) do S.UI:SetVisible(dot.root, false, self.owner) end
end

function P:PlaceUnitDot(dot, x, y, size, opacity, pairKey, r, g, b)
    if type(dot)~="table" or dot.root==nil or dot.drawable==nil then return 0,0,0 end
    size=math.max(2,math.min(10,math.floor(tonumber(size) or 4)))
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
    -- Local Presenter cache intentionally sits above RSUI's defensive Native
    -- cache.  Calling RSUI with an unchanged value still performs compatibility
    -- getters on RU builds; hundreds of dots doing that every frame was a real
    -- crowd hitch even when no property changed.
    if state.x~=px or state.y~=py then
        S.UI:SetAnchor(dot.root,self.unitHost,px,py,self.owner)
        state.x,state.y=px,py; anchorWrites=1
    end
    if state.size~=size then
        S.UI:SetExtent(dot.root,size,size,self.owner)
        S.UI:SetExtent(dot.drawable,size,size,self.owner)
        state.size=size; styleWrites=styleWrites+2
    end
    if state.r~=cr or state.g~=cg or state.b~=cb or state.a~=alpha then
        S.UI:SetColor(dot.drawable,cr,cg,cb,alpha,self.owner)
        state.r,state.g,state.b,state.a=cr,cg,cb,alpha; styleWrites=styleWrites+1
    end
    if self:SetUnitDotVisible(dot,true) then visibilityWrites=1 end
    return anchorWrites,styleWrites,visibilityWrites
end

function P:PlaceDot(dot, x, y, size, opacity, kind, pairKey, r, g, b)
    size=math.max(2,math.min(10,math.floor(tonumber(size) or 4)))
    S.UI:SetAnchor(dot.root, kind == "unit" and self.unitHost or self.rangeHost, math.floor((tonumber(x) or 0)-size/2), math.floor((tonumber(y) or 0)-size/2), self.owner)
    S.UI:SetExtent(dot.root, size, size, self.owner)
    S.UI:SetAnchor(dot.drawable, dot.root, 0, 0, self.owner); S.UI:SetExtent(dot.drawable, size, size, self.owner)
    if kind == "range" then
        -- r,g,b are passed by RenderRange from the persisted projection color;
        -- fall back to the original (0.20, 0.82, 1.00) when none is set.
        S.UI:SetColor(dot.drawable, r or 0.20, g or 0.82, b or 1.00, math.max(0.1,math.min(1,tonumber(opacity) or 0.68)), self.owner)
    else
        local cr, cg, cb = r, g, b
        if cr == nil then
            local c = UNIT_COLORS[tostring(pairKey or "target")] or UNIT_COLORS.target
            cr, cg, cb = c[1], c[2], c[3]
        end
        S.UI:SetColor(dot.drawable, cr, cg, cb, math.max(0.1,math.min(1,tonumber(opacity) or 0.78)),self.owner)
    end
    S.UI:SetVisible(dot.root, true, self.owner)
end

function P:RenderUnit()
    if self.unitHeld ~= true then self:HideUnitPools(); return true end
    local projection=UnitFeature:GetProjection() or {}; local rows=type(projection.rows)=="table" and projection.rows or {}
    if #rows==0 then self:HideUnitPools(); return true end
    local pairSizes = type(projection.pairSizes) == "table" and projection.pairSizes or {}
    local _,_,_,logicalW,logicalH=S.Api:GetUiMetrics(); logicalW,logicalH=tonumber(logicalW) or 1024,tonumber(logicalH) or 768
    local pressure="Normal"
    if type(S.FrameBudget)=="table" and type(S.FrameBudget.current)=="table" then pressure=tostring(S.FrameBudget.current.pressure or "Normal") end
    local plans,budget=self:BuildUnitLineSamplePlan(rows,projection,logicalW,logicalH,pressure)
    local active,visibleDots,requestedDots,clippedEdges={},0,0,0
    local anchorWrites,styleWrites,visibilityWrites,poolGrowth=0,0,0,0
    local growthRemaining=UnitLinePoolGrowthBudget(pressure)
    for _,plan in ipairs(plans) do
        local row=plan.row
        local key=tostring(row.pairKey or row.key or "target"):gsub("[^%w_]","_")
        local requested=math.max(2,math.min(UNIT_LINE_PAIR_HARD_CAP,math.floor(tonumber(plan.count) or 2)))
        requestedDots=requestedDots+requested
        local size=math.max(2,math.min(10,math.floor(tonumber(pairSizes[row.pairKey]) or tonumber(projection.pointSize) or 4)))
        local cr,cg,cb=UnitLineColor(projection,row.pairKey)
        local pool,err,created=self:EnsureUnitPairPool(key,requested,growthRemaining); if pool==nil then return false,err end
        created=math.max(0,tonumber(created) or 0); growthRemaining=math.max(0,growthRemaining-created); poolGrowth=poolGrowth+created
        local count=math.min(requested,#pool)
        active[key]=true; visibleDots=visibleDots+count
        if plan.clipped==true then clippedEdges=clippedEdges+1 end
        for i=1,count do
            local t=(i-1)/math.max(1,count-1)
            local aw,sw,vw=self:PlaceUnitDot(pool[i],plan.x1+(plan.x2-plan.x1)*t,plan.y1+(plan.y2-plan.y1)*t,size,projection.opacity,key,cr,cg,cb)
            anchorWrites=anchorWrites+(tonumber(aw) or 0); styleWrites=styleWrites+(tonumber(sw) or 0); visibilityWrites=visibilityWrites+(tonumber(vw) or 0)
        end
        for i=count+1,#pool do if self:SetUnitDotVisible(pool[i],false) then visibilityWrites=visibilityWrites+1 end end
    end
    for key,pool in pairs(self.unitPools) do
        if active[key]~=true then for _,dot in ipairs(pool) do if self:SetUnitDotVisible(dot,false) then visibilityWrites=visibilityWrites+1 end end end
    end
    self.lastUnitSampling={budget=budget,pressure=pressure,visibleEdges=#plans,clippedEdges=clippedEdges,requestedDots=requestedDots,
        visibleDots=visibleDots,poolGrowth=poolGrowth,anchorWrites=anchorWrites,styleWrites=styleWrites,visibilityWrites=visibilityWrites}
    return true
end

function P:RenderRange()
    if self.rangeHeld ~= true then self:HidePool(self.rangePool); return true end
    local projection=RangeFeature:GetProjection() or {}; local row=projection.rows and projection.rows[1] or nil
    local points=type(row)=="table" and type(row.points)=="table" and row.points or {}
    if #points<3 then self:HidePool(self.rangePool); return true end
    -- Range line color is now configurable via the page ColorField; fall back to
    -- the legacy default when no color has been persisted.
    local rc=type(projection.color)=="table" and projection.color or nil
    local rr,rg,rb=rc and (tonumber(rc[1]) or 0.20) or 0.20, rc and (tonumber(rc[2]) or 0.82) or 0.82, rc and (tonumber(rc[3]) or 1.00) or 1.00
    local count=math.min(48,#points); local ok,err=self:EnsurePool("range",count); if ok~=true then return false,err end
    for i=1,count do self:PlaceDot(self.rangePool[i],points[i].x,points[i].y,projection.pointSize,projection.opacity,"range",nil,rr,rg,rb) end
    for i=count+1,#self.rangePool do S.UI:SetVisible(self.rangePool[i].root,false,self.owner) end
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
    local acquiredNow=false
    if self[heldField]~=true then
        local ok,err=feature:AcquireConsumer(token); if ok~=true then return false,err end
        self[heldField]=true; acquiredNow=true
    end
    local rendered,renderErr
    if kind=="unit" then rendered,renderErr=self:RenderUnit() else rendered,renderErr=self:RenderRange() end
    if rendered~=true and acquiredNow then
        feature:ReleaseConsumer(token); self[heldField]=false
    end
    return rendered,renderErr
end
function P:Reconcile(reason)
    local ok1,err1=self:ReconcileOne(UnitFeature,"combat_unit_lines",self.unitToken,"unitHeld","unit")
    local ok2,err2=self:ReconcileOne(RangeFeature,"combat_range_assist",self.rangeToken,"rangeHeld","range")
    return ok1==true and ok2==true, err1 or err2
end
function P:Describe() local sample=type(self.lastUnitSampling)=="table" and self.lastUnitSampling or {}; return {version=self.version,adaptiveUnitLineSampling=tonumber(self.AdaptiveUnitLineSamplingContractVersion) or 0,unitLinePressureBudget=tonumber(self.UnitLinePressureBudgetContractVersion) or 0,unitLineDiffRender=tonumber(self.UnitLineDiffRenderContractVersion) or 0,unitLineProgressivePool=tonumber(self.UnitLineProgressivePoolContractVersion) or 0,unitHeld=self.unitHeld==true,rangeHeld=self.rangeHeld==true,unitDots=(function() local n=0; for _,pool in pairs(self.unitPools) do n=n+#pool end; return n end)(),unitVisibleDots=tonumber(sample.visibleDots) or 0,unitRequestedDots=tonumber(sample.requestedDots) or 0,unitVisibleEdges=tonumber(sample.visibleEdges) or 0,unitClippedEdges=tonumber(sample.clippedEdges) or 0,unitBudget=tonumber(sample.budget) or 0,unitPressure=tostring(sample.pressure or "Normal"),unitPoolGrowth=tonumber(sample.poolGrowth) or 0,unitAnchorWrites=tonumber(sample.anchorWrites) or 0,unitStyleWrites=tonumber(sample.styleWrites) or 0,unitVisibilityWrites=tonumber(sample.visibilityWrites) or 0,rangeDots=#self.rangePool} end

if S.Events ~= nil and type(S.Events.SubscribeInternal)=="function" then
    S.Events:SubscribeInternal((S.FeatureRuntime and S.FeatureRuntime.LifecycleTopic) or "v3.feature.lifecycle",P.eventOwner,function(_,featureId)
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
