import test from 'node:test';
import assert from 'node:assert/strict';
import {CoachState} from './worker.mjs';
import {marketMovements} from './live-sources.mjs';
const at='2026-11-16T23:00:00Z',clock=Date.parse(at);
const storage=()=>{const values=new Map();const s={get:async k=>structuredClone(values.get(k)),put:async(k,v)=>{assert.ok(new TextEncoder().encode(JSON.stringify(v)).length<128000,'Each durable record must stay below its storage limit');values.set(k,structuredClone(v));},transaction:async f=>f(s)};return s;};
const call=(worker,path,body)=>worker.fetch(new Request('https://internal'+path,body?{method:'POST',body:JSON.stringify(body)}:{}));
test('slate market history exceeding one record is losslessly stored by event and creates no duplicate moves',async()=>{
 const events=Array.from({length:12},(_,i)=>({id:`nflverse:2026_11_T${i}_X${i}`,startsAt:'2026-11-17T02:00:00Z'}));
 const quotes=Array.from({length:591},(_,i)=>({selection:{eventId:events[i%12].id,market:'totals',participant:'',outcome:i%2?'Over':'Under',point:45.5},bookId:'book-'+i,book:'Book',provider:'the-odds-api',decimal:1.91,sourceAt:at,collectedAt:at,status:'open',demo:false}));
 const snapshot={props:{fetchedAt:at,quotes}},index={events,players:[]};
 const first=marketMovements(snapshot,index,[],clock);assert.ok(JSON.stringify(first.state).length>120000);
 const worker=new CoachState({storage:storage()},{});
 assert.equal((await call(worker,'/market-update',first.state)).status,200);
 const restored=await (await call(worker,'/market-state')).json();assert.equal(restored.length,591);assert.deepEqual(new Set(restored.map(r=>JSON.stringify(r))),new Set(first.state.map(r=>JSON.stringify(r))));
 assert.equal(marketMovements(snapshot,index,restored,clock+1000).observations.length,0);
});
test('larger normalized telemetry is stored in bounded chunks with original timestamps',async()=>{
 const worker=new CoachState({storage:storage()},{}),body={schemaVersion:1,checkedAt:at,sources:[],observations:Array.from({length:600},(_,i)=>({id:String(i),kind:'news',eventId:'nfl',observedAt:at,source:'Public source',value:{title:'x'.repeat(240)}}))};
 assert.ok(JSON.stringify(body).length>120000);
 assert.equal((await call(worker,'/update',body)).status,200);assert.deepEqual(await (await call(worker,'/telemetry')).json(),body);
 assert.equal((await call(worker,'/update',{...body,observations:[{value:{text:'x'.repeat(150000)}}]})).status,413);
 assert.equal((await (await call(worker,'/telemetry')).json()).checkedAt,at);
});
