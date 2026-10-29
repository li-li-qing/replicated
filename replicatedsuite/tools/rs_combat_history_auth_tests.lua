-- Replicated Suite · 纯 Lua 5.1 SHA-256 / HMAC-SHA256 回归
-- 固定向量来自 FIPS 180-4、RFC 4231；二进制与补齐边界另由 Python hashlib/hmac 独立生成。
-- 从 replicatedsuite 目录执行；此文件验证离线算法，不代表 RU 客户端验收。
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; print('PASS history-auth ' .. name)
    else failed = failed + 1; print('FAIL history-auth ' .. name .. ': ' .. tostring(err)) end
end

-- 无 bit/bit32、require 或 Native 的白名单环境，避免宿主扩展掩盖纯 Lua 约束。
local sandbox = {ReplicatedSuite={}, math=math, string=string, table=table, type=type}
local chunk, loadError = loadfile('core/rs_combat_history_auth.lua')
Test('module provides both algorithms without runtime dependencies', function()
    assert(chunk, loadError)
    setfenv(chunk, sandbox)()
    local auth = sandbox.ReplicatedSuite.CombatHistoryAuth
    assert(type(auth) == 'table', 'CombatHistoryAuth is missing')
    assert(type(auth.Sha256) == 'function' and type(auth.HmacSha256) == 'function', 'auth API is missing')
end)
local A = sandbox.ReplicatedSuite.CombatHistoryAuth
local function Equal(actual, expected)
    assert(actual == expected, tostring(actual) .. ' ~= ' .. expected)
    assert(#actual == 64 and not actual:find('[^0-9a-f]'), 'digest must be 64 lowercase hex characters')
end
local function Bytes(reverse)
    local parts = {}
    for i = 0, 255 do parts[#parts+1] = string.char(reverse and 255-i or i) end
    return table.concat(parts)
end

local shaVectors = {
    {'empty', '', 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'},
    {'abc', 'abc', 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'},
    {'NIST multi-block', 'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1'},
    {'binary bytes 0..255', Bytes(false), '40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880'},
    {'padding 55', string.rep('a',55), '9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318'},
    {'padding 56', string.rep('a',56), 'b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a'},
    {'padding 63', string.rep('a',63), '7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34'},
    {'padding 64', string.rep('a',64), 'ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb'},
    {'padding 65', string.rep('a',65), '635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0'},
    {'1000 bytes', string.rep('a',1000), '41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3'},
}
for _, vector in ipairs(shaVectors) do
    Test('SHA256 ' .. vector[1], function() Equal(A.Sha256(vector[2]), vector[3]) end)
end

local sequenceKey = {}
for i = 1,25 do sequenceKey[i] = string.char(i) end
local hmacVectors = {
    {'empty key and message', '', '', 'b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad'},
    {'RFC4231 case 1', string.rep(string.char(11),20), 'Hi There',
        'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7'},
    {'RFC4231 case 2', 'Jefe', 'what do ya want for nothing?',
        '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843'},
    {'RFC4231 case 3', string.rep(string.char(170),20), string.rep(string.char(221),50),
        '773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe'},
    {'RFC4231 case 4', table.concat(sequenceKey), string.rep(string.char(205),50),
        '82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b'},
    {'RFC4231 case 6 long key', string.rep(string.char(170),131), 'Test Using Larger Than Block-Size Key - Hash Key First',
        '60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54'},
    {'RFC4231 case 7 long key and message', string.rep(string.char(170),131),
        'This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm.',
        '9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2'},
    {'binary key and message', Bytes(false), Bytes(true),
        'cd512c928571ffff9b7c38cc7782a87228b103f62094edb992c8a20b548664a1'},
}
for _, vector in ipairs(hmacVectors) do
    Test('HMAC ' .. vector[1], function() Equal(A.HmacSha256(vector[2], vector[3]), vector[4]) end)
end
Test('alternating keys and repeated requests preserve independent HMAC results', function()
    for i = 1,3 do
        for _, vector in ipairs(hmacVectors) do Equal(A.HmacSha256(vector[2], vector[3]), vector[4]) end
    end
end)
Test('invalid types fail without silently changing the authenticated bytes', function()
    for _, value in ipairs({false, 1, {}, function()end}) do
        local result, err = A.Sha256(value)
        assert(result == nil and type(err) == 'string')
        result, err = A.HmacSha256(value, 'text')
        assert(result == nil and type(err) == 'string')
        result, err = A.HmacSha256('key', value)
        assert(result == nil and type(err) == 'string')
    end
    assert(A.Sha256(nil) == nil and A.HmacSha256(nil, '') == nil and A.HmacSha256('', nil) == nil)
end)
Test('100 HMAC calls over 100 bytes complete with fixed expected results', function()
    local message, expected = string.rep('x',100), '03e16faf735e5573e159b0ee5cbbc712f010262b0fb9c8098c14073fdfafa234'
    -- 冷路径的固定工作量探针；只报告实际耗时，不把宿主阈值写成游戏帧预算。
    local started = os.clock()
    for i = 1,100 do Equal(A.HmacSha256('performance-key',message), expected) end
    local elapsed = os.clock()-started
    print(string.format('PERF history-auth HMAC 100-byte x100: %.6fs total / %.3fms per call (%s)',elapsed,elapsed*10,_VERSION))
end)
print(string.format('HISTORY AUTH RESULT %d passed / %d failed (%s)',passed,failed,_VERSION))
assert(failed == 0, 'history auth regression failures: ' .. failed)
