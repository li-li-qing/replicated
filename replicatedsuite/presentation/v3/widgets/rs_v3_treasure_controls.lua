-- Replicated Suite · 寻宝共用紧凑控件；只分派 Feature Commands。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
local R=S.RSUI
if not R then return end
S.UIV3=S.UIV3 or {}
local M={version=1}
S.UIV3.TreasureControlsV3=M
local KINDS={{value="maps",text="藏宝图"},{value="seabugs",text="海虫"},{value="ships",text="沉船"}}
-- 两个表面复用表单；输入草稿属于各自 UI，当前追踪目标只由 Feature 拥有。
function M:BuildCustomPoint(parent,F,prefix,options)
    if type(F.Commands.TrackCustomPoint)~="function" then return nil end
    options=options or {}
    local c={draft={longitude="E1",latitude="N1",lonMinutes="0",lonSeconds="0",latMinutes="0",latSeconds="0"}}
    c.root=R:VerticalBox({id=prefix.."custom",parent=parent,gap=3,slot={size=options.hideToggle and "fill" or "auto",fill=1,hAlign="fill",vAlign="fill"}})
    c.toggle=R:Button({id=prefix.."custom_toggle",parent=c.root,text="自定义点 ▸",compact=true,
        slot={size="fixed",height=24,hAlign="fill"}})
    local formSpec={id=prefix.."custom_form",parent=c.root,gap=3,visible=false,scrollStep=1,
        slot={size=options.hideToggle and "fill" or "auto",fill=1,hAlign="fill",vAlign="fill"}}
    -- 悬浮窗可保存为很矮的尺寸；编辑时独占内容区，仍允许滚动到按钮，不强行改用户窗口大小。
    if options.hideToggle then c.form=R:ScrollBox(formSpec)else c.form=R:VerticalBox(formSpec)end
    local function Axis(key,positive,negative,maximum,minuteKey,secondKey)
        local items={}
        -- 正反方向按度数成对排列，常用 E1/W1 等均在列表前部；不创建几百个常驻选项控件。
        for degree=0,maximum do for _,dir in ipairs({positive,negative})do
            items[#items+1]={value=dir..degree,text=dir..degree.."°"}
        end end
        local row=R:HorizontalBox({id=prefix..key.."_row",parent=c.form,gap=2,slot={size="fixed",height=24,hAlign="fill"}})
        c[key]=R:Dropdown({id=prefix..key,parent=row,items=items,maxVisible=8,popupWidth=120,compact=true,fontSize=9,
            get=function()return c.draft[key]end,set=function(value)c.draft[key]=value;return true end,
            slot={size="fixed",width=60}})
        for _,field in ipairs({{minuteKey,"分"},{secondKey,"秒"}})do
            local name,unit=field[1],field[2]
            c[name]=R:TextInput({id=prefix..name,parent=row,value="0",maxLength=16,placeholder=unit,
                get=function()return c.draft[name]end,set=function(value)c.draft[name]=value;return true end,
                slot={size="fill",fill=1,minWidth=56}})
            R:Text({id=prefix..name.."_unit",parent=row,text=unit,fontSize=8,slot={size="fixed",width=8}})
        end
    end
    Axis("longitude","E","W",180,"lonMinutes","lonSeconds")
    Axis("latitude","N","S",90,"latMinutes","latSeconds")
    local actions=R:HorizontalBox({id=prefix.."custom_actions",parent=c.form,gap=3,slot={size="fixed",height=24,hAlign="fill"}})
    c.track=R:Button({id=prefix.."custom_track",parent=actions,text="追踪坐标",compact=true,slot={size="fill",fill=1,minWidth=68}})
    c.stop=R:Button({id=prefix.."custom_stop",parent=actions,text="停止追踪",compact=true,slot={size="fixed",width=76}})
    if options.hideToggle then
        c.back=R:Button({id=prefix.."custom_back",parent=actions,text="返回",compact=true,slot={size="fixed",width=46},
            onClick=function()return c:SetExpanded(false)end})
    end
    c.hint=R:Text({id=prefix.."custom_hint",parent=c.form,text="分、秒可填小数；空秒按0",fontSize=9,tone="muted",overflow="ellipsis",
        slot={size="fixed",height=18,hAlign="fill"}})
    function c:ClosePopups()
        for _,control in ipairs({self.longitude,self.latitude})do if control.open then control:Close()end end
    end
    if options.hideToggle then
        local setScrollOffset=c.form.SetScrollOffset
        function c.form:SetScrollOffset(offset,relayout)
            -- 下拉弹层是独立窗口，不随滚动裁剪；滚轮和滚动条都在此收起它。
            c:ClosePopups()
            return setScrollOffset(self,offset,relayout)
        end
    end
    function c:SetExpanded(expanded)
        self.expanded=expanded==true
        if not c.expanded then c:ClosePopups()end
        c.form:SetVisible(c.expanded);c.toggle:SetText(c.expanded and "自定义点 ▾" or "自定义点 ▸")
        if options.hideToggle then c.root:SetVisible(c.expanded)end
        c.root:InvalidateMeasure("custom_point_toggle")
        if options.onExpanded then options.onExpanded(c.expanded)end
        return true
    end
    c.toggle.onClick=function()return c:SetExpanded(not c.expanded)end
    if options.hideToggle then c.toggle:SetVisible(false);c.root:SetVisible(false)end
    local function Result(ok,why)
        c.actionError=ok~=true and tostring(why or "操作未完成") or nil
        c.hint:SetText(c.actionError or "分、秒可填小数；空秒按0")
        if options.onResult then options.onResult(ok,why)end
        return ok,why
    end
    c.track.onClick=function()
        -- 按钮先于 LostFocus 时仍读可见输入，避免追踪上一次提交的分/秒。
        local ok,why=F.Commands:TrackCustomPoint(c.draft.longitude,c.lonMinutes:GetActionValue(),c.lonSeconds:GetActionValue(),
            c.draft.latitude,c.latMinutes:GetActionValue(),c.latSeconds:GetActionValue())
        if ok==true and options.hideToggle then c:SetExpanded(false)end
        return Result(ok,why)
    end
    c.stop.onClick=function()return Result(F.Commands:StopTracking())end
    function c:Refresh(p)
        self.track:SetEnabled(F.enabled==true and not (p.withdraw and p.withdraw.status=="running"))
        self.stop:SetEnabled(F.enabled==true and p.selected~=nil)
        -- 不 Render 编辑框，500ms 位置通知不能覆盖用户输入中的坐标。
        return true
    end
    c.form:SetVisible(false);c:Refresh(F:GetProjection() or {})
    return c
end
function M:Build(parent,F,prefix,options)
    options=options or {}
    local c={projection=F:GetProjection() or {}}
    local function Run(name,...)
        local ok,err=F.Commands[name](F.Commands,...)
        if options.onResult then options.onResult(ok,err) end
        return ok,err
    end
    local row=R:HorizontalBox({id=prefix.."filters",parent=parent,gap=4,slot={size="fixed",height=26,hAlign="fill"}})
    c.kind=R:SegmentedSelector({id=prefix.."kind",parent=row,items=KINDS,itemWidth=54,height=26,gap=2,
        get=function()return c.projection.viewKind or "maps" end,set=function(value)return Run("SetViewKind",value)end,
        slot={size="fixed",width=166}})
    c.region=R:Dropdown({id=prefix.."region",parent=row,items=c.projection.regionItems or {},maxVisible=9,popupWidth=210,
        get=function()return c.projection.region or "all" end,set=function(value)return Run("SetRegion",value)end,
        slot={size="fill",fill=1,minWidth=100}})
    c.nearest=R:Button({id=prefix.."nearest",parent=row,text="追踪最近",compact=true,slot={size="fixed",width=76}})
    c.nearest.onClick=function()return Run("TrackNearest")end
    if options.mapButton~=false then
        c.map=R:Button({id=prefix.."map",parent=row,text="地图定位",compact=true,slot={size="fixed",width=76}})
        c.map.onClick=function()return Run("ShowSelectedOnMap")end
    end
    if options.onSettings then
        c.settings=R:Button({id=prefix.."settings",parent=row,text="设置",compact=true,slot={size="fixed",width=76}})
        c.settings.onClick=options.onSettings
    end
    c.custom=self:BuildCustomPoint(parent,F,prefix,{onResult=options.onResult})
    if F.Inventory then
        -- 完整页与悬浮窗分派同一个逐箱识别命令；记录号来自Feature，不让UI预设/选择物理箱身份。
        c.takeLimit=2
        c.storage=R:VerticalBox({id=prefix.."storage",parent=parent,gap=3,slot={size="auto",hAlign="fill"}})
        local boxes=R:HorizontalBox({id=prefix.."boxes",parent=c.storage,gap=4,slot={size="fixed",height=26,hAlign="fill"}})
        c.register=R:Button({id=prefix.."register",parent=boxes,text="识别当前保管箱",compact=true,slot={size="fixed",width=136}})
        c.register.onClick=function()return Run("IdentifyCurrentCoffer")end
        c.clear=R:Button({id=prefix.."clear_coffers",parent=boxes,text="重新统计",compact=true,slot={size="fixed",width=88}})
        c.clear.onClick=function()return Run("ResetCofferRound")end
        c.sort=R:Dropdown({id=prefix.."sort",parent=boxes,items={{value="count",text="数量从多到少"},{value="coordinate",text="按坐标排序"}},popupWidth=180,
            get=function()return c.projection.sortMode or "count" end,set=function(value)return Run("SetInventorySort",value)end,
            slot={size="fill",fill=1,minWidth=100}})
        local actions=R:HorizontalBox({id=prefix.."inventory_actions",parent=c.storage,gap=4,slot={size="fixed",height=26,hAlign="fill"}})
        c.quantity=R:Dropdown({id=prefix.."take_quantity",parent=actions,items={{value=1,text="最多1张"},{value=2,text="最多2张"},{value=0,text="本箱该点全部"}},popupWidth=180,
            get=function()return c.takeLimit end,set=function(value)c.takeLimit=tonumber(value);return true end,
            slot={size="fixed",width=112}})
        c.take=R:Button({id=prefix.."take",parent=actions,text="取本箱同坐标",compact=true,slot={size="fixed",width=112}})
        c.take.onClick=function()local selected=c.projection.selected
            return Run("WithdrawCoordinate",c.boxId,selected and selected.groupKey,c.takeLimit)end
        c.cancel=R:Button({id=prefix.."cancel_take",parent=actions,text="停止取图",compact=true,slot={size="fixed",width=76}})
        c.cancel.onClick=function()return Run("CancelWithdrawal")end
        local classes={{value="auto",text="恢复自动分类"},{value="auroria",text="归为原大陆"},{value="west",text="归为西大陆"},
            {value="east",text="归为东大陆"},{value="sea",text="归为海上"},{value="unknown",text="归为未分类"}}
        c.assign=R:Dropdown({id=prefix.."assign_continent",parent=actions,items=classes,placeholder="给选中坐标分类",popupWidth=180,
            get=function()return "__assign__" end,set=function(value)
                local selected=c.projection.selected;return Run("SetCoordinateContinent",selected and selected.groupKey,value)end,
            onChanged=function(_,_,control)control:Render()end,slot={size="fill",fill=1,minWidth=110}})
        c.inventoryHint=R:Text({id=prefix.."inventory_hint",parent=c.storage,text="",fontSize=9,tone="muted",overflow="ellipsis",
            slot={size="fixed",height=20,hAlign="fill"}})
    end
    c.round=R:HorizontalBox({id=prefix.."round",parent=parent,gap=4,slot={size="fixed",height=26,hAlign="fill"}})
    local function Button(key,text,width,fn)
        local b=R:Button({id=prefix..key,parent=c.round,text=text,compact=true,slot={size="fixed",width=width}});b.onClick=fn;return b
    end
    c.searched=Button("searched","已搜查 → 下一处",120,function()return Run("VisitAndNext","searched")end)
    c.skip=Button("skip","跳过",48,function()return Run("VisitAndNext","skipped")end)
    c.undo=Button("undo","撤销",48,function()return Run("UndoVisit")end)
    c.reset=Button("reset","新一轮",60,function()return Run("ResetRound")end)
    c.stop=Button("stop","停止追踪",76,function()return Run("StopTracking")end)
    c.hint=R:Text({id=prefix.."round_hint",parent=c.round,text="静态资料点，不代表当前存在",fontSize=9,tone="muted",overflow="ellipsis",slot={size="fill",fill=1,minWidth=60}})
    function c:Refresh(p)
        self.projection=p
        if self.custom then self.custom:Refresh(p)end
        local sea=p.viewKind=="seabugs" or p.viewKind=="ships"
        self.kind:Render()
        if self.lastKind~=p.viewKind then self.region:SetItems(p.regionItems or {});self.lastKind=p.viewKind end
        self.region:Render();self.region:SetEnabled(sea or p.inventoryContractVersion~=nil)
        self.nearest:SetEnabled(sea and F.enabled==true)
        self.round:SetVisible(sea)
        local selected=p.selected
        if self.map then self.map:SetEnabled(selected~=nil and F.enabled==true) end
        local same=selected and selected.kind==p.viewKind and (p.region=="all" or selected.region==p.region)
        self.searched:SetEnabled(same==true);self.skip:SetEnabled(same==true)
        self.undo:SetEnabled(p.canUndoVisit==true)
        self.stop:SetEnabled(selected~=nil)
        self.hint:SetText("本轮 已搜 "..tostring(p.roundSearched or 0).."/"..tostring(p.roundTotal or 0).." · 待搜 "..tostring(p.roundRemaining or 0)
            ..((p.roundSkipped or 0)>0 and (" · 跳过 "..tostring(p.roundSkipped)) or ""))
        if self.storage then
            self.storage:SetVisible(not sea)
            local running=p.withdraw and p.withdraw.status=="running"
            self.boxId=p.boundCofferId -- 取图只允许刚识别的当前箱，不能从旧统计记录任意切换操作对象。
            self.sort:Render();self.quantity:Render();self.assign:Render()
            self.register:SetEnabled(F.enabled==true and not running)
            self.clear:SetEnabled(F.enabled==true and not running)
            self.assign:SetEnabled(selected~=nil and selected.groupKey~=nil)
            self.take:SetEnabled(F.enabled==true and not running and not p.inventoryUncertain and p.boundCofferId==self.boxId
                and selected~=nil and selected.boxes~=nil and (selected.boxes[self.boxId] or 0)>0)
            self.cancel:SetEnabled(running==true)
            local hint=p.inventoryHint or ""
            if running then hint="正在从箱"..tostring(p.withdraw.boxId).."取图：已确认 "..tostring(p.withdraw.moved).."/"..tostring(p.withdraw.limit)
            elseif p.withdraw and p.withdraw.status=="done" then hint="本次已取出 "..tostring(p.withdraw.moved).." 张 · "..hint
            elseif p.withdraw and p.withdraw.error then hint="取图停止："..p.withdraw.error end
            if p.boundCofferId then hint="当前识别记录 "..p.boundCofferId.." · "..hint end
            self.inventoryHint:SetText(hint)
        end
        return true
    end
    c:Refresh(c.projection)
    return c
end
