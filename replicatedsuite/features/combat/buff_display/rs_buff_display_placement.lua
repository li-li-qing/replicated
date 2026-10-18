------------------------------------------------------------------------
-- Replicated Suite · HUD 显示模式与屏幕固定布局
-- 作者：Replicated
-- QQ群：1104129461
-- 旧头顶 layout/arrangement canonical 保持原样；固定布局拥有独立小 Store。
-- 锚点为 UIParent 视口万分比（整数），不存物理像素，不复制 Aura/目标事实或调度器。
------------------------------------------------------------------------
if not ReplicatedSuite or ReplicatedSuite.BootError then return end
local S=ReplicatedSuite
local F,P=S.Features and S.Features.BuffDisplay,S.Persistence
if not F or not P then return end
local ID='v3.buff_display.placement'
local SCOPES={'player','target'}
local MODES={head=true,fixed=true}
local COMPONENT_KEYS={'info','class','gearScore','distance','buffs','debuffs','cooldowns','mainHand','offHand','ranged','wings','castBar','alias'}
local COMPONENTS={};for _,key in ipairs(COMPONENT_KEYS)do COMPONENTS[key]=true end
local ReadHeadProfile=F.GetScopeLayoutSettings
local GetHeadAlias=F.GetTargetAliasHudConfigProjection
local PersistHeadAlias=F.PersistTargetAliasHudConfig
local function GetHeadProfile(self,scope)
    local out=ReadHeadProfile(self,scope)
    if scope=='target'and GetHeadAlias then out.aliasHud=GetHeadAlias(self)end
    return out
end
local GetDefaults=F.GetDefaultHudCalibrationSnapshot
local ReadCalibration=F.GetHudCalibrationSnapshot
local function Copy(v)if type(v)~='table'then return v end;local out={};for k,x in pairs(v)do out[k]=Copy(x)end;return out end
local function Equal(a,b)
    if type(a)~=type(b)then return false end
    if type(a)~='table'then return a==b end
    for k,v in pairs(a)do if not Equal(v,b[k])then return false end end
    for k in pairs(b)do if a[k]==nil then return false end end
    return true
end
local function Integer(v,lo,hi,fallback)
    local n=tonumber(v);if not n or n~=n or math.abs(n)==math.huge then n=fallback end
    return math.max(lo,math.min(hi,math.floor(n+.5)))
end
local function ValidScope(scope)return scope=='player'or scope=='target'end
local function AliasProfile(value,fallback)
    value=type(value)=='table'and value or {};fallback=type(fallback)=='table'and fallback or {}
    local enabled=value.enabled;if enabled==nil then enabled=fallback.enabled end
    local function Float(v,base)
        local n=tonumber(v);if not n or n~=n or math.abs(n)==math.huge then n=base end
        return math.max(.1,math.min(1,n))
    end
    return {enabled=enabled~=false,x=Integer(value.x,-400,400,fallback.x or 0),y=Integer(value.y,-400,400,fallback.y or -94),
        fontSize=Integer(value.fontSize,8,32,fallback.fontSize or 12),alpha=Float(value.alpha,fallback.alpha or 1)}
end
local function Profile(value,fallback)
    local out=F:NormalizeHudVisualProfile(value,fallback)
    -- 固定 profile 携带自身排列代际；跨 v3/v5 分享不按接收方代际误解装备偏移。
    local order=type(value)=='table'and value.layoutPresetVersion or nil
    if order==nil then order=type(fallback)=='table'and fallback.layoutPresetVersion end
    out.layoutPresetVersion=Integer(order,1,5,tonumber(F.State.settings.layoutPresetVersion)or 3)
    -- orientation/nameLinked 在历史 layout 中无字段；固定 profile 自己持有，不能反写排列 Store。
    for _,key in ipairs({'buffs','debuffs','cooldowns'})do
        local cfg=type(value)=='table'and type(value.components)=='table'and value.components[key]
        local base=type(fallback)=='table'and type(fallback.components)=='table'and fallback.components[key]
        local mode=type(cfg)=='table'and cfg.orientation or type(base)=='table'and base.orientation or 'default'
        out.components[key].orientation=(mode=='horizontal'or mode=='vertical')and mode or 'default'
    end
    local class=type(value)=='table'and type(value.components)=='table'and value.components.class
    local base=type(fallback)=='table'and type(fallback.components)=='table'and fallback.components.class
    local linked;if type(class)=='table'then linked=class.nameLinked end
    if linked==nil then linked=type(base)=='table'and base.nameLinked end
    out.components.class.nameLinked=linked==true
    local alias=type(value)=='table'and value.aliasHud
    local baseAlias=type(fallback)=='table'and fallback.aliasHud
    if type(alias)=='table'or type(baseAlias)=='table'then out.aliasHud=AliasProfile(alias,baseAlias)end
    return out
end
local function DefaultPlacement(scope)return {mode='head',x=scope=='target'and 6500 or 3500,y=6800}end
local function DefaultComponentPlacement(scope,key)
    local out=DefaultPlacement(scope)
    local offsets={info={0,-700},class={-450,-700},gearScore={0,-350},distance={0,0},buffs={0,-1400},debuffs={0,500},
        cooldowns={0,1500},mainHand={-1100,-350},offHand={-650,-350},ranged={650,-350},wings={1100,-350},castBar={0,1050},alias={0,-1800}}
    local delta=offsets[key]or {0,0}
    out.x,out.y=Integer(out.x+delta[1],0,10000,out.x),Integer(out.y+delta[2],0,10000,out.y)
    return out
end
local function ComponentMode(state,key)
    return state.slots and state.slots[key]and state.slots[key].mode or state.mode
end
local function Normalize(value)
    local out={};local defaults=GetDefaults(F)
    for _,scope in ipairs(SCOPES)do
        local raw=type(value)=='table'and type(value[scope])=='table'and value[scope]or {}
        local base=DefaultPlacement(scope)
        out[scope]={mode=MODES[raw.mode]and raw.mode or 'head',x=Integer(raw.x,0,10000,base.x),y=Integer(raw.y,0,10000,base.y)}
        if type(raw.fixed)=='table'then out[scope].fixed=Profile(raw.fixed,defaults[scope])end
        -- 可选 slots 不补入历史 schema1 canonical；新需求按组件覆盖原整组默认。
        if type(raw.slots)=='table'then
            out[scope].slots={}
            for _,key in ipairs(COMPONENT_KEYS)do
                local slot=raw.slots[key]
                if type(slot)=='table'and (key~='alias'or scope=='target')then
                    local baseSlot=DefaultComponentPlacement(scope,key)
                    out[scope].slots[key]={mode=MODES[slot.mode]and slot.mode or out[scope].mode,
                        x=Integer(slot.x,0,10000,baseSlot.x),y=Integer(slot.y,0,10000,baseSlot.y)}
                end
            end
        end
    end
    return out
end
F.HudPlacementStoreId=ID
F.HudPlacementState=Normalize(nil)
if not P:GetStore(ID)then
    local store,err=P:RegisterV3Store({id=ID,owner=ID,scope=P.Scope.Account,lifetime=P.Lifetime.Permanent,
        schemaVersion=1,transportVersion=3,key=P.V3KeyPrefix..'buff_display_placement',
        budget={maxDepth=7,maxNodes=800,maxStringBytes=10000,maxEntriesPerTable=24},
        default=function()return Normalize(nil)end,get=function()return Normalize(F.HudPlacementState)end,
        apply=function(value)
            F.HudPlacementState=Normalize(value)
            if F.InvalidateSettingsCache then F:InvalidateSettingsCache()end
            return true
        end})
    if not store then error(err)end
end
function F:EnsureHudPlacementLoaded()
    local store=P:GetStore(ID)
    if store.writeFenced then self.HudPlacementError=tostring(store.writeFenceReason or '固定 HUD 存档已保护');return false,self.HudPlacementError end
    if store.loaded then return true end
    local ok,_,err=P:LoadStore(ID)
    if ok~=true and ok~='empty'then self.HudPlacementError=tostring(err or ok);return false,self.HudPlacementError end
    self.HudPlacementError=nil;return true
end
function F:GetHudDisplayModeProjection(scope)
    if not ValidScope(scope)then return nil,'HUD 范围无效'end
    local state=self.HudPlacementState[scope]
    return {mode=state.mode,x=state.x,y=state.y,error=self.HudPlacementError}
end
function F:GetDefaultHudPlacement(scope)return DefaultPlacement(scope)end
function F:GetDefaultHudComponentPlacement(scope,key)return DefaultComponentPlacement(scope,key)end
function F:GetHudComponentDisplayModeProjection(scope,key)
    if not ValidScope(scope)or not COMPONENTS[key]or (key=='alias'and scope~='target')then return nil,'HUD 组件无效'end
    local state=self.HudPlacementState[scope]
    local slot=Copy(state.slots and state.slots[key]or DefaultComponentPlacement(scope,key))
    slot.mode,slot.error=ComponentMode(state,key),self.HudPlacementError
    return slot
end
function F:GetHudModeLayoutsProjection()
    local out={}
    for _,scope in ipairs(SCOPES)do
        local head=GetHeadProfile(self,scope);local state=self.HudPlacementState[scope]
        local fixed=Profile(state.fixed or head,head)
        head.placement={mode='head',baseMode=state.mode,x=state.x,y=state.y,slots=Copy(state.slots)}
        fixed.placement={mode='fixed',baseMode=state.mode,x=state.x,y=state.y,slots=Copy(state.slots)}
        out[scope]={head=head,fixed=fixed,fixedInitialized=state.fixed~=nil}
    end
    return out
end
function F:GetHudCalibrationSnapshot()
    local snapshot=ReadCalibration(self)
    if self._placementHeadRead then return snapshot end
    -- 拆分显示后的活动投影是混合结果，不能作为任一模式的可写草稿。
    -- 显式返回两套草稿，scope 字段保留悬浮几何以兼容旧调用者的读写往返。
    if self.HudPlacementState.player.slots or self.HudPlacementState.target.slots then
        snapshot.modeLayouts=self:GetHudModeLayoutsProjection()
        for _,scope in ipairs(SCOPES)do
            if self.HudPlacementState[scope].slots then snapshot[scope]=Copy(snapshot.modeLayouts[scope].head)end
        end
    end
    return snapshot
end
function F:GetScopeLayoutSettings(scope)
    scope=scope=='target'and 'target'or 'player'
    local head=GetHeadProfile(self,scope);local state=self.HudPlacementState[scope]
    local mode=self._placementHeadRead and 'head'or state.mode
    local out=mode=='fixed'and Profile(state.fixed or head,head)or head
    if state.slots and not self._placementHeadRead then
        local fixed=Profile(state.fixed or head,head)
        out=Copy(head)
        for _,key in ipairs(COMPONENT_KEYS)do
            local source=ComponentMode(state,key)=='fixed'and fixed or head
            if key=='info'then out.info=Copy(source.info)
            elseif key=='alias'then out.aliasHud=Copy(source.aliasHud)
            else out.components[key]=Copy(source.components[key])end
        end
        local function InfoFlag(key,field)
            local source=ComponentMode(state,key)=='fixed'and fixed or head
            return source.info.enabled~=false and source.info[field]~=false
        end
        out.info.showClass=InfoFlag('info','showClass');out.info.showGear=InfoFlag('gearScore','showGear')
        out.info.showDistance=InfoFlag('distance','showDistance')
        local classSource=ComponentMode(state,'class')=='fixed'and fixed or head
        out.components.class.enabled=classSource.info.enabled~=false and out.components.class.enabled~=false
        out.info.enabled=out.info.showClass or out.info.showGear or out.info.showDistance or out.components.class.enabled
    end
    out.layoutPresetVersion=out.layoutPresetVersion or tonumber(self.State.settings.layoutPresetVersion)or 3
    out.placement={mode=mode,baseMode=state.mode,x=state.x,y=state.y,slots=not self._placementHeadRead and Copy(state.slots)or nil}
    if state.slots and not self._placementHeadRead then
        local needsHead=false
        for _,key in ipairs(COMPONENT_KEYS)do
            local enabled=key=='info'and out.info.showClass or key=='alias'and scope=='target'and out.aliasHud and out.aliasHud.enabled~=false
                or (key~='info'and key~='alias'and out.components[key]and out.components[key].enabled~=false)
            if enabled and ComponentMode(state,key)=='head'then needsHead=true end
        end
        out.placement.needsHead=needsHead
        out.placement.distanceFixed=ComponentMode(state,'distance')=='fixed'
    end
    return out
end
function F:GetHudLayerSettingsProjection(scope,layer)
    if not ValidScope(scope)or not MODES[layer]then return nil end
    local state=self.HudPlacementState[scope]
    local head=GetHeadProfile(self,scope)
    local out=layer=='fixed'and Profile(state.fixed or head,head)or Copy(head)
    local policy=self:GetHeadPolicyProjection()
    for key,value in pairs(policy)do out[key]=Copy(value)end
    out.componentLayer=true
    out.componentPlacements=layer=='fixed'and {}or nil
    for _,key in ipairs(COMPONENT_KEYS)do
        local selected=ComponentMode(state,key)==layer
        if key=='info'then out.info.showClass=out.info.showClass~=false and selected
        elseif key=='alias'then
            out.targetAlias=Copy(out.aliasHud or (GetHeadAlias and GetHeadAlias(self))or {})
            out.targetAlias.enabled=out.targetAlias.enabled~=false and selected and scope=='target'
        else out.components[key].enabled=out.components[key].enabled~=false and selected end
        if selected and layer=='fixed'then
            out.componentPlacements[key]=Copy(state.slots and state.slots[key]or DefaultComponentPlacement(scope,key))
        end
    end
    out.info.showGear=out.info.showGear~=false and ComponentMode(state,'gearScore')==layer
    out.info.showDistance=out.info.showDistance~=false and ComponentMode(state,'distance')==layer
    out.placement={mode=layer,x=0,y=0}
    return out
end
local EnsureStoreLoaded=F.EnsureStoreLoaded
function F:EnsureStoreLoaded(...)
    local ok,err=EnsureStoreLoaded(self,...)
    if ok==true then
        self:EnsureHudPlacementLoaded()
        -- 冷调用首次复制固定布局前读入真实名字几何；此可选小域故障不阻断其它 HUD。
        if GetHeadAlias and self.EnsureTargetAliasStoreLoaded then self:EnsureTargetAliasStoreLoaded()end
    end
    return ok,err
end
local function Changed()
    F:InvalidateSettingsCache()
    if GetHeadAlias and F.RefreshTargetAliasIdentity then F:RefreshTargetAliasIdentity('hud_placement')end
    if F.ReconcileLanes then F:ReconcileLanes()end
    if S.Events and S.Events.Publish then
        S.Events:Publish('v3.buff_display.settings','placement')
        S.Events:Publish('v3.buff_display.plates.updated','placement')
    end
end
local function Persist(value,reason)
    local ok,err=P:MutateStore(ID,function()F.HudPlacementState=Normalize(value);return true end,
        {delayMs=0,durable=true,reason=reason or 'hud_placement'})
    if ok then Changed()end
    return ok==true,err
end
local function WithHeadAlias(value,reason,action)
    if not value or not PersistHeadAlias then return action()end
    -- 未编辑的可选名字域即使处于保护状态也不应阻断其它组件几何保存。
    if Equal(GetHeadAlias(F),AliasProfile(value,GetHeadAlias(F)))then return action()end
    local ready,err=F:EnsureTargetAliasStoreLoaded();if not ready then return false,err end
    local before=GetHeadAlias(F)
    value=AliasProfile(value,before)
    if Equal(before,value)then return action()end
    local ok;ok,err=PersistHeadAlias(F,value,reason)
    if not ok then return false,err end
    local called,result,detail=pcall(action)
    if not called or result~=true then
        local restored,restoreErr=PersistHeadAlias(F,before,reason..':rollback')
        return false,tostring(called and detail or result)..(restored and ''or '；悬浮名字回滚失败：'..tostring(restoreErr))
    end
    return result,detail
end
local PersistCalibration=F.PersistHudCalibrationSnapshot
function F:PersistHudCalibrationSnapshot(snapshot,reason)
    if type(snapshot)~='table'then return false,'HUD 草稿无效'end
    local ready,err=self:EnsureStoreLoaded();if not ready then return false,err end
    ready,err=self:EnsureHudPlacementLoaded();if not ready then return false,err end
    local before=Normalize(self.HudPlacementState);local nextState=Copy(before);local heads={}
    for _,scope in ipairs(SCOPES)do
        local value=snapshot[scope]
        local banks=type(snapshot.modeLayouts)=='table'and snapshot.modeLayouts[scope]
        if type(banks)=='table'then
            if type(banks.head)=='table'then heads[scope]=Copy(banks.head)end
            if type(banks.fixed)=='table'and banks.fixedInitialized~=false then nextState[scope].fixed=Profile(banks.fixed,GetHeadProfile(self,scope))end
        end
        if type(value)=='table'then
            local placement=value.placement
            if placement~=nil then
                if type(placement)~='table'or not MODES[placement.mode]then return false,'HUD 显示模式无效'end
                for _,key in ipairs({'x','y'})do
                    local n=placement[key]
                    if n~=nil and (type(n)~='number'or n~=n or n<0 or n>10000 or n~=math.floor(n))then return false,'固定屏幕坐标无效'end
                    if n~=nil then nextState[scope][key]=n end
                end
                if placement.slots~=nil then
                    local valid,why=self:ValidateHudPlacement({[scope]={slots=placement.slots}})
                    if not valid then return false,why end
                    nextState[scope].slots=Copy(valid[scope].slots)
                else nextState[scope].mode=placement.mode end
            end
            local hasGeometry=value.plateScale~=nil or value.plate~=nil or value.info~=nil or value.components~=nil
            local editingMode=type(placement)=='table'and placement.mode or nextState[scope].mode
            if editingMode=='fixed'then
                if hasGeometry or not nextState[scope].fixed then
                    nextState[scope].fixed=Profile(hasGeometry and value or GetHeadProfile(self,scope),nextState[scope].fixed or GetHeadProfile(self,scope))
                end
            elseif hasGeometry then heads[scope]=Copy(value)end
        end
    end
    local changed=not Equal(before,nextState)
    if changed then local ok;ok,err=Persist(nextState,reason);if not ok then return false,err end end
    if next(heads)then
        -- 新小 Store 先提交；旧布局/排列失败则补偿固定配置。追踪大 Store 永不参与。
        local called,ok,why=pcall(WithHeadAlias,heads.target and heads.target.aliasHud,tostring(reason or 'hud_placement_alias'),
            function()return PersistCalibration(self,heads,reason)end)
        if not called or ok~=true then
            local restored,restoreErr=true,nil
            if changed then restored,restoreErr=Persist(before,tostring(reason or 'hud_placement')..':rollback')end
            return false,tostring(called and why or ok)..(restored and ''or '；固定 HUD 回滚失败：'..tostring(restoreErr))
        end
    end
    Changed();return true
end
function F:SetHudDisplayMode(scope,mode)
    if not ValidScope(scope)or not MODES[mode]then return false,'HUD 显示模式无效'end
    return self:PersistHudCalibrationSnapshot({[scope]={placement={mode=mode}}},'hud_display_mode:'..scope)
end
function F:SetHudComponentDisplayMode(scope,key,mode)
    if not ValidScope(scope)or not COMPONENTS[key]or not MODES[mode]or (key=='alias'and scope~='target')then return false,'HUD 组件显示模式无效'end
    local ready,err=self:EnsureStoreLoaded();if not ready then return false,err end
    ready,err=self:EnsureHudPlacementLoaded();if not ready then return false,err end
    local state=Normalize(self.HudPlacementState)
    state[scope].slots=state[scope].slots or {}
    local slot=Copy(state[scope].slots[key]or DefaultComponentPlacement(scope,key));slot.mode=mode
    state[scope].slots[key]=slot
    if mode=='fixed'and not state[scope].fixed then state[scope].fixed=Profile(GetHeadProfile(self,scope),GetHeadProfile(self,scope))end
    return Persist(state,'hud_component_mode:'..scope..':'..key)
end
-- 同一坐标 Authority：正式渲染与校准均传入 UIParent 视口，结果不受镜头/投影 depth 影响。
function F.ComputeFixedHudAnchor(placement,width,height)
    width,height=tonumber(width),tonumber(height)
    if not width or not height or width<=0 or height<=0 then return nil,nil,'viewport_unavailable'end
    return math.floor(width*placement.x/10000+.5),math.floor(height*placement.y/10000+.5)
end
F.Commands=F.Commands or {}
function F.Commands:SetHudDisplayMode(scope,mode)return F:SetHudDisplayMode(scope,mode)end
function F.Commands:GetHudDisplayModeProjection(scope)return F:GetHudDisplayModeProjection(scope)end
function F.Commands:SetHudComponentDisplayMode(scope,key,mode)return F:SetHudComponentDisplayMode(scope,key,mode)end
function F.Commands:GetHudComponentDisplayModeProjection(scope,key)return F:GetHudComponentDisplayModeProjection(scope,key)end
local SetHudVisibility=F.SetHudVisibility
function F:SetHudVisibility(scope,key,value)
    if not ValidScope(scope)or not self.HudPlacementState[scope].slots then return SetHudVisibility(self,scope,key,value)end
    if type(value)~='boolean'then return false,'显示状态必须为开或关'end
    if key=='alias'then return scope=='target'and self:SetCurrentTargetAliasDisplayEnabled(value)or false end
    local banks=self:GetHudModeLayoutsProjection()
    local changed=false
    for _,item in ipairs(self.HudVisibilityDefinitions)do
        if item.key==key or (key=='images'and item.kind=='image')then
            local component=item.key=='className'and 'info'or item.component or item.key
            local mode=ComponentMode(self.HudPlacementState[scope],component)
            local profile=banks[scope][mode];local info,components=profile.info,profile.components
            if value and (component=='info'or component=='class'or component=='gearScore'or component=='distance')and info.enabled==false then
                info.showClass,info.showGear,info.showDistance=false,false,false
                components.class.enabled,components.gearScore.enabled,components.distance.enabled=false,false,false
                info.enabled=true
            end
            if component=='info'then info.showClass=value
            elseif component=='gearScore'then info.showGear=value;components.gearScore.enabled=value
            elseif component=='distance'then info.showDistance=value;components.distance.enabled=value
            else components[component].enabled=value end
            changed=true
        end
    end
    if not changed then return false,'未知显示项'end
    return self:PersistHudCalibrationSnapshot({modeLayouts=banks},'hud_component_visibility:'..scope..':'..key)
end
if GetHeadAlias then
    function F:GetTargetAliasHudConfigProjection()
        local state=self.HudPlacementState.target
        local alias=ComponentMode(state,'alias')=='fixed'and not self._placementHeadRead and state.fixed and state.fixed.aliasHud
        return alias and Copy(alias)or GetHeadAlias(self)
    end
    function F:PersistTargetAliasHudConfig(value,reason)
        if ComponentMode(self.HudPlacementState.target,'alias')~='fixed'or self._placementHeadRead then return PersistHeadAlias(self,value,reason)end
        local profile=self:GetHudModeLayoutsProjection().target.fixed;profile.aliasHud=AliasProfile(value,profile.aliasHud or GetHeadAlias(self))
        return self:PersistHudCalibrationSnapshot({target=profile},reason)
    end
    local SetHeadAliasEnabled=F.SetTargetAliasDisplayEnabled
    function F:SetTargetAliasDisplayEnabled(value,reason)
        if ComponentMode(self.HudPlacementState.target,'alias')~='fixed'or self._placementHeadRead then return SetHeadAliasEnabled(self,value,reason)end
        local alias=self:GetTargetAliasHudConfigProjection();alias.enabled=value==true
        return self:PersistTargetAliasHudConfig(alias,reason)
    end
end
F.HudPlacementContractVersion=1

-- 传输为纯数据行；完整包保存悬浮+固定两套几何。旧包不含这些行时保留当前模式。
-- 校验沿用现行几何规范化且拒绝未知路径/越界值，不执行传入文本，不扩大追踪包范围。
local function CheckFields(value,normalized)
    if type(value)~='table'or type(normalized)~='table'then return false end
    for key,item in pairs(value)do
        local expected=normalized[key]
        if expected==nil then return false end
        if type(item)=='table'then if not CheckFields(item,expected)then return false end
        elseif type(item)~=type(expected)or item~=expected then return false end
    end
    return true
end
function F:ValidateHudPlacement(value)
    if type(value)~='table'then return nil,'HUD 模式数据无效'end
    local defaults=GetDefaults(self)
    for scope,part in pairs(value)do
        if not ValidScope(scope)or type(part)~='table'then return nil,'HUD 模式范围无效'end
        for key,item in pairs(part)do
            if key=='mode'then if not MODES[item]then return nil,'HUD 显示模式无效'end
            elseif key=='x'or key=='y'then
                if type(item)~='number'or item~=item or item<0 or item>10000 or item~=math.floor(item)then return nil,'固定屏幕坐标无效'end
            elseif key=='slots'then
                if type(item)~='table'then return nil,'组件显示配置无效'end
                for component,slot in pairs(item)do
                    if not COMPONENTS[component]or (component=='alias'and scope~='target')or type(slot)~='table'or not MODES[slot.mode]then return nil,'组件显示配置无效'end
                    for field,n in pairs(slot)do
                        if field~='mode'and (field~='x'and field~='y'or type(n)~='number'or n~=n or n<0 or n>10000 or n~=math.floor(n))then return nil,'组件屏幕坐标无效'end
                    end
                end
            elseif key=='fixed'then
                if type(item)~='table'or not CheckFields(item,Profile(item,defaults[scope]))then return nil,'固定 HUD 属性无效'end
            else return nil,'未知 HUD 模式字段'end
        end
    end
    return Copy(value)
end
local function Flatten(value,prefix,out)
    local keys={};for key in pairs(value)do keys[#keys+1]=key end;table.sort(keys)
    for _,key in ipairs(keys)do
        local path=prefix==''and key or prefix..'.'..key;local item=value[key]
        if type(item)=='table'then Flatten(item,path,out)
        else out[#out+1]={path=path,value=type(item)=='boolean'and (item and 'true'or 'false')or tostring(item)}end
    end
end
local ExportAll,SerializeExport,ParseImportText,PrepareTrackingImport,ImportAll=F.ExportAll,F.SerializeExport,F.ParseImportText,F.PrepareTrackingImport,F.ImportAll
local function HeadRead(action)
    local before=F._placementHeadRead;F._placementHeadRead=true
    local ok,a,b=pcall(action);F._placementHeadRead=before
    if not ok then return false,a end
    return a,b
end
function F:ExportAll(mode)
    local data,err=HeadRead(function()return ExportAll(self,mode)end)
    if type(data)~='table'then error(err or 'HUD 导出失败')end
    if mode~='tracking'then
        local ready,why=self:EnsureHudPlacementLoaded();if not ready then error(why)end
        data.placement=Normalize(self.HudPlacementState)
        if GetHeadAlias then
            ready,why=self:EnsureTargetAliasStoreLoaded();if not ready then error(why)end
            data.headAliasHud=GetHeadAlias(self)
        end
    end
    return data
end
function F:SerializeExport(data)
    data=data or self:ExportAll()
    local text=SerializeExport(self,data)
    if data.exportMode~='tracking'and data.headAliasHud then
        local alias=data.headAliasHud
        if not CheckFields(alias,AliasProfile(alias))then error('悬浮名字属性无效')end
        text=text..'\nHUDHEADALIAS='..(alias.enabled and 'true'or 'false')..':'..alias.x..':'..alias.y..':'..alias.fontSize..':'..alias.alpha
    end
    if data.exportMode~='tracking'and data.placement~=nil then
        local value,err=self:ValidateHudPlacement(data.placement);if not value then error(err)end
        for _,scope in ipairs(SCOPES)do
            local part=value[scope]
            if part then
                local placement=Normalize({[scope]=part})[scope]
                text=text..'\nHUDPLACEMENT='..scope..':'..placement.mode..':'..placement.x..':'..placement.y
                for _,key in ipairs(COMPONENT_KEYS)do
                    local slot=placement.slots and placement.slots[key]
                    if slot then text=text..'\nHUDSLOT='..scope..':'..key..':'..slot.mode..':'..slot.x..':'..slot.y end
                end
                if part.fixed then
                    local fields={};Flatten(part.fixed,'',fields)
                    for _,field in ipairs(fields)do text=text..'\nFIXEDHUD='..scope..':'..field.path..':'..field.value end
                end
            end
        end
    end
    return text
end
function F:ParseImportText(text)
    if type(text)~='string'or #text>65535 then return ParseImportText(self,text)end
    local pass,placement,seen,errors,headAlias={},nil,{},{},nil
    for raw in (text..'\n'):gmatch('([^\n]*)\n')do
        local line=raw:gsub('\r$',''):match('^%s*(.-)%s*$')
        if line:upper():match('^HUDHEADALIAS%s*=')then
            local enabled,x,y,font,alpha=line:match('^[^=]+=([%a]+):([^:]+):([^:]+):([^:]+):([^:]+)$')
            if headAlias or (enabled~='true'and enabled~='false')then errors[#errors+1]='悬浮名字属性行无效或重复'
            else
                headAlias={enabled=enabled=='true',x=tonumber(x),y=tonumber(y),fontSize=tonumber(font),alpha=tonumber(alpha)}
                if not headAlias.x or not headAlias.y or not headAlias.fontSize or not headAlias.alpha or not CheckFields(headAlias,AliasProfile(headAlias))then errors[#errors+1]='悬浮名字属性无效'end
            end
        elseif line:upper():match('^HUDSLOT%s*=')then
            local scope,key,mode,x,y=line:match('^[^=]+=([%a]+):([%a]+):([%a]+):(%d+):(%d+)$')
            if not ValidScope(scope)or not COMPONENTS[key]or not MODES[mode]or seen['slot:'..tostring(scope)..':'..tostring(key)]then errors[#errors+1]='组件显示行无效或重复'
            else
                placement=placement or {};placement[scope]=placement[scope]or {};placement[scope].slots=placement[scope].slots or {}
                placement[scope].slots[key]={mode=mode,x=tonumber(x),y=tonumber(y)};seen['slot:'..scope..':'..key]=true
            end
        elseif line:upper():match('^HUDPLACEMENT%s*=')then
            local scope,mode,x,y=line:match('^[^=]+=([%a]+):([%a]+):(%d+):(%d+)$')
            if not ValidScope(scope)or not MODES[mode]or seen['mode:'..tostring(scope)]then errors[#errors+1]='HUD 模式行无效或重复'
            else
                placement=placement or {};placement[scope]=placement[scope]or {}
                placement[scope].mode,placement[scope].x,placement[scope].y=mode,tonumber(x),tonumber(y)
                seen['mode:'..scope]=true
            end
        elseif line:upper():match('^FIXEDHUD%s*=')then
            local scope,path,rawValue=line:match('^[^=]+=([%a]+):([%a%.]+):([^:]+)$')
            if not ValidScope(scope)or not path or path:find('..',1,true)or path:sub(1,1)=='.'or path:sub(-1)=='.'or seen[tostring(scope)..':'..tostring(path)]then
                errors[#errors+1]='固定 HUD 属性行无效或重复'
            else
                local value=rawValue=='true'and true or rawValue=='false'and false or tonumber(rawValue)or rawValue
                -- false 不能经 and/or 表达式变回字符串。
                if rawValue=='false'then value=false end
                placement=placement or {};placement[scope]=placement[scope]or {};placement[scope].fixed=placement[scope].fixed or {}
                local node=placement[scope].fixed;local parts={};for key in path:gmatch('[^.]+')do parts[#parts+1]=key end
                local valid=true
                for i=1,#parts-1 do
                    if node[parts[i]]~=nil and type(node[parts[i]])~='table'then valid=false;break end
                    node[parts[i]]=node[parts[i]]or {};node=node[parts[i]]
                end
                if not valid or node[parts[#parts]]~=nil then errors[#errors+1]='固定 HUD 属性路径冲突'
                else node[parts[#parts]]=value;seen[scope..':'..path]=true end
            end
        else pass[#pass+1]=raw end
    end
    local parsed=ParseImportText(self,table.concat(pass,'\n'))
    if placement then local valid,err=self:ValidateHudPlacement(placement);if not valid then errors[#errors+1]=err end end
    for _,err in ipairs(errors)do parsed.errors[#parsed.errors+1]=err end
    parsed.data.placement=placement;parsed.data.headAliasHud=headAlias;parsed.data._parseErrors=#parsed.errors
    return parsed
end
function F:PrepareTrackingImport(data,mode)
    if type(data)=='table'and data.headAliasHud~=nil and not CheckFields(data.headAliasHud,AliasProfile(data.headAliasHud))then return nil,'悬浮名字属性无效'end
    if type(data)=='table'and data.placement~=nil then
        local valid,err=self:ValidateHudPlacement(data.placement);if not valid then return nil,err end
    end
    return PrepareTrackingImport(self,data,mode)
end
function F:ImportAll(data,mode)
    local prepared,err=self:PrepareTrackingImport(data,mode);if not prepared then return false,err end
    local ready;ready,err=self:EnsureStoreLoaded();if not ready then return false,err end
    ready,err=self:EnsureHudPlacementLoaded();if not ready then return false,err end
    local before=Normalize(self.HudPlacementState);local after=Copy(before)
    for scope,part in pairs(type(data.placement)=='table'and data.placement or {})do
        for key,value in pairs(part)do after[scope][key]=Copy(value)end
        if after[scope].mode=='fixed'and not after[scope].fixed then after[scope].fixed=Profile(GetHeadProfile(self,scope),GetHeadProfile(self,scope))end
    end
    local changed=not Equal(before,after)
    if changed then local ok;ok,err=Persist(after,'hud_placement_import');if not ok then return false,err end end
    local ok,why=WithHeadAlias(data.headAliasHud,'hud_alias_import',function()
        return HeadRead(function()return ImportAll(self,data,mode)end)
    end)
    if ok~=true then
        local restored,restoreErr=true,nil
        if changed then restored,restoreErr=Persist(before,'hud_placement_import_rollback')end
        Changed()
        return false,tostring(why)..(restored and ''or '；固定 HUD 回滚失败：'..tostring(restoreErr))
    end
    Changed();return ok,why
end
