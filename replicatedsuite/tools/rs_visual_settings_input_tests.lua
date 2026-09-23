-- 中文维护：真实 Business Page + RSUI 输入/调度链，Feature/Native 数据为替身。
-- 回归 2026-09-14：UnitLines/RangeAssist 高频 visual_tick 不能在用户持有 NumericInput draft 时
-- 触发整页 Refresh；整页更新会改写 Table/Status/Enabled 等 Native 状态，RU 会丢失 EditBox 焦点或把 draft 恢复为 Authority。
local Base = dofile('tools/rs_gear_page_test_host.lua')
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed=passed+1; print('PASS visual-settings-input '..name)
    else failed=failed+1; print('FAIL visual-settings-input '..name..': '..tostring(err)) end
end

local function Boot(id)
    local h=Base({width=980,height=760}); assert(h.page:OnDeactivated())
    local S=h.S
    if type(S.UI.CreateSlider) ~= 'function' then
        S.UI.CreateSlider=function(_,parent,wid,x,y,w,ht,min,max,step,value)
            local n=h.Native(parent,wid,x,y,w,ht);n.value=tonumber(value) or tonumber(min) or 0;n.min,n.max,n.step=min,max,step;n.pickable=true
            function n:GetValue() return self.value end
            function n:SetValue(v) self.value=tonumber(v) or self.value; return true end
            function n:SetRange(a,b,s) self.min,self.max,self.step=a,b,s; return true,true end
            return n
        end
    end
    -- Production load order persists adaptive slider endpoints before Forms.
    -- Keep the harness on the same Authority path so dynamic-range tests prove
    -- both immediate expansion and the presentation metadata write.
    dofile('ui/framework/rs_ui_numeric_range_store.lua')
    dofile('ui/framework/rs_ui_forms.lua')
    if type(S.RSUI.StatusChip) ~= 'function' then
        function S.RSUI:StatusChip(spec)
            local chip=self:Text({id=spec.id,parent=spec.parent,text=tostring(spec.text or spec.status or ''),slot=spec.slot})
            function chip:SetStatus(_,text) self:SetText(tostring(text or '')); return true end
            return chip
        end
    end
    dofile('ui/framework/rs_ui_settings_foundation.lua')
    local projection
    if id=='combat_unit_lines' then
        projection={revision=1,status='ready',rows={},pointCount=24,pointSize=4,opacity=0.78,refreshMs=50,
            showTarget=true,showTargetTarget=true,showFocusTarget=true,showFocusTargetTarget=true,
            pairPoints={},pairSizes={},colors={}}
    else
        projection={revision=1,status='ready',rows={{circleId=1,statusText='实时',tone='success'}},circleCount=1,enabledCircleCount=1,
            circles={{id=1,name='范围圆 1',enabled=true,radius=17,pointCount=24,pointSize=15,opacity=0.68,color={0.2,0.82,1}}}}
    end
    local F={Id=id,UpdateTopic='test.'..id..'.updated',enabled=true,consumerCount=0,Diagnostics={}}
    F.GetProjection=function() return projection end
    F.AcquireConsumer=function(self) self.consumerCount=self.consumerCount+1; return true end
    F.ReleaseConsumer=function(self) self.consumerCount=math.max(0,self.consumerCount-1); return true end
    local function Publish(reason)
        projection.revision=projection.revision+1
        S.Events:Publish(F.UpdateTopic,projection.revision,reason or 'test')
        return true
    end
    F.Commands={Refresh=function(_,reason) return Publish(reason or 'manual') end}
    if id=='combat_unit_lines' then
        F.Commands.SetPairEnabled=function(key,v) projection[({target='showTarget',targettarget='showTargetTarget',focus='showFocusTarget',focustarget='showFocusTargetTarget'})[key]]=v;return true end
        F.Commands.SetPointCount=function(_,v)projection.pointCount=v;return true end
        F.Commands.SetPointSize=function(_,v)projection.pointSize=v;return true end
        F.Commands.SetOpacity=function(_,v)projection.opacity=v;return true end
        F.Commands.SetRefreshMs=function(_,v)projection.refreshMs=v;return true end
        F.Commands.SetPairPoints=function(_,key,v)projection.pairPoints[key]=v;return true end
        F.Commands.SetPairSize=function(_,key,v)projection.pairSizes[key]=v;return true end
        F.Commands.SetPairColor=function(_,key,r,g,b)projection.colors[key]={r,g,b};return true end
    else
        local function C() return projection.circles[1] end
        F.Commands.AddCircle=function(_)return true end
        F.Commands.RemoveCircle=function(_,_)return true end
        F.Commands.SetCircleEnabled=function(_,circleId,v)C().enabled=v;return true end
        F.Commands.SetCircleRadius=function(_,circleId,v)C().radius=v;return true end
        F.Commands.SetCirclePointCount=function(_,circleId,v)C().pointCount=v;return true end
        F.Commands.SetCirclePointSize=function(_,circleId,v)C().pointSize=v;return true end
        F.Commands.SetCircleOpacity=function(_,circleId,v)C().opacity=v;return true end
        F.Commands.SetCircleColor=function(_,circleId,r,g,b)C().color={r,g,b};return true end
    end
    S.Features[id]=F
    S.FeatureRegistry={Get=function(_,wanted) if wanted==id then return {name=id,description='test'} end return {name=wanted,description='test'} end}
    S.FeatureRuntime={IsEnabled=function(_,wanted)return wanted==id end,
        SetPreferredEnabled=function(_,wanted,v)F.enabled=v;return true end}
    dofile('presentation/v3/pages/rs_v3_business_pages.lua')
    local ext=h.Native(nil,'visual_settings_external_'..id,0,0,980,760)
    local route=id=='combat_unit_lines' and 'combat.unit_lines' or 'combat.range_assist'
    local root,err=S.UIV3.PageHost.factories[route](ext,route);assert(root,err)
    h.page=root;h.widgets={}
    local function Index(n)h.widgets[n.id]=n;for _,ch in ipairs(n.children or {})do Index(ch)end end
    root:Layout(0,0,980,760);Index(root);assert(root:OnActivated())
    h.F,h.projection,h.route=F,projection,route
    function h:TypeVisual(inputId,text)
        local c=assert(self.widgets[inputId],'missing '..inputId)
        assert(type(c.root.events.OnClick)=='function'); assert(c.root.events.OnClick(c.root,'LeftButton'))
        c.root.text=tostring(text); return c
    end
    return h
end

local function AssertVisualTickDeferredWhileEditing(h,inputId,draft)
    local c=h:TypeVisual(inputId,draft)
    assert(c:IsEditing()==true,'input did not enter editing state')
    local refreshes=0;local original=h.page.Refresh
    h.page.Refresh=function(self,...)refreshes=refreshes+1;return original(self,...)end
    assert(h.page:RequestFeatureRefresh('visual_tick'))
    local taskName='v3_business_visual_page_refresh:'..h.F.Id
    assert(h.S.Scheduler.tasks[taskName]==nil,'visual tick scheduled a full page refresh while input draft active')
    assert(refreshes==0,'full page refresh ran while input draft active')
    assert(c.root.text==tostring(draft),'draft text changed before commit')
    assert(c:EndEditing('test_end'))
    assert(h.page:RequestFeatureRefresh('visual_tick'))
    assert(h.S.Scheduler.tasks[taskName]~=nil,'visual refresh never resumes after edit ends')
end

Test('unit-lines visual ticks are fenced while exact numeric input owns a draft',function()
    local h=Boot('combat_unit_lines')
    AssertVisualTickDeferredWhileEditing(h,'v3_business_combat_unit_lines_size_input','15')
end)

Test('range-assist visual ticks are fenced while selected-circle input owns a draft',function()
    local h=Boot('combat_range_assist')
    AssertVisualTickDeferredWhileEditing(h,'v3_business_combat_range_assist_selected_radius_input','1')
end)


Test('pending visual refresh created before click is fenced at execution time',function()
    local h=Boot('combat_unit_lines')
    local taskName='v3_business_visual_page_refresh:'..h.F.Id
    assert(h.page:RequestFeatureRefresh('visual_tick'))
    local task=assert(h.S.Scheduler.tasks[taskName],'pre-click visual task missing')
    local c=h:TypeVisual('v3_business_combat_unit_lines_size_input','13')
    local refreshes=0;local original=h.page.Refresh
    h.page.Refresh=function(self,...)refreshes=refreshes+1;return original(self,...)end
    assert(task.callback())
    assert(refreshes==0,'already-scheduled visual refresh ran after editing began')
    assert(c:IsEditing()==true and c.root.text=='13','pending visual refresh disturbed active draft')
end)


Test('range-assist color row and status row keep separate vertical geometry',function()
    local h=Boot('combat_range_assist')
    local color=assert(h.widgets['v3_business_combat_range_assist_selected_color'])
    local status=assert(h.widgets['v3_business_combat_range_assist_editor_status'])
    local function Rect(component)
        local n=component.root;local x,y=0,0;local current=n
        while current do x=x+(tonumber(current.x) or 0);y=y+(tonumber(current.y) or 0);current=current.parent end
        return x,y,tonumber(n.width) or 0,tonumber(n.height) or 0
    end
    local _,cy,_,ch=Rect(color);local _,sy=Rect(status)
    assert(ch>=24,'color row collapsed: '..tostring(ch))
    assert(sy>=cy+ch+4-0.01,string.format('color/status overlap: color=%.1f..%.1f status=%.1f',cy,cy+ch,sy))
end)


Test('range-assist suspended explicit draft keeps visual page fenced until Apply',function()
    local h=Boot('combat_range_assist')
    local taskName='v3_business_visual_page_refresh:'..h.F.Id
    local c=h:TypeVisual('v3_business_combat_range_assist_selected_radius_input','1')
    h.UI.focused=nil
    assert(type(c.root.events.OnLostFocus)=='function','lost-focus handler missing')
    c.root.events.OnLostFocus()
    assert(type(c.HasDraftSession)=='function' and c:HasDraftSession()==true,'blur discarded explicit draft')
    assert(c:IsEditing()==false,'blur failed to release Native editing ownership')
    assert(h.page:RequestFeatureRefresh('visual_tick'))
    assert(h.S.Scheduler.tasks[taskName]==nil,'suspended draft no longer fences ambient visual refresh')
    assert(c.root.text=='1','suspended draft text changed before Apply')
    assert(c:CommitAndEndEditing('test_apply'))
    assert(c:HasDraftSession()==false,'Apply left draft session active')
    assert(h.page:RequestFeatureRefresh('visual_tick'))
    assert(h.S.Scheduler.tasks[taskName]~=nil,'visual refresh did not resume after Apply')
end)


Test('unit-lines suspended explicit draft survives repeated visual ticks until Apply',function()
    local h=Boot('combat_unit_lines')
    local taskName='v3_business_visual_page_refresh:'..h.F.Id
    local c=h:TypeVisual('v3_business_combat_unit_lines_size_input','13')
    h.UI.focused=nil
    c.root.events.OnLostFocus()
    assert(c:HasDraftSession()==true and c:IsEditing()==false,'unit-lines blur did not suspend draft')
    for i=1,8 do
        assert(h.page:RequestFeatureRefresh('visual_tick'))
        assert(h.S.Scheduler.tasks[taskName]==nil,'visual tick #'..i..' escaped draft fence')
        assert(c.root.text=='13','visual tick #'..i..' overwrote unit-lines draft: '..tostring(c.root.text))
    end
    assert(c:CommitAndEndEditing('test_apply'))
    assert(c:HasDraftSession()==false,'unit-lines Apply left draft active')
    assert(h.page:RequestFeatureRefresh('visual_tick'))
    assert(h.S.Scheduler.tasks[taskName]~=nil,'unit-lines refresh did not resume after Apply')
end)


Test('range-assist exact density expands the slider beyond the recommended 48',function()
    local h=Boot('combat_range_assist')
    local input=assert(h.widgets['v3_business_combat_range_assist_selected_points_input'])
    local slider=assert(h.widgets['v3_business_combat_range_assist_selected_points_slider'])
    assert(input.root.events.OnClick(input.root,'LeftButton'))
    input.root.text='58'
    assert(input:CommitAndEndEditing('test_apply'))
    assert(h.projection.circles[1].pointCount==58,'domain received '..tostring(h.projection.circles[1].pointCount)..' instead of 58')
    local minValue,maxValue=slider:GetRange()
    assert(minValue==12,'recommended minimum changed unexpectedly: '..tostring(minValue))
    assert(maxValue==58,'slider maximum did not expand to accepted exact value: '..tostring(maxValue))
    local saved=h.S.RSUI.NumericRangeStore:Describe('v3_business_combat_range_assist_selected_points')
    assert(saved.minimum==12 and saved.maximum==58,'expanded range was not persisted in RSUI metadata')
end)

Test('unit-lines exact density expands the slider beyond the recommended 48',function()
    local h=Boot('combat_unit_lines')
    local input=assert(h.widgets['v3_business_combat_unit_lines_points_input'])
    local slider=assert(h.widgets['v3_business_combat_unit_lines_points_slider'])
    assert(input.root.events.OnClick(input.root,'LeftButton'))
    input.root.text='58'
    assert(input:CommitAndEndEditing('test_apply'))
    assert(h.projection.pointCount==58,'domain received '..tostring(h.projection.pointCount)..' instead of 58')
    local minValue,maxValue=slider:GetRange()
    assert(minValue==8,'recommended minimum changed unexpectedly: '..tostring(minValue))
    assert(maxValue==58,'slider maximum did not expand to accepted exact value: '..tostring(maxValue))
end)


Test('range-assist exact density can expand the slider below the recommended 12',function()
    local h=Boot('combat_range_assist')
    local input=assert(h.widgets['v3_business_combat_range_assist_selected_points_input'])
    local slider=assert(h.widgets['v3_business_combat_range_assist_selected_points_slider'])
    assert(input.root.events.OnClick(input.root,'LeftButton'))
    input.root.text='8'
    assert(input:CommitAndEndEditing('test_apply'))
    assert(h.projection.circles[1].pointCount==8,'domain received '..tostring(h.projection.circles[1].pointCount)..' instead of 8')
    local minValue,maxValue=slider:GetRange()
    assert(minValue==8,'slider minimum did not expand downward to accepted exact value: '..tostring(minValue))
    assert(maxValue==48,'recommended maximum changed unexpectedly: '..tostring(maxValue))
    local saved=h.S.RSUI.NumericRangeStore:Describe('v3_business_combat_range_assist_selected_points')
    assert(saved.minimum==8 and saved.maximum==48,'downward range expansion was not persisted')
end)

Test('fixed normalized opacity remains bounded and never expands',function()
    local h=Boot('combat_range_assist')
    local input=assert(h.widgets['v3_business_combat_range_assist_selected_opacity_input'])
    local slider=assert(h.widgets['v3_business_combat_range_assist_selected_opacity_slider'])
    assert(input.root.events.OnClick(input.root,'LeftButton'))
    input.root.text='1.5'
    assert(input:CommitAndEndEditing('test_apply'))
    assert(h.projection.circles[1].opacity==1,'fixed opacity accepted '..tostring(h.projection.circles[1].opacity))
    local minValue,maxValue=slider:GetRange()
    assert(minValue==0.1 and maxValue==1,'fixed opacity slider expanded unexpectedly')
end)

print('VISUAL SETTINGS INPUT RESULTS: '..passed..' passed / '..failed..' failed')
assert(failed==0,tostring(failed)..' visual settings input regressions')
