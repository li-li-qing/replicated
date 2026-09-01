------------------------------------------------------------------------
-- Replicated Suite - Compact Stats Composite (M6-v3)
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
S.Visual = S.Visual or {}
local C = {}
S.Visual.CompactStats = C

function C:Create(spec)
    spec = type(spec) == "table" and spec or {}
    local view = { rows = {}, maxRows = math.max(1, tonumber(spec.maxRows) or 6) }
    view.rootBox = RSUI:VerticalBox({
        id = spec.id, parent = spec.parent, gap = 0,
        slot = spec.slot,
    })
    if view.rootBox == nil then return nil end
    for i = 1, view.maxRows do
        local band = RSUI:Border({
            id = spec.id .. "_band_" .. i, parent = view.rootBox,
            height = tonumber(spec.rowHeight) or 25,
            padding = { left = 6, right = 6, top = 2, bottom = 2 }, variant = "soft", gradient = false,
            -- CompactStats lives in a responsive dashboard band. rowHeight is a
            -- preferred Measure size, not an Arrange minimum; visible rows share
            -- the actual content height so a 768p/minimized band cannot push the
            -- fourth statistic outside its card.
            slot = { size = "fill", fill = 1, hAlign = "fill" },
        })
        if band and S.Visual and S.Visual.Surface then
            S.Visual.Surface:Apply(band.root, { surface = (i % 2 == 0) and "rowB" or "rowA", borderTone = "separatorSoft", topAccent = false, innerBottom = true })
        end
        local row = RSUI:HorizontalBox({ id = spec.id .. "_row_" .. i, parent = band, gap = 6 })
        local marker = RSUI:Border({
            id = spec.id .. "_marker_" .. i, parent = row, width = 3, height = 14, padding = 0, variant = "soft", gradient = false,
            slot = { size = "fixed", width = 3, hAlign = "fill", vAlign = "center" },
        })
        if marker and S.Visual and S.Visual.Surface then S.Visual.Surface:Apply(marker.root, { surface = "cyan", borderTone = "cyan", topAccent = false }) end
        local label = RSUI:Text({
            id = spec.id .. "_label_" .. i, parent = row, text = "", tone = "muted", fontSize = 9, overflow = "ellipsis",
            slot = { size = "fill", fill = 1, minWidth = 46, hAlign = "fill", vAlign = "center" },
        })
        local value = RSUI:Text({
            id = spec.id .. "_value_" .. i, parent = row, text = "", tone = "textStrong", fontSize = 10, align = ALIGN_RIGHT, overflow = "ellipsis",
            slot = { size = "fixed", width = tonumber(spec.valueWidth) or 96, hAlign = "fill", vAlign = "center" },
        })
        view.rows[i] = { band = band, marker = marker, label = label, value = value }
    end

    function view:SetRows(rows)
        rows = type(rows) == "table" and rows or {}
        for i, entry in ipairs(self.rows) do
            local data = rows[i]
            local show = data ~= nil
            entry.band:SetVisible(show)
            if show then
                entry.label:SetText(tostring(data.name or data.label or "--"))
                entry.value:SetText(tostring(data.value or "--"))
                entry.value:SetTone(data.tone or "textStrong")
                if entry.marker and entry.marker.root and entry.marker.root.rsBackground and entry.marker.root.rsBackground.SetColor and S.Theme then
                    local c = S.Theme:ToneColor(data.tone or "blue")
                    pcall(function() entry.marker.root.rsBackground:SetColor(c[1],c[2],c[3],0.92) end)
                end
            end
        end
        return true
    end
    return view
end
