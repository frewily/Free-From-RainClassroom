// Isolated stage-0 experiment. Importing this module does not make network requests.
import {createHash, randomBytes} from 'node:crypto';

export const TARGET = 'frewily/rain-client-s0-target-20261027';
export const CONTROL = 'frewily/rain-client-s0-control-20261027';
export const BASELINE = '643a01c40f6ceb4b953036dfc5dcc1f8541193ac';
export const PERMISSIONS = Object.freeze({actions:'write', administration:'write', contents:'write', metadata:'read', secrets:'write', workflows:'write'});
const base = `/repos/${TARGET}`;
const hash = value => createHash('sha256').update(value).digest('hex');
const same = (a,b) => JSON.stringify(a) === JSON.stringify(b);
export class ProbeError extends Error {}
function check(ok, code) { if (!ok) throw new ProbeError(code); }

export function safeFailure(body) {
  const message=typeof body?.message==='string'?body.message:'';
  const patterns=[
    ['integration_access_denied',/resource not accessible by (integration|personal access token)/i],
    ['app_key_required',/(private|public) key.*(required|must|need)|must.*(private|public) key|generate.*(private|public) key/i],
    ['rate_limited',/rate limit|abuse detection/i],
    ['bad_credentials',/bad credentials/i],
    ['request_body_rejected',/parsing json|json object|request body/i],
    ['validation_rejected',/validation failed|invalid request/i],
    ['conflict',/^conflict$/i],
    ['not_found',/^not found$/i],
    ['endpoint_not_supported',/not supported|not allowed.*endpoint/i]
  ];
  const fieldNames=new Set(['enabled','allowed_actions','sha_pinning_required','content','sha','branch','encrypted_value','key_id','ref']);
  const codes=new Set(['missing_field','missing','invalid','already_exists','unprocessable','custom']);
  return {reason:patterns.find(([,pattern])=>pattern.test(message))?.[0]||'unclassified_upstream_response',
    ...(message?{message_sha256:hash(message)}:{}),
    validation_fields:Array.isArray(body?.errors)?body.errors.slice(0,10).map(e=>({
      ...(fieldNames.has(e?.field)?{field:e.field}:{}),...(codes.has(e?.code)?{code:e.code}:{})
    })).filter(e=>Object.keys(e).length):[]};
}

export function makeSpec(nonce = randomBytes(6).toString('hex')) {
  check(/^[a-f0-9]{12}$/.test(nonce), 'bad_nonce');
  return Object.freeze({nonce, config:`.rain-client-s0/manager-20261028-${nonce}.json`,
    workflow:`.github/workflows/s0-manager-20261028-${nonce}.yml`,
    secret:`RAIN_S0_MANAGER_20261028_${nonce.toUpperCase()}`, title:`S0 manager ${nonce}`});
}

export function workflowSource(spec, digest) {
  check(/^[a-f0-9]{64}$/.test(digest), 'bad_digest');
  return [
    `name: ${spec.title}`, `run-name: ${spec.title}`, "on: workflow_dispatch", 'permissions: {}',
    'jobs:', '  verify:', '    runs-on: ubuntu-latest', '    timeout-minutes: 2', '    steps:',
    '      - name: Verify synthetic secret without printing it', '        env:',
    `          CANARY: \${{ secrets.${spec.secret} }}`, `          EXPECTED_SHA256: ${digest}`,
    '        run: |', "          python3 - <<'PY'", '          import hashlib, hmac, os',
    '          actual = hashlib.sha256(os.environ["CANARY"].encode()).hexdigest()',
    '          if not hmac.compare_digest(actual, os.environ["EXPECTED_SHA256"]):',
    '              raise SystemExit("Synthetic secret verification failed")',
    '          print("Synthetic secret verification passed")', '          PY', ''
  ].join('\n');
}

// A second boundary in addition to the App installation. This is a program guard,
// not a claim that the platform grants only these individual operations.
export function restrictedApi(request, spec) {
  const config = `${base}/contents/${spec.config}`;
  const workflow = `${base}/contents/${spec.workflow}`;
  const secret = `${base}/actions/secrets/${spec.secret}`;
  return async (method, path, body) => {
    const reads = ['/user', '/user/installations?per_page=100', base,
      `${base}/commits/main`, `${base}/actions/runs?per_page=100`,
      `${base}/actions/permissions`, `${base}/actions/permissions/selected-actions`,
      `${base}/actions/secrets/public-key`, config, workflow, secret,
      `/repos/${CONTROL}/actions/secrets/public-key`];
    const allowed = method === 'GET' && (reads.includes(path) ||
      /^\/user\/installations\/\d+\/repositories\?per_page=100$/.test(path) ||
      new RegExp(`^${base}/actions/runs/[0-9]+$`).test(path)) ||
      ['PUT','DELETE'].includes(method) && [config,workflow].includes(path) ||
      ['PUT','DELETE'].includes(method) && path === secret ||
      method === 'PUT' && path === `${base}/actions/permissions` ||
      method === 'POST' && path === `${base}/actions/workflows/${spec.workflow.split('/').at(-1)}/dispatches`;
    check(allowed, 'request_outside_test_boundary');
    return request(method, path, body);
  };
}

function policy(body, baseline) {
  const allowed=body?.allowed_actions ?? (body?.enabled===false?baseline?.allowed_actions:undefined);
  check(typeof body?.enabled === 'boolean' && ['all','local_only','selected'].includes(allowed), 'bad_policy');
  const out = {enabled:body.enabled, allowed_actions:allowed};
  if (body.sha_pinning_required !== undefined) {
    check(typeof body.sha_pinning_required === 'boolean', 'bad_policy');
    out.sha_pinning_required = body.sha_pinning_required;
  } else if(body.enabled===false && typeof baseline?.sha_pinning_required==='boolean') {
    out.sha_pinning_required=baseline.sha_pinning_required;
  }
  return out;
}

export async function runProbe({request, seal, appId, spec=makeSpec(), checkpoint=async()=>{},
  sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms)), now=Date.now, runTimeoutMs=180000}) {
  check(Number.isSafeInteger(appId) && appId > 0 && appId !== 5489930, 'bad_manager_app_id');
  check(same(spec,makeSpec(spec.nonce)), 'bad_probe_spec');
  const api = restrictedApi(request, spec);
  const state = {probe:'github-manager-20261028-v3', nonce:spec.nonce, target:TARGET, control:CONTROL,
    app_id:appId, functional_result:'not_run', dispatch_attempts:0, writes_attempted:0,
    credentials_saved_to_file:false, cleanup_pending:[], write_observations:[]};
  const owned = new Map(); let baseline, selectedPolicy, policyTouched=false, restoreAttempted=false;
  let canary;
  const record = async stage => {
    state.stage=stage;
    try { await checkpoint(structuredClone(state)); } catch { state.checkpoint_failed=true; }
  };
  const get = async (path, status=200) => {
    const r=await api('GET',path); check(r.status===status, 'readback_rejected'); return r.body;
  };
  const mutate = async (method,path,body,expected,cleanupWrite=false) => {
    state.writes_attempted++; await record('writing_test_resource');
    check(cleanupWrite || !state.checkpoint_failed, 'checkpoint_failed');
    const r=await api(method,path,body);
    state.write_observations.push({method,path,http_status:r.status,expected_http_status:expected,
      ...(r.status===expected?{}:{failure:safeFailure(r.body)})});
    await record('write_response_received');
    check(r.status===expected, 'write_rejected'); return r.body;
  };
  const readPolicy = async () => {
    const value=await get(`${base}/actions/permissions`);
    if(value?.enabled===false)state.disabled_policy_fields_omitted=['allowed_actions','sha_pinning_required'].filter(key=>value[key]===undefined);
    return policy(value,baseline);
  };
  async function restorePolicy() {
    if (!policyTouched) return;
    let current=await readPolicy();
    if (!same(current,baseline)) {
      check(same(current,{...baseline,enabled:false}), 'policy_changed_externally');
      check(!restoreAttempted, 'policy_restore_needs_attention'); restoreAttempted=true;
      // A lost restore response is reconciled by GET; the PUT is never blindly retried.
      try { await mutate('PUT',`${base}/actions/permissions`,baseline,204,true); } catch {}
      current=await readPolicy();
    }
    check(same(current,baseline), 'policy_restore_needs_attention');
    if (selectedPolicy) check(same(await get(`${base}/actions/permissions/selected-actions`),selectedPolicy), 'selected_policy_changed');
    policyTouched=false; state.policy_restored=true;
  }
  async function cleanup() {
    const pending=[];
    try { await restorePolicy(); } catch { pending.push('actions_policy'); }
    for (const [path,source] of [...owned].reverse()) {
      try {
        const r=await api('GET',path);
        if (r.status!==404) {
          check(r.status===200, 'cleanup_readback_rejected');
          if (source!==null) {
            check(r.body?.encoding==='base64' && Buffer.from(r.body.content,'base64').toString()===source && /^[a-f0-9]{40}$/.test(r.body.sha), 'file_changed_externally');
            try { await mutate('DELETE',path,{message:`S0 cleanup ${spec.nonce}`,sha:r.body.sha,branch:'main'},200,true); } catch {}
          } else {
            try { await mutate('DELETE',path,undefined,204,true); } catch {}
          }
          check((await api('GET',path)).status===404, 'cleanup_not_confirmed');
        }
      } catch { pending.push(path.endsWith(spec.secret)?'synthetic_secret':path.endsWith(spec.workflow)?'workflow_file':'config_file'); }
    }
    state.cleanup_pending=pending; state.cleanup_verified=pending.length===0;
  }
  async function createFile(path,source) {
    owned.set(path,source); await record('file_create_attempt');
    const result=await mutate('PUT',path,{message:`S0 manager ${spec.nonce}`,content:Buffer.from(source).toString('base64'),branch:'main'},201);
    check(/^[a-f0-9]{40}$/.test(result?.commit?.sha), 'bad_commit_response');
    const read=await get(path);
    check(read?.encoding==='base64' && Buffer.from(read.content,'base64').toString()===source, 'file_readback_mismatch');
    return result.commit.sha;
  }
  try {
    await record('checking_identity_and_installation');
    check((await get('/user'))?.login==='frewily', 'unexpected_account');
    const installs=await get('/user/installations?per_page=100');
    check(installs?.total_count<=100 && Array.isArray(installs.installations), 'bad_installations');
    const matches=installs.installations.filter(i=>i.app_id===appId);
    check(matches.length===1, 'bad_installations'); const installation=matches[0];
    check(installation.account?.login==='frewily' && installation.repository_selection==='selected' && !installation.suspended_at && Number.isSafeInteger(installation.id), 'bad_installation_scope');
    check(same(Object.entries(installation.permissions||{}).sort(),Object.entries(PERMISSIONS).sort()), 'bad_permissions');
    const repos=await get(`/user/installations/${installation.id}/repositories?per_page=100`);
    check(repos?.total_count===1 && repos.repositories?.length===1 && repos.repositories[0].full_name===TARGET, 'bad_repository_scope');
    state.selected_repository_verified=true;
    const denied=await api('GET',`/repos/${CONTROL}/actions/secrets/public-key`);
    state.control_secret_key_http_status=denied.status;
    check([403,404].includes(denied.status), 'control_access_not_denied');
    const repo=await get(base);
    check(repo?.full_name===TARGET && repo.default_branch==='main' && repo.private===false && !repo.archived, 'unexpected_target');
    check((await get(`${base}/commits/main`))?.sha===BASELINE, 'baseline_changed');
    const runs=await get(`${base}/actions/runs?per_page=100`);
    check(Number.isSafeInteger(runs?.total_count) && runs.total_count<=100 && Array.isArray(runs.workflow_runs) && runs.workflow_runs.length===runs.total_count && runs.workflow_runs.every(r=>r.status==='completed'), 'target_not_idle');
    const configPath=`${base}/contents/${spec.config}`, workflowPath=`${base}/contents/${spec.workflow}`;
    const secretPath=`${base}/actions/secrets/${spec.secret}`;
    for (const path of [configPath,workflowPath,secretPath]) await get(path,404);
    baseline=await readPolicy(); check(baseline.enabled, 'target_actions_initially_disabled');
    state.policy_baseline=baseline;
    if (baseline.allowed_actions==='selected') selectedPolicy=await get(`${base}/actions/permissions/selected-actions`);
    state.preflight_passed=true;
    policyTouched=true; await record('actions_disable_attempt');
    await mutate('PUT',`${base}/actions/permissions`,{enabled:false},204);
    check(same(await readPolicy(),{...baseline,enabled:false}), 'disable_readback_mismatch');
    state.policy_disable_verified=true; await restorePolicy();
    const config=JSON.stringify({kind:'synthetic-manager-probe',schema:1,nonce:spec.nonce},null,2)+'\n';
    await createFile(configPath,config); state.config_readback_verified=true;
    canary=randomBytes(32).toString('hex'); const digest=hash(canary);
    const head=await createFile(workflowPath,workflowSource(spec,digest)); state.workflow_readback_verified=true;
    const key=await get(`${base}/actions/secrets/public-key`);
    check(typeof key?.key_id==='string' && /^[A-Za-z0-9+/]{43}=$/.test(key?.key), 'bad_repository_key');
    const encrypted=await seal(key.key,canary);
    check(typeof encrypted==='string' && /^[A-Za-z0-9+/]+={0,2}$/.test(encrypted) && Buffer.from(encrypted,'base64').length===Buffer.byteLength(canary)+48, 'bad_sealed_box');
    owned.set(secretPath,null); await record('synthetic_secret_write_attempt');
    await mutate('PUT',secretPath,{encrypted_value:encrypted,key_id:key.key_id},201); canary=undefined;
    await get(secretPath); state.secret_metadata_readback_verified=true;
    // Recheck the committed workflow and head immediately before the one dispatch.
    check((await get(`${base}/commits/main`))?.sha===head, 'head_changed_before_dispatch');
    const workflow=await get(workflowPath);
    check(Buffer.from(workflow?.content||'','base64').toString()===owned.get(workflowPath), 'workflow_changed_before_dispatch');
    state.dispatch_attempts=1; await record('dispatch_attempt');
    let dispatched;
    try { dispatched=await mutate('POST',`${base}/actions/workflows/${spec.workflow.split('/').at(-1)}/dispatches`,{ref:'main'},200); }
    catch (e) { state.dispatch_result_unknown=true; throw e; }
    check(Number.isSafeInteger(dispatched?.workflow_run_id) && dispatched.workflow_run_id>0, 'bad_dispatch_response');
    state.workflow_run_id=dispatched.workflow_run_id;
    state.workflow_run_url=`https://github.com/${TARGET}/actions/runs/${state.workflow_run_id}`;
    const deadline=now()+runTimeoutMs;
    while (now()<deadline) {
      const run=await get(`${base}/actions/runs/${state.workflow_run_id}`);
      check(run?.head_sha===head && run.path===spec.workflow && run.event==='workflow_dispatch' && run.display_title===spec.title, 'wrong_workflow_run');
      check(['queued','in_progress','completed','waiting','pending','requested'].includes(run.status) &&
        [null,'success','failure','cancelled','skipped','timed_out','action_required','neutral','stale','startup_failure'].includes(run.conclusion), 'bad_run_status');
      state.run_status=run.status; state.run_conclusion=run.conclusion; await record('observing_runner');
      if (run.status==='completed') { check(run.conclusion==='success', 'runner_failed'); state.runner_secret_verified=true; break; }
      await sleep(5000);
    }
    check(state.runner_secret_verified, 'runner_wait_timeout');
    state.functional_result='passed';
  } catch (error) {
    state.functional_result='not_passed';
    state.error_code=error instanceof ProbeError ? error.message : 'transport_or_parse_error';
  } finally {
    canary=undefined;
    await cleanup();
    await record(state.cleanup_verified?'finished_awaiting_revocation':'finished_cleanup_needs_attention');
  }
  return structuredClone(state);
}
