# CC-02 / CC-03 独立审查

结论：**CC-02 spec compliance 通过，code quality 未发现需修改的问题；CC-03 spec compliance 通过，code quality 未发现需修改的问题。** 本轮没有确认可触发的 Crash、数据丢失、旧建议误采纳或交易属性误判，因此没有列出推测性缺陷。

审查基于 `2026-10-28-craft-cost-execution.md` 的固定共享契约、Feature/UI 交付报告、`2026-10-28-craft-feature-ui-review.tmp` 以及当前实际源码。差异包包含实施前已有相关输入，未将这些输入当作无关内容删除。本审查只新增本报告，没有修改业务源码、测试或无关文件，没有提交。

## CC-02 Feature

- **Spec compliance：通过。** `rs_craft_plan_feature.lua:125-129` 兼容缺失的 `purchaseBlocks` 并拒绝坏类型；`:76-106` 保留限制所需目录身份；`:224-237` 和 `:567-575` 使用 durable 事务，保存拒绝恢复会话状态。清除限制删除键，成功改变限制后使旧比较失效并取消旧询价。
- `:363-408` 只接受匹配物品 ID 的明确静态交易属性；手动禁买与 Native 绑定保持不同来源。`quoteStates`、价格、库存和购买策略分别传递。`:1247-1279` 阻止禁买物品发起拍卖搜索/主动询价，`:243-268`、`:1288-1359` 先退休 token 再释放 requester，晚到回调不能继续旧批次。
- `:160-165`、`:410-425`、`:1153-1182` 分离输入版本与显示发布；每块和采纳前检查价格版本。调度为 50ms，每块最多 200 units，可计时则使用 2ms 软限，10 秒暂停。`:1202-1245` 分别处理继续、取消、显式 cash/combined 采纳及保存失败后可重试的撤销；不存在 UI 默认别名替代显式目标的路径。
- **Code quality：通过。** 使用现有 Store、EventBus、Scheduler 与 Feature 生命周期；计算输入和对外快照均有复制边界。进度通知重入后再次核对 job 身份，取消不会重新登记已退休任务。数量、配方、库存、限制、价格变化通过输入失效路径退休旧结果；最后一个消费者释放及停用清理比较任务。多个消费者仍持有 Feature 时，共享任务生命周期继续遵循既有需求所有权。

## CC-03 UI

- **Spec compliance：通过。** `rs_v3_craft_sidecar.lua:101-121` 分别计算背包/银行库存状态和交易标签；只有背包足量显示已备齐，银行待取保持 warning。`:142-171` 独立使用库存 tone、价格 tone、交易 tone，询价失败/无挂单不转成绑定，绑定与库存足量可同时展示。
- `:767-805` 每列通过 `getTone` 提供当前值；实际共享 `rs_ui_data_views.lua:1950-1974` 每次池行重绑都会提交 tone，因此旧紫色/绿色不会只因控件复用残留。
- `:539-625` 从 envelope 消费状态，分别常驻显示现金/含劳建议，显式切换采纳目标；缺失劳力折价不填零，暂停明确未证最优，继续/取消调用 Feature Commands。采纳请求携带 revision、key、objective，输入版本改变时禁用旧采纳；Feature 再检查真实当前输入。
- **Code quality：通过。** 比较没有引入第二套价格/购买资格计算或后台调度。默认 `400×430`，比较区 79、材料区最小 134；材料列表保持可见、可选，比较按钮和动作宽度有已有真实 RSUI 宿主几何断言。选行后的此项采纳仍传材料 key，不依赖默认 recommendation 视图。

## 本轮证据与边界

- 按委托未重复运行已报告的 Feature 19/19、Window 56/56、Planner 19/19；这些数字属于集成负责人提供的本轮先行执行证据，本报告没有将其表述为审查者重跑结果。
- 审查者额外使用 `lupa.lua51`，只在内存提取既有 Feature 宿主初始化段，加载真实 Domain/solver/Store/Scheduler，验证三条边界：完成建议后 Disable、完成建议后重新选择配方、关闭最后消费者再重开，旧 revision 的采纳均被拒绝。命令退出码 0，输出 `PASS review-boundaries: disable, recipe mutation, last-consumer close/reopen reject old advice (Lua 5.1)`。未修改或新增测试文件。
- 当前结论是源码审查与离线宿主证据。真实 RU Native 报价、绑定枚举、库存读数、绘制文字可读性与操作手感仍待实机；没有把合成制作链当作真实赤石链验收。
