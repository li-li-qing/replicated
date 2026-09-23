-- 中文维护：独立 Native/RSUI 叶节点模型，运行真实 Api/Layout/Windowing/WindowShell/FloatingSurface。
-- 不补造缺失历史 gear host，不代表 RU API 权限/回调触发已实测；仅测试同步几何、缓存及拒绝语义。
return function(options)
    options = options or {}
    local h = { w=1920, h=1080, scale=1, sw=1920, sh=1080, effective=1, writes=0, samples=0, tasks={}, events={}, resizeConfigCalls=0 }
    local S = { Generation=921, SafeTraceback=debug.traceback, ArchitectureMode='v3_rebuild', PhysicalId=function(s)return s end,
        Constants={SafeArea=12, MinAddonScale=.5, MaxAddonScale=2, Breakpoint={COMPACT=1150, STANDARD=1700, WIDE=2300,NARROW_ONE_COLUMN=760}},
        AppState={settings={addonScale=1}}, UI={NativeStateCache={}}, RSUI={}, }
    ReplicatedSuite=S; h.S=S
    local UI,R=S.UI,S.RSUI
    local function Native(parent,id,x,y,w,hh)
        if parent=='UIParent' then parent=UIParent end
        local n={parent=parent,id=id,x=x or 0,y=y or 0,w=w or 1,h=hh or 1,visible=false,handlers={}}
        function n:GetOffset()return self.x,self.y end
        function n:GetExtent()return self.w,self.h end
        function n:GetWidth()return self.w end;function n:GetHeight()return self.h end
        function n:GetEffectiveOffset()
            local px,py=0,0;if self.parent then px,py=self.parent:GetEffectiveOffset() end
            return px+self.x*h.effective,py+self.y*h.effective
        end
        function n:GetEffectiveExtent()return self.w*h.effective,self.h*h.effective end
        function n:SetExtent(w1,h1)self.w=w1;self.h=h1;return true end
        function n:RemoveAllAnchors()self.anchorRemoved=true;return true end
        function n:AddAnchor(_,parent1,x1,y1)self.parent=parent1=='UIParent' and UIParent or parent1;self.x=x1;self.y=y1;return true end
        function n:SetHandler(name,fn)self.handlers[name]=fn;return true end
        function n:ReleaseHandler(name)self.handlers[name]=nil;return true end
        function n:HasHandler(name)return self.handlers[name]~=nil end
        function n:Show(v)self.visible=v;return true end;function n:IsVisible()return self.visible end
        function n:RegisterEvent(name)self.events=self.events or {};self.events[name]=true;return true end
        function n:UnregisterEvent(name)if self.events then self.events[name]=nil end;return true end
        function n:Raise()self.raiseCount=(self.raiseCount or 0)+1;return true end;function n:EnableDrag()return true end
        function n:StartMoving()self.moving=true;return true end
        function n:StartSizing()self.moving=true;return true end
        function n:StopMovingOrSizing()self.moving=false;return true end
        function n:SetMinResizingExtent(w1,h1)self.minW=w1;self.minH=h1;h.resizeConfigCalls=h.resizeConfigCalls+1;return true end
        function n:SetMaxResizingExtent(w1,h1)self.maxW=w1;self.maxH=h1;h.resizeConfigCalls=h.resizeConfigCalls+1;return true end
        function n:UseResizing(v)self.resizing=v;h.resizeConfigCalls=h.resizeConfigCalls+1;return true end
        function n:SetUILayer(v)self.layer=v;return true end
        function n:SetCloseOnEscape()return true end;function n:SetWindowModal()return true end;function n:SetDrawPriority()return true end
        function n:SetDragCondition()return true end;function n:SetAlpha(v)self.alpha=v;return true end
        function n:CreateColorDrawable(r,g,b,a,layer)
            local d={r=r,g=g,b=b,a=a,layer=layer}
            function d:AddAnchor()return true end
            function d:SetColor(r1,g1,b1,a1)self.r,self.g,self.b,self.a=r1,g1,b1,a1;return true end
            self.drawables=self.drawables or {};self.drawables[#self.drawables+1]=d
            return d
        end
        return n
    end
    h.Native=Native
    UIParent=Native(nil,'UIParent',0,0,h.w,h.h)
    function UIParent:GetExtent()return h.w,h.h end
    function UIParent:GetWidth()return h.w end;function UIParent:GetHeight()return h.h end
    function UIParent:GetUIScale()return h.scale end
    function UIParent:GetEffectiveExtent()return h.w*h.effective,h.h*h.effective end
    _G.UI={GetScreenWidth=function()return h.sw end,GetScreenHeight=function()return h.sh end,GetUIScale=function()return h.scale end}
    local function Row(n)local r=UI.NativeStateCache[n];if not r then r={};UI.NativeStateCache[n]=r end;return r end
    function UI:InvalidateNativeState(n,field)if not field then self.NativeStateCache[n]=nil else Row(n)[field]=nil end end
    function UI:EnsureAnchor(n,p,x,y)
        if h.rejectAnchor then return false,false,'injected_anchor_rejection' end
        local r=Row(n);if r.anchorParent==p and r.anchorX==x and r.anchorY==y then return true,false end
        n.parent=p;n.x=x;n.y=y;r.anchorParent=p;r.anchorX=x;r.anchorY=y;return true,true
    end
    function UI:EnsureExtent(n,w,hh)
        if h.rejectExtent then return false,false,'injected_extent_rejection' end
        local r=Row(n);if r.width==w and r.height==hh then return true,false end
        n.w=w;n.h=hh;r.width=w;r.height=hh;return true,true
    end
    function UI:SetAnchor(...)local ok,changed=self:EnsureAnchor(...);return ok and changed end
    function UI:SetExtent(...)local ok,changed=self:EnsureExtent(...);return ok and changed end
    function UI:EnsureVisible(n,v)
        if h.rejectVisible then return false,false,'injected_visibility_rejection' end
        local r=Row(n);if r.visible==v then return true,false end
        n.visible=v;r.visible=v;return true,true
    end
    function UI:SetVisible(...)local ok,changed=self:EnsureVisible(...);return ok and changed end
    function UI:EnsureAlpha(n,v)n.alpha=v;return true,true end
    function UI:SetAlpha(n,v)n.alpha=v;return true end
    for _,field in ipairs({'Enabled','Pickable'}) do UI['Ensure'..field]=function(_,n,v)n[field]=v;return true,true end end
    UI.ClaimNativeAuthority=function()return true end
    UI.BeginNativeGeometryLease=function(_,n)n.lease=true;return true end
    UI.EndNativeGeometryLease=function(_,n)n.lease=false;return true end
    function UI:TryInteractionCall(n,m,...)if not n[m] then return false,'missing_'..m end;return n[m](n,...)~=false end
    function UI:RequireHandler(n,name,fn)n.handlers[name]=fn;return true end
    UI.SafeHandler=UI.RequireHandler
    function UI:CreateEmptyWidget(p,id,x,y,w,hh)return Native(p,id,x,y,w,hh)end
    S.NativeObjectFactory={CreateWindow=function(_,id,parent)local n=Native(parent,id);h.lastNative=n;return n end}
    local function Component(spec)
        local parent=spec.parent;parent=type(parent)=='table' and (parent.root or parent) or parent
        local c={root=Native(parent,spec.id),spec=spec,children={},text=spec.text}
        function c:Layout(x,y,w,hh)self.x=x;self.y=y;self.width=w;self.height=hh;UI:EnsureAnchor(self.root,parent,x,y);UI:EnsureExtent(self.root,w,hh);return true end
        function c:SetVisibility(v)self.visibility=v;local ok,changed,err=UI:EnsureVisible(self.root,v=='visible');return self,ok,err end
        function c:SetText(v)self.text=v;return self end;function c:SetTone(v)self.tone=v;return self end
        function c:SetOnClick(fn)self.onClick=fn;return self end
        function c:SetLayoutHost(v)self.layoutHost=v end
        function c:Release()return 1 end
        function c:SetSlot(v)self.slot=v;return self end
        function c:InvalidateMeasure()return true end;function c:InvalidateLayout()return true end
        return c
    end
    for _,name in ipairs({'Overlay','Border','HorizontalBox','VerticalBox','Text','Button'})do R[name]=function(_,spec)return Component(spec)end end
    R.ApplyOpacityChannels=function()return true end;R.ApplyFontScale=function()return true end;R.FlushLayoutQueue=function()return true end
    R.ReleaseOwner=function()return 0 end
    R.WindowPreferences={GetTopmost=function()return false end,SetTopmost=function()return true end}
    S.Scheduler={AddOneShot=function(_,id,ms,fn)h.tasks[id]=fn;return true end,RemoveTask=function(_,id)h.tasks[id]=nil;return true end}
    S.Events={SubscribeOptional=function(_,name,owner,fn)h.events[name]={owner=owner,fn=fn};return true end,
        UnsubscribeOwner=function(_,owner)for n,r in pairs(h.events)do if r.owner==owner then h.events[n]=nil end end end,
        Publish=function()return true end}
    function h:Fire(name)local r=self.events[name];if r then return r.fn(r.owner)end end
    function h:Drain()local batch=self.tasks;self.tasks={};for _,fn in pairs(batch)do fn()end end
    function h:Viewport(w,hh,s,sw,sh)self.w=w;self.h=hh;self.scale=s or 1;self.sw=sw or w*self.scale;self.sh=sh or hh*self.scale end
    dofile('core/rs_api.lua')
    local read=S.Api.GetUiMetrics
    function S.Api:GetUiMetrics()h.samples=h.samples+1;return read(self)end
    dofile('core/rs_layout.lua')
    if options.layoutOnly~=true then
        dofile('ui/framework/rs_ui_windowing.lua')
        dofile('ui/framework/rs_ui_window_shell_v3.lua')
        dofile('ui/framework/rs_ui_floating_surface.lua')
    end
    function h:Surface(state,spec)
        spec=spec or {};spec.id=spec.id or 'test_surface';spec.owner=spec.owner or 'viewport_test';spec.state=state
        spec.statePolicy=spec.statePolicy or {defaultWidth=420,defaultHeight=286,minWidth=100,minHeight=100}
        spec.persist=spec.persist or function()self.writes=self.writes+1;return true end
        spec.appearanceControls=false;spec.footer=false
        return assert(S.RSUI.FloatingSurface:Create(spec))
    end
    return h
end
