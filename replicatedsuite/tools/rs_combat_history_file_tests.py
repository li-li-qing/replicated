# Replicated Suite · 战斗历史文件往返测试
# 作者：Replicated
# QQ群：1104129461
"""真实Lua信箱 -> Python/发行exe TXT -> 待导入数据 -> 真实Lua Authority，无编辑框参与。"""
from pathlib import Path
import os
import shutil
import subprocess
import struct
import tempfile
import unittest
import zlib
from unittest.mock import patch

import rs_diagnostic_file_export as exporter

ROOT = Path(__file__).resolve().parents[1]


def write_udf(folder, records):
    """生成活动Manifest/WAL夹具；不在玩家UDF上运行。"""
    def var(number):
        data = bytearray()
        while number > 127:
            data.append((number & 127) | 128)
            number >>= 7
        data.append(number)
        return bytes(data)
    def field(data):
        return var(len(data)) + data
    def log(data):
        out = bytearray()
        for offset in range(0, len(data), 32761):
            part = data[offset:offset + 32761]
            final = offset + len(part) == len(data)
            kind = (1 if final else 2) if offset == 0 else (4 if final else 3)
            out.extend(struct.pack('<IHB', exporter.masked_crc(bytes([kind]) + part), len(part), kind) + part)
        return bytes(out)
    folder.mkdir(parents=True)
    (folder / 'CURRENT').write_bytes(b'MANIFEST-000001\n')
    (folder / 'MANIFEST-000001').write_bytes(log(b'\x01' + field(b'leveldb.BytewiseComparator') + b'\x02\x01'))
    batch = struct.pack('<QI', 1, len(records))
    for key, row in records.items():
        batch += b'\x01' + field(key) + field(row[2])
    (folder / '000001.log').write_bytes(log(batch))


class HistoryFileTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = shutil.which('lua5.1') or shutil.which('lua')
        if not cls.lua:
            raise AssertionError('real Lua 5.1 is required')
        cls.temp = tempfile.TemporaryDirectory()
        fixture = Path(cls.temp.name) / 'native.bin'
        run = subprocess.run([cls.lua, 'tools/rs_combat_history_transfer_tests.lua', '--emit-file', str(fixture)],
                             cwd=ROOT, capture_output=True)
        if run.returncode:
            raise AssertionError(run.stdout + run.stderr)
        cls.records = {}
        with fixture.open('rb') as stream:
            while key := stream.readline().rstrip(b'\n'):
                size = int(stream.readline())
                cls.records[key] = (1, 1, stream.read(size))

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def export_txt(self, folder):
        with patch.object(exporter, 'history_folder', return_value=folder):
            return exporter.save_report(Path(self.temp.name), kind='history', _records=self.records)

    def consume(self, prepared):
        run = subprocess.run([self.lua, 'tools/rs_combat_history_transfer_tests.lua', '--consume-file', str(prepared)],
                             cwd=ROOT, capture_output=True)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn(b'HISTORY TXT ROUNDTRIP PASS', run.stdout)

    def test_complete_txt_roundtrip_never_uses_editor_or_writes_database(self):
        self.assertTrue(hasattr(exporter, 'history_folder'), 'history TXT file sink is missing')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = self.export_txt(root / '战斗历史')
            self.assertGreater(target.stat().st_size, 16383, 'fixture does not cross the real Native cap')
            self.assertTrue(target.read_bytes().startswith(b'RSCH-FILE-1|'))
            self.assertEqual(self.export_txt(root / '战斗历史'), target, 'same snapshot was saved twice')
            with patch.object(exporter, 'addon_root', return_value=root):
                prepared = exporter.prepare_history_import(target)
            self.assertEqual(prepared, root / 'replicatedsuite/data/rs_combat_history_import.lua')
            self.consume(prepared)

    def test_bom_and_windows_line_endings_roundtrip_without_copying(self):
        self.assertTrue(hasattr(exporter, 'prepare_history_import'), 'history TXT preparation is missing')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = self.export_txt(root / '战斗历史')
            target.write_bytes(b'\xef\xbb\xbf' + target.read_bytes().replace(b'\n', b'\r\n'))
            with patch.object(exporter, 'addon_root', return_value=root):
                self.consume(exporter.prepare_history_import(target))

    def test_rejected_file_preserves_the_previous_prepared_file(self):
        self.assertTrue(hasattr(exporter, 'prepare_history_import'), 'history TXT preparation is missing')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = self.export_txt(root / '战斗历史')
            with patch.object(exporter, 'addon_root', return_value=root):
                prepared = exporter.prepare_history_import(target)
                previous = prepared.read_bytes()
                target.write_bytes(target.read_bytes()[:-1])
                with self.assertRaises(ValueError):
                    exporter.prepare_history_import(target)
                self.assertEqual(prepared.read_bytes(), previous)

    def test_history_pages_do_not_accept_the_diagnostic_protocol(self):
        self.assertTrue(hasattr(exporter, 'HISTORY_MAILBOX'), 'separate history mailbox is missing')
        records = dict(self.records)
        key = next(k for k in records if k.endswith(exporter.HISTORY_MAILBOX))
        row = records[key]
        records[key] = (row[0], row[1], row[2].replace(b'RS-COMBAT-HISTORY-FILE-1', b'RS-DIAGNOSTIC-FILE-2'))
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(exporter, 'history_folder', return_value=Path(directory)):
                with self.assertRaises(ValueError):
                    exporter.save_report(Path(directory), kind='history', _records=records)
            self.assertEqual(list(Path(directory).glob('*.txt')), [])

    def test_input_code_remains_data_and_is_rejected_by_the_history_parser(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = self.export_txt(root / '战斗历史')
            _, _, payload = target.read_bytes().partition(b'\n')
            payload = payload[:-3] + b'_G.HISTORY_EXECUTED=true\nEND'
            target.write_bytes(f'RSCH-FILE-1|{zlib.adler32(payload):08X}|{len(payload)}\n'.encode() + payload)
            with patch.object(exporter, 'addon_root', return_value=root):
                prepared = exporter.prepare_history_import(target)
            self.assertNotIn(b'HISTORY_EXECUTED', prepared.read_bytes(), 'input code escaped the HEX data')
            run = subprocess.run([self.lua, 'tools/rs_combat_history_transfer_tests.lua', '--reject-file', str(prepared)],
                                 cwd=ROOT, capture_output=True)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn(b'HISTORY TXT REJECTION PASS', run.stdout)

    def test_receiver_saves_both_types_and_recovers_a_deleted_history_folder(self):
        records = dict(self.records)
        data = '完整中文诊断\n'.encode()
        raw = (f'isTable true\nstr_protocol str_RS-DIAGNOSTIC-FILE-1\nstr_report_id str_diag\n'
               f'str_byte_count str_{len(data)}\nstr_chunk_count str_1\nstr_checksum str_{zlib.adler32(data):08X}\n'
               f'str_c0001 str_{data.hex().upper()}\n').encode()
        records[b'account:' + exporter.MAILBOX] = (1, 1, raw)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            udf, reports, history = root / 'USER1/udf', root / '诊断报告', root / '战斗历史'
            write_udf(udf, records)
            cycles = []
            def next_cycle(_):
                cycles.append(1)
                self.assertEqual(next(reports.glob('*.txt')).read_bytes(), data)
                self.assertTrue(next(history.glob('*.txt')).read_bytes().startswith(b'RSCH-FILE-1|'))
                if len(cycles) == 1:
                    shutil.rmtree(history)
                else:
                    (reports / '.stop-receiver').write_text('stop')
            with patch.object(exporter, 'report_folder', return_value=reports), \
                 patch.object(exporter, 'history_folder', return_value=history), \
                 patch.object(exporter.time, 'sleep', side_effect=next_cycle):
                exporter.watch(root, udf)
            self.assertEqual(len(cycles), 2)

    def test_portable_executable_prepares_from_its_own_install_directory(self):
        self.assertTrue(hasattr(exporter, 'prepare_history_import'), 'history TXT preparation is missing')
        with tempfile.TemporaryDirectory() as directory:
            game = Path(directory) / '其他电脑 中文路径'
            tools = game / 'Addon/replicatedsuite/tools'
            tools.mkdir(parents=True)
            exe = tools / 'RS-Diagnostic-Exporter.exe'
            shutil.copy2(ROOT / 'tools' / exe.name, exe)
            target = self.export_txt(game / 'Addon/战斗历史')
            env = dict(os.environ, PATH=os.environ['SystemRoot'] + '\\System32', USERPROFILE=str(game / '空白用户'))
            for name in ('PYTHONPATH', 'PYTHONHOME'):
                env.pop(name, None)
            udf = game / 'USER1/udf'
            write_udf(udf, self.records)
            previous_files = set(target.parent.glob('*.txt'))
            run = subprocess.run([str(exe), '--history'], cwd=directory, env=env,
                                 capture_output=True, timeout=25)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            created_files = set(target.parent.glob('*.txt')) - previous_files
            self.assertEqual(len(created_files), 1, 'portable tool did not create its own verified TXT')
            self.assertEqual(next(iter(created_files)).read_bytes(), target.read_bytes())
            run = subprocess.run([str(exe), '--import-history', str(target)], cwd=directory, env=env,
                                 capture_output=True, timeout=25)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            prepared = tools.parent / 'data/rs_combat_history_import.lua'
            self.assertTrue(prepared.is_file())
            self.consume(prepared)

    def test_honor_v3_txt_prepares_and_imports_through_python_and_portable_tool(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            native = root / 'honor-native.bin'
            run = subprocess.run([self.lua, 'tools/rs_combat_history_transfer_tests.lua', '--emit-file', str(native), 'honor'],
                                 cwd=ROOT, capture_output=True)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            records = {}
            with native.open('rb') as stream:
                while key := stream.readline().rstrip(b'\n'):
                    records[key] = (1, 1, stream.read(int(stream.readline())))
            with patch.object(exporter, 'history_folder', return_value=root / 'history'):
                target = exporter.save_report(root, kind='history', _records=records)
            self.assertIn(b'RS-HISTORY-3|', target.read_bytes())
            tools = root / 'Addon/replicatedsuite/tools'
            tools.mkdir(parents=True)
            with patch.object(exporter, 'addon_root', return_value=tools.parent.parent):
                prepared = exporter.prepare_history_import(target)
            for portable in (False, True):
                if portable:
                    exe = tools / 'RS-Diagnostic-Exporter.exe'
                    shutil.copy2(ROOT / 'tools' / exe.name, exe)
                    run = subprocess.run([str(exe), '--import-history', str(target)], cwd=root,
                                         capture_output=True, timeout=25)
                    self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                run = subprocess.run([self.lua, 'tools/rs_combat_history_transfer_tests.lua', '--consume-file', str(prepared), 'honor'],
                                     cwd=ROOT, capture_output=True)
                self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_protected_v4_txt_roundtrips_through_python_and_portable_tool(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            native = root / 'protected-native.bin'
            run = subprocess.run([self.lua, 'tools/rs_combat_history_transfer_tests.lua', '--emit-file', str(native), 'guard'],
                                 cwd=ROOT, capture_output=True)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            records = {}
            with native.open('rb') as stream:
                while key := stream.readline().rstrip(b'\n'):
                    records[key] = (1, 1, stream.read(int(stream.readline())))
            with patch.object(exporter, 'history_folder', return_value=root / 'history'):
                target = exporter.save_report(root, kind='history', _records=records)
            self.assertIn(b'RS-HISTORY-4|', target.read_bytes())
            tools = root / 'Addon/replicatedsuite/tools'
            tools.mkdir(parents=True)
            with patch.object(exporter, 'addon_root', return_value=tools.parent.parent):
                prepared = exporter.prepare_history_import(target)
            for portable in (False, True):
                if portable:
                    exe = tools / 'RS-Diagnostic-Exporter.exe'
                    shutil.copy2(ROOT / 'tools' / exe.name, exe)
                    run = subprocess.run([str(exe), '--import-history', str(target)], cwd=root,
                                         capture_output=True, timeout=25)
                    self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                run = subprocess.run([self.lua, 'tools/rs_combat_history_transfer_tests.lua', '--consume-file', str(prepared), 'guard'],
                                     cwd=ROOT, capture_output=True)
                self.assertEqual(run.returncode, 0, run.stdout + run.stderr)


if __name__ == '__main__':
    unittest.main()
