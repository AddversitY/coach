import test from 'node:test';
import {deterministicGameRoute} from './worker.mjs';
import assert from 'node:assert/strict';
import worker,{CoachState,normalizeInjuries,validatePlan,retrieve,parseModel,boundedJson,published,resetSourceCacheForTests} from './worker.mjs';

const time=Date.now(),at=new Date(time).toISOString();
const event={id:'e',home:'Buffalo Bills',away:'Kansas City Chiefs',startsAt:new Date(time+3600000).toISOString()};
const player={id:'p',name:'Recorded Player',team:'BUF',events:['e'],position:'QB',games:[]};
const source={index:{events:[event],players:[player],cutoff:at.slice(0,10)},snapshot:{props:{quotes:[]}}};
test('team-only prompts select visual game research without inference or stealing specialized questions',()=>{
 for(const q of ['Bills','Buffalo Bills','Tell me about the Bills'])assert.equal(deterministicGameRoute(q,source.index),true);
 for(const q of ['Bills injuries','Bills weather','Unknown Team'])assert.equal(deterministicGameRoute(q,source.index),false);
});

test('missing subjects, missing player markets and unsupported scopes clarify before any quota or inference call',async()=>{
 const original=globalThis.fetch;let calls=0;
 try{
  resetSourceCacheForTests();
  globalThis.fetch=async url=>Response.json(String(url).includes('coach-index.json')?{...source.index,schemaVersion:1,retrievedAt:at}:{schemaVersion:1});
  const env={AI:{run:async()=>{calls++;throw Error('No inference expected');}}};
  for(const question of ['Lakers total over 221.5','Recorded Player under 245.5','Bills first-half spread -3.5']){
   const response=await worker.fetch(new Request('https://coach.test/v1/plan',{method:'POST',headers:{Origin:'https://addversity.github.io','Content-Type':'application/json'},body:JSON.stringify({question,context:{eventId:event.id}})}),env);
   assert.equal(response.status,200);const result=await response.json();assert.equal(result.tool,'clarify');assert.equal(result.query,question);
  }
  assert.equal(calls,0);
  const scoped=await worker.fetch(new Request('https://coach.test/v1/coach',{method:'POST',headers:{Origin:'https://addversity.github.io','Content-Type':'application/json'},body:JSON.stringify({question:'Bills first-half spread -3.5'})}),env);
  assert.equal(scoped.status,200);assert.equal((await scoped.json()).failureReason,'unsupported_scope');assert.equal(calls,0);
 }finally{globalThis.fetch=original;resetSourceCacheForTests();}
});

test('planner cannot invent players, lines, odds or flip sides',()=>{
  assert.throws(()=>validatePlan({tool:'joint_probability',query:'Recorded Player over 250.5 passing yards'},'Recorded Player over 245.5 passing yards',source.index),/number/);
  assert.throws(()=>validatePlan({tool:'joint_probability',query:'Recorded Player under 245.5 passing yards'},'Recorded Player over 245.5 passing yards',source.index),/side/);
  assert.throws(()=>validatePlan({tool:'run_code',query:'anything'},'anything',source.index));
  assert.deepEqual(validatePlan({tool:'stress_test',query:'stress it'},'stress it',source.index),{tool:'clarify',query:'stress it'});
});
test('injury facts require exact name and club, remain unofficial, and never fabricate scratches',()=>{
  const raw={injuries:[{team:{abbreviation:'BUF'},injuries:[{status:'Out',date:at,athlete:{displayName:'Recorded Player'}}]}]};
  const result=normalizeInjuries(raw,source.index,at);assert.equal(result.length,1);assert.equal(result[0].confirmed,false);
  raw.injuries[0].team.abbreviation='KC';assert.equal(normalizeInjuries(raw,source.index,at).length,0);
});
test('retrieval ignores fake client facts and exposes missing availability',()=>{
  const result=retrieve('Recorded Player',{playerId:'p'},source,null,time);
  assert.equal(result.player_evidence[0].id,'p');assert.equal(result.team_evidence[0].sources[0].state,'unavailable');
  assert.match(result.team_evidence[0].priceNotice,/not guaranteed current/);
});
test('bounded request reader cancels excessive bodies and JSON parser rejects prose',async()=>{
  await assert.rejects(boundedJson(new Response('x'.repeat(33000)),32000),/large/);
  assert.throws(()=>parseModel({response:'Pretend odds are +999'}));
});
test('durable quota reservations enforce account and per-IP limits atomically',async()=>{
  const values=new Map();let queue=Promise.resolve();
  const storage={get:async k=>structuredClone(values.get(k)),put:async(k,v)=>{values.set(k,structuredClone(v));},
    transaction(fn){const next=queue.then(()=>fn(storage));queue=next.catch(()=>{});return next;}};
  const state=new CoachState({storage},{MAX_MODEL_CALLS_PER_DAY:'3',MAX_MODEL_CALLS_PER_IP_HOUR:'2'});
  const reserve=ip=>state.fetch(new Request('https://internal/reserve',{method:'POST',body:JSON.stringify({ip,now:time})}));
  const same=await Promise.all([reserve('one'),reserve('one'),reserve('one')]);assert.deepEqual(same.map(r=>r.status),[200,200,429]);
  assert.equal((await reserve('two')).status,200);assert.equal((await reserve('three')).status,429);
});
test('calculated game analysis has its own per-connection and daily caps',async()=>{
  const values=new Map();let queue=Promise.resolve();
  const storage={get:async k=>structuredClone(values.get(k)),put:async(k,v)=>{values.set(k,structuredClone(v));},
    transaction(fn){const next=queue.then(()=>fn(storage));queue=next.catch(()=>{});return next;}};
  const state=new CoachState({storage},{MAX_ANALYSES_PER_DAY:'3',MAX_ANALYSES_PER_IP_HOUR:'2'});
  const reserve=ip=>state.fetch(new Request('https://internal/analysis-reserve',{method:'POST',body:JSON.stringify({ip,now:time})}));
  const same=await Promise.all([reserve('one'),reserve('one'),reserve('one')]);assert.deepEqual(same.map(r=>r.status),[200,200,429]);
  assert.equal((await reserve('two')).status,200);assert.equal((await reserve('three')).status,429);
  // The AI quota ledger is separate and untouched.
  assert.equal(values.get('quota'),undefined);
});
test('public model routes reject other origins before inference and do not expose secrets',async()=>{
  let calls=0;
  const result=await worker.fetch(new Request('https://coach.example/v1/coach',{method:'POST',headers:{Origin:'https://evil.example'},body:JSON.stringify({question:'test'})}),{AI:{run(){calls++;}},ALLOWED_ORIGIN:'https://addversity.github.io'});
  assert.equal(result.status,403);assert.equal(calls,0);
  const health=await worker.fetch(new Request('https://coach.example/health'),{AI:{},STATE:{},SOME_SECRET:'never-show'});
  assert.ok(!(await health.text()).includes('never-show'));
});

test('retrieval excludes fixture, future, inconsistent and stale observations',()=>{
  const quote={selection:{eventId:'e',participant:player.name},status:'open',demo:false,sourceAt:at,collectedAt:at};
  const current={...source,snapshot:{odds:{coverage:{players:[{name:player.name,playerId:'p'}]}},props:{fetchedAt:at,quotes:[quote]}}};
  const prices=s=>retrieve(player.name,{},s,null,time).team_evidence[0].savedPrices;
  assert.equal(prices(current).length,1);
  for(const changed of [
    {...current.snapshot,odds:{...current.snapshot.odds,testFixture:true}},
    {...current.snapshot,props:{...current.snapshot.props,fetchedAt:new Date(time+60000).toISOString()}},
    {...current.snapshot,props:{...current.snapshot.props,quotes:[{...quote,collectedAt:new Date(time-60000).toISOString()}]}},
    {...current.snapshot,props:{...current.snapshot.props,quotes:[{...quote,sourceAt:new Date(time-19*3600000).toISOString()}]}},
  ])assert.equal(prices({...current,snapshot:changed}).length,0);
});

test('interpretation receives only prices from the current requested book set',()=>{
 const quote={selection:{eventId:'e',participant:player.name},status:'open',demo:false,sourceAt:at,collectedAt:at};
 const data={...source,snapshot:{odds:{coverage:{players:[{name:player.name,playerId:'p'}]}},props:{fetchedAt:at,quotes:['draftkings','fanduel','betmgm'].map(bookId=>({...quote,bookId}))}}};
 const rows=retrieve(player.name,{bookIds:['draftkings','fanduel']},data,null,time).team_evidence[0].savedPrices;
 assert.deepEqual(rows.map(r=>r.bookId),['draftkings','fanduel']);
 assert.equal(retrieve(player.name+' all books',{bookIds:['betmgm']},data,null,time).team_evidence[0].savedPrices.length,3);
});

test('Workers AI JSON mode accepts bounded parsed objects as well as JSON text',()=>{
  const answer={answer:'Recorded evidence only',cited:['team_evidence']};
  assert.deepEqual(parseModel({response:answer}),answer);
  assert.deepEqual(parseModel({response:JSON.stringify(answer)}),answer);
  assert.throws(()=>parseModel({response:{answer:'x'.repeat(8001)}}));
  assert.throws(()=>parseModel({response:[]}));
});

test('source fetch uses Workers-compatible manual redirects and rejects redirected evidence',async()=>{
  const original=globalThis.fetch;
  resetSourceCacheForTests();
  try{
    globalThis.fetch=async(url,init)=>{
      assert.equal(init.redirect,'manual');
      const value=String(url).endsWith('coach-index.json')?{schemaVersion:1,players:[],events:[],cutoff:at.slice(0,10),retrievedAt:at}:{schemaVersion:1};
      return Response.json(value);
    };
    const result=await published({},time);assert.equal(result.index.schemaVersion,1);
    resetSourceCacheForTests();
    globalThis.fetch=async()=>new Response('',{status:302,headers:{Location:'https://unapproved.example/'}});
    await assert.rejects(published({},time),/Source unavailable/);
  }finally{globalThis.fetch=original;resetSourceCacheForTests();}
});

test('a growing research index remains readable while oversized sources fail closed',async()=>{
 const original=globalThis.fetch;
 const index={schemaVersion:1,players:[],events:[],cutoff:at.slice(0,10),retrievedAt:at,researchNotes:'x'.repeat(2_050_000)};
 try{
  globalThis.fetch=async url=>Response.json(String(url).endsWith('coach-index.json')?index:{schemaVersion:1});
  resetSourceCacheForTests();assert.equal((await published({},time)).index.researchNotes.length,2_050_000);
  index.researchNotes='x'.repeat(3_000_000);resetSourceCacheForTests();
  await assert.rejects(published({},time));
 }finally{globalThis.fetch=original;resetSourceCacheForTests();}
});

test('market ingestion requires its own credential before any source access',async()=>{
  const original=globalThis.fetch;let network=0;
  try{
    globalThis.fetch=async()=>{network++;throw Error('should not fetch');};
    const response=await worker.fetch(new Request('https://coach.example/v1/ingest',{method:'POST',headers:{Authorization:'Bearer news-only'},body:JSON.stringify({kind:'market_splits'})}),{INGEST_SECRET:'news-only',MARKET_INGEST_SECRET:'market-only'});
    assert.equal(response.status,401);assert.equal(network,0);
  }finally{globalThis.fetch=original;}
});

test('news retrieval excludes unrelated injury, weather and price evidence',()=>{
  const telemetry={checkedAt:at,sources:[{id:'beat_writers',state:'attributed_headlines'},{id:'injuries',state:'reported_unofficial'}],observations:[
    {id:'news',kind:'news',eventId:'e',observedAt:at,value:{title:'Recorded Player report',url:'https://www.espn.com/nfl/report'}},
    {id:'injury',kind:'injury',eventId:'e',playerId:'p',observedAt:at,value:{status:'Out'}}
  ]};
  const result=retrieve('Recorded Player news',{},source,telemetry,time).team_evidence[0];
  assert.deepEqual(result.telemetry.map(row=>row.id),['news']);assert.equal(result.savedPrices,undefined);
  assert.deepEqual(result.sources.map(row=>row.id),['beat_writers']);
  assert.deepEqual(parseModel({choices:[{message:{content:'{"answer":"Scoped report","cited":["team_evidence"]}'}}]}),{answer:'Scoped report',cited:['team_evidence']});
});

test('logged-out book prices require the ingest secret and drop extra fields', async () => {
  const values = new Map();
  const storage = {get: async key => values.get(key) ?? null, put: async (key, value) => {values.set(key, structuredClone(value));}};
  const env = {
    BOOK_PROPS_INGEST_SECRET: 'ingest-secret',
    ALLOWED_ORIGIN: 'https://addversity.github.io',
    STATE: {idFromName(){return 'id';}, get(){return new CoachState({storage}, env);}},
  };
  const missing = await worker.fetch(new Request('https://coach.example/v1/book-prices'), env);
  assert.equal((await missing.json()).prices, 'unavailable');
  const denied = await worker.fetch(new Request('https://coach.example/v1/book-prices', {method:'POST', body:'{}'}), env);
  assert.equal(denied.status, 401);
  const row = {book:'bovada', eventId:'nflverse:2026_12_IND_HOU', market:'player_pass_yds', outcome:'Over', at:'2026-11-21T22:00:00Z', decimal:1.91, line:242.5, player:'C.J. Stroud', playerId:'00-0039163', apiKey:'ingest-secret'};
  const accepted = await worker.fetch(new Request('https://coach.example/v1/book-prices', {method:'POST', headers:{authorization:'Bearer ingest-secret', 'content-type':'application/json'}, body:JSON.stringify({observations:[row]})}), env);
  assert.equal(accepted.status, 200);
  const saved = await (await worker.fetch(new Request('https://coach.example/v1/book-prices'), env)).json();
  assert.equal(saved.observations.length, 1);
  assert.equal(saved.observations[0].playerId, '00-0039163');
  assert.equal(Object.hasOwn(saved.observations[0], 'apiKey'), false);
  assert.equal(JSON.stringify(saved).includes('ingest-secret'), false);
  const invented = await worker.fetch(new Request('https://coach.example/v1/book-prices', {method:'POST', headers:{authorization:'Bearer ingest-secret'}, body:JSON.stringify({observations:[{...row, decimal:1}]})}), env);
  assert.equal(invented.status, 400);
});
