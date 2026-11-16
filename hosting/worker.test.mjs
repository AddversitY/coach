import test from 'node:test';
import assert from 'node:assert/strict';
import worker,{CoachState,normalizeInjuries,validatePlan,retrieve,parseModel,boundedJson} from './worker.mjs';

const time=Date.now(),at=new Date(time).toISOString();
const event={id:'e',home:'Buffalo Bills',away:'Kansas City Chiefs',startsAt:new Date(time+3600000).toISOString()};
const player={id:'p',name:'Recorded Player',team:'BUF',events:['e'],position:'QB',games:[]};
const source={index:{events:[event],players:[player],cutoff:at.slice(0,10)},snapshot:{props:{quotes:[]}}};

test('planner cannot invent players, lines, odds or flip sides',()=>{
  assert.throws(()=>validatePlan({tool:'joint_probability',query:'Recorded Player over 250.5 passing yards'},'Recorded Player over 245.5 passing yards',source.index),/number/);
  assert.throws(()=>validatePlan({tool:'joint_probability',query:'Recorded Player under 245.5 passing yards'},'Recorded Player over 245.5 passing yards',source.index),/side/);
  assert.throws(()=>validatePlan({tool:'run_code',query:'anything'},'anything',source.index));
  assert.deepEqual(validatePlan({tool:'stress_test',query:'stress it'},'stress it',source.index),{tool:'clarify',query:'stress it'});
});
test('injury facts require exact name and club, remain unofficial, and never fabricate scratches',()=>{
  const raw={injuries:[{team:{abbreviation:'BUF'},injuries:[{status:'Out',athlete:{displayName:'Recorded Player'}}]}]};
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
