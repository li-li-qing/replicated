-- Development-only regression: player ranged weapon release default / compatibility / layout order.
-- Uses real BuffDisplay Store and real ComputePlateLayout; Native facts are test-host stubs only.
local H = dofile('tools/rs_udf_numeric_test_host.lua')
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; print('PASS ranged-default ' .. name)
    else failed = failed + 1; print('FAIL ranged-default ' .. name .. ': ' .. tostring(err)) end
end

local function BootStore()
    local S, P, io = H.Boot({})
    local F = S.Features.BuffDisplay
    assert(F:EnsureStoreLoaded())
    return S, P, F, io, P:GetStore('v3.buff_display')
end

Test('fresh player HUD enables ranged weapon and uses release preset v4', function()
    local _, _, F = BootStore()
    local d = F:GetDefaultSettingsSnapshot()
    assert(d.components.ranged.enabled == true, 'fresh ranged weapon must be enabled')
    assert(tonumber(d.layoutPresetVersion) == 4, 'fresh layout preset must be v4')
    assert(d.targetLayout.components.ranged.enabled == false, 'target HUD release template must remain unchanged')
end)

Test('old untouched ranged default upgrades once without changing its geometry', function()
    local _, _, F = BootStore()
    assert(type(F.UpgradeRangedWeaponReleaseDefault) == 'function', 'release upgrader missing')
    local s = F.State.settings
    s.layoutPresetVersion = 3
    s.components.ranged.enabled = false
    s.components.ranged.x = 0; s.components.ranged.y = 0; s.components.ranged.size = 26
    s.components.ranged.fontSize = 0; s.components.ranged.alpha = 1
    local ok, changed = F:UpgradeRangedWeaponReleaseDefault(false)
    assert(ok == true and changed == true, 'untouched old default was not upgraded')
    assert(s.components.ranged.enabled == true, 'upgrade did not enable ranged')
    assert(s.components.ranged.x == 0 and s.components.ranged.y == 0 and s.components.ranged.size == 26 and s.components.ranged.alpha == 1,
        'upgrade changed user geometry')
    assert(s.layoutPresetVersion == 4, 'upgrade did not stamp preset v4')
    -- A user may disable it after upgrading; the version stamp must prevent re-enabling on next load.
    s.components.ranged.enabled = false
    local ok2, changed2 = F:UpgradeRangedWeaponReleaseDefault(false)
    assert(ok2 == true and changed2 == false and s.components.ranged.enabled == false, 'v4 user choice was overwritten')
end)

Test('customized old ranged component is preserved and not auto-enabled', function()
    local _, _, F = BootStore()
    local s = F.State.settings
    s.layoutPresetVersion = 3
    s.components.ranged.enabled = false
    s.components.ranged.x = 9; s.components.ranged.y = -3; s.components.ranged.size = 31; s.components.ranged.alpha = 0.75
    local ok, changed = F:UpgradeRangedWeaponReleaseDefault(false)
    assert(ok == true and changed == false, 'custom ranged component should not be migrated')
    assert(s.components.ranged.enabled == false and s.components.ranged.x == 9 and s.components.ranged.y == -3
        and s.components.ranged.size == 31 and s.components.ranged.alpha == 0.75, 'custom ranged settings were changed')
    assert(s.layoutPresetVersion == 3, 'custom old layout must retain old ordering contract')
end)


Test('EnsureStoreLoaded durably upgrades a persisted untouched v3 player profile', function()
    local S1, P1, F1, io1, st1 = BootStore()
    F1.State.settings.layoutPresetVersion = 3
    local r = F1.State.settings.components.ranged
    r.enabled=false; r.x=0; r.y=0; r.size=26; r.fontSize=0; r.alpha=1
    assert(P1:SaveStore(st1.id, {force=true, durable=true}))
    local writesBefore = io1.writes
    local disk = H.Copy(io1.disk)
    local S2, P2, io2 = H.Boot(disk)
    local F2 = S2.Features.BuffDisplay
    assert(F2:EnsureStoreLoaded())
    assert(F2.State.settings.components.ranged.enabled == true, 'load migration did not enable untouched ranged')
    assert(F2.State.settings.layoutPresetVersion == 4, 'load migration did not stamp v4')
    assert(io2.writes == 1, 'load migration must perform exactly one durable compatibility write')
    local S3, P3, io3 = H.Boot(H.Copy(io2.disk))
    local F3 = S3.Features.BuffDisplay
    assert(F3:EnsureStoreLoaded())
    assert(F3.State.settings.components.ranged.enabled == true and F3.State.settings.layoutPresetVersion == 4)
    assert(io3.writes == 0, 'already-upgraded v4 save wrote again')
end)

Test('v4 visual order is mainhand then offhand then ranged from left to right', function()
    local Host = dofile('tools/rs_pvp_hud_test_host.lua')
    local _, _, F, P = Host({noRenderer=false})
    local settings = F:GetDefaultSettingsSnapshot()
    settings.layoutPresetVersion = 4
    local L = P.ComputePlateLayout(500, 400, settings, 0, 0, {mainHand=true, offHand=true, ranged=true, wings=true})
    local by = {}; for _, row in ipairs(L.leftGroup.slots) do by[row.key] = row end
    assert(by.mainHand and by.offHand and by.ranged, 'missing equipment slot')
    assert(by.mainHand.x < by.offHand.x and by.offHand.x < by.ranged.x,
        string.format('wrong visual order: main=%s off=%s ranged=%s', tostring(by.mainHand.x), tostring(by.offHand.x), tostring(by.ranged.x)))
end)

Test('v3 customized layouts keep historical equipment order', function()
    local Host = dofile('tools/rs_pvp_hud_test_host.lua')
    local _, _, F, P = Host({noRenderer=false})
    local settings = F:GetDefaultSettingsSnapshot()
    settings.layoutPresetVersion = 3
    local L = P.ComputePlateLayout(500, 400, settings, 0, 0, {mainHand=true, offHand=true, ranged=true, wings=true})
    local by = {}; for _, row in ipairs(L.leftGroup.slots) do by[row.key] = row end
    assert(by.ranged.x < by.mainHand.x and by.mainHand.x < by.offHand.x,
        'historical v3 equipment order changed')
end)

print(string.format('RANGED WEAPON DEFAULT RESULTS: %d passed / %d failed', passed, failed))
if failed > 0 then os.exit(1) end
