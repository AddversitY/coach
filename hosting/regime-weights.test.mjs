import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {regimeWeights} from './regime-weights.mjs';
import {aiFailure} from './ai-diagnostics.mjs';
import {CoachState,deterministicGameRoute} from './worker.mjs';
const fixtures=JSON.parse(readFileSync(new URL('./fixtures/regime-parity.json',import.meta.url),'utf8'));
test('conditional replay weights match Python and preserve a coherent distribution',()=>{
 for(const row of fixtures){const actual=regimeWeights(row.contexts,row.means);assert.ok(Math.abs(actual.reduce((a,b)=>a+b,0)-1)<1e-12);for(let i=0;i<actual.length;i++)assert.ok(Math.abs(actual[i]-row.weights[i])<1e-12);}
 assert.equal(regimeWeights([[40,3]],[23,17]),null);
});
test('AI daily-limit classification is safe and deterministic routes do not need inference',()=>{
 assert.equal(aiFailure(new Error('3036 daily free allocation exhausted')),'provider_daily_limit');assert.equal(aiFailure(new Error('3040 capacity exceeded')),'provider_capacity');
 const now=Date.now(),index={events:[{id:'g',home:'Buffalo Bills',away:'Miami Dolphins',startsAt:new Date(now+3600000).toISOString()}],players:[]};
 assert.equal(deterministicGameRoute('Analyze Bills spread',index,{}),true);assert.equal(deterministicGameRoute('Bills injury news',index,{}),false);assert.equal(deterministicGameRoute('Analyze an unknown club',index,{}),false);
});
test('provider cooldown blocks reservations without spending pilot quota',async()=>{
 const values=new Map([['ai-provider-status',{blockedUntil:new Date(Date.now()+3600000).toISOString(),reason:'provider_daily_limit'}]]);
 const store={get:async k=>values.get(k),put:async(k,v)=>values.set(k,v),transaction:async f=>f(store)};
 const worker=new CoachState({storage:store},{});
 const response=await worker.fetch(new Request('https://internal/reserve',{method:'POST',body:JSON.stringify({ip:'test',now:Date.now()})}));
 assert.equal(response.status,429);assert.equal(values.has('quota'),false);
});
import {regimeShadowGame} from './shadow-forecast.mjs';
import {analyzeGame} from './game-analysis.mjs';
test('the scoring-regime cohort is independent and cannot change the serving source',()=>{
 const now=Date.UTC(2026,10,16,12),at=new Date(now).toISOString();
 const teams=['BUF','KC',...Array.from({length:30},(_,i)=>'T'+i)];
 const residuals=Array.from({length:150},(_,i)=>[i%21-10,i%17-8]);
 const base={version:'base',schemaVersion:1,cutoff:'2026-11-12',trainedAt:at,teams,coefficients:[20,3,...Array(64).fill(0)],residuals,validation:{adopted:false,hasEdge:false}};
 const event={id:'g',home:'Buffalo Bills',away:'Kansas City Chiefs',homeCode:'BUF',awayCode:'KC',startsAt:new Date(now+3600000).toISOString(),forecast:{homeMean:23,awayMean:20,modelVersion:'base'}};
 const model={...structuredClone(base),version:'score-regime-kernel-v1',residualContexts:fixtures[0].contexts};
 const source={index:{events:[event],players:[],scoreModel:base,regimeScoreModel:model},snapshot:{props:{fetchedAt:at,quotes:[]}}};
 const before=JSON.stringify(source),primary=analyzeGame(source,event,{now}),shadow=regimeShadowGame(source,event);
 assert.ok(shadow);const research=analyzeGame(shadow.source,shadow.event,{now,anchorMarket:false,includeProduction:false});
 assert.match(research.modelVersion,/score-regime-kernel/);assert.equal(research.hasEdge,false);assert.equal(research.basis,'experimental_score_candidate');assert.equal(JSON.stringify(source),before);
 assert.deepEqual(analyzeGame(source,event,{now}).score,primary.score);
 model.validation.adopted=true;assert.equal(regimeShadowGame(source,event),null);
});
