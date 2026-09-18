------------------------------------------------------------------------
-- Replicated Suite V3 - Housing Read-only Page
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI, D = S.RSUI, S.UIV3Design
local PageHost = S.UIV3 and S.UIV3.PageHost or nil
local Feature = S.Features and S.Features.Housing or nil
if type(RSUI) ~= "table" or type(D) ~= "table" or type(PageHost) ~= "table" or type(Feature) ~= "table" then return end

local ROUTE = "life.housing"

local function FormatTaxInfo(tbl)
    if type(tbl) ~= "table" then return tostring(tbl or "") end
    local parts = {}
    local keyLabels = {
        totalTax = "总税额",
        basicTax = "基础税",
        tax = "税金",
        deposit = "保证金",
        prepayment = "预缴税",
        prepayTax = "预缴税",
        isPrepay = "可否预缴",
        penalty = "滞纳金",
        warmPeriod = "宽限期",
        remainTime = "剩余时间",
        dueDate = "缴税截止",
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
    if value == nil then return "未读取（不在住宅旁）" end
    if type(value) == "table" then
        return FormatTaxInfo(value)
    end
    local text = tostring(value)
    return text == "" and "未读取" or text
end

local function BuildPage(parent, route)
    local root, err = D:PageRoot(parent, "v3_page_housing")
    if root == nil then return nil, err end
    root.consumerHeld = false
    D:PageHeader(root, "v3_housing_header", "住宅 / 税务", "仅在当前住宅上下文按需读取名称、类型、所有者与税务信息；不会执行住宅写操作。", "刷新", function()
        local refreshed, refreshErr = Feature.Commands:Refresh("housing_page_manual")
        if refreshed == true then root:Refresh() end
        return refreshed, refreshErr
    end)
    local toggleRow = RSUI:HorizontalBox({ id = "v3_housing_lifecycle", parent = root, gap = 6, slot = { size = "fixed", height = 30, hAlign = "fill" } })
    local toggle = RSUI:Button({ id = "v3_housing_toggle", parent = toggleRow, text = "启用功能", compact = true, slot = { size = "fixed", width = 92 } })
    RSUI:Text({ id = "v3_housing_lifecycle_hint", parent = toggleRow, text = "页面不会自动启用功能；只有显式启用后才读取原生 API。", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fill", fill = 1 } })
    local card = D:InfoCard(root, { id = "v3_housing_card", title = "住宅信息", value = "等待读取", detail = "进入住宅上下文后点击刷新。", detailMaxLines = 8, slot = { size = "fill", fill = 1, hAlign = "fill" } })
    local status = RSUI:Text({ id = "v3_housing_status", parent = root, text = "", fontSize = 9, tone = "muted", overflow = "wrap", slot = { size = "auto", minHeight = 30, hAlign = "fill" } })
    function root:Refresh()
        local enabled = S.FeatureRuntime:IsEnabled("life_housing") == true
        toggle:SetText(enabled and "关闭功能" or "启用功能")
        if not enabled then
            card:SetData({ value = "功能已关闭", detail = "显式启用后才会建立 Consumer 并读取住宅 API。" })
            status:SetText("功能已关闭；打开页面不会改变用户启用偏好。")
            return true
        end
        local projection = Feature:GetProjection() or {}
        local values = projection.values or {}
        local ok = projection.status == "ready"
        if projection.status == "unavailable" then
            card:SetData({ value = "当前不可用", detail = "请靠近您的住宅或地皮管理标牌后再点击刷新。\n\n当前状态：未检测到住宅上下文事实（4 项只读接口均未返回数据）。" })
            status:SetText("提示：X2House 只读接口仅在玩家靠近建筑物时由客户端返回数据。插件绝不自动轮询或执行任何写操作。")
        else
            card:SetData({ value = ok and "已读取" or "部分可用", detail = "建筑名称：" .. ValueText(values.name) .. "\n建筑类型：" .. ValueText(values.type) .. "\n建筑所有者：" .. ValueText(values.owner) .. "\n当前税务：" .. ValueText(values.tax) })
            status:SetText(ok and "X2House 只读数据已就绪；仅作信息展示，禁止自动缴税。" or "住宅只读数据部分可用；仅展示已确认字段。")
        end
        return true
    end
    toggle.onClick = function()
        local target = S.FeatureRuntime:IsEnabled("life_housing") ~= true
        local changed, changeErr = S.FeatureRuntime:SetPreferredEnabled("life_housing", target, "housing_page_toggle")
        if changed ~= true then return false, changeErr end
        if target then
            local acquired, acquireErr = Feature:AcquireConsumer("page:housing")
            if acquired ~= true then
                local rolledBack, rollbackErr = S.FeatureRuntime:SetPreferredEnabled("life_housing", false, "housing_page_acquire_rollback")
                root.consumerHeld = false
                root:Refresh()
                if rolledBack ~= true then return false, tostring(acquireErr or "Consumer 启动失败") .. "；回滚失败：" .. tostring(rollbackErr or "unknown") end
                return false, acquireErr
            end
            root.consumerHeld = true
        else
            root.consumerHeld = false
        end
        root:Refresh()
        return true
    end
    function root:OnActivated()
        if S.FeatureRuntime:IsEnabled("life_housing") ~= true then self.consumerHeld = false; return self:Refresh() end
        local acquired, acquireErr = Feature:AcquireConsumer("page:housing")
        if acquired ~= true then return false, acquireErr end
        self.consumerHeld = true
        if S.Events and type(S.Events.SubscribeInternal) == "function" and not self.eventSub then
            self.eventSub = S.Events:SubscribeInternal("v3.housing.updated", root, function()
                if root.Refresh then root:Refresh() end
            end)
        end
        return self:Refresh()
    end
    function root:OnDeactivated()
        if self.consumerHeld then Feature:ReleaseConsumer("page:housing"); self.consumerHeld = false end
        if S.Events and type(S.Events.UnsubscribeInternal) == "function" then
            S.Events:UnsubscribeInternal("v3.housing.updated", root)
            self.eventSub = nil
        end
        return true
    end
    root.route = route
    return root
end

local ok, err = PageHost:RegisterFactory(ROUTE, BuildPage)
if ok ~= true then error(err) end
