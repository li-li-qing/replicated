# CC-03 小窗交付记录

- 已在既有未提交输入上增量修改 `rs_v3_craft_sidecar.lua`、`rs_craft_window_tests.lua`，没有修改 Domain/Feature/公共框架，没有提交、推送或发布。
- 材料的名称、需求、包/银库存、缺口及劳力使用独立库存 tone；仅背包足量显示绿色与“已备齐”，部分已有、银行待取使用 warning。`owned - fromBank` 计算背包分配量，银行另列文字，未出现“已制作”承诺。
- 新增窄交易列，`binding=bound` 显示紫色绑定；`state=forbidden,source=manual` 显示紫色“不可拍卖（手动）”。交易属性不从价格失败推断。所选材料操作区提供禁买/可买及动态说明 Tooltip。
- 单价列独立使用 info/muted/warning/danger；旧价标“参考”。池行每次复绑由现有 TableView `column.getTone` 刷新各列颜色。
- 比较使用每次 Feature projection 的 revision/status/result 更新；显式现金/含劳目标，两条目标常驻金币、劳力、含劳估价，第三行是选中目标相对当前与整件成品的差额。继续/取消与整套/此项采纳均调用已有 Commands，采纳带 revision、key、objective。
- 显示准备/搜索、预算暂停未证最优、最优（本次参考价）、缺数据、无路、unsupported、不可用与取消；未设劳力折价不以零替代。输入版本改变清除旧结果与采纳资格。
- 默认仍为 400×430，比较区 79 高，打开时材料主区最小 134，保留至少表头和一行材料（53）；没有更改 UI 展开与成本之间的边界，没有新增调度器或 Native API。

## 本轮执行证据

先加入四个实际 RSUI 宿主反例，基线执行为 **51 passed / 4 failed**，随后完成实现。最终新增第五个真实 Feature + Domain + solver + Scheduler 集成用例，验证后台完成事件直接更新已打开小窗，且比较动作不溢出、材料行仍可选择。

命令（cwd `replicatedsuite`）：

```text
python -X utf8 -B -c "from lupa.lua51 import LuaRuntime; lua=LuaRuntime(); lua.globals().dofile('tools/rs_craft_window_tests.lua')"
```

结果：**56 passed / 0 failed**（Lua 5.1）。`git diff --check` 通过。

这些测试保留真实 RSUI、WindowShell、FloatingSurface、Windowing，以及集成用例中的真实 Feature、solver、Scheduler；Native 绘制、鼠标与库存/报价服务仍是离线替身。RU 实机的色彩、文字可读性、银行移动后重核对及真实制作链尚待用户验收。

最终核对仅修正文案：“可直接比较金币；「管理」可设置劳力折价”，明确未设劳力折价也可使用现金比较；无布局与逻辑变更。Lua 5.1 单文件 loadfile 编译通过。
