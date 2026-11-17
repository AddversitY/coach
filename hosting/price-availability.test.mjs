import test from 'node:test';
import assert from 'node:assert/strict';
import {priceAvailability} from './price-availability.mjs';
import {compareResearch} from './research-comparison.mjs';
const now=Date.parse('2026-11-17T18:00:00Z');
const snapshot=(reason='waiting_window',eligibleAt='2026-11-19T19:20:00Z')=>({odds:{status:'unavailable',provider:'the-odds-api',availability:{reason,checkedAt:new Date(now).toISOString(),eligibleAt,message:'UNTRUSTED PROVIDER ERROR'}}});
test('waiting prices show eligibility without promising a completed update',()=>{
 const availability=priceAvailability(snapshot(),now);
 assert.match(availability.message,/pregame update window/);assert.match(availability.message,/Nov 19/);assert.match(availability.message,/not a promised refresh/);assert.doesNotMatch(availability.message,/UNTRUSTED/);
 const report={createdAt:new Date(now).toISOString(),decision:{focus:'game'},categories:[],priceCoverage:{availability}};
 const result=compareResearch(report);assert.match(result.summary.text,/pregame update window/);assert.equal(result.action,'pass');
});
test('expired status, unknown reasons and future checks do not invent a connection status',()=>{
 assert.equal(priceAvailability(snapshot('made_up'),now),null);
 assert.equal(priceAvailability(snapshot(),now+86400001),null);
 assert.equal(priceAvailability(snapshot(),now-6000),null);
 assert.equal(priceAvailability({odds:{status:'not_configured'}},now),null);
});
test('limits and passed eligibility remain explicit without implying prices are fresh',()=>{
 for(const reason of ['daily_limit','monthly_limit','protected_reserve','usage_review','source_unavailable']){
  const result=priceAvailability(snapshot(reason),now);assert.ok(result.message);assert.notEqual(result.reason,'missing_key');
 }
 const result=priceAvailability(snapshot('daily_limit','2026-11-18T00:00:00Z'),now+7*3600000);
 assert.match(result.message,/successful scheduled update is still needed/);
});
