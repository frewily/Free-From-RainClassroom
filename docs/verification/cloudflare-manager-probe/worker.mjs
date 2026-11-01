export const BUILD='rain-s0-cf-deploy-20261028-v1';
const reply=(value,status=200)=>new Response(JSON.stringify(value),{status,headers:{'Content-Type':'application/json','Cache-Control':'no-store'}});
export default {
  async fetch(request,env) {
    const url=new URL(request.url);
    if(request.method==='GET'&&url.pathname==='/health')return reply({build:BUILD});
    if(request.method!=='POST'||url.pathname!=='/probe')return reply({error:'not_found'},404);
    if(!env.PROBE_KEY||request.headers.get('Authorization')!=='Bearer '+env.PROBE_KEY)return reply({error:'unauthorized'},401);
    if(Number(request.headers.get('Content-Length'))>2048)return reply({error:'too_large'},413);
    try {
      const raw=await request.text();if(raw.length>2048)return reply({error:'too_large'},413);
      const value=JSON.parse(raw);
      if(Object.keys(value).sort().join(',')!=='expected_sha256,nonce'||!/^[a-f0-9]{12}$/.test(value.nonce)||!/^[a-f0-9]{64}$/.test(value.expected_sha256))return reply({error:'invalid_input'},400);
      const kv=await env.PROBE_KV.get(value.nonce);
      const row=await env.PROBE_DB.prepare('SELECT value FROM s0_probe WHERE id = ?').bind(value.nonce).first();
      const digest=async text=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(text)))).map(b=>b.toString(16).padStart(2,'0')).join('');
      return reply({build:BUILD,nonce:value.nonce,kv_matches:typeof kv==='string'&&await digest(kv)===value.expected_sha256,d1_matches:typeof row?.value==='string'&&await digest(row.value)===value.expected_sha256});
    } catch { return reply({error:'binding_probe_failed'},502); }
  }
};
