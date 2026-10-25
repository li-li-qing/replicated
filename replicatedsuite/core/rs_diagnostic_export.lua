-- Replicated Suite · 诊断导出编码
-- 作者：Replicated
-- QQ群：1104129461
-- RU 没有已验证的任意文件写入接口：报告先经 Persistence 写专用 key，完整回读后再由本地提取工具生成 txt。
-- 仅响应导出点击，独立于业务 Store 的加载、恢复和写保护。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local P, D, T = S.Persistence, S.DiagnosticsManager, S.ReportCopyTransport
if type(P) ~= 'table' or type(D) ~= 'table' or type(T) ~= 'table' then return end
local KEY, MAX_BYTES, CHUNK_BYTES, PAGE_BYTES = 'replicated_suite_v1_diagnostic_export', 1048576, 1024, 4096
local PROTOCOL = 'RS-DIAGNOSTIC-FILE-2'
local HISTORY_KEY, HISTORY_PROTOCOL = 'replicated_suite_v1_combat_history_export', 'RS-COMBAT-HISTORY-FILE-1'
S.DiagnosticExport = { version = 2, key = KEY, maxBytes = MAX_BYTES }
local E = S.DiagnosticExport

-- 报告身份/长度/校验全部使用字符串，避开 RU 数值精度与假值省略；
-- 正文按二进制字节 HEX 编码，换行、引号、中文和 Native 转义均不改变原文。
local function Hex(text)
    return (text:gsub('.', function(c) return string.format('%02X', string.byte(c)) end))
end
local function Build(text, meta, protocol)
    if type(text) ~= 'string' or #text == 0 or #text > MAX_BYTES then return nil, '报告为空或超过 1 MiB 安全上限' end
    local count = math.ceil(#text / PAGE_BYTES)
    local out = { protocol = protocol, report_id = tostring(type(meta) == 'table' and meta.id or 'report'),
        byte_count = tostring(#text), page_count = tostring(count), page_bytes = tostring(PAGE_BYTES), checksum = T:CopyChecksum(text) }
    local pages = {}
    for index = 1, count do
        local part = text:sub((index - 1) * PAGE_BYTES + 1, index * PAGE_BYTES)
        local page = { protocol = protocol .. '-PAGE', page_index = tostring(index),
            report_checksum = out.checksum, byte_count = tostring(#part), checksum = T:CopyChecksum(part),
            chunk_count = tostring(math.ceil(#part / CHUNK_BYTES)) }
        for chunk = 1, tonumber(page.chunk_count) do
            page[string.format('c%04d', chunk)] = Hex(part:sub((chunk - 1) * CHUNK_BYTES + 1, chunk * CHUNK_BYTES))
        end
        pages[index] = page
    end
    return out, nil, pages
end

-- 专用 key 只传输导出快照，不注册业务 Store。SaveData 成功后仍须完整回读；导出失败不改变业务健康状态。
local function SaveTextExport(key, protocol, text, meta)
    local payload, err, pages = Build(text, meta, protocol)
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
    -- 单 key 曾在 16383 字节被截断，因此每页最多 4 KiB 原文，HEX 加元数据小于 9 KiB，最多复用 256 个 key。
    -- 各页回读通过后才提交清单；提取端再验页号和校验，拒绝半份或新旧混合报告。
    for index, page in ipairs(pages) do
        local ok, reason = WriteVerified(key .. string.format('_page_%04d', index), page, '第' .. index .. '块')
        if ok ~= true then return false, reason end
    end
    local ok, reason = WriteVerified(key, payload, '清单')
    if ok ~= true then return false, reason end
    return true, { id = payload.report_id, bytes = #text, checksum = payload.checksum }
end
function P:SaveDiagnosticExport(text, meta)
    return SaveTextExport(KEY, PROTOCOL, text, meta)
end
function P:SaveHistoryExport(text, meta)
    -- 复用已验证的小块保存/回读机制，历史有独立清单与页面，不能覆盖用户刚导出的诊断。
    return SaveTextExport(HISTORY_KEY, HISTORY_PROTOCOL, text, meta)
end

-- 提交冻结的完整原文，不能取可能已截断的编辑框当前页。
-- 成功只代表 Native 快照回读通过；txt 仍需本地工具从磁盘提取并验证。
function D:ExportReport(text, meta)
    local ok, result = P:SaveDiagnosticExport(text, meta)
    E.last = ok == true and result or { error = tostring(result) }
    if ok ~= true then return false, result end
    return true, '报告快照已提交；请运行 replicatedsuite 文件夹内“开始自动保存诊断.cmd”并保留窗口，才会生成 Addon/诊断报告 下的 .txt。无需安装 Python。', result
end
