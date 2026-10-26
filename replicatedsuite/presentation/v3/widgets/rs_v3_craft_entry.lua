-- Replicated Suite · 配方制作屏幕入口
-- 作者：Replicated
-- QQ群：1104129461
-- 独立按钮进入已有手动小窗；零 Consumer、零周期任务，显隐由 WidgetHost 管理，位置由 Layout/Windowing 管理。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
local R=S.RSUI
local Host=S.UIV3 and S.UIV3.WidgetHost
local Feature=S.Features and S.Features.tools_craft
local Windowing=R and R.Windowing
if not R or not Host or not Feature or not Windowing then return end
local ID,OWNER='tools.craft.entry','v3:craft_entry'
local WIDTH,HEIGHT=112,28
local Entry={lastError=nil,opens=0}
S.UIV3.CraftEntry=Entry
function Entry:Describe()
    return {created=Host:GetInstance(ID)~=nil,visible=Host:IsVisible(ID),opens=self.opens,lastError=self.lastError}
end

local function Create()
    local instance={visible=false}
    local open,openErr=R:Button({id='v3_craft_entry_open',parent='UIParent',text='配方制作',width=WIDTH,height=HEIGHT,
        fontSize=10,compact=true,onClick=function()
            local controller=S.UIV3.CraftSidecar
            if not controller or type(controller.OpenManual)~='function' then return false,'配方小窗不可用' end
            local ok,why=controller:OpenManual()
            Entry.lastError=ok~=true and tostring(why or '打开失败') or nil
            if ok then Entry.opens=Entry.opens+1 end
            return ok,why
        end})
    if not open then return nil,openErr end
    instance.open=open
    local handle,handleErr=R:Button({id='v3_craft_entry_drag',parent=open,text='≡',width=20,height=24,fontSize=9,compact=true})
    if not handle then return nil,handleErr end
    handle:Layout(2,2,20,24)
    instance.root,instance.dragHandle=open.root,handle
    local controller,attachErr=Windowing:Attach({id='v3_craft_entry',owner=OWNER,window=open.root,dragHandle=handle.root,
        resizable=false,locked=false,scaleWithAddon=false,boundaryMode='strict',dragHandleHeight=HEIGHT,
        minWidth=WIDTH,minHeight=HEIGHT,maxWidth=WIDTH,maxHeight=HEIGHT,
        canDrag=function()return instance.visible==true end,
        onGeometryChanged=function(_,x,y,w,h)return Feature.Commands:SetScreenButtonPosition(x,y,w,h)end,
        onGeometryRollback=function()return instance:ApplyLayout()end})
    if not controller then return nil,attachErr end
    instance.windowController=controller
    function instance:ApplyLayout()
        if self.windowController:IsInteracting() then return true end
        local layout=S.Layout
        if not layout or type(layout.ResolvePlacement)~='function' then return false,'配方按钮布局不可用' end
        local position=Feature:GetScreenButtonState().placement
        local x,y,w,h=layout:ResolvePlacement(position,WIDTH,HEIGHT,300,180,
            {mode='strict',topLevel=true,topReachHeight=HEIGHT,reason='craft_entry'})
        return Windowing:ApplyGeometry(self.root,OWNER,x,y,w,h,true)
    end
    controller.onPlacementReady=function()return instance:ApplyLayout()end
    function instance:Show()
        local ok,why=self:ApplyLayout();if ok~=true then return false,why end
        local _,accepted,err=open:SetVisibility('visible');if accepted~=true then return false,err end
        self.visible=true
        -- RU 首次 Show 可调整锚点，使用同一解算器确认显示后的最终位置。
        ok,why=self:ApplyLayout()
        if ok~=true then self:Hide();return false,why end
        if S.UI and type(S.UI.TrySetUILayer)=='function' then S.UI:TrySetUILayer(self.root,'system') end
        return true
    end
    function instance:Hide()
        self.windowController:CancelInteraction()
        local _,accepted,err=open:SetVisibility('hidden')
        if accepted~=true then return false,err end
        self.visible=false;return true
    end
    local hidden,hideErr=instance:Hide();if not hidden then return nil,hideErr end
    return instance
end

local registered,registerErr=Host:Register(ID,{featureId='tools_craft',create=Create,
    ensurePreferences=function()return Feature:Initialize()end})
if not registered then error(registerErr) end
local function Enabled()return S.FeatureRuntime and S.FeatureRuntime:IsEnabled('tools_craft')==true end
local bound,bindErr=Host:BindFeatureLifecycle(ID,{featureId='tools_craft',enabled=Enabled,
    preference=function()return Feature:GetScreenButtonState().visible end})
if not bound then error(bindErr) end
local function Sync(reason)
    if Enabled() then
        local loaded,loadErr=Feature:Initialize();if loaded~=true then return false,loadErr end
    end
    local desired=Enabled() and Feature:GetScreenButtonState().visible
    if Host:IsVisible(ID)~=desired then
        local ok,why=Host:SetVisible(ID,desired,{persist=false,source='craft_entry:'..tostring(reason)})
        Entry.lastError=ok~=true and tostring(why or '入口显示失败') or nil
        return ok,why
    end
    local instance=Host:GetInstance(ID)
    if desired and instance then
        if reason=='craft_screen_button_reset' then instance.windowController:CancelInteraction() end
        return instance:ApplyLayout()
    end
    return true
end
if S.Events and type(S.Events.SubscribeInternal)=='function' then
    S.Events:SubscribeInternal('v3.craft.entry.changed',Entry,function(_,reason)return Sync(reason)end)
end
if Enabled() then Sync('registered') end
