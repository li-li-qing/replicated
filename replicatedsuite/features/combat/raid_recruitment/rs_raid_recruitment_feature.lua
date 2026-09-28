------------------------------------------------------------------------
-- Replicated Suite V3 - combat_raid_recruitment Feature Authority
--
-- Phase 1 Batch C（2026-09-28）：从 features/rs_business_bridge.lua 机械搬迁。
-- 只改变源码边界，不改业务行为：Feature ID、Store ID/Schema、UpdateTopic、Demand owner、
-- Commands（Create/Close/Accept/Reject）、Projection shape、ApiDependencies 全部与被搬迁前逐字一致。
--
-- Authority 边界：申请列表只读；创建/接受/拒绝仍因 RU 字段形态未验证而显式安全停用，
-- 本文件不得为了“功能完整”猜测 9 字段或 charIds 形态。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local FSF = S.FeatureSliceFactory
if type(FSF) ~= "table" then error("FeatureSliceFactory unavailable for combat_raid_recruitment") end
local Action, Call, Copy, Text, NewFeature = FSF.Action, FSF.Call, FSF.Copy, FSF.Text, FSF.NewFeature
local TeamApi = rawget(_G, "X2Team")

NewFeature("combat_raid_recruitment", { apiDependencies = { "X2Team:RaidRecruitDel", "X2Team:RaidApplicantList" },
    read = function(feature)
        local ok, list, callErr = Call("X2Team:RaidApplicantList", TeamApi, "RaidApplicantList")
        if not ok then
            if tostring(callErr or ""):find("capability cooldown active", 1, true) then
                -- A fast manual refresh must not erase the last proven applicant
                -- projection just because the official query pacing window is
                -- still active. Keep stale-but-honest rows and surface the gate.
                return Copy(feature.Authority.rows), "partial", "申请列表刷新冷却中；保留上一份投影：" .. tostring(callErr)
            end
            return {}, "unavailable", "招募申请列表不可用：" .. tostring(callErr or "native read failed")
        end
        local rows = {}
        for key, value in pairs(type(list) == "table" and list or {}) do rows[#rows + 1] = { key = "applicant:" .. tostring(key), name = Text(value and (value.name or value.characterName), key), text = Text(value and (value.level or value.gearScore), "申请人"), statusText = "只读申请", tone = "default" } end
        return rows, "partial", "当前只安全读取申请列表并允许关闭招募；创建 9 字段语义与 charIds 写入形态仍待 RU 验证"
    end,
    commands = {
        Create = function() return false, "创建招募已安全停用：RaidRecruitAdd 需要 type/subType/headcount/limitLevel/autoJoin/msg/hour/minute/limitGearPoint 共 9 个已验证字段" end,
        Close = function(_) return Action("X2Team:RaidRecruitDel", TeamApi, "RaidRecruitDel") end,
        Accept = function() return false, "接受申请已安全停用：RaidApplicantAccept(charIds) 的 charIds 形态尚未实机验证" end,
        Reject = function() return false, "拒绝申请已安全停用：RaidApplicantReject(charIds) 的 charIds 形态尚未实机验证" end,
    },
})
