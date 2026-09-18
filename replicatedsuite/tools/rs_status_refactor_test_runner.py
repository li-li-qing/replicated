#!/usr/bin/env python3
"""开发期离线回归；不进入 toc.g，不模拟已通过 RU 实机验收。
优先使用系统 Lua 5.1；无 CLI 时仅以 liblua5.4 + 兼容垫片运行纯逻辑测试。
"""
from __future__ import annotations
import ctypes
import ctypes.util
from pathlib import Path
import subprocess
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]

UNFINISHED_CLOSURE_TESTS = [
    "tools/rs_activity_tests.lua",
    "tools/rs_task_tests.lua",
    "tools/rs_bonds_tests.lua",
    "tools/rs_bonds_ui_contract_tests.lua",
    "tools/rs_housing_tests.lua",
    "tools/rs_butler_tests.lua",
    "tools/rs_craft_planner_tests.lua",
    "tools/rs_trade_tests.lua",
    "tools/rs_fishing_tests.lua",
    "tools/rs_auction_favorites_tests.lua",
    "tools/rs_team_tools_tests.lua",
    "tools/rs_raid_readiness_tests.lua",
    "tools/rs_pending_ru_navigation_tests.lua",
    "tools/rs_navigation_status_acceptance_tests.lua",
]


def require_test_files(paths: list[str]) -> bool:
    missing = [path for path in paths if not (ROOT / path).is_file()]
    if not missing:
        return True
    print("BLOCKED: required regression fixture(s) missing; no full-suite success claim is allowed:", file=sys.stderr)
    for path in missing:
        print(f"  - {path}", file=sys.stderr)
    return False


def lua_dofiles(paths: list[str]) -> str:
    return "; ".join(f'dofile("{path}")' for path in paths)


def run_lua_files_isolated(paths: list[str], prelude: str) -> None:
    # 维护（test-isolation-1）：B1~B11 套件会安装 Native/全局替身；每份测试必须使用独立 Lua state，
    # 否则前一套的 X2Bag/FeatureRuntime mock 会污染后一套并制造“单跑绿、统一入口红”的假故障。
    for path in paths:
        print(f"[ISOLATED] {path}")
        run_lua(prelude + f'dofile("{path}")')


def run_lua(source: str) -> None:
    for name in ("lua5.1", "luajit", "lua"):
        exe = shutil.which(name)
        if exe:
            result = subprocess.run([exe, "-"], input=source, text=True, cwd=ROOT)
            if result.returncode:
                raise RuntimeError(f"{name}: exit {result.returncode}")
            return
    lib_path = ctypes.util.find_library("lua5.4")
    if not lib_path:
        raise RuntimeError("需要 Lua 5.1 / LuaJIT，或离线 liblua5.4 兼容运行环境")
    lib = ctypes.CDLL(lib_path)
    state_t = ctypes.c_void_p
    lib.luaL_newstate.restype = state_t
    lib.luaL_openlibs.argtypes = [state_t]
    lib.luaL_loadbufferx.argtypes = [state_t, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_char_p]
    lib.luaL_loadbufferx.restype = ctypes.c_int
    lib.lua_pcallk.argtypes = [state_t, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_ssize_t, ctypes.c_void_p]
    lib.lua_pcallk.restype = ctypes.c_int
    lib.lua_tolstring.argtypes = [state_t, ctypes.c_int, ctypes.POINTER(ctypes.c_size_t)]
    lib.lua_tolstring.restype = ctypes.c_void_p
    lib.lua_close.argtypes = [state_t]
    state = lib.luaL_newstate()
    if not state:
        raise RuntimeError("Lua state allocation failed")
    try:
        lib.luaL_openlibs(state)
        raw = source.encode("utf-8")
        result = lib.luaL_loadbufferx(state, raw, len(raw), b"status_refactor_tests", None)
        if not result:
            result = lib.lua_pcallk(state, 0, -1, 0, 0, None)
        if result:
            size = ctypes.c_size_t()
            ptr = lib.lua_tolstring(state, -1, ctypes.byref(size))
            error = ctypes.string_at(ptr, size.value).decode("utf-8", "replace") if ptr else "unknown Lua error"
            raise RuntimeError(error)
    finally:
        lib.lua_close(state)


def main() -> int:
    import os
    os.chdir(ROOT)
    prelude = 'unpack=unpack or table.unpack; loadstring=loadstring or load; table.getn=table.getn or function(t) return #t end;\n'
    isolated_after: list[str] = []
    if "--syntax" in sys.argv:
        paths = sorted(ROOT.rglob("*.lua"))
        source = prelude
        for path in paths:
            import json
            source += f'assert(loadfile({json.dumps(str(path), ensure_ascii=False)}));\n'
        source += f'print("SYNTAX PASS: {len(paths)} Lua files (runtime=" .. _VERSION .. ")")'
    elif "--hud-defaults" in sys.argv:
        # 维护：用户完整11行模板、真实Store/校准/复制往返及旧schema4/5/6指纹；只替换Native/磁盘。
        # 此独立入口不进入toc.g；新默认不等同强制迁移已有布局，也不等同RU实机验收。
        source = prelude + 'dofile("tools/rs_hud_default_template_tests.lua")'
    elif "--hud-template-copy" in sys.argv:
        # 维护（hud-template-copy-2）：实际Draft/Store/公共分页器；Native容量/聊天/选区是可控模型。
        # 独立入口保留原V1纯生成器测试；不把模型通过当作RU剪贴板或聊天渲染验收。
        source = prelude + 'dofile("tools/rs_hud_template_copy_tests.lua")'
    elif "--hud-template" in sys.argv:
        # 维护：真实校准入口/Draft/V1模板和Store只读边界；Native控件、聊天仍为替身。
        # 独立入口不改变历史默认分组，不接入toc.g；输出完整性不等于RU实机聊天容量/复制验收。
        source = prelude + 'dofile("tools/rs_hud_template_tests.lua")'
    elif "--pvp-hud" in sys.argv:
        # 维护：实际事件合并/调度/FrameBudget/Renderer/校准/存档，另测实际RSUI纹理提交。
        # Native/磁盘/屏幕仍是替身；1ms请求代表每渲染帧，不代表实机1000Hz或网络延迟上界。
        source = prelude + 'dofile("tools/rs_pvp_hud_tests.lua"); dofile("tools/rs_pvp_hud_contract_tests.lua"); dofile("tools/rs_hud_info_split_tests.lua"); dofile("tools/rs_gear_score_format_tests.lua")'
    elif "--enemy-boss" in sys.argv:
        # 维护：目标类型事实、实际头顶Renderer、实际计时driver/告警Presenter/Windowing；仅Native/时钟为替身。
        # 独立入口不改变历史分组；Lua5.4兼容垫片测试不能冒充RU Lua5.1/屏幕实测。
        source = prelude + 'dofile("tools/rs_enemy_loadout_tests.lua"); dofile("tools/rs_loadout_hud_ui_tests.lua"); dofile("tools/rs_boss_hud_tests.lua")'
    elif "--random-shop" in sys.argv:
        # 维护：已有只读getter、独立设置事务、Demand/调度和真实RSUI；Native/磁盘为替身。
        # 单独分组保留原默认入口，不把未执行的RU客户端或缺失历史夹具统计为通过。
        source = prelude + 'dofile("tools/rs_random_shop_tests.lua"); dofile("tools/rs_random_shop_ui_tests.lua")'
    elif "--persistence-copy" in sys.argv:
        # 维护：真实Core负坐标传输/耐久失败只读取证和诊断页输入生命周期；独立Native模型，非RU实机。
        # 此入口不改变默认历史分组，不写用户存档；测试夹具/临时产物不得放入运行时TOC或补丁。
        source = prelude + 'dofile("tools/rs_signed_readback_tests.lua"); dofile("tools/rs_persistence_gate_current_health_tests.lua"); dofile("tools/rs_report_selection_tests.lua")'
    elif "--buff-cap" in sys.argv:
        # 中文维护：计数/会话峰值/个人提醒/耐久保存和真实RSUI；Native与磁盘为替身，不证明RU容量或实机通过。
        # 仅新增独立入口，保持其它分组/默认调用次序；本轮测试文件不进入游戏TOC。
        source = prelude + 'dofile("tools/rs_buff_cap_regression_tests.lua"); dofile("tools/rs_buff_cap_ui_tests.lua")'
    elif "--boss-alerts" in sys.argv:
        # 中文维护：首领规则/耐久回读/真实RSUI选择与布局；Native、磁盘和Presenter为替身，非RU验收。
        source = prelude + 'dofile("tools/rs_boss_alerts_regression_tests.lua"); dofile("tools/rs_boss_alerts_ui_tests.lua")'
    elif "--unfinished-closure" in sys.argv:
        # 维护（unfinished-closure-1）：B1~B11 与钓鱼 Hotkey v3 专项必须进入统一入口；implemented_pending_ru 仍属待 RU 验收，
        # 本地 PASS 只能证明离线契约，不得把导航状态提升为 complete。
        if not require_test_files(UNFINISHED_CLOSURE_TESTS): return 2
        try:
            run_lua_files_isolated(UNFINISHED_CLOSURE_TESTS, prelude)
        except RuntimeError as error:
            print(error, file=sys.stderr)
            return 1
        print(f"UNFINISHED_CLOSURE PASS: {len(UNFINISHED_CLOSURE_TESTS)} isolated suite(s)")
        return 0
    elif "--income" in sys.argv:
        # 今日收益：真实账本 + fail-closed CHAT_MESSAGE 结构化适配器。Native 载荷为模型，不等同 RU 实机字段证明。
        source = prelude + 'dofile("tools/rs_daily_ledger_tests.lua"); dofile("tools/rs_daily_income_source_tests.lua"); dofile("tools/rs_home_overview_tests.lua")'
    elif "--overview-v2" in sys.argv:
        # Workbench layout, task read model, official journal capability and ledger projection.
        # Native hosts are test doubles, not an in-client performance certification.
        source = prelude + 'dofile("tools/rs_overview_v2_tests.lua"); dofile("tools/rs_quest_journal_detail_tests.lua"); dofile("tools/rs_ledger_projection_v2_tests.lua")'
    elif "--overview" in sys.argv:
        # Real Feature/Service/RSUI, controlled Native sources; earnings providers are test-only.
        source = prelude + 'dofile("tools/rs_overview_quote_tests.lua"); dofile("tools/rs_compact_tracker_tests.lua"); dofile("tools/rs_daily_ledger_tests.lua"); dofile("tools/rs_daily_income_source_tests.lua"); dofile("tools/rs_home_overview_tests.lua")'
    elif "--report-failures" in sys.argv:
        # Real strict text-cache + Store/EventBus with explicit native truncation models.
        required = ["tools/rs_report_failure_regression_tests.lua"]
        if not require_test_files(required): return 2
        source = prelude + lua_dofiles(required)
    elif "--gear-page" in sys.argv:
        # 维护：真实RSUI布局/表单/虚拟表格/EventBus/ActionRunner/Gear存档；Native为模拟。
        source = prelude + 'dofile("tools/rs_gear_page_regression_tests.lua")'
    elif "--library-runtime" in sys.argv:
        # 维护：真实EventBus owner-first / Scheduler / Api / Store与Button逻辑；Native仍为模拟。
        source = prelude + 'dofile("tools/rs_library_runtime_contract_tests.lua")'
    elif "--capture-library" in sys.argv:
        # Real status Feature/Store/UI bindings and bounded metadata/retention; no RU-client claim.
        source = prelude + 'dofile("tools/rs_tracking_scope_tests.lua"); dofile("tools/rs_tracking_scope_ui_tests.lua"); dofile("tools/rs_status_capture_library_tests.lua")'
    elif "--unit-lines" in sys.argv:
        # 维护：真实Service/Feature/Presenter回归；Native、坐标和调度驱动为模拟，不代表RU实机。
        source = prelude + 'dofile("tools/rs_unit_lines_regression_tests.lua")'
    elif "--colorfield" in sys.argv:
        # 维护：共享 ColorField V2 的布局/事务/Popup 坐标契约；Native 顶层 Window 行为仍需 RU 实机确认。
        source = prelude + 'dofile("tools/rs_colorfield_v2_tests.lua"); dofile("tools/rs_colorfield_popup_positioning_tests.lua")'
    elif "--paged" in sys.argv:
        # Explicit UI navigation + immutable report; no implicit print-to-next behavior.
        source = prelude + 'dofile("tools/rs_report_paging_tests.lua")'
    elif "--udf-numeric" in sys.argv:
        # UDF-derived projection mechanisms, synthetic PII-free fixtures; not native acceptance.
        source = prelude + 'dofile("tools/rs_udf_numeric_regression_tests.lua")'
    elif "--f2-page" in sys.argv:
        # 维护：真实Core/Store/PageHost的构建前隔离；不是F2实际旧档已恢复的证明。
        source = prelude + 'dofile("tools/rs_f2_protected_page_tests.lua")'
    elif "--window-numeric" in sys.argv:
        # 维护：共享Floating单轴旧精度桥、schema5/6和codec1边界；数据为合成，非F2原档。
        source = prelude + 'dofile("tools/rs_window_numeric_recovery_tests.lua")'
    elif "--native-numeric" in sys.argv:
        # 维护：真实跑商取证/有界精度恢复/新旧物理传输；Native 为独立数值损失模型。
        source = prelude + 'dofile("tools/rs_native_numeric_transport_tests.lua")'
    elif "--focus" in sys.argv:
        # 维护：旧聚焦报告兼容入口；当前默认完整故障报告使用--paged回归。
        source = prelude + 'dofile("tools/rs_focus_report_tests.lua")'
    elif "--self-check" in sys.argv:
        # 维护：统一报告/两按钮交互/剪贴板和只读取证，不替代原存档完整性回归。
        source = prelude + 'dofile("tools/rs_self_check_report_tests.lua")'
    elif "--delivery" in sys.argv:
        # 维护：报告交付/无损复制包，Native 接收端模拟，不替代客户端验收。
        source = prelude + 'dofile("tools/rs_self_check_report_tests.lua"); dofile("tools/rs_report_delivery_tests.lua")'
    elif "--pipeline" in sys.argv:
        # 维护：独立复查三个 Store 的真实 API/能力门/存档链路，Native 仅用合成内存盘。
        source = prelude + 'dofile("tools/rs_persistence_pipeline_audit.lua")'
    else:
        # 维护（full-runner-proof-1）：默认入口先确认所有声明为“全量”所依赖的测试文件真实存在。
        # 缺历史夹具时明确 BLOCKED 并非零退出；禁止跳过缺失文件后仍宣称“全量全绿”。B1~B11 与钓鱼 Hotkey v3 专项同时纳入默认集合。
        legacy = [
            "tools/rs_status_refactor_tests.lua", "tools/rs_tracking_scope_tests.lua", "tools/rs_tracking_scope_ui_tests.lua", "tools/rs_persistence_pipeline_audit.lua", "tools/rs_self_check_report_tests.lua",
            "tools/rs_report_delivery_tests.lua", "tools/rs_focus_report_tests.lua", "tools/rs_native_numeric_transport_tests.lua",
            "tools/rs_window_numeric_recovery_tests.lua", "tools/rs_f2_protected_page_tests.lua", "tools/rs_report_paging_tests.lua",
            "tools/rs_udf_numeric_regression_tests.lua", "tools/rs_unit_lines_regression_tests.lua", "tools/rs_colorfield_v2_tests.lua", "tools/rs_colorfield_popup_positioning_tests.lua", "tools/rs_status_capture_library_tests.lua",
            "tools/rs_library_runtime_contract_tests.lua", "tools/rs_gear_page_regression_tests.lua", "tools/rs_report_failure_regression_tests.lua",
            "tools/rs_overview_quote_tests.lua", "tools/rs_compact_tracker_tests.lua", "tools/rs_daily_ledger_tests.lua",
            "tools/rs_daily_income_source_tests.lua", "tools/rs_home_overview_tests.lua", "tools/rs_overview_v2_tests.lua", "tools/rs_quest_journal_detail_tests.lua",
            "tools/rs_ledger_projection_v2_tests.lua",
        ]
        required = legacy + UNFINISHED_CLOSURE_TESTS
        if not require_test_files(required): return 2
        source = prelude + lua_dofiles(legacy)
        isolated_after = UNFINISHED_CLOSURE_TESTS
    try:
        run_lua(source)
        if isolated_after:
            run_lua_files_isolated(isolated_after, prelude)
    except RuntimeError as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
