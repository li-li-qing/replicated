------------------------------------------------------------------------
-- Replicated Suite · 寻宝共用紧凑控件；只分派 Feature Commands。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
local R=S.RSUI
if not R then return end
S.UIV3=S.UIV3 or {}
local M={version=1}
S.UIV3.TreasureControlsV3=M
local KINDS={{value="maps",text="藏宝图"},{value="seabugs",text="海虫"},{value="ships",text="沉船"}}
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
        local sea=p.viewKind=="seabugs" or p.viewKind=="ships"
        self.kind:Render()
        if self.lastKind~=p.viewKind then self.region:SetItems(p.regionItems or {});self.lastKind=p.viewKind end
        self.region:Render();self.region:SetEnabled(sea)
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
        return true
    end
    c:Refresh(c.projection)
    return c
end
