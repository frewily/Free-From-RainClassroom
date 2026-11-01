import http from 'node:http';
import {randomBytes,createHash} from 'node:crypto';
import {readFile,writeFile,rename,mkdir} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
import {spawn} from 'node:child_process';

const ROOT='http://127.0.0.1:8765';
const DIR='/private/tmp/rain-client-s0';
const RESULT=DIR+'/worker-live-result.json';
const GUARD=DIR+'/cloud-worker-request-attempt.json';
const BUILD='rain-s0-worker-github-20261027-v3';
const CLIENT='Iv23li2VecQYTHgNvvHE';
const TARGET='frewily/rain-client-s0-target-20261027';
const HEAD='643a01c40f6ceb4b953036dfc5dcc1f8541193ac';
const SUMMARY_KEYS=['build','nonce','api_version','client_secret_sent','dispatch_attempted','selected_repository_verified','fixture_verified','initial_profile_http_status','refresh_http_status','access_token_rotated','refresh_token_rotated','refreshed_profile_http_status','same_identity','old_access_http_status','dispatch_http_status','workflow_run_id','workflow_run_url','dispatch_acceptance_unknown','error_code'];
const ERROR_CODES=new Set(['bad_fixture','bad_identity','bad_installation','bad_permissions','bad_repository_scope','refresh_rejected','refreshed_identity_rejected','old_token_still_accepted','dispatch_rejected','bad_dispatch_response','request_deadline','transport_or_parse_error','unexpected_redirect']);
export function safeSummary(input){
  const out={};
  for(const key of SUMMARY_KEYS){const value=input?.[key];if(['boolean','number'].includes(typeof value))out[key]=value;else if(typeof value==='string'){
    if(key==='error_code')out[key]=ERROR_CODES.has(value)?value:'unrecognized_error';
    if(key==='build'&&value===BUILD)out[key]=value;
    if(key==='nonce'&&/^[a-f0-9]{24}$/.test(value))out[key]=value;
    if(key==='api_version'&&value==='2026-03-10')out[key]=value;
    if(key==='workflow_run_url'&&/^https:\/\/github\.com\/frewily\/rain-client-s0-target-20261027\/actions\/runs\/\d+$/.test(value))out[key]=value;
  }}return out;
}
export function checkedWorkerURL(raw){const u=new URL(raw);if(u.protocol!=='https:'||!/^rain-client-s0-worker-20261027\.[a-z0-9-]+\.workers\.dev$/.test(u.hostname)||u.username||u.password||u.port||u.search||u.hash||u.pathname!=='/')throw Error('unexpected_worker_url');return u.origin;}

export function workerCurlSpec(url,options,proxy){
  const quote=s=>'"'+String(s).replace(/\\/g,'\\\\').replace(/"/g,'\\"').replace(/\r/g,'\\r').replace(/\n/g,'\\n')+'"';
  const lines=['url = '+quote(url),'proxy = '+quote(proxy),'request = '+quote(options.method||'GET')];
  for(const[k,v]of Object.entries(options.headers||{}))lines.push('header = '+quote(k+': '+v));
  if(options.body!==undefined)lines.push('data-binary = '+quote(String(options.body)));
  return {args:['--config','-','--silent','--show-error','--max-time',String(Math.ceil((options.requestTimeout||20000)/1000)),'--proto','=https','--noproxy','','--write-out','\n%{http_code}'],config:lines.join('\n')+'\n'};
}

export async function startController({existingGate,sourceFile,existingWorkerURL}={}){
  await mkdir(DIR,{recursive:true,mode:0o700});
  if(existingGate!==undefined&&(typeof existingGate!=='string'||!/^[a-f0-9]{64}$/.test(existingGate)))throw Error('invalid_existing_gate');
  if(existingWorkerURL)existingWorkerURL=checkedWorkerURL(existingWorkerURL+'/');
  const gate=existingGate??randomBytes(32).toString('hex');let workerURL='',userCode='',held=null,busy=false,monitor=null,cleanupBusy=false,writes=Promise.resolve();
  const state={stage:'awaiting_worker_setup',worker_name:'rain-client-s0-worker-20261027',build:BUILD,github_app_id:5489930,worker_requests_sent:0,github_refresh_executed_locally:false,credentials_saved_to_file:false,authorization_cleanup_pending:true};
  state.gate_reused_in_memory=existingGate!==undefined;
  const source=await readFile(sourceFile||new URL('./worker-runtime.mjs',import.meta.url),'utf8');state.worker_source_sha256=createHash('sha256').update(source).digest('hex');
  const sleep=ms=>new Promise(r=>setTimeout(r,ms));
  function record(){state.observed_at=new Date().toISOString();const snapshot=JSON.stringify(state,null,2)+'\n';writes=writes.then(async()=>{await writeFile(RESULT+'.tmp',snapshot,{mode:0o600});await rename(RESULT+'.tmp',RESULT);});return writes;}
  async function request(url,options={}){
    if(new URL(url).hostname.endsWith('.workers.dev')&&process.env.HTTPS_PROXY){
      const spec=workerCurlSpec(url,options,process.env.HTTPS_PROXY);const p=spawn('/usr/bin/curl',spec.args,{stdio:['pipe','pipe','pipe']});let out='';p.stdout.on('data',x=>out+=x);p.stderr.on('data',()=>{});p.stdin.end(spec.config);spec.config='';
      const code=await new Promise((resolve,reject)=>{p.on('error',reject);p.on('exit',resolve);});if(code!==0)throw Error('worker_transport_failed');
      const split=out.lastIndexOf('\n'),status=Number(out.slice(split+1));let body=null;try{body=JSON.parse(out.slice(0,split));}catch{}out='';return {status,body};
    }
    const r=await fetch(url,{...options,redirect:'error',signal:AbortSignal.timeout(options.requestTimeout||20000)});const raw=await r.text();let body=null;try{body=raw?JSON.parse(raw):null;}catch{}return {status:r.status,body};
  }
  const form=(url,body)=>request(url,{method:'POST',headers:{Accept:'application/json','Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams(body)});
  const api=(path,token)=>request('https://api.github.com'+path,{headers:{Accept:'application/vnd.github+json','User-Agent':BUILD,'X-GitHub-Api-Version':'2026-03-10',...(token?{Authorization:'Bearer '+token}:{})}});
  function discard(){held=null;userCode='';state.temporary_token_references_discarded=true;if(monitor){clearInterval(monitor);monitor=null;}}
  async function cleanupTick(){
    if(!held||!state.refreshed_pair_received||cleanupBusy)return;
    cleanupBusy=true;
    try{const r=await api('/user',held.access);state.cleanup_last_profile_http_status=r.status;if(r.status===401){state.authorization_cleanup_pending=false;state.revocation_independently_verified=true;state.stage=state.functional_result==='passed'?'passed_and_revoked':'finished_and_revoked';discard();}await record();}catch{state.cleanup_monitor_transport_error=true;await record();}finally{cleanupBusy=false;}
  }
  async function observeRun(){
    const deadline=Date.now()+180000;
    while(Date.now()<deadline){const r=await api(`/repos/${TARGET}/actions/runs/${state.worker_summary.workflow_run_id}`,held?.access);const run=r.body;
      if(r.status!==200||run?.head_sha!==HEAD||run?.display_title!==`S0 probe ${state.probe_nonce}`||run?.event!=='workflow_dispatch')throw Error('run_readback_rejected');
      state.run_status=run.status;state.run_conclusion=run.conclusion;await record();
      if(run.status==='completed'){if(run.conclusion!=='success')throw Error('run_failed');return;}await sleep(5000);
    }throw Error('run_wait_timeout');
  }
  async function execute(){
    let device,issued,packet;
    try{
      // A prior attempt is never silently retried, including after a process restart.
      try{await readFile(GUARD);throw Error('worker_already_attempted');}catch(e){if(e.code!=='ENOENT')throw e;}
      device=await form('https://github.com/login/device/code',{client_id:CLIENT,scope:'offline_access'});
      if(device.status!==200||!device.body?.device_code||!device.body.user_code||device.body.verification_uri!=='https://github.com/login/device')throw Error('device_authorization_failed');
      userCode=device.body.user_code;state.stage='awaiting_github_authorization';state.device_code_expires_at=new Date(Date.now()+Number(device.body.expires_in)*1000).toISOString();await record();
      let interval=Math.max(5,Number(device.body.interval)||5);const deadline=Date.now()+Math.min(900,Number(device.body.expires_in)||900)*1000;
      while(Date.now()<deadline){await sleep(interval*1000);const r=await form('https://github.com/login/oauth/access_token',{client_id:CLIENT,device_code:device.body.device_code,grant_type:'urn:ietf:params:oauth:grant-type:device_code'});if(r.body?.error==='authorization_pending')continue;if(r.body?.error==='slow_down'){interval+=5;continue;}if(r.status!==200||r.body?.error)throw Error('device_authorization_failed');issued=r.body;break;}
      userCode='';if(!issued?.access_token||!issued?.refresh_token)throw Error('authorization_incomplete');held={access:issued.access_token,refresh:issued.refresh_token};
      const identity=await api('/user',held.access);if(identity.status!==200||identity.body?.login!=='frewily')throw Error('unexpected_account');
      state.stage='calling_cloud_worker';state.probe_nonce=randomBytes(12).toString('hex');
      await writeFile(GUARD,JSON.stringify({worker_url:workerURL,nonce:state.probe_nonce,attempted_at:new Date().toISOString()})+'\n',{flag:'wx',mode:0o600});
      state.worker_requests_sent=1;await record();
      // GitHub tokens cross HTTPS only after deployment checks and explicit live approval.
      const r=await request(workerURL+'/probe',{method:'POST',headers:{Authorization:'Bearer '+gate,'Content-Type':'application/json'},body:JSON.stringify({nonce:state.probe_nonce,initial_access_token:held.access,refresh_token:held.refresh}),requestTimeout:65000});
      packet=r.body;state.worker_http_status=r.status;state.worker_summary=safeSummary(packet?.summary);
      if(state.worker_summary.build===BUILD&&state.worker_summary.nonce===state.probe_nonce&&packet?.credentials&&typeof packet.credentials.access_token==='string'&&typeof packet.credentials.refresh_token==='string'){
        held={access:packet.credentials.access_token,refresh:packet.credentials.refresh_token};state.refreshed_pair_received=true;packet.credentials.access_token='';packet.credentials.refresh_token='';
        const checked=await api('/user',held.access);state.returned_token_profile_http_status=checked.status;
        if(checked.status!==200||checked.body?.id!==identity.body.id||checked.body?.login!=='frewily')throw Error('returned_token_identity_rejected');
        // Polling runs independently of Codex turns, so a usage-limit pause does not prevent cleanup checks.
        monitor=setInterval(()=>cleanupTick(),15000);monitor.unref();
      }
      if(r.status!==200||packet?.ok!==true||state.worker_summary.nonce!==state.probe_nonce||state.worker_summary.build!==BUILD||state.worker_summary.refresh_http_status!==200||state.worker_summary.dispatch_http_status!==200||!Number.isSafeInteger(state.worker_summary.workflow_run_id))throw Error('worker_probe_not_passed');
      state.stage='observing_target_run';await record();await observeRun();state.functional_result='passed';state.stage=state.authorization_cleanup_pending?'passed_awaiting_revocation':'passed_and_revoked';await record();
    }catch(e){state.functional_result='not_passed';state.stage='not_passed';const known=new Set(['worker_already_attempted','device_authorization_failed','authorization_incomplete','unexpected_account','returned_token_identity_rejected','run_readback_rejected','run_failed','run_wait_timeout','worker_probe_not_passed']);state.error_code=known.has(e.message)?e.message:e.code==='EEXIST'?'worker_already_attempted':'transport_or_parse_error';if(state.worker_requests_sent&&!state.worker_summary)state.worker_result_unknown=true;await record();}
    finally{userCode='';if(device?.body)device.body.device_code='';if(issued){issued.access_token='';issued.refresh_token='';}if(packet?.credentials){packet.credentials.access_token='';packet.credentials.refresh_token='';}busy=false;await record();}
  }
  async function body(req){let raw='';for await(const chunk of req){raw+=chunk;if(Buffer.byteLength(raw)>4096)throw Error('body_too_large');}return new URLSearchParams(raw);}
  const escape=x=>String(x).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const server=http.createServer(async(req,res)=>{
    if(req.headers.host!=='127.0.0.1:8765'){res.writeHead(403).end();return;}res.setHeader('Cache-Control','no-store');
    if(req.method==='GET'&&req.url==='/status'){res.setHeader('Content-Type','application/json');res.end(JSON.stringify({...state,user_code:userCode}));return;}
    if(req.method==='GET'&&req.url==='/worker-source'){res.setHeader('Content-Type','text/plain; charset=utf-8');res.end(source);return;}
    if(req.method==='POST'){
      if(req.headers.origin!==ROOT){res.writeHead(403).end();return;}
      if(req.url==='/configure'&&!busy&&!held){
        try{const values=await body(req);const candidate=checkedWorkerURL(values.get('worker_url')||'');const r=await request(candidate+'/ready',{headers:{Authorization:'Bearer '+gate}});if(r.status!==200||r.body?.build!==BUILD||r.body?.target!==TARGET||r.body?.ready!==true)throw Error('worker_not_ready');workerURL=candidate;state.worker_url=workerURL;state.gate_verified=true;state.stage='worker_ready';}
        catch{state.stage='worker_setup_failed';state.error_code='worker_url_or_gate_not_ready';}await record();
      }else if(req.url==='/start'&&workerURL&&state.gate_verified&&!busy&&!state.worker_requests_sent){busy=true;execute();}
      else{res.writeHead(409).end('Current step cannot be repeated');return;}
      res.writeHead(303,{Location:'/'}).end();return;
    }
    if(req.method!=='GET'||req.url!=='/'){res.writeHead(404).end();return;}
    res.setHeader('Content-Type','text/html; charset=utf-8');
    res.end(`<!doctype html><meta charset="utf-8"><meta name="referrer" content="same-origin"><title>独立 Worker 验证准备</title><style>body{font:17px system-ui;max-width:850px;margin:45px auto;padding:20px}input{width:95%;padding:9px}pre{font-size:13px;white-space:pre-wrap}code{word-break:break-all}button{padding:9px}</style><h1>独立 Worker 验证准备</h1><p>Worker 名称：rain-client-s0-worker-20261027。先在自己的 Cloudflare 账号创建独立 Worker。</p><p>① <a href="/worker-source" target="_blank">打开待部署的 Worker 源码</a>，复制完整内容到新 Worker。</p><p>② 只在该 Worker 添加 Secret，名称为 <code>PROBE_KEY</code>，值为下方临时调用口令。此口令不要发到聊天或放进源码。</p><code>${escape(gate)}</code><p>③ 填写新 Worker 的 HTTPS workers.dev 地址：</p><form method="post" action="/configure"><input name="worker_url" value="${escape(existingWorkerURL||'')}" required placeholder="https://rain-client-s0-worker-20261027.你的子域.workers.dev/"><button>检查 Worker 与调用口令</button></form><p>④ 检查通过后，点击开始，按当前验证码完成 GitHub 官方授权。</p><form method="post" action="/start"><button>开始这一次云端测试</button></form><p><a href="https://github.com/login/device" target="_blank" rel="noreferrer">GitHub 官方设备授权页</a></p><h2 id="code"></h2><p id="message"></p><details><summary>验证详情</summary><pre id="state"></pre></details><p>结果只显示脱敏摘要。临时 GitHub 凭据不会显示或写文件；Worker 刷新后的凭据留在本机内存，用于撤销检查。</p><script>async function p(){const s=await(await fetch('/status')).json();const labels={awaiting_worker_setup:'等待填写 Worker 地址并检查',worker_ready:'检查已通过，可以开始这一次云端测试',worker_setup_failed:'检查未通过，请核对地址、部署版本和调用口令',awaiting_github_authorization:'请使用上方验证码完成 GitHub 官方授权',calling_cloud_worker:'正在云端刷新并触发空任务，请勿重复点击',observing_target_run:'云端请求已完成，正在等待空任务结果',passed_awaiting_revocation:'功能验证通过，请撤销本轮 GitHub 用户令牌',passed_and_revoked:'功能验证与撤销检查均通过',not_passed:'验证暂未通过，请查看详情并告诉我'};document.getElementById('message').textContent=labels[s.stage]||s.stage;document.getElementById('code').textContent=s.user_code||'';delete s.user_code;document.getElementById('state').textContent=JSON.stringify(s,null,2)}p();setInterval(p,2000)</script>`);
  });
  let stopping=false;
  async function stop(){if(stopping)return;stopping=true;discard();state.local_probe_stopped=true;await record();server.close();process.exit(0);}
  process.on('SIGINT',stop);process.on('SIGTERM',stop);
  setInterval(()=>{if(held&&!state.retention_deadline)state.retention_deadline=new Date(Date.now()+15*60*1000).toISOString();if(held&&Date.now()>Date.parse(state.retention_deadline)){discard();state.memory_retention_timeout=true;record();}},1000).unref();
  await record();server.listen(8765,'127.0.0.1',()=>process.stdout.write('Worker preparation: '+ROOT+'/\n'));
}

if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
  if(process.argv[2]!=='--approved-live')throw Error('Start only after approval with --approved-live');
  await startController();
}
