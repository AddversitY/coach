import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {decisionBrief} from './game-context.mjs';
import {selectionExplanation} from './answer-quality.mjs';
import {resolveGame,analyzeGame,requestedBook} from './game-analysis.mjs';
const cases=JSON.parse(readFileSync(new URL('./fixtures/answer-scenarios.json',import.meta.url)));
const now=Date.UTC(2026,10,17,12),at=new Date(now).toISOString();
const event={id:'nflverse:2026_11_KC_BUF',home:'Buffalo Bills',away:'Kansas City Chiefs',homeCode:'BUF',awayCode:'KC',startsAt:'2026-11-22T18:00:00Z',forecast:{homeMean:24,awayMean:20,modelVersion:'test',cutoff:'2026-11-12'}};
const players=[['receiver','Recorded Receiver','WR'],['qb','Recorded Quarterback','QB'],['runner','Recorded Runner','RB']].map(([id,name,position])=>({id,name,position,team:'BUF',events:[event.id],games:Array.from({length:8},(_,i)=>({date:'2026-11-08',week:10-i,stats:{attempts:30,passing_yards:240,targets:8,receiving_yards:60,receptions:5,carries:15,rushing_yards:65}}))}));
const defs=[['spreads',event.home,-3.5],['spreads',event.away,3.5],['totals','Over',45.5],['totals','Under',45.5],['h2h',event.home,null],['h2h',event.away,null],['player_reception_yds','Over',65.5,players[0]],['player_reception_yds','Under',65.5,players[0]],['player_receptions','Over',5.5,players[0]],['player_receptions','Under',5.5,players[0]],['player_pass_yds','Over',245.5,players[1]],['player_pass_yds','Under',245.5,players[1]],['player_rush_yds','Over',68.5,players[2]],['player_rush_yds','Under',68.5,players[2]]];
function source(){return {index:{events:[event],players,scoreModel:{version:'test',trainedAt:at,cutoff:'2026-11-12',residuals:Array.from({length:180},(_,i)=>[i%17-8,i*7%19-9]),validation:{adopted:false,hasEdge:false}}},snapshot:{odds:{coverage:{players:players.map(p=>({playerId:p.id,name:p.name}))}},props:{fetchedAt:at,demo:false,quotes:defs.map(([market,outcome,point,p])=>({selection:{eventId:event.id,market,outcome,point,participant:p?.name||'',period:'full_game',rules:p?'player_prop_unverified':'game_market_unverified'},bookId:'draftkings',book:'DraftKings',provider:'the-odds-api',sourceAt:at,collectedAt:at,decimal:1.91,status:'open',demo:false}))}}};}
for(const c of cases)test('answer contract: '+c.question,()=>{
 const data=source(),report=analyzeGame(data,event,{now,question:c.question});
 const d=report.decision;
 assert.equal(d.hasEdge,false);assert.equal(d.action,'pass');assert.equal(d.recommendationsReady,false);
 if(c.missing){assert.equal(d.price,null);assert.equal(d.judgment,null);assert.equal(d.priceBoundary,null);}
 else{
  assert.equal(d.price.selection.market,c.market);assert.equal(d.price.selection.outcome,c.outcome);assert.equal(d.price.selection.point,c.point);
  assert.equal(d.judgment.selection,d.price.selection);assert.ok(d.judgment.conditionalChance>=0&&d.judgment.conditionalChance<=1);assert.match(d.judgment.text,/not establish value/);
  assert.deepEqual(d.priceBoundary.selection,d.price.selection);assert.match(d.priceBoundary.linePolicy,/different line requires/);
  if(c.market==='spreads'||c.market==='totals'||c.market.startsWith('player_'))assert.equal(d.lean,null);
  for(const follow of d.followUps){assert.equal(resolveGame(data.index,follow.query,{},now)?.id,event.id);if(follow.label==='Show the opposing case'){const again=analyzeGame(data,event,{now,question:follow.query});assert.deepEqual(again.decision.price?.selection,d.price.selection);}}
 }
 if(c.ticket)assert.match(d.decidingFactor,/correlation-aware joint estimate/);
});
test('stale prices, blocked roles and an unavailable requested book cannot become a supported judgment',()=>{
 for(const mutate of [s=>s.snapshot.props.fetchedAt='2026-10-01T00:00:00Z',s=>s.snapshot.props.quotes.forEach(q=>q.status='closed')]){
  const data=source();mutate(data);assert.equal(analyzeGame(data,event,{now,question:'Bills spread -3.5'}).decision.judgment,null);
 }
 const data=source(),question='Bills spread -3.5 at FanDuel';assert.equal(analyzeGame(data,event,{now,question,bookId:requestedBook(question,{})}).decision.price,null);
 const report=analyzeGame(data,event,{now});report.categories.forEach(c=>c.rows.forEach(r=>r.blocked=true));assert.equal(decisionBrief(report,report.context,{question:'Recorded Receiver receiving yards over 65.5'}).judgment,null);
});
test('break-even arithmetic preserves pushes and never creates an alternate-line cutoff or a guaranteed value claim',()=>{
 const row={selection:{market:'spreads',outcome:'Bills',point:-3},win:.45,push:.1,decimal:1.91,forecastBasis:'market_anchored'};
 const result=selectionExplanation({basis:'experimental_score_candidate'},row);assert.equal(result.priceBoundary.minimumDecimal,2);assert.equal(result.judgment.conditionalChance,.5);assert.equal(result.judgment.direction,'balanced');assert.equal(result.priceBoundary.relation,'below_model_threshold');assert.match(result.judgment.text,/Market-based/);
 assert.equal(selectionExplanation({}, {...row,win:0}).priceBoundary,null);assert.equal(selectionExplanation({}, {...row,win:.95,push:.1}).judgment,null);
});
