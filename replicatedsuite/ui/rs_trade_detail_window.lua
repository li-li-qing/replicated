------------------------------------------------------------------------
-- Replicated Suite - Trade material / auction-cost detail window
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
S.TradeDetailWindow={}
local W=S.TradeDetailWindow

function W.Create()
    local managed=S.UI:CreateManagedWindow({id="trade_detail",width=580,height=430,minWidth=580,minHeight=430,maxWidth=580,maxHeight=430,resizable=false})
    if managed==nil then return nil end
    local win=managed.window
    S.Theme:AddBorder(win,false); S.Theme:AddGradientBackground(win,"panel",nil)
    W.window=win; W.managed=managed; S.UI.windows.tradeDetail=win

    local titleBar=S.UI:CreatePanel(win,"trade_detail_titlebar",1,1,558,30,"header")
    W.title=S.UI:CreateLabel(titleBar,"trade_detail_title","贸易品材料 / 毛利",10,4,470,22,14,nil,ALIGN_LEFT)
    W.close=S.UI:CreateButton(titleBar,"trade_detail_close","X",0,3,28,24,11,false)
    W.route=S.UI:CreateLabel(win,"trade_detail_route","",12,38,530,22,10,"muted",ALIGN_LEFT)
    W.pack=S.UI:CreateLabel(win,"trade_detail_pack","",12,63,530,24,12,nil,ALIGN_LEFT)
    W.summary=S.UI:CreateLabel(win,"trade_detail_summary","",12,89,530,22,10,"blue",ALIGN_LEFT)
    W.header=S.UI:CreateLabel(win,"trade_detail_header","材料                              数量    拍卖单价     成本      操作",12,119,530,22,9,"muted",ALIGN_LEFT)
    W.rows={}
    for i=1,8 do
        W.rows[i]={
            name=S.UI:CreateLabel(win,"trade_detail_mat_name_"..i,"",12,0,192,22,10,nil,ALIGN_LEFT),
            count=S.UI:CreateLabel(win,"trade_detail_mat_count_"..i,"",210,0,42,22,10,"muted",ALIGN_RIGHT),
            price=S.UI:CreateLabel(win,"trade_detail_mat_price_"..i,"",258,0,76,22,10,"muted",ALIGN_RIGHT),
            cost=S.UI:CreateLabel(win,"trade_detail_mat_cost_"..i,"",340,0,88,22,10,"muted",ALIGN_RIGHT),
            take=S.UI:CreateButton(win,"trade_detail_mat_take_"..i,"取",0,0,32,22,9,false),
            put=S.UI:CreateButton(win,"trade_detail_mat_put_"..i,"放",0,0,32,22,9,false),
            auc=S.UI:CreateButton(win,"trade_detail_mat_auc_"..i,"拍",0,0,32,22,9,false),
        }
        for _,c in pairs(W.rows[i]) do
            if type(c.Show)=="function" then c:Show(false) end
        end
    end
    W.total=S.UI:CreateLabel(win,"trade_detail_total","材料成本：--    预计毛利：--",12,0,350,24,11,"yellow",ALIGN_LEFT)
    W.query=S.UI:CreateButton(win,"trade_detail_query","查价格",0,0,90,26,9,false)
    W.retry=S.UI:CreateButton(win,"trade_detail_refresh","重新查",0,0,78,26,9,false)
    W.hint=S.UI:CreateLabel(win,"trade_detail_hint","",12,0,530,22,9,"muted",ALIGN_LEFT)

    managed:BindTitleBar(titleBar)
    S.UI:SafeHandler(W.close,"OnClick",function() managed:Show(false) end,"trade_detail:close")
    local function Query()
        local trade=S.Services and S.Services.Trade
        if trade and type(trade.QuoteSelectedPack)=="function" then trade:QuoteSelectedPack(); W:Refresh() end
    end
    S.UI:SafeHandler(W.query,"OnClick",Query,"trade_detail:query")
    S.UI:SafeHandler(W.retry,"OnClick",Query,"trade_detail:retry")

    -- P1-2: per-material 取/放/拍卖. Directed bag moves pass the material's
    -- itemType so BagOrganizer moves only the matching identity (取 = storage
    -- -> bag for items the bag already holds; 放 = bag -> storage reverse).
    -- Auction (F1) pushes the official CN display name into the temp search
    -- queue and opens the favorites window; the row click there searches.
    local function RowMaterial(i)
        local d=S.State.data.trade or {}; local selected=d.selectedPack
        if type(selected)~="table" then return nil end
        local materials=selected.materials or {}
        return materials[i]
    end
    local function MaterialMove(i, direction)
        local mat=RowMaterial(i)
        if mat==nil then return end
        local bo=S.Services and S.Services.BagOrganizer
        if bo==nil or type(bo.Begin)~="function" then S.SafeChat("整理背包服务尚未就绪"); return end
        local itemType=tonumber(mat.itemType)
        if itemType==nil then
            S.SafeChat("该材料无物品ID（静态配方无 itemType 映射），无法"..(direction=="withdraw" and "取出" or "放入").."。")
            return
        end
        local ok, count = bo:Begin(direction, { itemType = itemType })
        if ok ~= true then
            -- Begin already chats its own failure message.
            return
        end
        local planned = tonumber(count) or 0
        if planned <= 0 then
            S.SafeChat(direction=="withdraw" and "未找到仓库中与背包同身份且为该材料的物品。" or "未找到背包中与仓库同身份且为该材料的物品。")
        end
    end
    local function MaterialAuction(i)
        local mat=RowMaterial(i)
        if mat==nil then return end
        local fav=S.Services and S.Services.AuctionFavorites
        if fav==nil then S.SafeChat("拍卖收藏夹服务尚未就绪"); return end
        -- Official CN display name is the temp-row text AND the search keyword.
        -- mat.name (EN) is identity only and never appears in UI/search (F1).
        local official
        if type(fav.ResolveOfficialName)=="function" then
            official=fav:ResolveOfficialName(mat.itemType, mat.displayName or mat.name)
        else
            official=mat.displayName or mat.name
        end
        if official==nil or tostring(official)=="" then S.SafeChat("该材料缺少官方名称。"); return end
        local okPush, pushErr = fav:PushTemp(official)
        if okPush ~= true and pushErr ~= nil then S.SafeChat("加入临时搜索失败："..tostring(pushErr)) end
        local ui=S.AuctionFavoritesWindow
        if ui~=nil and type(ui.Show)=="function" then
            if type(ui.Create)=="function" then ui:Create() end
            ui:Show(true)
            if type(ui.SetMode)=="function" then ui:SetMode("temp") end
            if type(ui.RefreshList)=="function" then ui:RefreshList(true) end
        end
    end
    -- UTF-8 safe byte truncation for the narrower name column (P1-2). Keeps
    -- long game item names inside the row without engine ellipsis; the
    -- "(不计成本)" suffix is appended after truncating the name part.
    local function TruncateName(text, byteLimit) return S.Utils.TruncateUtf8(text, byteLimit, "…") end
    for i=1,8 do
        local row=W.rows[i]
        S.UI:SafeHandler(row.take,"OnClick",function() MaterialMove(i,"withdraw") end,("trade_detail:mat_%d_take"):format(i))
        S.UI:SafeHandler(row.put,"OnClick",function() MaterialMove(i,"deposit") end,("trade_detail:mat_%d_put"):format(i))
        S.UI:SafeHandler(row.auc,"OnClick",function() MaterialAuction(i) end,("trade_detail:mat_%d_auc"):format(i))
    end

    function W:ApplyLayout(first)
        local scale=S.Layout:GetContext().addonScale
        local width,height=580*scale,430*scale
        managed:ApplyPlacement(width,height); titleBar:SetExtent(width-2,30*scale)
        W.close:SetExtent(28*scale,24*scale); S.UI:SetAnchor(W.close,titleBar,width-34*scale,3*scale)
        for _,label in ipairs({W.route,W.pack,W.summary,W.header,W.hint}) do label:SetExtent(width-24*scale,22*scale) end
        S.UI:SetAnchor(W.route,win,12*scale,38*scale); S.UI:SetAnchor(W.pack,win,12*scale,63*scale); S.UI:SetAnchor(W.summary,win,12*scale,89*scale); S.UI:SetAnchor(W.header,win,12*scale,119*scale)
        local startY=146*scale; local rowH=27*scale
        for i,row in ipairs(W.rows) do
            local y=startY+(i-1)*rowH
            row.name:SetExtent(192*scale,22*scale); row.count:SetExtent(42*scale,22*scale); row.price:SetExtent(76*scale,22*scale); row.cost:SetExtent(88*scale,22*scale)
            row.take:SetExtent(32*scale,22*scale); row.put:SetExtent(32*scale,22*scale); row.auc:SetExtent(32*scale,22*scale)
            S.UI:SetAnchor(row.name,win,12*scale,y); S.UI:SetAnchor(row.count,win,210*scale,y); S.UI:SetAnchor(row.price,win,258*scale,y); S.UI:SetAnchor(row.cost,win,340*scale,y)
            S.UI:SetAnchor(row.take,win,436*scale,y); S.UI:SetAnchor(row.put,win,472*scale,y); S.UI:SetAnchor(row.auc,win,508*scale,y)
        end
        local footerY=height-69*scale
        W.total:SetExtent(width-210*scale,24*scale); S.UI:SetAnchor(W.total,win,12*scale,footerY)
        W.query:SetExtent(90*scale,26*scale); S.UI:SetAnchor(W.query,win,width-184*scale,footerY-2*scale)
        W.retry:SetExtent(78*scale,26*scale); S.UI:SetAnchor(W.retry,win,width-88*scale,footerY-2*scale)
        S.UI:SetAnchor(W.hint,win,12*scale,height-34*scale)
    end

    function W:Refresh()
        local d=S.State.data.trade or {}; local selected=d.selectedPack
        if type(selected)~="table" then return end
        W.route:SetText(tostring(d.route or "--"))
        W.pack:SetText(tostring(selected.name or "--"))
        W.summary:SetText("货率："..tostring(selected.rate or "--").."    预计售价："..tostring(selected.price or "--"))
        local materials=selected.materials or {}
        for i,row in ipairs(W.rows) do
            local mat=materials[i]; local show=mat~=nil
            row.name:Show(show); row.count:Show(show); row.price:Show(show); row.cost:Show(show)
            row.take:Show(show); row.put:Show(show); row.auc:Show(show)
            if show then
                local base=tostring(mat.displayName or mat.name or "")
                local notCost=mat.includeInCost==false
                local display
                if notCost then
                    -- Truncate the name part only; keep the suffix intact.
                    local nameOnly=TruncateName(base,22)
                    display=nameOnly.."（不计成本）"
                else
                    display=TruncateName(base,34)
                end
                row.name:SetText(display)
                row.count:SetText("X"..tostring(mat.count or 0))
                if notCost then
                    row.price:SetText("不计")
                    row.cost:SetText("不计")
                else
                    row.price:SetText(mat.priceCopper and S.Utils.FormatMoney(mat.priceCopper,false) or "--")
                    row.cost:SetText(mat.costCopper and S.Utils.FormatMoney(mat.costCopper,false) or "--")
                end
                local itemType=tonumber(mat.itemType)
                local canMove=itemType~=nil
                if row.take.Enable~=nil then row.take:Enable(canMove) end
                if row.put.Enable~=nil then row.put:Enable(canMove) end
            end
        end
        local has=#materials>0
        if W.query.Enable~=nil then W.query:Enable(has and selected.quoteStatus~="loading") end
        if W.retry.Enable~=nil then W.retry:Enable(has and selected.quoteStatus~="loading") end
        W.total:SetText("材料成本："..tostring(selected.materialCost or "--").."    预计毛利："..tostring(selected.profit or "--"))
        S.Theme:SetLabelTone(W.total,tonumber(selected.profitCopper) and selected.profitCopper>=0 and "green" or (tonumber(selected.profitCopper) and "red" or "yellow"))
        local sourceText=(selected.recipeSource=="live") and "游戏当前配方" or ((selected.recipeSource=="static") and "静态备份配方" or "未识别配方")
        local hint=tostring(selected.quoteText or (has and "材料表已匹配" or "未匹配材料表"))
        W.hint:SetText("配方来源："..sourceText.." · "..hint)
    end

    function W:ShowPack()
        if W.window==nil then return end
        W:ApplyLayout(false); W:Refresh(); W.managed:Show(true)
    end

    W:ApplyLayout(true); win:Show(false)
    if S.Layout~=nil and type(S.Layout.RegisterFloating)=="function" then
        S.Layout:RegisterFloating("trade_detail",win,{onlyWhenVisible=true,ensureNow=false,onMetricsChanged=function(changed) if changed==true then W:ApplyLayout(true) else S.Layout:EnsureWidgetVisible(win,{onlyWhenVisible=true}) end end})
    end
    return win
end
