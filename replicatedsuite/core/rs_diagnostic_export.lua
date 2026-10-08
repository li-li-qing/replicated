------------------------------------------------------------------------
-- 中文维护（2026-10-02）：完整报告文件出口。RU 没有已验证的任意文件写入接口；
-- Diagnostics 冻结正文 -> Persistence 固定专用 key -> Native SaveData/LoadData
-- 完整回读 -> 本地只读提取工具生成 txt。业务 Store/Fence/配置均不参与此出口。
-- 仅明确点击才分块写快照，无 Tick、自动上传、报告历史堆积或业务启停副作用。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P, D, T = S.Persistence, S.DiagnosticsManager, S.ReportCopyTransport
if type(P) ~= 'table' or type(D) ~= 'table' or type(T) ~= 'table' then return end
local KEY, MAX_BYTES, CHUNK_BYTES, PAGE_BYTES = 'replicated_suite_v1_diagnostic_export', 1048576, 1024, 4096
local PROTOCOL = 'RS-DIAGNOSTIC-FILE-2'
S.DiagnosticExport = { version = 2, key = KEY, maxBytes = MAX_BYTES }
local E = S.DiagnosticExport

-- 中文维护：报告身份/长度/校验全部使用字符串，避开 RU 数值精度与假值省略；
-- 正文按二进制字节 HEX 编码，换行、引号、中文和 Native 转义均不改变原文。
local function Hex(text)
    return (text:gsub('.', function(c) return string.format('%02X', string.byte(c)) end))
end
local function Build(text, meta)
    if type(text) ~= 'string' or #text == 0 or #text > MAX_BYTES then return nil, '报告为空或超过 1 MiB 安全上限' end
    local count = math.ceil(#text / PAGE_BYTES)
    local out = { protocol = PROTOCOL, report_id = tostring(type(meta) == 'table' and meta.id or 'report'),
        byte_count = tostring(#text), page_count = tostring(count), page_bytes = tostring(PAGE_BYTES), checksum = T:CopyChecksum(text) }
    local pages = {}
    for index = 1, count do
        local part = text:sub((index - 1) * PAGE_BYTES + 1, index * PAGE_BYTES)
        local page = { protocol = PROTOCOL .. '-PAGE', page_index = tostring(index),
            report_checksum = out.checksum, byte_count = tostring(#part), checksum = T:CopyChecksum(part),
            chunk_count = tostring(math.ceil(#part / CHUNK_BYTES)) }
        for chunk = 1, tonumber(page.chunk_count) do
            page[string.format('c%04d', chunk)] = Hex(part:sub((chunk - 1) * CHUNK_BYTES + 1, chunk * CHUNK_BYTES))
        end
        pages[index] = page
    end
    return out, nil, pages
end

-- 中文维护：Persistence 是 Native 持久化唯一入口。此 key 是用户显式导出的传输快照，
-- 不注册业务 Store、不 Apply/default/migrate、不绕过任何已有业务 Store 的 write fence。
-- SaveData 返回成功仍须逐字段逐块完整回读；失败状态只属于本次导出，不能污染业务健康度。
function P:SaveDiagnosticExport(text, meta)
    local payload, err, pages = Build(text, meta)
    if payload == nil then return false, err end
    local api = S.Api
    if type(api) ~= 'table' or type(api.SaveData) ~= 'function' or type(api.LoadData) ~= 'function' then return false, '客户端保存/回读接口不可用' end
    local function WriteVerified(key, value, label)
        local called, saved, saveErr = pcall(api.SaveData, api, key, value)
        if called ~= true or saved ~= true then return false, '诊断快照保存失败（' .. label .. '）：' .. tostring(called and saveErr or saved) end
        local readOk, actual, readErr = pcall(api.LoadData, api, key)
        if readOk ~= true or type(actual) ~= 'table' or readErr ~= nil then return false, '诊断快照回读失败（' .. label .. '）：' .. tostring(readOk and readErr or actual) end
        for name, expected in pairs(value) do
            if actual[name] ~= expected then return false, '诊断快照回读不完整（' .. label .. '）：' .. name end
        end
        return true
    end
    -- 中文维护（实机取证）：旧单 key 正文被截在 16383 字节。每页最多 4 KiB 原文，
    -- HEX 与全部元数据小于 9 KiB；固定最多 256 个 key 复用，无 Native 深层大表。
    -- 每页逐字段回读通过后，最后才提交总清单。本地端还须验证页号、各页及全文校验，
    -- 因此半途失败或两次导出交错不会被当成完整文件，也不从旧清单拼出新旧混合报告。
    for index, page in ipairs(pages) do
        local ok, reason = WriteVerified(KEY .. string.format('_page_%04d', index), page, '第' .. index .. '块')
        if ok ~= true then return false, reason end
    end
    local ok, reason = WriteVerified(KEY, payload, '清单')
    if ok ~= true then return false, reason end
    return true, { id = payload.report_id, bytes = #text, checksum = payload.checksum }
end

-- 中文维护：展示端提交 immutable 原文，而非 Native 编辑框可能被截断的当前页；
-- 成功回执只承诺 Native 快照回读成功，txt 尚须本地提取工具读取磁盘后验证生成。
function D:ExportReport(text, meta)
    local ok, result = P:SaveDiagnosticExport(text, meta)
    E.last = ok == true and result or { error = tostring(result) }
    if ok ~= true then return false, result end
    return true, '报告快照已提交；请运行 replicatedsuite 文件夹内“开始自动保存诊断.cmd”并保留窗口，才会生成 Addon/诊断报告 下的 .txt。无需安装 Python。', result
end
