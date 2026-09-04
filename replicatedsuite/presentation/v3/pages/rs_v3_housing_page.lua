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

local function ValueText(value)
    if value == nil then return "未读取" end
    if type(value) == "table" then
        local count = 0
        for _ in pairs(value) do count = count + 1 end
        return "结构化数据（" .. tostring(count) .. " 个字段；字段映射待 RU 验证）"
    end
    return tostring(value) == "" and "未读取" or tostring(value)
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
    local card = D:InfoCard(root, { id = "v3_housing_card", title = "住宅信息", value = "等待读取", detail = "进入住宅上下文后点击刷新。", detailMaxLines = 6, slot = { size = "fill", fill = 1, hAlign = "fill" } })
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
        card:SetData({ value = ok and "已读取" or (projection.status == "partial" and "部分可用" or "当前不可用"), detail = "名称：" .. ValueText(values.name) .. "\n类型：" .. ValueText(values.type) .. "\n所有者：" .. ValueText(values.owner) .. "\n税务：" .. ValueText(values.tax) })
        status:SetText(ok and "X2House 只读数据已就绪。" or "住宅 getter 当前没有返回完整事实；这通常表示不在住宅上下文，或本 RU 客户端未提供该字段。不会用默认值伪造结果。")
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
        return self:Refresh()
    end
    function root:OnDeactivated()
        if self.consumerHeld then Feature:ReleaseConsumer("page:housing"); self.consumerHeld = false end
        return true
    end
    root.route = route
    return root
end

local ok, err = PageHost:RegisterFactory(ROUTE, BuildPage)
if ok ~= true then error(err) end
