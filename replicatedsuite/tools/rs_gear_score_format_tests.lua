-- 中文维护注释（gear-score-format-1）：本回归覆盖用户可见文字、双 HUD 配置与 schema6->7 兼容。
-- 测试只使用现有 Store/PVP HUD 开发宿主，不读取 Native，不进入 toc.g；RU 实机显示仍需用户验收。
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; print('PASS gear-score-format '..name)
    else failed = failed + 1; print('FAIL gear-score-format '..name..': '..tostring(err)) end
end

local Boot = dofile('tools/rs_pvp_hud_test_host.lua')

Test('full mode renders raw integer and never prefixes gear with middle dot', function()
    local h,S,F,P = Boot()
    F.laneData.player.class={name='Bard',icon='role.dds'}
    F.laneData.player.gearScore=15200
    F:InvalidateSettingsCache(); P:VisualTick()
    local profile=F:GetScopeLayoutSettings('player')
    assert(profile.info.gearScoreFormat=='full','fresh/default player format must be full')
    local base=P.ComputePlateLayout(350,350,profile,0,0,{})
    local g=P.ComputeInfoItemsLayout(F:GetPlatesProjection('player'),profile.info,profile.components,base.bar.centerX,base.info.top,base.info.font,base.scale)
    assert(g.gearScore and g.gearScore.text=='15200','full mode text mismatch')
    assert(g.gearScore.displayText=='15200','gear score still has punctuation/prefix')
    assert(not g.gearScore.displayText:find('·',1,true),'gear score has middle dot')
end)

Test('compact mode formats K with one decimal and trims trailing zero', function()
    local _,_,F,P = Boot()
    local profile=F:GetScopeLayoutSettings('player')
    profile.info.gearScoreFormat='compact'
    local function Format(value)
        local base=P.ComputePlateLayout(350,350,profile,0,0,{})
        local g=P.ComputeInfoItemsLayout({gearScore={value=tostring(value)}},profile.info,profile.components,base.bar.centerX,base.info.top,base.info.font,base.scale)
        return g.gearScore and g.gearScore.text or nil
    end
    assert(Format(15200)=='15.2K','15200 compact')
    assert(Format(15000)=='15K','15000 compact')
    assert(Format(9999)=='10K','9999 compact rounding')
    assert(Format(999)=='999','sub-1000 must stay full')
end)

Test('player and target formats are independent and sync copies player choice', function()
    local _,_,F = Boot()
    local snap=F:GetHudCalibrationSnapshot()
    assert(snap.player.info.gearScoreFormat=='full' and snap.target.info.gearScoreFormat=='full','default format')
    snap.player.info.gearScoreFormat='compact'
    assert(F:PersistHudCalibrationSnapshot(snap))
    local after=F:GetHudCalibrationSnapshot()
    assert(after.player.info.gearScoreFormat=='compact','player compact not persisted')
    assert(after.target.info.gearScoreFormat=='full','target was coupled to player format')
    after.target=after.player
    assert(F:PersistHudCalibrationSnapshot(after))
    local synced=F:GetHudCalibrationSnapshot()
    assert(synced.target.info.gearScoreFormat=='compact','sync/copy did not carry format')
end)

Test('schema is upgraded and calibration exposes both format actions', function()
    local f=assert(io.open('features/combat/buff_display/rs_buff_display_store.lua','rb')); local store=f:read('*a'); f:close()
    f=assert(io.open('presentation/v3/widgets/rs_v3_buff_hud_calibration.lua','rb')); local cal=f:read('*a'); f:close()
    assert(store:find('local SCHEMA = 8',1,true),'Store schema must retain gear format through schema8')
    assert(cal:find('完整数值',1,true),'calibration missing full format action')
    assert(cal:find('K简写',1,true),'calibration missing compact format action')
end)

Test('schema6-shaped state migrates both HUDs to full without coupling', function()
    local _,S,F = Boot()
    local store=assert(S.Persistence:GetStore('v3.buff_display'))
    local raw=store.default()
    raw.settings.info.gearScoreFormat=nil
    raw.settings.targetLayout.info.gearScoreFormat=nil
    local upgraded=store.migrate(raw,6,8)
    assert(upgraded.settings.info.gearScoreFormat=='full','schema6 player did not default to full')
    assert(upgraded.settings.targetLayout.info.gearScoreFormat=='full','schema6 target did not default to full')
    upgraded.settings.info.gearScoreFormat='compact'
    assert(upgraded.settings.targetLayout.info.gearScoreFormat=='full','target format shares player authority')
end)

Test('real calibration draft toggles player format and explicit sync copies it', function()
    local Host=dofile('tools/rs_hud_template_copy_test_host.lua')
    local _,_,_,_,C=Host()
    assert(C:SetScope('player'))
    assert(C:SetComponent('gearScore'))
    assert(C.draft.player.info.gearScoreFormat=='full','calibration default player format')
    assert(C:ToggleAux(2))
    assert(C.draft.player.info.gearScoreFormat=='compact','K action did not update player draft')
    assert(C.draft.target.info.gearScoreFormat=='full','K action leaked into target draft')
    assert(C:SyncPlayerToTarget())
    assert(C.draft.target.info.gearScoreFormat=='compact','explicit sync did not copy compact format')
end)

Test('feature acceptance keeps schema7 gear-format contract inside schema8', function()
    local f=assert(io.open('features/combat/buff_display/rs_buff_display_acceptance.lua','rb')); local a=f:read('*a'); f:close()
    assert(a:find('tonumber(store.schemaVersion) ~= 8',1,true),'feature acceptance does not expect schema8 Store')
    assert(a:find('tonumber(F.SchemaVersion) ~= 8',1,true),'feature acceptance does not expect schema8 Feature')
    assert(a:find('Schema7GearScoreFormatMigrationContractVersion',1,true),'feature acceptance does not gate schema7 migration')
    assert(a:find('GearScoreFormatContractVersion',1,true),'feature acceptance does not gate renderer format support')
end)

if failed>0 then error(string.format('GEAR_SCORE_FORMAT_RESULT passed=%d failed=%d',passed,failed)) end
print(string.format('GEAR_SCORE_FORMAT_RESULT passed=%d failed=%d',passed,failed))
