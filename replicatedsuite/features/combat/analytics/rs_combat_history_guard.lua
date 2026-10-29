-- Replicated Suite · 角色战绩独立凭据
-- 作者：Replicated
-- QQ群：1104129461
-- 随客户端发行的密钥只能提高基础篡改门槛，不能证明服务器事件真实性。
if ReplicatedSuite == nil or ReplicatedSuite.BootError ~= nil then return end
local S=ReplicatedSuite
local G={}
S.CombatHistoryGuard=G
local H=S.Features and S.Features.CombatAnalytics and S.Features.CombatAnalytics.PersonalHistory
if H then H.Guard=G end
local MAX_COUNTER,MAX_DAYS=9007199254740991,2048
local KEY='RS-history-guard-v1\0008e71c43d762caf90b385a4d51c937e62'
-- source 对象是唯一的写入身份。文件中的 dirty/pending 字段不参与授权；副本也不能继承待签权限。
local shadows=setmetatable({},{__mode='k'})
local function Text(n)return string.format('%.0f',n)end
local function WholeString(v)
    if type(v)~='string' or #v>16 or not (v=='0' or v:match('^[1-9]%d*$')) then return nil end
    local n=tonumber(v);if not n or n>MAX_COUNTER then return nil end;return n
end
local function Actual(v)
    if v==nil then return '0' end
    if type(v)=='string' then if WholeString(v) then return v end;return nil end
    if type(v)=='number' and v==v and v>=0 and v<=MAX_COUNTER and v==math.floor(v) then return Text(v) end
end
local function Hex(v)return type(v)=='string' and #v==64 and not v:find('[^0-9a-f]')end
local function Date(v)
    if v=='unknown' then return true end
    if type(v)~='string' then return false end
    local y,m,d=v:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$');y,m,d=tonumber(y),tonumber(m),tonumber(d)
    if not y or y<1 or not m or m<1 or m>12 or not d or d<1 then return false end
    local lengths={31,28,31,30,31,30,31,31,30,31,30,31}
    if y%4==0 and (y%100~=0 or y%400==0) then lengths[2]=29 end
    return d<=lengths[m]
end
local function Kind(id,source,identity)
    if type(id)~='string' or #id<3 or #id>64 or id:find('[^%w%-]') or type(source)~='table' then return nil,'历史来源标识无效' end
    if id:sub(1,2)~='p-' then
        if source.guard~=nil then return nil,'旧历史来源不能携带受保护凭据' end
        return 'legacy'
    end
    if type(identity)~='string' or identity=='' then return nil,'角色身份尚未就绪' end
    if type(source.guard)~='table' then return nil,'受保护历史来源缺少凭据，不能降级为旧记录' end
    return 'protected'
end
local function Encode(fields)
    local out={};for i,value in ipairs(fields)do local text=tostring(value);out[i]=#text..':'..text end
    return table.concat(out)
end
local function Mac(fields)
    local auth=S.CombatHistoryAuth
    if not auth or type(auth.HmacSha256)~='function' then return nil,'历史认证模块不可用' end
    local ok,tag=pcall(auth.HmacSha256,KEY,Encode(fields))
    if not ok or not Hex(tag) then return nil,'历史认证计算失败，未签名' end
    return tag
end
local function Digest(text)
    local auth=S.CombatHistoryAuth
    if not auth or type(auth.Sha256)~='function' then return nil,'历史认证摘要模块不可用' end
    local ok,tag=pcall(auth.Sha256,text)
    if not ok or not Hex(tag) then return nil,'历史认证摘要计算失败，未签名' end
    return tag
end
local function DayMac(view,date,row)
    return Mac({'RS-HISTORY-GUARD-DAY',1,view.identity,view.id,date,row.k,row.d})
end
local function HeadMac(view)
    return Mac({'RS-HISTORY-GUARD-HEAD',1,view.identity,view.id,view.serial,view.k,view.d,view.ak,view.ad,view.count,view.root})
end
local function BuildTree(view,previous,tags)
    -- 每日 HMAC 已绑定日期/身份/来源/计数。头还必须绑定这些叶子的完整集合，
    -- 否则可从不同合法快照拼接出守恒但日期分布被改写的日账。
    local dates={};for date in pairs(view.days)do dates[#dates+1]=date end;table.sort(dates)
    local level={}
    for i,date in ipairs(dates)do
        local tag=tags and tags[date] or view.days[date].tag
        if not Hex(tag) then return false,'每日凭据尚未完成认证，不能构建来源摘要' end
        level[i]=tag
    end
    local cache=previous and previous.tree or {}
    local current={};view.emptyRoot=previous and previous.emptyRoot
    if #level==0 then
        local err
        if not view.emptyRoot then view.emptyRoot,err=Digest('RS-HISTORY-GUARD-TREE-EMPTY\000v1')end
        if not view.emptyRoot then return false,err end
        view.root=view.emptyRoot;view.tree=current;return true
    end
    while #level>1 do
        local nextLevel={}
        for i=1,#level,2 do
            local left,right=level[i],level[i+1] or level[i]
            -- 两个固定64位HEX组成无歧义键。只复用上轮合法树的结果，且新缓存只收当前节点，
            -- 不随事件数累积历史摘要；单个叶子变化仅新增树高数量的 SHA256。
            local key=left..right;local node=cache[key] or current[key]
            if not node then
                local err;node,err=Digest('RS-HISTORY-GUARD-TREE-NODE\000v1'..key)
                if not node then return false,err end
            end
            current[key]=node;nextLevel[#nextLevel+1]=node
        end
        level=nextLevel
    end
    view.root=level[1];view.tree=current
    return true
end
local function Inspect(id,source,identity,unsigned)
    local kind,err=Kind(id,source,identity);if kind~='protected' then return nil,err or '旧历史来源不可写入受保护记录' end
    local guard=source.guard
    if guard.v~=1 or type(guard.days)~='table' or type(source.days)~='table'
        or type(source.totals)~='table' or type(source.archive)~='table' then return nil,'历史凭据结构无效' end
    for _,key in ipairs({'k','d','ak','ad'})do if not WholeString(guard[key]) then return nil,'历史凭据计数无效' end end
    local serial=Actual(source.serial);if not serial then return nil,'历史来源版本无效' end
    if Actual(source.totals.kills)~=guard.k or Actual(source.totals.deaths)~=guard.d
        or Actual(source.archive.kills)~=guard.ak or Actual(source.archive.deaths)~=guard.ad then return nil,'历史累计/归档与独立凭据不一致' end
    if not Hex(guard.tag) and unsigned~=true then return nil,'历史来源认证缺失或格式无效' end
    local view={id=id,identity=identity,guard=guard,guardDays=guard.days,sourceDays=source.days,
        serial=serial,k=guard.k,d=guard.d,ak=guard.ak,ad=guard.ad,tag=guard.tag,count=0,days={}}
    local k,d=tonumber(guard.ak),tonumber(guard.ad)
    for date,row in pairs(source.days)do
        view.count=view.count+1
        local proof=guard.days[date]
        if view.count>MAX_DAYS or not Date(date) or type(row)~='table' or type(proof)~='table' then return nil,'每日历史或凭据缺失/超限' end
        if not WholeString(proof.k) or not WholeString(proof.d) or Actual(row.kills)~=proof.k or Actual(row.deaths)~=proof.d then return nil,'每日历史与独立凭据不一致' end
        if not Hex(proof.tag) and unsigned~=true and not (type(unsigned)=='table' and unsigned[date] and proof.tag==nil) then return nil,'每日历史认证缺失或格式无效' end
        k,d=k+tonumber(proof.k),d+tonumber(proof.d)
        if k>MAX_COUNTER or d>MAX_COUNTER then return nil,'历史计数超过精确整数范围' end
        view.days[date]={k=proof.k,d=proof.d,tag=proof.tag}
    end
    local count=0
    for date in pairs(guard.days)do
        count=count+1;if count>MAX_DAYS or not view.days[date] then return nil,'存在没有日账的多余凭据' end
    end
    if Text(k)~=guard.k or Text(d)~=guard.d then return nil,'历史总计与每日/归档凭据不守恒' end
    return view
end
local function SameRow(a,b)return a and b and a.k==b.k and a.d==b.d and a.tag==b.tag end
local function Authenticate(view,previous,dirty)
    for date,row in pairs(view.days)do
        if not (dirty and dirty[date]) then
            local cached=previous and previous.id==view.id and previous.identity==view.identity and previous.days[date]
            if not (cached and not (previous.dirty and previous.dirty[date]) and SameRow(row,cached)) then
                local tag,err=DayMac(view,date,row);if not tag then return false,err end
                if tag~=row.tag then return false,'每日历史认证不匹配' end
            end
        end
    end
    if not dirty then
        local ok,err=BuildTree(view,previous);if not ok then return false,err end
        local tag,err=HeadMac(view);if not tag then return false,err end
        if tag~=view.tag then return false,'历史来源认证不匹配' end
    end
    return true
end
local function Approved(view,shadow)
    if not shadow or shadow.id~=view.id or shadow.identity~=view.identity or shadow.guard~=view.guard
        or shadow.guardDays~=view.guardDays or shadow.sourceDays~=view.sourceDays
        or shadow.serial~=view.serial or shadow.k~=view.k or shadow.d~=view.d or shadow.ak~=view.ak or shadow.ad~=view.ad
        or shadow.tag~=view.tag or shadow.count~=view.count then return false,'历史来源超出本次批准的修改范围' end
    for date,row in pairs(view.days)do if not SameRow(row,shadow.days[date]) then return false,'每日凭据超出本次批准的修改范围' end end
    return true
end
local function Hot(id,source,date,identity)
    local kind,err=Kind(id,source,identity);if kind~='protected' then return nil,err or '旧历史来源已冻结' end
    if not Date(date) then return nil,'服务器日期无效' end
    local shadow=shadows[source];local guard=source.guard
    if not shadow or shadow.id~=id or shadow.identity~=identity then return nil,'历史来源须先完成冷路径认证' end
    if guard~=shadow.guard or guard.v~=1 or guard.days~=shadow.guardDays or source.days~=shadow.sourceDays
        or type(source.totals)~='table' or type(source.archive)~='table'
        or guard.k~=shadow.k or guard.d~=shadow.d or guard.ak~=shadow.ak or guard.ad~=shadow.ad or guard.tag~=shadow.tag
        or Actual(source.serial)~=shadow.serial or Actual(source.totals.kills)~=shadow.k or Actual(source.totals.deaths)~=shadow.d
        or Actual(source.archive.kills)~=shadow.ak or Actual(source.archive.deaths)~=shadow.ad then return nil,'历史来源已偏离独立凭据，拒绝继续记录' end
    local saved=shadow.days[date];local row,proof=source.days[date],guard.days[date]
    if saved then
        if type(row)~='table' or type(proof)~='table' or not SameRow(proof,saved)
            or Actual(row.kills)~=saved.k or Actual(row.deaths)~=saved.d then return nil,'当前日账已偏离独立凭据' end
    -- 普通记录器可先分配空行；首个独立增量仍由 Advance 批准，非零预填不能借此补签。
    elseif proof~=nil or (row~=nil and (type(row)~='table' or Actual(row.kills)~='0' or Actual(row.deaths)~='0')) then
        return nil,'当前日期存在未经批准的日账'
    end
    return shadow
end
function G:ValidateDelta(delta)
    if type(delta)~='table' then return false,'战绩增量必须为表' end
    for _,key in ipairs({'kills','deaths'})do
        local value=delta[key]
        if value~=nil and (type(value)~='number' or (value~=0 and value~=1)) then return false,'单次击杀/死亡增量只能为0或1' end
    end
    return true
end
function G:NewSource(id,source,identity)
    if type(source)~='table' or source.guard~=nil or type(id)~='string' or id:sub(1,2)~='p-'
        or type(source.days)~='table' or type(source.totals)~='table' or type(source.archive)~='table' then return false,'只能为新的受保护来源建立凭据' end
    if Actual(source.totals.kills)~='0' or Actual(source.totals.deaths)~='0'
        or Actual(source.archive.kills)~='0' or Actual(source.archive.deaths)~='0' then return false,'不能把已有击杀/死亡历史改签为受保护记录' end
    local guard={v=1,k='0',d='0',ak='0',ad='0',days={}}
    local count=0
    for date,row in pairs(source.days)do
        count=count+1
        if count>MAX_DAYS or not Date(date) or type(row)~='table' or Actual(row.kills)~='0' or Actual(row.deaths)~='0' then return false,'新来源的每日击杀/死亡必须为零' end
        guard.days[date]={k='0',d='0'}
    end
    local candidate={guard=guard,serial=source.serial,totals=source.totals,archive=source.archive,days=source.days}
    local view,err=Inspect(id,candidate,identity,true);if not view then return false,err end
    for date,row in pairs(view.days)do
        local tag;tag,err=DayMac(view,date,row);if not tag then return false,err end
        row.tag=tag;guard.days[date].tag=tag
    end
    local ok;ok,err=BuildTree(view);if not ok then return false,err end
    local tag;tag,err=HeadMac(view);if not tag then return false,err end
    guard.tag=tag;view.tag=tag;source.guard=guard;shadows[source]=view
    return true
end
function G:Advance(id,source,delta,date,identity)
    local ok,err=self:ValidateDelta(delta);if not ok then return false,err end
    local shadow;shadow,err=Hot(id,source,date,identity);if not shadow then return false,err end
    local k,d=delta.kills or 0,delta.deaths or 0
    local old=shadow.days[date]
    if not old and shadow.count>=MAX_DAYS then return false,'每日凭据已满，请先归档旧日账' end
    if tonumber(shadow.k)+k>MAX_COUNTER or tonumber(shadow.d)+d>MAX_COUNTER or tonumber(shadow.serial)>=MAX_COUNTER then return false,'历史计数或版本超过精确整数范围' end
    local row=old or {k='0',d='0'}
    row.k=Text(tonumber(row.k)+k);row.d=Text(tonumber(row.d)+d)
    if not old then shadow.days[date]=row;shadow.guard.days[date]={k='0',d='0'};shadow.count=shadow.count+1 end
    local proof=shadow.guard.days[date];proof.k=row.k;proof.d=row.d
    shadow.k=Text(tonumber(shadow.k)+k);shadow.d=Text(tonumber(shadow.d)+d)
    shadow.guard.k=shadow.k;shadow.guard.d=shadow.d;shadow.serial=Text(tonumber(shadow.serial)+1)
    shadow.pending=true;shadow.dirty=shadow.dirty or {}
    if not old or k~=0 or d~=0 then shadow.dirty[date]=true end
    return true
end
function G:ArchiveDay(id,source,date,identity)
    local shadow,err=Hot(id,source,date,identity);if not shadow then return false,err end
    local row=shadow.days[date];if not row then return false,'待归档的日账不存在' end
    shadow.ak=Text(tonumber(shadow.ak)+tonumber(row.k));shadow.ad=Text(tonumber(shadow.ad)+tonumber(row.d))
    shadow.guard.ak=shadow.ak;shadow.guard.ad=shadow.ad;shadow.guard.days[date]=nil
    shadow.days[date]=nil;shadow.count=shadow.count-1;shadow.pending=true;shadow.dirty=shadow.dirty or {};shadow.dirty[date]=nil
    return true
end
function G:VerifySource(id,source,identity)
    local kind,err=Kind(id,source,identity);if not kind then return false,err end
    if kind=='legacy' then return true end
    local view;view,err=Inspect(id,source,identity);if not view then return false,err end
    local ok;ok,err=Authenticate(view,shadows[source]);if not ok then return false,err end
    shadows[source]=view
    return true
end
function G:SealSource(id,source,identity)
    local kind,err=Kind(id,source,identity);if not kind then return false,err end
    if kind=='legacy' then return true end
    local shadow=shadows[source]
    if not shadow or not shadow.pending then return self:VerifySource(id,source,identity) end
    local view;view,err=Inspect(id,source,identity,shadow.dirty);if not view then return false,err end
    local ok;ok,err=Approved(view,shadow);if not ok then return false,err end
    ok,err=Authenticate(view,shadow,shadow.dirty);if not ok then return false,err end
    -- 先在局部完成全部认证；任一计算失败，原凭据与 pending 保持原样，不能留下半次签名。
    local tags={}
    for date in pairs(shadow.dirty)do
        local tag;tag,err=DayMac(view,date,view.days[date]);if not tag then return false,err end;tags[date]=tag
    end
    ok,err=BuildTree(view,shadow,tags);if not ok then return false,err end
    local tag;tag,err=HeadMac(view);if not tag then return false,err end
    for date,dayTag in pairs(tags)do view.guard.days[date].tag=dayTag;view.days[date].tag=dayTag end
    view.guard.tag=tag;view.tag=tag;shadows[source]=view
    return true
end
function G:CopyGuard(guard)
    if type(guard)~='table' then return nil end
    local out={v=guard.v,k=guard.k,d=guard.d,ak=guard.ak,ad=guard.ad,tag=guard.tag}
    if type(guard.days)~='table' then out.days=guard.days;return out end
    out.days={}
    for date,row in pairs(guard.days)do
        if type(row)=='table' then out.days[date]={k=row.k,d=row.d,tag=row.tag} else out.days[date]=row end
    end
    return out
end
