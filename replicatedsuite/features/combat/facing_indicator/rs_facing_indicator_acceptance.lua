-- 中文维护（2026-10-09）：新 Feature 的只读运行期契约归属本模块，不把业务判断塞入 Core。
-- 自检只能检查已经注册的对象/方法，不读取目标、不领取租约、不写配置或创建 UI。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
if not S.FoundationGate or type(S.FoundationGate.RegisterSequenceCase)~="function" then return end
S.FoundationGate:RegisterSequenceCase("v3_facing_indicator_contract",function()
    local feature=S.Features and S.Features.combat_facing_indicator
    local pose=S.Services and S.Services.ScreenProjectionV3
    local presenter=S.UIV3 and S.UIV3.FacingIndicatorV3
    local page=S.UIV3 and S.UIV3.PageHost
    -- 中文维护：只核对新增的独立侧开关契约，不为自检更改开关或读取当前目标。
    if not feature or feature.FacingIndicatorContractVersion~=2 or not feature.Demand
        or not feature.Commands or type(feature.Commands.SetValue)~="function" or type(feature.Commands.SetSideEnabled)~="function"
        or type(feature.GetSideVisibility)~="function" then return false,"facing_feature_unavailable" end
    if not pose or type(pose.GetUnitPose)~="function" then return false,"facing_pose_unavailable" end
    if not presenter or type(presenter.Reconcile)~="function" then return false,"facing_presenter_unavailable" end
    if not page or not page.factories or type(page.factories["combat.facing_indicator"])~="function" then return false,"facing_page_unavailable" end
    return true
end,{runtime=true})
