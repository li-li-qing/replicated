------------------------------------------------------------------------
-- Replicated Suite - RSUI Playground / Graduation Harness v1
--
-- Developer-only, explicit entry points. Nothing in this file creates widgets,
-- scans components, or runs stress work during normal addon startup/Tick.
--
-- Purpose:
--   * prove that complex UI can be composed from primitive/panel widgets;
--   * exercise resolution-safe layout without touching business modules;
--   * stress ListView/TileView virtualization with large logical data counts;
--   * provide reusable composite *examples*, not a new business Authority.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
if type(RSUI) ~= "table" then return end

local Playground = { version = 2 }
RSUI.Playground = Playground
RSUI.Composite = RSUI.Composite or {}

local function Token(path, fallback)
    if S.UITokens ~= nil and type(S.UITokens.Number) == "function" then return S.UITokens:Number(path, fallback) end
    return fallback
end

------------------------------------------------------------------------
-- Composite examples
--
-- These deliberately use existing primitives instead of RegisterType(). The
-- goal is to demonstrate the UMG composition model and keep the standard type
-- registry small/stable at the end of Foundation development.
------------------------------------------------------------------------
function RSUI.Composite.StatusCard(parent, spec)
    spec = type(spec) == "table" and spec or {}
    local id = tostring(spec.id or "status_card")
    local root = RSUI:Border({ id = id, parent = parent, width = spec.width or 260, height = spec.height or 88, padding = spec.padding or 8, variant = spec.variant or "card" })
    if root == nil then return nil end
    local stack = RSUI:VerticalBox({ id = id .. "_stack", parent = root, gap = spec.gap or 4 })
    local header = RSUI:HorizontalBox({ id = id .. "_header", parent = stack, height = 22, gap = 6, slot = { size = "fixed", height = 22 } })
    local title = RSUI:Text({ id = id .. "_title", parent = header, text = spec.title or "Status", tone = spec.titleTone or "default", overflow = "ellipsis", slot = { size = "fill", fill = 1 } })
    local value = RSUI:Text({ id = id .. "_value", parent = header, text = spec.value or "", tone = spec.valueTone or spec.tone or "accent", overflow = "ellipsis", align = ALIGN_RIGHT, slot = { size = "auto" } })
    local progress = RSUI:ProgressBar({ id = id .. "_progress", parent = stack, percent = tonumber(spec.percent) or 0, height = spec.progressHeight or 10, slot = { size = "fixed", height = spec.progressHeight or 10 } })
    local detail = RSUI:Text({ id = id .. "_detail", parent = stack, text = spec.detail or "", tone = spec.detailTone or "muted", overflow = spec.detailOverflow or "ellipsis", slot = { size = "fill", fill = 1 } })
    root.stack, root.header, root.titleText, root.valueText, root.progress, root.detailText = stack, header, title, value, progress, detail
    function root:SetData(data)
        data = type(data) == "table" and data or {}
        if data.title ~= nil then title:SetText(data.title) end
        if data.value ~= nil then value:SetText(data.value) end
        if data.detail ~= nil then detail:SetText(data.detail) end
        if data.percent ~= nil then progress:SetPercent(data.percent) end
        return self
    end
    return root
end

function RSUI.Composite.AuraSlot(parent, spec)
    spec = type(spec) == "table" and spec or {}
    local id = tostring(spec.id or "aura_slot")
    local size = math.max(20, tonumber(spec.size) or 42)
    local root = RSUI:SizeBox({ id = id, parent = parent, widthOverride = size, heightOverride = size })
    local overlay = RSUI:Overlay({ id = id .. "_overlay", parent = root })
    local image = RSUI:Image({ id = id .. "_icon", parent = overlay, texture = spec.texture, width = size, height = size, slot = { hAlign = "fill", vAlign = "fill" } })
    local stacks = RSUI:Text({ id = id .. "_stacks", parent = overlay, text = spec.stacks or "", tone = spec.stackTone or "default", fontSize = spec.fontSize or 10, align = ALIGN_RIGHT, width = 18, height = 14, slot = { hAlign = "right", vAlign = "top" } })
    local time = RSUI:Text({ id = id .. "_time", parent = overlay, text = spec.time or "", tone = spec.timeTone or "default", fontSize = spec.fontSize or 10, align = ALIGN_CENTER, height = 14, slot = { hAlign = "fill", vAlign = "bottom" } })
    root.overlay, root.image, root.stackText, root.timeText = overlay, image, stacks, time
    function root:SetAura(data)
        data = type(data) == "table" and data or {}
        if data.texture ~= nil and type(image.SetTexture) == "function" then image:SetTexture(data.texture) end
        if data.stacks ~= nil then stacks:SetText(data.stacks) end
        if data.time ~= nil then time:SetText(data.time) end
        return self
    end
    return root
end

------------------------------------------------------------------------
-- Playground showcase
------------------------------------------------------------------------
function Playground:Build(parent, spec)
    if parent == nil then return nil, "parent_required" end
    spec = type(spec) == "table" and spec or {}
    local id = tostring(spec.id or "rsui_playground")
    local width = math.max(320, tonumber(spec.width) or 680)
    local height = math.max(240, tonumber(spec.height) or 520)

    local root = RSUI:Border({ id = id, parent = parent, width = width, height = height, padding = 10, variant = "card" })
    if root == nil then return nil, "root_create_failed" end
    local stack = RSUI:VerticalBox({ id = id .. "_stack", parent = root, gap = 8 })
    RSUI:Text({ id = id .. "_title", parent = stack, text = "RSUI Playground · Foundation Graduation", fontSize = 15, tone = "accent", overflow = "ellipsis", slot = { size = "fixed", height = 24 } })
    RSUI:Text({ id = id .. "_hint", parent = stack, text = "基础布局 / 文本安全 / 数据虚拟化 / 交互服务均为事件驱动，无 Tick 虚拟树。", tone = "muted", overflow = "wrap", maxLines = 2, slot = { size = "auto" } })

    local cards = RSUI:UniformGrid({ id = id .. "_cards", parent = stack, minCellWidth = 180, maxColumns = 3, gap = 8, slot = { size = "fixed", height = 102 } })
    RSUI.Composite.StatusCard(cards, { id = id .. "_card_a", title = "Layout", value = "PASS", detail = "SafeZone / Auto Fill / Wrap", percent = 1 })
    RSUI.Composite.StatusCard(cards, { id = id .. "_card_b", title = "Virtual Data", value = "Bounded", detail = "ListView / TileView Row Pool", percent = 0.86 })
    RSUI.Composite.StatusCard(cards, { id = id .. "_card_c", title = "Native Diff", value = "0 repeat", detail = "same state → no native write", percent = 1 })

    local body = RSUI:SplitView({
        id = id .. "_body", parent = stack, orientation = "horizontal", mode = "ratio", ratio = 0.52,
        minPrimary = 150, minSecondary = 150, dividerSize = 6, slot = { size = "fill", fill = 1 },
    })
    local list = RSUI:ListView({
        id = id .. "_list", parent = body, rowHeight = 26, overscan = 1,
        getCount = function() return 1000 end,
        getItem = function(index) return { id = "row:" .. tostring(index), text = "Row " .. tostring(index) .. " · Реплика / 中文" } end,
        itemText = function(item) return item.text end,
        selectionMode = "single", selectable = true,
        slot = { size = "fill", fill = 1 },
    })
    local tiles = RSUI:TileView({
        id = id .. "_tiles", parent = body, minTileWidth = 62, tileHeight = 44, overscanRows = 1,
        getCount = function() return 1000 end,
        getItem = function(index) return { id = "tile:" .. tostring(index), text = "#" .. tostring(index) } end,
        itemText = function(item) return item.text end,
        selectionMode = "multi", selectable = true,
        slot = { size = "fill", fill = 1 },
    })

    local footer = RSUI:HorizontalBox({ id = id .. "_footer", parent = stack, height = 28, gap = 6, slot = { size = "fixed", height = 28 } })
    local tipButton = RSUI:Button({ id = id .. "_tip", parent = footer, text = "Tooltip", slot = { size = "fixed", width = 96 } })
    local menuButton = RSUI:Button({ id = id .. "_menu", parent = footer, text = "Context Menu", slot = { size = "fixed", width = 118 } })
    RSUI:Spacer({ id = id .. "_spacer", parent = footer, slot = { size = "fill", fill = 1 } })
    RSUI:Text({ id = id .. "_types", parent = footer, text = tostring(#RSUI.typeOrder) .. " standard types", tone = "muted", align = ALIGN_RIGHT, slot = { size = "auto" } })

    if RSUI.Tooltip ~= nil then RSUI.Tooltip:Bind(tipButton, { text = "这是 RSUI 统一 TooltipService；优先使用 RU Native SetTooltip，缺失时才使用池化 fallback。" }) end
    if RSUI.ContextMenu ~= nil then
        RSUI.ContextMenu:Bind(menuButton, function()
            return {
                { id = "refresh", text = "刷新 Playground", onClick = function() root:InvalidateMeasure("playground_refresh") end },
                { id = "select", text = "选中第一行", onClick = function() list:SetSelectedIndex(1) end },
                { separator = true },
                { id = "close", text = "关闭菜单" },
            }
        end)
    end

    root.stack, root.listView, root.tileView, root.tipButton, root.menuButton = stack, list, tiles, tipButton, menuButton
    root:Layout(0, 0, width, height)
    RSUI.metrics.playgroundBuilds = (tonumber(RSUI.metrics.playgroundBuilds) or 0) + 1
    return root
end

------------------------------------------------------------------------
-- Explicit virtualization stress harness
------------------------------------------------------------------------
function Playground:RunStress(parent, spec)
    if parent == nil then return nil, "parent_required" end
    spec = type(spec) == "table" and spec or {}
    local logicalCount = math.max(1, math.min(100000, math.floor(tonumber(spec.count) or 10000)))
    local width = math.max(320, tonumber(spec.width) or 640)
    local height = math.max(180, tonumber(spec.height) or 280)
    local id = tostring(spec.id or "rsui_stress")
    local host = RSUI:HorizontalBox({ id = id, parent = parent, width = width, height = height, gap = 8 })
    if host == nil then return nil, "host_create_failed" end

    local list = RSUI:ListView({
        id = id .. "_list", parent = host, rowHeight = 24, maxPoolSize = spec.listPool or 48,
        getCount = function() return logicalCount end,
        getItem = function(index) return { id = "L:" .. tostring(index), text = "List " .. tostring(index) } end,
        itemText = function(item) return item.text end,
        slot = { size = "fill", fill = 1 },
    })
    local tile = RSUI:TileView({
        id = id .. "_tile", parent = host, minTileWidth = 56, tileHeight = 42, maxPoolSize = spec.tilePool or 96,
        getCount = function() return logicalCount end,
        getItem = function(index) return { id = "T:" .. tostring(index), text = tostring(index) } end,
        itemText = function(item) return item.text end,
        slot = { size = "fill", fill = 1 },
    })

    host:Layout(0, 0, width, height)
    local jump = math.max(1, logicalCount - math.max(1, math.floor(logicalCount * 0.1)))
    list:ScrollToIndex(jump)
    tile:ScrollToIndex(jump)
    host:Layout(0, 0, width, height)

    local listStats = type(list.GetPoolStats) == "function" and list:GetPoolStats() or {}
    local tileStats = type(tile.GetPoolStats) == "function" and tile:GetPoolStats() or {}
    RSUI.metrics.playgroundStressRuns = (tonumber(RSUI.metrics.playgroundStressRuns) or 0) + 1
    return {
        ok = true,
        logicalCount = logicalCount,
        listPool = tonumber(listStats.poolSize or listStats.created) or #(list.pool or {}),
        tilePool = tonumber(tileStats.poolSize or tileStats.created) or #(tile.pool or {}),
        listVisible = { list:GetVisibleRange() },
        tileVisible = { tile:GetVisibleRange() },
        host = host,
        list = list,
        tile = tile,
    }
end
