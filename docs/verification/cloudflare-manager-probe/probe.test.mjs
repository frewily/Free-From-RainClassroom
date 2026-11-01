import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import worker,{BUILD} from './worker.mjs';
import {ACCOUNT,SCOPE_NAMES,WORKERS_ADMIN_SCOPE_NAMES,CLOSED_SOURCE,makeSpec,restrictedApi,runProbe,validateConfig} from './probe.mjs';
import {curlSpec,moduleBody,checkWorkersAdminContinuation,compilerDetails,checkModuleFormatContinuation,checkAwaitingModuleResume} from './live.mjs';

const source=await readFile(new URL('./worker.mjs',import.meta.url),'utf8');
const spec=makeSpec('012345abcdef'),base=`/accounts/${ACCOUNT}`,workerPath=`${base}/workers/scripts/${spec.worker}`;
const KV_ID='a'.repeat(32),DB_ID='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
function fixture(options={}) {
  let kv=false,db=false,deployed=false,enabled=false,bindings=[],gate='',stored='',deletedSource='';
  let kvReads=0,ticks=0;
  const rows=new Map(),calls=[],snapshots=[];
  const response=(result,status=200)=>({status,body:{success:status===200||status===201,result}});
  const api=async(method,path,body,kind)=>{
    calls.push({method,path,body,kind});
    if(path==='/user')return response({id:'synthetic-user-id',private_field:'PRIVATE_PROFILE_FIELD'});
    if(path==='/memberships')return response([{status:'accepted',account:{id:options.otherAccount?'c'.repeat(32):ACCOUNT}}]);
    if(path===`${base}/workers/subdomain`)return response({subdomain:'2994508531'});
    if(path.startsWith(`${base}/storage/kv/namespaces?page=`))return response(kv?[{id:KV_ID,title:spec.kv}]:[]);
    if(path.startsWith(`${base}/d1/database?page=`))return response(db?[{uuid:DB_ID,name:spec.d1}]:[]);
    if(path===`${base}/storage/kv/namespaces`&&method==='POST'){kv=true;if(options.lostKvResponse)throw Error('PRIVATE_TRANSPORT');return response({id:KV_ID,title:spec.kv});}
    if(path===`${base}/d1/database`&&method==='POST'){db=true;if(options.lostDbResponse)throw Error('PRIVATE_TRANSPORT');return response({uuid:DB_ID,name:spec.d1});}
    if(path===`${base}/storage/kv/namespaces/${KV_ID}`&&method==='DELETE'){if(options.deleteKvDenied)return {status:403,body:{success:false,errors:[{code:10000,message:'PRIVATE_ERROR'}]}};kv=false;return response(null);}
    if(path===`${base}/d1/database/${DB_ID}`&&method==='DELETE'){db=false;return response(null);}
    if(path===`${base}/storage/kv/namespaces/${KV_ID}/values/${spec.nonce}`) {
      if(method==='PUT'){stored=body;return response(null);}
      if(options.kvDelayed&&kvReads++<2)return {status:404,body:{success:false}};
      return {status:200,text:stored};
    }
    if(path===`${base}/d1/database/${DB_ID}/query`) {
      if(body.sql.startsWith('INSERT'))rows.set(body.params[0],body.params[1]);
      if(body.sql.startsWith('SELECT'))return response([{success:true,results:[{value:rows.get(body.params[0])}]}]);
      return response([{success:true,results:[]}]);
    }
    if(path===workerPath) {
      if(method==='GET')return {status:options.workerExists||deployed?200:404,body:null};
      assert.equal(method,'PUT');assert.equal(kind,'module');
      if(options.uploadDenied)return {status:403,response_kind:'json',body:{error:'insufficient_scope',errors:[{code:'10000',message:'PRIVATE_ERROR'}]}};
      deployed=true;bindings=body.bindings;deletedSource=body.source;
      if(options.uploadResponseLost&&body.source!==CLOSED_SOURCE)throw Error('PRIVATE_TRANSPORT');
      return response({id:spec.worker});
    }
    if(path===`${workerPath}/settings`)return deployed?response({bindings:options.externalBindings?[{name:'OWNER_ADDED_BINDING'}]:bindings}):{status:404};
    if(path===`${workerPath}/secrets`) {
      if(method==='GET')return response(gate?[{name:'PROBE_KEY',type:'secret_text'}]:[]);
      gate=body.text;bindings=[...bindings,{name:'PROBE_KEY',type:'secret_text'}];return response({name:'PROBE_KEY'});
    }
    if(path===`${workerPath}/secrets/PROBE_KEY`&&method==='DELETE'){gate='';bindings=bindings.filter(b=>b.name!=='PROBE_KEY');return response(null);}
    if(path===`${workerPath}/subdomain`) {
      if(method==='POST'){enabled=body.enabled;assert.equal(body.previews_enabled,false);}
      return response({enabled,previews_enabled:false});
    }
    throw Error('Unexpected synthetic API route');
  };
  const workerRequest=async(url,requestOptions)=>{
    assert.equal(new URL(url).hostname,`${spec.worker}.2994508531.workers.dev`);
    assert(deployed&&enabled);assert.equal(requestOptions.headers.Authorization,'Bearer '+gate);
    if(options.workerReadbackFails)return {status:503,body:{}};
    const result=await worker.fetch(new Request(url,requestOptions),{PROBE_KEY:gate,PROBE_KV:{get:async()=>stored},PROBE_DB:{prepare:sql=>{assert.equal(sql,'SELECT value FROM s0_probe WHERE id = ?');return {bind:id=>({first:async()=>({value:rows.get(id)})})};}}});
    return {status:result.status,body:await result.json()};
  };
  const execute=extra=>runProbe({request:api,workerRequest,source,spec,checkpoint:async state=>snapshots.push(state),sleep:async()=>{},now:()=>ticks++*1000,...extra});
  return {api,execute,calls,snapshots,assets:()=>({kv,db,deployed,enabled,bindings,gate,stored,source:deletedSource})};
}

test('the actual Worker handler reads API-created synthetic data and cleanup leaves only a closed empty Worker',async()=>{
  const f=fixture(),s=await f.execute();assert.equal(s.functional_result,'passed');assert.equal(s.account_discovery_verified,true);assert.equal(s.worker_binding_reads_verified,true);
  assert.equal(s.kv_api_roundtrip,true);assert.equal(s.d1_api_roundtrip,true);assert.equal(s.cleanup_verified,true);
  const upload=f.calls.find(c=>c.method==='PUT'&&c.path===workerPath&&c.body.bindings.some(b=>b.type==='d1'));
  assert.deepEqual(upload.body.bindings.find(b=>b.type==='d1'),{name:'PROBE_DB',type:'d1',database_id:DB_ID});
  const compileIndex=f.calls.findIndex(c=>c.method==='PUT'&&c.path===workerPath);
  assert.deepEqual(f.calls[compileIndex].body.bindings,[]);
  assert(f.calls.findIndex(c=>c.method==='POST'&&c.path===`${base}/storage/kv/namespaces`)>compileIndex);
  const a=f.assets();assert.deepEqual({kv:a.kv,db:a.db,enabled:a.enabled,bindings:a.bindings,gate:a.gate},{kv:false,db:false,enabled:false,bindings:[],gate:''});assert.equal(a.source,CLOSED_SOURCE);
  assert(f.calls.every(c=>!(c.method==='DELETE'&&c.path===workerPath)));
  const saved=JSON.stringify(f.snapshots);assert(!saved.includes(a.stored));assert(!saved.includes('PRIVATE_'));
});
for(const [name,option]of [['other account','otherAccount'],['existing Worker','workerExists']])test(name+' prevents every mutation',async()=>{
  const f=fixture({[option]:true}),s=await f.execute();assert.equal(s.functional_result,'not_passed');assert.equal(s.writes.length,0);assert(f.calls.every(c=>c.method==='GET'));
});
for(const option of ['lostKvResponse','lostDbResponse','uploadResponseLost','workerReadbackFails'])test(option+' is reconciled without recreating resources',async()=>{
  const f=fixture({[option]:true}),s=await f.execute();assert.equal(s.functional_result,'not_passed');assert.equal(s.cleanup_verified,true);
  assert.equal(f.assets().kv,false);assert.equal(f.assets().db,false);
  assert(f.calls.filter(c=>c.method==='POST'&&c.path===`${base}/storage/kv/namespaces`).length<=1);
  assert(f.calls.filter(c=>c.method==='POST'&&c.path===`${base}/d1/database`).length<=1);
});
test('KV propagation is checked with bounded reads instead of another write',async()=>{
  const f=fixture({kvDelayed:true}),s=await f.execute();assert.equal(s.functional_result,'passed');
  assert.equal(f.calls.filter(c=>c.method==='PUT'&&c.path.includes('/values/')).length,1);
});
test('a denied deletion remains a visible cleanup item',async()=>{
  const f=fixture({deleteKvDenied:true}),s=await f.execute();assert.equal(s.functional_result,'passed');assert.equal(s.cleanup_verified,false);assert.deepEqual(s.cleanup_pending,['kv']);assert.equal(f.assets().kv,true);assert(!JSON.stringify(s).includes('PRIVATE_ERROR'));
});
test('unexpected Worker bindings are retained rather than overwritten',async()=>{
  const f=fixture({externalBindings:true}),s=await f.execute();assert.equal(s.cleanup_verified,false);assert(s.cleanup_pending.includes('worker_shutdown_or_detach'));
  assert(!f.calls.some(c=>c.method==='PUT'&&c.body?.source===CLOSED_SOURCE));
  assert.equal(f.assets().kv,true);assert.equal(f.assets().db,true);
});
test('the API boundary rejects production resources, Admin operations, DNS and Cron',async()=>{
  const f=fixture(),api=restrictedApi(f.api,spec,{kv:KV_ID,d1:DB_ID});
  for(const [method,path]of [['DELETE',workerPath],['PUT',`${base}/workers/scripts/rain-client-s0-worker-20261027`],['PUT',`${workerPath}/schedules`],['PUT','/zones/anything/dns_records'],['DELETE',`${base}/storage/kv/namespaces/${'e'.repeat(32)}`],['GET',`/accounts/${'c'.repeat(32)}`]])await assert.rejects(()=>api(method,path));
  assert.equal(f.calls.length,0);
});
test('unverified scope IDs, extra permissions and the old identity client cannot start',async()=>{
  const config=JSON.parse(await readFile(new URL('./client-config.template.json',import.meta.url),'utf8'));
  assert.throws(()=>validateConfig(config));
  const fixtureConfig={client_id:'synthetic-public-client-id',official_scope_details_verified:true,scopes:SCOPE_NAMES.map((name,i)=>({name,id:name==='User Details Read'?'user-details.read':`synthetic-${i}.read`}))};
  assert.equal(validateConfig(fixtureConfig).length,5);
  assert.throws(()=>validateConfig({...fixtureConfig,client_id:'2bbe4ad5369475121ba814dd9e8d7d78'}));
  assert.throws(()=>validateConfig({...fixtureConfig,scopes:[...fixtureConfig.scopes,{name:'DNS Write',id:'dns.write'}]}));
});
test('Worker rejects unauthenticated and arbitrary input without reading any binding',async()=>{
  const env={PROBE_KEY:'synthetic-gate',PROBE_KV:{get:()=>{throw Error('must not read');}}};
  const req=(body,key='wrong')=>new Request('https://example.invalid/probe',{method:'POST',headers:{Authorization:'Bearer '+key},body:JSON.stringify(body)});
  assert.equal((await worker.fetch(req({}),env)).status,401);
  assert.equal((await worker.fetch(req({nonce:spec.nonce,expected_sha256:'a'.repeat(64),sql:'arbitrary'},env.PROBE_KEY),env)).status,400);
  assert.equal((await worker.fetch(new Request('https://example.invalid/health'),{})).status,200);
});
test('transport keeps secrets in stdin, rejects redirects by omission and confines the runtime host',()=>{
  const s=curlSpec('https://api.cloudflare.com/client/v4/user',{headers:{Authorization:'Bearer SYNTHETIC_OAUTH'},body:'SYNTHETIC_SECRET'});
  assert(!JSON.stringify(s.args).includes('SYNTHETIC'));assert(s.input.includes('SYNTHETIC_OAUTH'));assert.equal(s.args[0],'--disable');assert(!s.args.includes('--location'));assert(!s.args.includes('--retry'));
  for(const url of ['http://api.cloudflare.com/client/v4/user','https://outside.example/','https://dash.cloudflare.com/somewhere','https://elsewhere.workers.dev/probe'])assert.throws(()=>curlSpec(url));
  const body=moduleBody(source,[{name:'PROBE_DB',type:'d1',database_id:DB_ID}]);assert(body.contentType.startsWith('multipart/form-data; boundary='));assert(body.body.includes('name="metadata"'));assert(body.body.includes('"main_module":"probe.mjs"'));assert(body.body.includes('Content-Type: application/javascript+module\r\n'));assert(body.body.includes(source));
});
test('Workers Admin cannot silently replace the originally approved Editor profile',()=>{
  const config={client_id:'synthetic-public-client-id',official_scope_details_verified:true,scopes:WORKERS_ADMIN_SCOPE_NAMES.map((name,i)=>({name,id:name==='User Details Read'?'user-details.read':`synthetic-${i}.read`}))};
  assert.throws(()=>validateConfig(config));assert.equal(validateConfig(config,{workersAdminApproved:true}).length,5);
  assert.throws(()=>validateConfig({...config,scopes:[...config.scopes,{name:'DNS Write',id:'dns.write'}]},{workersAdminApproved:true}));
});
test('Worker upload denial records safe response details before allocating either store',async()=>{
  const f=fixture({uploadDenied:true}),s=await f.execute();assert.equal(s.functional_result,'not_passed');assert.equal(s.worker_created,false);assert.equal(s.worker_retained,false);assert.equal(s.cleanup_verified,true);
  const failed=s.writes.find(write=>write.http_status===403);assert.equal(failed.response_kind,'json');assert.equal(failed.provider_oauth_error,'insufficient_scope');assert.deepEqual(failed.error_codes,[10000]);assert(!JSON.stringify(s).includes('PRIVATE_ERROR'));
  assert(!f.calls.some(call=>call.method==='POST'&&[`${base}/storage/kv/namespaces`,`${base}/d1/database`].includes(call.path)));
});
test('a permission continuation requires the exact completed Editor failure and verified cleanup and revocation',()=>{
  const previous={probe:BUILD,client_id:'synthetic-client',account_id:ACCOUNT,stage:'finished',functional_result:'not_passed',worker_created:false,cleanup_verified:true,kv_api_roundtrip:true,d1_api_roundtrip:true,kv_removed:true,d1_removed:true,revocation_independently_verified:true,temporary_token_references_discarded:true,granted_scope_ids:['d1.write','workers-scripts.edit','workers-kv-storage.write','memberships.read','user-details.read'],writes:[{method:'PUT',path:workerPath,http_status:403}]};
  assert.doesNotThrow(()=>checkWorkersAdminContinuation(previous,'synthetic-client'));
  for(const change of [{worker_created:true},{cleanup_verified:false},{revocation_independently_verified:false},{kv_removed:false},{granted_scope_ids:['other.write']}])assert.throws(()=>checkWorkersAdminContinuation({...previous,...change},'synthetic-client'));
});
test('compiler diagnostics remove the OAuth credential, bearer values and email addresses',()=>{
  const messages=compilerDetails({status:400,body:{errors:[{code:10021,message:'SyntaxError at probe.mjs:2 SYNTHETIC_CREDENTIAL Bearer ANOTHER_SYNTHETIC user@example.invalid'}]}},'SYNTHETIC_CREDENTIAL');
  const saved=JSON.stringify(messages);assert(saved.includes('SyntaxError'));assert(!saved.includes('SYNTHETIC'));assert(!saved.includes('user@example.invalid'));
});
test('a module-format repair cannot bypass the existing Admin profile or a cleanup failure',()=>{
  const previous={probe:BUILD,client_id:'synthetic-client',account_id:ACCOUNT,stage:'finished',workers_admin_continuation:true,functional_result:'not_passed',worker_created:false,cleanup_verified:true,kv_removed:true,d1_removed:true,revocation_independently_verified:true,temporary_token_references_discarded:true,granted_scope_ids:['d1.write','workers-scripts.admin','workers-kv-storage.write','memberships.read','user-details.read'],writes:[{method:'PUT',path:workerPath,http_status:400,error_codes:[10021]}]};
  assert.doesNotThrow(()=>checkModuleFormatContinuation(previous,'synthetic-client'));
  for(const change of [{worker_created:true},{cleanup_verified:false},{revocation_independently_verified:false},{workers_admin_continuation:false},{granted_scope_ids:['other.write']}])assert.throws(()=>checkModuleFormatContinuation({...previous,...change},'synthetic-client'));
});

test('resuming a stopped authorization wait preserves the original scope, source and resource names',()=>{
  const scopes=['d1.write','workers-scripts.admin','workers-kv-storage.write','memberships.read','user-details.read'];
  const pending={stage:'awaiting_authorization',client_id:'synthetic-client',account_id:ACCOUNT,workers_admin_continuation:true,module_format_continuation:true,requested_scope_ids:scopes,worker_source_sha256:'a'.repeat(64)};
  const guard={spec,client_id:'synthetic-client',scopes,workers_admin_continuation:true,module_format_continuation:true};
  assert.deepEqual(checkAwaitingModuleResume(pending,guard,'synthetic-client',scopes,'a'.repeat(64)),spec);
  for(const change of [{stage:'exchanging_code'},{callback_state_verified:true},{writes:[]},{token_exchange_http_status:200},{worker_source_sha256:'b'.repeat(64)},{requested_scope_ids:['other.write']},{module_format_continuation:false}])assert.throws(()=>checkAwaitingModuleResume({...pending,...change},guard,'synthetic-client',scopes,'a'.repeat(64)));
  assert.throws(()=>checkAwaitingModuleResume(pending,{...guard,spec:{...spec,worker:'existing-production-worker'}},'synthetic-client',scopes,'a'.repeat(64)));
});
