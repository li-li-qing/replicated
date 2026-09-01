------------------------------------------------------------------------
-- Replicated Suite - Treasure Map Service
-- Reuses Resource's authoritative bag snapshot; never performs a second bag
-- scan. Coordinate fields are observed ArcheRage item-info fields, therefore
-- this service fails closed when a client build does not expose them.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite; S.Services=S.Services or {}; S.Services.Treasure={}
local T=S.Services.Treasure
T.presentationBoundary = "service_only"
T.presentationDebt = nil
local X_OFFSET, Y_OFFSET, UNITS_PER_DEGREE = 21504, 28672, 1024

local function Number(v) local n=tonumber(v); if n~=nil then return n end; return nil end
local function DmsToWorld(dir,deg,min,sec,offset)
    deg,min,sec=Number(deg),Number(min),Number(sec)
    if deg==nil or min==nil or sec==nil then return nil end
    local d=deg+(min/60)+(sec/3600)
    dir=tostring(dir or "")
    if dir=="W" or dir=="S" then d=-d end
    return d*UNITS_PER_DEGREE+offset
end
local function CoordText(item)
    local ld,ad=tostring(item.longitudeDir or ""),tostring(item.latitudeDir or "")
    if (ld~="E" and ld~="W") or (ad~="N" and ad~="S") then return nil end
    local ldeg,lmin,lsec=Number(item.longitudeDeg),Number(item.longitudeMin),Number(item.longitudeSec)
    local adeg,amin,asec=Number(item.latitudeDeg),Number(item.latitudeMin),Number(item.latitudeSec)
    if ldeg==nil or lmin==nil or lsec==nil or adeg==nil or amin==nil or asec==nil then return nil end
    return string.format("%s %d°%d' %d\" · %s %d°%d' %d\"",ld,ldeg,lmin,lsec,ad,adeg,amin,asec)
end
local function Direction(dx,dy)
    if math.abs(dx)<0.001 and math.abs(dy)<0.001 then return "到达", "◎", "◎", 0 end
    local a=math.deg(math.atan2(dy,dx)); if a<0 then a=a+360 end
    if a<22.5 or a>=337.5 then return "东", "E", "→", a end
    if a<67.5 then return "东北", "NE", "↗", a end
    if a<112.5 then return "北", "N", "↑", a end
    if a<157.5 then return "西北", "NW", "↖", a end
    if a<202.5 then return "西", "W", "←", a end
    if a<247.5 then return "西南", "SW", "↙", a end
    if a<292.5 then return "南", "S", "↓", a end
    return "东南", "SE", "↘", a
end

function T:RefreshMaps()
    local resource=S.Services and S.Services.Resource
    local snapshot=resource and type(resource.BuildBagSnapshot)=="function" and resource:BuildBagSnapshot() or nil
    local maps={}
    for _,item in ipairs(snapshot and snapshot.items or {}) do
        local coord=CoordText(item)
        local name=tostring(item.name or "")
        if coord~=nil and (name=="记有坐标的藏宝图" or string.find(name,"藏宝图",1,true)~=nil) then
            local wx=DmsToWorld(item.longitudeDir,item.longitudeDeg,item.longitudeMin,item.longitudeSec,X_OFFSET)
            local wy=DmsToWorld(item.latitudeDir,item.latitudeDeg,item.latitudeMin,item.latitudeSec,Y_OFFSET)
            if wx~=nil and wy~=nil then
                local key=coord..":"..tostring(item.slot or 0)
                maps[#maps+1]={key=key,text=coord,name=name,worldX=wx,worldY=wy,slot=item.slot}
            end
        end
    end
    local d=S.State.data.treasure or {}
    local selected=tostring(d.selectedKey or "")
    local found=false
    for _,m in ipairs(maps) do if m.key==selected then found=true; break end end
    if not found then selected=maps[1] and maps[1].key or nil end
    S.State.data.treasure={status=#maps>0 and "ready" or "empty",maps=maps,selectedKey=selected,direction="--",directionShort="--",arrow="--",bearing=nil,distance=nil,error=nil}
    S.State:MarkDirty("treasure")
    return #maps
end

function T:SelectMap(key)
    local d=S.State.data.treasure or {}
    for _,m in ipairs(d.maps or {}) do
        if m.key==key then d.selectedKey=key; d.distance=nil; d.direction="--"; d.directionShort="--"; d.arrow="--"; d.bearing=nil; S.State:MarkDirty("treasure"); return true end
    end
    return false
end

function T:GetSelected()
    local d=S.State.data.treasure or {}
    for _,m in ipairs(d.maps or {}) do if m.key==d.selectedKey then return m end end
    return nil
end

function T:UpdatePosition()
    local place=S.State.ui and S.State.ui.widgets and S.State.ui.widgets.treasure
    if place==nil or place.visible~=true then return end
    local map=self:GetSelected(); if map==nil then return end
    if S.Api==nil or type(S.Api.IsCapabilityAllowed)~="function"
        or S.Api:IsCapabilityAllowed("X2Unit:GetUnitWorldPositionByTarget")~=true then return end
    local ok,x,_,y=S.Api:CallCapability("X2Unit:GetUnitWorldPositionByTarget", X2Unit, "GetUnitWorldPositionByTarget","player",false)
    x=ok and tonumber(x) or nil; y=ok and tonumber(y) or nil
    if x==nil or y==nil then return end
    local dx,dy=map.worldX-x,map.worldY-y
    local distance=math.sqrt(dx*dx+dy*dy)
    local direction,short,arrow,bearing=Direction(dx,dy)
    local d=S.State.data.treasure
    local old=tonumber(d.distance)
    if d.direction~=direction or d.arrow~=arrow or old==nil or math.abs(old-distance)>=0.5 then
        d.distance=distance; d.direction=direction; d.directionShort=short; d.arrow=arrow; d.bearing=bearing
        S.State:MarkDirty("treasure")
    end
end

function T:ForceRefresh()
    local resource=S.Services and S.Services.Resource
    if resource then resource.bagDirty=true; resource:BuildBagSnapshot() end
    self:RefreshMaps(); self:UpdatePosition()
end

function T:Start()
    S.Events:Subscribe("BAG_UPDATE",self,function()
        S.Scheduler:AddTask("treasure_map_refresh",350,function() S.Scheduler:RemoveTask("treasure_map_refresh"); T:RefreshMaps() end,true,self,"P3")
    end)
    S.Events:Subscribe("ENTERED_WORLD",self,function()
        S.Scheduler:AddTask("treasure_world_refresh",700,function() S.Scheduler:RemoveTask("treasure_world_refresh"); T:RefreshMaps() end,true,self,"P3")
    end)
    S.Scheduler:AddTask("treasure_position",S.Constants.Refresh.treasurePositionMs or 250,function() T:UpdatePosition() end,false,self,"P3")
    self:RefreshMaps()
end
