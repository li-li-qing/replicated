------------------------------------------------------------------------
-- Replicated Suite V3 - Random Shop Read-only Page
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI, D = S.RSUI, S.UIV3Design
local PageHost = S.UIV3 and S.UIV3.PageHost or nil
local Feature = S.Features and S.Features.RandomShop or nil
if type(RSUI) ~= "table" or type(D) ~= "table" or type(PageHost) ~= "table" or type(Feature) ~= "table" then return end

local ROUTE = "tools.random_shop"

local function BuildPage(parent, route)
    local root, err = D:PageRoot(parent, "v3_page_random_shop")
    if root == nil then return nil, err end
    root.consumerHeld = false
    D:PageHeader(root, "v3_random_shop_header", "随机商店计数", "当前 RU API 只开放刷新次数；页面不猜测商店开启状态、物品列表或刷新动作。", "刷新", function()
        local ok, refreshErr = Feature.Commands:Refresh("random_shop_page_manual")
        if ok == true then root:Refresh() end
        return ok, refreshErr
    end)
    local toggleRow = RSUI:HorizontalBox({ id = "v3_random_shop_lifecycle", parent = root, gap = 6, slot = { size = "fixed", height = 30, hAlign = "fill" } })
    local toggle = RSUI:Button({ id = "v3_random_shop_toggle", parent = toggleRow, text = "启用功能", compact = true, slot = { size = "fixed", width = 92 } })
    RSUI:Text({ id = "v3_random_shop_lifecycle_hint", parent = toggleRow, text = "页面不会自动启用功能；只有显式启用后才读取原生 API。", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fill", fill = 1 } })
    local card = D:InfoCard(root, { id = "v3_random_shop_card", title = "刷新次数", value = "等待读取", detail = "进入可读取的随机商店上下文后刷新。", detailMaxLines = 4, slot = { size = "fill", fill = 1, hAlign = "fill" } })
    local status = RSUI:Text({ id = "v3_random_shop_status", parent = root, text = "", fontSize = 9, tone = "muted", overflow = "wrap", slot = { size = "auto", minHeight = 30, hAlign = "fill" } })
    function root:Refresh()
        local enabled = S.FeatureRuntime:IsEnabled("tools_random_shop") == true
        toggle:SetText(enabled and "关闭功能" or "启用功能")
        if not enabled then
            card:SetData({ value = "功能已关闭", detail = "显式启用后才会建立 Consumer 并读取随机商店 API。" })
            status:SetText("功能已关闭；打开页面不会改变用户启用偏好。")
            return true
        end
        local projection = Feature:GetProjection() or {}
        if projection.available == true then
            card:SetData({ value = tostring(projection.refreshCount or 0), detail = "数据源：官方只读 getter\nRevision：" .. tostring(projection.revision or 0) })
            status:SetText("刷新次数已读取；其它随机商店字段未被当前 API 证明，因此不在页面中推断。")
        else
            card:SetData({ value = "当前不可用", detail = "未取得官方刷新次数。" })
            status:SetText("当前客户端/上下文没有返回随机商店刷新次数；页面保持只读降级，不执行未知 API。")
        end
        return true
    end
    toggle.onClick = function()
        local target = S.FeatureRuntime:IsEnabled("tools_random_shop") ~= true
        local changed, changeErr = S.FeatureRuntime:SetPreferredEnabled("tools_random_shop", target, "random_shop_page_toggle")
        if changed ~= true then return false, changeErr end
        if target then
            local acquired, acquireErr = Feature:AcquireConsumer("page:random_shop")
            if acquired ~= true then
                local rolledBack, rollbackErr = S.FeatureRuntime:SetPreferredEnabled("tools_random_shop", false, "random_shop_page_acquire_rollback")
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
    if toggle.root ~= nil then S.UI:SafeHandler(toggle.root, "OnClick", toggle.onClick, "v3_random_shop:toggle") end
    function root:OnActivated()
        if S.FeatureRuntime:IsEnabled("tools_random_shop") ~= true then self.consumerHeld = false; return self:Refresh() end
        local acquired, acquireErr = Feature:AcquireConsumer("page:random_shop")
        if acquired ~= true then return false, acquireErr end
        self.consumerHeld = true
        return self:Refresh()
    end
    function root:OnDeactivated()
        if self.consumerHeld then Feature:ReleaseConsumer("page:random_shop"); self.consumerHeld = false end
        return true
    end
    root.route = route
    return root
end

local ok, err = PageHost:RegisterFactory(ROUTE, BuildPage)
if ok ~= true then error(err) end
