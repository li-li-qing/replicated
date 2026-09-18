-- Replicated Suite status persistence split regression tests (.18.243)
-- 中文维护注释：这些用例只验证冷启动/持久化 Authority；Native SaveData/LoadData 为内存模拟，
-- 不宣称可替代 ArcheRage RU 实机。生产目标是证明：旧 v3.buff_display 不再是运行时写 Authority，
-- tracking 必须通过 inactive A/B + manifest 最终提交，当前已批准的 A 方案只用于首次迁移。
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, function(e) return tostring(e) .. '\n' .. debug.traceback() end)
    if ok then passed = passed + 1; print('PASS buff-persistence-split ' .. name)
    else failed = failed + 1; print('FAIL buff-persistence-split ' .. name .. ': ' .. err) end
end
local function Copy(v) if type(v) ~= 'table' then return v end local o = {}; for k,x in pairs(v) do o[k] = Copy(x) end return o end
local function Boot(options)
    options = options or {}
    local io = { disk = Copy(options.disk or {}), writes = 0, writeKeys = {}, reads = 0 }
    ADDON = {
        SaveData = function(_, k, v)
            io.writes = io.writes + 1; io.writeKeys[k] = (io.writeKeys[k] or 0) + 1
            if options.failKey ~= nil and tostring(k):find(options.failKey, 1, true) then return false, 'forced failure' end
            io.disk[k] = Copy(v); return true
        end,
        LoadData = function(_, k) io.reads = io.reads + 1; return Copy(io.disk[k]) end,
        ClearData = function() return true end,
    }
    ReplicatedSuite = { Features={}, Services={}, RSUI={}, UI={CreateWindowShell=function()end}, NowMs=function()return 1000 end, Generation=1,
        SafeTraceback=function(e)return tostring(e)end, FeatureRuntime={RegisterImplementation=function()return true end,IsEnabled=function()return false end} }
    local files = {
        'core/rs_utils.lua','core/rs_reuse.lua','core/rs_api.lua','core/rs_api_capabilities.lua','core/rs_events.lua','core/rs_scheduler.lua','core/rs_persistence.lua','core/rs_demand.lua',
        'data/rs_data_registry.lua','data/rs_skill_effects.lua','data/rs_combat_ability_catalog.lua','data/ids/rs_buff_ids.lua','data/ids/rs_plates_ids.lua','services/rs_status_classification_v3.lua','data/rs_status_tracking_catalog.lua','services/rs_buff_metadata_v3.lua','ui/framework/rs_ui_floating_surface.lua',
        'features/combat/buff_display/rs_buff_display_store.lua','features/combat/buff_display/rs_buff_display_projection.lua','features/combat/buff_display/rs_buff_display_feature.lua','features/combat/buff_display/rs_buff_display_management.lua','features/combat/buff_display/rs_buff_display_transfer_v2.lua'
    }
    for _,f in ipairs(files) do dofile(f) end
    return ReplicatedSuite, ReplicatedSuite.Features.BuffDisplay, ReplicatedSuite.Persistence, io
end

Test('registers settings tracking slots and manifest as independent stores', function()
    local _,F,P = Boot()
    assert(F.SettingsStoreId == 'v3.buff_display.settings')
    assert(F.TrackingManifestStoreId == 'v3.buff_display.tracking.manifest')
    assert(F.TrackingPersistenceContractVersion >= 1)
    for _,id in ipairs({
        'v3.buff_display.settings','v3.buff_display.layout','v3.buff_display.tracking.manifest',
        'v3.buff_display.tracking.player.a','v3.buff_display.tracking.player.b',
        'v3.buff_display.tracking.target.a','v3.buff_display.tracking.target.b',
        'v3.buff_display.tracking.meta.a','v3.buff_display.tracking.meta.b',
    }) do assert(P:GetStore(id) ~= nil, 'missing store ' .. id) end
end)

Test('fresh startup establishes new authority without writing legacy monolith', function()
    local _,F,P,io = Boot()
    local ok,why = F:EnsureStoreLoaded(); assert(ok,why)
    local legacy = assert(P:GetStore('v3.buff_display'))
    local legacyKey = assert(select(1,P:ResolveStoreKey(legacy)))
    assert((io.writeKeys[legacyKey] or 0) == 0, 'legacy monolith must remain read-only')
    local manifest = F:GetTrackingPersistenceHealth()
    assert(manifest and manifest.generation >= 1 and (manifest.slot == 'a' or manifest.slot == 'b'))
end)

Test('tracking commit writes inactive slot then manifest and never legacy store', function()
    local _,F,P,io = Boot(); assert(F:EnsureStoreLoaded())
    local before = F:GetTrackingPersistenceHealth(); local oldSlot = before.slot
    local ok,why = F:SetTrackedChannel(123456,'player','buff',true); assert(ok,why)
    assert(P:Flush(F.TrackingManifestStoreId))
    local after = F:GetTrackingPersistenceHealth()
    assert(after.generation == before.generation + 1)
    assert(after.slot ~= oldSlot)
    local legacy = assert(P:GetStore('v3.buff_display')); local legacyKey = assert(select(1,P:ResolveStoreKey(legacy)))
    assert((io.writeKeys[legacyKey] or 0) == 0, 'tracking mutation rewrote legacy monolith')
end)

Test('failed inactive slot write does not advance manifest', function()
    local _,F,P = Boot(); assert(F:EnsureStoreLoaded())
    local before = F:GetTrackingPersistenceHealth(); local inactive = before.slot == 'a' and 'b' or 'a'
    local victimId = 'v3.buff_display.tracking.player.' .. inactive
    local loaded = P:LoadStore(victimId); assert(loaded == true or loaded == 'empty')
    local victim = assert(P:GetStore(victimId))
    victim.writeFenced = true; victim.writeFenceReason = 'forced_test_fence'
    local ok = F:SetTrackedChannel(654321,'player','buff',true)
    assert(ok ~= true, 'commit must fail when inactive player slot is fenced')
    local after = F:GetTrackingPersistenceHealth()
    assert(after.slot == before.slot and after.generation == before.generation, 'manifest advanced after failed inactive write')
end)


Test('user-approved A migrates legacy truncated player auto from intact target exactly once', function()
    local _,F,P,io = Boot()
    local legacy = assert(P:GetStore('v3.buff_display'))
    local load = P:LoadStore('v3.buff_display'); assert(load == true or load == 'empty')
    local ids = {}; for i=1,64 do ids[i] = 100000 + i end
    F.State.settings.tracked.player.auto = Copy(ids)
    F.State.settings.tracked.target.auto = Copy(ids)
    local saved,saveErr = P:SaveStore('v3.buff_display',{consumeDirty=true,durable=true,verifyAfterSave=true,reason='fixture_legacy'}); assert(saved,saveErr)
    local legacyKey = assert(select(1,P:ResolveStoreKey(legacy)))
    local raw = assert(io.disk[legacyKey]); local player = raw.payload.settings.tracked.player.auto
    assert(player and player['__rs_t5:a']==1 and type(player.chunks)=='table')
    player['__rs_t5:a']=nil; player.count=nil
    local last=#player.chunks; for i=3,last do player.chunks[i]=nil end
    player.chunks[2]=assert(player.chunks[2]):sub(1,#player.chunks[2]-2)

    -- Remove all new split stores from fixture disk: the next boot must take the one-time migration path.
    for k in pairs(io.disk) do if tostring(k):find('buff_display_tracking_',1,true) or tostring(k):find('buff_display_settings',1,true) or tostring(k):find('buff_display_layout',1,true) then io.disk[k]=nil end end
    local _,fresh,_,fio = Boot({disk=io.disk})
    local ok,why = fresh:EnsureStoreLoaded(); assert(ok,why)
    assert(#fresh.State.settings.tracked.player.auto==64 and #fresh.State.settings.tracked.target.auto==64)
    for i=1,64 do assert(fresh.State.settings.tracked.player.auto[i]==ids[i]); assert(fresh.State.settings.tracked.target.auto[i]==ids[i]) end
    local h=fresh:GetTrackingPersistenceHealth(); assert(h.generation==1 and h.slot=='a')
    assert(h.legacyMigration=='legacy_schema8_t5_user_approved_A',h.legacyMigration)
end)




Test('manifest commit failure leaves previous generation authoritative', function()
    local _,F,P = Boot(); assert(F:EnsureStoreLoaded())
    local before=F:GetTrackingPersistenceHealth()
    local mst=assert(P:GetStore(F.TrackingManifestStoreId));mst.writeFenced=true;mst.writeFenceReason='forced_manifest_fence'
    local ok=F:SetTrackedChannel(888001,'target','debuff',true);assert(ok~=true,'manifest fence must fail tracking commit')
    local after=F:GetTrackingPersistenceHealth()
    assert(after.generation==before.generation and after.slot==before.slot,'failed manifest commit changed active authority')
    assert(not F:IsTrackedId(888001,'target','debuff'),'failed manifest commit leaked staged state into active Domain')
end)

Test('approved A migrates exact 393 item 25-chunk legacy shape with chunk19 mid-token truncation', function()
    local _,F,P,io = Boot()
    local legacy = assert(P:GetStore('v3.buff_display'))
    local load = P:LoadStore('v3.buff_display'); assert(load == true or load == 'empty')
    local ids = {}; for i=1,393 do ids[i] = 120000 + i end
    F.State.settings.tracked.player.auto = Copy(ids)
    F.State.settings.tracked.target.auto = Copy(ids)
    local saved,saveErr=P:SaveStore('v3.buff_display',{consumeDirty=true,durable=true,verifyAfterSave=true,reason='fixture_393'});assert(saved,saveErr)
    local legacyKey=assert(select(1,P:ResolveStoreKey(legacy)));local raw=assert(io.disk[legacyKey])
    local player=assert(raw.payload.settings.tracked.player.auto);local target=assert(raw.payload.settings.tracked.target.auto)
    assert(player['__rs_t5:a']==1 and player.count==393 and #player.chunks==25)
    assert(target['__rs_t5:a']==1 and target.count==393 and #target.chunks==25)
    player['__rs_t5:a']=nil;player.count=nil
    for i=20,25 do player.chunks[i]=nil end
    local healthy19=assert(target.chunks[19]);assert(#healthy19>3)
    player.chunks[19]=healthy19:sub(1,#healthy19-2) -- RU 实机：十进制 ID 中间截断。
    for k in pairs(io.disk) do if tostring(k):find('buff_display_tracking_',1,true) or tostring(k):find('buff_display_settings',1,true) or tostring(k):find('buff_display_layout',1,true) then io.disk[k]=nil end end
    local _,fresh=Boot({disk=io.disk});local ok,why=fresh:EnsureStoreLoaded();assert(ok,why)
    assert(#fresh.State.settings.tracked.player.auto==393 and #fresh.State.settings.tracked.target.auto==393)
    for i=1,393 do assert(fresh.State.settings.tracked.player.auto[i]==ids[i]);assert(fresh.State.settings.tracked.target.auto[i]==ids[i]) end
    local h=fresh:GetTrackingPersistenceHealth();assert(h.legacyMigration=='legacy_schema8_t5_user_approved_A',h.legacyMigration)
end)

Test('committed tracking survives reboot from manifest active slot', function()
    local _,F,P,io = Boot(); assert(F:EnsureStoreLoaded())
    local ok,why = F:SetTrackedChannel(777001,'player','buff',true); assert(ok,why)
    local before = F:GetTrackingPersistenceHealth(); assert(before.generation >= 2)
    local _,fresh = Boot({disk=io.disk})
    local loaded,loadWhy = fresh:EnsureStoreLoaded(); assert(loaded,loadWhy)
    local after = fresh:GetTrackingPersistenceHealth()
    assert(after.generation == before.generation and after.slot == before.slot, 'manifest did not survive reboot')
    local found=false
    for _,id in ipairs(fresh.State.settings.tracked.player.buff or {}) do if id==777001 then found=true end end
    assert(found,'active slot tracking mutation missing after reboot')
end)

Test('corrupt inactive tracking slot never blocks startup', function()
    local _,F,P,io = Boot(); assert(F:EnsureStoreLoaded())
    local active = F:GetTrackingPersistenceHealth().slot
    local inactive = active=='a' and 'b' or 'a'
    local victim = assert(P:GetStore('v3.buff_display.tracking.player.'..inactive))
    local key = assert(select(1,P:ResolveStoreKey(victim)))
    io.disk[key] = { broken = true }
    local _,fresh = Boot({disk=io.disk})
    local ok,why = fresh:EnsureStoreLoaded(); assert(ok,why)
    assert(fresh:GetTrackingPersistenceHealth().slot==active,'inactive corruption changed authority')
end)

Test('corrupt active tracking slot fails closed and never falls back to inactive guess', function()
    local _,F,P,io = Boot(); assert(F:EnsureStoreLoaded())
    local active = F:GetTrackingPersistenceHealth().slot
    local victim = assert(P:GetStore('v3.buff_display.tracking.player.'..active))
    local key = assert(select(1,P:ResolveStoreKey(victim)))
    local raw=assert(io.disk[key]); assert(type(raw)=='table')
    if type(raw.payload)=='table' then raw.payload.buff={999999} else raw.broken=true end
    local _,fresh = Boot({disk=io.disk})
    local ok = fresh:EnsureStoreLoaded()
    assert(ok ~= true,'active corruption must fail closed')
end)

Test('HUD and settings saves never rewrite tracking slots or legacy monolith', function()
    local _,F,P,io = Boot(); assert(F:EnsureStoreLoaded())
    local trackedKeys={}
    for _,slot in ipairs({'a','b'}) do for _,part in ipairs({'player','target','meta'}) do
        local st=assert(P:GetStore('v3.buff_display.tracking.'..part..'.'..slot))
        trackedKeys[assert(select(1,P:ResolveStoreKey(st)))] = true
    end end
    local legacy=assert(P:GetStore('v3.buff_display')); local legacyKey=assert(select(1,P:ResolveStoreKey(legacy)))
    local before={}; for k in pairs(trackedKeys) do before[k]=io.writeKeys[k] or 0 end; before[legacyKey]=io.writeKeys[legacyKey] or 0
    local ok,why=F:MutateStore(function() F.State.settings.showBuffs = not F.State.settings.showBuffs; return true end,0,'test_settings',true); assert(ok,why)
    local lok,lwhy=F:MutateHudLayoutStore(function() F.State.settings.components.distance.x=-7; return true end,0,'test_layout',true); assert(lok,lwhy)
    for k in pairs(trackedKeys) do assert((io.writeKeys[k] or 0)==before[k],'settings/layout wrote tracking store '..k) end
    assert((io.writeKeys[legacyKey] or 0)==before[legacyKey],'settings/layout wrote legacy monolith')
end)

print(string.format('BUFF PERSISTENCE SPLIT RESULT %d passed / %d failed', passed, failed))
if failed > 0 then os.exit(1) end
