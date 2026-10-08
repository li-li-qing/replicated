------------------------------------------------------------------------
-- Replicated Suite - Persistence Transport 编解码（v1-v5，纯函数、无状态）
--
-- 2026-09-30（giant-file-1）：从 core/rs_persistence.lua 原样迁出（427 行）。
-- 这是**纯移动**：函数体与递归调用逐字保留，不改变任何编解码语义 ——
-- 这些函数承载用户配置的磁盘格式，任何行为差异都等于数据损坏风险。
-- 迁出动机：rs_persistence.lua 曾达 4267 行（GIANT_FILE 审计项）。
-- 边界：本模块不持有事实、不读写 Store、不做完整性验证；只做「值 <-> 传输编码」。
-- 加载顺序：必须在 core/rs_persistence.lua **之前**（见 toc.g）。
------------------------------------------------------------------------
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

local function TransportEncodeValueV1(value, seen) -- 中文维护注释：只用于兼容 Harness/历史语义说明；生产新写由 v3 承担。
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

local function TransportDecodeValueV1(value, seen) -- 中文维护注释：Transport v1 永久保留只读解码，保证用户从 `.18.194-.196` 升级时无需清配置。
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

local function TransportEncodeValueV2(value, seen) -- 维护：冻结历史 v2 语义供兼容；非零数字不保护的缺口由新的 v3 处理，禁止偷换 v2 解码。
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

local function TransportDecodeValueV2(value, seen) -- 中文维护注释：v2 只识别 `__rs_t2:`，因此真实业务字符串即使以旧 `__rs_t1:` 开头也不会被误解；v2 自身前缀在写前必定转义。
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

-- 中文维护注释（2026-09-12 真实跑商取证）：normalizedCenterX 的旧业务 token 是
-- 0.0903896（整表精确复现旧章），Native 返回 0.09038999676704407，token 变成 0.09039。
-- “六位有效数字 Hash”并不能抵抗“先保留六位小数，再转单精度”的传输损失。
-- Authority：只有 Persistence 拥有物理传输；Store/Feature 仍接收原数值，不量化其 Domain。
-- v3 用 17 位往返十进制字符串封装非整数和超出 binary32 连续整数区间的数值（包含键）。
-- 非负小整数/版本路由继续用 Native number；v1/v2 解码永久保留，健康旧档不在启动时批量重写。
-- 风险：编码串计入原预算，超限仍拒绝；不扩大 StringBudget、不弱化业务指纹、不做循环内 I/O。
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
        -- 维护（2026-09-12）：实机回读证据为 buffs.y 的 -2 -> 0，负整数原先绕过了
        -- n-token。尚无该次原始 LoadData 表，不能断言 Native 内部是省略还是置零；
        -- 但负号不应继续裸传。Core 在 Save/Load 冷边界复用旧版已可读的 n-token，
        -- Domain 仍持有原负数；旧裸负整数解码保留。正整数 ID/路由不变，预算照旧。
        -- 不把 -2 改为 0、不从 Hash 猜旧坐标，也不放宽 expected/stamped/actual 校验。
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

-- 维护：C runtime 可能把同一科学计数法指数写成 e-021/e-21；只归一指数的补零，
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
            -- 维护：只接受本编码器产生的有限规范串，不接受 NaN/Inf/hex/空白/另一种写法；
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
        -- 维护：v3 风险数值必须来自 n-token；未封装的小数/大整数不能冒充安全 v3 数据。
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
        -- 维护：损坏输入可以把两个物理键映射成同一逻辑键，必须整体拒绝，禁止后一个覆盖前一个。
        if out[decodedKey] ~= nil then seen[value] = nil; return nil, "transport_key_collision_v3" end
        out[decodedKey] = decodedChild
    end
    seen[value] = nil
    return out, nil
end


-- 维护（2026-09-12 批量追踪实机）：397条导入在回读auto[189]首次缺失，
-- 测试的“保留前188个数字键”可精确复现04287DD8>3AF652D5，但不是Native上限的断言。
-- Authority：Core独占物理表示；Store只显式选择transport4。业务结构、canonical及旧章不改。
-- v4继承v3标量精度保护，只将>32项的连续正整数序列装成16项/串、最多2048项的短块。
-- 每串最多143字节，每表最多130项；计数/键集/段长严格验证，缺段绝不默认为短列表。
-- 旧1/2/3永久可读。真实保留前缀先转义，禁止用户字段被误识别为传输标记。
-- 只在已有Save/Load冷路径执行；没有新I/O/计时任务，物理大小仍受Store预算约束。
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
            -- 维护：仅Encoder能产生的保留前缀转义可读；拒绝残缺/伪造标记，不做容错补字。
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

-- 维护（2026-09-17，schema8 六通道实机）：Transport4 在 schema7->8 自动迁移后
-- 立即回读出现 transport_vector_missing_chunk_v4。旧 v4 用同一表上的 p1..pN
-- 字符串键承载分块；schema8 把原全局追踪复制到 player/target 后物理体积翻倍，
-- 实机证明这种表示仍可能被 SaveData 丢失某个 pN 字段。我们只把“字段丢失”
-- 作为已证事实，不猜 Native 的具体全局容量。
-- Authority：Core 仍独占物理传输。v5 保留 v3 标量精度保护，把 >32 的连续
-- 正整数序列编码为 {marker,count,chunks={1..N}}；chunks 最多128项，低于此前
-- 已实证的 numeric key 189 丢失边界，同时避免 v4 的几十/上百个 pN 字符串键。
-- Decoder 接受 Native 将 1..N 数字键表示为规范十进制字符串，但拒绝重复、稀疏、
-- 越界、非法 token 或额外字段。旧 transport1..4 永久保留只读兼容。
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

-- 导出（供 rs_persistence.lua 以 T.<名> 调用）
-- 中文维护（实机 16383 字节截断）：v6 仅压紧完整的死亡摘要标量树。
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

-- 中文维护：Native 的文本标签、固定六位数、引号/转义、每层四空格均计入保守预算。
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
