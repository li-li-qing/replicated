-- Replicated Suite · 配方制作入口策略
-- 作者：Replicated
-- QQ群：1104129461
-- 2026-10-26/27 实机三个制作窗口 Getter 全 nil；停止自动观察，以屏幕按钮进入手动小窗。
-- 旧 autoSidecar 偏好不删除、不隐式改写；按钮显隐/位置由原 Feature Store 的 nullable 字段持有。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local Feature = S.Features and S.Features.tools_craft or nil
local P = S.Persistence
local Surface = S.Services and S.Services.CraftSurfaceV3 or nil
if type(Feature) ~= "table" or type(P) ~= "table" or type(Surface) ~= "table" then return end
local ENTRY_TOPIC = "v3.craft.entry.changed"
local NATIVE_ENTRY_REASON = "当前客户端 O 窗口识别不可用，请使用屏幕配方按钮。"
Feature.NativeAutoEntryAvailable=false
Feature.NativeAutoEntryReason=NATIVE_ENTRY_REASON

local function Position(value)
    if type(value)~='table' or value.userMoved~=true then return nil end
    local out={userMoved=true,coordinateSpace='logical-free-v2'}
    for _,key in ipairs({'x','y','savedUiScale','savedLogicalWidth','savedLogicalHeight','normalizedCenterX','normalizedCenterY'})do
        local n=tonumber(value[key]);if n and n==n and n~=math.huge and n~=-math.huge then out[key]=n end
    end
    if out.x==nil or out.y==nil then return nil end
    return out
end
function Feature:GetScreenButtonState()
    return {visible=self.State.screenButtonVisible~=false,placement=Position(self.State.screenButtonPlacement)}
end
local function ChangeEntry(reason,mutator,topic)
    local loaded,loadErr=Feature:Initialize();if loaded~=true then return false,loadErr end
    local ok,err=P:MutateStore(Feature.storeId,mutator,{durable=true,reason=reason})
    if ok==true and S.Events and type(S.Events.Publish)=='function' then S.Events:Publish(topic or ENTRY_TOPIC,reason) end
    return ok,err
end
function Feature.Commands:SetScreenButtonVisible(value)
    return ChangeEntry('craft_screen_button_visible',function()
        -- nil 代表默认显示，老存档无此键时 canonical 不变。
        if value==true then Feature.State.screenButtonVisible=nil else Feature.State.screenButtonVisible=false end
        return true
    end)
end
function Feature.Commands:SetScreenButtonPosition(x,y,width,height)
    for _,n in ipairs({x,y,width,height})do
        if type(n)~='number' or n~=n or n==math.huge or n==-math.huge then return false,'按钮位置无效' end
    end
    if not x or not y or not width or not height or width<=0 or height<=0 then return false,'按钮位置无效' end
    local layout=S.Layout
    if not layout or type(layout.StorePlacementRect)~='function' then return false,'按钮位置存储不可用' end
    -- 显示/手势用 strict 边界；存档用 free-v2 保存坐标。strict 存储会转换为 edge-v1 并清 x/y。
    local placement={userMoved=true}
    layout:StorePlacementRect(placement,x,y,width,height,{mode='free'})
    placement=Position(placement);if not placement then return false,'按钮位置未确认' end
    return ChangeEntry('craft_screen_button_position',function()Feature.State.screenButtonPlacement=placement;return true end)
end
function Feature.Commands:ResetScreenButtonPosition()
    return ChangeEntry('craft_screen_button_reset',function()Feature.State.screenButtonPlacement=nil;return true end)
end

-- FloatingSurface 持有窗口事务；这里只持久化其标量状态，兼容共享 strict 定位生成的 edge-v1。
local function WindowState(value)
    if type(value)~='table' then return nil end
    local out={}
    for _,key in ipairs({'minimized','locked','userMoved'})do
        if type(value[key])=='boolean' then out[key]=value[key] end
    end
    for _,key in ipairs({'width','height','overallOpacity','backgroundOpacity','textOpacity','fontScale','x','y',
        'offsetX','offsetY','savedUiScale','savedLogicalWidth','savedLogicalHeight','normalizedCenterX','normalizedCenterY'})do
        local n=tonumber(value[key]);if n and n==n and n~=math.huge and n~=-math.huge then out[key]=n end
    end
    if value.coordinateSpace=='logical-free-v2' or value.coordinateSpace=='logical-edge-v1' then out.coordinateSpace=value.coordinateSpace end
    if value.anchorH=='LEFT' or value.anchorH=='RIGHT' then out.anchorH=value.anchorH end
    if value.anchorV=='TOP' or value.anchorV=='BOTTOM' then out.anchorV=value.anchorV end
    return out
end
function Feature:GetCraftWindowState()return WindowState(self.State.craftWindowState)end
function Feature.Commands:SetCraftWindowState(value)
    local nextState=WindowState(value)
    if not nextState or not nextState.width or not nextState.height or nextState.width<=0 or nextState.height<=0 then return false,'配方小窗状态无效' end
    return ChangeEntry('craft_window_state',function()Feature.State.craftWindowState=nextState;return true end,'v3.craft.window.changed')
end
function Feature.Commands:ResetCraftWindowState()
    return ChangeEntry('craft_window_reset',function()Feature.State.craftWindowState=nil;return true end,'v3.craft.window.changed')
end

local function PersistAuto(value)
    value = value == true
    if value then return false,NATIVE_ENTRY_REASON end
    if type(P.MutateStore) ~= "function" then return false, "配方制作设置持久化事务不可用" end
    local ok, err = P:MutateStore(Feature.storeId, function() Feature.State.autoSidecar = value; return true end,
        { delayMs = 300, reason = "craft_auto_sidecar" })
    if ok ~= true then return false, tostring(err or "自动侧窗设置保存失败") end
    Surface:Stop("native_entry_unavailable")
    return true
end

local baseProjection = Feature.GetProjection
function Feature:GetProjection()
    local projection = baseProjection(self) or {}
    projection.autoSidecar = false
    projection.nativeAutoEntryAvailable = false
    projection.nativeAutoEntryReason = NATIVE_ENTRY_REASON
    projection.screenButton = self:GetScreenButtonState()
    projection.craftSurface = Surface:GetSnapshot()
    return projection
end

function Feature.Commands:SetAutoSidecar(value) return PersistAuto(value == true) end

local baseDisable = Feature.Disable
function Feature:Disable(reason)
    Surface:Stop("feature_disabled")
    return baseDisable(self, reason)
end

Feature.CraftSidecarContractVersion = 2

-- 模块导出只取已有缓存；不能因点击诊断而重新读窗口、读计划或取得 Consumer。
local hub = S.ModuleDiagnosticsHub
if type(hub) == "table" and type(hub.RegisterProvider) == "function" then
    hub:RegisterProvider(Feature.Id, "craft_surface_runtime", function()
        local controller = S.UIV3 and S.UIV3.CraftSidecar
        local entry = S.UIV3 and S.UIV3.CraftEntry
        return { enabled = Feature.enabled == true, autoSidecar = false,
            nativeAutoEntryAvailable=false,nativeAutoEntryReason=NATIVE_ENTRY_REASON,
            screenButton=Feature:GetScreenButtonState(),
            craftWindow=Feature:GetCraftWindowState(),
            recipeRead=type(Feature.GetRecipeReadDiagnostics)=='function' and Feature:GetRecipeReadDiagnostics() or nil,
            entry=entry and type(entry.Describe)=='function' and entry:Describe() or {available=false},
            consumerCount = tonumber(Feature.consumerCount) or 0,
            surface = Surface:GetDiagnosticsSnapshot(),
            sidecar = controller and type(controller.Describe) == "function" and controller:Describe() or { available = false } }
    end, 30, { detailOnly = true })
    if type(hub.RegisterStoreOwner) == "function" then
        hub:RegisterStoreOwner(Feature.Id, Feature.storeId)
        hub:RegisterStoreOwner(Feature.Id, "v3.craft_plans")
    end
end
