"""Flat report envelopes: whitespace-safe transport only, never normalize report bytes.

Fixtures are produced by real Lua production transport/page with simulated Native editors.
No user code is evaluated; old v1 remains supported and missing parts remain fatal.
"""
from pathlib import Path
import re
import unittest
from rs_report_copy_decode import decode_copy_bytes, unwrap_report
from test_rs_report_parts import encoded, pieces
from test_rs_self_check_report import read_blocks

ROOT = Path(__file__).resolve().parent


def flat(row: str) -> str:
    header, body = row.split('\nDATA=\n', 1)
    data = body.removesuffix('\nRS-REPORT-PART-END')
    assert not any(c in data for c in '~;\r\t ')
    return header.replace('RS-REPORT-PART-1', 'RS-REPORT-PART-2').replace('\n', ';') + ';DATA=' + data.replace('\n', '~') + ';RS-REPORT-PART-END'


class FlatWireTests(unittest.TestCase):
    raw = ('原文 有 空格\t换行\r\n与~分号;不改写'.encode() + bytes(range(256))) * 4

    def rows(self):
        return [flat(row) for row in pieces(encoded(self.raw), step=147)]

    def test_exact_flat_roundtrip(self):
        self.assertEqual(decode_copy_bytes('\n'.join(self.rows())), self.raw)

    def test_transport_whitespace_may_change_but_original_whitespace_does_not(self):
        text = ''.join(self.rows())
        wrapped = '\ufeff' + ' \r\n\t'.join(text[i:i+67] for i in range(0, len(text), 67)) + ' \n'
        self.assertEqual(decode_copy_bytes(wrapped), self.raw)

    def test_lua_ui_roundtrip_after_newline_removal(self):
        for name in ('ui', 'short', 'real_flow'):
            with self.subTest(name=name):
                text = (ROOT / f'.copy_wire_{name}.txt').read_text('utf-8')
                raw = (ROOT / f'.copy_wire_{name}.bin').read_bytes()
                self.assertEqual(decode_copy_bytes(text), raw)
                self.assertEqual(unwrap_report(text).encode(), raw)
                if name == 'real_flow':
                    self.assertEqual(set(read_blocks(text)), {'v3.buff_display', 'v3.death_review', 'v3.life.trade'})

    def test_missing_part_names_index(self):
        rows = self.rows()
        with self.assertRaisesRegex(ValueError, 'Missing report parts: 2'):
            decode_copy_bytes('\n'.join(rows[:1] + rows[2:]))

    def test_reordering_and_identical_retries_are_allowed(self):
        rows = self.rows()
        self.assertEqual(decode_copy_bytes(''.join(rows[::-1] + rows[:2])), self.raw)

    def test_nonwhitespace_byte_change_is_rejected(self):
        rows = self.rows()
        rows[0] = rows[0].replace('DATA=RS-REPORT', 'DATA=XS-REPORT')
        with self.assertRaises(ValueError):
            decode_copy_bytes(''.join(rows))

    def test_newline_escape_change_is_rejected(self):
        rows = self.rows()
        rows[0] = rows[0].replace('~', 'X', 1)
        with self.assertRaises(ValueError):
            decode_copy_bytes(''.join(rows))

    def test_mixed_ids_and_legacy_framing_are_rejected(self):
        for bad in ('ID=7.1', 'RS-REPORT-PART-1'):
            rows = self.rows()
            rows[-1] = rows[-1].replace('ID=1.4', bad) if bad.startswith('ID=') else rows[-1].replace('RS-REPORT-PART-2', bad)
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                decode_copy_bytes(''.join(rows))

    def test_bad_sizes_end_and_total_checks_are_rejected(self):
        for pattern, substitute in [('DATA_BYTES=147', 'DATA_BYTES=148'), ('PART=1/', 'PART=0/'),
                                    (';RS-REPORT-PART-END', ';NO_END'), ('TOTAL_CHECK=', 'TOTAL_CHECK=0')]:
            rows = self.rows()
            rows[0] = rows[0].replace(pattern, substitute, 1)
            with self.subTest(pattern=pattern), self.assertRaises(ValueError):
                decode_copy_bytes(''.join(rows))

    def test_non_ascii_whitespace_is_not_silently_removed(self):
        text = '\u00a0'.join(self.rows())
        with self.assertRaises(ValueError):
            decode_copy_bytes(text)

    def test_full_original_report_and_three_raw_stores_survive_new_wire(self):
        raw = (ROOT / '.self_check_real_evidence.txt').read_bytes()
        text = ''.join(flat(p) for p in pieces(encoded(raw), step=1024))
        self.assertEqual(decode_copy_bytes(text), raw)
        self.assertEqual(set(read_blocks(text)), {'v3.buff_display', 'v3.death_review', 'v3.life.trade'})

    def test_legacy_copy_parts_and_raw_reports_still_work(self):
        self.assertEqual(decode_copy_bytes('\n'.join(pieces(encoded(self.raw)))), self.raw)
        self.assertEqual(decode_copy_bytes(encoded(self.raw)), self.raw)
        raw = (ROOT / '.self_check_real_evidence.txt').read_text('utf8')
        self.assertEqual(unwrap_report(raw), raw)


if __name__ == '__main__':
    unittest.main()
