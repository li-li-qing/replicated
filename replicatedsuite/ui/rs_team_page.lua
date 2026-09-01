------------------------------------------------------------------------
-- Replicated Suite - Team Utility Page
-- Auto role / Damage Review / Sacrifice Dance / native marker scale
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.TeamPage = {}

local function Service()
    return S.Services and S.Services.TeamUtility or nil
end

local function ReviewService()
    return S.Services and S.Services.DamageReview or nil
end

local function ModuleState()
    return S.ModuleManager and S.ModuleManager:Describe("team_utility") or nil
end

local function BoolText(v)
    return v == true and "开" or "关"
end

local function SafeEnable(widget, enabled)
    if widget and widget.Enable then widget:Enable(enabled == true) end
end

local function NextValue(current, values)
    current = tonumber(current) or tonumber(values[1]) or 0
    for index, value in ipairs(values) do
        local numeric = tonumber(value) or 0
        if current < numeric then return value end
        if current == numeric then return values[(index % #values) + 1] end
    end
    return values[1]
end

function S.TeamPage.Create(parent)
    local page = { key = "team", root = S.UI:CreatePanel(parent, "team_page", 0, 0, 100, 100, "soft") }
    if page.root.rsBorder and page.root.rsBorder.SetVisible then page.root.rsBorder:SetVisible(false) end
    if page.root.rsBackground and page.root.rsBackground.SetVisible then page.root.rsBackground:SetVisible(false) end

    page.title = S.UI:CreateLabel(page.root, "team_title", "团队辅助", 0, 0, 220, 28, 17, nil, ALIGN_LEFT)
    page.note = S.UI:CreateLabel(page.root, "team_note", "团队相关功能集中在这里：自动职责、伤害回顾、牺牲之舞高亮和游戏原生头顶标记缩放。", 0, 0, 700, 22, 9, "muted", ALIGN_LEFT)
    page.moduleState = S.UI:CreateLabel(page.root, "team_module_state", "", 0, 0, 120, 24, 10, "muted", ALIGN_RIGHT)
    page.moduleToggle = S.UI:CreateButton(page.root, "team_module_toggle", "启用团队辅助", 0, 0, 104, 27, 9, false)
    page.retry = S.UI:CreateButton(page.root, "team_retry", "重试初始化", 0, 0, 92, 27, 9, false)

    page.roleCard = S.UI:CreatePanel(page.root, "team_role_card", 0, 0, 100, 100, "card")
    page.roleTitle = S.UI:CreateLabel(page.root, "team_role_title", "自动职责", 0, 0, 180, 22, 13, nil, ALIGN_LEFT)
    page.roleHint = S.UI:CreateLabel(page.root, "team_role_hint", "进队或职业变化时自动切换自己的团队职责；也可以固定为指定职责。", 0, 0, 300, 20, 9, "muted", ALIGN_LEFT)
    page.roleStatus = S.UI:CreateLabel(page.root, "team_role_status", "当前：--", 0, 0, 260, 22, 10, "yellow", ALIGN_LEFT)
    page.roleDetail = S.UI:CreateLabel(page.root, "team_role_detail", "", 0, 0, 300, 20, 8, "muted", ALIGN_LEFT)
    page.roleToggle = S.UI:CreateButton(page.root, "team_role_toggle", "自动职责：关", 0, 0, 110, 27, 9, false)
    page.roleMode = S.UI:CreateButton(page.root, "team_role_mode", "规则：智能", 0, 0, 110, 27, 9, false)
    page.roleApply = S.UI:CreateButton(page.root, "team_role_apply", "立即应用", 0, 0, 86, 27, 9, false)

    -- P0-4: manual team tools on the right of the role card (no new page/section).
    page.raidToolsTitle = S.UI:CreateLabel(page.root, "team_raid_tools_title", "团队工具", 0, 0, 120, 20, 12, nil, ALIGN_LEFT)
    page.raidBuffCheck = S.UI:CreateButton(page.root, "team_raid_buff_check", "Buff / 职业检查", 0, 0, 136, 24, 9, false)
    page.raidSiegeCheck = S.UI:CreateButton(page.root, "team_raid_siege_check", "攻城装备检查", 0, 0, 136, 24, 9, false)

    page.sacCard = S.UI:CreatePanel(page.root, "team_sac_card", 0, 0, 100, 100, "card")
    page.sacTitle = S.UI:CreateLabel(page.root, "team_sac_title", "牺牲之舞高亮", 0, 0, 180, 22, 13, nil, ALIGN_LEFT)
    page.sacHint = S.UI:CreateLabel(page.root, "team_sac_hint", "只扫描有舞蹈天赋的团队成员；施放时显示剩余时间和头顶提示。", 0, 0, 300, 36, 9, "muted", ALIGN_LEFT)
    page.sacStatus = S.UI:CreateLabel(page.root, "team_sac_status", "候选 0 · 正在施放 0", 0, 0, 260, 22, 10, "yellow", ALIGN_LEFT)
    page.sacToggle = S.UI:CreateButton(page.root, "team_sac_toggle", "高亮：关", 0, 0, 100, 27, 9, false)
    page.sacScan = S.UI:CreateButton(page.root, "team_sac_scan", "立即扫描", 0, 0, 86, 27, 9, false)

    page.reviewCard = S.UI:CreatePanel(page.root, "team_review_card", 0, 0, 100, 100, "card")
    page.reviewTitle = S.UI:CreateLabel(page.root, "team_review_title", "伤害回顾", 0, 0, 180, 22, 13, nil, ALIGN_LEFT)
    page.reviewHint = S.UI:CreateLabel(page.root, "team_review_hint", "独立记录自己死亡前的承伤技能与 Debuff；关闭 DPS 后仍可使用。", 0, 0, 300, 32, 9, "muted", ALIGN_LEFT)
    page.reviewStatus = S.UI:CreateLabel(page.root, "team_review_status", "历史 0 · 缓冲 0", 0, 0, 260, 20, 9, "yellow", ALIGN_LEFT)
    page.reviewToggle = S.UI:CreateButton(page.root, "team_review_toggle", "回顾：开", 0, 0, 78, 25, 8, false)
    page.reviewAuto = S.UI:CreateButton(page.root, "team_review_auto", "弹窗：开", 0, 0, 78, 25, 8, false)
    page.reviewHistory = S.UI:CreateButton(page.root, "team_review_history", "查看历史", 0, 0, 78, 25, 8, false)
    page.reviewWindow = S.UI:CreateButton(page.root, "team_review_window", "窗口10秒", 0, 0, 78, 25, 8, false)
    page.reviewCount = S.UI:CreateButton(page.root, "team_review_count", "保留10次", 0, 0, 78, 25, 8, false)
    page.reviewDebuff = S.UI:CreateButton(page.root, "team_review_debuff", "Debuff：开", 0, 0, 78, 25, 8, false)
    page.reviewMin = S.UI:CreateButton(page.root, "team_review_min", "最低伤害：0", 0, 0, 150, 25, 8, false)

    page.markerCard = S.UI:CreatePanel(page.root, "team_marker_card", 0, 0, 100, 100, "card")
    page.markerTitle = S.UI:CreateLabel(page.root, "team_marker_title", "游戏原生头顶标记", 0, 0, 200, 22, 13, nil, ALIGN_LEFT)
    page.markerHint = S.UI:CreateLabel(page.root, "team_marker_hint", "调整游戏自己的团队标记图标大小，不影响插件自绘血条和治疗高亮。", 0, 0, 300, 36, 9, "muted", ALIGN_LEFT)
    page.markerValue = S.UI:CreateLabel(page.root, "team_marker_value", "120%", 0, 0, 80, 28, 15, "yellow", ALIGN_CENTER)
    page.markerMinus = S.UI:CreateButton(page.root, "team_marker_minus", "-", 0, 0, 38, 28, 12, false)
    page.markerPlus = S.UI:CreateButton(page.root, "team_marker_plus", "+", 0, 0, 38, 28, 12, false)
    page.markerReset = S.UI:CreateButton(page.root, "team_marker_reset", "恢复120%", 0, 0, 86, 28, 9, false)

    S.UI:SafeHandler(page.moduleToggle, "OnClick", function()
        if not S.ModuleManager then return end
        local ok, err = S.ModuleManager:SetEnabled("team_utility", not S.ModuleManager:IsEnabled("team_utility"))
        if ok ~= true then S.SafeChat("团队辅助切换失败：" .. tostring(err or "未知原因")) end
        page:Refresh()
    end, "team:module_toggle")
    S.UI:SafeHandler(page.retry, "OnClick", function()
        if S.ModuleManager then
            local ok, err = S.ModuleManager:Retry("team_utility")
            if ok ~= true then S.SafeChat("团队辅助重试失败：" .. tostring(err or "未知原因")) end
        end
        page:Refresh()
    end, "team:retry")
    S.UI:SafeHandler(page.roleToggle, "OnClick", function()
        local svc = Service(); if not svc then return end
        svc:SetAutoRoleEnabled(not (S.State.settings.teamAutoRoleEnabled == true)); page:Refresh()
    end, "team:role_toggle")
    S.UI:SafeHandler(page.roleMode, "OnClick", function()
        local svc = Service(); if not svc then return end
        svc:CycleRoleMode(); page:Refresh()
    end, "team:role_mode")
    S.UI:SafeHandler(page.roleApply, "OnClick", function()
        local svc = Service(); if not svc then return end
        svc:ApplyRole("manual", true); page:Refresh()
    end, "team:role_apply")
    S.UI:SafeHandler(page.raidBuffCheck, "OnClick", function()
        local svc = Service(); if not svc then return end
        local ok, err = svc:RunBuffCheck()
        if ok ~= true and err ~= nil then S.SafeChat("Buff 检查：" .. tostring(err)) end
        page:Refresh()
    end, "team:raid_buff_check")
    S.UI:SafeHandler(page.raidSiegeCheck, "OnClick", function()
        local svc = Service(); if not svc then return end
        local ok, err = svc:RunSiegeCheck()
        if ok ~= true and err ~= nil then S.SafeChat("攻城装备检查：" .. tostring(err)) end
        page:Refresh()
    end, "team:raid_siege_check")
    S.UI:SafeHandler(page.sacToggle, "OnClick", function()
        local svc = Service(); if not svc then return end
        svc:SetSacMarkerEnabled(not (S.State.settings.sacMarkerEnabled == true)); page:Refresh()
    end, "team:sac_toggle")
    S.UI:SafeHandler(page.sacScan, "OnClick", function()
        local svc = Service(); if not svc then return end
        if svc.ScanDancerCandidates then svc:ScanDancerCandidates() end
        if svc.ScanSacBuffs then svc:ScanSacBuffs() end
        page:Refresh()
    end, "team:sac_scan")

    S.UI:SafeHandler(page.reviewToggle, "OnClick", function()
        local review = ReviewService(); if not review then return end
        review:SetEnabled(not (S.State.settings.damageReviewEnabled == true)); page:Refresh()
    end, "team:review_toggle")
    S.UI:SafeHandler(page.reviewAuto, "OnClick", function()
        local review = ReviewService(); if not review then return end
        review:SetSetting("damageReviewAutoShow", not (S.State.settings.damageReviewAutoShow == true)); page:Refresh()
    end, "team:review_auto")
    S.UI:SafeHandler(page.reviewHistory, "OnClick", function()
        local review = ReviewService(); if review and review.ToggleHistory then review:ToggleHistory() end
        page:Refresh()
    end, "team:review_history")
    S.UI:SafeHandler(page.reviewWindow, "OnClick", function()
        local review = ReviewService(); if not review then return end
        review:SetSetting("damageReviewWindowMs", NextValue(S.State.settings.damageReviewWindowMs, { 5000, 8000, 10000, 12000, 15000, 20000 }))
        page:Refresh()
    end, "team:review_window")
    S.UI:SafeHandler(page.reviewCount, "OnClick", function()
        local review = ReviewService(); if not review then return end
        review:SetSetting("damageReviewMaxHistory", NextValue(S.State.settings.damageReviewMaxHistory, { 5, 10, 15, 20, 30 }))
        page:Refresh()
    end, "team:review_count")
    S.UI:SafeHandler(page.reviewDebuff, "OnClick", function()
        local review = ReviewService(); if not review then return end
        review:SetSetting("damageReviewShowDebuffs", not (S.State.settings.damageReviewShowDebuffs == true)); page:Refresh()
    end, "team:review_debuff")
    S.UI:SafeHandler(page.reviewMin, "OnClick", function()
        local review = ReviewService(); if not review then return end
        review:SetSetting("damageReviewMinDamage", NextValue(S.State.settings.damageReviewMinDamage, { 0, 100, 250, 500, 1000, 2500, 5000 }))
        page:Refresh()
    end, "team:review_min")

    S.UI:SafeHandler(page.markerMinus, "OnClick", function()
        local svc = Service(); if svc then svc:AdjustMarkerScale(-0.10); page:Refresh() end
    end, "team:marker_minus")
    S.UI:SafeHandler(page.markerPlus, "OnClick", function()
        local svc = Service(); if svc then svc:AdjustMarkerScale(0.10); page:Refresh() end
    end, "team:marker_plus")
    S.UI:SafeHandler(page.markerReset, "OnClick", function()
        local svc = Service(); if svc then svc:ResetMarkerScale(); page:Refresh() end
    end, "team:marker_reset")

    function page:Refresh()
        local desc = ModuleState()
        local enabled = desc and desc.enabled == true
        if desc == nil then
            self.moduleState:SetText("未注册"); S.Theme:SetLabelTone(self.moduleState, "red")
        elseif desc.state == "Faulted" then
            self.moduleState:SetText("初始化失败"); S.Theme:SetLabelTone(self.moduleState, "red")
        elseif enabled then
            self.moduleState:SetText("运行中"); S.Theme:SetLabelTone(self.moduleState, "green")
        else
            self.moduleState:SetText("已关闭"); S.Theme:SetLabelTone(self.moduleState, "muted")
        end
        self.moduleToggle:SetText(enabled and "关闭团队辅助" or "启用团队辅助")
        self.retry:Show(desc ~= nil and desc.state == "Faulted")

        local svc = Service()
        local review = ReviewService()
        local data = S.State.data.teamUtility or {}
        self.roleToggle:SetText("自动职责：" .. BoolText(S.State.settings.teamAutoRoleEnabled == true))
        self.roleMode:SetText("规则：" .. (svc and svc:GetRoleModeLabel() or "智能"))
        self.roleStatus:SetText("当前职责：" .. tostring(data.roleStatus or "--"))
        self.roleDetail:SetText("识别：" .. tostring(data.classKey or "--") .. " · 来源：" .. tostring(data.roleSource or data.lastRoleReason or "--"))
        self.sacToggle:SetText("高亮：" .. BoolText(S.State.settings.sacMarkerEnabled == true))
        self.sacStatus:SetText(string.format("舞者候选 %d · 正在施放 %d", tonumber(data.sacCandidates) or 0, tonumber(data.sacActive) or 0))

        self.reviewToggle:SetText("回顾：" .. BoolText(S.State.settings.damageReviewEnabled == true))
        self.reviewAuto:SetText("弹窗：" .. BoolText(S.State.settings.damageReviewAutoShow == true))
        self.reviewWindow:SetText("窗口" .. tostring(math.floor((tonumber(S.State.settings.damageReviewWindowMs) or 10000) / 1000 + 0.5)) .. "秒")
        self.reviewCount:SetText("保留" .. tostring(math.floor(tonumber(S.State.settings.damageReviewMaxHistory) or 10)) .. "次")
        self.reviewDebuff:SetText("Debuff：" .. BoolText(S.State.settings.damageReviewShowDebuffs == true))
        self.reviewMin:SetText("最低伤害：" .. tostring(math.floor(tonumber(S.State.settings.damageReviewMinDamage) or 0)))
        if review and review.GetStatusLine then
            self.reviewStatus:SetText(review:GetStatusLine())
        else
            self.reviewStatus:SetText("伤害回顾：未加载")
        end

        if data.markerScaleAvailable == false then self.markerValue:SetText("不可用")
        else self.markerValue:SetText(svc and svc:GetMarkerScaleText() or tostring(math.floor((tonumber(data.markerScale) or 1.2) * 100 + 0.5)) .. "%") end

        local usable = enabled and desc ~= nil and desc.state ~= "Faulted"
        for _, w in ipairs({
            self.roleToggle, self.roleMode, self.roleApply,
            self.sacToggle, self.sacScan,
            self.reviewToggle, self.reviewAuto, self.reviewWindow, self.reviewCount, self.reviewDebuff, self.reviewMin,
            self.markerMinus, self.markerPlus, self.markerReset,
        }) do SafeEnable(w, usable) end
        SafeEnable(self.reviewHistory, review ~= nil)
        if data.markerScaleAvailable == false then
            SafeEnable(self.markerMinus, false); SafeEnable(self.markerPlus, false); SafeEnable(self.markerReset, false)
        end
        SafeEnable(self.raidBuffCheck, usable and svc ~= nil)
        SafeEnable(self.raidSiegeCheck, usable and svc ~= nil)
    end

    local function LayoutSac(self, x, y, width, height, sc)
        self.sacCard:SetExtent(width, height); S.UI:SetAnchor(self.sacCard, self.root, x, y)
        self.sacTitle:SetExtent(width - 24 * sc, 22 * sc); S.UI:SetAnchor(self.sacTitle, self.root, x + 12 * sc, y + 10 * sc)
        self.sacHint:SetExtent(width - 24 * sc, 36 * sc); S.UI:SetAnchor(self.sacHint, self.root, x + 12 * sc, y + 34 * sc)
        self.sacStatus:SetExtent(width - 24 * sc, 22 * sc); S.UI:SetAnchor(self.sacStatus, self.root, x + 12 * sc, y + 76 * sc)
        self.sacToggle:SetExtent(100 * sc, 27 * sc); S.UI:SetAnchor(self.sacToggle, self.root, x + 12 * sc, y + height - 40 * sc)
        self.sacScan:SetExtent(86 * sc, 27 * sc); S.UI:SetAnchor(self.sacScan, self.root, x + 118 * sc, y + height - 40 * sc)
    end

    local function LayoutReview(self, x, y, width, height, sc)
        self.reviewCard:SetExtent(width, height); S.UI:SetAnchor(self.reviewCard, self.root, x, y)
        self.reviewTitle:SetExtent(width - 24 * sc, 22 * sc); S.UI:SetAnchor(self.reviewTitle, self.root, x + 12 * sc, y + 10 * sc)
        self.reviewHint:SetExtent(width - 24 * sc, 32 * sc); S.UI:SetAnchor(self.reviewHint, self.root, x + 12 * sc, y + 34 * sc)
        self.reviewStatus:SetExtent(width - 24 * sc, 18 * sc); S.UI:SetAnchor(self.reviewStatus, self.root, x + 12 * sc, y + 68 * sc)

        local innerW = math.max(1, width - 24 * sc)
        local buttonGap = 5 * sc
        local buttonW = math.max(58 * sc, (innerW - buttonGap * 2) / 3)
        local bx = x + 12 * sc
        local row1 = y + 92 * sc
        local row2 = row1 + 30 * sc
        local row3 = row2 + 30 * sc
        self.reviewToggle:SetExtent(buttonW, 25 * sc); S.UI:SetAnchor(self.reviewToggle, self.root, bx, row1)
        self.reviewAuto:SetExtent(buttonW, 25 * sc); S.UI:SetAnchor(self.reviewAuto, self.root, bx + buttonW + buttonGap, row1)
        self.reviewHistory:SetExtent(buttonW, 25 * sc); S.UI:SetAnchor(self.reviewHistory, self.root, bx + (buttonW + buttonGap) * 2, row1)
        self.reviewWindow:SetExtent(buttonW, 25 * sc); S.UI:SetAnchor(self.reviewWindow, self.root, bx, row2)
        self.reviewCount:SetExtent(buttonW, 25 * sc); S.UI:SetAnchor(self.reviewCount, self.root, bx + buttonW + buttonGap, row2)
        self.reviewDebuff:SetExtent(buttonW, 25 * sc); S.UI:SetAnchor(self.reviewDebuff, self.root, bx + (buttonW + buttonGap) * 2, row2)
        self.reviewMin:SetExtent(innerW, 25 * sc); S.UI:SetAnchor(self.reviewMin, self.root, bx, row3)
    end

    local function LayoutMarker(self, x, y, width, height, sc)
        self.markerCard:SetExtent(width, height); S.UI:SetAnchor(self.markerCard, self.root, x, y)
        self.markerTitle:SetExtent(width - 24 * sc, 22 * sc); S.UI:SetAnchor(self.markerTitle, self.root, x + 12 * sc, y + 10 * sc)
        self.markerHint:SetExtent(width - 24 * sc, 38 * sc); S.UI:SetAnchor(self.markerHint, self.root, x + 12 * sc, y + 34 * sc)
        local centerY = y + math.max(78 * sc, height - 56 * sc)
        local totalW = 38 * sc + 6 * sc + 72 * sc + 6 * sc + 38 * sc + 8 * sc + 86 * sc
        local mx = x + math.max(12 * sc, (width - totalW) / 2)
        self.markerMinus:SetExtent(38 * sc, 28 * sc); S.UI:SetAnchor(self.markerMinus, self.root, mx, centerY)
        self.markerValue:SetExtent(72 * sc, 28 * sc); S.UI:SetAnchor(self.markerValue, self.root, mx + 44 * sc, centerY)
        self.markerPlus:SetExtent(38 * sc, 28 * sc); S.UI:SetAnchor(self.markerPlus, self.root, mx + 122 * sc, centerY)
        self.markerReset:SetExtent(86 * sc, 28 * sc); S.UI:SetAnchor(self.markerReset, self.root, mx + 168 * sc, centerY)
    end

    function page:ApplyLayout(spec)
        S.UI:SetAnchor(self.root, parent, 0, 0); self.root:SetExtent(spec.contentWidth, spec.contentHeight)
        local sc = S.Layout:GetContext().addonScale
        local pad = 12 * sc
        local full = math.max(1, spec.contentWidth - pad * 2)
        self.title:SetExtent(math.max(120 * sc, full - 310 * sc), 28 * sc); S.UI:SetAnchor(self.title, self.root, pad, 7 * sc)
        local right = pad + full
        self.moduleToggle:SetExtent(104 * sc, 27 * sc); S.UI:SetAnchor(self.moduleToggle, self.root, right - 104 * sc, 6 * sc)
        self.retry:SetExtent(92 * sc, 27 * sc); S.UI:SetAnchor(self.retry, self.root, right - 202 * sc, 6 * sc)
        self.moduleState:SetExtent(94 * sc, 24 * sc); S.UI:SetAnchor(self.moduleState, self.root, right - 302 * sc, 8 * sc)
        self.note:SetExtent(full, 22 * sc); S.UI:SetAnchor(self.note, self.root, pad, 39 * sc)

        local top = 70 * sc
        local gap = 10 * sc
        local roleH = 138 * sc
        self.roleCard:SetExtent(full, roleH); S.UI:SetAnchor(self.roleCard, self.root, pad, top)
        -- P0-4: role card splits into left content + right tool zone (136sc).
        local toolW = 136 * sc
        local toolGap = 10 * sc
        local leftW = math.max(200 * sc, full - toolW - toolGap)
        local lx = pad + 12 * sc
        self.roleTitle:SetExtent(leftW - 24 * sc, 22 * sc); S.UI:SetAnchor(self.roleTitle, self.root, lx, top + 8 * sc)
        self.roleHint:SetExtent(leftW - 24 * sc, 20 * sc); S.UI:SetAnchor(self.roleHint, self.root, lx, top + 31 * sc)
        self.roleStatus:SetExtent(leftW - 24 * sc, 20 * sc); S.UI:SetAnchor(self.roleStatus, self.root, lx, top + 53 * sc)
        self.roleDetail:SetExtent(leftW - 24 * sc, 18 * sc); S.UI:SetAnchor(self.roleDetail, self.root, lx, top + 74 * sc)
        local actionGap = 6 * sc
        local actionW = math.max(64 * sc, (leftW - 24 * sc - actionGap * 2) / 3)
        self.roleToggle:SetExtent(actionW, 27 * sc); S.UI:SetAnchor(self.roleToggle, self.root, lx, top + 101 * sc)
        self.roleMode:SetExtent(actionW, 27 * sc); S.UI:SetAnchor(self.roleMode, self.root, lx + actionW + actionGap, top + 101 * sc)
        self.roleApply:SetExtent(actionW, 27 * sc); S.UI:SetAnchor(self.roleApply, self.root, lx + (actionW + actionGap) * 2, top + 101 * sc)
        -- Tool zone: title + two manual check buttons, vertically centred in
        -- the role card (no gap left by the removed raid-sort toggle).
        local tx = pad + leftW + toolGap
        self.raidToolsTitle:SetExtent(toolW - 12 * sc, 20 * sc); S.UI:SetAnchor(self.raidToolsTitle, self.root, tx + 6 * sc, top + 8 * sc)
        self.raidBuffCheck:SetExtent(toolW - 12 * sc, 24 * sc); S.UI:SetAnchor(self.raidBuffCheck, self.root, tx + 6 * sc, top + 40 * sc)
        self.raidSiegeCheck:SetExtent(toolW - 12 * sc, 24 * sc); S.UI:SetAnchor(self.raidSiegeCheck, self.root, tx + 6 * sc, top + 70 * sc)

        local lowerY = top + roleH + gap
        local lowerAvailable = math.max(1, spec.contentHeight - lowerY - pad)
        if full >= 820 * sc then
            local cardW = (full - gap * 2) / 3
            local cardH = math.max(184 * sc, lowerAvailable)
            LayoutSac(self, pad, lowerY, cardW, cardH, sc)
            LayoutReview(self, pad + cardW + gap, lowerY, cardW, cardH, sc)
            LayoutMarker(self, pad + (cardW + gap) * 2, lowerY, cardW, cardH, sc)
        elseif full >= 560 * sc then
            local cardW = (full - gap) / 2
            local row1H = math.max(184 * sc, math.floor((lowerAvailable - gap) * 0.56))
            local row2Y = lowerY + row1H + gap
            local row2H = math.max(132 * sc, spec.contentHeight - row2Y - pad)
            LayoutSac(self, pad, lowerY, cardW, row1H, sc)
            LayoutReview(self, pad + cardW + gap, lowerY, cardW, row1H, sc)
            LayoutMarker(self, pad, row2Y, full, row2H, sc)
        else
            local sacH = 144 * sc
            local reviewH = 184 * sc
            local markerH = math.max(132 * sc, lowerAvailable - sacH - reviewH - gap * 2)
            local reviewY = lowerY + sacH + gap
            local markerY = reviewY + reviewH + gap
            LayoutSac(self, pad, lowerY, full, sacH, sc)
            LayoutReview(self, pad, reviewY, full, reviewH, sc)
            LayoutMarker(self, pad, markerY, full, markerH, sc)
        end
        self:Refresh()
    end

    S.UI.pages.team = page
    return page
end
