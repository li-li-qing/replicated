-- 开发期宿主：真实 RSUI 布局/表单/事件、Gear Store/Authority；只替换 Native 和应用宿主。
-- 禁止纳入 toc.g。像素命中以原生父链裁剪模型断言，不冒充 RU 客户端实测。
return function(options)
    options=options or {}
    local h={disk=options.disk or {},writes=0,reads=0,clears=0,widgets={},logs={},ms=1000,failSave=false}
    local function Copy(t)if type(t)~='table'then return t end;local r={};for k,v in pairs(t)do r[k]=Copy(v)end;return r end
    h.Copy=Copy
    ADDON={LoadData=function(_,key)h.reads=h.reads+1;return Copy(h.disk[key])end,
        SaveData=function(_,key,value)h.writes=h.writes+1;if h.failSave then return false end;h.disk[key]=Copy(value);return true end,
        ClearData=function()h.clears=h.clears+1;error('unexpected ClearData')end,ChatLog=function()end}
    X2Unit={UnitNameWithWorld=function()return 'GearTest@World' end}
    X2Equipment={GetEquippedItemTooltipInfo=function(_,slot)
        h.equipmentReads=(h.equipmentReads or 0)+1
        return {name='+3 合成装备'..tostring(slot),itemGrade=4,itemType=10000+slot,icon='test/equipment.dds'}
    end}
    X2Player={GetShowingAppellation=function()return {42,'测试称号'}end,GetEffectAppellation=function()return {42,'测试称号'}end,PlayerInCombat=function()return false end}
    ReplicatedSuite={Features={},Services={},Generation=1,Config={settings={}},NowMs=function()return h.ms end,SafeTraceback=function(e)return tostring(e)..'\n'..debug.traceback()end}
    local S=ReplicatedSuite;h.S=S
    dofile('core/rs_utils.lua');dofile('core/rs_reuse.lua');dofile('core/rs_events.lua');dofile('core/rs_scheduler.lua');dofile('core/rs_api.lua');dofile('core/rs_api_capabilities.lua');dofile('core/rs_persistence.lua')
    S.DiagnosticsManager={Record=function(_,a,b,c,d,e)h.logs[#h.logs+1]={b,d,c,e}end,Error=function(_,a,b,c,d)h.logs[#h.logs+1]={a,b,c,d}end,Warn=function(_,a,b,c,d)h.logs[#h.logs+1]={a,b,c,d}end}
    S.FeatureRuntime={RegisterImplementation=function()return true end,IsEnabled=function()return true end,GetPreferredEnabled=function()return true end,
        Enable=function()return true end,Disable=function()return true end,SetEnabled=function()return true end}
    dofile('services/rs_gear_service_v3.lua');dofile('features/combat/gear/rs_gear_store.lua');dofile('features/combat/gear/rs_gear_authority.lua');dofile('features/combat/gear/rs_gear_feature.lua')
    local F=S.Features.Gear;h.F=F
    assert(F:EnsureStoreLoaded());F.enabled=true
    -- 外部应用偏好及 HUD 并非本用例被测对象。记录警告可单独注入，不替换 Create/Rename/Save 命令。
    F.EnsurePersistentQuickRuntime=function()return true end
    F.SetQuickHudVisible=function()return true end
    F.SyncQuickButtonsHost=function()return true end
    local function Native(parent,id,x,y,w,ht)
        local n={parent=parent,id=id,x=x or 0,y=y or 0,width=w or 1,height=ht or 1,shown=true,enabled=true,pickable=false,text='',events={},rsUiOwner='test:gear'}
        function n:GetParent()return self.parent end
        function n:GetWidth()return self.width end
        function n:GetHeight()return self.height end
        function n:SetExtent(a,b)self.width=a;self.height=b end
        function n:SetText(t)self.text=tostring(t or '')end
        function n:GetText()return self.text end
        function n:SetGuideText(t)self.guide=t end
        function n:Show(v)self.shown=v end
        function n:SetHandler(ev,fn)self.events[ev]=fn end
        function n:ReleaseHandler(ev)self.events[ev]=nil end
        function n:SetColor()end
        function n:SetTexture()end
        function n:SetVisible(v)self.shown=v end
        function n:SetCoords()end
        function n:AddAnchor(_,p,a,b)self.parent=p;self.x=a;self.y=b end
        function n:RemoveAllAnchors()end
        function n:CreateColorDrawable()return Native(self,id..'_drawable',0,0,1,1)end
        function n:SetFontSize()end
        function n:SetAlign()end
        function n:SetAutoResize()end
        function n:Enable(v)self.enabled=v end
        function n:EnablePick(v)self.pickable=v end
        return n
    end
    h.Native=Native
    local UI={};S.UI=UI
    UI.CreateEmptyWidget=function(_,p,id,x,y,w,ht,pick)local n=Native(p,id,x,y,w,ht);n.pickable=pick==true;return n end
    UI.CreatePanel=UI.CreateEmptyWidget
    UI.CreateLabel=function(_,p,id,text,x,y,w,ht)local n=Native(p,id,x,y,w,ht);n.text=tostring(text or '');return n end
    UI.CreateButton=function(_,p,id,text,x,y,w,ht)local n=Native(p,id,x,y,w,ht);n.pickable=true;n.text=text;return n end
    UI.CreateEditBox=function(_,p,id,x,y,w,ht,max)local n=Native(p,id,x,y,w,ht);n.max=max;n.pickable=true;n.rsUiKeyboardArmed=false;return n end
    UI.SetText=function(_,n,t)n.text=tostring(t or '');return true end
    UI.SetExtent=function(_,n,w,ht)n.width=w;n.height=ht;return true end
    UI.EnsureExtent=function(_,n,w,ht)n.width=w;n.height=ht;return true,false end
    UI.SetAnchor=function(_,n,p,x,y)n.parent=p;n.x=x;n.y=y;return true end
    UI.EnsureAnchor=function(_,n,p,x,y)n.parent=p;n.x=x;n.y=y;return true,false end
    UI.SetVisible=function(_,n,v)n.shown=v;return true end
    UI.EnsureVisible=function(_,n,v)n.shown=v;return true,false end
    UI.SetEnabled=function(_,n,v)n.enabled=v;return true end
    UI.EnsureEnabled=function(_,n,v)n.enabled=v;return true,false end
    UI.EnsurePickable=function(_,n,v)n.pickable=v;return true,false end
    UI.SetColor=function()return true end
    UI.SetLabelTone=function()return true end
    UI.SetFontSize=function()return true end
    UI.StyleLabel=function()return true end
    UI.SetButtonState=function()return true end
    UI.SetButtonActive=function()return true end
    UI.SetButtonSelected=function()return true end
    UI.SetButtonHoverState=function()return true end
    UI.SetEditBoxFocusVisual=function()return true end
    UI.IsWidgetUsable=function(n)return true end
    UI.SafeHandler=function(_,n,ev,fn)n.events[ev]=fn;return true end
    UI.RequireHandler=UI.SafeHandler
    UI.TryInteractionCall=function(_,n,fn,... )if n[fn]then n[fn](n,...)end;return true end
    UI.ActivateInputWidget=function(_,n)n.rsUiKeyboardArmed=true;UI.focused=n;return true end
    UI.DeactivateInputWidget=function(_,n)n.rsUiKeyboardArmed=false;if UI.focused==n then UI.focused=nil end;return true,false end
    UI.IsInputWidgetFocused=function(_,n)return UI.focused==n end
    dofile('ui/framework/rs_ui_tokens.lua');dofile('ui/framework/rs_ui_binding_v2.lua');dofile('ui/framework/rs_ui_component_core.lua')
    dofile('ui/framework/rs_ui_panels.lua');dofile('ui/framework/rs_ui_primitives.lua');dofile('ui/framework/rs_ui_controls.lua')
    dofile('ui/framework/rs_ui_adaptive_panels.lua');dofile('ui/framework/rs_ui_layout_templates.lua')
    local R=S.RSUI
    -- 布局、虚拟表格、选择模型和按钮命令全部使用生产实现，Native绘制仍为可控替身。
    dofile('ui/framework/rs_ui_selection.lua');dofile('ui/framework/rs_ui_view_state.lua');dofile('ui/framework/rs_ui_data_views.lua')
    dofile('ui/design_system/rs_ui_design_system_v3.lua')
    S.UIV3={PageHost={factories={},RegisterFactory=function(self,id,fn)self.factories[id]=fn;return true end}}
    dofile('ui/framework/rs_ui_action_runner.lua')
    dofile('presentation/v3/pages/rs_v3_gear_page.lua')
    local external=Native(nil,'external',0,0,options.width or 820,options.height or 680)
    local root,err=S.UIV3.PageHost.factories['combat.gear'](external,'combat.gear');assert(root,err);h.page=root;h.UI=UI
    local function Index(n)h.widgets[n.id]=n;for _,ch in ipairs(n.children or {})do Index(ch)end end
    Index(root)
    function h:Layout(w,ht)external.width=w or external.width;external.height=ht or external.height;root:Layout(0,0,external.width,external.height)end
    function h:Click(id)
        local c=assert(self.widgets[id],id);assert(type(c.root.events.OnClick)=='function','no click '..id)
        return c.root.events.OnClick(c.root,'LeftButton')
    end
    function h:Type(id,text)local c=assert(self.widgets[id]);assert(self:Click(id));c.root.text=text;return c end
    function h:VisibleRect(c)
        local n=c.root;local x,y=0,0;local current=n
        while current do x=x+(current.x or 0);y=y+(current.y or 0);current=current.parent end
        local rect={x=x,y=y,w=n.width,h=n.height};current=n
        while current do
            if current.shown==false then return false,'hidden:'..tostring(current.id)end
            local ax,ay=0,0;local p=current;while p do ax=ax+p.x;ay=ay+p.y;p=p.parent end
            if rect.x<ax-0.1 or rect.y<ay-0.1 or rect.x+rect.w>ax+current.width+0.1 or rect.y+rect.h>ay+current.height+0.1 then return false,'clipped:'..current.id..':'..current.width..'x'..current.height end
            current=current.parent
        end
        return true,rect
    end
    function h:ReloadStore()local store=S.Persistence:GetStore('v3.gear.index');store.loaded=false;assert(F:EnsureStoreLoaded());F.Authority:Refresh('test_reload')end
    assert(root:OnActivated());h:Layout();return h
end
