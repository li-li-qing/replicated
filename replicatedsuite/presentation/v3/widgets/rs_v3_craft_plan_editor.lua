-- Replicated Suite · 制作计划编辑器
-- 表现层只消费 detached 投影；草稿、展开和选中归页面，不触发 Native 读取。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
local R=S.RSUI
S.UIV3=S.UIV3 or {}
local function Money(value)
    if S.Utils and type(S.Utils.FormatMoney)=='function' then return S.Utils.FormatMoney(math.floor(value+0.5)) end
    return tostring(math.floor(value+0.5))..'铜'
end
local function Quantity(value)
    if value>=100000000 then return string.format('%.1f亿',value/100000000) end
    if value>=10000 then return string.format('%.1f万',value/10000) end
    return tostring(value)
end
local ISSUE={cycle='配方循环',graph_limit='配方链超出上限',edge_limit='材料过多',invalid_target='目标数量无效',
    empty_plan='请加入制作目标',quantity_limit='数量超出上限',recipe_unknown='下级配方待核对',
    recipe_incomplete='配方不完整/未选配方',allocation_mismatch='混合数量与缺口不一致',
    invalid_allocation='来源数量无效',invalid_material='材料字段未知',inventory_unknown='库存未核对',money_limit='金额超出安全计算范围',
    labor_unknown='每次劳力待校准',fee_unknown='每次手续费待校准'}
local function Summary(r)
    if not r then return '尚未比较' end
    return (r.costComplete and '还需参考支出 ' or '已知支出（未完整） ')..Money(r.cashCopper)..
        (r.costComplete and ' · 消耗估值 ' or ' · 已知消耗估值 ')..Money(r.valueCopper)..' · 劳力 '..tostring(r.labor)..(r.laborComplete and '' or '＋未知')..
        (r.combinedCopper and (' · 含劳力折价 '..Money(r.combinedCopper)) or '')
end
function S.UIV3.CreateCraftPlanEditor(parent,feature)
    local E={projection={},selected=nil,view='tree',expanded={},comparison=nil,expandedCount=0}
    local C=feature.Commands
    local root=R:VerticalBox({id='craft_plan_editor',parent=parent,gap=5,slot={size='auto',hAlign='fill'}})
    if not root then return nil,'制作计划编辑器不可用' end
    local function Row(id,height,parentNode)
        return R:HorizontalBox({id='craft_plan_'..id,parent=parentNode or root,gap=5,slot={size='fixed',height=height or 32,hAlign='fill'}})
    end
    local function Text(id,parentNode,text,height,maxLines)
        return R:Text({id='craft_plan_'..id,parent=parentNode,text=text,fontSize=9,tone='muted',overflow='wrap',maxLines=maxLines or 3,nativeLineLimit=maxLines or 3,
            slot={size='fixed',height=height or 38,hAlign='fill'}})
    end
    local feedback=Text('feedback',root,'通用制作清单：加入任意可读取配方，展开多层材料；可分别安排购买或制作。',36)
    local function Run(name,...)
        local fn=C[name];if type(fn)~='function' then return false,'命令不可用' end
        local ok,message=fn(C,...)
        feedback:SetText(ok and (type(message)=='string' and message or '已更新计划') or ('未完成：'..tostring(message or '数据待核对')))
        if feedback.SetTone then feedback:SetTone(ok and 'muted' or 'warn') end
        E:Refresh(feature:GetProjection());return ok,message
    end
    local function Button(id,parentNode,label,width,click)
        local b=R:Button({id='craft_plan_'..id,parent=parentNode,text=label,compact=true,slot={size='fixed',width=width}})
        if b then b.onClick=click end;return b
    end
    local numberFields={}
    local function CancelNumberDraft(id)
        local field=numberFields[id]
        if field and field.input and type(field.input.CancelEditing)=='function' then
            field.input:CancelEditing('craft_plan_entity_changed')
        end
    end
    local function Number(id,parentNode,label,get,set,min,max)
        local field=R:NumericField({id='craft_plan_'..id,parent=parentNode,label=label,min=min or 0,max=max or 1000000000,
            hardMin=min or 0,hardMax=max or 1000000000,integer=true,step=1,slider=false,inline=false,
            applyButton=true,get=get,set=set,slot={size='fill',fill=1,minWidth=150}})
        numberFields[id]=field;return field
    end
    local function CommitFields(ids)
        for _,id in ipairs(ids)do
            local field=numberFields[id]
            if field and type(field.ApplyDraft)=='function' then
                local ok=field:ApplyDraft('craft_plan_composite_action')
                if ok~=true then feedback:SetText('请检查数值后再保存；未写入计划。');return false end
            end
        end
        return true
    end
    local manager=Row('manager')
    local planSelect=R:Dropdown({id='craft_plan_select',parent=manager,items={},placeholder='计划',
        get=function()return E.projection.activeId end,set=function(value)E.selected=nil;E.comparison=nil;return Run('PlanSelect',value)end,
        slot={size='fill',fill=1,minWidth=130}})
    local nameInput=R:TextInput({id='craft_plan_name',parent=manager,value='',placeholder='计划名称',maxLength=96,submitOnLostFocus=false,
        slot={size='fill',fill=1,minWidth=120}})
    local function Name()return nameInput:GetDraftValue()end
    Button('new',manager,'新建',46,function()return Run('PlanNew',Name()~='' and Name() or '新计划')end)
    Button('copy',manager,'复制',46,function()return Run('PlanCopy',Name()~='' and Name() or '计划副本')end)
    Button('rename',manager,'改名',46,function()return Run('PlanRename',Name())end)
    local deleteArmed=false
    local deleteButton
    deleteButton=Button('delete',manager,'删除',46,function()
        if not deleteArmed then deleteArmed=true;deleteButton:SetText('确认删');return true end
        deleteArmed=false;deleteButton:SetText('删除');E.selected=nil;return Run('PlanDelete')
    end)

    local add=Row('add',58)
    local addCount=1
    local fallbackOutput=0
    Number('add_count',add,'目标件数',function()return addCount end,function(value)addCount=value;return true end,1)
    Number('output_count',add,'每次产出（0=自动）',function()return fallbackOutput end,function(value)fallbackOutput=value;return true end,0)
    local quick=Row('quick_add',56)
    Button('receive_share',quick,'接收配方分享',112,function()
        if not CommitFields({'add_count','output_count'}) then return false end
        return Run(type(C.RecipeReceive)=='function' and 'RecipeReceive' or 'PlanReceiveShare',addCount,fallbackOutput>0 and fallbackOutput or nil,'page:tools_craft')
    end)
    Button('open_window',quick,'打开配方小窗',104,function()
        local controller=S.UIV3.CraftSidecar
        if not controller or type(controller.OpenManual)~='function' then feedback:SetText('配方小窗暂不可用');return false end
        local ok,why=controller:OpenManual();feedback:SetText(tostring(why or (ok and '已打开配方小窗' or '打开失败')));return ok,why
    end)
    R:Text({id='craft_plan_quick_hint',parent=quick,text='点接收后分享并发送；每份配方独立保存。小窗可切换、改名、改数量或删除。',
        fontSize=9,tone='muted',overflow='wrap',maxLines=3,slot={size='fill',fill=1}})
    local moreOpen=false
    local more,moreButton
    moreButton=Button('toggle_imports',quick,'更多导入',76,function()
        local nextOpen=not moreOpen
        local changed,accepted,why=more:SetVisibility(nextOpen and 'visible' or 'collapsed')
        if accepted~=true then return false,why end
        moreOpen=nextOpen
        moreButton:SetText(moreOpen and '收起导入' or '更多导入');return true
    end)
    more=R:VerticalBox({id='craft_plan_more_imports',parent=root,gap=5,slot={size='auto',hAlign='fill'}})
    more:SetVisibility('collapsed')
    Text('share_help',more,'备用：粘贴配方分享链接；或聊天输入 /rsrecipe 加空格，Shift 点击配方并发送。保持本页或制作侧栏打开。',44)
    local shareRow=Row('share_input',32,more)
    local shareInput=R:TextInput({id='craft_plan_share_text',parent=shareRow,value='',placeholder='粘贴配方分享链接',maxLength=2048,submitOnLostFocus=false,
        slot={size='fill',fill=1,minWidth=250}})
    Text('native_import_unavailable',more,'当前客户端不提供 O 页窗口对象，直接读取不可用；请接收分享或导入链接。',30)
    Button('import',shareRow,'导入配方',80,function()
        if not CommitFields({'add_count','output_count'}) then return false end
        return Run(type(C.RecipeImportLink)=='function' and 'RecipeImportLink' or 'PlanImportLink',shareInput:GetDraftValue(),addCount,fallbackOutput>0 and fallbackOutput or nil)
    end)
    local selectedCatalog,searchText=nil,''
    local searchRow=Row('search_row')
    local search=R:TextInput({id='craft_plan_search',parent=searchRow,value='',placeholder='查找本地已收录物品',maxLength=64,submitOnLostFocus=false,
        slot={size='fill',fill=1,minWidth=130}})
    Button('filter',searchRow,'筛选',46,function()searchText=tostring(search:GetDraftValue() or '');E:Refresh(feature:GetProjection());return true end)
    local catalogRow=Row('catalog')
    local catalogSelect=R:Dropdown({id='craft_plan_catalog_select',parent=catalogRow,items={},placeholder='已收录/已观察的物品（非全游戏目录）',
        get=function()return selectedCatalog end,set=function(value)selectedCatalog=value;return true end,
        slot={size='fill',fill=1,minWidth=250}})
    Button('add_known',catalogRow,'加入计划',76,function()
        if not CommitFields({'add_count'}) then return false end
        for _,option in ipairs(E.projection.catalog or {})do if option.value==selectedCatalog then return Run('PlanAddTarget',option.item,addCount)end end
        return Run('PlanAddTarget',{},addCount)
    end)
    local commands=Row('commands')
    Button('read',commands,'读取配方链',88,function()return Run('PlanReadRecipes')end)
    Button('bag',commands,'核对背包',76,function()return Run('PlanRefreshInventory',false)end)
    Button('bank',commands,'背包＋银行',88,function()return Run('PlanRefreshInventory',true)end)
    Button('quote',commands,'校准价格',76,function()return Run('PlanCalibrate')end)
    Button('cancel',commands,'取消查询',76,function()return Run('PlanCancel')end)
    Button('compare',commands,'比较路线',76,function()
        local ok,value=C:PlanCompare()
        if ok then E.comparison=value;E:Refresh(feature:GetProjection()) else feedback:SetText(tostring(value))end
        return ok
    end)
    local summary=Text('summary',root,'',42)
    local stateText=Text('state',root,'',34)
    -- 容器与下拉框的逻辑 ID 必须独立，严格 PageHost 会隔离重复 ID 的整页构建。
    local viewRow=Row('view_row')
    local selectedItem
    R:Dropdown({id='craft_plan_view',parent=viewRow,
        items={{value='targets',text='目标'},{value='tree',text='材料层级'},{value='purchases',text='采购汇总'},{value='steps',text='制作步骤'}},
        get=function()return E.view end,set=function(value)E.view=value;E.selected=nil;selectedItem=nil;E:Refresh(feature:GetProjection());return true end,
        slot={size='fixed',width=128}})
    Button('expand',viewRow,'展开/收起',88,function()
        if selectedItem then E.expanded[selectedItem.key]=not E.expanded[selectedItem.key] end
        E:Refresh(feature:GetProjection());return true
    end)
    Button('search_auction',viewRow,'拍卖搜索',76,function()return Run('PlanSearch',selectedItem and selectedItem.key)end)
    Button('quote_one',viewRow,'校准此项',76,function()
        if not selectedItem then feedback:SetText('请先选择物品');return false end
        return Run('PlanCalibrate',selectedItem.key)
    end)
    Button('remove',viewRow,'移除目标',76,function()
        if not selectedItem or not selectedItem.targetId then feedback:SetText('在目标列表中选择要移除的目标');return false end
        return Run('PlanRemoveTarget',selectedItem.targetId)
    end)
    local tableView=R:TableView({id='craft_plan_table',parent=root,items={},rowHeight=28,headerHeight=27,desiredRows=7,
        scrollbar=true,selectable=true,selectionMode='single',columnResize=true,
        getKey=function(row)return row and row.uiKey end,
        onSelectionChanged=function(index,_,view)
            selectedItem=index and view:GetItem(index) or nil;E.selected=selectedItem and selectedItem.uiKey or nil
            if E.SyncSelection then E:SyncSelection() end
        end,
        columns={
            {id='name',title='物品 / 材料',field='name',size='fill',fill=2,minWidth=130},
            {id='need',title='需求',field='needText',size='fixed',width=58,minWidth=50},
            {id='owned',title='已有',field='ownedText',size='fixed',width=58,minWidth=50},
            {id='shortage',title='缺口',field='shortageText',size='fixed',width=58,minWidth=50,
                getTone=function(row)return row and row.tone or 'muted'end},
            {id='source',title='安排',field='source',size='fixed',width=105,minWidth=84},
            {id='price',title='参考单价',field='priceText',size='fill',fill=1,minWidth=120},
        },slot={size='fixed',height=247,hAlign='fill'}})
    local detail=Text('detail',root,'选择一行调整数量/来源；“材料层级”中用展开按钮查看下级。',56)
    local edit=Row('edit',58)
    Number('target_quantity',edit,'目标总量',function()
        if selectedItem and selectedItem.targetId then
            for _,row in ipairs(E.projection.targets or {})do if row.id==selectedItem.targetId then return row.count end end
        end
        return 1
    end,function(value)
        if not selectedItem or not selectedItem.targetId then return false,'先在目标列表选择目标' end
        return Run('PlanSetQuantity',selectedItem.targetId,value)
    end,1)
    local source=R:Dropdown({id='craft_plan_source',parent=edit,items={{value='buy',text='购买全部缺口'},{value='craft',text='制作全部缺口'},{value='mixed',text='混合买做'}},
        get=function()
            local a=selectedItem and (E.projection.allocations or {})[selectedItem.key]
            return a and a.mode or (selectedItem and E.projection.choices[selectedItem.key] and 'craft' or 'buy')
        end,set=function(mode)
            if not selectedItem then return false,'先选择物品' end
            return Run('PlanSetAllocation',selectedItem.key,mode,0,0)
        end,slot={size='fixed',width=150}})
    local mixedRow=Row('mixed',58)
    local mixedBuy,mixedCraft=0,0
    Number('mixed_buy',mixedRow,'买入数量',function()return mixedBuy end,function(v)mixedBuy=v;return true end)
    Number('mixed_craft',mixedRow,'制作数量',function()return mixedCraft end,function(v)mixedCraft=v;return true end)
    Button('apply_mixed',mixedRow,'保存混合',76,function()
        if not selectedItem then return false,'先选择物品' end
        if not CommitFields({'mixed_buy','mixed_craft'}) then return false end
        return Run('PlanSetAllocation',selectedItem.key,'mixed',mixedBuy,mixedCraft)
    end)
    local recipeRow=Row('recipe',58)
    local recipeSelect=R:Dropdown({id='craft_plan_recipe_select',parent=recipeRow,items={},placeholder='配方选项',
        get=function()return selectedItem and E.projection.choices[selectedItem.key] end,
        set=function(value)if not selectedItem then return false end;return Run('PlanChooseRecipe',selectedItem.key,value)end,
        slot={size='fixed',width=140}})
    local recipeLabor,recipeFee=0,0
    Number('recipe_labor',recipeRow,'劳力/次（人工）',function()return recipeLabor end,function(v)recipeLabor=v;return true end)
    Number('recipe_fee',recipeRow,'手续费铜/次',function()return recipeFee end,function(v)recipeFee=v;return true end)
    Button('save_costs',recipeRow,'保存成本',76,function()
        if not selectedItem then return false,'先选择物品' end
        if not CommitFields({'recipe_labor','recipe_fee'}) then return false end
        return Run('PlanSetRecipeCosts',selectedItem.key,recipeLabor,recipeFee)
    end)
    local laborRow=Row('labor',58)
    Number('labor_value',laborRow,'劳力折价（铜/点）',function()return E.projection.laborValueCopper or 0 end,
        function(value)return Run('PlanSetLaborValue',value)end)
    Button('no_labor_value',laborRow,'关闭折价',76,function()return Run('PlanSetLaborValue',nil)end)
    local availableLabor
    Number('available_labor',laborRow,'当前劳力（手填）',function()return availableLabor or 0 end,
        function(value)availableLabor=value;E:Refresh(feature:GetProjection());return true end)
    local laborStatus=Text('labor_status',root,'当前劳力未知',24)
    local comparisonStatus=Text('comparison_status',root,'“比较路线”使用独立库存账本，生成建议后仍由你决定是否采纳。',30)
    local comparisonLabels={}
    for _,key in ipairs({'manual','raw','buy','candidate'})do
        comparisonLabels[key]=Text('comparison_'..key,root,'尚未比较',46)
    end
    local recommendations=Row('recommendations')
    Button('apply_all',recommendations,'采纳整套建议',100,function()
        return Run('PlanApplyRecommendation',E.comparison and E.comparison.revision or -1)
    end)
    Button('apply_one',recommendations,'采纳此项建议',100,function()
        if not selectedItem then return false,'先选择物品' end
        return Run('PlanApplyRecommendation',E.comparison and E.comparison.revision or -1,selectedItem.key)
    end)
    Button('undo',recommendations,'撤销采纳',76,function()return Run('PlanUndo')end)
    Button('mark_base',recommendations,'确认为原料',88,function()
        if not selectedItem then return false,'先选择物品' end
        return Run('PlanMarkBase',selectedItem.key)
    end)
    Text('coverage',root,'数量表示准备好的总件数。库存移动后重读；银行打开后核对。产量、劳力与手续费未读到时需对照制作界面校准；保管箱和买齐预算仍待验证。',40)
    function E:SyncSelection(preserveDrafts)
        local item=selectedItem
        local p=self.projection
        local identity=tostring(p.sessionRevision)..':'..tostring(p.activeId)..':'..tostring(item and item.uiKey)..':'..
            tostring(item and item.key)..':'..tostring(item and p.choices[item.key])
        if identity~=self.selectionIdentity then
            self.selectionIdentity=identity;preserveDrafts=false
            for _,id in ipairs({'target_quantity','mixed_buy','mixed_craft','recipe_labor','recipe_fee'})do CancelNumberDraft(id)end
        end
        if not item then detail:SetText('选择一行调整；买入部分不再展开下级。');return end
        local a=(p.allocations or {})[item.key] or {}
        if not preserveDrafts then mixedBuy,mixedCraft=a.buy or 0,a.craft or 0 end
        local chosen=p.choices[item.key]
        local recipe=p.recipes[chosen or '']
        if not preserveDrafts then recipeLabor,recipeFee=recipe and recipe.labor or 0,recipe and recipe.feeCopper or 0 end
        recipeSelect.items={}
        for _,id in ipairs((p.recipeCatalog[item.key] or {}).recipeIds or {})do
            local r=p.recipes[id]
            recipeSelect.items[#recipeSelect.items+1]={value=id,text='配方 '..id..' · 产出 '..tostring(r and r.product.count or '?')}
        end
        recipeSelect:Render();source:Render()
        for _,id in ipairs({'target_quantity','mixed_buy','mixed_craft','recipe_labor','recipe_fee'})do
            if numberFields[id] then numberFields[id]:Render() end
        end
        local amounts=item.amounts or {}
        detail:SetText(item.name..' · 需求 '..tostring(amounts.demand)..'，已有 '..tostring(amounts.owned)..
            '，缺口 '..tostring(amounts.shortage)..'，购买 '..tostring(amounts.buy)..'，制作 '..tostring(amounts.craft)..
            '，批次 '..tostring(amounts.batches)..'，余料 '..tostring(amounts.surplus)..
            ((amounts.fromBank or 0)>0 and ('，银行需取出 '..amounts.fromBank) or '')..'；'..(recipe and
            ('每次产出 '..recipe.product.count..'，劳力 '..tostring(recipe.labor or '待核')..'，手续费 '..tostring(recipe.feeCopper or '待核')..' 铜') or '尚未选择可确认配方'))
    end
    local function Display(row,path,depth,targetId)
        local item=row.item or {}
        local priceMeta=row.priceMeta or {}
        local age=priceMeta.ageMinutes and (' · '..priceMeta.ageMinutes..'分钟前') or ''
        return {uiKey=path,key=row.key,targetId=targetId,item=item,amounts=row,
            name=string.rep('  ',math.min(12,depth or 0))..(E.expanded[row.key] and '▾ ' or '▸ ')..(item.name or ('物品 '..tostring(item.itemType))),
            needText=Quantity(row.demand),ownedText=Quantity(row.owned),shortageText=Quantity(row.shortage),
            source=E.view=='steps' and (Quantity(row.batches)..'次，余'..Quantity(row.surplus)) or ('买'..Quantity(row.buy)..' / 做'..Quantity(row.craft)),
            priceText=row.price and (Money(row.price)..(priceMeta.candidatePrice and ' · 新价待复核' or priceMeta.freshness=='fresh' and '' or ' · 旧参考/待核')..age) or '待报价',
            tone=not E.projection.inventoryComplete and 'warn' or row.shortage==0 and 'success' or 'danger'}
    end
    function E:Refresh(projection)
        local p=projection.plan or {}
        local planIdentity=tostring(p.sessionRevision)..':'..tostring(p.activeId)
        if planIdentity~=self.planIdentity then
            self.planIdentity=planIdentity
            CancelNumberDraft('labor_value');CancelNumberDraft('available_labor');availableLabor=nil
        end
        self.projection=p
        if p.error then feedback:SetText('计划存档已保护：'..p.error);return end
        planSelect.items=p.plans or {};planSelect:Render()
        catalogSelect.items={}
        for _,option in ipairs(p.catalog or {})do
            if searchText=='' or option.text:find(searchText,1,true) then catalogSelect.items[#catalogSelect.items+1]=option end
        end
        catalogSelect:Render()
        if numberFields.labor_value then numberFields.labor_value:Render() end
        local receipt=p.importFeedback
        local receiptId=receipt and (tostring(p.sessionRevision)..':'..tostring(receipt.id))
        if receipt and receiptId~=self.lastImportFeedback then
            self.lastImportFeedback=receiptId
            feedback:SetText(receipt.message or '')
            if feedback.SetTone then feedback:SetTone(receipt.ok and 'muted' or 'warn') end
        end
        local r=p.evaluation or {rows={},byKey={},issues={},purchases={},steps={},cashCopper=0,valueCopper=0,labor=0}
        summary:SetText(Summary(r))
        local issues,seen={},{ }
        for _,issue in ipairs(r.issues or {})do
            local text=ISSUE[issue.code] or issue.code
            if not seen[text] and #issues<4 then issues[#issues+1]=text;seen[text]=true end
        end
        local progress=p.scan and (' · 配方读取 '..p.scan.done..'，待查 '..p.scan.pending) or ''
        if not p.scan and p.scanResult then
            progress=progress..(p.scanResult.status=='complete' and ' · 材料链读取结束' or ' · 下级仍有待核对')
        end
        if p.quote then progress=progress..' · 校准 '..p.quote.completed..'/'..p.quote.requested end
        stateText:SetText(tostring(p.inventoryNote or '库存未核对')..progress..(#issues>0 and (' · '..table.concat(issues,'；')) or ''))
        local rows={}
        if self.view=='targets' then
            for _,target in ipairs(p.targets or {})do
                local row=r.byKey and r.byKey[target.key]
                if row then rows[#rows+1]=Display(row,'target:'..target.id,0,target.id)end
            end
        elseif self.view=='tree' then
            local function Walk(key,path,depth,visited,targetId)
                if #rows>=512 or depth>24 then return end
                local row=r.byKey and r.byKey[key];if not row then return end
                rows[#rows+1]=Display(row,path,depth,targetId)
                if visited[key] or not self.expanded[key] or row.craft<=0 then return end
                visited[key]=true
                local recipe=p.recipes[p.choices[key] or '']
                for index,item in ipairs(recipe and recipe.materials or {})do
                    local grade=item.grade==nil and '*' or item.grade
                    Walk(item.itemType..':'..grade..':'..tostring(item.variant or '*'),path..':'..index,depth+1,visited)
                end
                visited[key]=nil
            end
            for _,target in ipairs(p.targets or {})do
                if self.expanded[target.key]==nil then self.expanded[target.key]=true end
                Walk(target.key,'tree:'..target.id,0,{},target.id)
            end
        else
            for _,row in ipairs(self.view=='steps' and r.steps or r.purchases)do rows[#rows+1]=Display(row,self.view..':'..row.key,0)end
        end
        tableView:SetItems(rows,'plan:'..tostring(p.revision)..':'..self.view)
        tableView:SetViewState(#rows>0 and 'ready' or 'empty',{title='暂无制作目标',detail='接收一次配方分享，或从已收录物品中添加。'})
        local found
        for _,row in ipairs(rows)do if row.uiKey==self.selected then selectedItem=row;found=true;break end end
        if not found then selectedItem=nil;self.selected=nil end
        self:SyncSelection(true)
        if availableLabor~=nil and r.laborComplete then
            laborStatus:SetText('当前手填劳力 '..availableLabor..' / 需要 '..r.labor..' · '..(availableLabor>=r.labor and '足够' or ('不足 '..(r.labor-availableLabor))))
            if laborStatus.SetTone then laborStatus:SetTone(availableLabor>=r.labor and 'success' or 'danger')end
        else laborStatus:SetText('当前劳力或配方有效消耗未知；每次成本须经制作界面核对。')end
        if self.comparison then
            local cmp=self.comparison.result
            comparisonStatus:SetText(self.comparison.revision~=p.revision and '旧比较已失效，请重新比较。' or '有界候选比较，不代表全局最优；采纳前不会改动手动方案。')
            comparisonLabels.manual:SetText('手动：'..Summary(cmp.manual))
            comparisonLabels.raw:SetText('原料：'..Summary(cmp.raw))
            comparisonLabels.buy:SetText('成品：'..Summary(cmp.buy))
            comparisonLabels.candidate:SetText('候选建议：'..Summary(cmp.recommendation.evaluation))
        end
        return true
    end
    E.root=root
    return E
end

-- 工具页保留低频设置，日常材料操作由配方小窗承担。
function S.UIV3.CreateCraftAdvancedSettings(parent,feature)
    local root=R:VerticalBox({id='craft_advanced_settings',parent=parent,gap=5,slot={size='auto',hAlign='fill'}})
    if not root then return nil,'制作高级设置不可用' end
    local info=R:Text({id='craft_advanced_info',parent=root,text='配方、材料、拍卖搜索与成本比较在悬浮小窗操作。此处设置劳力折价；关闭后只分别显示金币和劳力。',
        fontSize=9,tone='muted',overflow='wrap',maxLines=3,slot={size='fixed',height=42,hAlign='fill'}})
    local row=R:HorizontalBox({id='craft_advanced_labor_row',parent=root,gap=5,slot={size='fixed',height=48,hAlign='fill'}})
    local labor=R:NumericField({id='craft_advanced_labor_value',parent=row,label='劳力折价（铜/点）',
        min=0,max=1000000000,hardMin=0,hardMax=1000000000,integer=true,slider=false,inline=true,applyButton=true,
        get=function()local p=(feature:GetProjection() or {}).plan or {};return p.laborValueCopper or 0 end,
        set=function(value)return feature.Commands:PlanSetLaborValue(value)end,
        slot={size='fill',fill=1,minWidth=220}})
    local clear=R:Button({id='craft_advanced_clear_labor',parent=row,text='关闭折价',compact=true,
        slot={size='fixed',width=76},onClick=function()return feature.Commands:PlanSetLaborValue(nil)end})
    local open=R:Button({id='craft_advanced_open_window',parent=row,text='打开小窗',compact=true,
        slot={size='fixed',width=80},onClick=function()
            local controller=S.UIV3 and S.UIV3.CraftSidecar
            if not controller or type(controller.OpenManual)~='function' then return false,'配方小窗暂不可用' end
            return controller:OpenManual()
        end})
    if not info or not row or not labor or not clear or not open then return nil,'制作高级设置控件创建失败' end
    return {root=root,Refresh=function()labor:Render();return true end}
end
