-- 中文维护（2026-09-25，RS-ERROR-PAGE-1）：
-- Foundation Gate `service_presentation_boundary` 契约的静态回归。
-- 该检查会遍历 S.Services.* 的每一张表（以及 S.TargetService），要求显式声明
-- presentationBoundary ∈ {service_only, event_host_only}；任何一个 Service 漏声明都会把
-- 整份游戏内自检报告变成 status="BLOCKED"（实机案例：MaterialPriceServiceV3:missing）。
-- 本测试把该运行时契约提前到离线阶段兑现：
--   1) services/*.lua 中每一个 `S.Services.X = ...` 注册文件都必须声明允许的边界值；
--   2) 复刻 Gate 的判定循环语义（含 S.TargetService 分支）；
--   3) 断言合法取值集合没有被悄悄放宽。
-- 不进入 toc.g。运行：cd replicatedsuite && lua tools/rs_service_boundary_contract_tests.lua
local pass, fail, skipped = 0, 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        if err == 'SKIP' then skipped = skipped + 1; print('SKIP service-boundary ' .. name .. ' (host enumeration unavailable)')
        else pass = pass + 1; print('PASS service-boundary ' .. name) end
    else
        fail = fail + 1; print('FAIL service-boundary ' .. name .. ': ' .. tostring(err))
    end
end

local SERVICE_DIR = 'services'
local ALLOWED = { service_only = true, event_host_only = true }
local function DeclaresAllowedBoundary(text)
    -- Lua 两种引号语义相同；必须成对匹配，取值仍受既有门禁词表限制。
    for quote, boundary in text:gmatch("presentationBoundary%s*=%s*(['\"])([%w_]+)%1") do
        if ALLOWED[boundary] == true then return true end
    end
    return false
end

local function ReadFile(path)
    local handle = assert(io.open(path, 'rb'))
    local text = handle:read('*a')
    handle:close()
    return text
end

local function ListServiceFiles()
    -- io.popen 在部分沙箱下不可用；直接尝试已知目录列举，失败则跳过动态枚举。
    local files = {}
    local pipe = io.popen('dir /b "' .. SERVICE_DIR .. '\\*.lua" 2>nul')
    if pipe ~= nil then
        for name in pipe:lines() do
            name = name:gsub('\r', '')
            if name:sub(-4) == '.lua' then files[#files + 1] = SERVICE_DIR .. '/' .. name end
        end
        pipe:close()
    end
    return files
end

-- 与 rs_foundation_gate.lua:2266-2281 完全一致的判定语义（此处只做镜像，不复制业务）。
local function CollectInvalidBoundaries(services, targetService)
    local invalid = {}
    for name, service in pairs(services or {}) do
        if type(service) == 'table' then
            local boundary = tostring(service.presentationBoundary or 'missing')
            if ALLOWED[boundary] ~= true then invalid[#invalid + 1] = tostring(name) .. ':' .. boundary end
        end
    end
    if type(targetService) == 'table' then
        local boundary = tostring(targetService.presentationBoundary or 'missing')
        if ALLOWED[boundary] ~= true then invalid[#invalid + 1] = 'TargetService:' .. boundary end
    end
    table.sort(invalid)
    return invalid
end

Test('every services/*.lua registry owner declares an allowed presentationBoundary', function()
    local files = ListServiceFiles()
    -- 受限宿主可能禁用 io.popen；此时必须显式 SKIP，禁止把“没跑到”报成 PASS。
    if #files == 0 then error('SKIP') end
    local offenders = {}
    local registered = 0
    for _, path in ipairs(files) do
        local text = ReadFile(path)
        local declares = DeclaresAllowedBoundary(text)
        local hasRegistration = text:find('S%.Services%.[%w_]+%s*=') ~= nil
        if hasRegistration then
            registered = registered + 1
            if declares ~= true then offenders[#offenders + 1] = path end
        end
    end
    assert(registered > 0, 'no S.Services registry owner found under services/')
    assert(#offenders == 0, 'services missing presentationBoundary (would BLOCK the in-game self check): ' .. table.concat(offenders, ', '))
end)

Test('static declaration check accepts both Lua quote forms without widening the contract', function()
    assert(DeclaresAllowedBoundary([[presentationBoundary = 'service_only']]))
    assert(DeclaresAllowedBoundary([[presentationBoundary = "service_only"]]))
    assert(DeclaresAllowedBoundary([[presentationBoundary = 'event_host_only']]))
    assert(not DeclaresAllowedBoundary([[presentationBoundary = 'presentation_owner']]))
    assert(not DeclaresAllowedBoundary([[presentationBoundary = 'service_only"]]))
end)

Test('gate loop semantics flag exactly the non-declaring service', function()
    local invalid = CollectInvalidBoundaries({
        Good = { presentationBoundary = 'service_only' },
        EventHost = { presentationBoundary = 'event_host_only' },
        Bad = {},
        WrongValue = { presentationBoundary = 'presentation_owner' },
    }, { presentationBoundary = 'service_only' })
    assert(#invalid == 2, 'unexpected invalid count: ' .. table.concat(invalid, ','))
    assert(invalid[1] == 'Bad:missing', 'first offender mismatch: ' .. tostring(invalid[1]))
    assert(invalid[2] == 'WrongValue:presentation_owner', 'second offender mismatch: ' .. tostring(invalid[2]))
end)

Test('allowed boundary vocabulary is not silently widened', function()
    local invalid = CollectInvalidBoundaries({ Service = { presentationBoundary = 'service_only' } }, nil)
    assert(#invalid == 0, 'service_only must be accepted')
    local targetInvalid = CollectInvalidBoundaries(nil, { presentationBoundary = 'event_host_only' })
    assert(#targetInvalid == 0, 'event_host_only must be accepted for S.TargetService')
    local missing = CollectInvalidBoundaries(nil, {})
    assert(missing[1] == 'TargetService:missing', 'missing TargetService boundary must be flagged')
end)

Test('material price service file itself declares the boundary next to its identity', function()
    local text = ReadFile(SERVICE_DIR .. '/rs_material_price_service_v3.lua')
    assert(text:find('StoreId%s*=%s*"v3%.market%.material_prices"', 1) ~= nil, 'material price service identity changed')
    assert(text:find('presentationBoundary%s*=%s*"service_only"', 1) ~= nil,
        'MaterialPriceServiceV3 must declare presentationBoundary = "service_only"')
end)

print(string.format('SERVICE_BOUNDARY_CONTRACT RESULT %d passed / %d failed / %d skipped (%s)', pass, fail, skipped, _VERSION))
assert(fail == 0, 'service boundary contract failures: ' .. tostring(fail))
