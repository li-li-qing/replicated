#!/usr/bin/env python3
"""Join explicit RS-ERROR-PAGE-1 pages and restore the exact UTF-8 report.

Maintenance: editor pagination is NOT a persistence codec. Only CR/LF inserted by
an editor are ignored in this line-free wire. Spaces/tabs and every data byte are
significant. Check length, identity, offsets, per-page and whole checksums before
unescaping; never eval Lua or repair/write game files. Output uses exclusive create.
"""
from __future__ import annotations
import argparse
from pathlib import Path
import re
import zlib

MAX_RAW = 1_048_576
MAX_INPUT = 12 * MAX_RAW
HEADER = re.compile(
    rb'RS-ERROR-PAGE-1;ID=([A-Za-z0-9_.-]{1,48});PAGE=(\d{1,4})/(\d{1,4});'
    rb'TOTAL_BYTES=(\d{1,7});TOTAL_CHECK=([0-9A-F]{8});RAW_BYTES=(\d{1,7});'
    rb'RAW_CHECK=([0-9A-F]{8});OFFSET=(\d{1,7});DATA_BYTES=(\d{1,5});'
    rb'DATA_CHECK=([0-9A-F]{8});DATA=')
END = b';RS-ERROR-PAGE-END'

def checksum(value: bytes) -> bytes:
    return f'{zlib.adler32(value):08X}'.encode('ascii')

def decode_error_pages(text: str) -> bytes:
    if not isinstance(text, str):
        raise ValueError('Expected page text')
    data = text.lstrip('\ufeff').encode('utf-8', errors='strict')
    if len(data) > MAX_INPUT:
        raise ValueError('Page collection exceeds input limit')
    # Source newlines are encoded as literal backslash+n/r; only display breaks vanish.
    data = data.replace(b'\r', b'').replace(b'\n', b'')
    position, identity, seen, copies = 0, None, {}, 0
    while position < len(data):
        while position < len(data) and data[position:position+1] in (b' ', b'\t'):
            position += 1
        if position == len(data):
            break
        match = HEADER.match(data, position)
        if not match:
            raise ValueError('Missing or malformed page header')
        rid, index, count, total, total_check, raw_len, raw_check, offset, size, part_check = match.groups()
        index, count, total, raw_len, offset, size = map(int, (index, count, total, raw_len, offset, size))
        if not (1 <= index <= count <= 8192 and 0 <= raw_len <= MAX_RAW
                and 0 <= total <= 2 * MAX_RAW and 0 <= offset <= total
                and 0 <= size <= 32768 and offset + size <= total):
            raise ValueError('Page fields exceed limits')
        current = (rid, count, total, total_check, raw_len, raw_check)
        if identity is not None and current != identity:
            raise ValueError('Mixed report identities or totals')
        identity = current
        start, end = match.end(), match.end() + size
        part = data[start:end]
        if len(part) != size or not data.startswith(END, end):
            raise ValueError(f'Page {index}: incomplete data or wrong length')
        if checksum(part) != part_check:
            raise ValueError(f'Page {index}: checksum mismatch')
        part.decode('utf-8', errors='strict')
        value = (offset, part)
        if index in seen and seen[index] != value:
            raise ValueError(f'Page {index}: conflicting duplicate')
        seen[index] = value
        copies += 1
        if copies > 16384:
            raise ValueError('Too many duplicated pages')
        position = end + len(END)
    if identity is None:
        raise ValueError('No pages found')
    _, count, total, total_check, raw_len, raw_check = identity
    missing = [str(i) for i in range(1, count+1) if i not in seen]
    if missing:
        raise ValueError('Missing pages: ' + ','.join(missing[:32]))
    segments, position = [], 0
    for i in range(1, count+1):
        offset, part = seen[i]
        if offset != position:
            raise ValueError(f'Page {i}: non-contiguous offset')
        segments.append(part)
        position += len(part)
    wire = b''.join(segments)
    if len(wire) != total or checksum(wire) != total_check:
        raise ValueError('Complete escaped text checksum/length mismatch')
    out, position = bytearray(), 0
    escape = {ord('n'):10, ord('r'):13, ord('\\'):92}
    while position < len(wire):
        value = wire[position]
        position += 1
        if value == 92:
            if position == len(wire) or wire[position] not in escape:
                raise ValueError('Invalid reversible text escape')
            value = escape[wire[position]]
            position += 1
        out.append(value)
        if len(out) > MAX_RAW:
            raise ValueError('Decoded report exceeds limit')
    raw = bytes(out)
    if len(raw) != raw_len or checksum(raw) != raw_check:
        raise ValueError('Original report checksum/length mismatch')
    raw.decode('utf-8', errors='strict')
    return raw

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    try:
        if args.input.stat().st_size > MAX_INPUT:
            raise ValueError('Input too large')
        raw = decode_error_pages(args.input.read_text(encoding='utf-8-sig'))
        with args.output.open('xb') as stream:
            stream.write(raw)
    except (OSError, ValueError, UnicodeError) as exc:
        parser.exit(1, f'Decode failed: {exc}\n')
    print(f'Decoded {len(raw)} bytes -> {args.output}')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
