------------------------------------------------------------------------
-- 主菜单外观（2026-10-07）：仅保存主菜单三个 alpha 通道和局部字号。
-- 复用 Persistence；旧 v3.shell/v3.workspace canonical 不变，几何与主题仍由原 Store 所有。
-- 预览不写盘；明确提交通过 MutateStore 单次保存并读回，失败由 Shell 撤回预览。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S,P=ReplicatedSuite,ReplicatedSuite.Persistence
if type(P)~="table" then return end
S.UIV3=S.UIV3 or {}
local A={storeId="v3.presentation.main_appearance",version=1}
S.UIV3.MainAppearance=A
local FIELDS={overallOpacity={0.10,1},backgroundOpacity={0,1},textOpacity={0.10,1},fontScale={0.50,2}}
local function Number(value,limits)
    local n=tonumber(value)
    if n==nil or n~=n or n==math.huge or n==-math.huge then n=1 end
    return math.floor(math.max(limits[1],math.min(limits[2],n))*10000+0.5)/10000
end
function A:Normalize(value)
    local out={};value=type(value)=="table" and value or {}
    for key,limits in pairs(FIELDS)do out[key]=Number(value[key],limits)end
    return out
end
A.state=A:Normalize(nil)
function A:GetSettings()return self:Normalize(self.state)end
function A:Candidate(patch)
    local out=self:GetSettings()
    for key,value in pairs(type(patch)=="table" and patch or {})do
        if not FIELDS[key]then return nil,"未知主菜单外观选项"end
        out[key]=value
    end
    return self:Normalize(out)
end
if not P:GetStore(A.storeId)then
    local store,err=P:RegisterV3Store({id=A.storeId,owner=A.storeId,scope=P.Scope.Account,lifetime=P.Lifetime.Permanent,
        schemaVersion=1,legacySchemaVersion=0,key=P.V3KeyPrefix.."presentation_main_appearance",
        budget={maxDepth=3,maxNodes=32,maxStringBytes=1024,maxEntriesPerTable=16},
        default=function()return A:Normalize(nil)end,get=function()return A:GetSettings()end,
        apply=function(value)A.state=A:Normalize(value)end,migrate=function(value)return A:Normalize(value)end})
    if not store then A.error=tostring(err or "主菜单外观存档不可用")end
end
function A:EnsureLoaded()
    if not P:GetStore(self.storeId)then return false,self.error or "主菜单外观存档不可用"end
    local ok,err=P:PrepareRead(self.storeId)
    self.error=ok~=true and tostring(err or "主菜单外观读取失败") or nil
    return ok,err
end
function A:Save(value)
    local ok,err=self:EnsureLoaded();if ok~=true then return false,err end
    local normalized=self:Normalize(value)
    return P:MutateStore(self.storeId,function()self.state=normalized;return true end,
        {durable=true,reason="main_window_appearance"})
end
function A:RegisterDiagnostics()
    local hub=S.ModuleDiagnosticsHub
    if type(hub)~="table" then return false end
    hub:RegisterStoreOwner("system_workspace",self.storeId)
    return hub:RegisterProvider("system_workspace","main_appearance",function()
        local shell=S.UIV3.Shell
        return {settings=A:GetSettings(),loadError=A.error,created=type(shell)=="table" and shell.created==true}
    end,30,{detailOnly=true})
end
A:RegisterDiagnostics()
