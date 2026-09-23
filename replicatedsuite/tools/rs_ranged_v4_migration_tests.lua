-- Development-only regression for .18.256 ranged release default compatibility.
-- Real BuffDisplay Store + in-memory SaveData host; no Native equipment facts are fabricated.
local H = dofile('tools/rs_udf_numeric_test_host.lua')
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; print('PASS ranged-v4-migration ' .. name)
    else failed = failed + 1; print('FAIL ranged-v4-migration ' .. name .. ': ' .. tostring(err)) end
end
local function Boot(disk)
    local S, P, io = H.Boot(disk or {})
    local F = S.Features.BuffDisplay
    assert(F:EnsureStoreLoaded())
    return S, P, F, io
end
local function SeedLayout(version, enabled, x, size, alpha)
    local _, _, F, io = Boot({})
    local ok, err = F:MutateHudLayoutStore(function()
        local s = F.State.settings
        s.layoutPresetVersion = version
        local r = s.components.ranged
        r.enabled = enabled == true
        r.x = x or 0; r.y = 0; r.size = size or 26; r.fontSize = 0; r.alpha = alpha or 1
        return true
    end, 0, 'seed_ranged_layout', true)
    assert(ok == true, tostring(err))
    return H.Copy(io.disk)
end

Test('persisted untouched v4 false upgrades once to v5 and enables ranged', function()
    local disk = SeedLayout(4, false, 0, 26, 1)
    local _, _, F2, io2 = Boot(disk)
    assert(F2.State.settings.components.ranged.enabled == true, 'v4 persisted ranged=false not repaired')
    assert(tonumber(F2.State.settings.layoutPresetVersion) == 5, 'v4 repair not stamped to v5')
    assert(io2.writes == 1, 'compatibility migration must perform exactly one durable layout write')
    -- Re-entering the already-loaded layout authority must replay the upgraded snapshot, never the pre-upgrade v4 copy.
    assert(F2:EnsureHudLayoutStoreLoaded())
    assert(F2.State.settings.components.ranged.enabled == true, 'cached HUD layout snapshot reverted the ranged migration')
    assert(tonumber(F2.State.settings.layoutPresetVersion) == 5, 'cached HUD layout snapshot reverted the v5 stamp')
end)

Test('v5 explicit user off remains authoritative on reboot', function()
    local disk = SeedLayout(4, false, 0, 26, 1)
    local _, _, F2, io2 = Boot(disk)
    assert(F2:MutateHudLayoutStore(function()
        F2.State.settings.components.ranged.enabled = false
        return true
    end, 0, 'explicit_ranged_off', true))
    local _, _, F3, io3 = Boot(H.Copy(io2.disk))
    assert(F3.State.settings.components.ranged.enabled == false, 'v5 explicit off was overwritten')
    assert(tonumber(F3.State.settings.layoutPresetVersion) == 5, 'v5 stamp lost')
    assert(io3.writes == 0, 'v5 explicit off must not trigger another compatibility write')
end)

Test('customized v4 ranged geometry is preserved', function()
    local disk = SeedLayout(4, false, 9, 31, 0.75)
    local _, _, F2, io2 = Boot(disk)
    local r = F2.State.settings.components.ranged
    assert(r.enabled == false and r.x == 9 and r.size == 31 and math.abs(r.alpha - 0.75) < 0.000001,
        'customized ranged layout was overwritten')
    assert(tonumber(F2.State.settings.layoutPresetVersion) == 4, 'customized v4 layout generation changed')
    assert(io2.writes == 0, 'customized v4 layout must not be auto-written')
end)

print(string.format('RANGED V4 MIGRATION RESULT %d passed / %d failed', passed, failed))
if failed > 0 then os.exit(1) end
