"""Offline evidence-decoder regressions. Never executes user-supplied Lua."""
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parent
MODULE = ROOT / 'rs_persistence_evidence_decode.py'


def checksum(body):
    value = 146959810
    for byte in body.encode('ascii'):
        value = (value * 131 + byte) % 2147483647
    return f'{value:08X}'


def envelope(body):
    return f'RS-PERSIST-EVIDENCE-1\nBYTES={len(body)}\nCHECK={checksum(body)}\n{body}\nRS-PERSIST-EVIDENCE-END'


def parts(text, width=101):
    check = text.split('\n')[2].split('=')[1]
    chunks = [text[n:n + width] for n in range(0, len(text), width)]
    return [f'RS-PERSIST-PART-1 i={n+1} n={len(chunks)} check={check} bytes={len(c)}\n{c}\nRS-PERSIST-PART-END' for n,c in enumerate(chunks)]


class EvidenceDecoderTests(unittest.TestCase):
    def decoder(self):
        self.assertTrue(MODULE.exists(), 'strict offline decoder missing')
        spec = importlib.util.spec_from_file_location('evidence_decoder', MODULE)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module.decode_evidence

    def test_real_lua_export_preserves_types_and_byte_strings(self):
        decode = self.decoder()
        source = (ROOT / '.evidence_test_sample.txt').read_text('ascii')
        root = decode(source)
        def get(table, name):
            return next(row['value'] for row in table['entries'] if row['key'].get('text') == name)
        raw = get(root, 'raw'); payload = get(raw, 'payload')
        ids = get(payload, 'ids')['entries']
        self.assertEqual([row['key']['type'] for row in ids], ['number', 'string'])
        self.assertEqual(get(payload, 'text')['hex'], 'E4B8ADE696870A005F5F72735F74323A73')
        self.assertFalse(get(payload, 'a')['value'])
        self.assertEqual(get(payload, 'b')['decimal'], '0')
        self.assertEqual(get(payload, 'empty')['entries'], [])

    def test_real_native_editor_pages_decode(self):
        source = (ROOT / '.evidence_test_parts.txt').read_text('ascii')
        self.assertEqual(self.decoder()(source)['type'], 'table')

    def test_pages_reassemble_out_of_order(self):
        text = envelope('T1{S1:78;D12;}'); pages = parts(text)
        self.assertEqual(self.decoder()('\n\n'.join(reversed(pages))), self.decoder()(text))

    def test_missing_page_rejected(self):
        with self.assertRaises(ValueError): self.decoder()(parts(envelope('T0{}'), 30)[0])

    def test_duplicate_page_rejected(self):
        pages = parts(envelope('T0{}'))
        with self.assertRaises(ValueError): self.decoder()('\n'.join(pages + pages[:1]))

    def test_changed_content_rejected(self):
        with self.assertRaises(ValueError): self.decoder()(envelope('T1{S1:78;D12;}').replace('D12;', 'D13;'))

    def test_invalid_length_rejected(self):
        with self.assertRaises(ValueError): self.decoder()(envelope('T0{}').replace('BYTES=4', 'BYTES=5'))

    def test_malformed_tags_and_trailing_tokens_rejected(self):
        for body in ('X1;', 'T1{S1:00;}', 'T0{}D1;', 'S2:AB;'):
            with self.assertRaises(ValueError): self.decoder()(envelope(body))

    def test_deep_input_rejected(self):
        body = 'T1{S1:78;' * 40 + 'N;' + '}' * 40
        with self.assertRaises(ValueError): self.decoder()(envelope(body))

    def test_crlf_and_bom_accepted(self):
        text = envelope('T0{}')
        self.assertEqual(self.decoder()('\ufeff' + text.replace('\n', '\r\n')), self.decoder()(text))

    def test_duplicate_typed_keys_rejected(self):
        with self.assertRaises(ValueError): self.decoder()(envelope('T2{D1;S0:;D1.0;S0:;}'))

    def test_nonfinite_numbers_rejected(self):
        for token in ('nan','inf','1e9999'):
            with self.assertRaises(ValueError): self.decoder()(envelope('D'+token+';'))

    def test_lua_code_is_never_accepted(self):
        with self.assertRaises(ValueError): self.decoder()("os.execute('touch hacked')")


if __name__ == '__main__':
    unittest.main(verbosity=2)
