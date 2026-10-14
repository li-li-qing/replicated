------------------------------------------------------------------------
-- Replicated Suite · 首页任务双点击测试
-- 作者：Replicated
-- QQ群：1104129461
--
-- 真正 RSUI 行点击链；只替换游戏任务数据与详情服务，非 RU 客户端验收。
------------------------------------------------------------------------
local Host=dofile('tools/rs_workspace_home_test_host.lua')
local passed=0
local function Test(name,fn)fn();passed=passed+1;print('PASS home-double-click '..name)end
local function Boot()
    local S,p,n,c,enabled,h=Host({visible={'daily','weekly'}})
    local opened={};S.UIV3.QuestDetailFloatingV3={Open=function(_,scope,key,item)opened[#opened+1]={scope=scope,key=key,item=item};return true end}
    assert(p:OnActivated())
    local function Click(scope,index)
        local table=p.cardByKey[scope].table
        local slot=table.list.poolByIndex[index or 1]
        if slot then local row=slot.row;return row.root.events.OnClick(row.root,'LeftButton')end
        error('visible task row missing: '..scope)
    end
    return S,p,h,opened,Click,enabled
end
Test('daily and weekly single-select then double-open their own task',function()
    local S,p,h,opened,Click=Boot()
    for _,scope in ipairs({'daily','weekly'})do
        local before=#opened;Click(scope);assert(#opened==before,'single click opened task')
        h.ms=h.ms+100;Click(scope);assert(#opened==before+1,'double click did not open '..scope)
        assert(opened[#opened].scope==scope and opened[#opened].key=='quest')
        h.ms=h.ms+50;Click(scope);assert(#opened==before+1,'third click reopened detail')
    end
end)
Test('slow clicks and reversed clock cannot count as double click',function()
    local S,p,h,opened,Click=Boot();Click('daily');h.ms=h.ms+500;Click('daily');assert(#opened==0)
    h.ms=h.ms-600;Click('daily');assert(#opened==0);h.ms=h.ms+100;Click('daily');assert(#opened==1)
end)
Test('deactivation and disabled feature clear pending clicks',function()
    local S,p,h,opened,Click,enabled=Boot();Click('daily');assert(p:OnDeactivated());h.ms=h.ms+50
    assert(p:OnActivated());Click('daily');assert(#opened==0)
    enabled.life_tasks=false;p:RefreshData();enabled.life_tasks=true;p:RefreshData();h.ms=h.ms+50;Click('daily');assert(#opened==0)
    h.ms=h.ms+50;Click('daily');assert(#opened==1)
end)
Test('different selected task cannot complete earlier double click',function()
    local S,p,h,opened,Click=Boot()
    S.Features.Tasks.GetOverviewProjection=function(_,opts)return {rows={
        {id=opts.scope..':a',groupKey='a',scope=opts.scope,rawName='任务甲'},
        {id=opts.scope..':b',groupKey='b',scope=opts.scope,rawName='任务乙'}},revision=2}end
    p:RefreshData();Click('daily',1);h.ms=h.ms+50;Click('daily',2);assert(#opened==0)
    h.ms=h.ms+50;Click('daily',2);assert(#opened==1 and opened[1].key=='b')
end)
print('HOME_TASK_DOUBLE_CLICK: '..passed..' cases passed (Native modeled)')
