import {randomBytes,createHash} from 'node:crypto';
import {BUILD} from './worker.mjs';

export const ACCOUNT='6081b0f279a7de585cd27b877f1f5335';
export const SCOPE_NAMES=['D1 Write','Workers Editor','Workers KV Storage Write','Memberships Read','User Details Read'];
export const WORKERS_ADMIN_SCOPE_NAMES=SCOPE_NAMES.map(name=>name==='Workers Editor'?'Workers Admin':name);
export const CLOSED_SOURCE='export default {fetch(){return new Response("Stage-0 probe closed",{status:410})}};\n';
const base=`/accounts/${ACCOUNT}`;
const hash=text=>createHash('sha256').update(text).digest('hex');
class ProbeError extends Error {}
const check=(ok,code)=>{if(!ok)throw new ProbeError(code);};

export function makeSpec(nonce=randomBytes(6).toString('hex')) {
  check(/^[a-f0-9]{12}$/.test(nonce),'invalid_nonce');
  return Object.freeze({nonce,worker:`rain-client-s0-deploy-20261028-${nonce}`,kv:`rain-client-s0-kv-20261028-${nonce}`,d1:`rain-client-s0-db-20261028-${nonce}`});
}

export function validateConfig(config,{workersAdminApproved=false}={}) {
  check(config?.official_scope_details_verified===true,'scope_ids_not_verified');
  check(/^[A-Za-z0-9_-]{20,80}$/.test(config.client_id||'')&&config.client_id!=='2bbe4ad5369475121ba814dd9e8d7d78','separate_client_required');
  check(Array.isArray(config.scopes)&&config.scopes.length===5,'wrong_scope_count');
  const expected=workersAdminApproved?WORKERS_ADMIN_SCOPE_NAMES:SCOPE_NAMES;
  check(JSON.stringify(config.scopes.map(s=>s.name).sort())===JSON.stringify([...expected].sort()),'wrong_scope_names');
  check(config.scopes.every(s=>/^[a-z][a-z0-9-]{0,80}\.[a-z][a-z0-9-]{0,40}$/.test(s.id||''))&&new Set(config.scopes.map(s=>s.id)).size===5,'invalid_scope_ids');
  check(config.scopes.find(s=>s.name==='User Details Read').id==='user-details.read','wrong_identity_scope');
  return config.scopes.map(s=>s.id);
}

export function restrictedApi(request,spec,ids) {
  check(JSON.stringify(spec)===JSON.stringify(makeSpec(spec.nonce)),'invalid_spec');
  const worker=`${base}/workers/scripts/${spec.worker}`;
  return async(method,path,body,kind)=>{
    const list=/^\?page=([1-9]|10)&per_page=100$/;
    const allowed=method==='GET'&&['/user','/memberships',`${base}/workers/subdomain`,worker,`${worker}/settings`,`${worker}/secrets`,`${worker}/subdomain`].includes(path)||
      method==='GET'&&[`${base}/storage/kv/namespaces`,`${base}/d1/database`].some(prefix=>path.startsWith(prefix)&&list.test(path.slice(prefix.length)))||
      method==='POST'&&[`${base}/storage/kv/namespaces`,`${base}/d1/database`,`${worker}/subdomain`].includes(path)||
      method==='PUT'&&[worker,`${worker}/secrets`].includes(path)||
      method==='DELETE'&&path===`${worker}/secrets/PROBE_KEY`||
      ids.kv&&((method==='PUT'||method==='GET')&&path===`${base}/storage/kv/namespaces/${ids.kv}/values/${spec.nonce}`||method==='DELETE'&&path===`${base}/storage/kv/namespaces/${ids.kv}`)||
      ids.d1&&(method==='POST'&&path===`${base}/d1/database/${ids.d1}/query`||['GET','DELETE'].includes(method)&&path===`${base}/d1/database/${ids.d1}`);
    check(allowed,'request_outside_test_boundary');
    // Both approved profiles retain an empty, disabled Worker; deletion stays outside this probe.
    return request(method,path,body,kind);
  };
}

export async function runProbe({request,workerRequest,source,spec=makeSpec(),checkpoint=async()=>{},sleep=ms=>new Promise(r=>setTimeout(r,ms)),now=Date.now}) {
  const ids={};const api=restrictedApi(request,spec,ids);
  const state={probe:BUILD,account_id:ACCOUNT,spec,stage:'preflight',functional_result:'not_run',writes:[],cleanup_pending:[],worker_retained:false,credentials_saved_to_file:false};
  let kvAttempt=false,dbAttempt=false,workerAttempt=false;
  let gate=randomBytes(32).toString('hex'),value=randomBytes(32).toString('hex');
  const save=async(stage=state.stage)=>{state.stage=stage;try{await checkpoint(structuredClone(state));}catch{state.checkpoint_failed=true;}};
  async function call(method,path,body,kind,cleanup=false) {
    if(method!=='GET'){await save('writing_test_resource');check(cleanup||!state.checkpoint_failed,'checkpoint_failed');}
    const response=await api(method,path,body,kind);
    if(method!=='GET')state.writes.push({method,path,http_status:response.status,
      response_kind:response.response_kind||(response.body?'json':'unknown'),
      error_codes:Array.isArray(response.body?.errors)?response.body.errors.map(e=>typeof e.code==='number'?e.code:/^\d{1,9}$/.test(e.code||'')?Number(e.code):null).filter(Number.isSafeInteger).slice(0,10):[],
      ...(['insufficient_scope','invalid_token','invalid_request','access_denied','unauthorized','forbidden'].includes(response.body?.error)?{provider_oauth_error:response.body.error}:{}),
      ...(Array.isArray(response.compiler_details)?{compiler_details:response.compiler_details.filter(item=>typeof item==='string').slice(0,3).map(item=>item.replaceAll(gate||'\u0000','[probe_key]').replaceAll(value||'\u0000','[synthetic_value]').slice(0,1200))}:{}),
      ...(response.status>=400&&/^[a-f0-9]{64}$/.test(response.response_sha256||'')?{response_sha256:response.response_sha256}:{})});
    await save();
    return response;
  }
  async function ok(method,path,body,kind,cleanup=false) {
    const r=await call(method,path,body,kind,cleanup);
    check([200,201].includes(r.status)&&r.body?.success===true,'cloudflare_api_rejected');return r.body.result;
  }
  async function list(type) {
    const prefix=type==='kv'?`${base}/storage/kv/namespaces`:`${base}/d1/database`;
    const result=[];
    for(let page=1;page<=10;page++) {
      const r=await call('GET',`${prefix}?page=${page}&per_page=100`);
      check(r.status===200&&r.body?.success===true&&Array.isArray(r.body.result),'resource_list_rejected');
      result.push(...r.body.result);
      const info=r.body.result_info;
      if(info?.total_pages!==undefined?info.total_pages<=page:r.body.result.length<100)return result;
    }
    throw new ProbeError('inventory_page_limit');
  }
  function remember(type,item) {
    const id=type==='kv'?item?.id:item?.uuid;
    check(type==='kv'?/^[a-f0-9]{32}$/.test(id||''):/^[a-f0-9-]{36}$/.test(id||''),'invalid_resource_id');
    ids[type]=id;state[`${type}_id`]=id;
  }
  async function recoverId(type) {
    if(ids[type])return;
    const found=(await list(type)).filter(r=>(type==='kv'?r.title:r.name)===spec[type]);
    check(found.length<=1,'ambiguous_created_resource');if(found.length)remember(type,found[0]);
  }
  const workerPath=`${base}/workers/scripts/${spec.worker}`;
  async function cleanup() {
    let detached=!workerAttempt;
    if(workerAttempt) {
      try {
        const settings=await call('GET',`${workerPath}/settings`);
        if(settings.status===404){detached=true;state.worker_created=false;state.worker_retained=false;}
        else {
          check(settings.status===200&&settings.body?.success===true,'worker_cleanup_read_rejected');
          state.worker_created=true;state.worker_retained=true;
          const bindings=settings.body.result?.bindings;
          check(Array.isArray(bindings)&&bindings.every(b=>['PROBE_KV','PROBE_DB','PROBE_KEY'].includes(b.name)),'worker_bindings_changed');
          await ok('POST',`${workerPath}/subdomain`,{enabled:false,previews_enabled:false},undefined,true);
          await ok('PUT',workerPath,{source:CLOSED_SOURCE,bindings:[]},'module',true);
          const secrets=await ok('GET',`${workerPath}/secrets`);
          check(Array.isArray(secrets),'secret_list_invalid');
          if(secrets.some(s=>s.name==='PROBE_KEY'))await ok('DELETE',`${workerPath}/secrets/PROBE_KEY`,undefined,undefined,true);
          const final=await ok('GET',`${workerPath}/settings`);
          check(Array.isArray(final?.bindings)&&final.bindings.length===0,'worker_bindings_not_cleared');
          const route=await ok('GET',`${workerPath}/subdomain`);
          check(route?.enabled===false&&route?.previews_enabled===false,'worker_entry_not_closed');
          detached=true;state.worker_retained=true;state.worker_closed_and_unbound=true;
        }
      } catch {state.cleanup_pending.push('worker_shutdown_or_detach');}
    }
    for(const [type,attempted] of [['d1',dbAttempt],['kv',kvAttempt]]) {
      if(!attempted)continue;
      if(!detached){state.cleanup_pending.push(type);continue;}
      try {
        await recoverId(type);
        if(ids[type]) {
          await ok('DELETE',type==='kv'?`${base}/storage/kv/namespaces/${ids.kv}`:`${base}/d1/database/${ids.d1}`,undefined,undefined,true);
          check(!(await list(type)).some(r=>(type==='kv'?r.id:r.uuid)===ids[type]),'resource_delete_not_confirmed');
        }
        state[`${type}_removed`]=true;
      } catch {state.cleanup_pending.push(type);}
    }
    state.cleanup_verified=state.cleanup_pending.length===0;
  }
  try {
    await save();
    const profile=await call('GET','/user');state.initial_profile_http_status=profile.status;
    const user=profile.body?.result;check(profile.status===200&&profile.body?.success===true&&typeof user?.id==='string'&&user.id.length>0,'invalid_identity');
    const memberships=await ok('GET','/memberships');
    check(Array.isArray(memberships)&&memberships.some(m=>m.account?.id===ACCOUNT&&m.status==='accepted'),'expected_account_not_discovered');
    state.account_discovery_verified=true;
    const subdomain=await ok('GET',`${base}/workers/subdomain`);
    check(subdomain?.subdomain==='2994508531','unexpected_workers_subdomain');
    const url=`https://${spec.worker}.${subdomain.subdomain}.workers.dev`;
    check((await call('GET',workerPath)).status===404,'worker_name_exists');
    for(const type of ['kv','d1'])check(!(await list(type)).some(r=>(type==='kv'?r.title:r.name)===spec[type]),'resource_name_exists');
    state.preflight_passed=true;await save();
    // Validate the module before allocating either storage resource.
    workerAttempt=true;await save('worker_compile_attempt');
    await ok('PUT',workerPath,{source,bindings:[]},'module');
    state.worker_created=true;state.worker_retained=true;state.worker_compile_verified=true;
    kvAttempt=true;await save('kv_create_attempt');remember('kv',await ok('POST',`${base}/storage/kv/namespaces`,{title:spec.kv}));
    dbAttempt=true;await save('d1_create_attempt');remember('d1',await ok('POST',`${base}/d1/database`,{name:spec.d1}));
    await ok('PUT',`${base}/storage/kv/namespaces/${ids.kv}/values/${spec.nonce}`,value,'text');
    const kvDeadline=now()+90000;
    while(now()<kvDeadline) {
      const kvRead=await call('GET',`${base}/storage/kv/namespaces/${ids.kv}/values/${spec.nonce}`,undefined,'text');
      if(kvRead.status===200&&kvRead.text===value){state.kv_api_roundtrip=true;break;}
      check(kvRead.status===404,'kv_readback_failed');await sleep(5000);
    }
    check(state.kv_api_roundtrip,'kv_readback_deadline');
    for(const query of [{sql:'CREATE TABLE s0_probe (id TEXT PRIMARY KEY, value TEXT NOT NULL)',params:[]},{sql:'INSERT INTO s0_probe (id, value) VALUES (?, ?)',params:[spec.nonce,value]}])await ok('POST',`${base}/d1/database/${ids.d1}/query`,query);
    const rows=await ok('POST',`${base}/d1/database/${ids.d1}/query`,{sql:'SELECT value FROM s0_probe WHERE id = ?',params:[spec.nonce]});
    check(Array.isArray(rows)&&rows[0]?.success===true&&rows[0]?.results?.[0]?.value===value,'d1_readback_failed');state.d1_api_roundtrip=true;
    workerAttempt=true;await save('worker_create_attempt');
    await ok('PUT',workerPath,{source,bindings:[{name:'PROBE_KV',type:'kv_namespace',namespace_id:ids.kv},{name:'PROBE_DB',type:'d1',database_id:ids.d1}]},'module');
    state.worker_created=true;state.worker_retained=true;
    await ok('PUT',`${workerPath}/secrets`,{name:'PROBE_KEY',text:gate,type:'secret_text'});
    await ok('POST',`${workerPath}/subdomain`,{enabled:true,previews_enabled:false});
    state.worker_url=url;state.worker_deployment_verified=true;
    const deadline=now()+90000;
    while(now()<deadline) {
      try {
        const r=await workerRequest(url+'/probe',{method:'POST',headers:{Authorization:'Bearer '+gate,'Content-Type':'application/json'},body:JSON.stringify({nonce:spec.nonce,expected_sha256:hash(value)})});
        if(r.status===200&&r.body?.build===BUILD&&r.body?.nonce===spec.nonce&&r.body.kv_matches===true&&r.body.d1_matches===true){state.worker_binding_reads_verified=true;break;}
      } catch {state.worker_readback_transport_error=true;}
      await save('waiting_for_worker_readback');await sleep(5000);
    }
    check(state.worker_binding_reads_verified,'worker_readback_deadline');state.functional_result='passed';
  } catch(error) {state.functional_result='not_passed';state.error_code=error instanceof ProbeError?error.message:'transport_or_parse_error';}
  finally {gate=undefined;value=undefined;await cleanup();await save('finished');}
  return structuredClone(state);
}
