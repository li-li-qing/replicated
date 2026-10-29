-- Replicated Suite · 海上点位只读目录
-- DMS -> 全局 XY 与寻宝一致；目标区域组来自原包显式映射，地图标记复用寻宝原生箭头。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S = ReplicatedSuite
local data = S.Data and S.Data.TreasureSeaPoints
if type(data) ~= "table" then return end
local C, points, groups = { version=2 }, {}, {seabugs={},ships={}}
S.TreasureSeaCatalog = C
local function Copy(t)
    if type(t) ~= "table" then return t end
    local out={};for k,v in pairs(t) do out[k]=Copy(v) end;return out
end
local regions={}
for _,r in ipairs(data.regions) do regions[r.id]=r end
local labels={seabugs="海虫",ships="沉船"}
local statusLabels={source_confirmed="原包已确认",unconfirmed="原包未确认",unreviewed="资料点",user_reported="用户补充"}
for _,kind in ipairs({"seabugs","ships"}) do
    groups[kind].all={}
    for _,row in ipairs(data[kind] or {}) do
        local region,number=row[1],row[2]
        local lng=(row[4]+row[5]/60+row[6]/3600)*(row[3]=="W" and -1 or 1)
        local lat=(row[8]+row[9]/60+row[10]/3600)*(row[7]=="S" and -1 or 1)
        local key=kind..":"..region..":"..number
        local meta=assert(regions[region],"unknown sea point region: "..tostring(region))
        local point={key=key,kind=kind,region=region,number=number,regionName=meta.text,zoneGroupId=meta.zoneGroupId,
            name=labels[kind].." #"..number,worldX=21504+lng*1024,worldY=28672+lat*1024,
            sourceStatus=row[11],sourceText=statusLabels[row[11]] or "资料点",
            text=string.format("%s %d°%d′%d″ · %s %d°%d′%d″",row[3],row[4],row[5],row[6],row[7],row[8],row[9],row[10])}
        assert(points[key]==nil,"duplicate sea point: "..key)
        points[key]=point
        groups[kind].all[#groups[kind].all+1]=point
        groups[kind][region]=groups[kind][region] or {}
        table.insert(groups[kind][region],point)
    end
end
function C:Get(key) return Copy(points[key]) end
function C:Counts() return {seabugs=#groups.seabugs.all,ships=#groups.ships.all} end
function C:List(kind,region) return Copy(groups[kind] and groups[kind][region or "all"] or {}) end
function C:Regions(kind)
    local out={{value="all",text="全部海域"}}
    for _,r in ipairs(data.regions) do
        if groups[kind] and groups[kind][r.id] then out[#out+1]={value=r.id,text=r.text} end
    end
    return out
end
