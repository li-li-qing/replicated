------------------------------------------------------------------------
-- 统一统计的低频配置页：只读 Feature 投影，经原 Commands/Binding 写既有 Store。
-- 指标按任务分组；不读取 Native、不持有 Combat Consumer、不生成另一套设置默认值。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
local UI,D,H=S.RSUI,S.UIV3Design,S.UIV3 and S.UIV3.PageHost
local A=S.Features and S.Features.CombatAnalytics
local F=S.Features and S.Features.DPS
if not UI or not D or not H or not A or not F then return end
local GROUPS={
    {title="基础战绩",rows={{"kills","击杀玩家 / 死亡","关闭仅暂停实时战绩排行，个人战绩继续保留。"}}},
}
local function Build(parent)
    local root,err=D:ScrollablePageRoot(parent,{id="v3_statistics_config_page",padding=8,gap=8})
    if not root then error(err) end
    D:PageHeader(root,"v3_statistics_config_header","战斗统计设置","采集项目与显示设置即时生效并自动保存；当前角色的个人历史独立保留。")
    local scope=D:CombatStatisticsControls(root,"settings")
    local toggles={};local selectedBoss="";local lastBossToken
    local function Note(parent,id,text)
        return UI:Text({id=id,parent=parent,text=text,fontSize=9,tone="muted",overflow="wrap",slot={size="auto",minHeight=18}})
    end
    local function Section(id,title,subtitle)
        local box=UI:VerticalBox({id=id,parent=root,gap=5,slot={size="auto",hAlign="fill"}})
        UI:Text({id=id.."_title",parent=box,text=title,fontSize=12,tone="strong",slot={size="fixed",height=23}})
        if subtitle then Note(box,id.."_hint",subtitle) end
        return box
    end
    local collection=Section("v3_statistics_config_collection","采集项目","仅计算伤害、治疗、承伤、击杀玩家、死亡，与战斗总览共用一次采集。总开关关闭时停止采集。")
    for groupIndex,group in ipairs(GROUPS) do
        UI:Text({id="v3_statistics_config_group_"..groupIndex,parent=collection,text=group.title,fontSize=10,tone="strong",slot={size="fixed",height=20}})
        local grid=UI:UniformGrid({id="v3_statistics_config_grid_"..groupIndex,parent=collection,minCellWidth=205,minCellHeight=74,maxColumns=3,preferredColumns=3,columnGap=6,rowGap=6,slot={size="auto",hAlign="fill"}})
        for _,row in ipairs(group.rows) do
            local id,title,description=row[1],row[2],row[3]
            local card=UI:VerticalBox({id="v3_statistics_config_card_"..id,parent=grid,gap=3,slot={hAlign="fill",vAlign="fill"}})
            local toggle=UI:Toggle({id="v3_statistics_config_metric_"..id,parent=card,onText=title.."：开启",offText=title.."：关闭",
                get=function() return A:IsMetricPreferenceEnabled(id) end,set=function(value) return A.Commands:SetMetricEnabled(id,value) end,
                slot={size="fixed",height=28,hAlign="fill"}})
            toggles[#toggles+1]=toggle
            Note(card,"v3_statistics_config_note_"..id,description)
        end
    end
    local display=Section("v3_statistics_config_display","排行与悬浮窗","显示行数只影响呈现，不截断已采集的数据。悬浮窗随统计总开关启停。")
    local displayGrid=UI:UniformGrid({id="v3_statistics_config_display_grid",parent=display,minCellWidth=190,minCellHeight=32,maxColumns=2,preferredColumns=2,columnGap=6,rowGap=6,slot={size="auto",hAlign="fill"}})
    local side=UI:Toggle({id="v3_statistics_config_side",parent=displayGrid,onText="悬浮排行：敌方",offText="悬浮排行：友方",
        get=function() return F:GetSettingsProjection().side=="enemy" end,
        set=function(v) return F.Commands:ApplySettingFromBinding("side",v and "enemy" or "friendly") end,
        storeId=F.StoreId,persistDelayMs=300,persistReason="dps_side",slot={hAlign="fill",vAlign="fill"}})
    local mode=UI:Toggle({id="v3_statistics_config_mode",parent=displayGrid,onText="悬浮模式：PVE",offText="悬浮模式：PVP",
        get=function() return F:GetSettingsProjection().mode=="PVE" end,
        set=function(v) return F.Commands:ApplySettingFromBinding("mode",v and "PVE" or "PVP") end,
        storeId=F.StoreId,persistDelayMs=300,persistReason="dps_mode",slot={hAlign="fill",vAlign="fill"}})
    local own=UI:Toggle({id="v3_statistics_config_self",parent=displayGrid,onText="始终显示自己：开启",offText="始终显示自己：关闭",
        get=function() return F:GetSettingsProjection().alwaysShowSelf==true end,
        set=function(v) return F.Commands:ApplySettingFromBinding("alwaysShowSelf",v==true) end,
        storeId=F.StoreId,persistDelayMs=300,persistReason="dps_self",slot={hAlign="fill",vAlign="fill"}})
    local rows=D:NumericSetting(display,{id="v3_statistics_config_rows",label="显示行数",hint="自身模式固定显示自己的记录；所有人模式和悬浮窗使用此上限。",
        min=1,max=150,step=1,integer=true,unit=" 名",slider=true,stepButtons=false,
        get=function() return F:GetSettingsProjection().displayRows end,set=function(v) return F.Commands:ApplySettingFromBinding("displayRows",v) end,
        storeId=F.StoreId,persistDelayMs=300,persistReason="dps_rows",slot={size="auto",hAlign="fill"}})
    local boss=Section("v3_statistics_config_boss","首领标记","手动维护首领名称，沿用伤害排行的首领识别规则。")
    local input=UI:TextInput({id="v3_statistics_config_boss_input",parent=boss,value="",maxLength=64,allowEmpty=true,buildOptional=true,submitOnLostFocus=false,
        onSubmit=function(value) return root:AddBoss(value) end,slot={size="fixed",height=30,hAlign="fill"}})
    if not input then Note(boss,"v3_statistics_config_boss_unavailable","当前客户端不支持名称输入；已有首领标记仍可查看和移除。") end
    local bossButtons=UI:HorizontalBox({id="v3_statistics_config_boss_buttons",parent=boss,gap=6,slot={size="fixed",height=30,hAlign="fill"}})
    local add=UI:Button({id="v3_statistics_config_boss_add",parent=bossButtons,text="添加首领名称",compact=true,enabled=input~=nil,
        onClick=function() if input then return input:Submit("button") end;return false,"名称输入不可用" end,slot={size="fixed",width=112}})
    local dropdown=UI:Dropdown({id="v3_statistics_config_boss_list",parent=bossButtons,items={},maxVisible=8,
        get=function() return selectedBoss end,set=function(value) selectedBoss=tostring(value or "");return true end,
        onChanged=function(value) selectedBoss=tostring(value or "");root:RefreshData() end,slot={size="fill",fill=1}})
    local remove=UI:Button({id="v3_statistics_config_boss_remove",parent=bossButtons,text="移除所选",compact=true,slot={size="fixed",width=90}})
    local bossSummary=Note(boss,"v3_statistics_config_boss_summary","暂无首领标记")
    local function Action(id,button,text,execute,onSuccess)
        return S.ActionRunner:Run({id="statistics_config."..id,button=button,notify=true,busyText="处理中…",successText=text,
            execute=execute,errorText=function(reason) return tostring(reason or "设置失败") end,
            onSuccess=function() if onSuccess then onSuccess() end;root:RefreshData() end})
    end
    function root:AddBoss(value)
        if not input then return false,"名称输入不可用" end
        return Action("add_boss",add,"已添加首领名称。",function() return F.Commands:AddBossName(value) end,
            function() input:SetValue("") end)
    end
    remove.spec.onClick=function()
        return Action("remove_boss",remove,"已移除首领标记。",function()
            if selectedBoss=="" then return false,"请先选择首领标记" end
            return F.Commands:RemoveBossName(selectedBoss)
        end)
    end
    function root:RefreshData()
        scope:Render();for _,toggle in ipairs(toggles) do toggle:Render() end
        side:Render();mode:Render();own:Render();rows:Render()
        local names=F:GetBossNames() or {};local items,parts,found={},{},false
        for _,name in ipairs(names) do
            items[#items+1]={value=name,text=name};parts[#parts+1]=name;if name==selectedBoss then found=true end
        end
        local token=table.concat(parts,"\31")
        if token~=lastBossToken then
            lastBossToken=token;if not found then selectedBoss=names[1] or "" end
            dropdown:SetItems(items)
        end
        dropdown:Render();remove:SetEnabled(selectedBoss~="")
        bossSummary:SetText(#names==0 and "暂无首领标记" or ("已保存 "..#names.." 个首领名称"))
        return true
    end
    function root:OnActivated()
        local ok,err=A:EnsureStoreLoaded();if ok~=true then return false,err end
        ok,err=F:EnsureStoreLoaded();if ok~=true then return false,err end
        if S.Events and S.Events.SubscribeInternal then
            S.Events:SubscribeInternal("v3.combat_analytics.feature_updated",self,function() root:RefreshData() end)
            S.Events:SubscribeInternal("v3.dps.settings",self,function() root:RefreshData() end)
        end
        return self:RefreshData()
    end
    function root:OnDeactivated() if S.Events and S.Events.UnsubscribeInternalOwner then S.Events:UnsubscribeInternalOwner(self) end;return true end
    return root
end
local ok,err=H:RegisterFactory("combat.statistics_settings",Build);if ok~=true then error(err) end
