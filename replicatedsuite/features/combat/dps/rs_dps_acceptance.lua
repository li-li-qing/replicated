------------------------------------------------------------------------
-- Replicated Suite V3 - DPS Acceptance
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local G = S.FoundationGate
local F = S.Features and S.Features.DPS or nil
if type(G) ~= "table" or type(G.RegisterSequenceCase) ~= "function" or type(F) ~= "table" then return end

local function Fail(message) return false, tostring(message or "dps_acceptance_failed") end

G:RegisterSequenceCase("v3_m16_dps_shared_analytics_contract", function()
    local meta = S.FeatureRegistry and S.FeatureRegistry:Get("combat_stats") or nil
    if meta == nil or tostring(meta.status) ~= "migrated_m16" or tostring(meta.lifecycle) ~= "independent"
        or tostring(meta.authority):find("v3.dps", 1, true) == nil or meta.widgetCapable ~= true or meta.settingsCapable ~= true then
        return Fail("metadata_contract")
    end
    if meta.defaultEnabled == true then return Fail("quiet_default_contract") end
    if S.FeatureRuntime == nil or S.FeatureRuntime:IsImplemented("combat_stats") ~= true then return Fail("implementation_missing") end

    local store = S.Persistence and S.Persistence:GetStore(F.StoreId or "v3.dps") or nil
    if store == nil or tostring(store.owner or "") ~= "v3.dps"
        or tostring(store.scope or "") ~= tostring(S.Persistence.Scope.Account)
        or tonumber(store.schemaVersion) ~= 3 then
        return Fail("store_contract")
    end
    if type(F.State) ~= "table" or type(F.State.widgetWindow) ~= "table" then return Fail("widget_state_contract") end

    if F.Demand == nil or type(F.Demand.Acquire) ~= "function" or type(F.ReconcileDemand) ~= "function"
        or type(F.GetSettings) ~= "function" or type(F.ApplySettingFromBinding) ~= "function" or type(F.ClearStats) ~= "function"
        or type(F.IsBossName) ~= "function" or type(F.GetBossNames) ~= "function"
        or type(F.DeleteBossName) ~= "function" then
        return Fail("lifecycle_contract")
    end
    if type(F.Domain) ~= "table" or type(F.Domain.OnCombatFact) ~= "function"
        or type(F.Domain.ClearStats) ~= "function" or type(F.Domain.ResetTransient) ~= "function"
        or type(F.Domain.ReplayPending) ~= "function" or type(F.Domain.GetProjection) ~= "function"
        or (tonumber(F.Domain.version) or 0) < 7 or type(F.Domain.GetActorDetail) ~= "function" or type(F.GetActorDetail) ~= "function"
        or type(F.GetProjection) ~= "function" or type(F.Commands) ~= "table"
        or type(F.Commands.ApplySettingFromBinding) ~= "function" or type(F.Commands.MarkStoreDirty) ~= "function"
        or type(F.Commands.SetEnabled) ~= "function" or type(F.Commands.Clear) ~= "function"
        or type(F.Commands.SetMode) ~= "function" or type(F.Commands.SetSide) ~= "function"
        or type(F.Commands.SetMetric) ~= "function" or type(F.Commands.GetActorDetail) ~= "function"
        or type(F.Commands.SetDisplayRows) ~= "function" or type(F.Commands.SetAlwaysShowSelf) ~= "function" then
        return Fail("domain_contract")
    end

    local settings = F:GetSettings()
    if type(settings) ~= "table" or (tostring(settings.mode) ~= "PVE" and tostring(settings.mode) ~= "PVP")
        or (tostring(settings.side) ~= "friendly" and tostring(settings.side) ~= "enemy")
        or (tostring(settings.metric) ~= "damage" and tostring(settings.metric) ~= "taken" and tostring(settings.metric) ~= "heal")
        or tonumber(settings.displayRows) == nil or type(settings.alwaysShowSelf) ~= "boolean" then
        return Fail("settings_contract")
    end
    if tonumber(settings.displayRows) < 1 or tonumber(settings.displayRows) > 150 then return Fail("settings_range") end

    local proxyCatalog = S.Data and S.Data.CombatSourceProxyCatalog or nil
    local fountain = type(proxyCatalog) == "table" and type(proxyCatalog.Get) == "function" and proxyCatalog:Get("healing_fountain") or nil
    if type(proxyCatalog) ~= "table" or (tonumber(proxyCatalog.version) or 0) < 1
        or type(fountain) ~= "table" or tostring(fountain.kind) ~= "PLAYER_PLACED_SKILL_PROXY"
        or tostring(fountain.ownerAttribution) ~= "UNAVAILABLE_NO_RELIABLE_OWNER_LINK" then return Fail("proxy_catalog_contract") end

    local relation = S.Services and S.Services.CombatRelationV3 or nil
    local roster = S.Services and S.Services.TeamRosterV3 or nil
    local bus = S.Services and S.Services.CombatEventBusV3 or nil
    local analytics = S.Services and S.Services.CombatAnalyticsV3 or nil
    if type(relation) ~= "table" or type(relation.ApplyKind) ~= "function" or type(relation.RecordCombatFact) ~= "function" then
        return Fail("relation_contract")
    end
    if type(roster) ~= "table" or type(roster.AcquireConsumer) ~= "function" or type(roster.IsMemberName) ~= "function" then
        return Fail("team_roster_contract")
    end
    if type(bus) ~= "table" or type(bus.Subscribe) ~= "function" then return Fail("bus_contract") end
    if type(analytics) ~= "table" or type(analytics.AcquireConsumer) ~= "function" then return Fail("analytics_contract") end
    if F.analyticsMetricRegistered == true and analytics:GetMetric("dps_core") == nil then return Fail("dps_metric_registration") end
    if tonumber(F.Domain.version) < 5 or tonumber(relation.version) < 3 or tonumber(roster.version) < 2 or tonumber(bus.version) < 6 then
        return Fail("dps_dependency_version_contract")
    end

    if S.UIV3 == nil or S.UIV3.PageHost == nil or S.UIV3.PageHost.factories["combat.stats"] == nil then
        return Fail("page_contract")
    end
    local widget = S.UIV3.WidgetHost and S.UIV3.WidgetHost:GetSpec("combat.dps") or nil
    if widget == nil or widget.featureId ~= "combat_stats" or widget.minimizable ~= true
        or widget.lockable ~= true or widget.opacityAdjustable ~= true
        or widget.backgroundOpacityAdjustable ~= true or widget.fontScaleAdjustable ~= true then
        return Fail("widget_contract")
    end

    local rsui = S.RSUI
    if type(rsui) ~= "table" or (tonumber(rsui.version) or 0) < 21
        or (tonumber(rsui.SegmentedSelectorContractVersion) or 0) < 1
        or (tonumber(rsui.FloatingFontScaleContractVersion) or 0) < 1
        or type(rsui.SegmentedSelector) ~= "function" or type(rsui.NumericInput) ~= "function"
        or type(rsui.ApplyFontScale) ~= "function" then
        return Fail("widget_quick_filter_appearance_contract")
    end

    local health = F:GetHealth()
    if F.enabled == true then
        if tostring(health.busScope) ~= "all(shared_analytics)" or health.analyticsHeld ~= true or health.busSubscribed == true or health.relationHeld ~= true then return Fail("runtime_scope_contract") end
    elseif (tonumber(health.consumers) or 0) ~= 0 then
        return Fail("runtime_consumer_contract")
    end
    return true
end)

G:RegisterSequenceCase("v3_m16_dps_skill_proxy_source", function()
    local F2 = S.Features and S.Features.DPS or nil
    local liveRelation = S.Services and S.Services.CombatRelationV3 or nil
    local catalog = S.Data and S.Data.CombatSourceProxyCatalog or nil
    if type(F2) ~= "table" or type(F2.Domain) ~= "table" or type(liveRelation) ~= "table" or type(catalog) ~= "table" then return Fail("proxy_precondition") end
    local fake = { relations = { MePlayer="SELF", TeamMate="FRIENDLY" }, kinds = { MePlayer="PLAYER", TeamMate="PLAYER" }, records = 0 }
    function fake:ApplyKind(name, kind) self.kinds[tostring(name or "")] = tostring(kind or ""); return true, self.relations[tostring(name or "")] or "UNKNOWN", true end
    function fake:GetRelationAt(name) return self.relations[tostring(name or "")] or "UNKNOWN" end
    function fake:GetUnit(name) local kind=self.kinds[tostring(name or "")]; return kind and {kind=kind} or nil end
    function fake:RecordCombatFact(fact) self.records=self.records+1; return true,{sourceRelation=self:GetRelationAt(fact.sourceName),targetRelation=self:GetRelationAt(fact.targetName),relationChanged=false} end
    local wasEnabled = F2.enabled == true
    local function Cleanup() F2.Domain:ClearStats("proxy_acceptance_cleanup"); F2.enabled=wasEnabled; S.Services.CombatRelationV3=liveRelation end
    local function Run()
        S.Services.CombatRelationV3 = fake
        F2.enabled = true
        F2.Domain:ClearStats("proxy_acceptance")
        local proxyFact = { sequence=9001,receivedAt=1000,category="heal",kind="heal",amount=1500000,sourceName="治愈之泉",targetName="TeamMate",sourceKind="SLAVE",targetKind="PLAYER",abilityName="治愈之泉",rawAbilityId=11948,environmental=false,transport="private" }
        local consumed, meta = F2.Domain:OnCombatFact(proxyFact)
        if consumed ~= true or type(meta) ~= "table" or meta.proxySource ~= true then return Fail("proxy_not_consumed") end
        local p = F2.Domain:GetProjection({mode="PVE",side="friendly",metric="heal",displayRows=150})
        for _, row in ipairs(p.rows or {}) do if tostring(row.name or "") == "治愈之泉" then return Fail("proxy_became_actor") end end
        local h = F2.Domain:GetHealth()
        if tonumber(h.proxySourceHeals) ~= 1 or tonumber(h.proxySourceHealAmount) ~= 1500000 then return Fail("proxy_diagnostic_missing") end
        if fake.kinds["治愈之泉"] ~= nil or fake.records ~= 0 then return Fail("proxy_polluted_relation") end
        -- A real player-source heal that uses the same verified ability remains a
        -- normal player contribution; only the proxy source identity is filtered.
        F2.Domain:OnCombatFact({sequence=9002,receivedAt=1001,category="heal",kind="heal",amount=321,sourceName="MePlayer",targetName="TeamMate",sourceKind="PLAYER",targetKind="PLAYER",abilityName="治愈之泉",rawAbilityId=11948,environmental=false,transport="private"})
        p = F2.Domain:GetProjection({mode="PVE",side="friendly",metric="heal",displayRows=150})
        local playerSeen = false
        for _, row in ipairs(p.rows or {}) do if tostring(row.name or "") == "MePlayer" and (tonumber(row.heal) or 0) >= 321 then playerSeen=true end end
        if playerSeen ~= true then return Fail("player_source_suppressed") end
        for _, name in ipairs({"治愈之泉","治愈之泉：波涛","治愈之泉：绿叶"}) do if catalog:ResolveSource(name,"heal") == nil then return Fail("proxy_variant_missing:"..name) end end
        return true
    end
    local okRun,result,err=xpcall(Run,S.SafeTraceback or function(value) return tostring(value) end); Cleanup()
    if okRun ~= true then return Fail("proxy_exception:"..tostring(result)) end
    if result ~= true then return result,err end
    return true
end)

G:RegisterSequenceCase("v3_m15_6_combat_bus_pair_dedup", function()
    local bus = S.Services and S.Services.CombatEventBusV3 or nil
    if type(bus) ~= "table" or type(bus._IsCrossHostDuplicate) ~= "function" then return Fail("pair_dedup_contract") end
    local saved = {
        pairDedup = bus.pairDedup, pairOrder = bus.pairOrder, pairHead = bus.pairHead, pairSerial = bus.pairSerial,
        pairPendingCount = bus.pairPendingCount, pairMax = bus.pairMax, pairTtlMs = bus.pairTtlMs,
        duplicates = bus.globalCrossHostDuplicates, evicted = bus.globalCrossHostEvicted,
    }
    local function Restore()
        bus.pairDedup, bus.pairOrder, bus.pairHead, bus.pairSerial = saved.pairDedup, saved.pairOrder, saved.pairHead, saved.pairSerial
        bus.pairPendingCount, bus.pairMax, bus.pairTtlMs = saved.pairPendingCount, saved.pairMax, saved.pairTtlMs
        bus.globalCrossHostDuplicates, bus.globalCrossHostEvicted = saved.duplicates, saved.evicted
    end
    bus.pairDedup, bus.pairOrder, bus.pairHead, bus.pairSerial, bus.pairPendingCount = {}, {}, 1, 0, 0
    bus.pairMax, bus.pairTtlMs, bus.globalCrossHostDuplicates, bus.globalCrossHostEvicted = 8, 50, 0, 0
    local function Run()
        if bus:_IsCrossHostDuplicate("UI", "same", 1000) ~= false then return Fail("pair_ui_1") end
        if bus:_IsCrossHostDuplicate("UI", "same", 1001) ~= false then return Fail("pair_ui_2") end
        if bus:_IsCrossHostDuplicate("UIParent", "same", 1002) ~= true then return Fail("pair_parent_1") end
        if bus:_IsCrossHostDuplicate("UIParent", "same", 1003) ~= true then return Fail("pair_parent_2") end
        if tonumber(bus.globalCrossHostDuplicates) ~= 2 or tonumber(bus.pairPendingCount) ~= 0 then return Fail("pair_multiplicity") end
        for index = 1, 300 do
            local at = 2000 + index * 2
            if bus:_IsCrossHostDuplicate("UI", "hot", at) ~= false then return Fail("pair_hot_ui") end
            if bus:_IsCrossHostDuplicate("UIParent", "hot", at + 1) ~= true then return Fail("pair_hot_parent") end
        end
        if tonumber(bus.pairPendingCount) ~= 0 or #bus.pairOrder > 8 then return Fail("pair_backing_order_unbounded") end
        return true
    end
    local okRun, result, err = xpcall(Run, S.SafeTraceback or function(value) return tostring(value) end)
    Restore()
    if okRun ~= true then return Fail("pair_dedup_exception:" .. tostring(result)) end
    if result ~= true then return result, err end
    return true
end)

G:RegisterSequenceCase("v3_m15_3_dps_classification", function()
    local F2 = S.Features and S.Features.DPS or nil
    local liveRelation = S.Services and S.Services.CombatRelationV3 or nil
    if type(F2) ~= "table" or type(F2.Domain) ~= "table" or type(liveRelation) ~= "table" then return Fail("precondition") end

    -- Classification acceptance must be hermetic. Earlier versions seeded manual
    -- marks and kinds into the live CombatRelation service; any failed assertion
    -- could leak test identities into the running session. Swap in a tiny fake
    -- relation Authority for the duration of this case and restore unconditionally.
    local fake = { relations = {}, kinds = {}, nextRelationChanged = false }
    function fake:ApplyManual(name, relation) self.relations[tostring(name or "")] = tostring(relation or "UNKNOWN"); return true end
    function fake:ClearManual(name) self.relations[tostring(name or "")] = nil; return true end
    function fake:ApplyKind(name, kind)
        name, kind = tostring(name or ""), tostring(kind or "")
        local changed = self.kinds[name] ~= kind
        self.kinds[name] = kind
        return true, self.relations[name] or "UNKNOWN", changed
    end
    function fake:GetRelationAt(name) return self.relations[tostring(name or "")] or "UNKNOWN", "ACCEPTANCE", 0 end
    function fake:GetUnit(name)
        local kind = self.kinds[tostring(name or "")]
        return kind ~= nil and { kind = kind } or nil
    end
    function fake:RecordCombatFact(fact)
        local changed = self.nextRelationChanged == true
        self.nextRelationChanged = false
        return true, {
            sourceRelation = self:GetRelationAt(fact and fact.sourceName),
            targetRelation = self:GetRelationAt(fact and fact.targetName),
            relationChanged = changed,
        }
    end

    local wasEnabled = F2.enabled == true
    local function Cleanup()
        F2.Domain:ClearStats("acceptance_cleanup")
        F2.enabled = wasEnabled
        S.Services.CombatRelationV3 = liveRelation
    end

    S.Services.CombatRelationV3 = fake
    F2.enabled = true -- Domain unit test only; do not acquire the live bus.
    F2.Domain:ClearStats("acceptance")

    local function Run()
        fake:ApplyManual("MePlayer", "SELF")
        fake:ApplyManual("RivalPlayer", "OPPONENT")
        fake:ApplyManual("OrcMob", "OPPONENT")
        fake:ApplyManual("TeamMate", "FRIENDLY")
        fake:ApplyKind("MePlayer", "PLAYER")
        fake:ApplyKind("RivalPlayer", "PLAYER")
        fake:ApplyKind("OrcMob", "NPC")
        fake:ApplyKind("TeamMate", "PLAYER")

        local seq = 1
        local function Fact(source, target, category, amount, sourceKind, targetKind, abilityName, abilityId, kind)
            seq = seq + 1
            return {
                sequence = seq, receivedAt = seq, category = category, amount = amount,
                kind = kind or (category == "heal" and "heal" or (category == "damage" and "spell_damage" or category)),
                sourceName = source, targetName = target, sourceKind = sourceKind, targetKind = targetKind,
                abilityName = abilityName, rawAbilityId = abilityId,
                environmental = false, transport = "private",
            }
        end

        -- Outgoing PVE, outgoing/incoming PVP, and friendly healing are independent
        -- contributions. Incoming damage must land in target.taken rather than being
        -- accidentally folded into the source's outgoing damage.
        F2.Domain:OnCombatFact(Fact("MePlayer", "OrcMob", "damage", 1100, "PLAYER", "NPC"))
        F2.Domain:OnCombatFact(Fact("MePlayer", "RivalPlayer", "damage", 50, "PLAYER", "PLAYER"))
        F2.Domain:OnCombatFact(Fact("RivalPlayer", "MePlayer", "damage", 30, "PLAYER", "PLAYER"))
        F2.Domain:OnCombatFact(Fact("MePlayer", "TeamMate", "heal", 20, "PLAYER", "PLAYER"))

        local health = F2.Domain:GetHealth()
        if tonumber(health.classifiedPVE) < 1 then return Fail("pve_classification") end
        if tonumber(health.classifiedPVP) < 2 then return Fail("pvp_classification") end
        if tonumber(health.classifiedHeal) < 1 then return Fail("heal_classification") end

        local pveFriendly = F2.Domain:GetProjection({ mode = "PVE", side = "friendly", displayRows = 150 })
        local pveEnemy = F2.Domain:GetProjection({ mode = "PVE", side = "enemy", displayRows = 150 })
        local pvpFriendly = F2.Domain:GetProjection({ mode = "PVP", side = "friendly", displayRows = 150 })
        local pvpEnemy = F2.Domain:GetProjection({ mode = "PVP", side = "enemy", displayRows = 150 })
        if (pveFriendly.totals and tonumber(pveFriendly.totals.damage) or 0) ~= 1100 then return Fail("pve_outgoing_missing") end
        if (pveEnemy.totals and tonumber(pveEnemy.totals.taken) or 0) ~= 1100 then return Fail("pve_taken_missing") end
        if (pveFriendly.totals and tonumber(pveFriendly.totals.heal) or 0) ~= 20 then return Fail("heal_missing") end
        if (pvpFriendly.totals and tonumber(pvpFriendly.totals.heal) or 0) ~= 20 then return Fail("shared_pvp_heal_missing") end
        if (pvpFriendly.totals and tonumber(pvpFriendly.totals.damage) or 0) ~= 50 then return Fail("pvp_outgoing_missing") end
        if (pvpFriendly.totals and tonumber(pvpFriendly.totals.taken) or 0) ~= 30 then return Fail("incoming_taken_missing") end
        if (pvpEnemy.totals and tonumber(pvpEnemy.totals.damage) or 0) ~= 30 then return Fail("enemy_damage_missing") end

        -- An inferred OPPONENT is not a trusted anchor for assigning the other
        -- endpoint to friendly. Enemy -> neutral/NPC traffic is common in the
        -- global stream and must not manufacture fake friendly taken rows.
        fake:ApplyKind("NeutralVictim", "NPC")
        F2.Domain:OnCombatFact(Fact("RivalPlayer", "NeutralVictim", "damage", 41, "PLAYER", "NPC", "旁观攻击", 8001))
        local neutralFriendly = F2.Domain:GetProjection({ mode = "PVE", side = "friendly", metric = "taken", displayRows = 150 })
        local neutralUnknown = F2.Domain:GetProjection({ mode = "PVE", side = "unknown", metric = "taken", displayRows = 150 })
        if (neutralFriendly.totals and tonumber(neutralFriendly.totals.taken) or 0) ~= 0 then return Fail("opponent_inferred_fake_friendly") end
        if (neutralUnknown.totals and tonumber(neutralUnknown.totals.taken) or 0) < 41 then return Fail("neutral_target_not_retained") end

        -- Relation evidence established by a later combat row must request a
        -- safe-point replay of older pending facts. The hot callback only returns
        -- metadata; the Feature's 160ms one-shot performs the bounded replay.
        fake:ApplyKind("LateEnemy", "PLAYER")
        fake:ApplyKind("LateNeutral", "NPC")
        F2.Domain:OnCombatFact(Fact("LateEnemy", "LateNeutral", "damage", 19, "PLAYER", "NPC", "迟到证据", 8002))
        local reclassBeforeRelation = tonumber(F2.Domain:GetHealth().replayReclassifications) or 0
        fake:ApplyManual("LateEnemy", "OPPONENT")
        fake.nextRelationChanged = true
        local _, relationMeta = F2.Domain:OnCombatFact(Fact("LateEnemy", "MePlayer", "damage", 7, "PLAYER", "PLAYER", "建立敌对", 8003))
        if type(relationMeta) ~= "table" or relationMeta.replaySuggested ~= true then return Fail("relation_change_replay_not_suggested") end
        F2.Domain:ReplayPending("acceptance_relation_change")
        if (tonumber(F2.Domain:GetHealth().replayReclassifications) or 0) <= reclassBeforeRelation then return Fail("relation_change_replay_no_progress") end
        local lateEnemyProjection = F2.Domain:GetProjection({ mode = "PVE", side = "enemy", metric = "damage", displayRows = 150 })
        local lateSeen = false
        for _, actor in ipairs(lateEnemyProjection.rows or {}) do
            if actor.name == "LateEnemy" and (tonumber(actor.damage) or 0) >= 19 then lateSeen = true; break end
        end
        if lateSeen ~= true then return Fail("relation_change_old_fact_not_reclassified") end

        -- Cross-world identities are distinct Authorities. Two explicitly
        -- qualified players with the same base name must never collapse into one
        -- ranking row; short-name ambiguity may remain separate until verified.
        fake:ApplyManual("Twin@WorldA", "OPPONENT")
        fake:ApplyManual("Twin@WorldB", "OPPONENT")
        fake:ApplyKind("Twin@WorldA", "PLAYER")
        fake:ApplyKind("Twin@WorldB", "PLAYER")
        F2.Domain:OnCombatFact(Fact("Twin@WorldA", "MePlayer", "damage", 11, "PLAYER", "PLAYER"))
        F2.Domain:OnCombatFact(Fact("Twin@WorldB", "MePlayer", "damage", 13, "PLAYER", "PLAYER"))
        local crossWorld = F2.Domain:GetProjection({ mode = "PVP", side = "enemy", metric = "damage", displayRows = 150 })
        local crossSeen = {}
        for _, actor in ipairs(crossWorld.rows or {}) do
            if actor.name == "Twin@WorldA" or actor.name == "Twin@WorldB" then crossSeen[actor.name] = tonumber(actor.damage) or 0 end
        end
        if crossSeen["Twin@WorldA"] ~= 11 or crossSeen["Twin@WorldB"] ~= 13 then return Fail("cross_world_actor_collision") end

        -- Regression: Lua `a and b or c` is not a nil-safe ternary. SELF attacking
        -- a relation-known but kind-unknown target must be immediate provisional
        -- PVE, never fall back to sourceKind=PLAYER and become false PVP.
        fake:ApplyManual("FirstHitNpc", "OPPONENT")
        F2.Domain:OnCombatFact(Fact("MePlayer", "FirstHitNpc", "damage", 88, "PLAYER", nil, "首击测试", 9001))
        local firstHitPVE = F2.Domain:GetProjection({ mode = "PVE", side = "friendly", metric = "damage", displayRows = 150 })
        local firstHitPVP = F2.Domain:GetProjection({ mode = "PVP", side = "friendly", metric = "damage", displayRows = 150 })
        if (firstHitPVE.totals and tonumber(firstHitPVE.totals.damage) or 0) ~= 1188 then return Fail("first_unknown_npc_not_visible") end
        if (firstHitPVP.totals and tonumber(firstHitPVP.totals.damage) or 0) ~= 50 then return Fail("first_unknown_npc_false_pvp") end
        local pendingBeforeKind = tonumber(F2.Domain:GetHealth().pendingRows) or 0
        if pendingBeforeKind ~= 1 then return Fail("first_unknown_npc_not_replayable") end
        fake:ApplyKind("FirstHitNpc", "NPC")
        F2.Domain:ReplayPending("acceptance_first_hit_kind")
        if (tonumber(F2.Domain:GetHealth().pendingRows) or 0) ~= 0 then return Fail("first_unknown_npc_replay_not_resolved") end
        local firstHitAfter = F2.Domain:GetProjection({ mode = "PVE", side = "friendly", metric = "damage", displayRows = 150 })
        if (firstHitAfter.totals and tonumber(firstHitAfter.totals.damage) or 0) ~= 1188 then return Fail("first_unknown_npc_replay_changed_total") end

        -- Detail ledger must follow the same contribution/replay authority as the
        -- ranking. It is bounded per actor and contains no borrowed CombatFact.
        fake:ApplyManual("DetailNpc", "OPPONENT")
        fake:ApplyKind("DetailNpc", "NPC")
        F2.Domain:OnCombatFact(Fact("MePlayer", "DetailNpc", "damage", 120, "PLAYER", "NPC", "烈焰斩", 9101))
        F2.Domain:OnCombatFact(Fact("MePlayer", "DetailNpc", "damage", 80, "PLAYER", "NPC", "穿刺", 9102))
        F2.Domain:OnCombatFact(Fact("MePlayer", "DetailNpc", "damage", 40, "PLAYER", "NPC", "烈焰斩", 9101))
        local detailProjection = F2.Domain:GetProjection({ mode = "PVE", side = "friendly", metric = "damage", displayRows = 150 })
        local selfKey = nil
        for _, row in ipairs(detailProjection.rows or {}) do if row.self == true then selfKey = row.key; break end end
        if selfKey == nil then return Fail("detail_self_key_missing") end
        local detail = F2.Domain:GetActorDetail({ mode = "PVE", side = "friendly", metric = "damage", actorKey = selfKey, limit = 100 })
        if type(detail) ~= "table" or type(detail.actor) ~= "table" then return Fail("detail_actor_missing") end
        local skillAmounts, skillIds, counterpartAmounts = {}, {}, {}
        for _, row in ipairs(detail.abilities or {}) do skillAmounts[tostring(row.name)] = tonumber(row.amount) or 0; skillIds[tostring(row.name)] = tonumber(row.abilityId) end
        for _, row in ipairs(detail.counterparts or {}) do counterpartAmounts[tostring(row.name)] = tonumber(row.amount) or 0 end
        if skillAmounts["烈焰斩"] ~= 160 or skillAmounts["穿刺"] ~= 80 then return Fail("detail_skill_amount") end
        if skillIds["烈焰斩"] ~= 9101 or skillIds["穿刺"] ~= 9102 then return Fail("detail_skill_id") end
        if counterpartAmounts["DetailNpc"] ~= 240 then return Fail("detail_counterpart_amount") end

        -- MELEE_DAMAGE reuses rawAbilityId as amount on RU and must never expose
        -- that value as a fake skill id in player drill-down.
        fake:ApplyManual("MeleeNpc", "OPPONENT");fake:ApplyKind("MeleeNpc", "NPC")
        F2.Domain:OnCombatFact(Fact("MePlayer", "MeleeNpc", "damage", 17, "PLAYER", "NPC", "普通攻击", 777777, "melee_damage"))
        local meleeDetail=F2.Domain:GetActorDetail({mode="PVE",side="friendly",metric="damage",actorKey=selfKey,limit=100})
        for _,row in ipairs(meleeDetail.abilities or {}) do if row.name=="普通攻击" and row.abilityId~=nil then return Fail("melee_amount_promoted_to_skill_id") end end

        local healProjection = F2.Domain:GetProjection({ mode = "PVE", side = "friendly", metric = "heal", displayRows = 150 })
        if tostring(healProjection.metric) ~= "heal" or #healProjection.rows < 1
            or (tonumber(healProjection.rows[1].metricValue) or 0) < 20 then return Fail("metric_heal_projection") end
        local takenProjection = F2.Domain:GetProjection({ mode = "PVE", side = "enemy", metric = "taken", displayRows = 150 })
        if tostring(takenProjection.metric) ~= "taken" or #takenProjection.rows < 1
            or (tonumber(takenProjection.rows[1].metricValue) or 0) < 1100 then return Fail("metric_taken_projection") end

        -- Display cap is projection-only. Give each NPC a verified kind so every row
        -- is authoritative PVE and the underlying enemy actor count must exceed 3.
        for index = 1, 200 do
            local name = "OrcMob_" .. tostring(index)
            fake:ApplyManual(name, "OPPONENT")
            fake:ApplyKind(name, "NPC")
            F2.Domain:OnCombatFact(Fact("MePlayer", name, "damage", 5, "PLAYER", "NPC"))
        end
        local capped = F2.Domain:GetProjection({ mode = "PVE", side = "enemy", displayRows = 3 })
        if #capped.rows > 3 then return Fail("display_cap_violated") end
        if (capped.totals and capped.totals.actorCount or 0) <= 3 then return Fail("accumulation_capped") end

        -- Unknown facts are retained rather than silently discarded.
        F2.Domain:OnCombatFact(Fact("MysteryA", "MysteryB", "damage", 77, nil, nil))
        local unresolved = F2.Domain:GetProjection({ mode = "PVE", side = "friendly", displayRows = 150 }).unresolved
        if type(unresolved) ~= "table" or (unresolved.totals and unresolved.totals.damage or 0) < 77 then
            return Fail("unresolved_data_dropped")
        end

        -- Resolved PVE with no side evidence must stay visible in the side-unknown
        -- bucket instead of disappearing between the friendly/enemy projections.
        fake:ApplyKind("SideUnknownNpcA", "NPC")
        fake:ApplyKind("SideUnknownNpcB", "NPC")
        F2.Domain:OnCombatFact(Fact("SideUnknownNpcA", "SideUnknownNpcB", "damage", 33, "NPC", "NPC"))
        local sideUnknown = F2.Domain:GetProjection({ mode = "PVE", side = "unknown", displayRows = 150 })
        if (sideUnknown.totals and tonumber(sideUnknown.totals.damage) or 0) < 33 then return Fail("side_unknown_dropped") end
        if type(sideUnknown.rows) ~= "table" or sideUnknown.rows[1] == nil or (tonumber(sideUnknown.rows[1].events) or 0) < 1 then
            return Fail("side_unknown_inspection_events_missing")
        end

        -- Enabled/Demand lifetime and statistics lifetime are separate. Stopping
        -- collection releases replay/segment state but must not erase the session.
        local beforeReset = F2.Domain:GetProjection({ mode = "PVE", side = "friendly", metric = "damage", displayRows = 150 })
        local beforeResetDamage = beforeReset.totals and tonumber(beforeReset.totals.damage) or 0
        F2.Domain:ResetTransient("acceptance_preserve")
        local afterReset = F2.Domain:GetProjection({ mode = "PVE", side = "friendly", metric = "damage", displayRows = 150 })
        if (afterReset.totals and tonumber(afterReset.totals.damage) or 0) ~= beforeResetDamage then return Fail("transient_reset_erased_stats") end

        -- Replay ledger is truly bounded: stale array slots may not grow forever
        -- after the 512 active-row cap is reached. Repeated unknown events use the
        -- same actors so the stress case measures replay storage rather than rows.
        for index = 1, 520 do
            F2.Domain:OnCombatFact(Fact("StressUnknownA", "StressUnknownB", "damage", 1, nil, nil, "未知技能", 0))
        end
        local bounded = F2.Domain:GetHealth()
        if (tonumber(bounded.pendingRows) or 0) > 512 then return Fail("pending_rows_unbounded") end
        if (tonumber(bounded.pendingLedgerSlots) or 0) > 512 then return Fail("pending_order_unbounded") end
        if (tonumber(bounded.pendingEvicted) or 0) < 8 then return Fail("pending_eviction_missing") end
        for _, row in pairs(F2.Domain.pendingRows or {}) do
            if row.fact ~= nil then return Fail("borrowed_fact_retained") end
        end

        -- Provisional rows are visible immediately but must not mutate the
        -- committed DPS activity clock before classification is final. Otherwise
        -- moving a late-known player hit from PVE to PVP leaves ghost time in PVE
        -- and permanently depresses DPS even though the damage was rolled back.
        F2.Domain:ClearStats("acceptance_replay_clock")
        fake:ApplyManual("ClockNpc", "OPPONENT")
        fake:ApplyKind("ClockNpc", "NPC")
        local baseClock = Fact("MePlayer", "ClockNpc", "damage", 100, "PLAYER", "NPC", "基准攻击", 9901)
        baseClock.receivedAt = 1000
        F2.Domain:OnCombatFact(baseClock)
        fake:ApplyManual("ClockMystery", "OPPONENT")
        local provisionalClock = Fact("MePlayer", "ClockMystery", "damage", 50, "PLAYER", nil, "待定攻击", 9902)
        provisionalClock.receivedAt = 10000
        F2.Domain:OnCombatFact(provisionalClock)
        local beforeClock = F2.Domain:GetProjection({ mode = "PVE", side = "friendly", metric = "damage", displayRows = 150 })
        local beforeSelf = nil
        for _, actor in ipairs(beforeClock.rows or {}) do if actor.self == true then beforeSelf = actor; break end end
        if beforeSelf == nil or tonumber(beforeSelf.activeMs) ~= 1000 then return Fail("pending_polluted_activity_clock") end
        fake:ApplyKind("ClockMystery", "PLAYER")
        F2.Domain:ReplayPending("acceptance_replay_clock")
        local afterClock = F2.Domain:GetProjection({ mode = "PVE", side = "friendly", metric = "damage", displayRows = 150 })
        local afterSelf = nil
        for _, actor in ipairs(afterClock.rows or {}) do if actor.self == true then afterSelf = actor; break end end
        if afterSelf == nil or tonumber(afterSelf.damage) ~= 100 or tonumber(afterSelf.activeMs) ~= 1000 or tonumber(afterSelf.dps) ~= 100 then
            return Fail("replay_left_ghost_activity_clock")
        end

        F2.Domain:ClearStats("acceptance")
        local after = F2.Domain:GetProjection({ mode = "PVE", side = "friendly", displayRows = 150 })
        if (after.totals and after.totals.actorCount or 0) ~= 0 then return Fail("clear_failed") end
        return true
    end

    local okRun, result, err = xpcall(Run, S.SafeTraceback or function(value) return tostring(value) end)
    Cleanup()
    if okRun ~= true then return Fail("classification_exception:" .. tostring(result)) end
    if result ~= true then return result, err end
    return true
end)
