-- 中文维护：固定物品身份来自本机实际选药存档；技能编号只能由数量下降和唯一正CD验证产生，绝不猜测。
local P = LCotPotionSignal -- 中文维护：预设归属独立插件，不读取Suite配置或其它用户角色数据。
P.FixedItemIds = { 42043, 42045, 54386 } -- 中文维护：依次是速效、强效、远征队员的勇气；背包格和名称不参与共享身份。
P.DefaultPreset = "LCP2;42043:38429;42045:38431;54386:50855;0" -- 中文维护：2026-10-04用户实测截图与本机存档一致确认三种自有CD映射；末尾0保留关联冷却未验证边界，不伪造双向证据。
function P:ExportPreset() -- 中文维护：共享内容仅含三个固定物品与已确认技能映射，不包含账号、背包格、Ready缓存或热键。
    local parts = { "LCP2" } -- 中文维护：固定语法版本防止未来字段变化被旧解析器误读。
    for i = 1, 3 do -- 中文维护：导出顺序固定，稀疏配置不会导致药品错位。
        local row = self.rows[i] or {} -- 中文维护：未配置行仍有明确的固定物品身份。
        local skill = row.verified and row.itemId == self.FixedItemIds[i] and self.Integer(row.skillId) or nil -- 中文维护：只有已通过实测校准的映射才可分享。
        parts[#parts + 1] = tostring(self.FixedItemIds[i]) .. ":" .. tostring(skill or 0) -- 中文维护：未确认技能用0占位，禁止把现场候选升级为预设。
    end -- 中文维护：不导出原始Native事件或对象。
    local cross = self.crossEvidence or {} -- 中文维护：关联证据必须与当前图2/图3已确认映射同时成立。
    parts[#parts + 1] = (cross.twoAfterThree and cross.threeAfterTwo and self.rows[2].verified and self.rows[3].verified) and "1" or "0" -- 中文维护：共享的是已核对合同，实际每轮CD仍必须来自游戏。
    return table.concat(parts, ";") -- 中文维护：纯数据字符串不执行Lua，无loadstring或任意字段注入。
end -- 中文维护：本机存档与分享界面使用同一份验证结果。
function P:FormatIdInfo() -- 中文维护：供人工实测后回传的说明只投影固定物品与已提交技能，现场候选没有静态预设资格。
    local lines = {} -- 中文维护：固定四行文字，不携带角色名、账号、背包位置或其它存档。
    for i = 1, 3 do -- 中文维护：三种药按图1/图2/图3顺序排列，便于人工对应截图核对。
        local row = self.rows[i] or {} -- 中文维护：缺配置也明确显示，不跳行造成编号错位。
        local skill = row.verified and self.Integer(row.skillId) or nil -- 中文维护：仅已确认的唯一正CD技能进入可复制的信息；暂存候选显示未记录。
        lines[i] = self.Specs[i].name .. "：物品 ID " .. tostring(row.itemId or self.FixedItemIds[i]) .. "，技能 ID " .. (skill and tostring(skill) or "未记录") .. (skill and "（已验证）" or "（待验证）") -- 中文维护：物品类型与冷却技能是不同编号，未来内置时必须同时保留正确对应关系。
    end -- 中文维护：说明文字不改变记录或Ready状态。
    local cross = self.crossEvidence or {} -- 中文维护：静态映射还需标明关联冷却是否完成，不能把自有CD当共享CD证明。
    lines[4] = "关联冷却：图3→图2 " .. (cross.twoAfterThree and "已验证" or "待验证") .. "；图2→图3 " .. (cross.threeAfterTwo and "已验证" or "待验证") -- 中文维护：两个方向分别展示，完整双向证据才会进入下方复制码。
    return table.concat(lines, "\n") -- 中文维护：界面显示说明，下方原有LCP2复制码携带同一份固定映射供直接回传。
end -- 中文维护：不把实时CD倒计时静态写入分发预设。
function P:ParsePreset(code) -- 中文维护：先完整校验再提交，损坏导入不能清掉已记录药品。
    if type(code) ~= "string" or #code > 160 then return nil, "预设格式无效或过长" end -- 中文维护：有界解析，不读取文件或联网。
    code = code:match("^%s*(.-)%s*$") -- 中文维护：仅去除复制时首尾空白，不接受任意语法。
    local a, x, b, y, c, z, linked = code:match("^LCP2;(%d+):(%d+);(%d+):(%d+);(%d+):(%d+);([01])$") -- 中文维护：精确字段数量与分隔符，尾部代码无法被接收。
    if not a then return nil, "请粘贴完整的LCP2药品预设" end -- 中文维护：不能把无版本旧文本当已验证配置。
    local items, skills, rows, seen = { a, b, c }, { x, y, z }, {}, {} -- 中文维护：临时表与正式状态分离，失败不半提交。
    for i = 1, 3 do -- 中文维护：每行同时核对固定物品与合法技能形状。
        local item, skill = self.Integer(items[i]), self.Integer(skills[i]) -- 中文维护：编号边界统一由纯层校验，0单独代表未记录。
        if item ~= self.FixedItemIds[i] or (not skill and skills[i] ~= "0") or (skill and seen[skill]) then return nil, "预设药品不符、技能无效或重复" end -- 中文维护：不允许三种药绑定同一候选技能制造假Ready。
        if skill then seen[skill] = true end -- 中文维护：三种药自有技能应分别确认，禁止重复映射。
        rows[i] = { itemId = item, skillId = skill, verified = skill ~= nil, name = self.Specs[i].name } -- 中文维护：不导入别人的背包位置或运行时就绪读数。
    end -- 中文维护：未记录行可继续本机实测。
    if linked == "1" and (not rows[2].verified or not rows[3].verified) then return nil, "关联冷却预设缺少图2/图3的已验证技能" end -- 中文维护：单独的关联标志没有信任权。
    return rows, linked == "1" -- 中文维护：只有完整成功才交由调用方替换配置。
end -- 中文维护：共享预设来自用户确认的同服实测，游戏读取失败仍保持撤色。
function P:ApplyPreset(code, persist) -- 中文维护：显式导入或启动恢复可复用已验证映射，但永不自动启用信号。
    local rows, linked = self:ParsePreset(code) -- 中文维护：业务状态变更前完成全部校验。
    if not rows then return false, linked end -- 中文维护：错误字符串返回给界面，不破坏原来的三行。
    self:Disable("预设已载入，请核对库存后启用") -- 中文维护：导入过程中先撤掉旧颜色，禁止新旧身份交叉。
    self.rows, self.arm, self.armCross = rows, nil, nil -- 中文维护：现场记录会话不能跨导入继承。
    self.crossEvidence = linked and { twoAfterThree = true, threeAfterTwo = true } or {} -- 中文维护：共享合同有明确绑定的图2/图3技能身份。
    self.rows[2].crossVerified, self.rows[3].crossVerified = linked, linked -- 中文维护：关联标签仅保留实际观察证据，不作为内置药品的强制启用步骤。
    if self.LocateItems then self:LocateItems() end -- 中文维护：本机重新定位固定物品，不信任分享者的槽位。
    if persist then self:SaveBindings() end -- 中文维护：用户显式导入后保存，冷启动读取不无故覆盖旧存档。
    return true -- 中文维护：载入成功仅证明配置有效，不代表游戏API返回就绪。
end -- 中文维护：无输入API或后台自动操作。
