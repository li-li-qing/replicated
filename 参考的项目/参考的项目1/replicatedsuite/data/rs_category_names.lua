------------------------------------------------------------------------
-- Replicated Suite - Item category display names
-- Author: Replicated
--
-- Source: pocketsorter (Wyatt LW) community table, blacklist_ui.lua:7-131.
-- Display-only mapping for the bag-organizer blacklist window so category
-- rows show a readable Chinese name instead of a bare id (206 -> 车辆装备).
-- Item names themselves still come from the live API untouched (RU client).
--
-- Static data is never persisted, so numeric keys are safe here. Name() still
-- tostring()s its input so both numeric and string keys hit (C13 mirror).
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Data = S.Data or {}

S.Data.CategoryNames = {
    [6]       = "建筑",
    [7]       = "家具",
    [8]       = "树苗",
    [12]      = "药剂",
    [13]      = "食物",
    [18]      = "书籍",
    [20]      = "盈月石",
    [21]      = "家畜",
    [23]      = "金属",
    [24]      = "木材",
    [25]      = "石材",
    [26]      = "皮革",
    [27]      = "布料",
    [28]      = "机械",
    [31]      = "橡胶",
    [32]      = "源晶",
    [36]      = "食用油",
    [38]      = "矿石",
    [39]      = "原木",
    [40]      = "岩石",
    [41]      = "生皮",
    [42]      = "纤维",
    [45]      = "肉类",
    [46]      = "水产品",
    [47]      = "谷物",
    [48]      = "蔬菜",
    [49]      = "果实",
    [51]      = "种子",
    [52]      = "香辛料",
    [53]      = "药材",
    [55]      = "花草",
    [56]      = "土壤",
    [58]      = "稀有金属",
    [59]      = "宝石",
    [62]      = "炼金材料",
    [69]      = "匕首",
    [70]      = "单手剑",
    [72]      = "单手刀",
    [73]      = "单手斧",
    [74]      = "单手钝器",
    [75]      = "单手杖",
    [76]      = "单手枪",
    [77]      = "弓箭",
    [79]      = "盾牌",
    [80]      = "弦乐器",
    [81]      = "管乐器",
    [83]      = "布甲",
    [84]      = "皮甲",
    [85]      = "板甲",
    [86]      = "项链",
    [87]      = "戒指",
    [92]      = "骑宠",
    [95]      = "战宠",
    [97]      = "饮料",
    [106]     = "钥匙",
    [108]     = "召唤兽装备",
    [109]     = "水下召唤兽",
    [113]     = "魔法药水",
    [114]     = "防御药水",
    [116]     = "治疗药水",
    [118]     = "滑翔翼",
    [121]     = "披风",
    [125]     = "耳环",
    [126]     = "遗物",
    [127]     = "双手剑",
    [128]     = "双手刀",
    [129]     = "双手斧",
    [130]     = "双手钝器",
    [131]     = "双手杖",
    [132]     = "双手枪",
    [138]     = "货币",
    [145]     = "鱼竿",
    [146]     = "标本",
    [148]     = "乐谱",
    [150]     = "梦幻魔法物品",
    [152]     = "新月石",
    [157]     = "船舶武装",
    [158]     = "船舶掌舵装置",
    [159]     = "船舶桅杆",
    [160]     = "船舶帆",
    [161]     = "船舶照明装置",
    [162]     = "船舶乘船装置",
    [164]     = "船舶探索装置",
    [165]     = "船舶其他装置",
    [166]     = "船首雕像",
    [167]     = "船舶装载装置",
    [169]     = "船舶音响装置",
    [170]     = "船舶推进器",
    [173]     = "合成时装",
    [175]     = "翅膀",
    [176]     = "巨型召唤兽",
    [191]     = "宠物",
    [197]     = "格罗亚",
    [199]     = "合成材料",
    [200]     = "觉醒材料",
    [203]     = "散弹枪",
    [204]     = "妖精管家装备",
    [206]     = "车辆装备",
    [9000002] = "增益道具",
    [9000003] = "特殊材料",
    [9000004] = "畜牧产品",
    [9000005] = "船舶设计",
    [9000006] = "机械组件卷轴",
    [9000007] = "船舶部件设计",
    [9000008] = "碎片",
    [9000009] = "音乐唱片",
    [9000010] = "强化材料",
    [9000011] = "车辆部件设计",
    [9000013] = "饲料",
    [9000014] = "未鉴定装备",
    [9000015] = "炼金专用油",
    [9000016] = "机械部件设计包",
    [9000017] = "钱袋子",
    [9000018] = "贵重宝箱",
    [9000019] = "货币",
    [9000020] = "合成时装",
    [9000021] = "特殊消耗品",
    [9000022] = "藏宝图",
    [9000023] = "宝藏猎人的消耗品",
    [9000024] = "水下设备",
    [9000025] = "战利品",
    [9000026] = "梦境图纸",
    [9000027] = "艺术品",
}

function S.Data.CategoryNames.Name(id)
    local key = tostring(id)
    local name = S.Data.CategoryNames[key]
    if name ~= nil then return name end
    -- The table stores numeric keys; callers (scan entries) pass string ids.
    -- A bare tostring lookup would miss them, so fall back to the numeric key.
    local numeric = tonumber(key)
    if numeric ~= nil then
        name = S.Data.CategoryNames[numeric]
        if name ~= nil then return name end
    end
    return "#" .. key
end
