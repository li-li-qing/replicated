------------------------------------------------------------------------
-- Replicated Suite · 战斗统计共享控件
-- 作者：Replicated
-- QQ群：1104129461
--
-- 同一统计工作区的页内导航与采集范围；只消费 Feature Commands/Projection。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
local D,UI=S.UIV3Design,S.RSUI
local F=S.Features and S.Features.CombatAnalytics
if not D or not UI or not F then return end
-- 战斗采集频率与整页绘制频率分离；两个统计事件源共用一次有界合并，不新增周期任务。
-- 页面退出即取消，隐藏页不继续构造排行/技能图标；按钮、排序和设置操作仍同步响应。
function D:RequestCombatStatisticsRefresh(page, callback)
    if page.combatStatisticsActive ~= true then return true end
    local coordinator = S.RefreshCoordinator
    if not coordinator or type(coordinator.Request) ~= "function" then return callback(page) end
    return coordinator:Request({ owner=page, key="combat_statistics_data", moduleId="combat_stats",
        delayMs=250, maxWaitMs=250, reason="combat_data", priority="P3", cost=2,
        callback=function()
            if page.combatStatisticsActive ~= true then return true end
            return callback(page)
        end })
end
function D:CancelCombatStatisticsRefresh(page)
    page.combatStatisticsActive = false -- 生命周期标志先失效，已出队的迟到回调也不能绘制隐藏页。
    if S.RefreshCoordinator and type(S.RefreshCoordinator.Cancel) == "function" then
        S.RefreshCoordinator:Cancel(page, "combat_statistics_data")
    end
end
function D:CombatStatisticsControls(parent,active)
    local loaded,loadErr=F:EnsureStoreLoaded();if loaded~=true then error(loadErr or "统计设置读取失败") end
    -- 高级分析暂停后只保留总览、历史、设置；采集范围仍独立切换。
    local group=UI:VerticalBox({id="v3_statistics_"..active.."_controls",parent=parent,gap=4,slot={size="auto",hAlign="fill"}})
    local navigation,err=UI:SegmentedSelector({id="v3_statistics_"..active.."_views",parent=group,itemWidth=84,gap=3,
        items={{value="damage",text="战斗总览"},{value="history",text="个人历史"},{value="settings",text="统计设置"}},
        get=function() return active end,set=function(value)
            local routes={damage="combat.stats",history="combat.personal_history",settings="combat.statistics_settings"}
            if not routes[value] then return false,"unknown statistics view" end
            return S.UIV3.Shell:Navigate(routes[value],{source="statistics_subview"})
        end,slot={size="fixed",height=29,hAlign="fill"}})
    if not navigation then error(err or "统计子页切换器不可用") end
    local row=UI:HorizontalBox({id="v3_statistics_"..active.."_scope_row",parent=group,gap=6,slot={size="fixed",height=29,hAlign="fill"}})
    UI:Text({id="v3_statistics_"..active.."_scope_label",parent=row,text="采集范围",fontSize=9,tone="muted",slot={size="fixed",width=60}})
    local scope,scopeErr=UI:SegmentedSelector({id="v3_statistics_"..active.."_scope",parent=row,itemWidth=98,gap=3,
        items={{value="self",text="只统计自己"},{value="all",text="统计所有人"}},
        get=function() return F:GetCollectionScope() end,
        set=function(value) return F.Commands:SetCollectionScope(value) end,
        slot={size="fixed",width=202}})
    if not scope then error(scopeErr or "统计范围切换器不可用") end
    UI:Text({id="v3_statistics_"..active.."_hint",parent=group,text="默认只统计自己，不统计助攻。切换范围重置实时排行，个人历史保留。",
        fontSize=9,tone="muted",overflow="wrap",slot={size="auto",minHeight=16}})
    return scope
end
if S.UIV3 and S.UIV3.Router and not S.UIV3.Router:Get("combat.statistics_settings") then
    local registered,err=S.UIV3.Router:Register("combat.statistics_settings",{title="战斗统计设置",featureId="combat_stats",category="combat",visible=false,navigationParentRoute="combat.stats"})
    if not registered then error(err) end
end
if S.UIV3 and S.UIV3.Router and not S.UIV3.Router:Get("combat.personal_history") then
    local registered,err=S.UIV3.Router:Register("combat.personal_history",{title="个人战斗历史",featureId="combat_stats",category="combat",visible=false,navigationParentRoute="combat.stats"})
    if not registered then error(err) end
end
