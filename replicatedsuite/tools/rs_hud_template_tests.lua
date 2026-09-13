-- 维护（hud-template-restore-1）：恢复真实校准入口及 Draft 模板的回归，不进入 toc.g。
-- Authority：生产 Calibration/Store/Renderer 不替换；Native 控件和本地聊天采用既有可控宿主。
-- 目的：隐藏按钮、遗漏 class、新旧 profile 混淆或导出偷偷写档，都必须使此测试失败。
-- 局限：原生绘字、实际聊天长度/复制和 RU Lua 5.1 输入仍须在客户端验证。
local passed, failed = 0, 0
local BUTTON_ID = "v3_buff_hud_calibration_template"
local META = { viewportWidth=1280, viewportHeight=768, uiScale=1 }

local function Test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed=passed+1; print("PASS hud-template "..name)
    else failed=failed+1; print("FAIL hud-template "..name..": "..tostring(err)) end
end

local function Equal(a, b)
    if a == b then return true end
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k,v in pairs(a) do if not Equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

-- 维护（hud-template-copy-2）：交付由聊天改为可回读编辑框；复用带容量故障的宿主。
-- 原V1数值、Draft/Store隔离、屏幕Y与布局断言全部保留，只替换过时的“11条聊天成功”契约。
local Open=dofile("tools/rs_hud_template_copy_test_host.lua")

local function Find(lines,scope,section)
    local prefix="HUD_TEMPLATE_V1|"..scope.."|"..section.."|"
    for _,line in ipairs(lines) do
        if line:sub(1,#prefix)==prefix then return line end
    end
    error("missing "..scope.." "..section.." template line")
end

Test("normal calibration exposes current-position button",function()
    local h,S,F,P,C=Open()
    local button=assert(h.buttons[BUTTON_ID],"current-position button missing without developer flags")
    assert(button.text=="获取当前位置","button purpose unclear")
    assert(button.shown and button.enabled and button.pickable)
    assert(button.parent==C.panel and type(button.events.OnClick)=="function")
end)

Test("legacy maintenance flag no longer hides requested entry",function()
    local h=Open({debugFlags={ShowHudTemplateTools=false}})
    assert(h.buttons[BUTTON_ID],"legacy false flag still hides restored entry")
end)

Test("button captures both profiles including independent class geometry",function()
    local h,S,F,P,C=Open()
    -- 维护（hud-default-template-2）：读入本次初始几何后检验增量；期望尺寸仍固定24/32，
    -- 避免模板变更让“增24”被误写成“设24”。完整发行值另由独立默认模板用例验真。
    local initial=C:GetDraftSnapshot();local pc,tc=initial.player.components.class,initial.target.components.class
    assert(C:SetComponent("class"));C:Nudge(17,-9);C:Adjust("size",24-pc.size);C:Adjust("alpha",-.4)
    assert(C:SetScope("target"));C:Nudge(-31,12);C:Adjust("size",32-tc.size)
    local ok,lines=h:Click();assert(ok)
    assert(#lines==11 and #h.chat==1,"expected eleven records and one short receipt")
    assert(Find(lines,"PLAYER","CLASS"):find(string.format("class{x=%d,y=%d,size=24,alpha=0.6,enabled=1}",pc.x+17,pc.y-9),1,true))
    assert(Find(lines,"TARGET","CLASS"):find(string.format("class{x=%d,y=%d,size=32,alpha=1,enabled=1}",tc.x-31,tc.y+12),1,true))
    assert(C.visible and C.scope=="target" and C.component=="class")
    assert(C.templateCopy.text:find("HUD_TEMPLATE_V2;TARGET;CLASS;",1,true))
    assert(h.chat[1].source=="hud_template" and not h.chat[1].text:find("|",1,true))
end)

Test("automatic class size zero and disabled state remain explicit",function()
    local h,S,F,P,C=Open()
    -- 维护：显式经编辑框设成自动大小0；旧用例依赖新建配置碰巧为0，会漏测非零默认升级。
    local initial=C:GetDraftSnapshot();local pc,tc=initial.player.components.class,initial.target.components.class
    assert(C:SetComponent("class"));C.inputs.size:SetText("0");assert(C:ApplyInputFields())
    assert(C.enabledButton.events.OnClick())
    assert(C:SetScope("target"));C.inputs.size:SetText("0");assert(C:ApplyInputFields())
    local lines=assert(C:BuildTemplateSnapshotLines(META))
    assert(Find(lines,"PLAYER","CLASS"):find(string.format("class{x=%d,y=%d,size=0,alpha=1,enabled=0}",pc.x,pc.y),1,true))
    assert(Find(lines,"TARGET","CLASS"):find(string.format("class{x=%d,y=%d,size=0,alpha=1,enabled=1}",tc.x,tc.y),1,true))
end)

Test("snapshot uses unsaved draft without touching Store or default authority",function()
    local h,S,F,P,C=Open()
    local saved=F:GetHudCalibrationSnapshot()
    local defaults=F:GetDefaultHudCalibrationSnapshot()
    assert(C:SetComponent("class"));C:Nudge(23,-14)
    local draft=C:GetDraftSnapshot();local disk=h.Copy(h.disk)
    local writes,reads,clears=h.writes,h.reads,h.clears
    local scans,items,projection=h.scans,h.itemReads,h.projectionReads
    -- 调度 owner 可能指回完整 Feature；只取任务身份，不能深复制循环对象图。
    local tasks={}
    for name,task in pairs(S.Scheduler.tasks) do tasks[name]=task end
    assert(h:Click())
    assert(Equal(C:GetDraftSnapshot(),draft) and Equal(F:GetHudCalibrationSnapshot(),saved))
    assert(Equal(F:GetDefaultHudCalibrationSnapshot(),defaults) and Equal(h.disk,disk))
    assert(h.writes==writes and h.reads==reads and h.clears==clears)
    assert(h.scans==scans and h.itemReads==items and h.projectionReads==projection)
    assert(Equal(S.Scheduler.tasks,tasks),"export altered scheduled work")
    assert(C.dirty and C.visible and P:IsCalibrationSuppressed())
end)

Test("existing V1 sections and screen-Y conversion remain unchanged",function()
    local h,S,F,P,C=Open()
    assert(C:SetComponent("buffs"));C:Nudge(0,-7)
    local snapshot=C:GetDraftSnapshot()
    local lines=assert(C:BuildTemplateSnapshotLines(META))
    for _,scope in ipairs({"PLAYER","TARGET"}) do
        for _,section in ipairs({"BASE","AURA","EQUIP","CAST"}) do Find(lines,scope,section) end
    end
    local y=-snapshot.player.components.buffs.y
    assert(Find(lines,"PLAYER","AURA"):find("buffs{x="..snapshot.player.components.buffs.x..",y="..y..",",1,true))
    assert(lines[1]:find("source=draft;coords=screen-y-v1",1,true))
    assert(tonumber(Find(lines,"PLAYER","BASE"):match("|BASE|scale=([^;]+)"))==snapshot.player.plateScale)
end)

Test("metrics record logical viewport and scale once",function()
    local h,S,F,P,C=Open({width=1920,height=1080,scale=1.25})
    local lines=assert(C:BuildTemplateSnapshotLines())
    assert(lines[1]:find("viewport=1536x864;uiScale=1.25",1,true))
    -- 维护：无论初始模板在哪，增量只能应用一次，不能随UI缩放倍增。
    local initial=C:GetDraftSnapshot().player.components.class
    assert(C:SetComponent("class"));C:Nudge(13,-8)
    local after=assert(C:BuildTemplateSnapshotLines())
    assert(Find(after,"PLAYER","CLASS"):find(string.format("x=%d,y=%d",initial.x+13,initial.y-8),1,true),"scaled export changed logical offsets")
end)

Test("applied numeric inputs are included without autosaving",function()
    local h,S,F,P,C=Open()
    assert(C:SetComponent("class"))
    C.inputs.x:SetText("-38");C.inputs.y:SetText("19");C.inputs.size:SetText("30")
    C.inputs.alpha:SetText("0.75");C.inputs.scale:SetText("1.5")
    assert(C:ApplyInputFields())
    local writes=h.writes
    local ok,lines=h:Click();assert(ok)
    assert(Find(lines,"PLAYER","CLASS"):find("x=-38,y=19,size=30,alpha=0.75",1,true))
    assert(Find(lines,"PLAYER","BASE"):find("scale=1.5",1,true))
    assert(h.writes==writes)
end)

Test("captured lines remain immutable after later edits",function()
    local h,S,F,P,C=Open()
    local ok,lines=h:Click();assert(ok)
    local before=table.concat(lines,"\n")
    assert(C:SetComponent("class"));C:Nudge(20,3)
    assert(table.concat(lines,"\n")==before)
    local ok2,lines2=h:Click();assert(ok2)
    assert(table.concat(lines2,"\n")~=before)
end)

Test("cancel leaves config unchanged and hidden callback cannot export",function()
    local h,S,F,P,C=Open()
    local original=F:GetHudCalibrationSnapshot()
    assert(C:SetComponent("class"));C:Nudge(22,-6)
    assert(h:Click());assert(C:Exit(false))
    local count=#h.chat
    assert(not h:Click() and #h.chat==count)
    assert(Equal(original,F:GetHudCalibrationSnapshot()))
    assert(not C.visible and not P:IsCalibrationSuppressed())
end)

Test("reopen reuses one button and captures current saved layout",function()
    local h,S,F,P,C=Open()
    -- 维护：保存并重开应保留真实初始值加微调，不应重建为0坐标。
    local initial=C:GetDraftSnapshot().player.components.class
    assert(C:SetComponent("class"));C:Nudge(27,-11);assert(h:Click());assert(C:Exit(true))
    local store=S.Persistence:GetStore("v3.buff_display");store.loaded=false;assert(F:EnsureStoreLoaded())
    local count=h.createdButtons;local button=h.buttons[BUTTON_ID]
    assert(C:Open())
    assert(button==h.buttons[BUTTON_ID] and h.createdButtons==count,"reopening duplicated controls")
    local ok,lines=h:Click();assert(ok)
    assert(Find(lines,"PLAYER","CLASS"):find(string.format("x=%d,y=%d",initial.x+27,initial.y-11),1,true))
    assert(#h.chat==2,"one short receipt per explicit export expected")
end)

Test("missing draft rejects output without chatting",function()
    local h,S,F,P,C=Open();assert(C:Exit(false))
    local writes=h.writes;local ok=C:OutputTemplateSnapshot()
    assert(ok==false and #h.chat==0 and h.writes==writes)
    assert(C.Diagnostics.templateOutputFailures==1)
end)

Test("missing chat receipt preserves verified copy delivery",function()
    local h,S,F,P,C=Open();S.SafeChat=nil
    local writes=h.writes;local ok=C:OutputTemplateSnapshot()
    assert(ok==true and C.visible and h.writes==writes)
    assert(C.Diagnostics.templateOutputFailures==0 and C.Diagnostics.templateOutputCount==1)
end)

Test("rejected receipt does not invalidate verified report",function()
    local h,S,F,P,C=Open();local attempts=0
    S.SafeChat=function()attempts=attempts+1;return false end
    local ok=C:OutputTemplateSnapshot()
    assert(ok==true,"receipt rejection must not discard verified editor delivery")
    assert(attempts==1 and C.visible and C.templateCopy.index==1)
    assert(C.Diagnostics.templateOutputFailures==0 and C.Diagnostics.templateOutputCount==1)
end)

Test("chat exception is bounded and does not close calibration",function()
    local h,S,F,P,C=Open()
    S.SafeChat=function()error("synthetic_chat_failure")end
    local callOk,ok=pcall(C.OutputTemplateSnapshot,C)
    assert(callOk and ok==true,"receipt exception must not escape or invalidate editor")
    assert(C.visible and C.Diagnostics.templateOutputFailures==0)
end)

Test("button fits existing panel without overlapping reset controls",function()
    for _,metrics in ipairs({{1024,768,1},{1280,768,1},{1920,1080,1.25}}) do
        local h,S,F,P,C=Open({width=metrics[1],height=metrics[2],scale=metrics[3]})
        local button=assert(h.buttons[BUTTON_ID],"button missing")
        local previous=h.buttons.v3_buff_hud_calibration_default
        assert(button.x>=previous.x+previous.width)
        assert(button.x+button.width<=C.panel.width and button.y+button.height<=C.panel.height)
        assert(button.y+button.height<h.buttons.v3_buff_hud_calibration_cancel.y)
    end
end)

print(string.format("HUD_TEMPLATE_RESULT passed=%d failed=%d",passed,failed))
assert(failed==0,"HUD template restore regressions")
