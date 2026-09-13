#!/usr/bin/env python3
"""Compile text Lua sources using an explicitly identified Lua 5.1 interpreter.

No target chunks are executed; no shim, installation, network, or game APIs.
Exit 0 = syntax passed, 1 = syntax failure, 2 = blocked/not run.
Desktop Lua 5.1 syntax is NOT proof of Windows/RU sandbox or runtime compatibility.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

MAX_FILE=4*1024*1024
MAX_FILES=2000
HARNESS='local f,e=loadfile(arg[1]); if not f then io.stderr:write(tostring(e),"\\n"); os.exit(1) end\n'

def walk_error(error):
    raise error

def check_lua(files, executable='lua5.1') -> dict:
    result={'status':'blocked','checked':0,'passed':0,'failed':0,'files':[],
            'scope':'text syntax only; no chunks executed; no RU verification'}
    files=list(files)
    if not files or len(files)>MAX_FILES:
        result['reason']='empty_or_excessive_input_set';return result
    selected=shutil.which(str(executable))
    if selected is None:
        result['reason']='lua51_executable_not_found';return result
    exe=Path(selected).resolve()
    env={k:v for k,v in os.environ.items() if not k.startswith('LUA_')}
    try:
        version=subprocess.run([str(exe),'-e','io.write(_VERSION); if type(jit)=="table" then io.write("\\n", tostring(jit.version or "jit_variant")) end'],capture_output=True,text=True,timeout=5,env=env)
        result['interpreter']={'path':str(exe),'sha256':hashlib.sha256(exe.read_bytes()).hexdigest(),
                               'reported_version':version.stdout.strip()}
        if version.returncode!=0 or version.stdout.strip()!='Lua 5.1':
            result['reason']='wrong_or_unverified_lua_version';return result
        validated=[];seen=set()
        for candidate in files:
            p=Path(candidate)
            if p.is_symlink() or not p.is_file() or p.suffix.lower()!='.lua': raise ValueError('not_regular_lua_source:'+str(p))
            p=p.resolve()
            if str(p) in seen:raise ValueError('duplicate_source:'+str(p))
            seen.add(str(p))
            if p.stat().st_size>MAX_FILE:raise ValueError('source_size_limit:'+str(p))
            with p.open('rb') as f:data=f.read(MAX_FILE+1)
            if len(data)>MAX_FILE or data.startswith(b'\x1b'):raise ValueError('bytecode_or_oversized_source:'+str(p))
            validated.append((p,data))
        with tempfile.TemporaryDirectory(prefix='rs-lua51-check-') as tmp:
            driver=Path(tmp)/'compile_only.lua';driver.write_text(HARNESS,encoding='ascii')
            # Stage the exact bytes hashed above; source edits during validation
            # must not allow a different chunk to be parsed or bytecode loaded.
            for index,(p,data) in enumerate(validated):
                staged=Path(tmp)/f'source_{index}.lua';staged.write_bytes(data)
                run=subprocess.run([str(exe),str(driver),str(staged)],capture_output=True,text=True,errors='replace',timeout=5,env=env)
                ok=run.returncode==0
                result['files'].append({'path':str(p),'sha256':hashlib.sha256(data).hexdigest(),
                                        'ok':ok,'error':run.stderr[:3000] if not ok else ''})
                result['checked']+=1;result['passed' if ok else 'failed']+=1
        result['status']='failed' if result['failed'] else 'passed'
    except (OSError,ValueError,subprocess.TimeoutExpired) as e:
        result['reason']=str(e);result['status']='blocked'
    return result

def main() -> int:
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--lua',default='lua5.1',help='trusted Lua 5.1 executable, not a shell command')
    ap.add_argument('paths',nargs='+',type=Path,help='.lua files or directories; directories recurse without following symlinks')
    a=ap.parse_args();files=[]
    try:
        for path in a.paths:
            if path.is_symlink():raise ValueError('symlink_input')
            if path.is_dir():
                for current,dirs,names in os.walk(path,followlinks=False,onerror=walk_error):
                    if any((Path(current)/d).is_symlink() for d in dirs):raise ValueError('symlink_subdirectory')
                    files.extend(Path(current)/n for n in sorted(names) if n.lower().endswith('.lua'))
                    if len(files)>MAX_FILES:raise ValueError('source_count_limit')
            else:files.append(path)
        result=check_lua(files,a.lua)
    except (OSError,ValueError) as e:result={'status':'blocked','checked':0,'reason':str(e)}
    print(json.dumps(result,ensure_ascii=False,indent=2))
    return {'passed':0,'failed':1}.get(result['status'],2)
if __name__=='__main__':raise SystemExit(main())
