------------------------------------------------------------------------
-- Replicated Suite V3 - tools_reinforce_analysis Feature Authority
--
-- Phase 1 Batch B（2026-09-28）：从 features/rs_business_bridge.lua 机械搬迁。
-- 只改变源码边界，不改业务行为：Feature ID、Store ID/Schema、UpdateTopic、Demand owner、
-- Commands、Projection shape、ApiDependencies 与被搬迁前逐字一致。
--
-- 安全边界（搬迁后必须继续保持）：
--   * 逐槽位强化详情是 SPECIFIC_RUNTIME_BLOCKED：RU 客户端没有已验证的 equipSlotIndex 枚举来源，
--     GetReinforceInfo/GetMaterialInfo 的返回契约也未确认 —— 本文件**禁止**枚举或探测任何整数范围；
--   * 只允许无参 getter，以及参数是已导出 ESRA_* 属性常量的 getter；
--   * 强化写入类接口始终不可达；
--   * 本 Feature 的 SlotProbeRuntimeBlocked 标志是**本目录 acceptance 文件**
--     （rs_reinforce_analysis_acceptance.lua 的 v3_tools_reinforce_analysis_runtime_block_contract）
--     依赖的 blocker 级断言，必须保持 true，不能因为拆分而丢失。
--     中文维护注释（Phase 3 Batch F，2026-09-29）：该断言原先挂在 core/rs_foundation_gate.lua 的
--     v3_feature_truth_contract 上；Phase 3 已把它搬回 Feature 自己的 acceptance，Core 不再认识本 Feature。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local FSF = S.FeatureSliceFactory
if type(FSF) ~= "table" then error("FeatureSliceFactory unavailable for tools_reinforce_analysis") end
local Call, NewFeature = FSF.Call, FSF.NewFeature
-- 中文维护注释：X2EquipSlotReinforce 只作为能力宿主候选传入；导入 Authority 仍是
-- ApiDependencies → FeatureRuntime → S.ApiImports，本文件不自己 ImportAPI。
local ReinforceApi = rawget(_G, "X2EquipSlotReinforce")

------------------------------------------------------------------------
-- tools_reinforce_analysis: safe aggregate-only read projection.
--
-- PRODUCT_COMPLETION_MATRIX keeps per-slot reinforcement details runtime
-- blocked because the RU client exposes no verified equipSlotIndex enumerator
-- and the GetReinforceInfo/GetMaterialInfo payload contract is still unknown.
-- Never probe guessed integer ranges. Only parameter-free getters and getters
-- whose argument is an exported ESRA_* attribute constant are allowed here.
------------------------------------------------------------------------
local Reinforce = {
    attributes = {
        { key = "offence", label = "攻击", global = "ESRA_OFFENCE" },
        { key = "defence", label = "防御", global = "ESRA_DEFENCE" },
        { key = "support", label = "支援", global = "ESRA_SUPPORT" },
    },
}
function Reinforce:AppendFact(rows, key, name, facts, tone, statusText)
    rows[#rows + 1] = { key = key, name = name, text = table.concat(facts, " · "), statusText = statusText or "已识别", tone = tone or "default" }
end
NewFeature("tools_reinforce_analysis", {
    apiDependencies = {
        "X2EquipSlotReinforce:GetTotalReinforceLevel",
        "X2EquipSlotReinforce:GetAttributeTotalLevel", "X2EquipSlotReinforce:GetNextSetApplyLevel",
        "X2EquipSlotReinforce:HasNextSetEffect", "X2EquipSlotReinforce:SuitableLevelForEquipSlotReinforce",
        "X2EquipSlotReinforce:GetBundleEffectTopLevel",
    },
    read = function()
        local rows, failures, unresolved = {}, {}, 0
        local anyOk = false
        if ReinforceApi == nil then
            return rows, "unavailable", "X2EquipSlotReinforce 在当前客户端不可用（未导出）"
        end

        local okTotal, totalLevel, totalErr = Call("X2EquipSlotReinforce:GetTotalReinforceLevel", ReinforceApi, "GetTotalReinforceLevel")
        if okTotal == true then
            anyOk = true
            local total = tonumber(totalLevel)
            if total == nil then unresolved = unresolved + 1 end
            Reinforce:AppendFact(rows, "reinforce:total", "总强化等级", { total ~= nil and ("等级 " .. tostring(math.floor(total))) or "返回形态待 RU 实证" },
                total ~= nil and "green" or "warn", total ~= nil and "已识别" or "待确认")
        else
            failures[#failures + 1] = "总强化等级（" .. tostring(totalErr or "读取失败") .. "）"
        end

        local okSuit, suitLevel, suitErr = Call("X2EquipSlotReinforce:SuitableLevelForEquipSlotReinforce", ReinforceApi, "SuitableLevelForEquipSlotReinforce")
        if okSuit == true then
            anyOk = true
            local level = tonumber(suitLevel)
            if level == nil then unresolved = unresolved + 1 end
            Reinforce:AppendFact(rows, "reinforce:suitable", "装备强化适用等级", { level ~= nil and ("等级 " .. tostring(math.floor(level))) or "返回形态待 RU 实证" },
                "muted", level ~= nil and "已识别" or "待确认")
        else
            failures[#failures + 1] = "适用等级（" .. tostring(suitErr or "读取失败") .. "）"
        end

        for _, attribute in ipairs(Reinforce.attributes) do
            local attributeType = rawget(_G, attribute.global)
            if attributeType == nil then
                Reinforce:AppendFact(rows, "reinforce:attr:" .. attribute.key, attribute.label .. "系合计",
                    { "属性类型常量 " .. attribute.global .. " 未导出，无法查询" }, "muted", "未提供")
            else
                local okLevel, levelValue, levelErr = Call("X2EquipSlotReinforce:GetAttributeTotalLevel", ReinforceApi, "GetAttributeTotalLevel", attributeType)
                if okLevel ~= true then
                    failures[#failures + 1] = attribute.label .. "系合计（" .. tostring(levelErr or "读取失败") .. "）"
                else
                    anyOk = true
                    local facts = {}
                    local level = tonumber(levelValue)
                    if level == nil then unresolved = unresolved + 1 end
                    facts[#facts + 1] = level ~= nil and ("合计等级 " .. tostring(math.floor(level))) or "合计等级待 RU 实证"
                    local okNext, nextValue = Call("X2EquipSlotReinforce:GetNextSetApplyLevel", ReinforceApi, "GetNextSetApplyLevel", attributeType)
                    if okNext == true then
                        local nextLevel = tonumber(nextValue)
                        if nextLevel == nil then unresolved = unresolved + 1 end
                        facts[#facts + 1] = nextLevel ~= nil and ("下一套装档位 " .. tostring(math.floor(nextLevel))) or "下一套装档位待 RU 实证"
                    else
                        failures[#failures + 1] = attribute.label .. "系下一档位"
                    end
                    local okHas, hasValue = Call("X2EquipSlotReinforce:HasNextSetEffect", ReinforceApi, "HasNextSetEffect", attributeType)
                    if okHas == true then
                        if hasValue == true then facts[#facts + 1] = "存在下一档套装效果"
                        elseif hasValue == false then facts[#facts + 1] = "已达当前套装上限"
                        else unresolved = unresolved + 1; facts[#facts + 1] = "下一档套装效果状态待 RU 实证" end
                    else
                        failures[#failures + 1] = attribute.label .. "系套装效果状态"
                    end
                    Reinforce:AppendFact(rows, "reinforce:attr:" .. attribute.key, attribute.label .. "系合计", facts, "default",
                        level ~= nil and "已识别" or "待确认")
                end
            end
        end

        local okBundle, bundleTop = Call("X2EquipSlotReinforce:GetBundleEffectTopLevel", ReinforceApi, "GetBundleEffectTopLevel")
        if okBundle == true then
            anyOk = true
            local top = tonumber(bundleTop)
            if top == nil then unresolved = unresolved + 1 end
            Reinforce:AppendFact(rows, "reinforce:bundle", "组合效果上限", { top ~= nil and ("最高等级 " .. tostring(math.floor(top))) or "返回形态待 RU 实证" },
                "muted", top ~= nil and "已识别" or "待确认")
        else
            failures[#failures + 1] = "组合效果上限"
        end

        Reinforce:AppendFact(rows, "reinforce:slot_blocked", "逐槽位强化详情",
            { "Runtime Blocked：合法 equipSlotIndex 范围与 GetReinforceInfo/GetMaterialInfo 返回结构尚未通过 RU 实机验证；不会枚举或猜测槽位。" },
            "warn", "Runtime Blocked")

        local status = "ready"
        if not anyOk then status = "unavailable"
        elseif #failures > 0 or unresolved > 0 then status = "partial" end
        local notes = {}
        if #failures > 0 then notes[#notes + 1] = "读取失败：" .. table.concat(failures, "；") end
        if unresolved > 0 then notes[#notes + 1] = "聚合返回形态未识别 " .. tostring(unresolved) .. " 处（未伪造数值）" end
        notes[#notes + 1] = "逐槽位强化详情保持 Runtime Blocked；未执行任何 equipSlotIndex 探测或强化写入"
        return rows, status, table.concat(notes, "；")
    end,
})
-- 中文维护注释（Phase 1 Batch B）：core/rs_foundation_gate.lua 的 v3_feature_truth_contract 是
-- blocker 级检查，依赖这个标记为 true。搬迁后必须原地保留，删除它会让封包门禁整体失败。
S.Features.tools_reinforce_analysis.SlotProbeRuntimeBlocked = true
