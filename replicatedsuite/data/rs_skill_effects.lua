if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Data = S.Data or {}

--[[ Skill -> Buff/Debuff effect library (Replicated Suite 1.1, v3 2026-08-25)
-- 本版本 (v3) = 仅保留「准确」数据，推断项已全部清空，待游戏内实测补全。
--
-- 【准确数据】来源: wiki.archerage.to/ru-cn 技能库 (已逐页核对)
--   * 技能 ID + 中文名
--   * 每个技能「直接施加」的 buff/debuff 的 ID + 中文名 (取自该 buff 自身页面, 权威)
--   * buff 索引: ID + 中文名
--
-- 【已清空 / 待游戏内补全】(wiki 不区分 Buff/Debuff, 也无连锁 ID, 无法自动获取):
--   * kind  (buff / debuff): 当前全部为 "unknown", 需进游戏确认后填入
--   * target(self / enemy): 当前全部为 "unknown", 需进游戏确认后填入
--   * 连锁反应 (A 触发 B): wiki 无结构化数据, 需游戏内记录后补 chains 字段
--
-- Schema:
--   S.Data.SkillEffects.trees[slug] = {
--     name_cn = "中文天赋名",
--     skills = { [skillId] = { name="技能名", effects={ {buffId,name,target,kind}, ... } } }
--   }
--   S.Data.SkillEffects.buffs[buffId] = { name="buff名", kind="unknown" }
--
--   已知缺口: 欢乐(joy, 计算器 key 14) 在 wiki 无对应技能库页, 保留空结构待补。
--]]
S.Data.SkillEffects = {
    version = 3,
    trees = {},
    buffs = {},
}

do
    local B = S.Data.SkillEffects.buffs
    B[21] = { name = "倒地", kind = "unknown" }
    B[82] = { name = "大地之手", kind = "unknown" }
    B[87] = { name = "地狱长枪", kind = "unknown" }
    B[94] = { name = "冰冻碎片", kind = "unknown" }
    B[96] = { name = "水之禁锢", kind = "unknown" }
    B[101] = { name = "精神震击", kind = "unknown" }
    B[114] = { name = "催眠术", kind = "unknown" }
    B[127] = { name = "意志高昂", kind = "unknown" }
    B[156] = { name = "恐惧", kind = "unknown" }
    B[171] = { name = "挑衅", kind = "unknown" }
    B[182] = { name = "狂暴（1阶段）", kind = "unknown" }
    B[196] = { name = "毒", kind = "unknown" }
    B[206] = { name = "物理技能封印", kind = "unknown" }
    B[220] = { name = "生机泉涌", kind = "unknown" }
    B[242] = { name = "流血（1级）", kind = "unknown" }
    B[243] = { name = "眩晕", kind = "unknown" }
    B[245] = { name = "沉默", kind = "unknown" }
    B[247] = { name = "冻伤", kind = "unknown" }
    B[250] = { name = "触电", kind = "unknown" }
    B[256] = { name = "风神之怒", kind = "unknown" }
    B[266] = { name = "沉默", kind = "unknown" }
    B[328] = { name = "防御壁垒（1级）", kind = "unknown" }
    B[329] = { name = "防御壁垒（2级）", kind = "unknown" }
    B[330] = { name = "防御壁垒（3级）", kind = "unknown" }
    B[340] = { name = "疾风步（1级）", kind = "unknown" }
    B[404] = { name = "战神之刃（1级）", kind = "unknown" }
    B[425] = { name = "妨碍施法", kind = "unknown" }
    B[431] = { name = "霜冻之径", kind = "unknown" }
    B[439] = { name = "审判之枪", kind = "unknown" }
    B[445] = { name = "沸腾之血（1级）", kind = "unknown" }
    B[446] = { name = "沸腾之血（2级）", kind = "unknown" }
    B[447] = { name = "沸腾之血（3级）", kind = "unknown" }
    B[448] = { name = "沸腾之血（4级）", kind = "unknown" }
    B[449] = { name = "精神反噬", kind = "unknown" }
    B[451] = { name = "雄鹰之力（1级）", kind = "unknown" }
    B[452] = { name = "雄鹰之力（2级）", kind = "unknown" }
    B[453] = { name = "雄鹰之力（3级）", kind = "unknown" }
    B[454] = { name = "雄鹰之力（4级）", kind = "unknown" }
    B[467] = { name = "诅咒", kind = "unknown" }
    B[470] = { name = "乌鸦袭击", kind = "unknown" }
    B[499] = { name = "心灵专注", kind = "unknown" }
    B[502] = { name = "强力挑衅", kind = "unknown" }
    B[505] = { name = "倒地", kind = "unknown" }
    B[514] = { name = "流血（2级）", kind = "unknown" }
    B[515] = { name = "流血（3级）", kind = "unknown" }
    B[516] = { name = "流血（4级）", kind = "unknown" }
    B[517] = { name = "流血（5级）", kind = "unknown" }
    B[542] = { name = "黑暗之拥（1级）", kind = "unknown" }
    B[552] = { name = "祝福", kind = "unknown" }
    B[554] = { name = "复活（3级）", kind = "unknown" }
    B[555] = { name = "复活（4级）", kind = "unknown" }
    B[556] = { name = "复活（2级）", kind = "unknown" }
    B[599] = { name = "隐身（1级）", kind = "unknown" }
    B[600] = { name = "隐身（2级）", kind = "unknown" }
    B[601] = { name = "隐身（3级）", kind = "unknown" }
    B[656] = { name = "轻舞乐章（1级）", kind = "unknown" }
    B[657] = { name = "轻舞乐章（2级）", kind = "unknown" }
    B[658] = { name = "轻舞乐章（3级）", kind = "unknown" }
    B[659] = { name = "轻舞乐章（4级）", kind = "unknown" }
    B[660] = { name = "轻舞乐章（5级）", kind = "unknown" }
    B[662] = { name = "生命乐章（1级）", kind = "unknown" }
    B[663] = { name = "生命乐章（3级）", kind = "unknown" }
    B[664] = { name = "生命乐章（2级）", kind = "unknown" }
    B[667] = { name = "英雄进行曲（1级）", kind = "unknown" }
    B[745] = { name = "魔力护盾（1级）", kind = "unknown" }
    B[770] = { name = "僵直", kind = "unknown" }
    B[778] = { name = "大地赞歌（1级）", kind = "unknown" }
    B[794] = { name = "脉轮之息（1级）", kind = "unknown" }
    B[795] = { name = "脉轮之息（2级）", kind = "unknown" }
    B[796] = { name = "脉轮之息（3级）", kind = "unknown" }
    B[828] = { name = "深度破胆", kind = "unknown" }
    B[854] = { name = "魔力护盾（2级）", kind = "unknown" }
    B[855] = { name = "魔力护盾（3级）", kind = "unknown" }
    B[856] = { name = "魔力护盾（4级）", kind = "unknown" }
    B[857] = { name = "魔力护盾（5级）", kind = "unknown" }
    B[877] = { name = "살기 충격", kind = "unknown" }
    B[883] = { name = "束缚", kind = "unknown" }
    B[886] = { name = "猎手印记（1级）", kind = "unknown" }
    B[922] = { name = "触电", kind = "unknown" }
    B[975] = { name = "惊悚尖啸", kind = "unknown" }
    B[1225] = { name = "威胁减少", kind = "unknown" }
    B[1248] = { name = "魔法阵（1级）", kind = "unknown" }
    B[1249] = { name = "魔法阵（2级）", kind = "unknown" }
    B[1366] = { name = "达忽塔之息", kind = "unknown" }
    B[1403] = { name = "着火", kind = "unknown" }
    B[1449] = { name = "僵直", kind = "unknown" }
    B[1763] = { name = "杀气冲击", kind = "unknown" }
    B[1987] = { name = "火焰缠身", kind = "unknown" }
    B[2169] = { name = "负面情绪（轻舞乐章）", kind = "unknown" }
    B[2174] = { name = "衰弱气息（生命乐章）", kind = "unknown" }
    B[2176] = { name = "无力之息（英雄进行曲）", kind = "unknown" }
    B[2177] = { name = "掉以轻心(大地赞歌)", kind = "unknown" }
    B[2183] = { name = "轻舞乐章（1级）", kind = "unknown" }
    B[2184] = { name = "轻舞乐章（2级）", kind = "unknown" }
    B[2185] = { name = "轻舞乐章（3级）", kind = "unknown" }
    B[2186] = { name = "轻舞乐章（4级）", kind = "unknown" }
    B[2187] = { name = "轻舞乐章（5级）", kind = "unknown" }
    B[2188] = { name = "负面情绪（轻舞乐章）", kind = "unknown" }
    B[2190] = { name = "生命乐章（1级）", kind = "unknown" }
    B[2191] = { name = "生命乐章（2级）", kind = "unknown" }
    B[2192] = { name = "生命乐章（3级）", kind = "unknown" }
    B[2193] = { name = "衰弱气息（生命乐章）", kind = "unknown" }
    B[2196] = { name = "英雄进行曲（1级）", kind = "unknown" }
    B[2197] = { name = "无力之息（英雄进行曲）", kind = "unknown" }
    B[2199] = { name = "大地赞歌（1级）", kind = "unknown" }
    B[2200] = { name = "掉以轻心(大地赞歌)", kind = "unknown" }
    B[2206] = { name = "魔法防御（1级）", kind = "unknown" }
    B[2207] = { name = "魔法防御（2级）", kind = "unknown" }
    B[2208] = { name = "魔法防御（3级）", kind = "unknown" }
    B[2214] = { name = "视力模糊", kind = "unknown" }
    B[2275] = { name = "催眠术", kind = "unknown" }
    B[2277] = { name = "恐惧", kind = "unknown" }
    B[2278] = { name = "惊悚尖啸", kind = "unknown" }
    B[2279] = { name = "冻结", kind = "unknown" }
    B[2286] = { name = "水之禁锢", kind = "unknown" }
    B[2287] = { name = "猛烈灼烧", kind = "unknown" }
    B[2445] = { name = "猎手印记（2级）", kind = "unknown" }
    B[2446] = { name = "猎手印记（3级）", kind = "unknown" }
    B[2624] = { name = "破甲之力", kind = "unknown" }
    B[2723] = { name = "减速", kind = "unknown" }
    B[2727] = { name = "后空翻", kind = "unknown" }
    B[2763] = { name = "破胆（1级）", kind = "unknown" }
    B[2765] = { name = "破胆（2级）", kind = "unknown" }
    B[2766] = { name = "破胆（3级）", kind = "unknown" }
    B[2767] = { name = "破胆（4级）", kind = "unknown" }
    B[2768] = { name = "破胆（5级）", kind = "unknown" }
    B[2921] = { name = "死亡刻印", kind = "unknown" }
    B[2923] = { name = "复仇刃铠", kind = "unknown" }
    B[2924] = { name = "复仇刃铠（2级）", kind = "unknown" }
    B[2956] = { name = "睿明祝福（2级）", kind = "unknown" }
    B[3127] = { name = "眩晕", kind = "unknown" }
    B[3200] = { name = "진공 당겨짐", kind = "unknown" }
    B[3532] = { name = "冲击盾：增加威胁", kind = "unknown" }
    B[3533] = { name = "春生之种（1级）", kind = "unknown" }
    B[3655] = { name = "光辉祷言", kind = "unknown" }
    B[3717] = { name = "移动速度增加", kind = "unknown" }
    B[3719] = { name = "束缚", kind = "unknown" }
    B[3761] = { name = "破胆", kind = "unknown" }
    B[3819] = { name = "懦弱（1级）", kind = "unknown" }
    B[3823] = { name = "懦弱（2级）", kind = "unknown" }
    B[3824] = { name = "懦弱（3级）", kind = "unknown" }
    B[3825] = { name = "坚韧（1级）", kind = "unknown" }
    B[3826] = { name = "坚韧（2级）", kind = "unknown" }
    B[3827] = { name = "坚韧（3级）", kind = "unknown" }
    B[3842] = { name = "연출용 느려짐", kind = "unknown" }
    B[4252] = { name = "黑暗之拥", kind = "unknown" }
    B[4386] = { name = "大地赞歌（2级）", kind = "unknown" }
    B[4387] = { name = "大地赞歌（2级）", kind = "unknown" }
    B[4677] = { name = "활력 칼날 데미지 증가", kind = "unknown" }
    B[5278] = { name = "隐身（1级）", kind = "unknown" }
    B[5279] = { name = "隐身（2级）", kind = "unknown" }
    B[5280] = { name = "隐身（3级）", kind = "unknown" }
    B[6961] = { name = "炽火凋零", kind = "unknown" }
    B[7010] = { name = "镜之分身", kind = "unknown" }
    B[7543] = { name = "鲁莽突进", kind = "unknown" }
    B[7649] = { name = "懦弱（4级）", kind = "unknown" }
    B[7650] = { name = "坚韧（4级）", kind = "unknown" }
    B[7651] = { name = "战神之刃（2级）", kind = "unknown" }
    B[7654] = { name = "破胆（6级）", kind = "unknown" }
    B[7655] = { name = "脉轮之息（4级）", kind = "unknown" }
    B[7657] = { name = "黑暗之拥（2级）", kind = "unknown" }
    B[7658] = { name = "雄鹰之力（5级）", kind = "unknown" }
    B[7659] = { name = "猎手印记（4级）", kind = "unknown" }
    B[7660] = { name = "复活（5级）", kind = "unknown" }
    B[7661] = { name = "睿明祝福（3级）", kind = "unknown" }
    B[7662] = { name = "英雄进行曲（2级）", kind = "unknown" }
    B[7664] = { name = "英雄进行曲（2级）", kind = "unknown" }
    B[8075] = { name = "魔法阵（3级）", kind = "unknown" }
    B[8224] = { name = "隐身（4级）", kind = "unknown" }
    B[8225] = { name = "隐身（4级）", kind = "unknown" }
    B[13605] = { name = "坚韧（5级）", kind = "unknown" }
    B[13606] = { name = "懦弱（5级）", kind = "unknown" }
    B[13610] = { name = "坚韧（6级）", kind = "unknown" }
    B[13611] = { name = "懦弱（6级）", kind = "unknown" }
    B[13612] = { name = "战神之刃（3级）", kind = "unknown" }
    B[13613] = { name = "战神之刃（4级）", kind = "unknown" }
    B[13616] = { name = "防御壁垒（4级）", kind = "unknown" }
    B[13617] = { name = "防御壁垒（5级）", kind = "unknown" }
    B[13618] = { name = "魔法防御（4级）", kind = "unknown" }
    B[13619] = { name = "魔法防御（5级）", kind = "unknown" }
    B[13627] = { name = "沸腾之血（5级）", kind = "unknown" }
    B[13628] = { name = "沸腾之血（6级）", kind = "unknown" }
    B[13769] = { name = "破胆（7级）", kind = "unknown" }
    B[13770] = { name = "破胆（8级）", kind = "unknown" }
    B[13775] = { name = "魔法阵（4级）", kind = "unknown" }
    B[13776] = { name = "魔法阵（5级）", kind = "unknown" }
    B[13777] = { name = "猎手印记（5级）", kind = "unknown" }
    B[13778] = { name = "猎手印记（6级）", kind = "unknown" }
    B[13779] = { name = "疾风步（2级）", kind = "unknown" }
    B[13780] = { name = "疾风步（3级）", kind = "unknown" }
    B[13781] = { name = "疾风步（4级）", kind = "unknown" }
    B[13785] = { name = "生命乐章（5级）", kind = "unknown" }
    B[13786] = { name = "生命乐章（4级）", kind = "unknown" }
    B[13787] = { name = "生命乐章（4级）", kind = "unknown" }
    B[13788] = { name = "生命乐章（5级）", kind = "unknown" }
    B[13790] = { name = "睿明祝福（4级）", kind = "unknown" }
    B[13791] = { name = "睿明祝福（5级）", kind = "unknown" }
    B[13867] = { name = "脉轮之息（5级）", kind = "unknown" }
    B[13868] = { name = "脉轮之息（6级）", kind = "unknown" }
    B[14861] = { name = "腾空之力", kind = "unknown" }
    B[15024] = { name = "魔力源泉", kind = "unknown" }
    B[15053] = { name = "祈祷", kind = "unknown" }
    B[16576] = { name = "暴露弱点", kind = "unknown" }
    B[16870] = { name = "魔力魔法盾", kind = "unknown" }
    B[17205] = { name = "Manage Rhythm Overlap", kind = "unknown" }
    B[17207] = { name = "Manage Rhythm Overlap", kind = "unknown" }
    B[17339] = { name = "Infuse", kind = "unknown" }
    B[17417] = { name = "生机泉涌", kind = "unknown" }
    B[17925] = { name = "春生之种", kind = "unknown" }
    B[18136] = { name = "Root", kind = "unknown" }
    B[18146] = { name = "减少物理防御", kind = "unknown" }
    B[18147] = { name = "减速", kind = "unknown" }
    B[18341] = { name = "诅咒的种子", kind = "unknown" }
    B[18344] = { name = "血魄地狱", kind = "unknown" }
    B[18380] = { name = "地狱长枪", kind = "unknown" }
    B[18390] = { name = "心脉连击：正在使用闪电", kind = "unknown" }
    B[18396] = { name = "审判之枪", kind = "unknown" }
    B[18420] = { name = "审判之枪", kind = "unknown" }
    B[18449] = { name = "Mana Bolts Move Speed Boost", kind = "unknown" }
    B[19979] = { name = "裂空星陨", kind = "unknown" }
    B[20018] = { name = "执念", kind = "unknown" }
    B[20019] = { name = "Meteor Impact", kind = "unknown" }
    B[20933] = { name = "懦弱", kind = "unknown" }
    B[20936] = { name = "炽火凋零", kind = "unknown" }
    B[21154] = { name = "276599 DO NOT TRANSLATE", kind = "unknown" }
    B[21372] = { name = "防御壁垒：绿叶", kind = "unknown" }
    B[21374] = { name = "威慑气势：磐石（6级）", kind = "unknown" }
    B[21375] = { name = "魔力护盾：烈焰（5阶段）", kind = "unknown" }
    B[21376] = { name = "后空翻：波涛", kind = "unknown" }
    B[21397] = { name = "大地之手", kind = "unknown" }
    B[21398] = { name = "大地之手", kind = "unknown" }
    B[21399] = { name = "水之禁锢", kind = "unknown" }
    B[21400] = { name = "水之禁锢", kind = "unknown" }
    B[21402] = { name = "惊悚尖啸", kind = "unknown" }
    B[21403] = { name = "惊悚尖啸", kind = "unknown" }
    B[21406] = { name = "防御壁垒：暴风", kind = "unknown" }
    B[21407] = { name = "防御壁垒：暴风", kind = "unknown" }
    B[21416] = { name = "魔力护盾（5级）", kind = "unknown" }
    B[21433] = { name = "陶醉", kind = "unknown" }
    B[21434] = { name = "魅惑", kind = "unknown" }
    B[21437] = { name = "清晨号角：绿叶", kind = "unknown" }
    B[21475] = { name = "威慑气势：磐石（7级）", kind = "unknown" }
    B[21557] = { name = "触电", kind = "unknown" }
    B[21960] = { name = "格挡精通", kind = "unknown" }
    B[21976] = { name = "沸腾之血（7级）", kind = "unknown" }
    B[21977] = { name = "前往黄泉", kind = "unknown" }
    B[21988] = { name = "风神之怒（2阶段）", kind = "unknown" }
    B[21989] = { name = "风神之怒（3阶段）", kind = "unknown" }
    B[21990] = { name = "冻结", kind = "unknown" }
    B[21993] = { name = "追击", kind = "unknown" }
    B[22013] = { name = "沉默", kind = "unknown" }
    B[22039] = { name = "血魄地狱", kind = "unknown" }
    B[22060] = { name = "意志高昂：迷雾", kind = "unknown" }
    B[22265] = { name = "死亡刻印", kind = "unknown" }
    B[22266] = { name = "抹毒", kind = "unknown" }
    B[22532] = { name = "眩晕", kind = "unknown" }
    B[22548] = { name = "刺", kind = "unknown" }
    B[22627] = { name = "束缚", kind = "unknown" }
    B[22689] = { name = "狂暴（3阶段）", kind = "unknown" }
    B[22690] = { name = "狂暴（2阶段）", kind = "unknown" }
    B[22909] = { name = "精神震击连锁", kind = "unknown" }
    B[22958] = { name = "蛇之眼", kind = "unknown" }
    B[22964] = { name = "死神", kind = "unknown" }
    B[22975] = { name = "恶魔之剑", kind = "unknown" }
    B[22980] = { name = "死神", kind = "unknown" }
    B[22981] = { name = "死神", kind = "unknown" }
    B[22982] = { name = "愤怒", kind = "unknown" }
    B[22995] = { name = "恶魔的傀儡", kind = "unknown" }
    B[23052] = { name = "552938 DO NOT TRANSLATE", kind = "unknown" }
    B[23134] = { name = "镜之分身：烈焰", kind = "unknown" }
    B[23135] = { name = "镜之分身：磐石", kind = "unknown" }
    B[23146] = { name = "疾风步：烈焰", kind = "unknown" }
    B[23150] = { name = "追击：烈焰", kind = "unknown" }
    B[23151] = { name = "追击：波涛", kind = "unknown" }
    B[23152] = { name = "追击：波涛", kind = "unknown" }
    B[23153] = { name = "追击：波涛", kind = "unknown" }
    B[23154] = { name = "追击：波涛", kind = "unknown" }
    B[23155] = { name = "追击：波涛", kind = "unknown" }
    B[23180] = { name = "疾风步：地哮", kind = "unknown" }
    B[23275] = { name = "범죄 버프", kind = "unknown" }
    B[23347] = { name = "净化", kind = "unknown" }
    B[23353] = { name = "解除装备（乐器）", kind = "unknown" }
    B[23361] = { name = "地狱长枪：烈焰", kind = "unknown" }
    B[23523] = { name = "沉默", kind = "unknown" }
    B[23524] = { name = "沉默", kind = "unknown" }
    B[23956] = { name = "枪刺", kind = "unknown" }
    B[23958] = { name = "眩晕", kind = "unknown" }
    B[23959] = { name = "睡眠", kind = "unknown" }
    B[23962] = { name = "减速", kind = "unknown" }
    B[24001] = { name = "步履轻盈", kind = "unknown" }
    B[24066] = { name = "复仇刃铠：迷雾", kind = "unknown" }
    B[24071] = { name = "复仇刃铠：烈焰", kind = "unknown" }
    B[24093] = { name = "抹毒：烈焰", kind = "unknown" }
    B[24235] = { name = "抹毒：波涛", kind = "unknown" }
    B[24239] = { name = "조준 사격 느려짐", kind = "unknown" }
    B[24543] = { name = "无法使用药水", kind = "unknown" }
    B[24544] = { name = "无法使用滑翔翼（翅膀）", kind = "unknown" }
    B[24583] = { name = "火之印记", kind = "unknown" }
    B[24586] = { name = "冻伤", kind = "unknown" }
    B[24610] = { name = "突袭", kind = "unknown" }
    B[24633] = { name = "减速", kind = "unknown" }
    B[24634] = { name = "束缚", kind = "unknown" }
    B[24641] = { name = "그림자 장막", kind = "unknown" }
    B[24748] = { name = "New Ability Main Body 2 Immunity", kind = "unknown" }
    B[24758] = { name = "신규 능력 이동기2 복제", kind = "unknown" }
    B[24764] = { name = "신규 능력 딜링기4 복제", kind = "unknown" }
    B[24765] = { name = "신규 능력 버프1 복제", kind = "unknown" }
    B[24767] = { name = "신규 능력 버프2 복제", kind = "unknown" }
    B[24768] = { name = "신규 능력 디버프 복제", kind = "unknown" }
    B[24947] = { name = "突袭", kind = "unknown" }
    B[24953] = { name = "伊尔克的剑舞", kind = "unknown" }
    B[24980] = { name = "免疫影之镜像", kind = "unknown" }
    B[24986] = { name = "贴身保护", kind = "unknown" }
    B[24987] = { name = "复苏喘息", kind = "unknown" }
    B[25391] = { name = "雄鹰之力：烈焰", kind = "unknown" }
    B[25401] = { name = "复苏喘息：生命", kind = "unknown" }
    B[25402] = { name = "复苏喘息：波涛", kind = "unknown" }
    B[25646] = { name = "魔法阵（地哮）", kind = "unknown" }
    B[25647] = { name = "魔法阵（烈焰）", kind = "unknown" }
    B[25650] = { name = "狂暴：波涛", kind = "unknown" }
    B[25651] = { name = "狂暴：烈焰", kind = "unknown" }
    B[25694] = { name = "突袭隐身", kind = "unknown" }
    B[25980] = { name = "狂暴的后遗症", kind = "unknown" }
    B[26075] = { name = "전율하는 매(연출)", kind = "unknown" }
    B[26116] = { name = "칼날 심판:파도 복제", kind = "unknown" }
    B[26453] = { name = "精神震击连锁", kind = "unknown" }
    B[26454] = { name = "精神震击：暴风", kind = "unknown" }
    B[26471] = { name = "标志", kind = "unknown" }
    B[26472] = { name = "标志", kind = "unknown" }
    B[26932] = { name = "减速", kind = "unknown" }
    B[26958] = { name = "防御壁垒", kind = "unknown" }
    B[26959] = { name = "防御壁垒：绿叶", kind = "unknown" }
    B[26963] = { name = "物理技能封印", kind = "unknown" }
    B[26964] = { name = "眩晕", kind = "unknown" }
    B[26965] = { name = "沉默", kind = "unknown" }
    B[26966] = { name = "破甲之力", kind = "unknown" }
    B[26977] = { name = "恐惧", kind = "unknown" }
    B[27030] = { name = "预告", kind = "unknown" }
    B[27219] = { name = "物理技能封印", kind = "unknown" }
    B[27631] = { name = "倒地", kind = "unknown" }
    B[27632] = { name = "倒地", kind = "unknown" }
    B[27673] = { name = "雄鹰之力：绿叶", kind = "unknown" }
    B[27702] = { name = "移动射击模式", kind = "unknown" }
    B[27824] = { name = "신규 능력 이동기2 복제", kind = "unknown" }
    B[28116] = { name = "潜在力量：防御壁垒", kind = "unknown" }
    B[28118] = { name = "潜在力量：防御壁垒", kind = "unknown" }
    B[28186] = { name = "潜在力量：复苏喘息", kind = "unknown" }
    B[28187] = { name = "潜在力量：魔力护盾", kind = "unknown" }
    B[28188] = { name = "潜在力量：守护之界", kind = "unknown" }
    B[28194] = { name = "潜在力量：诅咒之刺", kind = "unknown" }
    B[28232] = { name = "锋利的尖刺", kind = "unknown" }
    B[28237] = { name = "潜在力量：邪鸦", kind = "unknown" }
    B[28239] = { name = "乌鸦的袭击", kind = "unknown" }
    B[28247] = { name = "潜在力量：恐惧耳语", kind = "unknown" }
    B[28250] = { name = "深渊恐惧", kind = "unknown" }
    B[28252] = { name = "深渊恐惧", kind = "unknown" }
    B[28253] = { name = "潜在力量：水之禁锢", kind = "unknown" }
    B[28256] = { name = "深渊的水之禁锢", kind = "unknown" }
    B[28257] = { name = "深渊的水之禁锢", kind = "unknown" }
    B[28585] = { name = "装填中", kind = "unknown" }
    B[28597] = { name = "移动中", kind = "unknown" }
    B[28671] = { name = "창꽂힘 연쇄 불가", kind = "unknown" }
    B[31536] = { name = "步履轻盈：风暴", kind = "unknown" }
    B[31538] = { name = "가벼운 발놀림: 돌풍 복제", kind = "unknown" }
    B[31543] = { name = "신규 능력 버프1 복제", kind = "unknown" }
    B[31544] = { name = "战栗之鹰：波涛", kind = "unknown" }
    B[31549] = { name = "전율하는 매:파도(연출)", kind = "unknown" }
    B[32646] = { name = "精神震击：奔雷", kind = "unknown" }
    B[32647] = { name = "Hell Spear", kind = "unknown" }
    B[32794] = { name = "전율하는 매: 생명 버프1 복제", kind = "unknown" }
    B[32795] = { name = "战栗之鹰：绿叶", kind = "unknown" }
    B[32796] = { name = "전율하는 매:생명(연출)", kind = "unknown" }
    B[9000157] = { name = "Skill test", kind = "unknown" }
end

do
    -- 游戏内实测补充 (2026-08-25)：用户手动采集的真实 buff ID，已用 wiki 查中文名。
    -- 极性(kind) 暂置 "unknown"：wiki 的 Buff/Debuff 标签极性不可靠（如 5935 骨牢标 Buff 实为定身减益，
    -- 23360/23357 减少受到的治愈量、23216 石化、23642 枪刺、93 冻结 等同理），待用户在游戏内确认
    -- 目标/自身 与 buff/debuff 后填入。导入时仍按名字关键词启发式分列，故部分减益可能暂落在 Buff 列。
    local B = S.Data.SkillEffects.buffs
    B[23360] = { name = "减少受到的治愈量", kind = "unknown" }
    B[16498] = { name = "痛苦折磨", kind = "unknown" }
    B[2361] = { name = "安塔伦的腾空之力", kind = "unknown" }
    B[5935] = { name = "骨牢", kind = "unknown" }
    B[4807] = { name = "乌鸦的干扰", kind = "unknown" }
    B[23358] = { name = "沉默", kind = "unknown" }
    B[18388] = { name = "冤魂诅咒", kind = "unknown" }
    B[23357] = { name = "减少受到的治愈量", kind = "unknown" }
    B[26512] = { name = "痛苦折磨：烈焰", kind = "unknown" }
    B[131] = { name = "钢铁之躯", kind = "unknown" }
    B[23216] = { name = "遗留书库的双手钝器", kind = "unknown" }
    B[22089] = { name = "疾奔", kind = "unknown" }
    B[23642] = { name = "枪刺", kind = "unknown" }
    B[3601] = { name = "眩晕", kind = "unknown" }
    B[22253] = { name = "压倒", kind = "unknown" }
    B[141] = { name = "倒地", kind = "unknown" }
    B[21404] = { name = "恐怖的怪物的叫喊", kind = "unknown" }
    B[2778] = { name = "减速", kind = "unknown" }
    B[2276] = { name = "睡眠", kind = "unknown" }
    B[93] = { name = "冻结", kind = "unknown" }
end

do
    local T = { name_cn = "格斗", skills = {} }
    T.skills[10377] = { name = "战神之刃", effects = {
        { buffId = 404, name = "战神之刃（1级）", target = "unknown", kind = "unknown" },
        { buffId = 7651, name = "战神之刃（2级）", target = "unknown", kind = "unknown" },
        { buffId = 13612, name = "战神之刃（3级）", target = "unknown", kind = "unknown" },
        { buffId = 13613, name = "战神之刃（4级）", target = "unknown", kind = "unknown" },
    } }
    T.skills[10455] = { name = "狂暴", effects = {
        { buffId = 182, name = "狂暴（1阶段）", target = "unknown", kind = "unknown" },
        { buffId = 22690, name = "狂暴（2阶段）", target = "unknown", kind = "unknown" },
        { buffId = 22689, name = "狂暴（3阶段）", target = "unknown", kind = "unknown" },
    } }
    T.skills[10644] = { name = "裂岩斩", effects = {} }
    T.skills[11918] = { name = "突击", effects = {
        { buffId = 22627, name = "束缚", target = "unknown", kind = "unknown" },
        { buffId = 27632, name = "倒地", target = "unknown", kind = "unknown" },
    } }
    T.skills[12026] = { name = "致命打击", effects = {} }
    T.skills[12028] = { name = "突击调用技能", effects = {} }
    T.skills[12034] = { name = "挣脱枷锁", effects = {} }
    T.skills[12786] = { name = "격투_(로그인스테이지)_회오리베기", effects = {} }
    T.skills[12787] = { name = "격투_(로그인스테이지)_올려치기", effects = {} }
    T.skills[12788] = { name = "격투_(로그인스테이지)_결정타", effects = {} }
    T.skills[13282] = { name = "圆月斩", effects = {
        { buffId = 27632, name = "倒地", target = "unknown", kind = "unknown" },
    } }
    T.skills[13315] = { name = "杀戮风暴", effects = {} }
    T.skills[16185] = { name = "破甲之力", effects = {
        { buffId = 2624, name = "破甲之力", target = "unknown", kind = "unknown" },
        { buffId = 26966, name = "破甲之力", target = "unknown", kind = "unknown" },
    } }
    T.skills[18131] = { name = "三连斩", effects = {
        { buffId = 3842, name = "연출용 느려짐", target = "unknown", kind = "unknown" },
        { buffId = 3761, name = "破胆", target = "unknown", kind = "unknown" },
    } }
    T.skills[18132] = { name = "三连斩", effects = {
        { buffId = 26932, name = "减速", target = "unknown", kind = "unknown" },
    } }
    T.skills[18134] = { name = "三连斩", effects = {} }
    T.skills[18308] = { name = "刺耳咆哮", effects = {
        { buffId = 3819, name = "懦弱（1级）", target = "unknown", kind = "unknown" },
        { buffId = 3823, name = "懦弱（2级）", target = "unknown", kind = "unknown" },
        { buffId = 3824, name = "懦弱（3级）", target = "unknown", kind = "unknown" },
        { buffId = 3825, name = "坚韧（1级）", target = "unknown", kind = "unknown" },
        { buffId = 3826, name = "坚韧（2级）", target = "unknown", kind = "unknown" },
        { buffId = 3827, name = "坚韧（3级）", target = "unknown", kind = "unknown" },
        { buffId = 7649, name = "懦弱（4级）", target = "unknown", kind = "unknown" },
        { buffId = 7650, name = "坚韧（4级）", target = "unknown", kind = "unknown" },
        { buffId = 13605, name = "坚韧（5级）", target = "unknown", kind = "unknown" },
        { buffId = 13606, name = "懦弱（5级）", target = "unknown", kind = "unknown" },
        { buffId = 13610, name = "坚韧（6级）", target = "unknown", kind = "unknown" },
        { buffId = 13611, name = "懦弱（6级）", target = "unknown", kind = "unknown" },
        { buffId = 27631, name = "倒地", target = "unknown", kind = "unknown" },
        { buffId = 27632, name = "倒地", target = "unknown", kind = "unknown" },
    } }
    T.skills[18757] = { name = "艾摩兰之锤", effects = {
        { buffId = 22532, name = "眩晕", target = "unknown", kind = "unknown" },
    } }
    T.skills[23587] = { name = "英勇跃击", effects = {
        { buffId = 828, name = "深度破胆", target = "unknown", kind = "unknown" },
        { buffId = 27631, name = "倒地", target = "unknown", kind = "unknown" },
        { buffId = 26932, name = "减速", target = "unknown", kind = "unknown" },
        { buffId = 7543, name = "鲁莽突进", target = "unknown", kind = "unknown" },
        { buffId = 27632, name = "倒地", target = "unknown", kind = "unknown" },
    } }
    T.skills[32040] = { name = "圆月斩", effects = {} }
    T.skills[32049] = { name = "圆月斩", effects = {} }
    T.skills[36401] = { name = "三连斩：奔雷", effects = {
        { buffId = 26932, name = "减速", target = "unknown", kind = "unknown" },
    } }
    T.skills[36402] = { name = "三连斩：奔雷", effects = {} }
    T.skills[36403] = { name = "三连斩：奔雷", effects = {
        { buffId = 3842, name = "연출용 느려짐", target = "unknown", kind = "unknown" },
    } }
    T.skills[36404] = { name = "三连斩：地哮", effects = {} }
    T.skills[36405] = { name = "三连斩：地哮", effects = {} }
    T.skills[36406] = { name = "三连斩：地哮", effects = {
        { buffId = 3842, name = "연출용 느려짐", target = "unknown", kind = "unknown" },
    } }
    T.skills[36446] = { name = "致命打击：波涛", effects = {
        { buffId = 21154, name = "276599 DO NOT TRANSLATE", target = "unknown", kind = "unknown" },
    } }
    T.skills[36447] = { name = "致命打击：暴风", effects = {} }
    T.skills[36448] = { name = "杀戮风暴：奔雷", effects = {} }
    T.skills[36449] = { name = "杀戮风暴：绿叶", effects = {} }
    T.skills[39661] = { name = "英勇跃击：暴风", effects = {
        { buffId = 828, name = "深度破胆", target = "unknown", kind = "unknown" },
        { buffId = 27631, name = "倒地", target = "unknown", kind = "unknown" },
        { buffId = 7543, name = "鲁莽突进", target = "unknown", kind = "unknown" },
        { buffId = 27632, name = "倒地", target = "unknown", kind = "unknown" },
        { buffId = 26932, name = "减速", target = "unknown", kind = "unknown" },
    } }
    T.skills[39662] = { name = "英勇跃击：磐石", effects = {
        { buffId = 27631, name = "倒地", target = "unknown", kind = "unknown" },
        { buffId = 26932, name = "减速", target = "unknown", kind = "unknown" },
        { buffId = 7543, name = "鲁莽突进", target = "unknown", kind = "unknown" },
        { buffId = 27632, name = "倒地", target = "unknown", kind = "unknown" },
    } }
    T.skills[41217] = { name = "裂岩斩：地哮", effects = {} }
    T.skills[41218] = { name = "裂岩斩：迷雾", effects = {} }
    T.skills[43188] = { name = "狂暴：烈焰", effects = {
        { buffId = 25651, name = "狂暴：烈焰", target = "unknown", kind = "unknown" },
        { buffId = 25980, name = "狂暴的后遗症", target = "unknown", kind = "unknown" },
    } }
    T.skills[43189] = { name = "狂暴：波涛", effects = {
        { buffId = 25650, name = "狂暴：波涛", target = "unknown", kind = "unknown" },
    } }
    S.Data.SkillEffects.trees["battlerage"] = T
end

do
    local T = { name_cn = "幻术", skills = {} }
    T.skills[10134] = { name = "催眠术", effects = {
        { buffId = 114, name = "催眠术", target = "unknown", kind = "unknown" },
        { buffId = 2275, name = "催眠术", target = "unknown", kind = "unknown" },
    } }
    T.skills[10154] = { name = "水之禁锢", effects = {
        { buffId = 96, name = "水之禁锢", target = "unknown", kind = "unknown" },
        { buffId = 2286, name = "水之禁锢", target = "unknown", kind = "unknown" },
    } }
    T.skills[10159] = { name = "精神震击", effects = {
        { buffId = 101, name = "精神震击", target = "unknown", kind = "unknown" },
        { buffId = 22909, name = "精神震击连锁", target = "unknown", kind = "unknown" },
    } }
    T.skills[10409] = { name = "恐惧耳语", effects = {
        { buffId = 156, name = "恐惧", target = "unknown", kind = "unknown" },
        { buffId = 2277, name = "恐惧", target = "unknown", kind = "unknown" },
    } }
    T.skills[10665] = { name = "绝对沉默", effects = {
        { buffId = 245, name = "沉默", target = "unknown", kind = "unknown" },
        { buffId = 425, name = "妨碍施法", target = "unknown", kind = "unknown" },
        { buffId = 18147, name = "减速", target = "unknown", kind = "unknown" },
    } }
    T.skills[10712] = { name = "净化", effects = {
        { buffId = 266, name = "沉默", target = "unknown", kind = "unknown" },
        { buffId = 23347, name = "净化", target = "unknown", kind = "unknown" },
        { buffId = 23275, name = "범죄 버프", target = "unknown", kind = "unknown" },
    } }
    T.skills[11353] = { name = "精神反噬", effects = {
        { buffId = 449, name = "精神反噬", target = "unknown", kind = "unknown" },
    } }
    T.skills[11443] = { name = "达忽塔之息", effects = {
        { buffId = 1366, name = "达忽塔之息", target = "unknown", kind = "unknown" },
    } }
    T.skills[12001] = { name = "惊悚尖啸", effects = {
        { buffId = 975, name = "惊悚尖啸", target = "unknown", kind = "unknown" },
        { buffId = 2278, name = "惊悚尖啸", target = "unknown", kind = "unknown" },
    } }
    T.skills[14376] = { name = "大地之手", effects = {
        { buffId = 82, name = "大地之手", target = "unknown", kind = "unknown" },
        { buffId = 23353, name = "解除装备（乐器）", target = "unknown", kind = "unknown" },
    } }
    T.skills[23588] = { name = "虚空魔物", effects = {} }
    T.skills[23934] = { name = "镜之分身", effects = {
        { buffId = 7010, name = "镜之分身", target = "unknown", kind = "unknown" },
    } }
    T.skills[36450] = { name = "大地之手：地哮", effects = {
        { buffId = 21397, name = "大地之手", target = "unknown", kind = "unknown" },
        { buffId = 23353, name = "解除装备（乐器）", target = "unknown", kind = "unknown" },
    } }
    T.skills[36451] = { name = "大地之手：奔雷", effects = {
        { buffId = 21398, name = "大地之手", target = "unknown", kind = "unknown" },
        { buffId = 23353, name = "解除装备（乐器）", target = "unknown", kind = "unknown" },
    } }
    T.skills[36452] = { name = "水之禁锢：暴风", effects = {
        { buffId = 21399, name = "水之禁锢", target = "unknown", kind = "unknown" },
        { buffId = 21400, name = "水之禁锢", target = "unknown", kind = "unknown" },
    } }
    T.skills[36453] = { name = "水之禁锢：迷雾", effects = {} }
    T.skills[36454] = { name = "惊悚尖啸：磐石", effects = {
        { buffId = 21402, name = "惊悚尖啸", target = "unknown", kind = "unknown" },
        { buffId = 21403, name = "惊悚尖啸", target = "unknown", kind = "unknown" },
    } }
    T.skills[36455] = { name = "惊悚尖啸：迷雾", effects = {} }
    T.skills[39291] = { name = "镜之分身：烈焰", effects = {
        { buffId = 23134, name = "镜之分身：烈焰", target = "unknown", kind = "unknown" },
    } }
    T.skills[39292] = { name = "镜之分身：磐石", effects = {
        { buffId = 23135, name = "镜之分身：磐石", target = "unknown", kind = "unknown" },
    } }
    T.skills[40774] = { name = "达忽塔之息：地哮", effects = {} }
    T.skills[40777] = { name = "达忽塔之息：迷雾", effects = {} }
    T.skills[44252] = { name = "精神震击：暴风", effects = {
        { buffId = 26454, name = "精神震击：暴风", target = "unknown", kind = "unknown" },
        { buffId = 26453, name = "精神震击连锁", target = "unknown", kind = "unknown" },
    } }
    T.skills[44258] = { name = "大地之手：烈焰", effects = {
        { buffId = 82, name = "大地之手", target = "unknown", kind = "unknown" },
        { buffId = 23353, name = "解除装备（乐器）", target = "unknown", kind = "unknown" },
    } }
    T.skills[46191] = { name = "恐惧耳语：磐石", effects = {
        { buffId = 28247, name = "潜在力量：恐惧耳语", target = "unknown", kind = "unknown" },
    } }
    T.skills[46192] = { name = "恐惧耳语：磐石", effects = {
        { buffId = 156, name = "恐惧", target = "unknown", kind = "unknown" },
        { buffId = 2277, name = "恐惧", target = "unknown", kind = "unknown" },
    } }
    T.skills[46193] = { name = "恐惧耳语：磐石", effects = {
        { buffId = 28250, name = "深渊恐惧", target = "unknown", kind = "unknown" },
        { buffId = 28252, name = "深渊恐惧", target = "unknown", kind = "unknown" },
    } }
    T.skills[46195] = { name = "水之禁锢：磐石", effects = {
        { buffId = 28253, name = "潜在力量：水之禁锢", target = "unknown", kind = "unknown" },
    } }
    T.skills[46196] = { name = "水之禁锢：磐石", effects = {
        { buffId = 96, name = "水之禁锢", target = "unknown", kind = "unknown" },
        { buffId = 2286, name = "水之禁锢", target = "unknown", kind = "unknown" },
    } }
    T.skills[46197] = { name = "水之禁锢：磐石", effects = {
        { buffId = 28256, name = "深渊的水之禁锢", target = "unknown", kind = "unknown" },
        { buffId = 28257, name = "深渊的水之禁锢", target = "unknown", kind = "unknown" },
    } }
    T.skills[50986] = { name = "精神震击：奔雷", effects = {
        { buffId = 32646, name = "精神震击：奔雷", target = "unknown", kind = "unknown" },
        { buffId = 22909, name = "精神震击连锁", target = "unknown", kind = "unknown" },
    } }
    S.Data.SkillEffects.trees["witchcraft"] = T
end

do
    local T = { name_cn = "铁壁", skills = {} }
    T.skills[10372] = { name = "钢铁之躯", effects = {} }
    T.skills[10375] = { name = "防御壁垒", effects = {
        { buffId = 26958, name = "防御壁垒", target = "unknown", kind = "unknown" },
        { buffId = 328, name = "防御壁垒（1级）", target = "unknown", kind = "unknown" },
        { buffId = 329, name = "防御壁垒（2级）", target = "unknown", kind = "unknown" },
        { buffId = 330, name = "防御壁垒（3级）", target = "unknown", kind = "unknown" },
        { buffId = 13616, name = "防御壁垒（4级）", target = "unknown", kind = "unknown" },
        { buffId = 13617, name = "防御壁垒（5级）", target = "unknown", kind = "unknown" },
    } }
    T.skills[10399] = { name = "震荡盾", effects = {
        { buffId = 21960, name = "格挡精通", target = "unknown", kind = "unknown" },
        { buffId = 18136, name = "Root", target = "unknown", kind = "unknown" },
    } }
    T.skills[10436] = { name = "浴血怒吼", effects = {
        { buffId = 171, name = "挑衅", target = "unknown", kind = "unknown" },
        { buffId = 3761, name = "破胆", target = "unknown", kind = "unknown" },
        { buffId = 828, name = "深度破胆", target = "unknown", kind = "unknown" },
        { buffId = 502, name = "强力挑衅", target = "unknown", kind = "unknown" },
    } }
    T.skills[10501] = { name = "冲击盾", effects = {
        { buffId = 206, name = "物理技能封印", target = "unknown", kind = "unknown" },
        { buffId = 505, name = "倒地", target = "unknown", kind = "unknown" },
        { buffId = 3532, name = "冲击盾：增加威胁", target = "unknown", kind = "unknown" },
    } }
    T.skills[10645] = { name = "生命值涌现", effects = {} }
    T.skills[10655] = { name = "复仇刃铠", effects = {
        { buffId = 2923, name = "复仇刃铠", target = "unknown", kind = "unknown" },
    } }
    T.skills[11365] = { name = "沸腾之血", effects = {
        { buffId = 445, name = "沸腾之血（1级）", target = "unknown", kind = "unknown" },
        { buffId = 446, name = "沸腾之血（2级）", target = "unknown", kind = "unknown" },
        { buffId = 447, name = "沸腾之血（3级）", target = "unknown", kind = "unknown" },
        { buffId = 448, name = "沸腾之血（4级）", target = "unknown", kind = "unknown" },
        { buffId = 13627, name = "沸腾之血（5级）", target = "unknown", kind = "unknown" },
        { buffId = 13628, name = "沸腾之血（6级）", target = "unknown", kind = "unknown" },
        { buffId = 21976, name = "沸腾之血（7级）", target = "unknown", kind = "unknown" },
    } }
    T.skills[12039] = { name = "牵引之索", effects = {} }
    T.skills[12046] = { name = "复苏喘息", effects = {
        { buffId = 24987, name = "复苏喘息", target = "unknown", kind = "unknown" },
    } }
    T.skills[12048] = { name = "胜者之吼", effects = {
        { buffId = 828, name = "深度破胆", target = "unknown", kind = "unknown" },
        { buffId = 502, name = "强力挑衅", target = "unknown", kind = "unknown" },
    } }
    T.skills[14529] = { name = "铁壁结界", effects = {
        { buffId = 20018, name = "执念", target = "unknown", kind = "unknown" },
    } }
    T.skills[36456] = { name = "震荡盾：暴风", effects = {
        { buffId = 425, name = "妨碍施法", target = "unknown", kind = "unknown" },
        { buffId = 21960, name = "格挡精通", target = "unknown", kind = "unknown" },
    } }
    T.skills[36457] = { name = "震荡盾：地哮", effects = {
        { buffId = 1449, name = "僵直", target = "unknown", kind = "unknown" },
        { buffId = 21960, name = "格挡精通", target = "unknown", kind = "unknown" },
    } }
    T.skills[36458] = { name = "防御壁垒：暴风", effects = {
        { buffId = 21406, name = "防御壁垒：暴风", target = "unknown", kind = "unknown" },
        { buffId = 21407, name = "防御壁垒：暴风", target = "unknown", kind = "unknown" },
    } }
    T.skills[36459] = { name = "防御壁垒：绿叶", effects = {
        { buffId = 26959, name = "防御壁垒：绿叶", target = "unknown", kind = "unknown" },
        { buffId = 21372, name = "防御壁垒：绿叶", target = "unknown", kind = "unknown" },
        { buffId = 24986, name = "贴身保护", target = "unknown", kind = "unknown" },
    } }
    T.skills[36460] = { name = "铁壁结界：波涛", effects = {} }
    T.skills[36461] = { name = "铁壁结界：迷雾", effects = {} }
    T.skills[38634] = { name = "复仇刃铠", effects = {} }
    T.skills[39289] = { name = "牵引之索：暴风", effects = {} }
    T.skills[39290] = { name = "牵引之索：绿叶", effects = {} }
    T.skills[40575] = { name = "复仇刃铠", effects = {} }
    T.skills[40578] = { name = "浴血怒吼", effects = {
        { buffId = 171, name = "挑衅", target = "unknown", kind = "unknown" },
        { buffId = 3761, name = "破胆", target = "unknown", kind = "unknown" },
        { buffId = 828, name = "深度破胆", target = "unknown", kind = "unknown" },
        { buffId = 502, name = "强力挑衅", target = "unknown", kind = "unknown" },
    } }
    T.skills[40779] = { name = "复仇刃铠：迷雾", effects = {
        { buffId = 24066, name = "复仇刃铠：迷雾", target = "unknown", kind = "unknown" },
    } }
    T.skills[40780] = { name = "复仇刃铠：烈焰", effects = {
        { buffId = 24071, name = "复仇刃铠：烈焰", target = "unknown", kind = "unknown" },
    } }
    T.skills[40806] = { name = "复仇刃铠：迷雾", effects = {} }
    T.skills[40807] = { name = "复仇刃铠：迷雾", effects = {} }
    T.skills[40808] = { name = "复仇刃铠：烈焰", effects = {} }
    T.skills[40809] = { name = "复仇刃铠：烈焰", effects = {} }
    T.skills[40930] = { name = "复仇刃铠：火焰爆炸", effects = {} }
    T.skills[42279] = { name = "牵引之索", effects = {} }
    T.skills[42857] = { name = "复苏喘息：生命", effects = {
        { buffId = 25401, name = "复苏喘息：生命", target = "unknown", kind = "unknown" },
    } }
    T.skills[42858] = { name = "复苏喘息：波涛", effects = {
        { buffId = 25402, name = "复苏喘息：波涛", target = "unknown", kind = "unknown" },
    } }
    T.skills[44265] = { name = "震荡盾：磐石", effects = {
        { buffId = 21960, name = "格挡精通", target = "unknown", kind = "unknown" },
        { buffId = 18136, name = "Root", target = "unknown", kind = "unknown" },
    } }
    T.skills[44269] = { name = "胜者之吼：烈焰", effects = {
        { buffId = 502, name = "强力挑衅", target = "unknown", kind = "unknown" },
    } }
    T.skills[46075] = { name = "防御壁垒：磐石", effects = {
        { buffId = 28116, name = "潜在力量：防御壁垒", target = "unknown", kind = "unknown" },
        { buffId = 28118, name = "潜在力量：防御壁垒", target = "unknown", kind = "unknown" },
    } }
    T.skills[46136] = { name = "复苏喘息：磐石", effects = {
        { buffId = 28186, name = "潜在力量：复苏喘息", target = "unknown", kind = "unknown" },
    } }
    T.skills[50006] = { name = "魔像反击", effects = {} }
    T.skills[50984] = { name = "胜者之吼：磐石", effects = {
        { buffId = 171, name = "挑衅", target = "unknown", kind = "unknown" },
        { buffId = 502, name = "强力挑衅", target = "unknown", kind = "unknown" },
    } }
    S.Data.SkillEffects.trees["defense"] = T
end

do
    local T = { name_cn = "意志", skills = {} }
    T.skills[10152] = { name = "闪现", effects = {} }
    T.skills[10710] = { name = "真空爆炸", effects = {
        { buffId = 3200, name = "진공 당겨짐", target = "unknown", kind = "unknown" },
    } }
    T.skills[10714] = { name = "守护之界", effects = {} }
    T.skills[11380] = { name = "前往黄泉", effects = {
        { buffId = 21977, name = "前往黄泉", target = "unknown", kind = "unknown" },
        { buffId = 24543, name = "无法使用药水", target = "unknown", kind = "unknown" },
        { buffId = 24544, name = "无法使用滑翔翼（翅膀）", target = "unknown", kind = "unknown" },
    } }
    T.skills[11424] = { name = "心灵专注", effects = {
        { buffId = 32646, name = "精神震击：奔雷", target = "unknown", kind = "unknown" },
        { buffId = 499, name = "心灵专注", target = "unknown", kind = "unknown" },
    } }
    T.skills[11429] = { name = "唤醒", effects = {} }
    T.skills[11869] = { name = "魔力护盾", effects = {
        { buffId = 745, name = "魔力护盾（1级）", target = "unknown", kind = "unknown" },
        { buffId = 854, name = "魔力护盾（2级）", target = "unknown", kind = "unknown" },
        { buffId = 855, name = "魔力护盾（3级）", target = "unknown", kind = "unknown" },
        { buffId = 856, name = "魔力护盾（4级）", target = "unknown", kind = "unknown" },
        { buffId = 857, name = "魔力护盾（5级）", target = "unknown", kind = "unknown" },
        { buffId = 2206, name = "魔法防御（1级）", target = "unknown", kind = "unknown" },
        { buffId = 2207, name = "魔法防御（2级）", target = "unknown", kind = "unknown" },
        { buffId = 2208, name = "魔法防御（3级）", target = "unknown", kind = "unknown" },
        { buffId = 13618, name = "魔法防御（4级）", target = "unknown", kind = "unknown" },
        { buffId = 13619, name = "魔法防御（5级）", target = "unknown", kind = "unknown" },
    } }
    T.skills[11989] = { name = "冥想", effects = {} }
    T.skills[11991] = { name = "脉轮之息", effects = {
        { buffId = 794, name = "脉轮之息（1级）", target = "unknown", kind = "unknown" },
        { buffId = 795, name = "脉轮之息（2级）", target = "unknown", kind = "unknown" },
        { buffId = 796, name = "脉轮之息（3级）", target = "unknown", kind = "unknown" },
        { buffId = 7655, name = "脉轮之息（4级）", target = "unknown", kind = "unknown" },
        { buffId = 13867, name = "脉轮之息（5级）", target = "unknown", kind = "unknown" },
        { buffId = 13868, name = "脉轮之息（6级）", target = "unknown", kind = "unknown" },
    } }
    T.skills[16486] = { name = "威慑气势", effects = {
        { buffId = 2763, name = "破胆（1级）", target = "unknown", kind = "unknown" },
        { buffId = 2765, name = "破胆（2级）", target = "unknown", kind = "unknown" },
        { buffId = 2766, name = "破胆（3级）", target = "unknown", kind = "unknown" },
        { buffId = 2767, name = "破胆（4级）", target = "unknown", kind = "unknown" },
        { buffId = 2768, name = "破胆（5级）", target = "unknown", kind = "unknown" },
        { buffId = 7654, name = "破胆（6级）", target = "unknown", kind = "unknown" },
        { buffId = 13769, name = "破胆（7级）", target = "unknown", kind = "unknown" },
        { buffId = 13770, name = "破胆（8级）", target = "unknown", kind = "unknown" },
        { buffId = 127, name = "意志高昂", target = "unknown", kind = "unknown" },
    } }
    T.skills[18222] = { name = "光芒之路", effects = {} }
    T.skills[23589] = { name = "背水一战", effects = {} }
    T.skills[36462] = { name = "威慑气势：迷雾", effects = {
        { buffId = 22060, name = "意志高昂：迷雾", target = "unknown", kind = "unknown" },
    } }
    T.skills[36463] = { name = "威慑气势：磐石", effects = {
        { buffId = 127, name = "意志高昂", target = "unknown", kind = "unknown" },
        { buffId = 21374, name = "威慑气势：磐石（6级）", target = "unknown", kind = "unknown" },
        { buffId = 21475, name = "威慑气势：磐石（7级）", target = "unknown", kind = "unknown" },
    } }
    T.skills[36464] = { name = "魔力护盾：迷雾", effects = {
        { buffId = 21416, name = "魔力护盾（5级）", target = "unknown", kind = "unknown" },
        { buffId = 13619, name = "魔法防御（5级）", target = "unknown", kind = "unknown" },
    } }
    T.skills[36465] = { name = "魔力护盾：烈焰", effects = {
        { buffId = 21375, name = "魔力护盾：烈焰（5阶段）", target = "unknown", kind = "unknown" },
        { buffId = 13619, name = "魔法防御（5级）", target = "unknown", kind = "unknown" },
    } }
    T.skills[36466] = { name = "守护之界：迷雾", effects = {} }
    T.skills[36467] = { name = "守护之界：烈焰", effects = {} }
    T.skills[39293] = { name = "闪现：迷雾", effects = {} }
    T.skills[39294] = { name = "闪现：奔雷", effects = {} }
    T.skills[40781] = { name = "真空爆炸：磐石", effects = {
        { buffId = 3200, name = "진공 당겨짐", target = "unknown", kind = "unknown" },
    } }
    T.skills[40782] = { name = "真空爆炸：烈焰", effects = {
        { buffId = 3200, name = "진공 당겨짐", target = "unknown", kind = "unknown" },
    } }
    T.skills[44348] = { name = "真空爆炸：地哮", effects = {
        { buffId = 3200, name = "진공 당겨짐", target = "unknown", kind = "unknown" },
    } }
    T.skills[46137] = { name = "魔力护盾：磐石", effects = {
        { buffId = 28187, name = "潜在力量：魔力护盾", target = "unknown", kind = "unknown" },
    } }
    T.skills[46138] = { name = "守护之界：磐石", effects = {
        { buffId = 28188, name = "潜在力量：守护之界", target = "unknown", kind = "unknown" },
    } }
    S.Data.SkillEffects.trees["auramancy"] = T
end

do
    local T = { name_cn = "死亡", skills = {} }
    T.skills[10135] = { name = "地狱长枪", effects = {
        { buffId = 87, name = "地狱长枪", target = "unknown", kind = "unknown" },
    } }
    T.skills[10201] = { name = "痛苦折磨", effects = {} }
    T.skills[10434] = { name = "血魄地狱", effects = {
        { buffId = 22039, name = "血魄地狱", target = "unknown", kind = "unknown" },
    } }
    T.skills[10488] = { name = "假死", effects = {} }
    T.skills[11395] = { name = "邪鸦", effects = {
        { buffId = 470, name = "乌鸦袭击", target = "unknown", kind = "unknown" },
    } }
    T.skills[11441] = { name = "生命汲取", effects = {} }
    T.skills[11442] = { name = "黑暗之拥", effects = {
        { buffId = 542, name = "黑暗之拥（1级）", target = "unknown", kind = "unknown" },
        { buffId = 7657, name = "黑暗之拥（2级）", target = "unknown", kind = "unknown" },
    } }
    T.skills[11504] = { name = "冥界之痕", effects = {} }
    T.skills[12075] = { name = "残影步", effects = {
        { buffId = 1225, name = "威胁减少", target = "unknown", kind = "unknown" },
        { buffId = 3717, name = "移动速度增加", target = "unknown", kind = "unknown" },
    } }
    T.skills[14760] = { name = "骨牢", effects = {} }
    T.skills[14810] = { name = "暗影飞刃", effects = {
        { buffId = 4677, name = "활력 칼날 데미지 증가", target = "unknown", kind = "unknown" },
        { buffId = 2921, name = "死亡刻印", target = "unknown", kind = "unknown" },
    } }
    T.skills[14811] = { name = "暗影飞刃", effects = {
        { buffId = 4677, name = "활력 칼날 데미지 증가", target = "unknown", kind = "unknown" },
        { buffId = 2921, name = "死亡刻印", target = "unknown", kind = "unknown" },
    } }
    T.skills[14832] = { name = "暗影飞刃", effects = {
        { buffId = 4677, name = "활력 칼날 데미지 증가", target = "unknown", kind = "unknown" },
        { buffId = 2921, name = "死亡刻印", target = "unknown", kind = "unknown" },
    } }
    T.skills[19047] = { name = "죽음_(로그인스테이지)_죽은자의 주문", effects = {
        { buffId = 4252, name = "黑暗之拥", target = "unknown", kind = "unknown" },
    } }
    T.skills[19048] = { name = "죽음_(로그인스테이지)_모두 쉿", effects = {
        { buffId = 245, name = "沉默", target = "unknown", kind = "unknown" },
        { buffId = 425, name = "妨碍施法", target = "unknown", kind = "unknown" },
    } }
    T.skills[19049] = { name = "죽음_(로그인스테이지)_복수의 갑옷", effects = {
        { buffId = 2923, name = "复仇刃铠", target = "unknown", kind = "unknown" },
        { buffId = 2924, name = "复仇刃铠（2级）", target = "unknown", kind = "unknown" },
    } }
    T.skills[23591] = { name = "炽火凋零", effects = {
        { buffId = 6961, name = "炽火凋零", target = "unknown", kind = "unknown" },
    } }
    T.skills[34171] = { name = "诅咒之刺", effects = {
        { buffId = 18341, name = "诅咒的种子", target = "unknown", kind = "unknown" },
    } }
    T.skills[34181] = { name = "230243 DO NOT TRANSLATE", effects = {} }
    T.skills[36586] = { name = "地狱长枪：迷雾", effects = {
        { buffId = 18380, name = "地狱长枪", target = "unknown", kind = "unknown" },
    } }
    T.skills[36587] = { name = "地狱长枪：烈焰", effects = {
        { buffId = 23361, name = "地狱长枪：烈焰", target = "unknown", kind = "unknown" },
    } }
    T.skills[36620] = { name = "痛苦折磨：磐石", effects = {} }
    T.skills[36621] = { name = "暗影飞刃", effects = {
        { buffId = 18449, name = "Mana Bolts Move Speed Boost", target = "unknown", kind = "unknown" },
        { buffId = 2921, name = "死亡刻印", target = "unknown", kind = "unknown" },
    } }
    T.skills[36622] = { name = "暗影飞刃", effects = {
        { buffId = 18449, name = "Mana Bolts Move Speed Boost", target = "unknown", kind = "unknown" },
        { buffId = 2921, name = "死亡刻印", target = "unknown", kind = "unknown" },
    } }
    T.skills[36623] = { name = "痛苦折磨：地哮", effects = {} }
    T.skills[36624] = { name = "暗影飞刃", effects = {
        { buffId = 4677, name = "활력 칼날 데미지 증가", target = "unknown", kind = "unknown" },
        { buffId = 2921, name = "死亡刻印", target = "unknown", kind = "unknown" },
    } }
    T.skills[36625] = { name = "暗影飞刃", effects = {
        { buffId = 4677, name = "활력 칼날 데미지 증가", target = "unknown", kind = "unknown" },
        { buffId = 2921, name = "死亡刻印", target = "unknown", kind = "unknown" },
    } }
    T.skills[36626] = { name = "血魄地狱：波涛", effects = {
        { buffId = 18344, name = "血魄地狱", target = "unknown", kind = "unknown" },
    } }
    T.skills[36627] = { name = "血魄地狱：迷雾", effects = {} }
    T.skills[37935] = { name = "炽火凋零", effects = {
        { buffId = 20936, name = "炽火凋零", target = "unknown", kind = "unknown" },
    } }
    T.skills[39295] = { name = "残影步：迷雾", effects = {} }
    T.skills[39296] = { name = "残影步：奔雷", effects = {} }
    T.skills[39339] = { name = "残影步：奔雷", effects = {} }
    T.skills[39340] = { name = "残影步：奔雷", effects = {} }
    T.skills[40785] = { name = "生命汲取：磐石", effects = {} }
    T.skills[40786] = { name = "生命汲取：烈焰", effects = {} }
    T.skills[44321] = { name = "痛苦折磨：暴风", effects = {} }
    T.skills[44339] = { name = "痛苦折磨：烈焰", effects = {} }
    T.skills[44346] = { name = "地狱长枪：地哮", effects = {
        { buffId = 32647, name = "Hell Spear", target = "unknown", kind = "unknown" },
    } }
    T.skills[44347] = { name = "地狱长枪：暴风", effects = {
        { buffId = 18380, name = "地狱长枪", target = "unknown", kind = "unknown" },
    } }
    T.skills[44596] = { name = "给食人鲳撒食物", effects = {} }
    T.skills[44620] = { name = "给食人鲳撒饵", effects = {} }
    T.skills[46140] = { name = "诅咒之刺：磐石", effects = {
        { buffId = 28194, name = "潜在力量：诅咒之刺", target = "unknown", kind = "unknown" },
    } }
    T.skills[46180] = { name = "诅咒之刺：磐石", effects = {
        { buffId = 22548, name = "刺", target = "unknown", kind = "unknown" },
    } }
    T.skills[46182] = { name = "诅咒之刺：磐石", effects = {
        { buffId = 28232, name = "锋利的尖刺", target = "unknown", kind = "unknown" },
    } }
    T.skills[46184] = { name = "邪鸦：磐石", effects = {
        { buffId = 28237, name = "潜在力量：邪鸦", target = "unknown", kind = "unknown" },
    } }
    T.skills[46185] = { name = "邪鸦：磐石", effects = {
        { buffId = 28239, name = "乌鸦的袭击", target = "unknown", kind = "unknown" },
    } }
    T.skills[46186] = { name = "邪鸦：磐石", effects = {
        { buffId = 28239, name = "乌鸦的袭击", target = "unknown", kind = "unknown" },
        { buffId = 3127, name = "眩晕", target = "unknown", kind = "unknown" },
    } }
    T.skills[50985] = { name = "生命汲取：波涛", effects = {} }
    S.Data.SkillEffects.trees["occultism"] = T
end

do
    local T = { name_cn = "野性", skills = {} }
    T.skills[10694] = { name = "瞄准射击", effects = {} }
    T.skills[10708] = { name = "风神之怒", effects = {
        { buffId = 256, name = "风神之怒", target = "unknown", kind = "unknown" },
        { buffId = 21988, name = "风神之怒（2阶段）", target = "unknown", kind = "unknown" },
        { buffId = 21989, name = "风神之怒（3阶段）", target = "unknown", kind = "unknown" },
    } }
    T.skills[11368] = { name = "雄鹰之力", effects = {
        { buffId = 451, name = "雄鹰之力（1级）", target = "unknown", kind = "unknown" },
        { buffId = 452, name = "雄鹰之力（2级）", target = "unknown", kind = "unknown" },
        { buffId = 453, name = "雄鹰之力（3级）", target = "unknown", kind = "unknown" },
        { buffId = 454, name = "雄鹰之力（4级）", target = "unknown", kind = "unknown" },
        { buffId = 7658, name = "雄鹰之力（5级）", target = "unknown", kind = "unknown" },
    } }
    T.skills[11933] = { name = "爆裂射击", effects = {
        { buffId = 23962, name = "减速", target = "unknown", kind = "unknown" },
        { buffId = 24239, name = "조준 사격 느려짐", target = "unknown", kind = "unknown" },
    } }
    T.skills[12133] = { name = "束缚", effects = {
        { buffId = 883, name = "束缚", target = "unknown", kind = "unknown" },
    } }
    T.skills[12759] = { name = "释放射击", effects = {
        { buffId = 20933, name = "懦弱", target = "unknown", kind = "unknown" },
        { buffId = 24239, name = "조준 사격 느려짐", target = "unknown", kind = "unknown" },
    } }
    T.skills[12792] = { name = "야성_(로그인스테이지)_매의발톱", effects = {
        { buffId = 451, name = "雄鹰之力（1级）", target = "unknown", kind = "unknown" },
    } }
    T.skills[12793] = { name = "야성_(로그인스테이지)_충격화살", effects = {} }
    T.skills[12794] = { name = "야성_(로그인스테이지)_폭탄화살", effects = {} }
    T.skills[13281] = { name = "多重射击", effects = {} }
    T.skills[14835] = { name = "连环箭", effects = {
        { buffId = 24239, name = "조준 사격 느려짐", target = "unknown", kind = "unknown" },
    } }
    T.skills[14836] = { name = "连环箭", effects = {
        { buffId = 24239, name = "조준 사격 느려짐", target = "unknown", kind = "unknown" },
    } }
    T.skills[14837] = { name = "连环箭", effects = {
        { buffId = 24239, name = "조준 사격 느려짐", target = "unknown", kind = "unknown" },
    } }
    T.skills[15073] = { name = "移动射击", effects = {
        { buffId = 27702, name = "移动射击模式", target = "unknown", kind = "unknown" },
    } }
    T.skills[15096] = { name = "光之射击", effects = {
        { buffId = 2214, name = "视力模糊", target = "unknown", kind = "unknown" },
        { buffId = 242, name = "流血（1级）", target = "unknown", kind = "unknown" },
        { buffId = 23958, name = "眩晕", target = "unknown", kind = "unknown" },
        { buffId = 24239, name = "조준 사격 느려짐", target = "unknown", kind = "unknown" },
    } }
    T.skills[16210] = { name = "冲击射击", effects = {
        { buffId = 2723, name = "减速", target = "unknown", kind = "unknown" },
        { buffId = 23956, name = "枪刺", target = "unknown", kind = "unknown" },
        { buffId = 23523, name = "沉默", target = "unknown", kind = "unknown" },
        { buffId = 23959, name = "睡眠", target = "unknown", kind = "unknown" },
        { buffId = 24239, name = "조준 사격 느려짐", target = "unknown", kind = "unknown" },
    } }
    T.skills[23592] = { name = "狙击", effects = {
        { buffId = 24239, name = "조준 사격 느려짐", target = "unknown", kind = "unknown" },
    } }
    T.skills[36468] = { name = "冲击射击：烈焰", effects = {
        { buffId = 2723, name = "减速", target = "unknown", kind = "unknown" },
        { buffId = 23956, name = "枪刺", target = "unknown", kind = "unknown" },
        { buffId = 23523, name = "沉默", target = "unknown", kind = "unknown" },
        { buffId = 23959, name = "睡眠", target = "unknown", kind = "unknown" },
        { buffId = 24239, name = "조준 사격 느려짐", target = "unknown", kind = "unknown" },
    } }
    T.skills[36469] = { name = "冲击射击：暴风", effects = {
        { buffId = 2723, name = "减速", target = "unknown", kind = "unknown" },
        { buffId = 23956, name = "枪刺", target = "unknown", kind = "unknown" },
        { buffId = 23524, name = "沉默", target = "unknown", kind = "unknown" },
        { buffId = 23959, name = "睡眠", target = "unknown", kind = "unknown" },
        { buffId = 24239, name = "조준 사격 느려짐", target = "unknown", kind = "unknown" },
    } }
    T.skills[36470] = { name = "爆裂射击：烈焰", effects = {
        { buffId = 24239, name = "조준 사격 느려짐", target = "unknown", kind = "unknown" },
    } }
    T.skills[36471] = { name = "爆裂射击：迷雾", effects = {
        { buffId = 24239, name = "조준 사격 느려짐", target = "unknown", kind = "unknown" },
    } }
    T.skills[36472] = { name = "多重射击：烈焰", effects = {
        { buffId = 24239, name = "조준 사격 느려짐", target = "unknown", kind = "unknown" },
    } }
    T.skills[36473] = { name = "多重射击：迷雾", effects = {
        { buffId = 24239, name = "조준 사격 느려짐", target = "unknown", kind = "unknown" },
    } }
    T.skills[38893] = { name = "光之射击", effects = {
        { buffId = 2214, name = "视力模糊", target = "unknown", kind = "unknown" },
        { buffId = 242, name = "流血（1级）", target = "unknown", kind = "unknown" },
        { buffId = 23958, name = "眩晕", target = "unknown", kind = "unknown" },
        { buffId = 24239, name = "조준 사격 느려짐", target = "unknown", kind = "unknown" },
    } }
    T.skills[39663] = { name = "连环箭：烈焰", effects = {
        { buffId = 24239, name = "조준 사격 느려짐", target = "unknown", kind = "unknown" },
    } }
    T.skills[39664] = { name = "连环箭：烈焰", effects = {
        { buffId = 24239, name = "조준 사격 느려짐", target = "unknown", kind = "unknown" },
    } }
    T.skills[39665] = { name = "连环箭：烈焰", effects = {
        { buffId = 24239, name = "조준 사격 느려짐", target = "unknown", kind = "unknown" },
    } }
    T.skills[39666] = { name = "连环箭：磐石", effects = {
        { buffId = 24239, name = "조준 사격 느려짐", target = "unknown", kind = "unknown" },
    } }
    T.skills[39667] = { name = "连环箭：磐石", effects = {
        { buffId = 24239, name = "조준 사격 느려짐", target = "unknown", kind = "unknown" },
    } }
    T.skills[39668] = { name = "连环箭：磐石", effects = {
        { buffId = 24239, name = "조준 사격 느려짐", target = "unknown", kind = "unknown" },
    } }
    T.skills[40580] = { name = "束缚", effects = {
        { buffId = 883, name = "束缚", target = "unknown", kind = "unknown" },
    } }
    T.skills[41219] = { name = "狙击：奔雷", effects = {
        { buffId = 24239, name = "조준 사격 느려짐", target = "unknown", kind = "unknown" },
    } }
    T.skills[41221] = { name = "狙击：烈焰", effects = {} }
    T.skills[42849] = { name = "雄鹰之力：烈焰", effects = {
        { buffId = 25391, name = "雄鹰之力：烈焰", target = "unknown", kind = "unknown" },
    } }
    T.skills[42851] = { name = "雄鹰之力：绿叶", effects = {
        { buffId = 27673, name = "雄鹰之力：绿叶", target = "unknown", kind = "unknown" },
    } }
    T.skills[50987] = { name = "爆裂射击：磐石", effects = {
        { buffId = 23962, name = "减速", target = "unknown", kind = "unknown" },
        { buffId = 24239, name = "조준 사격 느려짐", target = "unknown", kind = "unknown" },
    } }
    S.Data.SkillEffects.trees["archery"] = T
end

do
    local T = { name_cn = "元素", skills = {} }
    T.skills[10151] = { name = "冰封领域", effects = {
        { buffId = 94, name = "冰冻碎片", target = "unknown", kind = "unknown" },
        { buffId = 21990, name = "冻结", target = "unknown", kind = "unknown" },
    } }
    T.skills[10153] = { name = "魔法盾", effects = {} }
    T.skills[10664] = { name = "裂空星陨", effects = {
        { buffId = 19979, name = "裂空星陨", target = "unknown", kind = "unknown" },
        { buffId = 1403, name = "着火", target = "unknown", kind = "unknown" },
        { buffId = 20019, name = "Meteor Impact", target = "unknown", kind = "unknown" },
    } }
    T.skills[10667] = { name = "寒冰术", effects = {
        { buffId = 247, name = "冻伤", target = "unknown", kind = "unknown" },
        { buffId = 2279, name = "冻结", target = "unknown", kind = "unknown" },
    } }
    T.skills[10670] = { name = "闪电术", effects = {
        { buffId = 250, name = "触电", target = "unknown", kind = "unknown" },
    } }
    T.skills[10752] = { name = "火球术", effects = {
        { buffId = 1403, name = "着火", target = "unknown", kind = "unknown" },
    } }
    T.skills[11314] = { name = "霜冻之径", effects = {
        { buffId = 431, name = "霜冻之径", target = "unknown", kind = "unknown" },
    } }
    T.skills[11939] = { name = "流星火雨", effects = {} }
    T.skills[11967] = { name = "闪电风暴", effects = {} }
    T.skills[12789] = { name = "마법_(로그인스테이지)_불꽃송이", effects = {} }
    T.skills[12790] = { name = "마법_(로그인스테이지)_얼음화살", effects = {} }
    T.skills[12791] = { name = "마법_(로그인스테이지)_분노의벼락", effects = {} }
    T.skills[12796] = { name = "魔法阵", effects = {
        { buffId = 1248, name = "魔法阵（1级）", target = "unknown", kind = "unknown" },
        { buffId = 1249, name = "魔法阵（2级）", target = "unknown", kind = "unknown" },
        { buffId = 8075, name = "魔法阵（3级）", target = "unknown", kind = "unknown" },
        { buffId = 13775, name = "魔法阵（4级）", target = "unknown", kind = "unknown" },
        { buffId = 13776, name = "魔法阵（5级）", target = "unknown", kind = "unknown" },
    } }
    T.skills[14774] = { name = "火之壁障", effects = {
        { buffId = 1987, name = "火焰缠身", target = "unknown", kind = "unknown" },
    } }
    T.skills[23593] = { name = "雷霆狂怒", effects = {
        { buffId = 250, name = "触电", target = "unknown", kind = "unknown" },
    } }
    T.skills[23646] = { name = "雷霆狂怒", effects = {
        { buffId = 250, name = "触电", target = "unknown", kind = "unknown" },
    } }
    T.skills[23647] = { name = "雷霆狂怒", effects = {
        { buffId = 250, name = "触电", target = "unknown", kind = "unknown" },
    } }
    T.skills[23648] = { name = "雷霆狂怒", effects = {
        { buffId = 250, name = "触电", target = "unknown", kind = "unknown" },
    } }
    T.skills[23649] = { name = "雷霆狂怒", effects = {
        { buffId = 250, name = "触电", target = "unknown", kind = "unknown" },
    } }
    T.skills[24894] = { name = "火球术", effects = {} }
    T.skills[24895] = { name = "火球术", effects = {
        { buffId = 2287, name = "猛烈灼烧", target = "unknown", kind = "unknown" },
        { buffId = 15024, name = "魔力源泉", target = "unknown", kind = "unknown" },
    } }
    T.skills[36474] = { name = "火球术：烈焰", effects = {
        { buffId = 21154, name = "276599 DO NOT TRANSLATE", target = "unknown", kind = "unknown" },
        { buffId = 1403, name = "着火", target = "unknown", kind = "unknown" },
        { buffId = 2287, name = "猛烈灼烧", target = "unknown", kind = "unknown" },
    } }
    T.skills[36475] = { name = "火球术：奔雷", effects = {
        { buffId = 21154, name = "276599 DO NOT TRANSLATE", target = "unknown", kind = "unknown" },
        { buffId = 250, name = "触电", target = "unknown", kind = "unknown" },
    } }
    T.skills[36476] = { name = "闪电风暴：烈焰", effects = {} }
    T.skills[36477] = { name = "闪电风暴：波涛", effects = {} }
    T.skills[36478] = { name = "裂空星陨：波涛", effects = {} }
    T.skills[36479] = { name = "裂空星陨：奔雷", effects = {
        { buffId = 21557, name = "触电", target = "unknown", kind = "unknown" },
    } }
    T.skills[37837] = { name = "冰甲", effects = {
        { buffId = 94, name = "冰冻碎片", target = "unknown", kind = "unknown" },
    } }
    T.skills[39669] = { name = "雷霆狂怒：奔雷", effects = {
        { buffId = 250, name = "触电", target = "unknown", kind = "unknown" },
    } }
    T.skills[39670] = { name = "雷霆狂怒：奔雷", effects = {
        { buffId = 250, name = "触电", target = "unknown", kind = "unknown" },
    } }
    T.skills[39671] = { name = "雷霆狂怒：奔雷", effects = {
        { buffId = 250, name = "触电", target = "unknown", kind = "unknown" },
    } }
    T.skills[39672] = { name = "雷霆狂怒：奔雷", effects = {
        { buffId = 250, name = "触电", target = "unknown", kind = "unknown" },
    } }
    T.skills[39673] = { name = "雷霆狂怒：奔雷", effects = {
        { buffId = 250, name = "触电", target = "unknown", kind = "unknown" },
    } }
    T.skills[39674] = { name = "雷霆狂怒：波涛", effects = {} }
    T.skills[41222] = { name = "火之壁障：波涛", effects = {
        { buffId = 24586, name = "冻伤", target = "unknown", kind = "unknown" },
    } }
    T.skills[41223] = { name = "火之壁障：迷雾", effects = {
        { buffId = 24583, name = "火之印记", target = "unknown", kind = "unknown" },
    } }
    T.skills[41478] = { name = "火之壁障：迷雾", effects = {
        { buffId = 1987, name = "火焰缠身", target = "unknown", kind = "unknown" },
    } }
    T.skills[42012] = { name = "移动到魔法阵", effects = {
        { buffId = 9000157, name = "Skill test", target = "unknown", kind = "unknown" },
    } }
    T.skills[43068] = { name = "魔法阵：地哮", effects = {
        { buffId = 25646, name = "魔法阵（地哮）", target = "unknown", kind = "unknown" },
    } }
    T.skills[43185] = { name = "魔法阵：烈焰", effects = {
        { buffId = 25647, name = "魔法阵（烈焰）", target = "unknown", kind = "unknown" },
    } }
    T.skills[43464] = { name = "前往魔法阵：烈焰", effects = {} }
    T.skills[43465] = { name = "前往魔法阵：地哮", effects = {} }
    T.skills[9000229] = { name = "", effects = {
        { buffId = 922, name = "触电", target = "unknown", kind = "unknown" },
    } }
    S.Data.SkillEffects.trees["sorcery"] = T
end

do
    local T = { name_cn = "暗杀", skills = {} }
    T.skills[10082] = { name = "隐身", effects = {
        { buffId = 599, name = "隐身（1级）", target = "unknown", kind = "unknown" },
        { buffId = 600, name = "隐身（2级）", target = "unknown", kind = "unknown" },
        { buffId = 601, name = "隐身（3级）", target = "unknown", kind = "unknown" },
        { buffId = 5278, name = "隐身（1级）", target = "unknown", kind = "unknown" },
        { buffId = 5279, name = "隐身（2级）", target = "unknown", kind = "unknown" },
        { buffId = 5280, name = "隐身（3级）", target = "unknown", kind = "unknown" },
        { buffId = 8224, name = "隐身（4级）", target = "unknown", kind = "unknown" },
        { buffId = 8225, name = "隐身（4级）", target = "unknown", kind = "unknown" },
    } }
    T.skills[10104] = { name = "迷扰", effects = {
        { buffId = 23275, name = "범죄 버프", target = "unknown", kind = "unknown" },
    } }
    T.skills[10189] = { name = "疾风步", effects = {
        { buffId = 340, name = "疾风步（1级）", target = "unknown", kind = "unknown" },
        { buffId = 13779, name = "疾风步（2级）", target = "unknown", kind = "unknown" },
        { buffId = 13780, name = "疾风步（3级）", target = "unknown", kind = "unknown" },
        { buffId = 13781, name = "疾风步（4级）", target = "unknown", kind = "unknown" },
    } }
    T.skills[10481] = { name = "抹毒", effects = {
        { buffId = 22266, name = "抹毒", target = "unknown", kind = "unknown" },
    } }
    T.skills[10496] = { name = "影袭", effects = {
        { buffId = 206, name = "物理技能封印", target = "unknown", kind = "unknown" },
        { buffId = 21, name = "倒地", target = "unknown", kind = "unknown" },
    } }
    T.skills[10648] = { name = "飞刺", effects = {
        { buffId = 243, name = "眩晕", target = "unknown", kind = "unknown" },
        { buffId = 1763, name = "杀气冲击", target = "unknown", kind = "unknown" },
    } }
    T.skills[11418] = { name = "反刺", effects = {} }
    T.skills[12029] = { name = "乱斩", effects = {
        { buffId = 16576, name = "暴露弱点", target = "unknown", kind = "unknown" },
        { buffId = 18136, name = "Root", target = "unknown", kind = "unknown" },
    } }
    T.skills[12049] = { name = "后空翻", effects = {
        { buffId = 14861, name = "腾空之力", target = "unknown", kind = "unknown" },
        { buffId = 2727, name = "后空翻", target = "unknown", kind = "unknown" },
    } }
    T.skills[12139] = { name = "猎手印记", effects = {
        { buffId = 886, name = "猎手印记（1级）", target = "unknown", kind = "unknown" },
        { buffId = 2445, name = "猎手印记（2级）", target = "unknown", kind = "unknown" },
        { buffId = 2446, name = "猎手印记（3级）", target = "unknown", kind = "unknown" },
        { buffId = 7659, name = "猎手印记（4级）", target = "unknown", kind = "unknown" },
        { buffId = 13777, name = "猎手印记（5级）", target = "unknown", kind = "unknown" },
        { buffId = 13778, name = "猎手印记（6级）", target = "unknown", kind = "unknown" },
        { buffId = 18146, name = "减少物理防御", target = "unknown", kind = "unknown" },
    } }
    T.skills[13344] = { name = "锥击", effects = {
        { buffId = 242, name = "流血（1级）", target = "unknown", kind = "unknown" },
        { buffId = 514, name = "流血（2级）", target = "unknown", kind = "unknown" },
        { buffId = 515, name = "流血（3级）", target = "unknown", kind = "unknown" },
        { buffId = 516, name = "流血（4级）", target = "unknown", kind = "unknown" },
        { buffId = 517, name = "流血（5级）", target = "unknown", kind = "unknown" },
        { buffId = 877, name = "살기 충격", target = "unknown", kind = "unknown" },
        { buffId = 22013, name = "沉默", target = "unknown", kind = "unknown" },
        { buffId = 3842, name = "연출용 느려짐", target = "unknown", kind = "unknown" },
    } }
    T.skills[18125] = { name = "凌风连击", effects = {
        { buffId = 22265, name = "死亡刻印", target = "unknown", kind = "unknown" },
    } }
    T.skills[18126] = { name = "凌风连击", effects = {
        { buffId = 22265, name = "死亡刻印", target = "unknown", kind = "unknown" },
    } }
    T.skills[18127] = { name = "凌风连击", effects = {
        { buffId = 22265, name = "死亡刻印", target = "unknown", kind = "unknown" },
    } }
    T.skills[19050] = { name = "사명_(로그인스테이지)_내리꽂기", effects = {} }
    T.skills[19052] = { name = "사명_(로그인스테이지)_독화살", effects = {
        { buffId = 196, name = "毒", target = "unknown", kind = "unknown" },
    } }
    T.skills[19054] = { name = "사명_(로그인스테이지)_어둠의 일격", effects = {
        { buffId = 21, name = "倒地", target = "unknown", kind = "unknown" },
        { buffId = 206, name = "物理技能封印", target = "unknown", kind = "unknown" },
    } }
    T.skills[23594] = { name = "彗星利刃", effects = {} }
    T.skills[36588] = { name = "飞刺：烈焰", effects = {
        { buffId = 1763, name = "杀气冲击", target = "unknown", kind = "unknown" },
    } }
    T.skills[36589] = { name = "飞刺：奔雷", effects = {
        { buffId = 1763, name = "杀气冲击", target = "unknown", kind = "unknown" },
    } }
    T.skills[36590] = { name = "后空翻：迷雾", effects = {
        { buffId = 2727, name = "后空翻", target = "unknown", kind = "unknown" },
    } }
    T.skills[36591] = { name = "后空翻：波涛", effects = {
        { buffId = 21376, name = "后空翻：波涛", target = "unknown", kind = "unknown" },
    } }
    T.skills[36593] = { name = "影袭：迷雾", effects = {
        { buffId = 206, name = "物理技能封印", target = "unknown", kind = "unknown" },
        { buffId = 21, name = "倒地", target = "unknown", kind = "unknown" },
    } }
    T.skills[36594] = { name = "影袭：奔雷", effects = {
        { buffId = 206, name = "物理技能封印", target = "unknown", kind = "unknown" },
        { buffId = 21, name = "倒地", target = "unknown", kind = "unknown" },
    } }
    T.skills[39297] = { name = "疾风步：地哮", effects = {
        { buffId = 23180, name = "疾风步：地哮", target = "unknown", kind = "unknown" },
    } }
    T.skills[39298] = { name = "疾风步：烈焰", effects = {
        { buffId = 23146, name = "疾风步：烈焰", target = "unknown", kind = "unknown" },
    } }
    T.skills[40787] = { name = "抹毒：烈焰", effects = {
        { buffId = 24093, name = "抹毒：烈焰", target = "unknown", kind = "unknown" },
    } }
    T.skills[40788] = { name = "抹毒：波涛", effects = {
        { buffId = 24235, name = "抹毒：波涛", target = "unknown", kind = "unknown" },
    } }
    T.skills[40815] = { name = "抹毒：烈焰", effects = {} }
    T.skills[44288] = { name = "猎手印记：暴风", effects = {
        { buffId = 26471, name = "标志", target = "unknown", kind = "unknown" },
        { buffId = 18146, name = "减少物理防御", target = "unknown", kind = "unknown" },
    } }
    T.skills[44289] = { name = "猎手印记：烈焰", effects = {
        { buffId = 26472, name = "标志", target = "unknown", kind = "unknown" },
        { buffId = 18146, name = "减少物理防御", target = "unknown", kind = "unknown" },
    } }
    S.Data.SkillEffects.trees["shadowplay"] = T
end

do
    local T = { name_cn = "吟游", skills = {} }
    T.skills[10723] = { name = "[演奏]轻舞乐章", effects = {
        { buffId = 656, name = "轻舞乐章（1级）", target = "unknown", kind = "unknown" },
        { buffId = 657, name = "轻舞乐章（2级）", target = "unknown", kind = "unknown" },
        { buffId = 658, name = "轻舞乐章（3级）", target = "unknown", kind = "unknown" },
        { buffId = 659, name = "轻舞乐章（4级）", target = "unknown", kind = "unknown" },
        { buffId = 660, name = "轻舞乐章（5级）", target = "unknown", kind = "unknown" },
        { buffId = 2169, name = "负面情绪（轻舞乐章）", target = "unknown", kind = "unknown" },
        { buffId = 2183, name = "轻舞乐章（1级）", target = "unknown", kind = "unknown" },
        { buffId = 2184, name = "轻舞乐章（2级）", target = "unknown", kind = "unknown" },
        { buffId = 2185, name = "轻舞乐章（3级）", target = "unknown", kind = "unknown" },
        { buffId = 2186, name = "轻舞乐章（4级）", target = "unknown", kind = "unknown" },
        { buffId = 2187, name = "轻舞乐章（5级）", target = "unknown", kind = "unknown" },
        { buffId = 2188, name = "负面情绪（轻舞乐章）", target = "unknown", kind = "unknown" },
        { buffId = 17205, name = "Manage Rhythm Overlap", target = "unknown", kind = "unknown" },
        { buffId = 17207, name = "Manage Rhythm Overlap", target = "unknown", kind = "unknown" },
    } }
    T.skills[10724] = { name = "[演奏]生命乐章", effects = {
        { buffId = 662, name = "生命乐章（1级）", target = "unknown", kind = "unknown" },
        { buffId = 664, name = "生命乐章（2级）", target = "unknown", kind = "unknown" },
        { buffId = 663, name = "生命乐章（3级）", target = "unknown", kind = "unknown" },
        { buffId = 2174, name = "衰弱气息（生命乐章）", target = "unknown", kind = "unknown" },
        { buffId = 2190, name = "生命乐章（1级）", target = "unknown", kind = "unknown" },
        { buffId = 2191, name = "生命乐章（2级）", target = "unknown", kind = "unknown" },
        { buffId = 2192, name = "生命乐章（3级）", target = "unknown", kind = "unknown" },
        { buffId = 2193, name = "衰弱气息（生命乐章）", target = "unknown", kind = "unknown" },
        { buffId = 13786, name = "生命乐章（4级）", target = "unknown", kind = "unknown" },
        { buffId = 13785, name = "生命乐章（5级）", target = "unknown", kind = "unknown" },
        { buffId = 13787, name = "生命乐章（4级）", target = "unknown", kind = "unknown" },
        { buffId = 13788, name = "生命乐章（5级）", target = "unknown", kind = "unknown" },
        { buffId = 17205, name = "Manage Rhythm Overlap", target = "unknown", kind = "unknown" },
        { buffId = 17207, name = "Manage Rhythm Overlap", target = "unknown", kind = "unknown" },
    } }
    T.skills[10727] = { name = "[演奏]英雄进行曲", effects = {
        { buffId = 7662, name = "英雄进行曲（2级）", target = "unknown", kind = "unknown" },
        { buffId = 667, name = "英雄进行曲（1级）", target = "unknown", kind = "unknown" },
        { buffId = 2196, name = "英雄进行曲（1级）", target = "unknown", kind = "unknown" },
        { buffId = 7664, name = "英雄进行曲（2级）", target = "unknown", kind = "unknown" },
        { buffId = 17205, name = "Manage Rhythm Overlap", target = "unknown", kind = "unknown" },
        { buffId = 17207, name = "Manage Rhythm Overlap", target = "unknown", kind = "unknown" },
        { buffId = 2176, name = "无力之息（英雄进行曲）", target = "unknown", kind = "unknown" },
        { buffId = 2197, name = "无力之息（英雄进行曲）", target = "unknown", kind = "unknown" },
    } }
    T.skills[11377] = { name = "风之乐章", effects = {} }
    T.skills[11396] = { name = "[演奏]大地赞歌", effects = {
        { buffId = 778, name = "大地赞歌（1级）", target = "unknown", kind = "unknown" },
        { buffId = 4386, name = "大地赞歌（2级）", target = "unknown", kind = "unknown" },
        { buffId = 2177, name = "掉以轻心(大地赞歌)", target = "unknown", kind = "unknown" },
        { buffId = 2199, name = "大地赞歌（1级）", target = "unknown", kind = "unknown" },
        { buffId = 4387, name = "大地赞歌（2级）", target = "unknown", kind = "unknown" },
        { buffId = 2200, name = "掉以轻心(大地赞歌)", target = "unknown", kind = "unknown" },
        { buffId = 17205, name = "Manage Rhythm Overlap", target = "unknown", kind = "unknown" },
        { buffId = 17207, name = "Manage Rhythm Overlap", target = "unknown", kind = "unknown" },
    } }
    T.skills[11934] = { name = "魅惑之歌", effects = {
        { buffId = 770, name = "僵直", target = "unknown", kind = "unknown" },
    } }
    T.skills[11943] = { name = "不谐和音", effects = {} }
    T.skills[11973] = { name = "音刃", effects = {} }
    T.skills[17413] = { name = "春之回旋曲", effects = {} }
    T.skills[23596] = { name = "救赎之歌", effects = {} }
    T.skills[36595] = { name = "春之回旋曲：磐石", effects = {} }
    T.skills[36596] = { name = "春之回旋曲：波涛", effects = {} }
    T.skills[36597] = { name = "魅惑之歌：绿叶", effects = {
        { buffId = 21433, name = "陶醉", target = "unknown", kind = "unknown" },
    } }
    T.skills[36598] = { name = "魅惑之歌：波涛", effects = {
        { buffId = 21434, name = "魅惑", target = "unknown", kind = "unknown" },
    } }
    T.skills[36628] = { name = "号角：迷雾", effects = {} }
    T.skills[36629] = { name = "号角：绿叶", effects = {
        { buffId = 21437, name = "清晨号角：绿叶", target = "unknown", kind = "unknown" },
    } }
    T.skills[37839] = { name = "追击", effects = {
        { buffId = 21993, name = "追击", target = "unknown", kind = "unknown" },
    } }
    T.skills[37886] = { name = "号角", effects = {} }
    T.skills[39299] = { name = "追击：烈焰", effects = {
        { buffId = 23150, name = "追击：烈焰", target = "unknown", kind = "unknown" },
    } }
    T.skills[39300] = { name = "追击：波涛", effects = {
        { buffId = 23151, name = "追击：波涛", target = "unknown", kind = "unknown" },
    } }
    T.skills[39347] = { name = "追击：波涛", effects = {
        { buffId = 23152, name = "追击：波涛", target = "unknown", kind = "unknown" },
        { buffId = 23153, name = "追击：波涛", target = "unknown", kind = "unknown" },
    } }
    T.skills[39348] = { name = "追击：波涛", effects = {
        { buffId = 23154, name = "追击：波涛", target = "unknown", kind = "unknown" },
        { buffId = 23155, name = "追击：波涛", target = "unknown", kind = "unknown" },
    } }
    T.skills[40789] = { name = "音刃：烈焰", effects = {} }
    T.skills[40790] = { name = "音刃：地哮", effects = {} }
    T.skills[43196] = { name = "不谐和音：奔雷", effects = {} }
    T.skills[43197] = { name = "不谐和音：地哮", effects = {} }
    T.skills[44349] = { name = "音刃：波涛", effects = {} }
    T.skills[44379] = { name = "音刃：暴风", effects = {} }
    T.skills[44382] = { name = "不谐和音：烈焰", effects = {} }
    T.skills[44383] = { name = "不谐和音：暴风", effects = {} }
    S.Data.SkillEffects.trees["songcraft"] = T
end

do
    local T = { name_cn = "生命", skills = {} }
    T.skills[10534] = { name = "圣光洗礼", effects = {} }
    T.skills[10546] = { name = "复生", effects = {
        { buffId = 556, name = "复活（2级）", target = "unknown", kind = "unknown" },
        { buffId = 554, name = "复活（3级）", target = "unknown", kind = "unknown" },
        { buffId = 555, name = "复活（4级）", target = "unknown", kind = "unknown" },
        { buffId = 7660, name = "复活（5级）", target = "unknown", kind = "unknown" },
    } }
    T.skills[10547] = { name = "生机泉涌", effects = {
        { buffId = 220, name = "生机泉涌", target = "unknown", kind = "unknown" },
        { buffId = 17417, name = "生机泉涌", target = "unknown", kind = "unknown" },
    } }
    T.skills[10720] = { name = "光辉祷言", effects = {
        { buffId = 3655, name = "光辉祷言", target = "unknown", kind = "unknown" },
        { buffId = 17925, name = "春生之种", target = "unknown", kind = "unknown" },
    } }
    T.skills[11379] = { name = "光与暗", effects = {
        { buffId = 467, name = "诅咒", target = "unknown", kind = "unknown" },
        { buffId = 552, name = "祝福", target = "unknown", kind = "unknown" },
        { buffId = 3719, name = "束缚", target = "unknown", kind = "unknown" },
    } }
    T.skills[11948] = { name = "治愈之泉", effects = {} }
    T.skills[12795] = { name = "사랑_(로그인스테이지)_축복과저주", effects = {
        { buffId = 467, name = "诅咒", target = "unknown", kind = "unknown" },
        { buffId = 552, name = "祝福", target = "unknown", kind = "unknown" },
    } }
    T.skills[13286] = { name = "审判之枪", effects = {
        { buffId = 439, name = "审判之枪", target = "unknown", kind = "unknown" },
    } }
    T.skills[13572] = { name = "사랑_(로그인스테이지)_회복의씨앗", effects = {
        { buffId = 3533, name = "春生之种（1级）", target = "unknown", kind = "unknown" },
    } }
    T.skills[13656] = { name = "사랑_(로그인스테이지)_모두치유", effects = {} }
    T.skills[14929] = { name = "心脉连击", effects = {
        { buffId = 15053, name = "祈祷", target = "unknown", kind = "unknown" },
    } }
    T.skills[14930] = { name = "心脉连击", effects = {} }
    T.skills[14931] = { name = "心脉连击", effects = {} }
    T.skills[14932] = { name = "心脉连击", effects = {} }
    T.skills[14933] = { name = "心脉连击", effects = {} }
    T.skills[16004] = { name = "睿明祝福", effects = {
        { buffId = 2956, name = "睿明祝福（2级）", target = "unknown", kind = "unknown" },
        { buffId = 7661, name = "睿明祝福（3级）", target = "unknown", kind = "unknown" },
        { buffId = 13790, name = "睿明祝福（4级）", target = "unknown", kind = "unknown" },
        { buffId = 13791, name = "睿明祝福（5级）", target = "unknown", kind = "unknown" },
    } }
    T.skills[16783] = { name = "魔法盾", effects = {
        { buffId = 16870, name = "魔力魔法盾", target = "unknown", kind = "unknown" },
        { buffId = 17339, name = "Infuse", target = "unknown", kind = "unknown" },
    } }
    T.skills[17412] = { name = "春生之种", effects = {
        { buffId = 17925, name = "春生之种", target = "unknown", kind = "unknown" },
    } }
    T.skills[33345] = { name = "光束的岔道", effects = {} }
    T.skills[33822] = { name = "test", effects = {} }
    T.skills[36630] = { name = "圣光洗礼：绿叶", effects = {} }
    T.skills[36631] = { name = "圣光洗礼：地哮", effects = {} }
    T.skills[36632] = { name = "心脉连击：奔雷", effects = {
        { buffId = 15053, name = "祈祷", target = "unknown", kind = "unknown" },
        { buffId = 18390, name = "心脉连击：正在使用闪电", target = "unknown", kind = "unknown" },
    } }
    T.skills[36633] = { name = "心脉连击：奔雷", effects = {
        { buffId = 18390, name = "心脉连击：正在使用闪电", target = "unknown", kind = "unknown" },
    } }
    T.skills[36634] = { name = "心脉连击：奔雷", effects = {
        { buffId = 18390, name = "心脉连击：正在使用闪电", target = "unknown", kind = "unknown" },
    } }
    T.skills[36635] = { name = "心脉连击：烈焰", effects = {
        { buffId = 15053, name = "祈祷", target = "unknown", kind = "unknown" },
    } }
    T.skills[36636] = { name = "审判之枪：绿叶", effects = {
        { buffId = 18396, name = "审判之枪", target = "unknown", kind = "unknown" },
    } }
    T.skills[36637] = { name = "审判之枪：烈焰", effects = {
        { buffId = 18420, name = "审判之枪", target = "unknown", kind = "unknown" },
    } }
    T.skills[36638] = { name = "审判之枪：烈焰", effects = {
        { buffId = 18420, name = "审判之枪", target = "unknown", kind = "unknown" },
    } }
    T.skills[36639] = { name = "审判之枪：烈焰", effects = {
        { buffId = 18420, name = "审判之枪", target = "unknown", kind = "unknown" },
    } }
    T.skills[38206] = { name = "复活", effects = {} }
    T.skills[39675] = { name = "光束的岔道：烈焰", effects = {} }
    T.skills[39676] = { name = "光束的岔道：迷雾", effects = {} }
    T.skills[41224] = { name = "治愈之泉：波涛", effects = {} }
    T.skills[41225] = { name = "治愈之泉：绿叶", effects = {} }
    T.skills[43207] = { name = "光辉祷言：波涛", effects = {
        { buffId = 3655, name = "光辉祷言", target = "unknown", kind = "unknown" },
        { buffId = 17925, name = "春生之种", target = "unknown", kind = "unknown" },
    } }
    T.skills[43208] = { name = "光辉祷言：迷雾", effects = {
        { buffId = 3655, name = "光辉祷言", target = "unknown", kind = "unknown" },
        { buffId = 17925, name = "春生之种", target = "unknown", kind = "unknown" },
    } }
    T.skills[43209] = { name = "光辉祷言：生命", effects = {
        { buffId = 3655, name = "光辉祷言", target = "unknown", kind = "unknown" },
        { buffId = 17925, name = "春生之种", target = "unknown", kind = "unknown" },
    } }
    S.Data.SkillEffects.trees["vitalism"] = T
end

do
    local T = { name_cn = "憎恨", skills = {} }
    T.skills[39007] = { name = "暗影飞刃", effects = {} }
    T.skills[39008] = { name = "暗影飞刃", effects = {} }
    T.skills[39009] = { name = "暗影飞刃", effects = {} }
    T.skills[39012] = { name = "蛇之眼", effects = {
        { buffId = 22958, name = "蛇之眼", target = "unknown", kind = "unknown" },
    } }
    T.skills[39013] = { name = "深渊波动", effects = {} }
    T.skills[39015] = { name = "恶魔之剑", effects = {
        { buffId = 22975, name = "恶魔之剑", target = "unknown", kind = "unknown" },
    } }
    T.skills[39016] = { name = "恶魔的傀儡", effects = {
        { buffId = 22995, name = "恶魔的傀儡", target = "unknown", kind = "unknown" },
    } }
    T.skills[39017] = { name = "深渊獠牙", effects = {} }
    T.skills[39018] = { name = "愤怒", effects = {
        { buffId = 22982, name = "愤怒", target = "unknown", kind = "unknown" },
    } }
    T.skills[39019] = { name = "命运之骰", effects = {} }
    T.skills[39020] = { name = "恶魔的召唤", effects = {} }
    T.skills[39021] = { name = "恶灵突进", effects = {} }
    T.skills[39022] = { name = "憎恨之环", effects = {} }
    T.skills[39023] = { name = "死神", effects = {
        { buffId = 22964, name = "死神", target = "unknown", kind = "unknown" },
        { buffId = 22980, name = "死神", target = "unknown", kind = "unknown" },
        { buffId = 22981, name = "死神", target = "unknown", kind = "unknown" },
    } }
    T.skills[39024] = { name = "深渊巨刃", effects = {} }
    T.skills[39082] = { name = "深渊波动", effects = {} }
    T.skills[39083] = { name = "深渊波动", effects = {} }
    T.skills[39163] = { name = "暗影飞刃：波涛", effects = {
        { buffId = 23052, name = "552938 DO NOT TRANSLATE", target = "unknown", kind = "unknown" },
    } }
    T.skills[39164] = { name = "暗影飞刃：波涛", effects = {
        { buffId = 23052, name = "552938 DO NOT TRANSLATE", target = "unknown", kind = "unknown" },
    } }
    T.skills[39165] = { name = "暗影飞刃：波涛", effects = {
        { buffId = 23052, name = "552938 DO NOT TRANSLATE", target = "unknown", kind = "unknown" },
    } }
    T.skills[39166] = { name = "暗影飞刃：地哮", effects = {} }
    T.skills[39167] = { name = "暗影飞刃：地哮", effects = {} }
    T.skills[39168] = { name = "暗影飞刃", effects = {} }
    T.skills[39677] = { name = "深渊巨刃：奔雷", effects = {} }
    T.skills[39678] = { name = "深渊巨刃：烈焰", effects = {} }
    T.skills[40791] = { name = "深渊獠牙：烈焰", effects = {} }
    T.skills[40792] = { name = "深渊獠牙：磐石", effects = {} }
    T.skills[41017] = { name = "命运之骰", effects = {} }
    T.skills[41226] = { name = "恶魔的召唤：迷雾", effects = {} }
    T.skills[41227] = { name = "恶魔的召唤：烈焰", effects = {} }
    S.Data.SkillEffects.trees["malediction"] = T
end

do
    local T = { name_cn = "暗斗", skills = {} }
    T.skills[40331] = { name = "三段斩", effects = {} }
    T.skills[40332] = { name = "疾风斩", effects = {} }
    T.skills[40333] = { name = "突袭", effects = {
        { buffId = 24610, name = "突袭", target = "unknown", kind = "unknown" },
        { buffId = 26977, name = "恐惧", target = "unknown", kind = "unknown" },
    } }
    T.skills[40334] = { name = "阴影帐幕", effects = {} }
    T.skills[40335] = { name = "影之镜像", effects = {} }
    T.skills[40336] = { name = "乱舞", effects = {
        { buffId = 27219, name = "物理技能封印", target = "unknown", kind = "unknown" },
    } }
    T.skills[40337] = { name = "旋风", effects = {} }
    T.skills[40338] = { name = "伊尔克的剑舞", effects = {
        { buffId = 24953, name = "伊尔克的剑舞", target = "unknown", kind = "unknown" },
        { buffId = 26963, name = "物理技能封印", target = "unknown", kind = "unknown" },
        { buffId = 26965, name = "沉默", target = "unknown", kind = "unknown" },
    } }
    T.skills[40339] = { name = "审判之刃", effects = {
        { buffId = 24764, name = "신규 능력 딜링기4 복제", target = "unknown", kind = "unknown" },
        { buffId = 28671, name = "창꽂힘 연쇄 불가", target = "unknown", kind = "unknown" },
    } }
    T.skills[40340] = { name = "战栗之鹰", effects = {
        { buffId = 26075, name = "전율하는 매(연출)", target = "unknown", kind = "unknown" },
        { buffId = 24765, name = "신규 능력 버프1 복제", target = "unknown", kind = "unknown" },
    } }
    T.skills[40341] = { name = "步履轻盈", effects = {
        { buffId = 24001, name = "步履轻盈", target = "unknown", kind = "unknown" },
        { buffId = 24767, name = "신규 능력 버프2 복제", target = "unknown", kind = "unknown" },
    } }
    T.skills[40342] = { name = "影子鹰", effects = {
        { buffId = 24633, name = "减速", target = "unknown", kind = "unknown" },
        { buffId = 24634, name = "束缚", target = "unknown", kind = "unknown" },
        { buffId = 24768, name = "신규 능력 디버프 복제", target = "unknown", kind = "unknown" },
        { buffId = 26964, name = "眩晕", target = "unknown", kind = "unknown" },
    } }
    T.skills[40377] = { name = "三段斩", effects = {} }
    T.skills[40378] = { name = "三段斩", effects = {} }
    T.skills[41487] = { name = "突袭", effects = {
        { buffId = 24758, name = "신규 능력 이동기2 복제", target = "unknown", kind = "unknown" },
    } }
    T.skills[41749] = { name = "疾风斩", effects = {} }
    T.skills[41753] = { name = "三段斩", effects = {} }
    T.skills[41754] = { name = "三段斩", effects = {} }
    T.skills[41755] = { name = "三段斩", effects = {} }
    T.skills[41756] = { name = "突袭", effects = {
        { buffId = 24947, name = "突袭", target = "unknown", kind = "unknown" },
        { buffId = 26977, name = "恐惧", target = "unknown", kind = "unknown" },
    } }
    T.skills[41757] = { name = "阴影帐幕", effects = {} }
    T.skills[41758] = { name = "乱舞", effects = {
        { buffId = 26963, name = "物理技能封印", target = "unknown", kind = "unknown" },
    } }
    T.skills[41759] = { name = "旋风", effects = {} }
    T.skills[41761] = { name = "审判之刃", effects = {
        { buffId = 24748, name = "New Ability Main Body 2 Immunity", target = "unknown", kind = "unknown" },
    } }
    T.skills[41762] = { name = "战栗之鹰", effects = {
        { buffId = 26075, name = "전율하는 매(연출)", target = "unknown", kind = "unknown" },
        { buffId = 24748, name = "New Ability Main Body 2 Immunity", target = "unknown", kind = "unknown" },
    } }
    T.skills[41764] = { name = "步履轻盈", effects = {
        { buffId = 24001, name = "步履轻盈", target = "unknown", kind = "unknown" },
        { buffId = 24748, name = "New Ability Main Body 2 Immunity", target = "unknown", kind = "unknown" },
    } }
    T.skills[41765] = { name = "影子鹰", effects = {
        { buffId = 24633, name = "减速", target = "unknown", kind = "unknown" },
        { buffId = 24634, name = "束缚", target = "unknown", kind = "unknown" },
        { buffId = 24748, name = "New Ability Main Body 2 Immunity", target = "unknown", kind = "unknown" },
        { buffId = 26964, name = "眩晕", target = "unknown", kind = "unknown" },
    } }
    T.skills[41844] = { name = "伊尔克的剑舞", effects = {
        { buffId = 24953, name = "伊尔克的剑舞", target = "unknown", kind = "unknown" },
        { buffId = 26963, name = "物理技能封印", target = "unknown", kind = "unknown" },
        { buffId = 26965, name = "沉默", target = "unknown", kind = "unknown" },
    } }
    T.skills[41876] = { name = "伊尔克的剑舞", effects = {
        { buffId = 24953, name = "伊尔克的剑舞", target = "unknown", kind = "unknown" },
        { buffId = 26963, name = "物理技能封印", target = "unknown", kind = "unknown" },
        { buffId = 26965, name = "沉默", target = "unknown", kind = "unknown" },
    } }
    T.skills[41877] = { name = "伊尔克的剑舞", effects = {
        { buffId = 24953, name = "伊尔克的剑舞", target = "unknown", kind = "unknown" },
        { buffId = 26963, name = "物理技能封印", target = "unknown", kind = "unknown" },
        { buffId = 26965, name = "沉默", target = "unknown", kind = "unknown" },
    } }
    T.skills[41964] = { name = "突袭", effects = {
        { buffId = 24980, name = "免疫影之镜像", target = "unknown", kind = "unknown" },
    } }
    T.skills[41997] = { name = "阴影帐幕", effects = {
        { buffId = 24641, name = "그림자 장막", target = "unknown", kind = "unknown" },
    } }
    T.skills[43211] = { name = "三段斩：波涛", effects = {} }
    T.skills[43212] = { name = "突袭：迷雾", effects = {
        { buffId = 25694, name = "突袭隐身", target = "unknown", kind = "unknown" },
        { buffId = 26977, name = "恐惧", target = "unknown", kind = "unknown" },
    } }
    T.skills[43213] = { name = "审判之刃：波涛", effects = {
        { buffId = 26116, name = "칼날 심판:파도 복제", target = "unknown", kind = "unknown" },
        { buffId = 28671, name = "창꽂힘 연쇄 불가", target = "unknown", kind = "unknown" },
    } }
    T.skills[43220] = { name = "三段斩：波涛", effects = {} }
    T.skills[43221] = { name = "三段斩：波涛", effects = {} }
    T.skills[43744] = { name = "突袭：迷雾", effects = {
        { buffId = 25694, name = "突袭隐身", target = "unknown", kind = "unknown" },
    } }
    T.skills[43745] = { name = "审判之刃：波涛", effects = {
        { buffId = 24748, name = "New Ability Main Body 2 Immunity", target = "unknown", kind = "unknown" },
    } }
    T.skills[45592] = { name = "突袭", effects = {
        { buffId = 24610, name = "突袭", target = "unknown", kind = "unknown" },
        { buffId = 26977, name = "恐惧", target = "unknown", kind = "unknown" },
    } }
    T.skills[45593] = { name = "突袭", effects = {
        { buffId = 24947, name = "突袭", target = "unknown", kind = "unknown" },
        { buffId = 26977, name = "恐惧", target = "unknown", kind = "unknown" },
    } }
    T.skills[45594] = { name = "突袭：迷雾", effects = {
        { buffId = 25694, name = "突袭隐身", target = "unknown", kind = "unknown" },
        { buffId = 26977, name = "恐惧", target = "unknown", kind = "unknown" },
    } }
    T.skills[45595] = { name = "突袭：迷雾", effects = {
        { buffId = 25694, name = "突袭隐身", target = "unknown", kind = "unknown" },
    } }
    T.skills[45772] = { name = "突袭", effects = {
        { buffId = 24980, name = "免疫影之镜像", target = "unknown", kind = "unknown" },
    } }
    T.skills[45778] = { name = "突袭", effects = {
        { buffId = 24980, name = "免疫影之镜像", target = "unknown", kind = "unknown" },
    } }
    T.skills[45779] = { name = "突袭", effects = {
        { buffId = 27824, name = "신규 능력 이동기2 복제", target = "unknown", kind = "unknown" },
    } }
    T.skills[49428] = { name = "步履轻盈：风暴", effects = {
        { buffId = 31536, name = "步履轻盈：风暴", target = "unknown", kind = "unknown" },
        { buffId = 31538, name = "가벼운 발놀림: 돌풍 복제", target = "unknown", kind = "unknown" },
    } }
    T.skills[49429] = { name = "步履轻盈：风暴", effects = {
        { buffId = 31536, name = "步履轻盈：风暴", target = "unknown", kind = "unknown" },
        { buffId = 24748, name = "New Ability Main Body 2 Immunity", target = "unknown", kind = "unknown" },
    } }
    T.skills[49446] = { name = "战栗之鹰：波涛", effects = {
        { buffId = 31543, name = "신규 능력 버프1 복제", target = "unknown", kind = "unknown" },
        { buffId = 31544, name = "战栗之鹰：波涛", target = "unknown", kind = "unknown" },
        { buffId = 31549, name = "전율하는 매:파도(연출)", target = "unknown", kind = "unknown" },
    } }
    T.skills[49447] = { name = "战栗之鹰：波涛", effects = {
        { buffId = 31549, name = "전율하는 매:파도(연출)", target = "unknown", kind = "unknown" },
        { buffId = 24748, name = "New Ability Main Body 2 Immunity", target = "unknown", kind = "unknown" },
        { buffId = 31544, name = "战栗之鹰：波涛", target = "unknown", kind = "unknown" },
    } }
    T.skills[51241] = { name = "战栗之鹰：绿叶", effects = {
        { buffId = 32794, name = "전율하는 매: 생명 버프1 복제", target = "unknown", kind = "unknown" },
        { buffId = 32795, name = "战栗之鹰：绿叶", target = "unknown", kind = "unknown" },
        { buffId = 32796, name = "전율하는 매:생명(연출)", target = "unknown", kind = "unknown" },
    } }
    T.skills[51242] = { name = "战栗之鹰：绿叶", effects = {
        { buffId = 32796, name = "전율하는 매:생명(연출)", target = "unknown", kind = "unknown" },
        { buffId = 24748, name = "New Ability Main Body 2 Immunity", target = "unknown", kind = "unknown" },
        { buffId = 32795, name = "战栗之鹰：绿叶", target = "unknown", kind = "unknown" },
    } }
    S.Data.SkillEffects.trees["swiftblade"] = T
end

do
    local T = { name_cn = "疯狂", skills = {} }
    T.skills[44196] = { name = "连续射击", effects = {} }
    T.skills[44197] = { name = "腐蚀射击", effects = {} }
    T.skills[44198] = { name = "疯狂的子弹", effects = {} }
    T.skills[44199] = { name = "战术移动", effects = {
        { buffId = 28597, name = "移动中", target = "unknown", kind = "unknown" },
    } }
    T.skills[44200] = { name = "爆炸射击", effects = {} }
    T.skills[44201] = { name = "预告", effects = {
        { buffId = 27030, name = "预告", target = "unknown", kind = "unknown" },
    } }
    T.skills[44202] = { name = "破灭射击", effects = {} }
    T.skills[44203] = { name = "炮火", effects = {} }
    T.skills[44204] = { name = "破坏", effects = {} }
    T.skills[44205] = { name = "返还", effects = {
        { buffId = 23275, name = "범죄 버프", target = "unknown", kind = "unknown" },
    } }
    T.skills[44206] = { name = "报复射击", effects = {} }
    T.skills[44207] = { name = "感染射击", effects = {} }
    T.skills[45118] = { name = "连续射击", effects = {} }
    T.skills[45180] = { name = "装填", effects = {
        { buffId = 28585, name = "装填中", target = "unknown", kind = "unknown" },
    } }
    T.skills[47594] = { name = "连续射击：烈焰", effects = {} }
    T.skills[47595] = { name = "连续射击：烈焰", effects = {} }
    T.skills[47596] = { name = "连续射击：奔雷", effects = {} }
    T.skills[47597] = { name = "连续射击：奔雷", effects = {} }
    T.skills[47602] = { name = "破坏：烈焰", effects = {} }
    T.skills[47645] = { name = "破灭射击：地哮", effects = {} }
    T.skills[47651] = { name = "爆炸射击：奔雷", effects = {} }
    T.skills[47681] = { name = "腐蚀射击：磐石", effects = {} }
    T.skills[47711] = { name = "连续射击：闪电", effects = {} }
    S.Data.SkillEffects.trees["gunslinger"] = T
end

do
    local T = { name_cn = "欢乐", skills = {} }
    -- TODO: 欢乐 在 wiki 无技能数据，待手动补全 (见文件头说明)
    S.Data.SkillEffects.trees["joy"] = T
end

