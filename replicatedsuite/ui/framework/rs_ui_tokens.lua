------------------------------------------------------------------------
-- Replicated Suite - UI Design Tokens v2
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local C = S.Constants or {}

local Tokens = {
    version = 2,
    spacing = { xxs = 2, xs = 4, sm = 8, md = 12, lg = 16, xl = 24, xxl = 32 },
    font = { caption = 9, small = 10, body = 11, bodyLarge = 12, section = 13, title = 15, hero = 18 },
    size = {
        controlH = 24, buttonH = 26, compactButtonH = 22, inputH = 24,
        titleBarH = 32, sectionHeaderH = 28, footerH = 30, rowH = 28,
        compactRowH = 23, iconSm = 16, iconMd = 20, hitMin = 28,
        formLabelW = 116, formControlW = 180,
    },
    alpha = { disabled = 0.45, muted = 0.68, panel = 0.94, card = 0.92, normal = 1.0 },
    tone = {},
    component = {
        window = { padding = 12, gap = 8, titleBarH = 32, footerH = 30 },
        card = { padding = 10, gap = 6 },
        form = { rowH = 28, fieldH = 52, compactFieldH = 46, gap = 6, labelW = 116, controlW = 180, feedbackW = 96 },
        grid = { gapX = 8, gapY = 8 },
    },
}

local color = C.Color or {}
Tokens.tone.default = color.text
Tokens.tone.text = color.text
Tokens.tone.muted = color.textMuted
Tokens.tone.accent = color.accent
Tokens.tone.info = color.blue
Tokens.tone.success = color.green
Tokens.tone.warning = color.yellow
Tokens.tone.caution = color.orange
Tokens.tone.danger = color.red
Tokens.tone.purple = color.purple
Tokens.tone.green = color.green
Tokens.tone.yellow = color.yellow
Tokens.tone.orange = color.orange
Tokens.tone.red = color.red
Tokens.tone.blue = color.blue

-- Button-state colors are semantic tokens rather than page-owned literals.
Tokens.button = {
    normal = { 0.025, 0.065, 0.080, 0.97 },
    active = { 0.035, 0.145, 0.170, 0.99 },
    hover = { 0.045, 0.120, 0.145, 0.99 },
    activeHover = { 0.055, 0.190, 0.220, 0.99 },
    pushed = { 0.018, 0.050, 0.065, 0.99 },
    disabled = { 0.030, 0.040, 0.045, 0.70 },
}

local function ResolvePath(root, path)
    if type(path) ~= "string" or path == "" then return nil end
    local node = root
    for part in path:gmatch("[^%.]+") do
        if type(node) ~= "table" then return nil end
        node = node[part]
        if node == nil then return nil end
    end
    return node
end

function Tokens:Get(path, fallback)
    local value = ResolvePath(self, path)
    if value == nil then return fallback end
    return value
end

function Tokens:Number(path, fallback)
    return tonumber(self:Get(path, fallback)) or tonumber(fallback) or 0
end

function Tokens:Color(name, fallback)
    local value = self.tone[tostring(name or "default")]
    if type(value) ~= "table" then value = fallback end
    return value
end

function Tokens:Scale(value)
    value = tonumber(value) or 0
    if S.Layout ~= nil and type(S.Layout.GetContext) == "function" then
        local ok, ctx = pcall(function() return S.Layout:GetContext() end)
        if ok and type(ctx) == "table" then return value * (tonumber(ctx.addonScale) or 1) end
    end
    return value
end

function Tokens:Snapshot()
    return {
        version = self.version,
        spacing = self.spacing,
        font = self.font,
        size = self.size,
        alpha = self.alpha,
    }
end

S.UITokens = Tokens
