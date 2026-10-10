#!/usr/bin/env python3
# 维护（2026-09-18，startup-source-recovery）：本文件在故障包中有 6 处未解决的 Git 合并冲突。
# 已对照用户此前完整 V3 工程恢复有效实现；Authority、调用数据流和存档协议仍由下方原实现负责，
# 不通过清配置、跳过加载或恢复 Legacy 绕过错误。兼容边界：须与完整 toc.g 及 .18.247 UI 配套；
# 后续合并必须先检查冲突标记、清单完整性与 Lua 语法，再做运行时验收；注释不增加运行期开销。
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

# Phase 1 源码故障域拆分的契约回归（2026-09-28，Batch A）。
# 每个被拆出的 Feature 都必须在这里证明：Feature ID / Store ID / UpdateTopic / Demand owner /
# Commands / Projection shape / ApiDependencies 与拆分前一致，而且只注册一次。
# 中文维护注释：该清单属于默认全量门禁，不并入 UNFINISHED_CLOSURE_TESTS，
# 避免把“拆分契约”与“未完成能力收口”两种语义混在同一个计数里。
FEATURE_SPLIT_TESTS = [
    "tools/rs_feature_slice_split_tests.lua",
]

# Phase 3 源码契约收口的契约回归（2026-09-29，Batch A）。
# 每个批次把 Foundation 里“点名具体业务 Feature”的硬编码门禁搬回 Feature 自己的 acceptance 文件，
# 这里证明搬迁是**无损且严格加强**的：逐条触发搬迁过程中补齐的强度点，并静态断言 core/*.lua
# 不再出现该 Feature 的硬编码访问。与 FEATURE_SPLIT_TESTS 分开计数，语义不同。
CORE_FEATURE_DECOUPLING_TESTS = [
    "tools/rs_core_feature_decoupling_tests.lua",
    "tools/rs_refactor_live_gate_tests.lua",
    # 2026-09-30: real dormant/active feature states and catalog data revisions.
    "tools/rs_live_contract_state_tests.lua",
]


# 2026-09-30: same-viewport reload recovery, genuine scale/viewport migration,
# and independent profile buttons must be in the default gate, not optional-only.
WINDOW_POSITION_TESTS = [
    "tools/rs_window_viewport_tests.lua",
    "tools/rs_window_reload_position_tests.lua",
    "tools/rs_feature_profiles_quick_geometry_tests.lua",
]


# 2026-09-30: actual shared auction services + Trade activity projection; required in full gate.
# Cross-continent Native readiness / actual persistence roundtrip regressions.
BONDS_CROSS_CONTINENT_TESTS = ["tools/rs_bonds_cross_continent_tests.lua"]

AUCTION_USER_PRIORITY_TESTS = [
    "tools/rs_auction_user_priority_tests.lua",
    "tools/rs_auction_user_priority_trade_tests.lua",
    # 维护（2026-10-01）：整条原生询价保护、SWR 阻断与后台需求释放必须进入默认门禁。
    "tools/rs_auction_full_lane_safety_tests.lua",
    "tools/rs_auction_full_lane_trade_tests.lua",
]


# 2026-09-30: real quest-title readiness + original alias/candidate/detail boundaries.
DAILY_AUCTION_TESTS = [
    "tools/rs_daily_auction_title_readiness_tests.lua",
    "tools/rs_daily_auction_multi_quest_tests.lua",
    "tools/rs_auction_workspace_tests.lua",
    "tools/rs_quest_progress_detail_refresh_tests.lua",
]


# 2026-09-30: keep the dedicated copy buffer and economics evidence in the
# default gate. These use real controllers/projections, with Native-only boundaries.
TRADE_COPY_EVIDENCE_TESTS = [
    "tools/rs_diagnostic_copy_box_tests.lua",
    "tools/rs_module_diagnostics_window_tests.lua",
    "tools/rs_module_diagnostics_tests.lua",
    "tools/rs_trade_economics_evidence_tests.lua",
]


# 维护（2026-09-30，feature-profile-failure-evidence-1）：坏业务索引不得假恢复；
# 功能方案失败证据与死亡记录事务回读必须进入默认门禁，而不是只保留可选脚本。
FEATURE_PROFILE_FAILURE_TESTS = [
    "tools/rs_feature_profiles_tests.lua",
    "tools/rs_death_review_integrity_failure_tests.lua",
    "tools/rs_death_review_auto_show_tests.lua",
    "tools/rs_death_review_layout_tests.lua",
    "tools/rs_death_review_status_tests.lua",
    "tools/rs_death_review_content_tests.lua",
]


# 维护（2026-09-30，range-continuity-1）：低帧率刷新、总点预算和只读诊断进入默认门禁。
RANGE_CONTINUITY_TESTS = [
    "tools/rs_range_assist_continuity_tests.lua",
    "tools/rs_range_metric_calibration_tests.lua",
    "tools/rs_visual_guide_resolution_recovery_tests.lua",
    "tools/rs_visual_overlay_layer_tests.lua",
    "tools/rs_visual_settings_input_tests.lua",
]


# 2026-09-30: cold Trade imports, quote recovery/unit-price authority and best-effort Gear transactions.
# Native-only boundary models; these gates do not substitute RU game acceptance.
TRADE_GEAR_RELIABILITY_TESTS = [
    "tools/rs_trade_quote_isolation_price_safety_tests.lua",
    "tools/rs_trade_cost_retry_tests.lua",
    "tools/rs_gear_partial_continuation_tests.lua",
    "tools/rs_gear_ring_identity_tests.lua",
    "tools/rs_trade_quote_unit_price_tests.lua",
    "tools/rs_material_price_swr_tests.lua",
    "tools/rs_gear_costume_title_apply_tests.lua",
    "tools/rs_gear_costume_title_regression_tests.lua",
    "tools/rs_gear_title_effect_authority_tests.lua",
]


# 2026-10-01: legacy shared queue and the cache-first Trade path both remain required.
# Production service tests cover bounded native counts, cache ages and cancellation ownership.
TRADE_REQUOTE_TESTS = [
    "tools/rs_trade_single_query_transport_tests.lua",
    "tools/rs_trade_material_quote_service_tests.lua",
    "tools/rs_trade_requote_pipeline_tests.lua",
    "tools/rs_trade_requote_e2e_tests.lua",
]

# 2026-10-07 release gate: recent user-visible behavior and migration safety
# must remain mandatory, not silently disappear behind a passing legacy group.
# Native boundaries are models; this gate does not certify live RU behavior.
RELEASE_READINESS_TESTS = [
    "tools/rs_treasure_double_click_tests.lua",
    "tools/rs_buff_tracking_ux_tests.lua",
    "tools/rs_status_tracking_grid_tests.lua",
    "tools/rs_unified_cooldown_tests.lua",
    "tools/rs_batch_import_authority_tests.lua",
    "tools/rs_signed_readback_tests.lua",
    "tools/rs_transport4_dual_loss_recovery_tests.lua",
    "tools/rs_cooldown_auto_discovery_tests.lua",
    "tools/rs_cooldown_hud_pipeline_tests.lua",
    "tools/rs_bonds_daily_cache_tests.lua",
    "tools/rs_combat_basic_statistics_tests.lua",
    "tools/rs_combat_basic_statistics_ui_tests.lua",
    "tools/rs_combat_history_integrity_tests.lua",
    "tools/rs_combat_kill_diagnostics_tests.lua",
    "tools/rs_combat_statistics_layout_tests.lua",
    "tools/rs_hud_all_preview_tests.lua",
    "tools/rs_gear_score_format_tests.lua",
    "tools/rs_hud_default_template_tests.lua",
    "tools/rs_pvp_hud_tests.lua",
    "tools/rs_ranged_weapon_default_tests.lua",
    "tools/rs_feature_profiles_catalog_sync_tests.lua",
    "tools/rs_feature_retirement_tests.lua",
    "tools/rs_trade_auction_sort_tests.lua",
    "tools/rs_diagnostic_export_tests.lua",
    "tools/rs_boss_simulation_lifetime_tests.lua",
    "tools/rs_main_shell_visibility_tests.lua",
    "tools/rs_bag_settings_page_tests.lua",
]


def require_test_files(paths: list[str]) -> bool:
    missing = [path for path in paths if not (ROOT / path).is_file()]
    if not missing:
        return True
    print("BLOCKED: required regression fixture(s) missing; no full-suite success claim is allowed:", file=sys.stderr)
    for path in missing:
        print(f"  - {path}", file=sys.stderr)
    return False




def require_transitive_test_dependencies(paths: list[str]) -> bool:
    # Phase 0 baseline gate: top-level existence is insufficient when historical suites
    # still dofile nested hosts/fixtures. Audit literal repository-relative dependencies
    # before running anything so one early failure cannot hide the remaining blockers.
    try:
        from rs_test_dependency_audit import audit
    except ImportError:
        import importlib.util
        spec = importlib.util.spec_from_file_location("rs_test_dependency_audit", ROOT / "tools/rs_test_dependency_audit.py")
        if spec is None or spec.loader is None:
            print("BLOCKED: cannot load transitive test dependency audit", file=sys.stderr)
            return False
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        audit = module.audit
    _, missing = audit(paths)
    if not missing:
        return True
    print("BLOCKED: nested regression dependency file(s) missing; no full-suite success claim is allowed:", file=sys.stderr)
    for path, parents in missing.items():
        print(f"  - {path}", file=sys.stderr)
        for parent in parents[:4]:
            print(f"      required by {parent}", file=sys.stderr)
        if len(parents) > 4:
            print(f"      ... +{len(parents)-4} more parent(s)", file=sys.stderr)
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
    if "--native-dependency" in sys.argv:
        # Phase 0 FND-016: implementation/Registry Native ownership parity + shared-service inventory.
        # A return code of 2 means the audit ran but a verified NativeContract namespace is still missing.
        try:
            from rs_native_dependency_audit import main as native_dependency_main
        except ImportError:
            import importlib.util
            spec = importlib.util.spec_from_file_location("rs_native_dependency_audit", ROOT / "tools/rs_native_dependency_audit.py")
            if spec is None or spec.loader is None:
                print("BLOCKED: cannot load native dependency audit", file=sys.stderr)
                return 2
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            native_dependency_main = module.main
        return int(native_dependency_main())
    elif "--syntax" in sys.argv:
        paths = sorted(ROOT.rglob("*.lua"))
        source = prelude
        for path in paths:
            import json
            source += f'assert(loadfile({json.dumps(str(path), ensure_ascii=False)}));\n'
        source += f'print("SYNTAX PASS: {len(paths)} Lua files (runtime=" .. _VERSION .. ")")'
    elif "--bonds-cross-continent" in sys.argv:
        if not require_test_files(BONDS_CROSS_CONTINENT_TESTS): return 2
        if not require_transitive_test_dependencies(BONDS_CROSS_CONTINENT_TESTS): return 2
        try:
            run_lua_files_isolated(BONDS_CROSS_CONTINENT_TESTS, prelude)
        except RuntimeError as error:
            print(error, file=sys.stderr)
            return 1
        print(f"BONDS_CROSS_CONTINENT PASS: {len(BONDS_CROSS_CONTINENT_TESTS)} suite(s)")
        return 0
    elif "--auction-user-priority" in sys.argv:
        if not require_test_files(AUCTION_USER_PRIORITY_TESTS): return 2
        if not require_transitive_test_dependencies(AUCTION_USER_PRIORITY_TESTS): return 2
        try:
            run_lua_files_isolated(AUCTION_USER_PRIORITY_TESTS, prelude)
        except RuntimeError as error:
            print(error, file=sys.stderr)
            return 1
        print(f"AUCTION_USER_PRIORITY PASS: {len(AUCTION_USER_PRIORITY_TESTS)} suite(s)")
        return 0
    elif "--window-reload-position" in sys.argv:
        if not require_test_files(WINDOW_POSITION_TESTS): return 2
        if not require_transitive_test_dependencies(WINDOW_POSITION_TESTS): return 2
        try:
            run_lua_files_isolated(WINDOW_POSITION_TESTS, prelude)
        except RuntimeError as error:
            print(error, file=sys.stderr)
            return 1
        print(f"WINDOW_POSITION PASS: {len(WINDOW_POSITION_TESTS)} suite(s)")
        return 0
    elif "--window-viewport" in sys.argv:
        # 维护：独立 Native 窗口模型执行真实 Api/Layout/Windowing/Shell/Surface 与完整 viewport 矩阵。
        # 不替换缺失历史夹具，不改变默认全量的 BLOCKED 判据；通过不等同 RU Native/OnScale 验收。
        required = ["tools/rs_window_viewport_test_host.lua", "tools/rs_window_viewport_tests.lua"]
        if not require_test_files(required): return 2
        source = prelude + lua_dofiles(required[1:])
    elif "--activity-layout" in sys.argv:
        # 维护（activity-section-pack-1）：真实 ActivityLists 分区器 + 受控 TableView 几何替身；
        # 覆盖特定窗口高度的中段空白、极小高度降级与混合计数矩阵，不等同 RU Native 渲染验收。
        required = ["tools/rs_activity_lists_layout_tests.lua"]
        if not require_test_files(required): return 2
        source = prelude + lua_dofiles(required)
    elif "--foundation-lifecycle" in sys.argv:
        # 维护（foundation-lifecycle-1）：真实事件/调度/刷新链路，独立 Native/时钟故障模型。
        # 不依赖缺失历史 UI host，不改变默认全量的 BLOCKED 判据，不把兼容 Lua 运行算作 RU 验收。
        required = ["tools/rs_foundation_lifecycle_tests.lua"]
        if not require_test_files(required): return 2
        source = prelude + lua_dofiles(required)
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
        # 2026-10-06 用户删除随机商店计数；旧快捷入口改为验证功能退役，而非装载已删除源码。
        source = prelude + 'dofile("tools/rs_feature_retirement_tests.lua")'
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
        if not require_transitive_test_dependencies(UNFINISHED_CLOSURE_TESTS): return 2
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
    elif "--cooldown" in sys.argv:
        # CooldownObservationV3 V4: Skill-ID-only, event-independent Native cooldown authority with bounded READY probe and full demand release; Native transport is a model.
        source = prelude + 'dofile("tools/rs_cooldown_observation_tests.lua")'
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
    elif "--feature-split" in sys.argv:
        # Phase 1 Batch A：只跑“源码故障域拆分契约”。每个 Feature 独立进程，
        # 避免上一个套件的 Store/FeatureRuntime 替身污染下一个 Feature 的契约断言。
        if not require_test_files(FEATURE_SPLIT_TESTS): return 2
        if not require_transitive_test_dependencies(FEATURE_SPLIT_TESTS): return 2
        try:
            run_lua_files_isolated(FEATURE_SPLIT_TESTS, prelude)
        except RuntimeError as error:
            print(error, file=sys.stderr)
            return 1
        print(f"FEATURE_SPLIT PASS: {len(FEATURE_SPLIT_TESTS)} suite(s)")
        return 0
    elif "--daily-auction" in sys.argv:
        if not require_test_files(DAILY_AUCTION_TESTS): return 2
        if not require_transitive_test_dependencies(DAILY_AUCTION_TESTS): return 2
        try:
            run_lua_files_isolated(DAILY_AUCTION_TESTS, prelude)
        except RuntimeError as error:
            print(error, file=sys.stderr)
            return 1
        print(f"DAILY_AUCTION PASS: {len(DAILY_AUCTION_TESTS)} suite(s)")
        return 0
    elif "--trade-requote" in sys.argv:
        if not require_test_files(TRADE_REQUOTE_TESTS): return 2
        if not require_transitive_test_dependencies(TRADE_REQUOTE_TESTS): return 2
        try:
            run_lua_files_isolated(TRADE_REQUOTE_TESTS, prelude)
        except RuntimeError as error:
            print(error, file=sys.stderr)
            return 1
        print(f"TRADE_REQUOTE PASS: {len(TRADE_REQUOTE_TESTS)} suite(s)")
        return 0
    elif "--trade-gear-reliability" in sys.argv:
        if not require_test_files(TRADE_GEAR_RELIABILITY_TESTS): return 2
        if not require_transitive_test_dependencies(TRADE_GEAR_RELIABILITY_TESTS): return 2
        try:
            run_lua_files_isolated(TRADE_GEAR_RELIABILITY_TESTS, prelude)
        except RuntimeError as error:
            print(error, file=sys.stderr)
            return 1
        print(f"TRADE_GEAR_RELIABILITY PASS: {len(TRADE_GEAR_RELIABILITY_TESTS)} suite(s)")
        return 0
    elif "--range-continuity" in sys.argv:
        if not require_test_files(RANGE_CONTINUITY_TESTS): return 2
        if not require_transitive_test_dependencies(RANGE_CONTINUITY_TESTS): return 2
        try:
            run_lua_files_isolated(RANGE_CONTINUITY_TESTS, prelude)
        except RuntimeError as error:
            print(error, file=sys.stderr)
            return 1
        print(f"RANGE_CONTINUITY PASS: {len(RANGE_CONTINUITY_TESTS)} suite(s)")
        return 0
    elif "--feature-profile-failure" in sys.argv:
        if not require_test_files(FEATURE_PROFILE_FAILURE_TESTS): return 2
        if not require_transitive_test_dependencies(FEATURE_PROFILE_FAILURE_TESTS): return 2
        try:
            run_lua_files_isolated(FEATURE_PROFILE_FAILURE_TESTS, prelude)
        except RuntimeError as error:
            print(error, file=sys.stderr)
            return 1
        print(f"FEATURE_PROFILE_FAILURE PASS: {len(FEATURE_PROFILE_FAILURE_TESTS)} suite(s)")
        return 0
    elif "--core-feature-decoupling" in sys.argv:
        # Phase 3 Batch A：只跑“Core 不再硬编码认识业务 Feature”的搬迁契约。独立进程，
        # 避免上一个套件的 ReplicatedSuite 替身污染本套件的最小离线宿主。
        if not require_test_files(CORE_FEATURE_DECOUPLING_TESTS): return 2
        if not require_transitive_test_dependencies(CORE_FEATURE_DECOUPLING_TESTS): return 2
        try:
            run_lua_files_isolated(CORE_FEATURE_DECOUPLING_TESTS, prelude)
        except RuntimeError as error:
            print(error, file=sys.stderr)
            return 1
        print(f"CORE_FEATURE_DECOUPLING PASS: {len(CORE_FEATURE_DECOUPLING_TESTS)} suite(s)")
        return 0
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
        required = legacy + UNFINISHED_CLOSURE_TESTS + FEATURE_SPLIT_TESTS + CORE_FEATURE_DECOUPLING_TESTS + WINDOW_POSITION_TESTS + AUCTION_USER_PRIORITY_TESTS + BONDS_CROSS_CONTINENT_TESTS + DAILY_AUCTION_TESTS + TRADE_COPY_EVIDENCE_TESTS + FEATURE_PROFILE_FAILURE_TESTS + RANGE_CONTINUITY_TESTS + TRADE_GEAR_RELIABILITY_TESTS + TRADE_REQUOTE_TESTS + RELEASE_READINESS_TESTS
        if not require_test_files(required): return 2
        if not require_transitive_test_dependencies(required): return 2
        source = prelude + lua_dofiles(legacy)
        isolated_after = UNFINISHED_CLOSURE_TESTS + FEATURE_SPLIT_TESTS + CORE_FEATURE_DECOUPLING_TESTS + WINDOW_POSITION_TESTS + AUCTION_USER_PRIORITY_TESTS + BONDS_CROSS_CONTINENT_TESTS + DAILY_AUCTION_TESTS + TRADE_COPY_EVIDENCE_TESTS + FEATURE_PROFILE_FAILURE_TESTS + RANGE_CONTINUITY_TESTS + TRADE_GEAR_RELIABILITY_TESTS + TRADE_REQUOTE_TESTS + RELEASE_READINESS_TESTS
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
