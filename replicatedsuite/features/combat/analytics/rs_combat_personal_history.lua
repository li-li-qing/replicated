------------------------------------------------------------------------
-- 个人长期统计。每日摘要 + 全期累计；实时排行的 reset 永不删除此 Store。
-- 仅从共享事实和击杀指标的明确归属接收增量，不监听第二套原生事件。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local F = S.Features and S.Features.CombatAnalytics
local A = S.Services and S.Services.CombatAnalyticsV3
local P = S.Persistence
if not F or not A or not P then return end
local H = { StoreId="v3.combat_personal_history", revision=0, lastDirtyAt=-10000, clockAt=-10000, failures=0 }
F.PersonalHistory = H
local LEGACY_KEYS = {"kills","deaths","assists","damage","taken","healing","inferredKills","unattributedParticipations","unknownTargetKills"}
local KEYS = {"kills","npcKills","deaths","assists","damage","taken","healing","inferredKills","inferredNpcKills","unattributedParticipations","unknownTargetKills"}
-- 旧推断计数仍参与原指纹规范化/归档，不能删除旧字段或改写原总数。
-- 用户已选择只计明确归属，新记录不再累计推断；只读投影从旧合计中扣除已标记的推断。
-- 2026-10-07：NPC击杀已删除；schema2字段仅用于旧档完整性验证，不进入记录或公开投影。
local LIVE_KEYS = {"kills","deaths","damage","taken","healing"}
local MAX_DAYS = 2048
local function Counter(v) v=tonumber(v);if not v or v~=v or v==math.huge or v<0 then return 0 end;return math.floor(v) end
local function Counts(v,keys)
    local out={};for _,key in ipairs(keys or KEYS) do out[key]=Counter(type(v)=="table" and v[key]) end;return out
end
local function ConfirmedCounts(v)
    local out=Counts(v,LEGACY_KEYS)
    out.recordedKills=out.kills
    out.kills=math.max(0,out.kills-out.inferredKills)
    return out
end
local function Add(to, delta, keys) for _,key in ipairs(keys or KEYS) do to[key]=(tonumber(to[key]) or 0)+Counter(delta[key]) end end
local function ValidDate(value)
    value=tostring(value or "")
    local y,m,d=value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    y,m,d=tonumber(y),tonumber(m),tonumber(d)
    if not y or y<2000 or y>9999 or not m or m<1 or m>12 or not d or d<1 then return false end
    local days={31,28,31,30,31,30,31,31,30,31,30,31}
    if y%4==0 and (y%100~=0 or y%400==0) then days[2]=29 end
    return d<=days[m]
end
local function Stamp(v) return type(v)=="string" and #v<=32 and v or nil end
local function Normalize(v,keys)
    v=type(v)=="table" and v or {}
    local out={totals=Counts(v.totals,keys),days={},firstAt=Stamp(v.firstAt),lastAt=Stamp(v.lastAt),archive=Counts(v.archive,keys),archiveFrom=Stamp(v.archiveFrom),archiveTo=Stamp(v.archiveTo)}
    local dates={}
    for date,row in pairs(type(v.days)=="table" and v.days or {}) do
        if (ValidDate(date) or date=="unknown") and type(row)=="table" then dates[#dates+1]=date end
    end
    table.sort(dates)
    for i,date in ipairs(dates) do
        local row=Counts(v.days[date],keys);row.firstAt=Stamp(v.days[date].firstAt);row.lastAt=Stamp(v.days[date].lastAt)
        if i<=#dates-MAX_DAYS then
            Add(out.archive,row,keys);out.archiveFrom=out.archiveFrom or date;out.archiveTo=date
        else out.days[date]=row end
    end
    return out
end
H.state=Normalize(nil)
-- schema1 没有 NPC 计数。只重建已知旧字段的原规范形式，原指纹精确匹配后由 Core 迁移。
-- 不改写实际文件、不绕过写保护；未知损坏仍由 Persistence 拒绝。
local function RebuildSchema1Canonical(value,_,_,raw)
    local meta=type(raw)=="table" and raw.__rsmeta or nil
    if type(meta)~="table" or meta.store~=H.StoreId or meta.owner~=H.StoreId or tonumber(meta.schema)~=1 then return nil end
    return Normalize(value,LEGACY_KEYS),Normalize(value)
end
local store,registerErr=P:RegisterV3Store({
    id=H.StoreId,owner=H.StoreId,scope=P.Scope.Character,lifetime=P.Lifetime.Permanent,
    schemaVersion=2,legacySchemaVersion=0,key=(P.V3KeyPrefix or "rs.v3.").."combat_personal_history",
    budget={maxDepth=5,maxNodes=38000,maxStringBytes=200000,maxEntriesPerTable=2048},
    rebuildCanonicalForIntegrity=RebuildSchema1Canonical,
    default=function() return Normalize(nil) end,get=function() return Normalize(H.state) end,
    apply=function(value) H.state=Normalize(value);H.lastDirtyAt=-10000;H.loaded=false;H.revision=H.revision+1 end,
    migrate=function(value) return Normalize(value) end,
})
H.registerError=registerErr
function H:EnsureLoaded(verifyBinding)
    local identity=S.Services and S.Services.UnitIdentityV3
    local player=identity and identity.player
    local tag=type(player)=="table" and tostring(player.nameWithWorld or player.name or player.id or "") or ""
    if self.loaded==true and self.identityTag==tag and verifyBinding~=true then return true end
    if not P:GetStore(self.StoreId) then return false,self.registerError or "个人历史存档不可用" end
    if type(P.IsStoreLoaded)=="function" and P:IsStoreLoaded(self.StoreId) then self.loaded=true;self.identityTag=tag;return true end
    local ok,_,err=P:LoadStore(self.StoreId)
    if ok~=true and ok~="empty" then return false,err or tostring(ok) end
    self.loaded=true;self.identityTag=tag
    return true
end
function H:Timestamp()
    local now=tonumber(S.NowMs and S.NowMs()) or 0
    if now-self.clockAt<1000 then return self.clockDay,self.clockStamp end
    self.clockAt=now
    local t=S.Utils and S.Utils.GetServerTime and S.Utils.GetServerTime()
    self.clockDay,self.clockStamp="unknown",nil
    if type(t)~="table" then return self.clockDay,nil end
    local y,m,d=tonumber(t.year),tonumber(t.month),tonumber(t.day)
    if not y or not m or not d then return self.clockDay,nil end
    local date=string.format("%04d-%02d-%02d",y,m,d)
    if not ValidDate(date) then return self.clockDay,nil end
    local hour,minute=tonumber(t.hour),tonumber(t.minute or t.min)
    if not hour or not minute or hour<0 or hour>23 or minute<0 or minute>59 then return self.clockDay,nil end
    self.clockDay=date
    self.clockStamp=string.format("%s %02d:%02d",date,hour,minute)
    return self.clockDay,self.clockStamp
end
function H:Record(delta)
    if type(delta)~="table" then return false end
    local hasValue=false
    for _,key in ipairs(LIVE_KEYS) do if Counter(delta[key])>0 then hasValue=true;break end end
    if not hasValue then return false end
    local ready,err=self:EnsureLoaded();if ready~=true then self.failures=self.failures+1;return false,err end
    local now=tonumber(S.NowMs and S.NowMs()) or 0
    -- 只标记脏存档，不在战斗事件中复制/保存整表；最多每秒标记一次，Persistence 在5秒内合并保存。
    if now-self.lastDirtyAt>=1000 then
        local ok,saveErr=P:MarkDirty(self.StoreId,5000,"personal_combat_delta")
        if ok~=true then self.failures=self.failures+1;self.lastError=saveErr;return false,saveErr end
        self.lastDirtyAt=now
    end
    local date,stamp=self:Timestamp()
    local row=self.state.days[date]
    if not row then
        local dates={};for key in pairs(self.state.days) do dates[#dates+1]=key end
        if #dates>=MAX_DAYS then
            table.sort(dates);local oldest=dates[1]
            Add(self.state.archive,self.state.days[oldest]);self.state.archiveFrom=self.state.archiveFrom or oldest;self.state.archiveTo=oldest
            self.state.days[oldest]=nil
        end
        row=Counts(nil);self.state.days[date]=row
    end
    for _,key in ipairs(LIVE_KEYS) do
        local amount=Counter(delta[key])
        row[key]=(tonumber(row[key]) or 0)+amount;self.state.totals[key]=(tonumber(self.state.totals[key]) or 0)+amount
    end
    row.firstAt=row.firstAt or stamp;row.lastAt=stamp or row.lastAt
    self.state.firstAt=self.state.firstAt or stamp;self.state.lastAt=stamp or self.state.lastAt
    self.revision=self.revision+1;self.lastError=nil
    return true
end
function H:GetProjection(options)
    local ready,err=self:EnsureLoaded(true)
    if ready~=true then return {available=false,error=err,totals=Counts(nil,LEGACY_KEYS),rows={}} end
    options=type(options)=="table" and options or {}
    local from,to=tostring(options.fromDate or ""),tostring(options.toDate or "")
    if (from~="" and not ValidDate(from)) or (to~="" and not ValidDate(to)) or (from~="" and to~="" and from>to) then
        return {available=false,error="请输入有效日期 YYYY-MM-DD，开始日期不能晚于结束日期",totals=Counts(nil,LEGACY_KEYS),rows={}}
    end
    local filtered=from~="" or to~="";local rows={};local totals=filtered and Counts(nil,LEGACY_KEYS) or Counts(self.state.totals,LEGACY_KEYS)
    local complete=true
    for date,row in pairs(self.state.days) do
        if not filtered or (date~="unknown" and (from=="" or date>=from) and (to=="" or date<=to)) then
            local out=ConfirmedCounts(row);out.date=date;out.firstAt=row.firstAt;out.lastAt=row.lastAt;rows[#rows+1]=out
            if filtered then Add(totals,row,LEGACY_KEYS) end
        elseif date=="unknown" then complete=false end
    end
    table.sort(rows,function(a,b) return a.date>b.date end)
    if filtered and self.state.archiveTo and (from=="" or from<=self.state.archiveTo) then complete=false end
    local store=P:GetStore(self.StoreId)
    return {available=true,complete=complete,totals=ConfirmedCounts(totals),rows=rows,firstAt=self.state.firstAt,lastAt=self.state.lastAt,
        archive=ConfirmedCounts(self.state.archive),archiveFrom=self.state.archiveFrom,archiveTo=self.state.archiveTo,
        revision=self.revision,failures=self.failures,error=self.lastError or (store and store.lastError),scope=A:GetCollectionScope(),
        coverage="仅记录开启期间客户端可见的伤害、治疗、承伤、击杀玩家、死亡；自身与所有人模式都只计明确归属，来源不明时不计击杀。旧版推断记录保留，但不计入击杀合计。日期时间为服务器时间（分钟精度）。"}
end
A:RegisterMetric({id="personal_history",title="个人长期统计",hidden=true,order=6,factCategories={"damage","heal"},
    OnFact=function(_,fact)
        local ownSource=A:IsSelfActor(fact.sourceName,fact.sourceId)
        local ownTarget=A:IsSelfActor(fact.targetName,fact.targetId)
        local amount=Counter(fact.amount);if amount<=0 then return false end
        local delta={}
        if fact.category=="damage" then if ownSource then delta.damage=amount end;if ownTarget then delta.taken=amount end
        elseif fact.category=="heal" and ownSource then delta.healing=amount end
        if next(delta)==nil then return false end
        return H:Record(delta)
    end,
    Reset=function() return true end,
    GetHealth=function() return {revision=H.revision,failures=H.failures,lastError=H.lastError} end,
})
