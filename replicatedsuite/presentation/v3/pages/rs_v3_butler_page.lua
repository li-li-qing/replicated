------------------------------------------------------------------------
-- Replicated Suite V3 - Butler Read-only Page
------------------------------------------------------------------------
-- 维护（module-controls-diag-2）：总开关领取PageHost左上角的同一实例；原Feature/Consumer/保存回滚回调不变。
-- 只调整呈现归属，禁止在刷新中另造开关状态、重设Native父级或绑定第二个OnClick；局部选项开关保持原位。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI, D = S.RSUI, S.UIV3Design
local PageHost = S.UIV3 and S.UIV3.PageHost or nil
local Feature = S.Features and S.Features.Butler or nil
if type(RSUI) ~= "table" or type(D) ~= "table" or type(PageHost) ~= "table" or type(Feature) ~= "table" then return end

local function FormatChargeInfo(tbl)
    if type(tbl) ~= "table" then return tostring(tbl or "") end
    local parts = {}
    local keyLabels = {
        charge = "充能点数",
        maxCharge = "充能上限",
        remainTime = "剩余时间",
        remainPoint = "剩余点数",
        chargeType = "充能类型",
        chargeState = "充能状态",
        isCharged = "已充能",
        cost = "消耗",
    }
    for k, v in pairs(tbl) do
        local label = keyLabels[k] or tostring(k)
        if type(v) == "table" then
            local sub = {}
            for sk, sv in pairs(v) do
                if #sub < 3 then sub[#sub + 1] = tostring(sk) .. "=" .. tostring(sv) end
            end
            parts[#parts + 1] = label .. "={" .. table.concat(sub, ", ") .. "}"
        else
            parts[#parts + 1] = label .. ": " .. tostring(v)
        end
        if #parts >= 6 then
            parts[#parts + 1] = "..."
            break
        end
    end
    if #parts == 0 then return "空数据表" end
    return table.concat(parts, " | ")
end

local function ValueText(value)
    if value == nil then return "未读取（未召唤管家或未进入管家上下文）" end
    if type(value) == "table" then
        return FormatChargeInfo(value)
    end
    local text = tostring(value)
    return text == "" and "未读取" or text
end

local function BuildPage(parent, route)
    local root, err = D:PageRoot(parent, "v3_page_butler")
    if root == nil then return nil, err end
    root.consumerHeld = false
    local consumerBinding = { feature = Feature, featureId = "life_butler", token = "page:butler", refresh = function(page) return page:Refresh() end }
    D:PageHeader(root, "v3_butler_header", "管家充能", "当前仅展示官方开放的只读充能信息；不会调用管家装备、交互或其它未授权动作。", "刷新", function()
        local ok, refreshErr = Feature.Commands:Refresh("butler_page_manual")
        if ok == true then root:Refresh() end
        return ok, refreshErr
    end)
    local toggleRow = RSUI:HorizontalBox({ id = "v3_butler_lifecycle", parent = root, gap = 6, slot = { size = "fixed", height = 30, hAlign = "fill" } })
    local toggle = D:ModuleToggleButton({ id = "v3_butler_toggle", parent = toggleRow, text = "启用功能", compact = true, slot = { size = "fixed", width = 92 } })
    RSUI:Text({ id = "v3_butler_lifecycle_hint", parent = toggleRow, text = "页面不会自动启用功能；只有显式启用后才读取原生 API。", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fill", fill = 1 } })
    local card = D:InfoCard(root, { id = "v3_butler_card", title = "充能信息", value = "等待读取", detail = "进入管家上下文后刷新。", detailMaxLines = 6, slot = { size = "fill", fill = 1, hAlign = "fill" } })
    local status = RSUI:Text({ id = "v3_butler_status", parent = root, text = "", fontSize = 9, tone = "muted", overflow = "wrap", slot = { size = "auto", minHeight = 30, hAlign = "fill" } })
    function root:Refresh()
        local enabled = S.FeatureRuntime:IsEnabled("life_butler") == true
        toggle:SetText(enabled and "关闭功能" or "启用功能")
        if not enabled then
            card:SetData({ value = "功能已关闭", detail = "显式启用后才会建立 Consumer 并读取管家 API。" })
            status:SetText("功能已关闭；打开页面不会改变用户启用偏好。")
            return true
        end
        local projection = Feature:GetProjection() or {}
        if not projection.available then
            card:SetData({ value = "当前不可用", detail = "未检测到管家充能数据。\n\n提示：请召唤管家或靠近管家后再点击刷新；当前客户端仅开放只读充能查询接口，插件绝不执行未授权的管家动作。" })
            status:SetText("当前客户端/上下文未返回管家充能信息；页面保持只读降级。")
        else
            card:SetData({ value = "已读取", detail = "充能状态：" .. ValueText(projection.charge) .. "\n数据源：官方只读 getter (X2Butler:GetChargeInfo)\nRevision：" .. tostring(projection.revision or 0) })
            status:SetText("管家只读信息已返回；其它能力保持关闭。")
        end
        return true
    end
    toggle.onClick = function()
        local target = S.FeatureRuntime:IsEnabled("life_butler") ~= true
        local changed, changeErr = S.FeatureRuntime:SetPreferredEnabled("life_butler", target, "butler_page_toggle")
        if changed ~= true then return false, changeErr end
        local synced, syncErr = PageHost:SyncFeatureConsumer(root, consumerBinding, "butler_page_toggle")
        if synced ~= true and target == true then
            local rolledBack, rollbackErr = S.FeatureRuntime:SetPreferredEnabled("life_butler", false, "butler_page_acquire_rollback")
            root.consumerHeld = false; root:Refresh()
            if rolledBack ~= true then return false, tostring(syncErr or "Consumer 启动失败") .. "；回滚失败：" .. tostring(rollbackErr or "unknown") end
            return false, syncErr
        end
        return root:Refresh()
    end
    function root:BindUpdates()
        if S.Events == nil or type(S.Events.SubscribeInternal) ~= "function" then return false, "内部事件总线不可用" end
        if type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        if S.Events:SubscribeInternal("v3.butler.updated", self, function() if root.Refresh then root:Refresh() end end) ~= true then return false, "页面更新事件订阅失败" end
        local ok, err = PageHost:BindFeatureConsumerLifecycle(self, consumerBinding)
        if ok ~= true then S.Events:UnsubscribeInternalOwner(self); return false, err end
        return true
    end
    function root:OnActivated()
        local bound, bindErr = self:BindUpdates(); if bound ~= true then return false, bindErr end
        return PageHost:SyncFeatureConsumer(self, consumerBinding, "page_activated")
    end
    function root:OnDeactivated()
        if S.Events and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        return PageHost:ReleaseFeatureConsumer(self, consumerBinding, "page_deactivated")
    end
    root.route = route
    return root
end

local ok, err = PageHost:RegisterFactory("life.butler", BuildPage)
if ok ~= true then error(err) end
