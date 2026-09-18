-- Regression coverage for RU single-line EditBox caret geometry and delayed
-- OnLostFocus ordering. Uses production primitive/control code with bounded
-- native substitutes; does not claim clipboard contents or RU pixels are emulated.
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; print('PASS text-input '..name)
    else failed = failed + 1; print('FAIL text-input '..name..': '..tostring(err)) end
end

Test('caret API converts requested visual height to RU half-extent', function()
    ReplicatedSuite = { Generation = 1 }
    dofile('ui/rs_ui_native_primitives.lua')
    local UI = ReplicatedSuite.UI
    assert(type(UI.ConfigureEditCaret) == 'function', 'shared caret converter missing')
    local got
    local edit = {
        SetCursorColor = function() end,
        SetCursorHeight = function(_, value) got = value end,
    }
    local ok, nativeHalf = UI:ConfigureEditCaret(edit, 22)
    assert(ok == true and nativeHalf == got, 'caret converter did not report applied native value')
    assert(nativeHalf >= 5 and nativeHalf <= 8,
        '22px single-line editor must not request the old oversized RU cursor half-extent: '..tostring(nativeHalf))
end)

Test('early lost-focus notification preserves still-owned TextInput for copy', function()
    local h = dofile('tools/rs_gear_page_test_host.lua')()
    local edit = assert(h.widgets.v3_gear_create_edit)
    assert(edit:BeginEditing('copy_regression'))
    edit.root.text = '可复制文本'
    assert(edit.root.rsUiKeyboardArmed == true and h.UI.focused == edit.root)
    assert(type(edit.root.events.OnLostFocus) == 'function')
    edit.root.events.OnLostFocus()
    assert(edit:IsEditing() == true, 'late/early lost-focus event ended a still-focused edit')
    assert(edit.root.rsUiKeyboardArmed == true, 'still-focused EditBox lost keyboard ownership; Ctrl+C would fail')
    assert(h.UI.focused == edit.root, 'guard must not steal or clear focus')
    assert(edit._lostFocusTask ~= nil and h.S.Scheduler.tasks[edit._lostFocusTask] ~= nil,
        'ambiguous lost focus must schedule exactly one bounded recheck')
end)

Test('deferred TextInput lost-focus completes after focus really leaves', function()
    local h = dofile('tools/rs_gear_page_test_host.lua')()
    local edit = assert(h.widgets.v3_gear_create_edit)
    assert(edit:BeginEditing('blur_regression'))
    edit.root.text = '最终草稿'
    edit.root.events.OnLostFocus()
    local task = assert(edit._lostFocusTask)
    h.UI.focused = nil -- model Native focus id changing after the early callback
    h.S.Scheduler:RunTask(task)
    assert(edit:IsEditing() == false and edit.root.rsUiKeyboardArmed == false,
        'real blur must still end editing and release keyboard ownership')
    assert(edit._lostFocusTask == nil and h.S.Scheduler.tasks[task] == nil,
        'one-shot focus recheck leaked')
end)

print('TEXT INPUT REGRESSION RESULT '..passed..' passed / '..failed..' failed')
if failed > 0 then error('text input regression failures: '..failed) end
