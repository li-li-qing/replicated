------------------------------------------------------------------------
-- Replicated Suite V3 - life_bonds Feature Authority
--
-- Phase 2 Step 3（2026-09-28，§24.1 固定顺序第三步）：从 features/life/rs_life_m16_bundle.lua
-- 机械搬迁。只改变源码边界，不改业务行为：Feature ID、Store ID/Schema（v3.life.bonds）、
-- UpdateTopic、Demand owner、Commands、Projection shape、ApiDependencies 全部逐字一致。
--
-- §24.3 红线：Bonds 的 X2Quest ownership 保持 .328 修复（ApiDependencies 由
-- features/rs_feature_registry.lua 声明，本文件不重复声明、不扩大权限）。
-- 共享装配 helper 来自 features/life/shared/rs_life_slice_factory.lua（toc.g 已保证先加载）。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P, Runtime, Demand = S.Persistence, S.FeatureRuntime, S.Demand
if type(P) ~= "table" or type(Runtime) ~= "table" or type(Demand) ~= "table" then return end
local BagApi = rawget(_G, "X2Bag")
local ResidentApi = rawget(_G, "X2Resident")
local UnitApi = rawget(_G, "X2Unit")
local LF = S.LifeSliceFactory
if type(LF) ~= "table" then error("LifeSliceFactory unavailable for life_bonds") end
local Copy, Call = LF.Copy, LF.Call
local Number, Text = LF.Number, LF.Text
local InstallLifeWidgetContract, PublishFeatureUpdate = LF.InstallLifeWidgetContract, LF.PublishFeatureUpdate
local RegisterStore, LoadStore, PersistLifeMutation = LF.RegisterStore, LF.LoadStore, LF.PersistLifeMutation

------------------------------------------------------------------------
-- Bonds / Resident board
------------------------------------------------------------------------
local Bonds = { Id = "life_bonds", storeId = "v3.life.bonds", enabled = false, storeLoaded = false,
    progressConsumerToken = "feature:life_bonds:quest_progress", progressConsumerHeld = false, progressSubscribed = false,
    locationSubscribed = false }
local BONDS_ZONE_REFRESH_TASK = "life_bonds_zone_refresh"
local BONDS_SERVER_DATE_TASK = "life_bonds_server_date"
local BONDS_LOCATION_DELAYS = { 750, 1500, 3000 }
Bonds.CrossContinentPatch = "bonds-cross-continent-1"
Bonds.RegionContinentPatch = "bonds-region-continent-1"
S.Features.Bonds = Bonds
Bonds.UpdateTopic = "v3.life.bonds.updated"
Bonds.State = { sortMode = "continent", continentOrder = "west_first", showCompleted = true, q20 = true, q60 = true, q100 = true, auroria = true, excludeSame = false, priority = "west", completionDateKey = nil, completedMainlandKeys = {}, dailyDateKey = nil, dailySnapshots = {}, widgetVisible = false, widgetWindow = nil }
-- 中文维护注释（2026-09-15，西/东大陆同日快照与排序语义）：
-- 问题原因：旧页面把“按大陆排序”“优先西/东”和“去重”挤在同一排，priority 还会隐式开启去重，
-- 用户切换排序时会看到另一大陆行被隐藏，从而误以为 Authority 只能读取一个大陆。Authority 实际已经
-- 按 server day 保存 west/east/auroria 三份快照，因此本次不新增第二数据源，只把“大陆展示顺序”提升为
-- 独立持久化偏好 continentOrder，并明确 duplicate priority 只有在合并模式开启时才参与。
-- Authority/数据流：ResidentBoard -> Bonds.Authority -> dailySnapshots[continent] -> detached Projection；
-- Presentation 只能调用 Commands，禁止直接读取 State。兼容边界：新增字段缺失时默认 west_first，旧 Store
-- schema/fingerprint 仍由 NormalizeBondState 兼容；不增加轮询，不跨大陆伪造远程读取。
-- 风险：未来若增加第四大陆/新阵营，必须同时扩展排序 rank、dailySnapshotStatus 和 UI 标签，不能复用 priority。
-- 中文维护注释（2026-09-24，债券 18.302 契约）：v3 表示多大陆缓存已具备 Native 板族识别、
-- 空快照拒绝、区域重探测以及按 board index 的同日增量合并；ResidentBoardFamily/AuroriaMaterial/DropdownPresentation 分开打契约，
-- 让 Foundation/Acceptance 能在用户只覆盖部分文件时 fail-fast，而不是运行到一半才出现“原大陆没数据/按钮旧版”。
Bonds.MultiContinentSnapshotContractVersion = 3
Bonds.ResidentBoardFamilyContractVersion = 1
Bonds.AuroriaMaterialContractVersion = 1
Bonds.DropdownPresentationContractVersion = 2
InstallLifeWidgetContract(Bonds, { defaultWidth = 500, defaultHeight = 330, minWidth = 280, minHeight = 150, defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 })
Bonds.Authority = { version = 3, revision = 0, rows = {}, status = "idle", error = nil, boardScope = "unknown", faction = nil }
local BA = Bonds.Authority
-- 中文维护注释（2026-09-24，债券 ItemType 反向索引）：大陆 4 种 + 原大陆 6 种材料在脚本加载时
-- 建一次只读反向表。InventorySnapshotV3 刷新会遍历背包物品，如果每个 item 再 pairs 扫 10 个常量键，
-- 会把一个 O(n) 背包聚合放大成 O(n*10)。反向索引保持同一 GameIds Authority，只消除热路径重复匹配。
local BOND_MATERIAL_KEY_BY_ITEM_TYPE = {}
for key, value in pairs(S.Constants and S.Constants.BondMaterialItemTypes or {}) do
    if tonumber(value) ~= nil then BOND_MATERIAL_KEY_BY_ITEM_TYPE[tonumber(value)] = key end
end
for key, value in pairs(S.Constants and S.Constants.AuroriaBondMaterialItemTypes or {}) do
    if tonumber(value) ~= nil then BOND_MATERIAL_KEY_BY_ITEM_TYPE[tonumber(value)] = key end
end
local function BondMaterialKey(itemType)
    return BOND_MATERIAL_KEY_BY_ITEM_TYPE[tonumber(itemType)]
end
local function BondItemType(item) return item.itemType or item.itemTypeId or item.typeId or item.item_type end
local function BondItemCount(item) return Number(item.stackCount or item.stack or item.count or item.itemCount or item.amount or item.stackSize or item.quantity) end
local QUEST_STATUS_TEXT = { COMPLETED = "已完成", READY_TO_TURN_IN = "可交付", IN_PROGRESS = "进行中", NOT_ACCEPTED = "未接", UNKNOWN = "待确认" }
local QUEST_STATUS_TONE = { COMPLETED = "green", READY_TO_TURN_IN = "orange", IN_PROGRESS = "yellow", NOT_ACCEPTED = "muted", UNKNOWN = "muted" }
local AURORIA_BOND_LABEL = {
    prince_purse = "王子的钱袋", prince_crate = "王子的箱子",
    queen_purse = "女王的钱袋", queen_crate = "女王的箱子",
    ancestor_purse = "祖先的钱袋", ancestor_crate = "祖先的箱子",
}
local function BondTextContainsAny(text, patterns)
    text = tostring(text or "")
    local lower = string.lower(text)
    for _, pattern in ipairs(patterns or {}) do
        if string.find(text, pattern, 1, true) or string.find(lower, string.lower(pattern), 1, true) then return true end
    end
    return false
end
local function ResolveAuroriaBondToken(boardIndex, text, quantity)
    -- 中文维护注释（2026-09-24，原大陆任务解析 / 18.302 复核）：公开 ArcheRage residentboard
    -- 插件确认板位 5/6/7 分别代表 Prince/Queen/Ancestor。板位只决定家族，文本优先判断钱袋/箱子；
    -- 若本地化关键词缺失，不能只拿“文本第一个数字”推断，因为区域名/阶段文本可能在需求量之前出现其它数字。
    -- 这里扫描整行所有数字，并且只有所有命中证据唯一指向 purse 或 crate 时才降级推断；30/25/20 等
    -- 两类都合法的歧义数量仍保持 UNKNOWN。Authority 不猜任务身份，避免把完成状态锁到错误 QuestId。
    local family = ({ [5] = "prince", [6] = "queen", [7] = "ancestor" })[tonumber(boardIndex)]
    if family == nil then return nil end
    local purse = BondTextContainsAny(text, { "钱袋", "袋", "coinpurse", "purse", "кош", "Кош", "меш", "Меш", "котом", "Котом", "金闪闪" })
    local crate = BondTextContainsAny(text, { "箱", "盒", "匣", "杂货箱", "杂物箱", "crate", "box", "сунд", "Сунд", "ящ", "Ящ" })
    if purse and not crate then return family .. "_purse" end
    if crate and not purse then return family .. "_crate" end

    local maps = S.Constants and S.Constants.AuroriaBondQuestByTokenQuantity or {}
    local purseMap, crateMap = maps[family .. "_purse"], maps[family .. "_crate"]
    local observed = {}
    local q = tonumber(quantity)
    if q ~= nil then observed[q] = true end
    for number in string.gmatch(tostring(text or ""), "(%d+)") do
        q = tonumber(number)
        if q ~= nil then observed[q] = true end
    end
    local purseMatch, crateMatch = false, false
    for amount in pairs(observed) do
        purseMatch = purseMatch or (type(purseMap) == "table" and purseMap[amount] ~= nil)
        crateMatch = crateMatch or (type(crateMap) == "table" and crateMap[amount] ~= nil)
    end
    if purseMatch ~= crateMatch then return purseMatch and (family .. "_purse") or (family .. "_crate") end
    return nil
end
local function BondQuestEvidence(materialKey, text, boardIndex)
    local function quantityFromMap(map)
        if type(map) ~= "table" then return nil end
        for number in string.gmatch(tostring(text or ""), "(%d+)") do
            local quantity = tonumber(number)
            if quantity ~= nil and map[quantity] ~= nil then return quantity end
        end
        return nil
    end
    local materialMap = S.Constants and S.Constants.BondQuestByMaterialQuantity
        and S.Constants.BondQuestByMaterialQuantity[materialKey]
    if type(materialMap) == "table" then
        local quantity = quantityFromMap(materialMap)
        return quantity and materialMap[quantity] or nil, quantity, nil
    end

    local rawQuantity = Number(string.match(tostring(text or ""), "(%d+)"))
    local token = ResolveAuroriaBondToken(boardIndex, text, rawQuantity)
    local map = token and S.Constants and S.Constants.AuroriaBondQuestByTokenQuantity and S.Constants.AuroriaBondQuestByTokenQuantity[token]
    local quantity = quantityFromMap(map)
    if quantity ~= nil then return map[quantity], quantity, token end
    return nil, rawQuantity, token
end
-- BondDateCache removed 2026-09-02: S.State 永远 nil (replicatedsuite.lua 显式置 nil
-- + foundation_gate 断言), 整个函数返回 nil, 调用方 cache 逻辑不可达.
-- 大陆债券完成状态由 questStatus 直接决定, 无缓存层.
local function ReadBondResources()
    local totals = {}
    for key in pairs(S.Constants and S.Constants.BondMaterialItemTypes or {}) do totals[key] = 0 end
    for key in pairs(S.Constants and S.Constants.AuroriaBondMaterialItemTypes or {}) do totals[key] = 0 end
    local status = "unknown"
    -- 中文维护注释：优先复用 InventorySnapshotV3 统一背包只读快照（含 bagId 1/0 自动试探与数量提取），
    -- 避免各生活模块对物理背包槽位产生第二 Authority 或猜测不同 bagId。
    local snapshotService = S.Services and S.Services.InventorySnapshotV3
    if type(snapshotService) == "table" and type(snapshotService.BuildSnapshot) == "function" then
        local snapshot, snapErr = snapshotService:BuildSnapshot("bag")
        if snapshot ~= nil and type(snapshot.rows) == "table" then
            for _, row in ipairs(snapshot.rows) do
                local key = BondMaterialKey(row.itemType)
                if key ~= nil then
                    totals[key] = totals[key] + (tonumber(row.stack) or 1)
                end
            end
            local failed = (tonumber(snapshot.readErrors) or 0) > 0 or (snapshot.unknown and snapshot.unknown > 0)
            if #snapshot.rows == 0 then status = "unknown" elseif failed then status = "partial" else status = "ready" end
            return totals, status
        end
    end

    if S.Api == nil or S.Api:IsCapabilityAllowed("X2Bag:GetBagItemInfo") ~= true or S.Api:IsCapabilityAllowed("X2Bag:Capacity") ~= true then return totals, status end
    local capacityOk, capacity = Call("X2Bag:Capacity", BagApi, "Capacity")
    capacity = Number(capacity)
    if capacityOk ~= true or not capacity or capacity < 0 then return totals, status end
    local maxSlot = math.min(240, math.floor(capacity))
    local readCount, failed = 0, false
    -- 中文维护注释：物理槽位降级读取依循 GearV3 规范：bagId=1 优先，无有效物品时降级 bagId=0。
    local bagIds = { 1, 0 }
    for _, bagId in ipairs(bagIds) do
        local currentReadCount, currentObservedItems = 0, 0
        local currentTotals = {}
        for key in pairs(totals) do currentTotals[key] = 0 end
        local currentFailed = false
        for slot = 1, maxSlot do
            local ok, item = Call("X2Bag:GetBagItemInfo", BagApi, "GetBagItemInfo", bagId, slot)
            if ok ~= true then
                currentFailed = true
            else
                currentReadCount = currentReadCount + 1
                if type(item) == "table" then
                    -- 中文维护注释（bond-bag-fallback-1）：API 调用成功只证明槽位可读，nil/空表不能证明
                    -- bagId=1 是当前物理背包。只有看到至少一个真实物品后才锁定该 bagId；否则继续试 bagId=0。
                    -- 这样不会把“100 个空槽位成功返回 nil”误判为有效背包而把真实材料统计成 0。
                    if next(item) ~= nil then currentObservedItems = currentObservedItems + 1 end
                    local itemType, count = BondItemType(item), BondItemCount(item)
                    local key = BondMaterialKey(itemType)
                    if key ~= nil then
                        if count ~= nil then currentTotals[key] = currentTotals[key] + count else currentFailed = true end
                    elseif next(item) ~= nil and itemType == nil then
                        currentFailed = true
                    end
                elseif item ~= nil then
                    currentObservedItems = currentObservedItems + 1
                    currentFailed = true
                end
            end
        end
        if currentObservedItems > 0 then
            totals = currentTotals
            readCount = currentReadCount
            failed = currentFailed
            break
        end
    end
    if readCount == 0 then status = "unknown" elseif failed then status = "partial" else status = "ready" end
    return totals, status
end
local function BondRowText(value)
    if type(value) == "table" then return Text(value.text or value.name or value.title or value[1]) end
    return Text(value)
end
local BOND_BOARD_NAMES = {
    [1] = "布料", [2] = "皮革", [3] = "木材", [4] = "铁锭",
    [5] = "王子的物品", [6] = "女王的物品", [7] = "祖先的物品",
}
-- 维护（2026-09-30，跨大陆读取）：Native 行表和持久化序列不是同一个边界。
-- Native 允许稀疏/十进制字符串索引；旧 ipairs 会截断后半段，且 tonumber(key) 后再
-- source[number] 取不到原 string key。现在保留实际键值，按数值顺序读取，元数据不当行。
-- 单板最多检查 192 项；别名碰撞/过大输入整体拒绝，不按 pairs 的不确定顺序选赢家。
local function NormalizeResidentBoardContents(value)
    if type(value) == "string" or type(value) == "number" then
        return Text(value) ~= "" and { value } or {}
    end
    if type(value) ~= "table" then return {} end
    local source = value.contents or value.content or value.rows or value.items
    if source == nil then source = value end
    if type(source) == "string" or type(source) == "number" then
        return Text(source) ~= "" and { source } or {}
    end
    if type(source) ~= "table" then return {} end
    local indexed, keys, scanned = {}, {}, 0
    for key, entry in pairs(source) do
        scanned = scanned + 1
        if scanned > 192 then return {}, "native_board_entry_limit" end
        local kind, n = type(key), tonumber(key)
        local canonical = kind == "number" or (kind == "string" and key:match("^[1-9]%d*$") ~= nil)
        if canonical and n ~= nil and n >= 1 and n <= 192 and n == math.floor(n) then
            if indexed[n] ~= nil then return {}, "native_board_duplicate_index" end
            indexed[n], keys[#keys + 1] = entry, n
        end
    end
    table.sort(keys)
    local result = {}
    for _, key in ipairs(keys) do
        local entry = indexed[key]
        local kind = type(entry)
        if (kind == "string" or kind == "number" or kind == "table") and BondRowText(entry) ~= "" then
            result[#result + 1] = entry
        end
    end
    return result
end
local function BondContinent(index) if index >= 5 then return "原大陆" else return "西/东大陆" end end
local BOND_CONTINENT_LABEL = { west = "西大陆", east = "东大陆", auroria = "原大陆" }
local BOND_ZONE_CATALOG = S.GameIds and S.GameIds.Zone and S.GameIds.Zone.ById or {}
local BOND_REGION_NAMES = {}
for zoneId, zone in pairs(BOND_ZONE_CATALOG) do
    local function AddName(name, ascii)
        if type(name) == "string" and name ~= "" then
            BOND_REGION_NAMES[#BOND_REGION_NAMES + 1] = {
                zoneId = zoneId, name = ascii and string.lower(name) or name, ascii = ascii == true,
            }
        end
    end
    AddName(zone.nameZh, false)
    AddName(zone.nameEn, true)
    for _, alias in ipairs(zone.nameZhAliases or {}) do AddName(alias, false) end
end

local function BondRegionNameMatches(text, lower, entry)
    if not entry.ascii then return string.find(text, entry.name, 1, true) ~= nil end
    local start = 1
    while start <= #lower do
        local first, last = string.find(lower, entry.name, start, true)
        if first == nil then return false end
        -- 英文短地区名允许匹配全名（Airain Rock），但不能匹配 Sanddeepness 等另一名称。
        local before, after = string.sub(lower, first - 1, first - 1), string.sub(lower, last + 1, last + 1)
        if not string.find(before, "[%w_]") and not string.find(after, "[%w_]") then return true end
        start = last + 1
    end
    return false
end

local function BondTaskContinent(text, board, sourceKey)
    if board >= 5 then return "auroria", nil, "board_family" end
    local lower, found = string.lower(text), nil
    for _, entry in ipairs(BOND_REGION_NAMES) do
        if BondRegionNameMatches(text, lower, entry) then
            if found ~= nil and found ~= entry.zoneId then return sourceKey, nil, "region_ambiguous" end
            found = entry.zoneId
        end
    end
    local zone = found and BOND_ZONE_CATALOG[found] or nil
    if zone ~= nil and (zone.continentKey == "west" or zone.continentKey == "east") then
        return zone.continentKey, found, "region_text"
    end
    return sourceKey, nil, zone ~= nil and "region_family_conflict" or "snapshot_fallback"
end
local BOND_SNAPSHOT_MAX_LINES = 4
local BOND_SNAPSHOT_MAX_TEXT = 160

local function BoundedBondSnapshotText(value)
    local text = Text(value, "")
    if #text <= BOND_SNAPSHOT_MAX_TEXT then return text end
    local cut = BOND_SNAPSHOT_MAX_TEXT
    -- Persist only a valid UTF-8 prefix. Russian/Chinese board text is
    -- multi-byte; raw string.sub at the byte budget can split a codepoint and
    -- corrupt the restored daily snapshot.
    while cut > 0 do
        local byte = string.byte(text, cut)
        if byte ~= nil and byte >= 0x80 and byte < 0xC0 then cut = cut - 1 else break end
    end
    if cut <= 0 then return "" end
    local lead = string.byte(text, cut) or 0
    local width = lead >= 0xF0 and 4 or (lead >= 0xE0 and 3 or (lead >= 0xC0 and 2 or 1))
    if cut + width - 1 > BOND_SNAPSHOT_MAX_TEXT then cut = cut - 1 else cut = BOND_SNAPSHOT_MAX_TEXT end
    return string.sub(text, 1, math.max(0, cut))
end

local function CurrentBondContinentKey()
    local ok, zoneId = Call("X2Unit:GetCurrentZoneGroup", UnitApi, "GetCurrentZoneGroup")
    zoneId = ok == true and math.floor(Number(zoneId) or 0) or 0
    local zone = BOND_ZONE_CATALOG[zoneId]
    return zone and zone.continentKey or nil
end

local function BondBoardLineCount(boards, index)
    local board = type(boards) == "table" and boards[index] or nil
    return #(type(board) == "table" and type(board.contents) == "table" and board.contents or {})
end

local function DetectResidentBoardFamily(boards)
    -- 中文维护注释（2026-09-24，ResidentBoard 家族识别）：Strawberry-devs 的公开 ArcheRage
    -- residentboard 插件使用“3/4 板同时非空 => 主大陆；5/6 任一非空 => 原大陆”的真实客户端行为。
    -- 旧 Bonds 反过来先相信静态 zoneGroup 表，导致未收录的原大陆区域在已经缓存西/东后完全不再调用
    -- GetResidentBoardContent，甚至可能把 5/6 的原大陆内容误作为西/东的一张空快照保存。这里把 Native
    -- ResidentBoard 内容提升为“当前板族”的 Authority，zoneGroup 只负责主大陆西/东分边，不再决定原大陆。
    -- 维护（2026-09-30）：3/4 同时非空是充分条件而非必要条件。局部加载的 1/2
    -- 以及原大陆单独第 7 板也携带真实内容；主大陆仍必须另有明确的西/东归属证据。
    local mainlandReady, auroriaReady = false, false
    for index = 1, 4 do mainlandReady = mainlandReady or BondBoardLineCount(boards, index) > 0 end
    for index = 5, 7 do auroriaReady = auroriaReady or BondBoardLineCount(boards, index) > 0 end
    if mainlandReady and auroriaReady then return "mixed", "mixed_board_families" end
    if mainlandReady then return "mainland", "boards_1_4" end
    if auroriaReady then return "auroria", "boards_5_7" end
    return nil, "insufficient_board_evidence"
end

local function BondFactionContinentHint(boards, includeEmpty)
    -- 维护（2026-09-30）：优先检查有内容的主大陆板。跨区时 zone 可能已更新，而内容
    -- 仍是上一大陆；冲突不得把旧板标成新大陆。空板 faction 仅保留旧版未知区域
    -- 的 locator 兜底，不得覆盖已知所在地或内容板的明确证据。
    local hint, faction = nil, ""
    for index = 1, 4 do
        local raw = type(boards[index]) == "table" and boards[index].raw or nil
        local value = (includeEmpty == true or BondBoardLineCount(boards, index) > 0) and type(raw) == "table" and Text(raw.faction, "") or ""
        if value ~= "" then
            faction = value
            local lower, candidate = string.lower(value), nil
            if string.find(lower, "nuia", 1, true) or string.find(lower, "nui", 1, true)
                or string.find(value, "нуи", 1, true) or string.find(value, "Нуи", 1, true)
                or string.find(value, "西", 1, true) then candidate = "west" end
            if string.find(lower, "haranya", 1, true) or string.find(lower, "harani", 1, true)
                or string.find(value, "хар", 1, true) or string.find(value, "Хар", 1, true)
                or string.find(value, "东", 1, true) then
                if candidate ~= nil then return nil, faction, true end
                candidate = "east"
            end
            if candidate ~= nil then
                if hint ~= nil and hint ~= candidate then return nil, faction, true end
                hint = candidate
            end
        end
    end
    return hint, faction, false
end

local function ResolveLiveBondScope(boards, zoneHint)
    local family, evidence = DetectResidentBoardFamily(boards)
    -- 同时出现两族不一定是坏数据：Native 可能保留另一族缓存。已知所在地只采对应
    -- 板区间，保留原本 1..4 + 第5板同时返回的兼容场景；未知位置才等待归属证据。
    if family == "mixed" then
        if zoneHint == "auroria" then return "auroria", "auroria", evidence .. "+zone" end
        if zoneHint == "west" or zoneHint == "east" then family = "mainland"
        else return nil, family, evidence .. "+location_unknown" end
    end
    if family == "auroria" then return "auroria", family, evidence end
    if family == "mainland" then
        local factionHint, _, conflict = BondFactionContinentHint(boards)
        if conflict or ((zoneHint == "west" or zoneHint == "east") and factionHint ~= nil and factionHint ~= zoneHint) then
            return nil, family, evidence .. "+location_faction_conflict"
        end
        if zoneHint == "west" or zoneHint == "east" then return zoneHint, family, evidence .. "+zone" end
        if factionHint ~= nil then return factionHint, family, evidence .. "+faction" end
        factionHint, _, conflict = BondFactionContinentHint(boards, true)
        if factionHint ~= nil and conflict ~= true then return factionHint, family, evidence .. "+faction_locator" end
        return nil, family, evidence .. "+mainland_side_unknown"
    end
    return nil, nil, evidence
end

local function BondSnapshotLineCount(snapshot)
    local count = 0
    for _, board in ipairs(type(snapshot) == "table" and type(snapshot.boards) == "table" and snapshot.boards or {}) do
        count = count + #(type(board.lines) == "table" and board.lines or {})
    end
    return count
end

-- 维护（2026-09-30，保存/重登表示差异）：仅 boards / lines 是已声明序列。
-- 遇到字符串数字索引，复用 Core 的完整 1..N 重建；缺口、碰撞、非规范数字键不补齐。
-- 普通数字数组的 canonical 形状完全不改；原 envelope/stamped hash 必须继续通过。
-- 该候选归一不绕过读回校验，不迁移 Schema，不扩大 Core 对其他 Store 的容错。
local function BondStoredSequence(value, limit)
    if type(value) ~= "table" then return {} end
    for key in pairs(value) do
        if type(key) == "string" and tonumber(key) ~= nil then
            if type(P.RebuildDenseSequenceForIntegrity) ~= "function" then return {} end
            return P:RebuildDenseSequenceForIntegrity(value, limit) or {}
        end
    end
    return value
end

local function NormalizeBondSnapshot(value, continentKey)
    if type(value) ~= "table" then return nil end
    if continentKey ~= "west" and continentKey ~= "east" and continentKey ~= "auroria" then return nil end
    local out = { continentKey = continentKey, faction = Text(value.faction, ""), boards = {} }
    local count = 0
    for _, rawBoard in ipairs(BondStoredSequence(value.boards, 7)) do
        if count >= 7 then break end
        local board = type(rawBoard) == "table" and rawBoard or {}
        local index = math.floor(Number(board.index or board.board) or 0)
        if index >= 1 and index <= 7 then
            local lines = {}
            for _, rawLine in ipairs(BondStoredSequence(board.lines, BOND_SNAPSHOT_MAX_LINES)) do
                if #lines >= BOND_SNAPSHOT_MAX_LINES then break end
                local line = BoundedBondSnapshotText(rawLine)
                if line ~= "" then
                    lines[#lines + 1] = line
                end
            end
            out.boards[#out.boards + 1] = { index = index, lines = lines }
            count = count + 1
        end
    end
    -- 中文维护注释（2026-09-24，空快照污染修复）：旧 Normalize 只要存在 1..7 的 board 外壳就
    -- 接受快照，即使所有 lines 都为空。若一次 ResidentBoard 临时读空却被错误大陆提示命中，Store 会把
    -- “空西大陆/空东大陆”保存整天，后续 Refresh 因 snapshot 已存在不再读取，表现就是“偶尔整天没数据”。
    -- 现在至少要求 1 条真实居民板文本；旧存档中的空壳会在 Normalize 时自然丢弃，无需清配置或迁移 schema。
    return BondSnapshotLineCount(out) > 0 and out or nil
end

local function CaptureBondSnapshot(continentKey, boards)
    if continentKey == nil or type(boards) ~= "table" then return nil end
    local firstIndex, lastIndex = 1, 4
    if continentKey == "auroria" then firstIndex, lastIndex = 5, 7 end
    local snapshot = { continentKey = continentKey, faction = "", boards = {} }
    for index = firstIndex, lastIndex do
        local board = type(boards[index]) == "table" and boards[index] or {}
        if snapshot.faction == "" and type(board.raw) == "table" and board.raw.faction ~= nil then snapshot.faction = Text(board.raw.faction, "") end
        local lines = {}
        for _, entry in ipairs(type(board.contents) == "table" and board.contents or {}) do
            if #lines >= BOND_SNAPSHOT_MAX_LINES then break end
            local line = BoundedBondSnapshotText(BondRowText(entry))
            if line ~= "" then
                lines[#lines + 1] = line
            end
        end
        snapshot.boards[#snapshot.boards + 1] = { index = index, lines = lines }
    end
    return NormalizeBondSnapshot(snapshot, continentKey)
end

-- 维护（2026-10-07）：同日已完整读取的大陆直接复用本地；缺板仍允许有限补读。
-- 只检查现有快照结构，不增加存档字段，保持 schema=1 的历史 canonical/指纹。
local function BondSnapshotComplete(snapshot, continentKey)
    if type(snapshot) ~= "table" then return false end
    local seen = {}
    for _, board in ipairs(snapshot.boards or {}) do
        if type(board.lines) == "table" and #board.lines > 0 then seen[tonumber(board.index)] = true end
    end
    local firstIndex, lastIndex = continentKey == "auroria" and 5 or 1, continentKey == "auroria" and 7 or 4
    for index = firstIndex, lastIndex do if seen[index] ~= true then return false end end
    return true
end


-- 中文维护注释（2026-09-24，18.302 每板增量合并）：dailySnapshots 的 Authority 粒度是“服务器日 + 大陆”，
-- 但一次 Native ResidentBoard 读取只代表玩家当前可见板内容。18.301 把整个 auroria 当成单个原子快照，
-- 导致已经缓存 Prince 后进入 Queen/Ancestor 区域时，zone-boundary 探测虽然成功却因 previous 已存在而拒绝
-- 新内容；手动刷新又只按总行数比较，可能同样丢失另一组合法板数据。这里改为按 board index 合并，并对
-- 每个板的文本做稳定去重。旧行先保留，新探测只追加尚未记录的真实行；空读绝不删除已有行。主大陆也
-- 复用同一规则，从而抵抗局部 Native 空读。每天日期 rollover 仍由上层清空，因此不会跨天积累陈旧事实。
local function MergeBondSnapshot(previous, captured, continentKey)
    previous = NormalizeBondSnapshot(previous, continentKey)
    captured = NormalizeBondSnapshot(captured, continentKey)
    if previous == nil then
        return captured, captured ~= nil, BondSnapshotLineCount(captured)
    end
    if captured == nil then
        return previous, false, 0
    end

    local firstIndex, lastIndex = 1, 4
    if continentKey == "auroria" then firstIndex, lastIndex = 5, 7 end
    local previousByIndex, capturedByIndex = {}, {}
    for _, board in ipairs(previous.boards or {}) do previousByIndex[tonumber(board.index)] = board end
    for _, board in ipairs(captured.boards or {}) do capturedByIndex[tonumber(board.index)] = board end

    local merged = {
        continentKey = continentKey,
        faction = Text(captured.faction, "") ~= "" and Text(captured.faction, "") or Text(previous.faction, ""),
        boards = {},
    }
    local changed, addedLines = false, 0
    if merged.faction ~= Text(previous.faction, "") then changed = true end
    for index = firstIndex, lastIndex do
        local lines, seen = {}, {}
        local function append(source, isNewProbe)
            for _, rawLine in ipairs(type(source) == "table" and type(source.lines) == "table" and source.lines or {}) do
                if #lines >= BOND_SNAPSHOT_MAX_LINES then break end
                local line = BoundedBondSnapshotText(rawLine)
                if line ~= "" and seen[line] ~= true then
                    seen[line] = true
                    lines[#lines + 1] = line
                    if isNewProbe then changed, addedLines = true, addedLines + 1 end
                end
            end
        end
        append(previousByIndex[index], false)
        append(capturedByIndex[index], true)
        merged.boards[#merged.boards + 1] = { index = index, lines = lines }
    end
    return NormalizeBondSnapshot(merged, continentKey) or previous, changed, addedLines
end

local function NormalizeBondWidgetWindow(value)
    if type(value) ~= "table" then return nil end
    local floating = S.RSUI and S.RSUI.FloatingSurface or nil
    if type(floating) == "table" and type(floating.NormalizeState) == "function" then
        return floating:NormalizeState(value, {
            defaultWidth = 430, defaultHeight = 300, minWidth = 180, minHeight = 100,
            defaultOverallOpacity = 0.94, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0,
        })
    end
    return Copy(value)
end

local function NormalizeBondState(value)
    value = type(value) == "table" and value or {}
    local completed = {}
    local completedCount = 0
    for key, enabled in pairs(type(value.completedMainlandKeys) == "table" and value.completedMainlandKeys or {}) do
        key = tostring(key or "")
        if enabled == true and key ~= "" and #key <= 64 and completedCount < 64 then
            completed[key] = true
            completedCount = completedCount + 1
        end
    end
    local dateKey = tostring(value.completionDateKey or "")
    if not string.match(dateKey, "^%d%d%d%d%-%d%d%-%d%d$") then dateKey = nil end
    local dailyDateKey = tostring(value.dailyDateKey or "")
    if not string.match(dailyDateKey, "^%d%d%d%d%-%d%d%-%d%d$") then dailyDateKey = nil end
    local snapshots = {}
    for _, continentKey in ipairs({ "west", "east", "auroria" }) do
        local snap = NormalizeBondSnapshot(type(value.dailySnapshots) == "table" and value.dailySnapshots[continentKey] or nil, continentKey)
        if snap ~= nil then snapshots[continentKey] = snap end
    end
    -- 中文维护注释（2026-09-24，排序兼容）：18.303 新增 material 排序，但不新增 Store 字段，避免
    -- schema=1 的历史 envelope 再次发生 canonical 漂移。已有 continent/quantity 值保持原样；只有用户
    -- 新选择“按材料”后才会持久化 material。旧版本回退时 material 会安全归一为 continent，不破坏快照。
    local sortMode = value.sortMode == "quantity" and "quantity" or (value.sortMode == "material" and "material" or "continent")
    return { sortMode = sortMode,
        continentOrder = value.continentOrder == "east_first" and "east_first" or "west_first",
        showCompleted = value.showCompleted ~= false,
        q20 = value.q20 ~= false, q60 = value.q60 ~= false, q100 = value.q100 ~= false, auroria = value.auroria ~= false,
        excludeSame = value.excludeSame == true, priority = value.priority == "east" and "east" or "west",
        completionDateKey = dateKey, completedMainlandKeys = completed,
        dailyDateKey = dailyDateKey, dailySnapshots = snapshots,
        widgetVisible = value.widgetVisible == true,
        -- widgetWindow is the only passthrough field left in this Domain and it
        -- was the top fingerprint-drift candidate (arbitrary keys survive the
        -- Copy; RU serialization then reorders/drops them). Routing it through
        -- the shared FloatingSurface normalizer gives it a fixed shape like
        -- every other field, which both stabilizes the canonical fingerprint
        -- and repairs legacy windows saved with missing keys.
        widgetWindow = NormalizeBondWidgetWindow(value.widgetWindow) }
end
-- 中文维护注释（2026-09-15，债券 historical canonical 修复）：上一版在 schema=1 的
-- NormalizeBondState 中新增 continentOrder，导致已经合法盖章的旧存档（字段尚不存在）在下一次
-- Fresh Reload 被当前 canonical 自动补成 west_first，从而出现 fingerprint_mismatch。这里由 Bonds Store
-- 自己声明唯一可证明的历史形状：CURRENT canonical 去掉新增字段。候选没有信任权，仍必须重新计算并
-- 精确命中磁盘已经保存的 stampedFingerprint；未知 Hash、已有 continentOrder 的 payload、非 schema1
-- 都继续 fail-closed。恢复成功后第二返回值使用当前 NormalizeBondState，Core 会按当前 canonical 立即重盖章。
-- 该函数只走 Persistence mismatch 冷路径，不进入 Refresh/Tick，也不读取居民板或背包。
local function RebuildBondCanonicalForIntegrity(decoded, stampedFingerprint, currentCanonical, rawEnvelope)
    if type(decoded) ~= "table" or type(currentCanonical) ~= "table" then return nil, nil end
    if decoded.continentOrder ~= nil then return nil, nil end
    local meta = type(rawEnvelope) == "table" and rawEnvelope.__rsmeta or nil
    if type(meta) == "table" and tonumber(meta.schema) ~= 1 then return nil, nil end
    if currentCanonical.continentOrder ~= "west_first" then return nil, nil end

    local historical = Copy(currentCanonical)
    historical.continentOrder = nil
    local store = type(P.GetStore) == "function" and P:GetStore(Bonds.storeId) or nil
    if type(store) ~= "table" or type(P.FingerprintCanonicalValue) ~= "function" then return nil, nil end
    local candidateFingerprint = P:FingerprintCanonicalValue(store, historical)
    local matched = candidateFingerprint ~= nil and tostring(candidateFingerprint) == tostring(stampedFingerprint)
    store.lastHistoricalRecoveryProbe = "bonds_pre_continent_order/candidate=" .. tostring(candidateFingerprint or "nil")
        .. "/matched=" .. tostring(matched == true)
    if matched ~= true then return nil, nil end
    return historical, NormalizeBondState(decoded)
end

local function BondCompletionKey(materialKey, quantity, continentKey)
    if materialKey == nil or tonumber(quantity) == nil then return nil end
    -- 中文维护注释（2026-09-24，原大陆完成锁存）：QuestProgress 在任务交付后可能从 activeIndex 中移除，
    -- 如果只依赖当前 questStatus，原大陆已完成行会从“已完成”退回“待确认”。沿用现有每日完成 Store，
    -- 但给原大陆 key 加 auroria 前缀，避免和主大陆 material:quantity 的跨大陆共享语义碰撞；不改 schema。
    local suffix = tostring(materialKey) .. ":" .. tostring(math.floor(tonumber(quantity)))
    if continentKey == "auroria" then return "auroria:" .. suffix end
    return suffix
end
local function BondContinentKey(line)
    if type(line) ~= "table" then return nil end
    local value = line.continentKey or line.continent_key or line.continentId or line.continent_id or line.continent
    value = string.lower(tostring(value or ""))
    if value == "west" or value == "nuia" or value == "nuia_continent" or value == "西大陆" then return "west" end
    if value == "east" or value == "haranya" or value == "haranya_continent" or value == "东大陆" then return "east" end
    if value == "auroria" or value == "原大陆" then return "auroria" end
    return nil
end
local BOND_TEXT_MATERIAL = { [1] = "fabric", [2] = "leather", [3] = "lumber", [4] = "iron" }
function BA:Refresh(reason)
    local rows = {}
    reason = tostring(reason or "feature_refresh")
    local loaded, loadError = LoadStore(Bonds)
    if loaded ~= true then
        self.status, self.error = "unavailable", "本地债券数据读取失败：" .. tostring(loadError or "unknown")
        PublishFeatureUpdate(Bonds, self.revision, "bonds_store_unavailable")
        return false, self.error
    end
    local state = NormalizeBondState(Bonds.State)
    local completionDirty, snapshotDirty = false, false
    local serverDateKey = S.Utils and type(S.Utils.ServerDateKey) == "function" and tostring(S.Utils.ServerDateKey()) or "unknown"

    -- Daily resident-board contents are stable for the server day. Keep the
    -- restored cache during the cold unknown-date window; only a proven date
    -- rollover is allowed to invalidate snapshots/completion latches.
    local dateReady = string.match(serverDateKey, "^%d%d%d%d%-%d%d%-%d%d$") ~= nil
    self.serverDateKey = dateReady and serverDateKey or "unknown"
    local latestStoredDate = state.dailyDateKey
    if state.completionDateKey and (latestStoredDate == nil or state.completionDateKey > latestStoredDate) then
        latestStoredDate = state.completionDateKey
    end
    self.dateValidation = dateReady and "verified" or "server_date_unknown"
    if dateReady and latestStoredDate and serverDateKey < latestStoredDate then
        dateReady, self.dateValidation = false, "server_date_rollback"
    end
    self.snapshotDateVerified = dateReady
    -- 维护（2026-09-30）：日期未知时只展示已恢复的快照，不把新板混入昨日快照，
    -- 也不保存无日期快照再于下一次日期就绪时清掉。有限恢复探测等待可信服务器日期。
    if dateReady then
        if state.completionDateKey ~= serverDateKey then
            state.completionDateKey = serverDateKey
            state.completedMainlandKeys = {}
            completionDirty = true
        end
        if state.dailyDateKey ~= serverDateKey then
            state.dailyDateKey = serverDateKey
            state.dailySnapshots = {}
            snapshotDirty = true
        end
    end
    Bonds.State.completionDateKey = state.completionDateKey
    Bonds.State.completedMainlandKeys = Copy(state.completedMainlandKeys)
    Bonds.State.dailyDateKey = state.dailyDateKey
    Bonds.State.dailySnapshots = Copy(state.dailySnapshots)
    BA.duplicatePriorityUnresolved = nil

    -- 中文维护注释（2026-09-24，筛选/排序不重复扫包）：Dropdown 只改变 Presentation 过滤与排序，
    -- 不改变背包事实。旧实现每次 SetDisplayOrder/SetFilterMask/SetDuplicateMode 都会重新 BuildSnapshot("bag")，
    -- 大背包下属于不必要的 O(slots) 读取。Authority 现在只在 presentation 重建时复用最近一次 detached 资源
    -- 汇总；Demand 首开、手动刷新、QuestProgress/其他业务刷新仍重新读取背包，因此交任务/消耗材料后的数量不会
    -- 被长期缓存。缓存只含 10 个 materialKey->count 与状态，不持有 Native item/slot 引用，也不进入 Store。
    local resources, resourceStatus
    if reason == "presentation" and type(self.resourceTotals) == "table" then
        resources = Copy(self.resourceTotals)
        resourceStatus = self.resourceReadStatus or "unknown"
    else
        resources, resourceStatus = ReadBondResources()
        self.resourceTotals = Copy(resources)
        self.resourceReadStatus = resourceStatus
        self.resourceReads = (tonumber(self.resourceReads) or 0) + 1
    end
    local zoneHint = CurrentBondContinentKey()
    local currentKey = zoneHint
    local currentSnapshot = currentKey and state.dailySnapshots[currentKey] or nil
    local firstError = nil

    local lastReadable, lastContentCount = 0, 0
    local forceRead = reason == "page_manual" or reason == "widget_manual" or reason == "overview_manual" or reason == "manual"
    -- 维护（2026-10-07）：重载/重新上线先核对服务器日期；已完整缓存的当前大陆不再探测。
    -- 未收录地图的区域边界仍可识别新板族；原大陆缺少 5/6/7 时继续增量补读。
    local boundaryProbe = reason == "zone_changed" or reason == "entered_world" or reason == "location_retry" or reason == "left_loading"
    local projectionOnly = reason == "presentation" or reason == "quest_progress"
    local anyComplete, hasIncomplete, allComplete = false, false, true
    for _, key in ipairs({ "west", "east", "auroria" }) do
        if BondSnapshotComplete(state.dailySnapshots[key], key) then
            anyComplete = true
        else
            allComplete = false
            if state.dailySnapshots[key] ~= nil then hasIncomplete = true end
        end
    end
    local needsCurrentSnapshot = zoneHint ~= nil and not BondSnapshotComplete(currentSnapshot, zoneHint)
    local shouldRead = not projectionOnly and dateReady and (forceRead or needsCurrentSnapshot
        or (zoneHint == nil and (not anyComplete or hasIncomplete or (boundaryProbe and not allComplete))))
    local probe = {
        reason = reason, zoneHint = zoneHint or "unknown", attempted = shouldRead == true,
        readable = 0, contentCount = 0, detectedFamily = "none", detectedScope = "none",
        evidence = "not_probed", captureAction = "cache_reuse", capturedLines = 0, boardCounts = {},
    }

    -- 显式手动刷新仍可探测 1..7。板族由 Native 内容裁决，空读不会删除已有缓存。
    if shouldRead then
        local boards, readable, contentCount = {}, 0, 0
        for index = 1, 7 do
            local ok, value, err = Call("X2Resident:GetResidentBoardContent", ResidentApi, "GetResidentBoardContent", index)
            Bonds.boardReads = (tonumber(Bonds.boardReads) or 0) + 1
            if ok == true and value ~= nil then
                readable = readable + 1
                local contents, shapeError = NormalizeResidentBoardContents(value)
                if shapeError ~= nil then probe.shapeError = probe.shapeError or shapeError end
                boards[index] = { raw = value, contents = contents }
                contentCount = contentCount + #contents
            else
                boards[index] = { raw = value, contents = {} }
                if err ~= nil then firstError = firstError or tostring(err) end
            end
            probe.boardCounts[index] = BondBoardLineCount(boards, index)
        end
        lastReadable, lastContentCount = readable, contentCount
        probe.readable, probe.contentCount = readable, contentCount

        local liveScope, family, evidence = ResolveLiveBondScope(boards, zoneHint)
        probe.needsRetry = liveScope == nil or readable < 7 or probe.shapeError ~= nil
        if liveScope ~= nil then
            local firstIndex, lastIndex = liveScope == "auroria" and 5 or 1, liveScope == "auroria" and 7 or 4
            for index = firstIndex, lastIndex do
                if BondBoardLineCount(boards, index) == 0 then probe.needsRetry = true end
            end
        end
        probe.detectedFamily = family or "none"
        probe.detectedScope = liveScope or "none"
        probe.evidence = evidence or "none"
        if liveScope ~= nil then
            currentKey = liveScope
            local captured = CaptureBondSnapshot(liveScope, boards)
            local capturedLines = BondSnapshotLineCount(captured)
            probe.capturedLines = capturedLines
            local previous = state.dailySnapshots[liveScope]
            local merged, changed, addedLines = MergeBondSnapshot(previous, captured, liveScope)
            probe.addedLines = tonumber(addedLines) or 0
            probe.mergedLines = BondSnapshotLineCount(merged)
            if merged ~= nil then
                currentSnapshot = merged
                if previous == nil or changed == true then
                    state.dailySnapshots[liveScope] = merged
                    Bonds.State.dailySnapshots[liveScope] = Copy(merged)
                    snapshotDirty = true
                end
                if previous == nil then
                    probe.captureAction = "captured_new"
                elseif captured == nil then
                    probe.captureAction = "kept_cache_empty_probe"
                elseif changed == true then
                    probe.captureAction = "merged_new_board_lines"
                else
                    probe.captureAction = "cache_unchanged"
                end
            else
                currentSnapshot = nil
                probe.captureAction = captured == nil and "no_snapshot_from_probe" or "capture_rejected"
            end
        else
            currentSnapshot = currentKey and state.dailySnapshots[currentKey] or nil
            probe.captureAction = contentCount > 0 and "scope_unresolved" or "empty_probe"
        end
    end

    -- 只有真实 Native 探测才覆盖 lastBoardProbe；排序/筛选等纯 Presentation 重算保留最近一次
    -- 可诊断证据，避免用户操作下拉框后再导出报告时只看到 not_probed。
    if not projectionOnly then
        if not dateReady then
            probe.evidence, probe.captureAction, probe.needsRetry = self.dateValidation, "waiting_server_date", true
        end
        self.needsLocationRetry = probe.needsRetry == true
        if shouldRead or not dateReady then BA.lastBoardProbe = probe end
    end
    BA.lastRefreshReason = reason
    BA.boardScope = currentKey or "cached"
    BA.faction = currentSnapshot and currentSnapshot.faction or nil

    local progress = S.Services and S.Services.QuestProgressV3
    local activeIndex = progress and (progress.activeIndex or (type(progress.BuildActiveIndex) == "function" and select(1, progress:BuildActiveIndex()))) or nil
    -- 中文维护注释（2026-10-04）：snapshot.continentKey 仅记录采集来源。原生板和旧存档可能
    -- 在东大陆采集时包含西大陆任务，行标签、排序与可选合并必须按任务地区投影。修正不搬动
    -- dailySnapshots、不改变 schema/完整性指纹，也不清缓存；无法唯一识别地区时保留来源并留证据。
    local regionalRows = {}
    local classification = { patch = Bonds.RegionContinentPatch, mappedRows = 0, correctedRows = 0,
        fallbackRows = 0, ambiguousRows = 0, familyConflicts = 0, duplicatesRemoved = 0, details = {} }
    local function AppendSnapshot(continentKey, snapshot)
        if type(snapshot) ~= "table" then return end
        for _, board in ipairs(snapshot.boards or {}) do
            local index = math.floor(Number(board.index) or 0)
            if index >= 1 and index <= 7 then
                for lineIndex, textValue in ipairs(type(board.lines) == "table" and board.lines or {}) do
                    textValue = Text(textValue, "")
                    local materialKey = BOND_TEXT_MATERIAL[index]
                    local quantity = Number(string.match(textValue, "(%d+)"))
                    -- 中文维护注释（2026-09-24，原大陆行身份闭环）：板 5/6/7 不再使用一个虚拟
                    -- auroria_token。ResidentBoard 文本 + 板位先解析成 prince/queen/ancestor purse/crate，
                    -- 再与共享 ItemType/QuestId 映射汇合。这样原大陆也能显示真实“持有/缺口/完成状态”；
                    -- 文本不足以区分钱袋与箱子时保持 unknown，绝不为了显示数量而猜错材料/任务。
                    local questId, mappedQuantity, auroriaToken = BondQuestEvidence(materialKey, textValue, index)
                    if index >= 5 then materialKey = auroriaToken end
                    quantity = mappedQuantity or quantity
                    local taskContinent, regionZoneId, continentEvidence = BondTaskContinent(textValue, index, continentKey)
                    local region = regionZoneId and BOND_ZONE_CATALOG[regionZoneId] or nil
                    local regionDetail = { sourceContinentKey = continentKey, continentKey = taskContinent,
                        regionZoneId = regionZoneId, regionName = region and region.nameZh,
                        evidence = continentEvidence, board = index, text = textValue }
                    classification.details[#classification.details + 1] = regionDetail
                    if continentEvidence == "region_text" then
                        classification.mappedRows = classification.mappedRows + 1
                        if taskContinent ~= continentKey then classification.correctedRows = classification.correctedRows + 1 end
                    elseif continentEvidence == "region_ambiguous" then classification.ambiguousRows = classification.ambiguousRows + 1
                    elseif continentEvidence == "region_family_conflict" then classification.familyConflicts = classification.familyConflicts + 1
                    elseif continentEvidence == "snapshot_fallback" then classification.fallbackRows = classification.fallbackRows + 1 end
                    local requiredCount = quantity
                    local haveCount = materialKey and resources[materialKey] or nil
                    local rowStatus = materialKey and resourceStatus or "unknown"
                    if resourceStatus == "unknown" or resourceStatus == "partial" then haveCount = nil end
                    local questStatus = "UNKNOWN"
                    if questId ~= nil and progress and type(progress.QuestState) == "function" then
                        questStatus = tostring(progress:QuestState(questId, activeIndex) or "UNKNOWN")
                    end
                    local completionKey = BondCompletionKey(materialKey, quantity, taskContinent)
                    -- 日期未知时可以投影实时完成态，但不得把它持久化到旧日期的完成锁存。
                    if dateReady and questStatus == "COMPLETED" and completionKey ~= nil and state.completedMainlandKeys[completionKey] ~= true then
                        state.completedMainlandKeys[completionKey] = true
                        Bonds.State.completedMainlandKeys[completionKey] = true
                        completionDirty = true
                    end
                    local completed = questStatus == "COMPLETED" or (completionKey ~= nil and state.completedMainlandKeys[completionKey] == true)
                    local category = taskContinent == "auroria" and "auroria"
                        or (quantity == 20 and "q20" or quantity == 60 and "q60" or quantity == 100 and "q100" or nil)
                    if (category == nil or state[category]) and (state.showCompleted or completed ~= true) then
                        local row = {
                            key = "daily:" .. tostring(continentKey) .. ":" .. tostring(index) .. ":" .. tostring(lineIndex),
                            board = index, name = AURORIA_BOND_LABEL[materialKey] or BOND_BOARD_NAMES[index] or ("分类" .. tostring(index)),
                            continent = BOND_CONTINENT_LABEL[taskContinent] or tostring(taskContinent), continentKey = taskContinent,
                            sourceContinentKey = continentKey, regionZoneId = regionZoneId,
                            regionName = region and region.nameZh, continentEvidence = continentEvidence,
                            text = textValue, quantity = quantity, materialKey = materialKey, auroriaToken = auroriaToken,
                            requiredCount = requiredCount, haveCount = haveCount,
                            shortage = requiredCount and haveCount and math.max(0, requiredCount - haveCount) or nil,
                            resourceStatus = rowStatus,
                            -- 中文维护注释：resourceStatus 保留机器态供诊断/兼容，玩家表格使用本地化文本，
                            -- 避免直接暴露 ready/partial/unknown 造成语义不清；这里仍由同一 Authority 生成。
                            resourceStatusText = rowStatus == "ready" and "可读取" or (rowStatus == "partial" and "部分" or "未知"),
                            resourceText = haveCount and tostring(haveCount) or "?",
                            shortageText = requiredCount and haveCount and tostring(math.max(0, requiredCount - haveCount)) or "?",
                            questId = questId, questStatus = questStatus, completed = completed,
                            statusText = completed and "已完成" or (QUEST_STATUS_TEXT[questStatus] or "待确认"),
                            tone = completed and "green" or (QUEST_STATUS_TONE[questStatus] or "muted"),
                        }
                        regionDetail.key = row.key
                        -- 只有同一已识别地区、同一板、同一材料与数量才是跨缓存的同一委托。
                        -- 数量相同但地区不同的任务仍保留，未识别地区也不擅自折叠。
                        local identity = regionZoneId and materialKey and quantity and
                            (tostring(regionZoneId) .. ":" .. tostring(index) .. ":" .. tostring(materialKey) .. ":" .. tostring(quantity)) or nil
                        local previous = identity and regionalRows[identity] or nil
                        if previous ~= nil then
                            classification.duplicatesRemoved = classification.duplicatesRemoved + 1
                            if row.sourceContinentKey == row.continentKey and previous.row.sourceContinentKey ~= previous.row.continentKey then
                                previous.detail.duplicateOf = row.key
                                rows[previous.position] = row
                                regionalRows[identity] = { row = row, position = previous.position, detail = regionDetail }
                            else
                                regionDetail.duplicateOf = previous.row.key
                            end
                        else
                            rows[#rows + 1] = row
                            if identity ~= nil then regionalRows[identity] = { row = row, position = #rows, detail = regionDetail } end
                        end
                    end
                end
            end
        end
    end

    for _, continentKey in ipairs({ "west", "east", "auroria" }) do
        AppendSnapshot(continentKey, state.dailySnapshots[continentKey])
    end

    -- Mainland daily identity is material + quantity. A Leather:20 completion
    -- is global across west/east, while Leather:20/60/100 remain three distinct
    -- tasks. De-duplication therefore uses that exact key and may also collapse
    -- accidental duplicates within one continent.
    if state.excludeSame then
        local groups = {}
        for _, row in ipairs(rows) do
            if row.continentKey == "west" or row.continentKey == "east" then
                local key = row.materialKey and row.quantity and (tostring(row.materialKey) .. ":" .. tostring(row.quantity)) or nil
                if key ~= nil then
                    groups[key] = groups[key] or { west = {}, east = {} }
                    groups[key][row.continentKey][#groups[key][row.continentKey] + 1] = row
                end
            end
        end
        local suppressed = {}
        local priority = state.priority == "east" and "east" or "west"
        local other = priority == "west" and "east" or "west"
        for _, group in pairs(groups) do
            local total = #group.west + #group.east
            if total > 1 then
                local winner = group[priority][1] or group[other][1]
                for _, row in ipairs(group.west) do if row ~= winner then suppressed[row] = true end end
                for _, row in ipairs(group.east) do if row ~= winner then suppressed[row] = true end end
            end
        end
        if next(suppressed) ~= nil then
            local filtered = {}
            for _, row in ipairs(rows) do if suppressed[row] ~= true then filtered[#filtered + 1] = row end end
            rows = filtered
        end
    end

    -- 中文维护注释（2026-09-24，债券三维排序）：18.302 的“按数量 · 西→东/东→西”只改变
    -- 数量主键、却仍用大陆方向作为第二语义，用户无法表达“数量少→多/多→少”，也没有按材料聚合，
    -- 因而实际体验会像“少了排序”。18.303 不增加新的 Store 字段：继续复用 sortMode + continentOrder
    -- 这两个稳定字段，其中 continent 模式解释 order 为大陆方向；quantity/material 模式解释同一二值为
    -- 正向/反向。Authority 只重排 detached rows，不删行、不改 dailySnapshots、不重扫背包。
    local forward = state.continentOrder ~= "east_first"
    local continentRank = state.sortMode == "continent" and (forward
        and { west = 1, east = 2, auroria = 3 } or { east = 1, west = 2, auroria = 3 })
        or { west = 1, east = 2, auroria = 3 }
    -- 材料正序按 ResidentBoard 的稳定业务语义排列，不依赖本地化名称排序，避免中/俄文环境下顺序漂移。
    local materialRank = {
        fabric = 1, leather = 2, lumber = 3, iron = 4,
        prince_purse = 5, prince_crate = 6,
        queen_purse = 7, queen_crate = 8,
        ancestor_purse = 9, ancestor_crate = 10,
    }
    table.sort(rows, function(a, b)
        local ac, bc = continentRank[a.continentKey] or 9, continentRank[b.continentKey] or 9
        local aq, bq = Number(a.quantity), Number(b.quantity)
        local am, bm = materialRank[a.materialKey] or 99, materialRank[b.materialKey] or 99
        if state.sortMode == "quantity" then
            if aq ~= bq then
                if aq == nil then return false end
                if bq == nil then return true end
                if forward then return aq < bq end
                return aq > bq
            end
            if ac ~= bc then return ac < bc end
            if am ~= bm then return am < bm end
        elseif state.sortMode == "material" then
            if am ~= bm then
                if forward then return am < bm end
                return am > bm
            end
            if aq ~= bq then
                if aq == nil then return false end
                if bq == nil then return true end
                if forward then return aq < bq end
                return aq > bq
            end
            if ac ~= bc then return ac < bc end
        else
            if ac ~= bc then return ac < bc end
            -- 按大陆模式只负责把同一大陆聚在一起，组内继续保持居民板 1→7 的自然顺序。
            local ab, bb = Number(a.board) or 99, Number(b.board) or 99
            if ab ~= bb then return ab < bb end
            if am ~= bm then return am < bm end
        end
        return tostring(a.key) < tostring(b.key)
    end)

    local capturedCount = 0
    for _, key in ipairs({ "west", "east", "auroria" }) do if state.dailySnapshots[key] ~= nil then capturedCount = capturedCount + 1 end end
    local status, errorText
    if capturedCount > 0 then
        status, errorText = "ready", nil
    elseif lastReadable > 0 and lastContentCount == 0 then
        status, errorText = "empty", "居民板暂无委托内容"
    else
        status, errorText = "unavailable", firstError or "今天尚未记录居民债券；进入可读取居民板的地区后刷新一次"
    end
    self.rows, self.status, self.resourceStatus, self.error = rows, status, resourceStatus, errorText
    self.regionClassification = classification
    self.snapshotDateKey, self.snapshotCount = state.dailyDateKey, capturedCount
    self.revision = self.revision + 1
    local persisted, persistError = true, nil
    if completionDirty or snapshotDirty then
        -- 维护（2026-10-07）：每日事实不能只排队延迟保存。先保留 Core 的有界失败重试，
        -- 再立即落盘并校验回读；返回成功前已验证日期、三个大陆快照和完成态的一致存档。
        persisted, persistError = P:MarkDirty(Bonds.storeId, 5000, "bond_daily_snapshot_or_completion")
        if persisted == true then
            persisted, persistError = P:SaveStore(Bonds.storeId, { durable = true, consumeDirty = true, reason = "bond_daily_commit" })
        end
        self.lastSaveIntent = { accepted = persisted == true, durable = persisted == true,
            error = persisted ~= true and tostring(persistError or "daily_save_failed") or nil }
    elseif dateReady and forceRead and self.lastSaveIntent and self.lastSaveIntent.accepted ~= true then
        -- 显式刷新允许重试未提交的快照；界面/任务投影不反复发起写盘。
        persisted, persistError = P:SaveStore(Bonds.storeId, { durable = true, consumeDirty = true, reason = "bond_daily_retry" })
        self.lastSaveIntent = { accepted = persisted == true, durable = persisted == true,
            error = persisted ~= true and tostring(persistError or "daily_save_failed") or nil }
    end
    if persisted ~= true then self.error = "债券数据本地保存失败：" .. tostring(persistError or "unknown") end
    PublishFeatureUpdate(Bonds, self.revision, "bonds_refresh")
    return capturedCount > 0 and persisted == true, persisted ~= true and self.error or nil
end

function BA:GetProjection()
    local snapshots = type(Bonds.State.dailySnapshots) == "table" and Bonds.State.dailySnapshots or {}
    -- 中文维护注释（2026-09-15，Projection 覆盖状态）：Presentation 需要告诉玩家“今天西/东大陆
    -- 哪些已读取”，但禁止直接读 State/Store。因此 Authority 只投影三个布尔值和当前大陆标签，不暴露
    -- snapshot 原文/嵌套表，也不复制第二份业务数据。该 detached 状态不会触发任何 Native 读取。
    local coverage = { west = snapshots.west ~= nil, east = snapshots.east ~= nil, auroria = snapshots.auroria ~= nil }
    -- 只读 Core 的当前状态；失败后后台重试成功也不能被旧 lastSaveIntent 掩盖。
    local store = P:GetStore(Bonds.storeId)
    local saveFailure = store and type(P.GetStoreFailureKind) == "function" and P:GetStoreFailureKind(store) or nil
    local saveStatus = saveFailure and "failed" or (store and (store.dirty or store.needsBarrierVerify) and "pending" or "saved")
    return {
        revision = self.revision, rows = Copy(self.rows), status = self.status, resourceStatus = self.resourceStatus,
        error = self.error, duplicatePriorityUnresolved = self.duplicatePriorityUnresolved,
        boardScope = self.boardScope, currentContinentLabel = BOND_CONTINENT_LABEL[self.boardScope], faction = self.faction,
        snapshotDateKey = self.snapshotDateKey, snapshotCount = tonumber(self.snapshotCount) or 0,
        snapshotDateVerified = self.snapshotDateVerified == true, dateValidation = self.dateValidation,
        dailySaveStatus = saveStatus, dailySaveError = saveFailure and (store.lastError or store.writeFenceReason or saveFailure) or nil,
        dailySnapshotStatus = coverage,
        lastBoardProbe = Copy(self.lastBoardProbe),
        regionClassification = Copy(self.regionClassification),
        selectedKey = Bonds.selectedKey,
    }
end
-- The daily snapshot domain nests 5 tables deep with up to 21 boards of CJK
-- text; the generic helper budget (depth 6 / 320 nodes) sat at the boundary
-- and silently starved the integrity upgrade's decode validation.
RegisterStore(Bonds.storeId, "v3.life.bonds", function() return NormalizeBondState(nil) end,
    function() return Copy(Bonds.State) end,
    function(value) Bonds.State = NormalizeBondState(value) end,
    NormalizeBondState,
    { maxDepth = 8, maxNodes = 960, maxStringBytes = 24576, maxEntriesPerTable = 192 },
    RebuildBondCanonicalForIntegrity) -- 中文维护注释：仅 Bonds 注册 pre-continentOrder exact historical bridge；Core 规则不放宽。
Bonds.ApiDependencies = {
    "X2Resident:GetResidentBoardContent", "X2Bag:Capacity", "X2Bag:GetBagItemInfo", "X2Unit:GetCurrentZoneGroup",
    -- 中文维护注释（2026-09-28，native-dependency-ownership-2）：Bonds AcquireConsumer 会启动共享 QuestProgressV3，
    -- 其基础 Refresh 必须读取活动任务索引与完成/可交付状态。FeatureRuntime 以实现层 ApiDependencies 优先，
    -- 因此这里必须由 Bonds 自己声明 X2Quest，禁止借用 Activities/Tasks 偶然已经导入的 namespace。
    "X2Quest:GetActiveQuestListCount", "X2Quest:GetActiveQuestType",
    "X2Quest:IsCompleted", "X2Quest:IsReadyForCompleteQuest",
}
function Bonds:Initialize() return LoadStore(self) end
function Bonds:SubscribeProgress()
    if self.progressSubscribed == true then return true end
    if S.Events == nil or type(S.Events.SubscribeInternal) ~= "function" then return false, "quest progress internal event unavailable" end
    local subscribed = S.Events:SubscribeInternal("v3.quest_progress.updated", self, function()
        -- 中文维护注释（bond-quest-reactive-1）：居民板 Store/材料快照仍由 Bonds Authority 持有；这里只在已有
        -- Bonds Consumer 时重算 questStatus，不新增 ResidentBoard 轮询。QuestProgress 的事件由 Native Quest 事件
        -- 合并后发布，因此交任务/变为可交付可以在事件后立即刷新主页面与悬浮窗。
        if Bonds.enabled == true and Bonds.consumerCount > 0 then BA:Refresh("quest_progress") end
    end)
    if subscribed ~= true then return false, "quest progress internal subscribe failed" end
    self.progressSubscribed = true
    return true
end
function Bonds:UnsubscribeProgress()
    if self.progressSubscribed ~= true then return true end
    if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
    self.progressSubscribed = false
    return true
end
function Bonds:ScheduleLocationRefresh(reason, continuing)
    if self.enabled ~= true or (tonumber(self.consumerCount) or 0) <= 0 then return true end
    -- 维护（2026-09-30）：只在需求首开/显式刷新/地图生命周期边界启动有限恢复序列。
    -- 一次 750ms 探测可能早于慢客户端加载；最多再做 1500/3000ms 两次，不创建永久轮询。
    -- 新地图事件使旧 epoch 失效；退出需求或热重载后，迟到回调无权读取或保存新场景。
    if continuing ~= true then
        self.locationEpoch = (tonumber(self.locationEpoch) or 0) + 1
        self.locationAttempt, self.locationReason = 0, tostring(reason or "zone_changed")
    end
    local attempt = (tonumber(self.locationAttempt) or 0) + 1
    local delay = BONDS_LOCATION_DELAYS[attempt]
    if delay == nil then self.locationRecoveryStatus = "exhausted"; return true end
    self.locationAttempt = attempt
    if S.Scheduler == nil or type(S.Scheduler.AddOneShot) ~= "function" then
        self.locationRecoveryStatus = "scheduler_unavailable"
        return true -- 首读/手动刷新仍有效；不可在缺调度器时递归伪造等待。
    end
    local epoch, generation = self.locationEpoch, S.Generation
    local added = S.Scheduler:AddOneShot(BONDS_ZONE_REFRESH_TASK, delay, function()
        if ReplicatedSuite ~= S or S.Generation ~= generation or Bonds.locationEpoch ~= epoch
            or Bonds.enabled ~= true or (tonumber(Bonds.consumerCount) or 0) <= 0 then return true end
        BA:Refresh("location_retry")
        if Bonds.locationEpoch ~= epoch then return true end
        if BA.needsLocationRetry then return Bonds:ScheduleLocationRefresh(Bonds.locationReason, true) end
        Bonds.locationRecoveryStatus = "complete"
        return true
    end, self, "P2", 1)
    self.locationRecoveryStatus = added == true and "pending" or "schedule_failed"
    if added == true and type(S.Scheduler.SetTaskModule) == "function" then
        S.Scheduler:SetTaskModule(BONDS_ZONE_REFRESH_TASK, self.Id, false)
    end
    return added == true
end
function Bonds:SubscribeLocationEvents()
    if self.locationSubscribed == true then return true end
    if S.Events == nil or type(S.Events.SubscribeOptional) ~= "function" then return true end
    local zoneOk = S.Events:SubscribeOptional("ENTER_ANOTHER_ZONEGROUP", self, function()
        return Bonds:ScheduleLocationRefresh("zone_changed")
    end)
    local worldOk = S.Events:SubscribeOptional("ENTERED_WORLD", self, function()
        return Bonds:ScheduleLocationRefresh("entered_world")
    end)
    -- Optional Native events are an enhancement, not a hard startup dependency. Manual refresh and Demand probe
    -- remain valid fallback paths if an older RU client cannot register one of them. Track whether any listener landed
    -- so release can deterministically clean the owner without introducing a second event Authority.
    -- 已有客户端加载结束事件；仍为 optional，旧客户端不支持时手动刷新和有限恢复可用。
    local loadingOk = S.Events:SubscribeOptional("LEFT_LOADING", self, function()
        return Bonds:ScheduleLocationRefresh("left_loading")
    end)
    self.locationSubscribed = zoneOk == true or worldOk == true or loadingOk == true
    return true
end
function Bonds:UnsubscribeLocationEvents()
    self.locationEpoch = (tonumber(self.locationEpoch) or 0) + 1
    self.locationRecoveryStatus = "cancelled"
    if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(BONDS_ZONE_REFRESH_TASK) end
    if self.locationSubscribed == true and S.Events ~= nil and type(S.Events.UnsubscribeOwner) == "function" then
        S.Events:UnsubscribeOwner(self)
    end
    self.locationSubscribed = false
    return true
end
function Bonds:StartServerDateCheck()
    if S.Scheduler == nil or type(S.Scheduler.AddTask) ~= "function" then return true end
    self.serverDateEpoch = (tonumber(self.serverDateEpoch) or 0) + 1
    local generation, epoch = S.Generation, self.serverDateEpoch
    -- 维护（2026-10-07）：打开债券时每分钟只核对服务器日期，同日不扫居民板或写盘。
    -- 确认换日才重建每日事实；无 Consumer 时释放任务，旧代回调不能采集新会话。
    local added = S.Scheduler:AddTask(BONDS_SERVER_DATE_TASK, 60000, function()
        if ReplicatedSuite ~= S or S.Generation ~= generation or Bonds.serverDateEpoch ~= epoch or Bonds.enabled ~= true
            or (tonumber(Bonds.consumerCount) or 0) <= 0 then return true end
        local dateKey = S.Utils and type(S.Utils.ServerDateKey) == "function" and tostring(S.Utils.ServerDateKey()) or "unknown"
        if dateKey ~= BA.serverDateKey then
            BA:Refresh("server_date_changed")
            if BA.needsLocationRetry then Bonds:ScheduleLocationRefresh("server_date_changed") end
        end
        return true
    end, false, self, "P3", 1)
    if added == true and type(S.Scheduler.SetTaskModule) == "function" then
        S.Scheduler:SetTaskModule(BONDS_SERVER_DATE_TASK, self.Id, false)
    end
    return added == true
end
function Bonds:StopServerDateCheck()
    self.serverDateEpoch = (tonumber(self.serverDateEpoch) or 0) + 1
    if S.Scheduler and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(BONDS_SERVER_DATE_TASK) end
    return true
end
function Bonds:ReconcileDemand(_, before, after)
    local beforeCount = tonumber(before and before.count) or 0
    local afterCount = tonumber(after and after.count) or 0
    if beforeCount <= 0 and afterCount > 0 then
        local progress = S.Services and S.Services.QuestProgressV3 or nil
        if type(progress) ~= "table" or type(progress.AcquireConsumer) ~= "function" then return false, "quest progress service unavailable" end
        local acquired, acquireErr = progress:AcquireConsumer(self.progressConsumerToken)
        if acquired ~= true then return false, acquireErr end
        self.progressConsumerHeld = true
        local subscribed, subErr = self:SubscribeProgress()
        if subscribed ~= true then
            progress:ReleaseConsumer(self.progressConsumerToken)
            self.progressConsumerHeld = false
            return false, subErr
        end
        self:SubscribeLocationEvents()
        -- Demand 0->1 在 QuestProgress 已完成一次同步刷新后再重算 Bonds，确保首次打开也使用最新 activeIndex。
        BA:Refresh("demand_start")
        self:StartServerDateCheck()
        if BA.needsLocationRetry then self:ScheduleLocationRefresh("demand_start") end
    elseif beforeCount > 0 and afterCount <= 0 then
        self:StopServerDateCheck()
        self:UnsubscribeLocationEvents()
        self:UnsubscribeProgress()
        if self.progressConsumerHeld == true then
            local progress = S.Services and S.Services.QuestProgressV3 or nil
            if type(progress) ~= "table" or type(progress.ReleaseConsumer) ~= "function" then return false, "quest progress release unavailable" end
            local released, releaseErr = progress:ReleaseConsumer(self.progressConsumerToken)
            if released ~= true then return false, releaseErr or "quest progress release failed" end
            self.progressConsumerHeld = false
        end
    end
    return true
end
function Bonds:Enable() self.enabled = true; return true end
function Bonds:Disable(reason) local ok, err = self.Demand:Clear(reason or "bonds_disable"); if ok ~= true then return false, err end; self.enabled = false; return true end
function Bonds:AcquireConsumer(token) if not self.enabled then return false, "居民板功能已关闭" end return self.Demand:Acquire(token, {}, "bonds_consumer") end
function Bonds:ReleaseConsumer(token) return self.Demand:Release(token, "bonds_consumer") end
function Bonds:Refresh(reason)
    if not self.enabled or self.consumerCount <= 0 then return true end
    reason = tostring(reason or "feature_refresh")
    local result = BA:Refresh(reason)
    if reason ~= "presentation" and reason ~= "quest_progress" and BA.needsLocationRetry then
        self:ScheduleLocationRefresh(reason)
    end
    return result
end
-- Presentation must consume a detached Feature read model rather than reaching
-- through to Bonds.Authority. Keep this facade explicit so the public Feature
-- contract stays symmetric with Trade/Treasure/Fishing.
function Bonds:GetProjection() return BA:GetProjection() end
function Bonds:GetRow(key)
    key = tostring(key or "")
    if key == "" then return nil end
    for _, row in ipairs(BA.rows or {}) do
        if tostring(row.key or "") == key or tostring(row.questId or "") == key then return Copy(row) end
    end
    return nil
end
function Bonds:SelectRow(key)
    self.selectedKey = key ~= nil and tostring(key) or nil
    return true
end
function Bonds:GetSelectedRow()
    if self.selectedKey == nil then return nil end
    return self:GetRow(self.selectedKey)
end

-- §Bonds diagnostics (dayKey / per-continent load state / snapshot volume /
-- board read counter) for the acceptance snapshot. Reads only live state.
function Bonds:DescribeDailyCache()
    local snapshots = type(self.State.dailySnapshots) == "table" and self.State.dailySnapshots or {}
    -- 维护（2026-09-30）：区分“未采集 / 已缓存但被合并筛选隐藏 / 等待落盘 / 写入失败”。
    -- 只读已加载 State、Projection 和 Core 元数据；不 Load/Save/探测，也不解除任何 fence。
    local coverage = {}
    for _, key in ipairs({ "west", "east", "auroria" }) do
        coverage[key] = { lines = BondSnapshotLineCount(snapshots[key]), visibleRows = 0, visibleSourceRows = 0 }
    end
    for _, row in ipairs(BA.rows or {}) do
        if coverage[row.continentKey] then coverage[row.continentKey].visibleRows = coverage[row.continentKey].visibleRows + 1 end
        if coverage[row.sourceContinentKey] then coverage[row.sourceContinentKey].visibleSourceRows = coverage[row.sourceContinentKey].visibleSourceRows + 1 end
    end
    local store = type(P.GetStore) == "function" and P:GetStore(self.storeId) or nil
    local persistence = type(store) == "table" and {
        loaded = store.loaded == true, loadStatus = store.loadStatus, dirty = store.dirty == true,
        writeFenced = store.writeFenced == true, lastError = store.lastError or store.writeFenceReason,
        failure = type(P.GetStoreFailureKind) == "function" and P:GetStoreFailureKind(store) or nil,
        needsBarrierVerify = store.needsBarrierVerify == true, lastVerifyOk = store.lastVerifyOk,
        dirtyRevision = store.dirtyRevision, lastSavedRevision = store.lastSavedRevision, lastSaveAt = store.lastSaveAt,
    } or { loaded = false, loadStatus = "unavailable" }
    return {
        patch = self.CrossContinentPatch, serverDateKey = BA.serverDateKey or "unknown",
        dateValidation = BA.dateValidation or "not_sampled", snapshotDateVerified = BA.snapshotDateVerified == true,
        regionClassification = Copy(BA.regionClassification),
        coverage = coverage, persistence = persistence, lastSaveIntent = Copy(BA.lastSaveIntent),
        recovery = { status = self.locationRecoveryStatus or "idle", attempt = tonumber(self.locationAttempt) or 0,
            maxAttempts = #BONDS_LOCATION_DELAYS, reason = self.locationReason },
        filters = { q20 = self.State.q20, q60 = self.State.q60, q100 = self.State.q100, auroria = self.State.auroria,
            showCompleted = self.State.showCompleted, excludeSame = self.State.excludeSame, priority = self.State.priority },
        dayKey = tostring(self.State.dailyDateKey or "-"),
        westLoaded = snapshots.west ~= nil,
        eastLoaded = snapshots.east ~= nil,
        auroriaLoaded = snapshots.auroria ~= nil,
        snapshotCount = (snapshots.west ~= nil and 1 or 0) + (snapshots.east ~= nil and 1 or 0) + (snapshots.auroria ~= nil and 1 or 0),
        completedCount = (function() local n = 0 for _ in pairs(type(self.State.completedMainlandKeys) == "table" and self.State.completedMainlandKeys or {}) do n = n + 1 end return n end)(),
        boardReads = tonumber(self.boardReads) or 0,
        resourceReads = tonumber(BA.resourceReads) or 0,
        -- 中文维护注释（2026-09-24，诊断证据）：只暴露上一次 bounded 1..7 探测摘要，不复制
        -- ResidentBoard 原始文本，既能判断“没读/读空/板族未识别/保留旧缓存”，又控制诊断体积。
        lastBoardProbe = Copy(BA.lastBoardProbe),
    }
end
function Bonds:GetHealth()
    return { patch = self.CrossContinentPatch, enabled = self.enabled == true,
        consumerCount = tonumber(self.consumerCount) or 0, status = BA.status,
        error = BA.error, dailyCache = self:DescribeDailyCache() }
end
function Bonds:GetSortMode() return Bonds.State.sortMode end
function Bonds:SetSortMode(mode)
    if mode ~= "continent" and mode ~= "quantity" and mode ~= "material" then return false, "债券排序模式无效" end
    local persisted, persistErr = PersistLifeMutation(self, "bonds_sort", function(state) state.sortMode = mode; return true end)
    if persisted ~= true then return false, persistErr end
    return self:Refresh("presentation")
end
function Bonds:GetContinentOrder() return NormalizeBondState(Bonds.State).continentOrder end
function Bonds:SetContinentOrder(order)
    if order ~= "west_first" and order ~= "east_first" then return false, "大陆排序方向无效" end
    -- 中文维护注释：大陆顺序是纯 Presentation 偏好，但由 Bonds Store 持久化并由 Authority 排序，
    -- 这样主页面/悬浮窗共享同一顺序。该命令不读 ResidentBoard、不修改 dailySnapshots，也不触发去重。
    local persisted, persistErr = PersistLifeMutation(self, "bonds_continent_order", function(state) state.continentOrder = order; return true end)
    if persisted ~= true then return false, persistErr end
    return self:Refresh("presentation")
end
function Bonds:GetBondFilter() return NormalizeBondState(Bonds.State) end
function Bonds:GetBondFilterOption(key) return Bonds:GetBondFilter()[key] == true end
function Bonds:GetDuplicatePriority() return Bonds:GetBondFilter().priority end
function Bonds:SetBondFilterOption(key, enabled)
    if key ~= "q20" and key ~= "q60" and key ~= "q100" and key ~= "auroria" and key ~= "excludeSame" then return false, "债券筛选键无效" end
    local persisted, persistErr = PersistLifeMutation(self, "bonds_filter", function(state) state[key] = enabled == true; return true end)
    if persisted ~= true then return false, persistErr end
    return self:Refresh("presentation")
end
function Bonds:SetDuplicatePriority(priority)
    if priority ~= "west" and priority ~= "east" then return false, "重复材料优先大陆无效" end
    -- 中文维护注释（2026-09-15，合并优先级无副作用）：旧实现会在选择“优先西/东”时顺手把
    -- excludeSame=true，导致用户只是想改顺序/偏好却突然少一整个大陆的重复行。priority 现在只保存
    -- “合并模式下保留哪一侧”，是否合并只能由 SetBondFilterOption(excludeSame) 显式决定。
    local persisted, persistErr = PersistLifeMutation(self, "bonds_priority", function(state) state.priority = priority; return true end)
    if persisted ~= true then return false, persistErr end
    return self:Refresh("presentation")
end
-- 中文维护注释（2026-09-24，债券下拉框原子命令）：主页面与悬浮窗都改为 3 个 Dropdown。
-- Presentation 不能连续模拟点击多个旧按钮来表达一个选项，否则会产生多次 Store 写入/Projection 发布，
-- 还可能在 Dropdown popup 未关闭时重入刷新。这里提供组合命令，一次 PersistLifeMutation 原子提交。
-- 旧 SetSortMode/SetContinentOrder/SetBondFilterOption/SetDuplicatePriority 继续保留，保证升级/扩展兼容。
function Bonds:GetDisplayOrderKey()
    local state = NormalizeBondState(Bonds.State)
    return tostring(state.sortMode) .. ":" .. tostring(state.continentOrder)
end
function Bonds:SetDisplayOrder(mode, order)
    if mode ~= "continent" and mode ~= "quantity" and mode ~= "material" then return false, "债券排序模式无效" end
    if order ~= "west_first" and order ~= "east_first" then return false, "大陆排序方向无效" end
    local persisted, persistErr = PersistLifeMutation(self, "bonds_display_order", function(state)
        state.sortMode, state.continentOrder = mode, order
        return true
    end)
    if persisted ~= true then return false, persistErr end
    return self:Refresh("presentation")
end
function Bonds:GetFilterMask()
    local state = NormalizeBondState(Bonds.State)
    local mask = 0
    if state.q20 then mask = mask + 1 end
    if state.q60 then mask = mask + 2 end
    if state.q100 then mask = mask + 4 end
    if state.auroria then mask = mask + 8 end
    return mask
end
function Bonds:SetFilterMask(mask)
    mask = tonumber(mask)
    if mask == nil or mask < 0 or mask > 15 or math.floor(mask) ~= mask then return false, "债券筛选组合无效" end
    local q20 = (mask % 2) >= 1
    local q60 = (math.floor(mask / 2) % 2) >= 1
    local q100 = (math.floor(mask / 4) % 2) >= 1
    local auroria = (math.floor(mask / 8) % 2) >= 1
    local persisted, persistErr = PersistLifeMutation(self, "bonds_filter_mask", function(state)
        state.q20, state.q60, state.q100, state.auroria = q20, q60, q100, auroria
        return true
    end)
    if persisted ~= true then return false, persistErr end
    return self:Refresh("presentation")
end
function Bonds:GetDuplicateMode()
    local state = NormalizeBondState(Bonds.State)
    if state.excludeSame ~= true then return "all" end
    return state.priority == "east" and "east" or "west"
end
function Bonds:SetDuplicateMode(mode)
    if mode ~= "all" and mode ~= "west" and mode ~= "east" then return false, "重复材料显示模式无效" end
    local persisted, persistErr = PersistLifeMutation(self, "bonds_duplicate_mode", function(state)
        state.excludeSame = mode ~= "all"
        -- “全部显示”不改历史 priority；用户以后再次选择合并时仍保留上次偏好。
        if mode == "west" or mode == "east" then state.priority = mode end
        return true
    end)
    if persisted ~= true then return false, persistErr end
    return self:Refresh("presentation")
end

Bonds.Commands = { SetDisplayOrder = function(_, mode, order) return Bonds:SetDisplayOrder(mode, order) end, SetFilterMask = function(_, mask) return Bonds:SetFilterMask(mask) end, SetDuplicateMode = function(_, mode) return Bonds:SetDuplicateMode(mode) end, Refresh = function(_, reason) return Bonds:Refresh(reason) end, SetSortMode = function(_, mode) return Bonds:SetSortMode(mode) end, SetContinentOrder = function(_, order) return Bonds:SetContinentOrder(order) end, SetBondFilterOption = function(_, key, enabled) return Bonds:SetBondFilterOption(key, enabled) end, SetDuplicatePriority = function(_, priority) return Bonds:SetDuplicatePriority(priority) end,
    SelectRow = function(_, key) return Bonds:SelectRow(key) end, GetSelectedRow = function() return Bonds:GetSelectedRow() end, GetRow = function(_, key) return Bonds:GetRow(key) end,
    GetWidgetVisible = function() return Bonds:GetWidgetVisible() end, SetWidgetVisible = function(_, value, reason) return Bonds:SetWidgetVisible(value, reason) end,
    SetWidgetWindowState = function(_, value, reason) return Bonds:SetWidgetWindowState(value, reason) end,
    MarkStoreDirty = function(_, delayMs, reason) return Bonds:MarkStoreDirty(delayMs, reason) end }
local bondsDemand, bondsErr = Demand:Create({ id = "feature:" .. Bonds.Id, owner = Bonds, projectionOwner = Bonds, projectionConsumersField = "consumers", projectionCountField = "consumerCount", reconcile = function(lease, before, after) return Bonds:ReconcileDemand(lease, before, after) end })
if bondsDemand == nil then error(bondsErr) end
Bonds.Demand = bondsDemand
ok, err = Runtime:RegisterImplementation(Bonds.Id, Bonds); if ok ~= true then error(err) end
