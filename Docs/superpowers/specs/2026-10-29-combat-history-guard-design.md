# 角色战绩基础保护与双电脑合并

用户已确认：重点查看服务器今日击杀/死亡，保留角色累计、每日历史；离线双电脑按角色合并去重；拦截简单修改总数、增量、导出数字；保留旧历史，验证后提交推送。

- 沿用 PersonalHistory 单一 Character Store（新写schema6，旧schema原章校验后迁移）、来源累计快照与耐久合并。旧 schema 和来源的 canonical 不变，不清档、不重盖旧章。
- 保护启用后切换到新的 p- 本地来源；已有来源冻结并标为旧记录。旧历史仍参与今日/累计展示，保护状态必须区分旧记录。
- p- 来源维护独立的 kills/deaths 凭据计数，单次只能 0/1；按天凭据和来源头使用嵌入式密钥 HMAC-SHA256。密钥随客户端发行，仅用于提高基础篡改门槛，不是游戏服务器认证或防破解。
- 冷路径保存/导出前校验独立计数、每日/归档/合计守恒与认证。未被业务路径标为待签名的来源只能验签，不能因 getter 自动重签伪造数据。读档、导入需验证 p- 来源；移除凭据不得把 p- 来源降级成旧记录。
- 导出增加 RS-HISTORY-4：沿用现有 RSCH1 分段和 TXT 信箱，受保护来源带 P/Q 凭据行，旧版本 1/2/3 继续读取。旧来源身份与基线 hash 不变，回传/重复/乱序不相加，更新单来源只接纳较新累计；本地来源分叉拒绝覆盖。无法判断部分重叠的旧历史仍要求确认，不能自动猜重合量。
- 今日采用已有服务器日期，显式点击通过GetPersonalHistoryToday冷查询；普通投影只读缓存；日期不可用时保留 unknown，不能借电脑日期清账。页面增加今日快捷筛选与保护/旧历史说明；保留全部日期、原筛选、累计和现有导入导出操作。
- 不新增轮询，不在战斗事件遍历全期日账，不存无限逐事件日志；热路径只更新当前来源/当日的固定计数，认证放在冷路径并缓存不变凭据。
- 防护边界：可拦直接改总数/增量/文件；主动改凭据与认证代码、伪造整套事件、关闭插件或回滚整个合法旧存档仍非离线客户端可彻底阻止。

## 保护模块接口（实施合同）
Crypto: S.CombatHistoryAuth.Sha256(text), HmacSha256(key,text)，返回小写64位HEX；纯Lua5.1，无依赖/Native调用。
Guard: H.Guard 或 S.CombatHistoryGuard（同一对象），source.guard={v=1,k='0',d='0',ak='0',ad='0',tag=HEX,days={date={k='0',d='0',tag=HEX}}}。
方法冒号调用：NewSource(id,source,identity)->bool,err（仅零击杀死亡源）；Advance(id,source,delta,date,identity)->bool,err（在普通source累加前更新独立计数，记录内存pending）；ArchiveDay(id,source,date,identity)->bool,err（在普通source归档前）；SealSource(id,source,identity)->bool,err（仅pending可签新tag，否则验签）；VerifySource(id,source,identity)->bool,err（绝不重签）；CopyGuard(guard)->table。id以p-开头必须有有效guard，其他id的无guard来源视为旧记录。
容量为旧来源16个加保护来源16个，总上限32，新增来源前检查容量，不丢弃旧来源腾位置。
来源头tag绑定版本、identity、id、serial、k/d/ak/ad、guard天数及按日期排序的day tags Merkle根；日tag绑定版本、identity、id、date、k/d；使用无歧义长度前缀编码。Seal/Verify检查实际source totals/archive/days与凭据一致且守恒；旧来源guard存在但不是p-也拒绝。pending以source对象身份保存在模块私有弱表，不能信任文件提供的dirty标志。
