# Replicated Suite — AI 上岗指南

> **给任何接手本仓库的 AI / Agent。读完这一份就能开工。**
> 详细的项目背景与框架在 **[`replicatedsuite/Docs/README.md`](replicatedsuite/Docs/README.md)**（本仓库**唯一**的文档）。

---

## 一、这是什么

**ArcheRage RU**（`ru.archerage.to`，ArcheAge 俄语客户端私服）的综合辅助 Addon。

| 项 | 值 |
|---|---|
| 运行时 Addon | **只有 `replicatedsuite/`**（`toc.g` 只加载这里） |
| 客户端 addon 目录 | `C:\ArcheRage\Documents\Addon` |
| 加载模型 | **目录树 + `toc.g`**；**没有** `require` / `dofile` / `loadfile`，文件在顶层自行注册 |
| 目标语言 | **Lua 5.1** |
| `z_api_functions/` | 开发期 API 参考，**不进 `toc.g`、不进运行时** |
| `参考的项目/` | 外部参考 addon（只提供产品行为证据，**永不复制进本工程**），已从 git 脱离跟踪 |

---

## 二、工作流程（固定四步）

用户明确要求，**照做即可**：

1. **读 `replicatedsuite/Docs/README.md` 的背景信息**
2. **定位问题**（读真实代码与日志）
3. **修复问题**（改代码 + 写详细中文维护注释）
4. **交用户实测并反馈**

---

## 三、铁律

- **真实代码是唯一 Authority。** 禁止凭印象、凭文件名、凭历史聊天下结论。
- **修完 bug 不做文档收尾。** 不要更新 CHANGELOG / 状态文档 / 验收文档 / BuildTag / 版本号——用户明确说过那是负担，会拖慢修 bug 的速度。
- **不要跑长耗时的本地门禁。** `replicatedsuite/tools/` 已于 2026-09-10 被用户**整个删除**（59 个 .py / 904KB，不参与运行时）。**不要再规划"跑 audit / 跑 harness"这类步骤**——它们已经不存在。验证靠**用户实机测试反馈**。
- **不要创建新文档。** 需要知识就写进 `Docs/README.md` 或写进代码注释；不要新建第二份文档。
- **所有新增/修改代码行必须带详细中文维护注释**：说明为什么存在、属于哪个 Authority / 生命周期 / 安全边界、未来不能破坏什么。禁止"赋值""调用函数"这类无信息量注释。
- **修一个 bug 就扫全项目同源模式**，一次修完，不要只修报出来的那一处。
- **分层问题修底层**，不修业务特例。

---

## 四、可用的轻量自检（几秒级，可选）

```bash
cd replicatedsuite

# 语法（排除 toc.g —— 它是 TOC 清单不是 Lua）
luac -p <改过的文件>

# TOC ↔ 磁盘 Lua 双向对账（0 差异才算通过）
python - <<'PY'
import os
toc=[l.strip() for l in open('toc.g',encoding='utf-8') if l.strip() and not l.strip().startswith('#')]
allf={os.path.relpath(os.path.join(r,f),'.').replace('\\','/')
      for r,d,fs in os.walk('.') if '.git' not in r and '.workbuddy' not in r
      for f in fs if f.endswith('.lua')}
print("TOC",len(toc),"MISSING",[t for t in toc if t not in allf],"NOT IN TOC",len(allf-set(toc)))
PY
```

**不要**把这两步扩展成长流程。

---

## 五、环境与已知坑

- **CRLF**：工程全部 CRLF；跨平台比对文本前先归一 `\r\n → \n`。
- **Lua 版本**：目标是 5.1；本机若只有 `lua` 5.4，跑依赖 5.1 语义的脚本时需自备 `unpack = table.unpack` 垫片。
- **Git Bash 无 `zip`**：打包用 Python `zipfile`。
- **Windows 回收站**：PowerShell 的 `Add-Type` 会被安全策略拦截，改用 Python `ctypes` 调 `shell32.SHFileOperationW`（`FOF_ALLOWUNDO`）。注意**返回值不可信**（`rc=2` 时文件可能已成功进回收站），判定要看「原路径是否消失」+ 回收站 `$R`/`$I` 是否成对。删目录报 `rc=120` 时**单独重试**即可成功。
- **多 Agent 工作区**：`git status` 的 modified 数会随后台会话变化。开工前与收尾时各跑一次；用 `stat -c '%y'` 看 mtime，**同一秒成批出现 = 批量写入**（可能带旧时间戳覆盖你的改动，历史上发生过）。

---

## 六、这个项目最容易踩的领域坑（详见 `Docs/README.md` §五）

### RU SaveData serializer 会"吃掉"假值 —— 本项目最高频的故障源

`SaveData → LoadData` 往返时，RU 原生 serializer 会**省略**某些合法值：

| 值 | Transport v1 | Transport v2 |
|---|---|---|
| `boolean false` | 哨兵保护 | 保护 |
| 空 table | 哨兵保护 | 保护 |
| **数值 `0`** | ❌ **被省略** | ✅ 保护 |
| **空字符串 `""`** | ❌ **被省略** | ✅ 保护 |

后果链：字段消失 → 读回被 fallback 成**默认值** → canonical 变化 → `integrity_failed:fingerprint_mismatch` → Store 进 write fence。

**判断要点**：

- 只有"**fallback 与真实值不同**"的字段才会造成 mismatch（`minDamage = 0` 的 fallback 也是 0 → 安全；`overallOpacity` 的 fallback 是 0.94 → 用户设 0 就中招）
- **放大机制**：`FloatingSurface:NormalizeState` 的 `free` 分支要求 `tonumber(value.x) ~= nil and tonumber(value.y) ~= nil`。窗口贴左/上边缘时 `x`/`y` 合法为 `0`，被省略后 `free` 判定失败，`x/y/coordinateSpace/savedLogicalWidth/Height/normalizedCenterX/Y` **整组字段一起塌陷**
- **恢复原则**：能结构化证明的（补回被省略的 0 / 收集被表形漂移藏起来的行）就用**结构化 exact recovery**；物理已丢失无法反推的才用 known-pair 白名单。**候选没有信任权，必须逐字命中旧 `encodedFingerprint`**，未知 mismatch 一律 fail-closed
- 恢复成功的 Store 应立即重写为当前 Transport 版本；**健康**的旧版本 Store 走惰性升级，避免一次更新触发几十个 Store 的 fan-out

### 其它

- **RU 表形漂移**：往返可能让 sequence 变成稀疏/map，`ipairs()` 会少读仍存在的行
- **UI 坐标**：ArcheAge/CryEngine 原点在**左上角**，`+X→右 / +Y→下`。detached Popup 禁止自己拼绝对坐标；Suite-owned Popup 必须直接锚定 Trigger Native Widget；`Addon Scale` 只影响控件尺寸，**禁止乘到世界投影位置**
- **输入焦点**：`ClearFocus` 只有"global focused id → 已登记 Suite input → 属于正在停用子树"三条同时成立才允许执行，否则会误清游戏聊天输入。RU **未验证** generic `OnKeyDown/OnKeyUp/OnTextChanged`，禁止绑定
- **技能代理归属**：缺可靠 proxy→caster owner link 时，必须显式保留为"未归属技能代理"，**禁止猜主人**
- **Native 边界**：Active V3 代码不得依赖 `globals/`、不得直读 `API_TYPE` / `CreateWindow` 等；新裸 Widget 必须经 `NativeObjectFactory`；未验证的 RU 参数/返回/权限一律 fail-closed

---

## 七、目录速览

```text
Addon/
├── SKILL.md                  ← 本文件（AI 上岗指南）
├── replicatedsuite/          ← 唯一运行时 Addon
│   ├── Docs/README.md        ← 唯一文档（背景 + 框架）
│   ├── replicatedsuite.lua   ← 入口（含 S.BuildTag）
│   ├── toc.g                 ← 加载清单
│   ├── core/ native/ services/ features/ presentation/ ui/ data/ config/
├── z_api_functions/          ← 开发期 API 参考（不进运行时）
└── 参考的项目/                ← 外部参考（已脱离 git）
```

> **`replicatedsuite/tools/` 已不存在**（2026-09-10 删除）。不要再引用它。
