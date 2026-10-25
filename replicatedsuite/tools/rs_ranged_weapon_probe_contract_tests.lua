-- Replicated Suite · 远程武器探测契约测试
-- 作者：Replicated
-- QQ群：1104129461
-- 状态诊断必须提供独立于 Buff 字段探测的显式装备探测。
-- 完整 BuffDisplay 依赖实时运行环境，因此源码契约仅验证公开命令和 UI 连接，以及槽位、类型和 false/true tooltip 两组证据完整。
local feature=assert(io.open('features/combat/buff_display/rs_buff_display_feature.lua','r')):read('*a')
local window=assert(io.open('presentation/v3/widgets/rs_v3_module_diagnostics_window.lua','r')):read('*a')
local page=assert(io.open('presentation/v3/pages/rs_v3_buff_display_page.lua','r')):read('*a')
local store=assert(io.open('features/combat/buff_display/rs_buff_display_store.lua','r')):read('*a')
assert(feature:find('ProbeEquipmentFields',1,true),'missing explicit equipment probe command')
assert(feature:find('GetEquippedItemType',1,true),'equipment probe must read slot type')
assert(feature:find('targetEquippedItem=false',1,true) or feature:find('falseTooltip',1,true),'equipment probe missing self-tooltip evidence')
assert(feature:find('targetEquippedItem=true',1,true) or feature:find('trueTooltip',1,true),'equipment probe missing comparison evidence')
assert(window:find('装备探测',1,true),'module diagnostics missing equipment-probe button')
assert(window:find('Buff字段',1,true),'ambiguous generic field-probe label was not clarified')
-- 显示内容页按真实读模型生成开关，核对远程定义、显示/隐藏文案和持久化命令接线。
-- 不再要求已删除的专用“开/关”按钮；任一环节丢失都应继续失败。
assert(store:find('{key="ranged",label="远程武器",kind="image",component="ranged"}',1,true),'ranged visibility definition missing')
assert(page:find('Feature.Commands:GetHudVisibilityProjection("target")',1,true),'HUD page does not read visibility definitions')
assert(page:find('for _,definition in ipairs(type(initialSnapshot)=="table" and initialSnapshot.items or {})',1,true),'HUD visibility definitions are not rendered')
assert(page:find('id="v3_buff_visibility_"..key',1,true) and page:find('onText=definition.label.."：显示",offText=definition.label.."：隐藏"',1,true),'HUD visibility state is not exposed')
assert(page:find('Feature.Commands:SetHudVisibility(root.visibilityScope,key,value==true)',1,true) and page:find('set=function(value) return ApplyVisibility(key,value) end',1,true),'visibility toggle no longer commits through the Feature command')
print('PASS ranged equipment diagnostic/toggle contract')
