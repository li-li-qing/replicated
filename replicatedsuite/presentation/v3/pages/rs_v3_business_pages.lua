-- Replicated Suite · 业务功能页面
-- 作者：Replicated
-- QQ群：1104129461
-- 总开关复用 PageHost 的按钮，刷新时不能改父级或重复绑定 OnClick。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI, D, Host = S.RSUI, S.UIV3Design, S.UIV3 and S.UIV3.PageHost or nil
if type(RSUI) ~= "table" or type(D) ~= "table" or type(Host) ~= "table" then return end
-- Slider 只给出推荐起始范围，安全边界取 Constants.VisualGuide 并由 Feature 校验。
-- 精确输入被接受后才扩展滑块，避免 UI、Domain、Renderer 各留一份旧上限。
local VISUAL_LIMITS = (S.Constants and S.Constants.VisualGuide) or {}
local UNIT_DENSITY_HARD_MIN = tonumber(VISUAL_LIMITS.unitLineDensityHardMin) or 2
local UNIT_DENSITY_HARD_MAX = tonumber(VISUAL_LIMITS.unitLineDensityHardMax) or 160
local RANGE_DENSITY_HARD_MIN = tonumber(VISUAL_LIMITS.rangeDensityHardMin) or 3
local RANGE_DENSITY_HARD_MAX = tonumber(VISUAL_LIMITS.rangeDensityHardMax) or 192
local RANGE_RADIUS_HARD_MIN = tonumber(VISUAL_LIMITS.rangeRadiusHardMin) or 0.5
local RANGE_RADIUS_HARD_MAX = tonumber(VISUAL_LIMITS.rangeRadiusHardMax) or 1000
local REFRESH_HARD_MIN = tonumber(VISUAL_LIMITS.refreshMsHardMin) or 1
local REFRESH_HARD_MAX = tonumber(VISUAL_LIMITS.refreshMsHardMax) or 60000
S.UIV3.BusinessPagesContract = { version = 11, componentIdContractVersion = 1, bagProductUxContractVersion = 3, auctionCurrentListingUxContractVersion = 1, auctionSidecarEntryContractVersion = 2, craftSidecarUxContractVersion = 1, unitLineSettingsFoundationConsumerContractVersion = 3,
    teamCenterLayoutContractVersion = 1, teamFeatureSplitContractVersion = 1,
    rangeAssistEditorLayoutContractVersion = 1,
    visualSettingsInputFenceContractVersion = 1, -- UnitLines/RangeAssist 的 visual_tick 按原频率绘制；持有输入草稿时禁止整页表现刷新，编辑结束由下一 visual_tick 追平。
}

local ROUTES = {
    { route = "combat.boss_alerts", id = "combat_boss_alerts" }, { route = "combat.target_monitor", id = "combat_target_monitor" },
    { route = "combat.unit_lines", id = "combat_unit_lines" }, { route = "combat.range_assist", id = "combat_range_assist" },
    { route = "combat.buff_cap", id = "combat_buff_cap" }, { route = "combat.team_tools", id = "combat_team_tools" },
    { route = "combat.sac_highlight", id = "combat_sac_highlight" },
    { route = "combat.raid_recruitment", id = "combat_raid_recruitment" }, { route = "combat.siege_readiness", id = "combat_siege_readiness" },

    { route = "tools.bag_organizer", id = "tools_bag" },
    { route = "tools.auction_favorites", id = "tools_auction" }, { route = "tools.market_analysis", id = "tools_market_analysis" },
    { route = "tools.craft_assist", id = "tools_craft" }, { route = "tools.social", id = "tools_social" },
}

local BUSINESS_STATUS_ZH = {
    ready = "就绪", idle = "空闲", waiting = "等待结果", partial = "部分可用",
    empty = "暂无数据", unavailable = "不可用", failed = "读取失败", runtime_blocked = "运行时阻塞",
    running = "运行中", complete = "已完成", stopped = "已停止", cancelled = "已取消",
}

local function BusinessStatusText(value)
    local key = tostring(value or "ready")
    return BUSINESS_STATUS_ZH[key] or key
end
local function AuctionRowKey(row,index)
    -- 收藏下标会随删除/移动变化；管理选择属于关键词，分页表不能复用上一页的行号作身份。
    if type(row)=="table" and row.kind=="favorite" then return "favorite:"..tostring(row.name or "") end
    return type(row)=="table" and (row.key or row.id) or tostring(index)
end
local function SelectedAuctionRow(view)
    -- GetSelectedIndex 在 key 消失/不在池中时会回退旧索引，不能作为删除/询价身份。
    local key=view:GetSelectedKey()
    if key==nil then return nil end
    for index=1,view:GetItemCount() do
        local row=view:GetItem(index)
        if tostring(view:GetItemKey(row,index))==tostring(key) then return row end
    end
    return nil
end

local function ValidateBusinessFeature(feature, id)
    if type(feature) ~= "table" then return false, "Feature implementation unavailable: " .. tostring(id) end
    if type(feature.GetProjection) ~= "function" or type(feature.AcquireConsumer) ~= "function" or type(feature.ReleaseConsumer) ~= "function" then
        return false, "Feature public projection/consumer contract incomplete: " .. tostring(id)
    end
    if type(feature.Commands) ~= "table" or type(feature.Commands.Refresh) ~= "function" then
        return false, "Feature Commands.Refresh contract incomplete: " .. tostring(id)
    end
    return true
end

local function Build(parent, route, id)
    local feature = S.Features and S.Features[id]
    local meta = S.FeatureRegistry and S.FeatureRegistry:Get(id)
    local contractOk, contractErr = ValidateBusinessFeature(feature, id)
    if contractOk ~= true then return nil, contractErr end
    -- 增益计数使用连续滚动，窄屏不必逐项跳页。
    local rootSpec = id == "tools_bag" and { id="v3_page_business_tools_bag",gap=4,padding=2 } or (id == "combat_unit_lines" or id == "combat_boss_alerts" or id == "combat_buff_cap") and {
        id = "v3_page_business_" .. tostring(id), gap = 7, padding = 2, scrollStep = 1,
    } or ("v3_page_business_" .. tostring(id))
    local root, err
    if id == "tools_bag" or id == "combat_range_assist" then
        -- 范围辅助和背包以固定编辑区配合自带滚动的 TableView，使用普通 PageRoot。
        -- 若套 item-snapped ScrollBox，嵌套 auto Measure 会提前排入下一项，挤压标题、颜色和状态行；
        -- 表格也会按 desiredRows 测高，无法填满高窗口。其余顺序表单仍用滚动根节点。
        root, err = D:PageRoot(parent, rootSpec)
    else
        root, err = D:ScrollablePageRoot(parent, rootSpec)
    end
    if root == nil then return nil, err end
    root.consumerHeld = false
    local consumerBinding = {
        feature = feature, featureId = id, token = "page:" .. id,
        refresh = function(page) return page:Refresh() end,
    }
    if id == "combat_buff_cap" then
        -- 构造 Binding 前先读 Store；失败只显示保护页，不能编辑未读默认值或启动观察。
        -- 控件构建错误仍交给 PageHost。
        local called, loaded, loadErr = pcall(feature.Initialize, feature)
        if called ~= true or loaded ~= true then
            root.route, root.persistenceUnavailable = route, true
            D:PageHeader(root, "v3_business_combat_buff_cap_protected_header", "增益容量监控：配置已保护",
                "配置未通过读取校验；未清空旧设置，暂不创建编辑器或启动计数。")
            RSUI:Text({ id = "v3_business_combat_buff_cap_protected_reason", parent = root,
                text = "读取失败：" .. tostring((called and loadErr or loaded) or "未知错误"), fontSize = 10,
                tone = "warn", overflow = "wrap", slot = { size = "auto", minHeight = 45, hAlign = "fill" } })
    -- 保护页沿用宿主诊断按钮。
            function root:OnActivated() return true end
            function root:OnDeactivated() return true end
            return root
        end
    end
    local unitLineSettingsPage = id == "combat_unit_lines"
    local unitLineHeader, unitLineDiagnostics, unitLineDiagnosticsText
    local toggle, hint

    if unitLineSettingsPage then
        local headerErr
        unitLineHeader, headerErr = D:FeatureSettingsHeader(root, {
            id = "v3_business_combat_unit_lines_settings",
            title = meta and meta.name or "单位连线",
            description = "选择需要显示的连线；全局参数控制默认表现，每条连线仍可独立调整密度、点大小和颜色。",
            status = { status = "neutral", text = "等待状态" },
        })
        if unitLineHeader == nil then return nil, headerErr end
        toggle = D:ModuleToggleButton({ id = "v3_business_combat_unit_lines_feature_toggle", parent = unitLineHeader.actions,
            text = "关闭功能", compact = true, slot = { size = "fixed", width = 88 } })
        local refresh = RSUI:Button({ id = "v3_business_combat_unit_lines_refresh_button", parent = unitLineHeader.actions,
            text = "刷新", compact = true, slot = { size = "fixed", width = 64 } })
        if toggle == nil or refresh == nil then return nil, "unit_line_settings_header_actions_failed" end
        refresh.onClick = function()
            local ok, refreshErr = feature.Commands:Refresh("page_manual")
            if ok == true then root:Refresh() end
            return ok, refreshErr
        end
        hint = RSUI:Text({ id = "v3_business_combat_unit_lines_summary", parent = root,
            text = "状态：等待刷新", fontSize = 9, tone = "muted", overflow = "wrap", maxLines = 2,
            slot = { size = "auto", minHeight = 20, hAlign = "fill" } })
        if hint == nil then return nil, "unit_line_settings_summary_failed" end
    else
        D:PageHeader(root, "v3_business_" .. id .. "_header", meta and meta.name or id,
            meta and meta.description or "V3 业务功能页；数据读取由独立 Authority 完成。", id=="tools_bag" and "刷新背包" or (id=="tools_craft" and "刷新计划" or "刷新"), function()
                if id=="tools_craft" then root:Refresh();return true end
                local ok, refreshErr = feature.Commands:Refresh("page_manual")
                if ok == true then root:Refresh() end
                return ok, refreshErr
            end)
    end

    if unitLineSettingsPage ~= true then
        local actionRow = RSUI:HorizontalBox({ id = "v3_business_" .. id .. "_actions", parent = root, gap = 6, slot = { size = "fixed", height = 31, hAlign = "fill" } })
        toggle = D:ModuleToggleButton({ id = "v3_business_" .. id .. "_toggle", parent = actionRow, text = "关闭功能", compact = true, slot = { size = "fixed", width = 96 } })
        hint = RSUI:Text({ id = "v3_business_" .. id .. "_hint", parent = root, text = "", fontSize = 9, tone = "muted", overflow = "wrap", slot = { size = "auto", minHeight = 30, hAlign = "fill" } })
    end
    if toggle == nil or hint == nil then return nil, "business_page_primary_controls_failed:" .. tostring(id) end
    if id=="tools_bag" then hint:SetVisible(false)end
    toggle.onClick = function()
        local enabled = S.FeatureRuntime:IsEnabled(id) == true
        local target = not enabled
        local ok, enableErr = S.FeatureRuntime:SetPreferredEnabled(id, target, "business_page_toggle")
        if ok ~= true then
            if hint ~= nil then hint:SetText("启用失败：" .. tostring(enableErr or "未知原因")) end
            return false, enableErr
        end
        -- PageHost 生命周期桥恢复可见页的 lease；此处幂等核验，把获取失败交给点击事务回滚。
        local synced, syncErr = Host:SyncFeatureConsumer(root, consumerBinding, "business_page_toggle")
        if synced ~= true and target == true then
            local rolledBack, rollbackErr = S.FeatureRuntime:SetPreferredEnabled(id, false, "business_page_acquire_rollback")
            root.consumerHeld = false
            root:Refresh()
            if rolledBack ~= true then return false, tostring(syncErr or "Consumer 启动失败") .. "；回滚失败：" .. tostring(rollbackErr or "unknown") end
            return false, syncErr
        end
        return root:Refresh()
    end
    local specialFields = {}
    local function TrackField(field) if field ~= nil then specialFields[#specialFields + 1] = field end return field end
    -- 范围圆使用稳定列表和单一选中编辑器。按 #circles 在 Build 时生成卡片，
    -- 会让初始空列表新增后只有投影行、没有编辑控件，因为 Refresh 不会创建卡片。
    -- 页面只保存 circleId 选择；刷新、删除后按 id 对齐，不能捕获构建时的行号。
    local rangeSelectedCircleId, rangeSummaryText, rangeEditorTitle, rangeEditorStatus, rangeDeleteButton
    local rangeEditorControls, SyncRangeCircleEditor = {}, nil
    local function TrackRangeEditorControl(field)
        if field ~= nil then rangeEditorControls[#rangeEditorControls + 1] = field end
        return TrackField(field)
    end
    local function BuildRangeCircleRows(projection)
        if id ~= "combat_range_assist" then return type(projection.rows) == "table" and projection.rows or {} end
        projection = type(projection) == "table" and projection or {}
        local liveById = {}
        for _, row in ipairs(type(projection.rows) == "table" and projection.rows or {}) do
            local circleId = math.floor(tonumber(row.circleId) or 0)
            if circleId > 0 then liveById[circleId] = row end
        end
        local rows = {}
        for index, circle in ipairs(type(projection.circles) == "table" and projection.circles or {}) do
            local circleId = math.floor(tonumber(circle.id) or index)
            local live = liveById[circleId]
            local enabled = circle.enabled ~= false
            rows[#rows + 1] = {
                key = "range_circle_" .. tostring(circleId), circleId = circleId,
                name = tostring(circle.name or ("范围圆 " .. tostring(circleId))) .. " · #" .. tostring(circleId),
                text = string.format("半径 %.1fm · 密度 %d · 点大小 %d · 透明度 %d%%",
                    tonumber(circle.radius) or 10, math.floor(tonumber(circle.pointCount) or 24),
                    math.floor(tonumber(circle.pointSize) or 4), math.floor((tonumber(circle.opacity) or 0.68) * 100 + 0.5)),
                statusText = enabled and tostring(live and live.statusText or "等待投影") or "已隐藏",
                tone = enabled and tostring(live and live.tone or "muted") or "muted",
            }
        end
        return rows
    end
    -- 操作前按稳定 key 重读投影，避免排序或刷新后改错规则。
    -- 回执独立于 Refresh 摘要，保存失败不能被后续观察刷新覆盖。
    local bossTestStatus, bossRuleSummary, bossRuleToggle, bossRuleTest
    local bossRulesOn, bossRulesOff, bossSelectedKey, SyncBossControls
    local function FindSelectedBossRule(projection)
        for _, row in ipairs((projection or {}).rows or {}) do
            if bossSelectedKey ~= nil and row.mechanicKey == bossSelectedKey then return row end
        end
        return nil
    end
    local function BossActionResult(ok, actionErr, message)
        if type(root.Refresh) == "function" then root:Refresh() end
        if bossTestStatus ~= nil then
            bossTestStatus:SetText(ok == true and message or ("操作失败：" .. tostring(actionErr or "未执行")))
        end
        return ok, actionErr
    end
    -- 计数设置的操作回执与实时读数分开；后续观察刷新不能吞掉保存失败。
    -- 开关/阈值只经 Feature Commands，输入草稿/焦点/应用按钮继续由 RSUI NumericField 持有。
    local capActionStatus, capLiveStatus, capTestButton, SyncBuffCapControls
    if id == "combat_buff_cap" then
        local function Result(ok, actionErr, message)
            if type(root.Refresh) == "function" then root:Refresh() end
            if capActionStatus ~= nil then capActionStatus:SetText(ok == true and message or ("操作失败：" .. tostring(actionErr or "未执行"))) end
            return ok, actionErr
        end
        local actions = RSUI:UniformGrid({ id = "v3_business_combat_buff_cap_settings_actions", parent = root,
            minCellWidth = 140, minCellHeight = 30, maxColumns = 3, gap = 6,
            slot = { size = "auto", minHeight = 30, hAlign = "fill" } })
        TrackField(RSUI:Toggle({ id = "v3_business_combat_buff_cap_reminder_enabled", parent = actions,
            onText = "个人数量提醒：开", offText = "个人数量提醒：关",
            get = function() return feature:GetProjection().reminderEnabled == true end,
            set = function(value)
                local ok, actionErr = feature.Commands:SetReminderEnabled(value)
                return Result(ok, actionErr, "提醒开关已保存并回读；至少一项阈值大于0才后台观察。")
            end, slot = { size = "fill", hAlign = "fill" } }))
        capTestButton = RSUI:Button({ id = "v3_business_combat_buff_cap_test_reminder", parent = actions,
            text = "测试屏幕提醒", compact = true, slot = { size = "fill", hAlign = "fill" },
            onClick = function()
                local ok, actionErr = feature.Commands:TestReminder()
                return Result(ok, actionErr, "已发送手动提醒；不代表真实计数越线，也不改变峰值。")
            end })
        RSUI:Button({ id = "v3_business_combat_buff_cap_reset_peaks", parent = actions,
            text = "重置本次峰值", compact = true, slot = { size = "fill", hAlign = "fill" },
            onClick = function()
                local ok, actionErr = feature.Commands:ResetPeaks()
                return Result(ok, actionErr, "峰值已从当前可靠读数重新开始；设置未改变。")
            end })
        local fields = RSUI:UniformGrid({ id = "v3_business_combat_buff_cap_thresholds", parent = root,
            minCellWidth = 250, minCellHeight = 30, maxColumns = 2, gap = 6,
            slot = { size = "auto", minHeight = 30, hAlign = "fill" } })
        local function AddThreshold(key, label)
            -- 只提供精确整数输入和显式应用，不创建第二套滑块范围存档。
            -- 0-1000 是个人配置预算，不代表 Buff 槽位上限；未实测的容量预警继续不开放。
            TrackField(D:CompactNumericSetting(fields, { id = "v3_business_combat_buff_cap_" .. key .. "_threshold",
                label = label, min = 0, max = 1000, step = 1, integer = true, slider = false,
                inputWidth = 70, labelWidth = 86, applyButton = true,
                get = function() return feature:GetProjection()[key .. "Threshold"] or 0 end,
                set = function(value)
                    local ok, actionErr = feature.Commands:SetThreshold(key, value)
                    return Result(ok, actionErr, label .. "已保存并回读；0表示关闭该类提醒。")
                end, slot = { size = "fill", hAlign = "fill" } }))
        end
        AddThreshold("normal", "普通增益阈值")
        AddThreshold("hidden", "隐藏增益阈值")
        capActionStatus = RSUI:Text({ id = "v3_business_combat_buff_cap_action_status", parent = root,
            text = "阈值默认0（关闭）；输入后点击应用。功能关闭时也能保存设置。", fontSize = 9,
            tone = "muted", overflow = "wrap", slot = { size = "auto", minHeight = 22, hAlign = "fill" } })
        capLiveStatus = RSUI:Text({ id = "v3_business_combat_buff_cap_live_status", parent = root,
            text = "", fontSize = 9, tone = "muted", overflow = "wrap", slot = { size = "auto", minHeight = 22, hAlign = "fill" } })
        SyncBuffCapControls = function(projection)
            capTestButton:SetEnabled(S.FeatureRuntime:IsEnabled(id) == true)
            local text = (projection.observing == true and "正在观察" or "观察已停止")
                .. " · 采样 " .. tostring(projection.samples or 0) .. " · 部分/失败 " .. tostring(projection.failedSamples or 0)
                .. " · 自动提醒 " .. tostring(projection.delivered or 0)
            if projection.error ~= nil then text = text .. " · " .. tostring(projection.error) end
            if projection.reminderError ~= nil then text = text .. " · 提醒失败：" .. tostring(projection.reminderError) end
            capLiveStatus:SetText(text)
        end
    end

    if id == "combat_boss_alerts" then
        -- 六个按钮加回执会超出窄页；共享 UniformGrid 负责换行。
        local hudRow = RSUI:UniformGrid({ id = "v3_business_combat_boss_alerts_hud_row", parent = root,
            minCellWidth = 145, minCellHeight = 30, maxColumns = 3, gap = 6,
            slot = { size = "auto", minHeight = 30, hAlign = "fill" } })
        TrackField(RSUI:Toggle({ id = "v3_business_combat_boss_alerts_hud_enabled", parent = hudRow,
            onText = "机制 HUD：开", offText = "机制 HUD：关",
            get = function() return (feature:GetProjection() or {}).hudEnabled == true end,
            set = function(v)
                local ok, actionErr = feature.Commands:SetHudEnabled(v == true)
                return BossActionResult(ok, actionErr, "HUD 开关已保存并回读")
            end, slot = { size = "fill", hAlign = "fill" } }))
        TrackField(RSUI:Toggle({ id = "v3_business_combat_boss_alerts_hud_anchor", parent = hudRow,
            onText = "位置：顶部", offText = "位置：中央",
            get = function() return (feature:GetProjection() or {}).hudAnchor == "top" end,
            set = function(v) return feature.Commands:SetHudAnchor(v and "top" or "center") end,
            slot = { size = "fill", hAlign = "fill" } }))
        local function TestButton(suffix, text, command, success)
            return RSUI:Button({ id = "v3_business_combat_boss_alerts_" .. suffix, parent = hudRow,
                text = text, compact = true, slot = { size = "fill", hAlign = "fill" },
                onClick = function()
                    local ok, actionErr = feature.Commands[command](feature.Commands)
                    return BossActionResult(ok, actionErr, success)
                end })
        end
        TestButton("test_big", "测试大字", "TestBigText", "大字 HUD 已触发（手动测试）")
        TestButton("test_countdown", "测试倒计时", "TestCountdown", "倒计时 HUD 已触发（手动测试）")
        TestButton("sim_cast", "仿真读条", "SimulateCast", "仿真读条已触发；不是实时命中证明")
        TestButton("sim_debuff", "仿真 Debuff", "SimulateDebuff", "仿真 Debuff 已触发；不是实时命中证明")
        -- 校准通过命令/服务/Windowing，不让页面直接操纵 HUD Native。
        TrackField(RSUI:Toggle({id="v3_business_combat_boss_alerts_hud_edit", parent=hudRow,
            onText="完成 HUD 调整", offText="调整 HUD（可拖动）",
            get=function()return (feature:GetProjection() or {}).hudEditing == true end,
            set=function(v)local ok,err=feature.Commands:SetHudEditing(v==true);return BossActionResult(ok,err,"HUD 调整状态已切换")end,
            slot={size="fill",hAlign="fill"}}))
        TestButton("hud_reset", "重置 HUD 布局", "ResetHudLayout", "HUD 布局已重置，机制开关未改变")
        TrackField(RSUI:Toggle({id="v3_business_combat_boss_alerts_observed_casts", parent=hudRow,
            onText="未收录读条：开", offText="未收录读条：关",
            get=function()return (feature:GetProjection() or {}).showObservedCasts==true end,
            set=function(v)local ok,err=feature.Commands:SetShowObservedCasts(v==true);return BossActionResult(ok,err,"仅显示目标/关注目标的真实读条，不预测 CD")end,
            slot={size="fill",hAlign="fill"}}))
        local hudGrid = RSUI:UniformGrid({ id = "v3_business_combat_boss_alerts_hud_grid", parent = root, minCellWidth = 260, minCellHeight = 30, maxColumns = 2, gap = 5, slot = { size = "auto", minHeight = 30, hAlign = "fill" } })
        TrackField(D:CompactNumericSetting(hudGrid, { id = "v3_business_combat_boss_alerts_font", label = "HUD 字号", min = 18, max = 56, step = 1, integer = true, unit = "", slider = true,
            get = function() return (feature:GetProjection() or {}).hudFontSize or 34 end, set = function(v) return feature.Commands:SetHudFontSize(v) end, slot = { size = "fill", fill = 1, hAlign = "fill" } }))
        TrackField(D:CompactNumericSetting(hudGrid, { id = "v3_business_combat_boss_alerts_duration", label = "大字时长", min = 1000, max = 10000, step = 250, integer = true, unit = "ms", slider = true,
            get = function() return (feature:GetProjection() or {}).hudDurationMs or 3000 end, set = function(v) return feature.Commands:SetHudDurationMs(v) end, slot = { size = "fill", fill = 1, hAlign = "fill" } }))
        -- 数值与拖拽共用同一耐久设置；零/负偏移有效，修改后立即布局但不重启倒计时。
        for _, setting in ipairs({
            {suffix="offset_x",label="水平偏移",key="hudOffsetX",command="SetHudOffsetX",min=-8192,max=8192,default=0},
            {suffix="offset_y",label="垂直偏移",key="hudOffsetY",command="SetHudOffsetY",min=-8192,max=8192,default=0},
            {suffix="width",label="HUD 宽度",key="hudWidth",command="SetHudWidth",min=280,max=1200,default=720},
        }) do
            local field=setting
            TrackField(D:CompactNumericSetting(hudGrid,{id="v3_business_combat_boss_alerts_"..field.suffix,
                label=field.label,min=field.min,max=field.max,step=1,integer=true,unit="",slider=false,
                get=function()return (feature:GetProjection() or {})[field.key] or field.default end,
                set=function(v)local ok,err=feature.Commands[field.command](feature.Commands,v);return BossActionResult(ok,err,"HUD 设置已保存并应用")end,
                slot={size="fill",fill=1,hAlign="fill"}}))
        end
        RSUI:Text({id="v3_business_combat_boss_alerts_coverage_hint",parent=root,
            text="已知机制仅 3 种读条 + 2 种自身 Debuff。可开启未收录读条；瞬发、未观察单位和未来 CD 不会被猜测。倒计时按实际剩余时间结束。",
            fontSize=9,tone="muted",overflow="wrap",maxLines=3,slot={size="auto",minHeight=32,hAlign="fill"}})
        local ruleActions = RSUI:UniformGrid({ id = "v3_business_combat_boss_alerts_rule_actions", parent = root,
            minCellWidth = 145, minCellHeight = 30, maxColumns = 4, gap = 6,
            slot = { size = "auto", minHeight = 30, hAlign = "fill" } })
        bossRuleToggle = RSUI:Button({ id = "v3_business_combat_boss_alerts_rule_toggle", parent = ruleActions,
            text = "关闭选中规则", compact = true, enabled = false, slot = { size = "fill", hAlign = "fill" },
            onClick = function()
                local row = FindSelectedBossRule(feature:GetProjection())
                if row == nil then return BossActionResult(false, "请先选择一条机制规则") end
                local ok, actionErr = feature.Commands:SetRuleEnabled(row.mechanicKey, row.enabled ~= true)
                return BossActionResult(ok, actionErr, "规则设置已保存并回读")
            end })
        bossRuleTest = RSUI:Button({ id = "v3_business_combat_boss_alerts_rule_test", parent = ruleActions,
            text = "测试选中规则", compact = true, enabled = false, slot = { size = "fill", hAlign = "fill" },
            onClick = function()
                local row = FindSelectedBossRule(feature:GetProjection())
                if row == nil then return BossActionResult(false, "请先选择一条机制规则") end
                local ok, actionErr = feature.Commands:TestRule(row.mechanicKey)
                return BossActionResult(ok, actionErr, "选中规则已触发（手动测试，不是实时命中）")
            end })
        local function BulkButton(suffix, text, enabled)
            return RSUI:Button({ id = "v3_business_combat_boss_alerts_" .. suffix, parent = ruleActions,
                text = text, compact = true, slot = { size = "fill", hAlign = "fill" },
                onClick = function()
                    local ok, actionErr = feature.Commands:SetAllRulesEnabled(enabled)
                    return BossActionResult(ok, actionErr, "全部规则设置已保存并回读")
                end })
        end
        bossRulesOn = BulkButton("rules_on", "全部启用", true)
        bossRulesOff = BulkButton("rules_off", "全部关闭", false)
        bossRuleSummary = RSUI:Text({ id = "v3_business_combat_boss_alerts_rule_summary", parent = root,
            text = "请选择下方规则", fontSize = 9, tone = "muted", overflow = "wrap", maxLines = 2,
            slot = { size = "auto", minHeight = 20, hAlign = "fill" } })
        bossTestStatus = RSUI:Text({ id = "v3_business_combat_boss_alerts_test_status", parent = root,
            text = "规则可独立启停；规则与未收录读条都关闭后停止观察。", fontSize = 9, tone = "muted", overflow = "wrap",
            slot = { size = "auto", minHeight = 20, hAlign = "fill" } })
        SyncBossControls = function(projection)
            local row = FindSelectedBossRule(projection)
            if row == nil then bossSelectedKey = nil end
            local enabledCount, total = tonumber(projection.enabledRuleCount) or 0, tonumber(projection.ruleCount) or 0
            bossRuleToggle:SetEnabled(row ~= nil)
            bossRuleToggle:SetText(row ~= nil and row.enabled ~= true and "启用选中规则" or "关闭选中规则")
            bossRuleTest:SetEnabled(row ~= nil and row.enabled == true and projection.hudEnabled == true and S.FeatureRuntime:IsEnabled(id) == true)
            bossRulesOn:SetEnabled(enabledCount < total)
            bossRulesOff:SetEnabled(enabledCount > 0)
            bossRuleSummary:SetText("已启用 " .. tostring(enabledCount) .. "/" .. tostring(total)
                .. (projection.realtime == true and " · 实时观察已启动" or " · 实时观察已停止")
                .. (row ~= nil and (" · 已选：" .. tostring(row.name)) or " · 请选择下方规则"))
        end
    elseif id == "combat_unit_lines" then
        local pairSpecs = {
            { key="target", label="当前目标", field="showTarget" },
            { key="targettarget", label="目标的目标", field="showTargetTarget" },
            { key="focus", label="焦点目标", field="showFocusTarget" },
            { key="focustarget", label="焦点的目标", field="showFocusTargetTarget" },
        }
        -- 可见文字必须使用 RU 字体已确认支持的字形；部分客户端缺少箭头/勾选字形，会在卡片标题和开关标签中留下空隙。
        local pairNames = {
            target = "自己 与 当前目标", targettarget = "当前目标 与 目标的目标",
            focus = "自己 与 焦点目标", focustarget = "焦点目标 与 焦点的目标",
        }
        local UNIT_LINE_PALETTE = {
            target = { 1.00, 0.72, 0.12 }, targettarget = { 0.94, 0.42, 0.20 },
            focus = { 0.35, 0.82, 1.00 }, focustarget = { 0.67, 0.52, 1.00 },
        }

        -- 每个数值仍需滑块、精确输入和应用按钮；范围和 Binding 统一交给 NumericField。
        local visibilitySection, visibilityErr = D:SettingsSection(root, {
            id = "v3_business_combat_unit_lines_visibility", title = "显示哪些连线",
            headerHeight = 20, gap = 3, itemGap = 3,
            slot = { size = "auto", hAlign = "fill" },
        })
        if visibilitySection == nil then return nil, visibilityErr end
        local pairGrid, pairGridErr = D:SettingsToggleGrid(visibilitySection.content, {
            id = "v3_business_combat_unit_lines_visibility_grid", compact = true, toggleWidth = 142,
            minCellWidth = 150, minCellHeight = 26, maxColumns = 4, gap = 6,
            slot = { size = "auto", hAlign = "fill" },
        })
        if pairGrid == nil then return nil, pairGridErr end
        for _, spec in ipairs(pairSpecs) do
            local specRef = spec
            TrackField(pairGrid:AddToggle({
                id = "v3_business_combat_unit_lines_pair_" .. specRef.key,
                onText = specRef.label .. "：开", offText = specRef.label .. "：关",
                get = function() return (feature:GetProjection() or {})[specRef.field] ~= false end,
                set = function(v)
                    local ok, e = feature.Commands:SetPairEnabled(specRef.key, v == true)
                    if ok then feature.Commands:Refresh("pair_toggle") end
                    return ok, e
                end,
            }))
        end

        local globalSection, globalErr = D:SettingsSection(root, {
            id = "v3_business_combat_unit_lines_global", title = "全局显示",
            headerHeight = 20, gap = 4, itemGap = 4,
            slot = { size = "auto", hAlign = "fill" },
        })
        if globalSection == nil then return nil, globalErr end
        RSUI:Text({ id = "v3_business_combat_unit_lines_global_hint", parent = globalSection.content,
            text = "默认密度和默认点大小用于缺省回退；透明度与刷新间隔对全部连线生效。",
            fontSize = 9, tone = "muted", overflow = "wrap", maxLines = 1,
            slot = { size = "auto", hAlign = "fill" } })
        local globalGrid = RSUI:UniformGrid({ id = "v3_business_combat_unit_lines_global_grid", parent = globalSection.content,
            minCellWidth = 300, minCellHeight = 30, maxColumns = 2, gap = 6,
            slot = { size = "auto", hAlign = "fill" } })
        if globalGrid == nil then return nil, "unit_line_global_grid_failed" end
        TrackField(D:SettingsNumericSlider(globalGrid, {
            id = "v3_business_combat_unit_lines_points", label = "默认密度", min = 8, max = 48, hardMin = UNIT_DENSITY_HARD_MIN, hardMax = UNIT_DENSITY_HARD_MAX,
            -- 8..48 只是推荐起始窗口；精确输入被 Domain 接受后 Slider 自动向外扩展。
            step = 1, integer = true, labelWidth = 68, inputWidth = 54, applyButtonWidth = 38,
            controlHeight = 22, minHeight = 30, stackBelow = 274, sliderMinWidth = 74, sliderPreferredShare = 0.44,
            get = function() return (feature:GetProjection() or {}).pointCount or 24 end,
            set = function(v) return feature.Commands:SetPointCount(v) end,
            slot = { size = "fill", fill = 1, hAlign = "fill" },
        }))
        TrackField(D:SettingsNumericSlider(globalGrid, {
            id = "v3_business_combat_unit_lines_size", label = "默认点大小", min = 2, max = 10, hardMin = 2, hardMax = 24,
            step = 1, integer = true, labelWidth = 68, inputWidth = 54, applyButtonWidth = 38,
            controlHeight = 22, minHeight = 30, stackBelow = 274, sliderMinWidth = 74, sliderPreferredShare = 0.44,
            get = function() return (feature:GetProjection() or {}).pointSize or 4 end,
            set = function(v) return feature.Commands:SetPointSize(v) end,
            slot = { size = "fill", fill = 1, hAlign = "fill" },
        }))
        TrackField(D:SettingsNumericSlider(globalGrid, {
            id = "v3_business_combat_unit_lines_opacity", label = "整体透明度", min = 0.1, max = 1, hardMin = 0.1, hardMax = 1,
            fixedRange = true, step = 0.05, integer = false, labelWidth = 68, inputWidth = 54, applyButtonWidth = 38,
            controlHeight = 22, minHeight = 30, stackBelow = 274, sliderMinWidth = 74, sliderPreferredShare = 0.44,
            get = function() return (feature:GetProjection() or {}).opacity or 0.78 end,
            set = function(v) return feature.Commands:SetOpacity(v) end,
            slot = { size = "fill", fill = 1, hAlign = "fill" },
        }))
        TrackField(D:SettingsNumericSlider(globalGrid, {
            -- 视觉常用范围1～100ms，步长1；精确输入仍允许原技术上限，不破坏已有慢速配置。
            id = "v3_business_combat_unit_lines_refresh", label = "绘制间隔(ms)", min = 1, max = 100, fixedSliderRange = true, hardMin = REFRESH_HARD_MIN, hardMax = REFRESH_HARD_MAX, step = 1, integer = true, unit = "", labelWidth = 68, inputWidth = 58, applyButtonWidth = 38,
            controlHeight = 22, minHeight = 30, stackBelow = 274, sliderMinWidth = 74, sliderPreferredShare = 0.44,
            get = function() return (feature:GetProjection() or {}).refreshMs or 100 end,
            set = function(v) return feature.Commands:SetRefreshMs(v) end,
            slot = { size = "fill", fill = 1, hAlign = "fill" },
        }))
        RSUI:Text({ id = "v3_business_combat_unit_lines_density_hint", parent = globalSection.content,
            text = "精确输入可扩展滑块范围；远距离自动补点，性能压力只削减额外补点。",
            fontSize = 9, tone = "muted", overflow = "wrap", maxLines = 1,
            slot = { size = "auto", hAlign = "fill" } })

        local styleSection, styleErr = D:SettingsSection(root, {
            id = "v3_business_combat_unit_lines_styles", title = "每条连线样式",
            headerHeight = 20, gap = 4, itemGap = 4,
            slot = { size = "auto", hAlign = "fill" },
        })
        if styleSection == nil then return nil, styleErr end
        local appearanceGrid, appearanceErr = D:SettingsStyleCardGrid(styleSection.content, {
            id = "v3_business_combat_unit_lines_style_grid", minCellWidth = 300, minCellHeight = 116, maxColumns = 2, gap = 6,
            slot = { size = "auto", hAlign = "fill" },
        })
        if appearanceGrid == nil then return nil, appearanceErr end
        for _, spec in ipairs(pairSpecs) do
            local specRef = spec
            local pairKey = specRef.key
            local card, cardErr = D:SettingsStyleCard(appearanceGrid, {
                id = "v3_business_combat_unit_lines_card_" .. pairKey,
                title = tostring(pairNames[pairKey] or pairKey), headerHeight = 20, padding = 5, gap = 3, itemGap = 3,
                slot = { size = "auto", minHeight = 116, hAlign = "fill" },
            })
            if card == nil then return nil, cardErr end
            TrackField(D:SettingsNumericSlider(card.content, {
                id = "v3_business_combat_unit_lines_pair_" .. pairKey .. "_points",
                label = "密度", min = 8, max = 48, hardMin = UNIT_DENSITY_HARD_MIN, hardMax = UNIT_DENSITY_HARD_MAX,
                step = 1, integer = true, labelWidth = 42, inputWidth = 50, applyButtonWidth = 36,
                controlHeight = 22, minHeight = 28, stackBelow = 286, sliderMinWidth = 72, sliderPreferredShare = 0.48,
                get = function()
                    local projection = feature:GetProjection() or {}
                    return projection.pairPoints and projection.pairPoints[pairKey] or projection.pointCount or 24
                end,
                set = function(v) return feature.Commands:SetPairPoints(pairKey, v) end,
                slot = { size = "auto", minHeight = 28, hAlign = "fill" },
            }))
            TrackField(D:SettingsNumericSlider(card.content, {
                id = "v3_business_combat_unit_lines_pair_" .. pairKey .. "_size",
                label = "点大小", min = 2, max = 10, hardMin = 2, hardMax = 24,
                step = 1, integer = true, labelWidth = 42, inputWidth = 50, applyButtonWidth = 36,
                controlHeight = 22, minHeight = 28, stackBelow = 286, sliderMinWidth = 72, sliderPreferredShare = 0.48,
                get = function()
                    local projection = feature:GetProjection() or {}
                    return projection.pairSizes and projection.pairSizes[pairKey] or projection.pointSize or 4
                end,
                set = function(v) return feature.Commands:SetPairSize(pairKey, v) end,
                slot = { size = "auto", minHeight = 28, hAlign = "fill" },
            }))
            local defaultColor = UNIT_LINE_PALETTE[pairKey] or { 1, 1, 1 }
            TrackField(RSUI:ColorField({ id = "v3_business_combat_unit_lines_pair_" .. pairKey .. "_color",
                parent = card.content, label = "颜色",
                defaultColor = { defaultColor[1], defaultColor[2], defaultColor[3] }, -- ColorField V2 的“恢复默认”必须由业务声明自己的权威默认色，禁止共享控件猜颜色。
                get = function()
                    local colors = (feature:GetProjection() or {}).colors
                    local c = type(colors) == "table" and colors[pairKey] or nil
                    return type(c) == "table"
                        and { tonumber(c[1]) or 1, tonumber(c[2]) or 1, tonumber(c[3]) or 1 }
                        or { defaultColor[1], defaultColor[2], defaultColor[3] }
                end,
                set = function(color) return feature.Commands:SetPairColor(pairKey, color[1], color[2], color[3]) end,
                slot = { size = "auto", minHeight = 24, hAlign = "fill" } }))
        end

        local diagnosticsErr
        unitLineDiagnostics, diagnosticsErr = D:SettingsDiagnostics(root, {
            id = "v3_business_combat_unit_lines_runtime", title = "高级 / 诊断", expanded = false,
            slot = { size = "auto", hAlign = "fill" },
        })
        if unitLineDiagnostics == nil then return nil, diagnosticsErr end
        unitLineDiagnosticsText = RSUI:Text({ id = "v3_business_combat_unit_lines_runtime_text", parent = unitLineDiagnostics.content,
            text = "等待运行时诊断。", fontSize = 9, tone = "muted", overflow = "wrap", maxLines = 4,
            slot = { size = "auto", minHeight = 20, hAlign = "fill" } })
        if unitLineDiagnosticsText == nil then return nil, "unit_line_diagnostics_text_failed" end
    elseif id == "combat_range_assist" then
        local function FindRangeCircle(circleId, projection)
            projection = type(projection) == "table" and projection or (feature:GetProjection() or {})
            local circles = type(projection.circles) == "table" and projection.circles or {}
            local wanted = math.floor(tonumber(circleId) or 0)
            if wanted <= 0 then return nil end
            for _, circle in ipairs(circles) do
                if math.floor(tonumber(circle.id) or 0) == wanted then return circle end
            end
            return nil
        end
        local rangeProjection = feature:GetProjection() or {}
        local circles = type(rangeProjection.circles) == "table" and rangeProjection.circles or {}
        if circles[1] ~= nil then rangeSelectedCircleId = tonumber(circles[1].id) end

        -- 范围绘制间隔独立于点数；保持几何预算，缺偏好仍用原自动节奏。
        TrackField(D:SettingsNumericSlider(root, {
            id="v3_business_range_refresh",label="绘制间隔(ms)",min=1,max=100,fixedSliderRange=true,hardMin=1,hardMax=60000,step=1,integer=true,unit="",
            get=function()return (feature:GetProjection() or {}).refreshMs or 16 end,
            set=function(value)return feature.Commands:SetRefreshMs(value)end,
            slot={size="fixed",height=42,hAlign="fill"},
        }))
        local listSection, listErr = D:SettingsSection(root, {
            id = "v3_business_combat_range_assist_list", title = "范围圆列表",
            -- 标题、分隔线、说明和动作行保留最小高度；使用 auto + minHeight，允许字体放大后增长。
            headerHeight = 20, gap = 4, itemGap = 4, slot = { size = "auto", minHeight = 92, hAlign = "fill" },
        })
        if listSection == nil then return nil, listErr end
        RSUI:Text({ id = "v3_business_combat_range_assist_intro", parent = listSection.content,
            text = "新增后直接在下方列表点击任意范围圆，再在编辑区修改或删除；每个圆独立保存参数。",
            fontSize = 9, tone = "muted", overflow = "wrap", maxLines = 2,
            slot = { size = "auto", minHeight = 26, hAlign = "fill" } })
        -- 新增后从投影取最后一个稳定 id 并选中，不重建 RSUI 子树。
        -- 这样连续新增时控件和 Native handler 不变，也不会重复消耗逻辑 ID。
        local listActions = RSUI:HorizontalBox({ id = "v3_business_combat_range_assist_circle_list_actions", parent = listSection.content,
            gap = 6, slot = { size = "fixed", height = 30, hAlign = "fill" } })
        local addCircle = RSUI:Button({ id = "v3_business_combat_range_assist_add", parent = listActions, text = "新增范围圆", compact = true,
            slot = { size = "fixed", width = 96 } })
        rangeSummaryText = RSUI:Text({ id = "v3_business_combat_range_assist_summary", parent = listActions,
            text = "已创建 " .. tostring(#circles) .. " 个范围圆", fontSize = 9, tone = "muted",
            slot = { size = "fill", hAlign = "fill" } })
        if addCircle == nil or rangeSummaryText == nil then return nil, "range_assist_actions_failed" end
        addCircle.onClick = function()
            local ok, addErr = feature.Commands:AddCircle()
            if ok == true then
                feature.Commands:Refresh("range_add_circle")
                local updated = feature:GetProjection() or {}
                local updatedCircles = type(updated.circles) == "table" and updated.circles or {}
                local lastCircle = updatedCircles[#updatedCircles]
                if lastCircle ~= nil then rangeSelectedCircleId = tonumber(lastCircle.id) end
                root:Refresh()
            end
            return ok, addErr
        end

        local editorSection, editorErr = D:SettingsSection(root, {
            id = "v3_business_combat_range_assist_editor", title = "选中范围圆编辑",
            -- 编辑区自然高度约 218px，保留 224px 下限，避免表格挤压颜色和状态行；大字体仍可增长。
            headerHeight = 20, gap = 5, itemGap = 5, slot = { size = "auto", minHeight = 224, hAlign = "fill" },
        })
        if editorSection == nil then return nil, editorErr end
        -- 标题和动作按钮各占一行，避免窄屏中挤压双列滑块。
        rangeEditorTitle = RSUI:Text({ id = "v3_business_combat_range_assist_editor_title", parent = editorSection.content,
            text = "当前未选择范围圆", fontSize = 10, tone = "strong", overflow = "ellipsis",
            slot = { size = "auto", minHeight = 18, hAlign = "fill" } })
        local editorActions = RSUI:HorizontalBox({ id = "v3_business_combat_range_assist_editor_actions", parent = editorSection.content,
            gap = 6, slot = { size = "fixed", height = 30, hAlign = "fill" } })
        local editorActionSpacer = RSUI:Text({ id = "v3_business_combat_range_assist_editor_actions_spacer", parent = editorActions,
            text = "", fontSize = 8, tone = "muted", slot = { size = "fill", fill = 1, hAlign = "fill" } })
        if editorActionSpacer == nil then return nil, "range_assist_editor_actions_spacer_failed" end
        TrackRangeEditorControl(RSUI:Toggle({ id = "v3_business_combat_range_assist_selected_enabled", parent = editorActions,
            onText = "显示：开", offText = "显示：关",
            get = function() local c = FindRangeCircle(rangeSelectedCircleId); return c ~= nil and c.enabled ~= false end,
            set = function(v)
                if rangeSelectedCircleId == nil then return false, "请先选择范围圆" end
                local ok, setErr = feature.Commands:SetCircleEnabled(rangeSelectedCircleId, v == true)
                if ok == true then feature.Commands:Refresh("range_circle_enabled") end
                return ok, setErr
            end,
            slot = { size = "fixed", width = 92 } }))
        rangeDeleteButton = RSUI:Button({ id = "v3_business_combat_range_assist_selected_remove", parent = editorActions,
            text = "删除选中圆", compact = true, slot = { size = "fixed", width = 86 } })
        if rangeEditorTitle == nil or rangeDeleteButton == nil then return nil, "range_assist_editor_actions_failed" end
        rangeDeleteButton.onClick = function()
            if rangeSelectedCircleId == nil then return false, "请先选择范围圆" end
            local ok, removeErr = feature.Commands:RemoveCircle(rangeSelectedCircleId)
            if ok == true then
                feature.Commands:Refresh("range_remove_circle")
                local updated = feature:GetProjection() or {}
                local remaining = type(updated.circles) == "table" and updated.circles or {}
                rangeSelectedCircleId = remaining[1] ~= nil and tonumber(remaining[1].id) or nil
                root:Refresh()
            end
            return ok, removeErr
        end

        -- 固定两行双列加一行颜色，避免 UniformGrid 重算高度时把控件压在一起。
        local editorRows = RSUI:VerticalBox({ id = "v3_business_combat_range_assist_editor_rows", parent = editorSection.content,
            gap = 5, slot = { size = "auto", hAlign = "fill" } })
        if editorRows == nil then return nil, "range_assist_editor_rows_failed" end
        local editorRow1 = RSUI:HorizontalBox({ id = "v3_business_combat_range_assist_editor_row_1", parent = editorRows,
            gap = 6, slot = { size = "fixed", height = 30, hAlign = "fill" } })
        local editorRow2 = RSUI:HorizontalBox({ id = "v3_business_combat_range_assist_editor_row_2", parent = editorRows,
            gap = 6, slot = { size = "fixed", height = 30, hAlign = "fill" } })
        local editorRow3 = RSUI:HorizontalBox({ id = "v3_business_combat_range_assist_editor_row_3", parent = editorRows,
            gap = 6, slot = { size = "fixed", height = 30, hAlign = "fill" } })
        if editorRow1 == nil or editorRow2 == nil or editorRow3 == nil then return nil, "range_assist_editor_rows_build_failed" end
        local sliderSlot = { size = "fill", fill = 1, minWidth = 280, hAlign = "fill" }
        TrackRangeEditorControl(D:SettingsNumericSlider(editorRow1, {
            id = "v3_business_combat_range_assist_selected_radius", label = "半径(米)", min = 1, max = 100, hardMin = RANGE_RADIUS_HARD_MIN, hardMax = RANGE_RADIUS_HARD_MAX, step = 0.5, integer = false, unit = "",
            labelWidth = 42, inputWidth = 56, applyButtonWidth = 36, controlHeight = 22, minHeight = 28, stackBelow = 240, sliderMinWidth = 72, sliderPreferredShare = 0.48,
            get = function() local c = FindRangeCircle(rangeSelectedCircleId); return c and c.radius or 10 end,
            set = function(v) if rangeSelectedCircleId == nil then return false, "请先选择范围圆" end; return feature.Commands:SetCircleRadius(rangeSelectedCircleId, v) end,
            slot = sliderSlot,
        }))
        TrackRangeEditorControl(D:SettingsNumericSlider(editorRow1, {
            id = "v3_business_combat_range_assist_selected_points", label = "密度", min = 12, max = 48, hardMin = RANGE_DENSITY_HARD_MIN, hardMax = RANGE_DENSITY_HARD_MAX, step = 1, integer = true,
            labelWidth = 42, inputWidth = 56, applyButtonWidth = 36, controlHeight = 22, minHeight = 28, stackBelow = 240, sliderMinWidth = 72, sliderPreferredShare = 0.48,
            get = function() local c = FindRangeCircle(rangeSelectedCircleId); return c and c.pointCount or 24 end,
            set = function(v) if rangeSelectedCircleId == nil then return false, "请先选择范围圆" end; return feature.Commands:SetCirclePointCount(rangeSelectedCircleId, v) end,
            slot = sliderSlot,
        }))
        TrackRangeEditorControl(D:SettingsNumericSlider(editorRow2, {
            id = "v3_business_combat_range_assist_selected_size", label = "点大小", min = 2, max = 10, hardMin = 2, hardMax = 24, step = 1, integer = true,
            labelWidth = 42, inputWidth = 56, applyButtonWidth = 36, controlHeight = 22, minHeight = 28, stackBelow = 240, sliderMinWidth = 72, sliderPreferredShare = 0.48,
            get = function() local c = FindRangeCircle(rangeSelectedCircleId); return c and c.pointSize or 4 end,
            set = function(v) if rangeSelectedCircleId == nil then return false, "请先选择范围圆" end; return feature.Commands:SetCirclePointSize(rangeSelectedCircleId, v) end,
            slot = sliderSlot,
        }))
        TrackRangeEditorControl(D:SettingsNumericSlider(editorRow2, {
            id = "v3_business_combat_range_assist_selected_opacity", label = "透明度", min = 0.1, max = 1, hardMin = 0.1, hardMax = 1, fixedRange = true, step = 0.05, integer = false,
            labelWidth = 42, inputWidth = 56, applyButtonWidth = 36, controlHeight = 22, minHeight = 28, stackBelow = 240, sliderMinWidth = 72, sliderPreferredShare = 0.48,
            get = function() local c = FindRangeCircle(rangeSelectedCircleId); return c and c.opacity or 0.68 end,
            set = function(v) if rangeSelectedCircleId == nil then return false, "请先选择范围圆" end; return feature.Commands:SetCircleOpacity(rangeSelectedCircleId, v) end,
            slot = sliderSlot,
        }))
        TrackRangeEditorControl(RSUI:ColorField({ id = "v3_business_combat_range_assist_selected_color", parent = editorRow3, label = "颜色",
            defaultColor = { 0.20, 0.82, 1.00 },
            get = function()
                local c = FindRangeCircle(rangeSelectedCircleId)
                return (type(c) == "table" and type(c.color) == "table") and { c.color[1], c.color[2], c.color[3] } or { 0.20, 0.82, 1.00 }
            end,
            set = function(color)
                if rangeSelectedCircleId == nil then return false, "请先选择范围圆" end
                return feature.Commands:SetCircleColor(rangeSelectedCircleId, color[1], color[2], color[3])
            end,
            slot = { size = "fill", fill = 1, hAlign = "fill" } }))
        rangeEditorStatus = RSUI:Text({ id = "v3_business_combat_range_assist_editor_status", parent = editorSection.content,
            text = "请从下方列表选择一个范围圆。", fontSize = 9, tone = "muted", overflow = "wrap", maxLines = 2,
            slot = { size = "auto", minHeight = 24, hAlign = "fill" } })
        if rangeEditorStatus == nil then return nil, "range_assist_editor_status_failed" end

        SyncRangeCircleEditor = function(projection, renderControls)
            projection = type(projection) == "table" and projection or (feature:GetProjection() or {})
            local projectionCircles = type(projection.circles) == "table" and projection.circles or {}
            local selected = FindRangeCircle(rangeSelectedCircleId, projection)
            if selected == nil and projectionCircles[1] ~= nil then
                rangeSelectedCircleId = tonumber(projectionCircles[1].id)
                selected = FindRangeCircle(rangeSelectedCircleId, projection)
            end
            if rangeSummaryText ~= nil then
                rangeSummaryText:SetText("已创建 " .. tostring(#projectionCircles) .. " 个范围圆 · 点击下方列表选择")
            end
            local hasSelection = selected ~= nil
            if rangeEditorTitle ~= nil then
                rangeEditorTitle:SetText(hasSelection and ("当前编辑：" .. tostring(selected.name or "范围圆") .. " · #" .. tostring(rangeSelectedCircleId)) or "当前未选择范围圆")
            end
            if rangeEditorStatus ~= nil then
                rangeEditorStatus:SetText(hasSelection
                    and string.format("ID %d · 半径 %.1fm · 密度 %d · 点大小 %d · 透明度 %d%%；所有修改只作用于当前选中圆。",
                        math.floor(tonumber(rangeSelectedCircleId) or 0), tonumber(selected.radius) or 10, math.floor(tonumber(selected.pointCount) or 24),
                        math.floor(tonumber(selected.pointSize) or 4), math.floor((tonumber(selected.opacity) or 0.68) * 100 + 0.5))
                    or "当前没有范围圆。点击“新增范围圆”后会自动选中新圆。")
            end
            if rangeDeleteButton ~= nil and type(rangeDeleteButton.SetEnabled) == "function" then rangeDeleteButton:SetEnabled(hasSelection) end
            for _, control in ipairs(rangeEditorControls) do
                if type(control.SetEnabled) == "function" then control:SetEnabled(hasSelection) end
                if renderControls == true and type(control.Render) == "function" then control:Render() end
            end
            return hasSelection
        end
        SyncRangeCircleEditor(rangeProjection, true)
    end
    local auctionKeywordInput, auctionStatus, auctionPage = nil, nil, 1
    local auctionPageSize, auctionSelectedKeyword = 10, nil
    local auctionQuoteRow, auctionRemoveArm = nil, nil
    local auctionQuoteButton, auctionRemoveButton = nil, nil
    local auctionExactField, auctionLimitField = nil, nil
    local auctionSidecarStatus, auctionSidecarDetail, auctionSidecarShowButton, auctionSidecarEnabledToggle = nil, nil, nil, nil
    local SyncAuctionSidecarControls = nil
    if id == "tools_auction" then
        -- 主页面提供拍卖助手的收藏、今日任务和临时清单入口，手动关闭后可在此恢复。
        -- 显隐状态读 AuctionSidecar:GetControlState()，显示只调 RequestShow；Controller 管窗口生命周期。
        -- sidecarEnabled 缺省 true，关闭只停止助手观察，不删除收藏。
        -- 按钮状态依赖 ControlTopic，新增隐藏路径也须发布此事件。
        local sidecarCard, sidecarCardErr = D:SettingsStyleCard(root, {
            id = "v3_business_tools_auction_sidecar_card", title = "拍卖助手",
            description = "可独立开启或关闭悬浮助手；开启后打开游戏拍卖行时会自动显示在旁边。",
            variant = "soft", accentStrip = true, minHeight = 132, gap = 5, itemGap = 4,
            slot = { size = "auto", minHeight = 132, hAlign = "fill" },
        })
        if sidecarCard == nil then return nil, sidecarCardErr or "auction_sidecar_card_failed" end
        local stateRow = RSUI:HorizontalBox({ id = "v3_business_tools_auction_sidecar_state_row", parent = sidecarCard.content, gap = 6,
            slot = { size = "fixed", height = 30, hAlign = "fill" } })
        auctionSidecarEnabledToggle = TrackField(RSUI:Toggle({ id = "v3_business_tools_auction_sidecar_enabled", parent = stateRow,
            onText = "悬浮助手：开", offText = "悬浮助手：关",
            get = function() return type(feature.IsSidecarEnabled) ~= "function" or feature:IsSidecarEnabled() == true end,
            set = function(value)
                if type(feature.Commands.SetSidecarEnabled) ~= "function" then return false, "悬浮助手设置命令不可用" end
                local ok, setErr = feature.Commands:SetSidecarEnabled(value == true)
                if SyncAuctionSidecarControls ~= nil then SyncAuctionSidecarControls() end
                return ok, setErr
            end,
            slot = { size = "fixed", width = 126 } }))
        auctionSidecarStatus = RSUI:Text({ id = "v3_business_tools_auction_sidecar_status", parent = stateRow,
            text = "拍卖行：等待状态", fontSize = 10, tone = "strong", overflow = "ellipsis",
            slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "center" } })
        auctionSidecarShowButton = RSUI:Button({ id = "v3_business_tools_auction_sidecar_show", parent = stateRow,
            text = "显示拍卖助手", compact = true, enabled = false, slot = { size = "fixed", width = 116 } })
        auctionSidecarDetail = RSUI:Text({ id = "v3_business_tools_auction_sidecar_detail", parent = sidecarCard.content,
            text = "收藏：保存常用物品并快速查询｜今日任务：整理居民做货材料｜临时清单：从跑商详情或手工加入本次采购材料。",
            fontSize = 9, tone = "muted", overflow = "wrap", maxLines = 3,
            slot = { size = "auto", minHeight = 34, hAlign = "fill" } })
        RSUI:Text({ id = "v3_business_tools_auction_sidecar_shared_hint", parent = sidecarCard.content,
            text = "主页面与悬浮助手共用同一份收藏数据；关闭悬浮助手不会删除收藏。", fontSize = 8, tone = "muted", overflow = "wrap", maxLines = 2,
            slot = { size = "auto", minHeight = 18, hAlign = "fill" } })

        SyncAuctionSidecarControls = function()
            local controller = S.UIV3 and S.UIV3.AuctionSidecar or nil
            local featureEnabled = S.FeatureRuntime:IsEnabled(id) == true
            if type(controller) ~= "table" or type(controller.GetControlState) ~= "function" then
                auctionSidecarStatus:SetText("拍卖助手：控制器不可用")
                auctionSidecarDetail:SetText("主页面收藏与查询仍可使用；悬浮助手当前无法读取状态。")
                auctionSidecarShowButton:SetText("助手不可用")
                auctionSidecarShowButton:SetEnabled(false)
                return false
            end
            local state = controller:GetControlState() or {}
            if auctionSidecarEnabledToggle ~= nil and type(auctionSidecarEnabledToggle.SetEnabled) == "function" then
                auctionSidecarEnabledToggle:SetEnabled(featureEnabled == true)
            end
            if featureEnabled ~= true then
                auctionSidecarStatus:SetText("拍卖助手：功能已关闭")
                auctionSidecarDetail:SetText(state.enabled == false
                    and "拍卖收藏功能当前关闭，悬浮助手偏好也为关闭；收藏数据仍会保留。"
                    or "先启用拍卖收藏功能；悬浮助手已开启时，打开游戏拍卖行会自动出现。")
                auctionSidecarShowButton:SetText("功能已关闭")
                auctionSidecarShowButton:SetEnabled(false)
            elseif state.enabled ~= true then
                auctionSidecarStatus:SetText("悬浮助手：已关闭")
                auctionSidecarDetail:SetText("已关闭自动悬浮窗口；以后打开拍卖行不会弹出助手。主页面收藏、查询以及已有收藏数据不受影响。")
                auctionSidecarShowButton:SetText("悬浮已关闭")
                auctionSidecarShowButton:SetEnabled(false)
            elseif state.nativeVisible ~= true then
                auctionSidecarStatus:SetText("拍卖行：未打开")
                auctionSidecarDetail:SetText("请先打开游戏拍卖行。打开后助手会自动显示；收藏、今日任务和临时清单都在助手内可直接使用。")
                auctionSidecarShowButton:SetText("显示拍卖助手")
                auctionSidecarShowButton:SetEnabled(false)
            elseif state.visible == true then
                auctionSidecarStatus:SetText("拍卖行：已打开 · 助手已显示")
                auctionSidecarDetail:SetText("助手正在拍卖行旁边显示；主页面与助手共享收藏，任一处修改都会使用同一份数据。")
                auctionSidecarShowButton:SetText("助手已显示")
                auctionSidecarShowButton:SetEnabled(false)
            else
                auctionSidecarStatus:SetText("拍卖行：已打开 · 助手已隐藏")
                auctionSidecarDetail:SetText("助手已被关闭；点击右侧按钮可在当前拍卖行会话中重新显示，不会改变收藏或临时清单。")
                auctionSidecarShowButton:SetText(state.dismissed == true and "重新显示助手" or "显示拍卖助手")
                auctionSidecarShowButton:SetEnabled(state.canShow == true)
            end
            return true
        end
        auctionSidecarShowButton.onClick = function()
            local controller = S.UIV3 and S.UIV3.AuctionSidecar or nil
            if type(controller) ~= "table" or type(controller.RequestShow) ~= "function" then
                if auctionSidecarDetail ~= nil then auctionSidecarDetail:SetText("拍卖助手控制器不可用；主页面收藏与查询仍可继续使用。") end
                return false, "拍卖助手控制器不可用"
            end
            local ok, showErr = controller:RequestShow("auction_main_page")
            if SyncAuctionSidecarControls ~= nil then SyncAuctionSidecarControls() end
            if ok ~= true and auctionSidecarDetail ~= nil then auctionSidecarDetail:SetText("显示失败：" .. tostring(showErr or "未执行")) end
            return ok, showErr
        end
        SyncAuctionSidecarControls()

        local auctionSection = RSUI:VerticalBox({ id = "v3_business_tools_auction_listing_section", parent = root, gap = 3,
            slot = { size = "auto", minHeight = 26, hAlign = "fill" } })
        RSUI:Text({ id = "v3_business_tools_auction_listing_title", parent = auctionSection, text = "收藏与当前挂单",
            fontSize = 12, tone = "accent", overflow = "ellipsis", slot = { size = "fixed", height = 21, hAlign = "fill" } })
        RSUI:Divider({ id = "v3_business_tools_auction_listing_divider", parent = auctionSection, soft = true,
            slot = { size = "fixed", height = 1, hAlign = "fill" } })
    end
    if id == "tools_auction" or id == "tools_market_analysis" then
        local row = RSUI:HorizontalBox({ id = "v3_business_" .. id .. "_auction_context", parent = root, gap = 6, slot = { size = "fixed", height = 31, hAlign = "fill" } })
        auctionKeywordInput = RSUI:TextInput({ id = "v3_business_" .. id .. "_auction_keyword", parent = row, value = "", maxLength = 64, allowEmpty = false, placeholder = "物品名称", slot = { size = "fill", fill = 1, minWidth = 160 } })
        local search = RSUI:Button({ id = "v3_business_" .. id .. "_auction_search", parent = row, text = "查询当前挂单", compact = true, slot = { size = "fixed", width = 96 } })
        local add = id == "tools_auction" and RSUI:Button({ id = "v3_business_tools_auction_add", parent = row, text = "加入收藏", compact = true, slot = { size = "fixed", width = 72 } }) or nil
        local quote = id == "tools_auction" and RSUI:Button({ id = "v3_business_tools_auction_quote", parent = row, text = "结果询价", compact = true, slot = { size = "fixed", width = 72 } }) or nil
        auctionQuoteButton = quote
        auctionStatus = RSUI:Text({ id = "v3_business_" .. id .. "_auction_status", parent = root,
            text = id == "tools_auction" and "输入物品名称查询当前挂单，也可加入收藏以便之后快速查看。" or "这里只展示当前拍卖挂单，不把搜索结果伪装成历史成交行情。",
            fontSize = 8, tone = "muted", overflow = "wrap", maxLines = 2, slot = { size = "auto", minHeight = 26, hAlign = "fill" } })
        local settingRow=RSUI:HorizontalBox({ id="v3_business_"..id.."_auction_settings",parent=root,gap=6,slot={size="fixed",height=31,hAlign="fill"} })
        auctionExactField=TrackField(RSUI:Toggle({ id="v3_business_"..id.."_auction_exact",parent=settingRow,onText="精确匹配：开",offText="精确匹配：关",
            get=function() return (feature:GetProjection() or {}).exactMatch==true end,set=function(v) return feature.Commands:SetExactMatch(v) end,slot={size="fixed",width=104} }))
        auctionLimitField=TrackField(D:CompactNumericSetting(settingRow,{ id="v3_business_"..id.."_auction_limit",label="结果数",min=5,max=30,step=5,integer=true,slider=true,
            get=function() return (feature:GetProjection() or {}).resultLimit or 20 end,set=function(v) return feature.Commands:SetResultLimit(v) end,slot={size="fill",fill=1,hAlign="fill"} }))
        local function keyword() return auctionKeywordInput and type(auctionKeywordInput.GetDraftValue)=="function" and tostring(auctionKeywordInput:GetDraftValue() or "") or "" end
        search.onClick=function()
            local ok,searchErr=feature.Commands:Search(keyword())
            auctionStatus:SetText(ok and "已发送查询，等待服务器返回……" or ("查询失败："..tostring(searchErr or "未执行")))
            root:Refresh(); return ok,searchErr
        end
        if add~=nil then add.onClick=function()
            local ok,addErr=feature.Commands:AddFavorite(keyword())
            auctionStatus:SetText(ok and "已加入收藏" or ("收藏失败："..tostring(addErr or "未执行")))
            if ok then feature.Commands:Refresh("auction_add_favorite"); root:Refresh() end
            return ok,addErr
        end end
        if quote~=nil then
            quote:SetEnabled(false)
            quote.onClick=function()
                if auctionQuoteRow==nil or auctionQuoteRow.itemType==nil then auctionStatus:SetText("请先在结果中选择一条带物品身份的行"); return false end
                local okQuote,quoteErr=feature.Commands:Quote(auctionQuoteRow.itemType,auctionQuoteRow.itemGrade)
                auctionStatus:SetText(okQuote and "已提交最低价询价，完成后自动刷新。" or ("询价失败："..tostring(quoteErr or "未执行")))
                return okQuote,quoteErr
            end
        end
        local pages=RSUI:HorizontalBox({ id="v3_business_"..id.."_auction_pages",parent=root,gap=6,slot={size="fixed",height=28,hAlign="fill"} })
        local prev=RSUI:Button({ id="v3_business_"..id.."_auction_prev",parent=pages,text="上一页",compact=true,slot={size="fixed",width=64} })
        local next=RSUI:Button({ id="v3_business_"..id.."_auction_next",parent=pages,text="下一页",compact=true,slot={size="fixed",width=64} })
        local remove=id=="tools_auction" and RSUI:Button({ id="v3_business_tools_auction_remove",parent=pages,text="删除收藏",compact=true,slot={size="fixed",width=76} }) or nil
        auctionRemoveButton = remove
        local pageText=RSUI:Text({ id="v3_business_"..id.."_auction_page_text",parent=pages,text="第 1 页",fontSize=8,tone="muted",slot={size="fill",hAlign="fill"} })
        prev.onClick=function() auctionPage=math.max(1,auctionPage-1); root:Refresh(); return true end
        next.onClick=function() auctionPage=auctionPage+1; root:Refresh(); return true end
        if remove~=nil then remove.onClick=function()
            if auctionSelectedKeyword==nil then auctionRemoveArm=nil; remove:SetText("删除收藏"); auctionStatus:SetText("请先选择一条收藏关键词"); return false end
            -- 收藏删除不可恢复，必须点击两次确认，防止误触立即删除且无法撤销。
            if auctionRemoveArm~=auctionSelectedKeyword then
                auctionRemoveArm=auctionSelectedKeyword
                remove:SetText("确认删除?")
                auctionStatus:SetText("再点一次“确认删除?”才会删除该收藏。")
                return true
            end
            auctionRemoveArm=nil; remove:SetText("删除收藏")
            local ok,removeErr=feature.Commands:RemoveFavoriteByKeyword(auctionSelectedKeyword)
            if ok then auctionSelectedKeyword=nil; feature.Commands:Refresh("auction_remove"); root:Refresh() else auctionStatus:SetText("删除失败："..tostring(removeErr or "未执行")) end
            return ok,removeErr
        end end
        root.RefreshAuctionPaging=function(self,projection,tableView)
            local source=type(projection.rows)=="table" and projection.rows or {}; local total=#source
            local pagesCount=math.max(1,math.ceil(total/auctionPageSize)); auctionPage=math.min(auctionPage,pagesCount)
            local first=(auctionPage-1)*auctionPageSize+1; local pageRows={}
            for i=first,math.min(first+auctionPageSize-1,total) do pageRows[#pageRows+1]=source[i] end
            -- 分页改变可见切片，不推进业务 revision；加入页码后才能让 Native 池重绑到当前行。
            local pageChanged=self.auctionDisplayedPage~=auctionPage
            if pageChanged then tableView:ClearSelection() end
            tableView:SetItems(pageRows,"auction:"..tostring(projection.revision or 0)..":page:"..auctionPage)
            if pageChanged then tableView:ScrollToTop() end
            self.auctionDisplayedPage=auctionPage
            -- 当前页删除/重排也会移动索引；选择不存在时清空，存在时只更新动作绑定，不覆盖用户输入草稿。
            if tableView:GetSelectedKey()~=nil and SelectedAuctionRow(tableView)==nil then tableView:ClearSelection() end
            if self.SyncAuctionSelection then self:SyncAuctionSelection(false) end
            pageText:SetText("第 "..tostring(auctionPage).."/"..tostring(pagesCount).." 页 · 当前 "..tostring(total).." 条"..(id=="tools_auction" and (" · 收藏 "..tostring(projection.favoriteCount or 0)) or ""))
            prev:SetEnabled(auctionPage>1); next:SetEnabled(auctionPage<pagesCount)
        end
    end
    -- 日常制作流程在小窗完成，本页只放低频设置与窗口恢复。
    if id == "tools_craft" then
        if S.UIV3 == nil or type(S.UIV3.CreateCraftAdvancedSettings) ~= "function" then return nil, "配方高级设置不可用" end
        local editor, editorErr = S.UIV3.CreateCraftAdvancedSettings(root, feature)
        if editor == nil then return nil, editorErr or "配方高级设置创建失败" end
        root.craftPlanEditor = editor
        if type(feature.Commands.SetScreenButtonVisible) == "function" then
            local sidecarRow = RSUI:HorizontalBox({ id = "v3_business_tools_craft_sidecar_row", parent = root, gap = 6,
                slot = { size = "fixed", height = 31, hAlign = "fill" } })
            TrackField(RSUI:Toggle({ id = "v3_business_tools_craft_screen_button", parent = sidecarRow,
                onText = "屏幕配方按钮：显示", offText = "屏幕配方按钮：隐藏",
                get = function() return feature:GetScreenButtonState().visible end,
                set = function(value) return feature.Commands:SetScreenButtonVisible(value == true) end,
                slot = { size = "fixed", width = 160 } }))
            RSUI:Button({id='v3_business_tools_craft_reset_button',parent=sidecarRow,text='恢复按钮',compact=true,
                slot={size='fixed',width=76},onClick=function()return feature.Commands:ResetScreenButtonPosition()end})
            RSUI:Button({id='v3_business_tools_craft_reset_window',parent=sidecarRow,text='恢复小窗',compact=true,
                slot={size='fixed',width=76},onClick=function()
                    local controller=S.UIV3.CraftSidecar
                    if not controller or type(controller.ResetPosition)~='function' then return false,'配方小窗位置恢复不可用' end
                    return controller:ResetPosition()
                end})
            RSUI:Text({ id = "v3_business_tools_craft_sidecar_hint", parent = sidecarRow,
                text = "屏幕按钮点击打开小窗，左侧把手可拖动。O 自动入口当前不可用。", fontSize = 8, tone = "muted", overflow = "wrap", maxLines = 2,
                slot = { size = "fill", fill = 1 } })
        end
    end
    local bagQuickStatus,blacklistStatus,blacklistToggle,itemInput,BuildBagSettingsRows
    if id=="tools_bag" then
        -- 与背包悬浮设置保持相同交互：取放仍走原Commands，黑名单在下方逐行加入/移出。
        local quickRow=RSUI:HorizontalBox({id="v3_business_tools_bag_quick_row",parent=root,gap=5,slot={size="fixed",height=30,hAlign="fill"}})
        local function Quick(command)
            local fn=feature.Commands[command];if type(fn)~="function" then return false,"快捷取放命令不可用"end
            local ok,result=fn(feature.Commands);root:Refresh()
            if ok~=true then bagQuickStatus:SetText("操作失败："..tostring(result or "未执行"))end
            return ok,result
        end
        local take=RSUI:Button({id="v3_business_tools_bag_quick_take",parent=quickRow,text="取出同类",compact=true,slot={size="fixed",width=80}})
        local put=RSUI:Button({id="v3_business_tools_bag_quick_put",parent=quickRow,text="存入同类",compact=true,slot={size="fixed",width=80}})
        local all=RSUI:Button({id="v3_business_tools_bag_quick_all_put",parent=quickRow,text="全放",compact=true,slot={size="fixed",width=54}})
        take.onClick=function()return Quick("QuickWithdraw")end
        put.onClick=function()return Quick("QuickDeposit")end
        all.onClick=function()return Quick("QuickDepositAll")end
        if S.Tooltip and type(S.Tooltip.Bind)=="function" then
            S.Tooltip:Bind(all,{text="尝试存入所有非黑名单物品；运行中再点同一动作停止。",cursorFollow=true,maxWidth=320})
        end
        local reset=RSUI:Button({id="v3_business_tools_bag_reset_position",parent=quickRow,text="重置悬浮栏位置",compact=true,slot={size="fixed",width=114}})
        reset.onClick=function()
            local bar=S.UIV3 and S.UIV3.BagQuickOverlay
            if type(bar)~="table" or type(bar.ResetPosition)~="function" then return false,"悬浮栏不可用"end
            local ok,err=bar:ResetPosition();bagQuickStatus:SetText(ok and "悬浮栏位置已重置。" or "重置失败："..tostring(err or "未保存"));return ok,err
        end
        bagQuickStatus=RSUI:Text({id="v3_business_tools_bag_quick_status",parent=root,text="请先打开银行或保管箱。",fontSize=9,tone="muted",
            overflow="wrap",maxLines=2,slot={size="fixed",height=24,hAlign="fill"}})
    end
    local socialInput, socialStatus = nil, nil
    if id == "tools_social" then
        local socialRow = RSUI:HorizontalBox({ id = "v3_business_tools_social_member_actions", parent = root, gap = 6,
            slot = { size = "fixed", height = 31, hAlign = "fill" } })
        socialInput = RSUI:TextInput({ id = "v3_business_tools_social_name", parent = socialRow, value = "", maxLength = 48,
            allowEmpty = false, submitOnLostFocus = false, placeholder = "角色名", slot = { size = "fixed", width = 150 } })
        socialStatus = RSUI:Text({ id = "v3_business_tools_social_status", parent = root, text = "输入角色名（或点击下方列表行载入）后执行显式名单操作；写操作遵守官方 1 秒冷却。",
            fontSize = 8, tone = "muted", overflow = "wrap", maxLines = 2, slot = { size = "auto", minHeight = 24, hAlign = "fill" } })
        local actions = {
            { command = "Block", text = "屏蔽" }, { command = "Unblock", text = "取消屏蔽" },
            { command = "Mute", text = "静音" }, { command = "Unmute", text = "取消静音" },
            { command = "IsFriend", text = "查好友", holdRefresh = true },
        }
        local function SocialName()
            local name = socialInput and type(socialInput.GetDraftValue) == "function" and tostring(socialInput:GetDraftValue() or "") or ""
            name = name:match("^%s*(.-)%s*$") or ""
            if name == "" or #name > 48 or name:find("[%c]") then return nil, "角色名必须是 1-48 个可见字符" end
            return name
        end
        for index, action in ipairs(actions) do
            -- Lua 5.1 的 generic-for 控制变量会被闭包共享；捕获稳定局部变量，避免循环结束后所有按钮都执行最后一个 Unmute 命令。
            local commandRef, textRef, actionSpec = action.command, action.text, action
            local button = RSUI:Button({ id = "v3_business_tools_social_action_" .. tostring(index), parent = socialRow, text = textRef, compact = true, slot = { size = "fixed", width = 74 } })
            button.onClick = function()
                local name, nameErr = SocialName(); if name == nil then socialStatus:SetText("失败：" .. tostring(nameErr)); return false, nameErr end
                local command = feature.Commands[commandRef]
                if type(command) ~= "function" then socialStatus:SetText("失败：命令不可用"); return false, "命令不可用" end
                local ok, result = command(feature.Commands, name)
                if ok ~= true then
                    socialStatus:SetText("失败：" .. tostring(result or "未执行"))
                    return false, result
                end
                -- 查询命令（查好友）报告事实，
                -- 而非写入确认，也不会把权威状态标记为脏。
                socialStatus:SetText(textRef .. "：" .. tostring(result or "已执行"))
                if actionSpec.holdRefresh ~= true then feature.Commands:Refresh("social_" .. commandRef); root:Refresh() end
                return true, nil
            end
        end
    end

    local function SetBlacklistStatus(text,tone)
        root.blacklistFeedback=tostring(text or "")
        if blacklistStatus then blacklistStatus:SetText(root.blacklistFeedback);if type(blacklistStatus.SetTone)=="function" then blacklistStatus:SetTone(tone or "muted")end end
    end
    if id=="tools_bag" then
        root.bagSettingsView,root.bagSettingsFilter="bag",""
        -- 只筛选已有detached快照；不持有第二份黑名单、不在UI刷新或筛选中读取背包API。
        BuildBagSettingsRows=function(projection)
            local blocked,quantities,rows={}, {}, {}
            for _,entry in ipairs(projection.blacklistRows or {})do blocked[tostring(entry.itemType)]=true end
            for _,entry in ipairs(projection.bagItemRows or {})do quantities[tostring(entry.itemType)]=entry.stack end
            local query=tostring(root.bagSettingsFilter or ""):lower()
            local entries=root.bagSettingsView=="blacklist" and projection.blacklistRows or projection.bagItemRows
            for _,entry in ipairs(entries or {})do
                local itemType=tonumber(entry.itemType);local key=tostring(entry.itemType or "")
                local name=tostring(entry.itemName or entry.name or key)
                if query=="" or name:lower():find(query,1,true) or key:find(query,1,true) then
                    local inList=blocked[key]==true
                    rows[#rows+1]={key="bag_settings:"..key,itemType=itemType,name=name,quantity=quantities[key],blocked=inList,stateText=inList and "在名单" or "可整理"}
                end
            end
            return rows
        end
        local controls=RSUI:HorizontalBox({id="v3_business_tools_bag_settings_controls",parent=root,gap=5,slot={size="fixed",height=28,hAlign="fill"}})
        RSUI:SegmentedSelector({id="v3_business_tools_bag_settings_tabs",parent=controls,
            items={{value="bag",text="背包物品",width=76},{value="blacklist",text="黑名单",width=76}},maxItems=2,height=26,gap=3,
            get=function()return root.bagSettingsView end,set=function(value)
                if value~="bag" and value~="blacklist" then return false,"未知物品列表"end
                root.bagSettingsView=value;root.blacklistFeedback=nil;return root:Refresh()
            end,slot={size="fixed",width=155}})
        blacklistToggle=RSUI:Button({id="v3_business_tools_bag_blacklist_toggle",parent=controls,text="黑名单：开",compact=true,slot={size="fixed",width=94}})
        blacklistToggle.onClick=function()
            local p=feature:GetProjection() or {};local ok,err=feature.Commands:SetBlacklistEnabled((p.blacklist or {}).enabled~=true)
            if ok~=true then SetBlacklistStatus("保存失败："..tostring(err or "未提交"),"warn");return false,err end
            root:Refresh();SetBlacklistStatus((feature:GetProjection().blacklist or {}).enabled==true and "黑名单已开启。" or "黑名单已关闭，整理时不再排除名单物品。");return true
        end
        local search=RSUI:HorizontalBox({id="v3_business_tools_bag_settings_search",parent=root,gap=5,slot={size="fixed",height=28,hAlign="fill"}})
        itemInput=RSUI:TextInput({id="v3_business_tools_bag_blacklist_item_input",parent=search,value="",maxLength=96,commitMode="explicit",
            placeholder="筛选名称或 ID，也可输入添加",slot={size="fill",fill=1,minWidth=130}})
        local apply=RSUI:Button({id="v3_business_tools_bag_filter_apply",parent=search,text="筛选",compact=true,slot={size="fixed",width=48}})
        local clear=RSUI:Button({id="v3_business_tools_bag_filter_clear",parent=search,text="清除",compact=true,slot={size="fixed",width=48}})
        local add=RSUI:Button({id="v3_business_tools_bag_blacklist_item_add",parent=search,text="输入添加",compact=true,slot={size="fixed",width=76}})
        apply.onClick=function()root.bagSettingsFilter=tostring(itemInput:GetDraftValue() or ""):match("^%s*(.-)%s*$");root.blacklistFeedback=nil;return root:Refresh()end
        clear.onClick=function()root.bagSettingsFilter="";itemInput:SetValue("",false,"bag_filter_clear");root.blacklistFeedback=nil;return root:Refresh()end
        add.onClick=function()
            local ok,err=feature.Commands:ResolveAndAddBlacklistItem(tostring(itemInput:GetDraftValue() or ""))
            if ok~=true then SetBlacklistStatus("添加失败："..tostring(err or "未提交"),"warn");return false,err end
            root:Refresh();SetBlacklistStatus("已保存到黑名单，对银行和箱子同时生效。");return true
        end
        blacklistStatus=RSUI:Text({id="v3_business_tools_bag_blacklist_status",parent=root,text="点击行内“加入 / 移出”配置黑名单。",fontSize=9,tone="muted",
            overflow="wrap",maxLines=2,slot={size="fixed",height=24,hAlign="fill"}})
        function root:ToggleBlacklistItem(row)
            if self.featureUpdatesBound~=true or S.FeatureRuntime:IsEnabled(id)~=true then return false,"请先启用整理背包并打开页面"end
            local itemType=tonumber(row and row.itemType)
            if not itemType or itemType<=0 then SetBlacklistStatus("物品 ID 尚未取得，请刷新背包。","warn");return false,"物品 ID 未知"end
            local ok,err
            if row.blocked==true then ok,err=feature.Commands:RemoveGlobalBlacklistItem(itemType)
            else ok,err=feature.Commands:AddGlobalBlacklistItem(itemType,row.name)end
            if ok~=true then SetBlacklistStatus("保存失败："..tostring(err or "未提交"),"warn");return false,err end
            self:Refresh();SetBlacklistStatus(row.blocked==true and "已移出黑名单。" or "已加入黑名单，对银行和箱子同时生效。");return true
        end
        function root:RefreshBlacklistEditor(projection)
            local config=type(projection.blacklist)=="table" and projection.blacklist or {}
            blacklistToggle:SetText(config.enabled==true and "黑名单：开" or "黑名单：关")
            if self.blacklistFeedback==nil then
                local legacy=math.max(0,tonumber(projection.blacklistLegacyCategoryCount) or 0)
                blacklistStatus:SetText("点击行内“加入 / 移出”；名单 "..tostring(#(projection.blacklistRows or {})).." 项，对银行和箱子生效。"
                    ..(legacy>0 and " 旧分类规则仍保留。" or ""))
            end
        end
    end
    local teamRoleInput, teamActionStatus, teamAutoRoleButton, teamExtra
    if id == "combat_team_tools" or id == "combat_sac_highlight" then
        -- PageHost 会保留同代多个页面，逻辑 ID 一经消耗不能重用。
        -- 控件按当前 Feature 分配命名空间，不能沿用旧聚合页前缀。
        local teamComponentPrefix = "v3_business_" .. id .. "_"
        teamActionStatus = RSUI:Text({ id = teamComponentPrefix .. "action_status", parent = root,
            text = "全队职责只读；职责写入只作用于当前玩家。成员移动因缺少合法队长权限读取契约继续安全停用。", fontSize = 8, tone = "muted", overflow = "wrap", maxLines = 2,
            slot = { size = "auto", minHeight = 24, hAlign = "fill" } }) -- 成员移动尚不可执行，只显示能力说明；Domain 命令仍负责拒绝不满足权限的请求。

        local function SetTeamActionStatus(text, tone)
            teamActionStatus:SetText(tostring(text or ""))
            if S.Theme ~= nil and type(S.Theme.SetLabelTone) == "function" then S.Theme:SetLabelTone(teamActionStatus, tone or "muted") end
        end
        local function RefreshTeamAction(reason)
            local commandCallOk, commandRefreshOk, commandRefreshErr = pcall(function() return feature.Commands:Refresh(reason) end)
            local rootCallOk, rootRefreshOk, rootRefreshErr = pcall(function() return root:Refresh() end)
            if commandCallOk ~= true or commandRefreshOk ~= true or rootCallOk ~= true or rootRefreshOk ~= true then
                local detail
                if commandCallOk ~= true then detail = "命令刷新异常：" .. tostring(commandRefreshOk)
                elseif commandRefreshOk ~= true then detail = "命令刷新返回：" .. tostring(commandRefreshErr or commandRefreshOk)
                elseif rootCallOk ~= true then detail = "页面刷新异常：" .. tostring(rootRefreshOk)
                else detail = "页面刷新返回：" .. tostring(rootRefreshErr or rootRefreshOk) end
                return false, "动作已执行，但投影刷新失败：" .. detail
            end
            return true
        end
        teamExtra = {}
        if id == "combat_team_tools" then
        -- 成员移动缺少合法队长权限 getter，Domain 会拒绝执行；恢复 UI 前须先解决权限校验。
        local roleGroup = RSUI:GroupBox({ id = teamComponentPrefix .. "role_group", parent = root, title = "职责设置", variant = "soft", gap = 5, padding = 8,
            slot = { size = "auto", hAlign = "fill" } }) -- 分组通过 RSUI Measure/Arrange 适配窗口；全队职责表只读，编辑区只放当前玩家可执行的设置。
        local roleInner = RSUI:VerticalBox({ id = teamComponentPrefix .. "role_inner", parent = roleGroup, gap = 5 })
        local roleRow = RSUI:HorizontalBox({ id = teamComponentPrefix .. "role_row", parent = roleInner, gap = 6,
            slot = { size = "fixed", height = 31, hAlign = "fill" } })
        RSUI:Text({ id = teamComponentPrefix .. "role_label", parent = roleRow, text = "我的职责", fontSize = 9, tone = "strong",
            overflow = "ellipsis", slot = { size = "fixed", width = 58 } })
        local roleProjection = feature:GetProjection() or {} -- 下拉选项只读取 Feature detached projection，不直接调用 X2Team；Native 读写仍集中在 TeamTools Domain。
        local roleItems = {}
        for _, item in ipairs(type(roleProjection.roleOptions) == "table" and roleProjection.roleOptions or {}) do
            roleItems[#roleItems + 1] = { value = item.value, text = tostring(item.text or item.key or item.value) }
        end
        local teamRoleValue = nil
        teamRoleInput = RSUI:Dropdown({ id = teamComponentPrefix .. "role_input", parent = roleRow, items = roleItems, maxVisible = 5,
            get = function() return teamRoleValue end, set = function(value) teamRoleValue = value; return true end,
            placeholder = #roleItems > 0 and "选择职责" or "职责不可用", slot = { size = "fixed", width = 126 } })
        local setRoleButton = RSUI:Button({ id = teamComponentPrefix .. "set_role", parent = roleRow, text = "设置我的职责", compact = true,
            slot = { size = "fixed", width = 96 } })
        teamAutoRoleButton = RSUI:Button({ id = teamComponentPrefix .. "auto_role", parent = roleRow, text = "自动职责：开", compact = true,
            slot = { size = "fixed", width = 108 } }) -- 初始文案与 Domain 新安装默认 true 对齐；Refresh 仍以 projection 为最终事实，旧用户保存 false 不会被 UI 初始文字反向写入。
        local roleStatus = RSUI:Text({ id = teamComponentPrefix .. "role_status", parent = roleInner,
            text = "自动职责默认开启；进入团队或职业组合变化后按已验证职业表匹配。", fontSize = 8, tone = "muted", overflow = "wrap", maxLines = 2,
            slot = { size = "auto", minHeight = 20, hAlign = "fill" } }) -- 这是只读说明/状态文本，不参与 Store，避免把运行时识别结果误写成永久配置。

        teamAutoRoleButton.onClick = function()
            local projection = feature:GetProjection() or {} -- 按钮切换以前一份 Feature projection 为事实，不使用本地按钮文案推断状态，避免 UI 与 Store 脱节。
            local nextValue = projection.autoRoleEnabled == false
            local ok, err = feature.Commands:SetAutoRoleEnabled(nextValue) -- 写入必须经过 TeamTools PersistStateMutation；Presentation 不直接改 State/SaveData。
            if ok ~= true then SetTeamActionStatus("自动职责设置失败：" .. tostring(err or "未执行"), "warn"); return false, err end
            root:Refresh()
            SetTeamActionStatus(nextValue and "自动职责已开启；进团或切换职业后会按职业组合自动匹配" or "自动职责已关闭", nextValue and "success" or "muted")
            return true
        end
        setRoleButton.onClick = function()
            local role = teamRoleInput and type(teamRoleInput.GetValue) == "function" and teamRoleInput:GetValue() or nil
            if role == nil then local valueErr = "请选择职责"; SetTeamActionStatus("失败：" .. valueErr, "warn"); return false, valueErr end
            local ok, err = feature.Commands:SetRole(role) -- X2Team:SetRole 的 Native 写 Authority 仍在 Domain ActionCapability；页面只提交已验证 TMROLE 枚举。
            if ok ~= true then SetTeamActionStatus("失败：" .. tostring(err or "职责设置未执行"), "warn"); return false, err end
            local refreshed, refreshErr = RefreshTeamAction("team_tools_set_role")
            if refreshed ~= true then SetTeamActionStatus(refreshErr, "warn"); return false, refreshErr end
            SetTeamActionStatus("已提交当前玩家职责；等待团队同步确认", "success"); return true -- Action 接受与服务端同步是两个边界，后续只读确认和诊断归职责 Feature。
        end
        if #roleItems <= 0 then teamRoleInput:SetEnabled(false); setRoleButton:SetEnabled(false) end
        teamExtra.roleStatus = roleStatus
        end
        if id == "combat_sac_highlight" then
        local assistGroup = RSUI:GroupBox({ id = teamComponentPrefix .. "assist_group", parent = root, title = "牺牲之舞 / 团队头标", variant = "soft", gap = 5, padding = 8,
            slot = { size = "auto", hAlign = "fill" } })
        local assistInner = RSUI:VerticalBox({ id = teamComponentPrefix .. "assist_inner", parent = assistGroup, gap = 5 })
        local visualRow = RSUI:HorizontalBox({ id = teamComponentPrefix .. "visual_row", parent = assistInner, gap = 6,
            slot = { size = "fixed", height = 31, hAlign = "fill" } })
        teamExtra.sacButton = RSUI:Button({ id = teamComponentPrefix .. "sac_toggle", parent = visualRow, text = "牺牲之舞：开", compact = true,
            slot = { size = "fixed", width = 108 } }) -- 仅默认显示“开”；真实状态由 TeamVisuals Store schema2 projection 刷新，旧 schema1 的关闭状态会立即显示回“关”。
        teamExtra.saveMarks = RSUI:Button({ id = teamComponentPrefix .. "mark_save", parent = visualRow, text = "保存头标", compact = true,
            slot = { size = "fixed", width = 78 } })
        teamExtra.restoreMarks = RSUI:Button({ id = teamComponentPrefix .. "mark_restore", parent = visualRow, text = "恢复头标", compact = true,
            slot = { size = "fixed", width = 78 } })
        teamExtra.clearMarks = RSUI:Button({ id = teamComponentPrefix .. "mark_clear", parent = visualRow, text = "清空保存", compact = true,
            slot = { size = "fixed", width = 78 } })
        teamExtra.status = RSUI:Text({ id = teamComponentPrefix .. "visual_status", parent = assistInner,
            text = "牺牲之舞高亮默认开启 · 尚未保存团队头标", fontSize = 8, tone = "muted", overflow = "wrap", maxLines = 2,
            slot = { size = "auto", minHeight = 22, hAlign = "fill" } }) -- 只展示 TeamVisuals detached projection，不进行 Aura/Marker Native 读取；高频事实仍由共享 Service + 按需 Consumer 提供。
        TrackField(D:SettingsNumericSlider(assistInner, {
            id=teamComponentPrefix.."sac_refresh",label="高亮绘制间隔",min=1,max=100,fixedSliderRange=true,hardMin=1,hardMax=60000,step=1,integer=true,unit="ms",
            get=function()return feature:GetProjection().sacRefreshMs or 50 end,
            set=function(value)return feature.Commands:SetSacRefreshMs(value)end,
            slot={size="fixed",height=42,hAlign="fill"},
        }))

        end
        if id == "combat_sac_highlight" then
        teamExtra.sacButton.onClick = function()
            local projection = feature:GetProjection() or {} -- 牺牲之舞开关只消费 TeamVisuals projection；候选扫描/Aura 事实不由页面直接读取。
            local nextValue = projection.sacEnabled ~= true
            local ok, err = feature.Commands:SetSacHighlightEnabled(nextValue) -- 生命周期由 TeamVisuals 在开关变更后获取/释放 Consumer；隐藏页面不等于关闭功能。
            if ok ~= true then SetTeamActionStatus("牺牲之舞高亮设置失败：" .. tostring(err or "未执行"), "warn"); return false, err end
            root:Refresh()
            SetTeamActionStatus(nextValue and "牺牲之舞高亮已开启；仅扫描舞乐候选成员" or "牺牲之舞高亮已关闭并释放团队/Aura观察", nextValue and "success" or "muted")
            return true
        end
        teamExtra.saveMarks.onClick = function()
            local ok, countOrErr = feature.Commands:SaveRaidMarkers() -- 头标快照通过 Domain 读 Native 并 durable 保存；UI 不缓存 marker identity。
            if ok ~= true then SetTeamActionStatus("保存头标失败：" .. tostring(countOrErr or "未执行"), "warn"); return false, countOrErr end
            root:Refresh(); SetTeamActionStatus("已保存当前团队头标：" .. tostring(countOrErr or 0) .. " 个", "success"); return true
        end
        teamExtra.restoreMarks.onClick = function()
            local ok, countOrErr = feature.Commands:RestoreRaidMarkers() -- 恢复仍由 1100ms 串行队列 + 读回验证治理，布局改动绝不能改成循环瞬发 Native 写入。
            if ok ~= true then SetTeamActionStatus("恢复头标失败：" .. tostring(countOrErr or "未执行"), "warn"); return false, countOrErr end
            root:Refresh(); SetTeamActionStatus("头标恢复队列已启动：" .. tostring(countOrErr or 0) .. " 个；按官方 1 秒冷却串行执行", "success"); return true
        end
        teamExtra.clearMarks.onClick = function()
            local ok, err = feature.Commands:ClearSavedRaidMarkers() -- 只清插件 Store 中的快照，不调用 Native 清除当前游戏头标，保持用户可逆性。
            if ok ~= true then SetTeamActionStatus("清空保存失败：" .. tostring(err or "未执行"), "warn"); return false, err end
            root:Refresh(); SetTeamActionStatus("已清空插件保存的头标方案；不会清除当前游戏头标", "muted"); return true
        end
        end
        SetTeamActionStatus(id == "combat_team_tools" and "仅设置当前玩家职责；全队名单只读" or "高亮与头标使用独立开关；恢复按冷却串行并读回核验", "muted")
    end
    local tableView
    local tableParent = unitLineSettingsPage and unitLineDiagnostics and unitLineDiagnostics.content or root
    local tableDesiredRows = (unitLineSettingsPage or id == "combat_boss_alerts") and 5 or 14
    local tableSlot = unitLineSettingsPage
        and { size = "auto", minHeight = 150, hAlign = "fill" }
        or { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" }
    -- 机制只有五条静态规则；固定自然高度交给外层 ScrollBox 管理溢出，
    -- 不用十四行空表挤走操作区。getKey/回调必须传入构造器，TableView 不转发事后赋值字段。
    if id == "combat_boss_alerts" then tableSlot = { size = "fixed", height = 180, hAlign = "fill" } end
    -- 计数只有两行，不让通用十四行成本表把设置挤出窄屏；滚动仍由外层负责。
    if id == "combat_buff_cap" then tableSlot = { size = "fixed", height = 100, hAlign = "fill" }; tableDesiredRows = 2 end
    tableView = RSUI:TableView({ id = "v3_business_" .. id .. "_table", parent = tableParent, items = {}, rowHeight = 26, headerHeight = 27, desiredRows = tableDesiredRows, scrollbar = true, selectable = id == "combat_boss_alerts" or id == "combat_range_assist" or id == "tools_auction" or id == "tools_market_analysis" or id == "tools_social", selectionMode = "single", columnResize = true,
        -- 范围圆列表的选择键必须是持久稳定 circleId。
        -- Authority 刷新会改变可见点/status，删除也会改变行位置；若使用默认 index key，用户可能在刷新后编辑错圆。
        getKey = id == "combat_range_assist" and function(row) return row and row.circleId end
            or id == "combat_boss_alerts" and function(row) return row and row.key end
            or (id == "tools_auction" or id == "tools_market_analysis") and AuctionRowKey
            or nil,
        onSelectionChanged = id == "combat_range_assist" and function(index, _, view)
            local row = index ~= nil and view:GetItem(index) or nil
            rangeSelectedCircleId = row ~= nil and tonumber(row.circleId) or nil
            if SyncRangeCircleEditor ~= nil then SyncRangeCircleEditor(feature:GetProjection() or {}, true) end
        end or id == "combat_boss_alerts" and function(_, _, view)
            -- ClearSelection 的同步回调可能仍携带旧 index；当前 primary key 才是选择事实。
            -- 仅遍历五条 detached 目录行，不用内部 ListView 字段，也不读取 Native 或持久化。
            local selectedKey, projection = view:GetSelectedKey(), feature:GetProjection() or {}
            bossSelectedKey = nil
            for _, row in ipairs(projection.rows or {}) do
                if selectedKey ~= nil and row.key == selectedKey then bossSelectedKey = row.mechanicKey; break end
            end
            if SyncBossControls ~= nil then SyncBossControls(projection) end
        end or nil,
        -- 只消费独立计数/峰值投影，不在单元格读API，不把未知显示成0或合计容量。
        columns = id == "combat_range_assist" and {
            -- 列表现在是“配置实体选择器”，展示所有 circles（包括已隐藏圆），
            -- 不再拿仅含当前可绘制圆的 Authority.rows 当配置清单，因此关闭某个圆后仍能再次选中并启用。
            { id = "name", title = "范围圆", field = "name", size = "fixed", width = 170, minWidth = 120 },
            { id = "text", title = "参数", field = "text", size = "fill", minWidth = 260 },
            { id = "status", title = "显示 / 投影", field = "statusText", size = "fixed", width = 110, minWidth = 88,
                getTone = function(item) return item and item.tone or "muted" end },
        } or id == "combat_buff_cap" and {
            { id = "name", title = "增益类别", field = "name", size = "fixed", width = 100, minWidth = 82 },
            { id = "count", title = "当前数量", size = "fixed", width = 85, minWidth = 68,
                getText = function(row) return row and row.count ~= nil and tostring(row.count) or "未知" end },
            { id = "peak", title = "本次峰值", size = "fixed", width = 85, minWidth = 68,
                getText = function(row) return row and row.peak ~= nil and tostring(row.peak) or "--" end },
            { id = "status", title = "个人提醒", field = "statusText", size = "fill", minWidth = 120,
                getTone = function(row) return row and row.tone or "muted" end },
        } or id == "combat_boss_alerts" and {
            { id = "name", title = "机制规则", field = "name", size = "fixed", width = 150, minWidth = 110 },
            { id = "text", title = "触发条件", field = "text", size = "fill", minWidth = 140 },
            { id = "status", title = "追踪状态 / 提示", field = "statusText", size = "fixed", width = 145, minWidth = 120, getTone = function(item) return item and item.tone or "muted" end },
        } or id == "tools_bag" and {
            {id="name",title="物品",field="name",size="fill",minWidth=150},
            {id="quantity",title="持有",size="fixed",width=58,minWidth=48,getText=function(row)return row.quantity~=nil and tostring(row.quantity) or "--"end},
            {id="state",title="状态",field="stateText",size="fixed",width=66,minWidth=60},
            {id="action",title="操作",cellType="button",size="fixed",width=64,minWidth=64,absoluteMinWidth=64,sortable=false,resizable=false,
                getText=function(row)return row and row.blocked==true and "移出" or "加入"end,onClick=function(row)return root:ToggleBlacklistItem(row)end},
        } or id == "combat_team_tools" and { -- 职责表用专属三列，固定成员名列以留出职责说明空间。
        -- 直接使用 Domain 生成的文本，不在渲染循环重复调用 X2Team:GetRole。
            { id = "name", title = "团队成员", field = "name", size = "fixed", width = 180, minWidth = 120 },
            { id = "text", title = "位置 / 职责", field = "text", size = "fill", minWidth = 260 },
            { id = "status", title = "状态", field = "statusText", size = "fixed", width = 110, minWidth = 82, getTone = function(item) return item and item.tone or "muted" end },
        } or {
            { id = "name", title = "项目", field = "name", size = "fixed", width = 180, minWidth = 100 },
            { id = "text", title = "事实 / 说明", field = "text", size = "fill", minWidth = 220 },
            { id = "cost", title = "成本 / 持有 / 缺口", field = "cost", size = "fixed", width = 190, minWidth = 120, getText = function(item)
                local parts = {}
                for _, line in ipairs(item and item.cost or {}) do parts[#parts + 1] = tostring(line.lineCost or "?") .. "/" .. tostring(line.held or "?") .. "/" .. tostring(line.shortage or "?") end
                return #parts > 0 and table.concat(parts, "; ") or "--"
            end },
            { id = "status", title = "状态", field = "statusText", size = "fixed", width = 110, minWidth = 82, getTone = function(item) return item and item.tone or "muted" end },
        }, slot = tableSlot })
    if id == "tools_auction" then
        function root:SyncAuctionSelection(updateInput)
            -- ClearSelection 的回调可能携带旧 index，只从当前 primary key 解析选择。
            local row=SelectedAuctionRow(tableView)
            auctionSelectedKeyword=row and row.kind=="favorite" and tostring(row.name or "") or nil
            if auctionRemoveArm~=auctionSelectedKeyword then auctionRemoveArm=nil end
            if auctionRemoveButton ~= nil then auctionRemoveButton:SetText(auctionRemoveArm and "确认删除?" or "删除收藏") end
            auctionQuoteRow = (row ~= nil and row.kind == "result") and row or nil
            if auctionQuoteButton ~= nil and type(auctionQuoteButton.SetEnabled) == "function" then
                auctionQuoteButton:SetEnabled(auctionQuoteRow ~= nil and auctionQuoteRow.itemType ~= nil)
            end
            if updateInput~=false and row ~= nil and row.kind == "favorite" and auctionKeywordInput ~= nil and type(auctionKeywordInput.SetValue) == "function" then
                auctionKeywordInput:SetValue(tostring(row.name or ""), false, "auction_favorite_select")
                if auctionStatus ~= nil then auctionStatus:SetText("已载入收藏关键词，点击“查询当前挂单”即可搜索。") end
            elseif updateInput~=false and row ~= nil and row.kind == "result" and row.name ~= nil and auctionKeywordInput ~= nil and type(auctionKeywordInput.SetValue) == "function" then
                auctionKeywordInput:SetValue(tostring(row.name), false, "auction_result_select")
                if auctionStatus ~= nil then auctionStatus:SetText("已载入结果名称，可直接“加入收藏”或“结果询价”。") end
            end
        end
        tableView.onSelectionChanged=function() auctionRemoveArm=nil;return root:SyncAuctionSelection(true) end
    end
    if id == "tools_social" then
        -- 点击列表行会把成员名填入操作输入框；无法识别结构的占位行（memberName == nil）不响应操作。
        tableView.onSelectionChanged = function(index)
            local row = tableView:GetItem(index)
            if row == nil or row.memberName == nil then return end
            if socialInput ~= nil and type(socialInput.SetValue) == "function" then
                socialInput:SetValue(tostring(row.memberName), false, "social_row_select")
            end
            if socialStatus ~= nil then socialStatus:SetText("已载入 " .. tostring(row.memberName) .. "（" .. tostring(row.listKind or "名单") .. "），可执行显式名单操作。") end
        end
    end
    function root:RefreshBagQuickStatus(projection)
        if bagQuickStatus==nil then return true end
            local overlay = type(projection.quickOverlay) == "table" and projection.quickOverlay or {}
            local storage = overlay.storageKind == "coffer" and "保管箱" or (overlay.storageKind == "bank" and "银行" or nil)
            local text
            if overlay.running == true then
                local action = overlay.direction == "withdraw" and "取出同类" or "存入同类"
                text = "正在" .. action .. " · 已移动 " .. tostring(overlay.moved or 0) .. " · 队列 " .. tostring(overlay.queued or 0) .. " · 再点一次可停止"
            elseif overlay.visible == true and storage ~= nil then
                text = "当前：已识别" .. storage .. " · 可以取出或存入同类物品"
                if (tonumber(overlay.moved) or 0) > 0 then text = text .. " · 上次移动 " .. tostring(overlay.moved) end
            else
                text = "当前：请先打开银行或保管箱。打开后背包上方会自动出现“取 / 放”。"
            end
            if overlay.error ~= nil and tostring(overlay.error) ~= "" then text = text .. " · " .. tostring(overlay.error) end
            bagQuickStatus:SetText(text)
            if S.Theme ~= nil and type(S.Theme.SetLabelTone) == "function" then
                S.Theme:SetLabelTone(bagQuickStatus, overlay.error ~= nil and "warn" or (overlay.running == true and "success" or "muted"))
            end
        return true
    end
    if id == "tools_craft" then tableView:SetVisibility("collapsed") end
    function root:RefreshCraftSurfaceStatus(snapshot)
        if id ~= "tools_craft" then return end
        local status = "O 自动入口不可用；点击屏幕配方按钮或打开配方小窗。"
        hint:SetText(S.FeatureRuntime:IsEnabled(id) == true and ("通用配方计划 · " .. tostring(self.craftTargetCount or 0) .. " 个目标 · " .. status)
            or "功能已关闭；已有计划保留，启用后可导入和核对配方。")
    end
    function root:Refresh()
        local projection = feature:GetProjection() or {}
        local rows = id == "tools_bag" and BuildBagSettingsRows(projection)
            or id == "combat_range_assist" and BuildRangeCircleRows(projection)
            or (projection.rows or {})
        -- 先按当前 detached circles 校验选择，再 Render Binding；
        -- 删除最后一个圆时必须先把 selected id 置空，避免 NumericField 在同一次 Refresh 中读取已不存在实体。
        if id == "combat_range_assist" and SyncRangeCircleEditor ~= nil then SyncRangeCircleEditor(projection, false) end
        for _, field in ipairs(specialFields) do if type(field.Render) == "function" then field:Render() end end
        if SyncAuctionSidecarControls ~= nil then SyncAuctionSidecarControls() end
        if (id == "tools_auction" or id == "tools_market_analysis") and self.RefreshAuctionPaging then self:RefreshAuctionPaging(projection, tableView)
        else
            local revision=projection.revision or 0
            -- 来源/筛选会改变可见行，但不改变业务revision；必须让复用按钮重新绑定当前物品ID。
            if id=="tools_bag" then self.bagSettingsRenderRevision=(self.bagSettingsRenderRevision or 0)+1;revision=self.bagSettingsRenderRevision end
            tableView:SetItems(rows,revision)
        end
        if id == "combat_range_assist" then
            local selectedIndex = nil
            for rowIndex, row in ipairs(rows) do
                if tonumber(row.circleId) == tonumber(rangeSelectedCircleId) then selectedIndex = rowIndex; break end
            end
            if selectedIndex ~= nil then
                if tableView:GetSelectedKey() ~= rangeSelectedCircleId then tableView:SetSelectedIndex(selectedIndex) end
            else
                tableView:ClearSelection()
            end
        end
        if SyncBossControls ~= nil then SyncBossControls(projection) end
        if SyncBuffCapControls ~= nil then SyncBuffCapControls(projection) end -- 实时说明独立更新，保留用户动作回执。
        if (id == "tools_auction" or id == "tools_market_analysis") and auctionStatus ~= nil then
            local statusZh=({idle="等待查询",waiting="等待服务器",ready="查询完成",partial="部分结果",empty="没有结果",failed="查询失败",unavailable="不可用"})[tostring(projection.searchStatus or "idle")] or tostring(projection.searchStatus or "idle")
            local quotePart = ""
            if id == "tools_auction" then
                if projection.quotePrice ~= nil and S.Utils ~= nil and type(S.Utils.FormatMoney) == "function" then
                    local okMoney, moneyText = pcall(S.Utils.FormatMoney, projection.quotePrice)
                    quotePart = " · 最低价：" .. (okMoney and tostring(moneyText) or tostring(projection.quotePrice))
                elseif projection.quoteStatus == "queued" or projection.quoteStatus == "waiting" then
                    quotePart = " · 最低价：询价排队中"
                elseif projection.quoteError ~= nil then
                    quotePart = " · 最低价：询价失败"
                else
                    quotePart = " · 最低价：未询价"
                end
            end
            auctionStatus:SetText(statusZh .. " · 当前结果 " .. tostring(projection.resultCount or 0) .. quotePart .. (projection.queryError and (" · " .. tostring(projection.queryError)) or "") .. (id=="tools_market_analysis" and " · 非历史成交价" or ""))
        end
        if id == "tools_craft" then
            if self.craftPlanEditor ~= nil then self.craftPlanEditor:Refresh(projection) end
        end
        if id == "tools_bag" and type(self.RefreshBlacklistEditor) == "function" then self:RefreshBlacklistEditor(projection) end
        if id=="tools_bag" then self:RefreshBagQuickStatus(projection)end
        if id == "combat_team_tools" and teamAutoRoleButton ~= nil then
            teamAutoRoleButton:SetText(projection.autoRoleEnabled == false and "自动职责：关" or "自动职责：开") -- 投影是显示 Authority，旧用户显式 false 会覆盖初始“开”文案；这里不触发任何持久化写入。
            if type(teamExtra) == "table" and teamExtra.roleStatus ~= nil then
                local roleRuntime = tostring(projection.autoRoleStatus or "等待团队/职业变化") -- 运行状态来自 TeamTools Domain 的事件驱动结果，页面只做文本投影，不额外轮询职业或团队名单。
                local roleLabel = projection.autoRoleLabel and (" · 识别：" .. tostring(projection.autoRoleLabel)) or ""
                teamExtra.roleStatus:SetText((projection.autoRoleEnabled == false and "自动职责已关闭" or "自动职责已开启") .. " · " .. roleRuntime .. roleLabel)
            end
        end
        if id == "combat_sac_highlight" then
            if type(teamExtra) == "table" and teamExtra.sacButton ~= nil then
                teamExtra.sacButton:SetText(projection.sacEnabled == true and "牺牲之舞：开" or "牺牲之舞：关")
                local enabledNow = S.FeatureRuntime:IsEnabled(id) == true
                local restoring = projection.markerRestoreRunning == true
                teamExtra.sacButton:SetEnabled(enabledNow)
                teamExtra.saveMarks:SetEnabled(enabledNow and not restoring)
                teamExtra.restoreMarks:SetEnabled(enabledNow and not restoring and (tonumber(projection.savedMarkerCount) or 0) > 0)
                teamExtra.clearMarks:SetEnabled(not restoring and (tonumber(projection.savedMarkerCount) or 0) > 0)
                local markerStatus = ({idle="待保存",saved="已保存",empty="当前无头标",restoring="恢复中",complete="恢复完成",failed="恢复失败",stopped="已停止"})[tostring(projection.markerStatus or "idle")] or tostring(projection.markerStatus or "idle")
                local text = "牺牲之舞：候选 " .. tostring(projection.sacCandidateCount or 0) .. " / 激活 " .. tostring(projection.sacActiveCount or 0)
                    .. " · 头标保存 " .. tostring(projection.savedMarkerCount or 0) .. " · " .. markerStatus
                if restoring or (tonumber(projection.markerApplied) or 0) > 0 then
                    text = text .. " " .. tostring(projection.markerApplied or 0) .. "/" .. tostring(projection.markerQueued or 0)
                    if (tonumber(projection.markerSkipped) or 0) > 0 then text = text .. " · 跳过 " .. tostring(projection.markerSkipped) end
                end
                local detail = projection.markerError or projection.sacError
                if detail ~= nil then text = text .. " · " .. tostring(detail) end
                teamExtra.status:SetText(text)
                if S.Theme ~= nil and type(S.Theme.SetLabelTone) == "function" then S.Theme:SetLabelTone(teamExtra.status, detail ~= nil and "warn" or "muted") end
            end
        end
        local enabled = S.FeatureRuntime:IsEnabled(id) == true
        toggle:SetText(enabled and "关闭功能" or "启用功能")
        if unitLineSettingsPage then
            local dia = type(feature.Diagnostics) == "table" and feature.Diagnostics or {}
            local projectionHealth = type(dia.projection) == "table" and dia.projection or {}
            local status = tostring(projection.status or dia.lastStatus or "idle")
            local statusKind, statusText = "neutral", BusinessStatusText(status)
            if enabled ~= true then
                statusKind, statusText = "muted", "已关闭"
            elseif status == "ready" then
                statusKind, statusText = "success", "正常"
            elseif status == "partial" then
                statusKind, statusText = "warning", "部分可用"
            elseif status == "empty" then
                statusKind, statusText = "caution", "等待目标"
            elseif status == "runtime_blocked" or status == "failed" or status == "unavailable" then
                statusKind, statusText = "danger", status == "runtime_blocked" and "运行时阻塞" or "投影不可用"
            elseif enabled then
                statusKind, statusText = "info", BusinessStatusText(status)
            end
            if unitLineHeader ~= nil then unitLineHeader:SetStatus(statusKind, statusText) end
            if enabled ~= true then
                hint:SetText("状态：功能已关闭；开启后才读取目标投影并绘制连线。")
            elseif status == "ready" then
                hint:SetText("状态：工作中 · 当前可绘制 " .. tostring(#rows) .. " 条连线。")
            elseif status == "empty" then
                hint:SetText("状态：等待可绘制目标；选中目标或设置焦点后会自动更新。")
            elseif status == "partial" then
                hint:SetText("状态：部分连线可用 · 当前可绘制 " .. tostring(#rows) .. " 条；详细原因见“高级 / 诊断”。")
            else
                hint:SetText("状态：" .. tostring(statusText) .. "；详细原因见“高级 / 诊断”。")
            end
            if unitLineDiagnosticsText ~= nil then
                local reason = projection.error or dia.lastFailureReason or "无"
                local parts = {
                    "运行状态=" .. status,
                    "消费者=" .. tostring(dia.consumerCount or 0),
                    "尝试=" .. tostring(dia.attemptedPairs or 0),
                    "可绘制=" .. tostring(dia.drawnRows or #rows),
                    "端点重合=" .. tostring(dia.endpointCollapsed or 0),
                    "投影失败=" .. tostring(projectionHealth.failures or 0),
                    "最近原因=" .. tostring(reason),
                }
                unitLineDiagnosticsText:SetText(table.concat(parts, " · "))
            end
        elseif id == "combat_buff_cap" then
            hint:SetText("普通/隐藏分别计数，不推断共享容量或顶替规则。0关闭该类提醒；本次启用峰值仅覆盖实际采样。"
                .. (enabled ~= true and " 功能已关闭，设置仍可保存。" or " 关闭页面后仅个人提醒继续观察；关闭功能全部停止。"))
        elseif id == "tools_craft" then
            local plan = type(projection.plan) == "table" and projection.plan or {}
            self.craftTargetCount = #(plan.targets or {})
            self:RefreshCraftSurfaceStatus(projection.craftSurface)
        elseif id == "tools_bag" then
            if enabled ~= true then
                hint:SetText("功能已关闭；黑名单配置会保留，重新启用后继续生效。")
            else
                local storage = projection.batchTargetResolved == "coffer" and "保管箱" or (projection.batchTargetResolved == "bank" and "银行" or nil)
                hint:SetText(storage ~= nil
                    and ("已连接" .. storage .. " · 取出同类 / 存入同类 · 当前背包可识别物品 " .. tostring(#rows) .. " 种")
                    or ("打开银行或保管箱后即可整理同类物品 · 当前背包可识别物品 " .. tostring(#rows) .. " 种"))
            end
        elseif id == "combat_range_assist" then
            local circleCount = tonumber(projection.circleCount) or 0
            local enabledCircleCount = tonumber(projection.enabledCircleCount) or 0
            if enabled ~= true then
                hint:SetText("功能已关闭；范围圆配置会保留，重新启用后继续显示。")
            elseif circleCount <= 0 then
                hint:SetText("当前还没有范围圆；点击“新增范围圆”后再分别设置 20m、10m、5m 等多个圈。")
            elseif enabledCircleCount <= 0 then
                hint:SetText("已创建 " .. tostring(circleCount) .. " 个范围圆，但当前全部关闭；至少启用一个圆才会绘制。")
            elseif projection.status == "partial" then
                hint:SetText("部分可用 · 已启用 " .. tostring(enabledCircleCount) .. "/" .. tostring(circleCount) .. " 个范围圆 · " .. tostring(projection.error or "有圆投影不足，已继续刷新重试。"))
            else
                hint:SetText("工作中 · 已启用 " .. tostring(enabledCircleCount) .. "/" .. tostring(circleCount) .. " 个范围圆。")
            end
        elseif projection.status == "runtime_blocked" then
            hint:SetText("运行时阻塞：" .. tostring(projection.error or (meta and meta.runtimeBlocker) or "未说明") .. "\n当前实现：页面与生命周期已接入；剩余能力需 RU 实机/API 契约证据后才能继续。")
        elseif enabled and (projection.status == "partial" or (meta and meta.status == "migrated_partial")) then
            local detail = projection.error or (meta and meta.remainingCapability) or "部分能力仍待验证"
            hint:SetText("部分可用 · " .. tostring(#rows) .. " 条投影 · " .. tostring(detail))
        else
            hint:SetText(enabled and (BusinessStatusText(projection.status) .. " · " .. tostring(#rows) .. " 条数据") or "功能已关闭；启用后才读取对应 API。")
        end
        -- 用 enabled 和行数区分空、加载与不可用状态，与其它业务表一致。
        local tvState, tvOpts
        -- 机制目录不是实时采集结果，停用 Feature 后仍可配置下一次启动规则；
        -- 这里只保持静态表可选，测试按钮与观察任务仍服从 Feature/HUD 开关，不放宽其它页面。
        if enabled ~= true and id ~= "combat_boss_alerts" and id ~= "combat_range_assist" then
            tvState, tvOpts = "unavailable", { title = "功能已关闭", detail = id == "tools_bag" and "重新启用后会读取当前背包物品；已有黑名单不会丢失。" or ((meta and meta.name or id) .. " 启用后才会读取对应 API 并填充此表。") }
        elseif id == "combat_range_assist" then
            local circleCount = tonumber(projection.circleCount) or 0
            if circleCount <= 0 then
                tvState, tvOpts = "empty", { title = "当前没有范围圆", detail = "点击上方“新增范围圆”；新圆会自动选中并可立即编辑。" }
            else
                -- 这是持久配置列表，不是 Native 实时结果。即使 Feature 关闭或所有圆隐藏，
                -- 仍必须允许点击任意圆继续编辑/删除；是否绘制由上方状态行说明，不能用 unavailable/empty 覆盖交互。
                tvState = "ready"
            end
        elseif #rows == 0 then
            tvState, tvOpts = "empty", { title = id == "tools_bag" and (root.bagSettingsView=="blacklist" and "黑名单为空或无匹配物品" or "未找到背包物品") or "暂无数据", detail = id == "tools_bag" and "可清除筛选，或点击刷新背包。" or ((meta and meta.name or id) .. " 启用并读取后，结果会显示在这里。") }
        else
            tvState = "ready"
        end
        tableView:SetViewState(tvState, tvOpts)
        return true
    end
    -- 世界视觉权威层可能以 20 Hz（RangeAssist）或用户选择的 1 ms（UnitLines）发布。设置页不属于该渲染路径；同频重绘 RSUI 会浪费工作，并在 RU 中产生虚假的按钮离开/进入事件。
    -- 合并 visual-tick 表现更新，直接命令和非视觉权威更新仍立即处理。
    local visualSettingsPage = id == "combat_unit_lines" or id == "combat_range_assist"
    local visualPageRefreshTask = "v3_business_visual_page_refresh:" .. tostring(id)
    local visualPageRefreshMs = 160

    local function VisualSettingsInputDraftActive(observeNative)
        return visualSettingsPage == true and type(RSUI.HasActiveInputDraftWithin) == "function"
            and RSUI:HasActiveInputDraftWithin(root,observeNative) == true
    end
    local function DeferVisualPageRefreshForInput(reason)
        root.visualPageRefreshDeferredForInput = true
        root.visualPageRefreshDeferredReason = tostring(reason or "visual_tick")
        if root.visualPageRefreshPending == true and S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then
            S.Scheduler:RemoveTask(visualPageRefreshTask)
            root.visualPageRefreshPending = false
        end
        RSUI.metrics.visualPageInputRefreshSuppressions = (tonumber(RSUI.metrics.visualPageInputRefreshSuppressions) or 0) + 1
        return true
    end
    function root:RequestFeatureRefresh(reason)
        reason = tostring(reason or "update")
        -- 背包几何心跳只更新取放状态，不重绑整张物品表；物品快照/名单变化仍走原更新。
        if id=="tools_bag" and reason:sub(1,10)=="bag_quick_" then return self:RefreshBagQuickStatus(feature:GetProjection() or {})end
        if visualSettingsPage ~= true or (reason ~= "visual_tick" and reason ~= "visual_tick_error") then
            return self:Refresh()
        end
        -- visual_tick 不能在用户编辑时驱动整页刷新。仅保护文本还不够，
        -- TableView、状态和 Enabled 的 Native 更新也可能触发 RU LostFocus，恢复旧文本。
        -- 编辑期间跳过页面刷新；绘制任务照常运行，结束编辑后的下一次 visual_tick 补齐。
        -- 高频通知只查 Lua 草稿，Native 文本核对留到 160ms 合并刷新前，避免每帧 GetText。
        if VisualSettingsInputDraftActive(false) then return DeferVisualPageRefreshForInput(reason) end
        root.visualPageRefreshDeferredForInput = false
        root.visualPageRefreshDeferredReason = nil
        if self.visualPageRefreshPending == true then return true end
        if S.Scheduler == nil or type(S.Scheduler.AddOneShot) ~= "function" then return self:Refresh() end
        self.visualPageRefreshPending = true
        local added = S.Scheduler:AddOneShot(visualPageRefreshTask, visualPageRefreshMs, function()
            self.visualPageRefreshPending = false
            if self.featureUpdatesBound ~= true then return true end
            -- 刷新可能在用户点击输入框之前入队，执行时必须再次检查编辑状态；否则即使后续 Tick 被抑制，旧 one-shot 仍可能在 160ms 后抢走焦点。
            if VisualSettingsInputDraftActive() then return DeferVisualPageRefreshForInput("scheduled:" .. reason) end
            self.visualPageRefreshDeferredForInput = false
            self.visualPageRefreshDeferredReason = nil
            return self:Refresh()
        end, self, "P3", 1)
        if added ~= true then
            self.visualPageRefreshPending = false
            if VisualSettingsInputDraftActive() then return DeferVisualPageRefreshForInput("scheduler_fallback:" .. reason) end
            return self:Refresh()
        end
        if type(S.Scheduler.SetTaskModule) == "function" then
            S.Scheduler:SetTaskModule(visualPageRefreshTask, "presentation", true)
        end
        return true
    end
    function root:BindFeatureUpdates()
        if S.Events == nil or type(S.Events.SubscribeInternal) ~= "function" then return false, "内部事件总线不可用" end
        if type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        self.featureUpdatesBound = true
        -- UpdateTopic 是业务投影通知，可选；Feature 生命周期订阅是页面 lease 的硬契约，二者不能互相 gating。
        if type(feature.UpdateTopic) == "string" and feature.UpdateTopic ~= "" then
            local subscribed, subscribeErr = S.Events:SubscribeInternal(feature.UpdateTopic, self, function(_, _, reason) return root:RequestFeatureRefresh(reason) end)
            if subscribed ~= true then return false, subscribeErr end
        end
        -- 拍卖行几何变化不重绘业务页；Controller 只在开关、显隐和恢复时发布 ControlTopic。
        -- 此处仅刷新助手卡片，不询价或增加 Consumer；离页时随 root owner 退订。
        if id == "tools_auction" and SyncAuctionSidecarControls ~= nil then
            local controller = S.UIV3 and S.UIV3.AuctionSidecar or nil
            if type(controller) == "table" and type(controller.ControlTopic) == "string" then
                local controlOk, controlErr = S.Events:SubscribeInternal(controller.ControlTopic, self, function()
                    return SyncAuctionSidecarControls()
                end)
                if controlOk ~= true then
                    self.featureUpdatesBound = false
                    if type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
                    return false, controlErr
                end
            end
        end
        if id == "tools_craft" then
            local surface = S.Services and S.Services.CraftSurfaceV3
            if surface and type(surface.topic) == "string" then
                -- 仅刷新状态文字，避免开关原生窗口时重绘编辑器或覆盖输入草稿。
                S.Events:SubscribeInternal(surface.topic, self, function(_, snapshot) return root:RefreshCraftSurfaceStatus(snapshot) end)
            end
        end
        -- 功能方案可在页面可见时启停模块；disabled 同步已释放的 lease，enabled 重取同一 token。
        local lifecycleOk, lifecycleErr = Host:BindFeatureConsumerLifecycle(self, consumerBinding)
        if lifecycleOk ~= true then
            self.featureUpdatesBound = false
            if type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
            return false, lifecycleErr or "业务页面生命周期订阅失败"
        end
        return true
    end
    function root:UnbindFeatureUpdates()
        self.featureUpdatesBound = false
        self.visualPageRefreshPending = false
        self.visualPageRefreshDeferredForInput = false
        self.visualPageRefreshDeferredReason = nil
        if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(visualPageRefreshTask) end
        if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        return true
    end
    function root:OnActivated()
        local bound, bindErr = self:BindFeatureUpdates()
        if bound ~= true then return false, bindErr end
        -- Demand 0->1 仍由 Domain 负责初始读取；这里仅建立当前页面 lease 并渲染现有投影。
        return Host:SyncFeatureConsumer(self, consumerBinding, "page_activated")
    end
    function root:OnDeactivated()
        -- 离页结束未应用的视觉设置草稿；重开从业务权威重绘，避免隐藏期Native重绘被当成新输入。
        if visualSettingsPage and type(RSUI.CancelInputDraftsWithin)=='function' then RSUI:CancelInputDraftsWithin(self,'page_deactivated') end
        -- 离开设置页只退出鼠标校准，保留已启用机制的后台观察，避免 HUD 截获战斗点击。
        if id == "combat_boss_alerts" and type(feature.Commands.SetHudEditing) == "function" then feature.Commands:SetHudEditing(false) end
        self:UnbindFeatureUpdates()
        if id=='tools_craft' and type(feature.Commands.PlanCancelReceiveShare)=='function' then
            feature.Commands:PlanCancelReceiveShare('page:tools_craft')
        end
        return Host:ReleaseFeatureConsumer(self, consumerBinding, "page_deactivated")
    end
    root.route, root.tableView = route, tableView
    return root
end

local function MakeBusinessFactory(capturedId)
    return function(parent, route) return Build(parent, route, capturedId) end
end
for _, item in ipairs(ROUTES) do
    local ok, err = Host:RegisterFactory(item.route, MakeBusinessFactory(item.id))
    if ok ~= true then error(err) end
end
