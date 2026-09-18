#!/usr/bin/env python3
"""Decode an RS-REPORT-COPY-1 envelope or a complete RS-REPORT-PART-1/2 collection. Never execute report/Lua input.

The envelope is a lossless copy transport, not encryption or a save-file repair.
LZB1 uses eight tokens per low-bit-first flag byte. A set bit consumes a
big-endian (distance-1) uint16 and a (length-4) uint8. Distance is at most
65536; overlapping matches are valid. Adler32 checks the exact original bytes.
"""
from __future__ import annotations

import argparse
import base64
import binascii
from pathlib import Path
import re
import zlib

MAX_BYTES = 1_048_576
MAX_ENCODED_BYTES = 1_500_000


# Maintenance (2026-09-12): the real editor returned 9215 bytes. A large lossless
# envelope must be copied in parts, not truncated or made to pass save integrity.
# This parser owns ONLY transport reassembly. It never evaluates Lua, writes game
# files, or treats an Adler32 as authentication. Each part is bounded, checked, and
# matched to the same report; the existing whole-envelope decoder remains the
# final authority. Reordering/exact duplicates are harmless, missing/conflicting
# parts fail closed with their indices. CRLF is the one permitted text conversion.
MAX_PARTS = 256
PART_HEADER = re.compile(
    r'RS-REPORT-PART-1\nID=([A-Za-z0-9_.-]{1,64})\nPART=([0-9]{1,3})/([0-9]{1,3})\n'
    r'TOTAL_BYTES=([0-9]{1,7})\nTOTAL_CHECK=([0-9A-F]{8})\nOFFSET=([0-9]{1,7})\n'
    r'DATA_BYTES=([0-9]{1,7})\nDATA_CHECK=([0-9A-F]{8})\nDATA=\n')
PART_END = '\nRS-REPORT-PART-END'


# Maintenance (TEXT_READBACK, 2026-09-12): flat v2 escapes LF only in the fixed
# ASCII copy envelope (not in original text). Native may reflow/delete whitespace.
# Only this outer v2 grammar is whitespace-insensitive. Reuse the v1 assembler for
# bounds, duplicate/identity/offset/byte-count/checksum validation; never execute Lua.
FLAT_HEADER = re.compile(
    r'RS-REPORT-PART-2;ID=([A-Za-z0-9_.-]{1,64});PART=([0-9]{1,3})/([0-9]{1,3});'
    r'TOTAL_BYTES=([0-9]{1,7});TOTAL_CHECK=([0-9A-F]{8});OFFSET=([0-9]{1,7});'
    r'DATA_BYTES=([0-9]{1,7});DATA_CHECK=([0-9A-F]{8});DATA=')
FLAT_END = ';RS-REPORT-PART-END'
ASCII_SPACE = re.compile(r'[ \t\r\n]')


def _flat_candidate(text: str) -> str | None:
    """Do not interpret arbitrary raw reports as packets or remove their spaces."""
    compact = ASCII_SPACE.sub('', text)
    return compact if compact.startswith('RS-REPORT-PART-2;') else None


def _flat_to_legacy(text: str) -> str:
    """Preserve every encoded byte while mapping v2 framing to the validated v1 parser."""
    if not text.isascii():
        raise ValueError('Flat multipart envelopes must contain ASCII only')
    position = 0
    converted = []
    while position < len(text):
        if len(converted) >= MAX_PARTS * 4:
            raise ValueError('Too many duplicate report parts')
        match = FLAT_HEADER.match(text, position)
        if match is None:
            raise ValueError('Missing or malformed flat report part header')
        report_id, index, total, size, check, offset, data_size, data_check = match.groups()
        length = int(data_size)
        if not (0 < length <= MAX_ENCODED_BYTES and length <= int(size)):
            raise ValueError('Flat report part data size is invalid')
        start = match.end()
        end = start + length
        data = text[start:end]
        if len(data) != length or not text.startswith(FLAT_END, end):
            raise ValueError(f'Flat report part {index} is truncated or has a wrong length')
        if not re.fullmatch(r'[A-Za-z0-9+/_=.~\-]+', data):
            raise ValueError('Invalid flat data alphabet')
        # Encode emits no literal '~'; replacing it with LF is a bijection on
        # the encoder's alphabet. All data checksums still cover the original LF.
        data = data.replace('~', '\n')
        converted.append(
            f'RS-REPORT-PART-1\nID={report_id}\nPART={index}/{total}\n'
            f'TOTAL_BYTES={size}\nTOTAL_CHECK={check}\nOFFSET={offset}\n'
            f'DATA_BYTES={data_size}\nDATA_CHECK={data_check}\nDATA=\n'
            f'{data}\nRS-REPORT-PART-END')
        position = end + len(FLAT_END)
    return '\n'.join(converted)


def assemble_copy_parts(text: str) -> str:
    """Reassemble complete ASCII parts, rejecting mixed snapshots and data loss."""
    if not isinstance(text, str) or len(text) > MAX_ENCODED_BYTES:
        raise ValueError('Multipart report missing or too large')
    text = text.lstrip('\ufeff').replace('\r\n', '\n')
    flat = _flat_candidate(text)
    if flat is not None:
        text = _flat_to_legacy(flat)
    if not text.isascii():
        raise ValueError('Multipart envelopes must contain ASCII only')
    position = 0
    identity = None
    parts: dict[int, tuple[int, str]] = {}
    copies = 0
    while position < len(text):
        while position < len(text) and text[position] in ' \t\n':
            position += 1
        if position == len(text):
            break
        header = PART_HEADER.match(text, position)
        if header is None:
            raise ValueError('Missing or malformed report part header')
        report_id, index, total, size, check, offset, data_size, data_check = header.groups()
        index, total, size, offset, data_size = map(int, (index, total, size, offset, data_size))
        if not (1 <= index <= total <= MAX_PARTS and 0 < size <= MAX_ENCODED_BYTES
                and 0 <= offset < size and 0 < data_size <= size - offset):
            raise ValueError('Report part bounds are invalid')
        current = (report_id, total, size, check)
        if identity is None:
            identity = current
        elif identity != current:
            raise ValueError('Mixed report snapshots or inconsistent part metadata')
        start = header.end()
        end = start + data_size
        data = text[start:end]
        if len(data) != data_size or not text.startswith(PART_END, end):
            raise ValueError(f'Report part {index} is truncated or has a wrong length')
        if f'{zlib.adler32(data.encode("ascii")):08X}' != data_check:
            raise ValueError(f'Report part {index} checksum mismatch')
        entry = (offset, data)
        if index in parts and parts[index] != entry:
            raise ValueError(f'Conflicting duplicate report part: {index}')
        parts[index] = entry
        copies += 1
        if copies > MAX_PARTS * 4:
            raise ValueError('Too many duplicate report parts')
        position = end + len(PART_END)
    if identity is None:
        raise ValueError('No report parts found')
    _, total, size, check = identity
    missing = [str(i) for i in range(1, total + 1) if i not in parts]
    if missing:
        raise ValueError('Missing report parts: ' + ','.join(missing))
    chunks = []
    offset = 0
    for index in range(1, total + 1):
        actual_offset, data = parts[index]
        if actual_offset != offset:
            raise ValueError(f'Report part {index} has an invalid offset')
        chunks.append(data)
        offset += len(data)
    payload = ''.join(chunks)
    if len(payload) != size or f'{zlib.adler32(payload.encode("ascii")):08X}' != check:
        raise ValueError('Reassembled report length or checksum mismatch')
    if not payload.startswith('RS-REPORT-COPY-1\n'):
        raise ValueError('Parts must contain exactly one supported copy envelope')
    return payload


def decode_copy_bytes(text: str) -> bytes:
    # Maintenance: new readable UI pages are a separate transport; dispatch before
    # legacy Base64 limits. Both decoders verify complete content, never execute it.
    if isinstance(text, str) and text.lstrip('\ufeff').startswith('RS-ERROR-PAGE-1;'):
        from rs_error_pages_decode import decode_error_pages
        return decode_error_pages(text)
    if not isinstance(text, str) or len(text) > MAX_ENCODED_BYTES:
        raise ValueError("Copy envelope missing or too large")
    text = text.lstrip('\ufeff').replace('\r\n', '\n')
    if text.startswith('RS-REPORT-PART-1\n') or _flat_candidate(text) is not None:
        text = assemble_copy_parts(text)
    match = re.fullmatch(
        r'RS-REPORT-COPY-1\nCODEC=(LZB1|RAW64)\nRAW_BYTES=([0-9]{1,7})\n'
        r'PACKED_BYTES=([0-9]{1,7})\nCHECK=([0-9A-F]{8})\nDATA64=\n'
        r'([A-Za-z0-9+/=\n \t]*)\nRS-REPORT-COPY-END\s*', text)
    if not match:
        raise ValueError("Missing or malformed copy envelope")
    codec, size, packed_size, check, payload = match.groups()
    size, packed_size = int(size), int(packed_size)
    if size > MAX_BYTES or packed_size > MAX_BYTES:
        raise ValueError("Copy envelope exceeds decompression budget")
    payload = re.sub(r'[\n \t]', '', payload)
    try:
        packed = base64.b64decode(payload, validate=True)
    except (ValueError, binascii.Error) as exc:
        raise ValueError("Invalid Base64") from exc
    if base64.b64encode(packed).decode('ascii') != payload:
        raise ValueError("Noncanonical Base64")
    if len(packed) != packed_size:
        raise ValueError("Packed byte count mismatch")
    if codec == 'RAW64':
        raw = packed
    else:
        output = bytearray()
        offset = 0
        while offset < len(packed):
            flags = packed[offset]
            offset += 1
            if offset == len(packed):
                raise ValueError("Flag byte has no tokens")
            for bit in range(8):
                if offset == len(packed):
                    if flags >> bit:
                        raise ValueError("Nonzero unused flag bits")
                    break
                if flags & (1 << bit):
                    if offset + 3 > len(packed):
                        raise ValueError("Truncated match token")
                    distance = int.from_bytes(packed[offset:offset+2], 'big') + 1
                    length = packed[offset+2] + 4
                    offset += 3
                    if distance > 65536 or distance > len(output):
                        raise ValueError("Match distance out of bounds")
                    if len(output) + length > size:
                        raise ValueError("Match exceeds declared output size")
                    for _ in range(length):
                        output.append(output[-distance])
                else:
                    if len(output) >= size:
                        raise ValueError("Literal exceeds declared output size")
                    output.append(packed[offset])
                    offset += 1
        raw = bytes(output)
    if len(raw) != size:
        raise ValueError("Raw byte count mismatch")
    if f'{zlib.adler32(raw):08X}' != check:
        raise ValueError("Copy checksum mismatch")
    return raw


def unwrap_report(text: str) -> str:
    normalized = text.lstrip('\ufeff').replace('\r\n', '\n')
    if normalized.startswith(('RS-ERROR-PAGE-1;', 'RS-REPORT-COPY-1\n', 'RS-REPORT-PART-1\n')) or (len(normalized) <= MAX_ENCODED_BYTES and _flat_candidate(normalized) is not None):
        return decode_copy_bytes(normalized).decode('utf-8', errors='strict')
    return normalized


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('output', type=Path, help='New output file; existing files are never overwritten')
    args = parser.parse_args()
    try:
        # New text-page collections include UTF-8/header overhead; their parser enforces a separate limit.
        from rs_error_pages_decode import MAX_INPUT
        if args.input.stat().st_size > MAX_INPUT:
            raise ValueError('Input file exceeds limit')
        raw = decode_copy_bytes(args.input.read_text(encoding='utf-8-sig'))
        with args.output.open('xb') as target:
            target.write(raw)
    except (OSError, ValueError) as exc:
        parser.exit(1, f'Decode failed: {exc}\n')
    print(f'Decoded {len(raw)} bytes -> {args.output}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
