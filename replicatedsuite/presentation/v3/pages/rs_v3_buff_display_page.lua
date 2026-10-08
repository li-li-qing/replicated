------------------------------------------------------------------------
-- Replicated Suite V3 - Buff Display Page (UI_IMPLEMENTING / HUD calibration v1)
--
-- 中文维护注释：四个页面面向不同读模型；显示内容与HUD调整共用入口。
-- Four presentation surfaces:
--   1) 状态追踪  : current facts / saved selections / recorded states / local CD.
--   2) 显示内容  : scoped visibility, policies and in-world HUD calibration.
--                  Calibration owns a detached player/target draft and only
--                  Save & Exit crosses the Persistence boundary.
--   3) 导入导出  : one full export and one validated durable import.
--   4) 内置库    : visible preset groups, one durable group action and row toggles.
--
-- Presentation consumes only BuffDisplay projection/commands.  The page loads
-- the Store before constructing editable controls, so a disabled Feature can
-- never edit defaults over an unread saved payload.
------------------------------------------------------------------------
-- 维护（module-controls-diag-2）：总开关领取PageHost左上角的同一实例；原Feature/Consumer/保存回滚回调不变。
-- 只调整呈现归属，禁止在刷新中另造开关状态、重设Native父级或绑定第二个OnClick；局部选项开关保持原位。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI, D = S.RSUI, S.UIV3Design
local PageHost = S.UIV3 and S.UIV3.PageHost or nil
local WidgetHost = S.UIV3 and S.UIV3.WidgetHost or nil
local Feature = S.Features and S.Features.BuffDisplay or nil
if type(RSUI) ~= "table" or type(D) ~= "table" or type(PageHost) ~= "table" or type(WidgetHost) ~= "table" or type(Feature) ~= "table" then return end

local ROUTE = "combat.buff_display"
-- 中文维护注释：显示内容只调现有 Store Commands；UI 不直接写 Store 或访问 Native。
local TAB_KEYS = { "track", "visibility", "transfer", "library" }
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
    if widget == nil or type(widget.SetText) ~= "function" then return false,"文本框不可写" end
    local called,result=pcall(widget.SetText,widget,tostring(text or ""))
    if not called or result==false then return false,tostring(result or "文本框拒绝写入") end
    return true
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
    -- 维护（module-controls-diag-2）：主诊断入口由宿主左上角提供；完整原档只读取证仍保留，
    -- 不以普通错误摘要替代故障UDF，也不清除fence/回写默认值。
    RSUI:Text({ id="v3_buff_persistence_hint", parent=root,
        text="请先从左上角诊断复制模块报告。请保留旧存档；完整原始字段仍可从下方只读取证框获取。",
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
    root.consumerHeld = false
    root.activeTab, root.filterText = "track", ""
    root.managementView, root.managementFilter, root.managementSort, root.libraryPack = "live", "all", "id", "recommended"
    root.librarySource, root.libraryQuery, root.advancedTracking = "live", "", false
    root.visibilityScope, root.visibilityByKey = "player", {}

    D:PageHeader(root, "v3_buff_display_header", "状态显示", "统一管理状态追踪与头顶 HUD；HUD 校准会暂时最小化主菜单，在真实游戏画面上调整。", "刷新", function()
        return Feature.Commands:Refresh("page_manual")
    end)

    local actionRow = RSUI:HorizontalBox({ id = "v3_buff_display_actions", parent = root, gap = 6, slot = { size = "fixed", height = 30, hAlign = "fill" } })
    local featureButton = D:ModuleToggleButton({ id = "v3_buff_display_feature_toggle", parent = actionRow, text = "启用功能", compact = true, slot = { size = "fixed", width = 96 } })
    local widgetButton = RSUI:Button({ id = "v3_buff_display_widget_toggle", parent = actionRow, text = "打开悬浮窗", compact = true, slot = { size = "fixed", width = 116 } })
    local persistHint = RSUI:Text({ id = "v3_buff_display_persist_hint", parent = actionRow, text = "配置已读取", fontSize = 9, tone = "muted", overflow = "ellipsis", slot = { size = "fill", fill = 1, hAlign = "right" } })

    local function ApplySetting(key, value)
        local ok, err = Feature.Commands:SetSetting(key, value)
        if ok == true then root:Refresh() end
        return ok, err
    end
    local function ApplyComponentSetting(componentKey, field, value)
        local ok, err = Feature.Commands:SetComponentField(componentKey, field, value)
        if ok == true then
            -- SetComponentField owns durable HUD-layout persistence. The click is an explicit low-frequency user
            -- action, so after lane reconciliation we may run one bounded equipment refresh immediately; this avoids
            -- waiting for the 200ms backstop while adding no scan to Page Refresh/Tick. EquipmentTick itself no-ops
            -- without a consumer, preserving the feature lifecycle contract.
            if type(Feature.ReconcileLanes) == "function" then Feature:ReconcileLanes() end
            if type(Feature.EquipmentTick) == "function" then Feature:EquipmentTick(true) end
            root:Refresh()
        end
        return ok, err
    end

    local switcher
    local transferEdit = nil
    local layoutPolicyControls = {}
    local calibrationButton = nil

    local tabSelector, tabSelectorErr = RSUI:SegmentedSelector({
        id = "v3_buff_display_tabs", parent = root, maxItems = 4, gap = 2, height = 26, fontSize = 10,
        items = {
            { value = "track", text = "状态追踪", width = 92 },
            { value = "visibility", text = "显示内容", width = 80 },
            { value = "transfer", text = "导入导出", width = 80 },
            { value = "library", text = "内置库", width = 80 },
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
    -- 紧凑追踪页：一个来源入口，状态四通道与本机 CD 都在当前行操作。
    ------------------------------------------------------------------
    local tabTrack=RSUI:VerticalBox({id="v3_buff_display_tab_track",parent=switcher,gap=4,slot={hAlign="fill",vAlign="fill"}})
    local sourceNames={live="当前状态",tracked="已追踪",frozen="状态记录",cooldowns="技能 CD"}
    local toolbar=RSUI:HorizontalBox({id="v3_buff_manage_views",parent=tabTrack,gap=5,slot={size="fixed",height=28,hAlign="fill"}})
    local viewPicker=RSUI:Dropdown({id="v3_buff_manage_view",parent=toolbar,maxVisible=4,
        items={{value="live",text="当前状态"},{value="tracked",text="已追踪"},{value="frozen",text="状态记录"},{value="cooldowns",text="技能 CD"}},
        get=function()return root.managementView end,set=function(value)
            if value=="library" then return root:SwitchTab("library")end -- 兼容已有程序化入口；界面只保留上方页签。
            root.managementView=sourceNames[value] and value or "live";root.selectedManagementRow=nil
            if root.activeTab~="track" then return root:SwitchTab("track")end
            Feature:SetCooldownManagementActive(root.activeTab=="track" and root.managementView=="cooldowns")
            return root:Refresh()
        end,slot={size="fixed",width=120}})
    local searchInput=RSUI:TextInput({id="v3_buff_display_track_search",parent=toolbar,value="",maxLength=80,
        placeholder="搜索名称 / ID",onSubmit=function(value)root.filterText=tostring(value or "");return root:Refresh()end,
        slot={size="fill",fill=1,minWidth=90}})
    local searchClear=RSUI:Button({id="v3_buff_display_track_search_clear",parent=toolbar,text="清除",compact=true,slot={size="fixed",width=52}})
    local recordRow=RSUI:HorizontalBox({id="v3_buff_record_actions",parent=tabTrack,gap=5,slot={size="fixed",height=27,hAlign="fill"}})
    local freezeButton=RSUI:Button({id="v3_buff_capture_record",parent=recordRow,text="开始记录",compact=true,slot={size="fixed",width=100}})
    local updateFreezeButton=RSUI:Button({id="v3_buff_capture_reset",parent=recordRow,text="清空记录",compact=true,slot={size="fixed",width=86}})
    local recordHint=RSUI:Text({id="v3_buff_record_hint",parent=recordRow,text="只留存实际观察过的状态。",fontSize=9,tone="muted",overflow="ellipsis",slot={size="fill",fill=1}})
    recordRow:SetVisible(false)
    local cooldownEditorRow=RSUI:HorizontalBox({id="v3_buff_cooldown_editor_row",parent=tabTrack,gap=5,slot={size="fixed",height=27,hAlign="fill"}})
    local cooldownIdInput=RSUI:TextInput({id="v3_buff_cooldown_skill_id",parent=cooldownEditorRow,value="",maxLength=12,buildOptional=true,
        placeholder="手动补充技能 ID",slot={size="fixed",width=140}})
    local cooldownAddButton=RSUI:Button({id="v3_buff_cooldown_add",parent=cooldownEditorRow,text="追踪自身 CD",compact=true,slot={size="fixed",width=100}})
    RSUI:Text({id="v3_buff_cooldown_hint",parent=cooldownEditorRow,text="包含坐骑和宠物；施放后可自动发现。",fontSize=9,tone="muted",overflow="ellipsis",slot={size="fill",fill=1}})
    cooldownAddButton:SetEnabled(cooldownIdInput~=nil);cooldownEditorRow:SetVisible(false)
    local function IsEffectRow(row)return type(row)=="table" and row.id~=nil and row.kind~="skill" and row.kind~="mate" end
    local rowStatus,libraryStatus
    local function ReportTrackingFailure(code,err,context)
        if S.DiagnosticsManager and type(S.DiagnosticsManager.Emit)=="function" then
            S.DiagnosticsManager:Emit("error","buff_display",code,tostring(err),context)
        end
    end
    local function ShowResult(ok,err,label,afterSave)
        local status=root.activeTab=="library" and libraryStatus or rowStatus
        status:SetText(ok and (label or "追踪已保存") or ("保存失败："..tostring(err or "未知错误")))
        local rendered,renderErr=pcall(function()if ok and afterSave then afterSave()end;return root:Refresh()end)
        if not rendered then
            status:SetText((ok and "追踪已保存，列表刷新失败：" or "保存失败，列表刷新失败：")..tostring(renderErr))
            ReportTrackingFailure("BUFF_TRACKING_UI_FAILED",renderErr,{committed=ok==true,stage="refresh"})
        end
        return ok,err
    end
    local function RunTrackingCommand(id,label,command,afterSave)
        local called,ok,err=pcall(command)
        if not called then err=ok;ok=false;ReportTrackingFailure("BUFF_TRACKING_COMMAND_FAILED",err,{id=id,stage="command"})end
        return ShowResult(ok==true,err,label,afterSave)
    end
    local function SelectManagementRow(row)
        if type(row)~="table" or not row.id then return false end
        root.selectedManagementRow=row;return true
    end
    local channelDefs={
        {id="player_buff",title="自身 Buff",scope="player",category="buff"},
        {id="player_debuff",title="自身 Debuff",scope="player",category="debuff"},
        {id="target_buff",title="目标 Buff",scope="target",category="buff"},
        {id="target_debuff",title="目标 Debuff",scope="target",category="debuff"},
    }
    local function BaseColumns()
        return {
            {id="icon",title="",field="iconPath",cellType="icon",iconSize=16,fallbackIcon="ui/icon/icon_unknown_item.dds",size="fixed",width=22,minWidth=20,sortable=false,resizable=false},
            {id="id",title="ID",field="id",size="fixed",width=62,minWidth=52,sortable=false,resizable=false},
            {id="name",title="名字",field="name",size="fill",fill=1,minWidth=90,sortable=false},
            {id="time",title="剩余时间",size="fixed",width=96,minWidth=88,sortable=false,resizable=false,overflow="wrap",maxLines=2,
                getText=function(row)local text=row and row.timeText;return (not text or text=="" or text=="--") and "无时间" or text:gsub(" / ","\n") end},
        }
    end
    local effectColumns=BaseColumns()
    for _,definition in ipairs(channelDefs) do
        local d=definition
        effectColumns[#effectColumns+1]={id=d.id,title=d.title,cellType="button",size="fixed",width=60,minWidth=56,sortable=false,resizable=false,
            getText=function(row)
                if not IsEffectRow(row) then return "—" end
                -- RU 字体未必含勾/圈字形；直接用文字表达选择，旧 Auto 保留数据语义。
                return Feature:IsTrackedPlacement(row.id,d.scope,d.category) and "追踪" or "未追踪"
            end,
            getTone=function(row)return IsEffectRow(row) and Feature:IsTrackedPlacement(row.id,d.scope,d.category) and "green" or "red" end,
            onClick=function(row)
                if not IsEffectRow(row) then return false,"请使用技能 CD 列" end
                return RunTrackingCommand(row.id,"已保存："..tostring(row.name or row.id).." · "..d.title,function()
                    return Feature.Commands:SetTrackedPlacement(row.id,d.scope,d.category,not Feature:IsTrackedPlacement(row.id,d.scope,d.category))
                end)
            end}
    end
    local function BindEffectRow(row,item)
        if IsEffectRow(item) then Feature:QueueManagementMetadata(item.id) end
        for index,column in ipairs(row.columns or {}) do
            if column.cellType=="button" and row.cells[index] and type(row.cells[index].SetEnabled)=="function" then row.cells[index]:SetEnabled(IsEffectRow(item)) end
        end
    end
    local panel=RSUI:Border({id="v3_buff_display_tracking_panel",parent=tabTrack,padding=3,variant="card",slot={size="fill",fill=1,hAlign="fill",vAlign="fill"}})
    local stack=RSUI:VerticalBox({id="v3_buff_display_tracking_stack",parent=panel,gap=2,slot={hAlign="fill",vAlign="fill"}})
    local trackingCaption=RSUI:Text({id="v3_buff_display_tracking_caption",parent=stack,text="当前状态",fontSize=9,tone="strong",slot={size="fixed",height=18}})
    local trackingTable=RSUI:TableView({id="v3_buff_display_tracking_table",parent=stack,items={},columns=effectColumns,
        bindRow=BindEffectRow,rowHeight=25,headerHeight=24,fontSize=9,desiredRows=12,overscan=2,scrollbar=true,
        selectable=true,selectionMode="single",columnResize=false,headerInteractive=false,
        getKey=function(row)return row and row.key end,onItemActivated=SelectManagementRow,
        onSelectionChanged=function(index,_,view)local row=view and view:GetItem(index);if row then SelectManagementRow(row)end end,
        slot={size="fill",fill=1,hAlign="fill",vAlign="fill"}})
    local cooldownColumns=BaseColumns()
    cooldownColumns[#cooldownColumns+1]={id="player_cd",title="自身 CD",cellType="button",size="fixed",width=78,minWidth=70,sortable=false,resizable=false,
        getText=function(row)return row and Feature:IsUnifiedCooldownTracked(row.id) and "追踪" or "未追踪" end,
        getTone=function(row)return row and Feature:IsUnifiedCooldownTracked(row.id) and "green" or "red" end,
        onClick=function(row)
            if not row or (row.kind~="skill" and row.kind~="mate") then return false,"技能 ID 无效" end
            return RunTrackingCommand(row.id,"已保存技能 CD："..tostring(row.name or row.id),function()
                return Feature.Commands:SetUnifiedCooldownTracked(row.id,not Feature:IsUnifiedCooldownTracked(row.id))
            end)
        end}
    -- 目标没有真实冷却 API，不能拿本机读数或静态秒数冒充；保留明确不可用状态。
    cooldownColumns[#cooldownColumns+1]={id="target_cd",title="目标 CD",cellType="button",size="fixed",width=78,minWidth=70,sortable=false,resizable=false,
        getText=function()return "不支持" end,getTone=function()return "muted" end,onClick=function()return false,"当前接口不提供目标真实 CD" end}
    local cooldownTable=RSUI:TableView({id="v3_buff_cooldown_table",parent=stack,items={},columns=cooldownColumns,
        rowHeight=25,headerHeight=24,fontSize=9,desiredRows=12,overscan=2,scrollbar=true,selectable=true,selectionMode="single",columnResize=false,headerInteractive=false,
        getKey=function(row)return row and row.key end,onItemActivated=SelectManagementRow,
        onSelectionChanged=function(index,_,view)local row=view and view:GetItem(index);if row then SelectManagementRow(row)end end,
        bindRow=function(row)
            for index,column in ipairs(row.columns or {})do if column.id=="target_cd" and row.cells[index] then row.cells[index]:SetEnabled(false)end end
        end,slot={size="fill",fill=1,hAlign="fill",vAlign="fill"}})
    cooldownTable:SetVisible(false)
    local footer=RSUI:HorizontalBox({id="v3_buff_tracking_footer",parent=tabTrack,gap=4,slot={size="fixed",height=24,hAlign="fill"}})
    RSUI:Text({id="v3_buff_tracking_on_legend",parent=footer,text="追踪",fontSize=9,tone="green",slot={size="fixed",width=44}})
    RSUI:Text({id="v3_buff_tracking_off_legend",parent=footer,text="未追踪",fontSize=9,tone="red",slot={size="fixed",width=52}})
    rowStatus=RSUI:Text({id="v3_buff_tracking_status",parent=footer,text="点击“未追踪”添加，点击“追踪”取消；修改立即保存。",fontSize=9,tone="muted",overflow="ellipsis",slot={size="fill",fill=1}})
    freezeButton.onClick=function()
        local state=Feature:GetManagementFreezeState()
        local ok,err
        if state.active then ok,err=Feature.Commands:ClearManagementFreeze()else ok,err=Feature.Commands:CaptureManagementFreeze()end
        return ShowResult(ok,err,state.active and "已停止并清空记录" or "开始记录实际观察的状态")
    end
    updateFreezeButton.onClick=function()local ok,err=Feature.Commands:ResetManagementCapture();return ShowResult(ok,err,"已清空记录")end
    cooldownAddButton.onClick=function()
        local id=cooldownIdInput and tonumber(cooldownIdInput:GetDraftValue())
        return RunTrackingCommand(id,"已追踪技能 CD："..tostring(id),function()return Feature.Commands:SetUnifiedCooldownTracked(id,true)end,
            function()if cooldownIdInput then cooldownIdInput:SetValue("",false,"cooldown_add_clear")end end)
    end
    searchClear.onClick=function()root.filterText="";if searchInput then searchInput:SetValue("",false,"search_clear")end;return root:Refresh()end

    ------------------------------------------------------------------
    -- Visibility is a cold command surface over the existing scoped layout.
    -- No geometry draft, tracking mutation, Native scan or page-owned task.
    ------------------------------------------------------------------
    local tabVisibility = RSUI:VerticalBox({ id="v3_buff_display_tab_visibility", parent=switcher, gap=5,
        slot={hAlign="fill",vAlign="fill"} })
    local contentActions=RSUI:HorizontalBox({id="v3_buff_display_content_actions",parent=tabVisibility,gap=8,
        slot={size="fixed",height=30,hAlign="fill"}})
    local visibilityControls, visibilityScopeSelector = {}, nil
    local visibilityStatus = RSUI:Text({ id="v3_buff_visibility_status", parent=tabVisibility,
        text="显隐修改立即保存；位置、字号和尺寸点击“调整 HUD”。",fontSize=9,tone="muted",
        overflow="wrap",maxLines=2,slot={size="fixed",height=26,hAlign="fill"} })
    -- 每个滚动条目独立Measure；不把整个显隐表和布局卡片塞成一个无法滚到末尾的大条目。
    local contentScroll=RSUI:ScrollBox({id="v3_buff_display_content_scroll",parent=tabVisibility,orientation="vertical",gap=6,
        scrollbar=true,reserveScrollbar=true,scrollbarWidth=12,scrollbarGap=3,
        slot={size="fill",fill=1,hAlign="fill",vAlign="fill"}})
    if not contentScroll then error("显示内容滚动区域创建失败")end
    local visibilityCard=RSUI:Border({id="v3_buff_visibility_card",parent=contentScroll,padding=6,variant="card",
        slot={size="auto",hAlign="fill"}})
    local visibilityStack=RSUI:VerticalBox({id="v3_buff_visibility_stack",parent=visibilityCard,gap=4,slot={hAlign="fill"}})
    RSUI:Text({id="v3_buff_visibility_title",parent=visibilityStack,text="显示项目",fontSize=11,tone="strong",slot={size="fixed",height=20}})
    function root:RefreshVisibilityControls()
        local snapshot, err = Feature.Commands:GetHudVisibilityProjection(self.visibilityScope)
        self.visibilityByKey = {}
        if type(snapshot)=="table" then
            for _,item in ipairs(snapshot.items or {}) do self.visibilityByKey[item.key]=item end
        else visibilityStatus:SetText("显示设置不可用："..tostring(err or "未知错误")) end
        for key,control in pairs(visibilityControls) do
            local item=self.visibilityByKey[key]
            control:SetVisible(item~=nil and (not item.targetOnly or self.visibilityScope=="target"))
            control:SetEnabled(item~=nil and item.available~=false)
            if type(control.Render)=="function" then control:Render() end
        end
        if visibilityScopeSelector and type(visibilityScopeSelector.Render)=="function" then visibilityScopeSelector:Render() end
        return snapshot~=nil,err
    end
    local function ApplyVisibility(key,value)
        local ok,err=Feature.Commands:SetHudVisibility(root.visibilityScope,key,value==true)
        -- Always reread committed state, including persistence rollback. Never keep a UI-only checked value.
        root:RefreshVisibilityControls()
        local item=root.visibilityByKey[key]
        local label=key=="images" and "全部图标" or (item and item.label or key)
        local scopeLabel=root.visibilityScope=="target" and "目标" or "自身"
        local message=ok==true and ("已保存："..scopeLabel.." · "..label..(value==true and "显示" or "隐藏"))
            or ("保存失败："..tostring(err or "未知错误"))
        visibilityStatus:SetText(message);persistHint:SetText(message)
        return ok,err
    end
    visibilityScopeSelector=RSUI:SegmentedSelector({ id="v3_buff_visibility_scope",parent=contentActions,maxItems=2,
        items={{value="player",text="自身 HUD",width=120},{value="target",text="目标 HUD",width=120}},
        get=function() return root.visibilityScope end,
        set=function(value)
            if value~="player" and value~="target" then return false,"未知 HUD 范围" end
            root.visibilityScope=value
            visibilityStatus:SetText(value=="target" and "正在设置目标 HUD。" or "正在设置自身 HUD。")
            return root:RefreshVisibilityControls()
        end,slot={size="fixed",width=240,height=30} })
    calibrationButton=RSUI:Button({id="v3_buff_display_layout_open_calibration",parent=contentActions,text="调整 HUD",compact=true,
        slot={size="fixed",width=132}})
    local visibilityActions=RSUI:HorizontalBox({ id="v3_buff_visibility_actions",parent=contentScroll,gap=8,
        slot={size="fixed",height=30,hAlign="fill"} })
    local hideImages=RSUI:Button({ id="v3_buff_visibility_hide_images",parent=visibilityActions,text="隐藏全部图标",
        compact=true,slot={size="fixed",width=132} })
    local showImages=RSUI:Button({ id="v3_buff_visibility_show_images",parent=visibilityActions,text="显示全部图标",
        compact=true,slot={size="fixed",width=132} })
    hideImages.onClick=function() return ApplyVisibility("images",false) end
    showImages.onClick=function() return ApplyVisibility("images",true) end
    RSUI:Text({ id="v3_buff_visibility_images_hint",parent=contentScroll,
        text="批量操作包含职业、装备、Buff、Debuff 和技能 CD 图标；文字、施法条仍由各自开关控制。",
        fontSize=9,tone="muted",overflow="wrap",maxLines=2,slot={size="auto",minHeight=26,hAlign="fill"} })
    local visibilityGrid=RSUI:UniformGrid({ id="v3_buff_visibility_grid",parent=visibilityStack,minCellWidth=145,
        minCellHeight=30,maxColumns=3,gap=5,slot={size="auto",hAlign="fill"} })
    root:RefreshVisibilityControls()
    local initialSnapshot=Feature.Commands:GetHudVisibilityProjection("target")
    for _,definition in ipairs(type(initialSnapshot)=="table" and initialSnapshot.items or {}) do
        local key=definition.key
        local control,controlErr=RSUI:Toggle({ id="v3_buff_visibility_"..key,parent=visibilityGrid,
            onText=definition.label.."：显示",offText=definition.label.."：隐藏",height=28,
            get=function() local item=root.visibilityByKey[key];return item~=nil and item.visible==true end,
            set=function(value) return ApplyVisibility(key,value) end,
            slot={size="fill",fill=1,hAlign="fill",vAlign="center"} })
        if not control then error("显示内容开关创建失败："..key.." / "..tostring(controlErr)) end
        visibilityControls[key]=control
    end
    RSUI:Text({ id="v3_buff_visibility_policy_hint",parent=contentScroll,
        text="这些是内容开关。HUD 总开关及自身 / 目标总开关仍须开启；Buff 等内容还需存在对应追踪数据。",
        fontSize=9,tone="muted",overflow="wrap",maxLines=2,slot={size="auto",minHeight=26,hAlign="fill"} })
    root:RefreshVisibilityControls()

    ------------------------------------------------------------------
    -- 合并显示策略；真实画面校准仍持有独立草稿，只有保存并退出才写入。
    ------------------------------------------------------------------
    -- Border自身minHeight与slot下限同时声明，防止Native控件高度大于卡片Measure而重叠。
    local policyCard = RSUI:Border({ id = "v3_buff_display_layout_policy_card", parent = contentScroll, padding = 8, variant = "card",
        minHeight = 128, slot = { size = "auto", minHeight = 128, hAlign = "fill" } })
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
        local key, trueOnly, componentKey = spec.key, spec.trueOnly == true, spec.component
        local toggle = RSUI:Toggle({
            id = "v3_buff_display_layout_policy_" .. key, parent = policyToggleGrid, width = 94, height = 24,
            onText = spec.on, offText = spec.off,
            get = function()
                local settings = Feature:GetSettingsProjection() or {}
                if componentKey ~= nil then
                    local components = type(settings.components) == "table" and settings.components or {}
                    local component = type(components[componentKey]) == "table" and components[componentKey] or {}
                    return component.enabled ~= false
                end
                return trueOnly and settings[key] == true or (not trueOnly and settings[key] ~= false)
            end,
            set = function(value)
                if componentKey ~= nil then return ApplyComponentSetting(componentKey, "enabled", value == true) end
                return ApplySetting(key, value == true)
            end,
            slot = { size = "auto", hAlign = "left", vAlign = "center" },
        })
        if toggle ~= nil then layoutPolicyControls[#layoutPolicyControls + 1] = toggle end
    end
    RSUI:Text({ id = "v3_buff_display_layout_policy_hint", parent = policyStack, text = "“全部”开启时显示所有已识别状态；关闭时按追踪清单显示。", fontSize = 9, tone = "muted", overflow = "wrap", maxLines = 2, slot = { size = "auto", minHeight = 26, hAlign = "fill" } })

    -- 中文维护注释（2026-09-27，target-alias-hud-2）：目标自定义名字的编辑与几何调整已全部
    -- 收敛到“调整 HUD → 目标 HUD → 自定义名字”。显示内容页仅复用同一显隐 Command；
    -- 不复制备注编辑器、几何草稿或 Alias Store，目标切换事件仍由原生命周期按需消费。

    local refreshCard = RSUI:Border({ id = "v3_buff_display_layout_refresh_card", parent = contentScroll, padding = 8, variant = "card",
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
        return true
    end
    function root:RefreshDisplayControls()
        local ok,err=self:RefreshVisibilityControls();self:RefreshLayoutControls();return ok,err
    end

    calibrationButton.onClick = function()
        local calibration = S.UIV3 and S.UIV3.BuffHudCalibrationV3 or nil
        if type(calibration) ~= "table" or type(calibration.Open) ~= "function" then return false, "HUD 校准模块未加载" end
        local ok, err = calibration:Open({ source = "status_display_page", scope = root.visibilityScope, onExit = function(saved, restored, restoreErr)
            if saved == true then persistHint:SetText("HUD 校准已保存 · 自己 / 目标配置已写入")
            else persistHint:SetText("HUD 校准已取消 · 未保存本次修改") end
            if restored ~= true and restoreErr ~= nil then persistHint:SetText("HUD 校准已退出，但主菜单恢复异常：" .. tostring(restoreErr)) end
            if type(root.RefreshDisplayControls) == "function" then root:RefreshDisplayControls() end
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
    RSUI:Text({id="v3_buff_display_transfer_help",parent=tabTransfer,
        text="导出后全选复制，发给其他人；收到分享后粘贴到下方，再点导入。包含追踪、显示设置和 HUD 布局。",
        fontSize=10,tone="muted",overflow="wrap",maxLines=2,slot={size="auto",minHeight=32,hAlign="fill"}})
    local transferBtnRow=RSUI:HorizontalBox({id="v3_buff_display_transfer_buttons",parent=tabTransfer,gap=8,slot={size="fixed",height=30,hAlign="fill"}})
    local exportBtn=RSUI:Button({id="v3_buff_display_transfer_export",parent=transferBtnRow,text="导出",compact=true,slot={size="fixed",width=100}})
    local importTextBtn=RSUI:Button({id="v3_buff_display_transfer_import",parent=transferBtnRow,text="导入",compact=true,slot={size="fixed",width=100}})
    local transferStatus=RSUI:Text({id="v3_buff_display_transfer_status",parent=tabTransfer,
        text="导入会加入分享的追踪，并应用其中的显示设置与 HUD 布局。",fontSize=9,tone="muted",overflow="wrap",maxLines=3,
        slot={size="auto",minHeight=32,hAlign="fill"}})
    local transferEditHost = RSUI:Border({ id = "v3_buff_display_transfer_edit_host", parent = tabTransfer, padding = 0, variant = "card", minHeight=120,
        slot = { size = "fill",fill=1,minHeight=120,hAlign="fill",vAlign="fill" } })
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
    if transferEditAvailable~=true then
        root.transferFeedback="当前客户端文本框不可用，暂时无法导入或导出。"
        transferStatus:SetText(root.transferFeedback);exportBtn:SetEnabled(false);importTextBtn:SetEnabled(false)
    end

    ------------------------------------------------------------------
    -- 内置库：给不想逐个查状态的用户一个可见、独立的一键分组入口。
    -- 复用原 ImportBuiltinPack / 行内四列 / 元数据队列；不复制目录或追踪 Authority。
    ------------------------------------------------------------------
    local tabLibrary=RSUI:VerticalBox({id="v3_buff_display_tab_library",parent=switcher,gap=4,slot={hAlign="fill",vAlign="fill"}})
    RSUI:Text({id="v3_buff_library_intro",parent=tabLibrary,text="选择分组，点击“追踪本组”，无需等待这些状态出现在身上。",
        fontSize=10,tone="strong",overflow="wrap",maxLines=2,slot={size="auto",minHeight=28,hAlign="fill"}})
    local packs,packByKey={},{}
    for _,pack in ipairs(Feature:GetLibraryPacks())do
        packByKey[pack.key]=pack
        -- all 与 recommended 是同一状态并集的历史入口；展示一个推荐入口即可，旧 key 仍可读取。
        if pack.key~="all" and pack.key~="cooldown:skill" and pack.key~="cooldown:mate" then
            packs[#packs+1]={value=pack.key,text=pack.name.."（"..pack.count.."项）"}
        end
    end
    local libraryActions=RSUI:HorizontalBox({id="v3_buff_library_actions",parent=tabLibrary,gap=5,slot={size="fixed",height=30,hAlign="fill"}})
    local packPicker=RSUI:Dropdown({id="v3_buff_library_pack",parent=libraryActions,items=packs,maxVisible=8,
        get=function()return root.libraryPack end,set=function(value)
            root.libraryPack=value;libraryStatus:SetText("点击追踪本组可批量添加；每行按钮可单独添加或取消。")
            return root:RefreshLibrary()
        end,slot={size="fill",fill=1,minWidth=180}})
    local libraryImport=RSUI:Button({id="v3_buff_library_import",parent=libraryActions,text="追踪本组",compact=true,slot={size="fixed",width=148}})
    RSUI:Text({id="v3_buff_library_hint",parent=tabLibrary,
        text="批量加入自身和目标追踪，保留已配置的单列选择；完全取消的状态可重新加入。搜索只筛选列表。",
        fontSize=9,tone="muted",overflow="wrap",maxLines=2,slot={size="auto",minHeight=30,hAlign="fill"}})
    local librarySearchRow=RSUI:HorizontalBox({id="v3_buff_library_search_row",parent=tabLibrary,gap=5,slot={size="fixed",height=27,hAlign="fill"}})
    local librarySearch=RSUI:TextInput({id="v3_buff_library_search",parent=librarySearchRow,value="",maxLength=80,placeholder="搜索本组名称 / ID",
        onSubmit=function(value)root.libraryQuery=tostring(value or "");return root:RefreshLibrary()end,slot={size="fill",fill=1,minWidth=90}})
    local librarySearchClear=RSUI:Button({id="v3_buff_library_search_clear",parent=librarySearchRow,text="清除",compact=true,slot={size="fixed",width=52}})
    local libraryPanel=RSUI:Border({id="v3_buff_library_panel",parent=tabLibrary,padding=3,variant="card",slot={size="fill",fill=1,hAlign="fill",vAlign="fill"}})
    local libraryStack=RSUI:VerticalBox({id="v3_buff_library_stack",parent=libraryPanel,gap=2,slot={hAlign="fill",vAlign="fill"}})
    local libraryCaption=RSUI:Text({id="v3_buff_library_caption",parent=libraryStack,text="内置状态",fontSize=9,tone="strong",slot={size="fixed",height=18}})
    local libraryTable=RSUI:TableView({id="v3_buff_library_table",parent=libraryStack,items={},columns=effectColumns,
        bindRow=BindEffectRow,rowHeight=25,headerHeight=24,fontSize=9,desiredRows=12,overscan=2,scrollbar=true,
        selectable=true,selectionMode="single",columnResize=false,headerInteractive=false,getKey=function(row)return row and row.key end,
        onItemActivated=SelectManagementRow,onSelectionChanged=function(index,_,view)local row=view and view:GetItem(index);if row then SelectManagementRow(row)end end,
        slot={size="fill",fill=1,hAlign="fill",vAlign="fill"}})
    libraryStatus=RSUI:Text({id="v3_buff_library_status",parent=tabLibrary,text="点击追踪本组可批量添加；每行按钮可单独添加或取消。",
        fontSize=9,tone="muted",overflow="wrap",maxLines=2,slot={size="auto",minHeight=28,hAlign="fill"}})
    libraryImport.onClick=function()
        local pack=packByKey[root.libraryPack]
        if not pack or pack.key=="cooldown:skill" or pack.key=="cooldown:mate" then return ShowResult(false,"请选择内置状态分组")end
        return RunTrackingCommand(pack.key,"已保存本组追踪；点击行内“追踪”可取消对应项。",function()
            -- 用户明确追踪本组；false 走完整分组，既有显式分类仍由 Domain 保留。
            return Feature.Commands:ImportBuiltinPack(pack.key,false)
        end)
    end
    librarySearchClear.onClick=function()
        root.libraryQuery="";if librarySearch then librarySearch:SetValue("",false,"library_search_clear")end
        return root:RefreshLibrary()
    end

    ------------------------------------------------------------------
    -- Refresh / tab switching.
    ------------------------------------------------------------------
    function root:RefreshTransferStatus()
        transferStatus:SetText(self.transferFeedback or "导入会加入分享的追踪，并应用其中的显示设置与 HUD 布局。")
        return true
    end

    function root:Refresh()
        local enabled=S.FeatureRuntime and S.FeatureRuntime:IsEnabled("combat_buff_display")==true
        featureButton:SetText(enabled and "关闭功能" or "启用功能");widgetButton:SetEnabled(enabled)
        widgetButton:SetText(WidgetHost:IsVisible("combat.buff_display") and "关闭悬浮窗" or "打开悬浮窗")
        if self.activeTab=="library" then return self:RefreshLibrary()end
        local source=sourceNames[self.managementView] and self.managementView or "live"
        local rows,revision,coverage=Feature:GetManagementProjection({view=source,compact=true,preserveLive=true,sort="id",query=self.filterText})
        local cooldown=source=="cooldowns";local view=cooldown and cooldownTable or trackingTable
        -- 只有已被控件接受的 revision 才算显示成功；静态库不跟着 Aura/CD 节拍重绑。
        local displayedKey=cooldown and "displayedCooldownRevision" or "displayedEffectRevision"
        if self[displayedKey]~=revision then
            local accepted,bindErr=view:SetItems(rows or {},revision)
            if accepted==false then error(bindErr or "追踪列表更新失败")end
            self[displayedKey]=revision
        end
        trackingTable:SetVisible(not cooldown);cooldownTable:SetVisible(cooldown)
        recordRow:SetVisible(source=="frozen");cooldownEditorRow:SetVisible(cooldown)
        trackingCaption:SetText(sourceNames[source].." · "..tostring(#(rows or {})).." 条"..(source=="live" and " · 未知：未读到剩余时间" or cooldown and " · 目标真实 CD 暂不支持" or ""))
        if #(rows or {})>0 then view:SetViewState("normal")
        elseif source=="live" and tostring(self.filterText or "")=="" and (not enabled or not coverage or not ((coverage.player and coverage.player.available==true) or (coverage.target and coverage.target.available==true))) then
            view:SetViewState("unavailable",{title="当前状态尚未取得",message=enabled and "等待自身或目标状态采样；可从诊断查看读取情况。" or "请开启状态显示以读取当前自身和目标状态。"})
        elseif cooldown then view:SetViewState("empty",{title="暂无技能记录",message="施放技能后自动发现；未发现时开启游戏“显示战斗信息”，或手动补充技能 ID。"})
        else view:SetViewState("empty",{title="暂无状态",message=source=="frozen" and "开始记录后，将留存实际出现过的状态。" or "可切换列表来源或清除搜索。"})end
        local state=Feature:GetManagementFreezeState()
        freezeButton:SetText(state.active and "停止并清空" or "开始记录");freezeButton:SetEnabled(enabled)
        updateFreezeButton:SetEnabled((state.count or 0)>0)
        recordHint:SetText(state.overflow and "记录已达上限，新增状态未记录。" or state.active and "正在留存实际出现的状态。" or "记录只在本次会话中保留。")
        if type(viewPicker.Render)=="function"then viewPicker:Render()end
        if self.managementLayoutKey~=source then self.managementLayoutKey=source;switcher:InvalidateMeasure("tracking_source_changed")end
        if self.activeTab=="visibility"then self:RefreshDisplayControls()
        elseif self.activeTab=="transfer"then self:RefreshTransferStatus()end
        return true
    end
    function root:RefreshLibrary()
        local rows,revision=Feature:GetManagementProjection({view="library",pack=self.libraryPack,query=self.libraryQuery,sort="id",compact=true})
        if self.displayedLibraryRevision~=revision then
            local accepted,bindErr=libraryTable:SetItems(rows or {},revision)
            if accepted==false then error(bindErr or "内置库列表更新失败")end
            self.displayedLibraryRevision=revision
        end
        local pack=packByKey[self.libraryPack];local count=pack and tonumber(pack.count) or 0
        local supported=pack and pack.key~="cooldown:skill" and pack.key~="cooldown:mate"
        libraryImport:SetEnabled(supported and count>0)
        libraryImport:SetText("追踪本组 · "..tostring(count).."项")
        libraryCaption:SetText("本组 "..tostring(count).." 项 · 当前显示 "..tostring(#(rows or {})).." 项")
        if #(rows or {})>0 then libraryTable:SetViewState("normal")
        else libraryTable:SetViewState("empty",{title=count>0 and "没有匹配状态" or "本组暂无状态",message=count>0 and "可清除搜索查看完整分组；追踪本组仍针对全部状态。" or "请选择其他分组。"})end
        if type(packPicker.Render)=="function"then packPicker:Render()end
        return true
    end

    function root:SwitchTab(value)
        value = tostring(value or "track")
        if value=="layout" then value="visibility"end -- 保留旧程序化导航别名，不再增加一个可见页签。
        -- 程序化切页也必须关闭UIParent上的独立弹层；隐藏Switcher子页不会隐藏它。
        if RSUI.PopupCoordinator and type(RSUI.PopupCoordinator.CloseAll)=="function" then RSUI.PopupCoordinator:CloseAll()end
        local index = 1
        for i, key in ipairs(TAB_KEYS) do if key == value then index = i break end end
        -- 中文维护注释：页签 Authority 同步模型和 switcher；程序化导航不能只换 Native 可见页。
        self.activeTab=TAB_KEYS[index]
        value=self.activeTab
        -- 页面离开目录/管理表即取消图标队列；不影响Feature采集和留存。
        Feature:SetManagementPageActive(value=="track" or value=="library")
        if type(Feature.SetCooldownManagementActive)=="function" then Feature:SetCooldownManagementActive(value=="track" and self.managementView=="cooldowns") end
        switcher:SetActiveIndex(index)
        if tabSelector and type(tabSelector.Render)=="function" then tabSelector:Render() end
        if transferEdit ~= nil and type(transferEdit.Show) == "function" then transferEdit:Show(value == "transfer") end
        if value=="library" then self:RefreshLibrary()
        elseif value=="track" then self:Refresh()
        elseif value=="visibility" then self:RefreshDisplayControls()
        elseif value == "transfer" then self:RefreshTransferStatus() end
        return true
    end

    -- 中文维护（2026-10-07，release-metadata-lifecycle）：页面只在可见期间订阅生命周期。
    -- Feature 停用释放 Aura/CD 业务 Demand；仍可见的管理/内置库只保留静态名称图标补全，
    -- 不会隐式启用 Feature。离开页面的 OnDeactivated 统一取消该元数据需求与 one-shot。
    local consumerBinding = {
        feature = Feature, featureId = "combat_buff_display", token = "page:buff_display",
        onDisabled = function(page)
            Feature:SetManagementPageActive(page.activeTab == "track" or page.activeTab == "library")
            if type(Feature.SetCooldownManagementActive) == "function" then Feature:SetCooldownManagementActive(false) end
        end,
        onEnabled = function(page)
            Feature:SetManagementPageActive(page.activeTab == "track" or page.activeTab == "library")
            if type(Feature.SetCooldownManagementActive) == "function" then
                Feature:SetCooldownManagementActive(page.activeTab == "track" and page.managementView == "cooldowns")
            end
        end,
        refresh = function(page) return page:Refresh() end,
    }

    -- 维护：图标补全属于页面读操作，功能关闭仍需刷新内置库。事件订阅独立于战斗Consumer；
    -- 页面隐藏时整体退订，布局/导入页不被Aura节拍重绘。只响应自己Feature的统一更新事件。
    local function SubscribePageUpdates()
        if S.Events == nil or type(S.Events.UnsubscribeInternalOwner) ~= "function" or type(S.Events.SubscribeInternal) ~= "function" then
            return false, "内部事件总线不可用"
        end
        S.Events:UnsubscribeInternalOwner(root)
        -- 维护（library-eventbus-2，真实总线回归）：Events:Publish先传owner、再传业务参数。
        -- 旧function(reason)把root当reason，图标和追踪更新永远不进入library分支；mock漏传owner掩盖错误。
        -- 库页面只按缓存revision刷新：Aura新学到的图标也可显示，但无变更时不重建397行/不查Native。
        if S.Events:SubscribeInternal("v3.buff_display.updated",root,function(_owner,_reason)
            if root.activeTab=="track" then root:Refresh()
            elseif root.activeTab=="library" then root:RefreshLibrary() end
        end) ~= true then return false, "状态显示页面更新事件订阅失败" end
        for _,topic in ipairs({"v3.buff_display.settings","v3.buff_display.target_alias.config"}) do
            if S.Events:SubscribeInternal(topic,root,function()
                if root.activeTab=="visibility" then root:RefreshDisplayControls() end
            end) ~= true then S.Events:UnsubscribeInternalOwner(root);return false,"显示内容更新事件订阅失败" end
        end
        local lifecycleOk, lifecycleErr = PageHost:BindFeatureConsumerLifecycle(root, consumerBinding)
        if lifecycleOk ~= true then S.Events:UnsubscribeInternalOwner(root); return false, lifecycleErr end
        return true
    end

    ------------------------------------------------------------------
    -- Handlers.
    ------------------------------------------------------------------
    featureButton.onClick = function()
        local enabled = S.FeatureRuntime:IsEnabled("combat_buff_display") == true
        local target = not enabled
        local ok, err = S.FeatureRuntime:SetPreferredEnabled("combat_buff_display", target, "buff_display_page")
        if ok ~= true then return false, err end
        local synced, syncErr = PageHost:SyncFeatureConsumer(root, consumerBinding, "buff_display_page_toggle")
        if synced ~= true and target == true then
            local rolledBack, rollbackErr = S.FeatureRuntime:SetPreferredEnabled("combat_buff_display", false, "buff_display_consumer_rollback")
            root.consumerHeld = false; root:Refresh()
            if rolledBack ~= true then return false, tostring(syncErr or "状态显示 Consumer 启动失败") .. "；回滚失败：" .. tostring(rollbackErr or "unknown") end
            return false, syncErr or "状态显示 Consumer 启动失败"
        end
        if target then Feature.Commands:Refresh("page_enable") end
        return root:Refresh()
    end
    widgetButton.onClick = function() return WidgetHost:SetVisible("combat.buff_display", not WidgetHost:IsVisible("combat.buff_display"), { source = "buff_display_page" }) end
    local function TransferFeedback(message)
        root.transferFeedback=tostring(message);return transferStatus:SetText(root.transferFeedback)
    end
    exportBtn.onClick=function()
        if transferEditAvailable~=true then TransferFeedback("导出失败：文本框不可用。");return false,"文本框不可用"end
        local called,text=pcall(function()return Feature.Commands:SerializeExport(Feature.Commands:ExportAll())end)
        if not called or type(text)~="string" or text=="" then TransferFeedback("导出失败："..tostring(text or "配置文本不可用"));return false,text end
        if #text>65535 then TransferFeedback("导出失败：配置超过文本框容量，请减少追踪数量后重试。");return false,"文本超出容量"end
        local written,err=WriteNativeText(transferEdit,text)
        -- 客户端可将LF转换成CRLF；除此之外的截断/改写不能当作可分享的完整配置。
        if written~=true or ReadNativeText(transferEdit):gsub("\r\n","\n")~=text:gsub("\r\n","\n") then
            WriteNativeText(transferEdit,"");TransferFeedback("导出失败：文本框拒绝写入或改写了内容，请勿分享不完整文本。")
            return false,err or "文本框内容不完整"
        end
        TransferFeedback("已导出。点击下方文本框，全选复制后即可发给其他人。")
        return true
    end
    -- 简单分享只有一次显式导入；仍先走原严格解析/容量检查，再走原耐久复合事务。
    -- 固定merge保留用户其它追踪，导出包中的显示策略和双HUD布局由原ImportAll应用。
    importTextBtn.onClick=function()
        if transferEditAvailable~=true then TransferFeedback("导入失败：文本框不可用。");return false,"文本框不可用"end
        local text=ReadNativeText(transferEdit)
        if text:match("^%s*$") then TransferFeedback("请先粘贴其他人分享的配置，再点击导入。");return false,"导入文本为空"end
        local parsedOk,parsed=pcall(function()return Feature.Commands:ParseImportText(text)end)
        if not parsedOk or type(parsed)~="table" or type(parsed.errors)~="table" then
            TransferFeedback("导入失败："..tostring(parsed or "配置解析失败"));return false,parsed
        end
        if #parsed.errors>0 then TransferFeedback("导入失败："..tostring(parsed.errors[1]));return false,parsed.errors[1]end
        local called,ok,err=pcall(function()return Feature.Commands:ImportAll(parsed.data,"merge")end)
        if not called then err=ok;ok=false end
        if ok~=true then TransferFeedback("导入失败："..tostring(err or "未知错误"));return false,err end
        local refreshed,refreshErr=pcall(function()return root:Refresh()end)
        TransferFeedback(refreshed and "导入成功。追踪、显示设置与 HUD 布局已保存。"
            or ("配置已导入并保存，页面刷新失败："..tostring(refreshErr)))
        return true
    end

    ------------------------------------------------------------------
    -- Lifecycle. HUD calibration draft is owned by the standalone overlay, not
    -- by this page; page navigation therefore never commits or replays geometry.
    ------------------------------------------------------------------
    function root:OnActivated()
        local loaded, loadErr = Feature:EnsureStoreLoaded()
        if loaded ~= true then return false, loadErr or "状态显示配置读取失败" end
        persistHint:SetText("显隐点击即保存 · 校准需“保存并退出”")
        Feature:SetManagementPageActive(self.activeTab=="track" or self.activeTab=="library")
        if type(Feature.SetCooldownManagementActive)=="function" then Feature:SetCooldownManagementActive(self.activeTab=="track" and self.managementView=="cooldowns") end
        local subscribed, subscribeErr = SubscribePageUpdates()
        if subscribed ~= true then return false, subscribeErr end
        local synced, syncErr = PageHost:SyncFeatureConsumer(self, consumerBinding, "page_activated")
        if synced ~= true then S.Events:UnsubscribeInternalOwner(self); return false, syncErr end
        if S.FeatureRuntime:IsEnabled("combat_buff_display") == true then Feature.Commands:Refresh("page_activated") end
        return self:Refresh()
    end
    function root:OnDeactivated()
        if RSUI.PopupCoordinator and type(RSUI.PopupCoordinator.CloseAll)=="function" then RSUI.PopupCoordinator:CloseAll()end
        Feature:SetManagementPageActive(false)
        if type(Feature.SetCooldownManagementActive)=="function" then Feature:SetCooldownManagementActive(false) end
        if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        local released, releaseErr = PageHost:ReleaseFeatureConsumer(self, consumerBinding, "page_deactivated")
        -- 校准器若仍开启，Shell 已被临时最小化，因此正常页面导航不会走到这里；
        -- 即使页面被宿主回收，Detached Draft 仍不会越过 Persistence boundary。
        return released, releaseErr
    end
    function root:RefreshData() return self:Refresh() end
    root.route = route
    return root
end

-- 中文维护注释（页面 Measure 契约）：v1 证明 HUD 布局三卡片把 minHeight 写入组件 spec，
-- 而不是只写父 slot。Foundation/Acceptance 只读该声明来阻止热重载残留 .205 页面继续运行；
-- 不创建额外 UI、不改变 Store Authority。
Feature.HudLayoutPageMeasureContractVersion = 1
Feature.HudVisibilityPageContractVersion = 1
Feature.TargetAliasPageContractVersion = 2 -- .18.322：主页面不再单独编辑别名，入口统一收敛到目标 HUD 校准器。

local ok, err = PageHost:RegisterFactory(ROUTE, BuildPage)
if ok ~= true then error(err) end
