------------------------------------------------------------------------
-- 页面与死亡弹窗共用的两列只读内容；不读取 Native 元数据、不改变历史记录。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local R = S.RSUI
if type(R) ~= "table" then return end
S.UIV3 = S.UIV3 or {}
local C = {}
S.UIV3.DeathReviewContent = C
local UNKNOWN_ICON = "ui/icon/icon_unknown_item.dds"
local function Fill(weight) return { size = "fill", fill = weight or 1, hAlign = "fill", vAlign = "fill" } end
local function IconColumn()
    return { id = "icon", title = "", field = "iconPath", cellType = "icon", iconSize = 18,
        fallbackIcon = UNKNOWN_ICON, size = "fixed", width = 24, minWidth = 24 }
end
local function StatusRows(rows)
    local result = {}
    for _, row in ipairs(rows or {}) do
        local time = tonumber(row.timeLeft)
        result[#result + 1] = { iconPath = row.path or UNKNOWN_ICON,
            name = tostring(row.name or "未知效果") .. ((tonumber(row.stack) or 0) > 1 and (" ×" .. tostring(row.stack)) or ""),
            timeText = time ~= nil and string.format("%.1fs", time / 1000) or "--" }
    end
    return result
end
local function StateText(state, count)
    if state == "complete" then return count > 0 and tostring(count) or "无" end
    if state == "partial" then return tostring(count) .. " · 部分采集" end
    if state == "unavailable" then return "读取失败" end
    if state == "disabled" then return "采集已关闭" end
    if state == "legacy" then return tostring(count) .. " · 旧记录" end
    return "未采集"
end

function C:Create(parent, id)
    local view = {}
    view.root = R:VerticalBox({ id = id .. "_content", parent = parent, gap = 4, slot = Fill() })
    -- 两个单行控件由固定槽位安排间距，避免 Native 行高偏小使中文基线重叠。
    local summaryLines = R:VerticalBox({ id = id .. "_summary_lines", parent = view.root, gap = 0,
        slot = { size = "fixed", height = 36, hAlign = "fill" } })
    view.summary = R:Text({ id = id .. "_summary", parent = summaryLines, text = "暂无死亡记录", fontSize = 10,
        tone = "strong", overflow = "ellipsis", slot = { size = "fixed", height = 18, hAlign = "fill" } })
    view.lethalSummary = R:Text({ id = id .. "_lethal_summary", parent = summaryLines, text = "", fontSize = 10,
        tone = "strong", overflow = "ellipsis", slot = { size = "fixed", height = 18, hAlign = "fill" } })
    view.statusHint = R:Text({ id = id .. "_capture_hint", parent = view.root, text = "状态：未采集", fontSize = 9,
        tone = "muted", overflow = "ellipsis", slot = { size = "fixed", height = 16, hAlign = "fill" } })
    local body = R:HorizontalBox({ id = id .. "_columns", parent = view.root, gap = 6, slot = Fill() })
    view.damagePanel = R:VerticalBox({ id = id .. "_damage", parent = body, gap = 3, slot = Fill(0.55) })
    view.statusPanel = R:VerticalBox({ id = id .. "_status", parent = body, gap = 3, slot = Fill(0.45) })
    R:Text({ id = id .. "_damage_title", parent = view.damagePanel, text = "受到的伤害", fontSize = 10,
        tone = "strong", slot = { size = "fixed", height = 18 } })
    view.timeline = R:TableView({ id = id .. "_timeline", parent = view.damagePanel, items = {}, rowHeight = 32,
        headerHeight = 20, scrollbar = true, selectable = false, columnResize = true,
        columns = { IconColumn(),
            { id = "time", title = "时间", field = "timeText", size = "fixed", width = 40, minWidth = 36 },
            { id = "ability", title = "技能", size = "fill", fill = 0.6, minWidth = 40, overflow = "ellipsis",
                getText = function(row) return tostring(row.ability or "普通攻击") end },
            { id = "source", title = "来源", size = "fill", fill = 0.4, minWidth = 34, overflow = "ellipsis",
                getText = function(row) return tostring(row.source or "未知来源") end },
            { id = "amount", title = "伤害", field = "amount", size = "fixed", width = 48, minWidth = 42, getTone = function() return "red" end } }, slot = Fill() })
    local function Group(lane, label, tone)
        local group = R:VerticalBox({ id = id .. "_" .. lane .. "_group", parent = view.statusPanel, gap = 2, slot = Fill() })
        local title = R:Text({ id = id .. "_" .. lane .. "_title", parent = group, text = label .. " · 未采集", fontSize = 10,
            tone = tone, overflow = "ellipsis", slot = { size = "fixed", height = 18 } })
        local list = R:TableView({ id = id .. "_" .. lane .. "s", parent = group, items = {}, rowHeight = 25,
            headerHeight = 20, scrollbar = true, selectable = false, columnResize = true,
            columns = { IconColumn(), { id = "name", title = "状态 / 层数", field = "name", size = "fill", fill = 1, minWidth = 40 },
                { id = "time", title = "剩余", field = "timeText", size = "fixed", width = 44, minWidth = 36 } }, slot = Fill() })
        return title, list
    end
    view.debuffTitle, view.debuffs = Group("debuff", "Debuff 减益", "red")
    view.buffTitle, view.buffs = Group("buff", "Buff 增益", "green")
    function view:Render(rows, record)
        local revision = record and record.serial or 0
        self.timeline:SetItems(rows or {}, revision)
        self.timeline:SetViewState("ready")
        local buffs, debuffs = StatusRows(record and record.buffs), StatusRows(record and record.debuffs)
        self.buffs:SetItems(buffs, revision);self.debuffs:SetItems(debuffs, revision)
        self.buffs:SetViewState("ready");self.debuffs:SetViewState("ready")
        local captured = record and record.statusSnapshot or {}
        self.buffTitle:SetText("Buff 增益 · " .. StateText(captured.buff, #buffs))
        self.debuffTitle:SetText("Debuff 减益 · " .. StateText(captured.debuff or (record and "legacy"), #debuffs))
        if record == nil then
            self.summary:SetText("暂无死亡记录")
            self.lethalSummary:SetText("")
            self.statusHint:SetText("死亡后显示伤害与最后观测到的状态")
            return true
        end
        local lethal = record.lethal or {}
        self.summary:SetText(tostring(record.clock or "--:--:--") .. " · 总伤害 " .. tostring(record.totalDamage or 0)
            .. " · 窗口 " .. string.format("%.1fs", (tonumber(record.windowMs) or 0) / 1000))
        self.lethalSummary:SetText("致命：" .. tostring(lethal.source or "--") .. " · " .. tostring(lethal.ability or "--") .. " · " .. tostring(lethal.amount or 0))
        local at = tonumber(captured.time)
        local hint = record.statusSnapshot == nil and "旧记录未采集 Buff；保留已记录的 Debuff" or "本次死亡前未采集到状态"
        if captured.buff == "disabled" then hint = "状态采集已关闭" end
        if at then hint = "死亡前 " .. string.format("%.1fs", math.max(0, ((tonumber(record.noticeTime or record.time) or at) - at) / 1000))
            .. " 的状态快照 · 剩余时间按采集时显示" end
        self.statusHint:SetText(hint)
        return true
    end
    return view
end
