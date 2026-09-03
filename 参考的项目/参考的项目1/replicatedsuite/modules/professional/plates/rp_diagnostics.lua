ReplicatedSuiteModuleSandbox:Enter('plates', {'ReplicatedPlates'})
------------------------------------------------------------------------
-- Replicated Plates - Manual pretest diagnostics
-- No OnUpdate handler. API sampling happens only when the user clicks refresh.
------------------------------------------------------------------------
if ReplicatedPlates == nil or ReplicatedPlates.BootError ~= nil or ReplicatedPlates.Api == nil or ReplicatedPlates.Storage == nil then return end
local P = ReplicatedPlates
local A = P.Api
local S = P.Storage
local generation = P.Generation

P.Diagnostics = { window = nil, report = nil }
local D = P.Diagnostics

local function SafeHandler(widget, eventName, fn, label)
    if widget == nil or type(widget.SetHandler) ~= "function" then return end
    widget:SetHandler(eventName, function(...)
        if P.Generation ~= generation then return nil end
        local args = { ... }
        local argCount = select("#", ...)
        local ok, result = xpcall(function() return fn(unpack(args, 1, argCount)) end, P.SafeTraceback)
        if not ok then P.SafeChat("诊断 UI 错误 " .. tostring(label or eventName) .. "：" .. tostring(result)); return nil end
        return result
    end)
end

local function SetPick(widget, enabled)
    if widget == nil then return end
    if widget.Enable ~= nil then pcall(function() widget:Enable(true) end) end
    if widget.EnablePick ~= nil then pcall(function() widget:EnablePick(enabled == true, true) end) end
    if widget.Clickable ~= nil then pcall(function() widget:Clickable(enabled == true, true) end) end
end

local function Background(parent, r, g, b, a)
    local bg = parent:CreateColorDrawable(r, g, b, a, "background")
    bg:AddAnchor("TOPLEFT", parent, 0, 0); bg:AddAnchor("BOTTOMRIGHT", parent, 0, 0)
    return bg
end

local function Label(parent, id, text, x, y, width, height, size, align)
    local w = parent:CreateChildWidget("label", P.PhysicalId(id), 0, true)
    w:AddAnchor("TOPLEFT", parent, x, y); w:SetAutoResize(false); w:SetExtent(width, height)
    if w.EnablePick ~= nil then w:EnablePick(false) end
    if w.Clickable ~= nil then w:Clickable(false) end
    w.style:SetFontSize(size or 10); w.style:SetAlign(align or ALIGN_LEFT); w.style:SetColor(0.94, 0.95, 0.97, 1)
    if w.style.SetOutline ~= nil then w.style:SetOutline(true) end
    w:SetText(text or ""); w:Show(true); return w
end

local function StyleButton(button, width, height, size)
    local colors = {
        {0.07,0.14,0.21,0.99},{0.14,0.29,0.43,0.99},{0.035,0.08,0.13,0.99},{0.07,0.08,0.10,0.75}
    }
    button.rpStates = {}
    for i,c in ipairs(colors) do
        local bg=button:CreateColorDrawable(c[1],c[2],c[3],c[4],"background")
        bg:AddAnchor("TOPLEFT",button,0,0);bg:AddAnchor("BOTTOMRIGHT",button,0,0);button.rpStates[i]=bg
    end
    if button.SetNormalBackground ~= nil then
        button:SetNormalBackground(button.rpStates[1]);button:SetHighlightBackground(button.rpStates[2]);button:SetPushedBackground(button.rpStates[3]);button:SetDisabledBackground(button.rpStates[4])
    end
    button:SetAutoResize(false);button:SetExtent(width,height);button.style:SetFontSize(size or 9);button.style:SetColor(0.96,0.94,0.89,1)
end

local function Button(parent,id,text,x,y,width,height,size)
    local b=parent:CreateChildWidget("button",P.PhysicalId(id),0,true);b:SetText(text);StyleButton(b,width,height,size);b:AddAnchor("TOPLEFT",parent,x,y);SetPick(b,true);b:Show(true);return b
end

local function Value(value)
    if value == nil then return "<nil>" end
    if type(value) == "number" then return string.format("%.3f", value) end
    return tostring(value)
end

local function SortedPrimitivePairs(value)
    local rows = {}
    if type(value) ~= "table" then return rows end
    for key,item in pairs(value) do rows[#rows + 1] = { key=tostring(key), value=item } end
    table.sort(rows,function(a,b) return a.key < b.key end)
    return rows
end

local function TableCount(value)
    local n=0
    if type(value)=="table" then for _ in pairs(value) do n=n+1 end end
    return n
end

function D:BuildReport()
    local lines = {}
    local function Add(text) lines[#lines + 1] = tostring(text or "") end
    Add("Replicated Plates 实机诊断")
    Add("Version=" .. tostring(P.Version) .. "  Schema=" .. tostring(P.SchemaVersion) .. "  Generation=" .. tostring(P.Generation))
    Add("Ready=" .. tostring(P.Ready == true) .. "  BootError=" .. tostring(P.BootError or "<none>"))
    local runtime = P.Runtime
    Add("Runtime=" .. tostring(type(runtime)=="table" and runtime.running==true)
        .. "  Driver=" .. tostring(type(runtime)=="table" and runtime.driver~=nil)
        .. "  Watchdog=" .. tostring(type(runtime)=="table" and runtime.watchdog~=nil))
    if type(runtime)=="table" then
        Add("SuccessfulUpdates=" .. tostring(runtime.successfulUpdateSerial or 0)
            .. "  WatchdogRecoveries=" .. tostring(runtime.watchdogRecoveries or 0)
            .. "  VisibilityRepairs=" .. tostring(runtime.visibilityRepairs or 0))
        local activeErrors = 0
        for _, _ in pairs(runtime.laneErrors or {}) do activeErrors = activeErrors + 1 end
        Add("ActiveLaneErrors=" .. tostring(activeErrors))
    end
    Add("")
    Add("[API Capability]")
    for _,item in ipairs(A:GetCapabilitySnapshot()) do Add((item.available and "[OK] " or "[--] ") .. tostring(item.label)) end

    for _,spec in ipairs({ {"target","目标"}, {"player","自己"} }) do
        local unit,title=spec[1],spec[2]
        local d=A:GetUnitDiagnostic(unit)
        Add("")
        Add("["..title.." / "..unit.."]")
        Add("name="..Value(d.name).."  id="..Value(d.unitId))
        Add("screen="..Value(d.x)..","..Value(d.y)..","..Value(d.z))
        Add("hp="..Value(d.health).." / "..Value(d.maxHealth).."  distance="..Value(d.distance))
        local cfg=S:Get()[unit]
        if type(cfg)=="table" then
            local plateState=P.UI and P.UI.plates and P.UI.plates[unit] or nil
            Add("enabled="..tostring(cfg.enabled==true).."  width="..Value(cfg.width).."  offset="..Value(cfg.offsetX)..","..Value(cfg.offsetY).."  anchor="..Value(cfg.anchorMode).."  layoutHeight="..Value(plateState and plateState.layoutHeight))
            local hiddenLimit = tostring(S:GetEffectLimit(unit,"hidden"))
            Add("effects limit B/D/H="..tostring(S:GetEffectLimit(unit,"buff")).."/"..tostring(S:GetEffectLimit(unit,"debuff")).."/"..hiddenLimit)
            Add("show B/D/H="..tostring(cfg.showBuffs==true).."/"..tostring(cfg.showDebuffs==true).."/"..tostring(cfg.showHidden==true)
                .."  trackedOnly="..tostring(cfg.trackedOnly==true))
        end
        local st=type(runtime)=="table" and runtime.scopes and runtime.scopes[unit] or nil
        if type(st)=="table" then
            local snap=st.effectSnapshots or {}; local fail=st.effectReadFailures or {}; local fallback=st.trackedOnlyFallback or {}
            Add("runtime positionValid="..tostring(st.positionValid==true).." identityValid="..tostring(st.identityValid==true)
                .." lastName="..Value(st.lastIdentityName))
            Add("snapshot B/D/H="..TableCount(snap.buff).."/"..TableCount(snap.debuff).."/"..TableCount(snap.hidden)
                .." readFailures="..tostring(fail.buff or 0).."/"..tostring(fail.debuff or 0).."/"..tostring(fail.hidden or 0))
            Add("emptyTrackedFallback B/D/H="..tostring(fallback.buff==true).."/"..tostring(fallback.debuff==true).."/"..tostring(fallback.hidden==true)
                .."  hiddenStrictWhitelist=true  hiddenWhitelistEmpty="..tostring(st.hiddenWhitelistEmpty==true))
        end
        for _,effectType in ipairs({"buff","debuff","hidden"}) do
            local rawEffect=A:GetRawEffectDiagnostic(unit,effectType,1)
            if type(rawEffect)=="table" then
                Add("raw "..effectType.." count="..tostring(rawEffect.count or 0).." dataOk="..tostring(rawEffect.dataOk==true).." tipOk="..tostring(rawEffect.tipOk==true))
                if type(rawEffect.data)=="table" and next(rawEffect.data)~=nil then
                    local fields={}; for _,row in ipairs(SortedPrimitivePairs(rawEffect.data)) do fields[#fields+1]=row.key.."="..Value(row.value) end
                    Add("  data: "..table.concat(fields," | "))
                end
                if type(rawEffect.tip)=="table" and next(rawEffect.tip)~=nil then
                    local fields={}; for _,row in ipairs(SortedPrimitivePairs(rawEffect.tip)) do fields[#fields+1]=row.key.."="..Value(row.value) end
                    Add("  tip: "..table.concat(fields," | "))
                end
            end
        end
    end

    Add("")
    Add("[Target UnitCastingInfo raw primitives]")
    local raw=A:GetRawCastingDiagnostic("target")
    if type(raw)~="table" or next(raw)==nil then Add("<none / not casting / unavailable>")
    else for _,row in ipairs(SortedPrimitivePairs(raw)) do Add(row.key.."="..Value(row.value)) end end

    Add("")
    Add("[Tracking counts]")
    for _,scope in ipairs({"target","player"}) do
        local hidden = tostring(S:TrackedCount(scope,"hidden"))
        Add(scope.."  B/D/H="..tostring(S:TrackedCount(scope,"buff")).."/"..tostring(S:TrackedCount(scope,"debuff")).."/"..hidden)
    end
    Add("")
    Add("说明：此报告仅由按钮触发一次性采样，不会增加常驻 OnUpdate。若实机显示异常，请 Ctrl+A / Ctrl+C 复制整段给开发。")
    return table.concat(lines,"\n")
end

if ReplicatedSuiteEmbedded == true then
    function D:Refresh() return self:BuildReport() end
    function D:Open()
        if ReplicatedSuite ~= nil and ReplicatedSuite.UI ~= nil then ReplicatedSuite.UI:ShowPage("plates"); return true end
        return false
    end
    function D:HideAll() end
    return
end

local pos = S:Get().diagnostics
local window = CreateEmptyWindow(P.PhysicalId("diagnostics"), "UIParent")
window:SetExtent(700, 590); window:AddAnchor("TOPLEFT","UIParent",pos.x,pos.y);if window.CorrectOffsetByScreen~=nil then pcall(function() window:CorrectOffsetByScreen() end) end;window:Show(false);SetPick(window,true)
if window.SetUILayer ~= nil then pcall(function() window:SetUILayer("system") end) end
Background(window,0.014,0.024,0.038,0.995)
local header=window:CreateChildWidget("emptywidget",P.PhysicalId("diagnostics_header"),0,true);header:AddAnchor("TOPLEFT",window,0,0);header:SetExtent(700,40);SetPick(header,true);Background(header,0.050,0.12,0.19,1)
local line=header:CreateColorDrawable(0.20,0.58,0.88,1,"artwork");line:AddAnchor("BOTTOMLEFT",header,0,0);line:SetExtent(700,2)
Label(header,"diagnostics_title","Replicated Plates · 实机诊断",14,7,420,24,14,ALIGN_LEFT)
local close=Button(header,"diagnostics_close","X",656,6,32,27,13)

if header.EnableDrag ~= nil then
    header:EnableDrag(true)
    SafeHandler(header,"OnDragStart",function() if type(window.StartMoving)=="function" then window:StartMoving() end return true end,"diagnostics:drag_start")
    SafeHandler(header,"OnDragStop",function()
        if type(window.StopMovingOrSizing)=="function" then window:StopMovingOrSizing() end
        if window.CorrectOffsetByScreen~=nil then pcall(function() window:CorrectOffsetByScreen() end) end
        if type(window.GetOffset)=="function" then local x,y=window:GetOffset(); if x~=nil and y~=nil then S:UpdatePosition("diagnostics",x,y) end end
        return true
    end,"diagnostics:drag_stop")
end

local help=Label(window,"diagnostics_help","用于第一次进游戏核对 RU 客户端 API 返回。诊断只在点击“刷新采样”时读取数据。",16,52,668,24,9,ALIGN_LEFT);help.style:SetColor(0.66,0.78,0.88,1)
local report=window:CreateChildWidgetByType(UOT_EDITBOX_MULTILINE,P.PhysicalId("diagnostics_report"),0,true)
report:SetInset(10,10,15,0);report:SetWidth(668);report:SetHeight(442);report:EnableFocus(true);report:SetMaxTextLength(65535);report.style:SetAlign(ALIGN_TOP_LEFT)
if report.guideTextStyle~=nil then report.guideTextStyle:SetAlign(ALIGN_TOP_LEFT) end
local reportBg=report:CreateDrawable("ui/common/default.dds","editbox_df","background");reportBg:AddAnchor("TOPLEFT",report,0,0);reportBg:AddAnchor("BOTTOMRIGHT",report,0,0);report:AddAnchor("TOPLEFT",window,16,82)
local refresh=Button(window,"diagnostics_refresh","刷新采样",222,542,120,30,10)
local force=Button(window,"diagnostics_force","刷新 HUD",356,542,120,30,10)

SafeHandler(close,"OnClick",function() window:Show(false) end,"diagnostics:close")
SafeHandler(refresh,"OnClick",function() D:Refresh() end,"diagnostics:refresh")
SafeHandler(force,"OnClick",function() if P.UI and P.UI.ApplyAllLayouts then P.UI:ApplyAllLayouts() end;if P.Runtime and P.Runtime.ForceAll then P.Runtime:ForceAll() end;D:Refresh() end,"diagnostics:force")

D.window,D.report=window,report
function D:Refresh() if self.report~=nil then self.report:SetText(self:BuildReport()) end end
function D:Open() self:Refresh();window:Show(true);if window.Raise~=nil then window:Raise() end end
function D:HideAll() if window~=nil then pcall(function() window:Show(false) end) end end
