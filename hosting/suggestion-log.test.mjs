import test from 'node:test';
import assert from 'node:assert/strict';
import {snapshotFor,suggestions} from './suggestion-log.mjs';

const event={id:'nflverse:2026_12_ARI_KC',home:'Kansas City Chiefs',away:'Arizona Cardinals',homeCode:'KC',awayCode:'ARI',startsAt:'2026-11-29T18:00:00Z'};
const row=(at,book,market,outcome,line,decimal,player='')=>({at,book,market,outcome,line,decimal,player,home:'KC',away:'ARI',kickoff:'2026-11-29T18:00:00Z'});
const history={observations:[
  row('2026-11-28T10:00:00Z','draftkings','spreads','Kansas City Chiefs',-3,1.91),
  row('2026-11-28T12:00:00Z','draftkings','spreads','Kansas City Chiefs',-3.5,1.95),
  row('2026-11-28T12:00:00Z','draftkings','spreads','Arizona Cardinals',3.5,1.87),
  row('2026-11-28T12:00:00Z','pinnacle','spreads','Kansas City Chiefs',-3.5,1.93),
  row('2026-11-28T12:00:00Z','draftkings','player_rush_yds','Over',50.5,1.9,'Not Indexed'),
]};

test('the newest snapshot becomes Worker quotes for Coach books only', ()=>{
  const built=snapshotFor({players:[]},history,event);
  assert.equal(built.at,'2026-11-28T12:00:00Z');
  const quotes=built.snapshot.props.quotes;
  assert.equal(quotes.length,2);
  assert.ok(quotes.every(q=>q.bookId==='draftkings'&&q.selection.market==='spreads'));
  assert.equal(quotes[0].selection.outcome,'Kansas City Chiefs');
  assert.equal(quotes[0].selection.eventId,event.id);
});

test('a game without a model is skipped, not guessed', ()=>{
  const result=suggestions({events:[event],players:[]},history,Date.parse('2026-11-28T12:01:00Z'));
  assert.equal(result.suggestions.length,0);
  assert.equal(result.skipped.length,1);
});
