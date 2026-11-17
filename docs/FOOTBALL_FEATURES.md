# Pregame football evidence and fixed trial

Implemented 2026-11-16. This is an unadopted research model, not a demonstrated betting advantage.

## Evidence

`model/football_features.py` aggregates free [nflverse play-by-play](https://github.com/nflverse/nflverse-data/releases/tag/pbp) (CC BY 4.0). `assets/team-efficiency.json` contains 2,448 team-games from 2022–2026, through 2026-11-12, joined to exact scored games. Source URLs and file SHA-256 hashes are retained. These are reconstructed dated observations; archived publication vintages are unavailable, so later source corrections cannot be ruled out.

Pass/run EPA excludes kneels and spikes. A play-weighted ridge regression jointly estimates team offense and opponent allowance relative to league, using an 84-day half-life, 730-day window and 200-play ridge penalty. Clock pace uses within-drive, same-quarter game-clock gaps from 1–80 seconds. It is a proxy, not neutral-situation tempo. Pace shrinks toward the league by 50 intervals; weighted play volume by three games.

Prior passing leaders, their recorded dropback shares and changes across the previous two appearances are descriptive history. Tied/missing leaders remain unknown. Upcoming starters remain explicitly unconfirmed. Existing official named-inactive checks remain separate; no injury point penalties or starting roles are invented. Coach exposes this sourced context under **Lineup & workload**.

## One fixed challenger

`score-football-features-v1` starts with the stronger existing score challenger (ridge 8, half-life 180 days). A 16-feature residual correction uses home field, opponent-adjusted efficiency, pace, play volume, rest difference, prior observed passing-leader changes/shares and missing-data flags. It fits earlier out-of-sample score errors only, with ridge 20, home penalty 4, unpenalized intercept, 180-day half-life, 730-day window, at least 100 earlier games and corrections capped at seven points. No parameter search was performed.

Each entire target week is excluded from fitting and residual banks. Fits also exclude observations dated on/after the week's earliest kickoff date, including already-played Thursday games when projecting a remaining Monday game. Paired empirical score errors need at least 120 earlier games. Current-game starter labels, current scores, closing lines and current-week EPA never enter predictors. Closing prices are evaluation references only.

## First retrospective comparison

Lower Brier scores are better. All rows use matched games against the stronger existing challenger and no-vig closing market references.

| Market | Games | Football trial | Existing challenger | Market |
|---|---:|---:|---:|---:|
| Moneyline | 407 | 0.225177 | 0.225721 | 0.213314 |
| Spread | 402 | 0.266915 | 0.267743 | 0.249795 |
| Total | 409 | 0.262506 | 0.259571 | 0.250383 |

The trial slightly improves moneyline/spread errors but worsens totals; market references beat it in all three categories. These results do not establish significance or profitability. The later 2025+ period appeared in earlier project reports, so it is retrospective, not a newly untouched holdout. The fixed settings were not revised after viewing this result. Full Brier/log-loss results and week-cluster comparisons are in `assets/football-research.json`.

## Forward testing and publication

Weekly training rebuilds the evidence and this same fixed model. The public index validates source/history hashes, coefficients, earlier input cutoffs, event identities and exact kickoff timestamps. Only board-relevant future event blocks are published, keeping the index below the hosted two-megabyte limit.

The worker captures a separate `score-football-features-v1/game-analysis-v1` cohort within the existing pregame capture window. It does not change serving probabilities, request extra AI benchmarks, fetch extra paid odds or track personal bets. Future frozen snapshots and final results provide the untouched evaluation; old cohorts are preserved. Coach's performance view reports this trial alongside existing research without promoting it to recommendations.

If the public schedule changes a kickoff after training, that exact event's trial inputs are withheld until refitting. Coverage reports the withheld identities and old/current times. Other matching events and the current schedule can still publish; no mismatched forecast is silently reused.

Tests cover target/future-week score, EPA and role perturbations; closing-price separation; prior-date guards; unknown role flags; bounded corrections; Python/JavaScript projection parity; malformed/adopted inputs; source provenance; and phone layout. Reproduce with the existing model environment:

```powershell
python model/football_features.py
python model/football_forecast.py --schedule model/.cache/games.csv
python -m unittest discover -s model -t model
python -m unittest discover -s tools -p 'test_*.py'
node --test hosting/*.test.mjs
flutter analyze
flutter test
```

The cache must contain the free nflverse PBP files, downloaded by the existing trainer. Future work should prioritize verified point-in-time lineup/participation data and prospective evidence. This version does not claim neutral-situation pace, confirmed starters, or superiority to general AI.
