------------------------------------------------------------------------
-- Replicated Suite - RSUI UMG-style Panel / Slot Components v1
--
-- Layout contract:
--   Measure(availableW, availableH) -> desired size (no native layout writes)
--   Layout(x, y, width, height)     -> arrange children through cached UI writes
--
-- Panel/Slot work is event/layout driven only; never call this from Tick.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local UI, RSUI = S.UI, S.RSUI
if type(UI) ~= "table" or type(RSUI) ~= "table" then return end
local Tokens = S.UITokens or {}
local Base = RSUI.BaseComponent

local function Token(path, fallback)
    if type(Tokens.Number) == "function" then return Tokens:Number(path, fallback) end
    return tonumber(fallback) or 0
end
local function N(v, fallback) local x = tonumber(v); if x == nil then return tonumber(fallback) or 0 end return x end
local function Clamp(v, lo, hi) v=N(v,0); if lo~=nil then v=math.max(v,N(lo,0)) end; if hi~=nil then v=math.min(v,N(hi,v)) end; return v end
local function Pad(value)
    if type(value) == "number" then return { left=value, top=value, right=value, bottom=value } end
    value = type(value) == "table" and value or {}
    local x, y = N(value.x or value.horizontal, 0), N(value.y or value.vertical, 0)
    return { left=N(value.left,x), top=N(value.top,y), right=N(value.right,x), bottom=N(value.bottom,y) }
end
local function Slot(slot)
    slot = type(slot) == "table" and slot or {}
    local out = {}
    for k,v in pairs(slot) do out[k]=v end
    out.padding = Pad(slot.padding)
    out.fill = tonumber(slot.fill or slot.fillWeight)
    out.size = tostring(slot.size or (out.fill and "fill") or "auto"):lower()
    out.hAlign = tostring(slot.hAlign or slot.horizontalAlignment or "fill"):lower()
    out.vAlign = tostring(slot.vAlign or slot.verticalAlignment or "fill"):lower()
    return out
end
local function Measure(child, aw, ah)
    if type(child) ~= "table" or child.visible == false then return 0,0 end
    local sameConstraint = child.lastMeasureAvailableW == aw and child.lastMeasureAvailableH == ah
    if child.measureDirty ~= true and sameConstraint and tonumber(child.desiredWidth) ~= nil and tonumber(child.desiredHeight) ~= nil then
        RSUI.metrics.measureSkips = (tonumber(RSUI.metrics.measureSkips) or 0) + 1
        return math.max(0,N(child.desiredWidth,0)), math.max(0,N(child.desiredHeight,0))
    end
    if type(child.Measure) == "function" then
        local ok,w,h = pcall(function() return child:Measure(aw,ah) end)
        if ok then
            child.lastMeasureAvailableW, child.lastMeasureAvailableH = aw, ah
            RSUI.metrics.measurePasses = (tonumber(RSUI.metrics.measurePasses) or 0) + 1
            return math.max(0,N(w,0)), math.max(0,N(h,0))
        end
    end
    return math.max(0,N(child.width or (child.spec and child.spec.width),0)), math.max(0,N(child.height or (child.spec and child.spec.height),0))
end
local function Align(start, available, desired, mode)
    desired = math.min(math.max(0, desired), math.max(0, available))
    if mode == "fill" or mode == "stretch" then return start, math.max(0,available) end
    if mode == "center" then return start + math.max(0,(available-desired)/2), desired end
    if mode == "right" or mode == "bottom" then return start + math.max(0,available-desired), desired end
    return start, desired
end
local function Arrange(child, x, y, width, height, force)
    if type(child) ~= "table" or child.visible == false then return false end
    if type(child.LayoutIfNeeded) == "function" then return child:LayoutIfNeeded(x, y, width, height, force) end
    if type(child.Layout) == "function" then child:Layout(x, y, width, height); return true end
    return false
end
local function Host(kind, spec, rootFactory)
    local root
    if type(rootFactory) == "function" then
        root = rootFactory(spec)
    else
        root = UI:CreateEmptyWidget(spec.parent, spec.id, N(spec.x,0), N(spec.y,0), math.max(1,N(spec.width,1)), math.max(1,N(spec.height,1)), spec.pickable==true)
    end
    if root == nil then return nil, string.lower(kind).."_create_failed" end
    local c = RSUI:NewComponent(kind, spec, root)
    c.slots, c.gap = {}, math.max(0,N(spec.gap,Token("spacing.sm",8)))
    local baseAdd = Base.AddChild
    function c:UpdateChildSlot(child, slot)
        if type(child) ~= "table" then return nil end
        local normalized = Slot(slot or child.slot)
        for _, entry in ipairs(self.slots) do
            if entry.child == child then
                entry.slot = normalized
                child.slot = slot or child.slot
                self:InvalidateMeasure("slot_changed")
                return normalized
            end
        end
        self.slots[#self.slots + 1] = { child = child, slot = normalized }
        child.slot = slot or child.slot
        self:InvalidateMeasure("slot_added")
        return normalized
    end
    function c:AddChild(child, slot)
        local attached, ok, attachErr = baseAdd(self, child, slot)
        if attached == nil then return nil, false, attachErr end
        if type(attached)=="table" then self:UpdateChildSlot(attached, slot or attached.slot) end
        return attached, ok, attachErr
    end
    function c:GetContentRoot() return self.root end
    return c
end

-- Shared pure helpers for later UMG-like panels. Keeping Slot normalization and
-- Measure/Align semantics here prevents each panel family from inventing a
-- slightly different layout contract.
RSUI.LayoutUtil = { N = N, Clamp = Clamp, Pad = Pad, Slot = Slot, Measure = Measure, Align = Align, Arrange = Arrange, Host = Host }

local function NewLinear(kind, axis, spec)
    local c,err=Host(kind,spec); if c==nil then return nil,err end
    c.axis=axis
    function c:Measure(availableW,availableH)
        local p=Pad(self.spec.padding); local primary,cross=0,0; local count=0
        for _,entry in ipairs(self.slots) do
            local child,slot=entry.child,entry.slot
            if child.visible~=false then
                local dw,dh=Measure(child, availableW, availableH)
                local cp = axis=="x" and (dw+slot.padding.left+slot.padding.right) or (dh+slot.padding.top+slot.padding.bottom)
                local cc = axis=="x" and (dh+slot.padding.top+slot.padding.bottom) or (dw+slot.padding.left+slot.padding.right)
                if slot.size=="fixed" then cp=axis=="x" and N(slot.width,cp) or N(slot.height,cp) end
                primary=primary+cp; cross=math.max(cross,cc); count=count+1
            end
        end
        if count>1 then primary=primary+self.gap*(count-1) end
        local w = axis=="x" and (primary+p.left+p.right) or (cross+p.left+p.right)
        local h = axis=="x" and (cross+p.top+p.bottom) or (primary+p.top+p.bottom)
        w=Clamp(w,self.spec.minWidth,self.spec.maxWidth); h=Clamp(h,self.spec.minHeight,self.spec.maxHeight)
        if availableW~=nil and self.spec.allowOverflow~=true then w=math.min(w,math.max(0,N(availableW,0))) end
        if availableH~=nil and self.spec.allowOverflow~=true then h=math.min(h,math.max(0,N(availableH,0))) end
        self.desiredWidth,self.desiredHeight=w,h; self.measureDirty=false; return w,h
    end
    function c:Layout(x,y,width,height)
        width,height=math.max(1,N(width,self.width or self.spec.width or 1)),math.max(1,N(height,self.height or self.spec.height or 1))
        self:SetBounds(x,y,width,height)
        local p=Pad(self.spec.padding)
        local innerW=math.max(0,width-p.left-p.right)
        local innerH=math.max(0,height-p.top-p.bottom)
        local primaryAvail=axis=="x" and innerW or innerH
        local crossAvail=axis=="x" and innerH or innerW

        -- Measure/Arrange must agree about Fill children.  The old layout pass
        -- excluded Fill minimums from the required size and then divided the
        -- entire remainder between Fill slots.  Under tight layouts that could
        -- silently allocate a Fill child below its declared min size, while
        -- Measure still reported the larger desired size.  That mismatch is a
        -- common source of clipped/overlapping descendants.
        local visibleCount,totalNonFill,totalFillMin,totalFillWeight=0,0,0,0
        local work={}
        for _,entry in ipairs(self.slots) do
            local child,slot=entry.child,entry.slot
            if child.visible~=false then
                local dw,dh=Measure(child,innerW,innerH)
                local desiredPrimary=axis=="x" and dw or dh
                local padPrimary=axis=="x" and (slot.padding.left+slot.padding.right) or (slot.padding.top+slot.padding.bottom)
                local childSpec=type(child.spec)=="table" and child.spec or {}
                local minPrimary=axis=="x" and N(slot.minWidth or childSpec.minWidth,1) or N(slot.minHeight or childSpec.minHeight,1)
                local maxPrimary=axis=="x" and tonumber(slot.maxWidth or childSpec.maxWidth) or tonumber(slot.maxHeight or childSpec.maxHeight)
                desiredPrimary=Clamp(desiredPrimary,minPrimary,maxPrimary)

                local base=desiredPrimary+padPrimary
                if slot.size=="fixed" then
                    local fixed=axis=="x" and N(slot.width,desiredPrimary) or N(slot.height,desiredPrimary)
                    fixed=Clamp(fixed,minPrimary,maxPrimary)
                    base=fixed+padPrimary
                end
                local minBase=math.max(padPrimary,minPrimary+padPrimary)
                local fillWeight=math.max(0.0001,N(slot.fill,1))
                local item={
                    child=child,slot=slot,dw=dw,dh=dh,base=base,minBase=minBase,
                    allocated=slot.size=="fill" and minBase or base,fillWeight=fillWeight,
                }
                work[#work+1]=item
                visibleCount=visibleCount+1
                if slot.size=="fill" then
                    totalFillMin=totalFillMin+minBase
                    totalFillWeight=totalFillWeight+fillWeight
                else
                    totalNonFill=totalNonFill+base
                end
            end
        end

        local gaps=self.gap*math.max(0,visibleCount-1)
        local required=totalNonFill+totalFillMin+gaps
        local deficit=math.max(0,required-primaryAvail)
        if deficit>0 and self.state.lastCompressionDeficit~=deficit then
            RSUI.metrics.layoutCompressionEvents=(tonumber(RSUI.metrics.layoutCompressionEvents) or 0)+1
        end
        self.state.lastCompressionDeficit=deficit

        -- Only Auto slots are compressed automatically. Fixed stays authoritative
        -- and Fill never drops below its declared minimum. If even those minima
        -- cannot fit we expose overflow instead of creating hidden overlap.
        if deficit>0 then
            local shrinkable=0
            for _,item in ipairs(work) do
                if item.slot.size~="fill" and item.slot.size~="fixed" then
                    shrinkable=shrinkable+math.max(0,item.base-item.minBase)
                end
            end
            if shrinkable>0 then
                local used=math.min(deficit,shrinkable)
                for _,item in ipairs(work) do
                    if item.slot.size~="fill" and item.slot.size~="fixed" then
                        local room=math.max(0,item.base-item.minBase)
                        item.allocated=math.max(item.minBase,item.base-used*(room/shrinkable))
                    end
                end
                totalNonFill=0
                for _,item in ipairs(work) do
                    if item.slot.size~="fill" then totalNonFill=totalNonFill+(item.allocated or item.base) end
                end
            end
        end

        local requiredAfter=totalNonFill+totalFillMin+gaps
        local extra=math.max(0,primaryAvail-requiredAfter)
        self.lastOverflow=math.max(0,requiredAfter-primaryAvail)
        if self.lastOverflow>0 and self.state.lastOverflowAmount~=self.lastOverflow then
            RSUI.metrics.layoutOverflowEvents=(tonumber(RSUI.metrics.layoutOverflowEvents) or 0)+1
        end
        self.state.lastOverflowAmount=self.lastOverflow

        local cursor=axis=="x" and p.left or p.top
        local arrangedIndex=0
        for _,item in ipairs(work) do
            arrangedIndex=arrangedIndex+1
            local slot=item.slot
            local allocated=item.allocated or item.base
            if slot.size=="fill" then
                allocated=item.minBase + extra*(item.fillWeight/math.max(0.0001,totalFillWeight))
            end
            local pad=slot.padding
            local contentPrimary=math.max(0,allocated-(axis=="x" and (pad.left+pad.right) or (pad.top+pad.bottom)))
            local contentCross=math.max(0,crossAvail-(axis=="x" and (pad.top+pad.bottom) or (pad.left+pad.right)))
            local px,py,pw,ph
            if axis=="x" then
                local minCross=N(slot.minHeight or (item.child.spec and item.child.spec.minHeight),0)
                local maxCross=tonumber(slot.maxHeight or (item.child.spec and item.child.spec.maxHeight))
                local desiredCross=Clamp(item.dh,minCross,maxCross)
                local crossStart,crossSize=Align(p.top+pad.top,contentCross,desiredCross,slot.vAlign)
                local primaryStart,primarySize=Align(cursor+pad.left,contentPrimary,item.dw,slot.hAlign=="fill" and "fill" or slot.hAlign)
                px,py,pw,ph=primaryStart,crossStart,primarySize,crossSize
            else
                local minCross=N(slot.minWidth or (item.child.spec and item.child.spec.minWidth),0)
                local maxCross=tonumber(slot.maxWidth or (item.child.spec and item.child.spec.maxWidth))
                local desiredCross=Clamp(item.dw,minCross,maxCross)
                local crossStart,crossSize=Align(p.left+pad.left,contentCross,desiredCross,slot.hAlign)
                local primaryStart,primarySize=Align(cursor+pad.top,contentPrimary,item.dh,slot.vAlign=="fill" and "fill" or slot.vAlign)
                px,py,pw,ph=crossStart,primaryStart,crossSize,primarySize
            end
            Arrange(item.child,px,py,math.max(1,pw),math.max(1,ph))
            cursor=cursor+allocated
            if arrangedIndex<visibleCount then cursor=cursor+self.gap end
        end
        return axis=="x" and width or height
    end
    return c
end

RSUI:RegisterType("HorizontalBox", function(spec) return NewLinear("HorizontalBox","x",spec) end)
RSUI:RegisterType("VerticalBox", function(spec) return NewLinear("VerticalBox","y",spec) end)

RSUI:RegisterType("Overlay", function(spec)
    local c,err=Host("Overlay",spec); if c==nil then return nil,err end
    function c:Measure(aw,ah)
        local p=Pad(self.spec.padding); local w,h=0,0
        for _,entry in ipairs(self.slots) do local dw,dh=Measure(entry.child,aw,ah); w=math.max(w,dw+entry.slot.padding.left+entry.slot.padding.right); h=math.max(h,dh+entry.slot.padding.top+entry.slot.padding.bottom) end
        w=w+p.left+p.right; h=h+p.top+p.bottom; self.desiredWidth,self.desiredHeight=w,h; self.measureDirty=false; return w,h
    end
    function c:Layout(x,y,width,height)
        width,height=math.max(1,N(width,self.width or 1)),math.max(1,N(height,self.height or 1)); self:SetBounds(x,y,width,height)
        local p=Pad(self.spec.padding); local iw,ih=math.max(0,width-p.left-p.right),math.max(0,height-p.top-p.bottom)
        for _,entry in ipairs(self.slots) do
            local child,slot=entry.child,entry.slot
            if child.visible~=false then
                local dw,dh=Measure(child,iw,ih); local pad=slot.padding
                local ax,aw=Align(p.left+pad.left,math.max(0,iw-pad.left-pad.right),dw,slot.hAlign)
                local ay,ah=Align(p.top+pad.top,math.max(0,ih-pad.top-pad.bottom),dh,slot.vAlign)
                Arrange(child,ax,ay,math.max(1,aw),math.max(1,ah))
            end
        end
        return height
    end
    return c
end)

RSUI:RegisterType("Grid", function(spec)
    local c,err=Host("Grid",spec); if c==nil then return nil,err end
    c.columns=math.max(1,math.floor(N(spec.columns,2))); c.columnGap=math.max(0,N(spec.columnGap or spec.gapX,c.gap)); c.rowGap=math.max(0,N(spec.rowGap or spec.gapY,c.gap))
    function c:Measure(aw,ah)
        local p=Pad(self.spec.padding); local colW,rowH={},{}
        for _,entry in ipairs(self.slots) do
            local s=entry.slot; local col=math.max(1,math.floor(N(s.column,1))); local row=math.max(1,math.floor(N(s.row,1))); local dw,dh=Measure(entry.child,aw,ah)
            local cs=math.max(1,math.floor(N(s.columnSpan,1))); local rs=math.max(1,math.floor(N(s.rowSpan,1)))
            local perW=(dw+s.padding.left+s.padding.right)/cs; local perH=(dh+s.padding.top+s.padding.bottom)/rs
            for i=col,col+cs-1 do colW[i]=math.max(colW[i] or 0,perW) end
            for i=row,row+rs-1 do rowH[i]=math.max(rowH[i] or 0,perH) end
        end
        local w,h,maxRow=0,0,0; for i=1,self.columns do w=w+(colW[i] or 0) end; if self.columns>1 then w=w+self.columnGap*(self.columns-1) end
        for i,v in pairs(rowH) do maxRow=math.max(maxRow,i) end; for i=1,maxRow do h=h+(rowH[i] or 0) end; if maxRow>1 then h=h+self.rowGap*(maxRow-1) end
        w=w+p.left+p.right; h=h+p.top+p.bottom; self.desiredWidth,self.desiredHeight=w,h; self.measureDirty=false; return w,h
    end
    function c:Layout(x,y,width,height)
        width,height=math.max(1,N(width,self.width or 1)),math.max(1,N(height,self.height or 1)); self:SetBounds(x,y,width,height)
        local p=Pad(self.spec.padding); local iw=math.max(0,width-p.left-p.right); local cellW=math.max(0,(iw-self.columnGap*(self.columns-1))/self.columns)
        local rowHeights,maxRow={},0
        for _,entry in ipairs(self.slots) do local s=entry.slot; local row=math.max(1,math.floor(N(s.row,1))); local rs=math.max(1,math.floor(N(s.rowSpan,1))); local _,dh=Measure(entry.child,cellW,nil); local per=(dh+s.padding.top+s.padding.bottom)/rs; for r=row,row+rs-1 do rowHeights[r]=math.max(rowHeights[r] or 0,per); maxRow=math.max(maxRow,r) end end
        local rowY={}; local cy=p.top; for r=1,maxRow do rowY[r]=cy; cy=cy+(rowHeights[r] or 0)+self.rowGap end
        for _,entry in ipairs(self.slots) do
            local child,s=entry.child,entry.slot; if child.visible~=false then
                local col=math.max(1,math.min(self.columns,math.floor(N(s.column,1)))); local row=math.max(1,math.floor(N(s.row,1))); local cs=math.max(1,math.min(self.columns-col+1,math.floor(N(s.columnSpan,1)))); local rs=math.max(1,math.floor(N(s.rowSpan,1)))
                local sx=p.left+(col-1)*(cellW+self.columnGap); local sw=cellW*cs+self.columnGap*(cs-1); local sh=0; for r=row,row+rs-1 do sh=sh+(rowHeights[r] or 0) end; sh=sh+self.rowGap*(rs-1)
                local pad=s.padding; local dw,dh=Measure(child,sw,sh); local ax,aw=Align(sx+pad.left,math.max(0,sw-pad.left-pad.right),dw,s.hAlign); local ay,ah=Align((rowY[row] or p.top)+pad.top,math.max(0,sh-pad.top-pad.bottom),dh,s.vAlign)
                Arrange(child,ax,ay,math.max(1,aw),math.max(1,ah))
            end
        end
        return math.max(height,cy-p.top)
    end
    return c
end)

RSUI:RegisterType("SizeBox", function(spec)
    local c,err=Host("SizeBox",spec); if c==nil then return nil,err end; c.content=nil
    local baseAdd=Base.AddChild
    function c:AddChild(child,slot) local attached,ok,attachErr=baseAdd(self,child,slot); if attached~=nil and self.content==nil then self.content=attached end; return attached,ok,attachErr end
    function c:Measure(aw,ah)
        local dw,dh=Measure(self.content,aw,ah)
        local w=tonumber(self.spec.widthOverride) or dw; local h=tonumber(self.spec.heightOverride) or dh
        w=Clamp(w,self.spec.minWidth,self.spec.maxWidth); h=Clamp(h,self.spec.minHeight,self.spec.maxHeight)
        if aw~=nil and self.spec.allowOverflow~=true then w=math.min(w,N(aw,w)) end; if ah~=nil and self.spec.allowOverflow~=true then h=math.min(h,N(ah,h)) end
        self.desiredWidth,self.desiredHeight=w,h; self.measureDirty=false; return w,h
    end
    function c:Layout(x,y,width,height)
        local dw,dh=self:Measure(width,height); width=math.max(1,tonumber(self.spec.widthOverride) or N(width,dw)); height=math.max(1,tonumber(self.spec.heightOverride) or N(height,dh)); self:SetBounds(x,y,width,height)
        if self.content~=nil and self.content.visible~=false then local cw,ch=Measure(self.content,width,height); local ha=tostring(self.spec.hAlign or "fill"):lower(); local va=tostring(self.spec.vAlign or "fill"):lower(); local cx,cww=Align(0,width,cw,ha); local cy,chh=Align(0,height,ch,va); Arrange(self.content,cx,cy,math.max(1,cww),math.max(1,chh)) end
        return height
    end
    return c
end)

RSUI:RegisterType("Border", function(spec)
    local root=UI:CreatePanel(spec.parent,spec.id,N(spec.x,0),N(spec.y,0),math.max(1,N(spec.width,1)),math.max(1,N(spec.height,1)),spec.variant or "card",{gradient=spec.gradient,gradientKind=spec.gradientKind,accentStrip=spec.accentStrip})
    if root==nil then return nil,"border_create_failed" end
    local c=RSUI:NewComponent("Border",spec,root); c.content=nil; c.padding=Pad(spec.padding or Token("component.card.padding",8)); local baseAdd=Base.AddChild
    function c:AddChild(child,slot) local attached,ok,attachErr=baseAdd(self,child,slot); if attached~=nil and self.content==nil then self.content=attached end; return attached,ok,attachErr end
    function c:Measure(aw,ah) local p=self.padding; local dw,dh=Measure(self.content,aw and math.max(0,aw-p.left-p.right),ah and math.max(0,ah-p.top-p.bottom)); local w=dw+p.left+p.right; local h=dh+p.top+p.bottom; if self.spec.width then w=N(self.spec.width,w) end; if self.spec.height then h=N(self.spec.height,h) end; w=Clamp(w,self.spec.minWidth,self.spec.maxWidth); h=Clamp(h,self.spec.minHeight,self.spec.maxHeight); self.desiredWidth,self.desiredHeight=w,h; self.measureDirty=false; return w,h end
    function c:Layout(x,y,width,height) width,height=math.max(1,N(width,self.width or self.spec.width or 1)),math.max(1,N(height,self.height or self.spec.height or 1)); self:SetBounds(x,y,width,height); if self.content~=nil and self.content.visible~=false then local p=self.padding; Arrange(self.content,p.left,p.top,math.max(1,width-p.left-p.right),math.max(1,height-p.top-p.bottom)) end; return height end
    return c
end)
