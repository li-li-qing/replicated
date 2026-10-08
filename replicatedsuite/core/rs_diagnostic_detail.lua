------------------------------------------------------------------------
-- 中文维护（2026-10-02）：TXT 详细证据格式器。只消费已有 primitive 快照，逐字段写路径、
-- 类型与值；不读取 Native、不执行函数/元方法、不持有业务对象。界面摘要与文件证据共用
-- 同一次采集，翻页/导出不重跑 Provider。所有保护限制均输出遗漏位置，不伪称全量历史。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.DiagnosticDetail = { version = 1 }
local F = S.DiagnosticDetail
local function Cut(text, limit)
    if #text <= limit then return text end
    local n = limit
    while n > 0 and (text:byte(n + 1) or 0) >= 128 and (text:byte(n + 1) or 0) < 192 do n = n - 1 end
    return text:sub(1, n)
end
local function Quoted(text, plain)
    -- 旧 Native 截断字符串可能含半个中文；以原始字节转义，不能让 TXT 的 UTF-8 解码失败。
    local out, index = {plain and '' or '"'}, 1
    while index <= #text do
        local byte=text:byte(index)
        if byte < 128 then
            local stop=text:find('[\128-\255]',index) or (#text+1)
            local part=text:sub(index,stop-1)
            if not plain then part=part:gsub('\\','\\\\'):gsub('"','\\"') end
            part=part:gsub('[%c]',function(c)
                if plain and (c=='\n' or c=='\r' or c=='\t') then return c end
                return string.format('\\x%02X',c:byte())
            end)
            out[#out+1]=part;index=stop
        else
        local width=byte<128 and 1 or (byte>=194 and byte<=223 and 2 or (byte>=224 and byte<=239 and 3 or (byte>=240 and byte<=244 and 4 or 0)))
        local valid=width>0 and index+width-1<=#text
        if valid and width>1 then
            for offset=1,width-1 do local tail=text:byte(index+offset);if tail<128 or tail>191 then valid=false;break end end
            local second=text:byte(index+1)
            if (byte==224 and second<160) or (byte==237 and second>159) or (byte==240 and second<144) or (byte==244 and second>143) then valid=false end
        end
        if not valid or byte<32 or byte==127 then out[#out+1]=string.format('\\x%02X',byte);index=index+1
        else
            local part=text:sub(index,index+width-1)
            out[#out+1]=(part=='"' or part=='\\') and ('\\'..part) or part;index=index+width
        end
        end
    end
    out[#out+1]=plain and '' or '"';return table.concat(out)
end
local function Limits(options)
    options = options or {}
    return { totalBytes = options.totalBytes or 786432, sourceBytes = options.sourceBytes or 393216,
        nodes = options.nodes or 16384, depth = options.depth or 12, keys = options.keys or 2048,
        stringBytes = options.stringBytes or 32768 }
end
local function Keys(value, maximum)
    local keys, visited, unsupported = {}, 0, 0
    for key in next, value do
        visited = visited + 1
        if visited > maximum then break end
        if type(key) == 'string' or type(key) == 'number' then keys[#keys + 1] = key else unsupported = unsupported + 1 end
    end
    table.sort(keys, function(a, b)
        if type(a) ~= type(b) then return type(a) < type(b) end
        return a < b
    end)
    return keys, visited > maximum, unsupported
end
local function Path(parent, key)
    return parent .. '[' .. (type(key) == 'number' and tostring(key) or Quoted(Cut(key, 256))) .. ']'
end
function F:New(options)
    local limits = Limits(options)
    local w = { limits = limits, lines = {}, bytes = 0, partial = false, omitted = 0, sources = 0 }
    function w:Add(label, value)
        self.sources = self.sources + 1
        local used, nodes, seen, lastPath = 0, 0, {}, label
        local function Emit(line, force)
            local needed = #line + 1
            if not force and (used + needed > limits.sourceBytes - 512 or self.bytes + needed > limits.totalBytes - 2048) then
                error('byte_limit', 0)
            end
            if self.bytes + needed > limits.totalBytes then return false end
            self.lines[#self.lines + 1] = line; used = used + needed; self.bytes = self.bytes + needed
            return true
        end
        local function Omit(path, reason)
            self.partial = true; self.omitted = self.omitted + 1
            return Emit(path .. ' = <OMITTED reason=' .. reason .. '>', true)
        end
        local function Walk(item, path, depth)
            lastPath = path; nodes = nodes + 1
            if nodes > limits.nodes then Omit(path, 'source_node_limit'); return false end
            local kind = type(item)
            if kind == 'string' then
                local clipped = Cut(item, limits.stringBytes)
                Emit(path .. ' = (string bytes=' .. #item .. ') ' .. Quoted(clipped))
                if #clipped < #item then Omit(path, 'string_bytes kept=' .. #clipped .. ' original=' .. #item) end
            elseif kind == 'number' or kind == 'boolean' or kind == 'nil' then
                Emit(path .. ' = (' .. kind .. ') ' .. tostring(item))
            elseif kind ~= 'table' then Emit(path .. ' = <not_serialized type=' .. kind .. '>')
            elseif seen[item] then Emit(path .. ' = <cycle target=' .. seen[item] .. '>')
            elseif depth >= limits.depth then Omit(path, 'depth_limit')
            else
                seen[item] = path
                local keys, more, unsupported = Keys(item, limits.keys)
                Emit(path .. ' = (table keysKept=' .. #keys .. ')')
                for _, key in ipairs(keys) do
                    local childPath = Path(path, key)
                    if type(key) == 'string' and #key > 256 then Omit(childPath, 'key_bytes original=' .. #key) end
                    if Walk(rawget(item, key), childPath, depth + 1) == false then seen[item] = nil; return false end
                end
                if more then Omit(path, 'table_keys kept=' .. #keys .. ' additional=at_least_1') end
                if unsupported > 0 then Omit(path, 'non_primitive_keys count=' .. unsupported) end
                seen[item] = nil
            end
            return true
        end
        local ok, err = pcall(function() Emit('[DETAIL_SOURCE ' .. label .. ']'); Walk(value, label, 0) end)
        if not ok then Omit(lastPath, 'source_stopped ' .. tostring(err)) end
        Emit('[DETAIL_SOURCE_END ' .. label .. ' nodes=' .. nodes .. ' bytes=' .. used .. ']', true)
    end
    function w:Finish(prefix, maximum)
        maximum = maximum or 1048576
        prefix = Quoted(tostring(prefix or ''), true)
        if #prefix > maximum - 4096 then prefix = Cut(prefix, maximum - 4096) .. '\n<SUMMARY_OMITTED reason=file_byte_limit>' end
        local out = { prefix, '\nRS-DIAGNOSTIC-DETAIL-1\n'
            .. 'READING=前半段为兼容界面摘要；下方 DETAIL_SOURCE 为逐字段证据；OMITTED 会列出具体遗漏路径。\n'
            .. 'COVERAGE=本次冻结的已采集状态；未执行的查询、未收到的回包、已淘汰或重载前历史不能补回。\n'
            .. 'LIMITS totalBytes=' .. limits.totalBytes .. ' sourceBytes=' .. limits.sourceBytes .. ' nodesPerSource=' .. limits.nodes
            .. ' depth=' .. limits.depth .. ' keysPerTable=' .. limits.keys .. ' stringBytes=' .. limits.stringBytes .. '\n' }
        local bytes = #out[1] + #out[2]
        for index, line in ipairs(self.lines) do
            if bytes + #line + 1 > maximum - 512 then
                self.partial = true; self.omitted = self.omitted + 1
                out[#out + 1] = '<OMITTED reason=file_byte_limit remainingLines=' .. (#self.lines - index + 1) .. '>\n'; break
            end
            out[#out + 1] = line .. '\n'; bytes = bytes + #line + 1
        end
        out[#out + 1] = 'DETAIL_RESULT sources=' .. self.sources .. ' serializationPartial=' .. tostring(self.partial) .. ' omissions=' .. self.omitted
            .. '\nRS-DIAGNOSTIC-DETAIL-END\n'
        return table.concat(out), { partial = self.partial, omissions = self.omitted, sources = self.sources }
    end
    return w
end
function F:Detach(value, options)
    local limits, seen, nodes = Limits(options), {}, 0
    local function Walk(item, depth)
        nodes = nodes + 1
        if nodes > limits.nodes then return '<OMITTED node_limit>' end
        local kind = type(item)
        if kind == 'string' then
            local clipped = Cut(item, limits.stringBytes)
            return #clipped < #item and (clipped .. '<OMITTED string original=' .. #item .. '>') or item
        end
        if kind == 'number' or kind == 'boolean' or kind == 'nil' then return item end
        if kind ~= 'table' then return '<not_serialized type=' .. kind .. '>' end
        if seen[item] then return '<cycle>' end
        if depth >= limits.depth then return '<OMITTED depth_limit>' end
        seen[item] = true
        local keys, more, unsupported = Keys(item, limits.keys)
        local out = {}
        for _, key in ipairs(keys) do
            if nodes >= limits.nodes then out.__diagnosticOmitted = 'node_limit'; break end
            if not (options and options.excludeKeys and options.excludeKeys[key]) then out[key] = Walk(rawget(item, key), depth + 1) end
        end
        if more or unsupported > 0 then out.__diagnosticOmitted = 'key_limit_or_non_primitive_keys' end
        seen[item] = nil
        return out
    end
    return Walk(value, 0)
end
