------------------------------------------------------------------------
-- Replicated Suite · HUD 排列与布局预设
-- 作者：Replicated
-- QQ群：1104129461
-- 方向独立存档并叠加只读投影，不扩充历史主Store/layout canonical。
-- default保留旧横排坐标；显式横/纵排列使用完整图标间距，避免新预设换行重叠。
------------------------------------------------------------------------
if not ReplicatedSuite or ReplicatedSuite.BootError then return end
local S=ReplicatedSuite
local F,P=S.Features and S.Features.BuffDisplay,S.Persistence
if not F or not P then return end
local ID='v3.buff_display.arrangement'
local KEYS={'buffs','debuffs','cooldowns'}
local KNOWN={buffs=true,debuffs=true,cooldowns=true}
local MODES={default=true,horizontal=true,vertical=true}
local IDENTITIES={free=true,paired=true}
local function Copy(v)if type(v)~='table'then return v end;local out={};for k,x in pairs(v)do out[k]=Copy(x)end;return out end
local function Normalize(value)
    local out={player={},target={}}
    for _,scope in ipairs({'player','target'})do for _,key in ipairs(KEYS)do
        local mode=type(value)=='table'and type(value[scope])=='table'and value[scope][key]
        out[scope][key]=MODES[mode]and mode or 'default'
    end end
    -- 可选扩展不补进旧方向档的 canonical；已存在的 schema1 数据继续按原形状验真。
    if type(value)=='table'and type(value.identity)=='table'then
        out.identity={}
        for _,scope in ipairs({'player','target'})do out.identity[scope]=IDENTITIES[value.identity[scope]]and value.identity[scope]or 'free'end
    end
    return out
end
local function StateValue(state,scope,key)
    if scope=='identity'then return state.identity and state.identity[key]or 'free'end
    return state[scope]and state[scope][key]or 'default'
end
local function Changed()
    if F.InvalidateSettingsCache then F:InvalidateSettingsCache()end
    if S.Events and S.Events.Publish then
        S.Events:Publish('v3.buff_display.settings','arrangement')
        S.Events:Publish('v3.buff_display.plates.updated','arrangement')
    end
end
F.HudArrangementState=Normalize(nil)
F.HudArrangementStoreId=ID
if not P:GetStore(ID)then
    local store,err=P:RegisterV3Store({id=ID,owner=ID,scope=P.Scope.Account,lifetime=P.Lifetime.Permanent,
        schemaVersion=1,transportVersion=3,key=P.V3KeyPrefix..'buff_display_arrangement',
        budget={maxDepth=3,maxNodes=32,maxStringBytes=512,maxEntriesPerTable=8},
        default=function()return Normalize(nil)end,get=function()return Normalize(F.HudArrangementState)end,
        apply=function(value)
            F.HudArrangementState=Normalize(value)
            if F.InvalidateSettingsCache then F:InvalidateSettingsCache()end
            return true
        end})
    if not store then error(err)end
end
function F:EnsureHudArrangementLoaded()
    local store=P:GetStore(ID)
    if store.writeFenced then self.HudArrangementError=tostring(store.writeFenceReason or '排列存档已保护');return false,self.HudArrangementError end
    if store.loaded then return true end
    local ok,_,err=P:LoadStore(ID)
    if ok~=true and ok~='empty'then self.HudArrangementError=tostring(err or ok);return false,self.HudArrangementError end
    self.HudArrangementError=nil;return true
end
function F:GetHudArrangementProjection()
    local out=Copy(self.HudArrangementState)
    out.identity={player=StateValue(out,'identity','player'),target=StateValue(out,'identity','target')}
    return out
end
function F:ValidateHudArrangement(value)
    if type(value)~='table'then return nil,'排列配置必须是表'end
    for scope,items in pairs(value)do
        if type(items)~='table'then return nil,'排列范围无效'end
        if scope=='identity'then
            for key,mode in pairs(items)do if (key~='player'and key~='target')or not IDENTITIES[mode]then return nil,'职业组合模式无效'end end
        else
            if scope~='player'and scope~='target'then return nil,'排列范围无效'end
            for key,mode in pairs(items)do if not KNOWN[key]or not MODES[mode]then return nil,'排列方向无效'end end
        end
    end
    return Copy(value)
end
function F:PersistHudArrangement(value,reason)
    local patch,err=self:ValidateHudArrangement(value);if not patch then return false,err end
    local ready;ready,err=self:EnsureHudArrangementLoaded();if not ready then return false,err end
    local ok;ok,err=P:MutateStore(ID,function()
        local nextState=Normalize(self.HudArrangementState)
        for scope,items in pairs(patch)do
            nextState[scope]=nextState[scope]or {}
            for key,mode in pairs(items)do nextState[scope][key]=mode end
        end
        self.HudArrangementState=nextState;return true
    end,{delayMs=0,durable=true,reason=reason or 'hud_arrangement'})
    if ok then Changed()end;return ok==true,err
end
local function WithArrangement(patch,reason,action)
    local requested=false;for _,items in pairs(patch)do if next(items)then requested=true;break end end
    if not requested then return action()end
    -- 公共持久入口也可冷调用；先回读真实旧值，再比较和捕获补偿快照。
    local ready,loadErr=F:EnsureHudArrangementLoaded();if not ready then return false,loadErr end
    local changed=false
    for scope,items in pairs(patch)do for key,mode in pairs(items)do
        if StateValue(F.HudArrangementState,scope,key)~=mode then changed=true end
    end end
    if not changed then return action()end
    local before=F:GetHudArrangementProjection()
    local ok,err=F:PersistHudArrangement(patch,reason);if not ok then return false,err end
    local called,result,detail=pcall(action)
    if not called or result~=true then
        local restored,restoreErr=F:PersistHudArrangement(before,reason..':rollback')
        return false,tostring(called and detail or result)..(restored and ''or '；排列回滚失败：'..tostring(restoreErr))
    end
    return result,detail
end
local EnsureStoreLoaded,GetScopeLayoutSettings,PersistHudCalibrationSnapshot=F.EnsureStoreLoaded,F.GetScopeLayoutSettings,F.PersistHudCalibrationSnapshot
local GetDefaultHudCalibrationSnapshot=F.GetDefaultHudCalibrationSnapshot
function F:GetDefaultHudCalibrationSnapshot()
    local snapshot=GetDefaultHudCalibrationSnapshot(self)
    for _,scope in ipairs({'player','target'})do
        snapshot[scope].layoutPresetVersion=tonumber(self.State.settings.layoutPresetVersion)or 3
        snapshot[scope].components.class.nameLinked=false
        for _,key in ipairs(KEYS)do snapshot[scope].components[key].orientation='default'end
    end
    return snapshot
end
function F:EnsureStoreLoaded(...)
    local ok,err=EnsureStoreLoaded(self,...);if ok==true then self:EnsureHudArrangementLoaded()end;return ok,err
end
function F:GetScopeLayoutSettings(scope)
    local profile=GetScopeLayoutSettings(self,scope)
    -- 装备排列代际属于整套布局；校准副本必须与正式 scope projection 使用同一代际。
    profile.layoutPresetVersion=tonumber(self.State.settings.layoutPresetVersion)or 3
    profile.components.class.nameLinked=StateValue(self.HudArrangementState,'identity',scope=='target'and 'target'or 'player')=='paired'
    local values=self.HudArrangementState[scope=='target'and 'target'or 'player']
    for _,key in ipairs(KEYS)do if profile.components[key]and values[key]~='default'then profile.components[key].orientation=values[key]end end
    return profile
end
function F:PersistHudCalibrationSnapshot(snapshot,reason)
    local patch={}
    if not self._keepImportedArrangement then
        for scope,profile in pairs(type(snapshot)=='table'and snapshot or {})do
            if (scope=='player'or scope=='target')and type(profile)=='table'and type(profile.components)=='table'then
                patch[scope]={}
                for _,key in ipairs(KEYS)do
                    local cfg=profile.components[key]
                    -- 缺字段是旧调用方的部分几何更新，必须保留方向；恢复默认有显式default意图。
                    if type(cfg)=='table'and cfg.orientation~=nil then patch[scope][key]=cfg.orientation end
                end
                local class=profile.components.class
                if type(class)=='table'and class.nameLinked~=nil then
                    if type(class.nameLinked)~='boolean'then return false,'职业组合开关无效'end
                    patch.identity=patch.identity or {};patch.identity[scope]=class.nameLinked and 'paired'or 'free'
                end
            end
        end
    end
    local valid,err=self:ValidateHudArrangement(patch);if not valid then return false,err end
    return WithArrangement(valid,reason or 'hud_layout',function()return PersistHudCalibrationSnapshot(self,snapshot,reason)end)
end

-- 纯网格坐标：slots相对包围框；left/top相对组件中心/首行基准。预览与真实渲染共用。
function F.ComputeHudIconGrid(count,size,spacing,perLine,maxLines,vertical,growUp)
    size=math.max(8,math.floor(tonumber(size)or 29));spacing=math.max(0,math.floor(tonumber(spacing)or 2))
    perLine=math.max(1,math.min(16,math.floor(tonumber(perLine)or 8)))
    maxLines=math.max(1,math.min(4,math.floor(tonumber(maxLines)or 2)))
    count=math.max(0,math.min(math.floor(tonumber(count)or 0),perLine*maxLines))
    local major=math.min(count,perLine);local lines=math.ceil(count/perLine)
    -- 显式横排使用固定列宽，缺项和末行不会反复居中，三组图标可共用竖向对齐线。
    local columns,rows=vertical and lines or perLine,vertical and major or lines
    local width=columns>0 and columns*size+(columns-1)*spacing or size
    local height=rows>0 and rows*size+(rows-1)*spacing or size
    local out={count=count,size=size,width=width,height=height,left=-width/2,top=growUp and -(height-size)or 0,slots={}}
    for i=1,count do
        local line=math.floor((i-1)/perLine);local slot=(i-1)%perLine
        local x,y
        if vertical then x=line*(size+spacing);y=slot*(size+spacing)
        else
            x=slot*(size+spacing);y=(growUp and rows-1-line or line)*(size+spacing)
        end
        out.slots[i]={x=x,y=y}
    end
    return out
end

local PRESETS={{id='classic',label='经典横排'},{id='compact',label='紧凑横排（推荐）'},
    {id='balanced',label='均衡分层'},{id='vertical',label='纵向双翼'},{id='matrix',label='矩阵面板'}}
function F:GetHudLayoutPresets()return Copy(PRESETS)end
local function CompactPreset(out)
    local s=math.max(.5,math.min(2,tonumber(out.plateScale)or 1))
    for _,key in ipairs(KEYS)do
        local cfg=out.components[key];cfg.size=26;cfg.fontSize=11;cfg.spacing=4
        cfg.maxPerRow=key=='buffs'and 6 or 4;cfg.maxRows=2;cfg.orientation='horizontal';cfg.x=0;cfg.y=0
    end
    out.info.fontSize=11;out.info.y=-34;out.info.x=math.floor(6*s+.5)
    local class=out.components.class;class.nameLinked=true;class.x=0;class.y=0;class.size=22
    out.components.gearScore.fontSize=11;out.components.gearScore.x=13;out.components.gearScore.y=-34
    out.components.distance.fontSize=11;out.components.distance.x=20;out.components.distance.y=-34
    local cast=out.components.castBar;cast.width=176;cast.size=6;cast.fontSize=11;cast.y=62
    out.components.cooldowns.y=130
    local barWidth=math.floor(out.plate.width*s);local left=-math.floor(barWidth/2);local right=left+barWidth
    local equipment=math.min(24,math.floor((384-out.plate.width)/3))
    local size=math.floor(equipment*s);local gap=math.max(1,math.floor(4*s))
    local desired={mainHand=left-2*(size+gap),offHand=left-size-gap,ranged=right+gap,wings=right+size+2*gap}
    local order=out.layoutPresetVersion>=4 and {'ranged','offHand','mainHand'}or {'offHand','mainHand','ranged'}
    for index,key in ipairs(order)do
        local cfg=out.components[key];cfg.size=equipment;cfg.y=0
        cfg.x=math.ceil((desired[key]-(left-index*(size+gap)))/s)
    end
    local wings=out.components.wings;wings.size=equipment;wings.y=0;wings.x=math.ceil((desired.wings-(right+gap))/s)
    return out,{x=0,y=-164,fontSize=12}
end
local function MatrixPreset(out)
    -- 同一网格统一 Buff/Debuff/CD 与读条外沿；两行装备分列血条左右。
    -- 预设应用时按当前缩放反算局部偏移，仍只输出既有几何字段，不增加存档 Authority。
    local s=math.max(.5,math.min(2,tonumber(out.plateScale)or 1))
    local function Round(v)return math.floor(v+.5)end
    local count=math.max(6,math.min(14,math.ceil((out.plate.width+78)/29)))
    -- 旧代际远程槽从血条左侧第三格移到右列，反算偏移必须保持在既有 ±400 范围。
    count=math.min(count,math.floor((700-out.plate.width)/29))
    local size=math.floor(25*s);local gap=math.floor(4*s)
    local width=count*size+(count-1)*gap;local left=math.floor(-width/2);local right=left+width
    for _,key in ipairs(KEYS)do
        local cfg=out.components[key];cfg.size=25;cfg.fontSize=11;cfg.spacing=4
        cfg.maxPerRow=count;cfg.maxRows=2;cfg.orientation='horizontal';cfg.x=0
    end
    out.components.buffs.y=17;out.components.debuffs.y=21;out.components.cooldowns.y=150
    local cast=out.components.castBar;cast.width=Round(width/s);cast.size=6;cast.y=81;cast.fontSize=11
    local font=math.max(8,math.floor(11*s));local function TextWidth(n)return math.max(24,math.floor(n*font*.62)+8)end
    local textGap=math.max(3,math.floor(font*.25));local gearWidth=TextWidth(6)
    local classRight=math.floor(-gearWidth/2)-textGap
    local iconBase=classRight-math.floor(96*s)-4-math.max(12,font+2)
    local portrait=out.components.class;portrait.size=25;portrait.y=-74;portrait.x=math.ceil((left-iconBase)/s)
    out.info.fontSize=11;out.info.y=-69
    out.info.x=Round((left+size+8*s+right)/2+TextWidth(12)/2-classRight)
    local gear=out.components.gearScore;gear.fontSize=11;gear.y=-40;gear.x=Round((left+gearWidth/2)/s)
    local distance=out.components.distance;distance.fontSize=11;distance.y=-40
    distance.x=Round((right-TextWidth(6)-(math.floor(-gearWidth/2)+gearWidth+textGap))/s)
    local barWidth=math.floor(out.plate.width*s);local barLeft=-math.floor(barWidth/2)
    local equipmentGap=math.max(1,math.floor(4*s))
    local equipmentSize=math.max(8,math.floor(20*s))
    local order=out.layoutPresetVersion>=4 and {'ranged','offHand','mainHand'}or {'offHand','mainHand','ranged'}
    for index,key in ipairs(order)do
        local cfg=out.components[key];cfg.size=20
        local desired=key=='ranged'and right-equipmentSize or left
        cfg.x=math.ceil((desired-(barLeft-index*(equipmentSize+equipmentGap)))/s)
        cfg.y=key=='offHand'and 14 or -15
    end
    local wings=out.components.wings;wings.size=20;wings.y=14
    wings.x=math.ceil((right-equipmentSize-(barLeft+barWidth+equipmentGap))/s)
    return out,{x=0,y=-198,fontSize=12}
end
function F:GetHudLayoutPreset(name,scope,current)
    if scope~='player'and scope~='target'then return nil,'HUD范围无效'end
    if name~='classic'and name~='compact'and name~='balanced'and name~='vertical'and name~='matrix'then return nil,'未知布局预设'end
    current=type(current)=='table'and current or self:GetScopeLayoutSettings(scope)
    local out=Copy(current);local defaults=self:GetDefaultHudCalibrationSnapshot()[scope]
    out.info.x,out.info.y,out.info.fontSize=defaults.info.x,defaults.info.y,defaults.info.fontSize
    for key,cfg in pairs(out.components)do
        local base=defaults.components[key]or {}
        for _,field in ipairs({'x','y','size','fontSize','width','spacing','maxPerRow','maxRows'})do if base[field]~=nil then cfg[field]=base[field]end end
        cfg.orientation=base.orientation
    end
    out.components.class.nameLinked=false
    if name=='compact'then return CompactPreset(out)end
    if name=='matrix'then return MatrixPreset(out)end
    if name=='classic'then
        -- 经典预设保留原横排槽位，但必须给两行 Debuff、施法条与文字各留空间。
        -- 小缩放下文字仍有固定高度，CD 同步下移；不改历史默认或已保存的布局。
        out.components.castBar.y=36;out.components.cooldowns.y=104
        return out,{x=0,y=-94,fontSize=12}
    end
    local vertical=name=='vertical';local icon=vertical and 24 or 26
    for _,key in ipairs(KEYS)do
        local cfg=out.components[key];cfg.size=icon;cfg.fontSize=11;cfg.spacing=vertical and 3 or 4
        cfg.maxPerRow=vertical and 4 or 6;cfg.maxRows=2
        cfg.orientation=vertical and 'vertical'or 'horizontal';cfg.x=0;cfg.y=0
    end
    local lift=vertical and 0 or -32
    out.info.y=lift;out.components.gearScore.y=lift;out.components.distance.y=lift
    out.components.class.y=lift-2;out.components.class.size=24
    out.components.castBar.width=144;out.components.castBar.size=6
    out.components.castBar.y=vertical and 0 or 58
    out.components.cooldowns.y=vertical and 58 or 118
    for _,key in ipairs({'mainHand','offHand','ranged','wings'})do
        out.components[key].size=vertical and 20 or 22
        out.components[key].y=vertical and 92 or 0
    end
    if vertical then
        out.components.buffs.x=math.floor(-126*(out.plateScale or 1));out.components.buffs.y=-97
        out.components.debuffs.x=math.floor(126*(out.plateScale or 1));out.components.debuffs.y=-44
        out.components.cooldowns.size=22
    end
    return out,{x=0,y=vertical and -98 or -130,fontSize=12}
end

-- 分享方向为可选独立行；旧包无该行时保留本机方向，追踪包不含布局。
local ExportAll,SerializeExport,ParseImportText,PrepareTrackingImport,ImportAll=F.ExportAll,F.SerializeExport,F.ParseImportText,F.PrepareTrackingImport,F.ImportAll
local function ValidOrder(value)return type(value)=='number'and value>=1 and value<=5 and value==math.floor(value)end
function F:PrepareTrackingImport(data,mode)
    if type(data)=='table'and data.hudOrder~=nil and not ValidOrder(data.hudOrder)then return nil,'装备排列代际无效'end
    if type(data)=='table'and data.arrangement~=nil then local valid,err=self:ValidateHudArrangement(data.arrangement);if not valid then return nil,err end end
    return PrepareTrackingImport(self,data,mode)
end
function F:ExportAll(mode)
    local data=ExportAll(self,mode)
    if mode~='tracking'then
        local ok,err=self:EnsureHudArrangementLoaded();if not ok then error(err)end
        data.arrangement=self:GetHudArrangementProjection();data.hudOrder=tonumber(self.State.settings.layoutPresetVersion)or 3
    end
    return data
end
function F:SerializeExport(data)
    data=data or self:ExportAll();local text=SerializeExport(self,data)
    if data.exportMode~='tracking'and data.hudOrder~=nil then
        if not ValidOrder(data.hudOrder)then error('装备排列代际无效')end
        text=text..'\nHUDORDER='..data.hudOrder
    end
    if data.exportMode~='tracking'and data.arrangement then
        local valid,err=self:ValidateHudArrangement(data.arrangement);if not valid then error(err)end
        for _,scope in ipairs({'player','target'})do for _,key in ipairs(KEYS)do
            if valid[scope]and valid[scope][key]then text=text..'\nHUDARRANGE='..scope..':'..key..':'..valid[scope][key]end
        end end
        for _,scope in ipairs({'player','target'})do
            if valid.identity and valid.identity[scope]then text=text..'\nHUDIDENTITY='..scope..':'..valid.identity[scope]end
        end
    end
    return text
end
function F:ParseImportText(text)
    if type(text)~='string'or #text>65535 then return ParseImportText(self,text)end
    local pass,arrangement,errors,seen,order,orderSeen={},nil,{},{},nil,false
    for raw in (text..'\n'):gmatch('([^\n]*)\n')do
        local line=raw:gsub('\r$',''):match('^%s*(.-)%s*$')
        if line:upper():match('^HUDIDENTITY%s*=')then
            local scope,mode=line:match('^[^=]+=([%a]+):([%a]+)$')
            if not scope or (scope~='player'and scope~='target')or not IDENTITIES[mode]or seen['identity:'..scope]then errors[#errors+1]='职业组合行无效或重复'
            else
                arrangement=arrangement or {};arrangement.identity=arrangement.identity or {};arrangement.identity[scope]=mode
                seen['identity:'..scope]=true
            end
        elseif line:upper():match('^HUDORDER%s*=')then
            local value=tonumber(line:match('^[^=]+=(%d+)$'))
            if orderSeen or not ValidOrder(value)then errors[#errors+1]='装备排列代际无效或重复'else order=value end
            orderSeen=true
        elseif line:upper():match('^HUDARRANGE%s*=')then
            local scope,key,mode=line:match('^[^=]+=([%a]+):([%a]+):([%a]+)$')
            if not scope or (scope~='player'and scope~='target')or not KNOWN[key]or not MODES[mode]or seen[scope..':'..key]then errors[#errors+1]='排列行无效或重复'
            else arrangement=arrangement or {};arrangement[scope]=arrangement[scope]or {};arrangement[scope][key]=mode;seen[scope..':'..key]=true end
        else pass[#pass+1]=raw end
    end
    local parsed=ParseImportText(self,table.concat(pass,'\n'))
    for _,err in ipairs(errors)do parsed.errors[#parsed.errors+1]=err end
    parsed.data.arrangement=arrangement;parsed.data.hudOrder=order;parsed.data._parseErrors=#parsed.errors;return parsed
end
local function RebaseEquipmentImport(self,data)
    local source=data.hudOrder;local target=tonumber(self.State.settings.layoutPresetVersion)or 3
    if not source or (source>=4)==(target>=4)then return data end
    data=Copy(data)
    local sourceOrder=source>=4 and {ranged=1,offHand=2,mainHand=3}or {offHand=1,mainHand=2,ranged=3}
    local targetOrder=target>=4 and {ranged=1,offHand=2,mainHand=3}or {offHand=1,mainHand=2,ranged=3}
    local function Rebase(components,profile,fallback)
        if type(components)~='table'then return true end
        local scale=tonumber(profile and profile.plateScale)or fallback.plateScale or 1
        scale=math.max(.5,math.min(2,scale))
        for key,index in pairs(sourceOrder)do
            local cfg=components[key]
            if type(cfg)=='table'and cfg.x~=nil then
                local x=tonumber(cfg.x);if not x or x~=x or math.abs(x)>400 then return false,'装备偏移无效'end
                local size=math.max(8,math.floor((tonumber(cfg.size)or fallback.components[key].size)*scale))
                local pixels=math.floor(x*scale)+(targetOrder[key]-index)*(size+math.max(1,math.floor(4*scale)))
                local rebased=math.ceil(pixels/scale)
                if math.abs(rebased)>400 then return false,'装备跨代际偏移超出范围'end
                cfg.x=rebased
            end
        end
        return true
    end
    for _,scope in ipairs({'player','target'})do
        local fallback=self:GetScopeLayoutSettings(scope);local hud=type(data.hud)=='table'and data.hud[scope]
        local ok,err=Rebase(type(hud)=='table'and hud.components or nil,hud,fallback);if not ok then return nil,err end
        if scope=='player'then ok,err=Rebase(data.components,hud,fallback);if not ok then return nil,err end end
    end
    data.hudOrder=target;return data
end
function F:ImportAll(data,mode)
    if type(data)~='table'then return ImportAll(self,data,mode)end
    local patch,err=self:ValidateHudArrangement(data.arrangement or {});if not patch then return false,err end
    local prepared;prepared,err=self:PrepareTrackingImport(data,mode);if not prepared then return false,err end
    if data.hudOrder~=nil then
        local ready;ready,err=self:EnsureStoreLoaded();if not ready then return false,err end
        data,err=RebaseEquipmentImport(self,data);if not data then return false,err end
    end
    return WithArrangement(patch,'import_arrangement',function()
        local previous=self._keepImportedArrangement;self._keepImportedArrangement=true
        local called,result,detail=pcall(ImportAll,self,data,mode);self._keepImportedArrangement=previous
        if not called then return false,result end;return result,detail
    end)
end
local GetManagementHealth=F.GetManagementHealth
if GetManagementHealth then
    function F:GetManagementHealth()
        local health=GetManagementHealth(self)
        health.hudArrangement={storeId=ID,error=self.HudArrangementError,loaded=P:GetStore(ID).loaded==true}
        return health
    end
end
