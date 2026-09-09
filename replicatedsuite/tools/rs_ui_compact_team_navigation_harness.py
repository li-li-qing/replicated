from pathlib import Path  # 中文维护注释：静态 Harness 只读取仓库源码验证 UI/导航契约，不执行游戏 API、Native UI 或运行时 Feature。

ROOT = Path(__file__).resolve().parents[1]  # 中文维护注释：以项目根目录为唯一解析基准，避免测试依赖调用者当前工作目录。

def text(rel):  # 中文维护注释：统一按 UTF-8 读取目标源码，保证中文控件文本与维护注释可被稳定断言。
    return (ROOT / rel).read_text(encoding="utf-8")  # 中文维护注释：Harness 只做只读源码检查，不写入任何生产文件或持久化数据。

def require(name, cond):  # 中文维护注释：所有新增紧凑 UI/团队导航契约都通过同一 fail-fast 断言输出，便于发布门禁定位。
    if not cond:  # 中文维护注释：任一核心契约缺失都必须阻断 Harness，防止视觉修复在后续重构中静默回退。
        raise AssertionError(name)  # 中文维护注释：错误名称即稳定契约键，CI/Agent 可直接定位失败项。
    print("PASS", name)  # 中文维护注释：成功项保持项目现有 Harness 的简洁 PASS 输出格式。

registry = text("features/rs_feature_registry.lua")  # 中文维护注释：读取 Feature 元数据，验证隐藏团队子页拥有父导航归属但不改变 Feature 身份。
router = text("presentation/v3/navigation/rs_v3_router.lua")  # 中文维护注释：读取 Router，验证父导航元数据只被透传到解析结果。
shell = text("presentation/v3/rs_v3_shell.lua")  # 中文维护注释：读取 Shell，验证主侧栏选中态使用父导航而真实 PageHost route 保持子页。
raid = text("presentation/v3/pages/rs_v3_raid_readiness_page.lua")  # 中文维护注释：读取战备页，验证团队中心上下文与局部子导航存在。
healer = text("presentation/v3/pages/rs_v3_healer_page.lua")  # 中文维护注释：读取治疗页，防止校准说明卡重新占满剩余页面高度。
trade_widget = text("presentation/v3/widgets/rs_v3_life_economy_widgets.lua")  # 中文维护注释：读取跑商 Widget，验证三行 HUD 与原语义控件 ID 延续。
trade_feature = text("features/life/rs_life_m16_bundle.lua")  # 中文维护注释：读取跑商 Feature，只验证窗口 policy/兼容投影，不修改业务 Authority。

require("team_child_parent_metadata", registry.count('navigationParentRoute = "combat.team_tools"') >= 3)  # 中文维护注释：战备/招募/攻城三个隐藏子页必须统一视觉归属团队中心。
require("router_parent_passthrough", "navigationParentRoute = feature.navigationParentRoute" in router)  # 中文维护注释：Router 必须从 Registry 取父导航元数据，禁止 Shell 硬编码业务路由。
require("shell_parent_highlight", "navigationRoute = tostring(resolved.navigationParentRoute" in shell)  # 中文维护注释：Shell 必须独立计算侧栏选中路由，不能把 PageHost 真实 route 改成父页面。
require("raid_stays_in_team_center_surface", '"团队中心"' in raid and "v3_raid_readiness_team_tabs" in raid)  # 中文维护注释：战备页必须保留团队中心标题和局部导航，修复“点击后跳到另一页”的视觉割裂。
require("healer_calibration_not_fill", 'id = "v3_healer_calibration_panel"' in healer and 'slot = { size = "auto", minHeight = 88' in healer)  # 中文维护注释：治疗校准说明卡必须是 auto 高度，禁止重新使用 fill 制造大面积空白。
require("trade_compact_three_rows", 'height = 90' in trade_widget and 'text = "起"' in trade_widget and 'text = "到"' in trade_widget)  # 中文维护注释：跑商操作区必须维持 90px 三行结构与同一行起/终点选择。
require("trade_semantic_ids_preserved", all(token in trade_widget for token in [  # 中文维护注释：布局重构必须完整保留八个稳定控件 ID，保护绑定、Fence、诊断与升级兼容。
    'id = "v3_life_trade_widget_from"', 'id = "v3_life_trade_widget_to"',  # 中文维护注释：路线起点/终点 ID 不得因合并行布局而改名。
    'id = "v3_life_trade_widget_ratio_mode"', 'id = "v3_life_trade_widget_commerce_mode"',  # 中文维护注释：货率模式与熟练度模式 ID 必须保持历史语义。
    'id = "v3_life_trade_widget_quote"', 'id = "v3_life_trade_widget_favorite"',  # 中文维护注释：询价与收藏路线选择仍由原 Command/投影契约驱动。
    'id = "v3_life_trade_widget_favorite_toggle"', 'id = "v3_life_trade_widget_sort"']))  # 中文维护注释：收藏切换与排序选择器继续复用既有绑定标识。
require("trade_compact_policy", "defaultWidth = 410, defaultHeight = 306, minWidth = 320, minHeight = 228" in trade_feature)  # 中文维护注释：跑商窗口默认/最小尺寸必须维持紧凑预算，防止后续无意回到 470×374 旧布局。
require("trade_legacy_default_projection", "TradeWidgetWindowStateBase" in trade_feature and "Number(state.width) == 470" in trade_feature and "state.width, state.height = 410, 306" in trade_feature)  # 中文维护注释：旧精确默认尺寸只能在展示边界压缩，禁止为纯 UI 变化改 Store schema 或持久化指纹。
