import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {footballShadowGame} from './shadow-forecast.mjs';
import {gameContext,contextEvidence} from './game-context.mjs';
const fixtures=JSON.parse(readFileSync(new URL('./fixtures/football-parity.json',import.meta.url)));
test('football trial agrees with independent Python means and preserves the serving model',()=>{
 for(const {source,event,means} of fixtures){
  const before=JSON.stringify(source),result=footballShadowGame(source,event);
  assert.ok(result);assert.ok(Math.abs(result.event.forecast.homeMean-means[0])<1e-8);assert.ok(Math.abs(result.event.forecast.awayMean-means[1])<1e-8);
  assert.equal(JSON.stringify(source),before);assert.equal(result.source.index.scoreModel.residuals.length,120);
  assert.equal(result.source.index.scoreModel.validation.hasEdge,false);
 }
});
test('football trial rejects adopted models, kickoff mismatches and insufficient earlier errors',()=>{
 for(const change of [f=>f.validation.adopted=true,f=>f.events[fixtures[0].event.id].startsAt='2030-01-01T00:00:00Z',f=>f.residuals=f.residuals.slice(0,119),f=>f.residuals.forEach(r=>r[4]='2030-01-01')]){
  const {source,event}=structuredClone(fixtures[0]);change(source.index.footballScoreModel);assert.equal(footballShadowGame(source,event),null);
 }
});
test('earlier QB evidence is sourced without claiming an upcoming starter or changing predictions',()=>{
 const {source,event}=structuredClone(fixtures[0]);source.index.players=[];source.index.contextPlayers=[];
 const context=gameContext(source,event,{now:Date.parse(event.startsAt)-3600000});
 assert.equal(context.version,'role-context-football-v2');assert.equal(context.adjustmentsApplied,false);
 assert.equal(context.teams[0].footballEvidence.confirmedUpcomingStarter,null);
 assert.ok(context.sources.some(s=>s.id==='football_features'&&s.url.startsWith('https://github.com/nflverse/')));
 assert.equal(contextEvidence(context).teams[0].footballEvidence.confirmedUpcomingStarter,null);
});
