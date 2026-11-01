-- Daily confirmed player names are kept separately from authenticated totals.
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
local H=S.Features and S.Features.CombatAnalytics and S.Features.CombatAnalytics.PersonalHistory
local F=S.Features and S.Features.CombatAnalytics
local P=S.Persistence
if not H or not P then return end
local C=H.TransferHelpers
local ID='v3.combat_history_kill_targets'
H.KillTargetsStoreId=ID
local MAX_DAYS,MAX_NAMES,MAX_ENTRIES=2048,128,4000
local state={days={}}
local revision=0
local entries=0
local function Normalize(value)
    local out={days={}}
    local days=type(value)=='table' and value.days or nil
    local dates={}
    for date,row in pairs(type(days)=='table' and days or {}) do
        if (C.validDate(date) or date=='unknown') and type(row)=='table' then dates[#dates+1]=date end
    end
    table.sort(dates)
    for i,date in ipairs(dates) do
        if i>MAX_DAYS then break end
        local source=days[date];local names={};local keys={}
        for name,n in pairs(type(source.names)=='table' and source.names or {}) do
            if type(name)=='string' and #name>0 and #name<=128 and C.counter(n)>0 then keys[#keys+1]=name end
        end
        table.sort(keys)
        for index,name in ipairs(keys) do if index<=MAX_NAMES then names[name]=C.counter(source.names[name]) end end
        out.days[date]={names=names,omitted=C.counter(source.omitted)}
    end
    return out
end
local store,registrationError=P:RegisterV3Store({id=ID,owner=ID,scope=P.Scope.Character,lifetime=P.Lifetime.Permanent,
    schemaVersion=1,legacySchemaVersion=0,key=(P.V3KeyPrefix or 'rs.v3.')..'combat_history_kill_targets',
    budget={maxDepth=5,maxNodes=300000,maxStringBytes=4000000,maxEntriesPerTable=2048},
    transportVersion=7,nativeByteBudget=15000,nativePaged=true,
    default=function()return Normalize(nil)end,get=function()return Normalize(state)end,
    apply=function(value)
        state=Normalize(value);entries=0
        for _,row in pairs(state.days)do for _ in pairs(row.names)do entries=entries+1 end end
        revision=revision+1
    end})
local function Load()
    if not store then return false,registrationError or '击杀名单存档不可用' end
    if type(P.PrepareRead)=='function' then return P:PrepareRead(ID) end
    if P:IsStoreLoaded(ID) then return true end
    local ok,_,err=P:LoadStore(ID)
    if ok~=true and ok~='empty' then return false,err or tostring(ok) end
    return true
end
function H:RecordKillTarget(date,name)
    if not (C.validDate(date) or date=='unknown') or type(name)~='string' or #name==0 or #name>128 then return false end
    local ok,err=Load();if not ok then self.killTargetsError=err;return false,err end
    local row=state.days[date]
    if not row then
        local n=0;for _ in pairs(state.days)do n=n+1 end
        if n>=MAX_DAYS then self.killTargetsError='击杀名单日期容量已满';return false,self.killTargetsError end
    end
    ok,err=P:MarkDirty(ID,5000,'personal_kill_target')
    if ok~=true then self.killTargetsError=err;return false,err end
    if not row then row={names={},omitted=0};state.days[date]=row end
    if row.names[name] then row.names[name]=row.names[name]+1
    else
        local n=0;for _ in pairs(row.names)do n=n+1 end
        if n>=MAX_NAMES or entries>=MAX_ENTRIES then row.omitted=row.omitted+1 else row.names[name]=1;entries=entries+1 end
    end
    revision=revision+1;self.killTargetsError=nil
    return true
end
function H:GetKillTargets(date)
    local ok,err=Load();if not ok then return nil,err end
    local day=state.days[date];local rows={}
    for name,count in pairs(day and day.names or {})do rows[#rows+1]={name=name,kills=count} end
    table.sort(rows,function(a,b)if a.kills~=b.kills then return a.kills>b.kills end return a.name<b.name end)
    return {rows=rows,omitted=day and day.omitted or 0,revision=revision,error=self.killTargetsError or (store and store.lastError)}
end
function F:GetPersonalHistoryKillTargets(date) return H:GetKillTargets(date) end
