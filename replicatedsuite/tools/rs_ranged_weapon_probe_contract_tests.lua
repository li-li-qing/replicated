-- Regression: status diagnostics need an explicit equipment probe separate from Buff-field probing.
-- This source-level contract is intentionally narrow because the full BuffDisplay feature requires the live runtime;
-- it verifies the public command/UI wiring and that slot/type/false+true tooltip evidence are all present.
local feature=assert(io.open('features/combat/buff_display/rs_buff_display_feature.lua','r')):read('*a')
local window=assert(io.open('presentation/v3/widgets/rs_v3_module_diagnostics_window.lua','r')):read('*a')
local page=assert(io.open('presentation/v3/pages/rs_v3_buff_display_page.lua','r')):read('*a')
assert(feature:find('ProbeEquipmentFields',1,true),'missing explicit equipment probe command')
assert(feature:find('GetEquippedItemType',1,true),'equipment probe must read slot type')
assert(feature:find('targetEquippedItem=false',1,true) or feature:find('falseTooltip',1,true),'equipment probe missing self-tooltip evidence')
assert(feature:find('targetEquippedItem=true',1,true) or feature:find('trueTooltip',1,true),'equipment probe missing comparison evidence')
assert(window:find('装备探测',1,true),'module diagnostics missing equipment-probe button')
assert(window:find('Buff字段',1,true),'ambiguous generic field-probe label was not clarified')
assert(page:find('远程武器：开',1,true) and page:find('远程武器：关',1,true),'main HUD page does not expose ranged visibility state')
print('PASS ranged equipment diagnostic/toggle contract')
