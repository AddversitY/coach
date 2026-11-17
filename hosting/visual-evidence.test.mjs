import test from 'node:test';
import assert from 'node:assert/strict';
import {visualEvidence} from './visual-evidence.mjs';
import {resolveGame} from './game-analysis.mjs';
import {deterministicGameRoute} from './worker.mjs';
const now=Date.UTC(2026,10,17),event={id:'target',away:'Buffalo Bills',home:'Kansas City Chiefs',awayCode:'BUF',homeCode:'KC'};
const source={index:{cutoff:'2026-11-12',players:[{id:'p',name:'Recorded Receiver',team:'BUF',position:'WR',events:['target'],games:[{date:'2026-11-01',week:9,stats:{receiving_yards:0,receptions:0}},{date:'2026-11-08',week:10,stats:{receptions:4}},{date:'2026-11-20',week:12,stats:{receiving_yards:999}}]}],results:[{eventId:'g',date:'2026-11-08',home:event.away,away:'Other',homeScore:24,awayScore:17},{eventId:'future',date:'2026-11-20',home:event.away,away:'Other',homeScore:99,awayScore:0},{eventId:'target',date:'2026-11-08',home:event.away,away:'Other',homeScore:88,awayScore:0}]}};
test('named props resolve their own game instead of a previous unrelated matchup',()=>{
 const startsAt=new Date(Date.now()+86400000).toISOString(),correct={...event,startsAt},wrong={id:'other',home:'Other Home',away:'Other Away',startsAt};
 const index={...source.index,events:[wrong,correct]};
 assert.equal(resolveGame(index,'Recorded Receiver receiving yards over 65.5',{eventId:'other'})?.id,'target');
 assert.equal(deterministicGameRoute('Recorded Receiver receiving yards over 65.5',index,{eventId:'other'}),true);
 assert.equal(resolveGame(index,'Other Home Recorded Receiver receiving yards over 65.5'),null);
});
test('player visuals preserve true zero, missing metrics and the requested line without using future rows',()=>{
 const v=visualEvidence(source,event,{decision:{}},'Recorded Receiver receiving yards over 65.5',now),p=v.players[0];
 assert.equal(v.focus,'player');assert.equal(p.line,65.5);assert.equal(p.lineSource,'Requested line');assert.deepEqual(p.series.find(s=>s.metric==='receiving_yards').samples.map(s=>s.value),[0,null]);assert.equal(p.series.find(s=>s.metric==='receptions').samples.length,2);
 assert.equal(visualEvidence(source,event,{decision:{}},'Unknown Receiver receiving yards over 65.5',now).players.length,0);
});
test('team charts use exact identities and earlier final results, with no target-game or future outcomes',()=>{
 const v=visualEvidence(source,event,{decision:{}},'Analyze BUF spread',now);assert.equal(v.selectedTeam,event.away);assert.equal(v.teams[0].samples.length,1);assert.equal(v.teams[0].samples[0].value,24);assert.equal(v.teams[0].samples[0].secondary,17);assert.equal(v.teams[1].samples.length,0);
});
