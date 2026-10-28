-- Replicated Suite · 个人战斗历史
-- 作者：Replicated
-- QQ群：1104129461
-- 个人长期统计。每日摘要 + 全期累计；实时排行的 reset 永不删除此 Store。
-- 从同一个击杀指标接收明确归属/荣誉补记增量，不监听第二套原生事件。
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
local TRANSFER_V1_KEYS={};for i,key in ipairs(KEYS) do TRANSFER_V1_KEYS[i]=key end
KEYS[#KEYS+1]="honorParticipations"
local TRANSFER_V2_KEYS={};for i,key in ipairs(KEYS) do TRANSFER_V2_KEYS[i]=key end
KEYS[#KEYS+1]="honorKills"
local DISPLAY_KEYS={};for i,key in ipairs(LEGACY_KEYS) do DISPLAY_KEYS[i]=key end
DISPLAY_KEYS[#DISPLAY_KEYS+1]="honorParticipations"
DISPLAY_KEYS[#DISPLAY_KEYS+1]="honorKills"
-- 旧推断计数仍参与原指纹规范化/归档，不能删除旧字段或改写原总数。
-- 新的荣誉辅助计入同一kills；旧版独立荣誉字段不自动并入。只读投影扣除旧版已标记的猜测计数。
-- 2026-10-07：NPC击杀已删除；schema2字段仅用于旧档完整性验证，不进入记录或公开投影。
local LIVE_KEYS = {"kills","deaths","damage","taken","healing","honorParticipations","honorKills"}
local OPTIONAL_KEYS={honorParticipations=true,honorKills=true}
local MAX_DAYS = 2048
local function Counter(v) v=tonumber(v);if not v or v~=v or v==math.huge or v<0 then return 0 end;return math.floor(v) end
local function Counts(v,keys)
    local out={};for _,key in ipairs(keys or KEYS) do
        -- 新计数缺失时保持缺失：旧档原指纹不变，未采集的旧日期也不能显示为零次。
        if not OPTIONAL_KEYS[key] or (type(v)=="table" and v[key]~=nil) then out[key]=Counter(type(v)=="table" and v[key]) end
    end;return out
end
local function ConfirmedCounts(v)
    local out=Counts(v,DISPLAY_KEYS)
    out.recordedKills=out.kills
    out.kills=math.max(0,out.kills-out.inferredKills)
    return out
end
local function Add(to, delta, keys) for _,key in ipairs(keys or KEYS) do
    if not OPTIONAL_KEYS[key] or to[key]~=nil or delta[key]~=nil then to[key]=(tonumber(to[key]) or 0)+Counter(delta[key]) end
end end
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
-- 同步模块只扩展本 Feature 的历史存档，不另建持久化 Authority；无同步字段的旧档仍保持原 canonical。
H.TransferHelpers={normalize=Normalize,keys=KEYS,legacyKeys=TRANSFER_V1_KEYS,v2Keys=TRANSFER_V2_KEYS,liveKeys=LIVE_KEYS,counter=Counter,counts=Counts,add=Add,validDate=ValidDate,maxDays=MAX_DAYS}
function H:NormalizeState(value)
    if type(self.NormalizeTransferState)=="function" then return self:NormalizeTransferState(value) end
    return Normalize(value)
end
-- schema1 没有 NPC 计数。只重建已知旧字段的原规范形式，原指纹精确匹配后由 Core 迁移。
-- 不改写实际文件、不绕过写保护；未知损坏仍由 Persistence 拒绝。
local function RebuildHistoryCanonical(value,stamp,canonical,raw)
    local meta=type(raw)=="table" and raw.__rsmeta or nil
    if type(meta)~="table" or meta.store~=H.StoreId or meta.owner~=H.StoreId then return nil end
    if tonumber(meta.schema)==1 then
        local historical=Normalize(value,LEGACY_KEYS)
        -- 迁移值只能来自通过旧章校验的字段，不能采纳原schema未认证的新计数。
        return historical,Normalize(historical)
    end
    -- 2026-10-28 活动 UDF 的 126817 在第16383字节截断；126227完整记录证明丢失日的两个时间。
    -- 只对该 old/new pair 补一个缺日及总起点。计数从总账减去现存日账/归档恢复，最终仍须逐字命中原章。
    local store=P:GetStore(H.StoreId)
    if tonumber(meta.schema)~=5 or tonumber(meta.framework)~=3 or tonumber(meta.transportVersion)~=3
        or stamp~='624DEB3B' or P:FingerprintCanonicalValue(store,canonical)~='4AEB9230'
        or type(value)~='table' or value.sync~=nil or value.firstAt~=nil
        or type(value.days)~='table' or value.days['2026-10-24']~=nil then return nil end
    local candidate=Normalize(value);local row=Counts(nil)
    for _,key in ipairs(KEYS)do
        local remaining=Counter(candidate.totals[key])-Counter(candidate.archive[key])
        for _,existing in pairs(candidate.days)do remaining=remaining-Counter(existing[key])end
        if remaining<0 then return nil end
        if not OPTIONAL_KEYS[key] or remaining>0 then row[key]=remaining end
    end
    row.firstAt,row.lastAt='2026-10-24 10:30','2026-10-24 14:39'
    candidate.days['2026-10-24']=row
    for _,existing in pairs(candidate.days)do
        if existing.firstAt and (not candidate.firstAt or existing.firstAt<candidate.firstAt)then candidate.firstAt=existing.firstAt end
    end
    if P:FingerprintCanonicalValue(store,candidate)~=stamp then return nil end
    return candidate,candidate
end
local store,registerErr=P:RegisterV3Store({
    id=H.StoreId,owner=H.StoreId,scope=P.Scope.Character,lifetime=P.Lifetime.Permanent,
    -- schema3 将来源账本和合计放在同一个 Store，导入只需一次耐久提交，不能出现“金额已加、去重标记未存”。
    schemaVersion=5,legacySchemaVersion=0,key=(P.V3KeyPrefix or "rs.v3.").."combat_personal_history",
    budget={maxDepth=8,maxNodes=120000,maxStringBytes=1000000,maxEntriesPerTable=2048},
    -- 单 key 的 Native 文本已实测在16383字节截断；压紧标量行并在写入前保守限额，不能靠回读发现后再覆盖旧档。
    transportVersion=7,nativeByteBudget=15000,nativePaged=true,
    rebuildCanonicalForIntegrity=RebuildHistoryCanonical,
    default=function() return H:NormalizeState(nil) end,get=function() return H:NormalizeState(H.state) end,
    apply=function(value) H.state=H:NormalizeState(value);H.lastDirtyAt=-10000;H.loaded=false;H.revision=H.revision+1 end,
    migrate=function(value) return H:NormalizeState(value) end,
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
function H:Record(delta,recordTime)
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
    -- 荣誉补记有短暂配对等待，跨服务器日界线时仍归到奖励发生日；只接受本 Feature 已捕获的完整时间。
    if type(recordTime)=="table" and (ValidDate(recordTime.date) or recordTime.date=="unknown")
        and (recordTime.stamp==nil or (Stamp(recordTime.stamp) and recordTime.stamp:sub(1,10)==recordTime.date)) then
        date,stamp=recordTime.date,recordTime.stamp
    end
    -- 来源增量仅做固定字段累加；未启用跨电脑交换的旧历史不额外建表，失败不得改变主合计。
    if type(self.RecordTransferDelta)=="function" then
        local accepted,transferErr=self:RecordTransferDelta(delta,date,stamp)
        if accepted~=true then self.failures=self.failures+1;self.lastError=transferErr;return false,transferErr end
    end
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
        if not OPTIONAL_KEYS[key] or amount>0 or row[key]~=nil then
        row[key]=(tonumber(row[key]) or 0)+amount;self.state.totals[key]=(tonumber(self.state.totals[key]) or 0)+amount
        end
    end
    if stamp then
        if not row.firstAt or stamp<row.firstAt then row.firstAt=stamp end
        if not row.lastAt or stamp>row.lastAt then row.lastAt=stamp end
        if not self.state.firstAt or stamp<self.state.firstAt then self.state.firstAt=stamp end
        if not self.state.lastAt or stamp>self.state.lastAt then self.state.lastAt=stamp end
    end
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
    local filtered=from~="" or to~="";local rows,dateOptions={},{};local totals=filtered and Counts(nil,DISPLAY_KEYS) or Counts(self.state.totals,DISPLAY_KEYS)
    local complete=true
    for date,row in pairs(self.state.days) do
        -- 下拉目录必须来自完整日账，不能随筛选结果缩小；未定日期仍留在全期记录，不伪造日期选项。
        if ValidDate(date) then dateOptions[#dateOptions+1]=date end
        if not filtered or (date~="unknown" and (from=="" or date>=from) and (to=="" or date<=to)) then
            local out=ConfirmedCounts(row);out.date=date;out.firstAt=row.firstAt;out.lastAt=row.lastAt;rows[#rows+1]=out
            if filtered then Add(totals,row,DISPLAY_KEYS) end
        elseif date=="unknown" then complete=false end
    end
    table.sort(dateOptions,function(a,b)return a>b end)
    table.sort(rows,function(a,b)
        if a.date=="unknown" then return false end
        if b.date=="unknown" then return true end
        return a.date>b.date
    end)
    if filtered and self.state.archiveTo and (from=="" or from<=self.state.archiveTo) then complete=false end
    local store=P:GetStore(self.StoreId)
    return {available=true,complete=complete,totals=ConfirmedCounts(totals),rows=rows,dateOptions=dateOptions,firstAt=self.state.firstAt,lastAt=self.state.lastAt,
        archive=ConfirmedCounts(self.state.archive),archiveFrom=self.state.archiveFrom,archiveTo=self.state.archiveTo,
        revision=self.revision,failures=self.failures,error=self.lastError or (store and store.lastError),scope=A:GetCollectionScope(),
        coverage="同一个击杀数：明确归属直接计入，普通区域没有荣誉也照常记录；战争/纷争荣誉只作备用补记。已知助攻3/12排除，仅匹配确认金额并与前后归属通知配对，其他金额不猜测。荣誉补记不编造死者或技能；旧版独立荣誉次数不并入击杀，已有历史不回补。伤害、治疗仅在对应追踪开启期间记录。日期时间为服务器时间（分钟精度）。"}
end
A:RegisterMetric({id="personal_history",title="个人长期统计",hidden=true,order=6,factCategories={"damage","heal"},
    OnFact=function(_,fact)
        local dps=S.Features and S.Features.DPS
        if dps and type(dps.IsTrackingCategoryEnabled)=="function" and not dps:IsTrackingCategoryEnabled(fact.category) then return false end
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
