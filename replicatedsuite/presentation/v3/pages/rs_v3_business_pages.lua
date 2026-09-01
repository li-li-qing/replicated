------------------------------------------------------------------------
-- Replicated Suite V3 - business Feature pages
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI, D, Host = S.RSUI, S.UIV3Design, S.UIV3 and S.UIV3.PageHost or nil
if type(RSUI) ~= "table" or type(D) ~= "table" or type(Host) ~= "table" then return end
S.UIV3.BusinessPagesContract = { version = 2, componentIdContractVersion = 1, bagProductUxContractVersion = 1, auctionCurrentListingUxContractVersion = 1 }

local ROUTES = {
    { route = "combat.boss_alerts", id = "combat_boss_alerts" }, { route = "combat.target_monitor", id = "combat_target_monitor" },
    { route = "combat.unit_lines", id = "combat_unit_lines" }, { route = "combat.range_assist", id = "combat_range_assist" },
    { route = "combat.buff_cap", id = "combat_buff_cap" }, { route = "combat.team_tools", id = "combat_team_tools" },
    { route = "combat.raid_recruitment", id = "combat_raid_recruitment" }, { route = "combat.siege_readiness", id = "combat_siege_readiness" },
    { route = "life.craft_planner", id = "life_craft_planner" }, { route = "tools.bag_organizer", id = "tools_bag" },
    { route = "tools.auction_favorites", id = "tools_auction" }, { route = "tools.market_analysis", id = "tools_market_analysis" },
    { route = "tools.craft_assist", id = "tools_craft" }, { route = "tools.social", id = "tools_social" },
    { route = "tools.hotkey_profiles", id = "tools_hotkey_profiles" }, { route = "tools.reinforce_analysis", id = "tools_reinforce_analysis" },
    { route = "tools.portal_profiles", id = "tools_portal_profiles" },
}

local BUSINESS_STATUS_ZH = {
    ready = "就绪", idle = "空闲", waiting = "等待结果", partial = "部分可用",
    empty = "暂无数据", unavailable = "不可用", failed = "读取失败", runtime_blocked = "运行时阻塞",
    running = "运行中", complete = "已完成", stopped = "已停止", cancelled = "已取消",
}

local function BusinessStatusText(value)
    local key = tostring(value or "ready")
    return BUSINESS_STATUS_ZH[key] or key
end

local function ValidateBusinessFeature(feature, id)
    if type(feature) ~= "table" then return false, "Feature implementation unavailable: " .. tostring(id) end
    if type(feature.GetProjection) ~= "function" or type(feature.AcquireConsumer) ~= "function" or type(feature.ReleaseConsumer) ~= "function" then
        return false, "Feature public projection/consumer contract incomplete: " .. tostring(id)
    end
    if type(feature.Commands) ~= "table" or type(feature.Commands.Refresh) ~= "function" then
        return false, "Feature Commands.Refresh contract incomplete: " .. tostring(id)
    end
    return true
end

local function Build(parent, route, id)
    local feature = S.Features and S.Features[id]
    local meta = S.FeatureRegistry and S.FeatureRegistry:Get(id)
    local contractOk, contractErr = ValidateBusinessFeature(feature, id)
    if contractOk ~= true then return nil, contractErr end
    local root, err = D:ScrollablePageRoot(parent, "v3_page_business_" .. tostring(id))
    if root == nil then return nil, err end
    root.consumerHeld = false
    D:PageHeader(root, "v3_business_" .. id .. "_header", meta and meta.name or id,
        meta and meta.description or "V3 业务功能页；数据读取由独立 Authority 完成。", "刷新", function()
            local ok, refreshErr = feature.Commands:Refresh("page_manual")
            if ok == true then root:Refresh() end
            return ok, refreshErr
        end)
    local actionRow = RSUI:HorizontalBox({ id = "v3_business_" .. id .. "_actions", parent = root, gap = 6, slot = { size = "fixed", height = 31, hAlign = "fill" } })
    local toggle = RSUI:Button({ id = "v3_business_" .. id .. "_toggle", parent = actionRow, text = "关闭功能", compact = true, slot = { size = "fixed", width = 96 } })
    local hint = RSUI:Text({ id = "v3_business_" .. id .. "_hint", parent = root, text = "", fontSize = 9, tone = "muted", overflow = "wrap", slot = { size = "auto", minHeight = 30, hAlign = "fill" } })
    toggle.onClick = function()
        local enabled = S.FeatureRuntime:IsEnabled(id) == true
        local target = not enabled
        local ok, enableErr = S.FeatureRuntime:SetPreferredEnabled(id, target, "business_page_toggle")
        if ok ~= true then return false, enableErr end
        if target then
            local acquired, acquireErr = feature:AcquireConsumer("page:" .. id)
            if acquired ~= true then
                local rolledBack, rollbackErr = S.FeatureRuntime:SetPreferredEnabled(id, false, "business_page_acquire_rollback")
                root.consumerHeld = false
                root:Refresh()
                if rolledBack ~= true then return false, tostring(acquireErr or "Consumer 启动失败") .. "；回滚失败：" .. tostring(rollbackErr or "unknown") end
                return false, acquireErr
            end
            root.consumerHeld = true
        else
            root.consumerHeld = false
        end
        root:Refresh()
        return true
    end
    if toggle.root ~= nil then S.UI:SafeHandler(toggle.root, "OnClick", toggle.onClick, "v3_business:" .. id) end
    local craftRecipeDropdown, craftActionStatus
    local specialFields = {}
    local function TrackField(field) if field ~= nil then specialFields[#specialFields + 1] = field end return field end
    local bossTestStatus = nil
    if id == "combat_boss_alerts" then
        local hudRow = RSUI:HorizontalBox({ id = "v3_business_combat_boss_alerts_hud_row", parent = root, gap = 6,
            slot = { size = "fixed", height = 30, hAlign = "fill" } })
        TrackField(RSUI:Toggle({ id = "v3_business_combat_boss_alerts_hud_enabled", parent = hudRow,
            onText = "机制 HUD：开", offText = "机制 HUD：关",
            get = function() return (feature:GetProjection() or {}).hudEnabled == true end,
            set = function(v) return feature.Commands:SetHudEnabled(v == true) end,
            slot = { size = "fixed", width = 120 } }))
        TrackField(RSUI:Toggle({ id = "v3_business_combat_boss_alerts_hud_anchor", parent = hudRow,
            onText = "位置：顶部", offText = "位置：中央",
            get = function() return (feature:GetProjection() or {}).hudAnchor == "top" end,
            set = function(v) return feature.Commands:SetHudAnchor(v and "top" or "center") end,
            slot = { size = "fixed", width = 120 } }))
        local testBig = RSUI:Button({ id = "v3_business_combat_boss_alerts_test_big", parent = hudRow, text = "测试大字", compact = true, slot = { size = "fixed", width = 82 } })
        local testCountdown = RSUI:Button({ id = "v3_business_combat_boss_alerts_test_countdown", parent = hudRow, text = "测试倒计时", compact = true, slot = { size = "fixed", width = 92 } })
        bossTestStatus = RSUI:Text({ id = "v3_business_combat_boss_alerts_test_status", parent = hudRow, text = "实时触发待事实桥", fontSize = 8, tone = "muted", overflow = "ellipsis", slot = { size = "fill", fill = 1 } })
        testBig.onClick = function() local ok, actionErr = feature.Commands:TestBigText(); bossTestStatus:SetText(ok and "大字 HUD 已触发" or ("测试失败：" .. tostring(actionErr or "未执行"))); return ok, actionErr end
        testCountdown.onClick = function() local ok, actionErr = feature.Commands:TestCountdown(); bossTestStatus:SetText(ok and "倒计时 HUD 已触发" or ("测试失败：" .. tostring(actionErr or "未执行"))); return ok, actionErr end
        if testBig.root then S.UI:SafeHandler(testBig.root, "OnClick", testBig.onClick, "v3_business:boss:test_big") end
        if testCountdown.root then S.UI:SafeHandler(testCountdown.root, "OnClick", testCountdown.onClick, "v3_business:boss:test_countdown") end
        local hudGrid = RSUI:UniformGrid({ id = "v3_business_combat_boss_alerts_hud_grid", parent = root, minCellWidth = 260, minCellHeight = 30, maxColumns = 2, gap = 5, slot = { size = "auto", minHeight = 30, hAlign = "fill" } })
        TrackField(D:CompactNumericSetting(hudGrid, { id = "v3_business_combat_boss_alerts_font", label = "HUD 字号", min = 18, max = 56, step = 1, integer = true, unit = "", slider = true,
            get = function() return (feature:GetProjection() or {}).hudFontSize or 34 end, set = function(v) return feature.Commands:SetHudFontSize(v) end, slot = { size = "fill", fill = 1, hAlign = "fill" } }))
        TrackField(D:CompactNumericSetting(hudGrid, { id = "v3_business_combat_boss_alerts_duration", label = "显示时长", min = 1000, max = 10000, step = 250, integer = true, unit = "ms", slider = true,
            get = function() return (feature:GetProjection() or {}).hudDurationMs or 3000 end, set = function(v) return feature.Commands:SetHudDurationMs(v) end, slot = { size = "fill", fill = 1, hAlign = "fill" } }))
    elseif id == "combat_unit_lines" then
        local pairRow = RSUI:HorizontalBox({ id = "v3_business_combat_unit_lines_pairs", parent = root, gap = 5,
            slot = { size = "fixed", height = 30, hAlign = "fill" } })
        local pairSpecs = {
            { key="target", on="当前目标：开", off="当前目标：关", field="showTarget" },
            { key="targettarget", on="目标的目标：开", off="目标的目标：关", field="showTargetTarget" },
            { key="focus", on="焦点目标：开", off="焦点目标：关", field="showFocusTarget" },
            { key="focustarget", on="焦点的目标：开", off="焦点的目标：关", field="showFocusTargetTarget" },
        }
        for index, spec in ipairs(pairSpecs) do
            local specRef=spec
            TrackField(RSUI:Toggle({ id="v3_business_combat_unit_lines_pair_"..specRef.key, parent=pairRow,
                onText=specRef.on, offText=specRef.off,
                get=function() return (feature:GetProjection() or {})[specRef.field] ~= false end,
                set=function(v) local ok,e=feature.Commands:SetPairEnabled(specRef.key,v==true); if ok then feature.Commands:Refresh("pair_toggle") end; return ok,e end,
                slot={size="fixed",width=index>=3 and 116 or 112} }))
        end
        local grid = RSUI:UniformGrid({ id = "v3_business_combat_unit_lines_settings", parent = root, minCellWidth = 190, minCellHeight = 30, maxColumns = 4, gap = 5, slot = { size = "auto", minHeight = 30, hAlign = "fill" } })
        TrackField(D:CompactNumericSetting(grid, { id = "v3_business_combat_unit_lines_points", label = "每线点数", min = 8, max = 48, step = 1, integer = true, slider = true,
            get = function() return (feature:GetProjection() or {}).pointCount or 24 end, set = function(v) return feature.Commands:SetPointCount(v) end, slot = { size = "fill", fill = 1, hAlign = "fill" } }))
        TrackField(D:CompactNumericSetting(grid, { id = "v3_business_combat_unit_lines_size", label = "点大小", min = 2, max = 10, step = 1, integer = true, slider = true,
            get = function() return (feature:GetProjection() or {}).pointSize or 4 end, set = function(v) return feature.Commands:SetPointSize(v) end, slot = { size = "fill", fill = 1, hAlign = "fill" } }))
        TrackField(D:CompactNumericSetting(grid, { id = "v3_business_combat_unit_lines_opacity", label = "透明度", min = 0.1, max = 1, step = 0.05, integer = false, slider = true,
            get = function() return (feature:GetProjection() or {}).opacity or 0.78 end, set = function(v) return feature.Commands:SetOpacity(v) end, slot = { size = "fill", fill = 1, hAlign = "fill" } }))
        TrackField(D:CompactNumericSetting(grid, { id = "v3_business_combat_unit_lines_refresh", label = "刷新间隔", min = 1, max = 1000, step = 25, integer = true, unit = "ms", slider = true,
            get = function() return (feature:GetProjection() or {}).refreshMs or 100 end, set = function(v) return feature.Commands:SetRefreshMs(v) end, slot = { size = "fill", fill = 1, hAlign = "fill" } }))
    elseif id == "combat_range_assist" then
        local grid = RSUI:UniformGrid({ id = "v3_business_combat_range_assist_settings", parent = root, minCellWidth = 190, minCellHeight = 30, maxColumns = 2, gap = 5, slot = { size = "auto", minHeight = 60, hAlign = "fill" } })
        TrackField(D:CompactNumericSetting(grid, { id = "v3_business_combat_range_assist_radius", label = "半径", min = 1, max = 100, step = 0.5, integer = false, unit = "m", slider = true,
            get = function() return (feature:GetProjection() or {}).radius or 10 end, set = function(v) return feature.Commands:SetRadius(v) end, slot = { size = "fill", fill = 1, hAlign = "fill" } }))
        TrackField(D:CompactNumericSetting(grid, { id = "v3_business_combat_range_assist_points", label = "圆点数量", min = 12, max = 48, step = 1, integer = true, slider = true,
            get = function() return (feature:GetProjection() or {}).pointCount or 24 end, set = function(v) return feature.Commands:SetPointCount(v) end, slot = { size = "fill", fill = 1, hAlign = "fill" } }))
        TrackField(D:CompactNumericSetting(grid, { id = "v3_business_combat_range_assist_size", label = "点大小", min = 2, max = 10, step = 1, integer = true, slider = true,
            get = function() return (feature:GetProjection() or {}).pointSize or 4 end, set = function(v) return feature.Commands:SetPointSize(v) end, slot = { size = "fill", fill = 1, hAlign = "fill" } }))
        TrackField(D:CompactNumericSetting(grid, { id = "v3_business_combat_range_assist_opacity", label = "透明度", min = 0.1, max = 1, step = 0.05, integer = false, slider = true,
            get = function() return (feature:GetProjection() or {}).opacity or 0.68 end, set = function(v) return feature.Commands:SetOpacity(v) end, slot = { size = "fill", fill = 1, hAlign = "fill" } }))
    end
    local auctionKeywordInput, auctionStatus, auctionPage = nil, nil, 1
    local auctionPageSize, auctionSelectedIndex = 10, nil
    local auctionExactField, auctionLimitField = nil, nil
    if id == "tools_auction" or id == "tools_market_analysis" then
        local row = RSUI:HorizontalBox({ id = "v3_business_" .. id .. "_auction_context", parent = root, gap = 6, slot = { size = "fixed", height = 31, hAlign = "fill" } })
        auctionKeywordInput = RSUI:TextInput({ id = "v3_business_" .. id .. "_auction_keyword", parent = row, value = "", maxLength = 64, allowEmpty = false, placeholder = "物品名称", slot = { size = "fill", fill = 1, minWidth = 160 } })
        local search = RSUI:Button({ id = "v3_business_" .. id .. "_auction_search", parent = row, text = "查询当前挂单", compact = true, slot = { size = "fixed", width = 96 } })
        local add = id == "tools_auction" and RSUI:Button({ id = "v3_business_tools_auction_add", parent = row, text = "加入收藏", compact = true, slot = { size = "fixed", width = 72 } }) or nil
        auctionStatus = RSUI:Text({ id = "v3_business_" .. id .. "_auction_status", parent = root,
            text = id == "tools_auction" and "收藏与当前挂单查询已接入；服务器搜索按 9 参数契约显式执行。" or "这里只展示当前拍卖挂单，不把搜索结果伪装成历史成交行情。",
            fontSize = 8, tone = "muted", overflow = "wrap", maxLines = 2, slot = { size = "auto", minHeight = 26, hAlign = "fill" } })
        local settingRow=RSUI:HorizontalBox({ id="v3_business_"..id.."_auction_settings",parent=root,gap=6,slot={size="fixed",height=31,hAlign="fill"} })
        auctionExactField=TrackField(RSUI:Toggle({ id="v3_business_"..id.."_auction_exact",parent=settingRow,onText="精确匹配：开",offText="精确匹配：关",
            get=function() return (feature:GetProjection() or {}).exactMatch==true end,set=function(v) return feature.Commands:SetExactMatch(v) end,slot={size="fixed",width=104} }))
        auctionLimitField=TrackField(D:CompactNumericSetting(settingRow,{ id="v3_business_"..id.."_auction_limit",label="结果数",min=5,max=30,step=5,integer=true,slider=true,
            get=function() return (feature:GetProjection() or {}).resultLimit or 20 end,set=function(v) return feature.Commands:SetResultLimit(v) end,slot={size="fill",fill=1,hAlign="fill"} }))
        local function keyword() return auctionKeywordInput and type(auctionKeywordInput.GetDraftValue)=="function" and tostring(auctionKeywordInput:GetDraftValue() or "") or "" end
        search.onClick=function()
            local ok,searchErr=feature.Commands:Search(keyword())
            auctionStatus:SetText(ok and "已发送查询，等待服务器返回……" or ("查询失败："..tostring(searchErr or "未执行")))
            root:Refresh(); return ok,searchErr
        end
        if add~=nil then add.onClick=function()
            local ok,addErr=feature.Commands:AddFavorite(keyword())
            auctionStatus:SetText(ok and "已加入收藏" or ("收藏失败："..tostring(addErr or "未执行")))
            if ok then feature.Commands:Refresh("auction_add_favorite"); root:Refresh() end
            return ok,addErr
        end end
        if search.root then S.UI:SafeHandler(search.root,"OnClick",search.onClick,"v3_business:"..id..":auction_search") end
        if add and add.root then S.UI:SafeHandler(add.root,"OnClick",add.onClick,"v3_business:auction:add") end
        local pages=RSUI:HorizontalBox({ id="v3_business_"..id.."_auction_pages",parent=root,gap=6,slot={size="fixed",height=28,hAlign="fill"} })
        local prev=RSUI:Button({ id="v3_business_"..id.."_auction_prev",parent=pages,text="上一页",compact=true,slot={size="fixed",width=64} })
        local next=RSUI:Button({ id="v3_business_"..id.."_auction_next",parent=pages,text="下一页",compact=true,slot={size="fixed",width=64} })
        local remove=id=="tools_auction" and RSUI:Button({ id="v3_business_tools_auction_remove",parent=pages,text="删除收藏",compact=true,slot={size="fixed",width=76} }) or nil
        local pageText=RSUI:Text({ id="v3_business_"..id.."_auction_page_text",parent=pages,text="第 1 页",fontSize=8,tone="muted",slot={size="fill",hAlign="fill"} })
        prev.onClick=function() auctionPage=math.max(1,auctionPage-1); root:Refresh(); return true end
        next.onClick=function() auctionPage=auctionPage+1; root:Refresh(); return true end
        if remove~=nil then remove.onClick=function()
            if auctionSelectedIndex==nil then auctionStatus:SetText("请先选择一条收藏关键词"); return false end
            local ok,removeErr=feature.Commands:RemoveFavorite(auctionSelectedIndex)
            if ok then auctionSelectedIndex=nil; feature.Commands:Refresh("auction_remove"); root:Refresh() else auctionStatus:SetText("删除失败："..tostring(removeErr or "未执行")) end
            return ok,removeErr
        end end
        if prev.root then S.UI:SafeHandler(prev.root,"OnClick",prev.onClick,"v3_business:"..id..":auction_prev") end
        if next.root then S.UI:SafeHandler(next.root,"OnClick",next.onClick,"v3_business:"..id..":auction_next") end
        if remove and remove.root then S.UI:SafeHandler(remove.root,"OnClick",remove.onClick,"v3_business:auction:remove") end
        root.RefreshAuctionPaging=function(self,projection,tableView)
            local source=type(projection.rows)=="table" and projection.rows or {}; local total=#source
            local pagesCount=math.max(1,math.ceil(total/auctionPageSize)); auctionPage=math.min(auctionPage,pagesCount)
            local first=(auctionPage-1)*auctionPageSize+1; local pageRows={}
            for i=first,math.min(first+auctionPageSize-1,total) do pageRows[#pageRows+1]=source[i] end
            tableView:SetItems(pageRows,projection.revision or 0)
            pageText:SetText("第 "..tostring(auctionPage).."/"..tostring(pagesCount).." 页 · 当前 "..tostring(total).." 条"..(id=="tools_auction" and (" · 收藏 "..tostring(projection.favoriteCount or 0)) or ""))
            prev:SetEnabled(auctionPage>1); next:SetEnabled(auctionPage<pagesCount)
        end
    end
    if id == "life_craft_planner" or id == "tools_craft" then
        local craftRow = RSUI:HorizontalBox({ id = "v3_business_" .. id .. "_recipe_row", parent = root, gap = 6,
            slot = { size = "fixed", height = 32, hAlign = "fill" } })
        RSUI:Text({ id = "v3_business_" .. id .. "_recipe_label", parent = craftRow, text = "制作物", fontSize = 9, tone = "strong",
            slot = { size = "fixed", width = 46 } })
        local initialProjection = feature:GetProjection() or {}
        craftRecipeDropdown = RSUI:Dropdown({ id = "v3_business_" .. id .. "_recipe_select", parent = craftRow,
            items = type(initialProjection.recipeOptions)=="table" and initialProjection.recipeOptions or {}, maxVisible = 12, popupWidth = 310,
            get = function() return (feature:GetProjection() or {}).selectedRecipeKey end,
            set = function(value)
                local ok, commandErr = feature.Commands:SelectRecipe(value)
                if ok == true then root:Refresh() end
                return ok, commandErr
            end, placeholder = "选择已核制作物", slot = { size = "fill", fill = 1, minWidth = 220 } })
        local refreshButton = RSUI:Button({ id = "v3_business_" .. id .. "_recipe_refresh", parent = craftRow, text = "刷新材料", compact = true,
            slot = { size = "fixed", width = 78 } })
        craftActionStatus = RSUI:Text({ id = "v3_business_" .. id .. "_context_status", parent = root,
            text = "从制作物列表选择配方；内部配方编号和物品编号只用于诊断，不要求用户输入。", fontSize = 8, tone = "muted", overflow = "wrap", maxLines = 2,
            slot = { size = "auto", minHeight = 26, hAlign = "fill" } })
        refreshButton.onClick = function()
            local ok, refreshErr = feature.Commands:Refresh("craft_page_manual")
            if ok == true then root:Refresh()
            elseif craftActionStatus ~= nil then craftActionStatus:SetText("刷新失败：" .. tostring(refreshErr or "未执行")) end
            return ok, refreshErr
        end
        if refreshButton.root ~= nil then S.UI:SafeHandler(refreshButton.root,"OnClick",refreshButton.onClick,"v3_business:"..id..":refresh") end
    end
    local bagQuickStatus, batchStatus, batchCategoryDropdown, batchTargetToggle, batchLimitField
    if id == "tools_bag" then
        local quickRow = RSUI:HorizontalBox({ id="v3_business_tools_bag_quick_row", parent=root, gap=6,
            slot={ size="fixed",height=31,hAlign="fill" } })
        RSUI:Text({ id="v3_business_tools_bag_quick_label", parent=quickRow, text="日常整理", fontSize=9, tone="strong", slot={size="fixed",width=60} })
        local quickTake=RSUI:Button({ id="v3_business_tools_bag_quick_take", parent=quickRow, text="取同类", compact=true, slot={size="fixed",width=70} })
        local quickPut=RSUI:Button({ id="v3_business_tools_bag_quick_put", parent=quickRow, text="放同类", compact=true, slot={size="fixed",width=70} })
        local quickStop=RSUI:Button({ id="v3_business_tools_bag_quick_stop", parent=quickRow, text="停止", compact=true, slot={size="fixed",width=58} })
        bagQuickStatus=RSUI:Text({ id="v3_business_tools_bag_quick_status", parent=root,
            text="打开银行或箱子后，背包上方会自动出现“取 / 放”；只移动两边已经存在的同类物品。", fontSize=8, tone="muted", overflow="wrap", maxLines=2,
            slot={size="auto",minHeight=26,hAlign="fill"} })
        local function Quick(command)
            local fn=feature.Commands[command]; if type(fn)~="function" then return false,"快捷取放命令不可用" end
            local ok,result=fn(feature.Commands); root:Refresh(); return ok,result
        end
        quickTake.onClick=function() return Quick("QuickWithdraw") end
        quickPut.onClick=function() return Quick("QuickDeposit") end
        quickStop.onClick=function() return Quick("QuickCancel") end
        for name,button in pairs({take=quickTake,put=quickPut,stop=quickStop}) do
            if button.root~=nil then S.UI:SafeHandler(button.root,"OnClick",button.onClick,"v3_business:tools_bag:quick_"..name) end
        end

        local batchRow = RSUI:HorizontalBox({ id="v3_business_tools_bag_batch_row", parent=root, gap=6,
            slot={ size="fixed",height=31,hAlign="fill" } })
        RSUI:Text({ id="v3_business_tools_bag_batch_label", parent=batchRow, text="高级整理", fontSize=9, tone="strong", slot={size="fixed",width=60} })
        local initialBagProjection = feature:GetProjection() or {}
        batchCategoryDropdown = RSUI:Dropdown({ id="v3_business_tools_bag_batch_category", parent=batchRow,
            items=type(initialBagProjection.batchCategoryOptions)=="table" and initialBagProjection.batchCategoryOptions or {}, maxVisible=10, popupWidth=220,
            get=function() return (feature:GetProjection() or {}).batchCategory end,
            set=function(value) return feature.Commands:SetBatchCategory(value) end, placeholder="选择背包内物品类别",
            slot={size="fill",fill=1,minWidth=180} })
        batchTargetToggle = TrackField(RSUI:Toggle({ id="v3_business_tools_bag_batch_target", parent=batchRow,
            onText="目标：箱子", offText="目标：银行", get=function() return (feature:GetProjection() or {}).batchTarget=="coffer" end,
            set=function(v) return feature.Commands:SetBatchTarget(v and "coffer" or "bank") end, slot={size="fixed",width=104} }))
        local startBatch=RSUI:Button({ id="v3_business_tools_bag_batch_start", parent=batchRow, text="开始整理", compact=true, slot={size="fixed",width=72} })
        local stopBatch=RSUI:Button({ id="v3_business_tools_bag_batch_stop", parent=batchRow, text="停止批量", compact=true, slot={size="fixed",width=72} })
        local batchLimitRow=RSUI:HorizontalBox({ id="v3_business_tools_bag_batch_limit_row", parent=root, gap=6, slot={size="fixed",height=31,hAlign="fill"} })
        batchLimitField=TrackField(D:CompactNumericSetting(batchLimitRow,{ id="v3_business_tools_bag_batch_limit",label="最多移动",min=1,max=40,step=1,integer=true,slider=true,
            get=function() return (feature:GetProjection() or {}).batchLimit or 20 end,set=function(v) return feature.Commands:SetBatchLimit(v) end,slot={size="fill",fill=1,hAlign="fill"} }))
        startBatch.onClick=function()
            local projection=feature:GetProjection() or {}; local category=projection.batchCategory
            if category==nil or tostring(category)=="" then return false,"请先从下拉列表选择物品类别" end
            local command=projection.batchTarget=="coffer" and feature.Commands.DepositCategoryCoffer or feature.Commands.DepositCategoryBank
            if type(command)~="function" then return false,"类别整理命令不可用" end
            local ok,result=command(feature.Commands,category,projection.batchLimit or 20); root:Refresh(); return ok,result
        end
        stopBatch.onClick=function() local ok,result=feature.Commands:CancelCategoryBatch(); root:Refresh(); return ok,result end
        if startBatch.root~=nil then S.UI:SafeHandler(startBatch.root,"OnClick",startBatch.onClick,"v3_business:tools_bag:batch_start") end
        if stopBatch.root~=nil then S.UI:SafeHandler(stopBatch.root,"OnClick",stopBatch.onClick,"v3_business:tools_bag:batch_stop") end
        batchStatus = RSUI:Text({ id = "v3_business_tools_bag_batch_status", parent = root,
            text = "高级整理按背包中实际出现的物品类别建立有界队列；与上方快捷取放互斥，避免同时移动物品。",
            fontSize = 8, tone = "muted", overflow = "wrap", maxLines = 2, slot = { size = "auto", minHeight = 26, hAlign = "fill" } })
    end
    if id == "tools_social" then
        local socialRow = RSUI:HorizontalBox({ id = "v3_business_tools_social_member_actions", parent = root, gap = 6,
            slot = { size = "fixed", height = 31, hAlign = "fill" } })
        local socialInput = RSUI:TextInput({ id = "v3_business_tools_social_name", parent = socialRow, value = "", maxLength = 48,
            allowEmpty = false, submitOnLostFocus = false, placeholder = "角色名", slot = { size = "fixed", width = 150 } })
        local socialStatus = RSUI:Text({ id = "v3_business_tools_social_status", parent = root, text = "输入角色名后执行显式名单操作。",
            fontSize = 8, tone = "muted", overflow = "wrap", maxLines = 2, slot = { size = "auto", minHeight = 24, hAlign = "fill" } })
        local actions = {
            { command = "Block", text = "屏蔽" }, { command = "Unblock", text = "取消屏蔽" },
            { command = "Mute", text = "静音" }, { command = "Unmute", text = "取消静音" },
        }
        local function SocialName()
            local name = socialInput and type(socialInput.GetDraftValue) == "function" and tostring(socialInput:GetDraftValue() or "") or ""
            name = name:match("^%s*(.-)%s*$") or ""
            if name == "" or #name > 48 or name:find("[%c]") then return nil, "角色名必须是 1-48 个可见字符" end
            return name
        end
        for index, action in ipairs(actions) do
            -- Lua 5.1 generic-for control variables are shared by closures.
            -- Capture stable locals so all four buttons cannot collapse onto
            -- the final Unmute command after the loop exits.
            local commandRef, textRef = action.command, action.text
            local button = RSUI:Button({ id = "v3_business_tools_social_action_" .. tostring(index), parent = socialRow, text = textRef, compact = true, slot = { size = "fixed", width = 74 } })
            button.onClick = function()
                local name, nameErr = SocialName(); if name == nil then socialStatus:SetText("失败：" .. tostring(nameErr)); return false, nameErr end
                local command = feature.Commands[commandRef]
                if type(command) ~= "function" then socialStatus:SetText("失败：命令不可用"); return false, "命令不可用" end
                local ok, actionErr = command(feature.Commands, name)
                socialStatus:SetText(ok and (textRef .. "已执行") or ("失败：" .. tostring(actionErr or "未执行")))
                if ok then feature.Commands:Refresh("social_" .. commandRef); root:Refresh() end
                return ok, actionErr
            end
            if button.root ~= nil then S.UI:SafeHandler(button.root, "OnClick", button.onClick, "v3_business:tools_social:" .. commandRef) end
        end
    end

    local blacklistScope, blacklistEnabled = "bank", false
    local blacklistStatus = nil
    local bankScopeButton, cofferScopeButton, blacklistToggle = nil, nil, nil
    local itemInput, categoryInput = nil, nil
    local function SetBlacklistStatus(text, tone)
        if blacklistStatus ~= nil then
            blacklistStatus:SetText(tostring(text or ""))
            if S.Theme ~= nil and type(S.Theme.SetLabelTone) == "function" then S.Theme:SetLabelTone(blacklistStatus, tone or "muted") end
        end
    end
    local function ReadDraft(input)
        if input == nil or type(input.GetDraftValue) ~= "function" then return nil, "输入控件不可用" end
        return (tostring(input:GetDraftValue() or ""):match("^%s*(.-)%s*$")) or ""
    end
    local function ReadItemDraft()
        local value, err = ReadDraft(itemInput)
        if value == nil then return nil, err end
        if value == "" or #value > 12 or not value:match("^%d+$") or tonumber(value) == nil or tonumber(value) < 1 then
            return nil, "物品编号必须是正整数"
        end
        return value
    end
    local function ReadCategoryDraft()
        local value, err = ReadDraft(categoryInput)
        if value == nil then return nil, err end
        if value == "" or #value > 64 or value:find("[%c]") ~= nil then return nil, "物品类别编号必须是 1-64 个可见字符" end
        return value
    end
    local function InvokeBlacklist(command, value, input)
        local callOk, commandOk, commandErr = pcall(function()
            if command == "SetBlacklistEnabled" then return feature.Commands:SetBlacklistEnabled(value) end
            if command == "SetBlacklistScope" then return feature.Commands:SetBlacklistScope(value) end
            if command == "AddBlacklistItem" then return feature.Commands:AddBlacklistItem(blacklistScope, value) end
            if command == "RemoveBlacklistItem" then return feature.Commands:RemoveBlacklistItem(blacklistScope, value) end
            if command == "AddBlacklistCategory" then return feature.Commands:AddBlacklistCategory(blacklistScope, value) end
            if command == "RemoveBlacklistCategory" then return feature.Commands:RemoveBlacklistCategory(blacklistScope, value) end
            return false, "未知黑名单命令"
        end)
        if callOk ~= true then SetBlacklistStatus("失败：" .. tostring(commandOk), "warn"); return false, commandOk end
        if commandOk ~= true then SetBlacklistStatus("失败：" .. tostring(commandErr or "黑名单修改未执行"), "warn"); return false, commandErr end
        if input ~= nil and type(input.SetValue) == "function" then input:SetValue("", false, "blacklist_command_success") end
        SetBlacklistStatus("已保存：" .. tostring(command), "success")
        root:Refresh()
        return true
    end
    local function BindBlacklistButton(button, command, input, reader)
        if button == nil then return end
        local handler = function()
            local value, valueErr = reader ~= nil and reader() or nil
            if reader ~= nil and value == nil then SetBlacklistStatus("失败：" .. tostring(valueErr), "warn"); return false, valueErr end
            return InvokeBlacklist(command, value, input)
        end
        button.onClick = handler
        if button.root ~= nil then S.UI:SafeHandler(button.root, "OnClick", handler, "v3_business:tools_bag:" .. command) end
    end
    if id == "tools_bag" then
        blacklistStatus = RSUI:Text({ id = "v3_business_tools_bag_blacklist_status", parent = root,
            text = "黑名单：关 · 默认不拦截", fontSize = 8, tone = "muted", overflow = "wrap", maxLines = 2,
            slot = { size = "auto", minHeight = 26, hAlign = "fill" } })
        local scopeRow = RSUI:HorizontalBox({ id = "v3_business_tools_bag_blacklist_scope_row", parent = root, gap = 6,
            slot = { size = "fixed", height = 28, hAlign = "fill" } })
        RSUI:Text({ id = "v3_business_tools_bag_blacklist_scope_label", parent = scopeRow, text = "黑名单范围", fontSize = 9,
            tone = "strong", overflow = "ellipsis", slot = { size = "fixed", width = 70 } })
        bankScopeButton = RSUI:Button({ id = "v3_business_tools_bag_blacklist_scope_bank", parent = scopeRow, text = "银行", compact = true,
            slot = { size = "fixed", width = 68 } })
        cofferScopeButton = RSUI:Button({ id = "v3_business_tools_bag_blacklist_scope_coffer", parent = scopeRow, text = "箱子", compact = true,
            slot = { size = "fixed", width = 68 } })
        blacklistToggle = RSUI:Button({ id = "v3_business_tools_bag_blacklist_toggle", parent = scopeRow, text = "黑名单：关", compact = true,
            slot = { size = "fixed", width = 92 } })
        local itemRow = RSUI:HorizontalBox({ id = "v3_business_tools_bag_blacklist_item_row", parent = root, gap = 6,
            slot = { size = "fixed", height = 28, hAlign = "fill" } })
        RSUI:Text({ id = "v3_business_tools_bag_blacklist_item_label", parent = itemRow, text = "物品编号", fontSize = 9, tone = "strong",
            overflow = "ellipsis", slot = { size = "fixed", width = 70 } })
        itemInput = RSUI:TextInput({ id = "v3_business_tools_bag_blacklist_item_input", parent = itemRow, value = "", maxLength = 12,
            allowEmpty = true, submitOnLostFocus = false, placeholder = "物品ID", slot = { size = "fixed", width = 92 } })
        local addItemButton = RSUI:Button({ id = "v3_business_tools_bag_blacklist_item_add", parent = itemRow, text = "添加", compact = true,
            slot = { size = "fixed", width = 58 } })
        local removeItemButton = RSUI:Button({ id = "v3_business_tools_bag_blacklist_item_remove", parent = itemRow, text = "删除", compact = true,
            slot = { size = "fixed", width = 58 } })
        local categoryRow = RSUI:HorizontalBox({ id = "v3_business_tools_bag_blacklist_category_row", parent = root, gap = 6,
            slot = { size = "fixed", height = 28, hAlign = "fill" } })
        RSUI:Text({ id = "v3_business_tools_bag_blacklist_category_label", parent = categoryRow, text = "类别编号", fontSize = 9, tone = "strong",
            overflow = "ellipsis", slot = { size = "fixed", width = 70 } })
        categoryInput = RSUI:TextInput({ id = "v3_business_tools_bag_blacklist_category_input", parent = categoryRow, value = "", maxLength = 64,
            allowEmpty = true, submitOnLostFocus = false, placeholder = "如 48（蔬菜）", slot = { size = "fixed", width = 150 } })
        local addCategoryButton = RSUI:Button({ id = "v3_business_tools_bag_blacklist_category_add", parent = categoryRow, text = "添加", compact = true,
            slot = { size = "fixed", width = 58 } })
        local removeCategoryButton = RSUI:Button({ id = "v3_business_tools_bag_blacklist_category_remove", parent = categoryRow, text = "删除", compact = true,
            slot = { size = "fixed", width = 58 } })
        local function BindScopeButton(button, scope)
            if button == nil then return end
            local handler = function() return InvokeBlacklist("SetBlacklistScope", scope) end
            button.onClick = handler
            if button.root ~= nil then S.UI:SafeHandler(button.root, "OnClick", handler, "v3_business:tools_bag:scope:" .. scope) end
        end
        BindScopeButton(bankScopeButton, "bank")
        BindScopeButton(cofferScopeButton, "coffer")
        BindBlacklistButton(blacklistToggle, "SetBlacklistEnabled", nil, function() return not blacklistEnabled end)
        BindBlacklistButton(addItemButton, "AddBlacklistItem", itemInput, ReadItemDraft)
        BindBlacklistButton(removeItemButton, "RemoveBlacklistItem", itemInput, ReadItemDraft)
        BindBlacklistButton(addCategoryButton, "AddBlacklistCategory", categoryInput, ReadCategoryDraft)
        BindBlacklistButton(removeCategoryButton, "RemoveBlacklistCategory", categoryInput, ReadCategoryDraft)
        function root:RefreshBlacklistEditor(projection)
            local config = type(projection) == "table" and projection.blacklist or nil
            config = type(config) == "table" and config or {}
            blacklistEnabled = config.enabled == true
            blacklistScope = config.activeScope == "coffer" and "coffer" or "bank"
            blacklistToggle:SetText(blacklistEnabled and "黑名单：开" or "黑名单：关")
            if bankScopeButton ~= nil and type(bankScopeButton.SetSelected) == "function" then bankScopeButton:SetSelected(blacklistScope == "bank") end
            if cofferScopeButton ~= nil and type(cofferScopeButton.SetSelected) == "function" then cofferScopeButton:SetSelected(blacklistScope == "coffer") end
            local bucket = type(config[blacklistScope]) == "table" and config[blacklistScope] or {}
            local itemCount, categoryCount = 0, 0
            for _ in pairs(type(bucket.itemType) == "table" and bucket.itemType or {}) do itemCount = itemCount + 1 end
            for _ in pairs(type(bucket.category) == "table" and bucket.category or {}) do categoryCount = categoryCount + 1 end
            SetBlacklistStatus((blacklistEnabled and "黑名单：开" or "黑名单：关") .. " · " .. (blacklistScope == "bank" and "银行" or "箱子")
                .. " · 物品编号 " .. tostring(itemCount) .. " · 类别编号 " .. tostring(categoryCount), "muted")
        end
    end
    local teamRoleInput, teamFromMemberInput, teamToMemberInput, teamMovePartyMemberInput, teamToPartyInput, teamActionStatus, teamAutoRoleButton
    if id == "combat_team_tools" then
        local roleRow = RSUI:HorizontalBox({ id = "v3_business_combat_team_tools_role_row", parent = root, gap = 6,
            slot = { size = "fixed", height = 31, hAlign = "fill" } })
        RSUI:Text({ id = "v3_business_combat_team_tools_role_label", parent = roleRow, text = "我的职责", fontSize = 9, tone = "strong",
            overflow = "ellipsis", slot = { size = "fixed", width = 36 } })
        local roleProjection = feature:GetProjection() or {}
        local roleItems = {}
        for _, item in ipairs(type(roleProjection.roleOptions) == "table" and roleProjection.roleOptions or {}) do
            roleItems[#roleItems + 1] = { value = item.value, text = tostring(item.text or item.key or item.value) }
        end
        local teamRoleValue = nil
        teamRoleInput = RSUI:Dropdown({ id = "v3_business_combat_team_tools_role_input", parent = roleRow, items = roleItems, maxVisible = 5,
            get = function() return teamRoleValue end, set = function(value) teamRoleValue = value; return true end,
            placeholder = #roleItems > 0 and "选择职责" or "职责不可用", slot = { size = "fixed", width = 100 } })
        local setRoleButton = RSUI:Button({ id = "v3_business_combat_team_tools_set_role", parent = roleRow, text = "设置我的职责", compact = true,
            slot = { size = "fixed", width = 78 } })
        teamAutoRoleButton = RSUI:Button({ id = "v3_business_combat_team_tools_auto_role", parent = roleRow, text = "自动职责：开", compact = true,
            slot = { size = "fixed", width = 92 } })

        local moveRow = RSUI:HorizontalBox({ id = "v3_business_combat_team_tools_move_row", parent = root, gap = 6,
            slot = { size = "fixed", height = 31, hAlign = "fill" } })
        RSUI:Text({ id = "v3_business_combat_team_tools_from_label", parent = moveRow, text = "从", fontSize = 9, tone = "strong",
            overflow = "ellipsis", slot = { size = "fixed", width = 18 } })
        teamFromMemberInput = RSUI:TextInput({ id = "v3_business_combat_team_tools_from_member_input", parent = moveRow, value = "", maxLength = 2,
            allowEmpty = false, submitOnLostFocus = false, placeholder = "成员1-50", slot = { size = "fixed", width = 68 } })
        RSUI:Text({ id = "v3_business_combat_team_tools_to_label", parent = moveRow, text = "到", fontSize = 9, tone = "strong",
            overflow = "ellipsis", slot = { size = "fixed", width = 18 } })
        teamToMemberInput = RSUI:TextInput({ id = "v3_business_combat_team_tools_to_member_input", parent = moveRow, value = "", maxLength = 2,
            allowEmpty = false, submitOnLostFocus = false, placeholder = "成员1-50", slot = { size = "fixed", width = 68 } })
        local moveButton = RSUI:Button({ id = "v3_business_combat_team_tools_move_member", parent = moveRow, text = "移动成员", compact = true,
            slot = { size = "fixed", width = 78 } })

        local movePartyRow = RSUI:HorizontalBox({ id = "v3_business_combat_team_tools_move_party_row", parent = root, gap = 6,
            slot = { size = "fixed", height = 31, hAlign = "fill" } })
        RSUI:Text({ id = "v3_business_combat_team_tools_party_member_label", parent = movePartyRow, text = "成员", fontSize = 9, tone = "strong",
            overflow = "ellipsis", slot = { size = "fixed", width = 36 } })
        teamMovePartyMemberInput = RSUI:TextInput({ id = "v3_business_combat_team_tools_move_party_member_input", parent = movePartyRow, value = "", maxLength = 2,
            allowEmpty = false, submitOnLostFocus = false, placeholder = "成员1-50", slot = { size = "fixed", width = 68 } })
        RSUI:Text({ id = "v3_business_combat_team_tools_party_label", parent = movePartyRow, text = "到小队", fontSize = 9, tone = "strong",
            overflow = "ellipsis", slot = { size = "fixed", width = 42 } })
        teamToPartyInput = RSUI:TextInput({ id = "v3_business_combat_team_tools_to_party_input", parent = movePartyRow, value = "", maxLength = 2,
            allowEmpty = false, submitOnLostFocus = false, placeholder = "小队1-50", slot = { size = "fixed", width = 68 } })
        local movePartyButton = RSUI:Button({ id = "v3_business_combat_team_tools_move_member_to_party", parent = movePartyRow, text = "移入小队", compact = true,
            slot = { size = "fixed", width = 78 } })
        teamActionStatus = RSUI:Text({ id = "v3_business_combat_team_tools_action_status", parent = root,
            text = "全队职责为只读；职责写入只作用于当前玩家。成员移动当前安全停用。", fontSize = 8, tone = "muted", overflow = "wrap", maxLines = 2,
            slot = { size = "auto", minHeight = 26, hAlign = "fill" } })

        local function ReadTeamToolInteger(input, label, maximum)
            if input == nil or type(input.GetDraftValue) ~= "function" then return nil, label .. " 输入控件不可用" end
            local value = tostring(input:GetDraftValue() or ""):match("^%s*(.-)%s*$") or ""
            local number = tonumber(value)
            if value == "" or not value:match("^%d+$") or number == nil or number < 1 or number > maximum then
                return nil, label .. " 必须是 1-" .. tostring(maximum) .. " 的正整数"
            end
            return number
        end
        local function SetTeamActionStatus(text, tone)
            teamActionStatus:SetText(tostring(text or ""))
            if S.Theme ~= nil and type(S.Theme.SetLabelTone) == "function" then S.Theme:SetLabelTone(teamActionStatus, tone or "muted") end
        end
        local function RefreshTeamAction(reason)
            local commandCallOk, commandRefreshOk, commandRefreshErr = pcall(function() return feature.Commands:Refresh(reason) end)
            local rootCallOk, rootRefreshOk, rootRefreshErr = pcall(function() return root:Refresh() end)
            if commandCallOk ~= true or commandRefreshOk ~= true or rootCallOk ~= true or rootRefreshOk ~= true then
                local detail
                if commandCallOk ~= true then detail = "命令刷新异常：" .. tostring(commandRefreshOk)
                elseif commandRefreshOk ~= true then detail = "命令刷新返回：" .. tostring(commandRefreshErr or commandRefreshOk)
                elseif rootCallOk ~= true then detail = "页面刷新异常：" .. tostring(rootRefreshOk)
                else detail = "页面刷新返回：" .. tostring(rootRefreshErr or rootRefreshOk) end
                return false, "动作已执行，但投影刷新失败：" .. detail
            end
            return true
        end
        teamAutoRoleButton.onClick = function()
            local projection = feature:GetProjection() or {}
            local nextValue = projection.autoRoleEnabled == false
            local ok, err = feature.Commands:SetAutoRoleEnabled(nextValue)
            if ok ~= true then SetTeamActionStatus("自动职责设置失败：" .. tostring(err or "未执行"), "warn"); return false, err end
            root:Refresh()
            SetTeamActionStatus(nextValue and "自动职责已开启；进团或切换职业后会按职业组合自动匹配" or "自动职责已关闭", nextValue and "success" or "muted")
            return true
        end
        setRoleButton.onClick = function()
            local role = teamRoleInput and type(teamRoleInput.GetValue) == "function" and teamRoleInput:GetValue() or nil
            if role == nil then local valueErr = "请选择职责"; SetTeamActionStatus("失败：" .. valueErr, "warn"); return false, valueErr end
            local ok, err = feature.Commands:SetRole(role)
            if ok ~= true then SetTeamActionStatus("失败：" .. tostring(err or "职责设置未执行"), "warn"); return false, err end
            local refreshed, refreshErr = RefreshTeamAction("team_tools_set_role")
            if refreshed ~= true then SetTeamActionStatus(refreshErr, "warn"); return false, refreshErr end
            SetTeamActionStatus("当前玩家职责设置成功", "success"); return true
        end
        moveButton.onClick = function()
            local fromMember, valueErr = ReadTeamToolInteger(teamFromMemberInput, "源成员", 50); if fromMember == nil then SetTeamActionStatus("失败：" .. tostring(valueErr), "warn"); return false, valueErr end
            local toMember; toMember, valueErr = ReadTeamToolInteger(teamToMemberInput, "目标成员", 50); if toMember == nil then SetTeamActionStatus("失败：" .. tostring(valueErr), "warn"); return false, valueErr end
            local ok, err = feature.Commands:MoveMember(fromMember, toMember)
            if ok ~= true then SetTeamActionStatus("失败：" .. tostring(err or "成员移动未执行"), "warn"); return false, err end
            local refreshed, refreshErr = RefreshTeamAction("team_tools_move_member")
            if refreshed ~= true then SetTeamActionStatus(refreshErr, "warn"); return false, refreshErr end
            SetTeamActionStatus("成员移动成功", "success"); return true
        end
        movePartyButton.onClick = function()
            local fromMember, valueErr = ReadTeamToolInteger(teamMovePartyMemberInput, "成员", 50); if fromMember == nil then SetTeamActionStatus("失败：" .. tostring(valueErr), "warn"); return false, valueErr end
            local toParty; toParty, valueErr = ReadTeamToolInteger(teamToPartyInput, "小队", 50); if toParty == nil then SetTeamActionStatus("失败：" .. tostring(valueErr), "warn"); return false, valueErr end
            local ok, err = feature.Commands:MoveMemberToParty(fromMember, toParty)
            if ok ~= true then SetTeamActionStatus("失败：" .. tostring(err or "成员移入小队未执行"), "warn"); return false, err end
            local refreshed, refreshErr = RefreshTeamAction("team_tools_move_member_to_party")
            if refreshed ~= true then SetTeamActionStatus(refreshErr, "warn"); return false, refreshErr end
            SetTeamActionStatus("成员移入小队成功", "success"); return true
        end
        if #roleItems <= 0 then teamRoleInput:SetEnabled(false); setRoleButton:SetEnabled(false) end
        -- Native move APIs are write-capable, but the only known ownership getter
        -- is explicitly disallowed. Keep these controls visible as capability
        -- disclosure, but make the unsafe path impossible to invoke.
        moveButton:SetEnabled(false)
        movePartyButton:SetEnabled(false)
        if teamFromMemberInput ~= nil then teamFromMemberInput:SetEnabled(false) end
        if teamToMemberInput ~= nil then teamToMemberInput:SetEnabled(false) end
        if teamMovePartyMemberInput ~= nil then teamMovePartyMemberInput:SetEnabled(false) end
        if teamToPartyInput ~= nil then teamToPartyInput:SetEnabled(false) end
        SetTeamActionStatus("全队职责只读；仅可设置当前玩家职责。成员移动等待合法队长/权限读取契约", "muted")
        if setRoleButton.root ~= nil then S.UI:SafeHandler(setRoleButton.root, "OnClick", setRoleButton.onClick, "v3_business:combat_team_tools:set_role") end
        if teamAutoRoleButton.root ~= nil then S.UI:SafeHandler(teamAutoRoleButton.root, "OnClick", teamAutoRoleButton.onClick, "v3_business:combat_team_tools:auto_role") end
    end
    local tableView
    tableView = RSUI:TableView({ id = "v3_business_" .. id .. "_table", parent = root, items = {}, rowHeight = 26, headerHeight = 27, desiredRows = 14, scrollbar = true, selectable = id == "tools_auction" or id == "tools_market_analysis", selectionMode = "single", columnResize = true,
        columns = {
            { id = "name", title = "项目", field = "name", size = "fixed", width = 180, minWidth = 100 },
            { id = "text", title = "事实 / 说明", field = "text", size = "fill", minWidth = 220 },
            { id = "cost", title = "成本 / 持有 / 缺口", field = "cost", size = "fixed", width = 190, minWidth = 120, getText = function(item)
                local parts = {}
                for _, line in ipairs(item and item.cost or {}) do parts[#parts + 1] = tostring(line.lineCost or "?") .. "/" .. tostring(line.held or "?") .. "/" .. tostring(line.shortage or "?") end
                return #parts > 0 and table.concat(parts, "; ") or "--"
            end },
            { id = "status", title = "状态", field = "statusText", size = "fixed", width = 110, minWidth = 82, getTone = function(item) return item and item.tone or "muted" end },
        }, slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    if id == "tools_auction" then
        tableView.onSelectionChanged = function(index)
            local row = tableView:GetItem(index)
            auctionSelectedIndex = row and row.favoriteIndex or nil
            if row ~= nil and row.kind == "favorite" and auctionKeywordInput ~= nil and type(auctionKeywordInput.SetValue) == "function" then
                auctionKeywordInput:SetValue(tostring(row.name or ""), false, "auction_favorite_select")
                if auctionStatus ~= nil then auctionStatus:SetText("已载入收藏关键词，点击“查询当前挂单”即可搜索。") end
            end
        end
    end
    function root:Refresh()
        local projection = feature:GetProjection() or {}
        local rows = projection.rows or {}
        for _, field in ipairs(specialFields) do if type(field.Render) == "function" then field:Render() end end
        if (id == "tools_auction" or id == "tools_market_analysis") and self.RefreshAuctionPaging then self:RefreshAuctionPaging(projection, tableView) else tableView:SetItems(rows, projection.revision or 0) end
        if (id == "tools_auction" or id == "tools_market_analysis") and auctionStatus ~= nil then
            local statusZh=({idle="等待查询",waiting="等待服务器",ready="查询完成",partial="部分结果",empty="没有结果",failed="查询失败",unavailable="不可用"})[tostring(projection.searchStatus or "idle")] or tostring(projection.searchStatus or "idle")
            auctionStatus:SetText(statusZh .. " · 当前结果 " .. tostring(projection.resultCount or 0) .. (projection.queryError and (" · " .. tostring(projection.queryError)) or "") .. (id=="tools_market_analysis" and " · 非历史成交价" or ""))
        end
        if id == "life_craft_planner" or id == "tools_craft" then
            local craft = type(projection.craft) == "table" and projection.craft or {}
            local craftStatus = tostring(craft.status or projection.status or "empty")
            local craftError = craft.error or projection.error
            if craftRecipeDropdown ~= nil then
                craftRecipeDropdown.items = type(projection.recipeOptions)=="table" and projection.recipeOptions or {}
                if type(craftRecipeDropdown.Render)=="function" then craftRecipeDropdown:Render() end
            end
            local statusZh = ({ ready="可用", partial="部分可用", empty="等待选择", unavailable="不可用", failed="读取失败", idle="等待选择" })[craftStatus] or craftStatus
            if craftActionStatus ~= nil then
                craftActionStatus:SetText(craftError and (statusZh .. "：" .. tostring(craftError)) or (statusZh .. " · " .. tostring(#rows) .. " 条材料/产物信息"))
                if S.Theme ~= nil and type(S.Theme.SetLabelTone) == "function" then S.Theme:SetLabelTone(craftActionStatus, craftError and "warn" or "muted") end
            end
        end
        if id == "tools_bag" and type(self.RefreshBlacklistEditor) == "function" then self:RefreshBlacklistEditor(projection) end
        if id == "tools_bag" and batchCategoryDropdown ~= nil then
            batchCategoryDropdown.items = type(projection.batchCategoryOptions)=="table" and projection.batchCategoryOptions or {}
            if type(batchCategoryDropdown.Render)=="function" then batchCategoryDropdown:Render() end
        end
        if id == "tools_bag" and projection.batch ~= nil and batchStatus ~= nil then
            local batch = projection.batch
            local statusZh=({idle="等待操作",running="整理中",empty="没有匹配物品",complete="已完成",stopped="已停止",cancelled="已取消"})[tostring(batch.status or "idle")] or "状态未知"
            batchStatus:SetText("批量状态：" .. statusZh .. " · 队列 " .. tostring(batch.queued or 0)
                .. " · 已移动 " .. tostring(batch.moved or 0) .. " · 跳过 " .. tostring(batch.skipped or 0)
                .. (batch.error and (" · " .. tostring(batch.error)) or ""))
        end
        if id == "tools_bag" and bagQuickStatus ~= nil then
            local quick = type(projection.quickButtons) == "table" and projection.quickButtons or {}
            local window = type(projection.windowContext) == "table" and projection.windowContext or {}
            local actionCount = type(quick.actions) == "table" and #quick.actions or 0
            local windowText = window.status == "ready"
                and (window.visible == true and "背包窗口可见" or "背包窗口关闭")
                or ("原生窗口状态未知：" .. tostring(window.reason or "安全拒绝"))
            local overlay = type(projection.quickOverlay)=="table" and projection.quickOverlay or {}
            local storage = overlay.storageKind=="coffer" and "箱子" or overlay.storageKind=="bank" and "银行" or "仓储"
            bagQuickStatus:SetText((overlay.visible==true and (storage .. "已打开 · " .. tostring(overlay.status or "可快捷取放")) or windowText)
                .. " · 已移动 " .. tostring(overlay.moved or 0) .. " · 队列 " .. tostring(overlay.queued or 0))
        end
        if id == "combat_team_tools" and teamAutoRoleButton ~= nil then
            teamAutoRoleButton:SetText(projection.autoRoleEnabled == false and "自动职责：关" or "自动职责：开")
            if projection.autoRoleStatus and teamActionStatus ~= nil then
                teamActionStatus:SetText(tostring(projection.autoRoleStatus) .. (projection.autoRoleLabel and (" · 识别：" .. tostring(projection.autoRoleLabel)) or "") .. "；手动职责仍可覆盖当前结果。")
            end
        end
        local enabled = S.FeatureRuntime:IsEnabled(id) == true
        toggle:SetText(enabled and "关闭功能" or "启用功能")
        if projection.status == "runtime_blocked" then
            hint:SetText("运行时阻塞：" .. tostring(projection.error or (meta and meta.runtimeBlocker) or "未说明") .. "\n当前实现：页面与生命周期已接入；剩余能力需 RU 实机/API 契约证据后才能继续。")
        elseif enabled and (projection.status == "partial" or (meta and meta.status == "migrated_partial")) then
            local detail = projection.error or (meta and meta.remainingCapability) or "部分能力仍待验证"
            hint:SetText("部分可用 · " .. tostring(#rows) .. " 条投影 · " .. tostring(detail))
        else
            hint:SetText(enabled and (BusinessStatusText(projection.status) .. " · " .. tostring(#rows) .. " 条数据") or "功能已关闭；启用后才读取对应 API。")
        end
        return true
    end
    function root:BindFeatureUpdates()
        if S.Events == nil or type(S.Events.SubscribeInternal) ~= "function" or type(feature.UpdateTopic) ~= "string" then return true end
        if type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        return S.Events:SubscribeInternal(feature.UpdateTopic, self, function() root:Refresh() end)
    end
    function root:UnbindFeatureUpdates()
        if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        return true
    end
    function root:OnActivated()
        self:BindFeatureUpdates()
        if S.FeatureRuntime:IsEnabled(id) ~= true then
            self.consumerHeld = false
            return self:Refresh()
        end
        local acquired, acquireErr = feature:AcquireConsumer("page:" .. id)
        if acquired ~= true then return false, acquireErr end
        self.consumerHeld = true
        -- Demand 0->1 owns the initial Authority refresh. Do not immediately
        -- issue a second server/native query from Presentation.
        return self:Refresh()
    end
    function root:OnDeactivated()
        self:UnbindFeatureUpdates()
        if self.consumerHeld then feature:ReleaseConsumer("page:" .. id); self.consumerHeld = false end
        return true
    end
    root.route, root.tableView = route, tableView
    return root
end

local function MakeBusinessFactory(capturedId)
    return function(parent, route) return Build(parent, route, capturedId) end
end
for _, item in ipairs(ROUTES) do
    local ok, err = Host:RegisterFactory(item.route, MakeBusinessFactory(item.id))
    if ok ~= true then error(err) end
end
