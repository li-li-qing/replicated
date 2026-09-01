------------------------------------------------------------------------
-- Replicated Suite - Visual Layer Tokens (M6-v7)
--
-- Product-level presentation semantics built on top of the frozen RSUI
-- Foundation.  M6-v4 tightens visual parity with the ArcheAge console mock:
-- gold is reserved for brand/key edges, cyan owns interaction, and nested
-- surfaces are separated by luminance rather than bright full-box outlines.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

local V = {
    version = 6,
    spacing = { xs = 3, sm = 6, md = 9, lg = 12, xl = 16 },
    size = {
        chromeH = 40,
        navItemH = 31,
        navHeaderH = 23,
        cardHeaderH = 30,
        denseRowH = 22,
        normalRowH = 24,
        compactButtonH = 25,
    },
    typography = {
        brand = { size = 16, tone = "brand" },
        pageTitle = { size = 15, tone = "textStrong" },
        section = { size = 11, tone = "brand" },
        cardTitle = { size = 12, tone = "primary" },
        tableHeader = { size = 10, tone = "tableHeader" },
        body = { size = 10, tone = "default" },
        secondary = { size = 9, tone = "muted" },
        numeric = { size = 10, tone = "textStrong" },
    },

    -- Verified ThreeColorDrawable bands used by the product Visual Layer.
    -- Surface:Apply repaints the Theme-owned gradient instead of stacking a
    -- second full-size drawable. This is the key to keeping the console as one
    -- coherent blue-black application surface rather than flat black boxes.
    gradient = {
        app = { top={0.032,0.094,0.118}, mid={0.018,0.056,0.076}, bottom={0.008,0.030,0.044}, alpha=0.995 },
        sidebar = { top={0.038,0.112,0.134}, mid={0.021,0.067,0.086}, bottom={0.009,0.034,0.048}, alpha=0.995 },
        section = { top={0.038,0.115,0.136}, mid={0.022,0.071,0.089}, bottom={0.010,0.036,0.050}, alpha=0.990 },
        card = { top={0.046,0.130,0.150}, mid={0.025,0.078,0.096}, bottom={0.010,0.040,0.054}, alpha=0.992 },
        cardRaised = { top={0.062,0.162,0.182}, mid={0.034,0.101,0.120}, bottom={0.015,0.050,0.064}, alpha=0.994 },
        cardInset = { top={0.024,0.074,0.091}, mid={0.014,0.048,0.063}, bottom={0.007,0.028,0.041}, alpha=0.986 },
        header = { top={0.068,0.176,0.198}, mid={0.036,0.115,0.136}, bottom={0.015,0.057,0.074}, alpha=0.995 },
        headerRaised = { top={0.074,0.188,0.210}, mid={0.041,0.124,0.145}, bottom={0.017,0.061,0.078}, alpha=0.996 },
        tableHeader = { top={0.047,0.132,0.151}, mid={0.027,0.090,0.108}, bottom={0.012,0.047,0.061}, alpha=0.995 },
    },
    color = {
        -- Main depth ladder.  Keep adjacent surfaces visibly different on the
        -- RU client even when CreateThreeColorDrawable falls back to flat fills.
        app = { 0.012, 0.038, 0.054, 0.994 },
        sidebar = { 0.015, 0.049, 0.067, 0.994 },
        section = { 0.016, 0.056, 0.073, 0.986 },
        card = { 0.018, 0.061, 0.079, 0.990 },
        cardRaised = { 0.030, 0.094, 0.112, 0.992 },
        cardInset = { 0.014, 0.050, 0.066, 0.982 },
        header = { 0.030, 0.104, 0.124, 0.994 },
        headerRaised = { 0.037, 0.125, 0.146, 0.996 },
        tableHeader = { 0.023, 0.086, 0.104, 0.994 },
        rowA = { 0.008, 0.032, 0.044, 0.90 },
        rowB = { 0.012, 0.043, 0.056, 0.92 },
        rowHover = { 0.026, 0.102, 0.120, 0.95 },
        rowSelected = { 0.032, 0.145, 0.170, 0.97 },

        -- Brand vs interaction.  The previous pass was visually dominated by
        -- gold full-box borders; M6-v4 makes those edges much quieter.
        gold = { 0.92, 0.70, 0.29, 1.00 },
        goldSoft = { 0.70, 0.50, 0.19, 0.44 },
        goldFaint = { 0.46, 0.34, 0.14, 0.20 },
        cyan = { 0.20, 0.74, 0.84, 1.00 },
        cyanSoft = { 0.13, 0.49, 0.57, 0.82 },
        cyanDim = { 0.075, 0.285, 0.330, 0.62 },
        cyanFaint = { 0.052, 0.195, 0.230, 0.42 },

        textStrong = { 0.96, 0.94, 0.87, 1.00 },
        tableHeaderText = { 0.74, 0.83, 0.82, 1.00 },
        caption = { 0.50, 0.59, 0.60, 1.00 },
        separator = { 0.080, 0.275, 0.305, 0.48 },
        separatorSoft = { 0.044, 0.165, 0.188, 0.30 },
        danger = { 0.72, 0.11, 0.08, 0.96 },
        dangerHover = { 0.90, 0.18, 0.12, 0.99 },
    },
}

function V:Metric(group, key, fallback)
    local t = self[group]
    local value = type(t) == "table" and t[key] or nil
    return tonumber(value) or tonumber(fallback) or 0
end

function V:Color(key, fallback)
    local value = self.color[tostring(key or "")]
    if type(value) == "table" then return value end
    return fallback
end

S.VisualTokens = V

-- Extend the existing semantic label palette without replacing UITokens.
if type(S.UITokens) == "table" then
    S.UITokens.tone = type(S.UITokens.tone) == "table" and S.UITokens.tone or {}
    S.UITokens.tone.brand = V.color.gold
    S.UITokens.tone.textStrong = V.color.textStrong
    S.UITokens.tone.tableHeader = V.color.tableHeaderText
    S.UITokens.tone.caption = V.color.caption
    S.UITokens.tone.primary = V.color.cyan
end
