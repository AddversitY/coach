"""Retrospective challenger selection, with later seasons excluded from selection.

Never changes the serving model. No new odds calls or historical AI inventions.
All grid members, the split and the objective are declared here, not selected
after inspecting the later-season report. Earlier v1 aggregates already covered
these years: this is retrospective validation, not a fresh prospective trial.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import numpy as np

from game_forecast import (ROOT, TEAMS, MIN_TRAIN, MIN_ERRORS, MAX_ERRORS,
                          before, chances, draws, fair, fit, project, team)

VERSION = 'forecast-lab-v1'
EVALUATION_START = 2025
GRID = tuple({'ridge': ridge, 'halfLifeDays': half}
             for ridge in (2., 8., 40.) for half in (90., 180.))
INCUMBENT = {'ridge': 40., 'halfLifeDays': 180.}
MARKETS = ('moneyline', 'spreads', 'totals')


def prepare(history, schedule):
    closing = {r['game_id']: r for r in schedule}
    rows = []
    for raw in history['games']:
        if raw['date'] > history['cutoff'] or team(raw['home']) not in TEAMS or team(raw['away']) not in TEAMS:
            continue
        source = closing.get(raw['id'], {})
        rows.append(dict(raw, home=team(raw['home']), away=team(raw['away']),
                         neutral=source.get('location') == 'Neutral', closing=source))
    return sorted(rows, key=lambda r: (r['season'], r['week'], r['date'], r['id']))


def walk_forward(rows, spec):
    errors, forecasts = [], []
    for season, week in sorted({(r['season'], r['week']) for r in rows}):
        testing = [r for r in rows if (r['season'], r['week']) == (season, week)]
        earlier = [r for r in rows if before(r, season, week)]
        if len(earlier) < MIN_TRAIN:
            continue
        day = min(date.fromisoformat(r['date']) for r in testing)
        try:
            coef, _ = fit(earlier, day, ridge=spec['ridge'], half_life=spec['halfLifeDays'])
        except ValueError:
            continue
        # A week's labels enter the error bank only after all its forecasts.
        frozen = errors[-MAX_ERRORS:]
        next_errors = []
        for row in testing:
            means = project(coef, row['home'], row['away'], row['neutral'])
            residual = [row['homeScore']-means[0], row['awayScore']-means[1]]
            next_errors.append(residual)
            scored = dict(id=row['id'], season=season, week=week,
                          squaredError=sum(e*e for e in residual)/2,
                          absoluteError=sum(abs(e) for e in residual)/2, residual=residual, markets={})
            if len(frozen) >= MIN_ERRORS:
                sample = draws(means, frozen)
                c = row['closing']
                for market in MARKETS:
                    try:
                        line = -float(c['spread_line']) if market == 'spreads' else float(c['total_line']) if market == 'totals' else 0.
                    except (ValueError, KeyError, TypeError):
                        continue
                    if not math.isfinite(line):
                        continue
                    actual = row['homeScore']-row['awayScore']+line if market == 'spreads' else row['homeScore']+row['awayScore']-line if market == 'totals' else row['homeScore']-row['awayScore']
                    if actual == 0:
                        continue
                    pair = ('home_moneyline', 'away_moneyline') if market == 'moneyline' else ('home_spread_odds', 'away_spread_odds') if market == 'spreads' else ('over_odds', 'under_odds')
                    baseline = fair(c.get(pair[0]), c.get(pair[1]))
                    # Report actual paired prices only; no 50% fallback hidden
                    # inside the market comparison.
                    if baseline is None or not math.isfinite(baseline):
                        continue
                    win, push = chances(sample, market, line)
                    scored['markets'][market] = dict(p=win/max(1e-9, 1-push),
                                                    baseline=baseline, y=int(actual > 0))
            forecasts.append(scored)
        errors.extend(next_errors)
    return forecasts


def select_spec(development):
    """Input is restricted to earlier seasons even if a caller passes more."""
    candidates = []
    for spec, rows in development:
        earlier = [r for r in rows if r['season'] < EVALUATION_START]
        if len(earlier) < 100:
            raise ValueError('Insufficient development games')
        candidates.append(dict(spec=spec, games=len(earlier),
                               scoreMse=sum(r['squaredError'] for r in earlier)/len(earlier)))
    chosen = min(candidates, key=lambda c: (c['scoreMse'], c['spec']['ridge'], c['spec']['halfLifeDays']))
    return chosen['spec'], candidates


def block_interval(rows, key, repetitions=2000):
    """Paired mean difference; resample whole season/week blocks, not bets."""
    groups = {}
    for r in rows:
        groups.setdefault((r['season'], r['week']), []).append(r[key])
    if len(groups) < 12:
        return None
    sums = np.array([sum(v) for v in groups.values()])
    sizes = np.array([len(v) for v in groups.values()])
    rng = np.random.default_rng(20261116)
    picks = rng.integers(0, len(sums), size=(repetitions, len(sums)))
    samples = sums[picks].sum(axis=1)/sizes[picks].sum(axis=1)
    return [float(v) for v in np.quantile(samples, [.025, .975])]


def compare(challenger, incumbent):
    lookup = {r['id']: r for r in incumbent}
    markets = {}
    for market in MARKETS:
        pairs = []
        for r in challenger:
            old = lookup.get(r['id'], {})
            if market not in r['markets'] or market not in old.get('markets', {}):
                continue
            c, v = r['markets'][market], old['markets'][market]
            y, p, base, prior = c['y'], c['p'], c['baseline'], v['p']
            loss = lambda x: -math.log(max(1e-6, min(1-1e-6, x if y else 1-x)))
            pairs.append(dict(season=r['season'], week=r['week'], p=p, y=y,
                              brier=(p-y)**2, marketBrier=(base-y)**2,
                              incumbentBrier=(prior-y)**2, logLoss=loss(p),
                              marketLogLoss=loss(base), incumbentLogLoss=loss(prior),
                              marketDifference=(p-y)**2-(base-y)**2,
                              incumbentDifference=(p-y)**2-(prior-y)**2))
        if not pairs:
            continue
        mean = lambda key: sum(r[key] for r in pairs)/len(pairs)
        calibration = []
        for low in range(0, 100, 10):
            bucket = [r for r in pairs if low/100 <= r['p'] < (low+10)/100 or low == 90 and r['p'] == 1]
            if bucket:
                calibration.append(dict(fromProbability=low/100, games=len(bucket),
                                        predicted=sum(r['p'] for r in bucket)/len(bucket),
                                        observed=sum(r['y'] for r in bucket)/len(bucket)))
        markets[market] = dict(games=len(pairs),
                              **{k: mean(k) for k in ('brier', 'marketBrier', 'incumbentBrier', 'logLoss', 'marketLogLoss', 'incumbentLogLoss')},
                              marketDifference95=block_interval(pairs, 'marketDifference'),
                              incumbentDifference95=block_interval(pairs, 'incumbentDifference'),
                              calibration=calibration)
    return markets


def run(history, schedule):
    rows = prepare(history, schedule)
    # Parameter search gets no later-season outcomes at all.
    development = [r for r in rows if r['season'] < EVALUATION_START]
    selected, candidates = select_spec([(s, walk_forward(development, s)) for s in GRID])
    challenger = walk_forward(rows, selected)
    incumbent = challenger if selected == INCUMBENT else walk_forward(rows, INCUMBENT)
    later = [r for r in challenger if r['season'] >= EVALUATION_START]
    if len(later) < 100:
        raise ValueError('Insufficient later-season evaluation')
    comparison = compare(later, incumbent)
    beats_incumbent = bool(comparison) and all(r['brier'] < r['incumbentBrier'] and r['logLoss'] < r['incumbentLogLoss'] for r in comparison.values())
    beats_market = len(comparison) == 3 and all(r['brier'] < r['marketBrier'] and r['logLoss'] < r['marketLogLoss'] and r['marketDifference95'] is not None and r['marketDifference95'][1] < 0 for r in comparison.values())
    coefficients, training_games = fit(rows, date.fromisoformat(history['cutoff'])+timedelta(days=1),
                                       ridge=selected['ridge'], half_life=selected['halfLifeDays'])
    shadow = dict(schemaVersion=1, version=f"score-shadow-r{selected['ridge']:g}-h{selected['halfLifeDays']:g}-v1",
                  cutoff=history['cutoff'], trainedAt=datetime.now(timezone.utc).isoformat(), teams=TEAMS,
                  coefficients=[round(float(x), 8) for x in coefficients],
                  residuals=[[round(v, 5) for v in r['residual']] for r in challenger[-MAX_ERRORS:]],
                  trainingGames=training_games, specification=selected,
                  baselineHomeWin=sum(r['homeScore']>r['awayScore'] for r in rows)/len(rows),
                  validation=dict(adopted=False, hasEdge=False, markets=comparison,
                                  scope='Independent shadow challenger; never used for public recommendations.'))
    return dict(schemaVersion=1, version=VERSION, cutoff=history['cutoff'], challengerModel=shadow,
                generatedAt=datetime.now(timezone.utc).isoformat(),
                sourceHash=hashlib.sha256(json.dumps(history, sort_keys=True).encode()).hexdigest(),
                scheduleHash=hashlib.sha256(json.dumps(schedule, sort_keys=True).encode()).hexdigest(),
                selectedSpecification=selected, developmentCandidates=candidates,
                protocol=dict(selectionSeasonsBefore=EVALUATION_START, evaluationSeasonsFrom=EVALUATION_START,
                              selectionObjective='earlier-week home/away score mean squared error',
                              evaluation='Retrospective later-season evaluation; prior v1 aggregate reports already included these seasons.',
                              intervals='95% paired season/week block bootstrap, fixed seed, 2000 replicates; exploratory, not multiple-comparison adjusted.',
                              priceReference='Actual paired historical closing odds only; no fallback baseline, no obtainable-return claim.'),
                evaluationGames=len(later), scoreMae=sum(r['absoluteError'] for r in later)/len(later),
                markets=comparison, seasons={str(s): compare([r for r in later if r['season'] == s], incumbent) for s in sorted({r['season'] for r in later})},
                decision=dict(improvedAllMarketsVsIncumbent=beats_incumbent, clearedHistoricalMarketGate=beats_market,
                              adopted=False, hasEdge=False, status='shadow_only',
                              reason='Challenger remains in research. Live predictions are unchanged. Historical comparisons cannot establish a prospective edge or superiority to general AI.'))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--history', type=Path, default=ROOT/'assets/nfl-history.json')
    parser.add_argument('--schedule', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT/'assets/forecast-lab.json')
    args = parser.parse_args()
    with args.schedule.open(encoding='utf-8-sig', newline='') as f:
        schedule = list(csv.DictReader(f))
    report = run(json.loads(args.history.read_text(encoding='utf-8-sig')), schedule)
    args.output.write_text(json.dumps(report, separators=(',', ':'), allow_nan=False)+'\n', encoding='utf-8')
    print(json.dumps({k: report[k] for k in ('selectedSpecification', 'evaluationGames', 'scoreMae', 'decision')}))
    print(json.dumps({m: {k: r[k] for k in ('games', 'brier', 'marketBrier', 'incumbentBrier', 'marketDifference95')} for m, r in report['markets'].items()}))


if __name__ == '__main__':
    main()
