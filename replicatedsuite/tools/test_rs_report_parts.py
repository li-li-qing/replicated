"""Bounded multipart copy transport, not a save repair or native-client test.

The old decoder must fail the valid multipart tests before implementation.
No report content is executed; every piece and the reassembled envelope is checked.
"""
from pathlib import Path
import base64
import re
import unittest
import zlib

from rs_report_copy_decode import decode_copy_bytes, unwrap_report
from test_rs_self_check_report import read_blocks

ROOT = Path(__file__).resolve().parent


def checksum(text):
    return f'{zlib.adler32(text.encode("ascii")):08X}'


def encoded(raw):
    return (f'RS-REPORT-COPY-1\nCODEC=RAW64\nRAW_BYTES={len(raw)}\nPACKED_BYTES={len(raw)}\n'
            f'CHECK={zlib.adler32(raw):08X}\nDATA64=\n{base64.b64encode(raw).decode()}\nRS-REPORT-COPY-END')


def pieces(text, step=97, report_id='1.4'):
    total = (len(text) + step - 1) // step
    result = []
    for i, offset in enumerate(range(0, len(text), step), 1):
        chunk = text[offset:offset + step]
        result.append(f'RS-REPORT-PART-1\nID={report_id}\nPART={i}/{total}\n'
                      f'TOTAL_BYTES={len(text)}\nTOTAL_CHECK={checksum(text)}\nOFFSET={offset}\n'
                      f'DATA_BYTES={len(chunk)}\nDATA_CHECK={checksum(chunk)}\nDATA=\n'
                      f'{chunk}\nRS-REPORT-PART-END')
    return result


class MultipartTests(unittest.TestCase):
    raw = ('包含全量错误与取证\r\n'.encode() + bytes(range(256))) * 4

    def sample(self):
        return pieces(encoded(self.raw))

    def test_valid_parts_roundtrip_exact_original_bytes(self):
        self.assertEqual(decode_copy_bytes('\n\n'.join(self.sample())), self.raw)

    def test_reordered_parts_and_exact_duplicate_are_accepted_without_data_loss(self):
        rows = self.sample()
        self.assertEqual(decode_copy_bytes('\n'.join(rows[::-1] + rows[:1])), self.raw)

    def test_missing_part_names_the_missing_index(self):
        rows = self.sample()
        with self.assertRaisesRegex(ValueError, 'Missing report parts: 2'):
            decode_copy_bytes('\n'.join(rows[:1] + rows[2:]))

    def test_same_id_different_snapshot_is_rejected(self):
        rows = self.sample()
        rows[-1] = pieces(encoded(self.raw + b'x'))[-1]
        with self.assertRaises(ValueError):
            decode_copy_bytes('\n'.join(rows))

    def test_conflicting_duplicate_is_rejected(self):
        rows = self.sample()
        bad = rows[0].replace('OFFSET=0', 'OFFSET=1')
        with self.assertRaises(ValueError):
            decode_copy_bytes('\n'.join(rows + [bad]))

    def test_inconsistent_report_id_is_rejected(self):
        rows = self.sample()
        rows[-1] = rows[-1].replace('ID=1.4', 'ID=1.5')
        with self.assertRaises(ValueError):
            decode_copy_bytes('\n'.join(rows))

    def test_payload_corruption_and_truncated_piece_are_rejected(self):
        for suffix in ('\nRS-REPORT-PART-END', ''):
            rows = self.sample()
            rows[0] = rows[0].split('DATA=\n', 1)[0] + 'DATA=\nWRONG' + suffix
            with self.subTest(suffix=suffix), self.assertRaises(ValueError):
                decode_copy_bytes('\n'.join(rows))

    def test_valid_piece_checksums_do_not_bypass_whole_envelope_check(self):
        rows = [row.replace('TOTAL_CHECK=' + checksum(encoded(self.raw)), 'TOTAL_CHECK=00000000') for row in self.sample()]
        with self.assertRaises(ValueError):
            decode_copy_bytes('\n'.join(rows))

    def test_wrong_offsets_and_total_size_are_rejected(self):
        for old, new in [('OFFSET=0', 'OFFSET=1'), ('TOTAL_BYTES=', 'TOTAL_BYTES=9')]:
            rows = self.sample()
            rows[0] = rows[0].replace(old, new)
            with self.subTest(new=new), self.assertRaises(ValueError):
                decode_copy_bytes('\n'.join(rows))

    def test_unsafe_lengths_counts_and_ids_are_rejected(self):
        for old, new in [('DATA_BYTES=97', 'DATA_BYTES=-1'), ('DATA_BYTES=97', 'DATA_BYTES=99999999'),
                         ('PART=1/', 'PART=0/'), ('ID=1.4', 'ID=bad id')]:
            rows = self.sample()
            rows[0] = rows[0].replace(old, new)
            with self.subTest(new=new), self.assertRaises(ValueError):
                decode_copy_bytes('\n'.join(rows))

    def test_trailing_chat_or_extra_garbage_is_not_silently_accepted(self):
        with self.assertRaises(ValueError):
            decode_copy_bytes('\n'.join(self.sample()) + '\nINCOMPLETE_ANOTHER_REPORT')

    def test_windows_line_endings_and_bom_are_accepted(self):
        report = '\ufeff' + '\n\n'.join(self.sample()).replace('\n', '\r\n')
        self.assertEqual(decode_copy_bytes(report), self.raw)

    def test_real_lua_capacity_fixtures_roundtrip(self):
        for i in range(1, 5):
            with self.subTest(i=i):
                self.assertEqual(decode_copy_bytes((ROOT / f'.copy_parts_{i}.txt').read_text()),
                                 (ROOT / f'.copy_parts_{i}.bin').read_bytes())

    def test_actual_page_button_sequence_roundtrip(self):
        self.assertEqual(decode_copy_bytes((ROOT / '.copy_parts_ui.txt').read_text()),
                         (ROOT / '.copy_parts_ui.bin').read_bytes())

    def test_three_real_stores_page_flow_preserves_evidence_without_rereading(self):
        text = (ROOT / '.copy_parts_real_flow.txt').read_text()
        self.assertEqual(decode_copy_bytes(text), (ROOT / '.copy_parts_real_flow.bin').read_bytes())
        self.assertEqual(set(read_blocks(text)), {'v3.buff_display', 'v3.death_review', 'v3.life.trade'})

    def test_all_three_raw_stores_survive_multipart_real_lua_encoding(self):
        text = (ROOT / '.copy_parts_2.txt').read_text()
        self.assertEqual(set(read_blocks(text)), {'v3.buff_display', 'v3.death_review', 'v3.life.trade'})
        self.assertEqual(unwrap_report(text).encode(), (ROOT / '.copy_parts_2.bin').read_bytes())


if __name__ == '__main__':
    unittest.main()
