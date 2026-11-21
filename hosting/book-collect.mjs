/** Logged-out prop collection for the Worker cron.

One slice per run, and only while a pre-kickoff window is open. Raw book
payloads are not stored. A missing price stays absent.
*/

const UA = 'CoachResearch/1.0 (logged-out public odds; +https://addversity.github.io/coach/)';
const FANDUEL_CLIENT = 'FhMFpcPWXMeyZxOx';
const EVEN = 1.909091;
const FETCH_CAP = 6;
const MAX_GAMES = 8;
export const SLOTS = [['T-24h', 24 * 60], ['T-6h', 6 * 60], ['T-3h', 3 * 60], ['T-90m', 90], ['T-30m', 30], ['last', 10]];
const EARLY = {'T-24h': 20, 'T-6h': 20, 'T-3h': 20, 'T-90m': 15, 'T-30m': 10, last: 7};
const LATE = {'T-24h': 30, 'T-6h': 25, 'T-3h': 25, 'T-90m': 20, 'T-30m': 12, last: 9};
const NICK = {cardinals:'ARI',falcons:'ATL',ravens:'BAL',bills:'BUF',panthers:'CAR',bears:'CHI',bengals:'CIN',browns:'CLE',cowboys:'DAL',broncos:'DEN',lions:'DET',packers:'GB',texans:'HOU',colts:'IND',jaguars:'JAX',chiefs:'KC',raiders:'LV',chargers:'LAC',rams:'LAR',dolphins:'MIA',vikings:'MIN',patriots:'NE',saints:'NO',giants:'NYG',jets:'NYJ',eagles:'PHI',steelers:'PIT','49ers':'SF',seahawks:'SEA',buccaneers:'TB',titans:'TEN',commanders:'WAS'};
const KAMBI = {
  'Total Passing Yards by the Player - Including Overtime': 'player_pass_yds',
  'Total Rushing Yards by the Player - Including Overtime': 'player_rush_yds',
  'Total Receiving Yards by the Player - Including Overtime': 'player_reception_yds',
  'Total Receptions by the Player - Including Overtime': 'player_receptions',
  'Total Pass Attempts by the Player - Including Overtime': 'player_pass_attempts',
  'Total Pass Completions by the Player - Including Overtime': 'player_pass_completions',
  'Total Touchdown Passes Thrown by the Player - Including Overtime': 'player_pass_tds',
  'Touchdown Scorer': 'player_anytime_td',
};
const BOVADA = [['Total Player Passing Yards O/U','player_pass_yds'],['Total Rushing Yards O/U','player_rush_yds'],['Total Receiving Yards O/U','player_reception_yds'],['Total Receptions O/U','player_receptions'],['Total Player Passing Attempts O/U','player_pass_attempts'],['Total Passing Completions O/U','player_pass_completions'],['Total Passing Touchdowns O/U','player_pass_tds']];

function num(value) {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string' && value.trim() && Number.isFinite(Number(value))) return Number(value);
  return null;
}
function kambiNumber(value) {
  const n = num(value);
  if (n == null) return null;
  if ((typeof value === 'number' && Number.isInteger(value)) || (typeof value === 'string' && /^\d+$/.test(value)) || n >= 100) return n / 1000;
  return n;
}
export function normalizePerson(name) {
  const parts = String(name || '').toLowerCase().replace(/\([^)]*\)/g, ' ').replace(/[.]/g, ' ').replace(/[^a-z\s'-]/g, ' ').replace(/\b(jr|sr|ii|iii|iv|v)\b/g, ' ').trim().split(/\s+/).filter(Boolean);
  const collapsed = [];
  for (const part of parts) {
    if (collapsed.length && collapsed[collapsed.length - 1].length === 1 && part.length === 1) collapsed[collapsed.length - 1] += part;
    else collapsed.push(part);
  }
  return collapsed.join(' ');
}
export function teamAbbr(label) {
  const text = String(label || '').trim();
  if (!text) return null;
  if (/^[A-Z]{2,3}$/.test(text)) return text === 'LA' ? 'LAR' : text;
  const nick = text.toLowerCase().split(/\s+/).pop().replace(/[^a-z0-9]/g, '');
  return NICK[nick] || null;
}
function iso(value) {
  if (typeof value === 'number' && value > 10_000_000_000) return new Date(value).toISOString().replace('.000Z', 'Z');
  const parsed = Date.parse(value || '');
  return Number.isFinite(parsed) ? new Date(parsed).toISOString().replace('.000Z', 'Z') : null;
}
function row(book, eventId, kickoff, away, home, market, outcome, player, line, decimal, now) {
  if (!(decimal > 1) || decimal > 100 || !outcome || !market) return null;
  return {at: new Date(now).toISOString(), book, eventId: String(eventId || ''), kickoff, away, home, market, outcome, player: player || '', line, decimal: Math.round(decimal * 1e6) / 1e6};
}
export function selectMainLines(rows) {
  const singles = [];
  const groups = new Map();
  for (const item of rows) {
    if (item.market === 'player_anytime_td') { singles.push(item); continue; }
    if (item.line == null || (item.outcome !== 'Over' && item.outcome !== 'Under')) continue;
    const key = [item.book, item.eventId, item.market, item.player, item.line].join('|');
    const list = groups.get(key) || [];
    list.push(item);
    groups.set(key, list);
  }
  const chosen = new Map();
  for (const [key, sides] of groups) {
    const outcomes = new Set(sides.map(item => item.outcome));
    if (!outcomes.has('Over') || !outcomes.has('Under')) continue;
    const over = sides.find(item => item.outcome === 'Over');
    const parts = key.split('|');
    const identity = parts.slice(0, 4).join('|');
    const score = [Math.abs(over.decimal - EVEN), Number(parts[4])];
    const current = chosen.get(identity);
    if (!current || score[0] < current.score[0] || (score[0] === current.score[0] && score[1] < current.score[1])) chosen.set(identity, {score, sides});
  }
  return singles.concat(...[...chosen.values()].map(item => item.sides));
}
function onePlayer(name) {
  const text = String(name || '').trim();
  const lowered = text.toLowerCase();
  return Boolean(text) && !lowered.includes(' or ') && !text.includes('/') && !lowered.endsWith(' defense') && !lowered.includes('d/st');
}
export function parseKambiEvent(payload, now) {
  const events = new Map((payload?.events || []).filter(event => event && typeof event === 'object').map(event => [event.id, event]));
  const rows = [];
  for (const offer of payload?.betOffers || []) {
    const market = KAMBI[(offer?.criterion || {}).englishLabel || ''];
    const event = events.get(offer?.eventId);
    if (!market || !event) continue;
    for (const outcome of offer.outcomes || []) {
      if (['SUSPENDED', 'CLOSED', 'REMOVED'].includes(String(outcome.status || 'OPEN').toUpperCase())) continue;
      const label = outcome.englishLabel || outcome.label || '';
      let side, player, line;
      if (market === 'player_anytime_td') { side = 'Yes'; player = outcome.participant || label; line = 0.5; }
      else if (label === 'Over' || label === 'Under') { side = label; player = outcome.participant || ''; line = kambiNumber(outcome.line); }
      else continue;
      let decimal = kambiNumber(outcome.odds);
      if (!(decimal > 1)) continue;
      const kept = row('betrivers', event.id, iso(event.start), event.awayName, event.homeName, market, side, player, line, decimal, now);
      if (kept && (market === 'player_anytime_td' || kept.line != null)) rows.push(kept);
    }
  }
  return selectMainLines(rows);
}
function bovadaMarket(label) {
  const text = String(label);
  if (['Longest', 'Alternate', '&', 'Most '].some(word => text.includes(word))) return null;
  return BOVADA.find(([prefix]) => text.startsWith(prefix))?.[1] || null;
}
export function parseBovada(payload, now) {
  const rows = [];
  for (const block of Array.isArray(payload) ? payload : [payload || {}]) {
    for (const event of block?.events || []) {
      if (!event || (event.type && event.type !== 'GAMEEVENT')) continue;
      const parts = String(event.description || '').split(/\s+@\s+|\s+v\s+|\s+vs\.?\s+/);
      const away = parts.length === 2 ? parts[0].trim() : null;
      const home = parts.length === 2 ? parts[1].trim() : null;
      for (const group of event.displayGroups || []) {
        for (const market of group.markets || []) {
          const label = market.descriptionKey || market.description || '';
          const kind = bovadaMarket(label);
          const period = market.period?.description || 'Game';
          if (!kind || !['Game', 'G'].includes(period) || ['S', 'SUSPENDED', 'CLOSED'].includes(String(market.status || 'O').toUpperCase())) continue;
          const player = String(label).split(' - ')[1]?.trim() || '';
          for (const outcome of market.outcomes || []) {
            if (['S', 'SUSPENDED', 'CLOSED'].includes(String(outcome.status || 'O').toUpperCase())) continue;
            const side = outcome.description || '';
            if (side !== 'Over' && side !== 'Under') continue;
            const kept = row('bovada', event.id, iso(event.startTime), away, home, kind, side, player, num(outcome.price?.handicap), num(outcome.price?.decimal), now);
            if (kept && kept.line != null) rows.push(kept);
          }
        }
      }
    }
  }
  return selectMainLines(rows);
}
function fanduelMarket(label) {
  const text = String(label || '');
  const lowered = text.toLowerCase();
  if (['alt ', 'alternate', 'longest', 'quarter', 'half', 'most ', 'combined', '1st', '2nd', '3rd', '4th', 'team total'].some(word => lowered.includes(word))) return [null, ''];
  const player = text.includes(' - ') ? text.split(' - ')[0].trim() : '';
  const yards = lowered.includes('yard') || /\byds?\b/.test(lowered);
  if (lowered.includes('pass') && yards && !lowered.includes('rush')) return ['player_pass_yds', player];
  if (lowered.includes('rush') && yards && !lowered.includes('receiv') && !lowered.includes('pass')) return ['player_rush_yds', player];
  if (lowered.includes('receiv') && yards) return ['player_reception_yds', player];
  if (lowered.includes('reception')) return ['player_receptions', player];
  if (lowered.includes('pass') && lowered.includes('attempt')) return ['player_pass_attempts', player];
  if (lowered.includes('completion')) return ['player_pass_completions', player];
  if (lowered.includes('pass') && (lowered.includes('touchdown') || /\btds?\b/.test(lowered))) return ['player_pass_tds', player];
  if (lowered.includes('any time') || lowered.includes('anytime')) return ['player_anytime_td', player];
  return [null, ''];
}
export function parseFanduelPage(payload, now) {
  const attachments = payload?.attachments || {};
  const events = attachments.events || {};
  const rows = [];
  for (const market of Object.values(attachments.markets || {})) {
    const event = events[String(market?.eventId)] || {};
    const [kind, player] = fanduelMarket(market?.marketName || '');
    if (!kind || !event.name) continue;
    const parts = String(event.name).split(/\s+@\s+|\s+v\s+|\s+vs\.?\s+/);
    const away = parts.length === 2 ? parts[0].trim() : null;
    const home = parts.length === 2 ? parts[1].trim() : null;
    for (const runner of market.runners || []) {
      if (['SUSPENDED', 'CLOSED', 'REMOVED'].includes(String(runner.runnerStatus || 'ACTIVE').toUpperCase())) continue;
      const name = runner.runnerName || '';
      const side = name === 'Over' || name.endsWith(' Over') ? 'Over' : name === 'Under' || name.endsWith(' Under') ? 'Under' : null;
      let who, line, outcome;
      if (kind === 'player_anytime_td' && !side) {
        if (!onePlayer(name)) continue;
        outcome = 'Yes'; who = name; line = 0.5;
      } else if (side) { outcome = side; who = player; line = num(runner.handicap); }
      else continue;
      const decimal = num(runner.winRunnerOdds?.trueOdds?.decimalOdds?.decimalOdds);
      const kept = row('fanduel', market.eventId, iso(event.openDate), away, home, kind, outcome, who, line, decimal, now);
      if (kept && (kind === 'player_anytime_td' || kept.line != null)) rows.push(kept);
    }
  }
  return selectMainLines(rows);
}
export function buildRoster(players) {
  const byName = new Map();
  for (const player of players || []) {
    if (!/^00-\d{7}$/.test(String(player?.id || '')) || !player.name) continue;
    const item = {playerId: String(player.id), name: player.name, norm: normalizePerson(player.name), team: String(player.team || '').toUpperCase()};
    const list = byName.get(item.norm) || [];
    list.push(item);
    byName.set(item.norm, list);
  }
  return byName;
}
export function matchPlayer(name, teams, roster) {
  const hits = roster.get(normalizePerson(name)) || [];
  if (hits.length === 1) return hits[0];
  const clubs = new Set((teams || []).filter(Boolean));
  const narrowed = hits.filter(hit => clubs.has(hit.team));
  return narrowed.length === 1 ? narrowed[0] : null;
}
function matchSchedule(away, home, kickoff, events) {
  const start = Date.parse(kickoff || '');
  if (!away || !home || !Number.isFinite(start)) return null;
  let best = null, gap = Infinity;
  for (const event of events || []) {
    if (event.awayCode !== away || event.homeCode !== home) continue;
    const delta = Math.abs(Date.parse(event.startsAt) - start);
    if (delta < gap) { gap = delta; best = event; }
  }
  return best && gap <= 36 * 3600 * 1000 ? best : null;
}
export function attachIdentity(rows, players, events) {
  const roster = buildRoster(players);
  const attached = [];
  for (const item of rows) {
    const away = teamAbbr(item.away), home = teamAbbr(item.home);
    const game = matchSchedule(away, home, item.kickoff, events);
    const next = {...item, away, home};
    if (game) next.eventId = game.id;
    else if (away && home && item.kickoff) next.eventId = `unmatched:${away}:${home}:${item.kickoff}`;
    else continue;
    if (next.eventId.length > 80) continue;
    const player = matchPlayer(item.player, [away, home], roster);
    if (player) { next.player = player.name; next.playerId = player.playerId; }
    attached.push(next);
  }
  return attached;
}
export function slotsToCapture(minutesLeft, attempted) {
  if (!(minutesLeft > 0)) return [];
  const done = new Set(attempted || []);
  const due = [];
  SLOTS.forEach(([name, target], index) => {
    if (done.has(name)) return;
    const onTime = target - LATE[name] <= minutesLeft && minutesLeft <= target + EARLY[name];
    const nextEarly = index + 1 < SLOTS.length ? SLOTS[index + 1][1] + EARLY[SLOTS[index + 1][0]] : 0;
    const missed = minutesLeft < target - LATE[name] && minutesLeft > nextEarly;
    if (onTime || missed) due.push(name);
  });
  return due;
}
export function dueCohort(events, now, cursor) {
  const completed = new Set(cursor?.completed || []);
  if (cursor?.key && cursor.stage !== 'done' && !completed.has(cursor.key) && Array.isArray(cursor.cohort) && cursor.cohort.some(event => Date.parse(event.startsAt) > now)) {
    return {key: cursor.key, slot: cursor.slot, events: cursor.cohort};
  }
  const groups = new Map();
  for (const event of events || []) {
    const start = Date.parse(event?.startsAt || '');
    if (!Number.isFinite(start) || start <= now) continue;
    for (const slot of slotsToCapture((start - now) / 60000, [])) {
      const list = groups.get(slot) || [];
      list.push(event);
      groups.set(slot, list);
    }
  }
  for (const [slot] of SLOTS) {
    const list = groups.get(slot);
    if (!list?.length) continue;
    const ids = list.map(event => event.id).sort();
    const key = `${ids.join(',')}|${slot}`;
    if (completed.has(key)) continue;
    return {key, slot, events: list.slice(0, MAX_GAMES).map(event => ({id: event.id, startsAt: event.startsAt, homeCode: event.homeCode, awayCode: event.awayCode, home: event.home, away: event.away}))};
  }
  return null;
}
function inWindow(kickoff, cohort) {
  const start = Date.parse(kickoff || '');
  if (!Number.isFinite(start)) return false;
  return (cohort?.events || []).some(event => Math.abs(Date.parse(event.startsAt) - start) <= 45 * 60 * 1000);
}
function headers(extra) {
  return {'User-Agent': UA, Accept: 'application/json,text/html;q=0.8', ...extra};
}
async function pull(url, extra, budget) {
  if (budget.left <= 0) return null;
  budget.left -= 1;
  budget.used += 1;
  const response = await budget.fetch(url, {redirect: 'manual', headers: headers(extra)});
  if (!response || response.status !== 200) return {status: response?.status || 0, body: null};
  const text = await response.text();
  try { return {status: 200, body: JSON.parse(text)}; }
  catch { return {status: 200, body: null}; }
}
function fresh(cursor, cohort, completed) {
  if (cursor?.key === cohort.key) return {...cursor, completed};
  return {key: cohort.key, slot: cohort.slot, stage: 'bovada', cursor: 0, games: [], cohort: cohort.events, completed, retried: false};
}
export async function collectSlice(cursor, cohort, players, schedule, fetchImpl, now = Date.now()) {
  const completed = [...(cursor?.completed || [])].slice(-40);
  const state = fresh(cursor, cohort, completed);
  const budget = {fetch: fetchImpl, left: FETCH_CAP, used: 0};
  const rows = [];
  const keep = list => attachIdentity(list.filter(item => inWindow(item.kickoff, cohort)), players, schedule);
  const fail = next => {
    if (!state.retried) { state.retried = true; return; }
    state.retried = false;
    state.stage = next;
    state.cursor = 0;
    state.games = [];
  };
  if (state.stage === 'bovada') {
    const result = await pull('https://www.bovada.lv/services/sports/event/v2/events/A/description/football/nfl', {}, budget);
    if (result?.status === 200 && result.body) { rows.push(...keep(parseBovada(result.body, now))); state.retried = false; state.stage = 'betrivers-list'; }
    else fail('betrivers-list');
  } else if (state.stage === 'betrivers-list') {
    const result = await pull('https://eu-offering-api.kambicdn.com/offering/v2018/rsiusnj/listView/american_football/nfl.json?lang=en_US&market=US', {}, budget);
    const games = [];
    for (const wrapper of result?.body?.events || []) {
      const event = wrapper?.event || wrapper;
      if (!event?.id || !inWindow(iso(event.start), cohort)) continue;
      games.push({id: event.id, kickoff: iso(event.start)});
    }
    if (result?.status === 200) { state.games = games.slice(0, MAX_GAMES); state.cursor = 0; state.retried = false; state.stage = 'betrivers'; }
    else fail('betrivers');
  } else if (state.stage === 'betrivers') {
    const next = (state.games || []).slice(state.cursor || 0, (state.cursor || 0) + 4);
    if (!next.length) { state.stage = 'fanduel-list'; state.cursor = 0; }
    else {
      for (const game of next) {
        const result = await pull(`https://eu-offering-api.kambicdn.com/offering/v2018/rsiusnj/betoffer/event/${game.id}.json?lang=en_US&market=US`, {}, budget);
        if (result?.status === 200 && result.body) rows.push(...keep(parseKambiEvent(result.body, now)));
      }
      state.cursor = (state.cursor || 0) + next.length;
      if (state.cursor >= (state.games || []).length) { state.stage = 'fanduel-list'; state.cursor = 0; }
    }
  } else if (state.stage === 'fanduel-list') {
    const result = await pull(`https://sbapi.nj.sportsbook.fanduel.com/api/content-managed-page?page=CUSTOM&customPageId=nfl&pbHorizontal=false&_ak=${FANDUEL_CLIENT}&timezone=America/New_York`, {'x-sportsbook-region': 'NJ'}, budget);
    const games = [];
    for (const event of Object.values(result?.body?.attachments?.events || {})) {
      if (!event?.eventId || !String(event.name || '').includes('@') || !inWindow(iso(event.openDate), cohort)) continue;
      games.push({id: event.eventId, kickoff: iso(event.openDate)});
    }
    if (result?.status === 200) { state.games = games.slice(0, MAX_GAMES); state.cursor = 0; state.retried = false; state.stage = 'fanduel'; }
    else fail('fanduel');
  } else if (state.stage === 'fanduel') {
    const game = (state.games || [])[state.cursor || 0];
    if (!game) state.stage = 'done';
    else {
      for (const tab of ['passing-props', 'rushing-props', 'receiving-props', 'td-scorer-props']) {
        const result = await pull(`https://sbapi.nj.sportsbook.fanduel.com/api/event-page?_ak=${FANDUEL_CLIENT}&eventId=${game.id}&tab=${tab}`, {'x-sportsbook-region': 'NJ'}, budget);
        if (result?.status === 200 && result.body) rows.push(...keep(parseFanduelPage(result.body, now)));
      }
      state.cursor = (state.cursor || 0) + 1;
      if (state.cursor >= (state.games || []).length) state.stage = 'done';
    }
  }
  if (state.stage === 'done' && !completed.includes(state.key)) completed.push(state.key);
  state.completed = completed.slice(-40);
  return {rows, cursor: state, fetches: budget.used};
}
export function mergeObservations(stored, rows, now) {
  const map = new Map();
  const cutoff = now - 36 * 3600 * 1000;
  for (const item of stored?.observations || []) {
    const kick = Date.parse(item?.kickoff || '');
    if (Number.isFinite(kick) && kick < cutoff) continue;
    map.set([item.book, item.eventId, item.market, item.player, item.outcome].join('|'), item);
  }
  for (const item of rows || []) map.set([item.book, item.eventId, item.market, item.player, item.outcome].join('|'), item);
  let observations = [...map.values()];
  if (observations.length > 5000) {
    observations.sort((a, b) => String(b.at || '').localeCompare(String(a.at || '')));
    observations = observations.slice(0, 5000);
  }
  return {observations};
}
