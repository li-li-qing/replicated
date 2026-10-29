"""真实 Lua 5.1 + Persistence + History/Transfer；Native仅为内存盘，非RU验收。"""
import os
from pathlib import Path
import unittest
from lupa.lua51 import LuaRuntime

ROOT=Path(__file__).resolve().parents[1]
HOST=r'''
math.randomseed(TEST_SEED or 1)
h=dofile('tools/rs_gear_page_test_host.lua')({disk=TEST_DISK})
local S=h.S
S.Features.CombatAnalytics={}
S.Services.CombatAnalyticsV3={RegisterMetric=function()return true end,GetCollectionScope=function()return 'self'end}
S.Services.UnitIdentityV3={player={name='GearTest',nameWithWorld='GearTest@World',id='self-id'}}
h.date={year=2026,month=10,day=29,hour=8,minute=30}
S.Utils.GetServerTime=function()return h.date end
if TEST_ROLE then X2Unit.UnitNameWithWorld=function()return TEST_ROLE end;S.Services.UnitIdentityV3.player.nameWithWorld=TEST_ROLE end
dofile('core/rs_report_copy_transport.lua');dofile('core/rs_diagnostic_export.lua')
if TEST_MODIFIED_HISTORY then assert(loadstring(TEST_MODIFIED_HISTORY))() else dofile('features/combat/analytics/rs_combat_personal_history.lua') end
if not TEST_LEGACY then
 dofile('core/rs_combat_history_auth.lua');dofile('features/combat/analytics/rs_combat_history_guard.lua')
end
dofile('features/combat/analytics/rs_combat_history_transfer.lua')
h.H=S.Features.CombatAnalytics.PersonalHistory;h.P=S.Persistence
assert(h.H:EnsureLoaded())
function h:Record(k,d)for i=1,k or 0 do assert(self.H:Record({kills=1}))end;for i=1,d or 0 do assert(self.H:Record({deaths=1}))end end
function h:Save()assert(self.P:SaveStore(self.H.StoreId,{durable=true}))end
function h:Export()return assert(self.H:ExportTransfer())end
function h:Import(packet)
 for _,part in ipairs(packet.parts)do
  local ok,r=self.H:ImportTransfer(part);assert(ok,r)
  if r.requiresConfirmation then ok,r=self.H:ImportTransfer(part,{confirmPackageId=r.packageId});assert(ok,r) end
 end
end
'''

def plain(v):
    if hasattr(v,'items'):return {k:plain(x) for k,x in v.items()}
    return v

class HistoryProtectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.before=Path.cwd();os.chdir(ROOT)
    @classmethod
    def tearDownClass(cls):os.chdir(cls.before)
    def boot(self,disk=None,legacy=False,seed=1,role=None,modified=None):
        lua=LuaRuntime(unpack_returned_tuples=True)
        lua.globals().TEST_DISK=lua.table_from(disk or {},recursive=True)
        lua.globals().TEST_MODIFIED_HISTORY=modified
        lua.globals().TEST_LEGACY=legacy;lua.globals().TEST_SEED=seed;lua.globals().TEST_ROLE=role
        lua.execute(HOST);return lua
    def disk(self,lua):return plain(lua.globals().h.disk)
    def packet(self,lua,packet):return lua.table_from(plain(packet),recursive=True)

    def test_identical_legacy_baseline_and_two_computers_merge_today_and_total_exactly_once(self):
        old=self.boot(legacy=True);old.execute('h:Record(100,8);h:Save()')
        disk=self.disk(old);a=self.boot(disk,seed=11);b=self.boot(disk,seed=22)
        a.execute('h:Record(10,1)');b.execute('h:Record(5,2)')
        pa=a.globals().h.Export(a.globals().h);pb=b.globals().h.Export(b.globals().h)
        a.globals().OTHER=self.packet(a,pb);a.execute('h:Import(OTHER);h:Import(OTHER)')
        pa=a.globals().h.Export(a.globals().h);b.globals().OTHER=self.packet(b,pa)
        b.execute('h:Import(OTHER);h:Import(OTHER);local p=h.H:GetProjection();assert(p.totals.kills==115 and p.totals.deaths==11);assert(p.todayDate=="2026-10-29");assert(p.rows[1].kills==115);assert(p.protection.protectedKills==15 and p.protection.legacyKills==100)')
        reloaded=self.boot(self.disk(b),seed=22)
        reloaded.execute('local p=h.H:GetProjection();assert(p.totals.kills==115 and p.totals.deaths==11);assert(p.protection.legacyKills==100)')

    def test_invalid_increment_does_not_change_history_or_write(self):
        l=self.boot();l.execute('''
        h:Record(1,1);local writes,revision=h.writes,h.H.revision
        for _,value in ipairs({100,-1,0.5,'1',math.huge})do
         local ok=h.H:Record({kills=value});assert(not ok,'invalid kill increment accepted')
         ok=h.H:Record({deaths=value});assert(not ok,'invalid death increment accepted')
        end
        assert(h.H.revision==revision and h.writes==writes);local p=h.H:GetProjection();assert(p.totals.kills==1 and p.totals.deaths==1)
        ''')

    def test_simple_live_total_or_source_tampering_is_not_automatically_resigned(self):
        for field in ('top','source','day','guard','removed'):
            l=self.boot();l.globals().EDIT=field;l.execute('''
            h:Record(1,1);h:Save();local before=h.writes
            local s=h.H.state.sync.sources[h.H.state.sync.localId]
            if EDIT=='top' then h.H.state.totals.kills=100
            elseif EDIT=='source' then s.totals.kills='100'
            elseif EDIT=='day' then s.days['2026-10-29'].kills='100'
            elseif EDIT=='guard' then s.guard.k='100'
            else s.guard=nil end
            local p=h.H:GetProjection();assert(not p.available,'tampered live data was displayed as valid')
            local packet=h.H:ExportTransfer();assert(not packet,'tampered live data was resigned/exported')
            assert(h.writes==before,'tampered live data reached Native save')
            ''')

    def test_recomputed_transport_checksum_cannot_authenticate_modified_protected_counts(self):
        source=self.boot();source.execute('h:Record(2,1);PACKET=h:Export()')
        target=self.boot(seed=33);target.globals().PACKET=self.packet(target,source.globals().PACKET)
        target.execute('''
        local p=PACKET;local payload=p.payload:gsub('T|2,','T|200,',1)
        assert(payload~=p.payload);local c=h.S.ReportCopyTransport
        local hash=c:CopyChecksum(payload);local parts={}
        for i=1,#payload,7000 do local text=payload:sub(i,i+6999);parts[#parts+1]=text end
        local writes=h.writes;local rejected=false
        for i,text in ipairs(parts)do
         local wire=table.concat({'RSCH1',hash,#payload,i,#parts,#text,c:CopyChecksum(text)},'|')..'\\n'..text
         local ok=h.H:ImportTransfer(wire);if not ok then rejected=true;break end
        end
        assert(rejected and h.writes==writes and h.H:GetProjection().totals.kills==0)
        ''')

    def test_failed_merge_preserves_original_and_retry_is_exactly_once(self):
        a=self.boot(seed=1);b=self.boot(seed=2);a.execute('h:Record(3,1);PACKET=h:Export()');b.execute('h:Record(2,1);h:Save()')
        b.globals().PACKET=self.packet(b,a.globals().PACKET)
        b.execute('''
        h.failSave=true
        for _,part in ipairs(PACKET.parts)do local ok=h.H:ImportTransfer(part);assert(not ok)end
        h.failSave=false;assert(h.H:GetProjection().totals.kills==2)
        h:Import(PACKET);h:Import(PACKET);assert(h.H:GetProjection().totals.kills==5)
        ''')

    def test_server_day_unknown_and_foreign_character_are_kept_distinct(self):
        a=self.boot();a.execute('h:Record(2,1);h.date.day=30;h.ms=h.ms+2000;h:Record(1,0);local p=h.H:GetProjection({fromDate="2026-10-30",toDate="2026-10-30"});assert(p.totals.kills==1 and p.protection.protectedKills==1);h.date=nil;h.ms=h.ms+2000;h:Record(1,0);assert(h.H:GetProjection().todayDate==nil);PACKET=h:Export()')
        b=self.boot(role='Other@World');b.globals().PACKET=self.packet(b,a.globals().PACKET)
        b.execute('local writes=h.writes;for _,part in ipairs(PACKET.parts)do local ok=h.H:ImportTransfer(part);assert(not ok)end;assert(h.writes==writes)')

    def test_genuine_schema1_old_fingerprint_and_all_counts_survive_guard_upgrade(self):
        l=self.boot();l.execute('''
        local store=h.P:GetStore(h.H.StoreId);local key=h.P:ResolveStoreKey(store)
        h.disk[key]=dofile('tools/fixtures/combat_history_schema1_20261007.lua')
        local stamped=h.disk[key].__rsmeta.encodedFingerprint
        store.loaded=false;h.H.loaded=false;assert(h.H:EnsureLoaded())
        local p=h.H:GetProjection();assert(p.totals.kills==2 and p.totals.deaths==2 and p.totals.damage==700)
        assert(p.protection.legacyKills==2 and p.protection.protectedKills==0)
        assert(h.disk[key].__rsmeta.encodedFingerprint==stamped,'read rewrote the old fingerprint')
        h:Record(1,1);h:Save();store.loaded=false;h.H.loaded=false;assert(h.H:EnsureLoaded())
        p=h.H:GetProjection();assert(p.totals.kills==3 and p.totals.deaths==3 and p.totals.damage==700)
        assert(p.protection.legacyKills==2 and p.protection.protectedKills==1)
        ''')

    def test_older_protected_snapshot_is_ignored_and_cloned_local_source_conflict_is_rejected(self):
        a=self.boot(seed=11);a.execute('h:Record(2,1);OLD=h:Export();h:Save()')
        copied=self.disk(a);b=self.boot(copied,seed=22)
        a.execute('h:Record(1,0);NEW=h:Export()');b.execute('h:Record(0,1)')
        b.globals().PACKET=self.packet(b,a.globals().NEW)
        b.execute('''
        local writes=h.writes
        for _,part in ipairs(PACKET.parts)do local ok=h.H:ImportTransfer(part);assert(not ok,'forked local source was overwritten')end
        local p=h.H:GetProjection();assert(h.writes==writes and p.totals.kills==2 and p.totals.deaths==2)
        ''')
        c=self.boot(seed=33);c.globals().NEW=self.packet(c,a.globals().NEW);c.globals().OLD=self.packet(c,a.globals().OLD)
        c.execute('h:Import(NEW);local writes=h.writes;h:Import(OLD);assert(h.writes==writes and h.H:GetProjection().totals.kills==3)')

    def test_guarded_history_archives_full_day_retention_and_reloads_from_shared_paging(self):
        l=self.boot();l.execute('''
        for i=1,2049 do
         local n=i-1;h.date={year=2020+math.floor(n/336),month=math.floor((n%336)/28)+1,day=n%28+1,hour=8,minute=30}
         h.ms=h.ms+2000;h:Record(1,0)
        end
        local p=h.H:GetProjection();assert(p.totals.kills==2049 and #p.rows==2048 and p.archive.kills==1)
        assert(p.protection.protectedKills==2049 and p.protection.legacyKills==0)
        h:Save();local store=h.P:GetStore(h.H.StoreId)
        assert(h.disk[store.resolvedKey].__rsPaged,'long protected history was not safely paged')
        store.loaded=false;h.H.loaded=false;assert(h.H:EnsureLoaded())
        p=h.H:GetProjection();assert(p.totals.kills==2049 and #p.rows==2048 and p.archive.kills==1)
        ''')

    def test_full_sixteen_legacy_sources_keep_export_capacity_after_protected_upgrade(self):
        old=self.boot(legacy=True);old.execute('''
        h:Record(1,0);h:Export()
        local state=h.H.state;local empty=state.sync.sources[state.sync.localId]
        for i=3,16 do state.sync.sources['d-old-'..i]=h.Copy(empty)end
        h.H.state=h.H:NormalizeState(state);h:Save()
        ''')
        fresh=self.boot(self.disk(old),seed=2)
        fresh.execute('''
        h:Record(1,0);h:Save();local packet=h:Export()
        local n=0;for _ in pairs(h.H.state.sync.sources)do n=n+1 end
        assert(n==17 and h.H:GetProjection().totals.kills==2)
        assert(packet.payload:match('^RS%-HISTORY%-4|'))
        ''')

    def test_changing_normal_counter_code_to_plus_one_hundred_cannot_export_valid_history(self):
        source=(ROOT/'features/combat/analytics/rs_combat_personal_history.lua').read_text(encoding='utf-8-sig')
        original='local amount=Counter(delta[key])'
        self.assertIn(original,source)
        modified=source.replace(original,"local amount=key=='kills' and 100 or Counter(delta[key])",1)
        l=self.boot(modified=modified)
        l.execute('''
        assert(h.H:Record({kills=1}));assert(h.H.state.totals.kills==100,'fault model did not alter normal counting')
        local writes=h.writes;assert(not h.H:GetProjection().available)
        assert(not h.H:ExportTransfer());assert(h.writes==writes,'modified counter code produced a valid saved/exported count')
        ''')

    def test_healthy_schema_migration_keeps_normal_debounce(self):
        l=self.boot(legacy=True)
        l.execute('''
        h:Record(1,0);local store=h.P:GetStore(h.H.StoreId)
        store.schemaVersion=5;h:Save();store.schemaVersion=6
        store.loaded=false;h.H.loaded=false;assert(h.H:EnsureLoaded())
        assert(store.dirty and store.lastDirtyReason=='migration')
        assert(store.dueAt>h.ms,'healthy migration unexpectedly became immediate repair')
        assert(h.H:GetProjection().totals.kills==1)
        ''')

    def test_today_query_reads_server_clock_explicitly_and_projections_remain_read_only(self):
        l=self.boot();l.execute('''
        h:Record(1,0);local queries=0
        h.S.Utils.GetServerTime=function()queries=queries+1;return h.date end
        h.ms=h.ms+2000;h.date.day=30
        local p=h.H:GetProjection();assert(queries==0 and p.todayDate=='2026-10-29','getter sampled Native clock')
        local date=h.S.Features.CombatAnalytics.Commands:GetPersonalHistoryToday()
        assert(date=='2026-10-30' and queries==1)
        assert(h.H:GetProjection().todayDate=='2026-10-30' and queries==1)
        h.date=nil;date=h.S.Features.CombatAnalytics.Commands:GetPersonalHistoryToday()
        assert(date==nil and queries==2,'unknown clock fabricated a date')
        ''')

if __name__=='__main__':unittest.main()
