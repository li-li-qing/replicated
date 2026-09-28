-- Phase 0 recovery: shared offline host for persistence/HUD numeric regression suites.
-- Test infrastructure only; never loaded by toc.g. It models Native storage boundaries while
-- running the real Persistence, BuffDisplay store/feature, and FloatingSurface normalizers.
local H = {}
local function Copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local out = {}; seen[value] = out
    for k,v in pairs(value) do out[Copy(k,seen)] = Copy(v,seen) end
    return out
end
local function Eq(a,b,seen)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    seen=seen or {}; if seen[a] and seen[a]==b then return true end; seen[a]=b
    for k,v in pairs(a) do if not Eq(v,b[k],seen) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
H.Copy,H.Eq=Copy,Eq

function H.Boot(initialDisk)
    local io={disk=Copy(initialDisk or {}),reads=0,writes=0,clears=0,failSave=false}
    local S={Generation=31,Features={},Services={},RSUI={},UI={},Utils={DeepCopy=Copy},BuildTag='phase0-test-host'}
    ReplicatedSuite=S
    S.SafeTraceback=debug.traceback
    S.PhysicalId=function(v)return tostring(v or '') end
    S.FeatureRuntime={
        RegisterImplementation=function() return true end,
        IsEnabled=function() return true end,
        SetTaskModule=function() return true end,
    }
    S.Scheduler={tasks={}}
    function S.Scheduler:AddTask(name,ms,fn) self.tasks[name]={ms=ms,fn=fn}; return true end
    function S.Scheduler:AddHighFrequencyTask(name,ms,fn) self.tasks[name]={ms=ms,fn=fn}; return true end
    function S.Scheduler:AddOneShot(name,ms,fn) self.tasks[name]={ms=ms,fn=fn,oneShot=true}; return true end
    function S.Scheduler:RemoveTask(name) self.tasks[name]=nil; return true end
    function S.Scheduler:SetTaskModule() return true end
    S.Events={listeners={}}
    function S.Events:Publish() return true end
    function S.Events:SubscribeOptional(name,owner,fn) self.listeners[#self.listeners+1]={name=name,owner=owner,fn=fn}; return true end
    function S.Events:SubscribeInternal(name,owner,fn) return self:SubscribeOptional(name,owner,fn) end
    function S.Events:UnsubscribeOwner(owner) for i=#self.listeners,1,-1 do if self.listeners[i].owner==owner then table.remove(self.listeners,i) end end return true end
    S.UI.CreateWindowShell=function() return nil,'test_host_no_window' end
    S.Api={allowedCapabilities={}}
    function S.Api:LoadData(key) io.reads=io.reads+1; return Copy(io.disk[key]) end
    function S.Api:SaveData(key,value)
        io.writes=io.writes+1
        if io.failSave or H.failSave then return false,'synthetic_save_failure' end
        io.disk[key]=Copy(value); return true
    end
    function S.Api:ClearData(key) io.clears=io.clears+1; io.disk[key]=nil; return true end
    function S.Api:IsCapabilityAllowed() return true end
    function S.Api:GetCharacterId() return 'phase0-test-character' end
    function S.Api:GetCharacterName() return 'Phase0' end
    -- FloatingSurface only needs the RSUI table and pure normalizer for these suites.
    dofile('data/rs_data_registry.lua')
    dofile('data/rs_skill_effects.lua')
    dofile('data/rs_combat_ability_catalog.lua')
    dofile('data/ids/rs_buff_ids.lua')
    dofile('data/ids/rs_plates_ids.lua')
    dofile('services/rs_status_classification_v3.lua')
    dofile('data/rs_status_tracking_catalog.lua')
    dofile('core/rs_persistence.lua')
    dofile('core/rs_demand.lua')
    dofile('ui/framework/rs_ui_floating_surface.lua')
    dofile('features/combat/buff_display/rs_buff_display_store.lua')
    dofile('features/combat/buff_display/rs_buff_display_projection.lua')
    dofile('features/combat/buff_display/rs_buff_display_feature.lua')
    dofile('features/combat/buff_display/rs_buff_display_management.lua')
    local transfer=loadfile('features/combat/buff_display/rs_buff_display_transfer_v2.lua'); if transfer then transfer() end
    return S,S.Persistence,io
end
return H
