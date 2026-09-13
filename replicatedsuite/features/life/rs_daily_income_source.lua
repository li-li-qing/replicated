------------------------------------------------------------------------
-- 今日收益原生事件适配器 / overview-income-source-9
-- Authority: PLAYER_MONEY / PLAYER_HONOR_POINT / PLAYER_LIVING_POINT / EXP_CHANGED 的 Native
-- payload 直接提供本次变化量；EXP_CHANGED 额外校验 player unitId，适配器只做结构校验与精确数值归一化，再交给 DailyLedger
-- 按日累计。DailyLedger 独占跨日、持久化、暂停边界，UI 不做业务计算。
-- Evidence: ArcheAge 客户端 UI 的 chat_msg_event.lua 明确使用
-- PLAYER_MONEY(change, changeStr, itemTaskType, info)、PLAYER_HONOR_POINT(amount, amountStr, ...)
-- 与 PLAYER_LIVING_POINT(amount, amountStr)。官方客户端 exp_bar_set.lua / combat_text.lua 同时确认
-- EXP_CHANGED(stringId, expNum, expStr)，且只有 player unitId 的 expStr 被作为本次获得经验显示。
-- money.lua 则证明 moneyStr 的末四位分别为银/铜，即 changeStr 是精确的最小货币单位十进制字符串。
-- Compatibility: 当前随包 z_api_functions 仍把 X2Bag:GetCurrency / GetMyMoneyString /
-- GetGamePoints / GetExpInfo 列为不允许，本适配器绝不调用。旧 overview-income-source-7
-- 曾错误把 change 当余额；新 delta 源首次命中时由 DailyLedger 清除该旧余额模式污染。
-- Performance: 纯事件驱动；无余额轮询、无 Tick、无聊天正文数字解析。
------------------------------------------------------------------------
if ReplicatedSuite==nil or ReplicatedSuite.BootError~=nil then return end
local S=ReplicatedSuite
local L=S.Features and S.Features.DailyLedger
if type(L)~="table" then return end
local A={Id="daily_income_chat_source",Patch="overview-income-source-9",started=false,sequence={gold=0,honor=0,experience=0,living=0},samples={},sampleCount=0,lastShape="",lastMeta="",
    totalEnvelopes=0,lastEnvelope="",lastCategorySource="",nativeEventCounts={PLAYER_MONEY=0,PLAYER_HONOR_POINT=0,PLAYER_LIVING_POINT=0,EXP_CHANGED=0},nativeEventLast={},
    nativeDirectDeltas={gold=0,honor=0,experience=0,living=0},nativeStringDeltaParses={gold=0,honor=0,experience=0,living=0},
    nativeNumericDeltaFallbacks={gold=0,honor=0,experience=0,living=0},nativeInvalidDeltas={gold=0,honor=0,experience=0,living=0},
    nativeLastAccepted={gold=nil,honor=nil,experience=nil,living=nil},nativeLastDeltaSource={gold="",honor="",experience="",living=""}}
S.Features.DailyIncomeSource=A
local CATEGORY_KEYS={"filterType","filter","filterId","messageFilterType","messageFilter","chatFilterType","chatFilter","cmf","messageType","chatType","categoryId","category"}
local UNIT_KEYS={"unit","currency","pointType","typeName"}
local function Integer(v)
    if type(v)=="number" then return v==v and v==math.floor(v) and math.abs(v)<=9007199254740991 and v or nil end
    if type(v)=="string" and v:match("^[+-]?%d+$") then local n=tonumber(v);if n and n==math.floor(n) then return n end end
    return nil
end
local function IsKnownCategory(n)
    return n~=nil and (n==_G.CMF_SELF_MONEY_CHANGED or n==_G.CMF_SELF_HONOR_POINT_CHANGED or n==_G.CMF_SELF_LIVING_POINT_CHANGED)
end
local function Category(info,channel)
    if type(info)=="table" then
        for _,key in ipairs(CATEGORY_KEYS)do local n=Integer(info[key]);if IsKnownCategory(n) then return n,"info."..key end end
    end
    -- Maintenance: RU 10.0 evidence showed the previous adapter could report samples=0 even
    -- while enabled. CHAT_MESSAGE's first argument is therefore treated as an alternate
    -- category carrier only when it equals one of the three exact CMF constants. This is
    -- evidence collection, not broad numeric-chat parsing.
    local ch=Integer(channel);if IsKnownCategory(ch) then return ch,"channel" end
    return nil
end
local function Unit(info)
    if type(info)~="table" then return nil end
    for _,key in ipairs(UNIT_KEYS)do if type(info[key])=="string" then return string.lower(info[key]) end end
    return nil
end
local function Delta(info,spec)
    for _,key in ipairs(spec.deltaKeys)do local n=Integer(info[key]);if n~=nil then return n,key end end
    -- Generic `delta` is accepted only when the payload also names the expected unit.
    local generic=Integer(info.delta);local unit=Unit(info)
    if generic~=nil and unit~=nil and spec.units[unit]==true then return generic,"delta" end
    return nil
end
local function Shape(info)
    if type(info)~="table" then return type(info) end
    local keys={};for k,v in pairs(info)do if type(k)=="string" and (type(v)=="string" or type(v)=="number" or type(v)=="boolean") then keys[#keys+1]=k..":"..type(v) end end
    table.sort(keys);if #keys>20 then while #keys>20 do table.remove(keys)end end
    return table.concat(keys,",")
end
local function PrimitiveSignature(...)
    local out={};local count=select("#",...)
    for i=1,count do
        local v=select(i,...);local t=type(v)
        if t=="number" or t=="boolean" then out[#out+1]=i..":"..t.."="..tostring(v)
        elseif t=="string" then out[#out+1]=i..":string[len="..tostring(#v).."]"
        elseif t=="nil" then out[#out+1]=i..":nil" else out[#out+1]=i..":"..t end
    end
    return table.concat(out,",")
end

function A:RecordEnvelope(channel,relation,name,message,info)
    self.totalEnvelopes=(tonumber(self.totalEnvelopes) or 0)+1
    self.lastEnvelope=table.concat({
        "channel="..tostring(channel),"relationType="..type(relation),
        "name="..((name==nil or name=="") and "empty" or "present"),
        "messageType="..type(message),"messageBytes="..tostring(type(message)=="string" and #message or 0),
        "infoType="..type(info)
    },",")
end
function A:RecordNativeEvent(eventName,...)
    eventName=tostring(eventName or "")
    self.nativeEventCounts[eventName]=(tonumber(self.nativeEventCounts[eventName]) or 0)+1
    self.nativeEventLast[eventName]=PrimitiveSignature(...)
end
local NATIVE_SPECS={
    PLAYER_MONEY={key="gold",sourceId="native:player_money:direct_delta_v1",unit="copper",mode="delta",resetLegacyBalanceOnFirstDelta=true},
    PLAYER_HONOR_POINT={key="honor",sourceId="native:player_honor_point:direct_delta_v1",unit="points",mode="delta",resetLegacyBalanceOnFirstDelta=true},
    PLAYER_LIVING_POINT={key="living",sourceId="native:player_living_point:direct_delta_v1",unit="points",mode="delta",resetLegacyBalanceOnFirstDelta=true},
    EXP_CHANGED={key="experience",sourceId="native:exp_changed:direct_delta_v1",unit="experience",mode="delta"},
}
local function EnsureSource(spec,sourceId,evidence)
    local current=L.sources and L.sources[spec.key]
    if current~=nil then
        if current.id==sourceId then return true end
        return false,"source_locked:"..tostring(current.id)
    end
    local ok,why=L:RegisterSource(spec.key,{id=sourceId,verified=true,runtimeVerified=false,
        evidence=evidence,mode=spec.mode or "delta",unit=spec.unit,
        resetLegacyBalanceOnFirstDelta=spec.resetLegacyBalanceOnFirstDelta==true})
    if ok==true or why=="source_already_registered" then return true end
    return false,why
end
local function ExactNativeDelta(change,changeStr)
    local numeric=Integer(change)
    if numeric==nil or numeric==0 then return nil,nil,"zero_or_invalid_change" end
    local text=Integer(changeStr)
    if text~=nil and text~=0 then
        local magnitude=math.abs(text)
        return numeric<0 and -magnitude or magnitude,"changeStr"
    end
    return numeric,"change","numeric_fallback"
end
local function PlayerUnitId()
    if type(S.Api)~="table" or type(S.Api.CallCapability)~="function" or type(_G.X2Unit)~="table" then return nil end
    local ok,value=S.Api:CallCapability("X2Unit:GetUnitId",X2Unit,"GetUnitId","player")
    if ok==true and value~=nil and tostring(value)~="" then return tostring(value) end
    return nil
end
local function CommitNativeDelta(self,eventName,spec,delta,deltaSource,evidence)
    local sourceOk,sourceWhy=EnsureSource(spec,spec.sourceId,evidence)
    if sourceOk~=true then return false,sourceWhy end
    local nextSeq=(self.sequence[spec.key] or 0)+1
    local accepted,err=L:Observe(spec.key,delta,spec.sourceId,nextSeq)
    if accepted==true then
        self.sequence[spec.key]=nextSeq
        self.nativeDirectDeltas[spec.key]=(self.nativeDirectDeltas[spec.key] or 0)+1
        if deltaSource=="changeStr" or deltaSource=="expStr" then self.nativeStringDeltaParses[spec.key]=(self.nativeStringDeltaParses[spec.key] or 0)+1
        else self.nativeNumericDeltaFallbacks[spec.key]=(self.nativeNumericDeltaFallbacks[spec.key] or 0)+1 end
        self.nativeLastAccepted[spec.key]=delta
        self.nativeLastDeltaSource[spec.key]=deltaSource or ""
        return true
    end
    return false,err
end
function A:HandleExpChanged(stringId,expNum,expStr)
    local eventName="EXP_CHANGED";self:RecordNativeEvent(eventName,stringId,expNum,expStr)
    local spec=NATIVE_SPECS[eventName]
    local playerId=PlayerUnitId()
    if playerId==nil then self.nativeInvalidDeltas.experience=(self.nativeInvalidDeltas.experience or 0)+1;return false,"player_unit_id_unavailable" end
    if tostring(stringId or "")~=playerId then return false,"not_player" end
    local delta,deltaSource,deltaWhy=ExactNativeDelta(expNum,expStr)
    if delta==nil then
        self.nativeInvalidDeltas.experience=(self.nativeInvalidDeltas.experience or 0)+1
        return false,deltaWhy or "invalid_experience_delta"
    end
    -- Maintenance (overview-income-source-9): do not call forbidden GetExpInfo/GetHeirExpInfo.
    -- The stock client consumes EXP_CHANGED for the player and renders expStr itself as the gain,
    -- so this event is the direct-delta authority and remains safe across level/heir-level rollover.
    return CommitNativeDelta(self,eventName,spec,delta,deltaSource=="changeStr" and "expStr" or deltaSource,
        "EXP_CHANGED(playerUnitId, expNum, expStr) stock-client contract; expStr is the displayed gained experience")
end
function A:HandleNativeDelta(eventName,...)
    eventName=tostring(eventName or "")
    self:RecordNativeEvent(eventName,...)
    local spec=NATIVE_SPECS[eventName]
    if spec==nil then return false,"unsupported_native_event" end
    local delta,deltaSource,deltaWhy=ExactNativeDelta(select(1,...),select(2,...))
    if delta==nil then
        self.nativeInvalidDeltas[spec.key]=(self.nativeInvalidDeltas[spec.key] or 0)+1
        return false,deltaWhy or "invalid_native_delta"
    end
    return CommitNativeDelta(self,eventName,spec,delta,deltaSource,
        eventName.." direct change payload; changeStr supplies exact integer magnitude when available")
end

function A:RecordShape(info,channel,relation,name)
    local shape=Shape(info);self.lastShape=shape;self.sampleCount=self.sampleCount+1
    if #self.samples<8 then self.samples[#self.samples+1]=shape end
    -- 只记录候选结构字段和值，不保存聊天正文或角色名；方便 RU 实机报告判断真正的 CMF/delta 键。
    local parts={"channel="..tostring(channel),"relation="..tostring(relation),"name="..((name==nil or name=="") and "empty" or "present")}
    local allow={}
    for _,k in ipairs(CATEGORY_KEYS)do allow[k]=true end
    for _,k in ipairs(UNIT_KEYS)do allow[k]=true end
    for _,k in ipairs({"moneyDelta","deltaMoney","money_delta","honorDelta","deltaHonor","honor_delta","livingDelta","deltaLiving","living_delta","delta"})do allow[k]=true end
    if type(info)=="table" then
        local keys={};for k in pairs(info)do if allow[k] then keys[#keys+1]=k end end;table.sort(keys)
        for _,k in ipairs(keys)do local v=info[k];if type(v)=="string" or type(v)=="number" or type(v)=="boolean" then parts[#parts+1]=k.."="..tostring(v) end end
    end
    self.lastMeta=table.concat(parts,",")
end
local function Specs()
    return {
        {key="gold",category=_G.CMF_SELF_MONEY_CHANGED,sourceId="chat:self_money_changed:explicit_delta_v1",unit="copper",
            deltaKeys={"moneyDelta","deltaMoney","money_delta"},units={copper=true,money=true}},
        {key="honor",category=_G.CMF_SELF_HONOR_POINT_CHANGED,sourceId="chat:self_honor_changed:explicit_delta_v1",unit="points",
            deltaKeys={"honorDelta","deltaHonor","honor_delta"},units={honor=true,honor_point=true,points=true}},
        {key="living",category=_G.CMF_SELF_LIVING_POINT_CHANGED,sourceId="chat:self_living_changed:explicit_delta_v1",unit="points",
            deltaKeys={"livingDelta","deltaLiving","living_delta"},units={living=true,living_point=true,vocation=true,points=true}},
    }
end
function A:EnsureChatSource(spec)
    return EnsureSource(spec,spec.sourceId,
        "CHAT_MESSAGE exact CMF category + explicit delta field; no text parsing / no forbidden balance getter")
end
function A:HandleChatMessage(channel,relation,name,message,info)
    self:RecordEnvelope(channel,relation,name,message,info)
    if type(info)=="table" and info.isUserChat==true then return false,"user_chat" end
    local category,categorySource=Category(info,channel);self.lastCategorySource=categorySource or ""
    local matched=nil
    for _,spec in ipairs(Specs())do if spec.category~=nil and category==spec.category then matched=spec;break end end
    if matched==nil then if type(info)=="table" then self:RecordShape(info,channel,relation,name) end;return false,"no_category_match" end
    if type(info)~="table" then return false,"no_explicit_delta" end
    local delta=Delta(info,matched)
    if delta==nil then self:RecordShape(info,channel,relation,name);return false,"no_explicit_delta" end
    local ok,why=self:EnsureChatSource(matched);if ok~=true then return false,why end
    local nextSeq=(self.sequence[matched.key] or 0)+1
    local accepted,err=L:Observe(matched.key,delta,matched.sourceId,nextSeq)
    if accepted==true then self.sequence[matched.key]=nextSeq;return true end
    return false,err
end
function A:Start()
    if self.started then return true end
    if type(S.Events)~="table" or type(S.Events.SubscribeOptional)~="function" then return false,"event_bus_unavailable" end
    -- Maintenance (overview-income-source-3): rs_events Dispatch always prepends
    -- listener.owner before the native payload. The old callback omitted this slot, so
    -- RU CHAT_MESSAGE shifted left by one argument and the real `info` value was dropped;
    -- diagnostics therefore showed channel=<adapter table> and could never match a CMF.
    -- Keep the owner slot explicit instead of special-casing payload shapes downstream.
    local subscribed=S.Events:SubscribeOptional("CHAT_MESSAGE",self,function(_,channel,relation,name,message,info)
        A:HandleChatMessage(channel,relation,name,message,info);return true
    end)
    if subscribed~=true then return false,"chat_message_unavailable" end
    -- Native PLAYER_* is the preferred authority. Client UI source defines these payloads as
    -- direct changes, not balances; register the source only when the optional event exists.
    -- If a client lacks one Native event, the exact-CMF explicit-delta chat fallback remains
    -- free to claim that one channel instead of being blocked by a dead source.
    for _,eventName in ipairs({"PLAYER_MONEY","PLAYER_HONOR_POINT","PLAYER_LIVING_POINT","EXP_CHANGED"})do
        -- Register the direct-delta contract before the first event so the homepage shows
        -- “监听中” rather than “待接入”. runtimeVerified remains false until a real RU event.
        local nativeEventName=eventName
        local subscribedNative=S.Events:SubscribeOptional(nativeEventName,self,function(_,...)
            if nativeEventName=="EXP_CHANGED" then A:HandleExpChanged(...) else A:HandleNativeDelta(nativeEventName,...) end
            return true
        end)
        if subscribedNative==true then
            local spec=NATIVE_SPECS[nativeEventName]
            local evidence=nativeEventName=="EXP_CHANGED"
                and "EXP_CHANGED(playerUnitId, expNum, expStr) stock-client direct experience delta"
                or nativeEventName.." direct change payload; exact magnitude prefers changeStr"
            local ok,why=EnsureSource(spec,spec.sourceId,evidence)
            if ok~=true then return false,why end
        end
    end
    self.started=true;return true
end
function A:Stop()
    if type(S.Events)=="table" and type(S.Events.UnsubscribeOwner)=="function" then S.Events:UnsubscribeOwner(self) end
    self.started=false;return true
end
function A:GetHealth()
    return {patch=self.Patch,started=self.started==true,samples=#self.samples,totalSamples=self.sampleCount,lastShape=self.lastShape,lastMeta=self.lastMeta,
        totalEnvelopes=self.totalEnvelopes,lastEnvelope=self.lastEnvelope,lastCategorySource=self.lastCategorySource,
        nativeEventCounts={PLAYER_MONEY=self.nativeEventCounts.PLAYER_MONEY or 0,PLAYER_HONOR_POINT=self.nativeEventCounts.PLAYER_HONOR_POINT or 0,PLAYER_LIVING_POINT=self.nativeEventCounts.PLAYER_LIVING_POINT or 0,EXP_CHANGED=self.nativeEventCounts.EXP_CHANGED or 0},
        nativeEventLast={PLAYER_MONEY=self.nativeEventLast.PLAYER_MONEY or "",PLAYER_HONOR_POINT=self.nativeEventLast.PLAYER_HONOR_POINT or "",PLAYER_LIVING_POINT=self.nativeEventLast.PLAYER_LIVING_POINT or "",EXP_CHANGED=self.nativeEventLast.EXP_CHANGED or ""},
        nativeDirectDeltas={gold=self.nativeDirectDeltas.gold or 0,honor=self.nativeDirectDeltas.honor or 0,experience=self.nativeDirectDeltas.experience or 0,living=self.nativeDirectDeltas.living or 0},
        nativeStringDeltaParses={gold=self.nativeStringDeltaParses.gold or 0,honor=self.nativeStringDeltaParses.honor or 0,experience=self.nativeStringDeltaParses.experience or 0,living=self.nativeStringDeltaParses.living or 0},
        nativeNumericDeltaFallbacks={gold=self.nativeNumericDeltaFallbacks.gold or 0,honor=self.nativeNumericDeltaFallbacks.honor or 0,experience=self.nativeNumericDeltaFallbacks.experience or 0,living=self.nativeNumericDeltaFallbacks.living or 0},
        nativeInvalidDeltas={gold=self.nativeInvalidDeltas.gold or 0,honor=self.nativeInvalidDeltas.honor or 0,experience=self.nativeInvalidDeltas.experience or 0,living=self.nativeInvalidDeltas.living or 0},
        nativeLastAccepted={gold=self.nativeLastAccepted.gold,honor=self.nativeLastAccepted.honor,experience=self.nativeLastAccepted.experience,living=self.nativeLastAccepted.living},
        nativeLastDeltaSource={gold=self.nativeLastDeltaSource.gold or "",honor=self.nativeLastDeltaSource.honor or "",experience=self.nativeLastDeltaSource.experience or "",living=self.nativeLastDeltaSource.living or ""},
        sequence={gold=self.sequence.gold,honor=self.sequence.honor,experience=self.sequence.experience,living=self.sequence.living}}
end
local ok,why=L:RegisterAdapter(A);if ok~=true and why~="adapter_already_registered" then error(why or "daily_income_adapter_registration_failed") end
