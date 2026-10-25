-- Replicated Suite · 头顶状态与装备标记
-- 作者：Replicated
-- QQ群：1104129461
-- 头顶层以血条为布局锚点；分组件固定层只消费 Feature 的独立屏幕坐标：
-- InfoRow（职业、装备、距离）：固定语义槽；BuffRow(s)：血条上方，最多 maxRows 向上堆叠；[LeftEquip] [plate] [RightEquip]：装备位于血条两侧；
-- DebuffRow(s)：血条下方，最多 maxRows 向下堆叠；CastBar：血条下方固定语义槽。
-- Feature 持有全部调度通道；presenter 仅持有有界控件池，按渲染计算缓存布局并应用差异。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Feature = S.Features and S.Features.BuffDisplay or nil
if type(Feature) ~= "table" or type(S.UI) ~= "table" or type(S.Events) ~= "table" then return end

S.UIV3 = S.UIV3 or {}
S.UIV3.BuffHeadMarkersV3 = S.UIV3.BuffHeadMarkersV3 or {}
local P = S.UIV3.BuffHeadMarkersV3
P.version = 13
P.owner = "v3:buff_head_markers"
P.consumerToken = "presentation:buff_head_markers"
P.running = P.running == true
P.consumerHeld = P.consumerHeld == true
P.pools = P.pools or { player = { icons = {}, labels = {}, cast = nil, plate = nil, info = nil }, target = { icons = {}, labels = {}, cast = nil, plate = nil, info = nil } }
P.lifecycleOwner = P.lifecycleOwner or {}
P.metrics = P.metrics or { starts=0, stops=0, ticks=0, projections=0, allocated=0, anchorFailures={} }
P.calibrationSuppressed = P.calibrationSuppressed == true
P.calibrationSuppressionReason = P.calibrationSuppressionReason or nil
P.calibrationSuppressionCount = tonumber(P.calibrationSuppressionCount) or 0
P.calibrationRestoreCount = tonumber(P.calibrationRestoreCount) or 0
P.LiveHudSuppressionContractVersion = 1
P.EquipmentIndependentOffsetContractVersion = 1
P.RangedWeaponVisualOrderContractVersion = 1
P.SplitInfoTextLayoutContractVersion = 3 -- 自身和目标共用固定槽位；同 profile、同事实应得到相同几何。
-- 显隐、缺失字段、兄弟尺寸只影响自身；别名是 target-only 独立槽。
-- 内容更新与运动分开，指标只留固定规模计数。
P.TargetDistanceStableSlotContractVersion = 1
P.MirroredInfoSlotContractVersion = 1
P.IndependentHudSlotContractVersion = 1
P.GearScoreFormatContractVersion = 1
P.TargetAliasHudContractVersion = 2


P.PvpPatch = "pvp-hud-1"
P.contentDirty = true
P.dynamicDirty = {distance=false,cast=false}
P.motionMetrics = { frames=0, rootWrites=0, contentBuilds=0, textureFailures=0, anchorFailures=0 }
P.motionMetrics.partialUpdates,P.motionMetrics.partialDistanceWrites,P.motionMetrics.partialCastUpdates=0,0,0
P.cooldownEvidence = {inputRows=0,drawn=0,rejected=0,nonemptyRenders=0}


local SCOPES = { "player", "target" }
local POOL_KEYS = { "player", "target", "player_fixed", "target_fixed" }
local function UnitScope(scope) return (scope == "target" or scope == "target_fixed") and "target" or "player" end
local function FixedLayer(scope) return scope == "player_fixed" or scope == "target_fixed" end
-- CD 是独立启动理由；漏掉它会让“仅开技能 CD”时不取 Consumer，冷却观察也无法启动。
local RENDERABLE_KEYS = { "buffs", "debuffs", "distance", "class", "gearScore", "mainHand", "offHand", "ranged", "wings", "castBar", "cooldowns" }
local UNKNOWN_ICON = "ui/icon/icon_unknown_item.dds"

local function N(v, fallback) return tonumber(v) or tonumber(fallback) or 0 end
local function TextColor(widget,scope,key,meters)
    if not widget or type(Feature.GetHudColor)~='function' then return end
    local r,g,b=Feature:GetHudColor(UnitScope(scope),key,meters)
    widget.rsManualTextColor=true -- 颜色属于HUD配置；工作台主题不覆盖。widget alpha仍由原组件独立控制。
    S.UI:SetColor(widget,r,g,b,1,P.owner)
end
local function Settings()
    -- VisualTick 是 50ms 级热路径，只需要 HUD 运行策略，不再复制
    -- tracked/classification 等大表；scope 几何由 ScopeSettings 单独取轻量投影。
    local value = type(Feature.GetHeadPolicyProjection) == "function" and Feature:GetHeadPolicyProjection() or nil
    if type(value) ~= "table" and type(Feature.GetSettingsProjection) == "function" then value = Feature:GetSettingsProjection() end
    return type(value) == "table" and value or {}
end
local scopeLayoutCache,scopeLayoutRevision={},nil
local function ScopeSettings(scope)
    -- 两个 scope 从 Feature 各取独立设置快照，设置代际变化才重复制；
    -- 实时单位事实仍每次读取，旧宿主没有代际时不缓存。
    local revision=tonumber(Feature.settingsRevision)
    if revision==nil or revision~=scopeLayoutRevision then
        scopeLayoutCache,scopeLayoutRevision={},revision
    end
    if revision~=nil and scopeLayoutCache[scope] then return scopeLayoutCache[scope] end
    local value = type(Feature.GetScopeSettingsProjection) == "function" and Feature:GetScopeSettingsProjection(scope) or nil
    if type(value) == "table" then
        if revision~=nil then scopeLayoutCache[scope]=value end
        return value
    end
    return Settings()
end
local function LayerSettings(poolKey)
    local scope=UnitScope(poolKey)
    local base=ScopeSettings(scope)
    -- 无 slots 的历史存档完整保留整体 head/fixed 路径；不为它构造第二套控件。
    local split=type(base.placement)=='table' and type(base.placement.slots)=='table'
    if not split then return not FixedLayer(poolKey) and base or nil end
    if type(Feature.GetHudLayerSettingsProjection)~='function' then return not FixedLayer(poolKey) and base or nil end
    local revision=tonumber(Feature.settingsRevision)
    local key=poolKey..':layer'
    if revision~=nil and scopeLayoutCache[key] then return scopeLayoutCache[key] end
    local value=Feature:GetHudLayerSettingsProjection(scope,FixedLayer(poolKey) and 'fixed' or 'head')
    if revision~=nil then scopeLayoutCache[key]=value end
    return value
end
local function FeatureEnabled()
    return S.FeatureRuntime ~= nil and S.FeatureRuntime:IsEnabled("combat_buff_display") == true
end
local function ScopeEnabled(scope, settings)
    return scope == "player" and settings.headPlayer ~= false or scope == "target" and settings.headTarget ~= false
end
-- 渲染门：headEnabled 且至少启用一个组件时启动头顶显示；Buff/debuff 白名单由 ProjectPlates 判断，表现层不能持有或绕过追踪策略。
local function HasRenderableComponents(settings, scope)
    local components = type(settings.components) == "table" and settings.components or {}
    -- 目标自定义名字是独立可见组件。只有 Store 已有至少一条且显示开关开启时才作为启动理由，
    -- 空备注库不会额外持有 Renderer Consumer；位置采集由 Feature 同一 gate 配套开启。
    if scope == "target" then
        if settings.componentLayer==true then
            if type(settings.targetAlias)=='table' and settings.targetAlias.enabled==true then return true end
        elseif type(Feature.IsTargetAliasHeadEnabled) == "function" and Feature:IsTargetAliasHeadEnabled() then return true end
    end
    -- plate 只是原生血条的代理锚点，不绘制；不能用它启动 Consumer，否则全关后 Aura lane 仍会运行。
    for _, key in ipairs(RENDERABLE_KEYS) do
        local component = components[key]
        -- 名称没有 component.enabled；职业图标关闭时，文字仍可独立启动 HUD Consumer。
        if key=="class" then
            local info=type(settings.info)=="table" and settings.info or {}
            if info.enabled~=false and (info.showClass~=false or (component~=nil and component.enabled~=false)) then return true end
        elseif component == nil or component.enabled ~= false then
            -- distance/gearScore 属于 info 区，info 关闭后不能单独启动 Consumer；
            -- 职业图标与文字另按各自开关判断，避免隐藏 HUD 仍保持 50ms 数据通道。
            if key ~= "distance" and key ~= "gearScore" then return true end
            local info = type(settings.info) == "table" and settings.info or {}
            if info.enabled ~= false then
                if key == "gearScore" and info.showGear ~= false then return true end
                if key == "distance" and info.showDistance ~= false then return true end
            end
        end
    end
    return false
end


local function MakeIcon(scope, index)
    local root, err = S.UI:CreateEmptyWidget(P.pools[scope].root, "v3_buff_head_" .. scope .. "_icon_" .. tostring(index), 0, 0, 40, 40, false, P.owner)
    if root == nil then return nil, err end
    root.rsUiOwner = P.owner
    local icon = root.CreateIconDrawable and root:CreateIconDrawable("artwork") or nil
    -- 装备品质使用基础物品图标上方的第二层纹理，仅池中标记实际渲染装备时延迟分配，普通 Aura 槽不额外分配 drawable。
    local stack = S.UI:CreateLabel(root, "v3_buff_head_" .. scope .. "_stack_" .. tostring(index), "", 0, 0, 18, 14, 9, "strong", "RIGHT", true)
    local time = S.UI:CreateLabel(root, "v3_buff_head_" .. scope .. "_time_" .. tostring(index), "", 0, 0, 40, 12, 8, "default", "RIGHT", true)
    if S.Theme and S.Theme.SetWorldTextPalette then S.Theme:SetWorldTextPalette(stack);S.Theme:SetWorldTextPalette(time) end
    if icon == nil or stack == nil or time == nil then
        S.UI:SetVisible(root, false, P.owner)
        return nil, "buff_head_marker_child_create_failed"
    end
    S.UI:SetVisible(root, false, P.owner)
    return { root=root, icon=icon, grade=nil, stack=stack, time=time, iconPath=nil, gradePath=nil, layout={}, scope=scope }
end

local function MakeLabel(scope, index)
    local label, err = S.UI:CreateLabel(UIParent, "v3_buff_head_" .. scope .. "_label_" .. tostring(index), "", 0, 0, 120, 16, 10, "strong", "CENTER", true)
    if label == nil then return nil, err end
    if S.Theme and S.Theme.SetWorldTextPalette then S.Theme:SetWorldTextPalette(label) end
    S.UI:SetVisible(label, false, P.owner)
    return { root=label, text="" }
end

local function MakeCastBar(scope)
    local root, err = S.UI:CreateEmptyWidget(P.pools[scope].root, "v3_buff_head_" .. scope .. "_castbar", 0, 0, 120, 8, false, P.owner)
    if root == nil then return nil, err end
    root.rsUiOwner = P.owner
    local bg = root.CreateColorDrawable and root:CreateColorDrawable(0.10, 0.10, 0.12, 0.85, "overlay") or nil
    local fill = root.CreateColorDrawable and root:CreateColorDrawable(0.96, 0.72, 0.12, 0.95, "overlay") or nil
    local text = S.UI:CreateLabel(root, "v3_buff_head_" .. scope .. "_cast_text", "", 0, 0, 120, 14, 10, "default", "CENTER", true)
    if S.Theme and S.Theme.SetWorldTextPalette then S.Theme:SetWorldTextPalette(text) end
    if bg == nil or fill == nil or text == nil then
        S.UI:SetVisible(root, false, P.owner)
        return nil, "buff_head_castbar_child_create_failed"
    end
    S.UI:SetVisible(root, false, P.owner)
    return { root=root, bg=bg, fill=fill, text=text, barW=120, layout={} }
end

local function MakeInfo(scope, settings, info)
    local parent = P.pools[scope].root
    settings=type(settings)=='table' and settings or {}
    -- 固定层按启用组件延迟建子控件；仅固定距离时不创建职业图标、别名或施法条。
    -- 已创建对象始终留在原父链，后续切换只隐藏或复用，不 reparent Native。
    local selective=FixedLayer(scope) and settings.componentLayer==true
    local cfg=type(settings.info)=='table' and settings.info or {}
    local components=type(settings.components)=='table' and settings.components or {}
    info=info or {classText='',gearText='',distanceText='',aliasText=''}
    local function Label(field,suffix,width,font,needed)
        if info[field] or not needed then return true end
        local alias=field=='aliasRoot'
        local root,err=S.UI:CreateLabel(parent,'v3_buff_head_'..scope..suffix,'',0,0,width,alias and 18 or 16,font,alias and 'strong' or 'default','CENTER',true)
        if not root then return false,err end
        info[field]=root
        if S.Theme and S.Theme.SetWorldTextPalette then S.Theme:SetWorldTextPalette(root) end
        S.UI:SetVisible(root,false,P.owner)
        return true
    end
    local visible=cfg.enabled~=false
    local ok,err=Label('classTextRoot','_info_class',120,10,not selective or (visible and cfg.showClass~=false))
    if not ok then return nil,err end
    ok,err=Label('gearRoot','_info_gear',90,10,not selective or (visible and cfg.showGear~=false and (components.gearScore or {}).enabled~=false))
    if not ok then return nil,err end
    ok,err=Label('distanceRoot','_info_distance',90,10,not selective or (visible and cfg.showDistance~=false and (components.distance or {}).enabled~=false))
    if not ok then return nil,err end
    ok,err=Label('aliasRoot','_alias',180,12,UnitScope(scope)=='target' and (not selective or (settings.targetAlias or {}).enabled==true))
    if not ok then return nil,err end
    if not info.iconRoot and (not selective or (visible and (components.class or {}).enabled~=false)) then
        info.iconRoot=S.UI:CreateEmptyWidget(parent,'v3_buff_head_'..scope..'_class_icon',0,0,16,16,false,P.owner)
        if not info.iconRoot then return nil,'buff_head_class_icon_create_failed' end
        info.icon=info.iconRoot.CreateIconDrawable and info.iconRoot:CreateIconDrawable('artwork') or nil
        S.UI:SetVisible(info.iconRoot,false,P.owner)
    end
    info.root=info.classTextRoot
    return info
end

local function RequiredIconCount(settings)
    settings = type(settings) == "table" and settings or Settings()
    local components = type(settings.components) == "table" and settings.components or {}
    local buff = components.buffs or {}
    local debuff = components.debuffs or {}
    local cooldown = components.cooldowns or {}
    local buffMax = math.max(1, math.min(64, math.floor(N(buff.maxPerRow, 8) * N(buff.maxRows, 2))))
    local debuffMax = math.max(1, math.min(64, math.floor(N(debuff.maxPerRow, 8) * N(debuff.maxRows, 2))))
    local cooldownMax = math.max(1, math.min(64, math.floor(N(cooldown.maxPerRow, 8) * N(cooldown.maxRows, 2))))
    if settings.componentLayer==true then
        local total=(buff.enabled~=false and buffMax or 0)+(debuff.enabled~=false and debuffMax or 0)
            +(cooldown.enabled~=false and cooldownMax or 0)
        for _,key in ipairs({'mainHand','offHand','ranged','wings'}) do
            if (components[key] or {}).enabled~=false then total=total+1 end
        end
        return total
    end
    -- CD 与 Buff/Debuff 共用既有 marker pool，
    -- 只按用户可见几何上限预分配，不为 256 个收藏技能建控件；装备仍保留 8 个固定余量。
    return buffMax + debuffMax + cooldownMax + 8
end

function P:EnsurePools(settings)
    -- player/target 的 maxPerRow/maxRows 现在可独立；池容量必须取两者
    -- 最大值，否则目标配置放大后会出现“设置已保存但最后几枚图标没有 pooled marker”。
    local iconCount = 0
    for _, scope in ipairs(SCOPES) do
        iconCount = math.max(iconCount, RequiredIconCount(ScopeSettings(scope)))
    end
    if iconCount <= 0 then iconCount = RequiredIconCount(type(settings) == "table" and settings or Settings()) end
    for _, scope in ipairs(POOL_KEYS) do
        local layerSettings=LayerSettings(scope)
        local active=layerSettings and (not FixedLayer(scope) or HasRenderableComponents(layerSettings,UnitScope(scope)))
        if active then
        local pool = self.pools[scope]
        if not pool then pool={icons={},labels={}};self.pools[scope]=pool end
        pool.unitScope,pool.layer=UnitScope(scope),FixedLayer(scope) and 'fixed' or 'head'
        local required=layerSettings.componentLayer==true and RequiredIconCount(layerSettings) or iconCount
        -- 新建时就固定父链，绝不reparent已有Native控件。所有子项落在union正坐标内，
        -- 避免小父容器裁剪；移动只写这个无命中父容器，职业/装备/Buff不会逐个追赶血条。
        if pool.root == nil then
            pool.root = S.UI:CreateEmptyWidget(UIParent, "v3_buff_head_" .. scope .. "_plate_root", 0, 0, 1, 1, false, self.owner)
            if pool.root == nil then return false, "buff_head_plate_root_create_failed" end
            pool.placements, pool.placementCount = {}, 0
            S.UI:SetVisible(pool.root, false, self.owner)
            self.metrics.allocated = self.metrics.allocated + 1
        end
        for index = #pool.icons + 1, required do
            local marker, err = MakeIcon(scope, index)
            if marker == nil then return false, err end
            pool.icons[index] = marker
            self.metrics.allocated = self.metrics.allocated + 1
        end
        if pool.cast == nil and (layerSettings.componentLayer~=true or (layerSettings.components.castBar or {}).enabled~=false) then
            local cast, err = MakeCastBar(scope)
            if cast == nil then return false, err end
            pool.cast = cast
            self.metrics.allocated = self.metrics.allocated + 1
        end
        if pool.info == nil or FixedLayer(scope) then
            local allocated=pool.info==nil
            local info, err = MakeInfo(scope,layerSettings,pool.info)
            if info == nil then return false, err end
            pool.info = info
            if allocated then self.metrics.allocated = self.metrics.allocated + 1 end
        end
        end
    end
    return true
end

local function HideIcon(marker)
    if marker and marker.root then S.UI:SetVisible(marker.root, false, P.owner);marker.contentCommitted=false end
end
local function HideScope(scope)
    local pool = P.pools[scope]
    if pool == nil then return end
    pool.dynamicLayout=nil
    if pool.root then
        pool.visibilityRequested=false
        if type(S.UI.EnsureVisible)=="function" then
            pool.rootVisibilityAccepted=S.UI:EnsureVisible(pool.root,false,P.owner)==true
            if pool.rootVisibilityAccepted then pool.rootVisible=false else pool.rootVisible=nil end
        else S.UI:SetVisible(pool.root,false,P.owner);pool.rootVisible=nil;pool.rootVisibilityAccepted=nil end
    end
    pool.rootVisibilityReason=pool.rootVisibilityAccepted==false and "visibility_write_rejected" or "scope_hidden"
    pool.ready = false
    for _, marker in ipairs(pool.icons) do HideIcon(marker) end
    if pool.labels then for _, label in ipairs(pool.labels) do if label.root then S.UI:SetVisible(label.root, false, P.owner) end end end
    if pool.cast then S.UI:SetVisible(pool.cast.root, false, P.owner) end
    if pool.info then
        if pool.info.classTextRoot then S.UI:SetVisible(pool.info.classTextRoot, false, P.owner) end
        if pool.info.gearRoot then S.UI:SetVisible(pool.info.gearRoot, false, P.owner) end
        if pool.info.distanceRoot then S.UI:SetVisible(pool.info.distanceRoot, false, P.owner) end
        if pool.info.aliasRoot then S.UI:SetVisible(pool.info.aliasRoot, false, P.owner) end
        if pool.info.iconRoot then S.UI:SetVisible(pool.info.iconRoot, false, P.owner) end
    end
end
function P:HideAll()
    for _, scope in ipairs(POOL_KEYS) do HideScope(scope) end
    return true
end


-- 内容布局以单位原点(0,0)计算，先记录所有子项边界再统一平移到父容器的正坐标。
-- 只在内容/设置变更时执行，不在每渲染帧构建表；每个placement对象在池里复用。
local function Place(pool, widget, x, y, w, h, component)
    local n = (pool.placementCount or 0) + 1
    local row = pool.placements[n] or {}
    pool.placements[n], pool.placementCount = row, n
    row.widget, row.x, row.y, row.w, row.h = widget, x, y, w, h
    row.rawX,row.rawY,row.component=x,y,component or pool.currentComponent
    pool.minX = math.min(pool.minX or x, x); pool.minY = math.min(pool.minY or y, y)
    pool.maxX = math.max(pool.maxX or x+w, x+w); pool.maxY = math.max(pool.maxY or y+h, y+h)
end
local function CommitPlacements(pool)
    if pool.componentPlacements then
        -- 分组件固定层只消费 Feature 的屏幕万分比投影。每组第一项是自己的锚点，
        -- 其余项保留原局部几何；一个组件的图标数/文字宽度不会移动其它组件。
        local width,height
        if type(Feature.GetFixedHudViewport)=='function' then width,height=Feature:GetFixedHudViewport() end
        local origins={}
        pool.minX,pool.minY,pool.maxX,pool.maxY=nil,nil,nil,nil
        for i=1,pool.placementCount do
            local row=pool.placements[i]
            local origin=origins[row.component]
            if not origin then
                local slot=pool.componentPlacements[row.component]
                local x,y
                if slot and type(Feature.ComputeFixedHudAnchor)=='function' then x,y=Feature.ComputeFixedHudAnchor(slot,width,height) end
                if x==nil or y==nil then pool.ready=false;pool.fixedPlacementError='fixed_component_anchor_unavailable';return false end
                origin={x=x-row.rawX,y=y-row.rawY};origins[row.component]=origin
            end
            row.x,row.y=row.rawX+origin.x,row.rawY+origin.y
            pool.minX=math.min(pool.minX or row.x,row.x);pool.minY=math.min(pool.minY or row.y,row.y)
            pool.maxX=math.max(pool.maxX or row.x+row.w,row.x+row.w);pool.maxY=math.max(pool.maxY or row.y+row.h,row.y+row.h)
        end
        pool.placementViewportW,pool.placementViewportH=width,height
        pool.fixedPlacementError=nil
    end
    local left, top = math.floor(pool.minX or 0), math.floor(pool.minY or 0)
    pool.offsetX, pool.offsetY = left, top
    pool.width = math.max(1, math.ceil(pool.maxX or 1)-left)
    pool.height = math.max(1, math.ceil(pool.maxY or 1)-top)
    -- 父容器与子锚点必须整体被接受。部分拒写时隐藏该组并重试，不能提交半新半旧的布局。
    local accepted = true
    if type(S.UI.EnsureExtent)=="function" then
        accepted = S.UI:EnsureExtent(pool.root,pool.width,pool.height,P.owner) == true
    else S.UI:SetExtent(pool.root,pool.width,pool.height,P.owner) end
    for i=1,pool.placementCount do
        local row=pool.placements[i]
        if type(S.UI.EnsureAnchor)=="function" then
            if S.UI:EnsureAnchor(row.widget,pool.root,row.x-left,row.y-top,P.owner)~=true then accepted=false end
        else S.UI:SetAnchor(row.widget,pool.root,row.x-left,row.y-top,P.owner) end
    end
    pool.ready = accepted and pool.placementCount > 0
    if not accepted then
        P.motionMetrics.anchorFailures=P.motionMetrics.anchorFailures+1
        P.textureRetryAt=(S.NowMs and S.NowMs() or 0)+50
    end
end
-- SetIconTexture的false也可能是diff无变化，所以通过Ensure契约区分成功与拒写。
-- 路径缓存只能在确认提交后改变；失败先隐藏旧武器并50ms后重试，不能把旧图当新事实。
local function Texture(cache, field, drawable, path)
    if cache[field] == path then return true end
    local ok, _, err
    if type(S.UI.EnsureIconTexture) == "function" then ok, _, err = S.UI:EnsureIconTexture(drawable, path, P.owner)
    else ok = S.UI:SetIconTexture(drawable, path, P.owner) end
    if ok == true then cache[field] = path; return true end
    cache[field] = nil -- 清除成功但添加失败可能已擦掉旧图；返回旧武器时也必须重新提交。
    P.motionMetrics.textureFailures = P.motionMetrics.textureFailures + 1
    P.motionMetrics.lastTextureError = tostring(err or "texture_write_rejected")
    P.textureRetryAt = (S.NowMs and S.NowMs() or 0) + 50
    return false
end

-- 字体取当前 scope 的 component.fontSize，再乘 plateScale；旧代码总按图标比例重算，
-- 曾导致校准保存后正式字体不变。fontSize<=0 才保留比例回退，供无字体配置的装备池使用。
local function ResolveIconFontSize(cfg, scale, size, role)
    local configured = tonumber(type(cfg) == "table" and cfg.fontSize or nil) or 0
    if configured > 0 then
        return math.max(8, math.floor(configured * math.max(0.1, tonumber(scale) or 1)))
    end
    local ratio = role == "stack" and 0.34 or 0.32
    return math.max(8, math.floor((tonumber(size) or 24) * ratio))
end
P.ResolveIconFontSize = ResolveIconFontSize
P.BuffIconFontSizeContractVersion = 1

local function LayoutIcon(marker, size, showStacks, showTime, stackFontSize, timeFontSize)
    local cache = marker.layout
    if cache.size == size and cache.showStacks == showStacks and cache.showTime == showTime
        and cache.stackFontSize == stackFontSize and cache.timeFontSize == timeFontSize then return end
    cache.size, cache.showStacks, cache.showTime = size, showStacks, showTime
    cache.stackFontSize, cache.timeFontSize = stackFontSize, timeFontSize
    -- 剩余时间标签嵌在图标右下角，不增加行高，始终可见且不撑开行；叠层计数保留在右上角。
    local totalH = size
    S.UI:SetExtent(marker.root, size, totalH, P.owner)
    S.UI:SetExtent(marker.icon, size, size, P.owner)
    S.UI:SetAnchor(marker.icon, marker.root, 0, 0, P.owner)
    if marker.grade ~= nil then
        S.UI:SetExtent(marker.grade, size, size, P.owner)
        S.UI:SetAnchor(marker.grade, marker.root, 0, 0, P.owner)
    end
    S.UI:SetAnchor(marker.stack, marker.root, 0, 0, P.owner)
    S.UI:SetExtent(marker.stack, size - 2, math.max(12, math.floor(size * 0.5)), P.owner)
    S.UI:SetAnchor(marker.time, marker.root, 0, math.max(0, size - 10), P.owner)
    S.UI:SetExtent(marker.time, size - 1, 10, P.owner)
    S.UI:SetFontSize(marker.stack, stackFontSize, P.owner)
    S.UI:SetFontSize(marker.time, timeFontSize, P.owner)
    S.UI:SetVisible(marker.stack, showStacks, P.owner)
    S.UI:SetVisible(marker.time, showTime, P.owner)
end

local function TextWidth(text, fontSize)
    return math.max(24, math.floor(#tostring(text or "") * (fontSize or 10) * 0.62) + 8)
end

-- 成组职业名不按 UTF-8 字节数预留空白；中日韩全宽字与拉丁/西里尔字分别估宽。
-- 只用于用户明确选择的成组模式，保留历史固定槽的文字几何。
local function PairedNameWidth(text,font)
    local width,index=0,1
    while index<=#text do
        local byte=text:byte(index);local bytes=byte<128 and 1 or byte<224 and 2 or byte<240 and 3 or 4
        width=width+font*(bytes>=3 and 1 or .62);index=index+bytes
    end
    return math.max(2,math.ceil(width)+2)
end

-- 目标别名只由目标血条中心、plateScale 和自身配置定位；与正式 Renderer、校准器共用此纯函数，
-- 不能让兄弟显隐、行数或文字长度推动它。
function P.ComputeTargetAliasLayout(text, cfg, centerX, centerY, scale)
    text = tostring(text or "")
    cfg = type(cfg) == "table" and cfg or {}
    scale = math.max(0.01, tonumber(scale) or 1)
    local font = math.max(8, math.min(32, math.floor(N(cfg.fontSize, 12) * scale)))
    local height = math.max(14, font + 5)
    local width = math.min(360, math.max(48, TextWidth(text ~= "" and text or "自定义名字", font)))
    local alpha = math.max(0.1, math.min(1, N(cfg.alpha, 1)))
    local x = math.floor(N(centerX, 0) + N(cfg.x, 0) * scale - width / 2)
    local y = math.floor(N(centerY, 0) + N(cfg.y, -94) * scale)
    return { text=text, x=x, y=y, width=width, height=height, font=font, alpha=alpha, enabled=cfg.enabled ~= false }
end

local function ApplyIcon(marker, row, size, cfg, x, y, showStacks, showTime, scale,channel)
    local stackFontSize = ResolveIconFontSize(cfg, scale, size, "stack")
    local timeFontSize = ResolveIconFontSize(cfg, scale, size, "time")
    LayoutIcon(marker, size, showStacks, showTime, stackFontSize, timeFontSize)
    if type(cfg) == "table" then S.UI:SetAlpha(marker.root, math.max(0.1, math.min(1, N(cfg.alpha, 1))), P.owner) end
    local path = tostring(row and row.iconPath or "")
    if (path ~= "" and path or UNKNOWN_ICON) ~= marker.iconPath then
        local actual = path ~= "" and path or UNKNOWN_ICON
        if Texture(marker, "iconPath", marker.icon, actual) ~= true then
            HideIcon(marker); return false
        end
    end
    local gradePath = tostring(row and row.gradeIconPath or "")
    if gradePath ~= "" and marker.grade == nil and marker.root ~= nil and type(marker.root.CreateIconDrawable) == "function" then
        marker.grade = marker.root:CreateIconDrawable("artwork")
        if marker.grade ~= nil then
            S.UI:SetExtent(marker.grade, size, size, P.owner)
            S.UI:SetAnchor(marker.grade, marker.root, 0, 0, P.owner)
            S.UI:SetVisible(marker.grade, false, P.owner)
        end
    end
    if marker.grade ~= nil then
        if gradePath ~= marker.gradePath then
            if gradePath ~= "" then
                if Texture(marker, "gradePath", marker.grade, gradePath) ~= true then HideIcon(marker); return false end
            else marker.gradePath = "" end
        end
        S.UI:SetVisible(marker.grade, gradePath ~= "", P.owner)
    end
    marker.stack:SetText((showStacks and N(row.stack, 1) > 1) and tostring(math.floor(N(row.stack, 1))) or "")
    marker.time:SetText(showTime and tostring(row.timeText or "--") or "")
    if channel then
        TextColor(marker.time,marker.scope,channel..'Time')
        if showStacks then TextColor(marker.stack,marker.scope,channel..'Stacks')end
    end
    -- 整行/整组已统一限制在屏幕内，各图标按精确槽位放置，避免成员堆叠。
    Place(P.pools[marker.scope], marker.root, x, y, size, size)
    -- SetVisible 的 false 也表示无需重复写入；EnsureVisible 才能区分已接受与明确拒写。
    -- 记录的是 RSUI 提交状态，不把它当作 GPU 像素读回。无该门面的旧测试宿主仍保持原绘制行为。
    if type(S.UI.EnsureVisible)=="function" then marker.contentCommitted=S.UI:EnsureVisible(marker.root,true,P.owner)==true
    else S.UI:SetVisible(marker.root,true,P.owner);marker.contentCommitted=nil end
end

-- 渲染组件的横向图标行并返回已用槽数；整行作为一组限制边界，各图标保持精确间距。
local function RenderIconRow(scope, pool, rows, cfg, centerX, rowY, showStacks, showTime, slotOffset, size, gap, scale,channel,firstIndex,rowCount)
    local used = 0
    size = math.max(8, math.floor(tonumber(size) or N(cfg.size, 24)))
    gap = math.max(0, math.floor(tonumber(gap) or N(cfg.spacing, 2)))
    -- 旧横排直接消费本次 detached 行的区间，避免每排复制临时 slice；不留存实时行引用。
    firstIndex = firstIndex or 1
    local count = math.min(rowCount or #rows, 16, #rows-firstIndex+1)
    local totalW = count * size + math.max(0, count - 1) * gap
    local startX = math.floor(centerX + N(cfg.x, 0) - totalW / 2)
    -- 整个血条附着组在移动父容器时统一裁剪，不能单独拉回每一排图标。
    local startY = math.floor(tonumber(rowY) or 0)
    for index = 1, count do
        local marker = pool.icons[slotOffset + index]
        if marker == nil then break end
        ApplyIcon(marker, rows[firstIndex+index-1], size, cfg, startX + (index - 1) * (size + gap), startY, showStacks, showTime, scale,channel)
        used = used + 1
    end
    return used
end

-- 每个 pool/channel 只保留一套相对网格，最多四个 pool × 三个通道。
-- 不缓存 Buff/计时/元数据或 Native 提交；中心与裁剪仍用本轮值。公共纯布局继续返回独立快照。
local iconGridCache, iconGridRevision = {}, nil
local function CachedIconGrid(scope,channel,count,size,spacing,perRow,maxRows,vertical,growUp)
    local revision=tonumber(Feature.settingsRevision)
    if revision==nil or revision~=iconGridRevision then iconGridCache,iconGridRevision={},revision end
    local calculate=Feature.ComputeHudIconGrid
    if revision==nil then return calculate(count,size,spacing,perRow,maxRows,vertical,growUp)end
    local scoped=iconGridCache[scope]
    local entry=scoped and scoped[channel]
    if entry and entry.calculate==calculate and entry.count==count and entry.size==size
        and entry.spacing==spacing and entry.perRow==perRow and entry.maxRows==maxRows
        and entry.vertical==vertical and entry.growUp==growUp then return entry.grid end
    local grid=calculate(count,size,spacing,perRow,maxRows,vertical,growUp)
    if not scoped then scoped={};iconGridCache[scope]=scoped end
    scoped[channel]={calculate=calculate,count=count,size=size,spacing=spacing,perRow=perRow,maxRows=maxRows,
        vertical=vertical,growUp=growUp,grid=grid}
    return grid
end

-- 多行 Buff/debuff 从血条边缘分别向上/向下堆叠，由 MaxPerRow 与 MaxRows 限制。
local function RenderRows(scope, pool, rows, cfg, centerX, firstRowTop, showStacks, showTime, slotOffset, size, spacing, maxPerRow, maxRows, rowGap, direction, scale,channel)
    local used = 0
    local all = type(rows) == "table" and rows or {}
    local total = math.min(#all, maxPerRow * maxRows)
    if total <= 0 then return 0 end
    if (cfg.orientation=='horizontal'or cfg.orientation=='vertical')and type(Feature.ComputeHudIconGrid)=='function' then
        local grid=CachedIconGrid(scope,channel,total,size,spacing,maxPerRow,maxRows,cfg.orientation=='vertical',direction<0)
        local xOffset=N(cfg.x,0)*(channel=='cooldown'and scale or 1)
        local left=math.floor(centerX+xOffset+grid.left)
        local top=math.floor(firstRowTop+grid.top)
        for index,position in ipairs(grid.slots)do
            local marker=pool.icons[slotOffset+index];if not marker then break end
            ApplyIcon(marker,all[index],size,cfg,left+position.x,top+position.y,showStacks,showTime,scale,channel)
            used=used+1
        end
        return used
    end
    for r = 0, maxRows - 1 do
        local start = r * maxPerRow + 1
        local count = math.min(maxPerRow, total - r * maxPerRow)
        if count <= 0 then break end
        local rowTop = firstRowTop + direction * (r * rowGap)
        used = used + RenderIconRow(scope, pool, all, cfg, centerX, rowTop, showStacks, showTime, slotOffset + used, size, spacing, scale,channel,start,count)
    end
    return used
end

-- 间距取已验证的 Plates 布局，按默认图标尺寸放大 1.2 倍；位置均相对血条矩形计算。
local BUFF_TO_BAR = 8        -- 首行 Buff 底边到 bar.top。
local BUFF_ROW_GAP = 4       -- Buff 行间距。
local DEBUFF_TO_BAR = 8      -- 首行 debuff 顶边到 bar.bottom。
local DEBUFF_ROW_GAP = 4     -- debuff 行间距。
local INFO_TO_BUFF = 7       -- Info 底边到实际最上方 Buff 行顶边。
local INFO_TO_BAR = 9        -- 无 Buff 时 Info 底边到 bar.top。
local EQUIP_TO_BAR = 7       -- 装备内侧边到血条侧边。
local EQUIP_GAP = 4          -- 两个装备图标间距。

-- 每个组件的位置 = 血条基础槽 + 自身 x/y，实际 Buff 行数、装备有无只决定显示。
-- Info、Cast 保留历史默认两行时的基线；plateScale 统一缩放。
-- 极端尺寸允许重叠，由用户调自身偏移，不能自动推走兄弟组件。
local INFO_RESERVED_BUFF_ROWS = 2
local INFO_RESERVED_BUFF_SIZE = 29
local CAST_RESERVED_DEBUFF_ROWS = 2
local CAST_TO_BAR = 6
local CLASS_TEXT_RESERVED_WIDTH = 96

-- 纯布局输入为投影锚点、设置、受限 Buff/Debuff 数量和装备存在性，返回可直接应用的几何。
-- equip = {mainHand, offHand, ranged, wings}，各项为 bool。
local function ComputePlateLayout(anchorX, anchorY, settings, buffCount, debuffCount, equip)
    settings = type(settings) == "table" and settings or {}
    local plateCfg = type(settings.plate) == "table" and settings.plate or {}
    local infoCfg = type(settings.info) == "table" and settings.info or {}
    local components = type(settings.components) == "table" and settings.components or {}
    local scale = math.max(0.5, math.min(2, tonumber(settings.plateScale) or 1))

    -- NativeBarProxy 矩形是唯一几何锚点；只有 plate.x/y 偏移血条，其它偏移不得进入该链。
    local barW = math.max(24, math.floor(N(plateCfg.width, 180) * scale))
    local barH = math.max(8, math.floor(N(plateCfg.height, 24) * scale))
    local centerX = math.floor((tonumber(anchorX) or 0) + N(plateCfg.x, 0) * scale)
    local centerY = math.floor((tonumber(anchorY) or 0) + N(plateCfg.y, 0) * scale)
    local left = centerX - math.floor(barW / 2)
    local right = left + barW
    local top = centerY - math.floor(barH / 2)
    local bottom = centerY + math.floor(barH / 2)
    local bar = { centerX = centerX, centerY = centerY, left = left, right = right, top = top, bottom = bottom, width = barW, height = barH }

    -- Buff 行：row1.bottom = bar.top - BuffToBarGap，后续行以 BuffRowGap 向上堆叠；组件 y 仅作局部微调。
    local buffCfg = components.buffs or {}
    local buffSize = math.max(8, math.floor(N(buffCfg.size, 29) * scale))
    local buffSpacing = math.max(0, math.floor(N(buffCfg.spacing, 2) * scale))
    local buffMaxPerRow = math.max(1, math.min(16, math.floor(N(buffCfg.maxPerRow, 8))))
    local buffMaxRows = math.max(1, math.min(4, math.floor(N(buffCfg.maxRows, 2))))
    local buffGap = BUFF_TO_BAR * scale + math.floor(N(buffCfg.y, 0) * scale)
    local buffRowGap = BUFF_ROW_GAP * scale
    local buffFirstTop = bar.top - buffGap - buffSize          -- row1 顶边。
    local buffActualRows = math.min(buffMaxRows, math.ceil(buffCount / buffMaxPerRow))
    local buffTopMostTop = buffFirstTop - (buffActualRows - 1) * buffRowGap

    -- debuff 行：row1.top = bar.bottom + DebuffToBarGap，后续行以 DebuffRowGap 向下堆叠。
    local debuffCfg = components.debuffs or {}
    local debuffSize = math.max(8, math.floor(N(debuffCfg.size, 29) * scale))
    local debuffSpacing = math.max(0, math.floor(N(debuffCfg.spacing, 2) * scale))
    local debuffMaxPerRow = math.max(1, math.min(16, math.floor(N(debuffCfg.maxPerRow, 8))))
    local debuffMaxRows = math.max(1, math.min(4, math.floor(N(debuffCfg.maxRows, 2))))
    local debuffGap = DEBUFF_TO_BAR * scale + math.floor(N(debuffCfg.y, 0) * scale)
    local debuffRowGap = DEBUFF_ROW_GAP * scale
    local debuffFirstTop = bar.bottom + debuffGap

    -- Info 行使用固定语义槽，运行 Buff 行数不能移动它；保留两行默认视觉基线，避免目标当前 0/1/2 个 Buff 导致已有布局跳变。
    local infoFont = math.max(8, math.floor(N(infoCfg.fontSize, 12) * scale))
    local infoH = infoFont + 4
    local infoReservedLift = (BUFF_TO_BAR + INFO_RESERVED_BUFF_SIZE
        + math.max(0, INFO_RESERVED_BUFF_ROWS - 1) * BUFF_ROW_GAP + INFO_TO_BUFF) * scale
    local infoTop = bar.top - infoReservedLift - infoH
    infoTop = infoTop + math.floor(N(infoCfg.y, 0) * scale)

    -- 装备位于血条两侧：左侧从左到右为 mainHand -> offHand -> ranged -> plate，使远程槽紧靠副手右边；右侧仅 wings/back。组件 x/y 仅作局部微调；
    -- 槽位返回未钳制的绝对原点，渲染器统一限制整组，不能逐图标钳制。
    local function EquipSlots(edgeStart, direction, keys)
        local slots = {}
        for semanticIndex, key in ipairs(keys) do
            local cfg = components[key] or {}
            local enabled = equip[key] == true
            if enabled then
                local size = math.max(8, math.floor(N(cfg.size, 26) * scale))
                local gap = math.max(1, math.floor(EQUIP_GAP * scale))
                -- 装备 semanticIndex 由 preset 固定，baseX 只取自身 size 与槽号。
                -- 缺副手、远程或改变图标尺寸不能移动兄弟；等尺寸时保持旧全装备布局，不同尺寸允许局部重叠。
                local baseX
                if direction < 0 then
                    baseX = edgeStart - semanticIndex * (size + gap)
                else
                    baseX = edgeStart + gap
                end
                local x = baseX + math.floor(N(cfg.x, 0) * scale)
                local y = bar.centerY - math.floor(size / 2) + math.floor(N(cfg.y, 0) * scale)
                slots[#slots + 1] = { key = key, x = x, y = y, size = size, baseX = baseX, semanticIndex = semanticIndex }
            end
        end
        return slots
    end
    -- EquipSlots(direction=-1) 的键顺序从血条向外；v4 的 ranged→offHand→mainHand
    -- 在屏幕上呈 mainHand→offHand→ranged。v3 保留旧顺序，只有新建、重置或未改旧默认才升到 v4。
    local presetVersion = math.floor(tonumber(settings.layoutPresetVersion) or 3)
    local leftOrder = presetVersion >= 4 and { "ranged", "offHand", "mainHand" } or { "offHand", "mainHand", "ranged" }
    local leftSlots = EquipSlots(bar.left, -1, leftOrder)
    local rightSlots = EquipSlots(bar.right, 1, { "wings" })
    local function GroupRect(slots)
        if #slots == 0 then return nil end
        local minX, maxX, maxW = math.huge, -math.huge, 0
        for _, s in ipairs(slots) do
            minX = math.min(minX, s.x); maxX = math.max(maxX, s.x + s.size); maxW = math.max(maxW, s.size)
        end
        return { left = minX, width = maxX - minX, maxW = maxW }
    end

    return {
        bar = bar,
        buff = { firstTop = buffFirstTop, rowGap = buffRowGap, size = buffSize, spacing = buffSpacing,
                 maxPerRow = buffMaxPerRow, maxRows = buffMaxRows, actualRows = buffActualRows, topMostTop = buffTopMostTop },
        debuff = { firstTop = debuffFirstTop, rowGap = debuffRowGap, size = debuffSize, spacing = debuffSpacing,
                   maxPerRow = debuffMaxPerRow, maxRows = debuffMaxRows, actualRows = math.min(debuffMaxRows, math.ceil(debuffCount / debuffMaxPerRow)) },
        info = { top = infoTop, font = infoFont, height = infoH },
        -- 读条使用独立固定语义槽；debuff 数量仅控制自身行，不能推动读条。
        cast = { top = bar.bottom + CAST_RESERVED_DEBUFF_ROWS * DEBUFF_ROW_GAP * scale + CAST_TO_BAR * scale },
        equip = { mainHand = equip.mainHand == true, offHand = equip.offHand == true, ranged = equip.ranged == true, wings = equip.wings == true },
        leftGroup = { slots = leftSlots, rect = GroupRect(leftSlots) },
        rightGroup = { slots = rightSlots, rect = GroupRect(rightSlots) },
        scale = scale,
    }
end

-- 公开纯布局函数，供验收几何测试及需要血条几何而不操作控件的 Consumer 使用。
P.ComputePlateLayout = ComputePlateLayout
P.CastYOffsetContractVersion = 1

-- 四个 Renderer 池各留一份纯几何；图标/倒计时/位置仍每轮读取，Native 提交仍走完整重试。
-- 只按已版本化的独立 settings、图标数量与装备存在性复用；旧宿主无 revision 时维持原计算路径。
local plateLayoutCache, plateLayoutRevision = {}, nil
local function CachedPlateLayout(scope, anchorX, anchorY, settings, buffCount, debuffCount, equip)
    local revision = tonumber(Feature.settingsRevision)
    if revision ~= plateLayoutRevision then plateLayoutCache, plateLayoutRevision = {}, revision end
    if revision == nil then return ComputePlateLayout(anchorX, anchorY, settings, buffCount, debuffCount, equip) end
    local mask = (equip.mainHand == true and 1 or 0) + (equip.offHand == true and 2 or 0)
        + (equip.ranged == true and 4 or 0) + (equip.wings == true and 8 or 0)
    local entry = plateLayoutCache[scope]
    if entry and entry.settings == settings and entry.buffCount == buffCount and entry.debuffCount == debuffCount
        and entry.mask == mask and entry.anchorX == anchorX and entry.anchorY == anchorY then return entry.layout end
    local layout = ComputePlateLayout(anchorX, anchorY, settings, buffCount, debuffCount, equip)
    plateLayoutCache[scope] = { settings=settings, buffCount=buffCount, debuffCount=debuffCount, mask=mask,
        anchorX=anchorX, anchorY=anchorY, layout=layout }
    return layout
end


-- 只提交变化的文字/进度；明确false或异常不提交缓存。
-- 失败先隐藏旧内容，由既有50ms内容重试恢复，不增加任务或Native采集。
local function CommitDynamicText(widget, cache, key, text)
    if cache[key]==text then return true end
    local ok,result=pcall(widget.SetText,widget,text)
    if ok~=true or result==false then
        P.textureRetryAt=(S.NowMs and S.NowMs() or 0)+50
        return false
    end
    cache[key]=text
    return true
end
local function RenderCastContent(bar, cast)
    local cache=bar.layout
    local ratio=math.max(0,math.min(1,cast.totalMs>0 and cast.currMs/cast.totalMs or 0))
    local fillW=math.max(1,math.floor(cache.barW*ratio))
    local accepted=true
    if type(S.UI.EnsureExtent)=="function" then accepted=S.UI:EnsureExtent(bar.fill,fillW,cache.barH,P.owner)==true
    else S.UI:SetExtent(bar.fill,fillW,cache.barH,P.owner) end
    local text=cache.showText and (cast.spellName or "") or ""
    if not CommitDynamicText(bar.text,cache,"text",text) then accepted=false end
    if not accepted then
        S.UI:SetVisible(bar.root,false,P.owner)
        P.textureRetryAt=(S.NowMs and S.NowMs() or 0)+50
    end
    return accepted
end

local function RenderCastBar(scope, cast, cfg, centerX, y, scale)
    local pool = P.pools[scope]
    if pool == nil or pool.cast == nil or cast == nil then return end
    local bar = pool.cast
    TextColor(bar.text,scope,'castName')
    scale = tonumber(scale) or 1
    local barW = math.max(24, math.floor(N(cfg.width, 120) * scale))
    local barH = math.max(4, math.floor(N(cfg.size, 6) * scale))
    local showText = cfg.showText ~= false
    local alpha = math.max(0.1, math.min(1, N(cfg.alpha, 1)))
    local x = math.floor(centerX + N(cfg.x, 0) * scale - barW / 2)
    -- castBar.y 是乘 plateScale 后的局部偏移；旧渲染遗漏它，曾导致上下校准保存后画面不动。
    y = N(y, 0) + N(cfg.y, 0) * scale
    local cache = bar.layout
    if cache.alpha ~= alpha then S.UI:SetAlpha(bar.root, alpha, P.owner); cache.alpha = alpha end
    if cache.barW ~= barW then cache.barW = barW end
    cache.barH,cache.showText=barH,showText
    -- 施法条/文字也归属同一个单位容器；总高度包含文字，避免父裁剪。
    local totalH = barH + (showText and 15 or 0)
    Place(pool, bar.root, x, math.floor(y), barW, totalH)
    S.UI:SetExtent(bar.root, barW, totalH, P.owner)
    S.UI:SetAnchor(bar.bg, bar.root, 0, 0, P.owner)
    S.UI:SetExtent(bar.bg, barW, barH, P.owner)
    S.UI:SetAnchor(bar.fill, bar.root, 0, 0, P.owner)
    local committed=RenderCastContent(bar,cast)
    S.UI:SetFontSize(bar.text, math.max(8, math.floor(N(cfg.fontSize, 10) * scale)), P.owner)
    S.UI:SetAnchor(bar.text, bar.root, 0, barH + 1, P.owner)
    S.UI:SetExtent(bar.text, barW, 14, P.owner)
    S.UI:SetVisible(bar.text, showText, P.owner)
    S.UI:SetVisible(bar.root, committed, P.owner)
end

-- 记录各作用域血条隐藏原因，为 RU 排查保留可见线索，如投影服务不可用、单位离屏、深度过滤。
local function RecordAnchorFailure(scope, reason)
    local entry = P.metrics.anchorFailures[scope]
    if type(entry) ~= "table" then entry = { count = 0, lastAt = 0, lastErr = nil }; P.metrics.anchorFailures[scope] = entry end
    entry.count = (tonumber(entry.count) or 0) + 1
    entry.lastAt = S.NowMs and S.NowMs() or 0
    entry.lastErr = tostring(reason or "anchor_unavailable")
end

-- 装备沿用局部布局。只由外层整组容器执行屏幕边缘约束，不能让装备/
-- Buff/职业各自夹紧到不同位置；这样移动与屏幕边缘的相对几何始终一致。
local function ApplyEquipGroup(scope, pool, plates, components, group, slotStart, scale)
    local slots = type(group) == "table" and group.slots or nil
    if slots == nil or #slots == 0 then return 0 end
    local used = 0
    for _, s in ipairs(slots) do
        local marker = pool.icons[slotStart + used + 1]
        if marker == nil then break end
        local item = type(plates) == "table" and plates[s.key] or {}
        local cfg = type(components) == "table" and components[s.key] or {}
        pool.currentComponent=s.key
        ApplyIcon(marker, { iconPath = item.icon, gradeIconPath = item.gradeIconPath, stack = nil, timeText = nil }, s.size, cfg, s.x, s.y, false, false, scale)
        used = used + 1
    end
    return used
end

-- 职业文字取 info，装分取 gearScore，距离取 distance，图标取 class；各用自己的几何和透明度。
-- 旧 renderer 合成单个 label，曾使装分、距离的已存字段无效。
-- ComputePlateLayout 已把 info.y 加入 top，此处先还原 baseY 再应用各自 Y，避免文字联动。
-- 固定槽为职业居左、装分居中、距离居右；字段缺失只隐藏自身。

-- 只格式化投影装分：compact 在 >=1000 时用 K，保留一位小数并去掉 .0；full 用整数。
-- 非数字占位原样显示。
function P.FormatGearScoreValue(value, mode)
    local raw = tostring(value == nil and "" or value)
    local n = tonumber(raw)
    if n == nil then return raw end
    n = math.max(0, math.floor(n + 0.5))
    if tostring(mode or "full") ~= "compact" or n < 1000 then return tostring(n) end
    local tenths = math.floor((n / 100) + 0.5)
    if tenths % 10 == 0 then return tostring(math.floor(tenths / 10)) .. "K" end
    return string.format("%.1fK", tenths / 10)
end

function P.ComputeInfoItemsLayout(plates, infoCfg, components, centerX, y, fontSize, scale, scope)
    plates, infoCfg, components = type(plates)=="table" and plates or {}, infoCfg or {}, components or {}
    scale = tonumber(scale) or 1
    local class = type(plates.class)=="table" and plates.class or {}
    local classCfg = components.class or {}
    local gearCfg = components.gearScore or {}
    local distanceCfg = components.distance or {}
    -- showClass 控制职业文字，class.enabled 控制图标；不能复用开关，否则关图标会连名字一起隐藏。
    local classValue = tostring(class.value or "")
    local classText = infoCfg.showClass ~= false and classValue or ""
    local rawGearText = infoCfg.showGear ~= false and gearCfg.enabled ~= false and type(plates.gearScore)=="table" and tostring(plates.gearScore.value or "") or ""
    local gearText = rawGearText ~= "" and P.FormatGearScoreValue(rawGearText, infoCfg.gearScoreFormat) or ""
    local distanceText = infoCfg.showDistance ~= false and distanceCfg.enabled ~= false and type(plates.distance)=="table" and tostring(plates.distance.value or "") or ""

    local classFont = math.max(8, math.floor(tonumber(fontSize) or 12))
    local gearFont = math.max(8, math.floor(N(gearCfg.fontSize, 12) * scale))
    local distanceFont = math.max(8, math.floor(N(distanceCfg.fontSize, 12) * scale))
    local specs = {}
    if classText ~= "" then specs[#specs+1] = { key="classText", raw=classText, font=classFont } end
    if gearText ~= "" then specs[#specs+1] = { key="gearScore", raw=gearText, font=gearFont } end
    if distanceText ~= "" then specs[#specs+1] = { key="distance", raw=distanceText, font=distanceFont } end
    for index, item in ipairs(specs) do
        -- 职业、装分、距离用几何间距分隔，不把装饰符写入真实文本；已有局部微调仍生效。
        item.gapBefore = index > 1 and math.max(3, math.floor(item.font * 0.25)) or 0
        item.text = item.raw
        item.width = TextWidth(item.text, item.font)
        item.height = math.max(12, item.font + 4)
    end

    local icon = classCfg.enabled ~= false and type(class.icon)=="string" and class.icon ~= "" and class.icon or nil
    local automaticSize = math.max(12, classFont + 2)
    local iconGap = icon and (automaticSize + 4) or 0
    local rowWidth = 0
    for _, item in ipairs(specs) do rowWidth = rowWidth + (item.gapBefore or 0) + item.width end
    local rowStartX = math.floor(centerX - (rowWidth + iconGap) / 2)
    local cursorX = rowStartX + iconGap
    local baseY = math.floor(N(y, 0) - N(infoCfg.y, 0) * scale)

    -- 正式 player/target 和校准预览必须显式传 scope，共用固定槽；复制 profile 后应得到同一几何。
    -- 缺少事实不回收槽位。未声明 scope 的旧只读调用保留流式布局，兼容外部工具。
    local runtimeScope = tostring(scope or "")
    if runtimeScope == "target" or runtimeScope == "player" then
        local gap = math.max(3, math.floor(math.max(classFont, gearFont, distanceFont) * 0.25))
        local gearSlotWidth = TextWidth("000000", gearFont)
        local gearLeft = math.floor(centerX - gearSlotWidth / 2)
        local gearRight = gearLeft + gearSlotWidth
        local classRight = gearLeft - gap
        local distanceLeft = gearRight + gap
        local out = { width=0, height=math.max(12,classFont+4), x=centerX, y=baseY, icon=icon }
        local minX, maxX = nil, nil
        local function AddBounds(x, width)
            minX = math.min(minX or x, x)
            maxX = math.max(maxX or (x + width), x + width)
        end
        if classText ~= "" then
            local width = classCfg.nameLinked==true and PairedNameWidth(classText,classFont)or TextWidth(classText, classFont)
            local x = math.floor(classRight - width + N(infoCfg.x,0))
            local yPos = math.floor(baseY + N(infoCfg.y,0) * scale)
            out.classText = { text=classText, displayText=classText, x=x, y=yPos, width=width, height=math.max(12,classFont+4), font=classFont, alpha=1 }
            AddBounds(x, width)
        end
        if gearText ~= "" then
            local width = TextWidth(gearText, gearFont)
            local x = math.floor(centerX - width / 2 + N(gearCfg.x,0) * scale)
            local yPos = math.floor(baseY + N(gearCfg.y,0) * scale)
            local alpha = math.max(.1,math.min(1,N(gearCfg.alpha,1)))
            out.gearScore = { text=gearText, displayText=gearText, x=x, y=yPos, width=width, height=math.max(12,gearFont+4), font=gearFont, alpha=alpha }
            AddBounds(x, width)
        end
        if distanceText ~= "" then
            local width = TextWidth(distanceText, distanceFont)
            local x = math.floor(distanceLeft + N(distanceCfg.x,0) * scale)
            local yPos = math.floor(baseY + N(distanceCfg.y,0) * scale)
            local alpha = math.max(.1,math.min(1,N(distanceCfg.alpha,1)))
            out.distance = { text=distanceText, displayText=distanceText, x=x, y=yPos, width=width, height=math.max(12,distanceFont+4), font=distanceFont, alpha=alpha }
            AddBounds(x, width)
        end
        local size = N(classCfg.size,0)>0 and math.max(8,math.floor(N(classCfg.size,0)*scale)) or automaticSize
        -- 职业文字以 classRight 右对齐，图标占其左侧固定 96px 槽。
        -- 名字长度和显隐不能移动图标；长文字可覆盖预留区，不能推走装分、距离。
        local classReservedWidth = math.floor(CLASS_TEXT_RESERVED_WIDTH * scale)
        local iconBaseX = classRight - classReservedWidth - 4 - automaticSize
        out.iconX = math.floor(iconBaseX + N(classCfg.x,0)*scale)
        out.iconY = baseY + math.floor(N(classCfg.y,0)*scale)
        out.iconSize = size
        out.iconAlpha = math.max(.1,math.min(1,N(classCfg.alpha,1)))
        if classCfg.nameLinked==true then
            local width=PairedNameWidth(classValue,classFont)
            local name=out.classText or {x=math.floor(classRight-width+N(infoCfg.x,0)),
                y=math.floor(baseY+N(infoCfg.y,0)*scale),height=math.max(12,classFont+4)}
            out.iconX=name.x-math.max(2,math.floor(4*scale))-size+math.floor(N(classCfg.x,0)*scale)
            out.iconY=name.y+math.floor((name.height-size)/2)+math.floor(N(classCfg.y,0)*scale)
        end
        if icon ~= nil then AddBounds(out.iconX, size) end
        out.x = minX or distanceLeft
        out.width = math.max(1, (maxX or (out.x + 1)) - out.x)
        return out
    end

    local out = { width=rowWidth, height=math.max(12,classFont+4), x=cursorX, y=baseY, icon=icon }
    for _, item in ipairs(specs) do
        cursorX = cursorX + (item.gapBefore or 0)
        local cfg, xOffset, yOffset, alpha = {}, 0, 0, 1
        if item.key == "classText" then
            xOffset, yOffset = N(infoCfg.x,0), N(infoCfg.y,0) * scale
        elseif item.key == "gearScore" then
            cfg=gearCfg; xOffset=N(cfg.x,0)*scale; yOffset=N(cfg.y,0)*scale; alpha=math.max(.1,math.min(1,N(cfg.alpha,1)))
        else
            cfg=distanceCfg; xOffset=N(cfg.x,0)*scale; yOffset=N(cfg.y,0)*scale; alpha=math.max(.1,math.min(1,N(cfg.alpha,1)))
        end
        out[item.key] = { text=item.raw, displayText=item.text, x=math.floor(cursorX+xOffset), y=math.floor(baseY+yOffset), width=item.width, height=item.height, font=item.font, alpha=alpha }
        cursorX = cursorX + item.width
    end
    local size = N(classCfg.size,0)>0 and math.max(8,math.floor(N(classCfg.size,0)*scale)) or automaticSize
    -- 图标锚定于基础信息行的未偏移基准，不消费 info.x/info.y；这样职业名称和职业图标
    -- 在 HUD 调整器中真正独立。class.x/y 仍只作用图标；schema7 仅新增装分文字格式，不改变图标几何。
    out.iconX = rowStartX + math.floor(N(classCfg.x,0)*scale)
    out.iconY = baseY + math.floor(N(classCfg.y,0)*scale)
    out.iconSize = size
    out.iconAlpha = math.max(.1,math.min(1,N(classCfg.alpha,1)))
    return out
end

-- 兼容只读 API：旧校准/外部测试若仍调用 ComputeInfoLayout，返回三段文字 union，而不是重新
-- 恢复单 label。新代码应读取 ComputeInfoItemsLayout 的 classText/gearScore/distance 子矩形。
function P.ComputeInfoLayout(plates, infoCfg, components, centerX, y, fontSize, scale, scope)
    local g=P.ComputeInfoItemsLayout(plates,infoCfg,components,centerX,y,fontSize,scale,scope)
    local minX,maxX,minY,maxY=nil,nil,nil,nil;local text={}
    for _,key in ipairs({"classText","gearScore","distance"}) do
        local item=g[key]
        if item then
            minX=math.min(minX or item.x,item.x);maxX=math.max(maxX or item.x+item.width,item.x+item.width)
            minY=math.min(minY or item.y,item.y);maxY=math.max(maxY or item.y+item.height,item.y+item.height)
            text[#text+1]=item.text
        end
    end
    return {text=table.concat(text," "),x=minX or g.x,y=minY or g.y,width=math.max(1,(maxX or g.x+1)-(minX or g.x)),height=math.max(1,(maxY or g.y+1)-(minY or g.y)),icon=g.icon,iconX=g.iconX,iconY=g.iconY,iconSize=g.iconSize,alpha=g.iconAlpha}
end

local function RenderTextItem(pool, widget, cache, cacheField, item, component)
    if widget == nil then return end
    if item == nil or item.text == "" then S.UI:SetVisible(widget,false,P.owner); cache[cacheField]=""; return end
    local rendered = item.displayText or item.text
    if not CommitDynamicText(widget,cache,cacheField,rendered) then S.UI:SetVisible(widget,false,P.owner);return end
    S.UI:SetFontSize(widget,item.font,P.owner)
    S.UI:SetAlpha(widget,item.alpha or 1,P.owner)
    S.UI:SetExtent(widget,item.width,item.height,P.owner)
    Place(pool,widget,item.x,item.y,item.width,item.height,component)
    S.UI:SetVisible(widget,true,P.owner)
end

local function RenderInfo(scope, plates, infoCfg, components, centerX, y, fontSize, scale)
    local pool = P.pools[scope]
    if pool == nil or pool.info == nil then return end
    local info = pool.info
    local g = P.ComputeInfoItemsLayout(plates,infoCfg,components,centerX,y,fontSize,scale,UnitScope(scope))
    TextColor(info.classTextRoot,scope,'classText');TextColor(info.gearRoot,scope,'gearScore')
    TextColor(info.distanceRoot,scope,'distance',plates.distance and plates.distance.meters)
    pool.dynamicLayout.distance=g.distance
    RenderTextItem(pool,info.classTextRoot,info,"classText",g.classText,'info')
    RenderTextItem(pool,info.gearRoot,info,"gearText",g.gearScore,'gearScore')
    RenderTextItem(pool,info.distanceRoot,info,"distanceText",g.distance,'distance')
    if info.iconRoot then
        -- 职业图标与职业名称是两个独立组件；隐藏名称不能连带隐藏图标。
        local showIcon = g.icon ~= nil and info.icon ~= nil
        if showIcon then
            showIcon = Texture(info,"iconPath",info.icon,g.icon)
            S.UI:SetExtent(info.iconRoot,g.iconSize,g.iconSize,P.owner)
            S.UI:SetExtent(info.icon,g.iconSize,g.iconSize,P.owner)
            S.UI:SetAnchor(info.icon,info.iconRoot,0,0,P.owner)
            S.UI:SetAlpha(info.iconRoot,g.iconAlpha,P.owner)
            Place(pool,info.iconRoot,g.iconX,g.iconY,g.iconSize,g.iconSize,'class')
        end
        S.UI:SetVisible(info.iconRoot,showIcon,P.owner)
    end
end

-- 目标别名独占 target 槽，位置、字号和透明度来自独立配置，不借用 info 或推动其它组件。
local function RenderTargetAlias(scope, plates, centerX, centerY, scale, settings)
    local pool = P.pools[scope]
    local info = pool and pool.info or nil
    local root = info and info.aliasRoot or nil
    if root == nil then return end
    TextColor(root,scope,'alias')
    local enabled=settings.componentLayer~=true or (settings.targetAlias or {}).enabled==true
    local alias = UnitScope(scope) == "target" and enabled and type(plates.alias) == "table" and plates.alias or nil
    local text = alias and tostring(alias.value or "") or ""
    local cfg = alias and type(alias.hud) == "table" and alias.hud or nil
    local g = P.ComputeTargetAliasLayout(text, cfg, centerX, centerY, scale)
    if text == "" or g.enabled ~= true then
        info.aliasText = ""
        S.UI:SetVisible(root, false, P.owner)
        return
    end
    if info.aliasText ~= text then root:SetText(text); info.aliasText = text end
    S.UI:SetFontSize(root, g.font, P.owner)
    S.UI:SetAlpha(root, g.alpha, P.owner)
    S.UI:SetExtent(root, g.width, g.height, P.owner)
    Place(pool, root, g.x, g.y, g.width, g.height,'alias')
    S.UI:SetVisible(root, true, P.owner)
end

local function RenderScope(scope, settings)
    local pool = P.pools[scope]
    if pool == nil then return end
    local unitScope=UnitScope(scope)
    if ScopeEnabled(unitScope, settings) ~= true then HideScope(scope); return end
    if unitScope=='target'and type(Feature.IsTargetSelf)=='function'and Feature:IsTargetSelf()then HideScope(scope);return end
    local plates = Feature:GetPlatesProjection(unitScope, settings)
    -- 所有内容在单位原点生成；屏幕移动留给MotionTick，绝不在这里重读投影Native。
    local anchorX, anchorY = 0, 0
    pool.placementCount, pool.minX, pool.minY, pool.maxX, pool.maxY = 0, nil, nil, nil, nil
    pool.componentPlacements=FixedLayer(scope) and settings.componentLayer==true and settings.componentPlacements or nil
    P.metrics.projections = P.metrics.projections + 1
    local components = type(settings.components) == "table" and settings.components or {}
    local infoCfg = type(settings.info) == "table" and settings.info or {}
    pool.dynamicLayout={revision=Feature.settingsRevision,distanceEnabled=infoCfg.enabled~=false
        and infoCfg.showDistance~=false and (components.distance or {}).enabled~=false,
        castEnabled=(components.castBar or {}).enabled~=false,castVisible=plates.cast~=nil}
    local showStacks = settings.headShowStacks ~= false
    local showTime = settings.headShowTime ~= false

    -- 装备显隐：无物品槽位折叠；远程槽保持独立组件。layout preset v4 的新建/玩家默认启用，历史自定义方案保留已存选择。
    local equip = {}
    for _, key in ipairs({ "mainHand", "offHand", "ranged", "wings" }) do
        local cfg = components[key] or {}
        local item = plates[key]
        -- 观察到类型但元数据缺图时不借“未知物品”伪装具体装备；待共享元数据补齐再绘制。
        equip[key] = cfg.enabled ~= false and item ~= nil and item.icon ~= nil
            and (item.source ~= "observed_buff" or item.icon ~= "")
    end

    local buffRows = plates.buffs or {}
    local debuffRows = plates.debuffs or {}
    local buffEnabled = (components.buffs or {}).enabled ~= false
    local debuffEnabled = (components.debuffs or {}).enabled ~= false
    local buffCount = buffEnabled and #buffRows or 0
    local debuffCount = debuffEnabled and #debuffRows or 0

    -- 统一纯布局权威层。
    local L = CachedPlateLayout(scope, anchorX, anchorY, settings, buffCount, debuffCount, equip)
    local bar = L.bar
    local scale = L.scale

    local slot = 0
    -- Buff 行从 bar.top 向上堆叠。
    if buffEnabled then
        pool.currentComponent='buffs'
        slot = slot + RenderRows(scope, pool, buffRows, components.buffs or {}, bar.centerX, L.buff.firstTop, showStacks, showTime, slot, L.buff.size, L.buff.spacing, L.buff.maxPerRow, L.buff.maxRows, L.buff.rowGap, -1, scale,'buff')
    end
    -- debuff 行从 bar.bottom 向下堆叠。
    if debuffEnabled then
        pool.currentComponent='debuffs'
        slot = slot + RenderRows(scope, pool, debuffRows, components.debuffs or {}, bar.centerX, L.debuff.firstTop, showStacks, showTime, slot, L.debuff.size, L.debuff.spacing, L.debuff.maxPerRow, L.debuff.maxRows, L.debuff.rowGap, 1, scale,'debuff')
    end
    -- 冷却行占单位锚点相对固定槽，不参与 Buff/Debuff/Info/Cast 兄弟几何；组件显现不能推动其它组件。
    local cooldownCfg = components.cooldowns or {}
    local cooldownRows = unitScope == "player" and (plates.cooldowns or {}) or {}
    if unitScope=="player" and (settings.componentLayer~=true or cooldownCfg.enabled~=false) then
        P.cooldownEvidence.lastRenderAt=S.NowMs and S.NowMs() or 0
        P.cooldownEvidence.inputRows=#cooldownRows
        P.cooldownEvidence.drawn,P.cooldownEvidence.rejected=0,0
    end
    if cooldownCfg.enabled ~= false and #cooldownRows > 0 then
        pool.currentComponent='cooldowns'
        local cdSize = math.max(8, math.floor(N(cooldownCfg.size, 29) * scale))
        local cdSpacing = math.max(0, math.floor(N(cooldownCfg.spacing, 2) * scale))
        local cdMaxPerRow = math.max(1, math.min(16, math.floor(N(cooldownCfg.maxPerRow, 8))))
        local cdMaxRows = math.max(1, math.min(4, math.floor(N(cooldownCfg.maxRows, 2))))
        local cdRowGap = math.max(1, math.floor(cdSize + 4 * scale))
        local cdTop = bar.centerY + math.floor(N(cooldownCfg.y, 90) * scale)
        local firstSlot=slot+1
        slot = slot + RenderRows(scope, pool, cooldownRows, cooldownCfg, bar.centerX, cdTop,
            false, true, slot, cdSize, cdSpacing, cdMaxPerRow, cdMaxRows, cdRowGap, 1, scale,'cooldown')
        -- 常数规模计数，不保存所有图标/Native 对象；仅用户导出时读取这一份现有绘制证据。
        for index=firstSlot,slot do
            if pool.icons[index].contentCommitted==true then P.cooldownEvidence.drawn=P.cooldownEvidence.drawn+1
            elseif pool.icons[index].contentCommitted==false then P.cooldownEvidence.rejected=P.cooldownEvidence.rejected+1 end
        end
        local evidence=P.cooldownEvidence
        evidence.nonemptyRenders=evidence.nonemptyRenders+1
        evidence.lastNonemptyAt=S.NowMs and S.NowMs() or 0
        evidence.lastNonemptyInput,evidence.lastNonemptyDrawn=#cooldownRows,evidence.drawn
    end
    -- 装备侧栏使用预计算分组，整组应用边界限制。
    slot = slot + ApplyEquipGroup(scope, pool, plates, components, L.leftGroup, slot, scale)
    slot = slot + ApplyEquipGroup(scope, pool, plates, components, L.rightGroup, slot, scale)
    for index = slot + 1, #pool.icons do HideIcon(pool.icons[index]) end

    -- Info 行（职业名、装备评分、距离）自动置于实际行上方。
    if infoCfg.enabled ~= false then
        RenderInfo(scope, plates, infoCfg, components, bar.centerX, L.info.top, L.info.font, scale)
    else
        local info = pool.info
        if info then
            if info.classTextRoot then S.UI:SetVisible(info.classTextRoot, false, P.owner) end
            if info.gearRoot then S.UI:SetVisible(info.gearRoot, false, P.owner) end
            if info.distanceRoot then S.UI:SetVisible(info.distanceRoot, false, P.owner) end
            if info.iconRoot then S.UI:SetVisible(info.iconRoot, false, P.owner) end
        end
    end
    RenderTargetAlias(scope, plates, bar.centerX, bar.centerY, scale,settings)

    -- 读条使用固定槽，未施法时隐藏；debuff 行不能移动它，RenderCastBar 中 cfg.y 是唯一局部 Y 调整。
    local castCfg = components.castBar or {}
    if castCfg.enabled ~= false and plates.cast ~= nil then
        pool.currentComponent='castBar'
        RenderCastBar(scope, plates.cast, castCfg, bar.centerX, L.cast.top, scale)
    else
        local cast = pool.cast
        if cast then S.UI:SetVisible(cast.root, false, P.owner) end
    end
    CommitPlacements(pool)
end

-- 校准时只隐藏正式 HUD，不能 Disable 或释放 Consumer，否则会丢真实锚点并改变采集生命周期。
-- 打开校准设 suppression，退出立即重绘；此开关只属会话，重载默认 false。
function P:SetCalibrationSuppressed(value, reason)
    local nextValue = value == true
    if self.calibrationSuppressed == nextValue then
        self.calibrationSuppressionReason = nextValue and tostring(reason or self.calibrationSuppressionReason or "hud_calibration") or nil
        if nextValue then self:HideAll() elseif self.running == true then self:VisualTick() end
        return true
    end
    self.calibrationSuppressed = nextValue
    self.calibrationSuppressionReason = nextValue and tostring(reason or "hud_calibration") or nil
    if nextValue then
        self.calibrationSuppressionCount = (tonumber(self.calibrationSuppressionCount) or 0) + 1
        self:HideAll()
    else
        self.calibrationRestoreCount = (tonumber(self.calibrationRestoreCount) or 0) + 1
        if self.running == true then self:VisualTick() else self:HideAll() end
    end
    return true
end
function P:IsCalibrationSuppressed() return self.calibrationSuppressed == true end

-- raw投影与raw视口只转换一次。组内子项全部不动，边缘裁剪平移整个union，
-- 禁止逐图标clamp/插值（会引入空间误导）；原生点不可用或在屏幕后时立即隐藏整组。
local function MoveRoots()
    local w,h
    if type(Feature.GetHeadViewport)=="function" then w,h=Feature:GetHeadViewport() end
    for _,scope in ipairs(POOL_KEYS) do
        local pool=P.pools[scope]
        local settings=LayerSettings(scope)
        if pool and settings then
        local unitScope=UnitScope(scope)
        local placement=type(settings.placement)=='table'and settings.placement or {}
        local x,y,depth,source,err
        local viewportW,viewportH=w,h
        if pool.componentPlacements then
            if type(Feature.GetFixedHudViewport)=='function'then viewportW,viewportH=Feature:GetFixedHudViewport()end
            if pool.placementViewportW~=viewportW or pool.placementViewportH~=viewportH or pool.fixedPlacementError then CommitPlacements(pool) end
            x,y,depth,source=0,0,1,'fixed_components'
            if type(Feature.IsHudUnitAvailable)=='function'and not Feature:IsHudUnitAvailable(unitScope)then x,y,err=nil,nil,'unit_unavailable'end
        elseif placement.mode=='fixed'and type(Feature.ComputeFixedHudAnchor)=='function'then
            if type(Feature.GetFixedHudViewport)=='function'then viewportW,viewportH=Feature:GetFixedHudViewport()end
            x,y,err=Feature.ComputeFixedHudAnchor(placement,viewportW,viewportH)
            if type(Feature.IsHudUnitAvailable)=='function'and not Feature:IsHudUnitAvailable(unitScope)then x,y,err=nil,nil,'unit_unavailable'end
            depth,source=1,'fixed_screen'
        else x,y,depth,source,err=Feature:GetPlatesAnchor(unitScope)end
        local valid=x~=nil and y~=nil and N(depth,1)>0
        if pool and not valid then
            local reason=tostring(err or "native_anchor_unavailable")
            if pool.lastAnchorFailure~=reason then RecordAnchorFailure(scope,reason) end
            pool.lastAnchorFailure=reason
        elseif pool then pool.lastAnchorFailure=nil end
        local selfTarget=unitScope=='target'and type(Feature.IsTargetSelf)=='function'and Feature:IsTargetSelf()
        local show=pool and pool.ready==true and valid and not selfTarget
        local visibilityReason=not valid and "native_anchor_unavailable" or not (pool and pool.ready) and "layout_not_ready" or "visible"
        if show then
            x,y=x+pool.offsetX,y+pool.offsetY
            -- 固定锚点遵守用户校准坐标；不能按内容包围盒夹紧，否则文字/图标变化会拖动整组。
            -- 锚点已限制在视口内，靠边的内容允许局部越界；恢复当前 HUD 可回到安全默认位置。
            if placement.mode~='fixed'and viewportW and viewportH and viewportW>0 and viewportH>0 then
                x=math.max(0,math.min(math.max(0,viewportW-pool.width),x))
                y=math.max(0,math.min(math.max(0,viewportH-pool.height),y))
            end
            x,y=math.floor(x+.5),math.floor(y+.5)
            if pool.screenX~=x or pool.screenY~=y then
                local ok
                if type(S.UI.EnsureAnchor)=="function" then ok=S.UI:EnsureAnchor(pool.root,UIParent,x,y,P.owner)
                else ok=S.UI:SetAnchor(pool.root,UIParent,x,y,P.owner) end
                if ok==true then
                    pool.screenX,pool.screenY=x,y
                    P.motionMetrics.rootWrites=P.motionMetrics.rootWrites+1
                else
                    show=false;P.motionMetrics.anchorFailures=P.motionMetrics.anchorFailures+1
                    visibilityReason="anchor_write_rejected"
                end
            end
        end
        if pool and pool.root then
            pool.visibilityRequested=show==true
            if type(S.UI.EnsureVisible)=="function" then
                local accepted=S.UI:EnsureVisible(pool.root,show==true,P.owner)
                pool.rootVisibilityAccepted=accepted==true
                if accepted==true then pool.rootVisible=show==true else pool.rootVisible=nil end
                if accepted~=true then visibilityReason="visibility_write_rejected" end
            else S.UI:SetVisible(pool.root,show==true,P.owner);pool.rootVisible=nil;pool.rootVisibilityAccepted=nil end
            pool.rootVisibilityReason=visibilityReason
        end
        elseif pool then HideScope(scope) end
    end
end

-- 动态事件不重投影所有图标/装备/布局。只有已提交的布局、
-- 相同设置代际、相同距离字宽和施法可见性才局部更新；结构边沿回到原VisualTick。
local function UpdateDynamicContent()
    if type(Feature.GetDynamicPlatesProjection)~="function" then return false end
    for _,scope in ipairs(POOL_KEYS) do
        local pool=P.pools[scope]
        local layout=pool and pool.dynamicLayout
        if layout then
            if layout.revision~=Feature.settingsRevision then return false end
            local unitScope=UnitScope(scope)
            local distance=P.dynamicDirty.distance and unitScope=="target" and layout.distanceEnabled
            local casting=P.dynamicDirty.cast and layout.castEnabled
            if distance or casting then
                local facts=Feature:GetDynamicPlatesProjection(unitScope)
                -- 仅读条且为空的作用域可在其它作用域更新时保持空闲；新显现条目仍需已提交完整布局。
                if pool.ready~=true and (distance or facts.cast or layout.castVisible) then return false end
                if distance then
                    local item=layout.distance
                    local text=facts.distance and facts.distance.value or nil
                    if (item~=nil)~=(text~=nil) or (item and TextWidth(text,item.font)~=item.width) then return false end
                    if item and pool.info.distanceText~=text then
                        if CommitDynamicText(pool.info.distanceRoot,pool.info,"distanceText",text) then
                            P.motionMetrics.partialDistanceWrites=P.motionMetrics.partialDistanceWrites+1
                        else S.UI:SetVisible(pool.info.distanceRoot,false,P.owner) end
                    end
                    if item then TextColor(pool.info.distanceRoot,scope,'distance',facts.distance.meters)end
                end
                if casting then
                    if layout.castVisible~=(facts.cast~=nil) then return false end
                    if facts.cast then
                        if RenderCastContent(pool.cast,facts.cast) then
                            P.motionMetrics.partialCastUpdates=P.motionMetrics.partialCastUpdates+1
                        end
                    end
                end
            end
        end
    end
    P.motionMetrics.partialUpdates=P.motionMetrics.partialUpdates+1
    return true
end
function P:MotionTick()
    if self.running~=true then return false end
    self.motionMetrics.frames=self.motionMetrics.frames+1
    if self.calibrationSuppressed==true then return true end
    local now=S.NowMs and S.NowMs() or 0
    if self.contentDirty or (self.textureRetryAt and now>=self.textureRetryAt) then return self:VisualTick() end
    if self.dynamicDirty.distance or self.dynamicDirty.cast then
        -- 拒绝写入可能让完整渲染漏掉位置；通过完整布局恢复，即使重试时间之前已有新事实。
        if self.textureRetryAt then return self:VisualTick() end
        if not UpdateDynamicContent() then return self:VisualTick() end
        self.dynamicDirty.distance,self.dynamicDirty.cast=false,false
    end
    MoveRoots()
    return true
end

function P:VisualTick()
    if self.running ~= true then return false end
    self.metrics.ticks = self.metrics.ticks + 1
    self.contentDirty, self.textureRetryAt = false, nil
    self.dynamicDirty.distance,self.dynamicDirty.cast=false,false
    self.motionMetrics.contentBuilds = self.motionMetrics.contentBuilds + 1
    if self.calibrationSuppressed == true then self:HideAll(); return true end
    local policy = Settings()
    if policy.headEnabled == false then self:HideAll(); return true end
    local rendered = false
    for _, scope in ipairs(POOL_KEYS) do
        local settings = LayerSettings(scope)
        if settings and ScopeEnabled(UnitScope(scope), settings) and HasRenderableComponents(settings, UnitScope(scope)) then
            if not self.pools[scope] or not self.pools[scope].root then
                local ok,err=self:EnsurePools(policy)
                if not ok then self:HideAll();return false,err end
            end
            RenderScope(scope, settings); rendered = true
        else HideScope(scope) end
    end
    if rendered ~= true then self:HideAll() else MoveRoots() end
    return true
end

function P:Start()
    if self.running == true then return true end
    if not FeatureEnabled() then return false, "状态显示功能已关闭" end
    local settings = Settings()
    local playerRenderable = settings.headPlayer ~= false and HasRenderableComponents(ScopeSettings("player"), "player")
    local targetRenderable = settings.headTarget ~= false and HasRenderableComponents(ScopeSettings("target"), "target")
    if settings.headEnabled == false or (playerRenderable ~= true and targetRenderable ~= true) then self:HideAll(); return true end
    local ok, err = self:EnsurePools(settings)
    if ok ~= true then return false, err end
    local acquired, acquireErr = Feature:AcquireConsumer(self.consumerToken)
    if acquired ~= true then return false, acquireErr end
    self.consumerHeld = true
    -- Feature发布独立的帧位置事件；Renderer自己不注册OnUpdate/任务。
    -- 内容lane只置脏，在下一次位置提交时合并渲染，而非每个位置回调重建内容。
    if type(S.Events.SubscribeInternal) == "function" then
        S.Events:UnsubscribeInternalOwner(self)
        -- 多个数据lane同一帧发布只置一次dirty；身份失效立即清屏，不能等内容轮询。
        S.Events:SubscribeInternal("v3.buff_display.plates.updated", self, function(_,reason)
            if reason=="distance" then P.dynamicDirty.distance=true
            elseif reason=="cast" then P.dynamicDirty.cast=true
            else P.contentDirty=true end
            if reason=="target_identity_invalidated" then HideScope("target");HideScope("target_fixed") end
        end)
        S.Events:SubscribeInternal("v3.buff_display.plates.motion", self, function() return P:MotionTick() end)
    end
    self.running = true
    self.metrics.starts = self.metrics.starts + 1
    self:VisualTick()
    return true
end

function P:Stop(reason)
    if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
    local releaseOk, releaseErr = true, nil
    if self.consumerHeld then
        releaseOk, releaseErr = Feature:ReleaseConsumer(self.consumerToken)
        if releaseOk == true then self.consumerHeld = false end
    end
    self.running = false
    self.contentDirty, self.textureRetryAt = true, nil
    plateLayoutCache, plateLayoutRevision = {}, nil -- 停用释放旧配置引用；下次启动重新确认几何。
    iconGridCache, iconGridRevision = {}, nil
    self:HideAll()
    self.metrics.stops = self.metrics.stops + 1
    -- 释放失败时保持 consumerHeld=true，供诊断/协调保留泄漏租约证据，并让后续 Stop 重试。
    if releaseOk ~= true then return false, releaseErr or "状态显示 Consumer 释放失败" end
    return true
end

function P:Reconcile(reason)
    local settings = Settings()
    local playerRenderable = settings.headPlayer ~= false and HasRenderableComponents(ScopeSettings("player"), "player")
    local targetRenderable = settings.headTarget ~= false and HasRenderableComponents(ScopeSettings("target"), "target")
    local shouldRun = FeatureEnabled() and settings.headEnabled ~= false and (playerRenderable or targetRenderable)
    if shouldRun then
        if self.running ~= true then return self:Start() end
        local ok, err = self:EnsurePools(settings)
        if ok ~= true then return false, err end
        return self:VisualTick()
    end
    return self:Stop(reason or "reconcile")
end

-- RU 排查接口直接说明头顶渲染器是否运行及血条隐藏原因，无需游戏控制台。
function P:GetDiagnostics()
    local laneData = Feature and Feature.laneData or nil
    local function Lane(scope) return type(laneData) == "table" and laneData[scope] or nil end
    local pool=self.pools.player or {};local lane=Lane("player") or {};local evidence=self.cooldownEvidence
    return {
        version = self.version,
        pvp = { patch=self.PvpPatch, frames=self.motionMetrics.frames, rootWrites=self.motionMetrics.rootWrites,
            contentBuilds=self.motionMetrics.contentBuilds, textureFailures=self.motionMetrics.textureFailures,
            anchorFailures=self.motionMetrics.anchorFailures, lastTextureError=self.motionMetrics.lastTextureError,
            dynamicPatch="dynamic-hud-1",partialUpdates=self.motionMetrics.partialUpdates,
            partialDistanceWrites=self.motionMetrics.partialDistanceWrites,partialCastUpdates=self.motionMetrics.partialCastUpdates },
        buffIconFontSizeContractVersion = tonumber(self.BuffIconFontSizeContractVersion) or 0,
        castYOffsetContractVersion = tonumber(self.CastYOffsetContractVersion) or 0,
        running = self.running == true,
        consumerHeld = self.consumerHeld == true,
        calibrationSuppressed = self.calibrationSuppressed == true,
        cooldowns = {contractVersion=1,inputRows=evidence.inputRows,drawn=evidence.drawn,rejected=evidence.rejected,
            lastRenderAt=evidence.lastRenderAt,
            nonemptyRenders=evidence.nonemptyRenders,lastNonemptyAt=evidence.lastNonemptyAt,
            lastNonemptyInput=evidence.lastNonemptyInput,lastNonemptyDrawn=evidence.lastNonemptyDrawn,
            visibilityAuthority="RSUI accepted submission",rootReady=pool.ready==true,rootVisible=pool.rootVisible,
            rootVisibilityAccepted=pool.rootVisibilityAccepted,
            rootVisibilityRequested=pool.visibilityRequested,rootVisibilityReason=pool.rootVisibilityReason,
            placementCount=pool.placementCount,screenX=pool.screenX,screenY=pool.screenY,width=pool.width,height=pool.height,
            anchorX=lane.x,anchorY=lane.y,depth=lane.depth,projectError=lane.projectErr},
        calibrationSuppressionReason = self.calibrationSuppressionReason,
        calibrationSuppressionCount = tonumber(self.calibrationSuppressionCount) or 0,
        calibrationRestoreCount = tonumber(self.calibrationRestoreCount) or 0,
        liveHudSuppressionContractVersion = tonumber(self.LiveHudSuppressionContractVersion) or 0,
        independentHudSlotContractVersion = tonumber(self.IndependentHudSlotContractVersion) or 0,
        poolsAllocated = tonumber(self.metrics.allocated) or 0,
        starts = tonumber(self.metrics.starts) or 0,
        stops = tonumber(self.metrics.stops) or 0,
        ticks = tonumber(self.metrics.ticks) or 0,
        projections = tonumber(self.metrics.projections) or 0,
        anchorFailures = self.metrics.anchorFailures,
        source = { player = Lane("player") and Lane("player").source or nil,
                   target = Lane("target") and Lane("target").source or nil },
        anchor = { player = Lane("player") and Lane("player").x or nil,
                   target = Lane("target") and Lane("target").x or nil },
        projectError = { player = Lane("player") and Lane("player").projectErr or nil,
                         target = Lane("target") and Lane("target").projectErr or nil },
    }
end

-- 复用模块导出的冷路径，仅取服务/Feature/Renderer缓存。
-- 不创建控件、不取 Consumer、不调用 Native 可见性读回，也不写用户存档。
if S.ModuleDiagnosticsHub and type(S.ModuleDiagnosticsHub.RegisterProvider)=="function" then
    S.ModuleDiagnosticsHub:RegisterProvider("combat_buff_display","cooldown_hud_pipeline",function()
        return {feature=type(Feature.GetCooldownHudDiagnostics)=="function" and Feature:GetCooldownHudDiagnostics() or {available=false},
            renderer=P:GetDiagnostics()}
    end,55,{detailOnly=true})
end

if type(S.Events.SubscribeInternal) == "function" then
    if type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(P.lifecycleOwner) end
    S.Events:SubscribeInternal("v3.feature.lifecycle", P.lifecycleOwner, function(_, featureId)
        if tostring(featureId or "") == "combat_buff_display" then P:Reconcile("feature_lifecycle") end
    end)
    S.Events:SubscribeInternal("v3.buff_display.settings", P.lifecycleOwner, function() P:Reconcile("settings_global") end)
    S.Events:SubscribeInternal("v3.buff_display.target_alias.config", P.lifecycleOwner, function() P:Reconcile("target_alias_config") end)
end

-- 校准与正式 HUD 共用固定槽位几何和组件 fontSize；目标武器、防具来自可见 Buff 类型投影。
P.TargetLoadoutPatch = "enemy-loadout-1"
Feature.BuffHeadMarkerContractVersion = 11
P:Reconcile("load")
