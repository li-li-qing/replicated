"""中文维护：文件出口须保留完整中文与换行，拒绝缺块/校验错误和不支持的磁盘格式。"""
import importlib.util
from pathlib import Path
import unittest
import zlib
import tempfile
import struct
import subprocess
import shutil
import os
import time
from unittest.mock import patch

class ExportTests(unittest.TestCase):
    def test_exporter_available(self):
        self.assertTrue(Path(__file__).with_name('rs_diagnostic_file_export.py').exists(), 'txt extractor is missing')

    def test_portable_executable_uses_install_location_not_unpack_directory(self):
        import rs_diagnostic_file_export as exporter
        entry = Path('D:/玩家目录/ArcheRage/Addon/replicatedsuite/tools/RS-Diagnostic-Exporter.exe').resolve()
        with patch.object(exporter.sys, 'frozen', True, create=True), patch.object(exporter.sys, 'executable', str(entry)):
            self.assertEqual(exporter.addon_root(), entry.parents[2])
            self.assertEqual(exporter.report_folder(), entry.parents[2] / '诊断报告')

    def test_distribution_launchers_need_no_python_or_codex(self):
        root = Path(__file__).resolve().parents[1]
        for name in ('导出诊断.cmd', '开始自动保存诊断.cmd', '停止自动保存诊断.cmd'):
            text = (root / name).read_text(encoding='utf-8')
            self.assertIn('RS-Diagnostic-Exporter.exe', text)
            self.assertNotIn('.cache', text)
            self.assertNotIn('python.exe', text)
        self.assertTrue((root / 'tools/RS-Diagnostic-Exporter.exe').is_file())

    def test_native_text_complete_and_corrupt(self):
        from rs_diagnostic_file_export import decode_mailbox
        raw = '中文阻断\n[FAILED_CHECK]\n' * 60
        data = raw.encode('utf-8')
        checksum = f'{zlib.adler32(data):08X}'
        text = f'str_protocol str_RS-DIAGNOSTIC-FILE-1 .. str_report_id str_test .. str_byte_count str_{len(data)} .. str_chunk_count str_2 .. str_checksum str_{checksum} .. str_chunks isTable true .. str_g0001 isTable true .. str_c0001 str_{data[:1024].hex().upper()} .. str_c0002 str_{data[1024:].hex().upper()}'
        self.assertEqual(decode_mailbox(text)[0], data)
        with self.assertRaises(ValueError):
            decode_mailbox(text.replace('str_c0002', 'str_c0003'))
        with self.assertRaises(ValueError):
            decode_mailbox(text.replace(checksum, '00000000'))

    def test_snappy_overlap_and_bounds(self):
        from rs_diagnostic_file_export import snappy
        self.assertEqual(snappy(bytes([5, 0, 65, 1, 1])), b'AAAAA')
        with self.assertRaises(ValueError):
            snappy(bytes([5, 1, 1]))

    def test_real_lua_native_cap_paged_chinese_report(self):
        from rs_diagnostic_file_export import MAILBOX, decode_mailbox
        lua = shutil.which('lua')
        self.assertIsNotNone(lua, 'Lua 5.1 is required for the real writer/reader boundary check')
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / 'native.bin'
            result = subprocess.run([lua, 'tools/rs_diagnostic_export_tests.lua', str(fixture)],
                                    cwd=Path(__file__).resolve().parents[1], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            records, expected = {}, None
            with fixture.open('rb') as stream:
                while name := stream.readline().rstrip(b'\n'):
                    size = int(stream.readline())
                    raw = stream.read(size)
                    if name == b'__REPORT__':
                        expected = raw
                    else:
                        self.assertLess(len(raw), 9000)
                        records[b'account:addon_replicatedsuite_' + name] = (1, 1, raw)
            key = b'account:' + MAILBOX
            manifest = records[key][2].decode()
            actual, identity = decode_mailbox(manifest, records, key)
            self.assertGreater(len(actual), 16383)
            self.assertEqual(actual, expected)
            self.assertEqual(identity, 'test.3')
            # 中文维护：只复制发行 exe 到有中文/空格的新玩家目录；禁用开发环境 PATH，
            # 用真实 Lua 分页原文构造活动 WAL，验证默认账号定位、输出位置及删除后的恢复。
            from rs_diagnostic_file_export import masked_crc
            game = Path(directory) / '其他玩家 游戏目录'
            tools = game / 'Addon/replicatedsuite/tools'
            tools.mkdir(parents=True)
            exe = tools / 'RS-Diagnostic-Exporter.exe'
            shutil.copy2(Path(__file__).with_name(exe.name), exe)
            udf = game / 'USER1/udf'
            udf.mkdir(parents=True)
            def var(number):
                data = bytearray()
                while number > 127:
                    data.append((number & 127) | 128); number >>= 7
                data.append(number)
                return bytes(data)
            def field(data):
                return var(len(data)) + data
            def physical_log(data):
                out = bytearray()
                offset = 0
                while offset < len(data):
                    part = data[offset:offset + 32761]
                    final = offset + len(part) == len(data)
                    kind = (1 if final else 2) if offset == 0 else (4 if final else 3)
                    out.extend(struct.pack('<IHB', masked_crc(bytes([kind]) + part), len(part), kind) + part)
                    offset += len(part)
                return bytes(out)
            (udf / 'CURRENT').write_bytes(b'MANIFEST-000001\n')
            (udf / 'MANIFEST-000001').write_bytes(physical_log(b'\x01' + field(b'leveldb.BytewiseComparator') + b'\x02\x01'))
            batch = struct.pack('<QI', 1, len(records))
            for record_key, record in records.items():
                batch += b'\x01' + field(record_key) + field(record[2])
            (udf / '000001.log').write_bytes(physical_log(batch))
            env = dict(os.environ, PATH=os.environ['SystemRoot'] + '\\System32', USERPROFILE=str(game / '空白用户'))
            for name in ('PYTHONPATH', 'PYTHONHOME'):
                env.pop(name, None)
            run = subprocess.run([str(exe)], cwd=directory, env=env, capture_output=True, timeout=20)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            reports = game / 'Addon/诊断报告'
            self.assertEqual(next(reports.glob('*.txt')).read_bytes(), expected)
            # 完整目录被清空且 WAL 未变时，实际 exe 接收器恢复文件，重复启动不会抢锁。
            log_path = Path(directory) / 'receiver.log'
            def wait_for_report():
                deadline = time.monotonic() + 12
                while time.monotonic() < deadline:
                    files = list(reports.glob('*.txt'))
                    if files and files[0].read_bytes() == expected:
                        return
                    time.sleep(.1)
                self.fail(log_path.read_text(encoding='utf-8'))
            with log_path.open('wb') as stream:
                receiver = subprocess.Popen([str(exe), '--watch'], cwd=directory, env=env, stdout=stream, stderr=stream)
                try:
                    # 先删除单次导出的旧报告，避免把尚未启动接收器误当成通过。
                    shutil.rmtree(reports)
                    wait_for_report()
                    duplicate = subprocess.run([str(exe), '--watch'], cwd=directory, env=env, capture_output=True, timeout=12)
                    self.assertEqual(duplicate.returncode, 0, duplicate.stdout + duplicate.stderr)
                    self.assertIn('已在运行', duplicate.stdout.decode('utf-8'))
                    shutil.rmtree(reports)
                    wait_for_report()
                    stop = subprocess.run([str(exe), '--stop'], cwd=directory, env=env, capture_output=True, timeout=12)
                    self.assertEqual(stop.returncode, 0, stop.stdout + stop.stderr)
                    self.assertEqual(receiver.wait(timeout=12), 0)
                finally:
                    if receiver.poll() is None:
                        receiver.terminate(); receiver.wait(timeout=12)
            page_key = key + b'_page_0001'
            page = records.pop(page_key)
            with self.assertRaisesRegex(ValueError, 'missing export page'):
                decode_mailbox(manifest, records, key)
            records[page_key] = (1, 1, page[2][:-20])
            with self.assertRaises(ValueError):
                decode_mailbox(manifest, records, key)
            records[page_key] = (1, 1, page[2].replace(b'str_report_checksum str_', b'str_report_checksum str_DEAD'))
            with self.assertRaisesRegex(ValueError, 'still being saved'):
                decode_mailbox(manifest, records, key)
            # 中文维护：旧单 key 实机截断不能被恢复成“完整报告”，继续拒绝伪成功。
            with self.assertRaises(ValueError):
                decode_mailbox(manifest[:80], records, key)

    def test_live_manifest_sst_wal_txt_end_to_end(self):
        from rs_diagnostic_file_export import MAILBOX, masked_crc, read_database, save_report
        def var(value):
            out = bytearray()
            while value > 127:
                out.append((value & 127) | 128); value >>= 7
            out.append(value); return bytes(out)
        def field(data):
            return var(len(data)) + data
        def log(data):
            return struct.pack('<IHB', masked_crc(b'\x01' + data), len(data), 1) + data
        def entry(key, value):
            return b'\0' + var(len(key)) + var(len(value)) + key + value + struct.pack('<II', 0, 1)
        def block(data):
            return data + b'\0' + struct.pack('<I', masked_crc(data + b'\0'))
        key = b'135726:1:443070:' + MAILBOX
        raw = '中文错误报告\n[FAILED_CHECK] 三项阻断\n'.encode('utf-8')
        value = (f'isTable true\nstr_protocol str_RS-DIAGNOSTIC-FILE-1\nstr_report_id str_test.1\nstr_byte_count str_{len(raw)}\nstr_chunk_count str_1\nstr_checksum str_{zlib.adler32(raw):08X}\nstr_chunks\n    isTable true\n    str_g0001\n        isTable true\n        str_c0001 str_{raw.hex().upper()}\n').encode()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            # 中文维护：活动 SST 中旧值由更高 sequence 的完整 WAL 覆盖；已删除 SST 不得扫描。
            payload = entry(key + struct.pack('<Q', (3 << 8) | 1), b'old')
            index_offset = len(block(payload))
            index = entry(b'z', var(0) + var(len(payload)))
            footer = (var(0) + var(0) + var(index_offset) + var(len(index))).ljust(40, b'\0') + bytes.fromhex('57fb808b247547db')
            (root/'000002.sst').write_bytes(block(payload) + block(index) + footer)
            (root/'000003.sst').write_bytes(b'OBSOLETE INVALID FILE MUST NOT BE READ')
            manifest = b'\x01' + field(b'leveldb.BytewiseComparator') + b'\x02' + var(1)
            manifest += b'\x07' + var(0) + var(2) + var(200) + field(key) + field(key)
            manifest += b'\x07' + var(0) + var(3) + var(200) + field(key) + field(key)
            manifest += b'\x06' + var(0) + var(3)
            (root/'MANIFEST-000001').write_bytes(log(manifest))
            (root/'CURRENT').write_bytes(b'MANIFEST-000001\n')
            wal = struct.pack('<QI', 7, 1) + b'\x01' + field(key) + field(value)
            (root/'000001.log').write_bytes(log(wal))
            self.assertEqual(read_database(root)[key][0], 7)
            output = root/'report.txt'
            save_report(root, output)
            self.assertEqual(output.read_bytes(), raw)
            with self.assertRaises(FileExistsError):
                save_report(root, output)
            # 中文维护：使用真实 WAL 验证首次无目录、去重、删除 txt / 删除整个输出目录后重建。
            import rs_diagnostic_file_export as exporter
            reports = root / '诊断报告'
            with patch.object(exporter, 'report_folder', return_value=reports):
                first = save_report(root)
                self.assertEqual(first.read_bytes(), raw)
                self.assertEqual(save_report(root), first)
                first.unlink()
                second = save_report(root)
                self.assertEqual(second.read_bytes(), raw)
                shutil.rmtree(reports)
                third = save_report(root)
                self.assertEqual(third.read_bytes(), raw)
                (reports / '.last-export.json').write_text('damaged', encoding='utf-8')
                self.assertEqual(save_report(root).read_bytes(), raw)
                # 中文维护：接收器运行中清空目录且数据库未变，仍恢复完整 txt；仅时间由测试推动。
                cycles = []
                def next_cycle(_):
                    cycles.append(1)
                    if len(cycles) == 1:
                        shutil.rmtree(reports)
                    else:
                        self.assertTrue(list(reports.glob('*.txt')))
                        self.assertEqual(next(reports.glob('*.txt')).read_bytes(), raw)
                        (reports / '.stop-receiver').write_text('stop')
                with patch.object(exporter.time, 'sleep', side_effect=next_cycle):
                    exporter.watch(root, root)
                self.assertEqual(len(cycles), 2)
            # 中文维护：最新删除记录优先，旧 SST 的导出快照不能复活。
            deletion = struct.pack('<QI', 8, 1) + b'\x00' + field(key)
            (root/'000001.log').write_bytes(log(wal) + log(deletion))
            self.assertNotIn(key, read_database(root))
            with self.assertRaises(ValueError):
                save_report(root, root/'must-not-exist.txt')

if __name__ == '__main__':
    unittest.main()
