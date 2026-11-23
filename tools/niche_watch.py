"""Live log for the niche angles in docs/NICHE_EDGES.md, scored by closing line value.

Every angle that fires on an upcoming game is logged with the best price
when Coach first saw it, then scored after kickoff against the close
(tools/edge_log.py). Nothing here changes Coach's picks: an angle becomes a
pick only after 200 scored bets with CLV clearly above zero.

Inputs (all free): nflverse schedule (games.csv) and weekly player stats for
this season and last, the saved Odds API prices (price-history.json), the
Worker's logged-out props (/v1/book-prices), the published coach-index.json
(stadium location) and Open-Meteo forecasts.

Game angles use the side that did better in research/niche/game_angles.json.
Player angles: visiting players at Denver (under), players near a season
milestone in the last two weeks (over), the player's own turf/grass and
indoor/outdoor split, kickers in wind or cold (no free kicker prop prices
yet, so logged without a bet), and sticky prop lines (the line barely moved
from last week while the opponent's defense against that stat changed 10%+).

Output: assets/niche-watch.json. Research, not a pick.
"""

import csv
import io
import json
import statistics
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import edge_log
import weather_watch

SCHEMA = 'coach-niche-watch-v1'
HORIZON_DAYS = 7
GRASS = {'grass', 'dessograss'}
INDOOR = {'dome', 'closed'}
REVENGE_QB_STARTS = 8
REVENGE_COACH_GAMES = 16
REVENGE_PLAYER_GAMES = 8
LATE_WEEKS = 4
OUT_OF_RACE_PCT = 0.55
REST_RISK_PCT = 0.75
SPLIT_SHRINK = 6
SPLIT_FLAG = 0.10
STICKY_LINE = 0.03
STICKY_MATCHUP = 0.10
KICKER_WIND = 15
KICKER_COLD = 32
MILESTONES = {'player_pass_yds': ('passing_yards', 4000), 'player_rush_yds': ('rushing_yards', 1000),
              'player_reception_yds': ('receiving_yards', 1000)}
STAT_OF = {'player_pass_yds': 'passing_yards', 'player_rush_yds': 'rushing_yards',
           'player_reception_yds': 'receiving_yards', 'player_receptions': 'receptions'}
EASTERN = ZoneInfo('America/New_York')


def _f(value):
    try:
        return float(value) if value not in (None, '', 'NA') else None
    except ValueError:
        return None


def read_csv(path):
    text = Path(path).read_text(encoding='utf-8')
    return list(csv.DictReader(io.StringIO(text)))


def kickoff_of(game):
    try:
        local = datetime.strptime(f"{game['gameday']} {game['gametime']}", '%Y-%m-%d %H:%M').replace(tzinfo=EASTERN)
    except (KeyError, ValueError):
        return None
    return local.astimezone(timezone.utc)


# ------------------------------------------------------------------ game context

def regular(games):
    return [g for g in games if g.get('game_type') == 'REG']


def standings(games, season):
    """{team: (wins, losses, ties, games left, season length)} from finished games this season."""
    rows = [g for g in regular(games) if int(g['season']) == season]
    length = max(sum(1 for g in rows if team in (g['home_team'], g['away_team']))
                 for team in {g['home_team'] for g in rows}) if rows else 17
    record = defaultdict(lambda: [0, 0, 0])
    for g in rows:
        result = _f(g.get('result'))
        if result is None:
            continue
        h, a = g['home_team'], g['away_team']
        if result > 0:
            record[h][0] += 1
            record[a][1] += 1
        elif result < 0:
            record[a][0] += 1
            record[h][1] += 1
        else:
            record[h][2] += 1
            record[a][2] += 1
    return {t: (w, l, ti, length - (w + l + ti), length) for t, (w, l, ti) in record.items()}, length


def history_counts(games, season):
    """QB starts and head-coach games per team, from earlier seasons."""
    qb, coach = defaultdict(lambda: defaultdict(int)), defaultdict(lambda: defaultdict(int))
    for g in regular(games):
        if int(g['season']) >= season:
            continue
        for side in ('home', 'away'):
            if g.get(f'{side}_qb_id'):
                qb[g[f'{side}_qb_id']][g[f'{side}_team']] += 1
            if g.get(f'{side}_coach'):
                coach[g[f'{side}_coach']][g[f'{side}_team']] += 1
    return qb, coach


def home_indoor(games, season):
    homes = defaultdict(list)
    for g in regular(games):
        if int(g['season']) == season and g.get('location') == 'Home':
            homes[g['home_team']].append(g.get('roof') in INDOOR)
    return {t: sum(v) / len(v) >= 0.5 for t, v in homes.items() if v}


def thanksgiving(game):
    day = game['gameday']
    return game.get('weekday') == 'Thursday' and day[5:7] == '11' and 22 <= int(day[8:10]) <= 28


def game_angles(game, table, qb, coach, indoor, weather):
    """[(angle name as in research/niche/game_angles.json, market, named side)]."""
    out = []
    surface = (game.get('surface') or '').strip().lower()
    roof = game.get('roof') or ''
    if roof in INDOOR:
        out.append(('venue: dome or closed roof, over', 'totals', 'over'))
    if surface and surface not in GRASS:
        out.append(('venue: artificial turf, over', 'totals', 'over'))
    if game['home_team'] == 'DEN' and game.get('location') == 'Home':
        out.append(('venue: Denver altitude, Denver side', 'spreads', 'home'))
    temp = (weather or {}).get('tempF')
    if roof not in INDOOR and temp is not None and temp <= 32:
        out.append(('venue: freezing (32F or colder), under', 'totals', 'under'))
        if indoor.get(game['away_team']) and not indoor.get(game['home_team']):
            out.append(('venue: dome team outdoors in the cold, home side', 'spreads', 'home'))
    week = int(game['week'])
    if game.get('weekday') == 'Thursday' and week > 1:
        if thanksgiving(game):
            out += [('short week: Thanksgiving, under', 'totals', 'under'),
                    ('short week: Thanksgiving, home side', 'spreads', 'home')]
        else:
            out += [('short week: Thursday, under', 'totals', 'under'),
                    ('short week: Thursday, home side', 'spreads', 'home')]
    hr, ar = _f(game.get('home_rest')), _f(game.get('away_rest'))
    if hr is not None and ar is not None:
        if hr - ar >= 3 and ar <= 6:
            out.append(('short week: rested team against a short-rest team, rested side', 'spreads', 'home'))
        elif ar - hr >= 3 and hr <= 6:
            out.append(('short week: rested team against a short-rest team, rested side', 'spreads', 'away'))
    h_qb = qb[game.get('home_qb_id')][game['away_team']] >= REVENGE_QB_STARTS if game.get('home_qb_id') else False
    a_qb = qb[game.get('away_qb_id')][game['home_team']] >= REVENGE_QB_STARTS if game.get('away_qb_id') else False
    if h_qb != a_qb:
        out.append(('revenge: quarterback against his former team, his side', 'spreads', 'home' if h_qb else 'away'))
    h_c = coach[game.get('home_coach')][game['away_team']] >= REVENGE_COACH_GAMES if game.get('home_coach') else False
    a_c = coach[game.get('away_coach')][game['home_team']] >= REVENGE_COACH_GAMES if game.get('away_coach') else False
    if h_c != a_c:
        out.append(('revenge: head coach against his former team, his side', 'spreads', 'home' if h_c else 'away'))
    h, a = table.get(game['home_team']), table.get(game['away_team'])
    if h and a and h[3] <= LATE_WEEKS:
        best = lambda r: (r[0] + 0.5 * r[2] + r[3]) / r[4]
        pct = lambda r: (r[0] + 0.5 * r[2]) / max(1, r[0] + r[1] + r[2])
        h_out, a_out = best(h) < OUT_OF_RACE_PCT, best(a) < OUT_OF_RACE_PCT
        if h_out != a_out:
            out.append(('late season: team out of the race (approx.), its side', 'spreads', 'home' if h_out else 'away'))
        if h[3] == 1:
            h_rest, a_rest = pct(h) >= REST_RISK_PCT, pct(a) >= REST_RISK_PCT
            if h_rest != a_rest:
                out.append(('late season: final week, team that may rest starters, its side', 'spreads',
                            'home' if h_rest else 'away'))
    return out


OTHER = {'home': 'away', 'away': 'home', 'over': 'under', 'under': 'over'}


def side_to_log(research, angle, named):
    """The side that did better at the opener in the backtest (average CLV of the two periods)."""
    entry = (research or {}).get('angles', {}).get(angle)
    if not entry:
        return named
    avg = lambda label: sum((entry[label][p]['clv']['mean'] or -1) for p in ('find', 'check')) / 2
    return named if avg('named side') >= avg('other side') else OTHER[named]


# ------------------------------------------------------------------ players

def player_table(stats_rows, games_by_id):
    """{name: {'id', 'team', 'position', 'games': [(stat dict, turf, indoor, season, team, opponent)]}}."""
    players = {}
    for r in sorted(stats_rows, key=lambda r: (int(r['season']), int(r['week']))):
        if r.get('season_type') != 'REG':
            continue
        g = games_by_id.get(r.get('game_id')) or {}
        surface = (g.get('surface') or '').strip().lower()
        p = players.setdefault(r['player_display_name'], {'id': r['player_id'], 'games': []})
        p.update({'team': r['team'], 'position': r['position'], 'id': r['player_id']})
        p['games'].append(({k: _f(r.get(k)) for k in STAT_OF.values()},
                           None if not surface else surface not in GRASS, g.get('roof') in INDOOR,
                           int(r['season']), r['team'], r['opponent_team']))
    return players


_ALLOWED = {}


def _allowed_by_game(stats_rows):
    """{(defense, stat): {(season, week): amount allowed}}, built once per stats list."""
    key = id(stats_rows)
    if key not in _ALLOWED:
        table = defaultdict(lambda: defaultdict(float))
        for r in stats_rows:
            if r.get('season_type') != 'REG':
                continue
            for stat in STAT_OF.values():
                table[(r.get('opponent_team'), stat)][(int(r['season']), int(r['week']))] += _f(r.get(stat)) or 0.0
        _ALLOWED.clear()
        _ALLOWED[key] = table
    return _ALLOWED[key]


def allowance(stats_rows, season, week, defense, stat):
    """Per-game amount of one stat the defense allowed: last season (weight 4 games) plus this season so far."""
    by_game = {k: v for k, v in _allowed_by_game(stats_rows).get((defense, stat), {}).items()
               if k[0] == season - 1 or (k[0] == season and k[1] < week)}
    prior = [v for (s, _w), v in by_game.items() if s == season - 1]
    now = [v for (s, _w), v in by_game.items() if s == season]
    if not prior and not now:
        return None
    base = statistics.mean(prior) if prior else statistics.mean(now)
    return (base * 4 + sum(now)) / (4 + len(now))


def _median_line(rows, player, market, before=None, after=None):
    lines = [(r['at'], r['line']) for r in rows if r.get('player') == player and r.get('market') == market
             and r.get('line') is not None and str(r.get('outcome', '')).lower() == 'over'
             and (before is None or str(r.get('kickoff')) < before) and (after is None or str(r.get('kickoff')) >= after)]
    if not lines:
        return None, None
    newest = max(a for a, _ in lines)
    kick = max((str(r.get('kickoff')) for r in rows if r.get('player') == player and r.get('market') == market
                and (before is None or str(r.get('kickoff')) < before) and (after is None or str(r.get('kickoff')) >= after)))
    return statistics.median(l for a, l in lines if a == newest), kick


def player_angles(game, kickoff, rows, players, stats_rows, season, week, season_length, weather):
    """[(angle, market, side, player, extra)] for priced props in this game."""
    out = []
    home, away = game['home_team'], game['away_team']
    priced = {(r.get('player'), r.get('market')) for r in rows if r.get('player') and r.get('away') == away
              and r.get('home') == home and r.get('market') in STAT_OF}
    surface = (game.get('surface') or '').strip().lower()
    turf = None if not surface else surface not in GRASS
    indoor = game.get('roof') in INDOOR
    for name, market in sorted(priced):
        p = players.get(name)
        if not p or p['team'] not in (home, away):
            continue
        stat = STAT_OF[market]
        values = [(g[0][stat], g[1], g[2]) for g in p['games'] if g[0].get(stat) is not None]
        if len(values) < 6:
            continue
        overall = statistics.mean(v for v, _t, _i in values)
        opponent = away if p['team'] == home else home
        if home == 'DEN' and p['team'] != 'DEN' and game.get('location') == 'Home':
            out.append(('venue: visiting player at Denver altitude', market, 'under', name, {}))
        if overall > 0:
            for flag, label, value in ((turf, 'turf' if turf else 'grass', 1), (indoor, 'indoors' if indoor else 'outdoors', 2)):
                if flag is None:
                    continue
                same = [v[0] for v in values if v[value] == flag]
                ratio = (sum(same) + SPLIT_SHRINK * overall) / (len(same) + SPLIT_SHRINK) / overall
                if abs(ratio - 1) >= SPLIT_FLAG:
                    angle = f'venue: own split on {label}' if value == 1 else f'venue: own split {label}'
                    out.append((angle, market, 'over' if ratio > 1 else 'under', name, {'splitRatio': round(ratio, 3)}))
        if market in MILESTONES and week >= season_length - 1:
            goal = MILESTONES[market][1]
            so_far = sum(g[0][stat] or 0 for g in p['games'] if g[3] == season)
            if so_far < goal <= so_far + 1.5 * overall:
                out.append(('milestone: within reach in the last two weeks', market, 'over', name,
                            {'seasonSoFar': so_far, 'goal': goal}))
        former = defaultdict(int)
        for g in p['games']:
            if g[3] < season:
                former[g[4]] += 1
        if former.get(opponent, 0) >= REVENGE_PLAYER_GAMES and opponent != p['team']:
            out.append(('revenge: player against a former team', market, 'over', name, {}))
        if game.get('weekday') == 'Thursday' and week > 1:
            out.append(('short week: Thanksgiving' if thanksgiving(game) else 'short week: Thursday', market, 'under', name, {}))
        # Sticky line: this week's line against the player's line for his previous game.
        now_line, _ = _median_line(rows, name, market, after=edge_log.iso(kickoff - timedelta(hours=1)))
        last_line, last_kick = _median_line(rows, name, market, before=edge_log.iso(kickoff - timedelta(days=3)))
        if now_line and last_line and last_kick:
            last_game = [g for g in p['games'] if g[3] == season]
            last_opp = last_game[-1][5] if last_game else None
            a_now = allowance(stats_rows, season, week, opponent, stat)
            a_before = allowance(stats_rows, season, week - 1, last_opp, stat) if last_opp else None
            if a_now and a_before:
                matchup = a_now / a_before - 1
                move = now_line / last_line - 1
                if abs(move) <= STICKY_LINE and abs(matchup) >= STICKY_MATCHUP:
                    out.append(('sticky line: matchup changed, line did not', market, 'over' if matchup > 0 else 'under',
                                name, {'lineBefore': last_line, 'lineNow': now_line, 'matchupChange': round(matchup, 3)}))
    roof = game.get('roof') or ''
    if roof not in INDOOR and weather and ((weather.get('windMph') or 0) >= KICKER_WIND
                                           or (weather.get('tempF') is not None and weather['tempF'] <= KICKER_COLD)):
        for team in (home, away):
            out.append(('kicker: wind or cold, kicking points under', 'player_kicking_points', 'under', f'{team} kicker',
                        {'weather': weather}))
    return out


# ------------------------------------------------------------------ build

def build(games, stats_rows, rows, index, research, now, fetch=None):
    upcoming = []
    for g in regular(games):
        kickoff = kickoff_of(g)
        if kickoff and now < kickoff <= now + timedelta(days=HORIZON_DAYS) and _f(g.get('result')) is None:
            upcoming.append((kickoff, g))
    if not upcoming:
        return []
    season = int(upcoming[0][1]['season'])
    table, length = standings(games, season)
    qb, coach = history_counts(games, season)
    indoor = home_indoor(games, season)
    games_by_id = {g['game_id']: g for g in games}
    players = player_table(stats_rows, games_by_id)
    places = {(e.get('awayCode'), e.get('homeCode')): e for e in (index or {}).get('events') or []}
    current = []
    for kickoff, g in upcoming:
        away, home = g['away_team'], g['home_team']
        weather = None
        place = places.get((away, home))
        if place and place.get('latitude') is not None and (g.get('roof') or '') not in INDOOR:
            try:
                weather = weather_watch.game_window(weather_watch.forecast(place['latitude'], place['longitude'], fetch), kickoff)
            except Exception:  # noqa: BLE001 - no forecast means no weather angle
                weather = None
        base = {'away': away, 'home': home, 'kickoff': edge_log.iso(kickoff), 'checkedAt': edge_log.iso(now)}
        for angle, market, named in game_angles(g, table, qb, coach, indoor, weather):
            side = side_to_log(research, angle, named)
            row = {**base, 'angle': angle, 'side': side, 'player': ''}
            bet = edge_log.best_price(rows, away, home, market, side, now=now)
            if bet:
                row['bet'] = bet
            current.append(row)
        for angle, market, side, player, extra in player_angles(g, kickoff, rows, players, stats_rows, season,
                                                                int(g['week']), length, weather):
            row = {**base, 'angle': angle, 'side': side, 'player': player, 'market': market, **extra}
            bet = edge_log.best_price(rows, away, home, market, side, player=player, now=now)
            if bet:
                row['bet'] = bet
            else:
                row['noPrice'] = 'no free price for this market yet'
            current.append(row)
    return current


def main(argv=None):
    import argparse
    parser = argparse.ArgumentParser(description='Niche angles, logged and scored by CLV.')
    parser.add_argument('--schedule', required=True, help='nflverse games.csv')
    parser.add_argument('--stats', nargs='+', default=[], help='nflverse stats_player_week CSVs (last season and this one)')
    parser.add_argument('--history', default='assets/price-history.json')
    parser.add_argument('--book-prices', default=None)
    parser.add_argument('--index', default=None)
    parser.add_argument('--research', default='research/niche/game_angles.json')
    parser.add_argument('--output', default='assets/niche-watch.json')
    args = parser.parse_args(argv)
    now = datetime.now(timezone.utc)
    path = Path(args.output)
    log = json.loads(path.read_text()) if path.exists() else {'schema': SCHEMA, 'alerts': []}
    rows = edge_log.normalize(json.loads(Path(args.history).read_text()).get('observations'))
    if args.book_prices and Path(args.book_prices).exists():
        rows += edge_log.normalize(json.loads(Path(args.book_prices).read_text()).get('observations'))
    stats_rows = [r for p in args.stats if Path(p).exists() for r in read_csv(p)]
    index = json.loads(Path(args.index).read_text()) if args.index and Path(args.index).exists() else None
    research = json.loads(Path(args.research).read_text()) if Path(args.research).exists() else None
    current = build(read_csv(args.schedule), stats_rows, rows, index, research, now)
    added = edge_log.merge(log, current, ('away', 'home', 'kickoff', 'angle', 'player', 'market'))
    log.update({'schema': SCHEMA, 'checkedAt': edge_log.iso(now), 'current': current,
                'summary': edge_log.score(log, rows, now),
                'notice': 'Niche angles with the price when first seen, scored by closing line value. Research, not a pick.'})
    path.write_text(json.dumps(log, indent=1) + '\n')
    print(json.dumps({'signals': len(current), 'priced': sum(1 for r in current if r.get('bet')), 'new': added}))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
