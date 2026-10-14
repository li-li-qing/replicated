------------------------------------------------------------------------
-- Replicated Suite · 人员备注页面
-- 作者：Replicated
-- QQ群：1104129461
--
-- 人员备注专页只发 Commands；选择行填草稿，后台名单刷新不能覆盖正在输入的名字或备注。
-- 表格有界复用，团队数据沿用共享 roster；页面生命周期由 PageHost 负责，没有自己的 Tick。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
local R,D,H=S.RSUI,S.UIV3Design,S.UIV3 and S.UIV3.PageHost
local F=S.Features and S.Features.PlayerNotes
if not R or not D or not H or not F then return end
local function Build(parent)
    -- 名单页覆盖Design默认12px段间距，只收紧本页；名单继续fill并独立滚动，不能为局部紧凑布局改全局主题。
    local root,err=D:PageRoot(parent,{id="v3_player_notes_page",gap=3});if not root then return nil,err end
    local binding={feature=F,featureId=F.Id,token="page:player_notes",refresh=function(page)return page:Refresh()end}
    -- 保留共享标题及诊断入口，重复的多行功能说明改为紧凑提示；刷新移到小按钮排，避免标题里的110px默认按钮。
    D:PageHeader(root,"v3_player_notes_header","人员备注",nil)
    local actions=R:HorizontalBox({id="v3_player_notes_views",parent=root,gap=3,slot={size="fixed",height=24,hAlign="fill"}})
    local toggle=D:ModuleToggleButton({id="v3_player_notes_toggle",parent=actions,text="启用功能",compact=true,height=24,fontSize=10,slot={size="fixed",width=72}})
    local refresh=R:Button({id="v3_player_notes_refresh",parent=actions,text="刷新名单",compact=true,height=24,fontSize=10,slot={size="fixed",width=68},onClick=function()return F.Commands:Refresh("notes_manual")end})
    -- RU无法提供社交窗口可见性时保留明确手动入口；点击只调用同一WidgetHost，不恢复名单事件自动弹窗。
    local popup=R:Button({id="v3_player_notes_popup",parent=actions,text="打开浮窗",compact=true,height=24,fontSize=10,slot={size="fixed",width=68},onClick=function()
        local sidecar=S.UIV3 and S.UIV3.PlayerNotesSidecar
        if not sidecar or type(sidecar.Open)~="function"then return false,"人员备注浮窗不可用"end
        return sidecar:Open()
    end})
    -- 反馈仍独立于名单更新；测高只保留实际一到两行，草稿继续由TextInput显式提交而非布局刷新写入。
    local status=R:Text({id="v3_player_notes_feedback",parent=root,text="点击名字编辑；保留名字中的服务器后缀。",overflow="wrap",fontSize=10,maxLines=2,slot={size="auto",minHeight=14,hAlign="fill"}})
    local names=R:HorizontalBox({id="v3_player_notes_editor",parent=root,gap=3,slot={size="fixed",height=24,hAlign="fill"}})
    local name=R:TextInput({id="v3_player_notes_name",parent=names,height=24,maxLength=96,commitMode="explicit",placeholder="完整角色名",slot={size="fixed",width=160}})
    local note=R:TextInput({id="v3_player_notes_note",parent=names,height=24,maxLength=384,commitMode="explicit",allowEmpty=true,placeholder="备注（清空后保存可删除）",slot={size="fill",fill=1,minWidth=140}})
    local deleteArm=nil
    local function Report(ok,why,text)status:SetText(ok and (text or "已更新") or ("失败："..tostring(why or "未执行")));return ok,why end
    local function LoadName(value)
        deleteArm=nil;name:SetValue(value,false,"notes_select");note:SetValue(F:GetNote(value),false,"notes_select");return true
    end
    -- 主页面与浮窗都按文字预算收窄按钮，名单切换统一交给下方Selector；目标请求及反馈仍走同一Feature。
    local target=R:Button({id="v3_player_notes_target",parent=actions,text="载入目标",compact=true,height=24,fontSize=10,slot={size="fixed",width=68}})
    target.onClick=function()local ok,value=F.Commands:GetTargetName();if ok then LoadName(value)end;return Report(ok,value,"已载入目标，编辑后保存")end
    -- 六种名单合并为一排，选择态随共享Projection回读；不另存视图状态、不新增消费者。
    local socialViews=R:SegmentedSelector({id="v3_player_notes_social_views",parent=root,itemWidth=48,gap=2,height=24,fontSize=10,
        items={{value="friends",text="好友"},{value="block",text="黑名单",width=58},{value="family",text="家族"},{value="expedition",text="远征队",width=58},{value="team",text="团队"},{value="saved",text="已保存",width=56}},
        get=function()return F:GetProjection().view end,set=function(v)deleteArm=nil;return F.Commands:SetView(v)end,
        slot={size="fixed",height=24,hAlign="fill"}})
    local teamScope=R:Dropdown({id="v3_player_notes_team_scope",parent=actions,height=24,
        items={{value=0,text="全部团队"},{value=1,text="团队1"},{value=2,text="团队2"}},
        get=function()return F:GetProjection().teamScope end,set=function(v)return F.Commands:SetTeamScope(v)end,
        slot={size="fixed",width=112}})
    -- 覆盖范围及错误原因仍常驻、可换行，不靠删提示伪装完整名单；普通一行提示不再预留32px。
    local coverage=R:Text({id="v3_player_notes_coverage",parent=root,text="",overflow="wrap",fontSize=10,maxLines=2,
        slot={size="auto",minHeight=14,hAlign="fill"}})
    if not refresh or not popup or not socialViews or not teamScope or not coverage then return nil,"人员名单选择器创建失败"end
    local save=R:Button({id="v3_player_notes_save",parent=names,text="保存",compact=true,height=24,fontSize=10,slot={size="fixed",width=44}})
    save.onClick=function()deleteArm=nil;local ok,why=F.Commands:SaveNote(name:GetDraftValue(),note:GetDraftValue());return Report(ok,why,"备注已提交保存")end
    local remove=R:Button({id="v3_player_notes_delete",parent=names,text="删除",compact=true,height=24,fontSize=10,slot={size="fixed",width=44}})
    remove.onClick=function()
        local value=name:GetDraftValue()
        if value=="" then return Report(false,"先选择或输入角色名")end
        if deleteArm~=value then deleteArm=value;status:SetText("再次点击删除以确认："..value);return true end
        deleteArm=nil;local ok,why=F.Commands:DeleteNote(value);if ok then note:SetValue("",false,"notes_deleted")end
        return Report(ok,why,"备注已删除")
    end
    -- 与浮窗一致采用24px行及22px表头；TableView继续拥有滚动和选择，紧凑只改变呈现尺寸。
    local tableView=R:TableView({id="v3_player_notes_table",parent=root,items={},rowHeight=24,headerHeight=22,scrollbar=true,selectable=true,selectionMode="single",
        onSortChanged=function(_,direction)return F.Commands:SetNameSort(direction)end,columns={
        -- 已保存备注编号与 /bzdel 共用；改名序或窗口尺寸不会改变备注身份，编号只占26px。
        {id="index",title="#",field="listIndex",sortable=false,size="fixed",width=26},
        {id="name",title="角色名",field="name",size="fill",fill=1,minWidth=140},
        {id="note",title="备注",field="note",sortable=false,size="fill",fill=2,minWidth=180},
        {id="source",title="来源",field="source",sortable=false,size="fixed",width=100}},slot={size="fill",fill=1,hAlign="fill",vAlign="fill"}})
    tableView.onSelectionChanged=function(index)local row=tableView:GetItem(index);if row then LoadName(row.name)end end
    function root:Refresh()
        local p=F:GetProjection();tableView:SetItems(p.rows,p.revision)
        -- 与浮窗同源的会话排序；只更新表头，不在刷新回调中再发排序命令。
        tableView:SetSortState(p.nameSort~="none"and "name"or nil,p.nameSort,false);socialViews:Render()
        -- 与浮窗同源筛选框保留Hidden布局槽，防止切团队时先在旧/初始坐标露出，再等待异步重排。
        teamScope:SetVisibility(p.view=="team"and R.Visibility.Visible or R.Visibility.Hidden);teamScope:Render()
        coverage:SetText(p.error or (p.view=="team"and "联合团队可按团队1/2查看，来源列显示团号与队伍。"or "同一完整角色名在各名单里共用备注。"))
        toggle:SetText(S.FeatureRuntime:IsEnabled(F.Id) and "关闭功能" or "启用功能")
        tableView:SetViewState(#p.rows>0 and "ready" or (p.status=="unavailable" and "error"or "empty"),{title=p.view=="saved"and "尚未保存备注"or ("当前没有可读"..tostring(p.viewLabel or "").."名单"),detail=p.error or "输入角色名和备注后保存；也可载入当前目标。"})
        return true
    end
    toggle.onClick=function()
        local targetEnabled=not S.FeatureRuntime:IsEnabled(F.Id)
        local ok,why=S.FeatureRuntime:SetPreferredEnabled(F.Id,targetEnabled,"notes_toggle");if not ok then return Report(ok,why)end
        local synced,syncErr=H:SyncFeatureConsumer(root,binding,"notes_toggle");root:Refresh();return Report(synced,syncErr,"功能状态已更新")
    end
    function root:BindUpdates()
        S.Events:UnsubscribeInternalOwner(self)
        local ok,why=S.Events:SubscribeInternal(F.UpdateTopic,self,function()root:Refresh()end)
        if ok then ok,why=H:BindFeatureConsumerLifecycle(self,binding) end
        if not ok then S.Events:UnsubscribeInternalOwner(self) end
        return ok,why
    end
    function root:OnActivated()
        local ok,why=self:BindUpdates();if not ok then return false,why end
        return H:SyncFeatureConsumer(self,binding,"notes_activated")
    end
    function root:OnDeactivated()
        S.Events:UnsubscribeInternalOwner(self)
        return H:ReleaseFeatureConsumer(self,binding,"notes_deactivated")
    end
    root.route,root.tableView="tools.player_notes",tableView
    root:Refresh();return root
end
local ok,err=H:RegisterFactory("tools.player_notes",Build);if not ok then error(err)end
