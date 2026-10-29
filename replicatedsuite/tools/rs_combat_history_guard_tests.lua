-- Replicated Suite · 独立击杀/死亡保护凭据回归（Lua 5.1）
-- 运行目录为 replicatedsuite；使用真实认证模块，不访问玩家文件或 Native。
local passed,failed=0,0
local function Test(name,fn)
    local ok,err=xpcall(fn,debug.traceback)
    if ok then passed=passed+1;print('PASS combat-history-guard '..name)
    else failed=failed+1;print('FAIL combat-history-guard '..name..': '..tostring(err)) end
end
local function Copy(v)
    if type(v)~='table' then return v end
    local out={};for k,x in pairs(v)do out[k]=Copy(x)end;return out
end
local function Boot()
    ReplicatedSuite={Features={CombatAnalytics={PersonalHistory={}}}}
    local S=ReplicatedSuite
    local crypto=assert(loadfile('core/rs_combat_history_auth.lua'),'real auth module is missing');crypto()
    local auth=S.CombatHistoryAuth.HmacSha256;local calls=0
    S.CombatHistoryAuth.HmacSha256=function(key,text)calls=calls+1;return auth(key,text)end
    local sha=S.CombatHistoryAuth.Sha256;local hashes=0
    S.CombatHistoryAuth.Sha256=function(text)hashes=hashes+1;return sha(text)end
    local file=loadfile('features/combat/analytics/rs_combat_history_guard.lua')
    assert(file,'guard module is missing');file()
    local G=S.CombatHistoryGuard
    assert(type(G)=='table' and S.Features.CombatAnalytics.PersonalHistory.Guard==G,'guard API missing or aliased incorrectly')
    return G,function()return calls end,S,function()return hashes end
end
local ID,IDENTITY='p-offline-fixture','character:server:player'
local DATE='2026-10-29'
local function Source()return {serial='0',totals={},archive={},days={}}end
local function New()
    local G,calls,S,hashes=Boot();local source=Source();assert(G:NewSource(ID,source,IDENTITY));return G,source,calls,S,hashes
end
local function Add(row,delta)
    for _,key in ipairs({'kills','deaths'})do
        local n=delta[key] or 0;if n>0 then row[key]=string.format('%.0f',(tonumber(row[key]) or 0)+n) end
    end
end
local function Record(G,source,delta,date)
    date=date or DATE;assert(G:Advance(ID,source,delta,date,IDENTITY))
    source.days[date]=source.days[date] or {};Add(source.days[date],delta);Add(source.totals,delta)
    source.serial=string.format('%.0f',tonumber(source.serial)+1)
end
local function Reject(ok,err)assert(ok~=true and type(err)=='string' and #err>0,'operation accepted bad input or gave no failure reason')end
Test('legacy sources remain untouched and cannot carry protected credentials',function()
    local G=Boot();local source={serial='47',totals={kills='19'},archive={kills='19'},days={}}
    assert(G:VerifySource('l-existing',source,IDENTITY));assert(G:SealSource('d-existing',source,IDENTITY))
    assert(source.guard==nil and source.serial=='47' and source.totals.kills=='19','legacy source was rewritten')
    Reject(G:NewSource('d-existing',source,IDENTITY));source.guard={v=1};Reject(G:VerifySource('d-existing',source,IDENTITY))
end)
Test('new sources must be empty and existing credentials are never reset',function()
    local G,source=New();assert(source.guard.v==1 and source.guard.k=='0' and source.guard.d=='0')
    assert(G:VerifySource(ID,source,IDENTITY));local tag=source.guard.tag;Reject(G:NewSource(ID,source,IDENTITY));assert(source.guard.tag==tag)
    local nonempty=Source();nonempty.totals.kills='1';nonempty.days[DATE]={kills='1'}
    Reject(G:NewSource(ID,nonempty,IDENTITY));assert(nonempty.guard==nil)
    local archived=Source();archived.archive.deaths='1';archived.totals.deaths='1';Reject(G:NewSource(ID,archived,IDENTITY))
end)
Test('single kill death deltas reject coercion bulk negative and fractional values atomically',function()
    local G,source=New();local tag=source.guard.tag
    for _,value in ipairs({-1,0.5,'1','0',2,100,true,math.huge,0/0})do
        Reject(G:Advance(ID,source,{kills=value},DATE,IDENTITY))
        Reject(G:Advance(ID,source,{deaths=value},DATE,IDENTITY))
        assert(source.guard.k=='0' and source.guard.d=='0' and source.guard.tag==tag and next(source.guard.days)==nil)
    end
    Record(G,source,{kills=1,deaths=1,damage=1234567});Record(G,source,{kills=0,damage=0.5})
    assert(G:SealSource(ID,source,IDENTITY));assert(source.guard.k=='1' and source.guard.d=='1' and source.serial=='2')
end)
Test('pending increments are signed only after normal accumulation and serial advancement',function()
    local G,source,calls=New();local before=calls()
    assert(G:Advance(ID,source,{kills=1},DATE,IDENTITY));assert(calls()==before,'hot path calculated an HMAC')
    Reject(G:SealSource(ID,source,IDENTITY));assert(source.guard.days[DATE].tag==nil)
    source.days[DATE]={kills='1'};source.totals.kills='1';source.serial='1'
    Reject(G:VerifySource(ID,source,IDENTITY));assert(G:SealSource(ID,source,IDENTITY));assert(G:VerifySource(ID,source,IDENTITY))
end)
Test('zero combat delta still authorizes the normal serial and unknown server day',function()
    local G,source=New();Record(G,source,{damage=5},'unknown');assert(G:SealSource(ID,source,IDENTITY))
    assert(source.guard.days.unknown.k=='0' and source.guard.days.unknown.d=='0' and source.serial=='1')
    assert(G:VerifySource(ID,source,IDENTITY));Reject(G:Advance(ID,source,{kills=1},'2026-02-30',IDENTITY))
end)
Test('normal recorder may allocate an empty day before requesting its first increment',function()
    local G,source=New();source.days[DATE]={kills='0',deaths='0',damage='0'}
    Record(G,source,{kills=1});assert(G:SealSource(ID,source,IDENTITY));assert(source.guard.days[DATE].k=='1')
    local G2,s=New();s.days[DATE]={kills='1'};Reject(G2:Advance(ID,s,{kills=1},DATE,IDENTITY))
end)
Test('actual totals current day and serial tampering stop the next event',function()
    for _,target in ipairs({'totals','day','serial','archive','guard'})do
        local G,source=New();Record(G,source,{kills=1});assert(G:SealSource(ID,source,IDENTITY))
        if target=='totals' then source.totals.kills='8'
        elseif target=='day' then source.days[DATE].kills='8'
        elseif target=='serial' then source.serial='8'
        elseif target=='archive' then source.archive.kills='8'
        else source.guard.k='8' end
        Reject(G:Advance(ID,source,{kills=1},DATE,IDENTITY))
    end
end)
Test('no pending source cannot sign internally consistent forged counts',function()
    local G,source=New();Record(G,source,{kills=1});assert(G:SealSource(ID,source,IDENTITY))
    local tag=source.guard.tag;local dayTag=source.guard.days[DATE].tag
    source.totals.kills='91';source.days[DATE].kills='91';source.guard.k='91';source.guard.days[DATE].k='91'
    Reject(G:SealSource(ID,source,IDENTITY));assert(source.guard.tag==tag and source.guard.days[DATE].tag==dayTag,'getter resigned forged data')
end)
Test('authentic days from different snapshots cannot splice a different daily distribution under an old header',function()
    local G,source=New();local a='2026-10-28'
    Record(G,source,{damage=1},a);Record(G,source,{kills=1});assert(G:SealSource(ID,source,IDENTITY));local p0=Copy(source)
    Record(G,source,{kills=1},a);assert(G:SealSource(ID,source,IDENTITY));local p1=Copy(source)
    Record(G,source,{kills=1});assert(G:SealSource(ID,source,IDENTITY));local p2=Copy(source)
    assert(p0.days[a].kills==nil and p1.days[a].kills=='1' and p1.serial=='3' and p1.totals.kills=='2' and p2.days[DATE].kills=='2')
    for _,warm in ipairs({false,true})do
        local forged=Copy(p1);if warm then assert(G:VerifySource(ID,forged,IDENTITY))end
        forged.days[a]=Copy(p0.days[a]);forged.guard.days[a]=Copy(p0.guard.days[a])
        forged.days[DATE]=Copy(p2.days[DATE]);forged.guard.days[DATE]=Copy(p2.guard.days[DATE])
        assert(forged.guard.k=='2' and forged.totals.kills=='2' and forged.days[DATE].kills=='2','splice fixture did not preserve the old total while moving kills into today')
        Reject(G:VerifySource(ID,forged,IDENTITY));Reject(G:SealSource(ID,forged,IDENTITY))
    end
end)
Test('approved pending count is not permission to rewrite any other count or tag',function()
    for _,target in ipairs({'total','day','headerTag','dayTag','missing','extra'})do
        local G,source=New();Record(G,source,{kills=1});assert(G:SealSource(ID,source,IDENTITY));Record(G,source,{kills=1})
        if target=='total' then source.totals.kills='3';source.guard.k='3';source.days[DATE].kills='3';source.guard.days[DATE].k='3'
        elseif target=='day' then source.days[DATE].kills='3'
        elseif target=='headerTag' then source.guard.tag=string.rep('a',64)
        elseif target=='dayTag' then source.guard.days[DATE].tag=string.rep('a',64)
        elseif target=='missing' then source.guard.days[DATE]=nil
        else source.guard.days['2026-10-28']={k='0',d='0',tag=string.rep('a',64)};source.days['2026-10-28']={} end
        Reject(G:SealSource(ID,source,IDENTITY))
    end
end)
Test('cold verification authenticates tags identity source id and retained days',function()
    for _,target in ipairs({'headerTag','dayTag','identity','id','date','guardVersion','guardType'})do
        local G,source=New();Record(G,source,{kills=1,deaths=1});assert(G:SealSource(ID,source,IDENTITY))
        local identity,id=IDENTITY,ID
        if target=='headerTag' then source.guard.tag=string.rep('0',64)
        elseif target=='dayTag' then source.guard.days[DATE].tag=string.rep('0',64)
        elseif target=='identity' then identity='different-character'
        elseif target=='id' then id='p-different-source'
        elseif target=='date' then source.days['2026-10-28']=source.days[DATE];source.days[DATE]=nil;source.guard.days['2026-10-28']=source.guard.days[DATE];source.guard.days[DATE]=nil
        elseif target=='guardVersion' then source.guard.v=2
        else source.guard.k=1 end
        Reject(G:VerifySource(id,source,identity))
    end
end)
Test('clearing credentials or changing protected prefix never downgrades to legacy',function()
    local G,source=New();Record(G,source,{kills=1});assert(G:SealSource(ID,source,IDENTITY))
    local guard=source.guard;source.guard=nil;Reject(G:VerifySource(ID,source,IDENTITY));Reject(G:SealSource(ID,source,IDENTITY))
    Reject(G:Advance(ID,source,{kills=1},DATE,IDENTITY));source.guard=guard;Reject(G:VerifySource('d-offline-fixture',source,IDENTITY))
end)
Test('archive moves only approved day counts and waits for normal source move',function()
    local G,source=New();Record(G,source,{kills=1,deaths=1},'2026-10-28');Record(G,source,{kills=1},DATE)
    assert(G:SealSource(ID,source,IDENTITY));Reject(G:ArchiveDay(ID,source,'2026-10-27',IDENTITY))
    assert(G:ArchiveDay(ID,source,'2026-10-28',IDENTITY));Reject(G:SealSource(ID,source,IDENTITY))
    source.archive.kills='1';source.archive.deaths='1';source.days['2026-10-28']=nil
    assert(G:SealSource(ID,source,IDENTITY));assert(source.guard.ak=='1' and source.guard.ad=='1' and source.guard.k=='2')
    assert(source.guard.days['2026-10-28']==nil and source.guard.days[DATE].k=='1');assert(G:VerifySource(ID,source,IDENTITY))
end)
Test('pending day can archive before signing and a copied guard cannot inherit pending',function()
    local G,source=New();Record(G,source,{kills=1});local copied=Copy(source)
    Reject(G:SealSource(ID,copied,IDENTITY));assert(G:ArchiveDay(ID,source,DATE,IDENTITY))
    source.archive.kills='1';source.days[DATE]=nil;assert(G:SealSource(ID,source,IDENTITY));assert(source.guard.ak=='1')
end)
Test('serialized copy verifies independently and requires cold validation before advancing',function()
    local G,source=New();Record(G,source,{kills=1});assert(G:SealSource(ID,source,IDENTITY));local copy=Copy(source)
    Reject(G:Advance(ID,copy,{kills=1},DATE,IDENTITY));assert(G:VerifySource(ID,copy,IDENTITY));Record(G,copy,{deaths=1})
    assert(G:SealSource(ID,copy,IDENTITY) and G:VerifySource(ID,copy,IDENTITY));assert(source.guard.d=='0')
end)
Test('copy guard does not alias daily credentials',function()
    local G,source=New();Record(G,source,{kills=1});assert(G:SealSource(ID,source,IDENTITY))
    local copy=G:CopyGuard(source.guard);copy.days[DATE].k='900';copy.k='900';assert(source.guard.k=='1' and source.guard.days[DATE].k=='1')
end)
Test('modifying an inactive day is detected at the next cold seal without scanning it on events',function()
    local G,source,calls=New();Record(G,source,{kills=1},'2026-10-28');Record(G,source,{kills=1});assert(G:SealSource(ID,source,IDENTITY))
    source.guard.days['2026-10-28'].tag=string.rep('0',64)
    local before=calls();Record(G,source,{deaths=1});assert(calls()==before)
    Reject(G:SealSource(ID,source,IDENTITY))
end)
Test('counter overflow malformed counters and failed authentication fail without signing',function()
    local G,source=New();Record(G,source,{kills=1});assert(G:SealSource(ID,source,IDENTITY))
    for _,bad in ipairs({'01','-1','1.5','9007199254740992','1e1',true})do
        local copy=Copy(source);copy.guard.k=bad;Reject(G:VerifySource(ID,copy,IDENTITY))
        copy=Copy(source);copy.totals.kills=bad;Reject(G:VerifySource(ID,copy,IDENTITY))
    end
    local G2,s,_,S=New();Record(G2,s,{kills=1});local tag=s.guard.tag
    S.CombatHistoryAuth.HmacSha256=function()return nil,'auth unavailable'end
    Reject(G2:SealSource(ID,s,IDENTITY));assert(s.guard.tag==tag and s.guard.days[DATE].tag==nil)
    local G3=Boot();local high=Source();high.serial='9007199254740991';assert(G3:NewSource(ID,high,IDENTITY))
    Reject(G3:Advance(ID,high,{kills=1},DATE,IDENTITY));assert(high.guard.k=='0' and next(high.guard.days)==nil)
end)
Test('a failed header calculation cannot publish half of the new daily signatures',function()
    local G,source,_,S=New();Record(G,source,{kills=1},'2026-10-28');Record(G,source,{deaths=1})
    local tag=source.guard.tag;local auth=S.CombatHistoryAuth.HmacSha256;local calls=0
    S.CombatHistoryAuth.HmacSha256=function(key,text)calls=calls+1;if calls==3 then return nil end;return auth(key,text)end
    Reject(G:SealSource(ID,source,IDENTITY));assert(calls==3)
    assert(source.guard.tag==tag and source.guard.days[DATE].tag==nil and source.guard.days['2026-10-28'].tag==nil)
    S.CombatHistoryAuth.HmacSha256=auth;assert(G:SealSource(ID,source,IDENTITY));assert(G:VerifySource(ID,source,IDENTITY))
end)
Test('Merkle hash failure publishes no day tags or header and leaves pending recoverable',function()
    local G,source,_,S,hashes=New()
    Record(G,source,{kills=1},'2026-10-27');Record(G,source,{kills=1},'2026-10-28');Record(G,source,{deaths=1})
    local tag=source.guard.tag;local sha=S.CombatHistoryAuth.Sha256;local attempts=0
    S.CombatHistoryAuth.Sha256=function(text)attempts=attempts+1;if attempts==2 then return nil,'hash failure'end;return sha(text)end
    Reject(G:SealSource(ID,source,IDENTITY));assert(attempts==2 and source.guard.tag==tag)
    for _,row in pairs(source.guard.days)do assert(row.tag==nil,'partial Merkle build published a daily signature')end
    S.CombatHistoryAuth.Sha256=sha;local before=hashes();assert(G:SealSource(ID,source,IDENTITY));assert(hashes()-before==3,'failed tree nodes leaked into the approved cache')
    assert(G:VerifySource(ID,source,IDENTITY))
end)
Test('odd Merkle leaves duplicate the final leaf and unchanged branches reuse their hashes',function()
    local G,source,calls,_,hashes=New()
    Record(G,source,{kills=1},'2026-10-27');Record(G,source,{kills=1},'2026-10-28');Record(G,source,{kills=1})
    local before=hashes();assert(G:SealSource(ID,source,IDENTITY));assert(hashes()-before==3,'three leaves need two first-level nodes and one root')
    local hashBefore,macBefore=hashes(),calls();assert(G:VerifySource(ID,source,IDENTITY))
    assert(hashes()==hashBefore and calls()-macBefore==1,'unchanged odd tree was rehashed')
    Record(G,source,{deaths=1});hashBefore,macBefore=hashes(),calls();assert(G:SealSource(ID,source,IDENTITY))
    assert(hashes()-hashBefore==2 and calls()-macBefore==2,'changing the odd leaf did not reuse the unchanged left branch')
    local copy=Copy(source);copy.days={};copy.guard.days={}
    for _,date in ipairs({DATE,'2026-10-28','2026-10-27'})do copy.days[date]=Copy(source.days[date]);copy.guard.days[date]=Copy(source.guard.days[date])end
    assert(G:VerifySource(ID,copy,IDENTITY),'Merkle ordering depended on source table insertion order')
end)
Test('maximum retained day ledger keeps event work constant and signs only changed days',function()
    local G,source,calls,_,hashes=New()
    local function Date(i)local n=i-1;return string.format('%04d-%02d-%02d',2020+math.floor(n/336),math.floor(n%336/28)+1,n%28+1)end
    Record(G,source,{kills=1},Date(1))
    local function Steps(date)
        local instructions=0;debug.sethook(function()instructions=instructions+1 end,'',1)
        local ok,err=G:Advance(ID,source,{deaths=1},date,IDENTITY);debug.sethook();assert(ok,err)
        Add(source.days[date],{deaths=1});Add(source.totals,{deaths=1});source.serial=string.format('%.0f',tonumber(source.serial)+1)
        return instructions
    end
    local small=Steps(Date(1));local before=calls();local hashBefore=hashes()
    for i=2,2048 do Record(G,source,{kills=1},Date(i))end
    local large=Steps(Date(2048));assert(calls()==before,'event path did authentication work')
    assert(hashes()==hashBefore,'event path calculated a Merkle hash')
    assert(large<=small*2+100,'event work scales with retained days: '..small..' -> '..large)
    local started=os.clock();assert(G:SealSource(ID,source,IDENTITY));local cold=os.clock()-started
    assert(hashes()-hashBefore==2047,'initial 2048-leaf tree did not hash exactly its internal nodes')
    local after=calls();hashBefore=hashes();Record(G,source,{kills=1},Date(2048));started=os.clock();assert(G:SealSource(ID,source,IDENTITY));local changed=os.clock()-started
    assert(calls()-after==2,'unchanged daily credentials were recalculated')
    assert(hashes()-hashBefore==11,'changing one of 2048 stable leaves must hash only its 11 ancestors')
    assert(source.guard.k=='2049' and source.guard.d=='2' and G:VerifySource(ID,source,IDENTITY))
    hashBefore=hashes();after=calls();started=os.clock();assert(G:SealSource(ID,source,IDENTITY));local unchanged=os.clock()-started
    assert(hashes()==hashBefore and calls()-after==1,'unchanged seal recalculated day proofs or tree hashes')
    local copied=Copy(source);started=os.clock();assert(G:VerifySource(ID,copied,IDENTITY));local verify=os.clock()-started
    before=calls();hashBefore=hashes();started=os.clock();assert(G:VerifySource(ID,copied,IDENTITY));local repeated=os.clock()-started
    assert(calls()-before==1 and hashes()==hashBefore,'repeated verification ignored unchanged daily credentials or Merkle nodes')
    Reject(G:Advance(ID,source,{kills=1},'2040-01-01',IDENTITY))
    print(string.format('METRIC combat-history-guard days=2048 eventInstructions=%d/%d initialSealSeconds=%.3f changedSealSeconds=%.3f unchangedSealSeconds=%.3f initialVerifySeconds=%.3f repeatedVerifySeconds=%.3f changedHashes=11',small,large,cold,changed,unchanged,verify,repeated))
end)
print(string.format('combat-history-guard: %d passed, %d failed',passed,failed))
assert(failed==0,'combat-history-guard regression failed')
