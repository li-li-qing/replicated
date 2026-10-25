-- Replicated Suite · 拍卖搜索桥
-- 作者：Replicated
-- QQ群：1104129461
-- 请求接受后可同步原生搜索框；这只是可选显示，找不到可验证 EditBox 时仍允许查询。
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
    -- RU userdata 的 __index 也可能抛错，取方法和调用都须置于 pcall；不透明对象按不可验证候选跳过。
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

-- 原生窗口引用仅缓存当前拍卖窗口代际，关闭或重开即释放，避免使用重建前的悬空 userdata。
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

    -- 没有已验证的通用子节点枚举 API。仅查 ADDON:GetContent 的 Lua table，最多 3 层、128 节点；不枚举 userdata。
    -- 候选须同时具备 EditBox 类型、GetText/SetText 和 search/keyword 语义，防止误写数量或价格框。
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
    -- 当前代际拒绝此候选，需新拍卖窗口才重新探测，避免反复修改错误 UI。
    self.candidate = nil
    return false, self.snapshot.reason
end

function B:Search(requester, keyword, options)
    requester, keyword = tostring(requester or ""), Trim(keyword)
    options = type(options) == "table" and options or {}
    if requester == "" then return false, "查询来源不能为空" end
    if keyword == "" or #keyword > 64 or keyword:find("[%c]") ~= nil then return false, "搜索关键词必须是 1-64 个可见字符" end
    if type(Query) ~= "table" or type(Query.Search) ~= "function" then return false, "AuctionQueryV3 不可用" end
    -- 服务器查询仍是权威；接受请求后才修改可选原生 EditBox，避免 SingleFlight 拒绝时显示从未查询的关键字。
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
