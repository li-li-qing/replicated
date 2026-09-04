------------------------------------------------------------------------
-- Replicated Suite V3 - Butler Read-only Page
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI, D = S.RSUI, S.UIV3Design
local PageHost = S.UIV3 and S.UIV3.PageHost or nil
local Feature = S.Features and S.Features.Butler or nil
if type(RSUI) ~= "table" or type(D) ~= "table" or type(PageHost) ~= "table" or type(Feature) ~= "table" then return end

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
    local root, err = D:PageRoot(parent, "v3_page_butler")
    if root == nil then return nil, err end
    root.consumerHeld = false
    D:PageHeader(root, "v3_butler_header", "管家充能", "当前仅展示官方开放的只读充能信息；不会调用管家装备、交互或其它未授权动作。", "刷新", function()
        local ok, refreshErr = Feature.Commands:Refresh("butler_page_manual")
        if ok == true then root:Refresh() end
        return ok, refreshErr
    end)
    local toggleRow = RSUI:HorizontalBox({ id = "v3_butler_lifecycle", parent = root, gap = 6, slot = { size = "fixed", height = 30, hAlign = "fill" } })
    local toggle = RSUI:Button({ id = "v3_butler_toggle", parent = toggleRow, text = "启用功能", compact = true, slot = { size = "fixed", width = 92 } })
    RSUI:Text({ id = "v3_butler_lifecycle_hint", parent = toggleRow, text = "页面不会自动启用功能；只有显式启用后才读取原生 API。", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fill", fill = 1 } })
    local card = D:InfoCard(root, { id = "v3_butler_card", title = "充能信息", value = "等待读取", detail = "进入管家上下文后刷新。", detailMaxLines = 4, slot = { size = "fill", fill = 1, hAlign = "fill" } })
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
        card:SetData({ value = projection.available and "已读取" or "当前不可用", detail = "充能：" .. ValueText(projection.charge) .. "\n数据源：官方只读 getter\nRevision：" .. tostring(projection.revision or 0) })
        status:SetText(projection.available and "管家只读信息已返回；其它能力保持关闭。" or "当前客户端/上下文未返回管家充能信息；页面保持只读降级。")
        return true
    end
    toggle.onClick = function()
        local target = S.FeatureRuntime:IsEnabled("life_butler") ~= true
        local changed, changeErr = S.FeatureRuntime:SetPreferredEnabled("life_butler", target, "butler_page_toggle")
        if changed ~= true then return false, changeErr end
        if target then
            local acquired, acquireErr = Feature:AcquireConsumer("page:butler")
            if acquired ~= true then
                local rolledBack, rollbackErr = S.FeatureRuntime:SetPreferredEnabled("life_butler", false, "butler_page_acquire_rollback")
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
        if S.FeatureRuntime:IsEnabled("life_butler") ~= true then self.consumerHeld = false; return self:Refresh() end
        local acquired, acquireErr = Feature:AcquireConsumer("page:butler")
        if acquired ~= true then return false, acquireErr end
        self.consumerHeld = true
        return self:Refresh()
    end
    function root:OnDeactivated()
        if self.consumerHeld then Feature:ReleaseConsumer("page:butler"); self.consumerHeld = false end
        return true
    end
    root.route = route
    return root
end

local ok, err = PageHost:RegisterFactory("life.butler", BuildPage)
if ok ~= true then error(err) end
