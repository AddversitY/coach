import assert from 'node:assert/strict';
import test from 'node:test';
import {attachIdentity, collectSlice, dueCohort, mergeObservations, parseBovada, parseFanduelPage, parseKambiEvent, slotsToCapture} from './book-collect.mjs';

const NOW = Date.parse('2026-11-21T22:00:00Z');

test('kambi keeps the even posted line and scales milli-odds', () => {
  const rows = parseKambiEvent({
    events: [{id: 7, start: '2026-11-22T18:00:00Z', awayName: 'IND Colts', homeName: 'HOU Texans'}],
    betOffers: [{eventId: 7, criterion: {englishLabel: 'Total Passing Yards by the Player - Including Overtime'}, outcomes: [
      {englishLabel: 'Over', participant: 'C. J. Stroud', odds: 1400, line: 199500, status: 'OPEN'},
      {englishLabel: 'Under', participant: 'C. J. Stroud', odds: 2700, line: 199500, status: 'OPEN'},
      {englishLabel: 'Over', participant: 'C. J. Stroud', odds: 1910, line: 242500, status: 'OPEN'},
      {englishLabel: 'Under', participant: 'C. J. Stroud', odds: 1910, line: 242500, status: 'OPEN'},
    ]}],
  }, NOW);
  assert.equal(rows.length, 2);
  assert.equal(rows[0].line, 242.5);
  assert.equal(rows[0].decimal, 1.91);
  assert.equal(rows[0].market, 'player_pass_yds');
});

test('bovada and fanduel keep posted props and drop combos', () => {
  const bovada = parseBovada([{events: [{id: '1', type: 'GAMEEVENT', description: 'Indianapolis Colts @ Houston Texans', startTime: 1795370400000, displayGroups: [{markets: [
    {descriptionKey: 'Total Receptions O/U - Nico Collins', status: 'O', period: {description: 'Game'}, outcomes: [
      {description: 'Over', status: 'O', price: {handicap: '5.5', decimal: '1.87'}},
      {description: 'Under', status: 'O', price: {handicap: '5.5', decimal: '1.95'}},
    ]},
    {descriptionKey: 'Total Longest Reception O/U - Nico Collins', status: 'O', period: {description: 'Game'}, outcomes: [
      {description: 'Over', status: 'O', price: {handicap: '22.5', decimal: '1.90'}},
      {description: 'Under', status: 'O', price: {handicap: '22.5', decimal: '1.90'}},
    ]},
  ]}]}]}], NOW);
  assert.equal(bovada.length, 2);
  assert.equal(bovada[0].player, 'Nico Collins');
  const fanduel = parseFanduelPage({attachments: {events: {9: {name: 'Indianapolis Colts @ Houston Texans', openDate: '2026-11-22T18:00:00Z'}}, markets: {
    1: {eventId: '9', marketName: 'Nico Collins - Alt Receiving Yds', runners: [{runnerName: 'Over', handicap: 80.5, winRunnerOdds: {trueOdds: {decimalOdds: {decimalOdds: 2.4}}}}]},
    2: {eventId: '9', marketName: 'Nico Collins - Receiving Yds', runners: [
      {runnerName: 'Nico Collins Over', handicap: 74.5, winRunnerOdds: {trueOdds: {decimalOdds: {decimalOdds: 1.87}}}},
      {runnerName: 'Nico Collins Under', handicap: 74.5, winRunnerOdds: {trueOdds: {decimalOdds: {decimalOdds: 1.95}}}},
    ]},
    3: {eventId: '9', marketName: 'Anytime Touchdown Scorer', runners: [
      {runnerName: 'Nico Collins', winRunnerOdds: {trueOdds: {decimalOdds: {decimalOdds: 1.8}}}},
      {runnerName: 'Nico Collins or C.J. Stroud', winRunnerOdds: {trueOdds: {decimalOdds: {decimalOdds: 1.4}}}},
      {runnerName: 'Houston Defense', winRunnerOdds: {trueOdds: {decimalOdds: {decimalOdds: 3.2}}}},
    ]},
  }}}, NOW);
  assert.deepEqual(fanduel.map(row => `${row.market}:${row.player}:${row.line}`).sort(), ['player_anytime_td:Nico Collins:0.5', 'player_reception_yds:Nico Collins:74.5', 'player_reception_yds:Nico Collins:74.5']);
});

test('a name collision uses the team and a 24 hour window is due', () => {
  const players = [{id: '00-0034857', name: 'Josh Allen', team: 'BUF'}, {id: '00-0039000', name: 'Josh Allen', team: 'JAX'}];
  const events = [{id: 'nflverse:2026_12_IND_HOU', awayCode: 'IND', homeCode: 'HOU', startsAt: '2026-11-22T18:00:00Z'}];
  const rows = attachIdentity([{book: 'bovada', eventId: '1', kickoff: '2026-11-22T18:00:00Z', away: 'Indianapolis Colts', home: 'Houston Texans', market: 'player_pass_yds', outcome: 'Over', player: 'Josh Allen', line: 240.5, decimal: 1.91}], players, events);
  assert.equal(rows[0].eventId, 'nflverse:2026_12_IND_HOU');
  assert.equal(rows[0].playerId, undefined);
  const matched = attachIdentity([{...rows[0], player: 'Josh Allen', away: 'Buffalo Bills', home: 'Houston Texans'}], players, [{id: 'nflverse:2026_12_BUF_HOU', awayCode: 'BUF', homeCode: 'HOU', startsAt: '2026-11-22T18:00:00Z'}]);
  assert.equal(matched[0].playerId, '00-0034857');
  assert.deepEqual(slotsToCapture(24 * 60, []), ['T-24h']);
  assert.deepEqual(slotsToCapture(0, []), []);
  const cohort = dueCohort(events, NOW, null);
  assert.equal(cohort.slot, 'T-24h');
  assert.equal(dueCohort(events, NOW, {completed: [cohort.key]}), null);
});

test('a slice makes one polite bovada request and a later price replaces the side', async () => {
  const cohort = {key: 'game|T-24h', slot: 'T-24h', events: [{id: 'nflverse:2026_12_IND_HOU', startsAt: '2026-11-22T18:00:00Z', awayCode: 'IND', homeCode: 'HOU'}]};
  let calls = 0;
  const slice = await collectSlice(null, cohort, [], cohort.events, async () => {
    calls += 1;
    return {status: 200, async text() { return JSON.stringify([{events: [{id: '1', type: 'GAMEEVENT', description: 'Indianapolis Colts @ Houston Texans', startTime: '2026-11-22T18:00:00Z', displayGroups: [{markets: [{descriptionKey: 'Total Receptions O/U - Nico Collins', status: 'O', period: {description: 'Game'}, outcomes: [
      {description: 'Over', status: 'O', price: {handicap: 5.5, decimal: 1.87}},
      {description: 'Under', status: 'O', price: {handicap: 5.5, decimal: 1.95}},
    ]}]}]}]}]); }};
  }, NOW);
  assert.equal(calls, 1);
  assert.equal(slice.fetches, 1);
  assert.equal(slice.cursor.stage, 'betrivers-list');
  assert.equal(slice.rows.length, 2);
  const merged = mergeObservations({observations: [{book: 'bovada', eventId: slice.rows[0].eventId, market: 'player_receptions', player: 'Nico Collins', outcome: 'Over', decimal: 1.5, line: 4.5, at: '2026-11-21T12:00:00Z', kickoff: '2026-11-22T18:00:00Z'}]}, slice.rows, NOW);
  const over = merged.observations.find(row => row.outcome === 'Over');
  assert.equal(over.decimal, 1.87);
  assert.equal(over.line, 5.5);
});
