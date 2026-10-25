-- Replicated Suite · 每日收益账本
-- 作者：Replicated
-- QQ群：1104129461
-- 独立角色账本，按 server_date 换日，UI 只读，变更经 Persistence。
-- 收入仅接收经校验的真实变化量，不能用聊天正文、预计售价或升级归零的经验条推算。新 direct-delta 源首次命中会清掉旧余额模式的当日污染。
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
local function InvalidateScopeReceipts()
    -- 只作废会话连续性，不改已验证账本金额；投影观察到切角也必须记住这个间隙，不能等下一次5s任务才发现。
    F.sessions={};F.scopeBaselinePending={}
    for _,key in ipairs(KEYS)do F.scopeBaselinePending[key]=true end
end
function F:EnsureStoreLoaded()
    -- Feature 的 loaded 不能替代 Core 的角色绑定：同一 Lua 代际切角后必须重新加载，并丢弃上一角色的回执序号/余额基线。
    if self.loaded and P:IsStoreLoaded(self.StoreId)==true then self.scopeObservationLost=false;return true end
    if self.loaded then
        -- 即使切回原角色，离开期间也没有连续观察余额；仅在各来源首个成功回执后解除间隙，不能计入离线/别角色期间变化。
        InvalidateScopeReceipts()
    end
    self.loaded=false;self.sessions={};self.clockAvailable=false
    local ok,_,err=P:LoadStore(self.StoreId)
    if ok==true or ok=="empty" then self.loaded=true;self.lastError=nil;return true end
    self.lastError=tostring(err or ok);return false,self.lastError
end
-- 时钟只由5s生命周期任务和 Observe 拥有，禁止 UI getter 读取；失败不能变成日期字符串或给昨日重新标日。
function F:CheckDay()
    local function Fail(reason)
        local changed=self.clockAvailable~=false or self.lastError~=reason
        self.clockAvailable=false;self.lastError=tostring(reason);self.sessions={}
        if changed then Publish()end
        return false,self.lastError
    end
    local day,err=P:GetPeriodId(P.Lifetime.Daily,{kind="server_date"})
    if not day then return Fail(err or "server_time_unavailable")end
    -- 跨角色重绑等同冷启动，不能把旧角色的已加载标志用于携带新角色昨日余额。
    local wasLoaded=self.loaded==true and P:IsStoreLoaded(self.StoreId)==true
    local loaded,loadErr=self:EnsureStoreLoaded();if not loaded then return Fail(loadErr)end
    if self.State.day~="" and day<self.State.day then return Fail("server_clock_regressed")end
    local rolled=self.State.day~=day
    if rolled then
        local ok,saveErr=P:MutateStore(self.StoreId,function()
            -- 午夜仅切换本账本，无保证余额采样；后续首次余额重新建立基线，禁止把间隙计入变化。
            local previous=self.State
            self.State=Default();self.State.day=day
            for _,key in ipairs(KEYS)do
                local old=previous.channels[key]
                -- 仅同一运行持续观察时可跨午夜携带最后绝对余额，日累计归零；暂停/禁用已失去连续性，跨日冷启动也不能用昨日余额作前值。
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
    -- 只保留源描述，不复制适配器对象。代码契约验证与 RU 载荷验证分开；CHAT_MESSAGE 未观察到精确 CMF/显式 delta 前只能 probing，不能显示假 0。
    -- 同源已有真实样本的账本可在重载后继续信任。
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
        -- balance 模式仅为其他已核实绝对余额来源保留；PLAYER_MONEY/HONOR/LIVING 是直接增量来源，跳过前值路径。未来 continuousBalance 来源只可跨同日文件重载沿用持久末余额；显式观察间隙必须作废。
        local previous=nil
        if session then previous=session.value
        elseif source.mode=="balance" and source.continuousBalance==true and ch.balance~=nil
            and not (self.scopeBaselinePending and self.scopeBaselinePending[key]) then previous=ch.balance end
        if source.mode=="delta" then
            -- PLAYER_* 来源存储的 balance 证明旧适配器误按余额计算；同日 net/gain/spent 已受污染，在接受首个权威直接增量前只清除一次。其他增量来源不启用此保护，真实历史总量保持不变。
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
    -- 序号只在变更被Core接收后前进，保存拒绝不能吞掉重试收据；无后台重放原生事件。
    self.sessions[key]={sequence=sequence,value=value}
    if self.scopeBaselinePending then self.scopeBaselinePending[key]=nil end -- 只接受成功观察后恢复当前来源连续性，拒绝路径必须允许原回执重试。
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
                -- balance 本身就是持久有效标志，schema1已存在；显式观察中断清空它，不为连续性记录新增持久形态/版本。0为有效余额，只有nil表示没有可信前值。
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
    -- 适配器失败仅降级一个来源，不能禁用整个首页账本。
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
    -- 运行关闭/重载保留连续性，让下次同日余额事件跨越文件重载间隙；用户/偏好显式禁用则作废连续性。
    local why=tostring(reason or "user")
    if why~="shutdown" and why~="startup_failure" then self:InvalidateContinuousBalances("daily_ledger_disable:"..why) end
    self.enabled=false;self.paused=false
    StopCollection();Publish();return true
end
-- 首页暂停是会话采集控制，不修改持久Feature偏好；无关存档写保护不能让暂停按钮失效。暂停停止适配器与时钟，保留今日已提交总量；恢复先复核服务器日期再接收新记录。
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
-- 只读表现：保留总量是真实已保存观察，不是新余额；重新建立基线前显示保存日期与暂停/中断标识。缺来源或 Store 加载失败不能编造0。
function F:GetProjection()
    -- 不加载磁盘、时钟或改业务金额；丢失身份时仅作废会话回执，避免A→B只看页面→A漏过绑定变化并沿用旧余额。
    local current=self.loaded==true and P:IsStoreLoaded(self.StoreId)==true
    if self.loaded and not current and not self.scopeObservationLost then
        InvalidateScopeReceipts();self.scopeObservationLost=true
    elseif current then self.scopeObservationLost=false end
    local clockAvailable=current and self.clockAvailable==true
    local rows,verified={},0
    for _,key in ipairs(KEYS)do
        local source=self.sources[key];local ch=self.State.channels[key]
        local runtimeVerified=source~=nil and source.runtimeVerified==true
        if runtimeVerified then verified=verified+1 end
        local retained=runtimeVerified and current and ch.samples>0
        local status=not self.enabled and "off" or self.paused==true and "paused" or not source and "unconnected"
            or not runtimeVerified and source.baselineReady==true and "baselined" or not runtimeVerified and "probing"
            or not clockAvailable and "unavailable" or not self.sessions[key] and (retained and "retained" or "waiting") or "ready"
        local show=retained or (status=="ready" and current)
        rows[#rows+1]={key=key,name=LABELS[key],status=status,value=show and ch.net or nil,
            observedGain=show and ch.gain or nil,observedSpent=show and ch.spent or nil,
            coverageGap=ch.coverageGap or (retained and self.sessions[key]==nil),unit=UNITS[key],mode=source and source.mode or nil}
    end
    return {patch=self.patch,rows=rows,revision=self.revision,enabled=self.enabled,paused=self.paused==true,
        day=current and self.State.day~="" and self.State.day or nil,error=self.lastError,clockAvailable=clockAvailable,
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
