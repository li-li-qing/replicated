#!/usr/bin/env python3
"""Phase 0 architecture debt audit. Reports known debt without rewriting runtime code."""
from pathlib import Path
import re, sys
ROOT=Path(__file__).resolve().parents[1]
issues=[]
def add(kind,path,line,text): issues.append((kind,str(path.relative_to(ROOT)),line,text.strip()))
# Core -> concrete Feature access (known debt; warning in Phase 0)
for p in (ROOT/'core').glob('*.lua'):
    for i,line in enumerate(p.read_text(encoding='utf-8',errors='replace').splitlines(),1):
        if re.search(r'\bS\.Features\.[A-Za-z_]',line): add('CORE_FEATURE',p,i,line)
# Presentation -> private Feature.State (targeted blocker for new debt, currently enumerate all)
for p in (ROOT/'presentation').rglob('*.lua'):
    for i,line in enumerate(p.read_text(encoding='utf-8',errors='replace').splitlines(),1):
        if 'Feature.State' in line: add('PRESENTATION_STATE',p,i,line)
# Giant shipped Lua files
for root in ('core','features','services','presentation'):
    for p in (ROOT/root).rglob('*.lua'):
        count=sum(1 for _ in p.open(encoding='utf-8',errors='replace'))
        if count>4000: issues.append(('GIANT_FILE',str(p.relative_to(ROOT)),count,f'{count} lines'))
# TOC duplicate/missing entries
seen={}
for i,raw in enumerate((ROOT/'toc.g').read_text(encoding='utf-8',errors='replace').splitlines(),1):
    s=raw.strip()
    if not s or s.startswith('#') or s.startswith('--'): continue
    if s in seen: issues.append(('TOC_DUP', 'toc.g', i, f'{s} first at {seen[s]}'))
    else: seen[s]=i
    if s.endswith('.lua') and not (ROOT/s).is_file(): issues.append(('TOC_MISSING','toc.g',i,s))
print(f'ARCHITECTURE AUDIT: {len(issues)} known issue(s)')
for kind,path,line,text in issues: print(f'{kind}\t{path}:{line}\t{text}')
# Phase 0 is inventory-only: missing TOC files/duplicates are hard failures; architectural debt is reported.
hard=[x for x in issues if x[0] in ('TOC_DUP','TOC_MISSING')]
sys.exit(1 if hard else 0)
