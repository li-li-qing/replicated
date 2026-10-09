------------------------------------------------------------------------
-- 中文维护（2026-10-09）：正背面设置使用既有 PageHost/RSUI/Feature Commands；页面不保活采样。
-- 页面编辑和 16ms 世界帧分离，不能每帧重写 NumericField 草稿或抢游戏聊天焦点。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
local F=S.Features and S.Features.combat_facing_indicator
local RSUI,D,Host=S.RSUI,S.UIV3Design,S.UIV3 and S.UIV3.PageHost
if not F or not RSUI or not D or not Host then return end
local function Build(parent,route)
    local root,err=D:ScrollablePageRoot(parent,{id="v3_page_facing_indicator",gap=7,padding=2})
    if not root then return nil,err end
    root.route=route
    D:PageHeader(root,"v3_facing_header","正面／背面指示器","目标脚下：红色正面、绿色背面，随目标移动和转身更新。")
    local fields,status={},nil
    local ready,loadErr=F:Initialize()
    if ready~=true then
        RSUI:Text({id="v3_facing_protected",parent=root,text="配置受保护："..tostring(loadErr),tone="warn",overflow="wrap",slot={size="auto",minHeight=48,hAlign="fill"}})
        return root
    end
    local function Result(ok,actionErr)
        if status then status:SetText(ok==true and "设置已保存" or "操作失败："..tostring(actionErr)) end
        if root.Refresh then root:Refresh() end
        return ok,actionErr
    end
    local toggle=D:ModuleToggleButton({id="v3_facing_toggle",parent=root,text="启用功能",compact=true,
        slot={size="auto",minHeight=30,hAlign="left"},onClick=function()
            local enabled=S.FeatureRuntime:IsEnabled(F.Id)~=true
            return Result(S.FeatureRuntime:SetPreferredEnabled(F.Id,enabled,"facing_indicator_page_toggle"))
        end})
    RSUI:Text({id="v3_facing_hint",parent=root,text="只标记当前选中目标。缺少朝向、目标消失或位于镜头后方时隐藏。弧线是方向提示，弧长不代表技能背击判定范围。",
        fontSize=10,tone="muted",overflow="wrap",slot={size="auto",minHeight=42,hAlign="fill"}})
    -- 中文维护：两侧开关复用 RSUI Toggle/get/set；只提交 Feature Commands，编辑设置不启动总功能。
    -- 明确保存的 false 必须在 Render 中由 Feature 投影回显，不能靠控件自己的临时布尔状态。
    local sides=RSUI:UniformGrid({id="v3_facing_sides",parent=root,minCellWidth=145,minCellHeight=30,maxColumns=2,gap=7,
        slot={size="auto",minHeight=30,hAlign="fill"}})
    for _,side in ipairs({{key="front",setting="showFront",label="正面"},{key="back",setting="showBack",label="背面"}})do
        local key,setting,label=side.key,side.setting,side.label
        local field,fieldErr=RSUI:Toggle({id="v3_facing_"..key,parent=sides,onText=label.."：显示",offText=label.."：隐藏",height=28,
            get=function()return F:GetProjection().settings[setting]==true end,
            set=function(value)return Result(F.Commands:SetSideEnabled(key,value))end,slot={size="fill",fill=1,hAlign="fill"}})
        if not field then return nil,"正背面开关创建失败："..tostring(fieldErr or key) end
        fields[#fields+1]=field
    end
    RSUI:Text({id="v3_facing_sides_hint",parent=root,text="正面与背面可单独显示。两侧都隐藏时暂停采样，功能总开关保持原状态。",
        fontSize=10,tone="muted",overflow="wrap",slot={size="auto",minHeight=26,hAlign="fill"}})
    local grid=RSUI:UniformGrid({id="v3_facing_settings",parent=root,minCellWidth=290,minCellHeight=44,maxColumns=2,gap=7,
        slot={size="auto",minHeight=132,hAlign="fill"}})
    local specs={
        {key="radius",label="显示半径",step=0.5,unit="m"},
        {key="arcDegrees",label="每侧弧长",step=5,unit="°",integer=true},
        {key="pointSize",label="点大小",step=1,integer=true},
        {key="opacity",label="透明度",step=0.05},
        {key="angleOffset",label="朝向校准",step=5,unit="°",integer=true},
    }
    for _,spec in ipairs(specs) do
        local key=spec.key
        local field=D:CompactNumericSetting(grid,{id="v3_facing_"..key,label=spec.label,min=F.Limits[key][1],max=F.Limits[key][2],
            hardMin=F.Limits[key][1],hardMax=F.Limits[key][2],fixedRange=true,step=spec.step,integer=spec.integer==true,unit=spec.unit,
            labelWidth=74,inputWidth=62,slider=true,stepButtons=false,
            get=function()return F:GetProjection().settings[key]end,
            set=function(value)return Result(F.Commands:SetValue(key,value))end,
            slot={size="fill",fill=1,hAlign="fill"}})
        if not field then return nil,"正背面数值控件创建失败："..key end
        fields[#fields+1]=field
    end
    RSUI:Text({id="v3_facing_calibration_hint",parent=root,text="朝向校准默认 0°。实机若发现前后相反，设为 180°；如果偏向侧面，可用 ±90°核对。半径按目标体型手动调整。",
        fontSize=10,tone="muted",overflow="wrap",slot={size="auto",minHeight=42,hAlign="fill"}})
    status=RSUI:Text({id="v3_facing_status",parent=root,text="设置可在功能关闭时保存。",fontSize=10,tone="muted",overflow="wrap",slot={size="auto",minHeight=24,hAlign="fill"}})
    function root:Refresh()
        if toggle then toggle:SetText(S.FeatureRuntime:IsEnabled(F.Id) and "关闭功能" or "启用功能") end
        for _,field in ipairs(fields) do if type(field.Render)=="function" then field:Render() end end
        return true
    end
    local generation=S.Generation
    function root:OnActivated()
        if self._active then return self:Refresh() end
        self._active=true
        if not S.Events then self._active=false;return false,"页面事件不可用" end
        local updated=S.Events:SubscribeInternal(F.UpdateTopic,self,function(_,_,reason)
            -- 中文维护：只在显式配置提交后刷新字段，visual_tick/target_changed 不能覆盖编辑草稿。
            if root._active and S.Generation==generation and reason=="settings_changed" then root:Refresh() end
        end)
        local lifecycle=S.Events:SubscribeInternal(S.FeatureRuntime.LifecycleTopic or "v3.feature.lifecycle",self,function(_,id)
            if root._active and S.Generation==generation and id==F.Id then root:Refresh() end
        end)
        if not updated or not lifecycle then self:OnDeactivated();return false,"页面事件订阅失败" end
        return self:Refresh()
    end
    function root:OnDeactivated()
        self._active=false
        if S.Events then S.Events:UnsubscribeInternalOwner(self) end
        return true
    end
    local release=root.Release
    function root:Release()self:OnDeactivated();if release then return release(self) end;return true end
    return root
end
local ok,err=Host:RegisterFactory("combat.facing_indicator",Build)
if ok~=true then error(err) end
