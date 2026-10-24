-- 中文维护：用药限制只增加不可用条件，绝不按倒计时宣告Ready；实际库存、血量、零CD仍是必要条件。
local P = LCotPotionSignal -- 中文维护：限制归属独立插件及当前Lua会话，不持久化到角色存档。
P.usage = {} -- 中文维护：与配置行分离，导入同一映射、暂停或收起都不能清掉正在生效的用药限制。
function P:Usage(index) -- 中文维护：固定物品与技能共同标识运行时限制，换技能时不能错误继承旧身份。
    local row, use = self.rows[index], self.usage[index] -- 中文维护：只接受当前已确认映射，不从名称推断。
    if not row or not row.verified or not row.skillId then return nil end -- 中文维护：未确认项不获得可推算的运行时状态。
    if not use or use.itemId ~= row.itemId or use.skillId ~= row.skillId then use = { itemId = row.itemId, skillId = row.skillId, blockedUntil = 0 }; self.usage[index] = use end -- 中文维护：新身份从实际CD读取开始，不继承另一药的Ready。
    return use -- 中文维护：此表只拥有额外限制，不拥有Native剩余时间。
end -- 中文维护：运行时限制不会进入分享预设。
function P:RestoreUsage() -- 中文维护：热重载沿用同会话单调时钟和已发生用药的限制，冷启动没有旧会话数据。
    local previous = self.previousUsage; self.previousUsage = nil -- 中文维护：读取一次后解除旧实例引用，不能继续执行旧代次回调。
    if type(previous) ~= "table" or not self.Number(previous.now) or previous.now < 0 or type(previous.usage) ~= "table" then return end -- 中文维护：未知旧状态不生成Ready或伪造剩余秒数。
    self.now = previous.now -- 中文维护：与旧限制期限同一单调时间域；不调用未验证游戏时钟接口。
    for i = 1, 3 do -- 中文维护：只传递当前相同固定映射的三个有限标量状态。
        local old, row = previous.usage[i], self.rows[i] -- 中文维护：持久化恢复与内置映射完成后再核对身份。
        if type(old) == "table" and row.verified and old.itemId == row.itemId and old.skillId == row.skillId and self.Number(old.blockedUntil) then -- 中文维护：不同技能不能借旧证据，NaN等时钟值拒绝传递。
            self.usage[i] = { itemId = row.itemId, skillId = row.skillId, blockedUntil = old.blockedUntil, lastUseAt = self.Number(old.lastUseAt), pendingUntil = self.Number(old.pendingUntil), cause = old.cause == "shared" and "shared" or "own", pairUncertain = i ~= 1 and old.pairUncertain == true } -- 中文维护：仅传递相同映射的保守限制/共享未归因否决，不携带库存、CD读数、控件、Ready或未确认数量候选。
        end -- 中文维护：丢弃不匹配旧状态不影响真实CD检查。
    end -- 中文维护：限制不因重载归零。
    self.inventoryPairLock = self.usage[2] and self.usage[3] and self.usage[2].pairUncertain == true and self.usage[3].pairUncertain == true or false -- 中文维护：已见正CD的共享未归因状态属于会话限制，重载后必须重新取得两方真实零才能解除。
end -- 中文维护：游戏完全重启后仍从Native冷却重新取得状态。
function P:LockInventoryPair(pendingUntil) -- 中文维护：共享药数量变化加正CD也可能是换堆叠碰上另一药用药，无法确认方向；只保留不可用否决，不猜自有90秒或反向60秒。
    local two, three = self:Usage(2), self:Usage(3); if not two or not three then return end -- 中文维护：负面事实也必须绑定当前两个已验证映射。
    if not self.inventoryPairLock then self.inventoryPairEventUntil = self.Number(pendingUntil) end -- 中文维护：仅本次新候选可等待同500ms窗口的明确本人事件；旧否决不能被新拖动续期或冒充为新用药，关联资格不跨重载传递。
    two.pairUncertain, three.pairUncertain, self.inventoryPairLock = true, true, true -- 中文维护：有限标量放入Usage沿会话继承，同映射导入不能消除已经观察到的未归因冷却。
    self.rows[2].inventoryUncertain, self.rows[3].inventoryUncertain = true, true -- 中文维护：本轮立即撤销两药Ready，独立图1不受该长期否决影响。
end -- 中文维护：锁只否决两关联药，不延长全局500ms等待。
function P:SyncInventoryPair() -- 中文维护：配置行重建后，从相同身份的Usage恢复否决；不借旧行的CD/库存授予Ready。
    local two, three = self:Usage(2), self:Usage(3) -- 中文维护：Usage会剔除身份不符的旧限制，不能把别的技能归因带进当前映射。
    local locked = two and three and two.pairUncertain == true and three.pairUncertain == true or false -- 中文维护：双方匹配才构成当前一对的未归因事实。
    self.inventoryPairLock = locked; self.rows[2].inventoryUncertain, self.rows[3].inventoryUncertain = locked, locked -- 中文维护：旧行被替换也立即得到同一保守否决，普通数量候选仍不继承。
    if not locked then self.inventoryPairRetryAt, self.inventoryPairEventUntil = nil, nil end -- 中文维护：身份改变或两方已经解除后不保留旧共同调度期限和迟到事件关联资格。
end -- 中文维护：只有锁生效时调用，正常16ms路径不额外校验两份Usage。
function P:UnlockInventoryPair() -- 中文维护：调用方必须已取得同轮真实双零，或同映射新候选窗口内的明确本人用药事件；普通超时不能调用。
    self.usage[2].pairUncertain, self.usage[3].pairUncertain = nil, nil -- 中文维护：清除已被当前证据解释的会话否决，未来热重载不再恢复它。
    local two, three = self.rows[2], self.rows[3] -- 中文维护：身份已由调用方核对，旧库存及CD读数不因解除否决取得Ready权限。
    two.inventoryUncertain, three.inventoryUncertain, self.inventoryPairLock, self.inventoryPairRetryAt, self.inventoryPairEventUntil = nil, nil, false, nil, nil -- 中文维护：双方和短期事件关联资格一并解除，不能只放开一边。
    two.wakeAt, three.wakeAt, two.sleeping, three.sleeping = nil, nil, false, false -- 中文维护：双零后立即恢复16ms观察；本人事件则在RecordUse继续建立准确限制，不能残留旧250ms睡眠持有过期颜色。
end -- 中文维护：只撤销此共享歧义，不清已确认用药期限、库存或健康事实。
function P:ResolveInventoryPair() -- 中文维护：解除必须取自同轮两次实际零CD；缺货、未知、旧缓存或500ms结束都不等价于共享限制已结束。
    local two, three = self.rows[2], self.rows[3] -- 中文维护：行身份已由本轮Sync核对，CD读数仍由正式采样赋值。
    if two.at ~= self.now or three.at ~= self.now then return end -- 中文维护：单边唤醒或旧零值不能解锁，两方共同调度将在下一到期周期完整核对。
    if two.remaining == 0 and three.remaining == 0 then -- 中文维护：真实双零只解除这一额外否决，库存、血量与已确认用药限制仍由原决策逐项验证。
        self:UnlockInventoryPair() -- 中文维护：真实双零仅解除该额外否决，不能用候选计时到期替代。
    else self.inventoryPairRetryAt = self.now + 250 end -- 中文维护：未解除时两方共用250ms到期点，避免各自错开采样后永远拿不到同轮双零。
end -- 中文维护：Native读数未知也会保留锁，独立药继续原16ms响应。
function P:ObserveStockChange(index) -- 中文维护：数量下降也可能是同ID换堆叠/拆分，只能发起短暂核对，不能直接生成21/90/30秒用药限制。
    local row, use = self.rows[index], self:Usage(index) -- 中文维护：候选绑定当前固定药及已验证技能，不读取背包界面代理的可见性猜操作来源。
    if not use or row.remaining ~= 0 or not row.at or self.now < row.at or self.now - row.at > 150 or use.blockedUntil > self.now then return end -- 中文维护：起点必须是当前映射150ms内的真实零CD；过期零值或已有冷却都不能为数量变化提供新用药因果。
    if not row.inventoryPendingUntil then row.inventoryPendingUntil = self.now + 500 end -- 中文维护：从首次下降起算，不因连续拖动/背包通知续期；未确认候选不进入已确认Usage。
    self:HideSignal(); self.nextSampleAt = nil -- 中文维护：不明数量变化先同步撤色，随后最多500ms核对真实CD，不能带着旧Ready继续发色。
end -- 中文维护：实际本人施法事件仍直接进入RecordUse，不等待此库存候选。
function P:CheckStockChange(index, probe) -- 中文维护：在本轮正式行更新之前确认候选，以复用原来的用药/共享限制及校准刷新顺序。
    local row, use = self.rows[index], self:Usage(index) -- 中文维护：预设替换会丢弃旧行候选，当前Usage身份必须仍匹配。
    if not row.inventoryPendingUntil then return end -- 中文维护：正常16ms采样不增加任何Native读取。
    if not use or use.blockedUntil > self.now or self.now > row.inventoryPendingUntil then row.inventoryPendingUntil = nil; return end -- 中文维护：已被本人事件/共享限制覆盖或超过观察窗口的候选不再归因，避免暂停很久后把新CD绑给旧拖动。
    local ok, first, second = self:Read("X2Skill", "GetCooldown", row.skillId, true) -- 中文维护：只读取已验证技能，零→正证据仍使用既有允许API和参数，不依赖背包开关接口。
    probe.cooldownSampled, probe.cooldownSkillId, probe.cooldownRemaining, probe.cooldownDuration = true, row.skillId, nil, nil -- 中文维护：本轮标量结果交给后续行刷新复用，不重复查CD，失败也不能回退旧成功。
    if ok then probe.cooldownRemaining, probe.cooldownDuration = self.Cooldown(first, second) end -- 中文维护：合法正CD才是确认依据，nil/异常保持Unknown。
    if probe.cooldownRemaining and probe.cooldownRemaining > 0 then -- 中文维护：正CD确认了不可用，但共享药不一定是本药被使用，不能把另一药迟到的库存反馈当作不存在。
        if index == 1 then self:RecordUse(index) -- 中文维护：图1没有图2/3的共享因果，真实零→正可确认其独立用药并使用21秒限制休眠。
        else self:LockInventoryPair(row.inventoryPendingUntil); self.rows[2].inventoryPendingUntil, self.rows[3].inventoryPendingUntil = nil, nil end -- 中文维护：仅本人明确施法事件可为共享药确定方向；保留新候选的原窗口用于关联该事件，同时结束全局等待让独立图1响应。
    elseif self.now >= row.inventoryPendingUntil then row.inventoryPendingUntil = nil end -- 中文维护：窗口到期仅撤销未证实的归因，随后仍须真实库存、真实零CD和当前血量才允许Ready。
end -- 中文维护：同ID堆叠互换且CD持续为零不会创建整段用药限制。
function P:ClearStockChanges() -- 中文维护：进入显式校准或切世界时旧数量变化失去因果资格，已确认Usage限制由独立表继续保留。
    for _, row in ipairs(self.rows) do row.inventoryPendingUntil = nil end -- 中文维护：只清未确认候选，不撤销本人成功事件或已证实的共享冷却。
    self.inventoryPairEventUntil = nil -- 中文维护：跨校准/世界后迟到事件不能解释旧候选；已有共享否决仍保留，等待新真实双零。
end -- 中文维护：预设替换/热重载直接创建新行，不复制这些临时字段。
function P:RecordUse(index) -- 中文维护：本人施法成功或独立图1库存加真实正CD确认触发，第一步必须同步撤色；共享药库存不能单独决定用药方向。
    local use = self:Usage(index); if not use then return end -- 中文维护：未确认技能不能应用药品规则。
    self:HideSignal() -- 中文维护：不用等下一次50ms采样或250ms文字刷新。
    self.rows[index].inventoryPendingUntil = nil -- 中文维护：真实用药证据取代库存候选；即使事件与CD确认落在去重窗口，也不能遗留不明等待。
    self.nextSampleAt = nil -- 中文维护：真实用药可能改变最早唤醒的药品，旧的合并休眠期限必须重新计算；不能休眠到另一个药的旧期限。
    if index ~= 1 and self.inventoryPairEventUntil and self.now <= self.inventoryPairEventUntil then self:SyncInventoryPair(); if self.inventoryPairLock then self:UnlockInventoryPair() end end -- 中文维护：共享药RecordUse只来自明确本人事件；仅同身份、本次新候选原500ms内可解释其歧义并恢复精准长休眠，不能抹掉更早或过期的未归因事实。
    if use.lastUseAt and self.now - use.lastUseAt >= 0 and self.now - use.lastUseAt <= 500 then return end -- 中文维护：同次用药的事件和库存反馈合并，不延长两份倒计时。
    self.rows[index].stock, self.rows[index].remaining, self.rows[index].duration, self.rows[index].at, self.rows[index].cooldownRetryAt = nil, nil, nil, nil, nil -- 中文维护：确认消耗后旧库存基线与CD观察立即失效；休眠后不能把同一瓶的数量下降再当一次新用药，唤醒必须重新建立基线。
    self.usageRevision = (self.usageRevision or 0) + 1 -- 中文维护：只有真实新用药改变限制版本；采样中检测到数量下降时才重算三药休眠，常态不重复遍历Usage。
    use.lastUseAt, use.pendingUntil = self.now, self.now + 500 -- 中文维护：只短暂等待反馈；本药独立限制仍覆盖整个标称CD，不永久阻塞独立图1。
    use.blockedUntil, use.cause = math.max(use.blockedUntil or 0, self.now + self.Specs[index].cooldown * 1000), "own" -- 中文维护：21/90/30秒来自用户确认，仅作为附加不可用下限，不转换Native未知单位。
    self.rows[index].awaitCooldown = true -- 中文维护：零CD迟到时不能立即重复吃同一瓶。
    if index ~= 1 then -- 中文维护：只有图2与图3共享冷却，独立图1不受关联限制。
        local otherRow = self.rows[index == 2 and 3 or 2]; otherRow.inventoryPendingUntil = nil -- 中文维护：本药已确认用药时，对方的零→正可由共享CD造成，必须取消对方未确认的数量归因，不能反向再加一整段CD。
        local other = self:Usage(index == 2 and 3 or 2) -- 中文维护：关联目标也必须是已确认的固定映射。
        local seconds = index == 2 and 60 or 30 -- 中文维护：使用图2限制图3六十秒；使用图3限制图2三十秒，方向不能反转。
        if other and self.now + seconds * 1000 > (other.blockedUntil or 0) then other.blockedUntil, other.cause = self.now + seconds * 1000, "shared" end -- 中文维护：共享限制只延后，不缩短目标已有更长的独立CD。
    end -- 中文维护：规则限制不是已经观察到Native关联CD的证明。
    self.reason = "检测到用药或数量变化：已撤色，核对当前血量与CD" -- 中文维护：事件处理只撤色并记录限制，不直接选择下一药。
end -- 中文维护：无吃药API、模拟输入或后台按键队列。
function P:UsagePending() -- 中文维护：正CD反馈可以提前结束短暂全局等待，独立和共享限制始终另外保留。
    local pending = false -- 中文维护：跨三行合并后只做一次信号决策。
    for i, row in ipairs(self.rows) do -- 中文维护：三种药固定有界，不扫描技能列表。
        local use = self:Usage(i) -- 中文维护：配置身份变化后自动取得匹配的限制表。
        row.blockedUntil = use and use.blockedUntil or nil -- 中文维护：纯决策层消费当前限制，不引用旧配置行。
        if row.inventoryPendingUntil and self.now < row.inventoryPendingUntil then pending = true end -- 中文维护：只为尚待核对的数量变化短暂撤色，不能把它升级成整段冷却或共享限制。
        if row.awaitCooldown and use then -- 中文维护：短暂等待属于实际用药，不把所有正CD当作事件。
            if (row.remaining and row.remaining > 0) or not use.pendingUntil or self.now >= use.pendingUntil then row.awaitCooldown = false else pending = true end -- 中文维护：五百毫秒后允许独立药重新决策；原药仍受完整限制与实际CD双重检查。
        end -- 中文维护：读取失败仍由决策层Unknown撤色，期限结束不意味着Ready。
    end -- 中文维护：不改变Native剩余CD读数。
    return pending -- 中文维护：只有已知用药的短暂反馈窗口会全局撤色。
end -- 中文维护：本地时钟只控制保守限制，不能覆盖真实正CD。
