------------------------------------------------------------------------
-- 今日收支：独立角色账本。Authority在本Feature，UI只读投影，变更只经Persistence。
-- 维护（overview-ledger-6）：禁止的余额 Getter 仍不调用；金币/荣誉/生活点优先接收
-- PLAYER_* 的直接变化量。不能把聊天正文、跑商预计售价或其它推算值当实际收入。
-- 旧 overview-ledger-5 曾把 PLAYER_* 错当绝对余额并持久化 ch.balance；新 direct-delta
-- source 首次命中时会一次性清空对应旧余额模式的当日污染，然后从真实变化量重新累计。
-- 日界线复用 Core 的 server_date；仅本账本按日换新，不使用全局 ClearData。
-- 经验不接受会升级归零的普通余额条。
------------------------------------------------------------------------
if ReplicatedSuite==nil or ReplicatedSuite.BootError~=nil then return end
local S=ReplicatedSuite
local P=S.Persistence
if type(P)~="table" or type(S.FeatureRuntime)~="table" then return end
S.Features=S.Features or {}
local F={Id="life_daily_stats",StoreId="v3.daily_ledger",UpdateTopic="v3.daily_ledger.updated",
    ApiDependencies={},enabled=false,paused=false,loaded=false,revision=0,sources={},sessions={},adapters={},adapterErrors={},patch="overview-ledger-6",clockAvailable=false}
S.Features.DailyLedger=F
local KEYS={"gold","honor","experience","living"}
local LABELS={gold="金币",honor="荣誉",experience="经验",living="生活点"}
local UNITS={gold="copper",honor="points",experience="experience",living="points"}
local TASK="v3_daily_ledger_clock"
local function Copy(v)if type(v)~="table" then return v end;local o={};for k,x in pairs(v)do o[k]=Copy(x)end;return o end
local function Integer(n)return type(n)=="number" and n==n and n==math.floor(n) and math.abs(n)<=9007199254740991 end
local function Channel()return {net=0,gain=0,spent=0,samples=0,coverageGap=false}end
local function Default()local o={day="",channels={}};for _,k in ipairs(KEYS)do o.channels[k]=Channel()end;return o end
local function Normalize(v)
    if v==nil then return Default()end
    assert(type(v)=="table" and type(v.channels)=="table","invalid_ledger")
    local o=Default();o.day=tostring(v.day or "")
    assert(o.day=="" or o.day:match("^%d%d%d%d%-%d%d%-%d%d$"),"invalid_day")
    for _,k in ipairs(KEYS)do
        local src=v.channels[k];assert(type(src)=="table","invalid_channel")
        local dst=o.channels[k]
        for _,field in ipairs({"net","gain","spent","samples"})do assert(Integer(src[field]),"invalid_integer:"..field);dst[field]=src[field]end
        assert(dst.gain>=0 and dst.spent>=0 and dst.samples>=0,"invalid_totals")
        dst.coverageGap=src.coverageGap==true
        if src.balance~=nil then assert(Integer(src.balance),"invalid_balance");dst.balance=src.balance end
    end
    return o
end
F.State=Default()
local store,storeErr=P:RegisterV3Store({id=F.StoreId,owner="v3.daily_ledger",scope=P.Scope.Character,
    lifetime=P.Lifetime.Permanent,schemaVersion=1,legacySchemaVersion=0,key=P.V3KeyPrefix.."daily_ledger",
    budget={maxDepth=5,maxNodes=160,maxStringBytes=4096,maxEntriesPerTable=24},
    default=Default,get=function()return Copy(F.State)end,apply=function(v)F.State=Normalize(v)end,migrate=Normalize})
if not store then error(storeErr or "daily_ledger_store_failed")end
local function Publish()
    F.revision=F.revision+1
    if S.Events and type(S.Events.Publish)=="function" then S.Events:Publish(F.UpdateTopic,F.revision)end
end
function F:EnsureStoreLoaded()
    if self.loaded then return true end
    local ok,_,err=P:LoadStore(self.StoreId)
    if ok==true or ok=="empty" then self.loaded=true;return true end
    self.lastError=tostring(err or ok);return false,self.lastError
end
-- Clock ownership stays in the 5-second lifecycle task and Observe, never in a
-- UI getter. A failed read must not become a date string or relabel yesterday.
function F:CheckDay()
    local function Fail(reason)
        local changed=self.clockAvailable~=false or self.lastError~=reason
        self.clockAvailable=false;self.lastError=tostring(reason);self.sessions={}
        if changed then Publish()end
        return false,self.lastError
    end
    local day,err=P:GetPeriodId(P.Lifetime.Daily,{kind="server_date"})
    if not day then return Fail(err or "server_time_unavailable")end
    local wasLoaded=self.loaded==true
    local loaded,loadErr=self:EnsureStoreLoaded();if not loaded then return Fail(loadErr)end
    if self.State.day~="" and day<self.State.day then return Fail("server_clock_regressed")end
    local rolled=self.State.day~=day
    if rolled then
        local ok,saveErr=P:MutateStore(self.StoreId,function()
            -- Only this ledger rotates; midnight has no guaranteed balance
            -- sample, so a later first balance rebaselines, never counts gaps.
            local previous=self.State
            self.State=Default();self.State.day=day
            for _,key in ipairs(KEYS)do
                local old=previous.channels[key]
                -- Maintenance (overview-ledger-5): absolute-balance sources can safely carry the
                -- last observed balance across the server-day boundary. Net/gain/spent still reset
                -- to zero, but the next authoritative balance event can measure the first change of
                -- the new day instead of swallowing it as a fresh baseline. Invalidated continuity
                -- (pause/user-disable) is never revived by rollover.
                -- Carry an absolute balance through midnight only while this same runtime
                -- was already observing the character. A cold start on a later server day
                -- has an unbounded offline gap, so yesterday's persisted balance must not
                -- become today's predecessor. Same-day file reload remains continuous because
                -- no day roll occurs at all.
                if wasLoaded and old.balance~=nil then
                    self.State.channels[key].balance=old.balance
                    self.State.channels[key].coverageGap=old.coverageGap==true
                else
                    self.State.channels[key].coverageGap=old.samples>0 or old.balance~=nil or old.coverageGap==true
                end
            end
            return true
        end,{delayMs=1000,reason="daily_ledger_server_rollover"})
        if not ok then return Fail(saveErr)end
        self.sessions={}
    end
    local changed=self.clockAvailable~=true or self.lastError~=nil
    self.clockAvailable=true;self.lastError=nil
    if changed or rolled then Publish()end
    return true,day
end
function F:RegisterSource(key,spec)
    -- 确认来源身份/单位/模式才接收；不探测未允许的API。替换源需明确停用，避免混合两种单位。
    if not LABELS[key] or type(spec)~="table" or spec.verified~=true or type(spec.id)~="string" or #spec.id<1 or #spec.id>96
        or type(spec.evidence)~="string" or #spec.evidence<1 or #spec.evidence>512 or spec.unit~=UNITS[key] then return false,"unverified_source" end
    if spec.mode~="balance" and spec.mode~="delta" and spec.mode~="cumulative" then return false,"invalid_mode" end
    if key=="experience" and spec.mode=="balance" then return false,"xp_bar_is_not_total" end
    if self.sources[key] then return false,"source_already_registered" end
    -- 只保留经过验证的源描述，不复制适配器对象/函数/循环引用，也不接管它的生命周期。
    -- 维护（overview-income-source-1）：来源“代码契约已验证”和“RU 运行时载荷已验证”分开。
    -- CHAT_MESSAGE 适配器在真正观察到精确 CMF + 显式 delta 字段前只能处于 probing，
    -- 不允许 UI 把它算作已接入，更不能显示伪造的 0。已有真实样本的同源账本在重载后可继续信任。
    local channel=self.State.channels[key]
    local historicalVerified=(channel and channel.samples or 0)>0
    if spec.resetLegacyBalanceOnFirstDelta==true and channel and channel.balance~=nil then historicalVerified=false end
    local runtimeVerified=spec.runtimeVerified~=false or historicalVerified
    self.sources[key]={id=spec.id,verified=true,runtimeVerified=runtimeVerified,evidence=spec.evidence,unit=spec.unit,mode=spec.mode,
        continuousBalance=spec.continuousBalance==true,resetLegacyBalanceOnFirstDelta=spec.resetLegacyBalanceOnFirstDelta==true}
    self.sessions[key]=nil;Publish();return true
end
function F:RegisterAdapter(adapter)
    if type(adapter)~="table" or type(adapter.Id)~="string" or adapter.Id=="" or type(adapter.Start)~="function" or type(adapter.Stop)~="function" then
        return false,"invalid_adapter"
    end
    if self.adapters[adapter.Id]~=nil then return false,"adapter_already_registered" end
    self.adapters[adapter.Id]=adapter
    if self.enabled and self.paused~=true then
        local ok,why=adapter:Start()
        if ok~=true then self.adapterErrors[adapter.Id]=tostring(why or "start_failed") else self.adapterErrors[adapter.Id]=nil end
        Publish()
    end
    return true
end
function F:Observe(key,value,sourceId,sequence)
    if not self.enabled then return false,"stats_disabled" end
    if self.paused==true then return false,"stats_paused" end
    local source=self.sources[key]
    if not source or source.id~=sourceId then return false,"unregistered_source" end
    if not Integer(value) or not Integer(sequence) or sequence<1 then return false,"invalid_receipt" end
    if source.mode~="delta" and value<0 then return false,"negative_balance" end
    local ok,err=self:CheckDay();if not ok then return false,err end
    local session=self.sessions[key]
    if session and sequence<=session.sequence then return false,"stale_receipt" end
    local success,why=P:MutateStore(self.StoreId,function()
        local ch=self.State.channels[key];local delta=0
        -- Maintenance (overview-ledger-6): balance-mode remains available for other verified
        -- absolute-balance sources. PLAYER_MONEY/HONOR/LIVING themselves are now registered as
        -- direct delta sources by overview-income-source-8 and therefore skip this predecessor path.
        -- For a future balance source that opts into continuousBalance, the durable last balance is
        -- safe only across a same-day file reload; deliberate observation gaps invalidate it below.
        local previous=nil
        if session then previous=session.value
        elseif source.mode=="balance" and source.continuousBalance==true and ch.balance~=nil then previous=ch.balance end
        if source.mode=="delta" then
            -- Maintenance (overview-ledger-6): source-8 fixes the earlier PLAYER_* semantic bug.
            -- A persisted `balance` proves this channel was produced by the old incorrect balance
            -- adapter. Its same-day net/gain/spent are therefore contaminated and must be discarded
            -- exactly once before accepting the first authoritative direct delta. No other delta
            -- source opts into this fence, so legitimate historical delta totals are untouched.
            if source.resetLegacyBalanceOnFirstDelta==true and ch.balance~=nil then
                ch.net,ch.gain,ch.spent,ch.samples=0,0,0,0
                ch.balance=nil
                ch.coverageGap=true
            elseif not session then
                ch.coverageGap=ch.coverageGap or ch.samples>0
            end
            delta=value
        elseif previous~=nil then
            delta=value-previous
        else
            delta=0
            if source.mode=="balance" then ch.coverageGap=true end
        end
        if source.mode=="cumulative" and delta<0 then return false,"cumulative_total_regressed" end
        if not Integer(ch.net+delta) or not Integer(ch.gain+math.max(0,delta)) or not Integer(ch.spent+math.max(0,-delta)) then return false,"amount_overflow" end
        ch.net=ch.net+delta;ch.gain=ch.gain+math.max(0,delta);ch.spent=ch.spent+math.max(0,-delta)
        ch.samples=math.min(2147483647,ch.samples+1)
        if source.mode~="delta" then ch.balance=value end
        return true
    end,{delayMs=1000,reason="daily_ledger_observation"})
    if not success then self.lastError=tostring(why);return false,why end
    -- 维护：序号只在变更被Core接收后前进，保存拒绝不能吞掉重试收据；无后台重放原生事件。
    self.sessions[key]={sequence=sequence,value=value}
    if source.runtimeVerified~=true then source.runtimeVerified=true end
    Publish();return true
end
function F:InvalidateContinuousBalances(reason)
    local has=false
    for key,source in pairs(self.sources or {})do
        if type(source)=="table" and source.mode=="balance" and source.continuousBalance==true then has=true;break end
    end
    if not has then return true end
    local loaded,loadErr=self:EnsureStoreLoaded();if not loaded then return false,loadErr end
    local ok,why=P:MutateStore(self.StoreId,function()
        for key,source in pairs(self.sources or {})do
            if type(source)=="table" and source.mode=="balance" and source.continuousBalance==true then
                local ch=self.State.channels[key]
                -- Maintenance (overview-ledger-5): `balance` itself is the durable validity
                -- marker. The field already existed in schema v1, so clearing it on an
                -- intentional observation gap avoids adding a new persisted shape/version
                -- solely for continuity bookkeeping. Zero remains a valid balance because
                -- only nil means "no trusted predecessor".
                if ch then ch.balance=nil;ch.coverageGap=true end
            end
        end
        return true
    end,{delayMs=0,reason=tostring(reason or "continuous_balance_invalidated")})
    if ok then self.sessions={};Publish() end
    return ok,why
end
function F:Initialize()return true end
local function StopCollection()
    F.sessions={}
    if S.Scheduler then S.Scheduler:RemoveTask(TASK)end
    for id,adapter in pairs(F.adapters)do
        local ok,why=adapter:Stop();if ok~=true then F.adapterErrors[id]=tostring(why or "stop_failed") end
    end
    return true
end
local function StartCollection()
    F.sessions={}
    F:CheckDay()
    if not S.Scheduler or type(S.Scheduler.AddTask)~="function" then return false,"scheduler_unavailable" end
    local ok=S.Scheduler:AddTask(TASK,5000,function()if F.enabled and F.paused~=true then F:CheckDay()end;return true end,false,F,"P4",1)
    if not ok then return false,"clock_task_failed" end
    -- Adapter failure only degrades one data source; it must not disable the whole homepage ledger.
    for id,adapter in pairs(F.adapters)do
        local started,why=adapter:Start()
        if started~=true then F.adapterErrors[id]=tostring(why or "start_failed") else F.adapterErrors[id]=nil end
    end
    return true
end
function F:Enable()
    if self.enabled then return true end
    self.enabled=true;self.paused=false
    local ok,why=StartCollection()
    if ok~=true then self.enabled=false;StopCollection();return false,why end
    Publish();return true
end
function F:Disable(reason)
    -- Runtime shutdown/reload preserves continuity so the next same-day balance event can
    -- bridge the file-reload gap. Explicit user/preference disables invalidate it.
    local why=tostring(reason or "user")
    if why~="shutdown" and why~="startup_failure" then self:InvalidateContinuousBalances("daily_ledger_disable:"..why) end
    self.enabled=false;self.paused=false
    StopCollection();Publish();return true
end
-- Maintenance (overview-ledger-4): the homepage control is a session collection
-- pause, not a persistent Feature preference mutation. A preference write can be fenced
-- for unrelated persistence reasons and made the old “暂停统计” button appear dead.
-- Pausing now has its own bounded lifecycle: adapters + clock stop, today's committed
-- totals remain, and resume re-checks the server day before accepting new receipts.
function F:SetPaused(paused,reason)
    if not self.enabled then return false,"stats_disabled" end
    local target=paused==true
    if self.paused==target then return true end
    if target then
        local ok,why=self:InvalidateContinuousBalances("daily_ledger_pause:"..tostring(reason or "home"))
        if ok~=true then return false,why end
        self.paused=true;StopCollection();Publish();return true
    end
    self.paused=false
    local ok,why=StartCollection()
    if ok~=true then self.paused=true;StopCollection();Publish();return false,why end
    Publish();return true
end
-- Read-only presentation. Retained totals are genuine saved observations,
-- not a new balance; show the saved day and a paused/gap badge until rebaselined.
-- Never fabricate a zero for a missing source or a failed store load.
function F:GetProjection()
    local rows,verified={},0
    for _,key in ipairs(KEYS)do
        local source=self.sources[key];local ch=self.State.channels[key]
        local runtimeVerified=source~=nil and source.runtimeVerified==true
        if runtimeVerified then verified=verified+1 end
        local retained=runtimeVerified and self.loaded and ch.samples>0
        local status=not self.enabled and "off" or self.paused==true and "paused" or not source and "unconnected"
            or not runtimeVerified and source.baselineReady==true and "baselined" or not runtimeVerified and "probing"
            or not self.clockAvailable and "unavailable" or not self.sessions[key] and (retained and "retained" or "waiting") or "ready"
        local show=retained or (status=="ready" and self.loaded)
        rows[#rows+1]={key=key,name=LABELS[key],status=status,value=show and ch.net or nil,
            observedGain=show and ch.gain or nil,observedSpent=show and ch.spent or nil,
            coverageGap=ch.coverageGap or (retained and self.sessions[key]==nil),unit=UNITS[key],mode=source and source.mode or nil}
    end
    return {patch=self.patch,rows=rows,revision=self.revision,enabled=self.enabled,paused=self.paused==true,
        day=self.State.day~="" and self.State.day or nil,error=self.lastError,clockAvailable=self.clockAvailable,
        verifiedSources=verified,missingSources=4-verified,
        sourceNote="已验证收益来源 "..verified.."/4；未接入的项目不显示伪造的0。"}
end
function F:GetHealth()
    local registered,verified=0,0;for _,src in pairs(self.sources)do registered=registered+1;if src.runtimeVerified==true then verified=verified+1 end end
    local adapterErrors={};for id,why in pairs(self.adapterErrors)do adapterErrors[id]=why end
    return {patch=self.patch,enabled=self.enabled,paused=self.paused==true,day=self.State.day,registeredSources=registered,verifiedSources=verified,lastError=self.lastError,
        adapterErrors=adapterErrors,scope="character",datePolicy="server_date",revision=self.revision}
end
local ok,err=S.FeatureRuntime:RegisterImplementation(F.Id,F)
if not ok then error(err or "daily_ledger_registration_failed")end
