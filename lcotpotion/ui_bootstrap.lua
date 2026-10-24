-- 中文维护：RU Addon的Lua环境不能按共享_G假定；与现有../globals TOC用法一致，在LCot环境载入Suite UI源码闭包。
local P = LCotPotionSignal
local previous = ReplicatedSuite
if previous and previous.lcotUIOwner ~= true then
    P.externalSuiteUI = previous
    ReplicatedSuite = nil -- 中文维护：确有同环境Suite时，下列共享文件的既有nil门使其跳过重装，ui_host末尾恢复原实例。
    return
end
if previous and previous.UI then
    if previous.UI.QuiesceKeyboardInput then pcall(previous.UI.QuiesceKeyboardInput, previous.UI, "lcot_ui_reload", true) end
    if previous.UI.HideAll then pcall(previous.UI.HideAll, previous.UI) end
end
local S = { lcotUIOwner = true, Generation = P.generation, ArchitectureMode = "v3_rebuild", Config = { settings = {} }, UIV3 = {},
    AppState = { settings = { addonScale = 1, fontScale = 1 } }, NativeIdentity = { maxPhysicalLength = 15, sequence = 0, logicalToPhysical = {}, physicalToLogical = {} } }
ReplicatedSuite = S
P.uiLibrary = S
function P:GetThresholdUI() return self.uiLibrary or ReplicatedSuite end -- 中文维护：只读本Addon明确绑定的UI上下文，不能把另一插件是否开窗当加载证据。
S.SafeTraceback = function(err) return tostring(err) end
S.NowMs = function() return P.now end
S.SafeChat = function(message) P.uiLibraryError = tostring(message) end
S.RecordLog = function(_, _, message) P.uiLibraryError = tostring(message) end
S.WarnOnce = function(_, message) P.uiLibraryError = tostring(message) end
S.DiagnosticsManager = { Error = function(_, _, code, message, context) P.uiLibraryError = tostring(code) .. ":" .. tostring(context and (context.error or context.detail) or message) end } -- 中文维护：库构建失败回到LCot已有提示，不把Native构建错误误报成另一个插件未打开。
function S.PhysicalId(logicalId)
    local ids = S.NativeIdentity
    local cached = ids.logicalToPhysical[logicalId]
    if cached then return cached end
    ids.sequence = ids.sequence + 1
    local physical = "lc" .. tostring(S.Generation) .. "_" .. tostring(ids.sequence) -- 中文维护：配套Suite物理名使用rs前缀；此库上下文使用短lc前缀，避免两个Addon的原生注册表撞名。
    ids.logicalToPhysical[logicalId], ids.physicalToLogical[physical] = physical, logicalId
    return physical
end
