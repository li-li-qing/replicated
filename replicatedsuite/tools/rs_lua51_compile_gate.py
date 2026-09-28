#!/usr/bin/env python3
"""Release gate: compile every shipped Lua file with a real Lua 5.1 compiler."""
from pathlib import Path
import shutil, subprocess, sys
ROOT=Path(__file__).resolve().parents[1]
CANDIDATES=('luac5.1','luac-5.1')
exe=next((shutil.which(x) for x in CANDIDATES if shutil.which(x)),None)
if not exe:
    print('BLOCKED: real Lua 5.1 compiler not found (need luac5.1/luac-5.1).',file=sys.stderr)
    sys.exit(2)
files=[]
for p in ROOT.rglob('*.lua'):
    rel=p.relative_to(ROOT)
    if rel.parts and rel.parts[0]=='tools':
        continue
    files.append(p)
failed=[]
for p in sorted(files):
    r=subprocess.run([exe,'-p',str(p)],cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    if r.returncode: failed.append((p.relative_to(ROOT),r.stderr.strip() or r.stdout.strip()))
if failed:
    print(f'FAIL: Lua 5.1 compile gate: {len(failed)} file(s)',file=sys.stderr)
    for p,e in failed: print(f'  {p}: {e}',file=sys.stderr)
    sys.exit(1)
print(f'PASS: Lua 5.1 compile gate: {len(files)} shipped Lua files ({exe})')
