-- 真实业务 Commands/Store；Native 时钟/区域读取被设为错误，确保关闭时编辑只是偏好写入。
local function Boot()
 local h=dofile('tools/rs_gear_page_test_host.lua')();local S=h.S
 S.UI.CreateWindowShell=function()return {}end
 dofile('ui/framework/rs_ui_floating_surface.lua');dofile('core/rs_demand.lua')
 for _,f in ipairs({'data/rs_data_registry.lua','data/ids/rs_quest_ids.lua','data/ids/rs_instance_ids.lua','data/rs_event_data.lua','data/rs_quest_data.lua'})do dofile(f)end
 for _,name in ipairs({'tasks/rs_task','activities/rs_activity'})do for _,part in ipairs({'store','authority','feature'})do dofile('features/life/'..name..'_'..part..'.lua')end end
 UIParent={GetServerTimeTable=function()error('unexpected clock scan')end};X2Map={GetZoneStateInfoByZoneId=function()error('unexpected zone scan')end}
 assert(S.Features.Tasks:EnsureStoreLoaded());assert(S.Features.Activities:EnsureStoreLoaded());return S,h
end
local p,f=0,0
local function T(n,fn)local ok,e=xpcall(fn,debug.traceback);if ok then p=p+1;print('PASS '..n)else f=f+1;print('FAIL '..n..' '..e)end end
T('task catalogue atomic batch preserves other scope and all-empty',function()
 local S,h=Boot();local F=S.Features.Tasks;assert(type(F.GetAttentionCatalog)=='function','missing task attention catalogue')
 local rows=F:GetAttentionCatalog('daily');assert(#rows>3);local ids={};for _,r in ipairs(rows)do ids[#ids+1]=r.key;assert(r.tracked)end
 assert(F.Commands:SetAttention('daily',ids,false));for _,r in ipairs(F:GetAttentionCatalog('daily'))do assert(not r.tracked)end
 assert(F:GetAttentionCatalog('weekly')[1].tracked);assert(not F.enabled and F.consumerCount==0)
 assert(F.Commands:SetAttention('daily',{ids[1]},true));assert(F:IsTracked('daily',ids[1]));assert(not F:IsTracked('daily',ids[2]))
 local before=h.writes;assert(not F.Commands:SetAttention('daily',{ids[1],'NO_SUCH_GROUP'},false));assert(h.writes==before and F:IsTracked('daily',ids[1]))
 h.failSave=true;assert(not F.Commands:SetAttention('daily',{ids[1]},false));assert(F:IsTracked('daily',ids[1]))
end)
T('activity catalogue includes hidden timeline and live states without sampling',function()
 local S,h=Boot();local F=S.Features.Activities;assert(type(F.GetAttentionCatalog)=='function','missing activity attention catalogue')
 local rows=F:GetAttentionCatalog();local seen,zone={},nil;for _,r in ipairs(rows)do assert(not seen[r.id]);seen[r.id]=true;if r.id=='zone:20'then zone=r end end
 assert(zone and #rows>5);assert(F.Commands:SetAttention({rows[1].id,zone.id},false));assert(F.State.hiddenEvents[zone.id])
 local found=false;for _,r in ipairs(F:GetAttentionCatalog())do if r.id==zone.id then assert(not r.tracked);found=true end end;assert(found)
 assert(not F.enabled and F.consumerCount==0);assert(F.Commands:SetAttention({zone.id},true));assert(not F.State.hiddenEvents[zone.id])
 local before=h.writes;assert(not F.Commands:SetAttention({'missing'},false));assert(before==h.writes)
end)
print('ATTENTION RESULT '..p..' passed / '..f..' failed');if f>0 then error('attention failures')end
