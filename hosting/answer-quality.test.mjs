import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {decisionBrief} from './game-context.mjs';
import {selectionExplanation} from './answer-quality.mjs';
import {resolveGame,analyzeGame,requestedBook} from './game-analysis.mjs';
import {deterministicGameRoute,deterministicPlan,validatePlan} from './worker.mjs';
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
 if(c.clarify)assert.ok(d.clarification);
 if(c.ticket)assert.match(d.decidingFactor,/correlation-aware joint estimate/);
});
test('stale prices, blocked roles and an unavailable requested book cannot become a supported judgment',()=>{
 for(const mutate of [s=>s.snapshot.props.fetchedAt='2026-10-01T00:00:00Z',s=>s.snapshot.props.quotes.forEach(q=>q.status='closed')]){
  const data=source();mutate(data);assert.equal(analyzeGame(data,event,{now,question:'Bills spread -3.5'}).decision.judgment,null);
 }
 const data=source(),question='Bills spread -3.5 at FanDuel';assert.equal(analyzeGame(data,event,{now,question,bookId:requestedBook(question,{})}).decision.price,null);
 const report=analyzeGame(data,event,{now});report.categories.forEach(c=>c.rows.forEach(r=>r.blocked=true));assert.equal(decisionBrief(report,report.context,{question:'Recorded Receiver receiving yards over 65.5'}).judgment,null);
});

test('shorthand routes without model inference and charts preserve the actual requested market',()=>{
 const data=source();
 for(const question of ['Bills -3.5','Bills ML -150','Bills under 45.5','Recorded Receiver rec yds over 65.5'])assert.equal(deterministicGameRoute(question,data.index,{},now),true);
 assert.equal(analyzeGame(data,event,{now,question:'Bills -3.5'}).visualEvidence.teamMetric,'margin');
 const r=analyzeGame(data,event,{now,question:'Recorded Receiver over 65.5'});
 assert.match(r.decision.clarification,/Which player market/);assert.equal(r.decision.price,null);assert.equal(r.visualEvidence.players[0].line,null);
 const rec=analyzeGame(data,event,{now,question:'Recorded Receiver rec yds over 65.5'});
 assert.equal(rec.visualEvidence.players[0].metric,'receiving_yards');assert.equal(rec.visualEvidence.players[0].line,65.5);
 const total=analyzeGame(data,event,{now,question:'Bills under 45.5'});
 assert.equal(total.visualEvidence.teamMetric,'total');
 assert.equal(total.visualEvidence.teams[0].series.find(s=>s.metric==='total').line,45.5);
});

test('a player or matchup overview never silently chooses a priced side',()=>{
 const data=source();
 for(const question of ['Recorded Receiver','Tell me about the Bills']){
  const r=analyzeGame(data,event,{now,question});
  assert.equal(r.decision.price,null);assert.equal(r.decision.judgment,null);assert.equal(r.decision.priceBoundary,null);
  assert.match(r.decision.priceNotice,/No exact selection/);
 }
});

test('a team under question without a number requests the line rather than giving a winner lean',()=>{
 const data=source();
 for(const question of ['Bills under this week','Bills over','What about the under?']){
  const r=analyzeGame(data,event,{now,question});
  assert.equal(r.decision.reason,'selection_incomplete');assert.ok(r.decision.clarification);
  assert.equal(r.decision.price,null);assert.equal(r.decision.lean,null);
  assert.equal(r.visualEvidence.teamMetric,'total');
  for(const team of r.visualEvidence.teams)assert.equal(team.series.find(s=>s.metric==='total').line,null);
 }
});

test('unsupported scope cannot borrow full-game prices, chart lines or winner leans',()=>{
 const data=source();
 for(const question of ['Bills first-half spread -3.5','Bills team total under 45.5','Recorded Quarterback 1H passing yards under 245.5','Bills regulation-only moneyline','Bills live spread -3.5']){
  const r=analyzeGame(data,event,{now,question});
  assert.equal(r.decision.reason,'unsupported_scope');assert.equal(r.decision.price,null);assert.equal(r.decision.lean,null);assert.equal(r.comparison.summary.primary,false);
  assert.equal(r.visualEvidence.priceComparison.selection,null);
  for(const p of r.visualEvidence.players)assert.equal(p.line,null);
  for(const t of r.visualEvidence.teams)for(const s of t.series)assert.ok(s.line==null);
 }
 assert.throws(()=>validatePlan({tool:'analyze_game',query:'Bills spread -3.5'},'Bills first-half spread -3.5',data.index,{}),/market scope/);
 assert.throws(()=>validatePlan({tool:'analyze_game',query:'Recorded Receiver rushing yards under 65.5'},'Recorded Receiver receiving yards under 65.5',data.index,{}),/requested market/);
 assert.throws(()=>validatePlan({tool:'analyze_game',query:'Recorded Receiver receiving yards under 65.5'},'Recorded Receiver under 65.5',data.index,{}),/requested market/);
});

test('an unknown new subject cannot reuse a previous game, while clear contextual questions and lowercase codes work',()=>{
 const data=source(),context={eventId:event.id};
 for(const q of ['Lakers total over 221.5','Unknown Receiver receiving yards under 65.5']){
  assert.equal(resolveGame(data.index,q,context,now),null);
  assert.equal(validatePlan({tool:'analyze_game',query:'Game total over '+(q.includes('221.5')?'221.5':'65.5')},q,data.index,context,now).tool,'clarify');
 }
 for(const q of ['Is that still a good bet?','What about the under at DraftKings?','Game total under 45.5','over/under 45.5','the money line'])assert.equal(resolveGame(data.index,q,context,now)?.id,event.id);
 for(const q of ['buf -3.5','kc moneyline'])assert.equal(resolveGame(data.index,q,{},now)?.id,event.id);
 const r=analyzeGame(data,event,{now,question:'Game spread -3.5'});
 assert.ok(r.decision.clarification);for(const t of r.visualEvidence.teams)assert.equal(t.series.find(s=>s.metric==='margin').line,null);
});
test('break-even arithmetic preserves pushes and never creates an alternate-line cutoff or a guaranteed value claim',()=>{
 const row={selection:{market:'spreads',outcome:'Bills',point:-3},win:.45,push:.1,decimal:1.91,forecastBasis:'market_anchored'};
 const result=selectionExplanation({basis:'experimental_score_candidate'},row);assert.equal(result.priceBoundary.minimumDecimal,2);assert.equal(result.judgment.conditionalChance,.5);assert.equal(result.judgment.direction,'balanced');assert.equal(result.priceBoundary.relation,'below_model_threshold');assert.match(result.judgment.text,/Market-based/);
 assert.equal(selectionExplanation({}, {...row,win:0}).priceBoundary,null);assert.equal(selectionExplanation({}, {...row,win:.95,push:.1}).judgment,null);
});
test('a lineup concern is not misrepresented as a directional case against the requested side',()=>{
 const data=source(),report=analyzeGame(data,event,{now});
 report.context.alerts=[{team:'KC',kind:'offensive_line',text:'KC has a reported line concern.'}];
 const brief=decisionBrief(report,report.context,{question:'Bills spread line -3.5'});
 assert.match(brief.decidingFactor,/KC has/);assert.match(brief.counterargument,/selection losing/);assert.match(brief.counterargument,/could change/);
 assert.notEqual(brief.counterargument,brief.decidingFactor);
});
test('everyday wording keeps the asked team and total, and a missing price stays unavailable',()=>{
 const data=source();
 for(const question of ['over/under 45.5','game o/u 45.5']){
  const r=analyzeGame(data,event,{now,question});
  assert.equal(r.decision.price,null);assert.equal(r.decision.lean,null);assert.equal(r.decision.reason,'selection_incomplete');
  assert.match(r.decision.clarification,/over or under/);assert.equal(r.visualEvidence.teamMetric,'total');
  assert.equal(r.visualEvidence.teams[0].series.find(s=>s.metric==='total').line,45.5);
 }
 const under=analyzeGame(data,event,{now,question:'Bills o/u under 45.5'});
 assert.equal(under.decision.price.selection.outcome,'Under');assert.equal(under.decision.price.selection.point,45.5);assert.equal(under.decision.lean,null);
 const ml=analyzeGame(data,event,{now,question:'Bills money line'});
 assert.equal(ml.decision.price.selection.market,'h2h');assert.equal(ml.decision.price.selection.outcome,'Buffalo Bills');assert.equal(ml.decision.lean,null);
 assert.match(ml.decision.judgment.text,/comparison, not a pick/);
 assert.equal(analyzeGame(data,event,{now,question:'Bills to win'}).decision.price.selection.outcome,'Buffalo Bills');
 assert.equal(analyzeGame(data,event,{now,question:'KC money line at +150'}).decision.price.selection.outcome,'Kansas City Chiefs');
 const prop=analyzeGame(data,event,{now,question:'Recorded Receiver over/under 65.5'});
 assert.equal(prop.decision.price,null);assert.equal(prop.decision.lean,null);assert.match(prop.decision.clarification,/Which player market/);
 const missing=analyzeGame(data,event,{now,question:'Bills spread -2.5'});
 assert.equal(missing.decision.price,null);assert.match(missing.decision.headline,/unavailable/);assert.match(missing.decision.priceNotice,/unavailable/);
 assert.throws(()=>validatePlan({tool:'analyze_game',query:'Game total under 45.5'},'over/under 45.5',data.index,{},now),/explicit side/);
 assert.equal(deterministicGameRoute('Bills money line',data.index,{},now),true);
 assert.equal(deterministicPlan('Recorded Receiver over/under 65.5',data.index,{},now).tool,'clarify');
});
