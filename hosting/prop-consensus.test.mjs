import test from 'node:test';
import assert from 'node:assert/strict';
import {answerPropConsensus, asksPropComparison, formatConsensus} from './prop-consensus.mjs';

const at = '2026-11-28T18:00:00Z';
const kickoff = '2026-11-29T18:00:00Z';
const eventId = 'nflverse:2026_13_SF_SEA';
const record = {scored: 0, mean: null, low: null, high: null, passes: false};

function row(book, outcome, decimal, line = 241.5, extra = {}) {
  return {
    book, eventId, market: 'player_pass_yds', outcome, player: 'Brock Purdy',
    decimal, line, at, kickoff, ...extra,
  };
}

const priced = [
  row('fanduel', 'Over', 1.91), row('fanduel', 'Under', 1.91),
  row('bovada', 'Over', 1.91), row('bovada', 'Under', 1.91),
  row('draftkings', 'Over', 2.2), row('draftkings', 'Under', 1.74),
];

const flagged = 'Best price vs other books: DraftKings, Brock Purdy Over 241.5 at +120 (decimal 2.2), consensus fair chance 48.1% from 3 books, price saved 2026-11-28T18:00:00Z. This is a comparison, not a pick. Prop-consensus closing-line record: 0 scored bets. 200 scored bets, with the low end of the range above zero, are needed before this is a signal.';

test('a price that pays 3% more than the consensus is named, and the even books are not', () => {
  assert.equal(formatConsensus(priced, {record}), flagged);
  assert.equal(answerPropConsensus(priced, 'Brock Purdy passing yards over 241.5', [{name: 'Brock Purdy'}], record), flagged);
});

test('fewer than 3 books on the same line stays unavailable, and a different line is not the same chance', () => {
  const thin = priced.filter(row => row.book !== 'draftkings');
  const text = formatConsensus(thin, {player: 'Brock Purdy', record});
  assert.match(text, /Best price vs other books: unavailable\. Fewer than 3 books/);
  assert.match(text, /A different line is not treated as the same chance/);
  const moved = [
    row('fanduel', 'Over', 1.91, 241.5), row('fanduel', 'Under', 1.91, 241.5),
    row('bovada', 'Over', 1.91, 241.5), row('bovada', 'Under', 1.91, 241.5),
    row('draftkings', 'Over', 2.2, 250.5), row('draftkings', 'Under', 1.74, 250.5),
  ];
  assert.match(formatConsensus(moved, {record}), /Fewer than 3 books/);
});

test('no saved price, an even market, and a one-sided anytime price stay a comparison', () => {
  assert.match(formatConsensus([], {record}), /No saved price for this prop/);
  const even = [
    row('fanduel', 'Over', 1.91), row('fanduel', 'Under', 1.91),
    row('bovada', 'Over', 1.91), row('bovada', 'Under', 1.91),
    row('betrivers', 'Over', 1.91), row('betrivers', 'Under', 1.91),
  ];
  assert.match(formatConsensus(even, {record}), /no saved price pays 3% more than a fair payout at the consensus chance\. Consensus fair chance on the over at 241\.5 is 50\.0% from 3 books/);
  assert.match(formatConsensus(priced, {market: 'player_anytime_td', record}), /Anytime touchdown is one-sided/);
});

test('a grade question is not a price comparison', () => {
  assert.equal(asksPropComparison('How good is Coach at receiving yards props?', ['Brock Purdy']), false);
  assert.equal(asksPropComparison('Brock Purdy passing yards', ['Brock Purdy']), true);
  assert.equal(asksPropComparison('best prop prices', []), true);
});
