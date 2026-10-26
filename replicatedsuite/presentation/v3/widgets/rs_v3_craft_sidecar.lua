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
            local function Walk(key,path,depth,visiting)
                if #rows>=512 or depth>24 then return end
                local row=evaluation.byKey[key];if not row then return end
                local recipe=plan.recipes[(plan.choices or {})[key] or '']
                rows[#rows+1]={key=path,itemKey=key,item=row.item,name=string.rep('  ',depth)..
                    (recipe and (instance.expanded[key]==false and '+ ' or '- ') or (row.recipeUnknown and '? ' or ''))..(row.item.name or ('物品 '..row.item.itemType)),
                    need=tostring(row.demand),held=plan.inventoryComplete and tostring(row.owned) or '?',
                    shortage=plan.inventoryComplete and tostring(row.shortage) or '?'}
                if visiting[key] or instance.expanded[key]==false or not recipe then return end
                visiting[key]=true
                for i,item in ipairs(recipe.materials or {})do
                    local child=tostring(item.itemType)..':'..tostring(item.grade==nil and '*' or item.grade)..':'..tostring(item.variant or '*')
                    Walk(child,path..':'..i,depth+1,visiting)
                end
                visiting[key]=nil
            end
            for _,target in ipairs(plan.targets)do Walk(target.key,'target:'..target.id,0,{})end
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
        instance.status:SetText(ok and tostring(why or '已更新') or ('未完成：'..tostring(why)))
        instance:Refresh();return ok,why
    end
    local searchRow=RSUI:HorizontalBox({id='v3_craft_sidecar_search_row',parent=root,gap=4,slot={size='fixed',height=29,hAlign='fill'}})
    instance.search=RSUI:TextInput({id='v3_craft_sidecar_search',parent=searchRow,value='',placeholder='按名称查找已保存配方',maxLength=96,submitOnLostFocus=false,
        slot={size='fill',fill=1,minWidth=100}})
    RSUI:Button({id='v3_craft_sidecar_filter',parent=searchRow,text='筛选',compact=true,slot={size='fixed',width=48},onClick=function()
        instance.searchText=tostring(instance.search:GetDraftValue() or '');return instance:Refresh()
    end})
    RSUI:Button({id='v3_craft_sidecar_clear_filter',parent=searchRow,text='全部',compact=true,slot={size='fixed',width=48},onClick=function()
        instance.searchText='';instance.search:SetValue('',false);return instance:Refresh()
    end})
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
        local id=(Feature:GetProjection().plan or {}).libraryActiveId
        if not id then instance.status:SetText('请先选择一份配方');return false end
        if instance.deleteArmed~=id then instance.deleteArmed=id;instance.deleteButton:SetText('确认删');return true end
        instance.deleteArmed=nil;return Action('RecipeDelete',id)
    end})
    local quantityRow=RSUI:HorizontalBox({id='v3_craft_sidecar_quantity_row',parent=root,gap=4,slot={size='fixed',height=31,hAlign='fill'}})
    instance.quantity=RSUI:NumericField({id='v3_craft_sidecar_quantity',parent=quantityRow,label='制作件数',inline=true,slider=false,integer=true,
        min=1,max=1000000000,hardMin=1,hardMax=1000000000,applyButton=true,labelWidth=52,inputWidth=62,
        get=function()local p=Feature:GetProjection().plan or {};return p.targets and p.targets[1] and p.targets[1].count or 1 end,
        set=function(value)
            local p=Feature:GetProjection().plan or {};local target=p.targets and p.targets[1]
            if not target then return false,'先选择配方' end
            return Action('PlanSetQuantity',target.id,value)
        end,slot={size='fill',fill=1,minWidth=200}})
    RSUI:Button({id='v3_craft_sidecar_read_chain',parent=quantityRow,text='重读下级',compact=true,slot={size='fixed',width=76},onClick=function()return Action('PlanReadRecipes')end})

    local planRow = RSUI:HorizontalBox({ id = "v3_craft_sidecar_plan_row", parent = root, gap = 4,
        slot = { size = "fixed", height = 29, hAlign = "fill" } })
    local addPlan = RSUI:Button({ id = "v3_craft_sidecar_add_plan", parent = planRow, text = "接收新配方", compact = true,
        slot = { size = "fixed", width = 112 } })
    RSUI:Text({ id = "v3_craft_sidecar_plan_hint", parent = planRow, text = "每个分享单独保存；切换不累计", fontSize = 8, tone = "muted",
        overflow = "wrap", maxLines = 2, slot = { size = "fill", fill = 1 } })
    if addPlan ~= nil then addPlan.onClick = function()
        if type(Feature.Commands.PlanReceiveShare) ~= "function" then return false, "配方接收命令不可用" end
        local fn=Feature.Commands.RecipeReceive or Feature.Commands.PlanReceiveShare
        local ok, err = fn(Feature.Commands,1,nil,'widget:craft_sidecar')
        instance.status:SetText(ok and tostring(err or '等待下一条配方分享') or ("未接收：" .. tostring(err)))
        if type(instance.status.SetTone) == "function" then instance.status:SetTone(ok and "muted" or "warn") end
        return ok, err
    end end

    local treeActions=RSUI:HorizontalBox({id='v3_craft_sidecar_tree_actions',parent=root,gap=4,slot={size='fixed',height=27,hAlign='fill'}})
    RSUI:Button({id='v3_craft_sidecar_expand',parent=treeActions,text='展开/收起',compact=true,slot={size='fixed',width=84},onClick=function()
        local row=instance.selectedMaterial;if not row then instance.status:SetText('先选材料行');return false end
        instance.expanded[row.itemKey]=instance.expanded[row.itemKey]==false;return instance:Refresh()
    end})
    RSUI:Button({id='v3_craft_sidecar_receive_material',parent=treeActions,text='补子配方',compact=true,slot={size='fixed',width=80},onClick=function()
        local row=instance.selectedMaterial;if not row then instance.status:SetText('先选待补的材料');return false end
        return Action('RecipeReceiveMaterial',row.itemKey,'widget:craft_sidecar')
    end})
    RSUI:Button({id='v3_craft_sidecar_mark_base',parent=treeActions,text='确认为原料',compact=true,slot={size='fixed',width=88},onClick=function()
        local row=instance.selectedMaterial;if not row then instance.status:SetText('先选材料行');return false end
        return Action('PlanMarkBase',row.itemKey)
    end})

    -- WindowShell footer 占用 v3_craft_sidecar_status，业务反馈须用独立 ID，否则首次构建会被隔离。
    instance.status = RSUI:Text({ id = "v3_craft_sidecar_action_status", parent = root,
        text = "点接收后分享并发送配方；问号材料可选中后补子配方，或确认为原料。", fontSize = 8, tone = "muted", overflow = "wrap", maxLines = 2,
        slot = { size = "fixed", height = 30, hAlign = "fill" } })

    instance.table = RSUI:TableView({
        id = "v3_craft_sidecar_table", parent = root, items = {}, rowHeight = 27, headerHeight = 26,
        desiredRows = 10, overscan = 1, scrollbar = true, selectable = true, columnResize = false, headerInteractive = false,
        onSelectionChanged=function(index,_,view)
            instance.selectedMaterial=index and view:GetItem(index) or nil
            local row=instance.selectedMaterial
            if row then
                local p=Feature:GetProjection().plan or {};local reason=''
                for _,issue in ipairs(p.scanResult and p.scanResult.issues or {})do if issue.key==row.itemKey then reason='；'..issue.reason;break end end
                instance.status:SetText((row.item and row.item.name or row.name)..' · 需求 '..row.need..reason)
            end
        end,
        getKey = function(item) return item and item.key or nil end,
        columns = {
            { id = "name", title = "材料", field = "name", size = "fill", minWidth = 132, fill = 1.6 },
            { id = "need", title = "需", field = "need", size = "fixed", width = 44, minWidth = 36 },
            { id = "held", title = "有", field = "held", size = "fixed", width = 44, minWidth = 36 },
            { id = "shortage", title = "缺", field = "shortage", size = "fixed", width = 44, minWidth = 36 },
        },
        slot = { size = "fill", fill = 1, hAlign = "fill", vAlign = "fill" },
    })
    if root == nil or instance.recipe == nil or instance.addSaved == nil or instance.refresh == nil or instance.quote == nil
        or instance.search == nil or instance.nameInput == nil or instance.quantity == nil or instance.deleteButton == nil
        or addPlan == nil or instance.status == nil or instance.table == nil then
        return nil, "配方制作侧窗控件构建失败"
    end

    instance.refresh.onClick = function()
        local command=Feature.Commands.PlanRefreshInventory
        local ok,err
        if command then ok,err=command(Feature.Commands,false) else ok,err=Feature.Commands:Refresh('craft_sidecar_manual') end
        instance.status:SetText(ok == true and "已核对计划背包库存" or ("核对失败：" .. tostring(err or "未执行")))
        if ok == true then instance:Refresh() end
        return ok, err
    end
    instance.quote.onClick = function()
        local command=Feature.Commands.PlanCalibrate or Feature.Commands.QuotePendingMaterials
        if type(command) ~= "function" then return false, "材料询价命令不可用" end
        local ok, message = command(Feature.Commands)
        instance.status:SetText(ok == true and tostring(message or "询价已提交") or ("询价失败：" .. tostring(message or "未执行")))
        if ok == true then instance:Refresh() end
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
                self.planIdentity=identity;self.selectedMaterial=nil;self.expanded={};self.deleteArmed=nil
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
        for _,option in ipairs(plan and (plan.libraryEntries or plan.contextRecipeOptions) or projection.recipeOptions or {})do
            if self.searchText=='' or option.text:find(self.searchText,1,true) then self.recipe.items[#self.recipe.items+1]=option end
        end
        if type(self.recipe.Render) == "function" then self.recipe:Render() end
        local rows = MaterialRows(projection,self)
        self.table:SetItems(rows, "craft-sidecar:" .. tostring(projection.revision or 0))
        self.selectedMaterial=self.table:GetSelectedIndex() and self.table:GetItem(self.table:GetSelectedIndex()) or nil
        if #rows == 0 then self.table:SetViewState("empty", { title = "暂无制作目标", detail = "接收一次配方分享，或从上方打开已保存配方。" }) else self.table:SetViewState("ready") end
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
