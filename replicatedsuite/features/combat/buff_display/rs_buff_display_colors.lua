------------------------------------------------------------------------
-- Replicated Suite · 状态显示自定义配色
-- 作者：Replicated
-- QQ群：1104129461
-- 颜色有独立小存档；历史布局/追踪canonical不变。任意24位RGB，方案只用于显式快捷填充。
------------------------------------------------------------------------
if not ReplicatedSuite or ReplicatedSuite.BootError then return end
local S=ReplicatedSuite
local F,P=S.Features and S.Features.BuffDisplay,S.Persistence
if not F or not P then return end
local ID='v3.buff_display.colors'
local KEYS={'alias','classText','gearScore','distance','castName','buffTime','buffStacks','debuffTime','debuffStacks','cooldownTime'}
local LABELS={alias='自定义名字',classText='职业名称',gearScore='装备分数',distance='距离',castName='施法名称',
    buffTime='Buff剩余时间',buffStacks='Buff层数',debuffTime='Debuff剩余时间',debuffStacks='Debuff层数',cooldownTime='技能CD时间'}
local KNOWN={};for _,key in ipairs(KEYS)do KNOWN[key]=true end
local function Copy(v)if type(v)~='table'then return v end;local out={};for k,x in pairs(v)do out[k]=Copy(x)end;return out end
local function Hex(color)
    if type(color)~='table' or #color~=3 then return nil,'颜色需要完整的RGB三个通道' end
    for index=1,3 do
        local value=color[index]
        if type(value)~='number' or value~=value or value<0 or value>1 then return nil,'RGB通道必须是0到1的有限数值'end
    end
    for key,value in pairs(color)do
        if type(key)~='number' or key<1 or key>3 or key~=math.floor(key)
            or type(value)~='number' or value~=value or value<0 or value>1 then return nil,'RGB通道必须是0到1的有限数值' end
    end
    return string.format('%02X%02X%02X',math.floor(color[1]*255+.5),math.floor(color[2]*255+.5),math.floor(color[3]*255+.5))
end
local function RGB(hex)
    hex=type(hex)=='string' and hex or 'FFFFFF'
    return (tonumber(hex:sub(1,2),16) or 255)/255,(tonumber(hex:sub(3,4),16) or 255)/255,(tonumber(hex:sub(5,6),16) or 255)/255
end
local function Normalize(v)
    v=type(v)=='table' and v or {};local out={player={},target={},recent={}}
    for _,scope in ipairs({'player','target'})do
        for _,key in ipairs(KEYS)do
            local value=type(v[scope])=='table' and v[scope][key]
            out[scope][key]=type(value)=='string' and value:match('^%x%x%x%x%x%x$') and value:upper() or 'FFFFFF'
        end
    end
    local seen={}
    for _,hex in ipairs(type(v.recent)=='table' and v.recent or {})do
        if type(hex)=='string' and hex:match('^%x%x%x%x%x%x$') then
            hex=hex:upper();if not seen[hex] and #out.recent<8 then out.recent[#out.recent+1]=hex;seen[hex]=true end
        end
    end
    return out
end
F.HudColorsState=Normalize(nil);F.HudColorsStoreId=ID
local function Changed()
    if type(F.InvalidateSettingsCache)=='function'then F:InvalidateSettingsCache()end
    if S.Events and S.Events.Publish then
        S.Events:Publish('v3.buff_display.settings','colors')
        S.Events:Publish('v3.buff_display.plates.updated','colors')
    end
end
if not P:GetStore(ID) then
    local store,err=P:RegisterV3Store({id=ID,owner=ID,scope=P.Scope.Account,lifetime=P.Lifetime.Permanent,
        schemaVersion=1,transportVersion=3,key=P.V3KeyPrefix..'buff_display_colors',
        budget={maxDepth=4,maxNodes=160,maxStringBytes=2048,maxEntriesPerTable=32},
        default=function()return Normalize(nil)end,get=function()return Normalize(F.HudColorsState)end,
        apply=function(value)F.HudColorsState=Normalize(value);return true end})
    if not store then error(err)end
end
function F:EnsureHudColorsLoaded()
    local store=P:GetStore(ID)
    if store.writeFenced then self.HudColorsError=tostring(store.writeFenceReason or '配色存档已保护');return false,self.HudColorsError end
    if store.loaded then return true end
    local ok,_,err=P:LoadStore(ID)
    if ok~=true and ok~='empty' then self.HudColorsError=tostring(err or ok);return false,self.HudColorsError end
    if ok=='empty' then self.HudColorsState=Normalize(nil)end
    self.HudColorsError=nil;return true
end
function F:GetHudColor(scope,key)
    local palette=self.HudColorsState[scope]
    return RGB(palette and palette[key]) -- 纯读内存，无Native查询、无数组分配。
end
function F:GetHudColorsProjection()
    local out={player={},target={}}
    for _,scope in ipairs({'player','target'})do for _,key in ipairs(KEYS)do out[scope][key]={self:GetHudColor(scope,key)}end end
    return out
end
function F:GetRecentHudColors()
    local out={};for _,hex in ipairs(self.HudColorsState.recent)do out[#out+1]={RGB(hex)}end;return out
end
function F:GetHudColorDefinitions()
    local out={};for _,key in ipairs(KEYS)do out[#out+1]={key=key,label=LABELS[key],targetOnly=key=='alias'}end;return out
end
function F:ValidateHudColors(value)
    if type(value)~='table'then return nil,'配色配置必须是表' end
    local normalized={}
    for scope,palette in pairs(value)do
        if scope~='player' and scope~='target' then return nil,'未知配色范围' end
        if type(palette)~='table'then return nil,'配色范围必须是表' end
        normalized[scope]={}
        for key,color in pairs(palette)do
            if not KNOWN[key]then return nil,'未知文字配色项目：'..tostring(key)end
            local hex,err=Hex(color);if not hex then return nil,err end
            normalized[scope][key]=hex
        end
    end
    return normalized
end
function F:PersistHudColors(value,reason,remember)
    local patch,err=self:ValidateHudColors(value);if not patch then return false,err end
    if not remember then
        local count,only=0,nil
        for _,palette in pairs(patch)do for _,hex in pairs(palette)do count=count+1;only=hex end end
        if count==1 then remember=only end
    end
    local ready;ready,err=self:EnsureHudColorsLoaded();if not ready then return false,err end
    local ok;ok,err=P:MutateStore(ID,function()
        local nextState=Normalize(self.HudColorsState)
        for scope,palette in pairs(patch)do for key,hex in pairs(palette)do nextState[scope][key]=hex end end
        if remember then table.insert(nextState.recent,1,remember)end
        self.HudColorsState=Normalize(nextState);return true
    end,{delayMs=0,durable=true,reason=reason or 'hud_colors'})
    if ok then Changed()end
    return ok==true,err
end
function F:SetHudColor(scope,key,color)
    if (scope~='player' and scope~='target')or not KNOWN[key]then return false,'未知配色范围或文字项目'end
    local hex,err=Hex(color);if not hex then return false,err end
    return self:PersistHudColors({[scope]={[key]=color}},'hud_color:'..scope..':'..key,hex)
end
function F:GetHudColorPreset(name)
    local colors={}
    for _,key in ipairs(KEYS)do colors[key]={1,1,1}end
    if name=='recommended' then
        colors.alias={1,0.83,0.42};colors.classText={0.52,0.77,1};colors.gearScore={0.83,0.68,1};colors.distance={0.44,0.88,0.81}
        colors.castName={1,0.83,0.42}
        colors.buffTime={0.55,0.90,0.65};colors.buffStacks={1,0.83,0.42}
        colors.debuffTime={1,0.48,0.42};colors.debuffStacks={1,0.70,0.42};colors.cooldownTime={0.55,0.80,1}
    elseif name=='contrast' then
        colors.alias={1,1,0};colors.classText={0,1,1};colors.gearScore={1,0.7,1};colors.distance={0.4,1,0.4}
        colors.castName={1,0.4,1}
        colors.buffTime={0,1,1};colors.buffStacks={1,1,0}
        colors.debuffTime={1,0.3,0.4};colors.debuffStacks={1,0.65,0};colors.cooldownTime={0.55,1,0.1}
    end
    return colors
end
-- 业务正常启动时一次性加载小配色Store；坏配色降级为默认显示，不阻断状态追踪。
local EnsureStoreLoaded=F.EnsureStoreLoaded
function F:EnsureStoreLoaded(...)
    local ok,err=EnsureStoreLoaded(self,...)
    if ok==true then self:EnsureHudColorsLoaded()end
    return ok,err
end
F.Commands=F.Commands or {}
function F.Commands:SetHudColor(scope,key,color)return F:SetHudColor(scope,key,color)end
function F.Commands:PersistHudColors(value,reason)return F:PersistHudColors(value,reason)end

-- 颜色行是完整分享的可选扩展。旧包不含颜色时保留本机配色；非法/重复行整体拒绝。
local ExportAll,SerializeExport,ParseImportText,ImportAll=F.ExportAll,F.SerializeExport,F.ParseImportText,F.ImportAll
local PrepareTrackingImport=F.PrepareTrackingImport
function F:PrepareTrackingImport(data,mode)
    if type(data)=='table'and data.colors~=nil then
        local valid,err=self:ValidateHudColors(data.colors);if not valid then return nil,err end
    end
    return PrepareTrackingImport(self,data,mode)
end
function F:ExportAll(mode)
    local data=ExportAll(self,mode)
    if mode~='tracking' then
        local ok,err=self:EnsureHudColorsLoaded();if not ok then error('配色无法完整导出：'..tostring(err))end
        data.colors=self:GetHudColorsProjection()
    end
    return data
end
function F:SerializeExport(data)
    data=data or self:ExportAll();local text=SerializeExport(self,data)
    if data.exportMode~='tracking' and data.colors then
        local patch,err=self:ValidateHudColors(data.colors);if not patch then error(err)end
        local lines={text}
        for _,scope in ipairs({'player','target'})do for _,key in ipairs(KEYS)do
            if patch[scope] and patch[scope][key]then lines[#lines+1]='HUDCOLOR='..scope..':'..key..':'..patch[scope][key]end
        end end
        text=table.concat(lines,'\n')
    end
    return text
end
function F:ParseImportText(text)
    if type(text)~='string'or #text>65535 then return ParseImportText(self,text)end
    local pass,colors,errors,seen={},nil,{},{}
    for raw in (text..'\n'):gmatch('([^\n]*)\n')do
        local line=raw:gsub('\r$',''):match('^%s*(.-)%s*$')
        if line:upper():match('^HUDCOLOR%s*=') then
            local scope,key,hex=line:match('^[^=]+=([%a]+):([%w]+):(%x%x%x%x%x%x)$')
            if not scope or (scope~='player'and scope~='target')or not KNOWN[key]or seen[scope..':'..key]then errors[#errors+1]='文字配色行无效或重复'
            else colors=colors or {};colors[scope]=colors[scope]or {};colors[scope][key]={RGB(hex)};seen[scope..':'..key]=true end
        else pass[#pass+1]=raw end
    end
    local parsed=ParseImportText(self,table.concat(pass,'\n'))
    for _,err in ipairs(errors)do parsed.errors[#parsed.errors+1]=err end
    parsed.data.colors=colors;parsed.data._parseErrors=#parsed.errors
    return parsed
end
function F:ImportAll(data,mode)
    if type(data)~='table'or data.colors==nil then return ImportAll(self,data,mode)end
    local patch,err=self:ValidateHudColors(data.colors);if not patch then return false,err end
    local prepared;prepared,err=self:PrepareTrackingImport(data,mode);if not prepared then return false,err end
    local ready;ready,err=self:EnsureHudColorsLoaded();if not ready then return false,err end
    local before=self:GetHudColorsProjection()
    local ok;ok,err=self:PersistHudColors(data.colors,'import_colors');if not ok then return false,err end
    local called,result,reason=pcall(ImportAll,self,data,mode)
    if not called or result~=true then
        local rollback,rollbackErr=self:PersistHudColors(before,'import_colors_rollback')
        return false,tostring(called and reason or result)..(rollback and ''or '；配色回滚失败：'..tostring(rollbackErr))
    end
    return result,reason
end
local ManagementHealth=F.GetManagementHealth
if type(ManagementHealth)=='function'then
    function F:GetManagementHealth()
        local health=ManagementHealth(self)
        health.hudColors={storeId=ID,error=self.HudColorsError,loaded=P:GetStore(ID).loaded==true,recent=#self.HudColorsState.recent}
        return health
    end
end
