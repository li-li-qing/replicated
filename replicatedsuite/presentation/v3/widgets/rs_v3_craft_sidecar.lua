-- Replicated Suite · 配方制作小窗
-- 作者：Replicated
-- QQ群：1104129461
-- 独立窗口位置/拖动归 FloatingSurface 与 Windowing，不再按原生窗口贴边。配方/材料归 tools_craft，市场报价仅由用户明确
-- “材料询价”操作经 Feature 命令与 PriceQuoteQueueV3 提交。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local RSUI = S.RSUI
local Host = S.UIV3 and S.UIV3.WidgetHost or nil
local Floating = RSUI and RSUI.FloatingSurface or nil
local Feature = S.Features and S.Features.tools_craft or nil
local SurfaceService = S.Services and S.Services.CraftSurfaceV3 or nil
if type(RSUI) ~= "table" or type(Host) ~= "table" or type(Floating) ~= "table"
    or type(Feature) ~= "table" or type(SurfaceService) ~= "table" then return end

local WIDGET_ID = "tools.craft_sidecar"
local OWNER = "v3:widget:craft_sidecar"
local WIDTH, HEIGHT = 360, 430
local MAX_WIDTH, MAX_HEIGHT = 1600, 1200
-- 成本不能使用省略铜币的紧凑格式，否则不同方案的实际金额会被显示成相同。
local function Money(value)
    local n=math.max(0,math.floor(tonumber(value) or 0))
    local gold=math.floor(n/10000)
    local silver=math.floor((n%10000)/100)
    local copper=n%100
    if gold>0 then return string.format('%d金%02d银%02d铜',gold,silver,copper) end
    if silver>0 then return string.format('%d银%02d铜',silver,copper) end
    return tostring(copper)..'铜'
end
local function QuoteFailure(query)
    local code=tostring(query.code or query.reason or '')
    if code=='strict_grade_mismatch' then return '品质不符' end
    if code=='strict_item_mismatch' then return '物品不符' end
    if code=='strict_search_grade_invalid' then return '品质待核' end
    if code=='auction_listing_unverified' then return '字段待核' end
    if code=='strict_buyout_unavailable' then return '无一口价' end
    if code=='strict_sample_unmatched' or code=='strict_buyout_not_found' then return '样本未匹配' end
    if code:find('deadline',1,true) or code:find('timeout',1,true) then return '查询超时' end
    return '查询失败'
end

local Controller = { nativeVisible = false, manualVisible = false, dismissed = false, snapshot = nil, observations = 0, showAttempts = 0, showFailures = 0 }
S.UIV3 = S.UIV3 or {}
S.UIV3.CraftSidecar = Controller
function Controller:Describe()
    local instance=Host and type(Host.GetInstance)=='function' and Host:GetInstance(WIDGET_ID) or nil
    local split=instance and instance.bodySplit
    local evidence=split and split.dragEvidence
    local divider=evidence and {starts=evidence.starts,stops=evidence.stops,updates=evidence.updates,raises=evidence.raises,
        inputSurface=evidence.inputSurface,dragEnabled=evidence.dragEnabled,dragConditionAvailable=evidence.dragConditionAvailable,dragConditionApplied=evidence.dragConditionApplied,
        clicks=evidence.clicks or 0,clickHandler=evidence.clickHandler,lastInput=evidence.lastInput,
        nativeEnabled=evidence.nativeEnabled,nativeVisible=evidence.nativeVisible,nativeMouseOver=evidence.nativeMouseOver,
        status=evidence.status,reason=evidence.reason,handlers=evidence.handlers,hovers=evidence.hovers or 0,delta=evidence.delta,unitScale=evidence.unitScale,limited=evidence.limited,startPrimary=evidence.startPrimary,
        finalPrimary=evidence.finalPrimary,raiseError=evidence.raiseError,primarySize=split.primarySize,
        minPrimary=split.minPrimary,minSecondary=split.minSecondary,height=split.height,
        degraded=split.rsUiDegraded,degradedReason=split.rsUiDegradedReason} or nil
    return { nativeVisible = self.nativeVisible == true, manualVisible = self.manualVisible == true, dismissed = self.dismissed == true,
        observations = self.observations, showAttempts = self.showAttempts, showFailures = self.showFailures,
        lastDecision = self.lastDecision, lastSource = self.lastSource, lastReason = self.lastReason,
        lastShowError = self.lastShowError,actionAttempts=self.actionAttempts or 0,
        lastAction=self.lastAction,lastActionResult=self.lastActionResult,lastActionError=self.lastActionError,divider=divider,render=instance and instance.renderEvidence,
        priceAction=instance and instance.quote and {text=instance.quote.text,enabled=instance.quote.enabled,
            visibility=instance.quote.visibility,x=instance.quote.x,y=instance.quote.y,width=instance.quote.width,height=instance.quote.height,
            rowWidth=instance.quote.parent and instance.quote.parent.width} or nil,
        recipeReadAction=instance and instance.readChain and {text=instance.readChain.text,enabled=instance.readChain.enabled,
            visibility=instance.readChain.visibility,x=instance.readChain.x,y=instance.readChain.y,
            width=instance.readChain.width,height=instance.readChain.height,
            rowWidth=instance.readChain.parent and instance.readChain.parent.width} or nil }
end
function Controller:OpenManual()
    if not S.FeatureRuntime or S.FeatureRuntime:IsEnabled('tools_craft')~=true then return false,'请先开启配方制作。' end
    local previous=self.manualVisible
    self.manualVisible=true;self.dismissed=false;self.showAttempts=self.showAttempts+1
    local ok,why=Host:SetVisible(WIDGET_ID,true,{persist=false,source='craft_manual_open'})
    if ok~=true then
        self.manualVisible=previous;self.showFailures=self.showFailures+1;self.lastDecision='manual_show_failed'
        self.lastShowError=tostring(why or 'unknown'):sub(1,200);return false,why
    end
    self.lastDecision='manual_open';return true,'已打开配方小窗'
end
function Controller:ResetPosition()
    local instance=Host:GetInstance(WIDGET_ID)
    local ok,why
    if instance and instance.surface and type(instance.surface.ResetLayout)=='function' then
        ok,why=instance.surface:ResetLayout(true)
    elseif type(Feature.Commands.ResetCraftWindowState)=='function' then
        ok,why=Feature.Commands:ResetCraftWindowState()
    else return false,'配方小窗位置恢复不可用' end
    if ok~=true then return false,why end
    return self:OpenManual()
end

local function CopyState(target, source)
    if type(target) ~= "table" or type(source) ~= "table" then return false end
    for key in pairs(target) do target[key] = nil end
    for key, value in pairs(source) do target[key] = value end
    return true
end

local function MaterialRows(projection,instance)
    if type(projection.plan)=='table' then
        local plan,rows=projection.plan,{}
        local evaluation=plan.evaluation or {}
        if plan.targets and plan.recipes and evaluation.byKey then
            local roots={}
            for _,target in ipairs(plan.targets)do roots[target.key]=true end
            local function Walk(key,path,depth,visiting,previewItem,preview,targetId,branchNeed,sharedParent)
                if #rows>=512 or depth>24 then return end
                local row=not preview and evaluation.byKey[key] or nil
                if not row and not previewItem then return end
                local item=row and row.item or previewItem
                local isPreview=preview==true or row==nil
                local recipe=plan.recipes[(plan.choices or {})[key] or '']
                local catalog=(plan.recipeCatalog or {})[key]
                local unresolved=not recipe and catalog and catalog.status=='recipe_fields_unknown'
                local canExpand=type(recipe)=='table' and type(recipe.materials)=='table' and #recipe.materials>0
                local labor=recipe and tonumber(recipe.labor)
                local quote=(plan.prices or {})[key] or (row and row.priceMeta)
                local price=type(quote)=='table' and tonumber(quote.price) or row and tonumber(row.price)
                local priceText='—'
                if price and price==price and price>=0 and price<=1000000000 then
                    local source=type(quote)=='table' and tostring(quote.source or ''):gsub('^legacy:','') or ''
                    local stale=not quote or quote.freshness~='fresh' or quote.candidatePrice~=nil or source=='name_search_direct_unit'
                    priceText=(stale and '~' or '')..Money(price)
                end
                local query=(plan.quoteItems or {})[key]
                if query and query.status=='none' then priceText='无'
                elseif query and query.status=='failed' then priceText=QuoteFailure(query)
                elseif query and query.status=='querying' then priceText='查询中' end
                -- 购买分支仍可看配方，但预览数量不进入当前采购和库存抵扣。
                local parents=row and type(row.parents)=='table' and #row.parents or 0
                local shared=row and (parents>1 or (roots[key] and parents>0))
                local aggregate=shared or sharedParent
                local bagOnly=plan.inventoryScope=='bag'
                rows[#rows+1]={key=path,itemKey=key,targetId=targetId,isTarget=depth==0,item=item,preview=isPreview,canExpand=canExpand,
                    labor=labor and labor>=0 and (tostring(labor)..'/次') or '—',unitPrice=priceText,name=string.rep('  ',depth)..
                    (canExpand and (instance.expanded[path]==false and '[+] ' or '[-] ') or ((unresolved or row and row.recipeUnknown) and '? ' or ''))..
                    (item.name or ('物品 '..item.itemType))..(aggregate and '（库存合计）' or ''),
                    need=row and tostring(branchNeed or row.demand) or (branchNeed and ('预'..tostring(branchNeed)) or (tostring(item.count or '?')..'/次')),
                    held=row and (row.inventoryUncertain and '?' or (plan.inventoryComplete or bagOnly) and ((bagOnly and '包' or aggregate and '合' or '')..tostring(row.owned)) or '?') or '-',
                    shortage=row and (row.inventoryUncertain and '?' or plan.inventoryComplete and ((aggregate and '合' or '')..tostring(row.shortage))
                        or (bagOnly and row.shortage==0 and '0' or '?')) or '-',
                    tone=not row and 'muted' or row.inventoryUncertain and 'warn' or (bagOnly and row.shortage==0) and 'success'
                        or not plan.inventoryComplete and 'warn' or row.shortage==0 and 'success' or 'danger'}
                if visiting[key] or instance.expanded[path]==false or not recipe then return end
                visiting[key]=true
                for i,item in ipairs(recipe.materials or {})do
                    local child=tostring(item.itemType)..':'..tostring(item.grade==nil and '*' or item.grade)..':'..tostring(item.variant or '*')
                    local batches=row and tonumber(row.batches)
                    local childPreview=isPreview or (row and row.craft~=nil and (tonumber(row.craft) or 0)<=0)
                        or (row and row.craft and row.craft>0 and batches~=nil and batches<=0)
                    local childNeed
                    if not childPreview and not aggregate and batches and batches>0 and tonumber(item.count) then
                        childNeed=batches*item.count
                    elseif childPreview then
                        -- 购买分支仅展示假设制作的用量，不进入实际采购或成本；数量跟随目标并标为预览。
                        local parentNeed=tonumber(branchNeed or (row and row.demand))
                        local output=recipe.product and tonumber(recipe.product.count)
                        local amount=tonumber(item.count)
                        if parentNeed and output and output>0 and amount and amount>0 then
                            local previewNeed=math.ceil(parentNeed/output)*amount
                            if previewNeed<=1000000000 then childNeed=previewNeed end
                        end
                    end
                    Walk(child,path..':'..i,depth+1,visiting,item,childPreview,targetId,childNeed,aggregate)
                end
                visiting[key]=nil
            end
            for _,target in ipairs(plan.targets)do Walk(target.key,'target:'..target.id,0,{},nil,false,target.id)end
            return rows
        end
        for _,row in ipairs(plan.evaluation and plan.evaluation.rows or {})do
            rows[#rows+1]={key='craft-plan:'..row.key,name=row.item.name or ('物品 '..row.item.itemType),
                need=tostring(row.demand),held=plan.inventoryComplete and tostring(row.owned) or '?',
                shortage=plan.inventoryComplete and tostring(row.shortage) or '?'}
        end
        return rows
    end
    return {}
end

local function CreateSidecar()
    local state = {
        width = WIDTH, height = HEIGHT, minimized = false, locked = false,
        overallOpacity = 0.96, backgroundOpacity = 1.0, textOpacity = 1.0, fontScale = 1.0,
        userMoved = false,
    }
    if type(Feature.GetCraftWindowState)=='function' then
        for key,value in pairs(Feature:GetCraftWindowState() or {})do state[key]=value end
    end
    local instance = { visible = false, acquired = false, subscribed = false, state = state,expanded={},searchText='' }
    local surface, surfaceErr = Floating:Create({
        id = "v3_craft_sidecar", owner = OWNER, title = "配方制作", status = "当前制作计划",
        width = WIDTH, height = HEIGHT, minWidth = WIDTH, minHeight = HEIGHT, maxWidth = MAX_WIDTH, maxHeight = MAX_HEIGHT,
        resizable = true, movable = true, footer = true, closeButton = true, appearanceControls = false,
        -- 窗口与内部固定按钮使用同一 logical 单位，避免缩放时按钮排出窗外。
        scaleWithAddon = false, minimizeMode = "compact", boundaryMode = "strict",
        statePolicy = { defaultWidth = WIDTH, defaultHeight = HEIGHT, minWidth = WIDTH, minHeight = HEIGHT, maxWidth = MAX_WIDTH, maxHeight = MAX_HEIGHT,
            defaultLocked = false, defaultOverallOpacity = 0.96, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 },
        getState = function() return instance.state end,
        setState = function(value)
            if type(value) ~= "table" then return false, "sidecar state invalid" end
            CopyState(instance.state, value); return true
        end,
        persist = function()
            if type(Feature.Commands.SetCraftWindowState)~='function' then return false,'配方小窗位置保存不可用' end
            local split=instance.bodySplit
            local primary=split and split.height and select(1,split:ResolvePrimary(split.height)) or nil
            return Feature.Commands:SetCraftWindowState(instance.state,primary)
        end,
        onClosed = function(_, reason)
            Controller.manualVisible = false
            Controller.dismissed = true
            return Host:NotifyWindowClosed(WIDGET_ID, { persist = false, source = tostring(reason or "craft_sidecar_close") })
        end,
    })
    if surface == nil then return nil, surfaceErr or "配方制作侧窗创建失败" end
    instance.surface, instance.shell, instance.windowController = surface, surface.shell, surface.windowController
    local bodySplit,controlArea,bottomArea
    local function Relayout()
        if bodySplit and bottomArea then
            local _,height=bottomArea:Measure(bodySplit.width or WIDTH,nil)
            bodySplit.minSecondary=math.max(80,tonumber(height) or 80)
        end
        return instance.shell:Layout()
    end

    local content = surface:GetContentRoot()
    local root = RSUI:VerticalBox({ id = "v3_craft_sidecar_content", parent = content, gap = 2,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    controlArea=RSUI:VerticalBox({id='v3_craft_sidecar_controls',parent=root,gap=2,slot={size='auto',hAlign='fill'}})
    local committedSplit=type(Feature.GetCraftListSplit)=='function' and Feature:GetCraftListSplit()
        or (170+math.max(0,(tonumber(state.height) or HEIGHT)-HEIGHT)*0.6)
    bodySplit=RSUI:SplitView({id='v3_craft_sidecar_split',parent=root,orientation='vertical',mode='fixed',primarySize=committedSplit,
        minPrimary=80,minSecondary=110,dividerSize=10,slot={size='fill',fill=1,hAlign='fill',vAlign='fill'},
        onSplitChanged=function(split,_,_,final)
            if final~=true then return end
            local size=select(1,split:ResolvePrimary(split.height or 0))
            if type(Feature.Commands.SetCraftListSplit)=='function' then
                local saved,err=Feature.Commands:SetCraftListSplit(size)
                if saved~=true then
                    split:SetPrimarySize(committedSplit,false)
                    if instance.status then instance.status:SetText('分隔线保存失败：'..tostring(err or '未知原因')) end
                    return false,err or 'split_save_failed'
                end
            end
            committedSplit=size;return true
        end})
    local listArea=RSUI:VerticalBox({id='v3_craft_sidecar_list_area',parent=bodySplit,gap=2,slot={size='fill',fill=1}})
    bottomArea=RSUI:VerticalBox({id='v3_craft_sidecar_selection_area',parent=bodySplit,gap=2,slot={size='fill',fill=1}})
    local layoutSplit=bodySplit.Layout
    function bodySplit:Layout(x,y,width,height)
        -- 外窗增长的高度交给材料表；不能让固定分隔位置把新增空间全留成底部空白。
        if instance.visible and not self.dragging and tonumber(height) and tonumber(self.height) and height~=self.height then
            self.primarySize=math.max(0,self:ResolvePrimary(self.height)+height-self.height)
        end
        return layoutSplit(self,x,y,width,height)
    end
    instance.bodySplit=bodySplit
    local function PlanError(value)
        local reason=tostring(value or '原因未知')
        if reason:find('integrity_failed',1,true) or reason:find('fingerprint_mismatch',1,true) or reason:find('write_fenced',1,true) then
            return '制作计划存档损坏，已保护原数据；请打开诊断'
        end
        return reason
    end
    local function Action(command,...)
        local fn=Feature.Commands[command]
        if type(fn)~='function' then return false,'配方管理命令不可用' end
        local ok,why=fn(Feature.Commands,...)
        instance:Refresh()
        instance.status:SetText(ok and tostring(why or '已更新') or ('未完成：'..PlanError(why)))
        if instance.status.SetTone then instance.status:SetTone(ok and 'muted' or 'warn') end
        return ok,why
    end
    local function OutputCount()
        local value=instance.outputCount and tostring(instance.outputCount:GetDraftValue() or '') or ''
        if value=='' then return nil,true end
        local count=value:match('^%s*%d+%s*$') and tonumber(value) or nil
        return count,count~=nil and count>=1 and count<=1000000000
    end
    local searchRow=RSUI:HorizontalBox({id='v3_craft_sidecar_search_row',parent=controlArea,gap=4,slot={size='fixed',height=29,hAlign='fill'}})
    instance.search=RSUI:TextInput({id='v3_craft_sidecar_search',parent=searchRow,value='',placeholder='筛选本地配方和物品',maxLength=96,submitOnLostFocus=false,
        slot={size='fill',fill=1,minWidth=100}})
    RSUI:Button({id='v3_craft_sidecar_filter',parent=searchRow,text='筛选',compact=true,slot={size='fixed',width=48},onClick=function()
        instance.addRecipeId=nil;instance.searchText=tostring(instance.search:GetDraftValue() or '');return instance:Refresh()
    end})
    RSUI:Button({id='v3_craft_sidecar_clear_filter',parent=searchRow,text='全部',compact=true,slot={size='fixed',width=48},onClick=function()
        instance.addRecipeId=nil;instance.searchText='';instance.search:SetValue('',false);return instance:Refresh()
    end})
    searchRow:SetVisibility('collapsed')
    local recipeRow = RSUI:HorizontalBox({ id = "v3_craft_sidecar_recipe_row", parent = controlArea, gap = 4,
        slot = { size = "fixed", height = 31, hAlign = "fill" } })
    instance.recipe = RSUI:Dropdown({ id = "v3_craft_sidecar_recipe", parent = recipeRow, items = {}, maxVisible = 12, popupWidth = 300,
        get = function()
            local projection=Feature:GetProjection() or {}
            if projection.plan then
                return projection.plan.libraryActiveId or instance.savedRecipeId
            end
            return nil
        end,
        set = function(value)
            if (Feature:GetProjection() or {}).plan then
                if type(Feature.Commands.RecipeOpen)=='function' then return Action('RecipeOpen',value) end
                instance.savedRecipeId=value;return true
            end
            instance.status:SetText('制作计划未就绪，无法选择配方');return false,'制作计划未就绪'
        end,
        placeholder = "选择已接收配方", slot = { size = "fill", fill = 1, minWidth = 100 } })
    instance.addSaved=RSUI:Button({id='v3_craft_sidecar_add_saved',parent=recipeRow,text='打开',compact=true,
        slot={size='fixed',width=44},onClick=function()
            local selected=(Feature:GetProjection().plan or {}).libraryActiveId or instance.savedRecipeId
            if type(Feature.Commands.RecipeOpen)=='function' then return Action('RecipeOpen',selected) end
            if not instance.savedRecipeId or not Feature.Commands.PlanAddSavedRecipe then return false,'请先选择已收录配方。' end
            local ok,why=Feature.Commands:PlanAddSavedRecipe(instance.savedRecipeId,1)
            instance.status:SetText(ok and '已加入当前计划' or tostring(why));if ok then instance:Refresh() end;return ok,why
        end})
    instance.addSaved:SetVisibility('collapsed') -- 下拉选择即打开，无需再点一次打开。
    instance.refresh = RSUI:Button({ id = "v3_craft_sidecar_refresh", parent = recipeRow, text = "核对", compact = true, slot = { size = "fixed", width = 52 } })
    -- 读取子配方是主流程入口，紧凑布局也必须保留；与数量/价格行分开放，避免窄窗挤出按钮。
    instance.readChain=RSUI:Button({id='v3_craft_sidecar_read_chain',parent=recipeRow,text='获取子配方',compact=true,
        enabled=false,slot={size='fixed',width=88},onClick=function()return Action('PlanReadRecipes')end})

    local editRow=RSUI:HorizontalBox({id='v3_craft_sidecar_edit_row',parent=controlArea,gap=4,slot={size='fixed',height=29,hAlign='fill'}})
    instance.nameInput=RSUI:TextInput({id='v3_craft_sidecar_name',parent=editRow,value='',placeholder='配方名称',maxLength=96,submitOnLostFocus=false,
        slot={size='fill',fill=1,minWidth=120}})
    RSUI:Button({id='v3_craft_sidecar_rename',parent=editRow,text='改名',compact=true,slot={size='fixed',width=48},onClick=function()
        return Action('PlanRename',instance.nameInput:GetDraftValue())
    end})
    instance.deleteButton=RSUI:Button({id='v3_craft_sidecar_delete',parent=editRow,text='删除',compact=true,slot={size='fixed',width=52},onClick=function()
        local p=(Feature:GetProjection().plan or {})
        local id=p.libraryActiveId or p.activeId
        if not id then instance.status:SetText('请先选择一份配方');return false end
        if instance.deleteArmed~=id then instance.deleteArmed=id;instance.deleteButton:SetText('确认删');return true end
        instance.deleteArmed=nil
        if p.libraryActiveId then return Action('RecipeDelete',id) end
        return Action('PlanDelete')
    end})
    RSUI:Button({id='v3_craft_sidecar_bank',parent=editRow,text='核对银行',compact=true,slot={size='fixed',width=72},
        onClick=function()return Action('PlanRefreshInventory',true)end})
    editRow:SetVisibility('collapsed')
    local quantityRow=RSUI:HorizontalBox({id='v3_craft_sidecar_quantity_row',parent=controlArea,gap=4,slot={size='fixed',height=31,hAlign='fill'}})
    local function ActiveTarget()
        local p=Feature:GetProjection().plan or {}
        for _,target in ipairs(p.targets or {})do if target.id==instance.activeTargetId then return target end end
        return p.targets and p.targets[1] or nil
    end
    instance.quantity=RSUI:NumericField({id='v3_craft_sidecar_quantity',parent=quantityRow,label='制作件数',inline=true,slider=false,integer=true,
        min=1,max=1000000000,hardMin=1,hardMax=1000000000,applyButton=true,commitOnLostFocus=true,labelWidth=52,inputWidth=62,
        get=function()local target=ActiveTarget();return target and target.count or 1 end,
        set=function(value)
            local target=ActiveTarget()
            if not target then return false,'先选择配方' end
            return Action('PlanSetQuantity',target.id,value)
        end,slot={size='fill',fill=1,minWidth=170}})
    instance.quote = RSUI:Button({ id = "v3_craft_sidecar_quote", parent = quantityRow, text = "获取全部价格", compact = true,
        enabled = false, slot = { size = "fixed", width = 108 } })

    local planRow = RSUI:HorizontalBox({ id = "v3_craft_sidecar_plan_row", parent = controlArea, gap = 4,
        slot = { size = "fixed", height = 29, hAlign = "fill" } })
    local addPlan = RSUI:Button({ id = "v3_craft_sidecar_add_plan", parent = recipeRow, text = "接收配方", compact = true,
        slot = { size = "fixed", width = 64 } })
    RSUI:Button({id='v3_craft_sidecar_settings',parent=quantityRow,text='高级',compact=true,slot={size='fixed',width=44},onClick=function()
        local shell=S.UIV3 and S.UIV3.shell
        if shell and type(shell.Navigate)=='function' then return shell:Navigate('tools.craft_assist',{source='craft_sidecar'}) end
        return false,'高级设置页面暂不可用'
    end})
    planRow:SetVisibility('collapsed')
    local managementOpen=false
    local laborRow,planManagerRow,shareRow
    local management=RSUI:Button({id='v3_craft_sidecar_manage',parent=planRow,text='管理',compact=true,
        slot={size='fixed',width=76},onClick=function()
            return instance:SetManagementMode(not managementOpen)
        end})
    local targetRow,comparisonArea
    RSUI:Button({id='v3_craft_sidecar_add_target',parent=planRow,text='加入目标',compact=true,slot={size='fixed',width=72},onClick=function()
        if managementOpen then instance:SetManagementMode(false) end
        instance:SetComparisonMode(false);searchRow:SetVisibility('visible');targetRow:SetVisibility('visible');Relayout();return true
    end})
    RSUI:Button({id='v3_craft_sidecar_compare',parent=planRow,text='比较',compact=true,slot={size='fixed',width=48},onClick=function()
        if managementOpen then instance:SetManagementMode(false) end
        local command=Feature.Commands.PlanCompare
        if type(command)~='function' then return false,'比较不可用' end
        local ok,result=command(Feature.Commands)
        if not ok then instance.status:SetText(tostring(result or '比较失败'));return false,result end
        instance.comparison=result
        local function Cost(value)
            if not value or not value.costComplete then return '待核' end
            return Money(value.cashCopper)..(value.priceStale and '（旧价）' or '')
        end
        local r=result.result or {};local raw,buy=r.raw or {},r.buy or {}
        local difference=''
        if raw.costComplete and buy.costComplete then
            local delta=(tonumber(buy.cashCopper) or 0)-(tonumber(raw.cashCopper) or 0)
            local money=Money(math.abs(delta))
            difference=' · 自制'..(delta>=0 and '省 ' or '贵 ')..money
        end
        local rec=r.recommendation or {}
        local combined=''
        if raw.combinedCopper~=nil and buy.combinedCopper~=nil then
            combined='\n含劳力：原料 '..Money(raw.combinedCopper)..' / 成品 '..Money(buy.combinedCopper)
        end
        instance.compareText:SetText('原料 '..Cost(raw)..' / 劳力 '..(raw.laborComplete and tostring(raw.labor or 0) or '待核')..
            ' · 成品 '..Cost(buy)..difference..combined..'\n有限比较建议 '..(rec.available and Cost(rec.evaluation) or '待核')..
            (rec.partial and '（部分方案待核）' or '')..
            (rec.evaluation and not rec.evaluation.laborComplete and '（劳力待核）' or ''))
        targetRow:SetVisibility('collapsed');searchRow:SetVisibility('collapsed');instance:SetComparisonMode(true);return true
    end})
    if addPlan ~= nil then addPlan.onClick = function()
        if type(Feature.Commands.PlanReceiveShare) ~= "function" then return false, "配方接收命令不可用" end
        local fn=Feature.Commands.RecipeReceive or Feature.Commands.PlanReceiveShare
        local output,valid=OutputCount()
        if not valid then instance.status:SetText('每次产出须为正整数');return false end
        local ok, err = fn(Feature.Commands,1,output,'widget:craft_sidecar')
        if ok and instance.outputCount then instance.outputCount:SetValue('',false) end
        instance.status:SetText(ok and tostring(err or '等待下一条配方分享') or ("未接收：" .. PlanError(err)))
        if type(instance.status.SetTone) == "function" then instance.status:SetTone(ok and "muted" or "warn") end
        return ok, err
    end end

    local resetRow=RSUI:HorizontalBox({id='v3_craft_sidecar_reset_row',parent=controlArea,gap=4,slot={size='fixed',height=29,hAlign='fill'}})
    RSUI:Button({id='v3_craft_sidecar_reset_corrupt',parent=resetRow,text='清空损坏计划并重建',compact=true,
        slot={size='fixed',width=176},onClick=function()return Action('PlanResetCorrupt')end})
    resetRow:SetVisibility('collapsed')

    planManagerRow=RSUI:HorizontalBox({id='v3_craft_sidecar_plan_manager',parent=controlArea,gap=4,slot={size='fixed',height=27,hAlign='fill'}})
    instance.planSelector=RSUI:Dropdown({id='v3_craft_sidecar_plan_select',parent=planManagerRow,items={},placeholder='切换计划',
        get=function()return ((Feature:GetProjection() or {}).plan or {}).activeId end,
        set=function(value)return Action('PlanSelect',value)end,slot={size='fill',fill=1,minWidth=110}})
    instance.outputCount=RSUI:TextInput({id='v3_craft_sidecar_output_count',parent=planManagerRow,value='',placeholder='产出/次',maxLength=10,
        submitOnLostFocus=false,slot={size='fixed',width=70}})
    RSUI:Button({id='v3_craft_sidecar_new_plan',parent=planManagerRow,text='新计划',compact=true,slot={size='fixed',width=65},
        onClick=function()return Action('PlanNew','新计划')end})
    RSUI:Button({id='v3_craft_sidecar_copy_plan',parent=planManagerRow,text='复制',compact=true,slot={size='fixed',width=52},
        onClick=function()return Action('PlanCopy','计划副本')end})
    planManagerRow:SetVisibility('collapsed')
    shareRow=RSUI:HorizontalBox({id='v3_craft_sidecar_share_row',parent=controlArea,gap=4,slot={size='fixed',height=27,hAlign='fill'}})
    instance.shareInput=RSUI:TextInput({id='v3_craft_sidecar_share_input',parent=shareRow,value='',placeholder='粘贴配方分享链接',maxLength=2048,
        submitOnLostFocus=false,slot={size='fill',fill=1,minWidth=120}})
    RSUI:Button({id='v3_craft_sidecar_import_link',parent=shareRow,text='导入',compact=true,slot={size='fixed',width=52},onClick=function()
        local output,valid=OutputCount()
        if not valid then instance.status:SetText('每次产出须为正整数');return false end
        local command=type(Feature.Commands.RecipeImportLink)=='function' and 'RecipeImportLink' or 'PlanImportLink'
        local ok,why=Action(command,instance.shareInput:GetDraftValue(),1,output)
        if ok then instance.shareInput:SetValue('',false);instance.outputCount:SetValue('',false) end
        return ok,why
    end})
    shareRow:SetVisibility('collapsed')
    laborRow=RSUI:HorizontalBox({id='v3_craft_sidecar_labor_row',parent=bottomArea,gap=4,slot={size='fixed',height=27,hAlign='fill'}})
    RSUI:Text({id='v3_craft_sidecar_labor_label',parent=laborRow,text='劳力/次',fontSize=9,slot={size='fixed',width=48}})
    instance.manualLabor=RSUI:TextInput({id='v3_craft_sidecar_manual_labor',parent=laborRow,value='',placeholder='待核',maxLength=10,
        submitOnLostFocus=false,slot={size='fill',fill=1,minWidth=50}})
    RSUI:Text({id='v3_craft_sidecar_fee_label',parent=laborRow,text='费/次铜',fontSize=9,slot={size='fixed',width=48}})
    instance.manualFee=RSUI:TextInput({id='v3_craft_sidecar_manual_fee',parent=laborRow,value='',placeholder='待核',maxLength=10,
        submitOnLostFocus=false,slot={size='fill',fill=1,minWidth=50}})
    instance.currentLabor=RSUI:TextInput({id='v3_craft_sidecar_current_labor',parent=laborRow,value='',placeholder='当前劳力',maxLength=10,
        submitOnLostFocus=false,slot={size='fill',fill=1,minWidth=50}})
    instance.currentLabor:SetVisibility('collapsed')
    RSUI:Button({id='v3_craft_sidecar_save_labor',parent=laborRow,text='保存',compact=true,slot={size='fixed',width=48},onClick=function()
        local function Number(input)
            local value=tostring(input:GetDraftValue() or '')
            if value=='' then return nil,true end
            if not value:match('^%s*%d+%s*$') then return nil,false end
            local n=tonumber(value);return n,n~=nil and n<=1000000000
        end
        local labor,validLabor=Number(instance.manualLabor)
        local fee,validFee=Number(instance.manualFee)
        local current,validCurrent=Number(instance.currentLabor)
        if not validLabor or not validFee or not validCurrent then
            instance.status:SetText('请填写非负整数，未知项留空');return false
        end
        if labor~=nil or fee~=nil then
            local row=instance.selectedMaterial
            if not row then instance.status:SetText('先选择要校准的制作配方');return false end
            local ok,why=Action('PlanSetRecipeCosts',row.itemKey,labor,fee)
            if not ok then return false,why end
        elseif current==nil then instance.status:SetText('先选配方并填写劳力或手续费');return false
        end
        instance.availableLabor=current
        instance:Refresh();instance.status:SetText('已保存所选配方消耗；空白项保留原值或待核');return true
    end})
    local candidateRow=RSUI:HorizontalBox({id='v3_craft_sidecar_candidate_row',parent=controlArea,gap=4,slot={size='fixed',height=27,hAlign='fill'}})
    instance.materialRecipe=RSUI:Dropdown({id='v3_craft_sidecar_material_recipe',parent=candidateRow,items={},placeholder='选中材料的候选配方',
        get=function()
            local row=instance.selectedMaterial;local p=(Feature:GetProjection() or {}).plan or {}
            return row and (p.choices or {})[row.itemKey] or nil
        end,
        set=function(id)
            local row=instance.selectedMaterial
            if not row then return false,'请先选择材料' end
            local ok,why=Action('PlanChooseRecipe',row.itemKey,id)
            if ok and type(Feature.Commands.PlanReadRecipes)=='function' then
                local started=Feature.Commands:PlanReadRecipes()
                if not started then instance.status:SetText('配方已选择；可点获取子配方重读') end
            end
            return ok,why
        end,slot={size='fill',fill=1,minWidth=130}})
    RSUI:Button({id='v3_craft_sidecar_cancel_work',parent=candidateRow,text='停止查询',compact=true,
        slot={size='fixed',width=72},onClick=function()return Action('PlanCancel')end})
    candidateRow:SetVisibility('collapsed')
    targetRow=RSUI:HorizontalBox({id='v3_craft_sidecar_target_row',parent=controlArea,gap=4,slot={size='fixed',height=29,hAlign='fill'}})
    instance.addRecipe=RSUI:Dropdown({id='v3_craft_sidecar_target_recipe',parent=targetRow,items={},placeholder='选择已保存配方',
        get=function()return instance.addRecipeId end,set=function(value)instance.addRecipeId=value;return true end,
        slot={size='fill',fill=1,minWidth=120}})
    RSUI:Button({id='v3_craft_sidecar_confirm_target',parent=targetRow,text='加入',compact=true,slot={size='fixed',width=52},onClick=function()
        if not instance.addRecipeId then instance.status:SetText('请选择要加入的配方');return false end
        local itemKey=instance.addRecipeId:match('^item:(.+)$')
        local ok,why
        if itemKey then ok,why=Action('PlanAppendCatalogItem',itemKey,1)
        else ok,why=Action('PlanAppendSavedRecipe',instance.addRecipeId,1) end
        if ok then
            targetRow:SetVisibility('collapsed')
            if not managementOpen then searchRow:SetVisibility('collapsed') end
            Relayout()
        end
        return ok,why
    end})
    RSUI:Button({id='v3_craft_sidecar_remove_target',parent=targetRow,text='移除目标',compact=true,slot={size='fixed',width=76},onClick=function()
        local row=instance.selectedMaterial
        if not row or not row.isTarget then instance.status:SetText('先选择目标行');return false end
        return Action('PlanRemoveTarget',row.targetId)
    end})
    targetRow:SetVisibility('collapsed')
    comparisonArea=RSUI:VerticalBox({id='v3_craft_sidecar_comparison_area',parent=listArea,gap=2,slot={size='fixed',height=110,hAlign='fill'}})
    instance.compareText=RSUI:Text({id='v3_craft_sidecar_compare_text',parent=comparisonArea,text='',fontSize=8,tone='muted',
        overflow='wrap',maxLines=4,slot={size='fixed',height=79,hAlign='fill'}})
    local compareActions=RSUI:HorizontalBox({id='v3_craft_sidecar_compare_actions',parent=comparisonArea,gap=4,slot={size='fixed',height=27,hAlign='fill'}})
    RSUI:Button({id='v3_craft_sidecar_apply_all',parent=compareActions,text='采纳建议',compact=true,slot={size='fixed',width=76},onClick=function()
        local c=instance.comparison
        if not c or not c.result or not c.result.recommendation or not c.result.recommendation.available then
            instance.status:SetText('缺少有效成本，无法采纳建议');return false
        end
        local ok,why=Action('PlanApplyRecommendation',c.revision)
        if ok then instance.comparison=nil;instance:SetComparisonMode(false) end
        return ok,why
    end})
    RSUI:Button({id='v3_craft_sidecar_apply_one',parent=compareActions,text='采纳此项',compact=true,slot={size='fixed',width=76},onClick=function()
        local c,row=instance.comparison,instance.selectedMaterial
        if not c or not row or not c.result or not c.result.recommendation or not c.result.recommendation.available then
            instance.status:SetText('请先选择材料并确认有效建议');return false
        end
        local ok,why=Action('PlanApplyRecommendation',c.revision,row.itemKey)
        if ok then instance.comparison=nil;instance:SetComparisonMode(false) end
        return ok,why
    end})
    RSUI:Button({id='v3_craft_sidecar_close_compare',parent=compareActions,text='关闭',compact=true,slot={size='fixed',width=52},onClick=function()
        instance:SetComparisonMode(false);return true
    end})
    comparisonArea:SetVisibility('collapsed')

    local treeActions=RSUI:HorizontalBox({id='v3_craft_sidecar_tree_actions',parent=controlArea,gap=4,slot={size='fixed',height=27,hAlign='fill'}})
    RSUI:Button({id='v3_craft_sidecar_expand',parent=treeActions,text='展开/收起',compact=true,slot={size='fixed',width=84},onClick=function()
        return instance:ToggleBranch(instance.selectedMaterial,true)
    end})
    RSUI:Button({id='v3_craft_sidecar_receive_material',parent=treeActions,text='补子配方',compact=true,slot={size='fixed',width=80},onClick=function()
        local row=instance.selectedMaterial;if not row then instance.status:SetText('先选待补的材料');return false end
        local output,valid=OutputCount()
        if not valid then instance.status:SetText('每次产出须为正整数');return false end
        local ok,why=Action('RecipeReceiveMaterial',row.itemKey,'widget:craft_sidecar',output)
        if ok and instance.outputCount then instance.outputCount:SetValue('',false) end
        return ok,why
    end})
    RSUI:Button({id='v3_craft_sidecar_mark_base',parent=treeActions,text='确认为原料',compact=true,slot={size='fixed',width=88},onClick=function()
        local row=instance.selectedMaterial;if not row then instance.status:SetText('先选材料行');return false end
        return Action('PlanMarkBase',row.itemKey)
    end})

    local materialActions=RSUI:HorizontalBox({id='v3_craft_sidecar_material_actions',parent=bottomArea,gap=4,slot={size='fixed',height=27,hAlign='fill'}})
    local function SelectedAction(command,mode)
        local row=instance.selectedMaterial
        if not row or not row.itemKey then instance.status:SetText('先选择材料');return false end
        if mode and row.preview then instance.status:SetText('下级为配方预览，先将上级设为制作');return false end
        if mode then return Action(command,row.itemKey,mode,0,0) end
        return Action(command,row.itemKey)
    end
    RSUI:Button({id='v3_craft_sidecar_buy',parent=materialActions,text='购买',compact=true,slot={size='fixed',width=46},onClick=function()return SelectedAction('PlanSetAllocation','buy')end})
    RSUI:Button({id='v3_craft_sidecar_craft',parent=materialActions,text='制作',compact=true,slot={size='fixed',width=46},onClick=function()return SelectedAction('PlanSetAllocation','craft')end})
    local mixedRow
    RSUI:Button({id='v3_craft_sidecar_mixed',parent=materialActions,text='混合',compact=true,slot={size='fixed',width=46},onClick=function()
        local row=instance.selectedMaterial
        if not row or row.preview then instance.status:SetText('先选择当前需要的材料');return false end
        local p=(Feature:GetProjection() or {}).plan or {}
        local detail=p.evaluation and p.evaluation.byKey and p.evaluation.byKey[row.itemKey]
        if not p.inventoryComplete or not detail or detail.inventoryUncertain then instance.status:SetText('请先核对库存与品质，再分配缺口');return false end
        local allocation=(p.allocations or {})[row.itemKey]
        instance.mixedKey=row.itemKey
        instance.mixedBuy:SetValue(tostring(allocation and allocation.mode=='mixed' and allocation.buy or detail.shortage or 0),false)
        instance.mixedCraft:SetValue(tostring(allocation and allocation.mode=='mixed' and allocation.craft or 0),false)
        mixedRow:SetVisibility('visible');Relayout();return true
    end})
    RSUI:Button({id='v3_craft_sidecar_search_auction',parent=materialActions,text='搜索拍卖',compact=true,slot={size='fixed',width=72},onClick=function()return SelectedAction('PlanSearch')end})
    RSUI:Button({id='v3_craft_sidecar_quote_one',parent=materialActions,text='校准此项',compact=true,slot={size='fixed',width=72},onClick=function()return SelectedAction('PlanCalibrate')end})
    mixedRow=RSUI:HorizontalBox({id='v3_craft_sidecar_mixed_row',parent=bottomArea,gap=4,slot={size='fixed',height=27,hAlign='fill'}})
    instance.mixedBuy=RSUI:TextInput({id='v3_craft_sidecar_mixed_buy',parent=mixedRow,value='0',placeholder='购买数量',maxLength=10,
        submitOnLostFocus=false,slot={size='fill',fill=1,minWidth=60}})
    instance.mixedCraft=RSUI:TextInput({id='v3_craft_sidecar_mixed_craft',parent=mixedRow,value='0',placeholder='制作数量',maxLength=10,
        submitOnLostFocus=false,slot={size='fill',fill=1,minWidth=60}})
    RSUI:Button({id='v3_craft_sidecar_apply_mixed',parent=mixedRow,text='保存混合',compact=true,slot={size='fixed',width=76},onClick=function()
        local row=instance.selectedMaterial
        if not row or row.itemKey~=instance.mixedKey then instance.status:SetText('材料已切换，请重新分配');return false end
        local buyText=tostring(instance.mixedBuy:GetDraftValue() or '')
        local craftText=tostring(instance.mixedCraft:GetDraftValue() or '')
        local buy=buyText:match('^%s*%d+%s*$') and tonumber(buyText) or nil
        local craft=craftText:match('^%s*%d+%s*$') and tonumber(craftText) or nil
        local p=(Feature:GetProjection() or {}).plan or {}
        local detail=p.evaluation and p.evaluation.byKey and p.evaluation.byKey[row.itemKey]
        if not buy or not craft or buy>1000000000 or craft>1000000000 or not p.inventoryComplete or not detail or detail.inventoryUncertain
            or buy+craft~=detail.shortage then
            instance.status:SetText('购买与制作数量须为整数，合计等于当前缺口');return false
        end
        local ok,why=Action('PlanSetAllocation',row.itemKey,'mixed',buy,craft)
        if ok then mixedRow:SetVisibility('collapsed');instance.mixedKey=nil;Relayout() end
        return ok,why
    end})
    mixedRow:SetVisibility('collapsed')

    -- WindowShell footer 占用 v3_craft_sidecar_status，业务反馈须用独立 ID，否则首次构建会被隔离。
    instance.status = RSUI:Text({ id = "v3_craft_sidecar_action_status", parent = bottomArea,
        text = "点击带 [+] / [-] 的材料可展开或收起；拖动分隔线调整列表。", fontSize = 8, tone = "muted", overflow = "wrap", maxLines = 2,
        slot = { size = "fixed", height = 30, hAlign = "fill" } })

    local function ShowSelection(row,resetDraft)
        if not row then return end
        local p=(Feature:GetProjection() or {}).plan or {}
        local detail=p.evaluation and p.evaluation.byKey and p.evaluation.byKey[row.itemKey]
        local quote=(p.prices or {})[row.itemKey] or (detail and detail.priceMeta) or {}
        local price=quote.price or (detail and detail.price)
        local priceText=price and ('参考 '..Money(price)) or '待报价'
        if price then
            if quote.candidatePrice then priceText=priceText..'（新价待核）'
            elseif tostring(quote.source or ''):gsub('^legacy:','')=='name_search_direct_unit' then priceText=priceText..'（排序待核）'
            elseif quote.freshness~='fresh' then priceText=priceText..'（旧参考）' end
            if quote.ageMinutes then priceText=priceText..' · '..tostring(quote.ageMinutes)..'分钟前' end
        end
        local query=(p.quoteItems or {})[row.itemKey]
        if query and query.status=='none' then priceText='本次查询无记录'
        elseif query and query.status=='failed' then
            priceText=QuoteFailure(query)..'：'..tostring(query.reason or query.code or '原因待核')..'；未更新参考价'
            if query.quoteGrade~=nil then priceText=priceText..'（查询品质 '..tostring(query.quoteGrade)..'）' end
        elseif query and query.status=='querying' then priceText='正在查询价格' end
        local reason=''
        for _,issue in ipairs(p.scanResult and p.scanResult.issues or {})do if issue.key==row.itemKey then reason='；'..issue.reason;break end end
        local entry=(p.recipeCatalog or {})[row.itemKey]
        if reason=='' and entry and entry.status=='recipe_fields_unknown' then reason='；下级配方待核，可点获取子配方重读' end
        local recipe=(p.recipes or {})[(p.choices or {})[row.itemKey] or '']
        if recipe and recipe.product and row.item and row.item.grade~=nil and recipe.product.grade==nil then
            local domain=S.CraftPlanDomain
            local certain=domain and select(2,domain.ProductMatches(row.item,recipe.product))
            if certain~=true then reason=reason..'；产物品质待核，下级仅供预览' end
        end
        if detail and detail.inventoryUncertain then reason=reason..'；库存品质或归属待核' end
        local source=detail and (' · 买'..tostring(detail.buy or 0)..'/做'..tostring(detail.craft or 0)) or ''
        instance.status:SetText((row.item and row.item.name or row.name)..' · '..(row.preview and '配方预览' or ('需求 '..row.need))..source..' · '..priceText..reason)
        instance.materialRecipe.items={}
        for _,id in ipairs(((p.recipeCatalog or {})[row.itemKey] or {}).recipeIds or {})do
            local recipe=(p.recipes or {})[id]
            instance.materialRecipe.items[#instance.materialRecipe.items+1]={value=id,text='配方 '..id..' · 产出 '..tostring(recipe and recipe.product and recipe.product.count or '?')}
        end
        instance.materialRecipe:Render()
        if resetDraft then
            local recipe=p.recipes and p.recipes[(p.choices or {})[row.itemKey] or '']
            instance.manualLabor:SetValue(recipe and recipe.labor~=nil and tostring(recipe.labor) or '',false)
            instance.manualFee:SetValue(recipe and recipe.feeCopper~=nil and tostring(recipe.feeCopper) or '',false)
        end
    end
    function instance:ToggleBranch(row,explain)
        if not row then if explain then self.status:SetText('先选材料行') end;return false end
        if not row.canExpand then
            if explain then self.status:SetText('该材料暂无可展开配方，请先点击获取子配方') end
            return false
        end
        local key=row.key
        self.expanded[key]=self.expanded[key]==false;self:Refresh()
        self.status:SetText(self.expanded[key] and '已展开下级材料' or '已收起下级材料')
        return true
    end
    instance.table = RSUI:TableView({
        id = "v3_craft_sidecar_table", parent = listArea, items = {}, rowHeight = 27, headerHeight = 26,
        desiredRows = 10, overscan = 1, scrollbar = true, selectable = true, columnResize = true, headerInteractive = false,
        onSelectionChanged=function(index,_,view)
            instance.selectedMaterial=index and view:GetItem(index) or nil
            local row=instance.selectedMaterial
            if row and row.targetId and row.targetId~=instance.activeTargetId then
                instance.activeTargetId=row.targetId
                if instance.quantity.input and instance.quantity.input.CancelEditing then instance.quantity.input:CancelEditing('target_changed') end
                instance.quantity:Render()
            end
            if instance.mixedKey and (not row or row.itemKey~=instance.mixedKey) then
                mixedRow:SetVisibility('collapsed');instance.mixedKey=nil
                Relayout()
                if instance.mixedBuy.CancelEditing then instance.mixedBuy:CancelEditing('material_changed') end
                if instance.mixedCraft.CancelEditing then instance.mixedCraft:CancelEditing('material_changed') end
            end
            if row then
                ShowSelection(row,true)
            end
        end,
        onItemActivated=function(row)return instance:ToggleBranch(row,false)end,
        getKey = function(item) return item and item.key or nil end,
        columns = {
            { id = "name", title = "材料", field = "name", size = "fill", minWidth = 96, fill = 1.6,
                getTone=function(row)return row and row.tone or 'muted'end },
            { id = "need", title = "需", field = "need", size = "fixed", width = 32, minWidth = 30 },
            { id = "held", title = "有", field = "held", size = "fixed", width = 32, minWidth = 30 },
            { id = "shortage", title = "缺", field = "shortage", size = "fixed", width = 32, minWidth = 30,
                getTone=function(row)return row and row.tone or 'muted'end },
            { id = "labor", title = "劳/次", field = "labor", size = "fixed", width = 44, minWidth = 40 },
            { id = "unitPrice", title = "单价", field = "unitPrice", size = "fixed", width = 92, minWidth = 78 },
        },
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    instance.summary=RSUI:Text({id='v3_craft_sidecar_summary',parent=bottomArea,text='费用与劳力待计算',fontSize=8,tone='muted',
        overflow='wrap',maxLines=3,slot={size='fixed',height=44,hAlign='fill'}})
    instance.laborStatus=RSUI:Text({id='v3_craft_sidecar_labor_status',parent=bottomArea,text='当前劳力待核',fontSize=8,tone='muted',
        overflow='wrap',maxLines=1,slot={size='fixed',height=18,hAlign='fill'}})
    function instance:SetManagementMode(open)
        managementOpen=open==true
        management:SetText(managementOpen and '返回材料' or '管理')
        local settingsVisibility=managementOpen and 'visible' or 'collapsed'
        for _,section in ipairs({searchRow,editRow,planManagerRow,shareRow,candidateRow,treeActions})do section:SetVisibility(settingsVisibility) end
        local workflowVisibility=managementOpen and 'collapsed' or 'visible'
        for _,section in ipairs({quantityRow,materialActions,self.summary,self.laborStatus})do
            section:SetVisibility(workflowVisibility)
        end
        self.table:SetVisibility('visible')
        if managementOpen then
            targetRow:SetVisibility('collapsed');comparisonArea:SetVisibility('collapsed');mixedRow:SetVisibility('collapsed')
            self.mixedKey=nil
        end
        Relayout()
        return true
    end
    function instance:SetComparisonMode(open)
        comparisonArea:SetVisibility(open and 'visible' or 'collapsed')
        local visibility=(open or managementOpen) and 'collapsed' or 'visible'
        for _,section in ipairs({quantityRow,materialActions,self.summary,self.laborStatus})do
            section:SetVisibility(visibility)
        end
        self.table:SetVisibility(open and 'collapsed' or 'visible')
        treeActions:SetVisibility(not open and managementOpen and 'visible' or 'collapsed')
        if open then mixedRow:SetVisibility('collapsed');self.mixedKey=nil end
        Relayout()
        return true
    end
    if root == nil or instance.recipe == nil or instance.addSaved == nil or instance.refresh == nil or instance.quote == nil
        or instance.search == nil or instance.nameInput == nil or instance.quantity == nil or instance.deleteButton == nil
        or addPlan == nil or instance.readChain == nil or instance.status == nil or instance.table == nil or bodySplit == nil or controlArea == nil or listArea == nil then
        return nil, "配方制作侧窗控件构建失败"
    end

    instance.refresh.onClick = function()
        local command=Feature.Commands.PlanRefreshInventory
        local ok,err
        if command then ok,err=command(Feature.Commands,false) else ok,err=Feature.Commands:Refresh('craft_sidecar_manual') end
        if ok == true then instance:Refresh() end
        instance.status:SetText(ok == true and tostring(err or "已核对计划背包库存") or ("核对失败：" .. tostring(err or "未执行")))
        return ok, err
    end
    instance.quote.onClick = function()
        local quote=(Feature:GetProjection().plan or {}).quote
        if quote and quote.status=='querying' then return Action('PlanCancelPrices') end
        local command=Feature.Commands.PlanCalibrate or Feature.Commands.QuotePendingMaterials
        if type(command) ~= "function" then return false, "材料询价命令不可用" end
        local ok, message = command(Feature.Commands)
        if ok == true then instance:Refresh() end
        instance.status:SetText(ok == true and tostring(message or "询价已提交") or ("询价失败：" .. tostring(message or "未执行")))
        return ok, message
    end

    -- 只记录按钮回调是否到达与完成，不记录输入内容，也不改动 Native 绑定。
    local tips={
        add_plan='开始等待本人在 O 页分享的配方；再次点击取消。',
        manage='展开或收起配方管理和高级设置。',settings='在工具页打开高级设置，不改变小窗材料列表。',
        add_target='将已保存的配方或物品加入当前多目标计划。',
        compare='比较购买成品与从原材料制作的成本和劳力；未知数据会标为待核。',
        add_saved='打开下拉框中选择的配方。',
        refresh='核对背包库存；银行库存需在管理中另行核对。',
        quote='逐个查询当前配方和子材料的价格；查询中再次点击停止。打开拍卖行也会停止本轮，不自动恢复。',
        read_chain='读取当前配方及材料的子配方，完成后更新材料列表。',
        quantity_apply='应用制作件数；按回车或离开输入框也会提交。',
        filter='按输入的名称筛选本地配方和物品。',clear_filter='清除筛选，显示全部本地结果。',
        rename='将当前计划改为输入的名称。',delete='删除当前配方；需要再次点击确认。',
        bank='核对已打开的银行和背包库存。',new_plan='新建可容纳多个目标的计划。',copy_plan='复制当前计划，生成一份独立计划。',
        import_link='导入输入框中的配方分享链接。',save_labor='保存选中配方的每次劳力和手续费；当前劳力仅用于显示。',
        cancel_work='停止当前下级配方读取和价格校准。',confirm_target='将所选配方或物品作为目标加入当前计划。',
        remove_target='从当前多目标计划移除选中的目标。',apply_all='采用完整比较后给出的整份计划建议。',
        apply_one='只采用所选材料的比较建议。',close_compare='关闭成本比较并返回材料列表。',
        expand='展开或收起选中的材料；也可直接点击材料行。',receive_material='接收本人分享的配方，补充给选中的材料。',
        mark_base='确认选中材料是原料，原料路线将按购买计算。',
        buy='将选中材料设置为拍卖行购买。',craft='将选中材料设置为自己制作，需要可用子配方。',
        mixed='为选中材料分别输入购买数量和制作数量。',search_auction='在拍卖行搜索选中的材料，不会自动购买。',
        quote_one='重新查询并校准选中材料的价格。',apply_mixed='保存购买和制作数量，两者之和须等于缺口。',
        reset_corrupt='清空当前角色损坏的制作计划并重建，其他功能的存档不受影响。',
    }
    local function BindTip(component,text)
        if component and text and RSUI.Tooltip and type(RSUI.Tooltip.Bind)=='function' then
            RSUI.Tooltip:Bind(component,{text=text,maxWidth=320})
        end
    end
    BindTip(instance.quantity.input,'输入目标数量；按回车、点击应用或离开输入框后重新计算材料。')
    BindTip(instance.recipe,'选择已接收的配方；列表只显示本地保存的配方。')
    if bodySplit and bodySplit.dividerDrag then
        if RSUI.Tooltip and type(RSUI.Tooltip.Bind)=='function' then
            RSUI.Tooltip:Bind(bodySplit.dividerDrag,{provider=function()
                bodySplit:CapturePointerEvidence('hover')
                return '按住左键上下拖动：向下扩大材料列表，向上扩大下方操作区。'
            end,allowRaw=true,maxWidth=320})
        end
    end
    local function TraceButtons(node)
        if type(node)~='table' then return end
        if node.kind=='Button' and type(node.onClick)=='function' and tostring(node.id):find('v3_craft_sidecar_',1,true)==1 then
            local callback,id=node.onClick,node.id
            local tipKey=tostring(id):gsub('^v3_craft_sidecar_','')
            BindTip(node,tips[tipKey])
            node.onClick=function(...)
                Controller.actionAttempts=(Controller.actionAttempts or 0)+1
                Controller.lastAction=tostring(id):sub(1,96);Controller.lastActionResult='entered';Controller.lastActionError=nil
                local ok,why=callback(...)
                Controller.lastActionResult=ok==false and 'rejected' or 'completed'
                if ok==false and why~=nil then Controller.lastActionError=tostring(why):sub(1,256) end
                return ok,why
            end
        end
        for _,child in ipairs(node.children or {})do TraceButtons(child) end
    end
    TraceButtons(root)

    function instance:ApplyAnchor(snapshot)
        if type(snapshot) == "table" then Controller.snapshot = snapshot end
        -- 独立窗口由 FloatingSurface/Windowing 解析默认居中与保存位置；重开不能覆盖拖动结果。
        return self.surface:ApplyLayout(false)
    end

    function instance:Refresh()
        local projection = Feature:GetProjection() or {}
        local plan = projection.plan
        if plan then
            local identity=tostring(plan.sessionRevision)..':'..tostring(plan.activeId)..':'..tostring(plan.libraryActiveId)
            if self.planIdentity~=identity then
                self.planIdentity=identity;self.selectedMaterial=nil;self.activeTargetId=nil;self.expanded={};self.deleteArmed=nil
                self.addRecipeId=nil;self.comparison=nil;self:SetComparisonMode(false);targetRow:SetVisibility('collapsed')
                self.manualLabor:SetValue('',false);self.manualFee:SetValue('',false)
                if self.previousSession~=plan.sessionRevision then self.availableLabor=nil;self.currentLabor:SetValue('',false) end
                self.previousSession=plan.sessionRevision
                self.table:SetSelectedIndex(nil)
                if type(Feature.Commands.RecipeOpen)=='function' then self.savedRecipeId=plan.libraryActiveId end
                if self.nameInput.CancelEditing then self.nameInput:CancelEditing('recipe_changed') end
                self.nameInput:SetValue(plan.name or '',false)
                if self.quantity.input and self.quantity.input.CancelEditing then self.quantity.input:CancelEditing('recipe_changed') end
                self.lastPlanName=plan.name
            elseif self.lastPlanName~=plan.name and (not self.nameInput.HasDraftSession or not self.nameInput:HasDraftSession()) then
                self.nameInput:SetValue(plan.name or '',false);self.lastPlanName=plan.name
            end
            self.deleteButton:SetText(self.deleteArmed and '确认删' or '删除')
            self.quantity:Render()
        end
        local receipt = plan and plan.importFeedback
        local receiptId = receipt and (tostring(plan.sessionRevision) .. ":" .. tostring(receipt.id) .. ":" .. tostring(not not plan.pendingShare))
        self.recipe.items={}
        self.addRecipe.items={}
        self.planSelector.items=plan and plan.plans or {}
        for _,option in ipairs(plan and (plan.libraryEntries or plan.contextRecipeOptions) or {})do
            if self.searchText=='' or option.text:find(self.searchText,1,true) then
                self.recipe.items[#self.recipe.items+1]=option
                self.addRecipe.items[#self.addRecipe.items+1]=option
            end
        end
        for _,option in ipairs(plan and plan.catalog or {})do
            if self.searchText=='' or tostring(option.text):find(self.searchText,1,true) then
                self.addRecipe.items[#self.addRecipe.items+1]={value='item:'..option.value,text='物品：'..tostring(option.text)}
            end
        end
        if type(self.recipe.Render) == "function" then self.recipe:Render() end
        if type(self.addRecipe.Render) == "function" then self.addRecipe:Render() end
        if type(self.planSelector.Render) == "function" then self.planSelector:Render() end
        local rows = MaterialRows(projection,self)
        local selectedKey=self.selectedMaterial and self.selectedMaterial.key
        -- 计划与界面展开各自变化；让列表生成新版本，确保同一池行重新绑定可见文字。
        self.table:SetItems(rows)
        local evidence={planRevision=plan and plan.revision,baseRevision=projection.revision,rowCount=#rows,rows={}}
        local list=self.table:GetListView()
        for index=1,math.min(8,#rows)do
            local item=rows[index];local visible=list and list:GetRowForIndex(index)
            evidence.rows[#evidence.rows+1]={itemKey=item.itemKey,need=item.need,
                visibleNeed=visible and visible.cells and visible.cells[2] and visible.cells[2].text or nil}
        end
        self.renderEvidence=evidence
        if selectedKey then
            for index,row in ipairs(rows)do if row.key==selectedKey then self.table:SetSelectedIndex(index);break end end
        end
        self.selectedMaterial=self.table:GetSelectedIndex() and self.table:GetItem(self.table:GetSelectedIndex()) or nil
        if self.selectedMaterial then ShowSelection(self.selectedMaterial,false) end
        local showReset=plan and plan.status=='unavailable' and plan.canResetCorrupt==true
        local nextResetVisibility=showReset and 'visible' or 'collapsed'
        if resetRow.visibility~=nextResetVisibility then resetRow:SetVisibility(nextResetVisibility);Relayout() end
        if not plan then
            self.planReadUnavailable=true
            self.status:SetText('制作计划未就绪，请稍后重试')
            self.table:SetViewState('empty',{title='制作计划未就绪',detail='等待计划数据加载。'})
        elseif plan.status=='unavailable' then
            self.planReadUnavailable=true
            self.status:SetText('计划读取失败：'..PlanError(plan.error))
            self.table:SetViewState('empty',{title='制作计划不可用',detail=showReset and '可清空损坏计划并重新接收配方。' or '请查看读取失败原因，原存档已保留。'})
        else
            if self.planReadUnavailable then
                self.planReadUnavailable=nil
                if not self.selectedMaterial then self.status:SetText('制作计划已就绪') end
            end
            if #rows == 0 then self.table:SetViewState("empty", { title = "暂无制作目标", detail = "接收一次配方分享，或从上方打开已保存配方。" }) else self.table:SetViewState("ready") end
        end
        -- 材料行刷新也会更新状态栏；接收回执必须后显示，等待中的失败不能被背景刷新掩盖。
        if plan and plan.status~='unavailable' and receipt
            and (receiptId~=self.lastImportFeedback or (plan.pendingShare and receipt.ok==false)) then
            self.lastImportFeedback=receiptId
            self.status:SetText(tostring(receipt.message or ''))
            if type(self.status.SetTone)=='function' then self.status:SetTone(receipt.ok and 'muted' or 'warn') end
        end
        local result=plan and plan.evaluation
        if result then
            local material=result.materialCopper or math.max(0,(tonumber(result.cashCopper) or 0)-(tonumber(result.feeCopper) or 0))
            local missing=#(result.missingPrices or {})
            self.summary:SetText((result.materialCostComplete and result.feeComplete~=false and '金币估算 ' or '已知合计 ')..Money(result.cashCopper)..
                (missing>0 and (' · 缺价 '..missing..'项未计入') or '')..
                '\n材料 '..Money(material)..' + 制作费 '..Money(result.feeCopper or 0)..(result.feeComplete==false and '+待填' or '')..
                '\n劳力 '..tostring(result.labor or 0)..(result.laborComplete and '' or '+待填')..
                ' · 有价 '..tostring(result.pricedPurchaseCount or 0)..'/'..tostring(result.purchaseCount or 0)..(result.priceStale and '（旧参考）' or '')..
                (not plan.inventoryComplete and '（库存待核）' or plan.inventoryScope=='bag_bank' and '（不含保管箱）' or '')..
                (result.combinedCopper~=nil and (' · 含劳力 '..Money(result.combinedCopper)) or ''))
            if self.availableLabor~=nil and result.laborComplete and plan.inventoryComplete then
                local enough=self.availableLabor>=result.labor
                self.laborStatus:SetText('当前劳力（手填） '..self.availableLabor..' / 需要 '..result.labor..' · '..(enough and '足够' or ('不足 '..(result.labor-self.availableLabor))))
                if self.laborStatus.SetTone then self.laborStatus:SetTone(enough and 'success' or 'danger') end
            else
                self.laborStatus:SetText('当前劳力或配方消耗待核对')
                if self.laborStatus.SetTone then self.laborStatus:SetTone('warn') end
            end
        end
        local pending = math.max(0, tonumber(projection.pendingQuoteCount) or 0)
        local reading=plan and plan.scan~=nil
        self.readChain:SetText(reading and '读取中' or '获取子配方')
        self.readChain:SetEnabled(not reading and plan~=nil and plan.status~='unavailable'
            and #(plan.targets or {})>0 and type(Feature.Commands.PlanReadRecipes)=='function')
        local quote=plan and plan.quote
        local querying=quote and quote.status=='querying'
        self.quote:SetEnabled(querying or projection.plan and #rows>0 or pending > 0)
        self.quote:SetText(querying and '查询中' or '获取全部价格')
        local craft = type(projection.craft) == "table" and projection.craft or {}
        local status = tostring(craft.status or projection.status or "idle")
        local queryStatus
        if querying then queryStatus='查询中 '..tostring(quote.completed or 0)..'/'..tostring(quote.total or 0)..' · '..tostring(quote.currentName or '')
        elseif quote and quote.status=='stopped' then
            queryStatus=quote.reason=='native_auction_visible' and '已停止查询：玩家正在使用拍卖行'
                or quote.reason=='native_auction_visibility_unknown' and '已停止查询：无法确认拍卖行已关闭' or '已停止价格查询'
        elseif quote and quote.status=='completed' then
            queryStatus='查询完成 '..tostring(quote.completed or 0)..'项 · 无记录 '..tostring(quote.empty or 0)..' · 失败 '..tostring(quote.failed or 0)
                ..(quote.truncated and '（配方树超限，未全部查询）' or '')
        end
        self.surface:SetStatus(queryStatus or (projection.plan and ('当前计划 · '..tostring(#rows)..' 个条目') or (status..' · 材料 '..tostring(#rows))), (status == "failed" or status == "unavailable") and "orange" or "muted")
        return true
    end

    function instance:Subscribe()
        if self.subscribed == true then return true end
        if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
            S.Events:SubscribeInternal(Feature.UpdateTopic, self, function() if instance.visible == true then instance:Refresh() end end)
        end
        self.subscribed = true; return true
    end
    function instance:Unsubscribe()
        if self.subscribed ~= true then return true end
        if S.Events ~= nil and type(S.Events.UnsubscribeInternalOwner) == "function" then S.Events:UnsubscribeInternalOwner(self) end
        self.subscribed = false; return true
    end
    function instance:Show(context)
        context = type(context) == "table" and context or {}
        if type(context.snapshot) == "table" then Controller.snapshot = context.snapshot end
        local positioned,positionErr=self:ApplyAnchor(Controller.snapshot)
        if positioned~=true then return false,positionErr end
        if self.visible == true then self:Refresh(); return self.surface:Show(true) end
        self:Subscribe()
        local acquired, acquireErr = Feature:AcquireConsumer("widget:craft_sidecar")
        if acquired ~= true then self:Unsubscribe(); return false, acquireErr or "配方制作侧窗 Consumer 获取失败" end
        self.acquired = true; self:Refresh()
        local shown, showErr = self.surface:Show(true)
        if shown ~= true then Feature:ReleaseConsumer("widget:craft_sidecar"); self.acquired = false; self:Unsubscribe(); return false, showErr or "配方制作侧窗显示失败" end
        self.visible = true; return true
    end
    function instance:Hide()
        if self.bodySplit then self.bodySplit:CancelDrag('window_hidden') end
        local hidden, hideErr = self.surface:Show(false)
        if hidden ~= true then return false, hideErr end
        Controller.manualVisible = false
        -- Feature Disable 会先 Clear Demand，
        -- WidgetHost 随后的 Hide 只能按真实 token 释放，不能相信 acquired 的旧值触发 strict Demand 二次 Release。
        if self.acquired == true and Feature:HasConsumer("widget:craft_sidecar") then Feature:ReleaseConsumer("widget:craft_sidecar") end
        self.acquired = false; self.visible = false; self:Unsubscribe()
        if Feature.Commands.PlanCancelReceiveShare then Feature.Commands:PlanCancelReceiveShare('widget:craft_sidecar') end
        return true
    end
    function instance:OnWindowClosed()
        if self.bodySplit then self.bodySplit:CancelDrag('window_closed') end
        Controller.manualVisible = false
        if self.acquired == true and Feature:HasConsumer("widget:craft_sidecar") then Feature:ReleaseConsumer("widget:craft_sidecar") end
        self.acquired = false; self.visible = false; self:Unsubscribe()
        if Feature.Commands.PlanCancelReceiveShare then Feature.Commands:PlanCancelReceiveShare('widget:craft_sidecar') end
        return true
    end
    function instance:Open(context) return self:Show(context) end
    function instance:Close(context) return self:Hide(context) end
    function instance:ApplyLayout(fromMetricsChange) return self.surface:ApplyLayout(fromMetricsChange == true) end
    return instance
end

local registered, registerErr = Host:Register(WIDGET_ID, {
    featureId = "tools_craft", create = CreateSidecar,
    ensurePreferences = function() return Feature:Initialize() end,
    lockable = false, minimizable = false, resettable = false,
    opacityAdjustable = false, backgroundOpacityAdjustable = false, textOpacityAdjustable = false,
})
if registered ~= true then error(registerErr) end
-- Feature 生命周期控制资源；手动窗口或已确认的原生窗口可持有显隐需求。
local lifecycleBound, lifecycleErr = Host:BindFeatureLifecycle(WIDGET_ID, {
    featureId = "tools_craft",
    enabled = function() return S.FeatureRuntime ~= nil and S.FeatureRuntime:IsEnabled("tools_craft") == true end,
    preference = function() return Controller.manualVisible == true or Controller.nativeVisible == true end,
})
if lifecycleBound ~= true then error(lifecycleErr or "craft sidecar lifecycle bind failed") end

local function OnSurface(snapshot)
    snapshot = type(snapshot) == "table" and snapshot or {}
    Controller.observations = Controller.observations + 1
    Controller.lastSource, Controller.lastReason = snapshot.source, snapshot.reason
    local wasVisible = Controller.nativeVisible == true
    local projection = Feature:GetProjection() or {}
    Controller.nativeVisible = S.FeatureRuntime ~= nil and S.FeatureRuntime:IsEnabled("tools_craft") == true
        and projection.autoSidecar ~= false and snapshot.status == "ready" and snapshot.visible == true
    Controller.snapshot = snapshot
    -- 手动打开不依赖 O 页观测；全 nil 仅表示未知，不能把用户窗口收走。
    if Controller.manualVisible and S.FeatureRuntime and S.FeatureRuntime:IsEnabled('tools_craft')==true then
        Controller.lastDecision='manual_visible';return true
    end
    if Controller.nativeVisible ~= true then
        Controller.lastDecision = projection.autoSidecar == false and "auto_sidecar_disabled"
            or (snapshot.status ~= "ready" and "native_surface_unknown" or "native_surface_hidden")
        if snapshot.status == "ready" and snapshot.visible ~= true then Controller.dismissed = false end
        if Host:IsVisible(WIDGET_ID) == true then Host:SetVisible(WIDGET_ID, false, { persist = false, source = "craft_native_close" }) end
        return true
    end
    if wasVisible ~= true then Controller.dismissed = false end
    if Controller.dismissed == true then Controller.lastDecision = "user_dismissed"; return true end
    if Host:IsVisible(WIDGET_ID) ~= true then
        Controller.showAttempts = Controller.showAttempts + 1
        local shown, showError = Host:SetVisible(WIDGET_ID, true, { persist = false, source = "craft_native_open", snapshot = snapshot })
        if shown ~= true then
            Controller.showFailures = Controller.showFailures + 1; Controller.lastDecision = "show_failed"
            Controller.lastShowError = tostring(showError or "unknown"):sub(1, 200); return false
        end
    end
    Controller.lastDecision = "shown"
    local instance = Host:GetInstance(WIDGET_ID)
    if type(instance) == "table" and type(instance.ApplyAnchor) == "function" then return instance:ApplyAnchor(snapshot) end
    return true
end

if S.Events ~= nil and type(S.Events.SubscribeInternal) == "function" then
    S.Events:SubscribeInternal(SurfaceService.topic or "v3.craft_surface.updated", Controller, function(_, snapshot) return OnSurface(snapshot) end)
end
OnSurface(SurfaceService:GetSnapshot())
