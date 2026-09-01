ReplicatedSuiteModuleSandbox:Enter('healer', {'ReplicatedHealerBoot', 'ReplicatedHealerConfig', 'ReplicatedHealerModule'})
-----------------------------------------------------------------------
-- Replicated Healer Recommender v3.0.7 Bootstrap
-- Author: Replicated
-- This tiny file must remain simple. It creates the visible launcher before
-- the heavier rescue-score core file is compiled/executed.
-----------------------------------------------------------------------

ReplicatedHealerBoot = ReplicatedHealerBoot or {}
if ReplicatedHealerBoot.button ~= nil and type(ReplicatedHealerBoot.button.Show) == "function" then
	pcall(function() ReplicatedHealerBoot.button:Show(false) end)
end
ReplicatedHealerBoot.generation = (tonumber(ReplicatedHealerBoot.generation) or 0) + 1
ReplicatedHealerBoot.loaded = false
ReplicatedHealerBoot.error = nil
ReplicatedHealerBoot.runtimeError = nil
ReplicatedHealerBoot.createError = nil
ReplicatedHealerBoot.launcherVisible = false

if API_TYPE == nil then
	ADDON:ImportAPI(8)
	if X2Chat ~= nil then
		X2Chat:DispatchChatMessage(
			CMF_SYSTEM,
			"Replicated 治疗推荐器：未找到 globals 文件夹，请先安装官方插件包中的 globals。"
		)
	end
	return
end

pcall(function() ADDON:ImportAPI(API_TYPE.CHAT.id) end)
pcall(function() ADDON:ImportObject(OBJECT_TYPE.TEXT_STYLE) end)
pcall(function() ADDON:ImportObject(OBJECT_TYPE.BUTTON) end)
pcall(function() ADDON:ImportObject(OBJECT_TYPE.DRAWABLE) end)
pcall(function() ADDON:ImportObject(OBJECT_TYPE.COLOR_DRAWABLE) end)
pcall(function() ADDON:ImportObject(OBJECT_TYPE.EMPTY_WIDGET) end)

local function SafeChat(message)
	if X2Chat ~= nil and X2Chat.DispatchChatMessage ~= nil then
		X2Chat:DispatchChatMessage(CMF_SYSTEM, tostring(message))
	end
end

-- Keep every button visually identical to the supplied v1.12 style.  Build
-- and register the four state backgrounds directly so their visible and
-- clickable rectangles exactly match the requested dimensions.
function ApplyReplicatedButtonStyle(button, width, height, fontSize)
	width = width or 100
	height = height or 24
	fontSize = fontSize or 11

	local fontColors = {
		normal = { 0.96, 0.92, 0.82, 1.00 },
		highlight = { 1.00, 0.96, 0.80, 1.00 },
		pushed = { 0.90, 0.86, 0.72, 1.00 },
		disabled = { 0.52, 0.55, 0.58, 1.00 },
	}
	local backgroundColors = {
		{ 0.14, 0.21, 0.29, 0.97 },
		{ 0.23, 0.35, 0.47, 0.99 },
		{ 0.08, 0.13, 0.19, 0.99 },
		{ 0.08, 0.09, 0.11, 0.72 },
	}

	if button.bgs == nil or #button.bgs < 4 then
		button.bgs = {}
		for index = 1, 4 do
			local color = backgroundColors[index]
			local drawable = button:CreateColorDrawable(color[1], color[2], color[3], color[4], "background")
			drawable:AddAnchor("TOPLEFT", button, 0, 0)
			drawable:AddAnchor("BOTTOMRIGHT", button, 0, 0)
			button.bgs[index] = drawable
		end
		button:SetNormalBackground(button.bgs[1])
		button:SetHighlightBackground(button.bgs[2])
		button:SetPushedBackground(button.bgs[3])
		button:SetDisabledBackground(button.bgs[4])
	end

	if SetButtonFontColor ~= nil then
		SetButtonFontColor(button, fontColors)
	end
	button:SetAutoResize(false)
	button:SetExtent(width, height)
	button:SetWidth(width)
	if button.style ~= nil and button.style.SetFontSize ~= nil then
		button.style:SetFontSize(fontSize)
	end
end

if ReplicatedSuiteEmbedded ~= true then
local ok, buttonOrError = pcall(function()
	local button = UIParent:CreateWidget("button", "replicatedHealerLauncherButtonV28", "UIParent", "")
	button:SetText("治疗推荐")
	ApplyReplicatedButtonStyle(button, 88, 26, 11)
	button:AddAnchor("TOPLEFT", "UIParent", 300, 100)
	if button.Enable ~= nil then
		button:Enable(true)
	end
	if button.Clickable ~= nil then
		button:Clickable(true)
	end
	if button.EnableDrag ~= nil then
		button:EnableDrag(true)
	end
	button:Show(false)
	-- Keep the launcher on the normal UI z-order.  Do not force Raise() here:
	-- native game windows opened over this area must be allowed to cover it.
	return button
end)

if ok and buttonOrError ~= nil then
	ReplicatedHealerBoot.button = buttonOrError
else
	ReplicatedHealerBoot.button = nil
	ReplicatedHealerBoot.createError = tostring(buttonOrError)
	SafeChat("Replicated 治疗推荐器：启动按钮创建失败：" .. tostring(buttonOrError))
	return
end

if ReplicatedSuiteEmbedded ~= true and ReplicatedCombatLauncherPolicy ~= nil and type(ReplicatedCombatLauncherPolicy.Register) == "function" then
	ReplicatedCombatLauncherPolicy:Register("healer", ReplicatedHealerBoot.button)
else
	pcall(function() ReplicatedHealerBoot.button:Show(false) end)
end

local HEALER_LAUNCHER_CONTENT_ID = 91832
if ReplicatedSuiteEmbedded ~= true and ADDON ~= nil then
	if type(ADDON.RegisterContentWidget) == "function" then
		pcall(function() ADDON:RegisterContentWidget(HEALER_LAUNCHER_CONTENT_ID, ReplicatedHealerBoot.button) end)
	end
	if type(ADDON.RegisterContentTriggerFunc) == "function" then
		pcall(function()
			ADDON:RegisterContentTriggerFunc(HEALER_LAUNCHER_CONTENT_ID, function(show)
				ReplicatedHealerBoot.launcherVisible = show == true
				ReplicatedHealerBoot.button:Show(ReplicatedHealerBoot.launcherVisible)
			end)
		end)
	end
end
if ReplicatedSuiteEmbedded == true then ReplicatedHealerBoot.launcherVisible = false end
ReplicatedHealerBoot.button:Show(ReplicatedHealerBoot.launcherVisible == true)

ReplicatedHealerBoot.button:SetHandler("OnDragStart", function(self)
	if type(BeginHealerSafeMove) == "function" then BeginHealerSafeMove(self, "healer_boot_launcher", true) else self:StartMoving() end
	self.moving = true
	return true
end)

ReplicatedHealerBoot.button:SetHandler("OnDragStop", function(self)
	if type(EndHealerSafeMove) == "function" then EndHealerSafeMove(self) else self:StopMovingOrSizing() end
	self.moving = false
end)

ReplicatedHealerBoot.button:SetHandler("OnClick", function()
	if ReplicatedHealerBoot.openSettings ~= nil then
		ReplicatedHealerBoot.openSettings()
		return
	end
	if ReplicatedHealerBoot.error ~= nil then
		SafeChat("Replicated 治疗推荐器核心初始化失败：" .. tostring(ReplicatedHealerBoot.error))
		return
	end
	SafeChat("Replicated 治疗推荐器按钮已加载，但核心脚本尚未完成加载。请检查 replicatedhealer_core1/2.lua 是否在 toc.g 中。")
end)
else
	-- Suite left navigation replaces the historical bootstrap launcher.
	ReplicatedHealerBoot.button = nil
	ReplicatedHealerBoot.createError = nil
	ReplicatedHealerBoot.launcherVisible = false
end
