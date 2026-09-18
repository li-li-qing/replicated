"""Focused diagnostic copy: real Lua producer, synthetic stores; never execute received Lua."""
from pathlib import Path
import importlib
import re
import unittest
import zlib

from rs_persistence_evidence_decode import decode_evidence

ROOT = Path(__file__).resolve().parent


def decoder():
    try:
        module = importlib.import_module('rs_focus_report_decode')
    except ImportError as exc:
        raise AssertionError('focused decoder is not implemented') from exc
    return module.decode_focused_report


def field(node, key):
    return next(row['value'] for row in node['entries'] if row['key'].get('text') == key)


def body_of(text):
    return text.split(' | BODY_BYTES=', 1)[0]


def reseal(body):
    identity = re.match(r'RS-FOCUS-1 ID=([0-9.]+) ', body)[1]
    raw = body.encode('utf8')
    return body + f' | BODY_BYTES={len(raw)} CHECK={zlib.adler32(raw):08X} RS-FOCUS-END ID={identity}'


class FocusReportTests(unittest.TestCase):
    def sample(self):
        return (ROOT / '.focus_report.txt').read_text('utf8')

    def test_one_copy_yields_exact_one_real_store_evidence(self):
        result = decoder()(self.sample())
        expected = (ROOT / '.focus_report_expected_evidence.txt').read_text('utf8')
        self.assertEqual(result['evidence_text'], {'v3.life.trade': expected})
        self.assertEqual(result['included'], 1)
        self.assertEqual(result['fenced'], 3)
        self.assertFalse(result['full_dump'])

    def test_compact_snapshot_retains_entire_raw_table(self):
        full = decode_evidence((ROOT / '.focus_evidence_full.txt').read_text())
        compact = decode_evidence((ROOT / '.focus_evidence_compact.txt').read_text())
        self.assertEqual(field(full, 'raw'), field(compact, 'raw'))
        self.assertEqual(field(full, 'store'), field(compact, 'store'))
        self.assertEqual(len(compact['entries']), 2)

    def test_bom_and_editor_line_wrapping_are_only_outer_conversions(self):
        text = self.sample()
        wrapped = '\ufeff' + '\r\n'.join(text[i:i+80] for i in range(0, len(text), 80))
        self.assertEqual(decoder()(wrapped)['evidence'], decoder()(text)['evidence'])

    def test_truncated_report_rejected(self):
        with self.assertRaises(ValueError):
            decoder()(self.sample()[:-20])

    def test_changed_summary_rejected_not_only_raw_packet(self):
        with self.assertRaises(ValueError):
            decoder()(self.sample().replace('BLOCKED', 'BLOCAED', 1))

    def test_wrong_footer_identity_rejected(self):
        with self.assertRaises(ValueError):
            decoder()(self.sample().replace('RS-FOCUS-END ID=1.1', 'RS-FOCUS-END ID=9.9'))

    def test_bad_byte_length_rejected(self):
        text = re.sub(r'BODY_BYTES=\d+', 'BODY_BYTES=1', self.sample())
        with self.assertRaises(ValueError):
            decoder()(text)

    def test_missing_raw_marker_rejected_even_with_new_outer_checksum(self):
        body = body_of(self.sample()).replace(' RAW_END', '', 1)
        with self.assertRaises(ValueError):
            decoder()(reseal(body))

    def test_raw_copy_checksum_rejected_after_outer_reseal(self):
        body = body_of(self.sample())
        start = body.index('RAW_BEGIN')
        head, tail = body[:start], body[start:]
        tail = re.sub(r'~CHECK=[A-F0-9]{8}', '~CHECK=00000000', tail, count=1)
        with self.assertRaises(ValueError):
            decoder()(reseal(head+tail))

    def test_evidence_name_must_match_decoded_store(self):
        body = body_of(self.sample()).replace('RAW_BEGIN store=v3.life.trade', 'RAW_BEGIN store=v3.fake')
        with self.assertRaises(ValueError):
            decoder()(reseal(body))

    def test_omission_disclosure_must_match_actual_packet_count(self):
        body = body_of(self.sample()).replace('raw=1/3', 'raw=0/3')
        with self.assertRaises(ValueError):
            decoder()(reseal(body))

    def test_summarized_report_without_raw_is_not_full_evidence(self):
        body = re.sub(r' \| RAW_BEGIN .*? RAW_END', '', body_of(self.sample()))
        body = body.replace('raw=1/3', 'raw=0/3').replace('complete_native_unverified', 'copy_budget')
        result = decoder()(reseal(body))
        self.assertEqual(result['evidence'], {})
        self.assertEqual(result['included'], 0)
        self.assertEqual(result['fenced'], 3)
        self.assertFalse(result['full_dump'])

    def test_unknown_format_control_bytes_and_oversize_input_rejected(self):
        for text in ['x'*3501, self.sample().replace('RS-FOCUS-1', 'RS-FOCUS-9', 1), self.sample()+'\x00']:
            with self.subTest(text=text[:20]), self.assertRaises(ValueError):
                decoder()(text)

    def test_spaces_in_messages_cannot_be_silently_removed(self):
        with self.assertRaises(ValueError):
            decoder()(self.sample().replace('see S', 'seeS', 1))


if __name__ == '__main__':
    unittest.main()
