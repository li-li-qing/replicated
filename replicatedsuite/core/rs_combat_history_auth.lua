-- Replicated Suite · 战绩冷路径认证基础
-- SHA-256：FIPS 180-4 §6.2；HMAC：RFC 2104。标准向量见 tools/rs_combat_history_auth_tests.lua。
-- 仅处理原始字节，不访问 Native/磁盘，不参与战斗事件热路径。
-- 客户端内置密钥只能提高基础篡改门槛，不能证明事件来自游戏服务器。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local A = {}
S.CombatHistoryAuth = A
local floor, byte, char = math.floor, string.byte, string.char
local concat, rep, format = table.concat, string.rep, string.format
local MOD32 = 4294967296

-- Lua 5.1 没有标准位运算库。固定 256 项半字节异或表避免依赖 bit/bit32，
-- 比逐位循环少四倍迭代；表大小不随消息、密钥或历史长度增长。
local xorNibble, place = {}, {}
for a = 0,15 do
    for b = 0,15 do
        local x,y,value,power = a,b,0,1
        for i = 1,4 do
            if x%2 ~= y%2 then value = value+power end
            x,y,power = floor(x/2),floor(y/2),power*2
        end
        xorNibble[a*16+b] = value
    end
end
for i = 0,7 do place[i] = 16^i end
local function Xor(a,b)
    local value = 0
    for i = 0,7 do
        value = value+xorNibble[(a%16)*16+b%16]*place[i]
        a,b = floor(a/16),floor(b/16)
    end
    return value
end
local function And(a,b)
    -- a+b 与差值均小于 2^33，在 Lua number 的精确整数范围内。
    return (a+b-Xor(a,b))/2
end
local function Rotate(a,bits)
    -- 先截低位再左移，避免把完整 32 位数乘到 2^53 之外后丢精度。
    local divisor = 2^bits
    return floor(a/divisor)+(a%divisor)*(MOD32/divisor)
end
local K = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
}
local function NewState(seed)
    if seed then return {seed[1],seed[2],seed[3],seed[4],seed[5],seed[6],seed[7],seed[8]} end
    return {0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19}
end
local function Compress(state,text,offset,w)
    for i = 1,16 do
        local a,b,c,d = byte(text,offset+(i-1)*4,offset+(i-1)*4+3)
        w[i] = ((a*256+b)*256+c)*256+d
    end
    for i = 17,64 do
        local x,y = w[i-15],w[i-2]
        local s0 = Xor(Xor(Rotate(x,7),Rotate(x,18)),floor(x/8))
        local s1 = Xor(Xor(Rotate(y,17),Rotate(y,19)),floor(y/1024))
        w[i] = (w[i-16]+s0+w[i-7]+s1)%MOD32
    end
    local a,b,c,d,e,f,g,h = state[1],state[2],state[3],state[4],state[5],state[6],state[7],state[8]
    for i = 1,64 do
        local s1 = Xor(Xor(Rotate(e,6),Rotate(e,11)),Rotate(e,25))
        -- 两项 AND 的有效位互斥，直接相加与 XOR 等价。
        local ch = And(e,f)+And(MOD32-1-e,g)
        local t1 = (h+s1+ch+K[i]+w[i])%MOD32
        local s0 = Xor(Xor(Rotate(a,2),Rotate(a,13)),Rotate(a,22))
        local maj = And(a,b)+And(Xor(a,b),c)
        local t2 = (s0+maj)%MOD32
        h,g,f,e,d,c,b,a = g,f,e,(d+t1)%MOD32,c,b,a,(t1+t2)%MOD32
    end
    state[1],state[2],state[3],state[4] = (state[1]+a)%MOD32,(state[2]+b)%MOD32,(state[3]+c)%MOD32,(state[4]+d)%MOD32
    state[5],state[6],state[7],state[8] = (state[5]+e)%MOD32,(state[6]+f)%MOD32,(state[7]+g)%MOD32,(state[8]+h)%MOD32
end
local function WordBytes(word)
    return char(floor(word/16777216),floor(word/65536)%256,floor(word/256)%256,word%256)
end
local function Digest(text,seed,prefixBytes)
    local state,w = NewState(seed),{}
    local fullBytes = #text-#text%64
    for offset = 1,fullBytes,64 do Compress(state,text,offset,w) end
    local size = #text+(prefixBytes or 0)
    -- 64 位 bit 长度拆为高低两个 32 位字；不计算可能超出精确范围的 size*8。
    local tail = text:sub(fullBytes+1)..char(128)..rep(char(0),(55-#text)%64)
        ..WordBytes(floor(size/536870912))..WordBytes((size%536870912)*8)
    for offset = 1,#tail,64 do Compress(state,tail,offset,w) end
    local result = {}
    for i = 1,8 do result[i] = WordBytes(state[i]) end
    return concat(result)
end
local function Hex(raw)
    return (raw:gsub('.',function(c) return format('%02x',byte(c)) end))
end

-- 点调用；字符串按原始字节认证，拒绝隐式 tostring 改变签名内容。
function A.Sha256(text)
    if type(text) ~= 'string' then return nil,'auth_text_type' end
    return Hex(Digest(text))
end

-- 只保留最后一个标准化密钥的 64 字节前缀状态，不缓存消息或历史条目。
-- Digest 每次复制状态，防止连续调用或切换密钥污染后续认证。
local cachedKey,innerState,outerState
function A.HmacSha256(key,text)
    if type(key) ~= 'string' then return nil,'auth_key_type' end
    if type(text) ~= 'string' then return nil,'auth_text_type' end
    if #key > 64 then key = Digest(key) end
    if cachedKey ~= key then
        local inner,outer = {},{}
        for i = 1,64 do
            local value = byte(key,i) or 0
            inner[i],outer[i] = char(Xor(value,0x36)),char(Xor(value,0x5c))
        end
        innerState,outerState = NewState(),NewState()
        Compress(innerState,concat(inner),1,{})
        Compress(outerState,concat(outer),1,{})
        cachedKey = key
    end
    return Hex(Digest(Digest(text,innerState,64),outerState,64))
end
