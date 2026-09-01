ReplicatedSuiteModuleSandbox:Enter('healer', {'ReplicatedHealerBoot', 'ReplicatedHealerConfig', 'ReplicatedHealerModule'})
------------------------------------------------------------------------
-- Replicated Healer - Presentation UI Bridge v1
--
-- One low-level bridge from Healer presenters to Suite UI Diff Rendering.
-- This file owns no healer business policy.
------------------------------------------------------------------------

if ReplicatedHealerCore1Loaded ~= true then return end

ReplicatedHealerPresentationBridge = ReplicatedHealerPresentationBridge or {}
local B = ReplicatedHealerPresentationBridge
B.Version = "1.0"

HealerSuiteUI = ReplicatedSuite and ReplicatedSuite.UI or nil
HEALER_UI_OWNER_MARKERS = "healer:head_markers"
HEALER_UI_OWNER_RAID = "healer:raid_overlay"

function HealerSetVisible(widget, visible, owner)
	if widget == nil then return false end
	if HealerSuiteUI ~= nil and type(HealerSuiteUI.SetVisible) == "function" then
		return HealerSuiteUI:SetVisible(widget, visible == true, owner)
	end
	if widget.rsUiVisibilityMethod == "SetVisible" and type(widget.SetVisible) == "function" then
		widget:SetVisible(visible == true); return true
	end
	if type(widget.Show) == "function" then widget:Show(visible == true); return true end
	if type(widget.SetVisible) == "function" then widget:SetVisible(visible == true); return true end
	return false
end

function HealerSetText(widget, value, owner)
	if widget == nil then return false end
	if HealerSuiteUI ~= nil and type(HealerSuiteUI.SetText) == "function" then return HealerSuiteUI:SetText(widget, value, owner) end
	if type(widget.SetText) ~= "function" then return false end
	widget:SetText(tostring(value or "")); return true
end

function HealerSetColor(widget, red, green, blue, alpha, owner)
	if widget == nil then return false end
	if HealerSuiteUI ~= nil and type(HealerSuiteUI.SetColor) == "function" then
		return HealerSuiteUI:SetColor(widget, red, green, blue, alpha, owner)
	end
	if type(widget.SetColor) ~= "function" then return false end
	widget:SetColor(red, green, blue, alpha); return true
end

function HealerSetExtent(widget, width, height, owner)
	if widget == nil then return false end
	if HealerSuiteUI ~= nil and type(HealerSuiteUI.SetExtent) == "function" then return HealerSuiteUI:SetExtent(widget, width, height, owner) end
	if type(widget.SetExtent) ~= "function" then return false end
	widget:SetExtent(width, height); return true
end

function HealerSetAnchor(widget, parent, x, y, owner)
	if widget == nil then return false end
	if HealerSuiteUI ~= nil and type(HealerSuiteUI.SetAnchor) == "function" then return HealerSuiteUI:SetAnchor(widget, parent, x, y, owner) end
	if type(widget.RemoveAllAnchors) == "function" then widget:RemoveAllAnchors() end
	if type(widget.AddAnchor) ~= "function" then return false end
	widget:AddAnchor("TOPLEFT", parent, x, y); return true
end

function HealerSetFontSize(widget, size, owner)
	if widget == nil then return false end
	if HealerSuiteUI ~= nil and type(HealerSuiteUI.SetFontSize) == "function" then return HealerSuiteUI:SetFontSize(widget, size, owner) end
	if widget.style == nil or type(widget.style.SetFontSize) ~= "function" then return false end
	widget.style:SetFontSize(size); return true
end

function CreateMovableColorPanel(parent, id, red, green, blue, alpha, layer)
	local panel = UIParent:CreateWidget("emptywidget", id, parent)
	panel:SetExtent(1, 1)
	SetMouseThrough(panel, true)
	local drawable = panel:CreateColorDrawable(red, green, blue, alpha, layer)
	drawable:AddAnchor("TOPLEFT", panel, 0, 0)
	drawable:AddAnchor("BOTTOMRIGHT", panel, 0, 0)
	function panel:SetColor(r, g, b, a)
		drawable:SetColor(r, g, b, a)
	end
	function panel:SetVisible(visible)
		drawable:SetVisible(visible)
		self:Show(visible)
	end
	-- Composite panel visibility/color must route through its adapters rather
	-- than bypassing the child drawable. UI Framework uses these hints for
	-- accurate Diff state and native-write diagnostics.
	panel.rsUiVisibilityMethod = "SetVisible"
	panel.rsUiVisibilityNativeCalls = 2
	panel.rsUiColorNativeCalls = 1
	panel:SetVisible(false)
	if HealerSuiteUI ~= nil and type(HealerSuiteUI.PrimeNativeState) == "function" then
		HealerSuiteUI:PrimeNativeState(panel, {
			width=1, height=1, visible=false,
			colorR=red, colorG=green, colorB=blue, colorA=alpha,
		})
	end
	return panel
end



B.SetVisible = HealerSetVisible
B.SetText = HealerSetText
B.SetColor = HealerSetColor
B.SetExtent = HealerSetExtent
B.SetAnchor = HealerSetAnchor
B.SetFontSize = HealerSetFontSize
B.CreateMovableColorPanel = CreateMovableColorPanel
function B:Describe()
    return { version=tostring(self.Version or "?"), suiteUi=(HealerSuiteUI ~= nil) }
end
