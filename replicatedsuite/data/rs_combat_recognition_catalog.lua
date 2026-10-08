------------------------------------------------------------------------
-- 中文维护（2026-10-05）：战斗识别参考目录。只编译静态索引，不扫描单位，
-- 不调用 Native/Events/Scheduler/Persistence；技能与状态是独立命名空间。
-- 同一 ID 保留多候选，不擅自判定唯一效果、阵营、职业或状态极性。
-- GetRecord/GetMatches/GetByName/GetGroup/GetTree/GetSpec 返回 borrowed 只读
-- 静态对象；消费者不得修改。参考规则统一 reference_unverified_ru。
------------------------------------------------------------------------
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
S.Data = S.Data or {}
local source = S.Data.CombatRecognitionSource
local C = { version=1, ByKey={}, BySkillId={}, ByBuffId={}, ByName={}, Groups={},
    Trees={}, Specs={}, Families={}, valid=true, invalid=0,
    counts={ records=0, skills=0, buffs=0, names=0, trees=0, specs=0,
        skillCollisions=0, buffCollisions=0 } }
S.Data.CombatRecognitionCatalog = C

local function NormalizeId(value)
    local id = tonumber(value)
    if id == nil or id ~= id or id <= 0 or id == math.huge or id ~= math.floor(id) then return nil end
    return id
end
local function NameKey(value)
    if type(value) ~= "string" then return nil end
    local name = value:match("^%s*(.-)%s*$")
    return name ~= "" and string.lower(name) or nil
end
local function Index(map, key, row, counter, collisionCounter)
    if key == nil then return end
    local list = map[key]
    if list == nil then list={};map[key]=list;C.counts[counter]=C.counts[counter]+1
    elseif #list == 1 and collisionCounter then C.counts[collisionCounter]=C.counts[collisionCounter]+1 end
    list[#list+1]=row
end
local function SpecKey(trees)
    if type(trees) ~= "table" or #trees ~= 3 then return nil end
    local a,b,c=trees[1],trees[2],trees[3]
    if type(a)~="string" or type(b)~="string" or type(c)~="string" then return nil end
    if C.Trees[a]==nil or C.Trees[b]==nil or C.Trees[c]==nil or a==b or b==c or a==c then return nil end
    -- 固定三个元素的排序，不遍历技能/职业目录。
    if a>b then a,b=b,a end
    if b>c then b,c=c,b end
    if a>b then a,b=b,a end
    return a.."|"..b.."|"..c
end

if type(source) ~= "table" or source.version ~= 1 or type(source.records) ~= "table" then
    C.valid=false
else
    for _,row in ipairs(source.records) do
        if type(row) ~= "table" or type(row.key) ~= "string" or C.ByKey[row.key] ~= nil
            or row.verification ~= "reference_unverified_ru" then
            C.valid=false;C.invalid=C.invalid+1
        else
            C.ByKey[row.key]=row;C.counts.records=C.counts.records+1
            C.Families[row.family]=(C.Families[row.family] or 0)+1
            if row.group then
                if C.Groups[row.group] ~= nil then C.valid=false;C.invalid=C.invalid+1
                else C.Groups[row.group]=row end
            end
            for _,id in ipairs(row.skillIds or {}) do
                if NormalizeId(id) then Index(C.BySkillId,id,row,"skills","skillCollisions")
                else C.valid=false;C.invalid=C.invalid+1 end
            end
            for _,id in ipairs(row.buffIds or {}) do
                if NormalizeId(id) then Index(C.ByBuffId,id,row,"buffs","buffCollisions")
                else C.valid=false;C.invalid=C.invalid+1 end
            end
            local seen={}
            for _,name in ipairs(row.names or {}) do
                local key=NameKey(name)
                if key and not seen[key] then seen[key]=true;Index(C.ByName,key,row,"names") end
            end
        end
    end
    for key,row in pairs(source.trees or {}) do C.Trees[key]=row;C.counts.trees=C.counts.trees+1 end
    for _,row in ipairs(source.specs or {}) do
        local key=SpecKey(row.trees)
        if key==nil or C.Specs[key]~=nil then C.valid=false;C.invalid=C.invalid+1
        else C.Specs[key]=row;C.counts.specs=C.counts.specs+1 end
    end
end

function C:GetRecord(key) return self.valid and self.ByKey[key] or nil end
function C:GetMatches(namespace, id)
    if not self.valid then return nil end
    local key=NormalizeId(id);if key==nil then return nil end
    if namespace=="skill" then return self.BySkillId[key] end
    if namespace=="buff" then return self.ByBuffId[key] end
    return nil
end
function C:GetByName(name) return self.valid and self.ByName[NameKey(name)] or nil end
function C:GetGroup(key) return self.valid and self.Groups[key] or nil end
function C:GetTree(key) return self.valid and self.Trees[key] or nil end
function C:GetSpec(trees)
    if not self.valid then return nil end
    local key=SpecKey(trees);return key and self.Specs[key] or nil
end
function C:GetHealth()
    local families={};for key,value in pairs(self.Families) do families[key]=value end
    local c=self.counts
    return { ok=self.valid, version=self.version, invalid=self.invalid, verification="reference_unverified_ru",
        release=source and source.provenance and source.provenance.release or nil,
        commit=source and source.provenance and source.provenance.commit or nil,
        sourceFiles=source and #(source.sourceFiles or {}) or 0,
        records=c.records, skills=c.skills, buffs=c.buffs, names=c.names, trees=c.trees, specs=c.specs,
        skillCollisions=c.skillCollisions, buffCollisions=c.buffCollisions, families=families,
        sourceAnomalies=source and #(source.anomalies or {}) or 0 }
end
