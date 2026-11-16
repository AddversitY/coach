"""Conditional workload research, whole-week walk-forward, no odds requests.

Settings are selected before season 2025. All later-season candidates are
reported, never tuned against the evaluation results. Historical injury files,
retrospective starter names and future player appearances are not features.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
VERSION = 'workload-ridge-v1'
RIDGES = (1., 10., 100.)
SELECTION_BEFORE = 2025
MIN_TRAIN = 200
MIN_ERRORS = 120
GROUPS = {'QB_attempts': ('QB', 'attempts', 40., 40., 100.),
          'QB_carries': ('QB', 'carries', 8., 35., 60.),
          'RB_carries': ('RB', 'carries', 20., 35., 60.),
          'RB_targets': ('RB', 'targets', 4., 35., 40.),
          'WR_targets': ('WR', 'targets', 8., 35., 40.),
          'TE_targets': ('TE', 'targets', 6., 35., 40.)}
FEATURES = ['intercept', 'recent3', 'prior3', 'weighted10', 'last', 'trend',
            'teamRecent3', 'shareTimesTeam', 'recordedShare', 'appearanceGapWeeks',
            'missingRecentTeamFraction', 'coefficientOfVariation', 'home',
            'restWeeks', 'observedQuarterbackChange', 'opponentRecentOpportunities',
            'missingTeamContext']


def code(value):
    return {'LA': 'LAR', 'OAK': 'LV', 'SD': 'LAC', 'STL': 'LAR', 'WSH': 'WAS'}.get(value, value)


def feature_pack(history, team_games, opponent_games, day, group, home):
    position, metric, scale, team_scale, cap = GROUPS[group]
    # Caller supplies one contiguous same-team/position segment.
    rows = sorted([r for r in history if r['date'] < str(day) and
                   0 < (day-date.fromisoformat(r['date'])).days <= 730],
                  key=lambda r: r['date'], reverse=True)[:10]
    if len(rows) < 6 or (day-date.fromisoformat(rows[0]['date'])).days > 35:
        return None
    values = [r['stats'][metric] for r in rows]
    weights = [.5**(i/4) for i in range(len(rows))]
    weighted = sum(w*v for w, v in zip(weights, values))/sum(weights)
    if weighted <= 0:
        return None
    recent, prior = sum(values[:3])/3, sum(values[3:6])/3
    incumbent = min(weighted*1.25, max(weighted*.75, .65*recent+.35*weighted))
    team_games = sorted([g for g in team_games if g['date'] < str(day)], key=lambda g: g['date'], reverse=True)[:6]
    other = sorted([g for g in opponent_games if g['date'] < str(day)], key=lambda g: g['date'], reverse=True)[:3]
    team_recent = team_games[:3]
    team_volume = sum(g[metric] for g in team_recent)/len(team_recent) if team_recent else 0.
    paired = [(r, next((g for g in team_games if g['date'] == r['date'] and g['week'] == r['week']), None)) for r in rows[:3]]
    denominator = sum(g[metric] for _, g in paired if g)
    share = sum(r['stats'][metric] for r, g in paired if g)/denominator if denominator else 0.
    dates = {r['date'] for r in rows}
    missing = sum(g['date'] not in dates for g in team_recent)/len(team_recent) if team_recent else 0.
    mu = sum(values)/len(values)
    variation = min(3., math.sqrt(sum((v-mu)**2 for v in values)/len(values))/(mu+.1))
    leaders = [g.get('leader') for g in team_recent if g.get('leader')]
    changed = float(len(set(leaders)) > 1)
    opp = [g.get('allowed_'+metric) for g in other if g.get('allowed_'+metric) is not None]
    opponent_volume = sum(opp)/len(opp) if opp else 0.
    gap = (day-date.fromisoformat(rows[0]['date'])).days/7
    rest = min(21, (day-date.fromisoformat(team_games[0]['date'])).days)/7 if team_games else 0.
    x = [1., recent/scale, prior/scale, weighted/scale, values[0]/scale,
         (recent-prior)/scale, team_volume/team_scale, share*team_volume/scale,
         share, gap, missing, variation, float(home), rest, changed,
         opponent_volume/team_scale, float(not denominator or not opp)]
    return dict(x=x, incumbent=incumbent, last3=recent, last6=sum(values[:6])/6,
                records=len(rows), latestDate=rows[0]['date'], metric=metric,
                position=position, cap=cap)


def examples(dataset, history, schedule, *, extra_stats=(), augment=None):
    metadata = dataset.get('metadata', dataset)
    cutoff = min(metadata['cutoff'], history['cutoff'])
    closing = {r['game_id']: r for r in schedule}
    fixtures = [dict(g, home=code(g['home']), away=code(g['away'])) for g in history['games']
                if g['date'] <= cutoff and closing.get(g['id'], {}).get('game_type') == 'REG']
    weeks = sorted({(g['season'], g['week']) for g in fixtures})
    records = defaultdict(list)
    seen = set()
    for raw in dataset['rows']:
        if raw['seasonType'] != 'REG' or raw['date'] > cutoff:
            continue
        key = (raw['playerId'], code(raw['team']), raw['season'], raw['week'], raw['date'])
        if key in seen:
            raise ValueError('Duplicate player/game source row')
        seen.add(key)
        if isinstance(raw['stats'],list) and len(raw['stats'])!=len(dataset.get('statKeys',[])):
            raise ValueError('Invalid packed workload source')
        stats = dict(zip(dataset.get('statKeys', []), raw['stats'])) if isinstance(raw['stats'], list) else raw['stats']
        if not all(k in stats for k in ['attempts','carries','targets']):
            raise ValueError('Missing workload source field')
        if not all(k in stats for k in extra_stats):
            raise ValueError('Missing production source field')
        stats = {k: stats[k] for k in ['attempts', 'carries', 'targets', *extra_stats]}
        if any(isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) or v < 0 for k,v in stats.items() if k in ['attempts','carries','targets','receptions']):
            raise ValueError('Invalid workload label')
        if any(isinstance(v,bool) or not isinstance(v,(int,float)) or not math.isfinite(v) for v in stats.values()):
            raise ValueError('Invalid production label')
        records[(raw['season'], raw['week'])].append(dict(raw, team=code(raw['team']), stats=stats))
    states, team_states, all_examples = {}, defaultdict(list), []
    for season, week in weeks:
        games = [g for g in fixtures if (g['season'], g['week']) == (season, week)]
        day = min(date.fromisoformat(g['date']) for g in games)
        by_team = {t: g for g in games for t in [g['home'], g['away']]}
        actual = {(r['playerId'], r['team'], r['date']): r for r in records[(season, week)]}
        for player_id, segment in states.items():
            latest = segment[-1]
            game = by_team.get(latest['team'])
            if not game:
                continue
            opponent = game['away'] if latest['team'] == game['home'] else game['home']
            for group, (position, _, _, _, _) in GROUPS.items():
                if latest['position'] != position:
                    continue
                pack = feature_pack(segment, team_states[(season, latest['team'])], team_states[(season, opponent)],
                                    date.fromisoformat(game['date']), group, latest['team'] == game['home'])
                if not pack:
                    continue
                if augment is not None:
                    extra=augment(segment,team_states[(season,latest['team'])],team_states[(season,opponent)],date.fromisoformat(game['date']),group)
                    if extra is None:continue
                    pack.update(extra)
                result = actual.get((player_id, latest['team'], game['date']))
                all_examples.append(dict(pack, playerId=player_id, team=latest['team'],
                                         eventId='nflverse:'+game['id'], season=season, week=week,
                                         date=game['date'], group=group,
                                         actualStats=result['stats'] if result else None,
                                         y=result['stats'][pack['metric']] if result else None))
        for example in [r for r in all_examples if (r['season'],r['week'])==(season,week)]:
            candidates=[r for r in records[(season,week)] if r['team']==example['team'] and r['position']=='QB' and r['stats']['attempts']>0]
            candidates.sort(key=lambda r:(-r['stats']['attempts'],r['playerId']))
            example['actualLeader']=candidates[0]['playerId'] if candidates else None
        # Every forecast in this whole week is fixed before any labels enter.
        totals = {}
        for raw in records[(season, week)]:
            game = by_team.get(raw['team'])
            if not game or raw['date'] != game['date']:
                continue
            row = totals.setdefault(raw['team'], dict(team=raw['team'], date=raw['date'], week=week,
                                                      attempts=0., carries=0., targets=0., leader=None, leaderAttempts=-1))
            for metric in ['attempts', 'carries', 'targets', *extra_stats]:
                row.setdefault(metric,0.)
                row[metric] += raw['stats'][metric]
            if raw['position'] == 'QB' and raw['stats']['attempts'] > 0 and (raw['stats']['attempts'] > row['leaderAttempts'] or raw['stats']['attempts'] == row['leaderAttempts'] and raw['playerId'] < row['leader']):
                row['leader'], row['leaderAttempts'] = raw['playerId'], raw['stats']['attempts']
            prior = states.get(raw['playerId'], [])
            if prior and (prior[-1]['team'] != raw['team'] or prior[-1]['position'] != raw['position']):
                prior = []
            states[raw['playerId']] = (prior+[raw])[-10:]
        for team, row in totals.items():
            game = by_team[team]
            other = totals.get(game['away'] if team == game['home'] else game['home'])
            for metric in ['attempts', 'carries', 'targets', *extra_stats]:
                row['allowed_'+metric] = other[metric] if other else None
            team_states[(season, team)] = (team_states[(season, team)]+[row])[-6:]
    return all_examples, cutoff


def fit(rows, day, ridge):
    rows = [r for r in rows if r['y'] is not None and 0 < (day-date.fromisoformat(r['date'])).days <= 730]
    if len(rows) < MIN_TRAIN:
        raise ValueError('Insufficient earlier workload labels')
    x = np.array([r['x'] for r in rows])
    y = np.array([r['y']-r['incumbent'] for r in rows])
    weights = np.array([.5**((day-date.fromisoformat(r['date'])).days/365) for r in rows])
    coefficients = np.linalg.solve(x.T@(weights[:, None]*x)+ridge*np.eye(len(FEATURES)), x.T@(weights*y))
    return coefficients, len(rows)


def walk_forward(rows, ridge):
    prior, errors, predictions = [], [], []
    for season, week in sorted({(r['season'], r['week']) for r in rows}):
        batch = [r for r in rows if (r['season'], r['week']) == (season, week)]
        try:
            coefficients, _ = fit(prior, min(date.fromisoformat(r['date']) for r in batch), ridge)
        except ValueError:
            prior.extend(batch)
            continue
        interval = np.quantile(errors[-1000:], [.1, .9]).tolist() if len(errors) >= MIN_ERRORS else None
        new_errors = []
        for r in batch:
            p = float(np.clip(r['incumbent']+np.dot(r['x'], coefficients), 0, r['cap']))
            bounds = [max(0., min(r['cap'], p+e)) for e in interval] if interval else None
            predictions.append(dict(r, prediction=p, interval=bounds))
            if r['y'] is not None:
                new_errors.append(r['y']-p)
        errors.extend(new_errors)
        prior.extend(batch)
    return predictions, errors[-1000:]


def mae(rows, key):
    return sum(abs(r[key]-r['y']) for r in rows)/len(rows) if rows else None


def summary(rows):
    recorded = [r for r in rows if r['y'] is not None]
    if not recorded:
        return dict(eligible=len(rows), recorded=0, unresolved=len(rows), adopted=False, hasEdge=False)
    blocks = defaultdict(list)
    for r in recorded:
        blocks[(r['season'], r['week'])].append(abs(r['prediction']-r['y'])-abs(r['incumbent']-r['y']))
    ci = None
    if len(blocks) >= 12:
        sums, sizes = np.array([sum(v) for v in blocks.values()]), np.array([len(v) for v in blocks.values()])
        picks = np.random.default_rng(20261116).integers(0, len(sums), (2000, len(sums)))
        ci = [float(v) for v in np.quantile(sums[picks].sum(axis=1)/sizes[picks].sum(axis=1), [.025, .975])]
    intervals = [r for r in recorded if r['interval']]
    return dict(eligible=len(rows), recorded=len(recorded), unresolved=len(rows)-len(recorded),
                weeks=len(blocks), mae=mae(recorded, 'prediction'), incumbentMae=mae(recorded, 'incumbent'),
                last3Mae=mae(recorded, 'last3'), last6Mae=mae(recorded, 'last6'),
                rmse=math.sqrt(sum((r['prediction']-r['y'])**2 for r in recorded)/len(recorded)),
                incumbentRmse=math.sqrt(sum((r['incumbent']-r['y'])**2 for r in recorded)/len(recorded)),
                bias=sum(r['prediction']-r['y'] for r in recorded)/len(recorded), pairedMaeDifference95=ci,
                intervalCount=len(intervals), interval80Coverage=sum(r['interval'][0] <= r['y'] <= r['interval'][1] for r in intervals)/len(intervals) if intervals else None,
                adopted=False, hasEdge=False)


def select_ridge(rows):
    development = [r for r in rows if r['season'] < SELECTION_BEFORE]
    candidates = []
    for ridge in RIDGES:
        predictions, _ = walk_forward(development, ridge)
        scored = [r for r in predictions if r['y'] is not None]
        candidates.append(dict(ridge=ridge, recorded=len(scored), mae=mae(scored, 'prediction')))
    eligible = [r for r in candidates if r['recorded'] >= 100]
    return (min(eligible, key=lambda r: (r['mae'], r['ridge']))['ridge'] if eligible else None), candidates


def run(dataset, history, schedule):
    rows, cutoff = examples(dataset, history, schedule)
    models, validation = {}, {}
    for group, spec in GROUPS.items():
        data = [r for r in rows if r['group'] == group]
        selected, candidates = select_ridge(data)
        if selected is None:
            continue
        predictions, errors = walk_forward(data, selected)
        evaluation = [r for r in predictions if r['season'] >= SELECTION_BEFORE]
        report = summary(evaluation)
        ci = report.get('pairedMaeDifference95')
        gate = bool(report.get('recorded', 0) >= 200 and ci and ci[1] < 0 and
                    report['mae'] < min(report['incumbentMae'], report['last3Mae'], report['last6Mae']) and
                    report['rmse'] < report['incumbentRmse'])
        report.update(selectedRidge=selected, developmentCandidates=candidates, clearedHistoricalGate=gate,
                      seasons={str(s): summary([r for r in evaluation if r['season'] == s]) for s in sorted({r['season'] for r in evaluation})})
        validation[group] = report
        coefficients, n = fit(data, date.fromisoformat(cutoff)+timedelta(days=1), selected)
        models[group] = dict(position=spec[0], metric=spec[1], scale=spec[2], teamScale=spec[3], cap=spec[4], ridge=selected,
                             coefficients=[round(float(x), 10) for x in coefficients], trainingRows=n,
                             residuals=[round(float(e), 6) for e in errors], status='shadow_only')
    if not models:
        raise ValueError('No workload candidate has enough earlier labels')
    return dict(schemaVersion=1, version=VERSION, cutoff=cutoff, trainedAt=datetime.now(timezone.utc).isoformat(),
                sourceHashes={name: hashlib.sha256(json.dumps(d, sort_keys=True).encode()).hexdigest() for name, d in [('players', dataset), ('history', history)]},
                featureNames=FEATURES, models=models, validation=validation, adopted=False, hasEdge=False,
                protocol=dict(selectionSeasonsBefore=SELECTION_BEFORE, evaluationSeasonsFrom=SELECTION_BEFORE,
                              minPriorAppearances=6, maximumAppearanceGapDays=35, minTrainingLabels=MIN_TRAIN,
                              fitWindowDays=730, fitHalfLifeDays=365, ridgeGrid=RIDGES,
                              cohort='Eligible same-team/position segments formed before the entire test week. Recorded appearances only; absent/mismatched-team rows remain unresolved, never zero.',
                              features='Earlier box scores and team opportunities only. No retrospective starting-QB names, injury assumptions, current-game totals or player appearances.',
                              intervals='Earlier out-of-sample residuals only. Conditional central 80% empirical ranges, not guaranteed coverage.',
                              uncertainty='Exploratory paired week-block bootstrap; not adjusted for six groups or all research choices.',
                              baseline='Serving recency-weighting formula applied to workload records, plus last-three and last-six means. Not a comparison with live yardage probabilities.',
                              limits='Retrospective source vintage and schedule; not a historical point-in-time data archive. No price/ROI, participation probability, yardage edge or AI-superiority claim. No automatic model promotion.'))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--players', type=Path, default=ROOT/'assets/nfl-player-stats.json')
    parser.add_argument('--history', type=Path, default=ROOT/'assets/nfl-history.json')
    parser.add_argument('--schedule', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT/'assets/workload-model.json')
    args = parser.parse_args()
    with args.schedule.open(encoding='utf-8-sig', newline='') as f:
        schedule = list(csv.DictReader(f))
    model = run(json.loads(args.players.read_text(encoding='utf-8-sig')), json.loads(args.history.read_text(encoding='utf-8-sig')), schedule)
    args.output.write_text(json.dumps(model, separators=(',', ':'), allow_nan=False)+'\n', encoding='utf-8')
    print(json.dumps({g: {k: r.get(k) for k in ['recorded', 'unresolved', 'mae', 'incumbentMae', 'last3Mae', 'last6Mae', 'interval80Coverage', 'clearedHistoricalGate']} for g, r in model['validation'].items()}))


if __name__ == '__main__':
    main()
