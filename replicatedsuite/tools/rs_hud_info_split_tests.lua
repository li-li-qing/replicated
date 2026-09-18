-- 中文维护注释（hud-info-split-1）：不加载 Native；校准入口必须把职业名称、装备分数、距离
-- 暴露为独立文字几何控制，同时职业图标继续保持独立组件。Store schema 不应因纯表现拆分升级。
local function Read(path)
    local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s
end
local cal=Read('presentation/v3/widgets/rs_v3_buff_hud_calibration.lua')
local store=Read('features/combat/buff_display/rs_buff_display_store.lua')
assert(cal:find('key="info",     label="职业名称"',1,true),'职业名称仍标成基础信息')
assert(cal:find('key="gearScore",label="装备分数"',1,true),'装备分数没有独立校准项')
assert(cal:find('key="distance", label="距离"',1,true),'距离没有独立校准项')
assert(cal:find('gearScore = { x=true,y=true,font=true,scale=true,alpha=true }',1,true),'装备分数缺文字字段')
assert(cal:find('distance  = { x=true,y=true,font=true,scale=true,alpha=true }',1,true),'距离缺文字字段')
assert(store:find('local SCHEMA = 8',1,true),'当前 Store 应为 schema8；装备分数格式必须继续保留')
print('HUD_INFO_SPLIT_RESULT passed=6 failed=0')
