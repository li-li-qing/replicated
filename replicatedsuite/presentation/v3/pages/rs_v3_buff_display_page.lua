------------------------------------------------------------------------
-- Replicated Suite V3 - Buff Display Page (UI_IMPLEMENTING / HUD calibration v1)
--
-- 中文维护注释：四个页面面向不同读模型；没有新增 Store/Native Authority。
-- Four presentation surfaces:
--   1) 追踪管理  : one virtual TableView for player + target facts.
--   2) 内置库    : immutable catalog, explicit one-shot imports.
--   3) HUD 布局  : policy controls + standalone in-world HUD calibration entry.
--                  Calibration owns a detached player/target draft and only
--                  Save & Exit crosses the Persistence boundary.
--   4) 导入导出  : tracked-id quick import + full Store export/import.
--
-- Presentation consumes only BuffDisplay projection/commands.  The page loads
-- the Store before constructing editable controls, so a disabled Feature can
-- never edit defaults over an unread saved payload.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI, D = S.RSUI, S.UIV3Design
local PageHost = S.UIV3 and S.UIV3.PageHost or nil
local WidgetHost = S.UIV3 and S.UIV3.WidgetHost or nil
local Feature = S.Features and S.Features.BuffDisplay or nil
if type(RSUI) ~= "table" or type(D) ~= "table" or type(PageHost) ~= "table" or type(WidgetHost) ~= "table" or type(Feature) ~= "table" then return end

local ROUTE = "combat.buff_display"
-- 中文维护注释：管理/内置库/HUD/交换四个入口分工；UI 不直接写 Store 或访问 Native。
local TAB_KEYS = { "track", "library", "layout", "transfer" }
local function MatchRow(row, query)
    query = tostring(query or ""):lower()
    if query == "" then return true end
    return string.find(tostring(row.name or ""):lower(), query, 1, true) ~= nil
        or string.find(tostring(row.id or ""), query, 1, true) ~= nil
        or string.find(tostring(row.effectTypeText or ""):lower(), query, 1, true) ~= nil
        or string.find(tostring(row.scopeText or ""):lower(), query, 1, true) ~= nil
end

local function ReadNativeText(widget)
    if widget ~= nil and type(widget.GetText) == "function" then
        local ok, text = pcall(widget.GetText, widget)
        if ok and type(text) == "string" then return text end
    end
    return ""
end

local function WriteNativeText(widget, text)
    if widget ~= nil and type(widget.SetText) == "function" then pcall(widget.SetText, widget, tostring(text or "")) end
end

-- 中文维护注释（只读取证 UI）：旧 Hash 和 sequence=unchanged 不能还原字段，必须取得真实
-- LoadData 输入。用户明确选择并点击后才读取；不绑定 Store，不调用 Feature Commands 或 Save。
-- Native 输入框只是可复制的临时文本；可能包含玩家名/状态 ID，禁止自动发送聊天或上传。
-- 故障页不能因可选文本控件失败再次触发构建隔离；隐藏页面即清缓存，分页不再次读磁盘。
local function AttachEvidenceReader(root)
    local diagnostics = S.DiagnosticsManager
    local choices = type(diagnostics) == "table" and type(diagnostics.GetPersistenceFailureChoices) == "function"
        and diagnostics:GetPersistenceFailureChoices() or {}
    local selected = "v3.buff_display"
    if #choices > 0 then selected = choices[1].value end
    for _, choice in ipairs(choices) do if choice.value == "v3.buff_display" then selected = choice.value end end
    local text, pageIndex, pageCount = nil, 1, 0
    local editor, available, status, previous, following
    local function Clear()
        text, pageIndex, pageCount = nil, 1, 0
        WriteNativeText(editor, "")
        if previous then previous:SetEnabled(false) end
        if following then following:SetEnabled(false) end
    end
    RSUI:Text({id="v3_buff_evidence_warning",parent=root,
        text="只读取证：包含所选存档的原始字段，可能含玩家名、追踪 ID 和布局。不会写回配置或自动发送。",
        fontSize=10,tone="warn",overflow="wrap",maxLines=3,slot={size="auto",minHeight=40,hAlign="fill"}})
    local actions=RSUI:HorizontalBox({id="v3_buff_evidence_actions",parent=root,gap=6,slot={size="fixed",height=30,hAlign="fill"}})
    RSUI:Dropdown({id="v3_buff_evidence_store",parent=actions,items=choices,maxVisible=5,
        get=function() return selected end,set=function(value) selected=tostring(value);Clear();return true end,
        slot={size="fill",fill=1,minWidth=200}})
    local export=RSUI:Button({id="v3_buff_evidence_export",parent=actions,text="读取故障存档",compact=true,slot={size="fixed",width=128}})
    local host=RSUI:Border({id="v3_buff_evidence_host",parent=root,padding=0,variant="card",slot={size="fixed",height=154,hAlign="fill"}})
    if host and host.root and type(S.UI.CreateMultiEditBox)=="function" then
        local ok,value=pcall(S.UI.CreateMultiEditBox,S.UI,host.root,"v3_buff_evidence_edit",4,4,500,144,32768)
        if ok then editor=value end
        if editor and type(editor.AddAnchor)=="function" then pcall(editor.AddAnchor,editor,"BOTTOMRIGHT",host.root,-4,-4) end
        if editor and type(editor.SetText)=="function" and type(editor.GetText)=="function"
            and type(S.UI.BindDeferredInputActivation)=="function" then
            local activated,result=pcall(S.UI.BindDeferredInputActivation,S.UI,editor,host.owner,"v3_buff_evidence_edit")
            available=activated and result==true
        end
        if editor and not available then
            if type(S.UI.RetireInputWidget)=="function" then pcall(S.UI.RetireInputWidget,S.UI,editor,host.owner,"evidence_editor_unavailable") end
            if type(editor.Show)=="function" then pcall(editor.Show,editor,false) end
            editor=nil
        end
    end
    local nav=RSUI:HorizontalBox({id="v3_buff_evidence_nav",parent=root,gap=6,slot={size="fixed",height=28,hAlign="fill"}})
    previous=RSUI:Button({id="v3_buff_evidence_prev",parent=nav,text="上一段",compact=true,slot={size="fixed",width=70}})
    following=RSUI:Button({id="v3_buff_evidence_next",parent=nav,text="下一段",compact=true,slot={size="fixed",width=70}})
    local clear=RSUI:Button({id="v3_buff_evidence_clear",parent=nav,text="清空取证文本",compact=true,slot={size="fixed",width=110}})
    status=RSUI:Text({id="v3_buff_evidence_status",parent=root,
        text=available and "选择故障 Store，再读取。复制每一段到同一个 .txt；无需导出整个账号数据库。"
            or "多行文本框不可用；仍可点击上方“输出存档故障”，本页不会自动读盘。",
        fontSize=10,tone="muted",overflow="wrap",maxLines=3,slot={size="auto",minHeight=40,hAlign="fill"}})
    local function Render()
        if not text or not editor then return false,"没有可复制的取证文本" end
        local chunk=text:sub((pageIndex-1)*30000+1,pageIndex*30000)
        local check=text:match("\nCHECK=([0-9A-F]+)\n")
        local shown="RS-PERSIST-PART-1 i="..pageIndex.." n="..pageCount.." check="..tostring(check).." bytes="..#chunk
            .."\n"..chunk.."\nRS-PERSIST-PART-END"
        local wrote=pcall(editor.SetText,editor,shown)
        local read,actual=pcall(editor.GetText,editor)
        if not wrote or not read or actual~=shown then
            Clear();status:SetText("客户端文本框改写或截断了取证内容，已停止；不要提交不完整文本。")
            return false,"取证文本回读不一致"
        end
        previous:SetEnabled(pageIndex>1);following:SetEnabled(pageIndex<pageCount)
        status:SetText(selected.." · 第 "..pageIndex.."/"..pageCount.." 段。点文本框 Ctrl+A、Ctrl+C，粘贴到 .txt；全部段均需复制。")
        return true
    end
    local backendAvailable=type(diagnostics)=="table" and type(diagnostics.BuildPersistenceEvidenceText)=="function"
    export:SetEnabled(available==true and backendAvailable and #choices>0)
    export.onClick=function()
        if not available or not backendAvailable then return false,"取证文本框或后端不可用" end
        Clear()
        local captured,err=diagnostics:BuildPersistenceEvidenceText(selected)
        if not captured then status:SetText("读取失败："..tostring(err));return false,err end
        text,pageIndex,pageCount=captured,1,math.max(1,math.ceil(#captured/30000))
        return Render()
    end
    previous.onClick=function() if pageIndex<=1 then return false end;pageIndex=pageIndex-1;return Render() end
    following.onClick=function() if pageIndex>=pageCount then return false end;pageIndex=pageIndex+1;return Render() end
    clear.onClick=function() Clear();status:SetText("仅清空取证文本，原存档未修改。");return true end
    Clear()
    return function(visible)
        if not visible then
            Clear()
            -- 维护：隐藏不是销毁。通过共享输入生命周期释放焦点/键盘，避免取证框继续吞游戏按键；
            -- 不 Retire，重新打开后仍由显式点击激活，不改变其它页面/聊天的焦点 Authority。
            if editor and type(S.UI.DeactivateInputWidget)=="function" then
                pcall(S.UI.DeactivateInputWidget,S.UI,editor,host.owner,"evidence_page_hidden")
            end
        end
        if editor and type(editor.Show)=="function" then pcall(editor.Show,editor,visible==true) end
        return true
    end
end

-- 中文维护注释：存档拒绝是业务故障，不是控件构造异常。原先 return nil 让 PageHost
-- 叠加 rollback/quarantine；现在只展示读取失败，不套默认值、不清 fence、不建配置 Binding
-- 或 Consumer；取证复制框不绑定业务配置。真正构造失败仍报错，恢复使用“重新加载文件”。
local function BuildPersistenceUnavailablePage(parent, route, reason)
    -- 维护：取证说明/分页增加纵向内容，固定 PageRoot 在 768 高度可能裁掉复制控件。
    -- 复用 Foundation 滚动布局，禁止添加另一套坐标/滚轮 Authority；不修改正常四页签。
    local createRoot = D.ScrollablePageRoot or D.PageRoot
    local root, err = createRoot(D, parent, "v3_page_buff_display")
    if root == nil then return nil, err or "状态显示错误页面创建失败" end
    root.route, root.persistenceUnavailable = route, true
    D:PageHeader(root, "v3_buff_persistence_header", "状态显示：配置已保护",
        "旧配置未通过读取校验；不会用默认值覆盖，也不会开放编辑或启动状态采集。")
    RSUI:Text({ id="v3_buff_persistence_error", parent=root,
        text="读取失败：" .. tostring(reason or "未知错误"), fontSize=10, tone="warn",
        overflow="wrap", maxLines=6, slot={size="auto", minHeight=72, hAlign="fill"} })
    RSUI:Button({ id="v3_buff_persistence_report", parent=root, text="输出存档故障", compact=true,
        slot={size="fixed", width=144, height=30}, onClick=function()
            local diagnostics = S.DiagnosticsManager
            if type(diagnostics) ~= "table" or type(diagnostics.PrintPersistenceFailureReport) ~= "function" then
                return false, "存档故障报告不可用"
            end
            return diagnostics:PrintPersistenceFailureReport()
        end })
    -- 维护（RS-DIAG-3）：提示与单次发送契约一致；不改变取证读取、输入焦点或写保护。
    RSUI:Text({ id="v3_buff_persistence_hint", parent=root,
        text="报告只发送一条 RS-DIAG-3 消息，复制到末尾 END 即可。请保留旧存档；完整原始字段仍从下方文本框读取。",
        fontSize=10, tone="muted", overflow="wrap", maxLines=3,
        slot={size="auto", minHeight=42, hAlign="fill"} })
    local setEvidenceVisible = AttachEvidenceReader(root)
    function root:OnActivated() return setEvidenceVisible(true) end -- 显示页面不读盘，不启动消费者。
    function root:OnDeactivated() return setEvidenceVisible(false) end -- 隐藏时释放大文本与 Native 编辑内容。
    return root
end

local function BuildPage(parent, route)
    -- Editable pages must load their Store before controls are created.  This is
    -- deliberately earlier than Feature enable/consumer acquisition.
    if type(Feature.EnsureStoreLoaded) == "function" then
        local loaded, loadErr = Feature:EnsureStoreLoaded()
        if loaded ~= true then return BuildPersistenceUnavailablePage(parent, route, loadErr) end -- 中文维护注释：保留写保护，隔离读失败和构建失败。
    end

    local root, rootErr = D:PageRoot(parent, "v3_page_buff_display")
    if root == nil then return nil, "状态显示页面根组件创建失败：" .. tostring(rootErr or "未知错误") end
    root.activeTab, root.filterText, root.quickText, root.importCategory = "track", "", "", "auto"
    root.managementView, root.managementFilter, root.managementSort, root.libraryPack = "live", "all", "tracked", "recommended"

    D:PageHeader(root, "v3_buff_display_header", "状态显示", "统一管理状态追踪与头顶 HUD；HUD 校准会暂时最小化主菜单，在真实游戏画面上调整。", "刷新", function()
        return Feature.Commands:Refresh("page_manual")
    end)

    local actionRow = RSUI:HorizontalBox({ id = "v3_buff_display_actions", parent = root, gap = 6, slot = { size = "fixed", height = 30, hAlign = "fill" } })
    local featureButton = RSUI:Button({ id = "v3_buff_display_feature_toggle", parent = actionRow, text = "启用功能", compact = true, slot = { size = "fixed", width = 96 } })
    local widgetButton = RSUI:Button({ id = "v3_buff_display_widget_toggle", parent = actionRow, text = "打开悬浮窗", compact = true, slot = { size = "fixed", width = 116 } })
    local persistHint = RSUI:Text({ id = "v3_buff_display_persist_hint", parent = actionRow, text = "配置已读取", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fill", fill = 1, hAlign = "right" } })

    local function ApplySetting(key, value)
        local ok, err = Feature.Commands:SetSetting(key, value)
        if ok == true then root:Refresh() end
        return ok, err
    end

    local switcher
    local transferEdit = nil
    local layoutPolicyControls = {}
    local layoutProfileSummary = nil
    local calibrationButton = nil

    local tabSelector, tabSelectorErr = RSUI:SegmentedSelector({
        id = "v3_buff_display_tabs", parent = root, maxItems = 4, gap = 2, height = 26, fontSize = 10,
        items = {
            { value = "track", text = "追踪管理", width = 104 },
            { value = "library", text = "内置库", width = 88 },
            { value = "layout", text = "HUD 布局", width = 104 },
            { value = "transfer", text = "导入导出", width = 104 },
        },
        get = function() return root.activeTab or "track" end,
        set = function(value)
            root.activeTab = tostring(value or "track")
            return type(root.SwitchTab) == "function" and root:SwitchTab(root.activeTab) or true
        end,
        slot = { size = "fixed", height = 30, hAlign = "fill" },
    })
    if tabSelector == nil then error("状态显示页签选择器创建失败：" .. tostring(tabSelectorErr or "unknown")) end
    switcher = RSUI:WidgetSwitcher({ id = "v3_buff_display_tab_switcher", parent = root, activeIndex = 1, measureMode = "active", slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })

    ------------------------------------------------------------------
    -- Tab 1: 追踪管理 - one virtual table / one interaction contract.
    ------------------------------------------------------------------
    local tabTrack = RSUI:VerticalBox({ id = "v3_buff_display_tab_track", parent = switcher, gap = 6, slot = { hAlign = "fill", vAlign = "fill" } })
    -- 中文维护注释：筛选属于页面 Session，不借 showBuffs/showHidden 改写 HUD 或永久配置。
    local viewRow=RSUI:HorizontalBox({id="v3_buff_manage_views",parent=tabTrack,gap=5,slot={size="fixed",height=28,hAlign="fill"}})
    local viewPicker=RSUI:Dropdown({id="v3_buff_manage_view",parent=viewRow,maxVisible=4,
        items={{value="live",text="当前状态"},{value="frozen",text="留存记录（持续收集）"},{value="tracked",text="已追踪（含未出现）"},{value="cooldowns",text="技能 CD（未完成）"}},
        get=function() return root.managementView end,
        set=function(value) root.managementView=value;return root:Refresh() end,slot={size="fixed",width=164}})
    local filterPicker=RSUI:Dropdown({id="v3_buff_manage_filter",parent=viewRow,maxVisible=8,
        items={{value="all",text="全部"},{value="tracked_buff",text="追踪 Buff"},{value="tracked_debuff",text="追踪 Debuff"},
            {value="auto",text="自动识别 / 待分类"},{value="hidden",text="隐藏状态"},{value="untracked",text="未追踪"},{value="player",text="自己"},{value="target",text="目标"}},
        get=function() return root.managementFilter end,
        set=function(value) root.managementFilter=value;return root:Refresh() end,slot={size="fixed",width=148}})
    local sortPicker=RSUI:Dropdown({id="v3_buff_manage_sort",parent=viewRow,maxVisible=6,
        items={{value="tracked",text="追踪优先"},{value="category",text="按类别"},{value="source",text="按来源"},{value="name",text="按名称"},{value="id",text="按 ID"},{value="time",text="按剩余时间"}},
        get=function() return root.managementSort end,
        set=function(value) root.managementSort=value;return root:Refresh() end,slot={size="fixed",width=128}})
    if not viewPicker or not filterPicker or not sortPicker then error("追踪管理筛选控件创建失败") end
    local filterRow = RSUI:HorizontalBox({ id = "v3_buff_display_track_filters", parent = tabTrack, gap = 6, slot = { size = "fixed", height = 28, hAlign = "fill" } })
    local buffButton = RSUI:Button({ id = "v3_buff_display_filter_buff", parent = filterRow, text = "Buff：开", compact = true, slot = { size = "fixed", width = 76 } })
    local debuffButton = RSUI:Button({ id = "v3_buff_display_filter_debuff", parent = filterRow, text = "Debuff：开", compact = true, slot = { size = "fixed", width = 86 } })
    local hiddenButton = RSUI:Button({ id = "v3_buff_display_filter_hidden", parent = filterRow, text = "只看隐藏：关", compact = true, slot = { size = "fixed", width = 92 } })
    local searchInput = RSUI:TextInput({
        id = "v3_buff_display_search", parent = filterRow, value = "", maxLength = 48, buildOptional = true,
        allowEmpty = true, submitOnLostFocus = false,
        get = function() return root.filterText or "" end,
        set = function(v) root.filterText = tostring(v or ""); return true end,
        onSubmit = function(value) root.filterText = tostring(value or ""); return root:Refresh() end,
        slot = { size = "fill", fill = 1, minWidth = 90 },
    })
    if searchInput == nil then searchInput = RSUI:Text({ id = "v3_buff_display_search_unavailable", parent = filterRow, text = "搜索框不可用", fontSize = 9, tone = "warn", slot = { size = "fill", fill = 1 } }) end
    local searchClear = RSUI:Button({ id = "v3_buff_display_search_clear", parent = filterRow, text = "清空筛选", compact = true, slot = { size = "fixed", width = 72 } })

    local trackAction = RSUI:HorizontalBox({ id = "v3_buff_display_track_actions", parent = tabTrack, gap = 6, slot = { size = "fixed", height = 28, hAlign = "fill" } })
    local selectedText = RSUI:Text({ id = "v3_buff_display_selected", parent = trackAction, text = "点击状态行可追踪 / 取消追踪", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fill", fill = 1, minWidth = 150 } })
    local freezeButton = RSUI:Button({ id = "v3_buff_display_track_freeze", parent = trackAction, text = "冻结列表（留存）", compact = true, slot = { size = "fixed", width = 126 } })
    local updateFreezeButton=RSUI:Button({id="v3_buff_update_freeze",parent=trackAction,text="清空记录",compact=true,slot={size="fixed",width=78}})
    local clearTrackButton = RSUI:Button({ id = "v3_buff_display_track_clear", parent = trackAction, text = "清空追踪", compact = true, slot = { size = "fixed", width = 78 } })
    local probeButton = RSUI:Button({ id = "v3_buff_display_track_probe", parent = trackAction, text = "字段诊断", compact = true, slot = { size = "fixed", width = 78 } })

    local function ToggleRowTracked(item)
        if type(item) ~= "table" or item.id == nil then return true end
        local target = item.tracked ~= true
        root.selectedManagementRow=item
        local category=item.trackedBucket or ((item.category=="buff" or item.category=="debuff") and item.category or "auto")
        local ok,err
        if item.kind=="skill" or item.kind=="mate" then ok,err=Feature.Commands:SetTrackedCooldownId(tonumber(item.id),item.kind,target)
        else ok,err=Feature.Commands:SetTrackedId(tonumber(item.id),category,target) end
        selectedText:SetText(ok == true
            and ((target and "已追踪：" or "已取消追踪：") .. tostring(item.name or item.id) .. " · ID " .. tostring(item.id))
            or ("追踪失败：" .. tostring(item.name or item.id) .. " · " .. tostring(err or "未知错误")))
        if ok == true then root:Refresh() end
        return ok, err
    end

    local trackingPanel = RSUI:Border({ id = "v3_buff_display_tracking_panel", parent = tabTrack, padding = 5, variant = "card", slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    local trackingStack = RSUI:VerticalBox({ id = "v3_buff_display_tracking_stack", parent = trackingPanel, gap = 3, slot = { hAlign = "fill", vAlign = "fill" } })
    local trackingCaption = RSUI:Text({ id = "v3_buff_display_tracking_caption", parent = trackingStack, text = "当前状态", fontSize = 10, tone = "strong", slot = { size = "fixed", height = 20 } })
    local trackingTable = RSUI:TableView({
        id = "v3_buff_display_tracking_table",
        -- 仅排队，可见行渲染不直接调用Native；图标缺失由共享Metadata分批缓存。
        bindRow=function(_,item) if item and item.kind~="skill" and item.kind~="mate" then Feature:QueueManagementMetadata(item.id) end end, parent = trackingStack, items = {}, rowHeight = 25, headerHeight = 23, desiredRows = 12,
        overscan = 2, scrollbar = true, selectable = false, columnResize = true, headerInteractive = false,
        onItemActivated = ToggleRowTracked,
        columns = {
            { id = "scope", title = "来源", field = "scopeText", size = "fixed", width = 48, minWidth = 44, sortable = false },
            { id = "id", title = "ID", field = "id", size = "fixed", width = 52, minWidth = 44, sortable = false },
            { id = "icon", title = "", field = "iconPath", cellType = "icon", iconSize = 18, fallbackIcon = "ui/icon/icon_unknown_item.dds", size = "fixed", width = 25, minWidth = 24, sortable = false, resizable = false },
            { id = "name", title = "状态", field = "name", size = "fill", minWidth = 110, fill = 1, getTone = function(item)
                if type(item) ~= "table" then return "default" end
                if item.effectType == "debuff" then return "red" end
                if item.detectionSource == "hidden" or item.frozen == true then return "muted" end
                return "default"
            end },
            { id = "type", title = "类型", field = "effectTypeText", size = "fixed", width = 54, minWidth = 48, sortable = false },
            { id = "stack", title = "层", field = "stack", size = "fixed", width = 34, minWidth = 30, sortable = false },
            { id = "time", title = "剩余", field = "timeText", size = "fixed", width = 52, minWidth = 44, sortable = false },
            { id = "tracked", title = "追踪", field = "trackedText", size = "fixed", width = 56, minWidth = 50, sortable = false, getTone = function(item) return item and item.tracked == true and "green" or "muted" end },
        },
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })

    local classifyRow=RSUI:HorizontalBox({id="v3_buff_classify_row",parent=tabTrack,gap=5,slot={size="fixed",height=27,hAlign="fill"}})
    local function ClassifySelected(category)
        local row=root.selectedManagementRow
        if not row or row.kind=="skill" or row.kind=="mate" then return false,"请先点击一个状态行" end
        local ok,err
        if category=="auto" then ok,err=Feature.Commands:ClearClassification(row.id)
        else ok,err=Feature.Commands:SetClassification(row.id,category) end
        if ok then root:Refresh() end
        selectedText:SetText(ok and "已更新所选状态分类" or tostring(err));return ok,err
    end
    RSUI:Button({id="v3_buff_classify_buff",parent=classifyRow,text="所选设为 Buff",compact=true,onClick=function() return ClassifySelected("buff") end,slot={size="fixed",width=112}})
    RSUI:Button({id="v3_buff_classify_debuff",parent=classifyRow,text="所选设为 Debuff",compact=true,onClick=function() return ClassifySelected("debuff") end,slot={size="fixed",width=122}})
    RSUI:Button({id="v3_buff_classify_auto",parent=classifyRow,text="所选恢复自动",compact=true,onClick=function() return ClassifySelected("auto") end,slot={size="fixed",width=112}})

    -- 中文维护注释：内置包在 Catalog 一次编译；页面只读 Feature 投影，导入走单事务命令。
    -- 维护：用户主流程是选分类 -> 一键加入 -> 已追踪，而非按版本水位补齐。
    -- 历史newOnly命令保留兼容，移除发行按钮；不把新选择写入实时筛选或自动改极性。
    local tabLibrary=RSUI:VerticalBox({id="v3_buff_tab_library",parent=switcher,gap=6,slot={hAlign="fill",vAlign="fill"}})
    local libraryToolbar=RSUI:HorizontalBox({id="v3_buff_library_toolbar",parent=tabLibrary,gap=5,slot={size="fixed",height=28,hAlign="fill"}})
    local packs=Feature:GetLibraryPacks();local packItems={}
    for _,pack in ipairs(packs) do packItems[#packItems+1]={value=pack.key,text=pack.name.."（"..pack.count.."）"} end
    local libraryPicker=RSUI:Dropdown({id="v3_buff_library_pack",parent=libraryToolbar,items=packItems,maxVisible=10,popupWidth=340,
        get=function() return root.libraryPack end,set=function(value) root.libraryPack=value;return root:RefreshLibrary() end,slot={size="fill",fill=1,minWidth=200}})
    if not libraryPicker then error("内置包选择器创建失败") end
    local importPack=RSUI:Button({id="v3_buff_library_import",parent=libraryToolbar,text="一键加入追踪",compact=true,slot={size="fixed",width=112}})
    local libraryHint=RSUI:Text({id="v3_buff_library_hint",parent=tabLibrary,text="点击一次即可加入所选分类，并打开“已追踪”。自动识别也已追踪，状态出现时按实际 Buff/Debuff 显示；不会把技能 CD 加进推荐库。",fontSize=9,tone="muted",overflow="wrap",maxLines=2,slot={size="auto",minHeight=30,hAlign="fill"}})
    -- 维护（library-eventbus-2）：是否导入以Feature持久化集合为准，不以实时Aura数量或按钮点击为准。
    -- 单独的结果行在图标异步刷新时仍保留失败提示；仅目录revision改变时计算计数，不做Native查询。
    local libraryStatus=RSUI:Text({id="v3_buff_library_status",parent=tabLibrary,text="",
        fontSize=10,tone="strong",overflow="ellipsis",slot={size="fixed",height=22,hAlign="fill"}})
    local libraryTable=RSUI:TableView({id="v3_buff_library_table",parent=tabLibrary,items={},rowHeight=25,headerHeight=23,desiredRows=12,
        overscan=2,scrollbar=true,selectable=false,columnResize=true,headerInteractive=false,onItemActivated=ToggleRowTracked,
        -- 维护：与管理表复用原生icon单元格；没有资源的ID明确用unknown，不编造图标路径。
        bindRow=function(_,item) if item and item.kind=="effect" then Feature:QueueManagementMetadata(item.id) end end,
        columns={{id="icon",title="",field="iconPath",cellType="icon",iconSize=18,fallbackIcon="ui/icon/icon_unknown_item.dds",size="fixed",width=25,minWidth=24,sortable=false,resizable=false},
            {id="id",title="ID",field="id",size="fixed",width=70},{id="name",title="名称",field="name",size="fill",fill=1,minWidth=160},
            {id="category",title="类别",field="effectTypeText",size="fixed",width=76},{id="tracked",title="追踪",field="trackedText",size="fixed",width=72}},
        slot={size="fill",fill=1,hAlign="fill",vAlign="fill"}})
    function root:RefreshLibrary()
        local rows,revision=Feature:GetManagementProjection({view="library",pack=self.libraryPack,sort="id"})
        if self.libraryRevision==revision then return true end
        local tracked,icons=0,0
        for _,row in ipairs(rows) do
            if row.tracked then tracked=tracked+1 end
            if type(row.iconPath)=="string" and row.iconPath~="" then icons=icons+1 end
        end
        libraryStatus:SetText("所选分类 "..#rows.." 条 · 已追踪 "..tracked.." / "..#rows
            .." · 已取得图标 "..icons.." / "..#rows.."（其余等待解析或接口未提供）")
        libraryTable:SetItems(rows,revision)
        libraryTable:SetViewState(#rows>0 and "ready" or "empty",{title="当前内置库暂无可导入条目",detail="欢乐天赋为空时不伪造内容。"})
        importPack:SetEnabled(#rows>0)
        -- 只在控件全部接受后确认revision；临时构建/布局异常不得永久跳过同一批已解析图标。
        self.libraryRevision=revision
        return true
    end
    local function ImportPack()
        -- 维护（library-eventbus-2）：旧回调异常只到RSUI保护层，玩家看不出是否写入；
        -- UI不接管事务、不在异常时重试写盘。记录“命令调用”与“保存后显示”两个阶段，
        -- 业务失败由Feature保留并写诊断，显示失败不得谎称已提交的配置被回滚。
        local called,ok,detail=pcall(Feature.Commands.ImportBuiltinPack,Feature.Commands,root.libraryPack,false)
        if not called then
            local message=tostring(ok or "未知异常")
            libraryHint:SetText("导入调用异常："..message.."。尚未确认保存，请打印自检报告。")
            if S.DiagnosticsManager and type(S.DiagnosticsManager.Emit)=="function" then
                S.DiagnosticsManager:Emit("error","buff_display","BUFF_LIBRARY_IMPORT_UI_FAILED",message,
                    {pack=root.libraryPack,stage="command"})
            elseif type(S.RecordLog)=="function" then S.RecordLog("error","buff_display","BUFF_LIBRARY_IMPORT_UI_FAILED "..message) end
            return false,message
        end
        if ok~=true then
            libraryHint:SetText("导入失败："..tostring(detail or "未知错误").."；原因已进入自检报告。")
            persistHint:SetText("内置库未完成导入，请查看失败提示")
            return false,detail
        end
        -- 维护：提交成功后立刻显示持久化追踪集合；旧页面还停在实时事实视图，未出现状态看似未导入。
        -- 清除搜索和类别筛选，未知极性仍是已追踪Auto，不因切页篡改用户选择/开启HUD。
        -- 兼容旧CD收藏包：推荐包不包含CD；显式选择旧CD包时仍打开相应收藏视图，不伪装成Buff。
        local cooldownPack=root.libraryPack=="cooldown:skill" or root.libraryPack=="cooldown:mate"
        root.managementView=cooldownPack and "cooldowns" or "tracked"
        root.managementFilter="all";root.filterText="";root.managementSort="tracked"
        local shown,showErr=pcall(function()
            if searchInput and type(searchInput.SetValue)=="function" then searchInput:SetValue("",false,"library_import") end
            selectedText:SetText(tostring(detail));libraryHint:SetText(tostring(detail));persistHint:SetText(tostring(detail))
            root:SwitchTab("track");root:Refresh()
        end)
        if not shown then
            local message="追踪已保存，但列表刷新失败："..tostring(showErr)
            libraryHint:SetText(message);persistHint:SetText(message)
            if S.DiagnosticsManager and type(S.DiagnosticsManager.Emit)=="function" then
                S.DiagnosticsManager:Emit("error","buff_display","BUFF_LIBRARY_VIEW_FAILED",message,
                    {pack=root.libraryPack,stage="view",committed=true})
            elseif type(S.RecordLog)=="function" then S.RecordLog("error","buff_display",message) end
            return false,message
        end
        return true,detail
    end
    importPack.onClick=ImportPack

    ------------------------------------------------------------------
    -- Tab 2: HUD layout policy + standalone real-screen calibration.
    ------------------------------------------------------------------
    local tabLayout = RSUI:VerticalBox({ id = "v3_buff_display_tab_layout", parent = switcher, gap = 7, slot = { hAlign = "fill", vAlign = "fill" } })

    -- 中文维护注释（页面职责收敛，2026-09-11）：旧页把 640x320 的假画布塞在主菜单内部，
    -- 用户打开菜单后真实角色头顶 HUD 被遮住，拖动结果也无法和实际画面对齐。这里不再维护
    -- 第二套布局几何编辑器；主菜单只保留低频业务策略，几何/字体/图标/行数由独立
    -- BuffHudCalibrationV3 在真实 UIParent 上编辑。Authority 仍是 BuffDisplay Store。
    local introCard = RSUI:Border({ id = "v3_buff_display_layout_intro_card", parent = tabLayout, padding = 8, variant = "card",
        minHeight = 112, slot = { size = "auto", minHeight = 112, hAlign = "fill" } })
    local introStack = RSUI:VerticalBox({ id = "v3_buff_display_layout_intro_stack", parent = introCard, gap = 4, slot = { hAlign = "fill" } })
    RSUI:Text({ id = "v3_buff_display_layout_intro_title", parent = introStack, text = "HUD 校准模式", fontSize = 12, tone = "strong", slot = { size = "fixed", height = 22 } })
    RSUI:Text({ id = "v3_buff_display_layout_intro_text", parent = introStack, text = "点击“调整 HUD”后主菜单会临时最小化。可分别校准自己 / 目标 HUD，拖动预览框或用方向键、数值框精调；目标 HUD 可手动一键同步自身布局。", fontSize = 10, tone = "muted", overflow = "wrap", maxLines = 3, slot = { size = "auto", minHeight = 38, hAlign = "fill" } })
    local launchRow = RSUI:HorizontalBox({ id = "v3_buff_display_layout_launch_row", parent = introStack, gap = 8, slot = { size = "fixed", height = 32, hAlign = "fill" } })
    calibrationButton = RSUI:Button({ id = "v3_buff_display_layout_open_calibration", parent = launchRow, text = "调整 HUD", compact = false, slot = { size = "fixed", width = 132 } })
    layoutProfileSummary = RSUI:Text({ id = "v3_buff_display_layout_profile_summary", parent = launchRow, text = "自己 / 目标：独立布局", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fill", fill = 1, vAlign = "center" } })

    -- 中文维护注释（HUD 布局页响应式重排，2026-09-11）：旧版把 6 个固定宽度开关塞进
    -- 单行 HorizontalBox，再把刷新滑块塞进同一张 auto-height 卡片；在 1k/0.8 UI Scale 下
    -- 子控件宽度超过内容区且 CompactNumericSetting 自己需要多行高度，最终出现截图中的重叠。
    -- Authority 仍由 Feature Settings 持有；这里只改变 Presentation 排版，不复制任何设置状态。
    -- 三块职责固定为“校准入口 / 显示策略 / 刷新设置”，以后新增策略优先进入 Grid，禁止重新
    -- 回到一行固定按钮堆叠。
    -- 中文维护注释（.18.206 Measure 修复）：RSUI Border:Measure() 读取的是 Border 自身 spec.minHeight，
    -- 不是父 VerticalBox 的 slot.minHeight。.18.205 只把最小高度写进 slot，Native 子控件实际需要更高
    -- 时父布局仍可能按过小 desiredHeight 排下一个卡片，造成截图中的边框/文本重叠。本版把 minHeight
    -- 同时声明在组件 spec 与 slot：spec 是 Measure Authority，slot 只作为父容器的下限提示。该修复
    -- 仅影响 Presentation 几何，不读写 Store，也不改变响应式 Grid 的列数 Authority。
    local policyCard = RSUI:Border({ id = "v3_buff_display_layout_policy_card", parent = tabLayout, padding = 8, variant = "card",
        minHeight = 132, slot = { size = "auto", minHeight = 132, hAlign = "fill" } })
    local policyStack = RSUI:VerticalBox({ id = "v3_buff_display_layout_policy_stack", parent = policyCard, gap = 6, slot = { hAlign = "fill" } })
    RSUI:Text({ id = "v3_buff_display_layout_policy_title", parent = policyStack, text = "显示策略", fontSize = 11, tone = "strong", slot = { size = "fixed", height = 20 } })
    local policyToggleGrid = RSUI:UniformGrid({ id = "v3_buff_display_layout_policy_toggle_grid", parent = policyStack, minCellWidth = 96, minCellHeight = 28, maxColumns = 3, gap = 5, slot = { size = "auto", hAlign = "fill" } })
    local policySpecs = {
        { key="headEnabled", on="HUD：开", off="HUD：关", trueOnly=false },
        { key="headShowAll", on="全部：开", off="全部：关", trueOnly=true },
        { key="headPlayer", on="自己：开", off="自己：关", trueOnly=false },
        { key="headTarget", on="目标：开", off="目标：关", trueOnly=false },
        { key="headShowStacks", on="层数：开", off="层数：关", trueOnly=false },
        { key="headShowTime", on="时间：开", off="时间：关", trueOnly=false },
    }
    for _, spec in ipairs(policySpecs) do
        local key, trueOnly = spec.key, spec.trueOnly == true
        local toggle = RSUI:Toggle({
            id = "v3_buff_display_layout_policy_" .. key, parent = policyToggleGrid, width = 94, height = 24,
            onText = spec.on, offText = spec.off,
            get = function()
                local settings = Feature:GetSettingsProjection() or {}
                return trueOnly and settings[key] == true or (not trueOnly and settings[key] ~= false)
            end,
            set = function(value) return ApplySetting(key, value == true) end,
            slot = { size = "auto", hAlign = "left", vAlign = "center" },
        })
        if toggle ~= nil then layoutPolicyControls[#layoutPolicyControls + 1] = toggle end
    end
    RSUI:Text({ id = "v3_buff_display_layout_policy_hint", parent = policyStack, text = "这里仅控制 HUD 是否运行和通用文字显示；各组件位置、图标、字号、间距和尺寸统一在“调整 HUD”里设置。", fontSize = 9, tone = "muted", overflow = "wrap", maxLines = 2, slot = { size = "auto", minHeight = 28, hAlign = "fill" } })

    local refreshCard = RSUI:Border({ id = "v3_buff_display_layout_refresh_card", parent = tabLayout, padding = 8, variant = "card",
        minHeight = 104, slot = { size = "auto", minHeight = 104, hAlign = "fill" } })
    local refreshStack = RSUI:VerticalBox({ id = "v3_buff_display_layout_refresh_stack", parent = refreshCard, gap = 5, slot = { hAlign = "fill" } })
    RSUI:Text({ id = "v3_buff_display_layout_refresh_title", parent = refreshStack, text = "刷新设置", fontSize = 11, tone = "strong", slot = { size = "fixed", height = 20 } })
    local refreshGrid = RSUI:UniformGrid({ id = "v3_buff_display_layout_refresh_grid", parent = refreshStack, minCellWidth = 320, minCellHeight = 34, maxColumns = 1, gap = 4, slot = { size = "auto", hAlign = "fill" } })
    -- 维护（pvp-hud-1）：位置已独立逐帧跟随；旧headRefreshMs继续控制距离/读条，不能仍标成全HUD刷新。
    local refreshField = D:CompactNumericSetting(refreshGrid, {
        id = "v3_buff_display_layout_refresh", label = "距离/读条刷新", min = 25, max = 2000, hardMin = 1, hardMax = 2000, step = 25, integer = true, unit = "ms", slider = true,
        get = function() return tonumber((Feature:GetSettingsProjection() or {}).headRefreshMs) or 50 end,
        set = function(v) return ApplySetting("headRefreshMs", math.floor((tonumber(v) or 50) + 0.5)) end,
        slot = { size = "fill", fill = 1 },
    })
    if refreshField ~= nil then layoutPolicyControls[#layoutPolicyControls + 1] = refreshField end
    RSUI:Text({ id = "v3_buff_display_layout_refresh_hint", parent = refreshStack, text = "位置逐帧跟随，此项仅控制距离/读条。武器事件合并窗口50ms，自己装备200ms兜底。", fontSize = 9, tone = "muted", overflow = "wrap", maxLines = 2, slot = { size = "auto", minHeight = 26, hAlign = "fill" } })

    function root:RefreshLayoutControls()
        for _, control in ipairs(layoutPolicyControls) do
            if control ~= nil and type(control.Render) == "function" then control:Render() end
        end
        if layoutProfileSummary ~= nil then
            local snapshot = Feature.Commands:GetHudCalibrationSnapshot()
            local player = type(snapshot) == "table" and snapshot.player or nil
            local target = type(snapshot) == "table" and snapshot.target or nil
            local pScale = type(player) == "table" and tonumber(player.plateScale) or 1
            local tScale = type(target) == "table" and tonumber(target.plateScale) or 1
            layoutProfileSummary:SetText(string.format("自己 / 目标独立保存 · 缩放 %.2f / %.2f · 保存并退出后写入存档", pScale or 1, tScale or 1))
        end
        return true
    end

    calibrationButton.onClick = function()
        local calibration = S.UIV3 and S.UIV3.BuffHudCalibrationV3 or nil
        if type(calibration) ~= "table" or type(calibration.Open) ~= "function" then return false, "HUD 校准模块未加载" end
        local ok, err = calibration:Open({ source = "status_display_page", scope = "player", onExit = function(saved, restored, restoreErr)
            if saved == true then persistHint:SetText("HUD 校准已保存 · 自己 / 目标配置已写入")
            else persistHint:SetText("HUD 校准已取消 · 未保存本次修改") end
            if restored ~= true and restoreErr ~= nil then persistHint:SetText("HUD 校准已退出，但主菜单恢复异常：" .. tostring(restoreErr)) end
            if type(root.RefreshLayoutControls) == "function" then root:RefreshLayoutControls() end
        end })
        if ok ~= true then return false, err or "HUD 校准启动失败" end
        persistHint:SetText("HUD 校准中 · 保存并退出后写入配置")
        return true
    end
    root:RefreshLayoutControls()

    ------------------------------------------------------------------
    -- Tab 3: Import / Export.
    ------------------------------------------------------------------
    local tabTransfer = RSUI:VerticalBox({ id = "v3_buff_display_tab_transfer", parent = switcher, gap = 6, slot = { hAlign = "fill", vAlign = "fill" } })
    RSUI:Text({ id = "v3_buff_display_transfer_quick_title", parent = tabTransfer, text = "快速导入追踪 ID", fontSize = 11, tone = "strong", slot = { size = "fixed", height = 22 } })
    local quickRow = RSUI:HorizontalBox({ id = "v3_buff_display_transfer_quick_row", parent = tabTransfer, gap = 6, slot = { size = "fixed", height = 28, hAlign = "fill" } })
    local quickInput = RSUI:TextInput({
        id = "v3_buff_display_transfer_quick_input", parent = quickRow, value = "", maxLength = 256, buildOptional = true,
        allowEmpty = true, submitOnLostFocus = false, get = function() return root.quickText or "" end,
        set = function(v) root.quickText = tostring(v or ""); return true end,
        onSubmit = function(value) root.quickText = tostring(value or ""); return true end,
        slot = { size = "fill", fill = 1, minWidth = 90 },
    })
    if quickInput == nil then quickInput = RSUI:Text({ id = "v3_buff_display_transfer_quick_unavailable", parent = quickRow, text = "ID 输入框不可用", fontSize = 9, tone = "warn", slot = { size = "fill", fill = 1 } }) end
    local categorySelector, categorySelectorErr = RSUI:SegmentedSelector({
        id = "v3_buff_display_transfer_category", parent = quickRow, maxItems = 3, gap = 2, height = 24, fontSize = 9,
        items = { { value = "auto", text = "自动分类", width = 76 }, { value = "buff", text = "归入 Buff", width = 78 }, { value = "debuff", text = "归入 Debuff", width = 88 } },
        get = function() return root.importCategory or "auto" end,
        set = function(v) root.importCategory = tostring(v or "auto"); return true end,
        slot = { size = "auto" },
    })
    if categorySelector == nil then error("状态显示导入分类选择器创建失败：" .. tostring(categorySelectorErr or "unknown")) end
    local quickImport = RSUI:Button({ id = "v3_buff_display_transfer_quick_import", parent = quickRow, text = "合并导入", compact = true, slot = { size = "fixed", width = 78 } })
    local quickOverwrite = RSUI:Button({ id = "v3_buff_display_transfer_quick_overwrite", parent = quickRow, text = "覆盖导入", compact = true, slot = { size = "fixed", width = 78 } })
    local transferStatus = RSUI:Text({ id = "v3_buff_display_transfer_status", parent = tabTransfer, text = "当前追踪：--", fontSize = 9, tone = "muted", overflow = "wrap", maxLines = 3, slot = { size = "auto", minHeight = 32, hAlign = "fill" } })
    RSUI:Text({ id = "v3_buff_display_transfer_full_title", parent = tabTransfer, text = "完整导出 / 导入", fontSize = 11, tone = "strong", slot = { size = "fixed", height = 22 } })
    local transferEditHost = RSUI:Border({ id = "v3_buff_display_transfer_edit_host", parent = tabTransfer, padding = 0, variant = "card", slot = { size = "fixed", height = 168, hAlign = "fill" } })
    local transferEditAvailable = false
    if transferEditHost ~= nil and transferEditHost.root ~= nil then
        transferEdit = S.UI:CreateMultiEditBox(transferEditHost.root, "v3_buff_display_transfer_edit", 4, 4, 560, 158, 65535)
        if transferEdit ~= nil and transferEdit.AddAnchor ~= nil then pcall(transferEdit.AddAnchor, transferEdit, "BOTTOMRIGHT", transferEditHost.root, -4, -4) end
        transferEditAvailable = transferEdit ~= nil
        if transferEditAvailable == true then
            local activationOk, activationErr = S.UI:BindDeferredInputActivation(transferEdit, transferEditHost.owner,
                "v3_buff_display_transfer_edit")
            if activationOk ~= true then
                if type(S.UI.RetireInputWidget) == "function" then
                    pcall(function() S.UI:RetireInputWidget(transferEdit, transferEditHost.owner, "multiline_activation_unavailable") end)
                end
                if type(S.UI.SetVisible) == "function" then pcall(function() S.UI:SetVisible(transferEdit, false, transferEditHost.owner) end) end
                transferEditAvailable = false
                if S.DiagnosticsManager ~= nil and type(S.DiagnosticsManager.WarningRateLimited) == "function" then
                    S.DiagnosticsManager:WarningRateLimited("buff_display_v3", "BUFF_MULTILINE_INPUT_ACTIVATION_UNAVAILABLE", 5000,
                        "状态显示多行输入框无法建立安全键盘激活契约，已禁用以避免吞掉游戏按键",
                        { error = tostring(activationErr or "activation bind failed") })
                end
            end
        end
    end
    local transferBtnRow = RSUI:HorizontalBox({ id = "v3_buff_display_transfer_buttons", parent = tabTransfer, gap = 6, slot = { size = "fixed", height = 28, hAlign = "fill" } })
    local exportBtn = RSUI:Button({ id = "v3_buff_display_transfer_export", parent = transferBtnRow, text = "完整导出", compact = true, slot = { size = "fixed", width = 84 } })
    local importTextBtn = RSUI:Button({ id = "v3_buff_display_transfer_import", parent = transferBtnRow, text = "预览导入", compact = true, slot = { size = "fixed", width = 84 } })
    local transferMode=RSUI:Dropdown({id="v3_buff_transfer_mode",parent=transferBtnRow,items={{value="merge",text="合并"},{value="overwrite",text="覆盖"}},maxVisible=3,
        get=function() return root.transferMode or "merge" end,set=function(value) root.transferMode=value;root.importPreview=nil;importTextBtn:SetText("预览导入");return true end,slot={size="fixed",width=100}})
    if not transferMode then error("导入模式控件创建失败") end
    local exportTracking=RSUI:Button({id="v3_buff_export_tracking",parent=transferBtnRow,text="仅追踪",compact=true,slot={size="fixed",width=72}})
    local clearTextBtn = RSUI:Button({ id = "v3_buff_display_transfer_clear", parent = transferBtnRow, text = "清空文本框", compact = true, slot = { size = "fixed", width = 92 } })
    -- 中文维护注释：新增导出同样遵守 Native 输入激活降级边界。
    exportTracking:SetEnabled(transferEditAvailable)
    if transferEditAvailable ~= true then transferStatus:SetText("当前客户端不支持多行文本输入框；可使用上方快速导入。"); exportBtn:SetEnabled(false); importTextBtn:SetEnabled(false); clearTextBtn:SetEnabled(false) end

    ------------------------------------------------------------------
    -- Refresh / tab switching.
    ------------------------------------------------------------------
    function root:RefreshTransferStatus()
        local settings = Feature:GetSettingsProjection() or {}
        local tracked = type(settings.tracked) == "table" and settings.tracked or {}
        local buffCount = #(type(tracked.buff) == "table" and tracked.buff or {})
        local debuffCount = #(type(tracked.debuff) == "table" and tracked.debuff or {})
        transferStatus:SetText("当前追踪：Buff " .. tostring(buffCount) .. " · Debuff " .. tostring(debuffCount) .. " · Auto "..tostring(#(tracked.auto or {})).."（每类上限 1024）。")
        return true
    end

    function root:Refresh()
        local settings = Feature:GetSettingsProjection() or {}
        local enabled = S.FeatureRuntime ~= nil and S.FeatureRuntime:IsEnabled("combat_buff_display") == true
        local allRows, revision, coverage = Feature:GetManagementProjection({view=self.managementView,filter=self.managementFilter,sort=self.managementSort,query=self.filterText})
        local filtered=allRows or {}
        trackingTable:SetItems(filtered,revision)
        -- 已追踪/目录是持久化选择视图，功能关闭仍必须允许查看与取消；实时视图则明确事实不可用。
        local persistedView=self.managementView=="tracked" or self.managementView=="cooldowns"
        local freeze=Feature:GetManagementFreezeState()
        local liveCoverage=type(coverage)=="table" and coverage or {}
        local available=(liveCoverage.player and liveCoverage.player.available==true) or (liveCoverage.target and liveCoverage.target.available==true)
        local snapshotView=self.managementView=="frozen" or (self.managementView=="live" and freeze.active)
        local ready=persistedView or (snapshotView and freeze.active) or (not snapshotView and enabled and available)
        trackingTable:SetViewState(not ready and "unavailable" or (#filtered>0 and "ready" or "empty"),{
            title=not ready and (snapshotView and "尚无留存记录" or (enabled and "状态事实暂不可用" or "功能已关闭")) or "没有符合筛选的条目",detail="已追踪视图可以管理当前未出现的状态。"})
        trackingCaption:SetText((freeze.active and (self.managementView=="live" or self.managementView=="frozen") and "留存记录" or self.managementView=="tracked" and "已追踪" or self.managementView=="cooldowns" and "技能 CD" or "当前状态").." · "..#filtered.." 条"..(snapshotView and freeze.overflow and "（达到留存上限，新增未记录）" or ""))
        freezeButton:SetText(freeze.active and "停止并清空" or "冻结列表（留存）")
        freezeButton:SetEnabled(enabled)
        updateFreezeButton:SetEnabled(freeze.active)
        for _,picker in ipairs({viewPicker,filterPicker,sortPicker}) do if type(picker.Render)=="function" then picker:Render() end end
        featureButton:SetText(enabled and "关闭功能" or "启用功能")
        widgetButton:SetEnabled(enabled)
        widgetButton:SetText(WidgetHost:IsVisible("combat.buff_display") and "关闭悬浮窗" or "打开悬浮窗")
        buffButton:SetText(self.managementFilter=="tracked_buff" and "Buff ✓" or "追踪 Buff")
        debuffButton:SetText(self.managementFilter=="tracked_debuff" and "Debuff ✓" or "追踪 Debuff")
        hiddenButton:SetText(self.managementFilter=="hidden" and "隐藏 ✓" or "隐藏状态")
        if self.activeTab=="library" then self:RefreshLibrary() end
        if self.activeTab == "layout" then self:RefreshLayoutControls() end
        if self.activeTab == "transfer" then self:RefreshTransferStatus() end
        return true
    end

    function root:SwitchTab(value)
        value = tostring(value or "track")
        local index = 1
        for i, key in ipairs(TAB_KEYS) do if key == value then index = i break end end
        -- 中文维护注释：页签 Authority 同步模型和 switcher；程序化导航不能只换 Native 可见页。
        self.activeTab=TAB_KEYS[index]
        -- 页面离开目录/管理表即取消图标队列；不影响Feature采集和留存。
        Feature:SetManagementPageActive(value=="track" or value=="library")
        switcher:SetActiveIndex(index)
        if tabSelector and type(tabSelector.Render)=="function" then tabSelector:Render() end
        if transferEdit ~= nil and type(transferEdit.Show) == "function" then transferEdit:Show(value == "transfer") end
        if value=="library" then self:RefreshLibrary()
        elseif value == "layout" then
            self:RefreshLayoutControls()
        elseif value == "transfer" then self:RefreshTransferStatus() end
        return true
    end

    -- 维护：图标补全属于页面读操作，功能关闭仍需刷新内置库。事件订阅独立于战斗Consumer；
    -- 页面隐藏时整体退订，布局/导入页不被Aura节拍重绘。只响应自己Feature的统一更新事件。
    local function SubscribePageUpdates()
        if S.Events and type(S.Events.UnsubscribeInternalOwner)=="function" and type(S.Events.SubscribeInternal)=="function" then
            S.Events:UnsubscribeInternalOwner(root)
            -- 维护（library-eventbus-2，真实总线回归）：Events:Publish先传owner、再传业务参数。
            -- 旧function(reason)把root当reason，图标和追踪更新永远不进入library分支；mock漏传owner掩盖错误。
            -- 库页面只按缓存revision刷新：Aura新学到的图标也可显示，但无变更时不重建397行/不查Native。
            S.Events:SubscribeInternal("v3.buff_display.updated",root,function(_owner,_reason)
                if root.activeTab=="track" then root:Refresh()
                elseif root.activeTab=="library" then root:RefreshLibrary() end
            end)
        end
    end

    ------------------------------------------------------------------
    -- Handlers.
    ------------------------------------------------------------------
    featureButton.onClick = function()
        local enabled = S.FeatureRuntime:IsEnabled("combat_buff_display") == true
        local target = not enabled
        local ok, err = S.FeatureRuntime:SetPreferredEnabled("combat_buff_display", target, "buff_display_page")
        if ok ~= true then return false, err end
        if target then
            local acquired, acquireErr = Feature:AcquireConsumer("page:buff_display")
            if acquired ~= true then S.FeatureRuntime:SetPreferredEnabled("combat_buff_display", false, "buff_display_consumer_rollback"); root:Refresh(); return false, acquireErr or "状态显示 Consumer 启动失败" end
            SubscribePageUpdates()
            Feature.Commands:Refresh("page_enable")
        else SubscribePageUpdates() end
        return root:Refresh()
    end
    widgetButton.onClick = function() return WidgetHost:SetVisible("combat.buff_display", not WidgetHost:IsVisible("combat.buff_display"), { source = "buff_display_page" }) end
    local function SetFilter(filter) root.managementFilter=root.managementFilter==filter and "all" or filter;return root:Refresh() end
    buffButton.onClick=function() return SetFilter("tracked_buff") end
    debuffButton.onClick=function() return SetFilter("tracked_debuff") end
    hiddenButton.onClick=function() return SetFilter("hidden") end
    freezeButton.onClick=function()
        local freeze=Feature:GetManagementFreezeState();local ok,err
        if freeze.active then ok,err=Feature.Commands:ClearManagementFreeze();root.managementView="live"
        else ok,err=Feature.Commands:CaptureManagementFreeze();if ok then root.managementView="frozen" end end
        selectedText:SetText(tostring(err or (ok and "冻结状态已更新" or "冻结失败")));root:Refresh();return ok,err
    end
    updateFreezeButton.onClick=function()
        local ok,err=Feature.Commands:ResetManagementCapture();selectedText:SetText(tostring(err));root:Refresh();return ok,err
    end
    searchClear.onClick = function() root.filterText = ""; if searchInput ~= nil and type(searchInput.SetValue) == "function" then searchInput:SetValue("", false, "search_clear") end; return root:Refresh() end
    clearTrackButton.onClick = function() local ok, err = Feature.Commands:ClearTrackedIds(); if ok then root:Refresh() end; return ok, err end
    probeButton.onClick = function() local ok, summary = Feature.Commands:ProbeAuraFields(); selectedText:SetText(ok and ("字段诊断已输出到聊天框 · " .. tostring(summary)) or tostring(summary or "诊断失败")); return ok, summary end

    local function QuickImportText(mode)
        local text = quickInput ~= nil and type(quickInput.GetDraftValue) == "function" and tostring(quickInput:GetDraftValue() or "") or ""
        if text == "" then transferStatus:SetText("请先填写要导入的 Buff ID（逗号/换行分隔）。"); return true end
        local ok, err = Feature.Commands:ImportTrackedIds(text, root.importCategory or "auto", mode or "merge")
        if ok then root:Refresh(); transferStatus:SetText(tostring(err or "导入完成")) else transferStatus:SetText("导入失败：" .. tostring(err or "未知错误")) end
        return true
    end
    quickImport.onClick = function() return QuickImportText("merge") end
    quickOverwrite.onClick = function() return QuickImportText("overwrite") end
    exportBtn.onClick = function()
        if transferEdit == nil then transferStatus:SetText("多行文本框不可用，无法导出。"); return true end
        local data = Feature.Commands:ExportAll(); WriteNativeText(transferEdit, Feature.Commands:SerializeExport(data))
        local tracked = type(data) == "table" and type(data.tracked) == "table" and data.tracked or {}
        transferStatus:SetText("已导出 Buff " .. tostring(#(tracked.buff or {})) .. " · Debuff " .. tostring(#(tracked.debuff or {})) .. " 到文本框。")
        return true
    end
    -- 中文维护注释：首次只预览；再次点击时校验文本、模式与 Store revision 未变，才单事务提交。
    importTextBtn.onClick=function()
        local text=ReadNativeText(transferEdit);local mode=root.transferMode or "merge"
        local parsed=Feature.Commands:ParseImportText(text)
        if #parsed.errors>0 then root.importPreview=nil;transferStatus:SetText("解析失败："..parsed.errors[1]);return true end
        local preview=root.importPreview
        if not preview or preview.text~=text or preview.mode~=mode or preview.revision~=Feature:GetManagementSettingsRevision() then
            local ok,detail=Feature.Commands:PreviewImport(parsed.data,mode)
            transferStatus:SetText(tostring(detail));if not ok then return true end
            root.importPreview={text=text,mode=mode,revision=Feature:GetManagementSettingsRevision()}
            importTextBtn:SetText("确认导入");return true
        end
        local ok,err=Feature.Commands:ImportAll(parsed.data,mode)
        root.importPreview=nil;importTextBtn:SetText("预览导入");root:Refresh()
        transferStatus:SetText(tostring(err or (ok and "导入完成" or "导入失败")));return true
    end
    exportTracking.onClick=function()
        WriteNativeText(transferEdit,Feature.Commands:SerializeExport(Feature.Commands:ExportAll("tracking")))
        transferStatus:SetText("已导出追踪清单（不含 HUD 布局）。");return true
    end
    clearTextBtn.onClick = function() root.importPreview=nil; importTextBtn:SetText("预览导入"); WriteNativeText(transferEdit, ""); transferStatus:SetText("文本框已清空。"); return true end

    ------------------------------------------------------------------
    -- Lifecycle. HUD calibration draft is owned by the standalone overlay, not
    -- by this page; page navigation therefore never commits or replays geometry.
    ------------------------------------------------------------------
    function root:OnActivated()
        local loaded, loadErr = Feature:EnsureStoreLoaded()
        if loaded ~= true then return false, loadErr or "状态显示配置读取失败" end
        persistHint:SetText("配置已读取 · HUD 校准仅在“保存并退出”后写入")
        Feature:SetManagementPageActive(self.activeTab=="track" or self.activeTab=="library")
        SubscribePageUpdates()
        if S.FeatureRuntime:IsEnabled("combat_buff_display") == true then
            local ok, err = Feature:AcquireConsumer("page:buff_display"); if ok ~= true then return false, err end
            Feature.Commands:Refresh("page_activated")
        end
        return self:Refresh()
    end
    function root:OnDeactivated()
        Feature:SetManagementPageActive(false)
        if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        if Feature.Demand and Feature.Demand:Has("page:buff_display") then Feature:ReleaseConsumer("page:buff_display") end
        -- 校准器若仍开启，Shell 已被临时最小化，因此正常页面导航不会走到这里；
        -- 即使页面被宿主回收，Detached Draft 仍不会越过 Persistence boundary。
        return true
    end
    function root:RefreshData() return self:Refresh() end
    root.route = route
    return root
end

-- 中文维护注释（页面 Measure 契约）：v1 证明 HUD 布局三卡片把 minHeight 写入组件 spec，
-- 而不是只写父 slot。Foundation/Acceptance 只读该声明来阻止热重载残留 .205 页面继续运行；
-- 不创建额外 UI、不改变 Store Authority。
Feature.HudLayoutPageMeasureContractVersion = 1

local ok, err = PageHost:RegisterFactory(ROUTE, BuildPage)
if ok ~= true then error(err) end
