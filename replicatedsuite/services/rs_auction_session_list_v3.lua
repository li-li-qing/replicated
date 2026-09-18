------------------------------------------------------------------------
-- Replicated Suite V3 - Auction Session List
--
-- Session-only temporary shopping/material groups.  No Persistence Store, no
-- Scheduler and no Native API.  Trade/detail presenters submit detached facts;
-- this service owns only the current-addon-run temporary list and CRUD/order.
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Services = S.Services or {}
local T = {
    version = 1, SessionListContractVersion = 1,
    Topic = "v3.auction_session_list.updated", presentationBoundary = "service_only",
    groups = {}, nextGroupId = 1, revision = 0,
    PersistenceStoreId = nil,
}
S.Services.AuctionSessionListV3 = T

local function Copy(value, seen)
    if S.Utils ~= nil and type(S.Utils.DeepCopy) == "function" then return S.Utils.DeepCopy(value) end
    if type(value) ~= "table" then return value end
    seen = seen or {}; if seen[value] then return nil end; seen[value] = true
    local out = {}; for key, child in pairs(value) do out[key] = Copy(child, seen) end; return out
end
local function Trim(value) return (tostring(value or ""):match("^%s*(.-)%s*$")) or "" end
local function MaterialKey(spec)
    local itemType = tonumber(spec and spec.itemType)
    if itemType ~= nil and itemType > 0 then return "item:" .. tostring(math.floor(itemType)) end
    local name = Trim(spec and (spec.name or spec.materialKey) or "")
    if name == "" then return nil end
    return "name:" .. name:lower()
end
local function FindGroup(self, groupId)
    groupId = tonumber(groupId); if groupId == nil then return nil end
    for index, group in ipairs(self.groups) do if tonumber(group.id) == groupId then return group, index end end
    return nil
end
local function Publish(self, reason)
    self.revision = self.revision + 1
    if type(S.Events) == "table" and type(S.Events.Publish) == "function" then S.Events:Publish(self.Topic, self.revision, tostring(reason or "update")) end
end
local function NormalizeMaterial(spec)
    spec = type(spec) == "table" and spec or {}
    local key = MaterialKey(spec); if key == nil then return nil, "材料名称/身份不能为空" end
    local count = tonumber(spec.count); if count == nil or count <= 0 then return nil, "材料数量必须大于 0" end
    local name = Trim(spec.name or spec.displayName or spec.materialKey); if name == "" then name = "材料" end
    return {
        key = key, itemType = tonumber(spec.itemType), materialKey = spec.materialKey,
        name = name, count = count, searchable = spec.searchable ~= false,
    }
end

function T:GetSnapshot()
    return { status = #self.groups > 0 and "ready" or "empty", groups = Copy(self.groups), revision = self.revision, groupCount = #self.groups }
end

-- 中文维护注释（2026-09-14，临时清单身份/合并）：同一个货物组内优先按 itemType 合并数量，只有缺失
-- itemType 时才退回规范化名称；不同组绝不跨组相加，以保留“哪个跑商货物产生哪些材料”的来源事实。
-- 本 Service 没有 Store/Scheduler，ReloadAddon 后 Lua state 自然清空，符合 Session lifetime。
function T:AddTradeGroup(spec)
    spec = type(spec) == "table" and spec or {}
    local productName = Trim(spec.productName or spec.name); if productName == "" then return false, "临时货物名称不能为空" end
    local group = { id = self.nextGroupId, source = tostring(spec.source or "manual"), sourceKey = tostring(spec.sourceKey or ""), productName = productName, materials = {} }
    self.nextGroupId = self.nextGroupId + 1
    local byKey = {}
    for _, raw in ipairs(type(spec.materials) == "table" and spec.materials or {}) do
        local material = NormalizeMaterial(raw)
        if material ~= nil then
            local existing = byKey[material.key]
            if existing ~= nil then existing.count = (tonumber(existing.count) or 0) + material.count
            else group.materials[#group.materials + 1] = material; byKey[material.key] = material end
        end
    end
    self.groups[#self.groups + 1] = group; Publish(self, "add_group")
    return true, group.id
end

function T:AddTradeRow(row)
    row = type(row) == "table" and row or {}
    local materials = {}
    for _, material in ipairs(type(row.materialRows) == "table" and row.materialRows or {}) do
        materials[#materials + 1] = {
            itemType = material.itemType, materialKey = material.materialKey,
            name = material.name, count = material.count,
            searchable = material.includeInCost ~= false,
        }
    end
    return self:AddTradeGroup({ source = "trade", sourceKey = tostring(row.key or ""), productName = tostring(row.name or "贸易品"), materials = materials })
end
function T:RenameGroup(groupId, name)
    local group = FindGroup(self, groupId); if group == nil then return false, "临时组不存在" end
    name = Trim(name); if name == "" then return false, "临时组名称不能为空" end
    group.productName = name; Publish(self, "rename_group"); return true
end
function T:MoveGroup(groupId, direction)
    local _, index = FindGroup(self, groupId); if index == nil then return false, "临时组不存在" end
    local delta = tonumber(direction); if delta == nil or delta == 0 then return false, "移动方向无效" end; delta = delta < 0 and -1 or 1
    local target = index + delta; if target < 1 or target > #self.groups then return false, "临时组已在边界" end
    self.groups[index], self.groups[target] = self.groups[target], self.groups[index]; Publish(self, "move_group"); return true
end
function T:RemoveGroup(groupId)
    local _, index = FindGroup(self, groupId); if index == nil then return false, "临时组不存在" end
    table.remove(self.groups, index); Publish(self, "remove_group"); return true
end
function T:AddMaterial(groupId, spec)
    local group = FindGroup(self, groupId); if group == nil then return false, "临时组不存在" end
    local material, err = NormalizeMaterial(spec); if material == nil then return false, err end
    for _, current in ipairs(group.materials) do
        if current.key == material.key then current.count = current.count + material.count; Publish(self, "merge_material"); return true, current.key end
    end
    group.materials[#group.materials + 1] = material; Publish(self, "add_material"); return true, material.key
end
function T:UpdateMaterial(groupId, materialKey, patch)
    local group = FindGroup(self, groupId); if group == nil then return false, "临时组不存在" end
    materialKey, patch = tostring(materialKey or ""), type(patch) == "table" and patch or {}
    for index, material in ipairs(group.materials) do
        if material.key == materialKey then
            local nextName = material.name
            if patch.name ~= nil then nextName = Trim(patch.name); if nextName == "" then return false, "材料名称不能为空" end end
            local nextCount = material.count
            if patch.count ~= nil then nextCount = tonumber(patch.count); if nextCount == nil or nextCount <= 0 then return false, "材料数量必须大于 0" end end
            local nextSearchable = patch.searchable ~= nil and patch.searchable == true or material.searchable
            -- 中文维护注释（2026-09-14，Session 材料改名身份）：itemType 是稳定物品身份，显示名修改不能改 key；
            -- 只有没有 itemType 的手工临时材料才以规范化名称作为身份。旧实现只改 material.name，不刷新
            -- name:<...> key，之后再次添加同名材料会生成第二行，导致 CRUD/移动/删除引用旧身份。这里在 Service
            -- Authority 内原子更新 key；若新名称已经存在则合并数量并删除旧行，保证同一组内身份唯一。
            local nextKey = material.key
            if not (tonumber(material.itemType) ~= nil and tonumber(material.itemType) > 0) then
                nextKey = MaterialKey({ name = nextName }) or material.key
            end
            if nextKey ~= material.key then
                for otherIndex, other in ipairs(group.materials) do
                    if otherIndex ~= index and other.key == nextKey then
                        other.name = nextName
                        other.count = (tonumber(other.count) or 0) + (tonumber(nextCount) or 0)
                        other.searchable = nextSearchable
                        table.remove(group.materials, index)
                        Publish(self, "update_material_merge")
                        return true
                    end
                end
            end
            material.name, material.count, material.searchable, material.key = nextName, nextCount, nextSearchable, nextKey
            Publish(self, "update_material"); return true
        end
    end
    return false, "材料不存在"
end
function T:MoveMaterial(groupId, materialKey, direction)
    local group = FindGroup(self, groupId); if group == nil then return false, "临时组不存在" end
    local index = nil; for i, material in ipairs(group.materials) do if material.key == tostring(materialKey or "") then index = i; break end end
    if index == nil then return false, "材料不存在" end
    local delta = tonumber(direction); if delta == nil or delta == 0 then return false, "移动方向无效" end; delta = delta < 0 and -1 or 1
    local target = index + delta; if target < 1 or target > #group.materials then return false, "材料已在边界" end
    group.materials[index], group.materials[target] = group.materials[target], group.materials[index]; Publish(self, "move_material"); return true
end
function T:RemoveMaterial(groupId, materialKey)
    local group = FindGroup(self, groupId); if group == nil then return false, "临时组不存在" end
    for index, material in ipairs(group.materials) do if material.key == tostring(materialKey or "") then table.remove(group.materials, index); Publish(self, "remove_material"); return true end end
    return false, "材料不存在"
end
function T:Clear(reason)
    self.groups = {}; self.nextGroupId = 1; Publish(self, reason or "clear"); return true
end
