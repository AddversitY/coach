import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {workloadFeatures,workloadForecasts,workloadSnapshot} from './workload-forecast.mjs';
import {gradeForecast,addGrade,evaluationReport} from './forecast-evaluation.mjs';
import {evaluationState} from './evaluation-state.mjs';

const fixture=JSON.parse(fs.readFileSync(new URL('./fixtures/workload-parity.json',import.meta.url),'utf8'));
const now=Date.UTC(2026,10,16,12),at=new Date(now).toISOString();
const event={id:'g',home:'Buffalo Bills',away:'Miami Dolphins',homeCode:'BUF',awayCode:'MIA',startsAt:'2026-11-22T18:00:00Z'};
function source(c=fixture.cases[0]){return {index:{cutoff:'2026-11-12',players:[{...c.player,events:['g']}],roleContext:{schemaVersion:1,cutoff:'2026-11-12',retrievedAt:at,teamGames:[...c.teamGames,...c.opponentGames]},workloadModel:{schemaVersion:1,version:'workload-ridge-v1',cutoff:'2026-11-12',trainedAt:at,adopted:false,hasEdge:false,models:{[c.group]:{coefficients:c.coefficients,residuals:c.residuals,trainingRows:1000}}}}};}
const close=(a,b)=>assert.ok(Math.abs(a-b)<1e-8,`${a} differs from ${b}`);

test('live workload inputs and predictions match independently generated Python fixtures',()=>{
  for(const c of fixture.cases){
    const pack=workloadFeatures(c.player.games,c.teamGames,c.opponentGames,c.day,c.group,c.home);
    pack.x.forEach((v,i)=>close(v,c.expected.x[i]));close(pack.incumbent,c.expected.incumbent);close(pack.last3,c.expected.last3);
    const result=workloadForecasts(source(c),event,{now});assert.equal(result.available,true);assert.equal(result.forecasts.length,1);
    close(result.forecasts[0].prediction,c.expected.prediction);result.forecasts[0].interval.forEach((v,i)=>close(v,c.expected.interval[i]));
    assert.equal(result.adopted,false);assert.equal(result.hasEdge,false);
  }
});

test('missing history, future/stale models and outside-window captures remain unavailable',()=>{
  const data=source();data.index.players[0].games=data.index.players[0].games.slice(0,5);
  assert.equal(workloadForecasts(data,event,{now}).forecasts.length,0);
  data.index.workloadModel.trainedAt=new Date(now+1).toISOString();assert.equal(workloadForecasts(data,event,{now}).available,false);
  data.index.workloadModel.trainedAt='2026-09-01T00:00:00Z';assert.equal(workloadForecasts(data,event,{now}).available,false);
  assert.equal(workloadSnapshot(source(),event,{now}),null);
  const upcoming={...event,startsAt:new Date(now+3600000).toISOString()};
  const captured=workloadSnapshot(source(),upcoming,{now});assert.equal(captured.rows.length,0);assert.equal(captured.benchmarkState,'not_applicable');
  assert.ok(captured.workloads.length);assert.equal(captured.priced,false);
});

test('workload grading preserves absent/traded identities, actual zeros and score corrections',async()=>{
  const row={playerId:'p',team:'BUF',group:'QB_attempts',metric:'attempts',prediction:30,incumbent:34,last3:35,last6:33,interval:[20,40]};
  const snapshot={id:'workload-ridge-v1:g:unpriced',modelVersion:'workload-ridge-v1',event:{...event,startsAt:new Date(now+3600000).toISOString()},capturedAt:at,priced:false,rows:[],workloads:[row,{...row,playerId:'absent'}]};
  const result={eventId:'g',homeScore:21,awayScore:10,playerStats:{p:{attempts:32}},playerTeams:{p:'BUF'}};
  const grade=gradeForecast(snapshot,result);assert.equal(grade.unresolved,1);assert.equal(grade.workloads.QB_attempts.candidateAbsolute,2);
  const wrong=gradeForecast(snapshot,{...result,playerTeams:{p:'MIA'}});assert.equal(wrong.unresolved,2);assert.deepEqual(wrong.workloads,{});
  const zero=gradeForecast(snapshot,{...result,playerStats:{p:{attempts:0}}});assert.equal(zero.workloads.QB_attempts.candidateAbsolute,30);
  const aggregate=addGrade({},grade);const report=evaluationReport(aggregate,{});assert.equal(report.markets.length,0);assert.equal(report.workloads[0].mae,2);
  const values=new Map(),storage={get:async k=>structuredClone(values.get(k)),put:async(k,v)=>values.set(k,structuredClone(v)),transaction:async fn=>fn(storage)};
  const send=(path,body)=>evaluationState({storage},path,new Request('https://internal'+path,{method:'POST',body:JSON.stringify(body)}));
  await send('/forecast-capture',snapshot);await send('/grade-batch',{hash:'one',results:[result]});
  await send('/grade-batch',{hash:'two',results:[{...result,playerStats:{p:{attempts:28}}}]});
  const updated=await (await evaluationState({storage},'/evaluation',new Request('https://internal/evaluation'))).json();
  assert.equal(updated.gradedGames,1);assert.equal(updated.workloads[0].observations,1);assert.equal(updated.workloads[0].mae,2);assert.equal(updated.workloads[0].incumbentMae,6);assert.equal(updated.unresolved,1);
});
