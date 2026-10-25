-- 寻宝自定义坐标：真实 Feature、Demand、库存和 RSUI；Native 由现有宿主替代。
local Host=dofile('tools/rs_bag_action_test_host.lua')
local passed=0
local function Boot()
    local h=Host({capacity=4,storageCapacity=4});local S=h.S
    X2Unit.GetUnitWorldPositionByTarget=function()return 21504,28672,0,0 end
    X2Unit.GetCurrentZoneGroup=function()return 2 end
    h.mapCalls={}
    X2Map={ShowWorldmapLocation=function(_,zone,x,y,z)
        h.mapCalls[#h.mapCalls+1]={zone=zone,x=x,y=y,z=z};return true
    end}
    dofile('features/life/shared/rs_life_slice_factory.lua')
    dofile('data/rs_treasure_sea_points.lua');dofile('features/life/treasure/rs_treasure_sea_catalog.lua')
    dofile('features/life/treasure/rs_treasure_feature.lua');dofile('features/life/treasure/rs_treasure_inventory.lua')
    local f=S.Features.Treasure;assert(f:Initialize());assert(f:Enable());assert(f:AcquireConsumer('test:page'))
    return h,S,f
end
local function Test(name,fn)fn();passed=passed+1;print('PASS custom-point '..name)end
local function Track(f,...)
    assert(type(f.Commands.TrackCustomPoint)=='function','custom coordinate command is missing')
    return f.Commands:TrackCustomPoint(...)
end
local function Click(control)return control.root.events.OnClick(control.root,'LeftButton')end
Test('E/N and W/S coordinates use the existing global coordinate convention',function()
    local h,S,f=Boot()
    assert(Track(f,'E1','30','0','N2','15','0'))
    local p=f:GetProjection();assert(p.selected.kind=='custom' and p.selected.worldX==23040 and p.selected.worldY==30976)
    assert(p.selected.groupKey==nil,'custom target was converted into a bag group')
    assert(#h.mapCalls==0,'tracking opened the native map without a map action')
    assert(Track(f,'w2',30,'','s3',15,0))
    p=f:GetProjection();assert(p.selected.worldX==18944 and p.selected.worldY==25344)
end)
Test('fractional minutes and seconds retain precision and zero degrees work',function()
    local h,S,f=Boot();assert(Track(f,'E0','0','3.515625','N0','0.25','0'))
    local p=f:GetProjection();assert(p.selected.worldX==21505)
    assert(math.abs(p.selected.worldY-28676.2666666667)<0.000001)
    assert(p.selected.text:find('3.515625',1,true),'coordinate display lost fractional seconds')
end)
Test('invalid input leaves the previous target and demand unchanged',function()
    local h,S,f=Boot();assert(Track(f,'E1',0,0,'N1',0,0));local key=f:GetProjection().selected.key;local count=f.consumerCount
    local cases={{'E1',60,0,'N1',0,0},{'E1',-1,0,'N1',0,0},{'E1',0,60,'N1',0,0},
        {'E1',0,0,'N1','bad',0},{'N1',0,0,'E1',0,0},{'E181',0,0,'N1',0,0},
        {'E1',0,0,'N91',0,0},{'E1',0,0,'N1',0,math.huge},{'E1',0,0,'N1',0,0/0}}
    for _,args in ipairs(cases)do
        local ok,err=Track(f,unpack(args));assert(ok==false and type(err)=='string')
        assert(f:GetProjection().selected.key==key and f.consumerCount==count)
    end
end)
Test('inventory refresh cannot erase a custom target or scan a fictitious bag slot',function()
    local h,S,f=Boot();assert(Track(f,'E1',0,0,'N1',0,0));local key=f:GetProjection().selected.key
    local reads=h.inventoryReads
    for i=1,8 do h.ms=h.ms+500;assert(f.Authority:CheckInventory(),'inventory check failed');assert(f.Authority:UpdatePosition(),f.Authority.error or 'position update failed')end
    local p=f:GetProjection();assert(p.selected.key==key and p.status=='ready' and p.selected.distance>0)
    assert(h.inventoryReads==reads,'custom target polled the inventory')
    h.bag={{itemType=24581,name='map',longitudeDir='E',longitudeDeg=1,longitudeMin=0,longitudeSec=0,
        latitudeDir='N',latitudeDeg=2,latitudeMin=0,latitudeSec=0,zoneGroupId=2}}
    assert(f:Refresh());p=f:GetProjection()
    assert(#p.rows==1 and p.selected.key==key,'explicit refresh failed to update the bag without replacing the custom target')
end)
Test('closing the page retains guidance and stopping releases the final lease',function()
    local h,S,f=Boot();assert(Track(f,'E1',0,0,'N1',0,0));assert(f:ReleaseConsumer('test:page'))
    assert(f.consumerCount==1 and f.trackingConsumerHeld)
    assert(S.Scheduler.tasks.v3_life_treasure_position and S.Scheduler.tasks.v3_life_treasure_compass)
    assert(f.Commands:StopTracking());assert(f.consumerCount==0 and not f.trackingConsumerHeld)
    assert(not f:GetProjection().selected and not S.Scheduler.tasks.v3_life_treasure_position)
    assert(not S.Scheduler.tasks.v3_life_treasure_compass)
end)
Test('explicit map command uses custom XY and changing the target cancels queued requests',function()
    local h,S,f=Boot();assert(Track(f,'W2',30,0,'S3',15,0));assert(f.Commands:ShowSelectedOnMap())
    local call=assert(h.mapCalls[1]);assert(call.zone==2 and call.x==18944 and call.y==25344)
    assert(f.Commands:ShowSelectedOnMap());assert(f:GetProjection().mapActionPending)
    assert(Track(f,'E0',0,0,'N0',0,0));assert(not f:GetProjection().mapActionPending)
    assert(#h.mapCalls==1,'changing the target executed the obsolete request')
end)
Test('switching back to a treasure map releases custom tracking without losing map selection',function()
    local h,S,f=Boot()
    h.bag={{itemType=24581,name='map',longitudeDir='E',longitudeDeg=1,longitudeMin=0,longitudeSec=0,
        latitudeDir='N',latitudeDeg=2,latitudeMin=0,latitudeSec=0,zoneGroupId=2}}
    assert(f:Refresh());local mapKey=f:GetProjection().rows[1].key
    assert(Track(f,'W1',0,0,'S1',0,0));assert(f.Commands:Select(mapKey))
    assert(not f.trackingConsumerHeld and f.consumerCount==1 and f:GetProjection().selected.kind~='custom')
end)
Test('sea and custom points share one lease and a stored coordinate releases it',function()
    local h,S,f=Boot();assert(f.Commands:SetViewKind('ships'));assert(f.Commands:TrackNearest())
    local count=f.consumerCount
    assert(Track(f,'E1',0,0,'N1',0,0));assert(f.consumerCount==count)
    assert(f.Commands:TrackNearest());assert(f.consumerCount==count and f:GetProjection().selected.kind=='ships')
    assert(f.Commands:SetViewKind('maps'))
    h.storage={{itemType=24581,name='map',longitudeDir='E',longitudeDeg=1,longitudeMin=0,longitudeSec=0,
        latitudeDir='N',latitudeDeg=2,latitudeMin=0,latitudeSec=0,zoneGroupId=2}}
    assert(f.Commands:IdentifyCurrentCoffer());local key=f:GetProjection().rows[1].key
    assert(Track(f,'W1',0,0,'S1',0,0));assert(f.Commands:Select(key))
    assert(f:GetProjection().selected.kind=='catalog' and not f.trackingConsumerHeld and f.consumerCount==1)
end)
Test('disabled feature rejects coordinates and clears a custom session on disable',function()
    local h,S,f=Boot();assert(Track(f,'E1',0,0,'N1',0,0));assert(f:Disable('test'))
    local ok=Track(f,'W1',0,0,'S1',0,0);assert(ok==false)
    assert(not f:GetProjection().selected and not f.trackingConsumerHeld)
end)
local function UI()
    local h,S,f=Boot()
    S.Layout=S.Layout or {}
    S.Layout.ResolveSuiteOwnedViewportLogicalRect=function(_,n)
        local x,y,p=0,0,n
        while p do x=x+(p.x or 0);y=y+(p.y or 0);p=p.parent end
        return x,y,n.width,n.height,{}
    end
    dofile('ui/framework/rs_ui_popup_positioning.lua')
    S.UIV3.WidgetHost={Register=function()return true end,BindFeatureLifecycle=function()return true end,IsVisible=function()return false end}
    S.Features.Trade=f;S.Features.Bonds=f;S.Features.Fishing=f
    S.UI.CreateWindowShell=function()error('content test must not create a native window')end
    dofile('ui/framework/rs_ui_floating_surface.lua')
    dofile('presentation/v3/widgets/rs_v3_treasure_controls.lua')
    dofile('presentation/v3/widgets/rs_v3_life_economy_widgets.lua')
    local parent=h.Native(nil,'custom_parent',0,0,820,600)
    local body=assert(S.RSUI:VerticalBox({id='custom_body',parent=parent,gap=4}))
    local main=S.UIV3.TreasureControlsV3:Build(body,f,'main_custom_',{})
    local content=assert(S.UIV3.LifeEconomyContent:Create(parent,'Treasure','float_custom_'))
    assert(content:Refresh())
    return h,S,f,body,main,content
end
Test('page and floating form submit visible drafts through the same feature command',function()
    local h,S,f,body,main,content=UI()
    for _,form in ipairs({(assert(main.custom,'page custom form missing')),(assert(content.treasureCustomControls,'floating custom form missing'))})do
        if form==main.custom then assert(Click(form.toggle))else assert(content.treasureSettingsDropdown:SetValue('custom'))end
        assert(form.form.visible)
        assert(form.longitude:SetValue('W2'));assert(form.latitude:SetValue('S3'))
        form.lonMinutes.root:SetText('30');form.latMinutes.root:SetText('15')
        form.lonSeconds.root:SetText('0');form.latSeconds.root:SetText('0')
        assert(Click(form.track));local p=f:GetProjection()
        assert(p.selected.worldX==18944 and p.selected.worldY==25344,'button ignored unblurred input')
        if form~=main.custom then
            assert(not form.expanded and content.table.visible,'successful tracking did not restore the list')
            assert(content.treasureSettingsDropdown:SetValue('custom'))
        end
        form.lonMinutes.root:SetText('60');assert(Click(form.track)==false)
        assert(form.hint.text:find('分',1,true),'invalid coordinate has no visible feedback')
        assert(f:GetProjection().selected.worldX==18944)
    end
end)
Test('compact layout keeps coordinate inputs visible and closes popups when hidden',function()
    local h,S,f,body,main,content=UI();local form=assert(content.treasureCustomControls)
    assert(f.Commands:SetViewKind('ships'));assert(content:Refresh())
    content.content:Layout(0,0,216,172)
    assert(content.table.height>=60,'collapsed custom form consumed the existing point list')
    assert(content.treasureSettingsDropdown:SetValue('custom'));content.content:Layout(0,0,216,172)
    for _,c in ipairs({form.longitude,form.latitude,form.lonMinutes,form.lonSeconds,form.latMinutes,form.latSeconds,form.track,form.hint})do
        local visible,why=h:VisibleRect(c);assert(visible,why)
    end
    assert(Click(form.longitude));assert(form.longitude.open)
    assert(content:SetAvailable(false));assert(not form.longitude.open,'custom popup survived a hidden assistant')
    assert(content:SetAvailable(true));assert(Click(assert(form.back,'editor has no return button')))
    assert(content.table.visible and content.treasureActionRow.visible and not form.expanded,'return did not restore the normal assistant')
end)
Test('default and minimum saved floating sizes keep coordinates and actions accessible',function()
    local h,S,f,body,main,content=UI();local form=content.treasureCustomControls
    assert(content.treasureSettingsDropdown:SetValue('custom'))
    for _,size in ipairs({{366,154},{216,54}})do
        form.form:SetScrollOffset(0,false);content.content:Layout(0,0,size[1],size[2])
        local visible,why=h:VisibleRect(form.longitude);assert(visible,why)
        form.form:SetScrollOffset(form.form:GetMaxOffset(),true)
        visible,why=h:VisibleRect(form.track);assert(visible,why)
        visible,why=h:VisibleRect(form.back);assert(visible,why)
    end
    assert(Click(form.back));assert(content.table.visible and content.treasureFilters.visible)
end)
Test('wheel scrolling closes a dropdown before hiding its coordinate row',function()
    local h,S,f,body,main,content=UI();local form=content.treasureCustomControls
    assert(content.treasureSettingsDropdown:SetValue('custom'));content.content:Layout(0,0,216,54)
    assert(Click(form.longitude));assert(form.longitude.open and form.longitude.popup.shown)
    local wheel=assert(form.form.root.events.OnWheelDown);assert(wheel(form.form.root))
    assert(not form.longitude.open and form.longitude.popup.shown==false,'scrolling left a detached coordinate popup open')
    assert(form.form:ScrollToTop());assert(Click(form.latitude));form.form:ScrollToBottom()
    assert(not form.latitude.open and form.latitude.popup.shown==false,'scrollbar path left the latitude popup open')
end)
Test('the main page integrates coordinate entry and closes its popup on deactivation',function()
    local h,S,f,body,main,content=UI()
    local PH=S.UIV3.PageHost
    PH.BindFeatureConsumerLifecycle=function()return true end
    PH.SyncFeatureConsumer=function(_,page)return page:Refresh()end
    PH.ReleaseFeatureConsumer=function()return true end
    S.UI.CreateSlider=function(_,parent,id,x,y,w,ht,minimum,maximum,step,value)
        local n=h.Native(parent,id,x,y,w,ht);n.value=value
        function n:GetValue()return self.value end;function n:SetValue(v)self.value=v;return true end
        function n:SetRange()return true,true end;return n
    end
    dofile('ui/framework/rs_ui_numeric_range_store.lua');dofile('ui/framework/rs_ui_forms.lua');dofile('ui/framework/rs_ui_settings_foundation.lua')
    dofile('presentation/v3/pages/rs_v3_life_m16_pages.lua')
    local parent=h.Native(nil,'page_custom_parent',0,0,820,680)
    local page=assert(PH.factories['life.treasure'](parent,'life.treasure'));assert(page:OnActivated())
    local form=assert(page.treasureControls.custom);assert(Click(form.toggle));page:Layout(0,0,820,680)
    assert(form.longitude:SetValue('E1'));assert(form.latitude:SetValue('N2'))
    form.lonMinutes.root:SetText('30');form.latMinutes.root:SetText('15');assert(Click(form.track))
    assert(f:GetProjection().selected.worldX==23040 and f:GetProjection().selected.worldY==30976)
    local visible,why=h:VisibleRect(form.track);assert(visible,why)
    assert(Click(form.latitude));assert(form.latitude.open);assert(page:OnDeactivated());assert(not form.latitude.open)
end)
print('TREASURE_CUSTOM_POINT PASS: '..passed..' cases (RU Native rendering remains unverified)')
