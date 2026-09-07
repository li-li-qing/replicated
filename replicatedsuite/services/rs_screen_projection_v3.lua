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
-- v9 (2026-09-07, reference alignment): the .18.130b field report showed
-- proj失败=2831 with a lone surviving row — the logical-viewport model
-- (NormalizeScreenPoint heuristic + bounds rejection + native-vs-camera
-- consistency oracle) fought the REAL client's coordinate space. Both working
-- references use raw native coordinates with zero conversion and zero bounds
-- rejection (rp_api.lua UnitScreenPoint/ProjectWorldToScreen, easypull.lua
-- ConvertWorldToScreen), anchoring dots at raw values times addonScale.
-- v9 returns raw coordinates, culls camera-behind via depth, and records the
-- exact failure reason for every rejected read.
P.version = 12
P.presentationBoundary = "service_only"
P.EasyPullWorldToScreenContractVersion = 2
P.presentationDebt = nil
P.metrics = P.metrics or { unitReads=0, worldReads=0, nativeProjects=0, cameraProjects=0, cameraBatches=0, failures=0,
    unitBatches=0, behindCameraRejects=0, nativeScaleReconciles=0, nativeConsistencyFallbacks=0, worldAliasGuards=0, nativeCameraFallbacks=0 }
P.metrics.failuresByReason = P.metrics.failuresByReason or {}

local function N(v) v=tonumber(v); if v==nil or v~=v or v==math.huge or v==-math.huge then return nil end; return v end

-- Single funnel for every rejected read so one paste can name the reason.
local function RecordFailure(reason)
    reason = tostring(reason or "unknown")
    local byReason = P.metrics.failuresByReason
    byReason[reason] = (tonumber(byReason[reason]) or 0) + 1
    P.metrics.failures = (tonumber(P.metrics.failures) or 0) + 1
    P.metrics.lastFailure = { reason = reason, at = (S.NowMs and S.NowMs() or 0) }
end

function P:ProjectUnit(unitToken)
    unitToken = tostring(unitToken or "")
    if unitToken == "" then return nil,nil,nil,"unit_token_required" end
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return nil,nil,nil,"api_unavailable" end
    self.metrics.unitReads = (tonumber(self.metrics.unitReads) or 0) + 1
    -- v9 reference model (rp_api.lua:53-58): raw native read, no scale
    -- conversion, no viewport rejection. depth<=0 is the only cull.
    local ok, x, err, y, depth = S.Api:CallCapability("X2Unit:GetUnitScreenPosition", X2Unit, "GetUnitScreenPosition", unitToken)
    x, y, depth = N(x), N(y), N(depth)
    if ok ~= true or x == nil or y == nil then
        RecordFailure("unit_screen:" .. tostring(err or "unavailable"))
        return nil,nil,nil,err or "unit_screen_position_unavailable"
    end
    if depth ~= nil and depth <= 0 then
        self.metrics.behindCameraRejects = (tonumber(self.metrics.behindCameraRejects) or 0) + 1
        return nil,nil,nil,"behind_camera"
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
        RecordFailure("unit_world:" .. tostring(err or "unavailable"))
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
    -- v11 (.18.137): the ONLY proven camera fallback (rp_api.lua
    -- ProjectWorldToScreen, absorbed by the old working suite) sizes its frame
    -- from UIParent:GetScreenWidth/GetScreenHeight — NOT from GetUiMetrics.
    -- When uiScale differs from 1 those two sources disagree and the ring
    -- rendered at the wrong scale. Use the proven source first.
    local frameW, frameH = nil, nil
    if UIParent ~= nil and type(UIParent.GetScreenWidth) == "function" then
        local okW, w = pcall(function() return UIParent:GetScreenWidth() end)
        local okH, h = pcall(function() return UIParent:GetScreenHeight() end)
        if okW == true and okH == true then frameW, frameH = N(w), N(h) end
    end
    if frameW == nil or frameH == nil or frameW <= 0 or frameH <= 0 then frameW, frameH = screenW, screenH end
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
    return sx,sy,distance
end


-- EasyPull compatibility frame.  This intentionally mirrors the public
-- Strawberry-devs/ArcheRage-addons globals/WorldToScreen.lua math instead of
-- sharing _BuildCameraFrame(): EasyPull does NOT normalize camDir and does NOT
-- clamp FOV.  The live RU client has ConvertWorldToScreen unavailable, so this
-- fallback is the actual range-circle path and must preserve its proven space.
function P:_BuildEasyPullCameraFrame()
    if S.Api == nil or type(S.Api.CallCapability) ~= "function" then return nil,"api_unavailable" end
    local okP, camPos = S.Api:CallCapability("UIParent:GetViewCameraPos", UIParent, "GetViewCameraPos")
    local okD, camDir = S.Api:CallCapability("UIParent:GetViewCameraDir", UIParent, "GetViewCameraDir")
    if okP ~= true or okD ~= true or type(camPos) ~= "table" or type(camDir) ~= "table" then return nil,"camera_basis_unavailable" end
    local cx,cy,cz=N(camPos.x),N(camPos.y),N(camPos.z)
    local fx,fy,fz=N(camDir.x),N(camDir.y),N(camDir.z)
    if cx==nil or cy==nil or cz==nil or fx==nil or fy==nil or fz==nil then return nil,"camera_basis_invalid" end

    local screenW, screenH = nil, nil
    if UIParent ~= nil and type(UIParent.GetScreenWidth) == "function" and type(UIParent.GetScreenHeight) == "function" then
        local okW,w=pcall(function() return UIParent:GetScreenWidth() end)
        local okH,h=pcall(function() return UIParent:GetScreenHeight() end)
        if okW==true and okH==true then screenW,screenH=N(w),N(h) end
    end
    if screenW==nil or screenH==nil or screenW<=0 or screenH<=0 then return nil,"screen_metrics_unavailable" end

    local fov=1.57
    local okF,fovValue=S.Api:CallCapability("UIParent:GetViewCameraFov", UIParent, "GetViewCameraFov")
    if okF==true and N(fovValue)~=nil then fov=N(fovValue) end
    local tanHalf=math.tan(fov/2)
    if tanHalf==0 or tanHalf~=tanHalf then return nil,"camera_fov_invalid" end

    -- Reference: right = camDir x worldUp(0,0,1), then normalize right only.
    local rx,ry,rz=fy,-fx,0
    local rLen=math.sqrt(rx*rx+ry*ry+rz*rz)
    if rLen<0.001 then return nil,"camera_right_invalid" end
    rx,ry,rz=rx/rLen,ry/rLen,rz/rLen
    local ux=ry*fz-rz*fy
    local uy=rz*fx-rx*fz
    local uz=rx*fy-ry*fx
    return { cx=cx,cy=cy,cz=cz,fx=fx,fy=fy,fz=fz,rx=rx,ry=ry,rz=rz,ux=ux,uy=uy,uz=uz,
        screenW=screenW,screenH=screenH,focal=1/tanHalf }
end

function P:_ProjectWithEasyPullCameraFrame(frame, wx, wy, wz)
    if type(frame)~="table" then return nil,nil,nil end
    local dx,dy,dz=wx-frame.cx,wy-frame.cy,wz-frame.cz
    local distance=math.sqrt(dx*dx+dy*dy+dz*dz)
    if distance<0.1 then return nil,nil,nil end
    local forward=dx*frame.fx+dy*frame.fy+dz*frame.fz
    if forward<=0.001 then return nil,nil,nil end
    local rightComponent=dx*frame.rx+dy*frame.ry+dz*frame.rz
    local upComponent=dx*frame.ux+dy*frame.uy+dz*frame.uz
    local screenX=(frame.screenW/2)+((rightComponent/forward)*frame.focal*(frame.screenH/2))
    local screenY=(frame.screenH/2)-((upComponent/forward)*frame.focal*(frame.screenH/2))
    return screenX,screenY,distance
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
    local out={}
    if #source==0 then
        local facts={ at=(S.NowMs and S.NowMs() or 0), total=0, native=0, camera=0, nativeRejected=0, cameraRejected=0,
            mode=options.easyPullCompat==true and "easypull_native_then_worldtoscreen" or (options.nativeOnly==true and "native_only" or "native_then_camera") }
        self.lastWorldBatch=facts
        return out,"empty",facts
    end

    local nativeOnly = options.nativeOnly == true
    local easyPullCompat = options.easyPullCompat == true
    local nativeAvailable = S.Api~=nil and type(S.Api.CallGlobalCapability)=="function"
    local frame, frameErr, frameTried = nil, nil, false
    local nativeAccepted, cameraAccepted, nativeRejected, cameraRejected = 0, 0, 0, 0
    local depthMin, depthMax = nil, nil

    for index=1,#source do
        local point=source[index]
        local wx,wy,wz=N(point and point.x),N(point and point.y),N(point and point.z)
        if wx==nil or wy==nil or wz==nil then
            out[index]={visible=false,reason="invalid_world_point"}
        else
            local placed=false
            local nativeReturnedPoint=false
            if nativeAvailable then
                local ok,sx,_,sy,depth=S.Api:CallGlobalCapability("ConvertWorldToScreen",wx,wy,wz)
                sx,sy,depth=N(sx),N(sy),N(depth)
                -- EasyPull's ProjectWorldToScreen returns the native result as
                -- soon as all three values exist.  Positive-depth culling is
                -- performed by the caller, not by selecting another projector.
                if ok==true and sx~=nil and sy~=nil and depth~=nil then
                    nativeReturnedPoint=true
                    if depth>0 then
                        out[index]={visible=true,x=sx,y=sy,depth=depth,source="native"}
                        nativeAccepted=nativeAccepted+1
                        if depthMin==nil or depth<depthMin then depthMin=depth end
                        if depthMax==nil or depth>depthMax then depthMax=depth end
                        self.metrics.nativeProjects=(tonumber(self.metrics.nativeProjects) or 0)+1
                        placed=true
                    else
                        out[index]={visible=false,reason="native_depth_rejected",depth=depth,source="native"}
                        nativeRejected=nativeRejected+1
                    end
                else
                    nativeRejected=nativeRejected+1
                end
            else
                nativeRejected=nativeRejected+1
            end

            -- Exact EasyPull fallback: only fall back when the native projector
            -- did not return a complete point.  A complete negative-depth
            -- native point remains culled, matching easypull.lua.
            local mayFallback = placed~=true and nativeReturnedPoint~=true and nativeOnly~=true
            if mayFallback then
                if frameTried~=true then
                    frameTried=true
                    if easyPullCompat then frame,frameErr=self:_BuildEasyPullCameraFrame()
                    else frame,frameErr=self:_BuildCameraFrame() end
                end
                local sx,sy,depth
                if frame~=nil then
                    if easyPullCompat then sx,sy,depth=self:_ProjectWithEasyPullCameraFrame(frame,wx,wy,wz)
                    else sx,sy,depth=self:_ProjectWithCameraFrame(frame,wx,wy,wz) end
                end
                if sx~=nil and sy~=nil and depth~=nil and depth>0 then
                    out[index]={visible=true,x=sx,y=sy,depth=depth,source=easyPullCompat and "easypull_camera" or "camera_per_point"}
                    cameraAccepted=cameraAccepted+1
                    if depthMin==nil or depth<depthMin then depthMin=depth end
                    if depthMax==nil or depth>depthMax then depthMax=depth end
                    self.metrics.cameraProjects=(tonumber(self.metrics.cameraProjects) or 0)+1
                    placed=true
                else
                    cameraRejected=cameraRejected+1
                    out[index]={visible=false,reason=frameErr or "camera_projection_unavailable"}
                end
            elseif placed~=true and nativeOnly==true and nativeReturnedPoint~=true then
                out[index]={visible=false,reason=nativeAvailable and "native_projection_rejected" or "native_projection_unavailable"}
            end
        end
    end

    if frameTried==true then self.metrics.cameraBatches=(tonumber(self.metrics.cameraBatches) or 0)+1 end

    -- Camera projection gives the ring correct perspective, but on RU the camera
    -- principal point and the native unit-screen anchor are not guaranteed to
    -- share the same origin at every resolution/UI scale.  This is especially
    -- visible at 1280x768: the ring shape is correct while its centre is shifted
    -- away from the player.  When the entire EasyPull batch is on the camera
    -- fallback path, align ONE projected world centre to ONE native unit-screen
    -- fact and translate the whole batch by the same delta.  The ring therefore
    -- stays a rigid projection (no per-point mixing/scaling), and the calibration
    -- automatically follows resolution/UI-scale changes every refresh.
    local calibrationStatus, calibrationDx, calibrationDy, calibrationErr = "not_requested", nil, nil, nil
    local anchorUnit=tostring(options.anchorUnit or "")
    local anchorWorld=type(options.anchorWorld)=="table" and options.anchorWorld or nil
    if easyPullCompat and cameraAccepted>0 and nativeAccepted==0 and anchorUnit~="" and anchorWorld~=nil then
        calibrationStatus="unavailable"
        local awx,awy,awz=N(anchorWorld.x),N(anchorWorld.y),N(anchorWorld.z)
        local anchorX,anchorY,_,anchorErr=self:ProjectUnit(anchorUnit)
        local projectedX,projectedY=nil,nil
        if frame~=nil and awx~=nil and awy~=nil and awz~=nil then
            projectedX,projectedY=self:_ProjectWithEasyPullCameraFrame(frame,awx,awy,awz)
        end
        if anchorX~=nil and anchorY~=nil and projectedX~=nil and projectedY~=nil then
            local dx,dy=anchorX-projectedX,anchorY-projectedY
            local _,_,_,logicalW,logicalH=nil,nil,nil,nil,nil
            if S.Api~=nil and type(S.Api.GetUiMetrics)=="function" then
                local okMetrics,sw,sh,_,lw,lh=pcall(function() return S.Api:GetUiMetrics() end)
                if okMetrics then
                    logicalW=math.max(N(sw) or 0,N(lw) or 0)
                    logicalH=math.max(N(sh) or 0,N(lh) or 0)
                end
            end
            local boundW=math.max(1024,N(frame and frame.screenW) or 0,N(logicalW) or 0)
            local boundH=math.max(768,N(frame and frame.screenH) or 0,N(logicalH) or 0)
            if math.abs(dx)<=boundW and math.abs(dy)<=boundH then
                for index=1,#source do
                    local row=out[index]
                    if type(row)=="table" and row.visible==true and row.source=="easypull_camera" then
                        row.x=row.x+dx; row.y=row.y+dy
                    end
                end
                calibrationStatus="applied"
                calibrationDx,calibrationDy=dx,dy
            else
                calibrationStatus="rejected"
                calibrationErr="anchor_delta_out_of_bounds"
            end
        else
            calibrationErr=tostring(anchorErr or "anchor_projection_unavailable")
        end
    elseif easyPullCompat and cameraAccepted>0 and nativeAccepted>0 and anchorUnit~="" then
        -- Never translate only half of a ring.  Mixed native/camera batches keep
        -- their original points and expose the condition in telemetry instead.
        calibrationStatus="mixed_source_skipped"
    end

    local mode=easyPullCompat and "easypull_native_then_worldtoscreen" or (nativeOnly and "native_only" or "native_then_camera")
    local facts={ at=(S.NowMs and S.NowMs() or 0), total=#source, native=nativeAccepted,
        camera=cameraAccepted, nativeRejected=nativeRejected, cameraRejected=cameraRejected, frameErr=frameErr,
        depthMin=depthMin, depthMax=depthMax, mode=mode, calibrationStatus=calibrationStatus,
        calibrationDx=calibrationDx, calibrationDy=calibrationDy, calibrationErr=calibrationErr,
        sample=(out[1]~=nil) and (tostring(math.floor(tonumber(out[1].x) or 0))..","..tostring(math.floor(tonumber(out[1].y) or 0)).."/"..tostring(out[1].source or (out[1].visible==true and "native" or out[1].reason))) or nil }
    self.lastWorldBatch=facts
    if nativeAccepted<=0 and cameraAccepted<=0 then
        local failure=nativeOnly and "native_world_projection_unavailable" or (frameErr or "world_projection_unavailable")
        RecordFailure(failure)
        return out,failure,facts
    end
    return out,(nativeAccepted>0 and "native" or (easyPullCompat and "easypull_camera" or "camera")),facts
end

function P:ProjectWorld(wx, wy, wz)
    wx,wy,wz=N(wx),N(wy),N(wz); if wx==nil or wy==nil or wz==nil then return nil,nil,nil,"world_point_required" end
    if S.Api ~= nil and type(S.Api.CallGlobalCapability) == "function" then
        local ok, sx, err, sy, depth = S.Api:CallGlobalCapability("ConvertWorldToScreen", wx, wy, wz)
        sx,sy,depth=N(sx),N(sy),N(depth)
        if ok==true and sx~=nil and sy~=nil then
            self.metrics.nativeProjects=(tonumber(self.metrics.nativeProjects) or 0)+1
            return sx,sy,depth~=nil and depth or 1,nil
        end
    end
    local sx,sy,depth=self:_ProjectWithCamera(wx,wy,wz)
    if sx~=nil and sy~=nil then
        self.metrics.cameraProjects=(tonumber(self.metrics.cameraProjects) or 0)+1
        return sx,sy,depth or 1,nil
    end
    RecordFailure("world_projection_unavailable")
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
    -- v9: validateNativeAgainstCamera / reconcileNativeScale are accepted and
    -- ignored (native coordinates always win; camera math only fills gaps).
    -- Exact/near-exact duplicated world coordinates across DIFFERENT unit
    -- tokens are suspicious on RU. During target transitions the native world
    -- getter can briefly alias the target to the player while the native screen
    -- getter already points at the real target. A 0.15-world-unit threshold is
    -- intentionally tiny: ordinary nearby players are not treated as aliases.
    local aliasWorldDistance = math.max(0.001, tonumber(options.worldAliasDistance) or 0.15)
    local aliasWorldDistanceSq = aliasWorldDistance * aliasWorldDistance
    local aliasScreenSeparation = math.max(24, tonumber(options.worldAliasScreenSeparation) or 48)
    local aliasScreenSeparationSq = aliasScreenSeparation * aliasScreenSeparation

    local frame, frameErr = nil, nil
    if requireFront or options.preferCameraFallback == true then frame,frameErr=self:_BuildCameraFrame() end
    if requireFront and frame==nil then
        -- Front-hemisphere classification is preferred, but a transient camera
        -- basis failure must not permanently blank Unit Lines. Native unit
        -- projection is already normalized + bounds checked; use it as a
        -- call-local recovery path and resume strict camera validation as soon
        -- as the next batch can build a frame.
        local anyVisible = false
        for _,token in ipairs(ordered) do
            local x,y,depth,err=self:ProjectUnit(token)
            if x~=nil and y~=nil then
                out[token]={visible=true,x=x,y=y,depth=depth or 1,source="native_camera_unavailable"}
                anyVisible=true
                self.metrics.nativeCameraFallbacks=(tonumber(self.metrics.nativeCameraFallbacks) or 0)+1
            else out[token]={visible=false,reason=err or frameErr or "camera_visibility_unavailable"} end
        end
        if anyVisible then
            self.metrics.unitBatches=(tonumber(self.metrics.unitBatches) or 0)+1
            return out,"native_camera_unavailable"
        end
        self.metrics.failures=(tonumber(self.metrics.failures) or 0)+1
        return out,frameErr or "camera_visibility_unavailable"
    end
    self.metrics.unitBatches=(tonumber(self.metrics.unitBatches) or 0)+1

    -- Pass 1: read every world fact exactly once and derive camera facts. This
    -- is still O(unitCount) Native work; Unit Lines currently have at most five
    -- distinct tokens. We keep these facts in a call-local batch only — no
    -- cross-frame cache can make a stale target survive a target switch.
    local facts = {}
    for _,token in ipairs(ordered) do
        local wx,wy,wz,worldErr=self:GetUnitWorldPosition(token,false)
        local forward=frame~=nil and CameraForwardDistance(frame,wx,wy,wz) or nil
        local cameraX,cameraY,cameraDepth=nil,nil,nil
        if frame~=nil and wx~=nil then
            cameraX,cameraY,cameraDepth=self:_ProjectWithCameraFrame(frame,wx,wy,wz+worldZOffset)
        end
        facts[token]={ token=token, wx=wx, wy=wy, wz=wz, worldErr=worldErr, forward=forward,
            cameraX=cameraX, cameraY=cameraY, cameraDepth=cameraDepth,
            aliasCandidate=false, worldAliased=false }
    end

    -- Detect only candidate duplicates first. A duplicate world coordinate is
    -- not enough to override anything: two units may genuinely overlap. It only
    -- authorizes a Native-screen read even if that world fact says "behind",
    -- so we can gather independent evidence before deciding.
    for i=1,#ordered-1 do
        local a=facts[ordered[i]]
        if a.wx~=nil then
            for j=i+1,#ordered do
                local b=facts[ordered[j]]
                if b.wx~=nil then
                    local dx,dy,dz=a.wx-b.wx,a.wy-b.wy,a.wz-b.wz
                    if dx*dx+dy*dy+dz*dz<=aliasWorldDistanceSq then
                        a.aliasCandidate,b.aliasCandidate=true,true
                    end
                end
            end
        end
    end

    -- Pass 2: native screen fact. Unique, definite-behind units keep the old
    -- optimization and are rejected without a screen read. Alias candidates are
    -- the only exception because their world-forward fact itself is suspect.
    for _,token in ipairs(ordered) do
        local fact=facts[token]
        local worldAvailable=fact.wx~=nil and (not requireFront or fact.forward~=nil)
        local definitelyBehind=requireFront and worldAvailable and fact.forward<=frontEpsilon
        if worldAvailable and (not definitelyBehind or fact.aliasCandidate==true) then
            local x,y,depth,err=self:ProjectUnit(token)
            fact.nativeX,fact.nativeY,fact.nativeDepth,fact.nativeErr=x,y,depth,err
        end
    end

    -- Confirm aliases only when the independent native screen facts clearly
    -- disagree with the duplicated world fact. This is the proof that lets the
    -- screen fact outrank world/camera consistency for THIS batch only.
    for i=1,#ordered-1 do
        local a=facts[ordered[i]]
        if a.aliasCandidate==true and a.nativeX~=nil then
            for j=i+1,#ordered do
                local b=facts[ordered[j]]
                if b.aliasCandidate==true and b.nativeX~=nil and a.wx~=nil and b.wx~=nil then
                    local wdx,wdy,wdz=a.wx-b.wx,a.wy-b.wy,a.wz-b.wz
                    if wdx*wdx+wdy*wdy+wdz*wdz<=aliasWorldDistanceSq then
                        local sdx,sdy=a.nativeX-b.nativeX,a.nativeY-b.nativeY
                        if sdx*sdx+sdy*sdy>=aliasScreenSeparationSq then
                            a.worldAliased,b.worldAliased=true,true
                        end
                    end
                end
            end
        end
    end

    for _,token in ipairs(ordered) do
        local fact=facts[token]
        local wx,forward=fact.wx,fact.forward
        if requireFront and (wx==nil or forward==nil) then
            out[token]={visible=false,reason=fact.worldErr or "unit_world_position_unavailable"}
        elseif requireFront and forward<=frontEpsilon and fact.worldAliased~=true then
            self.metrics.behindCameraRejects=(tonumber(self.metrics.behindCameraRejects) or 0)+1
            out[token]={visible=false,reason="behind_camera",forward=forward}
        elseif fact.worldAliased==true then
            -- Do NOT use the camera projection here: it was derived from the
            -- very world fact we just proved inconsistent. Native endpoints are
            -- call-local and already normalized/bounds-checked by ProjectUnit.
            if fact.nativeX~=nil and fact.nativeY~=nil then
                self.metrics.worldAliasGuards=(tonumber(self.metrics.worldAliasGuards) or 0)+1
                out[token]={visible=true,x=fact.nativeX,y=fact.nativeY,depth=fact.nativeDepth or 1,
                    source="native_world_alias_guard",forward=forward,worldAliased=true}
            else
                out[token]={visible=false,reason=fact.nativeErr or "world_alias_native_unavailable",forward=forward,worldAliased=true}
            end
            else
            local cameraX,cameraY,cameraDepth=fact.cameraX,fact.cameraY,fact.cameraDepth
            local x,y,depth,err=fact.nativeX,fact.nativeY,fact.nativeDepth,fact.nativeErr
            local sourceName="native_unit"

            if fact.aliasCandidate==true then
                -- The world fact of an alias candidate is suspect (another unit
                -- reported near-identical world coordinates), and the camera
                -- projection was derived from exactly that suspect fact. When
                -- the alias could not be CONFIRMED (the paired native screen
                -- read failed or the two native points coincide), accepting the
                -- camera fallback here would anchor the endpoint onto the
                -- aliased position -- the reported "line collapses onto my own
                -- character" failure. Native screen evidence is independent, so
                -- it is accepted as-is; without it the endpoint fails closed.
                if x~=nil and y~=nil then
                    self.metrics.aliasNativeKept=(tonumber(self.metrics.aliasNativeKept) or 0)+1
                    out[token]={visible=true,x=x,y=y,depth=depth or 1,
                        source="native_alias_candidate",forward=forward,aliasCandidate=true}
                else
                    self.metrics.aliasNativeRejects=(tonumber(self.metrics.aliasNativeRejects) or 0)+1
                    out[token]={visible=false,reason=err or "alias_candidate_native_unavailable",
                        forward=forward,aliasCandidate=true}
                end
            else

            -- v9 reference alignment: native screen coordinates WIN. The old
            -- native-vs-camera consistency oracle REPLACED native coords with
            -- logical-frame camera math whenever they disagreed beyond 10% of
            -- the viewport — but the camera frame was the side in the wrong
            -- space (proj失败=2831). Native raw coords are the only proven
            -- space; camera math is now a fill-in used only when the native
            -- read is missing. The validateNativeAgainstCamera /
            -- reconcileNativeScale options are accepted and ignored.
            if x~=nil and y~=nil then
                -- keep native fact
            elseif cameraX~=nil and cameraY~=nil then
                x,y,depth=cameraX,cameraY,cameraDepth
                sourceName="camera_world"
            end

            if (x==nil or y==nil) and wx~=nil then
                if cameraX~=nil and cameraY~=nil then
                    x,y,depth=cameraX,cameraY,cameraDepth
                    sourceName="camera_world"
                elseif frame~=nil then
                    x,y,depth=self:_ProjectWithCameraFrame(frame,wx,fact.wy,fact.wz+worldZOffset)
                    sourceName="camera_world"
                else
                    x,y,depth,err=self:ProjectWorld(wx,fact.wy,fact.wz+worldZOffset)
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
    end
    return out,"ready"
end

P.FrontHemisphereBatchContractVersion = 1
P.UnitProjectionConsistencyContractVersion = 1
P.UnitWorldAliasGuardContractVersion = 1
P.WorldBatchIndexContractVersion = 1
P.WorldBatchFactsContractVersion = 2
P.WorldBatchAnchorCalibrationContractVersion = 1
P.CameraUnavailableNativeFallbackContractVersion = 1

function P:GetHealth()
    return { version=self.version, unitReads=tonumber(self.metrics.unitReads) or 0, worldReads=tonumber(self.metrics.worldReads) or 0,
        nativeProjects=tonumber(self.metrics.nativeProjects) or 0, cameraProjects=tonumber(self.metrics.cameraProjects) or 0,
        cameraBatches=tonumber(self.metrics.cameraBatches) or 0, failures=tonumber(self.metrics.failures) or 0,
        failuresByReason=self.metrics.failuresByReason, lastFailure=self.metrics.lastFailure,
        unitBatches=tonumber(self.metrics.unitBatches) or 0, behindCameraRejects=tonumber(self.metrics.behindCameraRejects) or 0,
        nativeScaleReconciles=tonumber(self.metrics.nativeScaleReconciles) or 0,
        nativeConsistencyFallbacks=tonumber(self.metrics.nativeConsistencyFallbacks) or 0,
        worldAliasGuards=tonumber(self.metrics.worldAliasGuards) or 0,
        aliasNativeKept=tonumber(self.metrics.aliasNativeKept) or 0,
        aliasNativeRejects=tonumber(self.metrics.aliasNativeRejects) or 0,
        nativeCameraFallbacks=tonumber(self.metrics.nativeCameraFallbacks) or 0,
        viewportRejects=tonumber(self.metrics.viewportRejects) or 0 }
end
