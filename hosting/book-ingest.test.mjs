import test from 'node:test';
import assert from 'node:assert/strict';
import {mergeBookIngest} from './worker.mjs';

const now = Date.parse('2026-11-28T12:00:00Z');
const kickoff = '2026-11-29T18:00:00Z';

function row(book, at, extra = {}) {
  return {
    book, eventId: 'nflverse:2026_13_SF_SEA', market: 'player_pass_yds', outcome: 'Over',
    player: 'Brock Purdy', decimal: 1.91, line: 241.5, at, kickoff, ...extra,
  };
}

test('a post replaces only its own books, and a newer stored row wins', () => {
  const stored = {
    observations: [
      row('fanduel', '2026-11-28T11:00:00Z'),
      row('bovada', '2026-11-28T11:00:00Z', {player: 'Jaxon Smith-Njigba'}),
    ],
  };
  const incoming = {
    observations: [
      row('fanduel', '2026-11-28T10:00:00Z', {decimal: 1.5}),
      row('draftkings', '2026-11-28T11:30:00Z'),
    ],
  };
  const merged = mergeBookIngest(stored, incoming, now);
  const books = merged.observations.map(item => item.book).sort();
  assert.deepEqual(books, ['bovada', 'draftkings', 'fanduel']);
  const fanduel = merged.observations.find(item => item.book === 'fanduel');
  assert.equal(fanduel.at, '2026-11-28T11:00:00Z');
  assert.equal(fanduel.decimal, 1.91);
  assert.equal(merged.observations.find(item => item.book === 'draftkings').decimal, 1.91);
});

test('a stored row left out of a stale snapshot is kept when it is newer than that post', () => {
  const stored = {
    observations: [
      row('fanduel', '2026-11-28T18:00:00.500Z', {player: 'Aiyuk'}),
      row('fanduel', '2026-11-28T10:00:00Z', {player: 'Brock Purdy'}),
    ],
  };
  const incoming = {observations: [row('fanduel', '2026-11-28T18:00:00Z', {player: 'Brock Purdy', decimal: 2.1})]};
  const merged = mergeBookIngest(stored, incoming, now);
  const aiyuk = merged.observations.find(item => item.player === 'Aiyuk');
  const purdy = merged.observations.find(item => item.player === 'Brock Purdy');
  assert.equal(aiyuk.at, '2026-11-28T18:00:00.500Z');
  assert.equal(purdy.decimal, 2.1);
});

test('kickoff more than 36 hours ago is dropped, and a missing kickoff stays', () => {
  const incoming = {
    observations: [
      row('bovada', '2026-11-28T11:00:00Z', {kickoff: '2026-11-26T20:00:00Z', player: 'Old'}),
      row('bovada', '2026-11-28T11:00:00Z', {kickoff: '2026-11-29T18:00:00Z', player: 'Future'}),
      row('bovada', '2026-11-28T11:00:00Z', {player: 'Open', kickoff: undefined}),
    ],
  };
  const merged = mergeBookIngest({observations: [row('fanduel', '2026-11-28T11:00:00Z', {kickoff: '2020-01-01T00:00:00Z'})]}, incoming, now);
  const players = merged.observations.map(item => item.player).sort();
  assert.deepEqual(players, ['Future', 'Open']);
});

test('an empty post does not wipe other books, and the store stays at 5000 rows', () => {
  const stored = {observations: [row('bovada', '2026-11-28T11:00:00Z')]};
  assert.equal(mergeBookIngest(stored, {observations: []}, now).observations.length, 1);
  const many = Array.from({length: 5001}, (_, i) => row('draftkings', '2026-11-28T11:00:00Z', {player: `Player ${i}`, eventId: `nflverse:2026_13_SF_${i}`}));
  assert.equal(mergeBookIngest({observations: []}, {observations: many}, now).observations.length, 5000);
});
