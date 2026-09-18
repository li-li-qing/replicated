------------------------------------------------------------------------
-- Replicated Suite V3 - Buff Metadata Service
--
-- Shared, lazy buff-id -> (name/icon) resolver. Runtime combat callbacks must
-- not spam it: lookups are cached (success AND miss) and gated by the
-- capability registry, so one unknown id costs at most a few native reads per
-- session. This is the single Authority for effect metadata; consumers
-- (AuraObservationV3, future plates/healer rebuilds) must not keep private
-- copies of the same chain.
--
-- Native source: X2Ability:GetBuffTooltip(buffType, itemLevel) — the RU-enabled
-- probe chain proven by the mature Plates module. Some RU builds return tooltip
-- TEXT (a string) instead of a table; the first line of a buff tooltip is the
-- buff name, so that shape is accepted too.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}

local M = {
    Id = "v3.buff_metadata",
    version = 1,
    cache = {},
    order = {},
    orderHead = 1,
    serial = 0,
    cacheCount = 0,
    cacheMax = 512,
    hits = 0,
    misses = 0,
    nativeLookups = 0,
    nativeFailures = 0,
    evictions = 0,
    iconResolved = 0,
    iconMissing = 0,
    samples = {},
}
M.presentationBoundary = "service_only"
S.Services.BuffMetadataV3 = M

local function NormalizeId(value)
    local id = tonumber(value)
    if id == nil or id <= 0 then return nil end
    return math.floor(id + 0.5)
end
-- 维护（library-eventbus-2）：只观察既有能力门，检查可用性不调用tooltip。
-- 模块加载初期API缺失不同于“该ID确实无图标”；后者可负缓存，前者必须在能力恢复后可重试。
-- 不在行绑定中查Native，也不增加定时重试；再次绑定/显式GetInfo才进入原有受限队列。
local function CanQuery()
    local api=S.Api
    if type(api)~="table" or type(api.CallCapability)~="function" or X2Ability==nil then
        return false,"capability_host_unavailable"
    end
    if type(api.IsCapabilityAllowed)=="function" then return api:IsCapabilityAllowed("X2Ability:GetBuffTooltip") end
    return true
end

-- 维护：图标仍只接受服务已支持的Native资源字段，禁止用技能图标冒充Buff图标。
-- 额外返回/未知字段只记录类型以便实机核对，不在没有依据时猜嵌套结构或构造dds路径。
-- 最近8个ID、每条至多12个顶层字段，诊断只保留基本值，不持有原tooltip表或正文。
local function ReturnShape(value)
    if type(value)~="table" then return type(value) end
    local keys={};local count=0
    for k,v in pairs(value) do
        count=count+1
        if count>12 then keys[#keys+1]="...";break end
        local key=tostring(k);if #key>32 then key="<long-key>" end
        keys[#keys+1]=key..":"..type(v)
    end
    table.sort(keys);return "table{"..table.concat(keys,",").."}"
end
function M:_RecordProbe(sample,hasIcon)
    sample=sample or {}
    sample.iconAvailable=hasIcon==true
    if hasIcon then self.iconResolved=self.iconResolved+1
    elseif sample.reason~="capability_unavailable" then self.iconMissing=self.iconMissing+1 end
    if #self.samples>=8 then table.remove(self.samples,1) end
    self.samples[#self.samples+1]=sample
end

local function FirstIconPath(info)
    if type(info) ~= "table" then return nil end
    for _,key in ipairs({"path","iconPath","icon_path","icon","skillIcon","skill_icon","texture"}) do
        local path=info[key];if type(path)=="string" and path~="" then return path end
    end
    return nil
end
local function NameFromInfo(info)
    if type(info) ~= "table" then return nil end
    for _, key in ipairs({ "name", "buffName" }) do
        local value = info[key]
        if type(value) == "string" and value ~= "" then return value end
    end
    return nil
end

-- 维护（目录按需图标）：旧负缓存不进淘汰队列会无限增长；稀疏表取#也不可靠。
-- 用明确首尾指针的512槽环形FIFO，正/负结果共享上限，替换已有值不重复计数。
-- 每次查找/新增/淘汰O(1)，不会在Aura调用路径搬移512个条目或遍历静态目录。
M.orderTail=1
function M:_EvictIfNeeded()
    if self.cacheCount>=self.cacheMax then
        local key=self.order[self.orderHead];self.order[self.orderHead]=nil
        self.orderHead=(self.orderHead%self.cacheMax)+1
        if key and self.cache[key]~=nil then self.cache[key]=nil;self.cacheCount=self.cacheCount-1;self.evictions=self.evictions+1 end
    end
end
function M:_Store(id,row)
    local key=tostring(id)
    if self.cache[key]==nil then
        self:_EvictIfNeeded();self.order[self.orderTail]=key
        self.orderTail=(self.orderTail%self.cacheMax)+1;self.cacheCount=self.cacheCount+1
    end
    self.serial=self.serial+1
    if type(row)=="table" then row.__cacheSerial=self.serial end
    self.cache[key]=row;return row
end
function M:GetRevision() return self.serial end
function M:HasCached(id,requireIcon)
    local row=self.cache[tostring(id)]
    if type(row)=="table" and row.__unavailable==true and (not row.iconPath or row.iconPath=="") then
        return CanQuery()~=true
    end
    return row~=nil and (requireIcon~=true or row==false or row.__iconProbeComplete==true or (type(row.iconPath)=="string" and row.iconPath~=""))
end

-- Peek: cached result only. Never issues native reads, never caches a miss.
-- Scan paths use this to decide whether a (more expensive) tooltip row fetch is
-- still worthwhile for an id.
function M:GetCached(id)
    local cached = self.cache[tostring(id)]
    if cached == nil then return nil end
    if cached == false then return nil end
    self.hits = self.hits + 1
    return { name = cached.name, iconPath = cached.iconPath }
end

-- Remember a POSITIVE resolution learned outside this service (e.g. a name
-- read straight off a UnitBuffTooltip row). Upgrades an earlier miss (false)
-- but never overwrites a different positive entry.
function M:Remember(id, name, iconPath)
    local numeric = NormalizeId(id)
    if numeric == nil then return false end
    local key = tostring(numeric)
    local existing = self.cache[key]
    local cleanName=type(name)=="string" and name or ""
    local cleanIcon=type(iconPath)=="string" and iconPath or ""
    if type(existing)=="table" then
        -- Aura真实图标可补全先前只有名称的tooltip结果；不覆盖已知的另一张正向图标。
        local changed=false
        if (not existing.iconPath or existing.iconPath=="") and cleanIcon~="" then existing.iconPath=cleanIcon;changed=true end
        if (not existing.name or existing.name=="" or existing.name==key) and cleanName~="" and cleanName~=key then existing.name=cleanName;changed=true end
        if changed then
            if existing.iconPath and existing.iconPath~="" then existing.__unavailable=nil end
            self.serial=self.serial+1
        end
        return changed
    end
    if (cleanName=="" or cleanName==key) and cleanIcon=="" then return false end
    self:_Store(key,{name=cleanName,iconPath=cleanIcon});return true
end

function M:GetInfo(id, requireIcon)
    local numeric = NormalizeId(id)
    if numeric == nil then return nil end
    local key = tostring(numeric)
    local cached = self.cache[key]
    if cached ~= nil and self:HasCached(numeric,requireIcon) then
        self.hits = self.hits + 1
        if cached == false then return nil end
        return { name = cached.name, iconPath = cached.iconPath }
    end
    self.misses = self.misses + 1
    -- 用户浏览图标时允许对“已知名称/无图标”做一次最多三个level的补全；
    -- 失败也加probe标记，后续行重绑不重复读Native。保留已有名称，不把name-only当不存在。
    local best=type(cached)=="table" and {name=cached.name or "",iconPath=cached.iconPath or ""} or nil

    local api = S.Api
    local gateOpen,gateReason=CanQuery()
    if gateOpen ~= true then
        local pending=best or {name="",iconPath=""};pending.__unavailable=true;pending.__iconProbeComplete=false
        self:_Store(key,pending)
        self.nativeFailures = self.nativeFailures + 1
        self:_RecordProbe({id=numeric,reason="capability_unavailable",detail=tostring(gateReason or "blocked")},false)
        return best and {name=best.name,iconPath=best.iconPath} or nil
    end
    local sample

    -- 沿用项目允许的0/1/55 tooltip链。查名称可首个成功返回，显式查图标则继续到图标或预算结束。
    for _,itemLevel in ipairs({0,1,55}) do
        self.nativeLookups=self.nativeLookups+1
        local ok,info,callErr,extra,third=api:CallCapability("X2Ability:GetBuffTooltip",X2Ability,"GetBuffTooltip",numeric,itemLevel)
        -- Capability第3返回是错误，不是Native第二返回。仅记录形态，绝不将错误文本当图标路径。
        local detail=tostring(callErr or "");if #detail>192 then detail="<long-native-error>" end
        sample={id=numeric,level=itemLevel,ok=ok==true,first=ReturnShape(info),second=ReturnShape(extra),third=ReturnShape(third),error=detail}
        if ok~=true then self.nativeFailures=self.nativeFailures+1 end
        local name,iconPath
        if ok and type(info)=="string" and info~="" then
            local first=string.match(info,"^([^\r\n]+)") or "";first=string.match(first,"^%s*(.-)%s*$") or ""
            if first~="" and not string.match(first,"^%d+$") then name=first end
        elseif ok and type(info)=="table" then name=NameFromInfo(info);iconPath=FirstIconPath(info) end
        -- nil ~= "" 为true，必须显式判string，不能把空表缓存成成功后阻止图标探测。
        if iconPath~=nil or (type(name)=="string" and name~="") then
            best=best or {name="",iconPath=""}
            if best.name=="" and name then best.name=name end
            if iconPath then best.iconPath=iconPath end
            if requireIcon~=true or best.iconPath~="" then
                best.__iconProbeComplete=best.iconPath~="";self:_Store(key,best)
                sample.reason=best.iconPath~="" and "resolved" or "name_only";self:_RecordProbe(sample,best.iconPath~="")
                return {name=best.name,iconPath=best.iconPath}
            end
        end
    end
    sample=sample or {id=numeric};sample.reason="icon_not_returned";self:_RecordProbe(sample,false)
    if best then best.__iconProbeComplete=true;self:_Store(key,best);return {name=best.name,iconPath=best.iconPath} end
    self:_Store(key,false);return nil
end

function M:GetHealth()
    local samples={}
    for i,row in ipairs(self.samples) do samples[i]={};for k,v in pairs(row) do samples[i][k]=v end end
    return {
        ok = true,
        cached = self.cacheCount,
        cacheMax = self.cacheMax,
        hits = self.hits,
        misses = self.misses,
        nativeLookups = self.nativeLookups,
        nativeFailures = self.nativeFailures,
        evictions = self.evictions,
        iconResolved = self.iconResolved,
        iconMissing = self.iconMissing,
        samples = samples,
        patch = "status-library-eventbus-2",
    }
end

return
