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
    S.Events={listeners={},ownerModules={},internalListeners={}}
    function S.Events:Publish() return true end
    function S.Events:SubscribeOptional(name,owner,fn) self.listeners[#self.listeners+1]={name=name,owner=owner,fn=fn}; return true end
    function S.Events:SubscribeInternal(name,owner,fn) return self:SubscribeOptional(name,owner,fn) end
    function S.Events:UnsubscribeOwner(owner) for i=#self.listeners,1,-1 do if self.listeners[i].owner==owner then table.remove(self.listeners,i) end end return true end
    -- Phase 1 Batch C（2026-09-28，test host 契约补齐）：NewFeature 的事件投影路径会先 BindOwner，
    -- 释放时用 UnsubscribeInternalOwner；两个拍卖/领导 Feature 的 Demand 0→1 也会走 SubscribeInternal。
    -- 这里的形状与 core/rs_events.lua 一致（BindOwner 只记录 owner→moduleId），离线宿主不做 Native 绑定。
    function S.Events:BindOwner(owner, moduleId)
        if owner == nil or moduleId == nil or tostring(moduleId) == '' then return false end
        self.ownerModules[owner] = tostring(moduleId)
        return true
    end
    function S.Events:UnsubscribeInternal(topic, owner)
        for i=#self.listeners,1,-1 do
            local row = self.listeners[i]
            if row.owner == owner and row.name == topic then table.remove(self.listeners,i) end
        end
        return true
    end
    function S.Events:UnsubscribeInternalOwner(owner) return self:UnsubscribeOwner(owner) end
    function S.Events:CountOwner(owner)
        local count = 0
        for _, row in ipairs(self.listeners) do if row.owner == owner then count = count + 1 end end
        return count
    end
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
    -- Phase 0 补强（2026-09-28，test host 契约补齐）：ScreenProjectionV3 / Unit Lines 等消费者
    -- 通过能力门 S.Api:CallCapability 读 Native，本 host 原先只桩了 IsCapabilityAllowed，
    -- 缺少正式入口，于是 ProjectUnit 一律以 api_unavailable 失败（unit-lines 套件 15 项误报）。
    -- 这里按 core/rs_api.lua 的真实契约补齐只读调用路径：成功返回 ok, value, nil, extra...，
    -- 失败返回 false, nil, err —— 调用方按 `local ok,x,err,y,depth = CallCapability(...)` 解包，
    -- 第三个返回值是错误位而不是第二个数据位，mock 必须保持同样形状。离线 host 不模拟限速。
    function S.Api:ConsumeCapabilityCooldown() return true end
    function S.Api:Call(object, methodName, ...)
        if object == nil then return false, nil, 'object unavailable' end
        local method = object[methodName]
        if type(method) ~= 'function' then return false, nil, tostring(methodName) .. ' unavailable' end
        local args = { ... }; local argCount = select('#', ...)
        local unpackFn = type(table.unpack) == 'function' and table.unpack or unpack
        local ok, a, b, c, d = pcall(function() return method(object, unpackFn(args, 1, argCount)) end)
        if not ok then return false, nil, tostring(a) end
        return true, a, nil, b, c, d
    end
    function S.Api:CallCapability(name, object, methodName, ...)
        if self:IsCapabilityAllowed(name) ~= true then return false, nil, 'capability blocked: ' .. tostring(name) end
        if object == nil then return false, nil, 'capability host unavailable: ' .. tostring(name) end
        local paced = self:ConsumeCapabilityCooldown(name)
        if paced ~= true then return false, nil, 'capability cooldown active: ' .. tostring(name) end
        return self:Call(object, methodName, ...)
    end
    -- Phase 0 补强（2026-09-28，test host 契约补齐）：world 回退路径（ProjectWorld →
    -- ConvertWorldToScreen）走的是 core/rs_api.lua 的 CallGlobalCapability，全局函数没有隐式 self，
    -- 且成功形态同样是 ok, value, nil, extra...。缺这个入口时 ScreenProjectionV3 会静默跳到相机投影，
    -- 于是“负深度不可绘制”这类用例失去覆盖。这里按真实契约补齐，仍不模拟限速。
    function S.Api:CallGlobalCapability(name, ...)
        if self:IsCapabilityAllowed(name) ~= true then return false, nil, 'capability blocked: ' .. tostring(name) end
        local methodName = tostring(name or ''):match('^[^:]+:(.+)$') or tostring(name or '')
        local fn = rawget(_G, methodName)
        if type(fn) ~= 'function' then return false, nil, 'global capability unavailable: ' .. tostring(name) end
        local paced = self:ConsumeCapabilityCooldown(name)
        if paced ~= true then return false, nil, 'capability cooldown active: ' .. tostring(name) end
        local args = { ... }; local argCount = select('#', ...)
        local unpackFn = type(table.unpack) == 'function' and table.unpack or unpack
        local ok, a, b, c, d = pcall(function() return fn(unpackFn(args, 1, argCount)) end)
        if not ok then return false, nil, tostring(a) end
        return true, a, nil, b, c, d
    end
    -- Phase 1 Batch A（2026-09-28，test host 契约补齐）：写路径走 ActionCapability，返回形态是
    -- `true, value` / `false, err`（core/rs_api.lua），不是读路径的 ok,value,nil,extra…
    -- 缺这个入口时 Feature 的显式写命令会静默变成“API boundary unavailable”，离线回归无法发现。
    -- 离线宿主同样不模拟 1000ms 能力冷却；冷却 Authority 是 core/rs_api.lua 的 ConsumeCapabilityCooldown。
    function S.Api:Action(object, methodName, ...)
        local ok, value, err = self:Call(object, methodName, ...)
        if ok ~= true then return false, err end
        if value == false then return false, tostring(methodName) .. ' returned false' end
        return true, value
    end
    function S.Api:ActionCapability(name, object, methodName, ...)
        if self:IsCapabilityAllowed(name) ~= true then return false, 'capability blocked: ' .. tostring(name) end
        if object == nil then return false, 'capability host unavailable: ' .. tostring(name) end
        local paced = self:ConsumeCapabilityCooldown(name)
        if paced ~= true then return false, 'capability cooldown active: ' .. tostring(name) end
        return self:Action(object, methodName, ...)
    end
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
    dofile('core/rs_persistence_transport.lua')
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
