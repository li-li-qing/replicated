------------------------------------------------------------------------
-- Replicated Suite - User Favorites / common-entry registry
-- New entries are never inserted automatically. Order is user Authority.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
S.Favorites={registry={},order={}}
local F=S.Favorites

local function Normalize(value) return tostring(value or ""):lower():gsub("[^%w_:%-]","") end
local function Saved()
    S.State.product=S.State.product or {}
    S.State.product.favorites=type(S.State.product.favorites)=="table" and S.State.product.favorites or {}
    return S.State.product.favorites
end
function F:Register(id,title,kind,target)
    id=Normalize(id); if id=="" then return false end
    if self.registry[id]==nil then self.order[#self.order+1]=id end
    self.registry[id]={id=id,title=tostring(title or id),kind=tostring(kind or "page"),target=tostring(target or "")}
    return true
end
function F:IsFavorite(id)
    id=Normalize(id); for _,savedId in ipairs(Saved()) do if savedId==id then return true end end; return false
end
function F:Add(id)
    id=Normalize(id); if self.registry[id]==nil or self:IsFavorite(id) then return false end
    local list=Saved(); list[#list+1]=id; if S.Storage then S.Storage:RequestSave() end; if S.State then S.State:MarkDirty("favorites") end; return true
end
function F:Remove(id)
    id=Normalize(id); local list=Saved(); for i=#list,1,-1 do if list[i]==id then table.remove(list,i); if S.Storage then S.Storage:RequestSave() end; if S.State then S.State:MarkDirty("favorites") end; return true end end; return false
end
function F:Toggle(id) if self:IsFavorite(id) then self:Remove(id); return false else self:Add(id); return true end end
function F:Move(id,delta)
    id=Normalize(id); local list=Saved(); local at=nil; for i,v in ipairs(list) do if v==id then at=i break end end
    if at==nil then return false end; local to=math.max(1,math.min(#list,at+(tonumber(delta) or 0))); if to==at then return true end
    table.remove(list,at); table.insert(list,to,id); if S.Storage then S.Storage:RequestSave() end; return true
end
function F:List()
    local result={}; for _,id in ipairs(Saved()) do local d=self.registry[id]; if d~=nil then result[#result+1]=d end end; return result
end
function F:Activate(id)
    local d=self.registry[Normalize(id)]; if d==nil then return false end
    if d.kind=="page" then if S.UIHostManager and S.UIHostManager.OpenPage then return S.UIHostManager:OpenPage(d.target)==true end
    elseif d.kind=="hud" then if S.HudManager then S.HudManager:SetVisible(d.target,true,true); return true end
    elseif d.kind=="module" then
        if S.ModuleManager and S.ModuleManager.IsRegistered and S.ModuleManager:IsRegistered(d.target) then
            local ok = S.ModuleManager:OpenSettings(d.target)
            if ok then return true end
        end
        if S.Services and S.Services.Professional and S.Services.Professional.Open then return S.Services.Professional:Open(d.target) end
        if S.UIHostManager and S.UIHostManager.OpenPage then return S.UIHostManager:OpenPage("modules")==true end
    end
    return false
end

for _,d in ipairs({
    {"page:activity","首页活动（旧常用兼容）","page","life"},{"page:combat","伤害统计（旧常用兼容）","page","dps"},{"page:modules","模块管理","page","modules"},
    {"page:team","团队辅助","page","team"},
    {"page:dps","伤害统计","page","dps"},{"page:healer","治疗辅助","page","healer"},{"page:gear","一键换装","page","gear"},{"page:plates","BUFF显示","page","plates"},
    {"page:hud","HUD 管理","page","hud"},{"page:settings","设置","page","settings"},{"page:diagnostics","诊断","page","diagnostics"},
    {"hud:task","任务追踪","hud","task"},{"hud:trade","跑商货率","hud","trade"},{"hud:bond","债券 / 居民板","hud","bond"},
    {"hud:event","活动时间","hud","event"},{"hud:treasure","寻宝助手","hud","treasure"},{"hud:fishing","钓鱼助手","hud","fishing"},
    {"hud:gear_quick","换装快捷栏","hud","gear_quick"},{"hud:dps_friendly","DPS 友军排行","hud","dps_friendly"},{"hud:dps_enemy","DPS 敌军排行","hud","dps_enemy"},
    {"module:dps","伤害统计","module","dps"},{"module:gear","一键换装","module","gear"},{"module:healer","治疗辅助","module","healer"},{"module:plates","BUFF显示","module","plates"},
    {"module:team_utility","团队辅助","page","team"},
}) do F:Register(d[1],d[2],d[3],d[4]) end
