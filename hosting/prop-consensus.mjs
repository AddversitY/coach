/** Cross-book prop comparison. A saved price versus the no-vig average of the
 * other books on the same line. A comparison, not a pick.
 *
 * At least 3 books must post both sides of the same line. A different line is
 * not moved onto that chance. A side is listed when its price pays at least
 * 3% more than a fair payout at the consensus chance (fair chance times the
 * decimal, minus 1). The bar is 3%, wider than the 2% Pinnacle rule, because
 * this average is the same soft books and each book sits inside it, so a 2%
 * gap is ordinary vig noise. The PropLine 2% test against Pinnacle still lost
 * to the close. Fair chances outside 10% to 90% are left out.
 */
export const MIN_BOOKS = 3;
export const MIN_EDGE = 0.03;
export const MIN_FAIR = 0.10;
export const MAX_FAIR = 0.90;
const TWO_SIDED = new Set([
  'player_pass_yds', 'player_rush_yds', 'player_reception_yds', 'player_receptions',
  'player_pass_attempts', 'player_pass_completions', 'player_pass_tds',
]);
const BOOK_NAMES = {
  fanduel: 'FanDuel', bovada: 'Bovada', betrivers: 'BetRivers',
  draftkings: 'DraftKings', betmgm: 'BetMGM', pinnacle: 'Pinnacle',
};

export function isPropQuestion(question) {
  return /\b(props?|yards|receptions?|catches|carries|rush(?:ing)?|pass(?:ing|es)?|touchdowns?|anytime|tds?)\b/i.test(String(question || ''));
}

function namesInQuestion(question, names) {
  const q = String(question || '').toLowerCase();
  let best = '';
  for (const name of names || []) {
    const text = String(name || '').trim();
    if (text.length >= 3 && q.includes(text.toLowerCase()) && text.length > best.length) best = text;
  }
  return best;
}

/** A prop question that is asking about a price, not a grade of Coach. */
export function asksPropComparison(question, names) {
  if (!isPropQuestion(question)) return false;
  if (namesInQuestion(question, names)) return true;
  return /\b(price|prices|odds|line|lines|over|under|book|books|shop|compare)\b/i.test(String(question || ''));
}

function quoteNewer(next, prev) {
  const a = Date.parse(next || '');
  const b = Date.parse(prev || '');
  if (Number.isFinite(a) && Number.isFinite(b)) return a >= b;
  return String(next || '') >= String(prev || '');
}

function noVig(over, under) {
  if (!(over > 1) || !(under > 1)) return null;
  const a = 1 / over, b = 1 / under;
  return a / (a + b);
}

function identity(row) {
  const event = String(row?.eventId || '');
  let away = row?.away, home = row?.home;
  if (event.startsWith('nflverse:')) {
    const parts = event.split(':')[1]?.split('_') || [];
    if (parts.length >= 4 && parts[2] && parts[3]) {
      away = parts[2];
      home = parts[3];
    }
  }
  if (!away || !home) return null;
  if (away === 'LAR') away = 'LA';
  if (home === 'LAR') home = 'LA';
  return {event: event || `${away}|${home}|${String(row.kickoff || '').slice(0, 16)}`, away, home};
}

function sideOf(outcome) {
  const text = String(outcome || '');
  if (/^over$/i.test(text)) return 'Over';
  if (/^under$/i.test(text)) return 'Under';
  return '';
}

/** Newest two-sided quote per book, then the consensus on each exact line. */
export function consensusGroups(observations) {
  const latest = new Map();
  for (const row of observations || []) {
    if (!row || !TWO_SIDED.has(row.market) || !(row.decimal > 1) || row.decimal > 100) continue;
    const line = Number(row.line);
    if (!Number.isFinite(line)) continue;
    const side = sideOf(row.outcome);
    const who = identity(row);
    if (!side || !who || !row.book || !row.player) continue;
    const key = [who.event, row.book, row.market, row.player, side].join('|');
    const prev = latest.get(key);
    if (!prev || quoteNewer(row.at, prev.row.at)) latest.set(key, {row, who, side, line});
  }
  const buckets = new Map();
  for (const item of latest.values()) {
    const key = [item.who.event, item.row.market, item.row.player, item.line].join('|');
    if (!buckets.has(key)) buckets.set(key, []);
    buckets.get(key).push(item);
  }
  const groups = [];
  for (const items of buckets.values()) {
    const byBook = new Map();
    for (const item of items) {
      if (!byBook.has(item.row.book)) byBook.set(item.row.book, {});
      byBook.get(item.row.book)[item.side] = item;
    }
    const fairs = [];
    for (const [book, sides] of byBook) {
      if (!sides.Over || !sides.Under) continue;
      const chance = noVig(sides.Over.row.decimal, sides.Under.row.decimal);
      if (chance == null) continue;
      fairs.push({book, chance, sides});
    }
    if (fairs.length < MIN_BOOKS) continue;
    const consensus = fairs.reduce((sum, item) => sum + item.chance, 0) / fairs.length;
    const flags = [];
    for (const sides of byBook.values()) {
      for (const side of ['Over', 'Under']) {
        const item = sides[side];
        if (!item) continue;
        const chance = side === 'Over' ? consensus : 1 - consensus;
        if (chance < MIN_FAIR || chance > MAX_FAIR) continue;
        const edge = chance * item.row.decimal - 1;
        if (edge < MIN_EDGE) continue;
        flags.push({
          book: item.row.book,
          player: item.row.player,
          market: item.row.market,
          outcome: side,
          line: item.line,
          decimal: item.row.decimal,
          at: item.row.at || '',
          fairChance: chance,
          edge,
          books: fairs.length,
          away: item.who.away,
          home: item.who.home,
          kickoff: item.row.kickoff || '',
          eventId: item.who.event,
        });
      }
    }
    flags.sort((a, b) => b.edge - a.edge || String(a.book).localeCompare(String(b.book)));
    groups.push({
      player: items[0].row.player,
      market: items[0].row.market,
      line: items[0].line,
      eventId: items[0].who.event,
      away: items[0].who.away,
      home: items[0].who.home,
      consensus,
      books: fairs.length,
      flags,
    });
  }
  return groups;
}

export function bookLabel(book) {
  return BOOK_NAMES[String(book || '').toLowerCase()] || book || 'unavailable';
}

export function decimalLabel(value) {
  const text = Number(value).toFixed(6).replace(/0+$/, '').replace(/\.$/, '');
  return text.includes('.') ? text : `${text}.0`;
}

export function americanLabel(decimal) {
  if (!(decimal > 1)) return 'unavailable';
  const value = decimal >= 2 ? (decimal - 1) * 100 : -100 / (decimal - 1);
  const rounded = Math.round(value);
  return `${rounded >= 0 ? '+' : ''}${rounded}`;
}

export function percentLabel(chance) {
  return `${(chance * 100).toFixed(1)}%`;
}

export function lineLabel(line) {
  return String(line);
}

export function recordSentence(record) {
  if (!record || !Number.isFinite(record.scored)) return 'Prop-consensus closing-line record: unavailable.';
  const n = record.scored;
  const gate = '200 scored bets, with the low end of the range above zero, are needed before this is a signal.';
  if (!(n > 0) || !Number.isFinite(record.mean)) {
    return `Prop-consensus closing-line record: ${n} scored bets. ${gate}`;
  }
  const pct = value => `${value >= 0 ? '+' : ''}${(value * 100).toFixed(1)}%`;
  const range = Number.isFinite(record.low) && Number.isFinite(record.high)
    ? ` (90% range ${pct(record.low)} to ${pct(record.high)})` : '';
  const cleared = record.passes ? ' The closing-line record has cleared the 200-bet bar.' : ` ${gate}`;
  return `Prop-consensus closing-line record: ${n} scored bets, average closing-line value ${pct(record.mean)}${range}.${cleared}`;
}

function flagSentence(flag) {
  return `${bookLabel(flag.book)}, ${flag.player} ${flag.outcome} ${lineLabel(flag.line)} at ${americanLabel(flag.decimal)} (decimal ${decimalLabel(flag.decimal)}), consensus fair chance ${percentLabel(flag.fairChance)} from ${flag.books} books, price saved ${flag.at || 'unavailable'}.`;
}

export function marketFromQuestion(question) {
  const text = String(question || '').toLowerCase();
  if (text.includes('reception') && !text.includes('yard')) return 'player_receptions';
  if (text.includes('receiving')) return 'player_reception_yds';
  if (text.includes('rush')) return 'player_rush_yds';
  if (text.includes('anytime')) return 'player_anytime_td';
  if (text.includes('attempt')) return 'player_pass_attempts';
  if (text.includes('completion')) return 'player_pass_completions';
  if (text.includes('touchdown') || /\btds?\b/.test(text)) return 'player_pass_tds';
  if (text.includes('pass')) return 'player_pass_yds';
  return '';
}

function lineFromQuestion(question) {
  const match = String(question || '').match(/\b(?:over|under|line)\s+(-?\d+(?:\.\d+)?)\b/i);
  if (!match) return null;
  const line = Number(match[1]);
  return Number.isFinite(line) ? line : null;
}

export function formatConsensus(observations, {player = '', market = '', line = null, eventId = '', record = null} = {}) {
  let groups = consensusGroups(observations);
  if (player) {
    const wanted = player.toLowerCase();
    groups = groups.filter(group => String(group.player).toLowerCase().includes(wanted) || wanted.includes(String(group.player).toLowerCase()));
  }
  if (market) groups = groups.filter(group => group.market === market);
  if (eventId) {
    const scoped = groups.filter(group => group.eventId === eventId);
    if (scoped.length) groups = scoped;
  }
  if (line != null) groups = groups.filter(group => group.line === line);
  const framing = 'This is a comparison, not a pick.';
  const recordText = recordSentence(record);
  if (market === 'player_anytime_td') {
    return `Best price vs other books: unavailable. Anytime touchdown is one-sided, so there is no two-sided consensus to compare. ${framing} ${recordText}`;
  }
  const matched = (observations || []).filter(row => {
    if (player && !String(row?.player || '').toLowerCase().includes(player.toLowerCase()) && !player.toLowerCase().includes(String(row?.player || '').toLowerCase())) return false;
    if (market && row?.market !== market) return false;
    return true;
  });
  if (!groups.length) {
    const reason = matched.length
      ? 'Fewer than 3 books have a two-sided price on the same line. A different line is not treated as the same chance.'
      : 'No saved price for this prop.';
    return `Best price vs other books: unavailable. ${reason} ${framing} ${recordText}`;
  }
  const flags = groups.flatMap(group => group.flags).sort((a, b) => b.edge - a.edge || String(a.book).localeCompare(String(b.book)));
  if (!flags.length) {
    if (groups.length === 1) {
      const group = groups[0];
      return `Best price vs other books: no saved price pays 3% more than a fair payout at the consensus chance. Consensus fair chance on the over at ${lineLabel(group.line)} is ${percentLabel(group.consensus)} from ${group.books} books. ${framing} ${recordText}`;
    }
    return `Best price vs other books: no saved price pays 3% more than a fair payout at the consensus chance. ${framing} ${recordText}`;
  }
  const shown = flags.slice(0, 4).map(flagSentence).join(' ');
  const extra = flags.length > 4 ? ` ${flags.length - 4} more are not listed.` : '';
  return `Best price vs other books: ${shown}${extra} ${framing} ${recordText}`;
}

export function answerPropConsensus(observations, question, players, record) {
  const names = [
    ...(players || []).map(player => player?.name),
    ...(observations || []).map(row => row?.player),
  ];
  const player = namesInQuestion(question, names);
  const market = marketFromQuestion(question);
  const line = lineFromQuestion(question);
  return formatConsensus(observations, {player, market, line, record});
}
