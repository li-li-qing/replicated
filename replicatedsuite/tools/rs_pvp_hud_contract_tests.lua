-- 维护：真实RSUI纹理提交与真实校准UI/Store；仅Native图形与磁盘由开发宿主替代。
-- 特意验证explicit-false与无返回值的差别，不把Set*的no-op当作拒绝。
local passed,failed=0,0
local function Test(name,fn)local ok,e=pcall(fn);if ok then passed=passed+1;print('PASS pvp-contract '..name)else failed=failed+1;print('FAIL pvp-contract '..name..': '..tostring(e))end end
local function TextureHost()
    ReplicatedSuite={Generation=1,UI={},Utils={},NowMs=function()return 0 end}
    dofile('ui/rs_ui_framework.lua');local UI=ReplicatedSuite.UI
    local n={writes=0}
    function n:ClearAllTextures()if self.failClear then return false end;self.path=nil end
    function n:AddTexture(path)self.writes=self.writes+1;if self.throwAdd then error('texture_rejected')end;if self.failAdd then return false end;self.path=path end
    return UI,n
end
Test('native texture false return is rejected instead of cached',function()
    local UI,n=TextureHost();assert(UI:SetIconTexture(n,'a.dds','v3:test'));n.failAdd=true
    assert(not UI:SetIconTexture(n,'b.dds','v3:test'),'explicit false was accepted');n.failAdd=false
    assert(UI:SetIconTexture(n,'b.dds','v3:test') and n.path=='b.dds','retry was skipped')
end)
Test('EnsureIconTexture separates accepted no-op from failure',function()
    local UI,n=TextureHost();assert(type(UI.EnsureIconTexture)=='function','missing texture commit contract')
    local ok,changed=UI:EnsureIconTexture(n,'a.dds','v3:test');assert(ok and changed)
    local w=n.writes;ok,changed=UI:EnsureIconTexture(n,'a.dds','v3:test');assert(ok and not changed and n.writes==w)
end)
Test('partial clear/add failure invalidates previous cached texture',function()
    local UI,n=TextureHost();assert(UI:SetIconTexture(n,'a.dds','v3:test'));n.throwAdd=true
    assert(not UI:SetIconTexture(n,'b.dds','v3:test'));n.throwAdd=false
    assert(UI:SetIconTexture(n,'a.dds','v3:test') and n.path=='a.dds','cleared previous texture falsely treated as present')
end)
Test('failed clear cannot commit a different texture',function()
    local UI,n=TextureHost();assert(UI:SetIconTexture(n,'a.dds','v3:test'));n.failClear=true
    assert(not UI:SetIconTexture(n,'b.dds','v3:test'));assert(n.path=='a.dds')
end)
local function Calibration()
    local h,S,F,P=dofile('tools/rs_pvp_hud_test_host.lua')()
    F.laneData.player.class={name='Role',icon='role.dds'}
    F.laneData.target.class={name='Target Role',icon='target-role.dds'}
    P:VisualTick();dofile('presentation/v3/widgets/rs_v3_buff_hud_calibration.lua')
    local C=S.UIV3.BuffHudCalibrationV3;local ok,err=C:Open();assert(ok,err)
    return h,S,F,P,C
end
Test('class icon has a real selectable calibration component',function()
    local h,S,F,P,C=Calibration();assert(C.controls.component_class,'class component button missing')
    assert(C:SetComponent('class'));assert(C.inputs.x.shown and C.inputs.size.shown and C.inputs.alpha.shown)
    assert(not C.inputs.rows.shown and not C.inputs.font.shown)
end)
Test('class icon preview and live share exact offset size geometry',function()
    local h,S,F,P,C=Calibration();assert(C:SetComponent('class'))
    -- 维护：新模板可非零；Nudge是增量，size测试仍显式落在24，不降低预览/正式几何一致性断言。
    local initial=C:GetDraftSnapshot().player.components.class
    C:Nudge(17,-9);C:Adjust('size',24-initial.size);C:Adjust('alpha',-.4)
    local rect=C.preview.expectedRect;local draft=C:GetDraftSnapshot()
    assert(rect.width==24 and C.preview.icons[1].root.width==24,'wrong preview size')
    assert(C.preview.icons[1].texture.texture=='role.dds','preview does not show known class icon')
    assert(C:Exit(true));P:VisualTick()
    local info=P.pools.player.info;local x,y=h:World(info.iconRoot)
    assert(x==rect.x and y==rect.y,'preview/live position mismatch')
    assert(info.iconRoot.width==24 and info.iconRoot.alpha==.6)
    assert(F.State.settings.components.class.x==initial.x+17 and F.State.settings.components.class.y==initial.y-9)
end)
Test('class zero size remains automatic and target profile stays independent',function()
    local h,S,F,P,C=Calibration();assert(C:SetComponent('class'))
    -- 维护：明确操作到24再减为0，自动大小0仍是合法用户选择，不与当前发行大小27混淆。
    local initial=C:GetDraftSnapshot();C:Adjust('size',24-initial.player.components.class.size);C:Adjust('size',-24)
    assert(C:GetDraftSnapshot().player.components.class.size==0,'automatic zero coerced to eight')
    C:Nudge(11,-5);assert(C:Exit(true));local own=F:GetHudCalibrationSnapshot()
    assert(own.player.components.class.x==initial.player.components.class.x+11 and own.target.components.class.x==initial.target.components.class.x)
    local store=S.Persistence:GetStore('v3.buff_display');store.loaded=false;assert(F:EnsureStoreLoaded())
    local loaded=F:GetHudCalibrationSnapshot();assert(loaded.player.components.class.x==initial.player.components.class.x+11 and loaded.player.components.class.size==0)
end)
Test('cancel class calibration leaves persisted fields unchanged',function()
    local h,S,F,P,C=Calibration();local before=F:GetHudCalibrationSnapshot().player.components.class.x
    -- 维护：取消应返回打开时已存值，不能硬编码返回旧发行坐标0。
    assert(C:SetComponent('class'));C:Nudge(15,-4);assert(C:Exit(false))
    assert(F:GetHudCalibrationSnapshot().player.components.class.x==before)
    assert(not C.visible and not P:IsCalibrationSuppressed())
end)
Test('class drag uses the actual draft and applies scale once',function()
    local h,S,F,P,C=Calibration();assert(C:SetComponent('class'));C:Adjust('scale',1)
    -- 维护：拖拽在原偏移上累加一次缩放后的增量；新默认偏移非零，仍禁止二次缩放。
    local initial=C:GetDraftSnapshot().player.components.class
    local before=C.preview.expectedRect;local scale=C:GetDraftSnapshot().player.plateScale
    assert(C.preview.root.events.OnDragStart());C.preview.root.x=before.x+20;C.preview.root.y=before.y-10
    assert(C.preview.root.events.OnDragStop())
    local cc=C:GetDraftSnapshot().player.components.class
    assert(cc.x==initial.x+20/scale and cc.y==initial.y-10/scale,'drag scale mismatch')
end)
print(string.format('PVP_CONTRACT_RESULT passed=%d failed=%d',passed,failed));assert(failed==0,'PVP contract failures')
