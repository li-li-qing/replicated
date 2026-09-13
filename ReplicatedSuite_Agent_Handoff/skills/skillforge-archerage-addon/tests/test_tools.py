"""Offline tests for the skill's tools, not evidence of agent or game behavior."""
from __future__ import annotations
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import warnings
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'scripts'
sys.path.insert(0, str(SCRIPTS))

def module(case, name):
    path = SCRIPTS / (name + '.py')
    case.assertTrue(path.is_file(), 'required correctness tool is absent: ' + name)
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    sys.modules[name] = value
    spec.loader.exec_module(value)
    return value

def checksum(data):
    return f'{zlib.adler32(data):08X}'

def frames(raw, cut=100, report_id='fixture.1'):
    # Independent fixture producer; does not call the receiver implementation.
    wire = raw.replace('\\', '\\\\').replace('\r', '\\r').replace('\n', '\\n').encode()
    pieces = []
    pos = 0
    while pos < len(wire) or not pieces:
        end = min(len(wire), pos + cut)
        while end < len(wire) and 128 <= wire[end] < 192:
            end -= 1
        if end == pos and pos < len(wire):
            raise ValueError('fixture cut too small')
        pieces.append((pos, wire[pos:end])); pos = end
    result = []
    for i, (offset, data) in enumerate(pieces, 1):
        result.append((f'RS-ERROR-PAGE-1;ID={report_id};PAGE={i}/{len(pieces)};'
            f'TOTAL_BYTES={len(wire)};TOTAL_CHECK={checksum(wire)};'
            f'RAW_BYTES={len(raw.encode())};RAW_CHECK={checksum(raw.encode())};'
            f'OFFSET={offset};DATA_BYTES={len(data)};DATA_CHECK={checksum(data)};DATA=').encode()
            + data + b';RS-ERROR-PAGE-END')
    return result

def hud_text():
    rows = ['HUD_TEMPLATE_V2;META;build=fixture;viewport=1280x768;uiScale=1;source=draft;coords=screen-y-v1']
    for scope in ['PLAYER','TARGET']:
        rows += [
            f'HUD_TEMPLATE_V2;{scope};BASE;scale=1;plate{{x=0,y=-24,w=150,h=20}};info{{x=1,y=0,font=12,enabled=1,class=1,gear=1,distance=1}}',
            f'HUD_TEMPLATE_V2;{scope};AURA;buffs{{x=0,y=0,size=29,font=11,spacing=2,perRow=8,rows=2,alpha=1,enabled=1}};debuffs{{x=0,y=0,size=29,font=11,spacing=2,perRow=8,rows=2,alpha=1,enabled=1}}',
            f'HUD_TEMPLATE_V2;{scope};EQUIP;mainHand{{x=0,y=0,size=26,alpha=1,enabled=1}};offHand{{x=0,y=0,size=26,alpha=1,enabled=1}};ranged{{x=0,y=0,size=26,alpha=1,enabled=0}};wings{{x=0,y=0,size=26,alpha=1,enabled=1}}',
            f'HUD_TEMPLATE_V2;{scope};CAST;castBar{{x=0,y=0,w=120,h=7,font=12,alpha=1,enabled=1,text=1}}',
            f'HUD_TEMPLATE_V2;{scope};CLASS;class{{x=16,y=-5,size=27,alpha=1,enabled=1}}']
    return '\n'.join(['RS-HUD-TEMPLATE-2','LINES=11;PATCH=fixture'] + rows + ['RS-HUD-TEMPLATE-END'])

class ReportTests(unittest.TestCase):
    def setUp(self): self.m = module(self, 'verify_report')
    def test_roundtrip_utf8_escapes_literal_marker_and_out_of_order(self):
        raw = '甲乙\n\\n\r;RS-ERROR-PAGE-END;中文'
        pages = frames(raw, 7)
        result = self.m.decode_pages(b'\n'.join(reversed(pages)))
        self.assertEqual(result['raw'], raw)
        self.assertEqual(result['raw_check'], checksum(raw.encode()))
    def test_identical_duplicate_is_counted_not_counted_as_new_page(self):
        pages = frames('abc\nXYZ', 5)
        r = self.m.decode_pages(b'\n'.join(pages + [pages[0]]))
        self.assertEqual(r['duplicates'], 1)
        self.assertEqual(r['pages'], len(pages))
    def test_missing_mixed_conflicting_damaged_and_trailing_garbage_rejected(self):
        pages = frames('abc\nXYZ', 5)
        bad = [pages[0], b'\n'.join(pages+[frames('other',5,'other.1')[0]]),
            b'\n'.join(pages + [frames('abx\nXYZ',5)[0]]),
            b'\n'.join(pages).replace(b'DATA=abc',b'DATA=abd'), b'\n'.join(pages)+b'oops']
        for payload in bad:
            with self.subTest(payload=payload[:60]), self.assertRaises(ValueError): self.m.decode_pages(payload)
    def test_wrong_offsets_lengths_totals_and_checks_rejected(self):
        source = b'\n'.join(frames('abc\nXYZ',5))
        for old,new in [(b'OFFSET=5',b'OFFSET=4'),(b'DATA_BYTES=5',b'DATA_BYTES=4'),
                        (b'TOTAL_BYTES=8',b'TOTAL_BYTES=9'),(b'RAW_BYTES=7',b'RAW_BYTES=8'),
                        (b'RAW_CHECK=',b'RAW_CHECK=F'),(b'PAGE=1/2',b'PAGE=0/2')]:
            self.assertIn(old,source)
            with self.subTest(old=old),self.assertRaises(ValueError): self.m.decode_pages(source.replace(old,new))
    def test_invalid_escape_with_valid_wire_checksum_rejected(self):
        page = frames('xx')[0]
        page = page.replace(b'DATA=xx', b'DATA=\\q').replace(checksum(b'xx').encode(),checksum(b'\\q').encode())
        with self.assertRaises(ValueError): self.m.decode_pages(page)
    def test_display_wraps_are_removed_but_data_spaces_retained(self):
        raw='甲  乙\t\nXYZ'
        data=b'\n'.join(frames(raw,7))
        wrapped=b'\r\n'.join(data[i:i+5] for i in range(0,len(data),5))
        self.assertEqual(self.m.decode_pages(wrapped)['raw'],raw)
    def test_all_three_checksum_layers_are_required(self):
        data=frames('test-value')[0]
        import re
        for label in (b'DATA_CHECK',b'TOTAL_CHECK',b'RAW_CHECK'):
            bad=re.sub(label+rb'=[A-F0-9]{8}',label+b'=00000000',data)
            with self.subTest(layer=label),self.assertRaises(ValueError):self.m.decode_pages(bad)
    def test_empty_report_is_valid_not_omitted(self):
        self.assertEqual(self.m.decode_pages(frames('')[0])['raw'],'')
    def test_complete_hud_numeric_values_are_preserved(self):
        r = self.m.parse_hud(hud_text())
        self.assertEqual(r['scopes']['PLAYER']['BASE']['plate']['y'],-24)
        self.assertEqual(r['scopes']['TARGET']['CLASS']['class']['x'],16)
        self.assertEqual(r['meta']['source'],'draft')
    def test_hud_duplicate_missing_unknown_nonfinite_and_boolean_rejected(self):
        raw = hud_text()
        for mutated in [raw.replace('x=16,y=-5','x=16,x=5,y=-5'),raw.replace(';CLASS;class{',';OTHER;class{'),
                        raw.replace('size=27','size=NaN'),raw.replace('size=27','size=1e309'),
                        raw.replace('enabled=0','enabled=2'),raw.replace('LINES=11','LINES=10'),
                        raw.replace(';source=draft',';source=guessed'),
                        raw.replace('coords=screen-y-v1','coords=unknown'),raw+'\nextra']:
            with self.subTest(mutated=mutated[-100:]),self.assertRaises(ValueError): self.m.parse_hud(mutated)
    def test_size_limits_and_invalid_utf8(self):
        with self.assertRaises(ValueError): self.m.decode_pages(b'x'*(self.m.MAX_INPUT+1))
        with self.assertRaises(ValueError): self.m.decode_pages(frames('x')[0].replace(b'DATA=x',b'DATA=\xff'))
    def test_cli_output_no_overwrite_and_no_raw_in_stdout(self):
        with tempfile.TemporaryDirectory() as d:
            inp=Path(d)/'pages.txt';out=Path(d)/'raw.txt';inp.write_bytes(b'\n'.join(frames('private-marker')))
            p=subprocess.run([sys.executable,str(SCRIPTS/'verify_report.py'),str(inp),'--output',str(out)],capture_output=True,text=True)
            self.assertEqual(p.returncode,0,p.stderr);self.assertNotIn('private-marker',p.stdout)
            self.assertEqual(out.read_text(),'private-marker')
            p=subprocess.run([sys.executable,str(SCRIPTS/'verify_report.py'),str(inp),'--output',str(out)],capture_output=True)
            self.assertNotEqual(p.returncode,0);self.assertEqual(out.read_text(),'private-marker')

class PatchTests(unittest.TestCase):
    def setUp(self):
        self.m=module(self,'audit_patch');self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.base=Path(self.temp.name)/'base';self.new=Path(self.temp.name)/'new';self.base.mkdir();self.new.mkdir()
        for r in [self.base,self.new]:
            (r/'addon').mkdir();(r/'addon/a.lua').write_text('old');(r/'addon/keep.lua').write_text('keep')
        (self.new/'addon/a.lua').write_text('new');(self.new/'addon/b.lua').write_text('added')
    def archive(self, members=None):
        p=Path(self.temp.name)/'patch.zip'
        with zipfile.ZipFile(p,'w') as z:
            for name,value in (members or [('addon/a.lua','new'),('addon/b.lua','added')]): z.writestr(name,value)
        return p
    def audit(self,p,**kwargs):return self.m.audit_patch(self.base,self.new,p,**kwargs)
    def test_exact_delta_and_untouched_are_verified(self):
        r=self.audit(self.archive());self.assertEqual(r['changed'],['addon/a.lua']);self.assertEqual(r['added'],['addon/b.lua']);self.assertEqual(r['unchanged_count'],1)
    def test_missing_extra_unchanged_or_wrong_payload_rejected(self):
        cases=[[('addon/a.lua','new')],[('addon/a.lua','new'),('addon/b.lua','added'),('addon/keep.lua','keep')],
               [('addon/a.lua','bad'),('addon/b.lua','added')]]
        for c in cases:
            with self.subTest(c=c),self.assertRaises(ValueError):self.audit(self.archive(c))
    def test_traversal_absolute_backslash_colon_and_reserved_rejected(self):
        for name in ['../a','/a','C:/a','addon\\a','addon/a:evil','addon/CON','addon/a.','addon//a']:
            with self.subTest(name=name),self.assertRaises(ValueError):self.audit(self.archive([(name,'x')]))
    def test_duplicate_and_case_collision_rejected(self):
        for names in [['addon/a.lua','addon/a.lua'],['addon/a.lua','addon/A.lua']]:
            with warnings.catch_warnings():
                warnings.simplefilter('ignore');p=self.archive([(n,'new') for n in names])
            with self.subTest(names=names),self.assertRaises(ValueError):self.audit(p)
    def test_deleted_file_requires_explicit_exact_approval(self):
        (self.new/'addon/keep.lua').unlink();p=self.archive()
        with self.assertRaises(ValueError):self.audit(p)
        self.assertEqual(self.audit(p,approved_deletions=['addon/keep.lua'])['deleted'],['addon/keep.lua'])
        with self.assertRaises(ValueError):self.audit(p,approved_deletions=['addon/other.lua'])
    def test_private_payloads_and_symlink_zip_rejected(self):
        for name in ['addon/private.udf','addon/.env','addon/.git/config','addon/__pycache__/x.pyc']:
            with self.subTest(name=name),self.assertRaises(ValueError):self.audit(self.archive([(name,'private')]))
        p=self.archive();info=zipfile.ZipInfo('addon/link');info.create_system=3;info.external_attr=0o120777<<16
        with zipfile.ZipFile(p,'a') as z:z.writestr(info,'a.lua')
        with self.assertRaises(ValueError):self.audit(p)
    def test_directory_symlink_rejected(self):
        try:(self.new/'link').symlink_to(self.base,target_is_directory=True)
        except (OSError,NotImplementedError):self.skipTest('symlink unsupported')
        with self.assertRaises(ValueError):self.audit(self.archive())
    def test_zip_file_directory_collision_is_rejected(self):
        p=self.archive([('addon/a.lua','x'),('addon/a.lua/child','x')])
        with self.assertRaisesRegex(ValueError,'file_directory_collision'):self.m.archive_files(p)
    def test_expanded_budget_checked_before_payload_read(self):
        p=self.archive([('addon/a.lua','x'*10)])
        with mock.patch.object(self.m,'MAX_FILE',5),self.assertRaisesRegex(ValueError,'expanded_budget'):self.m.archive_files(p)
    def test_final_archive_is_read_not_assumed_from_worktree(self):
        p=self.archive();with_bad=[('addon/a.lua','old'),('addon/b.lua','added')]
        self.audit(p);p=self.archive(with_bad)
        with self.assertRaises(ValueError):self.audit(p)

class LuaTests(unittest.TestCase):
    def setUp(self):self.m=module(self,'check_lua51')
    def test_missing_interpreter_blocks_not_passes(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'a.lua';p.write_text('return 1')
            r=self.m.check_lua([p],str(Path(d)/'nonexistent'))
            self.assertEqual(r['status'],'blocked');self.assertEqual(r['checked'],0)
    def test_wrong_interpreter_version_rejected_without_compiling(self):
        fake=subprocess.CompletedProcess([],0,'Lua 5.4','')
        with mock.patch.object(self.m.shutil,'which',return_value=sys.executable), mock.patch.object(self.m.subprocess,'run',return_value=fake) as run:
            r=self.m.check_lua([ROOT/'nonexistent.lua'],'synthetic-host')
            self.assertEqual(r['status'],'blocked');self.assertEqual(r['checked'],0);self.assertEqual(run.call_count,1)
    def test_luajit_version_alias_is_not_accepted_as_puc_lua51(self):
        # Synthetic command boundary only, not an executed LuaJIT/parser test.
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'a.lua';p.write_text('return 1')
            def respond(command, **kwargs):
                version='Lua 5.1\nLuaJIT 2.1' if 'jit' in command[-1] else 'Lua 5.1'
                return subprocess.CompletedProcess(command,0,version if command[1]=='-e' else '', '')
            with mock.patch.object(self.m.shutil,'which',return_value=sys.executable),mock.patch.object(self.m.subprocess,'run',side_effect=respond):
                self.assertEqual(self.m.check_lua([p],'synthetic-luajit')['status'],'blocked')
    def test_version_probe_timeout_is_not_green(self):
        with mock.patch.object(self.m.shutil,'which',return_value=sys.executable), mock.patch.object(self.m.subprocess,'run',side_effect=subprocess.TimeoutExpired('probe',5)):
            self.assertEqual(self.m.check_lua([ROOT/'nonexistent.lua'],'synthetic-host')['status'],'blocked')
    def test_bytecode_guard_with_synthetic_version_does_not_execute(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'a.lua';p.write_bytes(b'\x1bLua')
            fake=subprocess.CompletedProcess([],0,'Lua 5.1','')
            with mock.patch.object(self.m.shutil,'which',return_value=sys.executable),mock.patch.object(self.m.subprocess,'run',return_value=fake) as run:
                r=self.m.check_lua([p],'synthetic-host');self.assertEqual(r['status'],'blocked');self.assertEqual(run.call_count,1)
    def test_no_files_is_not_green(self):
        r=self.m.check_lua([],os.environ.get('RS_TEST_LUA51','lua5.1'))
        self.assertNotEqual(r['status'],'passed')
    def test_real_lua51_compile_only_and_bad_syntax(self):
        exe=os.environ.get('RS_TEST_LUA51')
        if not exe:self.skipTest('RS_TEST_LUA51 not supplied; real parser not run')
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'a.lua';sentinel=Path(d)/'SHOULD_NOT_EXIST'
            p.write_text('local f=io.open('+json.dumps(str(sentinel))+',"w"); f:write("executed")')
            r=self.m.check_lua([p],exe);self.assertEqual(r['status'],'passed',r);self.assertFalse(sentinel.exists())
            p.write_text('local x <const> = 1');r=self.m.check_lua([p],exe);self.assertEqual(r['status'],'failed');self.assertEqual(r['checked'],1)
    def test_bytecode_rejected_before_loading(self):
        exe=os.environ.get('RS_TEST_LUA51')
        if not exe:self.skipTest('RS_TEST_LUA51 not supplied')
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'a.lua';p.write_bytes(b'\x1bLuaevil')
            r=self.m.check_lua([p],exe);self.assertNotEqual(r['status'],'passed')

class SkillTests(unittest.TestCase):
    def setUp(self):self.m=module(self,'verify_skill')
    def test_package_structure_valid(self):self.assertEqual(self.m.validate(ROOT),[])
    def test_broken_link_duplicate_case_and_eval_id_fail(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)/ROOT.name;shutil.copytree(ROOT,root,ignore=shutil.ignore_patterns('__pycache__'))
            with (root/'SKILL.md').open('a') as f:f.write('\n[broken](references/no-such-file.md)\n')
            cases=json.loads((root/'evals/behavior-cases.json').read_text());cases.append(cases[0]);(root/'evals/behavior-cases.json').write_text(json.dumps(cases))
            errors=self.m.validate(root);self.assertTrue(any('link' in e for e in errors));self.assertTrue(any('duplicate' in e for e in errors))
    def test_wrong_metadata_name_fails(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)/ROOT.name;shutil.copytree(ROOT,root,ignore=shutil.ignore_patterns('__pycache__'))
            p=root/'SKILL.md';p.write_text(p.read_text().replace('name: skillforge-archerage-addon','name: Wrong_Name'))
            self.assertTrue(self.m.validate(root))
    def test_duplicate_json_keys_are_not_silently_accepted(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)/ROOT.name;shutil.copytree(ROOT,root,ignore=shutil.ignore_patterns('__pycache__'))
            (root/'evals/invalid.json').write_text('{"a":1,"a":2}')
            self.assertTrue(any('duplicate JSON' in e for e in self.m.validate(root)))
    def test_python_syntax_error_is_detected_without_running_script(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)/ROOT.name;shutil.copytree(ROOT,root,ignore=shutil.ignore_patterns('__pycache__'))
            (root/'scripts/invalid.py').write_text('def bad(: pass')
            self.assertTrue(any('Python syntax' in e for e in self.m.validate(root)))
    def test_scenario_marked_passed_requires_real_execution_record(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)/ROOT.name;shutil.copytree(ROOT,root,ignore=shutil.ignore_patterns('__pycache__'))
            p=root/'evals/behavior-cases.json';rows=json.loads(p.read_text());rows[-1]['execution_status']='passed';p.write_text(json.dumps(rows))
            self.assertTrue(any('not an execution record' in e for e in self.m.validate(root)))
    def test_new_routes_and_behavior_specs_present_not_claimed_executed(self):
        for ref in ['pvp-hud-and-freshness.md','boss-alert-clock-and-layout.md','hud-template-and-defaults.md','verification-tools.md']:
            self.assertTrue((ROOT/'references'/ref).is_file(),ref)
        cases=json.loads((ROOT/'evals/behavior-cases.json').read_text())
        new=[x for x in cases if int(x['id'].split('-')[-1])>=27]
        self.assertGreaterEqual(len(new),20)
        for x in new:self.assertEqual(x['execution_status'],'not_run');self.assertTrue(x['rubric']['critical_failures'])

if __name__=='__main__':unittest.main()
