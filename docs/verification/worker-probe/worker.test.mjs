import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {makeHandler} from './worker-runtime.mjs';
import {safeSummary,checkedWorkerURL,workerCurlSpec} from './controller.mjs';

const KEY='synthetic-test-gate-key-'.repeat(3);
const INPUT={nonce:'0123456789abcdef01234567',initial_access_token:'synthetic-initial-access',refresh_token:'synthetic-initial-refresh'};
const TARGET='frewily/rain-client-s0-target-20261027';
const FIXTURE=await readFile(new URL('../fixtures/s0-dispatch-probe.yml',import.meta.url));
const req=(body=INPUT,key=KEY)=>new Request('https://probe.example/probe',{method:'POST',headers:{Authorization:'Bearer '+key,'Content-Type':'application/json'},body:JSON.stringify(body)});
function github(overrides={}){
  const calls=[];let rotated=false;
  const fetcher=async(url,options={})=>{
    const u=new URL(url);calls.push({url,options});
    const response=(b,s=200)=>new Response(JSON.stringify(b),{status:s});
    assert(['github.com','api.github.com','raw.githubusercontent.com'].includes(u.hostname));
    if(overrides.allowRedirectModes)assert([undefined,'error','manual'].includes(options.redirect));else assert.equal(options.redirect,'manual');
    if(u.hostname==='raw.githubusercontent.com'){assert.equal(options.headers.Authorization,undefined);return new Response(overrides.badFixture?'wrong':FIXTURE);}
    if(u.hostname==='github.com'){
      assert.equal(u.pathname,'/login/oauth/access_token');const form=new URLSearchParams(options.body);
      assert.equal(form.get('client_id'),'Iv23li2VecQYTHgNvvHE');assert.equal(form.get('refresh_token'),INPUT.refresh_token);assert.equal(form.has('client_secret'),false);
      if(overrides.refreshRedirect)return new Response(null,{status:302,headers:{Location:'https://outside.example/receive'}});
      if(overrides.refreshFailure)return response({error:'bad_refresh_token',message:'PRIVATE_RESPONSE_MUST_NOT_LEAK'},400);
      rotated=true;return response({access_token:'synthetic-renewed-access',refresh_token:'synthetic-renewed-refresh'});
    }
    assert.equal(options.headers['X-GitHub-Api-Version'],'2026-03-10');
    if(u.pathname.endsWith('/contents/.github/workflows/s0-probe.yml'))return overrides.publicApiRateLimited?response({message:'API rate limit exceeded'},403):response({encoding:'base64',content:Buffer.from(overrides.badFixture?'wrong':FIXTURE).toString('base64')});
    if(u.pathname.endsWith('/commits/main'))return response({sha:'643a01c40f6ceb4b953036dfc5dcc1f8541193ac'});
    if(u.pathname==='/user'){
      if(options.headers.Authorization==='Bearer '+INPUT.initial_access_token&&rotated&&!overrides.oldStillValid)return response({message:'Bad credentials'},401);
      return response({login:overrides.wrongIdentity?'someone-else':'frewily',id:42});
    }
    if(u.pathname==='/user/installations')return response({installations:[{id:123,app_id:5489930,account:{login:'frewily'},repository_selection:overrides.allRepositories?'all':'selected',permissions:{actions:'write',metadata:'read',...(overrides.extraPermission?{contents:'write'}:{})}}]});
    if(u.pathname==='/user/installations/123/repositories')return response({total_count:1,repositories:[{full_name:overrides.wrongRepository?'frewily/some-other-repo':TARGET}]});
    if(u.pathname.endsWith('/dispatches')){
      assert.equal(u.pathname,`/repos/${TARGET}/actions/workflows/s0-probe.yml/dispatches`);
      assert.equal(options.method,'POST');assert.deepEqual(JSON.parse(options.body),{ref:'main',inputs:{probe_nonce:INPUT.nonce}});
      if(overrides.lostDispatchResponse)throw new Error('PRIVATE_TRANSPORT_DETAIL');
      return response({workflow_run_id:12345});
    }
    throw Error('Unexpected request: '+url);
  };
  return {calls,fetcher,dispatches:()=>calls.filter(c=>c.url.endsWith('/dispatches'))};
}

test('unauthorized calls never read a body or send GitHub requests',async()=>{
  const g=github();const r=await makeHandler(g.fetcher)(req(INPUT,'wrong-key'),{PROBE_KEY:KEY});assert.equal(r.status,401);assert.equal(g.calls.length,0);
});
test('a missing gate key and unsupported methods cannot execute the probe',async()=>{
  const g=github();const h=makeHandler(g.fetcher);assert.equal((await h(req(),{})).status,401);assert.equal((await h(new Request('https://probe.example/probe'),{PROBE_KEY:KEY})).status,405);assert.equal(g.calls.length,0);
});
test('readiness checks validate the gate without requesting GitHub',async()=>{
  const g=github();const h=makeHandler(g.fetcher);const r=await h(new Request('https://probe.example/ready',{headers:{Authorization:'Bearer '+KEY}}),{PROBE_KEY:KEY});assert.equal(r.status,200);assert.equal((await r.json()).ready,true);assert.equal((await h(new Request('https://probe.example/ready'),{PROBE_KEY:KEY})).status,401);assert.equal(g.calls.length,0);
});
test('the controller only accepts the named test Worker HTTPS origin',()=>{
  assert.equal(checkedWorkerURL('https://rain-client-s0-worker-20261027.synthetic.workers.dev/'),'https://rain-client-s0-worker-20261027.synthetic.workers.dev');
  for(const u of ['https://rainclassroom-scheduler.synthetic.workers.dev/','http://rain-client-s0-worker-20261027.synthetic.workers.dev/','https://rain-client-s0-worker-20261027.synthetic.workers.dev/?token=private','https://private@rain-client-s0-worker-20261027.synthetic.workers.dev/'])assert.throws(()=>checkedWorkerURL(u));
});
test('saved summaries omit credentials, raw error messages and unknown response fields',()=>{
  const summary=safeSummary({build:'rain-s0-worker-github-20261027-v3',nonce:INPUT.nonce,refresh_http_status:200,credentials:{access_token:'PRIVATE_TOKEN'},access_token:'PRIVATE_TOKEN',message:'PRIVATE_MESSAGE',error_code:'PRIVATE_MESSAGE',workflow_run_url:'https://elsewhere.example/PRIVATE_TOKEN'});
  assert.equal(summary.refresh_http_status,200);assert.equal(summary.error_code,'unrecognized_error');assert(!JSON.stringify(summary).includes('PRIVATE_'));assert.equal(Object.hasOwn(summary,'credentials'),false);
});
test('proxy transport keeps credentials in its private stdin and does not follow or retry redirects',()=>{
  const s=workerCurlSpec('https://rain-client-s0-worker-20261027.synthetic.workers.dev/probe',{method:'POST',headers:{Authorization:'Bearer SYNTHETIC_PRIVATE_GATE'},body:JSON.stringify({refresh_token:'SYNTHETIC_PRIVATE_REFRESH'})},'http://127.0.0.1:7897');
  assert(!JSON.stringify(s.args).includes('SYNTHETIC_PRIVATE'));assert(s.config.includes('SYNTHETIC_PRIVATE_GATE'));assert(s.config.includes('SYNTHETIC_PRIVATE_REFRESH'));assert(!s.args.includes('--location'));assert(!s.args.includes('--retry'));
});
test('body cannot override the repository or carry an oversized payload',async()=>{
  const g=github();const h=makeHandler(g.fetcher);assert.equal((await h(req({...INPUT,repository:'frewily/production'}),{PROBE_KEY:KEY})).status,400);assert.equal((await h(req({...INPUT,refresh_token:'x'.repeat(20000)}),{PROBE_KEY:KEY})).status,400);assert.equal(g.calls.length,0);
});
for(const [name,overrides]of [['fixture changed',{badFixture:true}],['identity differs',{wrongIdentity:true}],['all repositories selected',{allRepositories:true}],['unapproved code permission',{extraPermission:true}],['another repository selected',{wrongRepository:true}],['refresh rejected',{refreshFailure:true}],['old access token still works',{oldStillValid:true}]]){
  test(name+' prevents dispatch',async()=>{const g=github(overrides);const r=await makeHandler(g.fetcher)(req(),{PROBE_KEY:KEY});assert.equal(r.status,502);const b=await r.json();assert.equal(b.ok,false);assert.equal(g.dispatches().length,0);assert(!JSON.stringify(b).includes('PRIVATE_RESPONSE_MUST_NOT_LEAK'));});
}
test('refresh and current API-version dispatch succeed once; only the authenticated caller receives the new pair',async()=>{
  const g=github();const r=await makeHandler(g.fetcher)(req(),{PROBE_KEY:KEY});assert.equal(r.status,200);assert.match(r.headers.get('Cache-Control'),/no-store/);assert.equal(r.headers.has('Access-Control-Allow-Origin'),false);
  const b=await r.json();assert.equal(b.ok,true);assert.equal(b.summary.refresh_http_status,200);assert.equal(b.summary.old_access_http_status,401);assert.equal(b.summary.dispatch_http_status,200);assert.equal(b.summary.selected_repository_verified,true);assert.equal(b.summary.workflow_run_id,12345);assert.equal(g.dispatches().length,1);assert.deepEqual(b.credentials,{access_token:'synthetic-renewed-access',refresh_token:'synthetic-renewed-refresh'});assert(!JSON.stringify(b.summary).includes('synthetic-'));
});
test('lost dispatch responses are marked unknown and never retried',async()=>{
  const g=github({lostDispatchResponse:true});const r=await makeHandler(g.fetcher)(req(),{PROBE_KEY:KEY});const b=await r.json();assert.equal(r.status,502);assert.equal(b.summary.dispatch_acceptance_unknown,true);assert.equal(g.dispatches().length,1);assert.equal(b.summary.error_code,'transport_or_parse_error');assert(!JSON.stringify(b).includes('PRIVATE_TRANSPORT_DETAIL'));
});
test('the request helper uses redirect settings supported by Workers',async()=>{
  const g=github();
  function edgeFetch(url,options){if(options.redirect==='error')throw new TypeError('Invalid redirect value');return g.fetcher(url,options);}
  const r=await makeHandler(edgeFetch)(req(),{PROBE_KEY:KEY});assert.equal(r.status,200);assert.equal((await r.json()).ok,true);
});
test('transport diagnostics expose the unsupported redirect mode without credentials or dispatch',async()=>{
  const g=github({allowRedirectModes:true});
  function edgeFetch(url,options){if(options.redirect==='error')throw new TypeError('Invalid redirect value, must be follow or manual');return g.fetcher(url,options);}
  const h=makeHandler(edgeFetch);
  const unauthorized=await h(new Request('https://probe.example/transport-diagnostic'),{PROBE_KEY:KEY});assert.equal(unauthorized.status,401);assert.equal(g.calls.length,0);
  const r=await h(new Request('https://probe.example/transport-diagnostic',{headers:{Authorization:'Bearer '+KEY}}),{PROBE_KEY:KEY});const b=await r.json();assert.equal(b.github_credentials_used,false);assert.equal(b.dispatch_attempted,false);assert.equal(b.cases.find(x=>x.mode==='original_unbound').error_name,'TypeError');assert.equal(b.cases.find(x=>x.mode==='native_defaults_bound').http_status,200);assert.equal(b.cases.find(x=>x.mode==='manual_abort_controller').fixture_hash_matches,true);assert.equal(g.dispatches().length,0);assert(g.calls.every(x=>!x.options.headers.Authorization));
});
test('credential refresh redirects are rejected without following them or dispatching',async()=>{
  const g=github({refreshRedirect:true});const r=await makeHandler(g.fetcher)(req(),{PROBE_KEY:KEY});const b=await r.json();assert.equal(r.status,502);assert.equal(b.summary.error_code,'unexpected_redirect');assert.equal(g.dispatches().length,0);assert(g.calls.every(x=>new URL(x.url).hostname!=='outside.example'));
});
test('raw source diagnostics identify anonymous API limits without GitHub credentials',async()=>{
  const g=github({publicApiRateLimited:true});const r=await makeHandler(g.fetcher)(new Request('https://probe.example/source-diagnostic',{headers:{Authorization:'Bearer '+KEY}}),{PROBE_KEY:KEY});const b=await r.json();assert.equal(b.raw_http_status,200);assert.equal(b.raw_fixture_hash_matches,true);assert.equal(b.public_api_http_status,403);assert.equal(b.public_api_rate_limited,true);assert.equal(b.dispatch_attempted,false);assert(g.calls.every(x=>!x.options.headers.Authorization));
});
