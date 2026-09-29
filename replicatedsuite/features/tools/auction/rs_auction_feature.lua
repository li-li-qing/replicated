------------------------------------------------------------------------
-- Replicated Suite V3 - tools_auction Feature Authority
--
-- Phase 1 Batch D（2026-09-28）：从 features/rs_business_bridge.lua 机械搬迁。
-- 只改变源码边界，不改业务行为：Feature ID、Store ID/Schema、UpdateTopic、Demand owner、
-- Commands（设置 + 收藏 CRUD + 报价 + Sidecar 开关）、Projection shape、ApiDependencies、
-- SidecarPreferenceContractVersion / AuctionQueryContractVersion 全部与被搬迁前逐字一致。
--
-- Authority 边界：当前挂单/报价事实归 AuctionQueryV3 / PriceQuoteQueueV3 / AuctionSearchBridgeV3；
-- 共享读模型归 rs_auction_read_model.lua。本文件只拥有 tools_auction 自己的收藏 CRUD 与 Sidecar 偏好，
-- 不得把这些塞回共享读模型，也不得让 tools_market_analysis 反向依赖本文件。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local FSF = S.FeatureSliceFactory
if type(FSF) ~= "table" then error("FeatureSliceFactory unavailable for tools_auction") end
local Call, Copy, Text, NewFeature = FSF.Call, FSF.Copy, FSF.Text, FSF.NewFeature
local PersistStateMutation = FSF.PersistStateMutation
local Demand = S.Demand
-- 中文维护注释：共享读模型仍由 features/tools/auction/rs_auction_read_model.lua 拥有；
-- 本文件只消费它（不拥有事实、不复制第二份投影/归一化实现）。
local ARM = S.AuctionReadModel
if type(ARM) ~= "table" then error("AuctionReadModel unavailable for tools_auction") end
local AUCTION_FAVORITE_MAX = ARM.AUCTION_FAVORITE_MAX
local NormalizeAuctionKeyword, NormalizeAuctionFavorites = ARM.NormalizeAuctionKeyword, ARM.NormalizeAuctionFavorites
local NormalizeAuctionResultLimit = ARM.NormalizeAuctionResultLimit
local AuctionQueryReconcile, AuctionRows, AuctionProjection = ARM.ReconcileDemand, ARM.Rows, ARM.Projection
local AuctionSettingsCommands = ARM.SettingsCommands

-- 中文维护注释（2026-09-28，Phase 1 Batch A）：拍卖共享读模型（关键词/数量归一、Demand 绑定、
-- 快照读取、投影形状、设置命令）已抽到 features/tools/auction/rs_auction_read_model.lua。
-- 它不拥有事实（事实归 AuctionQueryV3 / PriceQuoteQueueV3 / AuctionSearchBridgeV3），
-- 这里只保留别名，tools_auction 的调用点逐字不变。
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
    -- 中文维护注释（2026-09-15，拍卖悬浮助手独立开关）：旧 v3.business.tools_auction
    -- payload 没有 sidecarEnabled。缺字段必须保持历史行为=开启，只有显式 false 才关闭；否则升级后
    -- 会把所有旧用户的拍卖助手静默关掉。Feature State 是永久偏好 Authority，Presentation 只能经
    -- Commands:SetSidecarEnabled 修改。该字段只控制 AuctionSurface/Sidecar 生命周期，不影响收藏、
    -- 当前挂单查询、今日任务或 Session 临时清单。沿用现有 schema1 是兼容加字段：旧 payload 的
    -- integrity 仍按其原始内容验证，Apply 后缺字段补 true；下一次合法写入才带上新字段。
    state.sidecarEnabled=value.sidecarEnabled~=false
    state.searchStatus="idle"
end
local function AuctionDefault() return { keyword="",favorites={},exactMatch=false,resultLimit=20,sidecarEnabled=true } end
-- 中文维护注释（2026-09-28，Phase 1 Batch A）：AuctionQueryService / AuctionQueryReconcile /
-- AuctionSnapshot / AuctionSearch / AuctionRows / AuctionProjection / AuctionSettingsCommands
-- 已全部搬到 features/tools/auction/rs_auction_read_model.lua，本文件顶部保留了同名别名。
-- 禁止在此重新定义，否则会与共享读模型产生第二份 Authority。
local auctionCommands=AuctionSettingsCommands()
-- Lowest-price quotes are explicit + rate-limited + asynchronous. They are
-- owned by the shared PriceQuoteQueueV3 service, never issued here via a direct
-- X2Auction:GetLowestPrice call (which would bypass serialization and the
-- official 500ms cooldown contract).
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
-- 中文维护注释（2026-09-14，拍卖收藏稳定身份 CRUD）：收藏永久 Store 继续保持历史字符串数组，
-- 避免为了 UI 排序/重命名升级 schema 导致旧用户配置迁移风险。业务身份使用规范化后的 keyword，
-- UI 行 index 只作瞬时显示位置；所有写入仍经 PersistStateMutation -> v3.business.tools_auction Store。
-- 风险边界：关键词必须唯一，因此 rename/move/remove-by-keyword 每次都扫描当前 Authority State，
-- 禁止缓存旧 index 后直接写入，避免排序刷新后误删/误改别的收藏。
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
-- 中文维护注释（2026-09-15，拍卖悬浮助手设置命令）：偏好写入仍走 tools_auction
-- Persistence 事务；Feature 已启用时同步启停 AuctionSurfaceV3，以确保“关”不仅隐藏窗口，
-- 还释放 250ms 原生窗口观察任务。Surface Start/Stop 只管理只读观察，收藏与 AuctionQuery 完全独立。
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
    -- 中文维护注释（2026-09-15，Sidecar Preference Authority）：sidecarEnabled 与收藏/查询参数共用
    -- tools_auction 永久 Store，但它只拥有“是否启用拍卖悬浮助手”的偏好，不拥有 Widget 可见性。
    -- 旧 Store 缺字段由 ApplyAuctionState 补 true；显式 persistentKeys 把该兼容字段钉死，避免后续
    -- 清理 default 时误从持久化白名单移除。关闭后 AuctionSurface watcher 也停止，真正释放 250ms
    -- 观察任务；主页面收藏与显式 AuctionQuery 不依赖该 watcher。
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
-- 中文维护注释（2026-09-15，Sidecar Preference read facade）：Presentation 禁止直接读取
-- Feature.State；这个只读 facade 让 Sidecar Controller 在 250ms Surface 事件上 O(1) 获取偏好，
-- 不必调用 GetProjection() 深拷贝当前拍卖结果。它不返回 Store 本体，也不允许反向写状态。
function AuctionFavorites:IsSidecarEnabled() return self.State.sidecarEnabled~=false end
-- 中文维护注释（2026-09-30，presentation-private-state-1）：收藏列表的公开只读 facade。
-- 走共享读模型的归一逻辑，返回新表；Presentation 应调这个方法，而不是直接读 State。
function AuctionFavorites:GetFavorites() return ARM.Favorites(self) end
AuctionFavorites.SidecarPreferenceContractVersion=1
function AuctionFavorites:Search(value) return self.Commands:Search(value) end
function AuctionFavorites:AddFavorite(value) return self.Commands:AddFavorite(value) end
function AuctionFavorites:RemoveFavorite(index) return self.Commands:RemoveFavorite(index) end
function AuctionFavorites:HasConsumer(token) return self.Demand ~= nil and type(self.Demand.Has) == "function" and self.Demand:Has(token) == true end

AuctionFavorites.AuctionQueryContractVersion = 1
