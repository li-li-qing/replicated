-- 维护（2026-09-18，startup-source-recovery）：本文件在故障包中有 11 处未解决的 Git 合并冲突。
-- 已对照用户此前完整 V3 工程恢复有效实现；Authority、调用数据流和存档协议仍由下方原实现负责，
-- 不通过清配置、跳过加载或恢复 Legacy 绕过错误。兼容边界：须与完整 toc.g 及 .18.247 UI 配套；
-- 后续合并必须先检查冲突标记、清单完整性与 Lua 语法，再做运行时验收；注释不增加运行期开销。
------------------------------------------------------------------------
-- 中文维护注释（tracking-scope-v1 / 文本格式 v3）：
-- 原因：schema8 将追踪 Authority 从全局 buff/debuff/auto 拆成
-- player/target × buff/debuff/auto 六个独立通道；旧 v1/v2 文本仍必须可导入。
-- Authority：本文件只负责纯文本解析/规范化/预览；真正写入仍由 Feature:ImportAll
-- 的单一 Persistence 事务完成。任何解析/容量错误都在事务前整体拒绝。
-- 数据流：文本 -> scoped draft -> PrepareTrackingImport -> ImportAll -> Store schema8。
-- 兼容：旧 BUFF/DEBUFF/AUTO 复制到 player 与 target，保留旧版本“两个 HUD 同时显示”语义。
-- 性能：导入导出是用户冷路径；不新增 Native 读取、Scheduler、Aura Consumer 或热路径缓存。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
local F=S.Features and S.Features.BuffDisplay
if type(F)~="table" then return end

local LegacyParse,LegacySerialize,LegacyExport=F.ParseImportText,F.SerializeExport,F.ExportAll
F.TransferFormatVersion=3

local SCOPES={"player","target"}
local CATEGORIES={"buff","debuff","auto"}
local function Copy(value)
    if type(value)~="table" then return value end
    local out={};for key,item in pairs(value) do out[key]=Copy(item) end;return out
end
local function EmptyTracked()
    return {player={buff={},debuff={},auto={}},target={buff={},debuff={},auto={}}}
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
local function NormalizeInputTracked(value)
    local out=EmptyTracked()
    value=type(value)=="table" and value or {}
    local nested=type(value.player)=="table" or type(value.target)=="table"
    if nested then
        for _,scope in ipairs(SCOPES) do
            local scoped=type(value[scope])=="table" and value[scope] or {}
            for _,category in ipairs(CATEGORIES) do out[scope][category]=Copy(type(scoped[category])=="table" and scoped[category] or {}) end
        end
    else
        -- Legacy in-memory callers keep global semantics: one list applies to both HUDs.
        for _,scope in ipairs(SCOPES) do
            for _,category in ipairs(CATEGORIES) do out[scope][category]=Copy(type(value[category])=="table" and value[category] or {}) end
        end
    end
    return out
end
local function AppendAll(dst,src)
    for _,id in ipairs(src or {}) do dst[#dst+1]=id end
end

function F:ExportAll(mode)
    local data=LegacyExport(self)
    data.format="replicatedsuite.buff_display.v3"
    data.schemaVersion=8
    data.exportMode=mode=="tracking" and "tracking" or "full"
    data.catalogVersion=(S.Data and S.Data.StatusTrackingCatalogV3 and S.Data.StatusTrackingCatalogV3.version) or 0
    data.tracked=Copy(self.State.settings.tracked or EmptyTracked())
    data.trackedCooldowns=Copy(self.State.settings.trackedCooldowns or {skill={},mate={}})
    if data.exportMode=="tracking" then data.components=nil;data.hud=nil;data.settings=nil end
    return data
end

function F:SerializeExport(data)
    data=type(data)=="table" and data or self:ExportAll()
    local tracked=NormalizeInputTracked(data.tracked)
    -- Reuse the frozen legacy serializer only for HUD/policy/classification lines.
    -- Give it an empty flat tracking shape, then strip its version headers so the
    -- v3 header below is the sole transfer authority.
    local legacy=Copy(data)
    legacy.format="replicatedsuite.buff_display"
    legacy.schemaVersion=7
    legacy.tracked={buff={},debuff={}}
    local legacyText=LegacySerialize(self,legacy)
    local retained,classificationLines={},{}
    for line in (legacyText.."\n"):gmatch("([^\n]*)\n") do
        local upper=line:upper()
        if upper:match("^CLASSIFICATION=") then classificationLines[#classificationLines+1]=line
        elseif not upper:match("^VERSION=") and not upper:match("^FORMAT=")
            and not upper:match("^BUFF=") and not upper:match("^DEBUFF=") and not upper:match("^AUTO=")
            and not upper:match("^STORE_SCHEMA=") and not upper:match("^CATALOG_VERSION=")
            and not upper:match("^EXPORT_MODE=") and not upper:match("^COOLDOWN_SKILL=") and not upper:match("^COOLDOWN_MATE=") then
            retained[#retained+1]=line
        end
    end
    table.sort(classificationLines);for _,line in ipairs(classificationLines) do retained[#retained+1]=line end
    local lines=retained
    lines[#lines+1]="VERSION=8"
    lines[#lines+1]="FORMAT=replicatedsuite.buff_display.v3"
    lines[#lines+1]="STORE_SCHEMA=8"
    lines[#lines+1]="CATALOG_VERSION="..tostring(data.catalogVersion or 0)
    lines[#lines+1]="EXPORT_MODE="..tostring(data.exportMode or "full")
    for _,scope in ipairs(SCOPES) do
        for _,category in ipairs(CATEGORIES) do
            lines[#lines+1]=string.upper(scope).."_"..string.upper(category).."="..table.concat(tracked[scope][category] or {},",")
        end
    end
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
    local tracked=EmptyTracked();local cooldowns={skill={},mate={}}
    local mode,format,catalogVersion="full",nil,0
    local lineCount,businessLines=0,0
    local classificationSeen={}
    for raw in (text.."\n"):gmatch("([^\n]*)\n") do
        lineCount=lineCount+1
        if lineCount>4096 then errors[#errors+1]="导入超过 4096 行";break end
        local line=raw:gsub("\r$",""):match("^%s*(.-)%s*$")
        local key,value=line:match("^([^=]+)=(.*)$")
        key=key and key:gsub("%s+",""):upper()
        value=value and value:match("^%s*(.-)%s*$")
        if key=="FORMAT" then
            format=value
            if value~="replicatedsuite.buff_display.v3" and value~="replicatedsuite.buff_display.v2"
                and value~="replicatedsuite.buff_display" and value~="replicatedsuite.buff_display.v1" then
                errors[#errors+1]="不支持的 FORMAT："..value
            end
        elseif key=="VERSION" or key=="STORE_SCHEMA" then
            local schema=tonumber(value)
            if not schema or schema<1 or schema>8 or schema~=math.floor(schema) then errors[#errors+1]="不支持的存档版本："..value end
        elseif key=="CATALOG_VERSION" then
            catalogVersion=tonumber(value) or -1
            if catalogVersion<0 or catalogVersion~=math.floor(catalogVersion) then errors[#errors+1]="目录版本无效" end
        elseif key=="EXPORT_MODE" then
            mode=value
            if mode~="full" and mode~="tracking" then errors[#errors+1]="导出模式无效" end
        elseif key=="BUFF" or key=="DEBUFF" or key=="AUTO" then
            -- v1/v2 global selection is duplicated to both scopes so upgrading a
            -- text backup cannot silently remove statuses from one HUD.
            businessLines=businessLines+1
            local tmp={};ReadIds(value,tmp,errors,"第 "..lineCount.." 行")
            local category=key:lower();AppendAll(tracked.player[category],tmp);AppendAll(tracked.target[category],tmp)
        elseif key=="PLAYER_BUFF" or key=="PLAYER_DEBUFF" or key=="PLAYER_AUTO"
            or key=="TARGET_BUFF" or key=="TARGET_DEBUFF" or key=="TARGET_AUTO" then
            businessLines=businessLines+1
            local scope,category=key:lower():match("^(player)_(.+)$")
            if not scope then scope,category=key:lower():match("^(target)_(.+)$") end
            ReadIds(value,tracked[scope][category],errors,"第 "..lineCount.." 行")
        elseif key=="COOLDOWN_SKILL" or key=="COOLDOWN_MATE" then
            businessLines=businessLines+1
            ReadIds(value,cooldowns[key=="COOLDOWN_SKILL" and "skill" or "mate"],errors,"第 "..lineCount.." 行")
        elseif key=="CLASSIFICATION" then
            businessLines=businessLines+1
            -- 中文维护注释：同一文本里对同 ID 给出 Buff 与 Debuff 两个 override 是歧义输入，
            -- 不能依赖“后写覆盖前写”的行顺序决定业务结果；先记录冲突，再继续交给 legacy parser
            -- 做既有格式/数值校验。相同值重复允许，由最终 map 自然去重。
            local rawId,rawCategory=tostring(value or ""):match("^(%d+):([%a]+)$")
            local numeric=ValidId(rawId);rawCategory=rawCategory and rawCategory:lower() or nil
            if numeric and (rawCategory=="buff" or rawCategory=="debuff") then
                if classificationSeen[numeric] and classificationSeen[numeric]~=rawCategory then
                    errors[#errors+1]="第 "..lineCount.." 行：同一 ID 的人工分类互相冲突："..tostring(numeric)
                else classificationSeen[numeric]=rawCategory end
            end
            pass[#pass+1]=line
        else
            if key=="COMPONENT" or key=="SETTING"
                or key=="HUDSCALE" or key=="HUDPLATE" or key=="HUDINFO" or key=="HUDCOMPONENT" then businessLines=businessLines+1 end
            pass[#pass+1]=line
        end
    end
    local parsed=LegacyParse(self,table.concat(pass,"\n"))
    for _,err in ipairs(parsed.errors or {}) do errors[#errors+1]=err end
    for _,warning in ipairs(parsed.warnings or {}) do warnings[#warnings+1]=warning end
    parsed.data.tracked,parsed.data.trackedCooldowns=tracked,cooldowns
    parsed.data.format,parsed.data.exportMode=format or "replicatedsuite.buff_display.v1",mode
    parsed.data.catalogVersion=catalogVersion
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
    for _,field in ipairs({"tracked","trackedCooldowns","classification","components","hud","settings"}) do
        if data[field]~=nil and type(data[field])~="table" then return nil,"导入字段不是表："..field end
    end
    -- 中文维护注释（导入结构 fail-closed）：NormalizeInputTracked 负责兼容形状转换，不负责吞掉
    -- 错类型。直接 API/未来 UI 若传 player.auto="..."，必须在任何 merge/overwrite 前整体拒绝；
    -- 否则“坏字段 -> 空列表”会在覆盖模式合法清空用户通道。旧 flat 三桶仍允许，但桶本身必须是 table。
    if type(data.tracked)=="table" then
        local rawTracked=data.tracked
        local nested=type(rawTracked.player)=="table" or type(rawTracked.target)=="table"
        if nested then
            for _,scopeKey in ipairs(SCOPES) do
                if rawTracked[scopeKey]~=nil and type(rawTracked[scopeKey])~="table" then return nil,"追踪范围不是表："..scopeKey end
                local rawScope=type(rawTracked[scopeKey])=="table" and rawTracked[scopeKey] or {}
                for _,categoryKey in ipairs(CATEGORIES) do
                    if rawScope[categoryKey]~=nil and type(rawScope[categoryKey])~="table" then
                        return nil,"追踪通道不是列表："..scopeKey.."."..categoryKey
                    end
                end
            end
        else
            for _,categoryKey in ipairs(CATEGORIES) do
                if rawTracked[categoryKey]~=nil and type(rawTracked[categoryKey])~="table" then return nil,"追踪通道不是列表："..categoryKey end
            end
        end
    end
    local incoming=NormalizeInputTracked(data.tracked)
    local settings=self.State.settings
    local current=NormalizeInputTracked(settings.tracked)
    local out={tracked=EmptyTracked(),trackedCooldowns={skill={},mate={}},classification={}}
    local summary={added=0,removed=0,existing=0,unknown=0,duplicates=0}
    local function MergeIds(existing,values,cap,label)
        if type(values)~="table" then return nil,"追踪字段必须为列表："..label end
        local result,seen={},{}
        for _,raw in ipairs(existing or {}) do
            local id=ValidId(raw);if id and not seen[id] then result[#result+1]=id;seen[id]=true end
        end
        local length=#values
        for key,raw in pairs(values) do
            if type(key)~="number" or key<1 or key~=math.floor(key) or key>length then return nil,"追踪列表不是连续数组："..label end
            if not ValidId(raw) then return nil,"非法追踪 ID："..tostring(raw) end
        end
        for _,raw in ipairs(values) do
            local id=ValidId(raw)
            if seen[id] then summary.existing=summary.existing+1;summary.duplicates=summary.duplicates+1
            else result[#result+1]=id;seen[id]=true end
            if #result>cap then return nil,"导入超出容量（"..cap.."）："..label.."，本次整体拒绝" end
        end
        table.sort(result);return result
    end
    for _,scope in ipairs(SCOPES) do
        for _,category in ipairs(CATEGORIES) do
            local base=mode=="merge" and current[scope][category] or {}
            local ids,err=MergeIds(base,incoming[scope][category],1024,scope.."."..category)
            if not ids then return nil,err end
            out.tracked[scope][category]=ids
        end
        -- Explicit placement is stronger than Auto only within the same scope.
        local explicit={};for _,category in ipairs({"buff","debuff"}) do for _,id in ipairs(out.tracked[scope][category]) do explicit[id]=true end end
        local auto={};for _,id in ipairs(out.tracked[scope].auto) do if not explicit[id] then auto[#auto+1]=id end end
        out.tracked[scope].auto=auto
    end
    local cooldowns=type(data.trackedCooldowns)=="table" and data.trackedCooldowns or {}
    for _,kind in ipairs({"skill","mate"}) do
        if cooldowns[kind]~=nil and type(cooldowns[kind])~="table" then return nil,"冷却追踪桶不是列表："..kind end
        local base=mode=="merge" and (settings.trackedCooldowns[kind] or {}) or {}
        local ids,err=MergeIds(base,cooldowns[kind] or {},256,"cooldown."..kind)
        if not ids then return nil,err end;out.trackedCooldowns[kind]=ids
    end
    out.classification=mode=="merge" and Copy(settings.classification) or {}
    for raw,category in pairs(type(data.classification)=="table" and data.classification or {}) do
        local id=ValidId(raw)
        if not id or (category~="buff" and category~="debuff") then return nil,"非法人工分类" end
        out.classification[id]=category
    end
    local before,after={},{}
    for _,scope in ipairs(SCOPES) do for _,category in ipairs(CATEGORIES) do
        for _,id in ipairs(current[scope][category]) do before[scope..":"..category..":"..id]=true end
        for _,id in ipairs(out.tracked[scope][category]) do after[scope..":"..category..":"..id]=true end
    end end
    for _,kind in ipairs({"skill","mate"}) do
        for _,id in ipairs(settings.trackedCooldowns[kind] or {}) do before["cooldown:"..kind..":"..id]=true end
        for _,id in ipairs(out.trackedCooldowns[kind] or {}) do after["cooldown:"..kind..":"..id]=true end
    end
    for key in pairs(after) do if not before[key] then summary.added=summary.added+1 end end
    for key in pairs(before) do if not after[key] then summary.removed=summary.removed+1 end end
    summary.unknown=#out.tracked.player.auto+#out.tracked.target.auto
    out.summary=summary
    return out
end

function F:PreviewImport(data,mode)
    local prepared,err=self:PrepareTrackingImport(data,mode)
    if not prepared then return false,err end
    return true,string.format("将新增通道 %d / 移除通道 %d / 已有或重复 %d / Auto通道 %d；确认后单事务写入",
        prepared.summary.added,prepared.summary.removed,prepared.summary.existing,prepared.summary.unknown),prepared.summary
end

function F:ImportTrackedIds(text,category,mode,scope)
    category=(category=="buff" or category=="debuff") and category or "auto"
    mode=(mode=="overwrite") and "overwrite" or "merge"
    scope=(scope=="player" or scope=="target") and scope or "all"
    local ids,errors={},{};ReadIds(text,ids,errors,"快速导入")
    if #errors>0 then return false,errors[1].."；本次整体未写入" end
    if #ids==0 then return false,"没有可导入的状态 ID" end
    local data={tracked=Copy(self.State.settings.tracked),trackedCooldowns=Copy(self.State.settings.trackedCooldowns),
        classification=Copy(self.State.settings.classification),exportMode="tracking"}
    local scopes=scope=="all" and SCOPES or {scope}
    for _,targetScope in ipairs(scopes) do
        if mode=="overwrite" then data.tracked[targetScope][category]=Copy(ids)
        else AppendAll(data.tracked[targetScope][category],ids) end
    end
    -- `data` already contains the exact preserved state for non-selected channels;
    -- use overwrite at the final transaction boundary to avoid merge duplicating it again.
    return self:ImportAll(data,"overwrite")
end

F.Commands.ExportAll=function(_,mode) return F:ExportAll(mode) end
F.Commands.PreviewImport=function(_,data,mode) return F:PreviewImport(data,mode) end
F.Commands.ImportTrackedIds=function(_,text,category,mode,scope) return F:ImportTrackedIds(text,category,mode,scope) end
