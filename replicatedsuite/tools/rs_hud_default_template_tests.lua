-- 维护（hud-default-template-2）：当前默认布局来自用户 hud.1.1 的完整三页报告，
-- 历史几何基线 RAW_BYTES=1539 / RAW_CHECK=3486F051；.18.221 仅把 PLAYER ranged.enabled 从0改为1，当前期望 RAW_CHECK=37FAF052。下方预期仍是独立的用户输入，
-- 不从生产默认表生成；改错坐标、漏职业图标、误用旧目标装备模板必须失败。
-- Authority：真实 Store/canonical/耐久事务、Calibration 和报告编码器；仅 Native/磁盘使用
-- 既有开发宿主。历史 fingerprint 在改生产代码前采样，禁止随新默认更新；不进 toc.g，
-- 不宣称 Native 替身等于 RU Lua5.1/屏幕布局验收。
local H=dofile("tools/rs_udf_numeric_test_host.lua")
local Open=dofile("tools/rs_hud_template_copy_test_host.lua")
local passed,failed=0,0
local function Test(name,fn)
    local ok,err=pcall(fn)
    if ok then passed=passed+1;print("PASS hud-defaults "..name)
    else failed=failed+1;print("FAIL hud-defaults "..name..": "..tostring(err))end
end
local function Eq(a,b,message)assert(H.Eq(a,b),message or "values differ")end
local function Boot(disk)
    local S,P,io=H.Boot(H.Copy(disk));local F=S.Features.BuffDisplay
    assert(F:EnsureStoreLoaded());return S,P,F,io,P:GetStore("v3.buff_display")
end
local RAW=[==[RS-HUD-TEMPLATE-2
LINES=11;PATCH=hud-template-copy-2
HUD_TEMPLATE_V2;META;build=v3-m1.16.0.18.208-target-gear-score-api-default-template;viewport=2560x1440;uiScale=1;source=draft;coords=screen-y-v1
HUD_TEMPLATE_V2;PLAYER;BASE;scale=1;plate{x=0,y=-24,w=150,h=20};info{x=1,y=0,font=12,enabled=1,class=1,gear=1,distance=1}
HUD_TEMPLATE_V2;PLAYER;AURA;buffs{x=0,y=0,size=29,font=11,spacing=2,perRow=8,rows=2,alpha=1,enabled=1};debuffs{x=0,y=0,size=29,font=11,spacing=2,perRow=8,rows=2,alpha=1,enabled=1}
HUD_TEMPLATE_V2;PLAYER;EQUIP;mainHand{x=0,y=0,size=26,alpha=1,enabled=1};offHand{x=0,y=0,size=26,alpha=1,enabled=1};ranged{x=0,y=0,size=26,alpha=1,enabled=1};wings{x=0,y=0,size=26,alpha=1,enabled=1}
HUD_TEMPLATE_V2;PLAYER;CAST;castBar{x=0,y=0,w=120,h=7,font=12,alpha=1,enabled=1,text=1}
HUD_TEMPLATE_V2;PLAYER;CLASS;class{x=16,y=-5,size=27,alpha=1,enabled=1}
HUD_TEMPLATE_V2;TARGET;BASE;scale=1;plate{x=0,y=-24,w=150,h=20};info{x=1,y=0,font=12,enabled=1,class=1,gear=1,distance=1}
HUD_TEMPLATE_V2;TARGET;AURA;buffs{x=0,y=0,size=29,font=11,spacing=2,perRow=8,rows=2,alpha=1,enabled=1};debuffs{x=0,y=0,size=29,font=11,spacing=2,perRow=8,rows=2,alpha=1,enabled=1}
HUD_TEMPLATE_V2;TARGET;EQUIP;mainHand{x=0,y=0,size=26,alpha=1,enabled=1};offHand{x=0,y=0,size=26,alpha=1,enabled=1};ranged{x=0,y=0,size=26,alpha=1,enabled=0};wings{x=0,y=0,size=26,alpha=1,enabled=1}
HUD_TEMPLATE_V2;TARGET;CAST;castBar{x=0,y=0,w=120,h=7,font=12,alpha=1,enabled=1,text=1}
HUD_TEMPLATE_V2;TARGET;CLASS;class{x=16,y=-5,size=27,alpha=1,enabled=1}
RS-HUD-TEMPLATE-END]==]
local function Expected(profile,rangedEnabled)
    rangedEnabled = rangedEnabled == true
    assert(profile.plateScale==1,"scale")
    local p=profile.plate;assert(p.x==0 and p.y==-24 and p.width==150 and p.height==20,"plate differs from verified template")
    local i=profile.info;assert(i.x==1 and i.y==0 and i.fontSize==12 and i.enabled and i.showClass and i.showGear and i.showDistance,"info")
    local c=profile.components
    for _,key in ipairs({"buffs","debuffs"})do
        local a=c[key];assert(a.x==0 and a.y==0 and a.size==29 and a.fontSize==11 and a.spacing==2
            and a.maxPerRow==8 and a.maxRows==2 and a.alpha==1 and a.enabled,key)
    end
    for _,key in ipairs({"mainHand","offHand","ranged","wings"})do
        local expectedEnabled = true
        if key == "ranged" then expectedEnabled = rangedEnabled end
        local a=c[key];assert(a.x==0 and a.y==0 and a.size==26 and a.alpha==1 and a.enabled==expectedEnabled,key)
    end
    local b=c.castBar;assert(b.x==0 and b.y==0 and b.width==120 and b.size==7 and b.fontSize==12 and b.alpha==1 and b.enabled and b.showText,"castBar")
    local a=c.class;assert(a.x==16 and a.y==-5 and a.size==27 and a.alpha==1 and a.enabled,"class")
end
for _,scope in ipairs({"player","target"})do
    Test("fresh "..scope.." matches all verified fields",function()
        local _,_,F,io=Boot();Expected(F:GetHudCalibrationSnapshot()[scope],scope=="player");assert(io.clears==0)
    end)
end
Test("all default entrypoints agree without disk IO",function()
    local _,_,F,io,st=Boot();local r,w=io.reads,io.writes
    local settings=F:GetDefaultSettingsSnapshot();local layout=F:GetDefaultLayoutSettingsSnapshot()
    local hud=F:GetDefaultHudCalibrationSnapshot();local defaults=st.default()
    Expected(settings,true);Expected(settings.targetLayout,false);Expected(layout,true);Expected(layout.targetLayout,false)
    Expected(hud.player,true);Expected(hud.target,false);Expected(defaults.settings,true);Expected(defaults.settings.targetLayout,false)
    assert(io.reads==r and io.writes==w,"defaults getter performed IO")
end)
Test("default profiles and repeated getters never alias",function()
    local _,_,F=Boot();local one=F:GetDefaultHudCalibrationSnapshot();local two=F:GetDefaultHudCalibrationSnapshot()
    one.player.components.class.x=333;one.target.plate.y=222
    Expected(two.player,true);Expected(two.target,false);Expected(F:GetDefaultHudCalibrationSnapshot().player,true)
    assert(one.target.components.class.x==16 and one.player.plate.y==-24)
    Expected(F:GetHudCalibrationSnapshot().player,true)
end)
Test("unreported policy and cooldown geometry retain their defaults",function()
    local _,_,F=Boot();local d=F:GetDefaultSettingsSnapshot()
    assert(not d.headShowAll and not d.showHidden and not d.freezeEnabled and d.refreshMs==120 and d.headRefreshMs==50)
    assert(#d.tracked.player.buff==0 and #d.tracked.player.debuff==0 and #d.tracked.player.auto==0
        and #d.tracked.target.buff==0 and #d.tracked.target.debuff==0 and #d.tracked.target.auto==0 and #d.trackedCooldowns.skill==0)
    for _,p in ipairs({d,d.targetLayout})do
        local c=p.components.cooldowns;assert(c.enabled==false and c.y==90 and c.size==29)
        assert(p.components.distance.x==0 and p.components.gearScore.x==0 and p.plate.opacity==.85)
    end
end)
-- 维护：这些输入刻意覆盖缺字段、自动大小0和独立目标；预期来自修改前的真实Store，
-- 用于防止“改默认”影响旧 canonical。普通表不等同新安装请求nil。
local cases={
 empty={settings={}},
 sparse={settings={plate={width=161},info={fontSize=13},components={class={enabled=false},ranged={enabled=true}}}},
 dual={settings={plate={x=-17,y=0},info={x=0,y=-7},components={class={x=0,y=0,size=0,alpha=.5},buffs={y=9}},targetLayout={plate={x=19,y=36},components={mainHand={x=-32,size=22},class={x=-42,y=31,size=19}}}}},
 single={settings={plate={x=-67,y=22},plateScale=1.25,info={x=3,y=-8},components={class={x=0,y=0,size=0},wings={enabled=false}},tracked={buff={206,716},debuff={8226}}}}
}
local fingerprints={
 empty={[4]="047C8F56",[5]="2CE06054",[6]="6967C4E3"},
 sparse={[4]="05FB6BAF",[5]="084AF8D4",[6]="5E9EC0FA"},
 dual={[5]="27FC9079",[6]="45A27283"},
 single={[4]="1DE0ADD8",[5]="69852D37",[6]="6CAA2555"}
}
for _,name in ipairs({"empty","sparse","dual","single"})do
    for _,schema in ipairs({4,5,6})do
        local wanted=fingerprints[name][schema]
        if wanted then Test("historical "..name.." schema"..schema.." fingerprint unchanged",function()
            local _,P,_,_,st=Boot();local value=H.Copy(cases[name]);local canonical
            canonical=st.rebuildCanonicalForIntegrity(value,"PROBE",nil,{__rsmeta={
                framework=3,store="v3.buff_display",owner="v3.buff_display",schema=schema}})
            assert(P:FingerprintCanonicalValue(st,canonical)==wanted,"old canonical changed")
        end)end
    end
end
Test("old single HUD migrates from its own player layout not new release",function()
    local _,_,_,_,st=Boot();local migrated=st.migrate(H.Copy(cases.single),4)
    assert(migrated.settings.plate.x==-67 and migrated.settings.plate.y==22)
    assert(migrated.settings.targetLayout.plate.x==-67 and migrated.settings.targetLayout.plate.y==22)
    assert(migrated.settings.components.class.size==0 and migrated.settings.targetLayout.components.class.size==0)
end)
Test("existing custom settings persist and reload without default overwrite",function()
    local _,P,F,io,st=Boot()
    assert(F:MutateCompositeStores(function()
        st.apply(H.Copy(cases.dual))
        F.State.settings.tracked.player.auto={4899,716};F.State.settings.tracked.target.auto={4899,716};F.State.settings.trackedCooldowns.skill={123}
        F.State.settings.library.importedPacks.custom=2
        F.State.settings.components.ranged.x=7 -- explicit user customization: release migration must not touch this profile
        return true
    end,"fixture_custom_state"))
    local before=H.Copy(F.State);assert(F:PersistHudCalibrationSnapshot(F:GetHudCalibrationSnapshot()))
    local _,_,newF,newIo=Boot(io.disk)
    Eq(newF.State,before,"saved custom state was overwritten");assert(newIo.clears==0)
end)
Test("new negative offsets survive physical save and next load",function()
    local _,P,F,io=Boot();assert(F:PersistHudCalibrationSnapshot(F:GetDefaultHudCalibrationSnapshot()))
    local st=assert(P:GetStore('v3.buff_display.layout'))
    assert(st.lastVerifyOk and st.schemaVersion==1 and st.transportVersion==3)
    assert(io.disk[st.key],"no physical layout save")
    local _,_,newF,newIo=Boot(io.disk);Expected(newF:GetHudCalibrationSnapshot().player,true)
    Expected(newF:GetHudCalibrationSnapshot().target,false);assert(newIo.writes==0 and newIo.clears==0)
end)
Test("explicit layout reset preserves tracking and nonlayout state",function()
    local _,_,F,_,st=Boot();st.apply(H.Copy(cases.dual))
    F.State.settings.tracked={player={buff={206,716},debuff={8226},auto={4899}},target={buff={206,716},debuff={8226},auto={4899}}}
    F.State.settings.trackedCooldowns={skill={123},mate={456}}
    F.State.settings.classification={[206]="buff"};F.State.settings.library.importedPacks.custom=2
    local old=H.Copy(F.State);assert(F:ResetLayoutSettings())
    Expected(F.State.settings,true);Expected(F.State.settings.targetLayout,false)
    for _,key in ipairs({"tracked","trackedCooldowns","classification","library","playerRows","targetRows"})do
        Eq(F.State.settings[key],old.settings[key],key.." was reset")
    end
    Eq(F.State.widgetWindow,old.widgetWindow);assert(F.State.widgetVisible==old.widgetVisible)
end)
Test("default report reexports exact user body and checksum",function()
    local h,S,F,P,C=Open({width=2560,height=1440})
    assert(C:ResetCurrentScope());assert(C:SetScope("target"));assert(C:ResetCurrentScope())
    S.BuildTag="v3-m1.16.0.18.208-target-gear-score-api-default-template"
    assert(h:Click());assert(C.templateCopy.text==RAW,"default export differs from verified 11-record report")
    assert(#C.templateCopy.text==1539 and S.ReportCopyTransport:CopyChecksum(C.templateCopy.text)=="37FAF052")
end)
Test("reset target only affects draft and not player or Store",function()
    local h,S,F,P,C=Open();assert(C:SetComponent("class"));C:Nudge(21,-7)
    local player=H.Copy(C:GetDraftSnapshot().player);local saved=F:GetHudCalibrationSnapshot();local w=h.writes
    assert(C:SetScope("target"));C:Nudge(33,14);assert(C:ResetCurrentScope())
    Expected(C:GetDraftSnapshot().target,false);Eq(C:GetDraftSnapshot().player,player)
    Eq(F:GetHudCalibrationSnapshot(),saved);assert(h.writes==w)
    assert(C:Exit(false));Eq(F:GetHudCalibrationSnapshot(),saved)
end)
Test("reset just class restores new icon without moving other components",function()
    local h,S,F,P,C=Open();assert(C:SetComponent("class"));C:Nudge(71,22);C:Adjust("size",8)
    local before=C:GetDraftSnapshot();assert(C:ResetCurrentComponent());local after=C:GetDraftSnapshot()
    local a=after.player.components.class;assert(a.x==16 and a.y==-5 and a.size==27)
    before.player.components.class=H.Copy(a);Eq(before,after,"component reset leaked into other settings")
end)
Test("save-and-exit commits chosen default scopes and reloads",function()
    local h,S,F,P,C=Open();assert(C:ResetCurrentScope());assert(C:SetScope("target"));assert(C:ResetCurrentScope())
    assert(C:Exit(true));local st=S.Persistence:GetStore("v3.buff_display")
    st.loaded=false;assert(F:EnsureStoreLoaded());Expected(F:GetHudCalibrationSnapshot().player,true)
    Expected(F:GetHudCalibrationSnapshot().target,false)
end)
Test("failed default apply keeps original state and draft recoverable",function()
    local h,S,F,P,C=Open();local saved=F:GetHudCalibrationSnapshot()
    assert(C:ResetCurrentScope());assert(C:SetScope("target"));assert(C:ResetCurrentScope())
    local draft=C:GetDraftSnapshot();h.failSave=true
    assert(not C:Exit(true));assert(C.visible);Eq(C:GetDraftSnapshot(),draft);Eq(F:GetHudCalibrationSnapshot(),saved)
    h.failSave=false;assert(C:Exit(false));Eq(F:GetHudCalibrationSnapshot(),saved)
end)
for _,metrics in ipairs({{1024,768,1},{1280,768,1},{1920,1080,1.25},{2560,1440,1}})do
    Test("relative template ignores viewport "..metrics[1].."x"..metrics[2].." scale "..metrics[3],function()
        local h,S,F,P,C=Open({width=metrics[1],height=metrics[2],scale=metrics[3]})
        assert(C:ResetCurrentScope());assert(C:SetScope("target"));assert(C:ResetCurrentScope())
        local lines=assert(C:BuildTemplateSnapshotLines());local body=table.concat(lines,"\n")
        assert(body:find("plate{x=0,y=-24,w=150,h=20}",1,true) and body:find("class{x=16,y=-5,size=27",1,true))
        Expected(C:GetDraftSnapshot().player,true);Expected(C:GetDraftSnapshot().target,false)
    end)
end
print("HUD DEFAULT TEMPLATE: "..passed.." passed / "..failed.." failed")
assert(failed==0,"hud default template failures")
