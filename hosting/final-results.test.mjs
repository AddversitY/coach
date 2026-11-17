import test from 'node:test';
import assert from 'node:assert/strict';
import {scoreboardFinals,collectFinals} from './final-results.mjs';
import {evaluationState} from './evaluation-state.mjs';
const kick=Date.UTC(2026,10,16,1,15),now=kick+5*3600000;
const event={id:'nflverse:2026_11_BUF_KC',startsAt:new Date(kick).toISOString(),home:'Chiefs',away:'Bills'};
const raw=()=>({events:[{id:'provider',date:event.startsAt,season:{year:2026},competitions:[{status:{type:{completed:true,state:'post'}},competitors:[{homeAway:'home',team:{abbreviation:'KC'},score:'27'},{homeAway:'away',team:{abbreviation:'BUF'},score:'24'}]}]}]});
test('only exact dated, completed game identities can supply final scores',()=>{
 const result=scoreboardFinals(raw(),[event],now,'https://example.test');assert.equal(result[0].homeScore,27);assert.deepEqual(result[0].playerStats,{});assert.equal(result[0].evidence.state,'final');
 for(const mutate of [r=>r.events[0].competitions[0].status.type.completed=false,r=>r.events[0].competitions[0].status.type.state='in',r=>r.events[0].date='2026-11-17T01:15:00Z',r=>r.events[0].season.year=2025,r=>r.events[0].competitions[0].competitors[0].team.abbreviation='DAL',r=>r.events[0].competitions[0].competitors[0].score='',r=>r.events.push(structuredClone(r.events[0]))]){
  const r=raw();mutate(r);assert.equal(scoreboardFinals(r,[event],now,'https://example.test').length,0);
 }
});
test('final collection caches each capture scope, preserves old finals on failure and never fetches future games',async()=>{
 let calls=0;const fetch=async()=>{calls++;return raw();};
 const first=await collectFinals([event],null,now,fetch);assert.equal(calls,1);assert.equal(first.results.length,1);
 assert.deepEqual(await collectFinals([event],first,now+60000,fetch),first);assert.equal(calls,1);
 const failed=await collectFinals([event],first,now+16*60000,async()=>{throw Error('offline');});assert.equal(failed.results.length,1);assert.equal(failed.source.state,'unavailable');
 await collectFinals([event],null,kick-1000,fetch);assert.equal(calls,1);
});
test('automatic game finals grade every captured model once, preserve unknown props and accept later box scores',async()=>{
 const values=new Map(),storage={get:async k=>structuredClone(values.get(k)),put:async(k,v)=>values.set(k,structuredClone(v)),transaction:async f=>f(storage)};
 const state={storage},call=(path,body,t=now)=>evaluationState(state,path,new Request('https://internal'+path,{method:'POST',body:JSON.stringify(body)}),t);
 const snapshot={id:'one:'+event.id+':priced',modelVersion:'one',event,capturedAt:new Date(kick-3600000).toISOString(),priced:true,rows:[{id:'money',selection:{market:'h2h',outcome:'Chiefs'},win:.6,push:0,baseline:.5,decimal:2},{id:'prop',playerId:'p',selection:{market:'player_receptions',outcome:'Over',point:4.5},win:.6,push:0,baseline:.5,decimal:2}]};
 await call('/forecast-capture',snapshot,kick-3600000);await call('/forecast-capture',{...snapshot,id:'two:'+event.id+':priced',modelVersion:'two'},kick-3600000);
 assert.equal((await (await call('/result-targets',{})).json()).events.length,1);
 const results=scoreboardFinals(raw(),[event],now,'https://example.test');await call('/grade-batch',{hash:'final',results});
 let report=await (await call('/evaluation',{})).json();assert.equal(report.models.length,2);
 for(const model of report.models){assert.equal(model.gradedGames,1);assert.equal(model.unresolved,1);assert.equal(model.forwardWindow.weeksGraded,1);assert.equal(model.forwardWindow.weeksCaptured,1);}
 await call('/grade-batch',{hash:'box',results:[{...results[0],playerStats:{p:{receptions:7}}}]});
 report=await (await call('/evaluation',{})).json();for(const model of report.models){assert.equal(model.gradedGames,1);assert.equal(model.unresolved,0);assert.equal(model.markets.find(m=>m.market==='props').games,1);}
 assert.equal(values.get('grade:one:'+event.id).resultEvidence.source,'ESPN final scoreboard');
});
