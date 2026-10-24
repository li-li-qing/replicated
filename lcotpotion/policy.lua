-- 中文维护：独立插件的纯决策层只消费本轮 Native 读数；不访问游戏、不发送按键，也不按倒计时推算就绪。
local P = LCotPotionSignal -- 中文维护：所有文件归属本插件代次，不能写 Replicated Suite 或公共 globals。
P.Specs = { -- 中文维护：阈值及交叉 CD 来自用户；标称秒数用于附加不可用限制，不能覆盖游戏实际正CD或未知读数。
    { name = "图1 · 速效治疗药水", threshold = 88, cooldown = 21, rgb = { 0, 1, 0 } }, -- 中文维护：保留 88% 触发，另有 10 秒持续回血；此处不把未知 Buff 当作零。
    { name = "图2 · 强效治疗药水", threshold = 62, cooldown = 90, rgb = { 1, 1, 0 } }, -- 中文维护：备用药；只能在图3确定冷却或缺货时入选。
    { name = "图3 · 远征队员的勇气", threshold = 62, cooldown = 30, rgb = { 0, 0.4, 1 } }, -- 中文维护：图2使用后应观察到60秒，图3使用后图2应观察到30秒；不推算 Ready。
} -- 中文维护：图1、图3优先，单色协议每轮最多选出一种药，避免 LCot 同时发送三种按键。
function P.Number(value) -- 中文维护：Native nil、布尔、NaN、无穷都属于未知，尤其不能通过 tonumber(nil) or 0 伪造就绪。
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then return nil end -- 中文维护：只接收实际数值 ABI。
    return value -- 中文维护：合法零值保留给明确的冷却结束分支。
end -- 中文维护：数值边界由纯层统一拥有。
function P.ThresholdNumber(value) -- 中文维护：用户阈值是0到100的整数百分比；字符串存档与编辑草稿共用完整校验，零明确禁用该药。
    if type(value) == "string" then if not value:match("^%d+$") then return nil end; value = tonumber(value) end -- 中文维护：拒绝带单位、空串、小数和任意表达式，不把无效输入变成默认值。
    value = P.Number(value); if value and value >= 0 and value <= 100 and value == math.floor(value) then return value end -- 中文维护：全部三项通过后才能整组提交，范围外不能静默截断。
end -- 中文维护：纯校验不读取Native，也不改变运行状态。
function P:Threshold(index) -- 中文维护：运行规则和界面都读取这份已提交配置；编辑中的原生文字没有决策权。
    local value = self.thresholds and self.ThresholdNumber(self.thresholds[index]) -- 中文维护：零值保留，缺失的旧存档才回退发行默认。
    return value ~= nil and value or self.Specs[index].threshold -- 中文维护：默认88/62/62只定义一次，不再在决策分支硬编码。
end -- 中文维护：图3优先与关联限制独立于阈值配置。
function P:ApplyThresholds(values, persist) -- 中文维护：三项完整校验后一次提交；编辑配置暂停信号，不能在打字过程中误发药键。
    if type(values) ~= "table" then return false, "阈值必须包含三种药的整数百分比" end -- 中文维护：未知Native存档形状不清空原配置。
    local nextValues = {} -- 中文维护：失败前不改任何已提交项，防止前两项成功第三项失败。
    for i = 1, 3 do local value = self.ThresholdNumber(values[i] or values[tostring(i)]); if value == nil then return false, "图" .. i .. "阈值请输入0到100的整数" end; nextValues[i] = value end -- 中文维护：兼容RU顺序表或字符串键表，不能靠ipairs漏掉缺项。
    local previous = self.thresholds
    self:Disable("血量阈值已调整，请重新启用用药信号"); self.thresholds = nextValues -- 中文维护：先撤色；写入/回读通过前只是候选配置，失败恢复原阈值。
    if persist then
        local saved = self:SaveBindings()
        local ok, readback = false, nil
        if saved and ADDON and type(ADDON.LoadData) == "function" then ok, readback = pcall(ADDON.LoadData, ADDON, "lcot_potion_signal_bindings_v1") end -- 中文维护：仅读回本插件原私有键，不新增存档或触碰其它插件。
        local values = ok and type(readback) == "table" and readback.thresholds
        local verified = type(values) == "table"
        if verified then for i = 1, 3 do if self.ThresholdNumber(values[i] or values[tostring(i)]) ~= nextValues[i] then verified = false; break end end end
        if not saved or not verified then
            self.thresholds = previous
            self.saveError = "血量阈值保存未通过回读校验，本次仍使用原阈值；保存状态未确认，请保留编辑窗口并重试。"
            return false, self.saveError
        end
        self.saveError = nil
    end
    return true -- 中文维护：提交不推算任何CD，不改变固定药品身份和共用冷却。
end -- 中文维护：分享映射LCP2保持兼容，本机阈值独立保存。
function P.HealthNumber(value) -- 中文维护：仅血量接受项目现有Healer契约支持的数字文本，不能把这项兼容扩散到尚未验证的CD返回ABI。
    if type(value) == "string" then if not value:match("^%d+%.?%d*$") then return nil end; value = tonumber(value) end -- 中文维护：只接受完整非负十进制文本，空串、单位、表、布尔和未知字段不变成血量零。
    return P.Number(value) -- 中文维护：数值仍经过NaN、无穷和类型边界，死亡与上限关系由Decide验证。
end -- 中文维护：不能以解析失败回退为100%或允许发色。
function P.HealthRaw(value, accepted) -- 中文维护：只有读取异常时把受限的原始类型和值投影到诊断，帮助实机确认返回契约。
    if not accepted then return "读取失败" end -- 中文维护：调用错误不能作为血量数字展示。
    local kind = type(value) -- 中文维护：未知表形状明确显示类型，不猜字段拼假血量。
    if kind == "number" or kind == "boolean" then return kind .. ":" .. tostring(value) end -- 中文维护：有限标量说明不调用额外Native方法。
    if kind == "string" then return "string:" .. (#value <= 24 and value or "文本过长") end -- 中文维护：诊断有界，不因异常长串挤掉关键操作。
    return kind -- 中文维护：nil与table保持可辨识，不默认零。
end -- 中文维护：诊断文字不拥有Ready权限。
function P.Integer(value) -- 中文维护：物品/技能身份必须是精确正整数，防止小数或无效编号落入 Native 查询。
    local n = tonumber(value) -- 中文维护：配置采用字符串存储，避开 RU SaveData 的 float32 身份损伤。
    if not P.Number(n) or n < 1 or n ~= math.floor(n) or n > 2147483647 then return nil end -- 中文维护：拒绝静默截断、负数和无界探测。
    return n -- 中文维护：返回值只代表编号形状合法，不代表 API 能读或药品已验证。
end -- 中文维护：身份形状和实机证据必须分离。
function P.Cooldown(first, second) -- 中文维护：白名单契约 GetCooldown 返回 remaining,duration；第一版不猜表字段、秒/毫秒或其它排列。
    local remaining, duration = P.Number(first), P.Number(second) -- 中文维护：pcall 成功之后仍须验证业务返回结构。
    if remaining == nil or remaining < 0 or (second ~= nil and (duration == nil or duration < remaining)) then return nil, nil end -- 中文维护：负数/畸形值是未知，不能当 Ready。
    return remaining, duration -- 中文维护：只比较剩余值是否等于零，因此不依赖未验证的时间单位。
end -- 中文维护：UI 原样显示 CD，实机验证之后才可说明它的单位。
function P.EmptyUntil(row, now) -- 中文维护：只有完整成功扫描且尚未过期的缺货证明可供休眠/备用决策复用，不依赖旧CD读数。
    if row and not row.slot and row.emptyConfirmed == true and P.Number(row.emptyScanAt) and now >= row.emptyScanAt and now < row.emptyScanAt + 2000 then return row.emptyScanAt + 2000 end -- 中文维护：期限固定归属真实扫描时点，事件失效、时钟倒退和两秒到期立即变未知，不能每次采样续期。
    return nil -- 中文维护：未完成或失败的扫描永远不能证明缺货。
end -- 中文维护：纯标量判断不读取Native，也不授予Ready。
function P.RowState(r, now) -- 中文维护：每种药独立区分未知、缺货、CD与就绪；关联规则只增加限制，不代替实际读数。
    if not r or not r.itemId or not r.skillId or r.verified ~= true then return "unknown" end -- 中文维护：身份未确认仍不能借用任何休眠状态；所有期限只归属当前映射。
    if r.inventoryUncertain then return "unknown" end -- 中文维护：共享用药方向未确认且曾见过正CD时，单方零值不能授予Ready或放行备用药，须等同轮双零解除否决。
    if P.Number(r.blockedUntil) and now < r.blockedUntil then return "cooldown" end -- 中文维护：已确认用药/共享限制本身足以证明不可用，休眠期间无需伪造新库存、CD或读取时点；该分支永远不授予Ready。
    if not r.slot and r.emptyConfirmed and P.EmptyUntil(r, now) then return "empty" end -- 中文维护：确认缺药时无需继续查询CD或刷新at；过期后必须重新扫描，未知不放行备用药。
    if r.at and now >= r.at and P.Number(r.remaining) and r.remaining > 0 and P.Number(r.cooldownRetryAt) and now < r.cooldownRetryAt then return "cooldown" end -- 中文维护：单位未核实时只将真实正CD保守保留最多250ms，期限一到必须重读，不能延长缓存或把它倒数成零。
    if not r.at or now < r.at or now - r.at > 150 then return "unknown" end -- 中文维护：Ready仍须不超过150ms的真实库存与CD；休眠结束的旧零值没有就绪权限。
    if r.stock == 0 then return "empty" end -- 中文维护：只有完整背包读取证实的零库存才可作为备用药条件。
    if not P.Number(r.stock) or r.stock < 0 or r.stock ~= math.floor(r.stock) or not P.Number(r.remaining) or r.remaining < 0 then return "unknown" end -- 中文维护：读取失败不默认零CD，不继续显示上一轮颜色。
    if r.remaining > 0 or (P.Number(r.blockedUntil) and now < r.blockedUntil) then return "cooldown" end -- 中文维护：实际正CD与用户规则限制取并集，任何一项未结束都不可用。
    return "ready" -- 中文维护：限制结束仅解除一个否决条件；库存与实际零CD仍已在前面验证。
end -- 中文维护：不依赖可选的双向观察标签授予Ready。
function P.Decide(health, maximum, rows, now, enabled, pending) -- 中文维护：每轮唯一信号 Authority；外部循环不能缓存旧 Ready 再持续输入。
    health, maximum, now = P.Number(health), P.Number(maximum), P.Number(now) -- 中文维护：血量和时效同样严格处理未知。
    if not enabled then return nil, "已暂停：不发出用药颜色" end -- 中文维护：配置、重载及用户停用必须同步撤销信号。
    if pending then return nil, "等待游戏冷却反馈：色块已撤下" end -- 中文维护：实际用药事件先撤色，再等 Native 正冷却确认。
    if not health or not maximum or maximum <= 0 or health <= 0 or health > maximum or not now then return nil, "血量未知或角色死亡：色块已撤下" end -- 中文维护：死人、未进入世界和异常血量都不能吃药。
    local percent = health * 100 / maximum -- 中文维护：保留原始比例作比较，UI 四舍五入不能改变用户已保存的阈值。
    local one, two, three = P.RowState(rows[1], now), P.RowState(rows[2], now), P.RowState(rows[3], now) -- 中文维护：直接使用同一状态边界，16ms热路径不再为三次调用分配一个临时闭包。
    if percent <= P:Threshold(3) and three == "ready" then return 3, "图3可用：LCot 可持续按对应药键" end -- 中文维护：低血量优先图3，图2不能抢先消耗关联冷却。
    if percent <= P:Threshold(1) and one == "ready" then return 1, "图1可用：LCot 可持续按对应药键" end -- 中文维护：图1是独立优先药，图3不就绪时仍可按88%规则使用。
    if percent <= P:Threshold(2) and two == "ready" and (three == "cooldown" or three == "empty" or (three == "ready" and percent > P:Threshold(3))) then return 2, "图2备用药可用：LCot 可持续按对应药键" end -- 中文维护：图3未知不能猜成缺货或CD；图3就绪但未达它的自定义阈值时，图2仍可按自身阈值备用。
    return nil, "当前没有满足条件的药：色块已撤下" -- 中文维护：不保留上一次颜色，即使上一次判定成功。
end -- 中文维护：单色结果只能由后续渲染层提交，不产生任何游戏输入。
