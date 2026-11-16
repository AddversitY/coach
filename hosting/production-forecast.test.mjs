import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {workloadForecasts,trialHistory} from './workload-forecast.mjs';
import {productionRatePack,productionForecasts,productionSnapshot,productionSamples} from './production-forecast.mjs';
import {gradeForecast,addGrade,evaluationReport} from './forecast-evaluation.mjs';
const fixture=JSON.parse(fs.readFileSync(new URL('./fixtures/production-parity.json',import.meta.url),'utf8'));
const now=Date.UTC(2026,10,16,12),at=new Date(now).toISOString();
const event={id:'g',home:'Buffalo Bills',away:'Miami Dolphins',homeCode:'BUF',awayCode:'MIA',startsAt:'2026-11-22T18:00:00Z'};
function source(c){return {index:{cutoff:'2026-11-12',players:[{...c.player,events:['g']}],roleContext:{cutoff:'2026-11-12',retrievedAt:at,teamGames:[...c.teamGames,...c.opponentGames]},workloadModel:{schemaVersion:1,version:'workload-ridge-v1',cutoff:'2026-11-12',trainedAt:at,adopted:false,hasEdge:false,models:{[c.volumeGroup]:{trainingRows:1000,coefficients:c.volumeCoefficients,residuals:Array(120).fill(0)}}},productionModel:{schemaVersion:1,version:'production-joint-v1',volumeModelVersion:'workload-ridge-v1',cutoff:'2026-11-12',trainedAt:at,adopted:false,hasEdge:false,models:{[c.group]:{volumeGroup:c.volumeGroup,stat:c.stat,trainingRows:1000,coefficients:c.rateCoefficients,residualPairs:c.residualPairs}},validation:{}}}};}
const close=(a,b)=>assert.ok(Math.abs(a-b)<1e-8,`${a} differs from ${b}`);

test('live passing/receiving/reception distributions match independent Python fixtures',()=>{
  for(const c of fixture.cases){
    const data=source(c),workloadTrial=workloadForecasts(data,event,{now});
    const rate=productionRatePack(trialHistory(c.player),c.teamGames,c.opponentGames,c.day,c.stat,workloadTrial.forecasts[0].metric);
    rate.extra.forEach((v,i)=>close(v,c.expected.extra[i]));
    const trial=productionForecasts(data,event,{now,workloadTrial});assert.equal(trial.forecasts.length,1);
    close(trial.forecasts[0].prediction,c.expected.prediction);trial.forecasts[0].interval.forEach((v,i)=>close(v,c.expected.interval[i]));
    const short=trialHistory(c.player).slice(0,5);
    assert.equal(productionRatePack([...short,{...short[0],date:'2023-01-01'}],c.teamGames,c.opponentGames,c.day,c.stat,workloadTrial.forecasts[0].metric),null);
    assert.equal(trial.adopted,false);assert.equal(trial.hasEdge,false);
    const night={...event,startsAt:'2026-11-23T01:00:00Z'};
    close(productionForecasts(data,night,{now,workloadTrial:workloadForecasts(data,night,{now})}).forecasts[0].prediction,c.expected.prediction);
  }
});

test('verified exact lines get coherent experimental probabilities, never an invented ticket',()=>{
  const c=fixture.cases[0],data=source(c),workloadTrial=workloadForecasts(data,event,{now});
  const quote={id:'q',playerId:c.player.id,selection:{eventId:'g',market:'player_pass_yds',participant:c.player.name,outcome:'Over',point:225.5,period:'full_game',rules:'player_prop_unverified'},decimal:1.91,sourceAt:at,collectedAt:at,win:.5,push:0,loss:.5,book:'Test book',modelValidated:false,hasEdge:false};
  const trial=productionForecasts(data,event,{now,workloadTrial,observations:[quote]});assert.equal(trial.rows.length,1);
  close(trial.rows[0].win,c.expected.over225_5);close(trial.rows[0].win+trial.rows[0].push+trial.rows[0].loss,1);
  assert.equal(trial.rows[0].servingWin,.5);assert.equal(trial.rows[0].modelValidated,false);
  assert.equal(productionForecasts(data,event,{now,workloadTrial,observations:[{...quote,selection:{...quote.selection,eventId:'other'}}]}).rows.length,0);
  assert.equal(productionSnapshot(trial,event),null);
  const soon={...event,startsAt:new Date(now+3600000).toISOString()};
  assert.equal(productionSnapshot(trial,soon),null);
  const newTrial=productionForecasts(data,soon,{now,workloadTrial:workloadForecasts(data,soon,{now}),observations:[quote]});
  const snapshot=productionSnapshot(newTrial,soon);assert.match(snapshot.id,/:priced$/);assert.equal(snapshot.benchmarkState,'not_applicable');
  data.index.productionModel.trainedAt=new Date(now+1).toISOString();assert.equal(productionForecasts(data,event,{now,workloadTrial}).available,false);
});

test('signed yardage and same-price serving comparisons grade without claiming an edge',()=>{
  const point={playerId:'p',team:'BUF',group:'QB_rushing_yards',metric:'rushing_yards',prediction:-2,incumbent:5,last3:-1,last6:2,interval:[-8,10]};
  const row={id:'r',playerId:'p',team:'BUF',selection:{eventId:'g',market:'player_rush_yds',outcome:'Over',point:4.5,participant:'Player'},win:.3,push:0,servingWin:.6,servingPush:0,baseline:.5,decimal:1.91};
  const snapshot={event,modelVersion:'production-joint-v1',rows:[row],workloads:[point],capturedAt:at};
  const grade=gradeForecast(snapshot,{eventId:'g',homeScore:20,awayScore:10,playerTeams:{p:'BUF'},playerStats:{p:{rushing_yards:-3}}});
  assert.equal(grade.unresolved,0);assert.equal(grade.workloads.QB_rushing_yards.candidateAbsolute,1);
  const report=evaluationReport(addGrade({},grade),{});close(report.markets[0].servingPairedBrier,.09);close(report.markets[0].servingBrier,.36);
  assert.equal(report.hasEdge,false);assert.equal(report.workloads[0].mae,1);
  const corrected=gradeForecast(snapshot,{eventId:'g',homeScore:20,awayScore:10,playerTeams:{p:'MIA'},playerStats:{p:{rushing_yards:-3}}});assert.equal(corrected.unresolved,2);
});

test('paired replay preserves dependence and catch totals stay within targets',()=>{
  const pairs=Array.from({length:120},(_,i)=>i%2?[1,1]:[-1,-1]);
  const a=productionSamples(10,5,pairs,'passing_yards',100),b=productionSamples(10,5,pairs.map(([x,y])=>[x,-y]),'passing_yards',100);
  assert.notEqual(a.reduce((x,y)=>x+y,0),b.reduce((x,y)=>x+y,0));
  const catches=productionSamples(5,.8,pairs,'receptions',40);assert.ok(catches.every(v=>v>=0&&v<=6));
});
