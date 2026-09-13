-- Test-only: real stores, in-memory Native. Projection is an explicit model, not a claim to execute RU.
local function Copy(v)
    if type(v)~='table' then return v end
    local t={};for k,x in pairs(v) do t[Copy(k)]=Copy(x) end;return t
end
local function Eq(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for k,v in pairs(a) do if not Eq(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function F32(v)
    if v==0 then return v end
    local sign=v<0 and -1 or 1;v=math.abs(v)
    local _,e=math.frexp(v);local step=2^(math.max(e-24,-149))
    local n=v/step;local f=math.floor(n);local r=n-f
    if r>0.5 or (r==0.5 and f%2==1) then f=f+1 end
    local result=sign*f*step
    -- Lua5.4 harness: Native small integer metadata must print like Lua5.1, not "3.0".
    if result==math.floor(result) then return math.floor(result) end
    return result
end
local function NativeLoss(v)
    if type(v)=='number' then return F32(tonumber(string.format('%.6f',F32(v)))) end
    if type(v)~='table' then return v end
    local t={};for k,x in pairs(v) do t[NativeLoss(k)]=NativeLoss(x) end;return t
end
local function Boot(disk,loss)
    local io={disk=disk or {},reads=0,writes=0,clears=0}
    ADDON={LoadData=function(_,k) io.reads=io.reads+1;return Copy(io.disk[k]) end,
        SaveData=function(_,k,v)io.writes=io.writes+1;io.disk[k]=loss and NativeLoss(v) or Copy(v);return true end,
        ClearData=function()io.clears=io.clears+1;error('must not clear saves')end}
    ReplicatedSuite={Features={},Services={},UI={CreateWindowShell=function()error('no native windows')end},RSUI={},
        NowMs=function()return 1000 end,FeatureRuntime={RegisterImplementation=function()return true end}}
    local S=ReplicatedSuite
    dofile('core/rs_utils.lua');dofile('core/rs_reuse.lua');dofile('core/rs_demand.lua')
    dofile('core/rs_api.lua');dofile('core/rs_api_capabilities.lua');dofile('core/rs_persistence.lua')
    dofile('ui/framework/rs_ui_floating_surface.lua')
    dofile('features/combat/buff_display/rs_buff_display_store.lua')
    dofile('features/combat/death_review/rs_death_review_store.lua')
    dofile('features/life/rs_life_m16_bundle.lua')
    return S,S.Persistence,io
end

return {Boot=Boot, Copy=Copy, Eq=Eq, NativeLoss=NativeLoss, F32=F32}
