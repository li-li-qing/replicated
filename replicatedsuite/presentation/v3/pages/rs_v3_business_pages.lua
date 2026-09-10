------------------------------------------------------------------------
-- Replicated Suite V3 - business Feature pages
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI, D, Host = S.RSUI, S.UIV3Design, S.UIV3 and S.UIV3.PageHost or nil
if type(RSUI) ~= "table" or type(D) ~= "table" or type(Host) ~= "table" then return end
S.UIV3.BusinessPagesContract = { version = 7, componentIdContractVersion = 1, bagProductUxContractVersion = 2, auctionCurrentListingUxContractVersion = 1, craftPlanUxContractVersion = 1, craftSidecarUxContractVersion = 1, unitLineSettingsFoundationConsumerContractVersion = 3,
    teamCenterLayoutContractVersion = 1, -- 中文维护注释：.18.197 团队中心把职责/团队辅助分组，并移除主视图中永远不可执行的成员移动表单；只改变 Presentation 层级与列定义，不改变 v3.team_tools / v3.team_visuals Authority、命令安全门或 Store。
}

local ROUTES = {
    { route = "combat.boss_alerts", id = "combat_boss_alerts" }, { route = "combat.target_monitor", id = "combat_target_monitor" },
    { route = "combat.unit_lines", id = "combat_unit_lines" }, { route = "combat.range_assist", id = "combat_range_assist" },
    { route = "combat.buff_cap", id = "combat_buff_cap" }, { route = "combat.team_tools", id = "combat_team_tools" },
    { route = "combat.raid_recruitment", id = "combat_raid_recruitment" }, { route = "combat.siege_readiness", id = "combat_siege_readiness" },
    { route = "life.craft_planner", id = "life_craft_planner" }, { route = "tools.bag_organizer", id = "tools_bag" },
    { route = "tools.auction_favorites", id = "tools_auction" }, { route = "tools.market_analysis", id = "tools_market_analysis" },
    { route = "tools.craft_assist", id = "tools_craft" }, { route = "tools.social", id = "tools_social" },
    { route = "tools.hotkey_profiles", id = "tools_hotkey_profiles" }, { route = "tools.reinforce_analysis", id = "tools_reinforce_analysis" },
    { route = "tools.portal_profiles", id = "tools_portal_profiles" },
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
    local rootSpec = id == "combat_unit_lines" and {
        id = "v3_page_business_" .. tostring(id), gap = 7, padding = 2, scrollStep = 1,
    } or ("v3_page_business_" .. tostring(id))
    local root, err
    if id == "tools_bag" then
        -- MAINTENANCE (2026-09-10, bag viewport fill): tools_bag is a data-view page whose
        -- primary body is the virtualized TableView below.  The generic business ScrollBox
        -- measures that table from desiredRows and treats it as an auto-sized snapped item;
        -- on tall windows this left a large unused strip below the bag rows even though the
        -- page still owned free viewport height.  InventorySnapshotV3 / feature projection
        -- remains the data Authority and all quick-move / blacklist commands keep their
        -- existing data flow; this is Presentation geometry only.  Give this one page a
        -- normal VerticalBox root so its fixed editor controls consume natural height and
        -- the TableView's existing fill slot receives the entire remainder.  The TableView
        -- continues to own row scrolling/selection, while all other sequential business
        -- pages retain ScrollablePageRoot for small-resolution/UI-scale compatibility.
        root, err = D:PageRoot(parent, rootSpec)
    else
        root, err = D:ScrollablePageRoot(parent, rootSpec)
    end
    if root == nil then return nil, err end
    root.consumerHeld = false
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
        toggle = RSUI:Button({ id = "v3_business_combat_unit_lines_feature_toggle", parent = unitLineHeader.actions,
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
            meta and meta.description or "V3 业务功能页；数据读取由独立 Authority 完成。", "刷新", function()
                local ok, refreshErr = feature.Commands:Refresh("page_manual")
                if ok == true then root:Refresh() end
                return ok, refreshErr
            end)
    end

    local teamCenterIds = {
        combat_team_tools = { route = "combat.team_tools", text = "团队管理" },
        combat_raid_readiness = { route = "combat.raid_readiness", text = "战备检查" },
        combat_raid_recruitment = { route = "combat.raid_recruitment", text = "招募助手" },
        combat_siege_readiness = { route = "combat.siege_readiness", text = "攻城战备" },
    }
    if teamCenterIds[id] ~= nil then
        local tabs = RSUI:HorizontalBox({ id = "v3_team_center_tabs_" .. id, parent = root, gap = 5, slot = { size = "fixed", height = 31, hAlign = "fill" } })
        for _, teamId in ipairs({ "combat_team_tools", "combat_raid_readiness", "combat_raid_recruitment", "combat_siege_readiness" }) do
            local tab = teamCenterIds[teamId]
            local tabRef = tab
            local button = RSUI:Button({ id = "v3_team_center_tab_" .. id .. "_" .. teamId, parent = tabs,
                text = (teamId == id and "● " or "") .. tabRef.text, compact = true,
                slot = { size = "fixed", width = teamId == "combat_raid_recruitment" and 96 or 88 } })
            button.onClick = function()
                local shell = S.UIV3 and S.UIV3.Shell or nil
                if type(shell) ~= "table" or type(shell.Navigate) ~= "function" then return false, "团队中心导航不可用" end
                return shell:Navigate(tabRef.route, { source = "team_center_tab" })
            end
        end
    end

    if unitLineSettingsPage ~= true then
        local actionRow = RSUI:HorizontalBox({ id = "v3_business_" .. id .. "_actions", parent = root, gap = 6, slot = { size = "fixed", height = 31, hAlign = "fill" } })
        toggle = RSUI:Button({ id = "v3_business_" .. id .. "_toggle", parent = actionRow, text = "关闭功能", compact = true, slot = { size = "fixed", width = 96 } })
        hint = RSUI:Text({ id = "v3_business_" .. id .. "_hint", parent = root, text = "", fontSize = 9, tone = "muted", overflow = "wrap", slot = { size = "auto", minHeight = 30, hAlign = "fill" } })
    end
    if toggle == nil or hint == nil then return nil, "business_page_primary_controls_failed:" .. tostring(id) end
    toggle.onClick = function()
        local enabled = S.FeatureRuntime:IsEnabled(id) == true
        local target = not enabled
        local ok, enableErr = S.FeatureRuntime:SetPreferredEnabled(id, target, "business_page_toggle")
        if ok ~= true then
            if hint ~= nil then hint:SetText("启用失败：" .. tostring(enableErr or "未知原因")) end
            return false, enableErr
        end
        if target then
            local acquired, acquireErr = feature:AcquireConsumer("page:" .. id)
            if acquired ~= true then
                local rolledBack, rollbackErr = S.FeatureRuntime:SetPreferredEnabled(id, false, "business_page_acquire_rollback")
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
    local craftRecipeDropdown, craftActionStatus, craftQuoteButton
    local craftPlanTable, craftPlanQtyInput, craftPlanRemoveButton, craftPlanQuoteButton, craftPlanStatus, craftPlanSelectedIndex
    local specialFields = {}
    local function TrackField(field) if field ~= nil then specialFields[#specialFields + 1] = field end return field end
    local bossTestStatus = nil
    if id == "combat_boss_alerts" then
        local hudRow = RSUI:HorizontalBox({ id = "v3_business_combat_boss_alerts_hud_row", parent = root, gap = 6,
            slot = { size = "fixed", height = 30, hAlign = "fill" } })
        TrackField(RSUI:Toggle({ id = "v3_business_combat_boss_alerts_hud_enabled", parent = hudRow,
            onText = "机制 HUD：开", offText = "机制 HUD：关",
            get = function() return (feature:GetProjection() or {}).hudEnabled == true end,
            set = function(v) return feature.Commands:SetHudEnabled(v == true) end,
            slot = { size = "fixed", width = 120 } }))
        TrackField(RSUI:Toggle({ id = "v3_business_combat_boss_alerts_hud_anchor", parent = hudRow,
            onText = "位置：顶部", offText = "位置：中央",
            get = function() return (feature:GetProjection() or {}).hudAnchor == "top" end,
            set = function(v) return feature.Commands:SetHudAnchor(v and "top" or "center") end,
            slot = { size = "fixed", width = 120 } }))
        local testBig = RSUI:Button({ id = "v3_business_combat_boss_alerts_test_big", parent = hudRow, text = "测试大字", compact = true, slot = { size = "fixed", width = 82 } })
        local testCountdown = RSUI:Button({ id = "v3_business_combat_boss_alerts_test_countdown", parent = hudRow, text = "测试倒计时", compact = true, slot = { size = "fixed", width = 92 } })
        -- World-boss-independent verification: inject a CATALOGED rule through
        -- the real lookup+push chain (no boss encounter required). Fact-source
        -- truth stays with the Boss: diagnostics line on any cast-bar mob.
        local simCast = RSUI:Button({ id = "v3_business_combat_boss_alerts_sim_cast", parent = hudRow, text = "仿真读条", compact = true, slot = { size = "fixed", width = 82 } })
        local simDebuff = RSUI:Button({ id = "v3_business_combat_boss_alerts_sim_debuff", parent = hudRow, text = "仿真Debuff", compact = true, slot = { size = "fixed", width = 92 } })
        bossTestStatus = RSUI:Text({ id = "v3_business_combat_boss_alerts_test_status", parent = hudRow, text = "实时：目标施法 + 自身Debuff", fontSize = 8, tone = "muted", overflow = "ellipsis", slot = { size = "fill", fill = 1 } })
        testBig.onClick = function() local ok, actionErr = feature.Commands:TestBigText(); bossTestStatus:SetText(ok and "大字 HUD 已触发" or ("测试失败：" .. tostring(actionErr or "未执行"))); return ok, actionErr end
        testCountdown.onClick = function() local ok, actionErr = feature.Commands:TestCountdown(); bossTestStatus:SetText(ok and "倒计时 HUD 已触发" or ("测试失败：" .. tostring(actionErr or "未执行"))); return ok, actionErr end
        simCast.onClick = function() local ok, actionErr = feature.Commands:SimulateCast(); bossTestStatus:SetText(ok and "仿真读条：规则匹配+HUD 已触发" or ("仿真失败：" .. tostring(actionErr or "未执行"))); return ok, actionErr end
        simDebuff.onClick = function() local ok, actionErr = feature.Commands:SimulateDebuff(); bossTestStatus:SetText(ok and "仿真Debuff：规则匹配+HUD 已触发" or ("仿真失败：" .. tostring(actionErr or "未执行"))); return ok, actionErr end
        local hudGrid = RSUI:UniformGrid({ id = "v3_business_combat_boss_alerts_hud_grid", parent = root, minCellWidth = 260, minCellHeight = 30, maxColumns = 2, gap = 5, slot = { size = "auto", minHeight = 30, hAlign = "fill" } })
        TrackField(D:CompactNumericSetting(hudGrid, { id = "v3_business_combat_boss_alerts_font", label = "HUD 字号", min = 18, max = 56, step = 1, integer = true, unit = "", slider = true,
            get = function() return (feature:GetProjection() or {}).hudFontSize or 34 end, set = function(v) return feature.Commands:SetHudFontSize(v) end, slot = { size = "fill", fill = 1, hAlign = "fill" } }))
        TrackField(D:CompactNumericSetting(hudGrid, { id = "v3_business_combat_boss_alerts_duration", label = "显示时长", min = 1000, max = 10000, step = 250, integer = true, unit = "ms", slider = true,
            get = function() return (feature:GetProjection() or {}).hudDurationMs or 3000 end, set = function(v) return feature.Commands:SetHudDurationMs(v) end, slot = { size = "fill", fill = 1, hAlign = "fill" } }))
    elseif id == "combat_unit_lines" then
        local pairSpecs = {
            { key="target", label="当前目标", field="showTarget" },
            { key="targettarget", label="目标的目标", field="showTargetTarget" },
            { key="focus", label="焦点目标", field="showFocusTarget" },
            { key="focustarget", label="焦点的目标", field="showFocusTargetTarget" },
        }
        -- Keep visible text inside the RU font's known-safe glyph set.  Earlier
        -- arrow/check glyphs were silently missing on some client fonts and left
        -- awkward gaps in card titles/toggle labels.
        local pairNames = {
            target = "自己 与 当前目标", targettarget = "当前目标 与 目标的目标",
            focus = "自己 与 焦点目标", focustarget = "焦点目标 与 焦点的目标",
        }
        local UNIT_LINE_PALETTE = {
            target = { 1.00, 0.72, 0.12 }, targettarget = { 0.94, 0.42, 0.20 },
            focus = { 0.35, 0.82, 1.00 }, focustarget = { 0.67, 0.52, 1.00 },
        }

        -- .18.161: use the COMPLETE shared numeric contract everywhere.  The
        -- .18.160 card compaction incorrectly disabled sliders in per-pair rows;
        -- cards now keep one full Slider + exact NumericInput + Apply row per
        -- value. NumericField remains the sole Binding/adaptive-range authority.
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
            id = "v3_business_combat_unit_lines_points", label = "默认密度", min = 8, max = 48, hardMin = 8, hardMax = 48,
            fixedRange = true, step = 1, integer = true, labelWidth = 68, inputWidth = 54, applyButtonWidth = 38,
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
            id = "v3_business_combat_unit_lines_refresh", label = "刷新间隔", min = 1, max = 1000, hardMin = 1, hardMax = 1000,
            fixedRange = true, step = 25, integer = true, unit = "ms", labelWidth = 68, inputWidth = 58, applyButtonWidth = 38,
            controlHeight = 22, minHeight = 30, stackBelow = 274, sliderMinWidth = 74, sliderPreferredShare = 0.44,
            get = function() return (feature:GetProjection() or {}).refreshMs or 100 end,
            set = function(v) return feature.Commands:SetRefreshMs(v) end,
            slot = { size = "fill", fill = 1, hAlign = "fill" },
        }))
        RSUI:Text({ id = "v3_business_combat_unit_lines_density_hint", parent = globalSection.content,
            text = "远距离自动补点；性能压力只削减额外补点，不降低基础连续性。",
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
                label = "密度", min = 8, max = 48, hardMin = 8, hardMax = 48, fixedRange = true,
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
        local grid = RSUI:UniformGrid({ id = "v3_business_combat_range_assist_settings", parent = root, minCellWidth = 230, minCellHeight = 30, maxColumns = 2, gap = 5, slot = { size = "auto", minHeight = 60, hAlign = "fill" } })
        TrackField(D:CompactNumericSetting(grid, { id = "v3_business_combat_range_assist_radius", label = "半径", min = 1, max = 100, step = 0.5, integer = false, unit = "m", slider = true,
            get = function() return (feature:GetProjection() or {}).radius or 10 end, set = function(v) return feature.Commands:SetRadius(v) end, slot = { size = "fill", fill = 1, hAlign = "fill" } }))
        TrackField(D:CompactNumericSetting(grid, { id = "v3_business_combat_range_assist_points", label = "圆点数量", min = 12, max = 48, step = 1, integer = true, slider = true,
            get = function() return (feature:GetProjection() or {}).pointCount or 24 end, set = function(v) return feature.Commands:SetPointCount(v) end, slot = { size = "fill", fill = 1, hAlign = "fill" } }))
        TrackField(D:CompactNumericSetting(grid, { id = "v3_business_combat_range_assist_size", label = "点大小", min = 2, max = 10, hardMin = 2, hardMax = 24, step = 1, integer = true, slider = true,
            get = function() return (feature:GetProjection() or {}).pointSize or 4 end, set = function(v) return feature.Commands:SetPointSize(v) end, slot = { size = "fill", fill = 1, hAlign = "fill" } }))
        TrackField(D:CompactNumericSetting(grid, { id = "v3_business_combat_range_assist_opacity", label = "透明度", min = 0.1, max = 1, step = 0.05, integer = false, slider = true,
            get = function() return (feature:GetProjection() or {}).opacity or 0.68 end, set = function(v) return feature.Commands:SetOpacity(v) end, slot = { size = "fill", fill = 1, hAlign = "fill" } }))
        -- Range-assist previously had NO line-color control. The ColorField below
        -- writes feature.Commands:SetColor; the presenter falls back to the same
        -- (0.20, 0.82, 1.00) default until a color is persisted.
        TrackField(RSUI:ColorField({ id = "v3_business_combat_range_assist_color", parent = grid, label = "线条颜色",
            get = function() return (feature:GetProjection() or {}).color or { 0.20, 0.82, 1.00 } end,
            set = function(color) return feature.Commands:SetColor(color[1], color[2], color[3]) end,
            slot = { size = "fill", fill = 1, hAlign = "fill" } }))
    end
    local auctionKeywordInput, auctionStatus, auctionPage = nil, nil, 1
    local auctionPageSize, auctionSelectedIndex = 10, nil
    local auctionQuoteRow, auctionRemoveArm = nil, nil
    local auctionQuoteButton, auctionRemoveButton = nil, nil
    local auctionExactField, auctionLimitField = nil, nil
    if id == "tools_auction" or id == "tools_market_analysis" then
        local row = RSUI:HorizontalBox({ id = "v3_business_" .. id .. "_auction_context", parent = root, gap = 6, slot = { size = "fixed", height = 31, hAlign = "fill" } })
        auctionKeywordInput = RSUI:TextInput({ id = "v3_business_" .. id .. "_auction_keyword", parent = row, value = "", maxLength = 64, allowEmpty = false, placeholder = "物品名称", slot = { size = "fill", fill = 1, minWidth = 160 } })
        local search = RSUI:Button({ id = "v3_business_" .. id .. "_auction_search", parent = row, text = "查询当前挂单", compact = true, slot = { size = "fixed", width = 96 } })
        local add = id == "tools_auction" and RSUI:Button({ id = "v3_business_tools_auction_add", parent = row, text = "加入收藏", compact = true, slot = { size = "fixed", width = 72 } }) or nil
        local quote = id == "tools_auction" and RSUI:Button({ id = "v3_business_tools_auction_quote", parent = row, text = "结果询价", compact = true, slot = { size = "fixed", width = 72 } }) or nil
        auctionQuoteButton = quote
        auctionStatus = RSUI:Text({ id = "v3_business_" .. id .. "_auction_status", parent = root,
            text = id == "tools_auction" and "收藏与当前挂单查询已接入；服务器搜索按 9 参数契约显式执行。" or "这里只展示当前拍卖挂单，不把搜索结果伪装成历史成交行情。",
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
            if auctionSelectedIndex==nil then auctionRemoveArm=nil; remove:SetText("删除收藏"); auctionStatus:SetText("请先选择一条收藏关键词"); return false end
            -- Two-click confirm: favorites are not recoverable, and an accidental
            -- click used to delete immediately with no undo.
            if auctionRemoveArm~=auctionSelectedIndex then
                auctionRemoveArm=auctionSelectedIndex
                remove:SetText("确认删除?")
                auctionStatus:SetText("再点一次“确认删除?”才会删除该收藏。")
                return true
            end
            auctionRemoveArm=nil; remove:SetText("删除收藏")
            local ok,removeErr=feature.Commands:RemoveFavorite(auctionSelectedIndex)
            if ok then auctionSelectedIndex=nil; feature.Commands:Refresh("auction_remove"); root:Refresh() else auctionStatus:SetText("删除失败："..tostring(removeErr or "未执行")) end
            return ok,removeErr
        end end
        root.RefreshAuctionPaging=function(self,projection,tableView)
            local source=type(projection.rows)=="table" and projection.rows or {}; local total=#source
            local pagesCount=math.max(1,math.ceil(total/auctionPageSize)); auctionPage=math.min(auctionPage,pagesCount)
            local first=(auctionPage-1)*auctionPageSize+1; local pageRows={}
            for i=first,math.min(first+auctionPageSize-1,total) do pageRows[#pageRows+1]=source[i] end
            tableView:SetItems(pageRows,projection.revision or 0)
            pageText:SetText("第 "..tostring(auctionPage).."/"..tostring(pagesCount).." 页 · 当前 "..tostring(total).." 条"..(id=="tools_auction" and (" · 收藏 "..tostring(projection.favoriteCount or 0)) or ""))
            prev:SetEnabled(auctionPage>1); next:SetEnabled(auctionPage<pagesCount)
        end
    end
    if id == "life_craft_planner" or id == "tools_craft" then
        local craftRow = RSUI:HorizontalBox({ id = "v3_business_" .. id .. "_recipe_row", parent = root, gap = 6,
            slot = { size = "fixed", height = 32, hAlign = "fill" } })
        RSUI:Text({ id = "v3_business_" .. id .. "_recipe_label", parent = craftRow, text = "制作物", fontSize = 9, tone = "strong",
            slot = { size = "fixed", width = 46 } })
        local initialProjection = feature:GetProjection() or {}
        craftRecipeDropdown = RSUI:Dropdown({ id = "v3_business_" .. id .. "_recipe_select", parent = craftRow,
            items = type(initialProjection.recipeOptions)=="table" and initialProjection.recipeOptions or {}, maxVisible = 12, popupWidth = 310,
            get = function() return (feature:GetProjection() or {}).selectedRecipeKey end,
            set = function(value)
                local ok, commandErr = feature.Commands:SelectRecipe(value)
                if ok == true then root:Refresh() end
                return ok, commandErr
            end, placeholder = "选择已核制作物", slot = { size = "fill", fill = 1, minWidth = 220 } })
        local refreshButton = RSUI:Button({ id = "v3_business_" .. id .. "_recipe_refresh", parent = craftRow, text = "刷新材料", compact = true,
            slot = { size = "fixed", width = 78 } })
        craftQuoteButton = RSUI:Button({ id = "v3_business_" .. id .. "_material_quote", parent = craftRow, text = "材料询价", compact = true, enabled = false,
            slot = { size = "fixed", width = 92 } })
        craftActionStatus = RSUI:Text({ id = "v3_business_" .. id .. "_context_status", parent = root,
            text = "从制作物列表选择配方；内部配方编号和物品编号只用于诊断，不要求用户输入。", fontSize = 8, tone = "muted", overflow = "wrap", maxLines = 2,
            slot = { size = "auto", minHeight = 26, hAlign = "fill" } })
        refreshButton.onClick = function()
            local ok, refreshErr = feature.Commands:Refresh("craft_page_manual")
            if ok == true then root:Refresh()
            elseif craftActionStatus ~= nil then craftActionStatus:SetText("刷新失败：" .. tostring(refreshErr or "未执行")) end
            return ok, refreshErr
        end
        craftQuoteButton.onClick = function()
            if type(feature.Commands.QuotePendingMaterials) ~= "function" then return false, "材料批量询价命令不可用" end
            local ok, quoteMessage = feature.Commands:QuotePendingMaterials()
            if craftActionStatus ~= nil then craftActionStatus:SetText(ok == true and tostring(quoteMessage or "询价已提交") or ("询价失败：" .. tostring(quoteMessage or "未执行"))) end
            if ok == true then root:Refresh() end
            return ok, quoteMessage
        end
        if id == "life_craft_planner" then
            local planQtyValue = 1
            local planActions = RSUI:HorizontalBox({ id = "v3_business_life_craft_planner_plan_actions", parent = root, gap = 5,
                slot = { size = "fixed", height = 31, hAlign = "fill" } })
            RSUI:Text({ id = "v3_business_life_craft_planner_plan_label", parent = planActions, text = "制作计划", fontSize = 9, tone = "strong",
                slot = { size = "fixed", width = 58 } })
            craftPlanQtyInput = TrackField(RSUI:NumericInput({ id = "v3_business_life_craft_planner_plan_qty", parent = planActions,
                value = 1, min = 1, max = 999, step = 1, integer = true, width = 64,
                get = function() return planQtyValue end,
                set = function(value) planQtyValue = math.max(1, math.min(999, math.floor((tonumber(value) or 1) + 0.5))); return true end,
                slot = { size = "fixed", width = 64 } }))
            local addPlan = RSUI:Button({ id = "v3_business_life_craft_planner_plan_add", parent = planActions, text = "加入计划", compact = true,
                slot = { size = "fixed", width = 72 } })
            craftPlanRemoveButton = RSUI:Button({ id = "v3_business_life_craft_planner_plan_remove", parent = planActions, text = "移除选中", compact = true, enabled = false,
                slot = { size = "fixed", width = 78 } })
            local clearPlan = RSUI:Button({ id = "v3_business_life_craft_planner_plan_clear", parent = planActions, text = "清空", compact = true,
                slot = { size = "fixed", width = 52 } })
            craftPlanQuoteButton = RSUI:Button({ id = "v3_business_life_craft_planner_plan_quote", parent = planActions, text = "计划询价", compact = true, enabled = false,
                slot = { size = "fixed", width = 76 } })
            craftPlanStatus = RSUI:Text({ id = "v3_business_life_craft_planner_plan_status", parent = root,
                text = "从上方选择制作物，设置数量后加入计划；同一制作物会合并数量。", fontSize = 8, tone = "muted", overflow = "wrap", maxLines = 2,
                slot = { size = "fixed", height = 28, hAlign = "fill" } })
            craftPlanTable = RSUI:TableView({ id = "v3_business_life_craft_planner_plan_table", parent = root, items = {},
                rowHeight = 26, headerHeight = 25, desiredRows = 5, overscan = 1, scrollbar = true, selectable = true,
                columnResize = false, headerInteractive = false,
                getKey = function(item) return item and item.key or nil end,
                onSelectionChanged = function(index)
                    craftPlanSelectedIndex = tonumber(index)
                    if craftPlanRemoveButton ~= nil then craftPlanRemoveButton:SetEnabled(craftPlanSelectedIndex ~= nil) end
                end,
                columns = {
                    { id = "name", title = "计划制作物", field = "name", size = "fill", minWidth = 180, fill = 1.7 },
                    { id = "quantity", title = "数量", field = "quantity", size = "fixed", width = 58, minWidth = 48 },
                    { id = "materialCount", title = "材料项", field = "materialCount", size = "fixed", width = 62, minWidth = 54 },
                },
                slot = { size = "fixed", height = 158, hAlign = "fill" },
            })
            addPlan.onClick = function()
                if type(feature.Commands.AddPlanRecipe) ~= "function" then return false, "多配方计划命令不可用" end
                local projection = feature:GetProjection() or {}
                local key = projection.selectedRecipeKey
                local quantity = craftPlanQtyInput ~= nil and craftPlanQtyInput:GetValue() or planQtyValue
                local ok, addErr = feature.Commands:AddPlanRecipe(key, quantity)
                if craftPlanStatus ~= nil then craftPlanStatus:SetText(ok == true and "已加入制作计划" or ("加入失败：" .. tostring(addErr or "未执行"))) end
                if ok == true then root:Refresh() end
                return ok, addErr
            end
            craftPlanRemoveButton.onClick = function()
                local projection = feature:GetProjection() or {}
                local row = type(projection.planRecipeRows) == "table" and projection.planRecipeRows[tonumber(craftPlanSelectedIndex) or 0] or nil
                if type(row) ~= "table" or row.recipeKey == nil then return false, "请先选择计划中的制作物" end
                local ok, removeErr = feature.Commands:RemovePlanRecipe(row.recipeKey)
                if ok == true then craftPlanSelectedIndex = nil; root:Refresh() end
                if craftPlanStatus ~= nil then craftPlanStatus:SetText(ok == true and "已从计划移除" or ("移除失败：" .. tostring(removeErr or "未执行"))) end
                return ok, removeErr
            end
            clearPlan.onClick = function()
                local ok, clearErr = feature.Commands:ClearPlan()
                if ok == true then craftPlanSelectedIndex = nil; root:Refresh() end
                if craftPlanStatus ~= nil then craftPlanStatus:SetText(ok == true and "制作计划已清空" or ("清空失败：" .. tostring(clearErr or "未执行"))) end
                return ok, clearErr
            end
            craftPlanQuoteButton.onClick = function()
                if type(feature.Commands.QuotePlanMaterials) ~= "function" then return false, "计划材料询价命令不可用" end
                local ok, message = feature.Commands:QuotePlanMaterials()
                if craftPlanStatus ~= nil then craftPlanStatus:SetText(ok == true and tostring(message or "计划询价已提交") or ("计划询价失败：" .. tostring(message or "未执行"))) end
                if ok == true then root:Refresh() end
                return ok, message
            end
        elseif id == "tools_craft" and type(feature.Commands.SetAutoSidecar) == "function" then
            local sidecarRow = RSUI:HorizontalBox({ id = "v3_business_tools_craft_sidecar_row", parent = root, gap = 6,
                slot = { size = "fixed", height = 31, hAlign = "fill" } })
            TrackField(RSUI:Toggle({ id = "v3_business_tools_craft_auto_sidecar", parent = sidecarRow,
                onText = "制作台侧窗：自动", offText = "制作台侧窗：关闭",
                get = function() return (feature:GetProjection() or {}).autoSidecar ~= false end,
                set = function(value) return feature.Commands:SetAutoSidecar(value == true) end,
                slot = { size = "fixed", width = 142 } }))
            RSUI:Text({ id = "v3_business_tools_craft_sidecar_hint", parent = sidecarRow,
                text = "只观察原生制作窗口；打开时显示材料侧窗，普通刷新不会后台询价。", fontSize = 8, tone = "muted", overflow = "ellipsis",
                slot = { size = "fill", fill = 1 } })
        end
    end
    local bagQuickStatus, blacklistStatus, blacklistToggle, blacklistPicker, itemInput
    local selectedBlacklistItem = nil
    if id == "tools_bag" then
        RSUI:Text({ id="v3_business_tools_bag_quick_title", parent=root,
            text="快速整理", fontSize=10, tone="strong", overflow="ellipsis",
            slot={size="fixed",height=22,hAlign="fill"} })
        local quickRow = RSUI:HorizontalBox({ id="v3_business_tools_bag_quick_row", parent=root, gap=8,
            slot={size="fixed",height=36,hAlign="fill"} })
        -- Product page mirrors the floating surface but uses explicit wording.
        -- Same-button stop / other-button switch remains owned by tools_bag.
        local quickTake=RSUI:Button({ id="v3_business_tools_bag_quick_take", parent=quickRow, text="取出同类", compact=true, slot={size="fixed",width=118} })
        local quickPut=RSUI:Button({ id="v3_business_tools_bag_quick_put", parent=quickRow, text="存入同类", compact=true, slot={size="fixed",width=118} })
        RSUI:Text({ id="v3_business_tools_bag_quick_help", parent=quickRow,
            text="只移动背包与当前仓储两边都存在的同类物品。", fontSize=8, tone="muted", overflow="wrap", maxLines=2,
            slot={size="fill",fill=1,minWidth=180} })
        bagQuickStatus=RSUI:Text({ id="v3_business_tools_bag_quick_status", parent=root,
            text="当前：请先打开银行或保管箱。", fontSize=8, tone="muted", overflow="wrap", maxLines=2,
            slot={size="auto",minHeight=22,hAlign="fill"} })
        local function Quick(command)
            local fn=feature.Commands[command]; if type(fn)~="function" then return false,"快捷取放命令不可用" end
            local ok,result=fn(feature.Commands)
            if ok~=true and bagQuickStatus~=nil then bagQuickStatus:SetText("操作失败："..tostring(result or "未执行")) end
            root:Refresh(); return ok,result
        end
        quickTake.onClick=function() return Quick("QuickWithdraw") end
        quickPut.onClick=function() return Quick("QuickDeposit") end
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
            -- Lua 5.1 generic-for control variables are shared by closures.
            -- Capture stable locals so buttons cannot collapse onto the final
            -- Unmute command after the loop exits.
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
                -- Info commands (查好友) report a fact instead of a write
                -- acknowledgement and do not dirty the authority.
                socialStatus:SetText(textRef .. "：" .. tostring(result or "已执行"))
                if actionSpec.holdRefresh ~= true then feature.Commands:Refresh("social_" .. commandRef); root:Refresh() end
                return true, nil
            end
        end
    end

    local function SetBlacklistStatus(text, tone)
        if blacklistStatus ~= nil then
            blacklistStatus:SetText(tostring(text or ""))
            if S.Theme ~= nil and type(S.Theme.SetLabelTone) == "function" then S.Theme:SetLabelTone(blacklistStatus, tone or "muted") end
        end
    end
    if id == "tools_bag" then
        RSUI:Text({ id = "v3_business_tools_bag_blacklist_title", parent = root, text = "整理黑名单", fontSize = 10,
            tone = "strong", overflow = "ellipsis", slot = { size = "fixed", height = 22, hAlign = "fill" } })
        blacklistStatus = RSUI:Text({ id = "v3_business_tools_bag_blacklist_status", parent = root,
            text = "加入黑名单的物品不会参与取出或存入。", fontSize = 8, tone = "muted", overflow = "wrap", maxLines = 2,
            slot = { size = "auto", minHeight = 22, hAlign = "fill" } })

        local addRow = RSUI:HorizontalBox({ id = "v3_business_tools_bag_blacklist_add_row", parent = root, gap = 6,
            slot = { size = "fixed", height = 31, hAlign = "fill" } })
        itemInput = RSUI:TextInput({ id = "v3_business_tools_bag_blacklist_item_input", parent = addRow, value = "", maxLength = 96,
            allowEmpty = true, submitOnLostFocus = false, placeholder = "输入物品ID或当前背包/仓储中的物品名称",
            slot = { size = "fill", fill = 1, minWidth = 220 } })
        local addItemButton = RSUI:Button({ id = "v3_business_tools_bag_blacklist_item_add", parent = addRow, text = "加入黑名单", compact = true,
            slot = { size = "fixed", width = 96 } })
        blacklistToggle = RSUI:Button({ id = "v3_business_tools_bag_blacklist_toggle", parent = addRow, text = "黑名单：开", compact = true,
            slot = { size = "fixed", width = 82 } })

        local listRow = RSUI:HorizontalBox({ id = "v3_business_tools_bag_blacklist_list_row", parent = root, gap = 6,
            slot = { size = "fixed", height = 31, hAlign = "fill" } })
        RSUI:Text({ id = "v3_business_tools_bag_blacklist_list_label", parent = listRow, text = "当前黑名单", fontSize = 9,
            tone = "strong", overflow = "ellipsis", slot = { size = "fixed", width = 72 } })
        blacklistPicker = RSUI:Dropdown({ id = "v3_business_tools_bag_blacklist_picker", parent = listRow, items = {}, maxVisible = 8, popupWidth = 320,
            get = function() return selectedBlacklistItem end,
            set = function(value) selectedBlacklistItem = value ~= nil and tostring(value) or nil; return true end,
            placeholder = "暂无黑名单物品", slot = { size = "fill", fill = 1, minWidth = 220 } })
        local removeItemButton = RSUI:Button({ id = "v3_business_tools_bag_blacklist_item_remove", parent = listRow, text = "删除选中", compact = true,
            slot = { size = "fixed", width = 82 } })

        RSUI:Text({ id = "v3_business_tools_bag_blacklist_help", parent = root,
            text = "也可以直接点击下方“当前背包物品”中的一行，物品ID会自动填入上面的输入框。名称搜索只在你主动添加时读取当前背包和已打开的仓储，不会后台扫描。",
            fontSize = 8, tone = "muted", overflow = "wrap", maxLines = 2,
            slot = { size = "auto", minHeight = 26, hAlign = "fill" } })

        addItemButton.onClick = function()
            local query = itemInput ~= nil and type(itemInput.GetDraftValue) == "function" and tostring(itemInput:GetDraftValue() or "") or ""
            local command = feature.Commands.ResolveAndAddBlacklistItem
            if type(command) ~= "function" then SetBlacklistStatus("添加失败：黑名单匹配命令不可用", "warn"); return false, "黑名单匹配命令不可用" end
            local ok, result = command(feature.Commands, query)
            if ok ~= true then SetBlacklistStatus("添加失败：" .. tostring(result or "未执行"), "warn"); return false, result end
            if itemInput ~= nil and type(itemInput.SetValue) == "function" then itemInput:SetValue("", false, "bag_blacklist_add_success") end
            root:Refresh()
            SetBlacklistStatus("已加入黑名单；对银行和保管箱同时生效。", "success")
            return true
        end
        blacklistToggle.onClick = function()
            local projection = feature:GetProjection() or {}
            local config = type(projection.blacklist) == "table" and projection.blacklist or {}
            local ok, result = feature.Commands:SetBlacklistEnabled(config.enabled ~= true)
            if ok ~= true then SetBlacklistStatus("设置失败：" .. tostring(result or "未执行"), "warn"); return false, result end
            root:Refresh(); return true
        end
        removeItemButton.onClick = function()
            if selectedBlacklistItem == nil or tostring(selectedBlacklistItem) == "" then
                SetBlacklistStatus("请先从“当前黑名单”选择一个物品。", "warn"); return false, "未选择黑名单物品"
            end
            local command = feature.Commands.RemoveGlobalBlacklistItem
            if type(command) ~= "function" then SetBlacklistStatus("删除失败：黑名单删除命令不可用", "warn"); return false, "黑名单删除命令不可用" end
            local ok, result = command(feature.Commands, selectedBlacklistItem)
            if ok ~= true then SetBlacklistStatus("删除失败：" .. tostring(result or "未执行"), "warn"); return false, result end
            selectedBlacklistItem = nil
            root:Refresh()
            SetBlacklistStatus("已从整理黑名单删除。", "success")
            return true
        end

        function root:RefreshBlacklistEditor(projection)
            local config = type(projection) == "table" and projection.blacklist or nil
            config = type(config) == "table" and config or {}
            local enabledNow = config.enabled == true
            local options = type(projection.blacklistOptions) == "table" and projection.blacklistOptions or {}
            blacklistToggle:SetText(enabledNow and "黑名单：开" or "黑名单：关")
            if type(blacklistPicker.SetItems) == "function" then blacklistPicker:SetItems(options) else blacklistPicker.items = options end
            if selectedBlacklistItem ~= nil then
                local found = false
                for _, option in ipairs(options) do if tostring(option.value or "") == tostring(selectedBlacklistItem) then found = true; break end end
                if found ~= true then selectedBlacklistItem = nil end
            end
            if type(blacklistPicker.Render) == "function" then blacklistPicker:Render() end
            local legacyCount = math.max(0, tonumber(projection.blacklistLegacyCategoryCount) or 0)
            local suffix = legacyCount > 0 and (" · 兼容旧分类规则 " .. tostring(legacyCount) .. " 项仍生效") or ""
            SetBlacklistStatus((enabledNow and "黑名单保护已开启" or "黑名单保护已关闭") .. " · 物品 " .. tostring(#options) .. " 项" .. suffix,
                enabledNow and "muted" or "warn")
        end
    end
    local teamRoleInput, teamActionStatus, teamAutoRoleButton, teamExtra
    if id == "combat_team_tools" then
        -- 中文维护注释（2026-09-10，团队中心布局）：旧版把“职责、两个已禁用的成员移动表单、牺牲之舞/头标”连续堆在同一层，既占据大量垂直空间，也让不可执行的 Native 写能力看起来像可配置功能。这里仅重组 Presentation：v3.team_tools 继续拥有职责/自动职责 Authority，v3.team_visuals 继续拥有牺牲之舞与头标 Store/Consumer；成员移动命令仍保留在 Domain 并 fail-closed，等未来获得合法队长权限 getter 后再单独恢复 UI。禁止以后为了“把按钮放回来”绕过 Domain 权限安全门。
        local roleGroup = RSUI:GroupBox({ id = "v3_business_combat_team_tools_role_group", parent = root, title = "职责设置", variant = "soft", gap = 5, padding = 8,
            slot = { size = "auto", hAlign = "fill" } }) -- 中文维护注释：GroupBox 使用 RSUI 布局而非手算像素，窗口缩放/不同分辨率由 Measure/Arrange 统一处理，避免 1280×768 下控件挤压。
        local roleInner = RSUI:VerticalBox({ id = "v3_business_combat_team_tools_role_inner", parent = roleGroup, gap = 5 }) -- 中文维护注释：职责组内部只承载当前玩家可执行的设置；全队职责表仍是只读投影，不与写入控件共享 Authority。
        local roleRow = RSUI:HorizontalBox({ id = "v3_business_combat_team_tools_role_row", parent = roleInner, gap = 6,
            slot = { size = "fixed", height = 31, hAlign = "fill" } })
        RSUI:Text({ id = "v3_business_combat_team_tools_role_label", parent = roleRow, text = "我的职责", fontSize = 9, tone = "strong",
            overflow = "ellipsis", slot = { size = "fixed", width = 58 } })
        local roleProjection = feature:GetProjection() or {} -- 中文维护注释：下拉选项只读取 Feature detached projection，不直接调用 X2Team；Native 读写仍集中在 TeamTools Domain。
        local roleItems = {}
        for _, item in ipairs(type(roleProjection.roleOptions) == "table" and roleProjection.roleOptions or {}) do
            roleItems[#roleItems + 1] = { value = item.value, text = tostring(item.text or item.key or item.value) }
        end
        local teamRoleValue = nil
        teamRoleInput = RSUI:Dropdown({ id = "v3_business_combat_team_tools_role_input", parent = roleRow, items = roleItems, maxVisible = 5,
            get = function() return teamRoleValue end, set = function(value) teamRoleValue = value; return true end,
            placeholder = #roleItems > 0 and "选择职责" or "职责不可用", slot = { size = "fixed", width = 126 } })
        local setRoleButton = RSUI:Button({ id = "v3_business_combat_team_tools_set_role", parent = roleRow, text = "设置我的职责", compact = true,
            slot = { size = "fixed", width = 96 } })
        teamAutoRoleButton = RSUI:Button({ id = "v3_business_combat_team_tools_auto_role", parent = roleRow, text = "自动职责：开", compact = true,
            slot = { size = "fixed", width = 108 } }) -- 中文维护注释：初始文案与 Domain 新安装默认 true 对齐；Refresh 仍以 projection 为最终事实，旧用户保存 false 不会被 UI 初始文字反向写入。
        local roleStatus = RSUI:Text({ id = "v3_business_combat_team_tools_role_status", parent = roleInner,
            text = "自动职责默认开启；进入团队或职业组合变化后按已验证职业表匹配。", fontSize = 8, tone = "muted", overflow = "wrap", maxLines = 2,
            slot = { size = "auto", minHeight = 20, hAlign = "fill" } }) -- 中文维护注释：这是只读说明/状态文本，不参与 Store，避免把运行时识别结果误写成永久配置。

        teamExtra = {}
        local assistGroup = RSUI:GroupBox({ id = "v3_business_combat_team_tools_assist_group", parent = root, title = "团队辅助", variant = "soft", gap = 5, padding = 8,
            slot = { size = "auto", hAlign = "fill" } }) -- 中文维护注释：团队视觉辅助与职责写入分组，明确它们由不同子 Authority 管理；分组本身不获取额外 Consumer。
        local assistInner = RSUI:VerticalBox({ id = "v3_business_combat_team_tools_assist_inner", parent = assistGroup, gap = 5 })
        local visualRow = RSUI:HorizontalBox({ id = "v3_business_combat_team_tools_visual_row", parent = assistInner, gap = 6,
            slot = { size = "fixed", height = 31, hAlign = "fill" } })
        teamExtra.sacButton = RSUI:Button({ id = "v3_business_combat_team_tools_sac_toggle", parent = visualRow, text = "牺牲之舞：开", compact = true,
            slot = { size = "fixed", width = 108 } }) -- 中文维护注释：仅默认显示“开”；真实状态由 TeamVisuals Store schema2 projection 刷新，旧 schema1 的关闭状态会立即显示回“关”。
        teamExtra.saveMarks = RSUI:Button({ id = "v3_business_combat_team_tools_mark_save", parent = visualRow, text = "保存头标", compact = true,
            slot = { size = "fixed", width = 78 } })
        teamExtra.restoreMarks = RSUI:Button({ id = "v3_business_combat_team_tools_mark_restore", parent = visualRow, text = "恢复头标", compact = true,
            slot = { size = "fixed", width = 78 } })
        teamExtra.clearMarks = RSUI:Button({ id = "v3_business_combat_team_tools_mark_clear", parent = visualRow, text = "清空保存", compact = true,
            slot = { size = "fixed", width = 78 } })
        teamExtra.status = RSUI:Text({ id = "v3_business_combat_team_tools_visual_status", parent = assistInner,
            text = "牺牲之舞高亮默认开启 · 尚未保存团队头标", fontSize = 8, tone = "muted", overflow = "wrap", maxLines = 2,
            slot = { size = "auto", minHeight = 22, hAlign = "fill" } }) -- 中文维护注释：只展示 TeamVisuals detached projection，不进行 Aura/Marker Native 读取；高频事实仍由共享 Service + 按需 Consumer 提供。

        teamActionStatus = RSUI:Text({ id = "v3_business_combat_team_tools_action_status", parent = root,
            text = "全队职责只读；职责写入只作用于当前玩家。成员移动因缺少合法队长权限读取契约继续安全停用。", fontSize = 8, tone = "muted", overflow = "wrap", maxLines = 2,
            slot = { size = "auto", minHeight = 24, hAlign = "fill" } }) -- 中文维护注释：用一条明确能力说明替代两组永久禁用输入框，减少视觉噪声；Domain 的 MoveMember/MoveMemberToParty 仍存在并拒绝执行，兼容未来功能恢复与旧调用方。

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
        teamAutoRoleButton.onClick = function()
            local projection = feature:GetProjection() or {} -- 中文维护注释：按钮切换以前一份 Feature projection 为事实，不使用本地按钮文案推断状态，避免 UI 与 Store 脱节。
            local nextValue = projection.autoRoleEnabled == false
            local ok, err = feature.Commands:SetAutoRoleEnabled(nextValue) -- 中文维护注释：写入必须经过 TeamTools PersistStateMutation；Presentation 不直接改 State/SaveData。
            if ok ~= true then SetTeamActionStatus("自动职责设置失败：" .. tostring(err or "未执行"), "warn"); return false, err end
            root:Refresh()
            SetTeamActionStatus(nextValue and "自动职责已开启；进团或切换职业后会按职业组合自动匹配" or "自动职责已关闭", nextValue and "success" or "muted")
            return true
        end
        setRoleButton.onClick = function()
            local role = teamRoleInput and type(teamRoleInput.GetValue) == "function" and teamRoleInput:GetValue() or nil
            if role == nil then local valueErr = "请选择职责"; SetTeamActionStatus("失败：" .. valueErr, "warn"); return false, valueErr end
            local ok, err = feature.Commands:SetRole(role) -- 中文维护注释：X2Team:SetRole 的 Native 写 Authority 仍在 Domain ActionCapability；页面只提交已验证 TMROLE 枚举。
            if ok ~= true then SetTeamActionStatus("失败：" .. tostring(err or "职责设置未执行"), "warn"); return false, err end
            local refreshed, refreshErr = RefreshTeamAction("team_tools_set_role")
            if refreshed ~= true then SetTeamActionStatus(refreshErr, "warn"); return false, refreshErr end
            SetTeamActionStatus("当前玩家职责设置成功", "success"); return true
        end
        teamExtra.sacButton.onClick = function()
            local projection = feature:GetProjection() or {} -- 中文维护注释：牺牲之舞开关只消费 TeamVisuals projection；候选扫描/Aura 事实不由页面直接读取。
            local nextValue = projection.sacEnabled ~= true
            local ok, err = feature.Commands:SetSacHighlightEnabled(nextValue) -- 中文维护注释：生命周期由 TeamVisuals 在开关变更后获取/释放 Consumer；隐藏页面不等于关闭功能。
            if ok ~= true then SetTeamActionStatus("牺牲之舞高亮设置失败：" .. tostring(err or "未执行"), "warn"); return false, err end
            root:Refresh()
            SetTeamActionStatus(nextValue and "牺牲之舞高亮已开启；仅扫描舞乐候选成员" or "牺牲之舞高亮已关闭并释放团队/Aura观察", nextValue and "success" or "muted")
            return true
        end
        teamExtra.saveMarks.onClick = function()
            local ok, countOrErr = feature.Commands:SaveRaidMarkers() -- 中文维护注释：头标快照通过 Domain 读 Native 并 durable 保存；UI 不缓存 marker identity。
            if ok ~= true then SetTeamActionStatus("保存头标失败：" .. tostring(countOrErr or "未执行"), "warn"); return false, countOrErr end
            root:Refresh(); SetTeamActionStatus("已保存当前团队头标：" .. tostring(countOrErr or 0) .. " 个", "success"); return true
        end
        teamExtra.restoreMarks.onClick = function()
            local ok, countOrErr = feature.Commands:RestoreRaidMarkers() -- 中文维护注释：恢复仍由 1100ms 串行队列 + 读回验证治理，布局改动绝不能改成循环瞬发 Native 写入。
            if ok ~= true then SetTeamActionStatus("恢复头标失败：" .. tostring(countOrErr or "未执行"), "warn"); return false, countOrErr end
            root:Refresh(); SetTeamActionStatus("头标恢复队列已启动：" .. tostring(countOrErr or 0) .. " 个；按官方 1 秒冷却串行执行", "success"); return true
        end
        teamExtra.clearMarks.onClick = function()
            local ok, err = feature.Commands:ClearSavedRaidMarkers() -- 中文维护注释：只清插件 Store 中的快照，不调用 Native 清除当前游戏头标，保持用户可逆性。
            if ok ~= true then SetTeamActionStatus("清空保存失败：" .. tostring(err or "未执行"), "warn"); return false, err end
            root:Refresh(); SetTeamActionStatus("已清空插件保存的头标方案；不会清除当前游戏头标", "muted"); return true
        end
        if #roleItems <= 0 then teamRoleInput:SetEnabled(false); setRoleButton:SetEnabled(false) end -- 中文维护注释：客户端 TMROLE 枚举不可用时 fail-closed，只禁用职责写 UI，不影响团队名单只读投影。
        SetTeamActionStatus("全队职责只读；仅可设置当前玩家职责。成员移动等待合法队长/权限读取契约", "muted")
        teamExtra.roleStatus = roleStatus -- 中文维护注释：保留引用供 Refresh 更新自动职责运行说明；只属于当前页面生命周期，不跨重载持久化。
    end
    local tableView
    local tableParent = unitLineSettingsPage and unitLineDiagnostics and unitLineDiagnostics.content or root
    local tableDesiredRows = unitLineSettingsPage and 5 or 14
    local tableSlot = unitLineSettingsPage
        and { size = "auto", minHeight = 150, hAlign = "fill" }
        or { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" }
    tableView = RSUI:TableView({ id = "v3_business_" .. id .. "_table", parent = tableParent, items = {}, rowHeight = 26, headerHeight = 27, desiredRows = tableDesiredRows, scrollbar = true, selectable = id == "tools_bag" or id == "tools_auction" or id == "tools_market_analysis" or id == "tools_social", selectionMode = "single", columnResize = true,
        columns = id == "tools_bag" and {
            { id = "name", title = "当前背包物品（ID · 名称）", field = "name", size = "fill", minWidth = 300 },
            { id = "status", title = "数量", field = "statusText", size = "fixed", width = 82, minWidth = 64, getTone = function(item) return item and item.tone or "muted" end },
        } or id == "combat_team_tools" and { -- 中文维护注释：团队职责行没有 craft cost 语义；使用专用三列避免“成本/持有/缺口”空列长期浪费宽度。只改变 detached row 的 Presentation 映射，ReadTeamRoleRoster 数据结构/Authority 不变。
            { id = "name", title = "团队成员", field = "name", size = "fixed", width = 180, minWidth = 120 }, -- 中文维护注释：成员名固定列保证 1280×768 仍有足够职责说明空间；不缓存 Unit 对象或身份指针。
            { id = "text", title = "位置 / 职责", field = "text", size = "fill", minWidth = 260 }, -- 中文维护注释：复用 Domain 已生成的 team/member/role 文本，不在 Table 渲染循环重复调用 X2Team:GetRole。
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
    if id == "tools_bag" then
        tableView.onSelectionChanged = function(index)
            local row = tableView:GetItem(index)
            if row == nil or row.itemType == nil then return end
            if itemInput ~= nil and type(itemInput.SetValue) == "function" then
                itemInput:SetValue(tostring(row.itemType), false, "bag_item_row_select")
            end
            SetBlacklistStatus("已选择：" .. tostring(row.name or row.itemType) .. "；点击“加入黑名单”即可。", "muted")
        end
    end
    if id == "tools_auction" then
        tableView.onSelectionChanged = function(index)
            local row = tableView:GetItem(index)
            auctionSelectedIndex = row and row.favoriteIndex or nil
            auctionRemoveArm = nil
            if auctionRemoveButton ~= nil then auctionRemoveButton:SetText("删除收藏") end
            auctionQuoteRow = (row ~= nil and row.kind == "result") and row or nil
            if auctionQuoteButton ~= nil and type(auctionQuoteButton.SetEnabled) == "function" then
                auctionQuoteButton:SetEnabled(auctionQuoteRow ~= nil and auctionQuoteRow.itemType ~= nil)
            end
            if row ~= nil and row.kind == "favorite" and auctionKeywordInput ~= nil and type(auctionKeywordInput.SetValue) == "function" then
                auctionKeywordInput:SetValue(tostring(row.name or ""), false, "auction_favorite_select")
                if auctionStatus ~= nil then auctionStatus:SetText("已载入收藏关键词，点击“查询当前挂单”即可搜索。") end
            elseif row ~= nil and row.kind == "result" and row.name ~= nil and auctionKeywordInput ~= nil and type(auctionKeywordInput.SetValue) == "function" then
                auctionKeywordInput:SetValue(tostring(row.name), false, "auction_result_select")
                if auctionStatus ~= nil then auctionStatus:SetText("已载入结果名称，可直接“加入收藏”或“结果询价”。") end
            end
        end
    end
    if id == "tools_social" then
        -- Clicking a list row loads that member name into the action input;
        -- unrecognized-shape placeholder rows (memberName == nil) are inert.
        tableView.onSelectionChanged = function(index)
            local row = tableView:GetItem(index)
            if row == nil or row.memberName == nil then return end
            if socialInput ~= nil and type(socialInput.SetValue) == "function" then
                socialInput:SetValue(tostring(row.memberName), false, "social_row_select")
            end
            if socialStatus ~= nil then socialStatus:SetText("已载入 " .. tostring(row.memberName) .. "（" .. tostring(row.listKind or "名单") .. "），可执行显式名单操作。") end
        end
    end
    function root:Refresh()
        local projection = feature:GetProjection() or {}
        local rows = id == "tools_bag" and (projection.bagItemRows or {}) or (projection.rows or {})
        for _, field in ipairs(specialFields) do if type(field.Render) == "function" then field:Render() end end
        if (id == "tools_auction" or id == "tools_market_analysis") and self.RefreshAuctionPaging then self:RefreshAuctionPaging(projection, tableView) else tableView:SetItems(rows, projection.revision or 0) end
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
        if id == "life_craft_planner" or id == "tools_craft" then
            local craft = type(projection.craft) == "table" and projection.craft or {}
            local craftStatus = tostring(craft.status or projection.status or "empty")
            local craftError = craft.error or projection.error
            if craftRecipeDropdown ~= nil then
                craftRecipeDropdown.items = type(projection.recipeOptions)=="table" and projection.recipeOptions or {}
                if type(craftRecipeDropdown.Render)=="function" then craftRecipeDropdown:Render() end
            end
            local statusZh = ({ ready="可用", partial="部分可用", empty="等待选择", unavailable="不可用", failed="读取失败", idle="等待选择" })[craftStatus] or craftStatus
            local pendingQuotes = math.max(0, tonumber(projection.pendingQuoteCount) or 0)
            if craftQuoteButton ~= nil then
                craftQuoteButton:SetEnabled(S.FeatureRuntime:IsEnabled(id) == true and pendingQuotes > 0)
                craftQuoteButton:SetText(pendingQuotes > 0 and ("询价(" .. tostring(pendingQuotes) .. ")") or "材料询价")
            end
            local costText = ""
            if (tonumber(projection.pricedMaterialCount) or 0) > 0 then
                local rawCost = tonumber(projection.quotedMaterialCostCopper) or 0
                local cost = tostring(math.floor(rawCost + 0.5))
                if S.Utils ~= nil and type(S.Utils.FormatMoney) == "function" then
                    local okMoney, moneyText = pcall(S.Utils.FormatMoney, rawCost)
                    if okMoney == true and type(moneyText) == "string" and moneyText ~= "" then cost = moneyText end
                end
                costText = " · 已报价材料 " .. tostring(projection.pricedMaterialCount) .. " 项 / 当前小计 " .. cost
            end
            if pendingQuotes > 0 then costText = costText .. " · 待询价 " .. tostring(pendingQuotes) .. " 项" end
            if craftActionStatus ~= nil then
                craftActionStatus:SetText(craftError and (statusZh .. "：" .. tostring(craftError)) or (statusZh .. " · " .. tostring(#rows) .. " 条材料/产物信息" .. costText))
                if S.Theme ~= nil and type(S.Theme.SetLabelTone) == "function" then S.Theme:SetLabelTone(craftActionStatus, craftError and "warn" or "muted") end
            end
            if id == "life_craft_planner" and craftPlanTable ~= nil then
                local planRows = type(projection.planRecipeRows) == "table" and projection.planRecipeRows or {}
                craftPlanTable:SetItems(planRows, "craft-plan:" .. tostring(projection.revision or 0) .. ":" .. tostring(#planRows))
                if #planRows == 0 then
                    craftPlanTable:SetViewState("empty", { title = "制作计划为空", detail = "选择制作物和数量后点击“加入计划”。" })
                    craftPlanSelectedIndex = nil
                else
                    craftPlanTable:SetViewState("ready")
                    if craftPlanSelectedIndex ~= nil and planRows[craftPlanSelectedIndex] == nil then craftPlanSelectedIndex = nil end
                end
                if craftPlanRemoveButton ~= nil then craftPlanRemoveButton:SetEnabled(craftPlanSelectedIndex ~= nil) end
                local planPending = math.max(0, tonumber(projection.planPendingQuoteCount) or 0)
                if craftPlanQuoteButton ~= nil then
                    craftPlanQuoteButton:SetEnabled(S.FeatureRuntime:IsEnabled(id) == true and planPending > 0)
                    craftPlanQuoteButton:SetText(planPending > 0 and ("计划询价(" .. tostring(planPending) .. ")") or "计划询价")
                end
                if craftPlanStatus ~= nil then
                    local planCost = tonumber(projection.planQuotedRequiredCostCopper) or 0
                    local shortageCost = tonumber(projection.planQuotedShortageCostCopper) or 0
                    local costLabel, shortageLabel = tostring(math.floor(planCost + 0.5)), tostring(math.floor(shortageCost + 0.5))
                    if S.Utils ~= nil and type(S.Utils.FormatMoney) == "function" then
                        local okTotal, totalText = pcall(S.Utils.FormatMoney, planCost)
                        local okShort, shortText = pcall(S.Utils.FormatMoney, shortageCost)
                        if okTotal == true and type(totalText) == "string" and totalText ~= "" then costLabel = totalText end
                        if okShort == true and type(shortText) == "string" and shortText ~= "" then shortageLabel = shortText end
                    end
                    craftPlanStatus:SetText("计划 " .. tostring(projection.planRecipeCount or 0) .. " 项 · 聚合材料 " .. tostring(projection.planMaterialCount or 0)
                        .. " · 待询价 " .. tostring(planPending)
                        .. ((tonumber(projection.planPricedMaterialCount) or 0) > 0 and (" · 总需求 " .. costLabel .. " · 当前缺口 " .. shortageLabel) or ""))
                end
            end
        end
        if id == "tools_bag" and type(self.RefreshBlacklistEditor) == "function" then self:RefreshBlacklistEditor(projection) end
        if id == "tools_bag" and bagQuickStatus ~= nil then
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
        end
        if id == "combat_team_tools" and teamAutoRoleButton ~= nil then
            teamAutoRoleButton:SetText(projection.autoRoleEnabled == false and "自动职责：关" or "自动职责：开") -- 中文维护注释：投影是显示 Authority，旧用户显式 false 会覆盖初始“开”文案；这里不触发任何持久化写入。
            if type(teamExtra) == "table" and teamExtra.roleStatus ~= nil then
                local roleRuntime = tostring(projection.autoRoleStatus or "等待团队/职业变化") -- 中文维护注释：运行状态来自 TeamTools Domain 的事件驱动结果，页面只做文本投影，不额外轮询职业或团队名单。
                local roleLabel = projection.autoRoleLabel and (" · 识别：" .. tostring(projection.autoRoleLabel)) or ""
                teamExtra.roleStatus:SetText((projection.autoRoleEnabled == false and "自动职责已关闭" or "自动职责已开启") .. " · " .. roleRuntime .. roleLabel)
            end
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
        elseif id == "tools_bag" then
            if enabled ~= true then
                hint:SetText("功能已关闭；黑名单配置会保留，重新启用后继续生效。")
            else
                local storage = projection.batchTargetResolved == "coffer" and "保管箱" or (projection.batchTargetResolved == "bank" and "银行" or nil)
                hint:SetText(storage ~= nil
                    and ("已连接" .. storage .. " · 取出同类 / 存入同类 · 当前背包可识别物品 " .. tostring(#rows) .. " 种")
                    or ("打开银行或保管箱后即可整理同类物品 · 当前背包可识别物品 " .. tostring(#rows) .. " 种"))
            end
        elseif projection.status == "runtime_blocked" then
            hint:SetText("运行时阻塞：" .. tostring(projection.error or (meta and meta.runtimeBlocker) or "未说明") .. "\n当前实现：页面与生命周期已接入；剩余能力需 RU 实机/API 契约证据后才能继续。")
        elseif enabled and (projection.status == "partial" or (meta and meta.status == "migrated_partial")) then
            local detail = projection.error or (meta and meta.remainingCapability) or "部分能力仍待验证"
            hint:SetText("部分可用 · " .. tostring(#rows) .. " 条投影 · " .. tostring(detail))
        else
            hint:SetText(enabled and (BusinessStatusText(projection.status) .. " · " .. tostring(#rows) .. " 条数据") or "功能已关闭；启用后才读取对应 API。")
        end
        -- Table view-state coverage: every sibling V3 table page drives the
        -- table's empty/loading/unavailable overlay from the same enabled / #rows
        -- signals used for the hint line above. The business table previously
        -- never set a view state, so empty/unavailable states had no overlay.
        local tvState, tvOpts
        if enabled ~= true then
            tvState, tvOpts = "unavailable", { title = "功能已关闭", detail = id == "tools_bag" and "重新启用后会读取当前背包物品；已有黑名单不会丢失。" or ((meta and meta.name or id) .. " 启用后才会读取对应 API 并填充此表。") }
        elseif #rows == 0 then
            tvState, tvOpts = "empty", { title = id == "tools_bag" and "当前背包没有可识别物品" or "暂无数据", detail = id == "tools_bag" and "刷新页面或放入物品后会显示“物品ID · 名称”。" or ((meta and meta.name or id) .. " 启用并读取后，结果会显示在这里。") }
        else
            tvState = "ready"
        end
        tableView:SetViewState(tvState, tvOpts)
        return true
    end
    -- World-visual authorities may publish at 20 Hz (RangeAssist) or even a
    -- user-selected 1 ms UnitLines cadence.  The settings page is not part of
    -- that render path: redrawing RSUI controls at the same cadence wastes UI
    -- work and, on RU, can synthesize false button leave/enter transitions.
    -- Coalesce visual-tick presentation updates while keeping direct commands
    -- and non-visual authority updates immediate.
    local visualSettingsPage = id == "combat_unit_lines" or id == "combat_range_assist"
    local visualPageRefreshTask = "v3_business_visual_page_refresh:" .. tostring(id)
    local visualPageRefreshMs = 160

    function root:RequestFeatureRefresh(reason)
        reason = tostring(reason or "update")
        if visualSettingsPage ~= true or (reason ~= "visual_tick" and reason ~= "visual_tick_error") then
            return self:Refresh()
        end
        if self.visualPageRefreshPending == true then return true end
        if S.Scheduler == nil or type(S.Scheduler.AddOneShot) ~= "function" then return self:Refresh() end
        self.visualPageRefreshPending = true
        local added = S.Scheduler:AddOneShot(visualPageRefreshTask, visualPageRefreshMs, function()
            self.visualPageRefreshPending = false
            if self.featureUpdatesBound ~= true then return true end
            return self:Refresh()
        end, self, "P3", 1)
        if added ~= true then
            self.visualPageRefreshPending = false
            return self:Refresh()
        end
        if type(S.Scheduler.SetTaskModule) == "function" then
            S.Scheduler:SetTaskModule(visualPageRefreshTask, "presentation", true)
        end
        return true
    end
    function root:BindFeatureUpdates()
        if S.Events == nil or type(S.Events.SubscribeInternal) ~= "function" or type(feature.UpdateTopic) ~= "string" then return true end
        if type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        self.featureUpdatesBound = true
        return S.Events:SubscribeInternal(feature.UpdateTopic, self, function(_, _, reason) return root:RequestFeatureRefresh(reason) end)
    end
    function root:UnbindFeatureUpdates()
        self.featureUpdatesBound = false
        self.visualPageRefreshPending = false
        if S.Scheduler ~= nil and type(S.Scheduler.RemoveTask) == "function" then S.Scheduler:RemoveTask(visualPageRefreshTask) end
        if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        return true
    end
    function root:OnActivated()
        self:BindFeatureUpdates()
        if S.FeatureRuntime:IsEnabled(id) ~= true then
            self.consumerHeld = false
            return self:Refresh()
        end
        local acquired, acquireErr = feature:AcquireConsumer("page:" .. id)
        if acquired ~= true then return false, acquireErr end
        self.consumerHeld = true
        -- Demand 0->1 owns the initial Authority refresh. Do not immediately
        -- issue a second server/native query from Presentation.
        return self:Refresh()
    end
    function root:OnDeactivated()
        self:UnbindFeatureUpdates()
        if self.consumerHeld then feature:ReleaseConsumer("page:" .. id); self.consumerHeld = false end
        return true
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
