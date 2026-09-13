"""Cross-language tests: real Lua encoder -> bounded Python decoder.

Run rs_status_refactor_test_runner.py first to generate non-user fixtures.
The tests do not establish actual RU UI, clipboard or FPS behavior.
"""
from pathlib import Path
import base64
import re
import unittest
import zlib

from rs_report_copy_decode import decode_copy_bytes, unwrap_report
from test_rs_self_check_report import read_blocks

ROOT = Path(__file__).resolve().parent


def envelope(packed: bytes, raw: bytes, *, codec='LZB1', size=None) -> str:
    return (f'RS-REPORT-COPY-1\nCODEC={codec}\nRAW_BYTES={len(raw) if size is None else size}\n'
            f'PACKED_BYTES={len(packed)}\nCHECK={zlib.adler32(raw):08X}\nDATA64=\n'
            f'{base64.b64encode(packed).decode()}\nRS-REPORT-COPY-END')


class ReportCopyTests(unittest.TestCase):
    def sample(self, index=10):
        return (ROOT / f'.copy_transport_{index}.txt').read_text(encoding='ascii')

    def test_addon_clipboard_name_is_in_nonallowed_reference_section(self):
        reference = ROOT.parents[1] / 'z_api_functions' / 'api_functions.lua'
        section = reference.read_text(encoding='utf-8').split('-- ADDON', 1)[1].split('-- Console', 1)[0]
        allowed, denied = section.split('Allowed functions', 1)[1].split('Available/not allowed functions', 1)
        self.assertNotIn('SetClipboardText(text)', allowed)
        self.assertIn('SetClipboardText(text)', denied)

    def test_all_lua_fixtures_roundtrip_exact_bytes(self):
        for i in range(1, 12):
            with self.subTest(i=i):
                self.assertEqual(decode_copy_bytes(self.sample(i)), (ROOT / f'.copy_transport_{i}.bin').read_bytes())

    def test_unified_report_decoder_reads_all_three_stores_from_single_copy_package(self):
        self.assertEqual(set(read_blocks(self.sample())), {'v3.buff_display', 'v3.death_review', 'v3.life.trade'})

    def test_windows_line_endings_and_bom_are_tolerated(self):
        self.assertEqual(decode_copy_bytes('\ufeff'+self.sample().replace('\n','\r\n')), decode_copy_bytes(self.sample()))

    def test_base64_line_wrapping_and_spaces_do_not_change_evidence(self):
        t = self.sample()
        t = t.replace('DATA64=\n','DATA64=\n \t').replace('\nRS-REPORT-COPY-END',' \nRS-REPORT-COPY-END')
        self.assertEqual(decode_copy_bytes(t), decode_copy_bytes(self.sample()))

    def test_corrupted_checksum_is_rejected(self):
        with self.assertRaises(ValueError):
            decode_copy_bytes(re.sub(r'CHECK=[A-F0-9]{8}', 'CHECK=00000000', self.sample()))

    def test_truncated_envelope_is_rejected(self):
        with self.assertRaises(ValueError):
            decode_copy_bytes(self.sample()[:-10])

    def test_negative_or_oversized_declared_lengths_are_rejected(self):
        for value in ('-1', '1048577', '99999999999999'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                decode_copy_bytes(re.sub(r'RAW_BYTES=\d+', 'RAW_BYTES='+value, self.sample()))

    def test_undeclared_codec_is_rejected(self):
        with self.assertRaises(ValueError):
            decode_copy_bytes(self.sample().replace('CODEC=LZB1', 'CODEC=exec'))

    def test_invalid_base64_is_rejected(self):
        with self.assertRaises(ValueError):
            decode_copy_bytes(self.sample().replace('DATA64=\n', 'DATA64=\n$'))

    def test_invalid_initial_backreference_is_rejected(self):
        with self.assertRaises(ValueError):
            decode_copy_bytes(envelope(bytes((1, 0, 0, 0)), b'AAAA'))

    def test_truncated_match_token_is_rejected(self):
        with self.assertRaises(ValueError):
            decode_copy_bytes(envelope(bytes((2, 65, 0, 0)), b'AAAA'))

    def test_overlap_match_is_correct(self):
        self.assertEqual(decode_copy_bytes(envelope(bytes((2,65,0,0,5)), b'A'*10)), b'A'*10)

    def test_match_cannot_expand_past_declared_length(self):
        with self.assertRaises(ValueError):
            decode_copy_bytes(envelope(bytes((2,65,0,0,255)), b'A'*5))

    def test_unused_high_flag_bits_are_rejected(self):
        with self.assertRaises(ValueError):
            decode_copy_bytes(envelope(bytes((128,65)), b'A'))

    def test_flag_without_tokens_is_rejected(self):
        with self.assertRaises(ValueError):
            decode_copy_bytes(envelope(bytes((0,)), b''))

    def test_trailing_tokens_are_rejected(self):
        with self.assertRaises(ValueError):
            decode_copy_bytes(envelope(bytes((0,65,66)), b'A'))

    def test_wrong_packed_size_is_rejected(self):
        with self.assertRaises(ValueError):
            decode_copy_bytes(re.sub(r'PACKED_BYTES=\d+', 'PACKED_BYTES=1', self.sample()))

    def test_raw64_checks_byte_count(self):
        with self.assertRaises(ValueError):
            decode_copy_bytes(envelope(b'A', b'AA', codec='RAW64'))

    def test_raw64_rejects_noncanonical_padding(self):
        with self.assertRaises(ValueError):
            decode_copy_bytes(envelope(b'A', b'A', codec='RAW64').replace('QQ==','QR=='))

    def test_old_plain_report_remains_accepted(self):
        plain=(ROOT/'.self_check_real_evidence.txt').read_text()
        self.assertEqual(unwrap_report(plain), plain)
        self.assertEqual(set(read_blocks(plain)), {'v3.buff_display', 'v3.death_review', 'v3.life.trade'})


if __name__ == '__main__':
    unittest.main()
