------------------------------------------------------------------------
-- Replicated Suite - Dashboard Card Composite (M6-v7)
--
-- Product-level card chrome shared by the high-density dashboard. M6-v7
-- removes the nested-window look: one outer surface owns the card body, the
-- header is only a shallow tonal band, and content wrappers no longer draw a
-- second full border/background on top of the card.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
S.Visual = S.Visual or {}
local D = {}
S.Visual.DashboardCard = D

function D:Create(parent, id, title, actions, opts)
    opts = type(opts) == "table" and opts or {}
    local card = { id = id, actions = {} }
    local headerH = tonumber(opts.headerHeight) or (S.VisualTokens and S.VisualTokens:Metric("size", "cardHeaderH", 37)) or 37
    local accentTone = tostring(opts.accentTone or "cyan")
    local borderTone = tostring(opts.borderTone or "separatorSoft")
    local titleTone = tostring(opts.titleTone or (accentTone == "gold" and "brand" or "primary"))
    local headerSurface = tostring(opts.headerSurface or "header")
    local contentSurface = tostring(opts.contentSurface or "cardInset")

    card.component = RSUI:Border({
        id = id .. "_card", parent = parent, width = 100, height = 100,
        padding = 0, variant = "card", gradient = true, accentStrip = false,
    })
    if card.component == nil then return nil end
    card.root = card.component.root
    if S.Visual and S.Visual.Surface then
        S.Visual.Surface:Apply(card.root, {
            surface = "card", borderTone = borderTone, topAccent = true,
            accentTone = tostring(opts.topAccentTone or accentTone),
            accentHeight = tonumber(opts.topAccentHeight) or 1,
            cornerCaps = opts.cornerCaps == true, cornerLength = 7, cornerThickness = 1,
            cornerColor = S.VisualTokens and S.VisualTokens:Color("goldFaint") or nil,
        })
    end

    card.outerStack = RSUI:VerticalBox({ id = id .. "_outer", parent = card.component, gap = 0 })
    card.headerSurface = RSUI:Border({
        id = id .. "_header_surface", parent = card.outerStack,
        height = headerH,
        padding = { left = 8, right = 7, top = 1, bottom = 1 },
        variant = "header", gradient = true, accentStrip = false,
        slot = { size = "fixed", height = headerH, hAlign = "fill" },
    })
    if card.headerSurface and S.Visual and S.Visual.Surface then
        S.Visual.Surface:Apply(card.headerSurface.root, {
            surface = headerSurface, borderTone = "separatorSoft",
            topAccent = false, innerBottom = true,
        })
        if card.headerSurface.root.rsBorder and card.headerSurface.root.rsBorder.SetVisible then card.headerSurface.root.rsBorder:SetVisible(false) end
    end
    card.header = RSUI:HorizontalBox({ id = id .. "_header", parent = card.headerSurface, gap = 5 })

    if opts.iconKind ~= nil and S.Visual and S.Visual.Nav and type(S.Visual.Nav.CreateGlyph)=="function" then
        card.headerIcon = RSUI:Border({
            id=id.."_header_icon", parent=card.header, width=25, height=22, padding=0, variant="soft", gradient=false,
            slot={size="fixed",width=25,hAlign="fill",vAlign="center"},
        })
        if card.headerIcon and card.headerIcon.root then
            if card.headerIcon.root.rsBorder and card.headerIcon.root.rsBorder.SetVisible then card.headerIcon.root.rsBorder:SetVisible(false) end
            if card.headerIcon.root.rsBackground and card.headerIcon.root.rsBackground.SetVisible then card.headerIcon.root.rsBackground:SetVisible(false) end
            card.headerGlyphs=S.Visual.Nav:CreateGlyph(card.headerIcon.root,opts.iconKind,{ox=3,oy=2})
            if type(S.Visual.Nav.PaintGlyph)=="function" then S.Visual.Nav:PaintGlyph(card.headerGlyphs,accentTone) end
        end
    else
        card.headerMark = RSUI:Border({
            id = id .. "_header_mark", parent = card.header, width = 3, height = 18,
            padding = 0, variant = "soft", gradient = false,
            slot = { size = "fixed", width = 3, hAlign = "fill", vAlign = "center" },
        })
        if card.headerMark and S.Visual and S.Visual.Surface then
            S.Visual.Surface:Apply(card.headerMark.root, { surface = accentTone, borderTone = accentTone, topAccent = false })
        end
    end

    card.title = RSUI:Text({
        id = id .. "_title", parent = card.header, text = tostring(title or ""),
        tone = titleTone, fontSize = tonumber(opts.titleFontSize) or 12,
        shadow = true, overflow = "ellipsis",
        slot = { size = "auto", minWidth = 64, maxWidth = tonumber(opts.titleMaxWidth) or 200, hAlign = "fill", vAlign = "center" },
    })

    card.subtitle = RSUI:Text({
        id = id .. "_subtitle", parent = card.header, text = tostring(opts.subtitle or ""),
        tone = tostring(opts.subtitleTone or "caption"), fontSize = tonumber(opts.subtitleFontSize) or 8,
        overflow = "ellipsis",
        slot = { size = "fill", fill = 1, minWidth = 20, hAlign = "fill", vAlign = "center" },
    })
    card.subtitle:SetVisible(tostring(opts.subtitle or "") ~= "")

    for index, action in ipairs(type(actions) == "table" and actions or {}) do
        local button = S.Visual.ActionButton:Create({
            id = id .. "_action_" .. tostring(index), parent = card.header,
            text = tostring(action.text or "操作"), fontSize = tonumber(action.fontSize) or 9,
            compact = true, height = tonumber(action.height) or 24, visualVariant = action.variant or "ghost",
            slot = { size = "fixed", width = tonumber(action.width) or 48, hAlign = "fill", vAlign = "center" },
            onClick = action.onClick,
        })
        card.actions[#card.actions + 1] = button
    end

    card.contentSurface = RSUI:Border({
        id = id .. "_content_surface", parent = card.outerStack,
        padding = opts.padding or { left = 7, right = 7, top = 4, bottom = 5 },
        variant = "card", gradient = true, accentStrip = false,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    if card.contentSurface and S.Visual and S.Visual.Surface then
        -- The outer card is the only full background/border.  The content
        -- wrapper exists for padding/layout only; hiding its native skin is
        -- what turns six stacked mini-windows into one coherent dashboard.
        if card.contentSurface.root.rsBorder and card.contentSurface.root.rsBorder.SetVisible then card.contentSurface.root.rsBorder:SetVisible(false) end
        if card.contentSurface.root.rsBackground and card.contentSurface.root.rsBackground.SetVisible then card.contentSurface.root.rsBackground:SetVisible(false) end
    end
    card.stack = RSUI:VerticalBox({ id = id .. "_stack", parent = card.contentSurface, gap = tonumber(opts.gap) or 4 })

    function card:SetSubtitle(text, tone)
        text = tostring(text or "")
        if self.subtitle ~= nil then
            self.subtitle:SetText(text)
            if tone ~= nil then self.subtitle:SetTone(tone) end
            self.subtitle:SetVisible(text ~= "")
        end
        return true
    end

    function card:SetActionVisible(index, visible)
        local button = self.actions and self.actions[index] or nil
        if button ~= nil and type(button.SetVisible) == "function" then button:SetVisible(visible == true); return true end
        return false
    end

    function card:SetActionText(index, text)
        local button = self.actions and self.actions[index] or nil
        if button ~= nil and type(button.SetText) == "function" then button:SetText(tostring(text or "")); return true end
        return false
    end

    return card
end
