------------------------------------------------------------------------
-- 中文维护（2026-10-09）：当前目标正面/背面可视提示的独立 Feature。
-- Native 坐标/角度/深度归属 ScreenProjectionV3，几何与配置归属本 Feature，UI 只消费 detached 帧。
-- 仅观察 target，不枚举附近单位、不推断技能背击范围；存档不包含目标、角度或投影结果。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Factory = S.FeatureSliceFactory
if type(Factory) ~= "table" then error("FeatureSliceFactory unavailable for combat_facing_indicator") end
local TASK, INTERVAL, COUNT = "v3_facing_indicator_refresh", 16, 17
-- 中文维护（facing-independent-sides-1）：侧显示属于本 Feature 永久设置；旧存档缺字段时两侧默认开，
-- 明确 false 必须原样回读，不能以 and/or fallback 把用户关闭意图恢复成 true；数值校准不改。
local DEFAULT = { radius=2, arcDegrees=90, pointSize=4, opacity=0.85, angleOffset=0, showFront=true, showBack=true }
local LIMITS = { radius={0.5,50}, arcDegrees={20,160}, pointSize={2,10}, opacity={0.1,1}, angleOffset={-180,180} }
local SIDES = { {key="front",setting="showFront",label="正面",color={1,0.28,0.22},sign=1}, {key="back",setting="showBack",label="背面",color={0.25,1,0.4},sign=-1} }

-- 中文维护：非有限数是输入错误；归一只在配置读入/显式事务进行，不在高频路径回写 State。
local function Finite(value)
    local n=tonumber(value)
    if n==nil or n~=n or n==math.huge or n==-math.huge then return nil end
    return n
end
local function Normalize(key, value)
    if type(DEFAULT[key])=="boolean" then
        if type(value)=="boolean" then return value end
        return DEFAULT[key]
    end
    local n=Finite(value) or DEFAULT[key]
    n=math.max(LIMITS[key][1],math.min(LIMITS[key][2],n))
    if key=="pointSize" then n=math.floor(n) end
    return n
end
local function Frame(feature, rows, status, reason)
    feature.FrameStatus={ status=status, reason=reason, at=S.NowMs and S.NowMs() or 0 }
    return rows,status,reason
end
local function Clear(feature)
    -- 中文维护：最后租约/停用释放任务及纯数学工作区，同时发布空帧，不能留上一目标的箭头。
    if S.Scheduler then S.Scheduler:RemoveTask(TASK) end
    feature.Geometry,feature.LastBatch,feature.MetricFacts=nil,nil,nil
    feature.Authority.rows,feature.Authority.status,feature.Authority.error={},"idle",nil
    feature.Authority.revision=feature.Authority.revision+1
    if S.Events then S.Events:Publish(feature.UpdateTopic,feature.Authority.revision,"quiesce") end
end
local function Geometry(feature)
    local g=feature.Geometry
    -- 中文维护：侧开关变化必须失效几何；只有显示的一侧进入紧凑批次，单侧18点、双侧36点。
    -- 不在 Presenter 先算/再丢弃隐藏侧，避免视觉关闭但 Native/数学/复制工作量仍保持双侧。
    if g and g.arcDegrees==feature.State.arcDegrees and g.showFront==feature.State.showFront and g.showBack==feature.State.showBack then return g end
    g={ arcDegrees=feature.State.arcDegrees, showFront=feature.State.showFront,showBack=feature.State.showBack,directions={},world={},sides={} }
    for _,side in ipairs(SIDES)do if feature.State[side.setting]==true then g.sides[#g.sides+1]=side end end
    local half=feature.State.arcDegrees*math.pi/360
    for i=1,COUNT do
        local a=-half+2*half*(i-1)/(COUNT-1)
        g.directions[i]={x=math.cos(a),y=math.sin(a)}
    end
    for i=1,#g.sides*(COUNT+1) do g.world[i]={x=0,y=0,z=0} end
    feature.Geometry=g
    return g
end

local F=Factory.NewFeature("combat_facing_indicator", {
    apiDependencies={"X2Unit:GetTargetUnitId","X2Unit:GetUnitWorldPositionByTarget","X2Unit:GetUnitScreenPosition","X2Unit:UnitDistance"},
    state=Factory.Copy(DEFAULT), default=Factory.Copy(DEFAULT), observationContractVersion=1,
    apply=function(value,state)
        value=type(value)=="table" and value or {}
        for key in pairs(DEFAULT) do state[key]=Normalize(key,value[key]) end -- 中文维护：直接读取字段，不能经 or nil 丢掉 false。
        return true
    end,
    event="TARGET_CHANGED",
    onEvent=function(feature) return feature.Authority:Refresh("target_changed") end,
    reconcileDemand=function(feature,before,after)
        local b,a=tonumber(before and before.count) or 0,tonumber(after and after.count) or 0
        if b<=0 and a>0 then
            if S.Scheduler==nil or type(S.Scheduler.AddHighFrequencyTask)~="function" then return false,"正背面刷新 Scheduler 不可用" end
            -- 中文维护：仅一个共享 Scheduler 高频任务；无目标仍可等待下一目标，关闭/无租约立即停。
            local added=S.Scheduler:AddHighFrequencyTask(TASK,INTERVAL,function()
                if feature.enabled~=true or (tonumber(feature.consumerCount) or 0)<=0 then return true end
                local ok,err=xpcall(function()return feature.Authority:Refresh("visual_tick")end,S.SafeTraceback)
                if not ok then
                    -- 中文维护：采样异常必须清空当前画面；不撤销任务，下一帧可自行恢复，限速输出诊断。
                    feature.Authority.rows,feature.Authority.status,feature.Authority.error={},"unavailable",tostring(err)
                    feature.Authority.revision=feature.Authority.revision+1
                    if S.Events then S.Events:Publish(feature.UpdateTopic,feature.Authority.revision,"visual_tick_error") end
                    if S.DiagnosticsManager and type(S.DiagnosticsManager.WarnRateLimited)=="function" then
                        S.DiagnosticsManager:WarnRateLimited("facing_indicator","REFRESH_FAILED",5000,"正背面采样失败，已隐藏旧标记",{error=tostring(err)})
                    end
                end
                return true
            end,false,feature,"P1",1)
            if added~=true then return false,"正背面刷新任务创建失败" end
            if type(S.Scheduler.SetTaskModule)=="function" then S.Scheduler:SetTaskModule(TASK,feature.Id) end
        elseif b>0 and a<=0 then Clear(feature) end
        return true
    end,
    onDisable=function(feature) Clear(feature);return true end,
    read=function(feature)
        -- 中文维护：Feature 关闭/无 Consumer 时禁止读游戏；GetProjection/设置页读取不触发采样。
        if feature.enabled~=true or (tonumber(feature.consumerCount) or 0)<=0 then return Frame(feature,{},"idle") end
        -- 中文维护：即使其他调用方暂时仍持有租约，两侧关闭也不读目标/镜头；显示租约会在同次设置事件释放。
        if feature.State.showFront~=true and feature.State.showBack~=true then return Frame(feature,{},"idle","正面和背面均已隐藏") end
        local service=S.Services and S.Services.ScreenProjectionV3
        if type(service)~="table" or type(service.GetUnitPose)~="function" then return Frame(feature,{},"unavailable","目标朝向服务不可用") end
        local okId,id,idErr=Factory.Call("X2Unit:GetTargetUnitId",nil,"GetTargetUnitId")
        if not okId then return Frame(feature,{},"unavailable",idErr) end
        if id==nil or id=="" or id==0 then return Frame(feature,{},"empty","当前没有目标") end
        local sx,_,_,screenErr=service:ProjectUnit("target")
        if sx==nil then return Frame(feature,{},"unavailable",screenErr) end
        local pose,poseErr=service:GetUnitPose("target",true)
        if pose==nil then return Frame(feature,{},"unavailable",poseErr) end
        local px,py,pz,playerErr=service:GetUnitWorldPosition("player",true)
        if px==nil then return Frame(feature,{},"unavailable",playerErr) end
        -- 中文维护：米标定复用共享 500ms 有界事实；两种世界指引共享比例，不能另写第二套倍数。
        local metric=service:GetRangeMetricCalibration({anchorUnit="player",targetUnit="target",
            anchorWorld={x=px,y=py,z=pz},targetWorld=pose,intervalMs=500,aspectSafeCamera=true,worldZOffset=0.1})
        feature.MetricFacts=metric
        local radius=feature.State.radius*(Finite(metric.worldUnitsPerMeter) or 1)
        local angle=pose.angle+feature.State.angleOffset*math.pi/180
        local fx,fy=math.cos(angle),math.sin(angle)
        local g=Geometry(feature)
        for sideIndex,side in ipairs(g.sides) do
            local offset=(sideIndex-1)*(COUNT+1)
            for i=1,COUNT do
                local d,w=g.directions[i],g.world[offset+i]
                w.x=pose.x+side.sign*(fx*d.x-fy*d.y)*radius
                w.y=pose.y+side.sign*(fy*d.x+fx*d.y)*radius
                w.z=pose.z+0.1
            end
            local label=g.world[offset+COUNT+1]
            label.x,label.y,label.z=pose.x+side.sign*fx*radius*1.3,pose.y+side.sign*fy*radius*1.3,pose.z+0.1
        end
        -- 中文维护：前弧/后弧/文字同批投影，同一帧源；相机 fallback 使用与范围辅助同源的玩家
        -- 锚点，不能把目标的头顶 screen 点直接当脚底。目标切换时不共用范围圆锚点稳定器。
        local projected,_,batch=service:ProjectWorldBatch(g.world,{easyPullCompat=true,rigidBatch=true,aspectSafeCamera=true,
            anchorUnit="player",anchorWorld={x=px,y=py,z=pz+0.1},metricScreenScale=metric.projectionScale})
        feature.LastBatch=batch
        -- 中文维护：相机 fallback 若未成功对齐已验证的玩家屏幕锚点，则不能把未校准位置画成脚底。
        -- 保持失败时隐藏和下帧自动重试；Native 整批成功无需这个 fallback 平移校验。
        if type(batch)=="table" and batch.rigidSource=="camera" and batch.calibrationStatus~="applied" then
            return Frame(feature,{},"unavailable","正背面相机锚点暂不可用")
        end
        local okAfter,afterId=Factory.Call("X2Unit:GetTargetUnitId",nil,"GetTargetUnitId")
        if not okAfter or afterId~=id then return Frame(feature,{},"empty","目标已切换，丢弃旧帧") end
        local rows,visible={},0
        for sideIndex,side in ipairs(g.sides) do
            local offset=(sideIndex-1)*(COUNT+1)
            local row={key=side.key,label=side.label,color=side.color,points={},labelPoint=projected and projected[offset+COUNT+1]}
            for i=1,COUNT do
                local point=projected and projected[offset+i]
                row.points[i]=point or {visible=false}
                if point and point.visible==true then visible=visible+1 end
            end
            rows[#rows+1]=row
        end
        if visible==0 then return Frame(feature,{},"unavailable","正背面标记投影不可见") end
        return Frame(feature,rows,"ready")
    end,
    projection=function(feature) return {enabled=feature.enabled==true,settings=Factory.Copy(feature.State),frame=feature.FrameStatus} end,
    commands={SetValue=function(feature,key,value)
        value=Finite(value) -- 中文维护：精确输入可能是数字字符串，后续范围比较统一使用已验证 number。
        if LIMITS[key]==nil or value==nil then return false,"正背面设置值无效" end
        if value<LIMITS[key][1] or value>LIMITS[key][2] then return false,"设置值超出允许范围" end
        local ok,err=Factory.PersistStateMutation(feature,"facing_setting_"..key,function(state)state[key]=Normalize(key,value);return true end)
        if ok then feature:Refresh("settings_changed") end
        return ok,err
    end,SetSideEnabled=function(feature,side,value)
        local key=side=="front" and "showFront" or (side=="back" and "showBack" or nil)
        if not key or type(value)~="boolean" then return false,"正背面显示开关无效" end
        local ok,err=Factory.PersistStateMutation(feature,"facing_side_"..side,function(state)state[key]=value;return true end)
        -- 中文维护：无消费者时也发布一次只读设置帧，让重新开启一侧立即握手；不能依赖下一次1秒
        -- watchdog 或页面私自 Acquire。Authority 的 idle 路径不读 Native，写保护拒绝时不改变租约。
        if ok then feature.Authority:Refresh("settings_changed") end
        return ok,err
    end},
})
-- 中文维护：只公开设置契约与只读现有诊断；不在诊断路径 AcquireConsumer 或读 Native。
F.Limits=Factory.Copy(LIMITS)
F.FacingIndicatorContractVersion=2 -- 中文维护：契约增加两侧独立开关；原 Store ID/Schema 与数值设置保持兼容。
function F:GetRenderProjection()
    -- 中文维护（performance-snapshot-1）：绘制只复制当前屏幕坐标/显隐/样式，去掉逐点深度、
    -- 来源与页面诊断字段。每次返回独立小表，不缓存目标事实，不采样Native、不授予Authority引用。
    local function Point(point)
        if type(point)~="table" then return nil end
        return {x=point.x,y=point.y,visible=point.visible}
    end
    local snapshot={revision=self.Authority.revision,status=self.Authority.status,error=self.Authority.error,
        settings={pointSize=self.State.pointSize,opacity=self.State.opacity},rows={}}
    for _,row in ipairs(self.Authority.rows or {}) do
        local points={}
        for i=1,math.min(COUNT,#row.points) do points[i]=Point(row.points[i]) end
        snapshot.rows[#snapshot.rows+1]={key=row.key,label=row.label,
            color={row.color[1],row.color[2],row.color[3]},points=points,labelPoint=Point(row.labelPoint)}
    end
    return snapshot
end
function F:GetSideVisibility()
    -- 中文维护：Presenter 生命周期只读此设置投影；不复制世界帧、不采样 Native、不授予业务写权限。
    return self.State.showFront==true,self.State.showBack==true
end
if S.ModuleDiagnosticsHub and type(S.ModuleDiagnosticsHub.RegisterProvider)=="function" then
    S.ModuleDiagnosticsHub:RegisterProvider(F.Id,"facing_projection",function()
        return {frame=Factory.Copy(F.FrameStatus),batch=Factory.Copy(F.LastBatch),metric=Factory.Copy(F.MetricFacts),consumerCount=F.consumerCount}
    end)
end
