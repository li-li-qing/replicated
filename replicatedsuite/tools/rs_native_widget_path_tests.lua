-- Development only. Real bootstrap identity; Native path length is a bounded model.
-- User log: 4043 duplicate warnings, every printed Suite path has 259 bytes.
-- A truncating path registry reproduces the ambiguity; passing does not prove C++ internals.
ReplicatedSuite={};ADDON={ChatLog=function()end};UIParent=nil;UI=nil
dofile('replicatedsuite.lua')
local S=ReplicatedSuite
local originalGeneration=S.Generation
local function Eq(a,b,m)assert(a==b,(m or 'mismatch')..' expected='..tostring(b)..' actual='..tostring(a))end
local function Path(depth,branch)
 local nodes={}
 for i=1,depth do nodes[i]=S.PhysicalId('v3_diagnostics_nested_level_'..i..'_'..(i==depth and branch or 'shared'))end
 return table.concat(nodes,'.')
end
local first,second=Path(15,'first'),Path(15,'second')
assert(#first<259 and #second<259,'deep native path still crosses observed truncation boundary: '..#first..'/'..#second)
assert(first:sub(1,259)~=second:sub(1,259),'siblings alias under the observed bounded registry model')
local seen={}
for i=1,12000 do
 local logical='v3_same_readable_suffix_status_'..i..'_status'
 local id=S.PhysicalId(logical)
 assert(not seen[id],'physical collision');seen[id]=true
 Eq(S.PhysicalId(logical),id,'cached logical identity');Eq(S.NativeIdentity.physicalToLogical[id],logical)
 assert(#id<=S.NativeIdentity.maxPhysicalLength)
end
local old=S.PhysicalId('v3_generation_identity')
S.Generation=originalGeneration+1296
S.NativeIdentity.logicalToPhysical={};S.NativeIdentity.physicalToLogical={}
S.NativeIdentity.sequence=0
local fresh=S.PhysicalId('v3_generation_identity')
assert(old~=fresh,'generation beyond short-token rollover must not alias')
Eq(S.NativeIdentity.collisions,0)
-- Native constructor transaction/ownership is still the real production factory.
S.NativeContract={GetObject=function()return {}end}
S.NativeImports={AcquireObject=function()return true end}
local function Widget()return {Show=function()return true end,CreateChildWidget=function()return Widget()end}end
UIParent={CreateWidget=function()return Widget()end}
dofile('native/rs_native_object_factory.lua')
local parent=S.NativeObjectFactory:CreateWindow(S.PhysicalId('v3_path_factory_parent'),'UIParent');assert(parent)
local childId=S.PhysicalId('v3_path_factory_child')
assert(S.NativeObjectFactory:CreateChild(parent,'label',childId,0,true))
local duplicate,err=S.NativeObjectFactory:CreateChild(parent,'label',childId,0,true)
assert(duplicate==nil and tostring(err):find('duplicate native widget identity',1,true),'factory duplicate ownership fence changed')
print('NATIVE WIDGET PATH: PASS (15 levels, distinct siblings, 12000 identities, full generation, reverse map)')
