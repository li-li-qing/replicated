-- Phase 0 recovered lightweight BuffDisplay domain host used by scoped tracking regressions.
-- Test infrastructure only; it deliberately stops before transfer/presentation modules so each owning
-- regression can load the exact production layer it intends to test without double-wrapping APIs.
local function Copy(value,seen)
    if type(value)~='table' then return value end
    seen=seen or {};if seen[value] then return seen[value] end
    local out={};seen[value]=out;for k,v in pairs(value)do out[Copy(k,seen)]=Copy(v,seen)end;return out
end
return function(options)
    options=options or {}
    local io={disk=Copy(options.disk or {}),reads=0,writes=0}
    local S={Generation=41,Features={},Services={},RSUI={},UI={CreateWindowShell=function()return nil,'test_no_window'end},Utils={DeepCopy=Copy},BuildTag='phase0-pvp-domain-host'}
    ReplicatedSuite=S;S.SafeTraceback=debug.traceback;S.PhysicalId=function(v)return tostring(v or '')end
    S.FeatureRuntime={RegisterImplementation=function()return true end,IsEnabled=function()return true end,SetTaskModule=function()return true end}
    S.Scheduler={tasks={}};function S.Scheduler:AddTask(name,ms,fn)self.tasks[name]={callback=fn,fn=fn,ms=ms};return true end
    function S.Scheduler:AddHighFrequencyTask(name,ms,fn)return self:AddTask(name,ms,fn)end
    function S.Scheduler:AddOneShot(name,ms,fn)return self:AddTask(name,ms,fn)end
    function S.Scheduler:RemoveTask(name)self.tasks[name]=nil;return true end;function S.Scheduler:SetTaskModule()return true end
    S.Events={listeners={}}
    function S.Events:SubscribeOptional(topic,owner,fn)self.listeners[#self.listeners+1]={topic=topic,owner=owner,fn=fn};return true end
    function S.Events:SubscribeInternal(topic,owner,fn)return self:SubscribeOptional(topic,owner,fn)end
    function S.Events:UnsubscribeOwner(owner)for i=#self.listeners,1,-1 do if self.listeners[i].owner==owner then table.remove(self.listeners,i)end end;return true end
    S.Events.UnsubscribeInternalOwner=S.Events.UnsubscribeOwner
    function S.Events:Publish(topic,...)for _,r in ipairs(self.listeners)do if r.topic==topic then r.fn(r.owner,...)end end;return true end
    S.Api={allowedCapabilities={}}
    function S.Api:LoadData(key)io.reads=io.reads+1;return Copy(io.disk[key])end
    function S.Api:SaveData(key,value)io.writes=io.writes+1;io.disk[key]=Copy(value);return true end
    function S.Api:ClearData(key)io.disk[key]=nil;return true end
    function S.Api:IsCapabilityAllowed()return true end
    function S.Api:GetCharacterId()return 'phase0-test-character'end
    function S.Api:GetCharacterName()return 'Phase0'end
    for _,f in ipairs({'data/rs_data_registry.lua','data/rs_skill_effects.lua','data/rs_combat_ability_catalog.lua','data/ids/rs_buff_ids.lua','data/ids/rs_plates_ids.lua','services/rs_status_classification_v3.lua','data/rs_status_tracking_catalog.lua','core/rs_persistence_transport.lua','core/rs_persistence.lua','core/rs_demand.lua','ui/framework/rs_ui_floating_surface.lua','features/combat/buff_display/rs_buff_display_store.lua','features/combat/buff_display/rs_buff_display_projection.lua','features/combat/buff_display/rs_buff_display_feature.lua','features/combat/buff_display/rs_buff_display_management.lua'})do dofile(f)end
    local F=assert(S.Features.BuffDisplay,'BuffDisplay feature missing')
    S.Services.AuraObservationV3=S.Services.AuraObservationV3 or {GetSnapshot=function()return nil,'test_no_native_aura'end}
    local h={S=S,P=S.Persistence,io=io,disk=io.disk}
    return h,S,F,nil
end
