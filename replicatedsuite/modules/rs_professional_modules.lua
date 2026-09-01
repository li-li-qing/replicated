------------------------------------------------------------------------
-- Replicated Suite - Professional module lifecycle adapters
-- Author: Replicated
-- Architecture baseline: Replicated Suite v1.1 / consolidated build
--
-- These adapters are the only lifecycle Authority for embedded DPS/Gear/
-- Healer/Plates. Historical Domain implementations remain intact inside their
-- isolated module sandboxes and keep their own domain persistence keys.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local M = S.ModuleManager
if M == nil then return end

if S.PerformanceMonitor ~= nil and type(S.PerformanceMonitor.MarkStartup) == "function" then S.PerformanceMonitor:MarkStartup("professional_end") end

local function RequireExport(moduleId, exportName)
    local sandbox = ReplicatedSuiteModuleSandbox
    local value = sandbox ~= nil and sandbox:GetExport(moduleId, exportName) or nil

    -- Lifecycle adapters consume only explicit, unique professional exports.
    -- Keep a root fallback here as a second compatibility fence for ArcheRage
    -- loaders whose chunk environment semantics differ from stock Lua.  The
    -- sandbox remains the primary Authority and repairs its own cache when it
    -- can resolve the root mirror.
    if value == nil then value = rawget(_G, tostring(exportName or "")) end
    if value ~= nil then return value end

    local detail = ""
    if sandbox ~= nil and type(sandbox.DescribeExport) == "function" then
        local info = sandbox:DescribeExport(moduleId, exportName)
        detail = " [mode=" .. tostring(info.environmentMode)
            .. ", env=" .. tostring(info.hasEnvironment)
            .. ", allowed=" .. tostring(info.allowed)
            .. ", local=" .. tostring(info.localPresent)
            .. ", root=" .. tostring(info.rootPresent) .. "]"
    end
    error(tostring(moduleId) .. " export unavailable: " .. tostring(exportName) .. detail)
end


local function OpenSuitePage(pageId, target)
    local section = target
    if pageId == "dps" then
        local map = { [1]="general", [2]="display", [3]="accuracy", [4]="rules", [5]="advanced", [6]="diag" }
        section = map[target] or target
    elseif pageId == "healer" then
        -- Historical observer/rule destinations now land on the user-facing
        -- BUFF condition-group section.  The semantic route itself is Host-owned.
        local map = {
            [1]="basic", [2]="buffs", [3]="buffs", [4]="team", [5]="cal",
            observe="buffs", rules="buffs", observer="buffs",
        }
        section = map[target] or target
    elseif pageId == "plates" then
        local map = {
            main="display", target="display", visibility="display",
            hud="layout", targetlayout="layout", appearance="colors",
            tracking="tracking", buffcap="buffcap", magiccircle="magiccircle",
            alerts="alerts", lines="lines", transfer="transfer", diag="diag",
        }
        section = map[target] or target
    elseif pageId == "gear" then
        local map = { plans="sets", slots="sets", quick="sets", behavior="sets" }
        section = map[target] or target
    end
    if S.UIHostManager ~= nil and type(S.UIHostManager.OpenProfessional) == "function" then
        return S.UIHostManager:OpenProfessional(pageId, section) == true
    end
    return false
end

local function RegisterProfessional(def)
    M:Register({
        Id = def.Id,
        Name = def.Name,
        Category = "combat",
        DefaultEnabled = false,
        Professional = true,
        HudIds = def.HudIds or {},
        DataScope = def.DataScope or "character",
        Initialize = function(self)
            local domain = RequireExport(def.Id, def.Export)
            self._domain = domain
            if domain.BootError ~= nil then error(tostring(domain.BootError)) end
            if type(domain.Boot) == "table" and domain.Boot.error ~= nil then error(tostring(domain.Boot.error)) end
            if def.Initialize ~= nil then return def.Initialize(domain) end
            return true
        end,
        Enable = function(self)
            local ok = def.Enable(self._domain or RequireExport(def.Id, def.Export))
            if ok ~= false then
                if S.Observation ~= nil then S.Observation:Subscribe("professional:"..def.Id, def.ObservationFields or {}) end
                -- Demand-driven Target Detection Authority: the module consumes
                -- shared current-target state instead of re-issuing the same reads.
                if def.TargetServiceFields ~= nil and S.TargetService ~= nil and type(S.TargetService.Subscribe) == "function" then
                    S.TargetService:Subscribe("professional:"..def.Id, def.TargetServiceFields)
                end
            end
            return ok
        end,
        Disable = function(self, reason)
            if S.Observation ~= nil then S.Observation:Unsubscribe("professional:"..def.Id) end
            if S.TargetService ~= nil and type(S.TargetService.Unsubscribe) == "function" then
                S.TargetService:Unsubscribe("professional:"..def.Id)
            end
            return def.Disable(self._domain or RequireExport(def.Id, def.Export), reason)
        end,
        OpenSettings = function(self)
            return def.Open(self._domain or RequireExport(def.Id, def.Export))
        end,
        DescribeRuntime = function(self)
            local domain = self._domain or (ReplicatedSuiteModuleSandbox and ReplicatedSuiteModuleSandbox:GetExport(def.Id, def.Export))
            local result = {
                embedded = true,
                version = domain and tostring(domain.Version or "") or "",
                bootError = domain and domain.BootError or nil,
            }
            if def.Describe ~= nil and domain ~= nil then
                local extra = def.Describe(domain)
                if type(extra) == "table" then for key, value in pairs(extra) do result[key] = value end end
            end
            return result
        end,
    })

    if S.SettingsRegistry ~= nil and type(S.SettingsRegistry.RegisterSetting) == "function" then
        for _, setting in ipairs(def.SearchSettings or {}) do
            local settingId = tostring(setting.Id or "setting")
            local settingTitle = tostring(setting.Title or settingId)
            local settingKeywords = tostring(setting.Keywords or "")
            local settingTarget = setting.Target
            S.SettingsRegistry:RegisterSetting(def.Id, settingId, settingTitle, settingKeywords, function()
                local domain = RequireExport(def.Id, def.Export)
                if type(def.OpenSearch) == "function" then
                    return def.OpenSearch(domain, settingTarget)
                end
                return def.Open(domain)
            end)
        end
    end
end

RegisterProfessional({
    Id = "gear", Name = "一键换装", Export = "ReplicatedGear", HudIds = {"gear_quick"}, DataScope = "character", ObservationFields = {},
    SearchSettings = {
        { Id="plans", Title="换装方案与快捷按钮", Keywords="换装 方案 名称 新建 获取当前配置 保存 删除 快捷按钮 武器 防具 弓箭 乐器 称号", Target="sets" },
        { Id="slots", Title="换装参与槽位", Keywords="参与槽位 部位 武器 防具 主手 副手 弓箭 乐器 空槽 饰品 称号 防具饰品 仅称号", Target="sets" },
        { Id="behavior", Title="换装快捷 / 战斗行为", Keywords="快捷按钮 称号 战斗 延后 切换行为", Target="sets" },
    },
    Enable = function(G)
        if G.Runtime == nil or type(G.Runtime.EnableModuleRuntime) ~= "function" then return false end
        return G.Runtime:EnableModuleRuntime()
    end,
    Disable = function(G, reason)
        if G.Runtime ~= nil and type(G.Runtime.DisableModuleRuntime) == "function" then
            return G.Runtime:DisableModuleRuntime(reason)
        end
        return true
    end,
    OpenSearch = function(G, target) return OpenSuitePage("gear", target or "sets") end,
    Open = function(G) return OpenSuitePage("gear") end,
    Describe = function(G)
        return { ready = G.Ready == true, busy = G.Runtime and G.Runtime.busy == true or false }
    end,
})

RegisterProfessional({
    Id = "plates", Name = "BUFF显示", Export = "ReplicatedPlates", HudIds = {"plates_target", "plates_player"}, DataScope = "account", ObservationFields = {"UnitName","GetUnitId","UnitHealth","UnitMaxHealth","UnitDistance","buff"},
    TargetServiceFields = {"vitals","distance","profession","gear"},
    SearchSettings = {
        { Id="hud", Title="BUFF显示 HUD布局", Keywords="目标 自己 HUD 布局 位置 组件 职业 装等 距离 目标的目标 施法 重要冷却 图标 数量 间距", Target="layout" },
        { Id="tracking", Title="Buff / Debuff追踪", Keywords="Buff Debuff 隐藏状态 追踪 ID 按ID追加 PVP发现 冷却 状态", Target="tracking" },
        { Id="buffcap", Title="buff上限追踪", Keywords="buff 上限 满buff 挤掉 歌舞 疾跑 提醒 顶部", Target="buffcap" },
        { Id="alerts", Title="战斗警报 / Boss机制", Keywords="黑龙 大地强击 死亡之海 鳞片 撞鬼 下水 警报 倒计时 世界boss 旋涡 预览", Target="alerts" },
        { Id="lines", Title="单位连线", Keywords="连线 点 目标 目标的目标 追踪目标 方向 起点 距离 预览 追踪 连接线", Target="lines" },
{ Id="magiccircle", Title="魔法阵距离", Keywords="魔法阵 距离 圆心 出圈 19037 25850 25851 贴头", Target="magiccircle" },
        { Id="visibility", Title="目标/自己显示", Keywords="显示 目标HUD 自己HUD 可见 隐藏", Target="display" },
        { Id="appearance", Title="Buff状态外观", Keywords="Buff Debuff Hidden 冷却 图标 字体 数量 方向 间距 外观", Target="colors" },
        { Id="diagnostics", Title="BUFF显示诊断", Keywords="诊断 刷新 重置 追踪计数 HUD", Target="diag" },
    },
    OpenSearch = function(P, target) return OpenSuitePage("plates", target) end,
    Enable = function(P)
        if P.Runtime == nil or type(P.Runtime.StartModule) ~= "function" then return false end
        return P.Runtime:StartModule()
    end,
    Disable = function(P, reason)
        if P.Runtime ~= nil and type(P.Runtime.Stop) == "function" then return P.Runtime:Stop(reason) end
        return true
    end,
    Open = function(P) return OpenSuitePage("plates") end,
    Describe = function(P)
        return { ready = P.Ready == true, running = P.Runtime and P.Runtime.running == true or false }
    end,
})

RegisterProfessional({
    Id = "healer", Name = "治疗辅助 / 团队高亮", Export = "ReplicatedHealerModule", DataScope = "character", ObservationFields = {"UnitName","UnitHealth","UnitMaxHealth","UnitDistance","buff"},
    SearchSettings = {
        { Id="healing", Title="治疗距离 / 血量阈值", Keywords="治疗距离 最大治疗距离 低血量 紧急血量 阈值 团队高亮", Target="basic" },
        { Id="score", Title="救援评分 / 权重 / 等级", Keywords="评分 权重 血量 距离 缺失 保护 关注 高危 紧急 等级颜色", Target="score" },
        { Id="color", Title="治疗显示颜色 RGBA", Keywords="颜色 RGBA 范围底色 低血量 紧急", Target="colors" },
        { Id="buff", Title="治疗 Buff追踪", Keywords="Buff颜色 Buff追踪 状态 追踪 ID RGBA", Target="buffs" },
        { Id="observer", Title="治疗状态扫描 / 条件组", Keywords="扫描自身 当前目标 敌人 Buff Debuff Hidden 状态 追加 条件组", Target="buffs" },
        { Id="rules", Title="BUFF条件组", Keywords="条件组 Buff Debuff Hidden 状态 ID 颜色 启用 扫描自身 当前目标", Target="buffs" },
        { Id="team", Title="团队高亮 / 头顶标记", Keywords="团队高亮 头顶标记 名次 字号 大小 距离底色 团队页", Target="team" },
        { Id="roles", Title="职责评分 / 手动职责", Keywords="职责 主坦 副坦 治疗 玩家 覆盖 评分", Target="roles" },
        { Id="calibration", Title="团队列表校准", Keywords="团队 校准 覆盖区域 位置 坐标 距离", Target="cal" },
    },
    OpenSearch = function(H, target) return OpenSuitePage("healer", target) end,
    Initialize = function(H)
        local boot = RequireExport("healer", "ReplicatedHealerBoot")
        if boot.error ~= nil then error(tostring(boot.error)) end
        return true
    end,
    Enable = function(H)
        return type(H.EnableRuntime) == "function" and H:EnableRuntime() or false
    end,
    Disable = function(H, reason)
        if tostring(reason or "") ~= "startup_disabled" and type(H.SaveSuiteSettings) == "function" then
            local saved, saveErr = H:SaveSuiteSettings()
            if saved ~= true then return false, "治疗辅助设置收尾保存失败：" .. tostring(saveErr or "unknown") end
        end
        return type(H.DisableRuntime) ~= "function" or H:DisableRuntime()
    end,
    Open = function(H) return OpenSuitePage("healer") end,
    Describe = function(H)
        return type(H.DescribeRuntime) == "function" and H:DescribeRuntime() or {}
    end,
})

RegisterProfessional({
    Id = "dps",
    Name = "伤害统计",
    Export = "ReplicatedDps",
    HudIds = {"dps_friendly", "dps_enemy"},
    DataScope = "character",
    ObservationFields = {"UnitName","GetUnitId","GetUnitNameById","team"},
    SearchSettings = {
        { Id="runtime", Title="DPS 数据范围 / 运行", Keywords="启用 数据范围 团队 附近 PVP PVE 友军 敌军", Target=1 },
        { Id="display", Title="排行榜人数 / 透明度 / 缩放", Keywords="排行榜人数 排行榜显示人数上限 透明度 缩放 简化模式 百分比 始终显示自己", Target=2 },
        { Id="accuracy", Title="DPS 身份与准确率", Keywords="准确率 中文 NPC 公会 身份 玩家 召唤物 关系", Target=3 },
        { Id="rules", Title="友军敌军名单 / 规则", Keywords="名单 规则 友军 敌军 Boss 忽略 人工纠错", Target=4 },
        { Id="advanced", Title="DPS 高级设置", Keywords="高级 个人窗口 重放 缓存 性能 持久化 保存周期", Target=5 },
        { Id="diagnostics", Title="DPS 诊断", Keywords="诊断 Debug API 统计处理中 backlog", Target=6 },
    },
    OpenSearch = function(D, target) return OpenSuitePage("dps", target) end,
    Enable = function(D)
        if D.Runtime == nil or type(D.Runtime.Start) ~= "function" then return false end
        D.State.config.enabled = true
        D.State.runtime.paused = false
        if type(D.MarkConfigDirty) == "function" then D.MarkConfigDirty() end
        D.Runtime:Start()
        if D.UI ~= nil and type(D.UI.ApplyVisibility) == "function" then D.UI:ApplyVisibility() end
        if D.UI ~= nil and type(D.UI.RefreshConfig) == "function" then D.UI:RefreshConfig() end
        return D.Runtime.started == true
    end,
    Disable = function(D, reason)
        -- Suite ModuleManager is the lifecycle Authority. A shutdown is only a
        -- runtime teardown, not a user request to persist DPS disabled. Mutating
        -- config.enabled before Runtime:Stop() would make the new stop-flush save
        -- a false OFF value every logout. User/fault disables still update the
        -- standalone-compatible DPS config normally.
        if tostring(reason or "") ~= "shutdown" then
            if D.State ~= nil and D.State.config ~= nil then D.State.config.enabled = false end
            if type(D.MarkConfigDirty) == "function" then D.MarkConfigDirty() end
        end
        if D.State ~= nil and D.State.runtime ~= nil then D.State.runtime.paused = true end
        if D.Runtime ~= nil and type(D.Runtime.Stop) == "function" then D.Runtime:Stop(reason) end
        if D.UI ~= nil and type(D.UI.ApplyVisibility) == "function" then D.UI:ApplyVisibility() end
        if D.UI ~= nil and type(D.UI.RefreshConfig) == "function" then D.UI:RefreshConfig() end
        return true
    end,
    Open = function(D) return OpenSuitePage("dps") end,
    Describe = function(D)
        local result = {
            ready = D.Boot ~= nil and D.Boot.error == nil,
            running = D.Runtime ~= nil and D.Runtime.started == true,
            scopeMode = D.State and D.State.config and tostring(D.State.config.scopeMode or "team") or "team",
            paused = D.State and D.State.runtime and D.State.runtime.paused == true or false,
        }
        if D.Runtime ~= nil and type(D.Runtime.DescribeScope) == "function" then
            local scope = D.Runtime:DescribeScope()
            if type(scope) == "table" then
                for key, value in pairs(scope) do result[key] = value end
            end
        end
        return result
    end,
})

------------------------------------------------------------------------
-- Suite HUD Authority for professional long-lived surfaces.
------------------------------------------------------------------------
local H = S.HudManager
if H ~= nil then
    local gear = ReplicatedSuiteModuleSandbox and ReplicatedSuiteModuleSandbox:GetExport("gear", "ReplicatedGear") or nil
    if gear ~= nil and gear.UI ~= nil then
        H:Register({
            Id = "gear_quick", Title = "一键换装快捷栏", ShortTitle = "换装", ModuleId = "gear",
            DefaultVisible = true, SupportsCollapsed = false, SupportsResize = false, SupportsFont = false, SupportsBackground = false, SupportsCompact = false,
            DefaultAnchorH = "LEFT", DefaultAnchorV = "TOP", DefaultOffsetX = 16, DefaultOffsetY = 230,
            Instance = {
                ApplyEffectiveVisibility = function(_, effective)
                    if type(gear.UI.SetSuiteHudVisible) == "function" then gear.UI:SetSuiteHudVisible(effective == true) end
                end,
                ApplyLock = function(_, effectiveLocked)
                    if type(gear.UI.SetSuiteHudLocked) == "function" then gear.UI:SetSuiteHudLocked(effectiveLocked == true) end
                end,
                ApplyEditMode = function() end,
                OnMetricsChanged = function()
                    if type(gear.UI.ApplySuiteQuickButtonPositions) == "function" then gear.UI:ApplySuiteQuickButtonPositions() end
                    local config = gear.UI.windows and gear.UI.windows.config or nil
                    if config ~= nil and config.IsVisible ~= nil and config:IsVisible()
                        and S.Layout ~= nil and type(S.Layout.EnsureWidgetVisible) == "function" then
                        S.Layout:EnsureWidgetVisible(config, { onlyWhenVisible = true })
                    end
                end,
                GetSnapWindows = function() return gear.UI.quickButtons or {} end,
                CaptureProfileState = function(_, placement)
                    if type(gear.UI.CaptureSuiteHudProfile) == "function" then return gear.UI:CaptureSuiteHudProfile(placement) end
                    return true
                end,
                ApplyProfileState = function(_, placement)
                    if type(gear.UI.ApplySuiteHudProfile) == "function" then return gear.UI:ApplySuiteHudProfile(placement) end
                    return true
                end,
                ResetPosition = function()
                    if type(gear.UI.ResetSuiteHudPosition) == "function" then return gear.UI:ResetSuiteHudPosition() end
                    return true
                end,
                Recover = function()
                    for _, button in pairs(gear.UI.quickButtons or {}) do
                        if button ~= nil and button.CorrectOffsetByScreen ~= nil then pcall(function() button:CorrectOffsetByScreen() end) end
                    end
                    return true
                end,
            },
        })
    end

    local plates = ReplicatedSuiteModuleSandbox and ReplicatedSuiteModuleSandbox:GetExport("plates", "ReplicatedPlates") or nil
    if plates ~= nil and plates.UI ~= nil and plates.Storage ~= nil then
        local function RegisterPlatesHud(id, title, scope, y)
            local legacy = plates.Storage:GetPlate(scope)
            H:Register({
                Id = id, Title = title, ShortTitle = scope == "target" and "目标BUFF" or "自身BUFF", ModuleId = "plates",
                DefaultVisible = type(legacy) == "table" and legacy.enabled == true or false,
                SupportsCollapsed = false, SupportsResize = false, SupportsFont = false, SupportsBackground = false, SupportsCompact = false,
                DefaultAnchorH = "LEFT", DefaultAnchorV = "TOP", DefaultOffsetX = 16, DefaultOffsetY = y,
                Instance = {
                    ApplyEffectiveVisibility = function(_, effective, preferred)
                        if type(plates.UI.SetSuiteHudEffectiveVisible) == "function" then
                            plates.UI:SetSuiteHudEffectiveVisible(scope, effective == true, preferred == true)
                        end
                    end,
                    ApplyLock = function(_, effectiveLocked)
                        if type(plates.UI.SetSuiteHudLocked) == "function" then plates.UI:SetSuiteHudLocked(scope, effectiveLocked == true) end
                    end,
                    ApplyEditMode = function() end,
                    OnMetricsChanged = function()
                        if type(plates.UI.ApplyPlateLayout) == "function" then plates.UI:ApplyPlateLayout(scope) end
                    end,
                    CaptureProfileState = function(_, placement)
                        if type(plates.UI.CaptureSuiteHudProfile) == "function" then return plates.UI:CaptureSuiteHudProfile(scope, placement) end
                        return true
                    end,
                    ApplyProfileState = function(_, placement)
                        if type(plates.UI.ApplySuiteHudProfile) == "function" then return plates.UI:ApplySuiteHudProfile(scope, placement) end
                        return true
                    end,
                    ResetPosition = function()
                        if type(plates.UI.ResetSuiteHudPosition) == "function" then return plates.UI:ResetSuiteHudPosition(scope) end
                        return true
                    end,
                    Recover = function()
                        if type(plates.UI.ResetSuiteHudPosition) == "function" then return plates.UI:ResetSuiteHudPosition(scope) end
                        return true
                    end,
                },
            })
        end
        RegisterPlatesHud("plates_target", "BUFF显示 - 目标 HUD", "target", 150)
        RegisterPlatesHud("plates_player", "BUFF显示 - 自己 HUD", "player", 260)

        -- watchtarget aggro/distance mini-windows (report 七-C). Two separate
        -- HUD registrations, independent visibility. rp_runtime drives the
        -- actual window visibility from storage; HudManager is the outer
        -- visible/locked/profile Authority exactly like the plates HUDs.
        local function RegisterWatchHud(id, title, kind, x, y)
            H:Register({
                Id = id, Title = title, ShortTitle = kind == "aggro" and "仇恨窗" or "距离窗",
                ModuleId = "plates",
                DefaultVisible = false, -- storage switch (aggroEnabled/distEnabled) is the real gate
                SupportsCollapsed = false, SupportsResize = false, SupportsFont = false,
                SupportsBackground = false, SupportsCompact = false,
                DefaultAnchorH = "LEFT", DefaultAnchorV = "TOP", DefaultOffsetX = x, DefaultOffsetY = y,
                Instance = {
                    ApplyEffectiveVisibility = function(_, effective)
                        -- Runtime lane reconciles visible <-> storage switch on
                        -- its next tick; nothing to do synchronously here.
                    end,
                    ApplyLock = function() end,
                    ApplyEditMode = function() end,
                    OnMetricsChanged = function() end,
                    CaptureProfileState = function() return true end,
                    ApplyProfileState = function() return true end,
                    ResetPosition = function() return true end,
                    Recover = function() return true end,
                },
            })
        end
        RegisterWatchHud("plates_watch_aggro", "追踪目标 - 仇恨窗口", "aggro", 16, 400)
        RegisterWatchHud("plates_watch_dist", "追踪目标 - 距离窗口", "dist", 260, 400)

        -- Combat alert window (report 七-方案A). The alert host itself is owned
        -- by the shared S.Services.Alerts channel; HudManager only drives the
        -- outer visibility. The alert service is started/stopped with the
        -- plates module (see module Enable/Disable chain in plates runtime).
        H:Register({
            Id = "plates_alert", Title = "战斗警报 - 屏幕提醒", ShortTitle = "警报",
            ModuleId = "plates",
            DefaultVisible = false,
            SupportsCollapsed = false, SupportsResize = false, SupportsFont = false,
            SupportsBackground = false, SupportsCompact = false,
            DefaultAnchorH = "CENTER", DefaultAnchorV = "TOP", DefaultOffsetX = 0, DefaultOffsetY = -120,
            Instance = {
                ApplyEffectiveVisibility = function(_, effective)
                    local alerts = S.Services and S.Services.Alerts
                    if effective ~= true and alerts ~= nil and type(alerts.Hide) == "function" then
                        alerts:Hide()
                    end
                end,
                ApplyLock = function() end,
                ApplyEditMode = function() end,
                OnMetricsChanged = function() end,
                CaptureProfileState = function() return true end,
                ApplyProfileState = function() return true end,
                ResetPosition = function() return true end,
                Recover = function() return true end,
            },
        })

        -- One-time consolidation repair: early Suite builds introduced an
        -- independent HUD visibility Authority while legacy Plates also defaulted
        -- both HUDs off. If both Suite preferences are still off, restore them to
        -- visible once. Module Enabled remains an independent gate, and every
        -- subsequent user toggle is preserved.
        S.State.settings = type(S.State.settings) == "table" and S.State.settings or {}
        if S.State.settings.platesHudVisibilityRepairV1011 ~= true then
            local targetPlacement = H:GetPlacement("plates_target")
            local playerPlacement = H:GetPlacement("plates_player")
            if targetPlacement ~= nil and playerPlacement ~= nil
                and targetPlacement.visible ~= true and playerPlacement.visible ~= true then
                H:SetVisible("plates_target", true, false)
                H:SetVisible("plates_player", true, false)
            end
            S.State.settings.platesHudVisibilityRepairV1011 = true
            if S.Storage ~= nil and type(S.Storage.RequestSave) == "function" then S.Storage:RequestSave() end
            if S.State ~= nil and type(S.State.MarkDirty) == "function" then S.State:MarkDirty("hud") end
        end
    end

    local dps = ReplicatedSuiteModuleSandbox and ReplicatedSuiteModuleSandbox:GetExport("dps", "ReplicatedDps") or nil
    if dps ~= nil and dps.UI ~= nil then
        local function RegisterDpsHud(id, title, side, y)
            local showKey = side == "friendly" and "showFriendly" or "showEnemy"
            local lockKey = side == "friendly" and "friendlyLocked" or "enemyLocked"
            local legacyConfig = dps.State and dps.State.config or {}
            H:Register({
                Id = id, Title = title, ShortTitle = side == "friendly" and "DPS友" or "DPS敌", ModuleId = "dps",
                -- First consolidated launch migrates the old DPS UI preference.
                -- Once Suite storage exists, State:ApplySaved overwrites these
                -- bootstrap defaults and HudManager remains the sole Authority.
                DefaultVisible = legacyConfig[showKey] ~= false,
                DefaultLocked = legacyConfig[lockKey] == true,
                SupportsCollapsed = false, SupportsResize = true, SupportsFont = false, SupportsBackground = false, SupportsCompact = false,
                DefaultAnchorH = "RIGHT", DefaultAnchorV = "TOP", DefaultOffsetX = 20, DefaultOffsetY = y,
                Instance = {
                    ApplyEffectiveVisibility = function(_, effective, preferred)
                        if type(dps.UI.SetSuiteHudEffectiveVisible) == "function" then
                            dps.UI:SetSuiteHudEffectiveVisible(side, effective == true, preferred == true)
                        end
                    end,
                    ApplyLock = function(_, effectiveLocked, preferredLocked)
                        if type(dps.UI.SetSuiteHudLocked) == "function" then dps.UI:SetSuiteHudLocked(side, effectiveLocked == true, preferredLocked == true) end
                    end,
                    ApplyEditMode = function(_, enabled)
                        if type(dps.UI.ApplySuiteEditMode) == "function" then dps.UI:ApplySuiteEditMode(enabled == true) end
                    end,
                    CaptureProfileState = function(_, placement)
                        if type(dps.UI.CaptureSuiteHudProfile) == "function" then return dps.UI:CaptureSuiteHudProfile(side, placement) end
                        return true
                    end,
                    ApplyProfileState = function(_, placement)
                        if type(dps.UI.ApplySuiteHudProfile) == "function" then return dps.UI:ApplySuiteHudProfile(side, placement) end
                        return true
                    end,
                    ApplyLayout = function()
                        if type(dps.UI.LayoutQuickWindow) == "function" then dps.UI:LayoutQuickWindow(side) end
                    end,
                    OnMetricsChanged = function()
                        if type(dps.UI.LayoutQuickWindow) == "function" then dps.UI:LayoutQuickWindow(side) end
                    end,
                    GetSnapWindows = function()
                        local window = dps.UI.windows and dps.UI.windows[side] or nil
                        return window ~= nil and { window } or {}
                    end,
                    ResetPosition = function()
                        local rect = dps.State and dps.State.ui and dps.State.ui[side] or nil
                        local defaults = dps.Defaults and dps.Defaults.ui and dps.Defaults.ui[side] or nil
                        if type(rect) == "table" and type(defaults) == "table" then
                            rect.anchorH = defaults.anchorH or "LEFT"; rect.anchorV = defaults.anchorV or "TOP"
                            rect.offsetX = tonumber(defaults.offsetX) or 12; rect.offsetY = tonumber(defaults.offsetY) or 160
                            rect.userMoved = false
                        end
                        if type(dps.UI.LayoutQuickWindow) == "function" then dps.UI:LayoutQuickWindow(side) end
                        if type(dps.MarkUiDirty) == "function" then dps.MarkUiDirty() end
                        return true
                    end,
                    ResetSize = function()
                        local rect = dps.State and dps.State.ui and dps.State.ui[side] or nil
                        local defaults = dps.Defaults and dps.Defaults.ui and dps.Defaults.ui[side] or nil
                        if type(rect) == "table" and type(defaults) == "table" then
                            rect.width = tonumber(defaults.width) or rect.width
                            rect.height = tonumber(defaults.height) or rect.height
                            rect.visualScale = tonumber(defaults.visualScale) or 1.0
                        end
                        if type(dps.UI.LayoutQuickWindow) == "function" then dps.UI:LayoutQuickWindow(side) end
                        if type(dps.MarkUiDirty) == "function" then dps.MarkUiDirty() end
                        return true
                    end,
                    Recover = function()
                        local window = dps.UI.windows and dps.UI.windows[side] or nil
                        if window ~= nil and window.CorrectOffsetByScreen ~= nil then
                            pcall(function() window:CorrectOffsetByScreen() end)
                            if dps.Util ~= nil and type(dps.Util.StoreRect) == "function" then
                                dps.Util.StoreRect(dps.State.ui[side], window)
                            end
                        elseif type(dps.UI.LayoutQuickWindow) == "function" then
                            dps.UI:LayoutQuickWindow(side)
                        end
                        if type(dps.MarkUiDirty) == "function" then dps.MarkUiDirty() end
                        return true
                    end,
                },
            })
        end
        RegisterDpsHud("dps_friendly", "DPS 友军排行", "friendly", 80)
        RegisterDpsHud("dps_enemy", "DPS 敌军排行", "enemy", 330)
    end
end
