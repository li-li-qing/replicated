#!/usr/bin/env python3
# ---------------------------------------------------------------------
# Replicated Suite · 架构审查
# 作者：Replicated
# QQ群：1104129461
# ---------------------------------------------------------------------
"""架构债务审查：报告已知问题，不改写运行时代码。"""
from pathlib import Path
import re, sys
ROOT=Path(__file__).resolve().parents[1]
issues=[]
def add(kind,path,line,text): issues.append((kind,str(path.relative_to(ROOT)),line,text.strip()))
# Core 对具体 Feature 的访问属于已知架构债务，此处作为警告报告。
for p in (ROOT/'core').glob('*.lua'):
    for i,line in enumerate(p.read_text(encoding='utf-8',errors='replace').splitlines(),1):
        if re.search(r'\bS\.Features\.[A-Za-z_]',line): add('CORE_FEATURE',p,i,line)
# 表现层访问私有 Feature.State 的检查用于阻止新增债务，当前先枚举全部调用。
for p in (ROOT/'presentation').rglob('*.lua'):
    for i,line in enumerate(p.read_text(encoding='utf-8',errors='replace').splitlines(),1):
        if 'Feature.State' in line: add('PRESENTATION_STATE',p,i,line)
# 列出发行包中过大的 Lua 文件，供拆分审查。
for root in ('core','features','services','presentation'):
    for p in (ROOT/root).rglob('*.lua'):
        count=sum(1 for _ in p.open(encoding='utf-8',errors='replace'))
        if count>4000: issues.append(('GIANT_FILE',str(p.relative_to(ROOT)),count,f'{count} lines'))
# 检查 TOC 重复条目与缺失文件。
seen={}
for i,raw in enumerate((ROOT/'toc.g').read_text(encoding='utf-8',errors='replace').splitlines(),1):
    s=raw.strip()
    if not s or s.startswith('#') or s.startswith('--'): continue
    if s in seen: issues.append(('TOC_DUP', 'toc.g', i, f'{s} first at {seen[s]}'))
    else: seen[s]=i
    if s.endswith('.lua') and not (ROOT/s).is_file(): issues.append(('TOC_MISSING','toc.g',i,s))
print(f'ARCHITECTURE AUDIT: {len(issues)} known issue(s)')
for kind,path,line,text in issues: print(f'{kind}\t{path}:{line}\t{text}')
# 本工具只盘点问题：TOC 缺失或重复是硬失败，架构债务单独报告。
hard=[x for x in issues if x[0] in ('TOC_DUP','TOC_MISSING')]
sys.exit(1 if hard else 0)
