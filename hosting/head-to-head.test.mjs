import test from 'node:test';
import assert from 'node:assert/strict';
import {benchmarkFacts,BENCHMARK_PROTOCOL} from './head-to-head.mjs';
import {gradeForecast,addGrade,evaluationReport,benchmarkTargets} from './forecast-evaluation.mjs';
import {evaluationState} from './evaluation-state.mjs';
const now=Date.UTC(2026,10,16,18),at=new Date(now).toISOString(),event={id:'g',home:'Home',away:'Away',startsAt:new Date(now+3600000).toISOString()};
const row={id:'one',selection:{eventId:'g',market:'h2h',outcome:'Home',point:null,participant:''},win:.6,push:0,baseline:.5,decimal:2};
const snapshot=()=>({id:'model:g:priced',modelVersion:'model',priced:true,event,capturedAt:at,rows:[structuredClone(row)],benchmarkState:'not_requested',benchmarkModel:'test-ai',benchmarkPromptVersion:BENCHMARK_PROTOCOL,benchmarkFacts:{targets:[]},benchmarkFactsHash:'a'.repeat(64)});
const state=()=>{const values=new Map();const storage={get:async k=>structuredClone(values.get(k)),put:async(k,v)=>values.set(k,structuredClone(v)),transaction:async f=>f(storage)};return {storage};};
const call=(s,path,body,t=now)=>evaluationState(s,path,new Request('https://internal'+path,{method:'POST',body:JSON.stringify(body)}),t);
test('AI context strips Coach forecasts and future records but retains exact observed prices',()=>{
 const facts=benchmarkFacts({event:{...event,forecast:{win:.99},prediction:99},createdAt:at,contextFacts:null,frozenRows:[row]}, {cutoff:'2026-11-15',results:[{date:'2026-11-17',home:'Home',homeScore:999}],players:[{name:'Home',team:'H',games:[]}]},[row]);
 assert.equal(facts.event.forecast,undefined);assert.equal(facts.event.prediction,undefined);assert.equal(facts.recentGames.length,0);assert.equal(facts.savedPrices[0].decimal,2);assert.equal(facts.savedPrices[0].win,undefined);
});
test('neutral benchmark targets ignore row EV and probability ordering',()=>{
 const a=snapshot();a.rows.push({...row,id:'two',selection:{...row.selection,outcome:'Away'},win:.9});
 const before=benchmarkTargets(a).map(r=>r.id);a.rows.reverse();a.rows[0].win=.01;
 assert.deepEqual(benchmarkTargets(a).map(r=>r.id),before);
});
test('strict three-way comparison excludes legacy, late and unmatched baseline observations',()=>{
 const s=snapshot();s.benchmark=[{id:'one',win:.4,push:0}];s.benchmarkCompletedAt=new Date(now+1000).toISOString();
 const result={eventId:'g',homeScore:20,awayScore:10};
 const grade=gradeForecast(s,result),aggregate=addGrade({},grade),report=evaluationReport(aggregate,{}).markets[0].headToHead;
 assert.equal(report.games,1);assert.equal(report.observations,1);assert.ok(Math.abs(report.coachBrier-.16)<1e-12);assert.ok(Math.abs(report.aiBrier-.36)<1e-12);assert.equal(report.marketBrier,.25);assert.equal(report.superiorityDemonstrated,false);
 for(const changed of [{benchmarkPromptVersion:'generic-source-context-v2'},{benchmarkCompletedAt:event.startsAt},{benchmarkFactsHash:null}])assert.equal(gradeForecast({...s,...changed},result).markets.h2h.headPairs,0);
 const noMarket=structuredClone(s);noMarket.rows[0].baseline=null;assert.equal(gradeForecast(noMarket,result).markets.h2h.headPairs,0);
 addGrade(aggregate,grade,-1);assert.equal(evaluationReport(aggregate,{}).markets[0].headToHead.games,0);
});
test('benchmark deadline, quota deferral and automatic daily cap are enforced atomically',async()=>{
 const s=state(),a=snapshot();await call(s,'/forecast-capture',a);
 assert.equal((await (await call(s,'/benchmark-auto-reserve',{id:a.id,limit:200})).json()).reserved,true);
 assert.equal((await (await call(s,'/benchmark-auto-reserve',{id:a.id,limit:200})).json()).reserved,false);
 await call(s,'/benchmark-reserve',{id:a.id});await call(s,'/benchmark-save',{id:a.id,result:null,reason:'quota_deferred'});
 assert.equal((await (await call(s,'/benchmark-reserve',{id:a.id})).json()).reserved,true);
 await call(s,'/benchmark-save',{id:a.id,result:{probabilities:[{key:0,win:.5,push:0}]}},now+3600000);
 const stored=await s.storage.get('forecast:'+a.id);assert.equal(stored.benchmarkState,'late');assert.equal(stored.benchmark,undefined);
 for(let i=2;i<=3;i++){const b={...snapshot(),id:`model:g${i}:priced`,event:{...event,id:'g'+i}};await call(s,'/forecast-capture',b);const r=await (await call(s,'/benchmark-auto-reserve',{id:b.id,limit:200})).json();assert.equal(r.reserved,i===2);}
 const report=await (await evaluationState(s,'/evaluation',new Request('https://internal/evaluation'),now)).json();assert.equal(report.benchmarkCoverage.fair_late,1);
});

test('different AI model versions are not pooled into a superiority score',()=>{
 const a=snapshot();a.benchmark=[{id:'one',win:.4,push:0}];a.benchmarkCompletedAt=new Date(now+1000).toISOString();
 const b={...structuredClone(a),benchmarkModel:'other-ai'};
 const result={eventId:'g',homeScore:20,awayScore:10},aggregate=addGrade({},gradeForecast(a,result));addGrade(aggregate,gradeForecast(b,result));
 const report=evaluationReport(aggregate,{}).markets[0].headToHead;assert.equal(report.status,'mixed_models_not_comparable');assert.equal(report.aiBrier,null);assert.equal(report.models.length,2);
});

test('provider daily-limit deferral waits for reset without burning another automatic reservation',async()=>{
 const s=state(),a=snapshot();await call(s,'/forecast-capture',a);await call(s,'/benchmark-reserve',{id:a.id});
 await call(s,'/benchmark-save',{id:a.id,result:null,reason:'provider_daily_limit'});
 assert.equal((await s.storage.get('forecast:'+a.id)).benchmarkState,'waiting_for_quota');
 await s.storage.put('ai-provider-status',{blockedUntil:new Date(now+60000).toISOString()});
 assert.equal((await (await call(s,'/benchmark-auto-reserve',{id:a.id,limit:2})).json()).reserved,false);assert.equal(await s.storage.get('automatic-benchmark-budget'),undefined);
 assert.equal((await (await call(s,'/benchmark-auto-reserve',{id:a.id,limit:2},now+61000)).json()).reserved,true);
});
