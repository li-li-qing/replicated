-- Replicated Suite · 持久化传输编码
-- 作者：Replicated
-- QQ群：1104129461
-- 纯值与传输编码转换；承载用户配置磁盘格式，行为变化须验证已有存档兼容。
-- 不持有领域事实、不读写 Store、不执行完整性验证；必须先于 core/rs_persistence.lua 加载（见 toc.g）。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite

local T = {}
S.PersistenceTransport = T

local TRANSPORT_V1_PREFIX = "__rs_t1:"
local TRANSPORT_V1_FALSE = TRANSPORT_V1_PREFIX .. "f"
local TRANSPORT_V1_EMPTY = TRANSPORT_V1_PREFIX .. "e"
local TRANSPORT_V1_STRING = TRANSPORT_V1_PREFIX .. "s"
local TRANSPORT_V2_PREFIX = "__rs_t2:"
local TRANSPORT_V2_FALSE = TRANSPORT_V2_PREFIX .. "f"
local TRANSPORT_V2_EMPTY_TABLE = TRANSPORT_V2_PREFIX .. "t"
local TRANSPORT_V2_ZERO = TRANSPORT_V2_PREFIX .. "z"
local TRANSPORT_V2_EMPTY_STRING = TRANSPORT_V2_PREFIX .. "e"
local TRANSPORT_V2_STRING = TRANSPORT_V2_PREFIX .. "s"

local function TransportEncodeValueV1(value, seen) -- 只用于兼容 Harness/历史语义说明；生产新写由 v3 承担。
    local kind = type(value)
    if kind == "boolean" then return value == false and TRANSPORT_V1_FALSE or true, nil end
    if kind == "string" then
        if value:sub(1, #TRANSPORT_V1_PREFIX) == TRANSPORT_V1_PREFIX then return TRANSPORT_V1_STRING .. value, nil end
        return value, nil
    end
    if kind ~= "table" then return value, nil end
    if next(value) == nil then return TRANSPORT_V1_EMPTY, nil end
    seen = seen or {}
    if seen[value] ~= nil then return nil, "transport_cycle" end
    seen[value] = true
    local out = {}
    for key, child in pairs(value) do
        local encodedKey, keyErr = TransportEncodeValueV1(key, seen)
        if keyErr ~= nil then seen[value] = nil; return nil, keyErr end
        local encodedChild, childErr = TransportEncodeValueV1(child, seen)
        if childErr ~= nil then seen[value] = nil; return nil, childErr end
        out[encodedKey] = encodedChild
    end
    seen[value] = nil
    return out, nil
end

local function TransportDecodeValueV1(value, seen) -- 保留 v1 解码，旧档升级无需清配置。
    local kind = type(value)
    if kind == "string" then
        if value == TRANSPORT_V1_FALSE then return false, nil end
        if value == TRANSPORT_V1_EMPTY then return {}, nil end
        if value:sub(1, #TRANSPORT_V1_STRING) == TRANSPORT_V1_STRING then return value:sub(#TRANSPORT_V1_STRING + 1), nil end
        if value:sub(1, #TRANSPORT_V1_PREFIX) == TRANSPORT_V1_PREFIX then return nil, "unknown_transport_token_v1" end
        return value, nil
    end
    if kind ~= "table" then return value, nil end
    seen = seen or {}
    if seen[value] ~= nil then return nil, "transport_cycle" end
    seen[value] = true
    local out = {}
    for key, child in pairs(value) do
        local decodedKey, keyErr = TransportDecodeValueV1(key, seen)
        if keyErr ~= nil then seen[value] = nil; return nil, keyErr end
        local decodedChild, childErr = TransportDecodeValueV1(child, seen)
        if childErr ~= nil then seen[value] = nil; return nil, childErr end
        out[decodedKey] = decodedChild
    end
    seen[value] = nil
    return out, nil
end

local function TransportEncodeValueV2(value, seen) -- 保留 v2 原语义；非零数值的保护由 v3 处理。
    local kind = type(value)
    if kind == "boolean" then return value == false and TRANSPORT_V2_FALSE or true, nil end
    if kind == "number" then return value == 0 and TRANSPORT_V2_ZERO or value, nil end
    if kind == "string" then
        if value == "" then return TRANSPORT_V2_EMPTY_STRING, nil end
        if value:sub(1, #TRANSPORT_V2_PREFIX) == TRANSPORT_V2_PREFIX then return TRANSPORT_V2_STRING .. value, nil end
        return value, nil
    end
    if kind ~= "table" then return value, nil end
    if next(value) == nil then return TRANSPORT_V2_EMPTY_TABLE, nil end
    seen = seen or {}
    if seen[value] ~= nil then return nil, "transport_cycle" end
    seen[value] = true
    local out = {}
    for key, child in pairs(value) do
        local encodedKey, keyErr = TransportEncodeValueV2(key, seen)
        if keyErr ~= nil then seen[value] = nil; return nil, keyErr end
        local encodedChild, childErr = TransportEncodeValueV2(child, seen)
        if childErr ~= nil then seen[value] = nil; return nil, childErr end
        out[encodedKey] = encodedChild
    end
    seen[value] = nil
    return out, nil
end

local function TransportDecodeValueV2(value, seen) -- v2 只识别 `__rs_t2:`，因此真实业务字符串即使以旧 `__rs_t1:`
                                                   -- 开头也不会被误解；v2 自身前缀在写前必定转义。
    local kind = type(value)
    if kind == "string" then
        if value == TRANSPORT_V2_FALSE then return false, nil end
        if value == TRANSPORT_V2_EMPTY_TABLE then return {}, nil end
        if value == TRANSPORT_V2_ZERO then return 0, nil end
        if value == TRANSPORT_V2_EMPTY_STRING then return "", nil end
        if value:sub(1, #TRANSPORT_V2_STRING) == TRANSPORT_V2_STRING then return value:sub(#TRANSPORT_V2_STRING + 1), nil end
        if value:sub(1, #TRANSPORT_V2_PREFIX) == TRANSPORT_V2_PREFIX then return nil, "unknown_transport_token_v2" end
        return value, nil
    end
    if kind ~= "table" then return value, nil end
    seen = seen or {}
    if seen[value] ~= nil then return nil, "transport_cycle" end
    seen[value] = true
    local out = {}
    for key, child in pairs(value) do
        local decodedKey, keyErr = TransportDecodeValueV2(key, seen)
        if keyErr ~= nil then seen[value] = nil; return nil, keyErr end
        local decodedChild, childErr = TransportDecodeValueV2(child, seen)
        if childErr ~= nil then seen[value] = nil; return nil, childErr end
        out[decodedKey] = decodedChild
    end
    seen[value] = nil
    return out, nil
end

-- 真实跑商中心值曾从旧 token 0.0903896 变为 Native 0.09038999676704407（token 0.09039）。
-- 六位有效数字指纹无法抵抗固定六位小数再转单精度；v3 用 17 位往返文本保护非整数和 binary32 连续整数区间外的值（含键）。
-- 非负小整数/路由仍用 Native number；编码串计入原预算，健康旧档不批量重写。
local TRANSPORT_V3_PREFIX = "__rs_t3:"
local TRANSPORT_V3_FALSE = TRANSPORT_V3_PREFIX .. "f"
local TRANSPORT_V3_EMPTY_TABLE = TRANSPORT_V3_PREFIX .. "t"
local TRANSPORT_V3_ZERO = TRANSPORT_V3_PREFIX .. "z"
local TRANSPORT_V3_EMPTY_STRING = TRANSPORT_V3_PREFIX .. "e"
local TRANSPORT_V3_STRING = TRANSPORT_V3_PREFIX .. "s"
local TRANSPORT_V3_NUMBER = TRANSPORT_V3_PREFIX .. "n"
local NATIVE_EXACT_INTEGER_LIMIT = 16777216

local function TransportEncodeValueV3(value, seen)
    local kind = type(value)
    if kind == "boolean" then return value == false and TRANSPORT_V3_FALSE or true, nil end
    if kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return nil, "transport_nonfinite_v3" end
        if value == 0 then return TRANSPORT_V3_ZERO, nil end
        -- 实机曾把 buffs.y=-2 回读为 0，具体是省略还是置零尚不明确，因此负整数也走已兼容的 n-token。
        -- 旧裸负整数仍可读，正整数 ID/路由不变；不能改成 0 或放宽 stamped/expected/actual 校验。
        if value > 0 and value == math.floor(value) and value <= NATIVE_EXACT_INTEGER_LIMIT then return value, nil end
        return TRANSPORT_V3_NUMBER .. string.format("%.17g", value), nil
    end
    if kind == "string" then
        if value == "" then return TRANSPORT_V3_EMPTY_STRING, nil end
        if value:sub(1, #TRANSPORT_V3_PREFIX) == TRANSPORT_V3_PREFIX then return TRANSPORT_V3_STRING .. value, nil end
        return value, nil
    end
    if kind ~= "table" then return nil, "transport_type_v3:" .. kind end
    if next(value) == nil then return TRANSPORT_V3_EMPTY_TABLE, nil end
    seen = seen or {}
    if seen[value] ~= nil then return nil, "transport_cycle" end
    seen[value] = true
    local out = {}
    for key, child in pairs(value) do
        if type(key) ~= "number" and type(key) ~= "string" then seen[value] = nil; return nil, "transport_key_type_v3" end
        local encodedKey, keyErr = TransportEncodeValueV3(key, seen)
        if keyErr ~= nil then seen[value] = nil; return nil, keyErr end
        local encodedChild, childErr = TransportEncodeValueV3(child, seen)
        if childErr ~= nil then seen[value] = nil; return nil, childErr end
        if out[encodedKey] ~= nil then seen[value] = nil; return nil, "transport_key_collision_v3" end
        out[encodedKey] = encodedChild
    end
    seen[value] = nil
    return out, nil
end

-- C runtime 可能把同一科学计数法指数写成 e-021/e-21；只归一指数的补零，
-- 不接受不同尾数或非规范数字。防止跨运行库升级让精确数值串无故变成坏档。
local function ComparableTransportNumberToken(token)
    local mantissa, exponent = token:match("^(.-)[eE]([%+%-]?%d+)$")
    if mantissa ~= nil then return mantissa .. "e" .. string.format("%.0f", tonumber(exponent)) end
    return token
end

local function TransportDecodeValueV3(value, seen)
    local kind = type(value)
    if kind == "string" then
        if value == TRANSPORT_V3_FALSE then return false, nil end
        if value == TRANSPORT_V3_EMPTY_TABLE then return {}, nil end
        if value == TRANSPORT_V3_ZERO then return 0, nil end
        if value == TRANSPORT_V3_EMPTY_STRING then return "", nil end
        if value:sub(1, #TRANSPORT_V3_STRING) == TRANSPORT_V3_STRING then return value:sub(#TRANSPORT_V3_STRING + 1), nil end
        if value:sub(1, #TRANSPORT_V3_NUMBER) == TRANSPORT_V3_NUMBER then
            local token = value:sub(#TRANSPORT_V3_NUMBER + 1)
            local number = #token > 0 and #token <= 32 and not token:find("[^%d%.eE%+%-]") and tonumber(token) or nil
            -- 只接受本编码器产生的有限规范串，不接受 NaN/Inf/hex/空白/另一种写法；
            -- 此处不 loadstring、不修复输入。业务字面前缀已走 s 转义，不会误当数值。
            if number == nil or number ~= number or number == math.huge or number == -math.huge
                or ComparableTransportNumberToken(string.format("%.17g", number)) ~= ComparableTransportNumberToken(token) then
                return nil, "transport_number_token_v3"
            end
            return number, nil
        end
        if value:sub(1, #TRANSPORT_V3_PREFIX) == TRANSPORT_V3_PREFIX then return nil, "unknown_transport_token_v3" end
        return value, nil
    end
    if kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return nil, "transport_nonfinite_v3" end
        -- v3 风险数值必须来自 n-token；未封装的小数/大整数不能冒充安全 v3 数据。
        if value ~= math.floor(value) or math.abs(value) > NATIVE_EXACT_INTEGER_LIMIT then return nil, "transport_native_number_v3" end
        return value, nil
    end
    if kind == "boolean" then return value, nil end
    if kind ~= "table" then return nil, "transport_type_v3:" .. kind end
    seen = seen or {}
    if seen[value] ~= nil then return nil, "transport_cycle" end
    seen[value] = true
    local out = {}
    for key, child in pairs(value) do
        local decodedKey, keyErr = TransportDecodeValueV3(key, seen)
        if keyErr ~= nil then seen[value] = nil; return nil, keyErr end
        if type(decodedKey) ~= "number" and type(decodedKey) ~= "string" then seen[value] = nil; return nil, "transport_key_type_v3" end
        local decodedChild, childErr = TransportDecodeValueV3(child, seen)
        if childErr ~= nil then seen[value] = nil; return nil, childErr end
        -- 损坏输入可以把两个物理键映射成同一逻辑键，必须整体拒绝，禁止后一个覆盖前一个。
        if out[decodedKey] ~= nil then seen[value] = nil; return nil, "transport_key_collision_v3" end
        out[decodedKey] = decodedChild
    end
    seen[value] = nil
    return out, nil
end


-- 397 项导入曾在 auto[189] 首次缺失；保留前 188 项可复现旧章变化，但这不能视为 Native 上限。
-- v4 保留 v3 标量保护，将 >32 项的连续正整数序列编码成每串 16 项、最多 2048 项的短块。
-- 每串最多 143 字节、每表最多 130 项；严格验计数/键集/段长，缺段不能当短列表。旧版本可读，原前缀先转义。
local TRANSPORT_V4_PREFIX = "__rs_t4:"
local TRANSPORT_V4_STRING = TRANSPORT_V4_PREFIX .. "s"
local TRANSPORT_V4_ARRAY = TRANSPORT_V4_PREFIX .. "a"
local VECTOR_CHUNK = 16
local VECTOR_LIMIT = 2048

local function DensePositiveIntegerCount(value)
    local count,maximum=0,0
    for key,child in pairs(value) do
        if type(key)~="number" or key<1 or key~=math.floor(key) or key>VECTOR_LIMIT
            or type(child)~="number" or child<1 or child>NATIVE_EXACT_INTEGER_LIMIT or child~=math.floor(child) then return nil end
        count=count+1;maximum=math.max(maximum,key)
    end
    if count>32 and count==maximum then return count end
end
local function TransportEncodeValueV4(value,seen)
    if type(value)=="string" and value:sub(1,#TRANSPORT_V4_PREFIX)==TRANSPORT_V4_PREFIX then
        return TRANSPORT_V4_STRING..value,nil
    end
    if type(value)~="table" or next(value)==nil then return TransportEncodeValueV3(value) end
    seen=seen or {};if seen[value] then return nil,"transport_cycle" end;seen[value]=true
    local count=DensePositiveIntegerCount(value)
    if count then
        local out={[TRANSPORT_V4_ARRAY]=1,count=count}
        for first=1,count,VECTOR_CHUNK do
            local tokens={}
            for i=first,math.min(count,first+VECTOR_CHUNK-1) do tokens[#tokens+1]=string.format("%.0f",value[i]) end
            out["p"..tostring(math.floor((first-1)/VECTOR_CHUNK)+1)]=table.concat(tokens,",")
        end
        seen[value]=nil;return out,nil
    end
    local out={}
    for key,child in pairs(value) do
        if type(key)~="number" and type(key)~="string" then seen[value]=nil;return nil,"transport_key_type_v4" end
        local ek,ke=TransportEncodeValueV4(key,seen);if ke then seen[value]=nil;return nil,ke end
        local ev,ve=TransportEncodeValueV4(child,seen);if ve then seen[value]=nil;return nil,ve end
        if out[ek]~=nil then seen[value]=nil;return nil,"transport_key_collision_v4" end
        out[ek]=ev
    end
    seen[value]=nil;return out,nil
end
local function DecodePositiveVector(value)
    local count=value.count
    if value[TRANSPORT_V4_ARRAY]~=1 or type(count)~="number" or count~=math.floor(count)
        or count<=32 or count>VECTOR_LIMIT then return nil,"transport_vector_header_v4" end
    local parts=math.ceil(count/VECTOR_CHUNK);local fields=0
    for key in pairs(value) do
        fields=fields+1
        if key~=TRANSPORT_V4_ARRAY and key~="count" then
            local n=type(key)=="string" and key:match("^p([1-9]%d*)$") or nil
            n=tonumber(n)
            if not n or n>parts then return nil,"transport_vector_extra_key_v4" end
        end
    end
    if fields~=parts+2 then return nil,"transport_vector_missing_chunk_v4" end
    local out={}
    for index=1,parts do
        local text=value["p"..tostring(index)]
        if type(text)~="string" or #text>143 or not text:match("^[1-9]%d*[,0-9]*$") then return nil,"transport_vector_chunk_v4:"..index end
        local tokens={};local expected=math.min(VECTOR_CHUNK,count-(index-1)*VECTOR_CHUNK)
        for token in text:gmatch("[^,]+") do
            local n=tonumber(token)
            if not n or n<1 or n>NATIVE_EXACT_INTEGER_LIMIT or n~=math.floor(n) or string.format("%.0f",n)~=token then return nil,"transport_vector_token_v4:"..index end
            tokens[#tokens+1]=token;if #tokens>expected then return nil,"transport_vector_count_v4:"..index end
            out[#out+1]=n
        end
        if #tokens~=expected or table.concat(tokens,",")~=text then return nil,"transport_vector_count_v4:"..index end
    end
    return out,nil
end
local function TransportDecodeValueV4(value,seen)
    if type(value)=="string" and value:sub(1,#TRANSPORT_V4_PREFIX)==TRANSPORT_V4_PREFIX then
        if value:sub(1,#TRANSPORT_V4_STRING)==TRANSPORT_V4_STRING then
            local literal=value:sub(#TRANSPORT_V4_STRING+1)
            -- 仅Encoder能产生的保留前缀转义可读；拒绝残缺/伪造标记，不做容错补字。
            if literal:sub(1,#TRANSPORT_V4_PREFIX)==TRANSPORT_V4_PREFIX then return literal,nil end
            return nil,"invalid_transport_escape_v4"
        end
        return nil,"unknown_transport_token_v4"
    end
    if type(value)~="table" then return TransportDecodeValueV3(value) end
    if value[TRANSPORT_V4_ARRAY]~=nil then return DecodePositiveVector(value) end
    seen=seen or {};if seen[value] then return nil,"transport_cycle" end;seen[value]=true
    local out={}
    for key,child in pairs(value) do
        local dk,ke=TransportDecodeValueV4(key,seen);if ke then seen[value]=nil;return nil,ke end
        if type(dk)~="number" and type(dk)~="string" then seen[value]=nil;return nil,"transport_key_type_v4" end
        local dv,ve=TransportDecodeValueV4(child,seen);if ve then seen[value]=nil;return nil,ve end
        if out[dk]~=nil then seen[value]=nil;return nil,"transport_key_collision_v4" end
        out[dk]=dv
    end
    seen[value]=nil;return out,nil
end

-- schema8 双 scope 使物理体积增大，实机曾丢失 v4 的 pN 字段，具体容量未知。
-- v5 将 >32 项序列改存 {marker,count,chunks={1..N}}，chunks 最多 128 项，继续保留 v3 标量保护。
-- 接受 Native 将数字索引改成规范十进制字符串，拒绝重复、稀疏、越界、非法 token 和额外字段；旧 1..4 仍可读。
local TRANSPORT_V5_PREFIX = "__rs_t5:"
local TRANSPORT_V5_STRING = TRANSPORT_V5_PREFIX .. "s"
local TRANSPORT_V5_ARRAY = TRANSPORT_V5_PREFIX .. "a"

local function TransportEncodeValueV5(value,seen)
    if type(value)=="string" and value:sub(1,#TRANSPORT_V5_PREFIX)==TRANSPORT_V5_PREFIX then
        return TRANSPORT_V5_STRING..value,nil
    end
    if type(value)~="table" or next(value)==nil then return TransportEncodeValueV3(value) end
    seen=seen or {};if seen[value] then return nil,"transport_cycle" end;seen[value]=true
    local count=DensePositiveIntegerCount(value)
    if count then
        local chunks={}
        for first=1,count,VECTOR_CHUNK do
            local tokens={}
            for i=first,math.min(count,first+VECTOR_CHUNK-1) do tokens[#tokens+1]=string.format("%.0f",value[i]) end
            chunks[#chunks+1]=table.concat(tokens,",")
        end
        seen[value]=nil
        return {[TRANSPORT_V5_ARRAY]=1,count=count,chunks=chunks},nil
    end
    local out={}
    for key,child in pairs(value) do
        if type(key)~="number" and type(key)~="string" then seen[value]=nil;return nil,"transport_key_type_v5" end
        local ek,ke=TransportEncodeValueV5(key,seen);if ke then seen[value]=nil;return nil,ke end
        local ev,ve=TransportEncodeValueV5(child,seen);if ve then seen[value]=nil;return nil,ve end
        if out[ek]~=nil then seen[value]=nil;return nil,"transport_key_collision_v5" end
        out[ek]=ev
    end
    seen[value]=nil;return out,nil
end

local function DecodePositiveVectorV5(value)
    local count=value.count
    if value[TRANSPORT_V5_ARRAY]~=1 or type(count)~="number" or count~=math.floor(count)
        or count<=32 or count>VECTOR_LIMIT then return nil,"transport_vector_header_v5" end
    local topFields=0
    for key in pairs(value) do
        topFields=topFields+1
        if key~=TRANSPORT_V5_ARRAY and key~="count" and key~="chunks" then return nil,"transport_vector_extra_key_v5" end
    end
    if topFields~=3 or type(value.chunks)~="table" then return nil,"transport_vector_chunks_v5" end
    local parts=math.ceil(count/VECTOR_CHUNK)
    local indexed,fields={},0
    for key,text in pairs(value.chunks) do
        local kind=type(key);local index=tonumber(key)
        if (kind~="number" and kind~="string") or index==nil or index~=math.floor(index) or index<1 or index>parts then
            return nil,"transport_vector_chunk_key_v5"
        end
        if kind=="string" and (not key:match("^[1-9]%d*$") or tostring(index)~=key) then return nil,"transport_vector_chunk_key_v5" end
        if indexed[index]~=nil then return nil,"transport_vector_chunk_collision_v5" end
        indexed[index]=text;fields=fields+1
    end
    if fields~=parts then return nil,"transport_vector_missing_chunk_v5" end
    local out={}
    for index=1,parts do
        local text=indexed[index]
        if type(text)~="string" or #text>143 or not text:match("^[1-9]%d*[,0-9]*$") then return nil,"transport_vector_chunk_v5:"..index end
        local tokens={};local expected=math.min(VECTOR_CHUNK,count-(index-1)*VECTOR_CHUNK)
        for token in text:gmatch("[^,]+") do
            local n=tonumber(token)
            if not n or n<1 or n>NATIVE_EXACT_INTEGER_LIMIT or n~=math.floor(n) or string.format("%.0f",n)~=token then return nil,"transport_vector_token_v5:"..index end
            tokens[#tokens+1]=token;if #tokens>expected then return nil,"transport_vector_count_v5:"..index end
            out[#out+1]=n
        end
        if #tokens~=expected or table.concat(tokens,",")~=text then return nil,"transport_vector_count_v5:"..index end
    end
    return out,nil
end

local function TransportDecodeValueV5(value,seen)
    if type(value)=="string" and value:sub(1,#TRANSPORT_V5_PREFIX)==TRANSPORT_V5_PREFIX then
        if value:sub(1,#TRANSPORT_V5_STRING)==TRANSPORT_V5_STRING then
            local literal=value:sub(#TRANSPORT_V5_STRING+1)
            if literal:sub(1,#TRANSPORT_V5_PREFIX)==TRANSPORT_V5_PREFIX then return literal,nil end
            return nil,"invalid_transport_escape_v5"
        end
        return nil,"unknown_transport_token_v5"
    end
    if type(value)~="table" then return TransportDecodeValueV3(value) end
    if value[TRANSPORT_V5_ARRAY]~=nil then return DecodePositiveVectorV5(value) end
    seen=seen or {};if seen[value] then return nil,"transport_cycle" end;seen[value]=true
    local out={}
    for key,child in pairs(value) do
        local dk,ke=TransportDecodeValueV5(key,seen);if ke then seen[value]=nil;return nil,ke end
        if type(dk)~="number" and type(dk)~="string" then seen[value]=nil;return nil,"transport_key_type_v5" end
        local dv,ve=TransportDecodeValueV5(child,seen);if ve then seen[value]=nil;return nil,ve end
        if out[dk]~=nil then seen[value]=nil;return nil,"transport_key_collision_v5" end
        out[dk]=dv
    end
    seen[value]=nil;return out,nil
end

-- 供 rs_persistence.lua 调用。
-- v6 仅压紧完整的死亡摘要标量树。
-- Domain、codec1、schema2 与指纹均不改变；所有其他值仍经过 v3 的精确数值/假值保护。
-- 固定字段顺序 + 数值往返文本 + 字符串 HEX 消除每行 11 个键/缩进的 Native 开销。
local V6_PREFIX = '__rs_t6:'
local ROW_FIELDS = {'serial','storageId','time','clock','windowMs','totalDamage','lethalSource','lethalAbility','lethalAmount','eventCount','debuffCount'}
local ROW_STRINGS = {clock=true,lethalSource=true,lethalAbility=true}
local function CompactV6(value, decode, seen)
    if type(value)=='string' then
        if not decode then
            if value:sub(1,#V6_PREFIX)==V6_PREFIX then return V6_PREFIX..'s'..value end
            return value
        end
        if value:sub(1,#V6_PREFIX)~=V6_PREFIX then return value end
        if value:sub(1,#V6_PREFIX+1)==V6_PREFIX..'s' then return value:sub(#V6_PREFIX+2) end
        if value:sub(1,#V6_PREFIX+1)~=V6_PREFIX..'r' or #value>4096 then return nil,'transport_row_token_v6' end
        local tokens={}
        for token in (value:sub(#V6_PREFIX+2)..';'):gmatch('(.-);') do tokens[#tokens+1]=token end
        if #tokens~=#ROW_FIELDS then return nil,'transport_row_count_v6' end
        local row={}
        for i,key in ipairs(ROW_FIELDS) do
            local token=tokens[i]
            if ROW_STRINGS[key] then
                if #token%2~=0 or token:find('[^0-9A-F]') then return nil,'transport_row_hex_v6' end
                row[key]=(token:gsub('..',function(pair)return string.char(tonumber(pair,16))end))
            else
                local n=tonumber(token)
                if not n or n~=n or n==math.huge or n==-math.huge or string.format('%.17g',n)~=token then return nil,'transport_row_number_v6' end
                row[key]=n
            end
        end
        return row
    end
    if type(value)~='table' then return value end
    seen=seen or {};if seen[value] then return nil,'transport_cycle' end;seen[value]=true
    if not decode then
        local count=0;for _ in pairs(value) do count=count+1 end
        local complete=count==#ROW_FIELDS
        for _,key in ipairs(ROW_FIELDS) do
            local v=value[key]
            if ROW_STRINGS[key] then complete=complete and type(v)=='string'
            else complete=complete and type(v)=='number' and v==v and v~=math.huge and v~=-math.huge end
        end
        if complete then
            local tokens={}
            for i,key in ipairs(ROW_FIELDS) do
                local v=value[key]
                tokens[i]=ROW_STRINGS[key] and (v:gsub('.',function(c)return string.format('%02X',string.byte(c))end)) or string.format('%.17g',v)
            end
            seen[value]=nil
            local packed=V6_PREFIX..'r'..table.concat(tokens,';')
            if #packed>4096 then return nil,'transport_row_limit_v6' end
            return packed
        end
    end
    local out={}
    for key,child in pairs(value) do
        local k,ke=CompactV6(key,decode,seen);if ke then seen[value]=nil;return nil,ke end
        local v,ve=CompactV6(child,decode,seen);if ve then seen[value]=nil;return nil,ve end
        if (type(k)~='string' and type(k)~='number') or out[k]~=nil then seen[value]=nil;return nil,'transport_key_collision_v6' end
        out[k]=v
    end
    seen[value]=nil;return out
end
function T.EncodeV6(value)
    local compact,err=CompactV6(value,false);if err then return nil,err end
    return TransportEncodeValueV3(compact)
end
function T.DecodeV6(value)
    local decoded,err=TransportDecodeValueV3(value);if err then return nil,err end
    return CompactV6(decoded,true)
end

-- Native 的文本标签、固定六位数、引号/转义、每层四空格均计入保守预算。
-- 每个字段按最占空间的另起一行估算；在 SaveData 之前拒绝，不能等截断后才回滚 RAM。
function T.EstimateNativeBytes(value, depth)
    depth=depth or 0
    local indent=depth*4
    local function Scalar(v)
        if type(v)=='number' then return 4+#string.format('%.6f',v) end
        if type(v)=='boolean' then return 16 end
        local text=tostring(v)
        local _,escapes=text:gsub('[%c"\\]','')
        return 4+#text+escapes+2
    end
    if type(value)~='table' then return indent+Scalar(value)+2 end
    local size=indent+14
    for key,child in pairs(value) do size=size+indent+Scalar(key)+2+T.EstimateNativeBytes(child,depth+1) end
    return size
end

T.EncodeV1 = TransportEncodeValueV1
T.DecodeV1 = TransportDecodeValueV1
T.EncodeV2 = TransportEncodeValueV2
T.DecodeV2 = TransportDecodeValueV2
T.EncodeV3 = TransportEncodeValueV3
T.DecodeV3 = TransportDecodeValueV3
T.EncodeV4 = TransportEncodeValueV4
T.DecodeV4 = TransportDecodeValueV4
T.EncodeV5 = TransportEncodeValueV5
T.DecodeV5 = TransportDecodeValueV5
