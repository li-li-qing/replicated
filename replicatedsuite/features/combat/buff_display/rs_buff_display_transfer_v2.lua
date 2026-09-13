------------------------------------------------------------------------
-- 中文维护注释：文本格式 v2 与 Store schema6 分离；保留旧 HUD/COMPONENT 解析器。
-- 原因：旧快速导入会忽略非法 ID 并部分写入，未知极性被错误归入 Buff，覆盖不清人工分类。
-- Authority：解析/预览是纯数据；PrepareTrackingImport 校验全部选择后，既有 ImportAll 的
-- 单一 Persistence 事务提交追踪 + 人工分类 + 双 HUD。失败不得留下半份设置。
-- Native API/目录本体不导出；文本仅携带用户选择。输入长度、行数、ID 范围与容量都有界。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
local F=S.Features and S.Features.BuffDisplay
if type(F)~="table" then return end
local LegacyParse,LegacySerialize,LegacyExport=F.ParseImportText,F.SerializeExport,F.ExportAll
F.TransferFormatVersion=2
local function Copy(value)
    if type(value)~="table" then return value end
    local out={};for key,item in pairs(value) do out[key]=Copy(item) end;return out
end
local function ValidId(value)
    local id=tonumber(value)
    if not id or id~=id or id<=0 or id>2147483647 or id~=math.floor(id) then return nil end
    return id
end
local function ReadIds(text,out,errors,label)
    for token in tostring(text or ""):gmatch("[^,%s;]+") do
        local id=token:match("^%d+$") and ValidId(token) or nil
        if id then out[#out+1]=id else errors[#errors+1]=label.."：无效 ID "..token end
    end
end
function F:ExportAll(mode)
    local data=LegacyExport(self)
    data.format="replicatedsuite.buff_display.v2";data.schemaVersion=6
    data.exportMode=mode=="tracking" and "tracking" or "full"
    data.catalogVersion=S.Data.StatusTrackingCatalogV3.version
    data.trackedCooldowns=Copy(self.State.settings.trackedCooldowns)
    if data.exportMode=="tracking" then data.components=nil;data.hud=nil;data.settings=nil end
    return data
end
function F:SerializeExport(data)
    data=type(data)=="table" and data or self:ExportAll()
    local legacy=Copy(data);legacy.format="replicatedsuite.buff_display.v2";legacy.schemaVersion=6
    local text=LegacySerialize(self,legacy)
    -- 中文维护注释：旧 serializer 的 pairs(classification) 顺序不稳定；只重排该命名空间，不改变旧 HUD 语法。
    local retained,classificationLines={},{}
    for line in (text.."\n"):gmatch("([^\n]*)\n") do
        if line:match("^CLASSIFICATION=") then classificationLines[#classificationLines+1]=line else retained[#retained+1]=line end
    end
    table.sort(classificationLines)
    for _,line in ipairs(classificationLines) do retained[#retained+1]=line end
    text=table.concat(retained,"\n")
    local lines={text,"STORE_SCHEMA=6","CATALOG_VERSION="..tostring(data.catalogVersion or 1),
        "EXPORT_MODE="..tostring(data.exportMode or "full")}
    lines[#lines+1]="AUTO="..table.concat(type(data.tracked)=="table" and data.tracked.auto or {},",")
    for _,kind in ipairs({"skill","mate"}) do
        local ids=type(data.trackedCooldowns)=="table" and data.trackedCooldowns[kind] or {}
        lines[#lines+1]="COOLDOWN_"..string.upper(kind).."="..table.concat(ids or {},",")
    end
    return table.concat(lines,"\n")
end
function F:ParseImportText(text)
    text=tostring(text or "")
    if #text>65535 then return {data={_parseErrors=1},errors={"导入文本超过 65535 字节"},warnings={}} end
    local pass,errors,warnings={}, {}, {}
    local tracked={buff={},debuff={},auto={}};local cooldowns={skill={},mate={}}
    local mode,format,catalogVersion="full",nil,0
    local lineCount,businessLines=0,0
    local classifications={}
    for raw in (text.."\n"):gmatch("([^\n]*)\n") do
        lineCount=lineCount+1
        if lineCount>4096 then errors[#errors+1]="导入超过 4096 行";break end
        local line=raw:gsub("\r$",""):match("^%s*(.-)%s*$")
        local key,value=line:match("^([^=]+)=(.*)$")
        key=key and key:gsub("%s+",""):upper()
        value=value and value:match("^%s*(.-)%s*$")
        if key=="FORMAT" then
            format=value
            if value~="replicatedsuite.buff_display.v2" and value~="replicatedsuite.buff_display"
                and value~="replicatedsuite.buff_display.v1" then errors[#errors+1]="不支持的 FORMAT："..value end
        elseif key=="VERSION" or key=="STORE_SCHEMA" then
            local schema=tonumber(value)
            if not schema or schema<1 or schema>6 or schema~=math.floor(schema) then errors[#errors+1]="不支持的存档版本："..value end
        elseif key=="CATALOG_VERSION" then
            catalogVersion=tonumber(value) or -1
            if catalogVersion<0 or catalogVersion~=math.floor(catalogVersion) then errors[#errors+1]="目录版本无效" end
        elseif key=="EXPORT_MODE" then
            mode=value
            if mode~="full" and mode~="tracking" then errors[#errors+1]="导出模式无效" end
        elseif key=="BUFF" or key=="DEBUFF" or key=="AUTO" then
            businessLines=businessLines+1
            ReadIds(value,tracked[key:lower()],errors,"第 "..lineCount.." 行")
        elseif key=="COOLDOWN_SKILL" or key=="COOLDOWN_MATE" then
            businessLines=businessLines+1
            ReadIds(value,cooldowns[key=="COOLDOWN_SKILL" and "skill" or "mate"],errors,"第 "..lineCount.." 行")
        else
            if key=="COMPONENT" or key=="SETTING" or (key=="HUDSCALE" or key=="HUDPLATE" or key=="HUDINFO" or key=="HUDCOMPONENT") then businessLines=businessLines+1 end
            if key=="CLASSIFICATION" then
                businessLines=businessLines+1
                local id,category=value:match("^(%d+):([a-z]+)$")
                if not ValidId(id) or (category~="buff" and category~="debuff") then errors[#errors+1]="人工分类格式无效"
                elseif classifications[id] and classifications[id]~=category then errors[#errors+1]="同一状态存在冲突的人工分类："..id
                else classifications[id]=category end
            end
            pass[#pass+1]=line
        end
    end
    local parsed=LegacyParse(self,table.concat(pass,"\n"))
    for _,err in ipairs(parsed.errors or {}) do errors[#errors+1]=err end
    for _,warning in ipairs(parsed.warnings or {}) do warnings[#warnings+1]=warning end
    parsed.data.tracked,parsed.data.trackedCooldowns=tracked,cooldowns
    parsed.data.format,parsed.data.exportMode= format or "replicatedsuite.buff_display.v1",mode
    parsed.data.catalogVersion=catalogVersion
    -- 空文本绝不解释为“覆盖为空”；纯 FORMAT 也必须有实际业务行才可提交。
    -- 中文维护注释：元信息不是清空意图。显式 AUTO=/BUFF= 可表示空清单；只有版本头/注释不可提交。
    if businessLines==0 then errors[#errors+1]="没有可导入的追踪、分类或 HUD 设置行" end
    parsed.data._parseErrors=#errors
    local prepared,prepareErr=self:PrepareTrackingImport(parsed.data,"overwrite")
    if not prepared and #errors==0 then errors[#errors+1]=prepareErr;parsed.data._parseErrors=#errors end
    if prepared then parsed.data.tracked=prepared.tracked;parsed.data.trackedCooldowns=prepared.trackedCooldowns end
    parsed.errors,parsed.warnings=errors,warnings
    return parsed
end
function F:PrepareTrackingImport(data,mode)
    if type(data)~="table" or (tonumber(data._parseErrors) or 0)>0 then return nil,"导入含解析错误，未写入" end
    if mode~="merge" and mode~="overwrite" then return nil,"导入模式必须是 merge 或 overwrite" end
    -- 中文维护注释：命令也可能被内部调用；不能只信任文本框校验，更不能把 false/string 解释为空配置。
    for _,field in ipairs({"tracked","trackedCooldowns","classification","components","hud","settings"}) do
        if data[field]~=nil and type(data[field])~="table" then return nil,"导入字段不是表："..field end
    end
    for _,group in ipairs({{"tracked","buff","debuff","auto"},{"trackedCooldowns","skill","mate"}}) do
        local values=data[group[1]]
        if type(values)=="table" then
            for i=2,#group do if values[group[i]]~=nil and type(values[group[i]])~="table" then return nil,"追踪桶不是列表："..group[i] end end
        end
    end
    local settings=self.State.settings
    local out={tracked={buff={},debuff={},auto={}},trackedCooldowns={skill={},mate={}},classification={}}
    local summary={added=0,removed=0,existing=0,unknown=0,duplicates=0}
    local incomingSeen={}
    local function MergeIds(existing,incoming,cap,namespace)
        if type(incoming)~="table" then return nil,"追踪字段必须为列表" end
        local ids,seen={},{}
        for _,id in ipairs(existing or {}) do ids[#ids+1]=id;seen[id]=true end
        for key,raw in pairs(incoming) do
            if type(key)~="number" or key<1 or key~=math.floor(key) or key>#incoming then return nil,"追踪列表不是连续数组" end
            local id=ValidId(raw);if not id then return nil,"非法追踪 ID："..tostring(raw) end
            local previous=incomingSeen[namespace..":"..id]
            if previous then summary.duplicates=summary.duplicates+1 end
        end
        for _,raw in ipairs(incoming) do
            local id=ValidId(raw)
            if namespace=="aura" then
                if incomingSeen["aura:"..id] and incomingSeen["aura:"..id]~=out.currentBucket then return nil,"同一状态存在跨分类冲突："..id end
                incomingSeen["aura:"..id]=out.currentBucket
            end
            if not seen[id] then ids[#ids+1]=id;seen[id]=true else summary.existing=summary.existing+1 end
            if #ids>cap then return nil,"导入超出容量（"..cap.."），本次整体拒绝" end
        end
        table.sort(ids);return ids
    end
    for _,category in ipairs({"buff","debuff","auto"}) do
        out.currentBucket=category
        local ids,err=MergeIds(mode=="merge" and settings.tracked[category] or {},
            type(data.tracked)=="table" and data.tracked[category] or {},1024,"aura")
        if not ids then return nil,err end;out.tracked[category]=ids
    end
    out.currentBucket=nil
    -- 合并时同一 ID 已存在其它桶，不猜哪一个用户意图获胜：明确要求处理冲突/选择覆盖。
    local seen={}
    for _,category in ipairs({"buff","debuff","auto"}) do
        for _,id in ipairs(out.tracked[category]) do
            if seen[id] and seen[id]~=category then return nil,"合并后存在跨分类冲突："..id end
            seen[id]=category
        end
    end
    for _,kind in ipairs({"skill","mate"}) do
        local ids,err=MergeIds(mode=="merge" and settings.trackedCooldowns[kind] or {},
            type(data.trackedCooldowns)=="table" and data.trackedCooldowns[kind] or {},256,kind)
        if not ids then return nil,err end;out.trackedCooldowns[kind]=ids
    end
    out.classification=mode=="merge" and Copy(settings.classification) or {}
    for raw,category in pairs(type(data.classification)=="table" and data.classification or {}) do
        local id=ValidId(raw)
        if not id or (category~="buff" and category~="debuff") then return nil,"非法人工分类" end
        out.classification[id]=category
    end
    local before={}
    for _,category in ipairs({"buff","debuff","auto"}) do for _,id in ipairs(settings.tracked[category]) do before["a:"..id]=true end end
    for _,kind in ipairs({"skill","mate"}) do for _,id in ipairs(settings.trackedCooldowns[kind]) do before[kind..":"..id]=true end end
    local after={}
    for _,category in ipairs({"buff","debuff","auto"}) do for _,id in ipairs(out.tracked[category]) do after["a:"..id]=true end end
    for _,kind in ipairs({"skill","mate"}) do for _,id in ipairs(out.trackedCooldowns[kind]) do after[kind..":"..id]=true end end
    for key in pairs(after) do if not before[key] then summary.added=summary.added+1 end end
    for key in pairs(before) do if not after[key] then summary.removed=summary.removed+1 end end
    summary.unknown=#out.tracked.auto
    out.summary=summary
    return out
end
function F:PreviewImport(data,mode)
    local prepared,err=self:PrepareTrackingImport(data,mode)
    if not prepared then return false,err end
    return true,string.format("将新增 %d / 移除 %d / 已有 %d / Auto %d；确认后单事务写入",
        prepared.summary.added,prepared.summary.removed,prepared.summary.existing,prepared.summary.unknown),prepared.summary
end
function F:ImportTrackedIds(text,category,mode)
    category=(category=="buff" or category=="debuff") and category or "auto"
    local ids,errors={},{};ReadIds(text,ids,errors,"快速导入")
    if #errors>0 then return false,errors[1].."；本次整体未写入" end
    if #ids==0 then return false,"没有可导入的状态 ID" end
    local data={tracked={},classification={},exportMode="tracking"}
    if mode=="overwrite" then
        data.tracked=Copy(self.State.settings.tracked)
        data.trackedCooldowns=Copy(self.State.settings.trackedCooldowns)
        data.classification=Copy(self.State.settings.classification)
    end
    data.tracked[category]=ids
    return self:ImportAll(data,mode or "merge")
end
F.Commands.ExportAll=function(_,mode) return F:ExportAll(mode) end
F.Commands.PreviewImport=function(_,data,mode) return F:PreviewImport(data,mode) end
