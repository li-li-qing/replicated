------------------------------------------------------------------------
-- Replicated Suite V3 - Auction Search Bridge
--
-- One explicit-search bridge between player-facing auction helpers and the
-- existing AuctionQueryV3 server-query Authority.  Native Auction EditBox
-- synchronization is an optional presentation enhancement only: it is bounded,
-- read-back verified and fail-closed.  Failure to prove a safe EditBox never
-- blocks the authoritative AuctionQueryV3 search.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}

local B = {
    version = 1,
    SearchBridgeContractVersion = 1,
    NativeSyncContractVersion = 1,
    presentationBoundary = "service_only",
    maxProbeDepth = 3,
    maxProbeNodes = 128,
    generation = 0,
    auctionVisible = false,
    candidate = nil,
    candidatePath = nil,
    candidateName = nil,
    candidateType = nil,
    probedGeneration = nil,
    fallbackCount = 0,
    snapshot = {
        nativeSync = "idle", candidateStatus = "none", fallbackCount = 0,
        generation = 0, reason = nil,
    },
}
S.Services.AuctionSearchBridgeV3 = B

local Query = S.Services and S.Services.AuctionQueryV3 or nil
local Surface = S.Services and S.Services.AuctionSurfaceV3 or nil

local function Copy(value, seen)
    if S.Utils ~= nil and type(S.Utils.DeepCopy) == "function" then return S.Utils.DeepCopy(value) end
    if type(value) ~= "table" then return value end
    seen = seen or {}; if seen[value] then return nil end; seen[value] = true
    local out = {}; for key, child in pairs(value) do out[key] = Copy(child, seen) end
    return out
end
local function Trim(value) return (tostring(value or ""):match("^%s*(.-)%s*$")) or "" end
local function SafeCall(object, method, ...)
    if object == nil then return false, nil end
    local args, count = { ... }, select("#", ...)
    -- 中文维护注释（2026-09-14，Native userdata fail-closed）：RU 原生窗口子对象可能是带受限
    -- __index 的 userdata。方法探测本身也可能抛错，不能让可选的搜索框同步打断已经接受的服务器查询；
    -- 因此“取方法 + 调用方法”都置于 pcall 中，任何不透明对象都只视为不可验证候选并降级。
    local ok, value = pcall(function()
        local fn = object[method]
        if type(fn) ~= "function" then return nil end
        return fn(object, unpack(args, 1, count))
    end)
    return ok == true and value ~= nil, value
end
local function Lower(value) return tostring(value or ""):lower() end
local function SearchSemantic(path, name)
    local text = Lower(tostring(path or "") .. " " .. tostring(name or ""))
    return text:find("search", 1, true) ~= nil or text:find("keyword", 1, true) ~= nil
end
local function CandidateFacts(value, path)
    if value == nil then return nil end
    local methodsOk, hasMethods = pcall(function()
        return type(value.GetObjectType) == "function" and type(value.GetText) == "function" and type(value.SetText) == "function"
    end)
    if methodsOk ~= true or hasMethods ~= true then return nil end
    local okType, objectType = SafeCall(value, "GetObjectType")
    if okType ~= true then return nil end
    local typeText = Lower(objectType)
    if typeText:find("editbox", 1, true) == nil and typeText ~= "edit" then return nil end
    local _, objectName = SafeCall(value, "GetName")
    if SearchSemantic(path, objectName) ~= true then return nil end
    return { object = value, path = tostring(path or "$content"), name = tostring(objectName or ""), objectType = tostring(objectType or "") }
end

function B:GetSnapshot()
    local out = Copy(self.snapshot) or {}
    out.generation = tonumber(self.generation) or 0
    out.fallbackCount = tonumber(self.fallbackCount) or 0
    out.candidatePath = self.candidatePath
    out.candidateName = self.candidateName
    out.candidateType = self.candidateType
    return out
end

-- 中文维护注释（2026-09-14，Native 搜索框候选生命周期）：原生 Auction widget 引用只允许在
-- 当前拍卖窗口 generation 内缓存，窗口关闭/新一轮打开立即释放。它不是业务 Authority，也绝不写入
-- Persistence。这样 RU 客户端重建原生窗口后不会继续持有上一代 userdata/table 造成悬空引用。
function B:ResetNativeCandidate(reason)
    self.candidate, self.candidatePath, self.candidateName, self.candidateType = nil, nil, nil, nil
    self.probedGeneration = nil
    self.snapshot.candidateStatus = "none"
    self.snapshot.reason = reason ~= nil and tostring(reason) or nil
    return true
end

function B:_ReadAuctionContent()
    local addon, contentId = rawget(_G, "ADDON"), rawget(_G, "UIC_AUCTION")
    if addon == nil or contentId == nil then return nil, "ADDON/UIC_AUCTION 不可用" end
    if S.Api == nil or type(S.Api.IsCapabilityAllowed) ~= "function" or S.Api:IsCapabilityAllowed("ADDON:GetContent") ~= true then
        return nil, "ADDON:GetContent 未获能力许可"
    end
    if type(addon.GetContent) ~= "function" then return nil, "ADDON:GetContent 不可用" end
    local ok, content, err = S.Api:CallCapability("ADDON:GetContent", addon, "GetContent", contentId)
    if ok ~= true or content == nil then return nil, tostring(err or "拍卖内容对象不可用") end
    return content
end

function B:_ProbeNativeCandidate()
    if self.probedGeneration == self.generation then
        return self.candidate, self.candidate ~= nil and nil or self.snapshot.reason
    end
    self.probedGeneration = self.generation
    self.candidate, self.candidatePath, self.candidateName, self.candidateType = nil, nil, nil, nil
    local root, rootErr = self:_ReadAuctionContent()
    if root == nil then
        self.snapshot.candidateStatus = "unavailable"; self.snapshot.reason = rootErr
        return nil, rootErr
    end

    -- 中文维护注释（2026-09-14，bounded native probe）：RU API 没有已验证的通用 child-enumeration
    -- 方法，因此禁止猜 GetChildren/GetChild。这里只检查 ADDON:GetContent 返回的 Lua content table 及其
    -- 最多 3 层 table 字段；userdata 无法安全枚举就直接降级。最多 128 节点，且只接受同时具备
    -- EditBox 类型 + GetText/SetText + search/keyword 语义证据的候选，防止误写拍卖数量/价格输入框。
    local queue, head = { { value = root, path = "$content", depth = 0 } }, 1
    local seen, checked = {}, 0
    while head <= #queue and checked < self.maxProbeNodes do
        local entry = queue[head]; head = head + 1
        local value = entry.value
        if value ~= nil and not seen[value] then
            seen[value] = true; checked = checked + 1
            local facts = CandidateFacts(value, entry.path)
            if facts ~= nil then
                self.candidate = facts.object; self.candidatePath = facts.path; self.candidateName = facts.name; self.candidateType = facts.objectType
                self.snapshot.candidateStatus = "verified"; self.snapshot.reason = nil
                return self.candidate
            end
            if type(value) == "table" and entry.depth < self.maxProbeDepth then
                local keys = {}
                for key, child in pairs(value) do if type(child) == "table" or type(child) == "userdata" then keys[#keys + 1] = key end end
                table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
                for _, key in ipairs(keys) do
                    queue[#queue + 1] = { value = value[key], path = entry.path .. "." .. tostring(key), depth = entry.depth + 1 }
                end
            end
        end
    end
    local reason = "未找到具备 EditBox+search/keyword+读回能力的拍卖搜索框"
    self.snapshot.candidateStatus = "none"; self.snapshot.reason = reason
    return nil, reason
end

function B:SyncNativeKeyword(keyword)
    keyword = Trim(keyword)
    if keyword == "" then return false, "关键词为空" end
    local candidate, probeErr = self:_ProbeNativeCandidate()
    if candidate == nil then
        self.fallbackCount = (tonumber(self.fallbackCount) or 0) + 1
        self.snapshot.nativeSync = "fallback"; self.snapshot.fallbackCount = self.fallbackCount; self.snapshot.reason = probeErr
        return false, probeErr
    end
    local wrote = pcall(function() candidate:SetText(keyword) end)
    local readOk, readback = SafeCall(candidate, "GetText")
    if wrote == true and readOk == true and tostring(readback or "") == keyword then
        self.snapshot.nativeSync = "success"; self.snapshot.reason = nil; self.snapshot.keyword = keyword
        self.snapshot.candidateStatus = "verified"; self.snapshot.fallbackCount = self.fallbackCount
        return true
    end
    self.fallbackCount = (tonumber(self.fallbackCount) or 0) + 1
    self.snapshot.nativeSync = "fallback"; self.snapshot.candidateStatus = "rejected"; self.snapshot.fallbackCount = self.fallbackCount
    self.snapshot.reason = wrote ~= true and "原生搜索框写入异常" or (readOk ~= true and "原生搜索框无法读回" or "原生搜索框读回不一致")
    -- Reject this candidate for the current generation. A new auction window is
    -- required before probing again; this avoids repeatedly mutating a wrong UI.
    self.candidate = nil
    return false, self.snapshot.reason
end

function B:Search(requester, keyword, options)
    requester, keyword = tostring(requester or ""), Trim(keyword)
    options = type(options) == "table" and options or {}
    if requester == "" then return false, "查询来源不能为空" end
    if keyword == "" or #keyword > 64 or keyword:find("[%c]") ~= nil then return false, "搜索关键词必须是 1-64 个可见字符" end
    if type(Query) ~= "table" or type(Query.Search) ~= "function" then return false, "AuctionQueryV3 不可用" end
    -- Server query remains the Authority. Only after it accepts the request do
    -- we touch the optional native EditBox, so SingleFlight rejection cannot
    -- leave the native field displaying a keyword that was never queried.
    local ok, result = Query:Search(requester, keyword, options)
    if ok ~= true then return false, result end
    self.snapshot.keyword = keyword
    self:SyncNativeKeyword(keyword)
    return true, result
end

function B:_OnSurface(snapshot)
    snapshot = type(snapshot) == "table" and snapshot or {}
    local visible = snapshot.status == "ready" and snapshot.visible == true
    if visible and self.auctionVisible ~= true then
        self.generation = (tonumber(self.generation) or 0) + 1
        self:ResetNativeCandidate("auction_generation_open")
    elseif visible ~= true and self.auctionVisible == true then
        self:ResetNativeCandidate("auction_closed")
    end
    self.auctionVisible = visible
    self.snapshot.generation = self.generation
    return true
end

if type(S.Events) == "table" and type(S.Events.SubscribeInternal) == "function" and type(Surface) == "table" then
    S.Events:SubscribeInternal(Surface.topic or "v3.auction_surface.updated", B, function(_, snapshot) return B:_OnSurface(snapshot) end)
end
if type(Surface) == "table" and type(Surface.GetSnapshot) == "function" then B:_OnSurface(Surface:GetSnapshot()) end
