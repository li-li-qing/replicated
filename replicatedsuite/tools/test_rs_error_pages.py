"""Cross-language and hostile-input tests for readable immutable report pages."""
import unittest
from pathlib import Path
import re
import zlib
from rs_error_pages_decode import decode_error_pages
from rs_report_copy_decode import decode_copy_bytes

def make_pages(raw: bytes, width=36, rid='1.1'):
    wire=raw.replace(b'\\',b'\\\\').replace(b'\r',b'\\r').replace(b'\n',b'\\n')
    pieces=[];pos=0
    while pos<len(wire) or not pieces:
        end=min(len(wire),pos+width)
        while end<len(wire) and (wire[end]&0xc0)==0x80:end-=1
        pieces.append((pos,wire[pos:end]));pos=end
    chk=lambda x:f'{zlib.adler32(x):08X}'
    return [(f'RS-ERROR-PAGE-1;ID={rid};PAGE={i}/{len(pieces)};TOTAL_BYTES={len(wire)};TOTAL_CHECK={chk(wire)};'
        f'RAW_BYTES={len(raw)};RAW_CHECK={chk(raw)};OFFSET={off};DATA_BYTES={len(part)};DATA_CHECK={chk(part)};DATA=').encode()
        +part+b';RS-ERROR-PAGE-END' for i,(off,part) in enumerate(pieces,1)]

class ErrorPagesTests(unittest.TestCase):
    def setUp(self):
        self.raw=('中文错误\r\nfile\\path;RS-ERROR-PAGE-END;\n\t space ').encode()*20
        self.pages=make_pages(self.raw)
    def decode(self,pages):return decode_error_pages(b'\n'.join(pages).decode())
    def test_roundtrip(self):self.assertEqual(self.decode(self.pages),self.raw)
    def test_reordered_and_duplicate(self):self.assertEqual(self.decode(self.pages[::-1]+self.pages[:2]),self.raw)
    def test_empty(self):self.assertEqual(self.decode(make_pages(b'')),b'')
    def test_legacy_entry_dispatch(self):self.assertEqual(decode_copy_bytes(b''.join(self.pages).decode()),self.raw)
    def test_missing(self):
        with self.assertRaisesRegex(ValueError,'Missing pages'):self.decode(self.pages[1:])
    def test_mixed(self):
        with self.assertRaisesRegex(ValueError,'Mixed'):self.decode([self.pages[0]]+[p.replace(b'ID=1.1;',b'ID=2.1;') for p in self.pages[1:]])
    def test_corrupt(self):
        with self.assertRaises(ValueError):self.decode([self.pages[0].replace(b'DATA=',b'DATA=X',1)]+self.pages[1:])
    def test_bad_offset(self):
        with self.assertRaisesRegex(ValueError,'offset'):self.decode([self.pages[0].replace(b'OFFSET=0;',b'OFFSET=1;')]+self.pages[1:])
    def test_total_checksum(self):
        with self.assertRaisesRegex(ValueError,'checksum'):self.decode([re.sub(rb'TOTAL_CHECK=[0-9A-F]{8}',b'TOTAL_CHECK=00000000',p) for p in self.pages])
    def test_original_checksum(self):
        with self.assertRaisesRegex(ValueError,'checksum'):self.decode([re.sub(rb'RAW_CHECK=[0-9A-F]{8}',b'RAW_CHECK=00000000',p) for p in self.pages])
    def test_declared_oversize(self):
        with self.assertRaisesRegex(ValueError,'limits'):self.decode([re.sub(rb'RAW_BYTES=\d+',b'RAW_BYTES=9999999',p) for p in self.pages])
    def test_unknown_text(self):
        with self.assertRaises(ValueError):decode_error_pages('not a page')
    def test_lua_generated_page_flows(self):
        root=Path(__file__).parent
        for name in ('real_flow','wire_real_flow','ui'):
            stem=('.copy_parts_'+name if name!='wire_real_flow' else '.copy_wire_real_flow')
            text=(root/(stem+'.txt')).read_text()
            self.assertTrue(text.startswith('RS-ERROR-PAGE-1;'))
            self.assertEqual(decode_error_pages(text),(root/(stem+'.bin')).read_bytes())
    def test_lua_wire_newlines_short_and_long(self):
        root=Path(__file__).parent
        for name in ('ui','short'):
            self.assertEqual(decode_error_pages((root/f'.copy_wire_{name}.txt').read_text()),(root/f'.copy_wire_{name}.bin').read_bytes())
if __name__=='__main__':unittest.main()
