# 随包工具：执行方法与结论边界

四个工具仅用Python 3.10+标准库，无联网、依赖安装、游戏写入或自动执行Lua载荷。工作目录为本技能根目录；路径包含空格时加引号。所有命令应先`--help`，不要把示例路径原样当真实文件。

## 1. 技能结构检查

```text
python scripts/verify_skill.py .
python -m unittest discover -s tests -v
```

检查名称/修订、此包采用的简化YAML、Markdown本地链接、JSON、重复案例ID、必需脚本、新增评测题的未执行标志。它不是通用YAML验证器，不联系网络验证旧来源，不用关键词命中判断Agent正确率。

测试使用临时目录与合成报告，包含失败输入；游戏对象、PVP、Store逻辑没有被这组Python测试执行。涉及真实Lua5.1的两例需要环境变量`RS_TEST_LUA51`指向可信解释器；未提供显示skipped，不能算通过。Windows可在PowerShell中用 `$env:RS_TEST_LUA51 = "C:\tools\lua5.1.exe"`，POSIX用`export RS_TEST_LUA51=/path/to/lua5.1`。

## 2. 分页/HUD接收

```text
python scripts/verify_report.py pages.txt
python scripts/verify_report.py pages.txt --hud --output verified-layout.txt
```

仅支持当前已核对的`RS-ERROR-PAGE-1`及可选`HUD_TEMPLATE_V2`，其他协议明确拒绝，不猜解码。读取实际声明字节数，检查逐页、全传输、解转义原文；中文、反斜杠与嵌入尾标不会被误拆。顺序可调整，完全相同重复页统计去重；缺页、混ID、冲突、错误偏移与校验拒绝。

当前wire内源换行已编码为`\n/\r`，接收器可去掉复制新增的真实CR/LF；空格和tab在DATA中保持原样，不做“修复丢字”。这是协议特例，不应用于任意文本。资源预算是接收器保护，不是推断RU编辑框的真实上限。

默认stdout只输出校验元信息，不输出报告正文。`--hud`会额外输出布局字段；`--output`仅创建新文件，已存在则拒绝。报告可能含隐私，保持本地、按最小范围分享；工具不执行报告中的代码、不恢复存档、不修改默认值。解析数值不代替当前Store的上下限和语义验证。

## 3. 真Lua5.1语法门禁

```text
python scripts/check_lua51.py --lua /path/to/lua5.1 /path/to/changed.lua
python scripts/check_lua51.py --lua /path/to/lua5.1 /path/to/replicatedsuite
```

使用可信解释器实际打印`_VERSION`，必须精确为`Lua 5.1`，检测到`jit`变体时阻断而不是冒充标准解释器。记录解释器/源文件摘要；清理LUA_*启动环境；拒绝字节码；编译哈希对应的临时文本副本，调用loadfile但**不调用编译结果**。目录参数递归仅收`.lua`，符号链接拒绝。

退出码0=语法通过，1=语法失败，2=blocked/未完成；空文件集合不是通过。缺解释器、错误版本、超时或读取失败均不降级为5.4成功。无自动下载/安装；可继续其他定位，但不能报告Lua5.1已通过。

语法器抓不住`table.unpack`在5.1标准库不存在、事件参数错位、Native返回单位等运行契约；LuaJIT/定制VM也须单独标注。版本字符串检查不是恶意解释器认证，二进制来源由调用者负责。依据：[Lua5.1手册](https://www.lua.org/manual/5.1/manual.html)。

## 4. 最终增量ZIP核对

```text
python scripts/audit_patch.py --base /path/to/baseline --current /path/to/current --zip /path/to/patch.zip
```

base/current是**同一项目相对层级**的两个既有目录，ZIP也必须包含同层级路径；例如两者都含`replicatedsuite/`，不要一边选Addon根、一边选插件根。只有确有删除且获准时重复添加 `--allow-deletion relative/path`，批准列表必须等于实际删除集合。

拒绝多打未修改文件、少打变化文件、错误载荷、重复/大小写冲突、穿越/Windows危险路径、符号链接、文件目录碰撞、加密、超预算、常见私密文件与缓存。对最终ZIP内容核对摘要并验证覆盖后的文件映射一致，输出新增/修改/删除及未改数量。

不解压、不删除、不运行测试、不校验任意内容是否含密钥；文件名筛查后仍需人工内容审阅。不会修TOC，TOC加载顺序/重复依赖应使用已存在的项目检查。还需在干净目录实际应用最终ZIP再跑相关回归，映射相同不等于已经执行。

## 技能包更新与游戏补丁不同

用户本轮更新的是技能，完整包放回原来的技能目录，不覆盖Addon；可选增量仅覆盖同修订基线的技能。元信息与安装方式遵守[Agent Skills格式](https://agentskills.io/specification)，具体发现/启用由宿主决定，不承诺复制文件就跨所有工具热重载。
