-- 中文维护：唯一观察驱动。可用药保留16ms响应；明确限制中的药休眠至结束前250ms，暂停面板250ms采样；不追帧、不发送游戏输入。
local P = LCotPotionSignal -- 中文维护：独立实例，未提交的Suite改动与LCot用户方案均不在本文件范围。
local SCALAR_KEYS = { "value", "id", "type", "itemType", "count", "amount" } -- 中文维护：只读解析键表属于本代次常量，避免每次背包读取创建同样的临时表。
local ITEM_ID_KEYS = { "itemType", "itemTypeId", "typeId", "item_type" } -- 中文维护：身份字段仍沿原白名单，不为优化扩大Native返回契约。
local STOCK_KEYS = { "stackCount", "stack", "count", "itemCount", "amount", "stackSize" } -- 中文维护：数量字段复用固定集合，不在16ms循环重复分配。
local POTION_ITEM_IDS = {} -- 中文维护：自动定位只关心预设Authority定义的三个固定类型，查找表仅在本代次加载时构造一次。
for i = 1, 3 do POTION_ITEM_IDS[P.FixedItemIds[i]] = true end -- 中文维护：不另写一份物品编号，导入/校准仍不能改变固定药品身份。
local function Scalar(value) -- 中文维护：仅沿本机InventorySnapshot已核实的标量包装形状解析身份，不搜索任意Native字段猜语义。
    if type(value) ~= "table" then return value end -- 中文维护：普通标量原样保留。
    for _, key in ipairs(SCALAR_KEYS) do -- 中文维护：只读常量表仍保持有界字段优先级，不能遍历全表猜ID。
        if type(value[key]) == "number" or type(value[key]) == "string" then return value[key] end -- 中文维护：只取实际标量。
    end -- 中文维护：未知嵌套形状留给诊断。
    return nil -- 中文维护：未知不能变成零。
end -- 中文维护：只拥有形状解析。
function P:ItemId(info) -- 中文维护：药品身份与背包槽分开；排序不能让旧槽位自动代表另一种物品。
    if type(info) ~= "table" then return nil end -- 中文维护：无返回不等于空背包的确定证明。
    for _, key in ipairs(ITEM_ID_KEYS) do -- 中文维护：复用固定字段表，解析顺序与原身份契约一致。
        local id = self.Integer(Scalar(info[key])) -- 中文维护：正整数只做形状校验。
        if id then return id end -- 中文维护：第一份明确物品类型身份为Authority。
    end -- 中文维护：不把category_id误当itemType。
    return nil -- 中文维护：不猜同名物品ID。
end -- 中文维护：名称仅用于UI显示。
function P:Stock(info, slot) -- 中文维护：每次发色必须有实际库存读数，不能默认“表存在所以还有1瓶”。
    if type(info) == "table" then -- 中文维护：先消费本工程已用过的数量字段。
        for _, key in ipairs(STOCK_KEYS) do -- 中文维护：复用固定数量字段，不因缓存策略改变零库存与未知的区别。
            local count = self.Number(Scalar(info[key])) -- 中文维护：数量零是合法值，布尔或未知字符串不能等价于零。
            if count and count >= 0 and count == math.floor(count) then return count end -- 中文维护：只认非负整数库存。
        end -- 中文维护：未知字段形状不能编造库存。
    end -- 中文维护：独立公开getter作为已允许的回退。
    local ok, count = self:Read("X2Bag", "ItemStack", slot) -- 中文维护：这个方法在白名单中，禁止改成不可用的CountInBag/GetBagCooldown。
    if ok and self.Number(count) and count >= 0 and count == math.floor(count) then return count end -- 中文维护：成功且值合法才作为库存证据。
    return nil -- 中文维护：API异常时撤色。
end -- 中文维护：不消耗或移动物品。
function P:ReadItem(slot) -- 中文维护：固定背包视图1与本机已核实GetBagItemInfo(1,slot)签名一致。
    slot = self.Integer(slot) -- 中文维护：持久化表不可信，避免无效槽位跨Native边界。
    if not slot or slot > 240 then return nil, nil, nil end -- 中文维护：只读取本版声明覆盖的背包范围，不把越界查询当空格。
    local ok, info = self:Read("X2Bag", "GetBagItemInfo", 1, slot) -- 中文维护：不根据其它客户端的一参数写法调用。
    if not ok then return nil, nil, nil end -- 中文维护：抛错不当缺货。
    return self:ItemId(info), self:Stock(info, slot), info -- 中文维护：原表只在本次显式读取内消费，不长期保留Native对象。
end -- 中文维护：槽位必须与已选择的itemId重新核对。
function P:ScanBag(onlyPotions) -- 中文维护：手动选药仍返回完整列表；自动定位仅收集目标药，全部有货且原槽已核对即可提前结束。
    local ok, capacity = self:Read("X2Bag", "Capacity") -- 中文维护：真实容量必须可读，不能默认240后宣布已扫完整背包。
    capacity = ok and self.Integer(capacity) or nil -- 中文维护：无效容量是未知。
    if not capacity or capacity > 240 then return nil, "背包容量读取失败或超过本版扫描范围；色块保持撤下" end -- 中文维护：未覆盖的槽位不能假称缺货。
    local entries = {} -- 中文维护：只缓存分离后的标量，而不是Native表引用。
    local seen, foundCount, preferredEnd = onlyPotions and {} or nil, 0, 0 -- 中文维护：自动定位最多记录三个已找到类型，数量只统计真实正库存，不能把零数量当有货。
    if onlyPotions then -- 中文维护：提前停止不能跳过用户原先选中的有效堆叠，否则不同堆叠数量可能制造错误的用药下降。
        for i = 1, 3 do local preferred = self.Integer(self.rows[i] and self.rows[i].slot); if preferred then preferredEnd = math.max(preferredEnd, math.min(preferred, capacity)) end end -- 中文维护：至少读到最后一个旧槽；超出当前容量的旧槽必须完整扫描后丢弃。
    end -- 中文维护：普通选择列表没有提前停止或目标过滤。
    for slot = 1, capacity do -- 中文维护：扫描有界且只读。
        local readOk, info = self:Read("X2Bag", "GetBagItemInfo", 1, slot) -- 中文维护：选药过程使用同一已核实背包视图。
        if not readOk then return nil, "背包读取失败：格" .. slot end -- 中文维护：中途错误不能返回部分列表冒充完整缺货证明。
        if type(info) == "table" and next(info) ~= nil then -- 中文维护：空格忽略，但未知非空物品形状必须报告。
            local id = self:ItemId(info) -- 中文维护：先核对物品身份，明确不是目标药时无需额外读数量、拼名称或分配条目表。
            if not id then return nil, "背包格" .. slot .. "返回字段未识别，需要核对GetBagItemInfo实机结构" end -- 中文维护：无法识别身份的格子仍可能是目标药，不能跳过并宣布缺货。
            if not onlyPotions or POTION_ITEM_IDS[id] then -- 中文维护：只过滤身份已确认的非目标物品，显式选择列表继续处理所有物品。
                local stock = self:Stock(info, slot) -- 中文维护：目标药及手动列表仍沿原库存契约，缺数量才调用允许的ItemStack回退。
                if stock == nil then return nil, "背包格" .. slot .. "返回字段未识别，需要核对GetBagItemInfo实机结构" end -- 中文维护：目标药数量未知仍使本次定位失败，不能借过滤制造Ready。
                entries[#entries + 1] = { itemId = id, slot = slot, stock = stock, name = tostring(info.name or info.itemName or ("物品" .. id)) } -- 中文维护：自动定位仅为目标药保留标量条目，手动列表保持原显示数据。
                if onlyPotions and stock > 0 and not seen[id] then seen[id], foundCount = true, foundCount + 1 end -- 中文维护：同类型多个堆叠只计一种，必须三个不同固定药都确实有货才可提前停止。
            end -- 中文维护：非目标物品不需要数量证据来排除其作为药品的可能性。
        elseif info ~= nil and type(info) ~= "table" then return nil, "背包格" .. slot .. "返回类型未识别：" .. type(info) end -- 中文维护：未知返回类型必须停选药。
        if onlyPotions and foundCount == 3 and slot >= preferredEnd then break end -- 中文维护：三药均有正库存且旧槽全部核对后，不再读取剩余无关背包；任何缺药都必须继续扫到真实容量末尾。
    end -- 中文维护：提前结束只证明三药都有货；缺货结论仍只来自完整扫描。
    return entries -- 中文维护：不自动执行任何药品动作。
end -- 中文维护：背包排序后的身份恢复由固定ID定位完成，不改变已校准技能。
function P:LocateItems() -- 中文维护：固定物品ID是定位Authority，槽位只是当前客户端的可丢弃缓存。
    local entries, err = self:ScanBag(true) -- 中文维护：运行期定位走目标过滤/有货提前停止；缺货仍完整成功扫描，失败不得宣布缺货。
    self.bagScanAt = self.now -- 中文维护：缺药或排序后最多每两秒补一次扫描，不每帧扫全包。
    if not entries then return false, err end -- 中文维护：保留未知，不把Native失败当空背包。
    for i = 1, 3 do -- 中文维护：三个固定药品一起定位，避免同一轮重复扫描三次。
        local row, found = self.rows[i], nil -- 中文维护：绑定技能与证据保持，物品位置可以变化。
        for _, entry in ipairs(entries) do if entry.itemId == row.itemId and entry.stock > 0 then if not found or entry.slot == row.slot then found = entry end end end -- 中文维护：优先保留原有效堆叠，其次用实际同ID库存。
        local slot = found and found.slot or nil -- 中文维护：完整扫描没有该ID才可证明当前缺货。
        if row.slot ~= slot then row.stock, row.observationRetryAt, row.cooldownRetryAt = nil, nil, nil end -- 中文维护：换堆叠先清消耗基线与短观察缓存，不能把新槽当成旧槽的数量下降或沿用失败重试期限。
        row.slot, row.emptyScanAt, row.emptyConfirmed = slot, self.now, found == nil -- 中文维护：缺货证明保留真实扫描时点，不能每50ms续期。
        if found then row.name = found.name end -- 中文维护：界面展示本机真实名称，预设不依赖中文名称比较。
    end -- 中文维护：只改位置缓存，不清掉任何已记录映射。
    self.nextSampleAt = nil -- 中文维护：显式定位或补货扫描可能让休眠中的空槽恢复库存，旧合并期限不能压住下一次真实核对。
    return true -- 中文维护：没有移动、使用或排序背包物品。
end -- 中文维护：正常三槽采样与低频重新定位分开。
function P:SaveBindings() -- 中文维护：持久化已实测映射与关联证据；CD、Ready、启用仍仅属当前运行时。
    if type(ADDON.SaveData) ~= "function" then self.saveError = "客户端没有配置保存接口"; return false end -- 中文维护：保存能力缺失必须可见，不能伪称已保存。
    local saved = { contract = "readonly-potion-v2", preset = self:ExportPreset(), panelScale = tostring(self.panelScale or 100), thresholds = {}, rows = {} } -- 中文维护：预设有固定身份与版本；用字符串避开RU浮点精度和假值省略。
    for i = 1, 3 do saved.thresholds[i] = tostring(self:Threshold(i)) end -- 中文维护：字符串精确保留0/88/62，不依赖RU省略数值0或float32百分比回读。
    for i = 1, 3 do local row = self.rows[i]; saved.rows[i] = { itemId = tostring(row.itemId or ""), slot = tostring(row.slot or ""), name = row.name or "" } end -- 中文维护：位置只是本机提示，重启会按真实固定ID重新定位。
    local ok, result = pcall(ADDON.SaveData, ADDON, "lcot_potion_signal_bindings_v1", saved) -- 中文维护：沿用原私有键就地升级，不清空别人的数据。
    self.saveError = (not ok or result == false) and "药品预设保存失败；当前仅在内存生效" or nil -- 中文维护：业务失败独立显示，不被确认成功提示覆盖。
    return self.saveError == nil -- 中文维护：没有布尔false/数值0需要依赖RU保存器保留。
end -- 中文维护：可复用校准合同不等于可复用实时Ready。
function P:SelectItem(index, entry) -- 中文维护：固定药品只接受对应ID，同一药品换位置不丢失已验证的技能映射。
    local id, count = self:ReadItem(entry.slot) -- 中文维护：列表快照可能已过期，提交时必须重读。
    if id ~= self.FixedItemIds[index] or id ~= entry.itemId or not count or count <= 0 then self.reason = "请选择这一行对应的固定药品；背包变化后请刷新"; self:RefreshText(); return end -- 中文维护：不能把其它物品的事件绑定成吃药预设。
    local row = self.rows[index] -- 中文维护：本行记录拥有独立生命周期，不替换整张三行表。
    row.itemId, row.slot, row.name, row.stock = id, entry.slot, entry.name, count -- 中文维护：只更新本机位置和可读库存，保留已确认的技能与关联合同。
    row.emptyConfirmed, row.observationRetryAt, row.cooldownRetryAt, self.nextSampleAt = false, nil, nil, nil -- 中文维护：用户明确选中实物后立即撤销旧缺货/失败观察，下一轮读真实CD，不等待旧的两秒休眠。
    self.arm, self.armCross = nil, nil -- 中文维护：选择新位置取消现场记录，但不清掉已提交结果。
    self:SaveBindings(); self.reason = row.verified and "药品位置已更新，已记录的冷却映射保留" or "药品已找到。点“记录冷却”后手动使用，验证通过将自动保存。"; self:RefreshText() -- 中文维护：按钮意图与持久化结果明确可见。
end -- 中文维护：其它两行完全保持。
function P:Arm(index) -- 中文维护：只记录用户明确选择的一瓶药及本人的施法成功事件。
    self:Disable("记录冷却：请手动只使用" .. self.Specs[index].name .. "一次，不要同时释放其它技能") -- 中文维护：记录期间始终不发色。
    self:ClearStockChanges() -- 中文维护：开始重录前取消旧拖动/数量变化候选，不能把旧操作的新CD反馈混入本次校准。
    self:LocateItems() -- 中文维护：记录前按固定ID重找，背包排序不需要重新做技能校准。
    local row = self.rows[index] -- 中文维护：本轮配置快照。
    if not row.itemId or not row.slot then self.reason = "请先选择这瓶药"; self:RefreshText(); return end -- 中文维护：没有药品身份时不收集泛化技能。
    local id, stock = self:ReadItem(row.slot) -- 中文维护：起始库存必须是真实可读。
    if id ~= row.itemId or not stock or stock <= 0 then self.reason = "背包未找到对应药品或读数未知，请补充药品后重新定位"; self:RefreshText(); return end -- 中文维护：拒绝把未知或缺货作为记录成功。
    row.awaitCooldown = false -- 中文维护：重新记录是临时事务，直到确认新结果前保留已提交映射；期间信号始终暂停。
    self.armCross = nil -- 中文维护：新的单药记录取消旧关联记录，不能交叉归因。
    self.arm = { index = index, slot = row.slot, before = stock, started = self.now, order = {}, candidates = {} } -- 中文维护：最多8个本机真实事件候选，不进行技能编号枚举。
    self:RefreshText() -- 中文维护：立即显示正在记录。
end -- 中文维护：60秒上限只用于避免遗忘的记录，用户不必在3秒内操作。
function P:OnCombat(_, eventType, sourceName, _, skillId, abilityName) -- 中文维护：私有Widget的COMBAT_MSG payload为unitId,eventType,sourceName,targetName,abilityId,abilityName，来自本机CombatEventBus实际消费端。
    if eventType ~= "SPELL_CAST_SUCCESS" then return end -- 中文维护：治疗量、Buff/aura ID不能升级为可查CD的技能ID。
    skillId = self.Integer(skillId); if not skillId then return end -- 中文维护：只消费真实成功事件中的合法技能编号，不枚举探测。
    local relevant = self.arm ~= nil; for _, row in ipairs(self.rows) do if row.verified and row.skillId == skillId then relevant = true end end -- 中文维护：未记录时只有三种已确认药品事件需核实姓名，避免战斗中所有人的施法都触发Native读取。
    if not relevant then return end -- 中文维护：无关事件不更新限制、配置或信号。
    local ok, playerName = self:Read("X2Unit", "UnitName", "player") -- 中文维护：相关事件仍现场核实本人名称，重载/切角色不沿用旧缓存。
    if not ok or type(playerName) ~= "string" or playerName == "" or sourceName ~= playerName then return end -- 中文维护：其它人的事件不能绑定药品或撤销本人的CD。
    for i, row in ipairs(self.rows) do -- 中文维护：暂停时本人手动用药也会更新限制，重新启用不能遗忘关联冷却。
        if row.verified and row.skillId == skillId then self:RecordUse(i) end -- 中文维护：只接收这三个已确认技能的本人成功事件，马上撤色。
    end -- 中文维护：标称时限只作为保守限制，不是实际Native关联证据。
    local arm = self.arm -- 中文维护：记录与运行是分开的会话。
    if not arm or self.now - arm.started > 60000 or arm.candidates[skillId] or #arm.order >= 8 then return end -- 中文维护：记录有界、可取消，重复事件不扩容。
    arm.candidates[skillId] = { id = skillId, name = tostring(abilityName or ""), positive = false } -- 中文维护：候选仍未获得药品身份。
    arm.order[#arm.order + 1] = skillId -- 中文维护：仅由实际事件产生，禁止爆破GetCooldown。
end -- 中文维护：不订阅公共UIParent事件，避免覆盖其它插件。
function P:BindCandidate(index) -- 中文维护：只有手动用药、库存下降、唯一真实正CD候选和明确点击确认同时成立才绑定。
    local arm, found = self.arm, nil -- 中文维护：不跨记录会话消费候选。
    if not arm or arm.index ~= index then self.reason = self.rows[index].verified and "这一瓶已记录并保存；需要重录时点“记录冷却”" or "先点这一行“记录冷却”，然后手动用药"; self:RefreshText(); return end -- 中文维护：其它行不能抢候选，已记录按钮不再显示未记录。
    for _, id in ipairs(arm.order) do -- 中文维护：候选最多8个。
        if arm.candidates[id].positive then -- 中文维护：返回零本身不能证明接口能读这瓶药。
            if found then self.reason = "出现多个正CD候选，请取消记录后只使用这一瓶药再试"; self:RefreshText(); return end -- 中文维护：有歧义时不能自动挑第一个。
            found = arm.candidates[id] -- 中文维护：保留唯一有真实正冷却证据的候选。
        end -- 中文维护：未知及零值不升级权限。
    end -- 中文维护：不会用名称模糊匹配药品技能。
    if not found or not arm.consumed then self.reason = "尚未同时确认药品数量下降和唯一正CD；色块保持撤下"; self:RefreshText(); return end -- 中文维护：纯pcall成功不代表用药成功。
    for i, other in ipairs(self.rows) do if i ~= index and other.verified and other.skillId == found.id then self.reason = "候选技能已属于另一种药，请只使用当前药后重录"; self:RefreshText(); return end end -- 中文维护：不同固定药不能共享同一个未经区分的候选技能，避免预设重启解析失效。
    local row = self.rows[index] -- 中文维护：提交前再次核对本行仍是同一药。
    if index ~= 1 and row.skillId ~= found.id then self:ResetCross() end -- 中文维护：只有提交的新技能身份改变才撤销关联证据，记录另一行不会影响图1。
    row.skillId, row.verified, row.awaitCooldown = found.id, true, false -- 中文维护：明确正CD与药品消耗证明通过后持久化映射；实时冷却仍逐轮重读。
    self:RecordUse(index) -- 中文维护：刚完成的药品消耗也须记入独立/共享限制，不能启用时把迟到零CD当就绪。
    self.arm = nil; self:SaveBindings(); self.reason = "已记录并保存" .. self.Specs[index].name .. "；重启可复用，也可分享预设"; self:RefreshText() -- 中文维护：自动确认后保持暂停，用户显式启用才输出颜色。
end -- 中文维护：图2/图3交叉观察仅作可选证据，不把按规则限制写成Native实测结果。
function P:ResetCross() -- 中文维护：关联冷却合同绑定当前固定物品与已验证技能，可跨启动复用；技能变化时必须撤销。
    self.crossEvidence, self.armCross = {}, nil -- 中文维护：清除两个方向及正在记录的因果窗口。
    for i = 2, 3 do self.rows[i].crossVerified = false end -- 中文维护：仅影响互相共享CD的图2/图3，图1独立验证保留。
end -- 中文维护：新映射提交后再保存，防止未提交的重录事务破坏持久化证据。
function P:BeginCross() -- 中文维护：初次实测两个方向，先使两种药都实际归零，再只手动使用其中一种。
    self:Disable("核对关联冷却：色块已撤下") -- 中文维护：校准不与外部自动输入并发。
    self.arm, self.armCross = nil, nil -- 中文维护：每次显式开始只有一个归因窗口。
    self:ClearStockChanges() -- 中文维护：关联校准从新的真实库存/零CD起点开始，旧数量候选没有当前因果资格。
    if self.inventoryPairLock then self.inventoryPairRetryAt = nil end -- 中文维护：用户显式核对关联CD时立即读取两方，不等旧250ms期限；只能真实双零解除锁。
    self:Sample() -- 中文维护：先取得同轮当前库存与CD，不信任旧面板文本。
    local two, three = self.rows[2], self.rows[3] -- 中文维护：两种药必须各自完成唯一正CD校准。
    if not two.verified or not three.verified or not two.stock or two.stock <= 0 or not three.stock or three.stock <= 0 then self.reason = "先选择图2/图3，并分别记录确认它们的自有CD"; self:RefreshText(); return end -- 中文维护：没有药或身份未知时不能验证关联。
    if two.remaining ~= 0 or three.remaining ~= 0 then self.reason = "请等图2/图3的实际CD都归零，再点关联核对"; self:RefreshText(); return end -- 中文维护：已有正CD无法证明由本次另一瓶药造成。
    self.crossEvidence = self.crossEvidence or {} -- 中文维护：保留当前映射已有的实测方向；完整双向合同可从存档或分享预设恢复。
    if self.crossEvidence.twoAfterThree and self.crossEvidence.threeAfterTwo then self.reason = "两个方向均已观察到实际关联CD，本次可启用"; self:RefreshText(); return end -- 中文维护：完成后点击不会无故清空证据。
    local used = self.crossEvidence.twoAfterThree and 2 or 3 -- 中文维护：先记录图3→图2，再记录图2→图3，不猜关联倒计时。
    self.armCross = { used = used, other = used == 3 and 2 or 3, before = { [2] = two.stock, [3] = three.stock }, started = self.now } -- 中文维护：只有本药数量下降且另一药数量不变，才能把新的正CD归因给此手动操作。
    self:RefreshText() -- 中文维护：用户不需要3秒内完成动作，记录仍有60秒遗忘上限。
end -- 中文维护：仍不使用非白名单CD接口或输入API。
function P:EnableSignal() -- 中文维护：内置实测映射直接可用，关联记录是可选诊断，不再强迫每位用户重复消耗药品。
    self:Disable("正在核对当前血量、库存与CD") -- 中文维护：重新点击启用也先撤掉旧颜色，定位或读取失败不能留下上一轮可用信号。
    self.arm, self.armCross = nil, nil -- 中文维护：启用结束手动记录会话，不把候选当正式映射。
    local located, err = self:LocateItems() -- 中文维护：启用必须按本机固定ID重找，不能继承别人的位置。
    self:Sample() -- 中文维护：按钮本次回调取得实际血量和CD，不先收起窗口再让用户猜无反应原因。
    local any = false; for _, row in ipairs(self.rows) do if row.verified then any = true end end -- 中文维护：只使用用户已实测的固定映射，不要求可选关联标签。
    if self.error or not located or not any then self:Disable(self.error or err or "没有已确认的药品映射"); self:SetPanelVisible(true); return end -- 中文维护：初始化或定位失败保持暂停与可见诊断。
    if not self.health or not self.maximum or self.maximum <= 0 or self.health <= 0 or self.health > self.maximum then self:Disable("暂不能启用：血量未知或角色死亡，见上方原始读数"); self:SetPanelVisible(true); return end -- 中文维护：未知血量时面板留在原位，不伪称已经可运行。
    if not self:ApplySignalGeometry(true) then self:SetPanelVisible(true); return end -- 中文维护：每次明确启用立即核对当前UI比例；未知或拒写保留设置窗口与停止状态，不能等待旧缓存到期。
    self.enabled = true; self:Sample(); self:CollapsePanel(); self:RefreshText() -- 中文维护：本轮决策即提交，收起只释放自己的编辑焦点，不启动LCot或发送键盘输入。
end -- 中文维护：血量高于阈值时可以正常启用并等待，颜色仍保持撤下。
function P:RowWakeAt(index) -- 中文维护：返回下一次必须核对真实库存/CD的时点；只有不可用事实可以缓存，Ready没有休眠权限。
    if self.arm or self.armCross then return nil end -- 中文维护：手动校准需要真实零→正CD及库存下降，必须绕过运行期休眠。
    local row, use = self.rows[index], self:Usage(index) -- 中文维护：Usage先核对固定物品与已确认技能身份，配置替换不能继承另一映射的限制。
    if not row then return nil end -- 中文维护：未知配置不能制造可推算的可用性。
    row.blockedUntil = use and use.blockedUntil or nil -- 中文维护：只同步已有的保守限制，不生成Native冷却读数。
    if row.inventoryPendingUntil then return nil end -- 中文维护：数量变化待确认时保留快速CD反馈，不能被失败退避、缺货缓存或旧合并期限压住。
    if row.awaitCooldown and use and use.pendingUntil and self.now < use.pendingUntil then return nil end -- 中文维护：用药后最多500ms保留实际正CD确认通道；一读到反馈即由UsagePending解除全局等待，不能让休眠平白拖慢独立可用药。
    if row.inventoryUncertain then return self.inventoryPairRetryAt and self.now < self.inventoryPairRetryAt and self.inventoryPairRetryAt or nil end -- 中文维护：共享未归因时两方一起按250ms核对CD，不能被长CD/缺货休眠挡住，也不拖慢独立图1。
    if use and use.blockedUntil - 250 > self.now then return use.blockedUntil - 250 end -- 中文维护：21/90/30秒及30/60秒共享限制已由用药层确认，提前250ms恢复检查，禁止乘除未核实的Native CD单位。
    if not row.slot and row.emptyConfirmed then local emptyUntil = self.EmptyUntil(row, self.now); if emptyUntil then return emptyUntil end end -- 中文维护：无药时沿现有两秒补货扫描周期休眠，不再每16ms查没有意义的技能CD。
    if row.observationRetryAt and row.at and self.now >= row.at and self.Number(row.observationRetryAt) and self.now < row.observationRetryAt then return row.observationRetryAt end -- 中文维护：仅失败行校验250ms退避；可用药先以nil短路，避免16ms热路径反复校验不存在的期限，Unknown仍不放行备用药。
    if row.at and self.now >= row.at and self.Number(row.remaining) and row.remaining > 0 and self.Number(row.cooldownRetryAt) and self.now < row.cooldownRetryAt then return row.cooldownRetryAt end -- 中文维护：只有正CD可短暂退避；缺少用药时间证据时最多250ms再查，不能用标称整段CD猜剩余时间。
    return nil -- 中文维护：期限到达或真实可用时必须重新读取，任何休眠到期都不直接标Ready。
end -- 中文维护：此查询仅访问Lua标量，无游戏API，也不分配每帧任务或计时器。
function P:Sample() -- 中文维护：仅到期药读取Native，休眠药保留不可用事实；恢复Ready前仍要求当轮真实库存和零CD。
    if self.inventoryPairLock then self:SyncInventoryPair() end -- 中文维护：重载或同映射导入后的新行恢复已观察到的否决，正常无锁采样不增加Usage查询。
    self.sampleProbes = self.sampleProbes or { {}, {}, {} } -- 中文维护：三份固定探测缓冲属于本实例，复用空间减少16ms路径的短命表与GC。
    local probes, needsLocate, allSleeping, usageRevision, stockPending = self.sampleProbes, false, true, self.usageRevision, false -- 中文维护：先收齐数量候选再核对CD，结果供正式行更新复用；共享药库存不能单独归因用药方向。
    for i, row in ipairs(self.rows) do -- 中文维护：先清所有已过期数量候选，再采集新变化，不能让上个不重叠的窗口制造新的共享歧义。
        if row.inventoryPendingUntil and self.now > row.inventoryPendingUntil then row.inventoryPendingUntil = nil end -- 中文维护：只清未确认候选，已见正CD的pairUncertain保守否决独立保留。
        row.wakeAt = self:RowWakeAt(i); row.sleeping = row.wakeAt ~= nil; probes[i].slot, probes[i].cooldownSampled = nil, false; if not row.sleeping then allSleeping = false end -- 中文维护：库存/CD候选结果仅允许本轮复用；校准期间三药均不休眠。
    end -- 中文维护：过期清理完成后才允许比较任意药品的新数量下降。
    self.healthSleeping = self.enabled and allSleeping -- 中文维护：三药均因冷却、缺货或Unknown暂不能发色时，血量不会改变结果；暂停/启用核对仍读取真实血量。
    if not self.healthSleeping then -- 中文维护：任一药接近可用时立即恢复原有16ms血量响应，不把界面低频扩散到战斗信号。
        local hpOk, hp = self:Read("X2Unit", "UnitHealth", "player") -- 中文维护：只消费本人的实际血量。
        local maxOk, maxHp = self:Read("X2Unit", "UnitMaxHealth", "player") -- 中文维护：最大血量不可读时禁止计算假比例。
        self.health, self.maximum = hpOk and self.HealthNumber(hp) or nil, maxOk and self.HealthNumber(maxHp) or nil -- 中文维护：失败清掉旧血量，不能因减少Native读取保留旧Ready。
        self.healthRaw = self.panelOpen and ("当前 " .. self.HealthRaw(hp, hpOk) .. " / 上限 " .. self.HealthRaw(maxHp, maxOk)) or nil -- 中文维护：原值诊断只在面板可见时格式化，收起后的16ms路径不生成无人读取的字符串。
    else self.health, self.maximum, self.healthRaw = nil, nil, nil end -- 中文维护：休眠明确撤销旧血量权限，唤醒必须重读，不能借缓存发色。
    for i, row in ipairs(self.rows) do -- 中文维护：探测先保留原槽与库存，最后一瓶用完不能因自动定位清掉消耗证据。
        if not row.sleeping and row.slot then -- 中文维护：休眠药不查背包，限制结束前才重新核对实际槽位；没有槽位时不能猜位置。
            local id, stock = self:ReadItem(row.slot); local probe = probes[i]; probe.slot, probe.id, probe.stock = row.slot, id, stock -- 中文维护：只写本轮复用缓冲，不保留Native对象，不再每药每帧分配新表。
            if row.stock and stock and stock < row.stock and (id == row.itemId or (id == nil and stock == 0 and row.stock == 1)) then self:ObserveStockChange(i) end -- 中文维护：同ID数量下降/最后一瓶归零先撤色核对；堆叠互换或拆分不能直接被当成用药。
            if id ~= row.itemId or stock == 0 then needsLocate = true end -- 中文维护：排序/合堆或同ID零数量表都须完整定位，寻找其他堆叠或证明缺货；不能让用完的槽永久阻塞备用药。
        elseif not row.sleeping then needsLocate = true end -- 中文维护：仅当前有需求且缺药才用两秒扫描恢复补货，长CD中的空槽无需重复全包定位。
        if row.inventoryPendingUntil then stockPending = true end -- 中文维护：没有数量候选时跳过额外CD核对分支，避免常态热路径开销。
    end -- 中文维护：三槽变化只触发一次共同定位。
    if stockPending then -- 中文维护：仅发生数量变化时进入额外核对，不增加正常16ms采样的Native读取。
        for i, row in ipairs(self.rows) do if row.inventoryPendingUntil then self:CheckStockChange(i, probes[i]) end end -- 中文维护：独立药可确认用药，共享药仅确认不可用；读数交给本轮正式刷新复用，失败保持Unknown。
    end -- 中文维护：本人事件随时可直接确认真实用药并取消对方的共享候选。
    local scanInterval = self.bagDirty and 250 or 2000 -- 中文维护：事件风暴至少合并250ms，平时缺药每两秒扫一次；不会每50ms枚举240格。
    if needsLocate and (not self.bagScanAt or self.now - self.bagScanAt >= scanInterval) then if self:LocateItems() then self.bagDirty = false end -- 中文维护：真实缺药或换槽仍合并一次全量定位，失败不能续期缺货证据。
    elseif not needsLocate and not allSleeping then self.bagDirty = false end -- 中文维护：无关战利品/交易事件只需重读已知药槽，不再每250ms触发一次240格扫描；休眠中的空槽唤醒后另行定位。
    local pending = false -- 中文维护：已知用药的短暂反馈等待与本药/关联限制分离，不能永久阻塞独立药。
    for i, row in ipairs(self.rows) do -- 中文维护：正常运行只查询三种已配置药品，不产生游戏输入。
        if usageRevision ~= self.usageRevision then row.wakeAt = self:RowWakeAt(i); row.sleeping = row.wakeAt ~= nil end -- 中文维护：仅当本轮库存探测确实发现新用药时重算共享限制；常态复用本轮开头的Lua期限，减少热路径调用。
        if not row.sleeping then -- 中文维护：休眠期间不更新at，也不把旧CD/库存包装成本轮新读数；RowState只允许不可用状态跨轮。
            row.stock, row.remaining, row.duration, row.at, row.observationRetryAt, row.cooldownRetryAt = nil, nil, nil, nil, nil, nil -- 中文维护：每次真正重试先清旧观察及失败期限，不能把旧Ready或过期缺货证据续期为新读数。
            if row.itemId and row.slot then -- 中文维护：只有当前本机位置才可跨Native读取。
                local probe = probes[i] -- 中文维护：未移动的槽复用本轮读数，定位换槽后必须读新的真实位置。
                local id, stock; if probe and probe.slot == row.slot then id, stock = probe.id, probe.stock else id, stock = self:ReadItem(row.slot) end -- 中文维护：缓存仅覆盖本次16ms采样，不复用上一次库存。
                if id == row.itemId then row.stock = stock end -- 中文维护：身份不符保持Unknown，不把旧槽物品当固定药。
            elseif self.EmptyUntil(row, self.now) then row.stock = 0 end -- 中文维护：只接收仍有效的完整缺货证明，两秒边界立即过期，重扫失败不能保留零库存。
            if row.stock == 0 and not row.awaitCooldown and not row.inventoryPendingUntil and not row.inventoryUncertain and not self.arm and not self.armCross then row.wakeAt = self.EmptyUntil(row, self.now) -- 中文维护：常态缺药免查CD；最后一瓶、共享未归因或校准仍须读取实际CD，保证真实双零可解除否决。
            elseif row.skillId and row.verified then -- 中文维护：正常运行只查询有库存需求或校准需要的已验证技能。
                local probe = probes[i] -- 中文维护：库存候选的CD结果只在同一轮、同一已验证技能下复用，不能沿用上轮或旧映射。
                if probe.cooldownSampled and probe.cooldownSkillId == row.skillId then row.remaining, row.duration = probe.cooldownRemaining, probe.cooldownDuration -- 中文维护：复用刚完成的实际CD核对，未知原样保留，不再跨Native重复查询。
                else local ok, first, second = self:Read("X2Skill", "GetCooldown", row.skillId, true); if ok then row.remaining, row.duration = self.Cooldown(first, second) end end -- 中文维护：常态仍按原参数读取并严格解析，未采样/身份不符不能命中候选缓存。
                row.at = self.now -- 中文维护：本轮所有需要的读取均已尝试，nil依然由纯层判Unknown。
                row.observationRetryAt = (row.stock == nil or row.remaining == nil) and self.now + 250 or nil -- 中文维护：库存/CD未知只延后重试，不制造零CD；事件或配置变更会提前失效该期限。
                row.cooldownRetryAt = row.remaining and row.remaining > 0 and self.now + 250 or nil -- 中文维护：未知单位的正CD只退避250ms；零或异常立即取消退避，仍按原热路径检查。
                if row.cooldownRetryAt and row.blockedUntil and row.blockedUntil > self.now then row.cooldownRetryAt = math.min(row.cooldownRetryAt, row.blockedUntil) end -- 中文维护：预唤醒的正CD检查不得跨过规则到期点，最迟在到期后的下一帧重新核对真实零。
                row.wakeAt = not self.arm and not self.armCross and (row.inventoryUncertain and self.now + 250 or row.observationRetryAt or row.cooldownRetryAt) or nil -- 中文维护：共享未归因也只按250ms核对，单方零不进入16ms空转；校准不休眠，正常Ready无退避权限。
                if row.wakeAt and not row.inventoryUncertain and row.blockedUntil and row.blockedUntil - 250 > self.now then row.wakeAt = row.blockedUntil - 250 end -- 中文维护：普通已确认限制可长休眠；共享未归因必须继续共同核对真实CD以取得解除证据。
            end -- 中文维护：未验证药不获得Ready。
        end -- 中文维护：只有不休眠行获得当轮读数，校准模式始终执行上述真实读取。
        if not self.arm and not self.armCross and row.blockedUntil and row.blockedUntil - 250 > self.now then row.stock = nil end -- 中文维护：长限制期间始终废弃消耗比较基线；CD先到或500ms超时后库存才扣除，都不能在预唤醒时把同一瓶再记一次，校准的同轮库存证据必须保留。
        if row.inventoryPendingUntil then row.wakeAt = nil end -- 中文维护：待确认阶段继续16ms核对；即使本轮CD未知也不能提前按250ms退避把正反馈响应变慢。
        row.sleeping = row.wakeAt ~= nil -- 中文维护：本轮刚确认正CD也可能已经进入休眠，面板须把保留的CD明确标作上次观察，不能等待下一次采样才更新展示状态。
    end -- 中文维护：三行状态完全更新后只做一次决策，避免中间帧出现错误药色。
    if self.inventoryPairLock then self:ResolveInventoryPair() end -- 中文维护：仅同轮真实双零可解除共享歧义，500ms候选结束本身永远不授予两药Ready。
    pending = self:UsagePending() -- 中文维护：全部三行实际读数完成之后同步额外限制与短反馈等待，不恢复旧Ready。
    local arm = self.arm -- 中文维护：只读记录有独立的有限生命周期。
    if arm then -- 中文维护：记录期间最多读取8个现场候选。
        local row = self.rows[arm.index] -- 中文维护：只核对被记录的那个槽位。
        local id, stock = self:ReadItem(arm.slot) -- 中文维护：保留开始记录的实际槽位，最后一瓶用完后自动定位清空行槽位也不丢消耗证据。
        if id == row.itemId and stock and stock < arm.before then arm.consumed = true end -- 中文维护：数量下降是必要证据，不把事件本身当已消费。
        if id == nil and stock == 0 and arm.before == 1 then arm.consumed = true end -- 中文维护：最后一瓶消耗后原槽归零，仍只作为手动记录内的消耗证据。
        for _, candidateId in ipairs(arm.order) do -- 中文维护：不枚举数据库或增加无来源技能ID。
            local candidate = arm.candidates[candidateId] -- 中文维护：候选仅属本次记录。
            local ok, first, second = self:Read("X2Skill", "GetCooldown", candidateId, true) -- 中文维护：使用与正式观察相同的允许接口/参数。
            candidate.remaining, candidate.duration = nil, nil -- 中文维护：失败不保留旧CD文本冒充当前。
            if ok then candidate.remaining, candidate.duration = self.Cooldown(first, second) end -- 中文维护：没有实际正CD就不能通过校准。
            if candidate.remaining and candidate.remaining > 0 then candidate.positive = true end -- 中文维护：正CD证据仅保存到本次校准完成或取消。
        end -- 中文维护：有界读数，不做后台服务器查询。
        local positives = 0; for _, id in ipairs(arm.order) do if arm.candidates[id].positive then positives = positives + 1 end end -- 中文维护：数量下降和唯一正CD同时成立才可自动提交。
        if arm.consumed and positives == 1 then self:BindCandidate(arm.index) end -- 中文维护：用户无需额外点确认；歧义、零值或无消耗继续记录，不覆盖已提交映射。
        if self.arm and self.now - arm.started > 60000 then self.arm = nil; self:Disable("冷却记录已结束，未确认则不发色，可重新点记录") end -- 中文维护：防止遗忘的记录无限收集。
    end -- 中文维护：记录与正式用药信号互斥。
    local cross = self.armCross -- 中文维护：另一个药原来为零且未消耗，才能验证本次用药使它进入共享CD。
    if cross then -- 中文维护：关联记录始终处于暂停状态，没有LCot输入反馈污染。
        local used, other = self.rows[cross.used], self.rows[cross.other] -- 中文维护：消费刚完成的同轮Native读数。
        if used.stock and used.stock < cross.before[cross.used] and other.stock == cross.before[cross.other] and used.remaining and used.remaining > 0 and other.remaining and other.remaining > 0 then -- 中文维护：同时需要本药消耗、自有正CD、另一药未消耗及另一药从零变为正CD。
            if cross.used == 3 then self.crossEvidence.twoAfterThree = true else self.crossEvidence.threeAfterTwo = true end -- 中文维护：两个方向分别记录。
            local both = self.crossEvidence.twoAfterThree == true and self.crossEvidence.threeAfterTwo == true -- 中文维护：单向观察不能标成两向已实测，Ready只由当前读数与规则限制决定。
            self.rows[2].crossVerified, self.rows[3].crossVerified = both, both -- 中文维护：只保存观察证据，不授予或撤销基于实际CD的Ready。
            self.armCross = nil; self.reason = both and "两个方向关联CD已验证并保存，重启或分享可复用" or "已观察当前方向；另一方向可稍后核对，不影响按既定规则启用" -- 中文维护：两个方向分别持久化结果，不保存实时倒计时。
            if both then self:SaveBindings() end -- 中文维护：完成整个关联合同才将可分享证据写入存档。
        elseif self.now - cross.started > 60000 then self.armCross = nil; self.reason = "本次未确认关联CD，记录已结束；仍按既定30/60秒规则限制" end -- 中文维护：读取不覆盖共享CD时fail-closed。
    end -- 中文维护：没有关联冷却证据不意味着没有关联冷却。
    self.nextSampleAt = nil -- 中文维护：先撤销旧合并期限，任何一行不休眠就保持16ms快速响应。
    local earliest, sleepingCount = nil, 0 -- 中文维护：只需三个固定标量期限，无需通用任务堆或每帧定时器对象。
    for i = 1, 3 do local wake = self.rows[i].wakeAt; if wake then sleepingCount = sleepingCount + 1; earliest = earliest and math.min(earliest, wake) or wake end end -- 中文维护：复用本轮已核对的三药期限，最早一瓶接近可用时唤醒；不为合并定时再查一遍Usage。
    if sleepingCount == 3 then self.nextSampleAt = earliest end -- 中文维护：全不可用时唯一OnUpdate只推进时钟与可见文字，到期再执行Native采样。
    local index, reason = self.Decide(self.health, self.maximum, self.rows, self.now, self.enabled and not self.error, pending) -- 中文维护：唯一公开信号由当前真实可用快照或明确不可用事实决定。
    if self.healthSleeping then reason = "药品暂不可用：等待到期重新检查" end -- 中文维护：休眠可能来自缺货或Unknown，不能一概冒充冷却，也不能误报死亡；各行保留具体原因。
    if self.enabled then self.reason = reason end -- 中文维护：暂停或记录中的人工提示不被每轮“无药”文字覆盖。
    self:RenderSignal(index) -- 中文维护：nil立即Hide，不能等250ms文字刷新。
end -- 中文维护：结束时未提交任何键盘输入。
function P:RefreshText() -- 中文维护：慢速文字仅说明观察结果，不驱动颜色或业务状态。
    if not self.panel then return end -- 中文维护：构造失败仍保持信号关闭。
    self:RefreshPreviews(); self:RefreshSignalToggle() -- 中文维护：诊断统一投影真实启停态；运行时常亮预览色隐藏，不能被LCot误匹配。
    local percent = self.health and self.maximum and self.maximum > 0 and self.health * 100 / self.maximum or nil -- 中文维护：未知显示未知。
    self:SetObservedText(self.healthLabel, self.healthSleeping and "血量：药品暂不可用，暂缓采样" or (percent and string.format("血量：%.1f%%  (%s / %s)", percent, tostring(self.health), tostring(self.maximum)) or ("血量：未知，色块已撤下 · " .. (self.healthRaw or "等待读取")))) -- 中文维护：只在文字变化时写Native；休眠可能来自缺货/Unknown，不把旧血量伪装成实时值。
    for i, row in ipairs(self.rows) do -- 中文维护：固定行增量刷新。
        self:SetObservedText(self.rowLabels[i], self.Specs[i].name) -- 中文维护：只读药名常态零Native重写，阈值仍由独立设置按钮呈现。
        local threshold = self:Threshold(i) -- 中文维护：只投影已提交值，250ms刷新不重写正在编辑的数字草稿。
        if self.thresholdButtons[i] and self.thresholdButtonValues[i] ~= threshold then
            self.thresholdButtons[i]:SetText("≤" .. threshold .. "% 设置"); self.thresholdButtonValues[i] = threshold -- 中文维护：数值未变时不重复写Native按钮；保存后立即显示本次真正生效的阈值。
        end
        local state = self.RowState(row, self.now); local use = self:Usage(i) -- 中文维护：界面与发色完全共用状态判定，不能另造可用结论。
        local status = state == "empty" and "背包缺药" or state == "unknown" and "库存或CD读取未知" or state == "cooldown" and "冷却中" or "已就绪" -- 中文维护：正常操作先说明不可用原因，而不是要求重新记录。
        if state == "ready" and percent and percent > self:Threshold(i) then status = "血量未到阈值" elseif state == "ready" and self.signalIndex ~= i then status = self.enabled and "就绪 · 等待优先药" or "就绪 · 当前暂停" end -- 中文维护：药品可用和当前应执行是不同事实，血量条件不能被略去。
        if use and use.blockedUntil > self.now then status = (use.cause == "shared" and "关联限制 " or "用药限制 ") .. math.ceil((use.blockedUntil - self.now) / 1000) .. "秒" end -- 中文维护：仅附加规则限时带秒单位，Native原值不擅自换算。
        self:SetObservedText(self.rowDetailLabels[i], (row.sleeping and "上次数量：" or "数量：") .. tostring(row.stock or "未知") .. (row.sleeping and " | 上次CD：" or " | CD原值：") .. tostring(row.remaining or "未知") .. " | " .. status) -- 中文维护：只投影变化的观察文本，休眠药明确使用上次读数，当前可用性仍由RowState决定。
        self:SetObservedText(self.idLabels[i], "物品 ID：" .. tostring(row.itemId or self.FixedItemIds[i]) .. "  | 技能 ID：" .. (row.verified and self.Integer(row.skillId) and tostring(row.skillId) or "未记录")) -- 中文维护：编号同源且不变时不重写Native，另一行校准不影响本行显示。
        self:SetObservedText(self.itemButtons[i], row.name or "选择背包中的药品") -- 中文维护：真实名称变化才写按钮，不重复触发布局。
        local candidate, count = nil, 0 -- 中文维护：按钮只介绍候选，不偷偷完成确认。
        if self.arm and self.arm.index == i then for _, id in ipairs(self.arm.order) do if self.arm.candidates[id].positive then candidate = self.arm.candidates[id]; count = count + 1 end end end -- 中文维护：只列有正CD证据的候选。
        local recording = self.arm and self.arm.index == i -- 中文维护：未记录、正在记录和已提交结果必须独立显示，另一行开始记录不改变本行状态。
        self:SetObservedText(self.candidateButtons[i], recording and (count > 1 and "候选有歧义，请重录" or "记录中 · 验证通过自动保存") or (row.verified and (self.saveError and "已记录 · 保存失败" or "已记录并保存") or "等待手动用药记录")) -- 中文维护：记录/保存状态变化才写按钮，保持未记录、进行中和已验证三个状态边界。
    end -- 中文维护：不重建任何控件。
    local message = self.error and ("初始化/运行错误：" .. self.error) or self.reason or "已暂停" -- 中文维护：故障必须在窗口中可见。
    if self.arm then message = "正在记录" .. self.Specs[self.arm.index].name .. "\n请手动只用该药一次，不要同时放其它技能。\n数量下降：" .. (self.arm.consumed and "是" or "否") .. "；施法成功候选：" .. #self.arm.order .. "个。若没有正CD，不会发色。" end -- 中文维护：三行说明完整可见，不挤成一行。
    if self.armCross then message = "正在记录关联CD：请手动只用" .. self.Specs[self.armCross.used].name .. "一次。\n另一瓶请不要使用；它必须从实际零CD变成实际正CD才能通过。\n记录期间暂停；这项核对是可选功能，不是使用前置步骤。" end -- 中文维护：关联核对不能仅检查是否存在GetCooldown方法。
    if self.saveError then message = message .. "\n" .. self.saveError end -- 中文维护：持久化失败不能被记录成功或运行状态覆盖。
    self:SetObservedText(self.messageLabel, message) -- 中文维护：诊断不变时不重排多行标签，文字没有Ready权限。
    local cross = self.crossEvidence or {} -- 中文维护：只投影当前映射绑定的校准合同，实时CD与就绪始终另行读取。
    self:SetObservedText(self.crossLabel, "图3→图2：限制30秒 · " .. (cross.twoAfterThree and "已实测" or "按规则") .. "\n图2→图3：限制60秒 · " .. (cross.threeAfterTwo and "已实测" or "按规则")) -- 中文维护：固定规则/观察标签不变时零Native写入，不混淆规则秒数与未知单位的Native CD。
    self:SetObservedText(self.titleLabel, "LCot 药品信号 · " .. (self.enabled and "运行中" or "已暂停") .. "（" .. (self.panelScale or 100) .. "%）") -- 中文维护：与缩放入口共用缓存，运行状态或比例变化时才写标题。
end -- 中文维护：停止文字刷新不应推迟撤色。
function P:Update(dt) -- 中文维护：唯一OnUpdate只合并到期读数，不按卡顿时长补发历史采样。
    if self.thresholdEditor then self:ReconcileThresholdEditor() end -- 中文维护：Suite重载时先释放旧模态/输入；常态只读Lua代次，不增加药品或Native采样。
    dt = self.Number(dt) -- 中文维护：无效时间不能让旧颜色继续有效。
    if not dt or dt <= 0 then self:HideSignal(); return end -- 中文维护：未知时钟立即撤色。
    if dt < 1 then dt = dt * 1000 end -- 中文维护：复用本机Scheduler现有RU delta兼容契约；不会据此猜CD返回单位。
    self.now = self.now + dt -- 中文维护：单调时间只由本宿主累加，禁止os.time在游戏沙箱冻结时继续相信旧Ready。
    if dt > 150 then self:HideSignal() end -- 中文维护：长帧先撤销上一轮颜色，然后才允许当轮新读数重新发色。
    if not self.enabled and not self.panelOpen and not self.arm and not self.armCross then self.sampleElapsed, self.textElapsed = 0, 0; return end -- 中文维护：暂停且收起时不轮询血量、背包或CD；单调时钟仍推进用药限制。
    self.sampleElapsed, self.textElapsed = (self.sampleElapsed or 0) + dt, (self.textElapsed or 0) + dt -- 中文维护：采样与可读诊断刷新分开。
    local interval = (self.enabled or self.arm or self.armCross) and 16 or 250 -- 中文维护：战斗与校准保留16ms响应，暂停时仅为可见诊断每250ms取一次数据。
    if self.sampleElapsed >= interval and (not self.enabled or self.arm or self.armCross or not self.nextSampleAt or self.now >= self.nextSampleAt) then self.sampleElapsed = self.sampleElapsed % interval; self:Sample() end -- 中文维护：全药休眠期间跳过整个采样函数，最早到期只合并采样一次，不补跑已过去的帧。
    if self.textElapsed >= 250 then self.textElapsed = self.textElapsed % 250; if self.panelOpen then self:RefreshText() end end -- 中文维护：面板收起时不刷新隐藏文字；真实色块仍由16ms采样更新，重新打开立即读取并投影。
end -- 中文维护：LCot是否按键仅由它自己每次重新识别此时的颜色决定。
for i = 1, 3 do P.rows[i] = { itemId = P.FixedItemIds[i], verified = false, name = P.Specs[i].name } end -- 中文维护：已知药品自动定位，未验证技能不会发色。
P:ApplyPreset(P.DefaultPreset, false) -- 中文维护：发布预设可携带已验证映射，默认空技能不会假装完成实测。
if ADDON and type(ADDON.LoadData) == "function" then -- 中文维护：仅读取原私有键，保留旧存档路径。
    local ok, saved = pcall(ADDON.LoadData, ADDON, "lcot_potion_signal_bindings_v1") -- 中文维护：读取失败不会自动启用或编造映射。
    if ok and type(saved) == "table" and saved.contract == "readonly-potion-v2" then -- 中文维护：新版用精确分享语法恢复证据，与界面导入共用校验。
        local restored, err = P:ApplyPreset(saved.preset, false) -- 中文维护：合法已确认映射在重启后复用，实时CD仍须读取。
        if not restored then P.reason = "已保存预设无效：" .. tostring(err) end -- 中文维护：未知版本或损坏记录不能获得验证状态。
        local scale = tonumber(saved.panelScale); if scale and scale >= 75 and scale <= 125 then P.panelScale = scale end -- 中文维护：缩放偏好字符串恢复并有界，不影响信号色块几何。
    elseif ok and type(saved) == "table" and saved.contract == "readonly-potion-v1" and type(saved.rows) == "table" then -- 中文维护：旧版只有BindCandidate成功才保存skillId，因此固定物品的非空合法技能可迁移。
        for i = 1, 3 do local row = saved.rows[i] or saved.rows[tostring(i)]; if type(row) == "table" and P.Integer(row.itemId) == P.FixedItemIds[i] then local skill = P.Integer(row.skillId); P.rows[i].skillId, P.rows[i].verified = skill, skill ~= nil end end -- 中文维护：未确认的空技能不迁移成已记录，槽位重新定位。
    end -- 中文维护：不清空不可识别的旧值。
    if ok and type(saved) == "table" and saved.thresholds ~= nil then local restored, err = P:ApplyThresholds(saved.thresholds, false); if not restored then P.reason = "保存的血量阈值无效：" .. tostring(err) end end -- 中文维护：阈值复用同一次原私有键读取，三项完整校验后恢复；旧存档缺字段仍默认88/62/62，启动绝不启用。
end -- 中文维护：重启只恢复配置和验证合同，启用状态仍默认暂停。
local builtinRows = P:ParsePreset(P.DefaultPreset) -- 中文维护：旧测试存档可能有尚未记录的0占位，不能覆盖本次已实测内置映射。
if builtinRows then for i = 1, 3 do local row, builtin = P.rows[i], builtinRows[i]; if not row.verified and row.itemId == builtin.itemId and builtin.verified then row.skillId, row.verified = builtin.skillId, true end end end -- 中文维护：仅补未确认项，保留用户已有不同的合法映射与关联边界，不继承任何实时Ready。
P:RestoreUsage() -- 中文维护：内置与本机映射恢复后再传递同会话限制，冷启动不恢复Ready或自动启用。
P:LocateItems() -- 中文维护：冷启动从当前背包按三个固定ID找药，其他用户无需填写物品编号。
local built, buildError = pcall(P.BuildPanel, P) -- 中文维护：原生UI构造失败同样不能留下可用颜色。
if not built then P.error = tostring(buildError); P:Shutdown(); return end -- 中文维护：失败释放本代次窗口，拒绝假称可用。
P.driver:SetHandler("OnUpdate", P:Guard(function(_, dt) P:Update(dt) end)) -- 中文维护：只挂自己的调度宿主，不改公共UIParent回调。
P.driver:SetHandler("OnEvent", P:Guard(function(_, event, ...) -- 中文维护：实际Native回调先带widget和event，不能吞掉owner导致payload错位。
    if event == "COMBAT_MSG" then P:OnCombat(...) -- 中文维护：仅私有自端事件用于明确手动记录及用药撤色。
    elseif event == "BAG_UPDATE" then P.bagDirty = true; P.nextSampleAt = nil; for _, row in ipairs(P.rows) do row.emptyConfirmed = false; row.cooldownRetryAt, row.observationRetryAt = nil, nil end; P:HideSignal() -- 中文维护：事件立即撤色并失效缺货/失败退避，下一轮重新核对，既有用药限制仍保留。
    elseif event == "ENTERED_WORLD" then P.arm = nil; P.armCross = nil; P.nextSampleAt = nil; P.bagDirty = true; P:ClearStockChanges(); for _, row in ipairs(P.rows) do row.cooldownRetryAt, row.observationRetryAt, row.emptyConfirmed, row.at, row.remaining, row.stock = nil, nil, false, nil, nil, nil end; P:Disable("进入/切换世界：请核对配置后重新启用") end -- 中文维护：切换世界同时丢弃未确认的旧数量变化，保留已确认用药限制，不能把旧候选绑定到新世界或自动恢复信号。
end)) -- 中文维护：处理器代次受Guard保护，重载旧事件不能复活颜色。
for _, event in ipairs({ "COMBAT_MSG", "ENTERED_WORLD" }) do -- 中文维护：已在本机运行代码使用的事件，不试探未知事件。
    local ok, result = pcall(P.driver.RegisterEvent, P.driver, event) -- 中文维护：注册失败是Unknown，需要显示失败并保持暂停。
    if not ok or result == false then P.error = "事件注册失败：" .. event; P:Disable(P.error) end -- 中文维护：不能把没有事件记录能力的插件标成可校准。
end -- 中文维护：不注册公共全局覆盖处理器。
pcall(P.driver.RegisterEvent, P.driver, "BAG_UPDATE") -- 中文维护：参考RU事件表与实际Omnicraft消费使用的可选通知，只作缓存失效加速；注册缺失仍有两秒只读扫描，不升级任何读取能力。
P:Sample() -- 中文维护：首次打开立即显示实际血量与库存，不能让内置ID旁一直停留未知占位。
P:RefreshText() -- 中文维护：首次加载就给用户明确入口与当前状态。
if P:RegisterEscMenu() then P:CollapsePanel() end -- 中文维护：原生菜单注册成功后默认收起设置；进入世界时仍默认暂停，用户从Esc入口启用。
