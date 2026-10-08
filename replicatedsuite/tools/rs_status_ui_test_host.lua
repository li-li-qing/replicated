-- Phase 0 recovered offline host for BuffDisplay/diagnostics presentation regressions.
-- Test infrastructure only; never loaded by toc.g.
return function(S)
    assert(type(S)=='table','suite required')
    local H={widgets={},nativeEnabled=true,visibleWidgets={},factories={}}
    local function Attach(parent,node) if type(parent)=='table' then parent.children=parent.children or {};parent.children[#parent.children+1]=node end end
    function H.Node(spec)
        spec=type(spec)=='table' and spec or {id=tostring(spec or '')}
        local n={spec=spec,id=spec.id,children={},items=spec.items or {},text=spec.text or '',enabled=spec.enabled~=false,visible=spec.visible~=false,value=spec.value,shown=spec.visible~=false,width=0,height=0,handlers={},owner='phase0:status_ui'}
        n.root=n;n.onClick=spec.onClick;n.onItemActivated=spec.onItemActivated;n.onSelectionChanged=spec.onSelectionChanged
        Attach(spec.parent,n);if n.id then H.widgets[n.id]=n end
        function n:SetText(v) self.text=tostring(v or ''); return true end
        function n:GetText() return self.text or '' end
        function n:SetEnabled(v) self.enabled=v==true; return true end
        function n:SetVisible(v) self.visible=v==true; self.shown=self.visible; return true end
        function n:Show(v) return self:SetVisible(v) end
        function n:SetItems(items,revision) self.items=items or {}; self.revision=revision; return true end
        function n:SetViewState(state,detail) self.viewState=state; self.viewDetail=detail; return true end
        function n:SetValue(v,submit,reason) self.value=v; if type(self.spec.set)=='function' then return self.spec.set(v,submit,reason) end return true end
        function n:GetDraftValue() return self.value~=nil and self.value or (type(self.spec.get)=='function' and self.spec.get() or '') end
        function n:GetItem(i) return self.items and self.items[i] or nil end
        function n:Render() if type(self.spec.get)=='function' then self.value=self.spec.get() end; return true end
        function n:InvalidateMeasure(reason) self.measureDirty=true;self.layoutDirty=true;self.invalidationReason=reason;return true end
        function n:SetActiveIndex(i) self.activeIndex=i; return true end
        function n:Layout(x,y,w,h) self.x,self.y,self.width,self.height=x,y,w,h; return true end
        function n:AddAnchor() return true end
        function n:RemoveAllAnchors() return true end
        function n:SetExtent(w,h) self.width,self.height=w,h; return true end
        function n:GetExtent() return self.width,self.height end
        function n:GetWidth() return self.width end
        function n:GetHeight() return self.height end
        function n:SetHandler(k,v) self.handlers[k]=v; return true end
        function n:ReleaseHandler(k) self.handlers[k]=nil; return true end
        function n:MaxTextLength() return self.maxTextLength or 32768 end
        return n
    end
    local R=S.RSUI or {};S.RSUI=R
    local function C(_,spec) return H.Node(spec) end
    for _,name in ipairs({'Border','Button','Dropdown','HorizontalBox','ScrollBox','SegmentedSelector','Text','TextInput','Toggle','UniformGrid','VerticalBox'}) do R[name]=C end
    function R:WidgetSwitcher(spec) local n=H.Node(spec);n.activeIndex=spec.activeIndex or 1;return n end
    function R:TableView(spec) return H.Node(spec) end
    S.UIV3Design=S.UIV3Design or {};local D=S.UIV3Design
    function D:PageRoot(parent,id) return H.Node({id=id,parent=parent}) end
    function D:ScrollablePageRoot(parent,id) return H.Node({id=id,parent=parent}) end
    function D:PageHeader(parent,id,title,subtitle,actionText,action) local n=H.Node({id=id,parent=parent,text=title});n.subtitle=subtitle;if actionText then local b=H.Node({id=id..'_action',parent=n,text=actionText});b.onClick=action end;return n end
    function D:ModuleToggleButton(spec) return H.Node(spec) end
    function D:CompactNumericSetting(spec) local n=H.Node(spec);n.value=type(spec.get)=='function' and spec.get() or spec.value;function n:SetValue(v) self.value=v;if type(spec.set)=='function' then return spec.set(v) end return true end;return n end
    function D:InfoCard(parent,idOrSpec,spec) local cfg=type(idOrSpec)=='table' and idOrSpec or (type(spec)=='table' and spec or {id=idOrSpec,parent=parent});cfg.parent=cfg.parent or parent;local n=H.Node(cfg);function n:SetData(v)self.data=v end;return n end
    function D:StatusRow(parent,id) local n=H.Node({id=id,parent=parent});n.valueText=H.Node({parent=n});return n end
    S.UIV3=S.UIV3 or {};local PH=S.UIV3.PageHost or {};S.UIV3.PageHost=PH;PH.factories=PH.factories or H.factories
    function PH:RegisterFactory(route,factory) self.factories[route]=factory;return true end
    function PH:BindFeatureConsumerLifecycle(root,binding) root._consumerBinding=binding;return true end
    function PH:SyncFeatureConsumer(root,binding) local enabled=not S.FeatureRuntime or type(S.FeatureRuntime.IsEnabled)~='function' or S.FeatureRuntime:IsEnabled(binding.featureId)==true;if enabled and not root.consumerHeld and binding.feature and type(binding.feature.AcquireConsumer)=='function' then local ok,err=binding.feature:AcquireConsumer(binding.token);if ok~=true then return false,err end;root.consumerHeld=true;if type(binding.onEnabled)=='function' then binding.onEnabled(root) end elseif not enabled and root.consumerHeld then if binding.feature and type(binding.feature.ReleaseConsumer)=='function' then binding.feature:ReleaseConsumer(binding.token) end;root.consumerHeld=false;if type(binding.onDisabled)=='function' then binding.onDisabled(root) end end;return true end
    function PH:ReleaseFeatureConsumer(root,binding) if root.consumerHeld and binding.feature and type(binding.feature.ReleaseConsumer)=='function' then binding.feature:ReleaseConsumer(binding.token) end;root.consumerHeld=false;return true end
    function PH:Attach(parent) self.parent=parent; return true end
    function PH:Navigate(route) local f=self.factories[route];if type(f)~='function' then return false,'factory_missing' end;local page,err=f(self.parent or H.Node({id='page_host_parent'}),route);if not page then return false,err end;self.pages=self.pages or {};self.failedPages=self.failedPages or {};self.stats=self.stats or {buildFailures=0};self.pages[route]=page;if type(page.OnActivated)=='function' then local ok,e=page:OnActivated();if ok==false then return false,e end end;return true end
    PH.pages=PH.pages or {};PH.failedPages=PH.failedPages or {};PH.stats=PH.stats or {buildFailures=0}
    local WH=S.UIV3.WidgetHost or {};S.UIV3.WidgetHost=WH
    function WH:IsVisible(id) return H.visibleWidgets[id]==true end;function WH:SetVisible(id,v) H.visibleWidgets[id]=v==true;return true end;function WH:Register() return true end;function WH:BindFeatureLifecycle() return true end
    if type(S.Events)~='table' then S.Events={listeners={}} end;S.Events.listeners=S.Events.listeners or {}
    if type(S.Events.SubscribeInternal)~='function' then function S.Events:SubscribeInternal(topic,owner,cb) self.listeners[#self.listeners+1]={topic=topic,owner=owner,cb=cb};return true end end
    if type(S.Events.UnsubscribeInternalOwner)~='function' then function S.Events:UnsubscribeInternalOwner(owner) for i=#self.listeners,1,-1 do if self.listeners[i].owner==owner then table.remove(self.listeners,i) end end return true end end
    if type(S.Events.Publish)~='function' then function S.Events:Publish(topic,... ) for _,r in ipairs(self.listeners) do if r.topic==topic then r.cb(r.owner,...) end end return true end end
    S.UI=S.UI or {};H.edit=H.Node({id='phase0_shared_multiedit'});H.edit.text=''
    function H.edit:SetText(v) self.text=tostring(v or '');return true end;function H.edit:GetText() return self.text or '' end;function H.edit:Show(v) self.visible=v==true;return true end;function H.edit:SetCursorPos(v) self.cursor=v;return true end;function H.edit:SetFocus() H.focused=self;return true end
    function S.UI:CreateMultiEditBox(parent,id) if H.nativeEnabled~=true then return nil,'native_editor_disabled' end;local e=H.edit;e.id=id;e.parent=parent;H.widgets[id]=e;return e end
    if type(S.UI.BindDeferredInputActivation)~='function' then function S.UI:BindDeferredInputActivation(editor,owner) editor.rsUiOwner=owner;return true end end
    if type(S.UI.DeactivateInputWidget)~='function' then function S.UI:DeactivateInputWidget(editor) if editor then editor.keyboard=false end;return true end end
    if type(S.UI.RetireInputWidget)~='function' then function S.UI:RetireInputWidget(editor) if editor then editor.retired=true end;return true end end
    if type(S.UI.ActivateInputWidget)~='function' then function S.UI:ActivateInputWidget(editor) H.focused=editor;editor.keyboard=true;return true end end
    function H:Build() self.widgets={};self.edit=H.edit;self.factories={};PH.factories=self.factories;dofile('presentation/v3/pages/rs_v3_buff_display_page.lua');local factory=assert(PH.factories['combat.buff_display'],'buff display factory missing');local parent=H.Node({id='phase0_status_parent'});local page,err=factory(parent,'combat.buff_display');if not page then return nil,err end;self.page=page;return page end
    return H
end
