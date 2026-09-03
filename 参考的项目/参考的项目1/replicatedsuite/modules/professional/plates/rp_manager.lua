ReplicatedSuiteModuleSandbox:Enter('plates', {'ReplicatedPlates'})
------------------------------------------------------------------------
-- Replicated Plates - v0.4.7 PvP status V6 + important item cooldowns
-- V5 expands current RU 10.0/Ancestral PvP states, Songcraft/Vitalism/Spelldance
-- compatibility, and session auto-recognition for database gaps such as Communication.
------------------------------------------------------------------------
if ReplicatedPlates == nil or ReplicatedPlates.BootError ~= nil or ReplicatedPlates.Api == nil or ReplicatedPlates.Storage == nil or ReplicatedPlates.UI == nil then return end
local P, A, S, U = ReplicatedPlates, ReplicatedPlates.Api, ReplicatedPlates.Storage, ReplicatedPlates.UI
local generation = P.Generation
local settings = S:Get()

P.Manager = {
    windows = {}, catalog = {}, trackedRows = {}, liveRows = {},
    activePage = { tracked = 1, live = 1 },
    runtimePolls = 0, catalogRawCount = nil,
    frozen = false, frozenScope = nil, frozenEffect = nil,
    -- Session discovery watches the real RU client's current aura ids even while
    -- this manager is closed. It is intentionally NOT persisted and never
    -- auto-tracks entries: users decide which observed effects are worth showing.
    discovered = {
        target = { buff = {}, debuff = {}, hidden = {} },
        player = { buff = {}, debuff = {}, hidden = {} },
    },
    discoveryCursor = {
        target = { buff = 1, debuff = 1, hidden = 1 },
        player = { buff = 1, debuff = 1, hidden = 1 },
    },
    discoverySerial = 0,
    discoveryPhase = 0,
    discoveryCap = 192,
    -- Explicit user capture session used by the Suite tracking page.  Unlike
    -- ordinary live rows, the sticky queue retains short-lived auras long
    -- enough for the user to inspect/track them. Nothing here is persisted.
    capture = {
        enabled = false, sticky = true, scope = "target", effectType = "buff",
        cursor = 1, serial = 0, cap = 256, deepAllowed = true,
        buckets = {
            target = { buff = {}, debuff = {}, hidden = {} },
            player = { buff = {}, debuff = {}, hidden = {} },
        },
    },
    catalogMode = "live",
    categoryFilter = "ALL",
    -- Session-only staging for RPPLATESAURA3 chunked transfers. Chunks never
    -- mutate persistent state until the complete batch passes checksum/shape
    -- validation and the user explicitly confirms the import.
    auraImportStage = nil,
}
local M = P.Manager

local function ModuleRuntimeEnabled()
    if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.ModuleManager ~= nil then
        return ReplicatedSuite.ModuleManager:IsEnabled("plates")
    end
    return P.Runtime == nil or P.Runtime.running ~= false
end

local SCOPE_META = {
    target = { title = "目标", unit = "target" },
    player = { title = "自己", unit = "player" },
}
local EFFECT_META = {
    buff = { title = "Buff", accent = { 0.24, 0.82, 0.44 } },
    debuff = { title = "Debuff", accent = { 0.96, 0.30, 0.28 } },
    hidden = { title = "Hidden", accent = { 0.72, 0.38, 0.94 } },
}

local CATEGORY_META = {
    ALL = { title = "全部" },
    HARD_CC = { title = "硬控" },
    SOFT_CC = { title = "软控" },
    IMMUNITY = { title = "免控" },
    BREAK = { title = "破防" },
    HEAL_REDUCE = { title = "减疗" },
    HEAL = { title = "治疗" },
    DEFENSE = { title = "保命" },
    BURST = { title = "爆发" },
    EQUIP = { title = "装备" },
    MOBILITY = { title = "机动/禁飞" },
    COMBO = { title = "Combo" },
    HIDDEN = { title = "Hidden" },
    OTHER = { title = "其他" },
}
local CATEGORY_ORDER = { "ALL", "HARD_CC", "SOFT_CC", "IMMUNITY", "BREAK", "HEAL_REDUCE", "HEAL", "DEFENSE", "BURST", "EQUIP", "MOBILITY", "COMBO", "HIDDEN", "OTHER" }

local function ContainsAny(text, words)
    text = tostring(text or "")
    local lowered = string.lower(text)
    for _, word in ipairs(words or {}) do
        word = tostring(word or "")
        if word ~= "" and (string.find(lowered, string.lower(word), 1, true) ~= nil or string.find(text, word, 1, true) ~= nil) then return true end
    end
    return false
end

-- Classification uses the current client's localized tooltip whenever available.
-- Chinese UI therefore does not depend on our English fallback labels. Explicit
-- preset categories win because several ArcheAge effects have misleading names
-- (e.g. an "immunity limit" is a debuff, not an immunity buff).
local function ClassifyCombatEffect(effectType, name, description, explicit)
    if explicit ~= nil and explicit ~= "" then return tostring(explicit) end
    if effectType == "hidden" then return "HIDDEN" end
    local text = tostring(name or "") .. " " .. tostring(description or "")

    if effectType == "debuff" then
        if ContainsAny(text,{"装备禁用","禁用左手","禁用右手","禁用主手","禁用副手","禁用乐器","缴械","disable left-hand","disable right-hand","disable instrument","equipment disable","disarm"}) then return "EQUIP" end
        if ContainsAny(text,{"滑翔翼","翅膀","禁飞","无法使用滑翔","无法使用翅膀","湍流","整备中","突进中","glider","wings","turbulence","preparing glider","unable to use gliders","unable to use the glider"}) then return "MOBILITY" end
        if ContainsAny(text,{"受到治疗降低","治疗效果降低","治疗效率降低","治疗量降低","无法治疗","减疗","reduces received healing","decreased received healing","received healing -","healing effectiveness -"}) then return "HEAL_REDUCE" end
        if ContainsAny(text,{"下防","破甲","物理防御降低","魔法防御降低","双防降低","易伤","防御消除","armor destroyer","defense elimination","broken armor","corrosion","exposed weakness","decreases physical defense","decreases magic defense","stalker's mark","defenseless"}) then return "BREAK" end
        if ContainsAny(text,{"眩晕","倒地","穿刺","枪刺","审判之枪","恐惧","睡眠","泡泡","石化","念力","深度冰冻","浮空","击飞","麻痹","魅惑","昏迷","强制睡眠","深度睡眠","stun","tripped","trip","impale","skewer","fear","sleep","bubble","petrif","telekinesis","deep freeze","levitate","launched","paraly","charm"}) then return "HARD_CC" end
        if ContainsAny(text,{"定身","束缚","禁锢","减速","沉默","致盲","嘲讽","挑衅","虚弱","震慑","失衡","套索","拉拽","牵引","打断","无法转身","命中降低","移动速度降低","攻击速度降低","施法速度降低","root","snare","shackle","slow","silence","blind","taunt","provok","shaken","distressed","lasso","interrupt","accuracy reduction","move speed reduction","wraith's curse","crippling mire","enervated"}) then return "SOFT_CC" end
        if ContainsAny(text,{"燃烧","冰冻","感电","流血","诅咒","标记","中毒","burn","frozen","electric shock","bleed","curse","mark","poison","combustion","shock"}) then return "COMBO" end
        return "OTHER"
    end

    if ContainsAny(text,{"免控","控制免疫","免疫控制","免疫眩晕","免疫倒地","免疫恐惧","免疫睡眠","免疫沉默","免疫束缚","免疫穿刺","免疫泡泡","免疫念力","免疫浮空","负面效果免疫","debuff immunity","immunity","immune to","defiance","freedom","liberation","unbreakable will"}) then return "IMMUNITY" end
    if ContainsAny(text,{"回春","治疗","恢复生命","生命恢复","受到治疗提高","治疗力","治愈","持续恢复","生机泉涌","光辉祷言","光辉祷言：生命","生命乐章","生命颂歌","治愈乐章","治愈之歌","resurgence","renewal","mend","mend: life","healing circle","ode to recovery","fervent healing","healing power","received healing +","regeneration","self-heal","divine touch","over healing","toughen","revitalizing cheer","blessing","prayer"}) then return "HEAL" end
    if ContainsAny(text,{"无敌","护盾","防御","格挡","闪避","伤害减免","伤害免疫","保护","魔法免疫","物理免疫","大地乐章","大地颂歌","防御乐章","invincib","shield","redoubt","protective","warding","evasion","ranged defense","bulwark ballad","absorb physical damage","close protection","damage reduction"}) then return "DEFENSE" end
    if ContainsAny(text,{"爆发","攻击速度","施法速度","攻击力","暴击","穿透","战斗专注","狂暴","轻舞乐章","轻快步伐","英雄进行曲","血之赞歌","血之颂歌","attack speed","casting speed","all attacks","battle focus","frenzy","deadeye","zeal","bloodthirst","freerunner","double recurve","quickstep","bloody chantey","deadly refrain","uptempo","morale boost"}) then return "BURST" end
    if ContainsAny(text,{"燃烧","冰冻","感电","流血","诅咒","标记","中毒","交感","极效交感","burn","frozen","electric shock","bleed","curse","mark","poison","combustion","communication","communication maximization"}) then return "COMBO" end
    return "OTHER"
end

local function CategoryTitle(category)
    local meta = CATEGORY_META[tostring(category or "OTHER")] or CATEGORY_META.OTHER
    return meta.title
end

local function SafeHandler(widget, eventName, fn, label)
    if widget == nil or type(widget.SetHandler) ~= "function" then return end
    widget:SetHandler(eventName, function(...)
        if P.Generation ~= generation then return nil end
        local args = { ... }
        local argCount = select("#", ...)
        local ok, result = xpcall(function() return fn(unpack(args, 1, argCount)) end, P.SafeTraceback)
        if not ok then P.SafeChat("管理器 UI 错误 " .. tostring(label or eventName) .. "：" .. tostring(result)); return nil end
        return result
    end)
end

local function SetPick(widget, enabled)
    if widget == nil then return end
    if widget.Enable ~= nil then pcall(function() widget:Enable(true) end) end
    if widget.EnablePick ~= nil then pcall(function() widget:EnablePick(enabled == true, true) end) end
    if widget.Clickable ~= nil then pcall(function() widget:Clickable(enabled == true, true) end) end
end

local function CreateBackground(parent, r, g, b, a, layer)
    local bg = parent:CreateColorDrawable(r, g, b, a, layer or "background")
    bg:AddAnchor("TOPLEFT", parent, 0, 0); bg:AddAnchor("BOTTOMRIGHT", parent, 0, 0)
    return bg
end

local function Label(parent, id, text, x, y, width, height, size, align)
    local w = parent:CreateChildWidget("label", P.PhysicalId(id), 0, true)
    w:AddAnchor("TOPLEFT", parent, x, y); w:SetExtent(width, height)
    if w.SetAutoResize ~= nil then w:SetAutoResize(false) end
    w.style:SetFontSize(size or 10); w.style:SetAlign(align or ALIGN_LEFT); w.style:SetColor(0.94, 0.95, 0.97, 1)
    if w.style.SetOutline ~= nil then w.style:SetOutline(true) end
    if w.style.SetEllipsis ~= nil then pcall(function() w.style:SetEllipsis(false) end) end
    if w.EnablePick ~= nil then w:EnablePick(false) end
    w:SetText(tostring(text or "")); w:Show(true)
    return w
end

local function StyleButton(button, width, height, size)
    local colors = { {0.07,0.14,0.21,0.99}, {0.14,0.29,0.43,0.99}, {0.035,0.08,0.13,0.99}, {0.07,0.08,0.10,0.75} }
    button.rpStates = button.rpStates or {}
    if #button.rpStates == 0 then
        for i = 1, 4 do
            local c = colors[i]; local bg = button:CreateColorDrawable(c[1],c[2],c[3],c[4],"background")
            bg:AddAnchor("TOPLEFT", button, 0, 0); bg:AddAnchor("BOTTOMRIGHT", button, 0, 0); button.rpStates[i] = bg
        end
        if button.SetNormalBackground ~= nil then
            button:SetNormalBackground(button.rpStates[1]); button:SetHighlightBackground(button.rpStates[2]); button:SetPushedBackground(button.rpStates[3]); button:SetDisabledBackground(button.rpStates[4])
        end
    end
    if button.SetAutoResize ~= nil then button:SetAutoResize(false) end
    button:SetExtent(width, height)
    if button.style ~= nil then button.style:SetFontSize(size or 9); button.style:SetColor(0.96,0.94,0.89,1) end
end

local function Button(parent, id, text, x, y, width, height, size)
    local w = parent:CreateChildWidget("button", P.PhysicalId(id), 0, true)
    w:SetText(text or ""); StyleButton(w, width or 80, height or 24, size); w:AddAnchor("TOPLEFT", parent, x, y); SetPick(w, true); w:Show(true); return w
end

local function Window(id, width, height, bucket)
    local pos = settings[bucket]
    local w = CreateEmptyWindow(P.PhysicalId(id), "UIParent")
    w:SetExtent(width, height); w:AddAnchor("TOPLEFT", "UIParent", pos.x, pos.y); if w.CorrectOffsetByScreen ~= nil then pcall(function() w:CorrectOffsetByScreen() end) end; w:Show(false); SetPick(w, true)
    if w.SetUILayer ~= nil then pcall(function() w:SetUILayer("system") end) end
    CreateBackground(w, 0.014, 0.024, 0.038, 0.995, "background")
    local header = w:CreateChildWidget("emptywidget", P.PhysicalId(id .. "_header"), 0, true)
    header:AddAnchor("TOPLEFT", w, 0, 0); header:SetExtent(width, 40); SetPick(header, true); CreateBackground(header, 0.050, 0.12, 0.19, 1, "background")
    local line = header:CreateColorDrawable(0.20,0.58,0.88,1,"artwork"); line:AddAnchor("BOTTOMLEFT", header, 0, 0); line:SetExtent(width, 2)
    if header.EnableDrag ~= nil then
        header:EnableDrag(true)
        local dragKey = "plates_manager_" .. tostring(id)
        SafeHandler(header, "OnDragStart", function(self)
            self.rpSafeMoving = false
            if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
                and type(ReplicatedSuite.Layout.BeginSafeMove) == "function" then
                local ok, moved = pcall(function()
                    return ReplicatedSuite.Layout:BeginSafeMove(dragKey, w, { clamp = true })
                end)
                self.rpSafeMoving = ok and moved == true
            end
            if self.rpSafeMoving ~= true and type(w.StartMoving) == "function" then w:StartMoving() end
            return true
        end, id .. ":drag_start")
        SafeHandler(header, "OnDragStop", function(self)
            if self.rpSafeMoving == true and ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
                and type(ReplicatedSuite.Layout.EndSafeMove) == "function" then
                pcall(function() ReplicatedSuite.Layout:EndSafeMove(dragKey, false) end)
            elseif type(w.StopMovingOrSizing) == "function" then
                w:StopMovingOrSizing()
            end
            self.rpSafeMoving = false
            if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
                and type(ReplicatedSuite.Layout.EnsureWidgetVisible) == "function" then
                pcall(function() ReplicatedSuite.Layout:EnsureWidgetVisible(w, { onlyWhenVisible = true, fitSize = true }) end)
            elseif w.CorrectOffsetByScreen ~= nil then
                pcall(function() w:CorrectOffsetByScreen() end)
            end
            local x,y=nil,nil
            if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
                and type(ReplicatedSuite.Layout.GetLogicalRect) == "function" then
                local ok,lx,ly=pcall(function() return ReplicatedSuite.Layout:GetLogicalRect(w) end)
                if ok then x,y=tonumber(lx),tonumber(ly) end
            end
            if (x==nil or y==nil) and type(w.GetOffset)=="function" then
                local ok,ox,oy=pcall(function() return w:GetOffset() end)
                if ok then x,y=tonumber(ox),tonumber(oy) end
            end
            if x~=nil and y~=nil then
                local savedOk,savedErr=S:UpdatePosition(bucket,x,y)
                if not savedOk then
                    P.SafeChat("保存窗口位置失败："..tostring(savedErr or "unknown"))
                    local saved=S:Get()[bucket]
                    if type(saved)=="table" and type(w.RemoveAllAnchors)=="function" then w:RemoveAllAnchors();w:AddAnchor("TOPLEFT","UIParent",saved.x,saved.y) end
                end
            end
            return true
        end, id .. ":drag_stop")
    end
    if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.Layout ~= nil
        and type(ReplicatedSuite.Layout.RegisterFloating) == "function" then
        ReplicatedSuite.Layout:RegisterFloating("plates_manager_" .. tostring(id), w, {
            onlyWhenVisible = true, ensureNow = false, fitSize = true,
        })
    end
    -- Every Plates detail/manager window uses the same native bottom-right
    -- resize path as the game's own resizable windows. Contents keep their
    -- current anchors; resizing mainly gives the user more breathing room.
    if type(w.StartSizing) == "function" then
        if w.UseResizing ~= nil then pcall(function() w:UseResizing(true) end) end
        if w.SetMinResizingExtent ~= nil then pcall(function() w:SetMinResizingExtent(width, height) end) end
        if w.SetMaxResizingExtent ~= nil then pcall(function() w:SetMaxResizingExtent(width + 420, height + 500) end) end
        local grip=w:CreateChildWidget("emptywidget",P.PhysicalId(id.."_resize_grip"),0,true)
        grip:SetExtent(22,22);grip:AddAnchor("BOTTOMRIGHT",w,-2,-2);SetPick(grip,true)
        local mark=Label(grip,id.."_resize_mark","拖",0,0,20,20,10,ALIGN_CENTER);mark.style:SetColor(0.58,0.78,0.94,0.90)
        if grip.EnableDrag~=nil then grip:EnableDrag(true) end
        SafeHandler(grip,"OnDragStart",function() w:StartSizing("BOTTOMRIGHT");return true end,id..":resize_start")
        SafeHandler(grip,"OnDragStop",function()
            if type(w.StopMovingOrSizing)=="function" then w:StopMovingOrSizing() end
            if w.CorrectOffsetByScreen~=nil then pcall(function() w:CorrectOffsetByScreen() end) end
            return true
        end,id..":resize_stop")
    end
    return w, header
end

local function EditBox(parent, id, x, y, width)
    if UOT_X2_EDITBOX == nil or parent == nil or type(parent.CreateChildWidgetByType) ~= "function" then return nil end
    local ok,edit=pcall(function() return parent:CreateChildWidgetByType(UOT_X2_EDITBOX,P.PhysicalId(id),0,true) end)
    if not ok or edit==nil or type(edit.SetExtent)~="function" or type(edit.AddAnchor)~="function" or edit.style==nil then return nil end
    local configured=pcall(function()
        -- Match Replicated Gear's RU-proven input path. In particular, do not
        -- call SetDigit/SetDigitMax or generic CreateDrawable("editbox_df"):
        -- either can invalidate the whole widget on this client build.
        edit:SetExtent(width,26)
        if edit.SetInset~=nil then edit:SetInset(5,5,5,5) end
        if edit.EnableFocus~=nil then edit:EnableFocus(true) end
        if edit.UseSelectAllWhenFocused~=nil then edit:UseSelectAllWhenFocused(true) end
        if edit.SetMaxTextLength~=nil then edit:SetMaxTextLength(12) end
        edit.style:SetAlign(ALIGN_LEFT)
        edit.style:SetColor(1.00,0.96,0.84,1.00)
        local border=edit:CreateColorDrawable(0.34,0.43,0.52,0.98,"background")
        if border~=nil and border.AddAnchor~=nil then border:AddAnchor("TOPLEFT",edit,0,0);border:AddAnchor("BOTTOMRIGHT",edit,0,0) end
        local bg=edit:CreateColorDrawable(0.015,0.022,0.032,0.995,"background")
        if bg~=nil and bg.AddAnchor~=nil then bg:AddAnchor("TOPLEFT",edit,1,1);bg:AddAnchor("BOTTOMRIGHT",edit,-1,-1) end
        edit:AddAnchor("TOPLEFT",parent,x,y)
        edit:Show(true)
    end)
    if not configured then return nil end
    return edit
end

local function MultiEdit(parent, id, x, y, width, height)
    if UOT_EDITBOX_MULTILINE == nil or parent == nil or type(parent.CreateChildWidgetByType) ~= "function" then return nil end
    local ok,edit=pcall(function() return parent:CreateChildWidgetByType(UOT_EDITBOX_MULTILINE,P.PhysicalId(id),0,true) end)
    if not ok or edit==nil or type(edit.SetExtent)~="function" or type(edit.AddAnchor)~="function" then return nil end
    local configured=pcall(function()
        edit:SetExtent(width,height)
        if edit.SetInset~=nil then edit:SetInset(10,10,15,10) end
        if edit.EnableFocus~=nil then edit:EnableFocus(true) end
        if edit.SetMaxTextLength~=nil then edit:SetMaxTextLength(65535) end
        if edit.style~=nil then edit.style:SetAlign(ALIGN_TOP_LEFT);edit.style:SetColor(1,1,1,1);edit.style:SetFontSize(10) end
        if edit.guideTextStyle~=nil then edit.guideTextStyle:SetAlign(ALIGN_TOP_LEFT) end
        local border=edit:CreateColorDrawable(0.34,0.43,0.52,0.98,"background")
        if border~=nil and border.AddAnchor~=nil then border:AddAnchor("TOPLEFT",edit,0,0);border:AddAnchor("BOTTOMRIGHT",edit,0,0) end
        local bg=edit:CreateColorDrawable(0.012,0.020,0.030,0.995,"background")
        if bg~=nil and bg.AddAnchor~=nil then bg:AddAnchor("TOPLEFT",edit,1,1);bg:AddAnchor("BOTTOMRIGHT",edit,-1,-1) end
        edit:AddAnchor("TOPLEFT",parent,x,y)
        edit:Show(true)
    end)
    if not configured then return nil end
    return edit
end

local function SetIcon(row, path)
    path = type(path) == "string" and path or ""
    if row.iconPath == path then return end
    row.iconPath = path
    row.icon:ClearAllTextures()
    if path == "" then row.icon:SetVisible(false); return end
    row.icon:AddTexture(path); row.icon:SetVisible(true)
end

local function Active()
    local m = S:Get().manager
    local scope, effect = m.activeScope, m.activeEffect
    if scope ~= "target" and scope ~= "player" then scope = "target" end
    if S:Get().tracking[scope] == nil or S:Get().tracking[scope][effect] == nil then scope, effect = "target", "buff" end
    return scope, effect
end

local function SaveActive(scope, effect)
    local m = S:Get().manager
    if S:Get().tracking[scope] == nil or S:Get().tracking[scope][effect] == nil then return false end
    local oldScope, oldEffect, oldDirty = m.activeScope, m.activeEffect, S.dirty
    m.activeScope, m.activeEffect = scope, effect
    S:MarkDirty()
    local ok, err = S:Save(true)
    if not ok then
        m.activeScope, m.activeEffect, S.dirty = oldScope, oldEffect, oldDirty
        P.SafeChat("保存管理器分类失败：" .. tostring(err or "unknown"))
        return false
    end
    M.activePage.tracked, M.activePage.live = 1, 1
    M.catalogMode = "live"
    M.categoryFilter = "ALL"
    return true
end

local function SortedTracked(scope, effect)
    local result = {}
    for id, entry in pairs(S:GetTracked(scope, effect)) do
        local copy = {}
        copy.id=tostring(id); copy.name=tostring(entry.name or ""); copy.iconPath=tostring(entry.iconPath or ""); copy.category=tostring(entry.category or "")
        -- CopyRuleEntry is declared later for package V2. Preserve advanced
        -- fields here as well so SortedTracked remains self-contained.
        copy.customName=tostring(entry.customName or ""); copy.enabled=entry.enabled~=false; copy.priority=tonumber(entry.priority) or 0
        copy.showDuration=entry.showDuration; copy.showStack=entry.showStack; copy.showBorder=entry.showBorder; copy.showTooltip=entry.showTooltip; copy.iconSize=entry.iconSize
        copy.expireEnabled=entry.expireEnabled; copy.expireThreshold=entry.expireThreshold; copy.borderColor=entry.borderColor; copy.expireColor=entry.expireColor
        result[#result+1] = copy
    end
    table.sort(result, function(a,b)
        local an,bn=tostring(a and a.name or ""),tostring(b and b.name or "")
        if an==bn then
            local ai,bi=tonumber(a and a.id),tonumber(b and b.id)
            if ai~=nil and bi~=nil and ai~=bi then return ai<bi end
            return tostring(a and a.id or "")<tostring(b and b.id or "")
        end
        return an<bn
    end)
    return result
end

local function Escape(text)
    return (tostring(text or ""):gsub("%%","%%25"):gsub("|","%%7C"):gsub(";","%%3B"):gsub("~","%%7E"):gsub("\n","%%0A"))
end
local function Unescape(text)
    return (tostring(text or ""):gsub("%%0A","\n"):gsub("%%7E","~"):gsub("%%3B",";"):gsub("%%7C","|"):gsub("%%25","%%"))
end

local function BuildExport(scope, effect)
    local parts = { "RPPLATES1", scope, effect }
    for _, entry in ipairs(SortedTracked(scope,effect)) do
        parts[#parts+1] = entry.id .. "~" .. Escape(entry.name) .. "~" .. Escape(entry.iconPath) .. "~" .. Escape(entry.category)
    end
    return table.concat(parts, "|")
end

local function DecodeImport(text, expectedScope, expectedEffect)
    local parts = {}
    for part in (tostring(text or "") .. "|"):gmatch("(.-)|") do parts[#parts+1] = part end
    if parts[1] ~= "RPPLATES1" or parts[2] ~= expectedScope or parts[3] ~= expectedEffect then return nil, "格式或分类不匹配" end
    local result = {}
    for i=4,#parts do
        local id,name,icon,category = parts[i]:match("^(%d+)~(.-)~(.-)~(.*)$")
        if id == nil then id,name,icon = parts[i]:match("^(%d+)~(.-)~(.*)$") end
        if id ~= nil then
            local decodedName=Unescape(name)
            local decodedCategory=category~=nil and Unescape(category) or ""
            result[id] = {
                name=decodedName,
                iconPath=Unescape(icon),
                category=decodedCategory~="" and decodedCategory or ClassifyCombatEffect(expectedEffect,decodedName,"",nil),
            }
        end
    end
    return result
end

function M:ExportActive()
    local scope,effect=Active();return BuildExport(scope,effect)
end

function M:ImportActive(text)
    local scope,effect=Active();local decoded,err=DecodeImport(text,scope,effect)
    if decoded==nil then return false,err end
    local ok,saveErr=S:ReplaceTracked(scope,effect,decoded)
    if not ok then return false,saveErr end
    if P.Runtime and P.Runtime.ForceScope then P.Runtime:ForceScope(scope) end
    return true
end

local function BuildExportAll()
    local parts={"RPPLATESALL1"}
    for _,scope in ipairs({"target","player"}) do
        for _,effect in ipairs({"buff","debuff","hidden"}) do
            if type(S:Get().tracking[scope])=="table" and type(S:Get().tracking[scope][effect])=="table" then
                for _,entry in ipairs(SortedTracked(scope,effect)) do
                    parts[#parts+1]=Escape(scope).."~"..Escape(effect).."~"..entry.id.."~"..Escape(entry.name).."~"..Escape(entry.iconPath).."~"..Escape(entry.category)
                end
            end
        end
    end
    local raw = table.concat(parts,"|")
    -- Wrap every 110 chars (report plan D-3). Note: "{110}" is not a Lua
    -- pattern quantifier, so a gsub("(.{110})","%1\n") would silently no-op;
    -- chunked concat implements the same semantics (every 110 chars + one
    -- trailing newline when len % 110 == 0). The import side strips raw
    -- CR/LF/TAB in NormalizeImportText and names escape literal newlines as
    -- %0A, so plain \n separators are safe; the export payload is pure ASCII.
    local chunks = {}
    for i = 1, #raw, 110 do
        chunks[#chunks + 1] = raw:sub(i, i + 109)
    end
    local wrapped = table.concat(chunks, "\n")
    if #raw > 0 and #raw % 110 == 0 then wrapped = wrapped .. "\n" end
    return wrapped
end


local CORE_PRESET_TOKEN_V1="RPPLATESPRESET1|RU_CORE_V1"
local CORE_PRESET_TOKEN_V2="RPPLATESPRESET1|RU_CORE_V2"
local CORE_PRESET_TOKEN_V3="RPPLATESPRESET1|RU_CORE_V3"
local CORE_PRESET_TOKEN_V4="RPPLATESPRESET1|RU_CORE_V4"
local CORE_PRESET_TOKEN_V5="RPPLATESPRESET1|RU_CORE_V5"
local CORE_PRESET_TOKEN_V6="RPPLATESPRESET1|RU_CORE_V6"
local CORE_PRESET_TOKEN="RPPLATESPRESET1|RU_CORE_V7"
local CORE_PRESET={
    buff={
        {"22968","Defiance"},
        {"131","无敌"},
        {"499","勇气免控"},
        {"507","Shrug It Off"},
        {"417","沉默免疫"},
        {"2160","泡泡免疫"},
        {"2161","念力免疫"},
        {"2162","浮空免疫"},
        {"29346","控制免疫"},
        -- 10.0 / Ancestral equipment-disable immunity and Swiftblade self buffs.
        {"24748","装备禁用免疫"},
        {"32795","Primal Strike生命"},
        {"31544","Primal Strike波涛"},
        -- Current player defensive/support buffs that are important in real fights.
        {"258","Protective Wings"},
        {"328","Redoubt"},
        {"21406","Redoubt疾风"},
        {"21407","Redoubt疾风"},
        {"28116","Redoubt岩石"},
        {"28118","Redoubt岩石"},
        {"26959","Redoubt生命"},
        {"21372","Redoubt生命"},
        {"24986","近身保护"},
        {"855","转化护盾R3"},
        {"857","转化护盾R5"},
        {"21375","火焰转化护盾"},
        {"13619","魔法护盾"},
        {"28187","岩石转化护盾"},
        {"95","魔法防护罩"},
        {"7010","镜像位移"},
        {"24947","闪现"},
        {"24610","闪现"},
        {"25694","闪现潜行"},
        {"220","回春"},
        {"17417","回春"},
        {"552","Blessing / 受治疗提高"},
        {"17925","Renewal"},
        {"3655","Mend"},
        {"15053","Prayer"},
        {"18390","Fervent Healing闪电"},
        -- Defense self-healing / received-healing buffs.
        {"445","Toughen"},
        {"446","Toughen"},
        {"447","Toughen"},
        {"448","Toughen"},
        {"13627","Toughen"},
        {"13628","Toughen"},
        {"21976","Toughen"},
        {"24987","Revitalizing Cheer"},
        {"841","Health Lift"},
        {"16088","Invigorated Healing"},
        {"25401","Revitalizing Cheer生命"},
        {"25402","Revitalizing Cheer波涛"},
        {"28186","Revitalizing Cheer岩石"},
        -- Healing-over-time / healing-area / song effects.
        {"780","Healing Circle"},
        {"662","Ode to Recovery R1"},
        {"663","Ode to Recovery R3"},
        {"664","Ode to Recovery R2"},
        {"2190","Ode to Recovery R1"},
        {"2191","Ode to Recovery R2"},
        {"2192","Ode to Recovery R3"},
        {"13785","Ode to Recovery R5"},
        {"13786","Ode to Recovery R4"},
        {"13787","Ode to Recovery R4"},
        {"13788","Ode to Recovery R5"},
        {"16870","Mana Barrier"},
        {"17339","Infuse"},
        {"30098","牺牲之舞"},
        {"30137","牺牲之舞"},
        {"30141","牺牲之舞"},
        {"30142","牺牲之舞"},
        {"340","Freerunner"},
        {"13779","Freerunner"},
        {"13780","Freerunner"},
        {"13781","Freerunner"},
        {"404","Battle Focus"},
        {"7651","Battle Focus"},
        {"13612","Battle Focus"},
        {"13613","Battle Focus"},
        {"182","Frenzy"},
        {"7543","Reckless Charge"},
        {"127","Warding Light"},
        -- V4: broader player-combat immunities / healing / defensive and burst states.
        {"374","Awakening / 觉醒","COMBO"},
        {"375","Purge / 净化","HEAL"},
        {"400","Sleep Immunity","IMMUNITY"},
        {"468","Liberation","IMMUNITY"},
        {"475","Combustion Immunity","IMMUNITY"},
        {"476","Electric Shock Immunity","IMMUNITY"},
        {"478","Healing Area","HEAL"},
        {"484","Ranged Defense","DEFENSE"},
        {"495","Zeal","BURST"},
        {"496","物理伤害吸收","DEFENSE"},
        {"513","Consecutive Evasion","DEFENSE"},
        {"529","Divine Touch","HEAL"},
        {"534","Reprisal","DEFENSE"},
        {"542","Pain Harvest","DEFENSE"},
        {"602","Sleep Immunity","IMMUNITY"},
        {"608","Burn Immunity","IMMUNITY"},
        {"611","Freed from Shackling","IMMUNITY"},
        {"765","Morale Boost","BURST"},
        {"773","Indignant Guard","DEFENSE"},
        {"781","Uptempo","BURST"},
        {"839","Berserk","BURST"},
        {"870","Bloodthirst","BURST"},
        {"871","Charged Bloodthirst","BURST"},
        {"919","Trip Immunity","IMMUNITY"},
        {"920","Float Immunity","IMMUNITY"},
        {"921","Stun Immunity","IMMUNITY"},
        {"942","Poisoning Immunity","IMMUNITY"},
        {"1606","Immune to Trip","IMMUNITY"},
        {"2164","Leech Immunity","IMMUNITY"},
        {"2170","Deadeye R1","BURST"},
        {"2172","Deadeye R2","BURST"},
        {"2173","Deadeye R3","BURST"},
        {"2175","Deadeye R4","BURST"},
        {"2740","Invincibility","DEFENSE"},
        {"3568","Renewal R1","HEAL"},
        {"3569","Renewal R2","HEAL"},
        {"3570","Gradual Recovery R1","HEAL"},
        {"3571","Gradual Recovery R2","HEAL"},
        {"4239","Sleep Immunity","IMMUNITY"},
        {"4252","Pain Harvest","DEFENSE"},
        {"5004","Trip Immunity","IMMUNITY"},
        {"5005","Fear Immunity","IMMUNITY"},
        {"5006","Incapacitating Effects Immunity","IMMUNITY"},
        {"5007","Impale Immunity","IMMUNITY"},
        {"5008","Shackle Immunity","IMMUNITY"},
        {"5019","Fervent Healing R1","HEAL"},
        {"5021","Enhanced Fervent Healing","HEAL"},
        {"5022","Fervent Healing R2","HEAL"},
        {"5174","Stun Immunity","IMMUNITY"},
        {"5176","Sleep Immunity","IMMUNITY"},
        {"5177","Silence Immunity","IMMUNITY"},
        {"5178","Freedom","IMMUNITY"},
        {"5179","Shackle Immunity","IMMUNITY"},
        {"16182","Healing Power提高","HEAL"},
        {"17386","Hand of Salvation","DEFENSE"},
        {"23245","Healing Power叠层","HEAL"},
        {"23965","Over Healing","HEAL"},
        {"26069","Deadeye","BURST"},
        {"32505","Grasping Void Immunity","IMMUNITY"},
        {"8000228","Debuff Immunity","IMMUNITY"},
        {"8000229","Debuff Immunity","IMMUNITY"},
        {"8000647","Airborne Immunity","IMMUNITY"},
        {"8000651","Unbreakable Will","IMMUNITY"},
        {"8000654","Whirlwind Immunity","IMMUNITY"},
    },
    debuff={
        {"7","倒地"},
        {"21","倒地"},
        {"206","封印/缴械"},
        {"240","减速"},
        {"243","眩晕"},
        {"245","沉默"},
        {"247","冻伤"},
        {"248","冰冻"},
        {"253","浮空"},
        {"414","深度睡眠"},
        {"439","穿刺"},
        {"441","倒地"},
        {"443","眩晕"},
        {"449","催眠"},
        {"1832","石化"},
        {"1865","定身"},
        {"2107","眩晕"},
        {"2275","Lassitude"},
        {"2276","睡眠"},
        {"2458","定身"},
        {"2463","Dazed"},
        {"2464","旋风倒地"},
        {"2465","倒地"},
        {"156","恐惧"},
        {"2277","恐惧"},
        {"28250","深渊恐惧"},
        {"28252","深渊恐惧"},
        {"26977","闪现恐惧"},
        {"96","泡泡"},
        {"2286","泡泡"},
        {"21399","泡泡"},
        {"21400","泡泡"},
        {"21401","泡泡"},
        {"28256","深渊泡泡"},
        {"28257","深渊泡泡"},
        {"23467","强化泡泡"},
        {"21397","Earthen Grip"},
        {"21398","Earthen Grip"},
        {"21402","Banshee Wail"},
        {"21403","Banshee Wail"},
        {"21404","Phantasm Wail"},
        {"21405","Phantasm Wail"},
        {"21421","石化"},
        {"21432","魅惑"},
        {"21434","魅惑"},
        {"23430","石化"},
        {"2745","Enervated"},
        {"32646","Enervate闪电"},
        {"22909","Enervated Combo / 觉醒限制","COMBO"},
        {"87","Hell Spear"},
        {"32647","Hell Spear震地"},
        {"22532","眩晕"},
        {"21361","眩晕"},
        {"23359","眩晕"},
        {"23818","眩晕"},
        {"25712","眩晕"},
        {"26173","眩晕"},
        {"27279","眩晕"},
        {"27333","眩晕"},
        {"27575","眩晕"},
        {"27707","眩晕"},
        {"27850","眩晕"},
        {"29925","眩晕"},
        {"27631","倒地"},
        {"27632","倒地"},
        {"21381","倒地"},
        {"23127","倒地冲击"},
        {"23351","倒地"},
        {"25739","倒地"},
        {"25824","倒地"},
        {"27191","倒地"},
        {"27198","倒地"},
        {"27248","倒地"},
        {"27381","倒地"},
        {"27697","倒地"},
        {"30065","倒地"},
        {"27693","穿刺"},
        {"25002","浮空"},
        {"27236","浮空"},
        {"27271","深渊麻痹"},
        {"23322","定身"},
        {"23161","定身"},
        {"23832","定身","SOFT_CC"},
        {"25761","定身"},
        {"27315","定身"},
        {"27327","定身"},
        {"23830","禁锢","SOFT_CC"},
        {"25704","禁锢"},
        {"27307","禁锢"},
        {"27339","禁锢"},
        {"27730","禁锢"},
        {"3719","禁锢"},
        {"3187","Shackle"},
        {"6946","Shackle"},
        {"27219","Shackle"},
        {"27696","Shackle"},
        {"26932","减速"},
        {"23962","减速"},
        {"24239","Concussive Arrow岩石减速"},
        {"23092","减速"},
        {"27190","减速","SOFT_CC"},
        {"27192","减速"},
        {"27625","减速"},
        {"27706","减速"},
        {"27720","减速"},
        {"94","Ice Shard"},
        {"2279","Freeze"},
        {"15216","Deep Freeze"},
        {"25232","Freeze"},
        {"22013","沉默"},
        {"23358","沉默"},
        {"23469","沉默"},
        {"25234","沉默"},
        {"25718","沉默"},
        {"27145","沉默","SOFT_CC"},
        {"27345","沉默"},
        {"27681","沉默"},
        {"29926","沉默"},
        {"29987","沉默"},
        {"23353","禁用乐器"},
        {"23066","禁用副手"},
        {"23654","禁用左手/副手"},
        {"23107","禁用主手"},
        {"25717","致盲"},
        {"27231","致盲"},
        {"886","Stalker Mark"},
        {"2445","Stalker Mark"},
        {"2446","Stalker Mark"},
        {"7659","Stalker Mark"},
        {"13777","Stalker Mark"},
        {"13778","Stalker Mark"},
        {"26471","Stalker Mark疾风"},
        {"26472","Stalker Mark火焰"},
        {"18146","物防降低"},
        {"16576","Exposed Weakness"},
        {"2646","Broken Armor / 破甲"},
        {"26628","Defense Elimination / 下防"},
        {"26722","Corrosion / 双防降低"},
        {"265","魔防降低"},
        {"23357","受到治疗降低"},
        {"23360","受到治疗降低"},
        {"25260","受到治疗降低"},
        {"32645","受到治疗降低"},
        {"242","流血"},
        {"514","流血"},
        {"515","流血"},
        {"516","流血"},
        {"517","流血"},
        {"877","Bloodthirst Shock"},
        {"2169","Unpleasant Sensation"},
        {"2188","Unpleasant Sensation"},
        {"2176","Lethargy"},
        {"2197","Lethargy"},
        {"2177","Unguarded"},
        {"2200","Unguarded"},
        {"2174","Weakening Energy"},
        {"2193","Weakening Energy"},
        {"26547","Dissonance"},
        {"26548","Dissonance"},
        {"250","Electric Shock"},
        {"171","Taunt"},
        {"3761","Shaken"},
        {"828","Distressed"},
        {"502","Provoked"},
        {"27238","Shaken"},
        {"25780","恐惧"},
        {"27230","恐惧"},
        {"27351","恐惧"},
        {"31327","睡眠"},
        {"27362","毒性眩晕"},
        {"23637","无敌冷却"},
        {"22552","无敌限制"},
        -- Additional confinement/control families that V1 missed.
        {"551","念力控制"},
        {"1169","竞技场念力"},
        {"1170","竞技场念力拉拽"},
        {"1171","竞技场念力抓取"},
        {"21738","念力控制"},
        {"4286","强力念力"},
        {"770","定身"},
        {"771","魅惑"},
        {"798","麻痹"},
        {"826","束缚"},
        {"114","Lassitude"},
        {"101","Enervated"},
        {"121","Crippling Mire"},
        -- Keep the current player/Ancestral Crippling Mire family together.
        -- The 10.0 Wiki pages for Flame/Gale explicitly say their linked data is
        -- unavailable, so session discovery remains the authority for unknown
        -- RU/custom ids while these verified DB ids seed the practical library.
        {"2133","Crippling Mire"},
        {"2156","Crippling Mire"},
        {"23076","Crippling Mire岩石"},
        {"26473","Crippling Mire继承者"},
        {"26512","Crippling Mire继承者"},
        {"138","倒地"},
        {"141","倒地"},
        {"168","Uppercut"},
        {"193","Hooked"},
        {"202","Thorn Snare"},
        {"537","浮空"},
        {"591","倒地"},
        {"607","击飞"},
        {"2125","Hell Spear"},
        {"2126","Hell Spear"},
        {"2127","Skewer"},
        {"2128","Skewer"},
        {"2129","禁锢"},
        {"2130","禁锢"},
        {"2131","减速"},
        {"2132","减速"},
        {"2138","套索"},
        {"2219","眩晕"},
        {"2223","倒地"},
        {"2228","眩晕"},
        {"2231","倒地"},
        {"18332","恶意束缚"},
        {"18336","缴械"},
        {"18397","冰霜束缚"},
        {"18401","穿刺"},
        {"18508","恶意束缚"},
        {"18509","恶意束缚"},
        {"22995","恶意束缚"},
        {"22996","恶意束缚"},
        -- Additional current player-combat / Ancestral variants found in the live RU 10.0 DB.
        {"23307","Slow","SOFT_CC"},
        {"23361","Flame Hell Spear","HARD_CC"},
        {"23362","Wraith's Curse","SOFT_CC"},
        {"23427","Mist Wraith's Curse","SOFT_CC"},
        {"23474","Penetrating Dark Energy","COMBO"},
        {"23488","Taunted","SOFT_CC"},
        {"23842","Wraith's Curse","SOFT_CC"},
        {"23869","Shackle","SOFT_CC"},
        {"23873","Taunted","SOFT_CC"},
        {"23937","Absorb Lifeforce"},
        {"23958","Stun","HARD_CC"},
        {"23959","Sleep","HARD_CC"},
        {"23961","Stun","HARD_CC"},
        {"23964","Electric Shock","COMBO"},
        {"23986","Stun","HARD_CC"},
        {"31677","Tripped by Sunder Earth","HARD_CC"},
        {"31733","Stun","HARD_CC"},
        {"32689","Fear","HARD_CC"},
        -- V4: armor break / soft-control / combo primers and current combat limitations.
        {"49","Bleeding","COMBO"},
        {"82","Earthen Grip","SOFT_CC"},
        {"93","Freeze","COMBO"},
        {"97","Floating Bubble","HARD_CC"},
        {"102","Blind","SOFT_CC"},
        {"116","Loss of Perception","SOFT_CC"},
        {"129","Armor Destroyer R1","BREAK"},
        {"151","Armor Destroyer R2","BREAK"},
        {"203","Slow Curse","SOFT_CC"},
        {"204","Target Joint: Neck","SOFT_CC"},
        {"205","Target Joint: Arm","SOFT_CC"},
        {"2120","Defenseless","BREAK"},
        {"2124","Enervated","SOFT_CC"},
        {"2153","Shock","COMBO"},
        {"2214","Obscure Vision","SOFT_CC"},
        {"23309","Burning","COMBO"},
        {"23435","Electric Shock","COMBO"},
        {"23436","Electric Shock","COMBO"},
        {"23437","Electric Shock","COMBO"},
        {"23509","Ice Shard","COMBO"},
        {"23523","Silence","SOFT_CC"},
        {"23524","Silence","SOFT_CC"},
        {"23642","Impaled","HARD_CC"},
        {"23663","Armor Destroyer","BREAK"},
        {"23965","Over Healing","HEAL_REDUCE"},
        {"23976","Accuracy Reduction","SOFT_CC"},
        {"24056","Vicious Implosion","SOFT_CC"},
        {"24060","Provoked","SOFT_CC"},
        {"24061","Discord","SOFT_CC"},
        {"24062","Discord","SOFT_CC"},
        {"24116","Ice Cage","HARD_CC"},
        {"25236","Tripped","HARD_CC"},
        {"25239","Bubble Trap","HARD_CC"},
        {"25255","Petrification","HARD_CC"},
        {"25285","Silenced","SOFT_CC"},
        {"26964","Stun","HARD_CC"},
        {"26965","Silence","SOFT_CC"},
        {"26966","Puncture","BREAK"},
        {"27022","Root","SOFT_CC"},
        {"27124","Petrification","HARD_CC"},
        {"27269","Petrification","HARD_CC"},
        {"27308","Petrification","HARD_CC"},
        {"31675","Reduces Received Healing","HEAL_REDUCE"},
        {"31676","Decreases Physical Defense","BREAK"},
        {"31731","Move Speed Reduction","SOFT_CC"},
        {"32653","Invincibility Limit","COMBO"},
        {"8000631","Invincibility Limit","COMBO"},
        {"8000652","Tripped","HARD_CC"},
    },
    hidden={
        {"22969","Defiance隐藏","HIDDEN"},
        {"23214","Defiance隐藏兼容","HIDDEN"},
        {"27128","Defiance隐藏兼容","HIDDEN"},
        {"24405","Defiance隐藏兼容","HIDDEN"},
        {"32871","Defiance隐藏兼容","HIDDEN"},
    },
 }

-- V5 compatibility additions are retained through a de-duplicating layer.  IDs below are
-- current/player-combat relevant effects or compatibility variants that are
-- useful to track in PvP.  Localized names/icons are resolved from the running
-- client before persistence, so these English fallback labels never drive match.
local V5_PRESET_EXTRA={
    buff={
        -- Vitalism / healing states, including Mend: Life compatibility.
        {"222","Prayer","HEAL"},
        {"23965","Over Healing","HEAL"},
        {"5658","Healing Power","HEAL"},
        {"29905","Toughen","HEAL"},
        -- Songcraft positive performances and offensive/defensive windows.
        {"451","Double Recurve R1","BURST"},{"452","Double Recurve R2","BURST"},{"453","Double Recurve R3","BURST"},{"454","Double Recurve R4","BURST"},
        {"462","Deadly Refrain R1","BURST"},{"463","Deadly Refrain R2","BURST"},{"464","Deadly Refrain R3","BURST"},{"465","Deadly Refrain R4","BURST"},{"466","Deadly Refrain R5","BURST"},
        {"656","Quickstep R1","BURST"},{"657","Quickstep R2","BURST"},{"658","Quickstep R3","BURST"},{"659","Quickstep R4","BURST"},{"660","Quickstep R5","BURST"},
        {"2183","Quickstep R1","BURST"},{"2184","Quickstep R2","BURST"},{"2185","Quickstep R3","BURST"},{"2186","Quickstep R4","BURST"},{"2187","Quickstep R5","BURST"},
        {"667","Bloody Chantey R1","BURST"},{"7662","Bloody Chantey R2","BURST"},{"2196","Bloody Chantey R1","BURST"},{"7664","Bloody Chantey R2","BURST"},{"850","Bloody Chantey compatibility","BURST"},
        {"778","Bulwark Ballad R1","DEFENSE"},{"4386","Bulwark Ballad R2","DEFENSE"},{"2199","Bulwark Ballad R1","DEFENSE"},{"4387","Bulwark Ballad R2","DEFENSE"},
        {"833","Ode to Recovery compatibility R1","HEAL"},{"834","Ode to Recovery compatibility R2","HEAL"},{"835","Ode to Recovery compatibility R3","HEAL"},
        {"20325","Grief's Cadence of the Abyss","IMMUNITY"},
        -- Additional current-client healing / immunity / support states. These
        -- are aura ids (not skill ids) and are resolved to the Chinese client
        -- name/icon before they are persisted.
        {"15","Prayer of Protection","DEFENSE"},
        {"71","Regeneration","HEAL"},{"125","Self-Heal","HEAL"},{"221","Armor of Light","DEFENSE"},{"224","Healing Kiss","HEAL"},
        {"229","Song of Protection R1","DEFENSE"},{"230","Song of Protection R2","DEFENSE"},
        {"1057","Shock Immunity","IMMUNITY"},{"1067","Root Immunity","IMMUNITY"},{"1080","Liberation compatibility","IMMUNITY"},
        {"2216","Twilight Vitalism Immunity","IMMUNITY"},{"2220","Enhance Immunity","IMMUNITY"},{"5346","Sleep Immunity","IMMUNITY"},
        -- Spelldance current visible self states. Communication itself has no
        -- linked ID in the current public DB and is handled by runtime discovery.
        {"29842","Divine Presence R1","DEFENSE"},{"30067","Divine Presence R2","DEFENSE"},{"30068","Divine Presence R3","DEFENSE"},{"30069","Divine Presence R4","DEFENSE"},
        {"30594","Divine Presence: Wave","DEFENSE"},{"30113","Possessed by the Dead R1","BURST"},{"30114","Possessed by the Dead R2","BURST"},{"30115","Possessed by the Dead R3","BURST"},{"30116","Possessed by the Dead R4","BURST"},{"30595","Presence of the Dead: Wave","BURST"},
        -- More control-immunity compatibility states still observed by current
        -- clients/content; harmless if a particular player never receives one.
        {"3672","Snare Immunity","IMMUNITY"},{"5667","Trip Immunity","IMMUNITY"},{"5668","Stun Immunity","IMMUNITY"},{"5669","Impale Immunity","IMMUNITY"},{"5929","Impale Immunity","IMMUNITY"},{"6414","Trip Immunity","IMMUNITY"},{"6415","Impale Immunity","IMMUNITY"},
    },
    debuff={
        -- Vitalism Skewer/Impale family. Public linked-data only exposes 439 for
        -- the current base skill, while live/current databases contain multiple
        -- Impaled/Skewer compatibility ids used by variants and content builds.
        {"4351","Impaled compatibility","HARD_CC"},{"6860","Impaled compatibility","HARD_CC"},{"18420","Skewer compatibility","HARD_CC"},{"22685","Impaled compatibility","HARD_CC"},{"23956","Impaled compatibility","HARD_CC"},{"18396","Skewer compatibility","HARD_CC"},{"6368","Skewer compatibility","HARD_CC"},
        -- Core current PvP control/soft-control/defense-break variants.
        {"243","Stun compatibility","HARD_CC"},{"245","Silence compatibility","SOFT_CC"},{"253","Levitate","HARD_CC"},{"265","Decreases Magic Defense","BREAK"},{"2646","Broken Armor","BREAK"},{"26628","Defense Elimination","BREAK"},
        {"5009","Tripped","HARD_CC"},{"5014","Charm","HARD_CC"},{"5015","Charm","HARD_CC"},{"5016","Charm","HARD_CC"},{"5017","Charm","HARD_CC"},{"5018","Charm","HARD_CC"},
        {"5060","Sharp Dissonance","SOFT_CC"},{"5062","Song of Nightmares","HARD_CC"},{"5080","Immobilized","SOFT_CC"},{"5081","Electric Shock","COMBO"},{"6147","Silence","SOFT_CC"},
        {"2115","Silence","SOFT_CC"},{"2116","Silence","SOFT_CC"},{"2117","Dazed","SOFT_CC"},{"2118","Dazed","SOFT_CC"},{"2119","Defenseless","BREAK"},
        {"23357","Reduces Received Healing","HEAL_REDUCE"},{"23360","Reduces Received Healing","HEAL_REDUCE"},{"25260","Reduces Received Healing","HEAL_REDUCE"},
        {"23937","Absorb Lifeforce","HEAL_REDUCE"},{"32646","Enervate: Lightning","HEAL_REDUCE"},
        {"23361","Hell Spear: Flame","HARD_CC"},{"32647","Hell Spear: Quake","HARD_CC"},
        {"23066","Disable Left-Hand Weapon","EQUIP"},{"24239","Concussive Arrow: Rock slow","SOFT_CC"},
        -- Broader player-PvP control and vulnerability compatibility. The current
        -- DB contains several generations of the same state, so matching the
        -- observed aura id is more reliable than matching an English label.
        {"416","Stun","HARD_CC"},{"474","Enhanced Shackle","SOFT_CC"},{"501","Stun","HARD_CC"},{"505","Tripped","HARD_CC"},{"518","Tripped","HARD_CC"},
        {"523","Sleep","HARD_CC"},{"547","Powerful Sleep","HARD_CC"},{"734","Launched","HARD_CC"},{"743","Bubble Trap","HARD_CC"},{"752","Snare","SOFT_CC"},
        {"754","Encasing Webs","SOFT_CC"},{"756","Terror","HARD_CC"},{"758","Off-balance","SOFT_CC"},{"807","Interrupt Spell","SOFT_CC"},{"808","Defenseless","BREAK"},
        {"821","Fear","HARD_CC"},{"824","Lassoed","SOFT_CC"},{"902","Blind","SOFT_CC"},{"912","Cursed Shackles","SOFT_CC"},{"913","Stun","HARD_CC"},
        {"915","Decline in Concentration","SOFT_CC"},{"930","Leg Injury","SOFT_CC"},{"931","Drowsiness","SOFT_CC"},{"946","Severe Drowsiness","HARD_CC"},{"947","Shocked","SOFT_CC"},
        {"18337","Shield Removal","EQUIP"},{"18367","Soaring Impact","HARD_CC"},{"18428","Shield Charge Impact","HARD_CC"},{"18470","Stun","HARD_CC"},
        {"18496","Slow","SOFT_CC"},{"18982","Penetrated","BREAK"},{"23000","Mark of Malice","COMBO"},{"23030","Cursed","HEAL_REDUCE"},
        {"23034","Fiendish Fright","HARD_CC"},{"23061","Petrification","HARD_CC"},{"27031","Launched","HARD_CC"},{"27042","Freeze","SOFT_CC"},
        {"27046","Tripped","HARD_CC"},{"27061","Stop Time","HARD_CC"},{"27062","Shackle","SOFT_CC"},{"27063","Ultrasonic Waves","SOFT_CC"},
        {"27085","Deterioration","BREAK"},{"27837","Interruption","SOFT_CC"},{"27864","Petrification","HARD_CC"},
        {"30933","Pulled","SOFT_CC"},{"30934","Slowed","SOFT_CC"},{"30935","Silenced","SOFT_CC"},
        -- Spelldance current offensive states.
        {"29845","Psychic Shock","COMBO"},{"29897","Powerful Psychic Shock","COMBO"},
        -- Current/ancestral Songcraft negative performance states.
        {"2176","Lethargy (Bloody Chantey)","SOFT_CC"},{"2197","Lethargy (Bloody Chantey)","SOFT_CC"},{"2177","Unguarded (Bulwark Ballad)","BREAK"},{"2200","Unguarded (Bulwark Ballad)","BREAK"},
    },
    hidden={},
}

-- V6 adds verified flight-denial auras. The generic close/redeploy delay is
-- not forged into this table; its real timer is read from X2Skill cooldowns.
local V6_PRESET_EXTRA={
    buff={
        -- These are semantically restrictive states but the RU database/client
        -- classifies them as Buffs, so track them on the actual UnitBuff lane.
        {"4622","Preparing Glider / 滑翔翼整备中（5秒禁用）","MOBILITY"},
        {"20121","Preparing Glider / 翅膀整备中（5秒禁用）","MOBILITY"},
        {"26927","突进中 / 无法收起翅膀·滑翔翼","MOBILITY"},
    },
    debuff={
        {"7742","Turbulence / 湍流","MOBILITY"},
        {"19036","Madness / 无法使用滑翔翼·翅膀","MOBILITY"},
    },
    hidden={},
}

-- V7 focuses on player-confirmed and database-verified PvP timing states.
-- Do not invent an aura id for Sky Emperor's 5 sec untargetable window: the
-- public database confirms the mechanic but only exposes the related cooldown
-- aura (23087). Runtime PvP discovery can capture the live aura if the client
-- exposes a different id during actual use.
local V7_PRESET_EXTRA={
    buff={
        -- User-confirmed live RU ids.
        {"25875","光辉祷言：生命","HEAL"},
        {"8000503","Cat Nap / 灵猫格罗亚技能锁定","OTHER"},

        -- Powerstone/Groa lockouts: useful fallback when mate cooldown APIs are
        -- unavailable or a particular server build exposes only the owner aura.
        {"23834","Napping / 艾兰技能锁定","OTHER"},
        {"24200","Abraca-NOPE / 魔法梅布技能锁定","OTHER"},
        {"27291","Cooling Off / Wisp隐身格罗亚技能锁定","OTHER"},
        {"28599","Preparing next Trick / 南瓜格罗亚技能锁定","OTHER"},
        {"28674","Tired Snowflake / 雪花格罗亚技能锁定","OTHER"},
        {"29899","Cooling Off / Crowd格罗亚技能锁定","OTHER"},
        {"31532","Rammidri Cooling Off / Rammidri技能锁定","OTHER"},
        {"32699","Molang Cooling Off / Molang技能锁定","OTHER"},
        {"32700","Molang Cooling Off / Molang技能锁定兼容","OTHER"},

        -- Bloomfang's active 3 sec mitigation window (old/current custom ids).
        {"8000501","Truly Cathletic / 灵猫减伤","DEFENSE"},
        {"8000502","Truly Cathletic / 灵猫减伤","DEFENSE"},

        -- Other database-verified short defensive windows that matter in PvP.
        {"30334","Lamar's Protection / 拉玛保护（5秒承伤-50%）","DEFENSE"},
        {"5642","Damage Decrease / 强减伤（2秒承伤-80%）","DEFENSE"},
        {"26637","Absorb Damage / 伤害吸收（8秒50%伤害转生命）","DEFENSE"},

        -- Sky Emperor states. 23087 is intentionally named as the cooldown
        -- state, not as the unverified active 5 sec untargetable aura.
        {"23082","Ashen Wings: Sky Emperor / 天空帝王展开","MOBILITY"},
        {"23087","Untargetable Cooldown / 无法锁定冷却","MOBILITY"},
        {"23088","Sky Emperor's High Speed Glide / 天空帝王高速滑翔","MOBILITY"},

        -- Glider/wing deploy, active mobility and lockout compatibility ids.
        {"8000279","Preparing Glider / 新式滑翔翼整备中","MOBILITY"},
        {"8000532","Flight Speed Boost / 飞行加速","MOBILITY"},
        {"8000535","Stealth Flight / 隐形飞行","MOBILITY"},
        {"8000656","Flight Speed Boost / 飞行加速","MOBILITY"},
        {"21581","Invincible Flight Prevented / 无敌飞行限制","MOBILITY"},
        {"8000493","Invincible Flight Disabled / 无敌飞行禁用","MOBILITY"},
        {"9001924","Invincible Flight Disabled / 无敌飞行禁用（RU兼容）","MOBILITY"},

        -- Active invincible-flight windows used by several glider/wing families.
        {"8000162","Invincible Flight / 无敌飞行","DEFENSE"},
        {"8000163","Invincible Flight / 无敌飞行","DEFENSE"},
        {"8000164","Invincible Flight / 无敌飞行","DEFENSE"},
        {"8000165","Invincible Flight / 无敌飞行","DEFENSE"},
        {"8000166","Invincible Flight / 无敌飞行","DEFENSE"},
        {"8000286","Invincible Flight / 无敌飞行","DEFENSE"},
        {"8000465","Invincible Flight / 无敌飞行","DEFENSE"},
        {"8000466","Invincible Flight / 无敌飞行","DEFENSE"},
        {"8000492","Invincible Wings / 无敌翅膀","DEFENSE"},
        {"8000494","Invincible Flight / 无敌飞行","DEFENSE"},
        {"8000495","Invincible Flight / 无敌飞行","DEFENSE"},
        {"8000496","Invincible Flight / 无敌飞行","DEFENSE"},
        {"8000497","Invincible Flight / 无敌飞行","DEFENSE"},
        {"8000498","Invincible Flight / 无敌飞行","DEFENSE"},
    },
    debuff={
        -- These custom wing families are explicitly classified as Debuffs in
        -- the current ArcheRage custom buff database.
        {"8000533","Flight Speed Boost Cooldown / 飞行加速冷却","MOBILITY"},
        {"8000566","Flight Speed Boost Cooldown / 飞行加速冷却","MOBILITY"},
        {"8000610","Flight Speed Boost Cooldown / 飞行加速冷却","MOBILITY"},
        {"8000657","Flight Speed Boost Cooldown / 飞行加速冷却","MOBILITY"},
        {"32206","Flight Speed Boost Cooldown / 飞行加速冷却（45秒）","MOBILITY"},
        {"32816","Flight Speed Boost Cooldown / 飞行加速冷却（45秒）","MOBILITY"},
    },
    hidden={},
}

local function AppendPresetExtras()
    for _,effectType in ipairs({"buff","debuff","hidden"}) do
        local seen={}
        for _,entry in ipairs(CORE_PRESET[effectType] or {}) do seen[tostring(entry[1] or "")]=true end
        for _,extra in ipairs({V5_PRESET_EXTRA,V6_PRESET_EXTRA,V7_PRESET_EXTRA}) do
            for _,entry in ipairs(extra[effectType] or {}) do
                local id=tostring(entry[1] or "")
                if id~="" and not seen[id] then CORE_PRESET[effectType][#CORE_PRESET[effectType]+1]=entry; seen[id]=true end
            end
        end
    end
end
AppendPresetExtras()

local PRESET_FALLBACK_ICONS={
    buff="ui/icon/icon_skill_buff26.dds",
    debuff="ui/icon/icon_unknown_item.dds",
    hidden="ui/icon/icon_skill_buff381.dds",
}

local function ResolvePresetEntry(effectType, id, fallbackName, fallbackCategory)
    local fallbackIcon=PRESET_FALLBACK_ICONS[effectType] or "ui/icon/icon_unknown_item.dds"
    local entry,info=nil,nil
    if A~=nil and type(A.ResolveTrackedEntry)=="function" then
        entry,info=A:ResolveTrackedEntry(id,fallbackName,fallbackIcon)
    end
    if type(entry)~="table" then entry={name=tostring(fallbackName or ""),iconPath=fallbackIcon} end
    local description=type(info)=="table" and tostring(info.description or "") or ""
    entry.category=ClassifyCombatEffect(effectType,entry.name~="" and entry.name or fallbackName,description,fallbackCategory)
    return entry
end

local function DiscoveryBucket(scope,effectType)
    local scopeBucket=M.discovered and M.discovered[scope]
    return type(scopeBucket)=="table" and scopeBucket[effectType] or nil
end

local function CaptureBucket(scope,effectType)
    local capture=M.capture
    local scopeBucket=type(capture)=="table" and capture.buckets and capture.buckets[scope] or nil
    return type(scopeBucket)=="table" and scopeBucket[effectType] or nil
end

local function TrimCaptureBucket(bucket,cap)
    if type(bucket)~="table" then return end
    cap=math.max(32,math.floor(tonumber(cap) or 256))
    local count=0
    for _ in pairs(bucket) do count=count+1 end
    while count>=cap do
        local oldestId,oldestSerial=nil,nil
        for id,entry in pairs(bucket) do
            local serial=tonumber(entry and entry.lastSeenSerial) or tonumber(entry and entry.firstSeenSerial) or 0
            if oldestSerial==nil or serial<oldestSerial then oldestId,oldestSerial=id,serial end
        end
        if oldestId==nil then break end
        bucket[oldestId]=nil;count=count-1
    end
end

local function MergeCaptureEntry(scope,effectType,entry,serial)
    if type(entry)~="table" then return end
    local id=tostring(entry.id or "")
    if not id:match("^%d+$") then return end
    local bucket=CaptureBucket(scope,effectType)
    if type(bucket)~="table" then return end
    local current=bucket[id]
    if current==nil then
        TrimCaptureBucket(bucket,M.capture and M.capture.cap or 256)
        current={id=id,firstSeenSerial=serial}
        bucket[id]=current
    end
    current.lastSeenSerial=serial
    if tostring(entry.name or "")~="" then current.name=tostring(entry.name) end
    if tostring(entry.iconPath or "")~="" then current.iconPath=tostring(entry.iconPath) end
    if tostring(entry.category or "")~="" then current.category=tostring(entry.category) end
    if entry.stack~=nil then current.stack=tonumber(entry.stack) or current.stack end
    if entry.timeLeftMs~=nil then current.timeLeftMs=tonumber(entry.timeLeftMs) or current.timeLeftMs end
    current.effectType=effectType;current.trackable=true
end

-- The four lanes a single "开始检测" toggle now covers: both HUD scopes
-- (target + self) and both aura types (buff + debuff). Hidden is a separate
-- strict-whitelist mode and is intentionally excluded from all-lanes capture.
local CAPTURE_LANES = {
    { "target", "buff" }, { "target", "debuff" },
    { "player", "buff" }, { "player", "debuff" },
}

local function EnsureCaptureBuckets(capture)
    capture.buckets = type(capture.buckets) == "table" and capture.buckets or {}
    for _, scope in ipairs({ "target", "player" }) do
        capture.buckets[scope] = type(capture.buckets[scope]) == "table" and capture.buckets[scope] or {}
        for _, effectType in ipairs({ "buff", "debuff", "hidden" }) do
            if capture.buckets[scope][effectType] == nil then capture.buckets[scope][effectType] = {} end
        end
    end
    capture.laneCursors = type(capture.laneCursors) == "table" and capture.laneCursors or {}
end

function M:SetCaptureLane(scope,effectType)
    scope=(scope=="player") and "player" or "target"
    if effectType~="debuff" and effectType~="hidden" then effectType="buff" end
    self.capture=self.capture or {}
    EnsureCaptureBuckets(self.capture)
    self.capture.scope=scope;self.capture.effectType=effectType
end

function M:SetCaptureEnabled(enabled,scope,effectType)
    self.capture=self.capture or {}
    EnsureCaptureBuckets(self.capture)
    if enabled==true then
        -- One toggle now drives ALL four lanes (target/self x buff/debuff) so the
        -- user only needs to open detection once to capture both HUDs at once.
        self.capture.enabled=true
        self.capture.allLanes=true
        self.capture.deepAllowed=true
        if scope~=nil or effectType~=nil then self:SetCaptureLane(scope or "target",effectType or "buff") end
    else
        self.capture.enabled=false
        self.capture.allLanes=false
        if self.capture.sticky~=true then
            -- Not sticky: drop captured queues for every lane on stop.
            for _, lane in ipairs(CAPTURE_LANES) do self:ClearCaptureQueue(lane[1],lane[2]) end
        end
    end
    return self.capture.enabled
end

function M:SetCaptureSticky(enabled)
    self.capture.sticky=enabled==true
    return self.capture.sticky
end

function M:IsCaptureEnabled() return self.capture and self.capture.enabled==true end
function M:IsCaptureSticky() return self.capture==nil or self.capture.sticky~=false end

function M:ClearCaptureQueue(scope,effectType)
    if self.capture and self.capture.allLanes==true and scope==nil and effectType==nil then
        -- All-lanes mode: "清空队列" with no args clears every capture lane at once.
        for _, lane in ipairs(CAPTURE_LANES) do
            local bucket=CaptureBucket(lane[1],lane[2])
            if type(bucket)=="table" then for id in pairs(bucket) do bucket[id]=nil end end
        end
        return true
    end
    local bucket=CaptureBucket(scope or (self.capture and self.capture.scope),effectType or (self.capture and self.capture.effectType))
    if type(bucket)~="table" then return false end
    for id in pairs(bucket) do bucket[id]=nil end
    return true
end

function M:GetCaptureList(scope,effectType)
    local result={};local bucket=CaptureBucket(scope,effectType)
    if type(bucket)~="table" then return result end
    local sticky=self:IsCaptureSticky();local serial=tonumber(self.capture and self.capture.serial) or 0
    for id,entry in pairs(bucket) do
        local age=serial-(tonumber(entry and entry.lastSeenSerial) or 0)
        if sticky or age<=3 then
            result[#result+1]={
                id=tostring(id),name=tostring(entry.name or ("检测 ID "..tostring(id))),
                iconPath=tostring(entry.iconPath or "ui/icon/icon_unknown_item.dds"),
                category=tostring(entry.category or "OTHER"),stack=tonumber(entry.stack) or 1,
                timeLeftMs=tonumber(entry.timeLeftMs) or 0,effectType=effectType,trackable=true,
                firstSeenSerial=tonumber(entry.firstSeenSerial) or 0,lastSeenSerial=tonumber(entry.lastSeenSerial) or 0,
            }
        end
    end
    table.sort(result,function(a,b)
        if a.lastSeenSerial~=b.lastSeenSerial then return a.lastSeenSerial>b.lastSeenSerial end
        return (tonumber(a.id) or 0)<(tonumber(b.id) or 0)
    end)
    return result
end

function M:GetCaptureCount(scope,effectType) return #self:GetCaptureList(scope,effectType) end

-- 100ms capture lane: only reads cheap effect IDs. Metadata resolution happens
-- once per newly observed ID and is cached by A:GetBuffInfoById, so this mode
-- does not perform full Tooltip scans every runtime pass.
function M:CaptureFast()
    if not ModuleRuntimeEnabled() or not self:IsCaptureEnabled() or A==nil or type(A.GetEffectIds)~="function" then return end
    local capture=self.capture
    capture.serial=(tonumber(capture.serial) or 0)+1
    capture.deepAllowed=true
    local serial=capture.serial
    local lanes = (capture.allLanes==true) and CAPTURE_LANES or { { capture.scope or "target", capture.effectType or "buff" } }
    capture.laneCursors = capture.laneCursors or {}
    for _, lane in ipairs(lanes) do
        local scope, effectType = lane[1], lane[2]
        local unit = SCOPE_META[scope] and SCOPE_META[scope].unit
        if unit==nil then
            -- lane has no unit mapping; skip without aborting the rest
        else
            local key = scope..":"..effectType
            local cursor = math.max(1, math.floor(tonumber(capture.laneCursors[key]) or 1))
            local ids, nextCursor = A:GetEffectIds(unit, effectType, 32, cursor, 2)
            capture.laneCursors[key] = nextCursor or 1
            local bucket = CaptureBucket(scope, effectType)
            if type(bucket)=="table" then
                for _,id in ipairs(type(ids)=="table" and ids or {}) do
                    id=tostring(id or "")
                    if id:match("^%d+$") then
                        local existing=bucket[id]
                        if existing~=nil then
                            existing.lastSeenSerial=serial
                        else
                            local entry=ResolvePresetEntry(effectType,id,"检测 ID "..id,nil)
                            entry.id=id;entry.stack=1;entry.timeLeftMs=0
                            MergeCaptureEntry(scope,effectType,entry,serial)
                        end
                    end
                end
            end
        end
    end
end

-- Aura update events are sparse and user capture is explicit, so use one deep
-- catalog read on the selected lane to preserve real icon/name/stack/time for
-- very short effects. The periodic path above remains ID-only.
function M:CaptureEvent(effectHint)
    if not ModuleRuntimeEnabled() or not self:IsCaptureEnabled() or A==nil or type(A.GetEffectCatalog)~="function" then return end
    local capture=self.capture
    -- At most one deep catalog decode burst between 100ms fast passes. Aura events
    -- can burst heavily in raids; the fast ID lane still runs every pass and catches
    -- additional short states without turning every event into a Tooltip sweep.
    if capture.deepAllowed==false then return end
    capture.deepAllowed=false
    capture.serial=(tonumber(capture.serial) or 0)+1
    local serial=capture.serial
    -- In all-lanes mode a buff/debuff event drives the matching type on BOTH scopes.
    local lanes = (capture.allLanes==true)
        and CAPTURE_LANES
        or { { capture.scope or "target", capture.effectType or "buff" } }
    for _, lane in ipairs(lanes) do
        local scope, effectType = lane[1], lane[2]
        if effectHint~=nil and effectHint~=effectType and not (effectType=="hidden" and effectHint=="buff") then
            -- this lane's type does not match the event hint; skip it
        else
            local unit = SCOPE_META[scope] and SCOPE_META[scope].unit
            if unit~=nil then
                local list=A:GetEffectCatalog(unit,effectType,128,effectType=="hidden") or {}
                for _,entry in ipairs(list) do if entry.trackable~=false then MergeCaptureEntry(scope,effectType,entry,serial) end end
            end
        end
    end
end

function M:GetDiscoveryList(scope,effectType)
    local result={}
    local bucket=DiscoveryBucket(scope,effectType)
    if type(bucket)~="table" then return result end
    for id,entry in pairs(bucket) do
        if not S:IsTracked(scope,effectType,id) then
            result[#result+1]={
                id=tostring(id),
                name=tostring(entry.name or ""),
                iconPath=tostring(entry.iconPath or ""),
                category=tostring(entry.category or ""),
                firstSeen=tonumber(entry.firstSeen) or 0,
            }
        end
    end
    table.sort(result,function(a,b)
        if a.firstSeen~=b.firstSeen then return a.firstSeen>b.firstSeen end
        local an,bn=tostring(a.name or ""),tostring(b.name or "")
        if an~=bn then return an<bn end
        local ai,bi=tonumber(a.id),tonumber(b.id)
        if ai~=nil and bi~=nil and ai~=bi then return ai<bi end
        return tostring(a.id)<tostring(b.id)
    end)
    return result
end

function M:GetDiscoveredCount(scope,effectType)
    return #self:GetDiscoveryList(scope,effectType)
end

-- Session-only compatibility lane for current-server effects whose public DB has
-- no linked effect id (notably Spelldance Communication / Maximization).  Only
-- already-observed, combat-classified effects are admitted; nothing is saved or
-- silently added to the explicit tracking database.
local SESSION_AUTO_CATEGORIES={HARD_CC=true,SOFT_CC=true,IMMUNITY=true,BREAK=true,HEAL_REDUCE=true,HEAL=true,DEFENSE=true,BURST=true,EQUIP=true,MOBILITY=true,COMBO=true}
function M:GetSessionRelevantIds(scope,effectType)
    local result={}
    local bucket=DiscoveryBucket(scope,effectType)
    if type(bucket)~="table" then return result end
    for id,entry in pairs(bucket) do
        local category=tostring(entry and entry.category or "")
        local name=tostring(entry and entry.name or "")
        -- Exact-name compatibility keeps Communication visible even if a client
        -- tooltip has too little description to classify it generically.
        local communication=ContainsAny(name,{"交感","极效交感","Communication","Communication Maximization"})
        -- A hostile target's active debuff is itself combat-relevant evidence.
        -- Admit every observed target debuff for this session even if the public
        -- DB has no linked metadata. Other lanes still require a PvP category/name
        -- match so food/event buffs do not flood the self HUD.
        local targetDebuff = scope=="target" and effectType=="debuff"
        if targetDebuff or communication or SESSION_AUTO_CATEGORIES[category]==true then result[tostring(id)]=true end
    end
    return result
end

function M:ForgetDiscovered(scope,effectType,id)
    local bucket=DiscoveryBucket(scope,effectType)
    if type(bucket)=="table" then bucket[tostring(id or "")]=nil end
end

function M:ClearDiscovered(scope,effectType)
    if self.discovered==nil or self.discovered[scope]==nil then return end
    self.discovered[scope][effectType]={}
    if self.discoveryCursor and self.discoveryCursor[scope] then self.discoveryCursor[scope][effectType]=1 end
    self.activePage.live=1
end

local function TrimDiscoveryBucket(bucket,cap)
    local count=0
    for _ in pairs(bucket) do count=count+1 end
    if count<cap then return end
    local oldestId,oldestSerial=nil,nil
    for id,entry in pairs(bucket) do
        local serial=tonumber(entry and entry.firstSeen) or 0
        if oldestSerial==nil or serial<oldestSerial then oldestId,oldestSerial=id,serial end
    end
    if oldestId~=nil then bucket[oldestId]=nil end
end

-- Observe the current RU client's actual target/self aura ids.  This complements
-- the static preset list: new Ancestral variants or server-custom ids can be caught
-- during real combat even when the online database has incomplete linked data.
-- Nothing is auto-added to tracking and nothing here is written to SaveData.
function M:ObserveCombat()
    if not ModuleRuntimeEnabled() then return end
    if A==nil or type(A.GetEffectIds)~="function" then return end
    self.discoveryPhase=(tonumber(self.discoveryPhase) or 0)+1
    local phase=self.discoveryPhase
    local scanLimit,fallbackLimit=12,10

    local function ObserveLane(scope,effectType)
        local scopeCfg=S:Get()[scope]
        if type(scopeCfg)~="table" or scopeCfg.autoPvPRelevant~=true then return end
        local unit=SCOPE_META[scope].unit
        local cursor=1
        if self.discoveryCursor and self.discoveryCursor[scope] then cursor=self.discoveryCursor[scope][effectType] or 1 end
        local ids,nextCursor=A:GetEffectIds(unit,effectType,scanLimit,cursor,fallbackLimit)
        if self.discoveryCursor and self.discoveryCursor[scope] then self.discoveryCursor[scope][effectType]=nextCursor or 1 end
        local bucket=DiscoveryBucket(scope,effectType)
        if type(bucket)~="table" then return end
        for _,id in ipairs(type(ids)=="table" and ids or {}) do
            id=tostring(id or "")
            if id~="" then
                if S:IsTracked(scope,effectType,id) then
                    bucket[id]=nil
                elseif bucket[id]==nil then
                    TrimDiscoveryBucket(bucket,math.max(32,tonumber(self.discoveryCap) or 192))
                    self.discoverySerial=(tonumber(self.discoverySerial) or 0)+1
                    local entry=ResolvePresetEntry(effectType,id,"实战发现 ID "..id)
                    bucket[id]={
                        id=id,
                        name=tostring(entry.name or "实战发现 ID "..id),
                        iconPath=tostring(entry.iconPath or PRESET_FALLBACK_ICONS[effectType] or "ui/icon/icon_unknown_item.dds"),
                        category=tostring(entry.category or "OTHER"),
                        firstSeen=self.discoverySerial,
                    }
                end
            end
        end
    end

    -- Priority lanes are sampled every tick so short new 10.0 controls and
    -- short self-healing/immunity buffs are much less likely to be missed.
    ObserveLane("target","debuff")
    ObserveLane("player","buff")
    -- Secondary visible lanes: every second tick.
    if phase%2==0 then
        ObserveLane("target","buff")
        ObserveLane("player","debuff")
    end
    -- Hidden lanes are useful for compatibility but change less often.
    if phase%4==0 then
        ObserveLane("target","hidden")
        ObserveLane("player","hidden")
    end
end

local function BuildCorePresetTracking()
    local result={target={buff={},debuff={},hidden={}},player={buff={},debuff={},hidden={}}}
    -- Resolve each id only once; A:GetBuffInfoById is also cached.
    local resolved={buff={},debuff={},hidden={}}
    for _,effectType in ipairs({"buff","debuff","hidden"}) do
        for _,source in ipairs(CORE_PRESET[effectType]) do
            local id=tostring(source[1])
            resolved[effectType][id]=ResolvePresetEntry(effectType,id,source[2],source[3])
        end
    end
    for _,scope in ipairs({"target","player"}) do
        for _,effectType in ipairs({"buff","debuff","hidden"}) do
            for id,entry in pairs(resolved[effectType]) do
                result[scope][effectType][id]={name=entry.name,iconPath=entry.iconPath,category=entry.category}
            end
        end
    end
    return result
end

local function BuildCorePresetImportText()
    local parts={"RPPLATESALL1"}
    for _,scope in ipairs({"target","player"}) do
        for _,effect in ipairs({"buff","debuff","hidden"}) do
            for _,entry in ipairs(CORE_PRESET[effect]) do
                parts[#parts+1]=Escape(scope).."~"..Escape(effect).."~"..tostring(entry[1]).."~"..Escape(entry[2]).."~"
            end
        end
    end
    return table.concat(parts,"|")
end

-- New built-in library source: the wiki-scraped SkillEffects (rs_skill_effects.lua).
-- This replaces the old hand-picked CORE_PRESET so “导入内置实战库” seeds the current,
-- comprehensive buff/debuff ID set instead of the legacy RU_CORE_V7 list.
-- The library stores kind="unknown" (filled later in-game), so we split buff vs
-- debuff by a name-keyword heuristic as a sensible default; per-item edits in-game
-- remain authoritative. If the data table is missing, fall back to the legacy token.
local SKILL_EFFECT_DEBUFF_KW={
    "眩晕","沉默","恐惧","毒","流血","束缚","倒地","封印","冻","触电","催眠","禁锢","击倒","击退",
    "削弱","破甲","破防","减防","减速","迟缓","混乱","失明","虚弱","诅咒","定身","麻痹","睡眠","灼烧",
    "燃烧","重伤","侵蚀","腐朽","刺痛","创伤","降攻","降防","减益","控制","颤栗","石化","压制","瘫痪",
    "致盲","缓速","腐蚀","瘟疫","昏睡","震慑","封锁","枷锁","绞杀","撕裂","穿透","禁言","禁魔","缴械",
    "缠绕","冰冻","冰封","破胆","畏缩","怯懦","怯战","减速","虚弱","禁锢",
    "牢","折磨","治愈量","枪刺","压倒","冻结"
}
local function ClassifySkillEffectKind(name)
    if type(name)~="string" or name=="" then return "buff" end
    for _,kw in ipairs(SKILL_EFFECT_DEBUFF_KW) do
        if name:find(kw,1,true) then return "debuff" end
    end
    return "buff"
end

local SKILL_EFFECT_PRESET_TOKEN="RPPLATESPRESET1|RU_SKILLEFFECTS_V1"
local function BuildSkillEffectsPresetTracking()
    -- 注意：本模块的 S = ReplicatedPlates.Storage，而技能库写在 ReplicatedSuite.Data.SkillEffects
    -- （见 rs_skill_effects.lua 的 local S = ReplicatedSuite）。必须用全局 ReplicatedSuite 读取，
    -- 否则读到的是 Storage.Data，永远为 nil。
    local lib=(ReplicatedSuite and ReplicatedSuite.Data and ReplicatedSuite.Data.SkillEffects and ReplicatedSuite.Data.SkillEffects.buffs) or nil
    if lib==nil then
        -- 绝不静默回退到旧库：数据缺失说明 rs_skill_effects.lua 未加载，
        -- 必须明确报错，否则会把已过时的 RU_CORE_V7 手工清单当作"新库"灌进去。
        return nil, "新技能库未加载：rs_skill_effects.lua 未生效（请检查插件是否完整并重载）。无法导入内置实战库。"
    end
    local result={target={buff={},debuff={},hidden={}},player={buff={},debuff={},hidden={}}}
    for id,info in pairs(lib) do
        local name=(type(info)=="table" and info.name) or tostring(info)
        if name and name~="" then
            local effect=ClassifySkillEffectKind(name)
            for _,scope in ipairs({"target","player"}) do
                result[scope][effect][tostring(id)]={name=name,iconPath="",category=""}
            end
        end
    end
    return result
end

local COMPACT_AURA_HEADER="RPPLATESAURA1"
local AURA_LIBRARY_HEADER="RPPLATESAURA3"
local AURA_CHUNK_PAYLOAD_LIMIT=1300

local function NormalizeImportText(text)
    local normalized=tostring(text or "")
    -- Accept UTF-8 BOM and text copied through editors/chat windows that add
    -- line breaks around a long one-line export. Literal newlines in names are
    -- escaped as %0A by BuildExportAll(), so raw CR/LF/TAB are safe to remove.
    normalized=normalized:gsub("^\239\187\191","")
    local legacyHeader=normalized:find("RPPLATESALL1",1,true)
    local compactHeader=normalized:find(COMPACT_AURA_HEADER,1,true)
    local header=nil
    if legacyHeader~=nil and compactHeader~=nil then header=math.min(legacyHeader,compactHeader)
    elseif legacyHeader~=nil then header=legacyHeader
    else header=compactHeader end
    if header~=nil then normalized=normalized:sub(header) end
    normalized=normalized:gsub("[\r\n\t]","")
    normalized=normalized:match("^%s*(.-)%s*$") or ""
    return normalized
end

local function CountTracking(tracking)
    local counts={target={buff=0,debuff=0,hidden=0},player={buff=0,debuff=0,hidden=0},total=0}
    for _,scope in ipairs({"target","player"}) do
        for _,effect in ipairs({"buff","debuff","hidden"}) do
            local bucket=type(tracking)=="table" and type(tracking[scope])=="table" and tracking[scope][effect] or nil
            if type(bucket)=="table" then
                for _ in pairs(bucket) do counts[scope][effect]=counts[scope][effect]+1 end
            end
            counts.total=counts.total+counts[scope][effect]
        end
    end
    return counts
end

local function CountUniqueAuraIds(tracking)
    local seen={}
    for _,scope in ipairs({"target","player"}) do
        for _,effect in ipairs({"buff","debuff"}) do
            local bucket=type(tracking)=="table" and type(tracking[scope])=="table" and tracking[scope][effect] or nil
            if type(bucket)=="table" then for id in pairs(bucket) do if tostring(id):match("^%d+$") then seen[tostring(id)]=true end end end
        end
    end
    local count=0;for _ in pairs(seen) do count=count+1 end;return count
end

local function CountHiddenTracking(tracking)
    local count=0
    for _,scope in ipairs({"target","player"}) do
        local bucket=type(tracking)=="table" and type(tracking[scope])=="table" and tracking[scope].hidden or nil
        if type(bucket)=="table" then for _ in pairs(bucket) do count=count+1 end end
    end
    return count
end

local function DecodeCompactAuraImport(normalized)
    if normalized:sub(1,#COMPACT_AURA_HEADER+1)~=COMPACT_AURA_HEADER.."|" then return nil,"不是 "..COMPACT_AURA_HEADER.." 职业状态配置" end
    local body=normalized:sub(#COMPACT_AURA_HEADER+2)
    if body=="" then return nil,"职业状态配置为空" end

    local result={target={buff={},debuff={},hidden={}},player={buff={},debuff={},hidden={}}}
    local seen={}
    local sections=0
    for section in (body.."|"):gmatch("(.-)|") do
        if section~="" then
            local code,list=section:match("^([BD]):(.*)$")
            if code==nil then return nil,"职业状态分组格式无效" end
            if seen[code] then return nil,"职业状态分组重复："..tostring(code) end
            seen[code]=true;sections=sections+1
            if list=="" or list:find("[^%d,]")~=nil or list:find("^,")~=nil or list:find(",,")~=nil or list:find(",$")~=nil then
                return nil,"职业状态 "..tostring(code).." ID 列表格式无效"
            end
            local effect=code=="B" and "buff" or "debuff"
            local found=0
            for id in list:gmatch("%d+") do
                found=found+1
                for _,scope in ipairs({"target","player"}) do
                    result[scope][effect][id]={name="",iconPath="",category=""}
                end
            end
            if found<=0 then return nil,"职业状态 "..tostring(code).." 没有有效 ID" end
        end
    end
    if sections<=0 then return nil,"职业状态配置没有有效分组" end
    return result,nil,CountTracking(result),false
end

local function DecodeImportAll(text)
    local parts={}
    local normalized=NormalizeImportText(text)
    if normalized:sub(1,#COMPACT_AURA_HEADER+1)==COMPACT_AURA_HEADER.."|" then
        return DecodeCompactAuraImport(normalized)
    end
    if normalized==CORE_PRESET_TOKEN or normalized==CORE_PRESET_TOKEN_V6 or normalized==CORE_PRESET_TOKEN_V5 or normalized==CORE_PRESET_TOKEN_V4 or normalized==CORE_PRESET_TOKEN_V3 or normalized==CORE_PRESET_TOKEN_V2 or normalized==CORE_PRESET_TOKEN_V1 or normalized==SKILL_EFFECT_PRESET_TOKEN then
        local preset, perr
        if normalized==SKILL_EFFECT_PRESET_TOKEN then
            preset, perr = BuildSkillEffectsPresetTracking()
            if preset==nil then return nil, perr end
        else
            preset = BuildCorePresetTracking()
        end
        return preset,nil,CountTracking(preset),true
    end
    for part in (normalized.."|"):gmatch("(.-)|") do parts[#parts+1]=part end
    if parts[1]~="RPPLATESALL1" then return nil,"不是 RPPLATESALL1 全量配置" end
    local result={target={buff={},debuff={},hidden={}},player={buff={},debuff={},hidden={}}}
    for i=2,#parts do
        if parts[i]~="" then
            local scope,effect,id,name,icon,category=parts[i]:match("^(.-)~(.-)~(%d+)~(.-)~(.-)~(.*)$")
            if id==nil then scope,effect,id,name,icon=parts[i]:match("^(.-)~(.-)~(%d+)~(.-)~(.*)$") end
            if id==nil then return nil,"第 "..tostring(i-1).." 项格式无效" end
            scope,effect=Unescape(scope),Unescape(effect)
            if scope=="watchtarget" then
                -- v0.4.1 removed the independent watch-target HUD. Old all-in-one
                -- exports remain importable; their retired bucket is discarded.
            elseif type(result[scope])~="table" or type(result[scope][effect])~="table" then
                return nil,"第 "..tostring(i-1).." 项分类无效"
            else
                result[scope][effect][id]={name=Unescape(name),iconPath=Unescape(icon),category=category~=nil and Unescape(category) or ""}
            end
        end
    end
    return result, nil, CountTracking(result),false
end

local function IsPresetFallbackIcon(path)
    path=tostring(path or "")
    return path=="" or path==PRESET_FALLBACK_ICONS.buff or path==PRESET_FALLBACK_ICONS.debuff or path==PRESET_FALLBACK_ICONS.hidden
end

local function EnrichTrackingMetadata(tracking)
    if type(tracking)~="table" or A==nil or type(A.ResolveTrackedEntry)~="function" then return false end
    local changed=false
    for _,scope in ipairs({"target","player"}) do
        for _,effectType in ipairs({"buff","debuff","hidden"}) do
            local bucket=type(tracking[scope])=="table" and tracking[scope][effectType] or nil
            if type(bucket)=="table" then
                for id,entry in pairs(bucket) do
                    if type(entry)=="table" then
                        local oldName=tostring(entry.name or "")
                        local oldIcon=tostring(entry.iconPath or "")
                        local oldCategory=tostring(entry.category or "")
                        local resolved,info=A:ResolveTrackedEntry(id,oldName,oldIcon~="" and oldIcon or (PRESET_FALLBACK_ICONS[effectType] or "ui/icon/icon_unknown_item.dds"))
                        if type(resolved)=="table" then
                            local newName=tostring(resolved.name or oldName)
                            local newIcon=tostring(resolved.iconPath or oldIcon)
                            if (oldName=="" or oldName==("手动 ID "..tostring(id))) and newName~="" and newName~=oldName then entry.name=newName; oldName=newName; changed=true end
                            if IsPresetFallbackIcon(oldIcon) and newIcon~="" and newIcon~=oldIcon then entry.iconPath=newIcon; changed=true end
                            local description=type(info)=="table" and tostring(info.description or "") or ""
                            local category=ClassifyCombatEffect(effectType,entry.name or oldName,description,oldCategory~="" and oldCategory or nil)
                            if category~=oldCategory then entry.category=category; changed=true end
                        elseif oldCategory=="" then
                            entry.category=ClassifyCombatEffect(effectType,oldName,"",nil); changed=true
                        end
                    end
                end
            end
        end
    end
    return changed
end

local function CopyRuleEntry(entry)
    entry = type(entry) == "table" and entry or {}
    local result = {
        name = tostring(entry.name or ""), customName = tostring(entry.customName or ""),
        iconPath = tostring(entry.iconPath or ""), category = tostring(entry.category or ""),
        enabled = entry.enabled ~= false, priority = math.floor(tonumber(entry.priority) or 0),
        showDuration = entry.showDuration, showStack = entry.showStack, showBorder = entry.showBorder, showTooltip = entry.showTooltip, iconSize = entry.iconSize,
        expireEnabled = entry.expireEnabled, expireThreshold = entry.expireThreshold,
    }
    if type(entry.borderColor) == "table" then result.borderColor = { r=entry.borderColor.r, g=entry.borderColor.g, b=entry.borderColor.b, a=entry.borderColor.a } end
    if type(entry.expireColor) == "table" then result.expireColor = { r=entry.expireColor.r, g=entry.expireColor.g, b=entry.expireColor.b, a=entry.expireColor.a } end
    return result
end

local function MergePresetTracking(current,preset)
    local result={target={buff={},debuff={},hidden={}},player={buff={},debuff={},hidden={}}}
    for _,scope in ipairs({"target","player"}) do
        for _,effectType in ipairs({"buff","debuff","hidden"}) do
            local dst=result[scope][effectType]
            local old=type(current)=="table" and type(current[scope])=="table" and current[scope][effectType] or nil
            if type(old)=="table" then
                for id,entry in pairs(old) do
                    dst[tostring(id)]=CopyRuleEntry(entry)
                end
            end
            local incoming=type(preset)=="table" and type(preset[scope])=="table" and preset[scope][effectType] or nil
            if type(incoming)=="table" then
                for id,entry in pairs(incoming) do
                    id=tostring(id)
                    local existing=dst[id]
                    if existing==nil then
                        dst[id]=CopyRuleEntry(entry)
                    else
                        -- Preserve explicit user labels/icons, but repair old V1
                        -- preset/manual placeholders while merging V2.
                        local existingName=tostring(existing.name or "")
                        if existingName=="" or existingName==("手动 ID "..id) then existing.name=tostring(entry.name or existingName) end
                        if IsPresetFallbackIcon(existing.iconPath) and tostring(entry.iconPath or "")~="" then existing.iconPath=tostring(entry.iconPath) end
                        if tostring(existing.category or "")=="" and tostring(entry.category or "")~="" then existing.category=tostring(entry.category) end
                    end
                end
            end
        end
    end
    return result
end

function M:ExportAll()
    return BuildExportAll()
end

function M:ImportAll(text, replace)
    local decoded,err,expectedCounts,isPreset=DecodeImportAll(text)
    if decoded==nil then return false,err end
    if expectedCounts==nil or expectedCounts.total<=0 then return false,"导入内容里没有有效追踪项" end
    EnrichTrackingMetadata(decoded)

    local cfg=S:Get()
    local oldTracking,oldAura=cfg.tracking,cfg.auraLibrary
    local oldDirty,oldTrackingDirty,oldAuraDirty=S.dirty,S.trackingDirty,S.auraDirty
    if isPreset then
        if not replace then decoded=MergePresetTracking(cfg.tracking,decoded) end
        expectedCounts=CountTracking(decoded)
    end
    local adopted,adoptErr=S:AdoptTracking(decoded)
    if not adopted then return false,adoptErr end
    local ok,saveErr=S:Save(true)
    if not ok then
        cfg.tracking,cfg.auraLibrary=oldTracking,oldAura
        S.dirty,S.trackingDirty,S.auraDirty=oldDirty,oldTrackingDirty,oldAuraDirty
        return false,"保存失败："..tostring(saveErr or "unknown")
    end

    -- Bulk import verification follows the new split Authority: normal
    -- Buff/Debuff IDs live in AuraLibrary, while Hidden remains in tracking
    -- shards. Compare both committed authorities so a partial SaveData write
    -- can never look like a successful large import.
    local persistedAura,auraErr=S:ReadCommittedAuraLibrary()
    local persistedTracking,trackingErr=S:ReadCommittedTracking()
    local actualAura=0;if type(persistedAura)=="table" then for _ in pairs(persistedAura) do actualAura=actualAura+1 end end
    local actualHidden=type(persistedTracking)=="table" and CountHiddenTracking(persistedTracking) or -1
    local expectedAura,expectedHidden=CountUniqueAuraIds(decoded),CountHiddenTracking(decoded)
    if auraErr~=nil or trackingErr~=nil or actualAura~=expectedAura or actualHidden~=expectedHidden then
        cfg.tracking,cfg.auraLibrary=oldTracking,oldAura
        S:MarkAuraDirty();S:MarkTrackingDirty()
        local restored,restoreErr=S:Save(true)
        S.dirty=oldDirty and true or S.dirty
        S.trackingDirty=oldTrackingDirty and true or S.trackingDirty
        S.auraDirty=oldAuraDirty and true or S.auraDirty
        local detail="Aura "..tostring(actualAura).."/"..tostring(expectedAura).." · Hidden "..tostring(actualHidden).."/"..tostring(expectedHidden)
        if auraErr~=nil then detail=detail.." · Aura读取="..tostring(auraErr) end
        if trackingErr~=nil then detail=detail.." · Hidden读取="..tostring(trackingErr) end
        if not restored then detail=detail.."；旧配置恢复失败："..tostring(restoreErr or "unknown") end
        return false,"保存后校验失败（"..detail.."）"
    end

    if P.Runtime and P.Runtime.ForceAll then
        P.Runtime:ForceAll()
    elseif P.Runtime and P.Runtime.ForceScope then
        P.Runtime:ForceScope("target");P.Runtime:ForceScope("player")
    end
    return true,nil,expectedCounts
end

local function BoolCode(value)
    if value == nil then return "-" end
    return value == true and "1" or "0"
end
local function DecodeBoolCode(value)
    if value == "-" or value == nil or value == "" then return nil end
    return value == "1"
end
local function ColorHex(color)
    if type(color) ~= "table" then return "-" end
    local function c(v) return math.max(0, math.min(255, math.floor((tonumber(v) or 0) * 255 + 0.5))) end
    return string.format("%02X%02X%02X%02X", c(color.r or color[1]), c(color.g or color[2]), c(color.b or color[3]), c(color.a or color[4] or 1))
end
local function DecodeColorHex(text)
    text = tostring(text or "")
    if text == "-" or text == "" then return nil end
    local r,g,b,a=text:match("^(%x%x)(%x%x)(%x%x)(%x%x)$")
    if r==nil then return nil end
    return {r=tonumber(r,16)/255,g=tonumber(g,16)/255,b=tonumber(b,16)/255,a=tonumber(a,16)/255}
end
local function EncodeRule(scope,effect,id,entry)
    entry=type(entry)=="table" and entry or {}
    return table.concat({
        Escape(scope),Escape(effect),tostring(id),Escape(entry.name),Escape(entry.customName),Escape(entry.iconPath),Escape(entry.category),
        entry.enabled==false and "0" or "1",tostring(math.floor(tonumber(entry.priority) or 0)),
        BoolCode(entry.showDuration),BoolCode(entry.showStack),BoolCode(entry.showBorder),BoolCode(entry.showTooltip),tostring(entry.iconSize or "-"),BoolCode(entry.expireEnabled),
        tostring(math.floor(tonumber(entry.expireThreshold) or 5)),ColorHex(entry.borderColor),ColorHex(entry.expireColor)
    },"~")
end
local function DecodeRule(row)
    local parts={}; for part in (tostring(row or "").."~"):gmatch("(.-)~") do parts[#parts+1]=part end
    if #parts < 18 then return nil,"规则字段不足" end
    local scope,effect,id=Unescape(parts[1]),Unescape(parts[2]),tostring(parts[3] or "")
    if (scope~="target" and scope~="player") or (effect~="buff" and effect~="debuff" and effect~="hidden") or not id:match("^%d+$") then return nil,"规则身份无效" end
    return scope,effect,id,{
        name=Unescape(parts[4]),customName=Unescape(parts[5]),iconPath=Unescape(parts[6]),category=Unescape(parts[7]),
        enabled=parts[8]~="0",priority=math.max(-100,math.min(100,math.floor(tonumber(parts[9]) or 0))),
        showDuration=DecodeBoolCode(parts[10]),showStack=DecodeBoolCode(parts[11]),showBorder=DecodeBoolCode(parts[12]),showTooltip=DecodeBoolCode(parts[13]),iconSize=parts[14]~="-" and math.max(18,math.min(42,tonumber(parts[14]) or 24)) or nil,expireEnabled=DecodeBoolCode(parts[15]),
        expireThreshold=math.max(1,math.min(60,math.floor(tonumber(parts[16]) or 5))),borderColor=DecodeColorHex(parts[17]),expireColor=DecodeColorHex(parts[18]),
    }
end

local function BuildTrackingV2()
    local parts={"RPPLATESTRACK2"}
    for _,scope in ipairs({"target","player"}) do
        for _,effect in ipairs({"buff","debuff","hidden"}) do
            for _,item in ipairs(SortedTracked(scope,effect)) do parts[#parts+1]=EncodeRule(scope,effect,item.id,item) end
        end
    end
    return table.concat(parts,"|")
end
local function DecodeTrackingV2(text)
    local parts={}; for part in (tostring(text or "").."|"):gmatch("(.-)|") do parts[#parts+1]=part end
    if parts[1]~="RPPLATESTRACK2" then return nil,"不是 RPPLATESTRACK2 追踪配置" end
    local result={target={buff={},debuff={},hidden={}},player={buff={},debuff={},hidden={}}}
    for i=2,#parts do if parts[i]~="" then
        local scope,effect,id,entry=DecodeRule(parts[i]); if scope==nil then return nil,"第 "..tostring(i-1).." 项无效："..tostring(effect) end
        result[scope][effect][id]=entry
    end end
    return result,nil,CountTracking(result)
end

local function BuildLayoutV1()
    local cfg=S:Get(); local parts={"RPPLATESLAYOUT1"}
    for _,scope in ipairs({"target","player"}) do
        local c=cfg[scope] or {}
        parts[#parts+1]=table.concat({"BASE",scope,BoolCode(c.enabled),tostring(c.width or 286),tostring(c.sectionGap or 4),tostring(c.offsetX or 0),tostring(c.offsetY or 0),Escape(c.anchorMode or "TOP"),BoolCode(c.showBuffs),BoolCode(c.showDebuffs),BoolCode(c.showHidden),BoolCode(c.trackedOnly)},"~")
        for _,effect in ipairs({"buff","debuff","hidden"}) do
            local l=type(c.effects)=="table" and c.effects[effect] or {}
            parts[#parts+1]=table.concat({"FX",scope,effect,tostring(l.iconSize or 24),tostring(l.fontSize or 10),tostring(l.maxCount or 8),tostring(l.columns or 6),tostring(l.gap or 2),tostring(l.rowGap or 2),Escape(l.direction or "RIGHT"),tostring(l.offsetX or 0),tostring(l.offsetY or 0),BoolCode(l.showDuration),BoolCode(l.showStack),BoolCode(l.showBorder),BoolCode(l.showTooltip),ColorHex(l.borderColor),BoolCode(l.expireEnabled),tostring(l.expireThreshold or 5),ColorHex(l.expireColor)},"~")
        end
    end
    for _,preset in ipairs(cfg.colorPresets or {}) do parts[#parts+1]="CP~"..Escape(preset.name).."~"..ColorHex(preset.color) end
    return table.concat(parts,"|")
end
local function DecodeLayoutV1(text)
    local parts={}; for part in (tostring(text or "").."|"):gmatch("(.-)|") do parts[#parts+1]=part end
    if parts[1]~="RPPLATESLAYOUT1" then return nil,"不是 RPPLATESLAYOUT1 布局配置" end
    local out={target={effects={}},player={effects={}},colorPresets={}}
    for i=2,#parts do if parts[i]~="" then
        local f={}; for x in (parts[i].."~"):gmatch("(.-)~") do f[#f+1]=x end
        if f[1]=="BASE" and (f[2]=="target" or f[2]=="player") then
            out[f[2]].enabled=DecodeBoolCode(f[3]);out[f[2]].width=tonumber(f[4]);out[f[2]].sectionGap=tonumber(f[5]);out[f[2]].offsetX=tonumber(f[6]);out[f[2]].offsetY=tonumber(f[7]);out[f[2]].anchorMode=Unescape(f[8]);out[f[2]].showBuffs=DecodeBoolCode(f[9]);out[f[2]].showDebuffs=DecodeBoolCode(f[10]);out[f[2]].showHidden=DecodeBoolCode(f[11]);out[f[2]].trackedOnly=DecodeBoolCode(f[12])
        elseif f[1]=="FX" and (f[2]=="target" or f[2]=="player") and (f[3]=="buff" or f[3]=="debuff" or f[3]=="hidden") then
            out[f[2]].effects[f[3]]={iconSize=tonumber(f[4]),fontSize=tonumber(f[5]),maxCount=tonumber(f[6]),columns=tonumber(f[7]),gap=tonumber(f[8]),rowGap=tonumber(f[9]),direction=Unescape(f[10]),offsetX=tonumber(f[11]),offsetY=tonumber(f[12]),showDuration=DecodeBoolCode(f[13]),showStack=DecodeBoolCode(f[14]),showBorder=DecodeBoolCode(f[15]),showTooltip=DecodeBoolCode(f[16]),borderColor=DecodeColorHex(f[17]),expireEnabled=DecodeBoolCode(f[18]),expireThreshold=tonumber(f[19]),expireColor=DecodeColorHex(f[20])}
        elseif f[1]=="CP" and f[2] and f[3] and #out.colorPresets<24 then out.colorPresets[#out.colorPresets+1]={name=Unescape(f[2]),color=DecodeColorHex(f[3])} end
    end end
    return out
end

local function DeepCopy(value,seen)
    if type(value)~="table" then return value end
    seen=seen or {}; if seen[value] then return seen[value] end
    local out={}; seen[value]=out; for k,v in pairs(value) do out[DeepCopy(k,seen)]=DeepCopy(v,seen) end; return out
end
local function ClampImportedNumber(value,minimum,maximum,fallback,integer)
    local n=tonumber(value);if n==nil then return fallback end
    n=math.max(minimum,math.min(maximum,n));if integer then n=math.floor(n+0.5) end;return n
end
local function ApplyLayoutDecoded(decoded)
    local cfg=S:Get()
    for _,scope in ipairs({"target","player"}) do
        local src,dst=decoded[scope],cfg[scope]
        if type(src)=="table" and type(dst)=="table" then
            if src.enabled~=nil then dst.enabled=src.enabled~=false end
            dst.width=ClampImportedNumber(src.width,230,460,dst.width,false)
            dst.sectionGap=ClampImportedNumber(src.sectionGap,0,20,dst.sectionGap,true)
            dst.offsetX=ClampImportedNumber(src.offsetX,-1200,1200,dst.offsetX,true)
            dst.offsetY=ClampImportedNumber(src.offsetY,-1200,1200,dst.offsetY,true)
            if src.anchorMode~=nil then dst.anchorMode=tostring(src.anchorMode)=="BOTTOM" and "BOTTOM" or "TOP" end
            if src.showBuffs~=nil then dst.showBuffs=src.showBuffs~=false end
            if src.showDebuffs~=nil then dst.showDebuffs=src.showDebuffs~=false end
            if src.showHidden~=nil then dst.showHidden=src.showHidden==true end
            if src.trackedOnly~=nil then dst.trackedOnly=src.trackedOnly==true end
            for _,effect in ipairs({"buff","debuff","hidden"}) do
                local sl=type(src.effects)=="table" and src.effects[effect] or nil
                local dl=type(dst.effects)=="table" and dst.effects[effect] or nil
                if type(sl)=="table" and type(dl)=="table" then
                    dl.iconSize=ClampImportedNumber(sl.iconSize,18,42,dl.iconSize,true)
                    dl.fontSize=ClampImportedNumber(sl.fontSize,8,18,dl.fontSize,true)
                    dl.maxCount=ClampImportedNumber(sl.maxCount,1,12,dl.maxCount,true)
                    dl.columns=ClampImportedNumber(sl.columns,1,12,dl.columns,true)
                    dl.gap=ClampImportedNumber(sl.gap,0,12,dl.gap,true)
                    dl.rowGap=ClampImportedNumber(sl.rowGap,0,12,dl.rowGap,true)
                    local direction=tostring(sl.direction or dl.direction or "RIGHT");dl.direction=(direction=="LEFT" or direction=="UP" or direction=="DOWN") and direction or "RIGHT"
                    dl.offsetX=ClampImportedNumber(sl.offsetX,-300,300,dl.offsetX,true)
                    dl.offsetY=ClampImportedNumber(sl.offsetY,-300,300,dl.offsetY,true)
                    if sl.showDuration~=nil then dl.showDuration=sl.showDuration~=false end
                    if sl.showStack~=nil then dl.showStack=sl.showStack~=false end
                    if sl.showBorder~=nil then dl.showBorder=sl.showBorder~=false end
                    if sl.showTooltip~=nil then dl.showTooltip=sl.showTooltip==true end
                    if type(sl.borderColor)=="table" then dl.borderColor=DeepCopy(sl.borderColor) end
                    if sl.expireEnabled~=nil then dl.expireEnabled=sl.expireEnabled==true end
                    dl.expireThreshold=ClampImportedNumber(sl.expireThreshold,1,60,dl.expireThreshold,true)
                    if type(sl.expireColor)=="table" then dl.expireColor=DeepCopy(sl.expireColor) end
                end
            end
        end
    end
    if type(decoded.colorPresets)=="table" then
        cfg.colorPresets={};for i,preset in ipairs(decoded.colorPresets) do if i>24 then break end;if type(preset)=="table" then cfg.colorPresets[#cfg.colorPresets+1]={name=tostring(preset.name or ""):sub(1,24),color=DeepCopy(preset.color)} end end
    end
end

local function AuraChecksum(text)
    local hash=7
    text=tostring(text or "")
    for i=1,#text do hash=(hash*131+string.byte(text,i))%2147483647 end
    return string.format("%08X",hash)
end

local function AuraMaskHex(mask)
    mask=math.max(0,math.min(15,math.floor(tonumber(mask) or 0)))
    return string.format("%X",mask)
end

local function ParseAuraRecord(record)
    local id,hex=tostring(record or ""):match("^(%d+):([%x])$")
    if id==nil then return nil,nil,"状态记录格式无效："..tostring(record) end
    local mask=tonumber(hex,16)
    if mask==nil or mask<1 or mask>15 then return nil,nil,"状态范围无效："..tostring(record) end
    return id,mask,nil
end

local function DecodeAuraChunk(text)
    local raw=tostring(text or ""):gsub("^%s+",""):gsub("%s+$",""):gsub("[\r\n\t]","")
    local batch,index,total,payload=raw:match("^"..AURA_LIBRARY_HEADER.."|([%x]+)|(%d+)/(%d+)|(.+)$")
    index,total=tonumber(index),tonumber(total)
    if batch==nil or index==nil or total==nil or payload==nil then return nil,"不是有效的 "..AURA_LIBRARY_HEADER.." 分片" end
    batch=string.upper(batch)
    if #batch~=8 then return nil,"状态库批次校验码无效" end
    if total<1 or total>999 or index<1 or index>total then return nil,"状态库分片序号无效" end
    if #payload>AURA_CHUNK_PAYLOAD_LIMIT+64 then return nil,"状态库分片异常过长" end
    local count=0
    for record in (payload..","):gmatch("(.-),") do
        if record=="" then return nil,"状态库分片包含空记录" end
        local id,mask,err=ParseAuraRecord(record);if id==nil then return nil,err end
        count=count+1
    end
    if count<=0 then return nil,"状态库分片为空" end
    return {batch=batch,index=index,total=total,payload=payload,count=count,raw=raw},nil
end

function M:ExportAuraLibraryChunks()
    if S==nil or type(S.GetAuraLibrary)~="function" then return nil,"状态库 Authority 不可用" end
    local rows={}
    for id,entry in pairs(S:GetAuraLibrary() or {}) do
        local key=tostring(id or "")
        local mask=type(entry)=="table" and tonumber(entry.mask or entry.m) or 0
        if key:match("^%d+$") and mask~=nil and mask>0 then rows[#rows+1]={id=key,mask=math.floor(mask)} end
    end
    table.sort(rows,function(a,b) local an,bn=tonumber(a.id),tonumber(b.id);if an~=bn then return an<bn end;return a.id<b.id end)
    if #rows<=0 then return nil,"状态库为空" end
    local records={};for _,row in ipairs(rows) do records[#records+1]=row.id..":"..AuraMaskHex(row.mask) end
    local canonical=table.concat(records,",")
    local batch=AuraChecksum(canonical)
    local payloads,cur={},""
    for _,record in ipairs(records) do
        local candidate=cur=="" and record or (cur..","..record)
        if cur~="" and #candidate>AURA_CHUNK_PAYLOAD_LIMIT then payloads[#payloads+1]=cur;cur=record else cur=candidate end
    end
    if cur~="" then payloads[#payloads+1]=cur end
    local chunks,total={},#payloads
    for i,payload in ipairs(payloads) do chunks[i]=AURA_LIBRARY_HEADER.."|"..batch.."|"..tostring(i).."/"..tostring(total).."|"..payload end
    return chunks,nil,{kind="aura_export",label="状态库",batch=batch,total=total,unique=#rows,characters=#canonical}
end

-- External backup/share payload.  The in-game import edit remains deliberately
-- chunk-safe, but clipboard export should be one logical message so the Message
-- widget copies one backing message instead of only a visible page of many
-- messages.  Every physical line is still a valid RPPLATESAURA3 chunk, so the
-- text can be archived verbatim and imported chunk-by-chunk on constrained RU
-- clients.
function M:ExportAuraLibraryCopyText()
    local chunks,err,info=self:ExportAuraLibraryChunks()
    if not chunks then return nil,err end
    local text=table.concat(chunks,"\n")
    info=info or {}
    info.clipboardCharacters=#text
    return text,nil,info,chunks
end

local function ExtractAuraChunks(text)
    local raw=tostring(text or ""):gsub("^\239\187\191","")
    local chunks={}
    -- Aura chunk payload is intentionally ASCII-only.  Searching by the header
    -- makes this tolerant of CR/LF, chat/editor wrapping and surrounding notes.
    for batch,index,total,payload in raw:gmatch(AURA_LIBRARY_HEADER.."|([0-9A-Fa-f]+)|(%d+)/(%d+)|([0-9A-Fa-f:,]+)") do
        chunks[#chunks+1]=AURA_LIBRARY_HEADER.."|"..string.upper(batch).."|"..index.."/"..total.."|"..payload
    end
    return chunks
end

function M:ResetAuraImportStage() self.auraImportStage=nil end

function M:StageAuraImportChunk(text)
    local chunk,err=DecodeAuraChunk(text);if chunk==nil then return nil,err end
    local stage=self.auraImportStage
    if type(stage)~="table" or stage.batch~=chunk.batch then
        stage={batch=chunk.batch,total=chunk.total,chunks={},received=0,complete=false,entries=nil,unique=0}
        self.auraImportStage=stage
    elseif stage.total~=chunk.total then
        return nil,"同一批次的总分片数不一致"
    end
    if stage.chunks[chunk.index]==nil then stage.received=stage.received+1 end
    stage.chunks[chunk.index]=chunk.payload
    stage.complete=stage.received==stage.total
    if stage.complete then
        local ordered={}
        for i=1,stage.total do if type(stage.chunks[i])~="string" then stage.complete=false;break end;ordered[#ordered+1]=stage.chunks[i] end
        if stage.complete then
            local canonical=table.concat(ordered,",")
            if AuraChecksum(canonical)~=stage.batch then
                stage.complete=false;stage.entries=nil
                return nil,"状态库分片已齐，但整批校验失败；请清空后重新复制这一批"
            end
            local entries,unique={},0
            for record in (canonical..","):gmatch("(.-),") do
                local id,mask,recordErr=ParseAuraRecord(record);if id==nil then stage.complete=false;stage.entries=nil;return nil,recordErr end
                if entries[id]~=nil then stage.complete=false;stage.entries=nil;return nil,"状态库出现重复 ID："..tostring(id) end
                entries[id]=mask;unique=unique+1
            end
            stage.entries,stage.unique=entries,unique
        end
    end
    return {kind="aura_stage",label="状态库分片",batch=stage.batch,received=stage.received,total=stage.total,complete=stage.complete,unique=stage.unique,current=chunk.index},nil
end

-- Accept one or many RPPLATESAURA3 chunks in a single paste.  This does not
-- weaken the commit fence: each extracted chunk still goes through the exact
-- DecodeAuraChunk + whole-batch checksum path above, and persistent state is
-- untouched until CommitAuraImport().
function M:StageAuraImportText(text)
    local chunks=ExtractAuraChunks(text)
    if #chunks<=0 then return nil,"没有识别到完整的状态库分片" end
    local last=nil
    for i=1,#chunks do
        local staged,err=self:StageAuraImportChunk(chunks[i])
        if not staged then return nil,"第 "..tostring(i).." 个分片失败："..tostring(err) end
        last=staged
    end
    if last then last.pasted=#chunks end
    return last,nil
end

function M:GetAuraImportStageInfo()
    local stage=self.auraImportStage
    if type(stage)~="table" then return nil end
    return {kind="aura_stage",label="状态库分片",batch=stage.batch,received=stage.received,total=stage.total,complete=stage.complete==true,unique=tonumber(stage.unique) or 0}
end

function M:CommitAuraImport(policy)
    local stage=self.auraImportStage
    if type(stage)~="table" or stage.complete~=true or type(stage.entries)~="table" then return false,"状态库分片尚未收齐或校验未通过" end
    local ok,err,summary=S:ImportAuraMasks(stage.entries,policy)
    if not ok then return false,err end
    local info={kind="aura_library",label="状态库",batch=stage.batch,unique=stage.unique,policy=policy=="replace" and "replace" or "merge",before=summary and summary.before or nil,after=summary and summary.after or nil}
    self.auraImportStage=nil
    if P.Runtime and P.Runtime.ForceAll then P.Runtime:ForceAll() end
    return true,nil,info
end

function M:ExportTracking() return BuildTrackingV2() end
function M:ExportLayout() return BuildLayoutV1() end
function M:ExportConfig() return "RPPLATESCFG2|"..Escape(BuildTrackingV2()).."|"..Escape(BuildLayoutV1()) end
function M:ExportRule(scope,effect,id)
    local entry=S:GetTracked(scope,effect)[tostring(id or "")]; if type(entry)~="table" then return nil,"请先选择一个已追踪状态" end
    return "RPPLATESRULE1|"..EncodeRule(scope,effect,tostring(id),entry)
end

function M:PreviewImportPackage(text)
    local raw=tostring(text or ""):gsub("^%s+",""):gsub("%s+$","")
    local auraChunks=ExtractAuraChunks(raw)
    if #auraChunks>1 then
        local first,err=DecodeAuraChunk(auraChunks[1]);if not first then return nil,err end
        return {kind="aura_chunks",label="状态库分片",batch=first.batch,pasted=#auraChunks,total=first.total}
    elseif #auraChunks==1 and raw:find(AURA_LIBRARY_HEADER,1,true) then
        local chunk,err=DecodeAuraChunk(auraChunks[1]);if not chunk then return nil,err end
        return {kind="aura_chunk",label="状态库分片",batch=chunk.batch,current=chunk.index,total=chunk.total,records=chunk.count}
    elseif raw:find("^RPPLATESCFG2|") then
        local a,b=raw:match("^RPPLATESCFG2|(.-)|(.*)$"); if not a then return nil,"完整配置格式损坏" end
        local tracking,err,counts=DecodeTrackingV2(Unescape(a)); if not tracking then return nil,err end
        local layout,lerr=DecodeLayoutV1(Unescape(b)); if not layout then return nil,lerr end
        return {kind="all",label="全部配置",counts=counts,hasTarget=true,hasPlayer=true,colorPresets=#(layout.colorPresets or {})}
    elseif raw:find("^RPPLATESTRACK2|") then local _,err,counts=DecodeTrackingV2(raw); if err then return nil,err end; return {kind="tracking",label="追踪列表",counts=counts}
    elseif raw:find("^RPPLATESLAYOUT1|") then local layout,err=DecodeLayoutV1(raw); if not layout then return nil,err end; return {kind="layout",label="外观布局",hasTarget=true,hasPlayer=true,colorPresets=#(layout.colorPresets or {})}
    elseif raw:find("^RPPLATESRULE1|") then local row=raw:sub(#"RPPLATESRULE1|"+1); local scope,effect,id,entry=DecodeRule(row); if not scope then return nil,effect end; return {kind="rule",label="单个规则",scope=scope,effect=effect,id=id,name=entry.name}
    elseif raw:find(COMPACT_AURA_HEADER,1,true) then local decoded,err,counts=DecodeImportAll(raw); if not decoded then return nil,err end; return {kind="legacy",label="职业技能状态追踪",counts=counts,compact=true}
    elseif raw:find("RPPLATESALL1",1,true) then local decoded,err,counts=DecodeImportAll(raw); if not decoded then return nil,err end; return {kind="legacy",label="旧版追踪配置",counts=counts}
    end
    return nil,"无法识别导入格式"
end

function M:ImportPackage(text)
    local preview,perr=self:PreviewImportPackage(text); if not preview then return false,perr end
    local raw=tostring(text or ""):gsub("^%s+",""):gsub("%s+$","")
    if preview.kind=="aura_chunk" then return false,"这是状态库分片，请先点击“解析导入”暂存全部分片，再确认导入" end
    if preview.kind=="legacy" then return self:ImportAll(raw) end
    local cfg=S:Get(); local snapshot=DeepCopy(cfg)
    local oldDirty,oldTrackingDirty,oldAuraDirty=S.dirty,S.trackingDirty,S.auraDirty
    local trackingChanged=false
    local function rollback(err)
        S.settings=snapshot;S.dirty=oldDirty;S.trackingDirty=oldTrackingDirty;S.auraDirty=oldAuraDirty
        return false,err
    end
    if preview.kind=="all" then
        local ta,tb=raw:match("^RPPLATESCFG2|(.-)|(.*)$")
        local tracking,err=DecodeTrackingV2(Unescape(ta)); if not tracking then return false,err end
        local layout,lerr=DecodeLayoutV1(Unescape(tb)); if not layout then return false,lerr end
        local adopted,adoptErr=S:AdoptTracking(tracking);if not adopted then return false,adoptErr end
        ApplyLayoutDecoded(layout);trackingChanged=true
    elseif preview.kind=="tracking" then
        local tracking,err=DecodeTrackingV2(raw); if not tracking then return false,err end
        local adopted,adoptErr=S:AdoptTracking(tracking);if not adopted then return false,adoptErr end
        trackingChanged=true
    elseif preview.kind=="layout" then
        local layout,err=DecodeLayoutV1(raw); if not layout then return false,err end
        ApplyLayoutDecoded(layout);S:MarkDirty()
    elseif preview.kind=="rule" then
        local scope,effect,id,entry=DecodeRule(raw:sub(#"RPPLATESRULE1|"+1)); if not scope then return false,effect end
        if effect=="buff" or effect=="debuff" then
            local effective=DeepCopy(cfg.tracking);effective[scope][effect][id]=entry
            local adopted,adoptErr=S:AdoptTracking(effective);if not adopted then return false,adoptErr end
        else
            cfg.tracking[scope][effect][id]=entry;S:MarkTrackingDirty()
        end
        trackingChanged=true
    end
    if trackingChanged~=true and preview.kind~="layout" then S:MarkDirty() end
    local ok,err=S:Save(true); if not ok then return rollback("保存失败："..tostring(err or "unknown")) end
    if P.Runtime and P.Runtime.ForceAll then P.Runtime:ForceAll() end
    return true,nil,preview
end

function M:SearchKnown(query,effectType,limit)
    query=tostring(query or ""):gsub("^%s+",""):gsub("%s+$",""); effectType=tostring(effectType or "buff"); limit=math.max(1,math.min(50,math.floor(tonumber(limit) or 20)))
    local lower=string.lower(query); local result={}
    for _,source in ipairs(CORE_PRESET[effectType] or {}) do
        local id,name=tostring(source[1] or ""),tostring(source[2] or "")
        if query=="" or id==query or id:find(query,1,true) or string.lower(name):find(lower,1,true) then
            local entry=ResolvePresetEntry(effectType,id,name,source[3]); result[#result+1]={id=id,name=entry.name,iconPath=entry.iconPath,category=entry.category,effectType=effectType,trackable=true}
            if #result>=limit then break end
        end
    end
    return result
end

function M:ImportCorePreset()
    -- Seed from the current wiki-scraped SkillEffects library (rs_skill_effects.lua)
    -- instead of the legacy CORE_PRESET hand-picked list. Import is REPLACE (not
    -- merge): the preset fully overwrites the current tracking so stale IDs from a
    -- previous import never linger. If the data table is missing it errors loudly
    -- instead of silently falling back to the legacy RU_CORE_V7 list.
    return self:ImportAll(SKILL_EFFECT_PRESET_TOKEN, true)
end

------------------------------------------------------------------------
-- Buff manager
------------------------------------------------------------------------
-- The consolidated Suite owns settings/navigation.  Discovery helpers above
-- remain active, but no legacy manager/layout windows are allocated in embedded
-- mode. This removes a second UI Authority and several old-window boot hazards.
if ReplicatedSuiteEmbedded == true then
    function M:IsOpen() return false end
    function M:RuntimeRefresh() return end
    function M:Open()
        if ReplicatedSuite ~= nil and ReplicatedSuite.UI ~= nil then ReplicatedSuite.UI:ShowPage("plates"); return true end
        return false
    end
    function M:OpenHUDLayout(scope) return self:Open() end
    function M:OpenAdvanced() return self:Open() end
    function M:OpenAux() return self:Open() end
    function M:Refresh() end
    function M:RefreshHUDLayout() end
    function M:RefreshAdvanced() end
    function M:RefreshAux() end
    function M:HideAll() end
    return
end

local manager, managerHeader = Window("effect_manager", 720, 610, "manager")
M.windows.manager = manager
Label(managerHeader, "manager_title", "Buff / Debuff 追踪管理", 14, 7, 330, 24, 14, ALIGN_LEFT)
local managerClose = Button(managerHeader, "manager_close", "X", 676, 6, 32, 27, 13)
SafeHandler(managerClose,"OnClick",function() manager:Show(false) end,"manager:close")

Label(manager,"manager_help","扫描/追加当前效果；PVP发现只记录候选，不会自动显示，也不会自动加入追踪。",16,50,680,22,10,ALIGN_LEFT).style:SetColor(0.66,0.78,0.88,1)

local scopeButtons = {}
for i,scope in ipairs({"target","player"}) do
    local scopeKey = scope
    local b=Button(manager,"manager_scope_"..scopeKey,SCOPE_META[scopeKey].title,16+(i-1)*92,80,84,26,10); scopeButtons[scopeKey]=b
    SafeHandler(b,"OnClick",function()
        local _,effect=Active()
        M.frozen=false; M.frozenScope=nil; M.frozenEffect=nil
        if not SaveActive(scopeKey,effect) then return end
        M.runtimePolls=0; M.catalogRawCount=nil
        M:Refresh(true)
        if P.Runtime and P.Runtime.ForceScope then P.Runtime:ForceScope(scopeKey) end
    end,"manager:scope:"..scopeKey)
end
local effectButtons={}
for i,effect in ipairs({"buff","debuff","hidden"}) do
    local effectKey = effect
    local b=Button(manager,"manager_effect_"..effectKey,EFFECT_META[effectKey].title,218+(i-1)*92,80,84,26,10); effectButtons[effectKey]=b
    SafeHandler(b,"OnClick",function()
        local scope=Active()
        M.frozen=false; M.frozenScope=nil; M.frozenEffect=nil
        SaveActive(scope,effectKey); M:Refresh()
    end,"manager:effect:"..effectKey)
end
local trackedOnlyButton=Button(manager,"manager_tracked_only","只追踪：关",500,80,98,26,9)
local autoPvPButton=Button(manager,"manager_auto_pvp","PVP发现：开",604,80,100,26,9)
SafeHandler(trackedOnlyButton,"OnClick",function()
    local scope=Active(); local cfg=S:Get()[scope]; local oldValue, oldDirty=cfg.trackedOnly,S.dirty
    cfg.trackedOnly=not cfg.trackedOnly; S:MarkDirty()
    local ok,err=S:Save(true)
    if not ok then cfg.trackedOnly=oldValue; S.dirty=oldDirty; P.SafeChat("保存追踪显示模式失败："..tostring(err or "unknown")); M:Refresh(false); return end
    if P.Runtime and P.Runtime.ForceScope then P.Runtime:ForceScope(scope) end; M:Refresh(false)
end,"manager:tracked_only")
SafeHandler(autoPvPButton,"OnClick",function()
    local scope=Active(); local cfg=S:Get()[scope]; local oldValue,oldDirty=cfg.autoPvPRelevant,S.dirty
    cfg.autoPvPRelevant=not (cfg.autoPvPRelevant==true); S:MarkDirty()
    local ok,err=S:Save(true)
    if not ok then cfg.autoPvPRelevant=oldValue; S.dirty=oldDirty; P.SafeChat("保存自动PVP识别失败："..tostring(err or "unknown")); M:Refresh(false); return end
    if P.Runtime and P.Runtime.ForceScope then P.Runtime:ForceScope(scope) end; M:Refresh(false)
end,"manager:auto_pvp")

local sectionTracked=Label(manager,"manager_tracked_title","已追踪",16,121,330,24,11,ALIGN_LEFT)
local sectionLive=Label(manager,"manager_live_title","当前检测到",374,121,330,24,11,ALIGN_LEFT)
sectionTracked.style:SetColor(0.55,0.86,1,1); sectionLive.style:SetColor(0.55,0.86,1,1)

local function CreateRow(prefix,x,y,width,actionText)
    local row={}
    row.frame=manager:CreateChildWidget("emptywidget",P.PhysicalId(prefix.."_frame"),0,true); row.frame:AddAnchor("TOPLEFT",manager,x,y); row.frame:SetExtent(width,40); row.frame:Show(false); SetPick(row.frame,true)
    CreateBackground(row.frame,0.028,0.045,0.064,0.94,"background")
    row.icon=row.frame:CreateIconDrawable("artwork"); row.icon:SetExtent(30,30); row.icon:AddAnchor("TOPLEFT",row.frame,5,5); row.icon:SetVisible(false)
    row.label=Label(row.frame,prefix.."_label","",42,3,width-122,34,10,ALIGN_LEFT)
    row.button=Button(row.frame,prefix.."_button",actionText,width-74,7,68,26,9)
    return row
end
for i=1,8 do
    local rowIndex = i
    M.trackedRows[rowIndex]=CreateRow("tracked_row_"..rowIndex,16,150+(rowIndex-1)*43,330,"删除")
    M.liveRows[rowIndex]=CreateRow("live_row_"..rowIndex,374,150+(rowIndex-1)*43,330,"追加")
    SafeHandler(M.trackedRows[rowIndex].button,"OnClick",function()
        local row=M.trackedRows[rowIndex]; if row.entry==nil then return end; local scope,effect=Active(); local ok,err=S:RemoveTracked(scope,effect,row.entry.id); if not ok then P.SafeChat("删除追踪失败："..tostring(err or "unknown")); return end; if P.Runtime and P.Runtime.ForceScope then P.Runtime:ForceScope(scope) end; M:Refresh(false)
    end,"tracked:remove:"..rowIndex)
    SafeHandler(M.liveRows[rowIndex].button,"OnClick",function()
        local row=M.liveRows[rowIndex]; if row.entry==nil then return end
        local scope,effect=Active()
        local trackedNow=S:IsTracked(scope,effect,row.entry.id)
        local ok,err
        if trackedNow then
            ok,err=S:RemoveTracked(scope,effect,row.entry.id)
            if not ok then P.SafeChat("取消追踪失败："..tostring(err or "unknown")); return end
        else
            ok,err=S:AddTracked(scope,effect,row.entry.id,row.entry)
            if not ok then P.SafeChat("追加追踪失败："..tostring(err or "unknown")); return end
            M:ForgetDiscovered(scope,effect,row.entry.id)
        end
        if P.Runtime and P.Runtime.ForceScope then P.Runtime:ForceScope(scope) end
        M:Refresh(false)
    end,"live:toggle:"..rowIndex)
end

local trackedPrev=Button(manager,"tracked_prev","<",16,502,32,25,10); local trackedPage=Label(manager,"tracked_page","1/1",52,504,60,22,9,ALIGN_CENTER); local trackedNext=Button(manager,"tracked_next",">",116,502,32,25,10)
local livePrev=Button(manager,"live_prev","<",374,502,32,25,10); local livePage=Label(manager,"live_page","1/1",410,504,60,22,9,ALIGN_CENTER); local liveNext=Button(manager,"live_next",">",474,502,32,25,10)
local discoveryButton=Button(manager,"manager_discovery","实战发现(0)",514,502,110,25,8)
local clearDiscoveryButton=Button(manager,"manager_discovery_clear","清空发现",630,502,74,25,8)
SafeHandler(trackedPrev,"OnClick",function() M.activePage.tracked=M.activePage.tracked-1;M:Refresh(false) end,"tracked:prev")
SafeHandler(trackedNext,"OnClick",function() M.activePage.tracked=M.activePage.tracked+1;M:Refresh(false) end,"tracked:next")
SafeHandler(livePrev,"OnClick",function() M.activePage.live=M.activePage.live-1;M:Refresh(false) end,"live:prev")
SafeHandler(liveNext,"OnClick",function() M.activePage.live=M.activePage.live+1;M:Refresh(false) end,"live:next")
SafeHandler(discoveryButton,"OnClick",function()
    M.catalogMode=M.catalogMode=="discovered" and "live" or "discovered"
    M.activePage.live=1
    M:Refresh(M.catalogMode=="live")
end,"manager:discovery")
SafeHandler(clearDiscoveryButton,"OnClick",function()
    local scope,effect=Active()
    M:ClearDiscovered(scope,effect)
    M:Refresh(false)
end,"manager:discovery_clear")

Label(manager,"manual_id_label","效果 ID",16,548,54,24,10,ALIGN_LEFT)
local idEdit=EditBox(manager,"manual_id",72,546,116)
local idAdd=Button(manager,"manual_add","按 ID 追加",196,546,96,26,9)
local categoryButton=Button(manager,"manager_category","分类:全部",300,546,68,26,8)
local freezeButton=Button(manager,"manager_freeze","冻结：关",374,546,82,26,9)
local scan=Button(manager,"manager_scan","重新扫描",462,546,82,26,9)
local exportButton=Button(manager,"manager_export","导出全部",550,546,70,26,8)
local importButton=Button(manager,"manager_import","导入全部",626,546,70,26,8)
if idEdit==nil then
    idAdd:Enable(false)
    P.SafeChat("Buff 管理：当前客户端文本输入控件不可用，手动 ID 输入已禁用；扫描/追加/删除仍可使用。")
end
SafeHandler(idAdd,"OnClick",function()
    if idEdit==nil then P.SafeChat("当前客户端无法创建效果 ID 输入框。") return end
    local rawText=""
    if type(idEdit.GetText)=="function" then rawText=tostring(idEdit:GetText() or "") end
    local id=rawText:match("^%s*(%d+)%s*$")
    if id==nil or id=="" then
        P.SafeChat("请先在左侧输入数字效果 ID。")
        if type(idEdit.SetFocus)=="function" then pcall(function() idEdit:SetFocus() end) end
        return
    end
    local scope,effect=Active()
    local entry=nil
    for _,live in ipairs(M.catalog or {}) do
        if tostring(live.id or "")==id then entry={name=tostring(live.name or ""),iconPath=tostring(live.iconPath or ""),category=tostring(live.category or ClassifyCombatEffect(effect,live.name,"",nil))} break end
    end
    if entry==nil and A~=nil and type(A.ResolveTrackedEntry)=="function" then
        entry=ResolvePresetEntry(effect,id,"手动 ID "..id,nil)
    end
    if type(entry)~="table" then entry={name="手动 ID "..id,iconPath=PRESET_FALLBACK_ICONS[effect] or "ui/icon/icon_unknown_item.dds",category="OTHER"} end
    local ok,err=S:AddTracked(scope,effect,id,entry)
    if not ok then
        P.SafeChat("按 ID 追加失败："..tostring(err or "unknown"))
        return
    end
    M:ForgetDiscovered(scope,effect,id)
    idEdit:SetText("")
    if type(idEdit.ClearFocus)=="function" then pcall(function() idEdit:ClearFocus() end) end
    if P.Runtime and P.Runtime.ForceScope then P.Runtime:ForceScope(scope) end
    M:Refresh(false)
    P.SafeChat("已追加 "..SCOPE_META[scope].title.." / "..EFFECT_META[effect].title.." ID "..id)
end,"manual:add")

local function MergeDetectedCatalog(additions)
    additions = type(additions) == "table" and additions or {}
    local byId, merged = {}, {}
    for _, entry in ipairs(M.catalog or {}) do
        if type(entry) == "table" and entry.id ~= nil then byId[tostring(entry.id)] = entry end
    end
    for _, entry in ipairs(additions) do
        if type(entry) == "table" and entry.id ~= nil then byId[tostring(entry.id)] = entry end
    end
    for _, entry in pairs(byId) do merged[#merged + 1] = entry end
    table.sort(merged, function(left, right)
        local a, b = tostring(left and left.name or ""), tostring(right and right.name or "")
        if a == b then
            local leftId, rightId = tonumber(left and left.id), tonumber(right and right.id)
            if leftId ~= nil and rightId ~= nil and leftId ~= rightId then return leftId < rightId end
            return tostring(left and left.id or "") < tostring(right and right.id or "")
        end
        return a < b
    end)
    local changed = #merged ~= #(M.catalog or {})
    M.catalog = merged
    return changed
end

SafeHandler(categoryButton,"OnClick",function()
    local current=tostring(M.categoryFilter or "ALL")
    local index=1
    for i,key in ipairs(CATEGORY_ORDER) do if key==current then index=i break end end
    index=index+1; if index>#CATEGORY_ORDER then index=1 end
    M.categoryFilter=CATEGORY_ORDER[index]
    M.activePage.tracked,M.activePage.live=1,1
    M:Refresh(false)
end,"manager:category")

SafeHandler(freezeButton,"OnClick",function()
    if not ModuleRuntimeEnabled() then P.SafeChat("BUFF显示模块当前未启用；冻结捕获属于 Runtime 动作。") return end
    M.catalogMode="live"
    local scope,effect=Active()
    if M.frozen==true and M.frozenScope==scope and M.frozenEffect==effect then
        M.frozen=false; M.frozenScope=nil; M.frozenEffect=nil
        M.runtimePolls=0; M.catalogRawCount=nil
        M:Refresh(true)
        return
    end
    -- Capture a fresh snapshot, then hold it even after the live aura expires.
    M:Refresh(true)
    M.frozen=true; M.frozenScope=scope; M.frozenEffect=effect
    M:Refresh(false)
end,"manager:freeze")
SafeHandler(scan,"OnClick",function()
    if not ModuleRuntimeEnabled() then P.SafeChat("BUFF显示模块当前未启用；重新扫描属于 Runtime 动作。") return end
    M.catalogMode="live"
    if M.frozen==true then
        local scope,effect=Active()
        MergeDetectedCatalog(A:GetEffectCatalog(SCOPE_META[scope].unit,effect,96))
        M:Refresh(false)
        return
    end
    M:Refresh(true)
end,"manager:scan")

function M:Refresh(rescan)
    local scope,effect=Active(); local cfg=S:Get()[scope]
    local runtimeEnabled=ModuleRuntimeEnabled()
    local counts={}
    for key,_ in pairs(EFFECT_META) do counts[key]=runtimeEnabled and A:GetEffectCount(SCOPE_META[scope].unit,key) or 0 end
    for key,b in pairs(scopeButtons) do b:SetText((key==scope and "[选] " or "")..SCOPE_META[key].title) end
    for key,b in pairs(effectButtons) do
        b:SetText((key==effect and "[选] " or "")..EFFECT_META[key].title.." ("..tostring(counts[key] or 0)..")")
        b:Enable(true)
    end
    trackedOnlyButton:SetText(cfg.trackedOnly and "只追踪：开" or "只追踪：关")
    autoPvPButton:SetText(cfg.autoPvPRelevant==true and "PVP发现：开" or "PVP发现：关")
    categoryButton:SetText("分类:"..CategoryTitle(self.categoryFilter or "ALL"))

    local discovered=self:GetDiscoveryList(scope,effect)
    local discoveredCount=#discovered
    local discoveryMode=self.catalogMode=="discovered"
    discoveryButton:SetText((discoveryMode and "[选] " or "").."实战发现("..tostring(discoveredCount)..")")
    clearDiscoveryButton:Enable(discoveredCount>0)

    local frozenHere=self.frozen==true and self.frozenScope==scope and self.frozenEffect==effect
    freezeButton:SetText(frozenHere and "冻结：开" or "冻结：关")
    freezeButton:Enable(runtimeEnabled and not discoveryMode)
    scan:Enable(runtimeEnabled and not discoveryMode)

    local title=SCOPE_META[scope].title.." / "..EFFECT_META[effect].title
    sectionTracked:SetText("已追踪 · "..title.."（"..tostring(S:TrackedCount(scope,effect)).."）")

    local live={}
    if discoveryMode then
        sectionLive:SetText("实战发现 · "..title.."（"..tostring(discoveredCount).."）")
        live=discovered
    else
        sectionLive:SetText((not runtimeEnabled and "模块未启用 · " or (frozenHere and "已冻结 · " or "当前检测到 · "))..title.."（"..tostring(runtimeEnabled and (frozenHere and #(self.catalog or {}) or (counts[effect] or 0)) or 0).."）")
        if runtimeEnabled and not frozenHere and (rescan~=false or self.catalogScope~=scope or self.catalogEffect~=effect) then
            self.catalog=A:GetEffectCatalog(SCOPE_META[scope].unit,effect,96)
            self.catalogScope,self.catalogEffect=scope,effect
            self.catalogRawCount=counts[effect] or 0
        end
        live=runtimeEnabled and (self.catalog or {}) or {}
    end

    local tracked=SortedTracked(scope,effect)
    local function FilterCategory(data)
        local filter=tostring(self.categoryFilter or "ALL")
        if filter=="ALL" then return data end
        local filtered={}
        for _,entry in ipairs(data or {}) do
            local category=tostring(entry.category or "")
            if category=="" then category=ClassifyCombatEffect(effect,entry.name,"",nil); entry.category=category end
            if category==filter then filtered[#filtered+1]=entry end
        end
        return filtered
    end
    tracked=FilterCategory(tracked)
    live=FilterCategory(live)
    local function Render(rows,data,page,label)
        local pages=math.max(1,math.ceil(#data/#rows)); page=math.max(1,math.min(pages,page)); label:SetText(tostring(page).."/"..tostring(pages))
        local first=(page-1)*#rows+1
        for i,row in ipairs(rows) do
            local entry=data[first+i-1]; row.entry=entry
            if entry==nil then row.frame:Show(false) else
                SetIcon(row,entry.iconPath)
                local name=entry.name~="" and entry.name or "未命名效果"
                local category=tostring(entry.category or "")
                if category=="" then category=ClassifyCombatEffect(effect,name,"",nil); entry.category=category end
                row.label:SetText("["..CategoryTitle(category).."] "..name.."\nID "..entry.id); row.frame:Show(true)
                if rows==self.liveRows then
                    local trackedNow=S:IsTracked(scope,effect,entry.id)
                    row.button:SetText(trackedNow and "取消追踪" or "追踪")
                    row.button:Enable(true)
                else
                    row.button:Enable(true)
                end
            end
        end
        return page
    end
    self.activePage.tracked=Render(self.trackedRows,tracked,self.activePage.tracked,trackedPage)
    self.activePage.live=Render(self.liveRows,live,self.activePage.live,livePage)
end

function M:IsOpen()
    if manager==nil or type(manager.IsVisible)~="function" then return false end
    local ok,value=pcall(function() return manager:IsVisible() end)
    return ok and value==true
end

function M:RuntimeRefresh()
    if not self:IsOpen() or not ModuleRuntimeEnabled() then return end
    local scope,effect=Active()
    if self.catalogMode=="discovered" then
        self:Refresh(false)
        return
    end
    if self.frozen==true and self.frozenScope==scope and self.frozenEffect==effect then
        -- Freeze is an accumulating capture mode, not a paused scanner: keep
        -- detecting every 200ms, merge newly seen IDs into the catalog, and never
        -- remove an entry merely because the short aura has already expired.
        local additions=A:GetEffectCatalog(SCOPE_META[scope].unit,effect,96)
        MergeDetectedCatalog(additions)
        self.catalogRawCount=A:GetEffectCount(SCOPE_META[scope].unit,effect)
        self:Refresh(false)
        return
    end
    self.runtimePolls=(tonumber(self.runtimePolls) or 0)+1
    local count=A:GetEffectCount(SCOPE_META[scope].unit,effect)
    local mustDeep=self.catalogScope~=scope or self.catalogEffect~=effect or tonumber(self.catalogRawCount)~=tonumber(count)
    -- Count can stay identical when one aura replaces another. Deep-refresh once
    -- per second as a safety net while keeping the 200ms path count-only.
    if self.runtimePolls%5==0 then mustDeep=true end
    self:Refresh(mustDeep)
end

function M:Open()
    manager:Show(true); if manager.Raise~=nil then manager:Raise() end
    self.frozen=false; self.frozenScope=nil; self.frozenEffect=nil
    self.catalogMode="live"
    -- Upgrade old/manual rows that were saved without icon metadata. Resolve in
    -- one batch and persist once, rather than writing once per id.
    local tracking=S:Get().tracking
    if EnrichTrackingMetadata(tracking) then
        S:MarkTrackingDirty()
        local ok,err=S:Save(true)
        if not ok then P.SafeChat("Buff 图标补全保存失败："..tostring(err or "unknown")) end
    end
    self.runtimePolls=0; self.catalogRawCount=nil; self:Refresh(true)
end

------------------------------------------------------------------------
-- Import / export
------------------------------------------------------------------------
local transfer, transferHeader=Window("transfer",600,430,"transfer"); M.windows.transfer=transfer
local transferTitle=Label(transferHeader,"transfer_title","导出",14,7,420,24,14,ALIGN_LEFT)
local transferClose=Button(transferHeader,"transfer_close","X",556,6,32,27,13)
SafeHandler(transferClose,"OnClick",function() transfer:Show(false) end,"transfer:close")
local transferHint=Label(transfer,"transfer_hint","",16,54,568,40,9,ALIGN_LEFT); transferHint.style:SetColor(0.66,0.78,0.88,1)
local transferEdit=MultiEdit(transfer,"transfer_edit",16,100,568,260)
local transferSingleLineFallback=false
if transferEdit==nil then
    -- Some RU client builds expose EDITBOX_MULTILINE in the object table but
    -- fail to instantiate it at runtime. RPPLATESALL1 is intentionally a
    -- single-line transport format, so fall back to the proven X2 edit box
    -- instead of silently disabling Import/Export.
    transferEdit=EditBox(transfer,"transfer_edit_fallback",16,100,568)
    if transferEdit~=nil then
        transferSingleLineFallback=true
        if transferEdit.SetMaxTextLength~=nil then pcall(function() transferEdit:SetMaxTextLength(65535) end) end
    end
end
local transferPreset=Button(transfer,"transfer_preset","导入内置实战库",96,378,120,30,10)
local transferAction=Button(transfer,"transfer_action","关闭",240,378,120,30,10); local transferMode="export"
transferPreset:Show(false)
if transferEdit==nil then
    exportButton:Enable(false)
    transferHint:SetText("当前客户端无法创建文本输入控件；自定义导入/导出不可用，但“导入内置实战库”仍可使用（将以新库覆盖当前追踪）。")
end
SafeHandler(transferPreset,"OnClick",function()
    local ok,err,counts=M:ImportCorePreset()
    if not ok then
        P.SafeChat("实战库导入失败："..tostring(err))
        return
    end
    transfer:Show(false)
    M:Refresh(true)
    if counts~=nil then
        P.SafeChat(string.format(
            "内置实战库已覆盖：当前共 %d 条（目标 Buff %d / Debuff %d / Hidden %d；自己 Buff %d / Debuff %d / Hidden %d）。",
            counts.total,counts.target.buff,counts.target.debuff,counts.target.hidden,counts.player.buff,counts.player.debuff,counts.player.hidden
        ))
    else
        P.SafeChat("内置实战库已覆盖，追踪列表已刷新。")
    end
end,"transfer:preset")
SafeHandler(transferAction,"OnClick",function()
    if transferMode=="export" then transfer:Show(false); return end
    if transferEdit==nil then transfer:Show(false); return end
    local raw=type(transferEdit.GetText)=="function" and tostring(transferEdit:GetText() or "") or ""
    if raw:match("^%s*$") then P.SafeChat("请先粘贴 RPPLATESALL1 全量字符串，再点确认导入。") return end
    local ok,err,counts=M:ImportAll(raw)
    if not ok then P.SafeChat("导入失败："..tostring(err)); return end
    transfer:Show(false); M:Refresh(true)
    if counts~=nil then
        P.SafeChat(string.format(
            "导入成功：共 %d 条（目标 Buff %d / Debuff %d / Hidden %d；自己 Buff %d / Debuff %d / Hidden %d）。",
            counts.total,counts.target.buff,counts.target.debuff,counts.target.hidden,counts.player.buff,counts.player.debuff,counts.player.hidden
        ))
    else
        P.SafeChat("导入成功，追踪列表已刷新。")
    end
end,"transfer:action")
SafeHandler(exportButton,"OnClick",function()
    if transferEdit==nil then P.SafeChat("当前客户端无法创建导出文本框。") return end
    transferMode="export"; transferTitle:SetText("导出全部追踪配置"); transferPreset:Show(false)
    if transferSingleLineFallback then
        transferHint:SetText("当前客户端使用单行兼容输入框。点击输入框后 Ctrl+A / Ctrl+C 复制整段 RPPLATESALL1。")
    else
        transferHint:SetText("Ctrl+A / Ctrl+C 复制这一整段 RPPLATESALL1。目标/自己的 Buff、Debuff、Hidden 与分类会一次性带走。")
    end
    transferEdit:SetText(M:ExportAll()); transferAction:SetText("关闭"); transfer:Show(true); if transfer.Raise~=nil then transfer:Raise() end
end,"manager:export")
SafeHandler(importButton,"OnClick",function()
    transferMode="import"; transferTitle:SetText("导入全部追踪配置"); transferPreset:Show(true)
    if transferEdit==nil then
        transferHint:SetText("当前客户端文本输入框不可用。可直接点“导入内置实战库”，会用新库覆盖当前追踪。")
        transferAction:SetText("关闭")
    elseif transferSingleLineFallback then
        transferHint:SetText("RU 客户端长文本会被截断。推荐直接点“导入内置实战库”（覆盖当前追踪）；自定义短配置仍可粘贴后确认导入。")
        transferEdit:SetText(""); transferAction:SetText("确认导入")
    else
        transferHint:SetText("可粘贴 RPPLATESALL1 / RPPLATESPRESET1；也可直接点“导入内置实战库”以新库覆盖当前追踪。")
        transferEdit:SetText(""); transferAction:SetText("确认导入")
    end
    transfer:Show(true); if transfer.Raise~=nil then transfer:Raise() end
    P.SafeChat("导入窗口已打开：推荐直接点“导入内置实战库”（覆盖当前追踪）。")
end,"manager:import")

------------------------------------------------------------------------
-- HUD layout information - the only layout editor in v0.4.0.
-- Old Advanced + Auxiliary windows were intentionally merged here.
------------------------------------------------------------------------
local hud,hudHeader=Window("hud_layout",760,720,"hudLayout"); M.windows.hudLayout=hud
Label(hudHeader,"hud_layout_title","HUD布局信息",14,7,420,24,14,ALIGN_LEFT)
local hudClose=Button(hudHeader,"hud_layout_close","X",716,6,32,27,13)
SafeHandler(hudClose,"OnClick",function() hud:Show(false); if U.layoutEditScope~=nil then U:SetLayoutEdit(nil) end end,"hud_layout:close")
local hudHelp=Label(hud,"hud_layout_help","所有 Plates HUD 布局都在这一页。目标默认固定底部安全边界；Buff/Debuff 增加时整块向上扩展。",16,50,728,24,10,ALIGN_LEFT)
hudHelp.style:SetColor(0.66,0.82,0.92,1)

local hudScope="target"
local hudComponent="overall"
local hudScopeButtons={}
local HUD_COMPONENTS={
    {key="overall",text="整体"},{key="class",text="职业"},{key="gear",text="装等"},{key="loadout",text="甲胄/武器"},{key="distance",text="距离"},{key="buff",text="Buff"},
    {key="debuff",text="Debuff"},{key="hidden",text="Hidden"},{key="cast",text="施法"},{key="equipment",text="装备"},{key="cooldown",text="重要冷却"},{key="targetOfTarget",text="目标的目标"},
}
local hudComponentButtons={}
local function HudComponentAvailable(scope,key)
    if key=="overall" or key=="buff" or key=="debuff" then return true end
    if scope=="target" then return key=="class" or key=="gear" or key=="loadout" or key=="distance" or key=="hidden" or key=="cast" or key=="targetOfTarget" end
    if scope=="player" then return key=="hidden" or key=="equipment" or key=="cooldown" end
    return false
end
local function FirstHudComponent(scope)
    return "overall"
end

for i,scope in ipairs({"target","player"}) do
    local scopeKey=scope
    local b=Button(hud,"hud_scope_"..scopeKey,SCOPE_META[scopeKey].title,16+(i-1)*116,82,108,28,10)
    hudScopeButtons[scopeKey]=b
    SafeHandler(b,"OnClick",function()
        hudScope=scopeKey
        if not HudComponentAvailable(hudScope,hudComponent) then hudComponent=FirstHudComponent(hudScope) end
        M:RefreshHUDLayout()
    end,"hud:scope:"..scopeKey)
end

for i,def in ipairs(HUD_COMPONENTS) do
    local key=def.key
    local row=math.floor((i-1)/6)
    local col=(i-1)%6
    local b=Button(hud,"hud_component_"..key,def.text,16+col*120,122+row*34,112,28,9)
    hudComponentButtons[key]=b
    SafeHandler(b,"OnClick",function()
        if not HudComponentAvailable(hudScope,key) then return end
        hudComponent=key
        if U.layoutEditScope==hudScope then
            U:SetLayoutEdit(hudScope,hudComponent=="overall" and nil or hudComponent)
        end
        M:RefreshHUDLayout()
    end,"hud:component:"..key)
end

local hudSummary=Label(hud,"hud_summary","",18,194,590,26,11,ALIGN_LEFT)
hudSummary.style:SetColor(0.55,0.86,1,1)
local hudEnabled=Button(hud,"hud_enabled","显示：开",620,190,122,28,9)

local hudRows={}
local function HudRow(index,y)
    local row={}
    row.label=Label(hud,"hud_row_label_"..index,"",18,y,190,28,10,ALIGN_LEFT)
    row.value=Label(hud,"hud_row_value_"..index,"",220,y,150,28,10,ALIGN_CENTER)
    row.minus=Button(hud,"hud_row_minus_"..index,"-",392,y-1,132,28,9)
    row.plus=Button(hud,"hud_row_plus_"..index,"+",538,y-1,132,28,9)
    hudRows[index]=row
end
for i=1,8 do HudRow(i,230+(i-1)*38) end

local hudDirection=Button(hud,"hud_direction","排列：向右",18,542,170,30,9)
local hudAnchor=Button(hud,"hud_anchor","安全锚点：底部",198,542,170,30,9)
local hudExtraButtons={}
for i=1,4 do hudExtraButtons[i]=Button(hud,"hud_extra_"..i,"",378+(i-1)*90,542,84,30,8) end

local hudWholeDrag=Button(hud,"hud_whole_drag","整体拖动",18,590,126,32,9)
local hudComponentDrag=Button(hud,"hud_component_drag","组件拖动",154,590,126,32,9)
local hudResetCurrent=Button(hud,"hud_reset_current","恢复当前模块",290,590,136,32,9)
local hudResetScope=Button(hud,"hud_reset_scope","恢复整套推荐布局",436,590,154,32,9)
local hudRefresh=Button(hud,"hud_force_refresh","立即刷新",600,590,142,32,9)
local hudFooter=Label(hud,"hud_footer","",18,642,724,54,9,ALIGN_LEFT)
hudFooter.style:SetColor(0.62,0.74,0.84,1)

local function EffectShowField(effect)
    if effect=="buff" then return "showBuffs" end
    if effect=="debuff" then return "showDebuffs" end
    return "showHidden"
end

local function HudDescriptor()
    local cfg=S:Get()[hudScope]
    local c=hudComponent
    if c=="overall" then
        return cfg,{
            {label="HUD 宽度",key="width",step=10,min=230,max=460,suffix=" px"},
            {label="整体 X 偏移",key="offsetX",step=5,min=-1200,max=1200,suffix=" px"},
            {label=cfg.anchorMode=="BOTTOM" and "底部安全 Y 偏移" or "整体 Y 偏移",key="offsetY",step=5,min=-1200,max=1200,suffix=" px"},
            {label="组件区间距",key="sectionGap",step=1,min=0,max=20,suffix=" px"},
        },"enabled"
    elseif c=="class" then
        return cfg.class,{
            {label="职业文字大小",key="fontSize",step=1,min=9,max=20,suffix=" px"},
            {label="职业图标大小",key="iconSize",step=1,min=18,max=36,suffix=" px"},
            {label="X 偏移",key="offsetX",step=5,min=-300,max=300,suffix=" px"},
            {label="Y 偏移",key="offsetY",step=5,min=-300,max=300,suffix=" px"},
        },"showClass"
    elseif c=="gear" then
        return cfg.gear,{
            {label="装等文字大小",key="fontSize",step=1,min=9,max=20,suffix=" px"},
            {label="X 偏移",key="offsetX",step=5,min=-300,max=300,suffix=" px"},
            {label="Y 偏移",key="offsetY",step=5,min=-300,max=300,suffix=" px"},
        },"showGear"
    elseif c=="loadout" then
        return cfg.loadout,{
            {label="甲胄/武器文字大小",key="fontSize",step=1,min=9,max=20,suffix=" px"},
            {label="X 偏移",key="offsetX",step=5,min=-300,max=300,suffix=" px"},
            {label="Y 偏移",key="offsetY",step=5,min=-300,max=300,suffix=" px"},
        },"showLoadout"
    elseif c=="distance" then
        return cfg.distance,{
            {label="距离文字大小",key="fontSize",step=1,min=8,max=24,suffix=" px"},
            {label="X 偏移",key="offsetX",step=5,min=-300,max=300,suffix=" px"},
            {label="Y 偏移",key="offsetY",step=5,min=-300,max=300,suffix=" px"},
            {label="黄色距离阈值",key="warningAt",step=1,min=0,max=200,suffix=" m"},
            {label="红色距离阈值",key="dangerAt",step=1,min=1,max=300,suffix=" m"},
        },"showDistance"
    elseif c=="buff" or c=="debuff" or c=="hidden" then
        local l=S:GetEffectLayout(hudScope,c)
        return l,{
            {label="图标大小",key="iconSize",step=1,min=18,max=42,suffix=" px"},
            {label="倒计时/层数文字",key="fontSize",step=1,min=8,max=18,suffix=" px"},
            {label="最大显示数量",key="maxCount",step=1,min=1,max=12,suffix=" 个"},
            {label="每行最多图标",key="columns",step=1,min=1,max=12,suffix=" 个"},
            {label="图标横向间距",key="gap",step=1,min=0,max=12,suffix=" px"},
            {label="换行 / 纵向间距",key="rowGap",step=1,min=0,max=12,suffix=" px"},
            {label="X 偏移",key="offsetX",step=5,min=-300,max=300,suffix=" px"},
            {label="Y 偏移",key="offsetY",step=5,min=-300,max=300,suffix=" px"},
        },EffectShowField(c)
    elseif c=="cooldown" then
        return cfg.cooldowns,{
            {label="冷却图标大小",key="iconSize",step=1,min=18,max=42,suffix=" px"},
            {label="倒计时文字大小",key="fontSize",step=1,min=8,max=18,suffix=" px"},
            {label="最大显示数量",key="maxCount",step=1,min=1,max=12,suffix=" 个"},
            {label="每行最多图标",key="columns",step=1,min=1,max=12,suffix=" 个"},
            {label="图标横向间距",key="gap",step=1,min=0,max=12,suffix=" px"},
            {label="换行 / 纵向间距",key="rowGap",step=1,min=0,max=12,suffix=" px"},
            {label="X 偏移",key="offsetX",step=5,min=-300,max=300,suffix=" px"},
            {label="Y 偏移",key="offsetY",step=5,min=-300,max=300,suffix=" px"},
        },"showImportantCooldowns"
    elseif c=="cast" then
        return cfg.cast,{
            {label="施法条宽度（0=自动）",key="width",step=10,min=0,max=450,suffix=" px"},
            {label="施法条高度",key="height",step=1,min=10,max=28,suffix=" px"},
            {label="技能图标大小",key="iconSize",step=1,min=16,max=32,suffix=" px"},
            {label="X 偏移",key="offsetX",step=5,min=-300,max=300,suffix=" px"},
            {label="Y 偏移",key="offsetY",step=5,min=-300,max=300,suffix=" px"},
        },"showCast"
    elseif c=="equipment" then
        return cfg.equipment,{
            {label="装备图标大小",key="iconSize",step=1,min=18,max=42,suffix=" px"},
            {label="X 偏移",key="offsetX",step=5,min=-300,max=300,suffix=" px"},
            {label="Y 偏移",key="offsetY",step=5,min=-300,max=300,suffix=" px"},
        },"showEquipment"
    end
    return cfg.targetOfTarget,{
        {label="文字大小",key="fontSize",step=1,min=8,max=18,suffix=" px"},
        {label="X 偏移",key="offsetX",step=5,min=-300,max=300,suffix=" px"},
        {label="Y 偏移",key="offsetY",step=5,min=-300,max=300,suffix=" px"},
    },"showTargetOfTarget"
end

local function GetEnabledField(field)
    local cfg=S:Get()[hudScope]
    return cfg[field]==true
end
local function SetEnabledField(field,value)
    local cfg=S:Get()[hudScope]
    cfg[field]=value==true
end
local function DirectionBucket()
    if hudComponent=="buff" or hudComponent=="debuff" or hudComponent=="hidden" then return S:GetEffectLayout(hudScope,hudComponent) end
    if hudComponent=="equipment" then return S:Get()[hudScope].equipment end
    if hudComponent=="cooldown" then return S:Get()[hudScope].cooldowns end
    return nil
end

function M:CommitHUDLayout()
    local cfg=S:Get()[hudScope]
    if type(cfg.distance)=="table" and cfg.distance.dangerAt<cfg.distance.warningAt then cfg.distance.dangerAt=cfg.distance.warningAt end
    S:MarkDirty(); local ok,err=S:Save(true); if not ok then P.SafeChat("保存 HUD 布局失败："..tostring(err or "unknown")) end
    U:ApplyPlateLayout(hudScope)
    U:RefreshSettingsText()
    if P.Runtime and P.Runtime.ForceScope then P.Runtime:ForceScope(hudScope) end
    self:RefreshHUDLayout()
end

for i,row in ipairs(hudRows) do
    local index=i
    SafeHandler(row.minus,"OnClick",function()
        local bucket,defs=HudDescriptor(); local def=defs[index]; if def==nil then return end
        local old=tonumber(bucket[def.key]) or 0; bucket[def.key]=math.max(def.min,old-def.step); M:CommitHUDLayout()
    end,"hud:minus:"..index)
    SafeHandler(row.plus,"OnClick",function()
        local bucket,defs=HudDescriptor(); local def=defs[index]; if def==nil then return end
        local old=tonumber(bucket[def.key]) or 0; bucket[def.key]=math.min(def.max,old+def.step); M:CommitHUDLayout()
    end,"hud:plus:"..index)
end

SafeHandler(hudEnabled,"OnClick",function()
    local _,_,field=HudDescriptor(); if field==nil then return end
    SetEnabledField(field,not GetEnabledField(field)); M:CommitHUDLayout()
end,"hud:enabled")
SafeHandler(hudDirection,"OnClick",function()
    local bucket=DirectionBucket(); if type(bucket)~="table" then return end
    local order={RIGHT="DOWN",DOWN="LEFT",LEFT="UP",UP="RIGHT"}; bucket.direction=order[bucket.direction] or "RIGHT"; M:CommitHUDLayout()
end,"hud:direction")
SafeHandler(hudAnchor,"OnClick",function()
    if hudComponent~="overall" or hudScope~="target" then return end
    local cfg=S:Get().target
    cfg.anchorMode=cfg.anchorMode=="BOTTOM" and "TOP" or "BOTTOM"
    -- Switching to safe mode uses a known clearance instead of reinterpreting a
    -- legacy top Y as a bottom Y and jumping hundreds of pixels.
    if cfg.anchorMode=="BOTTOM" then cfg.offsetY=-34 end
    M:CommitHUDLayout()
end,"hud:anchor")

local function HudRuntimeReady(scope)
    local rt=P.Runtime and P.Runtime.scopes and P.Runtime.scopes[scope] or nil
    if type(rt)=="table" and rt.positionValid==true and rt.identityValid==true then return true end
    if scope=="target" then P.SafeChat("目标当前不可见，请先选择目标。")
    else P.SafeChat("自己当前没有可用屏幕坐标。") end
    return false
end

local function ResetComponent(scope,component)
    local cfg=S:Get()[scope]
    if component=="overall" then
        cfg.width=286; cfg.sectionGap=4; cfg.offsetX=-126
        if scope=="target" then cfg.anchorMode="BOTTOM"; cfg.offsetY=-34
        elseif scope=="player" then cfg.anchorMode="TOP"; cfg.offsetY=-92 end
    elseif component=="class" then
        local showIcon,showName=cfg.class.showIcon,cfg.class.showName
        cfg.class={showIcon=showIcon,showName=showName,iconSize=26,fontSize=12,offsetX=0,offsetY=0}
    elseif component=="gear" then cfg.gear={fontSize=12,offsetX=0,offsetY=0}
    elseif component=="loadout" then cfg.loadout={fontSize=11,offsetX=0,offsetY=0}
    elseif component=="distance" then cfg.distance={fontSize=12,offsetX=0,offsetY=0,warningAt=25,dangerAt=30}
    elseif component=="buff" or component=="debuff" or component=="hidden" then
        local l=S:GetEffectLayout(scope,component)
        if type(l)=="table" then l.iconSize=component=="hidden" and 23 or 24; l.fontSize=10; l.maxCount=8; l.columns=6; l.gap=2; l.rowGap=2; l.direction="RIGHT"; l.offsetX=0; l.offsetY=0 end
    elseif component=="cooldown" then cfg.cooldowns={iconSize=24,fontSize=10,maxCount=8,columns=6,gap=2,rowGap=2,direction="RIGHT",offsetX=0,offsetY=0}
    elseif component=="cast" then cfg.cast={width=0,height=16,iconSize=20,offsetX=0,offsetY=0}
    elseif component=="equipment" then
        local old=cfg.equipment
        cfg.equipment={iconSize=26,direction="RIGHT",offsetX=0,offsetY=0,showGlider=old.showGlider,showMainhand=old.showMainhand,showOffhand=old.showOffhand,showRanged=old.showRanged}
    elseif component=="targetOfTarget" then cfg.targetOfTarget={fontSize=10,offsetX=0,offsetY=0} end
end

SafeHandler(hudResetCurrent,"OnClick",function() ResetComponent(hudScope,hudComponent); M:CommitHUDLayout() end,"hud:reset_current")
function M:ResetHUDScope(scope)
    if SCOPE_META[scope]==nil then return false end
    hudScope=scope
    for _,component in ipairs({"overall","class","gear","distance","buff","debuff","hidden","cast","equipment","cooldown","targetOfTarget"}) do
        if HudComponentAvailable(scope,component) then ResetComponent(scope,component) end
    end
    M:CommitHUDLayout()
    return true
end
SafeHandler(hudResetScope,"OnClick",function() M:ResetHUDScope(hudScope) end,"hud:reset_scope")
SafeHandler(hudRefresh,"OnClick",function()
    U:ApplyPlateLayout(hudScope)
    if not ModuleRuntimeEnabled() then P.SafeChat("BUFF显示模块当前未启用；布局已保存，Runtime 刷新将在启用后生效。") return end
    if P.Runtime and P.Runtime.ForceScope then P.Runtime:ForceScope(hudScope) end
end,"hud:refresh")
SafeHandler(hudWholeDrag,"OnClick",function()
    if U.calibrationScope==hudScope then U:SetCalibration(nil)
    else if not HudRuntimeReady(hudScope) then return end; U:SetCalibration(hudScope) end
    M:RefreshHUDLayout()
end,"hud:whole_drag")
SafeHandler(hudComponentDrag,"OnClick",function()
    if U.layoutEditScope==hudScope then U:SetLayoutEdit(nil)
    else if not HudRuntimeReady(hudScope) then return end; U:SetLayoutEdit(hudScope,hudComponent=="overall" and nil or hudComponent) end
    M:RefreshHUDLayout()
end,"hud:component_drag")

local function ConfigureExtraButton(button,text,visible,handlerKey)
    button:SetText(text or "")
    button.rpAction=handlerKey
    button:Show(visible==true)
end
for i,b in ipairs(hudExtraButtons) do
    local index=i
    SafeHandler(b,"OnClick",function(self)
        local action=self.rpAction
        local cfg=S:Get()[hudScope]
        if action=="tracked" then cfg.trackedOnly=not cfg.trackedOnly
        elseif action=="classIcon" then cfg.class.showIcon=not cfg.class.showIcon
        elseif action=="className" then cfg.class.showName=not cfg.class.showName
        elseif action=="glider" then cfg.equipment.showGlider=not cfg.equipment.showGlider
        elseif action=="mainhand" then cfg.equipment.showMainhand=not cfg.equipment.showMainhand
        elseif action=="offhand" then cfg.equipment.showOffhand=not cfg.equipment.showOffhand
        elseif action=="ranged" then cfg.equipment.showRanged=not cfg.equipment.showRanged
        else return end
        M:CommitHUDLayout()
    end,"hud:extra:"..index)
end

function M:RefreshHUDLayout()
    if not HudComponentAvailable(hudScope,hudComponent) then hudComponent=FirstHudComponent(hudScope) end
    for scope,b in pairs(hudScopeButtons) do b:SetText((scope==hudScope and "[选] " or "")..SCOPE_META[scope].title) end
    for key,b in pairs(hudComponentButtons) do
        local enabled=HudComponentAvailable(hudScope,key); b:Enable(enabled)
        local title=""
        for _,def in ipairs(HUD_COMPONENTS) do if def.key==key then title=def.text; break end end
        b:SetText((key==hudComponent and "[选] " or "")..title)
    end
    local cfg=S:Get()[hudScope]
    local bucket,defs,field=HudDescriptor()
    local componentText=""
    for _,def in ipairs(HUD_COMPONENTS) do if def.key==hudComponent then componentText=def.text; break end end
    hudSummary:SetText(SCOPE_META[hudScope].title.." / "..componentText.." · 修改后立即保存并刷新")
    hudEnabled:SetText(field and (GetEnabledField(field) and "显示：开" or "显示：关") or "")
    hudEnabled:Show(field~=nil)
    for i,row in ipairs(hudRows) do
        local def=defs[i]
        if def==nil then row.label:Show(false); row.value:Show(false); row.minus:Show(false); row.plus:Show(false)
        else
            row.label:Show(true); row.value:Show(true); row.minus:Show(true); row.plus:Show(true)
            row.label:SetText(def.label)
            local value=tonumber(bucket[def.key]) or 0
            if def.key=="width" and hudComponent=="cast" and value==0 then row.value:SetText("自动") else row.value:SetText(tostring(value)..tostring(def.suffix or "")) end
        end
    end
    local dirBucket=DirectionBucket()
    hudDirection:Show(type(dirBucket)=="table")
    if type(dirBucket)=="table" then
        local directionText={RIGHT="向右",LEFT="向左",DOWN="向下",UP="向上"}
        hudDirection:SetText("排列："..(directionText[dirBucket.direction] or "向右"))
    end
    hudAnchor:Show(hudScope=="target" and hudComponent=="overall")
    hudAnchor:SetText(cfg.anchorMode=="BOTTOM" and "安全锚点：底部" or "锚点：顶部")
    for _,b in ipairs(hudExtraButtons) do ConfigureExtraButton(b,"",false,nil) end
    if hudComponent=="overall" then
        ConfigureExtraButton(hudExtraButtons[1],cfg.trackedOnly and "只追踪：开" or "只追踪：关",true,"tracked")
    elseif hudComponent=="class" then
        ConfigureExtraButton(hudExtraButtons[1],cfg.class.showIcon and "职业图标：开" or "职业图标：关",true,"classIcon")
        ConfigureExtraButton(hudExtraButtons[2],cfg.class.showName and "职业文字：开" or "职业文字：关",true,"className")
    elseif hudComponent=="buff" or hudComponent=="debuff" or hudComponent=="hidden" then
        ConfigureExtraButton(hudExtraButtons[1],cfg.trackedOnly and "只追踪：开" or "只追踪：关",true,"tracked")
    elseif hudComponent=="equipment" then
        ConfigureExtraButton(hudExtraButtons[1],cfg.equipment.showGlider and "滑翔翼：开" or "滑翔翼：关",true,"glider")
        ConfigureExtraButton(hudExtraButtons[2],cfg.equipment.showMainhand and "主手：开" or "主手：关",true,"mainhand")
        ConfigureExtraButton(hudExtraButtons[3],cfg.equipment.showOffhand and "副手：开" or "副手：关",true,"offhand")
        ConfigureExtraButton(hudExtraButtons[4],cfg.equipment.showRanged and "远程：开" or "远程：关",true,"ranged")
    end
    hudWholeDrag:SetText(U.calibrationScope==hudScope and "整体：拖动中" or "整体拖动")
    hudComponentDrag:SetText(U.layoutEditScope==hudScope and "组件：拖动中" or "组件拖动")
    if hudScope=="target" and cfg.anchorMode=="BOTTOM" then
        hudFooter:SetText("目标 HUD 下边界固定在单位屏幕点上方 "..tostring(math.abs(tonumber(cfg.offsetY) or 0)).."px；Buff 换行、Debuff、施法出现时只会把 HUD 顶部继续向上推，不会把底部推入原生姓名条。")
    else
        hudFooter:SetText("所有模块都在当前窗口调整；X/Y 是可选精细偏移。普通位置调整可直接使用“整体拖动 / 组件拖动”。")
    end
end

function M:OpenHUDLayout(scope)
    if SCOPE_META[scope]~=nil then hudScope=scope end
    if not HudComponentAvailable(hudScope,hudComponent) then hudComponent=FirstHudComponent(hudScope) end
    hud:Show(true); if hud.Raise~=nil then hud:Raise() end; self:RefreshHUDLayout()
end

-- Compatibility entry points: external integrations from older builds now land
-- in the unified window instead of resurrecting Advanced/Auxiliary subwindows.
function M:OpenAdvanced() self:OpenHUDLayout("target") end
function M:OpenAux() self:OpenHUDLayout("target") end
function M:RefreshAdvanced() self:RefreshHUDLayout() end
function M:RefreshAux() self:RefreshHUDLayout() end

function M:HideAll()
    for _,w in pairs(self.windows) do if w~=nil then pcall(function() w:Show(false) end) end end
end
