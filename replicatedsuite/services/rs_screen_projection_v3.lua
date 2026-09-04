------------------------------------------------------------------------
-- Replicated Suite V3 - Shared Screen Projection Service
--
-- Read-only projection authority shared by Healer markers, current-target
-- line rendering and user-configured range circles.  No loop is owned here;
-- Feature Demand decides cadence.  All game reads cross S.Api capabilities.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}
S.Services.ScreenProjectionV3 = S.Services.ScreenProjectionV3 or {}
local P = S.Services.ScreenProjectionV3
P.version = 5
P.presentationBoundary = "service_only"
P.presentationDebt = nil
P.metrics = P.metrics or { unitReads=0, worldReads=0, nativeProjects=0, cameraProjects=0, cameraBatches=0, failures=0,
    unitBatches=0, behindCameraRejects=0, nativeScaleReconciles=0, nativeConsistencyFallbacks=0 }

local function N(v) v=tonumber(v); if v==nil or v~=v or v==math.huge or v==-math.huge then return nil end; return v end
local function NormalizeScreenPoint(x, y)
    x, y = N(x), N(y)
    if x == nil or y == nil then return nil, nil end
    if S.Api == nil or type(S.Api.GetUiMetrics) ~= "function" then return x, y end
    local screenW, screenH, scale, logicalW, logicalH = S.Api:GetUiMetrics()
    screenW, screenH, scale = N(screenW), N(screenH), N(scale) or 1
    logicalW, logicalH = N(logicalW) or 1024, N(logicalH) or 768
    if scale > 0 and scale ~= 1 and (x > logicalW + 2 or y > logicalH + 2)
        and (screenW == nil or x <= screenW + 2) and (screenH == nil or y <= screenH + 2) then
        x, y = x / scale, y / scale
    end
    return x, y
end

function P:ProjectUnit(unitToken)
    unitToken = tostring(unitToken or "")
    if unitToken == "" then return nil,nil,nil,"unit_token_required" end
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return nil,nil,nil,"api_unavailable" end
    self.metrics.unitReads = (tonumber(self.metrics.unitReads) or 0) + 1
    local ok, x, err, y, depth = S.Api:CallCapability("X2Unit:GetUnitScreenPosition", X2Unit, "GetUnitScreenPosition", unitToken)
    x, y, depth = N(x), N(y), N(depth)
    if ok ~= true or x == nil or y == nil then
        self.metrics.failures = (tonumber(self.metrics.failures) or 0) + 1
        return nil,nil,nil,err or "unit_screen_position_unavailable"
    end
    x, y = NormalizeScreenPoint(x, y)
    -- Coordinates must survive normalization and fall inside the logical UI
    -- surface. Some RU builds return (someX, someY, depth=1) for an off-screen
    -- or stale unit (cached screen position before the entity is destroyed, or
    -- a token that resolves to a default origin). The depth check alone is not
    -- enough: consumers that only inspect depth > 0 (Healer head markers) end
    -- up anchoring their widget at a fixed/stale spot rather than on the
    -- target — visible as "the marker floats, never moves, not on the player".
    -- Treat any coordinate outside the logical surface as a projection failure
    -- so callers naturally hide their visual instead of pinning to a stale
    -- point. A small slop (-16..logicalW+16, -16..logicalH+16) absorbs
    -- floating point noise and minor scale mismatches without false negatives.
    if x == nil or y == nil then
        self.metrics.failures = (tonumber(self.metrics.failures) or 0) + 1
        return nil, nil, nil, "screen_position_normalize_failed"
    end
    local _,_,_,logicalW,logicalH = S.Api:GetUiMetrics()
    logicalW, logicalH = N(logicalW) or 1024, N(logicalH) or 768
    if x < -16 or x > logicalW + 16 or y < -16 or y > logicalH + 16 then
        self.metrics.failures = (tonumber(self.metrics.failures) or 0) + 1
        return nil, nil, nil, "screen_position_out_of_bounds"
    end
    return x, y, depth or 1, nil
end

function P:GetUnitWorldPosition(unitToken, isLocal)
    unitToken = tostring(unitToken or "")
    if unitToken == "" then return nil,nil,nil,"unit_token_required" end
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return nil,nil,nil,"api_unavailable" end
    self.metrics.worldReads = (tonumber(self.metrics.worldReads) or 0) + 1
    local ok, x, err, y, z = S.Api:CallCapability("X2Unit:GetUnitWorldPositionByTarget", X2Unit, "GetUnitWorldPositionByTarget", unitToken, isLocal == true)
    x, y, z = N(x), N(y), N(z)
    if ok ~= true or x == nil or y == nil or z == nil then
        self.metrics.failures = (tonumber(self.metrics.failures) or 0) + 1
        return nil,nil,nil,err or "unit_world_position_unavailable"
    end
    return x, y, z, nil
end

function P:_BuildCameraFrame()
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return nil,"api_unavailable" end
    local okP, camPos = S.Api:CallCapability("UIParent:GetViewCameraPos", UIParent, "GetViewCameraPos")
    local okD, camDir = S.Api:CallCapability("UIParent:GetViewCameraDir", UIParent, "GetViewCameraDir")
    if okP ~= true or okD ~= true or type(camPos) ~= "table" or type(camDir) ~= "table" then return nil,"camera_basis_unavailable" end
    local cx,cy,cz=N(camPos.x),N(camPos.y),N(camPos.z); local fx,fy,fz=N(camDir.x),N(camDir.y),N(camDir.z)
    if cx==nil or cy==nil or cz==nil or fx==nil or fy==nil or fz==nil then return nil,"camera_basis_invalid" end
    local fLen=math.sqrt(fx*fx+fy*fy+fz*fz); if fLen<0.001 then return nil,"camera_direction_invalid" end
    fx,fy,fz=fx/fLen,fy/fLen,fz/fLen
    local screenW,screenH,scale,logicalW,logicalH = nil,nil,1,nil,nil
    if S.Api and type(S.Api.GetUiMetrics)=="function" then screenW,screenH,scale,logicalW,logicalH=S.Api:GetUiMetrics() end
    screenW,screenH,scale=N(screenW),N(screenH),N(scale) or 1
    logicalW,logicalH=N(logicalW),N(logicalH)
    -- Camera projection must operate in the same logical coordinate space as
    -- RSUI/UIParent.  Using physical screen pixels here and heuristically
    -- dividing only some points causes range circles to shift away from the
    -- player at non-1.0 UI scale / different resolutions.
    local frameW = logicalW or (screenW and screenW / math.max(0.001,scale))
    local frameH = logicalH or (screenH and screenH / math.max(0.001,scale))
    if frameW==nil or frameH==nil then return nil,"screen_metrics_unavailable" end
    local fov=1.57
    local okF, fovValue = S.Api:CallCapability("UIParent:GetViewCameraFov", UIParent, "GetViewCameraFov")
    if okF==true and N(fovValue)~=nil then fov=N(fovValue) end
    fov=math.max(0.2,math.min(3.0,fov))
    local rx,ry,rz=fy,-fx,0
    local rLen=math.sqrt(rx*rx+ry*ry+rz*rz); if rLen<0.001 then return nil,"camera_right_invalid" end
    rx,ry,rz=rx/rLen,ry/rLen,rz/rLen
    local ux=ry*fz-rz*fy; local uy=rz*fx-rx*fz; local uz=rx*fy-ry*fx
    return { cx=cx,cy=cy,cz=cz,fx=fx,fy=fy,fz=fz,rx=rx,ry=ry,rz=rz,ux=ux,uy=uy,uz=uz,
        screenW=frameW,screenH=frameH,focal=1/math.tan(fov/2),uiScale=scale }
end

function P:_ProjectWithCameraFrame(frame, wx, wy, wz)
    if type(frame)~="table" then return nil,nil,nil end
    local dx,dy,dz=wx-frame.cx,wy-frame.cy,wz-frame.cz
    local distance=math.sqrt(dx*dx+dy*dy+dz*dz); if distance < 0.1 then return nil,nil,nil end
    local forward=dx*frame.fx+dy*frame.fy+dz*frame.fz; if forward <= 0.001 then return nil,nil,nil end
    local rComp=dx*frame.rx+dy*frame.ry+dz*frame.rz; local uComp=dx*frame.ux+dy*frame.uy+dz*frame.uz
    local sx=(frame.screenW/2)+((rComp/forward)*frame.focal*(frame.screenH/2))
    local sy=(frame.screenH/2)-((uComp/forward)*frame.focal*(frame.screenH/2))
    sx,sy=NormalizeScreenPoint(sx,sy)
    return sx,sy,distance
end

function P:_ProjectWithCamera(wx, wy, wz)
    local frame=self:_BuildCameraFrame(); if frame==nil then return nil,nil,nil end
    return self:_ProjectWithCameraFrame(frame,wx,wy,wz)
end

-- Range circles may project dozens of points per sample.  When the optional
-- global projector is unavailable, capture the camera basis ONCE for the whole
-- batch instead of calling three camera getters for every point.
function P:ProjectWorldBatch(points, options)
    options = type(options) == "table" and options or {}
    local source=type(points)=="table" and points or {}
    local out={}; if #source==0 then return out,"empty" end
    local nativeUsable=false
    -- ConvertWorldToScreen has no proven coordinate-space contract on all RU
    -- resolutions.  Geometry that must be centered in RSUI (range circles)
    -- explicitly requests the logical camera path instead of mixing spaces.
    if options.preferLogicalCamera ~= true and S.Api~=nil and type(S.Api.CallGlobalCapability)=="function" then
        local first=source[1]
        local wx,wy,wz=N(first and first.x),N(first and first.y),N(first and first.z)
        if wx~=nil and wy~=nil and wz~=nil then
            local ok,sx,_,sy,depth=S.Api:CallGlobalCapability("ConvertWorldToScreen",wx,wy,wz)
            sx,sy,depth=N(sx),N(sy),N(depth)
            if ok==true and sx~=nil and sy~=nil then
                nativeUsable=true; sx,sy=NormalizeScreenPoint(sx,sy)
                out[1]={x=sx,y=sy,depth=depth or 1}
                self.metrics.nativeProjects=(tonumber(self.metrics.nativeProjects) or 0)+1
            end
        end
    end
    if nativeUsable then
        for index=2,#source do
            local point=source[index]; local wx,wy,wz=N(point and point.x),N(point and point.y),N(point and point.z)
            if wx~=nil and wy~=nil and wz~=nil then
                local ok,sx,_,sy,depth=S.Api:CallGlobalCapability("ConvertWorldToScreen",wx,wy,wz)
                sx,sy,depth=N(sx),N(sy),N(depth)
                if ok==true and sx~=nil and sy~=nil then
                    sx,sy=NormalizeScreenPoint(sx,sy); out[index]={x=sx,y=sy,depth=depth or 1}
                    self.metrics.nativeProjects=(tonumber(self.metrics.nativeProjects) or 0)+1
                end
            end
        end
        return out,"native"
    end
    local frame,frameErr=self:_BuildCameraFrame(); if frame==nil then
        self.metrics.failures=(tonumber(self.metrics.failures) or 0)+1
        return out,frameErr or "world_projection_unavailable"
    end
    self.metrics.cameraBatches=(tonumber(self.metrics.cameraBatches) or 0)+1
    for index,point in ipairs(source) do
        local wx,wy,wz=N(point and point.x),N(point and point.y),N(point and point.z)
        if wx~=nil and wy~=nil and wz~=nil then
            local sx,sy,depth=self:_ProjectWithCameraFrame(frame,wx,wy,wz)
            if sx~=nil and sy~=nil then out[index]={x=sx,y=sy,depth=depth or 1}; self.metrics.cameraProjects=(tonumber(self.metrics.cameraProjects) or 0)+1 end
        end
    end
    return out,"camera"
end

function P:ProjectWorld(wx, wy, wz)
    wx,wy,wz=N(wx),N(wy),N(wz); if wx==nil or wy==nil or wz==nil then return nil,nil,nil,"world_point_required" end
    if S.Api ~= nil and type(S.Api.CallGlobalCapability) == "function" then
        local ok, sx, err, sy, depth = S.Api:CallGlobalCapability("ConvertWorldToScreen", wx, wy, wz)
        sx,sy,depth=N(sx),N(sy),N(depth)
        if ok==true and sx~=nil and sy~=nil then
            self.metrics.nativeProjects=(tonumber(self.metrics.nativeProjects) or 0)+1
            sx,sy=NormalizeScreenPoint(sx,sy)
            return sx,sy,depth or 1,nil
        end
    end
    local sx,sy,depth=self:_ProjectWithCamera(wx,wy,wz)
    if sx~=nil and sy~=nil then
        self.metrics.cameraProjects=(tonumber(self.metrics.cameraProjects) or 0)+1
        return sx,sy,depth or 1,nil
    end
    self.metrics.failures=(tonumber(self.metrics.failures) or 0)+1
    return nil,nil,nil,"world_projection_unavailable"
end

function P:ProjectUnitFlexible(unitToken)
    local x,y,depth,err = self:ProjectUnit(unitToken)
    if x ~= nil and y ~= nil then return x,y,depth,nil,"native_unit" end
    local wx,wy,wz,worldErr = self:GetUnitWorldPosition(unitToken, false)
    if wx == nil then return nil,nil,nil,worldErr or err end
    local sx,sy,projectDepth,projectErr = self:ProjectWorld(wx,wy,wz + 1)
    if sx == nil then return nil,nil,nil,projectErr or err end
    return sx,sy,projectDepth,nil,"world_fallback"
end


local function CameraForwardDistance(frame, wx, wy, wz)
    if type(frame) ~= "table" then return nil end
    wx,wy,wz=N(wx),N(wy),N(wz)
    if wx==nil or wy==nil or wz==nil then return nil end
    return (wx-frame.cx)*frame.fx + (wy-frame.cy)*frame.fy + (wz-frame.cz)*frame.fz
end

-- Unit-line consumers need a stronger visibility fact than the native
-- GetUnitScreenPosition depth value.  On some RU camera angles a unit behind
-- the camera can still produce a positive depth and a mirrored screen point;
-- clipping that point to the viewport creates the false "line points to a
-- corner" artifact.  This batched projection captures one camera basis,
-- deduplicates unit tokens, validates each world point against the camera
-- forward hemisphere, then resolves a logical screen point.  No state is
-- cached across calls; Feature Demand still owns cadence/lifetime.
function P:ProjectUnitBatch(unitTokens, options)
    options = type(options) == "table" and options or {}
    local source = type(unitTokens) == "table" and unitTokens or {}
    local out, ordered, seen = {}, {}, {}
    for _, raw in ipairs(source) do
        local token=tostring(raw or "")
        if token~="" and seen[token]~=true then seen[token]=true; ordered[#ordered+1]=token end
    end
    if #ordered==0 then return out,"empty" end
    local requireFront = options.requireFrontHemisphere == true
    local worldZOffset = tonumber(options.worldZOffset) or 1
    local frontEpsilon = math.max(0.001, tonumber(options.frontEpsilon) or 0.05)
    local validateNative = options.validateNativeAgainstCamera == true
    local reconcileNativeScale = options.reconcileNativeScale == true
    local frame, frameErr = nil, nil
    if requireFront or options.preferCameraFallback == true or validateNative then frame,frameErr=self:_BuildCameraFrame() end
    if requireFront and frame==nil then
        self.metrics.failures=(tonumber(self.metrics.failures) or 0)+1
        for _,token in ipairs(ordered) do out[token]={visible=false,reason=frameErr or "camera_visibility_unavailable"} end
        return out,frameErr or "camera_visibility_unavailable"
    end
    self.metrics.unitBatches=(tonumber(self.metrics.unitBatches) or 0)+1
    for _,token in ipairs(ordered) do
        -- Camera basis and every unit world position must live in the same world
        -- coordinate space.  `isLocal=true` for only the player created a mixed
        -- space edge: the player endpoint could be interpreted relative to the
        -- local origin while target/watchtarget remained global, producing a
        -- stable but visibly wrong line direction.  Unit-line batching therefore
        -- always requests global/world coordinates for every token.
        local wx,wy,wz,worldErr=self:GetUnitWorldPosition(token,false)
        local forward=frame~=nil and CameraForwardDistance(frame,wx,wy,wz) or nil
        if requireFront and (wx==nil or forward==nil) then
            out[token]={visible=false,reason=worldErr or "unit_world_position_unavailable"}
        elseif requireFront and forward<=frontEpsilon then
            self.metrics.behindCameraRejects=(tonumber(self.metrics.behindCameraRejects) or 0)+1
            out[token]={visible=false,reason="behind_camera",forward=forward}
        else
            local cameraX,cameraY,cameraDepth=nil,nil,nil
            if frame~=nil and wx~=nil then
                cameraX,cameraY,cameraDepth=self:_ProjectWithCameraFrame(frame,wx,wy,wz+worldZOffset)
            end

            local x,y,depth,err=self:ProjectUnit(token)
            local sourceName="native_unit"

            -- `GetUnitScreenPosition` is known to vary by UI-scale/client path.
            -- A value may still fall inside the logical viewport and therefore
            -- look "valid" even when it is actually in physical screen pixels.
            -- For Unit Lines we already paid for a single camera frame + world
            -- read to classify the front hemisphere, so use that same fact as a
            -- bounded consistency oracle instead of adding another Native read.
            if validateNative and x~=nil and y~=nil and cameraX~=nil and cameraY~=nil then
                local bestX,bestY=x,y
                local dx,dy=x-cameraX,y-cameraY
                local bestDistance=math.sqrt(dx*dx+dy*dy)

                if reconcileNativeScale and frame~=nil then
                    -- Reuse the metrics captured by the single Camera Frame.
                    -- Unit Lines may run at high cadence; never re-enter
                    -- GetUiMetrics once per token in this loop.
                    local uiScale=N(frame.uiScale) or 1
                    local logicalW,logicalH=N(frame.screenW) or 1024,N(frame.screenH) or 768
                    if uiScale>0 and math.abs(uiScale-1)>0.001 then
                        local sx,sy=x/uiScale,y/uiScale
                        local sdx,sdy=sx-cameraX,sy-cameraY
                        local scaledDistance=math.sqrt(sdx*sdx+sdy*sdy)
                        -- Do not switch spaces for tiny/noisy improvements.  The
                        -- candidate must also remain close to the logical surface.
                        if sx>=-16 and sx<=logicalW+16 and sy>=-16 and sy<=logicalH+16
                            and scaledDistance+8<bestDistance then
                            bestX,bestY,bestDistance=sx,sy,scaledDistance
                            sourceName="native_scale_reconciled"
                            self.metrics.nativeScaleReconciles=(tonumber(self.metrics.nativeScaleReconciles) or 0)+1
                        end
                    end
                end

                local tolerance=tonumber(options.nativeConsistencyTolerance)
                if tolerance==nil then
                    tolerance=math.max(80,math.min(tonumber(frame.screenW) or 1024,tonumber(frame.screenH) or 768)*0.10)
                end
                tolerance=math.max(24,tolerance)
                if bestDistance>tolerance then
                    x,y,depth=cameraX,cameraY,cameraDepth
                    sourceName="camera_consistency_fallback"
                    self.metrics.nativeConsistencyFallbacks=(tonumber(self.metrics.nativeConsistencyFallbacks) or 0)+1
                else
                    x,y=bestX,bestY
                end
            end

            if (x==nil or y==nil) and wx~=nil then
                if cameraX~=nil and cameraY~=nil then
                    x,y,depth=cameraX,cameraY,cameraDepth
                    sourceName="camera_world"
                elseif frame~=nil then
                    x,y,depth=self:_ProjectWithCameraFrame(frame,wx,wy,wz+worldZOffset)
                    sourceName="camera_world"
                else
                    x,y,depth,err=self:ProjectWorld(wx,wy,wz+worldZOffset)
                    sourceName="world_fallback"
                end
            end
            if x~=nil and y~=nil then
                out[token]={visible=true,x=x,y=y,depth=depth or 1,source=sourceName,forward=forward}
            else
                out[token]={visible=false,reason=err or "unit_projection_unavailable",forward=forward}
            end
        end
    end
    return out,"ready"
end

P.FrontHemisphereBatchContractVersion = 1
P.UnitProjectionConsistencyContractVersion = 1

function P:GetHealth()
    return { version=self.version, unitReads=tonumber(self.metrics.unitReads) or 0, worldReads=tonumber(self.metrics.worldReads) or 0,
        nativeProjects=tonumber(self.metrics.nativeProjects) or 0, cameraProjects=tonumber(self.metrics.cameraProjects) or 0,
        cameraBatches=tonumber(self.metrics.cameraBatches) or 0, failures=tonumber(self.metrics.failures) or 0,
        unitBatches=tonumber(self.metrics.unitBatches) or 0, behindCameraRejects=tonumber(self.metrics.behindCameraRejects) or 0,
        nativeScaleReconciles=tonumber(self.metrics.nativeScaleReconciles) or 0,
        nativeConsistencyFallbacks=tonumber(self.metrics.nativeConsistencyFallbacks) or 0 }
end
