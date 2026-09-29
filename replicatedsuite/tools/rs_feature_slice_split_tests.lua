------------------------------------------------------------------------
-- Phase 1 Batch A 源码故障域拆分契约回归（2026-09-28）
--
-- 目的：证明“从 rs_business_bridge.lua 拆到独立源码单元”只改变源码边界，
-- 不改变任何公开契约。逐项对应规划文档 §31 的 Feature 前后对照表。
--
-- 覆盖：tools_social（已拆）。tools_market_analysis 在共享 Auction 读模型
-- 归属确定前不在此文件断言，避免用错误 Authority 换取绿色。
--
-- 使用真实 Persistence / Demand / FeatureRuntime 替身（只替换 Native 与应用宿主），
-- 不读写用户 UDF，不声明 RU 实机行为。
------------------------------------------------------------------------
unpack = unpack or table.unpack
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; print('PASS split ' .. name)
    else failed = failed + 1; print('FAIL split ' .. name .. ': ' .. tostring(err)) end
end

-- 中文维护注释（2026-09-28，Phase 1 Batch E）：rs_business_bridge.lua 已在最后一批拆完退役。
-- “文件不存在”本身就是契约：它再出现就意味着有人把拆掉的 Feature 又塞回了一个巨型 chunk。
local function bridge_retired()
    local handle = io.open('features/rs_business_bridge.lua', 'rb')
    if handle == nil then return true end
    handle:close()
    return false
end

local H = dofile('tools/rs_udf_numeric_test_host.lua')
-- 中文维护注释：宿主返回的第三个值是它自己的内存盘替身，名字不能叫 io，
-- 否则会遮蔽 Lua 标准库 io，静态源码断言会直接报错而不是给出真实结论。
local S, P, _io = H.Boot()
S.SafeTraceback = debug.traceback

-- FeatureRuntime 替身：记录注册次数，用于证明“同一个 Feature 只注册一次”。
local registrations = {}
S.FeatureRuntime = {
    RegisterImplementation = function(_, id, impl)
        registrations[id] = (registrations[id] or 0) + 1
        registrations[id .. ':impl'] = impl
        return true
    end,
    IsEnabled = function() return true end,
}

-- X2Friend 替身：可切换的三种名单返回形态 + 写命令记录。
local friendCalls = { writes = {} }
local friendLists = { friends = {}, blocks = {}, mutes = {} }
local friendFail = {}
local friendValue = {}
-- 中文维护注释：能力读取失败在这套架构里表现为能力调用不成功（blocked / 冷却 / Native 抛错），
-- 而不是“方法返回 nil”。返回 nil 只是“本次没有名单数据”，必须与失败区分开，
-- 所以失败样本用 error() 触发 pcall 失败，与真实 CallCapability 语义一致。
_G.X2Friend = {
    GetFriendList = function(_, allMember)
        friendCalls.lastAllMember = allMember
        if friendFail.friends then error('friend_list_unavailable') end
        return friendLists.friends
    end,
    GetBlockList = function(_, ...) if friendFail.blocks then error('block_list_unavailable') end return friendLists.blocks end,
    GetMuteList = function(_, ...) if friendFail.mutes then error('mute_list_unavailable') end return friendLists.mutes end,
    IsMyFriend = function(_, name) friendCalls.lastIsFriend = name; return friendValue.isFriend end,
    BlockUser = function(_, name) friendCalls.writes[#friendCalls.writes + 1] = 'BlockUser:' .. tostring(name); return true end,
    UnblockUser = function(_, name) friendCalls.writes[#friendCalls.writes + 1] = 'UnblockUser:' .. tostring(name); return true end,
    MuteUser = function(_, name) friendCalls.writes[#friendCalls.writes + 1] = 'MuteUser:' .. tostring(name); return true end,
    UnmuteUser = function(_, name) friendCalls.writes[#friendCalls.writes + 1] = 'UnmuteUser:' .. tostring(name); return true end,
}

dofile('features/shared/rs_feature_slice_factory.lua')
assert(type(S.FeatureSliceFactory) == 'table', 'FeatureSliceFactory missing')
dofile('features/tools/social/rs_social_feature.lua')

local F = S.Features.tools_social
local function Read()
    return F.Authority:Refresh('test')
end

Test('tools_social 由独立文件注册且只注册一次', function()
    assert(type(F) == 'table', 'tools_social not registered by its own file')
    assert(registrations.tools_social == 1, 'expected exactly one registration, got ' .. tostring(registrations.tools_social))
    assert(registrations['tools_social:impl'] == F, 'registered implementation is not the Feature table')
end)

Test('Feature ID / Store ID / UpdateTopic / Demand owner 不变', function()
    assert(F.Id == 'tools_social', 'Feature Id changed')
    assert(F.storeId == 'v3.business.tools_social', 'storeId changed: ' .. tostring(F.storeId))
    assert(F.UpdateTopic == 'v3.business.tools_social.updated', 'UpdateTopic changed: ' .. tostring(F.UpdateTopic))
    assert(type(F.Demand) == 'table', 'Demand lease missing')
    local store = P:GetStore('v3.business.tools_social')
    assert(store ~= nil, 'v3.business.tools_social store not registered')
    assert(store.owner == 'v3.tools_social', 'store owner changed: ' .. tostring(store.owner))
    assert(store.lifetime == P.Lifetime.Permanent and store.scope == P.Scope.Account, 'store lifetime/scope changed')
    assert(store.schemaVersion == 1, 'store schemaVersion changed')
end)

Test('ApiDependencies 与 Registry 声明的 X2Friend 集合一致', function()
    local want = { 'X2Friend:IsMyFriend', 'X2Friend:GetFriendList', 'X2Friend:GetBlockList', 'X2Friend:GetMuteList',
        'X2Friend:BlockUser', 'X2Friend:UnblockUser', 'X2Friend:MuteUser', 'X2Friend:UnmuteUser' }
    local have = {}
    for _, value in ipairs(F.ApiDependencies) do have[value] = true end
    for _, value in ipairs(want) do assert(have[value] == true, 'missing api dependency ' .. value) end
    local count = 0
    for _ in pairs(have) do count = count + 1 end
    assert(count == #want, 'api dependency set changed: ' .. tostring(count))
end)

Test('公开 Commands 集合不变', function()
    for _, name in ipairs({ 'Refresh', 'Block', 'Unblock', 'Mute', 'Unmute', 'IsFriend' }) do
        assert(type(F.Commands[name]) == 'function', 'public command missing: ' .. name)
    end
    local count = 0
    for _ in pairs(F.Commands) do count = count + 1 end
    assert(count == 6, 'public command surface changed: ' .. tostring(count) .. ' commands')
end)

Test('Projection 顶层键不变且不泄露私有 State', function()
    local projection = F:GetProjection()
    local allowed = { revision = true, rows = true, status = true, error = true }
    for key in pairs(projection) do
        assert(allowed[key] == true, 'projection leaked an unexpected key: ' .. tostring(key))
    end
    -- 中文维护注释：error 属于“有错才出现”的键（nil 值在 Lua 里根本不存在于表中），
    -- 因此这里断言的是允许键集与 revision 的绑定关系，而不是强行要求 4 个键全在。
    assert(type(projection.revision) == 'number', 'projection.revision missing')
    assert(type(projection.rows) == 'table' and type(projection.status) == 'string', 'projection rows/status missing')
    assert(projection.revision == F.Authority.revision, 'projection revision is not the Authority revision')
    assert(F:GetProjection().revision == projection.revision, 'projection revision is not stable between reads')
end)

Test('读取路径：三种名单形态都归一，且好友查询传 allMember=true', function()
    friendLists.friends = { { name = '  Alice  ', online = true, level = 60 }, { name = 'Bob', isOnline = false, growLevel = 30.7 } }
    friendLists.blocks = { Carol = { name = 'Carol' }, Dave = 'Dave', count = 2 }
    friendLists.mutes = { '  Erin  ' }
    friendFail.friends, friendFail.blocks, friendFail.mutes = nil, nil, nil
    assert(Read())
    local rows = F.Authority.rows
    assert(F.Authority.status == 'ready', 'unexpected status: ' .. tostring(F.Authority.status))
    assert(friendCalls.lastAllMember == true, 'GetFriendList must be called with allMember=true')
    local seen = {}
    for _, row in ipairs(rows) do seen[row.memberName or row.name] = row end
    assert(seen.Alice and seen.Bob and seen.Carol and seen.Dave and seen.Erin, 'recognized members missing')
    assert(seen.Alice.text:find('等级 60', 1, true) ~= nil, 'level not normalized')
    assert(seen.Bob.text:find('离线', 1, true) ~= nil, 'offline flag not normalized')
    assert(seen.Bob.text:find('等级 30', 1, true) ~= nil, 'float level not floored')
    assert(seen.Carol ~= nil and seen.Dave ~= nil, 'name-keyed block list not normalized')
    assert(seen['count'] == nil, 'scalar hash metadata leaked as a member row')
end)

Test('读取路径：全部失败是 unavailable，绝不伪装成空名单', function()
    friendFail.friends, friendFail.blocks, friendFail.mutes = true, true, true
    assert(Read())
    assert(F.Authority.status == 'unavailable', 'failed read must not be empty/ready: ' .. tostring(F.Authority.status))
    assert(tostring(F.Authority.error):find('读取失败', 1, true) ~= nil, 'failure note missing')
end)

Test('读取路径：部分失败或未识别条目降级为 partial', function()
    friendFail.friends, friendFail.blocks, friendFail.mutes = true, nil, nil
    friendLists.blocks = { { nested = { no = 'name' } } }
    friendLists.mutes = {}
    assert(Read())
    assert(F.Authority.status == 'partial', 'expected partial, got ' .. tostring(F.Authority.status))
    local errorText = tostring(F.Authority.error)
    assert(errorText:find('读取失败', 1, true) ~= nil and errorText:find('未识别', 1, true) ~= nil, 'partial notes incomplete: ' .. errorText)
    local unrecognized
    for _, row in ipairs(F.Authority.rows) do if row.memberName == nil then unrecognized = row end end
    assert(unrecognized ~= nil and unrecognized.name:find('未识别条目', 1, true) ~= nil, 'unrecognized entry not surfaced')
    assert(not tostring(unrecognized.name):find('table:', 1, true), 'raw table address leaked into a row')
end)

Test('读取路径：超过 200 条必须显式截断而不是无限膨胀', function()
    friendLists.friends = {}
    for index = 1, 260 do friendLists.friends[index] = 'Member' .. tostring(index) end
    friendFail.friends, friendFail.blocks, friendFail.mutes = nil, nil, nil
    friendLists.blocks, friendLists.mutes = {}, {}
    assert(Read())
    assert(#F.Authority.rows == 200, 'row bound changed: ' .. tostring(#F.Authority.rows))
    assert(tostring(F.Authority.error):find('已截断显示', 1, true) ~= nil, 'truncation note missing')
end)

Test('读取路径：三个名单都为空才是 empty，nil 名单不伪造成员', function()
    friendFail.friends, friendFail.blocks, friendFail.mutes = nil, nil, nil
    friendLists.friends, friendLists.blocks, friendLists.mutes = {}, {}, {}
    assert(Read())
    assert(F.Authority.status == 'empty', 'expected empty, got ' .. tostring(F.Authority.status))
    -- 中文维护注释：Native 返回 nil 表示“本次没有名单数据”，不是失败，也不是 0 个好友的伪造事实；
    -- 该名单不得产生任何行，也不得被记成读取失败，因此整体仍是 empty（确实没有任何成员）。
    friendLists.friends = nil
    assert(Read())
    assert(#F.Authority.rows == 0, 'nil list fabricated rows: ' .. tostring(#F.Authority.rows))
    assert(F.Authority.status == 'empty', 'nil list must not fabricate a failure: ' .. tostring(F.Authority.status))
    assert(F.Authority.error == nil, 'nil list fabricated a failure note: ' .. tostring(F.Authority.error))
end)

Test('命令：写操作到达 X2Friend 且角色名被裁剪，空名被拒绝', function()
    friendCalls.writes = {}
    local ok = F.Commands:Block('  Carol  ')
    assert(ok == true, 'Block command rejected a valid name')
    assert(friendCalls.writes[1] == 'BlockUser:Carol', 'write did not reach X2Friend: ' .. tostring(friendCalls.writes[1]))
    assert(F.Commands:Unblock('Dave') == true and F.Commands:Mute('Erin') == true and F.Commands:Unmute('Frank') == true)
    assert(#friendCalls.writes == 4, 'write count changed: ' .. tostring(#friendCalls.writes))
    local rejected, reason = F.Commands:Block('   ')
    assert(rejected == false and reason == '角色名不能为空', 'empty name must be rejected')
    assert(#friendCalls.writes == 4, 'rejected write still reached Native')
end)

Test('命令：IsFriend 三种返回都被显式区分', function()
    friendValue.isFriend = true
    assert(select(2, F.Commands:IsFriend('Alice')) == '是好友', 'true result misreported')
    friendValue.isFriend = false
    assert(select(2, F.Commands:IsFriend('Alice')) == '非好友', 'false result misreported')
    friendValue.isFriend = nil
    assert(tostring(select(2, F.Commands:IsFriend('Alice'))):find('待 RU 实证', 1, true) ~= nil, 'unknown shape must stay explicit')
    assert(friendCalls.lastIsFriend == 'Alice', 'IsMyFriend must receive the trimmed name')
end)

Test('生命周期：没有 Scheduler task / 事件订阅副作用', function()
    local tasks = 0
    for _ in pairs(S.Scheduler.tasks or {}) do tasks = tasks + 1 end
    assert(tasks == 0, 'split Feature created scheduler tasks: ' .. tostring(tasks))
    assert(type(F.AcquireConsumer) == 'function' and type(F.ReleaseConsumer) == 'function', 'demand lifecycle missing')
end)

Test('静态：bridge 已退役，tools_social 由独立文件唯一持有', function()
    -- 中文维护注释（2026-09-28，Phase 1 Batch E 更新）：rs_business_bridge.lua 已在最后一批拆完删除，
    -- “不再双注册”由更强的两个事实保证：bridge 文件不存在 + 全树只有一个 NewFeature("tools_social"。
    assert(bridge_retired(), 'rs_business_bridge.lua must stay retired')
    local social = assert(io.open('features/tools/social/rs_social_feature.lua', 'rb'))
    local socialText = social:read('*a'); social:close()
    assert(socialText:find('NewFeature("tools_social"', 1, true) ~= nil, 'split file does not register the Feature')
end)

Test('静态：X2Friend 写能力仍由 core 能力表登记（写路径未被拆分绕过）', function()
    local handle = assert(io.open('core/rs_api_capabilities.lua', 'rb'))
    local text = handle:read('*a'); handle:close()
    for _, capability in ipairs({ 'X2Friend:BlockUser', 'X2Friend:UnblockUser', 'X2Friend:MuteUser', 'X2Friend:UnmuteUser' }) do
        assert(text:find(capability, 1, true) ~= nil, 'capability record missing: ' .. capability)
    end
end)

------------------------------------------------------------------------
-- tools_market_analysis：与 tools_auction 共用 AuctionReadModel，
-- 但不允许共享同一份命令表实例，也不允许反向依赖 tools_auction。
------------------------------------------------------------------------
local auctionSnapshot = { status = 'idle', rows = {}, count = 0 }
local auctionSearchCalls = {}
S.Services.AuctionQueryV3 = {
    GetSnapshot = function(_, requester) return auctionSnapshot end,
    Search = function(_, requester, keyword, options)
        auctionSearchCalls[#auctionSearchCalls + 1] = { requester = requester, keyword = keyword, exact = options and options.exactMatch, limit = options and options.resultLimit }
        return true, 'waiting'
    end,
}
-- 中文维护注释：按 toc.g 顺序加载拍卖共享读模型，再加载它的新消费方。
dofile('features/tools/auction/rs_auction_read_model.lua')
assert(type(S.AuctionReadModel) == 'table', 'AuctionReadModel missing')
dofile('features/tools/market_analysis/rs_market_analysis_feature.lua')
local Market = S.Features.tools_market_analysis

Test('tools_market_analysis 由独立文件注册且只注册一次', function()
    assert(type(Market) == 'table', 'tools_market_analysis not registered by its own file')
    assert(registrations.tools_market_analysis == 1, 'expected exactly one registration, got ' .. tostring(registrations.tools_market_analysis))
    assert(registrations['tools_market_analysis:impl'] == Market, 'registered implementation is not the Feature table')
end)

Test('market：Feature ID / Store ID / UpdateTopic / 契约版本不变', function()
    assert(Market.Id == 'tools_market_analysis', 'Feature Id changed')
    assert(Market.storeId == 'v3.business.tools_market_analysis', 'storeId changed: ' .. tostring(Market.storeId))
    assert(Market.UpdateTopic == 'v3.business.tools_market_analysis.updated', 'UpdateTopic changed')
    assert(Market.AuctionQueryContractVersion == 1, 'AuctionQueryContractVersion changed')
    local store = assert(P:GetStore('v3.business.tools_market_analysis'), 'market store not registered')
    assert(store.owner == 'v3.tools_market_analysis' and store.schemaVersion == 1, 'market store owner/schema changed')
    assert(type(Market.Demand) == 'table', 'Demand lease missing')
end)

Test('market：ApiDependencies 与公开 Commands 不变', function()
    local want = { 'X2Auction:SearchAuctionArticle', 'X2Auction:GetSearchedItemCount', 'X2Auction:GetSearchedItemInfo' }
    local have = {}
    for _, value in ipairs(Market.ApiDependencies) do have[value] = true end
    for _, value in ipairs(want) do assert(have[value] == true, 'missing api dependency ' .. value) end
    local count = 0
    for _ in pairs(have) do count = count + 1 end
    assert(count == #want, 'market api dependency set changed: ' .. tostring(count))
    for _, name in ipairs({ 'Refresh', 'SetKeyword', 'SetExactMatch', 'SetResultLimit', 'Search' }) do
        assert(type(Market.Commands[name]) == 'function', 'market command missing: ' .. name)
    end
    local commandCount = 0
    for _ in pairs(Market.Commands) do commandCount = commandCount + 1 end
    assert(commandCount == 5, 'market command surface changed: ' .. tostring(commandCount))
end)

Test('market：共享读模型提供独立实例，不共用同一张命令表', function()
    local first, second = S.AuctionReadModel.SettingsCommands(), S.AuctionReadModel.SettingsCommands()
    assert(first ~= second, 'shared read model returned one shared command table')
    assert(type(first.SetKeyword) == 'function' and type(second.Search) == 'function', 'shared command table incomplete')
    assert(type(Market.HasConsumer) == 'function' and type(Market.AcquireConsumer) == 'function', 'demand facade missing')
end)

Test('market：投影同时保留 NewFeature 基础键与拍卖读模型扩展键', function()
    auctionSnapshot = { status = 'ready', rows = { { key = 'item:1', name = '货物', price = 100 } }, count = 1, contract = 1 }
    Market.Authority:Refresh('test')
    local projection = Market:GetProjection()
    for _, key in ipairs({ 'revision', 'rows', 'status', 'keyword', 'favoriteMax', 'resultCount', 'quoteStatus', 'nativeSync' }) do
        if projection[key] == nil then error('projection key missing: ' .. key) end
    end
    assert(projection.resultCount == 1, 'resultCount not mirrored from the shared snapshot')
    assert(projection.favoriteMax == S.AuctionReadModel.AUCTION_FAVORITE_MAX, 'favoriteMax must come from the read model')
    assert(projection.rows[1].kind == 'result', 'snapshot rows must be tagged as results')
end)

Test('market：无结果时给“非历史成交价”提示，失败/等待状态不被伪装', function()
    auctionSnapshot = { status = 'idle', rows = {}, count = 0 }
    Market.Authority:Refresh('test')
    assert(#Market.Authority.rows == 1 and Market.Authority.rows[1].key == 'market:hint', 'empty result hint missing')
    assert(tostring(Market.Authority.rows[1].text):find('非历史成交价', 1, true) ~= nil
        or tostring(Market.Authority.rows[1].text):find('不把挂单伪装成历史成交价', 1, true) ~= nil, 'hint wording changed')

    auctionSnapshot = { status = 'waiting', rows = {}, count = 0 }
    Market.Authority:Refresh('test')
    assert(Market.Authority.status == 'partial', 'waiting query must project as partial: ' .. tostring(Market.Authority.status))
    assert(#Market.Authority.rows == 0, 'waiting query must not show the empty-result hint')

    auctionSnapshot = { status = 'failed', rows = {}, count = 0, error = 'query_failed' }
    Market.Authority:Refresh('test')
    assert(Market.Authority.status == 'unavailable', 'failed query must project as unavailable: ' .. tostring(Market.Authority.status))
    assert(Market.Authority.error == 'query_failed', 'query error not propagated')
end)

Test('market：Search 命令经归一化后交给共享 AuctionQueryV3', function()
    -- 中文维护注释：真实使用顺序是 Feature 先 Initialize（读取 Store）再执行命令；
    -- 未加载时 Persistence 会按 default 应用一次，直接改内存 State 会被覆盖 —— 这是既有契约，
    -- 不是本轮拆分引入的行为，所以测试必须复现真实顺序。
    assert(Market:Initialize(), 'market Feature store load failed')
    auctionSearchCalls = {}
    Market.State.exactMatch = true
    Market.State.resultLimit = 25
    local ok = Market.Commands:Search('  布料  ')
    assert(ok == true, 'Search command rejected a valid keyword')
    assert(#auctionSearchCalls == 1, 'Search did not reach AuctionQueryV3 exactly once')
    assert(auctionSearchCalls[1].keyword == '布料', 'keyword not trimmed: ' .. tostring(auctionSearchCalls[1].keyword))
    assert(auctionSearchCalls[1].exact == true and auctionSearchCalls[1].limit == 25, 'search options not forwarded')
    assert(auctionSearchCalls[1].requester == 'tools_market_analysis', 'search requester identity changed')
    local rejected = Market.Commands:SetResultLimit(999)
    assert(rejected == true, 'result limit must be clamped rather than rejected')
end)

Test('静态：bridge 不再注册 tools_market_analysis / tools_auction 仍由 bridge 拥有', function()
    assert(bridge_retired(), 'rs_business_bridge.lua must stay retired')
    local readModel = assert(io.open('features/tools/auction/rs_auction_read_model.lua', 'rb'))
    local readModelText = readModel:read('*a'); readModel:close()
    -- 中文维护注释：共享读模型把投影定义为 R.Projection（表方法），不是 local function；
    -- 断言它仍归读模型所有，而不是被任何 Feature 文件复制。
    assert(readModelText:find('function R.Projection(feature)', 1, true) ~= nil,
        'the shared auction projection must stay in the read model, not in a Feature file')
    for _, path in ipairs({ 'features/tools/auction/rs_auction_read_model.lua',
        'features/tools/market_analysis/rs_market_analysis_feature.lua',
        'features/tools/social/rs_social_feature.lua' }) do
        local probe = assert(io.open(path, 'rb')); probe:close()
    end
end)

------------------------------------------------------------------------
-- Phase 1 Batch B：combat_siege_readiness / tools_reinforce_analysis / tools_portal_profiles
------------------------------------------------------------------------
local reinforceCalls = {}
local reinforceHost = {
    GetTotalReinforceLevel = function(_, ...) reinforceCalls[#reinforceCalls+1] = { 'GetTotalReinforceLevel', ... }; return 137 end,
    SuitableLevelForEquipSlotReinforce = function(_, ...) reinforceCalls[#reinforceCalls+1] = { 'SuitableLevelForEquipSlotReinforce', ... }; return 120 end,
    GetAttributeTotalLevel = function(_, attributeType, ...) reinforceCalls[#reinforceCalls+1] = { 'GetAttributeTotalLevel', attributeType, ... }; return 48 end,
    GetNextSetApplyLevel = function(_, attributeType, ...) reinforceCalls[#reinforceCalls+1] = { 'GetNextSetApplyLevel', attributeType, ... }; return 50 end,
    HasNextSetEffect = function(_, attributeType, ...) reinforceCalls[#reinforceCalls+1] = { 'HasNextSetEffect', attributeType, ... }; return true end,
    GetBundleEffectTopLevel = function(_, ...) reinforceCalls[#reinforceCalls+1] = { 'GetBundleEffectTopLevel', ... }; return 7 end,
}
_G.ESRA_OFFENCE, _G.ESRA_DEFENCE, _G.ESRA_SUPPORT = 'ESRA_OFFENCE', 'ESRA_DEFENCE', 'ESRA_SUPPORT'
_G.X2EquipSlotReinforce = reinforceHost
dofile('features/combat/siege_readiness/rs_siege_readiness_feature.lua')
dofile('features/tools/reinforce_analysis/rs_reinforce_analysis_feature.lua')
dofile('features/tools/portal_profiles/rs_portal_profiles_feature.lua')
local Siege = S.Features.combat_siege_readiness
local ReinforceFeature = S.Features.tools_reinforce_analysis
local Portal = S.Features.tools_portal_profiles

Test('BatchB：三个 Feature 各自独立注册且都只注册一次', function()
    for id, feature in pairs({ combat_siege_readiness = Siege, tools_reinforce_analysis = ReinforceFeature, tools_portal_profiles = Portal }) do
        assert(type(feature) == 'table', id .. ' not registered by its own file')
        assert(registrations[id] == 1, id .. ' expected exactly one registration, got ' .. tostring(registrations[id]))
        assert(registrations[id .. ':impl'] == feature, id .. ' registered implementation mismatch')
    end
end)

Test('BatchB：Feature ID / Store ID / UpdateTopic / Demand owner 不变', function()
    local cases = {
        { Siege, 'combat_siege_readiness', 'v3.business.combat_siege_readiness', 'v3.combat_siege_readiness' },
        { ReinforceFeature, 'tools_reinforce_analysis', 'v3.business.tools_reinforce_analysis', 'v3.tools_reinforce_analysis' },
        { Portal, 'tools_portal_profiles', 'v3.business.tools_portal_profiles', 'v3.tools_portal_profiles' },
    }
    for _, case in ipairs(cases) do
        local feature, id, storeId, owner = case[1], case[2], case[3], case[4]
        assert(feature.Id == id, 'Feature Id changed: ' .. tostring(feature.Id))
        assert(feature.storeId == storeId, id .. ' storeId changed: ' .. tostring(feature.storeId))
        assert(feature.UpdateTopic == 'v3.business.' .. id .. '.updated', id .. ' UpdateTopic changed')
        local store = assert(P:GetStore(storeId), id .. ' store not registered')
        assert(store.owner == owner, id .. ' store owner changed: ' .. tostring(store.owner))
        assert(store.schemaVersion == 1 and store.lifetime == P.Lifetime.Permanent, id .. ' store schema/lifetime changed')
        assert(type(feature.Demand) == 'table', id .. ' Demand lease missing')
    end
end)

Test('BatchB：命令面只有 Refresh，且不新增 Scheduler 任务/事件订阅', function()
    for _, feature in ipairs({ Siege, ReinforceFeature, Portal }) do
        local count = 0
        for name, fn in pairs(feature.Commands) do
            count = count + 1
            assert(name == 'Refresh' and type(fn) == 'function', feature.Id .. ' unexpected command: ' .. tostring(name))
        end
        assert(count == 1, feature.Id .. ' command surface changed: ' .. tostring(count))
    end
    local tasks = 0
    for _ in pairs(S.Scheduler.tasks or {}) do tasks = tasks + 1 end
    assert(tasks == 0, 'Batch B split created scheduler tasks: ' .. tostring(tasks))
end)

Test('BatchB：Runtime Blocked 两个 Feature 暴露精确阻塞原因而不是空壳', function()
    for _, case in ipairs({
        { Siege, 'GetEquippedItemTooltipInfo 的槽位/装分字段和攻城上下文未在当前 RU 实机确认；不猜测装备状态' },
        { Portal, 'X2Option optionType/返回值语义和个人传送候选集合未在当前 RU 客户端验证；禁止执行猜测写入' },
    }) do
        local feature, blocker = case[1], case[2]
        assert(feature.Authority:Refresh('test'))
        assert(feature.Authority.status == 'runtime_blocked', feature.Id .. ' status changed: ' .. tostring(feature.Authority.status))
        assert(feature.Authority.error == blocker, feature.Id .. ' blocker text changed')
        assert(#feature.Authority.rows == 1 and feature.Authority.rows[1].key == feature.Id .. ':blocked', feature.Id .. ' blocker row shape changed')
        assert(feature.Authority.rows[1].text == blocker, feature.Id .. ' blocker row text changed')
        assert(feature.Authority.rows[1].statusText == 'Runtime Blocked', feature.Id .. ' blocker row label changed')
        local projection = feature:GetProjection()
        assert(projection.status == 'runtime_blocked' and projection.revision >= 1, feature.Id .. ' projection does not surface the blocker')
    end
end)

Test('BatchB：被阻塞 Feature 不声明实现层依赖，Registry 才是它们的依赖 Authority', function()
    -- 中文维护注释：这两个 Feature 是 blocker-only spec，没有实现层 override，
    -- 因此 feature.ApiDependencies 为空、FeatureRuntime 走 Registry 声明（native audit 已校验 parity）。
    assert(#Siege.ApiDependencies == 0, 'siege must not override api dependencies')
    assert(#Portal.ApiDependencies == 0, 'portal must not override api dependencies')
    local want = { 'X2EquipSlotReinforce:GetTotalReinforceLevel', 'X2EquipSlotReinforce:GetAttributeTotalLevel',
        'X2EquipSlotReinforce:GetNextSetApplyLevel', 'X2EquipSlotReinforce:HasNextSetEffect',
        'X2EquipSlotReinforce:SuitableLevelForEquipSlotReinforce', 'X2EquipSlotReinforce:GetBundleEffectTopLevel' }
    local have = {}
    for _, value in ipairs(ReinforceFeature.ApiDependencies) do have[value] = true end
    for _, value in ipairs(want) do assert(have[value] == true, 'reinforce missing api dependency ' .. value) end
    local count = 0
    for _ in pairs(have) do count = count + 1 end
    assert(count == #want, 'reinforce api dependency set changed: ' .. tostring(count))
end)

Test('BatchB：强化聚合读取 ready 阶梯，且逐槽位始终 Runtime Blocked', function()
    assert(ReinforceFeature:Initialize(), 'reinforce store load failed')
    reinforceCalls = {}
    assert(ReinforceFeature.Authority:Refresh('test'))
    assert(ReinforceFeature.Authority.status == 'ready', 'expected ready, got ' .. tostring(ReinforceFeature.Authority.status))
    local byKey = {}
    for _, row in ipairs(ReinforceFeature.Authority.rows) do byKey[row.key] = row end
    for _, key in ipairs({ 'reinforce:total', 'reinforce:suitable', 'reinforce:attr:offence', 'reinforce:attr:defence',
        'reinforce:attr:support', 'reinforce:bundle', 'reinforce:slot_blocked' }) do
        assert(byKey[key] ~= nil, 'missing aggregate row: ' .. key)
    end
    assert(byKey['reinforce:total'].text:find('等级 137', 1, true) ~= nil, 'total level not projected')
    assert(byKey['reinforce:attr:offence'].text:find('合计等级 48', 1, true) ~= nil, 'attribute total not projected')
    assert(byKey['reinforce:attr:offence'].text:find('下一套装档位 50', 1, true) ~= nil, 'next set level not projected')
    assert(byKey['reinforce:attr:offence'].text:find('存在下一档套装效果', 1, true) ~= nil, 'set effect state not projected')
    assert(byKey['reinforce:slot_blocked'].statusText == 'Runtime Blocked', 'per-slot row must stay Runtime Blocked')
    assert(tostring(byKey['reinforce:slot_blocked'].text):find('不会枚举或猜测槽位', 1, true) ~= nil, 'per-slot honesty note changed')
end)

Test('BatchB：强化读取从不探测 equipSlotIndex（安全边界）', function()
    -- 中文维护注释：这是搬迁前就成立的安全契约 —— 只允许无参 getter 与 ESRA_* 常参 getter。
    -- 断言方式：记录每次 Native 调用的实参，全部必须是空或已导出的 ESRA_* 常量，绝不出现整数槽位。
    local allowed = { ESRA_OFFENCE = true, ESRA_DEFENCE = true, ESRA_SUPPORT = true }
    assert(#reinforceCalls > 0, 'no native call was recorded')
    for _, call in ipairs(reinforceCalls) do
        for index = 2, #call do
            local value = call[index]
            assert(allowed[value] == true,
                'forbidden argument probed in ' .. tostring(call[1]) .. ': ' .. tostring(value))
        end
    end
end)

Test('BatchB：任一聚合 getter 失败降级为 partial 并给出失败明细', function()
    local original = reinforceHost.GetAttributeTotalLevel
    reinforceHost.GetAttributeTotalLevel = function() error('reinforce_host_unavailable') end
    assert(ReinforceFeature.Authority:Refresh('test'))
    reinforceHost.GetAttributeTotalLevel = original
    assert(ReinforceFeature.Authority.status == 'partial', 'expected partial, got ' .. tostring(ReinforceFeature.Authority.status))
    local errorText = tostring(ReinforceFeature.Authority.error)
    assert(errorText:find('读取失败', 1, true) ~= nil, 'failure detail missing: ' .. errorText)
    assert(errorText:find('Runtime Blocked', 1, true) ~= nil, 'per-slot honesty note missing from notes')
    local byKey = {}
    for _, row in ipairs(ReinforceFeature.Authority.rows) do byKey[row.key] = row end
    assert(byKey['reinforce:slot_blocked'] ~= nil, 'per-slot row must survive a partial read')
end)

Test('BatchB：ESRA_* 常量未导出时如实标注，不伪造数值', function()
    local saved = _G.ESRA_SUPPORT
    _G.ESRA_SUPPORT = nil
    assert(ReinforceFeature.Authority:Refresh('test'))
    _G.ESRA_SUPPORT = saved
    local support
    for _, row in ipairs(ReinforceFeature.Authority.rows) do if row.key == 'reinforce:attr:support' then support = row end end
    assert(support ~= nil, 'support row lost when the constant is missing')
    assert(tostring(support.text):find('未导出', 1, true) ~= nil, 'missing constant must be labeled, not fabricated')
    assert(support.statusText == '未提供', 'missing constant status changed: ' .. tostring(support.statusText))
end)

Test('BatchB：SlotProbeRuntimeBlocked 仍为 true，且 Authority 已在 Feature acceptance', function()
    assert(ReinforceFeature.SlotProbeRuntimeBlocked == true, 'SlotProbeRuntimeBlocked must stay true')
    -- 中文维护注释（Phase 3 Batch F，2026-09-29，core-feature-decoupling-1）：该真值原先由 FoundationGate
    -- 的 v3_feature_truth_contract 直接检查；Authority 已搬到 Feature 自己的 acceptance。断言改成
    -- “Foundation 不得再引用、acceptance 必须引用”——强度不变，而 Core 不再认识这个业务 Feature。
    local handle = assert(io.open('core/rs_foundation_gate.lua', 'rb'))
    local gate = handle:read('*a'); handle:close()
    assert(gate:find('SlotProbeRuntimeBlocked', 1, true) == nil,
        'FoundationGate must no longer reference the reinforce runtime-block flag')
    assert(gate:find('slot_probe_runtime_block', 1, true) == nil,
        'FoundationGate must no longer own the reinforce truth contract')
    local acc = assert(io.open('features/tools/reinforce_analysis/rs_reinforce_analysis_acceptance.lua', 'rb'))
    local accText = acc:read('*a'); acc:close()
    assert(accText:find('SlotProbeRuntimeBlocked', 1, true) ~= nil
        and accText:find('slot_probe_runtime_block', 1, true) ~= nil,
        'the reinforce acceptance must own the runtime-block truth contract')
end)

Test('BatchB：X2EquipSlotReinforce 未导出时 fail-closed 为 unavailable', function()
    -- 中文维护注释：`ReinforceApi` 是加载期捕获的宿主引用，无法在已加载的实例上改。
    -- 因此用第二个独立 ReplicatedSuite（H.Boot 重建）验证“宿主未导出”这一 fail-closed 分支，
    -- 测完立刻恢复全局，避免影响其它断言。
    local outerSuite = ReplicatedSuite
    local savedHost = _G.X2EquipSlotReinforce
    local probeSuite = H.Boot()
    _G.X2EquipSlotReinforce = nil
    ReplicatedSuite = probeSuite
    dofile('features/shared/rs_feature_slice_factory.lua')
    dofile('features/tools/reinforce_analysis/rs_reinforce_analysis_feature.lua')
    local probeFeature = probeSuite.Features.tools_reinforce_analysis
    -- 中文维护注释：Authority:Refresh 只返回 true，状态/错误必须从 Authority.status / .error 读取。
    assert(probeFeature.Authority:Refresh('test'))
    local status, err = probeFeature.Authority.status, probeFeature.Authority.error
    ReplicatedSuite = outerSuite
    _G.X2EquipSlotReinforce = savedHost
    assert(status == 'unavailable', 'missing host must fail closed, got ' .. tostring(status))
    assert(tostring(err):find('未导出', 1, true) ~= nil, 'missing host reason changed: ' .. tostring(err))
    assert(#probeFeature.Authority.rows == 0, 'missing host must not fabricate rows')
    assert(probeFeature.SlotProbeRuntimeBlocked == true, 'flag must be set even when the host is missing')
end)

Test('静态：bridge 不再注册 Batch B 三个 Feature', function()
    assert(bridge_retired(), 'rs_business_bridge.lua must stay retired')
    for _, id in ipairs({ 'combat_siege_readiness', 'tools_reinforce_analysis', 'tools_portal_profiles' }) do
        assert(registrations[id] == 1, id .. ' must stay registered exactly once')
    end
    for _, path in ipairs({ 'features/combat/siege_readiness/rs_siege_readiness_feature.lua',
        'features/tools/reinforce_analysis/rs_reinforce_analysis_feature.lua',
        'features/tools/portal_profiles/rs_portal_profiles_feature.lua' }) do
        local probe = assert(io.open(path, 'rb')); probe:close()
    end
end)

------------------------------------------------------------------------
-- Phase 1 Batch C：combat_boss_alerts / combat_target_monitor /
--                   combat_buff_cap / combat_raid_recruitment
------------------------------------------------------------------------
local unitHost = { calls = {} }
_G.X2Unit = _G.X2Unit or {}
_G.X2Unit.GetTargetUnitId = function(_, ...) unitHost.calls[#unitHost.calls+1] = { 'GetTargetUnitId', ... }; return 4242 end
_G.X2Unit.UnitName = function(_, unit, ...) unitHost.calls[#unitHost.calls+1] = { 'UnitName', unit, ... }; return '训练假人' end
_G.X2Unit.UnitDistance = function(_, unit, ...) unitHost.calls[#unitHost.calls+1] = { 'UnitDistance', unit, ... }; return 12.5 end
_G.X2Unit.UnitBuffCount = function(_, scope, ...) unitHost.calls[#unitHost.calls+1] = { 'UnitBuffCount', scope, ... }; return 3 end
_G.X2Team = _G.X2Team or {}
_G.X2Team.RaidApplicantList = function(_, ...) unitHost.calls[#unitHost.calls+1] = { 'RaidApplicantList', ... }; return { { name = '申请人甲', level = 55 }, second = { name = '申请人乙', gearScore = 8000 } } end
_G.X2Team.RaidRecruitDel = function(_, ...) unitHost.calls[#unitHost.calls+1] = { 'RaidRecruitDel', ... }; return true end

-- 中文维护注释：boss_alerts 在**加载期**把 S.Data.BossAlerts 读成内部规则索引，因此目录必须先于 dofile 存在；
-- 没有规则目录时它不会启动观察任务（这是正确的“无规则即无观察”行为，不是缺陷）。
S.Data = S.Data or {}
S.Data.BossAlerts = {
    { key = 'split:cast', kind = 'cast', names = { '测试读条' }, alert = '测试读条', style = 'countdown' },
    { key = 'split:debuff', kind = 'debuff', debuffId = 9001, alert = '测试减益', style = 'bigtext' },
}

dofile('features/combat/boss_alerts/rs_boss_alerts_feature.lua')
dofile('features/combat/target_monitor/rs_target_monitor_feature.lua')
dofile('features/combat/buff_cap/rs_buff_cap_feature.lua')
dofile('features/combat/raid_recruitment/rs_raid_recruitment_feature.lua')
local BossAlerts = S.Features.combat_boss_alerts
local TargetMonitor = S.Features.combat_target_monitor
local BuffCap = S.Features.combat_buff_cap
local RaidRecruit = S.Features.combat_raid_recruitment

Test('BatchC：四个 Feature 各自独立注册且都只注册一次', function()
    for id, feature in pairs({ combat_boss_alerts = BossAlerts, combat_target_monitor = TargetMonitor,
        combat_buff_cap = BuffCap, combat_raid_recruitment = RaidRecruit }) do
        assert(type(feature) == 'table', id .. ' not registered by its own file')
        assert(registrations[id] == 1, id .. ' expected exactly one registration, got ' .. tostring(registrations[id]))
        assert(registrations[id .. ':impl'] == feature, id .. ' registered implementation mismatch')
    end
end)

Test('BatchC：Feature ID / Store ID / owner / UpdateTopic / Demand 不变', function()
    local cases = {
        { BossAlerts, 'combat_boss_alerts', 'v3.combat_boss_alerts' },
        { TargetMonitor, 'combat_target_monitor', 'v3.combat_target_monitor' },
        { BuffCap, 'combat_buff_cap', 'v3.combat_buff_cap' },
        { RaidRecruit, 'combat_raid_recruitment', 'v3.combat_raid_recruitment' },
    }
    for _, case in ipairs(cases) do
        local feature, id, owner = case[1], case[2], case[3]
        assert(feature.Id == id, 'Feature Id changed: ' .. tostring(feature.Id))
        assert(feature.storeId == 'v3.business.' .. id, id .. ' storeId changed')
        assert(feature.UpdateTopic == 'v3.business.' .. id .. '.updated', id .. ' UpdateTopic changed')
        local store = assert(P:GetStore(feature.storeId), id .. ' store not registered')
        assert(store.owner == owner, id .. ' store owner changed: ' .. tostring(store.owner))
        assert(store.schemaVersion == 1 and store.lifetime == P.Lifetime.Permanent, id .. ' store schema/lifetime changed')
        assert(type(feature.Demand) == 'table', id .. ' Demand lease missing')
    end
    assert(TargetMonitor.ObservationContractVersion == 1, 'target monitor observation contract changed')
    assert(BossAlerts.HudContractVersion == 4, 'boss HUD contract version changed')
    assert(BossAlerts.RealtimeFactBridgeContractVersion == 2, 'boss realtime bridge contract changed')
    assert(BossAlerts.RuleManagementContractVersion == 1, 'boss rule management contract changed')
    assert(BuffCap.PersonalReminderContractVersion == 1, 'buff cap reminder contract changed')
end)

Test('BatchC：公开 Commands 集合不变', function()
    local expected = {
        { BossAlerts, { 'Refresh', 'SetRuleEnabled', 'SetAllRulesEnabled', 'TestRule', 'SetHudEnabled', 'SetHudAnchor',
            'SetHudFontSize', 'SetHudDurationMs', 'SetHudOffsetX', 'SetHudOffsetY', 'SetHudWidth', 'ResetHudLayout',
            'SetHudEditing', 'SetShowObservedCasts', 'TestBigText', 'TestCountdown', 'SimulateCast', 'SimulateDebuff' } },
        { TargetMonitor, { 'Refresh' } },
        { BuffCap, { 'Refresh', 'SetReminderEnabled', 'SetThreshold', 'ResetPeaks', 'TestReminder' } },
        { RaidRecruit, { 'Refresh', 'Create', 'Close', 'Accept', 'Reject' } },
    }
    for _, case in ipairs(expected) do
        local feature, names = case[1], case[2]
        local wanted = {}
        for _, name in ipairs(names) do wanted[name] = true end
        for _, name in ipairs(names) do
            assert(type(feature.Commands[name]) == 'function', feature.Id .. ' command missing: ' .. name)
        end
        for name in pairs(feature.Commands) do
            assert(wanted[name] == true, feature.Id .. ' unexpected command: ' .. tostring(name))
        end
    end
end)

Test('BatchC：target_monitor 距离任务只在消费期存在且 cadence 不变', function()
    assert(TargetMonitor:Enable(), 'target monitor enable failed')
    assert(TargetMonitor:AcquireConsumer('split_test'))
    local task = assert(S.Scheduler.tasks.v3_business_target_monitor_distance, 'distance task missing after acquire')
    assert(task.ms == 500 or task.interval == 500, 'distance cadence changed: ' .. tostring(task.ms or task.interval))
    assert(S.Events:CountOwner(TargetMonitor) == 1, 'TARGET_CHANGED subscription missing')
    assert(TargetMonitor:ReleaseConsumer('split_test'))
    assert(S.Scheduler.tasks.v3_business_target_monitor_distance == nil, 'distance task must be removed at final release')
    assert(S.Events:CountOwner(TargetMonitor) == 0, 'TARGET_CHANGED subscription not released')
    assert(TargetMonitor:Disable(), 'target monitor disable failed')
end)

Test('BatchC：target_monitor 读取走 X2Unit 只读事实，无目标时如实 empty', function()
    unitHost.calls = {}
    assert(TargetMonitor.Authority:Refresh('test'))
    assert(TargetMonitor.Authority.status == 'ready', 'expected ready, got ' .. tostring(TargetMonitor.Authority.status))
    local row = TargetMonitor.Authority.rows[1]
    assert(row.key == 'target' and row.text:find('4242', 1, true) ~= nil, 'target id not projected')
    assert(row.name == '训练假人', 'target name not trimmed: ' .. tostring(row.name))
    for _, call in ipairs(unitHost.calls) do
        assert(call[1] ~= 'UnitName' or call[2] == 'target', 'unit name must be read for target only')
        assert(call[1] ~= 'UnitDistance' or call[2] == 'target', 'unit distance must be read for target only')
    end
    local savedName = _G.X2Unit.UnitName
    _G.X2Unit.UnitName = function() return nil end
    local savedId = _G.X2Unit.GetTargetUnitId
    _G.X2Unit.GetTargetUnitId = function() return nil end
    assert(TargetMonitor.Authority:Refresh('test'))
    _G.X2Unit.UnitName, _G.X2Unit.GetTargetUnitId = savedName, savedId
    assert(TargetMonitor.Authority.status == 'empty', 'no-target read must be empty, got ' .. tostring(TargetMonitor.Authority.status))
    assert(#TargetMonitor.Authority.rows == 0, 'no-target read must not fabricate rows')
end)

Test('BatchC：buff_cap 两个任务名与释放语义不变', function()
    assert(BuffCap:Enable(), 'buff cap enable failed')
    assert(BuffCap:AcquireConsumer('split_test'))
    assert(S.Scheduler.tasks.v3_business_buff_cap_poll, 'buff cap fallback poll task missing')
    assert(S.Events:CountOwner(BuffCap) == 1, 'BUFF_UPDATE subscription missing')
    assert(BuffCap:ReleaseConsumer('split_test'))
    assert(S.Scheduler.tasks.v3_business_buff_cap_poll == nil, 'buff cap poll task must be removed at final release')
    assert(BuffCap:Disable(), 'buff cap disable failed')
    assert(S.Scheduler.tasks.v3_business_buff_cap_refresh == nil, 'buff cap edge task must not survive disable')
end)

Test('BatchC：boss_alerts 观察任务由服务租约驱动并在停用时释放', function()
    local held, released = {}, {}
    S.Services.CastingObservationV3 = {
        AcquireConsumer = function(_, token) held[#held+1] = token; return true end,
        ReleaseConsumer = function(_, token) released[#released+1] = token; return true end,
        GetCoverage = function() return { available = false } end,
        Get = function() return nil end,
    }
    S.Services.AuraObservationV3 = {
        AcquireConsumer = function(_, token) held[#held+1] = token; return true end,
        ReleaseConsumer = function(_, token) released[#released+1] = token; return true end,
        Get = function() return nil end,
    }
    S.Services.Alerts = {
        Maintain = function() return true end, Push = function() return true end,
        HideOwner = function() return true end, ConfigureOwner = function() return true end,
        Describe = function() return { ownerCount = 0 } end,
    }
    assert(BossAlerts:Enable(), 'boss alerts enable failed')
    -- 中文维护注释：onEnable 只取 runtime 租约；观察任务由“有消费者 + 有启用规则”共同决定，
    -- 所以这里必须再取一个业务消费者才能真正证明任务生命周期。
    assert(BossAlerts:AcquireConsumer('split_test'), 'boss alerts consumer acquire failed')
    local task = assert(S.Scheduler.tasks.v3_business_boss_alert_observe, 'boss observe task missing after acquire')
    assert(task.ms == 100 or task.interval == 100, 'boss observe cadence changed: ' .. tostring(task.ms or task.interval))
    assert(#held >= 2, 'boss observation must hold casting + aura leases')
    assert(BossAlerts:ReleaseConsumer('split_test'), 'boss alerts consumer release failed')
    assert(BossAlerts:Disable(), 'boss alerts disable failed')
    assert(S.Scheduler.tasks.v3_business_boss_alert_observe == nil, 'boss observe task must be removed at disable')
    assert(#released >= 2, 'boss observation must release casting + aura leases')
end)

Test('BatchC：raid_recruitment 只读申请列表，写入命令仍显式安全停用', function()
    unitHost.calls = {}
    assert(RaidRecruit.Authority:Refresh('test'))
    assert(RaidRecruit.Authority.status == 'partial', 'read-only applicant projection must stay honest: ' .. tostring(RaidRecruit.Authority.status))
    assert(#RaidRecruit.Authority.rows == 2, 'applicant rows not projected: ' .. tostring(#RaidRecruit.Authority.rows))
    for _, row in ipairs(RaidRecruit.Authority.rows) do
        assert(row.key:sub(1, 10) == 'applicant:', 'applicant row key changed: ' .. tostring(row.key))
        assert(row.statusText == '只读申请', 'applicant row label changed')
    end
    assert(tostring(RaidRecruit.Authority.error):find('仍待 RU 验证', 1, true) ~= nil, 'read-only honesty note missing')
    local created, createErr = RaidRecruit.Commands:Create()
    assert(created == false and tostring(createErr):find('已安全停用', 1, true) ~= nil, 'Create must stay safely disabled')
    local accepted, acceptErr = RaidRecruit.Commands:Accept()
    assert(accepted == false and tostring(acceptErr):find('charIds', 1, true) ~= nil, 'Accept must stay safely disabled')
    local rejected, rejectErr = RaidRecruit.Commands:Reject()
    assert(rejected == false and tostring(rejectErr):find('charIds', 1, true) ~= nil, 'Reject must stay safely disabled')
    unitHost.calls = {}
    assert(RaidRecruit.Commands:Close() == true, 'Close must reach X2Team')
    assert(unitHost.calls[1] ~= nil and unitHost.calls[1][1] == 'RaidRecruitDel', 'Close did not call RaidRecruitDel')
end)

Test('BatchC：boss 规则目录按固定目录投影，未启用规则如实标注', function()
    -- 中文维护注释：本宿主注入 2 条规则（cast + debuff），断言投影按规则目录逐条输出，
    -- 且默认启用状态与状态文案一致；不伪造任何未发生的机制事实。
    assert(BossAlerts.Authority:Refresh('test'))
    assert(BossAlerts.Authority.status == 'ready', 'boss projection status changed: ' .. tostring(BossAlerts.Authority.status))
    local byKey = {}
    for _, row in ipairs(BossAlerts.Authority.rows) do byKey[row.key] = row end
    assert(byKey['boss:split:cast'] ~= nil, 'cast rule row missing')
    assert(byKey['boss:split:debuff'] ~= nil, 'debuff rule row missing')
    assert(byKey['boss:split:cast'].text:find('测试读条', 1, true) ~= nil, 'cast trigger text changed')
    assert(byKey['boss:split:cast'].statusText == '已启用 · 倒计时', 'cast rule status text changed: ' .. tostring(byKey['boss:split:cast'].statusText))
    assert(byKey['boss:split:debuff'].statusText == '已启用 · 大字', 'debuff rule status text changed: ' .. tostring(byKey['boss:split:debuff'].statusText))
    assert(byKey['boss:split:debuff'].debuffId == 9001, 'debuff id not projected')
    -- 显式关闭一条规则后，投影必须如实变成“已关闭”，而不是继续显示已启用。
    local loaded = BossAlerts:Initialize()
    assert(loaded == true, 'boss store load failed')
    assert(BossAlerts.Commands:SetRuleEnabled('split:cast', false))
    assert(BossAlerts.Authority:Refresh('test'))
    local after = {}
    for _, row in ipairs(BossAlerts.Authority.rows) do after[row.key] = row end
    assert(after['boss:split:cast'].statusText == '已关闭' and after['boss:split:cast'].enabled == false, 'disabled rule not reflected')
    assert(BossAlerts.Commands:SetRuleEnabled('split:cast', true))
end)

Test('BatchC：boss 规则开关拒绝不存在的规则键', function()
    local ok, err = BossAlerts.Commands:SetRuleEnabled('split:not_a_rule', false)
    assert(ok == false and tostring(err):find('不存在', 1, true) ~= nil, 'unknown rule key must be rejected explicitly')
end)

Test('静态：bridge 不再注册 Batch C 四个 Feature', function()
    assert(bridge_retired(), 'rs_business_bridge.lua must stay retired')
    for _, id in ipairs({ 'combat_boss_alerts', 'combat_target_monitor', 'combat_buff_cap', 'combat_raid_recruitment' }) do
        assert(registrations[id] == 1, id .. ' must stay registered exactly once')
    end
    for _, path in ipairs({ 'features/combat/boss_alerts/rs_boss_alerts_feature.lua',
        'features/combat/target_monitor/rs_target_monitor_feature.lua',
        'features/combat/buff_cap/rs_buff_cap_feature.lua',
        'features/combat/raid_recruitment/rs_raid_recruitment_feature.lua' }) do
        local probe = assert(io.open(path, 'rb')); probe:close()
    end
end)

------------------------------------------------------------------------
-- Phase 1 Batch D：combat_team_tools / tools_craft / tools_auction
-- （这三个是 chunk 级 helper 大户：搬走后 bridge 主 chunk 从 187 降到 105 slots）
------------------------------------------------------------------------
_G.BagApi_SharedHost = true
-- 中文维护注释：按 toc.g 顺序先加载共享边界模块，tools_craft 依赖 S.SharedBounds.BagScanLimit。
dofile('features/shared/rs_shared_bounds.lua')
dofile('features/combat/team_tools/rs_team_tools_feature.lua')
dofile('features/tools/craft/rs_craft_feature.lua')
dofile('features/tools/auction/rs_auction_feature.lua')
local TeamToolsSplit = S.Features.combat_team_tools
local CraftSplit = S.Features.tools_craft
local AuctionSplit = S.Features.tools_auction

Test('BatchD：三个 Feature 各自独立注册且都只注册一次', function()
    for id, feature in pairs({ combat_team_tools = TeamToolsSplit, tools_craft = CraftSplit, tools_auction = AuctionSplit }) do
        assert(type(feature) == 'table', id .. ' not registered by its own file')
        assert(registrations[id] == 1, id .. ' expected exactly one registration, got ' .. tostring(registrations[id]))
        assert(registrations[id .. ':impl'] == feature, id .. ' registered implementation mismatch')
    end
end)

Test('BatchD：Feature ID / Store ID / owner / UpdateTopic 不变', function()
    local cases = {
        { TeamToolsSplit, 'combat_team_tools', 'v3.combat_team_tools' },
        { CraftSplit, 'tools_craft', 'v3.tools_craft' },
        { AuctionSplit, 'tools_auction', 'v3.tools_auction' },
    }
    for _, case in ipairs(cases) do
        local feature, id, owner = case[1], case[2], case[3]
        assert(feature.Id == id, 'Feature Id changed: ' .. tostring(feature.Id))
        assert(feature.storeId == 'v3.business.' .. id, id .. ' storeId changed')
        assert(feature.UpdateTopic == 'v3.business.' .. id .. '.updated', id .. ' UpdateTopic changed')
        local store = assert(P:GetStore(feature.storeId), id .. ' store not registered')
        assert(store.owner == owner, id .. ' store owner changed: ' .. tostring(store.owner))
        assert(store.schemaVersion == 1 and store.lifetime == P.Lifetime.Permanent, id .. ' store schema/lifetime changed')
        assert(type(feature.Demand) == 'table', id .. ' Demand lease missing')
    end
    assert(TeamToolsSplit.AutoRoleContractVersion == 3, 'AutoRoleContractVersion changed')
    assert(TeamToolsSplit.TeamRoleContractVersion == 2, 'TeamRoleContractVersion changed')
    assert(TeamToolsSplit.AutoRoleRosterLeaseContractVersion == 1, 'AutoRoleRosterLeaseContractVersion changed')
    assert(CraftSplit.CraftUserSelectionContractVersion == 1, 'CraftUserSelectionContractVersion changed')
    assert(AuctionSplit.SidecarPreferenceContractVersion == 1, 'SidecarPreferenceContractVersion changed')
    assert(AuctionSplit.AuctionQueryContractVersion == 1, 'AuctionQueryContractVersion changed')
end)

Test('BatchD：公开 Commands 精确集合不变', function()
    local expected = {
        { TeamToolsSplit, { 'Refresh', 'SetAutoRoleEnabled', 'SetRole', 'MoveMember', 'MoveMemberToParty' } },
        { CraftSplit, { 'Refresh', 'SelectRecipe', 'SetCraftType', 'SetItemType', 'SetDoodadId', 'QuoteMaterial', 'QuotePendingMaterials' } },
        { AuctionSplit, { 'Refresh', 'Search', 'SetKeyword', 'SetExactMatch', 'SetResultLimit', 'Quote', 'AddFavorite', 'RemoveFavorite',
            'RenameFavorite', 'MoveFavorite', 'RemoveFavoriteByKeyword', 'ClearFavorites', 'SetSidecarEnabled' } },
    }
    for _, case in ipairs(expected) do
        local feature, names = case[1], case[2]
        local wanted = {}
        for _, name in ipairs(names) do wanted[name] = true end
        for _, name in ipairs(names) do
            assert(type(feature.Commands[name]) == 'function', feature.Id .. ' command missing: ' .. name)
        end
        local count = 0
        for name in pairs(feature.Commands) do
            assert(wanted[name] == true, feature.Id .. ' unexpected command: ' .. tostring(name))
            count = count + 1
        end
        assert(count == #names, feature.Id .. ' command surface size changed: ' .. tostring(count))
    end
end)

Test('BatchD：ApiDependencies 不变', function()
    local expected = {
        { TeamToolsSplit, { 'X2Team:GetRole', 'X2Team:SetRole', 'X2Unit:GetTargetAbilityTemplates', 'X2Unit:UnitName' } },
        { CraftSplit, { 'X2Craft:GetCraftBaseInfo', 'X2Craft:GetCraftMaterialInfo', 'X2Craft:GetCraftProductInfo',
            'X2Craft:GetCraftTypeByItemType', 'X2Bag:Capacity', 'X2Bag:GetBagItemInfo' } },
        { AuctionSplit, { 'X2Auction:SearchAuctionArticle', 'X2Auction:GetSearchedItemCount', 'X2Auction:GetSearchedItemInfo',
            'X2Auction:GetLowestPrice', 'ADDON:GetContent', 'ADDON:GetContentMainScriptPosVis' } },
    }
    for _, case in ipairs(expected) do
        local feature, names = case[1], case[2]
        local have = {}
        for _, value in ipairs(feature.ApiDependencies) do have[value] = true end
        for _, value in ipairs(names) do assert(have[value] == true, feature.Id .. ' missing api dependency ' .. value) end
        local count = 0
        for _ in pairs(have) do count = count + 1 end
        assert(count == #names, feature.Id .. ' api dependency set changed: ' .. tostring(count))
    end
end)

Test('BatchD：team_tools 的 roster token / 自动职责任务名不变', function()
    local source = assert(io.open('features/combat/team_tools/rs_team_tools_feature.lua', 'rb'))
    local text = source:read('*a'); source:close()
    assert(text:find('"combat_team_tools:roster"', 1, true) ~= nil, 'roster token changed')
    assert(text:find('"v3_team_auto_role_apply"', 1, true) ~= nil, 'auto role task name changed')
    assert(text:find('AutoRoleRosterLeaseContractVersion = 1', 1, true) ~= nil, 'roster lease contract missing')
end)

Test('BatchD：craft 的共享扫描上界来自 SharedBounds（唯一 Authority）', function()
    local source = assert(io.open('features/tools/craft/rs_craft_feature.lua', 'rb'))
    local text = source:read('*a'); source:close()
    assert(text:find('S.SharedBounds.BagScanLimit', 1, true) ~= nil, 'craft must read the shared bag scan bound')
    assert(text:find('BAG_SCAN_LIMIT = 240', 1, true) == nil, 'craft must not hard-code the bound')
    local bounds = assert(io.open('features/shared/rs_shared_bounds.lua', 'rb'))
    local boundsText = bounds:read('*a'); bounds:close()
    assert(boundsText:find('BagScanLimit = 240', 1, true) ~= nil, 'shared bound value changed')
end)

Test('BatchD：auction 仍通过共享读模型消费，不复制投影实现', function()
    local source = assert(io.open('features/tools/auction/rs_auction_feature.lua', 'rb'))
    local text = source:read('*a'); source:close()
    assert(text:find('S.AuctionReadModel', 1, true) ~= nil, 'auction feature must consume the shared read model')
    assert(text:find('local function AuctionProjection', 1, true) == nil, 'auction feature re-defined the shared projection')
    assert(text:find('local function AuctionRows', 1, true) == nil, 'auction feature re-defined the shared row builder')
end)

------------------------------------------------------------------------
-- Phase 1 Batch E（最后一批）：tools_bag / combat_unit_lines / combat_range_assist
-- 以及“rs_business_bridge.lua 退役”这一事实本身。
------------------------------------------------------------------------
dofile('features/tools/bag/rs_bag_feature.lua')
dofile('features/combat/unit_lines/rs_unit_lines_feature.lua')
dofile('features/combat/range_assist/rs_range_assist_feature.lua')
local BagToolsSplit = S.Features.tools_bag
local UnitLinesSplit = S.Features.combat_unit_lines
local RangeAssistSplit = S.Features.combat_range_assist

Test('BatchE：三个 Feature 各自独立注册且都只注册一次', function()
    for id, feature in pairs({ tools_bag = BagToolsSplit, combat_unit_lines = UnitLinesSplit,
        combat_range_assist = RangeAssistSplit }) do
        assert(type(feature) == 'table', id .. ' not registered by its own file')
        assert(registrations[id] == 1, id .. ' expected exactly one registration, got ' .. tostring(registrations[id]))
        assert(registrations[id .. ':impl'] == feature, id .. ' registered implementation mismatch')
    end
end)

Test('BatchE：Feature ID / Store ID / owner / UpdateTopic 不变', function()
    local cases = {
        { BagToolsSplit, 'tools_bag', 'v3.tools_bag' },
        { UnitLinesSplit, 'combat_unit_lines', 'v3.combat_unit_lines' },
        { RangeAssistSplit, 'combat_range_assist', 'v3.combat_range_assist' },
    }
    for _, case in ipairs(cases) do
        local feature, id, owner = case[1], case[2], case[3]
        assert(feature.Id == id, 'Feature Id changed: ' .. tostring(feature.Id))
        assert(feature.storeId == 'v3.business.' .. id, id .. ' storeId changed')
        assert(feature.UpdateTopic == 'v3.business.' .. id .. '.updated', id .. ' UpdateTopic changed')
        local store = assert(P:GetStore(feature.storeId), id .. ' store not registered')
        assert(store.owner == owner, id .. ' store owner changed: ' .. tostring(store.owner))
        assert(store.schemaVersion == 1 and store.lifetime == P.Lifetime.Permanent, id .. ' store schema/lifetime changed')
        assert(type(feature.Demand) == 'table', id .. ' Demand lease missing')
    end
    -- 中文维护注释：契约版本是跨升级的公开承诺，逐个钉死。
    assert(BagToolsSplit.BagMoveContractVersion == 8, 'BagMoveContractVersion changed')
    assert(BagToolsSplit.BatchLifecycleContractVersion == 5, 'BatchLifecycleContractVersion changed')
    assert(BagToolsSplit.NativeWindowQuickContractVersion == 7, 'NativeWindowQuickContractVersion changed')
    assert(BagToolsSplit.BagTaskMutexContractVersion == 2, 'BagTaskMutexContractVersion changed')
    assert(UnitLinesSplit.VisualGuideContractVersion == 5, 'unit lines VisualGuideContractVersion changed')
    assert(UnitLinesSplit.AdaptiveDensityContractVersion == 2, 'unit lines AdaptiveDensityContractVersion changed')
    assert(RangeAssistSplit.VisualGuideContractVersion == 9, 'range VisualGuideContractVersion changed')
    assert(RangeAssistSplit.MetricDistanceContractVersion == 1, 'range MetricDistanceContractVersion changed')
    assert(RangeAssistSplit.MultiCircleContractVersion == 1, 'range MultiCircleContractVersion changed')
end)

Test('BatchE：公开 Commands 精确集合不变', function()
    local expected = {
        { BagToolsSplit, { 'Refresh', 'DepositBank', 'DepositCoffer', 'WithdrawBank', 'WithdrawCoffer', 'QuickWithdraw',
            'QuickDeposit', 'QuickCancel', 'DepositCategoryBank', 'DepositCategoryCoffer', 'DepositCategoryCurrent',
            'CancelCategoryBatch', 'SetBatchConfig', 'SetBatchCategory', 'SetBatchTarget', 'SetBatchLimit',
            'SetBlacklistEnabled', 'SetBlacklistScope', 'AddBlacklistItem', 'RemoveBlacklistItem', 'AddBlacklistCategory',
            'RemoveBlacklistCategory', 'AddGlobalBlacklistItem', 'RemoveGlobalBlacklistItem', 'ResolveAndAddBlacklistItem' } },
        { UnitLinesSplit, { 'Refresh', 'SetPairEnabled', 'SetPairColor', 'SetPairPoints', 'SetPairSize', 'SetOpacity',
            'SetPointCount', 'SetPointSize', 'SetRefreshMs' } },
        { RangeAssistSplit, { 'Refresh', 'SetColor', 'SetOpacity', 'SetPointCount', 'SetPointSize', 'SetRadius',
            'AddCircle', 'RemoveCircle', 'SetCircleEnabled', 'SetCircleColor', 'SetCircleOpacity',
            'SetCirclePointCount', 'SetCirclePointSize', 'SetCircleRadius' } },
    }
    for _, case in ipairs(expected) do
        local feature, names = case[1], case[2]
        local wanted = {}
        for _, name in ipairs(names) do wanted[name] = true end
        for _, name in ipairs(names) do
            assert(type(feature.Commands[name]) == 'function', feature.Id .. ' command missing: ' .. name)
        end
        local count = 0
        for name in pairs(feature.Commands) do
            assert(wanted[name] == true, feature.Id .. ' unexpected command: ' .. tostring(name))
            count = count + 1
        end
        assert(count == #names, feature.Id .. ' command surface size changed: ' .. tostring(count))
    end
end)

Test('BatchE：ApiDependencies 不变', function()
    local expected = {
        { BagToolsSplit, { 'X2Bag:GetBagItemInfo', 'X2Bag:Capacity', 'X2Bag:MoveToEmptyBankSlot', 'X2Bag:MoveToEmptyCofferSlot',
            'X2Bank:GetBagItemInfo', 'X2Bank:Capacity', 'X2Bank:MoveToEmptyBagSlot', 'X2Coffer:GetBagItemInfo',
            'X2Coffer:Capacity', 'X2Coffer:MoveToEmptyBagSlot', 'ADDON:GetContent', 'ADDON:GetContentMainScriptPosVis' } },
        { UnitLinesSplit, { 'X2Unit:GetUnitScreenPosition', 'X2Unit:GetUnitWorldPositionByTarget' } },
        { RangeAssistSplit, { 'X2Unit:GetUnitScreenPosition', 'X2Unit:GetUnitWorldPositionByTarget', 'X2Unit:UnitDistance' } },
    }
    for _, case in ipairs(expected) do
        local feature, names = case[1], case[2]
        local have = {}
        for _, value in ipairs(feature.ApiDependencies) do have[value] = true end
        for _, value in ipairs(names) do assert(have[value] == true, feature.Id .. ' missing api dependency ' .. value) end
        local count = 0
        for _ in pairs(have) do count = count + 1 end
        assert(count == #names, feature.Id .. ' api dependency set changed: ' .. tostring(count))
    end
end)

Test('BatchE：bag 的三个任务名与共享扫描上界保持唯一 Authority', function()
    local source = assert(io.open('features/tools/bag/rs_bag_feature.lua', 'rb'))
    local text = source:read('*a'); source:close()
    for _, task in ipairs({ 'v3_business_bag_category_batch', 'v3_business_bag_quick_observe', 'v3_business_bag_quick_move' }) do
        assert(text:find('"' .. task .. '"', 1, true) ~= nil, 'bag task name changed: ' .. task)
    end
    assert(text:find('S.SharedBounds.BagScanLimit', 1, true) ~= nil, 'bag must read the shared scan bound')
    assert(text:find('BAG_SCAN_LIMIT = 240', 1, true) == nil, 'bag must not hard-code the bound')
    assert(text:find('local function RestoreState', 1, true) == nil, 'dead RestoreState must not come back')
end)

Test('BatchE：静态 —— bridge 文件已退役，且 15 个 Feature 全部只注册一次', function()
    assert(bridge_retired(), 'rs_business_bridge.lua must stay retired')
    local expected = { tools_social = 1, tools_market_analysis = 1, combat_siege_readiness = 1, tools_reinforce_analysis = 1,
        tools_portal_profiles = 1, combat_boss_alerts = 1, combat_target_monitor = 1, combat_buff_cap = 1,
        combat_raid_recruitment = 1, combat_team_tools = 1, tools_craft = 1, tools_auction = 1,
        tools_bag = 1, combat_unit_lines = 1, combat_range_assist = 1 }
    for id, count in pairs(expected) do
        assert(registrations[id] == count, id .. ' registration count changed: ' .. tostring(registrations[id]))
    end
    local seen = 0
    for _ in pairs(registrations) do seen = seen + 1 end
    -- registrations 里每个 Feature 占两个键（id 与 id:impl），因此期望 30 个键
    assert(seen == 30, 'unexpected extra registrations: ' .. tostring(seen))
end)

------------------------------------------------------------------------
-- Phase 2（2026-09-28）：life bundle 拆分契约 —— 同样对应 §31 前后对照表
--
-- Phase 2 Step 1–4 把 features/life/rs_life_m16_bundle.lua（5633 行 / 4 个 Feature）拆成
-- life_treasure / life_fishing / life_bonds / life_trade 四个独立源码单元并退役删除 bundle。
-- 下面每一项的期望值都不是“照着拆分后源码反抄”，而是同一探针在**拆分前**的 bundle 与
-- **拆分后**的四个文件上分别跑出来再逐项比对的（44 行契约面 0 差异，见 Phase 2 报告）。
------------------------------------------------------------------------
local LifeConfigured = true

local lifeRegistrations = {}
local S2
do
    local bootOk, bootedS = pcall(H.Boot)
    if bootOk and type(bootedS) == 'table' then
        S2 = bootedS
        S2.FeatureRuntime = {
            RegisterImplementation = function(_, id, impl)
                lifeRegistrations[id] = (lifeRegistrations[id] or 0) + 1
                lifeRegistrations[id .. ':impl'] = impl
                return true
            end,
            IsEnabled = function() return true end,
            SetTaskModule = function() return true end,
        }
        local factoryOk, factoryErr = pcall(dofile, 'features/life/shared/rs_life_slice_factory.lua')
        if not factoryOk then
            LifeConfigured = false
            print('FAIL split Phase2 factory load: ' .. tostring(factoryErr))
        end
        for _, path in ipairs({
            'features/life/treasure/rs_treasure_feature.lua',
            'features/life/fishing/rs_fishing_feature.lua',
            'features/life/bonds/rs_bonds_feature.lua',
            'features/life/trade/rs_trade_feature.lua',
        }) do
            local ok, err = pcall(dofile, path)
            if not ok then LifeConfigured = false; print('FAIL split Phase2 load ' .. path .. ': ' .. tostring(err)) end
        end
    else
        LifeConfigured = false
        print('FAIL split Phase2 host boot: ' .. tostring(bootedS))
    end
end

local LifeSlices = {
    life_treasure = {
        storeId = 'v3.life.treasure', topic = 'v3.life.treasure.updated',
        commands = { 'Refresh', 'Select', 'ShowSelectedOnMap', 'GetWidgetVisible', 'SetWidgetVisible',
            'SetWidgetWindowState', 'MarkStoreDirty' },
        apiDependencies = { 'X2Bag:GetBagItemInfo', 'X2Bag:Capacity', 'X2Unit:GetUnitWorldPositionByTarget',
            'X2Unit:GetCurrentZoneGroup', 'X2Map:ShowWorldmapLocation' },
        contractVersions = { ObservationContractVersion = 2, MapLocationContractVersion = 2 },
    },
    life_fishing = {
        storeId = 'v3.life.fishing', topic = 'v3.life.fishing.updated',
        commands = { 'Refresh', 'ArmAuto', 'DisarmAuto', 'GetWidgetVisible', 'SetWidgetVisible',
            'SetWidgetWindowState', 'MarkStoreDirty' },
        apiDependencies = { 'X2Hotkey:GetOptionBinding', 'X2Hotkey:SetOptionBindingWithIndex',
            'X2Hotkey:RemoveOptionBinding', 'X2Hotkey:BindingToOption', 'X2Hotkey:SaveHotKey',
            'X2Player:PlayerInCombat', 'X2Unit:UnitBuff', 'X2Unit:UnitBuffCount', 'X2Unit:GetCurrentZoneGroup' },
        contractVersions = { HotkeyContractVersion = 3, ObservationContractVersion = 2 },
    },
    life_bonds = {
        storeId = 'v3.life.bonds', topic = 'v3.life.bonds.updated',
        commands = { 'Refresh', 'SelectRow', 'GetRow', 'GetSelectedRow', 'SetSortMode', 'SetBondFilterOption',
            'SetContinentOrder', 'SetDuplicatePriority', 'SetDisplayOrder', 'SetFilterMask', 'SetDuplicateMode',
            'GetWidgetVisible', 'SetWidgetVisible', 'SetWidgetWindowState', 'MarkStoreDirty' },
        apiDependencies = { 'X2Resident:GetResidentBoardContent', 'X2Bag:GetBagItemInfo', 'X2Bag:Capacity',
            'X2Quest:GetActiveQuestListCount', 'X2Quest:GetActiveQuestType', 'X2Quest:IsCompleted',
            'X2Quest:IsReadyForCompleteQuest', 'X2Unit:GetCurrentZoneGroup' },
        contractVersions = { ResidentBoardFamilyContractVersion = 1, MultiContinentSnapshotContractVersion = 3,
            AuroriaMaterialContractVersion = 1, DropdownPresentationContractVersion = 2 },
    },
    life_trade = {
        storeId = 'v3.life.trade', preferenceStoreId = 'v3.trade_preferences', topic = 'v3.life.trade.updated',
        commands = { 'Refresh', 'SetFrom', 'SetTo', 'SetSortMode', 'SetRatioMode', 'SetCommerceMode', 'SetViewMode',
            'ToggleTrackedProduct', 'SetAutoRefresh', 'SetCargoScan', 'ToggleCurrentFavorite', 'SelectFavorite',
            'SelectRow', 'QuoteMaterial', 'QuotePendingMaterials', 'QuoteRowMaterials', 'CancelQuoteRowMaterials',
            'CancelQuoteBatch', 'CycleFrom', 'CycleTo', 'GetWidgetVisible', 'SetWidgetVisible',
            'SetWidgetWindowState', 'MarkStoreDirty' },
        apiDependencies = { 'X2Store:GetProductionZoneGroups', 'X2Store:GetSellableZoneGroups',
            'X2Store:GetSpecialtyRatioBetween', 'X2Ability:GetAllMyActabilityInfos',
            'X2Equipment:GetEquippedItemType', 'X2Equipment:GetEquippedItemTooltipInfo',
            'X2Craft:GetCraftTypeByItemType', 'X2Craft:GetCraftMaterialInfo', 'X2Craft:GetCraftProductInfo',
            'X2Auction:AskMarketPrice', 'X2Auction:GetLowestPrice', 'X2Auction:SearchAuctionArticle',
            'X2Auction:GetSearchedItemCount', 'X2Auction:GetSearchedItemInfo' },
        contractVersions = {
            AutoRefreshRuntimeContractVersion = 1, AutoRefreshBackgroundLeaseContractVersion = 2,
            MaterialPriceCacheContractVersion = 1, MultiRowQuoteJobsContractVersion = 1,
            QuoteTerminalRefreshContractVersion = 2, QuoteReadModelSyncContractVersion = 1,
            EconomicsRevisionContractVersion = 1, BackgroundMaterialRevalidateContractVersion = 1,
        },
        authorityContractVersions = {
            RouteRefreshRetryContractVersion = 3, SingleFlightLatestRouteContractVersion = 1,
            RequestTimeoutContractVersion = 3, NativeCooldownContractVersion = 4, QuerySchedulerContractVersion = 2,
            AutoRefreshContractVersion = 3, AutoRefreshWatchdogContractVersion = 3, RatioFastPublishContractVersion = 2,
            TradePayoutProjectionContractVersion = 1, PreferenceProjectionContractVersion = 1,
            CargoObservationContractVersion = 2, NativeCallbackLeaseContractVersion = 1,
        },
    },
}

local function LifeFeature(id)
    return type(S2) == 'table' and S2.Features and S2.Features[
        ({ life_treasure = 'Treasure', life_fishing = 'Fishing', life_bonds = 'Bonds', life_trade = 'Trade' })[id]]
        or nil
end

Test('Phase2：life 工厂是唯一装配 Authority，四个 Feature 各自独立注册且只注册一次', function()
    assert(LifeConfigured, 'life features failed to load')
    assert(type(S2.LifeSliceFactory) == 'table', 'S.LifeSliceFactory missing')
    local expected = { life_treasure = 1, life_fishing = 1, life_bonds = 1, life_trade = 1 }
    for id, count in pairs(expected) do
        assert(lifeRegistrations[id] == count, id .. ' registration count changed: ' .. tostring(lifeRegistrations[id]))
    end
    local seen = 0
    for _ in pairs(lifeRegistrations) do seen = seen + 1 end
    -- 每个 Feature 占两个键（id 与 id:impl），因此期望 8 个键；多出来的就是有人把 Feature 又塞回了共享 chunk
    assert(seen == 8, 'unexpected extra life registrations: ' .. tostring(seen))
end)

Test('Phase2：Feature ID / Store ID / preference Store / UpdateTopic / Demand id 不变', function()
    for id, spec in pairs(LifeSlices) do
        local feature = assert(LifeFeature(id), id .. ' not registered by its own file')
        assert(feature.Id == id, id .. ' Feature ID changed: ' .. tostring(feature.Id))
        assert(feature.storeId == spec.storeId, id .. ' Store ID changed: ' .. tostring(feature.storeId))
        assert(feature.UpdateTopic == spec.topic, id .. ' UpdateTopic changed: ' .. tostring(feature.UpdateTopic))
        assert(feature.enabled == false, id .. ' default enabled state changed')
        if spec.preferenceStoreId then
            assert(feature.preferenceStoreId == spec.preferenceStoreId, id .. ' preference Store ID changed')
        end
        assert(type(feature.Demand) == 'table' and feature.Demand.id == 'feature:' .. id,
            id .. ' Demand id changed')
        assert(feature.Demand.owner == feature, id .. ' Demand owner changed')
    end
end)

Test('Phase2：公开 Commands 精确集合不变', function()
    for id, spec in pairs(LifeSlices) do
        local feature = assert(LifeFeature(id), id .. ' not registered')
        local wanted = {}
        for _, name in ipairs(spec.commands) do wanted[name] = true end
        for _, name in ipairs(spec.commands) do
            assert(type(feature.Commands[name]) == 'function', id .. ' command missing: ' .. name)
        end
        local count = 0
        for name in pairs(feature.Commands) do
            assert(wanted[name] == true, id .. ' unexpected command: ' .. tostring(name))
            count = count + 1
        end
        assert(count == #spec.commands, id .. ' command surface size changed: ' .. tostring(count))
    end
end)

Test('Phase2：ApiDependencies 精确集合不变', function()
    for id, spec in pairs(LifeSlices) do
        local feature = assert(LifeFeature(id), id .. ' not registered')
        local have = {}
        for _, value in ipairs(feature.ApiDependencies) do have[value] = true end
        for _, value in ipairs(spec.apiDependencies) do
            assert(have[value] == true, id .. ' missing api dependency ' .. value)
        end
        local count = 0
        for _ in pairs(have) do count = count + 1 end
        assert(count == #spec.apiDependencies, id .. ' api dependency set changed: ' .. tostring(count))
    end
end)

Test('Phase2：跨升级契约版本号不变', function()
    for id, spec in pairs(LifeSlices) do
        local feature = assert(LifeFeature(id), id .. ' not registered')
        for name, value in pairs(spec.contractVersions) do
            assert(feature[name] == value, id .. ' ' .. name .. ' changed: ' .. tostring(feature[name]))
        end
        for name, value in pairs(spec.authorityContractVersions or {}) do
            assert(feature.Authority[name] == value,
                id .. ' Authority.' .. name .. ' changed: ' .. tostring(feature.Authority[name]))
        end
    end
end)

Test('Phase2：静态 —— bundle 已退役，且没有任何源码单元注册多个 Feature', function()
    local retired = io.open('features/life/rs_life_m16_bundle.lua', 'rb')
    if retired ~= nil then retired:close() end
    assert(retired == nil, 'rs_life_m16_bundle.lua must stay retired')
    -- 逐行读 toc.g（跳过注释行），任何 .lua 文件都不允许出现第二次 RegisterImplementation：
    -- 否则“单个 Feature 源码失败不再因为同一 chunk 天然吞掉其它实现”这个 Phase 1/2 目标就被撤销了。
    local toc = assert(io.open('toc.g', 'rb'))
    local text = toc:read('*a'); toc:close()
    local checked = 0
    for line in text:gmatch('[^\r\n]+') do
        local path = line:match('^([^%-][^%s]*%.lua)%s*$')
        if path and path:match('^features/') then
            local handle = io.open(path, 'rb')
            if handle ~= nil then
                local source = handle:read('*a'); handle:close()
                local first = source:find('RegisterImplementation', 1, true)
                if first ~= nil then
                    checked = checked + 1
                    local second = source:find('RegisterImplementation', first + 1, true)
                    assert(second == nil, path .. ' registers more than one Feature implementation')
                end
            end
        end
    end
    assert(checked >= 19, 'expected at least 19 feature units to register an implementation, saw ' .. tostring(checked))
end)

Test('Phase2：静态 —— Trade / Bonds 的 Scheduler 任务名与 Native topic 不变', function()
    local function read(path)
        local handle = io.open(path, 'rb')
        if handle == nil then return '' end
        local text = handle:read('*a'); handle:close()
        return text
    end
    local trade = read('features/life/trade/rs_trade_feature.lua')
    for _, task in ipairs({ 'v3_trade_route_timeout', 'v3_trade_timeout_drain', 'v3_trade_route_deferred',
        'v3_trade_route_auto_refresh_watchdog', 'v3_trade_equipment_refresh', 'v3_trade_cargo_pump',
        'v3_trade_cargo_rescan', 'v3_trade_material_projection_deferred', 'v3_trade_quote_refresh' }) do
        assert(trade:find('"' .. task .. '"', 1, true) ~= nil, 'trade task name changed: ' .. task)
    end
    for _, topic in ipairs({ 'SPECIALTY_RATIO_BETWEEN_INFO', 'ENTER_ANOTHER_ZONEGROUP', 'UNIT_EQUIPMENT_CHANGED' }) do
        assert(trade:find(topic, 1, true) ~= nil, 'trade event topic changed: ' .. topic)
    end
    local bonds = read('features/life/bonds/rs_bonds_feature.lua')
    assert(bonds:find('"life_bonds_zone_refresh"', 1, true) ~= nil, 'bonds zone refresh task name changed')
    for _, topic in ipairs({ 'ENTER_ANOTHER_ZONEGROUP', 'ENTERED_WORLD' }) do
        assert(bonds:find(topic, 1, true) ~= nil, 'bonds event topic changed: ' .. topic)
    end
    -- §24.3 红线：Trade 不得因为拆文件重新实现共享 Authority
    for _, foreign in ipairs({ 'function PriceQuoteQueueV3', 'function TradePayoutV3', 'function MaterialPriceServiceV3' }) do
        assert(trade:find(foreign, 1, true) == nil, 'trade must not re-implement shared authority: ' .. foreign)
    end
end)

assert(#F.ApiDependencies == 8, 'tools_social api dependency count changed')
assert(#Market.ApiDependencies == 3, 'tools_market_analysis api dependency count changed')
print(string.format('FEATURE SPLIT RESULT %d passed / %d failed', passed, failed))
if failed > 0 then error('feature split contract regressions: ' .. tostring(failed)) end
