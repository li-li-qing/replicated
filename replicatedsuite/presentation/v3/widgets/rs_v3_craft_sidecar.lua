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

local Controller = { nativeVisible = false, manualVisible = false, dismissed = false, snapshot = nil, observations = 0, showAttempts = 0, showFailures = 0 }
S.UIV3 = S.UIV3 or {}
S.UIV3.CraftSidecar = Controller
function Controller:Describe()
    return { nativeVisible = self.nativeVisible == true, manualVisible = self.manualVisible == true, dismissed = self.dismissed == true,
        observations = self.observations, showAttempts = self.showAttempts, showFailures = self.showFailures,
        lastDecision = self.lastDecision, lastSource = self.lastSource, lastReason = self.lastReason,
        lastShowError = self.lastShowError }
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
                -- 购买分支仍可看配方，但预览数量不进入当前采购和库存抵扣。
                local parents=row and type(row.parents)=='table' and #row.parents or 0
                local shared=row and (parents>1 or (roots[key] and parents>0))
                local aggregate=shared or sharedParent
                local bagOnly=plan.inventoryScope=='bag'
                rows[#rows+1]={key=path,itemKey=key,targetId=targetId,isTarget=depth==0,item=item,preview=isPreview,name=string.rep('  ',depth)..
                    (recipe and (instance.expanded[path]==false and '+ ' or '- ') or (row and row.recipeUnknown and '? ' or ''))..
                    (item.name or ('物品 '..item.itemType))..(aggregate and '（库存合计）' or ''),
                    need=row and tostring(branchNeed or row.demand) or (tostring(item.count or '?')..'/次'),
                    held=row and (row.inventoryUncertain and '?' or (plan.inventoryComplete or bagOnly) and ((bagOnly and '包' or aggregate and '合' or '')..tostring(row.owned)) or '?') or '-',
                    shortage=row and (row.inventoryUncertain and '?' or plan.inventoryComplete and ((aggregate and '合' or '')..tostring(row.shortage))
                        or (bagOnly and row.shortage==0 and '0' or '?')) or '-',
                    tone=not row and 'muted' or row.inventoryUncertain and 'warn' or (bagOnly and row.shortage==0) and 'success'
                        or not plan.inventoryComplete and 'warn' or row.shortage==0 and 'success' or 'danger'}
                if visiting[key] or instance.expanded[path]==false or not recipe then return end
                visiting[key]=true
                for i,item in ipairs(recipe.materials or {})do
                    local child=tostring(item.itemType)..':'..tostring(item.grade==nil and '*' or item.grade)..':'..tostring(item.variant or '*')
                    local childPreview=isPreview or (row and row.craft~=nil and (tonumber(row.craft) or 0)<=0)
                    local childNeed
                    if not childPreview and not aggregate and row and tonumber(row.batches) and tonumber(item.count) then
                        childNeed=row.batches*item.count
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
    local craft = type(projection) == "table" and type(projection.craft) == "table" and projection.craft or {}
    local rows = {}
    for _, recipe in ipairs(type(craft.recipes) == "table" and craft.recipes or {}) do
        local materials = type(recipe.materials) == "table" and recipe.materials.items or nil
        for _, item in ipairs(type(materials) == "table" and materials or {}) do
            rows[#rows + 1] = {
                key = "craft-sidecar:" .. tostring(recipe.craftType or 0) .. ":" .. tostring(item.itemType or #rows + 1),
                name = tostring(item.name or (item.itemType ~= nil and ("物品 " .. tostring(item.itemType)) or "材料")),
                need = item.count ~= nil and tostring(item.count) or "?",
                held = item.held ~= nil and tostring(item.held) or "?",
                shortage = item.shortage ~= nil and tostring(item.shortage) or "?",
            }
        end
    end
    return rows
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
        width = WIDTH, height = HEIGHT, minWidth = WIDTH, minHeight = HEIGHT, maxWidth = WIDTH, maxHeight = HEIGHT,
        resizable = false, movable = true, footer = true, closeButton = true, appearanceControls = false,
        -- 固定工具尺寸与内部固定按钮同一 logical 单位；不能只缩外框、使 0.75 倍时按钮排出窗外。
        scaleWithAddon = false, minimizeMode = "compact", boundaryMode = "strict",
        statePolicy = { defaultWidth = WIDTH, defaultHeight = HEIGHT, minWidth = WIDTH, minHeight = HEIGHT, maxWidth = WIDTH, maxHeight = HEIGHT,
            defaultLocked = false, defaultOverallOpacity = 0.96, defaultBackgroundOpacity = 1.0, defaultTextOpacity = 1.0 },
        getState = function() return instance.state end,
        setState = function(value)
            if type(value) ~= "table" then return false, "sidecar state invalid" end
            CopyState(instance.state, value); return true
        end,
        persist = function()
            if type(Feature.Commands.SetCraftWindowState)~='function' then return false,'配方小窗位置保存不可用' end
            return Feature.Commands:SetCraftWindowState(instance.state)
        end,
        onClosed = function(_, reason)
            Controller.manualVisible = false
            Controller.dismissed = true
            return Host:NotifyWindowClosed(WIDGET_ID, { persist = false, source = tostring(reason or "craft_sidecar_close") })
        end,
    })
    if surface == nil then return nil, surfaceErr or "配方制作侧窗创建失败" end
    instance.surface, instance.shell, instance.windowController = surface, surface.shell, surface.windowController

    local content = surface:GetContentRoot()
    local root = RSUI:VerticalBox({ id = "v3_craft_sidecar_content", parent = content, gap = 5,
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" } })
    local function Action(command,...)
        local fn=Feature.Commands[command]
        if type(fn)~='function' then return false,'配方管理命令不可用' end
        local ok,why=fn(Feature.Commands,...)
        instance:Refresh()
        instance.status:SetText(ok and tostring(why or '已更新') or ('未完成：'..tostring(why)))
        if instance.status.SetTone then instance.status:SetTone(ok and 'muted' or 'warn') end
        return ok,why
    end
    local function OutputCount()
        local value=instance.outputCount and tostring(instance.outputCount:GetDraftValue() or '') or ''
        if value=='' then return nil,true end
        local count=value:match('^%s*%d+%s*$') and tonumber(value) or nil
        return count,count~=nil and count>=1 and count<=1000000000
    end
    local searchRow=RSUI:HorizontalBox({id='v3_craft_sidecar_search_row',parent=root,gap=4,slot={size='fixed',height=29,hAlign='fill'}})
    instance.search=RSUI:TextInput({id='v3_craft_sidecar_search',parent=searchRow,value='',placeholder='筛选本地配方和物品',maxLength=96,submitOnLostFocus=false,
        slot={size='fill',fill=1,minWidth=100}})
    RSUI:Button({id='v3_craft_sidecar_filter',parent=searchRow,text='筛选',compact=true,slot={size='fixed',width=48},onClick=function()
        instance.addRecipeId=nil;instance.searchText=tostring(instance.search:GetDraftValue() or '');return instance:Refresh()
    end})
    RSUI:Button({id='v3_craft_sidecar_clear_filter',parent=searchRow,text='全部',compact=true,slot={size='fixed',width=48},onClick=function()
        instance.addRecipeId=nil;instance.searchText='';instance.search:SetValue('',false);return instance:Refresh()
    end})
    searchRow:SetVisibility('collapsed')
    local recipeRow = RSUI:HorizontalBox({ id = "v3_craft_sidecar_recipe_row", parent = root, gap = 4,
        slot = { size = "fixed", height = 31, hAlign = "fill" } })
    instance.recipe = RSUI:Dropdown({ id = "v3_craft_sidecar_recipe", parent = recipeRow, items = {}, maxVisible = 12, popupWidth = 300,
        get = function()
            local projection=Feature:GetProjection() or {}
            if projection.plan then
                return projection.plan.libraryActiveId or instance.savedRecipeId
            end
            return projection.selectedRecipeKey
        end,
        set = function(value)
            if (Feature:GetProjection() or {}).plan then
                if type(Feature.Commands.RecipeOpen)=='function' then return Action('RecipeOpen',value) end
                instance.savedRecipeId=value;return true
            end
            local command=type(Feature.Commands.PlanAddSavedRecipe)=='function' and Feature.Commands.PlanAddSavedRecipe or Feature.Commands.SelectRecipe
            if type(command) ~= "function" then return false, "配方选择命令不可用" end
            local ok, err = command(Feature.Commands,value,1)
            if ok == true then instance.savedRecipeId=value;instance:Refresh() end; return ok, err
        end,
        placeholder = "选择配方，仅显示选中这一份", slot = { size = "fill", fill = 1, minWidth = 136 } })
    instance.addSaved=RSUI:Button({id='v3_craft_sidecar_add_saved',parent=recipeRow,text='打开',compact=true,
        slot={size='fixed',width=44},onClick=function()
            local selected=(Feature:GetProjection().plan or {}).libraryActiveId or instance.savedRecipeId
            if type(Feature.Commands.RecipeOpen)=='function' then return Action('RecipeOpen',selected) end
            if not instance.savedRecipeId or not Feature.Commands.PlanAddSavedRecipe then return false,'请先选择已收录配方。' end
            local ok,why=Feature.Commands:PlanAddSavedRecipe(instance.savedRecipeId,1)
            instance.status:SetText(ok and '已加入当前计划' or tostring(why));if ok then instance:Refresh() end;return ok,why
        end})
    instance.refresh = RSUI:Button({ id = "v3_craft_sidecar_refresh", parent = recipeRow, text = "核对", compact = true, slot = { size = "fixed", width = 52 } })
    instance.quote = RSUI:Button({ id = "v3_craft_sidecar_quote", parent = recipeRow, text = "材料询价", compact = true, enabled = false, slot = { size = "fixed", width = 76 } })

    local editRow=RSUI:HorizontalBox({id='v3_craft_sidecar_edit_row',parent=root,gap=4,slot={size='fixed',height=29,hAlign='fill'}})
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
    local quantityRow=RSUI:HorizontalBox({id='v3_craft_sidecar_quantity_row',parent=root,gap=4,slot={size='fixed',height=31,hAlign='fill'}})
    local function ActiveTarget()
        local p=Feature:GetProjection().plan or {}
        for _,target in ipairs(p.targets or {})do if target.id==instance.activeTargetId then return target end end
        return p.targets and p.targets[1] or nil
    end
    instance.quantity=RSUI:NumericField({id='v3_craft_sidecar_quantity',parent=quantityRow,label='制作件数',inline=true,slider=false,integer=true,
        min=1,max=1000000000,hardMin=1,hardMax=1000000000,applyButton=true,labelWidth=52,inputWidth=62,
        get=function()local target=ActiveTarget();return target and target.count or 1 end,
        set=function(value)
            local target=ActiveTarget()
            if not target then return false,'先选择配方' end
            return Action('PlanSetQuantity',target.id,value)
        end,slot={size='fill',fill=1,minWidth=200}})
    RSUI:Button({id='v3_craft_sidecar_read_chain',parent=quantityRow,text='重读下级',compact=true,slot={size='fixed',width=76},onClick=function()return Action('PlanReadRecipes')end})

    local planRow = RSUI:HorizontalBox({ id = "v3_craft_sidecar_plan_row", parent = root, gap = 4,
        slot = { size = "fixed", height = 29, hAlign = "fill" } })
    local addPlan = RSUI:Button({ id = "v3_craft_sidecar_add_plan", parent = planRow, text = "接收新配方", compact = true,
        slot = { size = "fixed", width = 112 } })
    local managementOpen=false
    local laborRow,planManagerRow,shareRow
    local management=RSUI:Button({id='v3_craft_sidecar_manage',parent=planRow,text='管理',compact=true,
        slot={size='fixed',width=48},onClick=function()
            return instance:SetManagementMode(not managementOpen)
        end})
    local targetRow,comparisonArea
    RSUI:Button({id='v3_craft_sidecar_add_target',parent=planRow,text='加入目标',compact=true,slot={size='fixed',width=72},onClick=function()
        if managementOpen then instance:SetManagementMode(false) end
        instance:SetComparisonMode(false);searchRow:SetVisibility('visible');targetRow:SetVisibility('visible');return true
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
        instance.status:SetText(ok and tostring(err or '等待下一条配方分享') or ("未接收：" .. tostring(err)))
        if type(instance.status.SetTone) == "function" then instance.status:SetTone(ok and "muted" or "warn") end
        return ok, err
    end end

    planManagerRow=RSUI:HorizontalBox({id='v3_craft_sidecar_plan_manager',parent=root,gap=4,slot={size='fixed',height=27,hAlign='fill'}})
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
    shareRow=RSUI:HorizontalBox({id='v3_craft_sidecar_share_row',parent=root,gap=4,slot={size='fixed',height=27,hAlign='fill'}})
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
    laborRow=RSUI:HorizontalBox({id='v3_craft_sidecar_labor_row',parent=root,gap=4,slot={size='fixed',height=27,hAlign='fill'}})
    instance.manualLabor=RSUI:TextInput({id='v3_craft_sidecar_manual_labor',parent=laborRow,value='',placeholder='劳力/次',maxLength=10,
        submitOnLostFocus=false,slot={size='fill',fill=1,minWidth=50}})
    instance.manualFee=RSUI:TextInput({id='v3_craft_sidecar_manual_fee',parent=laborRow,value='',placeholder='手续费铜/次',maxLength=10,
        submitOnLostFocus=false,slot={size='fill',fill=1,minWidth=50}})
    instance.currentLabor=RSUI:TextInput({id='v3_craft_sidecar_current_labor',parent=laborRow,value='',placeholder='当前劳力',maxLength=10,
        submitOnLostFocus=false,slot={size='fill',fill=1,minWidth=50}})
    RSUI:Button({id='v3_craft_sidecar_save_labor',parent=laborRow,text='校准',compact=true,slot={size='fixed',width=48},onClick=function()
        local function Number(input)
            local value=tostring(input:GetDraftValue() or '')
            if value=='' then return nil,true end
            if not value:match('^%s*%d+%s*$') then return nil,false end
            local n=tonumber(value);return n,n~=nil and n<=1000000000
        end
        local labor,validLabor=Number(instance.manualLabor)
        local fee,validFee=Number(instance.manualFee)
        local current,validCurrent=Number(instance.currentLabor)
        if not validLabor or not validFee or not validCurrent or ((labor~=nil or fee~=nil) and (labor==nil or fee==nil)) then
            instance.status:SetText('请填写非负整数；配方劳力和手续费需同时确认');return false
        end
        if labor~=nil then
            local row=instance.selectedMaterial
            if not row or row.preview then instance.status:SetText('先选择要校准的制作配方');return false end
            local ok,why=Action('PlanSetRecipeCosts',row.itemKey,labor,fee)
            if not ok then return false,why end
        end
        instance.availableLabor=current
        instance:Refresh();return true
    end})
    laborRow:SetVisibility('collapsed')
    local candidateRow=RSUI:HorizontalBox({id='v3_craft_sidecar_candidate_row',parent=root,gap=4,slot={size='fixed',height=27,hAlign='fill'}})
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
                if not started then instance.status:SetText('配方已选择；可点击重读下级') end
            end
            return ok,why
        end,slot={size='fill',fill=1,minWidth=130}})
    RSUI:Button({id='v3_craft_sidecar_cancel_work',parent=candidateRow,text='停止查询',compact=true,
        slot={size='fixed',width=72},onClick=function()return Action('PlanCancel')end})
    candidateRow:SetVisibility('collapsed')
    targetRow=RSUI:HorizontalBox({id='v3_craft_sidecar_target_row',parent=root,gap=4,slot={size='fixed',height=29,hAlign='fill'}})
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
        end
        return ok,why
    end})
    RSUI:Button({id='v3_craft_sidecar_remove_target',parent=targetRow,text='移除目标',compact=true,slot={size='fixed',width=76},onClick=function()
        local row=instance.selectedMaterial
        if not row or not row.isTarget then instance.status:SetText('先选择目标行');return false end
        return Action('PlanRemoveTarget',row.targetId)
    end})
    targetRow:SetVisibility('collapsed')
    comparisonArea=RSUI:VerticalBox({id='v3_craft_sidecar_comparison_area',parent=root,gap=2,slot={size='fixed',height=110,hAlign='fill'}})
    instance.compareText=RSUI:Text({id='v3_craft_sidecar_compare_text',parent=comparisonArea,text='',fontSize=8,tone='muted',
        overflow='wrap',maxLines=4,slot={size='fixed',height=79,hAlign='fill'}})
    local compareActions=RSUI:HorizontalBox({id='v3_craft_sidecar_compare_actions',parent=comparisonArea,gap=4,slot={size='fixed',height=27,hAlign='fill'}})
    RSUI:Button({id='v3_craft_sidecar_apply_all',parent=compareActions,text='采纳建议',compact=true,slot={size='fixed',width=76},onClick=function()
        local c=instance.comparison
        if not c or not c.result or not c.result.recommendation or not c.result.recommendation.available then return false,'缺少有效成本，无法采纳建议' end
        local ok,why=Action('PlanApplyRecommendation',c.revision)
        if ok then instance.comparison=nil;instance:SetComparisonMode(false) end
        return ok,why
    end})
    RSUI:Button({id='v3_craft_sidecar_apply_one',parent=compareActions,text='采纳此项',compact=true,slot={size='fixed',width=76},onClick=function()
        local c,row=instance.comparison,instance.selectedMaterial
        if not c or not row or not c.result or not c.result.recommendation or not c.result.recommendation.available then return false,'请先比较并选择有效建议' end
        local ok,why=Action('PlanApplyRecommendation',c.revision,row.itemKey)
        if ok then instance.comparison=nil;instance:SetComparisonMode(false) end
        return ok,why
    end})
    RSUI:Button({id='v3_craft_sidecar_close_compare',parent=compareActions,text='关闭',compact=true,slot={size='fixed',width=52},onClick=function()
        instance:SetComparisonMode(false);return true
    end})
    comparisonArea:SetVisibility('collapsed')

    local treeActions=RSUI:HorizontalBox({id='v3_craft_sidecar_tree_actions',parent=root,gap=4,slot={size='fixed',height=27,hAlign='fill'}})
    RSUI:Button({id='v3_craft_sidecar_expand',parent=treeActions,text='展开/收起',compact=true,slot={size='fixed',width=84},onClick=function()
        local row=instance.selectedMaterial;if not row then instance.status:SetText('先选材料行');return false end
        instance.expanded[row.key]=instance.expanded[row.key]==false;return instance:Refresh()
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

    local materialActions=RSUI:HorizontalBox({id='v3_craft_sidecar_material_actions',parent=root,gap=4,slot={size='fixed',height=27,hAlign='fill'}})
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
        mixedRow:SetVisibility('visible');return true
    end})
    RSUI:Button({id='v3_craft_sidecar_search_auction',parent=materialActions,text='搜索拍卖',compact=true,slot={size='fixed',width=72},onClick=function()return SelectedAction('PlanSearch')end})
    RSUI:Button({id='v3_craft_sidecar_quote_one',parent=materialActions,text='校准此项',compact=true,slot={size='fixed',width=72},onClick=function()return SelectedAction('PlanCalibrate')end})
    mixedRow=RSUI:HorizontalBox({id='v3_craft_sidecar_mixed_row',parent=root,gap=4,slot={size='fixed',height=27,hAlign='fill'}})
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
        if ok then mixedRow:SetVisibility('collapsed');instance.mixedKey=nil end
        return ok,why
    end})
    mixedRow:SetVisibility('collapsed')

    -- WindowShell footer 占用 v3_craft_sidecar_status，业务反馈须用独立 ID，否则首次构建会被隔离。
    instance.status = RSUI:Text({ id = "v3_craft_sidecar_action_status", parent = root,
        text = "点接收后分享并发送配方；问号材料可选中后补子配方，或确认为原料。", fontSize = 8, tone = "muted", overflow = "wrap", maxLines = 2,
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
        local reason=''
        for _,issue in ipairs(p.scanResult and p.scanResult.issues or {})do if issue.key==row.itemKey then reason='；'..issue.reason;break end end
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
    instance.table = RSUI:TableView({
        id = "v3_craft_sidecar_table", parent = root, items = {}, rowHeight = 27, headerHeight = 26,
        desiredRows = 10, overscan = 1, scrollbar = true, selectable = true, columnResize = false, headerInteractive = false,
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
                if instance.mixedBuy.CancelEditing then instance.mixedBuy:CancelEditing('material_changed') end
                if instance.mixedCraft.CancelEditing then instance.mixedCraft:CancelEditing('material_changed') end
            end
            if row then
                ShowSelection(row,true)
            end
        end,
        getKey = function(item) return item and item.key or nil end,
        columns = {
            { id = "name", title = "材料", field = "name", size = "fill", minWidth = 132, fill = 1.6,
                getTone=function(row)return row and row.tone or 'muted'end },
            { id = "need", title = "需", field = "need", size = "fixed", width = 44, minWidth = 36 },
            { id = "held", title = "有", field = "held", size = "fixed", width = 44, minWidth = 36 },
            { id = "shortage", title = "缺", field = "shortage", size = "fixed", width = 44, minWidth = 36,
                getTone=function(row)return row and row.tone or 'muted'end },
        },
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    instance.summary=RSUI:Text({id='v3_craft_sidecar_summary',parent=root,text='费用与劳力待计算',fontSize=8,tone='muted',
        overflow='wrap',maxLines=2,slot={size='fixed',height=28,hAlign='fill'}})
    instance.laborStatus=RSUI:Text({id='v3_craft_sidecar_labor_status',parent=root,text='当前劳力待核',fontSize=8,tone='muted',
        overflow='wrap',maxLines=1,slot={size='fixed',height=18,hAlign='fill'}})
    function instance:SetManagementMode(open)
        managementOpen=open==true
        local settingsVisibility=managementOpen and 'visible' or 'collapsed'
        for _,section in ipairs({searchRow,editRow,laborRow,planManagerRow,shareRow,candidateRow})do section:SetVisibility(settingsVisibility) end
        local workflowVisibility=managementOpen and 'collapsed' or 'visible'
        for _,section in ipairs({quantityRow,treeActions,materialActions,self.table,self.summary,self.laborStatus})do
            section:SetVisibility(workflowVisibility)
        end
        if managementOpen then
            targetRow:SetVisibility('collapsed');comparisonArea:SetVisibility('collapsed');mixedRow:SetVisibility('collapsed')
            self.mixedKey=nil
        end
        return true
    end
    function instance:SetComparisonMode(open)
        comparisonArea:SetVisibility(open and 'visible' or 'collapsed')
        local visibility=(open or managementOpen) and 'collapsed' or 'visible'
        for _,section in ipairs({quantityRow,treeActions,materialActions,self.table,self.summary,self.laborStatus})do
            section:SetVisibility(visibility)
        end
        if open then mixedRow:SetVisibility('collapsed');self.mixedKey=nil end
        return true
    end
    if root == nil or instance.recipe == nil or instance.addSaved == nil or instance.refresh == nil or instance.quote == nil
        or instance.search == nil or instance.nameInput == nil or instance.quantity == nil or instance.deleteButton == nil
        or addPlan == nil or instance.status == nil or instance.table == nil then
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
        local command=Feature.Commands.PlanCalibrate or Feature.Commands.QuotePendingMaterials
        if type(command) ~= "function" then return false, "材料询价命令不可用" end
        local ok, message = command(Feature.Commands)
        if ok == true then instance:Refresh() end
        instance.status:SetText(ok == true and tostring(message or "询价已提交") or ("询价失败：" .. tostring(message or "未执行")))
        return ok, message
    end

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
        local receiptId = receipt and (tostring(plan.sessionRevision) .. ":" .. tostring(receipt.id))
        if receipt and receiptId ~= self.lastImportFeedback then
            self.lastImportFeedback = receiptId
            self.status:SetText(tostring(receipt.message or ""))
            if type(self.status.SetTone) == "function" then self.status:SetTone(receipt.ok and "muted" or "warn") end
        end
        self.recipe.items={}
        self.addRecipe.items={}
        self.planSelector.items=plan and plan.plans or {}
        for _,option in ipairs(plan and (plan.libraryEntries or plan.contextRecipeOptions) or projection.recipeOptions or {})do
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
        self.table:SetItems(rows, "craft-sidecar:" .. tostring(projection.revision or 0))
        self.selectedMaterial=self.table:GetSelectedIndex() and self.table:GetItem(self.table:GetSelectedIndex()) or nil
        if self.selectedMaterial then ShowSelection(self.selectedMaterial,false) end
        if #rows == 0 then self.table:SetViewState("empty", { title = "暂无制作目标", detail = "接收一次配方分享，或从上方打开已保存配方。" }) else self.table:SetViewState("ready") end
        local result=plan and plan.evaluation
        if result then
            self.summary:SetText((result.costComplete and '还需参考 ' or '已知支出 ')..Money(result.cashCopper)..
                (result.priceStale and '（旧价）' or '')..
                ' · '..(result.valueComplete~=false and result.costComplete and '估值 ' or '已知估值 ')..Money(result.valueCopper)..
                ' · 劳力 '..tostring(result.labor or 0)..(result.laborComplete and '' or '+待核')..
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
        self.quote:SetEnabled(projection.plan and #rows>0 or pending > 0)
        self.quote:SetText(projection.plan and '校准价格' or (pending > 0 and ("询价(" .. tostring(pending) .. ")") or "材料询价"))
        local craft = type(projection.craft) == "table" and projection.craft or {}
        local status = tostring(craft.status or projection.status or "idle")
        self.surface:SetStatus(projection.plan and ('当前计划 · '..tostring(#rows)..' 个条目') or (status..' · 材料 '..tostring(#rows)), (status == "failed" or status == "unavailable") and "orange" or "muted")
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
