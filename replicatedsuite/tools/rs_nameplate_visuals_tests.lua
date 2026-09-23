------------------------------------------------------------------------
-- Replicated Suite - nameplate visual offline regression tests
-- Synthetic X2Option only. This proves lifecycle/transaction semantics and is
-- NOT an RU-client visual acceptance claim.
--
-- 2026-09-20 nameplate-mark-ratio-3: RU acceptance from 18.272 proved the four
-- name_tag_hp_* variables affect native HP bars while over_head_marker_width /
-- height / offset do not visually resize X2Unit:SetOverHeadMarker marks. The
-- current contract therefore drives name_tag_mark_size_ratio only and keeps
-- schema1 markerWidth/markerHeight as persistence-compatible percent encoding.
------------------------------------------------------------------------
local function DeepCopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[DeepCopy(k)] = DeepCopy(x) end
    return out
end
local function Eq(a,b,msg) assert(a==b,(msg or "mismatch").." expected="..tostring(b).." actual="..tostring(a)) end
local function Near(a,b,eps,msg)
    eps=eps or 0.0001
    assert(type(a)=="number" and type(b)=="number" and math.abs(a-b)<=eps,(msg or "not near").." expected="..tostring(b).." actual="..tostring(a))
end
local tests, passed = {}, 0
local function Test(name, fn) tests[#tests+1]={name=name,fn=fn} end

local cvars = {
    name_tag_mark_size_ratio = 1,
    overhead_marker_fixed_size = 1,
    name_tag_hp_width = 70,
    name_tag_hp_height = 7,
    name_tag_hp_width_on_bgmode = 158,
    name_tag_hp_height_on_bgmode = 38,
    -- Legacy candidates remain in the synthetic client specifically so tests can
    -- prove 18.273 no longer writes them after RU showed they are visually inert.
    over_head_marker_width = 46,
    over_head_marker_height = 50,
    over_head_marker_offset = 10,
}
local failWrite = nil
local unreadableAll = false
local unreadable = {}
local writesByName = {}
X2Option = {}
function X2Option:GetConsoleVariable(name)
    if unreadableAll == true or unreadable[name] == true then return nil end
    return cvars[name]
end
function X2Option:SetConsoleVariable(name,value)
    if failWrite == name then error("synthetic write failure:"..name) end
    cvars[name] = assert(tonumber(value), "numeric cvar expected")
    writesByName[name] = (writesByName[name] or 0) + 1
    return true
end

ReplicatedSuite = {
    BootError=nil,
    Generation=1,
    Features={},
    Api={
        CallCapability=function(_,_,obj,method,...)
            local ok,a=pcall(obj[method],obj,...)
            if not ok then return false,nil,a end
            return true,a,nil
        end,
        ActionCapability=function(_,_,obj,method,...)
            local ok,a=pcall(obj[method],obj,...)
            if not ok then return false,a end
            if a==false then return false,method.." returned false" end
            return true,a
        end,
    },
    DiagnosticsManager={ Emit=function() return true end },
}
local S=ReplicatedSuite

local stores={}
S.Persistence={
    Scope={Account="account"}, Lifetime={Permanent="permanent"}, V3KeyPrefix="rs.v3.",
    GetStore=function(_,id) return stores[id] end,
    RegisterV3Store=function(_,def)
        def.loaded=false; def.writeFenced=false; stores[def.id]=def; return def
    end,
    LoadStore=function(_,id)
        local st=assert(stores[id]); st.apply(st.default()); st.loaded=true; return "empty",nil,nil
    end,
    MutateStore=function(_,id,mutator,_)
        local st=assert(stores[id]); local before=DeepCopy(st.get())
        local ok,err=mutator()
        if ok==false then st.apply(before); return false,err end
        st.loaded=true; return true
    end,
}
S.FeatureRuntime={
    implementations={},
    RegisterImplementation=function(self,id,impl) self.implementations[id]=impl; return true end,
}
local nativeListeners={}
S.Events={
    Publish=function() return true end,
    BindOwner=function() return true end,
    Subscribe=function(_,name,owner,callback) nativeListeners[name]={owner=owner,callback=callback}; return true end,
    UnsubscribeOwner=function(_,owner)
        local n=0
        for k,v in pairs(nativeListeners) do if v.owner==owner then nativeListeners[k]=nil;n=n+1 end end
        return n
    end,
}

dofile("features/combat/nameplate_visuals/rs_nameplate_visuals_store.lua")
dofile("features/combat/nameplate_visuals/rs_nameplate_visuals_authority.lua")
dofile("features/combat/nameplate_visuals/rs_nameplate_visuals_feature.lua")
local F=assert(S.Features.NameplateVisuals)

Test("schema1 canonical remains unchanged for 18.270-18.272 saves",function()
    Eq(F.StoreSchema,1)
    local st=F:NormalizeSettings({markerWidth=92,markerHeight=100,markerOffset=31,markerFixedSize=false,hpWidth=88,hpHeight=9,bgHpWidth=170,bgHpHeight=40})
    Eq(st.markerWidth,92); Eq(st.markerHeight,100); Eq(st.markerOffset,31); Eq(st.markerFixedSize,false)
    Eq(st.markerScale,nil,"schema1 must not grow a persisted markerScale field")
end)

Test("defaults load without native side effects",function()
    local ok=F:Initialize(); Eq(ok,true)
    local st=F:GetSettings()
    Eq(st.markerWidth,46); Eq(st.markerHeight,50); Eq(st.hpWidth,70); Eq(st.hpHeight,7)
    Eq(F:GetMarkerPercent(),100)
    Eq(F.Authority.metrics.writes,0,"store load must not write native")
end)

Test("enable captures marker-ratio baseline and subscribes only event edge",function()
    local ok,err=F:Enable("test_enable"); assert(ok,err)
    Eq(F.enabled,true); assert(F.Authority.baseline~=nil,"baseline missing")
    assert(nativeListeners.ENTERED_WORLD~=nil,"ENTERED_WORLD listener missing")
    Near(F.Authority.baseline.markerScale,1)
    Near(cvars.name_tag_mark_size_ratio,1)
    Eq(cvars.name_tag_hp_width,70)
end)

Test("150 percent preset drives name_tag_mark_size_ratio not legacy width-height cvars",function()
    local legacyBefore={
        width=cvars.over_head_marker_width,
        height=cvars.over_head_marker_height,
        offset=cvars.over_head_marker_offset,
    }
    local ok,err=F.Commands:SetMarkerPreset(150); assert(ok,err)
    Eq(F:GetSettings().markerWidth,69); Eq(F:GetSettings().markerHeight,75); Eq(F:GetMarkerPercent(),150)
    Near(cvars.name_tag_mark_size_ratio,1.5)
    Eq(cvars.over_head_marker_width,legacyBefore.width)
    Eq(cvars.over_head_marker_height,legacyBefore.height)
    Eq(cvars.over_head_marker_offset,legacyBefore.offset)
    Eq(writesByName.over_head_marker_width,nil,"legacy width cvar must never be written")
    Eq(writesByName.over_head_marker_height,nil,"legacy height cvar must never be written")
    Eq(writesByName.over_head_marker_offset,nil,"legacy offset cvar must never be written")

    ok,err=F.Commands:SetValue("hpWidth",120); assert(ok,err)
    Eq(cvars.name_tag_hp_width,120); Eq(F:GetSettings().hpWidth,120)
end)

Test("entered world reapplies marker ratio and hp without polling",function()
    cvars.name_tag_mark_size_ratio=1; cvars.name_tag_hp_width=70
    nativeListeners.ENTERED_WORLD.callback("ENTERED_WORLD")
    Near(cvars.name_tag_mark_size_ratio,1.5); Eq(cvars.name_tag_hp_width,120)
    Eq(F.reapplyCount,1)
end)

Test("partial native failure rolls back native and durable setting",function()
    local before=DeepCopy(cvars); local old=F:GetSettings()
    failWrite="name_tag_hp_height"
    local ok,err=F.Commands:SetValue("hpHeight",20)
    failWrite=nil
    Eq(ok,false); assert(type(err)=="string")
    local after=F:GetSettings()
    Eq(after.hpHeight,old.hpHeight,"store must compensate failed native apply")
    for k,v in pairs(before) do Eq(cvars[k],v,"native rollback "..k) end
end)

Test("disable restores enable-time marker-ratio baseline and releases listener",function()
    local ok,err=F:Disable("test_disable"); assert(ok,err)
    Eq(F.enabled,false); Eq(nativeListeners.ENTERED_WORLD,nil)
    Near(cvars.name_tag_mark_size_ratio,1)
    Eq(cvars.name_tag_hp_width,70); Eq(cvars.name_tag_hp_height,7)
    Eq(cvars.name_tag_hp_width_on_bgmode,158); Eq(cvars.name_tag_hp_height_on_bgmode,38)
    Eq(F.Authority.baseline,nil)
end)

Test("write-only getter nil no longer blocks marker-ratio enable",function()
    unreadableAll = true
    local cfgBaseline = {
        name_tag_mark_size_ratio = 1.15,
        overhead_marker_fixed_size = 1,
        name_tag_hp_width = 82,
        name_tag_hp_height = 9,
        name_tag_hp_width_on_bgmode = 168,
        name_tag_hp_height_on_bgmode = 42,
    }
    F.Authority.ReadSystemCfgSnapshot = function() return DeepCopy(cfgBaseline), "synthetic-system.cfg" end
    local ok,err=F:Enable("write_only_enable"); assert(ok,err)
    Eq(F.enabled,true)
    Eq(F.Authority.readbackMode,"write_only")
    Near(F.Authority.baseline.markerScale,1.15)
    Eq(F.Authority.baseline.hpWidth,82)
    Eq(F.Authority.baselineSources.markerScale,"system_cfg")
    -- Enable still applies durable user settings even though every getter returns nil.
    Near(cvars.name_tag_mark_size_ratio,1.5)
    Eq(cvars.name_tag_hp_width,F:GetSettings().hpWidth)
end)

Test("write-only apply failure rolls back to last applied values",function()
    local before=DeepCopy(cvars); local old=F:GetSettings()
    failWrite="name_tag_hp_height_on_bgmode"
    local ok,err=F.Commands:SetValue("bgHpHeight",60)
    failWrite=nil
    Eq(ok,false); assert(type(err)=="string")
    Eq(F:GetSettings().bgHpHeight,old.bgHpHeight,"durable setting must compensate write-only native failure")
    for k,v in pairs(before) do Eq(cvars[k],v,"write-only rollback "..k) end
end)

Test("write-only disable restores system cfg marker-ratio baseline",function()
    local ok,err=F:Disable("write_only_disable"); assert(ok,err)
    Eq(F.enabled,false)
    Near(cvars.name_tag_mark_size_ratio,1.15)
    Eq(cvars.name_tag_hp_width,82)
    Eq(cvars.name_tag_hp_height,9)
    Eq(cvars.name_tag_hp_width_on_bgmode,168)
    Eq(cvars.name_tag_hp_height_on_bgmode,42)
    Eq(F.Authority.baseline,nil)
    unreadableAll=false
end)

for _,t in ipairs(tests) do
    local ok,err=pcall(t.fn)
    if not ok then io.stderr:write("FAIL ",t.name,": ",tostring(err),"\n"); os.exit(1) end
    passed=passed+1
end
print("NAMEPLATE_VISUALS_TESTS PASS: "..tostring(passed))
