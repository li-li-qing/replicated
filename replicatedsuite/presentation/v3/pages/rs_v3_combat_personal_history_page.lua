------------------------------------------------------------------------
-- 本地永久战绩只读页；打开历史不领取 Combat Consumer。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
local F=S.Features and S.Features.CombatAnalytics
local D,UI,H=S.UIV3Design,S.RSUI,S.UIV3 and S.UIV3.PageHost
if not F or not D or not UI or not H then return end
local function Build(parent)
    local root,err=D:ScrollablePageRoot(parent,{id="v3_personal_history_page",padding=8,gap=7})
    if not root then error(err) end
    D:PageHeader(root,"v3_personal_history_header","个人战斗历史","仅记录功能开启期间的个人数据；记录保存在本地当前角色存档。清空实时统计不会删除这里的记录。")
    local scope=D:CombatStatisticsControls(root,"history")
    local ranges=UI:HorizontalBox({id="v3_personal_history_ranges",parent=root,gap=8,slot={size="fixed",height=32,hAlign="fill"}})
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
    UI:Text({id="v3_personal_history_range_hint",parent=root,text="日期：YYYY-MM-DD（含首尾当天）；留空查询全部。服务器时间，分钟精度。列表显示最近120个记录日，累计包含完整查询范围。",fontSize=9,tone="muted",overflow="wrap",slot={size="auto",minHeight=30}})
    local period=UI:Text({id="v3_personal_history_period",parent=root,text="记录期间：--",fontSize=10,tone="strong",overflow="wrap",slot={size="auto",minHeight=26}})
    local totals=UI:Text({id="v3_personal_history_totals",parent=root,text="--",fontSize=12,tone="strong",overflow="wrap",slot={size="auto",minHeight=44}})
    local details=UI:Text({id="v3_personal_history_evidence",parent=root,text="--",fontSize=9,tone="muted",overflow="wrap",slot={size="auto",minHeight=48}})
    local tableView=UI:TableView({id="v3_personal_history_table",parent=root,items={},rowHeight=24,headerHeight=25,desiredRows=14,scrollbar=true,columnResize=true,
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
        if S.Events and S.Events.SubscribeInternal then
            S.Events:SubscribeInternal("v3.combat_analytics.updated",self,function() root:RefreshData() end)
            S.Events:SubscribeInternal("v3.combat_analytics.feature_updated",self,function() root:RefreshData() end)
        end
        return self:RefreshData()
    end
    function root:OnDeactivated() if S.Events and S.Events.UnsubscribeInternalOwner then S.Events:UnsubscribeInternalOwner(self) end;return true end
    return root
end
local ok,err=H:RegisterFactory("combat.personal_history",Build);if ok~=true then error(err) end
