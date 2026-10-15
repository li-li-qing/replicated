------------------------------------------------------------------------
-- Replicated Suite · 个人战斗历史交换
-- 作者：Replicated
-- QQ群：1104129461
--
-- 历史 Authority 的冷路径扩展：每个来源只接纳较新的累计快照，回传/重复/乱序包不重复相加。
-- 来源、设备写入身份和派生合计共用原 Store 的一次耐久提交；不监听战斗、不新增后台任务。
-- 文本为有限字段协议，绝不执行 Lua。复制校验只检查传输完整性，不构成战绩真实性认证。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
local F=S.Features and S.Features.CombatAnalytics
local H=F and F.PersonalHistory
local P=S.Persistence
if not H or not P or type(H.TransferHelpers)~='table' then return end
local C=H.TransferHelpers
H.TransferContractVersion=1 -- 只读验收可确认模块实际加载，不通过测试导入或创建本地来源来探测。
local MAX_SOURCES,MAX_BYTES,PART_BYTES,MAX_COUNTER=16,1048576,7000,9007199254740991
local function Copy(v) return S.Utils.DeepCopy(v) end
local function NumberText(v) return string.format('%.0f',C.counter(v)) end
local function Whole(v)
    if type(v)~='string' or #v>16 or not (v=='0' or v:match('^[1-9]%d*$')) then return nil end
    local n=tonumber(v);if not n or n>MAX_COUNTER then return nil end
    return n
end
local function Check(text)
    local transport=S.ReportCopyTransport
    if not transport or type(transport.CopyChecksum)~='function' then return nil,'历史复制编码器不可用' end
    return transport:CopyChecksum(text)
end
local function Hex(text) return (tostring(text or ''):gsub('.',function(ch)return string.format('%02X',ch:byte())end)) end
local function Unhex(text,limit)
    if #text%2~=0 or #text>(limit or 32)*2 or text:find('[^%x]') then return nil end
    return (text:gsub('%x%x',function(pair)return string.char(tonumber(pair,16))end))
end
local function Split(text,separator)
    local out={};for field in (text..separator):gmatch('(.-)'..separator) do out[#out+1]=field end;return out
end
local function Sorted(map)
    local out={};for key in pairs(map or {})do out[#out+1]=key end;table.sort(out);return out
end
local function Stamp(a,b,last)
    if not a then return b end;if not b then return a end
    if last then return a>b and a or b end;return a<b and a or b
end
local function OriginId(id) return type(id)=='string' and #id>=3 and #id<=64 and not id:find('[^%w%-]') end
local function Snapshot(value)
    local out=C.normalize(value)
    -- 来源数值保存为十进制字符串，避免 RU float32 序列化把大累计和来源版本改小。
    -- 零字段由固定计数字段表恢复，来源内省略零可避免两台电脑的多年历史重复撑满节点预算。
    local function Strings(row)for _,key in ipairs(C.keys)do local n=C.counter(row[key]);row[key]=n>0 and NumberText(n) or nil end end
    Strings(out.totals);Strings(out.archive);for _,row in pairs(out.days)do Strings(row)end
    out.serial=NumberText(type(value)=='table' and value.serial or 0)
    return out
end
local function CountText(row)
    local out={};for _,key in ipairs(C.keys)do out[#out+1]=NumberText(row[key])end;return table.concat(out,',')
end
local function AppendSource(lines,id,source)
    lines[#lines+1]=table.concat({'S',id,source.serial,Hex(source.firstAt),Hex(source.lastAt),Hex(source.archiveFrom),Hex(source.archiveTo)},'|')
    lines[#lines+1]='T|'..CountText(source.totals);lines[#lines+1]='A|'..CountText(source.archive)
    for _,date in ipairs(Sorted(source.days))do
        local row=source.days[date]
        lines[#lines+1]=table.concat({'D',date,Hex(row.firstAt),Hex(row.lastAt),CountText(row)},'|')
    end
    lines[#lines+1]='E'
end
local function SourceText(id,source)local lines={};AppendSource(lines,id,source);return table.concat(lines,'\n')end

-- canonical 是来源账本的确定性投影；顶层合计只是派生缓存，回读时可从精确来源恢复被 float32 舍入的数值。
-- 旧档没有 sync 时完全使用旧归一化器，因此 schema1/2 的历史指纹和退休 NPC 字段仍受原校验保护。
function H:NormalizeTransferState(value)
    if type(value)~='table' or type(value.sync)~='table' or type(value.sync.sources)~='table' then return C.normalize(value) end
    local out=C.normalize(nil);local sources={}
    for id,raw in pairs(value.sync.sources)do
        if OriginId(id) and type(raw)=='table' then
            local source=Snapshot(raw);sources[id]=source
            C.add(out.totals,source.totals);C.add(out.archive,source.archive)
            out.firstAt=Stamp(out.firstAt,source.firstAt);out.lastAt=Stamp(out.lastAt,source.lastAt,true)
            out.archiveFrom=Stamp(out.archiveFrom,source.archiveFrom);out.archiveTo=Stamp(out.archiveTo,source.archiveTo,true)
            for date,row in pairs(source.days)do
                local target=out.days[date] or C.counts(nil);out.days[date]=target;C.add(target,row)
                target.firstAt=Stamp(target.firstAt,row.firstAt);target.lastAt=Stamp(target.lastAt,row.lastAt,true)
            end
        end
    end
    out=C.normalize(out);out.sync={localId=value.sync.localId,sources=sources}
    return out
end
local function Binding()
    local store=P:GetStore(H.StoreId)
    local key,err,fingerprint=P:ResolveStoreKey(store)
    if not key or not fingerprint then return nil,err or '角色身份尚未就绪，请进入角色后重试' end
    return tostring(fingerprint)
end
local function Enroll(value,incoming)
    local out=H:NormalizeState(value)
    if out.sync then return out end
    local sources={};local hasHistory=next(out.days)~=nil
    for _,key in ipairs(C.keys)do if C.counter(out.totals[key])>0 then hasHistory=true end end
    if hasHistory then
        -- 完全相同的旧档使用同一基线 ID；复制过的相同旧历史不会在首次交换时重复累计。
        local baseline=Snapshot(out);local text=SourceText('baseline',baseline)
        local hash,err=Check(text);if not hash then return nil,err end
        sources['l-'..hash..'-'..#text]=baseline
    end
    local id
    for attempt=1,8 do
        local parts={'d'};for _=1,8 do parts[#parts+1]=string.format('%04X',math.random(0,65535))end
        parts[#parts+1]=NumberText(S.NowMs and S.NowMs());parts[#parts+1]=tostring(S.Generation or 0)
        id=table.concat(parts,'-')
        if not sources[id] and not (incoming and incoming[id]) then break end
        id=nil
    end
    if not id then return nil,'无法建立独立的本地来源，请重载后重试' end
    sources[id]=Snapshot(nil);out.sync={localId=id,sources=sources}
    return H:NormalizeState(out)
end
local function ValidSnapshot(source)
    -- 容量、非整数和总账守恒均在写存档前检查，坏输入不能被归一化成合法的空历史。
    local sum=C.counts(nil)
    for _,key in ipairs(C.keys)do
        if not Whole(source.totals[key] or '0') or not Whole(source.archive[key] or '0') then return false,'历史累计数值无效' end
        sum[key]=C.counter(source.archive[key])
    end
    local count=0
    for date,row in pairs(source.days)do
        count=count+1;if count>C.maxDays or not (C.validDate(date) or date=='unknown') then return false,'记录日期或数量无效' end
        for _,key in ipairs(C.keys)do
            local n=Whole(row[key] or '0');if not n then return false,'每日历史数值无效' end
            sum[key]=sum[key]+n;if sum[key]>MAX_COUNTER then return false,'历史累计超过精确数值范围' end
        end
    end
    for _,key in ipairs(C.keys)do if C.counter(source.totals[key])~=sum[key] then return false,'历史总计与每日记录/归档不一致' end end
    return true
end
local function ValidateState(value)
    local count=0
    for id,source in pairs(value.sync.sources)do
        count=count+1;if count>MAX_SOURCES or not OriginId(id) then return false,'来源过多，最多支持16个来源；原记录未修改' end
        local ok,err=ValidSnapshot(source);if not ok then return false,err end
    end
    for _,key in ipairs(C.keys)do if C.counter(value.totals[key])>MAX_COUNTER then return false,'合并累计超过精确数值范围' end end
    local inspection=P:InspectPayload(value,P:GetStore(H.StoreId).budget)
    if inspection.ok~=true then return false,'合并结果超过存档容量，原记录未修改' end
    return true
end
local function Commit(value,reason)
    local ok,err=P:PrepareWrite(H.StoreId);if ok~=true then return false,err end
    ok,err=ValidateState(value);if ok~=true then return false,err end
    ok,err=P:SaveValue(H.StoreId,value,{durable=true,reason=reason})
    if ok~=true then return false,err or '历史保存失败，未应用本次合并' end
    -- 保存并回读成功后才发布内存状态；来源与金额属于同一提交，失败不能留下半次导入。
    H.state=value;H.loaded=true;H.lastDirtyAt=-10000;H.revision=H.revision+1;H.lastError=nil
    if S.Events and type(S.Events.Publish)=='function' then S.Events:Publish('v3.combat_analytics.feature_updated',reason) end
    return true
end
function H:RecordTransferDelta(delta,date,stamp)
    local sync=self.state.sync;if not sync then return true end
    local source=sync.sources[sync.localId]
    if not source then return false,'本地历史来源缺失，请保留存档并检查诊断' end
    for _,key in ipairs(C.liveKeys)do
        if C.counter(source.totals[key])+C.counter(delta[key])>MAX_COUNTER
            or C.counter(self.state.totals[key])+C.counter(delta[key])>MAX_COUNTER then return false,'历史累计超过精确数值范围' end
    end
    if not source.days[date] then
        local dates=Sorted(source.days)
        if #dates>=C.maxDays then
            local oldest=dates[1];local row=source.days[oldest]
            for _,key in ipairs(C.keys)do source.archive[key]=NumberText(C.counter(source.archive[key])+C.counter(row[key]))end
            source.archiveFrom=source.archiveFrom or oldest;source.archiveTo=oldest;source.days[oldest]=nil
        end
        source.days[date]=Snapshot(nil).totals
    end
    local row=source.days[date]
    for _,key in ipairs(C.liveKeys)do
        local amount=C.counter(delta[key])
        if amount>0 then row[key]=NumberText(C.counter(row[key])+amount);source.totals[key]=NumberText(C.counter(source.totals[key])+amount) end
    end
    source.serial=NumberText(C.counter(source.serial)+1)
    row.firstAt=row.firstAt or stamp;row.lastAt=stamp or row.lastAt
    source.firstAt=source.firstAt or stamp;source.lastAt=stamp or source.lastAt
    return true
end
function H:ExportTransfer()
    local ok,err=self:EnsureLoaded(true);if ok~=true then return nil,err end
    local identity;identity,err=Binding();if not identity then return nil,err end
    local value;value,err=Enroll(self.state);if not value then return nil,err end
    local lines={'RS-HISTORY-1|'..Hex(identity)}
    for _,id in ipairs(Sorted(value.sync.sources))do AppendSource(lines,id,value.sync.sources[id])end
    lines[#lines+1]='END';local payload=table.concat(lines,'\n')
    if #payload>MAX_BYTES then return nil,'历史超过单次导出容量，未生成不完整备份' end
    local hash;hash,err=Check(payload);if not hash then return nil,err end
    -- 第一次导出先耐久保存来源身份，重载后导出才会沿用同一条来源而非重复建账。
    ok,err=Commit(value,'personal_history_export');if ok~=true then return nil,err end
    local count=math.ceil(#payload/PART_BYTES);local parts={}
    for index=1,count do
        local chunk=payload:sub((index-1)*PART_BYTES+1,index*PART_BYTES)
        parts[index]=table.concat({'RSCH1',hash,#payload,index,count,#chunk,assert(Check(chunk))},'|')..'\n'..chunk
    end
    return {parts=parts,partCount=count,packageId=hash,totals=Copy(value.totals)}
end
local function ReadCounts(text)
    local fields=Split(text,',');if #fields~=#C.keys then return nil end
    local row={};for index,key in ipairs(C.keys)do if not Whole(fields[index]) then return nil end;row[key]=fields[index]end
    return row
end
local function ParsePayload(payload)
    local lines={};for line in (payload..'\n'):gmatch('([^\n]*)\n')do lines[#lines+1]=line;if #lines>33000 then return nil,'记录过多' end end
    local encoded=lines[1] and lines[1]:match('^RS%-HISTORY%-1|(%x+)$')
    local identity=encoded and Unhex(encoded,256);if not identity then return nil,'不是受支持的历史导出文本' end
    local sources,index={},2
    while lines[index]~='END' do
        local header=Split(lines[index] or '','|')
        if #header~=7 or header[1]~='S' or not OriginId(header[2]) or not Whole(header[3]) or sources[header[2]] then return nil,'来源记录无效或重复' end
        if #Sorted(sources)>=MAX_SOURCES then return nil,'来源超过16个' end
        local source={serial=header[3],days={}}
        for offset,key in ipairs({'firstAt','lastAt','archiveFrom','archiveTo'})do
            local value=Unhex(header[offset+3]);if value==nil then return nil,'日期说明编码无效' end
            source[key]=value~='' and value or nil
        end
        source.totals=ReadCounts((lines[index+1] or ''):match('^T|(.*)$') or '')
        source.archive=ReadCounts((lines[index+2] or ''):match('^A|(.*)$') or '')
        if not source.totals or not source.archive then return nil,'历史累计字段不完整' end
        index=index+3;local days=0
        while lines[index]~='E' do
            local fields=Split(lines[index] or '','|');days=days+1
            if #fields~=5 or fields[1]~='D' or days>C.maxDays or not (C.validDate(fields[2]) or fields[2]=='unknown') or source.days[fields[2]] then return nil,'每日记录无效、重复或超限' end
            local row=ReadCounts(fields[5]);local first,last=Unhex(fields[3]),Unhex(fields[4])
            if not row or first==nil or last==nil then return nil,'每日记录内容不完整' end
            row.firstAt=first~='' and first or nil;row.lastAt=last~='' and last or nil;source.days[fields[2]]=row
            index=index+1
        end
        local valid,err=ValidSnapshot(source);if valid~=true then return nil,err end
        sources[header[2]]=source;index=index+1
    end
    if index~=#lines or next(sources)==nil then return nil,'历史结尾或来源数量无效' end
    return {identity=identity,sources=sources}
end
local function LegacyOverlap(a,b)
    for date in pairs(a.days)do if b.days[date] then return true end end
    -- 早期归档丢失逐日边界时同样不能替用户猜测两份旧档是否独立。
    if a.archiveTo and (not b.firstAt or b.firstAt:sub(1,10)<=a.archiveTo) then return true end
    if b.archiveTo and (not a.firstAt or a.firstAt:sub(1,10)<=b.archiveTo) then return true end
    return false
end
function H:MergeTransfer(parsed,packageId,options)
    local ready,err=self:EnsureLoaded(true);if ready~=true then return false,err end
    local identity;identity,err=Binding();if not identity then return false,err end
    if parsed.identity~=identity then return false,'导出属于另一个角色/服务器，未合并' end
    local value;value,err=Enroll(self.state,parsed.sources);if not value then return false,err end
    local changed=self.state.sync==nil;local overlap=false;local previousLegacy={}
    for id,source in pairs(value.sync.sources)do if id:sub(1,2)=='l-' then previousLegacy[id]=source end end
    for id,incoming in pairs(parsed.sources)do
        local old=value.sync.sources[id]
        if not old then
            if id:sub(1,2)=='l-' then
                for other,source in pairs(previousLegacy)do if other~=id and LegacyOverlap(source,incoming) then overlap=true end end
            end
            value.sync.sources[id]=Copy(incoming);changed=true
        elseif C.counter(incoming.serial)>C.counter(old.serial) then
            if id==value.sync.localId then return false,'本地来源出现并行写入冲突，请保留两台存档后检查；未覆盖本机记录' end
            for _,key in ipairs(C.keys)do if C.counter(incoming.totals[key])<C.counter(old.totals[key]) then return false,'较新来源的累计倒退，未合并' end end
            value.sync.sources[id]=Copy(incoming);changed=true
        elseif incoming.serial==old.serial and SourceText(id,incoming)~=SourceText(id,old) then
            return false,'同一来源版本的内容冲突，未合并'
        end
    end
    if overlap and (type(options)~='table' or options.confirmPackageId~=packageId) then
        return true,{complete=false,requiresConfirmation=true,packageId=packageId,
            warning='两份启用同步前的旧历史有重叠日期。若曾复制存档，可能重复；确认是独立记录后再次点击“导入合并”。'}
    end
    if changed then
        value=self:NormalizeState(value);local ok;ok,err=Commit(value,'personal_history_import');if ok~=true then return false,err end
    end
    return true,{complete=true,changed=changed,totals=Copy(value.totals)}
end
function H:ImportTransfer(text,options)
    -- 分段只存在于临时缓冲中；缺段、混包、截断或校验失败绝不触碰历史 Store。
    if type(text)~='string' or #text>8192 then return false,'请逐段粘贴导出内容，每段不超过8192字节' end
    text=text:gsub('\r\n','\n'):gsub('^%s+','')
    local header,body=text:match('^([^\n]+)\n(.*)$')
    local fields=Split(header or '','|')
    if #fields~=7 or fields[1]~='RSCH1' or not fields[2]:match('^%x%x%x%x%x%x%x%x$') or not fields[7]:match('^%x%x%x%x%x%x%x%x$') then return false,'历史导出头不完整或格式不支持' end
    local size,index,count,bytes=Whole(fields[3]),Whole(fields[4]),Whole(fields[5]),Whole(fields[6])
    if not size or size<1 or size>MAX_BYTES or not index or not count or index<1 or index>count or count~=math.ceil(size/PART_BYTES)
        or not bytes or bytes~=math.min(PART_BYTES,size-(index-1)*PART_BYTES) or not body or #body<bytes
        or not body:sub(bytes+1):match('^%s*$') then return false,'历史分段长度不完整，请重新复制该段' end
    body=body:sub(1,bytes)
    if Check(body)~=fields[7] then return false,'历史分段校验失败，可能被截断或改写' end
    local session=self.importSession
    if session and (session.id~=fields[2] or session.size~=size or session.count~=count) then return false,'正在接收另一份历史，请先点“清除输入”再换一份' end
    if not session then session={id=fields[2],size=size,count=count,parts={},received=0};self.importSession=session end
    if session.parts[index] and session.parts[index]~=body then return false,'同一分段的内容冲突' end
    if not session.parts[index] then session.parts[index]=body;session.received=session.received+1 end
    if session.received<count then return true,{complete=false,received=session.received,total=count} end
    local payload=table.concat(session.parts)
    if #payload~=size or Check(payload)~=session.id then self.importSession=nil;return false,'整份历史校验失败，未合并' end
    local parsed,err=ParsePayload(payload);if not parsed then self.importSession=nil;return false,err end
    local ok,result=self:MergeTransfer(parsed,session.id,options)
    if ok~=true or (result and result.complete) then self.importSession=nil end
    return ok,result
end
F.Commands=F.Commands or {}
function F.Commands:ExportPersonalHistory() return H:ExportTransfer() end
function F.Commands:ImportPersonalHistory(text,options) return H:ImportTransfer(text,options) end
function F.Commands:ClearPersonalHistoryImport() H.importSession=nil;return true end -- 只丢弃未提交的复制缓冲，不删除历史。
