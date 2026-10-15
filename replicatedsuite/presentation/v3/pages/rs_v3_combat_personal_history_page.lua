------------------------------------------------------------------------
-- Replicated Suite · 个人战斗历史页面
-- 作者：Replicated
-- QQ群：1104129461
--
-- 本地永久战绩只读页；打开历史不领取 Combat Consumer。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
local F=S.Features and S.Features.CombatAnalytics
local D,UI,H=S.UIV3Design,S.RSUI,S.UIV3 and S.UIV3.PageHost
if not F or not D or not UI or not H then return end
-- 交换面板只持有冻结的导出文本和输入草稿；来源去重、角色校验和耐久合并均经 Feature Commands。
-- 文本只在点击操作时写入，战斗刷新不能重写多行框、抢焦点或清掉用户正在选择/粘贴的内容。
local function BuildTransfer(parent)
    local box=UI:VerticalBox({id="v3_history_transfer",parent=parent,gap=5,slot={size="auto",hAlign="fill"}})
    local actions=UI:HorizontalBox({id="v3_history_transfer_actions",parent=box,gap=5,slot={size="fixed",height=29,hAlign="fill"}})
    local export=UI:Button({id="v3_history_transfer_export",parent=actions,text="导出历史",compact=true,slot={size="fixed",width=84}})
    local import=UI:Button({id="v3_history_transfer_import",parent=actions,text="导入合并",compact=true,slot={size="fixed",width=98}})
    local clear=UI:Button({id="v3_history_transfer_clear",parent=actions,text="清除输入",compact=true,slot={size="fixed",width=76}})
    local fold=UI:Button({id="v3_history_transfer_fold",parent=actions,text="展开文本",compact=true,slot={size="fixed",width=76}})
    local status=UI:Text({id="v3_history_transfer_status",parent=box,
        text="跨电脑：导出全期历史 → 复制到另一台同角色的导入框 → 导入合并。重复导入和来回交换会去重。",
        fontSize=9,tone="muted",overflow="wrap",slot={size="auto",minHeight=28,hAlign="fill"}})
    local editorHost=UI:Border({id="v3_history_transfer_editor_host",parent=box,visible=false,padding=0,variant="card",
        slot={size="fixed",height=150,hAlign="fill"}})
    local pager=UI:HorizontalBox({id="v3_history_transfer_pager",parent=box,visible=false,gap=5,slot={size="fixed",height=28,hAlign="fill"}})
    local previous=UI:Button({id="v3_history_transfer_previous",parent=pager,text="上一段",compact=true,slot={size="fixed",width=76}})
    local partLabel=UI:Text({id="v3_history_transfer_part",parent=pager,text="",fontSize=10,tone="muted",slot={size="fill",fill=1}})
    local nextPart=UI:Button({id="v3_history_transfer_next",parent=pager,text="下一段",compact=true,slot={size="fixed",width=76}})
    local edit,available,packet,partIndex,confirmId=nil,false,nil,1,nil
    if S.UI and type(S.UI.CreateMultiEditBox)=='function' and type(S.UI.BindDeferredInputActivation)=='function' then
        edit=S.UI:CreateMultiEditBox(editorHost.root,"v3_history_transfer_edit",4,4,360,142,8192)
        -- 复制框请求共享的选区保护：迟到失焦但焦点仍明确属于本框时保留 Ctrl+C；真正离框/切页仍归还键盘。
        if edit then available=S.UI:BindDeferredInputActivation(edit,editorHost.owner,"history_transfer_edit",{preserveFocusedSelection=true})==true end
    end
    local controller={}
    function controller:Deactivate()
        if edit and S.UI and type(S.UI.DeactivateInputWidget)=='function' then
            S.UI:DeactivateInputWidget(edit,editorHost.owner,"history_transfer_hidden")
        end
    end
    local layout=editorHost.Layout
    function editorHost:Layout(x,y,width,height)
        local result=layout(self,x,y,width,height)
        if edit then
            -- 裸多行输入仍复用 Suite Native 工厂和输入治理；几何随 RSUI 宿主，不使用固定分辨率定位。
            S.UI:EnsureAnchor(edit,self.root,4,4,self.owner)
            S.UI:EnsureExtent(edit,math.max(1,width-8),math.max(1,height-8),self.owner)
        end
        return result
    end
    local function OpenEditor(open)
        if not open then controller:Deactivate() end
        editorHost:SetVisible(open);fold:SetText(open and "收起文本" or "展开文本")
        pager:SetVisible(open and packet~=nil and #packet.parts>1)
    end
    local function Write(text)
        if not available then return false,'当前客户端历史文本框不可用' end
        local ok,result=pcall(edit.SetText,edit,text)
        local read,actual=pcall(edit.GetText,edit)
        if not ok or result==false or not read or type(actual)~='string' or actual:gsub('\r\n','\n')~=text:gsub('\r\n','\n') then
            return false,'文本框回读不完整，请勿使用本次导出；重新复制或重载后再试'
        end
        return true
    end
    local function ShowPart(index)
        if not packet then return false,'请先导出历史' end
        local text=packet.parts[index];if not text then return false,'导出分段不存在' end
        local ok,err=Write(text);if not ok then status:SetText('导出失败：'..tostring(err));return false,err end
        partIndex=index;OpenEditor(true);partLabel:SetText('第 '..index..' / '..#packet.parts..' 段 · 全部分段组成一份历史')
        previous:SetEnabled(index>1);nextPart:SetEnabled(index<#packet.parts)
        status:SetText('已导出全期历史。点击文本框，全选复制；长历史需逐段发送，另一台每粘贴一段后点击“导入合并”。')
        return true
    end
    export.spec.onClick=function()
        local value,err=F.Commands:ExportPersonalHistory()
        if not value then status:SetText('导出失败：'..tostring(err));return false,err end
        packet=value;confirmId=nil;import:SetText('导入合并');F.Commands:ClearPersonalHistoryImport()
        return ShowPart(1)
    end
    import.spec.onClick=function()
        if not available then return false,'历史文本框不可用' end
        OpenEditor(true)
        local read,text=pcall(edit.GetText,edit)
        if not read or type(text)~='string' or text:match('^%s*$') then status:SetText('请在文本框粘贴另一台电脑导出的历史，再点“导入合并”。');return false,'导入文本为空' end
        local ok,result=F.Commands:ImportPersonalHistory(text,{confirmPackageId=confirmId})
        if ok~=true then status:SetText('导入失败：'..tostring(result));return false,result end
        packet=nil;pager:SetVisible(false)
        if result.requiresConfirmation then
            confirmId=result.packageId;import:SetText('确认合并旧档');status:SetText(result.warning)
        elseif result.complete then
            confirmId=nil;import:SetText('导入合并')
            status:SetText(result.changed and '历史已合并并保存。可以继续导出传回另一台电脑，已有来源不会重复累计。' or '这份历史已合并，无需重复累计。')
        else
            confirmId=nil;import:SetText('导入合并');status:SetText('已接收 '..result.received..' / '..result.total..' 段；集齐后一次合并保存。请粘贴下一段。')
        end
        return true
    end
    clear.spec.onClick=function()
        controller:Deactivate();packet=nil;confirmId=nil;F.Commands:ClearPersonalHistoryImport()
        local ok,err=Write('');pager:SetVisible(false);import:SetText('导入合并');status:SetText('输入与未完成的分段接收已清除，已保存的历史保留。')
        return ok,err
    end
    fold.spec.onClick=function()OpenEditor(editorHost.visible~=true);return true end
    previous.spec.onClick=function()return ShowPart(partIndex-1)end
    nextPart.spec.onClick=function()return ShowPart(partIndex+1)end
    if not available or type(F.Commands.ExportPersonalHistory)~='function' or type(F.Commands.ImportPersonalHistory)~='function' then
        export:SetEnabled(false);import:SetEnabled(false);clear:SetEnabled(false);fold:SetEnabled(false)
        status:SetText('当前历史交换组件或文本输入不可用；历史查询与记录仍可正常使用。')
    end
    return controller
end
local function Build(parent)
    -- 与总览统一边距和导航顺序，不能让不同长度的页面说明移动鼠标下方的三个切换按钮。
    local root,err=D:PageRoot(parent,{id="v3_personal_history_page",padding=4,gap=7})
    if not root then error(err) end
    local scope=D:CombatStatisticsControls(root,"history")
    -- 导航留在固定根中，只有查询正文滚动；否则回到曾滚动的历史页时，导航仍会跳走或被裁掉。
    local content,contentErr=D:ScrollablePageRoot(root,{id="v3_personal_history_page_body",padding=0,gap=7,
        slot={size="fill",fill=1,hAlign="fill",vAlign="fill"}})
    if not content then error(contentErr or "个人历史滚动正文不可用") end
    D:PageHeader(content,"v3_personal_history_header","个人战斗历史","仅记录功能开启期间的个人数据；记录保存在本地当前角色存档。清空实时统计不会删除这里的记录。")
    local transfer=BuildTransfer(content) -- 全期交换独立于下方日期筛选；不把一个日期子集误当作完整来源覆盖旧档。
    local ranges=UI:HorizontalBox({id="v3_personal_history_ranges",parent=content,gap=8,slot={size="fixed",height=32,hAlign="fill"}})
    UI:Text({id="v3_personal_history_range_label",parent=ranges,text="日期范围：",slot={size="fixed",width=80}})
    local from=UI:TextInput({id="v3_personal_history_from",parent=ranges,value="",maxLength=10,allowEmpty=true,buildOptional=true,submitOnLostFocus=false,
        slot={size="fill",fill=1,minWidth=110},onSubmit=function() return root:RefreshData() end})
    local to=UI:TextInput({id="v3_personal_history_to",parent=ranges,value="",maxLength=10,allowEmpty=true,buildOptional=true,submitOnLostFocus=false,
        slot={size="fill",fill=1,minWidth=110},onSubmit=function() return root:RefreshData() end})
    UI:Button({id="v3_personal_history_query",parent=ranges,text="查询",compact=true,slot={size="fixed",width=70},onClick=function()
        if from then from:SetValue(from:GetDraftValue(),false) end
        if to then to:SetValue(to:GetDraftValue(),false) end
        return root:RefreshData()
    end})
    UI:Button({id="v3_personal_history_all",parent=ranges,text="全期累计",compact=true,slot={size="fixed",width=100},onClick=function()
        if from then from:SetValue("") end;if to then to:SetValue("") end;return root:RefreshData()
    end})
    -- 查询和结果同属滚动正文；顶层只保留稳定导航，不改变历史的读取/存储 Authority。
    UI:Text({id="v3_personal_history_range_hint",parent=content,text="日期：YYYY-MM-DD（含首尾当天）；留空查询全部。服务器时间，分钟精度。列表显示最近120个记录日，累计包含完整查询范围。",fontSize=9,tone="muted",overflow="wrap",slot={size="auto",minHeight=30}})
    local period=UI:Text({id="v3_personal_history_period",parent=content,text="记录期间：--",fontSize=10,tone="strong",overflow="wrap",slot={size="auto",minHeight=26}})
    local totals=UI:Text({id="v3_personal_history_totals",parent=content,text="--",fontSize=12,tone="strong",overflow="wrap",slot={size="auto",minHeight=44}})
    local details=UI:Text({id="v3_personal_history_evidence",parent=content,text="--",fontSize=9,tone="muted",overflow="wrap",slot={size="auto",minHeight=48}})
    local tableView=UI:TableView({id="v3_personal_history_table",parent=content,items={},rowHeight=24,headerHeight=25,desiredRows=14,scrollbar=true,columnResize=true,
        columns={
            {id="date",title="日期",field="dateDisplay",size="fixed",width=92,minWidth=66},
            {id="period",title="采集起止",field="period",size="fill",fill=1,minWidth=90},
            {id="damage",title="伤害",field="damage",size="fixed",width=70,minWidth=38},
            {id="healing",title="治疗",field="healing",size="fixed",width=70,minWidth=38},
            {id="taken",title="承伤",field="taken",size="fixed",width=70,minWidth=38},
            {id="kills",title="击杀玩家",field="kills",size="fixed",width=76,minWidth=56},
            {id="deaths",title="死亡",field="deaths",size="fixed",width=42,minWidth=28},
        },slot={size="fixed",height=410,hAlign="fill"}})
    function root:RefreshData()
        scope:Render()
        local p=F:GetPersonalHistoryProjection({fromDate=from and from:GetValue() or "",toDate=to and to:GetValue() or ""})
        if p.available~=true then period:SetText(tostring(p.error or "历史不可用"));totals:SetText("--");details:SetText("");tableView:SetItems({},"history_error");return true end
        local t=p.totals or {}
        period:SetText("全期记录："..tostring(p.firstAt or "尚无已知时间样本").." → "..tostring(p.lastAt or "--"))
        totals:SetText("所选期间 · 击杀玩家 "..tostring(t.kills or 0).." · 死亡 "..tostring(t.deaths or 0)
            .."\n伤害 "..tostring(t.damage or 0).." · 承伤 "..tostring(t.taken or 0).." · 治疗 "..tostring(t.healing or 0))
        details:SetText(tostring(p.coverage or "").."\n旧版推断记录（不计入上述击杀）：玩家 "..tostring(t.inferredKills or 0)
            ..(p.complete==false and " · 此日期筛选不完整：存在早期归档或未定日期记录" or "")
            ..(p.archiveTo and (" · 早期归档截至 "..tostring(p.archiveTo).."（计入全期累计）") or "")
            ..(p.error and (" · 保存异常："..tostring(p.error)) or ""))
        local rows={}
        for i,row in ipairs(p.rows or {}) do
            if i>120 then break end
            row.dateDisplay=row.date=="unknown" and "日期未定" or row.date
            row.period=tostring(row.firstAt or "--"):sub(12).." → "..tostring(row.lastAt or "--"):sub(12)
            rows[#rows+1]=row
        end
        tableView:SetItems(rows,"personal_history:"..tostring(p.revision)..":"..tostring(from and from:GetValue() or "")..":"..tostring(to and to:GetValue() or ""))
        return true
    end
    function root:OnActivated()
        self.combatStatisticsActive=true -- 历史查询同样只在可见期间合并战斗通知，不领取采集 Consumer。
        if S.Events and S.Events.SubscribeInternal then
            S.Events:SubscribeInternal("v3.combat_analytics.updated",self,function() return D:RequestCombatStatisticsRefresh(root,root.RefreshData) end)
            S.Events:SubscribeInternal("v3.combat_analytics.feature_updated",self,function() root:RefreshData() end)
        end
        return self:RefreshData()
    end
    function root:OnDeactivated()
        transfer:Deactivate() -- 隐藏输入按共享所有权契约归还键盘，不能影响游戏聊天或其它页面输入。
        D:CancelCombatStatisticsRefresh(self) -- 切页后不能留下排序每日历史或重提表格的延迟任务。
        if S.Events and S.Events.UnsubscribeInternalOwner then S.Events:UnsubscribeInternalOwner(self) end
        return true
    end
    return root
end
local ok,err=H:RegisterFactory("combat.personal_history",Build);if ok~=true then error(err) end
