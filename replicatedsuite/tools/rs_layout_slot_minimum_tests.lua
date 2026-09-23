-- 中文维护：真实 RSUI Panel Measure/Layout，Native 几何来自测试宿主。
-- 回归 2026-09-14：Linear Measure 忽略 slot.minHeight/minWidth 时，父容器会低估所需尺寸；
-- Layout 随后又按最小值排版，造成子项溢出/裁切，看起来像标题、颜色、状态文本互相重叠。
local Base = dofile('tools/rs_gear_page_test_host.lua')
local passed, failed = 0, 0
local function Test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; print('PASS layout-slot-min '..name)
    else failed = failed + 1; print('FAIL layout-slot-min '..name..': '..tostring(err)) end
end

Test('vertical measure honors auto slot minimums before arrange', function()
    local h = Base({width=420,height=320})
    local R = h.S.RSUI
    local host = h.Native(nil, 'layout_min_host', 0, 0, 240, 200)
    local box = R:VerticalBox({id='layout_min_box', parent=host, gap=5})
    local a = R:Panel({id='layout_min_a', parent=box, width=20, height=1,
        slot={size='auto', minHeight=30, hAlign='fill'}})
    local b = R:Panel({id='layout_min_b', parent=box, width=20, height=1,
        slot={size='auto', minHeight=24, hAlign='fill'}})
    local _, desiredH = box:Measure(240,200)
    assert(desiredH >= 59, 'Measure underreported slot minima: '..tostring(desiredH))
    box:Layout(0,0,240,desiredH)
    assert(a.height >= 30 and b.height >= 24, 'arranged below declared minima')
    assert(b.y >= a.y + a.height + 5 - 0.01, 'children overlap after layout')
end)

Test('horizontal measure honors fill/auto slot min widths consistently', function()
    local h = Base({width=420,height=320})
    local R = h.S.RSUI
    local host = h.Native(nil, 'layout_min_host_x', 0, 0, 300, 80)
    local row = R:HorizontalBox({id='layout_min_row', parent=host, gap=6})
    R:Panel({id='layout_min_x_a', parent=row, width=1, height=20,
        slot={size='auto', minWidth=90, hAlign='fill'}})
    R:Panel({id='layout_min_x_b', parent=row, width=1, height=20,
        slot={size='fill', fill=1, minWidth=120, hAlign='fill'}})
    local desiredW = select(1,row:Measure(300,80))
    assert(desiredW >= 216, 'Measure underreported horizontal slot minima: '..tostring(desiredW))
end)

print('LAYOUT SLOT MINIMUM RESULTS: '..passed..' passed / '..failed..' failed')
assert(failed==0,tostring(failed)..' layout slot minimum regressions')
