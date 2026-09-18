/* Offline collector tests: browser File inputs are simulated here; real Chromium is tested separately.
 * Regression target: a 3500-byte report may omit evidence, but a requested folder archive must
 * contain EVERY selected file byte or refuse entirely. No Native or game files are read in tests. */
'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),vm=require('node:vm');
const {webcrypto}=require('node:crypto');
const html=fs.readFileSync(path.join(__dirname,'rs_udf_evidence.html'),'utf8');
const core=html.match(/<script id="collector-core">([\s\S]*?)<\/script>/);
assert.ok(core,'read-only collector core missing');
const context={TextEncoder,Uint8Array,Uint32Array,DataView,ArrayBuffer,crypto:webcrypto,Date,console};
vm.createContext(context);vm.runInContext(core[1],context);const C=context.RSUdfEvidence;
assert.ok(C && typeof C.build==='function' && typeof C.plan==='function','collector API missing');
let passed=0,failed=0;
async function test(name,fn){try{await fn();passed++;console.log('PASS udf '+name);}catch(e){failed++;console.log('FAIL udf '+name+': '+e.message);}}
function file(name,raw){const b=Buffer.from(raw);return {webkitRelativePath:name,size:b.length,lastModified:1700000000000,arrayBuffer:async()=>Uint8Array.from(b).buffer};}
function consent(){return {clientClosed:true,privacyAccepted:true};}
(async()=>{
 await test('standard ZIP CRC32 known vector',()=>assert.equal(C.crc32(new TextEncoder().encode('123456789')),0xCBF43926));
 await test('files sort without guessing database file extensions',()=>{
  const p=C.plan([file('udf/000001.sst','a'),file('udf/LOCK',''),file('udf/子目录/opaque.bin','\0x')]);
  assert.equal(p.count,3);assert.equal(p.totalBytes,3);assert.ok(p.files.some(x=>x.path==='udf/LOCK'));
 });
 await test('zero-length root refuses as incomplete evidence',()=>assert.throws(()=>C.plan([]),/EMPTY/));
 await test('wrong directory and parent traversal refuse before reading',()=>{
  for(const p of ['USER/udf/001','Addon/001','udf/../secret','udf/a/../../secret','udf//bad','udf/./bad','udf/a\\b','/udf/001'])assert.throws(()=>C.plan([file(p,'x')]),/PATH|DIRECTORY/);
 });
 await test('case-insensitive duplicate refuses ambiguity',()=>assert.throws(()=>C.plan([file('udf/LOCK','a'),file('udf/lock','b')]),/DUPLICATE/));
 await test('declared size over limit refuses without reading',async()=>{
  let read=0;const f=file('udf/huge','a');f.size=C.MAX_BYTES+1;f.arrayBuffer=async()=>{read++;return new ArrayBuffer(1)};
  await assert.rejects(()=>C.build([f],consent()),/LIMIT/);assert.equal(read,0);
 });
 await test('file count and invalid length are bounded',()=>{
  assert.throws(()=>C.plan(Array.from({length:C.MAX_FILES+1},(_,i)=>file('udf/'+i,''))),/LIMIT/);
  const f=file('udf/x','x');f.size=NaN;assert.throws(()=>C.plan([f]),/SIZE/);
 });
 await test('missing privacy or closed-client confirmation forbids access',async()=>{
  let read=0;const f=file('udf/x','a');f.arrayBuffer=async()=>{read++;return new ArrayBuffer(1)};
  await assert.rejects(()=>C.build([f],{}),/CONFIRM/);assert.equal(read,0);
  await assert.rejects(()=>C.build([f],{clientClosed:true}),/CONFIRM/);assert.equal(read,0);
 });
 await test('read failure rejects whole output instead of skipping a database file',async()=>{
  const bad=file('udf/b.sst','a');bad.arrayBuffer=async()=>{throw new Error('locked')};
  await assert.rejects(()=>C.build([file('udf/a.sst','a'),bad],consent()),/READ/);
 });
 await test('actual truncation refuses changed file',async()=>{
  const f=file('udf/a','abcdef');f.arrayBuffer=async()=>new ArrayBuffer(2);await assert.rejects(()=>C.build([f],consent()),/CHANGED/);
 });
 await test('opaque binary UTF8 and empty files round trip as full archive',async()=>{
  const data=Uint8Array.from({length:65536},(_,i)=>(i*37)%256);
  const result=await C.build([file('udf/数据.sst',data),file('udf/CURRENT','MANIFEST-000123\n'),file('udf/LOCK','')],consent());
  assert.equal(result.manifest.files.length,3);assert.equal(result.manifest.source,'user_selected_udf_files');
  assert.equal(result.manifest.consistency,'client_closed_user_confirmed_not_atomic');
  const bin=result.manifest.files.find(x=>x.path==='udf/数据.sst');assert.equal(bin.bytes,data.length);assert.match(bin.sha256,/^[a-f0-9]{64}$/);
  fs.writeFileSync(path.join(__dirname,'.udf_collector_test.zip'),Buffer.from(result.bytes));
  fs.writeFileSync(path.join(__dirname,'.udf_collector_expected.bin'),data);
 });
 await test('no full paths username or fabricated integrity proof in manifest',async()=>{
  const r=await C.build([file('udf/000001','x')],consent());const json=JSON.stringify(r.manifest);
  assert.ok(!json.includes('USERPROFILE')&&!json.includes('C:\\'));
  assert.equal(r.manifest.saveIntegrityVerified,false);assert.equal(r.manifest.omittedFiles,0);
 });
 await test('fresh plan on build rejects changed file list despite earlier valid preview',async()=>{
  const list=[file('udf/a','x')];C.plan(list);list.push(file('ArcheRage/private','x'));
  await assert.rejects(()=>C.build(list,consent()),/DIRECTORY/);
 });
 console.log('UDF RESULT '+passed+' passed / '+failed+' failed');process.exitCode=failed?1:0;
})();
