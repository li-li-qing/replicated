------------------------------------------------------------------------
-- Replicated Suite V3 - Native nameplate / HP bar visual settings page
--
-- 维护（2026-09-20，nameplate-mark-ratio-3）：Presentation 不访问 X2Option，所有
-- Native 写入只走 Feature.Commands -> Authority。RU 某些 CVar 允许 Set 但 Get 返回 nil，因此页面
-- 必须区分 strict / partial / write_only，禁止把“调用 Set 成功”伪装成“全部回读验证成功”。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI, D = S.RSUI, S.UIV3Design
local PageHost = S.UIV3 and S.UIV3.PageHost or nil
local Feature = S.Features and S.Features.NameplateVisuals or nil
if type(RSUI) ~= "table" or type(D) ~= "table" or type(PageHost) ~= "table" or type(Feature) ~= "table" then return end

local ROUTE, ID = "combat.nameplate_visuals", "v3_nameplate_visuals_"

local function N(value)
    local n = tonumber(value)
    if n == nil then return "--" end
    if math.abs(n - math.floor(n + 0.5)) < 0.01 then return tostring(math.floor(n + 0.5)) end
    return string.format("%.2f", n)
end

local function MarkerPercent(values)
    if type(values) ~= "table" then return nil end
    local scale = tonumber(values.markerScale)
    if scale ~= nil then return scale * 100 end
    local width = tonumber(values.markerWidth)
    if width ~= nil then return width * 100 / 46 end
    return nil
end

local function SnapshotText(values)
    if type(values) ~= "table" then return "--" end
    return "标记 " .. N(MarkerPercent(values)) .. "%"
        .. " / 血条 " .. N(values.hpWidth) .. "×" .. N(values.hpHeight)
        .. " / 背景模式 " .. N(values.bgHpWidth) .. "×" .. N(values.bgHpHeight)
end

local function BuildPage(parent, route)
    local root, err = D:ScrollablePageRoot(parent, { id = "v3_page_nameplate_visuals", gap = 7, padding = 2 })
    if root == nil then return nil, err end
    root.route = route

    local called, loaded, loadErr = pcall(Feature.EnsureStoreLoaded, Feature)
    if called ~= true or loaded ~= true then
        root.persistenceUnavailable = true
        D:PageHeader(root, ID .. "protected_header", "头顶显示增强：配置已保护", "设置未通过读取校验；不会清空旧配置，也不会写入客户端显示参数。")
        RSUI:Text({ id = ID .. "protected_reason", parent = root,
            text = tostring((called and loadErr or loaded) or "配置不可用"), fontSize = 10, tone = "warn", overflow = "wrap",
            slot = { size = "auto", minHeight = 42, hAlign = "fill" } })
        function root:OnActivated() return true end
        function root:OnDeactivated() return true end
        return root
    end

    D:PageHeader(root, ID .. "header", "头顶显示增强",
        "直接调整 RU 客户端原生队伍头顶标记倍率与名称血条尺寸；无持续扫描。18.272 实机确认血条有效，头标改用 name_tag_mark_size_ratio。")

    local fields = {}
    local actionStatus
    local actions = RSUI:UniformGrid({ id = ID .. "actions", parent = root, minCellWidth = 138, minCellHeight = 30,
        maxColumns = 3, gap = 6, slot = { size = "auto", minHeight = 30, hAlign = "fill" } })

    local function Result(ok, actionErr, message)
        if root.Refresh then root:Refresh() end
        if actionStatus then
            actionStatus:SetText(ok == true and tostring(message or "已完成") or ("操作失败：" .. tostring(actionErr or "未执行")))
            actionStatus:SetTone(ok == true and "muted" or "warn")
        end
        return ok, actionErr
    end

    local toggle = D:ModuleToggleButton({ id = ID .. "toggle", parent = actions, text = "启用功能", compact = true,
        slot = { size = "fill", hAlign = "fill" }, onClick = function()
            local target = S.FeatureRuntime:IsEnabled(Feature.Id) ~= true
            local ok, actionErr = S.FeatureRuntime:SetPreferredEnabled(Feature.Id, target, "nameplate_visuals_page_toggle")
            return Result(ok, actionErr, target and "已启用；原生显示参数已应用。" or "已关闭；已恢复启用前基线，设置仍保留。")
        end })

    local reapply = RSUI:Button({ id = ID .. "reapply", parent = actions, text = "重新应用", compact = true,
        slot = { size = "fill", hAlign = "fill" }, onClick = function()
            local ok, actionErr = Feature.Commands:Reapply()
            return Result(ok, actionErr, "已重新应用原生显示参数；可读项已验证。")
        end })

    RSUI:Button({ id = ID .. "reset", parent = actions, text = "恢复插件默认", compact = true,
        slot = { size = "fill", hAlign = "fill" }, onClick = function()
            local ok, actionErr = Feature.Commands:ResetDefaults()
            return Result(ok, actionErr, "设置已恢复为当前 API 快照默认；功能开启时已立即应用。")
        end })

    actionStatus = RSUI:Text({ id = ID .. "action_status", parent = root,
        text = "修改数值后点击应用；功能关闭时只保存设置，不写客户端。", fontSize = 9, tone = "muted", overflow = "wrap",
        slot = { size = "auto", minHeight = 22, hAlign = "fill" } })

    local markerPanel = RSUI:GroupBox({ id = ID .. "marker_panel", parent = root, title = "头顶标记",
        variant = "card", gradient = true, padding = 5, slot = { size = "auto", minHeight = 124, hAlign = "fill" } })
    local markerStack = RSUI:VerticalBox({ id = ID .. "marker_stack", parent = markerPanel, gap = 5 })
    local presetRow = RSUI:UniformGrid({ id = ID .. "marker_presets", parent = markerStack,
        minCellWidth = 82, minCellHeight = 28, maxColumns = 4, gap = 5,
        slot = { size = "auto", minHeight = 28, hAlign = "fill" } })
    for _, preset in ipairs({ 100, 125, 150, 200 }) do
        local value = preset
        RSUI:Button({ id = ID .. "preset_" .. tostring(value), parent = presetRow, text = tostring(value) .. "%", compact = true,
            slot = { size = "fill", hAlign = "fill" }, onClick = function()
                local ok, actionErr = Feature.Commands:SetMarkerPreset(value)
                return Result(ok, actionErr, "头顶标记倍率已设置为 " .. tostring(value) .. "% 。")
            end })
    end

    local markerGrid = RSUI:UniformGrid({ id = ID .. "marker_grid", parent = markerStack,
        minCellWidth = 220, minCellHeight = 32, maxColumns = 2, gap = 5,
        slot = { size = "auto", minHeight = 32, hAlign = "fill" } })

    local function AddNumeric(parentBox, key, label, slider)
        local range = Feature.Limits[key]
        local field = D:CompactNumericSetting(parentBox, {
            id = ID .. key, label = label, min = range[1], max = range[2], step = 1, integer = true,
            slider = slider ~= false, stepButtons = false, labelWidth = 74, inputWidth = 62,
            get = function() return Feature:GetSettings()[key] end,
            set = function(value)
                local ok, actionErr = Feature.Commands:SetValue(key, value)
                return Result(ok, actionErr, "设置已保存" .. (Feature.enabled and "并写入客户端。" or "；启用功能后写入客户端。"))
            end,
            slot = { size = "fill", fill = 1, hAlign = "fill" },
        })
        if field ~= nil then fields[#fields + 1] = field end
        return field
    end

    -- 中文维护注释（nameplate-mark-ratio-3）：旧 over_head_marker_width/height/offset 在 RU 实机
    -- Set 成功但无视觉变化，页面不再暴露三个无效控件。百分比仍写 schema1 width/height 兼容字段，
    -- Native Authority 只转换成 name_tag_mark_size_ratio，避免改 Store schema 导致旧用户指纹 fence。
    local markerScale = D:CompactNumericSetting(markerGrid, {
        id = ID .. "marker_scale_percent", label = "标记倍率%", min = 50, max = 300, step = 5, integer = true,
        slider = true, stepButtons = false, labelWidth = 74, inputWidth = 62,
        get = function() return Feature:GetMarkerPercent() end,
        set = function(value)
            local ok, actionErr = Feature.Commands:SetMarkerScalePercent(value)
            return Result(ok, actionErr, "头顶标记倍率已保存" .. (Feature.enabled and "并写入客户端。" or "；启用功能后写入客户端。"))
        end,
        slot = { size = "fill", fill = 1, hAlign = "fill" },
    })
    if markerScale ~= nil then fields[#fields + 1] = markerScale end
    local fixed = RSUI:Toggle({ id = ID .. "marker_fixed", parent = markerGrid,
        onText = "固定屏幕尺寸：开", offText = "固定屏幕尺寸：关",
        get = function() return Feature:GetSettings().markerFixedSize == true end,
        set = function(value)
            local ok, actionErr = Feature.Commands:SetFixedSize(value == true)
            return Result(ok, actionErr, "固定尺寸设置已保存" .. (Feature.enabled and "并应用。" or "。"))
        end,
        slot = { size = "fill", fill = 1, hAlign = "fill" } })
    fields[#fields + 1] = fixed

    RSUI:Text({ id = ID .. "marker_hint", parent = markerStack,
        text = "18.272 RU 实机已确认 over_head_marker_width/height/offset 对队伍头标无视觉效果。本版改用客户端明确标注为 ‘name tag mark scale’ 的 name_tag_mark_size_ratio；只改变标记大小，不改编号/归属，也不启动治疗头顶覆盖层。",
        fontSize = 9, tone = "muted", overflow = "wrap", slot = { size = "auto", minHeight = 28, hAlign = "fill" } })

    local hpPanel = RSUI:GroupBox({ id = ID .. "hp_panel", parent = root, title = "名称血条大小",
        variant = "card", gradient = true, padding = 5, slot = { size = "auto", minHeight = 116, hAlign = "fill" } })
    local hpStack = RSUI:VerticalBox({ id = ID .. "hp_stack", parent = hpPanel, gap = 5 })
    local hpGrid = RSUI:UniformGrid({ id = ID .. "hp_grid", parent = hpStack,
        minCellWidth = 220, minCellHeight = 32, maxColumns = 2, gap = 5,
        slot = { size = "auto", minHeight = 64, hAlign = "fill" } })
    AddNumeric(hpGrid, "hpWidth", "普通血条宽", true)
    AddNumeric(hpGrid, "hpHeight", "普通血条高", true)
    AddNumeric(hpGrid, "bgHpWidth", "背景模式宽", true)
    AddNumeric(hpGrid, "bgHpHeight", "背景模式高", true)
    RSUI:Text({ id = ID .. "hp_hint", parent = hpStack,
        text = "普通模式 API 默认 70×7；背景模式默认 158×38。本功能只改尺寸，不强制显示血条，也不修改敌我/姓名显示规则。",
        fontSize = 9, tone = "muted", overflow = "wrap", slot = { size = "auto", minHeight = 28, hAlign = "fill" } })

    local stateCard = D:InfoCard(root, { id = ID .. "state", title = "Native 状态", value = "功能已关闭", detail = "",
        detailMaxLines = 5, slot = { size = "auto", minHeight = 96, hAlign = "fill" } })
    RSUI:Text({ id = ID .. "limits", parent = root,
        text = "兼容边界：滑块范围是插件安全输入预算，不代表引擎硬上限。关闭时基线优先使用 Native 可读值；不可读项尝试 system.cfg，缺失时才使用已核对客户端默认值。",
        fontSize = 9, tone = "muted", overflow = "wrap", slot = { size = "auto", minHeight = 35, hAlign = "fill" } })

    function root:Refresh()
        local p = Feature:GetProjection()
        toggle:SetText(p.enabled and "关闭功能" or "启用功能")
        reapply:SetEnabled(p.enabled == true)
        for _, field in ipairs(fields) do if type(field) == "table" and type(field.Render) == "function" then field:Render() end end
        local metrics = p.metrics or {}
        local mode = tostring(p.readbackMode or "unknown")
        local unreadable = type(p.unreadableCvars) == "table" and table.concat(p.unreadableCvars, ",") or ""
        local modeLabel = mode == "strict" and "严格回读"
            or (mode == "partial" and "部分回读" or (mode == "write_only" and "Write-only" or "未探测"))
        if p.enabled then
            stateCard:SetData({ value = "已启用 · " .. modeLabel, detail = "当前期望：" .. SnapshotText(p.effective or p.settings)
                .. "\nNative 回读：" .. SnapshotText(p.observed)
                .. "\n启用前基线：" .. SnapshotText(p.baseline) .. " / 来源 " .. tostring(p.baselineSourceSummary or "--")
                .. "\n头标入口：name_tag_mark_size_ratio"
                .. "\n写入 " .. N(metrics.writes) .. " / 回读尝试 " .. N(metrics.reads) .. " / 不可读 " .. N(metrics.readMisses)
                .. " / 失败 " .. N(metrics.failures) .. " / ENTERED_WORLD " .. N(p.reapplyCount)
                .. (unreadable ~= "" and ("\n不可回读：" .. unreadable) or "")
                .. (p.lastError and ("\n最近错误：" .. tostring(p.lastError)) or "") })
        else
            stateCard:SetData({ value = "功能已关闭", detail = "已保存设置：" .. SnapshotText(p.settings)
                .. "\n无 Tick / 无轮询 / 无 Consumer；启用时才写原生客户端变量。"
                .. (p.lastError and ("\n最近错误：" .. tostring(p.lastError)) or "") })
        end
        return true
    end

    local generation = S.Generation
    function root:OnActivated()
        if self._active == true then return self:Refresh() end
        self._active = true
        if S.Events == nil or type(S.Events.SubscribeInternal) ~= "function" then self._active = false; return false, "内部事件总线不可用" end
        local updated = S.Events:SubscribeInternal(Feature.UpdateTopic, self, function(_, id)
            if root._active ~= true or S.Generation ~= generation or id ~= Feature.Id then return end
            root:Refresh()
        end)
        local lifecycle = S.Events:SubscribeInternal("v3.feature.lifecycle", self, function(_, id)
            if root._active ~= true or S.Generation ~= generation or id ~= Feature.Id then return end
            root:Refresh()
        end)
        if updated ~= true or lifecycle ~= true then self:OnDeactivated(); return false, "页面事件订阅失败" end
        return self:Refresh()
    end

    function root:OnDeactivated()
        self._active = false
        if S.Events and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        return true
    end

    local release = root.Release
    function root:Release()
        self:OnDeactivated()
        return release(self)
    end

    return root
end

local ok, err = PageHost:RegisterFactory(ROUTE, BuildPage)
if ok ~= true then error(err) end
