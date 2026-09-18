# 开发任务书：快捷键方案「导出 / 导入」（跨账号迁移游戏按键绑定）

> **怎么用本文档**：把全文原样粘贴给接手的 AI 即可。它是一个自包含的任务书，不需要额外上下文。
>
> 目标项目：Replicated Suite —— ArcheRage RU 客户端的 Lua addon
> 编写日期：2026-09-12

---

## 0. 一句话目标

让插件能把玩家在游戏里配置好的**按键绑定**（`Esc → 选项 → 按键设置`）导出成一段可携带的文本，
并在**另一个游戏账号**登录后导入恢复，免去手动逐个重设。

典型场景：玩家换号，希望新号沿用旧号的整套键位。

---

## 1. 先读这些文件（权威来源，禁止凭印象或旧上下文推断）

| 文件 | 作用 |
|---|---|
| `Addon/replicatedsuite/Docs/README.md` | 插件唯一的背景 + 框架文档。**先读这个** |
| `Addon/z_api_functions/README.md` | 原生 API 参考库的定位与使用规则 |
| `Addon/z_api_functions/api_functions.lua` | 客户端导出函数清单（Allowed 名单）。**第 2393–2439 行是 X2Hotkey** |
| `Addon/z_api_functions/api_capabilities_ru_20260828.lua` | RU 官方能力快照（enabled / disabled / removed） |
| `Addon/replicatedsuite/core/rs_api_capabilities.lua` | **运行时能力门的唯一权威**，所有 Native 调用必须先在这里登记 |
| `Addon/replicatedsuite/features/rs_feature_registry.lua` | Feature 注册表，搜 `tools_hotkey_profiles` |
| `Addon/replicatedsuite/features/tools/random_shop/` | 一个完整 tool feature 的三文件范式（authority / feature / acceptance），照它做 |
| `Addon/replicatedsuite/core/rs_report_copy_transport.lua` | 既有的文本导出 / 复制通道，导出功能可复用 |
| `Addon/参考的项目/参考的项目2/ArcheRage-addons-master/z_pub_wip/petrebinder.lua` | **现成的热键写入示例**，见下面第 3.3 节 |

---

## 2. 已实测的环境事实（直接用，不要重新验证这些结论）

| 项 | 值 |
|---|---|
| 客户端根目录 | `d:\Game\Arage\ArcheRage`（`C:\ArcheRage0\Working` 是指向它的 junction） |
| 客户端 userdir | `C:\Users\23118\Documents\ArcheRage` |
| 插件源码 | `<userdir>\Addon\replicatedsuite` |
| 插件存档（leveldb / RocksDB） | `<userdir>\USERcb92fd1887b25ed41a981fa05e29a931\udf\` |
| 插件 SaveKey | `replicated_suite_v1` |

**关键结论：游戏原生按键绑定不在本地任何文件里，它随账号存在服务器上。**

实测依据：
- `<userdir>` 整棵树、客户端根目录、`bin64`，都没有任何键位相关文件；
- 把 6MB 的 `udf/` RocksDB 全量 dump 成文本后检索，`hotkey` / `keybind` / `binding` **命中 0 次**（里面只有 `replicated_suite_v1*` 这批插件存档 key）；
- `ArcheRage.log:872` 确认 leveldb 路径：`leveldb(1) initialized (folder: c:/archerage0/documents/usercb92…/udf)`；
- ArcheRage 官方论坛同题帖确认 "Game configs are also saved to your account anyway"，另有玩家删掉整个 Documents 文件夹后 "everything was resetted except for keybind"。

**推论（决定了整个架构）**：跨账号迁移**没有"复制文件"这条路**。
只能是：**旧号读出 → 生成可携带文本 → 新号导入写入**，载体不能存在 udf 里。

### 2.1 可携带载体：已实测的约束（别自己想当然）

**先记住 `api_functions.lua` 的三段结构**（每个命名空间都按这个排布）：

```
-- X2Foo
Global variables                 ← 常量 / 枚举
Allowed functions                ← 允许 addon 调用 ✅
Available/not allowed functions  ← 客户端里有，但【不允许 addon 调用】❌
```

判断能不能用，**必须看它落在哪一段**，不能只看到函数名就下结论。

| 通道 | 状态 | 依据 |
|---|---|---|
| addon 写磁盘文件 | **清单里没有任何文件 IO 函数**（无 `SaveFile` / `WriteFile` / `OpenFile`），不可用 | `api_functions.lua` 全文检索。注意游戏根目录那些 `dpsmeter_settings.txt` / `*WindowPos.txt` 是**客户端自身**写的，不是 addon |
| 写系统剪贴板 | **不可用**。`SetClipboardText(text)` 虽然存在（`api_functions.lua:276`），但它落在 **"Available/not allowed functions"** 段 | `api_functions.lua` 第 183–289 行即为该 Not-allowed 段；实机记录同样报 `Clipboard unavailable` |
| 读系统剪贴板 | **不可用**，连 Set 都不允许，更没有 Get | 同上 |
| 游戏内输入框 `SetText` / `GetText` | **可用**，是既有报告的现成通道 | `core/rs_report_copy_transport.lua` 头部注释：「Presentation 仍须 Set/GetText 回读」 |

`core/rs_report_copy_transport.lua` 的头部实机记录（2026-09-12）：

> 实机完整报告 108833 字节且 **Clipboard unavailable**；原页面把整份正文塞进 Native 输入框，截断后清空……
> 本模块仅压缩复制文本……**不访问 Native/磁盘/剪贴板**。

**由此得出的现实方案**：

- **导出**：把方案文本显示在游戏内输入框里，玩家手动复制走（`SetClipboardText` 不可用，别指望一键复制）。
- **导入**：玩家把文本粘贴进插件提供的输入框 → 插件 `GetText` 读回 → 解析 → 写入。
- 按键方案的文本量远小于 108KB 的报告（通常几十行），**不需要走 LZB1 压缩**，但应复用同一套"写入后回读校验"的思路。

---

## 3. 原生 API：X2Hotkey

### 3.1 Allowed（可用）

```
SaveHotKey()
BindingToOption()
OptionToBinding()
GetOptionBinding(action, index, option, arg)
GetOptionBindingButton(buttonName, index)
SetOptionBindingButtonWithIndex(buttonName, key)
SetOptionBindingWithIndex(action, key, index, arg)
RemoveOptionBinding(action, index, arg)
EnableHotkey(enable)
IsValidActionName(action)
IsOverridableAction(action)
GetBindingUiEvent(actionName, index)
SetBindingUiEvent(actionName, key)
SetBindingUiEventWithIndex(actionName, key, index)
GetOptionBindingUiEvent(actionName, index)
SetOptionBindingUiEvent(actionName, key)
SetOptionBindingUiEventWithIndex(actionName, key)
```

### 3.2 NOT Allowed（不可用，别浪费时间试）

```
InitOptionHotKey()
GetBinding / SetBinding / SetOptionBinding
GetBindingSpell / SetBindingSpell / SetBindingSpellWithIndex
GetBindingButton / SetBindingButton / SetOptionBindingButton / SetBindingButtonWithIndex
SetBindingItem / SetBindingItemWithIndex / SetBindingWithIndex
GetTemporaryBindingButton / SetTemporaryBindingButton
ExcuteActionHandler
```

### 3.3 已验证的真实调用范例

来源：`Addon/参考的项目/…/z_pub_wip/petrebinder.lua`（社区现成 addon，可直接参考写法）

```lua
ADDON:ImportAPI(API_TYPE.CHAT.id)
ADDON:ImportAPI(API_TYPE.HOTKEY.id)

X2Hotkey:BindingToOption()   -- 该 addon 在加载阶段先调用一次

-- 写入：把 "CTRL-b" 绑到 ride_pet_action_bar_button 的 index=1 / arg=1
X2Hotkey:SetOptionBindingWithIndex("ride_pet_action_bar_button", "CTRL-b", 1, 1)

X2Hotkey:SaveHotKey()        -- 写完必须调用
```

由此可以确定的事实（**来自真实代码，不是猜测**）：
- **action 名格式**：小写 + 下划线，例 `ride_pet_action_bar_button`
- **键名格式**：`"CTRL-b"`（修饰键大写前缀 + `-` + 键名）
- 该例中 `index` 用了 `1`，`arg` 用 `1` / `2` 区分不同宠物
- **写操作末尾必须调 `SaveHotKey()`**
- `API_TYPE.HOTKEY.id` = 19（见 `globals/apitypes.lua`，插件里对应 `native/rs_native_contract.lua:40`）

**注意**：`ride_pet_action_bar_button` 这个命名和 `GetOptionBindingButton(buttonName, index)` / `SetOptionBindingButtonWithIndex(buttonName, key)` 的 `buttonName` 高度吻合 —— 值得验证 **action 名与 UI 按钮名是否同一命名空间**。

---

## 4. 真正的难点：action 名称枚举

`GetOptionBinding` / `SetOptionBindingWithIndex` 都以 **action 名**为键，但 RU 客户端**没有 action 名称枚举接口** —— 没人告诉你全集是什么。

插件里已经有一个同名待办 feature `tools_hotkey_profiles`（`features/rs_feature_registry.lua` 第 346 行），状态 `runtime_blocked`，blocker 原文：

> 当前 RU API 没有动作名称枚举接口；GetOptionBinding 只能读取已知 action/index，无法安全构造完整快捷键方案

**这个 blocker 不解决，功能就做不成。** 以下是候选方向，**都没验证过，需要你去实测**：

1. **优先验证 `BindingToOption()` / `OptionToBinding()`**
   两者**都不接受参数**，且在参考实现里于 addon 加载阶段被调用一次。
   如果其中任何一个会返回或填充一张**全量绑定表**（返回值 / 全局表 / 副作用），问题直接解决。
   先打印返回值类型、长度和内容，再看全局变量副作用。

2. **用 `IsValidActionName(action)` 做候选校验**
   它可以验证任意字符串是不是合法 action，但仍需要一个**候选字典**来源。

3. **候选字典可能来源**（逐个实测，不要采信未交叉验证的清单）：
   - 客户端资源里的键位设置界面定义（打包在 `game_pak`，可能需要额外解包工具）
   - 社区 ArcheAge addon 项目 / 论坛整理的 action 清单（联网检索，**每一条都要用 `IsValidActionName` 验证过才能用**）
   - 客户端运行日志（玩家改键位时是否打印 action 名）
   - 已知 action 名做前缀 / 命名规律外推（如 `*_action_bar_button` 一族），再用 `IsValidActionName` 逐条校验

4. **降级方案（允许）**：只覆盖用户实际关心的 action 子集（技能栏 1–0、常用功能键）。
   但**必须在 UI 里如实标注覆盖范围**，不许包装成"完整方案"。

---

## 5. 实施顺序

### Step 1 — 实机探针（必须先做，不许跳过、不许只写分析）

在插件里加一个临时诊断入口，把 X2Hotkey 的每个 Allowed 函数逐个调用并打印：
- 返回值类型 / 数量 / 内容
- 是否产生全局副作用
- 是否有异常

重点先打这几个：
`BindingToOption()`、`OptionToBinding()`、`GetOptionBinding("ride_pet_action_bar_button", 1, 1, 1)`、`GetOptionBindingButton("ride_pet_action_bar_button", 1)`、`IsValidActionName("ride_pet_action_bar_button")`

**探针的原始输出必须随交付回复表格化给出**，不能只写"结果正常"这类结论。

探针是临时代码：验收完成后要么**物理删除**，要么按项目规范转成正式的诊断入口 —— 不许留下无主的临时代码。

### Step 2 — 定 action 名称来源

基于 Step 1 的实测结果选路线，并把**证据**写下来。若走到降级方案，明确写清覆盖率。

### Step 3 — 导出

- 遍历 action 集合 → 读取绑定 → 生成**带 schema 版本号**的纯文本
- 建议格式（可调整）：首行 `RS_HOTKEY_PROFILE v1`，之后每行一条 `action|index|arg|key`
- 文本展示通道**参考**（不是照抄）`core/rs_report_copy_transport.lua`：它是为超出输入框容量的长报告做的压缩编码器（LZB1 + Base64）。按键方案通常几十行文本，**直接放输入框即可，不要引入压缩**；真正值得复用是它"写入后必须回读校验"的思路。
- ⚠️ 如果方案还要落进插件存档（table 形式）：注意 RU 的 SaveData serializer 会**省略 `false` 与空表**（Transport v1），v2 才保护 `0` 与 `""`。字段被省略 → 读回 fallback 成默认值 → canonical 变化 → `integrity_failed:fingerprint_mismatch` → write fence。
  纯字符串导出不受影响；只有走存档才需要按这套规则设计字段。

### Step 4 — 导入

- 解析 + 版本校验 + 逐项 `SetOptionBindingWithIndex(...)`
- 收尾调用 `SaveHotKey()`
- **写完后必须回读验证**（用 `GetOptionBinding` 比对）
- 任何一项失败要能**整体回滚**到导入前状态，不许留"半套键位"

### Step 5 — UI 接入

- 在 V3 页面加"导出 / 导入"入口
- 战斗中**禁用全部写操作**并给出明确提示
- 覆盖范围如实展示

### Step 6 — 验收

见第 8 节。

---

## 6. 交付物

1. `features/tools/hotkey_profiles/rs_hotkey_profiles_authority.lua`、`_feature.lua`、`_acceptance.lua`
   —— 对齐 `features/tools/random_shop/` 的三文件范式
2. **把新增的 3 个 `.lua` 登记进 `toc.g`**
   —— 加载模型是「目录树 + `toc.g`」，没有 `require` / `dofile` / `loadfile`，文件靠顶层自注册。
   **磁盘上有、但 `toc.g` 里没有的 `.lua` 就是死文件，永远不会被加载。**
3. 更新 `features/rs_feature_registry.lua` 里 `tools_hotkey_profiles` 的 `status` / `runtimeBlocker` / `evidence`
4. 若引入新的 Native API 调用：在 `core/rs_api_capabilities.lua` 登记（含 `Risk` / `Restrictions` / `Since` / `Notes`）
5. V3 页面改动
6. **实测证据**（Step 1 探针原始输出、action 来源证据、导出/导入往返验证结果）
   —— 直接随交付回复**表格化**给出，**不要新建独立的状态文档 / 验收文档 / CHANGELOG**

---

## 7. 红线（必须遵守）

### 7.1 技术红线

- **不许猜 API 签名**。以 `z_api_functions/api_functions.lua` 为准；不在 Allowed 名单里的函数一律不许调用。
- **所有 Native 调用必须经过能力门** `S.Api:CallCapability(...)`，且该 API 必须先在 `core/rs_api_capabilities.lua` 登记，否则会被门阻断。
- **战斗中禁止任何写操作**（`SaveHotKey` / `SetOptionBindingWithIndex` / `RemoveOptionBinding` 都带 combat 限制）。
- **被替代的旧代码物理删除**，不要留 deprecated 壳子。
- **结论必须带本轮实测证据**（打印输出、回读值、日志行）。不许引用历史结论，不许凭印象推断。
- **不许新建平行工程 / 临时验证工程**，在真实插件里做。

### 7.2 本项目的工程约定（照做，别自创）

- **所有新增 / 修改的代码行必须带详细中文维护注释**：说明它为什么存在、属于哪个 Authority / 生命周期 / 安全边界、未来不能破坏什么。
  禁止"赋值""调用函数"这类零信息量注释。
- **分层依赖只能向下**：
  `Shell / Router / PageHost` → `Presentation / RSUI` → `Feature Projection + Commands` → `Feature Domain / Store` → `Services` → `Demand / Scheduler / Events / Persistence` → `Native`。
- **`Docs/README.md` 是本仓库唯一的文档**（背景 + 框架）。
  CHANGELOG / 状态 / 验收 / 矩阵 / `Architecture/*.md` / 归档**已于 2026-09-10 全部删除**，不要再引用、不要再新建。
  **修完不做文档收尾**：不更新版本号、不写状态文档。契约变化只改**代码内**的声明（如 `XxxContractVersion = N`）与断言。
- **不要规划"跑门禁 / 跑 harness / 跑 audit"**：`replicatedsuite/tools/` 整个目录已删除（2026-09-10）。本仓库没有自动回归网。
  **验证靠用户 RU 实机测试反馈。**
- 可选的几秒级轻量自检（**不要扩展成长流程**）：
  - `luac -p <改过的文件>` 查语法（排除 `toc.g`，它是 TOC 清单不是 Lua）
  - `toc.g` ↔ 磁盘 Lua 双向对账，差异应为 0
- **工程目标是 Lua 5.1**（本机可能是 5.4，注意 `unpack` 等语义差异）。
- 工程文件全部是 **CRLF**；跨平台比对文本前先归一 `\r\n → \n`。
- UI 坐标：**左上角原点，`+X → 右`、`+Y → 下`**。detached Popup 禁止自己拼绝对坐标；Suite-owned Popup 直接锚定 Trigger Native Widget。
- 代码注释与交付文档用**简体中文**。

---

## 8. 验收标准

1. 账号 A 导出 → 得到文本；把同一文本导回账号 A，键位不变（幂等）。
2. 换到账号 B 导入 → 回读一致，且游戏内实际按键行为正确。
3. 战斗中触发导入 → 被拒绝，且**不产生任何写入**。
4. 文本被破坏（截断 / 改字符）→ 导入整体失败并回滚，不留下半套键位。
5. 覆盖范围在 UI 里如实标注（若只覆盖子集，必须写清楚）。
