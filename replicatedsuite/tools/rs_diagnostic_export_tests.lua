-- 中文维护：模拟真实 SaveData 传输边界，报告导出必须验证完整回读，且不得写业务 Store。
local disk, writes, maxPhysicalBytes = {}, 0, 0
ReplicatedSuite = { Persistence = {}, DiagnosticsManager = {}, Generation = 3, ReportCopyTransport = nil }
local S = ReplicatedSuite
S.Api = {
    -- 中文维护：实机 UDF 正文截在 16383 字节；模拟序列化与截断，禁止原样表回传掩盖故障。
    SaveData = function(_, key, value)
        writes = writes + 1
        local rows = {'isTable true\r\n'}
        for name, child in pairs(value) do
            assert(type(child) == 'string', 'export records must be flat ASCII tables')
            rows[#rows + 1] = 'str_' .. name .. ' str_' .. child .. '\r\n'
        end
        local raw = table.concat(rows)
        maxPhysicalBytes = math.max(maxPhysicalBytes, #raw)
        disk[key] = raw:sub(1, 16383)
        return true
    end,
    LoadData = function(_, key)
        local out = {}
        for name, value in (disk[key] or ''):gmatch('str_([_%w]+) str_([^\r\n]+)\r\n') do out[name] = value end
        return out
    end,
}
dofile('core/rs_report_copy_transport.lua')
pcall(dofile, 'core/rs_diagnostic_export.lua')
assert(type(S.DiagnosticsManager.ExportReport) == 'function', 'complete report file export is missing')
local text = ('中文错误\n[FAILED_CHECK] blocker\n'):rep(5000)
assert(S.DiagnosticsManager:ExportReport(text, { id = 'test.3' }))
assert(writes == math.ceil(#text / 4096) + 1, 'pages must be verified before one manifest commit')
assert(maxPhysicalBytes < 9000, 'a Native record exceeded the conservative physical budget')
assert(S.DiagnosticExport.last.bytes == #text)
-- 中文维护：使用同一真实 Lua 生成的 Native 页面让 Python 端交叉验证完整中文正文。
if arg and arg[1] then
    local f = assert(io.open(arg[1], 'wb'))
    for key, raw in pairs(disk) do f:write(key, '\n', tostring(#raw), '\n', raw) end
    f:write('__REPORT__\n', tostring(#text), '\n', text); f:close()
end
local oldLoad = S.Api.LoadData
dofile('core/rs_diagnostic_detail.lua')
local writer=S.DiagnosticDetail:New()
local rows={};for i=1,70 do rows[i]={request=i,state={reason='诊断字段完整保存',raw=string.rep('中文回包证据',120)}}end
writer:Add('detailed_native_fixture',rows)
local detailed=writer:Finish('RS-DETAILED-TEST')
assert(detailed:find('detailed_native_fixture[70]',1,true) and #detailed>100000)
local beforeWrites=writes
assert(S.DiagnosticsManager:ExportReport(detailed,{id='detail-large'}))
assert(writes-beforeWrites==math.ceil(#detailed/4096)+1 and S.DiagnosticExport.last.bytes==#detailed)
assert(maxPhysicalBytes<9000,'detailed export exceeded per-key Native cap')
local manifest = disk[S.DiagnosticExport.key]
S.Api.LoadData = function() return { protocol = 'RS-DIAGNOSTIC-FILE-2-PAGE' } end
local ok, err = S.DiagnosticsManager:ExportReport(text, { id = 'lost-chunks' })
assert(ok == false and tostring(err):find('回读', 1, true), 'truncated readback must fail visibly')
assert(disk[S.DiagnosticExport.key] == manifest, 'failed page must not commit a new manifest')
S.Api.LoadData = oldLoad
S.Api.SaveData = function() return false, 'disk rejected' end
ok, err = S.DiagnosticsManager:ExportReport(text, { id = 'failed-write' })
assert(ok == false and tostring(err):find('disk rejected', 1, true))
assert(S.DiagnosticsManager:ExportReport(string.rep('x',1048577), {}) == false)
print('DIAGNOSTIC_EXPORT PASS: Native 16383-byte cap, paged Chinese report, manifest last, truncated readback, save failure, size limit')
