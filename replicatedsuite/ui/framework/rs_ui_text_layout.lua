------------------------------------------------------------------------
-- Replicated Suite - RSUI Text Layout / Measurement v1
--
-- UMG-like text sizing authority for RSUI. This code is only used when text
-- or layout changes; it must never be called from a per-frame Tick loop.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
if type(RSUI) ~= "table" then return end

local TextLayout = { version = 3, metrics = { measures = 0, wraps = 0, fits = 0, overflows = 0, wordBoundaryBreaks = 0 } }
RSUI.TextLayout = TextLayout

local function Utf8Chars(text)
    local value = tostring(text or "")
    local chars, i = {}, 1
    while i <= #value do
        local b = string.byte(value, i) or 0
        local n = b >= 0xF0 and 4 or (b >= 0xE0 and 3 or (b >= 0xC0 and 2 or 1))
        chars[#chars + 1] = string.sub(value, i, math.min(#value, i + n - 1))
        i = i + n
    end
    return chars
end


local function ResolveNativeFont(label, requested)
    local target = tonumber(requested) or tonumber(label and label.rsBaseFontSize) or 11
    local localScale = tonumber(label and label.rsLocalFontScale) or 1.0
    if S.Theme ~= nil and type(S.Theme.ResolveFontSize) == "function" then
        target = S.Theme:ResolveFontSize(target, localScale)
    else
        target = math.max(1, target * localScale)
    end
    return target
end

local function Estimate(text, fontSize)
    local size = math.max(1, tonumber(fontSize) or 11)
    local units, i, value = 0, 1, tostring(text or "")
    while i <= #value do
        local b = string.byte(value, i) or 0
        if b < 0x80 then units = units + (b == 32 and 0.34 or 0.56); i = i + 1
        elseif b >= 0xF0 then units = units + 1.0; i = i + 4
        elseif b >= 0xE0 then units = units + 1.0; i = i + 3
        elseif b >= 0xC0 then units = units + 1.0; i = i + 2
        else units = units + 1.0; i = i + 1 end
    end
    return units * size
end

function TextLayout:MeasureWidth(label, text, fontSize)
    self.metrics.measures = self.metrics.measures + 1
    local value = tostring(text or "")
    if label ~= nil and label.style ~= nil and type(label.style.GetTextWidth) == "function" then
        local ok, measured = pcall(function() return label.style:GetTextWidth(value) end)
        if ok and tonumber(measured) ~= nil then
            local width = math.max(0, tonumber(measured))
            -- TextStyle measures the *currently applied native* font. RSUI specs
            -- store design/base font sizes, while Theme resolves them through the
            -- active addon/font scale. Compare native-to-native sizes so normal
            -- Measure sees the real physical text width and ShrinkToFit can probe
            -- another base size without mutating the widget first.
            local applied = tonumber(label.rsAppliedFontSize)
            local requested = tonumber(fontSize) or tonumber(label.rsBaseFontSize)
            local target = ResolveNativeFont(label, requested)
            if applied ~= nil and applied > 0 and target ~= nil and target > 0 and target ~= applied then
                width = width * (target / applied)
            end
            return width
        end
    end
    return Estimate(value, fontSize)
end

function TextLayout:LineHeight(label, fontSize)
    if label ~= nil and label.style ~= nil and type(label.style.GetLineHeight) == "function" then
        local ok, height = pcall(function() return label.style:GetLineHeight() end)
        if ok and tonumber(height) ~= nil and tonumber(height) > 0 then
            local value = tonumber(height)
            local applied = tonumber(label.rsAppliedFontSize)
            local requested = tonumber(fontSize) or tonumber(label.rsBaseFontSize)
            local target = ResolveNativeFont(label, requested)
            if applied ~= nil and applied > 0 and target ~= nil and target > 0 and target ~= applied then value = value * (target / applied) end
            return value
        end
    end
    return math.max(1, math.ceil((tonumber(fontSize) or 11) * 1.25))
end

function TextLayout:Ellipsize(label, text, width, fontSize, suffix)
    self.metrics.fits = self.metrics.fits + 1
    local value = tostring(text or "")
    local available = math.max(0, tonumber(width) or 0)
    suffix = tostring(suffix or "…")
    if self:MeasureWidth(label, value, fontSize) <= available then return value, false end
    self.metrics.overflows = self.metrics.overflows + 1
    local suffixW = self:MeasureWidth(label, suffix, fontSize)
    if suffixW > available then return "", true end
    local chars = Utf8Chars(value)
    local low, high, best = 0, #chars, 0
    while low <= high do
        local mid = math.floor((low + high) / 2)
        local candidate = table.concat(chars, "", 1, mid) .. suffix
        if self:MeasureWidth(label, candidate, fontSize) <= available then best = mid; low = mid + 1 else high = mid - 1 end
    end
    return table.concat(chars, "", 1, best) .. suffix, true
end

function TextLayout:ShrinkToFit(label, text, width, preferred, minimum)
    self.metrics.fits = self.metrics.fits + 1
    local value = tostring(text or "")
    local available = math.max(0, tonumber(width) or 0)
    preferred = math.max(1, math.floor(tonumber(preferred) or 11))
    minimum = math.max(1, math.min(preferred, math.floor(tonumber(minimum) or math.max(8, preferred - 3))))
    for size = preferred, minimum, -1 do
        if self:MeasureWidth(label, value, size) <= available then return value, size, false end
    end
    local fitted, overflow = self:Ellipsize(label, value, available, minimum)
    return fitted, minimum, overflow
end

function TextLayout:Wrap(label, text, width, fontSize, maxLines)
    self.metrics.wraps = self.metrics.wraps + 1
    local available = math.max(1, tonumber(width) or 1)
    local limit = math.max(1, math.floor(tonumber(maxLines) or 1000))
    local source = tostring(text or "")
    local output, overflow = {}, false
    local function IsSpace(ch) return ch == " " or ch == "\t" end
    local function IsSoftBreak(ch) return IsSpace(ch) or ch == "-" or ch == "/" end
    for rawLine in (source .. "\n"):gmatch("(.-)\n") do
        local chars = Utf8Chars(rawLine)
        if #chars == 0 then output[#output + 1] = "" end
        local cursor = 1
        while cursor <= #chars do
            while cursor <= #chars and IsSpace(chars[cursor]) do cursor = cursor + 1 end
            if cursor > #chars then break end
            if #output >= limit then overflow = true; break end
            local low, high, best = cursor, #chars, cursor - 1
            while low <= high do
                local mid = math.floor((low + high) / 2)
                local candidate = table.concat(chars, "", cursor, mid)
                if self:MeasureWidth(label, candidate, fontSize) <= available then best = mid; low = mid + 1 else high = mid - 1 end
            end
            if best < cursor then best = cursor end

            -- Prefer a natural word boundary for Latin/Cyrillic text. Chinese
            -- and other scripts without spaces fall back to the exact UTF-8
            -- character boundary found above, so no language needs a special
            -- business-level wrapper.
            local lineEnd, nextCursor = best, best + 1
            if best < #chars and best > cursor then
                local breakAt = nil
                for j = best, cursor + 1, -1 do
                    if IsSoftBreak(chars[j]) then breakAt = j; break end
                end
                if breakAt ~= nil then
                    if IsSpace(chars[breakAt]) then
                        lineEnd, nextCursor = breakAt - 1, breakAt + 1
                        while nextCursor <= #chars and IsSpace(chars[nextCursor]) do nextCursor = nextCursor + 1 end
                    else
                        lineEnd, nextCursor = breakAt, breakAt + 1
                    end
                    if lineEnd >= cursor then self.metrics.wordBoundaryBreaks = (tonumber(self.metrics.wordBoundaryBreaks) or 0) + 1 else lineEnd, nextCursor = best, best + 1 end
                end
            end
            output[#output + 1] = table.concat(chars, "", cursor, lineEnd)
            cursor = nextCursor
        end
        if overflow then break end
    end
    if #output > limit then while #output > limit do table.remove(output) end; overflow = true end
    if overflow and #output > 0 then
        local suffix = "…"
        local last = tostring(output[#output] or "")
        if self:MeasureWidth(label, last .. suffix, fontSize) <= available then
            output[#output] = last .. suffix
        else
            local chars = Utf8Chars(last)
            while #chars > 0 and self:MeasureWidth(label, table.concat(chars) .. suffix, fontSize) > available do table.remove(chars) end
            output[#output] = table.concat(chars) .. suffix
        end
    end
    return table.concat(output, "\n"), #output, overflow
end

function TextLayout:GetSnapshot()
    return { version = self.version, measures = self.metrics.measures, wraps = self.metrics.wraps, fits = self.metrics.fits, overflows = self.metrics.overflows, wordBoundaryBreaks = tonumber(self.metrics.wordBoundaryBreaks) or 0 }
end
