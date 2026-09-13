-- 维护（hud-template-copy-2）：仅开发期。实际 Calibration/Feature/Store/分页编码器保留；
-- 原生图形、键盘、SetText容量和聊天为有故障注入的替身，不能据此声称RU已验证。
-- 输入框草稿/选区由模型记录；公共焦点绑定的真实实现另由rs_report_selection_tests覆盖。
return function(options)
    options=options or {}
    local h,S,F,P=dofile('tools/rs_pvp_hud_test_host.lua')()
    h.width,h.height,h.scale=options.width or 1280,options.height or 768,options.scale or 1
    h.buttons,h.chat,h.createdButtons,h.editCreates={}, {}, 0, 0
    h.declaredCapacity=options.capacity or 3500
    h.actualCapacity=options.actualCapacity or h.declaredCapacity
    h.editWrites,h.editGeometry,h.focusCalls=0,0,0
    S.DebugFlags=options.debugFlags
    local create=S.UI.CreateButton
    S.UI.CreateButton=function(self,parent,id,...)
        local b,e=create(self,parent,id,...)
        if b then h.buttons[id]=b;h.createdButtons=h.createdButtons+1 end
        return b,e
    end
    S.SafeChat=function(text,level,source)
        h.chat[#h.chat+1]={text=text,level=level,source=source}
        return true
    end
    S.UI.CreatePanel=function(ui,parent,id,x,y,w,ht,kind,opts)
        local r=ui:CreateEmptyWidget(parent,id,x,y,w,ht,opts.pickable,opts.owner)
        r.rsUiTransientWindow=opts.transientWindow;return r
    end
    S.UI.CreateMultiEditBox=function(_,parent,id,x,y,w,ht)
        if h.noEditor then return nil,'synthetic_no_editor' end
        local e=h.Native(parent,id,x,y,w,ht)
        e.rsUiOwner=parent.rsUiOwner;e.rsUiKeyboardArmed=false
        function e:SetText(v)
            h.editWrites=h.editWrites+1;self.selected=false
            if h.throwWrite then error('synthetic_write_throw') end
            if h.rejectWrite then return false end
            self.text=v:sub(1,h.actualCapacity)
            if h.corruptText and #v>0 then self.text=self.text:sub(1,-2)..'?' end
        end
        function e:GetText()if h.nonStringRead then return false end;return self.text end
        function e:MaxTextLength()return h.declaredCapacity end
        function e:SetCursorOffset(v)self.cursor=v;self.selected=false end
        function e:SelectForTest()assert(self.rsUiKeyboardArmed);self.selected=true end
        function e:CopyForTest()return self.selected and self.rsUiKeyboardArmed and self.shown and self.text or nil end
        h.edit=e;h.editCreates=h.editCreates+1;return e
    end
    S.UI.BindDeferredInputActivation=function(ui,e,owner,label,opts)
        if h.rejectBinding and e==h.edit then return false,'synthetic_bind_reject' end
        e.copyOptions=opts
        e.events.OnClick=function()return ui:ActivateInputWidget(e,owner,label)end
        return true
    end
    S.UI.RetireInputWidget=function(ui,e,owner)
        ui:DeactivateInputWidget(e,owner);e.retired=true;return true
    end
    local activate=S.UI.ActivateInputWidget
    S.UI.ActivateInputWidget=function(ui,e,...)
        if e==h.edit then h.focusCalls=h.focusCalls+1 end
        return activate(ui,e,...)
    end
    for _,method in ipairs({'SetExtent','EnsureExtent','SetAnchor','EnsureAnchor'})do
        local original=S.UI[method]
        S.UI[method]=function(ui,e,...)
            if e==h.edit then
                h.editGeometry=h.editGeometry+1;e.selected=false
                if h.rejectGeometry then return false,false,'synthetic_geometry_reject' end
            end
            return original(ui,e,...)
        end
    end
    dofile('core/rs_report_copy_transport.lua')
    dofile('presentation/v3/widgets/rs_v3_buff_hud_calibration.lua')
    local C=S.UIV3.BuffHudCalibrationV3;h.C=C
    assert(C:Open())
    function h:Click(id)
        local b=assert(self.buttons[id or 'v3_buff_hud_calibration_template'],'button missing')
        return b.events.OnClick(b,'LeftButton')
    end
    -- 额外的真实框架路径：校准已打开后替换纯图形宿主，保留生产Primitive/Registry/Diff/
    -- 输入生命周期；只实现Native的方法表和Theme装饰，不替换复制框构造或焦点处理。
    function h:UseRealCopyUi()
        local oldUI=S.UI
        dofile('ui/rs_ui_native_primitives.lua');dofile('ui/rs_ui_framework.lua')
        local ui=S.UI
        GetFocusedWidgetId=function()return self.focusId end
        S.Layout.GetContext=function()return {uiScale=self.scale}end
        S.Theme={AddBorder=function()end,AddPanelBackground=function()end}
        local function Native(parent,id)
            if parent=='UIParent'then parent=UIParent end
            local n=self.Native(parent,id,0,0,1,1)
            n.rsNativeGeneration=S.Generation;n.rsNativePhysicalId=id;n.rsUiLogicalId=id
            n.style={SetAlign=function()end,SetColor=function()end}
            n.guideTextStyle={SetAlign=function()end}
            function n:IsVisible()return self.shown end
            function n:GetEffectiveOffset()
                local x,y=self.x,self.y;local p=self.parent
                while type(p)=='table'do x=x+(p.x or 0);y=y+(p.y or 0);p=p.parent end
                return x,y
            end
            function n:CreateChildWidgetByType()end
            function n:SetInset()end
            function n:EnableFocus(v)self.focusEnabled=v;return v end
            function n:EnableKeyboard(v)self.keyboard=v;return v end
            function n:SetFocus()h.focusCalls=h.focusCalls+1;h.focusId=self.rsNativePhysicalId;self.selected=false end
            function n:ClearFocus()h.clearCalls=(h.clearCalls or 0)+1;h.focusId=nil;self.selected=false end
            function n:SetReadOnly(v)self.readonly=v;return v end
            function n:UseSelectAllWhenFocused(v)end
            function n:SetMaxTextLength(v)self.requestedMax=v end
            function n:MaxTextLength()return h.declaredCapacity end
            function n:SetCursorOffset(v)self.cursor=v;self.selected=false end
            function n:SetUILayer(v)self.layer=v end
            function n:SetWindowModal(v)self.modal=v end
            function n:SetCloseOnEscape(v)self.closeOnEscape=v end
            function n:SetDrawPriority(v)self.priority=v end
            function n:Raise()self.raised=true end
            local setText=n.SetText
            function n:SetText(v)
                if self==h.edit then
                    h.editWrites=h.editWrites+1;self.selected=false
                    if h.rejectWrite then return false end
                    v=v:sub(1,h.actualCapacity)
                end
                return setText(self,v)
            end
            function n:SelectForTest()assert(self.keyboard and h.focusId==self.rsNativePhysicalId);self.selected=true end
            function n:CopyForTest()return self.selected and self.keyboard and h.focusId==self.rsNativePhysicalId and self.text or nil end
            if id=='v3_buff_hud_template_edit'then h.edit=n;h.editCreates=h.editCreates+1 end
            return n
        end
        S.NativeObjectFactory={
            CreateWindow=function(_,id,parent)local n=Native(parent,id);n.kind='window';return n end,
            CreateEmptyWidget=function(_,id,parent)return Native(parent,id)end,
            CreateChildByObject=function(_,parent,kind,id)return Native(parent,id)end,
        }
        -- 非被测的按钮/标签只给外观，仍通过真实注册器和SafeHandler进入生命周期。
        local function Label(ui,parent,id,text,x,y,w,ht)
            local n=Native(parent,id);n.x=x;n.y=y;n.width=w;n.height=ht;n.text=text
            n.rsUiParent=parent;n.rsUiOwner=parent.rsUiOwner
            return ui:Register(id,n)
        end
        ui.CreateLabel=Label
        ui.CreateButton=function(self,parent,id,...)
            local n=Label(self,parent,id,...);h.buttons[id]=n;h.createdButtons=h.createdButtons+1;return n
        end
        return ui
    end
    return h,S,F,P,C
end
