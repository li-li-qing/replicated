------------------------------------------------------------------------
-- Replicated Suite - Visual Layer Preview (M6-v3)
-- On-demand only: no Tick / OnUpdate.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
S.Visual = S.Visual or {}
local P = { instance = nil }
S.Visual.Preview = P

function P:Open()
    if self.instance ~= nil and self.instance.window ~= nil then self.instance.window:Show(true); return true end
    if S.UI == nil or type(S.UI.CreateManagedWindow) ~= "function" then return false end
    local managed = S.UI:CreateManagedWindow({ id = "visual_preview", width = 620, height = 520, minWidth = 520, minHeight = 420, maxWidth = 820, maxHeight = 700, resizable = true })
    if managed == nil or managed.window == nil then return false end
    local window = managed.window
    S.Visual.Surface:Apply(window, { surface = "app", borderTone = "goldSoft", topAccent = true, accentHeight = 2 })
    local title = S.UI:CreateLabel(window, "visual_preview_title", "M6-v3 Visual Layer Playground", 12, 8, 420, 28, 14, "brand", ALIGN_LEFT)
    managed:BindTitleBar(title)
    local close = S.UI:CreateButton(window, "visual_preview_close", "×", 574, 6, 30, 26, 12, false, true)
    S.UI:SafeHandler(close, "OnClick", function() window:Show(false); return true end, "visual_preview:close")
    local note = S.UI:CreateLabel(window, "visual_preview_note", "只用于视觉验收；不扫描游戏数据，不创建常驻刷新。", 12, 36, 580, 20, 9, "muted", ALIGN_LEFT)

    local card = S.Visual.DashboardCard:Create(window, "visual_preview_card", "DashboardCard", {
        { text = "主操作", width = 54, variant = "primary" },
        { text = "更多", width = 44, variant = "ghost" },
    }, { headerHeight = 31 })
    local tableView = RSUI:TableView({
        id = "visual_preview_table", parent = card.stack,
        columns = {
            { id = "name", title = "项目", size = "fill", field = "name" },
            { id = "status", title = "状态", width = 90, field = "status", getTone = function(r) return r.tone end },
            { id = "value", title = "数值", width = 80, field = "value", align = ALIGN_RIGHT },
        },
        rowHeight = 24, headerHeight = 23, items = {
            { name = "普通数据行", status = "正常", value = "128%", tone = "green" },
            { name = "警告数据行", status = "注意", value = "00:04:32", tone = "yellow" },
            { name = "危险数据行", status = "战争", value = "3 / 3", tone = "red" },
        },
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    card.component:LayoutIfNeeded(12, 66, 596, 180, true)
    local buttonRow = RSUI:HorizontalBox({ id = "visual_preview_buttons", parent = window, gap = 6 })
    S.Visual.ActionButton:Create({ id = "visual_preview_primary", parent = buttonRow, text = "Primary", visualVariant = "primary", slot = { size = "fixed", width = 110 } })
    S.Visual.ActionButton:Create({ id = "visual_preview_secondary", parent = buttonRow, text = "Secondary", visualVariant = "secondary", slot = { size = "fixed", width = 110 } })
    S.Visual.ActionButton:Create({ id = "visual_preview_ghost", parent = buttonRow, text = "Ghost", visualVariant = "ghost", slot = { size = "fixed", width = 110 } })
    S.Visual.ActionButton:Create({ id = "visual_preview_danger", parent = buttonRow, text = "Danger", visualVariant = "danger", slot = { size = "fixed", width = 110 } })
    buttonRow:LayoutIfNeeded(12, 258, 596, 30, true)

    local dd = S.Visual.StyledDropdown:Create({
        id = "visual_preview_dropdown", parent = window, width = 250, height = 28, maxVisible = 7,
        items = {
            { value = "__group:west", text = "— 西大陆 —", kind = "header", selectable = false },
            { value = 1, text = "格威尔森林" }, { value = 2, text = "玛瑞诺普" },
            { value = "__group:east", text = "— 东大陆 —", kind = "header", selectable = false },
            { value = 3, text = "黎明半岛" }, { value = 4, text = "咏唱之地" },
        },
    })
    dd:LayoutIfNeeded(12, 304, 250, 28)
    local longZh = S.UI:CreateLabel(window, "visual_preview_long_zh", "超长中文：这是用于验证省略与层级的视觉压力文本，不应该覆盖相邻控件。", 12, 350, 580, 22, 10, nil, ALIGN_LEFT)
    if S.Theme and S.Theme.SetEllipsis then S.Theme:SetEllipsis(longZh, true) end
    local longRu = S.UI:CreateLabel(window, "visual_preview_long_ru", "Русский длинный текст: проверка плотной таблицы и безопасного обрезания.", 12, 378, 580, 22, 10, "muted", ALIGN_LEFT)
    if S.Theme and S.Theme.SetEllipsis then S.Theme:SetEllipsis(longRu, true) end
    managed:ApplyPlacement()
    window:Show(true)
    self.instance = managed
    return true
end
