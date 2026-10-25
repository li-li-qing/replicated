-- Replicated Suite · 拍卖助手功能入口
-- 作者：Replicated
-- QQ群：1104129461
-- 此 Feature 只管理收藏 CRUD 与 Sidecar 偏好。查询/报价/原生同步分别归 AuctionQueryV3、PriceQuoteQueueV3、AuctionSearchBridgeV3。
-- AuctionReadModel 供 auction/market_analysis 共享，不能反向依赖本 Feature 私有状态。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local FSF = S.FeatureSliceFactory
if type(FSF) ~= "table" then error("FeatureSliceFactory unavailable for tools_auction") end
local Call, Copy, Text, NewFeature = FSF.Call, FSF.Copy, FSF.Text, FSF.NewFeature
local PersistStateMutation = FSF.PersistStateMutation
local Demand = S.Demand
-- 共享读模型仍由 features/tools/auction/rs_auction_read_model.lua 拥有；
-- 本文件只消费它（不拥有事实、不复制第二份投影/归一化实现）。
local ARM = S.AuctionReadModel
if type(ARM) ~= "table" then error("AuctionReadModel unavailable for tools_auction") end
local AUCTION_FAVORITE_MAX = ARM.AUCTION_FAVORITE_MAX
local NormalizeAuctionKeyword, NormalizeAuctionFavorites = ARM.NormalizeAuctionKeyword, ARM.NormalizeAuctionFavorites
local NormalizeAuctionResultLimit = ARM.NormalizeAuctionResultLimit
local AuctionQueryReconcile, AuctionRows, AuctionProjection = ARM.ReconcileDemand, ARM.Rows, ARM.Projection
local AuctionSettingsCommands = ARM.SettingsCommands

-- 通用参数、Demand 和投影使用 AuctionReadModel；这里只保留本地别名，不另存查询事实。
local ARM = S.AuctionReadModel
if type(ARM) ~= "table" then error("AuctionReadModel unavailable for business bridge") end
local AUCTION_FAVORITE_MAX, AUCTION_KEYWORD_MAX = ARM.AUCTION_FAVORITE_MAX, ARM.AUCTION_KEYWORD_MAX
local NormalizeAuctionKeyword, NormalizeAuctionFavorites = ARM.NormalizeAuctionKeyword, ARM.NormalizeAuctionFavorites
local NormalizeAuctionResultLimit = ARM.NormalizeAuctionResultLimit
local AuctionQueryReconcile, AuctionRows, AuctionProjection = ARM.ReconcileDemand, ARM.Rows, ARM.Projection
local AuctionSettingsCommands = ARM.SettingsCommands
local function ApplyAuctionState(value,state)
    value=type(value)=="table" and value or {}
    state.keyword=NormalizeAuctionKeyword(value.keyword) or ""
    state.favorites=NormalizeAuctionFavorites(value.favorites)
    state.exactMatch=value.exactMatch==true
    state.resultLimit=NormalizeAuctionResultLimit(value.resultLimit) or 20
    -- 旧 Store 缺 sidecarEnabled 时补 true，显式 false 保留；只控制悬浮助手生命周期，不影响收藏/查询/任务清单。
    -- 旧 payload 按原内容验真，Apply 后补默认，下一次合法写入才带新字段。
    state.sidecarEnabled=value.sidecarEnabled~=false
    state.searchStatus="idle"
end
local function AuctionDefault() return { keyword="",favorites={},exactMatch=false,resultLimit=20,sidecarEnabled=true } end
-- 共享查询 helper 在 rs_auction_read_model.lua；此处只用别名，不能重新定义第二份。
local auctionCommands=AuctionSettingsCommands()
-- 最低价报价必须显式、限频且异步，由共享 PriceQuoteQueueV3 拥有；禁止直接 X2Auction:GetLowestPrice 绕过串行化与官方500ms冷却契约。
auctionCommands.Quote=function(_,itemType,grade)
    local queue = S.Services ~= nil and S.Services.PriceQuoteQueueV3 or nil
    if type(queue) ~= "table" or type(queue.RequestQuote) ~= "function" then return false, "报价服务不可用" end
    local ok, status = queue:RequestQuote("tools_auction", itemType, grade, nil)
    if ok ~= true then return false, status or "报价请求失败" end
    return true, status or "queued"
end
auctionCommands.AddFavorite=function(feature,value)
    local keyword=NormalizeAuctionKeyword(value); if keyword==nil then return false,"收藏关键词必须是 1-64 个可见字符" end
    if #feature.State.favorites>=AUCTION_FAVORITE_MAX then return false,"收藏已达到上限" end
    for _,item in ipairs(feature.State.favorites) do if item==keyword then return false,"收藏关键词已存在" end end
    return PersistStateMutation(feature,"auction_favorite",function(state) state.favorites[#state.favorites+1]=keyword; return true end)
end
auctionCommands.RemoveFavorite=function(feature,index)
    index=tonumber(index); if index==nil or index~=math.floor(index) or index<1 or index>#feature.State.favorites then return false,"收藏索引无效" end
    return PersistStateMutation(feature,"auction_favorite_remove",function(state) table.remove(state.favorites,index); return true end)
end
-- 收藏保留历史字符串数组，以规范 keyword 作身份。重命名/移动/删除每次查当前 State，不能拿旧 UI index 写入。
auctionCommands.RenameFavorite=function(feature,oldValue,newValue)
    local oldKeyword=NormalizeAuctionKeyword(oldValue); if oldKeyword==nil then return false,"收藏关键词必须是 1-64 个可见字符" end
    local index=nil; for i,item in ipairs(feature.State.favorites or {}) do if item==oldKeyword then index=i; break end end
    if index==nil then return false,"收藏关键词不存在" end
    local newKeyword=NormalizeAuctionKeyword(newValue); if newKeyword==nil then return false,"新收藏关键词必须是 1-64 个可见字符" end
    if newKeyword==oldKeyword then return true end
    for _,item in ipairs(feature.State.favorites or {}) do if item==newKeyword then return false,"收藏关键词已存在" end end
    return PersistStateMutation(feature,"auction_favorite_rename",function(state) state.favorites[index]=newKeyword; return true end)
end
auctionCommands.MoveFavorite=function(feature,value,direction)
    local keyword=NormalizeAuctionKeyword(value); if keyword==nil then return false,"收藏关键词必须是 1-64 个可见字符" end
    local index=nil; for i,item in ipairs(feature.State.favorites or {}) do if item==keyword then index=i; break end end
    if index==nil then return false,"收藏关键词不存在" end
    local delta=tonumber(direction); if delta==nil or delta==0 then return false,"移动方向无效" end
    delta=delta<0 and -1 or 1
    local target=index+delta; if target<1 or target>#feature.State.favorites then return false,"收藏已在边界" end
    return PersistStateMutation(feature,"auction_favorite_move",function(state)
        state.favorites[index],state.favorites[target]=state.favorites[target],state.favorites[index]; return true
    end)
end
auctionCommands.RemoveFavoriteByKeyword=function(feature,value)
    local keyword=NormalizeAuctionKeyword(value); if keyword==nil then return false,"收藏关键词必须是 1-64 个可见字符" end
    local index=nil; for i,item in ipairs(feature.State.favorites or {}) do if item==keyword then index=i; break end end
    if index==nil then return false,"收藏关键词不存在" end
    return PersistStateMutation(feature,"auction_favorite_remove_keyword",function(state) table.remove(state.favorites,index); return true end)
end
auctionCommands.ClearFavorites=function(feature)
    if #(feature.State.favorites or {})==0 then return true end
    return PersistStateMutation(feature,"auction_favorite_clear",function(state) state.favorites={}; return true end)
end
-- 偏好提交后同步启停 AuctionSurfaceV3，关闭须释放 250ms 窗口观察；收藏和显式查询不依赖该 watcher。
auctionCommands.SetSidecarEnabled=function(feature,value)
    local target=value==true
    local persisted,persistErr=PersistStateMutation(feature,"auction_sidecar_enabled",function(state) state.sidecarEnabled=target; return true end)
    if persisted~=true then return false,persistErr end
    local surface=S.Services and S.Services.AuctionSurfaceV3 or nil
    if feature.enabled==true and type(surface)=="table" then
        if target==true and type(surface.Start)=="function" then
            local started,startErr=surface:Start()
            if started~=true and S.DiagnosticsManager~=nil and type(S.DiagnosticsManager.Warn)=="function" then
                S.DiagnosticsManager:Warn("auction","AUCTION_SIDECAR_OBSERVER_UNAVAILABLE","拍卖悬浮助手偏好已开启，但原生拍卖窗口观察未启动；主页面功能保持可用",{error=tostring(startErr or "unknown")})
            end
        elseif target~=true and type(surface.Stop)=="function" then
            surface:Stop("sidecar_preference_disabled")
        end
    end
    -- 只刷新 detached projection/设置订阅，不发起 Auction Search。这样主页面 Toggle 会立即追平，
    -- Sidecar 的真实显隐仍由 AuctionSurfaceV3 -> Controller 单向驱动。
    if type(feature.Authority)=="table" and type(feature.Authority.Refresh)=="function" then feature.Authority:Refresh("auction_sidecar_setting") end
    return true
end
local AUCTION_API_DEPENDENCIES={"X2Auction:SearchAuctionArticle","X2Auction:GetSearchedItemCount","X2Auction:GetSearchedItemInfo","X2Auction:GetLowestPrice","ADDON:GetContent","ADDON:GetContentMainScriptPosVis"}
local AuctionFavorites = NewFeature("tools_auction",{apiDependencies=AUCTION_API_DEPENDENCIES,
    -- sidecarEnabled 是助手启用偏好，须保留在持久白名单，不能与 Widget 当前可见性混用；关闭时也停 250ms watcher。
    state={keyword="",favorites={},exactMatch=false,resultLimit=20,sidecarEnabled=true,searchStatus="idle"},default=AuctionDefault(),persistentKeys={"sidecarEnabled"},apply=ApplyAuctionState,
    onEnable=function(feature)
        if feature.State.sidecarEnabled==false then return true end
        local surface=S.Services and S.Services.AuctionSurfaceV3 or nil
        if type(surface)=="table" and type(surface.Start)=="function" then
            local started,startErr=surface:Start()
            if started~=true and S.DiagnosticsManager~=nil and type(S.DiagnosticsManager.Warn)=="function" then
                S.DiagnosticsManager:Warn("auction","AUCTION_SIDECAR_OBSERVER_UNAVAILABLE","拍卖收藏侧窗观察未启动；主页面功能保持可用",{error=tostring(startErr or "unknown")})
            end
        end
        return true
    end,
    onDisable=function()
        local surface=S.Services and S.Services.AuctionSurfaceV3 or nil
        if type(surface)=="table" and type(surface.Stop)=="function" then surface:Stop("feature_disabled") end
        return true
    end,
    reconcileDemand=AuctionQueryReconcile,read=function(feature) local rows,snapshot=AuctionRows(feature,true); local status=snapshot.status=="failed" and (#rows>0 and "partial" or "unavailable") or (#rows>0 and "ready" or "empty"); return rows,status,snapshot.error end,
    projection=AuctionProjection,commands=auctionCommands})
-- 向 Sidecar 提供 O(1) 偏好读取，避免 250ms 事件深拷贝拍卖结果；返回标量，不暴露 State。
function AuctionFavorites:IsSidecarEnabled() return self.State.sidecarEnabled~=false end
-- 收藏列表的公开只读 facade。
-- 走共享读模型的归一逻辑，返回新表；Presentation 应调这个方法，而不是直接读 State。
function AuctionFavorites:GetFavorites() return ARM.Favorites(self) end
AuctionFavorites.SidecarPreferenceContractVersion=1
function AuctionFavorites:Search(value) return self.Commands:Search(value) end
function AuctionFavorites:AddFavorite(value) return self.Commands:AddFavorite(value) end
function AuctionFavorites:RemoveFavorite(index) return self.Commands:RemoveFavorite(index) end
function AuctionFavorites:HasConsumer(token) return self.Demand ~= nil and type(self.Demand.Has) == "function" and self.Demand:Has(token) == true end

AuctionFavorites.AuctionQueryContractVersion = 1

-- 模块右上角诊断需能解释
-- “两个任务只识别一个”。只收集 Daily 服务当前快照，不读 Native、不刷新、不创建窗口，
-- 不依赖服务已取得 Consumer；全局报告与模块报告使用同一个诊断读模型。
if type(S.ModuleDiagnosticsHub) == "table" and type(S.ModuleDiagnosticsHub.RegisterProvider) == "function" then
    S.ModuleDiagnosticsHub:RegisterProvider(AuctionFavorites.Id, "daily_materials", function()
        local daily = S.Services and S.Services.DailyAuctionMaterialsV3 or nil
        if type(daily) == "table" and type(daily.GetDiagnosticsSnapshot) == "function" then return daily:GetDiagnosticsSnapshot() end
        return { status="unavailable", reason="daily_service_unavailable" }
    end, 30)
end
