------------------------------------------------------------------------
-- 今日总览提醒事实（2026-10-04）：只读自身时装/内衣与 Achievement 每日、公会任务。
-- Native 返回形状和 1..7 板位来自用户已工作的 1.2 Character service；不猜装备槽号、
-- 期限或任务状态。成功读取且具备物品身份、没有倒计时的装备按 1.2 契约显示永久；
-- 读取失败、无身份或倒计时畸形仍待确认，六项全零才判到期。
-- 只由 Core Demand 驱动：首个可见租约读一次，事件合并 + 30 秒低频校验；末租约停止
-- Scheduler/RefreshCoordinator/Events，并撤销旧闭包。无 Store、无 UI、无后台常驻扫描。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}
local C = { Id = 'v3.home_reminders', version = 2, patch = 'home-reminders-permanent-2',
    -- 只提供提醒事实与租约生命周期，界面由首页负责；漏声明会被 Foundation Gate 判为阻断。
    presentationBoundary = 'service_only',
    taskName = 'v3_home_reminders_refresh', intervalMs = 30000, revision = 0,
    nativeReads = 0, readFailures = 0, taskGeneration = 0, running = false }
S.Services.HomeRemindersV3 = C
local DEFINITIONS = { { 'costume', '时装' }, { 'underwear', '内衣' }, { 'daily', '每日任务' }, { 'guild', '公会任务' } }
local TIME_FIELDS = { 'year', 'month', 'day', 'hour', 'minute', 'second' }
local function Copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}; for k, x in pairs(v) do out[k] = Copy(x) end; return out
end
local function Bound(v)
    local text = tostring(v or '')
    if #text <= 160 then return text end
    local cut = 160
    while cut > 0 and (string.byte(text, cut) or 0) >= 0x80 and (string.byte(text, cut) or 0) < 0xC0 do cut = cut - 1 end
    local lead = string.byte(text, cut) or 0
    local width = lead >= 0xF0 and 4 or lead >= 0xE0 and 3 or lead >= 0xC0 and 2 or 1
    return string.sub(text, 1, cut + width - 1 <= 160 and 160 or cut - 1)
end
local function Unknown(key, name, reason, text)
    return { key = key, name = name, status = 'unknown', text = text or '待确认', tone = 'muted', available = false, error = Bound(reason) }
end
local function EmptyRows()
    local rows = {}; for _, d in ipairs(DEFINITIONS) do rows[#rows + 1] = Unknown(d[1], d[2], 'not_observed') end; return rows
end
C.rows = EmptyRows()
local function Number(v)
    v = tonumber(v)
    if v == nil or v ~= v or v < 0 or v == math.huge or v > 1000000000 or math.floor(v) ~= v then return nil end
    return v
end
function C:_Equipment(key, name, primary)
    if self.dependencies and self.dependencies.equipment.available ~= true then return Unknown(key, name, self.dependencies.equipment.error) end
    -- EST_* 是装备类型，不能拿来代替 ES_* 的实际装备槽号；缺 ES_* 保持待确认。
    local slot = rawget(_G, primary)
    local gear = S.Services.GearV3
    if slot == nil then return Unknown(key, name, 'equipment_slot_unavailable') end
    if not gear or type(gear.GetEquipped) ~= 'function' then return Unknown(key, name, 'gear_read_boundary_unavailable') end
    self.nativeReads = self.nativeReads + 1
    local called, info, err = pcall(gear.GetEquipped, gear, slot)
    if not called or err ~= nil then self.readFailures = self.readFailures + 1; return Unknown(key, name, called and err or info) end
    if info == nil or type(info) == 'table' and next(info) == nil then
        return { key = key, name = name, status = 'empty', text = '未装备', tone = 'muted', available = true, slot = slot }
    end
    if type(info) ~= 'table' then return Unknown(key, name, 'invalid_equipment_shape') end
    local row = Unknown(key, name, 'expiration_unavailable', '期限待确认')
    row.slot, row.selector, row.itemType, row.itemName = slot, false, tonumber(info.itemType), Bound(info.name)
    local evolving = info.evolvingInfo
    local remain
    if type(evolving) == 'table' then remain = evolving.remainTime end
    row.expirationEvidence = { equipmentRead = 'success', evolvingKind = type(evolving), countdownKind = type(remain),
        source = 'GetEquippedItemTooltipInfo:false' }
    -- 1.2 Character.Remaining 的永久契约与用户实际永久时装一致；仅在成功读到
    -- 可识别装备且字段确实缺席时使用。false/字符串/残缺时间表不是“无倒计时”。
    local itemType = Number(info.itemType)
    local identified = itemType ~= nil and itemType > 0
        or type(info.name) == 'string' and info.name:find('%S') ~= nil
    row.expirationEvidence.identified = identified
    if remain == nil and (evolving == nil or type(evolving) == 'table') and identified then
        row.status, row.text, row.tone, row.available, row.error = 'permanent', '永久', 'green', true, nil
        row.expirationEvidence.policy = 'identified_item_without_countdown'
        return row
    end
    if type(remain) ~= 'table' then return row end
    row.expirationEvidence.policy = 'six_field_countdown'
    for _, field in ipairs(TIME_FIELDS) do
        row.expirationEvidence[field] = { present = remain[field] ~= nil, kind = type(remain[field]), value = Bound(remain[field]) }
    end
    local time, allZero = {}, true
    for _, field in ipairs(TIME_FIELDS) do
        local value = Number(remain[field])
        if value == nil then row.error = 'expiration_field_unavailable:' .. field; return row end
        time[field] = value; if value > 0 then allZero = false end
    end
    row.remaining, row.available, row.error = time, true, nil
    if allZero then row.status, row.text, row.tone = 'expired', '已到期', 'red'; return row end
    local parts, units = {}, { '年', '月', '天', '小时', '分', '秒' }
    for i, field in ipairs(TIME_FIELDS) do if time[field] > 0 and #parts < 2 then parts[#parts + 1] = tostring(time[field]) .. units[i] end end
    local near = time.year == 0 and time.month == 0 and (time.day * 86400 + time.hour * 3600 + time.minute * 60 + time.second) <= 86400
    row.status, row.text, row.tone = near and 'expiring' or 'valid', '剩余 ' .. table.concat(parts, ' '), near and 'orange' or 'green'
    return row
end
function C:_Assignments(key, name, kind)
    if self.dependencies and self.dependencies.assignments.available ~= true then return Unknown(key, name, self.dependencies.assignments.error) end
    if kind == nil then return Unknown(key, name, 'assignment_kind_unavailable') end
    if not S.Api or type(S.Api.CallCapability) ~= 'function' then return Unknown(key, name, 'api_unavailable') end
    local row = { key = key, name = name, pending = 0, active = 0, completed = 0, unknown = 0, total = 0, samples = {} }
    for index = 1, 7 do
        self.nativeReads = self.nativeReads + 1
        local ok, info, err = S.Api:CallCapability('X2Achievement:GetTodayAssignmentInfo', rawget(_G, 'X2Achievement'), 'GetTodayAssignmentInfo', kind, index)
        local status = ok == true and type(info) == 'table' and tonumber(info.status) or nil
        local known = status == 1 or status == 2 or status == 3
        row.samples[index] = { index = index, available = known, status = status, error = not known and Bound(err or 'assignment_status_unavailable') or nil }
        if known then
            row.total = row.total + 1
            if status == 1 then row.pending = row.pending + 1 elseif status == 2 then row.active = row.active + 1 else row.completed = row.completed + 1 end
        else
            row.unknown = row.unknown + 1; self.readFailures = self.readFailures + 1
        end
    end
    row.accepted = row.active + row.completed
    row.available = row.unknown == 0
    if row.total == 0 then row.status, row.text, row.tone = 'unknown', '待确认', 'muted'
    elseif row.unknown > 0 then
        row.status, row.tone = 'partial', 'orange'
        row.text = (row.pending > 0 and ('还有 ' .. row.pending .. '项未接') or ('已接 ' .. row.accepted .. '项')) .. ' · 待确认'
    elseif row.pending > 0 then row.status, row.text, row.tone = 'pending', '还有 ' .. row.pending .. '项未接', 'orange'
    elseif row.completed == row.total then row.status, row.text, row.tone = 'completed', '已完成 ' .. row.completed .. '/' .. row.total, 'green'
    else row.status, row.text, row.tone = 'accepted', '已接 ' .. row.accepted .. '/' .. row.total, 'green' end
    return row
end
function C:Refresh(reason)
    if not self.running or not self.Demand or self.Demand.count <= 0 then return false, 'reminder_view_hidden' end
    if self.refreshing then return true end
    self.refreshing = true
    local ok, err = xpcall(function()
        self.rows = {
            self:_Equipment('costume', '时装', 'ES_COSPLAY'),
            self:_Equipment('underwear', '内衣', 'ES_UNDERPANTS'),
            self:_Assignments('daily', '每日任务', rawget(_G, 'TADT_TODAY')),
            self:_Assignments('guild', '公会任务', rawget(_G, 'TADT_EXPEDITION')),
        }
        self.revision = self.revision + 1
        self.lastReason, self.observedAtMs = Bound(reason), S.NowMs and S.NowMs() or 0
        self.error = nil
    end, S.SafeTraceback or tostring)
    self.refreshing = false
    if not ok then self.rows = EmptyRows(); self.error = Bound(err) end
    if S.Events then S.Events:Publish('v3.home.reminders.updated', self.revision) end
    return ok, err
end
function C:RequestRefresh(reason)
    if not self.running then return true end
    if not S.RefreshCoordinator then return true end -- 低频校验仍在；不在事件路径回退成即时扫描。
    local epoch, generation = self.taskGeneration, S.Generation
    return S.RefreshCoordinator:Request({ key = 'home_reminders', owner = self, moduleId = 'life_daily_stats',
        delayMs = 300, maxWaitMs = 1000, reason = reason, priority = 'P3', cost = 1,
        callback = function()
            if C.taskGeneration ~= epoch or S.Generation ~= generation or S.Services.HomeRemindersV3 ~= C or not C.running then return true end
            return C:Refresh('event')
        end })
end
function C:_Stop()
    self.taskGeneration = self.taskGeneration + 1; self.running = false
    if S.Scheduler then S.Scheduler:RemoveTask(self.taskName) end
    if S.RefreshCoordinator then S.RefreshCoordinator:CancelOwner(self) end
    if S.Events then S.Events:UnsubscribeOwner(self) end
    self.rows, self.observedAtMs = EmptyRows(), nil
    return true
end
function C:_Start()
    if not S.Scheduler then return false, 'reminder_scheduler_unavailable' end
    -- 中文维护：不能假设其他模块/插件已经导入 X2Achievement 或装备常量。
    -- 本服务在 0->1 Demand 边界通过唯一 NativeImports 领取两个可选依赖；逐项记录失败，
    -- 成就失败只使每日/公会提醒待确认，不阻断装备提醒或今日账本。
    self.dependencies = {}
    for _, definition in ipairs({{'equipment','X2Equipment:GetEquippedItemTooltipInfo'},{'assignments','X2Achievement:GetTodayAssignmentInfo'}}) do
        local ok, err = false, 'native_import_boundary_unavailable'
        if S.NativeImports and type(S.NativeImports.AcquireApi) == 'function' then
            -- IsCapabilityAllowed 同时检查 namespace 是否已存在，不能在导入前用它拦截
            -- cold start。先核对官方许可，再导入，再经同一能力门检查实际 getter。
            local capability = S.ApiCapabilities and S.ApiCapabilities:Get(definition[2])
            if capability and capability.OfficialState == 'OfficialEnabled' then
                ok, err = S.NativeImports:AcquireApi(self.Id, definition[2], false)
                if ok == true then ok, err = S.Api:IsCapabilityAllowed(definition[2]) end
            else err = 'capability_not_allowed:' .. definition[2] end
        end
        self.dependencies[definition[1]] = { available = ok == true, error = ok ~= true and Bound(err) or nil, capability = definition[2] }
    end
    self.taskGeneration = self.taskGeneration + 1; self.running = true
    local epoch, generation = self.taskGeneration, S.Generation
    local ok = S.Scheduler:AddTask(self.taskName, self.intervalMs, function()
        if C.taskGeneration ~= epoch or S.Generation ~= generation or S.Services.HomeRemindersV3 ~= C then return true end
        return C:Refresh('scheduled')
    end, false, self, 'P3', 1)
    if ok ~= true then self:_Stop(); return false, 'reminder_task_unavailable' end
    if S.Scheduler.SetTaskModule then S.Scheduler:SetTaskModule(self.taskName, 'life_daily_stats', false) end
    if S.Events then
        S.Events:BindOwner(self, 'life_daily_stats')
        for _, event in ipairs({ 'UNIT_EQUIPMENT_CHANGED', 'ACHIEVEMENT_UPDATE', 'COMPLETE_ACHIEVEMENT', 'ENTERED_WORLD' }) do
            local eventName = event
            S.Events:SubscribeOptional(eventName, self, function() return C:RequestRefresh(eventName) end)
        end
    end
    return self:Refresh('visible')
end
local demand, demandErr = S.Demand:Create({ id = C.Id, owner = C, projectionOwner = C,
    projectionConsumersField = 'consumers', projectionCountField = 'consumerCount',
    reconcile = function(_, before, after)
        if after.count <= 0 then return C:_Stop() end
        if before.count <= 0 then return C:_Start() end
        return true
    end, quiesce = function() return C:_Stop() end })
if demand == nil then error(demandErr) end
C.Demand = demand
function C:AcquireConsumer(token) return self.Demand:Acquire(token, {}, 'reminder_visible') end
function C:ReleaseConsumer(token) return self.Demand:Release(token, 'reminder_hidden') end
function C:GetProjection() return { revision = self.revision, rows = Copy(self.rows), observedAtMs = self.observedAtMs, error = self.error } end
function C:GetHealth()
    return { patch = self.patch, presentationBoundary = self.presentationBoundary, running = self.running, consumers = self.consumerCount or 0,
        nativeReads = self.nativeReads, readFailures = self.readFailures, revision = self.revision,
        intervalMs = self.running and self.intervalMs or nil, observedAtMs = self.observedAtMs,
        reason = self.lastReason, error = self.error, dependencies = Copy(self.dependencies), rows = Copy(self.rows) }
end
