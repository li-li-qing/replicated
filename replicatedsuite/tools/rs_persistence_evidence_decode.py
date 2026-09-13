#!/usr/bin/env python3
"""Decode RS-PERSIST-EVIDENCE-1 / PART-1 into lossless tagged JSON.

Developer-only; not loaded by toc.g. Does not execute Lua or modify game saves.
Strings preserve original bytes as hex. Table entries retain typed keys instead
of collapsing Lua numeric key 1 and string key "1" into one JSON member.
The checksum detects copying errors only; it is NOT a save-integrity proof.
Usage: python rs_persistence_evidence_decode.py input.txt -o evidence.json
"""
from __future__ import annotations
import argparse
import json
import math
from pathlib import Path
import re
import sys

MAX_INPUT = 1048576
MAX_BODY = 262144


def checksum(body: str) -> str:
    value = 146959810
    for byte in body.encode('ascii'):
        value = (value * 131 + byte) % 2147483647
    return f'{value:08X}'


def reassemble(text: str) -> str:
    if text.startswith('RS-PERSIST-EVIDENCE-1\n'):
        return text
    header = re.compile(r'RS-PERSIST-PART-1 i=(\d{1,2}) n=(\d{1,2}) check=([0-9A-F]{8}) bytes=(\d{1,5})\n')
    pages = {}
    expected = identity = None
    cursor = 0
    while cursor < len(text):
        while cursor < len(text) and text[cursor].isspace():
            cursor += 1
        if cursor == len(text):
            break
        match = header.match(text, cursor)
        if not match:
            raise ValueError('Missing/invalid evidence part header')
        index, count, check, size = match.groups()
        index, count, size = int(index), int(count), int(size)
        if not 1 <= index <= count <= 64 or not 1 <= size <= 30000:
            raise ValueError('Invalid part bounds')
        if expected is not None and (expected != count or identity != check):
            raise ValueError('Parts belong to different exports')
        expected, identity = count, check
        if index in pages:
            raise ValueError('Duplicate part')
        start = match.end()
        end = start + size
        suffix = '\nRS-PERSIST-PART-END'
        if not text.startswith(suffix, end):
            raise ValueError('Truncated or changed part length')
        pages[index] = text[start:end]
        cursor = end + len(suffix)
    if expected is None or set(pages) != set(range(1, expected + 1)):
        raise ValueError('One or more parts are missing')
    result = ''.join(pages[n] for n in range(1, expected + 1))
    if f'\nCHECK={identity}\n' not in result:
        raise ValueError('Part identity does not match envelope')
    return result


class Parser:
    def __init__(self, body: str):
        self.body = body
        self.position = 0
        self.nodes = 0

    def match(self, pattern: str) -> re.Match:
        match = re.compile(pattern).match(self.body, self.position)
        if not match:
            raise ValueError(f'Malformed token at offset {self.position}')
        self.position = match.end()
        return match

    def value(self, depth: int = 0) -> dict:
        self.nodes += 1
        if depth > 16 or self.nodes > 65536:
            raise ValueError('Evidence structure exceeds parser budget')
        if self.position >= len(self.body):
            raise ValueError('Truncated value')
        tag = self.body[self.position]
        if tag == 'N':
            self.match(r'N;')
            return {'type': 'nil'}
        if tag == 'B':
            token = self.match(r'B([01]);').group(1)
            return {'type': 'boolean', 'value': token == '1'}
        if tag == 'D':
            token = self.match(r'D(-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?);').group(1)
            if not math.isfinite(float(token)):
                raise ValueError('Non-finite number')
            return {'type': 'number', 'decimal': token}
        if tag == 'S':
            length = int(self.match(r'S(\d{1,6}):').group(1))
            if length > MAX_BODY // 2:
                raise ValueError('Oversized byte string')
            end = self.position + length * 2
            token = self.body[self.position:end]
            if len(token) != length * 2 or not re.fullmatch(r'[0-9A-F]*', token):
                raise ValueError('Invalid hex byte string')
            self.position = end
            self.match(r';')
            raw = bytes.fromhex(token)
            node = {'type': 'string', 'hex': token}
            try:
                node['text'] = raw.decode('utf-8')
            except UnicodeDecodeError:
                pass  # Original bytes remain lossless; never invent replacement characters.
            return node
        if tag == 'T':
            count = int(self.match(r'T(\d{1,5})\{').group(1))
            if count > 4096:
                raise ValueError('Table exceeds entry budget')
            rows, keys = [], set()
            for _ in range(count):
                key, value = self.value(depth + 1), self.value(depth + 1)
                if key['type'] not in ('number', 'string'):
                    raise ValueError('Unsupported table key type')
                identity = (key['type'], float(key['decimal']) if key['type'] == 'number' else key['hex'])
                if identity in keys:
                    raise ValueError('Duplicate typed table key')
                keys.add(identity)
                rows.append({'key': key, 'value': value})
            self.match(r'\}')
            return {'type': 'table', 'entries': rows}
        raise ValueError(f'Unknown token at offset {self.position}')


def decode_evidence(text: str) -> dict:
    if len(text) > MAX_INPUT:
        raise ValueError('Input exceeds 1 MiB')
    text = text.lstrip('\ufeff').replace('\r\n', '\n').strip()
    if not text.isascii():
        raise ValueError('Evidence must be ASCII; strings are hex encoded')
    text = reassemble(text)
    match = re.fullmatch(r'RS-PERSIST-EVIDENCE-1\nBYTES=(\d{1,6})\nCHECK=([0-9A-F]{8})\n([^\n]*)\nRS-PERSIST-EVIDENCE-END', text)
    if not match:
        raise ValueError('Invalid envelope, missing end marker, or extra text')
    size, check, body = match.groups()
    if len(body) != int(size) or len(body) > MAX_BODY:
        raise ValueError('Evidence byte length mismatch or overflow')
    if checksum(body) != check:
        raise ValueError('Evidence checksum mismatch: missing/changed copied text')
    parser = Parser(body)
    result = parser.value()
    if parser.position != len(body):
        raise ValueError('Trailing data after root value')
    return result


def main() -> int:
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument('input', type=Path)
    cli.add_argument('-o', '--output', required=True, type=Path)
    args = cli.parse_args()
    try:
        if args.input.stat().st_size > MAX_INPUT:
            raise ValueError('Input exceeds 1 MiB')
        result = decode_evidence(args.input.read_text(encoding='utf-8-sig'))
        # Exclusive creation: a maintenance export must not overwrite another fixture.
        with args.output.open('x', encoding='utf-8') as handle:
            json.dump(result, handle, ensure_ascii=False, indent=2)
            handle.write('\n')
    except (OSError, UnicodeError, ValueError) as error:
        print(f'ERROR: {error}', file=sys.stderr)
        return 1
    print(f'Decoded copied evidence: {args.output} (not save recovery)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
