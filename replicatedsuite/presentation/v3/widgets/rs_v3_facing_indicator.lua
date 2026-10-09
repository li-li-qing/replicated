------------------------------------------------------------------------
-- 中文维护（2026-10-09）：正背面 Presenter 只渲染 Feature 当前帧，不拥有 Native 观测或第二套 Tick。
-- 两个 17 点弧和两个文字的池固定有界；透明窗口/点/文字均不抢输入，统一沿用 game overlay 层。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
local F=S.Features and S.Features.combat_facing_indicator
if type(F)~="table" or type(S.UI)~="table" then return end
S.UIV3=S.UIV3 or {}
local U=S.UI
local P={owner="v3:facing_indicator",token="presentation:facing_indicator",pools={},labels={},held=false,visiblePoints=0}
S.UIV3.FacingIndicatorV3=P

-- 中文维护：Ensure 返回 accepted/changed，拒绝写入时缓存不得前进；旧控件失效后保持下一帧可重试。
local function Visible(item,value)
    if not item or not item.root then return false,false end
    if item.visible==value then return value,true end
    local accepted=U:EnsureVisible(item.root,value,P.owner)
    if accepted then item.visible=value end
    return accepted==true and value==true,accepted==true
end
function P:Hide()
    self.visiblePoints=0
    -- 中文维护：Show=false 也可能拒写。停止世界采样不依赖 Native UI 接受，但必须保留待隐藏
    -- 事实供原1秒 watchdog 重试，否则两侧关闭/租约撤销后没有 visual_tick，旧弧会永久留屏。
    local hidden=true
    for _,pool in pairs(self.pools) do for _,dot in ipairs(pool) do
        local _,accepted=Visible(dot,false);if not accepted then hidden=false end
    end end
    for _,label in pairs(self.labels) do local _,accepted=Visible(label,false);if not accepted then hidden=false end end
    if self.host and U:EnsureVisible(self.host,false,self.owner)~=true then hidden=false end
    self.hidePending=not hidden
    return hidden,not hidden and "正背面控件隐藏待重试" or nil
end
function P:EnsureItem(side,index,text)
    local pool=self.pools[side] or {};self.pools[side]=pool
    local item=text and self.labels[side] or pool[index]
    if item then return item end
    local label,err=U:CreateLabel(self.host,"v3_facing_"..side.."_"..(text and "label" or tostring(index)),text or ".",
        0,0,text and 54 or 1,text and 22 or 1,15,"strong","CENTER",false)
    if not label then return nil,err end
    label.rsManualTypography,label.rsManualTextColor=true,true
    U:SetPickable(label,false,self.owner)
    item={root=label}
    -- 中文维护：CreateLabel 原生初始状态可能已显示，首次隐藏也可能被拒绝；只有接受才缓存 false。
    -- 否则后续锚点/字号失败的 Hide 会误判“已经隐藏”，把无位置的点永久留在屏幕原点。
    if U:EnsureVisible(label,false,self.owner)==true then item.visible=false end
    if text then self.labels[side]=item else pool[index]=item end
    return item
end
function P:Place(item,point,size,opacity,color,ox,oy,isText,viewportW,viewportH)
    local x=type(point)=="table" and tonumber(point.x) or nil
    local y=type(point)=="table" and tonumber(point.y) or nil
    if not x or not y or x~=x or y~=y or math.abs(x)==math.huge or math.abs(y)==math.huge or point.visible~=true
        or (viewportW and viewportH and (x<0 or y<0 or x>viewportW or y>viewportH)) then
        self.clippedPoints=(self.clippedPoints or 0)+1;Visible(item,false);return false
    end
    -- 中文维护：世界投影是 raw UIParent 点，只减宿主原点；文本按自身尺寸居中，不乘 Addon Scale。
    x,y=math.floor(x-ox-(isText and 27 or 0)+0.5),math.floor(y-oy-(isText and 11 or 0)+0.5)
    if item.x~=x or item.y~=y then
        local accepted,_,anchorErr=U:EnsureAnchor(item.root,self.host,x,y,self.owner)
        if accepted~=true then self.lastPlacementError=anchorErr or "anchor_rejected";self.placementFailures=self.placementFailures+1;Visible(item,false);return false end
        item.x,item.y=x,y
    end
    local fontAccepted,_,fontErr=U:EnsureFontSize(item.root,size,self.owner)
    if fontAccepted~=true then self.lastPlacementError=fontErr or "font_rejected";self.placementFailures=self.placementFailures+1;Visible(item,false);return false end
    if item.r~=color[1] or item.g~=color[2] or item.b~=color[3] or item.opacity~=opacity then
        -- 中文维护：SetColor 的 false 既可能是无变化也可能是拒绝；这里持续交给 UI cache 收敛，
        -- 只有 true 才记 Presenter cache，避免一次拒写后相同颜色永不恢复。
        if U:SetColor(item.root,color[1],color[2],color[3],opacity,self.owner)==true then
            item.r,item.g,item.b,item.opacity=color[1],color[2],color[3],opacity
        end
    end
    return Visible(item,true)
end
function P:Render()
    -- 中文维护（facing-render-evidence-1）：仅记录本次既有渲染的阶段与拒写，不为诊断额外调用 Native。
    -- 实机报告出现 ready/36 个投影点却零显示，旧报告缺少创建/回调失败原因，不能据此改投影倍数。
    self.renderCalls=(self.renderCalls or 0)+1
    self.renderStage="projection"
    self.placementFailures,self.clippedPoints,self.lastPlacementError=0,0,nil
    if not self.held or not F.enabled then return self:Hide() end
    local frame=type(F.GetRenderProjection)=="function" and F:GetRenderProjection() or F:GetProjection()
    self.inputRows=#frame.rows
    if #frame.rows==0 then self.renderStage="empty";return self:Hide() end
    if not self.host then
        self.renderStage="host_create"
        local host,err=U:CreateOverlayWindow("v3_facing_indicator_host",self.owner)
        if not host then return false,err end
        self.host=host
    end
    self.renderStage="environment"
    -- 中文维护：分辨率/画质改变时失效两层位置/样式缓存，保持字体和弧点尺寸；复用原池不造新任务。
    local revision=S.Layout and tonumber(S.Layout.metricsRevision) or 0
    if S.Layout and type(S.Layout.GetUiEnvironmentRevision)=="function" then
        -- 中文维护（facing-revision-return-1）：Layout 返回 revision,reason 两个值，Lua 的末位函数
        -- 实参会展开全部返回；直接 tonumber(Get...) 会把 reason 当进制而报错，整帧在创建弧点前中断。
        -- 先以单变量接收首值，保留 Layout 的双返回契约，不改变环境失效/字体恢复/采样频率。
        local environmentRevision=S.Layout:GetUiEnvironmentRevision()
        revision=tonumber(environmentRevision) or 0
    end
    if self.environmentRevision~=revision then
        self.environmentRevision=revision
        local function Invalidate(item)
            item.x,item.y,item.r,item.g,item.b,item.opacity,item.visible=nil,nil,nil,nil,nil,nil,nil
            if type(U.InvalidateNativeState)=="function" then U:InvalidateNativeState(item.root) end
        end
        for _,pool in pairs(self.pools) do for _,item in ipairs(pool) do Invalidate(item) end end
        for _,item in pairs(self.labels) do Invalidate(item) end
        if type(U.InvalidateNativeState)=="function" then U:InvalidateNativeState(self.host) end
    end
    local ox,oy=0,0
    if S.Layout and type(S.Layout.GetUiParentLocalOrigin)=="function" then
        local ok,x,y,known=pcall(S.Layout.GetUiParentLocalOrigin,S.Layout,self.host)
        if ok and known==true then ox,oy=tonumber(x) or 0,tonumber(y) or 0 end
    end
    local service=S.Services and S.Services.ScreenProjectionV3
    local vw,vh
    if service and type(service.GetUiParentViewport)=="function" then vw,vh=service:GetUiParentViewport() end
    local visible,active=0,{}
    for _,row in ipairs(frame.rows) do
        active[row.key]=true
        self.renderStage="dot_create:"..row.key
        for i=1,math.min(17,#row.points) do
            local dot,err=self:EnsureItem(row.key,i)
            if not dot then self:Hide();return false,err end
            self.renderStage="dot_place:"..row.key..":"..i
            if self:Place(dot,row.points[i],10+frame.settings.pointSize*3,frame.settings.opacity,row.color,ox,oy,false,vw,vh) then visible=visible+1 end
        end
        self.renderStage="label_create:"..row.key
        local label,err=self:EnsureItem(row.key,0,row.label)
        if not label then self:Hide();return false,err end
        self.renderStage="label_place:"..row.key
        self:Place(label,row.labelPoint,15,frame.settings.opacity,row.color,ox,oy,true,vw,vh)
    end
    for key,pool in pairs(self.pools) do if not active[key] then
        for _,dot in ipairs(pool) do Visible(dot,false) end;Visible(self.labels[key],false)
    end end
    self.visiblePoints=visible
    self.renderStage="host_show"
    if U:EnsureVisible(self.host,visible>0,self.owner)~=true then self:Hide();return false,"正背面宿主显示失败" end
    self.renderStage=visible>0 and "visible" or "no_visible_points"
    self.hidePending=false -- 中文维护：恢复显示的成功帧取消上一关闭边沿的待隐藏请求，不能误隐藏新帧。
    return true
end
local function WantsVisuals()
    if S.FeatureRuntime:IsEnabled(F.Id)~=true then return false end
    local front,back=F:GetSideVisibility()
    return front or back
end
function P:Reconcile()
    -- 中文维护（facing-independent-sides-1）：总开关不被两侧偏好改写；两侧隐藏时只撤销本 Presenter
    -- 租约，由现有 Demand 清任务/事件。任一侧重新显示则恢复同一租约，不建立第二个刷新器。
    if not WantsVisuals() then
        local hidden,hideErr=self:Hide()
        if F:HasConsumer(self.token) then
            local ok,err=F:ReleaseConsumer(self.token)
            if ok~=true then return false,err end
        end
        self.held=false
        return hidden,hideErr -- 中文维护：Native 拒写只记录显示待重试，租约和采样仍已释放。
    end
    -- 中文维护：Demand 才是租约 Authority；不能因 Feature.Disable 已清空而重复 Release，也不能
    -- 在静默 ForceQuiesce 后永远相信 Presenter 的 held。共享视觉 watchdog 会低频重试握手。
    if not F:HasConsumer(self.token) then
        self.held=false
        local ok,err=F:AcquireConsumer(self.token)
        if not ok then self:Hide();return false,err end
    end
    self.held=true
    return self:Render()
end
function P:ConvergeTick()
    local wanted=WantsVisuals()
    if wanted and (not self.held or not F:HasConsumer(self.token)) then return self:Invoke("Reconcile") end
    if not wanted and (self.held or F:HasConsumer(self.token)) then return self:Invoke("Reconcile") end
    if not wanted and self.hidePending then return self:Invoke("Hide") end -- 中文维护：仅重试UI隐藏，不领取租约/采样目标。
    return true
end
-- 中文维护：原来的 Report(P:Render()) 会先求值 Render；异常越过 Report 后仅留在总线的
-- LastInternalEventError，模块报告因而显示零错误。这里包住实际调用，保留阶段/堆栈并限速归属本模块。
-- 出错先隐藏旧帧，保留 Consumer 和原任务供下帧恢复，不新增定时器、不取消保护边界。
function P:Invoke(method)
    local called,result,err=xpcall(function()return self[method](self)end,S.SafeTraceback or tostring)
    local failure
    if not called then failure=tostring(result) elseif result~=true then failure=tostring(err or "render_rejected") end
    self.lastRenderError=failure
    if failure then
        self.lastErrorStage=self.renderStage
        pcall(self.Hide,self)
        if S.DiagnosticsManager and type(S.DiagnosticsManager.WarnRateLimited)=="function" then
            S.DiagnosticsManager:WarnRateLimited("facing_indicator","PRESENTATION_FAILED",5000,"正背面显示待重试",
                {moduleId=F.Id,error=failure,stage=self.lastErrorStage})
        end
        return false,failure
    end
    return true
end
if S.Events and type(S.Events.SubscribeInternal)=="function" then
    S.Events:SubscribeInternal(F.UpdateTopic,P,function(_,_,reason)
        -- 中文维护：仅设置边沿重新核对显示需求；16ms visual_tick 仍只渲染，不反复复制设置/握手。
        P:Invoke(reason=="settings_changed" and "Reconcile" or "Render")
    end)
    S.Events:SubscribeInternal(S.FeatureRuntime.LifecycleTopic or "v3.feature.lifecycle",P,function(_,id)
        if id==F.Id then P:Invoke("Reconcile") end
    end)
end
P:Invoke("Reconcile")
if S.ModuleDiagnosticsHub and type(S.ModuleDiagnosticsHub.RegisterProvider)=="function" then
    S.ModuleDiagnosticsHub:RegisterProvider(F.Id,"facing_render",function()
        local poolDots=0;for _,pool in pairs(P.pools) do poolDots=poolDots+#pool end
        local eventError=S.LastInternalEventError
        if type(eventError)~="table" or eventError.topic~=F.UpdateTopic then eventError=nil end
        return {patch="facing-render-evidence-1",held=P.held,hidePending=P.hidePending,visiblePoints=P.visiblePoints,poolLimit=36,environmentRevision=P.environmentRevision,
            hostCreated=P.host~=nil,poolDots=poolDots,renderCalls=P.renderCalls,inputRows=P.inputRows,renderStage=P.renderStage,
            placementFailures=P.placementFailures,clippedPoints=P.clippedPoints,lastPlacementError=P.lastPlacementError,
            lastRenderError=P.lastRenderError,lastErrorStage=P.lastErrorStage,eventError=S.FeatureSliceFactory.Copy(eventError)}
    end)
end
