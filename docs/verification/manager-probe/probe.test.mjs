import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {BASELINE, TARGET, CONTROL, PERMISSIONS, makeSpec, restrictedApi, runProbe, workflowSource, safeFailure} from './probe.mjs';
import {curlSpec, checkZeroDispatchResume, checkPolicyFixResume} from './live.mjs';

const APP=9000001, spec=makeSpec('012345abcdef');
const base=`/repos/${TARGET}`;
const sha=text=>createHash('sha1').update(text).digest('hex');
function fixture(options={}) {
  const files=new Map(),calls=[],snapshots=[];
  let settings={enabled:true,allowed_actions:options.selected?'selected':'all',sha_pinning_required:true};
  let head=BASELINE,secret=options.existingSecret||false,commits=0;
  if(options.existingFile)files.set(`${base}/contents/${spec.config}`,{source:'owner existing file',sha:'f'.repeat(40)});
  const response=(status,body=null)=>({status,body});
  const request=async(method,path,body)=>{
    calls.push({method,path,body});
    if(path==='/user')return response(200,{login:options.wrongUser?'other':'frewily',private_field:'DO_NOT_SAVE_PRIVATE'});
    if(path==='/user/installations?per_page=100')return response(200,{total_count:1,installations:[{id:123,app_id:APP,account:{login:'frewily'},repository_selection:options.allRepos?'all':'selected',permissions:{...PERMISSIONS,...(options.extraPermission?{issues:'write'}:{})}}]});
    if(path==='/user/installations/123/repositories?per_page=100')return response(200,{total_count:options.extraRepository?2:1,repositories:[{full_name:TARGET},...(options.extraRepository?[{full_name:CONTROL}]:[])]});
    if(path===`/repos/${CONTROL}/actions/secrets/public-key`)return response(options.controlAllowed?200:403,{key:'DO_NOT_SAVE_PRIVATE'});
    if(path===base)return response(200,{full_name:TARGET,default_branch:'main',private:false,archived:false});
    if(path===`${base}/commits/main`)return response(200,{sha:options.changedBaseline?'f'.repeat(40):head});
    if(path===`${base}/actions/runs?per_page=100`)return response(200,{total_count:1,workflow_runs:[{status:options.active?'queued':'completed'}]});
    if(path===`${base}/actions/permissions/selected-actions`)return response(200,{github_owned_allowed:true,verified_allowed:false,patterns_allowed:['synthetic/*']});
    if(path===`${base}/actions/permissions`) {
      if(method==='GET')return response(200,options.strictDisabledPolicy&&!settings.enabled?{enabled:false,sha_pinning_required:settings.sha_pinning_required}:{...settings});
      if(!body.enabled && options.strictDisabledPolicy && Object.keys(body).length!==1)return response(409,{message:'Conflict'});
      if(!body.enabled && options.disableDenied)return response(403,{message:'Resource not accessible by integration',private:'DO_NOT_SAVE_PRIVATE'});
      if(body.enabled && options.restoreDenied)return response(403);
      settings={...settings,...body};
      if(!body.enabled && options.externalPolicy)settings.allowed_actions='local_only';
      if(!body.enabled && options.disableResponseLost)throw Error('DO_NOT_SAVE_PRIVATE');
      if(body.enabled && options.restoreResponseLost)throw Error('DO_NOT_SAVE_PRIVATE');
      return response(204);
    }
    if(path.startsWith(`${base}/contents/`)) {
      const file=files.get(path);
      if(method==='GET') {
        if(file && options.externalFile && path.endsWith(spec.workflow))return response(200,{encoding:'base64',content:Buffer.from('owner changed this file').toString('base64'),sha:'e'.repeat(40)});
        return file?response(200,{encoding:'base64',content:Buffer.from(file.source).toString('base64'),sha:file.sha}):response(404);
      }
      if(method==='PUT') {
        const source=Buffer.from(body.content,'base64').toString();
        files.set(path,{source,sha:sha(source)});head=(++commits).toString(16).padStart(40,'0');
        if(options.fileResponseLost && path.endsWith(spec.workflow))throw Error('DO_NOT_SAVE_PRIVATE');
        if(options.changedBeforeCleanup && path.endsWith(spec.workflow))return response(403);
        return response(201,{commit:{sha:head}});
      }
      if(method==='DELETE') {
        if(options.changedBeforeCleanup && path.endsWith(spec.workflow)) {
          // Simulate a concurrent owner update just before the cleanup read.
          return response(409);
        }
        assert.equal(body.sha,file.sha);files.delete(path);return response(200,{});
      }
    }
    if(path===`${base}/actions/secrets/public-key`)return response(200,{key_id:'synthetic-key-id',key:Buffer.alloc(32).toString('base64')});
    if(path===`${base}/actions/secrets/${spec.secret}`) {
      if(method==='GET')return response(secret?200:404,secret?{name:spec.secret}:null);
      if(method==='PUT') {secret=true;if(options.secretResponseLost)throw Error('DO_NOT_SAVE_PRIVATE');return response(201);}
      if(method==='DELETE') {secret=false;return response(204);}
    }
    if(path.endsWith('/dispatches')) {
      assert.equal(method,'POST');assert.deepEqual(body,{ref:'main'});
      if(options.dispatchResponseLost)throw Error('DO_NOT_SAVE_PRIVATE');
      return response(200,{workflow_run_id:123456});
    }
    if(path===`${base}/actions/runs/123456`)return response(200,{head_sha:options.wrongRun?'e'.repeat(40):head,path:spec.workflow,event:'workflow_dispatch',display_title:spec.title,status:options.timeout?'queued':'completed',conclusion:options.timeout?null:options.runnerFailed?'failure':'success'});
    throw Error('Unexpected synthetic request');
  };
  let ticks=0;
  const execute=extra=>runProbe({request,appId:APP,spec,sleep:async()=>{},now:()=>++ticks*10000,runTimeoutMs:30000,
    seal:async(key,text)=>{assert.equal(Buffer.from(key,'base64').length,32);return Buffer.alloc(Buffer.byteLength(text)+48).toString('base64');},
    checkpoint:async state=>snapshots.push(state),...extra});
  return {request,execute,calls,snapshots,files,settings:()=>settings,secret:()=>secret};
}

test('successful manager sequence verifies Runner and restores/removes all test resources',async()=>{
  const f=fixture({selected:true}),s=await f.execute();
  assert.equal(s.functional_result,'passed');assert.equal(s.runner_secret_verified,true);
  assert.equal(s.cleanup_verified,true);assert.equal(s.policy_restored,true);
  assert.equal(s.dispatch_attempts,1);assert.equal(f.files.size,0);assert.equal(f.secret(),false);
  assert.deepEqual(f.settings(),{enabled:true,allowed_actions:'selected',sha_pinning_required:true});
  assert(!JSON.stringify(f.snapshots).includes('DO_NOT_SAVE_PRIVATE'));
  assert(f.calls.filter(c=>c.path.includes(CONTROL)).every(c=>c.method==='GET'));
});

for(const [name,options] of Object.entries({identity:{wrongUser:true},permissions:{extraPermission:true},all_repositories:{allRepos:true},extra_repository:{extraRepository:true},control_access:{controlAllowed:true},changed_baseline:{changedBaseline:true},active_run:{active:true}})) {
  test(`preflight ${name} prevents every mutation`,async()=>{
    const f=fixture(options),s=await f.execute();
    assert.equal(s.functional_result,'not_passed');assert.equal(s.writes_attempted,0);
    assert(f.calls.every(c=>c.method==='GET'));
  });
}

for(const [name,options] of Object.entries({disable_response:{disableResponseLost:true},file_response:{fileResponseLost:true},secret_response:{secretResponseLost:true},dispatch_response:{dispatchResponseLost:true},runner_failure:{runnerFailed:true},wrong_run:{wrongRun:true},runner_timeout:{timeout:true}})) {
  test(`failure at ${name} is not retried and still cleans up`,async()=>{
    const f=fixture(options),s=await f.execute();assert.equal(s.functional_result,'not_passed');
    assert.equal(s.cleanup_verified,true);assert.equal(f.files.size,0);assert.equal(f.secret(),false);assert.equal(f.settings().enabled,true);
    assert(f.calls.filter(c=>c.path.endsWith('/dispatches')).length<=1);
    assert(!JSON.stringify(s).includes('DO_NOT_SAVE_PRIVATE'));
    if(options.dispatchResponseLost)assert.equal(s.dispatch_result_unknown,true);
  });
}

test('lost restore acknowledgement is confirmed by readback without a second restore PUT',async()=>{
  const f=fixture({restoreResponseLost:true}),s=await f.execute();assert.equal(s.functional_result,'passed');
  assert.equal(f.calls.filter(c=>c.method==='PUT'&&c.path.endsWith('/actions/permissions')&&c.body.enabled).length,1);
});
test('denied policy restoration stays visible and prevents configuration/dispatch',async()=>{
  const f=fixture({restoreDenied:true}),s=await f.execute();assert.equal(s.functional_result,'not_passed');
  assert.equal(s.cleanup_verified,false);assert(s.cleanup_pending.includes('actions_policy'));
  assert.equal(s.dispatch_attempts,0);assert.equal(f.calls.some(c=>c.method==='PUT'&&c.path.includes('/contents/')),false);
});
test('cleanup conflict is retained as pending rather than deleting with a different SHA',async()=>{
  const f=fixture({changedBeforeCleanup:true}),s=await f.execute();
  assert.equal(s.cleanup_verified,false);assert.deepEqual(s.cleanup_pending,['workflow_file']);
  assert.equal(f.files.size,1);
});
for(const option of ['existingFile','existingSecret'])test(`${option} is preserved and blocks all writes`,async()=>{
  const f=fixture({[option]:true}),s=await f.execute();assert.equal(s.functional_result,'not_passed');
  assert(f.calls.every(c=>c.method==='GET'));assert.equal(option==='existingFile'?f.files.size:f.secret(),option==='existingFile'?1:true);
});
test('a file changed by its owner is retained without any DELETE request',async()=>{
  const f=fixture({externalFile:true}),s=await f.execute();assert.equal(s.cleanup_verified,false);
  assert.deepEqual(s.cleanup_pending,['workflow_file']);
  assert(!f.calls.some(c=>c.method==='DELETE'&&c.path.endsWith(spec.workflow)));
});
test('a concurrent policy change is reported and not overwritten by restoration',async()=>{
  const f=fixture({externalPolicy:true}),s=await f.execute();assert.equal(s.cleanup_verified,false);
  assert(s.cleanup_pending.includes('actions_policy'));
  assert.equal(f.calls.filter(c=>c.method==='PUT'&&c.path.endsWith('/actions/permissions')).length,1);
});
test('a checkpoint failure blocks new writes but cannot block cleanup of existing resources',async()=>{
  const f=fixture();let writes=0;
  const s=await f.execute({checkpoint:async state=>{writes=state.writes_attempted;if(writes>=3)throw Error('synthetic disk full');}});
  assert.equal(s.functional_result,'not_passed');assert.equal(s.checkpoint_failed,true);
  assert.equal(s.cleanup_verified,true);assert.equal(f.files.size,0);assert.equal(f.settings().enabled,true);
});
test('the scheduler App and changed test paths are rejected before any requests',async()=>{
  const f=fixture();await assert.rejects(()=>f.execute({appId:5489930}));
  await assert.rejects(()=>f.execute({spec:{...spec,config:'README.md'}}));assert.equal(f.calls.length,0);
});
test('boundary guard rejects production writes, control writes and unrelated endpoints',async()=>{
  const f=fixture(),api=restrictedApi(f.request,spec);
  for(const [method,path] of [['PUT',`/repos/${CONTROL}/contents/README.md`],['DELETE',base],['PUT',`${base}/contents/README.md`],['POST',`${base}/actions/workflows/s0-probe.yml/dispatches`],['GET','/repos/frewily/Fuck-Yangtze-RainClassroom/actions/secrets/public-key']])await assert.rejects(()=>api(method,path));
  assert.equal(f.calls.length,0);
});
test('workflow has no checkout, third-party action, timer or secret output',()=>{
  const source=workflowSource(spec,'a'.repeat(64));
  assert(source.includes('on: workflow_dispatch'));assert(source.includes('permissions: {}'));
  assert(source.includes(`CANARY: \${{ secrets.${spec.secret} }}`));
  for(const text of ['uses:','schedule:','pull_request:','push:','print(os.environ','echo $'])assert(!source.includes(text));
});
test('transport keeps credentials out of arguments and forbids alternate origins',()=>{
  const s=curlSpec('https://api.github.com/user',{headers:{Authorization:'Bearer SYNTHETIC_TOKEN'},body:'SYNTHETIC_PRIVATE_BODY'});
  assert(!JSON.stringify(s.args).includes('SYNTHETIC'));assert(s.input.includes('SYNTHETIC_TOKEN'));assert(s.input.includes('SYNTHETIC_PRIVATE_BODY'));
  assert.equal(s.args[0],'--disable');assert(!s.args.includes('--location'));assert(!s.args.includes('--retry'));
  for(const url of ['http://api.github.com/user','https://example.com/user','https://github.com/elsewhere','https://secret@api.github.com/user'])assert.throws(()=>curlSpec(url));
});
test('lock file pins exactly three approved binary distributions',async()=>{
  const lock=await readFile(new URL('./requirements.lock',import.meta.url),'utf8');
  assert.equal(lock.split('\n').filter(l=>l&&!l.startsWith('#')).length,3);
  assert.equal((lock.match(/--hash=sha256:[a-f0-9]{64}/g)||[]).length,3);
});
test('policy write diagnostics retain HTTP status and a safe reason without response contents',async()=>{
  const f=fixture({disableDenied:true}),s=await f.execute();
  assert.equal(s.functional_result,'not_passed');assert.equal(s.dispatch_attempts,0);assert.equal(s.cleanup_verified,true);
  assert.equal(s.write_observations.length,1);assert.equal(s.write_observations[0].http_status,403);
  assert.equal(s.write_observations[0].expected_http_status,204);
  assert.equal(s.write_observations[0].failure.reason,'integration_access_denied');
  assert(!JSON.stringify(s).includes('DO_NOT_SAVE_PRIVATE'));
});
test('unknown upstream messages and validation values are never copied into evidence',()=>{
  const s=safeFailure({message:'DO_NOT_SAVE_PRIVATE',errors:[{field:'enabled',code:'invalid',value:'DO_NOT_SAVE_PRIVATE'},{field:'DO_NOT_SAVE_PRIVATE',code:'DO_NOT_SAVE_PRIVATE'}]});
  assert(!JSON.stringify(s).includes('DO_NOT_SAVE_PRIVATE'));assert.deepEqual(s.validation_fields,[{field:'enabled',code:'invalid'}]);
});
test('diagnostic continuation requires zero dispatches, complete cleanup and independently verified revocation',()=>{
  const previous={probe:'github-manager-20261028-v1',app_id:APP,target:TARGET,control:CONTROL,functional_result:'not_passed',error_code:'write_rejected',writes_attempted:1,dispatch_attempts:0,preflight_passed:true,cleanup_verified:true,authorization_cleanup_pending:false,revocation_independently_verified:true,revocation_profile_http_status:401,temporary_token_references_discarded:true};
  assert.doesNotThrow(()=>checkZeroDispatchResume(previous,APP));
  for(const change of [{dispatch_attempts:1},{cleanup_verified:false},{authorization_cleanup_pending:true},{revocation_independently_verified:false},{app_id:APP+1},{writes_attempted:2}])assert.throws(()=>checkZeroDispatchResume({...previous,...change},APP));
});
test('disabled policy API contract accepts only the switch and omits allowed_actions on readback',async()=>{
  const f=fixture({strictDisabledPolicy:true}),s=await f.execute();
  assert.equal(s.functional_result,'passed');assert.equal(s.policy_restored,true);assert.equal(s.cleanup_verified,true);
  const disable=f.calls.find(c=>c.method==='PUT'&&c.path.endsWith('/actions/permissions')&&c.body.enabled===false);
  assert.deepEqual(disable.body,{enabled:false});
  assert.deepEqual(f.settings(),{enabled:true,allowed_actions:'all',sha_pinning_required:true});
});
test('the verified policy fix cannot continue after any dispatch or without cleanup and revocation evidence',()=>{
  const previous={probe:'github-manager-20261028-v2',app_id:APP,target:TARGET,control:CONTROL,nonce:spec.nonce,functional_result:'not_passed',error_code:'write_rejected',writes_attempted:1,dispatch_attempts:0,preflight_passed:true,cleanup_verified:true,write_observations:[{method:'PUT',path:`${base}/actions/permissions`,http_status:409,failure:{message_sha256:'014659ab9d98c8fea5fed2a5a3bc3c41d6478904a9184c65a57769c439940d14'}}]};
  const revocation={confirmed:true,app_id:APP,attempt_nonce:spec.nonce,evidence_kind:'user_report'};
  const control={not_manager_app_capability_evidence:true,same_error_as_manager_app:true,original_payload_http_status:409,enabled_only_payload_http_status:204,policy_restored:true,policy_baseline:{enabled:true,allowed_actions:'all',sha_pinning_required:false}};
  assert.doesNotThrow(()=>checkPolicyFixResume(previous,APP,revocation,control));
  for(const change of [{dispatch_attempts:1},{cleanup_verified:false},{app_id:APP+1},{writes_attempted:2},{write_observations:[]}])assert.throws(()=>checkPolicyFixResume({...previous,...change},APP,revocation,control));
  assert.throws(()=>checkPolicyFixResume(previous,APP,{...revocation,confirmed:false},control));
  assert.throws(()=>checkPolicyFixResume(previous,APP,revocation,{...control,policy_restored:false}));
});
