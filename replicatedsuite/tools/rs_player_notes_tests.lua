------------------------------------------------------------------------
-- Replicated Suite · 人员备注测试
-- 作者：Replicated
-- QQ群：1104129461
--
-- 真实 Persistence / Factory 的备注事务回归，Native 团队和目标为边界替身，不写用户文件。
------------------------------------------------------------------------
local H=dofile('tools/rs_udf_numeric_test_host.lua')
local S,P=H.Boot();S.SafeTraceback=debug.traceback
S.FeatureRuntime={RegisterImplementation=function()return true end}
S.Features=S.Features or {};S.Services={}
local acquired,released=0,0
S.Services.TeamRosterV3={
    AcquireConsumer=function()acquired=acquired+1;return true end,
    ReleaseConsumer=function()released=released+1;return true end,
    GetSnapshot=function()return {members={{name='同名@甲',teamIndex=1,memberIndex=1},{name='同名@乙',teamIndex=2,memberIndex=1}}}end,
}
S.Events=S.Events or {};function S.Events:SubscribeInternal()return true end;function S.Events:UnsubscribeInternalOwner()return true end
X2Unit={UnitName=function()return '目标@甲' end}
dofile('features/shared/rs_feature_slice_factory.lua')
dofile('features/tools/social/rs_player_notes_feature.lua')
local F=S.Features.PlayerNotes
assert(F:Initialize());assert(F:Enable())
local targetOk,targetName=F.Commands:GetTargetName();assert(targetOk and targetName=='目标@甲')
assert(F.Commands:SaveNote('同名@甲','队友'));assert(F.Commands:SaveNote('同名@乙','敌对'))
assert(F:GetNote('同名@甲')=='队友' and F:GetNote('同名@乙')=='敌对')
assert(F.Commands:SaveNote('名字',string.rep('x',385))==false)
assert(F.Commands:SaveNote('名字\n','x')) -- 仅边界空白可裁剪，不接受内嵌控制字符。
assert(F.Commands:SaveNote('名\n字','x')==false)
assert(F:AcquireConsumer('test'));assert(acquired==0,'saved notes unnecessarily acquired live team scanning')
assert(F.Commands:SetView('team'));assert(acquired==1);local p=F:GetProjection();assert(#p.rows==2 and p.rows[1].note=='队友')
p.rows[1].note='修改';assert(F:GetNote('同名@甲')=='队友')
assert(F:ReleaseConsumer('test'));assert(released==1)
assert(F.Commands:DeleteNote('同名@甲'));assert(F:GetNote('同名@甲')=='')
assert(F.Commands:SetView('saved'));assert(F:GetProjection().noteCount==2)
-- 保存后真实 codec 读回；拒写时 Core 必须回滚 RAM，不能丢掉原备注。
assert(P:SaveStore(F.storeId,{consumeDirty=true,verifyAfterSave=true}));F.storeLoaded=false;assert(F:Initialize())
assert(F:GetNote('同名@乙')=='敌对')
local original=P.MutateStore;P.MutateStore=function()return false,'拒写' end
assert(F.Commands:SaveNote('同名@乙','覆盖')==false);assert(F:GetNote('同名@乙')=='敌对');P.MutateStore=original
print('PLAYER_NOTES: persistence, exact identities, validation, detached rows, leases and write rejection passed')

-- 实际 PageHost/RSUI/Feature 保存与草稿测试，Native 绘制仍是宿主模型。
local NewHost=dofile('tools/rs_workspace_home_test_host.lua')
local U,_,_,_,_,uiHost=NewHost({enabled={tools_player_notes=true},skipLayout=true})
dofile('features/shared/rs_feature_slice_factory.lua')
dofile('features/tools/social/rs_player_notes_feature.lua')
local notes=U.Features.PlayerNotes;assert(notes:Initialize());assert(notes:Enable())
X2Unit.UnitName=function()return '目标@甲'end
dofile('presentation/v3/shell/rs_v3_page_host.lua')
dofile('presentation/v3/pages/rs_v3_player_notes_page.lua')
local parent=uiHost.Native(nil,'notes_parent',0,0,850,700)
local page=assert(U.UIV3.PageHost.factories['tools.player_notes'](parent));assert(page:OnActivated());page:Layout(0,0,850,700)
local function Find(node,id)
    if node.id==id then return node end
    for _,child in ipairs(node.children or {})do local found=Find(child,id);if found then return found end end
end
local function Click(id)local c=assert(Find(page,id));return c.root.events.OnClick(c.root,'LeftButton')end
local nameInput=assert(Find(page,'v3_player_notes_name'));local noteInput=assert(Find(page,'v3_player_notes_note'))
assert(Click('v3_player_notes_target'));assert(nameInput:GetValue()=='目标@甲')
assert(noteInput:BeginEditing('test'));noteInput.root.text='尚未保存的备注'
assert(page:Refresh());assert(noteInput:GetDraftValue()=='尚未保存的备注','background refresh replaced draft')
assert(Click('v3_player_notes_save'));assert(notes:GetNote('目标@甲')=='尚未保存的备注')
assert(page.tableView:SetSelectedIndex(1));assert(noteInput:BeginEditing('selected_test'));noteInput.root.text='继续编辑'
assert(notes.Commands:SaveNote('另一个@甲','更新名单'));assert(page:Refresh())
assert(noteInput:GetDraftValue()=='继续编辑','selected-row refresh replaced draft')
assert(Click('v3_player_notes_delete'));assert(notes:GetNote('目标@甲')~='','first delete must only arm confirmation')
assert(Click('v3_player_notes_delete'));assert(notes:GetNote('目标@甲')=='')
assert(page:OnDeactivated());assert(notes.consumerCount==0 and (function()for _,bucket in pairs(U.Events.internalListeners)do for _,entry in ipairs(bucket)do if entry.owner==page then return false end end end;return true end)(),'notes page leaked lease/listener')
print('PLAYER_NOTES_UI: actual page save/target/draft/delete/lifecycle passed (Native modeled)')
