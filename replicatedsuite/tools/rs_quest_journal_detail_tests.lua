-- Official-enabled getters are queried only by an explicit detail action.
-- Native signatures are shaped test fixtures, not a RU runtime certification.
local passed,failed=0,0
local function Test(name,fn)local ok,e=xpcall(fn,debug.traceback);if ok then passed=passed+1;print('PASS journal '..name)else failed=failed+1;print('FAIL journal '..name..': '..tostring(e))end end
local function Boot()
 local h=dofile('tools/rs_gear_page_test_host.lua')();local S=h.S
 dofile('core/rs_demand.lua')
 local cfg={ids={101},texts={'击败怪物 2/5','采集材料 1/3'},count=2,calls=0}
 X2Quest={GetActiveQuestListCount=function()return #cfg.ids end,GetActiveQuestType=function(_,i)return cfg.ids[i]end,
 IsCompleted=function()return false end,IsReadyForCompleteQuest=function()return false end,
 GetQuestContextMainTitle=function(_,id)return '任务'..id end,
 GetQuestJournalObjectiveCount=function(_,i)cfg.calls=cfg.calls+1;cfg.countIndex=i;return cfg.count end,
 GetQuestJournalObjectiveText=function(_,i,o)cfg.calls=cfg.calls+1;if cfg.reorder then cfg.ids={999}end;return cfg.texts[o]end}
 S.Data={QuestGroups={daily={{key='one',title='测试日常',objectives={{quests={101}}}}}},EventQuestProgress={}}
 dofile('services/rs_quest_progress_v3.lua');local P=S.Services.QuestProgressV3;P.activeIndex={[101]=1}
 return S,P,cfg,h
end
Test('registry permits only the newly official enabled objective getters',function()
 local S=Boot();assert(S.Api:IsCapabilityAllowed('X2Quest:GetQuestJournalObjectiveCount'))
 assert(S.Api:IsCapabilityAllowed('X2Quest:GetQuestJournalObjectiveText'))
 assert(not S.Api:IsCapabilityAllowed('X2Player:GetExpInfo'),'earnings API must not be opened by this change')
end)
Test('detail reads selected active index and preserves native text without parsing reward numbers',function()
 local S,P,cfg=Boot();local r=P:GetJournalObjectives(101)
 assert(r.available and #r.rows==2 and cfg.countIndex==1 and cfg.calls==3)
 assert(r.rows[1].text=='击败怪物 2/5' and r.rows[2].text=='采集材料 1/3')
end)
Test('regular task row and group projection does not query journal objectives',function()
 local S,P,cfg=Boot();local r=P:GetGroupDetail('daily','one');assert(r.total==1 and #r.children==1 and cfg.calls==0)
end)
Test('explicit detailed projection adds objective rows but never changes completion denominator',function()
 local S,P,cfg=Boot();local r=P:GetGroupDetail('daily','one',{journal=true})
 assert(r.total==1 and r.activeCount==1 and #r.children==3 and r.journal.included==2)
 assert(r.children[2].counted==false and r.children[2].category=='目标')
end)
Test('repeat clicks reuse bounded TTL cache and refresh invalidates it',function()
 local S,P,cfg,h=Boot();assert(P:GetJournalObjectives(101).available);local n=cfg.calls
 assert(P:GetJournalObjectives(101).available and cfg.calls==n)
 h.ms=h.ms+4000;assert(P:GetJournalObjectives(101).available and cfg.calls==n+3)
 assert(P:Refresh('test'));assert(P:GetJournalObjectives(101).available and cfg.calls==n+6)
end)
Test('inactive and changed active-index identities are rejected before attributing text',function()
 local S,P,cfg=Boot();assert(not P:GetJournalObjectives(999).available and cfg.calls==0)
 cfg.ids={999};local r=P:GetJournalObjectives(101);assert(not r.available and r.reason=='quest_index_changed' and cfg.calls==0)
end)
Test('quest reorder during read rejects the whole set',function()
 local S,P,cfg=Boot();cfg.reorder=true;local r=P:GetJournalObjectives(101);assert(not r.available and r.reason=='quest_index_changed' and #r.rows==0)
end)
Test('invalid counts and rich unknown return shapes fail closed',function()
 local S,P,cfg=Boot();cfg.count='two';local r=P:GetJournalObjectives(101);assert(not r.available and r.reason=='objective_count_shape')
 local S,P,cfg=Boot();cfg.texts[1]={text='not a verified return shape'};r=P:GetJournalObjectives(101)
 assert(not r.available and r.reason=='objective_text_shape' and #r.rows==0)
end)
Test('large counts and text budgets reject without silently clipping',function()
 local S,P,cfg=Boot();cfg.count=99999;local r=P:GetJournalObjectives(101);assert(not r.available and r.reason=='objective_count_limit' and cfg.calls==1)
 local S,P,cfg=Boot();cfg.texts[1]=string.rep('a',2049);r=P:GetJournalObjectives(101);assert(not r.available and r.reason=='objective_text_limit')
end)
Test('capability absence does not call unavailable function and records reason',function()
 local S,P,cfg=Boot();X2Quest.GetQuestJournalObjectiveText=nil;local r=P:GetJournalObjectives(101)
 assert(not r.available and cfg.calls==0);assert(P:GetHealth('all').journal.lastReason)
end)
Test('selected group has a finite per-click quest budget',function()
 local S,P,cfg=Boot();local objectives={};cfg.ids={}
 for i=1,12 do cfg.ids[i]=100+i;P.activeIndex[100+i]=i;objectives[i]={quests={100+i}}end
 S.Data.QuestGroups.daily[1].objectives=objectives
 local r=P:GetGroupDetail('daily','one',{journal=true});assert(r.total==12 and r.journal.questReads==4 and r.journal.omitted==8)
 assert(cfg.calls==12 and #r.children==20)
end)
Test('journal cache releases when quest service is stopped',function()
 local S,P=Boot();P:GetJournalObjectives(101);assert(P:GetHealth('all').journal.cached>0)
 P:Stop();assert(P:GetHealth('all').journal.cached==0)
end)
Test('diagnostic report exposes journal shapes without extra Native reads',function()
 local S,P,cfg=Boot();P:GetJournalObjectives(101);local before=cfg.calls
 dofile('core/rs_diagnostics.lua')
 local found;for _,row in ipairs(S.DiagnosticsManager:BuildFeatureStatusRows())do if row.id=='task_progress' then found=row end end
 assert(found and found.journal.patch=='quest-journal-20260909' and found.journal.reads==3)
 assert(cfg.calls==before)
end)
print('JOURNAL RESULT '..passed..' passed / '..failed..' failed');if failed>0 then error('journal tests failed')end
