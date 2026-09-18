------------------------------------------------------------------------
-- Replicated Suite V3 - Plate Head Renderer (v4)
--
-- The health-bar plate is the single layout anchor. Everything is positioned
-- relative to its rectangle:
--
--   InfoRow (class · gear · distance)   ← above buffs, auto-raises with rows
--   BuffRow(s)                           ← above the plate, maxRows upward
--   [LeftEquip] [    plate    ] [RightEquip]  ← equipment flanks the plate
--   DebuffRow(s)                         ← below the plate, maxRows downward
--
-- The Feature owns all scheduler lanes; this presenter only keeps bounded
-- widget pools, computes a cached layout per render, and applies diffs.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Feature = S.Features and S.Features.BuffDisplay or nil
if type(Feature) ~= "table" or type(S.UI) ~= "table" or type(S.Events) ~= "table" then return end

S.UIV3 = S.UIV3 or {}
S.UIV3.BuffHeadMarkersV3 = S.UIV3.BuffHeadMarkersV3 or {}
local P = S.UIV3.BuffHeadMarkersV3
P.version = 10
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
P.SplitInfoTextLayoutContractVersion = 1 -- 中文维护注释（.18.225）：职业名称/装分/距离使用独立 pooled label 与独立几何；不改 Store schema，不增加 Native 查询。
P.GearScoreFormatContractVersion = 1 -- .18.226：只格式化现有 Projection 数值，full/compact 不新增事实读取。
-- 维护（pvp-hud-1）：内容dirty与运动分离；指标固定规模，不保存/逐帧打印。
P.PvpPatch = "pvp-hud-1"
P.contentDirty = true
P.motionMetrics = { frames=0, rootWrites=0, contentBuilds=0, textureFailures=0, anchorFailures=0 }


local SCOPES = { "player", "target" }
local RENDERABLE_KEYS = { "buffs", "debuffs", "distance", "class", "gearScore", "mainHand", "offHand", "ranged", "wings", "castBar" }
local UNKNOWN_ICON = "ui/icon/icon_unknown_item.dds"

local function N(v, fallback) return tonumber(v) or tonumber(fallback) or 0 end
local function Settings()
    -- 中文维护注释：VisualTick 是 50ms 级热路径，只需要 HUD 运行策略，不再复制
    -- tracked/classification 等大表；scope 几何由 ScopeSettings 单独取轻量投影。
    local value = type(Feature.GetHeadPolicyProjection) == "function" and Feature:GetHeadPolicyProjection() or nil
    if type(value) ~= "table" and type(Feature.GetSettingsProjection) == "function" then value = Feature:GetSettingsProjection() end
    return type(value) == "table" and value or {}
end
local function ScopeSettings(scope)
    -- 中文维护注释（双 HUD Presentation 读取，2026-09-11）：renderer 不再直接把
    -- player settings.components 套到 target。Feature 是 scope profile 的投影边界；
    -- Presentation 只消费 detached snapshot，避免 Proxy/Presentation 反向改 Authority。
    local value = type(Feature.GetScopeSettingsProjection) == "function" and Feature:GetScopeSettingsProjection(scope) or nil
    if type(value) == "table" then return value end
    return Settings()
end
local function FeatureEnabled()
    return S.FeatureRuntime ~= nil and S.FeatureRuntime:IsEnabled("combat_buff_display") == true
end
local function ScopeEnabled(scope, settings)
    return scope == "player" and settings.headPlayer ~= false or scope == "target" and settings.headTarget ~= false
end
-- Render gate: the head display starts when headEnabled and at least one
-- component is enabled. Buff/debuff whitelist decisions stay in ProjectPlates;
-- presentation never owns or bypasses tracking policy.
local function HasRenderableComponents(settings)
    local components = type(settings.components) == "table" and settings.components or {}
    -- 中文维护注释：plate 是“原生血条代理锚点”，renderer 从不绘制它，不能把
    -- plate.enabled 当作启动理由；否则用户把所有可视组件关掉后仍会持有 Consumer，
    -- 进而让 Aura lane 因 consumerCount>0 继续运行。真正可见能力只由组件开关决定。
    for _, key in ipairs(RENDERABLE_KEYS) do
        local component = components[key]
        if component == nil or component.enabled ~= false then
            -- 中文维护注释（Info 可见性门，2026-09-11）：distance/class/gearScore 没有
            -- 独立绘制区域，info 关闭后它们不能作为 Renderer/Consumer 的启动理由。这样
            -- 与 Feature 的 scope lane gate 保持同一 Authority，避免隐藏 HUD 仍保持 50ms
            -- 数据路径；其他组件继续按自己的 enabled 独立启停。
            if key ~= "distance" and key ~= "class" and key ~= "gearScore" then return true end
            local info = type(settings.info) == "table" and settings.info or {}
            if info.enabled ~= false then
                if key == "class" and info.showClass ~= false then return true end
                if key == "gearScore" and info.showGear ~= false then return true end
                if key == "distance" and info.showDistance ~= false then return true end
            end
        end
    end
    return false
end

------------------------------------------------------------------------
-- Pools
------------------------------------------------------------------------

local function MakeIcon(scope, index)
    local root, err = S.UI:CreateEmptyWidget(P.pools[scope].root, "v3_buff_head_" .. scope .. "_icon_" .. tostring(index), 0, 0, 40, 40, false, P.owner)
    if root == nil then return nil, err end
    root.rsUiOwner = P.owner
    local icon = root.CreateIconDrawable and root:CreateIconDrawable("artwork") or nil
    -- Equipment quality uses a second texture over the base item icon. It is
    -- allocated lazily only when this pooled marker actually renders equipment,
    -- so ordinary Aura-only slots do not pay an extra drawable allocation.
    local stack = S.UI:CreateLabel(root, "v3_buff_head_" .. scope .. "_stack_" .. tostring(index), "", 0, 0, 18, 14, 9, "strong", "RIGHT", true)
    local time = S.UI:CreateLabel(root, "v3_buff_head_" .. scope .. "_time_" .. tostring(index), "", 0, 0, 40, 12, 8, "default", "RIGHT", true)
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
    if bg == nil or fill == nil or text == nil then
        S.UI:SetVisible(root, false, P.owner)
        return nil, "buff_head_castbar_child_create_failed"
    end
    S.UI:SetVisible(root, false, P.owner)
    return { root=root, bg=bg, fill=fill, text=text, barW=120, layout={} }
end

local function MakeInfo(scope)
    local parent = P.pools[scope].root
    local classLabel, err = S.UI:CreateLabel(parent, "v3_buff_head_" .. scope .. "_info_class", "", 0, 0, 120, 16, 10, "default", "CENTER", true)
    if classLabel == nil then return nil, err end
    local gearLabel, gearErr = S.UI:CreateLabel(parent, "v3_buff_head_" .. scope .. "_info_gear", "", 0, 0, 90, 16, 10, "default", "CENTER", true)
    if gearLabel == nil then S.UI:SetVisible(classLabel, false, P.owner); return nil, gearErr end
    local distanceLabel, distanceErr = S.UI:CreateLabel(parent, "v3_buff_head_" .. scope .. "_info_distance", "", 0, 0, 90, 16, 10, "default", "CENTER", true)
    if distanceLabel == nil then
        S.UI:SetVisible(classLabel, false, P.owner); S.UI:SetVisible(gearLabel, false, P.owner)
        return nil, distanceErr
    end
    S.UI:SetVisible(classLabel, false, P.owner); S.UI:SetVisible(gearLabel, false, P.owner); S.UI:SetVisible(distanceLabel, false, P.owner)
    -- 中文维护注释（HUD 基础信息拆分，2026-09-17）：旧实现只有一个拼接 label，导致职业名称、
    -- 装分和距离只能整体移动/改字号。这里仍保持每 scope 固定 3 个 pooled label，不在 50ms
    -- VisualTick 中创建对象。root 继续别名到 classTextRoot，保护旧测试/诊断引用；gear/distance
    -- 仅消费 Feature 已有投影，不产生新的 Native 查询、Consumer 或 Scheduler。
    local iconRoot = S.UI:CreateEmptyWidget(parent, "v3_buff_head_" .. scope .. "_class_icon", 0, 0, 16, 16, false, P.owner)
    local icon = iconRoot and iconRoot.CreateIconDrawable and iconRoot:CreateIconDrawable("artwork") or nil
    if iconRoot then S.UI:SetVisible(iconRoot, false, P.owner) end
    return {
        root=classLabel, classTextRoot=classLabel, gearRoot=gearLabel, distanceRoot=distanceLabel,
        classText="", gearText="", distanceText="", iconRoot=iconRoot, icon=icon,
    }
end

local function RequiredIconCount(settings)
    settings = type(settings) == "table" and settings or Settings()
    local components = type(settings.components) == "table" and settings.components or {}
    local buff = components.buffs or {}
    local debuff = components.debuffs or {}
    local buffMax = math.max(1, math.min(64, math.floor(N(buff.maxPerRow, 8) * N(buff.maxRows, 2))))
    local debuffMax = math.max(1, math.min(64, math.floor(N(debuff.maxPerRow, 8) * N(debuff.maxRows, 2))))
    return buffMax + debuffMax + 8
end

function P:EnsurePools(settings)
    -- 中文维护注释：player/target 的 maxPerRow/maxRows 现在可独立；池容量必须取两者
    -- 最大值，否则目标配置放大后会出现“设置已保存但最后几枚图标没有 pooled marker”。
    local iconCount = 0
    for _, scope in ipairs(SCOPES) do
        iconCount = math.max(iconCount, RequiredIconCount(ScopeSettings(scope)))
    end
    if iconCount <= 0 then iconCount = RequiredIconCount(type(settings) == "table" and settings or Settings()) end
    for _, scope in ipairs(SCOPES) do
        local pool = self.pools[scope]
        -- 维护：新建时就固定父链，绝不reparent已有Native控件。所有子项落在union正坐标内，
        -- 避免小父容器裁剪；移动只写这个无命中父容器，职业/装备/Buff不会逐个追赶血条。
        if pool.root == nil then
            pool.root = S.UI:CreateEmptyWidget(UIParent, "v3_buff_head_" .. scope .. "_plate_root", 0, 0, 1, 1, false, self.owner)
            if pool.root == nil then return false, "buff_head_plate_root_create_failed" end
            pool.placements, pool.placementCount = {}, 0
            S.UI:SetVisible(pool.root, false, self.owner)
            self.metrics.allocated = self.metrics.allocated + 1
        end
        for index = #pool.icons + 1, iconCount do
            local marker, err = MakeIcon(scope, index)
            if marker == nil then return false, err end
            pool.icons[index] = marker
            self.metrics.allocated = self.metrics.allocated + 1
        end
        if pool.cast == nil then
            local cast, err = MakeCastBar(scope)
            if cast == nil then return false, err end
            pool.cast = cast
            self.metrics.allocated = self.metrics.allocated + 1
        end
        if pool.info == nil then
            local info, err = MakeInfo(scope)
            if info == nil then return false, err end
            pool.info = info
            self.metrics.allocated = self.metrics.allocated + 1
        end
    end
    return true
end

local function HideIcon(marker)
    if marker and marker.root then S.UI:SetVisible(marker.root, false, P.owner) end
end
local function HideScope(scope)
    local pool = P.pools[scope]
    if pool == nil then return end
    if pool.root then S.UI:SetVisible(pool.root, false, P.owner) end
    pool.ready = false
    for _, marker in ipairs(pool.icons) do HideIcon(marker) end
    if pool.labels then for _, label in ipairs(pool.labels) do if label.root then S.UI:SetVisible(label.root, false, P.owner) end end end
    if pool.cast then S.UI:SetVisible(pool.cast.root, false, P.owner) end
    if pool.info then
        if pool.info.classTextRoot then S.UI:SetVisible(pool.info.classTextRoot, false, P.owner) end
        if pool.info.gearRoot then S.UI:SetVisible(pool.info.gearRoot, false, P.owner) end
        if pool.info.distanceRoot then S.UI:SetVisible(pool.info.distanceRoot, false, P.owner) end
        if pool.info.iconRoot then S.UI:SetVisible(pool.info.iconRoot, false, P.owner) end
    end
end
function P:HideAll()
    for _, scope in ipairs(SCOPES) do HideScope(scope) end
    return true
end

------------------------------------------------------------------------
-- Layout helpers
------------------------------------------------------------------------

-- 维护：内容布局以单位原点(0,0)计算，先记录所有子项边界再统一平移到父容器的正坐标。
-- 只在内容/设置变更时执行，不在每渲染帧构建表；每个placement对象在池里复用。
local function Place(pool, widget, x, y, w, h)
    local n = (pool.placementCount or 0) + 1
    local row = pool.placements[n] or {}
    pool.placements[n], pool.placementCount = row, n
    row.widget, row.x, row.y, row.w, row.h = widget, x, y, w, h
    pool.minX = math.min(pool.minX or x, x); pool.minY = math.min(pool.minY or y, y)
    pool.maxX = math.max(pool.maxX or x+w, x+w); pool.maxY = math.max(pool.maxY or y+h, y+h)
end
local function CommitPlacements(pool)
    local left, top = math.floor(pool.minX or 0), math.floor(pool.minY or 0)
    pool.offsetX, pool.offsetY = left, top
    pool.width = math.max(1, math.ceil(pool.maxX or 1)-left)
    pool.height = math.max(1, math.ceil(pool.maxY or 1)-top)
    -- 维护：父容器与子锚点必须整体被接受。部分拒写时隐藏该组并重试，不能提交半新半旧的布局。
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
-- 维护：SetIconTexture的false也可能是diff无变化，所以通过Ensure契约区分成功与拒写。
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

-- 中文维护注释（Buff/Debuff 字体 Authority，2026-09-11）：旧 Renderer 虽然 Store/校准器都
-- 保存 component.fontSize，但正式渲染始终用 icon size × 固定比例重算字体，造成“校准预览能改、
-- 保存成功、实机字体却不动”。字体 Authority 应来自当前 scope 的组件配置；plateScale 只负责把
-- 逻辑字体映射到最终视觉尺寸。fontSize<=0 时保留旧比例回退，兼容装备池等没有字体配置的调用。
-- 该函数是纯数值计算，不读取 Store/Native，不增加 50ms VisualTick 的对象分配。
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
    -- Remaining-time label is embedded at the icon's bottom-right (no extra row
    -- height) so it is always visible without pushing rows apart; the stack
    -- counter stays at the top-right.
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

local function ApplyIcon(marker, row, size, cfg, x, y, showStacks, showTime, scale)
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
    -- Group-level clamping already kept the whole row/group inside the screen;
    -- each icon is placed at its exact computed slot so members never pile up.
    Place(P.pools[marker.scope], marker.root, x, y, size, size)
    S.UI:SetVisible(marker.root, true, P.owner)
end

-- Render a horizontal icon row for a component; returns how many slots used.
-- The WHOLE row is clamped as one group; individual icons keep exact spacing.
local function RenderIconRow(scope, pool, rows, cfg, centerX, rowY, showStacks, showTime, slotOffset, size, gap, scale)
    local used = 0
    size = math.max(8, math.floor(tonumber(size) or N(cfg.size, 24)))
    gap = math.max(0, math.floor(tonumber(gap) or N(cfg.spacing, 2)))
    local count = math.min(#rows, 16)
    local totalW = count * size + math.max(0, count - 1) * gap
    local startX = math.floor(centerX + N(cfg.x, 0) - totalW / 2)
    -- 维护：整个血条附着组在移动父容器时统一裁剪，不能单独拉回每一排图标。
    local startY = math.floor(tonumber(rowY) or 0)
    for index = 1, count do
        local marker = pool.icons[slotOffset + index]
        if marker == nil then break end
        ApplyIcon(marker, rows[index], size, cfg, startX + (index - 1) * (size + gap), startY, showStacks, showTime, scale)
        used = used + 1
    end
    return used
end

-- Multi-row buff/debuff rendering: rows stack upward (buff) or downward
-- (debuff) from the plate edge, bounded by MaxPerRow and MaxRows.
local function RenderRows(scope, pool, rows, cfg, centerX, firstRowTop, showStacks, showTime, slotOffset, size, spacing, maxPerRow, maxRows, rowGap, direction, scale)
    local used = 0
    local all = type(rows) == "table" and rows or {}
    local total = math.min(#all, maxPerRow * maxRows)
    if total <= 0 then return 0 end
    for r = 0, maxRows - 1 do
        local start = r * maxPerRow + 1
        local count = math.min(maxPerRow, total - r * maxPerRow)
        if count <= 0 then break end
        local rowTop = firstRowTop + direction * (r * rowGap)
        local slice = {}
        for i = 1, count do slice[i] = all[start + i - 1] end
        used = used + RenderIconRow(scope, pool, slice, cfg, centerX, rowTop, showStacks, showTime, slotOffset + used, size, spacing, scale)
    end
    return used
end

------------------------------------------------------------------------
-- Layout geometry (pure)
------------------------------------------------------------------------

-- Default visual spacing (verified defaults; derived from the legacy
-- Professional Plates section-flow experience, widened for clear layering).
-- Buff/Debuff/Info/equipment are all computed from the bar rect only.
-- Gap constants scaled 1.2× to match the new default icon sizes.
local BUFF_TO_BAR = 8        -- first buff row bottom -> bar.top
local BUFF_ROW_GAP = 4       -- between buff rows
local DEBUFF_TO_BAR = 8      -- first debuff row top -> bar.bottom
local DEBUFF_ROW_GAP = 4     -- between debuff rows
local INFO_TO_BUFF = 7       -- info bottom -> top-most actual buff row top
local INFO_TO_BAR = 9        -- info bottom -> bar.top when no buffs
local EQUIP_TO_BAR = 7       -- equipment inner edge -> bar side
local EQUIP_GAP = 4          -- between two equipment icons

-- Pure layout computation. No widgets, no native reads, no store mutation.
-- Inputs are the projected anchor (unit screen position), settings, and the
-- actual visible row/equipment counts. Returns a geometry table the renderer
-- applies verbatim. This is the single authority for "where does X go".
--
--   anchorX, anchorY : unit screen projection point (ScreenProjectionV3 space)
--   settings         : BuffDisplay settings projection (plate/info/components)
--   buffCount        : visible buff rows count (already bounded)
--   debuffCount      : visible debuff rows count
--   equip            : { mainHand=bool, offHand=bool, ranged=bool, wings=bool }
local function ComputePlateLayout(anchorX, anchorY, settings, buffCount, debuffCount, equip)
    settings = type(settings) == "table" and settings or {}
    local plateCfg = type(settings.plate) == "table" and settings.plate or {}
    local infoCfg = type(settings.info) == "table" and settings.info or {}
    local components = type(settings.components) == "table" and settings.components or {}
    local scale = math.max(0.5, math.min(2, tonumber(settings.plateScale) or 1))

    -- NativeBarProxy rectangle: the single geometric anchor. Only plate.x/y
    -- offset the bar; nothing else enters this chain.
    local barW = math.max(24, math.floor(N(plateCfg.width, 180) * scale))
    local barH = math.max(8, math.floor(N(plateCfg.height, 24) * scale))
    local centerX = math.floor((tonumber(anchorX) or 0) + N(plateCfg.x, 0) * scale)
    local centerY = math.floor((tonumber(anchorY) or 0) + N(plateCfg.y, 0) * scale)
    local left = centerX - math.floor(barW / 2)
    local right = left + barW
    local top = centerY - math.floor(barH / 2)
    local bottom = centerY + math.floor(barH / 2)
    local bar = { centerX = centerX, centerY = centerY, left = left, right = right, top = top, bottom = bottom, width = barW, height = barH }

    -- Buff rows: row1.bottom = bar.top - BuffToBarGap; extra rows stack upward
    -- at BuffRowGap. Component y is a local micro offset only.
    local buffCfg = components.buffs or {}
    local buffSize = math.max(8, math.floor(N(buffCfg.size, 29) * scale))
    local buffSpacing = math.max(0, math.floor(N(buffCfg.spacing, 2) * scale))
    local buffMaxPerRow = math.max(1, math.min(16, math.floor(N(buffCfg.maxPerRow, 8))))
    local buffMaxRows = math.max(1, math.min(4, math.floor(N(buffCfg.maxRows, 2))))
    local buffGap = BUFF_TO_BAR * scale + math.floor(N(buffCfg.y, 0) * scale)
    local buffRowGap = BUFF_ROW_GAP * scale
    local buffFirstTop = bar.top - buffGap - buffSize          -- row1.top
    local buffActualRows = math.min(buffMaxRows, math.ceil(buffCount / buffMaxPerRow))
    local buffTopMostTop = buffFirstTop - (buffActualRows - 1) * buffRowGap

    -- Debuff rows: row1.top = bar.bottom + DebuffToBarGap; extra rows stack
    -- downward at DebuffRowGap.
    local debuffCfg = components.debuffs or {}
    local debuffSize = math.max(8, math.floor(N(debuffCfg.size, 29) * scale))
    local debuffSpacing = math.max(0, math.floor(N(debuffCfg.spacing, 2) * scale))
    local debuffMaxPerRow = math.max(1, math.min(16, math.floor(N(debuffCfg.maxPerRow, 8))))
    local debuffMaxRows = math.max(1, math.min(4, math.floor(N(debuffCfg.maxRows, 2))))
    local debuffGap = DEBUFF_TO_BAR * scale + math.floor(N(debuffCfg.y, 0) * scale)
    local debuffRowGap = DEBUFF_ROW_GAP * scale
    local debuffFirstTop = bar.bottom + debuffGap

    -- Info row: above the top-most ACTUAL buff row; above the bar when no buffs.
    local infoFont = math.max(8, math.floor(N(infoCfg.fontSize, 12) * scale))
    local infoH = infoFont + 4
    local infoGap = (buffActualRows > 0 and INFO_TO_BUFF or INFO_TO_BAR) * scale
    local infoTop = (buffActualRows > 0 and buffTopMostTop or bar.top) - infoGap - infoH
    infoTop = infoTop + math.floor(N(infoCfg.y, 0) * scale)

    -- Equipment flanks. Historical v3 keeps offHand closest -> mainHand -> ranged outermost.
    -- Release v4 visually reads left-to-right as mainHand -> offHand -> ranged -> plate, so ranged is
    -- immediately to the RIGHT of offHand as requested by ranged-class players. Right: wings/back only.
    -- Component x/y are
    -- local micro offsets. Slots are returned UNCLAMPED with their absolute
    -- origin; the renderer clamps each group as a whole (never per-icon).
    local function EquipSlots(edgeStart, direction, keys)
        local slots = {}
        local edge = edgeStart
        for _, key in ipairs(keys) do
            local cfg = components[key] or {}
            local enabled = equip[key] == true
            if enabled then
                local size = math.max(8, math.floor(N(cfg.size, 26) * scale))
                local gap = math.max(1, math.floor(N(cfg.gap or cfg.spacing, EQUIP_GAP) * scale))
                -- 中文维护注释（装备局部位置 Authority，2026-09-11）：旧实现先把当前槽位
                -- cfg.x 加到最终 x，再用这个“已微调 x”推进 edge，导致 offHand.x 会拖着
                -- mainHand/ranged 一起移动，mainHand.x 又会继续拖着 ranged。默认槽位顺序本身
                -- 没问题，错误在于把“用户局部微调”污染成了下一个槽位的布局 Authority。
                -- 现在先计算不含用户 offset 的 baseX；当前组件最终 x=baseX+cfg.x，但 edge
                -- 只从 baseX/size 推进。这样默认仍按 offHand→mainHand→ranged 排列，单独移动
                -- 任一装备只影响自己。兼容边界：size/gap 仍属于基础槽位几何，改变尺寸时外侧
                -- 槽位会自然重新排布以避免默认重叠；schema5/x/y 数值语义完全不变。
                local baseX
                if direction < 0 then baseX = edge - gap - size else baseX = edge + gap end
                local x = baseX + math.floor(N(cfg.x, 0) * scale)
                local y = bar.centerY - math.floor(size / 2) + math.floor(N(cfg.y, 0) * scale)
                slots[#slots + 1] = { key = key, x = x, y = y, size = size, baseX = baseX }
                edge = direction < 0 and baseX or (baseX + size)
            end
        end
        return slots
    end
    -- 中文维护注释（装备排列版本化）：EquipSlots(direction=-1) 的 keys 是“从血条向外”顺序，
    -- 所以 v4 传 ranged→offHand→mainHand 后，屏幕从左到右正好是 mainHand→offHand→ranged。
    -- v3 继续使用历史顺序，保护曾主动调过 ranged 的旧用户；只有 fresh/reset 或“旧默认未动”
    -- 的兼容升级会进入 v4。单项 cfg.x 仍只影响自己，不恢复旧联动。
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
        equip = { mainHand = equip.mainHand == true, offHand = equip.offHand == true, ranged = equip.ranged == true, wings = equip.wings == true },
        leftGroup = { slots = leftSlots, rect = GroupRect(leftSlots) },
        rightGroup = { slots = rightSlots, rect = GroupRect(rightSlots) },
        scale = scale,
    }
end

-- Expose the pure layout function for acceptance geometry tests and any other
-- consumer that needs the plate geometry without touching widgets.
P.ComputePlateLayout = ComputePlateLayout
P.CastYOffsetContractVersion = 1

------------------------------------------------------------------------
-- Render
------------------------------------------------------------------------

local function RenderCastBar(scope, cast, cfg, centerX, y, scale)
    local pool = P.pools[scope]
    if pool == nil or pool.cast == nil or cast == nil then return end
    local bar = pool.cast
    scale = tonumber(scale) or 1
    local barW = math.max(24, math.floor(N(cfg.width, 120) * scale))
    local barH = math.max(4, math.floor(N(cfg.size, 6) * scale))
    local showText = cfg.showText ~= false
    local alpha = math.max(0.1, math.min(1, N(cfg.alpha, 1)))
    local ratio = math.max(0, math.min(1, cast.totalMs > 0 and (cast.currMs / cast.totalMs) or 0))
    local x = math.floor(centerX + N(cfg.x, 0) * scale - barW / 2)
    -- 中文维护注释（施法条 Y Authority，2026-09-11）：旧 renderer 读取 castBar.x 却
    -- 完全忽略 castBar.y，导致 HUD 校准器的上下拖动/方向键“保存成功但画面不动”。
    -- castBar.y 与其余 equipment 微调一致，以 plateScale 后的局部像素解释；这里只在
    -- Presentation 几何阶段应用，不改变 CastingObservation 数据或高频采集路径。
    y = N(y, 0) + N(cfg.y, 0) * scale
    local cache = bar.layout
    if cache.alpha ~= alpha then S.UI:SetAlpha(bar.root, alpha, P.owner); cache.alpha = alpha end
    if cache.barW ~= barW then cache.barW = barW end
    -- 维护：施法条/文字也归属同一个单位容器；总高度包含文字，避免父裁剪。
    local totalH = barH + (showText and 15 or 0)
    Place(pool, bar.root, x, math.floor(y), barW, totalH)
    S.UI:SetExtent(bar.root, barW, totalH, P.owner)
    S.UI:SetAnchor(bar.bg, bar.root, 0, 0, P.owner)
    S.UI:SetExtent(bar.bg, barW, barH, P.owner)
    S.UI:SetAnchor(bar.fill, bar.root, 0, 0, P.owner)
    S.UI:SetExtent(bar.fill, math.max(1, math.floor(barW * ratio)), barH, P.owner)
    bar.text:SetText(showText and (cast.spellName or "") or "")
    S.UI:SetFontSize(bar.text, math.max(8, math.floor(N(cfg.fontSize, 10) * scale)), P.owner)
    S.UI:SetAnchor(bar.text, bar.root, 0, barH + 1, P.owner)
    S.UI:SetExtent(bar.text, barW, 14, P.owner)
    S.UI:SetVisible(bar.text, showText, P.owner)
    S.UI:SetVisible(bar.root, true, P.owner)
end

-- Record why a scope's plates were hidden so RU-side triage has a visible
-- trail (projection service down, unit off-screen, depth filtered, ...).
local function RecordAnchorFailure(scope, reason)
    local entry = P.metrics.anchorFailures[scope]
    if type(entry) ~= "table" then entry = { count = 0, lastAt = 0, lastErr = nil }; P.metrics.anchorFailures[scope] = entry end
    entry.count = (tonumber(entry.count) or 0) + 1
    entry.lastAt = S.NowMs and S.NowMs() or 0
    entry.lastErr = tostring(reason or "anchor_unavailable")
end

-- 维护：装备沿用局部布局。只由外层整组容器执行屏幕边缘约束，不能让装备/
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
        ApplyIcon(marker, { iconPath = item.icon, gradeIconPath = item.gradeIconPath, stack = nil, timeText = nil }, s.size, cfg, s.x, s.y, false, false, scale)
        used = used + 1
    end
    return used
end

-- 中文维护注释（HUD 信息拆分几何 Authority，2026-09-17）：
-- Store schema6 已经持久化 info、components.gearScore、components.distance 三套几何字段；
-- schema7 只在 info 增加 gearScoreFormat，不改变这些几何 Authority。旧 Renderer 把文本先拼成一个
-- label，后两套字段事实上从未参与正式 HUD。职业名称继续使用 info.x/y/fontSize；装备分数使用
-- gearScore.x/y/fontSize/alpha；距离使用 distance.x/y/fontSize/alpha；职业图标仍只使用
-- class.x/y/size/alpha。历史 schema6 canonical 由 Store 冻结验真；schema7 只新增文字格式，
-- 不会把“图标微调”重新耦合到职业名字。ComputePlateLayout 历史上把 info.y 预先加进
-- info.top，因此本函数先还原 baseY，再分别应用三项 Y，确保移动职业名称不拖着装分/距离。
-- 零偏移时三段仍按旧职业→装分→距离顺序整体居中，升级后默认视觉不会无故散开。

-- 中文维护注释（装备分数显示格式，2026-09-17）：
-- Renderer 只格式化 Projection 已提供的 gearScore，不读取 Native、不缓存第二份数值 Authority。
-- compact 只在 >=1000 时使用 K，一位小数四舍五入并去掉 .0；full 保持整数文本。
-- 非数字输入 fail-soft 原样显示，避免未来诊断占位被错误吞掉。
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

function P.ComputeInfoItemsLayout(plates, infoCfg, components, centerX, y, fontSize, scale)
    plates, infoCfg, components = type(plates)=="table" and plates or {}, infoCfg or {}, components or {}
    scale = tonumber(scale) or 1
    local class = type(plates.class)=="table" and plates.class or {}
    local classCfg = components.class or {}
    local gearCfg = components.gearScore or {}
    local distanceCfg = components.distance or {}
    -- 中文维护注释（职业名称/图标独立 Authority）：showClass 只控制职业名称；class.enabled 只控制
    -- 职业图标。旧合并 label 曾把二者绑定，拆分后若继续复用同一门会导致“关图标=名字也没了”。
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
        -- 用户要求装备分数前不再显示“·”。gearScore 使用纯文字，并通过几何 gap 与前项分开；
        -- distance 保留旧分隔符语义。这样 gear label 的真实文本就是 15200/15.2K，不带隐藏前缀。
        item.gapBefore = (index > 1 and item.key == "gearScore") and math.max(3, math.floor(item.font * 0.25)) or 0
        item.text = (index > 1 and item.key ~= "gearScore" and "· " or "") .. item.raw
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
function P.ComputeInfoLayout(plates, infoCfg, components, centerX, y, fontSize, scale)
    local g=P.ComputeInfoItemsLayout(plates,infoCfg,components,centerX,y,fontSize,scale)
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

local function RenderTextItem(pool, widget, cache, cacheField, item)
    if widget == nil then return end
    if item == nil or item.text == "" then S.UI:SetVisible(widget,false,P.owner); cache[cacheField]=""; return end
    local rendered = item.displayText or item.text
    if cache[cacheField] ~= rendered then widget:SetText(rendered);cache[cacheField]=rendered end
    S.UI:SetFontSize(widget,item.font,P.owner)
    S.UI:SetAlpha(widget,item.alpha or 1,P.owner)
    S.UI:SetExtent(widget,item.width,item.height,P.owner)
    Place(pool,widget,item.x,item.y,item.width,item.height)
    S.UI:SetVisible(widget,true,P.owner)
end

local function RenderInfo(scope, plates, infoCfg, components, centerX, y, fontSize, scale)
    local pool = P.pools[scope]
    if pool == nil or pool.info == nil then return end
    local info = pool.info
    local g = P.ComputeInfoItemsLayout(plates,infoCfg,components,centerX,y,fontSize,scale)
    RenderTextItem(pool,info.classTextRoot,info,"classText",g.classText)
    RenderTextItem(pool,info.gearRoot,info,"gearText",g.gearScore)
    RenderTextItem(pool,info.distanceRoot,info,"distanceText",g.distance)
    if info.iconRoot then
        local showIcon = g.icon ~= nil and info.icon ~= nil and g.classText ~= nil
        if showIcon then
            showIcon = Texture(info,"iconPath",info.icon,g.icon)
            S.UI:SetExtent(info.iconRoot,g.iconSize,g.iconSize,P.owner)
            S.UI:SetExtent(info.icon,g.iconSize,g.iconSize,P.owner)
            S.UI:SetAnchor(info.icon,info.iconRoot,0,0,P.owner)
            S.UI:SetAlpha(info.iconRoot,g.iconAlpha,P.owner)
            Place(pool,info.iconRoot,g.iconX,g.iconY,g.iconSize,g.iconSize)
        end
        S.UI:SetVisible(info.iconRoot,showIcon,P.owner)
    end
end

local function RenderScope(scope, settings)
    local pool = P.pools[scope]
    if pool == nil then return end
    if ScopeEnabled(scope, settings) ~= true then HideScope(scope); return end
    local plates = Feature:GetPlatesProjection(scope)
    -- 维护：所有内容在单位原点生成；屏幕移动留给MotionTick，绝不在这里重读投影Native。
    local anchorX, anchorY = 0, 0
    pool.placementCount, pool.minX, pool.minY, pool.maxX, pool.maxY = 0, nil, nil, nil, nil
    P.metrics.projections = P.metrics.projections + 1
    local components = type(settings.components) == "table" and settings.components or {}
    local infoCfg = type(settings.info) == "table" and settings.info or {}
    local showStacks = settings.headShowStacks ~= false
    local showTime = settings.headShowTime ~= false

    -- Equipment visibility: collapse slots that have no item. Ranged remains an independent component;
    -- fresh/player defaults are ON from layout preset v4, while customized historical profiles keep their stored choice.
    local equip = {}
    for _, key in ipairs({ "mainHand", "offHand", "ranged", "wings" }) do
        local cfg = components[key] or {}
        local item = plates[key]
        -- 中文维护：观察到类型但元数据缺图时不借“未知物品”伪装具体装备；待共享元数据补齐再绘制。
        equip[key] = cfg.enabled ~= false and item ~= nil and item.icon ~= nil
            and (item.source ~= "observed_buff" or item.icon ~= "")
    end

    local buffRows = plates.buffs or {}
    local debuffRows = plates.debuffs or {}
    local buffEnabled = (components.buffs or {}).enabled ~= false
    local debuffEnabled = (components.debuffs or {}).enabled ~= false
    local buffCount = buffEnabled and #buffRows or 0
    local debuffCount = debuffEnabled and #debuffRows or 0

    -- Single pure layout authority.
    local L = ComputePlateLayout(anchorX, anchorY, settings, buffCount, debuffCount, equip)
    local bar = L.bar
    local scale = L.scale

    local slot = 0
    -- Buff rows (stack upward from bar.top).
    if buffEnabled then
        slot = slot + RenderRows(scope, pool, buffRows, components.buffs or {}, bar.centerX, L.buff.firstTop, showStacks, showTime, slot, L.buff.size, L.buff.spacing, L.buff.maxPerRow, L.buff.maxRows, L.buff.rowGap, -1, scale)
    end
    -- Debuff rows (stack downward from bar.bottom).
    if debuffEnabled then
        slot = slot + RenderRows(scope, pool, debuffRows, components.debuffs or {}, bar.centerX, L.debuff.firstTop, showStacks, showTime, slot, L.debuff.size, L.debuff.spacing, L.debuff.maxPerRow, L.debuff.maxRows, L.debuff.rowGap, 1, scale)
    end
    -- Equipment flanks: pre-computed groups applied as whole units (group clamp).
    slot = slot + ApplyEquipGroup(scope, pool, plates, components, L.leftGroup, slot, scale)
    slot = slot + ApplyEquipGroup(scope, pool, plates, components, L.rightGroup, slot, scale)
    for index = slot + 1, #pool.icons do HideIcon(pool.icons[index]) end

    -- Info row (class name · gear score · distance), auto-placed above actual rows.
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

    -- Cast bar below the debuff rows (hidden when not casting).
    local castCfg = components.castBar or {}
    if castCfg.enabled ~= false and plates.cast ~= nil then
        local castY = bar.bottom + (debuffEnabled and (L.debuff.actualRows * L.debuff.rowGap) or 0) + 6 * scale
        RenderCastBar(scope, plates.cast, castCfg, bar.centerX, castY, scale)
    else
        local cast = pool.cast
        if cast then S.UI:SetVisible(cast.root, false, P.owner) end
    end
    CommitPlacements(pool)
end

-- 中文维护注释（HUD 校准 Presentation suppression，2026-09-11）：
-- 问题原因：独立校准器过去只是在 UIParent 上叠加模拟 Preview，正式 BuffHeadMarkers 仍持续绘制
-- 自己/目标 Buff 与装备，导致用户调整主手/副手时同时看到旧图标，无法判断哪个才是 Draft。
-- Authority：Feature/Store/Aura/位置 Lane 继续运行，本开关只属于 Renderer Presentation；禁止用
-- Feature disable/ReleaseConsumer 来“隐藏”，否则校准器会失去真实单位锚点并改变高频数据生命周期。
-- 数据流：Calibration Open -> SetCalibrationSuppressed(true) -> VisualTick 只 HideAll；Exit -> false ->
-- 立即 VisualTick 恢复正式 HUD。兼容边界：不持久化、不进入 schema5、不改变 Consumer 数；模块热重载
-- 后默认 false。后续任何校准 Overlay 都应复用此 Presentation gate，而不是直接改 Store 开关。
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

-- 维护：raw投影与raw视口只转换一次。组内子项全部不动，边缘裁剪平移整个union，
-- 禁止逐图标clamp/插值（会引入空间误导）；原生点不可用或在屏幕后时立即隐藏整组。
local function MoveRoots()
    local w,h
    if type(Feature.GetHeadViewport)=="function" then w,h=Feature:GetHeadViewport() end
    for _,scope in ipairs(SCOPES) do
        local pool=P.pools[scope]
        local x,y,depth,source,err=Feature:GetPlatesAnchor(scope)
        local valid=x~=nil and y~=nil and N(depth,1)>0
        if pool and not valid then
            local reason=tostring(err or "native_anchor_unavailable")
            if pool.lastAnchorFailure~=reason then RecordAnchorFailure(scope,reason) end
            pool.lastAnchorFailure=reason
        elseif pool then pool.lastAnchorFailure=nil end
        local show=pool and pool.ready==true and valid
        if show then
            x,y=x+pool.offsetX,y+pool.offsetY
            if w and h and w>0 and h>0 then
                x=math.max(0,math.min(math.max(0,w-pool.width),x))
                y=math.max(0,math.min(math.max(0,h-pool.height),y))
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
                end
            end
        end
        if pool and pool.root then S.UI:SetVisible(pool.root,show==true,P.owner) end
    end
end
function P:MotionTick()
    if self.running~=true then return false end
    self.motionMetrics.frames=self.motionMetrics.frames+1
    if self.calibrationSuppressed==true then return true end
    local now=S.NowMs and S.NowMs() or 0
    if self.contentDirty or (self.textureRetryAt and now>=self.textureRetryAt) then return self:VisualTick() end
    MoveRoots()
    return true
end

function P:VisualTick()
    if self.running ~= true then return false end
    self.metrics.ticks = self.metrics.ticks + 1
    self.contentDirty, self.textureRetryAt = false, nil
    self.motionMetrics.contentBuilds = self.motionMetrics.contentBuilds + 1
    if self.calibrationSuppressed == true then self:HideAll(); return true end
    local policy = Settings()
    if policy.headEnabled == false then self:HideAll(); return true end
    local rendered = false
    for _, scope in ipairs(SCOPES) do
        local settings = ScopeSettings(scope)
        if ScopeEnabled(scope, settings) and HasRenderableComponents(settings) then
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
    local playerRenderable = settings.headPlayer ~= false and HasRenderableComponents(ScopeSettings("player"))
    local targetRenderable = settings.headTarget ~= false and HasRenderableComponents(ScopeSettings("target"))
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
        -- 维护：多个数据lane同一帧发布只置一次dirty；身份失效立即清屏，不能等内容轮询。
        S.Events:SubscribeInternal("v3.buff_display.plates.updated", self, function(_,reason)
            P.contentDirty=true
            if reason=="target_identity_invalidated" then HideScope("target") end
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
    self:HideAll()
    self.metrics.stops = self.metrics.stops + 1
    -- Keep consumerHeld true on a failed release so diagnostics/reconcile retain
    -- evidence of the leaked lease and a later Stop can retry the release.
    if releaseOk ~= true then return false, releaseErr or "状态显示 Consumer 释放失败" end
    return true
end

function P:Reconcile(reason)
    local settings = Settings()
    local playerRenderable = settings.headPlayer ~= false and HasRenderableComponents(ScopeSettings("player"))
    local targetRenderable = settings.headTarget ~= false and HasRenderableComponents(ScopeSettings("target"))
    local shouldRun = FeatureEnabled() and settings.headEnabled ~= false and (playerRenderable or targetRenderable)
    if shouldRun then
        if self.running ~= true then return self:Start() end
        local ok, err = self:EnsurePools(settings)
        if ok ~= true then return false, err end
        return self:VisualTick()
    end
    return self:Stop(reason or "reconcile")
end

-- RU-side triage surface: answers "is the head renderer running, and if the
-- plates are hidden, why?" without needing in-game console digging.
function P:GetDiagnostics()
    local laneData = Feature and Feature.laneData or nil
    local function Lane(scope) return type(laneData) == "table" and laneData[scope] or nil end
    return {
        version = self.version,
        pvp = { patch=self.PvpPatch, frames=self.motionMetrics.frames, rootWrites=self.motionMetrics.rootWrites,
            contentBuilds=self.motionMetrics.contentBuilds, textureFailures=self.motionMetrics.textureFailures,
            anchorFailures=self.motionMetrics.anchorFailures, lastTextureError=self.motionMetrics.lastTextureError },
        buffIconFontSizeContractVersion = tonumber(self.BuffIconFontSizeContractVersion) or 0,
        castYOffsetContractVersion = tonumber(self.CastYOffsetContractVersion) or 0,
        running = self.running == true,
        consumerHeld = self.consumerHeld == true,
        calibrationSuppressed = self.calibrationSuppressed == true,
        calibrationSuppressionReason = self.calibrationSuppressionReason,
        calibrationSuppressionCount = tonumber(self.calibrationSuppressionCount) or 0,
        calibrationRestoreCount = tonumber(self.calibrationRestoreCount) or 0,
        liveHudSuppressionContractVersion = tonumber(self.LiveHudSuppressionContractVersion) or 0,
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

if type(S.Events.SubscribeInternal) == "function" then
    if type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(P.lifecycleOwner) end
    S.Events:SubscribeInternal("v3.feature.lifecycle", P.lifecycleOwner, function(_, featureId)
        if tostring(featureId or "") == "combat_buff_display" then P:Reconcile("feature_lifecycle") end
    end)
    S.Events:SubscribeInternal("v3.buff_display.settings", P.lifecycleOwner, function() P:Reconcile("settings_global") end)
end

-- Contract 6: health-bar proxy anchor layout via pure ComputePlateLayout;
-- class now contributes exact-catalog role icon + localized text; equipment collapses when
-- absent; main/off + optional ranged share the left flank, wings/back owns the
-- right flank; x/y are local offsets.
-- Contract 8 adds authoritative Buff/Debuff fontSize consumption. Startup acceptance checks
-- the dedicated BuffIconFontSizeContractVersion too so a stale Renderer cannot silently accept
-- the new calibration UI while ignoring its font controls.
-- Contract 9 keeps equipment default-slot flow but fences every component x/y as a local offset:
-- moving offHand/mainHand/ranged/wings can no longer shift sibling slot bases.
-- 中文维护（enemy-loadout-1）：目标武器/防具是可见 Buff 类型投影；现有布局/存档契约不变。
P.TargetLoadoutPatch = "enemy-loadout-1"
Feature.BuffHeadMarkerContractVersion = 9
P:Reconcile("load")
