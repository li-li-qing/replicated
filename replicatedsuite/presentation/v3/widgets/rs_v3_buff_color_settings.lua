------------------------------------------------------------------------
-- Replicated Suite · 状态显示配色编辑
-- 作者：Replicated
-- QQ群：1104129461
-- 直接嵌入HUD校准；调色只提交调用方草稿，不持有第二份业务配置。
------------------------------------------------------------------------
if not ReplicatedSuite or ReplicatedSuite.BootError then return end
local S=ReplicatedSuite
local R,F=S.RSUI,S.Features and S.Features.BuffDisplay
if not R or not F then return end
S.UIV3=S.UIV3 or {};local B={};S.UIV3.BuffColorSettings=B
local function Copy(v)if type(v)~='table'then return v end;local out={};for k,x in pairs(v)do out[k]=Copy(x)end;return out end
local EXAMPLES={alias='自定义名字',classText='职业预览',gearScore='12345',distance='28.4m',castName='施法预览',
    buffTime='12秒',buffStacks='3层',debuffTime='5秒',debuffStacks='2层',cooldownTime='8秒'}
local GROUPS={info={classText=true},alias={alias=true},gearScore={gearScore=true},distance={distance=true},castBar={castName=true},
    buffs={buffTime=true,buffStacks=true},debuffs={debuffTime=true,debuffStacks=true},cooldowns={cooldownTime=true}}
function B:HasComponentColors(component)return GROUPS[component]~=nil end
function B:Build(parent,options)
    local id=options.id;local currentScope=options.getScope()
    local compact=options.compact==true
    local root=R:VerticalBox({id=id,parent=parent,gap=compact and 3 or 5,slot={size='auto',hAlign='fill'}})
    local panel={root=root,fields={},rows={},options=options,visibleRowCount=0}
    local status
    if not compact then
    R:Text({id=id..'_title',parent=root,text='颜色与外观 · 每项都可自定义',fontSize=11,tone='strong',slot={size='fixed',height=22}})
    R:Text({id=id..'_hint',parent=root,text=options.draft and '点击色块用 RGB 滑块或 HEX 输入任意调色；校准预览立即更新，保存退出后生效。'
        or '点击色块任意调色，应用后立即保存；选色器优先显示最近使用色。',fontSize=9,tone='muted',overflow='wrap',slot={size='auto',minHeight=28}})
    local actions=R:UniformGrid({id=id..'_actions',parent=root,minCellWidth=110,minCellHeight=27,maxColumns=3,gap=4,slot={size='auto',hAlign='fill'}})
    status=R:Text({id=id..'_status',parent=root,text='',fontSize=9,tone='muted',overflow='wrap',slot={size='auto',minHeight=22}})
    panel.actions=actions
    end
    local function Apply(patch,label)
        if options.getKeys then
            local allowed=options.getKeys()
            for _,palette in pairs(patch)do for key in pairs(palette)do if not allowed[key]then palette[key]=nil end end end
        end
        local ok,err=options.apply(patch)
        local message=ok and ((options.draft and '已预览：'or '已保存：')..label)or '配色未保存：'..tostring(err)
        if status then status:SetText(message)end
        if options.onStatus then options.onStatus(message)end
        panel:Refresh();return ok,err
    end
    function panel:ApplyPreset(name)
        self:CancelPickers();return Apply({[options.getScope()]=F:GetHudColorPreset(name)},'当前组件配色')
    end
    if not compact then
    for _,preset in ipairs({{'recommended','推荐配色'},{'white','简洁白色'},{'contrast','高对比'}})do
        local name,label=preset[1],preset[2]
        R:Button({id=id..'_preset_'..name,parent=panel.actions,text=label,compact=true,slot={size='fill',fill=1},
            onClick=function()panel:CancelPickers();return Apply({[options.getScope()]=F:GetHudColorPreset(name)},label)end})
    end
    if options.copyScope~=false then
        R:Button({id=id..'_copy',parent=panel.actions,text='复制到另一HUD',compact=true,slot={size='fill',fill=1},onClick=function()
            panel:CancelPickers();local scope=options.getScope();local other=scope=='player'and 'target'or 'player'
            local palette=Copy(options.getColors()[scope]);palette.alias=nil -- 名字只有目标有意义，复制共同项目保留目标名字色。
            return Apply({[other]=palette},'复制到'..(other=='player'and '自身'or '目标'))
        end})
    end
    R:Button({id=id..'_reset',parent=panel.actions,text=options.getKeys and '恢复当前项颜色'or '恢复本HUD颜色',compact=true,slot={size='fill',fill=1},onClick=function()
        panel:CancelPickers();return Apply({[options.getScope()]=F:GetHudColorPreset('white')},'恢复本HUD颜色')end})
    end
    for _,definition in ipairs(F:GetHudColorDefinitions())do
        local key,label=definition.key,definition.label
        if not options.keys or options.keys[key]then
            local row=R:HorizontalBox({id=id..'_'..key,parent=root,gap=5,slot={size='fixed',height=compact and 24 or 29,hAlign='fill'}})
            local shortLabel=key:find('Stacks',1,true)and '层数颜色'or key:find('Time',1,true)and '时间颜色'or '文字颜色'
            R:Text({id=id..'_'..key..'_label',parent=row,text=compact and shortLabel or label,fontSize=10,overflow='ellipsis',slot={size='fixed',width=compact and 82 or 100}})
            local sample=not compact and R:Text({id=id..'_'..key..'_sample',parent=row,text=EXAMPLES[key],fontSize=11,overflow='ellipsis',slot={size='fill',fill=1,minWidth=48}})or nil
            local function Preview(color)
                if not sample then return end
                sample.root.rsManualTextColor=true
                S.UI:SetColor(sample.root,color[1],color[2],color[3],1,sample.owner)
            end
            local openedScope
            local field,err=R:ColorField({id=id..'_'..key..'_color',parent=row,label='',width=compact and 132 or 108,height=compact and 24 or 26,defaultColor={1,1,1},enableHexInput=true,
                get=function()return options.getColors()[options.getScope()][key]end,
                set=function(color)
                    if openedScope and openedScope~=options.getScope()then return false,'HUD范围已切换，请重新选择颜色'end
                    return Apply({[options.getScope()]={[key]=color}},label)
                end,
                getRecentColors=function()return F:GetRecentHudColors()end,onPreview=Preview,
                slot={size='fixed',width=compact and 132 or 108}})
            if not field then error(err or '配色控件不可用')end
            local open=field.Open
            function field:Open()openedScope=options.getScope();return open(self)end
            local reset=R:Button({id=id..'_'..key..'_reset',parent=row,text='恢复',compact=true,slot={size='fixed',width=44},onClick=function()
                panel:CancelPickers();return Apply({[options.getScope()]={[key]={1,1,1}}},label)end})
            panel.fields[key]=field;panel.rows[key]={definition=definition,row=row,sample=sample,preview=Preview,reset=reset}
        end
    end
    function panel:CancelPickers()
        for _,field in pairs(self.fields)do if field.CancelDraft then field:CancelDraft()end end
    end
    function panel:Refresh()
        local scope=options.getScope()
        if scope~=currentScope then self:CancelPickers();currentScope=scope end
        local palette=options.getColors()[scope]
        self.visibleRowCount=0
        for key,row in pairs(self.rows)do
            local allowed=options.getKeys and options.getKeys()
            local available=(not row.definition.targetOnly or scope=='target')and(not allowed or allowed[key])
            row.row:SetVisible(available)
            if available then self.visibleRowCount=self.visibleRowCount+1 end
            self.fields[key]:Render();if not self.fields[key].open then row.preview(palette[key])end
        end
        return true
    end
    panel:Refresh();return panel
end

-- 颜色直接属于校准面板的当前组件；不再创建第二个配色窗口。
function B:LayoutCalibration(calibration,y)
    self.calibration=calibration
    if not calibration.colorDraft then self:CloseCalibration();return 0 end
    if not calibration.colorPanel then
    calibration.colorPanel=self:Build(calibration.panel,{id='v3_buff_calibration_colors_content',draft=true,copyScope=false,compact=true,
        getKeys=function()return GROUPS[calibration.component]or {}end,
        getScope=function()return calibration.scope end,getColors=function()return calibration.colorDraft or F:GetHudColorsProjection()end,
        apply=function(patch)return calibration:ApplyColorPatch(patch)end,
        onStatus=function(text)S.UI:SetText(calibration.statusLabel,text,calibration.owner)end})
    calibration.colorPreset=R:Dropdown({id='v3_buff_calibration_color_preset',parent=calibration.panel,width=136,height=26,
        placeholder='当前项配色方案',maxVisible=3,popupWidth=154,
        items={{value='recommended',text='推荐配色'},{value='white',text='简洁白色'},{value='contrast',text='高对比'}},
        get=function()return false end,set=function(name)
            if not calibration.visible or not GROUPS[calibration.component]then return false end
            return calibration.colorPanel:ApplyPreset(name)
        end})
    end
    local panel=calibration.colorPanel;panel:Refresh()
    local count=panel.visibleRowCount;local height=count>0 and count*24+(count-1)*3 or 0
    panel.root:SetVisible(count>0)
    if count>0 then panel.root:Layout(126,y,282,height)end
    if calibration.colorPreset then
        calibration.colorPreset:SetVisible(count>0);calibration.colorPreset:Layout(272,170,136,26);calibration.colorPreset:Render()
    end
    return height
end
function B:CloseCalibration()
    local calibration=self.calibration
    if calibration and calibration.colorPanel then calibration.colorPanel:CancelPickers();calibration.colorPanel.root:SetVisible(false)end
    if calibration and calibration.colorPreset then calibration.colorPreset:Close();calibration.colorPreset:SetVisible(false)end
    return true
end
