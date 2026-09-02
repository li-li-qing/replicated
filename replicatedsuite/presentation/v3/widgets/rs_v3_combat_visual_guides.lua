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
P.version = 3
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
function P:EnsureUnitPairPool(pairKey, count)
    pairKey=tostring(pairKey or "target")
    count=math.max(0,math.min(48,math.floor(tonumber(count) or 0)))
    local pool=self.unitPools[pairKey]
    if type(pool)~="table" then pool={}; self.unitPools[pairKey]=pool end
    local host,err=self:EnsureHost("unit"); if host==nil then return nil,err end
    for index=#pool+1,count do
        local dot,dotErr=S.UI:CreateEmptyWidget(host,"v3_visual_unit_"..pairKey.."_dot_"..tostring(index),0,0,4,4,false,self.owner)
        if dot==nil then return nil,dotErr end
        local row={root=dot,drawable=NewColorDrawable(dot)}; pool[index]=row
        if row.drawable==nil then return nil,"visual_unit_dot_drawable_failed" end
        S.UI:SetAnchor(row.drawable,dot,0,0,self.owner); S.UI:SetExtent(row.drawable,4,4,self.owner); S.UI:SetVisible(dot,false,self.owner)
    end
    return pool
end
function P:HideUnitPools()
    for _,pool in pairs(self.unitPools) do self:HidePool(pool) end
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
    local pairPoints = type(projection.pairPoints) == "table" and projection.pairPoints or {}
    local pairSizes = type(projection.pairSizes) == "table" and projection.pairSizes or {}
    local active={}
    for _,row in ipairs(rows) do
        if type(row)=="table" and tonumber(row.x1)~=nil and tonumber(row.y1)~=nil and tonumber(row.x2)~=nil and tonumber(row.y2)~=nil then
            local key=tostring(row.pairKey or row.key or "target"):gsub("[^%w_]","_")
            -- Per-pair points/size override the global defaults when configured.
            local count=math.max(8,math.min(48,math.floor(tonumber(pairPoints[row.pairKey]) or tonumber(projection.pointCount) or 24)))
            local size=math.max(2,math.min(10,math.floor(tonumber(pairSizes[row.pairKey]) or tonumber(projection.pointSize) or 4)))
            local cr,cg,cb=UnitLineColor(projection,row.pairKey)
            local pool,err=self:EnsureUnitPairPool(key,count); if pool==nil then return false,err end
            active[key]=true
            for i=1,count do
                local t=(i-1)/math.max(1,count-1)
                self:PlaceDot(pool[i],row.x1+(row.x2-row.x1)*t,row.y1+(row.y2-row.y1)*t,size,projection.opacity,"unit",key,cr,cg,cb)
            end
            for i=count+1,#pool do S.UI:SetVisible(pool[i].root,false,self.owner) end
        end
    end
    for key,pool in pairs(self.unitPools) do if active[key]~=true then self:HidePool(pool) end end
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
function P:Describe() return {version=self.version,unitHeld=self.unitHeld==true,rangeHeld=self.rangeHeld==true,unitDots=(function() local n=0; for _,pool in pairs(self.unitPools) do n=n+#pool end; return n end)(),rangeDots=#self.rangePool} end

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
