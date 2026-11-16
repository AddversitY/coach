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
