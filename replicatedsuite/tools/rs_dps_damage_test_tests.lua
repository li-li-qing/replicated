-- 使用生产 DPS、战斗分析和 RSUI；悬浮外框与原生事件用测试宿主替代。
local h = dofile('tools/rs_gear_page_test_host.lua')({width=430,height=250})
local S = h.S
dofile('services/rs_unit_identity_v3.lua')
local identity = S.Services.UnitIdentityV3
identity.player = {id='a1',name='Self',nameWithWorld='Self@Home',normalizedName='self',normalizedWorldName='self@home'}
function identity:RefreshPlayerIdentity() return self.player end
S.Services.CombatEventBusV3 = {Subscribe=function() return true end,Unsubscribe=function() return true end}
S.Services.CombatRelationV3 = {
    AcquireConsumer=function() return true end, ReleaseConsumer=function() return true end,
    RecordCombatFact=function() return true,{sourceRelation='SELF',targetRelation='TEAM'} end,
}
dofile('core/rs_demand.lua')
dofile('services/rs_combat_analytics_v3.lua')
dofile('features/combat/dps/rs_dps_store.lua')
dofile('features/combat/dps/rs_dps_feature.lua')
dofile('features/combat/dps/rs_dps_domain.lua')
local F, analytics = S.Features.DPS, S.Services.CombatAnalyticsV3
function S.FeatureRuntime:GetSnapshot() return {enabled=F.enabled} end
assert(analytics:RegisterMetric({id='kills',factCategories={'death'}}))
analytics:SetStatisticsPolicy(function()
    return {scope='all',metrics=F:IsTrackingCategoryEnabled('damage') and {'kills','dps_core'} or {'kills'}}
end)
assert(F:Initialize())
assert(F:Enable())
assert(F.Commands:SetTrackingEnabled('damage',true))
local sequence=0
local function Fact(source,target,amount,at,category,environmental,sourceId)
    sequence=sequence+1
    analytics:_DispatchFact({category=category or 'damage',sourceName=source,targetName=target,amount=amount,
        receivedAt=at or h.ms,sequence=sequence,environmental=environmental,sourceId=sourceId})
end
local function CloseTo(a,b) assert(math.abs(a-b)<0.00001, tostring(a)..' ~= '..tostring(b)) end

Fact('Self','Target',500)
assert(F.Commands:StartDamageTest(0))
assert(not F.Commands:StartDamageTest(5), 'a waiting test cannot be overwritten')
Fact('Self','Target',700,h.ms-1)
h.ms=h.ms+3000
Fact('Other','Self',800)
Fact('Other','Target',900)
Fact('Self@Away','Self',400)
Fact('Self','Self',500,nil,'damage',false,'b2')
Fact('Self','Target',200,nil,'heal')
Fact('Self','Self',400,nil,'damage',true)
Fact('Self','Target',0)
assert(F:GetDamageTest().status=='waiting' and F:GetDamageTest().elapsedMs==0)
Fact('Self','Target',300)
assert(F:GetDamageTest().status=='running' and F:GetDamageTest().damage==300)
h.ms=h.ms+2500
assert(F.Commands:StopDamageTest())
local result=F:GetDamageTest()
assert(result.status=='finished' and result.damage==300 and result.elapsedMs==2500)
CloseTo(result.dps,120)
Fact('Self','Target',500)
h.ms=h.ms+10000
assert(F:GetDamageTest().damage==300 and F:GetDamageTest().dps==120)
assert(not F.Commands:StartDamageTest(7) and F:GetDamageTest().damage==300)

assert(F.Commands:StartDamageTest(5))
h.ms=h.ms+6000
assert(S.Scheduler.tasks['v3.dps.damage_test_deadline']==nil)
assert(F.Commands:StopDamageTest())
assert(F:GetDamageTest().status=='finished' and F:GetDamageTest().elapsedMs==0 and F:GetDamageTest().damage==0)

assert(F.Commands:StartDamageTest(5))
h.ms=h.ms+7000
assert(F:GetDamageTest().damage==0 and F:GetDamageTest().remainingMs==5000)
assert(S.Scheduler.tasks['v3.dps.damage_test_deadline']==nil)
h.ms=h.ms+200
Fact('Self','Target',100,h.ms-200) -- 以伤害接收时刻起算，而非后续派发时间。
assert(F:GetDamageTest().elapsedMs==200 and F:GetDamageTest().remainingMs==4800)
h.ms=h.ms+4799
Fact('Self','Target',400)
h.ms=h.ms+1
Fact('Self','Target',999)
h.ms=h.ms+600 -- 截止回调被推迟，金额和分母仍应截止在第 5 秒。
Fact('Self','Target',999)
assert(S.Scheduler:RunTask('v3.dps.damage_test_deadline'))
result=F:GetDamageTest()
assert(result.status=='finished' and result.reason=='deadline' and result.damage==500 and result.elapsedMs==5000)
CloseTo(result.dps,100)

assert(F.Commands:StartDamageTest(60))
h.ms=h.ms+10000
Fact('Self','Target',500)
h.ms=h.ms+10000
assert(F.Commands:StopDamageTest())
assert(F:GetDamageTest().elapsedMs==10000 and F:GetDamageTest().dps==50)
assert(S.Scheduler.tasks['v3.dps.damage_test_deadline']==nil)

assert(F.Commands:StartDamageTest(0))
h.ms=h.ms+1000
Fact('Self','Target',200)
assert(F.Commands:SetTrackingEnabled('damage',false))
assert(F:GetDamageTest().reason=='tracking_disabled' and F:GetDamageTest().damage==200)
assert(not F.Commands:StartDamageTest(0))
assert(F.Commands:SetTrackingEnabled('damage',true))

-- 使用真实控件和布局；外框宿主模拟收起广播和仅隐藏窗口，业务计时仍独立。
assert(F:ClearStats('widget_layout_test'))
local parent = h.Native(nil,'widget_parent',0,0,418,184)
local content = S.RSUI:Overlay({id='dps_test_host',parent=parent,autoRelayout=false})
S.Layout = {
    GetContext=function() return {logicalWidth=1024,logicalHeight=768} end,
    ResolveSuiteOwnedViewportLogicalRect=function(_,native)
        local x,y,current=0,0,native
        while current do x=x+current.x; y=y+current.y; current=current.parent end
        return x,y,native.width,native.height
    end,
}
dofile('ui/framework/rs_ui_popup_positioning.lua')
local surface = {shell={root=content},minimized=false}
function surface:GetContentRoot() return content end
function surface:Show(v) content:SetVisible(v); return true end
function surface:IsMinimized() return self.minimized end
function surface:SetStatus(value) self.status=value; return true end
local surfaceSpec
S.RSUI.FloatingSurface = {Create=function(_,spec) surfaceSpec=spec; return surface end,CreateStateAdapter=function() return {} end}
function surface:ChangeMinimized(value,reason)
    self.minimized = value
    surfaceSpec.onStateChanged(self,{minimized=value},reason)
end
function surface:ResetLayout() self:ChangeMinimized(false,'layout_reset'); return true end
local create
S.UIV3.WidgetHost = {Register=function(_,_,spec) create=spec.create;return true end,BindFeatureLifecycle=function() return true end}
dofile('presentation/v3/widgets/rs_v3_dps_widget.lua')
local widget = assert(create())
assert(widget:Show({persist=false}))
local function Layout(width,height)
    parent.width, parent.height = width or 418, height or 184
    content:Layout(0,0,parent.width,parent.height)
    S.RSUI:FlushLayoutQueue(32)
end
local function Click(component)
    return component.root.events.OnClick(component.root,'LeftButton')
end
Layout()
assert(widget.viewSwitcher.activeIndex==1)
assert(not h:VisibleRect(widget.detail))
local ensureVisible = h.UI.EnsureVisible
local detailRevealedInPlace
function h.UI:EnsureVisible(native,visible,...)
    if native==widget.detail.root and visible then
        detailRevealedInPlace = native.y >= widget.table.root.y + widget.table.root.height
    end
    return ensureVisible(self,native,visible,...)
end
Fact('Self','Target',63)
assert(S.Scheduler:RunTask(F.projectionPublishToken))
S.RSUI:FlushLayoutQueue(32)
local detailVisible, detailRect = h:VisibleRect(widget.detail)
local tableVisible, tableRect = h:VisibleRect(widget.table)
assert(detailVisible and tableVisible and detailRect.y >= tableRect.y + tableRect.h,
    'newly visible pending text must be below the table without resizing the window')
assert(detailRevealedInPlace, 'pending text became visible before its slot was arranged')
h.UI.EnsureVisible = ensureVisible
assert(F:ClearStats('widget_layout_test_done'))
assert(not h:VisibleRect(widget.detail) and widget.table.height > tableRect.h,
    'clearing pending text must release its slot without resizing the window')
assert(Click(widget.viewSelector.buttons[2]))
Layout()
assert(widget.viewSwitcher.activeIndex==2)
assert(h:VisibleRect(widget.testAction) and h:VisibleRect(widget.durationInput) and h:VisibleRect(widget.testRate))
Layout(548,344)
assert(h:VisibleRect(widget.testAction) and h:VisibleRect(widget.testTime))
Layout()
assert(not h:VisibleRect(widget.table))
assert(#widget.durationInput.items==13 and widget.durationInput.items[13].value==60)
assert(Click(widget.testAction))
assert(widget.testAction.root.text=='停止记录' and widget.durationInput.root.enabled==false)
assert(surface.status=='等待首次伤害' and not S.Scheduler.tasks['v3.dps.damage_test_display'])
Layout()
assert(widget.testRate.root.text=='0','starting a new round clears the previous readout')
h.ms=h.ms+1250
Fact('Self','Target',250)
assert(S.Scheduler:RunTask(F.projectionPublishToken))
assert(surface.status=='记录中 · 本人输出')
h.ms=h.ms+1250
assert(S.Scheduler:RunTask('v3.dps.damage_test_display'))
Layout()
assert(widget.testRate.root.text=='200')
surface:ChangeMinimized(true,'minimized')
assert(S.Scheduler.tasks['v3.dps.damage_test_display']==nil and F:GetDamageTest().status=='running')
assert(widget:ResetLayout(true))
assert(S.Scheduler.tasks['v3.dps.damage_test_display']~=nil)
assert(Click(widget.viewSelector.buttons[1]))
assert(S.Scheduler.tasks['v3.dps.damage_test_display']==nil and F:GetDamageTest().status=='running')
assert(widget:Hide({persist=false}))
h.ms=h.ms+750
Fact('Self','Target',50)
assert(F:GetDamageTest().damage==300)
assert(widget:Show({persist=false}))
assert(Click(widget.viewSelector.buttons[2]))
assert(Click(widget.testAction))
Layout()
assert(widget.testRate.root.text=='150' and widget.testAction.root.text=='开始记录')

local duration=widget.durationInput
assert(Click(duration))
assert(duration:Scroll(13))
local option=duration.optionButtons[duration.visibleRows]
assert(option.rsItemIndex==13 and option.events.OnClick(option,'LeftButton'))
assert(not duration.open and duration:GetValue()==60 and widget.testRate.root.text=='150')
assert(Click(widget.testAction) and F:GetDamageTest().remainingMs==60000)
assert(widget:Hide({persist=false}))
h.ms=h.ms+3000
Fact('Self','Target',1200)
h.ms=h.ms+60000
assert(S.Scheduler:RunTask('v3.dps.damage_test_deadline'))
assert(widget:Show({persist=false}))
assert(widget.testRate.root.text=='20' and widget.testAction.root.text=='开始记录')

assert(Click(widget.testAction))
assert(F:Disable() and F:GetDamageTest().reason=='feature_disabled')
assert(S.Scheduler.tasks['v3.dps.damage_test_display']==nil)
assert(S.Scheduler.tasks['v3.dps.damage_test_deadline']==nil)
assert(not S.LastInternalEventError)
print('PASS damage test clock / cutoff / retained result / filters / dual-view layout / hide and disable')
