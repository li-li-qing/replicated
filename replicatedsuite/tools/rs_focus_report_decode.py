#!/usr/bin/env python3
"""Decode one RS-FOCUS-1 diagnostic excerpt and its optional complete native snapshot.

The excerpt is not a full dump or a save-integrity recovery. Only the outer
newline-free display grammar tolerates CR/LF reflow. Spaces remain significant.
All byte lengths and copy checksums are verified before nested evidence parsing.
Received Lua is never evaluated; output is typed JSON, never a game save file.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import zlib

from rs_report_copy_decode import decode_copy_bytes
from rs_persistence_evidence_decode import decode_evidence

MAX_REPORT_BYTES = 3500
HEADER = re.compile(r'^RS-FOCUS-1 ID=([0-9]+\.[0-9]+) BUILD=')
FOOTER = re.compile(r' \| BODY_BYTES=([0-9]+) CHECK=([0-9A-F]{8}) RS-FOCUS-END ID=([0-9]+\.[0-9]+)$')
RAW = re.compile(r'RAW_BEGIN store=([A-Za-z0-9_.-]{1,128}) (RS-REPORT-COPY-1~[A-Za-z0-9+/=_.~\-]+~RS-REPORT-COPY-END) RAW_END')
COVERAGE = re.compile(r'(?:^| \| )COVERAGE fullDump=not_included raw=([0-9]+)/([0-9]+) ')


def _field(node: dict, key: str) -> dict:
    matches = [row['value'] for row in node.get('entries', []) if row['key'].get('text') == key]
    if len(matches) != 1:
        raise ValueError(f'Evidence must have exactly one {key!r} field')
    return matches[0]


def decode_focused_report(text: str) -> dict:
    """Validate a single copy; never infer or silently reconstruct omitted stores."""
    if not isinstance(text, str) or len(text.encode('utf8')) > MAX_REPORT_BYTES * 2:
        raise ValueError('Focused report is missing or too large')
    # Source report contains no literal LF/CR: logs escape them and nested copy
    # framing maps LF to '~'. Removing only display reflow does not alter raw data.
    normalized = text.lstrip('\ufeff').replace('\r', '').replace('\n', '')
    if len(normalized.encode('utf8')) > MAX_REPORT_BYTES or re.search(r'[\x00-\x1f\x7f]', normalized):
        raise ValueError('Focused report exceeds budget or contains control bytes')
    header, footer = HEADER.match(normalized), FOOTER.search(normalized)
    if not header or not footer or header[1] != footer[3]:
        raise ValueError('Missing or mismatched focused report markers')
    body = normalized[:footer.start()]
    raw_body = body.encode('utf8')
    if len(raw_body) != int(footer[1]) or f'{zlib.adler32(raw_body):08X}' != footer[2]:
        raise ValueError('Focused report length or checksum mismatch')
    coverage = list(COVERAGE.finditer(body))
    if len(coverage) != 1:
        raise ValueError('Missing or ambiguous omission disclosure')
    included, fenced = map(int, coverage[0].groups())
    if not (0 <= included <= min(1, fenced)):
        raise ValueError('Invalid focused evidence counts')
    packets = list(RAW.finditer(body))
    if len(packets) != included or body.count('RAW_BEGIN') != included or body.count('RAW_END') != included:
        raise ValueError('Incomplete, duplicated or mismatched evidence blocks')
    evidence, evidence_text = {}, {}
    for match in packets:
        store_id, envelope = match.groups()
        decoded_text = decode_copy_bytes(envelope.replace('~', '\n')).decode('utf8', errors='strict')
        decoded = decode_evidence(decoded_text)
        if _field(decoded, 'store').get('text') != store_id or _field(decoded, 'raw').get('type') != 'table':
            raise ValueError('Evidence Store identity or raw table does not match')
        evidence[store_id], evidence_text[store_id] = decoded, decoded_text
    return {'id': header[1], 'full_dump': False, 'included': included, 'fenced': fenced,
            'report_text': normalized, 'evidence': evidence, 'evidence_text': evidence_text}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('output', type=Path, help='New JSON file; an existing file is never overwritten')
    args = parser.parse_args()
    try:
        if args.input.stat().st_size > MAX_REPORT_BYTES * 2:
            raise ValueError('Input exceeds copy budget')
        result = decode_focused_report(args.input.read_text(encoding='utf8'))
        with args.output.open('x', encoding='utf8') as target:
            json.dump(result, target, ensure_ascii=False, indent=2)
            target.write('\n')
    except (OSError, ValueError) as exc:
        parser.exit(1, f'Decode failed: {exc}\n')
    print(f'Validated excerpt {result["id"]}: {result["included"]}/{result["fenced"]} native snapshots; not a full dump')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
