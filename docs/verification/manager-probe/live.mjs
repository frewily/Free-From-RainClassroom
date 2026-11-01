// Only run after approval of the separate manager experiment and temporary install.
import {spawn} from 'node:child_process';
import {mkdir, writeFile, rename, readFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
import {makeSpec, runProbe, TARGET, CONTROL} from './probe.mjs';

const DIR='/private/tmp/rain-client-s0/github-manager';
const PYTHON='/private/tmp/rain-client-s0/github-manager-venv/bin/python';
const BUILD='rain-s0-github-manager-20261028-v3';
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));

export function curlSpec(url,{method='GET',headers={},body}={}) {
  const u=new URL(url);
  if (u.origin!=='https://api.github.com' && !(u.origin==='https://github.com' && ['/login/device/code','/login/oauth/access_token'].includes(u.pathname) && !u.search)) throw Error('unexpected_origin');
  if (u.username || u.password || u.hash) throw Error('unexpected_url');
  const quote=s=>'"'+String(s).replace(/\\/g,'\\\\').replace(/"/g,'\\"').replace(/\r/g,'\\r').replace(/\n/g,'\\n')+'"';
  const lines=['url = '+quote(url),'proxy = "http://127.0.0.1:7897"','request = '+quote(method)];
  for (const [key,value] of Object.entries(headers)) lines.push('header = '+quote(key+': '+value));
  if (body!==undefined) lines.push('data-binary = '+quote(body));
  // Disable user curlrc, redirects and implicit retries. Sensitive input uses stdin.
  return {args:['--disable','--config','-','--silent','--show-error','--max-time','20','--proto','=https','--noproxy','','--globoff','--write-out','\n%{http_code}'],input:lines.join('\n')+'\n'};
}

async function childText(executable,args,input) {
  return new Promise((resolve,reject)=>{
    const child=spawn(executable,args,{stdio:['pipe','pipe','pipe'],env:{...process.env,PYTHONDONTWRITEBYTECODE:'1'}});
    let output='',tooLarge=false;
    const timer=setTimeout(()=>child.kill('SIGKILL'),25000);
    child.stdin.on('error',()=>{}); child.stderr.on('data',()=>{});
    child.stdout.on('data',part=>{output+=part;if(Buffer.byteLength(output)>1048576){tooLarge=true;output='';child.kill('SIGKILL');}});
    child.on('error',()=>{clearTimeout(timer);reject(Error('private_subprocess_failed'));});
    child.on('close',code=>{clearTimeout(timer);if(code!==0||tooLarge)reject(Error('private_subprocess_failed'));else resolve(output);});
    child.stdin.end(input);
  });
}

async function send(url,options) {
  const spec=curlSpec(url,options);
  let raw=await childText('/usr/bin/curl',spec.args,spec.input); spec.input='';
  const split=raw.lastIndexOf('\n'),status=Number(raw.slice(split+1));
  if (!Number.isInteger(status)||status<200||status>599||(status>=300&&status<400)) throw Error('transport_or_redirect_rejected');
  let body=null;try{body=JSON.parse(raw.slice(0,split));}catch{}raw='';
  return {status,body};
}

export function checkZeroDispatchResume(previous,appId) {
  if(previous?.probe!=='github-manager-20261028-v1'||previous.app_id!==appId||previous.target!==TARGET||previous.control!==CONTROL||
    previous.functional_result!=='not_passed'||previous.error_code!=='write_rejected'||previous.writes_attempted!==1||
    previous.dispatch_attempts!==0||previous.preflight_passed!==true||previous.cleanup_verified!==true||
    previous.authorization_cleanup_pending!==false||previous.revocation_independently_verified!==true||
    previous.revocation_profile_http_status!==401||previous.temporary_token_references_discarded!==true)throw Error('previous_attempt_not_safe_to_resume');
}

export function checkPolicyFixResume(previous,appId,revocation,control) {
  const write=previous?.write_observations?.[0];
  if(previous?.probe!=='github-manager-20261028-v2'||previous.app_id!==appId||previous.target!==TARGET||previous.control!==CONTROL||
    previous.functional_result!=='not_passed'||previous.error_code!=='write_rejected'||previous.writes_attempted!==1||
    previous.dispatch_attempts!==0||previous.preflight_passed!==true||previous.cleanup_verified!==true||
    previous.write_observations?.length!==1||write.method!=='PUT'||write.path!==`/repos/${TARGET}/actions/permissions`||
    write.http_status!==409||write.failure?.message_sha256!=='014659ab9d98c8fea5fed2a5a3bc3c41d6478904a9184c65a57769c439940d14'||
    revocation?.confirmed!==true||revocation.app_id!==appId||revocation.attempt_nonce!==previous.nonce||
    !['user_report','independent_401'].includes(revocation.evidence_kind)||
    control?.not_manager_app_capability_evidence!==true||control.same_error_as_manager_app!==true||
    control.original_payload_http_status!==409||control.enabled_only_payload_http_status!==204||control.policy_restored!==true||
    control.policy_baseline?.enabled!==true||control.policy_baseline.allowed_actions!=='all'||control.policy_baseline.sha_pinning_required!==false)throw Error('policy_fix_continuation_not_ready');
}

export async function main(args) {
  const resume=args.length===4 && args[3]==='--resume-after-zero-dispatch';
  const policyFix=args.length===4 && args[3]==='--resume-after-policy-fix';
  if ((!resume&&!policyFix&&args.length!==3) || args[0]!=='--approved-live' || !/^\d+$/.test(args[1]) || !/^Iv[0-9A-Za-z]{18}$/.test(args[2])) throw Error('approved_live_and_public_app_identifiers_required');
  const appId=Number(args[1]),clientId=args[2];
  if (!Number.isSafeInteger(appId)||appId<=0||appId===5489930||clientId==='Iv23li2VecQYTHgNvvHE') throw Error('separate_manager_app_required');
  // Fail before starting authorization if the approved encryption dependency is unavailable.
  const selfTest=await childText(PYTHON,[new URL('./seal.py',import.meta.url).pathname,'--self-test'],'');
  if(JSON.parse(selfTest).sealed_box_roundtrip!==true) throw Error('sealed_box_self_test_failed');
  await mkdir(DIR,{recursive:true,mode:0o700});
  if(resume) {
    const previous=JSON.parse(await readFile(DIR+'/result.json','utf8'));
    checkZeroDispatchResume(previous,appId);
    await writeFile(DIR+'/previous-result-20261028.json',JSON.stringify(previous,null,2)+'\n',{flag:'wx',mode:0o600});
  }
  if(policyFix) {
    const previous=JSON.parse(await readFile(DIR+'/result.json','utf8'));
    const revocation=JSON.parse(await readFile(DIR+'/revocation-confirmation-v2.json','utf8'));
    const control=JSON.parse(await readFile(DIR+'/owner-policy-parameter-control.json','utf8'));
    checkPolicyFixResume(previous,appId,revocation,control);
    await writeFile(DIR+'/previous-policy-conflict-result-20261028.json',JSON.stringify(previous,null,2)+'\n',{flag:'wx',mode:0o600});
  }
  const spec=makeSpec();
  const guard=policyFix?'/attempt-20261028-policy-fix.json':resume?'/attempt-20261028-resume1.json':'/attempt-20261028.json';
  await writeFile(DIR+guard,JSON.stringify({app_id:appId,client_id:clientId,spec,started_at:new Date().toISOString(),zero_dispatch_resume:resume,verified_policy_fix:policyFix})+'\n',{flag:'wx',mode:0o600});
  let held=null,writes=Promise.resolve(),envelope={stage:'requesting_device_code',app_id:appId};
  async function save(state=envelope) {
    envelope={...state,observed_at:new Date().toISOString()}; const json=JSON.stringify(envelope,null,2)+'\n';
    writes=writes.then(async()=>{await writeFile(DIR+'/result.json.tmp',json,{mode:0o600});await rename(DIR+'/result.json.tmp',DIR+'/result.json');});
    return writes;
  }
  const api=(method,path,body)=>send('https://api.github.com'+path,{method,headers:{Accept:'application/vnd.github+json','User-Agent':BUILD,'X-GitHub-Api-Version':'2026-03-10',Authorization:'Bearer '+held},...(body===undefined?{}:{body:JSON.stringify(body)})});
  const form=body=>send('https://github.com/login/oauth/access_token',{method:'POST',headers:{Accept:'application/json','Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams(body).toString()});
  try {
    await save();
    let device=await send('https://github.com/login/device/code',{method:'POST',headers:{Accept:'application/json','Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({client_id:clientId,scope:'offline_access'}).toString()});
    const d=device.body;
    if(device.status!==200 || !/^[A-Z0-9]{4}-[A-Z0-9]{4}$/.test(d?.user_code) || typeof d.device_code!=='string' || d.verification_uri!=='https://github.com/login/device' || !Number.isFinite(d.expires_in) || d.expires_in<=0 || d.expires_in>900) throw Error('device_code_rejected');
    const deadline=Date.now()+d.expires_in*1000;
    await save({stage:'awaiting_github_authorization',app_id:appId,expires_at:new Date(deadline).toISOString()});
    process.stdout.write(JSON.stringify({verification_uri:d.verification_uri,user_code:d.user_code,expires_at:new Date(deadline).toISOString()})+'\n');
    let interval=Math.max(5,Number(d.interval)||5);
    while(Date.now()<deadline) {
      await delay(interval*1000);
      const r=await form({client_id:clientId,device_code:d.device_code,grant_type:'urn:ietf:params:oauth:grant-type:device_code'});
      if(r.status===200 && r.body?.error==='authorization_pending')continue;
      if(r.status===200 && r.body?.error==='slow_down'){interval+=5;continue;}
      if(r.status!==200 || typeof r.body?.access_token!=='string' || r.body?.error)throw Error('device_authorization_rejected');
      held=r.body.access_token; r.body.access_token='';r.body.refresh_token='';break;
    }
    d.device_code='';device=null;
    if(!held)throw Error('device_authorization_expired');
    const result=await runProbe({appId,spec,request:api,checkpoint:save,seal:async(publicKey,plaintext)=>{
      const value=await childText(PYTHON,[new URL('./seal.py',import.meta.url).pathname],JSON.stringify({public_key:publicKey,plaintext}));
      return value.trim();
    }});
    await save({...result,authorization_cleanup_pending:true});
    process.stdout.write('Probe finished. Review result.json, then revoke the manager App user tokens.\n');
    // Independent of Codex turn/usage pauses: confirm revocation without logging profiles.
    const retentionDeadline=Date.now()+15*60*1000;
    while(Date.now()<retentionDeadline && held) {
      await delay(15000);
      try {
        const r=await api('GET','/user');
        await save({...envelope,revocation_profile_http_status:r.status});
        if(r.status===401) {
          held=null;
          await save({...envelope,authorization_cleanup_pending:false,revocation_independently_verified:true,temporary_token_references_discarded:true});
        }
      } catch { await save({...envelope,revocation_check_transport_error:true}); }
    }
    if(held) {held=null;await save({...envelope,memory_retention_timeout:true,temporary_token_references_discarded:true});}
  } catch {
    held=null;
    await save({...envelope,local_error:'live_probe_stopped',temporary_token_references_discarded:true});
    process.exitCode=1;
  } finally { held=null; }
}

if(process.argv[1] && import.meta.url===pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).catch(()=>{process.stderr.write('manager_probe_not_started_or_local_failure\n');process.exitCode=1;});
}
