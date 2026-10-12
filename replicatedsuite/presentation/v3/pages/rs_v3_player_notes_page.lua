------------------------------------------------------------------------
-- 中文维护：人员备注专页只发 Commands；选择行填草稿，后台名单刷新不能覆盖正在输入的名字或备注。
-- 表格有界复用，团队数据沿用共享 roster；页面生命周期由 PageHost 负责，没有自己的 Tick。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
local R,D,H=S.RSUI,S.UIV3Design,S.UIV3 and S.UIV3.PageHost
local F=S.Features and S.Features.PlayerNotes
if not R or not D or not H or not F then return end
local function Build(parent)
    local root,err=D:PageRoot(parent,"v3_player_notes_page");if not root then return nil,err end
    local binding={feature=F,featureId=F.Id,token="page:player_notes",refresh=function(page)return page:Refresh()end}
    -- 中文维护：名单事件不等于窗口开关；说明实际触发与手动关闭方式，不能继续承诺跟随原生社交窗口收起。
    D:PageHeader(root,"v3_player_notes_header","人员备注","好友、黑名单、家族、远征队及团队共用账号备注；名单事件弹窗，手动关闭。远征队按原生成员当前页显示。","刷新",function()return F.Commands:Refresh("notes_manual")end)
    local actions=R:HorizontalBox({id="v3_player_notes_views",parent=root,gap=6,slot={size="fixed",height=30,hAlign="fill"}})
    local toggle=D:ModuleToggleButton({id="v3_player_notes_toggle",parent=actions,text="启用功能",compact=true,slot={size="fixed",width=90}})
    local status=R:Text({id="v3_player_notes_feedback",parent=root,text="保存的备注可在社交名单中显示；请保留名字中的服务器后缀。",overflow="wrap",fontSize=10,slot={size="auto",minHeight=28,hAlign="fill"}})
    local names=R:HorizontalBox({id="v3_player_notes_editor",parent=root,gap=6,slot={size="fixed",height=32,hAlign="fill"}})
    local name=R:TextInput({id="v3_player_notes_name",parent=names,maxLength=96,commitMode="explicit",placeholder="完整角色名",slot={size="fixed",width=180}})
    local note=R:TextInput({id="v3_player_notes_note",parent=names,maxLength=384,commitMode="explicit",allowEmpty=true,placeholder="备注（清空后保存可删除）",slot={size="fill",fill=1,minWidth=180}})
    local deleteArm=nil
    local function Report(ok,why,text)status:SetText(ok and (text or "已更新") or ("失败："..tostring(why or "未执行")));return ok,why end
    local function LoadName(value)
        deleteArm=nil;name:SetValue(value,false,"notes_select");note:SetValue(F:GetNote(value),false,"notes_select");return true
    end
    for _,view in ipairs({{id="saved",text="已保存备注"},{id="team",text="当前团队"}})do
        local key,label=view.id,view.text
        local button=R:Button({id="v3_player_notes_view_"..key,parent=actions,text=label,compact=true,slot={size="fixed",width=104}})
        button.onClick=function()deleteArm=nil;return Report(F.Commands:SetView(key))end
    end
    local target=R:Button({id="v3_player_notes_target",parent=actions,text="载入当前目标",compact=true,slot={size="fixed",width=116}})
    target.onClick=function()local ok,value=F.Commands:GetTargetName();if ok then LoadName(value)end;return Report(ok,value,"已载入目标，编辑后保存")end
    -- 中文维护（2026-10-13）：新增四类名单独占一排，沿用Commands和PageHost；不扩大原工具排宽度。
    local socialViews=R:SegmentedSelector({id="v3_player_notes_social_views",parent=root,itemWidth=96,gap=4,height=28,
        items={{value="friends",text="好友"},{value="block",text="黑名单"},{value="family",text="家族"},{value="expedition",text="远征队"}},
        get=function()return F:GetProjection().view end,set=function(v)deleteArm=nil;return F.Commands:SetView(v)end,
        slot={size="fixed",height=32,hAlign="fill"}})
    local teamScope=R:Dropdown({id="v3_player_notes_team_scope",parent=actions,
        items={{value=0,text="全部团队"},{value=1,text="团队1"},{value=2,text="团队2"}},
        get=function()return F:GetProjection().teamScope end,set=function(v)return F.Commands:SetTeamScope(v)end,
        slot={size="fixed",width=112}})
    local coverage=R:Text({id="v3_player_notes_coverage",parent=root,text="",overflow="wrap",fontSize=10,maxLines=2,
        slot={size="fixed",height=32,hAlign="fill"}})
    if not socialViews or not teamScope or not coverage then return nil,"人员名单选择器创建失败"end
    local save=R:Button({id="v3_player_notes_save",parent=names,text="保存",compact=true,slot={size="fixed",width=64}})
    save.onClick=function()deleteArm=nil;local ok,why=F.Commands:SaveNote(name:GetDraftValue(),note:GetDraftValue());return Report(ok,why,"备注已提交保存")end
    local remove=R:Button({id="v3_player_notes_delete",parent=names,text="删除",compact=true,slot={size="fixed",width=64}})
    remove.onClick=function()
        local value=name:GetDraftValue()
        if value=="" then return Report(false,"先选择或输入角色名")end
        if deleteArm~=value then deleteArm=value;status:SetText("再次点击删除以确认："..value);return true end
        deleteArm=nil;local ok,why=F.Commands:DeleteNote(value);if ok then note:SetValue("",false,"notes_deleted")end
        return Report(ok,why,"备注已删除")
    end
    local tableView=R:TableView({id="v3_player_notes_table",parent=root,items={},rowHeight=28,headerHeight=28,scrollbar=true,selectable=true,selectionMode="single",columns={
        {id="name",title="角色名",field="name",size="fill",fill=1,minWidth=140},
        {id="note",title="备注",field="note",size="fill",fill=2,minWidth=180},
        {id="source",title="来源",field="source",size="fixed",width=100}},slot={size="fill",fill=1,hAlign="fill",vAlign="fill"}})
    tableView.onSelectionChanged=function(index)local row=tableView:GetItem(index);if row then LoadName(row.name)end end
    function root:Refresh()
        local p=F:GetProjection();tableView:SetItems(p.rows,p.revision);socialViews:Render()
        -- 中文维护：与浮窗同源筛选框保留Hidden布局槽，防止切团队时先在旧/初始坐标露出，再等待异步重排。
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
