// Standalone stage-0 probe. Do not replace the production scheduler with this file.
const BUILD = 'rain-s0-worker-github-20261027-v3';
const CLIENT = 'Iv23li2VecQYTHgNvvHE';
const APP_ID = 5489930;
const OWNER = 'frewily';
const TARGET = 'frewily/rain-client-s0-target-20261027';
const WORKFLOW = 's0-probe.yml';
const RAW_FIXTURE = `https://raw.githubusercontent.com/${TARGET}/main/.github/workflows/${WORKFLOW}`;
const FIXTURE_HASH = 'd7349007d247f4f2e698f55e02755407eb15016f42381967776c8257ac566abe';
const headers = {'Content-Type':'application/json', 'Cache-Control':'no-store, private', 'X-Content-Type-Options':'nosniff'};
const reply = (body, status=200) => new Response(JSON.stringify(body), {status, headers});
const fail = code => {throw new Error(code);};
const errors = new Set(['bad_fixture','bad_identity','bad_installation','bad_permissions','bad_repository_scope','refresh_rejected','refreshed_identity_rejected','old_token_still_accepted','dispatch_rejected','bad_dispatch_response','request_deadline','unexpected_redirect']);

async function readLimitedBody(request) {
  const reader=request.body?.getReader();
  if(!reader)throw new Error('bad_body');
  const chunks=[];let size=0;
  while(true){const {done,value}=await reader.read();if(done)break;size+=value.length;if(size>16384){await reader.cancel();throw new Error('bad_body');}chunks.push(value);}
  const bytes=new Uint8Array(size);let offset=0;for(const b of chunks){bytes.set(b,offset);offset+=b.length;}
  return JSON.parse(new TextDecoder().decode(bytes));
}

async function keyMatches(received,expected) {
  if(typeof expected!=='string'||expected.length<40||expected.length>160||received.length>200)return false;
  const digest=async s=>new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(s)));
  const [a,b]=await Promise.all([digest(received),digest('Bearer '+expected)]);let d=0;for(let i=0;i<a.length;i++)d|=a[i]^b[i];return d===0;
}

export function makeHandler(fetcher=globalThis.fetch) {
  return async function handle(request,env) {
    const url=new URL(request.url);
    if(request.method==='GET'&&url.pathname==='/health')return reply({build:BUILD,target:TARGET,key_configured:typeof env.PROBE_KEY==='string'&&env.PROBE_KEY.length>=40});
    if(request.method==='GET'&&url.pathname==='/ready')return await keyMatches(request.headers.get('Authorization')||'',env.PROBE_KEY)?reply({build:BUILD,target:TARGET,ready:true}):reply({error:'unauthorized'},401);
    if(request.method==='GET'&&url.pathname==='/source-diagnostic'){
      if(!await keyMatches(request.headers.get('Authorization')||'',env.PROBE_KEY))return reply({error:'unauthorized'},401);
      const result={build:BUILD,github_credentials_used:false,dispatch_attempted:false};
      const options={headers:{'User-Agent':BUILD},redirect:'manual',signal:AbortSignal.timeout(10000)};
      try{const r=await fetcher(RAW_FIXTURE,options);result.raw_http_status=r.status;const text=await r.text();const hash=[...new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(text)))].map(x=>x.toString(16).padStart(2,'0')).join('');result.raw_fixture_hash_matches=hash===FIXTURE_HASH;}catch(e){result.raw_error_name=e.name;}
      try{const r=await fetcher(`https://api.github.com/repos/${TARGET}/contents/.github/workflows/${WORKFLOW}?ref=main`,{...options,signal:AbortSignal.timeout(10000),headers:{Accept:'application/vnd.github+json','User-Agent':BUILD,'X-GitHub-Api-Version':'2026-03-10'}});result.public_api_http_status=r.status;let b=null;try{b=await r.json();}catch{}result.public_api_rate_limited=/rate limit/i.test(String(b?.message));}catch(e){result.public_api_error_name=e.name;}
      return reply(result);
    }
    if(request.method==='GET'&&url.pathname==='/transport-diagnostic'){
      if(!await keyMatches(request.headers.get('Authorization')||'',env.PROBE_KEY))return reply({error:'unauthorized'},401);
      const cases=[];
      const modes=['original_unbound','global_receiver','native_defaults_unbound','native_defaults_bound','manual_redirect','manual_abort_controller'];
      for(const mode of modes){
        const row={mode,phase:'construct_options'};let timer;
        try{
          const target=`https://api.github.com/repos/${TARGET}/contents/.github/workflows/${WORKFLOW}?ref=main`;
          const options={headers:{Accept:'application/vnd.github+json','User-Agent':BUILD,'X-GitHub-Api-Version':'2026-03-10'}};
          if(['original_unbound','global_receiver'].includes(mode)){options.redirect='error';options.signal=AbortSignal.timeout(10000);}
          if(['manual_redirect','manual_abort_controller'].includes(mode))options.redirect='manual';
          if(mode==='manual_abort_controller'){const controller=new AbortController();options.signal=controller.signal;timer=setTimeout(()=>controller.abort(),10000);}
          row.phase='fetch';
          const r=['original_unbound','native_defaults_unbound'].includes(mode)?await fetcher(target,options):await fetcher.call(globalThis,target,options);
          row.phase='read_response';
          row.http_status=r.status;let b=null;try{b=await r.json();}catch{}
          row.fixture_content_present=b?.encoding==='base64'&&typeof b?.content==='string';
          if(row.fixture_content_present){const bytes=Uint8Array.from(atob(b.content.replace(/\s/g,'')),c=>c.charCodeAt(0));const hash=[...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(x=>x.toString(16).padStart(2,'0')).join('');row.fixture_hash_matches=hash===FIXTURE_HASH;}
        }catch(e){row.error_name=['TypeError','Error','TimeoutError','AbortError'].includes(e.name)?e.name:'other';row.receiver_error=/Illegal invocation|incompatible.*receiver/i.test(String(e.message));row.error_message=String(e.message).replaceAll(env.PROBE_KEY,'[redacted]').slice(0,240);}
        finally{if(timer)clearTimeout(timer);}
        cases.push(row);
      }
      return reply({build:BUILD,github_credentials_used:false,dispatch_attempted:false,capabilities:{fetch_type:typeof fetcher,abort_signal_timeout_type:typeof AbortSignal.timeout,abort_controller_type:typeof AbortController},cases});
    }
    if(url.pathname!=='/probe')return reply({error:'not_found'},404);
    if(request.method!=='POST')return reply({error:'method_not_allowed'},405);
    if(!await keyMatches(request.headers.get('Authorization')||'',env.PROBE_KEY))return reply({error:'unauthorized'},401);
    if(!request.headers.get('Content-Type')?.startsWith('application/json'))return reply({error:'bad_content_type'},400);
    let input;
    try{
      input=await readLimitedBody(request);
      if(!input||Object.keys(input).sort().join(',')!=='initial_access_token,nonce,refresh_token'||!/^[a-f0-9]{24}$/.test(input.nonce)||!['initial_access_token','refresh_token'].every(k=>typeof input[k]==='string'&&input[k].length>=8&&input[k].length<=7000))throw new Error('bad_body');
    }catch{return reply({error:'bad_body'},400);}
    const summary={build:BUILD,nonce:input.nonce,api_version:'2026-03-10',client_secret_sent:false,dispatch_attempted:false};
    let refreshed=null;
    const deadline=Date.now()+50000;
    async function call(url,options={},asText=false){
      const remaining=deadline-Date.now();if(remaining<=0)fail('request_deadline');
      const r=await fetcher(url,{...options,redirect:'manual',signal:AbortSignal.timeout(Math.min(10000,remaining))});
      if(r.status>=300&&r.status<400)fail('unexpected_redirect');
      const raw=await r.text();if(asText)return {status:r.status,text:raw};let body=null;try{body=raw?JSON.parse(raw):null;}catch{}
      return {status:r.status,body};
    }
    function api(path,token,method='GET',body){return call('https://api.github.com'+path,{method,headers:{Accept:'application/vnd.github+json','User-Agent':BUILD,'X-GitHub-Api-Version':'2026-03-10',...(token?{Authorization:'Bearer '+token}:{}),...(body?{'Content-Type':'application/json'}:{})},...(body?{body:JSON.stringify(body)}:{})});}
    async function installation(token){
      const r=await api('/user/installations?per_page=100',token);
      const matches=r.body?.installations?.filter(x=>x.app_id===APP_ID&&x.account?.login===OWNER);
      if(r.status!==200||matches?.length!==1)fail('bad_installation');
      const i=matches[0];
      if(i.permissions?.actions!=='write'||i.permissions?.metadata!=='read'||Object.entries(i.permissions||{}).some(([k,v])=>v!=='none'&&!((k==='actions'&&v==='write')||(k==='metadata'&&v==='read'))))fail('bad_permissions');
      if(i.repository_selection!=='selected')fail('bad_repository_scope');
      const rr=await api(`/user/installations/${i.id}/repositories?per_page=100`,token);
      if(rr.status!==200||rr.body?.total_count!==1||rr.body.repositories?.length!==1||rr.body.repositories[0].full_name!==TARGET)fail('bad_repository_scope');
      summary.selected_repository_verified=true;
    }
    try{
      const fixture=await call(RAW_FIXTURE,{headers:{'User-Agent':BUILD}},true);
      if(fixture.status!==200)fail('bad_fixture');
      const bytes=new TextEncoder().encode(fixture.text);
      const digest=[...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(x=>x.toString(16).padStart(2,'0')).join('');
      if(digest!==FIXTURE_HASH)fail('bad_fixture');
      summary.fixture_verified=true;
      const before=await api('/user',input.initial_access_token);
      summary.initial_profile_http_status=before.status;
      if(before.status!==200||before.body?.login!==OWNER)fail('bad_identity');
      await installation(input.initial_access_token);
      const r=await call('https://github.com/login/oauth/access_token',{method:'POST',headers:{Accept:'application/json','Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({client_id:CLIENT,grant_type:'refresh_token',refresh_token:input.refresh_token})});
      summary.refresh_http_status=r.status;
      if(r.status!==200||!r.body?.access_token||!r.body?.refresh_token)fail('refresh_rejected');
      refreshed=r.body;
      summary.access_token_rotated=refreshed.access_token!==input.initial_access_token;summary.refresh_token_rotated=refreshed.refresh_token!==input.refresh_token;
      const after=await api('/user',refreshed.access_token);
      summary.refreshed_profile_http_status=after.status;summary.same_identity=after.body?.id===before.body.id&&after.body?.login===OWNER;
      if(after.status!==200||!summary.same_identity)fail('refreshed_identity_rejected');
      const old=await api('/user',input.initial_access_token);summary.old_access_http_status=old.status;
      if(old.status!==401)fail('old_token_still_accepted');
      await installation(refreshed.access_token);
      summary.dispatch_attempted=true;
      const dispatched=await api(`/repos/${TARGET}/actions/workflows/${WORKFLOW}/dispatches`,refreshed.access_token,'POST',{ref:'main',inputs:{probe_nonce:input.nonce}});
      summary.dispatch_http_status=dispatched.status;
      if(dispatched.status!==200)fail('dispatch_rejected');
      const runId=dispatched.body?.workflow_run_id;
      if(!Number.isSafeInteger(runId)||runId<=0)fail('bad_dispatch_response');
      summary.workflow_run_id=runId;summary.workflow_run_url=`https://github.com/${TARGET}/actions/runs/${runId}`;
      return reply({ok:true,summary,credentials:{access_token:refreshed.access_token,refresh_token:refreshed.refresh_token}});
    }catch(error){
      summary.error_code=errors.has(error.message)?error.message:'transport_or_parse_error';
      if(summary.dispatch_attempted&&!summary.dispatch_http_status)summary.dispatch_acceptance_unknown=true;
      // Only the authenticated caller receives the rotated pair, for local cleanup checks.
      return reply({ok:false,summary,...(refreshed?{credentials:{access_token:refreshed.access_token,refresh_token:refreshed.refresh_token}}:{})},502);
    }finally{
      input.initial_access_token='';input.refresh_token='';
      if(refreshed){refreshed.access_token='';refreshed.refresh_token='';}
    }
  };
}

export default {fetch:makeHandler()};
