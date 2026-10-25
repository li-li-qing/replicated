-- Replicated Suite · 无损报告复制编码
-- 作者：Replicated
-- QQ群：1104129461
-- 只编码复制文本，原报告由 Diagnostics 保留；不访问 Native、磁盘或剪贴板，展示端仍须 Set/GetText 回读。
-- RS-REPORT-COPY-1 由离线工具逐字节解码，旧 RS-SELF-CHECK-1 原文仍兼容。
-- LZB1 窗口/哈希槽均为 65536，每位置一候选、最长 259 字节。Adler32 只检测复制损坏，编码仍含敏感字段。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local T = {version=1, MaxInputBytes=1048576, PreferredCopyBytes=32768}
S.ReportCopyTransport=T
local floor, byte, char = math.floor, string.byte, string.char
local ALPHABET='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function Checksum(text)
    local a,b=1,0
    for i=1,#text do a=(a+byte(text,i))%65521;b=(b+a)%65521 end
    return string.format('%08X',b*65536+a)
end
-- 复用同一个Adler32实现验证单次故障摘录的复制边界；不是存档FP/安全认证。
-- 仅点击冷路径处理有界文本，不访问Native，不引入第二套业务序列化算法。
function T:CopyChecksum(text)
    if type(text)~='string' or #text>self.MaxInputBytes then return nil,'copy_checksum_input_limit' end
    return Checksum(text)
end
local function Hash(text,index)
    local a,b,c,d=byte(text,index,index+3)
    if not d then return nil end
    return (((a*33+b)*33+c)*33+d)%65536
end
local function Compress(text)
    -- flags 每组8 token，bit=1: [距离-1 big-endian u16][长度-4 u8]；bit=0: 原字节。
    -- 解码允许自重叠（如AAAA），距离1..65536、长度4..259；尾组未用flag必须为0。
    -- 哈希只留最新位置，不建无界字典/匹配链；每个消费位置最多比较一个有界候选。
    local positions,groups={},{}
    local index,size=1,#text
    while index<=size do
        local tokens,flags,bit={},0,1
        for _=1,8 do
            if index>size then break end
            local hash=Hash(text,index)
            local previous=hash and positions[hash] or nil
            local length=0
            if previous and index-previous<=65536 then
                local limit=math.min(259,size-index+1)
                while length<limit and byte(text,previous+length)==byte(text,index+length) do length=length+1 end
            end
            if length>=4 then
                local distance=index-previous-1
                tokens[#tokens+1]=char(floor(distance/256),distance%256,length-4)
                flags=flags+bit
            else
                length=1;tokens[#tokens+1]=text:sub(index,index)
            end
            for pos=index,index+length-1 do
                local key=Hash(text,pos);if key then positions[key]=pos end
            end
            index=index+length;bit=bit*2
        end
        groups[#groups+1]=char(flags)..table.concat(tokens)
    end
    return table.concat(groups)
end
local function Base64(text)
    local lines,pieces={},{}
    for i=1,#text,3 do
        local a,b,c=byte(text,i,i+2)
        local n=a*65536+(b or 0)*256+(c or 0)
        local p=floor(n/262144)%64+1;local q=floor(n/4096)%64+1
        local r=floor(n/64)%64+1;local s=n%64+1
        pieces[#pieces+1]=ALPHABET:sub(p,p)..ALPHABET:sub(q,q)..(b and ALPHABET:sub(r,r) or '=')..(c and ALPHABET:sub(s,s) or '=')
        if #pieces==30 then lines[#lines+1]=table.concat(pieces);pieces={} end
    end
    if #pieces>0 then lines[#lines+1]=table.concat(pieces) end
    return table.concat(lines,'\n')
end
function T:Encode(text)
    if type(text)~='string' then return nil,'copy_text_required' end
    if #text>self.MaxInputBytes then return nil,'copy_input_limit' end
    local packed=Compress(text)
    local codec='LZB1'
    -- 不可压缩文本不应膨胀为冗余匹配流；Native 接收预算由页面最终检查，超限明确失败。
    if #packed>=#text then packed=text;codec='RAW64' end
    local out='RS-REPORT-COPY-1\nCODEC='..codec..'\nRAW_BYTES='..#text..'\nPACKED_BYTES='..#packed
        ..'\nCHECK='..Checksum(text)..'\nDATA64=\n'..Base64(packed)..'\nRS-REPORT-COPY-END'
    return out,{codec=codec,rawBytes=#text,packedBytes=#packed,copyBytes=#out}
end

-- 实机输入框只接收 9215 字节，而复制包曾达 38011 字节；压缩无法保证缩短，需有限分段。
-- 每段附身份、偏移、长度及分段/整包校验，集齐后才还原。最多 256 段，每段 <=32KiB，离页释放 session。
-- 页面管理当前段和键盘，编码器不调用 Native 或写 SaveData。
T.MaxEditorBytes=32768
T.UnknownEditorBytes=8192
T.MaxParts=256
local function WholeNumber(value, minimum, maximum)
    return type(value)=='number' and value==value and value>=minimum and value<=maximum and value==floor(value)
end
function T:BuildDelivery(text, reportId, capacity)
    if type(text)~='string' then return nil,'copy_text_required' end
    if #text>self.MaxInputBytes then return nil,'copy_input_limit' end
    if not WholeNumber(capacity,1,self.MaxInputBytes) then return nil,'copy_capacity_invalid' end
    if type(reportId)~='string' or #reportId<1 or #reportId>64 or reportId:find('[^%w_.%-]') then
        return nil,'copy_report_id_invalid'
    end
    capacity=math.min(capacity,self.MaxEditorBytes)
    local session={version=1,id=reportId,capacity=capacity,rawBytes=#text,parts=1,kind='plain',payload=text}
    if #text<=capacity then return session end
    local payload,info=self:Encode(text)
    if not payload then return nil,info end
    session.payload,session.kind=payload,'packed'
    if #payload<=capacity then return session end
    if capacity<512 then return nil,'copy_native_capacity_too_small:'..capacity end
    -- 分段正文为ASCII复制包，切任何字节均不拆中文；预留头尾+CRLF换行余量，
    -- 不将报告本体逐字段截断。只缓存一份payload，按需要生成当前段，避免常驻N份副本。
    session.chunkBytes=capacity-384-floor(capacity/80)
    session.parts=math.ceil(#payload/session.chunkBytes)
    if session.parts>self.MaxParts then return nil,'copy_parts_limit:'..session.parts end
    session.kind,session.checksum='part',Checksum(payload)
    return session
end
function T:GetDeliveryPart(session,index)
    if type(session)~='table' or session.version~=1 or type(session.payload)~='string'
        or not WholeNumber(session.parts,1,self.MaxParts) or not WholeNumber(index,1,session.parts) then
        return nil,'copy_part_invalid'
    end
    if session.parts==1 and session.wire~='flat2' then return session.payload end
    if not WholeNumber(session.chunkBytes,1,self.MaxEditorBytes) then return nil,'copy_part_size_invalid' end
    local offset=(index-1)*session.chunkBytes
    local data=session.payload:sub(offset+1,offset+session.chunkBytes)
    -- flat2只转义已编码的ASCII复制包，绝不改原始报告/存档。
    -- ~是唯一LF转义符，Encode的固定头和Base64字母表本来不含~或分号；单行框架不
    -- 依赖Native保留硬换行。接收工具只对flat2忽略传输层空白，并核验原长度和全部校验。
    if session.wire=='flat2' then
        if data:find('[~;\r \t]') then return nil,'copy_flat_alphabet_invalid' end
        local text='RS-REPORT-PART-2;ID='..session.id..';PART='..index..'/'..session.parts
            ..';TOTAL_BYTES='..#session.payload..';TOTAL_CHECK='..session.checksum
            ..';OFFSET='..offset..';DATA_BYTES='..#data..';DATA_CHECK='..Checksum(data)
            ..';DATA='..data:gsub('\n','~')..';RS-REPORT-PART-END'
        if #text>session.capacity then return nil,'copy_part_capacity_exceeded' end
        return text
    end
    local text='RS-REPORT-PART-1\nID='..session.id..'\nPART='..index..'/'..session.parts
        ..'\nTOTAL_BYTES='..#session.payload..'\nTOTAL_CHECK='..session.checksum
        ..'\nOFFSET='..offset..'\nDATA_BYTES='..#data..'\nDATA_CHECK='..Checksum(data)
        ..'\nDATA=\n'..data..'\nRS-REPORT-PART-END'
    if #text>session.capacity then return nil,'copy_part_capacity_exceeded' end
    return text
end


-- MaxTextLength 不保证 SetText/GetText 往返无损。这里只重分帧和比较，Native 交付由 Presentation 处理。
-- 仅首段交付前协商预算，已交付段不重编号；缩容复用原编码包，不改 reportId 或重采证据。
T.MaxWriteAttempts=8
T.MinEditorBytes=512
function T:ReframeDelivery(session,capacity,wire)
    if type(session)~='table' or session.version~=1 or type(session.payload)~='string'
        or not WholeNumber(capacity,self.MinEditorBytes,self.MaxEditorBytes) or wire~='flat2' then
        return nil,'copy_reframe_invalid'
    end
    local payload=session.payload
    if session.kind=='plain' then
        local value,err=self:Encode(payload)
        if not value then return nil,err end
        payload=value
    end
    if payload:find('[~;\r \t]') or not payload:match('^RS%-REPORT%-COPY%-1\n') then
        return nil,'copy_flat_alphabet_invalid'
    end
    local chunk=capacity-384-floor(capacity/80)
    local total=math.max(1,math.ceil(#payload/chunk))
    if total>self.MaxParts then return nil,'copy_parts_limit:'..total end
    return {version=1,id=session.id,capacity=capacity,rawBytes=session.rawBytes,
        parts=total,kind=total>1 and 'part' or 'packed',wire=wire,payload=payload,
        chunkBytes=chunk,checksum=session.checksum or Checksum(payload)}
end
function T:VerifyEditorReadback(session,expected,actual)
    local trace={sent=#expected,received=type(actual)=='string' and #actual or -1,
        readType=type(actual),capacity=session.capacity,wire=session.wire or 'legacy'}
    if type(actual)~='string' then trace.difference=0;return false,trace end
    local compare
    if session.wire=='flat2' then
        -- 仅外层ASCII编码允许这些空白；UTF-8原文、Evidence和Base64解码后的字节不变。
        -- 不删非空白、不接受部分前缀，也不把同长度误当一致。解码器必须实施同一规则。
        compare=actual:gsub('[ \t\r\n]','')
    else compare=actual:gsub('\r\n','\n') end
    trace.observed=#compare
    if compare==expected then trace.difference=0;return true,trace end
    local limit=math.min(#expected,#compare)
    local index=1
    while index<=limit and byte(expected,index)==byte(compare,index) do index=index+1 end
    trace.difference=index
    trace.expectedByte=byte(expected,index) or -1
    trace.actualByte=byte(compare,index) or -1
    trace.prefix=index==#compare+1 and #compare<#expected
    return false,trace
end
function T:FormatReadback(trace)
    if type(trace)~='table' then return '' end
    -- 聊天只能复制一条：只输出数值/类型和调用状态，不输出存档内容/长错误栈；上限有界。
    local write=trace.writeOk==false and 'throw' or (trace.writeRejected and 'reject' or 'ok')
    local read=trace.readOk==false and 'throw' or tostring(trace.readType or '?')
    local expected=trace.expectedByte and trace.expectedByte>=0 and string.format('%02X',trace.expectedByte) or 'EOF'
    local actual=trace.actualByte and trace.actualByte>=0 and string.format('%02X',trace.actualByte) or 'EOF'
    return 'rb='..tostring(trace.sent or -1)..'/'..tostring(trace.received or -1)
        ..'@'..tostring(trace.difference or 0)..' cap='..tostring(trace.capacity or 0)
        ..' try='..tostring(trace.attempts or 1)..' wire='..tostring(trace.wire or '?')
        ..' w='..write..' g='..read
        ..(trace.difference and trace.difference>0 and (' hex='..expected..'/'..actual) or '')
end

-- 将冻结的完整文本按 UTF-8 边界分页；翻页不重新采集或读取存档。
-- 换行、回车和反斜杠可逆转义，规避 RU 多行框吞换行。校验只用于复制完整性，旧协议保留兼容。
T.TextPageContractVersion=1
function T:BuildTextPages(text,capacity,reportId)
    if type(text)~='string' or #text>self.MaxInputBytes then return nil,'text_page_input_limit' end
    capacity=tonumber(capacity)
    if not capacity or capacity~=capacity or capacity<512 or capacity>32768 then return nil,'text_page_capacity' end
    capacity=floor(capacity)
    local id=tostring(reportId or '')
    if #id<1 or #id>48 or id:find('[^%w%.%-%_]') then return nil,'text_page_id' end
    local wire=text:gsub('\\','\\\\'):gsub('\r','\\r'):gsub('\n','\\n')
    local bounds,offset={},0
    local payloadCap=capacity-256
    repeat
        local finish=math.min(#wire,offset+payloadCap)
        -- 下一个字节是continuation表示切在字内；只退到本字符起点，不能删任何字节。
        while finish>offset do local b=byte(wire,finish+1);if not b or b<128 or b>=192 then break end;finish=finish-1 end
        if finish<=offset and #wire>0 then return nil,'text_page_boundary' end
        bounds[#bounds+1]={offset=offset,length=finish-offset};offset=finish
        if #bounds>8192 then return nil,'text_page_count_limit' end
    until offset>=#wire
    return {kind='text_pages',wire='error_pages1',id=id,capacity=capacity,parts=#bounds,bounds=bounds,
        text=wire,totalBytes=#wire,totalCheck=Checksum(wire),rawBytes=#text,rawCheck=Checksum(text)}
end
function T:GetTextPage(session,index)
    if type(session)~='table' or session.kind~='text_pages' then return nil,'text_page_session' end
    index=tonumber(index)
    if not index or index~=floor(index) or index<1 or index>session.parts then return nil,'text_page_index' end
    local item=session.bounds[index];local data=session.text:sub(item.offset+1,item.offset+item.length)
    local text='RS-ERROR-PAGE-1;ID='..session.id..';PAGE='..index..'/'..session.parts
        ..';TOTAL_BYTES='..session.totalBytes..';TOTAL_CHECK='..session.totalCheck
        ..';RAW_BYTES='..session.rawBytes..';RAW_CHECK='..session.rawCheck..';OFFSET='..item.offset
        ..';DATA_BYTES='..#data..';DATA_CHECK='..Checksum(data)..';DATA='..data..';RS-ERROR-PAGE-END'
    if #text>session.capacity then return nil,'text_page_header_limit' end
    return text
end
