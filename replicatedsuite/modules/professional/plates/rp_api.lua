ReplicatedSuiteModuleSandbox:Enter('plates', {'ReplicatedPlates'})
------------------------------------------------------------------------
-- Replicated Plates - API boundary
-- All direct X2Unit/X2Skill/persistence access stays here.
------------------------------------------------------------------------
if ReplicatedPlates == nil or ReplicatedPlates.BootError ~= nil then return end
local P = ReplicatedPlates
P.Api = {}
local A = P.Api
local PlatesData = ReplicatedSuite and ReplicatedSuite.GameIds and ReplicatedSuite.GameIds.Plates or nil

local function SafeInvoke(object, methodName, ...)
    if object == nil then return false, nil, "object unavailable" end
    local method = object[methodName]
    if type(method) ~= "function" then return false, nil, tostring(methodName) .. " unavailable" end
    local args = { ... }
    local argCount = select("#", ...)
    local ok, value1, value2, value3 = pcall(function() return method(object, unpack(args, 1, argCount)) end)
    if not ok then return false, nil, tostring(value1) end
    return true, value1, value2, value3
end

function A:Validate()
    local required = {
        { X2Unit, "GetUnitScreenPosition", "X2Unit:GetUnitScreenPosition" },
        { X2Unit, "UnitName", "X2Unit:UnitName" },
        { X2Unit, "UnitHealth", "X2Unit:UnitHealth" },
        { X2Unit, "UnitMaxHealth", "X2Unit:UnitMaxHealth" },
    }
    for _, item in ipairs(required) do
        if item[1] == nil or type(item[1][item[2]]) ~= "function" then return false, item[3] .. " unavailable" end
    end
    if ADDON == nil or type(ADDON.LoadData) ~= "function" or type(ADDON.SaveData) ~= "function" then
        return false, "ADDON persistence API unavailable"
    end
    return true
end


function A:RegisterContentWidget(contentId, widget)
    local ok, value, err = SafeInvoke(ADDON, "RegisterContentWidget", contentId, widget)
    if not ok then return false, err end
    if value == false then return false, "RegisterContentWidget returned false" end
    return true, value
end

function A:RegisterContentTrigger(contentId, callback)
    local ok, value, err = SafeInvoke(ADDON, "RegisterContentTriggerFunc", contentId, callback)
    if not ok then return false, err end
    if value == false then return false, "RegisterContentTriggerFunc returned false" end
    return true, value
end

function A:GetUnitScreenPosition(unit)
    local ok, x, y, z = SafeInvoke(X2Unit, "GetUnitScreenPosition", unit)
    if not ok then return nil, nil, nil end
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if x == nil or y == nil or z == nil then return nil, nil, nil end
    return x, y, z
end

-- Magic-circle (report 八-P1-1): find the first player buff whose id is in
-- `ids` ({number} array; converted to a set internally). Mirrors the
-- GetEffects buff scan: count then per-index UnitBuff rows, accepting the
-- same buff_id key aliases RU builds have moved between. Returns
-- `buffId, info` on hit, `nil` otherwise.
function A:FindPlayerBuff(ids)
    if type(ids) ~= "table" then return nil end
    local wanted = {}
    for _, id in ipairs(ids) do wanted[id] = true end
    if X2Unit == nil or type(X2Unit.UnitBuffCount) ~= "function" or type(X2Unit.UnitBuff) ~= "function" then return nil end
    local okCount, rawCount = SafeInvoke(X2Unit, "UnitBuffCount", "player")
    if not okCount then return nil end
    local count = math.max(0, math.floor(tonumber(rawCount) or 0))
    for index = 1, count do
        local okData, extra = SafeInvoke(X2Unit, "UnitBuff", "player", index)
        if okData and type(extra) == "table" then
            local rawId = extra.buff_id or extra.buffId or extra.buffID or extra.id
            local id = rawId ~= nil and tonumber(rawId) or nil
            if id ~= nil and wanted[id] then
                return id, extra
            end
        end
    end
    return nil
end

-- Magic-circle: read a unit's position (x, y, z) via the registered getter with
-- a soft triple-tonumber guard. Returns nil on any failure.
-- isLocal: false (default) = world coordinates (verified magic-circle / D-2
-- UnitScreenPoint pipeline); true = the coordinate space ConvertWorldToScreen
-- expects (verified easypull pipeline, G1). Existing callers pass nothing and
-- keep world coordinates untouched.
function A:UnitWorldPosition(unit, isLocal)
    local ok, x, y, z = SafeInvoke(X2Unit, "GetUnitWorldPositionByTarget", unit, isLocal == true)
    if not ok then return nil, nil, nil end
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if x == nil or y == nil or z == nil then return nil, nil, nil end
    return x, y, z
end

-- Shared world->screen projection. Resolution order (G1/G1b):
--   1. native global ConvertWorldToScreen when present (RU may omit it);
--   2. camera-based manual projection (absorbed from the community
--      globals/WorldToScreen.lua that easypull depends on — UIParent camera
--      getters + FOV math; NOT a game API, forward<=0 culls camera-behind).
-- The legacy global WorldToScreen is deliberately NOT referenced: it only
-- exists inside easypull's own globals folder and is absent from Suite.
-- Returns sx, sy, depth or nil, nil, nil.
function A:ProjectWorldToScreen(wx, wy, wz)
    wx, wy, wz = tonumber(wx), tonumber(wy), tonumber(wz)
    if wx == nil or wy == nil or wz == nil then return nil, nil, nil end
    -- 1) native global when available
    if type(ConvertWorldToScreen) == "function" then
        local okC, sx, sy, depth = pcall(ConvertWorldToScreen, wx, wy, wz)
        if okC then
            sx, sy = tonumber(sx), tonumber(sy)
            local d = tonumber(depth)
            if sx ~= nil and sy ~= nil and d ~= nil then return sx, sy, d end
            if sx ~= nil and sy ~= nil then return sx, sy, depth end
        end
    end
    -- 2) camera-based manual projection (absorbed WorldToScreen.lua logic)
    if UIParent ~= nil and type(UIParent.GetViewCameraPos) == "function"
        and type(UIParent.GetViewCameraDir) == "function" then
        local okP, camPos = pcall(function() return UIParent:GetViewCameraPos() end)
        local okD, camDir = pcall(function() return UIParent:GetViewCameraDir() end)
        if okP and okD and type(camPos) == "table" and type(camDir) == "table"
            and camPos.x ~= nil and camPos.y ~= nil and camPos.z ~= nil
            and camDir.x ~= nil and camDir.y ~= nil and camDir.z ~= nil then
            local dx, dy, dz = wx - camPos.x, wy - camPos.y, wz - camPos.z
            local distance = math.sqrt((dx * dx) + (dy * dy) + (dz * dz))
            if distance >= 0.1 then
                local forward = (dx * camDir.x) + (dy * camDir.y) + (dz * camDir.z)
                if forward > 0.001 then
                    local screenW = tonumber(UIParent.GetScreenWidth and UIParent:GetScreenWidth() or nil)
                        or (UI ~= nil and tonumber(UI.GetScreenWidth and UI:GetScreenWidth() or nil)) or nil
                    local screenH = tonumber(UIParent.GetScreenHeight and UIParent:GetScreenHeight() or nil)
                        or (UI ~= nil and tonumber(UI.GetScreenHeight and UI:GetScreenHeight() or nil)) or nil
                    if screenW ~= nil and screenH ~= nil and screenW > 0 and screenH > 0 then
                        local fov = 1.57
                        if type(UIParent.GetViewCameraFov) == "function" then
                            local okF, fovV = pcall(function() return UIParent:GetViewCameraFov() end)
                            if okF and tonumber(fovV) ~= nil then fov = tonumber(fovV) end
                        end
                        local worldUp = { x = 0, y = 0, z = 1 }
                        local rX = (camDir.y * worldUp.z) - (camDir.z * worldUp.y)
                        local rY = (camDir.z * worldUp.x) - (camDir.x * worldUp.z)
                        local rZ = (camDir.x * worldUp.y) - (camDir.y * worldUp.x)
                        local rLen = math.sqrt((rX * rX) + (rY * rY) + (rZ * rZ))
                        if rLen >= 0.001 then
                            rX, rY, rZ = rX / rLen, rY / rLen, rZ / rLen
                            local uX = (rY * camDir.z) - (rZ * camDir.y)
                            local uY = (rZ * camDir.x) - (rX * camDir.z)
                            local uZ = (rX * camDir.y) - (rY * camDir.x)
                            local rComp = (dx * rX) + (dy * rY) + (dz * rZ)
                            local uComp = (dx * uX) + (dy * uY) + (dz * uZ)
                            local focal = 1 / math.tan(fov / 2)
                            local sX = (screenW / 2) + ((rComp / forward) * focal * (screenH / 2))
                            local sY = (screenH / 2) - ((uComp / forward) * focal * (screenH / 2))
                            return sX, sY, distance -- distance as depth (forward>0 already culls behind)
                        end
                    end
                end
            end
        end
    end
    return nil, nil, nil
end

function A:UnitScreenPoint(unit)
    -- Fast path: native screen read (current behaviour).
    local x, y, z = self:GetUnitScreenPosition(unit)
    if x ~= nil and y ~= nil and z ~= nil and z > 0 then
        return x, y, z, "native"
    end
    -- Projection fallback for the transient-nil windows while the client
    -- rebuilds native nameplates. Soft: any failure returns nil and the
    -- caller keeps its existing failure-counter behaviour. Opt-out default:
    -- missing/unknown config means ON; only explicit false disables it.
    local storage = P.Storage
    local cfg = storage ~= nil and type(storage.Get) == "function" and storage:Get() or nil
    if cfg ~= nil and cfg.positionProjection == false then return nil, nil, nil end
    local wx, wy, wz = self:UnitWorldPosition(unit)
    if wx == nil or wy == nil or wz == nil then return nil, nil, nil end
    local sx, sy, depth = self:ProjectWorldToScreen(wx, wy, wz + 1)
    if sx == nil or sy == nil then return nil, nil, nil end
    return sx, sy, (tonumber(depth) and depth > 0) and depth or 1, "projected"
end

function A:UnitBuffCount(unit)
    local ok, count = SafeInvoke(X2Unit, "UnitBuffCount", unit)
    if not ok then return nil end
    return tonumber(count)
end


local function SharedUnitRead(field, unit, ttlMs, fetchFn)
    if ReplicatedSuiteEmbedded == true and ReplicatedSuite ~= nil and ReplicatedSuite.Observation ~= nil then
        return ReplicatedSuite.Observation:ReadField("professional:plates", unit, field, fetchFn, ttlMs)
    end
    return fetchFn()
end

-- Target Detection Authority bridge. When the Suite's unified Target Service has
-- already resolved the current target, Plates consumes that shared state instead
-- of re-issuing the same X2Unit read (single authority, no duplicate scan).
-- Player scope and any missing/stale field fall through to the proven direct
-- read, so the HUD never regresses if the service is unavailable or unstarted.
local function TargetServiceState(unit)
    if unit ~= "target" then return nil end
    if ReplicatedSuiteEmbedded ~= true or ReplicatedSuite == nil or ReplicatedSuite.TargetService == nil then return nil end
    local T = ReplicatedSuite.TargetService
    if T.started ~= true or type(T.state) ~= "table" or T.state.hasTarget ~= true
        or T.state.validity ~= "valid" then
        return nil
    end
    return T.state
end

function A:GetUnitName(unit)
    local ts = TargetServiceState(unit)
    if ts ~= nil and type(ts.name) == "string" and ts.name ~= "" then return ts.name end
    return SharedUnitRead("UnitName", unit, 250, function()
        local ok, value = SafeInvoke(X2Unit, "UnitName", unit)
        if not ok or value == nil then return nil end
        local text = tostring(value)
        return text ~= "" and text or nil
    end)
end

function A:GetUnitId(unit)
    local ts = TargetServiceState(unit)
    if ts ~= nil and type(ts.unitId) == "string" and ts.unitId ~= "" then return ts.unitId end
    if X2Unit == nil or type(X2Unit.GetUnitId) ~= "function" then return nil end
    return SharedUnitRead("GetUnitId", unit, 75, function()
        local ok, value = SafeInvoke(X2Unit, "GetUnitId", unit)
        if not ok or value == nil then return nil end
        local text = tostring(value)
        return text ~= "" and text or nil
    end)
end


function A:GetHealth(unit)
    local ts = TargetServiceState(unit)
    if ts ~= nil and type(ts.vitals) == "table" and ts.vitals.valid == true then
        local hp, maxHp = tonumber(ts.vitals.hp), tonumber(ts.vitals.maxHp)
        if hp ~= nil and maxHp ~= nil and maxHp > 0 then
            return math.max(0, math.min(maxHp, hp)), maxHp
        end
    end
    local health = SharedUnitRead("UnitHealth", unit, 75, function() local ok, value=SafeInvoke(X2Unit,"UnitHealth",unit); return ok and value or nil end)
    local maxHealth = SharedUnitRead("UnitMaxHealth", unit, 75, function() local ok, value=SafeInvoke(X2Unit,"UnitMaxHealth",unit); return ok and value or nil end)
    health, maxHealth = tonumber(health), tonumber(maxHealth)
    if health == nil or maxHealth == nil or maxHealth <= 0 then return nil, nil end
    return math.max(0, math.min(maxHealth, health)), maxHealth
end

function A:GetDistance(unit)
    local ts = TargetServiceState(unit)
    if ts ~= nil and type(ts.distance) == "table" and ts.distance.valid == true then
        local distance = tonumber(ts.distance.value)
        if distance ~= nil and distance >= 0 then return distance end
    end
    if X2Unit == nil or type(X2Unit.UnitDistance) ~= "function" then return nil end
    local value = SharedUnitRead("UnitDistance", unit, 75, function() local ok, v=SafeInvoke(X2Unit,"UnitDistance",unit); return ok and v or nil end)
    local distance = type(value) == "table" and tonumber(value.distance) or tonumber(value)
    if distance == nil or distance < 0 then return nil end
    return distance
end

-- watchtarget lanes (report 七-C). Prefer the shared TargetService cache when
-- a consumer subscribed the watchAggro/watchDist fields; otherwise fall back to
-- a direct read with the same SharedUnitRead caching. Unreadable -> nil; the
-- window renders "--" (fail-closed, no errors).
function A:GetWatchTargetName()
    local ts = TargetServiceState("target")
    if ts ~= nil and type(ts.watchAggro) == "table" and ts.watchAggro.valid == true
        and type(ts.watchAggro.name) == "string" and ts.watchAggro.name ~= "" then
        return ts.watchAggro.name
    end
    if X2Unit == nil or type(X2Unit.UnitName) ~= "function" then return nil end
    local value = SharedUnitRead("UnitName", "watchtargettarget", 250, function()
        local ok, v = SafeInvoke(X2Unit, "UnitName", "watchtargettarget")
        if not ok or v == nil then return nil end
        local text = tostring(v)
        return text ~= "" and text or nil
    end)
    return value
end

function A:GetWatchTargetDistance()
    local ts = TargetServiceState("target")
    if ts ~= nil and type(ts.watchDist) == "table" and ts.watchDist.valid == true then
        local distance = tonumber(ts.watchDist.value)
        if distance ~= nil and distance >= 0 then return distance end
    end
    if X2Unit == nil or type(X2Unit.UnitDistance) ~= "function" then return nil end
    local value = SharedUnitRead("UnitDistance", "watchtarget", 75, function()
        local ok, v = SafeInvoke(X2Unit, "UnitDistance", "watchtarget")
        return ok and v or nil
    end)
    local distance = type(value) == "table" and tonumber(value.distance) or tonumber(value)
    if distance == nil or distance < 0 then return nil end
    return distance
end

function A:LoadData(key)
    local ok, value, err = SafeInvoke(ADDON, "LoadData", key)
    if not ok then return nil, err end
    return value, nil
end

function A:ClearData(key)
    if ADDON == nil or type(ADDON.ClearData) ~= "function" then return true end
    local ok, value, err = SafeInvoke(ADDON, "ClearData", key)
    if not ok then return false, err end
    return value ~= false, value == false and "clear returned false" or nil
end

function A:SaveData(key, value)
    local ok, result, err = SafeInvoke(ADDON, "SaveData", key, value)
    if not ok then return false, err end
    if result == false then return false, "save returned false" end
    return true
end

local function NormalizeIconPath(value)
    return type(value) == "string" and value ~= "" and value or nil
end

local buffInfoCache = {}

-- RU enabled X2Ability:GetBuffTooltip(buffType, itemLevel).  Unlike the
-- unit-row APIs this resolves metadata from a buff id even when that aura is
-- not currently active, which lets manual/preset tracking rows get the real
-- game icon instead of a blank placeholder.
function A:GetBuffInfoById(id)
    local key = tostring(id or "")
    if not key:match("^%d+$") then return nil end
    if buffInfoCache[key] ~= nil then
        return buffInfoCache[key] ~= false and buffInfoCache[key] or nil
    end
    if X2Ability == nil or type(X2Ability.GetBuffTooltip) ~= "function" then
        buffInfoCache[key] = false
        return nil
    end

    local numericId = tonumber(key)
    -- Item level is irrelevant for ordinary combat auras on current RU, but
    -- older rows can be picky. Try the cheap/common values and stop on the
    -- first structurally useful tooltip.
    for _, itemLevel in ipairs({ 0, 1, 55 }) do
        local ok, info = SafeInvoke(X2Ability, "GetBuffTooltip", numericId, itemLevel)
        if ok and type(info) == "table" then
            local path = NormalizeIconPath(info.path)
                or NormalizeIconPath(info.iconPath)
                or NormalizeIconPath(info.icon)
            local name = tostring(info.name or "")
            if path ~= nil or name ~= "" then
                local resolved = {
                    id = key,
                    name = name,
                    iconPath = path or "",
                    description = tostring(info.description or ""),
                    category = tostring(info.category or ""),
                    tipType = tostring(info.tipType or ""),
                }
                buffInfoCache[key] = resolved
                return resolved
            end
        end
    end
    buffInfoCache[key] = false
    return nil
end

function A:ResolveTrackedEntry(id, fallbackName, fallbackIcon)
    local info = self:GetBuffInfoById(id)
    if info ~= nil then
        return {
            name = info.name ~= "" and info.name or tostring(fallbackName or ""),
            iconPath = info.iconPath ~= "" and info.iconPath or tostring(fallbackIcon or ""),
        }, info
    end
    return { name = tostring(fallbackName or ""), iconPath = tostring(fallbackIcon or "") }, nil
end

local function FirstIconPath(info)
    if type(info) ~= "table" then return nil end
    -- Do not build a sparse candidate array and iterate it with ipairs():
    -- ipairs stops at the first nil, so RU variants that expose iconPath but
    -- not path would otherwise be silently missed. Check fields explicitly.
    local path = NormalizeIconPath(info.path)
        or NormalizeIconPath(info.iconPath)
        or NormalizeIconPath(info.icon_path)
        or NormalizeIconPath(info.icon)
        or NormalizeIconPath(info.skillIcon)
        or NormalizeIconPath(info.skill_icon)
        or NormalizeIconPath(info.texture)
    return path
end

-- Public wrapper for the effect-icon path resolver (magic-circle view uses it
-- to render the buff icon when one is available).
function A:IconPath(info)
    return FirstIconPath(info)
end

local EFFECT_METHODS = {
    buff = { count = "UnitBuffCount", data = "UnitBuff", tip = "UnitBuffTooltip" },
    debuff = { count = "UnitDeBuffCount", data = "UnitDeBuff", tip = "UnitDeBuffTooltip" },
    hidden = { count = "UnitHiddenBuffCount", data = "UnitHiddenBuff", tip = "UnitHiddenBuffTooltip" },
}

-- Reads at most `maximum` visible icon entries. The loop intentionally stops
-- once enough displayable effects are found, so large aura sets do not force
-- tooltip decoding for every entry on every effect lane tick.
local function EffectIdFromTable(info)
    if type(info) ~= "table" then return nil end
    return info.buff_id or info.buffId or info.buffID or info.id
        or info.buffType or info.buff_type or info.type
end

local function EffectTimeLeft(info)
    if type(info) ~= "table" then return nil end
    return tonumber(info.timeLeft or info.time_left or info.remainTime or info.remainingTime or info.remain_time)
end

local function NormalizeEffect(effectType, index, extra, tip)
    extra = type(extra) == "table" and extra or {}
    tip = type(tip) == "table" and tip or {}
    -- RU builds have moved aura fields between UnitBuff() and Tooltip() more than
    -- once. Treat both rows as Authority candidates and accept the common id
    -- aliases instead of depending on one historical `buff_id` shape.
    local id = EffectIdFromTable(extra) or EffectIdFromTable(tip)
    if id == nil then return nil end
    local idText = tostring(id)

    local resolved = nil
    local iconPath = FirstIconPath(extra) or FirstIconPath(tip)
    local name = tostring(tip.name or tip.buffName or extra.name or extra.buffName or "")
    if iconPath == nil or name == "" then
        resolved = A:GetBuffInfoById(idText)
        if resolved ~= nil then
            iconPath = iconPath or NormalizeIconPath(resolved.iconPath)
            if name == "" then name = tostring(resolved.name or "") end
        end
    end
    -- An effect without an icon cannot be rendered safely. Marking it invalid
    -- lets GetEffects() keep the previous reliable snapshot for tracked rows.
    if iconPath == nil then return nil end

    local timeLeftMs = EffectTimeLeft(tip) or EffectTimeLeft(extra) or 0
    timeLeftMs = math.max(0, tonumber(timeLeftMs) or 0)
    -- Apply only a registered compatibility correction. The returned client
    -- timer remains the input; the semantic relation is not a new ID source.
    local correction = PlatesData and PlatesData.EffectTimerCorrections
        and PlatesData.EffectTimerCorrections[effectType]
        and PlatesData.EffectTimerCorrections[effectType][idText]
    if correction ~= nil then
        timeLeftMs = timeLeftMs - (tonumber(correction.subtractMs) or 0)
        if timeLeftMs < 0 then return nil end
    end
    local stack = tonumber(tip.stack or tip.stackCount or tip.count or extra.stack or extra.stackCount or extra.count or 0) or 0
    return {
        key = effectType .. ":" .. idText .. ":" .. name,
        id = idText,
        name = name ~= "" and name or ("ID " .. idText),
        iconPath = iconPath,
        timeLeftMs = timeLeftMs,
        stack = math.max(0, math.floor(stack + 0.5)),
        sourceIndex = index,
    }
end

function A:GetEffects(unit, effectType, maximum, tracked, trackedOnly)
    -- Target scope: delegate to the unified Target Detection scan (single
    -- authority). The whitelist is still owned here and passed as a filter
    -- parameter. Falls back to the direct scan only when the service is absent
    -- or this is the player scope.
    local ts = TargetServiceState(unit)
    if ts ~= nil and ReplicatedSuite.TargetService ~= nil
        and type(ReplicatedSuite.TargetService.GetDisplayEffects) == "function" then
        local ok, effects, reliable = pcall(ReplicatedSuite.TargetService.GetDisplayEffects,
            ReplicatedSuite.TargetService, effectType, maximum, tracked, trackedOnly)
        if ok then return effects, reliable end
    end
    local methods = EFFECT_METHODS[effectType]
    if methods == nil then return {}, true end
    maximum = math.floor(tonumber(maximum) or 8)
    if maximum <= 0 then return {}, true end
    maximum = math.min(12, maximum)
    if X2Unit == nil or type(X2Unit[methods.count]) ~= "function" then return {}, true end
    if type(X2Unit[methods.data]) ~= "function" and type(X2Unit[methods.tip]) ~= "function" then return {}, true end

    local okCount, rawCount = SafeInvoke(X2Unit, methods.count, unit)
    if not okCount then return {}, false end
    local count = math.max(0, math.floor(tonumber(rawCount) or 0))
    local result = {}
    local reliable = true
    for index = 1, count do
        if #result >= maximum then break end
        local okData, extra = SafeInvoke(X2Unit, methods.data, unit, index)
        -- Some RU builds intermittently fail UnitBuff/UnitDeBuff row reads while
        -- the corresponding tooltip remains complete.  A failed cheap row is
        -- therefore not, by itself, an unreliable visibility sample: tooltip
        -- fallback below is the authoritative recovery path.
        extra = okData and type(extra) == "table" and extra or {}
        local rawId = EffectIdFromTable(extra)
        local id = rawId ~= nil and tostring(rawId) or nil
        local tip = nil
        -- Keep tracked-only cheap when UnitBuff()/UnitDeBuff() exposes an id.
        -- If the row call is missing/empty, fall back to Tooltip instead of
        -- dropping the whole effect. Some RU builds expose useful fields only
        -- through the tooltip function.
        if trackedOnly == true and id == nil then
            local okTip, value = SafeInvoke(X2Unit, methods.tip, unit, index)
            if not okTip then reliable = false end
            tip = okTip and type(value) == "table" and value or {}
            local tooltipId = EffectIdFromTable(tip)
            if tooltipId ~= nil then id = tostring(tooltipId) end
        end
        local trackedEntry = id ~= nil and type(tracked) == "table" and tracked[id] or nil
        local accept = trackedOnly ~= true or (type(trackedEntry) == "table" and trackedEntry.enabled ~= false)
        if accept then
            if tip == nil then
                local okTip, value = SafeInvoke(X2Unit, methods.tip, unit, index)
                if not okTip then reliable = false end
                tip = okTip and type(value) == "table" and value or {}
            end
            local effect = NormalizeEffect(effectType, index, extra, tip)
            if effect ~= nil then
                if type(trackedEntry) == "table" then
                    effect.trackedEntry = trackedEntry
                    if tostring(trackedEntry.customName or "") ~= "" then effect.name = tostring(trackedEntry.customName) end
                end
                result[#result + 1] = effect
            elseif trackedOnly == true and type(trackedEntry) == "table" and trackedEntry.enabled ~= false then
                -- A tracked effect is known to exist but its icon/tooltip row was
                -- incomplete for this poll. Treat the sample as transient instead
                -- of committing an empty lane and hiding a valid icon.
                reliable = false
            end
        end
    end
    -- API row order is not guaranteed to be stable between refreshes.  Render in
    -- deterministic id/name order so icons keep their slots instead of visually
    -- swapping back and forth (the "twitch" seen on the player aura row).
    table.sort(result, function(left, right)
        local leftPriority = tonumber(left and left.trackedEntry and left.trackedEntry.priority) or 0
        local rightPriority = tonumber(right and right.trackedEntry and right.trackedEntry.priority) or 0
        if leftPriority ~= rightPriority then return leftPriority > rightPriority end
        local leftId, rightId = tonumber(left and left.id), tonumber(right and right.id)
        if leftId ~= nil and rightId ~= nil and leftId ~= rightId then return leftId < rightId end
        local leftKey = tostring(left and (left.id or left.key or left.name) or "")
        local rightKey = tostring(right and (right.id or right.key or right.name) or "")
        if leftKey ~= rightKey then return leftKey < rightKey end
        return tostring(left and left.name or "") < tostring(right and right.name or "")
    end)
    return result, reliable
end

function A:GetEffectCount(unit, effectType)
    local methods = EFFECT_METHODS[effectType]
    if methods == nil or X2Unit == nil or type(X2Unit[methods.count]) ~= "function" then return 0 end
    local okCount, rawCount = SafeInvoke(X2Unit, methods.count, unit)
    if not okCount then return 0 end
    return math.max(0, math.floor(tonumber(rawCount) or 0))
end

-- Single id-scan Authority used by both alerts and rolling discovery.
--
-- Contract:
--   * scanLimit == nil  -> full cheap scan of every visible row, no tooltip
--                         fallback.  This is the alerts path and fixes the old
--                         duplicate-method bug where the later rolling version
--                         silently replaced the full scan and capped alerts to
--                         the first 12 rows.
--   * scanLimit ~= nil  -> rolling window (max 32 rows) with bounded tooltip
--                         fallback for discovery/capture callers.
--
-- Returns ids, nextCursor, totalCount. Callers interested only in ids may keep
-- reading the first return value exactly as before.
function A:GetEffectIds(unit, effectType, scanLimit, startIndex, tooltipFallbackLimit)
    local methods = EFFECT_METHODS[effectType]
    if methods == nil or X2Unit == nil or type(X2Unit[methods.count]) ~= "function" then return {}, 1, 0 end
    local fullScan = scanLimit == nil
    local okCount, rawCount = SafeInvoke(X2Unit, methods.count, unit)
    local count = okCount and math.max(0, math.floor(tonumber(rawCount) or 0)) or 0
    if count <= 0 then return {}, 1, 0 end

    if fullScan then
        scanLimit = count
        tooltipFallbackLimit = 0
    else
        scanLimit = math.max(1, math.min(32, math.floor(tonumber(scanLimit) or 12)))
        tooltipFallbackLimit = math.max(0, math.min(scanLimit, math.floor(tonumber(tooltipFallbackLimit) or scanLimit)))
    end

    local cursor = fullScan and 1 or math.floor(tonumber(startIndex) or 1)
    cursor = ((cursor - 1) % count) + 1
    local limit = math.min(count, scanLimit)
    local fallbackUsed = 0
    local result, seen = {}, {}

    for offset = 0, limit - 1 do
        local index = ((cursor + offset - 1) % count) + 1
        local extra = {}
        if type(X2Unit[methods.data]) == "function" then
            local okData, value = SafeInvoke(X2Unit, methods.data, unit, index)
            if okData and type(value) == "table" then extra = value end
        end
        local rawId = EffectIdFromTable(extra)
        if rawId == nil and fallbackUsed < tooltipFallbackLimit and type(X2Unit[methods.tip]) == "function" then
            local okTip, tip = SafeInvoke(X2Unit, methods.tip, unit, index)
            fallbackUsed = fallbackUsed + 1
            if okTip and type(tip) == "table" then rawId = EffectIdFromTable(tip) end
        end
        if rawId ~= nil then
            local id = tostring(rawId)
            if id:match("^%d+$") and seen[id] ~= true then
                seen[id] = true
                result[#result + 1] = id
            end
        end
    end

    local nextCursor = ((cursor + limit - 1) % count) + 1
    return result, nextCursor, count
end

-- Manager-only catalog scan. It may be called by the single Runtime host while
-- the manager is visible; no manager-specific OnUpdate is created.
function A:GetEffectCatalog(unit, effectType, scanLimit, includeUnknown)
    local methods = EFFECT_METHODS[effectType]
    if methods == nil then return {} end
    scanLimit = math.max(1, math.min(128, math.floor(tonumber(scanLimit) or 64)))
    if X2Unit == nil or type(X2Unit[methods.count]) ~= "function" then return {} end
    if type(X2Unit[methods.data]) ~= "function" and type(X2Unit[methods.tip]) ~= "function" then return {} end
    local okCount, rawCount = SafeInvoke(X2Unit, methods.count, unit)
    local count = okCount and math.min(scanLimit, math.max(0, math.floor(tonumber(rawCount) or 0))) or 0
    local result, seen = {}, {}

    local function primitiveSnapshot(value)
        local out = {}
        if type(value) ~= "table" then return out end
        local copied = 0
        for key, raw in pairs(value) do
            local kind = type(raw)
            if kind == "string" or kind == "number" or kind == "boolean" then
                out[tostring(key)] = raw
                copied = copied + 1
                if copied >= 24 then break end
            end
        end
        return out
    end

    for index = 1, count do
        local okData, extra = SafeInvoke(X2Unit, methods.data, unit, index)
        extra = okData and type(extra) == "table" and extra or {}
        local okTip, tip = SafeInvoke(X2Unit, methods.tip, unit, index)
        tip = okTip and type(tip) == "table" and tip or {}
        local effect = NormalizeEffect(effectType, index, extra, tip)
        if effect ~= nil then
            local key = "id:" .. tostring(effect.id)
            if seen[key] ~= true then
                seen[key] = true
                effect.diagnosticOnly = false
                effect.trackable = true
                result[#result + 1] = effect
            end
        elseif includeUnknown == true then
            local rawId = EffectIdFromTable(extra) or EffectIdFromTable(tip)
            local id = rawId ~= nil and tostring(rawId) or nil
            local name = FirstText(extra, { "name", "buffName", "title", "effectName" }) or FirstText(tip, { "name", "buffName", "title", "effectName" })
            local iconPath = FirstIconPath(extra) or FirstIconPath(tip) or ""
            local key = id ~= nil and ("id:" .. id) or ("index:" .. tostring(index))
            if seen[key] ~= true then
                seen[key] = true
                result[#result + 1] = {
                    id = id or "",
                    name = name or (effectType == "hidden" and ("未知 Hidden #" .. tostring(index)) or ("未知状态 #" .. tostring(index))),
                    iconPath = iconPath,
                    stack = tonumber(extra.stack or extra.count or tip.stack or tip.count),
                    timeLeftMs = TimeLeftMs(extra, tip),
                    effectType = effectType,
                    sourceIndex = index,
                    diagnosticOnly = true,
                    trackable = id ~= nil and id:match("^%d+$") ~= nil,
                    rawData = primitiveSnapshot(extra),
                    rawTooltip = primitiveSnapshot(tip),
                }
            end
        end
    end
    table.sort(result, function(left, right)
        if left.diagnosticOnly ~= right.diagnosticOnly then return left.diagnosticOnly ~= true end
        local a, b = tostring(left.name or ""), tostring(right.name or "")
        if a == b then
            local leftId, rightId = tonumber(left and left.id), tonumber(right and right.id)
            if leftId ~= nil and rightId ~= nil and leftId ~= rightId then return leftId < rightId end
            return tostring(left and left.id or "") < tostring(right and right.id or "")
        end
        return a < b
    end)
    return result
end

function A:ResolveSkillIcon(skillId)
    skillId = tonumber(skillId)
    if skillId == nil or X2Skill == nil then return nil end
    if type(X2Skill.Info) == "function" then
        local ok, info = SafeInvoke(X2Skill, "Info", skillId)
        if ok then
            local path = FirstIconPath(info)
            if path ~= nil then return path end
        end
    end
    if type(X2Skill.GetSkillTooltip) == "function" then
        local ok, tip = SafeInvoke(X2Skill, "GetSkillTooltip", skillId)
        if ok then return FirstIconPath(tip) end
    end
    return nil
end

local skillInfoCache = {}

-- Cooldown values come from the running client and are the runtime Authority.
-- Static RU database values only seed which important skill ids are watched.
function A:GetSkillInfo(skillId, fallbackName)
    skillId = tonumber(skillId)
    if skillId == nil or skillId <= 0 then return nil end
    local key = tostring(skillId)
    local cached = skillInfoCache[key]
    if cached ~= nil then return cached ~= false and cached or nil end
    local name, iconPath = nil, nil
    if X2Skill ~= nil and type(X2Skill.Info) == "function" then
        local ok, info = SafeInvoke(X2Skill, "Info", skillId)
        if ok and type(info) == "table" then
            name = info.name or info.skillName or info.skill_name
            iconPath = FirstIconPath(info)
        end
    end
    if X2Skill ~= nil and type(X2Skill.GetSkillTooltip) == "function" and (name == nil or iconPath == nil) then
        local ok, tip = SafeInvoke(X2Skill, "GetSkillTooltip", skillId)
        if ok and type(tip) == "table" then
            name = name or tip.name or tip.skillName or tip.skill_name
            iconPath = iconPath or FirstIconPath(tip)
        end
    end
    local result = { skillId=skillId, name=tostring(name or fallbackName or ("技能 "..key)), iconPath=iconPath or "ui/icon/icon_unknown_item.dds" }
    skillInfoCache[key] = result
    return result
end

function A:GetSkillCooldown(skillId, ignoreGlobalCooldown)
    skillId = tonumber(skillId)
    if skillId == nil or skillId <= 0 or X2Skill == nil or type(X2Skill.GetCooldown) ~= "function" then return nil,nil,"skill cooldown unavailable" end
    local ok, remain, duration = SafeInvoke(X2Skill, "GetCooldown", skillId, ignoreGlobalCooldown == true)
    if not ok then return nil,nil,tostring(duration or "GetCooldown failed") end
    remain, duration = tonumber(remain), tonumber(duration)
    if remain == nil then return nil,duration,"cooldown unavailable" end
    return math.max(0,remain), duration ~= nil and math.max(0,duration) or nil, nil
end

function A:GetMateSkillCooldown(skillId, ignoreGlobalCooldown)
    skillId = tonumber(skillId)
    if skillId == nil or skillId <= 0 or X2Skill == nil or type(X2Skill.GetMateCooldown) ~= "function" then
        return nil,nil,"mate cooldown unavailable"
    end

    -- API boundary: X2Skill:GetMateCooldown is whitelisted, while the current
    -- RU z_api_functions snapshot lists X2Mate:IsPlayerPetExists as NOT allowed.
    -- Do not use an unavailable presence probe merely to guard another native
    -- call. If the battle-mate constant is not exposed in this addon context,
    -- fail closed and let the ordinary GetCooldown path continue to work.
    -- ArcheRage's 17.09.2025 addon update explicitly documents mate type
    -- 2 as battle. Prefer the exported constant when present, otherwise use the
    -- documented value locally; this does not require importing/calling X2Mate.
    local mateType = tonumber(rawget(_G, "MATE_TYPE_BATTLE")) or 2

    local ok, remain, duration = SafeInvoke(X2Skill, "GetMateCooldown", skillId, ignoreGlobalCooldown == true, mateType)
    if not ok then return nil,nil,tostring(duration or "GetMateCooldown failed") end
    remain, duration = tonumber(remain), tonumber(duration)
    if remain == nil then return nil,duration,"mate cooldown unavailable" end
    return math.max(0,remain), duration ~= nil and math.max(0,duration) or nil, nil
end

local ITEM_SKILL_KEYS={"skillId","skill_id","skillType","skill_type","useSkillId","use_skill_id","useSkillType","use_skill_type","activeSkillId","active_skill_id","activeSkillType","active_skill_type"}
local ITEM_SKILL_TABLE_KEYS={"skill","useSkill","use_skill","activeSkill","active_skill"}
local function CollectItemSkillIds(value,result,seen,depth)
    if type(value)~="table" or depth>2 then return end
    for _,key in ipairs(ITEM_SKILL_KEYS) do
        local id=tonumber(value[key]); if id~=nil and id>0 and seen[id]~=true then seen[id]=true; result[#result+1]=id end
    end
    for _,key in ipairs(ITEM_SKILL_TABLE_KEYS) do if type(value[key])=="table" then CollectItemSkillIds(value[key],result,seen,depth+1) end end
end
function A:ExtractItemSkillIds(item)
    local result,seen={},{}; CollectItemSkillIds(item,result,seen,0); table.sort(result); return result
end

local function HasMethod(object, methodName)
    return object ~= nil and type(object[methodName]) == "function"
end

function A:GetCapabilitySnapshot()
    return {
        { key = "screen", label = "单位屏幕坐标", available = HasMethod(X2Unit, "GetUnitScreenPosition") },
        { key = "projection", label = "坐标投影回退", available = type(ConvertWorldToScreen) == "function" },
        { key = "health", label = "单位生命值", available = HasMethod(X2Unit, "UnitHealth") and HasMethod(X2Unit, "UnitMaxHealth") },
        { key = "distance", label = "单位距离", available = HasMethod(X2Unit, "UnitDistance") },
        { key = "buff", label = "Buff", available = HasMethod(X2Unit, "UnitBuffCount") and HasMethod(X2Unit, "UnitBuffTooltip") },
        { key = "debuff", label = "Debuff", available = HasMethod(X2Unit, "UnitDeBuffCount") and HasMethod(X2Unit, "UnitDeBuffTooltip") },
        { key = "hidden", label = "Hidden Buff", available = HasMethod(X2Unit, "UnitHiddenBuffCount") and HasMethod(X2Unit, "UnitHiddenBuffTooltip") },
        { key = "cast", label = "目标施法", available = HasMethod(X2Unit, "UnitCastingInfo") },
        { key = "gear", label = "目标装等", available = HasMethod(X2Unit, "UnitGearScore") },
        { key = "class", label = "目标职业", available = HasMethod(X2Unit, "GetTargetAbilityTemplates") and X2Locale ~= nil },
        { key = "equipment", label = "自身装备", available = HasMethod(X2Equipment, "GetEquippedItemTooltipInfo") },
        { key = "skillIcon", label = "技能 Icon 解析", available = HasMethod(X2Skill, "Info") or HasMethod(X2Skill, "GetSkillTooltip") },
        { key = "skillCooldown", label = "技能/道具冷却", available = HasMethod(X2Skill, "GetCooldown") },
        { key = "mateCooldown", label = "格罗亚/战斗宠物冷却", available = HasMethod(X2Skill, "GetMateCooldown") },
    }
end

local function ShallowPrimitiveTable(value)
    if type(value) ~= "table" then return nil end
    local result = {}
    for key, item in pairs(value) do
        local kind = type(item)
        if kind == "string" or kind == "number" or kind == "boolean" then
            result[tostring(key)] = item
        end
    end
    return result
end

function A:GetRawEffectDiagnostic(unit, effectType, index)
    local methods = EFFECT_METHODS[effectType]
    if methods == nil or X2Unit == nil then return nil end
    index = math.max(1, math.floor(tonumber(index) or 1))
    local okCount, rawCount = SafeInvoke(X2Unit, methods.count, unit)
    local count = okCount and math.max(0, math.floor(tonumber(rawCount) or 0)) or 0
    if count < index then return { count = count, index = index, dataOk = false, tipOk = false } end
    local okData, extra = SafeInvoke(X2Unit, methods.data, unit, index)
    local okTip, tip = SafeInvoke(X2Unit, methods.tip, unit, index)
    return {
        count = count,
        index = index,
        dataOk = okData == true,
        tipOk = okTip == true,
        data = ShallowPrimitiveTable(extra),
        tip = ShallowPrimitiveTable(tip),
    }
end

function A:GetRawCastingDiagnostic(unit)
    if not HasMethod(X2Unit, "UnitCastingInfo") then return nil end
    local ok, info = SafeInvoke(X2Unit, "UnitCastingInfo", unit)
    if not ok then return nil end
    return ShallowPrimitiveTable(info)
end

function A:GetUnitDiagnostic(unit)
    local name = self:GetUnitName(unit)
    local unitId = self:GetUnitId(unit)
    local x, y, z = self:GetUnitScreenPosition(unit)
    local health, maxHealth = self:GetHealth(unit)
    local distance = self:GetDistance(unit)
    return {
        token = tostring(unit or ""), name = name, unitId = unitId,
        x = x, y = y, z = z, health = health, maxHealth = maxHealth,
        distance = distance,
    }
end

function A:GetCastingInfo(unit)
    if X2Unit == nil or type(X2Unit.UnitCastingInfo) ~= "function" then return nil end
    local ok, info = SafeInvoke(X2Unit, "UnitCastingInfo", unit)
    if not ok or type(info) ~= "table" or info.showTargetCastingTime == false then return nil end
    if info.spellName == nil or tostring(info.spellName) == "" then return nil end
    local skillId = tonumber(info.skillId or info.skill_id or info.skillType or info.skill_type or info.type)
    local iconPath = FirstIconPath(info)
    if iconPath == nil and skillId ~= nil then iconPath = self:ResolveSkillIcon(skillId) end
    return {
        name = tostring(info.spellName),
        currentMs = math.max(0, tonumber(info.currCastingTime) or 0),
        totalMs = math.max(0, tonumber(info.castingTime) or 0),
        castingUseable = info.castingUseable == true,
        skillId = skillId,
        iconPath = iconPath,
    }
end


local ROLE_ICONS = {
    Tank = "ui/icon/icon_skill_adamant15.dds",
    Songer = "ui/icon/icon_skill_romance15.dds",
    Melee = "ui/icon/icon_skill_fight37.dds",
    Archer = "ui/icon/icon_skill_wild35.dds",
    Mage = "ui/icon/icon_skill_magic40.dds",
    Gunner = "ui/icon/icon_skill_madness07.dds",
    Malediction = "ui/icon/icon_skill_hatred25.dds",
    Dancer = "ui/icon/icon_skill_pleasure02.dds",
    Swiftblade = "ui/icon/icon_skill_assassin43.dds",
    Healer = "ui/icon/icon_skill_love01.dds",
    unknown = "ui/icon/top_question_mark.dds",
}

function A:GetGearScore(unit)
    local ts = TargetServiceState(unit)
    if ts ~= nil and type(ts.gear) == "table" then
        local score = tonumber(ts.gear.score)
        if score ~= nil and score > 0 then return score end
    end
    if X2Unit == nil or type(X2Unit.UnitGearScore) ~= "function" then return nil end
    local ok, value = SafeInvoke(X2Unit, "UnitGearScore", unit, true)
    local score = ok and tonumber(value) or nil
    return score ~= nil and score > 0 and score or nil
end


-- Target equipment type is exposed to the client as persistent set/equipment
-- buffs.  The whitelist does not provide a reliable target-slot inventory API,
-- so infer only from authoritative equip-state buff ids and return nil when the
-- state cannot be proven. This deliberately avoids guessing from class/gear score.
local TARGET_ARMOR_SET_BY_BUFF = PlatesData and PlatesData.TargetArmorByBuff or {}
local TARGET_WEAPON_STYLE_BY_BUFF = PlatesData and PlatesData.TargetWeaponStyleByBuff or {}
local TARGET_ARMOR_PRIORITY = PlatesData and PlatesData.TargetArmorPriority or {}
local TARGET_WEAPON_PRIORITY = PlatesData and PlatesData.TargetWeaponPriority or {}

local function CollectKnownUnitAuraIds(unit, wanted)
    local found = {}
    if X2Unit == nil then return found end
    local lanes = {
        { count = "UnitBuffCount", data = "UnitBuff", tip = "UnitBuffTooltip" },
        { count = "UnitHiddenBuffCount", data = "UnitHiddenBuff", tip = "UnitHiddenBuffTooltip" },
    }
    for _, lane in ipairs(lanes) do
        if type(X2Unit[lane.count]) == "function" then
            local okCount, rawCount = SafeInvoke(X2Unit, lane.count, unit)
            local count = okCount and math.max(0, math.min(160, math.floor(tonumber(rawCount) or 0))) or 0
            for index = 1, count do
                local id = nil
                if type(X2Unit[lane.data]) == "function" then
                    local okData, row = SafeInvoke(X2Unit, lane.data, unit, index)
                    if okData and type(row) == "table" then id = tonumber(row.buff_id or row.buffId or row.id) end
                end
                if id == nil and type(X2Unit[lane.tip]) == "function" then
                    local okTip, tip = SafeInvoke(X2Unit, lane.tip, unit, index)
                    if okTip and type(tip) == "table" then id = tonumber(tip.buff_id or tip.buffId or tip.id) end
                end
                if id ~= nil and wanted[id] ~= nil then found[id] = true end
            end
        end
    end
    return found
end

function A:GetTargetCombatLoadout(unit)
    unit = tostring(unit or "target")
    local wanted = {}
    for id in pairs(TARGET_ARMOR_SET_BY_BUFF) do wanted[id] = true end
    for id in pairs(TARGET_WEAPON_STYLE_BY_BUFF) do wanted[id] = true end
    local found = CollectKnownUnitAuraIds(unit, wanted)

    local function BuildItem(id, label)
        if id == nil or label == nil then return nil end
        local info = self:GetBuffInfoById(id)
        return {
            id = tostring(id),
            label = tostring(label),
            iconPath = type(info) == "table" and tostring(info.iconPath or "") or "",
        }
    end

    local armorId = nil
    -- Current complete-set ids take precedence over legacy compatibility ids.
    for _, id in ipairs(TARGET_ARMOR_PRIORITY) do
        if found[id] then armorId = id; break end
    end
    local weaponId = nil
    -- A visible shield is more decision-relevant than one/two-hand classification.
    for _, id in ipairs(TARGET_WEAPON_PRIORITY) do
        if found[id] then weaponId = id; break end
    end
    if armorId == nil and weaponId == nil then return nil end

    local armorItem = BuildItem(armorId, armorId and TARGET_ARMOR_SET_BY_BUFF[armorId])
    local weaponItem = BuildItem(weaponId, weaponId and TARGET_WEAPON_STYLE_BY_BUFF[weaponId])
    local items = {}
    if armorItem ~= nil then items[#items + 1] = armorItem end
    if weaponItem ~= nil then items[#items + 1] = weaponItem end
    return { armor = armorItem, weapon = weaponItem, items = items }
end

function A:GetClassInfo(unit)
    local ts = TargetServiceState(unit)
    if ts ~= nil and type(ts.profession) == "table" then
        local p = ts.profession
        if type(p.name) == "string" and p.name ~= "" and p.key ~= nil then
            local role = p.role or "unknown"
            if ROLE_ICONS[role] == nil then role = "unknown" end
            return { key = p.key, name = p.name, role = role, iconPath = ROLE_ICONS[role], indices = p.indices }
        end
    end
    if X2Unit == nil or type(X2Unit.GetTargetAbilityTemplates) ~= "function" then return nil end
    local ok, templates = SafeInvoke(X2Unit, "GetTargetAbilityTemplates", unit)
    if not ok or type(templates) ~= "table" or templates[1] == nil or templates[2] == nil or templates[3] == nil then return nil end
    local indices = { tonumber(templates[1].index), tonumber(templates[2].index), tonumber(templates[3].index) }
    if indices[1] == nil or indices[2] == nil or indices[3] == nil then return nil end
    table.sort(indices)
    local key = string.format("name_%d_%d_%d", indices[1], indices[2], indices[3])
    if key == "name_30_30_30" then return nil end
    local className = ""
    if X2Locale ~= nil and type(X2Locale.LocalizeUiText) == "function" and COMBINED_ABILITY_NAME_TEXT ~= nil then
        local localizedOk, localized = SafeInvoke(X2Locale, "LocalizeUiText", COMBINED_ABILITY_NAME_TEXT, key, "")
        if localizedOk and localized ~= nil then className = tostring(localized) end
    end
    if className == "" and type(GetUIText) == "function" and COMBINED_ABILITY_NAME_TEXT ~= nil then
        local fallbackOk, fallback = pcall(GetUIText, COMBINED_ABILITY_NAME_TEXT, key)
        if fallbackOk and fallback ~= nil then className = tostring(fallback) end
    end
    if className == "" then return nil end
    local role = type(nameMappings) == "table" and nameMappings[key] or "unknown"
    if ROLE_ICONS[role] == nil then role = "unknown" end
    return { key = key, name = className, role = role, iconPath = ROLE_ICONS[role], indices = indices }
end

local EQUIPMENT_SLOT_DEFS = {
    -- ES_* are actual equipment-slot constants. EST_* are equipment *type*
    -- constants and must never be used as slot IDs. The numeric fallbacks below
    -- are the same physical equipment slots already verified by Replicated Gear.
    -- Reading them happens only on equipment-change/forced refresh, not per tick.
    { key = "glider", label = "滑翔翼/翅膀", slot = function() return ES_BACKPACK end },
    { key = "head", label = "头盔", slot = function() return 1 end },
    { key = "necklace", label = "项链", slot = function() return 2 end },
    { key = "chest", label = "胸甲", slot = function() return 3 end },
    { key = "waist", label = "腰带", slot = function() return 4 end },
    { key = "legs", label = "腿甲", slot = function() return 5 end },
    { key = "hands", label = "手套", slot = function() return 6 end },
    { key = "feet", label = "鞋子", slot = function() return 7 end },
    { key = "wrists", label = "护腕", slot = function() return 8 end },
    { key = "cloak", label = "披风", slot = function() return 9 end },
    { key = "earring1", label = "耳环1", slot = function() return 10 end },
    { key = "earring2", label = "耳环2", slot = function() return 11 end },
    { key = "ring1", label = "戒指1", slot = function() return 12 end },
    { key = "ring2", label = "戒指2", slot = function() return 13 end },
    { key = "underwear", label = "内衣", slot = function() return 15 end },
    { key = "mainhand", label = "主手", slot = function() return ES_MAINHAND ~= nil and ES_MAINHAND or 16 end },
    { key = "offhand", label = "副手", slot = function() return ES_OFFHAND ~= nil and ES_OFFHAND or 17 end },
    { key = "ranged", label = "远程", slot = function() return ES_RANGED ~= nil and ES_RANGED or 18 end },
    { key = "instrument", label = "乐器", slot = function() return 19 end },
    { key = "costume", label = "时装", slot = function() return 28 end },
}

function A:GetEquipmentSnapshot()
    if X2Equipment == nil or type(X2Equipment.GetEquippedItemTooltipInfo) ~= "function" then return {} end
    local result = {}
    for _, def in ipairs(EQUIPMENT_SLOT_DEFS) do
        local slotId = def.slot()
        if slotId ~= nil then
            local ok, item = SafeInvoke(X2Equipment, "GetEquippedItemTooltipInfo", slotId, false)
            if ok and type(item) == "table" then
                local icon = NormalizeIconPath(item.icon or item.iconPath or item.path)
                if icon ~= nil then
                    result[def.key] = {
                        key = def.key, label = def.label, iconPath = icon,
                        gradeIconPath = NormalizeIconPath(item.gradeIcon or item.grade_icon),
                        name = tostring(item.name or item.itemName or ""),
                        -- RU tooltip builds may expose the equipped item's own
                        -- activation skill. Keep those ids so the cooldown lane
                        -- can follow the actually equipped glider without action-bar scans.
                        skillIds = self:ExtractItemSkillIds(item),
                    }
                end
            end
        end
    end
    return result
end
