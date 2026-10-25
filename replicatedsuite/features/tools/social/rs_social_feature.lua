-- Replicated Suite · 社交名单功能入口
-- 作者：Replicated
-- QQ群：1104129461
-- 名单读取与投影独立于其它 Feature；通用装配由 FeatureSliceFactory 提供。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local FSF = S.FeatureSliceFactory
if type(FSF) ~= "table" then error("FeatureSliceFactory unavailable for tools_social") end
local Call, Action, NewFeature = FSF.Call, FSF.Action, FSF.NewFeature
-- X2Friend 只作为能力宿主候选传入；真正的导入 Authority 仍是 FeatureRuntime →
-- S.ApiImports（ApiDependencies 声明 8 个 X2Friend method），本文件不自己 ImportAPI。
local FriendApi = rawget(_G, "X2Friend")

-- RU 名单形状尚待实机核实；兼容表数组、名称数组和名称键表。无可用名的条目标未识别并降级 partial，不能渲染表地址。
-- 按 SOCIAL_LIST_MAX_ROWS 截断；失败不能冒充空表。签名以导出为准：GetFriendList(allMember)、GetBlockList()、GetMuteList()。
local SOCIAL_LIST_MAX_ROWS = 200
local SOCIAL_LIST_SCAN_LIMIT = 1000
local SOCIAL_LISTS = {
    { key = "好友", capability = "X2Friend:GetFriendList", method = "GetFriendList", allMember = true },
    { key = "屏蔽", capability = "X2Friend:GetBlockList", method = "GetBlockList", toneUnknown = "warn" },
    { key = "静音", capability = "X2Friend:GetMuteList", method = "GetMuteList", toneUnknown = "orange" },
}
local function SocialMemberName(value)
    if type(value) == "string" then
        local name = value:match("^%s*(.-)%s*$")
        return name ~= "" and name or nil
    end
    if type(value) ~= "table" then return nil end
    for _, field in ipairs({ "name", "characterName", "memberName", "charName" }) do
        local candidate = value[field]
        if type(candidate) == "string" then
            local name = candidate:match("^%s*(.-)%s*$")
            if name ~= "" then return name end
        end
    end
    return nil
end
local function SocialListEntries(list)
    -- 先处理数组部分，遵循ipairs语义；仅纯名称键表回退排序字符串key。Native count等标量哈希字段为元数据，两种形态都跳过。
    local arrayCount = 0
    for index = 1, SOCIAL_LIST_SCAN_LIMIT do
        if list[index] == nil then break end
        arrayCount = index
    end
    if arrayCount > 0 then
        local entries = {}
        for index = 1, arrayCount do entries[index] = { value = list[index], key = nil } end
        return entries
    end
    local keys = {}
    for key, value in pairs(list) do
        if type(key) == "string" and (type(value) == "table" or type(value) == "string") then keys[#keys + 1] = key end
    end
    table.sort(keys)
    local entries = {}
    for index, key in ipairs(keys) do entries[index] = { value = list[key], key = key } end
    return entries
end
local function AppendSocialList(rows, spec, list)
    local stats = { recognized = 0, unrecognized = 0, truncated = false }
    if type(list) ~= "table" then return stats end
    local entries = SocialListEntries(list)
    stats.truncated = #entries > SOCIAL_LIST_MAX_ROWS
    for index = 1, math.min(#entries, SOCIAL_LIST_MAX_ROWS) do
        local entry = entries[index]
        local name = SocialMemberName(entry.value)
        if name == nil then
            stats.unrecognized = stats.unrecognized + 1
            rows[#rows + 1] = { key = "social:" .. spec.key .. ":" .. index, memberName = nil, listKind = spec.key,
                name = "未识别条目 " .. tostring(entry.key or index), text = "返回形态未识别；待 RU 实证后修正",
                statusText = spec.key, tone = "muted" }
        else
            stats.recognized = stats.recognized + 1
            local online, level
            if type(entry.value) == "table" then
                for _, field in ipairs({ "online", "isOnline", "loggedIn" }) do
                    local flag = entry.value[field]
                    if type(flag) == "boolean" then online = flag; break end
                end
                for _, field in ipairs({ "level", "growLevel" }) do
                    local n = tonumber(entry.value[field])
                    if n ~= nil then level = math.floor(n); break end
                end
            end
            local fact = online == nil and "在线状态未知" or (online and "在线" or "离线")
            if level ~= nil then fact = fact .. " · 等级 " .. tostring(level) end
            -- 社交名单只读独立备注的标量，不建立第二份备注 Store，也不因展示备注额外读取 Native 名单。
            local notes = S.Features and S.Features.PlayerNotes
            local note = notes and notes:GetNote(name) or ""
            if note ~= "" then fact = fact .. " · 备注：" .. note end
            local tone = spec.toneUnknown or "default"
            if spec.key == "好友" then tone = (online == true and "green") or (online == false and "muted") or "default" end
            rows[#rows + 1] = { key = "social:" .. spec.key .. ":" .. index, memberName = name, listKind = spec.key,
                name = name, text = fact, statusText = spec.key, tone = tone }
        end
    end
    return stats
end
local function SocialRosterAction(capability, method, name)
    local member = SocialMemberName(name)
    if member == nil then return false, "角色名不能为空" end
    return Action(capability, FriendApi, method, member)
end

NewFeature("tools_social", { apiDependencies = { "X2Friend:IsMyFriend", "X2Friend:GetFriendList", "X2Friend:GetBlockList", "X2Friend:GetMuteList", "X2Friend:BlockUser", "X2Friend:UnblockUser", "X2Friend:MuteUser", "X2Friend:UnmuteUser" }, read = function()
    local rows, failed, anyOk = {}, {}, false
    local unrecognized, truncated = 0, false
    for _, spec in ipairs(SOCIAL_LISTS) do
        local ok, list, callErr
        if spec.allMember == true then
            ok, list, callErr = Call(spec.capability, FriendApi, spec.method, true)
        else
            -- GetBlockList()/GetMuteList()按客户端导出清单无参数；禁止传nil改变Native参数个数。
            ok, list, callErr = Call(spec.capability, FriendApi, spec.method)
        end
        if ok ~= true then
            failed[#failed + 1] = spec.key .. "（" .. tostring(callErr or "读取失败") .. "）"
        else
            anyOk = true
            local stats = AppendSocialList(rows, spec, list)
            unrecognized = unrecognized + stats.unrecognized
            truncated = truncated or stats.truncated
        end
    end
    local status = "ready"
    if not anyOk then status = "unavailable"
    elseif #failed > 0 or unrecognized > 0 then status = "partial"
    elseif #rows == 0 then status = "empty" end
    local notes = {}
    if #failed > 0 then notes[#notes + 1] = "读取失败：" .. table.concat(failed, "；") end
    if unrecognized > 0 then notes[#notes + 1] = "返回形态未识别 " .. tostring(unrecognized) .. " 条（RU 契约待实证）" end
    if truncated then notes[#notes + 1] = "单名单超过 " .. tostring(SOCIAL_LIST_MAX_ROWS) .. " 条已截断显示" end
    return rows, status, (#notes > 0 and table.concat(notes, "；") or nil)
end, commands = {
    Block = function(_, name) return SocialRosterAction("X2Friend:BlockUser", "BlockUser", name) end,
    Unblock = function(_, name) return SocialRosterAction("X2Friend:UnblockUser", "UnblockUser", name) end,
    Mute = function(_, name) return SocialRosterAction("X2Friend:MuteUser", "MuteUser", name) end,
    Unmute = function(_, name) return SocialRosterAction("X2Friend:UnmuteUser", "UnmuteUser", name) end,
    IsFriend = function(_, name)
        local member = SocialMemberName(name)
        if member == nil then return false, "角色名不能为空" end
        local ok, result, callErr = Call("X2Friend:IsMyFriend", FriendApi, "IsMyFriend", member)
        if ok ~= true then return false, tostring(callErr or "查询失败") end
        if result == true then return true, "是好友" end
        if result == false then return true, "非好友" end
        return true, "好友状态未知（返回形态待 RU 实证）"
    end,
} })
