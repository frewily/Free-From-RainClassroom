import http from 'node:http';
import {spawn} from 'node:child_process';
import {randomBytes,createHash} from 'node:crypto';
import {mkdir,readFile,writeFile,rename} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
import {makeSpec,runProbe,validateConfig,ACCOUNT} from './probe.mjs';

const DIR='/private/tmp/rain-client-s0/cloudflare-manager';
const ROOT='http://127.0.0.1:8765';
const ISSUER='https://dash.cloudflare.com';
const API='https://api.cloudflare.com/client/v4';
const BUILD='rain-s0-cf-deploy-20261028-v1';

export function curlSpec(url,{method='GET',headers={},body}={},workerHost) {
  const u=new URL(url);
  if(u.protocol!=='https:'||u.username||u.password||u.hash||u.port)throw Error('unexpected_url');
  const allowed=u.origin==='https://api.cloudflare.com'&&u.pathname.startsWith('/client/v4/')||
    u.origin===ISSUER&&['/oauth2/token','/oauth2/revoke'].includes(u.pathname)||
    workerHost&&u.hostname===workerHost&&/^(\/health|\/probe)$/.test(u.pathname);
  if(!allowed)throw Error('unexpected_origin');
  const quote=text=>'"'+String(text).replace(/\\/g,'\\\\').replace(/"/g,'\\"').replace(/\r/g,'\\r').replace(/\n/g,'\\n')+'"';
  const config=['url = '+quote(url),'proxy = "http://127.0.0.1:7897"','request = '+quote(method)];
  for(const [name,value] of Object.entries(headers))config.push('header = '+quote(name+': '+value));
  if(body!==undefined)config.push('data-binary = '+quote(body));
  return {args:['--disable','--config','-','--silent','--show-error','--max-time','20','--proto','=https','--noproxy','','--globoff','--write-out','\n%{http_code}'],input:config.join('\n')+'\n'};
}

export function moduleBody(source,bindings) {
  const boundary='rain-s0-'+randomBytes(12).toString('hex');
  const metadata=JSON.stringify({main_module:'probe.mjs',compatibility_date:'2026-10-01',bindings});
  return {contentType:'multipart/form-data; boundary='+boundary,body:[
    '--'+boundary,'Content-Disposition: form-data; name="metadata"','Content-Type: application/json','',metadata,
    '--'+boundary,'Content-Disposition: form-data; name="probe.mjs"; filename="probe.mjs"','Content-Type: application/javascript+module','',source,'--'+boundary+'--',''
  ].join('\r\n')};
}

async function send(url,options={},workerHost) {
  const spec=curlSpec(url,options,workerHost);
  let output=await new Promise((resolve,reject)=>{
    const child=spawn('/usr/bin/curl',spec.args,{stdio:['pipe','pipe','pipe']});let text='',tooLarge=false;
    const timer=setTimeout(()=>child.kill('SIGKILL'),25000);
    child.stdin.on('error',()=>{});child.stderr.on('data',()=>{});
    child.stdout.on('data',part=>{text+=part;if(Buffer.byteLength(text)>1048576){tooLarge=true;text='';child.kill('SIGKILL');}});
    child.on('error',()=>{clearTimeout(timer);reject(Error('transport_failed'));});
    child.on('close',code=>{clearTimeout(timer);if(code!==0||tooLarge)reject(Error('transport_failed'));else resolve(text);});
    child.stdin.end(spec.input);
  });
  spec.input='';const split=output.lastIndexOf('\n'),status=Number(output.slice(split+1));
  if(!Number.isInteger(status)||status<200||status>599||status>=300&&status<400)throw Error('transport_or_redirect_rejected');
  const text=output.slice(0,split);output='';let body=null;try{body=JSON.parse(text);}catch{}
  return {status,body,text,response_kind:body!==null?'json':/^\s*(?:<!doctype html|<html)/i.test(text)?'html':'text',response_sha256:createHash('sha256').update(text).digest('hex')};
}

export function checkWorkersAdminContinuation(previous,clientId) {
  const failed=previous?.writes?.filter(item=>item.method==='PUT'&&item.path?.includes('/workers/scripts/')&&item.http_status===403);
  if(previous?.probe!==BUILD||previous.client_id!==clientId||previous.account_id!==ACCOUNT||previous.stage!=='finished'||
    previous.functional_result!=='not_passed'||previous.worker_created!==false||previous.cleanup_verified!==true||
    previous.kv_api_roundtrip!==true||previous.d1_api_roundtrip!==true||previous.kv_removed!==true||previous.d1_removed!==true||
    previous.revocation_independently_verified!==true||previous.temporary_token_references_discarded!==true||failed?.length!==1||
    JSON.stringify([...(previous.granted_scope_ids||[])].sort())!==JSON.stringify(['d1.write','workers-scripts.edit','workers-kv-storage.write','memberships.read','user-details.read'].sort()))throw Error('workers_admin_continuation_not_ready');
}

export function compilerDetails(response,credential) {
  if(response.status!==400||!Array.isArray(response.body?.errors))return [];
  return response.body.errors.filter(error=>Number(error.code)===10021&&typeof error.message==='string').slice(0,3).map(error=>error.message
    .replaceAll(credential||'\u0000','[credential]')
    .replace(/Bearer\s+[^\s<>"']+/gi,'Bearer [credential]')
    .replace(/[A-Za-z0-9_.+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g,'[email]').slice(0,1200));
}

export function checkModuleFormatContinuation(previous,clientId) {
  const failure=previous?.writes?.filter(item=>item.method==='PUT'&&item.path?.includes('/workers/scripts/')&&item.http_status===400&&item.error_codes?.includes(10021));
  if(previous?.probe!==BUILD||previous.client_id!==clientId||previous.account_id!==ACCOUNT||previous.stage!=='finished'||
    previous.workers_admin_continuation!==true||previous.functional_result!=='not_passed'||previous.worker_created!==false||
    previous.cleanup_verified!==true||previous.kv_removed!==true||previous.d1_removed!==true||
    previous.revocation_independently_verified!==true||previous.temporary_token_references_discarded!==true||failure?.length!==1||
    JSON.stringify([...(previous.granted_scope_ids||[])].sort())!==JSON.stringify(['d1.write','workers-scripts.admin','workers-kv-storage.write','memberships.read','user-details.read'].sort()))throw Error('module_format_continuation_not_ready');
}

export function checkAwaitingModuleResume(previous,guard,clientId,scopes,sourceHash) {
  const sameScopes=value=>Array.isArray(value)&&JSON.stringify([...value].sort())===JSON.stringify([...scopes].sort());
  if(previous?.stage!=='awaiting_authorization'||previous.client_id!==clientId||previous.account_id!==ACCOUNT||
    previous.workers_admin_continuation!==true||previous.module_format_continuation!==true||
    previous.worker_source_sha256!==sourceHash||!sameScopes(previous.requested_scope_ids)||
    ['callback_state_verified','token_exchange_http_status','writes'].some(key=>Object.hasOwn(previous,key))||
    guard?.client_id!==clientId||guard.workers_admin_continuation!==true||guard.module_format_continuation!==true||!sameScopes(guard.scopes)||
    JSON.stringify(guard.spec)!==JSON.stringify(makeSpec(guard.spec?.nonce)))throw Error('authorization_wait_resume_not_ready');
  return guard.spec;
}

export async function main(args) {
  const resume=args.length===4&&args[2]==='--module-format-continuation'&&args[3]==='--resume-awaiting-authorization';
  const workersAdmin=args.length===3&&args[2]==='--workers-admin-continuation';
  const moduleFormat=resume||args.length===3&&args[2]==='--module-format-continuation';
  const adminProfile=workersAdmin||moduleFormat;
  if((!adminProfile&&args.length!==2)||args[0]!=='--approved-live')throw Error('explicit_approval_and_scope_config_required');
  const config=JSON.parse(await readFile(args[1],'utf8')),scopes=validateConfig(config,{workersAdminApproved:adminProfile});
  let spec=makeSpec();
  const source=await readFile(new URL('./worker.mjs',import.meta.url),'utf8');
  await mkdir(DIR,{recursive:true,mode:0o700});
  if(workersAdmin) {
    const previous=JSON.parse(await readFile(DIR+'/result.json','utf8'));
    checkWorkersAdminContinuation(previous,config.client_id);
    await writeFile(DIR+'/previous-editor-attempt-20261028.json',JSON.stringify(previous,null,2)+'\n',{flag:'wx',mode:0o600});
  }
  if(moduleFormat) {
    const previous=JSON.parse(await readFile(DIR+(resume?'/previous-module-error-attempt-20261028.json':'/result.json'),'utf8'));
    checkModuleFormatContinuation(previous,config.client_id);
    if(!resume)await writeFile(DIR+'/previous-module-error-attempt-20261028.json',JSON.stringify(previous,null,2)+'\n',{flag:'wx',mode:0o600});
  }
  let resumeSnapshot;
  if(resume) {
    const previous=JSON.parse(await readFile(DIR+'/result.json','utf8'));
    const originalGuard=JSON.parse(await readFile(DIR+'/attempt-20261028-module-format.json','utf8'));
    spec=checkAwaitingModuleResume(previous,originalGuard,config.client_id,scopes,createHash('sha256').update(source).digest('hex'));
    resumeSnapshot=previous;
  }
  const guard=resume?'/attempt-20261028-module-format-resume1.json':moduleFormat?'/attempt-20261028-module-format.json':workersAdmin?'/attempt-20261028-workers-admin.json':'/attempt-20261028.json';
  await writeFile(DIR+guard,JSON.stringify({spec,client_id:config.client_id,scopes,workers_admin_continuation:adminProfile,module_format_continuation:moduleFormat,resumed_wait_snapshot:resumeSnapshot,started_at:new Date().toISOString()})+'\n',{flag:'wx',mode:0o600});
  const verifier=randomBytes(32).toString('base64url'),csrf=randomBytes(32).toString('base64url');
  const auth=new URL(ISSUER+'/oauth2/auth');
  for(const [key,value] of Object.entries({client_id:config.client_id,response_type:'code',redirect_uri:ROOT+'/cloudflare/callback',scope:scopes.join(' '),code_challenge:createHash('sha256').update(verifier).digest('base64url'),code_challenge_method:'S256',state:csrf}))auth.searchParams.set(key,value);
  let held=null,callbackUsed=false,finished=false,writes=Promise.resolve();
  let state={stage:'awaiting_authorization',client_id:config.client_id,requested_scope_names:config.scopes.map(s=>s.name),requested_scope_ids:scopes,account_id:ACCOUNT,workers_admin_continuation:adminProfile,module_format_continuation:moduleFormat,credentials_saved_to_file:false,worker_source_sha256:createHash('sha256').update(source).digest('hex')};
  async function save(next=state) {
    state={...next,observed_at:new Date().toISOString()};const serialized=JSON.stringify(state,null,2)+'\n';
    writes=writes.then(async()=>{await writeFile(DIR+'/result.json.tmp',serialized,{mode:0o600});await rename(DIR+'/result.json.tmp',DIR+'/result.json');});return writes;
  }
  const form=(path,body)=>send(ISSUER+path,{method:'POST',headers:{Accept:'application/json','Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams(body).toString()});
  const api=async(method,path,body,kind)=>{
    const headers={Accept:'application/json',Authorization:'Bearer '+held,'User-Agent':BUILD};let payload;
    if(kind==='module'){const m=moduleBody(body.source,body.bindings);headers['Content-Type']=m.contentType;payload=m.body;}
    else if(body!==undefined){headers['Content-Type']=kind==='text'?'text/plain; charset=utf-8':'application/json';payload=kind==='text'?body:JSON.stringify(body);}
    const response=await send(API+path,{method,headers,body:payload});
    if(kind==='module'&&body.source===source)response.compiler_details=compilerDetails(response,held);
    return response;
  };
  async function execute(code) {
    let issued;
    try {
      await save({...state,stage:'exchanging_code',callback_state_verified:true});
      issued=await form('/oauth2/token',{client_id:config.client_id,code,grant_type:'authorization_code',redirect_uri:ROOT+'/cloudflare/callback',code_verifier:verifier});
      if(issued.status!==200||typeof issued.body?.access_token!=='string')throw Error('token_exchange_failed');
      held=issued.body.access_token;issued.body.access_token='';
      if(issued.body.refresh_token){await form('/oauth2/revoke',{client_id:config.client_id,token:issued.body.refresh_token,token_type_hint:'refresh_token'});issued.body.refresh_token='';throw Error('unexpected_refresh_token');}
      const granted=typeof issued.body.scope==='string'?issued.body.scope.split(/\s+/).filter(Boolean):[];
      await save({...state,token_exchange_http_status:issued.status,granted_scope_ids:granted.filter(scope=>/^[a-z0-9_.:-]{1,120}$/.test(scope)).slice(0,20)});
      if(JSON.stringify([...granted].sort())!==JSON.stringify([...scopes].sort()))throw Error('granted_scope_mismatch');
      const authResult={client_id:config.client_id,requested_scope_names:config.scopes.map(s=>s.name),requested_scope_ids:scopes,granted_scope_ids:granted,workers_admin_continuation:adminProfile,module_format_continuation:moduleFormat,client_secret_sent:false,callback_state_verified:true,worker_source_sha256:state.worker_source_sha256};
      const result=await runProbe({request:api,source,spec,checkpoint:r=>save({...authResult,...r}),workerRequest:(url,options)=>send(url,options,`${spec.worker}.2994508531.workers.dev`)});
      await save({...authResult,...result});
    } catch {await save({...state,local_error:'authorization_or_transport_failed'});}
    finally {
      code='';if(issued?.body){issued.body.access_token='';issued.body.refresh_token='';}
      if(held) {
        try {
          const revoked=await form('/oauth2/revoke',{client_id:config.client_id,token:held,token_type_hint:'access_token'});
          const checked=await api('GET','/user');
          const verified=state.initial_profile_http_status===200&&revoked.status===200&&[401,403].includes(checked.status);
          await save({...state,access_revoke_http_status:revoked.status,post_revoke_profile_http_status:checked.status,revocation_independently_verified:verified,revocation_cleanup_pending:!verified});
        } catch {await save({...state,revocation_cleanup_pending:true});}
      }
      held=null;finished=true;await save({...state,stage:'finished',temporary_token_references_discarded:true});
      process.stdout.write('Cloudflare probe finished; inspect the sanitized result.json.\n');
      setTimeout(()=>{server.close();},45000).unref();
    }
  }
  const page='<!doctype html><meta charset="utf-8"><meta name="referrer" content="same-origin"><title>Cloudflare 管理验证</title><style>body{font:17px system-ui;max-width:800px;margin:40px auto;padding:20px}pre{white-space:pre-wrap}</style><h1>Cloudflare 管理验证</h1><p>仅在批准的私有测试客户端中核对五项权限后授权。</p><p><a id="auth" href="'+auth.href.replace(/&/g,'&amp;')+'">打开 Cloudflare 官方授权页</a></p><p>回调收到后只处理一次；重复打开回调不会重复创建资源。页面结果不包含凭据。</p><pre id="status"></pre><script>async function poll(){try{const s=await(await fetch("/status")).json();document.getElementById("status").textContent=JSON.stringify(s,null,2);if(s.stage!=="awaiting_authorization")document.getElementById("auth").hidden=true}catch{}}poll();setInterval(poll,2000)</script>';
  const server=http.createServer(async(req,res)=>{
    if(req.headers.host!=='127.0.0.1:8765'){res.writeHead(403).end();return;}
    res.setHeader('Cache-Control','no-store');const url=new URL(req.url,ROOT);
    if(req.method==='GET'&&url.pathname==='/status'){res.setHeader('Content-Type','application/json');res.end(JSON.stringify(state));return;}
    if(req.method==='GET'&&url.pathname==='/cloudflare/callback') {
      if(url.searchParams.get('state')!==csrf){res.writeHead(403).end('Callback state mismatch');return;}
      if(!callbackUsed){callbackUsed=true;const code=url.searchParams.get('code');if(code)execute(code);else{finished=true;save({...state,stage:'authorization_not_completed'});}}
      res.writeHead(303,{Location:'/'}).end();return;
    }
    if(req.method==='GET'&&url.pathname==='/'){res.setHeader('Content-Type','text/html; charset=utf-8');res.end(page);return;}
    res.writeHead(404).end();
  });
  await save();await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(8765,'127.0.0.1',resolve);});
  const expiry=setTimeout(()=>{if(!callbackUsed||finished)server.close();},20*60*1000);expiry.unref();
  server.on('close',()=>{held=null;});
  process.stdout.write('Cloudflare manager preparation: '+ROOT+'/\n');
}

if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href)main(process.argv.slice(2)).catch(()=>{process.stderr.write('cloudflare_manager_not_started\n');process.exitCode=1;});
