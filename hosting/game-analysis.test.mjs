import test from 'node:test';
import assert from 'node:assert/strict';
import {analyzeGame,outcome,resolveGame,validQuotes,playerProjection} from './game-analysis.mjs';
import {forecastSnapshot,gradeForecast,addGrade,evaluationReport,validateBenchmark} from './forecast-evaluation.mjs';
import {evaluationState} from './evaluation-state.mjs';
import {shadowGame} from './shadow-forecast.mjs';
import {requestedBookIds} from './book-preference.mjs';

const now=Date.UTC(2026,10,16,12),at=new Date(now).toISOString();
const event={id:'nflverse:2026_11_BUF_KC',home:'Kansas City Chiefs',away:'Buffalo Bills',startsAt:new Date(now+3600000).toISOString()};
const player={id:'p',name:'Recorded Receiver',team:'BUF',events:[event.id],games:Array.from({length:8},(_,i)=>({date:`2026-11-${String(12-i).padStart(2,'0')}`,stats:{receptions:4+i%5,receiving_yards:40+i*3,targets:7+i%4}}))};
const quote=(market,outcome,point=null,decimal=1.91)=>({selection:{eventId:event.id,market,outcome,point,participant:market.startsWith('player_')?player.name:'',period:'full_game',rules:market.startsWith('player_')?'player_prop_unverified':'game_market_unverified'},bookId:'draftkings',book:'DraftKings',provider:'the-odds-api',sourceAt:at,collectedAt:at,decimal,status:'open',demo:false});
function source(quotes=[]){return {index:{events:[{...event,forecast:{homeMean:24,awayMean:20,modelVersion:'test',cutoff:'2026-11-12'}}],players:[player],scoreModel:{version:'test',trainedAt:at,cutoff:'2026-11-12',residuals:Array.from({length:180},(_,i)=>[i%17-8,i*7%19-9]),validation:{adopted:false,hasEdge:false,markets:{}},baselineHomeWin:.55}},snapshot:{odds:{coverage:{players:[{playerId:'p',name:player.name}]}},props:{quotes,fetchedAt:at,demo:false}}};}
const gameQuotes=()=>[quote('spreads',event.home,-3.5),quote('spreads',event.away,3.5),quote('totals','Over',47.5),quote('totals','Under',47.5),quote('h2h',event.home,null,1.67),quote('h2h',event.away,null,2.3),quote('player_receptions','Over',5.5),quote('player_receptions','Under',5.5)];
test('a newly created report cannot include expired weather observations',()=>{
 const data=source(),weather={id:'weather',eventId:event.id,kind:'weather',source:'Test',observedAt:new Date(now-36*60000).toISOString(),value:{windMph:10}},telemetry={checkedAt:at,observations:[weather]};
 assert.equal(analyzeGame(data,data.index.events[0],{now,telemetry}).weather.length,0);
 weather.observedAt=at;assert.equal(analyzeGame(data,data.index.events[0],{now,telemetry}).weather.length,1);
});
function report(quotes=gameQuotes()){const data=source(quotes);return analyzeGame(data,data.index.events[0],{now});}

test('analyze a game supports four market categories and coherent win/push/loss arithmetic',()=>{
  const result=report();assert.equal(result.basis,'market_anchored');assert.equal(result.categories.length,4);
  for(const category of result.categories){assert.ok(category.rows.length);for(const row of category.rows){
    assert.ok(Math.abs(row.win+row.push+row.loss-1)<1e-8);assert.ok(row.win>=0&&row.push>=0&&row.loss>=0);
    assert.ok(Math.abs(row.win*row.minimumDecimal-(1-row.push))<1e-8);assert.equal(row.hasEdge,false);
  }}
  assert.equal(result.recommendationsReady,false);assert.equal(result.hasEdge,false);
  assert.ok(Math.abs(result.score.home-result.score.away-result.score.marginMedian)<20);
});
test('unpriced score outlook never invents a sportsbook opportunity',()=>{
  const result=report([]);assert.equal(result.basis,'experimental_score_candidate');assert.equal(result.ranked.length,0);
  assert.ok(result.categories.every(c=>c.status==='prices_unavailable'));assert.ok(result.projections.length);
  assert.match(result.summary,/prices are unavailable/);assert.equal(result.score.homeWin+result.score.tie<=1,true);
});

test('named-book subsets constrain price rows, comparisons and best-observed flags without changing score forecasts',()=>{
 const initial=gameQuotes(),data=source(initial.flatMap(q=>[
  q,{...q,bookId:'fanduel',book:'FanDuel',decimal:q.decimal+.05},{...q,bookId:'betmgm',book:'BetMGM',decimal:q.decimal+.5},
 ]));
 const all=analyzeGame(data,data.index.events[0],{now});
 const ids=requestedBookIds('Compare DraftKings and FanDuel',{bookId:'betmgm'});
 const selected=analyzeGame(data,data.index.events[0],{now,bookIds:ids,question:'Recorded Receiver receptions over 5.5'});
 assert.deepEqual(selected.bookIds,['draftkings','fanduel']);assert.equal(selected.bookId,null);assert.deepEqual(selected.score,all.score);
 for(const row of selected.categories.flatMap(c=>c.rows)){assert.ok(ids.includes(row.bookId));if(row.bookId==='fanduel')assert.equal(row.bestObservedPrice,true);}
 assert.deepEqual(selected.visualEvidence.priceComparison.offers.map(o=>o.bookId).sort(),['draftkings','fanduel']);
 const missing=analyzeGame(data,data.index.events[0],{now,bookIds:['williamhill_us']});
 assert.equal(missing.categories.flatMap(c=>c.rows).length,0);
 assert.equal(missing.visualEvidence.priceComparison.offers.length,0);
});
test('a schedule rebuild is not a new price observation and waiting status reaches the research summary',()=>{
 const data=source([]);data.snapshot.odds={status:'unavailable',provider:'the-odds-api',availability:{reason:'waiting_window',checkedAt:at,eligibleAt:new Date(now+3600000).toISOString()}};
 const r=analyzeGame(data,data.index.events[0],{now});
 assert.equal(r.priceCoverage.savedSourceAt,null);assert.equal(r.priceCoverage.savedQuotesExpired,false);
 assert.equal(r.priceCoverage.availability.reason,'waiting_window');assert.match(r.comparison.summary.text,/pregame update window/);
 data.snapshot.odds={status:'limited',fetchedAt:new Date(now-19*3600000).toISOString()};
 assert.equal(analyzeGame(data,data.index.events[0],{now}).priceCoverage.savedQuotesExpired,true);
});

test('event, book, freshness and identity boundaries exclude invalid prices',()=>{
  const rows=gameQuotes();const data=source(rows);
  for(const bad of [{...rows[0],demo:true},{...rows[0],book:'Wrong book'},{...rows[0],sourceAt:new Date(now+1).toISOString()},{...rows[0],selection:{...rows[0].selection,outcome:'Dallas Cowboys'}}]){
    assert.equal(validQuotes({...data,snapshot:{...data.snapshot,props:{...data.snapshot.props,quotes:[bad]}}},event,now).length,0);
  }
  assert.equal(analyzeGame(data,data.index.events[0],{now,bookId:'fanduel'}).ranked.length,0);
  assert.equal(resolveGame(data.index,'Analyze Bills',{},now).id,event.id);
  assert.equal(resolveGame(data.index,'Analyze Cowboys',{},now),null);
  assert.throws(()=>analyzeGame(data,{...event,startsAt:at},{now}),/Upcoming/);
});
test('spread signs, whole-number pushes, totals and moneyline ties settle consistently',()=>{
  assert.equal(outcome({market:'spreads',outcome:event.home,homeTeam:event.home,point:-3},24,21),0);
  assert.equal(outcome({market:'spreads',outcome:event.away,homeTeam:event.home,point:3.5},24,21),1);
  assert.equal(outcome({market:'totals',outcome:'Under',point:45},24,21),0);
  assert.equal(outcome({market:'h2h',outcome:event.home,homeTeam:event.home},24,24,null,true),-1);
  assert.equal(outcome({market:'h2h',outcome:'Draw',homeTeam:event.home},24,24),1);
});
test('workload projections require records and an affected scratch blocks ranked prop candidates',()=>{
  assert.equal(playerProjection({...player,games:player.games.slice(0,3)},'player_receptions'),null);
  const data=source(gameQuotes());const result=analyzeGame(data,data.index.events[0],{now,telemetry:{checkedAt:at,observations:[{kind:'injury',eventId:event.id,playerId:'p',observedAt:at,value:{status:'Out'}}]}});
  assert.ok(result.categories.find(c=>c.market==='props').rows.every(r=>r.blocked));assert.ok(result.ranked.every(r=>r.selection.participant!==player.name));
});
test('automatic research capture excludes early/late requests and does not store user bets',()=>{
  const r=report();assert.ok(forecastSnapshot(r));assert.equal(forecastSnapshot({...r,createdAt:event.startsAt}),null);
  assert.equal(forecastSnapshot({...r,createdAt:new Date(now-2*86400000).toISOString()}),null);
  const snapshot=forecastSnapshot(r);assert.equal(snapshot.question,undefined);assert.equal(snapshot.stake,undefined);
});
test('grading leaves absent appearances unresolved and compares only paired baselines by game',()=>{
  const snapshot=forecastSnapshot(report());
  snapshot.benchmark=validateBenchmark({probabilities:[{key:0,win:.55,push:0}]},snapshot);
  const grade=gradeForecast(snapshot,{eventId:event.id,homeScore:24,awayScore:21,playerStats:{}});
  assert.equal(grade.unresolved,2);assert.equal(grade.markets.props,undefined);assert.equal(grade.markets.spreads.observations,2);
  const aggregate=addGrade({},grade),result=evaluationReport(aggregate,{});
  assert.equal(result.markets.find(m=>m.market==='spreads').games,1);assert.equal(result.hasEdge,false);
  assert.throws(()=>validateBenchmark({probabilities:[{key:0,win:.9,push:.2}]},snapshot));
});

test('stored forecasts freeze first capture and score corrections replace prior grades',async()=>{
  const values=new Map();let queue=Promise.resolve();const storage={get:async key=>structuredClone(values.get(key)),put:async(key,value)=>values.set(key,structuredClone(value)),transaction(fn){const next=queue.then(()=>fn(storage));queue=next.catch(()=>{});return next;}};
  const state={storage};const request=(path,body)=>evaluationState(state,path,new Request('https://internal'+path,{method:'POST',body:JSON.stringify(body)}));
  const snapshot=forecastSnapshot(report());
  await Promise.all([request('/forecast-capture',snapshot),request('/forecast-capture',snapshot)]);
  const graded={eventId:event.id,homeScore:24,awayScore:21,playerStats:{p:{receptions:6}}};
  await request('/grade-batch',{hash:'one',results:[graded]});
  await request('/grade-batch',{hash:'one',results:[graded]});
  await request('/grade-batch',{hash:'corrected',results:[{...graded,awayScore:28}]});
  const result=await (await evaluationState(state,'/evaluation',new Request('https://internal/evaluation'))).json();
  assert.equal(result.snapshots,1);assert.equal(result.gradedGames,1);assert.equal(result.pendingGames,0);assert.equal(result.markets.find(m=>m.market==='h2h').games,1);
});

test('explicit dates and next week cannot silently select a different matchup',()=>{
  const data=source();data.index.events[0].homeCode='KC';data.index.events[0].awayCode='BUF';
  data.index.events.push({...data.index.events[0],id:'later',startsAt:new Date(now+8*86400000).toISOString()});
  assert.equal(resolveGame(data.index,'Analyze BUF next week',{},now).id,'later');
  assert.equal(resolveGame(data.index,'Analyze Bills on 2026-11-16',{},now).id,event.id);
  assert.equal(resolveGame(data.index,'Analyze Bills on 2026-11-19',{eventId:event.id},now),null);
});

test('independent shadow forecasts keep exact prices without borrowing market probabilities',()=>{
  const data=source(gameQuotes()),e={...data.index.events[0],homeCode:'KC',awayCode:'BUF'};
  const teams=['KC','BUF',...Array.from({length:30},(_,i)=>'T'+i)];
  data.index.shadowScoreModel={...data.index.scoreModel,schemaVersion:1,version:'shadow',teams,coefficients:[20,3,...Array(64).fill(0)]};
  const next=shadowGame(data,e);assert.ok(next);assert.equal(next.event.forecast.homeMean,23);
  const result=analyzeGame(next.source,next.event,{now,anchorMarket:false});
  const unpriced=analyzeGame({...next.source,snapshot:{props:{quotes:[]}}},next.event,{now,anchorMarket:false});
  assert.equal(result.basis,'experimental_score_candidate');assert.equal(result.score.homeWin,unpriced.score.homeWin);
  assert.ok(result.categories.find(c=>c.market==='spreads').rows.length);
  assert.equal(data.index.scoreModel.version,'test');assert.equal(data.index.events[0].forecast.homeMean,24);
  data.index.shadowScoreModel.validation={adopted:true,hasEdge:true};assert.equal(shadowGame(data,e),null);
});

test('serving and shadow evaluation cohorts remain separate through corrections',async()=>{
  const values=new Map(),storage={get:async key=>structuredClone(values.get(key)),put:async(key,value)=>values.set(key,structuredClone(value)),transaction:async fn=>fn(storage)};
  const state={storage},request=(path,body)=>evaluationState(state,path,new Request('https://internal'+path,{method:'POST',body:JSON.stringify(body)}));
  const primary=forecastSnapshot(report([])),shadow={...structuredClone(primary),modelVersion:'shadow',id:`shadow:${event.id}:unpriced`};
  shadow.rows[0].win=.95;shadow.rows[0].push=0;
  await request('/forecast-capture',primary);
  // Emulate a record captured by the original unscoped deployment.
  values.delete('evaluation-model:'+primary.modelVersion);
  await request('/forecast-capture',shadow);
  const scores={eventId:event.id,homeScore:10,awayScore:30};
  await request('/grade-batch',{hash:'a',results:[scores]});
  const read=async()=> (await evaluationState(state,'/evaluation',new Request('https://internal/evaluation?modelVersion='+encodeURIComponent(primary.modelVersion)))).json();
  let result=await read();assert.equal(result.capturedGames,1);assert.equal(result.gradedGames,1);assert.equal(result.models.length,2);
  const other=result.models.find(m=>m.role==='shadow');assert.equal(other.gradedGames,1);assert.notEqual(result.markets[0].brier,other.markets[0].brier);
  await request('/grade-batch',{hash:'b',results:[{...scores,homeScore:40}]});
  result=await read();assert.equal(result.gradedGames,1);assert.equal(result.pendingGames,0);assert.equal(result.models.find(m=>m.role==='shadow').markets[0].games,1);
});


test('priced comparisons exclude unpriced references and average calibration inside each game',()=>{
  const snapshot=forecastSnapshot(report([]));
  snapshot.rows=[
    {selection:{market:'h2h',outcome:event.home},win:.7,push:0,baseline:.6,decimal:2},
    {selection:{market:'h2h',outcome:event.home},win:.7,push:0,baseline:.6,decimal:2},
    {selection:{market:'h2h',outcome:event.home},win:.9,push:0,baseline:.5,decimal:null},
  ];
  const result={eventId:event.id,homeScore:24,awayScore:21};
  const grade=gradeForecast(snapshot,result),aggregate=addGrade({},grade);
  let row=evaluationReport(aggregate,{}).markets[0];
  assert.equal(row.priceComparison.games,1);assert.ok(Math.abs(row.priceComparison.brierDifference.mean-(-.07))<1e-10);
  assert.equal(row.priceComparison.brierDifference.interval95,null);assert.equal(row.calibration.length,2);
  assert.equal(row.calibration[0].games,1);assert.equal(row.calibration[0].observations,2);
  assert.equal(row.calibration[0].observed,1);
  addGrade(aggregate,grade,-1);row=evaluationReport(aggregate,{}).markets[0];
  assert.equal(row.priceComparison.games,0);assert.deepEqual(row.calibration,[]);
  for(let i=0;i<30;i++)addGrade(aggregate,grade);
  row=evaluationReport(aggregate,{}).markets[0];assert.equal(row.priceComparison.games,30);
  assert.ok(row.priceComparison.brierDifference.interval95.every(n=>Number.isFinite(n)));
  assert.equal(row.priceComparison.adopted,false);
});

test('frozen forecast keeps one best-priced row per selection, independent of book order',()=>{
  const books=[['ballybet','Bally Bet',1.85],['betmgm','BetMGM',1.87],['draftkings','DraftKings',1.89],['fanduel','FanDuel',1.95]];
  const quotes=books.flatMap(([bookId,book,decimal])=>gameQuotes().map(q=>({...q,bookId,book,decimal})));
  const snapshot=forecastSnapshot(report(quotes));
  const keys=snapshot.rows.map(r=>JSON.stringify(r.selection));assert.equal(new Set(keys).size,keys.length);
  for(const market of ['spreads','totals','h2h'])assert.equal(snapshot.rows.filter(r=>r.selection.market===market).length,2);
  assert.ok(snapshot.rows.every(r=>r.book==='FanDuel'));
});
test('a book-filtered analysis would freeze a different record, so the worker freezes the all-books view',()=>{
  const quotes=[...gameQuotes(),...gameQuotes().map(q=>({...q,bookId:'fanduel',book:'FanDuel',decimal:q.decimal-0.05}))];
  const data=source(quotes);
  const scoped=forecastSnapshot(analyzeGame(data,data.index.events[0],{now,bookIds:['fanduel']}));
  const all=forecastSnapshot(analyzeGame(data,data.index.events[0],{now,bookIds:null}));
  assert.equal(scoped.id,all.id);
  assert.ok(scoped.rows.every(r=>r.book==='FanDuel'));
  assert.ok(all.rows.some(r=>r.book==='DraftKings'));
});
