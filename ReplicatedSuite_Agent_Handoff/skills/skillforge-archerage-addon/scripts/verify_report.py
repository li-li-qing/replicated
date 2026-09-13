#!/usr/bin/env python3
"""Read-only receiver for Replicated Suite RS-ERROR-PAGE-1 / HUD_TEMPLATE_V2.

Python >=3.10, standard library only. Checks copying integrity, not authenticity,
completeness of the collector, game truth, or the safety of applying a layout.
No Lua execution, no network, no game/save writes. Output is opt-in, exclusive.
"""
from __future__ import annotations
import argparse
import json
import math
from pathlib import Path
import re
import sys
import zlib

MAX_INPUT = 12 * 1024 * 1024
MAX_WIRE = 2 * 1024 * 1024
MAX_RAW = 1024 * 1024
MAX_PAGES = 8192
HEADER = re.compile(rb'RS-ERROR-PAGE-1;ID=([A-Za-z0-9_.-]{1,48});PAGE=([0-9]{1,5})/([0-9]{1,5});'
    rb'TOTAL_BYTES=([0-9]{1,8});TOTAL_CHECK=([A-Fa-f0-9]{8});'
    rb'RAW_BYTES=([0-9]{1,8});RAW_CHECK=([A-Fa-f0-9]{8});OFFSET=([0-9]{1,8});'
    rb'DATA_BYTES=([0-9]{1,8});DATA_CHECK=([A-Fa-f0-9]{8});DATA=')
END = b';RS-ERROR-PAGE-END'

def check(data: bytes) -> str:
    return f'{zlib.adler32(data):08X}'

def decode_pages(payload: bytes) -> dict:
    if not isinstance(payload, bytes) or len(payload) > MAX_INPUT:
        raise ValueError('input_limit_or_type')
    if payload.startswith(b'\xef\xbb\xbf'): payload = payload[3:]
    # The wire escapes source CR/LF; only physical display wraps are removable.
    display_breaks = payload.count(b'\r') + payload.count(b'\n')
    payload = payload.replace(b'\r', b'').replace(b'\n', b'')
    pos, copies, duplicates = 0, 0, 0
    common = None
    pages = {}
    while pos < len(payload):
        while pos < len(payload) and payload[pos] in b' \t\r\n': pos += 1
        if pos == len(payload): break
        m = HEADER.match(payload, pos)
        if m is None: raise ValueError(f'invalid_header_or_trailing_text_at_byte:{pos}')
        rid, idx, total, size, fullcheck, rawsize, rawcheck, offset, length, partcheck = m.groups()
        idx, total, size, rawsize, offset, length = map(int, (idx,total,size,rawsize,offset,length))
        if not (1 <= idx <= total <= MAX_PAGES and 0 <= size <= MAX_WIRE
                and 0 <= rawsize <= MAX_RAW and 0 <= offset <= size and 0 <= length <= min(32768, size-offset)):
            raise ValueError('page_bounds')
        identity = (rid, total, size, fullcheck.upper(), rawsize, rawcheck.upper())
        if common is None: common = identity
        if common != identity: raise ValueError('mixed_report_identity_or_totals')
        start, stop = m.end(), m.end()+length
        data = payload[start:stop]
        # Maintenance: consume the declared BYTE count. A marker is legal data;
        # splitting on END or applying unicode_escape would silently corrupt it.
        if len(data) != length or payload[stop:stop+len(END)] != END:
            raise ValueError('truncated_data_or_end_marker')
        data.decode('utf-8', errors='strict')
        if check(data) != partcheck.decode().upper(): raise ValueError('page_checksum')
        entry = (offset, data)
        if idx in pages:
            if pages[idx] != entry: raise ValueError('conflicting_duplicate_page')
            duplicates += 1
        pages[idx] = entry
        copies += 1
        if copies > MAX_PAGES * 4: raise ValueError('copy_count_limit')
        pos = stop+len(END)
    if common is None: raise ValueError('no_pages')
    rid,total,size,fullcheck,rawsize,rawcheck = common
    missing = sorted(set(range(1,total+1))-set(pages))
    if missing: raise ValueError('missing_pages:' + ','.join(map(str,missing[:32])))
    chunks, expected = [], 0
    for idx in range(1,total+1):
        offset,data=pages[idx]
        if offset != expected: raise ValueError(f'non_contiguous_offset:page={idx}')
        chunks.append(data);expected+=len(data)
    wire=b''.join(chunks)
    if len(wire)!=size or check(wire)!=fullcheck.decode(): raise ValueError('total_checksum_or_length')
    raw=bytearray();p=0
    while p<len(wire):
        value=wire[p];p+=1
        if value==92:
            if p>=len(wire) or wire[p] not in (92,110,114): raise ValueError('invalid_escape')
            value={92:92,110:10,114:13}[wire[p]];p+=1
        raw.append(value)
        if len(raw)>MAX_RAW: raise ValueError('raw_limit')
    raw=bytes(raw)
    if len(raw)!=rawsize or check(raw)!=rawcheck.decode(): raise ValueError('raw_checksum_or_length')
    return {'status':'verified_copy','id':rid.decode(),'pages':total,'duplicates':duplicates,
            'display_breaks_removed':display_breaks,'wire_bytes':size,'wire_check':fullcheck.decode(),'raw_bytes':rawsize,
            'raw_check':rawcheck.decode(),'raw':raw.decode('utf-8',errors='strict')}

GROUPS = {
 'BASE': {'plate':{'x','y','w','h'},'info':{'x','y','font','enabled','class','gear','distance'}},
 'AURA': {k:{'x','y','size','font','spacing','perRow','rows','alpha','enabled'} for k in ('buffs','debuffs')},
 'EQUIP':{k:{'x','y','size','alpha','enabled'} for k in ('mainHand','offHand','ranged','wings')},
 'CAST':{'castBar':{'x','y','w','h','font','alpha','enabled','text'}},
 'CLASS':{'class':{'x','y','size','alpha','enabled'}}}
NUM = re.compile(r'-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\Z')
BOOL_FIELDS = {'enabled','class','gear','distance','text'}

def pairs(text: str, sep: str) -> dict:
    result={}
    for piece in text.split(sep):
        if '=' not in piece: raise ValueError('missing_key_value')
        key,value=piece.split('=',1)
        if not key or not value or key in result: raise ValueError('duplicate_or_empty_key')
        result[key]=value
    return result

def number(value: str) -> int | float:
    if len(value)>64 or not NUM.fullmatch(value): raise ValueError('invalid_numeric_value')
    n=float(value)
    if not math.isfinite(n): raise ValueError('non_finite_number')
    return int(value) if re.fullmatch(r'-?[0-9]+',value) else n

def parse_hud(raw: str) -> dict:
    if len(raw.encode())>32768: raise ValueError('hud_limit')
    lines=raw.split('\n')
    if len(lines)!=14 or lines[0]!='RS-HUD-TEMPLATE-2' or lines[-1]!='RS-HUD-TEMPLATE-END':
        raise ValueError('hud_envelope_or_line_count')
    if not re.fullmatch(r'LINES=11;PATCH=[A-Za-z0-9_.-]{1,96}',lines[1]): raise ValueError('hud_header')
    records=lines[2:-1]
    if not records[0].startswith('HUD_TEMPLATE_V2;META;'): raise ValueError('hud_meta')
    meta=pairs(records[0][len('HUD_TEMPLATE_V2;META;'):],';')
    if set(meta)!={'build','viewport','uiScale','source','coords'}: raise ValueError('hud_meta_fields')
    if meta['source'] not in ('draft','saved') or meta['coords']!='screen-y-v1': raise ValueError('hud_source_or_coords')
    if not re.fullmatch(r'[1-9][0-9]{0,5}x[1-9][0-9]{0,5}',meta['viewport']): raise ValueError('hud_viewport')
    if number(meta['uiScale'])<=0: raise ValueError('hud_scale')
    scopes={'PLAYER':{},'TARGET':{}}
    expected=[(scope,group) for scope in scopes for group in GROUPS]
    for row,(scope,group) in zip(records[1:],expected):
        fields=row.split(';')
        if fields[:3]!=['HUD_TEMPLATE_V2',scope,group]: raise ValueError('hud_record_missing_duplicate_or_order')
        result={};tokens=fields[3:]
        if group=='BASE':
            if not tokens or not tokens[0].startswith('scale='): raise ValueError('hud_base_scale')
            result['scale']=number(tokens.pop(0)[6:])
            if result['scale']<=0: raise ValueError('hud_base_scale')
        for token in tokens:
            m=re.fullmatch(r'([A-Za-z]+)\{([^{}]+)\}',token)
            if not m: raise ValueError('hud_group_shape')
            name,body=m.groups()
            if name in result or name not in GROUPS[group]: raise ValueError('hud_component_duplicate_or_unknown')
            values=pairs(body,',')
            if set(values)!=GROUPS[group][name]: raise ValueError('hud_component_fields')
            parsed={k:number(v) for k,v in values.items()}
            if any(parsed[k] not in (0,1) for k in BOOL_FIELDS.intersection(parsed)): raise ValueError('hud_boolean')
            result[name]=parsed
        if set(result)!=set(GROUPS[group])|({'scale'} if group=='BASE' else set()): raise ValueError('hud_missing_component')
        scopes[scope][group]=result
    return {'format':'HUD_TEMPLATE_V2','meta':meta,'scopes':scopes,
            'application':'not_applied; validate against current project ranges and user intent'}

def main() -> int:
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('input',type=Path);ap.add_argument('--hud',action='store_true',help='also validate exact HUD_TEMPLATE_V2 schema')
    ap.add_argument('--output',type=Path,help='write verified raw text to a NEW file; never overwrite')
    args=ap.parse_args()
    try:
        if not args.input.is_file() or args.input.is_symlink() or args.input.stat().st_size>MAX_INPUT: raise ValueError('input_not_regular_or_too_large')
        with args.input.open('rb') as f:payload=f.read(MAX_INPUT+1)
        result=decode_pages(payload);raw=result.pop('raw')
        if args.hud:result['hud']=parse_hud(raw)
        if args.output:
            with args.output.open('xb') as f:f.write(raw.encode('utf-8'))
            result['output']=str(args.output)
        print(json.dumps(result,ensure_ascii=False,indent=2));return 0
    except (ValueError,OSError) as e:
        print(json.dumps({'status':'rejected','error':str(e)},ensure_ascii=False),file=sys.stderr);return 1
if __name__=='__main__':raise SystemExit(main())
