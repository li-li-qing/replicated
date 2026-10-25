-- Replicated Suite · 拍卖共享读模型
-- 作者：Replicated
-- QQ群：1104129461
-- auction 和 market_analysis 共用的参数归一、Demand 绑定与查询投影。
-- 事实仍归 AuctionQueryV3/PriceQuoteQueueV3/AuctionSearchBridgeV3；不发 Native、不长期复制 Feature 私有 State。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local FSF = S.FeatureSliceFactory
if type(FSF) ~= "table" then error("FeatureSliceFactory unavailable for auction read model") end
local Copy, Text = FSF.Copy, FSF.Text
local PersistStateMutation = FSF.PersistStateMutation

local R = {}

R.ContractVersion = 1
R.AUCTION_FAVORITE_MAX, R.AUCTION_KEYWORD_MAX = 20, 64
R.AUCTION_RESULT_LIMIT_MAX = 30

function R.NormalizeAuctionKeyword(value)
    local text = FSF.Trim(value)
    if text == "" or #text > R.AUCTION_KEYWORD_MAX or text:find("[%c]") ~= nil then return nil end
    return text
end

function R.NormalizeAuctionFavorites(value)
    local out, seen = {}, {}
    if type(value) ~= "table" then return out end
    for _, raw in ipairs(value) do
        local item = R.NormalizeAuctionKeyword(raw)
        if item ~= nil and not seen[item] and #out < R.AUCTION_FAVORITE_MAX then seen[item]=true; out[#out+1]=item end
    end
    return out
end

-- 返回重新归一化的新收藏数组，Presentation 不能直接持有或改写 Feature.State。
function R.Favorites(feature)
    if type(feature) ~= "table" then return {} end
    return R.NormalizeAuctionFavorites(feature.State and feature.State.favorites)
end

function R.NormalizeAuctionResultLimit(value)
    local n=tonumber(value); if n==nil or n~=math.floor(n) then return nil end
    return math.max(5,math.min(R.AUCTION_RESULT_LIMIT_MAX,math.floor(n)))
end

function R.QueryService() return S.Services and S.Services.AuctionQueryV3 or nil end

-- Demand 0->1 时把两个共享事实（查询结果、异步最低价报价）接成投影刷新边；
-- 1->0 时解绑。AuctionQueryV3 / PriceQuoteQueueV3 仍是各自事实的唯一 Authority。
function R.ReconcileDemand(feature,before,after)
    local a=tonumber(before and before.count) or 0; local b=tonumber(after and after.count) or 0
    if a<=0 and b>0 then
        if S.Events==nil or type(S.Events.SubscribeInternal)~="function" then return false,"拍卖查询内部事件不可用" end
        local ok=S.Events:SubscribeInternal("v3.auction_query.updated",feature,function(_,requester)
            if tostring(requester or "")==feature.Id and feature.enabled==true and (tonumber(feature.consumerCount) or 0)>0 then
                return feature.Authority:Refresh("auction_query_updated")
            end
        end)
        if ok~=true then return false,"拍卖查询结果订阅失败" end
        if type(S.Events.SubscribeInternal)=="function" then
            -- 共享队列异步完成最低价报价，此边沿负责让结果到达投影。
            S.Events:SubscribeInternal("v3.price_quote.completed",feature,function()
                if feature.enabled==true and (tonumber(feature.consumerCount) or 0)>0 then
                    return feature.Authority:Refresh("price_quote_completed")
                end
            end)
            feature.PriceQuoteSubscribed=true
        end
        feature.AuctionQuerySubscribed=true
    elseif a>0 and b<=0 and feature.AuctionQuerySubscribed==true and S.Events~=nil then
        S.Events:UnsubscribeInternal("v3.auction_query.updated",feature); feature.AuctionQuerySubscribed=false
        if feature.PriceQuoteSubscribed==true and type(S.Events.UnsubscribeInternal)=="function" then
            S.Events:UnsubscribeInternal("v3.price_quote.completed",feature); feature.PriceQuoteSubscribed=false
        end
    end
    return true
end

function R.Snapshot(feature)
    local query=R.QueryService()
    if type(query)~="table" or type(query.GetSnapshot)~="function" then return {status="unavailable",rows={},count=0,error="AuctionQueryV3 不可用"} end
    return query:GetSnapshot(feature.Id)
end

function R.Search(feature,value)
    local keyword=R.NormalizeAuctionKeyword(value==nil and feature.State.keyword or value)
    if keyword==nil then feature.State.searchStatus="failed"; return false,"搜索关键词必须是 1-64 个可见字符" end
    local persisted,persistErr=PersistStateMutation(feature,"auction_keyword",function(state) state.keyword=keyword; return true end)
    if persisted~=true then feature.State.searchStatus="failed"; return false,persistErr or "搜索关键词保存失败" end
    local bridge=S.Services and S.Services.AuctionSearchBridgeV3 or nil
    local query=R.QueryService()
    if (type(bridge)~="table" or type(bridge.Search)~="function") and (type(query)~="table" or type(query.Search)~="function") then return false,"拍卖查询服务不可用" end
    local options={exactMatch=feature.State.exactMatch==true,resultLimit=feature.State.resultLimit}
    local ok,result
    if type(bridge)=="table" and type(bridge.Search)=="function" then ok,result=bridge:Search(feature.Id,keyword,options)
    else ok,result=query:Search(feature.Id,keyword,options) end
    feature.State.searchStatus=ok==true and "waiting" or "failed"
    if feature.Authority then feature.Authority:Refresh("auction_search_requested") end
    return ok,result
end

function R.Rows(feature,includeFavorites)
    local rows={}
    if includeFavorites then
        for index,value in ipairs(feature.State.favorites or {}) do rows[#rows+1]={key="favorite:"..index,favoriteIndex=index,name=Text(value),text="收藏关键词 · 点击搜索可读取当前挂单",statusText="收藏",tone="default",kind="favorite"} end
    end
    local snapshot=R.Snapshot(feature)
    for _,row in ipairs(type(snapshot.rows)=="table" and snapshot.rows or {}) do
        local copy=Copy(row); copy.kind="result"; rows[#rows+1]=copy
    end
    return rows,snapshot
end

function R.Projection(feature)
    local query=R.QueryService()
    local snapshot=query and type(query.GetStatusSnapshot)=="function" and query:GetStatusSnapshot(feature.Id) or R.Snapshot(feature)
    -- 最低价结果由显式异步 PriceQuoteQueueV3 提供；队列是唯一权威，这里只同步页面快照，禁止发服务器查询。
    local quote=S.Services ~= nil and S.Services.PriceQuoteQueueV3 or nil
    local quoteSnapshot=type(quote)=="table" and type(quote.GetSnapshot)=="function" and quote:GetSnapshot(feature.Id) or nil
    local bridge=S.Services and S.Services.AuctionSearchBridgeV3 or nil
    local bridgeSnapshot=type(bridge)=="table" and type(bridge.GetSnapshot)=="function" and bridge:GetSnapshot() or {}
    return { keyword=feature.State.keyword,favoriteCount=#(feature.State.favorites or {}),favoriteMax=R.AUCTION_FAVORITE_MAX,
        exactMatch=feature.State.exactMatch==true,resultLimit=feature.State.resultLimit,sidecarEnabled=feature.State.sidecarEnabled~=false,
        nativeSync=tostring(bridgeSnapshot.nativeSync or "idle"),nativeCandidateStatus=tostring(bridgeSnapshot.candidateStatus or "none"),
        nativeCandidatePath=bridgeSnapshot.candidatePath,nativeSyncReason=bridgeSnapshot.reason,nativeSyncFallbackCount=tonumber(bridgeSnapshot.fallbackCount) or 0,
        searchStatus=snapshot.status or feature.State.searchStatus or "idle",resultStatus=snapshot.status or "idle",
        resultCount=tonumber(snapshot.count) or 0,queryError=snapshot.error,queryContract=snapshot.contract,
        quoteStatus=quoteSnapshot and quoteSnapshot.status or "idle",
        quotePrice=quoteSnapshot and tonumber(quoteSnapshot.price) or nil,
        quoteError=quoteSnapshot and quoteSnapshot.error or nil }
end

-- 每次调用返回全新的命令表：tools_auction 与 tools_market_analysis 各自持有一份实例，
-- 避免两个 Feature 共享同一个闭包表后被后续扩展互相污染。
function R.SettingsCommands()
    return {
        SetKeyword=function(feature,value) local keyword=R.NormalizeAuctionKeyword(value); if keyword==nil then return false,"搜索关键词必须是 1-64 个可见字符" end; return PersistStateMutation(feature,"auction_keyword",function(state) state.keyword=keyword; return true end) end,
        SetExactMatch=function(feature,value) return PersistStateMutation(feature,"auction_exact",function(state) state.exactMatch=value==true; return true end) end,
        SetResultLimit=function(feature,value) local n=R.NormalizeAuctionResultLimit(value); if n==nil then return false,"结果数量必须是 5-30" end; return PersistStateMutation(feature,"auction_limit",function(state) state.resultLimit=n; return true end) end,
        Search=R.Search,
    }
end

S.AuctionReadModel = R
