------------------------------------------------------------------------
-- 中文维护注释：只读追踪目录，静态数据是身份 Authority，Feature 才拥有用户选择。
-- 原因：实时 Aura 列表无法管理当前未出现的状态，新用户也不应逐职业手工拼 ID。
-- 数据流：SkillEffects / CombatAbilityCatalog / Plates -> 一次编译索引 -> Feature 投影。
-- 兼容：控制标签沿用现有名称推断，仅用于导航，绝不把它升级成已确认 Debuff；欢乐为空。
-- 性能：本文件只在 TOC 加载时扫描数据；渲染和 50ms 更新只按索引查，不匹配 Tag/名称。
-- 导入是一次性复制；这里没有用户 State、Native 调用、自动补齐或后台任务。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
S.Data=S.Data or {}
local Library=S.Data.SkillEffects or {}
local Ability=S.Data.CombatAbilityCatalog or {}
local Plates=S.GameIds and S.GameIds.Plates or {}
local C={version=1,ByEffectId={},BySkillId={},ByTree={},ByTag={},ByKey={},Packs={},PackOrder={},
    counts={trees=0,skills=0,effects=0,control=0,hidden=0,cooldowns=0}}
S.Data.StatusTrackingCatalogV3=C
local function Pack(key,name,description)
    local pack={key=key,name=name,description=description or "",entries={}}
    C.Packs[key]=pack;C.PackOrder[#C.PackOrder+1]=key;return pack
end
local all=Pack("all","全部职业技能效果","未知极性进入 Auto；不猜 Buff/Debuff。")
local function Effect(id,name,kind)
    id=tonumber(id);if not id or id<=0 then return nil end
    if C.ByEffectId[id] then return C.ByEffectId[id] end
    local category=(kind=="buff" or kind=="debuff") and kind or "unknown"
    local row={id=id,key="effect:"..tostring(id),name=tostring(name or id),kind="effect",category=category,
        confidence=category=="unknown" and "unknown" or "verified_static",skillTrees={},skillIds={},tags={},
        source="SkillEffects",introducedVersion=1}
    C.ByEffectId[id],C.ByKey[row.key]=row,row;return row
end
for id,entry in pairs(Library.buffs or {}) do
    local row=Effect(id,entry.name,entry.kind);all.entries[#all.entries+1]=row
    row.tags.skill_effect=true;C.counts.effects=C.counts.effects+1
end
local trees={};for key in pairs(Library.trees or {}) do trees[#trees+1]=key end;table.sort(trees)
for _,slug in ipairs(trees) do
    local tree=Library.trees[slug]
    local pack=Pack("tree:"..slug,tostring(tree.name_cn or slug),"一次性导入该天赋效果；空目录不伪造数据。")
    local seen={};C.ByTree[slug]=pack.entries;C.counts.trees=C.counts.trees+1
    for skillId,skill in pairs(tree.skills or {}) do
        C.counts.skills=C.counts.skills+1
        local skillRows=C.BySkillId[skillId] or {};C.BySkillId[skillId]=skillRows
        for _,effect in ipairs(skill.effects or {}) do
            local row=C.ByEffectId[tonumber(effect.buffId)]
            if row then
                row.skillTrees[slug]=true;row.skillIds[skillId]=true
                skillRows[#skillRows+1]=row
                if not seen[row.id] then seen[row.id]=true;pack.entries[#pack.entries+1]=row end
            end
        end
    end
end
local control=Pack("control","控制类效果（候选）","沿用现有名称推断标签；不是已验证的负面极性。")
local hidden=Pack("hidden","隐藏状态与特殊规则","来源标签不等于 Buff/Debuff 分类。")
for id,row in pairs(C.ByEffectId) do
    local entry=Ability.ByBuffId and Ability.ByBuffId[id]
    if entry and type(entry.controlTypes)=="table" and #entry.controlTypes>0 then
        row.tags.control=true;row.controlConfidence="inferred_from_verified_effect_name"
        control.entries[#control.entries+1]=row;C.counts.control=C.counts.control+1
    end
end
local hiddenSeen={}
local corrections=Plates.EffectTimerCorrections and Plates.EffectTimerCorrections.hidden or {}
for id in pairs(corrections) do
    local row=Effect(tonumber(id),nil,"unknown");row.tags.hidden=true
    hidden.entries[#hidden.entries+1]=row;hiddenSeen[row.id]=true;C.counts.hidden=C.counts.hidden+1
end
for _,id in ipairs(Plates.MagicCircleBuffIds or {}) do
    local row=Effect(id,nil,"unknown");row.tags.special_rule=true
    if not hiddenSeen[id] then hidden.entries[#hidden.entries+1]=row;hiddenSeen[id]=true end
end
local glider=Pack("cooldown:skill","滑翔翼 / 翅膀技能 CD","只导入技能 ID；实际倒计时必须来自已验证的 Native 读数。")
local mate=Pack("cooldown:mate","坐骑 / 伙伴技能 CD","只导入技能 ID；不以静态 expectedSec 伪造倒计时。")
for _,seed in ipairs(Plates.ImportantCooldownEntries or {}) do
    local kind=seed.kind=="mate" and "mate" or "skill"
    local row={id=seed.id,key="cooldown:"..kind..":"..tostring(seed.id),name=tostring(seed.label or seed.id),
        kind=kind,category="cooldown",confidence="unverified",tags={cooldown=true},source="Plates discovery seed",introducedVersion=1}
    C.ByKey[row.key]=row;local pack=kind=="mate" and mate or glider
    pack.entries[#pack.entries+1]=row;C.counts.cooldowns=C.counts.cooldowns+1
end
-- 维护（2026-09-12，一键追踪入口）：旧 all 只有职业效果，隐藏/特殊规则另散在分类中。
-- Catalog 只汇总 ID，不启动冷却或改用户选择；旧包 key/version 原样保留，防止旧导入水位变化。
-- 新用户默认 recommended 是全部已知状态的去重并集；未完成技能 CD 不混进 Buff/Debuff 主入口。
local recommended=Pack("recommended","全部内置 Buff / Debuff（推荐）","一次加入全部内置状态；未知类型自动识别，取消项仅在主动重新导入时恢复。")
for _,row in pairs(C.ByEffectId) do recommended.entries[#recommended.entries+1]=row end
table.remove(C.PackOrder,#C.PackOrder);table.insert(C.PackOrder,1,"recommended")
for _,pack in pairs(C.Packs) do
    table.sort(pack.entries,function(a,b) return a.id<b.id end)
    pack.count=#pack.entries
end
for _,row in pairs(C.ByKey) do
    for tag in pairs(row.tags) do C.ByTag[tag]=C.ByTag[tag] or {};table.insert(C.ByTag[tag],row) end
end
function C:GetHealth()
    return {version=self.version,treeCount=self.counts.trees,skillCount=self.counts.skills,effectCount=self.counts.effects,
        controlCount=self.counts.control,hiddenCount=self.counts.hidden,cooldownSeedCount=self.counts.cooldowns}
end
