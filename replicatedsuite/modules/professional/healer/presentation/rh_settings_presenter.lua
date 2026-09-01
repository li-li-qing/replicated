ReplicatedSuiteModuleSandbox:Enter('healer', {'ReplicatedHealerBoot', 'ReplicatedHealerConfig', 'ReplicatedHealerModule'})
------------------------------------------------------------------------
-- Replicated Healer - Settings Presenter v1
--
-- Suite-facing settings projection/command facade.  The SettingsModel owns
-- validation semantics; this presenter owns the narrow UI command surface and
-- requests visual projection + debounced persistence after accepted mutations.
------------------------------------------------------------------------

if ReplicatedHealerCore1Loaded ~= true or type(ReplicatedHealerModule) ~= "table" then return end

ReplicatedHealerSettingsPresenter = ReplicatedHealerSettingsPresenter or {}
local P = ReplicatedHealerSettingsPresenter
P.Version = "1.0"
P.metrics = P.metrics or { reads = 0, writes = 0, rejected = 0, projections = 0 }
local HM = ReplicatedHealerModule
local SettingsModel = ReplicatedHealerSettingsModel

local function CountRead() P.metrics.reads = (tonumber(P.metrics.reads) or 0) + 1 end
local function CountWrite() P.metrics.writes = (tonumber(P.metrics.writes) or 0) + 1 end
local function CountReject() P.metrics.rejected = (tonumber(P.metrics.rejected) or 0) + 1 end

function HM:OpenSettings()
    if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.UI ~= nil then
        ReplicatedSuite.UI:ShowPage("healer")
        return true
    end
    if configWindow == nil then return false end
    configWindow:Show(true)
    if configWindow.SetUILayer ~= nil then configWindow:SetUILayer(TOP_LAYER) end
    if configWindow.Raise ~= nil then configWindow:Raise() end
    RefreshSettingsUi()
    return true
end

function HM:OpenSettingsPage(pageIndex)
    if ReplicatedSuiteEmbedded == true then
        if type(SetSettingsPage) == "function" then SetSettingsPage(tonumber(pageIndex) or 1) end
        return self:OpenSettings()
    end
    if not self:OpenSettings() then return false end
    if type(SetSettingsPage) == "function" then SetSettingsPage(tonumber(pageIndex) or 1) end
    RefreshSettingsUi()
    return true
end

-- Narrow settings facade consumed by the Suite-native right-panel page.  The
-- Healer domain remains Authority; Suite never owns/copies healer state.
local SUITE_SETTING_SPECS = SettingsModel and SettingsModel.SuiteSettingSpecs or {}
local SUITE_COLOR_KEYS = SettingsModel and SettingsModel.SuiteColorKeys or {}
local SUITE_WEIGHT_KEYS = SettingsModel and SettingsModel.SuiteWeightKeys or {}
local SUITE_LEVEL_KEYS = SettingsModel and SettingsModel.SuiteLevelKeys or {}
local SUITE_ROLE_SCORE_KEYS = SettingsModel and SettingsModel.SuiteRoleScoreKeys or {}
local SUITE_RULE_SPECS = SettingsModel and SettingsModel.SuiteRuleSpecs or {}

local function RefreshSuiteProjection()
    P.metrics.projections = (tonumber(P.metrics.projections) or 0) + 1
    LayoutRaidOverlays()
    RefreshHeadMarkers()
    RefreshRaidHighlights()
end
function HM:GetSuiteSetting(key)
    CountRead()
    key=tostring(key or "")
    if SUITE_SETTING_SPECS[key]==nil then return nil end
    return state[key]
end

-- Pure preview/validation facade for BindingV2.  It delegates to the Settings
-- Model and performs no state mutation, Native UI projection or persistence.
-- Settings controls may therefore normalize coupled thresholds before crossing
-- the Domain write fence, while SetSuiteSetting remains the final Authority.
function HM:PreviewSuiteSetting(key, value)
    key=tostring(key or "")
    if type(SettingsModel)~="table" then return false,nil,"settings model unavailable" end
    if SUITE_SETTING_SPECS[key]==nil then return false,nil,"unsupported setting" end
    local preview=SettingsModel.PreviewSuiteSetting or SettingsModel.CoerceSuiteSetting
    if type(preview)~="function" then return false,nil,"settings model unavailable" end
    local ok,coerced,err=preview(SettingsModel,state,key,value)
    return ok==true,coerced,err
end

function HM:SetSuiteSetting(key, value)
    CountWrite()
    key=tostring(key or "")
    if type(SettingsModel)~="table" then return false, "settings model unavailable" end
    local ok, coerced, err = SettingsModel:CoerceSuiteSetting(state, key, value)
    if ok~=true then CountReject(); return false, err or "unsupported setting" end
    value=coerced
    state[key]=value
    if key=="maxDistance" then state.proximityDistance=value end
    if key=="proximityDistance" then state.maxDistance=value end
    if key=="raidCalibrationScope" then NormalizeCalibrationSectionForScope() end

    -- roleScoringEnabled is not a cosmetic toggle. Enabling it requires a
    -- trustworthy Native Role generation before Recommendation can consume
    -- role scores; disabling it may immediately return to classification-only
    -- roles. Keep this lifecycle inside the Healer Authority rather than making
    -- the Suite workspace know about Roster/Runtime internals.
    if key=="roleScoringEnabled" and ReplicatedHealerRoster~=nil then
        if value==true and type(ReplicatedHealerRoster.Invalidate)=="function" then
            ReplicatedHealerRoster:Invalidate(false,"suite_role_scoring_enabled")
        elseif value~=true and type(ReplicatedHealerRoster.Request)=="function" then
            ReplicatedHealerRoster:Request("suite_role_scoring_disabled",false)
        end
        if ReplicatedHealerRuntime~=nil and type(ReplicatedHealerRuntime.OnScoringPolicyChanged)=="function" then
            ReplicatedHealerRuntime:OnScoringPolicyChanged("suite_role_scoring_toggle")
        end
    end

    RefreshSuiteProjection()
    if key=="raidCalibrationSection" or key=="raidCalibrationScope" then ApplyCalibrationMode() end
    SaveState()
    return true
end

function HM:GetSuiteColor(key)
    key=tostring(key or "")
    if SUITE_COLOR_KEYS[key]~=true or type(state[key])~="table" then return nil end
    return DeepCopy(state[key])
end
function HM:GetSuiteHeadSize(level)
    level=math.floor(Clamp(tonumber(level) or 1,1,4))
    state.headSizes=type(state.headSizes)=="table" and state.headSizes or DeepCopy(defaults.headSizes)
    return SettingsModel:NormalizeHeadSize(state.headSizes[level], defaults.headSizes[level])
end
function HM:SetSuiteHeadSize(level,value)
    level=math.floor(Clamp(tonumber(level) or 1,1,4))
    state.headSizes=type(state.headSizes)=="table" and state.headSizes or DeepCopy(defaults.headSizes)
    state.headSizes[level]=SettingsModel:NormalizeHeadSize(value, state.headSizes[level] or defaults.headSizes[level])
    RefreshHeadMarkers()
    SaveState()
    return true
end

function HM:SetSuiteColorChannel(key, channel, value)
    key=tostring(key or ""); channel=tostring(channel or "")
    if SUITE_COLOR_KEYS[key]~=true or type(state[key])~="table" then return false, "unsupported color" end
    local ok, normalized, err = SettingsModel:NormalizeColorChannel(channel, value, state[key][channel])
    if ok~=true then return false, err end
    state[key][channel]=normalized
    RefreshSuiteProjection(); SaveState(); return true
end
function HM:SetSuiteColor(key,color)
    key=tostring(key or "")
    if SUITE_COLOR_KEYS[key]~=true then return false,"unsupported color" end
    state[key]=CopyColor(color,state[key] or defaults[key] or {r=1,g=1,b=1,a=1})
    RefreshSuiteProjection(); SaveState(); return true
end

-- Rescue-score settings previously lived only in the historical standalone
-- advanced window.  Suite reads/writes them through this narrow domain facade
-- so the right-panel UI does not become a second Healer state Authority.
function HM:GetSuiteWeight(key)
    key=tostring(key or "")
    return SUITE_WEIGHT_KEYS[key]==true and type(state.weights)=="table" and state.weights[key] or nil
end
function HM:SetSuiteWeight(key,value)
    key=tostring(key or "")
    if SUITE_WEIGHT_KEYS[key]~=true then return false,"unsupported weight" end
    state.weights=type(state.weights)=="table" and state.weights or DeepCopy(defaults.weights)
    state.weights[key]=Clamp(tonumber(value) or state.weights[key] or 0,0,100)
    if type(NormalizeWeights)=="function" then NormalizeWeights() end
    SaveState(); return true
end

function HM:GetSuiteLevelThreshold(key)
    key=tostring(key or "")
    return SUITE_LEVEL_KEYS[key]==true and type(state.levelThresholds)=="table" and state.levelThresholds[key] or nil
end
function HM:SetSuiteLevelThreshold(key,value)
    key=tostring(key or "")
    if SUITE_LEVEL_KEYS[key]~=true then return false,"unsupported level threshold" end
    state.levelThresholds=type(state.levelThresholds)=="table" and state.levelThresholds or DeepCopy(defaults.levelThresholds)
    local ok, normalized, err = SettingsModel:NormalizeLevelThreshold(state.levelThresholds, key, value)
    if ok~=true then return false, err end
    state.levelThresholds[key]=normalized
    RefreshSuiteProjection(); SaveState(); return true
end
function HM:GetSuiteLevelColor(level)
    level=math.floor(Clamp(tonumber(level) or 1,1,4))
    return DeepCopy(type(state.levelColors)=="table" and state.levelColors[level] or nil)
end
function HM:SetSuiteLevelColorChannel(level,channel,value)
    level=math.floor(Clamp(tonumber(level) or 1,1,4)); channel=tostring(channel or "")
    state.levelColors=type(state.levelColors)=="table" and state.levelColors or DeepCopy(defaults.levelColors)
    state.levelColors[level]=CopyColor(state.levelColors[level],defaults.levelColors[level])
    local ok, normalized, err = SettingsModel:NormalizeColorChannel(channel, value, state.levelColors[level][channel])
    if ok~=true then return false,err end
    state.levelColors[level][channel]=normalized
    RefreshSuiteProjection(); SaveState(); return true
end
function HM:SetSuiteLevelColor(level,color)
    level=math.floor(Clamp(tonumber(level) or 1,1,4))
    state.levelColors=type(state.levelColors)=="table" and state.levelColors or DeepCopy(defaults.levelColors)
    state.levelColors[level]=CopyColor(color,state.levelColors[level] or defaults.levelColors[level])
    RefreshSuiteProjection(); SaveState(); return true
end

function HM:GetSuiteRoleScore(key)
    key=tostring(key or "")
    return SUITE_ROLE_SCORE_KEYS[key]==true and type(state.roleScores)=="table" and state.roleScores[key] or nil
end
function HM:SetSuiteRoleScore(key,value)
    key=tostring(key or "")
    if SUITE_ROLE_SCORE_KEYS[key]~=true then return false,"unsupported role score" end
    state.roleScores=type(state.roleScores)=="table" and state.roleScores or DeepCopy(defaults.roleScores)
    state.roleScores[key]=Clamp(tonumber(value) or state.roleScores[key] or 0,-100,100)
    SaveState(); return true
end
function HM:GetSuiteRoleOverrides()
    local out={}
    for name,role in pairs(state.roleOverrides or {}) do out[#out+1]={name=tostring(name),role=math.floor(Clamp(tonumber(role) or 1,1,#ROLE_LABELS))} end
    table.sort(out,function(a,b) return a.name<b.name end)
    return out
end
local function ReprojectSuiteRoles(reason)
    if ReplicatedHealerRoster~=nil and type(ReplicatedHealerRoster.Reclassify)=="function" then
        ReplicatedHealerRoster:Reclassify()
    end
    if ReplicatedHealerRuntime~=nil and type(ReplicatedHealerRuntime.OnScoringPolicyChanged)=="function" then
        ReplicatedHealerRuntime:OnScoringPolicyChanged(tostring(reason or "suite_role_override"))
    end
end
function HM:SetSuiteRoleOverride(name,role)
    name=tostring(name or ""):gsub("^%s+",""):gsub("%s+$","")
    if name=="" then return false,"玩家名不能为空" end
    role=math.floor(Clamp(tonumber(role) or 1,1,#ROLE_LABELS))
    state.roleOverrides=type(state.roleOverrides)=="table" and state.roleOverrides or {}
    state.roleOverrides[name]=role
    ReprojectSuiteRoles("suite_role_override_set")
    SaveState()
    return true
end
function HM:RemoveSuiteRoleOverride(name)
    name=tostring(name or "")
    if type(state.roleOverrides)~="table" or state.roleOverrides[name]==nil then return false,"职责覆盖不存在" end
    state.roleOverrides[name]=nil
    ReprojectSuiteRoles("suite_role_override_remove")
    SaveState()
    return true
end
function HM:GetSuiteRoleLabel(role)
    role=math.floor(Clamp(tonumber(role) or 1,1,#ROLE_LABELS)); return tostring(ROLE_LABELS[role] or role)
end

-- Shared state metadata resolver used by the Suite selector. It is only called
-- from explicit UI actions / tracked-list refreshes and is cached by id; it is
-- never executed from the high-frequency health scan loop.
local suiteStatusMetaCache={}
local function ResolveSuiteStatusMeta(id,fallbackName,fallbackIcon)
    id=math.floor(tonumber(id) or 0)
    if id<=0 then return {id=0,name=tostring(fallbackName or ""),iconPath=tostring(fallbackIcon or "")} end
    local key=tostring(id);local cached=suiteStatusMetaCache[key]
    if cached~=nil then return cached end
    local result={id=id,name=tostring(fallbackName or ("Buff "..key)),iconPath=tostring(fallbackIcon or "")}
    if X2Ability~=nil and type(X2Ability.GetBuffTooltip)=="function" then
        for _,itemLevel in ipairs({0,1,55}) do
            local ok,info=pcall(function() return X2Ability:GetBuffTooltip(id,itemLevel) end)
            if ok and type(info)=="table" then
                local name=info.name or info.buffName
                local icon=info.path or info.iconPath or info.icon_path or info.icon or info.texture
                if name~=nil and tostring(name)~="" then result.name=tostring(name) end
                if type(icon)=="string" and icon~="" then result.iconPath=icon end
                if result.iconPath~="" or (result.name~="" and result.name~=("Buff "..key)) then break end
            end
        end
    end
    suiteStatusMetaCache[key]=result
    return result
end

-- On-demand Buff observer for the Suite-native page. It performs no background
-- full-raid scan of its own; a scan happens only when the user asks while the
-- Healer Runtime is enabled, preserving the existing performance boundary.
function HM:GetSuiteObservedMembers()
    if #roster==0 and type(RebuildRoster)=="function" then RebuildRoster() end
    local out={}
    for index,member in ipairs(roster or {}) do out[index]={name=tostring(member.name or ""),raidIndex=tonumber(member.raidIndex) or 1,memberIndex=tonumber(member.memberIndex) or index,isSelf=member.isSelf==true} end
    return out
end
function HM:GetSuiteObservedStatuses(memberIndex)
    if state.enabled~=true then return nil,"治疗辅助未启用；观察状态需要 Runtime 扫描" end
    if #roster==0 and type(RebuildRoster)=="function" then RebuildRoster() end
    memberIndex=math.floor(Clamp(tonumber(memberIndex) or 1,1,math.max(1,#roster)))
    local member=roster[memberIndex]; if member==nil then return {},nil end
    local statuses={}
    if ReplicatedHealerStatusCache~=nil and type(ReplicatedHealerStatusCache.Read)=="function" then
        statuses=select(1,ReplicatedHealerStatusCache:Read(member)) or {}
    elseif type(ReadUnitStatuses)=="function" then
        statuses=select(1,ReadUnitStatuses(member)) or {}
    end
    local out={}
    for _,status in pairs(statuses or {}) do
        local mask=tonumber(status and status.sourceMask) or 0; local parts={}
        if mask%2==1 then parts[#parts+1]="Buff" end
        if math.floor(mask/(SOURCE_DEBUFF or 2))%2==1 then parts[#parts+1]="Debuff" end
        if math.floor(mask/(SOURCE_HIDDEN or 4))%2==1 then parts[#parts+1]="隐藏" end
        local meta=ResolveSuiteStatusMeta(status.id,status.name,status.iconPath)
        local iconPath=tostring(status.iconPath or "");if iconPath=="" then iconPath=tostring(meta.iconPath or "") end
        out[#out+1]={id=tonumber(status.id) or 0,name=tostring(meta.name or status.name or status.id or ""),iconPath=iconPath,source=#parts>0 and table.concat(parts,"/") or "状态",stack=tonumber(status.stack) or 1,timeLeftMs=tonumber(status.timeLeft),timeKnown=status.timeKnown==true}
    end
    table.sort(out,function(a,b) if a.name~=b.name then return a.name<b.name end return a.id<b.id end)
    return out,nil
end

function HM:GetSuiteBuffDiagnostics()
    local d=type(statusScanDiagnostics)=="table" and statusScanDiagnostics or {}
    local enabledTracked=0
    for _,entry in ipairs(state.trackedBuffs or {}) do if entry.enabled~=false then enabledTracked=enabledTracked+1 end end
    return {
        runtimeEnabled=state.enabled==true,
        trackedTotal=#(state.trackedBuffs or {}),
        trackedEnabled=enabledTracked,
        scans=tonumber(d.scans) or 0,
        tooltipOnly=tonumber(d.tooltipOnly) or 0,
        skippedNoId=tonumber(d.skippedNoId) or 0,
        lastMember=tostring(d.lastMember or ""),
        buffCount=tonumber(d.lastBuffCount) or 0,
        debuffCount=tonumber(d.lastDebuffCount) or 0,
        hiddenCount=tonumber(d.lastHiddenCount) or 0,
        resolved=tonumber(d.lastResolved) or 0,
        lastScannedAt=tonumber(d.lastScannedAt) or 0,
    }
end

function HM:GetTrackedBuffs()
    local result={}
    for index,entry in ipairs(state.trackedBuffs or {}) do
        local meta=ResolveSuiteStatusMeta(entry.id,entry.name,entry.iconPath)
        local iconPath=tostring(entry.iconPath or "");if iconPath=="" then iconPath=tostring(meta.iconPath or "") end
        result[index]={ id=tonumber(entry.id) or 0, name=tostring(meta.name or entry.name or ""), iconPath=iconPath, enabled=entry.enabled~=false, color=DeepCopy(entry.color or {}) }
    end
    return result
end
function HM:ResolveSuiteStatusId(id,fallbackName)
    id=math.floor(tonumber(id) or 0);if id<=0 then return nil,"状态 ID 无效" end
    return DeepCopy(ResolveSuiteStatusMeta(id,fallbackName,nil)),nil
end
function HM:AddTrackedBuffId(id, name, iconPath)
    id=math.floor(tonumber(id) or 0)
    if id<=0 then return false,"Buff ID 无效" end
    for _,entry in ipairs(state.trackedBuffs or {}) do if tonumber(entry.id)==id then return false,"该 Buff 已在追踪列表" end end
    if #(state.trackedBuffs or {})>=MAX_RULES then return false,"追踪列表已达到上限" end
    local meta=ResolveSuiteStatusMeta(id,name,iconPath)
    state.trackedBuffs=state.trackedBuffs or {}
    state.trackedBuffs[#state.trackedBuffs+1]=NormalizeTrackedBuff({id=id,name=tostring(meta.name or name or ("Buff "..tostring(id))),iconPath=tostring(meta.iconPath or iconPath or ""),enabled=true})
    RefreshSuiteProjection(); SaveState(); return true
end
function HM:SetTrackedBuffEnabled(index, enabled)
    local entry=state.trackedBuffs and state.trackedBuffs[tonumber(index) or 0]
    if entry==nil then return false,"追踪项不存在" end
    entry.enabled=enabled==true; RefreshSuiteProjection(); SaveState(); return true
end
function HM:RemoveTrackedBuff(index)
    index=math.floor(tonumber(index) or 0)
    if index<1 or state.trackedBuffs==nil or state.trackedBuffs[index]==nil then return false,"追踪项不存在" end
    table.remove(state.trackedBuffs,index); RefreshSuiteProjection(); SaveState(); return true
end
function HM:MoveTrackedBuff(index, delta)
    index=math.floor(tonumber(index) or 0); delta=tonumber(delta) or 0
    local target=index+(delta<0 and -1 or 1)
    if state.trackedBuffs==nil or state.trackedBuffs[index]==nil or state.trackedBuffs[target]==nil then return false end
    state.trackedBuffs[index],state.trackedBuffs[target]=state.trackedBuffs[target],state.trackedBuffs[index]
    SaveState(); return true
end
function HM:SetTrackedBuffColorChannel(index, channel, value)
    local entry=state.trackedBuffs and state.trackedBuffs[tonumber(index) or 0]
    if entry==nil then return false,"追踪项不存在" end
    entry.color=CopyColor(entry.color,{r=0.72,g=0.30,b=1.00,a=0.84})
    channel=tostring(channel or "")
    local ok, normalized, err = SettingsModel:NormalizeColorChannel(channel, value, entry.color[channel])
    if ok~=true then return false,err end
    entry.color[channel]=normalized
    RefreshSuiteProjection(); SaveState(); return true
end
function HM:SetTrackedBuffColor(index,color)
    local entry=state.trackedBuffs and state.trackedBuffs[tonumber(index) or 0]
    if entry==nil then return false,"追踪项不存在" end
    entry.color=CopyColor(color,entry.color or {r=0.72,g=0.30,b=1.00,a=0.84})
    RefreshSuiteProjection(); SaveState(); return true
end

function HM:GetSuiteRules()
    local out={}
    for i,r in ipairs(state.rules or {}) do
        out[i]={name=tostring(r.name or ("规则 "..i)),enabled=r.enabled~=false,purpose=tonumber(r.purpose) or 1,ids=DeepCopy(r.ids or {}),simpleDisplayGroup=r.simpleDisplayGroup==true}
    end
    return out
end

-- Simple color-condition groups are a Suite UI projection over the existing
-- rule Authority.  They intentionally do not alter rescue scoring: their only
-- job is "if any tracked status matches, use this group's color".  Advanced
-- historical rules remain intact and are not silently converted/deleted.
function HM:AddSuiteColorConditionGroup()
    if #(state.rules or {})>=MAX_RULES then return false,"条件组已达到上限" end
    state.rules=state.rules or {}
    local r=NewRuleByPurpose(5)
    r.name="条件组 "..tostring(#state.rules+1)
    r.simpleDisplayGroup=true
    r.enabled=true
    r.sourceMode=5
    r.matchMode=1
    r.ids={}
    r.minStacks=1
    r.minRemainingMs=0
    r.unknownRemainingValid=true
    r.healthRangeEnabled=false
    r.effectType=2
    r.scoreMode=1
    r.scoreValue=0
    r.allowStack=false
    r.countsAsProtection=false
    r.displayPriority=150
    r.rescuePriority=0
    r.distanceMode=1
    r.color={r=0.72,g=0.30,b=1.00,a=0.84}
    state.rules[#state.rules+1]=r
    SaveState()
    return true,#state.rules
end

function HM:GetSuiteConditionGroups()
    local out={}
    for i,r in ipairs(state.rules or {}) do
        if r.simpleDisplayGroup==true then
            out[#out+1]={ruleIndex=i,name=tostring(r.name or ("条件组 "..i)),enabled=r.enabled~=false,ids=DeepCopy(r.ids or {}),color=DeepCopy(CopyColor(r.color,{r=0.72,g=0.30,b=1.00,a=0.84}))}
        end
    end
    return out
end
function HM:MoveSuiteConditionGroup(index,delta)
    index=math.floor(tonumber(index) or 0);delta=(tonumber(delta) or 0)<0 and -1 or 1
    if state.rules==nil or state.rules[index]==nil or state.rules[index].simpleDisplayGroup~=true then return false end
    local target=index+delta
    while state.rules[target]~=nil and state.rules[target].simpleDisplayGroup~=true do target=target+delta end
    if state.rules[target]==nil then return false end
    state.rules[index],state.rules[target]=state.rules[target],state.rules[index];SaveState();return true,target
end
function HM:AddSuiteRule(purpose)
    if #(state.rules or {})>=MAX_RULES then return false,"规则已达到上限" end
    state.rules=state.rules or {}; state.rules[#state.rules+1]=NewRuleByPurpose(tonumber(purpose) or 5); SaveState(); return true,#state.rules
end
function HM:CopySuiteRule(index)
    index=math.floor(tonumber(index) or 0)
    if state.rules==nil or state.rules[index]==nil then return false,"规则不存在" end
    if #state.rules>=MAX_RULES then return false,"规则已达到上限" end
    local copy=DeepCopy(state.rules[index]); copy.name=tostring(copy.name or "规则").." 副本"
    table.insert(state.rules,index+1,copy); SaveState(); return true,index+1
end
function HM:AddDefaultHealingRule()
    if #(state.rules or {})>=MAX_RULES then return false,"规则已达到上限" end
    state.rules=state.rules or {}; state.rules[#state.rules+1]=NewDefaultHealingRule(); SaveState(); return true,#state.rules
end
function HM:RemoveSuiteRule(index)
    index=math.floor(tonumber(index) or 0); if state.rules==nil or state.rules[index]==nil then return false,"规则不存在" end
    table.remove(state.rules,index); SaveState(); return true
end
function HM:MoveSuiteRule(index,delta)
    index=math.floor(tonumber(index) or 0); local target=index+((tonumber(delta) or 0)<0 and -1 or 1)
    if state.rules==nil or state.rules[index]==nil or state.rules[target]==nil then return false end
    state.rules[index],state.rules[target]=state.rules[target],state.rules[index]; SaveState(); return true
end
function HM:SetSuiteRuleEnabled(index,enabled)
    local r=state.rules and state.rules[tonumber(index) or 0]; if r==nil then return false,"规则不存在" end
    r.enabled=enabled==true; SaveState(); return true
end
function HM:GetSuiteRuleSetting(index,key)
    local r=state.rules and state.rules[tonumber(index) or 0]; key=tostring(key or "")
    if r==nil or SUITE_RULE_SPECS[key]==nil then return nil end
    return r[key]
end
function HM:SetSuiteRuleSetting(index,key,value)
    CountWrite()
    local r=state.rules and state.rules[tonumber(index) or 0]; key=tostring(key or "")
    if r==nil then return false,"规则不存在" end
    local ok, normalized, err = SettingsModel:CoerceRuleSetting(r, key, value)
    if ok~=true then CountReject(); return false,err or "unsupported rule setting" end
    r[key]=normalized; SaveState(); return true
end
function HM:SetSuiteRuleName(index,name)
    local r=state.rules and state.rules[tonumber(index) or 0]; if r==nil then return false,"规则不存在" end
    name=tostring(name or ""); if name=="" then return false,"规则名称不能为空" end
    r.name=name; SaveState(); return true
end
function HM:SetSuiteRuleIds(index,text)
    local r=state.rules and state.rules[tonumber(index) or 0]; if r==nil then return false,"规则不存在" end
    r.ids=ParseIdList(text); SaveState(); return true
end
function HM:AddSuiteRuleId(index,id)
    local r=state.rules and state.rules[tonumber(index) or 0]; if r==nil then return false,"规则不存在" end
    id=math.floor(tonumber(id) or 0);if id<=0 then return false,"状态 ID 无效" end
    r.ids=type(r.ids)=="table" and r.ids or {}
    for _,existing in ipairs(r.ids) do if tonumber(existing)==id then return true end end
    if #r.ids>=32 then return false,"规则 ID 已达到上限" end
    r.ids[#r.ids+1]=id;SaveState();return true
end
function HM:RemoveSuiteRuleId(index,id)
    local r=state.rules and state.rules[tonumber(index) or 0]; if r==nil then return false,"规则不存在" end
    id=math.floor(tonumber(id) or 0); if id<=0 then return false,"状态 ID 无效" end
    r.ids=type(r.ids)=="table" and r.ids or {}
    for i=#r.ids,1,-1 do
        if tonumber(r.ids[i])==id then table.remove(r.ids,i);SaveState();return true end
    end
    return false,"条件组中没有这个状态"
end
function HM:GetSuiteRuleColor(index)
    local r=state.rules and state.rules[tonumber(index) or 0]; if r==nil then return nil end
    return DeepCopy(CopyColor(r.color,{r=0.72,g=0.30,b=1.00,a=0.82}))
end
function HM:SetSuiteRuleColorChannel(index,channel,value)
    local r=state.rules and state.rules[tonumber(index) or 0]; if r==nil then return false,"规则不存在" end
    channel=tostring(channel or "")
    r.color=CopyColor(r.color,{r=0.72,g=0.30,b=1.00,a=0.82})
    local ok, normalized, err = SettingsModel:NormalizeColorChannel(channel, value, r.color[channel])
    if ok~=true then return false,err end
    r.color[channel]=normalized
    SaveState(); return true
end
function HM:SetSuiteRuleColor(index,color)
    local r=state.rules and state.rules[tonumber(index) or 0]; if r==nil then return false,"规则不存在" end
    r.color=CopyColor(color,r.color or {r=0.72,g=0.30,b=1.00,a=0.82})
    SaveState(); return true
end

local function GetSuiteCalibrationConfig(section)
    section=math.floor(Clamp(tonumber(section) or tonumber(state.raidCalibrationSection) or 1,1,4))
    -- Do not depend on a historical UI helper here.  The Suite facade owns a
    -- narrow, deterministic mapping to the four persisted calibration records.
    local config
    if section==2 then config=state.raidOverlayBottom
    elseif section==3 then config=state.raidOverlayTopRaid2
    elseif section==4 then config=state.raidOverlayBottomRaid2
    else config=state.raidOverlayTop end
    return config,section
end

local function RefreshSuiteCalibrationProjection()
    -- Calibration-specific visuals (blue background, border, labels and drag
    -- ownership) are released only by ApplyCalibrationMode().  Calling only
    -- RefreshRaidHighlights() when calibration is turned off leaves those child
    -- drawables visible even though calibrationMode is already false.  Always
    -- project through ApplyCalibrationMode() so both enter and exit paths share
    -- one visibility Authority; it also refreshes the normal raid highlights
    -- after the calibration visuals have been hidden.
    ApplyCalibrationMode()
end

function HM:GetSuiteCalibrationMode()
    return calibrationMode == true
end
function HM:SetSuiteCalibrationMode(enabled)
    enabled = enabled == true
    if enabled and state.enabled ~= true then
        return false, "治疗辅助未启用；请先启用模块再开始校准"
    end
    calibrationMode = enabled
    NormalizeCalibrationSectionForScope()
    RefreshSuiteCalibrationProjection()
    return true
end
function HM:GetSuiteCalibration()
    local config,section=GetSuiteCalibrationConfig(state.raidCalibrationSection)
    if type(config) ~= "table" then
        return {section=section,scope=tonumber(state.raidCalibrationScope) or 1,enabled=calibrationMode==true,overlay={},rect={x=0,y=0,width=0,height=0}}
    end
    local x,y,width,height=ResolveAnchoredRect(config,config.width,config.height)
    return {
        section=section,
        scope=tonumber(state.raidCalibrationScope) or 1,
        enabled=calibrationMode==true,
        overlay=DeepCopy(config),
        rect={x=x,y=y,width=width,height=height},
    }
end
function HM:AdjustSuiteCalibration(field,delta)
    local config=GetSuiteCalibrationConfig(state.raidCalibrationSection)
    field=tostring(field or ""); delta=tonumber(delta) or 0
    if type(config)~="table" then return false,"校准区域不可用" end
    local x,y,width,height=ResolveAnchoredRect(config,config.width,config.height)
    if field=="offsetX" then x=x+delta
    elseif field=="offsetY" then y=y+delta
    elseif field=="width" then width=Clamp(width+delta,120,1200)
    elseif field=="height" then height=Clamp(height+delta,80,900)
    else return false,"unsupported calibration field" end
    StoreAnchoredRect(config,x,y,width,height)
    RefreshSuiteCalibrationProjection()
    SaveState()
    return true
end
function HM:CenterSuiteCalibration()
    local config=GetSuiteCalibrationConfig(state.raidCalibrationSection)
    if type(config)~="table" then return false,"校准区域不可用" end
    local _,_,_,screenWidth,screenHeight=GetUiMetrics()
    local _,_,width,height=ResolveAnchoredRect(config,config.width,config.height)
    local x=math.max(0,((tonumber(screenWidth) or width)-width)/2)
    local y=math.max(0,((tonumber(screenHeight) or height)-height)/2)
    StoreAnchoredRect(config,x,y,width,height)
    RefreshSuiteCalibrationProjection()
    SaveState()
    return true
end

function HM:ResetSuiteCalibration(all)
    if all==true then
        state.raidOverlayTop=DeepCopy(defaults.raidOverlayTop)
        state.raidOverlayBottom=DeepCopy(defaults.raidOverlayBottom)
        state.raidOverlayTopRaid2=DeepCopy(defaults.raidOverlayTopRaid2)
        state.raidOverlayBottomRaid2=DeepCopy(defaults.raidOverlayBottomRaid2)
    else
        local _,section=GetSuiteCalibrationConfig(state.raidCalibrationSection)
        if section==1 then state.raidOverlayTop=DeepCopy(defaults.raidOverlayTop)
        elseif section==2 then state.raidOverlayBottom=DeepCopy(defaults.raidOverlayBottom)
        elseif section==3 then state.raidOverlayTopRaid2=DeepCopy(defaults.raidOverlayTopRaid2)
        else state.raidOverlayBottomRaid2=DeepCopy(defaults.raidOverlayBottomRaid2) end
    end
    RefreshSuiteCalibrationProjection()
    SaveState()
    return true
end

function HM:GetTrackedBuffCount() return #(state.trackedBuffs or {}) end
function HM:SaveSuiteSettings()
    local ok, err = SaveState(true, "suite_finalize")
    return ok == true, err
end


function P:Describe()
    return {
        version = self.Version,
        reads = tonumber(self.metrics.reads) or 0,
        writes = tonumber(self.metrics.writes) or 0,
        rejected = tonumber(self.metrics.rejected) or 0,
        projections = tonumber(self.metrics.projections) or 0,
        settingsPage = state and tonumber(state.settingsPage) or nil,
    }
end
