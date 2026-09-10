from pathlib import Path  # 中文维护注释：本 Harness 只读取/执行 FeatureRegistry + Router 的纯元数据代码，不触碰 Native UI、游戏 API、Persistence 或 FeatureRuntime。
import subprocess  # 中文维护注释：使用仓库发布环境已有的 texlua 执行真实 Lua 5.1 风格排序逻辑，避免 Python 重新实现一套比较规则形成假阳性。
import tempfile  # 中文维护注释：临时 Lua 驱动文件仅用于发布门禁，执行结束自动删除，不进入插件运行时或用户存档。

ROOT = Path(__file__).resolve().parents[1]  # 中文维护注释：所有路径从脚本自身解析，禁止依赖 Agent/CI 当前工作目录。
REGISTRY = (ROOT / "features/rs_feature_registry.lua").as_posix()  # 中文维护注释：FeatureRegistry 是导航开发态唯一判定 Authority。
ROUTER = (ROOT / "presentation/v3/navigation/rs_v3_router.lua").as_posix()  # 中文维护注释：Router 只消费 Registry 结果并负责左侧排序/导航标签投影。

lua = r'''
ReplicatedSuite = {} -- 中文维护注释：测试只建立最小全局宿主，使 Registry/Router 能按真实加载顺序注册纯元数据。
dofile("__REGISTRY__") -- 中文维护注释：先加载 FeatureRegistry，验证自动/显式 development state 的真实 Lua 结果。
ReplicatedSuite.UIV3 = {} -- 中文维护注释：Router 按运行时契约挂载到 UIV3；这里不构建 Shell/Native UI。
dofile("__ROUTER__") -- 中文维护注释：再加载 Router，验证完成项优先和未完成标签仅存在 navigationTitle。

local R = ReplicatedSuite.UIV3.Router -- 中文维护注释：后续断言只读取 Router detached rows，不启动任何 Feature Consumer。
local F = ReplicatedSuite.FeatureRegistry -- 中文维护注释：同时读取 Registry 以验证已知 CURRENT 回归覆盖没有被后续元数据改动静默丢失。

local function assertTrue(value, name) -- 中文维护注释：统一 fail-fast，门禁失败时直接输出稳定契约键便于维护者定位。
    if value ~= true then error(name) end -- 中文维护注释：任何排序/标签/显式回归标记退化都必须阻断发布。
end

for _, category in ipairs({"combat", "life", "tools"}) do -- 中文维护注释：只验证用户左侧可滚动业务分类；home/system 不参与开发队列重排需求。
    local seenIncomplete = false -- 中文维护注释：一旦进入未完成区，后续不得再出现完成项，保证“完成在上、未完成在最下面”。
    for _, row in ipairs(R:List(category)) do -- 中文维护注释：使用 Router 真实 List 比较器，覆盖 groupOrder/groupItemOrder 与开发态桶的组合行为。
        if row.navigationIncomplete == true then -- 中文维护注释：未完成路由必须带后缀，同时开始尾部区域。
            seenIncomplete = true -- 中文维护注释：记录尾部分界，后续完成项出现即代表排序回归。
            assertTrue(row.navigationTitle:sub(-15) == "（未完成）", category .. "_incomplete_suffix") -- 中文维护注释：中文 UTF-8 后缀按字节长度验证，仅影响 navigationTitle。
        else
            assertTrue(seenIncomplete == false, category .. "_completed_after_incomplete") -- 中文维护注释：严格保证每个分类所有完成项都位于未完成项之前。
            assertTrue(row.navigationTitle == row.title, category .. "_complete_title_changed") -- 中文维护注释：完成项不得被附加标签或改名。
        end
    end
end

assertTrue(F:Get("life_activities").navigationIncomplete == true, "activities_current_ru_backlog") -- 中文维护注释：CURRENT RU-ACT-01 未关闭前，活动不能因 migrated_m1 旧状态被误排为完成。
assertTrue(F:Get("life_tasks").navigationIncomplete == true, "tasks_current_ru_backlog") -- 中文维护注释：CURRENT RU-TASK-01 未关闭前，任务追踪保持开发中。
assertTrue(F:Get("life_bonds").navigationIncomplete == true, "bonds_current_ru_backlog") -- 中文维护注释：CURRENT RU-BOND-01/02 未关闭前，债券保持开发中。
assertTrue(F:Get("combat_stats").navigationIncomplete == false, "combat_stats_completed") -- 中文维护注释：选取一个稳定完成 Feature 作为正向对照，避免规则把所有项都错误下沉。
assertTrue(F:Get("combat_unit_lines").navigationIncomplete == true, "unit_lines_partial") -- 中文维护注释：migrated_partial 必须自动进入未完成，不依赖手工名单。
assertTrue(F:Get("tools_hotkey_profiles").navigationIncomplete == true, "hotkey_runtime_blocked") -- 中文维护注释：Runtime Blocked 必须自动进入未完成区且不得因此改变其原 blocker 行为。
assertTrue(R:Get("combat.stats").title == "伤害统计", "semantic_title_clean") -- 中文维护注释：页面语义 title 必须保持原名，开发后缀只能存在 navigationTitle。
assertTrue(R:Get("combat.unit_lines").navigationTitle == "单位连线（未完成）", "navigation_suffix_exact") -- 中文维护注释：验证用户实际看到的左侧文本为“名称（未完成）”。

print("NAVIGATION_DEVELOPMENT_ORDER_HARNESS PASS") -- 中文维护注释：稳定成功标记供全工程 Harness 汇总统计。
'''
lua = lua.replace("__REGISTRY__", REGISTRY).replace("__ROUTER__", ROUTER)  # 中文维护注释：只替换当前工程绝对路径，不拼接用户输入或执行外部内容。

with tempfile.NamedTemporaryFile("w", suffix=".lua", encoding="utf-8", delete=False) as fp:  # 中文维护注释：texlua 需要真实文件入口；内容只包含测试驱动且不写工程文件。
    fp.write(lua)  # 中文维护注释：写入临时驱动后立即执行，测试完成后在 finally 删除。
    tmp = Path(fp.name)  # 中文维护注释：保存临时路径用于 subprocess 与可靠清理。

try:  # 中文维护注释：无论 PASS/FAIL 都清理临时文件，避免测试产物污染用户补丁 ZIP。
    proc = subprocess.run(["texlua", str(tmp)], cwd=ROOT, text=True, capture_output=True)  # 中文维护注释：执行真实 Lua 源码；不注入游戏 API，所以任何 Native 依赖都会显式暴露为测试失败。
    if proc.returncode != 0:  # 中文维护注释：保留 texlua stderr/stdout 作为门禁证据，不把失败吞成布尔 false。
        raise SystemExit((proc.stdout + "\n" + proc.stderr).strip())  # 中文维护注释：CI/Agent 可直接看到 Lua assertion/parse 错误。
    print(proc.stdout.strip())  # 中文维护注释：向全工程 Harness 汇总输出单一 PASS 行。
finally:
    tmp.unlink(missing_ok=True)  # 中文维护注释：临时文件不是项目资产，必须在当前进程结束前删除。
