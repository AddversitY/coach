import test from 'node:test';
import assert from 'node:assert/strict';
import {compareResearch} from './research-comparison.mjs';
import {requestedBook} from './game-analysis.mjs';
const at='2026-11-16T18:00:00Z';
const selection={market:'spreads',outcome:'Buffalo Bills',participant:'',point:-3.5};
const row={id:'one',selection,bookId:'draftkings',book:'DraftKings',sourceAt:at,decimal:1.91,baseline:.5,win:.8,conditionalEv:100,blocked:false};
const report=rows=>({createdAt:at,categories:['spreads','totals','h2h','props'].map(market=>({market,rows:rows.filter(r=>r.selection.market===market||market==='props'&&r.selection.market.startsWith('player_'))}))});
test('comparison uses coverage, never optimistic model probabilities or EV',()=>{
 const input=report([row,{...row,id:'two',bookId:'fanduel',book:'FanDuel'}, {...row,id:'prop',selection:{...selection,market:'player_pass_yds'},baseline:null,conditionalEv:999,win:.99}]);
 const result=compareResearch(input);assert.equal(result.leadingMarket,'spreads');assert.equal(result.basis,'evidence_completeness');assert.equal(result.action,'pass');assert.equal(result.hasEdge,false);
 const updated=structuredClone(input);for(const c of updated.categories)for(const r of c.rows){r.win=.01;r.conditionalEv=-999;}
 assert.deepEqual(compareResearch(updated),result);
});
test('blocked selections and missing prices remain unavailable, equal evidence has no forced winner',()=>{
 assert.equal(compareResearch(report([{...row,blocked:true}])).leadingMarket,null);
 const result=compareResearch(report([row,{...row,id:'total',selection:{...selection,market:'totals',outcome:'Over',point:45.5}}]));
 assert.equal(result.leadingMarket,null);assert.match(result.headline,/comparable/);
 assert.equal(result.options.find(o=>o.market==='props').status,'missing_price');
});
test('an explicit new sportsbook overrides the previous preference',()=>{
 assert.equal(requestedBook('At FanDuel?',{bookId:'draftkings'}),'fanduel');
 assert.equal(requestedBook('What about the under?',{bookId:'draftkings'}),'draftkings');
});

function withHistory(rows){const input=report(rows);input.event={home:'Buffalo Bills',away:'Kansas City Chiefs',startsAt:'2026-11-19T18:00:00Z'};input.decision={focus:'game'};input.context={alerts:[],participation:{confirmedStartersAvailable:false},teams:[]};input.visualEvidence={teams:[{name:'Buffalo Bills',samples:Array.from({length:3},()=>({value:24,secondary:17}))},{name:'Kansas City Chiefs',samples:Array.from({length:3},()=>({value:20,secondary:21}))}]};return input;}
test('a unique research priority explains supporting records without claiming an advantage',()=>{
 const input=withHistory([row,{...row,id:'two',bookId:'fanduel',book:'FanDuel'}]);const out=compareResearch(input);
 assert.equal(out.summary.primary,true);assert.equal(out.summary.state,'clearer_option');assert.equal(out.leadingMarket,'spreads');assert.equal(out.summary.action,'pass');assert.equal(out.hasEdge,false);
 assert.ok(out.options[0].facts.some(s=>s.includes('7.0 average prior margin')));assert.ok(out.options[0].risks.some(s=>s.includes('unconfirmed')));assert.ok(out.summary.followUps[0].query.includes('2026-11-19'));
});
test('usable recent evidence outranks a stale multi-book market and ties never force a winner',()=>{
 const old={...row,sourceAt:'2026-11-16T06:00:00Z'},total={...row,id:'total',selection:{...selection,market:'totals',outcome:'Over',point:45.5}};
 const out=compareResearch(withHistory([old,{...old,id:'two',bookId:'fanduel',book:'FanDuel'},total]));assert.equal(out.leadingMarket,'totals');assert.equal(out.summary.state,'clearer_option');
 const tied=compareResearch(withHistory([row,total]));assert.equal(tied.leadingMarket,null);assert.equal(tied.summary.state,'comparable');assert.equal(tied.summary.leadingMarkets.length,2);
 const stale=compareResearch(withHistory([old]));assert.equal(stale.summary.state,'review_inputs');assert.match(stale.summary.text,/No option clears/);assert.ok(stale.summary.blockers.some(s=>s.includes('12 hours old')));
});
test('missing, future and blocked quotes cannot create a research winner',()=>{
 for(const rows of [[],[{...row,blocked:true}],[{...row,sourceAt:'2026-11-17T18:00:00Z'}]]){const out=compareResearch(withHistory(rows));assert.equal(out.summary.state,'insufficient_support');assert.equal(out.leadingMarket,null);assert.equal(out.summary.followUps.length,0);}
});
test('props need their own recorded production and workload, with a role check rather than invented snap forecasts',()=>{
 const prop={...row,id:'p',playerId:'p',selection:{...selection,market:'player_reception_yds',participant:'Recorded Receiver',outcome:'Over',point:65.5}};
 const input=withHistory([prop]);input.projections=[{playerId:'p',market:'player_reception_yds',records:6}];input.context.teams=[{code:'BUF',usage:[{playerId:'p',appearances:6,metric:'targets',recentMean:4.7,priorMean:8.3}],lineupReview:{starterConfirmed:false}}];
 const out=compareResearch(input),option=out.options.find(o=>o.market==='props');assert.ok(option.facts.some(s=>s.includes('4.7 per game')));assert.equal(option.criteria.find(c=>c.id==='context').state,'unknown');assert.equal(out.summary.action,'pass');
 input.context.alerts=[{team:'BUF',text:'Recorded quarterback changed.'}];assert.equal(compareResearch(input).options.find(o=>o.market==='props').researchState,'review_lineup');
});
test('a representative selection is neutral between equal-coverage sides, not chosen for a larger payout',()=>{
 const other={...row,id:'opposite',selection:{...selection,outcome:'Kansas City Chiefs',point:3.5},decimal:99};
 const first=compareResearch(withHistory([row,other])),changed=withHistory([{...row,decimal:20},{...other,decimal:1.01}]);
 const second=compareResearch(changed);assert.deepEqual(first.options[0].selection,second.options[0].selection);assert.equal(first.options[0].equivalentSelections,2);assert.equal(second.options[0].equivalentSelections,2);
});
test('expired source prices are explained without claiming betting markets do not exist',()=>{
 const input=withHistory([]);input.priceCoverage={savedQuotesExpired:true};const out=compareResearch(input);
 assert.equal(out.summary.state,'insufficient_support');assert.match(out.summary.text,/quotes have expired/);assert.match(out.summary.text,/charts below remain/);assert.match(out.summary.blockers[0],/18-hour/);
});
