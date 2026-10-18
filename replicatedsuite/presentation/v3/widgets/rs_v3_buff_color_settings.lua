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
local GROUPS={info={classText=true},alias={alias=true},gearScore={gearScore=true},distance={distance=true,distanceRules=true},castBar={castName=true},
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
            local shortLabel=key=='distance'and '固定颜色'or key:find('Stacks',1,true)and '层数颜色'or key:find('Time',1,true)and '时间颜色'or '文字颜色'
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

-- 同一校准面板内编辑有界数组；一次只编辑选中档，避免8档把动作按钮挤出窗口。
function B:BuildDistanceRules(calibration)
    local id='v3_buff_distance_rules'
    local root=R:VerticalBox({id=id,parent=calibration.panel,gap=3,slot={size='auto',hAlign='fill'}})
    local panel={root=root,index=1,calibration=calibration}
    local function Rows()return calibration.colorDraft[calibration.scope].distanceRules or {}end
    local function Available()return calibration.visible and calibration.component=='distance'and calibration.colorDraft~=nil end
    local function Reject(err)
        S.UI:SetText(calibration.statusLabel,tostring(err),calibration.owner)
        return false,err
    end
    local function Apply(rows,meters)
        if not Available()then return false,'距离校准未开启'end
        -- 先验证，再结束输入交互；拒绝重复阈值时不能先CancelEditing把22悄悄还原成15。
        local valid,validationErr=F:ValidateHudColors({[calibration.scope]={distanceRules=rows}})
        if not valid then return Reject(validationErr)end
        panel:CancelPickers()
        table.sort(rows,function(a,b)return a.meters<b.meters end)
        local ok,err=calibration:ApplyColorPatch({[calibration.scope]={distanceRules=rows}})
        if ok and meters then for i,row in ipairs(rows)do if row.meters==meters then panel.index=i;break end end end
        panel:Refresh()
        if ok then calibration:LayoutPreview();calibration:LayoutGlobalPreview()end
        S.UI:SetText(calibration.statusLabel,ok and '距离分段已预览，保存并退出后生效。'or tostring(err),calibration.owner)
        return ok,err
    end
    function panel:CancelPickers()
        if self.color then self.color:CancelDraft()end
        if self.selector then self.selector:Close()end
        if self.input and self.input.CancelEditing then self.input:CancelEditing('distance_rule_change')end
    end
    function panel:Select(index)
        if not Available()or not Rows()[index]then return false,'请选择有效距离档'end
        self:CancelPickers();self.index=index;self:Refresh();calibration:LayoutPreview();return true
    end
    function panel:Update(meters,color)
        if not Available()or not Rows()[self.index]then return false,'请先添加距离档'end
        for i,row in ipairs(Rows())do
            if i~=self.index and row.meters==meters then return Reject('距离阈值'..meters..'m已存在，请选择该档或换一个值。')end
        end
        local rows=Copy(Rows());rows[self.index]={meters=meters,color=Copy(color)}
        return Apply(rows,meters)
    end
    function panel:ApplyInput(color)
        if not Available()then return false,'距离校准未开启'end
        local row=Rows()[self.index];if not row then return true end
        -- 按钮可早于LostFocus，失焦也可先重绘Native文本；统一读NumericInput持有的草稿。
        local meters=self.input:GetDraftNumber()
        if meters==nil then return Reject('请输入0到10000的整数距离阈值。')end
        if meters==row.meters and color==nil then
            self.input:EndEditing('distance_apply_unchanged');self.input:Render(nil,'commit');return true
        end
        return self:Update(meters,color or row.color)
    end
    function panel:Add()
        if not Available()then return false,'距离校准未开启'end
        local rows=Copy(Rows());if #rows>=8 then return false,'距离颜色最多8档'end
        local meters=#rows>0 and math.min(10000,rows[#rows].meters+5)or 5
        local used={};for _,row in ipairs(rows)do used[row.meters]=true end
        while used[meters]and meters>0 do meters=meters-1 end
        rows[#rows+1]={meters=meters,color={1,1,1}};return Apply(rows,meters)
    end
    function panel:Delete()
        if not Available()or not Rows()[self.index]then return false,'请先选择距离档'end
        local rows=Copy(Rows());table.remove(rows,self.index);return Apply(rows)
    end
    function panel:UseExamples()
        return Apply({{meters=5,color={1,0,0}},{meters=15,color={1,1,0}},{meters=22,color={1,1,1}}},15)
    end
    local header=R:HorizontalBox({id=id..'_header',parent=root,gap=4,slot={size='fixed',height=24}})
    panel.title=R:Text({id=id..'_title',parent=header,text='距离分段',fontSize=10,slot={size='fill',fill=1}})
    panel.examples=R:Button({id=id..'_examples',parent=header,text='红/黄/白',compact=true,slot={size='fixed',width=82},onClick=function()return panel:UseExamples()end})
    panel.clear=R:Button({id=id..'_clear',parent=header,text='清空',compact=true,slot={size='fixed',width=44},onClick=function()return Apply({})end})
    local choose=R:HorizontalBox({id=id..'_choose',parent=root,gap=4,slot={size='fixed',height=24}})
    panel.selector=R:Dropdown({id=id..'_select',parent=choose,width=166,height=24,placeholder='未启用 · 添加距离档',maxVisible=8,
        items={},get=function()return Rows()[panel.index]and panel.index or false end,set=function(value)return panel:Select(value)end,
        slot={size='fill',fill=1}})
    panel.add=R:Button({id=id..'_add',parent=choose,text='新增',compact=true,slot={size='fixed',width=46},onClick=function()return panel:Add()end})
    panel.delete=R:Button({id=id..'_delete',parent=choose,text='删除',compact=true,slot={size='fixed',width=46},onClick=function()return panel:Delete()end})
    local edit=R:HorizontalBox({id=id..'_edit',parent=root,gap=4,slot={size='fixed',height=24}})
    R:Text({id=id..'_lte',parent=edit,text='≤',fontSize=10,slot={size='fixed',width=14}})
    panel.input=R:NumericInput({id=id..'_meters',parent=edit,width=76,height=24,min=0,max=10000,integer=true,step=1,
        draftCommitMode='explicit',
        get=function()local row=Rows()[panel.index];return row and row.meters or 0 end,
        set=function(value)local row=Rows()[panel.index];return row and panel:Update(value,row.color)or false end,
        slot={size='fixed',width=76}})
    panel.unit=R:Text({id=id..'_unit',parent=edit,text='米',fontSize=10,slot={size='fixed',width=14}})
    R:Text({id=id..'_color_label',parent=edit,text='颜色',fontSize=10,slot={size='fixed',width=28}})
    panel.color=R:ColorField({id=id..'_color',parent=edit,label='',width=132,height=24,enableHexInput=true,
        get=function()local row=Rows()[panel.index];return row and row.color or {1,1,1}end,
        set=function(color)return panel:ApplyInput(color)end,
        getRecentColors=function()return F:GetRecentHudColors()end,slot={size='fixed',width=132}})
    R:Text({id=id..'_hint',parent=root,text='≤阈值生效；超过最大档同色；清空用固定色。',fontSize=9,tone='muted',slot={size='fixed',height=16}})
    function panel:Refresh()
        local rows=Rows();self.index=math.max(1,math.min(self.index,#rows))
        local items={};for i,row in ipairs(rows)do items[#items+1]={value=i,text='第'..i..'档 · ≤'..row.meters..'m'}end
        self.selector:SetItems(items);self.selector:Render();self.input:Render();self.color:Render()
        self.input:SetEnabled(#rows>0);self.color:SetEnabled(#rows>0);self.delete:SetEnabled(#rows>0);self.add:SetEnabled(#rows<8)
        self.title:SetText('距离分段：'..(#rows>0 and #rows..'档'or '关'))
        return true
    end
    return panel
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
    if not calibration.distanceColorPanel then calibration.distanceColorPanel=self:BuildDistanceRules(calibration)end
    local ranges=calibration.distanceColorPanel
    ranges.root:SetVisible(calibration.component=='distance')
    if calibration.component=='distance'then
        ranges:Refresh();ranges.root:Layout(126,y+height+4,282,97);height=height+101
    end
    return height
end
function B:CloseCalibration()
    local calibration=self.calibration
    if calibration and calibration.colorPanel then calibration.colorPanel:CancelPickers();calibration.colorPanel.root:SetVisible(false)end
    if calibration and calibration.colorPreset then calibration.colorPreset:Close();calibration.colorPreset:SetVisible(false)end
    if calibration and calibration.distanceColorPanel then calibration.distanceColorPanel:CancelPickers();calibration.distanceColorPanel.root:SetVisible(false)end
    return true
end
