------------------------------------------------------------------------
-- Replicated Suite - Treasure helper floating widget
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite; S.TreasureWidget={}
function S.TreasureWidget.Create()
    local widget=S.WidgetBase:Create("treasure","寻宝助手",S.Constants.Widget.treasure)
    local win=widget.window
    local summary=S.UI:CreateLabel(win,"treasure_summary","未发现藏宝图",12,0,330,22,10,"muted",ALIGN_LEFT)
    -- Large, reliable eight-way navigation arrow.  This intentionally uses the
    -- same world-space Authority as the existing treasure direction instead of
    -- relying on camera/facing APIs whose runtime return shape differs between
    -- ArcheAge client builds.  North is visually up, matching the world map.
    local arrow=S.UI:CreateLabel(win,"treasure_arrow","--",12,0,330,64,40,"yellow",ALIGN_CENTER)
    local direction=S.UI:CreateLabel(win,"treasure_direction","--",12,0,150,30,11,"yellow",ALIGN_CENTER)
    local distance=S.UI:CreateLabel(win,"treasure_distance","-- m",0,0,150,30,16,"blue",ALIGN_CENTER)
    local refresh=S.UI:CreateButton(win,"treasure_refresh","刷新背包",0,0,82,25,9,false)
    local hint=S.UI:CreateLabel(win,"treasure_hint","仅在悬浮窗显示时每250ms读取玩家坐标；背包由资源服务统一扫描。",12,0,330,20,8,"muted",ALIGN_LEFT)
    local mini=S.UI:CreateLabel(win,"treasure_mini","寻宝 --",8,4,250,22,10,"blue",ALIGN_LEFT); mini:Show(false)
    local function Service() return S.Services and S.Services.Treasure end
    widget.dropdown=S.Dropdown:Create(win,"treasure_map_dd",300,27,8,function(item)
        local svc=Service(); if svc and item then svc:SelectMap(item.value); svc:UpdatePosition(); widget:Refresh() end
    end)
    S.UI:SafeHandler(refresh,"OnClick",function() local svc=Service(); if svc then svc:ForceRefresh(); widget:Refresh() end end,"treasure:refresh")

    function widget:Refresh()
        local d=S.State.data.treasure or {}
        local items={}; for i,m in ipairs(d.maps or {}) do items[#items+1]={value=m.key,text=("藏宝图 %d · %s"):format(i,tostring(m.text or "--"))} end
        self.dropdown:SetItems(items); self.dropdown:SetSelectedValue(d.selectedKey,true)
        if #items==0 then self.dropdown.trigger:SetText("未发现藏宝图  v") end
        summary:SetText(#items>0 and ("背包藏宝图："..tostring(#items).."张") or "未发现带坐标藏宝图")
        local dist=tonumber(d.distance)
        arrow:SetText(tostring(d.arrow or "--"))
        direction:SetText(tostring(d.directionShort or "--").."  "..tostring(d.direction or "--"))
        distance:SetText(dist and (string.format("%.1f m",dist)) or "-- m")
        local tone=dist and (dist<=20 and "green" or dist<=100 and "yellow" or "blue") or "muted"
        S.Theme:SetLabelTone(distance,tone)
        S.Theme:SetLabelTone(arrow,dist and (dist<=20 and "green" or dist<=100 and "yellow" or "blue") or "muted")
        mini:SetText((d.arrow or d.directionShort or "--").."  "..(dist and string.format("%.0fm",dist) or "--"))
    end

    widget.OnLayout=function(self,width,height,titleHeight,mode)
        local scale=S.Layout:GetContext().addonScale; local standard=mode=="standard"; local miniMode=mode=="mini"
        mini:Show(miniMode); for _,c in ipairs({summary,arrow,direction,distance,refresh,hint,self.dropdown.trigger}) do c:Show(standard) end
        if not standard then self.dropdown:Close() end
        if miniMode then mini:SetExtent(width-16*scale,math.max(18*scale,height-titleHeight-8*scale)); S.UI:SetAnchor(mini,win,8*scale,titleHeight+3*scale) end
        if standard then
            local y=titleHeight+8*scale; local full=width-24*scale
            summary:SetExtent(full-90*scale,22*scale); S.UI:SetAnchor(summary,win,12*scale,y)
            refresh:SetExtent(82*scale,25*scale); S.UI:SetAnchor(refresh,win,width-94*scale,y-2*scale)
            y=y+28*scale; self.dropdown:ApplyLayout(12*scale,y,full,27*scale,math.max(full,500*scale))
            y=y+36*scale
            arrow:SetExtent(full,64*scale); S.UI:SetAnchor(arrow,win,12*scale,y)
            y=y+66*scale
            local half=(full-8*scale)/2; direction:SetExtent(half,30*scale); distance:SetExtent(half,30*scale)
            S.UI:SetAnchor(direction,win,12*scale,y); S.UI:SetAnchor(distance,win,12*scale+half+8*scale,y)
            hint:SetText("箭头按地图北向上：↑北 / →东；位置每250ms更新，背包仍由资源服务统一扫描。")
            hint:SetExtent(full,20*scale); S.UI:SetAnchor(hint,win,12*scale,height-27*scale)
        end
        self:Refresh()
    end
    widget:ApplyLayout(false); return widget
end
