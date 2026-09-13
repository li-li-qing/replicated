#!/usr/bin/env python3
"""Audit an exact changed-files ZIP against two directory snapshots (read-only).

Does not extract, execute tests, delete files, or apply patches to a game.
A passing manifest is not semantic correctness or runtime verification.
Deletion approval must match the complete removed-file set exactly.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import zipfile

MAX_FILES=20000
MAX_FILE=16*1024*1024
MAX_TOTAL=256*1024*1024
PRIVATE_PARTS={'.git','.svn','__pycache__','.pytest_cache','.env','savedvariables','userdata'}
PRIVATE_SUFFIXES={'.udf','.crash','.pyc','.pyo','.pem','.key'}
RESERVED=re.compile(r'^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',re.I)

def safe_name(name: str) -> str:
    if not name or name.startswith('/') or '\\' in name or any(c in name for c in ':<>"|?*') or any(ord(c)<32 for c in name): raise ValueError('unsafe_path:'+repr(name))
    if any(p in ('','.', '..') or p.endswith((' ','.')) or RESERVED.match(p) for p in name.split('/')): raise ValueError('unsafe_path:'+repr(name))
    return name

def digest(data: bytes) -> str:return hashlib.sha256(data).hexdigest()

def walk_error(error):
    raise error

def snapshot(root: Path) -> dict:
    root=Path(root)
    if root.is_symlink() or not root.is_dir(): raise ValueError('snapshot_not_regular_directory')
    result={};seen=set();total=0
    for current,dirs,files in os.walk(root,followlinks=False,onerror=walk_error):
        for name in dirs+files:
            path=Path(current)/name;rel=safe_name(path.relative_to(root).as_posix())
            if path.is_symlink(): raise ValueError('snapshot_symlink:'+rel)
            fold=rel.casefold()
            if fold in seen:raise ValueError('snapshot_case_collision:'+rel)
            seen.add(fold)
        for name in files:
            p=Path(current)/name;rel=p.relative_to(root).as_posix()
            if not stat.S_ISREG(p.stat().st_mode):raise ValueError('snapshot_non_regular:'+rel)
            if p.stat().st_size>MAX_FILE:raise ValueError('snapshot_file_limit:'+rel)
            with p.open('rb') as f:data=f.read(MAX_FILE+1)
            total+=len(data)
            if len(data)>MAX_FILE or total>MAX_TOTAL or len(result)>=MAX_FILES:raise ValueError('snapshot_budget')
            result[rel]={'bytes':len(data),'sha256':digest(data)}
    return result

def archive_files(archive: Path) -> dict:
    archive=Path(archive)
    if archive.is_symlink() or not archive.is_file():raise ValueError('zip_not_regular')
    if archive.stat().st_size>MAX_TOTAL:raise ValueError('zip_input_limit')
    result={};seen=set();total=0
    with zipfile.ZipFile(archive) as z:
        infos=z.infolist()
        if len(infos)>MAX_FILES:raise ValueError('zip_entry_count_limit')
        for info in infos:
            name=safe_name(info.filename[:-1] if info.is_dir() else info.filename)
            if info.orig_filename!=info.filename:raise ValueError('zip_embedded_nul')
            fold=name.casefold()
            if fold in seen:raise ValueError('zip_duplicate_or_case_collision:'+name)
            seen.add(fold)
            mode=stat.S_IFMT(info.external_attr>>16)
            if mode not in (0,stat.S_IFDIR if info.is_dir() else stat.S_IFREG):raise ValueError('zip_non_regular:'+name)
            if info.flag_bits&1:raise ValueError('zip_encrypted:'+name)
            if set(fold.split('/')) & PRIVATE_PARTS or Path(fold).suffix in PRIVATE_SUFFIXES or Path(fold).name.startswith('.env.'):
                raise ValueError('private_or_generated_payload:'+name)
            if info.is_dir():continue
            total+=info.file_size
            if info.file_size>MAX_FILE or total>MAX_TOTAL:raise ValueError('zip_expanded_budget')
            with z.open(info) as f:data=f.read(MAX_FILE+1)
            if len(data)!=info.file_size or len(data)>MAX_FILE:raise ValueError('zip_size_mismatch')
            result[name]={'bytes':len(data),'sha256':digest(data)}
    # A regular file cannot also serve as a directory, even with different case.
    files_fold={n.casefold() for n in result}
    for name in seen:
        parts=name.split('/')
        if any('/'.join(parts[:i]) in files_fold for i in range(1,len(parts))):raise ValueError('zip_file_directory_collision:'+name)
    return result

def audit_patch(base: Path, current: Path, archive: Path, approved_deletions=()) -> dict:
    before,after=snapshot(base),snapshot(current)
    added=sorted(set(after)-set(before));deleted=sorted(set(before)-set(after))
    changed=sorted(k for k in before.keys()&after.keys() if before[k]!=after[k])
    approvals=[safe_name(n) for n in approved_deletions]
    if sorted(set(approvals))!=deleted or len(approvals)!=len(set(approvals)):raise ValueError('deletion_approval_mismatch:'+','.join(deleted))
    packed=archive_files(archive);expected=set(added+changed)
    if set(packed)!=expected:
        raise ValueError('delta_members_mismatch;missing='+','.join(sorted(expected-set(packed)))+';extra='+','.join(sorted(set(packed)-expected)))
    for name in expected:
        if packed[name]!=after[name]:raise ValueError('final_zip_payload_mismatch:'+name)
    merged={k:v for k,v in before.items() if k not in deleted};merged.update(packed)
    if merged!=after:raise ValueError('overlay_mismatch')
    return {'status':'verified_payload_only','added':added,'changed':changed,'deleted':deleted,
            'unchanged_count':len(before)-len(changed)-len(deleted),'files':packed,
            'archive_sha256':digest(Path(archive).read_bytes()),'tests_executed':False,
            'privacy':'filename screening only; manually review text for personal data and secrets'}

def main() -> int:
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--base',type=Path,required=True);ap.add_argument('--current',type=Path,required=True)
    ap.add_argument('--zip',type=Path,required=True);ap.add_argument('--allow-deletion',action='append',default=[])
    a=ap.parse_args()
    try:
        print(json.dumps(audit_patch(a.base,a.current,a.zip,a.allow_deletion),ensure_ascii=False,indent=2));return 0
    except (ValueError,OSError,zipfile.BadZipFile,RuntimeError) as e:
        print(json.dumps({'status':'rejected','error':str(e)},ensure_ascii=False),file=sys.stderr);return 1
if __name__=='__main__':raise SystemExit(main())
