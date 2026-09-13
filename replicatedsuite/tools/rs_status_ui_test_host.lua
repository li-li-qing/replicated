-- 中文维护注释：离线 Presentation 测试宿主，仅记录控件契约/事件，不模拟 Native 布局或输入焦点。
-- 不进入 TOC，不伪造实机像素验证；只用于发现 factory nil、无绑定按钮和危险事件顺序。
return function(S)
    local host={widgets={},nativeEnabled=true}
    local function Node(spec)
        local n={spec=spec or {},children={},text=spec and spec.text or '',enabled=true,items=spec and spec.items or {}}
        n.onClick=spec and spec.onClick
        n.root={Show=function(self,value) self.visible=value end}
        n.owner={}
        function n:SetText(text) self.text=text end
        function n:SetEnabled(value) self.enabled=value end
        function n:Render() return true end
        function n:SetItems(items,revision) self.items=items;self.revision=revision end
        function n:SetViewState(state,detail) self.viewState=state;self.viewDetail=detail end
        function n:SetActiveIndex(index) self.activeIndex=index end
        function n:SetValue(value) self.value=value end
        function n:GetDraftValue() return self.value or '' end
        function n:Refresh() return true end
        if spec and spec.id then assert(not host.widgets[spec.id],'duplicate UI id '..spec.id);host.widgets[spec.id]=n end
        if spec and spec.parent and spec.parent.children then table.insert(spec.parent.children,n) end
        return n
    end
    host.Node=Node
    for _,kind in ipairs({'Border','Button','Dropdown','HorizontalBox','SegmentedSelector','TableView','Text','TextInput','Toggle','UniformGrid','VerticalBox','WidgetSwitcher'}) do
        S.RSUI[kind]=function(_,spec) return Node(spec) end
    end
    S.UIV3Design={PageRoot=function(_,_,id) return Node({id=id}) end,
        PageHeader=function() end,CompactNumericSetting=function(_,parent,spec) spec.parent=parent;return Node(spec) end}
    S.UIV3=S.UIV3 or {}
    S.UIV3.PageHost={factories={},RegisterFactory=function(self,key,fn) self.factories[key]=fn;return true end}
    S.UIV3.WidgetHost={IsVisible=function() return false end,SetVisible=function() return true end}
    S.UI.CreateMultiEditBox=function()
        local edit={text=''}
        function edit:GetText() return self.text end
        function edit:SetText(text) self.text=text end
        function edit:Show(value) self.visible=value end
        function edit:AddAnchor() end
        host.edit=edit;return edit
    end
    S.UI.BindDeferredInputActivation=function() return host.nativeEnabled, 'synthetic activation unavailable' end
    function host:Build()
        self.widgets={}
        dofile('presentation/v3/pages/rs_v3_buff_display_page.lua')
        local factory=S.UIV3.PageHost.factories['combat.buff_display'];assert(type(factory)=='function')
        return factory(nil,'combat.buff_display')
    end
    return host
end
